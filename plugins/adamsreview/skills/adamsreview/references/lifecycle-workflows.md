# Lifecycle Workflows

## Add

Use `add` to inject external or manual findings into the latest review artifact. Accept free-form pasted review text or a structured `{file, line, claim}` input. Validate the existing artifact first.

Normalize candidates, optionally dedup against existing findings, assign continuing IDs with `scripts/assign-finding-ids.sh --start-from`, validate with the same lane rules as review, then render and publish once.

## Walkthrough

Use `walkthrough` to triage open findings that `fix` would skip at the chosen threshold. Present concise options in normal Codex conversation. Promotions should call the same artifact patch path as `promote` and defer render/publish until the walkthrough ends.

For findings with `auto_fix_hint`, reuse the hint instead of launching a new briefer.

## Promote

Use `promote` to set `human_confirmation` for one finding. Require a non-empty reason. Require explicit force when promoting a `disproven` finding.

After promotion, re-render and publish unless the caller is in a batched workflow such as walkthrough.
