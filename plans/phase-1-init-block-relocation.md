# Plan: Phase 1 init-block relocation — bring `#### Dispatch turn` and its prerequisites into the same sub-section

**Status:** drafted 2026-05-03; executed 2026-05-04 on top of `8fa8b6a`
(R3 of the imperative-fix loop). Branch: `parallel` (this worktree).
This file is the pre-execution plan snapshot; the rendered tree reflects
the executed result. Codex round-1 review of the executed diff added
two follow-up tightening fixes to CR-15a/c and softened a Phase 1.5
clock-alignment claim — see commit log for rounds.

**Pattern:** three small text edits in one fragment + one new smoke
assertion + a patch version bump. No schema changes, no helper changes,
no command changes.

**One-line summary:** `phase_1_start_epoch=$(date +%s)` is captured
in §1.4, AFTER `#### Dispatch turn` in §1.3 fires the lens fan-out —
so `phase_1_elapsed` (line 876) under-reports by the lens duration.
Move it (along with the conceptually-paired `internal_candidates='[]'`
seed) to a "**Pre-dispatch init**" preamble inside `#### Dispatch
turn`, where the codebase's own cross-references already say it
should be. Update the §1.4 opening to forward-point, refresh
line-293's prose, and add three smoke guards (CR-15a/b/c) against
future drift.

---

## Context

### The deferred finding

Codex's R3 review of the parallel-dispatch imperative-fix loop flagged
this layout (`fragments/01-detection.md:453-459`) and we deferred it
as out-of-scope for the bug-class fix. The deferral notes (R3 commit
`8fa8b6a`) read:

> Codex F2 (init-block layout in §1.4 vs. new "#### Dispatch turn"
> sub-section) deferred — Codex itself framed this as pre-existing,
> not an R1/R2 regression; relocating the init snippet is a structural
> change beyond the bug-class scope.

User has now requested we make the fix.

### Why the layout is a real defect (not just style)

The `#### Dispatch turn` sub-section in §1.3 (lines 401-411) is the
unambiguous action target the imperative-fix loop installed. It says:

> issue every applicable lens's `Agent` tool-use in a SINGLE
> orchestrator turn

But the bash that the dispatch *requires* lives 50 lines lower in
§1.4:

```bash
phase_1_start_epoch=$(date +%s)
internal_candidates='[]'
```

A naïve top-to-bottom orchestrator reads:
1. §1.3 dispatch turn → fires the lenses (no `phase_1_start_epoch`
   captured yet)
2. §1.3 ensemble fan-out → fires the CLIs
3. §1.4 init block → *now* sets `phase_1_start_epoch=$(date +%s)`

The genuine defect is on `phase_1_start_epoch` only: `phase_1_elapsed
= $(date +%s) - phase_1_start_epoch` at line 876 wildly under-reports
because the start time is captured AFTER §1.3's dispatch turn
finishes — it measures only the join-step duration, not the actual
lens duration.

`internal_candidates` is **not** currently broken. §1.4's init at
line 458 precedes its first consumer at line 563 in source order
within the same sub-section, so a top-to-bottom orchestrator reading
§1.4 hits the `internal_candidates='[]'` seed before the per-lens
append loop body at line 461+. Relocating it alongside
`phase_1_start_epoch` is structural cleanliness — the seed value
belongs with the dispatch it seeds, the two are conceptually paired,
and `01-codex-detection.md` already groups them together as the
"FIRST action of this phase" — not a latent-bug fix.

Risk on `phase_1_start_epoch` is **bounded** (a wrong number on a
metrics field; not a correctness defect — lenses still dispatch,
candidates still collect) but not zero, and it's exactly the class
of bug the imperative-fix loop was about: the orchestrator following
local prose strictly top-to-bottom, defeating an ordering the
fragment relied on prose alone to enforce.

### What the codebase ALREADY says should happen

Two cross-references in the tree already document the intended
placement:

**`fragments/01-detection.md:291-295`** (the §1.2-Phase-1.5 epoch
capture for ensemble mode):

> This epoch is what 02-ensemble-adapter.md step 1.5.7 subtracts to
> compute `phase_1_5_elapsed`. Placing it here mirrors Phase 1's
> **`phase_1_start_epoch` capture at the top of step 1.3** — both
> clocks start at the same turn boundary, so under §13.12 parallel
> dispatch the two `elapsed_sec` values naturally overlap in
> `phases.jsonl`.

The line 293 wording — *"capture at the top of step 1.3"* — is
factually wrong against the current tree. The capture is at the top
of §1.4, not §1.3. The fix brings the code in line with the prose's
documented intent.

**`fragments/01-codex-detection.md:3`** (the codex-review sibling
fragment):

> Capture `phase_1_start_epoch=$(date +%s)` as the FIRST action of
> this phase (step 1.6 logs the elapsed time). Initialize the
> tracking variables Phase 1's summary will reference: …

The codex-review path got the structure right — init at the top of
the phase. The canonical Claude path drifted to §1.4 at some point
and the cross-reference at line 293 is a remnant of the original
intent.

So the move is a **correction toward documented design intent**,
not a redesign.

### Why R2 chose the prose fix instead

R2 of the imperative-fix loop reworded line 454 from *"at the top of
step 1.3's dispatch turn"* to *"before the first lens `Agent` block
of step 1.3's dispatch turn"*. That was a deliberate prose-tightening
in lieu of relocation — defensible at the time because the loop's
scope was the imperative-recipe bug class, not the surrounding
layout. But prose-spanning between §1.3 and §1.4 is exactly the
shape of failure the imperative-fix is trying to make impossible.
This plan finishes the job R2 deliberately scoped out.

---

## Goal

`phase_1_start_epoch=$(date +%s)` and `internal_candidates='[]'`
initialize in the same sub-section as the dispatch they precede,
documented as a pre-dispatch context init that runs before the lens
`Agent` blocks.

**Done when:**

1. `fragments/01-detection.md` `#### Dispatch turn` sub-section opens
   with a "**Pre-dispatch init**" preamble containing the two-line
   bash block (`phase_1_start_epoch`, `internal_candidates`) and a
   prose explanation that these are working-context value
   initializations, not separate `Bash` tool-uses.
2. §1.4 opening prose ("Initialize the pool and capture the phase
   epoch before the first lens `Agent` block of step 1.3's dispatch
   turn:" + the bash block) is removed; replaced with a
   forward-pointer ("…in an in-context pool (`internal_candidates`,
   initialized in step 1.3's pre-dispatch init)…") so a reader
   landing in §1.4 still knows where the var came from.
3. Line 293's "capture at the top of step 1.3" cross-reference is
   updated to the more precise "capture in step 1.3's pre-dispatch
   init" — matches the new placement and the literal sub-section
   structure.
4. Smoke gains three new assertions split CR-13-style (a/b/c):
   - **`CR-15a`** (positive guard) — fragments/01-detection.md
     `#### Dispatch turn` sub-section contains both
     `phase_1_start_epoch=$(date +%s)` and `internal_candidates='[]'`.
     Mirrors the CR-12a/b spirit — fragment-prose-shape regression
     guard. Whitespace-tolerant `grep -qE` matches mirror CR-12a's
     regex precedent (not the literal `grep -qF` the first plan
     draft used).
   - **`CR-15b`** (negative twin) — neither var appears in
     fragments/01-detection.md §1.4 (window: `### 1.4.` →
     `### 1.5.`). Catches the regression class where a future edit
     re-introduces the init in §1.4 alongside the new dispatch-turn
     placement: CR-15a still passes (vars are in dispatch turn) but
     last-write-wins source-order reading would re-introduce the
     original layout drift via duplication. The regex (`= …`
     followed by literal `[]`) is precise enough to skip false
     positives on the §1.4 per-lens append at line 563
     (`internal_candidates=$(jq …)`, no `[]`) and the
     `--argjson accum "$internal_candidates"` site (variable
     expansion, no `=`).
   - **`CR-15c`** (window sanity) — the awk window itself
     (`#### Dispatch turn` → next `#### `) is non-empty. Sanity
     guard against silent no-op if a future fragment edit reorders
     or renames sub-section headings. Mitigates the awk-windowing
     fragility class flagged in the imperative-fix plan for this
     PR's new assertion only; CR-12a's and CR-12b's windows are
     still unguarded (see "Out of scope" below).
5. Smoke total: 313 → 316 (three new assertions).
6. Plugin version bumped `0.3.2 → 0.3.3` (patch bump per CLAUDE.md
   release discipline — observability correctness fix on
   `phase_1_start_epoch`; a wrong number on the published
   `phase_1_elapsed` metric is user-visible if anyone reads the
   artifact's `metrics` field).
7. `/adamsreview:codex-review` (the sibling fragment
   `01-codex-detection.md`) is **not** changed. Its structure was
   already correct and is the model this fix is moving toward.

---

## Non-goals / explicitly deferred

- **No restructure of §1.3 or §1.4 sub-section boundaries.** The
  move is purely "relocate the bash + adjust 3 prose lines"; the
  section numbering and headings stay as they are.
- **No changes to `01-codex-detection.md`.** Already structurally
  correct; this fix follows its lead, not the other way around.
  After this fix, the canonical Claude path will say "in step 1.3's
  pre-dispatch init" while codex-detection still says "FIRST action
  of this phase". The wording divergence is intentional — both
  phrases accurately describe their fragment's own structure (the
  codex fragment has no `#### Dispatch turn` sub-section to point
  at; its dispatch is a single `node "$CODEX_COMPANION" task`
  background fan-out at the top of the phase), and unifying them
  would force one fragment to use language that doesn't match its
  own layout.
- **No changes to `phase_1_elapsed` consumers** (line 876, plus
  whatever logs `elapsed_sec` to `phases.jsonl`). The compute
  expression is unchanged; only the time at which
  `phase_1_start_epoch` gets set moves.
- **No CLAUDE.md edit required.** The pipeline-shape diagram and
  rule 11 ("Working set lives in-prompt, not shell vars") are still
  accurate. The two values are working-context variables both
  before and after the move.
- **No schema or artifact changes.** Pure fragment + smoke.

---

## Validation steps for the executing agent (or future me)

Before making any edits, verify the diagnosis matches the live tree.

1. `git log --oneline -5` should show `8fa8b6a` (R3) at HEAD or near
   it. Confirms we're on top of the imperative-fix loop work.
2. `grep -n 'phase_1_start_epoch=$(date +%s)' fragments/01-detection.md`
   — must return exactly one hit, currently at line 457. Confirms
   the init lives in §1.4.
3. `grep -n 'internal_candidates=' fragments/01-detection.md` —
   must return three hits: line 458 (init), line 563 (per-lens
   append), line 564 (`--argjson accum`). Confirms consumer pattern.
4. `grep -n 'capture at the top of step 1.3' fragments/01-detection.md`
   — must return line 293. Confirms the cross-reference that
   documents intent.
5. `test/smoke.sh` — must pass 313/313 cleanly. Confirms baseline.
6. Read `fragments/01-detection.md` lines 280-300 (covers the
   Phase-1.5 epoch capture cross-reference at line 293).
7. Read `fragments/01-detection.md` lines 397-415 (covers the
   `#### Dispatch turn` sub-section).
8. Read `fragments/01-detection.md` lines 446-462 (covers §1.4
   opening with init block).
9. Read `fragments/01-detection.md` lines 870-880 (covers §1.6
   consumer at line 876).

If any of steps 1-5 disagree with the diagnosis, **stop and report**
instead of executing. Otherwise proceed.

---

## Changes

### Change 1: Relocate init block into `#### Dispatch turn`

**File:** `fragments/01-detection.md`

**Old (lines 401-411):**
```
#### Dispatch turn (one turn, all blocks)

With every applicable lens's spec assembled (L1–L7 sub-sections
above), issue every applicable lens's `Agent` tool-use in a SINGLE
orchestrator turn. The per-lens sub-sections are reference data — a
parameter sweep, not a turn sweep. Phase 1 wall-clock latency is
`max(lens_durations)`, not `sum(lens_durations)`.

Under `ensemble_mode == true`, the Ensemble fan-out's background
`Bash` calls (next sub-section) launch in this same turn — see the
"Total tool-use blocks" table below for the exact count by mode.
```

**New:**
```
#### Dispatch turn (one turn, all blocks)

**Pre-dispatch init** (orchestrator working context — not a separate
tool-use turn): capture the phase epoch and seed the in-context
candidate pool that §1.4 will append to as lens results return.

```bash
phase_1_start_epoch=$(date +%s)
internal_candidates='[]'
```

These are working-context value initializations per CLAUDE.md
operational rule 11 ("Working set lives in-prompt, not shell vars"),
not `Bash` tool-uses; the orchestrator records them in-context
*before* issuing the `Agent` blocks below. The `phase_1_start_epoch`
capture mirrors the §1.2-Phase-1.5 `phase_1_5_start_epoch` so both
clocks start at the same turn boundary (§13.12 parallel dispatch),
and `internal_candidates='[]'` is the seed value §1.4's per-lens
`--argjson accum "$internal_candidates"` appends require.

**Dispatch.** With every applicable lens's spec assembled (L1–L7
sub-sections above), issue every applicable lens's `Agent` tool-use
in a SINGLE orchestrator turn. The per-lens sub-sections are
reference data — a parameter sweep, not a turn sweep. Phase 1
wall-clock latency is `max(lens_durations)`, not `sum(lens_durations)`.

Under `ensemble_mode == true`, the Ensemble fan-out's background
`Bash` calls (next sub-section) launch in this same turn — see the
"Total tool-use blocks" table below for the exact count by mode.
```

Two structural additions:
- A bolded **Pre-dispatch init** preamble containing the bash block
  and explanation.
- A bolded **Dispatch.** label on the original action prose so the
  two-step structure within the sub-section is visually crisp.

CR-12b's regex (`Launch one \`Agent\` tool-use|and[[:space:]]+dispatch\.`)
does NOT match either `phase_1_start_epoch=$(date +%s)` or
`internal_candidates='[]'`, and does NOT match the new
**Pre-dispatch init** / **Dispatch.** labels. So no false-positive
risk on the existing imperative-recipe guard.

### Change 2: Drop init from §1.4, add forward-pointer

**File:** `fragments/01-detection.md`, lines 446-462.

**Old:**
```
### 1.4. Collect lens candidates into pool

Collection runs per-lens as each sub-agent result returns — but under
§13.12 nothing gets an `id` and nothing is committed to the artifact
during collection. Candidates accumulate in an in-context pool
(`internal_candidates`) and are committed at the join step 1.5.

Initialize the pool and capture the phase epoch before the first lens
`Agent` block of step 1.3's dispatch turn:

```bash
phase_1_start_epoch=$(date +%s)
internal_candidates='[]'
```

For each sub-agent result, in the order it returns:
```

**New:**
```
### 1.4. Collect lens candidates into pool

Collection runs per-lens as each sub-agent result returns — but under
§13.12 nothing gets an `id` and nothing is committed to the artifact
during collection. Candidates accumulate in an in-context pool
(`internal_candidates`, initialized in step 1.3's pre-dispatch init
along with `phase_1_start_epoch`) and are committed at the join step
1.5.

For each sub-agent result, in the order it returns:
```

Two surgical changes:
- The init block (8 lines including code fence and prose) is removed
  — it now lives in `#### Dispatch turn`.
- The `internal_candidates` parenthetical gains a forward-pointer so
  a reader landing in §1.4 doesn't have to grep for the var.

§1.4's title and conceptual scope ("Collect lens candidates into
pool") are unchanged — it was always the per-lens result-handling
section; the init was just slotted at the top out of convenience.

### Change 3: Update line-293 cross-reference

**File:** `fragments/01-detection.md`, lines 287-295.

**Old (lines 287-295):**
```
```bash
phase_1_5_start_epoch=$(date +%s)
```

This epoch is what 02-ensemble-adapter.md step 1.5.7 subtracts to
compute `phase_1_5_elapsed`. Placing it here mirrors Phase 1's
`phase_1_start_epoch` capture at the top of step 1.3 — both clocks
start at the same turn boundary, so under §13.12 parallel dispatch
the two `elapsed_sec` values naturally overlap in `phases.jsonl`.
```

**New:**
```
```bash
phase_1_5_start_epoch=$(date +%s)
```

This epoch is what 02-ensemble-adapter.md step 1.5.7 subtracts to
compute `phase_1_5_elapsed`. Placing it here mirrors Phase 1's
`phase_1_start_epoch` capture in step 1.3's pre-dispatch init — both
clocks start at the same turn boundary, so under §13.12 parallel
dispatch the two `elapsed_sec` values naturally overlap in
`phases.jsonl`.
```

One change: "capture at the top of step 1.3" → "capture in step
1.3's pre-dispatch init". More precise and matches the literal
sub-section structure created by Change 1.

### Change 4: Add smoke regression guard

**File:** `test/smoke.sh`

Insert immediately after the CR-12b block (after line ~5664 in the
post-imperative-fix tree). Naming convention follows the existing
CR-* / RH-* / FX-* style.

**New assertions split into CR-15a/b/c** (CR-13 is codex-poll,
CR-14 is preflight effort gate, CR-15 is the next free slot in the
CR-* range; the a/b/c split mirrors CR-13a/b/c/d's precedent of
breaking a multi-property guard into independently-meaningful
sub-checks):

```bash
# CR-15: fragments/01-detection.md §1.3 "#### Dispatch turn"
# sub-section hosts the Phase 1 pre-dispatch init block
# (phase_1_start_epoch + internal_candidates). Without
# phase_1_start_epoch in the dispatch sub-section, a top-to-bottom
# orchestrator captures the start time AFTER §1.3 dispatches the
# lenses and phase_1_elapsed (line 876) under-reports by the lens
# duration. internal_candidates is co-located for structural
# cleanliness (the seed value belongs with the dispatch it seeds);
# duplicating it back into §1.4 would re-introduce the original
# layout drift via last-write-wins source-order reading.
#
# Three sub-checks:
#   a. positive guard — both vars present in the dispatch-turn
#      window (`#### Dispatch turn` → next `#### ` heading).
#   b. negative twin — neither var present in §1.4 (`### 1.4.` →
#      `### 1.5.`). Catches future-edit duplication.
#   c. window sanity — the dispatch-turn window itself is
#      non-empty. Sanity guard against silent no-op if a future
#      fragment edit renames the sub-section heading.

cr15_window=$(awk '
    /^#### Dispatch turn/   {in_window=1; next}
    /^#### /                {if (in_window) in_window=0}
    in_window               {print}
' "$REPO/fragments/01-detection.md")

cr15_section_14=$(awk '
    /^### 1\.4\./           {in_window=1; next}
    /^### 1\.5\./           {in_window=0}
    in_window               {print}
' "$REPO/fragments/01-detection.md")

# CR-15a — positive guard. Whitespace-tolerant regex (mirrors
# CR-12a's `[[:space:]]+` precedent). For internal_candidates the
# optional-quote class `['"]?` accepts `'[]'`, `"[]"`, or bare
# `=[]` so trivial reformats don't trip the assertion.
cr15a_has_epoch=0
cr15a_has_pool=0
printf '%s\n' "$cr15_window" \
    | grep -qE 'phase_1_start_epoch[[:space:]]*=[[:space:]]*\$\(date' \
    && cr15a_has_epoch=1
printf '%s\n' "$cr15_window" \
    | grep -qE "internal_candidates[[:space:]]*=[[:space:]]*['\"]?\[\]" \
    && cr15a_has_pool=1
if [[ "$cr15a_has_epoch" == "1" && "$cr15a_has_pool" == "1" ]]; then
    pass "CR-15a: fragments/01-detection.md §1.3 '#### Dispatch turn' sub-section contains Phase 1 pre-dispatch init (phase_1_start_epoch + internal_candidates)"
else
    cr15a_missing=""
    [[ "$cr15a_has_epoch" == "0" ]] && cr15a_missing="$cr15a_missing phase_1_start_epoch=\$(date +%s)"
    [[ "$cr15a_has_pool" == "0" ]] && cr15a_missing="$cr15a_missing internal_candidates='[]'"
    fail "CR-15a: fragments/01-detection.md §1.3 '#### Dispatch turn' sub-section missing pre-dispatch init —$cr15a_missing — top-to-bottom orchestrator would dispatch lenses before capturing the phase epoch (phase_1_elapsed under-reports)"
fi

# CR-15b — negative twin. Catches the regression where a future
# edit re-introduces the init in §1.4 alongside the dispatch-turn
# placement. Same regex as 15a, applied to the §1.4 → §1.5 window.
# Precision matters: the regex requires `=` then optional quote
# then `[]`, so it does NOT match the existing §1.4 sites:
#   - line 563+ `internal_candidates=$(jq ...)` (no `[]`)
#   - line 564 `--argjson accum "$internal_candidates"` (no `=`
#     after the var name; that's a variable expansion)
#   - line 594 `--argjson internal "$internal_candidates"` (same)
#   - the §1.4 forward-pointer parenthetical (backticks, no `=`)
cr15b_violations=""
printf '%s\n' "$cr15_section_14" \
    | grep -qE 'phase_1_start_epoch[[:space:]]*=[[:space:]]*\$\(date' \
    && cr15b_violations="$cr15b_violations phase_1_start_epoch_in_§1.4"
printf '%s\n' "$cr15_section_14" \
    | grep -qE "internal_candidates[[:space:]]*=[[:space:]]*['\"]?\[\]" \
    && cr15b_violations="$cr15b_violations internal_candidates_in_§1.4"
if [[ -z "$cr15b_violations" ]]; then
    pass "CR-15b: fragments/01-detection.md §1.4 contains no Phase 1 pre-dispatch init (negative twin against duplication regression)"
else
    fail "CR-15b: fragments/01-detection.md §1.4 contains pre-dispatch init that should live only in '#### Dispatch turn' —$cr15b_violations — duplication would re-introduce original layout drift via last-write-wins source-order reading"
fi

# CR-15c — window sanity. If a future edit renames "#### Dispatch
# turn" or removes the next "#### " boundary, cr15_window goes
# empty and 15a would silently pass without checking anything.
# Loud-fail instead.
if [[ -n "$cr15_window" ]]; then
    pass "CR-15c: fragments/01-detection.md '#### Dispatch turn' awk window non-empty (heading present and a subsequent '#### ' boundary follows it)"
else
    fail "CR-15c: fragments/01-detection.md '#### Dispatch turn' awk window empty — heading missing, renamed, or no subsequent '#### ' heading found. Silent-no-op risk: CR-15a would pass without checking anything. Verify the '^#### Dispatch turn' heading and the next '^#### ' heading both exist."
fi
```

Notes on the assertion shape:
- **Three independent sub-checks** matching CR-13's a/b/c precedent
  in the same file. Failure messages point at the specific
  regression class (missing init / duplicated init / heading drift)
  rather than a combined "something's wrong with §1.3".
- **`grep -qE` with `[[:space:]]*`** rather than `grep -qF` — a
  trivial reformat (extra space, `'[]'` → `"[]"`, comment line
  inserted) won't false-trip the assertion. Mirrors CR-12a's
  whitespace-tolerant pattern.
- **CR-15b's window is `### 1.4.` → `### 1.5.`**, not "everywhere
  outside the dispatch-turn window". §1.4-only is the precise
  regression target (duplication into the original location); a
  broader "anywhere else" check would fight false positives in
  §1.6's `phase_1_elapsed=$(( $(date +%s) - phase_1_start_epoch ))`
  consumer line, which legitimately mentions the var.
- **CR-15c does NOT cover CR-12a's or CR-12b's windows.** Same
  awk-windowing fragility class affects those two assertions; this
  PR only closes the gap on its own new assertion. Generalizing
  CR-15c into a reusable `assert_nonempty_awk_window` helper and
  retrofitting it onto CR-12a/b is the right backlog shape (see
  "Out of scope" below).
- **No `tr '\n' ' '` flatten** needed — the bash code-block lines
  matched by 15a/15b don't wrap in markdown.

### Change 5: Plugin version bump

**File:** `.claude-plugin/plugin.json`

Bump `version` from `0.3.2` to `0.3.3`. Patch bump per CLAUDE.md
release discipline:

- This is a behavior correction (the published `phase_1_elapsed`
  metric will go from "wildly under-reported under top-to-bottom
  orchestrator reading" to "correct"). User-visible if anyone
  inspects the artifact's metrics field.
- Same rationale class as the v0.3.2 bump (parallel-dispatch
  correctness): a fragment-prose change that fixes an
  orchestrator-execution defect without touching code/schema/helpers.

---

## Test plan

1. **Smoke runs clean before edits.** `test/smoke.sh` should pass
   313/313. (Established by R3 of the imperative-fix loop.)

2. **After Changes 1-3 (fragment edits) but before Change 4 (smoke
   addition), smoke should still pass 313/313.** No existing
   assertion guards the relocated content, so the move is
   smoke-invisible. If smoke fails after Changes 1-3, an existing
   assertion is hardcoded against the pre-move text — stop and
   reconcile (most likely candidate: a hypothetical prose-anchor
   assertion targeting line 453's exact wording).

3. **After Change 4, smoke should pass 316/316.** Three new
   CR-15a/b/c assertions added; verifies the post-move state.

4. **Negative-test all three CR-15 guards.** Before committing:
   - **CR-15a**: temporarily comment out `phase_1_start_epoch=$(date +%s)`
     in the dispatch-turn preamble, run smoke, confirm CR-15a fails
     with the missing-piece message. Restore. Repeat for
     `internal_candidates='[]'`. Confirms the positive guard fires
     on either missing piece.
   - **CR-15b**: temporarily paste the pre-fix init block back into
     §1.4 (so the init lives in BOTH dispatch-turn and §1.4
     simultaneously), run smoke, confirm CR-15b fails with the
     duplication-violation message. Restore. Confirms the negative
     twin catches the duplication regression class — the exact
     failure mode CR-15a alone would miss.
   - **CR-15c**: temporarily rename `#### Dispatch turn` to
     `#### Dispatching` (or any heading drift), run smoke, confirm
     CR-15c fails with the empty-window message AND that CR-15a/b
     also surface (15a fails because the window is empty so neither
     var is found; 15b passes because §1.4 is unchanged). Restore.
     Confirms the sanity guard catches silent no-op from heading
     drift.

5. **Cross-reference sweep.** After all edits, run
   `grep -n 'phase_1_start_epoch\|internal_candidates' fragments/01-detection.md`
   and verify:
   - `phase_1_start_epoch=$(date +%s)` appears exactly once (in the
     new `#### Dispatch turn` preamble).
   - `internal_candidates='[]'` appears exactly once (same place).
   - Line-876 consumer (`phase_1_elapsed=$(( $(date +%s) -
     phase_1_start_epoch ))`) still references the var unchanged.
   - Lines 563/564 (`--argjson accum "$internal_candidates"`) still
     reference the var unchanged.
   - Line 451 (the §1.4 forward-pointer parenthetical) reads
     correctly.

6. **No live `/adamsreview:review` test required for this fix.**
   Same scope-class as the imperative-fix loop — fragment-prose-only
   change, behavior verification would require a real PR review.
   The user can re-test on a real PR post-merge if they want
   end-to-end confirmation that `phase_1_elapsed` now reports
   sensibly.

---

## Risk / blast radius

- **No code path runs differently as a direct result of this
  change.** `phase_1_start_epoch` and `internal_candidates` still
  get initialized; their consumers (line 876 for elapsed compute,
  lines 563-564 for per-lens append) are untouched. The fragment
  prose change shifts *when* in the orchestrator's reading the init
  fires — earlier (good) instead of later (the latent defect).
- **`/adamsreview:codex-review` is not affected.** Different
  fragment (`01-codex-detection.md`); already structurally clean
  per the Validation Step 4 trace. This fix moves the canonical
  Claude path to match what codex-review already does.
- **`/adamsreview:add` / `/adamsreview:fix` /
  `/adamsreview:walkthrough` / `/adamsreview:promote`** are not
  affected. None run Phase 1 lens detection.
- **The fix is reversible.** Single-PR revert restores the
  pre-relocation fragment + smoke + version. If the relocation
  somehow confuses the orchestrator in a different way, revert is
  clean; the deferred status of the original Codex finding remains
  defensible.
- **Smoke flakiness risk.** RA-10 and TK-1 have transient failures
  in the current test/smoke.sh (observed during the imperative-fix
  loop). Neither is related to this change; if they trip during
  validation, re-run smoke once to confirm transience before
  treating as a blocker.
- **Residual awk-windowing risk on CR-15a's window is mitigated
  by CR-15c.** If a future edit renames `#### Dispatch turn` or
  removes the next `#### ` boundary, CR-15a's window goes empty
  and would silently pass — but CR-15c's non-empty-window sanity
  check fires loud. The same fragility class still affects
  CR-12a's and CR-12b's windows, which this PR does NOT
  retrofit; see "Out of scope" for the generalization backlog
  item.

The only thing the executing agent should be careful about:
multi-line `old_string` matches in Change 1 and Change 2 are wide
windows. Verify each against the live `Read` of the file before
applying — if any prose has drifted since this plan was drafted,
reconcile before guessing.

---

## Commit message draft

```
Phase 1 init-block relocation: pre-dispatch init in same sub-section as dispatch (v0.3.3)

The Phase 1 imperative-fix (v0.3.2) installed a "#### Dispatch turn"
sub-section in fragments/01-detection.md §1.3 as the unambiguous
action target for parallel lens dispatch. The bash that the dispatch
requires —

  phase_1_start_epoch=$(date +%s)
  internal_candidates='[]'

— was left in §1.4, 50 lines below. A top-to-bottom orchestrator
reading the fragment dispatches the lens Agent blocks first
(line 401-411) and only sets phase_1_start_epoch later (line 457),
under-reporting phase_1_elapsed by the lens duration. (internal_candidates
is not currently broken — its first consumer at line 563+ follows
the init at line 458 within §1.4's source order — but it's
conceptually paired with phase_1_start_epoch as the dispatch's
working-context seed and belongs co-located with it; structural
cleanliness, not bug fix.)

The codebase already documents the intended placement: line 293's
cross-reference reads "Phase 1's phase_1_start_epoch capture at the
top of step 1.3", and fragments/01-codex-detection.md:3 ("Capture
... as the FIRST action of this phase") confirms the codex-review
path got this right. The §1.4 placement was a drift; this fix brings
the canonical Claude path back in line with documented intent.

Move both lines to a "**Pre-dispatch init**" preamble inside
"#### Dispatch turn", explicitly labeled as orchestrator
working-context value initialization (not a separate Bash tool-use
turn) per CLAUDE.md operational rule 11. Update §1.4's opening
parenthetical to forward-point at the new init location. Refresh
line 293's cross-reference to "capture in step 1.3's pre-dispatch
init" so it matches the literal sub-section structure.

New smoke CR-15a/b/c guards the placement (split per CR-13
precedent in the same file): 15a — both vars present in the
"#### Dispatch turn" window (positive guard); 15b — neither var
present in §1.4 (negative twin against future duplication into the
original location); 15c — dispatch-turn awk window is non-empty
(sanity guard against silent no-op if a future edit renames the
heading). Whitespace-tolerant grep -qE matches mirror CR-12a's
regex precedent (not the literal grep -qF the first plan draft
used). Smoke 313 → 316.

Plugin version bumped 0.3.2 → 0.3.3.

Closes the deferred Codex F2 finding from the parallel-dispatch
imperative-fix /review-fix-loop (R3, commit 8fa8b6a).

/adamsreview:codex-review unchanged — its sibling fragment
(fragments/01-codex-detection.md) was already structurally correct;
this fix moves the canonical Claude path to match.
```

---

## Out of scope but worth noting (for backlog)

- **CR-12a/b awk-windowing fragility (still partial).** CR-15c
  closes the silent-no-op risk on this PR's new dispatch-turn
  window assertion, but CR-12a's window (`### 1.3.` →
  `#### L1 `) and CR-12b's window (`#### L1 ` → `### 1.4.`) remain
  unguarded. A future heading-rename in either window would
  silently no-op those without firing. Generalizing CR-15c into a
  reusable helper (e.g., `assert_nonempty_awk_window <name>
  <window-var>`) and applying it to CR-12a, CR-12b, and CR-15c
  uniformly is the right backlog shape — same backlog item as
  flagged in the imperative-fix plan, narrower in scope after this
  fix.
- **Codex's R2 regex-broadening suggestion (still deferred).** This
  fix doesn't touch CR-12b's regex; the deferral remains defensible
  on the same grounds (bug class only manifested in two phrases;
  broadening risks false positives on legitimate prose).
