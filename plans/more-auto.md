---
branch: more-auto
base: main
started: 2026-05-10
---

# more-auto — Auto-fix-hint generation for findings currently locked behind walkthrough

## Goal

Convert findings that today force users into `/adamsreview:walkthrough` (confirmed_manual, confirmed_report, light-lane confirmed_mechanical) into AI-authored fix recommendations that ship with the review and can be batch-accepted at `:fix` or `:walkthrough` time. User reports accepting AI recommendations ~90% of the time during walkthrough — surface the recommendation upfront so the typical flow becomes a single batch-confirm rather than a per-finding interactive loop.

## Why

The schema already populates `validation_result.fix_proposal.approach` for *every* confirmed finding — mechanical, manual, AND report. Phase 8 only fixes deep-lane confirmed_mechanical because of the lane filter and the fact that "manual" is meant to encode "AI shouldn't decide unilaterally". With a second-opinion pass to verify the validator's proposal, we can lift most of these into "AI proposes, user batch-confirms" territory. Walkthrough's per-finding briefer already produces fix hints — this feature is a *time shift* of that work plus a confidence boost.

## Decided

- **Field:** new optional `auto_fix_hint` per finding (object). Shape:
  - `hint` (string, 1–3 sentences) — the recommended fix direction, suitable as `human_confirmation.fix_hint`
  - `confidence` (enum: high / medium / low)
  - `second_opinion` (enum: concurs / concerns)
  - `concerns` (array of strings, present only when second_opinion=concerns)
  - `alternatives` (array of {label, title, hint}; ≤2)
  - `ts` (ISO-8601)
- **Phase 5.5** (new, runs after Phase 5 cross-cutting, before Phase 6 finalize):
  - 5.5a generation pass: Sonnet, chunks of ≤10, structured prompt (propose → self-critique → finalize). Output: per-finding {hint, confidence_self, alternatives}
  - 5.5b verification pass: Sonnet, chunks of ≤10, independent. Input: hint + finding JSON. Output: per-finding {concurs|concerns, concerns[]?, confidence_verified}
  - Orchestrator merges → `auto_fix_hint` per finding → patches artifact via new `artifact-patch.py --apply-auto-fix-hints` mode
- **Eligibility:** `current_state=open` AND `human_confirmation==null` AND disposition ∈ {confirmed_manual, confirmed_report, (confirmed_mechanical AND validation_lane=="light")} AND `score_phase4 >= 60`. Excludes pre_existing_report and deep-lane confirmed_mechanical (already auto-fixable).
- **`:fix` Phase 7.5 preflight:** if any auto-rec-eligible findings exist, render summary table and AskUserQuestion: "Apply all (recommended) / Review per-finding / Skip these / Cancel". Apply-all auto-promotes via batch helper, sets `human_confirmation.reviewer = "auto-rec/<email>"`, then proceeds to Phase 8 with all promoted IDs included. Review-per-finding hands off to a walkthrough-style mini-loop. Skip continues with original eligibility.
- **`:walkthrough` Step 4.5:** same batch confirm before per-finding loop. Per-finding loop short-circuits the briefer sub-agent when `auto_fix_hint` is present (renders directly).
- **`:codex-review`:** same Phase 5.5 fragment (Sonnet-driven, validator-agnostic).
- **`:add`:** same Phase 5.5 fragment after its lane-aware Phase 4.
- **Render:** `artifact-render.py` shows an Auto-recommendation block per finding with auto_fix_hint, prefixed with confidence and concerns (if any).
- **Provenance string:** `human_confirmation.reviewer = "auto-rec/<email>"` distinguishes from user-typed and walkthrough-picked promotions.
- **Schema versioning:** stays at schema_version=1 (additive optional field). Plugin version 0.3.5 → 0.4.0 (new feature, minor bump).

## Considered, rejected

- **Make `:fix` silently apply auto-recs without confirmation** — rejected; user wants a "list and confirm" surface (default Apply-all is the speed path, but the option to review/skip stays).
- **Phase 5.5 inline in Phase 4 validators** — rejected; mixes classification with hint-authoring, and validator output already has a clean schema. Cleaner as a separate phase.
- **Single Sonnet pass with internal propose-critique-finalize** — rejected in favor of two-pass for genuine second-opinion independence; user explicitly asked for second agent.
- **Opus generation** — rejected for cost; Sonnet chunked at ≤10 with structured prompts is sufficient and the verification pass catches gaps.
- **New disposition value** (e.g., `auto_recommended_mechanical`) — rejected; orthogonal field is cleaner. Disposition is the routing key; auto_fix_hint is supplementary metadata.

## Index

- [PLAN](more-auto-PLAN.md) — implementation plan with stage breakdown
