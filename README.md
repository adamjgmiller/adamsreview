# adamsreview

Six personal Claude Code slash commands packaged as a plugin (`adamsreview`) distributable via `/plugin marketplace add`:

- **`/adamsreview:review`** — multi-lens code review of a branch or PR (phases 0–6, with Phase 5.5 generating `auto_fix_hint` recommendations for downstream batch-accept). Claude sub-agent lenses + Opus deep validators.
- **`/adamsreview:codex-review`** — Codex-driven counterpart to `:review`. Phase 1 detection runs 7 parallel Codex jobs (L1–L7) feeding one Sonnet normalizer; Phase 4a deep validation runs one Codex per finding + per-finding Sonnet shape-fixer; Phase 4b light is chunked-batch Codex + per-chunk Sonnet shape-fixer; Phase 5 is one Codex pass + one Sonnet shape-fixer. Same artifact schema as `:review` (`reviewer_sources: ["internal-codex"]`) so `:fix`, `:add`, `:walkthrough`, `:promote` work without changes. Effort tunable via `--effort <low|medium|high|xhigh>` (default `high`). No `--ensemble` (purpose-built for Codex purity).
- **`/adamsreview:add`** — inject externally-sourced findings (Claude Code cloud `/ultrareview` paste, an Opus once-over, a teammate's note) into the most recent review's existing artifact. Free-form paste mode dispatches a Sonnet normalizer; structured `--file/--line/--claim` mode skips it. One Sonnet dedup pass against existing findings; Phase 4 validation lane-aware (no Wave 2); re-renders + re-publishes to the existing PR comment.
- **`/adamsreview:walkthrough`** — interactive driver for findings `/adamsreview:fix` would skip; Step 4.5 batch-accepts all `auto_fix_hint` recommendations in one confirm, then per-finding briefing + options + recommendation for the rest, batched re-render/re-publish, decisions-log PR comment (see DESIGN §28).
- **`/adamsreview:fix`** — automated fix loop for auto-fixable findings surfaced by `/adamsreview:review` or `/adamsreview:codex-review` (phases 7, 7.5, 8, 9). Phase 7.5 surfaces light-lane / manual / report findings carrying `auto_fix_hint` for one-confirm batch-accept before Phase 8 dispatch.
- **`/adamsreview:promote`** — human override that promotes a single finding to auto-fixable (bypasses the Phase 8 impact_type lane filter and score threshold; see DESIGN §27).

Command files live at bare-stem paths under `commands/` (`review.md`, `codex-review.md`, `add.md`, `walkthrough.md`, `fix.md`, `promote.md`); shared phase fragments and the prompt references live under `fragments/`; helper scripts and the artifact schema live under `bin/`. The plugin runtime auto-adds `bin/` to `$PATH` on load — no symlinks, no install script.

## Recommended flow

Not required — each command is independent — but they work best in this order on a non-trivial PR:

1. **Review.** `/adamsreview:review` — or `/adamsreview:review --ensemble` if you have the Codex CLI installed and want to pool a Codex pass plus a PR bot-comment scrape on top of the internal Claude lenses (higher token cost). **Or** `/adamsreview:codex-review [--effort <level>]` for a Codex-driven peer review (drop-in for everything downstream; effort tunable; no `--ensemble`).
2. **Add.** *(optional)* `/adamsreview:add <paste...>` — if you ran a parallel review (cloud `/ultrareview`, Opus once-over, manual scan, etc.) that surfaced bugs the original review missed, paste the result here. The findings are validated by Phase 4 and land in the same artifact, deduped against what's already there. Auto-eligible additions feed step 4; non-eligible ones surface in step 3.
3. **Walkthrough.** *(optional)* `/adamsreview:walkthrough [threshold]` — step through findings the fix command would skip (deep-manual, deep-report, and the entire light lane including light `confirmed_mechanical`), restricted to those scoring at or above `$threshold` (default 60) so low-signal items don't pad the session. Step 4.5 batch-accepts all findings carrying an `auto_fix_hint` in one confirm (the fast path); the rest get per-finding briefing + options + recommendation. Promote the ones you want auto-fixed with tailored fix-hints, skip the rest. Posts a decisions log to the PR for audit. Pass a lower threshold (e.g. `/adamsreview:walkthrough 30`) and pick the **Full** tier at the preflight prompt to audit Phase-3-demoted `below_gate` findings too.
4. **Fix.** `/adamsreview:fix` — applies every auto-eligible finding (including whatever was added in step 2 and promoted in step 3). Phase 7.5 surfaces any remaining `auto_fix_hint` recommendations (light-lane / manual / report findings) for one-confirm batch-accept before Phase 8 dispatch. Default: one combined commit for all surviving fixes; pass `--granular-commits` for one commit per fix group. Per-group Phase-9 outcome lands in the commit message either way.

Steps 2 and 3 are optional. You can go straight from review to fix if you only care about the auto-eligible findings the original review surfaced.

Steps 2–4 can land days or weeks after step 1 — the review artifact persists under `~/.adams-reviews/<slug>/<branch>/`.

`/adamsreview:promote <id>` remains useful for one-off manual promotions outside the walkthrough flow (e.g. promoting a `disproven` finding with `--force`, or conceptually looping over a set of IDs — `F003`, `F037`, `F039` — with `--defer-publish` on each so only the final invocation re-publishes to the PR).

## Documents

- **`CLAUDE.md`** — operational guide for Claude Code sessions working in this repo. Self-contained for routine work; read first on a fresh session.
- **`docs/archive/`** — frozen design + build docs (2026-04-19 onward). `DESIGN.md` (rev 8) is the original normative spec; `BUILD.md` is the stage-by-stage journal. Not maintained; consult only for historical rationale behind a specific decision. See `docs/archive/README.md`.
- **`plans/`** — per-stage plan files. All original-roadmap stages are closed (1–3 + 2.5/2.6/2.7/2.8, plugin-conversion, post-plugin-improvements, stage-4-fragment-shrink). Active follow-ups now live in GitHub issues; the historical backlog is at `plans/old-backlog.md` (frozen 2026-05-04).

## Dependencies

### Runtime

| Tool | Version | Used by | Notes |
|---|---|---|---|
| `uv` | 0.7+ | `artifact-patch.py`, `artifact-render.py` | `brew install uv`. Scripts use a PEP 723 inline-script shebang (`#!/usr/bin/env -S uv run --quiet --script`) so `uv` fetches and caches `jsonschema` on first run — no venv, no global pip install |
| `python3` | 3.10+ | invoked by `uv` | `uv` will install a matching Python if needed |
| `bash` | 4+ | all `*.sh` helpers | macOS default `/bin/bash` is 3.2 — scripts use `#!/usr/bin/env bash` and rely on `brew install bash` or the user's newer default. On Windows, Git for Windows ships bash 5+ via Git Bash and Claude Code auto-routes through it |
| `jq` | 1.6+ | `artifact-read.sh`, log helpers | `brew install jq` |
| `gh` | 2.x | `artifact-publish.sh`, `external-scrape.sh` | `brew install gh`, `gh auth login` |
| `git` | 2.x | everywhere | standard |

## Installation

### macOS / Linux

1. Install deps: `brew install uv jq gh bash git` (macOS) or the distro equivalent. Bash 4+ is required — macOS's default `/bin/bash` is 3.2.
2. In a Claude Code session: `/plugin marketplace add adamjgmiller/adamsreview`
3. In the same session: `/plugin install adamsreview@adamsreview`

### Windows (native)

1. Install [Git for Windows](https://git-scm.com/downloads/win) — provides Git Bash (bash 5+) and `git`, which Claude Code uses internally. Claude Code auto-routes `#!/usr/bin/env bash` helpers through Git Bash; set `CLAUDE_CODE_GIT_BASH_PATH` if Git Bash lives in a non-default location (see *Troubleshooting*).
2. Install [uv](https://docs.astral.sh/uv/), [jq](https://jqlang.github.io/jq/download/), and the [GitHub CLI](https://cli.github.com/).
3. In a Claude Code session: `/plugin marketplace add adamjgmiller/adamsreview` and `/plugin install adamsreview@adamsreview`.

### Install from a local checkout

If you've cloned this repo and prefer running from source — or you want to pin to a specific commit — two paths work without the GitHub marketplace round-trip:

- **Persistent install from a local path.** In a Claude Code session, run `/plugin marketplace add /path/to/adamsreview` then `/plugin install adamsreview@adamsreview`. Same end state as the GitHub marketplace flow above — the plugin is registered under `~/.claude/` and survives restarts. Use `.` in place of the absolute path if your cwd is already the clone.
- **One-shot via `--plugin-dir`.** `claude --plugin-dir /path/to/adamsreview` launches Claude Code with the clone loaded as a plugin for that session only. Nothing is written to `~/.claude/`; re-launch without the flag and the plugin is gone. Handy for trying the plugin without any persistent state, or for running a specific checkout side-by-side with an installed version.

Both paths still require the runtime deps listed above (`uv`, `jq`, `gh`, `bash` 4+, `git`).

### Commands (post-install)

All invocations are plugin-namespaced:

- `/adamsreview:review [--ensemble] [--full]`
- `/adamsreview:codex-review [--effort <low|medium|high|xhigh>] [--full]`
- `/adamsreview:add [<paste...>] [--file <path> --line <N> --claim "..."]`
- `/adamsreview:walkthrough [threshold]`
- `/adamsreview:fix [threshold]`
- `/adamsreview:promote <finding_id> [--reason "..."] [--fix-hint "..."]`

No separate Python dep install. First invocation of any `*.py` helper triggers `uv` to resolve `jsonschema` (or any other declared dep) and cache it — this can take a few seconds on a fresh machine (see *Troubleshooting*). Subsequent runs are fast.

### Plugin-author iteration

If you're hacking on the plugin itself (not just using it), `scripts/dev-run.sh` launches Claude Code with the working tree loaded as a plugin via `claude --plugin-dir "$(pwd)"` — no marketplace install needed. For install-path simulation from a working tree, run `/plugin marketplace add .` inside a Claude Code session.

### Review state location

`/adamsreview:review` writes per-run state (artifact, trace, phase logs, token logs) under `~/.adams-reviews/<repo-slug>/<branch>/<review_id>/`. Override with `export ADAMS_REVIEW_REVIEWS_ROOT=/some/other/path` if you want state elsewhere.

**Why not `~/.claude/reviews/`?** Claude Code hardcodes a sensitive-file permission prompt for writes to `~/.claude/...` that survives even `bypassPermissions` mode, and `~/.claude/reviews` is not on the short list of exempt subdirs (`.claude/commands`, `.claude/agents`, `.claude/skills`). Keeping review state outside `~/.claude/` avoids dozens of permission prompts per run.

**Migrating from pre-Stage-2.5 state.** If you have reviews under `~/.claude/reviews/`, either:

```bash
# Option A: move state to the new canonical root (recommended).
mv ~/.claude/reviews ~/.adams-reviews

# Option B: keep state at the old location via the env var (accepts the prompts).
export ADAMS_REVIEW_REVIEWS_ROOT=~/.claude/reviews
```

### Token counts: what they measure

The rendered report can surface two numbers:

- **Sub-agent tokens** — rolled up from the per-review `tokens.jsonl` log. Counts every dispatched sub-agent (lenses, validators, fix agents, post-fix reviewer, etc.) for this specific review. Precise. Always shown.
- **Orchestrator tokens** — rolled up from the Claude Code session transcripts under `~/.claude/projects/<cwd-slug>/`, filtered to assistant turns with `timestamp >= review_started_at`. Captures the main-session spend that `subagent_tokens` deliberately excludes. **Opt-in** — see below.

When both are populated they're complementary (no overlap), and together estimate total cost.

#### Orchestrator tokens are opt-in

macOS Sequoia and Tahoe show an "*kitty (or your terminal) would like to access data from other apps*" prompt the first time a shell helper reads files marked with the `com.apple.provenance` extended attribute. Every Claude Code transcript carries one, and `bin/orchestrator-tokens.sh` reads them — so the helper would trigger the prompt on the first lifecycle command of every review and (because the TCC cache for this gate is partial) repeatedly thereafter. To avoid pestering users, the helper defaults to skip.

To enable, do **either**:

- **Recommended** — grant your terminal app **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access → `+` your terminal). One toggle, permanent, silences this prompt class for everything launched from your terminal. Then `export ADAMS_REVIEW_TALLY_ORCHESTRATOR=1` in your shell rc (`~/.zshrc`, `~/.bashrc`, etc.) so the helper actually runs.
- **Just opt in without FDA** — `export ADAMS_REVIEW_TALLY_ORCHESTRATOR=1` and accept the macOS prompts when they fire. Each grant survives until the next OS update or terminal-app update; choose this if you want narrower permissions at the cost of clicking *Allow* periodically.

When opted out (the default), the helper exits 0 with one `orchestrator-tally: skipped` line and leaves the artifact's `orchestrator_tokens` field absent. The PR comment shows only **Sub-agent tokens** — still the precise per-review counter and the primary cost signal. Sub-agent tokens log under `~/.adams-reviews/`, which carries no provenance xattr, so that path triggers no prompts.

**Stale-data behavior.** If you opt in for the initial review and then opt out before running `/adamsreview:fix`, the helper preserves the previously-written `orchestrator_tokens` value rather than wiping it. The rendered line shows the last-measured value, not a freshly-skipped zero — meaning it can under-report subsequent fix-time activity. Re-opt-in on the next lifecycle command refreshes. The reverse direction (opt out for review, opt in for fix) has no staleness: the fix-time tally's `--since review_started_at` window covers the full review→fix arc, so the first opt-in write captures everything.

#### Orchestrator tokens can over-count (when opted in)

The transcript scan is a pure time-window filter, so any Claude Code turn in the same working directory between `review_started_at` and the last tally gets counted — even if it's unrelated work. In practice that means:

- **Clean:** review → fix back-to-back, or review → new review on updated codebase (each review's `review_started_at` excludes the prior one's turns).
- **Over-counts:** review → unrelated work in the same cwd → fix (the unrelated turns land in the fix run's re-tally).
- **Mitigation:** run the lifecycle commands close together, or do unrelated work in a different worktree (different cwd → different transcript directory → not scanned).

Sub-agent tokens don't have this problem — their log is per-review. If you need a precise total, trust sub-agent tokens and treat orchestrator tokens as a rough ceiling. See `bin/orchestrator-tokens.sh` header for the full list of caveats.

### Why `uv` instead of plain pip

PEP 668 (Python 3.12+ with Homebrew) marks system and user site-packages as externally managed and refuses direct `pip install`. The original plan assumed plain pip; `uv`'s inline-script dep spec is the cleanest workaround: each Python helper is self-contained, runs without activation ceremony, and its dep list lives next to the code that imports it. Tradeoff: requires `uv` on the machine running the scripts.

## Layout

```
adamsreview/                           ← this repo (plugin root)
├── CLAUDE.md                          ← operational guide (read first)
├── README.md                          ← this file
├── .claude-plugin/
│   ├── plugin.json                    ← plugin manifest (name: adamsreview)
│   └── marketplace.json               ← single-plugin marketplace
├── .gitattributes                     ← LF enforcement
├── docs/
│   └── archive/                       ← frozen historical references (not maintained)
│       ├── README.md                  ← frozen-as-of banner
│       ├── DESIGN.md                  ← original normative design (rev 8)
│       └── BUILD.md                   ← build journal (Stages 1–3 + hardening + walkthrough)
├── plans/                             ← per-stage plans (incl. plugin-conversion)
├── test/                              ← smoke harness + fixtures
├── commands/                          ← bare-stem command files (plugin namespacing)
│   ├── review.md                      ← /adamsreview:review
│   ├── add.md                         ← /adamsreview:add
│   ├── walkthrough.md                 ← /adamsreview:walkthrough
│   ├── fix.md                         ← /adamsreview:fix
│   └── promote.md                     ← /adamsreview:promote
├── fragments/                         ← shared phase fragments + prompt references
│   ├── promote-core.md                ← shared precondition + patch (promote + walkthrough)
│   ├── 00-preflight.md … 10-post-fix-and-commit.md
│   └── lens-*-reference.md
├── bin/                               ← helper scripts (plugin runtime auto-adds to $PATH)
│   ├── include                        ← `!include <fragment>.md` wrapper
│   ├── schema-v1.json                 ← JSON Schema for artifact.json
│   ├── _common.py                     ← shared Python helpers
│   ├── artifact-patch.py              ← machine-state writer
│   ├── artifact-render.py             ← JSON → Markdown
│   ├── artifact-validate.sh           ← schema check (bash wrapper)
│   ├── artifact-read.sh               ← jq wrapper
│   ├── artifact-publish.sh            ← PR comment post/patch
│   ├── claude-md-paths.sh             ← walk-up CLAUDE.md finder
│   ├── staleness.sh                   ← git diff intersection
│   ├── log-phase.sh                   ← trace.md + phases.jsonl appender
│   ├── log-tokens.sh                  ← tokens.jsonl appender
│   └── (other helpers: group-fixes.py, repo-slug.sh, comment-freshness.sh,
│      origin-crosscheck.sh, prior-fix-diff.sh, external-scrape.sh,
│      assign-finding-ids.sh, line-range-check.sh, tally-subagent-tokens.sh,
│      orchestrator-tokens.sh)
├── hooks/
│   ├── hooks.json                     ← SessionStart registration
│   └── dep-check.sh                   ← soft dep-missing warning at session start
└── scripts/
    └── dev-run.sh                     ← `claude --plugin-dir` wrapper (plugin-author iteration)
```

No symlinks, no install script. The plugin runtime discovers `commands/`, `fragments/`, `bin/`, and `hooks/` by convention once the plugin is installed via `/plugin install adamsreview@adamsreview`.

## Troubleshooting

### First invocation is slow

The Python helpers (`artifact-patch.py`, `artifact-render.py`) use a PEP 723 inline-script shebang (`#!/usr/bin/env -S uv run --quiet --script`). On a fresh machine, the first run pauses for a few seconds while `uv` resolves a matching Python interpreter and fetches the `jsonschema` dep into its cache. Subsequent runs hit the cache and are effectively instant. This is a one-time cost per machine, not per review.

### `--ensemble` mode requirements

`/adamsreview:review --ensemble` additionally requires the `codex` Claude Code plugin (the local Codex CLI is invoked through the plugin's `codex-companion.mjs`, not as a standalone CLI on `$PATH`). Without the plugin installed, the readiness gate prompts you to either continue without Codex (in PR mode that means PR-comment scraping only; in local mode it means internal lenses only — Phase 1.5 has no work to do) or stop and run `/codex:setup` first. The default (non-ensemble) mode has no such requirement.

### Windows: Git Bash not found

Claude Code auto-discovers Git Bash on Windows and routes `#!/usr/bin/env bash` helpers through it. If the auto-discovery fails (non-default Git Bash install path, portable install, etc.), set `CLAUDE_CODE_GIT_BASH_PATH` to the absolute path of `bash.exe` before launching Claude Code — for example:

```
set CLAUDE_CODE_GIT_BASH_PATH=C:\Program Files\Git\bin\bash.exe
```

or the `$env:CLAUDE_CODE_GIT_BASH_PATH = ...` equivalent in PowerShell.

## Status

`/adamsreview:review`, `/adamsreview:add`, `/adamsreview:walkthrough`, `/adamsreview:fix`, and `/adamsreview:promote` are all built and in use. Stages 1, 2, 2.5, 2.6, 2.7, 2.8, and 3 closed between 2026-04-17 and 2026-04-18 (see `docs/archive/BUILD.md` for the full history); walkthrough merged 2026-04-19 from branch `walkthrough-mode`; `/adamsreview:add` was added 2026-04-20 on branch `review-add` (plan: `plans/review-add.md`); plugin conversion (repackaging as a Claude Code plugin, `/adams-review-<stem>` → `/adamsreview:<stem>` namespacing) landed on branch `plugin-conversion` (plan: `plans/plugin-conversion-execution.md`); Stage 4 (fragment shrink — manifest-style command bodies, helper extractions, prose compression) closed 2026-04-23 on branch `stage-4-fragment-shrink` (plan: `plans/stage-4-fragment-shrink.md`). All original-roadmap scope is now executed; forward-looking work lives in `plans/backlog.md`.
