## Phase 5 — Cross-cutting review (deep lane only)

One Opus sub-agent looks across all deep-lane `is_actionable: true`
findings and emits `cross_cutting_groups` — sets of findings that must
be fixed together, each with a combined approach. Non-deep-lane
findings skip Phase 5 entirely.

This phase is pure reasoning over serialized JSON. The sub-agent needs
no tool access beyond what's in its prompt.

Capture `phase_5_start_epoch=$(date +%s)` as the first action of this
phase — step 5.4 logs the elapsed time.

### 5.1. Check for eligibility

Read the candidates that qualify for cross-cutting analysis:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.is_actionable == true and .validation_lane == "deep")]'
```

If the list is empty (trivial mode, or every deep-lane candidate was
disproven/uncertain/confirmed_manual/confirmed_report), **skip Phase 5
entirely**:

```bash
log-phase.sh \
  --review-dir "$review_dir" --phase 5 --name cross-cutting \
  --elapsed 0 \
  --summary "skipped — no deep-lane actionable findings"
# plus the phases.jsonl record with delta="skipped".
```

Jump to Phase 6.

Otherwise, capture the list as `xc_input_json` and proceed.

### 5.2. Dispatch the cross-cutting sub-agent

Launch one `Agent` tool-use with `model: opus`. No tool access needed;
input is the serialized findings in the prompt.

Prompt essence:

> You are reviewing a set of confirmed, actionable deep-lane findings
> to identify cross-cutting concerns — findings whose fixes must happen
> together because they share code, invariants, or root cause.
>
> **Findings (full validation_result included):**
>
> ```
> <xc_input_json>
> ```
>
> Look across these for:
>
> - Parallel code paths needing matching fixes (e.g., an edit in
>   `foo()` implies a matching edit in `fooAsync()`).
> - Shared invariants stressed by multiple findings (e.g. multiple
>   findings all depend on "user_id is always non-null" — fixing them
>   piecemeal leaves the invariant in an inconsistent state).
> - Fix proposals that would collide if applied independently (two
>   findings editing the same function with incompatible changes).
> - Findings whose root cause is shared, where fixing only one leaves
>   the others broken.
>
> **Only group when combining is actually required** — not when
> findings are merely thematically related. Findings that stand alone
> get no annotation.
>
> Return JSON:
>
> ```
> {
>   "cross_cutting_groups": [
>     {
>       "id": "G1",
>       "finding_ids": ["F001", "F003"],
>       "combined_approach": "one paragraph explaining the unified fix"
>     },
>     ...
>   ],
>   "per_finding_annotations": [
>     {"finding_id": "F001", "group_id": "G1", "note": "..."},
>     ...
>   ]
> }
> ```
>
> Group ids follow the regex `^G[0-9]+$` (G1, G2, ...). Each group must
> have at least 2 finding_ids (singleton groups serve no purpose).
> `per_finding_annotations` is optional — include only when a finding
> needs group-specific context beyond the combined_approach.

### 5.3. Log tokens + apply

First, token log:

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_5 \
  --agent-role cross_cutting --agent-id <id> \
  --model opus --tokens <N or null>
```

Parse the sub-agent's JSON. If parsing fails after one retry (§24.1),
write to `trace.md` with tag `phase_5_parse_failed` and skip this step
— the artifact stays without `cross_cutting_groups` set. It's observability
that's missing, not correctness: the pipeline proceeds to Phase 6.

If parsing succeeds, extract `.cross_cutting_groups` from the sub-
agent's outer envelope (same pattern as 05-validation.md step 4.4 —
the sub-agent returns `{cross_cutting_groups: [...],
per_finding_annotations: [...]}`; schema's
`artifact.cross_cutting_groups` is the array only, not the envelope).
Write the groups to a tmpfile so `--set-json` can use `@file` form
(groups can be large if there are many cross-cutting interactions):

```bash
# If the sub-agent already returned just the groups array, the `// .`
# fallback preserves the value. If it returned the outer envelope,
# we pluck the inner array.
jq -c '.cross_cutting_groups // .' <<<"$subagent_response_json" \
    > "/tmp/adams-review-ccg-$review_id.json"
artifact-patch.py \
  --path "$artifact_path" \
  --set-json "cross_cutting_groups=@/tmp/adams-review-ccg-$review_id.json"
rm -f "/tmp/adams-review-ccg-$review_id.json"
```

The schema validates each group: id must match `^G[0-9]+$`,
finding_ids must have at least 2 entries, combined_approach required.
An invalid group causes `artifact-patch.py` to reject the write — the
error-as-prompt names the offending field. On rejection: log to
`trace.md` and proceed without cross_cutting_groups (same fallback as
parse failure).

### 5.4. Log Phase 5 summary

```bash
phase_5_elapsed=$(( $(date +%s) - phase_5_start_epoch ))
group_count=$(artifact-read.sh \
  --path "$artifact_path" --filter '.cross_cutting_groups | length')

log-phase.sh \
  --review-dir "$review_dir" --phase 5 --name cross-cutting \
  --elapsed "$phase_5_elapsed" \
  --summary "groups=$group_count"

log-phase.sh \
  --review-dir "$review_dir" --phase 5 --record "$(jq -nc \
    --argjson elapsed "$phase_5_elapsed" \
    --argjson groups "$group_count" \
    '{name:"cross-cutting", elapsed_sec:$elapsed, counts_by_state:{}, counts_by_disposition:{}, cross_cutting_groups:$groups, delta:"\($groups) groups emitted"}')"
```

### Working-set delta after Phase 5

- `artifact.cross_cutting_groups` populated (possibly `[]`).
- `tokens.jsonl` + one entry for the cross-cutting sub-agent.
- `phases.jsonl` + one Phase 5 record (with a skip note if no
  deep-lane actionable findings existed).
