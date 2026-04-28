## Phase 7 — Load artifact + gates (fix command)

Phase 7 sets up every downstream fix-run variable from the artifact on
disk, applies the four gates (leftover-`attempted` hard abort, clean
tree, staleness, PR eligibility), and generates the run identity.
Mostly deterministic shell — no LLM calls.

Work through the steps below in order. Capture each named variable
into your working context — later phases will reference them by name
("the `run_id` captured in Phase 7").

### 7.1. Resolve argument flags

Parse `$ARGUMENTS` (whitespace-split):
- First token that parses as a non-negative integer → `threshold`.
- `--granular-commits` → `granular_commits=true` (else `false`).
- Any other token → stop and ask the user to clarify.

If no integer was provided, `threshold=60` (DESIGN §13.2). Record both
in your working context.

### 7.2. Locate the artifact via `latest.txt`

```bash
reviews_root="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
```

Derive `repo_slug` via the shared helper — identical call to Phase 0
step 0.3 so the two phases resolve the same directory (DESIGN §9.2):

```bash
repo_slug=$(repo-slug.sh --repo-root "$repo_root")
latest_path="$reviews_root/$repo_slug/$head_branch/latest.txt"
```

If `latest.txt` is missing or empty → abort with the user-visible
message:

> No review found for this branch (`$head_branch`) under
> `$reviews_root/$repo_slug/`. Run `/adamsreview:review` first.

Otherwise read `review_id` from it:

```bash
review_id=$(tr -d '[:space:]' < "$latest_path")
review_dir="$reviews_root/$repo_slug/$head_branch/$review_id"
artifact_path="$review_dir/artifact.json"
trace_log_path="$review_dir/trace.md"
phases_log_path="$review_dir/phases.jsonl"
tokens_log_path="$review_dir/tokens.jsonl"
```

Capture all paths. Append a Phase 7 header to `trace.md`:

```bash
log-phase.sh \
  --review-dir "$review_dir" --phase 7 --name fix-loader \
  --summary "loading review $review_id; threshold=$threshold granular_commits=$granular_commits"
```

### 7.3. Schema-validate the artifact

```bash
artifact-validate.sh --path "$artifact_path"
```

On non-zero: log the validator stderr to `trace.md`, dump a copy to
`/tmp/adams-review-invalid-$(date -u +%Y%m%dT%H%M%SZ).json` per §24.3,
and abort. A schema-invalid artifact means something upstream broke
the invariant; do NOT try to "fix" by patching — surface to the user.

### 7.4. Leftover-`attempted` hard abort (§4 Phase 7 step 4)

```bash
leftover_ids=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter '[.findings[] | select(.current_state == "attempted") | .id] | join(", ")')
```

If `leftover_ids` is non-empty, print the deterministic recovery
message and abort (do NOT mutate state; the user decides):

> ERROR: previous /adamsreview:fix run did not finish (N findings
> still in 'attempted').
> The working tree may still contain partial fix edits from that run.
>
> Recover:
>   1. `git status` — inspect what's uncommitted.
>   2. If the uncommitted changes are ONLY from the interrupted fix run
>      and you want to discard them: `git restore .` (and `git clean
>      -fd` for any new files the fix agents created). Alternatively,
>      commit or stash them yourself if you want to keep them.
>   3. For each leftover 'attempted' finding, reset state manually:
>      artifact-patch.py --finding-id <id> --set current_state=open
>   4. Re-run /adamsreview:fix.
>
> Leftover 'attempted' finding ids: `$leftover_ids`

Substitute `N` with the count and `$leftover_ids` with the list. Exit
non-zero. No `fix_attempts` are appended and no artifact state
changes — recovery is the user's job.

### 7.5. Clean-tree gate

```bash
dirty=$(git status --porcelain)
```

If empty: `stash_taken=false`; skip to 7.6.

Otherwise categorize (filenames only — do NOT dump diffs) and prompt:

- **Modified**: lines starting with ` M` or `M`.
- **Staged**: lines starting with `A` / `M` in the index column (first char).
- **Untracked**: lines starting with `??`.

Dispatch `AskUserQuestion` once with two options:

- **Stash my changes, run fix, restore** (recommended). Run
  `git stash push --include-untracked -m "pre-adams-review-fix-stash"`
  immediately. Capture `stash_taken=true`. If the stash command fails
  (lock contention, invalid state): log stderr, abort per §24.2 —
  user resolves.
- **Stop so I can handle them first** — exit 0 with a one-line
  message; do NOT mutate state.

The stash route preserves the user's work behind a clean baseline so
§4 Phase 9b's per-group revert (`git checkout --` / `rm -f`) doesn't
collide with in-flight edits.

### 7.6. File-overlap staleness check (§4 Phase 7 step 6, §13.3)

Derive `latest_known_sha`:

```bash
latest_known_sha=$(jq -r '
    ( [.findings[].fix_attempts[]?.output_sha | select(. != null)] | last )
    // .reviewed_sha
' "$artifact_path")
```

The fallback chain: most recent non-null `fix_attempts[-1].output_sha`
across all findings, else the artifact's `reviewed_sha`. If every
prior fix_attempt was overlap-abort or all-regression (all output_sha
null), the chain falls through to `reviewed_sha` — the original
review anchor.

Compare against HEAD:

```bash
head_sha=$(git rev-parse HEAD)
if [[ "$head_sha" == "$latest_known_sha" ]]; then
    # Fresh — HEAD is exactly what the artifact tracks.
    staleness_verdict="safe"
else
    # HEAD moved — intersect with reviewed_files_all.
    reviewed_files=$(artifact-read.sh \
        --path "$artifact_path" \
        --filter '.reviewed_files_all | join("\n")')
    set +e
    staleness_stdout=$(printf '%s\n' "$reviewed_files" | \
        staleness.sh \
          --reviewed-sha "$latest_known_sha" --reviewed-files @- 2>&1)
    staleness_rc=$?
    set -e
    if [[ $staleness_rc -eq 0 ]]; then
        staleness_verdict="warn"   # stdout starts with "warn:"
        printf 'staleness: %s\n' "$staleness_stdout" >> "$trace_log_path"
    else
        # unsafe: abort per §4 Phase 7 step 6.
        printf 'staleness: %s\n' "$staleness_stdout" >> "$trace_log_path"
        echo "Reviewed files have changed since the last known-good SHA." >&2
        echo "$staleness_stdout" >&2
        echo "Re-run /adamsreview:review, or check 'git log $latest_known_sha..HEAD' to see what moved." >&2
        # Pop stash if we took one — don't leave the user's tree
        # behind a stash because we aborted before Phase 8 ran.
        if [[ "${stash_taken:-false}" == "true" ]]; then
            git stash pop || true
        fi
        exit 1
    fi
fi
```

Capture `latest_known_sha`, `staleness_verdict`.

### 7.6a. Branch-behind-base advisory

Active fetch — the artifact's review-time freshness snapshot may have
aged since `:review` ran. Use an explicit refspec
(`refs/heads/<base>:refs/remotes/origin/<base>`) so the fetch updates
`refs/remotes/origin/<base>` even under narrow `remote.origin.fetch`
configs that would otherwise update only `FETCH_HEAD` and leave a
stale `origin/<base>` in place. Route the rev-list by fetch success:
on success, prefer `origin/<base>` (with a defensive fallback to
local `<base>` if it somehow still doesn't resolve); on failure, fall
back to local `<base>` AND surface a "fetch failed" note so the user
knows the count may itself be stale (a bare `origin/<base>` rev-list
would silently resolve from cached refs and mislead). Track
`$merge_ref` alongside the count so the Stop guidance points at the
same ref the count was actually against — telling the user to merge
local `<base>` when the count was against `origin/<base>` would be a
no-op against a still-stale local ref. The fetch is bounded by a 30s
soft timeout (GNU `timeout` when available, background+watchdog
fallback otherwise), mirroring `freshness-gate.sh`'s §0.2a pattern so
a hung remote can't block the fix run indefinitely. When neither
`origin/$base_branch` nor local `$base_branch` resolves to a count,
emit a `branch_behind_base unresolvable` trace line so an operator
inspecting `trace.md` later can distinguish a genuinely-up-to-date
branch (`behind=0`) from a silently-degraded gate (also `behind=0`).
When the fetch fails AND the local fallback resolves to `behind=0`,
emit a `branch_behind_base degraded` trace line — the gate decides
not to fire (no `AskUserQuestion` since `behind == 0`), but the
operator still needs a trail showing the count came from a possibly
stale local ref.

```bash
base_branch=$(jq -r '.base_branch' "$artifact_path")
fetch_ok=true
if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout 30 git fetch origin \
        "refs/heads/$base_branch:refs/remotes/origin/$base_branch" \
        --quiet 2>/dev/null \
        || fetch_ok=false
else
    ( GIT_TERMINAL_PROMPT=0 git fetch origin \
        "refs/heads/$base_branch:refs/remotes/origin/$base_branch" \
        --quiet 2>/dev/null ) &
    fetch_pid=$!
    ( sleep 30 && kill -TERM "$fetch_pid" 2>/dev/null ) &
    watchdog_pid=$!
    wait "$fetch_pid" 2>/dev/null || fetch_ok=false
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
fi
if $fetch_ok; then
    if behind=$(git rev-list --count "HEAD..origin/$base_branch" 2>/dev/null); then
        merge_ref="origin/$base_branch"
    else
        # origin/<base> didn't resolve — narrow-refspec edge — fall back to local
        if behind=$(git rev-list --count "HEAD..$base_branch" 2>/dev/null); then
            merge_ref="$base_branch"
        else
            behind=0
            merge_ref="$base_branch"
            printf '[%s] branch_behind_base unresolvable fetch_ok=true local_resolve=false base_branch=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_branch" \
                >> "$trace_log_path"
        fi
    fi
    fetch_note=""
else
    if behind=$(git rev-list --count "HEAD..$base_branch" 2>/dev/null); then
        merge_ref="$base_branch"
        if [[ "$behind" == "0" ]]; then
            # Degraded fail-silent path: fetch failed, local rev-list
            # resolved to 0. The AskUserQuestion below won't fire (gated
            # on `behind > 0`), so without this trace line `trace.md`
            # has no signal distinguishing "branch genuinely fresh" from
            # "fetch failed, local says 0 but local may be stale."
            printf '[%s] branch_behind_base degraded fetch_ok=false local_resolve=true behind=0 base_branch=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_branch" \
                >> "$trace_log_path"
        fi
    else
        behind=0
        merge_ref="$base_branch"
        printf '[%s] branch_behind_base unresolvable fetch_ok=false local_resolve=false base_branch=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_branch" \
            >> "$trace_log_path"
    fi
    fetch_note=" (Note: fetch of \`origin/$base_branch\` failed; behind-count is from local \`$base_branch\`, which may itself be stale.)"
fi
```

Fail-open on any non-zero git exit — the gate is a warning surface, not
a precondition.

All three branches (Proceed / Stop / Abort) write a distinct
`branch_behind_base <verdict>` audit line to `trace.md` so an operator
reading the trace later can tell which path the user took.

If `$behind > 0`, `AskUserQuestion` once:

> Branch `$head_branch` is `$behind` commits behind `$base_branch`.$fetch_note
> The fix run will edit code that may merge-conflict with `$base_branch`,
> and `$base_branch` may have shifted shared context the fix planner
> can't see. Recommend merging `$merge_ref` into `$head_branch` first.

- **(a) Stop — I'll merge `$merge_ref` into `$head_branch` first, then re-run.** Run the stash-pop block
  below if step 7.5 took one, then emit a `branch_behind_base stopped`
  trace line, then exit 0 with: `Stopping. Run \`git merge $merge_ref\` (or fast-forward) on \`$head_branch\`, then re-run /adamsreview:fix.`
  If `stash_pop_conflict=true`, append: `Stashed changes preserved — \`git stash list\` / \`git stash apply\` once tree is in desired state.`
  ```bash
  stash_pop_conflict=false
  if [[ "${stash_taken:-false}" == "true" ]]; then
      if ! git stash pop 2>>"$trace_log_path"; then
          stash_pop_conflict=true
          printf 'stash_pop_conflict\n' >> "$trace_log_path"
      fi
  fi
  printf '[%s] branch_behind_base stopped behind=%s merge_ref=%s fetch_ok=%s stash_pop_conflict=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$behind" "$merge_ref" "$fetch_ok" "$stash_pop_conflict" \
      >> "$trace_log_path"
  ```
- **(b) Proceed.** Append a trace line and continue. Logs `merge_ref`
  and `fetch_ok` alongside the count so an operator reading `trace.md`
  later can tell which ref the count was measured against and whether
  the active fetch succeeded — mirrors `:review` §0.6a's
  Proceed-on-warning pattern; the active variants additionally log
  `merge_ref` and `fetch_ok` because the fetch may have failed and the
  gate may have measured against a different ref than the user is told
  to merge.
  ```bash
  printf '[%s] branch_behind_base proceeded behind=%s merge_ref=%s fetch_ok=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$behind" "$merge_ref" "$fetch_ok" \
      >> "$trace_log_path"
  ```
- **(c) Abort.** Run the same stash-pop block as (a) (inlined here for
  execution clarity — the duplication is intentional so an orchestrator
  following (c)'s bash recipe verbatim still pops the stash and
  initializes `$stash_pop_conflict` before the abort trace) and emit a
  `branch_behind_base aborted` trace line (same field shape as Stop's),
  then exit 0 with `Aborted.`. If `stash_pop_conflict=true`, append:
  `Stashed changes preserved — \`git stash list\` / \`git stash apply\` once tree is in desired state.`
  ```bash
  stash_pop_conflict=false
  if [[ "${stash_taken:-false}" == "true" ]]; then
      if ! git stash pop 2>>"$trace_log_path"; then
          stash_pop_conflict=true
          printf 'stash_pop_conflict\n' >> "$trace_log_path"
      fi
  fi
  printf '[%s] branch_behind_base aborted behind=%s merge_ref=%s fetch_ok=%s stash_pop_conflict=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$behind" "$merge_ref" "$fetch_ok" "$stash_pop_conflict" \
      >> "$trace_log_path"
  ```

### 7.7. PR eligibility recheck

Load `mode` and `pr_number` from the artifact:

```bash
mode=$(jq -r '.mode' "$artifact_path")
pr_number=$(jq -r '.pr_number // empty' "$artifact_path")
comment_id=$(jq -r '.comment_id // empty' "$artifact_path")
```

If `mode == "pr"` AND `pr_number` is non-empty:

```bash
pr_json=$(gh pr view "$pr_number" --json state,isDraft)
pr_raw_state=$(jq -r '.state' <<<"$pr_json")
pr_is_draft=$(jq -r '.isDraft' <<<"$pr_json")
```

- `state == "CLOSED"` or `"MERGED"` → abort with the user-visible
  message "PR #$pr_number is $pr_raw_state; fixes not applied."
  Pop stash if taken (so the user's working tree is restored before
  the abort surfaces).
- `state == "OPEN"` → proceed. Capture `pr_state="draft"` if
  `isDraft` else `"open"`.
- Any `gh` error (auth, network) → surface stderr per §24.2. Pop
  stash if taken, then abort. The abort should NOT try to re-run
  `gh pr view` — it already failed; don't compound the error.

If `mode == "local"` or `pr_number` empty: skip this step; local-mode
fixes still run (they just don't publish to a PR comment in 9e).

### 7.8. Generate `run_id` and capture `input_sha`

Per DESIGN §6 schema, `fix_attempts[].run_id` must match
`^fixrun_[A-Za-z0-9]+$`. Prefer ULID; fall back to timestamp + random
tail (same pattern as Phase 0 step 0.15):

```bash
if ulid=$(uv run --with ulid-py python3 -c 'import ulid; print(ulid.new())' 2>/dev/null); then
    run_id="fixrun_${ulid}"
else
    # Schema excludes underscores in [A-Za-z0-9], so concat without
    # a separator between the timestamp and the random tail.
    run_id="fixrun_$(date -u +%Y%m%dT%H%M%SZ)$(openssl rand -hex 3)"
fi
input_sha=$(git rev-parse HEAD)
```

Capture `run_id`, `input_sha`. The pair `(run_id, fix_group_id)`
uniquely identifies a specific group across the lifetime of the
project (§24.4); `fix_group_id` alone only scopes within `run_id`.

Append a working-set record to `trace.md`:

```bash
printf 'phase_7_ready run_id=%s input_sha=%s threshold=%s granular=%s staleness=%s stash=%s\n' \
    "$run_id" "$input_sha" "$threshold" "$granular_commits" "$staleness_verdict" "${stash_taken:-false}" \
    >> "$trace_log_path"
```

### Working-set delta after Phase 7

- **Loaded from artifact** (§25.1): `review_id`, `review_dir`,
  `artifact_path`, `base_branch`, `head_branch`, `reviewed_sha`,
  `reviewed_files_all`, `claude_md_paths`, `mode`, `pr_number`,
  `pr_state`, `comment_id`, `trivial_mode`, `reviewer_sources`, all
  log paths.
- **Fix-run-specific** (§25.2): `threshold`, `granular_commits`,
  `run_id`, `input_sha`, `latest_known_sha`, `staleness_verdict`,
  `stash_taken`.
- **Gates passed**: leftover-attempted clear, tree clean (or stashed),
  staleness safe or warn, PR open (or local mode).
- **Helper paths** (convenience for later phases — every path is
  absolute so no cwd assumption leaks in):
  - `log-phase.sh`, `artifact-patch.py`, `artifact-read.sh`,
    `artifact-validate.sh`, `artifact-render.py`,
    `artifact-publish.sh`, `group-fixes.py`, `staleness.sh`,
    `log-tokens.sh`.

Phase 8 reads these by name.
