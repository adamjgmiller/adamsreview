# adams-review

Build repo for five personal Claude Code slash commands:

- **`/adams-review`** — multi-lens code review of a branch or PR (phases 0–6).
- **`/adams-review-add`** — inject externally-sourced findings (Claude Code cloud `/ultrareview` paste, an Opus once-over, a teammate's note) into the most recent review's existing artifact. Free-form paste mode dispatches a Sonnet normalizer; structured `--file/--line/--claim` mode skips it. One Sonnet dedup pass against existing findings; Phase 4 validation lane-aware (no Wave 2); re-renders + re-publishes to the existing PR comment.
- **`/adams-review-walkthrough`** — interactive driver for findings `/adams-review-fix` would skip; per-finding briefing + options + recommendation, batched re-render/re-publish, decisions-log PR comment (see DESIGN §28).
- **`/adams-review-fix`** — automated fix loop for auto-fixable findings surfaced by `/adams-review` (phases 7–9).
- **`/adams-review-promote`** — human override that promotes a single finding to auto-fixable (bypasses the Phase 8 impact_type lane filter and score threshold; see DESIGN §27).

All five live under `commands/` (with phase fragments and `_shared/promote-core.md` under `commands/_shared/`) and are consumed from `~/.claude/commands/` via symlink (see *Layout* below).

## Recommended flow

Not required — each command is independent — but they work best in this order on a non-trivial PR:

1. **Review.** `/adams-review` — or `/adams-review --ensemble` if you have the CodeRabbit + Codex CLIs installed and want a multi-source review at higher token cost.
2. **Add.** *(optional)* `/adams-review-add <paste...>` — if you ran a parallel review (cloud `/ultrareview`, Opus once-over, manual scan, etc.) that surfaced bugs the original review missed, paste the result here. The findings are validated by Phase 4 and land in the same artifact, deduped against what's already there. Auto-eligible additions feed step 4; non-eligible ones surface in step 3.
3. **Walkthrough.** *(optional)* `/adams-review-walkthrough` — step through every finding the fix command would skip at the default threshold (deep-manual, deep-report, deep-below-gate, and the entire light lane including light `confirmed_auto`). Each finding gets a briefing + options + recommendation; promote the ones you want auto-fixed with tailored fix-hints, skip the rest. Posts a decisions log to the PR for audit.
4. **Fix.** `/adams-review-fix` — applies every auto-eligible finding (including whatever was added in step 2 and promoted in step 3). Commits each fix group separately with full provenance.

Steps 2 and 3 are optional. You can go straight from review to fix if you only care about the auto-eligible findings the original review surfaced.

Steps 2–4 can land days or weeks after step 1 — the review artifact persists under `~/.adams-reviews/<slug>/<branch>/`.

`/adams-review-promote <id>` remains useful for one-off manual promotions outside the walkthrough flow (e.g. promoting a `disproven` finding with `--force`, or scripted promote loops with `--defer-publish`).

## Documents

- **`CLAUDE.md`** — operational guide for Claude Code sessions working in this repo. Self-contained for routine work; read first on a fresh session.
- **`docs/archive/`** — frozen design + build docs (2026-04-19 onward). `DESIGN.md` (rev 8) is the original normative spec; `BUILD.md` is the stage-by-stage journal. Not maintained; consult only for historical rationale behind a specific decision. See `docs/archive/README.md`.
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

### Installation

```bash
git clone <repo-url> ~/Projects/adams-review
cd ~/Projects/adams-review
bash scripts/install.sh
bash test/smoke.sh          # expect "smoke: PASS (…)"
```

Then try `/adams-review` in a Claude Code session on any branch or PR.

**Uninstall:** `bash scripts/uninstall.sh`

#### How install works

The install script does two things:

1. **Symlinks** six paths into `~/.claude/commands/` so Claude Code discovers the slash commands:

   ```
   ~/.claude/commands/_shared                     -> <repo>/commands/_shared
   ~/.claude/commands/adams-review.md             -> <repo>/commands/adams-review.md
   ~/.claude/commands/adams-review-add.md         -> <repo>/commands/adams-review-add.md
   ~/.claude/commands/adams-review-fix.md         -> <repo>/commands/adams-review-fix.md
   ~/.claude/commands/adams-review-walkthrough.md -> <repo>/commands/adams-review-walkthrough.md
   ~/.claude/commands/adams-review-promote.md     -> <repo>/commands/adams-review-promote.md
   ```

   The `_shared/` symlink propagates every helper, fragment, and schema automatically — only new top-level command files need their own symlink.

2. **Substitutes the tools-path prefix** in four command files' `allowed-tools:` YAML. Claude Code's permission model requires absolute paths in `allowed-tools` grants (no `$HOME`/`~` expansion), and the committed form is the maintainer's `/Users/adammiller/...`. The install script rewrites it to your `$HOME` so grants resolve on your machine.

   If you are not the maintainer, this leaves the four command files (`commands/adams-review*.md`) showing as modified in `git status`. That is expected and reversible. **To submit a PR, run `bash scripts/uninstall.sh` first** to revert the substitution; make your edits; then reinstall.

#### Verify manually

```bash
readlink ~/.claude/commands/_shared                     # should print <repo>/commands/_shared
readlink ~/.claude/commands/adams-review.md             # should print <repo>/commands/adams-review.md
uv --version                                            # 0.7+
```

<details>
<summary>Manual setup (if the script doesn't fit your environment)</summary>

```bash
# 1. Rewrite /Users/adammiller/ → $HOME/ in the four command files (portable sed).
for f in commands/adams-review*.md; do
  sed "s|/Users/adammiller/|$HOME/|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done

# 2. Symlinks (repeat for each top-level command).
mkdir -p ~/.claude/commands
ln -sfn "$PWD/commands/_shared"                         ~/.claude/commands/_shared
ln -sfn "$PWD/commands/adams-review.md"                 ~/.claude/commands/adams-review.md
ln -sfn "$PWD/commands/adams-review-add.md"             ~/.claude/commands/adams-review-add.md
ln -sfn "$PWD/commands/adams-review-walkthrough.md"     ~/.claude/commands/adams-review-walkthrough.md
ln -sfn "$PWD/commands/adams-review-fix.md"             ~/.claude/commands/adams-review-fix.md
ln -sfn "$PWD/commands/adams-review-promote.md"         ~/.claude/commands/adams-review-promote.md
```

</details>

No separate Python dep install. First invocation of any `*.py` helper triggers `uv` to resolve `jsonschema` (or any other declared dep) and cache it. Subsequent runs are fast.

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
│   └── archive/                      ← frozen historical references (not maintained)
│       ├── README.md                 ← frozen-as-of banner
│       ├── DESIGN.md                 ← original normative design (rev 8)
│       └── BUILD.md                  ← build journal (Stages 1–3 + hardening + walkthrough)
├── plans/                            ← per-stage plans
├── test/                             ← smoke harness + fixtures (Stage 1)
└── commands/
    ├── adams-review.md                ← top-level /adams-review slash command
    ├── adams-review-add.md            ← top-level /adams-review-add slash command
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

`/adams-review`, `/adams-review-add`, `/adams-review-walkthrough`, `/adams-review-fix`, and `/adams-review-promote` are all built and in use. Stages 1, 2, 2.5, 2.6, 2.7, 2.8, and 3 closed between 2026-04-17 and 2026-04-18 (see `docs/archive/BUILD.md` for the full history); walkthrough closed on branch `walkthrough-mode` in April 2026; `/adams-review-add` was added on branch `review-add` (plan: `plans/review-add.md`). The only unexecuted scope from the original roadmap is Stage 4 (fragment shrink — `plans/stage-4-fragment-shrink.md`), still pending plan approval.
