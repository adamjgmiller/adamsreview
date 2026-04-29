## Phase 9 — Post-fix review + commit

### 9.pre. Touched-file overlap guard

Compute per-group `actual_touched` from Phase 8 results:

```bash
# For each group: union(files_modified, files_created)
fix_groups_with_actual=$(echo "$fix_groups" | jq -c '
    map(. + {actual_touched: ((.results.files_modified // []) + (.results.files_created // [])) | unique})
')
```

Detect files appearing in ≥2 groups' `actual_touched`:

```bash
overlap_files=$(echo "$fix_groups_with_actual" | jq -r '
    [ .[] | {g: .id, files: .actual_touched[]?} ]
    | group_by(.files)
    | map(select(length >= 2) | {file: .[0].files, groups: [.[].g]})
    | if length == 0 then "" else . end
')
```

Scan `git status --porcelain` for `D ` entries. Any hit → overlap-abort
(same no-commit branch) with a diagnostic naming the file(s):

```bash
deleted_paths=$(git status --porcelain | awk '/^( D|D )/ {print substr($0, 4)}')
if [[ -n "$deleted_paths" ]]; then
    overlap_files=$(jq -nc --arg reason "fix agent deleted file(s) — forbidden in v1: $deleted_paths" \
        '[{file:"<delete-detected>", groups:[], reason:$reason}]')
fi
```

**If `overlap_files` is non-empty:**

Delete-leak (`deleted_paths` non-empty) goes straight to abort — v1 revert
can't handle deletes and neither can reconcile, so no merge offer. For
plain overlap, offer a three-way `AskUserQuestion` before abort.

Snapshot for commit message + trace:

```bash
overlap_files_snapshot="$overlap_files"
overlap_files_snapshot_summary=$(echo "$overlap_files" | jq -r '
    [.[] | "\(.file) ← \(.groups | join(", "))"] | join("; ")
')
```

#### 9.pre.offer — three-way reviewer choice

Skipped on delete-leak (→ abort) or non-interactive (default `abort`).

Render a short summary:

```
Fix agents touched overlapping files:

<overlap_files_snapshot_summary rendered one per line>

Choose how to proceed.
```

Dispatch `AskUserQuestion` with three options; Abort highlighted as default:

- "⭐ Abort (recommended) — discard all edits, restore tree, reset state, re-run manually"
- "Reconcile — dispatch one merge agent to combine edits, then run full Phase 9 review"
- "Inspect — leave tree as-is for manual review (findings stay attempted; leftover-guard catches next run)"

Bind to `$overlap_choice` ∈ {`abort`, `reconcile`, `inspect`}. Non-interactive
or declined → `abort`.

Branch:

- `abort` → §9.pre.abort.
- `inspect` → §9.pre.inspect.
- `reconcile` → §9.pre.reconcile. On any reconcile failure (parse failure
  after one retry, or non-empty `unresolved_conflicts`), log to `trace.md`
  and fall back to §9.pre.abort — findings are still `attempted` so abort
  tuples apply cleanly.

#### 9.pre.reconcile — one Opus merge agent

Dispatched when `$overlap_choice == reconcile`. Produces a reconciled tree
and replaces `fix_groups` with a synthetic `FG-RECON` entry so 9a/9b/9c/9d
run unchanged. Each finding's on-disk `fix_attempts[].fix_group_id` keeps
its ORIGINAL FG-N (schema's `^FG-[0-9]+$` rejects `FG-RECON`) via the
snapshot captured here.

```bash
phase_9_reconcile_start_epoch=$(date +%s)

# Snapshot original group-per-finding for 9d schema compat.
original_fix_group_by_finding=$(echo "$fix_groups_with_actual" | jq -c '
    [.[] as $g | $g.finding_ids[] | {id: ., group: $g.id}]
')
```

Compose the merge-agent prompt (context values already in working set):

```
You are the Phase 9 reconciliation agent. Parallel fix-group agents
edited the working tree and collided on shared files. The tree is
last-write-wins — it does NOT represent any single group's intent.
Produce a tree that satisfies EVERY finding from EVERY group, without
regressions.

Run identity:
- run_id: $run_id
- input_sha: $input_sha (pre-Phase-8 baseline; `git diff $input_sha`
  shows cumulative edits across all fix groups)
- review_id: $review_id

Overlap map (files touched by ≥2 groups):
<jq output: $overlap_files_snapshot — [{file, groups: [FG-N, ...]}]>

Per-group context — for each original fix group:
<jq output from $fix_groups_with_actual: id, finding_ids,
 results.files_modified, results.files_created,
 results.per_finding.edits_applied,
 results.per_finding.verification_results>

Per-finding context — for each finding across all groups:
<artifact-read.sh --finding-id <id> for every id in
 original_fix_group_by_finding: id, file, line_range, claim,
 validation_result.evidence, validation_result.blast_radius
 (parallel_paths + invariants_at_stake),
 validation_result.fix_proposal (approach + files_to_modify with
 file/what/why), validation_result.verification_context.how_to_verify_fix>

CLAUDE.md paths (project conventions to respect):
$claude_md_paths

---

Your task:

1. Non-overlapping files: keep current contents. Do NOT re-edit a
   single-group file unless you detect a regression caused elsewhere.

2. For each overlapping file:
   a. Read the file as it currently stands.
   b. Read pre-Phase-8 content: `git show $input_sha:<path>`.
   c. Identify each group's intent from per_finding.edits_applied +
      verification_results and the finding's fix_proposal.files_to_modify
      (`what` / `why`).
   d. Produce a reconciled file applying ALL intents. Substantive
      conflict: prefer the version satisfying both findings' evidence;
      truly incompatible: pick higher-score_phase4 and list the other
      id in unresolved_conflicts with a concrete reason.

3. After editing, re-verify every finding across all groups by running
   its validation_result.verification_context.how_to_verify_fix steps
   (grep / Read only — no mutating calls). Report per-step pass/fail.

4. Adjacent-regression check: for each reconciled file, read changed
   hunks ±20 lines and verify no new bug (inverted condition, off-by-one,
   null-deref, resource leak, ordering swap, etc.) was introduced.

5. Convention-drift check: for each entry in any finding's
   blast_radius.parallel_paths, diff your reconciled file against that
   path for boundary-condition consistency (loop bounds, null semantics,
   ordering, error handling, direction of COALESCE args). Divergence
   from cross-parallel convention is a bug the merge just wrote — fix
   before returning.

6. If CLAUDE.md defines verification_commands for any changed file, run
   the matching ones; report exit codes.

7. DO NOT run git commands. DO NOT delete or rename files. Edit / Write only.
   Orchestrator handles staging, commit, revert. Genuine deletion/rename
   needs: list in unresolved_conflicts with reason "requires delete/rename
   — manual".

---

Return JSON of exactly this shape (matches Phase 8's per-group contract
so the orchestrator feeds it straight into Phase 9a):

{
  "reconcile_notes": "<1–3 sentences on how conflicts were merged>",
  "per_finding": [
    {
      "finding_id": "F001",
      "edits_applied": ["src/...", "src/..."],
      "verification_results": [
        { "step": "...", "passed": true, "note": "..." }
      ]
    }
  ],
  "files_modified": ["..."],
  "files_created": ["..."],
  "per_file_summary": [
    { "file": "...", "lines_changed": 24,
      "reconciled_from_groups": ["FG-1", "FG-2"] }
  ],
  "unresolved_conflicts": [
    { "file": "...", "finding_ids": ["F007", "F012"],
      "reason": "..." }
  ]
}

Rules:
- files_modified and files_created must be disjoint and cover every
  file you edited.
- per_finding must contain an entry for every finding_id across every
  original fix group (no silent drops).
- Non-empty unresolved_conflicts aborts reconcile to the standard
  overlap-abort recovery path — return them explicitly; never silently
  pick a winner.
```

Dispatch ONE `Agent` tool-use with `subagent_type: general-purpose`,
`model: opus`.

After the agent returns:

1. **Log tokens** via `log-tokens.sh --phase phase_9_reconcile
   --agent-role reconcile --model opus`. (Match Phase 8 §8.6 step 1 —
   always log tokens before branching on content so cost is accounted
   even when output fails to parse.)

2. **Parse JSON into `$reconcile_result`.** Light repair (strip fences,
   extract object); one retry with "Return only the JSON object described
   in the schema" on parse failure. On success `$reconcile_result` holds
   `per_finding`, `files_modified`, `files_created`, `per_file_summary`,
   `unresolved_conflicts`, `reconcile_notes`.

3. **Fallback to abort** on any of:
   - Second parse failure.
   - `$reconcile_result.unresolved_conflicts` non-empty.
   - `$reconcile_result.per_finding` missing any attempted finding_id
     (vs. union of finding_ids from original `fix_groups`).
   - Agent's `files_modified` and `files_created` share any entry (must
     be disjoint per prompt contract).
   - Post-reconcile tree empty vs. `$input_sha` — `git status --porcelain`
     empty. Valid JSON, zero edits: silent no-op.

   On any trigger, set `reconcile_fallback_reason` to one of
   `parse_failure` | `unresolved_conflicts` | `missing_findings` |
   `overlapping_files_arrays` | `empty_diff`, log it, set the fallback
   flag for 9e:

   ```bash
   reconcile_fallback_reason="<pick one of: parse_failure |
     unresolved_conflicts | missing_findings |
     overlapping_files_arrays | empty_diff>"
   printf 'reconcile_fallback reason=%s\n' "$reconcile_fallback_reason" \
       >> "$trace_log_path"
   reconcile_fallback=true
   ```

   Then drop into §9.pre.abort — findings are still `attempted` on disk,
   so abort tuples apply cleanly. The user sees a reconcile_fallback
   message from 9e step 8 naming `$reconcile_fallback_reason`.

4. **On success** (no fallback trigger), replace `fix_groups` with a
   synthetic single entry and clear overlap so the rest of Phase 9 runs
   against the reconciled tree.

   The synthetic entry's `files_modified` / `files_created` are built from
   **`git status --porcelain`** (every path git sees differs from
   `$input_sha`) and classified by git-truth: `git cat-file -e
   $input_sha:<path>` decides existed-at-baseline (→ `files_modified`,
   revert via `git checkout --`) vs. new (→ `files_created`, revert via
   `rm -f`).

   - **Catches everything actually changed.** Phase 8 agents `Write` new
     files (untracked, git-visible) and modify files (unstaged, git-visible).
     Phase 7's clean-tree gate + optional stash guarantees the only changes
     git sees are agent-made, so the set is complete and holds no user work.
   - **Catches rogue reconcile-agent edits** outside Phase 8's touched set
     (adjacency fix, hallucinated scope) even when the agent's arrays omit
     them. On regression 9b reverts; on commit 9c stages.
   - **Robust against agent-report disagreement.** If Group A reports X
     "created" but Group B reports X "modified", git is the ground truth —
     misreports can't cause a destructive revert.
   - **`git diff` can't substitute** — it ignores untracked files.

   ```bash
   # Candidate set: every path git status sees changed vs HEAD (== $input_sha,
   # per Phase 7's clean-tree baseline). Strip 3-char prefix; keep non-empty.
   # Handles tracked-modified (" M <path>"), untracked ("?? <path>"), etc.
   # Deletes were filtered by 9.pre's delete-leak short-circuit, so no D here.
   candidates_json=$(git status --porcelain | sed 's/^...//' | \
       jq -Rsc 'split("\n") | map(select(length > 0)) | unique')

   # Classify each candidate by existence at $input_sha.
   files_created_arr=()
   files_modified_arr=()
   while IFS= read -r f; do
       [[ -z "$f" ]] && continue
       if git cat-file -e "$input_sha:$f" 2>/dev/null; then
           files_modified_arr+=("$f")
       else
           files_created_arr+=("$f")
       fi
   done < <(echo "$candidates_json" | jq -r '.[]')

   # Bash-array-to-JSON (handle empty explicitly — `printf` on an unset
   # array under `set -u` trips unbound-variable).
   if [[ ${#files_created_arr[@]} -eq 0 ]]; then
       files_created_json='[]'
   else
       files_created_json=$(printf '%s\n' "${files_created_arr[@]}" \
           | jq -Rsc 'split("\n") | map(select(length > 0))')
   fi
   if [[ ${#files_modified_arr[@]} -eq 0 ]]; then
       files_modified_json='[]'
   else
       files_modified_json=$(printf '%s\n' "${files_modified_arr[@]}" \
           | jq -Rsc 'split("\n") | map(select(length > 0))')
   fi

   fix_groups=$(jq -nc \
       --argjson result "$reconcile_result" \
       --argjson fc "$files_created_json" \
       --argjson fm "$files_modified_json" \
       --argjson ids "$(echo "$fix_groups_with_actual" | jq -c '[.[].finding_ids[]] | sort | unique')" '
       [{
         id: "FG-RECON",
         finding_ids: $ids,
         files_planned: ($fc + $fm | unique),
         results: ($result + {files_modified: $fm, files_created: $fc})
       }]
   ')
   fix_groups_with_actual=$(echo "$fix_groups" | jq -c '
       map(. + {actual_touched: ((.results.files_modified // []) + (.results.files_created // [])) | unique})
   ')
   overlap_files=""
   reconciled_flag=true
   ```

5. **Log phases.jsonl** for the reconcile pass:

   ```bash
   phase_9_reconcile_elapsed=$(( $(date +%s) - phase_9_reconcile_start_epoch ))
   # Use FG-RECON's files_planned — the Phase-8-plus-reconcile union,
   # i.e., the full set 9b reverts on regression. $reconcile_result alone
   # undercounts Phase 8 files the merge agent didn't re-edit.
   reconciled_file_count=$(echo "$fix_groups" | jq '.[0].files_planned | length')
   reconciled_finding_count=$(echo "$fix_groups" | jq '.[0].finding_ids | length')
   original_group_count=$(echo "$original_fix_group_by_finding" | jq '[.[].group] | unique | length')
   overlap_count=$(echo "$overlap_files_snapshot" | jq 'length')

   log-phase.sh \
     --review-dir "$review_dir" --phase 9 --name reconcile \
     --elapsed "$phase_9_reconcile_elapsed" \
     --summary "reconciled $overlap_count overlap(s): $reconciled_finding_count finding(s) from $original_group_count group(s) merged across $reconciled_file_count file(s)"

   printf 'reconcile_applied files=%s findings=%s orig_groups=%s overlaps=%s\n' \
     "$reconciled_file_count" "$reconciled_finding_count" \
     "$original_group_count" "$overlap_count" \
     >> "$trace_log_path"
   ```

6. Proceed to 9a. Its `git diff HEAD` captures the reconciled tree;
   §19.9's per-finding re-trace + adjacent-regression + convention-drift
   sweeps serve as the post-reconcile review.

#### 9.pre.inspect — leave tree as-is

Dispatched when `$overlap_choice == inspect`. User inspects the post-
Phase-8 tree — no `--apply-fix-outcomes`, no revert, no commit. Findings
stay `attempted`; Phase 7 step 4's hard abort on next run is the recovery
path. Unlike `abort`, no audit fix_attempts are appended — user may
hand-resolve and wants a clean slate.

```bash
printf 'overlap_inspect chosen files=%s\n' "$overlap_files_snapshot_summary" >> "$trace_log_path"
commit_sha=null
reverted_groups='[]'
surviving_groups='[]'
phase_9a_outcomes='[]'
overlap_inspect=true
```

Jump to 9e no-commit branch. Stash-pop is skipped (matches revert-failure:
tree holds agent edits, popping could conflict); 9e step 8 surfaces a
tailored `overlap_inspect` message.

#### 9.pre.abort — overlap-abort (default)

Reached from `abort`, delete-leak short-circuit, or reconcile fallback.

1. Log overlapping files + owning groups to `trace.md`:

   ```bash
   printf 'overlap_abort %s\n' "$overlap_files_snapshot" >> "$trace_log_path"
   ```

2. Skip 9a/9b/9c entirely — no review, no revert, no stage, no commit.

3. Build `--apply-fix-outcomes` tuples for every attempted finding (every
   eligible from 8.1 — all `attempted` on disk from 8.4). Tuple shape
   (required keys):

   ```json
   {
     "id": "<Fxxx>",
     "run_id": "<run_id>",
     "fix_group_id": "<FG-N>",
     "input_sha": "<input_sha>",
     "output_sha": null,
     "phase_9_outcome": null,
     "timestamp": "<ISO-8601 UTC>",
     "phase_9_finding": "run aborted: fix agents touched overlapping files across groups — <file-list>"
   }
   ```

   For each eligible finding id, look up its `fix_group_id` from
   `fix_groups[].finding_ids` and emit one tuple. One batched call —
   `--apply-fix-outcomes` preserves `current_state=attempted` on null
   outcome (§21.2 / §4 Phase 9.pre step 5):

   ```bash
   ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   overlap_file_list=$(echo "$overlap_files_snapshot" | jq -r '[.[].file] | join(", ")')
   phase_9_finding_text="run aborted: fix agents touched overlapping files across groups — $overlap_file_list"

   # On reconcile-fallback-to-abort, $original_fix_group_by_finding was
   # captured in 9.pre.reconcile step 1 (before dispatch — present on every
   # fallback path) and is the authoritative pre-reconcile finding→group
   # map. Plain abort (no reconcile) leaves it unset — fall back to
   # fix_groups_with_actual.
   if [[ -n "${original_fix_group_by_finding:-}" ]]; then
       overlap_abort_tuples=$(jq -nc \
           --arg run_id "$run_id" --arg input_sha "$input_sha" \
           --arg ts "$ts" --arg pf "$phase_9_finding_text" \
           --argjson map "$original_fix_group_by_finding" '
           [ $map[]
             | {id: .id,
                run_id: $run_id,
                fix_group_id: .group,
                input_sha: $input_sha,
                output_sha: null,
                phase_9_outcome: null,
                timestamp: $ts,
                phase_9_finding: $pf}
           ]
       ')
   else
       overlap_abort_tuples=$(jq -nc \
           --arg run_id "$run_id" --arg input_sha "$input_sha" \
           --arg ts "$ts" --arg pf "$phase_9_finding_text" \
           --argjson groups "$fix_groups_with_actual" '
           [ $groups[] as $g
             | $g.finding_ids[]
             | {id: .,
                run_id: $run_id,
                fix_group_id: $g.id,
                input_sha: $input_sha,
                output_sha: null,
                phase_9_outcome: null,
                timestamp: $ts,
                phase_9_finding: $pf}
           ]
       ')
   fi

   echo "$overlap_abort_tuples" | \
       artifact-patch.py \
         --path "$artifact_path" --apply-fix-outcomes @-
   ```

4. Set working-set vars for 9e's no-commit branch. If reached via
   reconcile-fallback, `reconcile_fallback=true` (set in 9.pre.reconcile
   step 3) tells 9e to surface the fallback reason instead of the plain
   overlap message; unset on plain abort:

   ```bash
   commit_sha=null
   reverted_groups='[]'
   surviving_groups='[]'
   phase_9a_outcomes='[]'
   overlap_abort=true
   ```

5. Jump to 9e **no-commit branch**. User-visible error after terminal cleanup:

   > ERROR: /adamsreview:fix aborted before commit — fix agents
   > touched overlapping files across groups.
   >
   > Overlapping files: `<files>`
   > Groups involved: `<groups>`
   >
   > Recovery:
   >   1. `git status` — inspect what's in the working tree.
   >   2. Decide what to keep. To discard everything the agents did:
   >      `git restore .` + `git clean -fd` for any new files.
   >   3. Reset each affected finding's current_state:
   >      artifact-patch.py --finding-id <id> --set current_state=open
   >      (ids listed in `trace.md`)
   >   4. Re-run /adamsreview:fix.

   On `reconcile_fallback`, swap the first line for the variant below,
   interpolating `$reconcile_fallback_reason` (§9.pre.reconcile step 3):

   > ERROR: /adamsreview:fix — reconcile attempt failed, aborted before
   > commit. Reason: `$reconcile_fallback_reason`. The working tree holds
   > the Phase-8 agent edits plus any partial merge-agent edits; recovery
   > steps 1–4 above apply unchanged (`git restore .` + `git clean -fd`
   > discards everything). See `$trace_log_path` for raw output.

**If `overlap_files` is empty**: proceed to 9a.

### 9a. Phase 9 post-fix review (one Opus sub-agent)

Dispatch ONE `Agent` (`subagent_type: general-purpose`, `model: opus`)
carrying the §19.9 prompt. Embeds all attempted findings, Phase 8 per-group
results, and the unstaged working-tree diff.

Capture the diff snapshot before dispatch:

```bash
phase_9_start_epoch=$(date +%s)
working_tree_diff=$(git diff HEAD)
```

**Build the per-finding context** for the two `<jq output: …>` placeholders
below. Stream jq directly to a file — never `echo "$jq_var"` into the
prompt. Under zsh, `/bin/sh`, or bash with `xpg_echo`, `echo` collapses
`\\` to `\` and any finding string carrying a backslash (regex literal,
code snippet, fix-hint copy) corrupts the JSON, breaking either jq parsing
downstream or the reviewer agent's interpretation.

```bash
# Per-finding context (id, file, line_range, claim, validation_result.*).
# printf '%s', not echo — see operational rule 12.
attempted_ids_json=$(printf '%s' "$fix_groups_with_actual" | jq -c '[.[].finding_ids[]] | unique')
jq --argjson ids "$attempted_ids_json" --argjson groups "$fix_groups_with_actual" '
    [ .findings[] | select(.id | IN($ids[])) | . as $f | {
        id, file, line_range, claim,
        evidence:               .validation_result.evidence,
        blast_radius:           .validation_result.blast_radius,
        fix_proposal:           .validation_result.fix_proposal,
        verification_context:   .validation_result.verification_context,
        fix_group_id:           ($groups[] | select(.finding_ids | index($f.id)) | .id)
    } ]' "$artifact_path" > /tmp/9a-findings-$run_id.json

# Per-group results (Phase 8 self-report)
printf '%s' "$fix_groups_with_actual" | jq '[.[] | {
    id, finding_ids, files_modified: .results.files_modified,
    files_created: .results.files_created,
    per_finding_verification: .results.per_finding
}]' > /tmp/9a-groups-$run_id.json
```

Embed each file's contents directly at the placeholder site (Read the
file, paste its contents). Do not capture into a shell variable + echo.

**Prompt body:**

```
You are the Phase 9 post-fix reviewer. Fix groups edited the working
tree; nothing committed yet. Review each attempted finding against the
current tree and classify.

Run identity:
- run_id: $run_id
- input_sha: $input_sha

Attempted findings and their validation contexts:
<jq output: each attempted finding's id, file, line_range, claim, plus
 from validation_result — evidence array, blast_radius (especially
 parallel_paths + invariants_at_stake — checklist step 5 needs these
 for adjacent regressions), fix_proposal (especially files_to_modify
 — step 2 verifies every planned file got an edit), verification_context,
 plus the fix group id (cross-referenced from fix_groups)>

Fix-group agent results (what each group said it did):
<jq output: per-group id, finding_ids, files_modified, files_created,
 per_finding.verification_results>

Working-tree diff (unstaged; post-Phase-8 edits, pre-commit):

$working_tree_diff

---

For each attempted finding, decide (per DESIGN §19.9):

1. Did the fix actually eliminate the bug? Re-trace the original
   validation_result.evidence against the new code state. Use Read and
   Bash(grep:*) / Bash(git diff:*) as needed.

2. Did every file in fix_proposal.files_to_modify receive a
   corresponding edit? Missing any → `partial`.

3. Did the agent's verification_context.how_to_verify_fix steps all
   pass (per per_finding.verification_results)? Any failure → `partial`.

4. Did project verification_commands pass (if run)? Failure → `partial`
   or `regression` depending on nature.

5a. Adjacent-regression sweep (local). Any new issue in code adjacent
    to the fix (same file, changed hunk ±20 lines) not there before?
    → `regression`, describe concretely.

5b. Convention-drift sweep (cross-file).
    (i) For each entry in `blast_radius.parallel_paths`, diff the fix
        against that path for boundary conditions (loop bounds, error
        handling, null semantics, ordering, direction — e.g.,
        `COALESCE(a, b)` vs. `COALESCE(b, a)`). Any divergence from
        cross-parallel convention → `regression`, name the boundary.
    (ii) If the fix introduces a new function/method/substantial block
         (new loop over a domain, new query over a table), grep/Glob
         for existing code doing similar work (matching verbs on the
         same domain noun — a new `cleanup…` → grep other iterators
         over those tables; a new date-range loop → grep other date-
         range loops). Diff boundary conditions.
         `parallel_paths` was computed on the *bug*, not the *fix* —
         the fix can introduce new parallels the validator didn't
         anticipate. Divergence → `regression`.

6. Premise audit of added inline comments. Every comment the fix added
   in the same hunk as a logic change that asserts a fact about
   surrounding code (e.g., `// X because Y`, `// always Z`) is a
   falsifiable claim. Locate via Read/grep and verify. False premise →
   `regression` with `phase_9_finding` naming it + the contradicting
   location. Wrong inline justifications propagate to future readers
   and are worse than no comment. Pre-existing comments (context lines
   in the diff, not `+` lines) are out of scope.

Classification priority: regression > partial > verified. If in doubt
between verified and partial, choose partial.

For partial or regression: fill `phase_9_finding` (concrete description
of what's missing / what broke) and `revised_fix_proposal` (next-retry
plan matching fix_proposal shape: {approach, files_to_modify: [{file,
what, why}, ...]}).

---

Return JSON of exactly this shape:

{
  "per_finding": [
    {
      "finding_id": "F001",
      "outcome": "verified",
      "phase_9_finding": null,
      "revised_fix_proposal": null
    },
    {
      "finding_id": "F004",
      "outcome": "partial",
      "phase_9_finding": "off-by-one unchanged in search.ts:142",
      "revised_fix_proposal": {
        "approach": "add the search.ts pagination fix",
        "files_to_modify": [
          {"file": "src/api/search.ts", "what": "extend the pagination fix", "why": "symmetric to users.ts"}
        ]
      }
    }
  ]
}

(For verified: phase_9_finding and revised_fix_proposal are null.)
```

After the agent returns:

1. **Log tokens** via `log-tokens.sh --phase phase_9 --agent-role
   post_fix_review --model opus`.
2. Parse JSON; light repair + one retry on parse failure.
3. Full parse failure after retry: mark every attempted finding as
   `outcome: partial` with `phase_9_finding: "phase 9 reviewer parse
   failure — manual audit required"` and no `revised_fix_proposal`. Log
   orchestrator-error line to `trace.md`. Run continues (partial is
   retry-eligible).

Store as `phase_9a_outcomes` (the `per_finding` array).

### 9b. Per-group aggregation + revert of regression groups

Aggregate outcomes per fix group. Priority `regression > partial >
verified`:

```bash
group_outcomes=$(echo "$fix_groups" | jq -c \
    --argjson outcomes "$phase_9a_outcomes" '
    map(. as $g | {
      id: $g.id,
      finding_ids: $g.finding_ids,
      files_modified: ($g.results.files_modified // []),
      files_created: ($g.results.files_created // []),
      outcome: (
        [$outcomes[] | select(.finding_id | IN($g.finding_ids[])) | .outcome]
        | if any(. == "regression") then "regression"
          elif any(. == "partial") then "partial"
          elif length == 0 then "partial"    # all findings lost classifications → treat as partial (retry-eligible)
          else "verified" end
      )
    })
')
```

Partition:

```bash
reverted_groups=$(echo "$group_outcomes" | jq -c '[.[] | select(.outcome == "regression")]')
surviving_groups=$(echo "$group_outcomes" | jq -c '[.[] | select(.outcome != "regression")]')
reverted_count=$(echo "$reverted_groups" | jq 'length')
surviving_count=$(echo "$surviving_groups" | jq 'length')
```

**Revert each regression group** (§4 Phase 9b):

```bash
revert_failed=false
revert_failure_detail=""
for row in $(echo "$reverted_groups" | jq -c '.[]'); do
    group_id=$(echo "$row" | jq -r '.id')
    # Restore each modified file to pre-Phase-8 content
    for f in $(echo "$row" | jq -r '.files_modified[]?'); do
        if ! git checkout -- "$f" 2>>"$trace_log_path"; then
            revert_failed=true
            revert_failure_detail="$revert_failure_detail; git checkout -- $f failed in $group_id"
        fi
    done
    # Remove created files
    for f in $(echo "$row" | jq -r '.files_created[]?'); do
        if ! rm -f -- "$f" 2>>"$trace_log_path"; then
            revert_failed=true
            revert_failure_detail="$revert_failure_detail; rm -f $f failed in $group_id"
        fi
    done
    printf 'reverted group=%s files_modified=%s files_created=%s\n' \
        "$group_id" \
        "$(echo "$row" | jq -c '.files_modified')" \
        "$(echo "$row" | jq -c '.files_created')" \
        >> "$trace_log_path"
done
```

**On revert failure** (§24.2): do NOT commit or proceed to 9c. Log to
trace, set `revert_failure=true`, jump to 9e no-commit leaving the tree
as-is for manual inspection. Do NOT pop stash (tree is in unknown state).

**All-regression degenerate case** (`surviving_count == 0` AND
`reverted_count >= 1`): reverts already ran; tree is restored. Nothing
to commit:

```bash
commit_sha=null
all_regression=true
```

Jump to 9e no-commit. (9e builds `--apply-fix-outcomes` tuples with
every `phase_9_outcome: regression`, `output_sha: null` — see 9e
no-commit step 1.)

**Mixed case** (`surviving_count >= 1`): proceed to 9c.

### 9c. Stage + commit surviving groups

Pre-flight the working tree:

```bash
git status --porcelain >> "$trace_log_path"
```

Collect surviving-group files. Exclude any file also touched by a reverted
group (revert wins — §9c step 2):

```bash
reverted_files=$(echo "$reverted_groups" | jq -r '
    [.[].files_modified[]?, .[].files_created[]?] | unique | join("\n")
')

surviving_files=$(echo "$surviving_groups" | jq -r \
    --arg reverted "$reverted_files" '
    [.[].files_modified[]?, .[].files_created[]?]
    | unique
    | map(select(. as $f | ($reverted | split("\n") | index($f) | not)))
    | join("\n")
')
```

**Stage by explicit name** — never `git add -A`:

```bash
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    git add -- "$f"
done <<<"$surviving_files"
```

**Build the commit message.** Carries per-group Phase 9 truth for the
whole run (committed + reverted). Heredoc file, not `-m "$(...)"`, so
`$`/backticks/quotes in claims don't need escaping:

```bash
msg_file="/tmp/adams-fix-msg-$run_id.txt"
reconciled_flag=$(echo "$fix_groups" | jq -r '.[0].id == "FG-RECON"')
{
    if [[ "$reconciled_flag" == "true" ]]; then
        # Reconcile run — surviving_groups is the single FG-RECON entry,
        # reverted_groups is empty (reconcile is all-or-nothing).
        recon_findings=$(echo "$surviving_groups" | jq -r '.[0].finding_ids | join(", ")')
        recon_files=$(echo "$surviving_groups" | jq -r '(.[0].files_modified + .[0].files_created) | join(", ")')
        echo "fix: address code review findings (reconciled)"
        echo
        echo "Reconciled fix (one merge pass after Phase 9.pre overlap):"
        echo "  Findings: $recon_findings"
        echo "  Files:    $recon_files"
        echo "  Overlaps: $overlap_files_snapshot_summary"
        echo
    else
        echo "fix: address code review findings ($surviving_count groups committed, $reverted_count reverted)"
        echo
        if [[ "$surviving_count" -gt 0 ]]; then
            echo "Fix groups (committed):"
            # One bullet per surviving group.
            echo "$surviving_groups" | jq -r '
                .[] | "- [\(.id)] \(.finding_ids | join(", ")) — \(.files_modified + .files_created | join(", ")): \(.outcome)"
            '
            echo
        fi
        if [[ "$reverted_count" -gt 0 ]]; then
            echo "Fix groups (reverted — regression detected):"
            echo "$reverted_groups" | jq -r '
                .[] | "- [\(.id)] \(.finding_ids | join(", ")) — \(.files_modified + .files_created | join(", "))"
            '
            echo
        fi
    fi
    # Phase 9 summary line (common to reconciled and non-reconciled)
    verified_count=$(echo "$group_outcomes" | jq '[.[] | select(.outcome == "verified")] | length')
    partial_count=$(echo "$group_outcomes" | jq '[.[] | select(.outcome == "partial")] | length')
    echo "Post-fix review: $verified_count/$surviving_count groups verified complete; $partial_count group(s) partial; $reverted_count group(s) reverted."
    if [[ "$partial_count" -gt 0 || "$reverted_count" -gt 0 ]]; then
        echo "Re-run /adamsreview:fix to address partial and regression findings (retry with revised_fix_proposal context)."
    fi
} > "$msg_file"
```

**Commit strategy:**

- Default: one combined commit.
  ```bash
  git commit -F "$msg_file"
  commit_sha=$(git rev-parse HEAD)
  ```

- `--granular-commits` (opt-in): one commit per surviving group. Per group:
  1. Reset index to HEAD, add only that group's files.
  2. Scoped message (same template, single group in committed-section and
     outcome lines). The run-level "reverted" section stays in the first
     granular commit's message so history is complete.
  3. Commit, capture SHA. Final `commit_sha` is the chain's HEAD.

Capture `commit_sha` IMMEDIATELY via `git rev-parse HEAD` after the last
`git commit`. **Nothing else between commit and capture** — a tool failure
in that window leaves the next run unable to prove which SHA survivors
landed at.

Remove the temp message file:

```bash
rm -f "$msg_file"
```

### 9d. State transitions + fix_attempts append (batched)

Build one `--apply-fix-outcomes` tuple array — one per attempted finding.
Survivors: `output_sha = commit_sha`, `phase_9_outcome = {verified|partial}`.
Regressions (reverted groups): `output_sha = null`, `phase_9_outcome =
regression`. Helper enforces the regression-output-sha-null invariant.

```bash
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Map finding_id → {group_id, group_outcome} for quick lookup
group_by_finding=$(echo "$group_outcomes" | jq -c '
    [.[] as $g | $g.finding_ids[] | {id: ., group: $g.id, group_outcome: $g.outcome}]
')

if [[ -n "${original_fix_group_by_finding:-}" ]] && \
   echo "$fix_groups" | jq -e '.[0].id == "FG-RECON"' >/dev/null; then
    group_by_finding=$(jq -nc \
        --argjson synth "$group_by_finding" \
        --argjson orig "$original_fix_group_by_finding" '
        $synth | map(. as $s
            | ($orig[] | select(.id == $s.id)) as $o
            | {id: $s.id, group: $o.group, group_outcome: $s.group_outcome}
        )
    ')
fi

apply_tuples=$(jq -nc \
    --arg run_id "$run_id" --arg input_sha "$input_sha" \
    --arg commit_sha "$commit_sha" --arg ts "$ts" \
    --argjson outcomes "$phase_9a_outcomes" \
    --argjson group_map "$group_by_finding" '
    $outcomes
    | map(. as $o
          | ($group_map[] | select(.id == $o.finding_id)) as $gm
          | {
              id: $o.finding_id,
              run_id: $run_id,
              fix_group_id: $gm.group,
              input_sha: $input_sha,
              output_sha: (if $gm.group_outcome == "regression" then null else $commit_sha end),
              phase_9_outcome: $o.outcome,
              timestamp: $ts
            }
          # Attach phase_9_finding + revised_fix_proposal only when present
          + (if ($o.phase_9_finding // null) != null then {phase_9_finding: $o.phase_9_finding} else {} end)
          + (if ($o.revised_fix_proposal // null) != null then {revised_fix_proposal: $o.revised_fix_proposal} else {} end)
        )
')

echo "$apply_tuples" | \
    artifact-patch.py \
      --path "$artifact_path" --apply-fix-outcomes @-
```

On non-zero: log stderr verbatim to `trace.md`; do NOT retry — first-failure-halt means tuples 0..N-1 are already persisted, and the commit already happened; re-running would trip state-transition validation. Surface as the primary user error at end of 9e. Next run's leftover-attempted check catches the rest.

On success: surviving-group findings are `resolved` (verified) or
`open/partial`; reverted-group findings are `open/regression` with
`output_sha: null`. Proceed to 9e committed branch.

### 9e. Terminal cleanup (runs every time — §24.4)

Always runs; deterministic step order; each outcome logged; failures don't
abort the block. `commit_sha` from 9c distinguishes the two branches.

#### Committed branch (surviving groups exist, `commit_sha != null`)

1. **fix_attempts + state transitions** — done in 9d above.

2. **Re-tally `subagent_tokens` and `orchestrator_tokens`** so the
   artifact reflects cumulative spend across `/adamsreview:review` + this
   fix run (Phase 9a/9b/9c reviewer + any 9.pre.reconcile agent, plus
   every orchestrator turn since `review_started_at`). `tokens.jsonl` and
   transcript files are append-only; this is pure readback:

   ```bash
   tally-subagent-tokens.sh \
     --tokens-log "$tokens_log_path" \
     --artifact   "$artifact_path" \
     2>>"$trace_log_path" || printf 'tally_failed\n' >> "$trace_log_path"

   review_started_at=$(jq -r '.review_started_at // empty' "$artifact_path")

   orchestrator-tokens.sh \
     --artifact "$artifact_path" \
     --since    "$review_started_at" \
     2>>"$trace_log_path" || printf 'orchestrator_tally_failed\n' >> "$trace_log_path"
   ```

   Both failures are non-fatal (observability, not correctness) — PR
   totals may be stale but commit + transitions already landed. Same
   fallback as §11's `tokens: null`. `review_started_at` is loaded inline
   here (Phase 7 doesn't hoist it) so this block is self-contained.

3. **Schema-validate** the mutated artifact:

   ```bash
   if ! artifact-validate.sh --path "$artifact_path" 2>>"$trace_log_path"; then
       printf 'schema_invalid_post_9d\n' >> "$trace_log_path"
       # Keep going — artifact writes are atomic (can't be half-written);
       # validator is the canary.
   fi
   ```

4. **Re-render `artifact.md`:**

   ```bash
   artifact-render.py \
     --input "$artifact_path" --output "$review_dir/artifact.md" \
     2>>"$trace_log_path" || printf 'render_failed\n' >> "$trace_log_path"
   ```

5. **Phase 9 phases.jsonl record:**

   ```bash
   phase_9_elapsed=$(( $(date +%s) - phase_9_start_epoch ))
   by_disp=$(artifact-read.sh \
     --path "$artifact_path" --summary | jq -c '.counts_by_disposition')
   by_state=$(artifact-read.sh \
     --path "$artifact_path" --summary | jq -c '.counts_by_state')

   verified_count=$(echo "$group_outcomes" | jq '[.[] | select(.outcome == "verified")] | length')
   partial_count=$(echo "$group_outcomes" | jq '[.[] | select(.outcome == "partial")] | length')

   log-phase.sh \
     --review-dir "$review_dir" --phase 9 --name post-fix-review \
     --elapsed "$phase_9_elapsed" \
     --summary "$verified_count verified, $partial_count partial, $reverted_count regression (committed=$commit_sha)"

   reconciled_flag=$(echo "$fix_groups" | jq -r '.[0].id == "FG-RECON"')

   log-phase.sh \
     --review-dir "$review_dir" --phase 9 --record "$(jq -nc \
       --arg run_id "$run_id" --arg commit_sha "$commit_sha" \
       --arg reconciled "$reconciled_flag" \
       --argjson elapsed "$phase_9_elapsed" \
       --argjson by_disp "$by_disp" --argjson by_state "$by_state" \
       --argjson verified "$verified_count" \
       --argjson partial "$partial_count" \
       --argjson reverted "$reverted_count" \
       '{name:"post-fix-review", elapsed_sec:$elapsed,
         run_id:$run_id, commit_sha:$commit_sha,
         reconciled:($reconciled == "true"),
         counts_by_state:$by_state, counts_by_disposition:$by_disp,
         group_outcomes:{verified:$verified, partial:$partial, regression:$reverted}}')"
   ```

6. **`git push`** (PR mode only):

   ```bash
   push_failed=false
   if [[ "$mode" == "pr" ]]; then
       if ! git push 2>>"$trace_log_path"; then
           push_failed=true
           printf 'push_failed\n' >> "$trace_log_path"
       fi
   fi
   ```

   Failure doesn't undo the commit or artifact update — local record
   is already authoritative.

7. **`artifact-publish.sh`** (PR mode only):

   ```bash
   publish_failed=false
   if [[ "$mode" == "pr" && -n "$pr_number" ]]; then
       publish_args=(
         --mode pr
         --review-id "$review_id"
         --pr "$pr_number"
         --repo-slug "$repo_slug"
         --branch "$head_branch"
         --review-dir "$review_dir"
       )
       if [[ -n "$comment_id" ]]; then
           publish_args+=(--comment-id "$comment_id")
       fi
       if ! stdout=$(artifact-publish.sh "${publish_args[@]}" 2>>"$trace_log_path"); then
           publish_failed=true
           printf 'publish_failed\n' >> "$trace_log_path"
       else
           # Persist any newly-minted comment_id (first post on a local artifact).
           new_id=$(echo "$stdout" | jq -r '.comment_id // empty' 2>/dev/null || true)
           if [[ -n "$new_id" && -z "$comment_id" ]]; then
               artifact-patch.py \
                 --path "$artifact_path" --set "comment_id=$new_id"
               comment_id="$new_id"
           fi
       fi
   fi
   ```

7. **Pop stash** if `stash_taken=true`:

   ```bash
   stash_pop_conflict=false
   if [[ "${stash_taken:-false}" == "true" ]]; then
       if ! git stash pop 2>>"$trace_log_path"; then
           stash_pop_conflict=true
           printf 'stash_pop_conflict\n' >> "$trace_log_path"
           # Leave stash; user recovers via `git stash list`.
       fi
   fi
   ```

8. **Surface first failure** (ordered priority):

   - `push_failed` → "git push failed after a successful commit; run
     `git push` manually. Commit SHA: `$commit_sha`. See
     `$trace_log_path` for stderr."
   - `publish_failed` → "review comment could not be updated; commit
     and artifact are up to date. Run `artifact-publish.sh --mode pr
     --review-id $review_id` to retry, or update the PR comment
     manually. See `$trace_log_path`."
   - `stash_pop_conflict` → "git stash pop reported conflicts. Stashed
     changes preserved — `git stash list` / `git stash apply` once
     tree is in desired state."

   If none: mirror the rendered `artifact.md` to chat (full content, not
   a summary — matches Phase 6). Then a user-visible summary. On
   `reconciled_flag == true`, swap the first two lines for a reconcile-
   specific summary naming the original group count and overlap:

   > `/adamsreview:fix complete (reconciled).`
   >
   > Reconciled one merge pass covering $reconciled_finding_count
   > finding(s) across $reconciled_file_count file(s), merged from
   > $original_group_count originally-parallel fix groups that
   > collided on $overlap_count file(s). Outcome: $verified_count
   > verified, $partial_count partial, $reverted_count regression.

   Otherwise (non-reconciled run):

   > `/adamsreview:fix complete.`
   >
   > Committed: $surviving_count groups ($(attempted-count-verified+partial) findings → $verified_count verified, $partial_count partial).
   > Reverted:  $reverted_count groups ($regression-count findings → regression detected).

   Either variant ends with the same trailing block:

   > $((partial_count + regression_count)) findings remain open and retry-eligible.
   > Re-run /adamsreview:fix to attempt again with revised_fix_proposal context.
   >
   > Commit: `$commit_sha`
   > PR comment: (URL if PR mode AND publish succeeded)

#### No-commit branch (`commit_sha == null`)

Five degenerate paths: empty-eligibility (8.2), overlap-abort (9.pre),
overlap-inspect (9.pre), all-regression (9b), revert-failure (9b).
Overlap-abort via reconcile-fallback carries `reconcile_fallback=true`
for step 8.

1. **fix_attempts + state transitions** — already applied in the
   originating path:
   - Empty-eligibility: nothing to append.
   - Overlap-abort: `--apply-fix-outcomes` with `phase_9_outcome: null`
     applied in 9.pre step 3. (Same for reconcile-fallback, which routes
     through 9.pre.abort.)
   - Overlap-inspect: do NOT apply `--apply-fix-outcomes`. User asked
     for manual review; findings stay `attempted` and next run's
     leftover-attempted guard catches them. Unlike revert-failure, tree
     is in a known post-Phase-8 state.
   - All-regression: `--apply-fix-outcomes` with every tuple
     `phase_9_outcome: regression`, `output_sha: null`. Apply now so the
     artifact reflects reality before the rest of 9e runs:
     ```bash
     if [[ "$all_regression" == "true" ]]; then
         # 9d is skipped on all-regression, so $group_by_finding is not
         # yet computed. Build from $group_outcomes (set in 9b).
         group_by_finding=$(echo "$group_outcomes" | jq -c '
             [.[] as $g | $g.finding_ids[] | {id: ., group: $g.id, group_outcome: $g.outcome}]
         ')

         if [[ -n "${original_fix_group_by_finding:-}" ]] && \
            echo "$fix_groups" | jq -e '.[0].id == "FG-RECON"' >/dev/null; then
             group_by_finding=$(jq -nc \
                 --argjson synth "$group_by_finding" \
                 --argjson orig "$original_fix_group_by_finding" '
                 $synth | map(. as $s
                     | ($orig[] | select(.id == $s.id)) as $o
                     | {id: $s.id, group: $o.group, group_outcome: $s.group_outcome}
                 )
             ')
         fi
         # Tuples mirror committed-branch 9d logic: every one regression
         # with output_sha: null.
         apply_tuples=$(jq -nc \
             --arg run_id "$run_id" --arg input_sha "$input_sha" --arg ts "$ts" \
             --argjson outcomes "$phase_9a_outcomes" \
             --argjson group_map "$group_by_finding" '
             $outcomes | map(. as $o
                 | ($group_map[] | select(.id == $o.finding_id)) as $gm
                 | {id:$o.finding_id, run_id:$run_id, fix_group_id:$gm.group,
                    input_sha:$input_sha, output_sha:null,
                    phase_9_outcome:$o.outcome,
                    timestamp:$ts}
                 + (if ($o.phase_9_finding // null) != null then {phase_9_finding:$o.phase_9_finding} else {} end)
                 + (if ($o.revised_fix_proposal // null) != null then {revised_fix_proposal:$o.revised_fix_proposal} else {} end)
             )
         ')
         echo "$apply_tuples" | \
             artifact-patch.py \
               --path "$artifact_path" --apply-fix-outcomes @-
     fi
     ```
   - Revert-failure: do NOT apply `--apply-fix-outcomes` — tree is in an
     unknown state. Leave findings `attempted`; next run's leftover-
     attempted hard abort is the recovery path.

2. **Re-tally `subagent_tokens` and `orchestrator_tokens`** — same as
   committed branch step 2. Runs here too so the artifact reflects
   sub-agent spend from any 9.pre.reconcile / 9a agents dispatched before
   the degenerate path, plus orchestrator spend since `review_started_at`.

3. **Schema-validate** — same as committed branch step 3.

4. **Re-render `artifact.md`** — same as committed branch step 4.

5. **Phase 9 phases.jsonl record** — same shape as committed branch
   step 5 plus a degenerate-case tag:

   ```bash
   degen=""
   if [[ "${overlap_inspect:-false}" == "true" ]]; then degen="overlap_inspect"
   elif [[ "${overlap_abort:-false}" == "true" && "${reconcile_fallback:-false}" == "true" ]]; then degen="reconcile_fallback"
   elif [[ "${overlap_abort:-false}" == "true" ]]; then degen="overlap_abort"
   elif [[ "${all_regression:-false}" == "true" ]]; then degen="all_regression"
   elif [[ "${revert_failed:-false}" == "true" ]]; then degen="revert_failed"
   elif [[ "${eligible_count:-0}" -eq 0 ]]; then degen="no_eligible"
   fi
   ```

   Include `degenerate_case: $degen` in the phases.jsonl record.
   `commit_sha` is null.

6. **Pop stash** if `stash_taken=true` — BUT only when `revert_failed
   != true` AND `overlap_inspect != true`. Revert-failure leaves the tree
   in an unknown state; overlap-inspect leaves the post-Phase-8 tree with
   agent edits. Either way, popping on top risks conflicts that destroy
   user work. Leave the stash; note the ref in the user-visible error.

7. **No push, no publish** — no commit, nothing to ship. The artifact-
   side update still matters for next-run staleness and user inspection.

8. **Surface user-visible degenerate-case error:**

   - `overlap_abort` → the overlap message from 9.pre.abort step 5.
   - `reconcile_fallback` → the reconcile-fallback variant of 9.pre.abort
     step 5 (same recovery, first line names the fallback reason).
   - `overlap_inspect` → "Working tree left as-is for manual review.
     Overlapping files: `$overlap_files_snapshot_summary`. Findings
     remain `current_state=attempted` — next /adamsreview:fix hard-aborts
     with the leftover-attempted recovery prompt. When ready: either
     commit manually and run `artifact-patch.py --finding-id <id> --set
     current_state=open` on the affected findings, or `git restore . &&
     git clean -fd` to discard. Stash (if any) preserved at `git stash
     list`."
   - `all_regression` → "All $reverted_count fix groups regressed. Tree
     restored; no commit. `$(partial-plus-regression count)` findings are
     retry-eligible with revised_fix_proposal context. Re-run
     /adamsreview:fix." (Reconciled all-regression: merge reverted
     atomically — one "group" of many findings. Same message applies.)
   - `revert_failed` → "Per-group revert failed. Tree is in an unknown
     state — do NOT run destructive git commands without inspecting
     first. `$revert_failure_detail`. Stash (if any) preserved at `git
     stash list`. See `$trace_log_path`. Once resolved manually, reset
     `current_state` on affected findings and re-run /adamsreview:fix."
   - `no_eligible` → "No fix-eligible findings at threshold=$threshold.
     Nothing to do." (Clean no-op, no error prefix.)

Terminal invariant: regardless of branch, the on-disk artifact is
schema-valid and tracks git reality. A partially failed terminal block
may log errors to `trace.md` but cannot leave the artifact inconsistent.
