---
allowed-tools: Bash(artifact-read.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(assign-finding-ids.sh:*), Bash(log-phase.sh:*), Bash(log-tokens.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(repo-slug.sh:*), Bash(git:*), Bash(jq:*), Bash(date:*), Bash(timeout:*), Bash(sleep:*), Bash(kill:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(cat:*), Bash(printf:*), Bash(tr:*), Bash(awk:*), Bash(grep:*), Bash(mktemp:*), Read, Agent, AskUserQuestion
argument-hint: "[<paste...>] [--file path --line N --claim \"...\"] [--impact <type>] [--no-dedup]"
description: Inject externally-sourced findings (cloud /ultrareview, manual finds, etc.) into the most recent /adamsreview:review artifact for this branch. Validates via Phase 4, re-renders, re-publishes.
disable-model-invocation: false
---

Inject one or more findings sourced from outside `/adamsreview:review` —
a Claude Code cloud `/ultrareview` dump, an Opus once-over, a teammate's
Slack message, a CodeRabbit run outside `--ensemble` mode, or a human's
own discovery — into the **existing** `artifact.json` produced by the
most recent `/adamsreview:review` on this branch. Each new finding goes
through Phase 4 validation (deep Opus or light Sonnet, lane-aware) and
lands with whatever disposition the validator produces. The PR comment
is re-rendered + re-published to the existing `comment_id` so the new
findings appear alongside the original review's findings.

This command is **additive**. It does not re-run Phase 1 detection,
Phase 2 dedup against the original lens output, Phase 5 cross-cutting
analysis, or any fix loop. To re-derive everything from the diff, run
`/adamsreview:review` (which overwrites the artifact). To act on the new
findings after they land, run `/adamsreview:fix` (auto-eligible
findings only) or `/adamsreview:walkthrough` (everything else).

## Arguments

Two invocation shapes — pick whichever fits the input:

- **Free-form paste mode (default):** all positional `$ARGUMENTS`
  tokens are joined with spaces and treated as the paste body. A Sonnet
  "paste normalizer" sub-agent extracts one or more candidates from the
  text. Works for chat dumps, review summaries, multi-bug lists, etc.
- **Structured one-shot mode:** when ALL three of `--file`, `--line`,
  and `--claim` are present, skip the normalizer and build a single
  candidate inline. Useful for hand-crafted findings where the
  reviewer already knows file/line/claim and wants to skip the LLM
  round-trip.

Optional flags:

- `--impact <type>` — one of `correctness`, `security`, `ux`, `policy`,
  `architecture`. Sets `impact_type` (and thus `validation_lane`) on
  every emitted candidate. Default `correctness`. In paste mode this
  *overrides* the normalizer's per-candidate guess; useful when the
  reviewer knows the input is "all security."
- `--no-dedup` — skip the dedup pass (§step 5). Useful when the
  reviewer is confident the input is fresh, or when the artifact has
  many findings and the dedup call would be expensive.

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every step below (sub-agent return handling,
helper-script error-as-prompt).**

## Execution overview — read this first

This command runs against an artifact that ALREADY exists. The
sequencing matters:

1. **Parse arguments.** Paste / structured / mixed mode detection;
   honor `--no-dedup`, `--impact` overrides.
2. Locate the artifact via `latest.txt` (same pattern as
   `/adamsreview:fix` and `/adamsreview:promote`).
3. **Hard abort if any finding is `current_state == attempted`.**
   Mirrors `/adamsreview:fix` Phase 7's leftover-attempted gate. Adding
   findings while the artifact is mid-mutation is a footgun.
3a. **Branch-behind-base advisory.** Active fetch + behind-count vs
    `$base_branch`; if behind, `AskUserQuestion` (Stop / Proceed / Abort).
4. Build candidate findings — either via the structured one-shot, the
   paste normalizer, or both (mixed mode = paste + `--impact` override).
5. Dedup against existing findings (one Sonnet call) unless
   `--no-dedup` is set. Matched candidates merge `sources[]` into the
   existing finding; unmatched proceed to validation.
6. Assign new IDs and run the `--add-finding` loop to land the new
   candidates into `artifact.json` (continuing past the highest
   existing F-id via `assign-finding-ids.sh --start-from`).
7. Phase 4 validation, lane-aware (Opus deep / Sonnet light), no Wave 2
   chain retry. `--apply-decisions` batched call writes the §13.1
   dispositions.
8. Re-tally `subagent_tokens` + `orchestrator_tokens`, then re-render
   `artifact.md`.
9. Re-publish to the existing `comment_id` (PR mode only).
10. Append a `## add (<ts>)` block to `trace.md` and print a user-visible
    summary.

**Build a TaskList that mirrors the steps above** (1, 2, 3, 3a, 4–10).
Mark each `in_progress` when starting, `completed` when done.

## Sub-agent dispatch pattern

Sub-agent dispatches in this command:

- **Paste normalizer** (Sonnet, step 4) — only fires in paste mode.
- **Dedup** (Sonnet, step 5) — only fires when `--no-dedup` is unset
  AND there is at least one new candidate.
- **Phase 4 validators** (Opus deep / Sonnet light, step 7) — deep
  lane is one Opus per candidate; light lane is chunked-batch (≤25
  candidates per Sonnet chunk-agent). Both dispatch in a single
  orchestrator turn for concurrency.

Token extraction, `log-tokens.sh`, structured-output parse, and
helper-script error-as-prompt behaviour are all covered by rules §1
and §2 of `fragments/_prelude-shared.md` — apply them after every
sub-agent returns and on every non-zero helper exit.

## Execution

Work through the steps in order. Capture each named variable into your
working context.

### 1. Parse arguments

Parse `$ARGUMENTS`:

- Walk tokens left-to-right looking for the optional flags
  (`--file <path>`, `--line <N>`, `--claim "..."`, `--impact <type>`,
  `--no-dedup`). Strip surrounding quotes from `--claim`'s value.
- All non-flag tokens (and tokens not consumed as flag values) join
  with single spaces into `paste_body` (may be empty).

Capture:

- `cli_file`, `cli_line`, `cli_claim` (each may be empty).
- `cli_impact` (default `"correctness"`).
- `cli_impact_set` (`true` if the user explicitly passed `--impact`,
  `false` otherwise — needed by step 4b to decide whether to overlay
  the impact onto normalizer output).
- `no_dedup` (`true` / `false`, default `false`).
- `paste_body` (string; may be empty).

Determine `mode_input`:

- All three of `cli_file`, `cli_line`, `cli_claim` present → `structured`.
- `paste_body` non-empty AND `cli_file`/`cli_line`/`cli_claim` all
  empty → `paste` (the `--impact` flag, if explicitly passed, applies
  as an overlay inside paste mode — see step 4b).
- Anything else (e.g. only `cli_file` set, or all empty) → error-as-prompt:

  > ERROR: no input. Provide either:
  >   1. Free-form paste:    `/adamsreview:add <paste body...>`
  >   2. Structured one-shot: `/adamsreview:add --file <path> --line <N> --claim "<one-sentence claim>"`
  > Optional flags on either form: `--impact correctness|security|ux|policy|architecture` `--no-dedup`
  > Action: re-invoke with at least one of the two input shapes.

  Exit non-zero (usage code 64).

Validate `cli_impact` against the enum (`correctness`, `security`, `ux`,
`policy`, `architecture`). Reject unknown values with error-as-prompt.

### 2. Locate the artifact

```bash
reviews_root="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
repo_slug=$(repo-slug.sh --repo-root "$repo_root")
latest_path="$reviews_root/$repo_slug/$head_branch/latest.txt"
```

If `latest.txt` is missing or empty → error-as-prompt:

> ERROR: no review found for branch `$head_branch` under
> `$reviews_root/$repo_slug/`.
> Action: run /adamsreview:review against this branch first.

Otherwise:

```bash
review_id=$(tr -d '[:space:]' < "$latest_path")
review_dir="$reviews_root/$repo_slug/$head_branch/$review_id"
artifact_path="$review_dir/artifact.json"
trace_log_path="$review_dir/trace.md"
phases_log_path="$review_dir/phases.jsonl"
tokens_log_path="$review_dir/tokens.jsonl"
```

Schema-validate as a safety rail:

```bash
artifact-validate.sh --path "$artifact_path"
```

On non-zero: surface the validator stderr and abort. A schema-invalid
artifact means something upstream broke an invariant; do not try to
patch around it.

Capture `add_start_epoch=$(date +%s)`. Append a header to `trace.md`:

```bash
log-phase.sh \
  --review-dir "$review_dir" --phase add --name review-add \
  --summary "input_mode=$mode_input cli_impact=$cli_impact no_dedup=$no_dedup paste_length=${#paste_body}"
```

### 3. Leftover-`attempted` hard abort

```bash
leftover_ids=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter '[.findings[] | select(.current_state == "attempted") | .id] | join(", ")')
```

If `leftover_ids` is non-empty, print the deterministic recovery
message and abort (same shape as Phase 7 step 4 in
`08-fix-loader.md`):

> ERROR: previous /adamsreview:fix run did not finish (N findings
> still in 'attempted'). The working tree may still contain partial
> fix edits from that run.
>
> Recover:
>   1. `git status` — inspect what's uncommitted.
>   2. If you want to discard the partial edits: `git restore .`
>      (and `git clean -fd` for new files). Or commit/stash to keep
>      them.
>   3. For each leftover 'attempted' finding, reset state manually:
>      artifact-patch.py --finding-id <id> --set current_state=open
>   4. Re-run /adamsreview:add.
>
> Leftover 'attempted' finding ids: `$leftover_ids`

Append a one-line `add_rejected_leftover_attempted: ids=...` entry to
`trace.md` for audit, then exit non-zero.

### 3a. Branch-behind-base advisory

Active fetch — the artifact's review-time freshness snapshot may have
aged since `:review` ran. Use an explicit refspec
(`refs/heads/<base>:refs/remotes/origin/<base>`) so the fetch updates
`refs/remotes/origin/<base>` even under narrow `remote.origin.fetch`
configs that would otherwise update only `FETCH_HEAD` and leave a
stale `origin/<base>` in place. Route the rev-list by fetch success:
on success, prefer `origin/<base>` (with a defensive fallback to
local `<base>` if it somehow still doesn't resolve); on failure, fall
back to local `<base>` AND surface a "fetch failed" note so the user
knows the count may itself be stale (a bare `origin/<base>` rev-list
would silently resolve from cached refs and mislead). Track
`$merge_ref` alongside the count so the Stop guidance points at the
same ref the count was actually against — telling the user to merge
local `<base>` when the count was against `origin/<base>` would be a
no-op against a still-stale local ref. The fetch is bounded by a 30s
soft timeout (GNU `timeout` when available, background+watchdog
fallback otherwise), mirroring `freshness-gate.sh`'s §0.2a pattern so
a hung remote can't block the add run indefinitely. When neither
`origin/$base_branch` nor local `$base_branch` resolves to a count,
emit a `branch_behind_base unresolvable` trace line so an operator
inspecting `trace.md` later can distinguish a genuinely-up-to-date
branch (`behind=0`) from a silently-degraded gate (also `behind=0`).
When the fetch fails AND the local fallback resolves to `behind=0`,
emit a `branch_behind_base degraded` trace line — the gate decides
not to fire (no `AskUserQuestion` since `behind == 0`), but the
operator still needs a trail showing the count came from a possibly
stale local ref.

```bash
base_branch=$(jq -r '.base_branch' "$artifact_path")
fetch_ok=true
if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout 30 git fetch origin \
        "refs/heads/$base_branch:refs/remotes/origin/$base_branch" \
        --quiet 2>/dev/null \
        || fetch_ok=false
else
    ( GIT_TERMINAL_PROMPT=0 git fetch origin \
        "refs/heads/$base_branch:refs/remotes/origin/$base_branch" \
        --quiet 2>/dev/null ) &
    fetch_pid=$!
    ( sleep 30 && kill -TERM "$fetch_pid" 2>/dev/null ) &
    watchdog_pid=$!
    wait "$fetch_pid" 2>/dev/null || fetch_ok=false
    kill -TERM "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
fi
if $fetch_ok; then
    if behind=$(git rev-list --count "HEAD..origin/$base_branch" 2>/dev/null); then
        merge_ref="origin/$base_branch"
    else
        # origin/<base> didn't resolve — narrow-refspec edge — fall back to local
        if behind=$(git rev-list --count "HEAD..$base_branch" 2>/dev/null); then
            merge_ref="$base_branch"
        else
            behind=0
            merge_ref="$base_branch"
            printf '[%s] branch_behind_base unresolvable fetch_ok=true local_resolve=false base_branch=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_branch" \
                >> "$trace_log_path"
        fi
    fi
    fetch_note=""
else
    if behind=$(git rev-list --count "HEAD..$base_branch" 2>/dev/null); then
        merge_ref="$base_branch"
        if [[ "$behind" == "0" ]]; then
            # Degraded fail-silent path: fetch failed, local rev-list
            # resolved to 0. The AskUserQuestion below won't fire (gated
            # on `behind > 0`), so without this trace line `trace.md`
            # has no signal distinguishing "branch genuinely fresh" from
            # "fetch failed, local says 0 but local may be stale."
            printf '[%s] branch_behind_base degraded fetch_ok=false local_resolve=true behind=0 base_branch=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_branch" \
                >> "$trace_log_path"
        fi
    else
        behind=0
        merge_ref="$base_branch"
        printf '[%s] branch_behind_base unresolvable fetch_ok=false local_resolve=false base_branch=%s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$base_branch" \
            >> "$trace_log_path"
    fi
    fetch_note=" (Note: fetch of \`origin/$base_branch\` failed; behind-count is from local \`$base_branch\`, which may itself be stale.)"
fi
```

Fail-open on any non-zero git exit — the gate is a warning surface, not
a precondition.

All three branches (Proceed / Stop / Abort) write a distinct
`branch_behind_base <verdict>` audit line to `trace.md` so an operator
reading the trace later can tell which path the user took.

If `$behind > 0`, `AskUserQuestion` once:

> Branch `$head_branch` is `$behind` commits behind `$base_branch`.$fetch_note
> New findings will be deduped against the artifact's existing finding
> set and validated against the diff `:review` saw — if `$base_branch`
> has shifted, validators may reason against stale shared context
> (callers or helpers on `$base_branch` that have changed since).
> Recommend merging `$merge_ref` into `$head_branch` first.

- **(a) Stop — I'll merge `$merge_ref` into `$head_branch` first, then re-run.** Emit a `branch_behind_base stopped` trace line, then exit 0 with: `Stopping. Run \`git merge $merge_ref\` (or fast-forward) on \`$head_branch\`, then re-run /adamsreview:add.`
  ```bash
  printf '[%s] branch_behind_base stopped behind=%s merge_ref=%s fetch_ok=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$behind" "$merge_ref" "$fetch_ok" \
      >> "$trace_log_path"
  ```
- **(b) Proceed.** Append a trace line and continue. Logs `merge_ref`
  and `fetch_ok` alongside the count so an operator reading `trace.md`
  later can tell which ref the count was measured against and whether
  the active fetch succeeded — mirrors `:review` §0.6a's
  Proceed-on-warning pattern; the active variants additionally log
  `merge_ref` and `fetch_ok` because the fetch may have failed and the
  gate may have measured against a different ref than the user is told
  to merge.
  ```bash
  printf '[%s] branch_behind_base proceeded behind=%s merge_ref=%s fetch_ok=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$behind" "$merge_ref" "$fetch_ok" \
      >> "$trace_log_path"
  ```
- **(c) Abort.** Emit a `branch_behind_base aborted` trace line, then exit 0 with `Aborted.`.
  ```bash
  printf '[%s] branch_behind_base aborted behind=%s merge_ref=%s fetch_ok=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$behind" "$merge_ref" "$fetch_ok" \
      >> "$trace_log_path"
  ```

### 4. Build candidate array

Branch on `mode_input`:

#### 4a. Structured mode

Build one candidate object inline. The `evidence_snippet` field is
optional on the candidate shape (Phase 1 strips it before
`--add-finding`); we omit it because the reviewer's `--claim` IS the
evidence at this point.

```bash
new_candidates=$(jq -nc \
    --arg file "$cli_file" \
    --argjson line "$cli_line" \
    --arg claim "$cli_claim" \
    --arg impact "$cli_impact" \
    '[ {
       file: $file,
       line_range: [$line, $line],
       claim: $claim,
       impact_type: $impact,
       origin: "introduced_by_pr",
       origin_confidence: "low",
       source_family: "external-add-family",
       sources: ["external-add:cli"]
     } ]')
```

(`--argjson line` parses the integer; if the user passed a non-integer,
jq fails loudly — surface as error-as-prompt.)

#### 4b. Paste mode

Dispatch the paste normalizer sub-agent (the prompt is at the bottom
of this file under "Sub-agent prompts"). After it returns:

- Repair missing location info, mirroring Phase 1.5 §1.5.5: `file: null
  → "(unknown)"`, `line_range: null → [1, 1]`. The §13.10/§13.13
  downstream pipeline already handles `(unknown)` as a sentinel.
- If `--impact` was set, overlay it on every candidate — it overrides
  the normalizer's guess.
- If the normalizer returns `[]`, print:

  > No actionable bug claims extracted from input.
  > (The paste contained meta commentary, questions, or vague
  > suggestions only.)

  Exit 0 cleanly without mutating the artifact (skip steps 5–10; the
  trace header from step 2 is the only persisted record).

```bash
# Only overlay impact_type when the user explicitly passed --impact;
# otherwise let the normalizer's per-candidate guess stand.
if [[ "$cli_impact_set" == "true" ]]; then
    new_candidates=$(echo "$normalizer_output" | jq -c --arg impact "$cli_impact" '
      [ .[] | . + {
          file:        (.file // "(unknown)"),
          line_range:  (.line_range // [1,1]),
          impact_type: $impact,
          source_family: "external-add-family"
        } ]')
else
    new_candidates=$(echo "$normalizer_output" | jq -c '
      [ .[] | . + {
          file:        (.file // "(unknown)"),
          line_range:  (.line_range // [1,1]),
          source_family: "external-add-family"
        } ]')
fi
```

(Token logging for the normalizer happens immediately on its return,
per the dispatch pattern above. Phase tag: `phase_add`.)

Capture `normalizer_emitted=$(echo "$new_candidates" | jq 'length')`
for the step-10 trace block. In structured mode, set
`normalizer_emitted=0` (the normalizer didn't run).

### 5. Dedup against existing findings

Skip this step entirely when `no_dedup == true`.

Read the existing findings in compact form, plus a flat list of the
existing ids (used below to guard against a hallucinated `match_id`
from the sub-agent — a rare but catastrophic failure mode: without
the guard, a nonexistent `match_id` makes the sources-merge jq pipe
error on empty stdin and leaves the artifact partially mutated):

```bash
existing_compact=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter '[.findings[] | {id, file, line_range, claim}]')
existing_ids_csv=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter '[.findings[].id] | join(",")')
```

Dispatch the dedup sub-agent (the prompt is at the bottom of this
file under "Sub-agent prompts"). Capture the agent's response into
`verdicts_json` — its shape is
`{verdicts: [{new_index: N, matches: "F0NN" | null}, ...]}` with
exactly one verdict per new candidate.

Iterate `verdicts_json.verdicts[]`. For each verdict whose `matches`
is non-null, first confirm `$match_id` is in `$existing_ids_csv` (a
CSV membership check is enough — ids are `F[0-9]+`, no escaping
concerns). If the sub-agent hallucinated an id that doesn't exist,
log `add_dedup_hallucinated: new#$N → $match_id (unknown id; treating as no match)`
to `trace.md` and treat the verdict as `matches: null` — the candidate
proceeds to Phase 4 as a fresh finding. Otherwise, read the matched
finding's existing `sources[]` and union the new candidate's source
string into it via one `--set-json sources=@…` patch:

```bash
# Run once per matched verdict; $match_id and $candidate are bound
# to the verdict's "matches" field and the new candidate at
# new_candidates[new_index] respectively.
existing_sources=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter ".findings[] | select(.id == \"$match_id\") | .sources")
new_source=$(echo "$candidate" | jq -r '.sources[0]')
merged_sources=$(echo "$existing_sources" \
    | jq -c --arg s "$new_source" '. + [$s] | unique')

src_tmp=$(mktemp -t adams-add-srcs.XXXXXX)
echo "$merged_sources" > "$src_tmp"
artifact-patch.py \
    --path "$artifact_path" --finding-id "$match_id" \
    --set-json "sources=@$src_tmp"
rm -f "$src_tmp"
```

Append a trace line per merge: `add_dedup_merged: new#$N → $match_id (source=$new_source)`.

After processing every verdict, rebuild `new_candidates` to drop the
**real** matches (verdicts whose `matches` is non-null AND whose id
exists in `$existing_ids_csv`), and capture the count of merges as
`dedup_matched_count`. Hallucinated matches are filtered out here too
— their candidates flow to Phase 4 just like `matches: null` ones:

```bash
dedup_matched_count=$(echo "$verdicts_json" \
    | jq --arg ids "$existing_ids_csv" '
        ($ids | split(",")) as $known
        | [.verdicts[] | select(.matches != null and (.matches | IN($known[])))]
        | length')
matched_indices=$(echo "$verdicts_json" \
    | jq -c --arg ids "$existing_ids_csv" '
        ($ids | split(",")) as $known
        | [.verdicts[]
            | select(.matches != null and (.matches | IN($known[])))
            | .new_index]')
new_candidates=$(echo "$new_candidates" \
    | jq -c --argjson drop "$matched_indices" '
        [ to_entries[] | select((.key as $k | $drop | index($k)) | not) | .value ]')
```

If ALL new candidates were dedup-matched (no survivors after the
rebuild), skip steps 6–7 entirely (no `--add-finding`, no Phase 4) but
STILL run step 8 (re-render) and step 9 (re-publish) — the artifact
changed because existing sources were merged. Set `new_ids=""` and
`dispositions_summary="(none — all candidates merged into existing findings)"`
for the step-10 summary.

Token logging for the dedup sub-agent: phase tag `phase_add`,
agent_role `dedup`.

When `no_dedup == true`, set `dedup_matched_count=0` and proceed
directly to step 6.

### 6. Assign IDs and `--add-finding` loop

Compute the next free F-id by scanning existing ids:

```bash
next_n=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter '[.findings[].id | sub("^F"; "") | tonumber] | (max // 0) + 1')
next_id=$(printf 'F%03d' "$next_n")
```

(Bash `printf '%03d'` zero-pads to width 3, matching
`assign-finding-ids.sh`'s id format. The `(max // 0)` handles the
empty-findings edge case.)

Pipe the surviving candidates through the helper:

```bash
ids_assigned=$(echo "$new_candidates" \
    | assign-finding-ids.sh --start-from "$next_id")
```

Read `trivial_mode` from the artifact so the `validation_lane`
derivation below matches Phase 1's builder (`01-detection.md` §1.10,
per DESIGN §13.9 / §19.6). Under `trivial_mode`, every candidate lands
in the light lane regardless of `impact_type` — Phase 4b handles the
whole pool and light-lane-under-trivial refuses `auto_fixable`. If we
skipped this branch here, new findings would ship with
`validation_lane="deep"` while the rest of the trivial-mode artifact
has `validation_lane="light"`, and the renderer's lane-section filters
(`artifact-render.py` — `.validation_lane == "deep"`/`"light"`) would
misplace them:

```bash
trivial_mode=$(jq -r '.trivial_mode' "$artifact_path")
```

Build full schema-valid finding objects (mirrors the Wave 2 builder in
`05-validation.md` §4.5 step 1):

```bash
findings_to_add=$(echo "$ids_assigned" \
    | jq -c --argjson trivial "$trivial_mode" '
  [ .[] | {
      id,
      sources,
      source_families: [.source_family],
      impact_type,
      origin,
      origin_confidence,
      actionability: "auto_fixable",   # placeholder; Phase 4 sets the truth
      validation_lane: (
        if $trivial then "light"
        elif (.impact_type == "correctness" or .impact_type == "security") then "deep"
        else "light" end
      ),
      current_state: "open",
      disposition: "pending_validation",
      is_actionable: false,
      reason: null,
      confirmed_strength: null,
      file,
      line_range,
      claim,
      score_phase3: null,
      score_phase4: null,
      score_history: [],
      validation_result: null,
      fix_attempts: [],
      introduced_in_sha: null,
      suggested_follow_up: null,
      related_parent_finding_id: null
    } ]')
```

Note: `actionability` is set to `auto_fixable` as a placeholder so the
schema requirement is satisfied; Phase 4's `--apply-decisions` will
overwrite it with the validator's truth. `validation_lane` mirrors
Phase 1's rule: `light` under `trivial_mode`, else `deep` for
correctness/security and `light` for ux/policy/architecture.
`disposition: "pending_validation"` is the standard "awaiting Phase 4
verdict" parking state.

Loop and add each finding:

```bash
echo "$findings_to_add" | jq -c '.[]' | while IFS= read -r f; do
    artifact-patch.py \
        --path "$artifact_path" --add-finding "$f"
done
```

Capture the new ID list as `new_ids` (CSV) for step 7's dispatch and
step 10's summary:

```bash
new_ids=$(echo "$findings_to_add" | jq -r '[.[].id] | join(",")')
```

Append `add_new_findings: $new_ids` to `trace.md`.

### 7. Phase 4 validation (lane-aware, no Wave 2)

This step inlines the relevant slices of
`fragments/05-validation.md` — lane partition, deep + light
dispatch, post-wave tree-cleanliness sweep, `--apply-decisions`, and
the §4.6 pre-existing override re-assertion. Wave 2 chain retry is
intentionally NOT included (the user is adding a bounded set; following
`related_candidates_to_investigate` chains would expand scope
unpredictably).

Capture `phase_4_start_epoch=$(date +%s)`.

Snapshot the working tree's cleanliness before dispatch. Step 7.5's
belt-and-braces sweep reverts any dirty state detected after
validators run — but only when the tree was clean going in. Unlike
`/adamsreview:review` Phase 0, `/adamsreview:add` has no clean-tree gate
(§3.8 design decision: validators are read-only by contract). If the
user has their own uncommitted work when they invoke this command, a
blind sweep would clobber it.

```bash
pre_validator_clean=true
if [[ -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" ]]; then
    pre_validator_clean=false
fi
```

#### 7.1 Read CLAUDE.md paths from the artifact

```bash
claude_md_paths=$(artifact-read.sh \
    --path "$artifact_path" --filter '.claude_md_paths | join(" ")')
```

These are the paths the original review found via
`claude-md-paths.sh`. Re-using them ensures validators in this command
see the same governance context the original Phase 4 saw.

#### 7.2 Partition new candidates into lanes

```bash
trivial_mode=$(jq -r '.trivial_mode' "$artifact_path")

deep_ids=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter "[.findings[] | select(.id | IN(\"${new_ids//,/\",\"}\")) | select(.validation_lane == \"deep\") | .id] | join(\",\")")

light_ids=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter "[.findings[] | select(.id | IN(\"${new_ids//,/\",\"}\")) | select(.validation_lane == \"light\") | .id] | join(\",\")")

# Honor the existing artifact's trivial_mode per 05-validation.md §4.1:
# under trivial_mode, every new candidate routes to the light lane and
# the light prompt's "no auto_fixable under trivial_mode" rule applies.
if [[ "$trivial_mode" == "true" ]]; then
    light_ids="$new_ids"
    deep_ids=""
fi

# `${var:+...}` evaluates to empty when var is empty/unset, so we get
# 0 on empty without the awk-on-empty pitfall.
deep_count=0
light_count=0
[[ -n "$deep_ids" ]]  && deep_count=$(awk -F, '{print NF}'  <<<"$deep_ids")
[[ -n "$light_ids" ]] && light_count=$(awk -F, '{print NF}' <<<"$light_ids")
```

#### 7.3 Deep-lane dispatch (Opus, one sub-agent per candidate)

For each id in `deep_ids`, launch ONE `Agent` tool-use with `model:
opus`, `subagent_type: general-purpose`, dispatched in a single
orchestrator turn for concurrency. Read the finding JSON and pass it
inline.

**One Opus per candidate — never collapse multiple deep-lane candidates
into a single batched Opus call.** Same rule as `05-validation.md` §4.2
and the same structural enforcement: §7.6's `--apply-decisions
--expected $total_dispatched` rejects under-sized batches with a
recovery action. Each candidate needs its own blast-radius trace and
fix-proposal context.

Prompt essence — verbatim from `05-validation.md` §4.2 (kept
self-contained here for the user-add path; do NOT dispatch through that
fragment as it pulls in the Wave-2/§4.6/§4.4.5 prelude that doesn't
apply):

> You are a deep validator. Confirm or disprove this candidate, trace
> its blast radius, and — if real — produce a concrete fix proposal.
>
> **Candidate:** `<finding JSON>`
> **CLAUDE.md paths:** `$claude_md_paths`
>
> **Read-only.** Do not use `Edit` or `Write`, and do not run Bash that
> mutates the tree (no `git checkout`, no `git restore`, no writes into
> tracked paths). If a fix is warranted, describe it in `fix_proposal` —
> Phase 8 applies it.
>
> Steps:
> 1. **Confirm or disprove.** Trace the claim end-to-end in the code.
>    Read function BODIES, not just signatures. Consult git blame if
>    the history clarifies intent.
> 2. **Trace blast radius.** For every writer, consumer, parallel path,
>    and relevant test — enumerate them in `blast_radius`.
> 3. **Construct reproduction or disproof.** A concrete input / state /
>    call sequence that triggers the bug, OR evidence showing it can't.
> 4. **If real: produce `fix_proposal.files_to_modify` — the full class,
>    not just the obvious site.** Cross-check against
>    `blast_radius.parallel_paths`. Grep the repo for in-repo precedent.
> 5. **Produce `verification_context`:** `how_to_verify_fix`,
>    `edge_cases_to_preserve`, `what_would_break_if_incomplete`.
> 6. **Re-score 0–100** using the §20 rubric — based on what you found.
> 7. This finding was injected by `/adamsreview:add` from an external
>    source; do NOT emit `related_candidates_to_investigate` (no Wave 2
>    in this code path). If you notice adjacents, mention them in
>    `evidence` for the user's awareness only.
>
> Return JSON (matches the `validation_result` schema):
> ```
> {
>   "validation_result": {
>     "evidence": ["..."],
>     "blast_radius": {"writers": [], "consumers": [], "parallel_paths": [], "invariants_at_stake": []},
>     "fix_proposal": {"approach": "...", "files_to_modify": [{"file":"...", "what":"...", "why":"..."}]},
>     "verification_context": {"how_to_verify_fix": [], "edge_cases_to_preserve": [], "what_would_break_if_incomplete": []}
>   },
>   "score_phase4": <0-100>,
>   "decision": "confirmed" | "disproven" | "uncertain",
>   "actionability": "auto_fixable" | "manual" | "report_only"
> }
> ```
>
> Every nested array must exist (can be empty). When `decision !=
> confirmed`, set `validation_result: null` instead of populating the
> object — the orchestrator only persists `validation_result` on
> confirmed findings.

After each sub-agent returns: log tokens per candidate (phase
`phase_add`, agent_role `validator`, `--finding-id` set, model `opus`).

#### 7.4 Light-lane dispatch (Sonnet, chunked-batch fan-out)

Split `light_ids` into chunks of **at most 25 candidates per chunk**,
balanced as evenly as feasible. For each chunk, launch ONE `Agent`
tool-use with `model: sonnet`. Dispatch all chunk-agents in one
orchestrator turn for concurrency. Same chunked rationale as
`05-validation.md` §4.3 — light-lane work is rubric-checking, not
per-candidate investigation, so it batches well; the 25-cap restores
parallelism on large add-pasted batches and keeps each chunk-agent's
working set small enough to use the full 0-100 score range.

Prompt essence — verbatim from `05-validation.md` §4.3:

> You are a light confirmation validator. You will return one entry
> per candidate.
>
> **Candidates (N total):**
> ```
> <full JSON array of every finding in this chunk>
> ```
>
> **CLAUDE.md paths:** `$claude_md_paths`
> **trivial_mode:** `<true|false>` (when true, do NOT emit
> `actionability: auto_fixable` for ANY candidate — only `manual` or
> `report_only`).
>
> **Read-only.** Do not use `Edit` or `Write`; describe any needed
> change in each finding's `note` — it's not yours to apply.
>
> Verify each finding's accuracy only: does the CLAUDE.md really
> contain this rule? Does the adjacent comment really conflict?
> Adjust the per-candidate score accordingly.
>
> Flag `actionability: auto_fixable` ONLY for very mechanical rules
> (e.g. import ordering, specific constant naming). Judgment calls →
> `manual`. Architecture findings default to `report_only`.
>
> **Anti-anchor-clustering instruction (chunk-batch specific):** Use
> the full 0-100 range. Phase-4 routing has cutoffs at 45, 60, 75 — a
> finding between adjacent anchors should score in between (e.g. 60,
> 65). Do not snap onto an anchor.
>
> Return JSON array, one entry per candidate (order does not matter,
> routing is by `id`):
>
> ```
> [{"id":"<finding-id>","decision":"confirmed|disproven|uncertain","score_phase4":<0-100>,"actionability":"auto_fixable|manual|report_only","note":"brief rationale"}, ...]
> ```

After each chunk-agent returns: log tokens once per chunk-agent
(phase `phase_add`, agent_role `validator`, `--finding-id` OMITTED
because tokens are agent-level when a single sub-agent owns multiple
findings, model `sonnet`).

#### 7.5 Tree-cleanliness sweep (belt-and-braces)

After every validator dispatch returns, run a `git status --porcelain`
sweep **only when the tree was clean at step 7 entry**
(`pre_validator_clean == "true"`). Validators have no legitimate reason
to touch the working tree — the §7.3/§7.4 prompts already forbid it —
so any new dirt against a clean baseline is a prompt-override we can
safely revert.

When `pre_validator_clean == "false"` (the user had their own
uncommitted work going in), skip the sweep. Without a clean baseline
we can't distinguish user state from validator writes, and a blind
revert would clobber user work. `/adamsreview:add` has no Phase-0
dirty-tree gate (§3.8), so this is the only safeguard against that
data-loss class.

```bash
if [[ "$pre_validator_clean" == "true" ]]; then
    dirty=$(git -C "$repo_root" status --porcelain 2>/dev/null)
    if [[ -n "$dirty" ]]; then
        printf 'add_tree_dirty_reverted: %s\n' \
            "$(printf '%s\n' "$dirty" | awk '{print $2}' | paste -sd, -)" \
            >> "$trace_log_path"
        git -C "$repo_root" checkout -- . 2>/dev/null || true
        printf '%s\n' "$dirty" | awk '/^\?\?/ {print $2}' \
            | while IFS= read -r p; do rm -f "$repo_root/$p"; done
    fi
else
    printf 'add_tree_dirty_sweep_skipped: pre-existing dirty tree (user work preserved)\n' \
        >> "$trace_log_path"
fi
```

#### 7.6 Build the decision tuple array and apply

Compose one tuple per validator response. For deep-lane responses,
pass `validation_result` extracted from the sub-agent's outer envelope
(it'll be the populated nested object when the validator returned
`decision: confirmed`, else `null`). For light-lane responses (whose
prompt doesn't include a `validation_result` envelope), pass
`validation_result: null`. The helper persists `validation_result`
only when the tuple supplies a non-null value AND the derived
disposition lands in the confirmed band — so deep-lane confirmed
findings get the full validator output stored, light-lane confirmed
findings get nothing (matching Phase 4.4's behavior in the original
review path).

**The contract is the output, not the technique.** Agent tool results
land in orchestrator context, not a shell variable, so there's no
single "right" way to marshal them. Compose the tuple array however is
natural — a direct `Write` of the assembled JSON array, a `jq`
pipeline, or an inline helper script — and emit it to
`$scratch/add-decisions.json`. The trailing `rm -rf "$scratch"` below
cleans everything in that directory, so ad-hoc helpers that land
inside it get auto-removed too. Tuple shape is identical to
Phase 4.4's (`{id, score_phase4, decision, actionability, reason,
validation_result}`) — the helper validates and aborts the batch on
shape drift.

```bash
scratch="/tmp/adams-review-add-$review_id"
mkdir -p "$scratch"

# Compose the tuple array in orchestrator context and write it to
# $scratch/add-decisions.json by whatever means is natural. The helper
# only cares about the file path + tuple shape.

# total_dispatched = N_deep + N_light (count individual candidates,
# NOT chunk-agents — each light-lane chunk-agent owns multiple
# findings and is expected to return one tuple per finding it owned).
# Used by --expected as the structural guard against batched-Opus
# collapse (deep) and chunk-array drops (light). Same discipline as
# 05-validation.md §4.4.
total_dispatched=$(( deep_count + light_count ))

out=$(artifact-patch.py \
        --path "$artifact_path" \
        --apply-decisions "@$scratch/add-decisions.json" \
        --expected "$total_dispatched")
echo "$out"

rm -rf -- "$scratch"
```

Capture `dispositions_summary` for the step-10 trace block by reading
back the new findings:

```bash
dispositions_summary=$(artifact-read.sh \
    --path "$artifact_path" \
    --filter "[.findings[] | select(.id | IN(\"${new_ids//,/\",\"}\")) | \"\\(.id)=\\(.disposition)\"] | join(\" \")")
```

On parse failure for any sub-agent: emit `score_phase4: null` for that
tuple — the helper routes it to `uncertain` automatically. Override
the default reason via `reason: "Phase 4 parse failure — manual
review"` for legibility. The tuple still counts toward `--expected`,
so parse failures do not trip the structural guard.

**On `--expected` rejection (exit 6, count mismatch):** the helper
emits a stderr block naming expected vs received count and the
recovery action. Bidirectional check — under-count means deep-lane
Opus dispatches were collapsed (re-dispatch one Agent per missing
candidate) or a light-lane chunk-agent dropped findings from its
returned array (re-dispatch the chunk for the missing ids); over-
count means the orchestrator emitted extra tuples (e.g. a chunk-
agent returned hallucinated ids that were forwarded verbatim — strip
them before re-invoking). Recompose the tuple array on the corrected
result set and re-invoke; do NOT lower `--expected` to match the
received count — the guard is exactly what is supposed to catch
this. The artifact is left unchanged on this exit. Same contract as
`fragments/05-validation.md` §4.4.

#### 7.7 Pre-existing override re-assertion (§13.1)

After `--apply-decisions` returns, sweep the new ids one more time —
catches any new finding the validator graduated to a confirmed band
while marking it `pre_existing` with `high` confidence.

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter "[.findings[] | select(.id | IN(\"${new_ids//,/\",\"}\")) | select(.origin == \"pre_existing\" and .origin_confidence == \"high\" and .disposition != \"pre_existing_report\") | .id]"
```

For each returned id:

```bash
artifact-patch.py \
  --path "$artifact_path" --finding-id "$id" \
  --set disposition=pre_existing_report \
  --set is_actionable=false \
  --set actionability=report_only \
  --set confirmed_strength=null \
  --set reason=null
```

#### 7.8 Log Phase 4 summary for the add pass

```bash
phase_4_elapsed=$(( $(date +%s) - phase_4_start_epoch ))

log-phase.sh \
  --review-dir "$review_dir" --phase add --name validation \
  --elapsed "$phase_4_elapsed" \
  --summary "deep=$deep_count light=$light_count new_ids=$new_ids"
```

### 8. Re-tally `subagent_tokens` + `orchestrator_tokens`, then re-render `artifact.md`

Re-tally first so the rendered report (and the downstream PR comment
update in step 9) reflects this run's new sub-agent + orchestrator
spend on top of the prior `/adamsreview:review` baseline. The paste
normalizer (§4b) and any Phase-4 re-validators that ran during this
`/adamsreview:add` invocation already logged their sub-agent usage to
`tokens.jsonl`; the orchestrator transcript on disk captured every
main-session turn. Both helpers are pure readbacks:

```bash
tally-subagent-tokens.sh \
    --tokens-log "$tokens_log_path" \
    --artifact   "$artifact_path" \
    2>>"$trace_log_path" || printf 'add_tally_failed\n' >> "$trace_log_path"

review_started_at=$(jq -r '.review_started_at // empty' "$artifact_path")

orchestrator-tokens.sh \
    --artifact "$artifact_path" \
    --since    "$review_started_at" \
    2>>"$trace_log_path" || printf 'add_orchestrator_tally_failed\n' >> "$trace_log_path"

artifact-render.py \
    --input "$artifact_path" \
    --output "$review_dir/artifact.md"
```

Tally failures are non-fatal (observability, not correctness); stale
`subagent_tokens.total` or `orchestrator_tokens.turn_count` doesn't
block the re-publish. Render non-zero: log stderr to `trace.md` with
tag `add_render_failed`, continue to step 9 (the artifact patches
stand; the user can manually re-render).

### 9. Re-publish to the PR (PR mode only)

Read mode + comment_id from the artifact:

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

On non-zero exit: log stderr to `trace.md` with tag `add_publish_failed`.
Surface to the user at step 10. The artifact state persists; the user
can manually re-publish with the helper.

### 10. Append trace block + user-visible summary

Append to `trace.md`:

```bash
add_elapsed=$(( $(date +%s) - add_start_epoch ))
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

{
    printf '## add (%s)\n' "$ts"
    printf 'input_mode: %s\n' "$mode_input"
    printf 'input_length: %s\n' "${#paste_body}"
    printf 'cli_impact: %s\n' "$cli_impact"
    printf 'no_dedup: %s\n' "$no_dedup"
    printf 'normalizer_emitted: %s\n' "$normalizer_emitted"
    printf 'dedup_matched: %s\n' "$dedup_matched_count"
    printf 'new_finding_ids: %s\n' "$new_ids"
    printf 'phase_4_dispositions: %s\n' "$dispositions_summary"
    printf 'elapsed_sec: %s\n' "$add_elapsed"
    printf '\n'
} >> "$trace_log_path"
```

Print a clear summary block to chat:

```
Added N new findings to <review_id>:
  F037 confirmed_mechanical    correctness  src/foo.ts:142 — early-return skips audit-log
  F038 uncertain         correctness  src/bar.ts:88  — possible race in cache invalidation
  F039 disproven         correctness  src/baz.ts:12  — (validator found positive evidence; not a real issue)

Deduplicated K candidates against existing findings (sources merged):
  new#2 → F003   (skipped — same underlying issue)

Cumulative sub-agent spend: <total> tokens across <invs> invocations.
Cumulative orchestrator spend: <output> output / <input> input across <turns> turns.

Next:
  - /adamsreview:fix             apply newly auto-eligible findings (deep-lane confirmed_mechanical)
  - /adamsreview:walkthrough     promote any non-eligible new findings (light-lane / manual / uncertain)
```

Build the per-finding lines from `artifact-read.sh`:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter "[.findings[] | select(.id | IN(\"${new_ids//,/\",\"}\"))
            | \"  \\(.id) \\(.disposition | (. + \"                \")[0:18]) \\(.impact_type | (. + \"          \")[0:11]) \\(.file):\\(.line_range[0]) — \\(.claim | .[0:80])\"]
            | join(\"\n\")"
```

Read the cumulative spend numbers from the artifact (populated by §8's
re-tally). Direct `jq -r` call so stdout is the chat line itself, not
a JSON-quoted string (`artifact-read.sh --filter` doesn't enable raw
mode). Omit each line entirely if its source field is absent — matches
`artifact-render.py`'s renderer guard so the chat never shows `null
tokens across null invocations`:

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

If publish failed in step 9, append:

```
Note: PR comment republish FAILED (see trace.md tag add_publish_failed).
The artifact patches stand; to republish run:
  artifact-publish.sh --mode pr --review-id <id> --pr <N> \
      --repo-slug <slug> --branch <branch> --review-dir <dir> --comment-id <cid>
```

## What this command does NOT do

- **No fix-run.** Add is metadata-only (with validation). Run
  `/adamsreview:fix` afterward to apply auto-eligible new findings.
- **No promotion.** New findings land at whatever disposition Phase 4
  produces. Run `/adamsreview:walkthrough` (or
  `/adamsreview:promote <id>`) to promote anything that didn't land
  deep-`confirmed_mechanical`.
- **No Phase 5 cross-cutting recompute.** Added findings are not
  retroactively grouped into existing `cross_cutting_groups`.
  Documented small loss; the rendered report still shows them in the
  standard per-finding tables.
- **No persistence across fresh `/adamsreview:review` runs.** A re-review
  overwrites the artifact; added findings are lost. Re-add if needed.

## Sub-agent prompts (used by steps 4 and 5)

Defined in this file (rather than as separate fragments) to keep the
add path self-contained. Inline copies, not separate-fragment reads —
the prompts are short and the indirection cost outweighs the reuse
benefit for two short prompts used by exactly one command.

### Paste-mode normalizer prompt (Sonnet)

> You are normalizing an externally-sourced code-review note into the
> adamsreview candidate schema. The reviewer has either pasted a chat
> transcript / review summary from another tool (Claude Code
> /ultrareview, Opus chat, CodeRabbit text output, a teammate's Slack
> message) or hand-written a list of bugs they want added.
>
> **Input** (free-form text; may contain markdown, code fences, prose):
>
> ```
> <paste_body>
> ```
>
> **Files in the PR diff** (for location resolution context):
>
> ```
> <reviewed_files_all from artifact>
> ```
>
> Extract concrete bug claims. Rules:
>
> - One candidate per distinct bug. A single paragraph that describes
>   three issues becomes three candidates.
> - Discard meta commentary, praise, questions, "looks good," vague
>   suggestions without a concrete claim.
> - Resolve `file` from the text when possible (paths, code fences with
>   filenames, "in foo.ts:..."). Cross-check against the diff file
>   list — prefer matches. Emit `file: null` when ambiguous.
> - Resolve `line_range` similarly. Emit `null` when not stated.
> - Classify `impact_type` conservatively: prefer `correctness`. Use
>   `security` only with concrete evidence. `ux`/`policy`/`architecture`
>   per their normal definitions.
>
> Return strict JSON. No surrounding prose. No code fences. Shape:
>
> ```
> [
>   {
>     "file": "src/path/to/file.ts" | null,
>     "line_range": [start, end] | null,
>     "claim": "one-sentence description",
>     "evidence_snippet": "relevant excerpt from the paste",
>     "impact_type": "correctness" | "security" | "ux" | "policy" | "architecture",
>     "origin": "introduced_by_pr" | "pre_existing" | "unknown",
>     "origin_confidence": "low",
>     "source_family": "external-add-family",
>     "sources": ["external-add:paste"]
>   }
> ]
> ```
>
> If the input contains no actionable bug claims, return `[]`.

Model: Sonnet. Tool access: none (text-only — the paste IS the input).
Budget: ~3–8k tokens depending on paste length.

### Dedup prompt (Sonnet)

> You are deduplicating new bug candidates against an existing review's
> findings. For each new candidate, decide whether it describes the
> same underlying issue as one of the existing findings.
>
> **New candidates** (JSON array):
>
> ```
> <new_candidates>
> ```
>
> **Existing findings** (JSON array of `{id, file, line_range, claim}`):
>
> ```
> <existing_compact>
> ```
>
> Rules:
>
> - A match means "same underlying behavior" (same file region + same
>   invariant violation), not just "nearby code."
> - Be conservative: prefer "no match" when unsure. False matches drop
>   real new findings; false non-matches just produce a near-duplicate
>   (the report handles).
> - Each new candidate matches AT MOST ONE existing finding.
> - Existing findings are NOT compared against each other.
>
> Return strict JSON:
>
> ```
> {
>   "verdicts": [
>     {"new_index": 0, "matches": "F003"},
>     {"new_index": 1, "matches": null}
>   ]
> }
> ```
>
> `new_index` is the 0-based index into the new-candidates array. One
> verdict per new candidate. `matches` is either an existing finding
> id or `null`.

Model: Sonnet. Budget: ~2–4k tokens.
