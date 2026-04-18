## Phase 3 — Cheap scoring + gate

Per-candidate Sonnet scoring against the §20 rubric (err-up), followed
by the §13.1 Phase-3 gate that decides which candidates move on to
expensive Phase 4 validation.

Capture `phase_3_start_epoch=$(date +%s)` as the first action of this
phase — §13.5 observability requires an elapsed time on the phases.jsonl
record and step 3.5 below references this variable.

### 3.1. Pre-existing override (highest priority — §13.1)

Before scoring runs, sweep the findings list for pre-existing candidates
that should bypass the Phase-3 gate entirely:

```bash
~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.origin == "pre_existing" and .origin_confidence == "high") | .id]'
```

For each returned id, apply:

```bash
~/.claude/commands/_shared/tools/artifact-patch.py \
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
~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.disposition != "pre_existing_report") | .id]'
```

Capture as `scoring_ids`.

If `scoring_ids` is empty, skip step 3.3 and jump to step 3.4 (gate; may
be all-gate skip too).

### 3.3. Dispatch scoring sub-agents (parallel fan-out)

For each id in `scoring_ids`, launch ONE Sonnet sub-agent. Fire them all
from a single orchestrator turn so they run concurrently — just like the
Phase 1 lens fan-out.

Each sub-agent receives the full finding and the CLAUDE.md path list.
Prompt essence (passes §20 rubric verbatim):

> Score the following candidate finding against the 0-100 rubric below.
>
> **Candidate:**
> ```
> <full finding JSON>
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
> Return JSON: `{"score": <0-100>, "score_rationale": "<one-sentence reason>"}`.

For each sub-agent result:

1. **Log tokens** first (§24.4 invariant):

    ```bash
    ~/.claude/commands/_shared/tools/log-tokens.sh \
      --review-dir "$review_dir" --phase phase_3 \
      --agent-role scoring --finding-id "$id" \
      --agent-id <id-from-result> --model sonnet \
      --tokens <N or null>
    ```

2. **Parse** `{score, score_rationale}` (retry once on JSON-parse
   failure per §24.1; drop with note to `trace.md` on second failure —
   set `score_phase3=null` for the finding).

3. **Write** the score. `--set score_phase3=<N>` auto-appends to
   `score_history`:

    ```bash
    ~/.claude/commands/_shared/tools/artifact-patch.py \
      --path "$artifact_path" --finding-id "$id" \
      --set "score_phase3=$score" \
      --set "reason=$score_rationale"
    ```

    (`reason` at this phase holds the scoring rationale; Phase 4's gate
    application will overwrite it with the gate-specific reason if the
    candidate is gated out.)

### 3.4. Apply the Phase-3 gate (§13.1)

For every finding still at the Phase-1 parking disposition:

```bash
~/.claude/commands/_shared/tools/artifact-read.sh \
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
~/.claude/commands/_shared/tools/artifact-patch.py \
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
~/.claude/commands/_shared/tools/artifact-patch.py \
  --path "$artifact_path" --finding-id "$id" \
  --set disposition=below_gate \
  --set is_actionable=false \
  --set "reason=below validation gate (score $score)"
```

### 3.5. Log Phase 3 summary

```bash
phase_3_elapsed=$(( $(date +%s) - phase_3_start_epoch ))

gate_pass=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.disposition == "pending_validation")] | length')
gate_fail=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.disposition == "below_gate")] | length')

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 3 --name scoring-gate \
  --elapsed "$phase_3_elapsed" \
  --summary "advanced_to_phase_4=$gate_pass; below_gate=$gate_fail"

# phases.jsonl record: shows counts_by_disposition for the first time
# (Phase 1 + Phase 2 left disposition unassigned).
by_disp=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" --summary \
  | jq -c '.counts_by_disposition')

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 3 --record "$(jq -nc \
    --argjson elapsed "$phase_3_elapsed" \
    --argjson pass "$gate_pass" \
    --argjson fail "$gate_fail" \
    --argjson by_disp "$by_disp" \
    '{name:"scoring-gate", elapsed_sec:$elapsed, counts_by_state:{open:($pass+$fail)}, counts_by_disposition:$by_disp, delta:"\($fail) gated below, \($pass) advanced"}')"
```

### Working-set delta after Phase 3

- Every finding has `score_phase3` set (null only on parse failure).
- Pre-existing high-confidence findings have `disposition=pre_existing_report`.
- Sub-threshold findings have `disposition=below_gate`, `is_actionable=false`.
- Gate-passing findings have `disposition=pending_validation` (the
  §5.2.1 gate-in parking state); Phase 4 overwrites.
- `tokens.jsonl` + one entry per scored finding.
- `phases.jsonl` + Phase 3 record with `counts_by_disposition`.
