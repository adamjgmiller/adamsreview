---
allowed-tools: Bash(artifact-read.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(claude-md-paths.sh:*), Bash(staleness.sh:*), Bash(external-scrape.sh:*), Bash(log-phase.sh:*), Bash(log-tokens.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(origin-crosscheck.sh:*), Bash(assign-finding-ids.sh:*), Bash(group-fixes.py:*), Bash(repo-slug.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(timeout:*), Bash(sleep:*), Bash(kill:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(cat:*), Bash(printf:*), Bash(echo:*), Bash(grep:*), Bash(awk:*), Bash(sed:*), Bash(tr:*), Bash(wc:*), Bash(head:*), Bash(tail:*), Bash(cut:*), Bash(sort:*), Bash(diff:*), Bash(openssl:*), Bash(python3:*), Bash(node:*), Bash(find:*), AskUserQuestion, Agent, Read, Edit, Write, BashOutput, KillShell
argument-hint: "[threshold] [--granular-commits]"
description: Apply auto-fixable code review findings. Dispatches fix-group agents, post-fix-reviews the working tree, commits survivors, reverts regressions, updates the artifact.
disable-model-invocation: false
---

Run the per-finding fix loop per DESIGN §4 Phases 7–9. Reads the
artifact produced by the most recent `/adamsreview:review` on this branch,
dispatches fix-group agents, post-fix-reviews the working tree, and
either commits a coherent set of surviving fixes (with per-group
Phase-9 truth in the commit message) or leaves the tree exactly as it
found it (all-regression, revert-failure). When parallel fix groups
collide on shared files, Phase 9.pre offers the reviewer a choice
between abort (default), reconcile via one Opus merge agent (commits
a single reconciled fix if Phase 9 then verifies it), or inspect
(leave the tree for manual review).

Arguments (optional):
- First positional (integer 0–100) → `threshold` (default `60`). The
  §4 Phase 8 fix gate: `confirmed_mechanical`/`partial`/`regression` findings
  with `score_phase4 >= threshold` are eligible. `/adamsreview:fix 80`
  excludes moderate-strength findings from the run.
- `--granular-commits` → one commit per surviving fix group. Default is
  one combined commit for all survivors (§13.6).

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every phase below (sub-agent return handling,
helper-script error-as-prompt).**

## Execution overview — read this first

This command orchestrates DESIGN §4 Phases 7–9 in order. Each phase is
defined in a fragment under `fragments/NN-<name>.md`. At each phase
boundary below, read the named fragment with the `Read` tool and
execute the instructions inside before proceeding to the next phase.

**Before you start, build a TaskList that mirrors the phases below**
(one task per phase, plus one for argument parsing). Mark each
`in_progress` when you start it and `completed` when you finish.

This matters because:

- **The artifact is the source of truth.** Phase 7 loads every piece
  of context from `artifact.json` (review_id, reviewed_sha,
  reviewed_files_all, findings[], claude_md_paths, comment_id, …) —
  nothing runs fresh from the filesystem for *context* except the
  working tree. The §7.5 / §7.6a advisory git-state checks (staleness,
  branch-behind-base) read fresh ref state but only to gate the run,
  not to produce context that flows downstream.
  Losing track of a variable (`run_id`, `input_sha`, `stash_taken`,
  `latest_known_sha`, `eligible_finding_ids`) breaks later phases.
- **`attempted` is the transient recovery anchor.** Between Phase 8
  completing and Phase 9e writing fix_attempts, findings sit in
  `current_state=attempted`. If the run is interrupted there — or if
  Phase 9.pre detects a touched-file overlap and the reviewer chooses
  abort (default) or inspect — the next `/adamsreview:fix`
  invocation's Phase 7 step 4 hard abort catches the leftover
  `attempted` state and gives the user a deterministic recovery
  prompt. Never clean up `attempted` state silently; that's the
  user's call. (Reconcile does NOT leave findings at `attempted` —
  it commits or reverts just like a non-reconciled run.)
- **Artifact-records-commit-before-network (§24.4).** In Phase 9e,
  state transitions + fix_attempts append + schema validate + render
  all run BEFORE any `git push` or `artifact-publish.sh` call. Push or
  publish failure never leaves the artifact out of sync with git.
- **Never ship a regression.** Phase 9b reverts any fix group whose
  findings Phase 9a classified as regression, before Phase 9c commits.
  Surviving groups' files stage explicitly by name (never `git add -A`);
  regression-group files are restored with `git checkout --` (for
  modified files) or `rm -f` (for created files).
- **Fail loud, continue the terminal block.** Push failure, publish
  failure, stash-pop conflict — each gets logged to `trace.md` with a
  specific tag; the terminal block proceeds; the FIRST failure is
  surfaced to the user at the end. The artifact's state is already
  persisted so the user can re-run cleanly.

If a phase genuinely cannot run, mark the task `completed` with a
one-line `trace.md` note and move on. Phase 9e's terminal cleanup runs
unconditionally — every run finishes with artifact state consistent
with what actually happened on disk.

## Sub-agent dispatch pattern

Every Agent tool-use specifies:
- `subagent_type: general-purpose`.
- `model:` explicitly — per DESIGN §10:
  - Phase 8 fix-group agents → `opus`.
  - Phase 9a post-fix reviewer → `opus`.

**Parallel fan-outs** happen by firing multiple Agent tool-use blocks
in a single orchestrator turn. Phase 8's fix-group dispatch fans out
all groups at once — don't wait a turn between them. Phase 9a is a
single-agent call (one sub-agent reviews the whole working tree).

Token extraction, `log-tokens.sh`, structured-output parse, and
helper-script error-as-prompt behaviour are all covered by rules §1
and §2 of `fragments/_prelude-shared.md` — apply them after every
sub-agent returns and on every non-zero helper exit.

## Fix-group agent tool grants

Fix-group sub-agents inherit the parent session's tool grants. They are
expected (per DESIGN §19.8) to use `Edit` and `Write` only — NEVER git
commands, rm, git mv, or any filesystem-mutating Bash. The prompt
reinforces this; Phase 9.pre sanity-checks `git status --porcelain` for
any `D <path>` entries and aborts with an orchestrator-error prefix if
it finds one. Deletes and renames are `actionability: manual` in v1;
they should never reach Phase 8.

## Effort is session-wide (§10.1)

Sub-agents dispatched from this command inherit the parent session's
effort level. Phase 8 fix-group Opus agents and the Phase 9a post-fix
reviewer all run at whatever effort the parent session is set to.
`medium` or `high` is the usual baseline; reserve `xhigh`/`max` for
deliberate high-stakes runs.

## Working-set variables (§25.2 summary)

Phase 7 loads all of §25.1 from the artifact (review_id, artifact_path,
reviewed_sha, reviewed_files_all, base_branch, head_branch, pr_number,
pr_state, comment_id, trivial_mode, claude_md_paths, …) plus the
fix-specific set:

- **Run identity**: `run_id` (fixrun_ULID, generated Phase 7 step 7.8),
  `input_sha` (HEAD after any Phase 7 stash; recorded in fix_attempts).
- **Gates**: `threshold` (arg; default 60), `granular_commits` (bool),
  `latest_known_sha` (derived from prior fix_attempts output_sha OR
  reviewed_sha), `stash_taken` (from Phase 7 dirty-tree gate).
- **Execution**: `eligible_finding_ids` (CSV), `fix_groups` (Phase 8
  output: `[{id, finding_ids, files_planned, results:{files_modified,
  files_created, per_finding, per_file_summary}}]`).
- **Phase 9**: `phase_9a_outcomes` (per-finding verified/partial/
  regression + phase_9_finding + revised_fix_proposal), `overlap_files`,
  `reverted_groups`, `surviving_groups`, `commit_sha` (or null in
  degenerate cases).
- **Log paths**: `phases_log_path`, `tokens_log_path`, `trace_log_path`
  (all under `$review_dir` from the artifact).

State lives in your working context, not as Bash exports — shell state
doesn't persist across Bash-tool calls. Every helper receives absolute
paths; don't assume a cwd.

## Argument handling

Parse `$ARGUMENTS` (whitespace-split):
- First token that parses as a non-negative integer → `threshold`.
- `--granular-commits` → `granular_commits=true` (else `false`).
- Any other token → stop and ask the user to clarify.

If no integer was provided, `threshold=60` (DESIGN §13.2 default).

Capture both in your working context before executing Phase 7.

---

**Phase 7 — Fix loader.** Read `fragments/08-fix-loader.md` and execute
the instructions inside before proceeding to Phase 8.

---

**Phase 8 — Fix execution.** Read `fragments/09-fix-execution.md` and
execute the instructions inside before proceeding to Phase 9.

---

**Phase 9 — Post-fix and commit.** Read
`fragments/10-post-fix-and-commit.md` and execute the instructions
inside.

---

## What this command does NOT do

- No new review (that's `/adamsreview:review`). Findings, scores,
  validation_results, and cross_cutting_groups all come from the
  artifact this command loads; it never re-runs detection or scoring.
- **No deletes, renames, or moves in the working tree (v1).** Fix
  groups edit via `Edit`/`Write` only; the revert model in Phase 9b
  only handles modifications and creations (§19.8).
- **No automated recovery** from leftover-`attempted` state. Phase 7
  step 4 aborts with a deterministic recovery message; the user
  decides what to keep. A future `--resume-interrupted` flag could
  automate some of this.
- **No light-lane auto-fix.** Phase 8 eligibility is restricted to
  `impact_type ∈ {correctness, security}` per §13.2; a future
  `--include-light-fixes` flag could relax this.
- **No review of closed/merged PRs** — Phase 7 step 7.7 aborts with a
  user-visible message.
- **No git operations inside fix-group sub-agents.** All staging,
  commits, and push happen in the orchestrator's Phase 9c / 9e.
