---
allowed-tools: Bash(artifact-read.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(claude-md-paths.sh:*), Bash(staleness.sh:*), Bash(external-scrape.sh:*), Bash(log-phase.sh:*), Bash(log-tokens.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(origin-crosscheck.sh:*), Bash(assign-finding-ids.sh:*), Bash(group-fixes.py:*), Bash(repo-slug.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(timeout:*), Bash(sleep:*), Bash(kill:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(mktemp:*), Bash(cat:*), Bash(printf:*), Bash(echo:*), Bash(grep:*), Bash(awk:*), Bash(sed:*), Bash(tr:*), Bash(wc:*), Bash(head:*), Bash(tail:*), Bash(cut:*), Bash(sort:*), Bash(diff:*), Bash(openssl:*), Bash(python3:*), Bash(node:*), Bash(find:*), AskUserQuestion, Agent, Read, Edit, Write, BashOutput, KillShell
argument-hint: "[threshold] [--granular-commits]"
description: Apply auto-fixable code review findings. Dispatches fix-group agents, post-fix-reviews the working tree, commits survivors, reverts regressions, updates the artifact.
disable-model-invocation: false
---

Arguments (optional):
- First positional (integer 0–100) → `threshold` (default `60`). The
  Phase 8 fix gate: `confirmed_mechanical`/`partial`/`regression` findings
  with `score_phase4 >= threshold` are eligible. `/adamsreview:fix 80`
  excludes moderate-strength findings from the run.
- `--granular-commits` → one commit per surviving fix group. Default is
  one combined commit for all survivors.

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every phase below (sub-agent return handling,
helper-script error-as-prompt).**

## Execution overview

This command orchestrates Phases 7, 7.5, 8, and 9 in order. Each phase
is defined in a fragment under `fragments/NN-<name>.md`. At each phase
boundary below, read the named fragment with the `Read` tool and
execute the instructions inside before proceeding to the next phase.

Phase 7.5 (auto-recommendation preflight) lives at the end of
`fragments/08-fix-loader.md`. When that fragment populates Phase
5.5's `auto_fix_hint` on findings, Phase 7.5 surfaces them in a
batch-confirm UI before Phase 8 dispatch — apply-all / review-per-
finding / skip / cancel. On the apply-all and review paths, the user
choices are committed via `human_confirmation` so Phase 8's gate
picks them up via the existing bypass (no Phase 8 wiring change
needed). On skip, Phase 8 runs against originally-eligible findings
only. On cancel, `:fix` aborts and any stash from 7.5's clean-tree
gate is restored.

**Before you start, build a TaskList that mirrors the phases below**
(one task per phase, plus one for argument parsing). Mark each
`in_progress` when you start it and `completed` when you finish.

`attempted` is the transient recovery anchor. Between Phase 8 completing
and Phase 9e writing fix_attempts, findings sit in
`current_state=attempted`. If the run is interrupted there — or if
Phase 9.pre detects a touched-file overlap and the reviewer chooses
abort (default) or inspect — the next `/adamsreview:fix` invocation's
Phase 7 step 4 hard abort catches the leftover `attempted` state and
gives the user a deterministic recovery prompt. Never clean up
`attempted` state silently; that's the user's call. (Reconcile does
NOT leave findings at `attempted` — it commits or reverts just like a
non-reconciled run.)

In Phase 9e, state transitions + fix_attempts append + schema validate
+ render all run BEFORE any `git push` or `artifact-publish.sh` call.
Push or publish failure never leaves the artifact out of sync with git.

Phase 9b reverts any fix group whose findings Phase 9a classified as
regression, before Phase 9c commits. Surviving groups' files stage
explicitly by name (never `git add -A`); regression-group files are
restored with `git checkout --` (for modified files) or `rm -f` (for
created files).

Push failure, publish failure, stash-pop conflict — each gets logged to
`trace.md` with a specific tag; the terminal block proceeds; the FIRST
failure is surfaced to the user at the end. The artifact's state is
already persisted so the user can re-run cleanly.

If a phase genuinely cannot run, mark the task `completed` with a
one-line `trace.md` note and move on. Phase 9e's terminal cleanup runs
unconditionally — every run finishes with artifact state consistent
with what actually happened on disk.

## Sub-agent dispatch pattern

Every Agent tool-use specifies:
- `subagent_type: general-purpose`.
- `model:` explicitly:
  - Phase 8 fix-group agents → `opus`.
  - Phase 9a post-fix reviewer → `opus`.

**Parallel fan-outs** happen by firing multiple Agent tool-use blocks
in a single orchestrator turn. Phase 8's fix-group dispatch fans out
all groups at once — don't wait a turn between them. Phase 9a is a
single-agent call (one sub-agent reviews the whole working tree).

## Argument handling

Parse `$ARGUMENTS` (whitespace-split):
- First token that parses as a non-negative integer → `threshold`.
- `--granular-commits` → `granular_commits=true` (else `false`).
- Any other token → stop and ask the user to clarify.

If no integer was provided, `threshold=60` (default).

Capture both in your working context before executing Phase 7.

---

**Phase 7 — Fix loader + Phase 7.5 — Auto-recommendation preflight.**
Read `fragments/08-fix-loader.md` and execute the instructions inside
before proceeding to Phase 8. The loader fragment covers both phases:
Phase 7 (steps 7.1–7.8) loads the artifact, runs the gates, and
captures `run_id` / `input_sha`; Phase 7.5 (steps 7.5.1–7.5.5) then
filters auto-rec promotable findings against the at-fix-time
`$threshold`, asks the user how to proceed (apply-all / review /
skip / cancel), and either batch-promotes via
`artifact-patch.py --apply-auto-rec-promotions` or aborts. On cancel,
the fragment exits the run cleanly (with stash-pop) before Phase 8
ever dispatches.

---

**Phase 8 — Fix execution.** Read `fragments/09-fix-execution.md` and
execute the instructions inside before proceeding to Phase 9.

---

**Phase 9 — Post-fix and commit.** Read
`fragments/10-post-fix-and-commit.md` and execute the instructions
inside.

---

## What this command does NOT do

- **No deletes, renames, or moves in the working tree (v1).** Fix
  groups edit via `Edit`/`Write` only; the revert model in Phase 9b
  only handles modifications and creations.
- **No automated recovery** from leftover-`attempted` state. Phase 7
  step 4 aborts with a deterministic recovery message; the user
  decides what to keep.
- **No light-lane auto-fix without consent.** Phase 8 eligibility's
  default selector is restricted to `impact_type ∈ {correctness,
  security}`; light-lane findings flow through Phase 8 only when
  Phase 7.5's preflight (or `:walkthrough` / `:promote`) has set
  `human_confirmation` on them, which bypasses the impact_type filter
  and the score gate. Phase 7.5 makes this opt-in: the user sees
  every light-lane auto-rec candidate and chooses apply-all / review /
  skip / cancel before any promotion lands.
- **No review of closed/merged PRs** — Phase 7 step 7.7 aborts with a
  user-visible message.
- **No git operations inside fix-group sub-agents.** All staging,
  commits, and push happen in the orchestrator's Phase 9c / 9e.
