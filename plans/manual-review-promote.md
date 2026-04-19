# Plan: /adams-review-promote — human override to auto-fix

Status: draft, awaiting approval
Branch: `manual-review-flag`
Related DESIGN sections to update: §5.2.1 (disposition table), §6 (artifact schema), §13.1 (score decision table), §13.2 (thresholds), §19.8 (Phase 8 fix-group note — unchanged but referenced)

## 1. Goal

Give a human reviewer a single-command path to promote any finding to auto-fix, overriding both the validator's scoring gate and the impact_type lane restriction, with full provenance preserved in the artifact.

Concrete use case: a human reads `/adams-review`'s PR comment, sees three findings in "Uncertain" or "Requires manual attention" that they want auto-fixed, runs `/adams-review-promote F003 --reason "validator was too conservative"` for each, then `/adams-review-fix` and those three get fixed alongside whatever was already confirmed_auto.

## 2. Non-goals / explicitly deferred

- **Re-run persistence across fresh `/adams-review` invocations.** Promotions live in `artifact.json` and are lost if the user re-reviews the branch. Revisit as a sidecar `overrides.json` when the pain is felt (see §13 of this plan).
- **Symmetric demotion** (`/adams-review-promote --undo` or `/adams-review-demote`). User can already skip findings by passing a higher `--threshold` or (future) a finding-id denylist to `/adams-review-fix`.
- **Bulk promotion** (`--file-id F001,F002,F003` or array input). One finding per invocation keeps preconditions simple; low cost to loop from the shell.
- **Auto-run fix after promote.** Promote patches + republishes only. User still runs `/adams-review-fix` explicitly.

## 3. Key design decisions

### 3.1 Don't bump score_phase4; instead bypass the gate

Earlier draft considered bumping `score_phase4` to 90. Replaced with selector bypass: `score_phase4` stays as the validator's honest score, and Phase 8 eligibility gains `OR .human_confirmation != null`. Reasons:

- `score_phase4` being settable auto-appends to `score_history` (`artifact-patch.py:472-473`) with phase `phase_4`. That would record a fake "phase_4 scored this at 90" entry — misleading audit trail.
- Score history enum (`score_phase_enum`) is narrowly scoped: `{phase_3, phase_4, phase_4a, phase_4b}`. Adding `phase_manual` would ripple through every consumer; adding the bypass to the selector is a one-line gate change.
- Philosophically: human override is meta-information about the finding, not a new score. Storing it as metadata (`human_confirmation`) keeps the signals orthogonal.

### 3.2 Helper stays minimal; orchestrator owns preconditions

Rather than add a `--promote-finding` mode to `artifact-patch.py`, reuse the existing `--set`/`--set-json` machinery:

- Add `human_confirmation` to `JSON_SETTABLE_FINDING_FIELDS`.
- The slash command issues ONE patch call that mutates four fields atomically: `disposition`, `actionability`, `human_confirmation` (+ the derived `is_actionable` from existing coupling).
- Preconditions (refuse `confirmed_auto`/`resolved`, require `--force` on `disproven`) live in the command markdown; they're straightforward state reads, no new helper logic needed.

This matches the existing split: helpers enforce schema + coupling + state transitions; orchestrators enforce phase-specific business logic.

### 3.3 `promoted_from` captures full state triple

Schema: `promoted_from: {disposition, actionability, score_phase4}`. Because promotion can cross axes (ux → auto_fixable changes `actionability`; low-score → effectively-eligible changes the audit picture around `score_phase4` even though we don't touch the value), the snapshot needs all three so a future reader can reconstruct what the human overrode.

## 4. Schema change (commands/_shared/schema-v1.json)

Add `human_confirmation` to the `finding` definition as an optional nullable object. NOT added to `required` — existing artifacts must stay valid.

```jsonc
"human_confirmation": {
  "description": "Present when a human ran /adams-review-promote on this finding. Bypasses the Phase 8 impact_type lane filter and score threshold.",
  "anyOf": [
    { "type": "null" },
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["reviewer", "reason", "ts", "promoted_from"],
      "properties": {
        "reviewer": { "type": "string", "minLength": 1 },
        "reason":   { "type": "string", "minLength": 1 },
        "ts":       { "type": "string", "format": "date-time" },
        "promoted_from": {
          "type": "object",
          "additionalProperties": false,
          "required": ["disposition", "actionability", "score_phase4"],
          "properties": {
            "disposition":   { "$ref": "#/$defs/disposition_enum" },
            "actionability": { "$ref": "#/$defs/actionability_enum" },
            "score_phase4": {
              "anyOf": [
                { "type": "integer", "minimum": 0, "maximum": 100 },
                { "type": "null" }
              ]
            }
          }
        }
      }
    }
  ]
}
```

Default on new findings: `null` (Phase 0's `--add-finding` seeds or Phase 1 detection output should include `"human_confirmation": null`). Because the field is optional, pre-existing artifacts without it remain schema-valid and render fine — the renderer and selector both treat missing as equivalent to `null`.

## 5. Helper changes (commands/_shared/tools/artifact-patch.py)

**One-line change**: add `"human_confirmation"` to `JSON_SETTABLE_FINDING_FIELDS` (line ~290). This opens `--set-json human_confirmation=@<file>` to callers.

No new mode. No coupling rules to enforce (the field is metadata; doesn't couple to disposition or current_state).

Rationale: keeps the helper's surface area small, makes the patch auditable in the standard trace (each `--set`/`--set-json` already logs through the existing write path).

## 6. Phase 8 selector change (commands/_shared/09-fix-execution.md)

Modify the jq in step 8.1 (currently `09-fix-execution.md:15-23`) from:

```jq
[.findings[]
 | select(.current_state == "open")
 | select(.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
 | select(.impact_type == "correctness" or .impact_type == "security")
 | select(.score_phase4 != null and .score_phase4 >= $thr)
 | .id
] | join(",")
```

to:

```jq
[.findings[]
 | select(.current_state == "open")
 | select(.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
 | select(
     (.human_confirmation != null)
     or (
       (.impact_type == "correctness" or .impact_type == "security")
       and (.score_phase4 != null and .score_phase4 >= $thr)
     )
   )
 | .id
] | join(",")
```

Update the eligible_count jq in step 8.1 identically. Update the prose explainer above the jq to mention the human_confirmation bypass.

DESIGN §5.2.1 and §13.1 both contain prose versions of the same rule ("Phase 8 eligibility"); update those too to keep the three copies (spec + fragment + rendered markdown) in sync.

## 7. New top-level command (commands/adams-review-promote.md)

```
---
allowed-tools: Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-read.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-patch.py:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-validate.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-render.py:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-publish.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/repo-slug.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(cat:*), Bash(printf:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Read, AskUserQuestion
argument-hint: "<finding_id> [--reason \"...\"] [--force]"
description: Promote a finding to auto-fixable (human override). Sets disposition=confirmed_auto, records provenance, re-renders, re-publishes.
disable-model-invocation: false
---
```

Body outlines these steps (each self-contained, error-as-prompt on failure):

### 7.1 Argument parsing

Parse `$ARGUMENTS`:
- First positional matching `^F[0-9]+$` → `finding_id`.
- `--reason "..."` (quoted) → `reason`. If absent, prompt via AskUserQuestion with three options: "not a real finding-of-the-week — just a judgment call," "validator was too conservative here," or free-form. Default captured reason at minimum.
- `--force` → bypass disproven refusal.

### 7.2 Locate the artifact

Identical to `adams-review-fix.md` Phase 7.2: derive `reviews_root`, `head_branch`, `repo_slug`, read `latest.txt`, set `artifact_path`, `review_dir`, `trace_log_path`. Same helper call to `repo-slug.sh` (op-rule #7).

If `latest.txt` missing/empty: error-as-prompt "No review found for this branch. Run `/adams-review` first."

### 7.3 Read the finding + preconditions

```bash
finding_json=$("$TOOLS/artifact-read.sh" --path "$artifact_path" \
    --filter ".findings[] | select(.id == \"$finding_id\")")
```

If empty: error-as-prompt with closest-match suggestion (helper already does this via `--finding-id` semantics; this reads too so we do it inline — one shot to match).

Extract `curr_disp`, `curr_action`, `curr_score`, `curr_hc` via jq.

Preconditions:
| current disposition | action |
|---|---|
| `confirmed_auto` + `human_confirmation != null` | exit 0 with "Already promoted by $reviewer; no-op" |
| `confirmed_auto` (no human_confirmation) | exit 0 with "Already confirmed_auto by validator; no-op" |
| `resolved` | exit 1: "Finding resolved; cannot promote." |
| `disproven` and no `--force` | exit 1: "Validator disproved this (score=$curr_score). Pass --force to override." |
| `disproven` with `--force`, OR `uncertain`, `below_gate`, `pre_existing_report`, `confirmed_manual`, `confirmed_report`, `pending_validation` | proceed |

### 7.4 Build the patch

```bash
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
reviewer=$(git config user.email 2>/dev/null || git config user.name 2>/dev/null || echo "unknown")

human_confirmation=$(jq -nc \
    --arg reviewer "$reviewer" \
    --arg reason "$reason" \
    --arg ts "$ts" \
    --arg prior_disp "$curr_disp" \
    --arg prior_action "$curr_action" \
    --argjson prior_score "${curr_score:-null}" \
    '{
      reviewer: $reviewer, reason: $reason, ts: $ts,
      promoted_from: {
        disposition: $prior_disp,
        actionability: $prior_action,
        score_phase4: $prior_score
      }
    }')
echo "$human_confirmation" > "/tmp/adams-promote-hc-$finding_id.json"
```

### 7.5 Atomic patch

```bash
"$TOOLS/artifact-patch.py" --path "$artifact_path" --finding-id "$finding_id" \
    --set disposition=confirmed_auto \
    --set actionability=auto_fixable \
    --set-json "human_confirmation=@/tmp/adams-promote-hc-$finding_id.json"
rm -f "/tmp/adams-promote-hc-$finding_id.json"
```

All four mutations (including derived `is_actionable`) land in one atomic write. If it fails (schema, coupling, etc.), the artifact is untouched.

### 7.6 Re-render + re-publish

```bash
"$TOOLS/artifact-render.py" --input "$artifact_path" --output "$review_dir/artifact.md"
```

Then publish — reuse Phase 6.7's discovery chain. If `mode == pr`:

```bash
"$TOOLS/artifact-publish.sh" --mode pr --review-id "$review_id" --pr "$pr_number" \
    --repo-slug "$repo_slug" --branch "$head_branch" --review-dir "$review_dir" \
    --comment-id "$comment_id"
```

(`--comment-id` from the artifact when present; falls through to marker search if not.) If `mode == local`: `--mode local` no-op.

On publish failure: log to `trace.md` with tag `promote_publish_failed`, surface to user, but artifact patch stands (same §24.4 "artifact-records-commit-before-network" pattern).

### 7.7 Trace entry

```bash
{
    echo "## promote ($ts)"
    echo "finding=$finding_id reviewer=$reviewer promoted_from=$curr_disp force=${force:-false}"
    echo "reason: $reason"
    echo ""
} >> "$trace_log_path"
```

### 7.8 User-visible summary

Print one block summarizing what changed:

```
Promoted F037:
  disposition: uncertain → confirmed_auto
  actionability: report_only → auto_fixable
  reviewer: you@example.com
  reason: validator too conservative on the off-by-one
Next: /adams-review-fix will include F037 on its next run.
```

No `phases.jsonl` entry — promote isn't a pipeline phase.

## 8. Renderer change (commands/_shared/tools/artifact-render.py)

Two spots:

**8.1. In `_finding_detail()` (around line 267)**, after the existing `**Reason:**` line, emit a new line when `human_confirmation` is set:

```python
hc = f.get("human_confirmation")
if hc:
    lines.append(f"**Human-confirmed:** @{hc.get('reviewer','?')} on {hc.get('ts','?')} — {hc.get('reason','')}")
    pf = hc.get("promoted_from") or {}
    lines.append(f"_Promoted from {pf.get('disposition','?')} / {pf.get('actionability','?')} / score_phase4={pf.get('score_phase4','null')}_")
```

**8.2. In the auto-fixable table rows** (around line 227-232), add a small `(human-confirmed)` tag after the claim when `human_confirmation` is set:

```python
claim_cell = f.get("claim", "")
if f.get("human_confirmation"):
    claim_cell = f"{claim_cell} <sub>(human-confirmed)</sub>"
lines.append(
    f"| {f.get('id')} | ... | {claim_cell} | ..."
)
```

Kept subtle — `<sub>` tag renders fine in GitHub Markdown.

## 9. Symlink (one-shot setup)

Per op-rule #10 and CLAUDE.md "Layout":

```bash
ln -s "$PWD/commands/adams-review-promote.md" \
      ~/.claude/commands/adams-review-promote.md
```

(The `_shared/` directory symlink already propagates any helper changes; only new top-level commands need per-command symlinks.)

## 10. DESIGN.md updates

### §5.2.1 — extend invariants block

Add below the existing "current_state == 'resolved' ⇔ disposition == 'resolved'" bullet:

> - `human_confirmation` is null on fresh findings. Set only by `/adams-review-promote` (§27, new section). Present-and-non-null implies the human has overridden the validator's verdict; Phase 8 eligibility treats `human_confirmation != null` as a bypass of both the impact_type lane filter (§13.2) and the `score_phase4 >= threshold` gate (§13.1).

Update the **Phase 8 eligibility** code block at §5.2.1 to the new jq form (from §6 of this plan).

### §6 — artifact schema example

Add `"human_confirmation": null,` to the example finding near the other field comments, with an inline comment pointing to §5.2.1.

### §13.1 — score decision table

Add a footnote row / prose paragraph under the table:

> **Manual override.** `/adams-review-promote` sets `disposition=confirmed_auto`, `actionability=auto_fixable`, and `human_confirmation=<object>` on any finding except `confirmed_auto` (no-op) and `resolved` (rejected). `disproven` requires `--force`. The existing `score_phase4` is preserved (the validator's honest score); Phase 8 eligibility bypasses both gates when `human_confirmation != null` (see §5.2.1).

### §13.2 — thresholds

Add below the "Optional flag (future): `--include-light-fixes`" line:

> **Human override precedence.** `human_confirmation != null` bypasses both the impact_type lane filter and the score threshold. Set by `/adams-review-promote`; the threshold still applies to validator-scored findings.

### New §27 — /adams-review-promote (slash command)

A one-page section describing the command's contract mirroring the structure of §13.1 / §19.8 (inputs, mutations, preconditions, trace format). Cross-links from §5.2.1 and §13.2.

## 11. Smoke assertions (test/smoke.sh)

Add new `MP-*` (manual-promote) block with 6 assertions, structured like the existing `CF-*` / `FR-*` blocks:

| # | Label | Checks |
|---|---|---|
| MP-1 | `human_confirmation` accepted as schema-valid when null | `--init` of seed with `"human_confirmation": null` on each finding passes `artifact-validate.sh` |
| MP-2 | `human_confirmation` accepted as schema-valid when populated | `--set-json human_confirmation=<object>` on F001 passes validation |
| MP-3 | Incomplete `human_confirmation` (missing `promoted_from`) rejected | `--set-json` with a partial object fails validation with exit 1 |
| MP-4 | Promoted ux-finding becomes fix-eligible | Fixture: ux finding with `score_phase4=30`, `disposition=uncertain`. After `--set disposition=confirmed_auto --set actionability=auto_fixable --set-json human_confirmation=<valid>`, the Phase 8 eligibility jq returns it |
| MP-5 | Unpromoted ux-finding stays fix-ineligible | Same fixture without `human_confirmation` mutation — eligibility jq returns empty |
| MP-6 | Renderer shows "(human-confirmed)" tag | After MP-4's mutation, `artifact-render.py` output contains `(human-confirmed)` somewhere in the F00X row or details |

Total assertion count changes from **105 → 111**. Update the final `smoke: PASS (N assertions)` expectation (it reads `$N` dynamically; only docs mention the 105 count).

## 12. Execution order (one commit per group)

Commit at natural breakpoints per CLAUDE.md:

1. **Schema + helper allowlist** (one commit): schema-v1.json adds `human_confirmation` def; artifact-patch.py adds to allowlist.
2. **Phase 8 selector bypass** (one commit): 09-fix-execution.md jq + DESIGN §5.2.1 + DESIGN §13.1 + DESIGN §13.2.
3. **Renderer tags** (one commit): artifact-render.py emits human-confirmed tags.
4. **Promote command** (one commit): commands/adams-review-promote.md + symlink note in CLAUDE.md if needed (check — layout section already covers it).
5. **DESIGN §27** (one commit): new section + smoke assertions.
6. **Smoke harness** (one commit): MP-1 through MP-6.

Each commit runs `test/smoke.sh` and stays green (commits 1-3 add no assertions; commits 4-6 do). If a commit breaks existing assertions, fix before moving on.

## 13. Future work (explicitly out of scope)

- **overrides.json sidecar** for re-run persistence: `~/.adams-reviews/<slug>/<branch>/overrides.json` keyed by `(file, line_range, claim_fingerprint)`. Phase 0 loads → Phase 4 applies after decision table. Natural next step when user feels the "my promotions evaporated" pain.
- **Bulk promotion** / batched `--promote-findings F001,F002,F003` mode following the batched-helper pattern per CLAUDE.md.
- **Promote history / audit trail**: if the same finding gets promoted multiple times (re-promoted after a demote), we currently just overwrite `human_confirmation`. Could add `promotion_history: []` analogous to `fix_attempts: []` when needed.

## 14. Risk check

Blast radius per global CLAUDE.md:

- **Every writer** of `disposition`, `actionability`, `score_phase4`: Phase 3 (04-scoring-gate), Phase 4 (05-validation via `--apply-decisions`), Phase 9 (09-fix-execution via `--apply-fix-outcomes`). None of them write `human_confirmation`; none of them read it either. Promote writes it independently. No writer collision.
- **Every consumer** of the Phase 8 selector: `09-fix-execution.md:15-23` is the only place. The cross-cutting sub-agent (`06-cross-cutting.md:21`) filters on `is_actionable: true` — a promoted finding has `is_actionable=true` via the existing derivation, so it'll be included in cross-cutting analysis, which is what we want.
- **Parallel paths**: `--apply-decisions` and `--set disposition=...` are two paths to setting disposition. `--apply-decisions` derives disposition from score + actionability per §13.1; it never produces `confirmed_auto` for a non-correctness/security finding (the lane filter is a separate concern there). Promote uses `--set` directly, bypassing the derivation. That's intentional — the whole point is to skip the decision table.
- **Stale comments/docs**: §5.2.1 table, §13.1 table, §13.2 threshold table, §19.8 prompt (check — mentions impact_type filter), §21.2 (artifact-patch contract — update to note new allowlisted field), §25.2 working-set (no change, promote doesn't participate in Phase 7-9 working set).

Post-execution once-over will re-read the actual diff and check these again.
