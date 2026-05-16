# Pipeline

## `$adamsreview review`

1. Preflight: resolve repo, PR, comparison ref, touched files, instruction files, and artifact paths.
2. Detection fan-out: launch applicable lenses in parallel, using a bounded rolling window only if Codex reports the user's configured concurrent-agent limit.
3. PR enrichment: in PR mode, scrape automated GitHub reviewer comments while detection runs; fail open.
4. Join: combine lens and PR candidates, line-range check, assign IDs, and write findings in one batched mutation.
5. Dedup and score.
6. Validation fan-out: deep findings one-per-agent, light findings in chunks of at most 25, with the same bounded fallback if a configured limit is reached.
7. Cross-cutting review and auto-fix-hint generation.
8. Finalize: validate, render, publish, and update audit logs.

## `$adamsreview fix`

1. Load latest artifact and abort on leftover `attempted` findings.
2. Compute eligibility and group fixes with `group-fixes.py`.
3. Transition eligible findings to `attempted`.
4. Launch one worker per fix group in parallel, using the bounded fallback if a configured limit is reached.
5. Integrate worker results in deterministic group order.
6. Run one post-fix review over the integrated diff.
7. Revert regression groups, commit survivors, update artifact outcomes, render, and publish.

## Lifecycle Modes

- `add` normalizes external/manual findings into the latest artifact.
- `walkthrough` triages skipped/manual findings and can batch-promote.
- `promote` records human override provenance for one finding.
