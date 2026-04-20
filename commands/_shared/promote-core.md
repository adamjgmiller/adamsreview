## Promote core — precondition, patch, trace

Shared fragment used by both `/adams-review-promote` and
`/adams-review-walkthrough` (§28). Implements the middle steps of the
promote flow — reading the finding, enforcing preconditions, resolving
the `fix_hint` (with the doc/comment-vs-code heuristic), building the
`human_confirmation` object, applying the atomic patch, and appending
the trace entry. See DESIGN §27.

### Contract

**Inputs** (set by caller in ambient Bash context before including this
fragment):

| Variable | Purpose |
|---|---|
| `finding_id` | Positional id matching `^F[0-9]+$`. |
| `reason` | Non-empty string. Audit-focused. Caller is responsible for prompting if absent. |
| `fix_hint` | String; empty means "unset". Caller may pre-populate from `--fix-hint`; the heuristic below auto-prompts when empty. |
| `force` | `true` / `false`. Required `true` to promote a `disposition=disproven` finding. |
| `artifact_path` | Absolute path to `artifact.json` on disk. |
| `trace_log_path` | Absolute path to `trace.md` for this review. |

**Outputs** (captured into ambient context for callers who care):

| Variable | Purpose |
|---|---|
| `curr_disp` | Disposition before the patch (used by callers for their own summaries). |
| `curr_action` | Actionability before the patch. |
| `curr_score` | `score_phase4` before the patch (string — either a JSON integer or literal `null`). |
| `curr_hc` | `human_confirmation` before the patch (JSON; `null` for fresh findings). |
| `ts` | UTC ISO-8601 timestamp of the mutation. |
| `reviewer` | Resolved from `git config` or `unknown`. |

**Side effects**: the artifact is patched atomically; a `## promote`
block is appended to `trace.md`.

**Skipped**: render, publish, user-visible summary — those live in the
top-level command.

### Step 3. Read the target finding

```bash
finding_json=$(~/.claude/commands/_shared/tools/artifact-read.sh \
    --path "$artifact_path" \
    --filter ".findings[] | select(.id == \"$finding_id\")")
```

If empty, error-as-prompt with the list of existing ids. Use
`artifact-read.sh --filter` to pull the id list for the suggestion:

```bash
existing_ids=$(~/.claude/commands/_shared/tools/artifact-read.sh \
    --path "$artifact_path" \
    --filter '[.findings[].id] | join(", ")')
```

Emit `Valid values: $existing_ids` and `Did you mean '...'?` with the
closest match if one is obvious. Abort.

Extract the state variables:

```bash
curr_disp=$(jq -r '.disposition' <<<"$finding_json")
curr_action=$(jq -r '.actionability' <<<"$finding_json")
curr_score=$(jq -r '.score_phase4 // "null"' <<<"$finding_json")
curr_hc=$(jq -c '.human_confirmation // null' <<<"$finding_json")
```

`curr_score` is the literal string `"null"` when the finding is
unscored; pass it through that way (the JSON encoder at step 5 handles
both the integer and null cases via `--argjson`).

### Step 4. Check preconditions

| `curr_disp` | Additional condition | Action |
|---|---|---|
| `confirmed_auto` | `curr_hc != null` | Exit 0 with: "F$N already promoted by @$(jq -r '.reviewer' <<<"$curr_hc") on $(jq -r '.ts' <<<"$curr_hc"); no-op." — pulling reviewer and timestamp from the existing `human_confirmation` object (the bash `$reviewer` / `$ts` vars are not yet set in step 4). |
| `confirmed_auto` | `curr_hc == null` | **Proceed.** Set `human_confirmation` to record the human override. May be strictly necessary (light-lane `confirmed_auto` fails the Phase 8 impact_type filter, deep-lane below-threshold `confirmed_auto` fails the score gate) or redundant-but-harmless audit (deep-lane above-threshold `confirmed_auto` was already eligible). Promote can't know the user's planned `/adams-review-fix` threshold, so always proceed. |
| `resolved` | — | Exit 1: "F$N is resolved (fix already ran); cannot promote." |
| `disproven` | `force == false` | Exit 1: "F$N was disproven by Phase 4 (score=$curr_score). Validator found positive evidence this isn't a real issue. Re-run with --force to override." |
| `disproven` | `force == true` | Proceed with a warning line in trace.md: `disproven→confirmed_auto via --force`. |
| `uncertain`, `below_gate`, `pre_existing_report`, `confirmed_manual`, `confirmed_report`, `pending_validation`, `partial`, `regression` | — | Proceed. |

For each exit-1 case, print a clear user message AND emit a one-line
`## promote (<ts>) — rejected` block to `trace.md` so rejections are
auditable.

**Note on the `confirmed_auto` + `curr_hc == null` row.** Previously a
blanket no-op ("already confirmed_auto by validator"). That was correct
only when the finding would also pass the §13.1 eligibility gate at
the threshold the user plans to fix at — which promote can't know.
Examples where the old no-op silently broke promote:

- Light-lane `confirmed_auto` (impact_type ∈ ux/policy/architecture) —
  fails the Phase 8 impact_type filter; needs `human_confirmation` to
  bypass (§27.6). This is the case `/adams-review-walkthrough`
  exists to address.
- Deep-lane `confirmed_auto` below the user's planned threshold — the
  user may run `/adams-review-fix 70` on a finding scored 55, which
  fails the score gate; needs `human_confirmation` to bypass the
  score gate.

The current "always proceed" is correct in both cases and harmlessly
redundant for deep-lane above-threshold findings (adds provenance
metadata confirming the human OK'd a fix that was already going to
happen — useful audit, not a functional change).

### Step 4.5. Auto-prompt for `fix_hint` when needed

Decide whether to prompt for `fix_hint` now that preconditions have
passed. The logic keys off `$fix_hint` (possibly empty from the
caller) and the finding's `validation_result`:

- `$fix_hint` is non-empty → skip the prompt; the caller already
  supplied a hint.
- `$fix_hint` is empty AND `finding.validation_result` is populated
  (the validator already supplied `fix_proposal.approach`) → skip the
  prompt. Callers who want to override the validator's approach can
  pass `--fix-hint` on their own command line.
- `$fix_hint` is empty AND `finding.validation_result` is `null` (no
  validator fix_proposal exists — common for light-lane findings and
  for deep-lane findings Phase 4 marked `uncertain`/`disproven`) →
  dispatch one `AskUserQuestion` whose option set depends on the
  claim text.

**Heuristic for the option set.** Lowercase the `claim` and scan for
any of these substrings: `docstring`, `doc comment`, `jsdoc`, `tsdoc`,
`comment`, `documentation`, `description`, `disagrees`, `mismatch`,
`out of date`, `outdated`, `stale`. If any match, the claim is
probably a doc/comment-vs-code mismatch; offer the canned options:

- "Update the text/docstring to match the code"
- "Update the code to match the text/docstring"
- "Other (I'll provide the hint)"
- "Skip — no steering hint"

If none match, skip the canned options and offer only:

- "Provide a hint (free-form)"
- "Skip — no steering hint"

For "Other" and "Provide a hint (free-form)", dispatch a follow-up
`AskUserQuestion` asking for the free-form hint string. For the two
canned options, use the option text verbatim as `fix_hint`. For
"Skip", leave `fix_hint` empty. Capture the final `fix_hint` string
(may be empty — empty means "no hint").

Callers that bypass the prompt (e.g. the walkthrough's briefing agent
already supplies a `fix_hint_if_picked` string) should pre-set
`$fix_hint` before including this fragment so the prompt is skipped.

### Step 5. Build the human_confirmation object

```bash
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

reviewer=$(git config user.email 2>/dev/null)
[[ -z "$reviewer" ]] && reviewer=$(git config user.name 2>/dev/null)
[[ -z "$reviewer" ]] && reviewer="unknown"

hc_tmp=$(mktemp -t adams-promote-hc.XXXXXX)
jq -n \
    --arg reviewer "$reviewer" \
    --arg reason "$reason" \
    --arg fix_hint "${fix_hint:-}" \
    --arg ts "$ts" \
    --arg prior_disp "$curr_disp" \
    --arg prior_action "$curr_action" \
    --argjson prior_score "$curr_score" \
    '{
      reviewer: $reviewer,
      reason: $reason,
      ts: $ts,
      promoted_from: {
        disposition: $prior_disp,
        actionability: $prior_action,
        score_phase4: $prior_score
      }
    }
    + (if $fix_hint != "" then {fix_hint: $fix_hint} else {} end)' > "$hc_tmp"
```

`$curr_score` was extracted as either a JSON integer string (e.g.,
`"45"`) or literal `"null"`; `--argjson` parses either correctly.
`fix_hint` is conditionally merged: omitted entirely (not literal
`null`) when empty, so pre-promote artifacts and promotions-without-
steering keep the legacy object shape.

### Step 6. Atomic patch

One `artifact-patch.py` call mutates all four fields in a single atomic
write. The helper enforces `is_actionable` coupling automatically:

```bash
~/.claude/commands/_shared/tools/artifact-patch.py \
    --path "$artifact_path" \
    --finding-id "$finding_id" \
    --set disposition=confirmed_auto \
    --set actionability=auto_fixable \
    --set-json "human_confirmation=@$hc_tmp"
rm -f "$hc_tmp"
```

On non-zero exit: surface the helper's error-as-prompt verbatim (it
already follows §8.6 convention) and abort WITHOUT proceeding to the
caller's render/publish. A failed patch means the artifact is
unchanged, so the rendered md on disk is already correct.

### Step 9. Append trace entry

```bash
{
    printf '## promote (%s)\n' "$ts"
    printf 'finding=%s reviewer=%s force=%s\n' "$finding_id" "$reviewer" "${force:-false}"
    printf 'promoted_from: disposition=%s actionability=%s score_phase4=%s\n' \
        "$curr_disp" "$curr_action" "$curr_score"
    printf 'reason: %s\n' "$reason"
    [[ -n "${fix_hint:-}" ]] && printf 'fix_hint: %s\n' "$fix_hint"
    printf '\n'
} >> "$trace_log_path"
```

Step numbering (3, 4, 4.5, 5, 6, 9) matches the original
`/adams-review-promote` step numbers for continuity with DESIGN §27
and existing trace.md entries. The top-level command owns steps 1, 2,
7, 8, 10.
