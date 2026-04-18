## Phase 1 — Detection

Six internal lenses run in parallel to produce candidate findings. Each lens
returns a list of candidates tagged with routing fields (`impact_type`,
`origin`, `origin_confidence`, `source_family`). The orchestrator merges
all lens outputs into `artifact.findings[]` as one call per candidate to
`artifact-patch.py --add-finding`.

**Dispatch parallelism.** To get actual wall-clock parallelism across lenses,
send every applicable lens's `Agent` tool-use block inside a single
orchestrator turn. Claude Code then runs them concurrently. Collecting the
results happens on the next turn.

### 1.1. Decide which lenses run

Based on the Phase 0 variables:

| Lens | Model | Runs when |
|---|---|---|
| L1 — diff-local scan | `haiku` | always |
| L2 — structural / blast-radius | `opus` | `trivial_mode != true` |
| L3 — CLAUDE.md compliance | `sonnet` | always |
| L4 — comment compliance | `sonnet` | always |
| L5 — UX | `sonnet` | `user_facing == true AND trivial_mode != true` |
| L6 — lightweight security | `sonnet` | `trivial_mode != true` |

Skipped lenses get a one-line note in `trace.md`:
```
Phase 1: L2/L5/L6 skipped (trivial_mode=true)
```

Log them via `log-phase.sh --summary` at step 1.4 as part of the Phase 1
summary.

### 1.2. Build the shared input

Compute the diff once against `$comparison_ref` (not `$base_branch`; see
Phase 0 step 0.2a / §13.10 — when the user chose "compare against
`origin/$base_branch`", `comparison_ref` points at the remote ref while
`base_branch` stays the human name):

```bash
git diff "$comparison_ref..HEAD"
```

All lenses see this full diff. L1, L3, L4, L5, L6 operate primarily on the
diff; L2 additionally reads surrounding files.

For lenses that receive CLAUDE.md content (L3, L4, L5, L6), pass
`claude_md_paths` (the list captured in Phase 0, step 0.7). Each lens
reads only what it needs.

### 1.3. Dispatch the lenses (one turn, one Agent call per applicable lens)

#### L1 — diff-local scan (Haiku)

Launch one `Agent` tool-use with `model: haiku`, `subagent_type: general-purpose`.
Prompt essence:

> Read ONLY the diff between `$comparison_ref` and HEAD. Do not open other
> files or grep the repo. Flag off-by-one errors, inverted conditions, typos
> in identifiers, dead branches, obvious null-deref patterns, and
> mismatched quotes or parens. **Over-flag — Phase 3 will filter.** Ignore
> style issues; ignore anything a linter would catch.
>
> Return a JSON array of candidates. Each candidate:
> ```
> {
>   "file": "src/path/to/file.ts",
>   "line_range": [start, end],
>   "claim": "one-sentence description of the issue",
>   "evidence_snippet": "the exact code lines implicated",
>   "impact_type": "correctness",
>   "origin": "introduced_by_pr" | "pre_existing" | "unknown",
>   "origin_confidence": "high" | "medium" | "low",
>   "source_family": "diff-family"
> }
> ```
>
> Default `origin: "introduced_by_pr"`, `origin_confidence: "high"` unless
> the implicated code is clearly unchanged by this diff.

#### L2 — structural / blast-radius (Opus; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: opus`, `subagent_type: general-purpose`,
with `Read` and `Bash(git:*)` + `Bash(grep:*)` permissions (the sub-agent
inherits the parent command's grants — this already covers it).

Prompt essence:

> For every function, type, field, or API the diff between `$comparison_ref`
> and HEAD changes, **trace into the rest of the repo**:
> - Who calls this? Are callers updated consistently?
> - Who writes to this field? Do all writers share the same contract?
> - Is there a parallel code path (e.g. `foo()` and `fooAsync()`) that
>   should receive a matching change?
> - What invariants does the surrounding code assume? Does the diff
>   preserve them?
>
> Read function bodies, not just signatures. Flag contract changes,
> nullability shifts, return-shape changes, concurrent-write assumption
> violations, and missing matching updates in parallel paths. **This lens
> exists specifically to catch incomplete fixes — be thorough.** Over-flag.
>
> Return a JSON array of candidates with `impact_type: "correctness"`,
> `source_family: "structural-family"`, and the same field shape as L1.

#### L3 — CLAUDE.md compliance (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt essence:

> Read each CLAUDE.md file in this list (absolute paths, root-first):
> `$claude_md_paths`
>
> For every rule in those files, check whether the diff between `$comparison_ref`
> and HEAD violates it. For each violation, cite the exact CLAUDE.md file
> and line number in `evidence_snippet`.
>
> **Tag each violation's `impact_type`:** `correctness` if the rule concerns
> runtime behavior, error handling, invariants, or safety; `policy` if it
> concerns style, conventions, preferences, or formatting.
>
> Skip any violation that's silenced by an explicit ignore comment on the
> relevant code.
>
> Return the same candidate shape as L1 with `source_family: "policy-family"`.

#### L4 — comment compliance (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt essence:

> Read the diff between `$comparison_ref` and HEAD, plus the current content
> of every modified file. Focus on comments and doc strings (JSDoc, TSDoc,
> Python docstrings, Rust doc comments, etc.) adjacent to changed code.
>
> Flag when the diff contradicts a comment's claim — e.g., a docstring says
> "returns non-null" but the change now returns null; a function comment
> says "idempotent" but the change introduces state mutation.
>
> If the contradiction is runtime-impactful, upgrade `impact_type` to
> `correctness`; otherwise `policy`.
>
> Return the same candidate shape as L1 with `source_family: "policy-family"`.

#### L5 — UX (Sonnet; skipped if `trivial_mode` or `user_facing == false`)

Launch one `Agent` tool-use with `model: sonnet`. Inline the UX reference
content into the prompt via a preprocessor include — in the fragment as
consumed, the reference is inlined by the top-level command file via
`` !`cat ~/.claude/commands/_shared/lens-ux-reference.md` `` so the
sub-agent sees the full reference in its prompt.

Prompt essence:

> UX reference:
>
> !`cat ~/.claude/commands/_shared/lens-ux-reference.md`
>
> Read the diff between `$comparison_ref` and HEAD and the CLAUDE.md files in
> `$claude_md_paths` (project-specific UX conventions take precedence over
> the generic reference above).
>
> Focus on behavioral gaps visible from the diff: missing loading / empty /
> error states; inadequate confirmation on destructive actions; silent
> failures; missing keyboard / accessibility affordances; copy that doesn't
> match existing patterns in the codebase.
>
> Return the same candidate shape as L1 with `impact_type: "ux"`,
> `source_family: "ux-family"`.

#### L6 — lightweight security (Sonnet; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: sonnet`. Inline the security
reference via preprocessor include (same mechanism as L5).

Prompt essence:

> Security reference:
>
> !`cat ~/.claude/commands/_shared/lens-security-reference.md`
>
> Read the diff between `$comparison_ref` and HEAD. If structural reasoning
> (similar to L2 — walking callers and writers) suggests a security
> implication, flag it even when the immediate code isn't obviously a
> security surface. **Over-flag.**
>
> Return the same candidate shape as L1 with `impact_type: "security"`,
> `source_family: "security-family"`.

### 1.4. Collect lens results + log tokens

For each sub-agent result, in the order it returns:

1. **Log tokens first** (§24.4 — "cost accounted even for failed agents").
   Parse the sub-agent's `<usage>total_tokens: N</usage>` block. If the
   Agent tool result exposes a structured `usage` field directly, prefer
   that. On parse failure, use `--tokens null` per the §11 fallback.

   ```bash
   ~/.claude/commands/_shared/tools/log-tokens.sh \
     --review-dir "$review_dir" \
     --phase phase_1 --agent-role <lens-name> \
     --agent-id <id-from-Agent-result> \
     --model <model> \
     --tokens <N or null>
   ```

   `<lens-name>` is one of `lens_1_diff_local`, `lens_2_structural`,
   `lens_3_claude_md`, `lens_4_comments`, `lens_5_ux`, `lens_6_security`.
   The paired per-finding `sources[]` entry — used in the jq builder at
   step 3 — is the shorter lens tag: `L1-diff-local`, `L2-structural`,
   `L3-claude-md`, `L4-comments`, `L5-ux`, `L6-security` (DESIGN §6).

2. **Light JSON repair** if the output isn't a parseable array — strip code
   fences, extract the JSON block. If still unparseable, retry once with
   prompt addendum: "Your prior response was not valid JSON. Return only
   the JSON array described in the schema." If still unparseable, log to
   `trace.md` and drop that lens's output per §24.1.

2a. **Origin cross-check (§13.11).** Before building the full finding
   shape, hand the lens's candidate array to `origin-crosscheck.sh` so
   any candidate whose blame range is entirely ancestor of
   `$comparison_ref` gets `origin=pre_existing, origin_confidence=high`
   — which then triggers the §13.1 pre-existing override at Phase 3.
   `introduced_by_pr` candidates that blame confirms as PR-modified
   are respected; lens-supplied `pre_existing` whose blame disagrees
   gets downgraded to medium confidence so the override doesn't fire.

   ```bash
   corrected_candidates=$(
     ~/.claude/commands/_shared/tools/origin-crosscheck.sh \
       --comparison-ref "$comparison_ref" \
       --candidates "$lens_candidates_json" \
       2> >(tee -a "$trace_log_path" >&2)
   )
   ```

   Stderr (one `origin_crosscheck: id=... action=...` line per
   candidate) flows directly into `trace.md` via the process
   substitution. On non-zero exit: the helper does NOT abort per-
   candidate blame failures (those surface as `action=skipped`), so a
   non-zero exit means something structural (unknown ref, bad JSON).
   Log the stderr to `trace.md` and fall through using
   `$lens_candidates_json` unchanged — respecting the lens across the
   board is the safe default when cross-check can't run.

3. **Build a complete finding object and append it.** `artifact-patch.py
   --add-finding` does NOT default fields — it validates the payload
   against the full schema and rejects if anything required is missing.
   The lens sub-agent returns a PARTIAL candidate (with keys like
   `file`, `line_range`, `claim`, `evidence_snippet`, `impact_type`,
   `origin`, `origin_confidence`, `source_family` — singular). You must
   transform it into the full schema shape before passing to
   `--add-finding`.

   Iterate over `$corrected_candidates` from step 2a (it has the same
   shape as the lens's partial candidate array, with `origin` and
   `origin_confidence` possibly corrected per §13.11). For each
   element, bind it to `$candidate_from_lens` in the jq call below.

   Build the complete finding object per candidate. Monotonically assign
   finding ids (`F001`, `F002`, ... across all lenses — keep a counter in
   your working context):

   ```
   {
     "id":                        "F###",
     "sources":                   ["<lens-tag>"],                # lens-specific per DESIGN §6: L1-diff-local | L2-structural | L3-claude-md | L4-comments | L5-ux | L6-security
     "source_families":           ["<lens's source_family>"],    # singular → array; Phase 2 may union
     "impact_type":               "<from lens output>",
     "origin":                    "<from lens, default introduced_by_pr>",
     "origin_confidence":         "<from lens, default high>",
     "actionability":             "auto_fixable"                 # if impact_type ∈ {correctness, security}
                                  | "manual"                     # ux/policy
                                  | "report_only",               # architecture
     "validation_lane":           "deep" if impact_type ∈ {correctness, security} AND trivial_mode != true
                                  else "light",
     "current_state":             "open",
     "disposition":               "pending_validation",          # parking state; Phase 3 gate-fail → below_gate, Phase 4 → confirmed_* / disproven / uncertain / pre_existing_report
     "is_actionable":             false,                         # must agree with disposition per §5.2.1
     "reason":                    null,
     "confirmed_strength":        null,
     "file":                      "<from lens>",
     "line_range":                [<start>, <end>],              # [int, int]
     "claim":                     "<from lens>",
     "score_phase3":              null,                          # Phase 3 sets
     "score_phase4":              null,
     "score_history":             [],
     "validation_result":         null,
     "fix_attempts":              [],
     "introduced_in_sha":         null,
     "suggested_follow_up":       null,
     "related_parent_finding_id": null
   }
   ```

   Use `jq -n` to build this from the lens's partial candidate without
   escaping-hell:

   ```bash
   full_finding=$(jq -n \
     --arg id "F$(printf '%03d' $finding_counter)" \
     --arg lens_tag "$lens_source_tag" \
     --arg sf "$lens_source_family_singular" \
     --argjson trivial "$trivial_mode" \
     --argjson lens "$candidate_from_lens" \
     '$lens + {
       id: $id,
       sources: [$lens_tag],
       source_families: [$sf],
       actionability: (if ($lens.impact_type == "correctness" or $lens.impact_type == "security") then "auto_fixable"
                      elif ($lens.impact_type == "architecture") then "report_only"
                      else "manual" end),
       validation_lane: (if $trivial then "light"
                         elif ($lens.impact_type == "correctness" or $lens.impact_type == "security") then "deep"
                         else "light" end),
       current_state: "open",
       disposition: "pending_validation",
       is_actionable: false,
       reason: null,
       confirmed_strength: null,
       score_phase3: null,
       score_phase4: null,
       score_history: [],
       validation_result: null,
       fix_attempts: [],
       introduced_in_sha: null,
       suggested_follow_up: null,
       related_parent_finding_id: null
     } | del(.source_family, .evidence_snippet)')   # strip candidate-only fields — schema additionalProperties:false
   ```

   For trivial-mode runs (`trivial_mode=true`), the jq builder above
   forces `validation_lane="light"` for every candidate — Phase 4b
   handles the whole pool per §19.6. The `$trivial` argjson binding
   drives that branch so the stored lane is honest.

   Then append:

   ```bash
   ~/.claude/commands/_shared/tools/artifact-patch.py \
     --path "$artifact_path" --add-finding "$full_finding"
   ```

   On non-zero exit, read the error-as-prompt (it names the offending
   field), adjust your `jq` build, retry once. A common failure is a
   lens returning `line_range` as `null` instead of `[N, N]` — default
   to `[1, 1]` with a `trace.md` note when that happens.

   **`pending_validation` is the Phase-1 parking disposition.**
   Schema requires `disposition` non-null, so we can't leave it unset.
   `is_actionable: false` + `disposition: "pending_validation"` keeps the
   §5.2.1 coupling happy. Phase 3's gate either locks a gate-fail finding
   into `below_gate` with the "below validation gate (score X)" reason,
   or leaves it at `pending_validation` for Phase 4 to overwrite with
   the final verdict. Pre-existing overrides set `pre_existing_report`
   at Phase 3.1 before any of that runs.

### 1.5. Log Phase 1 summary

After every lens result is aggregated:

```bash
phase_1_elapsed=$(( $(date +%s) - phase_1_start_epoch ))

# Per-lens candidate count via artifact-read
counts_by_family=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | .source_families[]?] | group_by(.) | map({key:.[0], value:length}) | from_entries')

total_candidates=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" --filter '.findings | length')

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 1 --name detection \
  --elapsed "$phase_1_elapsed" \
  --summary "total=$total_candidates; counts_by_family=$counts_by_family; skipped_lenses=<list-if-any>"

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 1 --record "$(jq -nc \
    --arg name detection \
    --argjson elapsed "$phase_1_elapsed" \
    --argjson total "$total_candidates" \
    '{name:$name, elapsed_sec:$elapsed, counts_by_state:{open:$total}, counts_by_disposition:{pending_validation:$total}, delta:"+\($total) open"}')"
```

Capture `phase_1_start_epoch` via `phase_1_start_epoch=$(date +%s)` immediately
before the first Agent dispatch.

### Working-set delta after Phase 1

- `artifact.findings[]` populated with candidates.
- `tokens.jsonl` grew one entry per lens sub-agent.
- `phases.jsonl` grew a Phase 1 record.
- `trace.md` grew a Phase 1 section.
