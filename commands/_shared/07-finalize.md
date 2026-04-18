## Phase 6 — Finalize

Close out the review: validate the artifact, tally `subagent_tokens`,
populate `metrics`, record the final `phases.jsonl` entry, render
`artifact.md`, update `latest.txt` (already done in Phase 0 — re-
asserted here for atomic safety), publish to the PR (PR mode) or
no-op (local mode), mirror the report to chat, and pop any stash
taken at Phase 0's dirty-tree gate.

### 6.1. Schema-validate the artifact

```bash
~/.claude/commands/_shared/tools/artifact-validate.sh --path "$artifact_path"
```

On non-zero exit: log the validator stderr verbatim to `trace.md`;
surface to the user as "Final artifact fails schema validation — see
trace.md." Dump a copy to `/tmp/adams-review-invalid-$(date -u +%Y%m%dT%H%M%SZ).json`
for debugging per §24.3. Do NOT proceed to publish — a broken artifact
should not shadow the PR comment.

### 6.2. Tally `subagent_tokens` from `tokens.jsonl`

```bash
# Totals + invocation count + per-phase + per-model + per-lens + per-finding.
subagent_tokens=$(jq -s '{
  total: ([.[] | .tokens // 0] | add),
  invocations: length,
  by_phase: (group_by(.phase) | map({key:.[0].phase, value: ([.[] | .tokens // 0] | add)}) | from_entries),
  by_model: (group_by(.model) | map({key:.[0].model, value: ([.[] | .tokens // 0] | add)}) | from_entries),
  by_lens:  ([.[] | select(.agent_role | startswith("lens_"))] | group_by(.agent_role) | map({key:.[0].agent_role, value: ([.[] | .tokens // 0] | add)}) | from_entries),
  by_finding_phase4: ([.[] | select(.phase == "phase_4a" or .phase == "phase_4b")] | group_by(.finding_id) | map({key:.[0].finding_id, value: ([.[] | .tokens // 0] | add)}) | from_entries)
}' "$tokens_log_path")

echo "$subagent_tokens" > "/tmp/adams-review-st-$review_id.json"
~/.claude/commands/_shared/tools/artifact-patch.py \
  --path "$artifact_path" \
  --set-json "subagent_tokens=@/tmp/adams-review-st-$review_id.json"
rm -f "/tmp/adams-review-st-$review_id.json"
```

The jq expression handles `tokens: null` entries gracefully (coerces to
0 for totals). Parse-failure entries (§11 fallback) don't inflate or
deflate the aggregate by much.

### 6.3. Populate `metrics`

```bash
start_epoch=$(date -d "$review_started_at" +%s 2>/dev/null || python3 -c "
import sys
from datetime import datetime
print(int(datetime.fromisoformat('$review_started_at'.replace('Z','+00:00')).timestamp()))
")
now_epoch=$(date +%s)
elapsed=$((now_epoch - start_epoch))

# At review time (Stage 2), phase_9_verified_pct and required_followup
# are null — they're set by /adams-review-fix's Phase 9.
metrics=$(jq -n \
  --argjson elapsed "$elapsed" \
  --argjson files_changed "$num_files" \
  --argjson lines_changed "$lines_changed" \
  '{
    phase_9_verified_pct: null,
    required_followup: null,
    time_elapsed_seconds: $elapsed,
    pr_size_buckets: {files_changed: $files_changed, lines_changed: $lines_changed}
  }')

echo "$metrics" > "/tmp/adams-review-metrics-$review_id.json"
~/.claude/commands/_shared/tools/artifact-patch.py \
  --path "$artifact_path" \
  --set-json "metrics=@/tmp/adams-review-metrics-$review_id.json"
rm -f "/tmp/adams-review-metrics-$review_id.json"
```

### 6.4. Append Phase 6 record to `phases.jsonl`

```bash
by_disp=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_disposition')
by_state=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_state')

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 6 --name finalize \
  --elapsed 0 \
  --summary "rendering + publishing; total findings=$(jq '.findings | length' $artifact_path)"

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 6 --record "$(jq -nc \
    --argjson by_disp "$by_disp" \
    --argjson by_state "$by_state" \
    '{name:"finalize", elapsed_sec:0, counts_by_state:$by_state, counts_by_disposition:$by_disp}')"
```

### 6.5. Render `artifact.md`

```bash
~/.claude/commands/_shared/tools/artifact-render.py \
  --input "$artifact_path" --output "$review_dir/artifact.md"
```

On non-zero exit: log stderr to `trace.md` and stop — rendering is a
prerequisite for publish and for mirror-to-chat.

### 6.6. Re-assert `latest.txt` (atomic)

Phase 0 already wrote this at step 0.16. Re-write it here as an
idempotent safety rail — if the Phase 0 write raced with a concurrent
run, this re-assertion establishes correctness at Phase 6.

```bash
tmp="$reviews_root/$repo_slug/$head_branch/latest.txt.tmp.$$"
printf '%s\n' "$review_id" > "$tmp"
mv "$tmp" "$reviews_root/$repo_slug/$head_branch/latest.txt"
```

### 6.7. Publish (PR mode only)

Call `artifact-publish.sh` unconditionally — per §21.6 it's designed to
be called in every mode, with local mode as a no-op.

**PR mode:**

```bash
publish_args=(
    --mode pr
    --review-id "$review_id"
    --pr "$pr_number"
    --repo-slug "$repo_slug"
    --branch "$head_branch"
    --review-dir "$review_dir"
)
if [[ -n "$existing_comment_id" ]]; then
    # existing_comment_id was captured in Phase 0 step 0.14 if we detected
    # a prior-run PR comment with no local artifact.
    publish_args+=(--comment-id "$existing_comment_id")
fi
if [[ -n "$comment_id_from_artifact" ]]; then
    # comment_id might have been persisted into the artifact on a prior
    # run (re-runs on the same PR pick it up from latest.txt's artifact).
    publish_args+=(--comment-id "$comment_id_from_artifact")
fi

stdout=$("~/.claude/commands/_shared/tools/artifact-publish.sh" "${publish_args[@]}")
publish_exit=$?
```

On stdout emission `{"comment_id": N}` (post + first-time-located),
persist to artifact per §13.4:

```bash
new_id=$(echo "$stdout" | jq -r '.comment_id // empty')
if [[ -n "$new_id" ]]; then
    ~/.claude/commands/_shared/tools/artifact-patch.py \
      --path "$artifact_path" --set "comment_id=$new_id"
fi
```

On non-zero exit: per §24.2, log stderr to `trace.md` with tag
`publish_failed`. Surface the failure to the user AFTER the
mirror-to-chat step (so the user still sees the review in chat
even though the PR didn't get it).

**Local mode:**

```bash
~/.claude/commands/_shared/tools/artifact-publish.sh \
  --mode local --review-id "$review_id" --review-dir "$review_dir"
```

No-op that appends a one-line trace entry. Exit should be 0.

### 6.8. Mirror the rendered report to chat (all modes)

Read `$review_dir/artifact.md` and output the full content directly to
the Claude Code chat — NOT a summary, the full sectioned report. This
lets the user inspect findings without bouncing to GitHub (and is the
only output in local mode).

Prepend a one-line mode-aware header:

- `pr`    → `### Code review`
- `draft` → `### Code review (draft PR)`
- `local` → `### Code review (local — \`$head_branch\` vs \`$base_branch\`)`

After the main report body (the contents of `artifact.md`), add:

- If PR mode: a one-line "Full artifact: `$artifact_path`" (so the user
  knows where the JSON lives).
- If local mode: "Fix commit will land locally if you run /adams-review-fix.
  It will not be pushed without `--push` (Stage 3 future flag)."

(The final line isn't part of `artifact.md` itself — keeps the PR comment
clean.)

### 6.9. Pop stash (if Phase 0 took one)

If `stash_taken == true` from Phase 0 step 0.8:

```bash
git stash pop
```

If the pop conflicts, do NOT auto-resolve. Tell the user clearly: "Your
stashed changes conflict with something in the tree. Resolve manually;
your stash is preserved under `git stash list`." Leave the stash in
place (it doesn't auto-drop on conflict).

If `stash_taken == false`, skip this step.

### 6.10. Final status + surface any deferred failures

If any of publish / render / validation failed, surface them as the
primary user-visible failure now, after the chat mirror. Each failure
should name the step and the next action the user should take.

If everything succeeded: nothing more to say — the chat mirror + any
PR comment is the deliverable.

### Working-set delta after Phase 6

- `artifact.json` has fully-populated `subagent_tokens` and `metrics`.
- `artifact.md` rendered at `$review_dir/artifact.md`.
- `latest.txt` points at `$review_id`.
- PR mode: review comment posted or edited (`comment_id` persisted).
- Local mode: trace.md notes "local mode, nothing to publish."
- Chat: full rendered report is visible.
- Working tree: identical to start (stash popped if stashed; otherwise
  unchanged — this command does no edits/commits).
