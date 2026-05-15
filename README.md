# adamsreview

Parallel Codex code review as a Codex plugin. Adamsreview ships one primary
skill, `$adamsreview`, plus deterministic helper scripts for artifact state,
GitHub PR comment enrichment, rendering, publishing, grouping fixes, and
schema validation.

The v1 Codex port keeps the existing artifact schema and review state under
`~/.adams-reviews`, but replaces Claude slash commands with natural-language
skill modes.

## Layout

```
.agents/plugins/marketplace.json
plugins/adamsreview/
├── .codex-plugin/plugin.json
└── skills/adamsreview/
    ├── SKILL.md
    ├── agents/openai.yaml
    ├── references/
    │   ├── parallel-contract.md
    │   ├── review-workflow.md
    │   ├── fix-workflow.md
    │   ├── lifecycle-workflows.md
    │   └── lens-prompts/
    └── scripts/
        ├── schema-v1.json
        ├── artifact-*.py/sh
        ├── external-scrape.sh
        ├── comment-freshness.sh
        ├── group-fixes.py
        └── ...
```

The root marketplace file points Codex at the local plugin path
`./plugins/adamsreview`. The standalone entry is also mirrored at
`plugins/adamsreview/.codex-plugin/marketplace-entry.json` for copy/paste into
another marketplace checkout.

## Skill Modes

- `$adamsreview review` — run the Codex-native multi-lens review.
- `$adamsreview add` — add external or manual findings to the latest artifact.
- `$adamsreview walkthrough` — triage findings the fix pass would skip.
- `$adamsreview promote` — mark one finding as auto-fixable with human provenance.
- `$adamsreview fix` — apply eligible findings with parallel fix-group workers.

## Parallelism Contract

Parallelism is part of the design, not a convenience:

- Detection lenses run through a rolling window capped at 6 live agents.
- PR bot-comment scraping runs while detection is active when a GitHub PR exists.
- Deep validation runs one validator per finding, capped at 6 live agents.
- Light validation runs balanced chunks of at most 25 findings, capped at 6 live agents.
- Fix mode runs one worker per disjoint fix group, capped at 6 live workers.

See `plugins/adamsreview/skills/adamsreview/references/parallel-contract.md`.

## PR Bot-Comment Enrichment

In PR mode, review always attempts to scrape automated reviewer comments from
GitHub. `external-scrape.sh` reads issue comments, PR reviews, and review
comments; filters bot authors with allow/deny config; then
`comment-freshness.sh` drops stale code-local comments.

Failures are fail-open: auth, rate-limit, or network errors are logged to the
review trace, and the review continues without PR-comment enrichment.

Config lookup:

1. `.codex/review-config.json`
2. `.claude/review-config.json` legacy fallback
3. `$ADAMS_REVIEW_CONFIG_ROOT/review-config.json`
4. `~/.adams-reviews/review-config.json`

## Dependencies

- `bash`
- `git`
- `gh`
- `jq`
- `uv`
- `python3` via `uv`

## Test

```bash
test/smoke.sh
```
