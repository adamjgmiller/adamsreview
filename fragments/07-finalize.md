## Phase 6 — Finalize

Close out the review: validate the artifact, tally `subagent_tokens`
and `orchestrator_tokens`, populate `metrics`, record the final
`phases.jsonl` entry, render `artifact.md`, update `latest.txt`
(already done in Phase 0 — re-asserted here for atomic safety),
publish to the PR (PR mode) or no-op (local mode), mirror the report
to chat, and pop any stash taken at Phase 0's dirty-tree gate.

### 6.1. Schema-validate the artifact

```bash
artifact-validate.sh --path "$artifact_path"
```

On non-zero exit: log the validator stderr verbatim to `trace.md`;
surface to the user as "Final artifact fails schema validation — see
trace.md." Dump a copy to `/tmp/adams-review-invalid-$(date -u +%Y%m%dT%H%M%SZ).json`
for debugging per §24.3. Do NOT proceed to publish — a broken artifact
should not shadow the PR comment.

### 6.2. Tally `subagent_tokens` from `tokens.jsonl`

```bash
tally-subagent-tokens.sh \
  --tokens-log "$tokens_log_path" \
  --artifact   "$artifact_path"
```

The helper slurps `tokens.jsonl`, computes totals + invocation count +
per-phase + per-model + per-lens + per-finding-phase4, and writes the
rollup to `<artifact>.subagent_tokens` via `artifact-patch.py
--set-json`. It's a pure readback — `tokens.jsonl` itself is never
touched, and repeat invocations are idempotent.

`tokens: null` entries (§11 parse-failure fallback) coerce to 0 in
totals; an empty log produces a zero rollup rather than an error, so
the helper is safe to call at any terminus. The three lifecycle
commands (`/adamsreview:fix`, `/adamsreview:add`,
`/adamsreview:walkthrough`) each re-invoke it before their final
render so the published PR comment reflects cumulative sub-agent
spend, not just the initial `/adamsreview:review` snapshot.

### 6.2b. Tally `orchestrator_tokens` from the session transcript(s)

```bash
review_started_at=$(jq -r '.review_started_at // empty' "$artifact_path")

orchestrator-tokens.sh \
  --artifact "$artifact_path" \
  --since    "$review_started_at"
```

Companion to the sub-agent tally. Scans every Claude Code transcript
under `~/.claude/projects/<cwd-slug>/` whose assistant-line timestamps
fall in the review window and sums the main-session (orchestrator)
`message.usage` counters into `<artifact>.orchestrator_tokens`.
Complements `subagent_tokens` — the two are non-overlapping: sub-agent
tokens are the sub-agents' own internal API calls, orchestrator tokens
are the main session's per-turn usage. Together they cover the full
spend of a review.

The helper defaults `--cwd` to `$(pwd -P)`, which is exactly the
Claude Code session's cwd — the same path whose slugged form
(`tr '/.' '-'`) names the transcript directory. Don't override
`--cwd` unless testing; passing `$repo_root` would mis-point in
worktrees where the session was started from the worktree path.

The helper is safe to call when the transcript directory is absent —
it emits a zero rollup rather than erroring. Same "cumulative across
every lifecycle terminus" pattern as the sub-agent tally:
`/adamsreview:fix`, `/adamsreview:add`, and
`/adamsreview:walkthrough` each re-invoke it before their final
render.

The helper is **opt-in** via `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1`
(default skip — the transcript scan trips the macOS Sequoia/Tahoe
"access data from other apps" prompt because Claude Code marks
transcripts with the `com.apple.provenance` xattr). When opted out
it exits 0 with one `orchestrator-tally: skipped (...)` stdout line
and does not touch the artifact, so the rendered PR comment simply
omits the **Orchestrator tokens** line. See README §"Token counts"
for the user-facing rationale and enable path.

Soft over-count modes (unrelated same-cwd sessions, intermission chat
between lifecycle commands) are accepted for v1 — both bias towards
over-count, never under-count, and only apply when opted in. See the
helper header for the full list.

### 6.3a. Recompute `reviewer_sources` from actual findings

DESIGN §6 defines top-level `reviewer_sources` as the union of
providers that produced at least one candidate. Compute it from
`findings[].sources[]`:

- `internal` — present when any lens produced a candidate (any
  `sources[]` entry matches `L[0-9]+-.*` — L1–L7 today, forward-compat for future lenses).
- adapter names (`codex`, `coderabbit`) — present when any entry
  matches exactly.
- `external-pr:<bot-login>` — present when any entry starts with
  `external-pr:`.

```bash
reviewer_sources=$(jq -c '
  [.findings[] | .sources[]]
  | map(
      # Internal lens tags: L1..L7 today (L7 is the ensemble-gated
      # holistic lens, Stage 2.9.D). Regex is [0-9]+ for forward-
      # compatibility — new L-N lenses slot in without this needing
      # an update. Any entry that doesn't match falls through to
      # `empty` and gets dropped from the union.
      if test("^L[0-9]+-") then "internal"
      elif . == "codex" or . == "coderabbit" then .
      elif startswith("external-pr:") then .
      else empty end
    )
  | unique
' "$artifact_path")

echo "$reviewer_sources" > "/tmp/adams-review-rs-$review_id.json"
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
# Prefer artifact-recorded comment_id (which step 0.15's --init seeded
# from step 0.14's existing_comment_id if the user opted into
# "replace prior" recovery). Fall back to existing_comment_id directly
# for defense-in-depth if the seed missed it for any reason.
# Omitting --comment-id on a fresh /adamsreview:review is intentional: the
# publisher will POST a new comment. See DESIGN §13.4.
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
persist to artifact per §13.4:

```bash
new_id=$(echo "$stdout" | jq -r '.comment_id // empty')
if [[ -n "$new_id" ]]; then
    artifact-patch.py \
      --path "$artifact_path" --set "comment_id=$new_id"
fi
```

On non-zero exit: per §24.2, log stderr to `trace.md` with tag
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
**Next steps** block so the reviewer knows their options. The block
has two bullets — one for each follow-up command — framed as
suggestions rather than forced next actions. Do NOT use
`AskUserQuestion` here: the walkthrough is a 15-30 minute interactive
session and prompting at review completion catches the reviewer at a
bad time (they're just reading output). A descriptive block gives
discoverability without pressure.

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

### Working-set delta after Phase 6

- `artifact.json` has fully-populated `subagent_tokens`,
  `orchestrator_tokens`, and `metrics`.
- `artifact.md` rendered at `$review_dir/artifact.md`.
- `latest.txt` points at `$review_id`.
- PR mode: review comment posted or edited (`comment_id` persisted).
- Local mode: trace.md notes "local mode, nothing to publish."
- Chat: full rendered report is visible.
- Working tree: identical to start (stash popped if stashed; otherwise
  unchanged — this command does no edits/commits).
