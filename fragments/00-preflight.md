## Phase 0 — Pre-flight

Pre-flight sets up every downstream phase's working context: branch + base,
PR state, `review_started_at`, CLAUDE.md paths, the dirty-tree gate, the
trivial-diff gate, prior-review detection, and the initial `artifact.json`.
This phase is mostly deterministic shell — the only LLM call is the Haiku
user-facing-change classifier (step 0.9), and that's skipped in trivial mode.

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

This is the Phase-0 invariant that prevents stale-local-`base_branch` runs
from silently poisoning every downstream lens and blame check. Output: a
`comparison_ref` variable (which every later `git diff` / `git blame` /
lens prompt uses instead of `$base_branch`) and a `base_context` record
written into the artifact seed at step 0.15.

Warnings written in this step need to land in `trace.md`, but
`trace_log_path` isn't captured until step 0.15. Initialize a
`preflight_warnings` Bash array at the top of this step (one string per
entry) and flush it to `trace.md` at the end of step 0.15 once the
review directory exists.

```bash
preflight_warnings=()
base_freshness=""
comparison_ref=""
remote_sha=null
behind_count=null
```

**Step 1. Detect whether a remote exists, and fetch if it does.**

```bash
if ! git remote get-url origin >/dev/null 2>&1; then
    # Purely local repo — nothing to reconcile. Use local base_branch
    # directly and skip straight to step 4 (sanity check).
    base_freshness="no_remote"
    comparison_ref="$base_branch"
else
    # 30s soft timeout via GNU coreutils `timeout` if available; fall
    # back to a background+wait pattern on macOS where `timeout` isn't
    # default.
    fetch_rc=0
    if command -v timeout >/dev/null 2>&1; then
        timeout 30 git fetch origin "$base_branch" --quiet 2>/tmp/adams_fetch_err.$$ || fetch_rc=$?
    else
        ( git fetch origin "$base_branch" --quiet 2>/tmp/adams_fetch_err.$$ ) &
        fetch_pid=$!
        ( sleep 30 && kill -TERM "$fetch_pid" 2>/dev/null ) &
        watchdog_pid=$!
        wait "$fetch_pid" 2>/dev/null || fetch_rc=$?
        kill -TERM "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
    fi

    if [[ $fetch_rc -ne 0 ]]; then
        # Fetch failed (network, no upstream for this branch, timeout).
        # Do NOT prompt; do NOT abort — offline/airgapped runs must proceed.
        base_freshness="no_fetch"
        comparison_ref="$base_branch"
        preflight_warnings+=("fetch_failed origin $base_branch rc=$fetch_rc err=$(tr '\n' ' ' < /tmp/adams_fetch_err.$$ 2>/dev/null || true)")
    fi
    rm -f /tmp/adams_fetch_err.$$
fi
```

**Step 2. Compute `behind_count` and route (only if fetch succeeded).**

If `base_freshness` is still empty after step 1 (i.e., fetch succeeded),
compute the behind count and branch:

```bash
if [[ -z "$base_freshness" ]]; then
    remote_sha=$(git rev-parse "origin/$base_branch")
    behind_count=$(git rev-list --count "$base_branch..origin/$base_branch" 2>/dev/null || echo 0)

    if [[ "$behind_count" -eq 0 ]]; then
        base_freshness="fresh"
        comparison_ref="$base_branch"
    fi
    # else behind_count > 0 → Step 3 dispatches AskUserQuestion.
fi
```

**Step 3. User gate for the behind case (orchestrator-level).**

When `behind_count > 0` (i.e., `base_freshness` is still empty after
step 2), dispatch `AskUserQuestion` with four choices.
List `behind_count` explicitly in the prompt so the user knows how many
commits have accumulated upstream. Suggested prompt:

> Local `$base_branch` is $behind_count commits behind `origin/$base_branch`.
> Reviewing against stale local main may flag upstream commits as
> PR-introduced and miss pre-existing findings. Choose:
>
> - (a) Fast-forward local `$base_branch` and compare against it (recommended)
> - (b) Compare against `origin/$base_branch` without touching local
> - (c) Proceed with stale local `$base_branch` (strongly discouraged)
> - (d) Abort

Branch on the user's answer:

- **(a) Fast-forward local `$base_branch`**. Run
  `git fetch origin "$base_branch:$base_branch"` — this refuses non-FF
  updates, so a locally-diverged `$base_branch` surfaces a clear error
  rather than silently rewriting history. On success:
  `comparison_ref="$base_branch"`, `base_freshness="fast_forwarded"`.
  On failure (non-FF divergence): buffer the stderr into
  `preflight_warnings`, explain the divergence, and re-issue
  `AskUserQuestion` with only (b), (c), (d) offered (drop (a)).
- **(b) Compare against `origin/$base_branch`** (no local mutation).
  `comparison_ref="origin/$base_branch"`,
  `base_freshness="used_remote_ref"`. Local `$base_branch` stays stale
  — fine; the review's comparison ref points at the remote.
- **(c) Proceed with stale local `$base_branch`** (strongly discouraged).
  `comparison_ref="$base_branch"`, `base_freshness="proceeded_stale"`.
  Buffer the warning into `preflight_warnings` for trace.md.
- **(d) Abort.** Exit 0 with a one-line message; do not create a
  `review_dir` (nothing has been written yet — the artifact seed
  hasn't landed at 0.15).

**Step 4. Sanity check (against `comparison_ref`).**

```bash
if [[ "$(git rev-list --count "$comparison_ref..HEAD")" -eq 0 ]]; then
    echo "No commits to review on $head_branch relative to $comparison_ref. Nothing to do." >&2
    exit 0
fi
```

Running this against `$comparison_ref` (not `$base_branch`) means a
feature branch that looks empty vs stale local `main` but has real
commits vs `origin/main` still reviews correctly under option (b).

**Capture** `comparison_ref`, `base_freshness`, `remote_sha`, `behind_count`,
`preflight_warnings` into the working context. The first four feed the
`base_context` object in the artifact seed (step 0.15); `preflight_warnings`
is flushed to `trace.md` at the end of step 0.15. `comparison_ref` is used
by every later phase in place of `$base_branch` for diff / blame /
lens-prompt references.

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
  set `mode=local`, `pr_number=null`, `pr_state=null`, `pr_author=null`.
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

If `force_full=true`, set `trivial_mode=false` and skip the rest of this
step. Counts from 0.6 are used unchanged.

Otherwise, run this Bash check against the file list from 0.6:

```bash
# Every changed file must match the doc/config allow-list for trivial.
# Allow-list: *.md *.mdx *.txt *.rst *.yaml *.yml *.json *.jsonc
#             *.toml *.ini *.cfg *.conf LICENSE LICENSE.* CHANGELOG*
#             NOTICE* .gitignore .editorconfig .npmrc .nvmrc
all_trivial=true
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
        *.md|*.mdx|*.txt|*.rst|*.yaml|*.yml|*.json|*.jsonc|\
        *.toml|*.ini|*.cfg|*.conf|\
        LICENSE|LICENSE.*|CHANGELOG*|NOTICE*|\
        .gitignore|.editorconfig|.npmrc|.nvmrc) ;;
        *) all_trivial=false; break ;;
    esac
done <<<"$reviewed_files_all"
```

If `num_files <= 3 AND lines_changed <= 30 AND all_trivial == true`:
set `trivial_mode=true`. Otherwise `trivial_mode=false`.

### 0.12. User-facing-change classifier (Haiku — skipped in trivial mode)

If `trivial_mode == true`, set `user_facing=false` and skip this step
(L5 is already off in trivial mode per §13.9; Phase 1's L5 gating will also
re-check `trivial_mode`).

Otherwise, launch a Haiku sub-agent with this input:

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

Dispatch with the `Agent` tool, `model: haiku`. After the sub-agent returns,
parse `user_facing` + `surfaces`. Then log tokens (every required arg is
explicit here to match the helper's argparse — don't infer):

```bash
log-tokens.sh \
  --review-dir "$review_dir" \
  --phase phase_0 \
  --agent-role user_facing_classifier \
  --agent-id "$haiku_agent_id" \
  --model haiku \
  --tokens "$haiku_tokens_or_null"
```

Where `$haiku_agent_id` is the id in the Agent tool result and
`$haiku_tokens_or_null` is either the parsed token count or the literal
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
| Any finding has `current_state=open` AND `is_actionable=true` | "Previous review has unresolved actionable findings. Options: (a) run `/adams-review:fix` first, (b) proceed with fresh review, (c) abort." |
| Otherwise (prior exists but HEAD has moved beyond any known sha) | "Prior review at `<prior.reviewed_sha>`. Current HEAD is `<reviewed_sha>`. Proceed with fresh review?" |

A "fresh review" supersedes the prior local artifact (new `review_id`,
new `review_dir`, `latest.txt` re-pointed). In PR mode it also posts a
new PR comment — the prior comment is **not** overwritten (per §13.4).
If you want the prior comment gone, delete it on GitHub first.

If `latest.txt` is missing: skip this step.

### 0.14. Prior-PR-comment detection (PR mode, even without local artifact)

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

Suggested prompt: "A prior `/adams-review:review` comment exists on this PR
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

Build the initial seed doc. Use `jq -n` so you don't have to hand-escape JSON:

`base_context` encodes the §13.10 freshness reconciliation. `remote_sha`
and `behind_count` may be null (offline / no-remote paths); the schema
allows that. Build the subobject separately so the null cases stay
clean:

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
```

Then the main seed:

```bash
jq -n \
  --arg review_id "$review_id" \
  --arg generated_at "$review_started_at" \
  --arg review_started_at "$review_started_at" \
  --arg reviewed_sha "$reviewed_sha" \
  --arg base_branch "$base_branch" \
  --arg head_branch "$head_branch" \
  --arg mode "$mode" \
  --arg pr_state "${pr_state:-}" \
  --argjson pr_number "${pr_number:-null}" \
  --argjson comment_id "${existing_comment_id:-null}" \
  --argjson trivial_mode "$trivial_mode" \
  --argjson base_context "$base_context_json" \
  --argjson reviewed_files_all "$(printf '%s' "$reviewed_files_all" | jq -Rn '[inputs | select(length>0)]')" \
  --argjson claude_md_paths "$(printf '%s' "$claude_md_paths" | jq -Rn '[inputs | select(length>0)]')" \
  --argjson files_changed "$num_files" \
  --argjson lines_changed "$lines_changed" \
  '{
    schema_version: 1,
    review_id: $review_id,
    generated_at: $generated_at,
    review_started_at: $review_started_at,
    reviewed_sha: $reviewed_sha,
    base_branch: $base_branch,
    head_branch: $head_branch,
    mode: $mode,
    pr_state: (if $pr_state == "" then null else $pr_state end),
    pr_number: $pr_number,
    comment_id: $comment_id,
    trivial_mode: $trivial_mode,
    base_context: $base_context,
    reviewer_sources: ["internal"],    # seed — Phase 6.3a recomputes the authoritative list from findings[].sources[] union per DESIGN §6
    reviewed_files_all: $reviewed_files_all,
    claude_md_paths: $claude_md_paths,
    findings: [],
    cross_cutting_groups: [],
    subagent_tokens: {
      total: 0, invocations: 0, by_phase: {}, by_model: {},
      by_lens: {}, by_finding_phase4: {}
    },
    metrics: {
      phase_9_verified_pct: null,
      required_followup: null,
      time_elapsed_seconds: null,
      pr_size_buckets: {files_changed: $files_changed, lines_changed: $lines_changed}
    }
  }' \
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
