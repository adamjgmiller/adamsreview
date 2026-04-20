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

**If `overlap_files` is non-empty** — short-circuit before 9a runs:

1. Log the overlapping files + owning groups to `trace.md` with a
   clear orchestrator-error prefix:

   ```bash
   printf 'overlap_abort %s\n' "$overlap_files" >> "$trace_log_path"
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
   overlap_file_list=$(echo "$overlap_files" | jq -r '[.[].file] | join(", ")')
   phase_9_finding_text="run aborted: fix agents touched overlapping files across groups — $overlap_file_list"

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

   echo "$overlap_abort_tuples" | \
       ~/.claude/commands/_shared/tools/artifact-patch.py \
         --path "$artifact_path" --apply-fix-outcomes @-
   ```

4. Set working-set vars for the 9e no-commit branch:

   ```bash
   commit_sha=null
   reverted_groups='[]'
   surviving_groups='[]'
   phase_9a_outcomes='[]'
   overlap_abort=true
   ```

5. Jump to 9e **no-commit branch** (step numbering 9e.no-commit
   below). User-visible error after terminal cleanup:

   > ERROR: /adams-review-fix aborted before commit — fix agents
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
   >   4. Re-run /adams-review-fix.

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

5. Does any code adjacent to the fix (same file, changed hunk ±20
   lines) now contain a new issue that wasn't there before the fix? If
   so → `regression`, describe concretely.

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
{
    echo "fix: address code review findings ($surviving_count groups committed, $reverted_count reverted)"
    echo
    if [[ "$surviving_count" -gt 0 ]]; then
        echo "Fix groups (committed):"
        # Emit one bullet per surviving group. The claim-snippet is the
        # first finding's claim truncated to 60 chars so the message
        # stays readable even on dense groups.
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
    # Phase 9 summary line
    verified_count=$(echo "$group_outcomes" | jq '[.[] | select(.outcome == "verified")] | length')
    partial_count=$(echo "$group_outcomes" | jq '[.[] | select(.outcome == "partial")] | length')
    echo "Post-fix review: $verified_count/$surviving_count groups verified complete; $partial_count group(s) partial; $reverted_count group(s) reverted."
    if [[ "$partial_count" -gt 0 || "$reverted_count" -gt 0 ]]; then
        echo "Re-run /adams-review-fix to address partial and regression findings (retry with revised_fix_proposal context)."
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
    ~/.claude/commands/_shared/tools/artifact-patch.py \
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

2. **Schema-validate** the mutated artifact:

   ```bash
   if ! ~/.claude/commands/_shared/tools/artifact-validate.sh --path "$artifact_path" 2>>"$trace_log_path"; then
       printf 'schema_invalid_post_9d\n' >> "$trace_log_path"
       # Dump for debugging but keep going — artifact is atomic so it
       # can't be half-written; the validator is the canary.
   fi
   ```

3. **Re-render `artifact.md`:**

   ```bash
   ~/.claude/commands/_shared/tools/artifact-render.py \
     --input "$artifact_path" --output "$review_dir/artifact.md" \
     2>>"$trace_log_path" || printf 'render_failed\n' >> "$trace_log_path"
   ```

4. **Phase 9 phases.jsonl record:**

   ```bash
   phase_9_elapsed=$(( $(date +%s) - phase_9_start_epoch ))
   by_disp=$(~/.claude/commands/_shared/tools/artifact-read.sh \
     --path "$artifact_path" --summary | jq -c '.counts_by_disposition')
   by_state=$(~/.claude/commands/_shared/tools/artifact-read.sh \
     --path "$artifact_path" --summary | jq -c '.counts_by_state')

   verified_count=$(echo "$group_outcomes" | jq '[.[] | select(.outcome == "verified")] | length')
   partial_count=$(echo "$group_outcomes" | jq '[.[] | select(.outcome == "partial")] | length')

   ~/.claude/commands/_shared/tools/log-phase.sh \
     --review-dir "$review_dir" --phase 9 --name post-fix-review \
     --elapsed "$phase_9_elapsed" \
     --summary "$verified_count verified, $partial_count partial, $reverted_count regression (committed=$commit_sha)"

   ~/.claude/commands/_shared/tools/log-phase.sh \
     --review-dir "$review_dir" --phase 9 --record "$(jq -nc \
       --arg run_id "$run_id" --arg commit_sha "$commit_sha" \
       --argjson elapsed "$phase_9_elapsed" \
       --argjson by_disp "$by_disp" --argjson by_state "$by_state" \
       --argjson verified "$verified_count" \
       --argjson partial "$partial_count" \
       --argjson reverted "$reverted_count" \
       '{name:"post-fix-review", elapsed_sec:$elapsed,
         run_id:$run_id, commit_sha:$commit_sha,
         counts_by_state:$by_state, counts_by_disposition:$by_disp,
         group_outcomes:{verified:$verified, partial:$partial, regression:$reverted}}')"
   ```

5. **`git push`** (PR mode only):

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

6. **`artifact-publish.sh`** (PR mode only):

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
       if ! stdout=$(~/.claude/commands/_shared/tools/artifact-publish.sh "${publish_args[@]}" 2>>"$trace_log_path"); then
           publish_failed=true
           printf 'publish_failed\n' >> "$trace_log_path"
       else
           # Persist any newly-minted comment_id (first post on a local artifact)
           new_id=$(echo "$stdout" | jq -r '.comment_id // empty' 2>/dev/null || true)
           if [[ -n "$new_id" && -z "$comment_id" ]]; then
               ~/.claude/commands/_shared/tools/artifact-patch.py \
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
   user-visible summary:

   > `/adams-review-fix complete.`
   >
   > Committed: $surviving_count groups ($(attempted-count-verified+partial) findings → $verified_count verified, $partial_count partial).
   > Reverted:  $reverted_count groups ($regression-count findings → regression detected).
   >
   > $((partial_count + regression_count)) findings remain open and retry-eligible.
   > Re-run /adams-review-fix to attempt again with revised_fix_proposal context.
   >
   > Commit: `$commit_sha`
   > PR comment: (URL if PR mode AND publish succeeded)

#### No-commit branch (`commit_sha == null`)

Reached by one of four degenerate paths: empty-eligibility (8.2),
overlap-abort (9.pre), all-regression (9b), revert-failure (9b).

1. **fix_attempts + state transitions** — already applied in the
   originating path:
   - Empty-eligibility: no findings touched; nothing to append.
   - Overlap-abort: `--apply-fix-outcomes` with `phase_9_outcome:
     null` applied in 9.pre step 3.
   - All-regression: `--apply-fix-outcomes` with every tuple
     `phase_9_outcome: regression`, `output_sha: null`. Apply now
     before the rest of 9e runs so the artifact reflects reality:
     ```bash
     if [[ "$all_regression" == "true" ]]; then
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
             ~/.claude/commands/_shared/tools/artifact-patch.py \
               --path "$artifact_path" --apply-fix-outcomes @-
     fi
     ```
   - Revert-failure: do NOT apply `--apply-fix-outcomes` — the tree
     is in an unknown state. Leave findings as `attempted` (the
     leftover-attempted hard abort on next run is the deterministic
     recovery path).

2. **Schema-validate** — same as committed branch step 2.

3. **Re-render `artifact.md`** — same as committed branch step 3.

4. **Phase 9 phases.jsonl record** — same shape as committed branch
   step 4 but include a degenerate-case tag:

   ```bash
   degen=""
   if [[ "${overlap_abort:-false}" == "true" ]]; then degen="overlap_abort"
   elif [[ "${all_regression:-false}" == "true" ]]; then degen="all_regression"
   elif [[ "${revert_failed:-false}" == "true" ]]; then degen="revert_failed"
   elif [[ "${eligible_count:-0}" -eq 0 ]]; then degen="no_eligible"
   fi
   ```

   Include `degenerate_case: $degen` in the phases.jsonl record.
   `commit_sha` is null.

5. **Pop stash** if `stash_taken=true` — BUT only if
   `revert_failed != true`. Revert failure left the tree in an
   unknown state; popping into it could destroy user work. Leave the
   stash in place and note the ref in the user-visible error below.

6. **No push, no publish** — no new commit, nothing to ship. The
   artifact-side update is still valuable for the next run's
   staleness logic and for user inspection.

7. **Surface user-visible degenerate-case error:**

   - `overlap_abort` → the overlap message from 9.pre step 5 (above).
   - `all_regression` → "All $reverted_count fix groups regressed.
     Working tree restored; no commit made.
     `$(partial-plus-regression count)` findings are retry-eligible
     with revised_fix_proposal context. Re-run /adams-review-fix."
   - `revert_failed` → "Per-group revert failed. The working tree is
     in an unknown state — do NOT run any destructive git commands
     without inspecting first. `$revert_failure_detail`. Your stash
     (if any) is preserved at `git stash list`. See
     `$trace_log_path` for the full revert log. Once you've resolved
     manually, reset `current_state` on the affected findings and
     re-run /adams-review-fix."
   - `no_eligible` → "No fix-eligible findings at threshold=$threshold.
     Nothing to do." (No error prefix — it's a clean no-op.)

### Working-set delta after Phase 9

- Committed branch: `commit_sha` captured; every touched finding is
  either `resolved` (verified) or `open/partial` or `open/regression`;
  `fix_attempts` appended per finding; artifact re-rendered;
  (PR mode) push + publish attempted; (if stashed) stash popped;
  user-visible summary mirrored to chat.
- No-commit branch: `commit_sha=null`; state either at `attempted`
  (overlap-abort — next run catches), `open/regression` (all-
  regression), or `attempted` (revert-failure — manual recovery);
  artifact re-rendered with the degenerate case reflected; stash
  popped unless revert-failure; user-visible error surfaced.

Terminal invariant (§24.4): regardless of which branch ran, the
artifact on disk is schema-valid and tracks git reality. A partially
failed terminal block can log errors to `trace.md` but cannot leave
the artifact inconsistent.
