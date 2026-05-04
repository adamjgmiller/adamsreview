---
branch: plans-claudemd-etc
base: main
started: 2026-05-04
---

# plans-claudemd-etc — umbrella

## Goal

Two things rolled into one branch:

1. Align this worktree with the new user-global rule for `plans/` umbrella files (per-branch umbrella with `branch`/`base`/`started` frontmatter, optional `<branch>-PRD.md` / `<branch>-PLAN.md` / `<branch>-JOURNAL.md` siblings).
2. **CLAUDE.md token-cost overhaul.** Trim CLAUDE.md to first-touch essentials, extract reference-style content (pipeline trees, helper inventory, token-tally minutiae) to `docs/` files that load on demand.

## Decided

- **Existing `plans/` stays as-is.** 34 legacy flat-named files (`plans/stage-N-*.md`, `plans/<topic>.md`) predate the new convention. They're referenced from 123 sites across `README.md`, `CLAUDE.md`, `docs/archive/DESIGN.md`, `docs/archive/BUILD.md`, command files, and helpers — and the archive docs are frozen-not-maintained, so a bulk rename would strand pointers permanently. Migrating-existing-projects rule option **3** (apply new convention to new branches only).
- **This branch creates its own umbrella** (this file) per the rule's "Create on first session" clause.
- **`CLAUDE.md` "How to work on new changes" gets a one-liner** so future branches default to the new convention instead of the legacy `stage-N-<name>.md` pattern.

## Executed (2026-05-04)

- **CLAUDE.md: 485 → 207 lines** (~57% line reduction; ~62% words: 6399 → 2404). Section headings preserved for cross-reference grep-resolvability (Pipeline shape, Score gates, How to work on new changes, Layout, Helper index, Operational rules).
- **`docs/pipeline.md`** (new, 175 lines) — full ASCII phase trees for all four lifecycle commands, plus the `subagent_tokens` / `orchestrator_tokens` semantics with over-count modes and stale-data preservation. CLAUDE.md keeps a one-paragraph summary per command + pointer.
- **`docs/helpers.md`** (new, 77 lines) — full reader / writer / utility tables, batched-helper pattern. CLAUDE.md keeps the one-line "each helper is self-documenting via `head -40 bin/<script>`" plus pointer.
- **In-place trims to CLAUDE.md** — command descriptions condensed, `## Dependencies` dropped (already in README §Dependencies), `## Layout` reduced to a one-paragraph skeleton (full tree in README §Layout), `## Score gates` lost the "Threshold summary" and verbose "Gate terminology" prose (the rules + Phase 8 fix gate are clear), `## Lanes` collapsed to two bullets, every operational rule trimmed of backstory.
- **Smoke verification.** L7-4 assertion grep-checks two literal strings in CLAUDE.md (`'7 under --ensemble'` and `'holistic Opus safety net'`) — both preserved in the new Pipeline-shape line. `test/smoke.sh`: PASS (312 assertions).
- **`plans/backlog.md` → `plans/old-backlog.md`.** Backlog frozen as historical snapshot; four still-open items filed as GH issues — **#26** (Phase 3 telemetry trio: was #1B/#1C/#24), **#27** (parse-with-repair migration: was FU-2), **#28** (exit-code cleanup: was FU-4), **#29** (post-fix robustness lens: was P2). FU-5 (codex-poll watchdog) marked closed inline — already shipped via PR #23. §4/§5 "probably leave alone" items kept as in-file rationale, intentionally not filed. Cross-refs updated in CLAUDE.md, README.md, `plans/post-conversion-ideas.md` to point at the renamed file.
- **Validation pass over CLAUDE.md + `docs/pipeline.md` + `docs/helpers.md`** — 10 parallel sub-agents, one per validatable section, fact-checked claims against the codebase. Surfaced 8 doc errors + 22 ambiguities; **zero code bugs**. Applied all 8 errors plus 8 high-value ambiguities; skipped taste-level polish. Notable fixes: pre_existing_report "Set by" was Phase 1 (actually Phase 3); `confirmed_mechanical` row's "deep lane" precondition removed (lane filter is a Phase 8 concern, not a disposition condition); Phase 7 attribution corrected (eligible_finding_ids and fix_groups are set in Phase 8, not Phase 7); Codex Phase 1 helper-pipeline order corrected (line-range-check runs before assign-finding-ids so dropped candidates don't consume monotonic IDs); walkthrough re-tally section ref §6.1 → §6.1+§6.2; phases.jsonl Phase-6 ordering rewritten to reflect throughout-the-run appends. `test/smoke.sh`: PASS (316 assertions; L7-4 substring guards `'7 under --ensemble'` and `'holistic Opus safety net'` both still present in revised review-line).
- **Round-2 reduction: state model + score gates + lanes extracted** to `docs/state-and-gates.md` (new, 105 lines), replaced in CLAUDE.md by a 7-line TL;DR pointer. Rationale: normative state/gate/lane spec is needed for tasks touching state writers/readers, irrelevant for most fragment/command/helper edits. The TL;DR keeps every concept *name* (states, dispositions, threshold numbers 45/60/75, lane partition) so an agent knows whether to follow the pointer. Per-branch umbrella naming bullet under `## How to work on new changes` shrunk to a single-line "don't bulk-rename legacy files" note (umbrella creation, frontmatter, PRD/PLAN/JOURNAL siblings are covered by user-global CLAUDE.md).
- **Round-3 reduction: working-set inventory extracted** to `docs/pipeline.md` §Working set; the section's path/cwd/log-phase invariants folded into operational Rule 11 (same topic family — Rule 11 is already the doctrine for "working set lives in-prompt"). Standalone `## Working set` section dropped from CLAUDE.md. No TL;DR stub: a variable inventory either needs the full list or doesn't, so a stub doesn't carry useful answers (unlike state/gates, where threshold numbers can resolve common questions without loading the full doc).
- **Final CLAUDE.md size: 485 → 81 lines (~83% smaller than baseline; ~55% smaller than the post-overhaul 178).** `test/smoke.sh`: PASS (316 assertions).

## Out of scope

- Renaming any existing `plans/*.md` file.
- Touching `docs/archive/` references (frozen).
- Backfilling umbrellas for already-merged branches.
- Updating closed-plan files that reference "CLAUDE.md Helper index" prose (the heading is preserved; closed plans tolerate stale pointers).
