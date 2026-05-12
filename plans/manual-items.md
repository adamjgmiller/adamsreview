---
branch: manual-items
base: main
started: 2026-05-11
---

# manual-items — widen Phase 5.5 eligibility to all confirmed_mechanical

## Goal

Close the gap where dedup-induced lane/impact_type mismatches let
`confirmed_mechanical` findings fall through both Phase 5.5 (auto-fix-hint
generation) and Phase 8 (fix execution), forcing the user into a per-finding
walkthrough briefer for findings that should have been batch-acceptable.

## Triggering incident

`/adamsreview:review` run on `adamjgmiller/beta-briefing` PR #267
(`user-research-invite`, `rev_01KRAN1GS4BSDKS05A1YBMXYE6`, 2026-05-11) ran
v0.4.0 successfully but the overnight `/review-fix-loop` orchestrator
**fabricated** a Phase 5.5 skip rationale (`delta: "skipped — overnight-loop
optimization"`). The string doesn't exist in the plugin source — it was the
orchestrator's own decision. Net effect: 0 of 46 findings got
`auto_fix_hint`, the walkthrough's Step 4.5 batch-accept fast-path stayed
empty, and 6 findings (3 `confirmed_manual`, 3 `confirmed_mechanical`) went
through the per-finding briefer for ~136 k tokens instead of ~30–40 k.

Separately, F031 on that PR exposed a structural gap: it has
`validation_lane == "deep"` AND `impact_type == "ux"` because dedup's
"deep wins over light" rule (`fragments/03-dedup.md:124`) merged a
light-lane `L5-ux` candidate with a deep-lane `L6-security` candidate. Per
the v0.4.0 predicate, F031 was excluded from Phase 5.5
(`validation_lane != "light"`), and Phase 8's `impact_type ∈ {correctness,
security}` filter also excluded it — so it could only be fixed via
walkthrough.

The orchestrator's skip is out of scope here (that's a `/review-fix-loop`
prompt issue); this branch fixes the structural gap so even if Phase 5.5
runs correctly, F031-class findings get covered.

## Changes

- `fragments/06b-auto-fix-hint.md` — drop the `and .validation_lane ==
  "light"` constraint on `confirmed_mechanical` in the eligibility jq
  (§5.5.0) and the prose mirror. Add a short paragraph explaining why lane
  is no longer gated.
- `CLAUDE.md:9` — drop "light-lane" prefix from the Phase 5.5 description.
- `fragments/08-fix-loader.md:388-391` — same prose update; reference the
  dedup-induced gap as the reason.
- `.claude-plugin/plugin.json` — bump 0.4.0 → 0.4.2 (0.4.1 reserved for a
  parallel PR).
- `test/smoke.sh` — add AFH-11 (runtime predicate behavior against a
  synthetic 9-finding artifact, expected selection `F-DM,F-LM,F-MAN,F-REP`),
  AFH-12 (textual regression guard against re-introducing the lane
  gate), and AFH-13 (canonical fragment block extracted between
  fence markers and executed against the AFH-11 synthetic, catching
  predicate drift the inline-copy AFH-11 would miss).

## Blast radius (verified)

Downstream consumers of `auto_fix_hint` all accept any lane already, so the
generation-side widening is the only place that changes:

- `bin/artifact-patch.py:1501` `_AUTO_REC_PROMOTABLE_DISPOSITIONS` — no
  lane gate.
- `fragments/08-fix-loader.md:414` Phase 7.5 promotable filter — no lane
  gate (filters by `auto_fix_hint != null`, state, score).
- Walkthrough Step 4.5 — no lane gate.
- `:add` re-uses `fragments/06b-auto-fix-hint.md` directly, so it inherits
  the widening.
- `:codex-review` shares fragment 06b (Sonnet-driven, validator-agnostic).

## UX trade

`confirmed_mechanical` findings that previously fell into the
dedup-induced gap (e.g. `validation_lane=deep` +
`impact_type=ux`) now generate a Phase 5.5 hint and surface in the
Phase 7.5 batch confirm. Outcome depends on user action:

- **User accepts at Phase 7.5** → `human_confirmation` is set, Phase 8's
  `impact_type` filter is bypassed, finding gets fixed in this run.
- **User skips at Phase 7.5** → no `human_confirmation` set. Phase 8's
  `impact_type ∈ {correctness, security}` filter still excludes the
  finding for mismatched cases (e.g. deep+ux). The finding remains at
  `current_state=open` and the user must run `:walkthrough` or
  `:promote` to fix it later.

For deep-lane `confirmed_mechanical` findings whose `impact_type` is
already `correctness` or `security`, the skip path is still covered by
Phase 8's filter — the gap is specific to lane/impact_type mismatches.

Cost is one extra Sonnet generation+verify chunk per ~10 such findings.

## Test result

`./test/smoke.sh` → `smoke: PASS (329 assertions)` (up from 326; +AFH-11,
+AFH-12, +AFH-13). CR-8 also flips from `version >= 0.3.0` checking 0.4.0
to checking 0.4.2 — passes.

## Follow-ups (not in this branch)

1. The `/review-fix-loop` orchestrator prompt should not allow opting out
   of Phase 5.5 — the token "saving" is anti-economical once `:walkthrough`
   runs.
2. Consider a dedup-time invariant or warning when a merged finding's
   `validation_lane` and `impact_type` mismatch (deep+ux, deep+policy,
   deep+architecture, light+correctness, light+security).

## Merge log

- 2026-05-12 — merged `main` (`git merge`, commit `1ebaf39`). Brought in
  PR #37 `d462c22` ("PR-comment polish: signature line + filtered-findings
  accounting", v0.4.1). Only conflict was the `version` field in
  `.claude-plugin/plugin.json` (`0.4.1` vs `0.4.2`); resolved to `0.4.2`
  as anticipated by Changes §50 ("0.4.1 reserved for a parallel PR").
  `test/smoke.sh` auto-merged (main's F100/Y2 additions at ~L73/L178/L817,
  manual-items' AFH-11/12/13 at ~L2932 — different chapters of the file).
  Post-merge: `smoke: PASS (331 assertions)` (326 base + 2 main + 3
  manual-items).
