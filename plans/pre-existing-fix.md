# Plan — exposure-aware origin classification (Option A)

Branch: `pre-existing-fix`. Drafted 2026-04-26 in response to a misclassification audit on `beta-briefing@memory-2.0` (review `rev_01KQ6600SDPAMF5H6YJVT50NAM`).

## Background — the problem

The `/adamsreview:review` pipeline tagged five findings as `origin: pre_existing, origin_confidence: high`, which routed them via the §13.1 override to `disposition: pre_existing_report` (footnote-only, never validated). The user (manual git-blame audit against merge-base `6a146aa`) verified all five were caused by this PR. Walkthrough off-menu promote (`human_confirmation`) recovered four of them (F007/F017/F020/F021); F052 is still parked as `pre_existing_report`.

The five findings split into two failure modes:

**Mode 1 — wrong `line_range` (F007, F017).** The lens correctly described a PR-introduced bug in `claim`, but cited line numbers pointing at unrelated pre-existing prose (memory.py:552-553 instead of the real 510-518; notify.py:50-51 instead of the real 346). `origin-crosscheck.sh` blamed the wrong lines, found them all ancestor of `$comparison_ref`, and (correctly per its current logic) overrode to `pre_existing/high`.

**Mode 2 — exposure findings (F020, F021, F052).** The cited lines genuinely pre-date the PR (CLAUDE.md:138-145, CLAUDE.md:239, pipeline.py:364-431). What changed is *elsewhere* in the PR — `load_memory_context()` was added, the F051 alert was added, the F065 fallback was added — making the cited pre-existing prose/function wrong. Reverting the PR would close every one of these. But origin-crosscheck has no signal that "blame is pre-existing AND the bug is PR-caused" can both be true.

## Scope of this plan

**In scope (Option A):**
- F020 / F021 / F052 (exposure findings) — fully fixed.
- F007 / F017 (wrong line ranges) — partially mitigated. The lens's `introduced_by_pr` survives (instead of being overridden to pre_existing/high), so the finding routes through Phase 3 + Phase 4 normally. The wrong line range itself isn't corrected here; that's Mode 1's residual.

**Out of scope:**
- Mode 1 full fix — needs Phase 4 deep validator origin-correction authority. Track as Option B follow-up if F007/F017-class misses recur post-Option-A.
- Schema changes (no new `exposed_by_pr` enum or `exposure_in_pr` field).
- F038 rename-follow path. Content-preserving file extraction has a stronger evidentiary basis (we walked `git log --follow` to a pre-PR ancestor), so it stays auto-corrected to `pre_existing/high`. The rare combination "exposure finding inside an extracted file" is accepted as a known limitation, recoverable via walkthrough off-menu promote.

## Pipeline anchors (verified 2026-04-26)

- `bin/origin-crosscheck.sh` lines 281–291: the **main path** override-to-high site (lens introduced_by_pr + blame ancestor → override to `pre_existing/high`). This is where all five findings were misclassified.
- `bin/origin-crosscheck.sh` lines 228–241: the **rename-follow path** override-to-high site (F038 case). Untouched.
- `bin/origin-crosscheck.sh` lines 299–303: the symmetric **downgrade** site (lens pre_existing/high + blame includes PR commits → downgrade to medium). Already implements the symmetry pattern we're propagating to the main path.
- `fragments/01-detection.md` §1.2.1 (lines 58–99): shared lens-prompt invariant blockquote — the place all lenses see verbatim.
- `fragments/01-detection.md` lines 102–114: post-blockquote annotation list explaining what each lens carries inline (currently delegates origin defaults to L1/L7 + origin-crosscheck for others).
- `fragments/01-detection.md` lines 305–306 (L1) and lines 716–717 (L7): inline `origin: introduced_by_pr` defaults that need updating.
- `fragments/05-validation.md` §4.6 (lines 611–637): the post-Phase-4 re-assertion sweep. Unchanged here — Phase 4 still doesn't write origin, so this loop only catches what the lens + origin-crosscheck already produced.
- `fragments/04-scoring-gate.md` §3.1 (lines 11–34): the Phase-3 short-circuit that routes pre_existing/high to `pre_existing_report` before scoring. Unchanged behaviorally; just sees fewer inputs.
- `test/smoke.sh` OC-1 (line 1075): the existing assertion that flips. OC-9 (line 1229): rename-follow happy path, untouched.

## Edits

### A1 — `fragments/01-detection.md` shared origin rule

**Add to the shared invariants blockquote (§1.2.1, after the `line_range` paragraph at line 99):**

> Set `origin: "pre_existing"` only when BOTH (1) the implicated code is unchanged by this diff AND (2) the bug exists independently of this PR — reverting this PR would not close the finding. If pre-existing-looking code became wrong because of new code this PR adds elsewhere (a stale diagram now contradicted by a new pipeline step; a function missing a field a new caller needs; a doc bullet contradicted by a new fallback path), keep `origin: "introduced_by_pr"` — the PR is causally responsible. Default `origin: "introduced_by_pr"`, `origin_confidence: "high"`.

**Update L1's lens-specific extension (lines 305–306) and L7's (lines 716–717)** — replace their existing two-sentence default with a one-line reference: "Origin defaults per shared invariants in §1.2.1." Keeps the rule single-sourced.

**Update the annotation list (lines 102–114)** — drop the bullet "Default `origin: "introduced_by_pr"`, `origin_confidence: "high"` unless the code is clearly unchanged by this diff — L1 and L7 carry this explicit default; other lenses rely on `origin-crosscheck.sh` (step 1.4 step 2a) to correct blame-traceable cases." Replace with a one-liner noting origin defaults are now in the shared block and apply to every lens.

**Why every lens needs the rule, not just L1/L7.** Today L3 (CLAUDE.md compliance) and L4 (comment compliance) have no explicit origin guidance — they rely on origin-crosscheck for correction. Once we stop the main-path override (A2), those lenses need explicit guidance or every L3/L4 finding lands as whatever the LLM's interpretation of the schema enum is. F020/F021 came from L3 specifically.

### A2 — `bin/origin-crosscheck.sh` main-path symmetry fix

**Lines 281–291** — current logic:

```bash
if [[ "$all_ancestor" == "1" ]]; then
    if [[ "$lens_origin" == "pre_existing" && "$lens_conf" == "high" ]]; then
        action="respected"
        reason="blame-confirms-preexisting"
    else
        new_origin="pre_existing"
        new_conf="high"
        action="overridden"
        reason="all-blame-ancestor-of-comparison-ref"
    fi
```

**Proposed:**

```bash
if [[ "$all_ancestor" == "1" ]]; then
    if [[ "$lens_origin" == "pre_existing" && "$lens_conf" == "high" ]]; then
        action="respected"
        reason="blame-confirms-preexisting"
    else
        new_origin="pre_existing"
        new_conf="medium"
        action="downgraded"
        reason="lens-introduced-by-pr-but-all-blame-ancestor"
    fi
```

Effect: §13.1 override needs `origin_confidence == "high"` to fire. Dropping to `medium` prevents the Phase 3.1 short-circuit; the finding goes through Phase 3 scoring + Phase 4 validation, gets a real disposition.

**Rename-follow path (lines 228–241)** — keep as-is. The `git log --follow` extraction trace is a stronger signal than the main path's "all blame ancestor" check.

**Helper-header docstring (lines 13–29)** — update the decision table's "all SHAs reachable from comparison_ref" row to read:

```
all SHAs reachable from comparison_ref:
    lens already pre_existing/high     → respect (no-op)
    otherwise                          → set pre_existing/medium
                                          (lens disagrees with blame; let
                                          Phase 3 + Phase 4 decide instead
                                          of force-routing to footnote)
```

### A3 — Doc updates

**`CLAUDE.md` Helper index entry for `origin-crosscheck.sh`** — current text reads "forces `pre_existing:high` if fully reachable from `$comparison_ref`; downgrades conflicting lens verdicts."

Replace with: "main-path: respects lens-supplied `pre_existing/high` when blame agrees, downgrades to `pre_existing/medium` when the lens said `introduced_by_pr` but blame is ancestor (so Phase 3.1 doesn't short-circuit exposure findings); rename-follow path still overrides to `pre_existing/high` for F038-class extractions; downgrades lens-supplied `pre_existing/high` to medium when blame includes PR commits."

**`CLAUDE.md` §Score gates "Pre-existing override"** — unchanged. The §13.1 rule itself is unchanged; only its inputs are.

### A4 — Smoke tests (`test/smoke.sh`)

| Assertion | Today | After A2 |
|---|---|---|
| OC-1 (~line 1075) | expects `origin=pre_existing,conf=high` + `action=overridden` + `reason=all-blame-ancestor-of-comparison-ref` | expects `origin=pre_existing,conf=medium` + `action=downgraded` + `reason=lens-introduced-by-pr-but-all-blame-ancestor` |
| OC-2 through OC-8 | error / PR-modified / mixed cases | unchanged |
| OC-9 (~line 1229) | rename-follow happy path → `pre_existing/high` | **unchanged** (rename-follow path untouched) |
| OC-10, OC-11 | regression guards | unchanged |

**Add OC-12** — positive test for "lens already pre_existing/high + blame agrees → respect, no-op". OC-1's input direction has flipped, so a dedicated assertion makes the lens-AGREES-with-blame case explicit and resistant to future drift.

**Add OC-13** — prompt-rule fixture. Grep `fragments/01-detection.md` §1.2.1 shared block for the exposure-aware sentence ("reverting this PR would not close the finding"). Cheap regression guard against future drift in the prompt text.

## Risks & mitigations

1. **Recall regression on lens-confused pre-existing.** A lens that flags genuinely-old code as `introduced_by_pr` (rare, but the case origin-crosscheck used to auto-rescue) now goes through Phase 3 + Phase 4 instead of the report-only footnote.
   - *Mitigation*: Phase 4 deep-lane validation is a safety net — confirms (good, the user wanted to see it) or denies (`disproven` keeps it out of actionable). Cost is some Phase 4 token budget.
   - *Worth-tracking (optional)*: a phases.jsonl counter for `origin_crosscheck_main_downgraded` would surface frequency post-deploy. Flag for follow-up if it matters.

2. **L3 / L4 lens output shape change.** Today these lenses don't carry an explicit origin default; the schema enum gives the LLM three choices and it picks. After A1 the shared block forces a default. Smoke catches the prompt text, not lens behavior.
   - *Mitigation*: spot-check on a real review (re-run `/adamsreview:review` on `beta-briefing@memory-2.0` with the patched fragment loaded) before declaring done.

3. **F038-style exposure inside an extracted file.** Rare combination — exposure finding inside a content-preserving-extracted file would still be force-overridden to pre_existing/high by the rename-follow path. Accept as a known limitation; walkthrough off-menu promote covers it.

## Verification

1. `test/smoke.sh` → green (existing assertions plus OC-12, OC-13).
2. Hand-check the five-finding fixtures: shape candidate JSON like the lens output for F007/F017/F020/F021/F052, run `origin-crosscheck.sh --comparison-ref 6a146aa --candidates @-`, verify each comes out `pre_existing/medium` with `action=downgraded`. Use the user's already-recorded artifact as the truth set.
3. *Optional calibration*: re-run `/adamsreview:review` on `beta-briefing@memory-2.0` against the patched fragment to see whether the new prompt rule shifts L3/L4 behavior on the CLAUDE.md findings (F020/F021). Treat as a data point, not a blocker.

## Commit shape

Three commits, one per logical edit (per CLAUDE.md "commit at natural breakpoints"):

1. `01-detection.md: shared-block exposure-aware origin rule (Option A1)` — fragment + L1/L7 simplification.
2. `origin-crosscheck.sh: symmetric main-path downgrade for lens-introduced_by_pr (Option A2)` — helper + header docstring + CLAUDE.md helper-index entry.
3. `smoke: OC-1 expectation flip + OC-12/OC-13 additions (Option A4)` — test updates.

## Blast-radius checklist (per global CLAUDE.md)

- **Every writer of `origin/origin_confidence`**: lens prompts (set initial), `origin-crosscheck.sh` (corrects), `parse-validator-result.py` (does NOT touch origin — verified). Phase 4.6 sweep reads but doesn't write origin. ✓
- **Every consumer of `origin/origin_confidence`**: `fragments/04-scoring-gate.md` §3.1 (Phase 3.1 short-circuit), `fragments/05-validation.md` §4.6 (re-assertion). Both gate on `origin == "pre_existing" AND origin_confidence == "high"`. After A2, fewer findings reach that state via the main path; the gate semantics are unchanged. ✓
- **Parallel code paths**: rename-follow and main path inside `origin-crosscheck.sh` are siblings. Decision: change main only, document the asymmetry (rename-follow has stronger evidence). Documented in §A2 + helper docstring + CLAUDE.md helper-index entry. ✓
- **Stale comments / docs**: helper header comment block (§A2 last paragraph), CLAUDE.md helper-index entry (§A3). Fragment annotation list at lines 102–114 (§A1). All updated in this plan. ✓
- **Fix the class, not the instance**: the symmetry fix applies to `origin-crosscheck.sh`'s only override-to-high site on the main path; rename-follow is the deliberately-preserved sibling. The lens-prompt rule applies to the shared invariant so all lenses inherit it. ✓
