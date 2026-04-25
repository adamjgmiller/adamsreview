## Phase 3 — Cheap scoring + gate

Chunked-batch Sonnet scoring against the §20 rubric (err-up; up to 25
candidates per chunk-agent), followed by the §13.1 Phase-3 gate that
decides which candidates move on to expensive Phase 4 validation.

Capture `phase_3_start_epoch=$(date +%s)` as the first action of this
phase — §13.5 observability requires an elapsed time on the phases.jsonl
record and step 3.5 below references this variable.

### 3.1. Pre-existing override (highest priority — §13.1)

Before scoring runs, sweep the findings list for pre-existing candidates
that should bypass the Phase-3 gate entirely:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.origin == "pre_existing" and .origin_confidence == "high") | .id]'
```

For each returned id, apply:

```bash
artifact-patch.py \
  --path "$artifact_path" --finding-id "$id" \
  --set disposition=pre_existing_report \
  --set is_actionable=false \
  --set actionability=report_only
```

These findings will NOT be scored in step 3.3 and will NOT enter Phase 4.
Their reason line at render time comes from the `pre_existing_report`
section of the report (§7).

### 3.2. Enumerate scoring candidates

Get every finding that still needs a `score_phase3` (i.e., not pre-existing-
overridden):

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.disposition != "pre_existing_report") | .id]'
```

Capture as `scoring_ids`.

If `scoring_ids` is empty, skip step 3.3 and jump to step 3.4 (gate; may
be all-gate skip too).

### 3.3. Dispatch scoring sub-agents (chunked-batch fan-out)

Split `scoring_ids` into chunks of **at most 25 candidates per chunk**,
balanced as evenly as feasible (e.g. 22 → one chunk of 22; 50 → 25/25;
60 → 20/20/20). For each chunk, launch ONE Sonnet sub-agent. Fire all
chunk-agents from a single orchestrator turn so they run concurrently —
same parallel fan-out pattern as Phase 1 lenses, but at chunk granularity.

**Why chunked, not per-finding.** Per-finding fan-out (one Sonnet per
candidate) was the original design but was empirically too expensive on
typical PRs (20+ candidates → 20+ dispatches) and the orchestrator
self-collapsed to a single batched call anyway, off-spec. A single
unbounded batch lost score resolution (anchor collapse — every score
landing on 0/25/50/75/100 with no intermediate values). The 25-cap
restores parallelism on large reviews and keeps each agent's working
set small enough to use the full 0-100 range. The Phase-3 gate is a
sharp cutoff at 45 — slight per-candidate score loss is tolerable; loss
of triage signal feeding Phase 4 is not.

**Sub-agent prompt** — each chunk-agent receives the full finding JSON
for every candidate in the chunk, the §20 rubric verbatim, the
CLAUDE.md path list, and an explicit anti-anchor-clustering instruction.

Prompt essence:

> Score each of the following candidate findings against the 0-100
> rubric below. Return one entry per candidate.
>
> **Candidates (N total):**
> ```
> <full JSON array of every finding in this chunk>
> ```
>
> **CLAUDE.md paths:** `$claude_md_paths`
>
> **Rubric (0-100):**
>
> | Score | Meaning |
> |---|---|
> | **0** | Not confident. Clear false positive that doesn't stand up to light scrutiny. |
> | **25** | Somewhat confident. Might be real, but more likely a false positive or a stylistic issue not explicitly called out in CLAUDE.md. |
> | **50** | Moderately confident. Verified real, but a nitpick or edge case; not important relative to the rest of the PR. |
> | **75** | Highly confident. Verified real; will likely be hit in practice; directly impacts functionality OR directly violates a CLAUDE.md rule. |
> | **100** | Absolutely certain. Real; will happen frequently; evidence directly confirms. |
>
> **Err-up instruction:** When genuinely uncertain between two adjacent
> levels, pick the HIGHER one. This gate feeds expensive Phase 4
> investigation that filters false positives; the cost of flagging a FP
> here is one Opus agent of investigation. The cost of missing a real
> bug is that the bug ships. Err upward when ambiguous.
>
> **Stylistic-cap rule:** Issues that are stylistic and not explicitly
> called out in CLAUDE.md cap at 25.
>
> **UX note:** UX issues score on the same rubric. A destructive-action
> regression or silent-failure-no-feedback warrants 75+. A minor copy
> tweak or visual inconsistency warrants 25.
>
> **Anti-anchor-clustering instruction (chunk-batch specific):** The
> rubric anchors 0/25/50/75/100 are reference points, NOT the only
> valid scores. Use the full 0-100 range. A finding that sits between
> 50 and 75 should score 60 or 65 — do not snap it to an anchor. If
> half the chunk would naturally land at 50, that is a triage failure:
> resolve which ones are 40, 55, 65, etc. before returning. The
> Phase-3 gate cuts at exactly 45; scores compressed onto anchors lose
> the resolution Phase 4 needs to triage.
>
> Return JSON array, one entry per candidate (order does not matter,
> routing is by `id`):
>
> ```
> [{"id":"<finding-id>","score":<0-100>,"score_rationale":"<one-sentence reason>"}, ...]
> ```

For each chunk-agent's result:

1. **Log tokens** once per chunk-agent (§24.4 invariant; `--finding-id`
   is omitted because tokens are agent-level, not per-finding — the
   chunk dispatched a single sub-agent that scored multiple candidates):

    ```bash
    log-tokens.sh \
      --review-dir "$review_dir" --phase phase_3 \
      --agent-role scoring --agent-id <id-from-result> \
      --model sonnet --tokens <N or null>
    ```

2. **Parse** the JSON array (retry once on parse failure per §24.1).
   On second failure, set `score_phase3=null` for every finding in
   this chunk and append a chunk-level note to `trace.md` — the gate
   in step 3.4 will treat null-score findings as below-gate unless
   they auto-graduate via ≥2 source families.

3. **Validate count and ids.** The result should contain one entry per
   candidate dispatched in this chunk:
   - **Missing ids** (dispatched candidate not in result): set
     `score_phase3=null` for those findings + trace.md note.
   - **Extra ids** (in result but not dispatched): ignore + trace.md
     note (likely a hallucinated candidate id).

4. **Write each score** per finding via `--set` (auto-appends to
   `score_history`):

    ```bash
    artifact-patch.py \
      --path "$artifact_path" --finding-id "$id" \
      --set "score_phase3=$score" \
      --set "reason=$score_rationale"
    ```

    (`reason` at this phase holds the scoring rationale; Phase 4's gate
    application overwrites it with the gate-specific reason if the
    candidate is gated out.)

### 3.4. Apply the Phase-3 gate (§13.1)

For every finding still at the Phase-1 parking disposition:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[]
    | select(.disposition == "pending_validation")
    | {id, score: .score_phase3, families: .source_families}]'
```

For each returned entry, compute:

- `advances_to_phase_4 = (score >= 45) OR (count(distinct source_families) >= 2)`

If `advances_to_phase_4 == true`: leave the candidate's disposition as
`pending_validation` (the §5.2.1 gate-in parking value). Phase 4 will
overwrite with the real verdict. Erase the Phase-3 rationale from
`reason` so it doesn't bleed into the Phase-4 record:

```bash
artifact-patch.py \
  --path "$artifact_path" --finding-id "$id" \
  --set reason=null
```

**Schema note.** `schema-v1.json` requires `disposition` to be a
specific enum value, not null. `pending_validation` is the §5.2.1
enum value that distinguishes gate-in findings (awaiting Phase 4)
from gate-out findings (`below_gate`, locked). Phase 4 overwrites
`pending_validation` with the Phase-4 table verdict
(`confirmed_*` / `disproven` / `uncertain`). Pre-existing high-
confidence findings are already at `pre_existing_report` from step
3.1 and skip this read.

If `advances_to_phase_4 == false`: lock in the gate-out state:

```bash
artifact-patch.py \
  --path "$artifact_path" --finding-id "$id" \
  --set disposition=below_gate \
  --set is_actionable=false \
  --set "reason=below validation gate (score $score)"
```

### 3.5. Log Phase 3 summary

```bash
phase_3_elapsed=$(( $(date +%s) - phase_3_start_epoch ))

gate_pass=$(artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.disposition == "pending_validation")] | length')
gate_fail=$(artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.disposition == "below_gate")] | length')

log-phase.sh \
  --review-dir "$review_dir" --phase 3 --name scoring-gate \
  --elapsed "$phase_3_elapsed" \
  --summary "advanced_to_phase_4=$gate_pass; below_gate=$gate_fail"

# phases.jsonl record: shows counts_by_disposition for the first time
# with the Phase-3 table. (Phase 1 + Phase 2 parked every finding at
# pending_validation; this phase is where below_gate / pre_existing_report
# first appear on gate-fail / override findings respectively.)
#
# Telemetry for post-conversion-ideas #24 calibration: demote_rate (fraction
# gated out of the Phase-3-scored candidates) and score_phase3_histogram
# (10 buckets of width 10 over [0, 100]). These feed the decision on
# whether to tune the Phase 3 err-up rubric. demote_rate is a float in
# [0.0, 1.0]; when no candidates were scored (all routed to pre_existing_report
# in step 3.1) the denominator is zero and we emit 0.0 explicitly.
by_disp=$(artifact-read.sh \
  --path "$artifact_path" --summary \
  | jq -c '.counts_by_disposition')

score_total=$(( gate_pass + gate_fail ))
if [[ "$score_total" -eq 0 ]]; then
    demote_rate="0.0"
else
    demote_rate=$(jq -nc --argjson f "$gate_fail" --argjson t "$score_total" '$f / $t')
fi

# Histogram over the Phase-3-scored population (excludes pre_existing_report
# overrides and null scores from parse failures). Buckets are 0-9, 10-19,
# ..., 80-89, 90-100 (the top bucket is inclusive of 100).
score_phase3_histogram=$(artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.score_phase3 != null) | .score_phase3]' \
  | jq -c '
      . as $scores
      | (reduce range(0;10) as $b ({}; .["\($b*10)-\(if $b==9 then 100 else $b*10+9 end)"] = 0)) as $empty
      | reduce $scores[] as $s ($empty;
          ($s | if . >= 100 then 9 elif . < 0 then 0 else (. / 10 | floor) end) as $b
          | .["\($b*10)-\(if $b==9 then 100 else $b*10+9 end)"] += 1)')

log-phase.sh \
  --review-dir "$review_dir" --phase 3 --record "$(jq -nc \
    --argjson elapsed "$phase_3_elapsed" \
    --argjson pass "$gate_pass" \
    --argjson fail "$gate_fail" \
    --argjson by_disp "$by_disp" \
    --argjson demote_rate "$demote_rate" \
    --argjson histogram "$score_phase3_histogram" \
    '{name:"scoring-gate", elapsed_sec:$elapsed, counts_by_state:{open:($pass+$fail)}, counts_by_disposition:$by_disp, demote_rate:$demote_rate, score_phase3_histogram:$histogram, delta:"\($fail) gated below, \($pass) advanced"}')"
```

### Working-set delta after Phase 3

- Every finding has `score_phase3` set (null only on parse failure).
- Pre-existing high-confidence findings have `disposition=pre_existing_report`.
- Sub-threshold findings have `disposition=below_gate`, `is_actionable=false`.
- Gate-passing findings have `disposition=pending_validation` (the
  §5.2.1 gate-in parking state); Phase 4 overwrites.
- `tokens.jsonl` + one entry per scoring chunk-agent (not per finding —
  a chunk-agent owns up to 25 candidates and logs at agent granularity;
  see §3.3 step 1).
- `phases.jsonl` + Phase 3 record with `counts_by_disposition`,
  `demote_rate` (float), and `score_phase3_histogram` (10 buckets)
  — telemetry for post-conversion-ideas #24 rubric calibration.
