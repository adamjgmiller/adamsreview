# commands/_shared

This directory is consumed by the `/adams-review` and `/adams-review-fix` slash commands via the symlink `~/.claude/commands/_shared → ~/Projects/adams-review/commands/_shared`.

## Layout

- `schema-v1.json` — JSON Schema for `artifact.json`. See `docs/DESIGN.md` §6.
- `tools/` — helper scripts invoked by the command orchestrator and (in a read-only subset) by sub-agents.
- Phase fragment files (`00-preflight.md` … `10-post-fix-and-commit.md`) and lens reference files (`lens-ux-reference.md`, `lens-security-reference.md`).

## Helper scripts (`tools/`)

See `docs/DESIGN.md` §8 for the full scripts contract and §21 for per-helper algorithmic sketches.

| Script | Language | Purpose |
|---|---|---|
| `_common.py` | Python | Shared helpers: schema-validate, atomic write, error-as-prompt, path resolution |
| `artifact-patch.py` | Python | Finding-level mutations, state-transition whitelist, append-only guards, batched apply-* modes |
| `artifact-render.py` | Python | `artifact.json` → `artifact.md` (§7) |
| `artifact-validate.sh` | Bash | Thin wrapper around the Python validator |
| `artifact-read.sh` | Bash | `jq` wrapper: `--filter`, `--finding-id`, `--summary` |
| `artifact-publish.sh` | Bash | PR comment post/patch; local-mode no-op |
| `assign-finding-ids.sh` | Bash | Detection-pool ID assignment (§13.12) |
| `claude-md-paths.sh` | Bash | Walk-up `CLAUDE.md` finder |
| `comment-freshness.sh` | Bash | PR-comment code-locality filter (§13.13 / §21.10) |
| `external-scrape.sh` | Bash | Phase 1.5 PR-comment fetch + bot filter (§21.8) |
| `group-fixes.py` | Python | Phase 8 fix-group union-find (§21.5) |
| `log-phase.sh` | Bash | `trace.md` + `phases.jsonl` appender |
| `log-tokens.sh` | Bash | `tokens.jsonl` appender |
| `origin-crosscheck.sh` | Bash | Blame-based origin classifier (§13.11 / §21.9) |
| `repo-slug.sh` | Bash | Canonical `<repo-slug>` derivation (§9.2) |
| `staleness.sh` | Bash | `git diff` intersection classifier (§21.4) |

## Conventions

- **Error-as-prompt** (DESIGN §8.6): non-zero exits emit specific, actionable stderr. No stack traces on expected errors.
- **Atomic writes** (DESIGN §24.4): writers go tmp-file → `rename` so the on-disk artifact is never in an invalid state.
- **Shebang**: Python helpers use `#!/usr/bin/env -S uv run --script` with a PEP 723 inline dep spec. Bash helpers use `#!/usr/bin/env bash` and `set -euo pipefail`.
- **Absolute paths**: scripts receive absolute paths as CLI args. No `cd` inside scripts; no assumptions about `$PWD`.
