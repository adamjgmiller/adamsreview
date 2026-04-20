---
allowed-tools: Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-read.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-patch.py:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-validate.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-render.py:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-publish.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/repo-slug.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/log-tokens.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(cat:*), Bash(printf:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(tr:*), Bash(awk:*), Bash(mktemp:*), Agent, Read, AskUserQuestion
argument-hint: "[threshold]"
description: Walk interactively through findings /adams-review-fix would skip. Per-finding briefing + options + recommendation, then batch re-render/re-publish and post a decisions-log PR comment.
disable-model-invocation: false
---

Walk the reviewer through every finding in the latest `/adams-review`
artifact that `/adams-review-fix [threshold]` would **skip** at the
chosen threshold: deep-manual, light-manual, light-report, light-auto
that fails the impact_type lane filter, and any `confirmed_auto`
below the score threshold. For each finding, dispatch a Sonnet
briefing agent (claim → options → recommendation), ask the reviewer
to decide, and record a promote (via the shared `promote-core.md`
fragment with `--defer-publish` semantics) or a skip. At the end,
render + publish the updated review once, then POST a separate
decisions-log comment to the PR for audit.

See DESIGN §28 for the full contract and `plans/walkthrough-mode.md`
for the design rationale.

## Arguments

- `[threshold]` (optional, positional) — non-negative integer matching
  the threshold the reviewer plans to use for `/adams-review-fix`.
  Default: 60 (DESIGN §13.2). Determines which `confirmed_auto`
  findings would "already be fixed" by the fix command and are
  therefore excluded from the walkthrough scope.

## What it does

1. Parses the threshold.
2. Locates the artifact for the current branch.
3. Computes the walkthrough scope (see §3 below).
4. Shows a pre-flight summary of the scope + asks for go/no-go.
5. For each finding in scope:
   - Dispatches a Sonnet briefing sub-agent → `{summary, options[], recommendation}`.
   - Presents the briefing and asks the reviewer which option to pick.
   - Dispatches a promote (patch + trace, no render/publish) or a skip.
6. Re-renders `artifact.md` once.
7. Re-publishes the main review comment once.
8. Posts a new "Walkthrough decisions" comment to the PR with the
   full log of what was promoted / skipped / why.
9. Appends a `## walkthrough (<ts>)` block to `trace.md`.
10. Prints a user-visible summary.

Does NOT run `/adams-review-fix`. Does NOT surface `disposition=disproven`
findings (those require an explicit `/adams-review-promote <id> --force`).

## Execution

Work through the steps below in order. Capture each named variable
into your working context. Build a TaskList that mirrors these step
headings.

### 1. Parse arguments

Parse `$ARGUMENTS` (whitespace-split):

- First token that parses as a non-negative integer → `threshold`.
- Any other token → stop and ask the user to clarify.

If no integer was provided, `threshold=60` (DESIGN §13.2). Record in
your working context.

### 2. Locate the artifact

```bash
reviews_root="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
repo_slug=$(~/.claude/commands/_shared/tools/repo-slug.sh --repo-root "$repo_root")
latest_path="$reviews_root/$repo_slug/$head_branch/latest.txt"
```

If `latest.txt` is missing or empty, error-as-prompt:

> ERROR: no review found for branch `$head_branch` under
> `$reviews_root/$repo_slug/`.
> Action: run /adams-review against this branch first.

Otherwise:

```bash
review_id=$(tr -d '[:space:]' < "$latest_path")
review_dir="$reviews_root/$repo_slug/$head_branch/$review_id"
artifact_path="$review_dir/artifact.json"
trace_log_path="$review_dir/trace.md"
```

Capture paths. Schema-validate:

```bash
~/.claude/commands/_shared/tools/artifact-validate.sh --path "$artifact_path"
```

On non-zero: surface the validator stderr and abort.

### 3. Compute walkthrough scope

The scope is the set of findings `/adams-review-fix` would SKIP at
`$threshold`, minus the ones already promoted or in a terminal state.
This is the inverse of the Phase 8 eligibility selector at
`09-fix-execution.md` step 8.1 — **keep the two jq expressions in
sync**.

```bash
scope_ids=$(jq -r --argjson thr "$threshold" '
    [.findings[]
     # Not terminal: skip resolved / disproven / pending_validation.
     | select(.current_state == "open")
     | select(.disposition != "resolved")
     | select(.disposition != "disproven")
     | select(.disposition != "pending_validation")
     # Skip already-promoted (human_confirmation set). Re-running the
     # walkthrough mid-session naturally picks up where it left off.
     | select(.human_confirmation == null)
     # Include iff the Phase 8 gate would skip it — the inverse of
     # 09-fix-execution.md step 8.1 (§13.1, §13.2). Note: jq's `not`
     # is a filter (pipe into it), not a function.
     | select(
         (
           (.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
           and (
             (.impact_type == "correctness" or .impact_type == "security")
             and (.score_phase4 != null and .score_phase4 >= $thr)
           )
         ) | not
       )
     | .id
    ] | join(",")
' "$artifact_path")

if [[ -z "$scope_ids" ]]; then
    scope_count=0
else
    # scope_ids is comma-separated; count fields directly.
    scope_count=$(awk -F, '{print NF; exit}' <<<"$scope_ids")
fi
```

If `scope_ids` is empty:

```
No findings to walk through at threshold=$threshold.

Either every finding is already auto-eligible (run /adams-review-fix
$threshold to apply them) or the review has no actionable findings
left. Nothing to do.
```

Exit 0.

### 4. Pre-flight summary + go/no-go

Render a compact preview table so the reviewer knows what they're
signing up for. One row per id in `scope_ids`:

```bash
preview=$(jq -r --arg ids "$scope_ids" --argjson thr "$threshold" '
    ($ids | split(",")) as $want
    | [.findings[] | select(.id as $id | $want | index($id)) | {
        id,
        lane: .validation_lane,
        impact: .impact_type,
        disposition,
        score: (.score_phase4 // "—"),
        file: .file,
        claim_first_line: (.claim | split("\n") | .[0])
      }]
    | (["# ", "lane", "impact", "disposition", "score", "file", "claim"] | @tsv),
      (.[] | [.id, .lane, .impact, .disposition, (.score|tostring), .file, .claim_first_line] | @tsv)
' "$artifact_path")
```

Present the preview as a markdown table in chat (one header row + one
row per finding), then dispatch `AskUserQuestion` with two options:

- "Proceed — walk through $scope_count finding(s)."
- "Cancel — don't change anything."

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

### 5. Per-finding loop

Initialize an in-memory decisions array in your working context. Each
entry records the full outcome of one finding — whether promoted,
skipped, or interrupted — so step 7's decisions-log comment has the
complete audit trail:

```
decisions = []   # list of {finding_id, action, reason, fix_hint?, prior_disposition, prior_score}
```

Iterate `scope_ids` **in the order returned by the jq** (no re-sort —
that's the order the reviewer saw in the preview table at step 4).
For each `$finding_id`:

#### 5.1. Fetch the finding JSON

```bash
finding_json=$(~/.claude/commands/_shared/tools/artifact-read.sh \
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
f_score=$(jq -r '.score_phase4 // "null"' <<<"$finding_json")
f_impact=$(jq -r '.impact_type' <<<"$finding_json")
f_claim=$(jq -r '.claim' <<<"$finding_json")
```

#### 5.2. Dispatch the briefing sub-agent

One `Agent` tool-use per finding. Model: `sonnet`. Budget: ~3-5k
tokens. Prompt (see DESIGN §28.4):

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
`Stop the walkthrough`.

Log the agent's token count to `tokens.jsonl` per §11 / §24.4.
Extract the agent id and token count from the Agent tool result's
`<usage>` block. When the block is missing or unparseable, pass the
literal `null` for tokens (same fallback pattern as §8.6 / Phase 8
fix-group logging) — token tracking is observability, not
correctness:

```bash
~/.claude/commands/_shared/tools/log-tokens.sh \
    --review-dir "$review_dir" \
    --phase walkthrough --agent-role briefing \
    --agent-id <id-from-Agent-result> \
    --model sonnet --finding-id "$finding_id" \
    --tokens <N or null>
```

#### 5.3. Render the briefing to chat

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
- One "Skip this finding" option.
- One "Stop the walkthrough (finalize now with decisions made so
  far)" option.

Label the briefing's recommended option visually (e.g. prepend
"⭐ (recommended)" to the title) so the reviewer can accept it with
one click.

#### 5.5. Dispatch per choice

**If the reviewer picked a promote option:**

Set ambient context for the shared promote-core fragment (steps 3,
4, 4.5, 5, 6, 9 — the body of which is inlined once at the end of
this file for reference and for Claude Code's command-load
preprocessor to resolve):

```bash
fix_hint="$briefing_option.fix_hint_if_picked"          # non-null per §5.2
reason="walkthrough: $finding_id — picked option $label ($title)"
force=false
defer_publish=true
```

Then execute the shared fragment's steps 3, 4, 4.5 (the prompt is
skipped because `$fix_hint` is always non-empty — the briefer at
§5.2 is hard-constrained to emit a non-null `fix_hint_if_picked` on
every option), 5, 6, and 9 for this finding id. The fragment reads
`$finding_id`, `$reason`, `$fix_hint`, `$force`, `$artifact_path`,
and `$trace_log_path` from this ambient context.

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
  reason: $reason,
  fix_hint: $fix_hint,          # may be empty
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
7 (decisions-log) and step 8 (trace block) can reference them:

```bash
promote_count=$(jq -s '[.[] | select(.action == "promote")] | length' <<<"$(printf '%s\n' "${decisions[@]}")")
skip_count=$(jq   -s '[.[] | select(.action == "skip")]    | length' <<<"$(printf '%s\n' "${decisions[@]}")")
stop_count=$(jq   -s '[.[] | select(.action == "stop")]    | length' <<<"$(printf '%s\n' "${decisions[@]}")")
unreviewed_count=$(( scope_count - promote_count - skip_count - stop_count ))
```

`$unreviewed_count` is non-zero only when the reviewer picked "Stop
the walkthrough" before reaching every scoped finding. Reported
separately so the decisions-log (§7.1) and user-visible summary
(§9) can't misleadingly imply the reviewer walked all scope_count
findings.

Guard: if `promote_count == 0` (all skip/stop), there's nothing to
re-render or re-publish. Skip steps 6.1 and 6.2; jump to step 7
(decisions-log comment). The scope filter + preview table already
showed the user what's in the backlog; a decisions-log with
"skipped all 10" is still useful audit.

#### 6.1. Re-render `artifact.md`

```bash
~/.claude/commands/_shared/tools/artifact-render.py \
    --input "$artifact_path" \
    --output "$review_dir/artifact.md"
```

On non-zero: log stderr to `trace.md` with tag
`walkthrough_render_failed`. Continue to step 6.2 — the artifact
patches stand; the user can manually re-render.

#### 6.2. Re-publish the main review comment (PR mode only)

Read mode + pr_number + comment_id from the artifact:

```bash
mode=$(jq -r '.mode' "$artifact_path")
pr_number=$(jq -r '.pr_number // empty' "$artifact_path")
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

~/.claude/commands/_shared/tools/artifact-publish.sh "${publish_args[@]}"
```

If `mode == "local"`: call with `--mode local --review-id "$review_id"
--review-dir "$review_dir"` (no-op that appends a trace line).

On non-zero: log stderr to `trace.md` with tag
`walkthrough_publish_failed`. Continue to step 7 — the decisions-log
is still worth posting even if the main-comment PATCH failed.

### 7. Post the decisions-log PR comment

Skip entirely when `mode == "local"` (no PR to comment on — the trace
entry at step 8 is the audit record in local mode).

In PR mode, render a decisions-log markdown block from `decisions`
and POST it as a NEW PR comment (separate from the main review
comment). DO NOT mutate `artifact.comment_id` — that stays pointing
at the main review comment so future `/adams-review-fix` and
`/adams-review-promote` runs edit the right comment.

#### 7.1. Build the decisions-log markdown

One header block, then one subsection per decision in the order they
were made. Use the ids and titles verbatim from the `decisions[]`
array.

```markdown
<!-- adams-review-walkthrough-v1 -->
### Walkthrough decisions

`$review_id` · threshold=$threshold · reviewer=$reviewer · ts=$walkthrough_ts

Of **$scope_count** non-auto-eligible finding(s) in scope: **$promote_count promoted**, **$skip_count skipped**, **$stop_count stopped**, **$unreviewed_count unreviewed**.

Promoted findings will be picked up by the next `/adams-review-fix $threshold` run via the `human_confirmation` bypass (DESIGN §27.6).

---

#### Promoted

- **F003** — [first line of claim] · option **A** (Update the docstring to match the code)
  - **Why:** <option.detail> — <recommendation.rationale>
  - **Fix hint:** `<fix_hint>` (or "— (no steering hint supplied)" when empty)
  - **Prior:** disposition=<prior_disposition> · score=<prior_score>

- **F016** — ...

#### Skipped

- **F006** — [first line of claim]
  - Reviewer skipped during walkthrough.

#### Stopped

- **F023** — [first line of claim]
  - Reviewer requested stop at this finding. Not mutated.
  - Resume with `/adams-review-walkthrough $threshold`.

---

Decisions log: this comment is append-only audit — it's never edited
in place. Each `/adams-review-walkthrough` run posts a fresh entry.
Current state: see the main review comment and `artifact.md`.
```

Sections are emitted only when non-empty — a run with no stops omits
the "Stopped" block entirely. Similarly, omit the `$unreviewed_count
unreviewed` clause from the header sentence when `$unreviewed_count
== 0` (i.e., every scoped finding was promoted, skipped, or stopped
at).

#### 7.2. POST via `gh api`

```bash
comment_body_path=$(mktemp -t adams-walkthrough-body.XXXXXX)
# ... write the rendered markdown to $comment_body_path ...

decisions_comment_id=$(gh api \
    --method POST \
    "repos/{owner}/{repo}/issues/$pr_number/comments" \
    -F "body=@$comment_body_path" \
    --jq '.id')

rm -f "$comment_body_path"
```

`gh api` auto-substitutes `{owner}` and `{repo}` placeholders with
the current git remote's owner/repo when invoked from inside the
repo working tree — no manual resolution needed. Run the command
from `$repo_root` (the command file's $repo_root is already set at
step 2; the gh process inherits working directory unless we explicitly
cd).

Capture `decisions_comment_id` into trace only (do NOT mutate the
artifact's `comment_id`).

On `gh` failure: log stderr to `trace.md` with tag
`walkthrough_decisions_comment_failed`. Include the rendered markdown
in the trace so the reviewer can recover the content and manually
post it.

### 8. Append walkthrough block to `trace.md`

```bash
{
    printf '## walkthrough (%s)\n' "$walkthrough_ts"
    printf 'review_id=%s threshold=%s scope_count=%s promote_count=%s skip_count=%s stop_count=%s unreviewed_count=%s\n' \
        "$review_id" "$threshold" "$scope_count" "$promote_count" "$skip_count" "$stop_count" "$unreviewed_count"
    printf 'decisions:\n'
    # one line per decision, in order
    for d in "${decisions[@]}"; do
        printf '  %s %s option=%s hint=%s\n' \
            "$(jq -r '.finding_id' <<<"$d")" \
            "$(jq -r '.action' <<<"$d")" \
            "$(jq -r '.option_label // "—"' <<<"$d")" \
            "$(jq -r '.fix_hint // "—"' <<<"$d")"
    done
    [[ -n "${decisions_comment_id:-}" ]] && \
        printf 'decisions_comment_id=%s\n' "$decisions_comment_id"
    printf '\n'
} >> "$trace_log_path"
```

### 9. User-visible summary

Print a clear summary block to chat (plain text, not a tool call):

```
Walkthrough complete. Of $scope_count finding(s) in scope:
  Promoted:    $promote_count
  Skipped:     $skip_count
  Stopped:     $stop_count
  Unreviewed:  $unreviewed_count

Promoted findings are now auto-fix-eligible via the human_confirmation
bypass (§27.6). To apply them:

  /adams-review-fix $threshold

Decisions log comment: <url to the POSTed comment, if PR mode>
Main review comment: updated in place.

You can resume later by re-running /adams-review-walkthrough — the
scope filter naturally excludes anything you already promoted, so the
$unreviewed_count unreviewed finding(s) plus any newly-added ones
will be what you see.
```

Omit the "Unreviewed" line entirely (and the final re-run sentence's
unreviewed-count clause) when `$unreviewed_count == 0` — keeps the
common-case summary tidy.

On any step failure earlier in the run, append a `Note:` section
listing the deferred failures and their recovery actions (same
pattern as `/adams-review-promote` step 10).

## What this command does NOT do

- **No fix-run.** Walkthrough is metadata-only (via promote's patch
  primitive). Run `/adams-review-fix [threshold]` afterward to apply.
- **No `disposition=disproven` handling.** Disproven findings need
  `/adams-review-promote <id> --force` with a conscious justification;
  the walkthrough scope filter excludes them.
- **No cross-branch walkthrough.** Operates on `latest.txt` for the
  current branch — same as promote and fix.
- **No resumption state file.** If you quit mid-walkthrough, the
  promotions you already made stand. Re-invoking the walkthrough
  skips them naturally (the scope filter excludes
  `human_confirmation != null`).

---

## Appendix — shared promote-core fragment

The body below is the verbatim content of
`commands/_shared/promote-core.md`, included once via the Claude Code
preprocessor. Step 5.5 above references this content — treat it as
the per-iteration playbook for a single promote decision, not as
a single-shot action.

!`cat ~/.claude/commands/_shared/promote-core.md`
