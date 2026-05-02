## Phase 5 — Codex cross-cutting review (codex-review)

This fragment is the codex-review counterpart to
`fragments/06-cross-cutting.md`. The eligibility check (§5.1), apply
pattern (§5.3 step 2 onwards), and summary (§5.4) are unchanged. The
only difference is the dispatch shape:

- **Opus is replaced by ONE Codex job** that proposes cross-cutting
  groups over the confirmed deep-lane findings.
- The freeform Codex output runs through ONE **Sonnet shape-fixer**
  that emits the structured `cross_cutting_groups` JSON the schema
  expects.

This phase is pure reasoning over serialized JSON — Codex doesn't need
filesystem access for it (the prompt embeds the full findings list).

Capture `phase_5_start_epoch=$(date +%s)` as the first action of this
phase — step 5.4 logs the elapsed time.

### 5.1. Check for eligibility

Identical to `fragments/06-cross-cutting.md` §5.1. Read the candidates
that qualify:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.is_actionable == true and .validation_lane == "deep")]'
```

If the list is empty, **skip Phase 5 entirely**:

```bash
log-phase.sh \
  --review-dir "$review_dir" --phase 5 --name codex-cross-cutting \
  --elapsed 0 \
  --summary "skipped — no deep-lane actionable findings"
```

(Plus the `phases.jsonl` record with `delta="skipped"`.)

Jump to Phase 6.

Otherwise, capture the list as `xc_input_json` and proceed.

### 5.2. Dispatch the Codex cross-cutting job

#### 5.2.1. Build the prompt

```bash
prompt_file="/tmp/adams-review-codex-${review_id}-XC.md"

cat > "$prompt_file" <<'PROMPT'
You are reviewing a set of confirmed, actionable deep-lane findings to
identify cross-cutting concerns — findings whose fixes must happen
together because they share code, invariants, or root cause.

**Findings (full validation_result included):**

PROMPT

printf '```\n%s\n```\n\n' "$xc_input_json" >> "$prompt_file"

cat >> "$prompt_file" <<'PROMPT'
Look across these for:

- Parallel code paths needing matching fixes (e.g., an edit in `foo()`
  implies a matching edit in `fooAsync()`).
- Shared invariants stressed by multiple findings (e.g. multiple
  findings all depend on "user_id is always non-null" — fixing them
  piecemeal leaves the invariant in an inconsistent state).
- Fix proposals that would collide if applied independently (two
  findings editing the same function with incompatible changes).
- Findings whose root cause is shared, where fixing only one leaves
  the others broken.

**Only group when combining is actually required** — not when findings
are merely thematically related. Findings that stand alone get no
annotation.

Return JSON:

```
{
  "cross_cutting_groups": [
    {
      "id": "G1",
      "finding_ids": ["F001", "F003"],
      "combined_approach": "one paragraph explaining the unified fix"
    },
    ...
  ],
  "per_finding_annotations": [
    {"finding_id": "F001", "group_id": "G1", "note": "..."},
    ...
  ]
}
```

Group ids follow `^G[0-9]+$` (G1, G2, ...). Each group must have at
least 2 finding_ids (singleton groups serve no purpose).
`per_finding_annotations` is optional — include only when a finding
needs group-specific context beyond the combined_approach.

If no cross-cutting concerns warrant grouping, emit
`{"cross_cutting_groups": [], "per_finding_annotations": []}`.
PROMPT
```

#### 5.2.2. Launch + poll + fetch

```bash
node "$CODEX_COMPANION" task --background --effort "$effort" \
    --prompt-file "$prompt_file" --json
```

Capture `xc_job_id` from `.jobId`:

```bash
xc_job_id=$(node "$CODEX_COMPANION" task --background --effort "$effort" \
    --prompt-file "$prompt_file" --json | jq -r '.jobId')
```

Poll via `node "$CODEX_COMPANION" status "$xc_job_id" --json |
jq -r '.job.status'` (terminal: `completed` | `failed` | `cancelled`).
Once terminal, fetch and pluck:

```bash
node "$CODEX_COMPANION" result "$xc_job_id" --json \
    > "/tmp/adams-review-codex-${review_id}-XC.out.json"

xc_codex_output=$(jq -r '
    .storedJob.result.rawOutput // .storedJob.payload.rawOutput // .storedJob.rawOutput // ""
' "/tmp/adams-review-codex-${review_id}-XC.out.json")
```

#### 5.2.3. Adaptive retry-with-judgment

Apply the §3.7 retry policy:

1. On Codex job failure (non-zero exit, malformed output, or empty
   output), retry up to 3 times with the same prompt.
2. If all 3 retries fail, dispatch `AskUserQuestion`:

   ```
   "Codex cross-cutting analysis failed after retry. Continue without
   cross_cutting_groups (the rest of the review is unaffected), or
   abort?"
   Options:
   - Continue — skip Phase 5; artifact ships without groups
   - Abort
   ```

   On Continue: log `phase_5_codex_dropped: continuing without groups`
   and proceed to Phase 6.

#### 5.2.4. Sonnet shape-fixer

Dispatch ONE Sonnet `Agent` to canonicalize Codex's freeform output
into the structured shape:

> You are normalizing one Codex cross-cutting analysis output into the
> adamsreview cross_cutting_groups schema.
>
> **Codex output (freeform):**
>
> ```
> $xc_codex_output
> ```
>
> **Valid finding ids in this run:** `<comma-separated ids from xc_input_json>`
>
> Emit a JSON object:
>
> ```
> {
>   "cross_cutting_groups": [
>     {
>       "id": "G1",
>       "finding_ids": ["F001", "F003"],
>       "combined_approach": "one paragraph"
>     },
>     ...
>   ],
>   "per_finding_annotations": [
>     {"finding_id": "F001", "group_id": "G1", "note": "..."}
>   ]
> }
> ```
>
> Constraints (the schema enforces these — failing them rejects the
> whole apply):
> - Each `id` matches `^G[0-9]+$` (G1, G2, ...). Number sequentially
>   from G1.
> - Each `finding_ids` has at least 2 entries.
> - `finding_ids` ⊆ the valid finding-id list above. Drop any group
>   that references unknown ids; do not invent ids.
> - `combined_approach` is non-empty string.
>
> If Codex's output proposes no groups, emit
> `{"cross_cutting_groups": [], "per_finding_annotations": []}`.
> If Codex's output is unparseable for groups but contains relevant
> prose, emit empty arrays (skipping is safe — groups are
> observability, not correctness).

Capture the shape-fixer's response as `xc_response_json`.

Log shape-fixer tokens:

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_5 \
  --agent-role cross_cutting_shape_fixer --agent-id <id> \
  --model sonnet --tokens <N or null>
```

### 5.3. Apply the cross-cutting groups

Same pattern as `fragments/06-cross-cutting.md` §5.3 step 2 onwards.
Parse the shape-fixer's response, extract `.cross_cutting_groups`,
write to a tmpfile, apply via `artifact-patch.py --set-json`:

Mirror `fragments/06-cross-cutting.md` §5.3's pluck — accept either
the envelope (with `.cross_cutting_groups`) or a bare groups array.
The shape-fixer's prompt asks for the envelope, but a Sonnet that
returns just the array shouldn't lose its work. The `// .` fallback
is the same shape :review uses; `// []` would silently zero-out a
valid bare-array response.

```bash
jq -c '.cross_cutting_groups // .' <<<"$xc_response_json" \
    > "/tmp/adams-review-ccg-$review_id.json"

# Defensive type-guard: if neither path produced an array (e.g. the
# shape-fixer emitted a string or object), fall back to [] before
# applying so artifact-patch.py's set-json doesn't choke on the type
# mismatch and we still log a clean trace tag.
if ! jq -e 'type == "array"' "/tmp/adams-review-ccg-$review_id.json" >/dev/null; then
    printf 'phase_5_codex_groups_unparseable: shape-fixer output not an array; setting to []\n' \
        >> "$trace_log_path"
    echo '[]' > "/tmp/adams-review-ccg-$review_id.json"
fi

artifact-patch.py \
  --path "$artifact_path" \
  --set-json "cross_cutting_groups=@/tmp/adams-review-ccg-$review_id.json"

rm -f "/tmp/adams-review-ccg-$review_id.json"
```

If `artifact-patch.py` rejects the write (schema validation — invalid
group id, finding_ids list too short, etc.), log to `trace.md` with
tag `phase_5_apply_rejected: <stderr>` and proceed without
cross_cutting_groups. Same fallback as the original Opus path.

Clean up the Phase 5 Codex prompt + output files:

```bash
rm -f "/tmp/adams-review-codex-${review_id}-XC.md" \
      "/tmp/adams-review-codex-${review_id}-XC.out.json"
```

### 5.4. Log Phase 5 summary

Identical to `fragments/06-cross-cutting.md` §5.4:

```bash
phase_5_elapsed=$(( $(date +%s) - phase_5_start_epoch ))
group_count=$(artifact-read.sh \
  --path "$artifact_path" --filter '.cross_cutting_groups | length')

log-phase.sh \
  --review-dir "$review_dir" --phase 5 --name codex-cross-cutting \
  --elapsed "$phase_5_elapsed" \
  --summary "groups=$group_count"

log-phase.sh \
  --review-dir "$review_dir" --phase 5 --record "$(jq -nc \
    --argjson elapsed "$phase_5_elapsed" \
    --argjson groups "$group_count" \
    '{name:"codex-cross-cutting", elapsed_sec:$elapsed, counts_by_state:{}, counts_by_disposition:{}, cross_cutting_groups:$groups, delta:"\($groups) groups emitted"}')"
```
