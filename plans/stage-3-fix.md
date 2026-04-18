# Stage 3 — `/adams-review-fix` (Phases 7–9)

**Status:** drafted 2026-04-18, plan-and-execute (no separate approval round-trip).
**Preceded by:** Stage 2.7 (detection parallelization — done).
**Followed by:** Stage 4 (fragment shrink — not started).
**Pattern:** mirrors Stage 2's scaffolding (thin top-level + fragments + helpers + renderer + smoke) but for the fix half of the two-command system.

---

## Context

`/adams-review` is complete end-to-end (Stage 2) and hardened through three pre-Stage-3 passes (2.5 context-budget + sensitive-file gate; 2.6 base-branch freshness + origin cross-check; 2.7 detection parallelization). The artifact it produces is schema-valid, rendered, and (in PR mode) posted. Every surface that feeds `/adams-review-fix` — `findings[].disposition`, `fix_proposal`, `verification_context`, `cross_cutting_groups`, `base_context`, `comment_id` — already lands correctly.

What's still missing is the other half: the command that reads that artifact, dispatches fix-group agents, post-fix-reviews the working tree, commits the survivors, reverts the regressions, and keeps the artifact honest through every failure path.

DESIGN.md specifies this at rev 8: §4 Phases 7–9, §5.3 transitions, §13.1 Phase-9 decision rows, §13.6 commit strategy, §19.8 fix-group agent prompt, §19.9 post-fix reviewer prompt, §21.5 `group-fixes.py`, §24 error recovery, §25.2 working set, §26 worked mixed-outcome example. The spec is settled; Stage 3 executes it.

**Outcome this stage delivers.** `/adams-review-fix [threshold] [--granular-commits]` can be invoked against an artifact produced by `/adams-review`. It either commits a coherent set of fix-group edits (with per-group Phase-9 truth in the message) or leaves the working tree exactly as it found it (overlap-abort, all-regression, revert-failure). The artifact always tracks git reality, the commit, and the state of each touched finding. The next run can always tell what happened — no leftover ambiguity.

---

## 1. Goal

Build a working `/adams-review-fix` end-to-end, mirroring the Stage 2 surface for the review side.

**Done when:**

1. `/adams-review-fix` runs on an artifact with ≥1 `confirmed_auto` finding at `score_phase4 >= threshold`, dispatches fix groups, commits survivors, updates artifact state, and publishes the updated report.
2. Leftover-`attempted` findings from an interrupted prior run trigger the hard abort with the deterministic recovery message (§4 Phase 7 step 4).
3. Phase-9.pre overlap guard short-circuits when fix agents touched overlapping files across groups; the no-commit branch records the state correctly; re-running triggers the leftover-`attempted` hard abort.
4. Per-group revert runs when Phase 9 classifies a regression; the reverted files do not appear in the commit; `fix_attempts.output_sha` for regression-group findings is `null`; surviving groups still commit.
5. All-regression degenerate case reverts everything, makes no commit, records the state, and surfaces the degenerate-case error.
6. Phase 9e terminal cleanup holds the §24.4 invariant under push failure and publish failure — the artifact is persisted before any network call.
7. `artifact-render.py` surfaces a `## Fix runs` section that summarizes each run's outcome with commit SHA linkage; the Auto-fixable table gains a Status column when any finding has `fix_attempts`.
8. `test/smoke.sh` gains the new helper-level assertions (group-fixes, apply-fix-start, apply-fix-outcomes, render fix_runs); existing assertions unchanged.
9. DESIGN.md §21.2 gains the two new `artifact-patch.py` modes; BUILD.md stage index + Stage 3 section filled in.

**Explicitly out of scope** for Stage 3:

- Light-lane auto-fix (`--include-light-fixes` flag). Stays deferred per §13.2.
- `--cleanup-pre-existing` flag. Not on the Stage 3 punch list.
- `--resume-interrupted` automated cleanup (future v2).
- Commit-signing, GPG, or any identity config beyond `git commit` defaults.
- Deep prompt tuning for Phase 8/9 sub-agents beyond what DESIGN §19.8/§19.9 already specifies. Real-repo runs will surface tuning needs.
- Fragment prose shrink (Stage 4 scope).
- Real-repo end-to-end validation. Same deferral pattern as Stage 2.6/2.7 — the token cost of a real fix run against a multi-finding artifact is high, and fragment-level correctness is covered by unit smoke. Budget the ray-finance re-run separately after Stage 3 closes.

---

## 2. Ground rules (restated)

- **Bash:** `#!/usr/bin/env bash` + `set -euo pipefail`. Bash 3.2-safe (no `declare -A`, `mapfile`, `readarray`, `${var,,}`).
- **Python:** `#!/usr/bin/env -S uv run --script` + PEP 723 inline deps (`jsonschema`). Exit codes per `_common.py` (0 ok / 1 validation / 2 invalid-transition / 3 dry-run-invalid / 4 unexpected / 5 missing-dep / 64 usage).
- **Error-as-prompt:** ERROR → context → Valid values → Did you mean → Action.
- **Commits:** one per sub-item, imperative mood, DESIGN §-refs, `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer. Directly to `main`, no feature branches.
- **Clarification vs behavioral change:** Stage 3 implements an already-specified design. Any in-flight DESIGN discrepancy that's clarification-level gets updated inline + recorded in Cross-stage notes; any behavioral change stops and asks.
- **Authoring disciplines from Stage 2.5.C:**
  1. Read for decisions, not for holding — narrow `jq` filters that return a verdict, not full records into orchestrator context.
  2. Delegate large-context synthesis to sub-agents that return structured summaries.
  3. Avoid per-finding loops in fragments when a single helper call can carry the same semantics. Stage 3 adds two batched helpers (`--apply-fix-start`, `--apply-fix-outcomes`) so Phase 8 start and Phase 9d state transitions are single calls, not loops.

---

## 3. Scope — work items

Nine sub-items (3.A through 3.I), rough dependency order. 3.A–3.B are foundation (helpers); 3.C is the scaffold; 3.D–3.F are the fragments (staged so each commits independently); 3.G is the renderer update; 3.H is smoke; 3.I is close-out.

### 3.A — `group-fixes.py` helper (§21.5)

New Python helper at `commands/_shared/tools/group-fixes.py`. Implements the DESIGN §21.5 union-find algorithm.

**Interface:** `group-fixes.py --artifact <path> --eligible-finding-ids <csv|@-> [--output-json]`

- `--eligible-finding-ids`: comma-separated list, or `@-` to read from stdin (one id per line). The orchestrator is responsible for filtering (`current_state=="open" AND disposition ∈ {confirmed_auto,partial,regression} AND score_phase4 >= threshold`); this script does not re-derive eligibility.
- `--output-json`: default; emits JSON array. Kept as a flag for future forward-compat with `--output-tsv` etc.

**Output:** JSON array to stdout:
```json
[
  {"id": "FG-1", "finding_ids": ["F001", "F003"], "files_planned": ["src/auth/session.ts", "src/auth/guest.ts", "src/routes/_error.tsx"]},
  {"id": "FG-2", "finding_ids": ["F002"], "files_planned": ["src/cache/sync.ts"]}
]
```

**Algorithm** (per §21.5):

1. Read + validate artifact via `_common.validate()`.
2. Build id → finding index for every eligible id. Reject any id not found, or any found id that violates the eligibility contract (current_state != "open" or disposition not in the allowed set). Error-as-prompt lists the offenders and their actual state.
3. For each finding, extract `files_planned = validation_result.fix_proposal.files_to_modify[].file`. An eligible finding with no `validation_result.fix_proposal` is invalid input (error-as-prompt surfaces it).
4. Initialize parent map: each eligible id its own parent.
5. For each `cross_cutting_group` in the artifact: if any of its `finding_ids` intersect the eligible set, union all eligible members of that group.
6. For each pair of eligible findings: if their `files_planned` sets intersect, union them.
7. Compact to components; assign `FG-1`, `FG-2`, … in order of the minimum finding id per component (deterministic).
8. Emit the sorted array.

**Invariants:**
- Pathological case (everything shares a file) collapses to one group.
- Disjoint-file singletons stay singletons.
- IDs are monotonic within the run (`FG-1` through `FG-N`).
- Output is deterministic: same artifact + same eligible list → same groups, same ids, same file order (sorted alphabetically within each group).

**Error cases:**
- Missing `--artifact` or unreadable path: EXIT_USAGE (64).
- Unknown finding id in eligible list: EXIT_VALIDATION (1) with error-as-prompt listing valid ids.
- Eligible finding has `current_state != "open"` or invalid disposition: EXIT_VALIDATION (1) with diagnosis.
- Eligible finding missing `validation_result.fix_proposal`: EXIT_VALIDATION (1).
- Malformed artifact (schema failure): EXIT_VALIDATION (1).

**Smoke assertions** (FX-GF-1 … FX-GF-7 suggested naming):
- GF-1: single eligible finding with one planned file → single FG-1 group.
- GF-2: two eligible findings in same `cross_cutting_groups` entry → merged into one FG.
- GF-3: two eligible findings sharing one planned file (no cross-cutting group) → merged.
- GF-4: three eligible findings, A shares file with B, B shares a different file with C → all three in one FG (transitive closure).
- GF-5: two eligible findings with disjoint file sets and no cross-cutting link → two FGs.
- GF-6: empty eligible list → `[]` on stdout.
- GF-7: unknown eligible id → EXIT_VALIDATION with error-as-prompt.

One commit.

### 3.B — `artifact-patch.py` batched fix modes

Extend `commands/_shared/tools/artifact-patch.py` with two new modes. Mirrors Stage 2.5.B's `--apply-decisions` pattern (per-tuple atomic writes, first-failure halt, one summary line emission, `_common.py` exit codes).

#### `--apply-fix-start <array>`

**Input shape** (one tuple per finding entering Phase 8):
```json
{"id": "F001", "run_id": "fixrun_01JX..."}
```

`run_id` field is informational — captured in trace but not persisted on findings at this stage (Phase 9d writes the `fix_attempt` entry later). Schema pattern `^fixrun_[A-Za-z0-9]+$` (matches `fix_attempts[].run_id` regex).

**Behavior:** for each tuple, transition `current_state: open → attempted`. No other fields change. Disposition stays at whatever it was (`confirmed_auto`, `partial`, `regression`). `is_actionable` unchanged.

**Error cases:** tuple with unknown id, tuple with `current_state != "open"`, malformed JSON — all error-as-prompt with EXIT codes per the §21.2 table. Per-tuple atomic writes; first failure halts.

**Why separate from `--apply-decisions`:** semantically distinct — this is a transient-state marker at the start of a fix run, not a post-validation disposition derivation. Sharing a helper would overload semantics. Mirroring `--apply-decisions` keeps the pattern consistent.

#### `--apply-fix-outcomes <array>`

**Input shape** (one tuple per finding touched this run, emitted at Phase 9d):
```json
{
  "id": "F001",
  "run_id": "fixrun_01JX...",
  "fix_group_id": "FG-1",
  "input_sha": "a3f8d7c9",
  "output_sha": "c01ab2ef",
  "phase_9_outcome": "verified",
  "timestamp": "2026-04-18T20:15:03Z"
}
```

Optional fields:
- `phase_9_finding`: string, present when `phase_9_outcome ∈ {partial, regression}`.
- `revised_fix_proposal`: `fix_proposal` object, present when `phase_9_outcome ∈ {partial, regression}`.

**Behavior** (per tuple, derived from `phase_9_outcome`):

| `phase_9_outcome` | current_state transition | disposition set | `reason` set | fix_attempt appended |
|---|---|---|---|---|
| `verified` | attempted → resolved | `resolved` | null | yes |
| `partial` | attempted → open | `partial` | `"fix partial: <phase_9_finding>"` | yes |
| `regression` | attempted → open | `regression` | `"fix regressed: <phase_9_finding>"` | yes (`output_sha: null`) |
| `null` (overlap-abort) | no transition (stays `attempted`) | unchanged | unchanged | yes (`output_sha: null`, `phase_9_outcome: null`, `phase_9_finding: "run aborted: ..."`) |

For `regression` tuples: enforce `output_sha == null` (the fix group was reverted; no commit for this finding). Writer rejects `regression` with non-null output_sha.

For `null` outcome (overlap-abort): `phase_9_finding` MUST be present (diagnostic text). Schema allows `phase_9_finding` on fix_attempts unconditionally, so no schema change needed.

**Derivation rules** (enforced by helper — authority lives in code, not in fragments, mirroring Stage 2.5.B §21.2 clarification):
- `is_actionable` derived from new `disposition` per §5.2.1.
- `current_state=resolved ⇔ disposition=resolved` coupling enforced (§21.2).
- Transition validation through `_common.transitions_from()` — attempted's allowed nexts are `{open, resolved}`.

**Exit codes:** reuse the §21.2 table (0 ok / 1 validation / 2 invalid-transition / 3 not applicable / 4 unexpected / 5 missing-dep / 64 usage).

**Per-tuple atomic writes, first-failure halts** — identical pattern to `--apply-decisions`. Caller re-invokes with the remainder after fixing the bad tuple. Batch failure mid-way keeps preceding tuples committed.

**`--dry-run`:** not supported (same rationale as `--apply-decisions`).

**Smoke assertions** (FX-AF-1 … FX-AF-8):
- AF-1: `--apply-fix-start` mixed 3-tuple batch all `current_state=open`; all transitioned to `attempted`.
- AF-2: `--apply-fix-start` with one tuple at `current_state=resolved` halts mid-batch with EXIT_INVALID_TRANSITION; preceding tuples already applied.
- AF-3: `--apply-fix-outcomes` verified tuple → current_state=resolved, disposition=resolved, is_actionable=false, reason=null, fix_attempt appended with output_sha.
- AF-4: `--apply-fix-outcomes` partial tuple → current_state=open, disposition=partial, is_actionable=true, reason="fix partial: ..." with phase_9_finding text.
- AF-5: `--apply-fix-outcomes` regression tuple with output_sha=null → current_state=open, disposition=regression, is_actionable=true.
- AF-6: `--apply-fix-outcomes` overlap-abort tuple (phase_9_outcome=null) → current_state stays attempted, fix_attempt appended with output_sha=null and phase_9_outcome=null and phase_9_finding="run aborted: ...".
- AF-7: `--apply-fix-outcomes` regression tuple with non-null output_sha → rejected with error-as-prompt.
- AF-8: `--apply-fix-outcomes` all-regression 3-tuple batch → all three transition to open/regression, output_sha=null on each fix_attempt.

DESIGN §21.2 gains two clarification paragraphs documenting the modes. BUILD.md cross-stage note records the batched-helper discipline being applied for the second time (first was `--apply-decisions`).

One commit.

### 3.C — `commands/adams-review-fix.md` top-level scaffold

Mirror `commands/adams-review.md` structure. Thin top-level: frontmatter + prelude + preprocessor includes + trailer.

**Frontmatter:**
```yaml
---
allowed-tools: <full grant block — see below>
argument-hint: "[threshold] [--granular-commits]"
description: Apply auto-fixable code review findings. Dispatches fix-group agents, post-fix-reviews the working tree, commits survivors, reverts regressions, updates the artifact.
disable-model-invocation: false
---
```

**`allowed-tools` grant block** (absolute paths, per §8.7):
- All existing helper-script grants carried over from `adams-review.md` (`artifact-read.sh`, `artifact-patch.py`, `artifact-validate.sh`, `artifact-render.py`, `artifact-publish.sh`, `claude-md-paths.sh`, `staleness.sh`, `external-scrape.sh`, `log-phase.sh`, `log-tokens.sh`, `origin-crosscheck.sh`, `assign-finding-ids.sh`).
- New: `Bash(/Users/adammiller/.claude/commands/_shared/tools/group-fixes.py:*)`.
- Same Bash utilities (`git`, `gh`, `jq`, `date`, `mkdir`, `mv`, `rm`, `cat`, `printf`, `echo`, `grep`, `awk`, `sed`, `tr`, `wc`, `head`, `tail`, `cut`, `sort`, `diff`, `openssl`, `python3`, `node`, `find`, `uv`).
- `AskUserQuestion`, `Agent`, `Read`, `BashOutput`, `KillShell` — same as `adams-review.md`.
- **New for fix:** `Edit`, `Write`. The fix-group sub-agents need these. The orchestrator itself never edits files directly.

**Prelude sections** (mirror `adams-review.md`):
- One-paragraph summary.
- "Execution overview — read this first" with a TaskList directive (one task per Phase 7/8/9 plus args parsing) and key reminders: state carries across phases, sub-agents never mutate artifact directly, artifact-records-commit-before-network invariant (§24.4).
- "Sub-agent dispatch pattern" — same as `adams-review.md` (token logging after every return, one-retry-on-parse-fail, drop-with-note on second fail).
- "Effort is session-wide" (§10.1) — same as `adams-review.md`.
- "Working-set variables (§25.2 summary)" — condensed version of §25.2 table:
  - All of §25.1 (loaded from artifact in Phase 7).
  - `run_id`, `threshold`, `latest_known_sha`, `stash_taken`, `input_sha`, `eligible_finding_ids`, `fix_groups`, `phase_9a_outcomes`, `overlap_files`, `reverted_groups`, `surviving_groups`, `commit_sha`.
- "Argument handling" — parse `$ARGUMENTS`:
  - First positional → `threshold` (default 60).
  - `--granular-commits` → `granular_commits=true` (else false).
  - Any other token → stop + ask.

**Preprocessor includes:**
```
---
!`cat ~/.claude/commands/_shared/08-fix-loader.md`
---
!`cat ~/.claude/commands/_shared/09-fix-execution.md`
---
!`cat ~/.claude/commands/_shared/10-post-fix-and-commit.md`
---
```

**Trailer — "What this command does NOT do":**
- No new review (that's `/adams-review`).
- No delete or rename of files in fix edits (§19.8 prohibition).
- No git operations inside fix-group sub-agents — orchestrator handles staging, commits, push.
- No auto-recovery from leftover-`attempted` state (user intervention required).
- No light-lane auto-fix (deferred).

One commit. Kept minimal — the frontmatter + prelude should be roughly the same length as `adams-review.md`'s.

### 3.D — `08-fix-loader.md` fragment (Phase 7)

New file `commands/_shared/08-fix-loader.md`. Covers DESIGN §4 Phase 7 step-for-step.

**Step 7.1 — Argument resolution.**
- Parse `$ARGUMENTS` for threshold (first positional, integer, default 60; reject non-integer) and `--granular-commits` (optional bool).
- Capture into working context.

**Step 7.2 — Locate artifact + resolve paths.**
```bash
reviews_root="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_slug=...  # same derivation as Phase 0 step 0.3
latest_path="$reviews_root/$repo_slug/$head_branch/latest.txt"
```

If `latest.txt` is missing or empty → abort: "no review found for this branch. Run `/adams-review` first." (§24.3)

Read `review_id` from `latest.txt`, build `review_dir`, `artifact_path`. Capture all.

**Step 7.3 — Schema validate.**
```bash
artifact-validate.sh --path "$artifact_path"
```
On non-zero: dump to `/tmp/adams-review-invalid-<ts>.json`; abort with schema error. (§24.3)

**Step 7.4 — Leftover-`attempted` hard abort.**
```bash
leftover=$(artifact-read.sh --path "$artifact_path" --filter \
    '[.findings[] | select(.current_state == "attempted") | .id] | join(",")')
if [[ -n "$leftover" ]]; then
    # Print the deterministic recovery message from §4 Phase 7 step 4,
    # list the leftover ids, exit non-zero.
fi
```
Block verbatim from §4 Phase 7 step 4, with `<list>` substituted by `$leftover`.

**Step 7.5 — Clean-tree gate.**
```bash
dirty=$(git status --porcelain)
if [[ -n "$dirty" ]]; then
    # AskUserQuestion: stash | abort
    # Categorize files as Modified / Staged / Untracked — filenames only, not diff
fi
```
On stash: `git stash push --include-untracked -m "pre-adams-review-fix-stash"`; capture `stash_taken=true`. On stash failure: abort per §24.2. On abort: exit 0.
On clean tree: `stash_taken=false`.

**Step 7.6 — File-overlap staleness check.**
```bash
latest_known_sha=$(artifact-read.sh --path "$artifact_path" --filter \
    '[.findings[].fix_attempts[]? | select(.output_sha != null) | .output_sha] | last // (.reviewed_sha // empty)')
# Fallback: if jq found no prior output_sha, use artifact.reviewed_sha
```
Actually the jq above is broken — cleaner:
```bash
latest_known_sha=$(jq -r '
    ( [.findings[].fix_attempts[]?.output_sha | select(. != null)] | last )
    // .reviewed_sha
' "$artifact_path")
```
Capture as `latest_known_sha`. Then:
```bash
HEAD_SHA=$(git rev-parse HEAD)
if [[ "$HEAD_SHA" != "$latest_known_sha" ]]; then
    reviewed_files=$(artifact-read.sh --path "$artifact_path" --filter '.reviewed_files_all | join(",")')
    staleness.sh --reviewed-sha "$latest_known_sha" --reviewed-files "$reviewed_files" \
        || abort  # staleness.sh exits non-zero on 'unsafe'; stdout classifies
fi
```
On `unsafe`: abort with message ("reviewed files changed since review; re-run /adams-review"). On `warn`: proceed with a trace note. On `safe`: proceed silently.

**Step 7.7 — PR eligibility recheck.**
```bash
mode=$(jq -r '.mode' "$artifact_path")
pr_number=$(jq -r '.pr_number // empty' "$artifact_path")
if [[ "$mode" == "pr" && -n "$pr_number" ]]; then
    pr_state=$(gh pr view "$pr_number" --json state,isDraft -q '.state')
    case "$pr_state" in
        CLOSED|MERGED) abort ;;
    esac
fi
```
If PR closed/merged: abort ("PR #N is <state>; fixes not applied").

**Step 7.8 — Generate `run_id` and capture `input_sha`.**
```bash
if ulid=$(uv run --with ulid-py python3 -c 'import ulid; print(ulid.new())' 2>/dev/null); then
    run_id="fixrun_${ulid}"
else
    run_id="fixrun_$(date -u +%Y%m%dT%H%M%SZ)$(openssl rand -hex 3)"
fi
input_sha=$(git rev-parse HEAD)
```
The `fixrun_` prefix matches the schema regex `^fixrun_[A-Za-z0-9]+$`. Capture both.

**Step 7.9 — Working-set delta.** Brief recap of what's in context by end of Phase 7: all of `§25.1` loaded from artifact, plus `threshold`, `granular_commits`, `run_id`, `input_sha`, `latest_known_sha`, `stash_taken`, `review_dir`, `artifact_path`, all log paths. Phase 8 and 9 reference by name.

**Trace log path:** `$review_dir/trace.md` is loaded from artifact dir. The existing fragment convention is that `trace.md` is append-only — Phase 7 appends a phase-7 header and each step's outcome; Phase 8 / 9 continue.

One commit.

### 3.E — `09-fix-execution.md` fragment (Phase 8)

New file `commands/_shared/09-fix-execution.md`. Covers DESIGN §4 Phase 8.

**Step 8.1 — Compute eligible_finding_ids.**
```bash
eligible_finding_ids=$(jq -r --argjson thr "$threshold" '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
     | select(.impact_type == "correctness" or .impact_type == "security")
     | select(.score_phase4 != null and .score_phase4 >= $thr)
     | .id
    ] | join(",")
' "$artifact_path")
```

Per §4 Phase 8 filter. Note the `impact_type ∈ {correctness, security}` clause — deep lane only, per §13.2. Capture as `eligible_finding_ids` (CSV string).

**Step 8.2 — Empty-eligibility short-circuit.**
```bash
if [[ -z "$eligible_finding_ids" ]]; then
    # Trace note, render the (unchanged) artifact, mirror to chat, exit 0
    # without transitioning any state, without running Phase 9.
fi
```
User-visible message: "No fix-eligible findings at threshold=N. Nothing to do." Terminal cleanup runs in its trivially-no-op branch (no stash pop needed if `stash_taken=false`; pop if true).

**Step 8.3 — `group-fixes.py` dispatch.**
```bash
fix_groups=$(group-fixes.py --artifact "$artifact_path" --eligible-finding-ids "$eligible_finding_ids")
```
Parse stdout into orchestrator context. On non-zero exit: error-as-prompt handling per §8.6 (retry once). Capture as `fix_groups` (JSON array).

**Step 8.4 — Bulk open→attempted transition.**
```bash
# Build apply-fix-start tuple array
start_tuples=$(jq -nc --arg run_id "$run_id" --arg ids "$eligible_finding_ids" '
    ($ids | split(",")) | map({id: ., run_id: $run_id})
')
echo "$start_tuples" | artifact-patch.py --path "$artifact_path" --apply-fix-start @-
```
One call, not a loop. Every eligible finding enters `current_state=attempted`.

**Step 8.5 — Parallel fix-group agent dispatch (one turn).**

For each group in `fix_groups`, dispatch an Opus `Agent` with the §19.8 prompt. **All dispatches in one orchestrator turn** so the groups run concurrently.

Each agent prompt body contains:
- `run_id`, `fix_group_id`, threshold (informational).
- Full findings array for the group — each finding's `validation_result` (evidence, blast_radius, fix_proposal, verification_context).
- Any cross-cutting annotation (`cross_cutting_groups` entries touching this group's ids).
- `claude_md_paths` from the artifact.
- Prior `fix_attempts[-1]` for findings with `disposition ∈ {partial, regression}` — so retry runs have prior context.
- Files in the group: `jq -r '.findings[] | select(.id=="<ID>") | .validation_result.fix_proposal.files_to_modify[].file' | sort -u`.
- Verbatim §19.8 prompt essence, including the delete/rename prohibition.
- **Output schema:** verbatim §19.8 output JSON (per_finding, files_modified, files_created, per_file_summary).

Dispatch with `subagent_type: general-purpose`, `model: opus`.

**Step 8.6 — Result collection + token logging.**

After every agent returns (before branching on content):
1. Extract tokens via structured usage or `<usage>total_tokens: N</usage>`.
2. Log via `log-tokens.sh --phase phase_8 --agent-role fix_group_<FG-N> --agent-id <id> --model opus --tokens <N>`.
3. Parse structured output; light repair on fence stripping; one retry with prompt addendum on parse fail.
4. Store result into `fix_groups[FG-N].results` in orchestrator context: `{per_finding, files_modified, files_created, per_file_summary}`.

On full parse failure after retry: record the group's findings with a placeholder result (`files_modified=[]`, `files_created=[]`, `per_finding=[]`) — they'll drop through Phase 9 as unresolved. Log to `trace.md` with a clear orchestrator-error prefix.

**Step 8.7 — Phase 8 trace + phases.jsonl.**
```bash
log-phase.sh --review-dir "$review_dir" --phase 8 --name fix-execution --elapsed <sec> \
    --summary "dispatched N fix groups over M findings"
log-phase.sh --review-dir "$review_dir" --phase 8 --record '{...}'
```
phases.jsonl record: `{name, elapsed_sec, fix_group_count, eligible_finding_count, run_id}`.

**Working-set delta.** `fix_groups` array is fully populated (each group has `id`, `finding_ids`, `files_planned`, `results.{per_finding, files_modified, files_created, per_file_summary}`). Every eligible finding is `current_state=attempted` on disk.

One commit.

### 3.F — `10-post-fix-and-commit.md` fragment (Phase 9)

New file `commands/_shared/10-post-fix-and-commit.md`. The biggest fragment — covers §4 Phase 9.pre / 9a / 9b / 9c / 9d / 9e.

**Step 9.pre — Touched-file overlap guard.**
```bash
# Compute actual_touched per group
for group in fix_groups:
    group.actual_touched = union(group.results.files_modified, group.results.files_created)

# Detect overlap
overlap_files=$(compute files appearing in ≥ 2 groups' actual_touched)
```
If `overlap_files` non-empty:
1. Log to trace.md: `OVERLAP_DETECTED` tag + file list + owning groups.
2. **Skip 9a / 9b / 9c.**
3. Build `--apply-fix-outcomes` tuple array: for each attempted finding (every eligible finding touched this run), tuple with `phase_9_outcome: null`, `output_sha: null`, `phase_9_finding: "run aborted: fix agents touched overlapping files across groups — <files>"`. `current_state` stays `attempted` (helper preserves it on null outcome).
4. Call `artifact-patch.py --apply-fix-outcomes @-`.
5. Jump to step 9e no-commit branch.
6. Surface user-visible error: overlapping files, owning groups, recommended next step (inspect tree; `git restore .` + `git clean -fd` to discard; reset `current_state` with `artifact-patch.py`; re-run).

If `overlap_files` empty: proceed to 9a.

**Step 9a — Post-fix review (one Opus sub-agent).**

Build the §19.9 prompt:
- Attempted findings (those touched this run), each with full `validation_result`.
- `fix_groups[*].results` structured results.
- `git diff HEAD` pre-embedded (captured via Bash before dispatch).
- §19.9 verbatim prompt essence.

Dispatch one `Agent`, `model: opus`. After return: token log, parse, retry-once.

Parsed output: array of `{finding_id, outcome: verified|partial|regression, phase_9_finding?, revised_fix_proposal?}`. Store as `phase_9a_outcomes`.

**Step 9b — Per-group aggregation + revert of regression groups.**

For each group in `fix_groups`:
```
group_outcome = regression IF any finding in group ended regression
           ELSE partial     IF any finding in group ended partial
           ELSE verified
```

For each regression group:
```bash
for f in group.results.files_modified: git checkout -- "$f"
for f in group.results.files_created:  rm -f -- "$f"
```
Log revert actions to trace.md. On `git checkout --` failure or `rm -f` failure: per §24.2, log verbatim, skip the rest of this group's reverts for safety, mark the group as `revert_failed=true`. Jump to step 9e revert-failure no-commit branch.

Capture `reverted_groups` and `surviving_groups` (verified + partial).

**All-regression degenerate case** (every group is regression): all revert loops ran; tree is restored; nothing to commit. Jump to 9e no-commit (all-regression) branch.

**Mixed case** (at least one surviving group): proceed to 9c.

**Step 9c — Stage + commit (only if surviving groups exist).**

```bash
# Confirm working tree state
git status --porcelain  # for trace record

# Stage surviving-group files (never -A)
for group in surviving_groups:
    for f in group.results.files_modified ∪ group.results.files_created:
        git add -- "$f"
```

Build commit message (§4 Phase 9c template):
```
fix: address code review findings (N groups committed, M reverted)

Fix groups (committed):
- [FG-1] F001, F003 — <files>: <claim snippet> ✓ verified
- [FG-2] F002 — <file>: <claim snippet> ⚠ partial (<phase_9_finding>)

Fix groups (reverted — regression detected):
- [FG-3] F004 — <file>: <claim snippet>

Post-fix review: X/Y groups verified complete; Z groups partial; W groups reverted.
Re-run /adams-review-fix to address partial and regression findings.
```

Default: one combined commit. With `--granular-commits`: one commit per surviving group. The message template above is per the combined case; granular case uses a per-group variant.

```bash
git commit -m "$(cat <<'EOF'
<message>
EOF
)"
commit_sha=$(git rev-parse HEAD)
```
**Capture `commit_sha` immediately** — before any later step. Per §9c step 4.

**Step 9d — State transitions (one helper call).**

Build `--apply-fix-outcomes` tuple array:
```bash
apply_tuples=$(jq -nc \
    --arg run_id "$run_id" --arg input_sha "$input_sha" --arg commit_sha "$commit_sha" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson outcomes "$phase_9a_outcomes" \
    --argjson reverted_ids "$reverted_finding_ids_json" \
    '...'
)
# Where each outcome tuple includes:
#   output_sha: $commit_sha if finding's group is surviving, else null (regression)
#   phase_9_outcome: from phase_9a_outcomes
#   phase_9_finding + revised_fix_proposal: passed through
echo "$apply_tuples" | artifact-patch.py --path "$artifact_path" --apply-fix-outcomes @-
```

One call. Every touched finding transitions in one batch. fix_attempts appended per-finding atomically.

**Step 9e — Terminal cleanup (runs every time, deterministic order per §4 Phase 9e / §24.4).**

For runs that produced a commit (mixed / surviving-group case):

1. **fix_attempts appended + state transitions.** Done in 9d.
2. **Schema validate.** `artifact-validate.sh --path "$artifact_path"`. Record pass/fail in trace.md.
3. **Re-render artifact.md.** `artifact-render.py --input "$artifact_path" --output "$review_dir/artifact.md"`.
4. **Append phases.jsonl record.**
   ```json
   {"phase": 9, "name": "post-fix-review", "elapsed_sec": N,
    "counts_by_state": {...}, "counts_by_disposition": {...},
    "delta": "X verified, Y partial, Z regression (FG-N,... reverted)",
    "run_id": "...", "commit_sha": "...", "ts": "..."}
   ```
5. **`git push`** (PR mode). Non-zero → log `push_failed` with stderr to trace.md. Do NOT undo. Continue.
6. **`artifact-publish.sh --mode pr --comment-id <id>`** (PR mode). comment_id pulled from artifact (persisted by `/adams-review`). Non-zero → log `publish_failed` with stderr. Continue.
7. **`git stash pop`** if `stash_taken`. Conflict → log `stash_pop_conflict`; leave stash ref in place; surface stash ref in user message. Continue.
8. **Surface first failure** ordered `push_failed > publish_failed > stash_pop_conflict`. If none: success summary.

For runs that produced no commit (overlap-abort, all-regression, per-group revert failure, empty-eligibility):

1. **fix_attempts appended** (via `--apply-fix-outcomes` with null output_sha where applicable). For overlap-abort: current_state stays attempted (triggers leftover-attempted hard abort on next run). For all-regression: attempted→open with disposition=regression. For empty-eligibility: no findings touched, nothing to append.
2. **Schema validate + re-render + append phases.jsonl** (steps 2-4 from committed branch).
3. **Stash pop** if `stash_taken`, UNLESS degenerate case is revert-failure that left tree in unknown state — then leave stash in place, note ref in user error.
4. **No push, no publish** — nothing to ship. Artifact update is still valuable for next-run staleness + user inspection.
5. **Surface user-visible degenerate-case error** describing what happened + recommended next step.

**User-visible summary** (after all cleanup): mirror § 26.9 step 8's style — one block summarizing committed, reverted, remaining-retry-eligible findings, commit SHA, PR comment URL.

One commit.

### 3.G — `artifact-render.py` fix_runs section + Status column

Extend `commands/_shared/tools/artifact-render.py`.

**New section: `## Fix runs`**

Appended after the main report (after Pre-existing section) when any finding has `fix_attempts`. Derived view — group `fix_attempts` across all findings by `run_id`, reverse-chronological.

Per-run block:
```markdown
### Run `<run_id>` — 2026-04-18T20:15:03Z

- Findings attempted: <count>
- Verified: <N>
- Partial: <M>
- Regression: <P>
- Commits: `<short_sha>` (link if PR mode)

| Finding | Group | Outcome | phase_9_finding |
|---|---|---|---|
| F001 | FG-1 | ✓ verified | — |
| F002 | FG-2 | ⚠ partial | "missed search.ts:142" |
| F003 | FG-3 | ✗ regression (reverted) | "new 401 on valid tokens" |
```

Overlap-abort runs (phase_9_outcome=null) show as `⚠ overlap-abort` with the phase_9_finding text as diagnosis.

**Status column on Auto-fixable table.**

Per Stage 1 close-out: "column appears automatically when any row has a `fix_attempts` entry; it's absent pre-fix." Verify this holds for the new dispositions (`partial`, `regression`, `resolved`):
- `disposition: resolved` → `✓ verified` + commit link.
- `disposition: partial` → `⚠ partial` + commit link (partial fixes still commit).
- `disposition: regression` → `✗ regression (reverted)` + no commit link.

The Auto-fixable table is already filtered on `confirmed_auto` — findings that transitioned to `resolved` leave the Auto-fixable bucket (they move to their own rendered section if one exists, or just stop appearing there). Need to verify:
- Do we add a "Resolved" section? §7 doesn't mandate one; resolved findings surface in the Fix runs section's verified-count.
- For `partial` / `regression` findings: they stay `current_state=open` but their disposition changes. Per §7 filter, they surface under sections filtered on `disposition in {partial, regression}`. If those sections don't exist in the current renderer, add them as a pair.

Actually simpler interpretation: `partial` and `regression` are part of the deep-lane "retry-eligible" bucket. Add one section:

```markdown
### ⟳ Retry-eligible (N) — `disposition: partial` or `disposition: regression`

| # | Score | Outcome | File | Finding | phase_9_finding |
|---|---|---|---|---|---|
| F002 | 80 | ⚠ partial    | ... | ... | "missed search.ts:142" |
| F003 | 78 | ✗ regression | ... | ... | "new 401 on valid tokens" |
```

Surfaces only when at least one finding is in retry-eligible state.

**Smoke assertions** (FX-RF-1 … FX-RF-5):
- RF-1: fixture with one finding having one verified fix_attempts entry → Fix runs section present, verified count=1.
- RF-2: fixture with one partial + one regression + one verified in same run_id → Fix runs block shows mixed counts; retry-eligible section surfaces the partial and regression.
- RF-3: fixture with two runs (different run_ids) → two Fix runs sub-blocks in reverse-chronological order.
- RF-4: fixture with no fix_attempts → Fix runs section ABSENT (backward compat with pre-Stage-3 artifacts).
- RF-5: fixture with overlap-abort fix_attempt (phase_9_outcome=null) → Fix runs block shows `⚠ overlap-abort` for that finding.

One commit. Fixture seeds added to `test/fixtures/` as needed.

### 3.H — Smoke test additions

Consolidate all FX-* assertions from 3.A–3.G into `test/smoke.sh`. Breakdown:
- FX-GF-1..7 (group-fixes.py): 7 assertions
- FX-AF-1..8 (artifact-patch.py modes): 8 assertions
- FX-RF-1..5 (render fix_runs): 5 assertions

Total: 20 new assertions. `test/smoke.sh` grows from 71 → ~91 assertions.

Where possible, each smoke assertion family lands in the same commit as the code it tests (3.A, 3.B, 3.G). No standalone smoke commit expected.

### 3.I — DESIGN.md + BUILD.md close-out

**DESIGN.md updates:**
- §21.2 gains two clarification paragraphs (similar shape to the existing `--apply-decisions` paragraph added at Stage 2.5.B): one for `--apply-fix-start`, one for `--apply-fix-outcomes`. Interface, derivation rules, overlap-abort handling, exit codes, no-dry-run rationale.
- §9.1 — no changes; the file-list already includes `08-fix-loader.md`, `09-fix-execution.md`, `10-post-fix-and-commit.md`, and `group-fixes.py`. Verify at close-out.
- Any mid-stage DESIGN discrepancies — update inline + record in BUILD Cross-stage notes.

**BUILD.md updates:**
- "Current state" section: flip to Stage 3 done + date.
- Stage index row: flip Stage 3 to done + close-out link.
- Stage 3 section: fill in Status, Files landed, Verification evidence, Open issues / deviations.
- Cross-stage notes: append any Stage 3 observations (real-repo deferral, batched-helper-pattern second instance, Phase 8/9 agent prompt surface area, any DESIGN drift).

One commit (the close-out).

---

## 4. Out of scope (explicit)

- Light-lane auto-fix.
- `--cleanup-pre-existing`, `--resume-interrupted` flags.
- Ensemble external reviewers for fix review (Phase 1.5 is review-only; fix doesn't have an ensemble surface in v1).
- Commit signing / GPG configuration.
- Deep prompt tuning of §19.8 / §19.9 beyond verbatim reproduction — real-repo feedback will drive tuning in v2.
- Fragment prose shrink (Stage 4).
- Real-repo end-to-end smoke run (deferred, same pattern as 2.6/2.7).
- Any touch to `/adams-review` or its fragments — Stage 3 is additive.

---

## 5. Commit cadence (estimated)

~9 commits total, roughly:

1. **Stage 3 plan** (this file, check in first). No code.
2. **3.A**: `group-fixes.py` + smoke FX-GF-1..7.
3. **3.B**: `artifact-patch.py --apply-fix-start` + `--apply-fix-outcomes` + smoke FX-AF-1..8 + DESIGN §21.2 paragraphs.
4. **3.C**: `commands/adams-review-fix.md` scaffold.
5. **3.D**: `08-fix-loader.md` fragment.
6. **3.E**: `09-fix-execution.md` fragment.
7. **3.F**: `10-post-fix-and-commit.md` fragment.
8. **3.G**: `artifact-render.py` fix_runs + retry-eligible section + smoke FX-RF-1..5.
9. **3.I**: BUILD.md + DESIGN.md close-out.

3.H (smoke) is folded into 3.A / 3.B / 3.G as noted. If any sub-item discovers a genuine DESIGN gap, add a clarification commit between where it's surfaced and the close-out.

---

## 6. Risks / watchpoints

- **Orchestrator context budget on Phase 8 dispatch.** N parallel Agent tool-use blocks, each carrying its group's full `validation_result` + prior `fix_attempts` + CLAUDE.md text. Under the C13 run's 4 confirmed-auto findings this would be 4 agent prompts of ~5-10k tokens each = ~40k orchestrator context. Should scale to ~10-15 findings before context pressure. If real-repo runs hit the ceiling: delegate per-group prompt assembly to a helper script (mirroring Stage 2.5.C lever #2).
- **Delete/rename prohibition enforcement.** §19.8 forbids the fix-group agent from running `rm`, `git rm`, `git mv`. Today this is prompt-level only — the sub-agent inherits the parent's tool allowlist by default. Rely on prompt instruction + post-hoc `git status --porcelain` sanity check in 9.pre (a deleted file would show as `D <path>`, not in `files_modified` or `files_created` — currently not explicitly flagged). Worth adding a 9.pre assertion: "no file in working tree shows `D <path>` in `git status --porcelain`; if any does, abort with orchestrator-error prefix." This catches a delete that slipped through prompt instructions.
- **Phase 9 sub-agent's `git diff HEAD` surface.** Embedding the full working-tree diff in the prompt can explode if the fix groups made large edits. Cap at some sensible bound (e.g., 50k chars) with a truncation note; real-repo runs will tell us the actual distribution.
- **Commit-message escape characters.** The commit message includes finding `claim` text which could contain characters needing escaping in a heredoc. Use `printf '%s\n' ...` through a tempfile + `git commit -F <tempfile>` rather than `-m "$(...)"` for safety.
- **`--granular-commits` ordering.** Per-group commits must still respect the "at most one commit per surviving group" invariant and the "regression groups reverted before any commit" invariant. The revert loop runs once in 9b; the granular commit loop happens in 9c after that. No ordering issue, just worth confirming in the fragment.
- **File-overlap detection at 9.pre.** Uses group's `actual_touched = files_modified ∪ files_created`. Needs to handle the edge case of a file in one group's `files_modified` that another group also `files_modified`-ed — the set comparison already catches this. Additional edge: what if one group lists a file in `files_modified` and another lists it in `files_created`? Both touched it; overlap detector should catch this too. The implementation should work on the union sets per §9.pre, which handles both cases.
- **`artifact-patch.py --apply-fix-outcomes` atomic-per-tuple.** If tuple N fails, tuples 0..N-1 are persisted. For Phase 9d this means a partial batch could leave some findings at `resolved` and others still `attempted`. The next run would then hit the leftover-attempted hard abort — deterministic recovery, but the user has extra work. Same tradeoff as `--apply-decisions`; consistent enough.
- **`latest_known_sha` derivation edge cases.** If all prior `fix_attempts` have `output_sha: null` (e.g., prior run was overlap-abort or all-regression), the jq fallback needs to reach `reviewed_sha`. The expression `[.findings[].fix_attempts[]?.output_sha | select(. != null)] | last // .reviewed_sha` handles this — the `select(. != null)` filters first, then `last` grabs the most recent non-null, then `//` falls through to reviewed_sha.
- **Phase 7 clean-tree gate on an already-stashed repo.** If the user has existing stashes and dirty files, our stash adds another stash entry. That's fine — our stash is named `pre-adams-review-fix-stash` and uses the `@{0}` most-recent semantics for pop. Possible edge case: user runs two fix commands in quick succession, both take stashes. Second pop would pop the first's stash. Mitigation: `git stash pop stash@{0}` and verify the ref. For v1: accept the risk; note in cross-stage notes if observed.

---

## 7. Plan status

- Drafted 2026-04-18.
- Plan-and-execute: no separate approval round-trip. Execution proceeds immediately after this file is committed.
- Mid-stage changes to the plan: update this file in-place + record in BUILD.md cross-stage notes. Don't let the plan-file and reality drift.
