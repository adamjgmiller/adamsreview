## Phase 5.5 — Auto-fix-hint generation

A two-pass Sonnet generation+verification chain produces an
`auto_fix_hint` per eligible finding — pre-computing what
`/adamsreview:walkthrough`'s per-finding briefer would write so that
downstream `/adamsreview:fix` and `:walkthrough` can surface a
batch-confirm UI instead of a per-finding interactive loop.

Runs after Phase 5 cross-cutting and before Phase 6 finalize. Single
fragment for both `:review` and `:codex-review` — the work is
downstream of either validator and is Sonnet-driven, so there is no
Claude / Codex split here.

Capture `phase_5_5_start_epoch=$(date +%s)` as the first action of
this phase — step 5.5.5 logs the elapsed time.

### 5.5.0. Compute eligibility

Capture the pre-phase `auto_fix_hint` count BEFORE any work — §5.5.5
uses this to compute the delta this phase actually contributed (so
`:add` reruns don't over-report when `:review` already populated some
hints):

```bash
hints_before=$(artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.auto_fix_hint != null)] | length')
```

Read findings that qualify per the umbrella's predicate
(`current_state == "open"` AND `human_confirmation == null` AND
`auto_fix_hint == null` AND disposition ∈ {`confirmed_manual`,
`confirmed_report`, `confirmed_mechanical`} AND `score_phase4 >= 60`
AND disposition ≠ `pre_existing_report`):

Lane is **not** gated here. Without this widening, dedup-induced
lane/impact_type mismatches (a finding deduplicated from both a
security lens and a ux lens lands with `lane=deep` + `impact_type=ux`)
fall into a gap: Phase 8 excludes them via the `impact_type` filter,
and Phase 5.5 used to exclude them via the lane filter — leaving
no automated path to fix them. Generating a hint here lets Phase 7.5
surface those findings in the batch preflight: if the user accepts,
`human_confirmation` is set and Phase 8 bypasses the `impact_type`
filter; if the user declines, the finding stays at `current_state=open`
and must be resolved via `:walkthrough` or `:promote` (Phase 8's
`impact_type` filter alone does NOT pick up mismatched cases on the
decline path).

<!-- AFH-PREDICATE-START -->
```bash
eligible_findings=$(artifact-read.sh \
  --path "$artifact_path" \
  --filter '
    [.findings[]
       | select(.current_state == "open")
       | select(.human_confirmation == null)
       | select(.auto_fix_hint == null)
       | select(.disposition != "pre_existing_report")
       | select(
           (.disposition == "confirmed_manual")
           or (.disposition == "confirmed_report")
           or (.disposition == "confirmed_mechanical")
         )
       | select(.score_phase4 != null and .score_phase4 >= 60)
       | {id, file, line_range, claim, disposition, validation_lane, score_phase4, impact_type, validation_result}]
  ')
eligible_count=$(printf '%s' "$eligible_findings" | jq 'length')
```
<!-- AFH-PREDICATE-END -->

The block above is the canonical Phase 5.5 eligibility predicate.
Fence markers (`AFH-PREDICATE-START` / `AFH-PREDICATE-END`) are
load-bearing — `test/smoke.sh` AFH-13 extracts this block via awk and
executes it against a synthetic artifact, so any drift in the
predicate is caught behaviorally rather than by string match. Keep
the fences exactly as written; relocate the predicate only by moving
both fences together.

If `eligible_count == 0`, skip the rest of this phase:

```bash
log-phase.sh \
  --review-dir "$review_dir" --phase 5_5 --name auto-fix-hint \
  --elapsed 0 \
  --summary "skipped — no eligible findings"

log-phase.sh \
  --review-dir "$review_dir" --phase 5_5 --record "$(jq -nc \
    '{name:"auto-fix-hint", elapsed_sec:0, counts_by_state:{}, counts_by_disposition:{}, delta:"skipped — no eligible findings"}')"
```

Jump to Phase 6. Otherwise proceed.

### 5.5.1. Chunk eligible findings

Split into chunks of at most 10 candidates per chunk. Each chunk
becomes one generation sub-agent and one verification sub-agent
downstream:

```bash
mkdir -p "$review_dir/phase5_5_chunks"
chunk_size=10
chunk_count=$(( (eligible_count + chunk_size - 1) / chunk_size ))

i=0
while [[ "$i" -lt "$chunk_count" ]]; do
    start=$(( i * chunk_size ))
    chunk_id=$(printf 'chunk-%02d' "$i")
    printf '%s' "$eligible_findings" \
      | jq --argjson start "$start" --argjson size "$chunk_size" \
            '[.[$start:($start + $size)][]]' \
      > "$review_dir/phase5_5_chunks/${chunk_id}.json"
    i=$(( i + 1 ))
done
```

The verification pass (§5.5.3) reads the same chunk file plus the
gen pass's output for the chunk; it does NOT see the proposer's
self-critique — independence is the second-opinion mechanism.

### 5.5.2. Generation pass — one Sonnet sub-agent per chunk

★ **Parallel dispatch — load-bearing.** Issue every generation
sub-agent's `Agent` tool-use in a SINGLE orchestrator turn so they
run concurrently. Phase 5.5 wall-clock latency is
`max(chunk_durations) * 2` (gen + verify), not
`sum(chunk_durations) * 2`. Treating each chunk as its own turn
serializes the lane.

For each chunk file, launch ONE `Agent` tool-use with `model: sonnet`,
`subagent_type: general-purpose`. Each gen sub-agent receives the
chunk's findings (file content), `claude_md_paths` (absolute paths
captured in Phase 0), and `repo_root`.

Sub-agent contract (orchestrator constructs the actual prompt at
dispatch time):

1. **Propose** a 1–3 sentence fix direction per finding. Anchor on the
   validator's `fix_proposal.approach` when present; otherwise reason
   from the claim and `validation_result` evidence. The hint must be
   concrete enough to drop into `human_confirmation.fix_hint` and
   steer a Phase 8 fix-group agent.
2. **Self-critique** in one paragraph (consumed internally; not
   returned): blast-radius issues, tone/policy concerns, ambiguity.
3. **Finalize** the hint and assign `confidence_self` ∈ {high, medium,
   low} based on the self-critique outcome.
4. Optionally produce up to 2 `alternatives`, each
   `{label: "B"|"C", title, hint}`.

Token budget: ≤4k output per chunk (10 findings × ~400 chars).

Sub-agent return: strict JSON array, no surrounding prose, no code
fences. One entry per finding: `{id, hint, confidence_self,
alternatives?}`. The proposer's self-critique is NOT returned — the
verification pass operates on the hint alone.

After each gen sub-agent returns, log tokens and save the parsed
output:

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_5_5_gen \
  --agent-role auto_fix_hint_gen \
  --agent-id <id-from-Agent-result> --model sonnet \
  --tokens <N or null>
```

Light JSON repair + one retry per `_prelude-shared.md` §1. On second
parse failure, drop that chunk's findings from the rest of the phase
and append `phase_5_5_gen_chunk_dropped: chunk=<chunk_id>
reason=unparseable` to `$trace_log_path`.

Save each chunk's parsed output to
`$review_dir/phase5_5_chunks/${chunk_id}-gen.json`.

### 5.5.3. Verification pass — one Sonnet sub-agent per chunk

★ **Parallel dispatch — load-bearing.** Same parallelism contract as
§5.5.2. Verification depends on generation having returned, but the
verification sub-agents are independent of one another — fan them out
in a SINGLE orchestrator turn.

For each chunk that has a `${chunk_id}-gen.json` file (chunks dropped
in §5.5.2 are skipped here), launch ONE `Agent` tool-use with
`model: sonnet`. Each verify sub-agent receives:

- The chunk's original findings (`${chunk_id}.json`).
- The gen pass's hints for that chunk (`${chunk_id}-gen.json`) —
  hint, alternatives, id ONLY (the proposer's self-critique and
  `confidence_self` are not exposed).

Sub-agent contract: for each hint, independently review whether it
matches the actual problem, preserves
`validation_result.verification_context.edge_cases_to_preserve`,
covers `blast_radius` parallel paths, and is unambiguous enough for a
Phase 8 fix-group agent.

Return per finding: `second_opinion` ∈ {concurs, concerns},
`concerns` (array of strings — required non-empty when concerns,
omitted otherwise), and `confidence_verified` ∈ {high, medium, low}
assigned independently (no copy of the proposer's self-confidence).

Sub-agent return: strict JSON array `[{id, second_opinion, concerns?,
confidence_verified}, ...]`.

After each verify sub-agent returns:

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_5_5_verify \
  --agent-role auto_fix_hint_verify \
  --agent-id <id-from-Agent-result> --model sonnet \
  --tokens <N or null>
```

Light JSON repair + one retry per `_prelude-shared.md` §1. On second
parse failure, drop the chunk's findings from §5.5.4 and append
`phase_5_5_verify_chunk_dropped: chunk=<chunk_id> reason=unparseable`
to `$trace_log_path`.

Save each chunk's parsed output to
`$review_dir/phase5_5_chunks/${chunk_id}-verify.json`.

### 5.5.4. Merge generation + verification, apply

For each finding present in BOTH a gen file AND its verify file
(matched by `id`), build the final `auto_fix_hint` payload entry:

- `hint` — gen pass's hint
- `alternatives` — gen pass's alternatives (only when present)
- `second_opinion` — verify pass's verdict
- `concerns` — verify pass's concerns (only when
  `second_opinion == "concerns"`; omit otherwise — the helper schema
  rejects an empty concerns array on a "concurs" verdict)
- `confidence` — min of `confidence_self` and `confidence_verified`,
  ordered high > medium > low. {high, low} ⇒ low; {medium, medium}
  ⇒ medium. The min rule preserves the weaker signal.

Build the merged payload and write to `$review_dir/phase5_5_merged.json`:

```bash
merged_all="[]"
for chunk_file in "$review_dir"/phase5_5_chunks/chunk-*-gen.json; do
    chunk_id=$(basename "$chunk_file" -gen.json)
    verify_file="$review_dir/phase5_5_chunks/${chunk_id}-verify.json"
    [[ -f "$verify_file" ]] || continue

    chunk_merged=$(jq -nc \
        --slurpfile gen "$chunk_file" \
        --slurpfile ver "$verify_file" \
        '
        ($ver[0] | map({key: .id, value: .}) | from_entries) as $vmap
        | $gen[0]
        | map(. as $g
              | $vmap[$g.id] as $v
              | select($v != null)
              | {
                  id: $g.id,
                  hint: $g.hint,
                  confidence: (
                    [$g.confidence_self, $v.confidence_verified]
                    | map(if . == "high" then 3 elif . == "medium" then 2 else 1 end)
                    | min
                    | if . == 3 then "high" elif . == 2 then "medium" else "low" end
                  ),
                  second_opinion: $v.second_opinion
                }
              + (if $v.second_opinion == "concerns" and ($v.concerns // [] | length) > 0
                 then {concerns: $v.concerns} else {} end)
              + (if ($g.alternatives // [] | length) > 0
                 then {alternatives: $g.alternatives} else {} end)
             )
        ')

    merged_all=$(jq -nc --argjson a "$merged_all" --argjson b "$chunk_merged" \
        '$a + $b')
done

printf '%s\n' "$merged_all" > "$review_dir/phase5_5_merged.json"
merged_count=$(printf '%s' "$merged_all" | jq 'length')
```

Apply via the existing helper. Continue-on-error is intentional —
findings whose state shifted between dispatch and patch (e.g.,
concurrent `:add` mutating the artifact) surface as
`auto-fix-hints-rejected:` lines on stderr without aborting:

```bash
out=$(artifact-patch.py \
    --path "$artifact_path" \
    --apply-auto-fix-hints "@$review_dir/phase5_5_merged.json" \
    2>&1) || true
printf '%s\n' "$out"
```

The helper writes its own `## auto_fix_hint (<ts>)` block to `trace.md`
per its contract — no extra trace appending needed here.

Clean up the chunk scratch directory:

```bash
rm -rf -- "$review_dir/phase5_5_chunks"
rm -f -- "$review_dir/phase5_5_merged.json"
```

### 5.5.5. Log Phase 5.5 summary

```bash
phase_5_5_elapsed=$(( $(date +%s) - phase_5_5_start_epoch ))
hints_set=$(artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.auto_fix_hint != null)] | length')
hints_added=$(( hints_set - hints_before ))

log-phase.sh \
  --review-dir "$review_dir" --phase 5_5 --name auto-fix-hint \
  --elapsed "$phase_5_5_elapsed" \
  --summary "eligible=$eligible_count chunks=$chunk_count merged=$merged_count hints_set=$hints_set hints_added=$hints_added"

log-phase.sh \
  --review-dir "$review_dir" --phase 5_5 --record "$(jq -nc \
    --argjson elapsed "$phase_5_5_elapsed" \
    --argjson eligible "$eligible_count" \
    --argjson chunks "$chunk_count" \
    --argjson merged "$merged_count" \
    --argjson hints_set "$hints_set" \
    --argjson hints_added "$hints_added" \
    '{name:"auto-fix-hint", elapsed_sec:$elapsed, counts_by_state:{}, counts_by_disposition:{}, eligible:$eligible, chunks:$chunks, merged:$merged, hints_set:$hints_set, hints_added:$hints_added, delta:"+\($hints_added) auto_fix_hint set (now \($hints_set) total)"}')"
```

`hints_set` is read from the artifact post-apply (not from the merged
count) so it reflects what actually landed after the helper's
continue-on-error filtering — downstream consumers see the same
number. `hints_added` is the delta this phase contributed
(`hints_set - hints_before`, where `hints_before` was captured in
§5.5.0 before any work ran); `hints_set` is the cumulative count
across all reviews. The split keeps `:add` reruns from over-reporting
when a prior `:review` already populated some hints — the delta line
shows only what THIS phase added, while the cumulative total stays
visible for downstream consumers.
