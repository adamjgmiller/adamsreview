---
allowed-tools: Bash(artifact-read.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(repo-slug.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(cat:*), Bash(printf:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(tr:*), Read, AskUserQuestion
argument-hint: "<finding_id> [--reason \"...\"] [--fix-hint \"...\"] [--force] [--defer-publish]"
description: Promote a finding to auto-fixable via human override. Patches artifact, re-renders, re-publishes to PR.
disable-model-invocation: false
---

Promote a single finding from the most recent `/adamsreview:review` on this
branch to `disposition=confirmed_mechanical`, recording full provenance in
`human_confirmation` so `/adamsreview:fix` will pick it up on its next
run. See DESIGN §27 for the contract and §5.2.1 for how the Phase 8
eligibility bypass works.

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every step below (sub-agent return handling,
helper-script error-as-prompt).**

## Arguments

- `<finding_id>` (required, positional) — matches `^F[0-9]+$`. The id
  shown in the artifact's PR comment or `artifact.md`.
- `--reason "..."` (optional) — free-form justification recorded in
  `human_confirmation.reason`. Audit-focused ("why I promoted"). If
  omitted, you'll be prompted.
- `--fix-hint "..."` (optional) — free-form steering instruction
  recorded in `human_confirmation.fix_hint` and surfaced to the
  Phase 8 fix-group agent. Instruction-focused ("how to fix"). Use
  this when the claim is ambiguous about which side of a code/text
  mismatch to change (e.g. "update the docstring to match the code;
  do not modify the code"). Auto-prompted when omitted on a
  light-lane finding (one whose `validation_result` is null) so the
  fix agent isn't left guessing. Deep-lane findings can still pass
  it explicitly to override the validator's `fix_proposal.approach`.
- `--force` (optional) — required when promoting a finding currently
  at `disposition=disproven` (validator found positive evidence it's
  wrong). Without `--force`, disproven findings reject promotion with
  a user-visible message pointing to the validator's conclusion.
- `--defer-publish` (optional) — skip steps 7 (re-render), 8
  (re-publish to PR), and 10 (user-visible summary). The artifact
  patch and trace entry still land. Useful for scripted promote
  loops where render+publish should run once at the end rather than
  per-iteration; `/adamsreview:walkthrough` (§28) uses this
  internally. When set, the caller is responsible for running
  `artifact-render.py` and `artifact-publish.sh` afterward.

## What it does

1. Parses args.
2. Locates the artifact via `latest.txt` under
   `~/.adams-reviews/<slug>/<branch>/`.
3. Reads the target finding. Enforces preconditions (see shared
   `promote-core.md` step 4).
4. Patches the finding atomically via `artifact-patch.py` (see shared
   `promote-core.md` step 6).
5. Re-renders `artifact.md`.
6. Re-publishes to the PR (PR mode) or no-ops (local mode) — the same
   `gh api PATCH` flow `/adamsreview:fix` uses at Phase 9e.
7. Appends a `## promote (<ts>)` block to `trace.md`.
8. Prints a summary showing what changed.

Does NOT run `/adamsreview:fix` for you. Run it yourself when you're
ready to apply promoted findings.

## Execution

Work through the steps below in order. Capture each named variable
into your working context. Mark each task `in_progress` when you start
and `completed` when done. Build a TaskList that mirrors these step
headings.

### 1. Parse arguments

Parse `$ARGUMENTS` (whitespace-split, respecting `"..."` quoted values
for `--reason` and `--fix-hint`):

- First token matching `^F[0-9]+$` → `finding_id`.
- `--reason "..."` → `reason` (strip surrounding quotes).
- `--fix-hint "..."` → `fix_hint` (strip surrounding quotes). Default:
  empty string (treated as "absent" throughout — the jq at step 5
  omits the key entirely when empty).
- `--force` → `force=true` (else `false`).
- `--defer-publish` → `defer_publish=true` (else `false`).
- Any other token → stop and ask the user to clarify.

If no `finding_id` was provided, error-as-prompt:

> ERROR: missing finding_id.
> Valid input: /adamsreview:promote F037 [--reason "..."] [--fix-hint "..."] [--force]
> Action: pass a finding id (matching `^F[0-9]+$`) as the first arg.

If `--reason` was not provided, dispatch `AskUserQuestion` once with
three options:
- "Validator was too conservative — the issue is real."
- "I've verified this manually and want it auto-fixed."
- "Other (I'll supply the reason)."

For the "Other" branch, ask for the free-form reason. For the two
canned options, use the option text as `reason`. Capture the final
`reason` string (non-empty).


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

Capture paths. Schema-validate as a safety rail:

```bash
artifact-validate.sh --path "$artifact_path"
```

On non-zero: surface the validator stderr and abort — a broken
artifact means something upstream is wrong; promote is not the right
tool to diagnose it.

### 3–6, 9. Shared promote core

Steps 3 (read finding + existing-id suggestion), 4 (precondition
table), 4.5 (`fix_hint` heuristic prompt), 5 (build
`human_confirmation` object), 6 (atomic patch), and 9 (append trace
entry) live in the shared fragment below. It reads `$finding_id`,
`$reason`, `$fix_hint`, `$force`, `$artifact_path`, and
`$trace_log_path` from ambient context and populates `$curr_disp`,
`$curr_action`, `$curr_score`, `$curr_hc`, `$ts`, and `$reviewer` for
use in steps 7, 8, and 10 below.

Read `fragments/promote-core.md` and execute the listed steps (3, 4,
4.5, 5, 6, and 9) inline before proceeding to step 7 below.

### 7. Re-render `artifact.md`

Skip this step entirely when `defer_publish == true` — jump to step
8. The caller is expected to run `artifact-render.py` once after
all deferred promotes have landed.

```bash
artifact-render.py \
    --input "$artifact_path" \
    --output "$review_dir/artifact.md"
```

On non-zero: log stderr to `trace.md` with tag `promote_render_failed`,
continue to step 8 (the artifact patch stands; the user can manually
re-render).

### 8. Re-publish to the PR (PR mode only)

Skip this step entirely when `defer_publish == true` — jump to step
10. The caller is expected to run `artifact-publish.sh` once after
all deferred promotes have landed.

Read `mode`, `pr_number`, `comment_id` from the artifact:

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

artifact-publish.sh "${publish_args[@]}"
```

If `mode == "local"`: call with `--mode local --review-id "$review_id"
--review-dir "$review_dir"` (no-op that appends a trace line).

On non-zero exit: log stderr to `trace.md` with tag
`promote_publish_failed`. Surface to user at step 10 (artifact state
persists; user can manually re-publish with the helper).

### 10. User-visible summary

When `defer_publish == true`, print only a terse one-liner so the
caller's own summary (e.g. `/adamsreview:walkthrough`'s decisions
log) isn't drowned out:

```
Promoted $finding_id (deferred — artifact patched, render/publish skipped).
```

And skip the rest of this step.

Otherwise, print a clear summary block to chat (plain text, not a
tool call):

```
Promoted $finding_id:
  disposition:    $curr_disp → confirmed_mechanical
  actionability:  $curr_action → auto_fixable
  score_phase4:   $curr_score (preserved)
  reviewer:       $reviewer
  reason:         $reason

Next: run /adamsreview:fix to apply this and any other
confirmed_mechanical/partial/regression findings.
```

When `fix_hint` is non-empty, append one additional line to the block
BEFORE the blank line and `Next:` footer:

```
  fix_hint:       $fix_hint
```

Omit the line entirely when `fix_hint` is empty — keeps the summary
tidy for promotions that didn't need steering.

If the publish step failed, append:

```
Note: PR comment republish FAILED (see trace.md tag
promote_publish_failed). The artifact patch stands; to republish run:
  artifact-publish.sh --mode pr --review-id $review_id --pr $pr_number \
      --repo-slug $repo_slug --branch $head_branch --review-dir $review_dir
```

## What this command does NOT do

- **No fix-run.** Promote is metadata-only. You must run
  `/adamsreview:fix` to apply the promoted finding.
- **No batch promotion.** One finding per invocation. Loop from the
  shell if you need multiple:
  `for id in F003 F037 F039; do /adamsreview:promote $id --reason "..."; done`
- **No demotion / undo.** There is no `/adamsreview:demote`. If you
  change your mind BEFORE running `/adamsreview:fix`, manually patch
  the artifact:
  `artifact-patch.py --path <artifact> --finding-id F037 --set-json human_confirmation=null --set disposition=<prior> --set actionability=<prior>`
- **No persistence across fresh `/adamsreview:review` runs.** A new review
  overwrites the artifact; promotions are lost. Re-promote if needed.
  (Future work: `overrides.json` sidecar keyed by claim fingerprint.)
- **No argument for changing `score_phase4`.** The validator's score is
  preserved for audit. Phase 8 eligibility bypasses the score threshold
  for promoted findings via the `human_confirmation != null` gate.
