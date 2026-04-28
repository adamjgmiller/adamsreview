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
