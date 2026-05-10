# CLAUDE.md — operational guide for adamsreview

Read on a fresh session. Procedural how-to for the adamsreview plugin. Reference docs load on demand: `docs/state-and-gates.md` (state model, score gates, lanes), `docs/pipeline.md` (phase trees + token-tally semantics), `docs/helpers.md` (helper inventory). `bin/schema-v1.json` is the source of truth for artifact shape. `docs/archive/` is frozen historical reference — consult only for past-decision rationale.

## What this repo is

Build repo for six Claude Code slash commands packaged as plugin `adamsreview`:

- `/adamsreview:review [--ensemble]` — multi-lens review. Phase 0 preflight → 1 detection (up to 6 parallel lens agents — L2/L5/L6 conditional on `trivial_mode` and user-facing flags — plus L7 under --ensemble in non-trivial mode; L7 is a holistic Opus safety net) → 1.5 external-source pooling (Codex CLI + GitHub bot-comment scrape, Sonnet normalizer) → 2 dedup → 3 cheap scoring + gate → 4 validation (Opus deep / Sonnet light chunked) → 5 cross-cutting (deep-lane only) → 5.5 auto-fix-hint generation (Sonnet propose+verify two-pass) for confirmed_manual / confirmed_report / light-lane confirmed_mechanical findings ≥60 → 6 finalize + render + publish. `--ensemble` adds the Codex CLI + PR bot-comment scrape sources.
- `/adamsreview:codex-review [--effort low|medium|high|xhigh]` — Codex peer to `:review`. Same phase set (0-6 plus Phase 5.5 auto-fix-hint generation), Codex-driven detection/validation/cross-cutting via `bin/codex-poll.sh`; Phase 1.5 skipped (no ensemble); Phase 5.5 is Sonnet-driven (validator-agnostic, shared with `:review`). Same artifact shape (`reviewer_sources: ["internal-codex"]`) so drop-in for `:fix` / `:add` / `:walkthrough` / `:promote`. Sonnet shape-fixers per Codex output; Codex tokens billed externally (only Sonnet shape-fixer + normalizer + Phase 5.5 in `tokens.jsonl`). Fail-fast on missing Codex (no Claude fallback).
- `/adamsreview:add` — inject external findings (cloud `/ultrareview` paste, Opus once-over, manual finds) into the latest review's artifact. Locate latest → leftover-attempted gate → build candidates (paste-normalizer | structured `--file/--line/--claim` | mixed) → Sonnet dedup → assign continuing IDs → Phase 4 lane-aware (no Wave 2) → re-publish to existing PR comment.
- `/adamsreview:walkthrough [threshold]` — interactive driver for findings `:fix` would skip (deep-manual, deep-report, full light lane), restricted to effective score ≥ threshold (default 60). Two scope tiers (Qualifying / Full skip set) — `pre_existing_report` always routed to end-of-run `gh issue create` flow. Step 4.5 batch-accepts findings carrying `auto_fix_hint` (set by Phase 5.5) before the per-finding loop; per-finding loop skips the briefer sub-agent when `auto_fix_hint` is present, reusing the pre-computed hint.
- `/adamsreview:fix [threshold] [--granular-commits]` — automated fix loop for auto-fixable findings. Phase 7 load + leftover-attempted abort + clean-tree gate + staleness check → 7.5 auto-recommendation preflight (surfaces `auto_fix_hint` findings for batch-accept; promotes via `human_confirmation` bypass so Phase 8 picks them up) → 8 per-fix-group agents (no git ops) → 9 post-fix Opus review, revert regressions, commit survivors, append `fix_attempts`. Phase 9.pre overlap → reconcile/abort/inspect. Default one combined commit; `--granular-commits` does one per surviving fix group.
- `/adamsreview:promote <id>` — metadata-only override. Promotes a single finding to auto-fixable, bypassing Phase 8 lane filter and threshold. Run `:fix` after.

Recommended flow on a non-trivial PR: `:review` (or `:codex-review`) → optional `:add` → optional `:walkthrough` → `:fix`. Each command is independent; `:promote` is for one-off promotes outside the walkthrough flow.

Detailed phase trees and the `subagent_tokens` / `orchestrator_tokens` semantics: `docs/pipeline.md`. Both fields are re-tallied before every lifecycle command's final re-render so the published PR comment shows cumulative spend across the review → fix / add / walkthrough arc; `orchestrator_tokens` is opt-in via `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1` (macOS provenance-prompt avoidance).

Per-stage history: `plans/`. Historical backlog: `plans/old-backlog.md` (frozen 2026-05-04). Active follow-ups: GitHub issues.

## State, gates, lanes (TL;DR)

- **States.** `open` → `attempted` (Phase 8) → `resolved` (Phase 9 verified) | `→ open` (Phase 9 partial/regression). Leftover `attempted` on a fresh `:fix` → hard abort.
- **Disposition** is the routing key (11 values, set by Phase 3 / 4 / 9). `is_actionable` derives from disposition; never set independently.
- **Score gates.** Phase 3: 45 (single source-family demote to `below_gate`; ≥2 families auto-graduate). Phase 4 bands: 45 / 60 / 75 → `disproven` / `uncertain` / `confirmed_*` (strength: moderate 60–74, strong 75+). Phase 8 fix gate is a composite: state + disposition + lane filter + threshold; `human_confirmation != null` bypasses both lane and threshold.
- **Pre-existing override** (highest priority): `origin == pre_existing AND origin_confidence == high` → `pre_existing_report` regardless of score; set in Phase 3, re-asserted Phase 4.
- **Lanes.** Deep = `correctness` / `security` (Opus 4a, passes through Phase 5). Light = `ux` / `policy` / `architecture` (Sonnet 4b, report-biased; Phase 8 excludes light-lane `confirmed_mechanical` unless promoted via `:promote` or `:walkthrough`).

Full normative spec — disposition table, gate-rule code blocks, invariants, Phase 9 outcome map: `docs/state-and-gates.md`.

## Layout

`commands/` (bare-stem, namespacing is the plugin name) · `fragments/` (shared phase fragments + `lens-prompts/`; Phase-1/Phase-4/Phase-5 Codex variants are `01-codex-detection.md` / `05-codex-validation.md` / `06-codex-cross-cutting.md`; `_prelude-shared.md` is loaded by every command; `promote-core.md` is shared by `:promote` and `:walkthrough`) · `bin/` (helper scripts auto on `$PATH` via plugin runtime; `schema-v1.json` source of truth) · `hooks/` (SessionStart dep-check) · `scripts/dev-run.sh` (plugin-author iteration via `claude --plugin-dir`) · `test/smoke.sh`. Full tree: README §Layout.

## How to test

```bash
test/smoke.sh   # expects: smoke: PASS (N assertions)
```

New helpers add 2–3 assertions in the OC-* / FR-* / RH-* / FX-* / MP-* / WT-* naming style.

## Operational rules

Each rule is a decision learned the hard way.

1. **Bash 3.2 portable.** macOS `/bin/bash` 3.2 in practice. Avoid `declare -A`, `mapfile`/`readarray`, `${var,,}`. `awk '!seen[$0]++' | sort` for dedup. `set -euo pipefail` and process substitution are fine.

2. **uv shebang for Python helpers.** `#!/usr/bin/env -S uv run --quiet --script` with a `# /// script` inline dep spec. `--quiet` suppresses the cold-cache "Installed N packages" stderr line so smoke's `2>&1` capture stays clean (GH #13). Never `pip install` (PEP 668 blocks it on Homebrew Python 3.12+).

3. **Exit codes are a contract.** Python helpers: `0=OK, 1=validation, 2=invalid-transition, 3=dry-run-invalid, 4=unexpected, 5=missing-dep, 6=expected-mismatch (--apply-decisions tuple count != --expected; recover by re-dispatch), 7=all-rejected (--add-findings: every input element rejected; distinct from 1), 64=usage`. Codes 2 and 3 are context-sensitive — `parse-validator-result.py` reuses 2 for score-unrecoverable; `source-family-map.py` reuses 3 for unknown-family. Defined in `bin/_common.py`; reuse, don't invent.

4. **Error-as-prompt on every helper.** Non-zero exits emit `ERROR:` / `Valid input:` / `Did you mean:` / `Action:` stderr sections. No stack traces on expected errors. See `bin/_common.py:suggest()`.

5. **Atomic writes.** Writers go tmp-file → `rename` (`bin/_common.py:atomic_write`). On-disk artifact never in invalid state mid-run.

6. **Reviews root is `~/.adams-reviews/`, not `~/.claude/reviews/`.** Claude Code hardcodes a sensitive-file prompt on writes to `~/.claude/` that survives `bypassPermissions`. Override via `$ADAMS_REVIEW_REVIEWS_ROOT`.

7. **`repo_slug` comes from one helper.** `bin/repo-slug.sh --repo-root <path>` is the single source of truth. Never reimplement inline.

8. **Commit messages via `git commit -F <file>`, not `-m "$(…)"`.** Finding claims contain quotes/backticks/newlines. Temp-file message bodies sidestep the escape surface.

9. **Fix-group agents may not delete or rename files.** Layered enforcement: prompt prohibition + Phase 9.pre `git status --porcelain` scan for deleted-file entries (column 1 or 2 — staged or worktree).

10. **Bare-name grants in `allowed-tools`.** Plugin runtime puts `bin/` on `$PATH`, so `Bash(<script>.sh:*)` resolves cleanly — no absolute paths, no `$HOME` substitution. Helper invocations in command bodies and fragments use bare names too. Post-Stage-4 fragments are Read-loaded as inline markdown, not `!include`-preprocessed — no top-level command currently grants `Bash(include:*)`. `bin/include` remains for any future small (<~10 KB) transclusion site; adding one back requires reinstating the grant.

11. **Working set lives in-prompt, not shell vars.** Fragments are Read-loaded as orchestrator context (per rule 10), so "variables" like `review_id`, `comparison_ref`, `reviewed_files_all` are context values, not `$VAR`s. When a later fragment needs an artifact-stored value, call `artifact-read.sh --filter '.foo'` — don't pass through prose. Run-level vars that don't live in the artifact (`run_id`, `threshold`, `stash_taken`) are surfaced once at the top of the top-level command file. **Helpers receive absolute paths; fragments never assume a cwd. `log-phase.sh` writes to the Phase-0-known path — never opens its own file handle.** Per-phase variable inventory: `docs/pipeline.md` §Working set.

12. **`printf '%s\n'`, not `echo`, when piping JSON through bash variables.** Under zsh / dash / bash with `xpg_echo`, `echo "$x"` collapses `\\` to `\`, turning a valid JSON-encoded backslash (e.g., regex `\d` stored as `"\\d"`) into an invalid escape — next `jq` parse-errors. Artifact on disk is fine (Python writers go through `json.dump`); corruption only happens in the bash round trip. `printf '%s\n' "$x"` never interprets backslashes. When constructing prompt bodies that embed jq output, stream jq directly to a temp file and Read at the placeholder site. **Scope:** rule applies prospectively. The v0.2.9 hardening pass fixed the silent-corruption surfaces (helper output and §9a context builder feeding LLM prompts). 80+ pre-existing `echo "$VAR" | jq` sites under `set -euo pipefail` are loud-abort, not silent corruption — accepted residual risk; convert opportunistically when editing nearby.

## Helper index

All scripts live under `bin/` (auto on `$PATH`). Bare-name invocation: `Bash(<script>:*)` / `<script> --flag ...`. Categories: **readers** (no mutation, safe for any agent), **writers** (orchestrator-only), **utilities** (logs, tallies, batched scaffolding).

Each helper is self-documenting via its file header — `head -40 bin/<script>` for the contract. Full table + cross-references: `docs/helpers.md`. Batched-helper pattern (first-fail-halt for `--apply-*`, continue-on-error for `--add-findings`) also documented there.

## How to work on new changes

- **Bump `.claude-plugin/plugin.json` version** on user-visible behavior changes before merging — without it, `/plugin marketplace update` won't pick up the change. Patch bump for fixes; minor for new commands or breaking output-shape. Skip for docs-only / test-only / pure-refactor.
- **Legacy flat-named files in `plans/`** (`stage-N-*.md`, `<topic>.md`) predate the per-branch umbrella convention and stay as-is — cross-referenced from frozen archive docs and many helpers; don't bulk-rename.
