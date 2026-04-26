## Phase 4 — Validation (lane-aware)

Phase 3's survivors get validated: deep-lane candidates (correctness +
security outside trivial mode) go through Phase 4a — one Opus sub-agent
per candidate. Everything else (plus every candidate under
`trivial_mode`) goes through Phase 4b — chunked-batch Sonnet
chunk-agents (≤25 candidates per chunk; see §4.3), lighter.

Chain-wave retry (§4): the orchestrator dispatches Wave 1 (deep
per-candidate + light chunked-batch); if any Wave 1 deep output
references further candidates via `related_candidates_to_investigate`,
the orchestrator aggregates those at the orchestrator level and
dispatches Wave 2. Hard cap at two waves. Wave 2 is deep-lane only,
one Opus per candidate.

Capture `phase_4_start_epoch=$(date +%s)` as the first action of this
phase — step 4.7 logs the elapsed time.

### 4.1. Partition candidates into lanes

Read the phase-3 survivors (findings parked at `pending_validation`;
gate-fail `below_gate` and pre-existing `pre_existing_report` findings
are excluded by the positive filter):

```bash
artifact-read.sh \
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

For each deep-lane candidate, launch ONE `Agent` tool-use with
`model: opus`, `subagent_type: general-purpose`. Dispatch all in one
orchestrator turn for concurrency.

**One Opus per candidate — never collapse multiple deep-lane candidates
into a single batched Opus call.** Each candidate needs its own
independent blast-radius trace, evidence walk, and fix-proposal
synthesis; that investigation does not share context across candidates
the way Phase 3's rubric scoring does, and batching collapses
per-candidate depth. The §4.4 `--apply-decisions --expected $N` guard
catches one class of violation: if fewer tuples arrive than dispatched
candidates, the helper rejects the batch with a recovery action (see
§4.4). It does not detect collapse-then-correct-unwrap, where the
orchestrator batches multiple candidates into one Opus call but emits
the right count by unwrapping the response itself.

Each sub-agent receives:
- The full stored finding JSON. `evidence_snippet` is not among the
  stored fields — the validator works from `file + line_range + claim`
  plus the Read/grep tools it uses to look at the diff directly.
- `$claude_md_paths` (absolute paths).
- If this is a retry-mode run (Stage 3 context): the finding's prior
  `fix_attempts` for context. In Stage 2 `/adamsreview:review`, `fix_attempts`
  is always empty — noted here for symmetry with Stage 3's retry path.

Prompt essence (per §19.5):

> You are a deep validator. Confirm or disprove this candidate, trace
> its blast radius, and — if real — produce a concrete fix proposal.
>
> **Scoring contract.** Your `score_phase4` is a single integer 0-100
> per the §20 rubric. Do not output a 1-5 or 1-10 scale, a float, or
> a severity keyword — the orchestrator consumes the integer directly
> and mis-scaled scores silently route findings to the wrong band.
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
>
> **Exact inner keys — no substitutions.** The canonical shape is
> defined at `bin/schema-v1.json` lines 330-393 (`#/$defs/validation_result`
> + `#/$defs/fix_proposal`). Required keys, verbatim:
>
> - `validation_result.evidence` (array of strings)
> - `validation_result.blast_radius.writers` (array of strings)
> - `validation_result.blast_radius.consumers` (array of strings)
> - `validation_result.blast_radius.parallel_paths` (array of strings)
> - `validation_result.blast_radius.invariants_at_stake` (array of strings)
> - `validation_result.fix_proposal.approach` (string — non-empty when `decision == "confirmed"`)
> - `validation_result.fix_proposal.files_to_modify` (array of `{file, what, why}` objects — each string, `file` non-empty)
> - `validation_result.verification_context.how_to_verify_fix` (array of strings)
> - `validation_result.verification_context.edge_cases_to_preserve` (array of strings)
> - `validation_result.verification_context.what_would_break_if_incomplete` (array of strings)
>
> **Do NOT emit** alternative / renamed keys — the schema has
> `additionalProperties: false`, and the orchestrator's
> `parse-validator-result.py` will drop the whole `validation_result`
> to `null` with a "shape unrecoverable" note if it sees any of:
> `severity_assessment`, `exploitability`, `affected_locations`
> (top-level alternative shapes); `files_planned`, `sketch`, `risk`,
> `alternative_rejected` (fix-proposal alternative shapes). Pack that
> information into `evidence[]`, `blast_radius.invariants_at_stake[]`,
> and `fix_proposal.{approach,files_to_modify}` instead.

### 4.3. Wave 1 — light lane (Sonnet, chunked-batch fan-out)

Split light-lane candidates (including every candidate under
`trivial_mode`) into chunks of **at most 25 candidates per chunk**,
balanced as evenly as feasible. For each chunk, launch ONE `Agent`
tool-use with `model: sonnet`. Dispatch all chunk-agents in one
orchestrator turn for concurrency.

**Why chunked, unlike the deep lane.** Light-lane work is rubric-
checking against CLAUDE.md, not per-candidate blast-radius
investigation, so it batches well — same justification as Phase 3
scoring (§3.3). Sonnet is cheap, but unbounded batches collapse score
resolution onto the rubric anchors and stop using parallelism on large
reviews. The 25-cap restores both. The §4.4 `--apply-decisions
--expected $N` guard counts every dispatched candidate (deep + light),
so a chunk-agent that drops a finding from its returned array trips
the same structural check as a collapsed deep-lane Opus.

Prompt essence (per §19.6):

> You are a light confirmation validator. You will return one entry
> per candidate.
>
> **Candidates (N total):**
> ```
> <full JSON array of every finding in this chunk>
> ```
>
> **CLAUDE.md paths:** `$claude_md_paths`
> **trivial_mode:** `<true|false>` (when true, do NOT emit `actionability: auto_fixable` for ANY candidate — only `manual` or `report_only` per §13.9).
>
> **Read-only.** Do not use `Edit` or `Write`; describe any needed
> change in each finding's `note` — it's not yours to apply.
>
> Verify each finding's accuracy only: does the CLAUDE.md really
> contain this rule? Does the adjacent comment really conflict? Adjust
> the per-candidate score accordingly.
>
> Flag `actionability: auto_fixable` ONLY for very mechanical rules
> where the fix is unambiguous (e.g. import ordering, specific constant
> naming). Judgment calls → `manual`. Architecture findings default to
> `report_only`.
>
> **Anti-anchor-clustering instruction (chunk-batch specific):** Use
> the full 0-100 range. The §13.1 Phase-4 routing has cutoffs at 45,
> 60, and 75; a finding that sits between 60 and 75 should score 65 or
> 70 — do not snap it to an anchor. If multiple candidates in the
> chunk would naturally land at the same anchor, resolve which ones
> are actually higher / lower before returning. Compressed-onto-anchor
> scores lose the resolution Phase 6 needs to render confirmed_strength.
>
> Return JSON array, one entry per candidate (order does not matter,
> routing is by `id`):
>
> ```
> [{"id":"<finding-id>","decision":"confirmed|disproven|uncertain","score_phase4":<0-100>,"actionability":"auto_fixable|manual|report_only","note":"brief rationale"}, ...]
> ```

### 4.4. Apply §13.1 Phase-4 decision table (batched)

Log tokens for each Wave 1 sub-agent before composing the apply batch.
Deep-lane validators are per-candidate, so log once per finding with
`--finding-id`. Light-lane chunk-agents own multiple findings, so log
once per chunk-agent without `--finding-id` (tokens are agent-level,
matching the Phase 3 pattern in §3.3 step 1):

```bash
# Deep lane (per candidate):
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_4a \
  --agent-role validator --finding-id "$id" \
  --agent-id <id> --model opus \
  --tokens <N or null>

# Light lane (per chunk-agent — --finding-id omitted):
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_4b \
  --agent-role validator \
  --agent-id <id> --model sonnet \
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
| `60-74` AND `actionability=auto_fixable` | | `confirmed_mechanical` | true | confirmed_strength: moderate |
| `60-74` AND `actionability=manual` | | `confirmed_manual` | false | confirmed_strength: moderate |
| `60-74` AND `actionability=report_only` | | `confirmed_report` | false | confirmed_strength: moderate |
| `75+` AND `actionability=auto_fixable` | | `confirmed_mechanical` | true | confirmed_strength: strong |
| `75+` AND `actionability=manual` | | `confirmed_manual` | false | confirmed_strength: strong |
| `75+` AND `actionability=report_only` | | `confirmed_report` | false | confirmed_strength: strong |

The helper applies `score_phase4` takes-precedence-over-`decision`
automatically: derivation runs off `score_phase4 + actionability`, so
a validator returning `decision: "confirmed", score_phase4: 40` routes
to `disproven` via the score row; `decision: "disproven",
score_phase4: 70, actionability: "auto_fixable"` routes to
`confirmed_mechanical`. Validators shouldn't emit such mismatches, but when
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

**Normalize validator output before tuple compose.** Sub-agent score
shape is not deterministic across model versions / prompt drifts —
validators have been observed emitting `{score: {correctness: 72}}`,
`{overall_numeric: 3.5}`, `{severity: "high"}`, and `{score: 6}` instead
of the `score_phase4` integer the §20 rubric asks for. Pipe each raw
validator response through `parse-validator-result.py --lane
deep|light` before composing the tuple; the helper returns a canonical
shape (`score_phase4`, `actionability`, `confirmed_strength`,
`decision`, `validation_result`, `notes`) with `scale_inferred:` audit
notes when it had to guess. Exit 2 from the helper means the score was
unrecoverable — emit `score_phase4: null` in the tuple so
`--apply-decisions` routes to `uncertain` per §13.1 Phase-4 row 1, and
stash the stderr in `trace.md` so the audit trail records the drift.

```bash
# For each validator response `$raw` (captured from Agent tool output):
canon=$(printf '%s' "$raw" \
    | parse-validator-result.py --lane deep \
        2> >(tee -a "$trace_log_path" >&2)) \
    || canon='{"score_phase4": null, "actionability": null, "notes": "Phase 4 parse/score unrecoverable"}'
# `$canon` is now canonical JSON — merge it with {id: $finding_id} and
# the sub-agent's raw `reason` (if any) to form the tuple. For the
# light lane, `$raw` is one ENTRY of the chunk-agent's array (the
# chunk-agent returns `[{id,...}, {id,...}, ...]` per §4.3): iterate
# the array first, then pipe each entry through `--lane light`
# individually. Piping the whole array through the helper exits 2
# (parse-validator-result.py rejects non-object inputs), which would
# fall back every finding in the chunk to score_phase4=null.
```

The helper's `notes` field flows into the tuple's `reason` when the
validator didn't supply one — preserving the scale-inference audit
trail in the persisted finding.

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

# Compute total_dispatched_w1 = N_deep_dispatched + N_light_dispatched
# (count individual candidates, NOT chunk-agents — each light-lane
# chunk-agent owns multiple findings and is expected to return one
# tuple per finding it owned). Used by --expected as the structural
# guard against batched-Opus collapse and chunk-array drops.
#
# The orchestrator already has the lane-partitioned id lists in
# context from §4.1 — surface them as comma-separated bash strings
# (e.g. `deep_ids="F003,F007,F012"`, `light_ids="F004,F005"`) and
# count via awk on NF, mirroring commands/add.md §7.6 lines 551-556.
# The empty-string guard is required because `awk -F, '{print NF}'`
# returns 1 (not 0) on an empty input line.
deep_ids="<comma-separated ids dispatched in §4.2>"
light_ids="<comma-separated ids dispatched in §4.3>"
N_deep_dispatched=0
N_light_dispatched=0
[[ -n "$deep_ids"  ]] && N_deep_dispatched=$(awk  -F, '{print NF}' <<<"$deep_ids")
[[ -n "$light_ids" ]] && N_light_dispatched=$(awk -F, '{print NF}' <<<"$light_ids")
total_dispatched_w1=$(( N_deep_dispatched + N_light_dispatched ))

# Empty-wave skip: when both lanes dispatched zero candidates (e.g.,
# every survivor was Phase-3-gated out, or trivial_mode forced every
# candidate into the light lane and there happened to be none), there's
# nothing to apply — skip the helper invocation. Mirrors
# commands/add.md's `[[ -z "$new_ids" ]]` guard. The §4.4.5 sweep below
# still runs unconditionally.
if (( total_dispatched_w1 > 0 )); then
    out=$(artifact-patch.py \
            --path "$artifact_path" \
            --apply-decisions "@$scratch/phase4-wave1-decisions.json" \
            --expected "$total_dispatched_w1")
    echo "$out"  # e.g. "applied 18 decisions (confirmed_mechanical=4, confirmed_manual=1, confirmed_report=0, uncertain=3, disproven=10)"
fi
```

**On score parse failure** (sub-agent returned unparseable JSON even
after one retry): emit `score_phase4: null` in the tuple and the
helper routes to `uncertain` automatically. Override the default
reason by including `reason: "Phase 4 parse failure — manual review"`
in that tuple so the rendered report explains why Phase 4 didn't
confirm. The tuple still counts toward `--expected`, so the parse
failure does not trip the structural guard — it surfaces as an
`uncertain` finding instead.

**On `--expected` rejection (exit 6, count mismatch):** the helper
emits a stderr block naming the expected vs received count and the
recovery action. The check is bidirectional — under-count means a
collapsed deep-lane Opus call (re-dispatch one Agent per missing
candidate and recompose the tuple array on the full per-finding
result set) OR a light-lane chunk-agent dropped findings from its
returned array (re-dispatch the chunk for the missing ids); over-
count means the orchestrator emitted extra tuples (e.g. a light-lane
chunk-agent returned hallucinated ids that the orchestrator forwarded
verbatim — strip them before re-invoking). Do NOT lower `--expected`
to match the received count — the guard is exactly what is supposed
to catch this. The artifact is left unchanged on this exit, so a
clean re-invoke with the corrected batch is safe.

**On apply-decisions exit 1 (per-tuple validation failures, including
duplicate ids):** the batch halted before any write if a duplicate-id
guard fired (no tuples committed; strip the duplicate(s) and
re-invoke), otherwise it halted at the first invalid tuple (stderr
names the failing finding id) with the preceding tuples already
committed to the artifact. For the per-tuple case, fix the offending
tuple and re-invoke with just the remainder; do NOT re-send the whole
batch (the committed tuples would be re-applied, and
`_apply_finding_set` would re-append score_history entries — audit-
trail pollution). The remainder re-invoke uses `--expected
<remainder-count>` to match. For the duplicate-id case, no remainder
math is needed — just re-invoke with the de-duplicated batch and the
original `--expected` value.

### 4.4.5. Tree-cleanliness sweep (belt-and-braces for the read-only preamble)

After `--apply-decisions` returns for Wave 1 (and again for Wave 2
per §4.5 step 4), run a `git status --porcelain` sweep. Validators have no
legitimate reason to touch the working tree — the 4.2 / 4.3 prompts
already forbid it. This catches a prompt-override and restores the
tree before Phase 5 so a misbehaving validator cannot poison the
commit `/adamsreview:fix` will later produce.

The `:!.claude/` pathspec excludes the worktree's `.claude/` directory
from the sweep. Claude Code's own infrastructure (ScheduleWakeup locks,
session state) writes there during a run — flagging those is a false
positive, since `.claude/` is never substantive to a code review.

```bash
dirty=$(git -C "$repo_root" status --porcelain -- . ':!.claude/' 2>/dev/null)
if [[ -n "$dirty" ]]; then
    printf 'phase_4_tree_dirty_reverted: %s\n' \
        "$(printf '%s\n' "$dirty" | awk '{print $2}' | paste -sd, -)" \
        >> "$trace_log_path"
    # Restore tracked-file modifications (respect the .claude/ exclusion).
    git -C "$repo_root" checkout -- . ':!.claude/' 2>/dev/null || true
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

   artifact-patch.py \
     --path "$artifact_path" --add-finding "$wave2_finding"
   ```

2. Run Phase 3 scoring on these new candidates using the chunked-batch
   pattern from §3.3 (Wave 2 candidate counts are typically small, so a
   single chunk-agent usually suffices; the ≤25-per-chunk cap still
   applies if the related-candidate sweep produced an unusually large
   set).

   **Drop-recovery (§3.3 step 3 + Wave 2 cap interaction).** If the
   chunk-agent drops a finding from its returned array, §3.3 step 3
   normally sets `score_phase3=null` and notes it in `trace.md`; the
   gate then treats null-score findings as below-gate unless they
   auto-graduate via ≥2 source families. **In Wave 2 this is a silent
   confirmation loss**: every Wave 2 candidate is structurally seeded
   with a single source family (`["structural-family"]` per the
   `wave2_finding` shape in step 1), so a null-scored Wave 2 candidate
   cannot auto-graduate, and the hard 2-wave cap means it will never
   be retried in a Wave 3. Before continuing to step 3, re-dispatch
   the scoring chunk for any missing ids — mirrors §4.4's chunk-agent
   drop language. Re-dispatching the *scoring* chunk is intra-Wave-2,
   not a Wave 3, so the hard cap is preserved.

   Note that the §4.5 step 4 `--expected` guard cannot catch step-2
   drops on its own — gate-out candidates are excluded from step-3
   dispatch, so a silently-null-scored finding is invisible to the
   downstream `--apply-decisions` count check.
3. Dispatch Wave 2 deep-lane validators on any that pass the Phase-3
   gate, same prompt as Wave 1 BUT add: "This is Wave 2 — do NOT emit
   further `related_candidates_to_investigate` entries." (Hard-cap
   enforcement: §4 says "Hard cap at 2 waves.") Wave 2 is deep-lane
   only — one Opus per candidate, no batching, same rule as §4.2.
4. Apply the decision table per step 4.4 for Wave 2 results. Build a
   second tuple array at `$scratch/phase4-wave2-decisions.json`, then
   compute `$N_wave2_dispatched` from the gate-passers list (Wave 2 is
   deep-lane only, so this is just the count of Wave 2 validators
   dispatched in step 3 — no light-lane component). Skip the helper
   when the gate-passers list is empty (zero candidates passed the
   Wave 2 Phase-3 gate). Mirror §4.4's bash idiom:

   ```bash
   wave2_ids="<comma-separated ids dispatched in step 3>"
   N_wave2_dispatched=0
   [[ -n "$wave2_ids" ]] && N_wave2_dispatched=$(awk -F, '{print NF}' <<<"$wave2_ids")
   if (( N_wave2_dispatched > 0 )); then
       out=$(artifact-patch.py \
               --path "$artifact_path" \
               --apply-decisions "@$scratch/phase4-wave2-decisions.json" \
               --expected "$N_wave2_dispatched")
       echo "$out"
   fi
   ```

   Re-run the step 4.4.5 tree-cleanliness sweep after this
   `--apply-decisions` returns — Wave 2 validators are dispatched with
   the same prompt as Wave 1, so the same read-only invariant applies.

If the list is empty, proceed to step 4.6.

### 4.6. Pre-existing override re-assertion (§13.1)

After Phase 4 completes, sweep the findings list one more time:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.origin == "pre_existing" and .origin_confidence == "high" and .disposition != "pre_existing_report") | .id]'
```

This catches cases where Phase 4a's deep validation bumped a pre-existing
finding's score into the confirmed band — the pre-existing rule trumps.
For each returned id:

```bash
artifact-patch.py \
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

by_disp=$(artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_disposition')

log-phase.sh \
  --review-dir "$review_dir" --phase 4 --name validation \
  --elapsed "$phase_4_elapsed" \
  --summary "$(jq -nc --argjson by_disp "$by_disp" '$by_disp | to_entries | map("\(.key)=\(.value)") | join(", ")')"

log-phase.sh \
  --review-dir "$review_dir" --phase 4 --record "$(jq -nc \
    --argjson elapsed "$phase_4_elapsed" \
    --argjson by_disp "$by_disp" \
    --argjson total_open "$(artifact-read.sh --path "$artifact_path" --filter '[.findings[] | select(.current_state == "open")] | length')" \
    '{name:"validation", elapsed_sec:$elapsed, counts_by_state:{open:$total_open}, counts_by_disposition:$by_disp, delta:"<summarize e.g. +9 confirmed_mechanical, -5 disproven>"}')"
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
