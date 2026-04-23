## Phase 0 — Pre-flight

Pre-flight sets up every downstream phase's working context: branch + base,
PR state, `review_started_at`, CLAUDE.md paths, the dirty-tree gate, the
trivial-diff gate, prior-review detection, and the initial `artifact.json`.
This phase is mostly deterministic shell — the only LLM call is the Sonnet
user-facing-change classifier (step 0.9), and that's skipped in trivial mode.

**Run every Bash command in this phase in the foreground — do NOT use
`run_in_background`.** Phase 0's output (branch detection, dirty-tree
status, freshness prompts) is consumed inline by later steps and by
`AskUserQuestion` dispatches; backgrounded shells leave the orchestrator
unable to read the output and the session stalls on a variable that
never gets assigned.

Work through the steps below in order. Capture each named variable into
your working context — later phases will reference them by name ("the
`review_id` captured in Phase 0").

### 0.1. Resolve argument flags

Parse `$ARGUMENTS` for `--ensemble` and `--full`. Set `ensemble_mode=true/false`
and `force_full=true/false` in your context. Anything else on the command line
is unexpected — stop and ask the user to clarify.

### 0.2. Resolve branch, base, and repo root

Run:

```bash
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
```

Capture `head_branch` and `repo_root`.

For `base_branch`, try in order:

1. `git symbolic-ref --short refs/remotes/origin/HEAD` (strip the `origin/`
   prefix).
2. Probe `main`, then `master` via
   `git show-ref --verify --quiet refs/heads/<name>` or
   `refs/remotes/origin/<name>`. Use the first that resolves.
3. If neither resolves, stop and ask the user to rerun with explicit base
   (future flag; for now, tell them which refs you tried).

Capture `base_branch`.

(The sanity check that `base..HEAD > 0` moves to step 0.2a below, after
`comparison_ref` is resolved — a stale local `base_branch` can show zero
commits ahead while `origin/$base_branch..HEAD` is genuinely non-empty.)

### 0.2a. Reconcile base-branch freshness (§13.10)

Phase-0 invariant preventing stale-local-`base_branch` runs from poisoning
downstream lenses / blame. `freshness-gate.sh` owns remote detect, fetch,
and behind-count; orchestrator owns `AskUserQuestion`.

```bash
# Initialize preflight_warnings ONCE — prior-call warnings must survive
# across a --after-choice re-invocation. The jq-extraction loop below
# runs after EACH freshness-gate.sh call (first + any --after-choice)
# and appends; it must not reset the array.
preflight_warnings=()

fg_out=$(freshness-gate.sh --base-branch "$base_branch" --head-branch "$head_branch")
comparison_ref=$(echo "$fg_out" | jq -r '.comparison_ref // empty')
base_freshness=$(echo "$fg_out" | jq -r '.base_freshness')
remote_sha=$(echo "$fg_out" | jq -r '.remote_sha // empty')
behind_count=$(echo "$fg_out" | jq -r '.behind_count // empty')
while IFS= read -r w; do
    [[ -n "$w" ]] && preflight_warnings+=("$w")
done < <(echo "$fg_out" | jq -r '.preflight_warnings[]?')
```

First four values feed `base_context` at 0.15; `preflight_warnings` flushes
to `trace.md` at 0.15 (after `trace_log_path` exists). If `base_freshness ==
"pending_user_gate"`, ask the user — offer (a) Fast-forward local `$base_branch`
[drop when `ff_available: false`], (b) Compare against `origin/$base_branch`,
(c) Proceed with stale local `$base_branch` (discouraged), (d) Abort; include
`behind_count` in the prompt. Re-invoke `freshness-gate.sh ... --after-choice
<a|b|c>` and re-run the **same jq extractions** on the new `fg_out` — do NOT
reset `preflight_warnings` (the array is initialized once above); the while
loop appends any additional warnings to the prior-call set. A second
`pending_user_gate` (non-FF on (a)) re-asks with only (b)/(c)/(d). (d) exits 0
with a one-line message — no `review_dir` exists yet.

**Sanity check (against `comparison_ref`).** Phase-0-level decision, not
a freshness decision — stays inline so the "nothing to do" message is
user-facing:

```bash
if [[ "$(git rev-list --count "$comparison_ref..HEAD")" -eq 0 ]]; then
    echo "No commits to review on $head_branch relative to $comparison_ref. Nothing to do." >&2
    exit 0
fi
```

Running this against `$comparison_ref` (not `$base_branch`) means a
feature branch that looks empty vs stale local `main` but has real
commits vs `origin/main` still reviews correctly under option (b).

### 0.3. Derive repo slug

Delegate to the canonical helper (DESIGN §9.2 — single source of truth
shared with Phase 7's fix-loader so the two paths cannot drift):

```bash
repo_slug=$(repo-slug.sh --repo-root "$repo_root")
```

The helper runs `git remote get-url origin`, strips scheme + `git@` +
trailing `.git`, normalizes separators, and lowercases. No remote → falls
back to `local-<sanitized-path>`. See `bin/repo-slug.sh` for the exact
algorithm and test matrix.

Capture as `repo_slug`.

### 0.4. Detect PR mode

Run `gh pr view --json number,state,isDraft,url,author,headRefName,baseRefName`
(no PR arg — picks up the PR for the current branch if any).

- If the command succeeds and returns a PR: capture `pr_number`,
  `pr_author`, and verify `headRefName == head_branch` (otherwise stop
  — you may have checked out the wrong branch for the PR number you're
  reviewing).
  - The `gh` CLI returns `state` as uppercase enum
    (`OPEN` | `CLOSED` | `MERGED`) and `isDraft` as a separate boolean.
    Schema (`schema-v1.json`) requires `pr_state` to be lowercase
    `"draft"` | `"open"` | `null`. Transform the two fields into a
    single `pr_state`:
    - `isDraft == true`                → `pr_state="draft"`
    - `state == "OPEN" && !isDraft`    → `pr_state="open"`
    - `state == "CLOSED"` or `"MERGED"`→ stop with a user-visible message (closed/merged PRs are not reviewed)
  - Example:
    ```bash
    pr_json=$(gh pr view --json number,state,isDraft,url,author,headRefName,baseRefName)
    pr_number=$(jq -r '.number' <<<"$pr_json")
    pr_author=$(jq -r '.author.login' <<<"$pr_json")
    pr_raw_state=$(jq -r '.state' <<<"$pr_json")
    pr_is_draft=$(jq -r '.isDraft' <<<"$pr_json")
    if [[ "$pr_raw_state" == "CLOSED" || "$pr_raw_state" == "MERGED" ]]; then
        echo "Skipping review: PR #$pr_number is $pr_raw_state." >&2
        exit 0
    fi
    if [[ "$pr_is_draft" == "true" ]]; then
        pr_state="draft"
    elif [[ "$pr_raw_state" == "OPEN" ]]; then
        pr_state="open"
    else
        # Unexpected enum value — shouldn't reach here after the
        # CLOSED/MERGED exit above, but defend anyway.
        pr_state=""   # empty string sentinel; the jq seed at step 0.15 turns "" into null
    fi
    ```
  - Set `mode=pr`.
- If it exits non-zero with "no pull requests found for branch" (or similar):
  set `mode=local`, `pr_number=""`, `pr_state=""`, `pr_author=""` (empty-string
  sentinels matching the `pr_state=""` branch above; the `${var:-}` expansions
  at step 0.15's `artifact-seed.sh` call turn `""` into JSON null. Do NOT use
  the literal string `null` — the helper rejects it at argument validation).
- Any other `gh` error (auth, network): stop and surface stderr per §24.2.

### 0.5. Capture `review_started_at`

Run `date -u +%Y-%m-%dT%H:%M:%SZ` and capture as `review_started_at`.
This is the review's start time — consumed by Phase 6 `metrics.time_elapsed_seconds`
for cost-vs-size tracking. Pre-Stage-2.8 this timestamp also anchored
the Phase 1.5 scrape window, which is why its capture was deliberately
pre-mutation; Stage 2.8 moved PR comment filtering onto a code-locality
axis (§13.13) so the timing invariant is gone and this field is now
metrics-only.

### 0.6. Compute `reviewed_files_all`, `num_files`, and `lines_changed`

Run (using `$comparison_ref` — §13.10 — not `$base_branch`; the two
differ when the freshness gate resolved to option (b) `used_remote_ref`,
in which case `comparison_ref = "origin/$base_branch"`):

```bash
reviewed_files_all=$(git diff --name-only "$comparison_ref..HEAD")
num_files=$(printf '%s\n' "$reviewed_files_all" | grep -c . || true)
lines_changed=$(git diff --shortstat "$comparison_ref..HEAD" | \
  awk '{insertions=0; deletions=0; for(i=1;i<=NF;i++){if($i ~ /insertion/){insertions=$(i-1)}else if($i ~ /deletion/){deletions=$(i-1)}}; print insertions+deletions}')
# Fallback if awk path fails: lines_changed=0.
[[ -n "$lines_changed" ]] || lines_changed=0
```

Capture `reviewed_files_all` (newline-separated list — pass through stdin
with `@-` to scripts that accept it; join with commas when a CSV arg is
expected). Capture `num_files` and `lines_changed` as integers; they're
used by step 0.11 (trivial check) AND by step 0.15 (seed's
`pr_size_buckets`) AND by Phase 6's `metrics` block. Compute them here
unconditionally — if step 0.11 is skipped by `--full`, these still need
to exist.

### 0.7. Enumerate `claude_md_paths`

Run:

```bash
printf '%s\n' $reviewed_files_all | \
  claude-md-paths.sh \
    --repo-root "$repo_root" --files @-
```

(`@-` reads from stdin so large `reviewed_files_all` doesn't blow past
`ARG_MAX`.) Capture the output as `claude_md_paths` — one absolute path per
line, already deduped and root-first-sorted. Empty output is fine (plenty of
repos have no CLAUDE.md).

### 0.8. Dirty-tree gate

Run `git status --porcelain`. If output is non-empty, briefly list what's
uncommitted (filenames only, categorized as Modified / Staged / Untracked —
do NOT dump the diff). Then use `AskUserQuestion` once with three options:

- **Stash my changes, run review, restore** (recommended). Run
  `git stash push -u -m "pre-adams-review-stash"` now; at end of Phase 6,
  run `git stash pop`. Capture `stash_taken=true` so Phase 6 knows to pop.
- **Include uncommitted changes in the review** — the review will include
  whatever's in the tree as-is; no stash. In PR mode this is rarely what
  the user wants, so the warning should be explicit: "Uncommitted files
  will appear in the diff the lenses see, but they're not pushed to the PR
  so the review won't match what reviewers see on GitHub."
- **Stop so I can handle them first** — exit.

If the tree is clean, no prompt. Record `stash_taken=false`.

### 0.9. Push unpushed commits (PR mode only)

If `mode=pr`, run `git rev-list --count @{upstream}..HEAD`. If the count is
> 0, there are local commits not yet on the PR. Run `git push` to land them;
only then does `reviewed_sha` capture below represent the post-push state.
In local mode, skip.

### 0.10. Capture `reviewed_sha`

Now (after any push), run `git rev-parse HEAD` and capture as `reviewed_sha`.
This is the staleness-envelope anchor.

### 0.11. Trivial-diff check (§13.9)

If `force_full=true`, set `trivial_mode=false` and `trivial_reason=null`
and skip the rest of this step. Otherwise delegate to `trivial-check.sh`
(allow-list walk + count thresholds + reason emission):

```bash
tc_json=$(printf '%s\n' $reviewed_files_all | trivial-check.sh --num-files "$num_files" --lines-changed "$lines_changed")
trivial_mode=$(printf '%s' "$tc_json" | jq -r '.trivial_mode')
trivial_reason=$(printf '%s' "$tc_json" | jq -r '.reason')
```

### 0.12. User-facing-change classifier (Sonnet — skipped in trivial mode)

If `trivial_mode == true`, set `user_facing=false` and skip this step
(L5 is already off in trivial mode per §13.9; Phase 1's L5 gating will also
re-check `trivial_mode`).

Otherwise, launch a Sonnet sub-agent with this input:

```
Diff files (with short descriptions of each file's apparent type):
<list each file in reviewed_files_all with a one-line "what is this file"
hint based on its extension / path — e.g. "src/components/Foo.tsx — React
component", "config/database.yml — backend config">

Return JSON: {"user_facing": true|false, "surfaces": ["..."]}

Return user_facing: true if the diff touches any of: UI components,
route or page files, templates, user-visible strings/copy, CSS/styles,
i18n files. Return false for pure backend logic, build tooling,
internal utilities, config.
```

Dispatch with the `Agent` tool, `model: sonnet`. After the sub-agent returns,
parse `user_facing` + `surfaces`. Then log tokens (every required arg is
explicit here to match the helper's argparse — don't infer):

```bash
log-tokens.sh \
  --review-dir "$review_dir" \
  --phase phase_0 \
  --agent-role user_facing_classifier \
  --agent-id "$classifier_agent_id" \
  --model sonnet \
  --tokens "$classifier_tokens_or_null"
```

Where `$classifier_agent_id` is the id in the Agent tool result and
`$classifier_tokens_or_null` is either the parsed token count or the literal
word `null` on parse failure (per §11 fallback).

If JSON parsing of the classifier result fails after one retry, default
`user_facing=true` (fail-safe — better to run L5 unnecessarily than skip
a real UX finding).

### 0.13. Prior-artifact detection

Resolve the reviews root: `$ADAMS_REVIEW_REVIEWS_ROOT` if set, else
`~/.adams-reviews`. Build the path:
`<reviews_root>/<repo_slug>/<head_branch>/latest.txt`.

If the file exists and is non-empty, read its contents as
`prior_review_id`. Read `<reviews_root>/<repo_slug>/<head_branch>/<prior_review_id>/artifact.json`
and determine the prior state (per §4 Phase 0 step 11):

| Condition | AskUserQuestion prompt |
|---|---|
| `prior.reviewed_sha == reviewed_sha` AND no `fix_attempts` on any finding | "You have a review for this exact commit from `<date>`. Re-run fresh, or abort?" |
| `prior.reviewed_sha == reviewed_sha` AND some finding has a `fix_attempts[-1]` whose `output_sha` matches `HEAD` | "You have a review that was already fixed at this commit. Re-run fresh, or abort?" |
| Any finding has `current_state=open` AND `is_actionable=true` | "Previous review has unresolved actionable findings. Options: (a) run `/adamsreview:fix` first, (b) proceed with fresh review, (c) abort." |
| Otherwise (prior exists but HEAD has moved beyond any known sha) | "Prior review at `<prior.reviewed_sha>`. Current HEAD is `<reviewed_sha>`. Proceed with fresh review?" |

A "fresh review" supersedes the prior local artifact (new `review_id`,
new `review_dir`, `latest.txt` re-pointed). In PR mode it also posts a
new PR comment — the prior comment is **not** overwritten (per §13.4).
If you want the prior comment gone, delete it on GitHub first.

If `latest.txt` is missing: skip this step.

### 0.14. Prior-PR-comment detection (PR mode, even without local artifact)

**Note on repeat `:review` runs.** When step 0.13 found a prior local
artifact with `current_state=open`, §0.14 is skipped — the prior PR
comment stays on the PR untouched and this run posts a fresh comment
alongside it. Mention the prior comment's URL to the user so they can
delete it manually on GitHub if they don't want it lingering. Running
`:review` repeatedly on the same branch otherwise silently accumulates
review comments.

If `mode=pr` AND step 0.13 found no prior local artifact, run:

```bash
gh api --paginate "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/issues/$pr_number/comments" \
  | jq -r --arg user "$(gh api user -q .login)" \
         --arg marker "<!-- adams-review-v1 -->" \
      '[.[] | select(.user.login == $user) | select(.body | contains($marker))]
       | last // empty | .id'
```

If a comment id is returned, run `AskUserQuestion` with three choices:

- **(a) Post a new comment alongside the existing one** (default). The
  prior comment stays on the PR untouched; this run's rendered artifact
  lands as a fresh comment. `existing_comment_id` stays unset.
- **(b) Replace the existing comment in place.** Captures the returned
  comment id as `existing_comment_id`; Phase 6 will PATCH it via
  `--comment-id`. Use this when you're rehydrating a lost local artifact
  and want the single canonical review comment updated.
- **(c) Abort** and recover the prior artifact first.

Suggested prompt: "A prior `/adamsreview:review` comment exists on this PR
(`<comment_url>`) but no local artifact was found. (a) post a new
comment (prior stays), (b) replace the prior comment in place, (c)
abort to recover the prior artifact first."

Only option (b) sets `existing_comment_id`. The publisher has no
auto-discovery fallback (§13.4), so any run that reaches Phase 6
without `existing_comment_id` posts a fresh comment.

### 0.15. Create the review directory and initialize the artifact

Generate a `review_id`. Schema requires `^rev_[A-Za-z0-9]+$` (see
`schema-v1.json`) so the prefix is mandatory. Prefer ULID; fall back to
a timestamp+random tail. Both paths MUST produce a `rev_`-prefixed id:

```bash
if ulid=$(uv run --with ulid-py python3 -c 'import ulid; print(ulid.new())' 2>/dev/null); then
    review_id="rev_${ulid}"
else
    # Schema (schema-v1.json) pins review_id to ^rev_[A-Za-z0-9]+$ —
    # the character class excludes underscores, so concatenate without
    # a separator between the timestamp and the random tail.
    review_id="rev_$(date -u +%Y%m%dT%H%M%SZ)$(openssl rand -hex 3)"
fi
```

Capture as `review_id`.

Build the artifact directory:

```bash
reviews_root="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
review_dir="$reviews_root/$repo_slug/$head_branch/$review_id"
mkdir -p "$review_dir"
artifact_path="$review_dir/artifact.json"
```

Capture `reviews_root`, `review_dir`, `artifact_path`. Also capture the three
log paths:

- `phases_log_path = "$review_dir/phases.jsonl"`
- `tokens_log_path = "$review_dir/tokens.jsonl"`
- `trace_log_path = "$review_dir/trace.md"`

Build the initial seed doc. `base_context` encodes the §13.10 freshness
reconciliation; `remote_sha` / `behind_count` may be null on the
offline / no-remote paths. Build that sub-object inline (jq keeps the
null cases clean), then hand the rest of the seed shape to
`artifact-seed.sh`, which emits schema-shaped JSON for `artifact-patch.py
--init -` to persist. `reviewer_sources: ["internal"]` seeds as Phase
6.3a's pre-image; Phase 6.3a recomputes the authoritative list from
`findings[].sources[]` union per DESIGN §6.

```bash
base_context_json=$(jq -n \
  --arg freshness "$base_freshness" \
  --arg comparison_ref "$comparison_ref" \
  --arg remote_sha "${remote_sha:-}" \
  --arg behind_count "${behind_count:-}" \
  '{
    freshness: $freshness,
    comparison_ref: $comparison_ref,
    remote_sha: (if $remote_sha == "" then null else $remote_sha end),
    behind_count: (if $behind_count == "" then null else ($behind_count | tonumber) end)
  }')

artifact-seed.sh \
  --review-id "$review_id" --review-started-at "$review_started_at" \
  --reviewed-sha "$reviewed_sha" \
  --base-branch "$base_branch" --head-branch "$head_branch" \
  --mode "$mode" --pr-state "${pr_state:-}" \
  --pr-number "${pr_number:-}" --comment-id "${existing_comment_id:-}" \
  --trivial-mode "$trivial_mode" --base-context "$base_context_json" \
  --reviewed-files-all "$reviewed_files_all" \
  --claude-md-paths "$claude_md_paths" \
  --files-changed "$num_files" --lines-changed "$lines_changed" \
  | artifact-patch.py --init - --path "$artifact_path"
```

**Flush `preflight_warnings` to `trace.md`** (only after `--init`
succeeds — else `trace_log_path` points at a directory that may be
about to be `rm -rf`-ed):

```bash
if [[ ${#preflight_warnings[@]} -gt 0 ]]; then
    for w in "${preflight_warnings[@]}"; do
        printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$w" >> "$trace_log_path"
    done
fi
```

On non-zero exit from `artifact-patch.py --init`: the stderr will be error-
as-prompt. Parse the message, adjust the seed, retry once. If still failing
after retry, escalate to the user with the stderr content AND delete the
empty `review_dir` you created (`rm -rf -- "$review_dir"`). Leaving it
behind makes step 0.13 on the next run think a prior review exists when
none does. Do NOT write `latest.txt` (step 0.16) on this failure path.

### 0.16. Update `latest.txt` (atomic) — only after --init succeeds

Step 0.15's `--init` must have succeeded for this step to run. If the
`--init` call failed in step 0.15, skip this step — `latest.txt` stays
pointing at whatever prior review_id was there (or doesn't exist at
all on first run).

```bash
tmp="$reviews_root/$repo_slug/$head_branch/latest.txt.tmp.$$"
printf '%s\n' "$review_id" > "$tmp"
mv "$tmp" "$reviews_root/$repo_slug/$head_branch/latest.txt"
```

### 0.17. Log Phase 0

```bash
elapsed=$(( $(date +%s) - phase_0_start_epoch ))
log-phase.sh \
  --review-dir "$review_dir" --phase 0 --name preflight \
  --elapsed "$elapsed" \
  --summary "mode=$mode; trivial_mode=$trivial_mode; user_facing=$user_facing; files=$num_files; lines=$lines_changed; claude_md_paths=$(printf '%s\n' $claude_md_paths | wc -l | tr -d ' ')"

log-phase.sh \
  --review-dir "$review_dir" --phase 0 --record "$(jq -nc \
    --arg name preflight \
    --argjson elapsed_sec "$elapsed" \
    --argjson trivial "$trivial_mode" \
    --argjson user_facing "${user_facing:-false}" \
    --argjson files_changed "$num_files" \
    --argjson lines_changed "$lines_changed" \
    '{name:$name, elapsed_sec:$elapsed_sec, trivial_mode:$trivial, user_facing:$user_facing, counts_by_state:{}, counts_by_disposition:{}, pr_size:{files_changed:$files_changed, lines_changed:$lines_changed}}')"
```

(Capture `phase_0_start_epoch` at step 0.1 entry via
`phase_0_start_epoch=$(date +%s)`.)

### Working set now established

At the end of Phase 0, you should have captured:

| Name | Source |
|---|---|
| `ensemble_mode`, `force_full` | Step 0.1 |
| `head_branch`, `base_branch`, `repo_root` | Step 0.2 |
| `comparison_ref`, `base_freshness`, `remote_sha`, `behind_count` | Step 0.2a |
| `preflight_warnings` (flushed at 0.15) | Step 0.2a |
| `repo_slug` | Step 0.3 |
| `mode`, `pr_number`, `pr_state`, `pr_author` | Step 0.4 |
| `review_started_at` | Step 0.5 |
| `reviewed_files_all`, `num_files`, `lines_changed` | Step 0.6 |
| `claude_md_paths` | Step 0.7 |
| `stash_taken` | Step 0.8 |
| `reviewed_sha` | Step 0.10 |
| `trivial_mode` | Step 0.11 |
| `user_facing` | Step 0.12 |
| `existing_comment_id` (PR mode, may be null) | Step 0.14 |
| `review_id`, `review_dir`, `artifact_path`, `reviews_root` | Step 0.15 |
| `phases_log_path`, `tokens_log_path`, `trace_log_path` | Step 0.15 |

Every later phase references these by name. Don't recompute; don't rediscover.

**Reminder on `comparison_ref` vs `base_branch`.** `base_branch` is the
human name ("main") recorded in the artifact for display. `comparison_ref`
is the ref every later `git diff` / `git blame` / lens-prompt uses. They
match on the happy path (`fresh`, `fast_forwarded`) and diverge only
under option (b) (`used_remote_ref`), when `comparison_ref = "origin/main"`
while `base_branch` stays `"main"`. Phases 1–6 always read
`comparison_ref`; the renderer's header is the one place that still
shows `base_branch` (plus the freshness line when non-default).
