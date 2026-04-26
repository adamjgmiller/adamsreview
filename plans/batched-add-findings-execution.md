# Batched `--add-findings` execution journal

Execution protocol, step manifest, and progress ledger for
`plans/batched-add-findings.md`. Designed so the session can be
`/clear`-ed between stages and resumed by pasting the prompt below.

**Pre-reqs:** the design plan has been approved by the user. This
file is the authoritative state for execution; `plans/batched-add-
findings.md` is the authoritative state for design. If the two
disagree, the design plan wins — fix this file, don't drift.

**Branch:** `writing-issues` (worktree at
`.claude/worktrees/writing-issues`). All commands run from the
worktree, never `cd` to the original repo root.

---

## Paste prompt (copy verbatim after `/clear`)

```
Resume batched --add-findings execution via /orchestrate.

1. Read plans/batched-add-findings-execution.md — follow §1 (usage),
   §2 (protocol), and §4 (ledger; start from the "Next pending
   stage" cursor).
2. Read plans/batched-add-findings.md — design.
3. Read CLAUDE.md sections relevant to the current cursor stage
   (operational rules; helper index; batched-helper pattern).
4. Execute per §2's loop. Stop when all stages are done or you
   need user input. Do NOT amend; commit new commits only, per
   CLAUDE.md Git Safety Protocol.
```

---

## §1 — How to use

**On resume.** Read this file + the design plan + `CLAUDE.md`. The
cursor in §4 identifies the next pending stage. If §4's cursor says
`COMPLETE`, the stage set is closed. If `BLOCKED`, the last stage
paused for user input; read the blocker note before doing anything.

**During execution.** Every stage runs under §2's build → spot-check
→ verify loop. Sub-agents do per-stage build/edit/verify; the
orchestrator reconciles diffs, commits, and updates §4. Use
`TaskCreate` for in-session progress; the §4 ledger is the
cross-session durable truth.

**When stuck.** Pause, write a `BLOCKED` entry in §4 with the
reason, report to the user, and stop. Do not force a commit past a
failing smoke or a 3-cycle-unclean review. Halt early if diagnosis
points at upstream code or the plan's premise — three more cycles
won't fix an upstream problem.

---

## §2 — Execution protocol

Each stage runs this loop. Max **3 build → verify cycles** per
stage; after cycle 3 unclean, pause and escalate.

### Per-stage cycle

**1. Reload context.** Read the design plan section the stage maps
to (Section numbers given in §3 below), this file's §3 entry for
the stage, and any `CLAUDE.md` rule the stage's files touch
(operational rules 1–11, helper index, batched-helper pattern).

**2. Build (sub-agent dispatch — `general-purpose`, fresh).**

Each cycle is a separate `Agent` invocation. The build agent's
prompt must include:
- Stage ID + name + scope from §3.
- Success criteria (verbatim).
- Absolute paths of files to touch.
- The relevant section(s) of `plans/batched-add-findings.md`
  reproduced in full (the design plan is the source of truth for
  what to write — paste the section, don't paraphrase).
- Blast-radius discipline (CLAUDE.md): every writer, every
  consumer, parallel code paths, full function bodies, stale
  comments. Apply before editing and before reporting back.
- Constraint: **do not commit**. Leave changes in the working tree.
- Findings from prior cycles (if cycle > 1) — paste the verify or
  diagnose findings verbatim.

**3. Spot-check (orchestrator-only).** Run `git diff --stat` and
`git status --porcelain`. Confirm:
- Only the expected files changed (no stray edits).
- No deletions or renames (Operational rule 9 — fix-group agents
  may not delete or rename; broader principle for build agents
  too unless the design plan calls for it).
- Diff size is in the expected range.

If the diff doesn't match intent, skip verify and go to (5) —
diagnose, then re-dispatch. A wasted build burns a cycle.

**4. Verify.** Two layers:

- **Mechanical.** Run `bash test/smoke.sh` from the worktree root.
  Expected: `smoke: PASS (N assertions)` where N matches the
  stage's expected delta (see §3). The build agent may run smoke
  itself and report the result inline; the orchestrator
  re-confirms before committing.
  - **Baseline at start of stage set:** `smoke: PASS (260
    assertions)` on a clean working tree at branch `writing-issues`
    HEAD. (First-run smoke can flake at VR-1 due to uv's
    "Installed N packages" message leaking into stdout — same
    class as the PR-1 flake documented at
    `plans/stage-4-fragment-shrink-execution.md` 2026-04-23T05:10Z.
    Re-run once before treating any pre-AF-* assertion as a real
    regression.)
- **Semantic.** Dispatch a separate `general-purpose` reviewer
  agent with: the stage's success criteria + the working-tree
  diff (`git diff` output) + the design-plan section. The reviewer
  reads the diff itself; do **not** pass the build agent's
  self-report — that would let the builder grade its own homework.
  Reviewer returns `CLEAN` or a bulleted finding list with
  `severity` (`blocker` / `major` / `minor`) + file:line +
  description.

**5. Decide.**
- **CLEAN + smoke matches expected:** proceed to (6).
- **`minor` only, cycle ≥ 2:** orchestrator judges accept-or-fix.
  Accept = commit + log the minor findings in §4. Fix = another
  cycle.
- **`blocker` or `major`:** another cycle with findings as
  context. Increment cycle count.
- **Cycle 3 still unclean:** halt, write `BLOCKED` in §4 with the
  accumulated failure + diagnosis, escalate to user with a
  concrete choice (revert / replan / adjust verify).

**6. Commit (orchestrator-only, per CLAUDE.md Git Safety Protocol).**
- Stage only expected files (`git add <specific paths>`, never
  `-A` / `.`).
- Use `git commit -F <msgfile>` (not `-m "…"`) with the commit
  message template from §3 for this stage.
- Trailer: `Co-Authored-By: Claude Opus 4.7 (1M context)
  <noreply@anthropic.com>`.
- Never amend; always new commits.

**7. Update ledger.** Edit §4: append a log entry (timestamp,
stage ID, cycles taken, commit SHA, smoke delta, any minor
findings accepted), advance the cursor.

### Edge cases

- **Stage that doesn't add smoke assertions (Stage 1).** Verify
  is purely "smoke baseline unchanged" + reviewer CLEAN on the
  diff — no new assertion expected.
- **Stage that depends on a prior stage's helper (Stage 2 needs
  Stage 1's `finding_validator()`).** The cycle's reload step
  must read both the design plan section AND the prior stage's
  committed code; the build agent shouldn't re-derive the helper
  signature from the plan when the actual code is on HEAD.
- **Smoke flakes.** `parse-with-repair.py` PR-1 has been observed
  to flake on first invocation when uv prints "Installed N
  packages" into stdout. Re-run smoke once before treating as a
  blocker. Documented at `plans/stage-4-fragment-shrink-
  execution.md` ledger entry 2026-04-23T05:10Z.
- **Stage 4 fragment edit affects orchestrator-context discipline
  for Phase 1 itself.** Stage 4 changes the live behavior of
  `/adamsreview:review` Phase 1 join. Manual end-to-end fault-
  injection (per design plan §"Testing plan" items 2–6) is OUT of
  scope for the orchestrator run — those are post-merge manual
  validation. Stage 4 verify covers smoke + reviewer CLEAN +
  PF-INT-4 marker triple update.

---

## §3 — Stage manifest

Four stages, mapping to the four commits in
`plans/batched-add-findings.md` §"Sequencing". Stages 1–3 are pure
additions (the new mode is unused until Stage 4); Stage 4 changes
Phase 1 behavior in the wild.

Stages 1, 2, 3 touch disjoint files; Stage 1 must land before
Stage 2 (Stage 2 imports `finding_validator` / `validate_finding` /
`EXIT_ALL_REJECTED` from `_common`). Stage 3 depends on Stage 2's
`--add-findings` mode being callable (smoke assertions invoke it).
Stage 4 depends on all three. **Sequential by default — do NOT
parallelize.** The dependency chain is real.

### Stage 1 — `bin/_common.py` additions

- **Maps to:** design plan §3 step 1 (Concrete changes §1).
- **Goal:** add the building blocks — `EXIT_ALL_REJECTED = 7`
  constant, `finding_validator()` factory, and
  `validate_finding(finding, validator)` — without wiring them
  into any caller. Validator must be a hoisted, pre-built shape
  (not rebuilt per finding).
- **Files (only these):**
  - `bin/_common.py` (additions only — do not modify existing
    constants, factories, or helpers).
- **Steps:**
  1. Reload `plans/batched-add-findings.md` §"1. `bin/_common.py`"
     (lines ~116–207 of the design plan).
  2. Add `EXIT_ALL_REJECTED = 7` constant in the exit-code block
     (`bin/_common.py` lines ~23–32). Keep the existing comment
     style.
  3. Add `finding_validator()` mirroring
     `validation_result_validator()` (use the `Registry` /
     `Resource` / `DRAFT202012` pattern). Build the Draft202012
     validator bound to `#/$defs/finding`.
  4. Add `validate_finding(finding, validator)` that takes the
     pre-built validator and returns a list of
     human-readable error strings (empty list on valid).
  5. Do NOT add `finding_property_keys()` — design plan T2
     explicitly drops it; the schema validator catches
     `additionalProperties: false` at every depth.
- **Verify:**
  - `bin/artifact-patch.py --help` runs cleanly (any syntax
    error in `_common.py` would break the import `artifact-
    patch.py` does at module load — sufficient smoke that the
    additions parse).
  - Inline runtime check (uv-shebang to inherit jsonschema +
    referencing deps; system `python3` may not have them):
    ```
    bin/artifact-patch.py --path /tmp/never --add-finding '{}' 2>&1 | head -1
    ```
    Should error-as-prompt (validation failure on the empty
    object), proving `_common.py` is importable. The new symbols
    aren't exercised yet — Stage 2 wires them.
  - Smoke unchanged at 260 assertions (no new AF-* yet).
  - Reviewer CLEAN on diff: only `bin/_common.py` modified;
    additions only; no rebuilt validator inside any function
    (the factory is the hoist point); `EXIT_ALL_REJECTED = 7`
    placed beside the existing `EXIT_*` block; both new
    functions have docstrings matching the plan.
- **Rollback after 3 unclean cycles:** revert the stage's commit
  with `git revert <sha>`, halt, escalate.
- **Commit message:**
  ```
  bin/_common.py: add EXIT_ALL_REJECTED + finding_validator() + validate_finding() for batched --add-findings
  ```

### Stage 2 — `bin/artifact-patch.py` `--add-findings` mode

- **Maps to:** design plan §3 step 2 (Concrete changes §2).
- **Goal:** add the new `--add-findings` mode end-to-end — CLI
  plumbing in `build_parser()`, dispatch in `main()`, the
  `cmd_add_findings(args)` function, the `_check_add_finding_shape`
  preflight, and the `_emit_rejection` formatter. Continue-on-error
  per-finding; single atomic write across the accepted batch.
  T7's exit-code policy is the contract (0 / 1 / 7 / 64 — see
  the docstring).
- **Files (only these):**
  - `bin/artifact-patch.py` (additions + 3 CLI-text spots per T4:
    top-of-file module docstring, `build_parser()` mode-group
    entry, `parser.error("no mode selected ...")` string).
- **Steps:**
  1. Reload `plans/batched-add-findings.md` §"2. `bin/artifact-
     patch.py`" (lines ~209–480 of the design plan), with
     particular attention to T6 (batch-level err_prompt on
     all-rejected), T7 (exit-code policy aligned with code), R3
     (single-line per-rejection — no err_prompt block per drop),
     R4 (10-with-overflow on schema_errors).
  2. Add `cmd_add_findings(args)` exactly as specified in the
     plan — including the all-rejected `c.err_prompt(...)` block
     before the summary line (T6) and the `_write_and_emit`
     post-write defense-in-depth.
  3. Add `_check_add_finding_shape` and `_emit_rejection`
     helpers in the same file, in proximity to existing
     `_check_*_tuple` helpers (alphabetical / existing-pattern
     placement is fine).
  4. CLI plumbing: `build_parser()` mode-group entry; `main()`
     dispatch slotted **immediately after** the existing
     `--add-finding` (singular) block, **before**
     `--delete-finding`; mode-conflict guard rejects
     `--set` / `--set-json` / `--append-fix-attempt` /
     `--finding-id`; `--dry-run` rejected for the minimum version.
  5. Update T4's three CLI-text spots: top-of-file module
     docstring (the mode list), the `parser.error("no mode
     selected ...")` string, and the new `--add-findings` argparse
     entry's help text.
- **Verify:**
  - `bin/artifact-patch.py --help` lists `--add-findings` in the
     mutually-exclusive mode group.
  - `bin/artifact-patch.py --path /tmp/never` (path required by
     argparse, no mode) prints the updated "no mode selected"
     error string and the list now includes `--add-findings`.
  - **Exit-code spot-check:** verify mode-conflict actually
     returns 64 (`EXIT_USAGE`), not argparse's default 2.
     Argparse's `parser.error()` calls `sys.exit(2)` by default;
     the design plan T7 spec says 64. The build agent must
     either (a) raise via `sys.exit(c.EXIT_USAGE)` directly for
     mode conflicts, or (b) subclass `ArgumentParser` to override
     `error()`. Test via:
     `bin/artifact-patch.py --path /tmp/never --add-findings '[]'
     --finding-id F001 ; echo $?` → expect `64`.
  - Smoke unchanged at 260 assertions (Stage 3 adds the AF-*
     assertions — this stage just wires the helper).
  - Reviewer CLEAN on diff: only `bin/artifact-patch.py` modified;
     all three T4 spots updated (top-of-file docstring mode list,
     `build_parser()` mode-group entry, `parser.error("no mode
     selected ...")` string); T6 err_prompt present on
     all-rejected path; exit codes match the docstring (0 / 1 /
     7 / 64) — including mode-conflict actually emitting 64.
- **Rollback after 3 unclean cycles:** revert this stage's commit;
  Stage 1's commit may stay (pure additions, harmless).
- **Commit message:**
  ```
  bin/artifact-patch.py: add --add-findings batched mode (continue-on-error, single atomic write)
  ```

### Stage 3 — `test/smoke.sh` AF-1..AF-7 + AF-DRIFT

- **Maps to:** design plan §3 step 5 (Concrete changes §5,
  excluding the PF-INT-4 update which lands in Stage 4 because
  the markers it greps for don't appear until the fragment is
  migrated).
- **Goal:** add seven `AF-*` smoke assertions plus `AF-DRIFT`
  exercising the new `--add-findings` mode end-to-end. AF-5
  (defense-in-depth post-write) is **deferred** per design plan
  Section 5 — no real fixture to construct. AF-DRIFT requires
  factoring out the in-jq `fam_canonical` table; pick the simpler
  paste-duplicate-with-pointer approach from §5 unless the
  reviewer surfaces a maintenance argument for `bin/fam_canonical.jq`.
- **Files (only these):**
  - `test/smoke.sh` (additions only — do not rewrite existing
    assertions; AF-* is a new family appended at the appropriate
    spot, matching the existing OC-*/FR-*/RH-*/FX-*/MP-*/WT-*
    placement convention).
- **Steps:**
  1. Reload design plan §"5. `test/smoke.sh` — AF-1..AF-7 + AF-
     DRIFT, plus PF-INT-4 update" (lines ~810–944 of the design
     plan). PF-INT-4 update is Stage 4's, not this stage's.
  2. Add AF-1 (happy path, 3 valid findings, exit 0, on-disk
     state matches).
  3. Add AF-2 (mixed batch with R5 nested-key coverage —
     top-level `extra_field`, nested
     `validation_result.blast_radius.extra_subkey`, and
     `duplicate_id` — verify two `schema_invalid` lines + one
     `duplicate_id` line in stderr; exit 0; only #1 and #4 land).
  4. Add AF-3 (all-bad, exit 7 = `EXIT_ALL_REJECTED`, T6: stderr
     contains the batch-level `ERROR:` / `Action:` block from
     `c.err_prompt`).
  5. Add AF-4 (stdin via `printf | --add-findings -` matches
     AF-1 on-disk state).
  6. Skip AF-5 (defense-in-depth) — Section 5 marked contingent;
     no real fixture exists.
  7. Add AF-6 (empty array `[]` → exit 0, "added 0 findings", no
     stderr).
  8. Add AF-7 a/b/c (usage errors → exit 64): non-array JSON,
     unparseable JSON, mode conflict.
  9. Add AF-DRIFT (drift-table agreement between
     `bin/source-family-map.py` and the in-jq table). Implement
     using paste-duplicate of the in-jq `fam_canonical` from
     Stage 4's fragment text (the smoke is the verification
     boundary). NOTE: AF-DRIFT depends on the fragment-side
     `fam_canonical` text existing — the simplest sequencing is
     to extract the jq table to `bin/fam_canonical.jq` in
     Stage 4 OR to land AF-DRIFT in Stage 4 alongside the
     fragment. **Decision: land AF-DRIFT in Stage 3 with a
     placeholder table mirroring the design plan's listing** —
     Stage 4's fragment text is fully specified by the design
     plan (lines ~612–627), so the smoke can paste the same
     table without waiting on the fragment. If Stage 4 deviates
     during implementation, AF-DRIFT will fail and force them
     back into sync — that's the point.
- **Verify:**
  - Smoke passes at 260 + 9 = **269 assertions** (AF-1, AF-2,
    AF-3, AF-4, AF-6, AF-7a, AF-7b, AF-7c, AF-DRIFT — AF-5
    deferred). If the count comes in higher, AF-DRIFT may have
    been split into per-key assertions — re-read the diff and
    confirm the structure matches the design plan's
    implementation sketch (single loop, single fail-on-first-
    divergence — one assertion total).
  - Each AF-* assertion line PASSes individually in the smoke
    output (visual scan of the smoke run, not just the final
    count).
  - Reviewer CLEAN on diff: only `test/smoke.sh` modified; 9 new
    assertions in a contiguous AF-* block; each verifies stdout
    shape + on-disk state via `artifact-read.sh --filter
    '.findings | map(.id)'` (or equivalent); AF-3 stderr-greps
    for the err_prompt block.
- **Rollback after 3 unclean cycles:** revert this stage's
  commit; Stages 1–2 stay (the helper still works without
  smoke coverage).
- **Commit message:**
  ```
  test/smoke.sh: AF-1..AF-7 + AF-DRIFT for batched --add-findings
  ```

### Stage 4 — Fragment migration + cross-references

- **Maps to:** design plan §3 step 3 + step 4 + step 5's
  PF-INT-4 update (Concrete changes §3, §4, and the tail of §5).
- **Goal:** switch the Phase 1 join site to the new batched
  mode. This is the stage that delivers the orchestrator-context
  win and the only stage that changes live `/adamsreview:review`
  behavior.
- **Files (only these):**
  - `fragments/01-detection.md` (replace the per-candidate loop
    in §1.5 step 4; update the §1 overview prose per T10;
    add the T9 single-Bash-invocation note; extend Phase 1.6's
    summary grep to include the three new structural-failure
    counters).
  - `bin/source-family-map.py` (one-line cross-reference in the
    module docstring pointing to `fragments/01-detection.md`
    §1.5 step 4 — see design plan §3 step 3 last paragraph).
  - `CLAUDE.md` (helper index `artifact-patch.py` row + op
    rule 3 + batched-helper pattern paragraph — design plan §4).
  - `test/smoke.sh` (PF-INT-4 marker triple update per T11 —
    `fam_canonical` + `--add-findings` + `lens_source_family_unknown`).
- **Steps:**
  1. Reload design plan §"3. `fragments/01-detection.md`" (lines
     ~482–788 of the design plan), §"4. `CLAUDE.md`" (lines
     ~789–809), and §"5." PF-INT-4 update (lines ~916–940).
  2. Replace `fragments/01-detection.md` §1.5 step 4 bash block
     (current shell `while`-loop, lines ~966–1007) with the
     new batched bash block (design plan lines ~579–751).
     Specifically:
     - Single `jq` invocation building `findings` + `drift`
       arrays; type-guarded `fam_canonical($raw)` per T8;
       gsub-strip + ascii_downcase + canonical/drift/null
       branches.
     - `expected_n` / `built_n` count check with
       `phase_1_jq_builder_count_drop:` audit tag.
     - Drift-line append to `$trace_log_path`.
     - Synchronous tempfile stderr capture per T1 (NOT
       process-substitution `tee`); drain to trace.md and
       re-emit on stderr.
     - `phase_1_add_findings_failed:` + total-failure
       (`phase_1_add_findings_total_failure:`) tags per R2.
     - Cleanup: `rm -f "$stderr_capture"`.
  3. Update §1.5 step 4 prose:
     - Replace the per-candidate retry-once paragraph with the
       continue-on-error contract.
     - Note `--add-finding` (singular) is still supported.
     - Extend Phase 1.6's summary grep to surface the three new
       counters: `add_findings_rejected`,
       `jq_builder_count_drops`, `add_findings_total_failures`.
  4. Update §1 overview prose at fragment-top (T10): the
     "one call per candidate to `artifact-patch.py
     --add-finding`" sentence becomes "single batched
     `artifact-patch.py --add-findings` call (see §1.5 step 4)".
  5. Add the T9 execution note to §1.5 (steps 3 and 4 must run
     in one Bash invocation; scratch-file fallback if the
     orchestrator splits).
  6. Add the one-line cross-reference to
     `bin/source-family-map.py`'s module docstring pointing
     readers at `fragments/01-detection.md` §1.5 step 4 for
     the second drift-table site.
  7. Update `CLAUDE.md`:
     - Helper index `artifact-patch.py` row: add
       `--add-findings` to the mode list with the
       continue-on-error / single-atomic / exit 7 parenthetical.
     - Operational rule 3: append `7=all-rejected (--add-
       findings: every input element was rejected at preflight)`.
     - "Batched-helper pattern" section: append the
       continue-on-error vs. first-fail-halt distinction
       paragraph.
  8. Update `test/smoke.sh` PF-INT-4 marker triple:
     `canonical_family="unknown"` → `fam_canonical`; add
     `--add-findings` marker; keep `lens_source_family_unknown`.
     Update the assertion's pass/fail message to match.
- **Verify:**
  - Smoke passes at 269 assertions (Stage 3's count). PF-INT-4
    PASSes (markers present in the migrated fragment); AF-*
    block still all-PASS. **The stage must NOT introduce ANY
    new failures.**
  - Reviewer CLEAN on diff. Reviewer's brief includes:
    blast-radius checks (every consumer of the old loop —
    Wave 2 and `/adamsreview:add` should be UNTOUCHED, not
    silently migrated; `--add-finding` singular still works);
    stale-comment scan inside the migrated bash block; T1
    correctness (synchronous stderr capture, no race against
    immediate grep); T8 type-guard against non-string
    `source_family`; T9 single-Bash-invocation note present.
  - **Manual eyeball (orchestrator):** read the new bash block
    end-to-end; confirm shell quoting + `printf '%s'` usage
    matches the rest of the fragment; confirm `$trace_log_path`
    / `$artifact_path` / `$ided` / `$trivial_mode` shell
    variables resolve to Phase-0/Phase-1 working-set values
    (per CLAUDE.md operational rule 11).
- **Rollback after 3 unclean cycles:** revert THIS stage's
  commit. Stages 1–3 stay landed (the helper + smoke coverage
  remain valuable even without the fragment migration).
- **Commit message:**
  ```
  fragments/01-detection: switch Phase 1 join to batched --add-findings (in-jq fam_canonical, T1/T8/T9/T10/T11)
  ```

### Post-execution once-over (orchestrator)

After Stage 4 commits, dispatch in a single message with two
parallel review agents (per orchestrate skill §5):
- `general-purpose` reviewer on the cumulative diff
  (`git diff main..HEAD`) — bugs, edge cases, callers untouched,
  stale comments, missed plan steps. Brief includes the design
  plan's "Risks and what we've done about them" section so the
  reviewer can verify the documented risks are still mitigated
  in the landed code.
- `coderabbit:code-reviewer` (if present in available agent
  types) — second-opinion pass. Skip silently if absent (don't
  fail the orchestrator run).

Synthesize: dedup, treat reviewer disagreements as direct-
inspection signals, decide fix-vs-flag-vs-defer per finding.
Mechanical fixes → sub-agent dispatch. Cross-file judgment →
orchestrator inline. Fix in the same turn unless out of scope.

Final report includes:
- Stages completed + commit SHAs.
- Smoke delta (expected: `260 → 269`; deviation requires
  explanation in the report).
- Once-over findings resolved vs. deferred.
- Anything flagged for the user (post-merge manual fault-
  injection per design plan testing-plan items 2–6 is
  explicitly out of scope for this run; the report should
  hand back to the user with a short list of what to run
  manually before/after merging).

---

## §4 — Progress ledger

**Next pending stage:** `Stage 1`

### Log

*(Append one entry per completed stage. Format:
`[YYYY-MM-DDTHH:MMZ] <stage-id> cycles=<n> commit=<sha>
smoke=<before>→<after> notes=<...>`)*

*(empty — orchestrator populates as stages complete.)*

---

## §5 — Constraints and known flakes

**Smoke baseline.** `smoke: PASS (260 assertions)` at branch
`writing-issues` HEAD on a clean working tree. Stages 1, 2 keep
this. Stage 3 takes it to 269. Stage 4 holds at 269 (PF-INT-4 is
an in-place marker swap, not a new assertion).

**First-run uv flake.** smoke can fail at VR-1 (or PR-1, or any
assertion that shells to a uv-invoked Python helper) on the FIRST
invocation in a fresh shell, when uv prints "Installed N
packages" into the helper's stdout. **Always re-run smoke once
before treating any failure as real.** Documented at
`plans/stage-4-fragment-shrink-execution.md` 2026-04-23T05:10Z.
On a second consecutive run, smoke at this branch HEAD passes
all 260 assertions (verified 2026-04-26).

**Working-tree state at start.** `git status` shows two
untracked files:
- `plans/batched-add-findings.md` (design plan, untracked).
- `plans/batched-add-findings-execution.md` (this file).

The orchestrator operator should commit both BEFORE starting the
run so the plan + journal are reproducible from git, and so
Stage 1's diff is purely the helper additions. Do this in one
commit:
```
plans: add batched-add-findings design + execution journal
```

**Branch + worktree.** Work happens in
`.claude/worktrees/writing-issues` on branch `writing-issues`.
Do not `cd` to the original repo root. Final stage's commit
should be pushed by the orchestrator only with explicit user
approval — orchestrator hands back to the user for that.

**Out of scope for this orchestrator run** (per design plan
"Out of scope (deferred)"):
- Wave 2 site migration (`fragments/05-validation.md` step 4.5).
- `/adamsreview:add` step 6 migration.
- Lens scratch-file refactor.
- Pushing schema-shape jq into the helper.

These are forward-looking work items; do not let scope creep
into them mid-stage.

**Manual end-to-end + fault-injection** (design plan
testing-plan items 2–7) are post-merge validation, not
orchestrator-run verify. The orchestrator's verify is smoke +
reviewer CLEAN + spot-check. Manual fault-injection runs after
the user merges to `main` (or chooses to defer).
