# FU-1 + P3 execution journal

**Branch:** `FU1_P3` (off `d39414a` on `main`, Stage 4 close-out).
**Baseline:** 249 smoke assertions (confirmed 3x PASS; one intermittent VR-1 flake observed on main).
**Plan:** bundled FU-1 (transcluded-fragment `allowed-tools` gap) + P3 (L5-ux hunk-header line-range hallucination) into a single PR. Approved 2026-04-23.

## Cursor

Current: all stages complete; awaiting user approval to push + open PR.

## Stage 1 — FU-1: allowed-tools gap (commands/review.md) ✅

- 2026-04-23 start
- Builder (general-purpose): extended parameterized PF-INT-5 loop (Shape A); grants inserted adjacent to `Bash(line-range-check.sh:*)`; no unrelated reformatting.
- Spot-check: blast-radius grep confirmed `commands/fix.md` already has both grants; `commands/add.md` already has `assign-finding-ids.sh` (doesn't invoke origin-crosscheck.sh); ensemble-adapter reference is a comment.
- Smoke: 249 → 249 (parameterized assertion, count unchanged but coverage broadened from 3 → 5 helpers).
- Commit: **`36b2481`** — *"FU-1: grant assign-finding-ids.sh + origin-crosscheck.sh in commands/review.md"* (+5/−4 LOC, 2 files).
- 2026-04-23 stage complete.

## Stage 2 — P3: L5-ux hunk-header confusion fix (fragments/01-detection.md §1.2.1) ✅

- 2026-04-23 start
- Builder (general-purpose) landed the invariant in §1.2.1 shared-invariants blockquote (fragments/01-detection.md:89+). Inside-blockquote placement is load-bearing — the section's wiring comment explicitly says only blockquote content is dispatched to lens sub-agents.
- Three normative clauses preserved: (a) file-absolute + counted-from-1, (b) in-bounds (`line_range[1] <= file length`), (c) no verbatim `@@ -a,b +c,d @@` copying; bonus positive guidance for correct line-citation.
- Smoke: added LR-6 in the LR-* cluster (Shape A parameterized grep over 4 distinctive phrases). Pass-label tags P3, GH #2.
- Smoke 249 → 250, clean PASS on orchestrator re-run.
- Commit: **`3a8f64e`** — *"P3: add file-absolute line_range invariant to §1.2.1 (GH #2)"* (+32 LOC, 2 files).
- 2026-04-23 stage complete.

## Stage 3 — Once-over + backlog close-out ✅

- 2026-04-23 start
- Reviewer (general-purpose w/ review prompt; `quick-review` unavailable in this environment) inspected `d39414a..HEAD`.
- **Bottom line:** ship with the already-planned backlog close-out — no blocking or should-fix issues found.
- Key confirmations from review:
  - FU-1 blast-radius clean: `commands/fix.md` already grants both helpers; `add.md` grants `assign-finding-ids.sh` only (doesn't invoke the other); `walkthrough.md` / `promote.md` don't invoke either.
  - P3 invariant placement correct: lands inside §1.2.1 shared blockquote (all `> `-prefixed, contiguous, no duplication).
  - Ensemble-adapter normalizer uses its own prompt and doesn't need the invariant (external-CLI output, not hunk-header-confusion failure mode); `line-range-check.sh` still catches overshoots at the join step.
  - `bin/schema-v1.json` doesn't constrain file-absolute `line_range` — correctly framed as runtime-only invariant, no contradiction.
  - LR-6 smoke assertion has adequate phrase coverage, no false-positive/-failure risk to speak of.
- Backlog close-out applied: §3 FU-1 and §3 P3 both marked `*(CLOSED 2026-04-23)*` with commit SHAs and Resolution notes; P3's Resolution records classification (a) — diff-hunk-header confusion — and the shared-blockquote placement rationale.
- 2026-04-23 stage complete.

## Final state

| | |
|---|---|
| Branch | `FU1_P3` (off `d39414a` on `main`) |
| Commits | `36b2481` (FU-1) · `3a8f64e` (P3) · close-out commit pending |
| Smoke | `249 → 250` (249 baseline preserved by Stage 1's parameterized extension; Stage 2 adds LR-6) |
| Files touched | `commands/review.md` · `fragments/01-detection.md` · `test/smoke.sh` · `plans/backlog.md` · `plans/fu1-p3-execution.md` |
| Net LOC | +46 / −4 |
| Push / PR | **not yet** — awaiting explicit user approval |
