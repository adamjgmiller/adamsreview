## Phase 6 — Finalize

### 6.1. Schema-validate the artifact

```bash
artifact-validate.sh --path "$artifact_path"
```

On non-zero exit: log the validator stderr verbatim to `trace.md`;
surface to the user as "Final artifact fails schema validation — see
trace.md." Dump a copy to `/tmp/adams-review-invalid-$(date -u +%Y%m%dT%H%M%SZ).json`
for debugging. Do NOT proceed to publish — a broken artifact
should not shadow the PR comment.

### 6.2. Tally `subagent_tokens` from `tokens.jsonl`

```bash
tally-subagent-tokens.sh \
  --tokens-log "$tokens_log_path" \
  --artifact   "$artifact_path"
```

`tokens: null` entries coerce to 0; an empty log produces a zero
rollup rather than an error. The three lifecycle commands
(`/adamsreview:fix`, `/adamsreview:add`, `/adamsreview:walkthrough`)
each re-invoke it before their final render so the published PR
comment reflects cumulative sub-agent spend.

### 6.2b. Tally `orchestrator_tokens` from the session transcript(s)

```bash
review_started_at=$(jq -r '.review_started_at // empty' "$artifact_path")

orchestrator-tokens.sh \
  --artifact "$artifact_path" \
  --since    "$review_started_at"
```

Companion to the sub-agent tally; the two are non-overlapping. Don't
override `--cwd` — passing `$repo_root` mis-points in worktrees where
the session was started from the worktree path. Safe to call when
the transcript directory is absent (zero rollup, no error). Same
cumulative-across-lifecycle-terminus pattern as the sub-agent tally:
each lifecycle command re-invokes it before its final render.

The helper is **opt-in** via `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1`
(default skip). When opted out it exits 0 with one
`orchestrator-tally: skipped (...)` stdout line and does not touch
the artifact, so the rendered PR comment simply omits the
**Orchestrator tokens** line.

### 6.3a. Recompute `reviewer_sources` from actual findings

Top-level `reviewer_sources` is the union of providers that produced
at least one candidate. Compute it from `findings[].sources[]`:

- `internal` — present when any lens produced a candidate (any
  `sources[]` entry matches `L[0-9]+-.*` — L1–L7 today, forward-compat for future lenses).
- `internal-codex` — same `L<N>-` lens-tag pattern, but emitted by
  `/adamsreview:codex-review` rather than `/adamsreview:review`. The
  seeded artifact (Phase 0 step 0.15) carries this label when the
  top-level command set `reviewer_sources_label=internal-codex`;
  preserve it here instead of mapping back to `internal`.
- adapter name (`codex`) — present when any entry matches exactly.
- `external-pr:<bot-login>` — present when any entry starts with
  `external-pr:`.

The L-tag mapping picks `internal` vs `internal-codex` based on the
seeded value (so codex-review's marker survives the recompute):

```bash
internal_label=$(jq -r '
  if (.reviewer_sources // []) | any(. == "internal-codex") then "internal-codex"
  else "internal" end
' "$artifact_path")

reviewer_sources=$(jq -c --arg internal "$internal_label" '
  [.findings[] | .sources[]]
  | map(
      # Internal lens tags: L1..L7 today (L7 is the ensemble-gated
      # holistic lens, Stage 2.9.D). Regex is [0-9]+ for forward-
      # compatibility — new L-N lenses slot in without this needing
      # an update. Map to whichever internal label the seed indicated
      # ($internal). Any entry that doesn't match falls through to
      # `empty` and gets dropped from the union.
      if test("^L[0-9]+-") then $internal
      elif . == "codex" then .
      elif startswith("external-pr:") then .
      else empty end
    )
  | unique
' "$artifact_path")

printf '%s\n' "$reviewer_sources" > "/tmp/adams-review-rs-$review_id.json"
artifact-patch.py \
  --path "$artifact_path" \
  --set-json "reviewer_sources=@/tmp/adams-review-rs-$review_id.json"
rm -f "/tmp/adams-review-rs-$review_id.json"
```

If `findings[]` is empty (no candidates detected), the union is `[]` —
the schema accepts an empty array.

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
# are null — they're set by /adamsreview:fix's Phase 9.
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
artifact-patch.py \
  --path "$artifact_path" \
  --set-json "metrics=@/tmp/adams-review-metrics-$review_id.json"
rm -f "/tmp/adams-review-metrics-$review_id.json"
```

### 6.4. Append Phase 6 record to `phases.jsonl`

```bash
by_disp=$(artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_disposition')
by_state=$(artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_state')

log-phase.sh \
  --review-dir "$review_dir" --phase 6 --name finalize \
  --elapsed 0 \
  --summary "rendering + publishing; total findings=$(jq '.findings | length' $artifact_path)"

log-phase.sh \
  --review-dir "$review_dir" --phase 6 --record "$(jq -nc \
    --argjson by_disp "$by_disp" \
    --argjson by_state "$by_state" \
    '{name:"finalize", elapsed_sec:0, counts_by_state:$by_state, counts_by_disposition:$by_disp}')"
```

### 6.5. Render `artifact.md`

```bash
artifact-render.py \
  --input "$artifact_path" --output "$review_dir/artifact.md"
```

On non-zero exit: log stderr to `trace.md` and stop — rendering is a
prerequisite for publish and for mirror-to-chat.

### 6.6. Re-assert `latest.txt` (atomic)

```bash
tmp="$reviews_root/$repo_slug/$head_branch/latest.txt.tmp.$$"
printf '%s\n' "$review_id" > "$tmp"
mv "$tmp" "$reviews_root/$repo_slug/$head_branch/latest.txt"
```

### 6.7. Publish (PR mode only)

Call `artifact-publish.sh` unconditionally — it's designed to be
called in every mode, with local mode as a no-op.

**PR mode:**

First capture any `comment_id` that was persisted to the artifact
during this run. On a fresh `/adamsreview:review` this is normally empty —
the seed at step 0.15 writes `comment_id: null` unless step 0.14's
recovery prompt populated `existing_comment_id` (user chose "replace
prior comment in place"):

```bash
comment_id_from_artifact=$(artifact-read.sh \
  --path "$artifact_path" --filter '.comment_id // empty' 2>/dev/null || true)
```

Empty string means no comment id is known — the publisher will POST a
new comment (§13.4). Non-empty means PATCH the existing comment in
place.

Build the publish invocation:

```bash
publish_args=(
    --mode pr
    --review-id "$review_id"
    --pr "$pr_number"
    --repo-slug "$repo_slug"
    --branch "$head_branch"
    --review-dir "$review_dir"
)
# Prefer artifact-recorded comment_id; fall back to existing_comment_id
# directly. Omitting --comment-id on a fresh /adamsreview:review is
# intentional — the publisher will POST a new comment.
if [[ -n "$comment_id_from_artifact" ]]; then
    publish_args+=(--comment-id "$comment_id_from_artifact")
elif [[ -n "$existing_comment_id" ]]; then
    publish_args+=(--comment-id "$existing_comment_id")
fi

stdout=$(artifact-publish.sh "${publish_args[@]}") \
    || publish_exit=$?
publish_exit=${publish_exit:-0}
```

Note the unquoted tilde — Bash expands `~/` only when it's not inside
quotes. The helper script path must be unquoted (or use `$HOME/...`).

On stdout emission `{"comment_id": N}` (post + first-time-located),
persist to artifact:

```bash
new_id=$(echo "$stdout" | jq -r '.comment_id // empty')
if [[ -n "$new_id" ]]; then
    artifact-patch.py \
      --path "$artifact_path" --set "comment_id=$new_id"
fi
```

On non-zero exit: log stderr to `trace.md` with tag
`publish_failed`. Surface the failure to the user AFTER the
mirror-to-chat step (so the user still sees the review in chat
even though the PR didn't get it).

**Local mode:**

```bash
artifact-publish.sh \
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

After the main report body (the contents of `artifact.md`), add a
**Next steps** block. Do NOT use `AskUserQuestion` here.

Render this block verbatim (with the review's actual threshold
default):

```markdown
---

**Next steps**

- **Apply the auto-eligible findings** — `/adamsreview:fix 60`
  applies every finding in the deep-lane "✓ Auto-fixable" table
  that scores at or above the threshold. Light-lane rows are
  skipped by default; promote them first with the walkthrough.

- **Walk through the skipped findings** — `/adamsreview:walkthrough`
  presents each deep-lane manual finding and every light-lane row
  one at a time with a briefing (what it's about, options, a
  recommendation) and promotes the ones you approve with tailored
  fix-hints. Posts a decisions log to the PR for audit. Works
  same-session, later, or in a new session — the artifact persists
  under `~/.adams-reviews/`.

You can run either step independently, or both in either order.
```

Then add (still chat-only, not in `artifact.md`):

- If PR mode: a one-line "Full artifact: `$artifact_path`" (so the user
  knows where the JSON lives).
- If local mode: "Fix commit will land locally if you run /adamsreview:fix.
  It will not be pushed without `--push` (Stage 3 future flag)."

(None of these trailing lines are part of `artifact.md` itself — keeps
the PR comment clean.)

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
