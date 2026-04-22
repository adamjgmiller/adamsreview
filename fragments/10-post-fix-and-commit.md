## Phase 9 — Post-fix review + commit

Phase 9 classifies each attempted finding, reverts any fix group
whose findings the reviewer flagged as regression, commits surviving
groups with per-group Phase-9 truth in the message, applies state
transitions + fix_attempts in one batched helper call, and runs the
deterministic terminal-cleanup block that keeps the artifact
consistent with git reality through every failure mode (§24.4).

### 9.pre. Touched-file overlap guard

Compute per-group `actual_touched` sets from the Phase 8 agent
results:

```bash
# For each group: union(files_modified, files_created)
fix_groups_with_actual=$(echo "$fix_groups" | jq -c '
    map(. + {actual_touched: ((.results.files_modified // []) + (.results.files_created // [])) | unique})
')
```

Detect files appearing in ≥ 2 groups' `actual_touched`:

```bash
overlap_files=$(echo "$fix_groups_with_actual" | jq -r '
    [ .[] | {g: .id, files: .actual_touched[]?} ]
    | group_by(.files)
    | map(select(length >= 2) | {file: .[0].files, groups: [.[].g]})
    | if length == 0 then "" else . end
')
```

Record a one-line sanity log noting whether any group's Phase 8 agent
emitted a `D <path>` entry in `git status --porcelain` (the
delete/rename prohibition in §19.8 is prompt-only; catching a leaked
delete here is the belt-and-suspenders). If any `D ` lines appear,
treat the run as overlap-aborted (same no-commit branch) with a
diagnostic naming the file(s):

```bash
deleted_paths=$(git status --porcelain | awk '/^( D|D )/ {print substr($0, 4)}')
if [[ -n "$deleted_paths" ]]; then
    overlap_files=$(jq -nc --arg reason "fix agent deleted file(s) — §19.8 forbids this in v1: $deleted_paths" \
        '[{file:"<delete-detected>", groups:[], reason:$reason}]')
fi
```

**If `overlap_files` is non-empty**:

The delete-leak sub-case (`deleted_paths` non-empty above) goes
straight to the abort branch — the v1 revert model can't handle
deletes and neither can the reconcile agent, so there is no merge
offer for that case. For plain file-overlap cases, offer the reviewer
a three-way choice via `AskUserQuestion` before running abort.

Snapshot the overlap summary for later audit (the commit message and
trace both want this even if reconcile succeeds and clears
`overlap_files`):

```bash
overlap_files_snapshot="$overlap_files"
overlap_files_snapshot_summary=$(echo "$overlap_files" | jq -r '
    [.[] | "\(.file) ← \(.groups | join(", "))"] | join("; ")
')
```

#### 9.pre.offer — three-way reviewer choice

Skipped entirely when `deleted_paths` is non-empty (delete-leak goes
straight to the abort branch below). Also skipped when the session has
no interactive capability — treat as `abort` default.

Render a short summary:

```
Fix agents touched overlapping files:

<overlap_files_snapshot_summary rendered one per line>

Choose how to proceed.
```

Dispatch `AskUserQuestion` with three options. Default highlighted on
Abort (safe default — matches current behavior):

- "⭐ Abort (recommended) — discard all edits, restore tree, reset state, re-run manually"
- "Reconcile — dispatch one merge agent to combine edits, then run full Phase 9 review"
- "Inspect — leave tree as-is for manual review (findings stay attempted; leftover-guard catches next run)"

Bind the result to `$overlap_choice` ∈ {`abort`, `reconcile`,
`inspect`}. On non-interactive fallback or user decline, treat as
`abort`.

Branch on `$overlap_choice`:

- `abort` → existing abort steps (§9.pre.abort below).
- `inspect` → §9.pre.inspect below.
- `reconcile` → §9.pre.reconcile below. On any reconcile failure
  (parse failure after one retry, or `unresolved_conflicts` non-empty
  in the agent's result), log the reason to `trace.md` and fall back
  to §9.pre.abort — findings are still at `current_state=attempted`
  so the abort tuples apply cleanly.

#### 9.pre.reconcile — one Opus merge agent

Dispatched when `$overlap_choice == reconcile`. Produces a reconciled
working tree and replaces `fix_groups` with a single synthetic
`FG-RECON` entry so 9a/9b/9c/9d can run unchanged against it. Each
finding's on-disk `fix_attempts[].fix_group_id` still carries its
ORIGINAL FG-N (schema's `^FG-[0-9]+$` rejects `FG-RECON`) via the
snapshot captured here.

```bash
phase_9_reconcile_start_epoch=$(date +%s)

# Snapshot original group-per-finding for 9d schema compat.
original_fix_group_by_finding=$(echo "$fix_groups_with_actual" | jq -c '
    [.[] as $g | $g.finding_ids[] | {id: ., group: $g.id}]
')
```

Compose the merge-agent prompt (all context values are already in
working context):

```
You are the Phase 9 reconciliation agent. Parallel fix-group agents
just edited the working tree and collided on one or more shared
files. The tree is currently in a last-write-wins state — it does NOT
cleanly represent any single group's intent. Your job: produce a
working tree that satisfies EVERY finding from EVERY group, without
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

1. For each non-overlapping file, keep the current contents. Do NOT
   re-edit files that only one group touched unless you detect a
   regression caused by a change elsewhere.

2. For each overlapping file:
   a. Read the file as it currently stands.
   b. Read the original pre-Phase-8 content: `git show $input_sha:<path>`.
   c. Identify each group's intent for that file from its
      per_finding.edits_applied + verification_results and the
      finding's fix_proposal.files_to_modify (look at `what` / `why`).
   d. Produce a reconciled file that applies ALL intents. If two
      intents conflict substantively, prefer the version that
      satisfies both findings' evidence; if truly incompatible, pick
      the higher-score_phase4 finding's version and include the other
      finding's id in unresolved_conflicts with a concrete reason.

3. After editing, re-verify every finding across all groups by running
   its validation_result.verification_context.how_to_verify_fix steps
   (grep / Read only — no mutating calls). Report per-step pass/fail.

4. Adjacent-regression check: for each file you reconciled, read the
   changed hunks ±20 lines and verify no new bug (inverted condition,
   off-by-one, null-deref, resource leak, ordering swap, etc.) was
   introduced by the merge.

5. Convention-drift check: for each entry in any finding's
   blast_radius.parallel_paths, diff your reconciled file against that
   parallel path for boundary-condition consistency (loop bounds, null
   semantics, ordering, error handling, direction of COALESCE args).
   Divergence from cross-parallel convention is a bug the merge just
   wrote — fix it before returning.

6. If CLAUDE.md defines verification_commands for any changed file,
   run the matching ones; report exit codes.

7. DO NOT run git commands. DO NOT delete or rename files. Edit / Write
   only. The orchestrator handles staging, commit, and revert. If a
   finding genuinely requires deletion or rename, list it in
   unresolved_conflicts with reason "requires delete/rename — manual".

---

Return JSON of exactly this shape (matches Phase 8's per-group
contract so the orchestrator can feed it straight into Phase 9a):

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
- If unresolved_conflicts is non-empty, the orchestrator will abort
  the reconcile and fall back to the standard overlap-abort recovery
  path — return them explicitly rather than silently pick a winner
  without saying so.
```

Dispatch ONE `Agent` tool-use with `subagent_type: general-purpose`,
`model: opus`.

After the agent returns:

1. **Log tokens** via `log-tokens.sh --phase phase_9_reconcile
   --agent-role reconcile --model opus`. (Match Phase 8's §8.6 step 1
   pattern: always log tokens before branching on content, so token
   cost is accounted even when the output fails to parse.)

2. **Parse JSON into `$reconcile_result`.** Light repair allowed
   (strip code fences, extract object). One retry with a "Return only
   the JSON object described in the schema" addendum on parse failure.
   On success, `$reconcile_result` holds the agent's JSON object
   (with `per_finding`, `files_modified`, `files_created`,
   `per_file_summary`, `unresolved_conflicts`, `reconcile_notes`).

3. **Fallback to abort** on any of:
   - Second parse failure (both attempts returned unparsable output).
   - `$reconcile_result.unresolved_conflicts` non-empty.
   - `$reconcile_result.per_finding` missing any attempted finding_id
     (compare against the union of finding_ids from the original
     `fix_groups`).
   - Agent-returned `files_modified` and `files_created` share any
     entry (must be disjoint per the prompt contract).
   - Post-reconcile working tree is empty vs. `$input_sha` — i.e.,
     `git status --porcelain` produces no output. The agent returned
     valid JSON but made zero actual edits, a silent no-op.

   On any trigger, set `reconcile_fallback_reason` to one of
   `parse_failure` | `unresolved_conflicts` | `missing_findings` |
   `overlapping_files_arrays` | `empty_diff`, log it, and set the
   fallback flag so 9e surfaces the fallback-specific message:

   ```bash
   reconcile_fallback_reason="<pick one of: parse_failure |
     unresolved_conflicts | missing_findings |
     overlapping_files_arrays | empty_diff>"
   printf 'reconcile_fallback reason=%s\n' "$reconcile_fallback_reason" \
       >> "$trace_log_path"
   reconcile_fallback=true
   ```

   Then drop into §9.pre.abort — the attempted findings are still
   `current_state=attempted` on disk, so the abort tuples apply
   cleanly. The user sees a reconcile_fallback user-visible message
   from 9e step 8 that names `$reconcile_fallback_reason`.

4. **On success** (no fallback trigger fired above), replace
   `fix_groups` with a synthetic single entry and clear overlap so
   the rest of Phase 9 runs against the reconciled tree.

   The synthetic entry's `files_modified` / `files_created` are built
   from **`git status --porcelain`** — every file git sees differs
   from `$input_sha` right now — classified by authoritative git-
   truth: `git cat-file -e $input_sha:<path>` decides whether the
   file existed at the clean baseline (→ `files_modified`, revert
   via `git checkout --`) or not (→ `files_created`, revert via
   `rm -f`).

   Why `git status --porcelain` instead of agent self-reports:
   - **Catches everything actually changed** — Phase 8 agents create
     files via `Write` without staging (untracked but git-visible)
     and modify files without staging (unstaged mods but git-visible).
     Post-reconcile, git sees all of it. Phase 7's clean-tree gate +
     optional stash guarantees the only changes git sees are from the
     agents, so this set is complete and contains no user work.
   - **Catches rogue reconcile-agent edits** — if the merge agent
     silently edits a file outside any Phase 8 group's touched set
     (e.g., adjacency fix, hallucinated scope), git status sees it
     even if the agent's `files_modified` / `files_created` arrays
     omit it. On regression, 9b reverts it; on commit, 9c stages it.
   - **Robust against agent-report disagreement** — if Phase 8 Group
     A reports X as "created" but Group B reports X as "modified",
     only one of them is right about X's state at `$input_sha`. Git
     is the ground truth; misreports can't mis-classify X and cause
     a destructive revert.
   - **`git diff` can't substitute** — `git diff $input_sha` ignores
     untracked files. We need `git status --porcelain`.

   ```bash
   # Candidate set: every path git status sees as changed vs HEAD
   # (== $input_sha since Phase 7 took a clean-tree baseline + no
   # commits between input_sha and reconcile completion).
   # Strip the 3-char status prefix; keep every non-empty path.
   # Handles tracked-modified (" M <path>"), untracked ("?? <path>"),
   # and any other non-delete status. Deletes are already filtered
   # out by 9.pre's delete-leak short-circuit (which goes straight
   # to abort; we never reach reconcile with a D status).
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

   # Bash-array-to-JSON (handle empty arrays explicitly — `printf` on
   # an unset array name under `set -u` errors with an unbound-
   # variable trip).
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
   # Use the synthetic FG-RECON's files_planned — that's the agent-union
   # of Phase 8 + reconcile files, i.e., the full set 9b will revert if
   # regression. Don't use $reconcile_result alone (undercounts Phase 8
   # files the merge agent chose not to re-edit).
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

6. Proceed to 9a normally. 9a's `git diff HEAD` snapshot captures the
   reconciled tree; 9a's §19.9 per-finding evidence re-trace +
   adjacent-regression + convention-drift sweeps serve as the fresh
   post-reconcile review without any additional phase.

#### 9.pre.inspect — leave tree as-is

Dispatched when `$overlap_choice == inspect`. The user wants to look
at the post-Phase-8 tree themselves — no `--apply-fix-outcomes` call,
no revert, no commit. Findings stay `current_state=attempted` on disk;
the next `/adams-review:fix` invocation's Phase 7 step 4 hard abort is
the recovery path. Unlike `abort`, no audit fix_attempts are appended
— the user may hand-resolve and wants a clean slate.

```bash
printf 'overlap_inspect chosen files=%s\n' "$overlap_files_snapshot_summary" >> "$trace_log_path"
commit_sha=null
reverted_groups='[]'
surviving_groups='[]'
phase_9a_outcomes='[]'
overlap_inspect=true
```

Jump to 9e no-commit branch. The stash-pop skip matches revert-failure
semantics (leave stash in place — tree has agent edits and popping
could create conflicts); 9e step 8's `overlap_inspect` case surfaces a
tailored message.

#### 9.pre.abort — overlap-abort (current behavior; default)

Reached from `$overlap_choice == abort`, from a delete-leak
short-circuit, or from a reconcile fallback. Steps 1–5 below are the
original abort logic unchanged from prior revisions.

1. Log the overlapping files + owning groups to `trace.md` with a
   clear orchestrator-error prefix:

   ```bash
   printf 'overlap_abort %s\n' "$overlap_files_snapshot" >> "$trace_log_path"
   ```

2. Skip 9a, 9b, 9c entirely — no per-finding Phase 9 review, no
   revert, no stage, no commit.

3. Build `--apply-fix-outcomes` tuples for every finding attempted
   this run (every eligible finding from 8.1 — they're all
   `current_state=attempted` on disk from 8.4). Each tuple follows
   this shape (tuple required-keys per §21.2):

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

   For each eligible finding id, look up which `fix_group_id` it
   belonged to (from `fix_groups[].finding_ids`). Emit one tuple per
   finding. Apply in one batched call — `--apply-fix-outcomes`
   preserves `current_state=attempted` on null outcome (§21.2 / §4
   Phase 9.pre step 5):

   ```bash
   ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   overlap_file_list=$(echo "$overlap_files_snapshot" | jq -r '[.[].file] | join(", ")')
   phase_9_finding_text="run aborted: fix agents touched overlapping files across groups — $overlap_file_list"

   # When reconcile was attempted and fell back to abort,
   # $original_fix_group_by_finding is populated (set in 9.pre.reconcile
   # step 1, before dispatch — so it's present for every fallback path).
   # Prefer it over iterating fix_groups_with_actual because it's the
   # authoritative snapshot of the pre-reconcile finding→group mapping.
   # For a plain abort (never entered reconcile), the snapshot is unset;
   # fall through to fix_groups_with_actual which carries the original
   # per-group shape.
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

4. Set working-set vars for the 9e no-commit branch. If the abort
   path was reached via reconcile fallback, tag it so 9e's
   user-visible message surfaces the fallback reason instead of the
   plain overlap message:

   ```bash
   commit_sha=null
   reverted_groups='[]'
   surviving_groups='[]'
   phase_9a_outcomes='[]'
   overlap_abort=true
   # reconcile_fallback is set to true by 9.pre.reconcile step 3 when
   # the merge agent could not produce a valid reconciliation. It's
   # unset (empty) on a plain abort.
   ```

5. Jump to 9e **no-commit branch** (step numbering 9e.no-commit
   below). User-visible error after terminal cleanup:

   > ERROR: /adams-review:fix aborted before commit — fix agents
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
   >   4. Re-run /adams-review:fix.

   For `reconcile_fallback`, swap the first line for the variant
   below, interpolating `$reconcile_fallback_reason` (set in
   §9.pre.reconcile step 3):

   > ERROR: /adams-review:fix — reconcile attempt failed, aborted
   > before commit. Reason: `$reconcile_fallback_reason`. The working
   > tree still holds the Phase-8 agent edits plus any partial edits
   > the merge agent made before failing; recovery steps 1–4 above
   > apply unchanged (`git restore .` + `git clean -fd` discards
   > everything). See `$trace_log_path` for the merge agent's raw
   > output.

**If `overlap_files` is empty**: proceed to 9a.

### 9a. Phase 9 post-fix review (one Opus sub-agent)

Dispatch ONE `Agent` tool-use with `subagent_type: general-purpose`,
`model: opus`, carrying the §19.9 prompt. All attempted findings + all
Phase 8 per-group results + the unstaged working-tree diff get
embedded into the prompt.

Capture the diff snapshot before dispatch:

```bash
phase_9_start_epoch=$(date +%s)
working_tree_diff=$(git diff HEAD)
```

**Prompt body:**

```
You are the Phase 9 post-fix reviewer. Fix groups have edited the
working tree; nothing has been committed yet. Review each attempted
finding against the current working tree state and classify the outcome.

Run identity:
- run_id: $run_id
- input_sha: $input_sha

Attempted findings and their validation contexts:
<jq output: each attempted finding's id, file, line_range, claim, plus
 from validation_result — the evidence array, the blast_radius block
 (especially parallel_paths and invariants_at_stake — checklist step 5
 needs these to catch adjacent regressions), the fix_proposal block
 (especially files_to_modify — checklist step 2 verifies every planned
 file received an edit), and the verification_context block — plus the
 fix group id it belongs to, cross-referenced from fix_groups>

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
   pass (per the agent's per_finding.verification_results)? Any
   failure → `partial`.

4. Did project verification_commands pass (if run)? Failure → `partial`
   or `regression` depending on nature.

5a. Adjacent-regression sweep (local). Does any code adjacent to the
    fix (same file, changed hunk ±20 lines) now contain a new issue
    that wasn't there before the fix? If so → `regression`, describe
    concretely.

5b. Convention-drift sweep (cross-file).
    (i) For each entry in `blast_radius.parallel_paths` on the finding,
        diff the fix against that path for boundary conditions (loop
        bounds, error handling, null semantics, ordering, direction of
        operation — e.g., `COALESCE(a, b)` vs. `COALESCE(b, a)`). Any
        divergence from the cross-parallel convention → `regression`,
        name the divergent boundary.
    (ii) If the fix introduces a new function, class/method, or
         substantial block (new loop over a domain, new query over a
         table): grep/Glob the repo for existing code doing similar
         work (matching verbs on the same domain noun — e.g., a new
         `cleanup…` function → grep for other functions that iterate
         the same tables; a new loop over a date range → grep for
         other date-range loops). Diff boundary conditions.
         `parallel_paths` was computed on the *bug*, not the *fix* —
         the fix can introduce new parallels the validator didn't
         anticipate. Divergence → `regression`.

6. Premise audit of added inline comments. Every comment the fix added
   in the same hunk as a logic change that asserts a fact about
   surrounding code (e.g., `// X because Y`, `// always Z`) is a
   falsifiable claim. Locate the referenced code via Read/grep and
   verify. False premise → `regression` with `phase_9_finding` naming
   the false premise and the contradicting code location. Wrong
   inline justifications propagate to future readers and are worse
   than no comment. Pre-existing comments (context lines in the diff,
   not `+` lines) are out of scope.

Classification priority: regression > partial > verified. If in doubt
between verified and partial, choose partial.

For partial or regression: fill `phase_9_finding` (concrete
description of what's missing / what broke) and `revised_fix_proposal`
(updated plan for the next retry — matching the schema's fix_proposal
shape: {approach, files_to_modify: [{file, what, why}, ...]}).

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
2. Parse the JSON output; light repair + one retry on parse failure.
3. On full parse failure after retry: treat every attempted finding
   as `outcome: partial` with
   `phase_9_finding: "phase 9 reviewer parse failure — manual audit
   required"` and no `revised_fix_proposal`. Log an orchestrator-error
   prefixed line to `trace.md`. The run continues (partial is
   retry-eligible; user re-runs with fresh context).

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
    # Restore each modified file to its pre-Phase-8 content
    for f in $(echo "$row" | jq -r '.files_modified[]?'); do
        if ! git checkout -- "$f" 2>>"$trace_log_path"; then
            revert_failed=true
            revert_failure_detail="$revert_failure_detail; git checkout -- $f failed in $group_id"
        fi
    done
    # Remove each created file
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

**On revert failure** (§24.2): do NOT commit; do NOT proceed to 9c.
Log to trace, set `revert_failure=true`, jump to 9e no-commit branch
leaving the tree as-is. The user inspects manually. Do NOT pop stash
(tree is in an unknown state).

**All-regression degenerate case** (`surviving_count == 0` AND
`reverted_count >= 1`): reverts already ran (above); tree is restored.
Nothing to commit. Set:

```bash
commit_sha=null
all_regression=true
```

Jump to 9e no-commit branch. (9e will build `--apply-fix-outcomes`
tuples for every attempted finding with `phase_9_outcome: regression`,
`output_sha: null` — see 9e no-commit step 1.)

**Mixed case** (`surviving_count >= 1`): proceed to 9c.

### 9c. Stage + commit surviving groups

Pre-flight the working tree:

```bash
git status --porcelain >> "$trace_log_path"
```

Collect the file list for each surviving group. Any file that also
appeared in a reverted group is excluded (the revert wins — §9c step
2 "exclude any file that also appeared in a reverted group"):

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

**Build the commit message.** The message carries per-group Phase 9
truth for the whole run (committed + reverted), matching the §4 Phase
9c template. Use a heredoc file rather than `-m "$(...)"` so
embedded `$`, backticks, and quotes in the finding claims don't need
careful escaping:

```bash
msg_file="/tmp/adams-fix-msg-$run_id.txt"
reconciled_flag=$(echo "$fix_groups" | jq -r '.[0].id == "FG-RECON"')
{
    if [[ "$reconciled_flag" == "true" ]]; then
        # Reconcile run — surviving_groups contains the single FG-RECON
        # entry, reverted_groups is empty (the reconcile outcome is
        # all-or-nothing). Commit message names the reconciled state.
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
            # Emit one bullet per surviving group. The claim-snippet is
            # the first finding's claim truncated to 60 chars so the
            # message stays readable even on dense groups.
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
        echo "Re-run /adams-review:fix to address partial and regression findings (retry with revised_fix_proposal context)."
    fi
} > "$msg_file"
```

**Commit strategy** (per §13.6):

- Default: one combined commit.
  ```bash
  git commit -F "$msg_file"
  commit_sha=$(git rev-parse HEAD)
  ```

- `--granular-commits` (opt-in): one commit per surviving group. For
  each group:
  1. Reset the index to HEAD, then add only that group's files.
  2. Build a scoped message using the same template shape but naming
     only the one group (both committed-section and outcome lines
     filtered to it; the run-level "reverted" section stays in the
     first granular commit's message so the history record is
     complete).
  3. Commit. Capture its SHA. The final `commit_sha` is the HEAD of
     the chain (last commit) — downstream 9d writes use this for every
     surviving finding's `output_sha`, because they all landed in the
     same chain of commits starting from `input_sha`.

Capture `commit_sha` IMMEDIATELY via `git rev-parse HEAD` after the
last `git commit`. **Do NOT run anything else before this capture** —
if a tool fails between commit and capture, the artifact's next run
can't prove which SHA the survivors landed at.

Remove the temp message file:

```bash
rm -f "$msg_file"
```

### 9d. State transitions + fix_attempts append (batched)

Build one `--apply-fix-outcomes` tuple array. Every attempted finding
gets one tuple. For findings in surviving groups: `output_sha =
commit_sha`, `phase_9_outcome = {verified|partial}`. For findings in
reverted (regression) groups: `output_sha = null`, `phase_9_outcome =
regression`. The helper enforces the regression-output-sha-null
invariant.

```bash
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Map finding_id → {group_id, group_outcome} for quick lookup
group_by_finding=$(echo "$group_outcomes" | jq -c '
    [.[] as $g | $g.finding_ids[] | {id: ., group: $g.id, group_outcome: $g.outcome}]
')

# On a reconciled run, $group_by_finding carries FG-RECON as the group
# — which the schema's ^FG-[0-9]+$ regex rejects. Substitute each
# finding's ORIGINAL fix_group_id from the snapshot captured in
# 9.pre.reconcile while keeping the reconcile-aggregated group_outcome.
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

On non-zero: the helper's first-failure-halts semantics means some
tuples may already be applied. Log stderr to `trace.md` verbatim, do
NOT retry (the commit already happened), and surface as the primary
user error at the end of 9e. The next run's leftover-attempted check
will catch whatever's still in `attempted`.

On success: every surviving-group finding is `resolved` (verified)
or `open/partial`; every reverted-group finding is `open/regression`
with `output_sha: null`. Proceed to 9e committed branch.

### 9e. Terminal cleanup (runs every time — §24.4)

The cleanup block always runs; its steps are deterministic in order;
each step's outcome is logged; failures do not abort the block.
`commit_sha` captured in 9c distinguishes the two branches.

#### Committed branch (surviving groups exist, `commit_sha != null`)

1. **fix_attempts + state transitions** — done in 9d above.

2. **Re-tally `subagent_tokens` and `orchestrator_tokens`** so the
   published artifact reflects cumulative spend across `/adams-review:review`
   + this fix run (Phase 9a/9b/9c reviewer + any 9.pre.reconcile agent,
   plus every orchestrator turn since `review_started_at`).
   `tokens.jsonl` is append-only and the transcript files on disk are
   append-only too — every sub-agent dispatch and every orchestrator
   turn already logged itself; this is a pure readback:

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

   Both failures are non-fatal (observability, not correctness): the PR
   comment's totals may stay stale but the commit and state transitions
   already landed. Same fallback philosophy as §11's `tokens: null`.
   `review_started_at` is loaded inline here (Phase 7 doesn't hoist it
   into the working set by default) so this block is self-contained
   regardless of what earlier fragments loaded.

3. **Schema-validate** the mutated artifact:

   ```bash
   if ! artifact-validate.sh --path "$artifact_path" 2>>"$trace_log_path"; then
       printf 'schema_invalid_post_9d\n' >> "$trace_log_path"
       # Dump for debugging but keep going — artifact is atomic so it
       # can't be half-written; the validator is the canary.
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

   Failure does NOT undo the commit or the artifact update — the
   local record is already authoritative.

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
           # Persist any newly-minted comment_id (first post on a local artifact)
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
           # Leave the stash in place; user recovers via `git stash list`.
       fi
   fi
   ```

8. **Surface first failure** (ordered priority):

   - `push_failed` → "git push failed after a successful commit; run
     `git push` manually. Commit SHA: `$commit_sha`. See
     `$trace_log_path` for stderr."
   - `publish_failed` → "the review comment could not be updated; the
     commit and artifact are up to date. Run
     `artifact-publish.sh --mode pr --review-id $review_id` to retry,
     or update the PR comment manually. See `$trace_log_path`."
   - `stash_pop_conflict` → "git stash pop reported conflicts. Your
     stashed changes are preserved — run `git stash list` / `git
     stash apply` to recover once the tree is in the state you want."

   If none: mirror the rendered `artifact.md` to chat (full content,
   not a summary — matches Phase 6's mirror step), then print a
   user-visible summary. On a reconciled run (`reconciled_flag ==
   true`), swap the first two lines for a reconcile-specific summary
   naming the original group count and the overlap:

   > `/adams-review:fix complete (reconciled).`
   >
   > Reconciled one merge pass covering $reconciled_finding_count
   > finding(s) across $reconciled_file_count file(s), merged from
   > $original_group_count originally-parallel fix groups that
   > collided on $overlap_count file(s). Outcome: $verified_count
   > verified, $partial_count partial, $reverted_count regression.

   Otherwise (non-reconciled run):

   > `/adams-review:fix complete.`
   >
   > Committed: $surviving_count groups ($(attempted-count-verified+partial) findings → $verified_count verified, $partial_count partial).
   > Reverted:  $reverted_count groups ($regression-count findings → regression detected).

   Either variant ends with the same trailing block:

   > $((partial_count + regression_count)) findings remain open and retry-eligible.
   > Re-run /adams-review:fix to attempt again with revised_fix_proposal context.
   >
   > Commit: `$commit_sha`
   > PR comment: (URL if PR mode AND publish succeeded)

#### No-commit branch (`commit_sha == null`)

Reached by one of five degenerate paths: empty-eligibility (8.2),
overlap-abort (9.pre), overlap-inspect (9.pre), all-regression (9b),
revert-failure (9b). Overlap-abort reached via reconcile-fallback sets
an extra `reconcile_fallback=true` flag that step 8 reads.

1. **fix_attempts + state transitions** — already applied in the
   originating path:
   - Empty-eligibility: no findings touched; nothing to append.
   - Overlap-abort: `--apply-fix-outcomes` with `phase_9_outcome:
     null` applied in 9.pre step 3. (Same for reconcile-fallback,
     which routes into 9.pre.abort after logging the reason.)
   - Overlap-inspect: do NOT apply `--apply-fix-outcomes`. The user
     asked to leave the tree for manual review; findings stay at
     `current_state=attempted` and the next run's leftover-attempted
     guard catches them. Unlike revert-failure, the tree is in a
     known post-Phase-8 state — just unresolved.
   - All-regression: `--apply-fix-outcomes` with every tuple
     `phase_9_outcome: regression`, `output_sha: null`. Apply now
     before the rest of 9e runs so the artifact reflects reality:
     ```bash
     if [[ "$all_regression" == "true" ]]; then
         # 9d is skipped on all-regression, so $group_by_finding is not
         # yet computed. Build it fresh from $group_outcomes (already
         # set in 9b).
         group_by_finding=$(echo "$group_outcomes" | jq -c '
             [.[] as $g | $g.finding_ids[] | {id: ., group: $g.id, group_outcome: $g.outcome}]
         ')

         # On a reconciled run where every finding regressed, FG-RECON
         # has been reverted and the freshly-built $group_by_finding
         # carries FG-RECON (which fails the schema ^FG-[0-9]+$ regex).
         # Substitute each finding's ORIGINAL fix_group_id from the
         # 9.pre.reconcile snapshot. Non-reconciled runs skip this
         # override.
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
         # Build tuples mirroring the committed branch's 9d logic but
         # with every tuple regression + null output_sha.
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
   - Revert-failure: do NOT apply `--apply-fix-outcomes` — the tree
     is in an unknown state. Leave findings as `attempted` (the
     leftover-attempted hard abort on next run is the deterministic
     recovery path).

2. **Re-tally `subagent_tokens` and `orchestrator_tokens`** — same as
   committed branch step 2. Runs here too so the artifact (and its
   downstream re-render) reflect sub-agent spend from any
   9.pre.reconcile / 9a agents that dispatched before the degenerate
   path was taken, and orchestrator spend from every turn since
   `review_started_at`.

3. **Schema-validate** — same as committed branch step 3.

4. **Re-render `artifact.md`** — same as committed branch step 4.

5. **Phase 9 phases.jsonl record** — same shape as committed branch
   step 5 but include a degenerate-case tag:

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

6. **Pop stash** if `stash_taken=true` — BUT only if
   `revert_failed != true` AND `overlap_inspect != true`. Revert
   failure left the tree in an unknown state; overlap-inspect left
   the tree in the post-Phase-8 state with agent edits. In either
   case, popping a stash on top risks conflicts that could destroy
   user work. Leave the stash in place and note the ref in the
   user-visible error below.

7. **No push, no publish** — no new commit, nothing to ship. The
   artifact-side update is still valuable for the next run's
   staleness logic and for user inspection.

8. **Surface user-visible degenerate-case error:**

   - `overlap_abort` → the overlap message from 9.pre.abort step 5
     (above).
   - `reconcile_fallback` → the reconcile-fallback variant of the
     overlap message from 9.pre.abort step 5 (above) — same recovery
     steps, first line names the fallback reason.
   - `overlap_inspect` → "Working tree left as-is for manual review.
     Overlapping files: `$overlap_files_snapshot_summary`. Findings
     remain `current_state=attempted` on disk — the next
     /adams-review:fix run will hard-abort with a leftover-attempted
     recovery prompt. When you're ready: either commit what you want
     manually and run `artifact-patch.py --finding-id <id> --set
     current_state=open` on the affected findings, or `git restore .
     && git clean -fd` to discard everything the agents did. Your
     stash (if any) is preserved at `git stash list`."
   - `all_regression` → "All $reverted_count fix groups regressed.
     Working tree restored; no commit made.
     `$(partial-plus-regression count)` findings are retry-eligible
     with revised_fix_proposal context. Re-run /adams-review:fix."
     (On a reconciled all-regression, the reconciled merge was
     reverted atomically — one "group" of many findings. Same
     message applies.)
   - `revert_failed` → "Per-group revert failed. The working tree is
     in an unknown state — do NOT run any destructive git commands
     without inspecting first. `$revert_failure_detail`. Your stash
     (if any) is preserved at `git stash list`. See
     `$trace_log_path` for the full revert log. Once you've resolved
     manually, reset `current_state` on the affected findings and
     re-run /adams-review:fix."
   - `no_eligible` → "No fix-eligible findings at threshold=$threshold.
     Nothing to do." (No error prefix — it's a clean no-op.)

### Working-set delta after Phase 9

- Committed branch: `commit_sha` captured; every touched finding is
  either `resolved` (verified) or `open/partial` or `open/regression`;
  `fix_attempts` appended per finding; artifact re-rendered;
  (PR mode) push + publish attempted; (if stashed) stash popped;
  user-visible summary mirrored to chat.
- No-commit branch: `commit_sha=null`; state either at `attempted`
  (overlap-abort / reconcile-fallback — next run catches),
  `attempted` (overlap-inspect — next run catches, no audit fix_attempts),
  `open/regression` (all-regression, including a regressed reconcile
  which reverts the full FG-RECON file set atomically), or
  `attempted` (revert-failure — manual recovery);
  artifact re-rendered with the degenerate case reflected; stash
  popped unless revert-failure or overlap-inspect; user-visible error
  surfaced.

Terminal invariant (§24.4): regardless of which branch ran, the
artifact on disk is schema-valid and tracks git reality. A partially
failed terminal block can log errors to `trace.md` but cannot leave
the artifact inconsistent.
