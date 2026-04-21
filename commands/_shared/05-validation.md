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
- The full stored finding JSON. `evidence_snippet` is not among the
  stored fields — the validator works from `file + line_range + claim`
  plus the Read/grep tools it uses to look at the diff directly.
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
> **Read-only.** Do not use `Edit` or `Write`, and do not run Bash that
> mutates the tree (no `git checkout`, no `git restore`, no writes into
> tracked paths). If a fix is warranted, describe it in `fix_proposal` —
> Phase 8 applies it. Any working-tree changes you make will be reverted
> before Phase 5.
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
> 4. **If real: produce `fix_proposal.files_to_modify` — the full class,
>    not just the obvious site.**
>    - Cross-check against `blast_radius.parallel_paths` you just
>      enumerated. Every entry that exhibits the same invariant
>      violation MUST appear in `files_to_modify`.
>    - Grep the repo for in-repo precedent — if another file already
>      implements the correct pattern (e.g. a null-safe COALESCE, a
>      strict-regex parser, a non-TTY guard), cite that file:line and
>      apply the same shape across every site you list.
>    - A fix that addresses only the discovered site is a partial fix —
>      it will surface again on the next review as a new finding. Err
>      wide; Phase 8's fix-group agent will follow the scope you set.
> 5. **Produce `verification_context`:** `how_to_verify_fix` (specific
>    grep/read commands that confirm the fix landed everywhere),
>    `edge_cases_to_preserve`, `what_would_break_if_incomplete`.
> 6. **Re-score 0-100** using the §20 rubric — based on what you found,
>    not your gut.
> 7. **Related candidates — sweep actively, not just opportunistically.**
>    Before returning, run a deliberate adjacent-bug sweep and list
>    every candidate in `related_candidates_to_investigate[]` (even
>    half-confident ones — Phase 3 filters weak candidates). Two
>    radii, both mandatory:
>    - **Same-block (±10 lines around the confirmed site).** Reread
>      the surrounding code with a skeptical eye. Common adjacents:
>      a filter predicate that misses a value the fix must handle
>      (negative, zero, NULL, duplicate-key fan-out); a sibling
>      if/else branch with a matching gap; a second call site in the
>      same function with the same missing guard; a parallel parser
>      with diverged strictness. Co-located bugs usually share a fix
>      and are cheapest to surface now.
>    - **Elsewhere in the traced code path.** Anything with a related
>      root cause (different bug, same underlying invariant break)
>      you noticed while walking blast radius.
>
>    Do NOT investigate any of these yourself — Wave 2 will.
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
> **Read-only.** Do not use `Edit` or `Write`; describe any needed
> change in the finding — it's not yours to apply.
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

### 4.4. Apply §13.1 Phase-4 decision table (batched)

For each Wave 1 result, first log tokens:

```bash
~/.claude/commands/_shared/tools/log-tokens.sh \
  --review-dir "$review_dir" --phase <phase_4a|phase_4b> \
  --agent-role validator --finding-id "$id" \
  --agent-id <id> --model <opus|sonnet> \
  --tokens <N or null>
```

Then collect every Wave 1 sub-agent response into a single JSON array
and hand it to `artifact-patch.py --apply-decisions` in one call. The
helper derives `disposition`, `is_actionable`, `confirmed_strength`,
and default `reason` per §13.1 internally (Stage 2.5.B clarification,
DESIGN §21.2). This collapses what was previously a per-finding loop
of `--set … --set-json validation_result=@…` invocations into one
helper invocation per wave, so the orchestrator's working context
sees a single summary line instead of N per-finding prose blocks.

**Derivation (performed by `--apply-decisions`):**

| Score | Rule | Disposition | is_actionable | Other |
|---|---|---|---|---|
| `null` | parse failure | `uncertain` | false | reason default: "uncertain (Phase 4 inconclusive)" |
| `< 45` | disproven | `disproven` | false | reason default: "disproven by Phase 4" |
| `45-59` | uncertain | `uncertain` | false | reason default: "uncertain (Phase 4 inconclusive)" |
| `60-74` AND `actionability=auto_fixable` | | `confirmed_auto` | true | confirmed_strength: moderate |
| `60-74` AND `actionability=manual` | | `confirmed_manual` | false | confirmed_strength: moderate |
| `60-74` AND `actionability=report_only` | | `confirmed_report` | false | confirmed_strength: moderate |
| `75+` AND `actionability=auto_fixable` | | `confirmed_auto` | true | confirmed_strength: strong |
| `75+` AND `actionability=manual` | | `confirmed_manual` | false | confirmed_strength: strong |
| `75+` AND `actionability=report_only` | | `confirmed_report` | false | confirmed_strength: strong |

The helper applies `score_phase4` takes-precedence-over-`decision`
automatically: derivation runs off `score_phase4 + actionability`, so
a validator returning `decision: "confirmed", score_phase4: 40` routes
to `disproven` via the score row; `decision: "disproven",
score_phase4: 70, actionability: "auto_fixable"` routes to
`confirmed_auto`. Validators shouldn't emit such mismatches, but when
they do the structured fields win. Include the raw `decision` field
in each tuple for audit-trail legibility — it's accepted by the helper
but not authoritative.

**Building the batch.** For each Wave-1 validator response, compose
one tuple. `validation_result` in the tuple comes from the sub-agent's
outer response envelope — extract the nested object (the inner
`validation_result` value, or the whole response if it's already the
inner object). Pass the sub-agent's `reason` through when it provides
one; otherwise let the helper fill the disposition-appropriate default.
The helper writes `validation_result` only when the derived
disposition lands in the confirmed band; pass it for every deep-lane
tuple — uncertain / disproven tuples have it silently ignored.

**The contract is the output, not the technique.** Agent tool results
land in orchestrator context, not a shell variable, so there's no
single "right" way to marshal them. Compose the tuple array however is
natural — a direct `Write` of the assembled JSON array, a `jq`
pipeline, or an inline helper script — and emit it to
`$scratch/phase4-wave1-decisions.json` (inside the per-review scratch
dir, so Phase 4's trailing cleanup at the end of §4.6 removes it and
any co-located ad-hoc helper you wrote). Then invoke the helper on
that path.

Tuple shape (the helper rejects unknown keys; `id` is required;
`actionability` is required when `score_phase4 >= 60`; everything else
is optional and gets a sensible default):

```json
[
  {
    "id": "F001",
    "score_phase4": 72,
    "decision": "confirmed",
    "actionability": "auto_fixable",
    "reason": "optional — omit to let the helper fill the default",
    "validation_result": { "evidence": [...], "blast_radius": {...}, "fix_proposal": {...}, "verification_context": {...} }
  }
]
```

`validation_result` is `null` for light-lane tuples and for deep-lane
disproven / uncertain tuples. Deep-lane confirmed tuples carry the
full nested object.

```bash
scratch="/tmp/adams-review-$review_id"
mkdir -p "$scratch"

# Compose the tuple array in orchestrator context and write it to
# $scratch/phase4-wave1-decisions.json by whatever means is natural.
# The helper only cares about the file path + tuple shape above.

out=$(~/.claude/commands/_shared/tools/artifact-patch.py \
        --path "$artifact_path" \
        --apply-decisions "@$scratch/phase4-wave1-decisions.json")
echo "$out"  # e.g. "applied 18 decisions (confirmed_auto=4, confirmed_manual=1, confirmed_report=0, uncertain=3, disproven=10)"
```

**On score parse failure** (sub-agent returned unparseable JSON even
after one retry): emit `score_phase4: null` in the tuple and the
helper routes to `uncertain` automatically. Override the default
reason by including `reason: "Phase 4 parse failure — manual review"`
in that tuple so the rendered report explains why Phase 4 didn't
confirm.

**On apply-decisions exit non-zero:** the batch halted at the first
invalid tuple (stderr names the failing finding id). Tuples preceding
the failure are already committed to the artifact. Fix the offending
tuple and re-invoke with just the remainder; do NOT re-send the whole
batch (the committed tuples would be re-applied, and `_apply_finding_set`
would re-append score_history entries — audit-trail pollution).

### 4.4.5. Tree-cleanliness sweep (belt-and-braces for the read-only preamble)

After `--apply-decisions` returns for Wave 1 (and again for Wave 2
per §4.5 step 4), run a `git status --porcelain` sweep. Validators have no
legitimate reason to touch the working tree — the 4.2 / 4.3 prompts
already forbid it. This catches a prompt-override and restores the
tree before Phase 5 so a misbehaving validator cannot poison the
commit `/adams-review-fix` will later produce.

```bash
dirty=$(git -C "$repo_root" status --porcelain 2>/dev/null)
if [[ -n "$dirty" ]]; then
    printf 'phase_4_tree_dirty_reverted: %s\n' \
        "$(printf '%s\n' "$dirty" | awk '{print $2}' | paste -sd, -)" \
        >> "$trace_log_path"
    # Restore tracked-file modifications.
    git -C "$repo_root" checkout -- . 2>/dev/null || true
    # Remove anything the sub-agent created that git doesn't know about.
    printf '%s\n' "$dirty" | awk '/^\?\?/ {print $2}' \
        | while IFS= read -r p; do rm -f "$repo_root/$p"; done
fi
```

Invariant: Phase 0's dirty-tree gate clears the tree before Phase 1,
and Phases 1–5 are tree-read-only (artifact writes happen in
`$review_dir`, not in `$repo_root`). Anything `status --porcelain`
surfaces here is therefore validator-sourced and safely revertable.
The trace tag `phase_4_tree_dirty_reverted:` surfaces the incident
for post-mortem.

### 4.5. Wave 2 (chain retry — optional)

After Wave 1 completes, collect every
`related_candidates_to_investigate` entry from Wave 1 deep-lane outputs.
Dedup by (file, line_range, claim-fingerprint — a short prefix or
hash). Drop any entry that overlaps substantially with an existing
finding (since that was already investigated).

If the resulting list is non-empty AND we haven't already done Wave 2:

1. For each related candidate, **build a full schema-valid finding
   object** (same transformation the Phase-1 jq builder does — schema's
   `additionalProperties: false` rejects singular `source_family` and
   requires every finding field to be present). Example:

   ```bash
   wave2_finding=$(jq -n \
     --arg id "F$(printf '%03d' $finding_counter)" \
     --arg parent "$parent_finding_id" \
     --argjson cand "$related_candidate" \
     '{
        id: $id,
        sources: ["L2-structural"],            # Wave 2 is structural-derived
        source_families: ["structural-family"],
        impact_type: ($cand.impact_type // "correctness"),
        origin: ($cand.origin // "introduced_by_pr"),
        origin_confidence: ($cand.origin_confidence // "medium"),
        actionability: "auto_fixable",
        validation_lane: "deep",
        current_state: "open",
        disposition: "pending_validation",
        is_actionable: false,
        reason: null,
        confirmed_strength: null,
        file: $cand.file,
        line_range: ($cand.line_range // [1,1]),
        claim: $cand.claim,
        score_phase3: null,
        score_phase4: null,
        score_history: [],
        validation_result: null,
        fix_attempts: [],
        introduced_in_sha: null,
        suggested_follow_up: null,
        related_parent_finding_id: $parent
      }')

   ~/.claude/commands/_shared/tools/artifact-patch.py \
     --path "$artifact_path" --add-finding "$wave2_finding"
   ```

2. Run Phase 3 scoring on these new candidates (one Sonnet call each —
   can fan out). Same step 3.3 pattern as the first pass.
3. Dispatch Wave 2 deep-lane validators on any that pass the Phase-3
   gate, same prompt as Wave 1 BUT add: "This is Wave 2 — do NOT emit
   further `related_candidates_to_investigate` entries." (Hard-cap
   enforcement: §4 says "Hard cap at 2 waves.")
4. Apply the decision table per step 4.4 for Wave 2 results — build
   a second tuple array at `$scratch/phase4-wave2-decisions.json` and
   invoke `--apply-decisions @…` once for the whole Wave 2 batch.
   Re-run the step 4.4.5 tree-cleanliness sweep after this
   `--apply-decisions` returns — Wave 2 validators are dispatched with
   the same prompt as Wave 1, so the same read-only invariant applies.

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

Then clean up Phase 4's scratch dir (parallels Phase 1.5's cleanup of
the same path in `02-ensemble-adapter.md`). Reference the literal path
rather than `$scratch` — §4.4 may not have run if Phase 3 gated every
candidate out:

```bash
rm -rf -- "/tmp/adams-review-$review_id"
```

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
