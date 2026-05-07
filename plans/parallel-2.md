---
branch: parallel-2
base: main (84def52)
started: 2026-05-07
---

## Goal

Harden every parallel-dispatch site in the adamsreview pipeline against
agents that read fan-out instructions as serial loops — root-cause fix
for an observed Phase 1 failure where lenses ran sequentially
(latency = `sum(...)` instead of `max(...)`).

## Trigger

A user-run `/adamsreview:review` serialized L1, L2, L3, then started L4
each as separate orchestrator turns instead of batching them into one
multi-Agent dispatch turn. The agent's own post-mortem flagged the
existing parallelism warning as "buried under a heading" — the
imperative "Dispatch spec:" leading each per-lens sub-section read as
a standalone action target.

## Approach

Insert a tight blockquote callout at every fan-out site that re-orders
the priority — "one turn for all X" leads, the per-X spec follows.
Positive instruction ("read first, dispatch all together") rather than
negative command ("don't act yet"), to avoid mis-scoping risks of
imperative halt words like STOP.

Decided against:
- Restructuring §1.3 to put "#### Dispatch turn" first and reference
  per-lens specs as parameters — bigger edit, same effect.
- All-caps banner words like STOP / HALT — verbs trigger actions, and
  Claude Code agents trained on halt signals could mis-scope to
  "abort the command."

## Sites updated

15 callouts across 6 fragments + version bump:

- `fragments/01-detection.md` — L1 full callout + L2–L7 short reminders.
- `fragments/01-codex-detection.md` — §1.3 launches + §1.4 polling.
- `fragments/04-scoring-gate.md` — §3.3 chunked-batch scoring.
- `fragments/05-validation.md` — §4.2 deep, §4.3 light, §4.5 Wave 2.
- `fragments/05-codex-validation.md` — §4.2.2, §4.2.3, §4.3.2.
- `fragments/09-fix-execution.md` — §8.5 fix-group fan-out.
- `.claude-plugin/plugin.json` — 0.3.3 → 0.3.4.

Phase 5 (cross-cutting) and Phase 9 (post-fix-and-commit) checked: both
single-agent dispatches, no fan-out risk.

## Verification

`test/smoke.sh` — 316+ assertions PASS (existing CR-12a/CR-12b
parallel-dispatch regression guards still hold; new callouts reinforce
without re-introducing the imperative-per-lens pattern those guards
forbid).

## Follow-ups (not in this PR)

- Optional: add smoke assertions requiring callouts at each newly
  hardened site (mirror CR-12a's positive-presence check pattern).
- Optional: extract a `test/audit-fanout.sh` script from the
  `grep -nE 'orchestrator turn|fan-out|chunk-agent'` audit used
  during this work so future fan-out sites surface in CI rather
  than via post-incident review.
