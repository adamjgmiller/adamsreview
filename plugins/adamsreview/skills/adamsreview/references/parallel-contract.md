# Parallel Contract

This workflow treats parallelism as load-bearing behavior.

## Concurrency Window

Never run more than 6 live Codex sub-agents or workers at once. This cap
applies to every fan-out phase: detection lenses, deep validators, light
validation chunks, related-candidate validation, auto-fix hint generation,
walkthrough briefers, and fix workers.

Use a rolling window:

1. Start up to 6 eligible children.
2. Wait for any active child to finish.
3. Record its result, remove it from the active set, and start the next queued child.
4. Continue until the queue and active set are both empty.

Do not launch child 7 until one of the first 6 has completed.

## Detection

Launch every applicable detection lens as a read-only `explorer` sub-agent in
one rolling-window fan-out capped at 6 live agents. Do not serialize the lenses
one-by-one, and do not exceed the 6-agent cap.

Applicable lenses:

- L1 diff-local
- L2 structural / blast-radius, skip only for trivial reviews
- L3 project-instruction compliance
- L4 comment compliance
- L5 UX, skip when the diff is not user-facing
- L6 lightweight security, skip only for trivial reviews
- L7 holistic, run by default for non-trivial Codex reviews

The parent may run PR bot-comment scraping while lens agents are active. Join
all lens outputs and PR-scrape candidates before dedup, line-range filtering,
ID assignment, or artifact writes.

## Validation

Deep-lane validation is one independent validator per finding, dispatched
through the same rolling 6-agent window.

Light-lane validation is balanced chunks of at most 25 findings, dispatched
through the rolling 6-agent window. Never create a single unbounded light
validator.

Wave 2 related-candidate validation, when present, uses the same rolling
6-agent window.

## Fix

Run `scripts/group-fixes.py` before spawning fix workers. Queue one `worker`
per fix group with explicit file ownership, but keep at most 6 workers live at
once. Tell every worker it is not alone in the codebase, must not revert other
workers' edits, must not run git operations, and must list changed files in its
final response.

Workers own disjoint groups. The parent integrates results in deterministic group order, rejects deletes and renames, then runs one post-fix review.

## Join Discipline

No finding IDs before all detection sources join.

No mid-fan-out artifact writes except intentional lifecycle state transitions such as `open -> attempted`.

Record elapsed time for every fan-out. For 6 or fewer children, a healthy
fan-out should behave like `max(child_duration)`. For more than 6 children,
expect rolling-window elapsed time, not serialized `sum(child_duration)`.
