## Phase 7 — Load artifact + gates (fix command)

### 7.1. Resolve argument flags

Parse `$ARGUMENTS` (whitespace-split):
- First token that parses as a non-negative integer → `threshold`.
- `--granular-commits` → `granular_commits=true` (else `false`).
- Any other token → stop and ask the user to clarify.

If no integer was provided, `threshold=60`. Record both
in your working context.

### 7.2. Locate the artifact via `latest.txt`

```bash
reviews_root="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
```

Derive `repo_slug` via the shared helper — identical call to Phase 0
step 0.3 so the two phases resolve the same directory:

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
`/tmp/adams-review-invalid-$(date -u +%Y%m%dT%H%M%SZ).json`,
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
  (lock contention, invalid state): log stderr, abort —
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
        # unsafe: abort.
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
  and `fetch_ok` because the active fetch may have failed and the gate
  may have measured against a different ref than the user is told to
  merge — `:review` §0.6a's passive variant skips them since
  `$comparison_ref` is the only ref in play.
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
- Any `gh` error (auth, network) → surface stderr. Pop
  stash if taken, then abort. The abort should NOT try to re-run
  `gh pr view` — it already failed; don't compound the error.

If `mode == "local"` or `pr_number` empty: skip this step; local-mode
fixes still run (they just don't publish to a PR comment in 9e).

### 7.8. Generate `run_id` and capture `input_sha`

`fix_attempts[].run_id` must match `^fixrun_[A-Za-z0-9]+$`. Prefer
ULID; fall back to timestamp + random tail:

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

Capture `run_id`, `input_sha`.

Append a working-set record to `trace.md`:

```bash
printf 'phase_7_ready run_id=%s input_sha=%s threshold=%s granular=%s staleness=%s stash=%s\n' \
    "$run_id" "$input_sha" "$threshold" "$granular_commits" "$staleness_verdict" "${stash_taken:-false}" \
    >> "$trace_log_path"
```

## Phase 7.5 — Auto-recommendation preflight (fix command)

Phase 5.5 (review-time) populates `auto_fix_hint` on findings whose
disposition might otherwise force the user into `:walkthrough`
(`confirmed_manual`, `confirmed_report`, `confirmed_mechanical` —
the latter regardless of lane, so dedup-induced lane/impact_type
mismatches can be surfaced for batch acceptance instead of being
locked out of Phase 8's `impact_type` filter).
Phase 7.5 surfaces those hints to the user
*before* Phase 8 dispatch so a single batch-confirm covers the typical
~90% acceptance case — without the per-finding interactive loop.
Gap-closure for mismatched cases (e.g. deep+ux `confirmed_mechanical`)
is **conditional on the user accepting at Phase 7.5**: acceptance sets
`human_confirmation`, which bypasses Phase 8's `impact_type` filter
and threshold. On `Skip`, Phase 8 still runs but its `impact_type ∈
{correctness, security}` filter excludes the lane/impact_type-mismatched
findings, so they remain at `current_state=open` for the next run. On
`Cancel`, `:fix` aborts before Phase 8 dispatches at all — no filter
runs, and the findings stay at `current_state=open` for the next run.
Either way, the user must resolve them via `:walkthrough` or
`:promote`. The
filter computes against the on-disk artifact at `:fix` time, not the
review-time eligibility, so state shifts since `:review` (e.g. an
intervening `:promote`, an `:add` mutating a finding, or a different
`$threshold`) are honored.

Phase 7.5 runs only after the leftover-`attempted` hard abort (7.4), the
clean-tree gate (7.5), the staleness check (7.6), the
branch-behind-base advisory (7.6a), the PR eligibility recheck (7.7),
and the run_id / input_sha capture (7.8) all pass — i.e. *only* on a
clean baseline that's safe to mutate. Filtering before those gates
would risk surfacing auto-rec on a dirty tree the user hasn't yet
agreed to stash.

### 7.5.1. Compute auto-rec promotable set

```bash
auto_rec_promotable=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter '
      [.findings[]
         | select(.auto_fix_hint != null)
         | select(.current_state == "open")
         | select(.human_confirmation == null)
         | select(.disposition != "pre_existing_report")
         | select(.score_phase4 != null and .score_phase4 >= '"$threshold"')
         | {id, file, line_range, claim, disposition, impact_type, score_phase4, auto_fix_hint}]
    ')
auto_rec_count=$(printf '%s\n' "$auto_rec_promotable" | jq 'length')
```

The filter rechecks `auto_fix_hint != null` (don't trust review-time
generation alone — `:add` may have shifted dispositions or replaced
findings since), `current_state == "open"` (excludes resolved /
attempted), `human_confirmation == null` (excludes already-promoted
findings — auto-rec for them is moot, helper would reject anyway),
and disposition / score gating (mirrors Phase 5.5 eligibility
modulo the at-fix-time threshold). Pre-existing findings are
explicitly excluded so the auto-rec surface never collides with the
walkthrough's `pre_existing_report` issue-filing path.

If `auto_rec_count == 0`, log a one-line skip note and continue to
Phase 8 unchanged:

```bash
if [[ "$auto_rec_count" -eq 0 ]]; then
    printf 'phase_7_5 skipped: no auto-rec eligible at threshold=%s\n' "$threshold" \
        >> "$trace_log_path"
    log-phase.sh \
        --review-dir "$review_dir" --phase 7_5 --name auto-rec-preflight \
        --summary "skipped — no auto-rec eligible at threshold=$threshold"
    # Continue to Phase 8 unchanged.
fi
```

When `auto_rec_count > 0`, proceed to 7.5.2.

### 7.5.2. Render summary table + ask the user

Render a markdown summary table to chat (orchestrator emits directly,
no tool call) covering every promotable finding. Surface
**concerns** prominently — they are the load-bearing signal for
"don't blindly accept this hint." Show concerns in their own column
(or italicized inline below the row when the table would otherwise
overflow) so the user sees them before the AskUserQuestion fires:

```markdown
**$auto_rec_count auto-recommendation(s) ready for batch confirm.**

These findings have `auto_fix_hint` set by Phase 5.5 — Sonnet generated
+ verified a fix direction. Above the threshold ($threshold) and not
yet promoted. The default path applies all of them; review per-finding
or skip if you want a closer look.

| F-id | score | disp | file:line | confidence | hint | concerns? |
|---|---|---|---|---|---|---|
| F003 | 75 | confirmed_manual | src/foo.py:42-58 | high | Update docstring to match the implementation… | — |
| F008 | 68 | confirmed_report | src/bar.ts:120-134 | low | Add validation for the empty-array case… | _verify covers .filter() chain_ |
| F012 | 80 | confirmed_mechanical (ux) | docs/api.md:200-215 | medium | Tighten the typo + casing in the example… | — |
```

Build the rows from `$auto_rec_promotable` via jq. Columns:
- `id` — finding id.
- `score` — `score_phase4` (always non-null per filter).
- `disp` — `disposition` (suffixed with `(<impact_type>)` when
  `disposition == "confirmed_mechanical"` AND `impact_type` is not
  `correctness` or `security`, so the user can spot which mechanical
  findings are in the gap-case bucket — e.g. `confirmed_mechanical (ux)`
  for a deep+ux dedup-merge that needs the Phase 7.5 batch bypass).
- `file:line` — `file` + `line_range[0]-line_range[1]`.
- `confidence` — `auto_fix_hint.confidence` (`high` / `medium` / `low`).
- `hint` — `auto_fix_hint.hint`, truncated to ~80 chars + ellipsis if
  longer (full hint visible in the per-finding loop and the rendered
  artifact).
- `concerns?` — em-dash when `auto_fix_hint.second_opinion == "concurs"`
  OR `concerns` is absent/empty; otherwise the joined concerns string
  in italics. **Do not bury this column** — when `confidence == "low"`
  OR `second_opinion == "concerns"`, italicize the entire row's
  concerns text so the user can scan low-confidence rows at a glance.

Then dispatch `AskUserQuestion` with **four single-select options**,
default highlighted on the first:

- "⭐ Apply all (recommended) — auto-promote $auto_rec_count finding(s) and run Phase 8"
- "Review per-finding — walk each one with promote/edit/skip"
- "Skip these (proceed with originally-eligible only)"
- "Cancel `:fix`"

Capture the choice as `auto_rec_choice` ∈ {`apply_all`, `review`,
`skip`, `cancel`}.

### 7.5.3. Branch on the user's choice

Capture once before any branch:

```bash
auto_rec_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
reviewer=$(git config user.email 2>/dev/null)
[[ -z "$reviewer" ]] && reviewer=$(git config user.name 2>/dev/null)
[[ -z "$reviewer" ]] && reviewer="unknown"
auto_rec_reviewer="auto-rec/$reviewer"
```

Initialize accumulators used by the trace + decisions-log blocks
(7.5.4 / 7.5.5):

```bash
promoted_ids=()    # ids successfully promoted via --apply-auto-rec-promotions
edited_ids=()      # ids promoted via promote-core (alternative or edit-hint)
skipped_ids=()     # ids the user explicitly skipped during review-per-finding
```

#### Apply all

Build the promotion payload and stream to a temp file (CLAUDE.md rule
12 — never echo a JSON-encoded blob through bash; use `printf '%s\n'`
or stream-to-file). Critically, the helper sources `fix_hint`
automatically from `auto_fix_hint.hint` — **do NOT pass `fix_hint` in
the payload** (the helper rejects unknown keys with EXIT_VALIDATION):

```bash
auto_rec_payload_path="$review_dir/phase7_5_promotions.json"
printf '%s\n' "$auto_rec_promotable" \
  | jq --arg reviewer "$auto_rec_reviewer" '
      [ .[] | {
          id: .id,
          reviewer: $reviewer,
          reason: "auto-accepted via :fix Phase 7.5 preflight"
        }]
    ' > "$auto_rec_payload_path"

# --expected guards against payload corruption between jq and helper.
set +e
auto_rec_stderr=$(artifact-patch.py \
    --path "$artifact_path" \
    --apply-auto-rec-promotions "@$auto_rec_payload_path" \
    --expected "$auto_rec_count" \
    2>&1 1>/dev/null)
auto_rec_rc=$?
set -e
```

The payload is a `[{id, reviewer, reason}]` array; the helper sources
`fix_hint` from each finding's `auto_fix_hint.hint` server-side and
snapshots `promoted_from = {disposition, actionability,
score_phase4}`. First-fail-halt: a mid-batch failure leaves preceding
tuples committed.

On non-zero exit (`auto_rec_rc != 0`), abort `:fix` and run the same
stash-pop cleanup as 7.6a's Stop / Abort branches so the user's tree
is restored before the abort surfaces:

```bash
if [[ "$auto_rec_rc" -ne 0 ]]; then
    printf 'phase_7_5 apply_all_failed rc=%s stderr=%s\n' \
        "$auto_rec_rc" "$auto_rec_stderr" >> "$trace_log_path"

    stash_pop_conflict=false
    if [[ "${stash_taken:-false}" == "true" ]]; then
        if ! git stash pop 2>>"$trace_log_path"; then
            stash_pop_conflict=true
            printf 'stash_pop_conflict\n' >> "$trace_log_path"
        fi
    fi

    cat >&2 <<EOF
ERROR: Phase 7.5 batch promote failed (artifact-patch.py rc=$auto_rec_rc).
$auto_rec_stderr

The :fix run is aborted. Some auto-rec promotions may have landed
before the failure (first-fail-halt); inspect the artifact and
re-render preflight on a fresh state.
EOF
    [[ "$stash_pop_conflict" == "true" ]] && \
        echo "Stashed changes preserved — \`git stash list\` / \`git stash apply\` once tree is in desired state." >&2
    exit 1
fi
```

On success, capture the promoted ids from the helper's stdout (which
returns `{"promoted": [...], "total": N}`) — but the user's request
already named `$auto_rec_count` ids and the helper rejects on
mismatch via `--expected`, so the stored set is the same as
`$auto_rec_promotable | jq '[.[].id]'`. Use a while-read loop, not
`mapfile` — Bash 3.2 / macOS doesn't ship the builtin (CLAUDE.md
rule 1):

```bash
while IFS= read -r line; do
    promoted_ids+=("$line")
done < <(printf '%s\n' "$auto_rec_promotable" | jq -r '.[].id')

printf 'phase_7_5 apply_all promoted=%s ids=%s\n' \
    "${#promoted_ids[@]}" "$(IFS=,; printf '%s' "${promoted_ids[*]}")" \
    >> "$trace_log_path"
```

Continue to 7.5.4 (decisions-log POST), then 7.5.5 (trace block), then
Phase 8. Phase 8's eligibility recompute will pick up the now-promoted
findings via the `human_confirmation` bypass — no special wiring
needed.

#### Review per-finding

Initialize a deferred batch for the recommended-hint promotions (the
auto-rec batch fires once at the end of the loop; alternative /
edit-hint promotions go through `promote-core.md` immediately
per-iteration):

```bash
autorec_batch_payload=()
```

Loop over `$auto_rec_promotable` in order. For each entry:

1. **Render the brief** (orchestrator emits markdown directly):

   ```markdown
   ## $finding_id — <first line of claim>

   **File:** `$file:$line_start-$line_end`
   **Score:** $score_phase4 · **Disposition:** $disposition

   **Recommended hint** (confidence: $confidence): <auto_fix_hint.hint>

   <if alternatives exist:>
   **Alternatives:**
   - **B. <alternatives[0].title>** — <alternatives[0].hint>
   - **C. <alternatives[1].title>** — <alternatives[1].hint> (when present)

   <if second_opinion == "concerns":>
   **Concerns:** <concerns joined with "; ">
   ```

2. **Dispatch `AskUserQuestion`** with options:
   - "⭐ Promote with this hint (recommended)" — uses
     `--apply-auto-rec-promotions` (the helper sources hint from
     `auto_fix_hint.hint`).
   - For each alternative `alt_i`: "Promote with alternative
     **$alt_i.label**: $alt_i.title" — falls through to the
     `promote-core.md` path with `fix_hint = alt_i.hint`.
   - "✎ Edit the hint" — captures a free-form replacement string via
     a follow-up `AskUserQuestion`, then promotes via
     `promote-core.md` with the edited hint.
   - "Skip this finding".

3. **Branch on the choice:**
   - **Promote with this hint** — build one batch entry via jq (so
     the JSON is well-formed regardless of what's in the id /
     reviewer / reason strings) and append to
     `autorec_batch_payload`; apply once at end-of-loop via
     `--apply-auto-rec-promotions`:

     ```bash
     entry=$(jq -nc \
         --arg id "$finding_id" \
         --arg reviewer "$auto_rec_reviewer" \
         --arg reason "auto-accepted via :fix Phase 7.5 preflight (per-finding)" \
         '{id: $id, reviewer: $reviewer, reason: $reason}')
     autorec_batch_payload+=("$entry")
     ```
   - **Promote with alternative `alt_i`** OR **Edit the hint** —
     execute `promote-core.md`'s steps 3, 4, 4.5 (skipped — `$fix_hint`
     is non-empty), 5, 6, 9 inline with ambient context:
     `finding_id`, `reason="walkthrough-style alt for $finding_id"`
     or `"edit-hint for $finding_id"`, `fix_hint=<alt.hint or
     edited string>`, `force=false`, `artifact_path`, `trace_log_path`.
     Promote-core writes `human_confirmation.reviewer` from
     `$reviewer` (the user's git email), so the audit trail
     differentiates per-finding edits from auto-rec batch acceptance
     by reviewer prefix (`auto-rec/<email>` for batch; bare `<email>`
     for promote-core). Append the finding id to `edited_ids` after
     promote-core returns.
   - **Skip this finding** — append id to `skipped_ids`. No mutation.

4. **Between iterations:** print one terse line to chat ("F008 →
   promoted with recommended hint. 3 of 7 processed.") so the user has
   running feedback. No render or publish per-iteration.

After the loop, apply the deferred auto-rec batch in one helper call
(matches Apply-all's pattern; same error handling — non-zero aborts
`:fix` with stash-pop):

```bash
if (( ${#autorec_batch_payload[@]} > 0 )); then
    autorec_batch_path="$review_dir/phase7_5_promotions.json"
    printf '%s\n' "${autorec_batch_payload[@]}" \
      | jq -s '.' > "$autorec_batch_path"

    autorec_batch_count=$(jq 'length' < "$autorec_batch_path")

    set +e
    autorec_stderr=$(artifact-patch.py \
        --path "$artifact_path" \
        --apply-auto-rec-promotions "@$autorec_batch_path" \
        --expected "$autorec_batch_count" \
        2>&1 1>/dev/null)
    autorec_rc=$?
    set -e

    if [[ "$autorec_rc" -ne 0 ]]; then
        # Same abort cleanup as Apply all's failure path. Note: the
        # promote-core path (alt / edit-hint) above ALREADY committed
        # those promotions one-by-one; only the deferred auto-rec batch
        # is rolled back here. The artifact may now have a partial
        # set of promotions — this is acceptable per first-fail-halt
        # semantics; the user re-runs from the new fresh state.
        printf 'phase_7_5 review_batch_failed rc=%s stderr=%s\n' \
            "$autorec_rc" "$autorec_stderr" >> "$trace_log_path"

        stash_pop_conflict=false
        if [[ "${stash_taken:-false}" == "true" ]]; then
            if ! git stash pop 2>>"$trace_log_path"; then
                stash_pop_conflict=true
                printf 'stash_pop_conflict\n' >> "$trace_log_path"
            fi
        fi

        edited_summary="<none>"
        if (( ${#edited_ids[@]} > 0 )); then
            edited_summary="${edited_ids[*]}"
        fi
        cat >&2 <<EOF
ERROR: Phase 7.5 deferred batch promote failed (artifact-patch.py rc=$autorec_rc).
$autorec_stderr

Per-finding promote-core promotions (alternatives / edited hints) for
ids $edited_summary have already landed. The auto-rec batch for the
remaining accepted ids was rejected. The :fix run is aborted.
EOF
        [[ "$stash_pop_conflict" == "true" ]] && \
            echo "Stashed changes preserved — \`git stash list\` / \`git stash apply\` once tree is in desired state." >&2
        exit 1
    fi

    # Successfully applied — auto-rec batch ids are the {id} field of each payload entry.
    while IFS= read -r line; do promoted_ids+=("$line"); done \
        < <(jq -r '.[].id' < "$autorec_batch_path")
fi

printf 'phase_7_5 review promoted=%s edited=%s skipped=%s\n' \
    "${#promoted_ids[@]}" "${#edited_ids[@]}" "${#skipped_ids[@]}" \
    >> "$trace_log_path"
```

Continue to 7.5.4 (decisions-log POST), then 7.5.5 (trace block), then
Phase 8.

#### Skip these

Log skip in trace and continue to Phase 8 with the
originally-eligible findings only. The auto-rec findings remain at
`current_state=open` for the next `:fix` run. **Do not** post a PR
comment — the user explicitly said skip; no audit trail beyond the
local trace line is warranted (mirrors the no-decision walkthrough
shape).

```bash
printf 'phase_7_5 skipped_by_user count=%s\n' "$auto_rec_count" \
    >> "$trace_log_path"

log-phase.sh \
    --review-dir "$review_dir" --phase 7_5 --name auto-rec-preflight \
    --summary "skipped by user — $auto_rec_count auto-rec finding(s) left at current_state=open"
```

Skip 7.5.4 and 7.5.5; proceed to Phase 8 unchanged.

#### Cancel `:fix`

Abort. Restore stash if Phase 7's clean-tree gate took one (mirroring
the §7.6a Abort path). No artifact mutation; the auto-rec findings
stay at `current_state=open` for the next `:fix` run. **Do not** post
a PR comment.

```bash
printf 'phase_7_5 cancelled_by_user auto_rec_count=%s\n' "$auto_rec_count" \
    >> "$trace_log_path"

log-phase.sh \
    --review-dir "$review_dir" --phase 7_5 --name auto-rec-preflight \
    --summary "cancelled by user — :fix aborted, no fix groups dispatched"

stash_pop_conflict=false
if [[ "${stash_taken:-false}" == "true" ]]; then
    if ! git stash pop 2>>"$trace_log_path"; then
        stash_pop_conflict=true
        printf 'stash_pop_conflict\n' >> "$trace_log_path"
    fi
fi

cat >&2 <<EOF
:fix cancelled at Phase 7.5 preflight. No findings were promoted; the
auto-rec batch is intact for the next run.
EOF
[[ "$stash_pop_conflict" == "true" ]] && \
    echo "Stashed changes preserved — \`git stash list\` / \`git stash apply\` once tree is in desired state." >&2
exit 1
```

Exit 1 — the spec asks for "exit non-zero" on cancel. Distinct from
the clean-tree gate's "Stop so I can handle them first" exit 0
because that path leaves the user's code untouched and is the
expected halt route for a dirty tree; Phase 7.5 cancel happens after
gates already passed and the user has actively rejected the auto-rec
surface. A non-zero exit signals to wrappers / scripts that this run
did not complete its purpose.

### 7.5.4. Post auto-rec decisions-log PR comment (PR mode only)

Skip when `mode == "local"` (no PR to comment on — the local trace
entry at 7.5.5 is the audit record).

Skip when no promotions or edits landed (i.e. both `promoted_ids` and
`edited_ids` are empty — the only paths that reach 7.5.4 with neither
populated are degenerate and shouldn't post a no-op comment).

```bash
if [[ "$mode" == "pr" && -n "$pr_number" ]] && \
   (( ${#promoted_ids[@]} > 0 || ${#edited_ids[@]} > 0 )); then
    decisions_body=$(mktemp -t adams-fix-autorec-body.XXXXXX)
    err_tmp=$(mktemp -t adams-fix-autorec-gh-err.XXXXXX)

    {
        printf '<!-- adams-review-fix-autorec-v1 -->\n'
        printf '### Auto-recommendation acceptance\n\n'
        printf '`%s` · run_id=%s · choice=%s · threshold=%s · reviewer=%s · ts=%s\n\n' \
            "$review_id" "$run_id" "$auto_rec_choice" "$threshold" "$auto_rec_reviewer" "$auto_rec_ts"
        printf '%s auto-rec finding(s) eligible at threshold ≥ %s. Of those, **%s** auto-promoted via batch, **%s** promoted with an edited or alternative hint, **%s** skipped per-finding.\n\n' \
            "$auto_rec_count" "$threshold" "${#promoted_ids[@]}" "${#edited_ids[@]}" "${#skipped_ids[@]}"
        if (( ${#promoted_ids[@]} > 0 )); then
            printf '#### Promoted (batch)\n\n'
            for fid in "${promoted_ids[@]}"; do
                claim_first=$(jq -r --arg id "$fid" \
                    '.findings[] | select(.id == $id) | .claim | split("\n") | .[0]' \
                    "$artifact_path")
                hint=$(jq -r --arg id "$fid" \
                    '.findings[] | select(.id == $id) | .auto_fix_hint.hint' \
                    "$artifact_path")
                printf -- '- **%s** — %s\n  - **Hint:** `%s`\n' "$fid" "$claim_first" "$hint"
            done
            printf '\n'
        fi
        if (( ${#edited_ids[@]} > 0 )); then
            printf '#### Promoted (alternative or edited hint)\n\n'
            for fid in "${edited_ids[@]}"; do
                claim_first=$(jq -r --arg id "$fid" \
                    '.findings[] | select(.id == $id) | .claim | split("\n") | .[0]' \
                    "$artifact_path")
                hint=$(jq -r --arg id "$fid" \
                    '.findings[] | select(.id == $id) | .human_confirmation.fix_hint // "—"' \
                    "$artifact_path")
                printf -- '- **%s** — %s\n  - **Hint:** `%s`\n' "$fid" "$claim_first" "$hint"
            done
            printf '\n'
        fi
        if (( ${#skipped_ids[@]} > 0 )); then
            printf '#### Skipped during per-finding review\n\n'
            for fid in "${skipped_ids[@]}"; do
                claim_first=$(jq -r --arg id "$fid" \
                    '.findings[] | select(.id == $id) | .claim | split("\n") | .[0]' \
                    "$artifact_path")
                printf -- '- **%s** — %s\n' "$fid" "$claim_first"
            done
            printf '\n'
        fi
        printf '---\n\n'
        printf 'Auto-recommendation acceptance: append-only audit. Each `/adamsreview:fix` run posts a fresh entry. Promoted findings are now `confirmed_mechanical` with `human_confirmation` set; Phase 8 dispatches them next.\n'
    } > "$decisions_body"

    set +e
    autorec_comment_id=$(gh api \
        --method POST \
        "repos/{owner}/{repo}/issues/$pr_number/comments" \
        -F "body=@$decisions_body" \
        --jq '.id' 2>"$err_tmp")
    gh_rc=$?
    set -e

    if [[ "$gh_rc" -ne 0 ]]; then
        {
            printf '## phase_7_5_decisions_comment_failed (%s)\n' "$auto_rec_ts"
            printf 'gh_rc=%s\n' "$gh_rc"
            printf 'stderr:\n'
            cat "$err_tmp"
            printf '\n---\nrendered body:\n'
            cat "$decisions_body"
            printf '\n'
        } >> "$trace_log_path"
    else
        printf 'phase_7_5_decisions_comment_id=%s\n' "$autorec_comment_id" \
            >> "$trace_log_path"
    fi

    rm -f "$decisions_body" "$err_tmp"
fi
```

Post failure is non-fatal — the artifact is already patched; the user
can recover the comment body from `trace.md`'s
`phase_7_5_decisions_comment_failed` block. Continue to 7.5.5.

### 7.5.5. Append phase_7_5 trace block

```bash
{
    printf '## phase_7_5_auto_rec (%s)\n' "$auto_rec_ts"
    printf 'review_id=%s run_id=%s threshold=%s\n' \
        "$review_id" "$run_id" "$threshold"
    printf 'auto_rec_count=%s choice=%s\n' \
        "$auto_rec_count" "$auto_rec_choice"
    if (( ${#promoted_ids[@]} > 0 )); then
        printf 'promoted: %s\n' "${promoted_ids[*]}"
    fi
    if (( ${#edited_ids[@]} > 0 )); then
        printf 'edited: %s\n' "${edited_ids[*]}"
    fi
    if (( ${#skipped_ids[@]} > 0 )); then
        printf 'skipped: %s\n' "${skipped_ids[*]}"
    fi
    [[ -n "${autorec_comment_id:-}" ]] && \
        printf 'decisions_comment_id=%s\n' "$autorec_comment_id"
    printf '\n'
} >> "$trace_log_path"

log-phase.sh \
    --review-dir "$review_dir" --phase 7_5 --name auto-rec-preflight \
    --summary "auto_rec_count=$auto_rec_count choice=$auto_rec_choice promoted=${#promoted_ids[@]} edited=${#edited_ids[@]} skipped=${#skipped_ids[@]}"
```

Clean up the on-disk payload(s) so subsequent runs don't accidentally
reuse them:

```bash
rm -f "$review_dir/phase7_5_promotions.json"
```

Continue to Phase 8. The dispatch's eligibility recompute (`8.1`) will
include every finding promoted in this phase via the
`human_confirmation` bypass, regardless of disposition or impact_type
or score gate — i.e. light-lane `confirmed_manual` and
`confirmed_report` findings the auto-rec promoted are now
auto-fixable for this run.
