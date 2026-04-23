---
allowed-tools: Bash(artifact-read.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(claude-md-paths.sh:*), Bash(staleness.sh:*), Bash(external-scrape.sh:*), Bash(comment-freshness.sh:*), Bash(prior-fix-diff.sh:*), Bash(line-range-check.sh:*), Bash(log-phase.sh:*), Bash(log-tokens.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(repo-slug.sh:*), Bash(include:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(cat:*), Bash(printf:*), Bash(echo:*), Bash(grep:*), Bash(awk:*), Bash(sed:*), Bash(tr:*), Bash(wc:*), Bash(head:*), Bash(tail:*), Bash(cut:*), Bash(sort:*), Bash(diff:*), Bash(openssl:*), Bash(python3:*), Bash(coderabbit:*), Bash(node:*), Bash(find:*), AskUserQuestion, Agent, Read, BashOutput, KillShell
argument-hint: "[--ensemble] [--full]"
description: Deep code review producing artifact.json, artifact.md, and (PR mode) a review comment on the PR.
disable-model-invocation: false
---

Run an end-to-end code review per DESIGN §4 Phases 0–6. The result is a
validated `artifact.json`, a rendered `artifact.md`, and — in PR mode — a
posted-or-edited PR comment. Local mode skips the publish step but still
writes the artifact and mirrors the report to chat.

Flags (optional):
- `--ensemble` adds Phase 1.5 external-reviewer dispatch (CodeRabbit CLI
  + Codex CLI + GitHub PR bot-comment scrape, followed by a unified
  normalizer). Off by default — enable for a richer review at higher cost.
- `--full` forces `trivial_mode=false` for this run (overrides the
  §13.9 doc/config-PR early-exit).

## Execution overview — read this first

This command orchestrates DESIGN §4 Phases 0–6 in order. Each phase is
defined in a fragment under `fragments/NN-<name>.md` — the bodies are
inlined via `!`cat`` preprocessor at the bottom of this file.

**Before you start, build a TaskList that mirrors the phases below**
(one task per phase, plus one for argument parsing). Mark each
`in_progress` when you start it and `completed` when you finish.

This matters because:

- **State carries forward across phases.** Phase 0 captures many
  variables the later phases reference by name (see §25.1 of DESIGN for
  the full working-set table — reproduced in summary at the end of
  00-preflight.md). Losing track of a variable (e.g. `reviewed_files_all`,
  `claude_md_paths`, `review_id`, `artifact_path`) breaks later phases.
- **Parallel fan-outs are expensive.** Phase 1's six internal lenses (or
  seven under `--ensemble`, including the holistic L7) and Phase 3/4's
  per-candidate agents all dispatch in single-turn parallel batches.
  Re-running a phase because you lost your place costs real
  tokens. Under `--ensemble`, Phase 1 and Phase 1.5 also dispatch as a
  joint fan-out in one orchestrator turn (DESIGN §13.12). The TaskList
  can still carry two tasks — mark both `in_progress` when you fire the
  dispatch turn, and both `completed` after the join step at
  01-detection.md 1.5 commits the pooled findings.
- **The artifact is the single source of truth.** Every state change
  goes through `artifact-patch.py` (with full re-validation). Never hold
  state in shell variables that aren't also written to the artifact.
- **Fail loud, continue the pipeline.** Sub-agent failures (non-zero,
  unparseable output, timeouts) get logged to `trace.md` and drop that
  candidate from the run — they don't abort the whole command. See
  DESIGN §24 for per-failure responses.

If a phase genuinely cannot run, mark the task `completed` with a
one-line `trace.md` note and move on. Phase 6 (finalize) runs
unconditionally — a partial review is still worth rendering and
publishing so the user can inspect what did succeed.

## Sub-agent dispatch pattern

Every Agent tool-use specifies:
- `subagent_type: general-purpose` (unless a plugin agent is needed —
  the only exceptions in this command are `codex:codex-rescue` and
  `coderabbit:code-reviewer`, wrapped by the ensemble fragment).
- `model:` explicitly — `haiku`, `sonnet`, or `opus` per the fragment's
  instructions and DESIGN §10's allocation table.

**Parallel fan-outs** happen by firing multiple Agent tool-use blocks
in a single orchestrator turn. Waiting a turn between each dispatch
serializes them. Always batch within one turn.

**After every sub-agent returns**, immediately (before branching on its
content):

1. Extract the token count. The Agent tool result exposes a structured
   `usage` field when available; otherwise parse
   `<usage>total_tokens: N</usage>` from the sub-agent's output text.
   On parse failure, log with `--tokens null` per §11.
2. Call `log-tokens.sh` with the
   phase, agent_role, agent_id, model, finding_id (when applicable),
   and the tokens value. This invariant (§24.4) ensures every agent's
   cost is accounted even when its output fails to parse.
3. Parse the sub-agent's structured output per the fragment's schema.
   Light repair (strip code fences, extract JSON block) is OK.
   One retry allowed on parse failure with a prompt addendum.
   Drop-with-note on second failure.

**Helper-script errors** follow DESIGN §8.6's error-as-prompt convention:
ERROR → context → Valid values → Did you mean → Action. When a helper
exits non-zero, parse the stderr, adjust your inputs per the guidance,
retry ONCE. Only escalate to the user if the second retry also fails.

## Effort is session-wide (§10.1)

Sub-agents dispatched from this command inherit the parent session's
effort level. There is no per-sub-agent `effort` override in current
Claude Code — the Agent tool exposes `model` but not `effort`. Every
sub-agent the pipeline spawns (Sonnet L1, Opus L2, Sonnet L3-L6, Opus
L7 under `--ensemble`, Phase 2 dedup Sonnet, Phase 3 scorers, Phase 4a
Opus validators, Phase 4b Sonnet validators, Phase 5 Opus cross-
cutting, ensemble normalizer)
runs at whatever effort the parent session is set to. Expect cost to
scale linearly with session effort. `medium` or `high` is the usual
baseline; reserve `xhigh`/`max` for deliberate high-stakes runs.

## Working-set variables (§25.1 summary)

Phase 0 captures — and every later phase reads by name — this set:

- **Identity**: `review_id`, `artifact_path`, `review_dir`, `reviews_root`
- **Repo context**: `repo_root`, `repo_slug`, `head_branch`,
  `base_branch`, `reviewed_sha`
- **Mode**: `mode` (pr|local), `pr_number`, `pr_state`, `ensemble_mode`,
  `force_full`, `trivial_mode`, `user_facing`, `stash_taken`
- **Diff surface**: `reviewed_files_all`, `claude_md_paths`,
  `num_files`, `lines_changed` (feed `pr_size_buckets` at Phase 6)
- **Timestamps**: `review_started_at` (captured BEFORE any push — anchors
  Phase 1.5 scrape window)
- **Log paths**: `phases_log_path`, `tokens_log_path`, `trace_log_path`
- **PR state continuity**: `existing_comment_id` (if Phase 0 found a
  prior-run comment on the same PR)

State lives in your working context, not as Bash exports — shell state
doesn't persist across Bash-tool calls.

## Argument handling

Parse `$ARGUMENTS` (whitespace-split) for:
- `--ensemble` → `ensemble_mode=true` (else `false`)
- `--full` → `force_full=true` (else `false`)
- Any other token → stop and ask the user to clarify.

Capture both in your working context before executing Phase 0.

---

!`include 00-preflight.md`

---

!`include 01-detection.md`

---

!`include 02-ensemble-adapter.md`

---

!`include 03-dedup.md`

---

!`include 04-scoring-gate.md`

---

!`include 05-validation.md`

---

!`include 06-cross-cutting.md`

---

!`include 07-finalize.md`

---

## What this command does NOT do

- No git commits, no git tags, no branch creation.
- The only `git push` is in Phase 0 step 0.9 (unpushed commits → PR
  branch), and ONLY in PR mode after user dirty-tree confirmation.
- No file deletes or renames anywhere in the working tree.
- No fix application — that's `/adamsreview:fix` (Stage 3).
- No review of closed/merged PRs — bail at Phase 0 step 0.4 with a
  user-visible message.
