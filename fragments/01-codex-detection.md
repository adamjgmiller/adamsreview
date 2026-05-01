## Phase 1 — Codex detection (codex-review)

Capture `phase_1_start_epoch=$(date +%s)` as the FIRST action of this
phase (step 1.6 logs the elapsed time). Initialize the tracking
variables Phase 1's summary will reference:

- `lenses_run=""` — comma-separated list of lens IDs that successfully
  produced output (filled in across §1.4).
- `lenses_dropped=""` — comma-separated list of lenses that hit the
  unrecoverable retry path.
- `candidate_count=0` — total candidates the normalizer emitted, set
  after §1.5.2's batched `--add-findings` returns.

This fragment is the codex-review counterpart to `fragments/01-detection.md`.
Where the canonical fragment dispatches 6–7 Claude `Agent` blocks (one per
lens), this fragment dispatches 7 parallel **Codex jobs** via the
`codex-companion.mjs` plugin's `task --background` primitive — captures
each `job_id`, polls to terminal, fetches the freeform output, and feeds
all 7 outputs into one **Sonnet normalizer** that emits the standard
candidate JSON shape.

Phases 0, 2, 3, and 6 are unchanged — codex-review reuses
`fragments/00-preflight.md`, `fragments/03-dedup.md`,
`fragments/04-scoring-gate.md`, `fragments/07-finalize.md` verbatim.
Phases 4 and 5 are also Codex-driven; see
`fragments/05-codex-validation.md` and
`fragments/06-codex-cross-cutting.md`.

### 1.1. Decide which lenses run

Based on the Phase 0 working-context values, build the lens dispatch
list. Codex-review always runs L7 (the holistic safety net) when not
in trivial mode — no `--ensemble` gate, since codex-review IS the
high-thoroughness path.

| Lens | Effort | Runs when |
|---|---|---|
| L1 — diff-local scan | `$effort` | always |
| L2 — structural / blast-radius | `$effort` | `trivial_mode != true` |
| L3 — CLAUDE.md compliance | `$effort` | always |
| L4 — comment compliance | `$effort` | always |
| L5 — UX | `$effort` | `user_facing == true AND trivial_mode != true` |
| L6 — lightweight security | `$effort` | `trivial_mode != true` |
| L7 — holistic review | `$effort` | `trivial_mode != true` |

`$effort` is the working-context value captured from `--effort`
(default `high`).

Skipped lenses get a one-line note in `trace.md`:

```
Phase 1 codex: L7 skipped (trivial_mode=true)
Phase 1 codex: L2/L5/L6/L7 skipped (trivial_mode=true)
```

Log them via `log-phase.sh --summary` at step 1.6 as part of the Phase 1
summary.

### 1.2. Build the shared input

Compute the diff scope once against `$comparison_ref` (per Phase 0 step
0.2a / §13.10):

```bash
git diff "$comparison_ref..HEAD"
```

Codex jobs have filesystem access via codex-companion's `task` mode
and run `git diff` themselves — the prompt body in
`fragments/lens-prompts/L<N>.md` instructs them to read the diff
between `$comparison_ref` and HEAD. The orchestrator does NOT pre-compute
the diff and embed it; Codex's working directory is the repo root and
the diff range is in the prompt's shared invariants (§1.2.1 below).

`$claude_md_paths` (the list captured in Phase 0 step 0.7) is required
for L3, L4, L5 prompts. The orchestrator substitutes the value into
the prompt body at `--prompt-file` write time.

### 1.2.1. Shared lens-prompt invariants

Every Codex job in step 1.3 receives the contents of
`fragments/lens-prompts/_shared-invariants.md` prepended to the
lens-specific prompt body. This is the same shared block consumed by
`fragments/01-detection.md` §1.2.1 — single source of truth for
candidate-shape requirements (`line_range` rules, origin defaults,
JSON schema).

### 1.2b. Prior-fix suspect scan (§13.11b)

Same deterministic helper as `fragments/01-detection.md` step 1.2b.
The output feeds L2's prompt so L2 can judge prior-fix reversion.

Skipped when `$trivial_mode` is true (L2 is skipped too):

```bash
if [[ "$trivial_mode" != "true" ]]; then
    reviewed_files_csv=$(printf '%s\n' "$reviewed_files_all" \
      | awk 'NF' | paste -sd, -)

    prior_fix_suspects=$(
        prior-fix-diff.sh \
          --comparison-ref "$comparison_ref" \
          --reviewed-files "$reviewed_files_csv" \
          2> >(tee -a "$trace_log_path" >&2)
    ) || prior_fix_suspects="[]"
else
    prior_fix_suspects="[]"
fi
```

On helper non-zero exit, fall back to `[]`.

### 1.2c. Build the Codex prompt files

For each lens that runs (per step 1.1's selection), the orchestrator
assembles a prompt file at `/tmp/adams-review-codex-<review_id>-L<N>.md`.
Codex's `task --background --prompt-file <path>` reads the file at
launch time, so it must be on disk before §1.3.

The lens-prompt source files (`fragments/lens-prompts/L<N>.md`,
`fragments/lens-prompts/_shared-invariants.md`) live in the plugin's
install directory — NOT in the reviewed repository. Use the **Read
tool** to load them (it resolves plugin-relative paths the same way
`Read fragments/01-codex-detection.md` resolved this fragment when the
top-level command kicked it off). Do NOT use bash `cat` with a
relative path — bash's cwd is the reviewed repo, so a relative path
points at the wrong tree, and there's no canonical `$PLUGIN_ROOT`
shell variable.

Per lens that runs, the orchestrator does:

1. **Read** `fragments/lens-prompts/_shared-invariants.md` once and
   capture its content as `shared_invariants_body`.
2. **Read** `fragments/lens-prompts/L<N>.md` and capture as
   `lens_body_L<N>`.
3. **Substitute placeholders** in both `shared_invariants_body` and
   `lens_body_L<N>` against working-context values from Phase 0 + 1.2b.
   Substitution is literal pattern replacement (no regex; no `&`
   escape semantics).

   In `shared_invariants_body`:

   - `$comparison_ref` → working-context `comparison_ref` (Phase 0 step 0.2a).
   - `$reviewed_sha` → working-context `reviewed_sha` (Phase 0 step 0.10).

   In `lens_body_L<N>`:

   - **L2 only**: `$prior_fix_suspects` → JSON array from step 1.2b.
   - **L3, L5 only**: `$claude_md_paths` → newline-joined list from
     Phase 0 step 0.7.
   - L1, L4, L6, L7: no per-lens placeholders.

   The orchestrator can perform these substitutions in-context (string
   replace) before writing — no shell needed. If you DO want a shell
   one-liner, bash literal substitution is safe (immune to `&` /
   backreferences, unlike `awk gsub` / `sed`):

   ```bash
   shared_invariants_body="${shared_invariants_body//\$comparison_ref/$comparison_ref}"
   shared_invariants_body="${shared_invariants_body//\$reviewed_sha/$reviewed_sha}"
   lens_body="${lens_body//\$prior_fix_suspects/$prior_fix_suspects}"  # L2
   lens_body="${lens_body//\$claude_md_paths/$claude_md_paths}"        # L3, L5
   ```

   The `\$` in the search pattern escapes bash's own `$` expansion —
   the placeholder in the file is the literal four characters `$comparison_ref`.

4. **Write** the assembled prompt to
   `/tmp/adams-review-codex-${review_id}-L<N>.md`. Use the Write tool
   (orchestrator-side) with the assembled string as `<shared invariants>\n\n<substituted lens body>`,
   OR use the bash heredoc / printf pattern below:

   ```bash
   prompt_file="/tmp/adams-review-codex-${review_id}-L${N}.md"
   { printf '%s\n\n' "$shared_invariants_body"; \
     printf '%s\n'   "$lens_body"; } > "$prompt_file"
   ```

   The Write-tool path is preferable — keeps the orchestrator's
   working-context strings out of bash variable space (no quoting
   surprises with embedded backslashes, dollar signs, backticks).

### 1.3. Dispatch the Codex jobs (one orchestrator turn)

Launch each running lens's Codex job in a SINGLE orchestrator turn so
they run concurrently. Each launch is a Bash tool-use:

```bash
node "$CODEX_COMPANION" task --background --effort "$effort" \
    --prompt-file "/tmp/adams-review-codex-${review_id}-L${N}.md" \
    --json
```

The companion returns a JSON line on stdout containing the `job_id`
(and other metadata). Capture the job_id into a working-context map
keyed by lens slot:

```
codex_job_ids = {
  "L1": "job_<id>",
  "L2": "job_<id>",
  ...
}
```

Skipped lenses are absent from the map. Lenses that fail the launch
itself (codex-companion exit != 0) are logged to `trace.md` with tag
`phase_1_codex_launch_failed:L<N>` and dropped from the map; they
proceed to the §1.4 retry-or-escalate path with a synthetic "launch
failed" status.

**Tracking**: every lens that successfully receives a `job_id` joins
the `codex_job_ids` map; this is the working-context source of truth
for what's in flight. The §1.6 summary's `lenses_run` and
`lenses_dropped` lists are filled in across §1.4 as jobs resolve.

### 1.4. Poll the Codex jobs (subsequent orchestrator turns)

For each `job_id` in the map, poll via:

```bash
node "$CODEX_COMPANION" status "$job_id" --json | jq -r '.state'
```

Terminal states: `completed`, `failed`, `cancelled`. Non-terminal:
`pending`, `running`. Poll all jobs in one orchestrator turn (multiple
Bash blocks, each polling a different job) until all are terminal.

A reasonable polling cadence is one full sweep per orchestrator turn
with no explicit sleep between turns — Claude Code's turn cadence
provides natural pacing. If a job stays in `running` for an
unreasonably long time (>15 minutes), treat it as a soft-timeout
candidate for the retry-or-escalate path.

When a job reaches a terminal state, fetch its output:

```bash
node "$CODEX_COMPANION" result "$job_id" --json > "/tmp/adams-review-codex-${review_id}-L${N}.out.json"
```

The `.output` field of the result is the freeform Codex stdout (the
review text). Capture it as `codex_output_L<N>`.

#### Retry-with-orchestrator-judgment (per plan §3.7)

For each job, when the terminal state is `failed` / `cancelled`, OR
when `state == completed` but the output looks malformed (empty,
clearly truncated, doesn't resemble candidate-list output even loosely),
the orchestrator inspects the failure context and decides:

1. **Likely transient** (rate limit, transient API error, single-output
   JSON glitch, sentinel mismatch): retry up to **3 times** with the
   same prompt file. Re-launch via `task --background --effort
   "$effort" --prompt-file "$prompt_file"`, capture the new job_id, poll
   again.
2. **Persistent or fundamental** (3 retries with the same failure mode,
   or a clear structural error like "prompt file unreadable"): treat as
   unrecoverable. Log to `trace.md` with tag `phase_1_codex_dropped:L<N>
   reason=<short cause>`.

When any lens is dropped, dispatch `AskUserQuestion` ONCE for the whole
phase (don't ask per-lens — that's ~7 prompts):

```
"<N> Codex lenses failed after retry: [L<N>, L<M>, ...]. Continue
with the remaining lenses (degraded coverage), or abort the run?"
Options:
- Continue — proceed to Phase 2 with surviving lenses
- Abort — exit cleanly; preserve the seeded artifact for inspection
```

If 0 lenses survive, abort automatically (no point asking). On Continue,
log `phase_1_codex_user_continued: surviving=L1,L3,L4` and proceed.

**Tracking finalize (end of §1.4)**: after all jobs have either
resolved successfully or been dropped, set:

- `lenses_run` = comma-separated lens IDs whose Codex output was
  successfully fetched (e.g. `L1,L3,L4,L5,L6,L7`).
- `lenses_dropped` = comma-separated lens IDs that hit the unrecoverable
  retry path (e.g. `L2`). Empty string if none.

These feed §1.6's summary line.

### 1.5. Normalize Codex outputs (single Sonnet sub-agent)

Once all Codex jobs are terminal (and any drops handled), dispatch ONE
Sonnet `Agent` to consolidate the outputs into the standard candidate
schema. Mirrors the Phase 1.5 ensemble adapter pattern at
`fragments/02-ensemble-adapter.md` §1.5.5.

Concatenate all surviving lens outputs with lens-id headers:

```
=== L1 (diff-local) ===
<contents of codex_output_L1>

=== L2 (structural) ===
<contents of codex_output_L2>

...
```

Dispatch via `Agent` with `model: sonnet`, `subagent_type: general-purpose`.
Prompt essence:

> You are normalizing 7 (or fewer if any were skipped/dropped) Codex
> lens outputs into the adamsreview candidate schema. Each output is
> freeform Markdown/text describing findings; your job is to extract
> concrete candidates and tag them with the lens that produced them.
>
> Inputs (concatenated with `=== L<N> (<name>) ===` headers):
>
> ```
> <concatenated codex outputs>
> ```
>
> Per-lens routing:
> - L1 → `source_family: "diff-family"`, `impact_type: "correctness"` (default).
> - L2 → `source_family: "structural-family"`, `impact_type: "correctness"`.
> - L3 → `source_family: "policy-family"`. `impact_type` per L3's rule
>   (correctness if rule is runtime-impactful, else policy).
> - L4 → `source_family: "policy-family"`. `impact_type` per L4's rule.
> - L5 → `source_family: "ux-family"`, `impact_type: "ux"`.
> - L6 → `source_family: "security-family"`, `impact_type: "security"`.
> - L7 → `source_family: "holistic-family"`, `impact_type` is whatever
>   the L7 finding's nature is (any of correctness | security | ux |
>   policy | architecture).
>
> Extract concrete issues from each lens. If a single output covers
> multiple distinct issues, emit one candidate per issue. Infer `file`
> and `line_range` from explicit citations (e.g. "In `src/foo.ts:45`...");
> if neither is available, emit the candidate with `file: null` and
> `line_range: null` — Phase 2 dedup may still match it against another
> lens's finding.
>
> Discard meta-commentary: praise, summary statements, "no issues
> found in <area>" notes — only normalize content that identifies a
> specific issue.
>
> Return a JSON array. Each candidate:
>
> ```
> {
>   "file": "src/path/to/file.ts" | null,
>   "line_range": [start, end] | null,
>   "claim": "one-sentence description",
>   "evidence_snippet": "the implicated code or quoted lens output",
>   "impact_type": "correctness" | "security" | "ux" | "policy" | "architecture",
>   "origin": "introduced_by_pr" | "pre_existing" | "unknown",
>   "origin_confidence": "high" | "medium" | "low",
>   "source_family": "<per the routing table above>",
>   "sources": ["L<N>-<lens-name>"]
> }
> ```
>
> Use the lens IDs `L1-diff-local`, `L2-structural`, `L3-claude-md`,
> `L4-comments`, `L5-ux`, `L6-security`, `L7-holistic` for the
> `sources[]` entry. Default `origin: "introduced_by_pr"`,
> `origin_confidence: "high"` (Phase-3 / Phase-4 will adjust based on
> blame analysis). Lens output that explicitly identifies pre-existing
> behavior should set `origin: "pre_existing"` per the rule embedded in
> the shared invariants (each Codex job already received them).

Capture the normalizer's raw output as `normalizer_output`. Log tokens:

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_1 \
  --agent-role codex_normalizer --agent-id <id> \
  --model sonnet --tokens <N or null>
```

### 1.5.1. Parse + repair + schema-guard

Pipe `$normalizer_output` through `parse-with-repair.py`, then type-guard
before iterating:

```bash
normalizer_clean=$(printf '%s' "$normalizer_output" \
    | parse-with-repair.py 2> >(tee -a "$trace_log_path" >&2))

if [[ -z "$normalizer_clean" ]]; then
    printf 'phase_1_codex_normalizer_unparseable: dropping all internal candidates\n' \
        >> "$trace_log_path"
    internal_candidates="[]"
else
    # Type-guard the normalizer output. Sonnet sometimes wraps the
    # array in `{"findings": [...]}` or `{"candidates": [...]}`; pluck
    # those before iterating. If the result is still not an array,
    # treat as unparseable rather than letting jq's `[ .[] | ... ]`
    # crash the phase.
    normalizer_array=$(printf '%s' "$normalizer_clean" | jq -c '
      if type == "array" then .
      elif type == "object" and (.findings | type == "array") then .findings
      elif type == "object" and (.candidates | type == "array") then .candidates
      else null end
    ')
    if [[ "$normalizer_array" == "null" ]] || [[ -z "$normalizer_array" ]]; then
        printf 'phase_1_codex_normalizer_not_array: normalizer returned non-array (no .findings/.candidates pluck possible); dropping internal candidates\n' \
            >> "$trace_log_path"
        internal_candidates="[]"
    else
        # Schema-guard repair for missing location info — schema requires
        # file non-null and line_range as [int,int] with items >= 1.
        internal_candidates=$(printf '%s' "$normalizer_array" | jq -c '
          [ .[] | . + {
              file:       (.file // "(unknown)"),
              line_range: (.line_range // [1,1])
            } ]
        ')
    fi
fi
```

Log a one-line `trace.md` note per repaired candidate (file/line_range
sentinel applied) so the user knows where the ambiguity came from.

### 1.5.2. Join + assign IDs + post-processing + batched add-findings

Same shape (and same ordering — IDs are assigned AFTER bad candidates
are dropped, so no ID gaps remain in the artifact) as
`fragments/01-detection.md` §1.5 join step:

1. Pass `$internal_candidates` through `line-range-check.sh` to drop
   any line-range hallucinations exceeding the file at `$reviewed_sha`,
   and any candidates citing files missing in the reviewed tree. Done
   FIRST so dropped candidates don't consume monotonic IDs.
2. Pass through `assign-finding-ids.sh` to assign monotonic `F0NN`
   IDs to the surviving candidates.
3. Pass through `origin-crosscheck.sh` to blame-correct each
   candidate's `origin` / `origin_confidence` per §13.11.
4. Commit via one batched `artifact-patch.py --add-findings <array>`
   call (atomic write across the whole accepted batch).

Refer to `fragments/01-detection.md` §1.5 for the exact jq/source-family
canonicalization scaffolding — codex-review uses the same helpers and
the same join step. The only difference is the candidate origin: instead
of being pooled from per-lens `Agent` outputs, they come from the
single combined Sonnet normalizer above. The post-processing chain is
identical.

**Capture `candidate_count`** after `--add-findings` returns so §1.6's
log line and `phases.jsonl` record have the right number:

```bash
candidate_count=$(artifact-read.sh \
  --path "$artifact_path" \
  --filter '.findings | length')
```

(Reads the post-`--add-findings` count rather than the pre-batched
candidate count, so rejected entries — preflight drops, dedup
collisions — are excluded.)

### 1.5.3. Clean up Codex prompt files

```bash
rm -f "/tmp/adams-review-codex-${review_id}-L"*.md \
      "/tmp/adams-review-codex-${review_id}-L"*.out.json
```

Any orchestrator-fatal failure before this point leaves the prompt
files in /tmp for post-mortem inspection — the §1.4 retry-with-judgment
path drops affected lenses cleanly so this cleanup runs on success.

### 1.6. Log Phase 1 summary

```bash
phase_1_elapsed=$(( $(date +%s) - phase_1_start_epoch ))

log-phase.sh \
  --review-dir "$review_dir" --phase 1 --name codex-detection \
  --elapsed "$phase_1_elapsed" \
  --summary "lenses_run=$lenses_run; lenses_dropped=$lenses_dropped; candidates=$candidate_count"

log-phase.sh \
  --review-dir "$review_dir" --phase 1 --record "$(jq -nc \
    --arg name codex-detection \
    --argjson elapsed "$phase_1_elapsed" \
    --argjson added "$candidate_count" \
    '{name:$name, elapsed_sec:$elapsed, counts_by_state:{open:$added}, counts_by_disposition:{pending_validation:$added}, delta:"+\($added) codex"}')"
```

`$lenses_run` is the comma-separated list of surviving lens IDs (e.g.
`L1,L2,L3,L4,L5,L6,L7` for a full review, `L1,L3,L4` for trivial mode).
`$lenses_dropped` is the comma-separated list of lenses that hit the
unrecoverable retry path (empty string when none).
