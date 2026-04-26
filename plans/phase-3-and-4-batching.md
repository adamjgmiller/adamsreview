# Phase 3 / Phase 4 batching: codify the parts that work, harden the parts that shouldn't

## TL;DR

The orchestrator silently batches Phase 3 in ~65% of recent reviews and has now
started batching Phase 4 too. The data shows Phase 3 batching is **acceptable
at the gate decision level** but **destroys per-finding score resolution**,
which weakens Phase 3's value as triage and pushes more work into Phase 4.
Phase 4 deep-lane batching is **not safe** — the lane's load-bearing property
is independent blast-radius work per finding.

Recommendation:

- **Phase 3:** codify Sonnet-batched scoring with a chunk cap (~25 findings)
  and an explicit anti-clustering instruction in the prompt. Don't upgrade to
  Opus — anchor collapse isn't fixed by a smarter model, it's fixed by
  rubric structure.
- **Phase 4 deep lane:** keep per-candidate, and add a structural guard that
  catches batching after the fact (helper-side rejection of under-sized
  decision tuples).
- **Phase 4 light lane:** allow Sonnet-batched, same shape as Phase 3.

## Background

Spec §3.3 says "for each id in `scoring_ids`, launch ONE Sonnet sub-agent.
Fire them all from a single orchestrator turn." Spec §4.2 / §4.3 say "one
Opus sub-agent per candidate" / "one Sonnet sub-agent per candidate."

`tokens.jsonl` analysis across 34 recent reviews (`scripts/` count of
`agent_role: scoring`/`validator` entries vs expected fan-out from artifact
`disposition` counts):

- **Phase 3:** ~22/34 reviews silently batched (scoring count of 0 or 1
  against an expected 11–59 fan-out). Three explicit `phase_3_deviation`
  notes in `trace.md`; the rest are silent.
- **Phase 4:** ~5/33 underfanned, but the most recent run
  (`rev_01KQ1G00WKW1R6YQSVJQVAPGD8`) has both `phase_3_deviation` and
  `phase_4_deviation` notes — single Opus deep-validator + single Sonnet
  light-validator. That run's artifact still has 13 findings at
  `pending_validation` with no `validator` entry in `tokens.jsonl`, suggesting
  the batched form may not have closed cleanly through `--apply-decisions`.

Phase 1 lenses, Phase 8 fix-groups, Phase 9 post-fix review: all compliant.

## Quality data

Compared 5 batched and 5 fanned recent runs from comparable repos
(beta-briefing, ray-finance import-apple, worktreehq).

### Score-distribution collapse (the smoking gun)

| Mode | Anchor-only rate (% of scores in {0, 25, 50, 75, 100}) |
|---|---|
| Batched (5 runs, n=208 scores) | **100%** (208/208) |
| Fanned (5 runs, n=96 scores) | **39%** (37/96) |

Fanned scorers use the full 0–100 range (28, 32, 38, 52, 62, 72, 78, 82) to
express borderline judgments. Batched scorers collapse to the five rubric
anchor labels exclusively. The model is treating the rubric as a 5-state
classifier rather than a 0–100 score.

### Triage value (Phase 3 → Phase 4 correlation)

In a fanned run (`rev_01KPGXESJTMK51CSZMSAQYW1DP`): every advancing finding
(p3 ≥ 52) was confirmed at Phase 4 (p4 ≥ 60). Phase 3 was meaningful
triage.

In a batched run (`rev_01KQ19GWE93DC3M0K6VKSZCAFM`), of 16 findings scored
p3=50:

- 5 confirmed_mechanical
- 8 uncertain
- 3 disproven

p3=50 in batched mode is essentially "everything I'm not sure is a clear
false positive" — it carries no signal about likelihood of confirmation.
Phase 4 ends up doing both validation and triage, against a coarser input.

### Below_gate sample (batched)

Eyeballed all 32 below_gate findings from
`rev_01KQ19GWE93DC3M0K6VKSZCAFM`. Most are correct demotes (UX nitpicks,
script-only validation gaps, style policy items). Two-three look like
borderline real bugs that probably should have advanced:

- `F034` (correctness): URL collision in `by_url` map causing duplicate
  rewrites when two stories share a URL. Real-but-rare invariant violation.
- `F036` (correctness): `BEGIN` (deferred) vs `BEGIN IMMEDIATE` lock
  upgrade race in `merge_story_memory`; mitigated by WAL + busy_timeout
  but real.
- `F029` (security): raw `ValueError` message containing user-supplied
  slug forwarded to HTMX banner; autoescape mitigates XSS but reflects
  user input in error path.

Estimated miss rate: ~3/32 = ~9% per batched run for "real-but-borderline
that should have advanced."

### What this means for the gate decision

Gate is at 45. Anchor scores in batched mode are 25 (fail) or 50 (pass) —
the binary classification is exactly aligned with the gate threshold. So
the **gate outcome is functionally similar** between batched and fanned;
the difference is that batched mode loses the audit-trail granularity in
the 30–44 and 52–74 bands.

The ~9% miss rate observed is the model's err-up rule failing to fire —
borderline findings being bucketed as 25 instead of 50. This is fixable
in the prompt without changing model.

## Recommendation

### Phase 3: codify Sonnet-batched, harden the rubric application

**Why Sonnet, not Opus:**

- Phase 3 is designed as a coarse err-up triage gate. The err-up rule and
  the ≥2-source-family auto-graduate rule are the protective mechanisms,
  not model capability.
- Anchor collapse is a prompt-structure failure, not a discrimination
  failure. Opus would still tend toward anchors with the current prompt;
  Sonnet with a tightened prompt won't.
- Cost asymmetry: ~5x per token. Across a year of reviews, ~$50–60 of
  marginal Opus spend at Phase 3 buys quality improvements that are
  better bought via Phase 4 fan-out (which is already where the dollars
  earn their keep).

**Spec changes (§3.3):**

1. Replace "for each id in `scoring_ids`, launch ONE Sonnet sub-agent" with
   "dispatch one Sonnet sub-agent per chunk of up to 25 findings. Chunk
   sequentially when `len(scoring_ids) > 25`."
2. Add to the prompt body:
   > Score each candidate independently. Use the full 0–100 range —
   > **do not cluster scores at the rubric anchors {0, 25, 50, 75, 100}.**
   > A borderline candidate between two adjacent anchors should land on
   > a value in between (e.g. 30, 38, 62, 72) reflecting your actual
   > uncertainty. The err-up rule still applies: when truly torn between
   > two adjacent levels, pick the higher one.
3. Token logging: emit one `tokens.jsonl` entry per chunk (preserving
   per-finding `finding_id: null`-style "batch" entries — `tally-subagent-tokens.sh`
   already aggregates without caring about granularity).
4. Keep the per-finding `score_history` append intact — `--apply-decisions`-
   shaped helper isn't needed for Phase 3 since `--set score_phase3=N`
   already auto-appends.

**Optional: add a Phase 3 chunked-batch tuple helper.** Right now §3.3 step
3 calls `artifact-patch.py --finding-id $id --set score_phase3=N` per
result. With chunked output, this is N `--set` calls; we could add an
`--apply-scores @file.json` mode mirroring `--apply-decisions` to absorb
each chunk in one helper invocation. Not load-bearing — keep the per-finding
loop if helper expansion feels like overreach.

**Gate threshold stays at 45.** The anchor-collapse data made it look like
the gate position might need to nudge (e.g. to 26 or 49) to align with
the rubric anchors, but that's only relevant in pure-anchor mode — and
the prompt fix above is the actual remediation for anchor mode. Once
continuous scoring is restored, the 30–44 band fills back in with
"real-but-minor" findings (sample from fanned runs: a security
`_PRUNE_MAX_AGE_HOURS` concern at 35, a slug anonymization gap at 38,
a `notify_on_retry` bypass at 38) — these are correct demotions to
`below_gate`, where the rendered artifact still surfaces them as
report-only items. Gate=45 is doing the job. Widening to 26 would push
real-but-minor findings into Opus validation with low marginal value;
narrowing to 49 contradicts the err-up rule's design (which wants
ambiguous candidates to advance, not the opposite). The right time to
revisit this dial is *after* a few continuous-scored reviews land —
look at Phase 4 confirmation rates by p3 band and tune from real data.

### Phase 4 deep lane: keep per-candidate, harden via structural guard

**Why hold the line:**

- Phase 4 deep is per-finding work: blast-radius tracing, file reads, fix
  proposal, verification context. The model's "13x cost savings" estimate
  is wrong — the per-finding cost is ~2–3x not ~13x because most of the
  Opus spend is the read/grep work it does, not the prompt overhead.
- Anchoring across unrelated findings in one Opus context risks
  cross-contamination of fix proposals (e.g. a `files_to_modify` pattern
  from finding A leaking into finding B's proposal). This won't surface
  until a Phase 8 fix-group regression — long failure latency.
- The current run that batched Phase 4 didn't close cleanly through
  `--apply-decisions`; the helper plumbing is designed around N validators
  emitting one `validation_result` each.

**Spec changes (§4.2 / §4.3):**

1. Strengthen the "one per candidate" prose to "one Agent dispatch per
   candidate. Do not collapse multiple candidates into a single
   sub-agent — each finding's blast-radius work requires independent
   context."
2. Add a structural guard in `artifact-patch.py --apply-decisions`:
   - Helper currently accepts an array of N tuples and applies them.
   - Change: caller must also pass `--expected <N>` (the number of
     candidates dispatched in the wave). Helper rejects with exit 1
     when `len(tuples) < expected`, with error-as-prompt:
     `ERROR: dispatched N validators but only got M decisions; if you
     batched, re-dispatch one per candidate.`
   - This catches a batched validator that returned `{batch: [...]}` — the
     orchestrator would have to unwrap the array into N tuples, which is
     possible but no longer silent: the helper forces the surfacing.
3. Update §4.4's tuple compose step to pass `--expected` from the wave's
   dispatched candidate count.

**Why the structural guard, not just stronger prompt prose:** the model has
demonstrated it'll override prose rules when it judges the cost trade
favors batching. A helper-side check fails loudly at apply time, which
forces the orchestrator into a known recovery path (re-dispatch) rather
than silently batching.

### Phase 4 light lane: allow Sonnet-batched

**Why this is OK:**

- Light-lane prompt is "is this CLAUDE.md rule real? does the comment
  conflict?" — short rubric check, no blast-radius work. Same cost/quality
  shape as Phase 3.
- Light-lane already mostly emits `report_only` / `manual` (rarely
  `auto_fixable`), so confirmation precision matters less.
- The current `parse-validator-result.py --lane light` already canonicalizes
  output; doesn't care whether scores came from one batch or N calls.

**Spec changes (§4.3):** mirror the Phase 3 prose — chunk cap of ~25 per
Sonnet sub-agent, anti-anchor-clustering instruction. The structural
guard from §4.2 extends to the light lane via per-candidate counting:
each chunk-agent owns multiple findings and is expected to return one
tuple per finding it owned, so the combined `--expected $N_deep +
$N_light` value catches both deep-lane Opus collapse and light-lane
chunk-array drops at the helper boundary.

### `/adamsreview:add` — apply the same Phase 4 guard

`/adamsreview:add` runs the same lane-aware Phase 4 validation (without
Wave 2) on injected external findings, using the same
`artifact-patch.py --apply-decisions` plumbing. The helper change covers
it automatically — `commands/add.md`'s Phase 4 invocation passes
`--expected $(( deep_count + light_count ))` so the combined per-
candidate count catches both deep-lane Opus collapse and light-lane
chunk-array drops, same contract as `fragments/05-validation.md` §4.4.

## Implementation sketch

Concrete file-level changes — order is the proposed commit sequence:

1. **`fragments/04-scoring-gate.md` §3.3** — replace per-finding fan-out
   prose with chunked-batch dispatch; add anti-anchor-clustering line
   to the prompt body. Update the "Working-set delta after Phase 3"
   note to say "one tokens.jsonl entry per scoring chunk" instead of
   "per scored finding."
2. **`fragments/05-validation.md` §4.2** — strengthen the per-candidate
   rule; add a sentence pointing at the structural guard.
3. **`fragments/05-validation.md` §4.3** — mirror §3.3's chunk-cap
   prose for light lane.
4. **`fragments/05-validation.md` §4.4** — add `--expected` to the
   `--apply-decisions` invocation; document recovery path on the
   helper-rejected case.
5. **`commands/add.md`** — Phase 4 deep-lane invocation grows
   `--expected <dispatched_count>`; light-lane invocation passes
   `--expected 0` (or omits). Same prose tightening as §4.2 for the
   per-candidate rule.
6. **`bin/artifact-patch.py`** — add `--expected N` flag to the
   `_check_apply_decisions_tuple` path; reject when received tuple count
   < expected with the error-as-prompt convention. ~15 LoC change.
7. **`test/smoke.sh`** — add 2–3 assertions:
   - FR-12-ish: `--apply-decisions @decisions.json --expected 5` with a
     4-tuple file fails with exit 1 and the expected stderr message.
   - FR-13-ish: `--expected 0` (or omitted) accepts any tuple count
     (light-lane / Phase 3 path).
8. **`CLAUDE.md`** — update the §"Pipeline shape" Phase 3 line ("Cheap
   scoring + gate (Sonnet err-up rubric...)") to mention chunk-batched
   dispatch; update Phase 4 line to mention deep-lane structural guard.
   Update the `/adamsreview:add` line to note the same guard applies.

Estimated diff size: ~140 lines across 6 files (`fragments/04-scoring-gate.md`,
`fragments/05-validation.md`, `commands/add.md`, `bin/artifact-patch.py`,
`test/smoke.sh`, `CLAUDE.md`). Smoke-test additions: ~15 lines.

## Process notes for after the change lands

**Don't draw err-up calibration conclusions from pre-change data.**
There's a backlog item in `plans/post-conversion-ideas.md` (#24) about
calibrating the err-up rubric using `demote_rate` and
`score_phase3_histogram` telemetry. Both metrics behave very differently
in anchor-collapsed vs. continuous-scored runs — the histogram in
batched/anchor mode is essentially three bars (25, 50, 75) and
`demote_rate` reflects "how many got bucketed at 25" rather than
"how many fell below the err-up dial." Wait until a handful of
post-change reviews land, then re-examine the histogram and the p3→p4
correlation before tuning err-up.

**Watch the score histogram for a few runs after the prompt fix.** If
batched Sonnet still clusters at anchors despite the explicit anti-
clustering instruction, that's a signal to either (a) tighten the prompt
further, or (b) reconsider the gate-threshold question (see Phase 3
section above — held in reserve, not committed).

## Justifications recap

| Decision | Why |
|---|---|
| Codify Phase 3 batching | 65% silent deviation rate; cost savings real; gate outcome ≈ same |
| Sonnet, not Opus, for batched Phase 3 | Anchor-collapse is a prompt-structure problem; Opus spend better invested at Phase 4 |
| Chunk cap of 25 | Limits attention dilution without forcing N sub-agents on small reviews |
| Anti-anchor-clustering prompt | The observed quality miss (~9% borderline-real bucketed at 25 instead of 50) is a rubric-application failure addressable in the prompt |
| Hold Phase 4 deep per-candidate | Per-finding blast-radius work doesn't share context safely; cost savings are over-estimated by the model |
| Structural `--expected` guard | Prose has been overridden; a helper-side check fails loud rather than silently batching |
| Allow Phase 4 light batching | Same cost/quality shape as Phase 3; rarely emits auto_fixable; precision matters less |
