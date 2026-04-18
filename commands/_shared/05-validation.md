## Phase 4 — Validation (lane-aware)

Phase 3's survivors get validated: deep-lane candidates (correctness +
security outside trivial mode) go through Phase 4a — one Opus sub-agent
per candidate. Everything else (plus every candidate under
`trivial_mode`) goes through Phase 4b — one Sonnet sub-agent per
candidate, lighter.

Chain-wave retry (§4): the orchestrator dispatches Wave 1 per
candidate; if any Wave 1 output references further candidates via
`related_candidates_to_investigate`, the orchestrator aggregates
those at the orchestrator level and dispatches Wave 2. Hard cap at
two waves.

Capture `phase_4_start_epoch=$(date +%s)` as the first action of this
phase — step 4.7 logs the elapsed time.

### 4.1. Partition candidates into lanes

Read the phase-3 survivors (findings parked at `pending_validation`;
gate-fail `below_gate` and pre-existing `pre_existing_report` findings
are excluded by the positive filter):

```bash
~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.disposition == "pending_validation") | {id, impact_type, validation_lane}]'
```

If `trivial_mode == true`: force ALL candidates into the light lane.
Per §13.9 + §19.6, light lane under trivial_mode refuses to emit
`auto_fixable` — keeps v1's trivial-mode findings review-only.

Else: partition by `validation_lane` (which was set at Phase 1 based
on `impact_type`):

- `validation_lane == "deep"` → Wave 1 deep lane (Opus).
- `validation_lane == "light"` → Wave 1 light lane (Sonnet).

### 4.2. Wave 1 — deep lane (Opus per candidate; skipped under trivial_mode)

For each deep-lane candidate, launch one `Agent` tool-use with
`model: opus`, `subagent_type: general-purpose`. Dispatch all in one
orchestrator turn for concurrency.

Each sub-agent receives:
- The full candidate JSON (including evidence_snippet).
- `$claude_md_paths` (absolute paths).
- If this is a retry-mode run (Stage 3 context): the finding's prior
  `fix_attempts` for context. In Stage 2 `/adams-review`, `fix_attempts`
  is always empty — noted here for symmetry with Stage 3's retry path.

Prompt essence (per §19.5):

> You are a deep validator. Confirm or disprove this candidate, trace
> its blast radius, and — if real — produce a concrete fix proposal.
>
> **Candidate:** `<finding JSON>`
> **CLAUDE.md paths:** `$claude_md_paths`
>
> Steps:
> 1. **Confirm or disprove.** Trace the claim end-to-end in the code.
>    Read function BODIES, not just signatures. Consult git blame if
>    the history clarifies intent.
> 2. **Trace blast radius.** For every writer, consumer, parallel path,
>    and relevant test — enumerate them in `blast_radius`. A fix that
>    assumes "X is always non-null" breaks when one writer disagrees;
>    find those writers now.
> 3. **Construct reproduction or disproof.** A concrete input / state /
>    call sequence that triggers the bug, OR evidence showing it can't.
> 4. **If real:** produce `fix_proposal.files_to_modify` — every file
>    needing a change, with per-file `what` and `why`. NOT just the
>    obvious site — list every parallel path and consumer that matters.
> 5. **Produce `verification_context`:** `how_to_verify_fix` (specific
>    grep/read commands that confirm the fix landed everywhere),
>    `edge_cases_to_preserve`, `what_would_break_if_incomplete`.
> 6. **Re-score 0-100** using the §20 rubric — based on what you found,
>    not your gut.
> 7. If a related candidate (different bug, related root cause) surfaces
>    during investigation, add it to `related_candidates_to_investigate`
>    with a one-line rationale. Do NOT investigate it yourself — Wave 2
>    will.
>
> Return JSON (shape matches the `validation_result` schema):
> ```
> {
>   "validation_result": {
>     "evidence": [
>       "one sentence per piece of concrete evidence (e.g. file:line — observation)"
>     ],
>     "blast_radius": {
>       "writers": ["file:line — who writes this"],
>       "consumers": ["file:line — who reads this"],
>       "parallel_paths": ["file:line — adjacent paths with the same invariant"],
>       "invariants_at_stake": ["one sentence per invariant the diff stresses"]
>     },
>     "fix_proposal": {
>       "approach": "one or two sentences — the overall strategy",
>       "files_to_modify": [
>         {"file":"src/path.ts", "what":"concrete change", "why":"reason it's required"}
>       ]
>     },
>     "verification_context": {
>       "how_to_verify_fix": ["grep ...", "read ..."],
>       "edge_cases_to_preserve": ["..."],
>       "what_would_break_if_incomplete": ["..."]
>     }
>   },
>   "score_phase4": <0-100>,
>   "decision": "confirmed" | "disproven" | "uncertain",
>   "actionability": "auto_fixable" | "manual" | "report_only",
>   "related_candidates_to_investigate": [
>     {"claim": "...", "file": "...", "line_range": [start, end], "rationale": "..."}
>   ]
> }
> ```
>
> **Every nested array must exist** (can be empty — `[]`) — the schema
> rejects missing keys. `fix_proposal` and `verification_context` are
> only required when `decision == "confirmed"`; when `decision` is
> `"disproven"` or `"uncertain"`, omit the `validation_result` object
> entirely (set it to `null` in the outer return). The orchestrator
> only persists `validation_result` for confirmed findings.

### 4.3. Wave 1 — light lane (Sonnet per candidate)

For each light-lane candidate (including every candidate under
`trivial_mode`), launch one `Agent` tool-use with `model: sonnet`.

Prompt essence (per §19.6):

> You are a light confirmation validator.
>
> **Candidate:** `<finding JSON>`
> **CLAUDE.md paths:** `$claude_md_paths`
> **trivial_mode:** `<true|false>` (when true, do NOT emit `actionability: auto_fixable` — only `manual` or `report_only` per §13.9).
>
> Verify the finding's accuracy only: does the CLAUDE.md really contain
> this rule? Does the adjacent comment really conflict? Adjust score
> accordingly.
>
> Flag `actionability: auto_fixable` ONLY for very mechanical rules
> where the fix is unambiguous (e.g. import ordering, specific constant
> naming). Judgment calls → `manual`. Architecture findings default to
> `report_only`.
>
> Return JSON:
> ```
> {
>   "decision": "confirmed" | "disproven" | "uncertain",
>   "score_phase4": <0-100>,
>   "actionability": "auto_fixable" | "manual" | "report_only",
>   "note": "brief rationale"
> }
> ```

### 4.4. Apply §13.1 Phase-4 decision table (per candidate)

For each Wave 1 result, first log tokens:

```bash
~/.claude/commands/_shared/tools/log-tokens.sh \
  --review-dir "$review_dir" --phase <phase_4a|phase_4b> \
  --agent-role validator --finding-id "$id" \
  --agent-id <id> --model <opus|sonnet> \
  --tokens <N or null>
```

Then apply the decision table. Derive inputs from the sub-agent's
return:

| Score | Rule | Disposition | is_actionable | Other |
|---|---|---|---|---|
| `< 45` | disproven | `disproven` | false | reason: "disproven by Phase 4: <summary>" |
| `45-59` | uncertain | `uncertain` | false | reason: "uncertain (Phase 4 inconclusive)" |
| `60-74` AND `actionability=auto_fixable` | | `confirmed_auto` | true | confirmed_strength: moderate |
| `60-74` AND `actionability=manual` | | `confirmed_manual` | false | confirmed_strength: moderate |
| `60-74` AND `actionability=report_only` | | `confirmed_report` | false | confirmed_strength: moderate |
| `75+` AND `actionability=auto_fixable` | | `confirmed_auto` | true | confirmed_strength: strong |
| `75+` AND `actionability=manual` | | `confirmed_manual` | false | confirmed_strength: strong |
| `75+` AND `actionability=report_only` | | `confirmed_report` | false | confirmed_strength: strong |

Apply via one `artifact-patch.py` call per finding. Example for
`score=72, actionability=auto_fixable`:

```bash
~/.claude/commands/_shared/tools/artifact-patch.py \
  --path "$artifact_path" --finding-id "$id" \
  --set "score_phase4=72" \
  --set disposition=confirmed_auto \
  --set confirmed_strength=moderate \
  --set actionability=auto_fixable \
  --set reason=null
```

For deep-lane candidates whose `decision == "confirmed"`, ALSO persist
`validation_result`:

```bash
# Only confirmed findings get validation_result — disproven/uncertain
# skip the write (their reason line is enough). Schema requires every
# nested field of validation_result to be non-null, so writing a
# partial object for uncertain findings would fail validation.
if [[ "$decision" == "confirmed" ]]; then
    ~/.claude/commands/_shared/tools/artifact-patch.py \
      --path "$artifact_path" --finding-id "$id" \
      --set-json "validation_result=@/tmp/val-$id.json"
fi
rm -f "/tmp/val-$id.json"
```

(Write the validation_result JSON to a temp file first; the `@file`
form avoids quoting hell on large objects.)

On score parse failure (sub-agent returned unparseable JSON even after
one retry): leave `score_phase4=null`, set `disposition=uncertain`,
`reason="Phase 4 parse failure — manual review"`.

### 4.5. Wave 2 (chain retry — optional)

After Wave 1 completes, collect every
`related_candidates_to_investigate` entry from Wave 1 deep-lane outputs.
Dedup by (file, line_range, claim-fingerprint — a short prefix or
hash). Drop any entry that overlaps substantially with an existing
finding (since that was already investigated).

If the resulting list is non-empty AND we haven't already done Wave 2:

1. Add each new candidate to the artifact via `--add-finding` (continuing
   the F0xx sequence) with `source_family: "structural-family"` (the Wave
   1 finding's source family, really; `related_parent_finding_id` set to
   the Wave 1 parent).
2. Run Phase 3 scoring on these new candidates (one Sonnet call each —
   can fan out).
3. Dispatch Wave 2 deep-lane validators on any that pass the Phase-3
   gate, same prompt as Wave 1 BUT add: "This is Wave 2 — do NOT emit
   further `related_candidates_to_investigate` entries." (Hard-cap
   enforcement: §4 says "Hard cap at 2 waves.")
4. Apply the decision table per step 4.4 for Wave 2 results.

If the list is empty, proceed to step 4.6.

### 4.6. Pre-existing override re-assertion (§13.1)

After Phase 4 completes, sweep the findings list one more time:

```bash
~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.origin == "pre_existing" and .origin_confidence == "high" and .disposition != "pre_existing_report") | .id]'
```

This catches cases where Phase 4a's deep validation bumped a pre-existing
finding's score into the confirmed band — the pre-existing rule trumps.
For each returned id:

```bash
~/.claude/commands/_shared/tools/artifact-patch.py \
  --path "$artifact_path" --finding-id "$id" \
  --set disposition=pre_existing_report \
  --set is_actionable=false \
  --set actionability=report_only \
  --set confirmed_strength=null \
  --set reason=null
```

(The validation_result stays on the finding — it's still valuable context
for the user in the report — but the disposition forces it out of the
actionable path.)

### 4.7. Log Phase 4 summary

```bash
phase_4_elapsed=$(( $(date +%s) - phase_4_start_epoch ))

by_disp=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_disposition')

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 4 --name validation \
  --elapsed "$phase_4_elapsed" \
  --summary "$(jq -nc --argjson by_disp "$by_disp" '$by_disp | to_entries | map("\(.key)=\(.value)") | join(", ")')"

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 4 --record "$(jq -nc \
    --argjson elapsed "$phase_4_elapsed" \
    --argjson by_disp "$by_disp" \
    --argjson total_open "$(~/.claude/commands/_shared/tools/artifact-read.sh --path "$artifact_path" --filter '[.findings[] | select(.current_state == "open")] | length')" \
    '{name:"validation", elapsed_sec:$elapsed, counts_by_state:{open:$total_open}, counts_by_disposition:$by_disp, delta:"<summarize e.g. +9 confirmed_auto, -5 disproven>"}')"
```

### Working-set delta after Phase 4

- Every non-pre-existing, non-below-gate finding has `score_phase4` set
  and a final `disposition` from the §13.1 Phase-4 table.
- Deep-lane confirmed findings have `validation_result` populated
  (evidence, blast_radius, fix_proposal, verification_context).
- Light-lane confirmed findings have `actionability` (rarely
  `auto_fixable`; mostly `manual`/`report_only`, and never
  `auto_fixable` under trivial_mode).
- Pre-existing high-confidence findings are re-asserted to
  `pre_existing_report` regardless of Phase 4 verdict.
- `tokens.jsonl` + one entry per Wave-1 + Wave-2 sub-agent.
- `phases.jsonl` + Phase 4 record with the first deeply-populated
  `counts_by_disposition`.
