## Phase 1 — Codex detection (codex-review)

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

For each lens that runs (per step 1.1's selection), construct a prompt
file at `/tmp/adams-review-codex-<review_id>-L<N>.md`:

```bash
shared_invariants=$(cat "$REPO_ROOT/fragments/lens-prompts/_shared-invariants.md")
lens_body=$(cat "$REPO_ROOT/fragments/lens-prompts/L<N>.md")
```

(`$REPO_ROOT` is the plugin's worktree root, captured in Phase 0 / from
`repo-slug.sh`'s sister logic; the orchestrator knows its install path.)

Substitute placeholders in `$lens_body`. Use bash's literal pattern
substitution `${var//pattern/replacement}` — it does NOT interpret
special characters in the replacement (unlike `awk gsub` or `sed`,
which both have escape rules for `&` / `\1` / etc., dangerous when
the replacement contains commit subjects or arbitrary JSON):

- **L2**: replace `$prior_fix_suspects` literal with the JSON array
  from step 1.2b:

  ```bash
  lens_body="${lens_body//\$prior_fix_suspects/$prior_fix_suspects}"
  ```

- **L3** and **L5**: replace `$claude_md_paths` literal with the
  newline-joined list from Phase 0 step 0.7:

  ```bash
  lens_body="${lens_body//\$claude_md_paths/$claude_md_paths}"
  ```

- **L1, L4, L6, L7**: no placeholders to substitute.

Note: the `\$` in the search pattern escapes bash's own `$` expansion
(we want a literal dollar in the matched string, since the placeholder
in the file is `$prior_fix_suspects` literally). The replacement side
is literal — bash doesn't interpret `&` or backreferences there.

Concatenate `<shared invariants>\n\n<substituted lens body>` and write to
the per-lens prompt file:

```bash
prompt_file="/tmp/adams-review-codex-${review_id}-L${N}.md"
{ printf '%s\n\n' "$shared_invariants"; printf '%s\n' "$lens_body"; } > "$prompt_file"
```

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

Pipe `$normalizer_output` through `parse-with-repair.py`:

```bash
normalizer_clean=$(printf '%s' "$normalizer_output" \
    | parse-with-repair.py 2> >(tee -a "$trace_log_path" >&2))

if [[ -z "$normalizer_clean" ]]; then
    printf 'phase_1_codex_normalizer_unparseable: dropping all internal candidates\n' \
        >> "$trace_log_path"
    internal_candidates="[]"
else
    # Schema-guard repair for missing location info — schema requires
    # file non-null and line_range as [int,int] with items >= 1.
    internal_candidates=$(printf '%s' "$normalizer_clean" | jq -c '
      [ .[] | . + {
          file:       (.file // "(unknown)"),
          line_range: (.line_range // [1,1])
        } ]
    ')
fi
```

Log a one-line `trace.md` note per repaired candidate (file/line_range
sentinel applied) so the user knows where the ambiguity came from.

### 1.5.2. Join + assign IDs + post-processing + batched add-findings

Same shape as `fragments/01-detection.md` §1.5 join step:

1. Pass `$internal_candidates` through `assign-finding-ids.sh` to assign
   monotonic `F0NN` IDs.
2. Pass through `origin-crosscheck.sh` to blame-correct each candidate's
   `origin` / `origin_confidence` per §13.11.
3. Pass through `line-range-check.sh` to drop any line-range
   hallucinations exceeding the file at `$reviewed_sha`.
4. Commit via one batched `artifact-patch.py --add-findings <array>`
   call (atomic write across the whole accepted batch).

Refer to `fragments/01-detection.md` §1.5 for the exact jq/source-family
canonicalization scaffolding — codex-review uses the same helpers and
the same join step. The only difference is the candidate origin: instead
of being pooled from per-lens `Agent` outputs, they come from the
single combined Sonnet normalizer above. The post-processing chain is
identical.

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
