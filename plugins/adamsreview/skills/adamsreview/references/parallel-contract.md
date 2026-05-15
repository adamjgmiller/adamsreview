# Parallel Contract

This workflow treats parallelism as load-bearing behavior.

## Detection

Launch every applicable detection lens as a parallel read-only `explorer` sub-agent in one batch. Do not run one lens, wait, then run the next.

Applicable lenses:

- L1 diff-local
- L2 structural / blast-radius, skip only for trivial reviews
- L3 project-instruction compliance
- L4 comment compliance
- L5 UX, skip when the diff is not user-facing
- L6 lightweight security, skip only for trivial reviews
- L7 holistic, run by default for non-trivial Codex reviews

The parent may run PR bot-comment scraping while lens agents are active. Join all lens outputs and PR-scrape candidates before dedup, line-range filtering, ID assignment, or artifact writes.

## Validation

Deep-lane validation is one independent validator per finding, dispatched together.

Light-lane validation is balanced chunks of at most 25 findings, dispatched together. Never create a single unbounded light validator.

Wave 2 related-candidate validation, when present, is another parallel batch.

## Fix

Run `scripts/group-fixes.py` before spawning fix workers. Spawn one `worker` per fix group with explicit file ownership. Tell every worker it is not alone in the codebase, must not revert other workers' edits, must not run git operations, and must list changed files in its final response.

Workers own disjoint groups. The parent integrates results in deterministic group order, rejects deletes and renames, then runs one post-fix review.

## Join Discipline

No finding IDs before all detection sources join.

No mid-fan-out artifact writes except intentional lifecycle state transitions such as `open -> attempted`.

Record elapsed time for every fan-out. A healthy fan-out should behave like `max(child_duration)`, not `sum(child_duration)`.
