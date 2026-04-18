# adams-review

Build repo for two personal Claude Code slash commands:

- **`/adams-review`** — multi-lens code review of a branch or PR (phases 0–6).
- **`/adams-review-fix`** — automated fix loop for auto-fixable findings surfaced by `/adams-review` (phases 7–9).

Both commands live under `commands/_shared/` and are consumed from `~/.claude/commands/` via symlink (see *Layout* below).

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
# One-time symlink so Claude Code sees the shared dir at its canonical path.
# The repo is the source of truth; ~/.claude/commands/_shared just points at it.
ln -s ~/Projects/adams-review/commands/_shared ~/.claude/commands/_shared
```

No separate Python dep install. First invocation of any `*.py` helper triggers `uv` to resolve `jsonschema` (or any other declared dep) and cache it. Subsequent runs are fast.

Verify:

```bash
readlink ~/.claude/commands/_shared   # should print the repo path
uv --version                          # 0.7+
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
    └── _shared/                      ← symlinked into ~/.claude/commands/_shared
        ├── schema-v1.json            ← JSON Schema for artifact.json
        ├── tools/
        │   ├── _common.py            ← shared Python helpers
        │   ├── artifact-patch.py     ← machine-state writer
        │   ├── artifact-render.py    ← JSON → Markdown
        │   ├── artifact-validate.sh  ← schema check (bash wrapper)
        │   ├── artifact-read.sh      ← jq wrapper
        │   ├── artifact-publish.sh   ← PR comment post/patch
        │   ├── claude-md-paths.sh    ← walk-up CLAUDE.md finder
        │   ├── staleness.sh          ← git diff intersection
        │   ├── log-phase.sh          ← trace.md + phases.jsonl appender
        │   └── log-tokens.sh         ← tokens.jsonl appender
        └── <phase fragments>          ← added in Stage 2 / Stage 3
```

The top-level command files (`~/.claude/commands/adams-review.md`, `adams-review-fix.md`) are added in Stages 2 and 3.

## Status

`/adams-review` and `/adams-review-fix` are built and in use. Stages 1, 2, 2.5, 2.6, 2.7, 2.8, and 3 closed between 2026-04-17 and 2026-04-18; see `docs/BUILD.md` for the full history. The only unexecuted scope is Stage 4 (fragment shrink — `plans/stage-4-fragment-shrink.md`), still pending plan approval.
