## Phase 8 — Per-fix-group agents

Compute eligibility, union-find the groups, transition every eligible
finding open→attempted, and dispatch one Opus fix-group agent per
group in a single orchestrator turn. Each agent returns a strict JSON
shape (§19.8) that Phase 9 reads to classify outcomes and decide which
groups survive or revert.

### 8.1. Compute `eligible_finding_ids`

The Phase 8 fix gate filters on current_state + disposition +
impact_type (deep lane only — §13.2) + `score_phase4 >= threshold`.
A non-null `human_confirmation` (set by `/adams-review-promote`, §27)
bypasses both the impact_type lane filter AND the score threshold —
the human has overridden the validator's conservative defaults.

The `/adams-review-walkthrough` scope filter (§28, step 3 in
`commands/adams-review-walkthrough.md`) is the **inverse** of this
selector. Keep the two in sync — any edit to the eligibility logic
below must mirror into the walkthrough's scope jq.

```bash
eligible_finding_ids=$(jq -r --argjson thr "$threshold" '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
     | select(
         (.human_confirmation != null)
         or (
           (.impact_type == "correctness" or .impact_type == "security")
           and (.score_phase4 != null and .score_phase4 >= $thr)
         )
       )
     | .id
    ] | join(",")
' "$artifact_path")
```

Capture `eligible_finding_ids` (CSV string; empty when no finding
qualifies). Also capture counts for trace:

```bash
eligible_count=$(jq -r --argjson thr "$threshold" '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
     | select(
         (.human_confirmation != null)
         or (
           (.impact_type == "correctness" or .impact_type == "security")
           and (.score_phase4 != null and .score_phase4 >= $thr)
         )
       )
    ] | length
' "$artifact_path")
```

Append a trace record:

```bash
printf 'phase_8_eligible count=%s threshold=%s ids=%s\n' \
    "$eligible_count" "$threshold" "${eligible_finding_ids:-<none>}" \
    >> "$trace_log_path"
```

### 8.2. Empty-eligibility short-circuit

When `eligible_count == 0`, there is nothing to fix. Record a Phase 8
phases.jsonl entry, skip directly to Phase 9e's no-commit branch
(re-render artifact, pop stash if taken, mirror the unchanged report
to chat), and exit 0 with a user-visible message:

> No fix-eligible findings at threshold=$threshold. Nothing to do.

Implementation: set `fix_groups='[]'`, `phase_9a_outcomes='[]'`,
`overlap_files=''`, `reverted_groups='[]'`, `surviving_groups='[]'`,
`commit_sha=null` in working context, then jump to Phase 9e no-commit.
The artifact's findings are unchanged, but the terminal block still
re-renders, pops stash, and surfaces the summary — so the run is
accounted for in `phases.jsonl` and the user's tree is restored if
they stashed at 7.5.

### 8.3. Group findings via `group-fixes.py`

Skipped when `eligible_count == 0` (8.2 already handled the short-circuit).

```bash
fix_groups=$(~/.claude/commands/_shared/tools/group-fixes.py \
    --artifact "$artifact_path" \
    --eligible-finding-ids "$eligible_finding_ids")
```

On non-zero: parse stderr per §8.6 (error-as-prompt), adjust inputs
(usually the eligibility filter), retry once. On second failure:
escalate to the user, pop stash, abort.

Capture `fix_groups` as a JSON array in working context. Record the
group count:

```bash
group_count=$(echo "$fix_groups" | jq 'length')
printf 'phase_8_grouped groups=%s\n' "$group_count" >> "$trace_log_path"
```

### 8.4. Bulk `open → attempted` transition

Apply one batched helper call so every eligible finding transitions
atomically from the caller's perspective (per-tuple atomic on disk,
first-failure halts — see `--apply-fix-start` in §21.2):

```bash
start_tuples=$(jq -nc --arg run_id "$run_id" --arg ids "$eligible_finding_ids" '
    ($ids | split(",")) | map({id: ., run_id: $run_id})
')
echo "$start_tuples" | \
    ~/.claude/commands/_shared/tools/artifact-patch.py \
      --path "$artifact_path" --apply-fix-start @-
```

On non-zero (stale attempted state — the leftover-attempted hard
abort in 7.4 is supposed to catch it; a failure here would mean the
orchestrator filtered an ineligible finding in 8.1, so surface the
error and abort — DO NOT retry silently):

1. Log stderr to `trace.md`.
2. Pop stash if taken.
3. Abort with a user-visible message pointing at the bad finding id
   (the stderr names it); recommend `artifact-patch.py --finding-id
   <id> --set current_state=open` to reset.

On success, every eligible finding is now `current_state=attempted`
on disk. This is the transient state the §4 Phase 7 step 4 hard abort
catches if the run is interrupted between here and Phase 9e.

### 8.5. Dispatch parallel fix-group agents (one turn)

Fan out one `Agent` tool-use per group, all in a single orchestrator
turn. Each agent uses `subagent_type: general-purpose`, `model: opus`,
and receives the full §19.8 input per-group.

**Prompt body per fix-group agent** (inline for each group):

```
You are a fix-group agent. Apply all fixes in this group to the working
tree, then return a structured result the orchestrator can audit.

Run identity:
- run_id: $run_id
- fix_group_id: $group.id     (e.g. FG-1)
- input_sha: $input_sha

Findings in this group:
<jq output: for each finding_id in $group.finding_ids, emit the finding's
 full id, file, line_range, claim, validation_result (evidence,
 blast_radius, fix_proposal, verification_context), and — when the
 finding has human_confirmation.fix_hint set (promoted via
 /adams-review-promote --fix-hint, §27) — a labeled block:

   Human-authored fix direction (set via /adams-review-promote --fix-hint):
   <fix_hint verbatim>

   This is an explicit instruction from the reviewer. It takes
   precedence over any ambiguity in the claim text. If the hint
   and the claim can be reconciled, follow both; if they conflict,
   follow the hint. If validation_result.fix_proposal.approach is
   also present and disagrees with the hint, the hint wins — the
   human has explicitly overridden the validator.

 And — when the finding's latest fix_attempts entry has
 phase_9_outcome ∈ {partial, regression} — the prior phase_9_finding
 and revised_fix_proposal>

Cross-cutting annotations:
<jq output: any cross_cutting_groups entry whose finding_ids intersect
 this group's>

CLAUDE.md paths (read as needed for project conventions):
$claude_md_paths

Files this group will touch (union of all fix_proposal.files_to_modify
across the group):
$group.files_planned

Repository root: $repo_root

---

What to do (per DESIGN §19.8):

1. **Read all files in the group once** before editing. Duplicated reads
   waste tokens.
2. **Plan fix ordering.** Some fixes depend on earlier ones' changes.
3. **Apply edits via the Edit and Write tools ONLY.**
   - DO NOT run git commands. The orchestrator handles staging, commits,
     and push.
   - DO NOT delete or rename files. No rm, git rm, git mv, or any
     filesystem-mutating Bash. The revert model only handles edits and
     creates; deletes/renames are `actionability: manual` in v1. If a
     finding genuinely requires deletion or rename, return a
     verification_results entry with `passed: false` and
     `note: "requires delete/rename — manual intervention"` and leave
     the file untouched.
4. **For each finding, run its verification_context.how_to_verify_fix
   steps** after editing. Use Read and Bash(grep:*) — no mutating calls.
   Report per-step pass/fail.
5. **If the project has verification_commands configured** (CLAUDE.md),
   run the matching ones for changed files; report exit codes.
6. **Retry context.** If a finding's latest fix_attempts entry has
   phase_9_outcome ∈ {partial, regression}, the prior phase_9_finding
   and revised_fix_proposal are provided above — consult them. Do not
   replay an edit that regressed.
7. **Emit the two file lists explicitly.** Track every file you touch
   and classify it as:
   - `files_modified`: existed BEFORE this invocation, edited via Edit.
   - `files_created`: did NOT exist before this invocation, created via
     Write.
   The lists must be disjoint and cover every file you touched — no
   third category exists in v1.

---

Return JSON of exactly this shape:

{
  "per_finding": [
    {
      "finding_id": "F001",
      "edits_applied": ["src/auth/session.ts", "src/auth/guest.ts"],
      "verification_results": [
        { "step": "grep 'authenticateUser' — no dead null-checks", "passed": true, "note": "..." }
      ]
    }
  ],
  "files_modified": ["..."],
  "files_created": ["..."],
  "per_file_summary": [
    { "file": "src/auth/session.ts", "lines_changed": 18 }
  ]
}
```

Capture `phase_8_start_epoch` at the top of the dispatch turn:

```bash
phase_8_start_epoch=$(date +%s)
```

Then fire all `group_count` Agent tool-use blocks in the same turn.
Claude Code runs them concurrently.

### 8.6. Parse + record per-group results

After every agent returns (before branching on its content):

1. **Log tokens first** (§24.4):

   ```bash
   ~/.claude/commands/_shared/tools/log-tokens.sh \
     --review-dir "$review_dir" \
     --phase phase_8 --agent-role "fix_group_$group.id" \
     --agent-id <id-from-Agent-result> \
     --model opus \
     --tokens <N or null>
   ```

2. **Parse the JSON output.** Light repair (strip code fences, extract
   object) is OK. On parse failure, retry once with a prompt addendum:
   "Your prior response was not valid JSON. Return only the JSON object
   described in the schema." On second failure, record a placeholder
   result so Phase 9 can tell this group's agent failed:

   ```json
   {
     "per_finding": [],
     "files_modified": [],
     "files_created": [],
     "per_file_summary": [],
     "_parse_failed": true
   }
   ```

   and log an orchestrator-error prefixed line to `trace.md`. The
   group's findings will drop to Phase 9's regression-or-unresolved
   handling (no Phase 8 work to verify; the reviewer will see zero
   edits for those findings in the working-tree diff and classify
   them regression-or-partial).

3. **Store the result** onto the `fix_groups[group.id]` entry in
   working context:

   ```
   fix_groups[i].results = {
     per_finding: [...],
     files_modified: [...],
     files_created: [...],
     per_file_summary: [...],
     _parse_failed?: bool
   }
   ```

4. **Validate the two file lists are disjoint.** If an agent returned
   the same path in both `files_modified` and `files_created`, log an
   orchestrator-error prefixed line and proceed — Phase 9.pre's
   overlap check will catch and abort if needed.

### 8.7. Phase 8 trace + phases.jsonl

```bash
phase_8_elapsed=$(( $(date +%s) - phase_8_start_epoch ))

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 8 --name fix-execution \
  --elapsed "$phase_8_elapsed" \
  --summary "dispatched $group_count fix groups over $eligible_count findings (run_id=$run_id)"

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 8 --record "$(jq -nc \
    --arg run_id "$run_id" \
    --argjson elapsed "$phase_8_elapsed" \
    --argjson groups "$group_count" \
    --argjson eligible "$eligible_count" \
    '{name:"fix-execution", elapsed_sec:$elapsed,
      run_id:$run_id,
      fix_group_count:$groups,
      eligible_finding_count:$eligible}')"
```

### Working-set delta after Phase 8

- Every eligible finding is `current_state=attempted` on disk.
- `fix_groups` is a fully populated array: each entry has `id`,
  `finding_ids`, `files_planned`, and a populated `results` object
  (with `files_modified`, `files_created`, `per_finding`,
  `per_file_summary`, optional `_parse_failed`).
- Working tree has the fix-group agents' edits (or the prior stash's
  edits if they bypassed the Phase 7 gate — which they can't; we took
  a clean-tree baseline).
- Phase 9 reads `fix_groups[*].results` plus the working-tree diff.
