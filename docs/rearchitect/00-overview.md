# 00 — Overview

A clean-slate specification for a multi-perspective code review tool that runs as Claude Code slash commands. Supersedes the current `/adams-review`, `/adams-review-walkthrough`, `/adams-review-fix`, `/adams-review-promote` implementation.

This document is self-contained. The other docs in this directory expand individual sections; they should be readable independently.

## What the tool is

A code review pipeline that:

1. **Scans** a branch or PR diff from multiple perspectives (different prompts, different models, optionally repeated) and pools candidate bugs, UX gaps, policy violations, and security concerns.
2. **Validates** surviving candidates with deep per-candidate investigation (blast radius, writers/consumers, parallel paths, fix proposal).
3. **Reports** confirmed findings as a machine-readable artifact + a rendered Markdown report + a PR comment.
4. **Fixes** auto-fixable findings in a separate invocation, with post-fix review and regression revert.
5. **Walks** a reviewer through findings the auto-fixer would skip, capturing promote/skip decisions and filing issues for pre-existing bugs.

A single trusted scanner is not sufficient — every current AI-based reviewer misses bugs. Multi-perspective fan-out is a first-class design requirement, not an optimization. See `02-scanners.md` for the scanner portfolio.

## Goals

These goals drive every design decision in the rest of this spec. When a tradeoff is ambiguous, resolve in their priority order.

1. **Recall over precision in the scan phase.** The scan phase should over-report. Precision comes from the downstream scoring gate + deep validation, not from conservative scanners. A missed bug is much more expensive than a false positive.
2. **Fewer tokens per review at any given recall tier.** The default mode (`--mode thorough`) targets parity with today's spend while extracting more recall through repetition + corroboration voting + an unconstrained holistic scanner. The cheaper opt-in (`--mode standard`) targets the −40% reduction by dropping replicas and the holistic scanner. Primary lever: reduce duplicated diff/context reads across scanners. Secondary lever: prompt caching across the shared prefix.
3. **Less code, one language, small surface.** One language (TypeScript, compiled to Node ESM and shipped inside a Claude Code plugin), one schema library (Zod), one test framework (Vitest or Node's built-in test runner). Target ≤4,000 LoC end to end, vs. current ~14,000.
4. **Orchestration in code, not in prompts.** The LLM is called when judgment is needed; control flow, state transitions, artifact mutation, and token accounting run as deterministic TypeScript. The slash command is a thin trampoline.
5. **Easy to modify and extend.** New scanner = new file. New fix strategy = new file. New report section = new file. No prose-in-three-places problem. See `05-extending.md`.
6. **Easy for the user to use.** Namespaced slash-command verbs (`:review`, `:walkthrough`, `:fix`, `:add`, `:promote`, `:history`), each with its own description and flag surface so Claude Code's autocomplete + `/help` surfaces them naturally. Fewer flags, fewer state-model concepts exposed (`confidence: high` beats `disposition: confirmed_auto, actionability: auto_fixable, confirmed_strength: moderate`).
7. **Resumable and auditable.** Interrupts are safe. Every LLM call and every state change is an event in one log. `/adams-review:history` is a first-class verb.

## Non-goals

- **Not a replacement for CodeRabbit, Codex, or other hosted reviewers.** External reviewers plug in as additional scanners when the user opts in via a flag; their output flows through the same pipeline.
- **Not a merge tool, CI runner, or auto-merge bot.** The tool edits the working tree and writes a single commit when `fix` verifies. Humans merge.
- **Not language-specific.** The pipeline is language-agnostic; per-language heuristics live in scanner prompts, not in code.
- **No automatic file deletes or renames in v1.** Fix groups modify or create files. Delete/rename fixes stay manual.

## Baseline: where the tokens go today

From the most recent `/adams-review` run on `ray-finance feat/import-apple` (rev `01KPPT46J17C8M2SWWMS8D6SG8`, 2026-04-20, 20 files / 3,284 lines changed, 29 candidates → 9 confirmed, 4 uncertain, 4 disproven, 2 pre-existing, 11 below-gate):

| Phase | Role | Model | Agents | Tokens | % of total |
|---|---|---|---|---|---|
| 0 | user-facing classifier | haiku | 1 | 37,127 | 2.5% |
| 1 | L1 diff-local | haiku | 1 | 94,274 | 6.4% |
| 1 | L2 structural | opus | 1 | **259,342** | **17.5%** |
| 1 | L3 CLAUDE.md | sonnet | 1 | 9,837 | 0.7% |
| 1 | L4 comments | sonnet | 1 | 113,677 | 7.7% |
| 1 | L5 UX | sonnet | 1 | 104,883 | 7.1% |
| 1 | L6 security | sonnet | 1 | 95,434 | 6.4% |
| 1.5 | external normalizer | sonnet | 1 | 25,065 | 1.7% |
| 2 | dedup | sonnet | 1 | 30,567 | 2.1% |
| 3 | scoring gate | sonnet | 1 | 57,940 | 3.9% |
| 4a | deep validators | opus | 13 | **591,824** | **40.0%** |
| 4b | light validator | sonnet | 1 | 22,244 | 1.5% |
| 5 | cross-cutting | opus | 1 | 38,833 | 2.6% |
| **Total** | | | 25 | **1,481,047** | 100% |

Two dominant cost centers, combined 85.7% of spend:

- **Phase 1 fan-out (677k / 46%).** Six lens agents each re-read the diff. The four Sonnet lenses (L4+L5+L6 at ~315k plus L3 at 10k) have overlapping context that can be consolidated without losing perspective diversity.
- **Phase 4a deep validation (592k / 40%).** One Opus agent per candidate that survived Phase 3, each doing repo-wide blast-radius tracing. This is genuine reviewer work, not waste — the per-call cost (~45k avg) is what buys real bug detection.

Phase 3 scoring gate (58k) turned away 11 candidates that would otherwise have triggered Phase 4 (~550k of potential validation). That's an 11:1 ROI. **Keep the scoring gate.**

Phase 5 cross-cutting (39k) emitted 1 group for a 29-finding review. That's the lowest ROI in the pipeline.

Wall-clock: 51 minutes, dominated by Phase 1's slowest lens (~25min) and Phase 4a's fan-out (~14min). Parallelism is being used, but Opus latency caps both.

## Targets

Numeric targets the build plan optimizes toward. Measure after Stage 2 lands; adjust targets with data.

| Metric | Today | Target |
|---|---|---|
| Lines of code (prompts + helpers + orchestrator) | ~14,000 | ≤4,000 |
| Languages / runtimes | 3 (bash + python + markdown + uv + jq) | 1 (TypeScript, compiled to Node ESM) |
| Distribution | symlinks via `scripts/install.sh` | Claude Code plugin (`/plugin install`) |
| Top-level slash commands | 4 flat verbs | Namespaced verbs (`:review`, `:walkthrough`, `:fix`, `:add`, `:promote`, `:history`) |
| State dispositions | 11 | 3 core + derived view |
| Tokens per average-PR review (`--mode standard`, cheaper opt-in) | ~1.5M | ≤900k (-40%) |
| Tokens per average-PR review (`--mode thorough`, **default**) | ~1.5M | ≤1.6M (parity with today, with corroboration voting + holistic safety net for higher recall) |
| Tokens per average-PR review (`--mode ensemble`, opt-in) | n/a | ≤2.3M (thorough + 3 external reviewers from outside the Claude family) |
| Wall-clock per average-PR review (default `--mode thorough`) | ~50 min | ≤35 min |
| Test assertion count | 129 (smoke.sh, bash) | 40–60 (Vitest, typed) |

These are guidance, not contract. The spec cares about architecture; the targets are how we know architecture is paying off.

## How this spec is organized

Each doc stands alone. The order below is the suggested reading order, but any doc is self-contained enough to be modified without touching its neighbors.

- **`00-overview.md`** (this file) — goals, non-goals, baseline, targets.
- **`01-architecture.md`** — pipeline stages, data model, orchestrator, event log, artifact store.
- **`02-scanners.md`** — the multi-perspective scan phase. Scanner interface, default portfolio, repetition model, voting/corroboration. **This is the most modifiable document.**
- **`03-commands-and-ux.md`** — slash commands, flags, interactive walkthrough + fix + promote + add flows.
- **`04-build-plan.md`** — staged build plan for the AI agent. Each stage has a done-when checklist and acceptance test.
- **`05-extending.md`** — extension points for work-in-progress branches. How to plug in a new scanner, fix strategy, report section, model, or external tool without touching the pipeline.
- **`README.md`** — index + reading order + how to modify this spec.

## Guiding constraints

A few constraints have been fixed ahead of the detail docs to avoid relitigating them in every section.

- **Claude Code plugin distribution.** The tool ships as a plugin: `/plugin install adams-review` from a marketplace, or a path for local dev. Layout and install details in `04-build-plan.md § Stage 0`.
- **TypeScript, compiled to Node ESM.** Source is TypeScript; shipped output is `.mjs` bundled into the plugin under `scripts/`. Claude Code already ships Node for MCP, so the user-side dependency is zero. No Bun, no `tsx` on the user's machine. Testing uses Vitest or Node's built-in test runner during development.
- **Zod** for the artifact schema. No separate JSON Schema file; the Zod schema exports both runtime validators and the canonical TypeScript types.
- **Anthropic SDK (`@anthropic-ai/sdk`)** is a dev-time dependency for typed API shapes and recorded-response test fixtures. Real LLM calls at runtime flow through Claude Code's `Agent` tool-use, dispatched by slash commands — that's what gives us the Claude Code subscription billing, tool access, and user-controlled effort level. The orchestrator script is the TypeScript layer that composes prompts, collects results, and maintains state between those dispatches; it never makes an outbound HTTP call to Anthropic itself. See `01-architecture.md § Orchestrator model` for the mechanics.
- **One artifact per review, one event log per artifact.** Artifact is the canonical machine state; events are the append-only audit trail. Both live under `~/.adams-reviews/<repo-slug>/<branch>/<review_id>/`.
- **Prompt caching is on by default.** Every sub-agent call that shares a prefix (diff + CLAUDE.mds + repo context) uses Anthropic prompt caching. This is a token-budget line item, not an optional optimization. The orchestrator is responsible for composing prompts so that the cached prefix is identical across scanners.
- **Multi-perspective scanning is not optional.** A single scanner is never the default. The cheapest defined preset is `--mode quick` (see `02-scanners.md § Modes`), intended for trivial diffs or iteration — and even it runs more than one scanner.

## What a successful rebuild looks like

- A reviewer types `/adams-review:review` on a PR and 30–35 minutes later (default `--mode thorough`) gets a rendered report with confidence-tagged findings, posted as a PR comment.
- The reviewer can type `/adams-review:add "<paste from /ultrareview or another tool>"` to inject externally-sourced findings into the same artifact (Phase 4 validates them; PR comment updates in place).
- The reviewer can type `/adams-review:walkthrough` to interactively promote / skip / file-issue for the findings, or `/adams-review:fix` to apply the auto-fixable ones.
- Adding a new scanner takes one file and one line in a registry, with no changes to the pipeline.
- Adding a new fix strategy takes one file and one line in a registry.
- Modifying a report section takes one file.
- Onboarding a new AI agent to work on this codebase takes reading `docs/rearchitect/README.md` — no archive dive required.

If these statements are true after the build, the rebuild succeeded.
