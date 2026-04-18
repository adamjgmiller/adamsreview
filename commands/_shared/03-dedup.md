## Phase 2 — Dedup (LLM-only)

A single Sonnet sub-agent groups near-duplicate candidates so one
underlying issue doesn't surface as multiple findings downstream.
No structural fingerprinting — one LLM pass, pennies of cost.

Capture `phase_2_start_epoch=$(date +%s)` and `pre_dedup_count=$(
~/.claude/commands/_shared/tools/artifact-read.sh --path "$artifact_path" \
  --filter '.findings | length')` as the first actions of this phase —
step 2.4 references both.

### 2.1. Build the dedup input

Read the current findings list:

```bash
~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | {id, file, line_range, claim, source_families, sources}]'
```

(No singular `source_family` field exists on stored findings — Phase 1
already transformed lens output into the plural `source_families` array
before writing. `evidence_snippet` is a candidate-only field that
Phase 1 strips before `--add-finding`; dedup works from
`claim + file + line_range`, which is sufficient for near-duplicate
grouping.)

Capture as `candidate_list_json`.

If `candidate_list_json` is `[]` (no candidates from Phase 1 + 1.5), skip
Phase 2 entirely — log "Phase 2 skipped (no candidates)" to `trace.md`.

### 2.2. Dispatch the Sonnet dedup sub-agent

Launch one `Agent` tool-use with `model: sonnet`. Prompt essence:

> Group these candidate findings into sets where each set represents the
> same underlying issue described in different language.
>
> Candidates (JSON):
>
> ```
> <candidate_list_json>
> ```
>
> Rules:
> - Two candidates belong in the same group only when they point at the
>   same underlying behavior. "Authenticate returns null" and "session.ts
>   doesn't handle DB failure" at the same call site → same group.
>   Candidates about overlapping code but describing distinct issues →
>   separate groups.
> - **Be conservative — prefer splitting when unsure.** False merging
>   hides findings; false splitting only produces two near-identical
>   entries, which the report already handles gracefully.
> - Every id must appear in exactly one group. Single-id groups (unique
>   candidates) are fine.
>
> Return JSON: `{"groups": [[id, id, ...], [id, ...], ...]}`.

Log tokens with every required arg spelled out (the helper's argparse
refuses short forms):

```bash
~/.claude/commands/_shared/tools/log-tokens.sh \
  --review-dir "$review_dir" \
  --phase phase_2 \
  --agent-role dedup \
  --agent-id "$dedup_agent_id" \
  --model sonnet \
  --tokens "$dedup_tokens_or_null"
```

Capture `dedup_agent_id` from the Agent tool result; `dedup_tokens_or_null`
is the parsed token count or the literal word `null` on parse failure.

### 2.3. Merge each group in the artifact

For each group:

**Group of size 1 (unique candidate)** — do nothing; the lone id stays
as-is.

**Group of size ≥ 2** — pick the first id as the "keeper". Union the
`sources` and `source_families` arrays across all group members into the
keeper. Delete every non-keeper.

Concretely, for each group `[K, D1, D2, ...]` (K = keeper, Di = dupes):

1. Read the current state of every id in the group:

    ```bash
    ~/.claude/commands/_shared/tools/artifact-read.sh \
      --path "$artifact_path" \
      --filter '[.findings[] | select(.id as $id | ["K","D1","D2"] | index($id))]'
    ```

    (Substitute the actual group ids.)

2. Compute union arrays via `jq`:

    ```bash
    union_sources=$(jq -c '[.[].sources[]] | unique' <<<"$group_json")
    union_families=$(jq -c '[.[].source_families[]] | unique' <<<"$group_json")
    ```

3. Apply to the keeper in one patch:

    ```bash
    ~/.claude/commands/_shared/tools/artifact-patch.py \
      --path "$artifact_path" --finding-id K \
      --set-json "sources=$union_sources" \
      --set-json "source_families=$union_families"
    ```

4. Delete each dupe:

    ```bash
    for dupe in D1 D2; do
        ~/.claude/commands/_shared/tools/artifact-patch.py \
          --path "$artifact_path" --delete-finding "$dupe"
    done
    ```

Each `artifact-patch.py` call re-validates the full artifact (§13.7). A
merge that produces an invalid state fails loudly rather than silently
corrupting.

### 2.4. Log Phase 2 summary

```bash
phase_2_elapsed=$(( $(date +%s) - phase_2_start_epoch ))
post_count=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" --filter '.findings | length')

# candidates before - candidates after = merged
merged=$(( pre_dedup_count - post_count ))

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 2 --name dedup \
  --elapsed "$phase_2_elapsed" \
  --summary "groups=<N>; merged=$merged; surviving=$post_count"

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 2 --record "$(jq -nc \
    --argjson elapsed "$phase_2_elapsed" \
    --argjson survivors "$post_count" \
    --argjson merged "$merged" \
    '{name:"dedup", elapsed_sec:$elapsed, counts_by_state:{open:$survivors}, counts_by_disposition:{unassigned:$survivors}, delta:"-\($merged) merged"}')"
```

Capture `phase_2_start_epoch` and `pre_dedup_count` at the top of Phase 2
(the latter via `artifact-read.sh --filter '.findings | length'`).

### Working-set delta after Phase 2

- `artifact.findings[]` shrunk by the merged duplicate count.
- Survivors have unioned `sources` and `source_families` (enables
  Phase 3 source-family auto-graduation for multi-family overlaps).
- `tokens.jsonl` + 1 (the dedup sub-agent).
- `phases.jsonl` + 1 (Phase 2 record).
- `trace.md` + 1 section.
