# State And Gates

`plugins/adamsreview/skills/adamsreview/scripts/schema-v1.json` is the source
of truth for artifact shape.

## States

- `open` — finding is available for review/fix lifecycle actions.
- `attempted` — fix mode has claimed the finding in the current run.
- `resolved` — post-fix review verified the fix.

Leftover `attempted` findings hard-abort a fresh fix run.

## Dispositions

The schema-v1 disposition enum is preserved:

- `below_gate`
- `pending_validation`
- `disproven`
- `uncertain`
- `confirmed_mechanical`
- `confirmed_manual`
- `confirmed_report`
- `pre_existing_report`
- `partial`
- `regression`
- `resolved`

## Fix Eligibility

By default, fix mode selects open findings with `confirmed_mechanical`,
`partial`, or `regression`, in correctness/security lanes, at or above the
chosen threshold.

Any non-null `human_confirmation` bypasses the lane and score gates.

## Instruction Paths

Schema v1 keeps the field name `claude_md_paths`; the Codex plugin fills it
with `AGENTS.md` paths first and legacy `CLAUDE.md` paths second.
