# more-auto — Implementation plan

This is the build plan for the umbrella in `more-auto.md`. Each stage produces a verifiable artifact; smoke runs at end of stages 1–4. Plugin version bump in stage 5.

## Stage 1 — Schema + helpers

**Files:**
- `bin/schema-v1.json` — add `auto_fix_hint` object to finding (lines ~328 area, after `fix_attempts`). Required keys when present: hint, confidence, second_opinion, ts. Optional: concerns (only when second_opinion=concerns), alternatives. Field itself is OPTIONAL on the finding (omitted = no auto-rec generated/eligible).
- `bin/artifact-patch.py` — add two new modes:
  - `--apply-auto-fix-hints <json-file>`: takes array of `{id, hint, confidence, second_opinion, concerns?, alternatives?}`. Sets `auto_fix_hint` on each finding (with `ts=now`). Continue-on-error like `--add-findings`. Atomic write.
  - `--apply-auto-rec-promotions <json-file>`: takes array of `{id, reviewer, reason?}`. For each: snapshot `promoted_from`, set `human_confirmation = {reviewer, reason: reason || "auto-accepted via :fix preflight", ts: now, promoted_from: {...}, fix_hint: <auto_fix_hint.hint>}`. First-fail-halt semantics (matches existing `--apply-promotion`). Append trace block for batch.
- `bin/artifact-render.py` — render Auto-recommendation section per finding when `auto_fix_hint` present. Format: `**Auto-recommendation (<confidence>):** <hint>` + `**Concerns:** …` if `second_opinion=concerns`. Goes between the disposition line and the validator's fix_proposal block.
- `test/smoke.sh` — add MP-* (multi-promote) or new AFH-* assertions:
  - `AFH-1`: `--apply-auto-fix-hints` with valid JSON sets fields correctly
  - `AFH-2`: `--apply-auto-fix-hints` rejects invalid hint shape
  - `AFH-3`: `--apply-auto-rec-promotions` sets human_confirmation.reviewer prefix correctly
  - `AFH-4`: render output contains "Auto-recommendation" block for hint-bearing finding
  - `AFH-5`: render output omits Auto-recommendation block for findings without the field

**Verify:** `test/smoke.sh` passes including new assertions.

## Stage 2 — Phase 5.5 generation fragment

**Files:**
- `fragments/06b-auto-fix-hint.md` — new fragment, two sub-stages:
  - **5.5a Eligibility + generation dispatch** (in-prompt): compute eligibility via `artifact-read.sh --filter` (jq predicate per umbrella). If empty → log + skip. Else chunk into groups of ≤10, dispatch ONE Sonnet sub-agent per chunk in parallel (single tool turn). Each sub-agent:
    - Receives: array of {id, file, line_range, claim, disposition, validation_lane, score_phase4, validation_result.fix_proposal (when present)} + relevant CLAUDE.md path list + repo conventions
    - Returns: per-finding `{id, hint, confidence_self, alternatives}` (alternatives ≤2)
    - Prompt structure: propose → self-critique (1 paragraph) → finalize. Length budget: hint ≤ 3 sentences, alternatives optional
  - **5.5b Verification dispatch** (in-prompt, after 5.5a returns): one Sonnet sub-agent per chunk, independent. Each receives the hints from 5.5a + finding JSONs. Returns: per-finding `{id, concurs|concerns, concerns?, confidence_verified}`.
  - **Merge + patch** (orchestrator): collapse confidence_self + confidence_verified into one `confidence` (rule: take min; if either says low, result is low). Build payload, call `artifact-patch.py --apply-auto-fix-hints`. Log phase to phases.jsonl.
- `commands/review.md` — include `06b-auto-fix-hint.md` after `06-cross-cutting.md`. Bump `allowed-tools` if needed (likely already covered by existing grants).
- `commands/codex-review.md` — include same fragment after Codex's cross-cutting variant. Same Sonnet-driven generation regardless of which validator ran upstream.
- `commands/add.md` — include same fragment after :add's lane-aware Phase 4 (only on findings newly added or whose disposition shifted to a confirmed_* state).

**Verify:** synthetic artifact + dry-run trace shows correct chunk boundaries, eligibility filter applies correctly, dispatch happens in single tool turn (parallel-safe).

## Stage 3 — Consumer changes (`:fix` and `:walkthrough`)

**Files:**
- `commands/fix.md` (and likely `fragments/08-fix-loader.md`) — add **Phase 7.5 Auto-recommendation preflight** between loader's run-id assignment and Phase 8 dispatch. Logic:
  - Compute auto_rec_promotable_ids: findings with `auto_fix_hint != null` AND `current_state=="open"` AND `human_confirmation==null` AND `score_phase4 >= threshold`
  - If empty → log + skip
  - Else render summary table (id, file:line, claim_first_line, hint_truncated, confidence). AskUserQuestion: "Apply all (recommended) | Review per-finding | Skip these | Cancel"
  - **Apply all:** build promotion payload from each finding's auto_fix_hint, call `artifact-patch.py --apply-auto-rec-promotions`. These now match Phase 8's `human_confirmation != null` bypass. Continue to Phase 8.
  - **Review per-finding:** mini per-finding loop: render brief (id/file/hint/alternatives), AskUserQuestion: "Promote with this hint | Edit the hint | Skip". Loop until done. Promote chosen ones in batch. Continue to Phase 8.
  - **Skip:** continue to Phase 8 with original eligibility (auto_fix_hint findings stay open for next time).
  - **Cancel:** abort `:fix` (clean tree restored if stash taken).
- `commands/walkthrough.md` — add **Step 4.5 Auto-recommendation batch** between scope-tier choice and per-finding loop. Logic:
  - Compute auto_rec_in_scope_ids: findings in chosen scope (qualifying or full) with `auto_fix_hint != null` AND `human_confirmation==null`
  - If empty → continue to step 5 (existing per-finding loop)
  - Else render summary table. AskUserQuestion: "Accept all (recommended) | Pick subset to accept | Walk through each | Skip auto-rec batch"
  - **Accept all:** batch-promote all via `artifact-patch.py --apply-auto-rec-promotions`. Append decisions[] entries (action="auto-accept"). Remove from per-finding loop scope. Continue to step 5 with remaining (non-auto-rec) findings.
  - **Pick subset:** AskUserQuestion (multi-select) with each id+claim_first_line+hint_truncated. Batch-promote chosen, continue per-finding for unpicked.
  - **Walk through each:** continue to step 5 with full scope unchanged (per-finding loop will still benefit from short-circuit below).
  - **Skip auto-rec batch:** continue to step 5 with full scope.
- `commands/walkthrough.md` (per-finding loop, step 5.2) — when `auto_fix_hint != null`, **skip the briefing sub-agent**. Construct briefing object inline: `summary` from claim, `options` = [recommended option built from auto_fix_hint] + alternatives (if any) + edit-hint sentinel + skip + stop. Recommendation pre-set to label "A" (the auto-rec). Saves ~3-5k tokens per finding.

**Verify:** trace through synthetic artifacts with mixed auto-rec/non-auto-rec findings; render preflight tables; ensure batch-promotion path correctly tags reviewer="auto-rec/…".

## Stage 4 — Render + smoke

**Files:**
- `bin/artifact-render.py` already covered in Stage 1; verify the rendered PR comment block has correct Markdown structure + escaping (claims and hints contain backticks/quotes — must round-trip cleanly).
- `test/smoke.sh` — end-to-end synthetic-artifact assertions covering:
  - artifact with mixed findings (some with auto_fix_hint, some without) renders correctly
  - `:fix` preflight eligibility filter excludes already-promoted, excludes resolved, excludes deep-mechanical-already-auto, etc.
  - `:walkthrough` Step 4.5 scope intersection correct (auto-rec ∩ chosen scope)

**Verify:** `test/smoke.sh` clean.

## Stage 5 — Plugin metadata + docs

**Files:**
- `.claude-plugin/plugin.json`: 0.3.5 → 0.4.0 (new feature: auto-fix-hint pre-promotion)
- `CLAUDE.md`: add a single sentence under the `:review` and `:fix` and `:walkthrough` bullets about the new auto_fix_hint flow. Keep it terse — full docs live in the umbrella plan + the fragment itself. (Current CLAUDE.md is intentionally trim per recent commit 84def52.)
- `docs/state-and-gates.md`: short note about auto_fix_hint in the disposition section — clarifies that the field doesn't change disposition, only adds a fast-path for promotion. (Optional; only if needed for future-reader clarity.)

**Verify:** `gh pr create` would render the new field block; manually inspect rendered artifact.md against expectations.

## Stage 6 — End-to-end manual verification

After all stages green:
- Generate a synthetic artifact with 5 findings: 1 deep-mechanical, 2 light-mechanical, 2 confirmed_manual (mix of light/deep). Run `bin/artifact-render.py` and confirm Auto-recommendation block appears for findings 2-5 only (deep-mechanical excluded).
- Manually trace `:fix` preflight on this synthetic artifact: confirms 4 promotable, AskUserQuestion fires.
- Manually trace `:walkthrough` Step 4.5: confirms 4 in scope (assuming above-threshold), AskUserQuestion fires.

## Out of scope for this PR

- Adaptive Sonnet→Opus escalation when verification flags low confidence (could add later)
- Cross-cutting auto-fix-hints (cross-cutting groups don't currently have a structured fix-hint shape; would need separate design)
- Migration of existing artifacts (this is additive; old artifacts simply have no auto_fix_hint and behave as before)

## Risk + mitigations

- **Token blowup if many findings:** chunk size ≤10 caps per-call cost; eligibility filter caps total. Worst-case 50 eligible findings = 5 chunks × 2 passes = 10 Sonnet calls per review. Acceptable.
- **Wrong fix hint applied:** verification pass + `concerns` field surfaces low-confidence to user. Default Apply-all on high-confidence; users still see the hint in the preflight summary before clicking.
- **Schema drift:** auto_fix_hint is additive optional. Old artifacts work unchanged. New helper modes are net-additive.
- **Phase 8 fix-group agents misled by hint:** existing prompt already prioritizes `human_confirmation.fix_hint` over validator approach; auto-promoted ones flow through identically. No agent prompt changes needed.
