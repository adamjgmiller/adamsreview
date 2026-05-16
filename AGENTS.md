# AGENTS.md — adamsreview development guide

This repo now targets Codex plugins. The installable app lives under
`plugins/adamsreview/` and exposes the `$adamsreview` skill.

## Layout

- `plugins/adamsreview/.codex-plugin/plugin.json` — Codex plugin manifest.
- `plugins/adamsreview/skills/adamsreview/SKILL.md` — skill entry point.
- `plugins/adamsreview/skills/adamsreview/references/` — workflow references and lens prompts.
- `plugins/adamsreview/skills/adamsreview/scripts/` — deterministic helpers and `schema-v1.json`.
- `test/smoke.sh` — structural and helper smoke tests.

## Working Rules

- Preserve schema v1 unless a migration is explicitly planned.
- Keep `~/.adams-reviews` as the default review-state root.
- Treat parallelism as load-bearing: detection lenses, validation batches, and fix groups should fan out in parallel. If Codex reports the user's configured concurrent-agent limit, keep work moving with the bounded rolling-window fallback documented in the skill, and tell the user they can raise `[agents].max_threads` in their Codex config.
- PR bot-comment scraping is default in PR mode and fail-open on GitHub/auth/rate-limit failures.
- Keep helper scripts Bash 3.2 portable where practical.
- Use `uv` inline-script shebangs for Python helpers with dependencies.

## Testing

Run:

```bash
test/smoke.sh
```

The smoke test intentionally focuses on Codex plugin shape, helper behavior,
PR scrape fixtures, instruction-file discovery, and the parallelization
contract.
