# Branch-behind-base preflight gate

**Status:** drafted 2026-04-26, awaiting user review.
**Pattern:** mirrors Stage 2.6's freshness gate — preflight invariant, error-as-prompt, smoke-tested. Three insertion points (one per lifecycle command), one new helper.
**Picks up:** the deferred item from `plans/stage-2.6-freshness-origin.md` §3.1 ("Staleness-of-PR-branch-relative-to-base ... a separate axis from freshness-of-local-base. Deferred.").

---

## Context

Phase 0.2a's `freshness-gate.sh` covers one axis of staleness — is *local* `$base_branch` current with `origin/$base_branch`. It does not cover the rotated axis: has `$base_branch` (or `origin/$base_branch`) moved forward since the review branch was cut?

When `$base_branch` has moved forward and the branch hasn't merged it in, three things go wrong:

1. **Phantom deletions in the lens diff.** `git diff $comparison_ref..HEAD` is endpoint-vs-endpoint (two-dot). Files added on `$base_branch` that the branch lacks show up as "deletions" on HEAD. Lenses see a PR that "removes" code `$base_branch` actually added. Mitigated post-hoc by `origin-crosscheck.sh` blame-tracing, but at lens-prompt-budget cost and only for candidates that survive Phase 1. GitHub's PR diff uses three-dot semantics so doesn't suffer this; we don't.
2. **Stale review baseline.** `$base_branch` may have landed a security fix, an API rename, or a refactor the branch is unaware of. The lenses can't flag the resulting incompatibility because they don't see new `$base_branch` as context.
3. **Latent merge conflicts.** Branch reviews clean, then merging `$base_branch` introduces conflicts that change the very code we just reviewed.

Today there is no behind-base check anywhere — no `git rev-list --count HEAD..$comparison_ref` in fragments, helpers, or plans.

**Outcome this delivers.** All three lifecycle commands (`:review`, `:fix`, `:add`) preflight-check whether HEAD is behind `$comparison_ref`. Behind > 0 always surfaces an `AskUserQuestion`; the prompt body adapts to whether `$base_branch`'s drift overlaps the PR's files. The recommended option stops the command so the user can `git merge $base_branch` first; the proceed option logs a warning and continues.

---

## 1. Goal

1. New helper `bin/branch-behind-base.sh` — two modes: passive (`--comparison-ref <ref>`, no fetch) and active-fetch (`--fetch-base <name>`, runs `git fetch origin <base>` with soft timeout, falls back to local on no-remote / fetch failure). Emits `{behind_count, overlap_count, overlap_files[], comparison_ref_used, warnings[]}`. The only working-tree-adjacent side effect is the `FETCH_HEAD` / `origin/<base>` update from active-fetch mode (same as `freshness-gate.sh`'s initial fetch).
2. Insert preflight invocation at three points:
   - **`:review`** — new step `0.6a` in `fragments/00-preflight.md`, between 0.6 (compute `reviewed_files_all`) and 0.7 (enumerate `claude_md_paths`). **Passive mode** — `freshness-gate.sh` at 0.2a already fetched. Runs *before* `review_dir` is created (0.15), so option (a)/(c) exits leave nothing on disk.
   - **`:fix`** — new step `7.6a` in `fragments/08-fix-loader.md`, between 7.6 (file-overlap staleness vs `reviewed_sha`) and 7.7 (PR eligibility recheck). **Active-fetch mode** — reads `base_branch` from the artifact and asks the helper to fetch fresh. Runs *before* 7.8 (run_id generation), so option (a)/(c) exits leave nothing in `fix_attempts`.
   - **`:add`** — new step `3a` in `commands/add.md`, between step 3 (leftover-attempted abort) and step 4 (build candidate array). **Active-fetch mode**, same shape as `:fix`.
3. Orchestrator-side `AskUserQuestion` with three options (always offered when `behind_count > 0`, regardless of overlap; the prompt body just reads differently):
   - **(a) Stop — I'll merge `$base_branch` into `$head_branch` first** (recommended). Exit 0 with a one-liner instructing the user to merge and re-run.
   - **(b) Proceed.** Continues; the prompt body's caveat tells the user what to expect (phantom-deletion path vs latent-baseline path).
   - **(c) Abort.** Exit 0, plain.
4. `behind_count == 0` is silent.

**Done when:**

1. `branch-behind-base.sh` invoked on a branch with `behind=N, overlap=M` emits `{behind_count: N, overlap_count: M, overlap_files: [...]}`. `behind=0` short-circuits without computing the diff.
2. `:review` Phase 0.6a: behind-with-overlap branch surfaces (a)/(b)/(c); option (a) exits 0 with no `review_dir` created, no `latest.txt` written.
3. `:review` Phase 0.6a: behind-without-overlap branch surfaces the same options with the no-overlap context blurb; option (b) proceeds with `branch_behind_base behind=N overlap=0` flushed to `trace.md` via `preflight_warnings`.
4. `:fix` Phase 7.6a: behind branch surfaces the same gate; option (a) exits 0 with no `run_id` generated, no commit, no push, no `fix_attempts` append.
5. `:add` step 3a: behind branch surfaces the same gate; option (a) exits with no patch to artifact, no `--add-finding` calls.
6. `behind_count == 0` happy path is silent in all three commands.
7. `test/smoke.sh` adds `BB-*` assertions covering: helper passive-mode happy path + bad-ref + truncate, active-fetch success + no-remote fallback + fetch-failure fallback + mode-mutex usage error, plus orchestrator-flow assertions for each of `:review` / `:fix` / `:add` writing the expected trace line on a behind fixture.
8. CLAUDE.md gains a one-line entry under "Helper index" (`branch-behind-base.sh`) and a one-paragraph mention in the pipeline-shape diagram (Phase 0 + Phase 7) noting the new gate.

---

## 2. Ground rules (restated from CLAUDE.md)

- Bash 3.2-safe (operational rule 1) — no `declare -A`, no `mapfile`. `comm`/`sort`/`awk` are fine.
- Exit codes from `_common.py` (rule 3): 0 success, 1 validation, 64 usage. No new exit codes.
- Error-as-prompt on every helper failure (rule 4).
- `bin/` already on `$PATH` via plugin runtime — bare-name grant `Bash(branch-behind-base.sh:*)` in each top-level command's `allowed-tools` (rule 10).
- Atomic-write irrelevant — helper is pure read, no on-disk writes.
- Commits at natural breakpoints: one per helper, one per fragment edit, one per smoke-test batch.
- Plan mode → approval → execution. Per CLAUDE.md "How to work on new changes."

---

## 3. Out of scope

- **Three-dot diff switchover.** Switching every `comparison_ref..HEAD` to `comparison_ref...HEAD` would match GitHub PR diff semantics but ripples through every lens, blame check, `origin-crosscheck.sh`, `prior-fix-diff.sh`, etc. Bigger change than the problem warrants and doesn't address the stale-baseline concern (the merge base is even older than current `$base_branch`). Deferred.
- **Auto-merge.** The "stop" option exits and instructs the user; the command does not run `git merge` itself. Touching the working tree on the user's behalf at preflight is too large a blast radius.
- **`:walkthrough` and `:promote` gates.** Walkthrough is interactive triage with no commit; promote is metadata-only single-finding mutation. Adding the gate is reasonable but mostly noise — defer to a follow-up if useful.
- **Schema bump.** No new artifact fields; uses existing `preflight_warnings` (review-time) and `trace.md` (fix/add-time).

---

## 4. Scope details

### 4.1 — `bin/branch-behind-base.sh`

The helper has two invocation modes — passive (caller already has a resolved `comparison_ref`, just compute) and active-fetch (caller wants the helper to fetch `origin/$base_branch` first and use the fresh remote tip). Modes are mutually exclusive.

**Inputs (flags):**

- *Passive mode* — `--comparison-ref <ref>` (required) — e.g., `main` or `origin/main`. Resolved upstream by the caller. No fetch. Used by `:review`'s 0.6a (freshness-gate at 0.2a already fetched).
- *Active-fetch mode* — `--fetch-base <name>` (required) — e.g., `main`. Helper runs `git fetch origin <base>` (with the same 30s soft timeout pattern as `freshness-gate.sh` — GNU `timeout` if available, background+watchdog fallback for macOS without it), then uses `origin/<base>` as `comparison_ref`. On `no_remote` (`git remote get-url origin` fails) or fetch failure, falls back silently to local `<base>` and surfaces `fetch_failed` / `no_remote` in the emitted `warnings` array. Used by `:fix`'s 7.6a and `:add`'s 3a.
- `--reviewed-files @-` (required in both modes, stdin form) or `--reviewed-files <newline-sep-string>` — the staleness envelope. `:review` passes `reviewed_files_all` from Phase 0.6; `:fix`/`:add` read it from the artifact via `artifact-read.sh --filter '.reviewed_files_all[]?'`.

Mutual-exclusion enforcement: passing both `--comparison-ref` and `--fetch-base` is a usage error (exit 64). Passing neither is also exit 64.

**Output (stdout):** single JSON object:

```json
{
  "behind_count": <int>,
  "overlap_count": <int>,
  "overlap_files": ["path/a.ts", "path/b.go", "…+N more"],
  "comparison_ref_used": "<ref>",
  "warnings": ["fetch_failed origin main rc=128 err=...", ...]
}
```

`comparison_ref_used` reflects what the helper actually compared against (in active-fetch mode, this is `origin/<base>` on success or `<base>` on fallback — callers log this so the trace makes the resolution explicit). `warnings` is `[]` in the happy path; in active-fetch mode it carries fetch-failure messages so the orchestrator can flush them to `trace.md` / `preflight_warnings`.

`overlap_files` is truncated to the first **10** paths (sorted) plus a `"…+N more"` sentinel when truncated (so a 25-overlap renders as 10 paths + `"…+15 more"` as element 11). The cutoff is a single constant in the helper — change in one place if it ever needs tuning. The truncation keeps the AskUserQuestion prompt body tight on long-tail overlaps; below 10, full file context is preserved (the regime where specific paths most influence the user's decision).

**Algorithm:**

1. Parse flags; enforce passive ⊕ active-fetch mutual exclusion (exit 64 with usage on both/neither).
2. **Active-fetch mode only:**
   - Confirm a working tree (`git rev-parse --show-toplevel`).
   - Detect remote: `git remote get-url origin`. On failure, set `comparison_ref_used = $BASE`, append `no_remote` to warnings, skip fetch.
   - Otherwise fetch `origin "$BASE"` with 30s soft timeout (copy `freshness-gate.sh:262-273`'s GNU-or-watchdog pattern). On non-zero exit, set `comparison_ref_used = $BASE`, append `fetch_failed origin $BASE rc=$rc err=...` to warnings.
   - On success, set `comparison_ref_used = "origin/$BASE"`.
3. **Passive mode only:** set `comparison_ref_used = $COMPARISON_REF`.
4. Validate `comparison_ref_used` resolves: `git rev-parse --verify "$comparison_ref_used^{commit}"`. On failure, exit 1 with error-as-prompt.
5. `behind_count=$(git rev-list --count "HEAD..$comparison_ref_used")`.
6. **Short-circuit on behind=0**: emit zeros + `comparison_ref_used` + `warnings`, exit 0. No diff computed.
7. Otherwise compute the file-set overlap (Bash 3.2-safe):
   ```bash
   behind_files_tmp=$(mktemp); reviewed_files_tmp=$(mktemp)
   git diff --name-only "HEAD..$comparison_ref_used" | sort -u > "$behind_files_tmp"
   printf '%s\n' "$REVIEWED_FILES" | sort -u > "$reviewed_files_tmp"
   overlap=$(comm -12 "$behind_files_tmp" "$reviewed_files_tmp")
   rm -f "$behind_files_tmp" "$reviewed_files_tmp"
   ```
8. Truncate `overlap` to the cutoff; if more, append `"…+N more"` (N = actual remainder).
9. Emit JSON via `jq`. Use `jq -Rn '[inputs | select(length>0)]'` for the array (matches `freshness-gate.sh:181`'s `lines_to_json_array` pattern).

**Side effects:** in active-fetch mode, runs one `git fetch origin <base>` (no ref update, just `FETCH_HEAD` — same as `freshness-gate.sh`'s initial fetch). No working-tree mutation. Passive mode is pure read.

**Smoke fixtures** (additive to `test/fixtures/`):

| Fixture | Setup | Expected |
|---|---|---|
| `BB-1-zero-passive` | passive mode; branch is up-to-date with `$comparison_ref` | `{behind_count: 0, ..., comparison_ref_used: "$ref", warnings: []}` |
| `BB-2-overlap-passive` | passive; branch behind by 3, both branches modified `src/foo.ts` | `behind_count: 3, overlap_count: 1, overlap_files: ["src/foo.ts"]` |
| `BB-3-no-overlap-passive` | passive; branch behind by 3, no shared files | `behind_count: 3, overlap_count: 0, overlap_files: []` |
| `BB-4-bad-ref-passive` | passive; `--comparison-ref does-not-exist` | exit 1, error-as-prompt on stderr |
| `BB-5-truncate` | passive; behind, 25 overlap files | `overlap_files` length = 11 (10 paths + `"…+15 more"`) |
| `BB-6-fetch-success` | active-fetch; remote has new commits HEAD lacks | `comparison_ref_used: "origin/main"`, `behind_count > 0`, `warnings: []` |
| `BB-7-fetch-no-remote` | active-fetch; no `origin` remote configured | `comparison_ref_used: "main"`, `warnings: ["no_remote"]`, behind/overlap computed against local |
| `BB-8-fetch-fail` | active-fetch; `origin` URL is unreachable (e.g., `file:///nonexistent`) | `comparison_ref_used: "main"`, `warnings: ["fetch_failed origin main ..."]`, behind/overlap computed against local |
| `BB-9-mutex` | both `--comparison-ref X` and `--fetch-base Y` passed | exit 64 with usage |

### 4.2 — `:review` Phase 0.6a (new step)

Insert in `fragments/00-preflight.md` between step 0.6 (`reviewed_files_all` capture) and step 0.7 (`claude_md_paths`).

`:review` uses **passive mode** — `freshness-gate.sh` at 0.2a already fetched `origin/$base_branch` and resolved `comparison_ref` (which may be `main` or `origin/main` depending on the user's earlier (a)/(b)/(c) choice). No second fetch.

```markdown
### 0.6a. Branch-behind-base check

Run:

\`\`\`bash
bb_json=$(printf '%s\n' "$reviewed_files_all" \
  | branch-behind-base.sh --comparison-ref "$comparison_ref" --reviewed-files @-)
behind_count=$(echo "$bb_json" | jq -r '.behind_count')
overlap_count=$(echo "$bb_json" | jq -r '.overlap_count')
overlap_files_csv=$(echo "$bb_json" | jq -r '.overlap_files | join(", ")')
\`\`\`

If `behind_count == 0`, skip the rest of this step.

If `behind_count > 0`, append a buffered warning for trace flush at 0.15:

\`\`\`bash
preflight_warnings+=("branch_behind_base behind=$behind_count overlap=$overlap_count")
\`\`\`

Then `AskUserQuestion` with three options. Build the prompt body based on overlap:

- **`overlap_count > 0`:**
  > Branch `$head_branch` is `$behind_count` commits behind `$comparison_ref`, of which `$overlap_count` modified files in this PR (`$overlap_files_csv`). The lens diff will include phantom deletions for code that landed on `$base_branch` after this branch was cut. Recommend merging `$base_branch` first.
- **`overlap_count == 0`:**
  > Branch `$head_branch` is `$behind_count` commits behind `$comparison_ref`. None of those commits modified files in this PR — the lens diff is unaffected. Latent risk: `$base_branch` may have shifted code your branch calls into (renames, API changes, dep bumps) that the lenses cannot detect from the diff alone. Merging `$base_branch` first is conservative; proceeding is fine for short divergences.

Options:

- **(a) Stop — I'll merge `$base_branch` first** (recommended). Exit 0 with: `Stopping. Run \`git merge $base_branch\` (or fast-forward) on \`$head_branch\`, then re-run /adamsreview:review.` No `review_dir` exists yet — nothing to clean up.
- **(b) Proceed.** Append a second warning: `preflight_warnings+=("branch_behind_base proceeded")`. Continue to step 0.7.
- **(c) Abort.** Exit 0 with `Aborted.`.
```

Update step 0.15's table of captures to include `behind_count`, `overlap_count` (informational; not seeded into artifact). Update the "Working set now established" table at the foot of the fragment to mention them under step 0.6a.

### 4.3 — `:fix` Phase 7.6a (new step)

Insert in `fragments/08-fix-loader.md` between 7.6 and 7.7. **Active-fetch mode** — at fix-time we want freshest signal (`$base_branch` may have moved since `:review`), so the helper fetches `origin/$base_branch` and compares against the fresh remote tip. The artifact's `base_context.comparison_ref` snapshot is *not* used here (it reflects a review-time decision; at fix-time we always want fresh remote, falling back to local on no-remote / fetch-failure).

```bash
base_branch=$(artifact-read.sh --filter '.base_branch' --path "$artifact_path")
reviewed_files_all=$(artifact-read.sh --filter '.reviewed_files_all[]?' --path "$artifact_path")

bb_json=$(printf '%s\n' "$reviewed_files_all" \
  | branch-behind-base.sh --fetch-base "$base_branch" --reviewed-files @-)
behind_count=$(echo "$bb_json" | jq -r '.behind_count')
overlap_count=$(echo "$bb_json" | jq -r '.overlap_count')
overlap_files_csv=$(echo "$bb_json" | jq -r '.overlap_files | join(", ")')
comparison_ref_used=$(echo "$bb_json" | jq -r '.comparison_ref_used')

# Flush any fetch warnings from active-fetch mode to trace.md.
while IFS= read -r w; do
    [[ -n "$w" ]] && printf '[%s] branch_behind_base %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$w" >> "$trace_log_path"
done < <(echo "$bb_json" | jq -r '.warnings[]?')
```

Always log the resolution to `trace.md` (independent of behind-count) so the trace makes the fetch path explicit:

```bash
printf '[%s] branch_behind_base behind=%s overlap=%s comparison_ref_used=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$behind_count" "$overlap_count" \
    "$comparison_ref_used" >> "$trace_log_path"
```

Same prompt and option set as `:review` 0.6a. Differences:

- Use the `:fix`-tailored exit message on (a): `Stopping. Run \`git merge $base_branch\` on \`$head_branch\`, then re-run /adamsreview:fix.`
- Exit happens **before** 7.8 (run_id generation) — no run_id, no input_sha, no `fix_attempts` row, no commit, no push.
- The prompt text references `$comparison_ref_used` (so a fetch-failure fallback is visible — "behind by N commits vs `main` (fetch failed; comparing against local)" — rather than misleadingly claiming we checked the remote).

### 4.4 — `:add` step 3a (new step)

Insert in `commands/add.md` between step 3 (leftover-attempted abort) and step 4 (build candidate array). Same shape as `:fix` 7.6a — **active-fetch mode** for freshest signal:

- Reads `base_branch` and `reviewed_files_all` from the artifact (not `base_context.comparison_ref`).
- Calls `branch-behind-base.sh --fetch-base "$base_branch" --reviewed-files @-`.
- Flushes `warnings[]` and the resolution line to `trace.md` (same pattern as `:fix` 7.6a).
- (a) exit message: `Stopping. Run \`git merge $base_branch\` on \`$head_branch\`, then re-run /adamsreview:add.`
- (a)/(c) exit before any candidate normalization, no `--add-finding` invocations, artifact untouched.
- Prompt text references `$comparison_ref_used` so fetch-failure fallback is visible.

### 4.5 — Smoke tests

Additive to `test/smoke.sh`. Naming convention: `BB-<n>-<short-name>`. Helper-level assertions match the fixture table in §4.1; orchestrator-flow assertions verify the wiring:

| Assertion | Verifies |
|---|---|
| `BB-1-zero-passive` | helper passive: behind=0 emits zeros without computing diff |
| `BB-2-overlap-passive` | helper passive: overlap detected correctly |
| `BB-3-no-overlap-passive` | helper passive: `overlap_count: 0, overlap_files: []` |
| `BB-4-bad-ref-passive` | helper passive: exit 1 with error-as-prompt on unresolvable ref |
| `BB-5-truncate` | helper truncates `overlap_files` to 11 (10 paths + `"…+15 more"`) on a 25-overlap fixture |
| `BB-6-fetch-success` | helper active-fetch: `comparison_ref_used: "origin/<base>"`, `warnings: []` |
| `BB-7-fetch-no-remote` | helper active-fetch: falls back to local `<base>`, `warnings: ["no_remote"]` |
| `BB-8-fetch-fail` | helper active-fetch: falls back to local `<base>`, `warnings` carries `fetch_failed ...` line |
| `BB-9-mutex` | helper rejects both / neither of `--comparison-ref` and `--fetch-base` (exit 64) |
| `BB-10-review-warning` | `:review` with behind>0 writes `branch_behind_base behind=...` to `preflight_warnings` array (verify via trace.md after a simulated (b) choice) |
| `BB-11-fix-warning` | `:fix` with behind>0 logs `branch_behind_base behind=... comparison_ref_used=...` to `trace.md` (simulated (b)) |
| `BB-12-add-warning` | `:add` with behind>0 logs `branch_behind_base behind=... comparison_ref_used=...` to `trace.md` (simulated (b)) |

The interactive `AskUserQuestion` itself is not smoke-tested — fixtures simulate the post-choice state. The actual prompt is verified visually during real-PR validation.

---

## 5. Open questions — all resolved (2026-04-26)

1. **Re-fetch at fix/add time** — *resolved: re-fetch.* Helper grows an active-fetch mode (`--fetch-base <name>`) that runs `git fetch origin <base>` with the same 30s soft timeout pattern as `freshness-gate.sh`, falls back to local `<base>` on `no_remote` / fetch failure, and reports the resolution via `comparison_ref_used` + `warnings[]`. `:fix` and `:add` use active-fetch; `:review` stays passive (freshness-gate already fetched at 0.2a). Trade-off accepted: ~30s worst-case fetch latency at fix/add time vs the v1-snapshot risk of missing post-review base drift. The fallback path means flaky/offline networks degrade gracefully without gating fix/add.
2. **`:walkthrough` and `:promote` gates** — *resolved: do not add.* Out of scope. Both are non-committing operations (interactive triage / metadata mutation); the staleness concern doesn't apply. If a user wants to know `$base_branch` has moved before walking findings, they can re-run `:review` first.
3. **Truncation cutoff for `overlap_files`** — *resolved: 10.* Below 10, full file context is preserved — the regime where specific paths most influence the user's "merge first vs proceed" decision. At 10+ overlaps, the user is deciding on count alone anyway and specific paths become noise. Sentinel reads `"…+N more"` where N is the actual remainder (so a 25-overlap renders as 10 paths + `"…+15 more"` as element 11).
4. **Helper name** — *resolved: `branch-behind-base.sh`*. Symmetric with `freshness-gate.sh` (the "base" qualifier is what the user-facing prompt also uses).

---

## 6. Execution order (once approved)

1. Land `bin/branch-behind-base.sh` (both modes — passive + active-fetch with the GNU-or-watchdog timeout shared with `freshness-gate.sh`) + smoke fixtures `BB-1` through `BB-9` (helper-level: passive happy/bad-ref/no-overlap/truncate, active-fetch success/no-remote/fetch-fail, mode-mutex) — one commit.
2. Wire `:review` 0.6a in `fragments/00-preflight.md` (passive mode) + add `Bash(branch-behind-base.sh:*)` to `commands/review.md` allowed-tools + smoke `BB-10` — one commit.
3. Wire `:fix` 7.6a in `fragments/08-fix-loader.md` (active-fetch mode) + grant in `commands/fix.md` + smoke `BB-11` — one commit.
4. Wire `:add` 3a in `commands/add.md` (active-fetch mode) + grant + smoke `BB-12` — one commit.
5. CLAUDE.md updates (Helper index entry + Pipeline-shape diagram one-liner mentioning the gate at Phase 0 / Phase 7 / `:add` preflight) — one commit.

Five commits. No `MEMORY.md` / archive touches. Schema unchanged.
