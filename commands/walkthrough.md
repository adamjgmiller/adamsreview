---
allowed-tools: Bash(artifact-read.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(repo-slug.sh:*), Bash(log-tokens.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(cat:*), Bash(printf:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(tr:*), Bash(awk:*), Bash(mktemp:*), Agent, Read, AskUserQuestion
argument-hint: "[threshold]"
description: Walk interactively through findings /adamsreview:fix would skip, above a score floor. Per-finding briefing + options + recommendation, then batch re-render/re-publish and post a decisions-log PR comment.
disable-model-invocation: false
---

Walk the reviewer through findings in the latest `/adamsreview:review`
artifact that `/adamsreview:fix` would **skip** — deep-manual,
deep-report, light-manual, light-report, and light-auto that fails
the impact_type lane filter — further restricted to findings scoring
**at or above `$threshold`** so low-signal items don't pad the
session. For each
finding, dispatch a Sonnet briefing agent (claim → options →
recommendation), ask the reviewer to decide, and record a promote (via
the shared `promote-core.md` fragment with `--defer-publish`
semantics) or a skip. At the end, render + publish the updated review
once, then POST a separate decisions-log comment to the PR for audit.

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every step below (sub-agent return handling,
helper-script error-as-prompt).**

## Arguments

- `[threshold]` (optional, positional) — non-negative integer score
  floor. Default: 60. Findings with effective score
  (`COALESCE(score_phase4, score_phase3, -1)`) below this value are
  dropped from the walk scope so the session isn't padded with
  low-signal findings. Independent of the `/adamsreview:fix`
  threshold — promoted findings are picked up by `/adamsreview:fix`
  regardless of the score gate via the `human_confirmation` bypass.

## What it does

1. Parses the threshold.
2. Locates the artifact for the current branch.
3. Computes three walkthrough scopes (qualifying / full / pre-existing).
4. Shows a pre-flight summary + asks the reviewer which tier to walk
   (default **Qualifying**; **Full skip set** is the opt-in for
   auditing Phase-3-demoted findings).
4.5. **Auto-recommendation batch.** When any in-scope finding carries
   an `auto_fix_hint` from Phase 5.5, surfaces a batch confirm UI
   (Accept all / Pick subset / Walk through each). Accepted findings
   are promoted via `--apply-auto-rec-promotions` and removed from
   the per-finding loop's working scope.
5. For each remaining finding in the chosen tier:
   - When the finding has `auto_fix_hint` (i.e., it was in scope at
     §4.5 but the reviewer chose Walk-each / didn't include it in
     Pick-subset), constructs the briefing inline from `auto_fix_hint`
     — saves the ~3-5k tokens a Sonnet briefer would cost.
   - Otherwise, dispatches a Sonnet briefing sub-agent →
     `{summary, options[], recommendation}`.
   - Presents the briefing and asks the reviewer which option to pick
     (or "Edit the fix hint" to override the recommended option's hint).
   - Dispatches a promote (patch + trace, no render/publish) or a skip.
6. Re-renders `artifact.md` once.
7. Re-publishes the main review comment once.
8. For each `pre_existing_report` finding (PR mode only): offers to
   draft + create a GitHub issue, one by one.
9. Posts a new "Walkthrough decisions" comment to the PR with the
   full log of what was auto-accepted / promoted / skipped / issues
   filed / why.
10. Appends a `## walkthrough (<ts>)` block to `trace.md`.
11. Prints a user-visible summary.

Does NOT run `/adamsreview:fix`. Does NOT surface `disposition=disproven`
findings (those require an explicit `/adamsreview:promote <id> --force`).

## Execution

Work through the steps below in order. Capture each named variable
into your working context. Build a TaskList that mirrors these step
headings.

### 1. Parse arguments

Parse `$ARGUMENTS` (whitespace-split):

- First token that parses as a non-negative integer → `threshold`.
- Any other token → stop and ask the user to clarify.

If no integer was provided, `threshold=60` (matches the
`/adamsreview:fix` default and the Phase 4 moderate-confirmation
breakpoint, so the walkthrough shows what a reviewer at standard
confidence would want to see). Record in your working context.

### 2. Locate the artifact

```bash
reviews_root="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
repo_slug=$(repo-slug.sh --repo-root "$repo_root")
latest_path="$reviews_root/$repo_slug/$head_branch/latest.txt"
```

If `latest.txt` is missing or empty, error-as-prompt:

> ERROR: no review found for branch `$head_branch` under
> `$reviews_root/$repo_slug/`.
> Action: run /adamsreview:review against this branch first.

Otherwise:

```bash
review_id=$(tr -d '[:space:]' < "$latest_path")
review_dir="$reviews_root/$repo_slug/$head_branch/$review_id"
artifact_path="$review_dir/artifact.json"
trace_log_path="$review_dir/trace.md"
```

Capture paths. Schema-validate:

```bash
artifact-validate.sh --path "$artifact_path"
```

On non-zero: surface the validator stderr and abort.

Extract `mode` and `pr_number` from the validated artifact now — both
are needed by §3's mode-aware exit checks, §4's preflight messaging,
§6.2's publish call, §6.5's issue-filing gate, and §7's decisions-log
POST:

```bash
mode=$(jq -r '.mode' "$artifact_path")
pr_number=$(jq -r '.pr_number // empty' "$artifact_path")
```

(`comment_id` is extracted later in §6.2 — it's only read by the
publish call, and deferring it keeps the "reviewer cancelled early"
paths from unnecessarily reading it.)

### 3. Compute walkthrough scope

The walkthrough surfaces findings `/adamsreview:fix` would SKIP at
`$threshold`. Compute three parallel id sets so the preflight at step
4 can offer a tiered choice (default Qualifying) and step 6.5 can
handle `pre_existing_report` findings on a separate track.

**`scope_full_ids`** — the inverse of the Phase 8 eligibility selector
at `09-fix-execution.md` step 8.1 (minus terminal + already-promoted),
**further reduced by excluding `pre_existing_report`** which is routed
exclusively to §6.5's issue-filing phase and is never surfaced for
promotion (a user may still direct Claude off-menu to promote a
specific pre-existing finding; §6.5 defends against the double-
processing that would otherwise create), **then filtered by the
`$threshold` score floor** so low-signal findings don't pad the walk.
The score-floor uses `COALESCE(score_phase4, score_phase3, -1)` so
`below_gate` findings (which have no `score_phase4`) fall back to
their `score_phase3`; missing-both collapses to `-1` and is filtered
out at any non-negative threshold. **Keep the Phase-8-inverse shape in
sync with `09-fix-execution.md`; the pre-existing exclusion and score
floor are specific to the walkthrough.**

```bash
scope_full_ids=$(jq -r --argjson thr "$threshold" '
    [.findings[]
     # Not terminal: skip resolved / disproven / pending_validation.
     | select(.current_state == "open")
     | select(.disposition != "resolved")
     | select(.disposition != "disproven")
     | select(.disposition != "pending_validation")
     # Pre-existing findings are handled only via §6.5 issue filing;
     # never walked for promotion. (See header comment above.)
     | select(.disposition != "pre_existing_report")
     # Skip already-promoted (human_confirmation set). Re-running the
     # walkthrough mid-session naturally picks up where it left off.
     | select(.human_confirmation == null)
     # Include iff the Phase 8 gate would skip it — the inverse of
     # 09-fix-execution.md step 8.1 (§13.1, §13.2). Note: jq's `not`
     # is a filter (pipe into it), not a function.
     | select(
         (
           (.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
           and (
             (.impact_type == "correctness" or .impact_type == "security")
             and (.score_phase4 != null and .score_phase4 >= $thr)
           )
         ) | not
       )
     # Score floor: drop findings below the walkthrough threshold so the
     # session stays focused on high-signal items. COALESCE falls back
     # to phase3 for below_gate (no phase4), and to -1 if neither is set
     # (so null-scored findings are excluded at any threshold > 0).
     | select((.score_phase4 // .score_phase3 // -1) >= $thr)
     | .id
    ] | join(",")
' "$artifact_path")
```

**`scope_qualifying_ids`** — `scope_full_ids` minus the two
dispositions that dilute the signal: `below_gate` (Phase 3 already
judged these low-impact × low-confidence) and `pre_existing_report`
(routed to the dedicated issue-filing phase at step 6.5). This is
the new default tier.

```bash
scope_qualifying_ids=$(jq -r --argjson thr "$threshold" '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition != "resolved")
     | select(.disposition != "disproven")
     | select(.disposition != "pending_validation")
     | select(.disposition != "below_gate")
     | select(.disposition != "pre_existing_report")
     | select(.human_confirmation == null)
     | select(
         (
           (.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
           and (
             (.impact_type == "correctness" or .impact_type == "security")
             and (.score_phase4 != null and .score_phase4 >= $thr)
           )
         ) | not
       )
     # Score floor — same rule as scope_full_ids. Phase3 fallback is
     # irrelevant here (below_gate is already excluded above), but kept
     # for symmetry with scope_full_ids so the two stay easy to diff.
     | select((.score_phase4 // .score_phase3 // -1) >= $thr)
     | .id
    ] | join(",")
' "$artifact_path")
```

**`scope_preexisting_ids`** — open `pre_existing_report` findings,
independent of the fix-skip logic. Feeds step 6.5 (issue filing).
Already-promoted pre-existing findings are excluded for the same
resume-cleanly reason as the other scopes.

```bash
scope_preexisting_ids=$(jq -r '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "pre_existing_report")
     | select(.human_confirmation == null)
     | .id
    ] | join(",")
' "$artifact_path")
```

Counts:

```bash
count_ids() {
    # $1: comma-separated id string
    if [[ -z "$1" ]]; then echo 0; else awk -F, '{print NF; exit}' <<<"$1"; fi
}

scope_full_count=$(count_ids "$scope_full_ids")
scope_qualifying_count=$(count_ids "$scope_qualifying_ids")
scope_preexisting_count=$(count_ids "$scope_preexisting_ids")
```

If **all three** are empty, exit cleanly:

```
No findings to walk through at score floor $threshold.

Either every finding is already auto-eligible (run /adamsreview:fix
to apply them), every remaining skip-eligible finding scored below the
floor (re-run with a lower threshold to see them), or the review has
no actionable findings left. Nothing to do.
```

Exit 0.

If `scope_full_count == 0` AND `scope_preexisting_count > 0` AND
`mode == "local"`, also exit cleanly — the only remaining work
(pre-existing issue filing at §6.5) requires a PR to link against, so
local mode can't deliver it and falling through to §4 would promise
work the run can't perform:

```
$scope_preexisting_count pre-existing finding(s) in this review, but
local mode has no PR to file issues against. Re-run
/adamsreview:walkthrough on the PR branch (or use the GitHub UI)
to file them. Nothing to do here.
```

Exit 0. If `scope_full_count == 0` but `scope_preexisting_count > 0`
AND `mode == "pr"`, fall through to step 4 anyway — the preflight
will note that the walk has no scope but the issue-filing phase still
has work to offer.

### 4. Pre-flight summary + go/no-go

Before the preview table, render this short preamble so the reviewer
understands what "scope" means here:

```markdown
**Understanding the scope.** Three different gates govern this pipeline,
plus a fourth floor specific to this walkthrough:

- **Phase 3 scoring gate (45)** — filters candidates into validation.
  Failures get `disposition=below_gate` and no `score_phase4`.
- **Phase 4 confirmation gate (45/60/75)** — maps `score_phase4` into
  `disproven` / `uncertain` / `confirmed_*`.
- **Phase 8 fix gate (default 60)** — what `/adamsreview:fix` touches:
  confirmed_mechanical + deep lane + score ≥ threshold.
- **Walkthrough score floor (`$threshold`, default 60)** — the
  argument to this command. A display filter that drops findings below
  the floor so the session focuses on high-signal items. Independent
  of the fix gate: findings promoted here get picked up by
  `/adamsreview:fix` regardless of its threshold, via the
  `human_confirmation` bypass.

The walkthrough surfaces what Phase 8 would SKIP, minus anything below
the floor. `below_gate` is a **disposition name**, not a threshold —
Phase 3 already demoted those as low-impact × low-confidence, and the
score floor excludes them at default threshold=60 (fall back to
`score_phase3` means a low threshold like 30 would surface them for
auditing). Pre-existing findings (`pre_existing_report`) are handled
on a separate track at the end of the run (file GitHub issues for
base-branch bugs instead of trying to fix them here); they are not
score-floored.
```

Render a compact preview table covering all of `scope_full_ids` (so
the reviewer sees the full picture before picking a tier). Add a
`tier` column that categorizes each row:

- `qualifying` — would be included in the default tier
- `below_gate` — Phase 3 demoted
- `pre_existing` — routed to step 6.5 issue filing (not walked)

```bash
preview=$(jq -r --arg ids "$scope_full_ids" --arg preids "$scope_preexisting_ids" --argjson thr "$threshold" '
    # Preview covers both walk-eligible ids (scope_full_ids) AND
    # pre-existing ids (scope_preexisting_ids) so the reviewer sees
    # every finding that either tier or §6.5 will touch. split("")
    # on an empty string yields [""]; the inner select filters that
    # out via the non-empty-id guard.
    (($ids | split(",")) + ($preids | split(","))) as $want
    | [.findings[]
       | select(.id as $id | ($id | length) > 0 and ($want | index($id)))
       | {
        id,
        tier: (
          if (.disposition == "below_gate") then "below_gate"
          elif (.disposition == "pre_existing_report") then "pre_existing"
          else "qualifying" end
        ),
        lane: .validation_lane,
        impact: .impact_type,
        disposition,
        score: (.score_phase4 // .score_phase3 // "—"),
        file: .file,
        claim_first_line: (.claim | split("\n") | .[0])
      }]
    | (["# ", "tier", "lane", "impact", "disposition", "score", "file", "claim"] | @tsv),
      (.[] | [.id, .tier, .lane, .impact, .disposition, (.score|tostring), .file, .claim_first_line] | @tsv)
' "$artifact_path")
```

If `scope_preexisting_count > 0`, mention it explicitly under the
table: "N pre-existing finding(s) are excluded from both walk tiers
and will be offered as GitHub issues at the end of the run." This
prevents the "where did F005 go?" variant of the same confusion.

Then dispatch `AskUserQuestion` with three options. Default
highlighted on Qualifying:

- "⭐ Qualifying only — walk $scope_qualifying_count finding(s) (recommended)"
- "Full skip set — walk $scope_full_count finding(s) (adds \`below_gate\` when score floor admits their \`score_phase3\`)"
- "Cancel — don't change anything"

Edge case: if `scope_qualifying_count == 0` and `scope_full_count > 0`,
the only useful walk choice is "Full." Offer only "Full" and "Cancel"
in that case — no recommendation star, since Qualifying is empty.
If `scope_full_count == 0` AND `scope_preexisting_count > 0` (only
pre-existing findings remain), skip the walk `AskUserQuestion`
entirely and set `scope_tier="none"` directly. Print a one-line note
like "No walk scope at score floor $threshold; jumping to pre-existing
issue filing." Then continue normally: the timestamp/reviewer
capture below runs, step 5 loop iterates 0 findings (because
`scope_ids=""`), §6 tallies to all zeroes, §6's existing
`promote_count == 0` guard skips §6.1/§6.2, `scope_tier_title` is
derived, and §6.5 takes over. The §7 guard
("decisions empty AND issues_filed empty → skip POST") handles the
case where the reviewer then skips issue filing too.

Bind the `AskUserQuestion` result to `$scope_tier` (one of
`qualifying` / `full` / `cancel`). For the walk-skip edge case
(scope_full_count == 0, AskUserQuestion bypassed), set
`scope_tier="none"` directly. Then map it onto the loop variables
the rest of the command uses:

```bash
case "$scope_tier" in
    qualifying)
        scope_ids="$scope_qualifying_ids"
        scope_count="$scope_qualifying_count" ;;
    full)
        scope_ids="$scope_full_ids"
        scope_count="$scope_full_count" ;;
    none)
        # Walk skipped (only pre-existing remain). Bind empty so
        # §6 arithmetic (unreviewed_count = scope_count - …) works.
        scope_ids=""
        scope_count=0 ;;
    cancel)
        # exit 0 with a one-line note; no mutation
        ;;
esac
```

If the reviewer picks Cancel, exit 0 with a one-line note. No mutation.

Before entering the loop, capture the session timestamp + reviewer
identity. Used by step 7 (decisions-log header) and step 8 (trace
block header). Capturing before the loop ensures a single consistent
value across the session even though promote-core re-resolves
`$reviewer` per iteration:

```bash
walkthrough_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
reviewer=$(git config user.email 2>/dev/null)
[[ -z "$reviewer" ]] && reviewer=$(git config user.name 2>/dev/null)
[[ -z "$reviewer" ]] && reviewer="unknown"
```

### 4.5. Auto-recommendation batch (Phase 5.5 fast-path)

Phase 5.5 of `/adamsreview:review` (and `:codex-review` / `:add`)
generates an `auto_fix_hint` for findings the user typically accepts
during walkthrough — surfacing the recommendation upfront lets a
batch confirmation replace the per-finding loop for the typical
"AI proposes, user agrees" case (~90% acceptance rate observed).

This step runs after the scope-tier choice and BEFORE the per-finding
loop. Findings the reviewer accepts in batch are promoted via
`artifact-patch.py --apply-auto-rec-promotions` (which sources
`fix_hint` automatically from `finding.auto_fix_hint.hint` — do NOT
pass `fix_hint` in the payload) and removed from `scope_ids` so the
per-finding loop in §5 doesn't re-process them.

Initialize the decisions array up-front — used by both this step
(when batch acceptances land) and §5's loop. Initialize even when
§4.5 is skipped so §5 / §6 / §7 / §8 always have a defined array
to iterate:

```bash
decisions=()   # bash array of JSON-encoded objects; action ∈ {auto_accept, promote, skip, stop}
```

Skip the rest of step 4.5 entirely when `scope_tier == "cancel"` or
`scope_tier == "none"` (no walk scope to filter; auto-rec batch is
moot).

#### 4.5.1. Compute auto-rec eligibility within scope

Filter at consume time — intersect the chosen `scope_ids` with the
auto-rec eligibility predicate. The artifact already carries
`auto_fix_hint` for eligible findings; we additionally guard
`current_state == "open"` and `human_confirmation == null` so a
finding mid-promote (or already promoted off-menu) doesn't get
clobbered.

```bash
# Build a JSON array of the chosen-tier scope ids so jq can
# intersect against it. scope_ids is comma-separated.
scope_ids_json=$(printf '%s' "$scope_ids" | jq -R '
    if length > 0 then split(",") else [] end
')

auto_rec_in_scope=$(jq -c --argjson scope "$scope_ids_json" '
    [.findings[]
     | select(.id as $id | $scope | index($id))
     | select(.auto_fix_hint != null)
     | select(.human_confirmation == null)
     | select(.current_state == "open")
     | {
         id,
         file,
         line_range,
         claim,
         disposition,
         score: (.score_phase4 // .score_phase3 // null),
         auto_fix_hint
       }
    ]
' "$artifact_path")
auto_rec_count=$(jq 'length' <<<"$auto_rec_in_scope")
```

If `auto_rec_count == 0`, log a one-line note ("No auto-recommendations
in scope; entering per-finding loop.") and skip directly to §5 with
`scope_ids` unchanged. `decisions=()` was already initialized in
§4.5's prologue, so §5 / §6 / §7 / §8 have a valid empty array to
iterate.

#### 4.5.2. Render the auto-rec summary table

Render a markdown table to chat covering every auto-rec finding
in scope. Surface low-confidence and "concerns" rows prominently —
those are the cases the reviewer most needs to inspect:

```bash
auto_rec_table=$(jq -r '
    (["F-id", "score", "disp", "file:line", "hint", "confidence", "concerns"] | @tsv),
    (.[] | [
       .id,
       (.score | tostring),
       .disposition,
       (.file + ":" + (.line_range[0] | tostring)),
       (.auto_fix_hint.hint | gsub("\n"; " ") |
         (if length > 120 then (.[0:117] + "...") else . end)),
       .auto_fix_hint.confidence,
       (if .auto_fix_hint.second_opinion == "concerns"
        then ("⚠ " + ((.auto_fix_hint.concerns // []) | join("; ")))
        else "" end)
     ] | @tsv)
' <<<"$auto_rec_in_scope")
```

Render the table to chat with a heading like
`## Auto-recommendations available (N in scope)` and call out any
`confidence == "low"` or `second_opinion == "concerns"` rows in a
short note above the table — those entries should not be auto-accepted
without inspection. Build a list of "watch-out" ids:

```bash
auto_rec_watchout_ids=$(jq -r '
    [.[] | select(.auto_fix_hint.confidence == "low"
                  or .auto_fix_hint.second_opinion == "concerns")
         | .id] | join(", ")
' <<<"$auto_rec_in_scope")
```

If non-empty, emit a one-line note above the table:
"Watch out: [$auto_rec_watchout_ids] flagged low-confidence or
second-opinion concerns; consider Pick-subset / Walk-each instead
of Accept-all."

#### 4.5.3. Ask for the batch action

Dispatch `AskUserQuestion` with three options. **Note on rationale:**
the original spec called for four options including a "Skip auto-rec
batch" alongside "Walk through each." Both end with the same outcome
(continue to §5 with full scope; the §5.2 short-circuit handles the
auto-rec findings inline). Folded into a single "Walk through each
individually" option to keep cadence predictable — the per-finding
loop's short-circuit means there's no token cost difference between
the two original options.

- "Accept all $auto_rec_count auto-recommendation(s) (recommended)"
- "Pick subset to accept"
- "Walk through each individually"

Bind result to `$auto_rec_action` (one of `accept_all` / `pick_subset`
/ `walk_each`).

#### 4.5.4. Branch: build the accept set

Compute `accept_ids` (comma-separated) and `accept_payload`
(JSON array for the helper) based on the action:

**`accept_all`:** every id in `auto_rec_in_scope`.

```bash
accept_ids=$(jq -r '[.[].id] | join(",")' <<<"$auto_rec_in_scope")
```

**`pick_subset`:** dispatch `AskUserQuestion` (multi-select) with
one option per auto-rec finding:

```
"$id: <claim first line> — <hint truncated to 80c>"
```

If multi-select isn't available in the harness, fall back to a
free-form comma-separated id list (validate against
`auto_rec_in_scope` ids; reject unknowns with an error-as-prompt).
Capture chosen ids into `accept_ids`. Empty selection → equivalent
to `walk_each` (no batch promotion; `accept_ids=""`).

**`walk_each`:** `accept_ids=""` (no batch promotion; the §5 loop
walks every in-scope finding, but the §5.2 short-circuit will fire
on auto-rec findings to skip the briefer).

#### 4.5.5. Apply batch promotions (when `accept_ids` non-empty)

When `accept_ids` is empty (Walk-each, or Pick-subset with empty
selection), skip this whole step and §4.5.6 — there's nothing to
promote and no scope to strip. Drop straight to the chat note in
§4.5.6's trailing paragraph (which is also guarded on
`accept_ids` being empty) and proceed to §5.

Otherwise: build the payload for `--apply-auto-rec-promotions`. The
helper sources `fix_hint` automatically from
`finding.auto_fix_hint.hint`, so we DON'T pass `fix_hint` in the
payload (per Stage 1's contract). The `reviewer` follows the
convention `auto-rec/<email>` so the audit trail distinguishes
batch acceptance from manual promote.

```bash
if [[ -z "$accept_ids" ]]; then
    # No batch acceptances; skip §4.5.5 / §4.5.6 entirely and proceed
    # to §5. decisions[] stays empty; scope_ids unchanged.
    :
else
    accept_ids_json=$(printf '%s' "$accept_ids" | jq -R '
        if length > 0 then split(",") else [] end
    ')

    payload_path="$review_dir/walkthrough_step4_5_promotions.json"
    jq -n \
        --argjson chosen "$accept_ids_json" \
        --arg reviewer "auto-rec/$reviewer" \
        --arg reason "auto-recommendation accepted in :walkthrough Step 4.5 batch" \
        '[$chosen[] | {id: ., reviewer: $reviewer, reason: $reason}]' \
        > "$payload_path"

    expected_count=$(jq 'length' "$payload_path")

    artifact-patch.py \
        --path "$artifact_path" \
        --apply-auto-rec-promotions "@$payload_path" \
        --expected "$expected_count"
    patch_rc=$?

    if [[ $patch_rc -ne 0 ]]; then
        # Helper emitted error-as-prompt to stderr. Log to trace and abort
        # Step 4.5 — the per-finding loop in §5 can still run on the
        # remaining (un-accepted) scope; preceding tuples in the batch
        # may have committed (first-fail-halt semantics).
        {
            printf '## walkthrough_auto_rec_batch_failed (%s)\n' "$walkthrough_ts"
            printf 'patch_rc=%s payload=%s\n\n' "$patch_rc" "$payload_path"
        } >> "$trace_log_path"
        # Surface a one-line note to the user pointing at the trace
        # entry; continue to §5 with scope_ids unchanged so they can at
        # least walk what they would have anyway.
        printf 'Step 4.5 batch promote failed (rc=%s). See %s.\n' \
            "$patch_rc" "$trace_log_path"
    else
        rm -f "$payload_path"
    fi
fi
```

On success (the inner `else` branch above), append one `decisions[]`
entry per promoted finding so §7's decisions-log can render them
under the "Auto-accepted" subsection and §8's trace block tallies
them correctly. The `prior_disposition` and `prior_score` come from
the in-scope snapshot we captured at §4.5.1 (before the patch
overwrote `disposition` to `confirmed_mechanical`). The `fix_hint`
we record matches what the helper actually wrote to
`human_confirmation.fix_hint` (`auto_fix_hint.hint`). Skip this
block when `accept_ids` is empty or `patch_rc != 0`:

```bash
if [[ -n "$accept_ids" && ${patch_rc:-1} -eq 0 ]]; then
    while IFS= read -r d; do
        decisions+=("$d")
    done < <(jq -c --arg ts "$walkthrough_ts" --arg accepted "$accept_ids" '
        .[] | select(.id as $id |
            ($accepted | split(",") | index($id)))
        | {
            finding_id: .id,
            action: "auto_accept",
            option_label: "auto-rec",
            option_title: "auto-recommendation accepted in batch",
            edited_hint: false,
            reason: "auto-recommendation accepted in :walkthrough Step 4.5 batch",
            fix_hint: .auto_fix_hint.hint,
            prior_disposition: .disposition,
            prior_score: .score,
            confidence: .auto_fix_hint.confidence,
            ts: $ts
          }
    ' <<<"$auto_rec_in_scope")
fi
```

#### 4.5.6. Remove accepted ids from `scope_ids`

The §5 loop iterates `scope_ids`. Strip out anything we just promoted
so they aren't re-processed (the promote-core fragment would no-op
because `human_confirmation != null`, but presenting the briefer for
an already-promoted finding wastes both reviewer attention and tokens).

```bash
# Strip only when the batch succeeded — first-fail-halt may have
# committed a prefix of the batch but not all of it; if any failed,
# leave scope_ids alone so §5 falls back to per-finding handling.
# (Spec note: if you ever want to strip only the committed prefix
# instead of all-or-nothing, parse the helper's stdout JSON for
# `.promoted` and use that ids list here.)
if [[ -n "$accept_ids" && ${patch_rc:-1} -eq 0 ]]; then
    # Build a remaining-ids comma-separated list. Both inputs are
    # comma-separated; jq's index() treats absent as null.
    scope_ids=$(jq -nr \
        --arg full "$scope_ids" \
        --arg accepted "$accept_ids" '
        ($full | if length > 0 then split(",") else [] end) as $f
        | ($accepted | if length > 0 then split(",") else [] end) as $a
        | [$f[] | select(. as $id | ($a | index($id) | not))]
        | join(",")
    ')
    # scope_count is informational; recompute so §6's
    # `unreviewed_count = scope_count - …` arithmetic stays consistent
    # with the post-batch loop's actual iteration set. (Since auto-
    # accept entries land in decisions[] under their own action tag,
    # `unreviewed_count` excludes them naturally.)
    if [[ -z "$scope_ids" ]]; then
        scope_count=0
    else
        scope_count=$(awk -F, '{print NF}' <<<"$scope_ids")
    fi
fi
```

Print a one-line chat update mirroring §5.6's cadence:
"Step 4.5: N auto-recommendation(s) accepted in batch. Continuing
to per-finding walkthrough for $scope_count remaining finding(s)."
where N is the count of just-promoted ids
(`$(jq 'length' <<<"$accept_ids_json")`). The cumulative
`auto_accept_count` used by §6 / §7.1 / §8 / §9 is computed there
from `decisions[]` directly — no need to thread a running variable
across steps. When `accept_ids` is empty (no batch acceptance
happened — reviewer chose Walk-each / Pick-subset with empty
selection), skip this chat line entirely.

### 5. Per-finding loop

The in-memory decisions array (declared in §4.5's prologue as
`decisions=()`) records the full outcome of every finding — whether
auto-accepted in batch (§4.5.5), promoted in the per-finding loop,
skipped, or interrupted — so step 7's decisions-log comment has the
complete audit trail:

```
# decisions[] entries (already declared above):
#   { finding_id, action, option_label, option_title,
#     edited_hint?, reason, fix_hint?, confidence?,
#     prior_disposition, prior_score, ts }
# action ∈ {auto_accept, promote, skip, stop}
```

Iterate `scope_ids` **in the order returned by the jq** (no re-sort —
that's the order the reviewer saw in the preview table at step 4),
**minus any ids §4.5 already accepted in batch.** When `scope_ids`
is empty here (e.g. every in-scope finding was an auto-rec and the
reviewer chose Accept-all in §4.5), skip the loop and fall through
to §6. For each remaining `$finding_id`:

#### 5.1. Fetch the finding JSON

```bash
finding_json=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter ".findings[] | select(.id == \"$finding_id\")")
```

Capture the `file` and `line_range` for the briefing agent's file
snippet request:

```bash
f_file=$(jq -r '.file' <<<"$finding_json")
f_line_start=$(jq -r '.line_range[0]' <<<"$finding_json")
f_line_end=$(jq -r '.line_range[1]' <<<"$finding_json")
f_disp=$(jq -r '.disposition' <<<"$finding_json")
f_score=$(jq -r '.score_phase4 // .score_phase3 // "null"' <<<"$finding_json")
f_impact=$(jq -r '.impact_type' <<<"$finding_json")
f_claim=$(jq -r '.claim' <<<"$finding_json")
```

#### 5.2. Build the briefing (short-circuit when `auto_fix_hint` is present, else dispatch)

**Short-circuit path (auto_fix_hint exists).** When the finding has
`auto_fix_hint != null` AND `human_confirmation == null` (e.g. the
reviewer chose "Walk through each individually" or "Pick subset" in
§4.5 and left this finding unaccepted), construct the briefing object
INLINE from `auto_fix_hint`. Skip the Sonnet briefer entirely — the
auto_fix_hint already encodes the same shape (recommended fix +
alternatives) the briefer would produce, and re-dispatching wastes
~3–5k tokens per finding.

```bash
f_afh=$(jq -c '.auto_fix_hint // null' <<<"$finding_json")
f_hc=$(jq -c '.human_confirmation // null' <<<"$finding_json")

if [[ "$f_afh" != "null" && "$f_hc" == "null" ]]; then
    # Construct briefing inline. Map .hint → option A, alternatives
    # → options B/C. Recommendation pre-set to A. The summary is the
    # claim's first line (or first 2 sentences if claim is long) since
    # auto_fix_hint doesn't carry a separate summary field.
    briefing_json=$(jq -n \
        --argjson afh "$f_afh" \
        --arg claim "$f_claim" '
        # Summary: take up to first 2 sentences of claim (heuristic).
        ($claim
          | split("\n")
          | .[0]) as $first_line
        | (if ($first_line | length) > 200
           then ($first_line[0:197] + "...")
           else $first_line end) as $summary
        | (if ($afh.confidence == "low") then " (low confidence — review carefully)"
           elif ($afh.second_opinion == "concerns") then " (verifier flagged concerns)"
           else "" end) as $rationale_suffix
        | {
            summary: $summary,
            options: (
              [{
                label: "A",
                title: "Apply auto-recommendation",
                detail: $afh.hint,
                fix_hint_if_picked: $afh.hint
              }]
              + (
                ($afh.alternatives // [])
                | to_entries
                | map({
                    label: (.value.label // (["B","C"] | .[.key])),
                    title: .value.title,
                    detail: .value.hint,
                    fix_hint_if_picked: .value.hint
                  })
              )
            ),
            recommendation: {
              label: "A",
              rationale: ("auto-recommendation (confidence=" + $afh.confidence + ")" + $rationale_suffix)
            }
          }
    ')
    # No Sonnet dispatch → no token logging (the helper records
    # auto-rec generation tokens at Phase 5.5; reusing them here
    # is observed by the rendered Auto-recommendation block).
    briefing_source="auto_fix_hint"
else
    briefing_source="briefer_agent"
    # Fall through to the Sonnet briefer dispatch below.
fi
```

When `briefing_source == "auto_fix_hint"`, skip the rest of §5.2 (the
Sonnet briefer dispatch and its parse/retry/log steps) and proceed
directly to §5.3 with `$briefing_json` populated.

**Briefer dispatch path (auto_fix_hint absent or already promoted).**
Run the Sonnet briefer below ONLY when `briefing_source ==
"briefer_agent"`.

One `Agent` tool-use per finding. Model: `sonnet`. Budget: ~3-5k
tokens. Prompt:

> You are a code-review triage briefer. The reviewer is walking
> through one finding and needs:
>
>   1. A 2-4 sentence summary of what the finding is about and what
>      the validator concluded (include disproven halves, if any).
>   2. 2-5 concrete **fix-variant** options the reviewer can pick
>      from, each with a one-line title and 1-2 sentence detail. Each
>      option represents a different way to fix the finding (e.g.
>      "update the docstring" vs "update the code" for a doc/code
>      mismatch; "add parameter validation" vs "tighten the type
>      signature" for a type-safety finding). Do NOT emit a generic
>      "skip" or "defer" option — the walkthrough adds its own
>      "Skip this finding" and "Stop the walkthrough" options after
>      yours, and routing ambiguity between the two skip paths causes
>      fallback-prompt UX glitches. If no fix variant seems right,
>      emit only one or two weak-conviction options and let your
>      recommendation say so in the rationale — the reviewer can still
>      pick the walkthrough's Skip.
>      **For `confirmed_manual` and `confirmed_report` findings:**
>      propose a best-effort fix hint anyway. These are above the
>      Phase 4 confirmation threshold (score ≥ 60) — the validator
>      said the finding is real, just not mechanically trivial (manual)
>      or not worth a fix (report-only). If a concrete fix path exists,
>      emit it as your top option with a specific `fix_hint_if_picked`.
>      If you genuinely can't see a clean fix (rare), emit one or two
>      weak-conviction options and say so in your recommendation
>      rationale — the reviewer can still pick Skip.
>   3. A recommendation: which option + rationale + a specific
>      `fix_hint` string suitable to pass to the Phase 8 fix-group
>      agent. Include negative constraints when over-engineering is a
>      risk ("do NOT add a new flag"; "do NOT change the code").
>
> Context (read the repo via the Read tool for the file snippet):
>
>   - Finding JSON: <paste $finding_json verbatim>
>   - File: $f_file (lines $f_line_start-$f_line_end, plus ±30 of
>     context — use Read)
>   - Repo root CLAUDE.md: read once and extract any rules that
>     cite $f_file or the same pattern as $f_claim.
>   - Other findings on the same file: <filter artifact-read by .file == $f_file>
>
> Return strict JSON matching:
>
> ```json
> {
>   "summary": "2-4 sentences",
>   "options": [
>     {"label": "A", "title": "...", "detail": "...", "fix_hint_if_picked": "..."},
>     ...
>   ],
>   "recommendation": {"label": "A" | "B" | ..., "rationale": "..."}
> }
> ```
>
> Hard rules:
>
>   - Emit ONE JSON object only. No surrounding prose. No code fences.
>   - Labels are single uppercase letters starting from A.
>   - Every option MUST have a non-null `fix_hint_if_picked` string
>     (every option is a fix variant — see rule 2 above). A null
>     hint would fall through to promote-core's fallback heuristic
>     prompt and break the walkthrough's single-question-per-finding
>     rhythm.
>   - Prefer specific `fix_hint` strings with negative constraints.
>     Avoid vague hints like "fix the docstring" — say what to change
>     and what not to change.

Parse the returned text as JSON (one retry on parse failure with an
"emit JSON only; no surrounding prose" reminder). On second failure,
log to `trace.md` under tag `walkthrough_briefing_failed:$finding_id`
and fall through to a degraded UX: present the raw finding JSON with
options `Skip (briefing failed)` / `Promote anyway (no fix-hint)` /
`Stop the walkthrough`. Set `$briefing_json` to the parsed object (or
the degraded-UX shape on second failure) so §5.3 / §5.4 can read it
through the same variable as the short-circuit path.

Log the agent's token count to `tokens.jsonl`.
Extract the agent id and token count from the Agent tool result's
`<usage>` block. When the block is missing or unparseable, pass the
literal `null` for tokens (same fallback pattern as Phase 8 fix-group
logging) — token tracking is observability, not correctness. Only
runs on the briefer-dispatch path; the short-circuit path doesn't
dispatch a sub-agent so there's nothing to log:

```bash
log-tokens.sh \
    --review-dir "$review_dir" \
    --phase walkthrough --agent-role briefing \
    --agent-id <id-from-Agent-result> \
    --model sonnet --finding-id "$finding_id" \
    --tokens <N or null>
```

#### 5.3. Render the briefing to chat

**Anti-instruction (between iterations).** Do not dispatch a spurious
"continue / stop?" `AskUserQuestion` between per-finding iterations.
The only `AskUserQuestion` the reviewer sees per finding is the
decision prompt at step 5.4, which already includes an explicit "Stop
the walkthrough" option. Adding a standalone continue/stop check
after each iteration double-prompts the reviewer and breaks the
single-question-per-finding rhythm.

Present the briefing as a markdown block the reviewer can read at a
glance:

```markdown
## $finding_id — <first line of claim>

**File:** `$f_file:$f_line_start-$f_line_end`
**Score:** $f_score · **Impact:** $f_impact · **Disposition:** $f_disp

**What it's about:** <briefing.summary>

**Options:**

- **A. <options[0].title>** — <options[0].detail>
- **B. <options[1].title>** — <options[1].detail>
- ...

**Recommendation:** **<recommendation.label>** — <recommendation.rationale>
```

#### 5.4. Ask for a decision

Dispatch `AskUserQuestion` with options built from the briefing:

- One option per `briefing.options[]` entry, labeled with its letter
  and title ("**A.** <title>").
- **"✎ Edit the fix hint (for the recommended option)"** — picks the
  briefing's recommended option but overrides its
  `fix_hint_if_picked` with reviewer-supplied text. On selection,
  dispatch one follow-up `AskUserQuestion` (free-form) capturing the
  override string. Use when the recommended option's direction is
  right but the hint wording needs tightening or negative constraints
  added.
- One "Skip this finding" option.
- One "Stop the walkthrough (finalize now with decisions made so
  far)" option.

Label the briefing's recommended option visually (e.g. prepend
"⭐ (recommended)" to the title) so the reviewer can accept it with
one click.

#### 5.5. Dispatch per choice

**If the reviewer picked a promote option (or Edit the fix hint):**

For a regular promote option, `$fix_hint` comes from the option's
`fix_hint_if_picked`. For "Edit the fix hint," `$fix_hint` is the
reviewer's follow-up free-form string and `$option_label` /
`$option_title` are the originally-recommended option's values
(so the audit trail shows which direction the hint was edited for).
Set `edited_hint=true` in that case; `edited_hint=false` (or absent)
otherwise.

Set ambient context for the shared promote-core fragment (steps 3,
4, 4.5, 5, 6, 9 — the orchestrator reads `fragments/promote-core.md`
with the `Read` tool at this point and executes the listed steps
inline):

```bash
fix_hint="$briefing_option.fix_hint_if_picked"          # or reviewer override when edited_hint
reason="walkthrough: $finding_id — picked option $label ($title)"
[[ "${edited_hint:-false}" == "true" ]] && reason="$reason · hint edited"
force=false
defer_publish=true
```

(Note: `${edited_hint:+...}` would expand for the string `"false"`
since `:+` tests emptiness, not boolean — we need an explicit
string compare against `"true"`.)

Then execute the shared fragment's steps 3, 4, 4.5 (the prompt is
skipped because `$fix_hint` is always non-empty — the briefer at
§5.2 is hard-constrained to emit a non-null `fix_hint_if_picked` on
every option, and the edit-hint path is a free-form override that's
likewise always populated), 5, 6, and 9 for this finding id. The
fragment reads `$finding_id`, `$reason`, `$fix_hint`, `$force`,
`$artifact_path`, and `$trace_log_path` from this ambient context.

**The fragment runs once per iteration** — read it as the per-finding
playbook, not as a single-shot action. Each iteration patches one
finding + appends one `## promote` block to `trace.md`; render and
publish stay deferred until step 6 of this command.

Capture the `$ts`, `$curr_disp`, `$curr_score` the fragment emits
for this iteration. Append to `decisions`:

```
{
  finding_id: $finding_id,
  action: "promote",
  option_label: <briefing label>,
  option_title: <briefing title>,
  edited_hint: <true if the reviewer picked Edit the fix hint, else false>,
  reason: $reason,
  fix_hint: $fix_hint,          # non-empty (option default or reviewer override)
  prior_disposition: $curr_disp,
  prior_score: $curr_score,
  ts: $ts
}
```

**If the reviewer picked "Skip this finding":**

```
decisions += {
  finding_id: $finding_id,
  action: "skip",
  option_label: null,
  option_title: "skipped",
  reason: "reviewer skipped during walkthrough",
  prior_disposition: $f_disp,
  prior_score: $f_score,
  ts: <now>
}
```

No mutation. Append a terse line to `trace.md` under the run's
walkthrough entry (see step 8 below).

**If the reviewer picked "Stop the walkthrough":**

Break out of the loop immediately. Record a final `decisions` entry:

```
decisions += {
  finding_id: $finding_id,
  action: "stop",
  option_label: null,
  option_title: "walkthrough stopped by reviewer",
  reason: "reviewer requested stop",
  prior_disposition: $f_disp,
  prior_score: $f_score,
  ts: <now>
}
```

Note: the current finding (`$finding_id`) is NOT mutated — "stop"
is an explicit no-op on the current id. Only the previously-decided
findings earlier in the loop have been promoted.

Proceed to step 6 (finalize) with whatever decisions have accumulated.

#### 5.6. Between iterations

Append one terse line to the user-visible chat stream so the reviewer
has running feedback (e.g. "F023 promoted (option A — update
docstring). 4 of 10 processed."). No per-iteration render or publish.

### 6. Finalize — render + publish main comment

First, tally the decision counts from the `decisions[]` array so step
7 (decisions-log) and step 8 (trace block) can reference them.
`auto_accept_count` covers Step 4.5 batch acceptances; `promote_count`
covers per-finding-loop promotes only — they're tracked separately
so the decisions-log and user-visible summary can distinguish the
two pathways:

```bash
auto_accept_count=$(jq -s '[.[] | select(.action == "auto_accept")] | length' <<<"$(printf '%s\n' "${decisions[@]}")")
promote_count=$(jq -s '[.[] | select(.action == "promote")] | length' <<<"$(printf '%s\n' "${decisions[@]}")")
skip_count=$(jq    -s '[.[] | select(.action == "skip")]    | length' <<<"$(printf '%s\n' "${decisions[@]}")")
stop_count=$(jq    -s '[.[] | select(.action == "stop")]    | length' <<<"$(printf '%s\n' "${decisions[@]}")")
# scope_count was reduced by §4.5.6 to exclude auto-accepted ids, so
# unreviewed_count below is the count of findings the per-finding loop
# would have walked but didn't (because of stop). The auto-accept
# entries live in decisions[] under their own action tag and are
# accounted for in §7.1's "Auto-accepted" subsection.
unreviewed_count=$(( scope_count - promote_count - skip_count - stop_count ))
```

`$unreviewed_count` is non-zero only when the reviewer picked "Stop
the walkthrough" before reaching every scoped finding. Reported
separately so the decisions-log (§7.1) and user-visible summary
(§9) can't misleadingly imply the reviewer walked all scope_count
findings.

(`mode` and `pr_number` were already extracted in §2 and are in ambient
context. `comment_id` is deferred to §6.2 where the publish call uses
it.)

Guard: if `promote_count == 0` AND `auto_accept_count == 0` (no
mutations at all from this walk), there's nothing to re-render or
re-publish. Skip steps 6.1 and 6.2; proceed to step 6.5
(pre-existing issue filing) and then step 7 (decisions-log comment).
Issue filing is independent of walk activity — a reviewer who skipped
every walk finding may still want to file pre-existing issues. The
scope filter + preview table already showed the user what's in the
backlog; a decisions-log with "skipped all 10" is still useful audit.

Also derive `scope_tier_title` here for §7.1:

```bash
case "$scope_tier" in
    qualifying) scope_tier_title="Qualifying" ;;
    full)       scope_tier_title="Full skip set" ;;
    none)       scope_tier_title="Pre-existing only" ;;
esac
```

#### 6.1. Re-tally `subagent_tokens` + `orchestrator_tokens`, then re-render `artifact.md`

Re-tally first so the rendered report (and the PR comment update in
6.2) reflect cumulative sub-agent + orchestrator spend. Each
walkthrough briefer dispatched in the per-finding loop already logged
itself to `tokens.jsonl` (§24.4); the orchestrator transcript on disk
already captured every main-session turn. Both helpers are pure
readbacks:

```bash
tally-subagent-tokens.sh \
    --tokens-log "$review_dir/tokens.jsonl" \
    --artifact   "$artifact_path" \
    2>>"$trace_log_path" || printf 'walkthrough_tally_failed\n' >> "$trace_log_path"

review_started_at=$(jq -r '.review_started_at // empty' "$artifact_path")

orchestrator-tokens.sh \
    --artifact "$artifact_path" \
    --since    "$review_started_at" \
    2>>"$trace_log_path" || printf 'walkthrough_orchestrator_tally_failed\n' >> "$trace_log_path"

artifact-render.py \
    --input "$artifact_path" \
    --output "$review_dir/artifact.md"
```

Tally failures are non-fatal (observability, not correctness). On
render non-zero: log stderr to `trace.md` with tag
`walkthrough_render_failed`. Continue to step 6.2 — the artifact
patches stand; the user can manually re-render.

Issue-filing in §6.5 below dispatches another batch of sub-agents
after this point; those land in `tokens.jsonl` (and generate further
orchestrator turns) but the walkthrough does not re-render after §6.5,
so their cost will only surface on the next `/adamsreview:fix` (or
subsequent `/adamsreview:add` / `/adamsreview:walkthrough`) run when
that command re-tallies. This is acceptable — issue-filing is terminal
and no further re-publish follows it.

#### 6.2. Re-publish the main review comment (PR mode only)

`mode` and `pr_number` were already extracted in §2. Extract
`comment_id` here — it's only used by the publish call:

```bash
comment_id=$(jq -r '.comment_id // empty' "$artifact_path")
```

If `mode == "pr"` AND `pr_number` is non-empty:

```bash
publish_args=(
    --mode pr
    --review-id "$review_id"
    --pr "$pr_number"
    --repo-slug "$repo_slug"
    --branch "$head_branch"
    --review-dir "$review_dir"
)
[[ -n "$comment_id" ]] && publish_args+=(--comment-id "$comment_id")

artifact-publish.sh "${publish_args[@]}"
```

If `mode == "local"`: call with `--mode local --review-id "$review_id"
--review-dir "$review_dir"` (no-op that appends a trace line).

On non-zero: log stderr to `trace.md` with tag
`walkthrough_publish_failed`. Continue to step 6.5 — the downstream
steps are still worth running even if the main-comment PATCH failed.

### 6.5. File GitHub issues for pre-existing findings

Skip entirely when ANY of the following hold:
- `mode == "local"` — no PR to link the issue back to.
- `scope_preexisting_count == 0` — nothing to file.
- `pr_number` is empty — defensive; in pr mode this should always be
  populated but we avoid calling `gh issue create` with an empty
  link in the drafted body.

(Local mode has no PR → no natural "parent" issue; the trace entry at
step 8 remains the sole audit record.)

Rationale: `pre_existing_report` findings originate in code that
pre-dates this PR (per the §13 pre-existing override). They're not
fixable in the current change, so bundling them with promote-eligible
findings in the §5 loop forced awkward "skip" decisions every run.
Filing a GitHub issue moves them to a durable tracking surface outside
the review artifact.

Initialize an `issues_filed=[]` array in ambient context. Each entry:
`{finding_id, issue_url, title, ts}`.

Cache the owner/repo string once (used per iteration):

```bash
repo_name_with_owner=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
```

If `repo_name_with_owner` is empty (no remote, or `gh` auth issue),
log to `trace.md` under tag `walkthrough_repo_resolve_failed`, skip
§6.5 entirely, and continue to §7. `gh issue create --repo ""` would
fail per-iteration with a confusing error; a single upfront skip is
cleaner.

#### 6.5.1. One-shot gate prompt

Dispatch `AskUserQuestion`:

- "File all $scope_preexisting_count issue(s)"
- "Pick a subset"
- "Skip — don't file any"

If the reviewer picks "Pick a subset," dispatch a follow-up
`AskUserQuestion` with the finding ids as multi-select options
(fall back to a free-form comma-separated id list with validation
when multi-select isn't available). Capture the selected ids into
`filing_ids` (comma-separated). "File all" sets
`filing_ids=$scope_preexisting_ids`. "Skip" leaves `filing_ids`
empty.

If `filing_ids` is empty (either the reviewer chose "Skip" or
selected zero items in the subset picker), skip the §6.5.2 loop
entirely and proceed to §7. `issues_filed[]` remains empty and the
§9 summary's "not filed" note will fire.

#### 6.5.2. Per-selected finding: draft + confirm + create

Iterate `filing_ids` in the order returned. For each `$finding_id`:

**Fetch the finding JSON and per-finding variables** (same pattern as
§5.1). These MUST be re-extracted inside the §6.5.2 loop — they are
local to each iteration:

```bash
finding_json=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter ".findings[] | select(.id == \"$finding_id\")")
f_file=$(jq -r '.file' <<<"$finding_json")
f_line_start=$(jq -r '.line_range[0]' <<<"$finding_json")
f_line_end=$(jq -r '.line_range[1]' <<<"$finding_json")
f_claim=$(jq -r '.claim' <<<"$finding_json")
f_hc=$(jq -c '.human_confirmation // null' <<<"$finding_json")
```

**Guard: skip findings already promoted off-menu.** The default flow
never promotes a `pre_existing_report` finding (scope_full_ids excludes
them). But a user can direct Claude mid-run to promote a
specific pre-existing finding as an explicit override. In that case
the finding has `human_confirmation != null` now, even though
`scope_preexisting_ids` (captured before the override) still
lists its id. Filing a GitHub issue for a finding that's also queued
for auto-fix double-processes it:

```bash
if [[ "$f_hc" != "null" ]]; then
    {
        printf '## walkthrough_issue_filing_skipped (%s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'finding=%s reason=already_promoted_off_menu\n\n' "$finding_id"
    } >> "$trace_log_path"
    # One-line chat update mirroring the §5.6 cadence:
    #   "F026 skipped: already promoted earlier this run."
    continue
fi
```

Do NOT add an `issues_filed[]` entry for a skipped finding — the array
records what was actually filed, not what was considered.

**Dispatch a Sonnet drafting agent.** Model: `sonnet`. Budget: ~2-3k
tokens. Prompt:

> You are drafting a GitHub issue for a code-review finding that
> pre-dates the current PR (`pre_existing_report`). The reviewer
> wants a concise, actionable issue that someone triaging the
> backlog can read cold.
>
> Return strict JSON matching:
>
> ```json
> {
>   "title": "<70 chars, imperative or descriptive; no issue #, no trailing period>",
>   "body": "<markdown body; sections: Summary, Location, Evidence, Suggested direction>"
>
> }
> ```
>
> Hard rules:
>
>   - Emit ONE JSON object only. No surrounding prose. No outer code
>     fences on the JSON itself (the `body` string may contain inner
>     fenced code blocks — those are fine).
>   - Body must include a line like `File: <file>:<line_start>-<line_end>`
>     and a "Discovered during" sentence naming this PR number
>     (see context).
>   - Keep the body under 40 lines. Link to the PR once; don't
>     replicate the finding JSON.
>
> Context:
>
>   - Finding JSON: <paste $finding_json verbatim>
>   - PR: #$pr_number in $repo_name_with_owner
>   - File: $f_file (lines $f_line_start-$f_line_end, plus ±20 of
>     context via Read)

Parse the returned text as JSON (one retry on parse failure). On
second failure, log to `trace.md` under tag
`walkthrough_issue_draft_failed:$finding_id` and surface a degraded
UX: offer `Skip this finding` or `Write body free-form` (captured
via one `AskUserQuestion` free-form follow-up).

Log the drafting agent's tokens:

```bash
log-tokens.sh \
    --review-dir "$review_dir" \
    --phase walkthrough --agent-role pre_existing_issue_draft \
    --agent-id <id-from-Agent-result> \
    --model sonnet --finding-id "$finding_id" \
    --tokens <N or null>
```

**Render the draft** as a markdown block to chat:

```markdown
## Pre-existing issue draft — $finding_id

**Title:** <draft.title>

---

<draft.body>
```

**Ask for the next action.** `AskUserQuestion`:

- "Create issue"
- "Edit the body first"
- "Skip this finding"

For "Edit the body first," dispatch one follow-up `AskUserQuestion`
(free-form) capturing the replacement body, then re-render and loop
back to this same `AskUserQuestion`. Two edit rounds max per finding
to keep cadence predictable — after two, auto-offer Create/Skip only.

**For "Skip this finding,"** continue to the next finding in
`filing_ids`. The finding remains open in the artifact with its
existing `pre_existing_report` disposition. No trace entry is
written per-skip — the `pre_existing_issues:` block in §8 lists
what was *filed*, and the artifact's full `pre_existing_report`
set (discoverable via `artifact-read.sh`) implicitly shows what
was available, so absence = skipped.

**For "Create issue":**

```bash
body_tmp=$(mktemp -t adams-walkthrough-issue.XXXXXX)
err_tmp=$(mktemp -t adams-walkthrough-gh-err.XXXXXX)
# write $draft_body (possibly user-edited) to $body_tmp
# Capture gh_rc directly; piping gh through awk would swallow gh's exit (pipefail is off here).
gh_stdout=$(gh issue create \
    --repo "$repo_name_with_owner" \
    --title "$draft_title" \
    --body-file "$body_tmp" 2>"$err_tmp")
gh_rc=$?
rm -f "$body_tmp"
issue_url=$(awk 'END{print}' <<<"$gh_stdout")
```

`$err_tmp` uses `mktemp`, not `/tmp/...$$`, because the orchestrator may invoke successive bash calls with different PIDs.

If `gh_rc != 0`, read `$err_tmp`, log under tag
`walkthrough_issue_filed_failed:$finding_id` with the drafted
title + body (for manual recovery), `rm -f "$err_tmp"`, and continue
to the next finding. Do not abort the whole step on a single `gh`
failure. On success, also `rm -f "$err_tmp"`.

On success, append to `issues_filed`:

```
{
  finding_id: $finding_id,
  issue_url: $issue_url,
  title: $draft_title,
  ts: <now>
}
```

Print a one-line chat update: "Filed $finding_id → $issue_url.
Ns processed of M." Mirrors the §5.6 cadence for the main loop.

### 7. Post the decisions-log PR comment

Skip entirely when `mode == "local"` (no PR to comment on — the trace
entry at step 8 is the audit record in local mode).

Also skip when `${#decisions[@]} == 0` AND `${#issues_filed[@]} == 0`
— there's nothing to report (the reviewer cancelled before walking
anything AND filed no pre-existing issues). Step 8's trace line is
still written so the run is auditable locally.

In PR mode, render a decisions-log markdown block from `decisions`
and POST it as a NEW PR comment (separate from the main review
comment). DO NOT mutate `artifact.comment_id` — that stays pointing
at the main review comment so future `/adamsreview:fix` and
`/adamsreview:promote` runs edit the right comment.

#### 7.1. Build the decisions-log markdown

One header block, then one subsection per decision in the order they
were made. Use the ids and titles verbatim from the `decisions[]`
array.

```markdown
<!-- adams-review-walkthrough-v1 -->
### Walkthrough decisions

`$review_id` · scope=**$scope_tier** · score_floor=$threshold · reviewer=$reviewer · ts=$walkthrough_ts

Walking the **$scope_tier_title** scope: of **$scope_count** non-auto-eligible finding(s), **$auto_accept_count auto-accepted**, **$promote_count promoted**, **$skip_count skipped**, **$stop_count stopped**, **$unreviewed_count unreviewed**.

Promoted findings will be picked up by the next `/adamsreview:fix` run via the `human_confirmation` bypass, regardless of its score threshold.

---

#### Auto-accepted (Step 4.5 batch)

- **F003** — [first line of claim]
  - **Hint:** <fix_hint>
  - **Prior:** disposition=<prior_disposition> · score=<prior_score>
  - _Auto-recommendation accepted in batch (confidence=<confidence>)._

- **F004** — ...

#### Promoted

- **F006** — [first line of claim] · option **A** (Update the docstring to match the code)
  - **Why:** <option.detail> — <recommendation.rationale>
  - **Fix hint:** `<fix_hint>` (marked "(edited by reviewer)" when `edited_hint == true`; "— (no steering hint supplied)" when empty)
  - **Prior:** disposition=<prior_disposition> · score=<prior_score>

- **F016** — ...

#### Skipped

- **F009** — [first line of claim]
  - Reviewer skipped during walkthrough.

#### Stopped

- **F023** — [first line of claim]
  - Reviewer requested stop at this finding. Not mutated.
  - Resume with `/adamsreview:walkthrough $threshold`.

#### Pre-existing issues filed

- **F026** — <issue title> → <issue_url>
- **F028** — <issue title> → <issue_url>

---

Decisions log: this comment is append-only audit — it's never edited
in place. Each `/adamsreview:walkthrough` run posts a fresh entry.
Current state: see the main review comment and `artifact.md`.
```

`$scope_tier_title` is `"Qualifying"` when `scope_tier == qualifying`,
`"Full skip set"` when `scope_tier == full`, and `"Pre-existing only"`
when `scope_tier == none` (the walk was skipped because
`scope_full_count == 0`). In the `none` case, `scope_count == 0` and
`decisions[]` is empty — the Auto-accepted/Promoted/Skipped/Stopped
subsections all omit, leaving only the Pre-existing issues subsection.
The header sentence becomes "Walking the **Pre-existing only** scope:
of **0** non-auto-eligible finding(s), 0 auto-accepted, 0 promoted,
0 skipped, 0 stopped." — accurate and matches the §7 guard (which
skips the POST only when BOTH decisions and issues_filed are empty).

The **Auto-accepted** subsection comes BEFORE **Promoted** because
batch acceptance happens first (Step 4.5 runs before §5). The order
in the rendered comment matches the order the actions occurred.

Emit the Auto-accepted subsection only when `auto_accept_count > 0`,
the Pre-existing issues subsection only when `issues_filed[]` is
non-empty, and similarly for the existing Promoted/Skipped/Stopped
sections. Omit the `$auto_accept_count auto-accepted` and/or
`$unreviewed_count unreviewed` clauses from the header sentence when
their counts are 0. Omit the "Promoted findings will be picked up
by the next `/adamsreview:fix`…" sentence entirely when
`$promote_count == 0` AND `$auto_accept_count == 0` — with zero
mutations it describes a non-event (and misleadingly hints that a
fix run is pending when it isn't); when EITHER count is non-zero,
keep the sentence (auto-accepted findings also flow through the
`human_confirmation` bypass).

#### 7.2. POST via `gh api`

```bash
comment_body_path=$(mktemp -t adams-walkthrough-body.XXXXXX)
err_tmp=$(mktemp -t adams-walkthrough-gh-err.XXXXXX)
# ... write the rendered markdown to $comment_body_path ...

decisions_comment_id=$(gh api \
    --method POST \
    "repos/{owner}/{repo}/issues/$pr_number/comments" \
    -F "body=@$comment_body_path" \
    --jq '.id' 2>"$err_tmp")
gh_rc=$?

rm -f "$comment_body_path"
```

Run from `$repo_root` (set at step 2); the gh process inherits the working directory unless we explicitly cd.

Stderr is captured to `$err_tmp` (mirrors the §6.5.2 `gh issue create`
pattern) so the "log to trace on failure" branch below has something
to log. Without the `2>` redirect, stderr would print to the user's
terminal and the trace entry would be blank.

On success, `rm -f "$err_tmp"`. Capture `decisions_comment_id` into
trace only (do NOT mutate the artifact's `comment_id`).

On `gh` failure (`gh_rc != 0`), read `$err_tmp`, append a block under
tag `walkthrough_decisions_comment_failed` to `trace.md` containing
the captured stderr AND the rendered markdown (so the reviewer can
recover the content and manually post it), then `rm -f "$err_tmp"`.

### 8. Append walkthrough block to `trace.md`

```bash
{
    printf '## walkthrough (%s)\n' "$walkthrough_ts"
    printf 'review_id=%s scope_tier=%s threshold=%s scope_count=%s auto_accept_count=%s promote_count=%s skip_count=%s stop_count=%s unreviewed_count=%s\n' \
        "$review_id" "$scope_tier" "$threshold" "$scope_count" "$auto_accept_count" "$promote_count" "$skip_count" "$stop_count" "$unreviewed_count"
    printf 'decisions:\n'
    # one line per decision, in order. action ∈ {auto_accept, promote, skip, stop}.
    for d in "${decisions[@]}"; do
        edited_marker=""
        if [[ "$(jq -r '.edited_hint // false' <<<"$d")" == "true" ]]; then
            edited_marker=" hint_edited=true"
        fi
        printf '  %s %s option=%s hint=%s%s\n' \
            "$(jq -r '.finding_id' <<<"$d")" \
            "$(jq -r '.action' <<<"$d")" \
            "$(jq -r '.option_label // "—"' <<<"$d")" \
            "$(jq -r '.fix_hint // "—"' <<<"$d")" \
            "$edited_marker"
    done
    if (( ${#issues_filed[@]} > 0 )); then
        printf 'pre_existing_issues:\n'
        for i in "${issues_filed[@]}"; do
            printf '  %s %s\n' \
                "$(jq -r '.finding_id' <<<"$i")" \
                "$(jq -r '.issue_url' <<<"$i")"
        done
    fi
    [[ -n "${decisions_comment_id:-}" ]] && \
        printf 'decisions_comment_id=%s\n' "$decisions_comment_id"
    printf '\n'
} >> "$trace_log_path"
```

### 9. User-visible summary

Print a clear summary block to chat (plain text, not a tool call).
The summary line distinguishes Step 4.5 batch acceptance from
per-finding-loop promotion: "$auto_accept_count auto-recommendations
accepted in batch + $promote_count promoted via per-finding
walk-through" (with the `+ … per-finding walk-through` half omitted
when `$promote_count == 0`):

```
Walkthrough complete. Scope: $scope_tier_title.
$auto_accept_count auto-recommendations accepted in batch + $promote_count promoted via per-finding walk-through.
Of $scope_count finding(s) walked individually:
  Auto-accepted (batch): $auto_accept_count
  Promoted (per-finding): $promote_count
  Skipped:               $skip_count
  Stopped:               $stop_count
  Unreviewed:            $unreviewed_count

Pre-existing issues filed: <N; list id → url pairs below, or omit section>
  F026 → <url>
  F028 → <url>

Cumulative sub-agent spend: <total> tokens across <invs> invocations.
Cumulative orchestrator spend: <output> output / <input> input across <turns> turns.

Promoted findings (auto-accepted + per-finding) are now auto-fix-
eligible via the human_confirmation bypass — they'll be picked up
at any fix threshold. To apply:

  /adamsreview:fix

Decisions log comment: <url to the POSTed comment, if PR mode>
Main review comment: updated in place.

You can resume later by re-running /adamsreview:walkthrough — the
scope filter naturally excludes anything you already promoted (whether
auto-accepted or per-finding), so the $unreviewed_count unreviewed
finding(s) plus any newly-added ones will be what you see.
```

The "Auto-accepted (batch)" line is omitted when
`$auto_accept_count == 0` (matches the existing per-section omission
rule). When `$auto_accept_count > 0` AND `$promote_count == 0`, the
first sentence collapses to "$auto_accept_count auto-recommendations
accepted in batch."; the inverse holds for the
all-promoted-no-auto-accept case. The
"Promoted findings (auto-accepted + per-finding) are now auto-fix-
eligible…" sentence is kept whenever EITHER count is > 0; omitted
only when both are 0 (matches §7.1's "skip if zero mutations" rule).

Read the cumulative spend numbers from the artifact (populated by
§6.1's re-tally). Direct `jq -r` call so stdout is the chat line
itself, not a JSON-quoted string (`artifact-read.sh --filter` doesn't
enable raw mode). Note that §6.5 issue-filer agents dispatched after
the tally won't be included in these lines — they (and the
orchestrator turns that dispatch them) surface on the next lifecycle
command's re-tally (§6.1 above documents this). Omit each line
entirely when its source field is absent/null — matches
`artifact-render.py`'s renderer guard:

```bash
subagent_token_line=$(jq -r '
    if (.subagent_tokens.total // null) != null and (.subagent_tokens.invocations // null) != null
    then "Cumulative sub-agent spend: \(.subagent_tokens.total) tokens across \(.subagent_tokens.invocations) invocations."
    else empty end
' "$artifact_path")

orchestrator_token_line=$(jq -r '
    if (.orchestrator_tokens.turn_count // null) != null
    then "Cumulative orchestrator spend: \(.orchestrator_tokens.total_output) output / \(.orchestrator_tokens.total_input) input across \(.orchestrator_tokens.turn_count) turns."
    else empty end
' "$artifact_path")
```

Omit the "Unreviewed" line entirely (and the final re-run sentence's
unreviewed-count clause) when `$unreviewed_count == 0` — keeps the
common-case summary tidy. Omit the "Pre-existing issues filed"
section entirely when `issues_filed[]` is empty.

When `mode == "pr"` AND `scope_preexisting_count > 0` AND
`${#issues_filed[@]} == 0` (the reviewer saw pre-existing findings but
chose "Skip — don't file any"), add a one-line note after the
summary block:

```
Note: $scope_preexisting_count pre-existing finding(s) not filed as issues.
Re-run /adamsreview:walkthrough to revisit.
```

On any step failure earlier in the run, append a `Note:` section
listing the deferred failures and their recovery actions (same
pattern as `/adamsreview:promote` step 10).

## What this command does NOT do

- **No `disposition=disproven` handling.** Disproven findings need
  `/adamsreview:promote <id> --force` with a conscious justification;
  the walkthrough scope filter excludes them.
- **No resumption state file.** If you quit mid-walkthrough, the
  promotions you already made stand. Re-invoking the walkthrough
  skips them naturally (the scope filter excludes
  `human_confirmation != null`).
