# CLAUDE.md — operational guide for adams-review

Read this first on a fresh session. It's procedural (how to work in the repo). For normative spec, see `docs/DESIGN.md`. For historical rationale, see `docs/BUILD.md`.

## What this repo is

Build repo for two personal Claude Code slash commands:

- **`/adams-review`** — multi-lens code review of a branch or PR (Phases 0–6).
- **`/adams-review-fix`** — automated fix loop for auto-fixable findings (Phases 7–9).

Both are **built and in production use** as of 2026-04-18 (Stages 1, 2, 2.5, 2.6, 2.7, 2.8, 3 closed). The only unexecuted scope is Stage 4 (fragment shrink), scoped in `plans/stage-4-fragment-shrink.md`.

## Layout

```
adams-review/
├── CLAUDE.md                       ← this file
├── README.md                       ← setup + layout
├── docs/
│   ├── DESIGN.md                   ← normative spec (rev 8); cite by §X.Y
│   └── BUILD.md                    ← historical build journal
├── plans/                          ← stage plans (1–3 closed; stage-4 live)
├── commands/
│   ├── adams-review.md             ← top-level slash command (Phases 0–6)
│   ├── adams-review-fix.md         ← top-level slash command (Phases 7–9)
│   └── _shared/                    ← symlinked into ~/.claude/commands/_shared
│       ├── 00-preflight.md … 10-post-fix-and-commit.md   ← phase fragments
│       ├── lens-{ux,security}-reference.md
│       ├── schema-v1.json
│       └── tools/                  ← helper scripts
└── test/
    ├── smoke.sh                    ← 105-assertion harness
    └── fixtures/
```

Top-level command files (`~/.claude/commands/adams-review.md`, `adams-review-fix.md`) need **per-command symlinks** to be reachable as slash commands. The `_shared/` directory symlink propagates fragments + helpers automatically, but new `commands/*.md` files require `ln -s $PWD/commands/<name>.md ~/.claude/commands/<name>.md`.

## How to test

```bash
test/smoke.sh
```

Expects `smoke: PASS (105 assertions)`. Every helper script and renderer path is covered. Existing assertions should stay green across changes; new helpers should add 2-3 assertions in the OC-* / FR-* / RH-* / FX-* naming style.

## Dependencies

| Tool | Version | Notes |
|---|---|---|
| `uv` | 0.7+ | PEP 723 inline-script shebang (`#!/usr/bin/env -S uv run --script`) — no venv, no pip install. `brew install uv`. |
| `bash` | 4+ | Helpers use `#!/usr/bin/env bash`; macOS default `/bin/bash` is 3.2 so `brew install bash` or user's newer default is required. |
| `jq` | 1.6+ | `brew install jq`. |
| `gh` | 2.x | `brew install gh`, `gh auth login`. |
| `git` | 2.x | Standard. |

## Operational rules (distilled from Stages 1–3 cross-stage notes)

Read `docs/BUILD.md` "Cross-stage notes" section for full rationale. Summary:

1. **Bash 3.2 portable.** Helpers run under macOS `/bin/bash` 3.2 in practice. Avoid `declare -A`, `mapfile`/`readarray`, `${var,,}`. `awk '!seen[$0]++' | sort` beats associative arrays for dedup. `set -euo pipefail` is fine; process substitution is fine.

2. **uv shebang for Python helpers.** `#!/usr/bin/env -S uv run --script` with a `# /// script` inline dep spec. Never `pip install` directly (PEP 668 blocks it on Homebrew Python 3.12+).

3. **Exit codes are a contract** (docs/DESIGN.md §21.2 footnote). Python helpers: `0=OK, 1=validation, 2=invalid-transition, 3=dry-run-invalid, 4=unexpected, 5=missing-dep, 64=usage`. Defined in `tools/_common.py`; reuse, don't invent.

4. **Error-as-prompt on every helper.** Non-zero exits emit `ERROR:` / `Valid input:` / `Did you mean:` / `Action:` stderr sections. No stack traces on expected errors. See `tools/_common.py:suggest()`.

5. **Atomic writes.** Writers go tmp-file → `rename` (see `tools/_common.py:atomic_write`). The on-disk artifact is never in an invalid state mid-run.

6. **Reviews root is `~/.adams-reviews/`, not `~/.claude/reviews/`.** Claude Code hardcodes a sensitive-file prompt on writes to `~/.claude/` that survives `bypassPermissions` mode. Overridable via `$ADAMS_REVIEW_REVIEWS_ROOT`. See README "Review state location".

7. **`repo_slug` comes from one helper.** `tools/repo-slug.sh --repo-root <path>` is the single source of truth. Phase 0 and Phase 7 both call it. Do not reimplement the algorithm inline (prior divergence caused real-world `/adams-review-fix` failures — see docs/BUILD.md 2026-04-18 entry).

8. **Commit messages via `git commit -F <file>`, not `-m "$(…)"`.** Finding claims can contain quotes/backticks/newlines. Temp-file message bodies sidestep the whole escape surface.

9. **Fix-group agents may not delete or rename files.** Layered enforcement: prompt prohibition + Phase 9.pre `git status --porcelain` scan for `D ` entries. If a fix slips a delete past both layers, add a post-agent tree walk before escalating the prompt.

10. **Absolute paths in `allowed-tools` grants.** Under the `_shared/` symlink, `Bash(/Users/.../tools/<script>.sh:*)` resolves cleanly (§8.7 grant probe passed 2026-04-17). No relative-name + `PATH` fallback needed.

## How to work on new changes

- **Plan mode by default.** Per user's global CLAUDE.md: present plan, get approval, then execute. "Plan-and-execute" requests skip the approval round-trip. Bug fixes can go direct.
- **Blast-radius discipline before committing.** Check every writer, every consumer, parallel code paths, full function bodies, and stale comments. Self-review as if you were a reviewer.
- **`docs/DESIGN.md` tracks reality.** If behavior and spec diverge, update spec inline (clarification) or surface to user (behavioral change). Don't ship quiet divergences.
- **New stages get a `plans/stage-N-<name>.md`** drafted in plan mode, user-approved before execution.

## Batched-helper pattern

Three `artifact-patch.py` modes (`--apply-decisions`, `--apply-fix-start`, `--apply-fix-outcomes`) share a pattern: JSON array of tuples, per-tuple atomic writes, first-failure halt, one summary line. If you add a fourth batched mode, reuse the scaffolding (`_check_*_tuple` validator + `_load_or_fail` per tuple + `_write_and_emit(silent=True)`). Accept that mid-batch failure leaves tuples 0..N-1 persisted; callers re-invoke with the remainder.

## Commits

Imperative mood. Reference DESIGN section where relevant (e.g., "Add comment-freshness.sh (§13.13, §21.10)"). Commit at natural breakpoints within a stage, not one giant stage-final commit. A stage close-out commits its BUILD.md update in isolation.

## Where to look when debugging

- **Phase behavior** — `docs/DESIGN.md` §4 (pipeline narrative), §13.x (per-phase algorithm), §19.x (sub-agent prompts).
- **Schema** — `commands/_shared/schema-v1.json` is the source of truth; `docs/DESIGN.md` §5–§6 is the narrative.
- **Helper contracts** — `docs/DESIGN.md` §21.1–§21.10.
- **Working-set variables** — `docs/DESIGN.md` §25.1.
- **Historical rationale for a decision** — `docs/BUILD.md` Cross-stage notes (chronological).
- **Why things don't obviously live at the path you expect** — cross-stage notes again; the build history is dense with "we moved X because Y".
