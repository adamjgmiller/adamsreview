# Stage 4 execution journal

Execution protocol, step manifest, and progress ledger for `plans/stage-4-fragment-shrink.md`. Designed so the session can be `/clear`-ed between steps and resumed by pasting the prompt below.

**Pre-reqs:** the plan file has been approved by the user. This file is the authoritative state for execution; the plan file is the authoritative state for design.

---

## Paste prompt (copy verbatim after `/clear`)

```
Resume Stage 4 fragment shrink execution.

1. Read plans/stage-4-fragment-shrink-execution.md — follow §1 (usage), §2 (protocol), and §4 (ledger; start from the "Next pending step" cursor).
2. Read plans/stage-4-fragment-shrink.md — design.
3. Populate TaskCreate with all remaining steps from §3's manifest (status: pending).
4. Execute per §2's loop. Stop when all steps are done or you need user input. Do NOT commit amendments — commit new commits only, per CLAUDE.md Git Safety Protocol.
```

---

## §1 — How to use

**On resume.** Read this file + the design plan + `CLAUDE.md`. The cursor in §4 identifies the next pending step. If §4's cursor says `COMPLETE`, the stage is closed — nothing to do. If `BLOCKED`, the last step paused for user input; read the blocker note before doing anything.

**During execution.** Every step runs under §2's build→review loop. After a step commits cleanly, update §4's ledger (append a log entry + advance the cursor) in the same commit or in an immediate follow-up commit. Use TaskCreate for in-session progress; the §4 ledger is the cross-session durable truth.

**When stuck.** Pause, write a `BLOCKED` entry in §4 with the reason, report to the user, and stop. Do not force a commit past a failing smoke or a 3-round-unclean review.

---

## §2 — Execution protocol

Each step runs this loop. Max **3 build→review rounds** per step; after round 3 unclean, pause and escalate.

### Per-step loop

**1. Reload context.** Read the plan, this file's §3 for the step's scope + success criteria, and any `CLAUDE.md` sections that apply to the step's files.

**2. Build round (sub-agent dispatch — fresh Opus).**

Use `Agent` tool with `subagent_type: "general-purpose"` and `model: "opus"`. Each round is a separate `Agent` invocation — no memory carries across rounds; the next build agent gets prior-round review findings via its prompt. Prompt must include:
- The step ID + name + exact scope from §3.
- Success criteria from §3 (verbatim).
- Relative paths of files to touch (absolute paths in the agent's environment).
- Blast-radius discipline (from CLAUDE.md §Blast-radius discipline): every writer, every consumer, parallel code paths, full function bodies, stale comments. "Trace the blast radius before you change anything."
- Constraint: **purely representational, no behavior change** (exception: the 4.0 investigation step produces no diff).
- Instruction: **do not commit**. Leave changes in the working tree.
- Findings from prior rounds (if round > 1) — paste the review agent's finding list verbatim into the prompt.

**3. Verify shape.** After the build agent returns, run:
- `git status --porcelain` — confirm only expected files changed, no deletions/renames (Operational rule 9).
- `git diff --stat` — confirm line counts are roughly in the expected range.

**4. Review round (sub-agent dispatch — fresh Opus, separate invocation from the build).**

Use `Agent` tool with `subagent_type: "general-purpose"` and `model: "opus"`. Must be a *new* `Agent` invocation — a fresh Opus context with no memory of the build round's reasoning. This is the whole point: the reviewer forms an independent judgment from the diff + success criteria alone. Prompt must include:
- The step's success criteria verbatim.
- Explicit criteria: behavior neutrality, no lost invariants, smoke assertions present where required, CLAUDE.md Helper index row present for new helpers, stale comments/docs updated.
- Instruction: read the working-tree diff via `git diff`, compare against success criteria, return either `CLEAN` or a bulleted list of findings with `severity` (`blocker` / `major` / `minor`) + file:line + description.
- Do **not** pass the build-agent's self-report into the reviewer's prompt — reviewer reads the diff itself. Passing the build agent's summary would leak its reasoning and defeat the independent-review purpose.

**5. Decide.**
- **CLEAN:** proceed to step 6.
- **`minor` findings only, round ≥ 2:** orchestrator judges whether to accept or fix. Accept = commit + log the minor findings in §4. Fix = another build round.
- **`blocker` or `major` findings:** another build round with findings as context. Increment round counter.
- **Round 3 still unclean:** pause, write `BLOCKED` in §4, escalate to user.

**6. Smoke.** Run `test/smoke.sh`. Expected: `smoke: PASS (N assertions)` with N ≥ prior baseline (helper-extraction steps add 2–3 new assertions each).
- Smoke fail = treat as a blocker finding. Another build round with the smoke output as context, or escalate if round 3.

**7. Commit.** Per CLAUDE.md Git Safety Protocol:
- Stage only expected files (`git add <specific paths>`, never `-A` / `.`).
- Commit with `git commit -F <msgfile>` (not `-m "…"`) using the commit-message template from §3 for this step.
- Never amend — always new commits.
- Trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

**8. Update ledger.** Edit §4: append a log entry (timestamp, step ID, rounds taken, commit SHA, any `minor`-findings accepted), advance the cursor to the next pending step. Commit the ledger update in the same commit as the step if trivially feasible, otherwise as an immediate follow-up commit.

**9. Measurement (when applicable).** For prose-compression steps (4.B.*) and the close-out, update Appendix B in the plan file with fresh char/line counts for the affected files.

### Edge cases

- **4.0 investigation step.** No diff produced — instead, Appendix A in the plan file gets populated. Build round: do research + write Appendix A. Review round: verify all three options (a/b/c) considered, decision is present with rationale, Appendix A is complete. No smoke test needed; commit the plan-file update.
- **Conditional step (4.A.4 finding-builder.py).** Step's first action is the verification check: is step 1.4 still ~40 lines of jq not already absorbed by `parse-with-repair.py` et al.? If NO, mark step `SKIPPED` in §4 with rationale and advance cursor — no build/review/commit cycle. If YES, proceed normally.
- **Smoke growth.** New helpers add 2–3 OC-*/FR-*/RH-*/FX-*/MP-*/WT-*-style assertions. Review round must verify those assertions exercise the helper's happy path + at least one failure mode.
- **Blast-radius caught mid-step.** If build-agent discovers a second file needs touching mid-step (e.g., a caller that breaks without an update), expand the step's scope in-place (document the expansion in the ledger entry), not a new step.

---

## §3 — Step manifest

Ordered list of every step. Each step's "Success criteria" is what the review leg evaluates against.

### 4.0 — `!include` ceiling investigation

- **Scope:** populate `plans/stage-4-fragment-shrink.md` Appendix A with findings + chosen structural response (a/b/c).
- **Action:** web research first (WebSearch / WebFetch on Claude Code docs + `anthropics/claude-code` GitHub issues for slash-command `!` preprocessor output caps, truncation behavior, `!`include-pattern`` limits). Manual reproduction only if research is inconclusive (test command with progressively larger `!include`-d fragments, bisect to ceiling).
- **Success criteria:**
  - Sources consulted documented in Appendix A.
  - Observed behavior documented (what triggered the 2026-04-22 truncation).
  - Root-cause / ceiling characterized (per-invocation cap? cumulative? bash-subprocess output limit? other?).
  - Choice of (a) / (b) / (c) with explicit rationale recorded.
- **Smoke:** not applicable (no code diff).
- **Commit message:** `plans/stage-4-fragment-shrink: Appendix A — !include ceiling investigation + decision (a/b/c)` (substitute chosen letter).

### 4.A.1 — Extract `freshness-gate.sh`

- **Scope:** `fragments/00-preflight.md` step 0.2a (~80 lines of bash across lines ~77–184) → new `bin/freshness-gate.sh`.
- **Helper contract:** flags `--base-branch` / `--head-branch`; stdout is JSON `{comparison_ref, base_freshness, remote_sha, behind_count, preflight_warnings[]}`; `base_freshness ∈ {fresh, fast_forwarded, used_remote_ref, proceeded_stale, no_remote, no_fetch}`. `AskUserQuestion` dispatch stays orchestrator-side (helper returns the behind-count case as JSON; orchestrator decides what to ask).
- **Success criteria:**
  - `bin/freshness-gate.sh` exists, bash-3.2 portable, `set -euo pipefail`, `--help`, error-as-prompt stderr on non-zero exit, exit codes from `bin/_common.py` conventions.
  - Fragment step 0.2a reduced to ≤15 lines (helper invocation + AskUserQuestion branching).
  - 2–3 smoke assertions added covering: happy path (clean remote, no behind), no-remote case, fetch-failure case.
  - CLAUDE.md Helper index gets a row for `freshness-gate.sh`.
  - No changes outside `fragments/00-preflight.md`, `bin/freshness-gate.sh`, `test/smoke.sh`, `CLAUDE.md`.
- **Smoke:** `test/smoke.sh` passes; assertion count +2 or +3.
- **Commit message:** `bin/freshness-gate.sh: extract Phase 0.2a freshness reconciliation into helper`.

### 4.A.2 — Extract `trivial-check.sh`

- **Scope:** `fragments/00-preflight.md` step 0.11 → new `bin/trivial-check.sh`.
- **Helper contract:** flags `--files` (newline-separated stdin or repeated flag) + `--lines-changed <N>` + `--num-files <N>`; stdout is JSON `{trivial_mode, reason}`; `reason ∈ {docs_only, tests_only, small_patch, ...}` or null when not trivial.
- **Success criteria:**
  - Helper exists; bash-3.2; error-as-prompt; exit-code contract.
  - Fragment step 0.11 reduces to ≤10 lines.
  - 2–3 smoke assertions: trivial docs-only case, non-trivial mixed case, empty-diff edge case.
  - CLAUDE.md Helper index row.
- **Smoke:** smoke passes; assertion count +2 or +3.
- **Commit message:** `bin/trivial-check.sh: extract Phase 0.11 trivial-diff classification into helper`.

### 4.A.3 — Extract `artifact-seed.sh`

- **Scope:** `fragments/00-preflight.md` step 0.15 (48-line `jq -n --argjson …` block starting at line 517) → new `bin/artifact-seed.sh`.
- **Helper contract:** takes Phase-0 outputs as `--review-id`, `--review-started-at`, `--reviewed-sha`, `--base-branch`, `--head-branch`, `--mode`, `--pr-state`, `--pr-number`, `--comment-id`, `--trivial-mode`, `--base-context <json>`, `--reviewed-files-all <newline-sep>`, `--claude-md-paths <newline-sep>`, `--files-changed`, `--lines-changed`; stdout is the schema-shaped seed JSON; `artifact-patch.py --init -` consumes unchanged.
- **Success criteria:**
  - Helper exists; shape matches current schema (validate against `bin/schema-v1.json`).
  - Fragment step 0.15 reduces to ≤15 lines (helper invocation piped to `artifact-patch.py --init -`).
  - 2–3 smoke assertions: happy path matches reference output; missing-required-arg failure; invalid JSON in `--base-context` failure.
  - CLAUDE.md Helper index row.
- **Smoke:** smoke passes; assertion count +2 or +3.
- **Commit message:** `bin/artifact-seed.sh: extract Phase 0.15 artifact seed construction into helper`.

### 4.A.4 — (conditional) Extract `finding-builder.py`

- **Scope:** `fragments/01-detection.md` step 1.4 list-step-3 jq-builder → new `bin/finding-builder.py` (only if verification below passes).
- **Verification (first action):** read `fragments/01-detection.md` step 1.4 list-step-3; if still ~40 lines of cohesive jq not already delegated to `parse-with-repair.py` / `parse-validator-result.py` / `source-family-map.py`, proceed. Otherwise mark `SKIPPED` in §4 ledger with a short note.
- **Helper contract (if proceeding):** Python, uv-shebang; flags `--lens <L1..L7>`, `--candidate <json>`, `--counter-state <json>`; stdout is the schema-shaped finding; exit 2 on validation failure with error-as-prompt stderr.
- **Success criteria:**
  - Either: helper exists, fragment reduces to ≤10 lines at the extraction point, 2–3 smoke assertions added, CLAUDE.md Helper index row present.
  - Or: `SKIPPED` recorded in §4 with rationale.
- **Smoke:** if proceeding, smoke passes with assertion count +2 or +3; if skipped, smoke unchanged.
- **Commit message (if proceeding):** `bin/finding-builder.py: extract Phase 1.4 finding construction into helper`. (If skipped, no commit — ledger entry only.)

### 4.B.1 — Prelude consolidation across 5 commands

- **Scope:** `commands/{review,fix,walkthrough,add,promote}.md` prelude sections + the abbreviated duplicates inside fragments.
- **Action:** identify prose that is semantically identical across ≥3 command preludes (sub-agent dispatch pattern, working-set rules, effort-is-session-wide). Consolidate into one shared block; reference it by name from each command. Prefer `!include fragments/_prelude-shared.md` (new fragment) if 4.0 chose (a)/(b); for (c) manifest style, use an explicit `Read` pointer.
- **Success criteria:**
  - Consolidation yields a shared block + trimmed preludes across all 5 commands.
  - No semantic change: each consolidated rule is preserved in the shared block.
  - Review leg verifies the before/after prose communicates the same instructions (sample 2 rules and check they still fire).
  - smoke passes; assertion count unchanged (or +1 if consolidation deserves a sanity assertion).
- **Smoke:** passes.
- **Commit message:** `fragments/_prelude-shared.md: consolidate command preludes`.

### 4.B.2 — L1–L7 lens-prompt invariant extraction

- **Scope:** `fragments/01-detection.md` step 1.3 lens-dispatch prompts.
- **Action:** identify per-lens repeated scaffolding ("Read ONLY the diff between `$comparison_ref` and HEAD…", "Return a JSON array of candidates…", etc.) and move invariants into step 1.2's shared input block. Per-lens prompts retain only lens-specific guidance.
- **Success criteria:**
  - Each lens prompt reduced to only lens-specific content.
  - Shared input block gains the extracted invariants (marked as shared).
  - Review verifies no lens-specific correctness cue lost (spot-check L2 structural + L5 security).
- **Smoke:** passes.
- **Commit message:** `fragments/01-detection: extract L1–L7 lens prompt invariants into shared input block`.

### 4.B.3 — `fragments/10-post-fix-and-commit.md` compression

- **Scope:** the full 56k / 1351-line fragment. Focus areas: Phase 9.pre / 9a / 9b / 9c structural repetition; commit-message templating duplication; trace-log boilerplate.
- **Action:** compress prose; extract any ~40+ line bash blocks into helpers opportunistically (no helpers required unless a clean block emerges).
- **Success criteria:**
  - ≥10% char reduction on this fragment (target, not gate).
  - No behavior change: Phase 9 ordering, reconcile branching, commit-message content all preserved.
  - Review verifies the overlap-guard (`[[ ${#overlap_files[@]} -gt 0 ]]`) and revert logic are unchanged.
- **Smoke:** passes.
- **Commit message:** `fragments/10-post-fix-and-commit: compress Phase 9 prose; preserve behavior`.

### 4.C — Lens-reference lazy load

- **Scope:** `fragments/lens-ux-reference.md` (3k chars) + `fragments/lens-security-reference.md` (1.8k chars).
- **Action:** load the UX reference only when L4 is in the lens-selection set (step 1.1); same for security reference when L5 runs. Implementation depends on 4.0's chosen structural response:
  - (a) `!include`: inline conditional removed; lens agent prompt reads the reference via `Read` only when that lens is dispatched.
  - (b) split: similar to (a), plus any orchestrator-side gating needed.
  - (c) manifest: each lens's `Read` list is already scoped; lens-reference file moves into the lens's own `Read` list.
- **Success criteria:**
  - When neither L4 nor L5 runs, neither lens-reference file is loaded into the review invocation.
  - When L4 runs but L5 doesn't (or vice-versa), only the relevant reference loads.
  - Review verifies lens-reference content is still reached when the corresponding lens dispatches.
- **Smoke:** new assertion `FR-LENS-REF-LAZY-*` covering the lens-selection → reference-load gating.
- **Commit message:** `fragments/lens-{ux,security}-reference: lazy-load by lens selection`.

### 4.Z — Close-out

- **Scope:** measurement snapshot, backlog update, CLAUDE.md Helper index final pass, plan Appendix B populated.
- **Action:**
  - Populate Appendix B in the plan file with before/after per-command and per-fragment char/line counts.
  - Update `plans/backlog.md` §2 items #2 and #14: mark Stage 4 closed with commit SHA range; add any deferred follow-ups (e.g., walkthrough/add self-contained prose compression) as fresh §3 entries.
  - CLAUDE.md Helper index final pass — verify every new helper has a row and each row is accurate.
  - §4 cursor here in the journal advances to `COMPLETE`.
  - Orchestrator's own post-execution once-over (per global CLAUDE.md): re-read the full commit range for this stage, check cross-step consistency, flag anything the per-step reviews might have missed.
- **Success criteria:**
  - Appendix B has real numbers, not placeholders.
  - backlog.md §2 and §3 coherent with post-stage reality.
  - CLAUDE.md Helper index complete.
  - once-over report appended to §4 ledger (findings or "nothing worth flagging").
- **Smoke:** final `test/smoke.sh` pass — record final assertion count.
- **Commit message:** `plans/stage-4-fragment-shrink: close-out — measurements, backlog updates, helper index`.

---

## §4 — Progress ledger

**Next pending step:** `4.A.1`

### Log

*(Append one entry per completed step. Format: `[YYYY-MM-DDTHH:MMZ] <step-id> rounds=<n> commit=<sha> notes=<...>`.)*

- `[2026-04-23T04:35Z] 4.0 rounds=1 commit=<pending> notes=Decision: (c) manifest-style command bodies. Research conclusive via Claude Code docs + GitHub #17944 (persist-to-disk threshold ignores BASH_MAX_OUTPUT_LENGTH post-v2.1.2, ~10 KB on current versions replaces preprocessor output with ~2 KB <persisted-output> preview). 7 fragments already over 10 KB. Seven fragments already over 10 KB makes (a) non-durable; (b) works mechanically but locks in !include long-term and doesn't help 4.C; (c) sidesteps the preprocessor and makes 4.C fall out trivially. Accepted review's 1 minor finding inline (stale §4.C prose framing (a)/(c) as live alternatives — rewrote to reference chosen (c) with Appendix A backref).`
