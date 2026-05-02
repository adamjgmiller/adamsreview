## Phase 4 — Codex validation (codex-review)

This fragment is the codex-review counterpart to `fragments/05-validation.md`.
The lane partition (§4.1), apply-decisions (§4.4), tree-cleanliness sweep
(§4.4.5), pre-existing override re-assertion (§4.6), and summary (§4.7)
are unchanged — codex-review reuses the same helpers and the same
batched apply pattern. The differences are concentrated in the
dispatch shape:

- **Phase 4a deep lane**: one parallel **Codex** job per candidate
  (instead of one Opus `Agent` per candidate). Each Codex output runs
  through a per-finding **Sonnet shape-fixer** sub-agent that emits
  the canonical `validation_result` tuple.
- **Phase 4b light lane**: chunked-batch **Codex** (≤25 candidates per
  chunk) instead of chunked-batch Sonnet. Each chunk's freeform output
  runs through one chunk-level Sonnet shape-fixer that emits the tuple
  array.
- **Wave 2 (chain retry) is DISABLED**. Plan §2 — keeps wall-clock
  bounded for codex-review, mirrors `/adamsreview:add`'s no-Wave-2
  policy.

Capture `phase_4_start_epoch=$(date +%s)` as the first action of this
phase — step 4.7 logs the elapsed time.

### 4.1. Partition candidates into lanes

Identical to `fragments/05-validation.md` §4.1. Read the phase-3
survivors:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.disposition == "pending_validation") | {id, impact_type, validation_lane}]'
```

If `trivial_mode == true`: force ALL candidates into the light lane
(per §13.9). Else partition by `validation_lane`.

### 4.2. Phase 4a — deep lane (Codex per candidate)

For each deep-lane candidate, build a Codex prompt file at
`/tmp/adams-review-codex-${review_id}-V-${finding_id}.md` and launch a
Codex job. Dispatch ALL deep-lane Codex jobs in one orchestrator turn
for concurrency.

#### 4.2.1. Build the per-candidate prompt

```bash
prompt_file="/tmp/adams-review-codex-${review_id}-V-${finding_id}.md"
finding_json=$(artifact-read.sh \
  --path "$artifact_path" --finding-id "$finding_id")

cat > "$prompt_file" <<'PROMPT'
You are a deep validator. Confirm or disprove this candidate, trace
its blast radius, and — if real — produce a concrete fix proposal.

**Scoring contract.** Your `score_phase4` is a single integer 0-100
per the §20 rubric. Do not output a 1-5 or 1-10 scale, a float, or
a severity keyword — the orchestrator's parser consumes the integer
directly and mis-scaled scores silently route findings to the wrong
band.

**Read-only.** Do not modify the working tree. If a fix is warranted,
describe it in `fix_proposal` — the fix-application phase applies it
later. Any working-tree changes you make will be reverted before
Phase 5.

Steps:
1. **Confirm or disprove.** Trace the claim end-to-end in the code.
   Read function BODIES, not just signatures. Consult `git blame` /
   `git log` if the history clarifies intent.
2. **Trace blast radius.** For every writer, consumer, parallel path,
   and relevant test — enumerate them in `blast_radius`.
3. **Construct reproduction or disproof.** A concrete input / state /
   call sequence that triggers the bug, OR evidence showing it can't.
4. **If real: produce `fix_proposal.files_to_modify` — the full class,
   not just the obvious site.** Cross-check against
   `blast_radius.parallel_paths`. Every entry that exhibits the same
   invariant violation MUST appear in `files_to_modify`.
5. **Produce `verification_context`:** `how_to_verify_fix` (specific
   grep/read commands), `edge_cases_to_preserve`,
   `what_would_break_if_incomplete`.
6. **Re-score 0-100** using the §20 rubric — based on what you found.
7. **Skip the related-candidate sweep for codex-review.** Codex-review
   has no Wave 2 chain (§4.5), and the apply-decisions tuple shape
   does not carry `related_candidates_to_investigate`. Don't emit
   that field. If you notice an adjacent bug that's NOT a separate
   finding already, mention it inside `validation_result.evidence[]`
   or `validation_result.blast_radius.parallel_paths[]` — those keys
   ARE persisted on the artifact and surface in the rendered report.

**Candidate (full stored finding):**

PROMPT

# Append the finding JSON. The shape-fixer (§4.2.3) takes Codex's
# freeform output and canonicalizes; Codex doesn't need to emit
# perfect JSON — it just needs to think hard about the candidate.
printf '\n```\n%s\n```\n\n' "$finding_json" >> "$prompt_file"

cat >> "$prompt_file" <<'PROMPT'
**CLAUDE.md paths to consult:**

PROMPT
printf '%s\n\n' "$claude_md_paths" >> "$prompt_file"

cat >> "$prompt_file" <<'PROMPT'
Return JSON matching this shape (the orchestrator will normalize
freeform output via a shape-fixer, but emitting close-to-schema
output reduces shape-fixer drift):

```
{
  "validation_result": {
    "evidence": ["one sentence per piece of concrete evidence"],
    "blast_radius": {
      "writers": ["file:line — who writes this"],
      "consumers": ["file:line — who reads this"],
      "parallel_paths": ["file:line — adjacent paths with the same invariant"],
      "invariants_at_stake": ["one sentence per invariant the diff stresses"]
    },
    "fix_proposal": {
      "approach": "one or two sentences",
      "files_to_modify": [
        {"file":"src/path.ts", "what":"concrete change", "why":"reason"}
      ]
    },
    "verification_context": {
      "how_to_verify_fix": ["grep ...", "read ..."],
      "edge_cases_to_preserve": ["..."],
      "what_would_break_if_incomplete": ["..."]
    }
  },
  "score_phase4": <0-100>,
  "decision": "confirmed" | "disproven" | "uncertain",
  "actionability": "auto_fixable" | "manual" | "report_only"
}
```

Do NOT emit a top-level `related_candidates_to_investigate` —
codex-review has no Wave 2 (§4.5) and the apply-decisions tuple
schema rejects unknown keys. If `decision` is `disproven` or
`uncertain`, set `validation_result` to `null`. Empty arrays ARE
acceptable; missing keys are not.
PROMPT
```

#### 4.2.2. Launch Codex jobs (one orchestrator turn)

For each deep-lane finding, fire one Bash tool-use:

```bash
node "$CODEX_COMPANION" task --background --effort "$effort" \
    --prompt-file "/tmp/adams-review-codex-${review_id}-V-${finding_id}.md" \
    --json
```

Capture each launch payload's `.jobId` into a working-context map
keyed by `finding_id`:

```bash
job_id=$(node "$CODEX_COMPANION" task --background --effort "$effort" \
    --prompt-file "/tmp/adams-review-codex-${review_id}-V-${finding_id}.md" \
    --json | jq -r '.jobId')
```

#### 4.2.3. Poll, fetch, shape-fix per finding

Once all deep-lane Codex jobs are terminal (poll via `node
"$CODEX_COMPANION" status <job_id> --json | jq -r '.job.status'`),
fetch each output and pluck the freeform stdout from
`.storedJob.payload.rawOutput`:

```bash
node "$CODEX_COMPANION" result "$job_id" --json \
    > "/tmp/adams-review-codex-${review_id}-V-${finding_id}.out.json"

codex_output=$(jq -r '
    .storedJob.payload.rawOutput // .storedJob.rawOutput // ""
' "/tmp/adams-review-codex-${review_id}-V-${finding_id}.out.json")
```

Then dispatch ONE Sonnet shape-fixer per finding. Each shape-fixer
takes that freeform Codex output and returns a single canonical tuple.
Dispatch all shape-fixers in one orchestrator turn for concurrency.

Shape-fixer prompt essence:

> You are normalizing one Codex deep-validator output into the
> adamsreview validation tuple schema.
>
> **Codex output (freeform):**
>
> ```
> $codex_output
> ```
>
> Emit a single JSON object matching this exact shape (these are the
> ONLY keys the orchestrator's `artifact-patch.py --apply-decisions`
> accepts — emitting any other top-level key halts the batch):
>
> ```
> {
>   "id": "<finding_id>",
>   "score_phase4": <0-100 integer>,
>   "decision": "confirmed" | "disproven" | "uncertain",
>   "actionability": "auto_fixable" | "manual" | "report_only",
>   "validation_result": <the structured object below, or null if decision != confirmed>
> }
> ```
>
> Codex-review explicitly disables Wave 2 chain-retry (§4.5), so do
> NOT emit `related_candidates_to_investigate` — there's no consumer
> for it and the apply-decisions helper rejects it as an unknown key.
> Discard any "related candidates" prose from the Codex output.
>
> When `decision == "confirmed"`, `validation_result` MUST be the full
> structured object with these keys (verbatim — `additionalProperties:
> false` rejects substitutes):
>
> - `evidence` (array of strings)
> - `blast_radius.writers` (array of strings)
> - `blast_radius.consumers` (array of strings)
> - `blast_radius.parallel_paths` (array of strings)
> - `blast_radius.invariants_at_stake` (array of strings)
> - `fix_proposal.approach` (string)
> - `fix_proposal.files_to_modify` (array of `{file, what, why}` objects)
> - `verification_context.how_to_verify_fix` (array of strings)
> - `verification_context.edge_cases_to_preserve` (array of strings)
> - `verification_context.what_would_break_if_incomplete` (array of strings)
>
> If Codex's output doesn't include enough information to fill a key,
> emit an empty array `[]` (never null, never missing). If the score
> is unparseable (no clear 0-100 integer in the output), emit
> `score_phase4: null` and the orchestrator's `--apply-decisions` will
> route the finding to `uncertain`.
>
> **Use the candidate's id (`<finding_id>`) verbatim in the output.**
> Do not invent ids; do not omit it.

Dispatch via `Agent` with `model: sonnet`, `subagent_type: general-purpose`.
Capture each shape-fixer's response.

#### 4.2.4. Per-finding atomicity

If any single Codex job fails unrecoverably (after the §3.7 retry-with-
judgment policy: 3 retries, then drop), OR its shape-fixer can't produce
a valid tuple even after one retry, that **single finding** drops to
`disposition: uncertain` (`score_phase4: null`). Compose a sentinel
tuple for it:

```json
{
  "id": "<finding_id>",
  "score_phase4": null,
  "decision": "uncertain",
  "actionability": null,
  "validation_result": null,
  "reason": "Phase 4a Codex unrecoverable — manual review"
}
```

The other findings still apply cleanly via §4.4's batched apply. Log
each drop to `trace.md` with tag `phase_4a_codex_dropped:<finding_id>
reason=<short cause>`.

If MORE THAN HALF of deep-lane findings drop, dispatch
`AskUserQuestion` once for the phase:

```
"<N> of <M> deep-lane Codex validators failed. Continue with degraded
validation (<dropped> findings will be marked uncertain), or abort?"
Options:
- Continue
- Abort (preserve seeded artifact)
```

#### 4.2.5. Log tokens

Log each Sonnet shape-fixer's tokens (Codex tokens are NOT logged —
plan §3.8):

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_4a \
  --agent-role validator_shape_fixer --finding-id "$finding_id" \
  --agent-id <id> --model sonnet \
  --tokens <N or null>
```

### 4.3. Phase 4b — light lane (chunked-batch Codex per chunk)

Split light-lane candidates (and every candidate under `trivial_mode`)
into chunks of **≤25 candidates per chunk**. For each chunk, build
ONE Codex prompt file and launch ONE Codex job. Dispatch all chunk
jobs in one orchestrator turn for concurrency.

#### 4.3.1. Build per-chunk prompt

```bash
chunk_json=$(jq -nc --argjson cands "$chunk_candidates" '$cands')

prompt_file="/tmp/adams-review-codex-${review_id}-LB-chunk${chunk_n}.md"

# Use an UNQUOTED heredoc so $trivial_mode expands to its actual value
# at write time. (A quoted heredoc would emit the literal text
# "<true|false>" — Codex would not know which trivial_mode posture to
# enforce, and could emit `auto_fixable` despite the §13.9 contract.)
# $trivial_mode and $chunk_n are the only orchestrator-context bash
# variables this heredoc references; everything else is literal.
cat > "$prompt_file" <<PROMPT
You are a light confirmation validator. You will return one tuple per
candidate.

**trivial_mode:** $trivial_mode (when true, do NOT emit \`actionability:
auto_fixable\` for ANY candidate — only \`manual\` or \`report_only\`).

**Read-only.** Describe any needed change in each candidate's \`note\`
field — the fix-application phase later may pick it up. Do NOT write
to the working tree.

Verify each finding's accuracy: does the CLAUDE.md really contain this
rule? Does the adjacent comment really conflict? Adjust the per-
candidate score accordingly.

\`actionability: auto_fixable\` only for very mechanical rules (import
ordering, specific constant naming). Judgment calls → \`manual\`.
Architecture findings default to \`report_only\`.

**Use the full 0-100 range.** Do not snap to anchors at 45/60/75 —
emit values like 65 or 70 between anchors when warranted. Compressed
scores lose the resolution Phase 6 needs.

**Candidates (N total):**

PROMPT

printf '```\n%s\n```\n\n' "$chunk_json" >> "$prompt_file"
printf '**CLAUDE.md paths:**\n%s\n\n' "$claude_md_paths" >> "$prompt_file"

cat >> "$prompt_file" <<'PROMPT'
Return a JSON array, one entry per candidate (order does not matter,
routing is by `id`):

```
[
  {
    "id": "<finding-id>",
    "decision": "confirmed" | "disproven" | "uncertain",
    "score_phase4": <0-100>,
    "actionability": "auto_fixable" | "manual" | "report_only",
    "note": "brief rationale"
  },
  ...
]
```

The orchestrator's shape-fixer will canonicalize freeform output, but
emitting close-to-schema output reduces shape-fixer drift.
PROMPT
```

Set `trivial_mode` and `claude_md_paths` substitutions before writing.

#### 4.3.2. Launch + poll + shape-fix per chunk

Launch each chunk's Codex job:

```bash
node "$CODEX_COMPANION" task --background --effort "$effort" \
    --prompt-file "/tmp/adams-review-codex-${review_id}-LB-chunk${chunk_n}.md" \
    --json
```

Capture each launch payload's `.jobId` keyed by chunk number:

```bash
job_id=$(node "$CODEX_COMPANION" task --background --effort "$effort" \
    --prompt-file "/tmp/adams-review-codex-${review_id}-LB-chunk${chunk_n}.md" \
    --json | jq -r '.jobId')
```

Poll all in one orchestrator turn via
`node "$CODEX_COMPANION" status <job_id> --json | jq -r '.job.status'`
until terminal. Then fetch each chunk's output the same way Phase 4a
does: pluck `.storedJob.payload.rawOutput` (with `// .storedJob.rawOutput`
fallback) into a `codex_chunk_output_<N>` shell variable.

Dispatch ONE Sonnet shape-fixer per chunk:

> You are normalizing one Codex light-validator output into a JSON
> array of validation tuples.
>
> **Codex output (freeform):**
>
> ```
> $codex_chunk_output_<N>
> ```
>
> **Candidate ids in this chunk:** `<comma-separated finding ids>`
>
> Emit a JSON array. One element per candidate id (must include all
> ids from the list above):
>
> ```
> [
>   {
>     "id": "<finding-id>",
>     "score_phase4": <0-100 integer or null>,
>     "decision": "confirmed" | "disproven" | "uncertain",
>     "actionability": "auto_fixable" | "manual" | "report_only" | null,
>     "note": "brief rationale (one sentence)"
>   },
>   ...
> ]
> ```
>
> If Codex's output doesn't address some ids (a chunk drop), emit
> a sentinel tuple for each missing id:
>
> ```
> {"id":"<missing>","score_phase4":null,"decision":"uncertain","actionability":null,"note":"chunk dropped this finding"}
> ```
>
> NEVER invent ids not in the candidate list. NEVER skip ids.

Capture each shape-fixer's response (a JSON array of tuples).

#### 4.3.3. Per-chunk atomicity

If a chunk's Codex job fails unrecoverably or its shape-fixer can't
produce a valid array, emit sentinel tuples for ALL candidates in that
chunk (`score_phase4: null`, `decision: uncertain`). Log each drop:
`phase_4b_codex_dropped:<chunk_n> ids=<comma-sep>`.

If more than half of light-lane chunks drop, escalate via
`AskUserQuestion` per the §4.2.4 pattern.

#### 4.3.4. Log tokens

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_4b \
  --agent-role validator_shape_fixer \
  --agent-id <id> --model sonnet \
  --tokens <N or null>
```

(Per-chunk shape-fixer log; no `--finding-id` because each chunk-fixer
covers multiple findings — mirrors the existing Phase 4b chunk-agent
pattern in `fragments/05-validation.md`.)

### 4.4. Apply §13.1 Phase-4 decision table (batched)

Identical to `fragments/05-validation.md` §4.4. Concatenate every
shape-fixer's tuples (deep-lane: one tuple per finding; light-lane:
chunk shape-fixer arrays flattened) into a single JSON array at
`/tmp/adams-review-${review_id}/phase4-decisions.json`, then invoke:

```bash
scratch="/tmp/adams-review-$review_id"
mkdir -p "$scratch"
# Compose tuple array; write to $scratch/phase4-decisions.json.

# Compute total dispatched (deep-lane finding count + light-lane finding
# count, NOT chunk count — each chunk's shape-fixer returns N tuples).
deep_ids="<comma-separated deep-lane finding ids>"
light_ids="<comma-separated light-lane finding ids>"
N_deep=0
N_light=0
[[ -n "$deep_ids" ]]  && N_deep=$(awk -F, '{print NF}' <<<"$deep_ids")
[[ -n "$light_ids" ]] && N_light=$(awk -F, '{print NF}' <<<"$light_ids")
total_dispatched=$(( N_deep + N_light ))

if (( total_dispatched > 0 )); then
    out=$(artifact-patch.py \
            --path "$artifact_path" \
            --apply-decisions "@$scratch/phase4-decisions.json" \
            --expected "$total_dispatched")
    echo "$out"
fi
```

**Use `parse-validator-result.py`** to canonicalize each shape-fixer
tuple BEFORE composing the batch — same as `fragments/05-validation.md`
§4.4. The shape-fixer tries to emit canonical JSON but Codex's input
to it can be messy enough that residual drift slips through.

```bash
# For each shape-fixer tuple `$raw`:
canon=$(printf '%s' "$raw" \
    | parse-validator-result.py --lane deep \
        2> >(tee -a "$trace_log_path" >&2)) \
    || canon='{"score_phase4": null, "actionability": null, "notes": "Phase 4 parse/score unrecoverable"}'
```

Use `--lane light` for light-lane tuples. Iterate over EACH light-lane
chunk's tuple array element-by-element (do NOT pipe the whole array
through the helper — exit 2 on non-object input).

**Project the canonical object to the allowed tuple keys before adding
to the batch.** `parse-validator-result.py`'s canonical output includes
`related_candidates_to_investigate` (deep-lane passthrough), `notes`,
and `confirmed_strength` at the top level — all three are NOT in
`artifact-patch.py --apply-decisions`'s `ALLOWED_DECISION_TUPLE_KEYS`,
and feeding them through unchanged halts the batch with an unknown-key
error.

There's also a subtlety with `reason`: `apply-decisions` checks
`if "reason" in tup` (NOT truthiness) — so `reason: ""` short-circuits
the disposition-appropriate default reason ("disproven by Phase 4",
"uncertain (Phase 4 inconclusive)"). Only include the key when there's
actual content. Light lane has an additional preservation step: the
shape-fixer's prompt asks for `note` (rationale), but
`parse-validator-result.py` does not preserve raw `note` — its
canonical `notes` is the parser's own audit trail. Pull `note` from
the raw shape-fixer output as a fallback.

```bash
# $canon is parse-validator-result.py's canonicalized object (already
# strict JSON). $raw is the shape-fixer's pre-canonicalization output
# — it may be fenced, prose-wrapped, or otherwise repairable-but-not-
# strict, so feeding it to jq's --argjson directly would crash the
# projection (and bypass the per-finding/per-chunk atomicity contract).
# Repair $raw to strict JSON first; fall back to {} if even repair
# fails. parse-with-repair.py is the same front-stop
# parse-validator-result.py uses internally — symmetric handling.
raw_repaired=$(printf '%s' "$raw" | parse-with-repair.py 2>/dev/null) \
    || raw_repaired='{}'

# Per-tuple `id`: for the deep lane, $finding_id is the orchestrator-
# captured id of the single finding this Codex job validated. For the
# light lane, iterate the chunk array element-by-element FIRST and set
# `finding_id="$(printf '%s' "$raw_repaired" | jq -r '.id // empty')"`
# per iteration BEFORE this projection runs — using a stale or
# orchestrator-fixed $finding_id across chunk elements would
# duplicate ids and trip apply-decisions's duplicate-id guard. Drop
# the tuple if `.id` is missing or not in the chunk's expected id set.

tuple=$(jq -nc \
    --arg id "$finding_id" \
    --argjson canon "$canon" \
    --argjson raw "$raw_repaired" '
  # Pick the best non-empty rationale: validator-supplied note (light
  # lane), then parser audit trail (deep + light), else null.
  ($raw.note // $canon.notes // null) as $rationale
  | {
      id: $id,
      score_phase4:      $canon.score_phase4,
      decision:          $canon.decision,
      actionability:     $canon.actionability,
      validation_result: $canon.validation_result
    }
  | if ($rationale | type == "string") and ($rationale | length > 0)
    then . + {reason: $rationale}
    else .   # omit reason — let apply-decisions fill the default
    end
')
```

The mapping pattern follows `fragments/05-validation.md` §4.4 ("The
helper's `notes` field flows into the tuple's `reason` when the
validator didn't supply one — preserving the scale-inference audit
trail in the persisted finding"). `confirmed_strength` is dropped
because `--apply-decisions` derives it from score; passing it through
would conflict with the helper's derivation.
`related_candidates_to_investigate` is dropped per Wave 2 being
disabled in codex-review (§4.5).

Recovery paths for `--apply-decisions` non-zero exit codes (6 expected-
mismatch, 1 per-tuple validation, etc.) are identical to
`fragments/05-validation.md` §4.4. Re-dispatch the missing/invalid
findings; do NOT lower `--expected`.

### 4.4.5. Tree-cleanliness sweep

Identical to `fragments/05-validation.md` §4.4.5 — including the
`pre_validator_clean` gate that protects user-included uncommitted
work when Phase 0 step 0.8 option 2 was chosen. Codex jobs are
launched read-only by virtue of their prompt; this sweep is the
belt-and-braces guard. Run after `--apply-decisions` returns:

```bash
if [[ "$pre_validator_clean" == "true" ]]; then
    dirty=$(git -C "$repo_root" status --porcelain -- . ':!.claude/' 2>/dev/null)
    if [[ -n "$dirty" ]]; then
        printf 'phase_4_tree_dirty_reverted: %s\n' \
            "$(printf '%s\n' "$dirty" | awk '{print $2}' | paste -sd, -)" \
            >> "$trace_log_path"
        git -C "$repo_root" checkout -- . ':!.claude/' 2>/dev/null || true
        printf '%s\n' "$dirty" | awk '/^\?\?/ {print $2}' \
            | while IFS= read -r p; do rm -f "$repo_root/$p"; done
    fi
else
    printf 'phase_4_tree_dirty_sweep_skipped: pre-existing dirty tree (user opted to include uncommitted; preserved)\n' \
        >> "$trace_log_path"
fi
```

### 4.5. Wave 2 — DISABLED in codex-review

Plan §2 explicitly disables Wave 2 chain-retry on Codex. Skip this
section entirely — there is NO consumer for
`related_candidates_to_investigate`, and the apply-decisions tuple
schema does not carry that key. Per §4.2.1 step 7, validators are
told NOT to emit it; per §4.4's projection, the field is dropped if
it slips through anyway. Adjacent-bug observations belong inside
`validation_result.evidence[]` or
`validation_result.blast_radius.parallel_paths[]`, both of which DO
land on the artifact.

Log one line:

```
Phase 4 Wave 2 skipped — codex-review (no chain retry; bounded scope per plan §2)
```

### 4.6. Pre-existing override re-assertion (§13.1)

Identical to `fragments/05-validation.md` §4.6. Sweep findings for
the pre-existing override:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.origin == "pre_existing" and .origin_confidence == "high" and .disposition != "pre_existing_report") | .id]'
```

For each returned id, apply the override:

```bash
artifact-patch.py \
  --path "$artifact_path" --finding-id "$id" \
  --set disposition=pre_existing_report \
  --set is_actionable=false \
  --set actionability=report_only \
  --set confirmed_strength=null \
  --set reason=null
```

Clean up Phase 4's scratch dir AND the per-finding / per-chunk Codex
prompt + output files:

```bash
rm -rf -- "/tmp/adams-review-$review_id"
rm -f "/tmp/adams-review-codex-${review_id}-V-"*.md \
      "/tmp/adams-review-codex-${review_id}-V-"*.out.json \
      "/tmp/adams-review-codex-${review_id}-LB-chunk"*.md \
      "/tmp/adams-review-codex-${review_id}-LB-chunk"*.out.json
```

### 4.7. Log Phase 4 summary

Identical to `fragments/05-validation.md` §4.7:

```bash
phase_4_elapsed=$(( $(date +%s) - phase_4_start_epoch ))

by_disp=$(artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_disposition')

log-phase.sh \
  --review-dir "$review_dir" --phase 4 --name codex-validation \
  --elapsed "$phase_4_elapsed" \
  --summary "$(jq -nc --argjson by_disp "$by_disp" '$by_disp | to_entries | map("\(.key)=\(.value)") | join(", ")')"

log-phase.sh \
  --review-dir "$review_dir" --phase 4 --record "$(jq -nc \
    --argjson elapsed "$phase_4_elapsed" \
    --argjson by_disp "$by_disp" \
    --argjson total_open "$(artifact-read.sh --path "$artifact_path" --filter '[.findings[] | select(.current_state == "open")] | length')" \
    '{name:"codex-validation", elapsed_sec:$elapsed, counts_by_state:{open:$total_open}, counts_by_disposition:$by_disp, delta:"<summarize e.g. +9 confirmed_mechanical, -5 disproven>"}')"
```
