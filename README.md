# adams-review

Build repo for four personal Claude Code slash commands:

- **`/adams-review`** — multi-lens code review of a branch or PR (phases 0–6).
- **`/adams-review-walkthrough`** — interactive driver for findings `/adams-review-fix` would skip; per-finding briefing + options + recommendation, batched re-render/re-publish, decisions-log PR comment (see DESIGN §28).
- **`/adams-review-fix`** — automated fix loop for auto-fixable findings surfaced by `/adams-review` (phases 7–9).
- **`/adams-review-promote`** — human override that promotes a single finding to auto-fixable (bypasses the Phase 8 impact_type lane filter and score threshold; see DESIGN §27).

All four live under `commands/` (with phase fragments and `_shared/promote-core.md` under `commands/_shared/`) and are consumed from `~/.claude/commands/` via symlink (see *Layout* below).

## Recommended flow

Not required — each command is independent — but the four work best in this order on a non-trivial PR:

1. **Review.** `/adams-review` — or `/adams-review --ensemble` if you have the CodeRabbit + Codex CLIs installed and want a multi-source review at higher token cost.
2. **Walkthrough.** `/adams-review-walkthrough` — step through every finding the fix command would skip at the default threshold (deep-manual, deep-report, deep-below-gate, and the entire light lane including light `confirmed_auto`). Each finding gets a briefing + options + recommendation; promote the ones you want auto-fixed with tailored fix-hints, skip the rest. Posts a decisions log to the PR for audit.
3. **Fix.** `/adams-review-fix` — applies every auto-eligible finding (including whatever was promoted in step 2). Commits each fix group separately with full provenance.

Step 2 is optional. You can go straight from review to fix if you only care about the auto-eligible findings the review already surfaced. The walkthrough exists for the case where the validator's default gates (ux/policy lanes, below-threshold scores) skipped findings you want auto-fixed.

Steps 2 and 3 can land days or weeks after step 1 — the review artifact persists under `~/.adams-reviews/<slug>/<branch>/`.

`/adams-review-promote <id>` remains useful for one-off manual promotions outside the walkthrough flow (e.g. promoting a `disproven` finding with `--force`, or scripted promote loops with `--defer-publish`).

## Documents

- **`CLAUDE.md`** — operational guide for Claude Code sessions working in this repo. Read first on a fresh session.
- **`docs/DESIGN.md`** — normative design (rev 8). The spec for schema, phase behavior, and helper contracts. Consult by section (e.g., `§13.1`) when tweaking pipeline behavior.
- **`docs/BUILD.md`** — historical build journal covering Stages 1–3 + 2.5/2.6/2.7/2.8. Archive; consult for rationale on past decisions.
- **`plans/`** — per-stage plan files. Stages 1–3 + 2.5/2.6/2.7/2.8 are closed. `stage-4-fragment-shrink.md` is the one live plan.

## Dependencies

### Runtime

| Tool | Version | Used by | Notes |
|---|---|---|---|
| `uv` | 0.7+ | `artifact-patch.py`, `artifact-render.py` | `brew install uv`. Scripts use a PEP 723 inline-script shebang (`#!/usr/bin/env -S uv run --script`) so `uv` fetches and caches `jsonschema` on first run — no venv, no global pip install |
| `python3` | 3.10+ | invoked by `uv` | `uv` will install a matching Python if needed |
| `bash` | 4+ | all `*.sh` helpers | macOS default `/bin/bash` is 3.2 — scripts use `#!/usr/bin/env bash` and rely on `brew install bash` or the user's newer default |
| `jq` | 1.6+ | `artifact-read.sh`, log helpers | `brew install jq` |
| `gh` | 2.x | `artifact-publish.sh`, `external-scrape.sh` | `brew install gh`, `gh auth login` |
| `git` | 2.x | everywhere | standard |

### Setup

```bash
# One-time symlinks so Claude Code sees the shared dir + each top-level
# command at its canonical path. The repo is the source of truth;
# ~/.claude/commands/* just points at it.
ln -s ~/Projects/adams-review/commands/_shared                         ~/.claude/commands/_shared
ln -s ~/Projects/adams-review/commands/adams-review.md                 ~/.claude/commands/adams-review.md
ln -s ~/Projects/adams-review/commands/adams-review-walkthrough.md     ~/.claude/commands/adams-review-walkthrough.md
ln -s ~/Projects/adams-review/commands/adams-review-fix.md             ~/.claude/commands/adams-review-fix.md
ln -s ~/Projects/adams-review/commands/adams-review-promote.md         ~/.claude/commands/adams-review-promote.md
```

The `_shared/` directory symlink propagates every helper script and fragment (including `promote-core.md`) automatically — only new **top-level command files** need per-command symlinks.

No separate Python dep install. First invocation of any `*.py` helper triggers `uv` to resolve `jsonschema` (or any other declared dep) and cache it. Subsequent runs are fast.

Verify:

```bash
readlink ~/.claude/commands/_shared                           # should print the repo path
readlink ~/.claude/commands/adams-review-walkthrough.md       # should print the worktree/repo path
uv --version                                                  # 0.7+
```

### Review state location

`/adams-review` writes per-run state (artifact, trace, phase logs, token logs) under `~/.adams-reviews/<repo-slug>/<branch>/<review_id>/`. Override with `export ADAMS_REVIEW_REVIEWS_ROOT=/some/other/path` if you want state elsewhere.

**Why not `~/.claude/reviews/`?** Claude Code hardcodes a sensitive-file permission prompt for writes to `~/.claude/...` that survives even `bypassPermissions` mode, and `~/.claude/reviews` is not on the short list of exempt subdirs (`.claude/commands`, `.claude/agents`, `.claude/skills`). Keeping review state outside `~/.claude/` avoids dozens of permission prompts per run.

**Migrating from pre-Stage-2.5 state.** If you have reviews under `~/.claude/reviews/`, either:

```bash
# Option A: move state to the new canonical root (recommended).
mv ~/.claude/reviews ~/.adams-reviews

# Option B: keep state at the old location via the env var (accepts the prompts).
export ADAMS_REVIEW_REVIEWS_ROOT=~/.claude/reviews
```

### Why `uv` instead of plain pip

PEP 668 (Python 3.12+ with Homebrew) marks system and user site-packages as externally managed and refuses direct `pip install`. The original plan assumed plain pip; `uv`'s inline-script dep spec is the cleanest workaround: each Python helper is self-contained, runs without activation ceremony, and its dep list lives next to the code that imports it. Tradeoff: requires `uv` on the machine running the scripts.

## Layout

```
~/Projects/adams-review/              ← this repo
├── CLAUDE.md                         ← operational guide (read first)
├── README.md                         ← this file
├── docs/
│   ├── DESIGN.md                     ← normative design (rev 8)
│   └── BUILD.md                      ← historical build journal (Stages 1–3 + hardening)
├── plans/                            ← per-stage plans
├── test/                             ← smoke harness + fixtures (Stage 1)
└── commands/
    ├── adams-review.md                ← top-level /adams-review slash command
    ├── adams-review-walkthrough.md    ← top-level /adams-review-walkthrough slash command
    ├── adams-review-fix.md            ← top-level /adams-review-fix slash command
    ├── adams-review-promote.md        ← top-level /adams-review-promote slash command
    └── _shared/                       ← symlinked into ~/.claude/commands/_shared
        ├── schema-v1.json             ← JSON Schema for artifact.json
        ├── promote-core.md            ← shared precondition + patch fragment (used by promote and walkthrough)
        ├── 00-preflight.md … 10-post-fix-and-commit.md  ← per-phase fragments for the review + fix commands
        ├── lens-*-reference.md        ← per-lens prompt references
        └── tools/
            ├── _common.py             ← shared Python helpers
            ├── artifact-patch.py      ← machine-state writer
            ├── artifact-render.py     ← JSON → Markdown
            ├── artifact-validate.sh   ← schema check (bash wrapper)
            ├── artifact-read.sh       ← jq wrapper
            ├── artifact-publish.sh    ← PR comment post/patch
            ├── claude-md-paths.sh     ← walk-up CLAUDE.md finder
            ├── staleness.sh           ← git diff intersection
            ├── log-phase.sh           ← trace.md + phases.jsonl appender
            ├── log-tokens.sh          ← tokens.jsonl appender
            └── (other helpers: group-fixes.py, repo-slug.sh, comment-freshness.sh, origin-crosscheck.sh, external-scrape.sh, assign-finding-ids.sh)
```

Each top-level command file needs its own symlink in `~/.claude/commands/` (see the *Setup* section above). The `_shared/` directory symlink propagates every fragment, helper, and schema automatically.

## Status

`/adams-review` and `/adams-review-fix` are built and in use. Stages 1, 2, 2.5, 2.6, 2.7, 2.8, and 3 closed between 2026-04-17 and 2026-04-18; see `docs/BUILD.md` for the full history. The only unexecuted scope is Stage 4 (fragment shrink — `plans/stage-4-fragment-shrink.md`), still pending plan approval.
