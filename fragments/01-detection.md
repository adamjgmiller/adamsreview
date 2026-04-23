## Phase 1 — Detection

Six internal lenses run in parallel to produce candidate findings; a
seventh (L7 holistic) joins the fan-out when `--ensemble` is set. Each
lens returns a list of candidates tagged with routing fields
(`impact_type`, `origin`, `origin_confidence`, `source_family`). The
orchestrator merges all lens outputs into `artifact.findings[]` as one
call per candidate to `artifact-patch.py --add-finding`.

**Dispatch parallelism.** To get actual wall-clock parallelism across lenses,
send every applicable lens's `Agent` tool-use block inside a single
orchestrator turn. Claude Code then runs them concurrently. Collecting the
results happens on the next turn.

### 1.1. Decide which lenses run

Based on the Phase 0 variables:

| Lens | Model | Runs when |
|---|---|---|
| L1 — diff-local scan | `sonnet` | always |
| L2 — structural / blast-radius | `opus` | `trivial_mode != true` |
| L3 — CLAUDE.md compliance | `sonnet` | always |
| L4 — comment compliance | `sonnet` | always |
| L5 — UX | `sonnet` | `user_facing == true AND trivial_mode != true` |
| L6 — lightweight security | `sonnet` | `trivial_mode != true` |
| L7 — holistic review | `opus` | `ensemble_mode == true AND trivial_mode != true` |

Skipped lenses get a one-line note in `trace.md`:
```
Phase 1: L7 skipped (ensemble_mode=false)
Phase 1: L2/L5/L6/L7 skipped (trivial_mode=true)
```

Log them via `log-phase.sh --summary` at step 1.6 as part of the Phase 1
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
diff; L2 (and L7 under `--ensemble`) additionally read surrounding files
and use git blame / git log.

For lenses that receive CLAUDE.md content (L3, L4, L5, L6), pass
`claude_md_paths` (the list captured in Phase 0, step 0.7). Each lens
reads only what it needs.

### 1.2.1. Shared lens-prompt invariants

Every lens dispatched in step 1.3 must receive the following invariants
in its prompt (exact wording — the sub-agents need them verbatim so
candidate shapes don't diverge across lenses). Each lens's sub-section
below restates **only lens-specific guidance**; the orchestrator
prepends this shared block when assembling the dispatch prompt.

The orchestrator dispatches `<shared invariants from 1.2.1> + <lens
blockquote>` as the sub-agent prompt. Prose outside the blockquote in
each lens sub-section (headings, annotations, commentary) is for the
fragment reader, **NOT dispatched** — any directive the sub-agent must
follow has to live inside the blockquote.

> Read the diff between `$comparison_ref` and HEAD.
>
> Return a JSON array of candidates. Each candidate:
>
> ```
> {
>   "file": "src/path/to/file.ts",
>   "line_range": [start, end],
>   "claim": "one-sentence description of the issue",
>   "evidence_snippet": "the exact code lines implicated",
>   "impact_type": "correctness" | "security" | "ux" | "policy" | "architecture",
>   "origin": "introduced_by_pr" | "pre_existing" | "unknown",
>   "origin_confidence": "high" | "medium" | "low",
>   "source_family": "<set by lens; see lens-specific guidance>"
> }
> ```
>
> Each lens's section below specifies the `impact_type` and
> `source_family` values to use. Other fields follow the shapes above.

Lens-specific extensions the shared block does **not** cover (keep
inline in each lens sub-section):

- "ONLY the diff" vs. "diff plus surrounding files / git blame / git
  log" — lens-specific reading scope (L1 is diff-only; L2 and L7 walk
  outward).
- CLAUDE.md reading — L3, L4, L5 consume `$claude_md_paths`; others
  don't.
- "Over-flag; Phase 3 will filter" directive — appears in L1, L2, L6,
  L7 where over-flag is the intended posture; L3/L4/L5 don't carry it.
- Default `origin: "introduced_by_pr"`, `origin_confidence: "high"`
  unless the code is clearly unchanged by this diff — L1 and L7 carry
  this explicit default; other lenses rely on `origin-crosscheck.sh`
  (step 1.4 step 2a) to correct blame-traceable cases.
- Lens-specific failure modes, checklist items, impact-type tags, and
  source-family tags.

### 1.2a. Ensemble readiness gate (§13.12)

This gate runs before the dispatch turn so missing-CLI prompts surface
ahead of any token spend. Under `ensemble_mode=false` it's a one-line
no-op; under `ensemble_mode=true` it probes CodeRabbit + Codex, may
prompt the user via `AskUserQuestion`, and prepares the scratch
directory + Codex prompt file for the joint dispatch at step 1.3.

**When `ensemble_mode != true`:**

Skip the gate. Record one line in `trace.md`:

```
Phase 1 ensemble readiness gate skipped — --ensemble not set
```

Set `coderabbit_available=false`, `codex_available=false` in your
working context (so downstream fragments can short-circuit uniformly)
and continue to step 1.3.

**When `ensemble_mode == true`:**

Create the scratch directory for CLI outputs (DESIGN §9.3 keeps
`$review_dir` free of transient noise):

```bash
scratch_dir="/tmp/adams-review-$review_id"
mkdir -p "$scratch_dir"
```

Check CodeRabbit availability:

```bash
coderabbit --version 2>&1 && coderabbit auth status 2>&1 | head -3
```

If either returns non-zero, record `coderabbit_available=false` with
the specific failure reason (e.g., "not installed", "not authenticated
— run `coderabbit auth login`"). Otherwise `coderabbit_available=true`.

Check Codex availability:

```bash
CODEX_COMPANION="$(find ~/.claude/plugins -type f -name codex-companion.mjs -path '*codex*' 2>/dev/null | head -1)"
if [[ -z "$CODEX_COMPANION" ]]; then
    codex_available=false
    codex_reason="companion script not found — run /codex:setup"
else
    # Companion CLI surface: `setup --json` emits {"ready": true|false, ...}.
    # The older `ready` subcommand does not exist — parse the JSON's
    # `.ready` boolean instead of grep-matching a literal string.
    codex_setup_json=$(node "$CODEX_COMPANION" setup --json 2>&1)
    if [[ "$(jq -r '.ready // false' <<<"$codex_setup_json" 2>/dev/null)" == "true" ]]; then
        codex_available=true
    else
        codex_available=false
        codex_reason="setup --json reported not-ready — run /codex:setup to diagnose"
    fi
fi
```

**If both CLIs are available**, proceed silently. **If either is
unavailable**, dispatch `AskUserQuestion` **once** with two options:

- **Proceed with what's available** — continue with the available
  reviewer(s) plus the PR scrape. Note skipped reviewers in the final
  report's source breakdown and in `trace.md`.
- **Stop so I can set them up first** — exit the command. Print the
  exact remediation commands (`coderabbit auth login`, `/codex:setup`)
  and let the user fix first.

Stopping here costs zero lens tokens — the whole point of hoisting the
gate ahead of dispatch.

**If `codex_available=true`**, also write the Codex prompt file here so
the dispatch turn at 1.3 is pure launches with no side effects:

```bash
cat > "/tmp/adams-review-codex-$review_id.md" <<PROMPT
Review this PR as a skeptical careful reader — the kind of reviewer who
catches bugs a linter and the test suite miss. Range: the diff between
$comparison_ref and HEAD, plus surrounding code you need to understand it.

For every function the diff adds or modifies, look for:
- Inputs the function silently accepts that it shouldn't (prefix parsers
  like parseFloat/parseInt accepting trailing junk; regex gates that
  check digit shape but not range; validators that trust their input
  where a sibling in the same file is deliberately strict).
- Failure paths that produce misleading errors — especially try/catch
  blocks that wrap a state-changing operation (DB commit, file rename,
  UPSERT, network publish) together with post-commit work, so a
  post-commit throw surfaces as "operation failed" and users retry,
  double-applying.
- Termination / completion invariants that aren't checked — hand-rolled
  parsers (state machines, tokenizers, CSV/JSON/form readers) that
  don't verify they ended in a completed state at EOF.
- Parallel paths whose strictness has diverged — sibling parsers or
  validators in the same file where one is strict and one isn't; two
  filter predicates that should apply the same rule and don't; a SQL
  JOIN that fans out because the source table has multiple rows per
  join key.
- Filter predicates / COALESCE / NULLIF chains that miss a value some
  upstream writer legitimately produces (negative numbers, zero, NULL,
  duplicate-by-type rows) — trace every writer of the column, not just
  the happy-path writer.
- Project-convention violations visible in nearby CLAUDE.md rules or
  adjacent code style.

Return findings as a structured list — each with file path, line range,
and concrete prose describing the bug and why it matters. Over-report;
downstream filtering picks up the rest.
PROMPT
```

`phase_1_5_start_epoch` is captured at the END of step 1.2b (after the
deterministic prior-fix scan completes) — see the tail of 1.2b below.
That placement keeps both Phase 1 and Phase 1.5 clocks aligned with
the step 1.3 dispatch-turn boundary, so neither phase's `elapsed_sec`
over-reports Phase 0-style work done beforehand.

### 1.2b. Prior-fix suspect scan (§13.11b)

Before dispatching lenses, scan git history for prior "fix" commits
whose changes overlap the PR's diff. The output feeds L2's prompt so
L2 can judge whether the current change undoes any suspect fix — the
deterministic half of prior-fix-reversion detection; L2 is the judge.

Skipped when `$trivial_mode` is true (L2 is skipped too, so the
suspects have no consumer):

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

On helper non-zero exit, fall back to `[]` — L2's prior-fix section
becomes a no-op, which is the right degraded behavior (the rest of
L2's prompt still runs normally). Per-file audit lines
(`prior_fix_diff: file=... hunks=... suspects=...`) flow into
`trace.md` via the `tee -a` pattern — mirrors `origin-crosscheck.sh`
dispatch at step 1.4 step 2a.

`$prior_fix_suspects` is held in orchestrator working context and
consumed once at step 1.3 (L2's prompt). No artifact write here —
suspects are prompt input, not findings.

**Finally, capture `phase_1_5_start_epoch`** — AFTER the readiness-gate
`AskUserQuestion` (from step 1.2a) may have run AND after the prior-fix
helper completes, so neither user-response wait time nor helper runtime
is billed into Phase 1.5's elapsed:

```bash
phase_1_5_start_epoch=$(date +%s)
```

This epoch is what 02-ensemble-adapter.md step 1.5.7 subtracts to
compute `phase_1_5_elapsed`. Placing it here mirrors Phase 1's
`phase_1_start_epoch` capture at the top of step 1.3 — both clocks
start at the same turn boundary, so under §13.12 parallel dispatch
the two `elapsed_sec` values naturally overlap in `phases.jsonl`.

### 1.3. Dispatch the lenses (one turn, one Agent call per applicable lens)

#### L1 — diff-local scan (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`, `subagent_type: general-purpose`.
Prompt essence (prepended with the shared invariants from step 1.2.1):

> Read **ONLY** the diff. Do not open other files or grep the repo. Flag
> off-by-one errors, inverted conditions, typos in identifiers, dead
> branches, obvious null-deref patterns, and mismatched quotes or parens.
> **Over-flag — Phase 3 will filter.** Ignore style issues; ignore
> anything a linter would catch.
>
> Set `impact_type: "correctness"`, `source_family: "diff-family"`.
>
> Default `origin: "introduced_by_pr"`, `origin_confidence: "high"` unless
> the implicated code is clearly unchanged by this diff.

#### L2 — structural / blast-radius (Opus; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: opus`, `subagent_type: general-purpose`,
with `Read` and `Bash(git:*)` + `Bash(grep:*)` permissions (the sub-agent
inherits the parent command's grants — this already covers it).

Prompt essence (prepended with the shared invariants from step 1.2.1; L2
additionally reads surrounding files and uses `git blame` / `git log`):

> Read like a careful human reviewer who's been handed this PR. Your
> job is to find bugs a skilled reader would flag: the ones a linter
> and the test suite don't catch but a careful read of the diff plus
> surrounding code would. Over-flag; Phase 3 filters.
>
> **Outer pass — cross-file blast-radius.** For every function, type,
> field, or API the diff changes, trace into the rest of the repo:
> - Who calls this? Are callers updated consistently?
> - Who writes to this field? Enumerate the full range of values each
>   writer can produce (NULL, zero, negative, empty, duplicate-by-key).
> - Is there a parallel code path (e.g. `foo()` and `fooAsync()`) that
>   should receive a matching change?
> - What invariants does the surrounding code assume? Does the diff
>   preserve them?
> - **Consumer-surface value trace.** For every column, field, API
>   response, template variable, LLM tool output, report line, or
>   other value the diff introduces or whose writer it modifies, walk
>   the full path from writer through storage to user-visible output.
>   If a writer can produce NULL, zero, empty string, or a default
>   value, trace what each consumer does with it: does a SQL reader
>   COALESCE it to a sentinel (e.g. `COALESCE(rate, 0)`), and is the
>   sentinel distinguishable from a legitimate zero; does a render
>   layer display the sentinel as a real value (`"0% APR"`, `"$0.00"`,
>   `"Manual account"`); does an LLM tool schema, prompt helper, or
>   insight generator feed the sentinel into an AI-generated
>   recommendation (dangerous — the pipeline may be storage-layer
>   correct but present-layer misleading; the model acts on `0%` as
>   if it were a real rate); does a downstream filter / ORDER BY /
>   conditional branch change behavior because the value is the
>   default rather than the original. Flag when the writer's NULL /
>   default can propagate to a user-facing output that reads as
>   honest (real 0%, real $0, real "Manual") but actually represents
>   missing data. This is the "semantic-layer correctness" cousin of
>   the mechanical "does the INSERT happen?" check — both matter.
> - **Cross-provider / domain-scope check.** When the diff changes a
>   function that runs inside a specific data-path (`ray import-apple`,
>   `syncPlaid`, a payroll upload, a user-initiated flow), identify
>   which data entities the function's reads and writes touch. If the
>   function's query surface is broader than the data-path's intent —
>   e.g. a recategorization pass triggered by Apple-import that
>   re-evaluates *all* transactions, not just the newly-imported Apple
>   ones — flag it. The failure mode is subtle: the function is correct
>   in isolation, but its scope crosses a provider / domain boundary
>   the user did not consent to. Check whether the function filters by
>   source / provider / import-batch / user-initiated-id before reading
>   or writing; whether side effects stay scoped to the command's
>   intent; whether a shared helper called by multiple paths scopes its
>   work at the caller or the callee.
>
> **Inner pass — small-radius careful read.** For each file the diff
> touches, also run this checklist against the changed hunks and their
> immediate neighbors:
>
> 1. **Sibling parsers / validators in the same file.** If the diff
>    adds or modifies a parser, validator, or input-sanitizer (e.g.
>    `parseFoo`, `validateBar`, a regex `.test(…)` gate, an inquirer
>    `validate` callback), grep the same file/module for every other
>    parser/validator and diff their strictness. Flag asymmetry —
>    e.g. a strict anchored regex on one path while the sibling uses
>    `parseFloat`/`parseInt`/`Number(…)` (prefix parsers that silently
>    accept trailing junk); a date parser that round-trips through
>    `Date` while a sibling accepts `\d{2}/\d{2}/\d{4}` without
>    range-checking month/day; one branch throws on unknown keys while
>    the sibling ignores them.
>
> 2. **Catch scope around state-changing operations.** When the diff
>    introduces or modifies a `try/catch` (or equivalent), identify
>    which statements inside the `try` commit state — DB commit, file
>    rename, UPSERT, network publish, `process.exit(0)`. If a
>    post-commit throw would land in the same `catch` as a pre-commit
>    throw, flag the user-facing misleading error: the operation
>    succeeded but the user sees "failed" and retries, double-applying.
>
> 3. **Hand-rolled parser EOF invariants.** For any state machine,
>    tokenizer, or CSV/JSON/form/query parser the diff adds or touches,
>    check end-of-input handling: does the terminal state represent a
>    completed parse, or can the parser silently accept truncated input
>    as if it were valid (e.g. `inQuotes==true` at EOF, brace depth
>    nonzero, expected-next-token nonempty)?
>
> 4. **Filter-predicate / COALESCE / NULLIF sweeps.** For any SQL,
>    regex, or COALESCE/NULLIF chain the diff adds or modifies,
>    enumerate every value each upstream writer can produce (use the
>    outer-pass writer list) and verify each is handled consistently.
>    Negative numbers, zero, NULL, empty string, duplicate rows from
>    UNIQUE constraints that permit multiple types per key — each one
>    is a candidate bug.
>
> 5. **SQL JOIN join-key vs. target-table UNIQUE-constraint
>    cardinality.** For any SQL JOIN the diff adds, modifies, or reads
>    from, identify the JOIN's join-key column(s), then find the target
>    table's UNIQUE / PRIMARY KEY constraint in the schema (grep
>    migrations / `CREATE TABLE` / `ALTER TABLE`). If the JOIN's join-
>    key is NOT the uniqueness key, the JOIN can fan out when the
>    target table legitimately holds multiple rows per join-key value —
>    especially likely when an UPSERT on the target uses
>    `ON CONFLICT(a, b)` (multiple rows per `a` permitted, one per `b`)
>    while the JOIN only keys on `a`. Example: if `liabilities` has
>    `UNIQUE(account_id, type)` and a query `JOIN liabilities ON
>    a.account_id = l.account_id`, a single account with both
>    `credit_card` and `mortgage` types produces two rows — and any
>    downstream `SUM` / `COUNT` / `ORDER BY` silently double-counts.
>    Flag.
>
> 6. **Same-block adjacency.** Once you've found one bug in a block,
>    reread the ±10 lines around it before moving on. List any other
>    candidate bugs in that neighborhood as separate entries — even
>    half-confident ones. Phase 3 filters weak candidates; a bug
>    co-located with a known bug usually shares a fix and is cheapest
>    to surface now.
>
> **Prior-fix reversion check (§13.11b).** The following prior commits
> (subject matches fix-intent patterns, reachable from the comparison
> ref — PR-internal commits already filtered out) touched lines that
> this PR also modifies:
>
> ```
> $prior_fix_suspects
> ```
>
> (Empty array → nothing to check; skip this section.)
>
> For each suspect, compare the current diff's changes at the overlapping
> lines against what the prior fix commit did. Flag as a candidate when
> the current diff appears to undo the prior fix — either by reverting
> to the pre-fix line content, by introducing a parallel code path that
> behaves like the pre-fix code, or by broadening a narrow condition the
> prior fix specifically narrowed. Include the prior fix commit's short
> SHA and subject in your `claim` so a reviewer can trace the history.
>
> `impact_type` for a regression-of-prior-fix: `correctness`.
> `source_family`: `structural-family` (L2's default — this is still a
> structural observation, just with history awareness).
>
> Read function BODIES, not just signatures. Flag contract changes,
> nullability shifts, return-shape changes, concurrent-write assumption
> violations, and missing matching updates in parallel paths. **This
> lens exists specifically to catch incomplete fixes and narrow bugs a
> careful reader would see — be thorough.**
>
> Set `impact_type: "correctness"`, `source_family: "structural-family"`.

#### L3 — CLAUDE.md compliance (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt essence (prepended with the shared invariants from step 1.2.1):

> Read each CLAUDE.md file in this list (absolute paths, root-first):
> `$claude_md_paths`
>
> For every rule in those files, check whether the diff violates it. For
> each violation, cite the exact CLAUDE.md file and line number in
> `evidence_snippet`.
>
> **Tag each violation's `impact_type`:** `correctness` if the rule concerns
> runtime behavior, error handling, invariants, or safety; `policy` if it
> concerns style, conventions, preferences, or formatting.
>
> Skip any violation that's silenced by an explicit ignore comment on the
> relevant code.
>
> Set `source_family: "policy-family"`.

#### L4 — comment compliance (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt essence (prepended with the shared invariants from step 1.2.1; L4
additionally reads the current content of every modified file):

> Also read the current content of every modified file (not just diff
> hunks) so you can see the full comment / doc-string context around
> changed code.
>
> Focus on comments and doc strings (JSDoc, TSDoc, Python docstrings,
> Rust doc comments, etc.) adjacent to changed code.
>
> Flag when the diff contradicts a comment's claim — e.g., a docstring says
> "returns non-null" but the change now returns null; a function comment
> says "idempotent" but the change introduces state mutation.
>
> If the contradiction is runtime-impactful, set `impact_type: "correctness"`;
> otherwise `"policy"`. Set `source_family: "policy-family"`.

#### L5 — UX (Sonnet; skipped if `trivial_mode` or `user_facing == false`)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt essence (prepended with the shared invariants from step 1.2.1):

> UX reference:
>
> # UX lens reference
>
> You are reviewing whether this diff produces a good user experience —
> distinct from whether it is technically correct.
>
> ## What to check (when the diff is user-facing)
>
> **Destructive actions.** Does confirmation match blast radius? A single-click
> that irreversibly destroys user data is a finding. A heavyweight typed-confirm
> on something fully reversible is also a finding (wrong direction).
>
> **State coverage.** Are empty, loading, error, and in-progress states handled?
> Missing empty states; generic "Loading..." with no progress on long operations;
> errors that silently swallow; intermediate states the UI doesn't represent.
>
> **Feedback.** When the user acts, is it visibly clear the action worked (or
> clear why it failed)? Actions that complete with no visible change; errors
> that disappear before the user can read them; async ops with no progress.
>
> **Affordances.** Is it obvious what's interactive vs. static? Clickable things
> that don't look clickable; non-clickable things that do; ambiguous icons
> without labels; buttons whose label doesn't predict the action.
>
> **Keyboard & accessibility.** Escape closes modals; Enter submits; focus lands
> sensibly (not on the destructive button by default); tab order matches visual
> order; ARIA labels for icon-only controls; sufficient color contrast.
>
> **Copy.** Microcopy is clear, concise, and consistent with project voice.
> Errors say what happened AND what the user can do. Button labels are verbs
> describing the action, not generic "OK"/"Yes".
>
> **Diagnostic message quality.** When the diff adds or modifies a warning,
> error, or toast — especially ones triggered by parsing, validation, or
> input rejection — check whether the message helps the user diagnose and
> fix the problem:
>
> - Does the message reveal the expected format when input is rejected?
>   A `parseDate` that only accepts `MM/DD/YYYY` should say so in the
>   warning, not "Invalid date."
> - Does the message name the specific value that failed? "Invalid amount"
>   is weaker than `"'abc' is not a valid amount — expected a number like
>   42.50."`
> - When upstream context is available (file path, row number, column name,
>   field name, source system), is it in the message? A parser error that
>   buries line number in debug logs while showing the user "Something went
>   wrong" is a diagnostic-quality gap.
> - For batch / buffered operations (flush-after-N-errors, debounced save),
>   does an empty-buffer or mid-flush failure produce a generic message
>   when a specific one is cheap? "Save failed" on an empty buffer suggests
>   data loss the user didn't actually experience.
>
> Flag as `impact_type: "ux"`. Fix proposals should include concrete message-
> text suggestions.
>
> **Visual consistency.** Uses the project's existing design tokens, CSS
> variables, or utility classes rather than ad-hoc values. CLAUDE.md and the
> existing codebase take precedence over generic examples above.
>
> ## Scope guard
>
> If the PR has no user-facing surface, return an empty list. Do not reach for
> UX findings that don't apply.
>
> Also read the CLAUDE.md files in `$claude_md_paths` (project-specific UX
> conventions take precedence over the generic reference above).
>
> Focus on behavioral gaps visible from the diff: missing loading / empty /
> error states; inadequate confirmation on destructive actions; silent
> failures; missing keyboard / accessibility affordances; copy that doesn't
> match existing patterns in the codebase.
>
> Set `impact_type: "ux"`, `source_family: "ux-family"`.

#### L6 — lightweight security (Sonnet; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt essence (prepended with the shared invariants from step 1.2.1):

> Security reference:
>
> # Security lens reference
>
> You are doing a **lightweight** security scan on this diff. This is not a
> full audit — flag issues where the code change creates or worsens a security
> risk. Over-flag; Phase 4 will filter.
>
> ## Categories to check
>
> **Authorization & authentication.**
> - New routes, API endpoints, or mutations without an auth check
> - New fields exposed through responses that shouldn't be (e.g. internal IDs,
>   credentials, PII)
> - Permission checks that accept a broader role than intended
> - Session handling changes (token lifetime, invalidation, refresh)
>
> **Input validation & injection.**
> - User-controlled input concatenated into SQL, shell commands, or HTML without
>   escaping/parameterization
> - File paths built from user input without sanitization (path traversal)
> - Regex or parser changes that accept previously-rejected malformed input
>
> **Secrets & sensitive data.**
> - Hardcoded API keys, tokens, passwords, or connection strings
> - Sensitive values logged (passwords, tokens, PII, auth headers)
> - Debug output or error messages that leak internal structure or secrets
>
> **Cryptography.**
> - New crypto primitives (if the project already has conventions, flag
>   deviation; do not recommend specific algorithms beyond that)
> - Random values used where cryptographic randomness is required
>
> **Cross-cutting security patterns.**
> - Race conditions in access checks (TOCTOU)
> - Error paths that bypass normal auth/validation flow
> - New code that handles untrusted input and calls into a structural pattern
>   the rest of the code assumes is trusted (structural-family reasoning)
>
> ## Scope guard
>
> If the diff touches no security-adjacent surface (pure UI tweak, pure test
> refactor, etc.), return an empty list. Do not reach for security findings
> that don't apply.
>
> If structural reasoning (similar to L2 — walking callers and writers)
> suggests a security implication, flag it even when the immediate code
> isn't obviously a security surface. **Over-flag.**
>
> Set `impact_type: "security"`, `source_family: "security-family"`.

#### L7 — holistic review (Opus; `ensemble_mode` only; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: opus`, `subagent_type: general-purpose`.
Inherits the parent command's Read + Bash(git:*) + Bash(grep:*) grants — same
permissions as L2.

L7 exists as a recall-oriented safety net: focused lenses have narrower
prompts tuned to specific bug classes; L7 reads the diff like a skeptical
senior reviewer with no checklist. Ensemble-gated because it costs roughly
1.5–2x an L2 pass. Phase 2 dedup merges overlaps with focused-lens
findings (unioning `source_families`) so duplicates become a strengthening
signal via Phase 3's ≥2-families auto-graduate rule, not noise.

Prompt essence (prepended with the shared invariants from step 1.2.1; L7
additionally reads surrounding code and uses `git blame` / `git log`
freely):

> Review this PR as a skeptical, careful senior engineer who was just
> handed it and asked to find bugs the test suite and linter will miss.
> Read surrounding code freely; use `git blame` / `git log` as needed.
>
> **No checklist — scan for anything wrong.** Other agents are running
> in parallel with narrower prompts (L1 diff-local, L2 structural, L3
> CLAUDE.md, L4 comments, L5 UX, L6 security). Your job is to catch
> things those miss: semantic correctness across layer boundaries,
> misleading state visible to users or AI consumers, latent bugs a
> careful human reader would notice, regressions of prior behavior,
> multi-failure-mode issues at the same call site.
>
> Places to look especially hard:
>
> - **Cross-layer semantic value.** When a field can be NULL / default /
>   missing, follow every consumer and check whether the user-visible
>   or AI-visible output is honest. A NULL rate rendered as `"0% APR"`
>   in an LLM tool output is a real bug even when the SQL is correct.
>
> - **Regression of prior behavior.** When the diff changes behavior in
>   an area that had a named fix commit, check whether the fix is being
>   undone. Use `git log -L <range>:<file>` filtered to "fix"/"bug"/
>   "regression" message patterns. A broadened SQL predicate or a
>   consolidated branch that re-introduces the pre-fix behavior is the
>   characteristic pattern.
>
> - **Cross-provider / domain scope.** When a function runs inside a
>   path named for one data source (Apple import, Plaid sync, payroll),
>   check whether its queries and writes stay scoped to that source, or
>   whether it silently re-evaluates unrelated data.
>
> - **Multi-failure-mode at the same call site.** When the diff
>   addresses one failure mode (e.g. wraps a throwing call in
>   try/catch), enumerate other ways the same call can go wrong:
>   inconsistent state, partial writes, stale cache, out-of-order side
>   effects. A "fix" that addresses one mode while leaving another live
>   is a partial fix worth flagging.
>
> - **Misleading user / AI interfaces.** Outputs that look correct but
>   mislead — `"0% APR"` for a missing rate, `"Manual"` for a non-manual
>   account, silent failures rendered as successes, partial updates
>   reported as complete, generic error messages when specific context
>   was available.
>
> - **Parallel paths whose invariants have diverged.** Two similar
>   functions/queries where only one got updated; one strict parser and
>   one lenient; a write-side that now allows NULL and a read-side that
>   assumes non-null.
>
> - **Assumptions that don't hold.** Invariants the code assumes but
>   the diff breaks; ordering assumptions; concurrency; JOIN cardinality
>   against target-table UNIQUE constraints.
>
> Over-flag; Phase 3 filters. Err toward sharing a half-confident bug.
>
> `evidence_snippet` may be a multi-file trace when the finding spans
> layers. Set `source_family: "holistic-family"`; `impact_type` may be
> any of `correctness | security | ux | policy | architecture`.
>
> Default `origin: "introduced_by_pr"`, `origin_confidence: "high"` unless
> the implicated code is clearly unchanged by this diff.

#### Ensemble fan-out (same turn, when `ensemble_mode == true`)

Per DESIGN §13.12, the dispatch turn also launches the external
reviewers and PR scrape when `ensemble_mode=true`. These run as
tool-use blocks in the same orchestrator turn as the lens `Agent`
dispatches above — waiting a turn between them serializes what's
meant to be parallel and negates the whole point of §13.12.

Total tool-use blocks in the dispatch turn:

| Condition | Blocks |
|---|---|
| `ensemble_mode=false` | applicable lenses (6 max — L1..L6; L7 is ensemble-gated) |
| `ensemble_mode=true`, both CLIs available, `mode=pr` | lenses (up to 7, including L7) + 2 background Bash + 1 foreground Bash |
| `ensemble_mode=true`, both CLIs available, `mode=local` | lenses (up to 7) + 2 background Bash |
| `ensemble_mode=true`, one CLI unavailable | lenses (up to 7) + 1 background Bash + (1 foreground Bash if PR mode) |

The ensemble launch specs live in `02-ensemble-adapter.md`:

- **CodeRabbit** (background Bash) — see `02-ensemble-adapter.md`
  step 1.5.2. Skip if `coderabbit_available=false`. Capture
  `coderabbit_shell_id`.
- **Codex** (background Bash) — see `02-ensemble-adapter.md` step
  1.5.2. Skip if `codex_available=false`. The prompt file was already
  written in step 1.2a; the launch block just invokes `node
  "$CODEX_COMPANION" task …`. Capture `codex_shell_id`.
- **PR comment scrape** (foreground Bash, PR mode only) — see
  `02-ensemble-adapter.md` step 1.5.3. Skipped in local mode. This
  call is synchronous, but it's short (seconds of `gh api`) so staying
  foreground in the dispatch turn doesn't meaningfully delay the
  background launches — it just means the turn returns a hair later.

Under `ensemble_mode=false`, none of these launches happen; the
02-ensemble-adapter fragment's top-level skip note fires when
execution reaches it and execution proceeds straight to Phase 2.

### 1.4. Collect lens candidates into pool

Collection runs per-lens as each sub-agent result returns — but under
§13.12 nothing gets an `id` and nothing is `--add-finding`'d during
collection. Candidates accumulate in an in-context pool
(`internal_candidates`) and are committed at the join step 1.5.

Initialize the pool and capture the phase epoch before the first lens
dispatch (at the top of step 1.3's dispatch turn):

```bash
phase_1_start_epoch=$(date +%s)
internal_candidates='[]'
```

For each sub-agent result, in the order it returns:

1. **Log tokens first** (§24.4 — "cost accounted even for failed agents").
   Parse the sub-agent's `<usage>total_tokens: N</usage>` block. If the
   Agent tool result exposes a structured `usage` field directly, prefer
   that. On parse failure, use `--tokens null` per the §11 fallback.

   ```bash
   log-tokens.sh \
     --review-dir "$review_dir" \
     --phase phase_1 --agent-role <lens-name> \
     --agent-id <id-from-Agent-result> \
     --model <model> \
     --tokens <N or null>
   ```

   `<lens-name>` is one of `lens_1_diff_local`, `lens_2_structural`,
   `lens_3_claude_md`, `lens_4_comments`, `lens_5_ux`, `lens_6_security`,
   `lens_7_holistic`. The paired per-finding `sources[]` entry — used in
   the jq builder at step 1.5 — is the shorter lens tag: `L1-diff-local`,
   `L2-structural`, `L3-claude-md`, `L4-comments`, `L5-ux`, `L6-security`,
   `L7-holistic` (DESIGN §6).

2. **Light JSON repair** if the output isn't a parseable array — strip code
   fences, extract the JSON block. If still unparseable, retry once with
   prompt addendum: "Your prior response was not valid JSON. Return only
   the JSON array described in the schema." If still unparseable after the
   retry, append `lens_dropped_unparseable: lens=<lens-tag> attempts=2` to
   `$trace_log_path`, **SKIP step 2a entirely for this lens** (no
   origin-crosscheck call, no tagging, no pool append), and move on to the
   next lens. The lens contributes zero candidates this run — an unparseable
   lens is out of scope for blame classification, and origin-crosscheck was
   never the right recovery tool for it. Step 1.6's summary surfaces the
   drop count so a silent-fallthrough regression is visible.

2a. **Origin cross-check (§13.11).** Hand the lens's candidate array to
   `origin-crosscheck.sh` so any candidate whose blame range is entirely
   ancestor of `$comparison_ref` gets `origin=pre_existing,
   origin_confidence=high` — which then triggers the §13.1 pre-existing
   override at Phase 3. `introduced_by_pr` candidates that blame confirms
   as PR-modified are respected; lens-supplied `pre_existing` whose blame
   disagrees gets downgraded to medium confidence so the override doesn't
   fire.

   ```bash
   # Defensive pre-check — step 2 should have already dropped unparseable
   # lens output, but belt-and-suspenders here converts any leaked-through
   # garbage into a loud skip audit line instead of a helper error plus
   # silent fallthrough into the tagging step.
   if ! echo "$lens_candidates_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
       printf 'origin_crosscheck_skipped: lens=%s reason=input_not_array\n' \
           "$lens_source_tag" >> "$trace_log_path"
       corrected_candidates="$lens_candidates_json"
   else
       corrected_candidates=$(
         origin-crosscheck.sh \
           --comparison-ref "$comparison_ref" \
           --candidates "$lens_candidates_json" \
           2> >(tee -a "$trace_log_path" >&2)
       )
   fi
   ```

   Stderr (one `origin_crosscheck: id=... action=...` line per
   candidate) flows directly into `trace.md` via the process
   substitution. On non-zero exit: the helper does NOT abort per-
   candidate blame failures (those surface as `action=skipped`), so a
   non-zero exit means something structural (unknown ref, bad JSON).
   Log the stderr to `trace.md` and fall through using
   `$lens_candidates_json` unchanged — respecting the lens across the
   board is the safe default when cross-check can't run. The
   `origin_crosscheck_skipped` audit line (different tag from the
   helper's own `origin_crosscheck:` per-candidate lines) is what step
   1.6 counts for the summary.

3. **Tag with `sources` and append to the pool.** Do NOT call
   `--add-finding` here; do NOT assign an id. The full-finding jq build
   moves to step 1.5 where ids are assigned atomically across the
   combined pool.

   Tag each corrected candidate with `sources: [<lens-tag>]` so the
   join step's helper (`assign-finding-ids.sh`) can sort by source
   priority. The lens-tag is the same short tag used in the token log
   above (`L1-diff-local`, `L2-structural`, etc., per DESIGN §6):

   ```bash
   tagged=$(echo "$corrected_candidates" \
     | jq --arg tag "$lens_source_tag" '[.[] | . + {sources: [$tag]}]')

   internal_candidates=$(jq -nc \
     --argjson accum "$internal_candidates" \
     --argjson new "$tagged" \
     '$accum + $new')
   ```

   The pool lives in your working context, not on disk — no intermediate
   artifact writes. If the orchestrator loses context mid-collection,
   Phase 1 has to re-run from dispatch.

   A common lens failure is `line_range: null` instead of `[N, N]`.
   Default to `[1, 1]` with a one-line `trace.md` note at collection
   time so the join step's jq builder doesn't blow up on a schema-
   invalid pool entry:

   ```bash
   tagged=$(echo "$tagged" \
     | jq '[.[] | .line_range //= [1,1]]')
   ```

### 1.5. Join + assign IDs + add-finding (§13.12)

Wait until every internal lens has returned AND (if `ensemble_mode ==
true`) the ensemble normalizer has emitted its candidate array into
`external_candidates` per `02-ensemble-adapter.md` step 1.5.5. Under
`ensemble_mode=false`, `external_candidates` defaults to `[]`.

**Step 1. Combine the two pools:**

```bash
pooled=$(jq -nc \
  --argjson internal "$internal_candidates" \
  --argjson external "${external_candidates:-[]}" \
  '$internal + $external')
```

**Step 2. Line-range sanity filter.** Lens agents (notably L5-ux) have
been observed fabricating `line_range` values well past the file's
actual length — Phase 4 validators then "confirm" because they
re-search the file for the claim pattern, and the rendered report
carries unreachable line numbers. Drop hallucinated-range candidates
before ids are assigned so wasted IDs don't litter the artifact:

```bash
sanitized=$(printf '%s' "$pooled" \
  | line-range-check.sh \
      --reviewed-sha "$reviewed_sha" \
      2> >(tee -a "$trace_log_path" >&2))
```

Per-drop audit lines on stderr:

- `lens_hallucinated_line_range: source=<src> file=<path> range=[a,b] actual_lines=<N>`
- `lens_referenced_missing_file: source=<src> file=<path>`

Phase 1.5 external-scrape candidates with `file == "(unknown)"` pass
through untouched. On non-zero exit (bad ref / malformed JSON), log
stderr to `trace.md` and fall through with `$pooled` unchanged —
respecting every candidate is the safe default when the check can't
run.

```bash
if [[ -z "$sanitized" ]]; then
    sanitized="$pooled"
fi
```

**Step 3. Assign monotonic finding ids via the helper:**

```bash
ided=$(printf '%s' "$sanitized" \
  | assign-finding-ids.sh)
```

`assign-finding-ids.sh` sorts by source priority (L1, L2, L3, L4, L5,
L6, L7, external-pr, codex, coderabbit — stable within source = input
order preserved) and assigns `F001…F0NN`. See the helper's header for
the full priority table.

On non-zero exit (malformed pool JSON), log stderr to `trace.md` and
bail — the whole detection phase must re-run because the pool is
corrupt. This is a structural failure, not a per-candidate drop.

**Step 4. Build full schema-valid findings + single `--add-finding`
sweep.** `artifact-patch.py --add-finding` does NOT default fields —
it validates the payload against the full schema and rejects if
anything required is missing. Partial candidates (from lenses) and
normalizer candidates both need to be fleshed out to schema shape.

For each element in `$ided`, bind it to `$candidate` in the jq call
below and call `--add-finding`. The jq builder matches the pre-§13.12
logic (DESIGN §6 shape) with `.id` already populated from the helper.

**Source-family canonicalization.** Before the jq builder runs, pipe the
candidate's raw `source_family` through `source-family-map.py`. The
helper accepts the eight canonical families (`diff-family`,
`structural-family`, `policy-family`, `ux-family`, `security-family`,
`holistic-family`, `external-deep-family`, `external-add-family`) as pass-through and maps
known drift patterns (e.g. `prompt-injection → security-family`,
`stale-line-ref → policy-family`) to their canonical equivalent.
Exit 3 means "unknown family" — rather than silently drop the
candidate (risks losing real findings when the mapping table hasn't
caught up to lens drift), mark `source_family: "unknown"` and log the
drift to `trace.md` so the next mapping-table update surfaces from
audit inspection. Phase 2 dedup's union of `source_families` and
Phase 3's auto-graduation rule both accept arbitrary family strings,
so `"unknown"` propagates harmlessly downstream.

```bash
while IFS= read -r candidate; do
    raw_family=$(printf '%s' "$candidate" | jq -r '.source_family // "diff-family"')
    canonical_family=$(source-family-map.py --input "$raw_family" 2>/dev/null) || {
        printf 'lens_source_family_unknown: source=%s raw=%s -> mapped to "unknown"\n' \
            "$(printf '%s' "$candidate" | jq -r '.sources[0] // "(unknown)"')" \
            "$raw_family" \
            >> "$trace_log_path"
        canonical_family="unknown"
    }
    candidate=$(printf '%s' "$candidate" \
        | jq -c --arg f "$canonical_family" '.source_family = $f')

    full_finding=$(jq -n \
      --argjson trivial "$trivial_mode" \
      --argjson cand "$candidate" \
      '$cand + {
        source_families: [($cand.source_family // "diff-family")],
        actionability: (if ($cand.impact_type == "correctness" or $cand.impact_type == "security") then "auto_fixable"
                       elif ($cand.impact_type == "architecture") then "report_only"
                       else "manual" end),
        validation_lane: (if $trivial then "light"
                          elif ($cand.impact_type == "correctness" or $cand.impact_type == "security") then "deep"
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

    artifact-patch.py \
      --path "$artifact_path" --add-finding "$full_finding"
done < <(printf '%s' "$ided" | jq -c '.[]')
```

For trivial-mode runs (`trivial_mode=true`), the jq builder above
forces `validation_lane="light"` for every candidate — Phase 4b
handles the whole pool per §19.6. The `$trivial` argjson binding
drives that branch so the stored lane is honest.

On non-zero exit for any single `--add-finding`, read the error-as-
prompt (it names the offending field and id), adjust your `jq` build,
retry once. On second failure, log the finding id to `trace.md` and
drop it — the rest of the pool still commits. This matches the pre-
§13.12 per-candidate failure policy.

**`pending_validation` is the Phase-1 parking disposition.** Schema
requires `disposition` non-null, so we can't leave it unset.
`is_actionable: false` + `disposition: "pending_validation"` keeps the
§5.2.1 coupling happy. Phase 3's gate either locks a gate-fail finding
into `below_gate` with the "below validation gate (score X)" reason,
or leaves it at `pending_validation` for Phase 4 to overwrite with the
final verdict. Pre-existing overrides set `pre_existing_report` at
Phase 3.1 before any of that runs.

### 1.6. Log Phase 1 summary

After every lens result is aggregated and the join step has committed
the pool to the artifact:

```bash
phase_1_elapsed=$(( $(date +%s) - phase_1_start_epoch ))

# Per-lens candidate count via artifact-read
counts_by_family=$(artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | .source_families[]?] | group_by(.) | map({key:.[0], value:length}) | from_entries')

total_candidates=$(artifact-read.sh \
  --path "$artifact_path" --filter '.findings | length')

# Surface Phase 1's loud-failure audit tags so the operator sees a non-
# zero count in the trace + phases.jsonl summary rather than having to
# grep trace.md themselves. Both zero on a healthy run.
#
# `grep -c … || true` matches 00-preflight.md's idiom. `grep -c` outputs
# "0" to stdout on zero matches but exits 1 — `|| true` swallows the
# non-zero so the assignment cleanly captures "0". Do NOT use `|| echo
# 0` here: grep already prints "0" on no-match, so the fallback would
# concatenate another "0" and the variable becomes "0\n0".
lens_drops=$(grep -c '^lens_dropped_unparseable:' "$trace_log_path" 2>/dev/null || true)
oc_skipped=$(grep -c '^origin_crosscheck_skipped:' "$trace_log_path" 2>/dev/null || true)

log-phase.sh \
  --review-dir "$review_dir" --phase 1 --name detection \
  --elapsed "$phase_1_elapsed" \
  --summary "total=$total_candidates; counts_by_family=$counts_by_family; skipped_lenses=<list-if-any>; lens_drops=$lens_drops; origin_crosscheck_skipped=$oc_skipped"

log-phase.sh \
  --review-dir "$review_dir" --phase 1 --record "$(jq -nc \
    --arg name detection \
    --argjson elapsed "$phase_1_elapsed" \
    --argjson total "$total_candidates" \
    '{name:$name, elapsed_sec:$elapsed, counts_by_state:{open:$total}, counts_by_disposition:{pending_validation:$total}, delta:"+\($total) open"}')"
```

Under joint dispatch (§13.12), `phase_1_elapsed` and the Phase 1.5
elapsed logged by `02-ensemble-adapter.md` step 1.5.7 will overlap
because both phases share a dispatch-turn start boundary. That overlap
is the intended observability signal.

### Working-set delta after Phase 1

- `internal_candidates` (orchestrator-context pool) was built during
  1.4 and consumed at 1.5.
- `artifact.findings[]` populated with IDed candidates at 1.5.
- `tokens.jsonl` grew one entry per lens sub-agent.
- `phases.jsonl` grew a Phase 1 record (ts overlaps Phase 1.5's under
  `--ensemble` per §13.12).
- `trace.md` grew a Phase 1 section.
