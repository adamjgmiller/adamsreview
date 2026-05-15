# Helper Inventory

Helpers live under `plugins/adamsreview/skills/adamsreview/scripts/`.

Core helpers:

- `artifact-seed.sh` — build schema-v1 artifact seed JSON.
- `artifact-patch.py` — atomic artifact mutation and transition checks.
- `artifact-read.sh` — jq-backed artifact reader.
- `artifact-validate.sh` — schema validation wrapper.
- `artifact-render.py` — artifact JSON to Markdown report.
- `artifact-publish.sh` — GitHub PR comment publish/patch, local no-op.
- `instruction-paths.sh` — discover `AGENTS.md` and legacy `CLAUDE.md` files.
- `external-scrape.sh` — fetch automated GitHub reviewer comments.
- `comment-freshness.sh` — drop stale PR comments by code locality.
- `assign-finding-ids.sh` — deterministic ID assignment after detection join.
- `group-fixes.py` — disjoint fix-group planner.
- `log-phase.sh`, `log-tokens.sh`, `tally-subagent-tokens.sh` — audit logs.

Compatibility:

- `claude-md-paths.sh` remains as a wrapper around `instruction-paths.sh`
  because schema v1 still stores the path list in `claude_md_paths`.
- `orchestrator-tokens.sh` is a Codex-safe no-op until a stable Codex
  transcript contract exists.
