# Parallel Contract

This workflow treats parallelism as load-bearing behavior.

## Concurrency Window

Launch all independent work in parallel whenever Codex accepts the requested
fan-out. Some users configure a lower concurrent-agent limit. If Codex rejects
a launch because that limit has been reached, tell the user they can raise
`[agents].max_threads` in their Codex config, then keep the phase moving with a
bounded rolling window at the accepted concurrency.

Use this bounded fallback when a limit is encountered:

1. Start as many eligible children as Codex accepts.
2. Wait for any active child to finish.
3. Record its result, remove it from the active set, and start the next queued child.
4. Continue until the queue and active set are both empty.

Do not silently switch to serial execution after a limit error. Keep the
largest accepted parallel window open until the phase is complete.

## Detection

Launch every applicable detection lens as a read-only `explorer` sub-agent in
one fan-out. If the user's Codex agent limit blocks the full fan-out, use the
bounded rolling-window fallback above. Do not serialize the lenses one-by-one.

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
in parallel, with the bounded rolling-window fallback if Codex enforces a
concurrency limit.

Light-lane validation is balanced chunks of at most 25 findings, dispatched
in parallel, with the bounded rolling-window fallback if needed. Never create a
single unbounded light validator.

Wave 2 related-candidate validation, when present, uses the same parallel
dispatch and bounded fallback.

## Fix

Run `scripts/group-fixes.py` before spawning fix workers. Queue one `worker`
per fix group with explicit file ownership. If Codex enforces the user's
configured concurrency limit, use the bounded rolling-window fallback. Tell
every worker it is not alone in the codebase, must not revert other workers'
edits, must not run git operations, and must list changed files in its final
response.

Workers own disjoint groups. The parent integrates results in deterministic group order, rejects deletes and renames, then runs one post-fix review.

## Join Discipline

No finding IDs before all detection sources join.

No mid-fan-out artifact writes except intentional lifecycle state transitions such as `open -> attempted`.

Record elapsed time for every fan-out. When the full fan-out is accepted, a
healthy phase should behave like `max(child_duration)`. When a configured
agent limit forces the bounded fallback, expect rolling-window elapsed time,
not serialized `sum(child_duration)`.
