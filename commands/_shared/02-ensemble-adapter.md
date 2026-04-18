## Phase 1.5 — Ensemble adapter (conditional on `--ensemble`)

**Skip this entire phase** unless `ensemble_mode == true` (captured in Phase 0
step 0.1). Log one line to `trace.md` and proceed to Phase 2:

```
Phase 1.5 skipped — --ensemble not set
```

When `--ensemble` IS set, Phase 1.5 pulls additional candidates from three
external channels:

1. **CodeRabbit CLI** — `coderabbit review --agent -t all --base <base>`, a
   local Claude-like review that emits findings to stdout (does not post to
   the PR). Runs in background; result awaited at the end of this phase.
2. **Codex CLI** — `node "$CODEX_COMPANION" task --prompt-file <file>`, a
   local Codex-based review. Same shape.
3. **GitHub PR comment scrape** — `external-scrape.sh` pulls bot-authored
   comments posted to the PR since `review_started_at`. Only runs when
   `mode == pr`. Local mode can't scrape a PR that doesn't exist.

All three feed a single Sonnet normalizer sub-agent that emits standard
candidates. The orchestrator appends them to `artifact.findings[]` with
`source_family: "external-deep-family"` and `origin_confidence: "low"`.

**Token accounting.** The CodeRabbit and Codex CLIs are EXTERNAL processes —
their token spend is billed separately by their respective providers and is
NOT logged to `tokens.jsonl` (clarification vs DESIGN §11's "wrapper
orchestration tokens tracked" language — with CLI dispatch there is no
Claude wrapper sub-agent to track). Only the Sonnet normalizer is logged,
under `phase_1_5`.

### 1.5.1. Readiness check (up-front, before any launch)

Capture `phase_1_5_start_epoch=$(date +%s)`. Create a scratch directory
under `/tmp` for transient CLI outputs — DESIGN §9.3 keeps
`$review_dir` clean of ephemeral noise:

```bash
scratch_dir="/tmp/adams-review-$review_id"
mkdir -p "$scratch_dir"
```

(Cleanup happens at the end of Phase 1.5, step 1.5.5. The review-
persistent copies of anything worth keeping — only the normalized
candidate set — lands in the artifact via `--add-finding` at 1.5.6.)

Check CodeRabbit availability:

```bash
coderabbit --version 2>&1 && coderabbit auth status 2>&1 | head -3
```

If either returns non-zero, record `coderabbit_available=false` with the
specific failure reason (e.g., "not installed", "not authenticated —
run `coderabbit auth login`"). Otherwise `coderabbit_available=true`.

Check Codex availability:

```bash
CODEX_COMPANION="$(find ~/.claude/plugins -type f -name codex-companion.mjs -path '*codex*' 2>/dev/null | head -1)"
if [[ -z "$CODEX_COMPANION" ]]; then
    codex_available=false
    codex_reason="companion script not found — run /codex:setup"
else
    if node "$CODEX_COMPANION" ready 2>&1 | grep -q ready; then
        codex_available=true
    else
        codex_available=false
        codex_reason="ready check failed — run /codex:setup to diagnose"
    fi
fi
```

If **both** are available, proceed silently. If **either** is unavailable,
use `AskUserQuestion` **once** with two options:

- **Proceed with what's available** — continue with the available reviewer(s)
  plus the PR scrape. Note skipped reviewers in the final report's source
  breakdown and in `trace.md`.
- **Stop so I can set them up first** — exit the command. Print the exact
  remediation commands and let the user fix first.

### 1.5.2. Launch CLI reviewers (background Bash)

For each available CLI reviewer, launch in background and capture the shell
id. The diff used is `$base_branch..HEAD`.

**CodeRabbit:**

```bash
coderabbit review --agent -t all --base "$base_branch" \
  > "$scratch_dir/coderabbit.out" 2> "$scratch_dir/coderabbit.err"
```

Launch with the Bash tool using `run_in_background: true`. Capture the
returned shell id as `coderabbit_shell_id`. If `coderabbit_available == false`,
skip this launch.

**Codex:**

Write a brief prompt file first:

```bash
cat > "/tmp/adams-review-codex-$review_id.md" <<'PROMPT'
Review the code changes in this repository between <base-branch> and HEAD.
Focus on potential bugs, correctness issues, security concerns, and violations
of project conventions. Return a structured list of findings with file, line
range, and concrete description for each.
PROMPT
# (substitute $base_branch into the actual prompt text)
```

Then launch:

```bash
node "$CODEX_COMPANION" task --prompt-file "/tmp/adams-review-codex-$review_id.md" \
  > "$scratch_dir/codex.out" 2> "$scratch_dir/codex.err"
```

Launch with `run_in_background: true`; capture shell id as `codex_shell_id`.
If `codex_available == false`, skip.

### 1.5.3. PR comment scrape (PR mode only)

While the CLI reviewers are running, synchronously scrape bot comments.
Guard the exit-code capture with `||` so `set -e` orchestrator context
doesn't abort on non-zero — we deliberately want to read the code and
continue per §24.2:

```bash
if [[ "$mode" == "pr" ]]; then
    ~/.claude/commands/_shared/tools/external-scrape.sh \
        --pr "$pr_number" --since "$review_started_at" \
        > "$scratch_dir/pr-scrape.json" \
        2> "$scratch_dir/pr-scrape.err" \
        || scrape_exit=$?
    scrape_exit=${scrape_exit:-0}
else
    echo "[]" > "$scratch_dir/pr-scrape.json"
    scrape_exit=0
fi
```

On non-zero exit (rate limit, auth, network) per §24.2: log stderr to
`trace.md` with tag `phase_1_5_scrape_failed`; continue with the CLI
reviewer outputs only. Do not abort.

### 1.5.4. Collect CLI reviewer outputs

Poll each background shell via the `BashOutput` tool — it's the only
non-blocking read-current-output mechanism granted in
`adams-review.md`'s `allowed-tools` block. Do not wait serially — check
both concurrently so one slow reviewer doesn't hold up the other.

Apply a reasonable timeout (e.g., 10 minutes — ensemble reviewers can be
slow on large diffs). On timeout, capture whatever output exists, mark the
reviewer as `timed_out`, and continue.

After each reviewer returns, capture its status explicitly — the Phase-
1.5 summary record at step 1.5.7 references these variables by name:

```bash
# After CodeRabbit resolves (success / failure / timeout):
if [[ "$coderabbit_available" == "false" ]]; then
    coderabbit_status=skipped
elif [[ "$coderabbit_timed_out" == "true" ]]; then
    coderabbit_status=timed_out
elif [[ "$coderabbit_exit_code" -ne 0 ]] || [[ ! -s "$scratch_dir/coderabbit.out" ]]; then
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

### 1.5.5. Normalize all external inputs (single Sonnet sub-agent)

Pass the normalizer all three inputs in its prompt. The sub-agent produces
one unified candidate list. This follows §19.2a verbatim.

Dispatch via `Agent` with `model: sonnet`. Prompt essence:

> You are normalizing external-reviewer output into the adams-review
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

### 1.5.6. Append external candidates + log tokens

Log the normalizer's tokens under `phase_1_5`:

```bash
~/.claude/commands/_shared/tools/log-tokens.sh \
  --review-dir "$review_dir" --phase phase_1_5 \
  --agent-role external_normalizer --agent-id <id> \
  --model sonnet --tokens <N or null>
```

For each normalized candidate, call `artifact-patch.py --add-finding` with
the same field defaults as Phase 1.4 step 3 — monotonically continuing the
finding-id sequence (if Phase 1 produced F001-F030, external starts at F031).
`origin_confidence` stays `"low"` per the normalizer's output.

**Schema guard for missing location info.** The normalizer prompt
allows `file: null` / `line_range: null` for candidates whose body text
didn't specify a location. Schema (`schema-v1.json`) requires `file`
non-null with `minLength:1` and `line_range` as `[int,int]` with both
items `>=1`. Repair before `--add-finding` — default to a sentinel so
the finding is still stored (Phase 2 dedup + Phase 4 validation may
still match it against an internal finding with proper location):

```bash
# Before --add-finding, if candidate.file is null: set to "(unknown)"
# and line_range to [1,1]. Leave a one-line trace.md note per finding
# so the user knows where the ambiguity came from.
file=$(echo "$candidate" | jq -r '.file // "(unknown)"')
line_range_json=$(echo "$candidate" | jq -c '(.line_range // [1,1])')
# Merge back into the candidate before building the full finding.
```

### 1.5.6b. Clean up scratch_dir

```bash
rm -rf -- "$scratch_dir"
```

Keep `$review_dir` free of transient CLI output (§9.3). Any
orchestrator-fatal failure before this point leaves the scratch dir
for post-mortem inspection.

### 1.5.7. Log Phase 1.5 summary

```bash
phase_1_5_elapsed=$(( $(date +%s) - phase_1_5_start_epoch ))

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 1_5 --name ensemble-adapter \
  --elapsed "$phase_1_5_elapsed" \
  --summary "coderabbit=$coderabbit_status; codex=$codex_status; scrape_bots=$scrape_bot_count; normalized=$external_candidate_count"

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 1_5 --record "$(jq -nc \
    --arg name ensemble-adapter \
    --argjson elapsed "$phase_1_5_elapsed" \
    --argjson added "$external_candidate_count" \
    '{name:$name, elapsed_sec:$elapsed, counts_by_state:{open:$added}, counts_by_disposition:{unassigned:$added}, delta:"+\($added) external"}')"
```

Where `coderabbit_status` is one of `success|failed|skipped|timed_out`
(same for `codex_status`).

### Working-set delta after Phase 1.5

- `artifact.findings[]` grew by the external candidates.
- `tokens.jsonl` grew one entry for the normalizer (not for the CLI
  reviewers — those are external processes).
- `phases.jsonl` grew a Phase 1.5 record.
- `trace.md` grew a Phase 1.5 section.
