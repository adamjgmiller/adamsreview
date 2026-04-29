## Phase 1.5 — Ensemble adapter (conditional on `--ensemble`)

**Skip this entire phase** unless `ensemble_mode == true` (captured in Phase 0
step 0.1). Log one line to `trace.md` and proceed to Phase 2:

```
Phase 1.5 skipped — --ensemble not set
```

**Dispatch under §13.12.** When `--ensemble` IS set, Phase 1.5's CLI
launches fire in the same orchestrator turn as the Phase 1 lens
`Agent` dispatches — see 01-detection.md step 1.3. The PR comment
scrape (§1.5.4) is deferred to after CLI collection so third-party
PR-comment bots have time to land their posts. This fragment documents
the Phase-1.5-owned work (readiness pointer, launch specs, normalizer,
token logging, summary); execution sequencing is orchestrated from
01-detection.md. The readiness gate moved to 01-detection.md step
1.2a so missing-CLI prompts surface before any token spend.

Phase 1.5 pulls additional candidates from three external channels:

1. **CodeRabbit CLI** — `coderabbit review --agent -t all --base <base>`, a
   local Claude-like review that emits findings to stdout (does not post to
   the PR). Runs in background; result awaited before the normalizer dispatch.
2. **Codex CLI** — `node "$CODEX_COMPANION" task --prompt-file <file>`, a
   local Codex-based review. Same shape.
3. **GitHub PR comment scrape** — `external-scrape.sh` pulls bot-authored
   comments on the PR. Fires after the CLI reviewers' outputs are collected
   (§1.5.4) so third-party PR-comment bots — CodeRabbit-as-GitHub-App,
   Greptile, etc. — have the CLI minutes to land their posts before we
   fetch. Only runs when `mode == pr`. Local mode can't scrape a PR that
   doesn't exist.

All three feed a single Sonnet normalizer sub-agent that emits
standard candidates. The normalizer's output pools into the
orchestrator-context `external_candidates` variable; the join step at
01-detection.md 1.5 assigns ids and commits to `artifact.findings[]`
with `source_family: "external-deep-family"` and
`origin_confidence: "low"`.

**Token accounting.** CodeRabbit and Codex CLI spend is NOT logged to
`tokens.jsonl`. Only the Sonnet normalizer is logged, under `phase_1_5`.

### 1.5.1. Readiness

By this point, `coderabbit_available`, `codex_available`,
`CODEX_COMPANION`, `scratch_dir`, `phase_1_5_start_epoch`, and the
Codex prompt file are in working context (set by `01-detection.md`
step 1.2a).

### 1.5.2. Launch CLI reviewers (background Bash; dispatched from 01 step 1.3)

These launches are tool-use blocks in the **01-detection.md step 1.3
dispatch turn** — alongside the lens `Agent` blocks (§13.12). Under
`--ensemble` the lens count is 7 (L1–L7 including the ensemble-gated
holistic lens); non-ensemble runs never reach this fragment. This
section is the authoritative spec for the commands themselves; refer
back from step 1.3 to find the command strings.

For each available CLI reviewer, launch in background and capture the
shell id. The diff used is `$comparison_ref..HEAD` (§13.10 — the
freshness-reconciled ref, not the literal `$base_branch` name, so
ensemble reviewers see the same diff surface as the internal lenses
under option (b) `used_remote_ref`).

**CodeRabbit:**

```bash
coderabbit review --agent -t all --base "$comparison_ref" \
  > "$scratch_dir/coderabbit.out" 2> "$scratch_dir/coderabbit.err"
```

(If CodeRabbit rejects a remote-ref `--base` like `origin/main`, fall
back to `base_branch` and record the degradation in `trace.md`. In
practice CodeRabbit accepts any revspec git understands.)

Launch with the Bash tool using `run_in_background: true`. Capture the
returned shell id as `coderabbit_shell_id`. If `coderabbit_available ==
false`, skip this launch.

**Codex:**

The prompt file was already written in 01-detection.md step 1.2a (the
readiness gate). Just invoke the CLI:

```bash
node "$CODEX_COMPANION" task --prompt-file "/tmp/adams-review-codex-$review_id.md" \
  > "$scratch_dir/codex.out" 2> "$scratch_dir/codex.err"
```

Launch with `run_in_background: true`; capture shell id as
`codex_shell_id`. If `codex_available == false`, skip.

### 1.5.3. Collect CLI reviewer outputs

Poll each background shell via the `BashOutput` tool — it's the only
non-blocking read-current-output mechanism granted in
`review.md`'s `allowed-tools` block. Do not wait serially — check
both concurrently so one slow reviewer doesn't hold up the other.

**Note on Codex stream shape.** The Codex CLI writes progress lines to
stderr (captured in `codex.err`); `codex.out` remains empty until the
run completes and the final structured report is flushed. A zero-byte
`codex.out` mid-run is normal, not a failure signal — do not
short-circuit polling based on it.

Apply a reasonable timeout (e.g., 10 minutes — ensemble reviewers can be
slow on large diffs). On timeout, capture whatever output exists, mark the
reviewer as `timed_out`, and continue.

Capture these variables per reviewer as the background shell resolves —
the status computation below reads each one by name, so every branch
must set every variable:

- `coderabbit_exit_code` — integer exit code from the background shell
  (`BashOutput` exposes it when the shell exits); default `0` for the
  skipped branch.
- `coderabbit_timed_out` — `"true"` if the 10-minute deadline elapsed
  before the shell exited, else `"false"`.
- (Same two variables for Codex: `codex_exit_code`, `codex_timed_out`.)

After each reviewer resolves, set the status variable that the Phase-1.5
summary record at step 1.5.7 will reference:

```bash
# After CodeRabbit resolves (success / failure / timeout):
if [[ "$coderabbit_available" == "false" ]]; then
    coderabbit_status=skipped
elif [[ "${coderabbit_timed_out:-false}" == "true" ]]; then
    coderabbit_status=timed_out
elif [[ "${coderabbit_exit_code:-0}" -ne 0 ]] || [[ ! -s "$scratch_dir/coderabbit.out" ]]; then
    coderabbit_status=failed
else
    coderabbit_status=success
fi

# (Same shape for codex_status with $codex_* variables.)
```

On failed / timed_out, log to `trace.md` with tag
`phase_1_5_coderabbit_failed` (or `_codex_failed`); drop that source
from the normalizer input. On success, pass stdout to the normalizer.

Clean up the Codex prompt file:

```bash
rm -f "/tmp/adams-review-codex-$review_id.md"
```

### 1.5.4. PR comment scrape (PR mode only)

Now that the CLI outputs are collected, scrape PR bot comments and
apply the §13.13 code-locality filter. Running the scrape here (rather
than in parallel with the CLI launches at step 1.5.2) gives third-party
PR-comment bots — CodeRabbit-as-GitHub-App, Greptile, etc. — the CLI
minutes they need to land their posts before we fetch.

The scrape (`external-scrape.sh` §21.8) fetches every bot-authored
comment on the PR; the freshness filter (`comment-freshness.sh` §21.10)
drops records whose referenced code has changed between when the
comment was posted and HEAD. Guard the exit-code captures with `||`
so `set -e` orchestrator context doesn't abort on non-zero — we
deliberately want to read the code and continue:

```bash
if [[ "$mode" == "pr" ]]; then
    external-scrape.sh \
        --pr "$pr_number" \
        > "$scratch_dir/pr-scrape.raw.json" \
        2> "$scratch_dir/pr-scrape.err" \
        || scrape_exit=$?
    scrape_exit=${scrape_exit:-0}

    if [[ $scrape_exit -eq 0 ]]; then
        reviewed_files_csv=$(printf '%s\n' "$reviewed_files_all" \
            | awk 'NF' | paste -sd, -)

        # Pipe through comment-freshness.sh. Audit lines (`comment_freshness: …`)
        # flow into trace.md via `tee -a` — mirrors origin-crosscheck.sh
        # dispatch at 01-detection.md step 1.4 step 2a.
        if ! comment-freshness.sh \
                --pr "$pr_number" \
                --reviewed-files "$reviewed_files_csv" \
                --comments "$scratch_dir/pr-scrape.raw.json" \
                > "$scratch_dir/pr-scrape.json" \
                2> >(tee -a "$trace_log_path" >&2); then
            # Freshness helper itself failed (rare — its own errors log to
            # stderr with a `comment_freshness_api_failed` prefix). Degrade
            # gracefully: use the raw scrape. Log the tag so a reader can
            # explain why stale-but-pre-existing comments made it through.
            printf 'phase_1_5_freshness_helper_failed: using raw scrape\n' \
                >> "$trace_log_path"
            cp "$scratch_dir/pr-scrape.raw.json" "$scratch_dir/pr-scrape.json"
        fi
    else
        # Scrape failed — write an empty array so downstream consumers
        # don't trip on a missing file. The scrape-failed tag is logged
        # below.
        echo "[]" > "$scratch_dir/pr-scrape.json"
    fi
else
    echo "[]" > "$scratch_dir/pr-scrape.json"
    scrape_exit=0
fi
```

On scrape non-zero exit (rate limit, auth, network): log stderr to
`trace.md` with tag `phase_1_5_scrape_failed`; continue with
the CLI reviewer outputs only. Do not abort. The freshness-filter
failure path (inner `if`) is separately logged because it can fire
independently of the scrape succeeding.

### 1.5.5. Normalize all external inputs (single Sonnet sub-agent)

Pass the normalizer all three inputs in its prompt. The sub-agent produces
one unified candidate list. This follows §19.2a verbatim.

Dispatch via `Agent` with `model: sonnet`. Prompt essence:

> You are normalizing external-reviewer output into the adamsreview
> candidate schema. You receive three inputs:
>
> **1. PR bot comments** (JSON array; may be empty):
>
> ```
> <contents of $scratch_dir/pr-scrape.json>
> ```
>
> Each entry has `{id, author_login, author_type, created_at, body, kind,
> path?, line?, commit_id?}`.
>
> **2. CodeRabbit stdout** (free-form Markdown text; may be empty):
>
> ```
> <contents of $scratch_dir/coderabbit.out>
> ```
>
> **3. Codex stdout** (free-form Markdown/JSON; may be empty):
>
> ```
> <contents of $scratch_dir/codex.out>
> ```
>
> Extract concrete issues from each. If a single comment or message covers
> multiple distinct issues, emit one candidate per issue. Infer `file` and
> `line_range` from explicit `path`/`line` fields when present, else from
> the body text (e.g. "In `src/foo.ts:45`..."). If neither is available,
> emit the candidate with `file: null` — Phase 2 dedup may still match it
> against internal findings.
>
> Classify `impact_type` conservatively: prefer `correctness` when unclear;
> never reach for `security` without concrete evidence.
>
> Discard comments that are questions, praise, or general commentary — only
> normalize content that identifies an issue in the diff.
>
> Return a JSON array. Each candidate:
>
> ```
> {
>   "file": "src/path/to/file.ts" | null,
>   "line_range": [start, end] | null,
>   "claim": "one-sentence description",
>   "evidence_snippet": "the implicated code or the original comment body",
>   "impact_type": "correctness" | "security" | "ux" | "policy" | "architecture",
>   "origin": "introduced_by_pr" | "pre_existing" | "unknown",
>   "origin_confidence": "low",
>   "source_family": "external-deep-family",
>   "sources": ["external-pr:<author_login>" | "codex" | "coderabbit"]
> }
> ```
>
> `origin_confidence` is ALWAYS `"low"` for external candidates —
> internal corroboration in Phase 4 decides whether they surface.

**After the normalizer returns**, repair missing location info and
emit the result to `external_candidates` for the join step at
01-detection.md step 1.5. Do NOT call `--add-finding` / `--add-findings` here.

**Parse-with-repair front-stop.** Pipe the raw normalizer output
through `parse-with-repair.py` before handing it to `jq`:

```bash
normalizer_clean=$(printf '%s' "$normalizer_output" \
    | parse-with-repair.py \
        2> >(tee -a "$trace_log_path" >&2))

if [[ -z "$normalizer_clean" ]]; then
    # parse-with-repair exited non-zero (already logged via tee above).
    # Drop the external pool to an empty array.
    printf 'phase_1_5_normalizer_unparseable: dropping external candidates\n' \
        >> "$trace_log_path"
    external_candidates="[]"
fi
```

**Schema guard for missing location info.** Schema requires `file`
non-null and `line_range` as `[int,int]` with items `>=1`. Repair the
normalizer's `null` fields before pooling by defaulting to a sentinel:

```bash
if [[ -n "$normalizer_clean" ]]; then
    external_candidates=$(printf '%s' "$normalizer_clean" | jq -c '
      [ .[] | . + {
          file:       (.file // "(unknown)"),
          line_range: (.line_range // [1,1])
        } ]
    ')
fi
```

Leave a one-line `trace.md` note per repaired candidate so the user
knows where the ambiguity came from (iterate with `jq -r` to produce
the notes before the merge).

### 1.5.6. Log normalizer tokens

Log the normalizer's tokens under `phase_1_5`:

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_1_5 \
  --agent-role external_normalizer --agent-id <id> \
  --model sonnet --tokens <N or null>
```

### 1.5.6b. Clean up scratch_dir

```bash
rm -rf -- "$scratch_dir"
```

Any orchestrator-fatal failure before this point leaves the scratch
dir for post-mortem inspection.

### 1.5.7. Log Phase 1.5 summary

```bash
phase_1_5_elapsed=$(( $(date +%s) - phase_1_5_start_epoch ))

log-phase.sh \
  --review-dir "$review_dir" --phase 1_5 --name ensemble-adapter \
  --elapsed "$phase_1_5_elapsed" \
  --summary "coderabbit=$coderabbit_status; codex=$codex_status; scrape_bots=$scrape_bot_count; normalized=$external_candidate_count"

log-phase.sh \
  --review-dir "$review_dir" --phase 1_5 --record "$(jq -nc \
    --arg name ensemble-adapter \
    --argjson elapsed "$phase_1_5_elapsed" \
    --argjson added "$external_candidate_count" \
    '{name:$name, elapsed_sec:$elapsed, counts_by_state:{open:$added}, counts_by_disposition:{pending_validation:$added}, delta:"+\($added) external"}')"
```

Where `coderabbit_status` is one of `success|failed|skipped|timed_out`
(same for `codex_status`).
