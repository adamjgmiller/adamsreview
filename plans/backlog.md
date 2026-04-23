# Backlog

Forward-looking consolidation of everything still on the adamsreview plugin's backlog, organized by priority and effort class. Every item has a concrete trigger for when it unblocks or becomes worth doing — this is a real backlog, not a pile of "maybe someday."

## Relationship to other plan files

- **`plans/post-conversion-ideas.md`** — the chronological idea log with original rationale for each item. Items completed by the 2026-04-22 session are marked `> DONE` with commit SHAs; items still pending here carry `> Deferred` markers pointing back to this file's triggers. Read that file when you need the full original reasoning.
- **`plans/post-plugin-improvements.md`** — the 2026-04-22 execution session (closed). Its §6 Build Journal records per-project verifier findings and three follow-ups that surfaced during execution (integrated into this backlog under §4).
- **`plans/stage-4-fragment-shrink.md`** — fragment-shrink plan; closed 2026-04-23 (see Appendix B for the measurement snapshot). Execution journal at `plans/stage-4-fragment-shrink-execution.md`.
- **`docs/archive/DESIGN.md`**, **`docs/archive/BUILD.md`** — frozen historical references for pre-2026-04-19 decisions. Consult for historical-rationale questions; do not edit.

## Quick summary

| Class | Items | Unblocks when |
|---|---|---|
| **§1. Data-driven decisions** | #1B, #1C, #24 (threshold-decision portion) | ~10 reviews of Phase 3 telemetry data accumulate (instrumentation shipped 2026-04-22 in `ee81715`) |
| **§2. Already-planned, dedicated session** | #2, #14 (Stage 4 fragment shrink) | *Closed 2026-04-23* — commit range `84c96ee..f9ccda0` (close-out commit `e1af3e9`; `f9ccda0` is a post-close self-review reconcile). Body kept for reference; Appendix B in the plan has the measurement snapshot |
| **§3. Session / issue follow-ups** | Transcluded-fragment `allowed-tools` gap; broader `parse-with-repair.py` migration; telemetry data collection; post-fix robustness lens (GH #2); L5-ux line-range root-cause (GH #2) | Surfaced 2026-04-22 session or in GH #2 (2026-04-20); per-item triggers |
| **§4. Probably leave alone** | #3, #4, #5, #6, #7, #8, #17 | Per-item "probably never" triggers — documented for completeness, not expected to fire |
| **§5. Big refactors, unlikely to be worth it** | #1D, #1E | Cost becomes irrelevant / full architectural rewrite motivated |

---

## §1. Data-driven decisions (awaiting Phase 3 telemetry)

The 2026-04-22 session shipped Phase 3 telemetry (`demote_rate` + `score_phase3_histogram` to `phases.jsonl` on every Phase 3 close — commit `ee81715`). These three decisions are unblocked once ~10 real-review cohorts' worth of that data accumulates. Until then, the status quo (conservative Phase 3 gate at 45, symmetric Phase 4 confirmation at 60/75, lane-asymmetric Phase 8 fix gate) remains correct by default.

**Walkthrough behavior is the second signal source.** Over the next ~10 reviews, track:
- If you mostly **promote without editing the hint** → Phase 4b's fix shape is usually right; walkthrough is rubber-stamping. Prefer option #1C (lift filter).
- If you mostly **edit the hint or skip** → walkthrough is earning its keep. Keep current shape.
- If you **rarely run walkthrough at all** → light-lane findings are falling on the floor. Either codify walkthrough into your flow or lift the filter.

### #1B — Per-lane Phase 8 thresholds

Replace the hard `impact_type ∈ {correctness, security}` lane filter with per-lane score thresholds:

```
score_phase4 ≥ threshold_for(impact_type) where
  threshold_for(correctness|security)   = 60
  threshold_for(ux|policy|architecture) = 75
```

Smooth continuum, still asymmetric by lane, more principled than a hard filter.

- **Effort:** M. One-site change in the Phase 8 fix-gate composite; CLAUDE.md gate prose + smoke assertion updates.
- **Trigger:** telemetry + walkthrough data says light-lane findings sometimes earn their keep but not always.

### #1C — Lift the lane filter, trust Phase 9a

Phase 9a Opus post-fix review runs on every surviving fix group. If it catches semantic mistakes reliably, the lane filter is redundant and all `confirmed_mechanical` findings can auto-apply regardless of `impact_type`.

- **Risk:** Phase 9a sees the diff, not the intent — reworded error messages that subtly change meaning might slip through. This risk is the main reason the lane filter exists today.
- **Effort:** S. Remove the `impact_type` check in the Phase 8 fix-gate.
- **Trigger:** telemetry says walkthrough mostly rubber-stamps AND post-hoc checks of Phase 9a outcomes confirm semantic-mistake catch rate is high.

### #24 — Phase 3 demote-rate threshold calibration

The 2026-04-22 run had 24/37 post-dedup candidates land `below_gate` (65%). Phase 3's err-up rubric is intentionally conservative, but 65% demoted may mean the gate is doing too much of Phase 4's work prematurely.

- **Telemetry (DONE 2026-04-22, commit `ee81715`):** `demote_rate` + `score_phase3_histogram` land in `phases.jsonl` at every Phase 3 close.
- **Decision (still pending):** across ~10 reviews, if steady-state demote rate is 50–65% AND Phase 4 is comfortable with its advanced set → rubric calibration is fine, leave alone. If demote rate stays 65%+ AND Phase 4 rarely disproves what gets advanced → consider loosening the Phase 3 cutoff (45 → 40) or weighting confidence higher.
- **Effort:** S. One-line threshold change + CLAUDE.md score-gates section update + smoke assertion.
- **Trigger:** ~10 reviews' worth of telemetry, ideally with a mix of PR sizes and domains.

---

## §2. Already-planned, awaiting dedicated session

### #2 — Stage 4 fragment shrink + helper externalization *(CLOSED 2026-04-23)*

Consolidate fragments where the boundary is arbitrary; extract cohesive Bash snippets into helper scripts with ~10-line contracts.

**Detailed plan:** [`plans/stage-4-fragment-shrink.md`](./stage-4-fragment-shrink.md) — executed per `plans/stage-4-fragment-shrink-execution.md` ledger. **Commit range:** `84c96ee..f9ccda0` on branch `stage-4-fragment-shrink` (21 commits; f9ccda0 is a post-close self-review reconcile). Close-out commit: `e1af3e9`.

**Outcomes (see plan Appendix B for measurement detail):**
- 4.0 investigation chose option (c): manifest-style command bodies. Every `!include X.md` in the 5 command files replaced with `Read fragments/X.md` directives — eliminating the post-v2.1.2 `<persisted-output>` silent-truncation failure mode.
- 3 new helpers: `freshness-gate.sh` (Phase 0.2a), `trivial-check.sh` (Phase 0.11), `artifact-seed.sh` (Phase 0.15). 4.A.4 finding-builder.py SKIPPED — the jq was already decomposed by earlier Stage 2.5/2.6/2.7/2.8 helpers.
- Prose consolidation: `fragments/_prelude-shared.md` (4.B.1), L1-L7 lens-prompt invariants moved into §1.2.1 (4.B.2), `fragments/10-post-fix-and-commit.md` compressed 10.1% (4.B.3).
- Lens references lazy-loaded (4.C).
- `/adamsreview:review` invocation-time prompt cost dropped ~94% (151k → 8.5k chars at invocation).
- Smoke 236 → 246 at close, → 249 after the f9ccda0 post-close self-review reconcile (+13 total; +10 net from Stage 4 steps, +3 from the reconcile's helper-hardening coverage).

### #14 — Fragment inlining capacity *(CLOSED 2026-04-23 — resolved by Stage 4)*

During the 2026-04-22 run, the `!include` preprocessor persisted Phases 0, 1.5, and 2–6 inline but truncated Phases 1 and 3 to 2 KB "previews"; the orchestrator had to `Read fragments/NN.md` directly to recover the rest. Fresh forcing-function evidence that the preprocessor ceiling was real and cost orchestrator turns.

**Resolution:** Stage 4 step 4.0 characterized the ceiling as Claude Code's post-v2.1.2 persist-to-disk threshold (ignores `BASH_MAX_OUTPUT_LENGTH`; substitutes a ~2 KB `<persisted-output>` preview for outputs over ~10 KB on current versions). Chosen response (c) — manifest-style command bodies — sidesteps the mechanism entirely. No top-level command uses `!include` anymore; `bin/include` remains available for small, size-safe transclusions should a future need arise. Silent-truncation failure mode eliminated.

**Future:** if Anthropic exposes a `DISABLE_BASH_PERSIST` env var, `!include` + aggressive compression becomes viable again — worth revisiting at the next major Claude Code release. See `plans/stage-4-fragment-shrink.md` Appendix A.

---

## §3. Session / issue follow-ups

Items surfaced during in-session execution or filed as GitHub issues that aren't in `plans/post-conversion-ideas.md`. FU-1..FU-3 came from the 2026-04-22 session (journaled in `plans/post-plugin-improvements.md` §6 close-out); P2 and P3 came from the 2026-04-19 ray-finance run and were filed as GH issue #2 on 2026-04-20.

### FU-1 — Transcluded-fragment `allowed-tools` gap (extend Project C's #21 fix) *(CLOSED 2026-04-23)*

Project C closed #21 by granting `Bash(line-range-check.sh:*)` in `commands/review.md` frontmatter. During that work the Builder noted that `assign-finding-ids.sh` and `origin-crosscheck.sh` are also invoked bare in transcluded fragments (`fragments/01-detection.md`, `fragments/02-ensemble-adapter.md`) and are likewise missing from `commands/review.md` `allowed-tools` — same class of pre-existing gap as #21.

**Fix (shipped):** one-line addition each to `commands/review.md` `allowed-tools`:
```
Bash(assign-finding-ids.sh:*)
Bash(origin-crosscheck.sh:*)
```

Smoke assertion `PF-INT-5` was already parameterized over three helpers (Shape A); extended the loop to cover both new grants — assertion count unchanged, coverage broadened from 3 → 5 Phase 1 detection helpers.

- **Effort:** S (realized). Two-line diff in `commands/review.md` frontmatter + 2-line edit to `test/smoke.sh` PF-INT-5 loop.
- **Commit:** `36b2481` on branch `FU1_P3` (bundled with P3 below).
- **Blast-radius verified:** `commands/fix.md` already grants both helpers; `commands/add.md` grants `assign-finding-ids.sh` (doesn't invoke `origin-crosscheck.sh`); `walkthrough.md` / `promote.md` don't invoke either. No follow-up gaps.

### FU-2 — Broader `parse-with-repair.py` call-site migration

Project F's middle-path decision bounded the 2026-04-22 migration to the `fragments/02-ensemble-adapter.md` normalizer step (the messiest LLM slop site — external-tool output). Other legacy ad-hoc JSON parse sites across fragments remain unmigrated pending real-world validation of the `parse-with-repair.py` contract.

**Candidate sites** (enumerate before doing): search fragments for `jq '.[…]'` chains fed by sub-agent stdout, especially in Phase 4 validators (partially migrated via #12 `parse-validator-result.py`, but fragments that parse peripheral fields around the score still do it ad-hoc).

- **Effort:** S per site, M across all sites. Mechanical: replace `jq` chain's input with `parse-with-repair.py < raw.json > clean.json` + pipe to the existing `jq`.
- **Trigger:** once `parse-with-repair.py` has run in ~5 ensemble reviews without producing false-positive unrecoverable exits on real LLM output (prove the helper's contract is calibrated), migrate the other sites incrementally. Alternatively: if one of those unmigrated sites hits a trailing-comma-class failure in production, migrate it opportunistically.

### FU-3 — Collect Phase 3 telemetry data (gates §1)

Phase 3 `demote_rate` + `score_phase3_histogram` are now in `phases.jsonl` on every Phase 3 close (commit `ee81715`). Data cohort for §1's #1B / #1C / #24 decisions starts accumulating from the next `/adamsreview:review` run forward.

**What to capture alongside:** for each review, also informally note walkthrough behavior class ("promoted most without editing hint" / "edited most hints or skipped" / "didn't run walkthrough") — that's the second signal source §1 needs, and no instrumentation exists for it.

- **Effort:** zero ongoing — the telemetry is automatic. Decision-time effort is M (read the telemetry, make three decisions, land three separate small commits).
- **Trigger:** ~10 reviews of the telemetry + walkthrough-behavior notes accumulated.

### P2 — Post-fix robustness lens (from GH #2)

**Source:** GH issue #2 (filed 2026-04-20 off the 2026-04-19 ray-finance `feat/import-apple` run). Motivating case: ultrareview's `bug_004` — unwrapped `mkdirSync` / `writeFileSync` at `src/cli/commands.ts:930-935` that can throw *after* the DB transaction commits. The block was added by a prior fixrun (F020 → commit `031e04d`); nothing in the pipeline currently re-audits fix-added code beyond the headline finding's claim. Observed twice on ray-finance (F002→F027/F028 access_token over-fetch; F020→`bug_004` unwrapped fs calls).

**Direction:** a new lens that runs only when `fix_attempts` is non-empty somewhere in the branch history. Prompt reads only the lines added by prior `fix_attempts`, flags unwrapped I/O, missing null checks, ignored promises, `console.error`-without-exit, other robustness gaps. Err wide; nits are fine — it's a targeted QA pass on code we wrote, not the PR author wrote.

**Surfaces:** new `fragments/<NN>-post-fix-audit.md` (or a gated L8 entry in `fragments/01-detection.md`); dispatch gate in `commands/review.md` Phase 1 argument plumbing; end-to-end smoke with a fixture branch carrying a deliberately-fragile fix in its history.

- **Effort:** M. New fragment + prompt tuning + one smoke assertion + a fixture.
- **Trigger:** next time a fix-introduced bug resurfaces in a later review on one of your real projects — a third observation in the wild would make the class persistent rather than incidental. If ensemble becomes default (GH #1) and Codex/CR reliably catch these via L7 + ensemble normalizer, this trigger moves further out.

### P3 — Root-cause L5-ux line-range hallucination (from GH #2) *(CLOSED 2026-04-23 — prompt-side invariant shipped)*

**Source:** GH issue #2. On the ray-finance run, L5-ux contributed 4 unique findings; 3 had `line_range` past the file's actual end (file 1042 lines, ranges 1815-1826 / 1912-1916 / 1941-1960). Phase 4 validators still confirmed the underlying claims because they re-read files for the claim pattern — but a 75% hallucination rate on unique contributions in a single run is concerning.

**Original status:** `bin/line-range-check.sh` (Phase 1 step 2 in `fragments/01-detection.md`) silently drops overshoot ranges, which means real findings get filtered out. This item is about preventing the bad output at the source, not filtering after the fact.

**Resolution (investigation + fix, 2026-04-23).** `Explore` sub-agent inspected `tokens.jsonl` from `rev_01KPMBB6KR5P19N4WHCHNFHXZE` (2026-04-20 re-run of ray-finance `feat/import-apple`). Root cause: **classification (a) — diff-hunk-header confusion.** The hallucinated ranges exactly match `[start, start+span]` arithmetic from typical unified-diff hunk headers like `@@ -1815,12 +1815,12 @@`. L5-ux (and potentially any lens under token pressure) was treating hunk-header line numbers as file-absolute — the L5 prompt had no explicit distinction. Non-L5 lenses on the same file cited in-range lines, so the failure was lens-behavioral, not input-structural.

Fix landed the normative invariant in `fragments/01-detection.md` §1.2.1 **shared-lens-invariants blockquote** so every lens (L1..L7) receives it, not just L5. Three load-bearing clauses: (a) `line_range` is file-absolute + counted from 1, (b) `line_range[1] <= file's total line count`, (c) do not copy numbers inside `@@ -a,b +c,d @@` verbatim. `bin/line-range-check.sh` remains as the runtime downstream filter (preventive + corrective, complementary).

- **Commit:** `3a8f64e` on branch `FU1_P3` (bundled with FU-1 above).
- **Smoke coverage:** new `LR-6` assertion in `test/smoke.sh` (Shape A parameterized grep) checks all three clauses are present in the `fragments/01-detection.md` blockquote.
- **Effort realized:** S. +9-line prompt addition + +23-line smoke assertion.
- **Residual monitoring trigger:** next review where `line-range-check.sh` emits `lens_hallucinated_line_range:` audit lines despite the invariant being in place indicates the prompt fix is insufficient; escalate to input-shape reformatting (the hypothesis-(a) path from the original Direction paragraph — feed full-file snapshots instead of raw diff hunks).

---

## §4. Probably leave alone (documented for completeness)

These items each have an explicit "probably never" trigger in the original backlog. Kept here so a future reader can find the decision rationale rather than re-deriving it.

### #3 — Helper layout: flat vs. subdirs

Currently 24+ scripts flat under `bin/`. Could split into `bin/readers/`, `bin/writers/`, `bin/utilities/` (mirrors the helper index in CLAUDE.md). Trade-off: subdirs mean longer `allowed-tools` paths and a less-flat discovery surface via `ls bin/`.

- **Trigger:** when `ls bin/` stops fitting on one screen, or a new maintainer asks where things are. With the plugin runtime auto-adding `bin/` to `$PATH`, the grant-surface argument is neutral either way.

### #4 — `codex:codex-rescue` / `coderabbit:code-reviewer` as first-class plugin agents

Ensemble mode already dispatches both via the ensemble adapter shell-out. Post-conversion they could be first-class plugin sub-agents referenced by `subagent_type` instead of shell-outs. Fewer process boundaries, structured output.

- **Trade-off:** requires those plugins be installed at plugin-load time rather than discovered by the adapter at dispatch time.
- **Trigger:** ensemble mode becomes the default for your reviews (current default is off).

### #5 — PostToolUse hook for `attempted`-never-committed detection

Currently Phase 7 detects leftover `attempted` findings and hard-aborts. A `PostToolUse` hook on `Bash(git commit:*)` could catch the gap earlier (commit fired but Phase 9c didn't update the artifact to `resolved`).

- **Overkill for personal use.** Current gate works.
- **Trigger:** probably never. Revisit only if you hit the leftover-attempted hard-abort more than once in a quarter.

### #6 — Single-command-with-subcommands shape

`/adamsreview review` / `/adamsreview fix` instead of `/adamsreview:review` / `/adamsreview:fix`. More conventional CLI. Loses Claude Code's native five-command model (each with its own `allowed-tools` / `argument-hint` / `description` frontmatter).

- **Trigger:** probably never. The five-command model is working and plugin namespacing (D18) makes `/<plugin>:<stem>` idiomatic.

### #7 — SessionStart hook expansion

Currently only runs `dep-check.sh`. Could default `ADAMS_REVIEW_REVIEWS_ROOT`, warm a `gh auth status` check, precompute `repo_slug`.

- **Recommendation: don't.** Hook output injects into session context and burns tokens every turn — anything environmental that can live in a Python helper should live there.
- **Trigger:** only if a specific high-value use case emerges that can't live in a helper called by the first phase that needs it.

### #8 — `latest.txt` vs. explicit `--review-id`

Lifecycle commands resolve artifact via `latest.txt`. Failure mode: user ran `:review` in a different branch between commands → `latest.txt` is stale. Alternative: require `--review-id` on `:add` / `:fix` / `:walkthrough`.

- **Recommendation: don't.** Personal-use tool, `latest.txt` does its job; adding a required flag is friction for a rare failure mode.
- **Trigger:** only if the stale-pointer failure mode bites in practice.

### #17 — Normalizer should expand multi-site findings natively

When Codex says "commands.ts:1492–1505 AND daily-sync.ts:323–337", the normalizer prompt is instructed to emit one candidate per site for clean dedup. That works, but produces ~20 external candidates that Phase 2 dedup then folds. A native "expand multi-site findings into per-site candidates" pass (helper or prompt subtask) would be cleaner than relying on the normalizer to do it by instruction.

- **Trigger:** if `--ensemble` mode starts producing consistent Phase 2 dedup bloat. Not urgent — the current shape works.

---

## §5. Big refactors, unlikely to be worth it

### #1D — Move decision upstream into Phase 4b (largest refactor of the light-lane system)

Light-lane validators default to `actionability = manual` unless explicit evidence of "fix is a one-line rename with no semantic change" etc. The lane-vs-threshold asymmetry becomes a validator-prompt thing, not a gate. Walkthrough becomes pure inspection.

- **Trigger:** probably never; the value isn't worth the refactor. If §1's data-driven decisions (#1B/#1C) resolve cleanly, this problem is already solved by a simpler mechanism.

### #1E — Collapse lanes entirely

One Opus Phase 4 for everything. Simplest architecture, highest cost (every light-lane finding pays Opus-per-candidate price where today it pays Sonnet-per-candidate).

- **Trigger:** cost becomes irrelevant. Personal use + typical PR sizes make this unlikely to ever pencil out.

---

## Notes on maintenance

- **When completing a backlog item**, add a commit-SHA line to the item in THIS file and either strike it or move it to a "Done" section — whichever keeps the file readable. The DONE markers already present in `plans/post-conversion-ideas.md` are the template; a companion "Done" section at the bottom of this file is an alternative if the quick-summary table at the top gets busy.
- **When adding a new backlog item**, write it here with the full structure (Name, Fix/Direction, Effort, Trigger) — don't just drop a line in the summary table. Each item should be actionable by a future reader without extra context.
- **When an item's trigger fires**, move it to a per-item plan under `plans/` (following the `stage-N-*.md` / `<topic>.md` convention) and link to the detailed plan from this backlog.
- **Archive rule.** Once an item is done AND the commit's been on `main` for a full release cycle, it can be pruned from this file. The commit SHA preserved in `post-conversion-ideas.md` (or equivalent) is the permanent record — backlog.md is for live tracking.
