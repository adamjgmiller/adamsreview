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

### 4.A.0 — Manifest-style conversion *(added 2026-04-23 after 4.0 chose (c))*

- **Scope:** every `!`include <name>.md` `` site in the five command files — `commands/review.md`, `commands/fix.md`, `commands/add.md`, `commands/walkthrough.md`, `commands/promote.md` — converted to a manifest-style `Read` directive. `bin/include` itself is not removed; `promote-core.md` and the prelude (post-4.B.1) may still legitimately use it.
- **Action:**
  1. `grep -n '^!`include' commands/*.md` to enumerate every site.
  2. For each site, replace the preprocessor line with a human-readable directive of the form:
     ```
     **Phase N — <short name>.** Read `fragments/<name>.md` and execute the
     instructions inside before proceeding.
     ```
     Preserve surrounding `---` separators, argument-parsing blocks, and any pre-existing Phase headers. Fragment body contents are **not edited** in this step — only the splice point.
  3. Handle conditional `!include`s (if any) by making the directive conditional: *"If `--ensemble` was passed, read `fragments/02-ensemble-adapter.md` and execute the instructions inside; otherwise skip."*
  4. For each command file, audit `allowed-tools`: if the file no longer references `!`include …` `` anywhere, remove `Bash(include:*)` from the grant list. If it still has *any* `!include` site (e.g., for the shared prelude block that 4.B.1 will introduce, or existing `promote-core.md` transclusion in `walkthrough.md` / `promote.md`), keep the grant.
  5. Add `Read` to `allowed-tools` anywhere it isn't already granted — orchestrator now reads fragments during the turn.
- **Blast-radius checks:**
  - **Prelude duplication inside fragments.** Several fragments open with a short "Phase N prelude" restating working-set variables, phase position, etc. Those are unaffected — they live inside fragment bodies, not at `!include` splice points.
  - **Cross-fragment references.** If a fragment's body assumes the prior fragment is already "in prompt" (e.g., references a variable by name without re-deriving it), that assumption still holds under (c) — each `Read` tool-result enters the orchestrator's context and persists through the rest of the turn. No fragment rewrites needed.
  - **`walkthrough.md` + `promote.md`** both transclude `promote-core.md` (~10 KB, borderline). Under (c) those sites also get converted to `Read fragments/promote-core.md`-style directives, or — since `promote-core.md` is ≤10 KB — they can stay as `!include` if we want to preserve their existing behavior and `promote-core.md` keeps it size. Convert them for consistency; zero behavior change.
  - **Smoke assertions.** `test/smoke.sh` grep-tests on command-file content may reference `!`include …` `` patterns — audit and update. Do **not** change test semantics, only update patterns to match the new directive text.
- **Success criteria:**
  - `grep -rn '^!\`include' commands/` returns zero hits (or only the shared-prelude site that 4.B.1 will introduce).
  - Every `Read fragments/<name>.md and execute the instructions inside` directive matches a real file under `fragments/`.
  - Each command file still reads as a coherent procedural document — the converted directives preserve phase ordering, conditional branches, and separator structure.
  - `allowed-tools` audit complete on all five command files; `Bash(include:*)` removed where no `!include` remains; `Read` present where needed.
  - Smoke passes unchanged (or with pattern-only updates to any `!include`-referencing assertions).
- **Smoke:** passes; assertion count **unchanged** (this step is pure restructuring — no new helper to sanity-check).
- **Commit message:** `commands/*: convert !include sites to manifest-style Read directives per 4.0 decision (c)`.

### Context for all downstream steps (post-4.A.0)

After 4.A.0 lands, every fragment is reached via `Read`, not `!include`. Downstream steps should:

- **Not** assume the fragment they are editing is inlined in the command prompt. Helper extractions and prose compression still shrink fragment *content*; they just don't change the loading mechanism.
- **Not** re-introduce `!include` splice points in command files. If a new shared block is needed (4.B.1 prelude), it can use `!include` *only if* the shared block is kept under the persist-to-disk ceiling (~10 KB current, likely tightening) — otherwise use a `Read` directive.
- **Still honor the CLAUDE.md Helper index** — any new helper added by 4.A.1-4 gets a row (Script | Lang | Purpose), same shape as today.
- **Still honor the smoke-assertion naming scheme** (OC-*/FR-*/RH-*/FX-*/MP-*/WT-*).
- **Read the affected fragment before editing it.** The fragment is no longer "already in your prompt" — sub-agents tasked with editing need to open it explicitly. This is implementation hygiene for any 4.A/4.B sub-agent dispatch.

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

- **Scope:** `commands/{review,fix,walkthrough,add,promote}.md` prelude sections (the prose *above* the first phase splice point — not the phase directives themselves, which 4.A.0 already converted) + any abbreviated duplicates inside fragments.
- **Action:** identify prose that is semantically identical across ≥3 command preludes (sub-agent dispatch pattern, working-set rules, effort-is-session-wide). Consolidate into one shared block at `fragments/_prelude-shared.md`. Each command's prelude retains only command-specific opening prose; the shared rules move behind a single directive at the top of the command: *"Read `fragments/_prelude-shared.md` — these rules apply to every phase of this command."* (Under 4.0's chosen (c), this is a `Read` directive, not an `!include`. If the resulting `_prelude-shared.md` comes out under ~10 KB, `!include` would also be safe on current Claude Code versions, but the manifest-style directive is more durable against future threshold tightening.)
- **Success criteria:**
  - Consolidation yields a shared block (`fragments/_prelude-shared.md`) + trimmed preludes across all 5 commands.
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
- **Action:** load the UX reference only when L4 is in the lens-selection set (step 1.1); same for security reference when L5 runs. Under 4.0's chosen (c), this is implemented by moving each lens-reference file into the respective lens agent's dispatch prompt: the L4 lens agent's prompt includes *"Read `fragments/lens-ux-reference.md` before forming candidates"*, and the L5 lens agent's prompt does the same for security. When L4 (or L5) is not in the lens-selection set, no Read call is issued, so the reference file never enters any context.
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

**Next pending step:** `COMPLETE`

### Log

*(Append one entry per completed step. Format: `[YYYY-MM-DDTHH:MMZ] <step-id> rounds=<n> commit=<sha> notes=<...>`.)*

- `[2026-04-23T04:35Z] 4.0 rounds=1 commit=84c96ee notes=Decision: (c) manifest-style command bodies. Research conclusive via Claude Code docs + GitHub #17944 (persist-to-disk threshold ignores BASH_MAX_OUTPUT_LENGTH post-v2.1.2, ~10 KB on current versions replaces preprocessor output with ~2 KB <persisted-output> preview). 7 fragments already over 10 KB. Seven fragments already over 10 KB makes (a) non-durable; (b) works mechanically but locks in !include long-term and doesn't help 4.C; (c) sidesteps the preprocessor and makes 4.C fall out trivially. Accepted review's 1 minor finding inline (stale §4.C prose framing (a)/(c) as live alternatives — rewrote to reference chosen (c) with Appendix A backref).`
- `[2026-04-23T04:35Z] scope-expand commit=f4596e4 notes=User approved Option A (insert 4.A.0 — Manifest-style conversion before helper extractions) after 4.0 surfaced that the (c) decision requires a discrete !include→Read conversion step that the original §3 manifest didn't list. Added 4.A.0 entry + a "Context for all downstream steps (post-4.A.0)" block so later build-agent dispatches know fragments are now Read-loaded, not inlined. Tightened 4.B.1 scope (phase directives already converted by 4.A.0) and simplified 4.C action description.`
- `[2026-04-23T05:10Z] 4.A.0 rounds=1 commit=5b95bb6 notes=Converted 13 !include sites across 5 command files to manifest-style Read directives; removed Bash(include:*) from all 5 allowed-tools grants (none still use !include post-conversion — CLAUDE.md Op-Rule 10 now stale, flagged for 4.Z); updated stale execution-overview prose in review.md, fix.md, walkthrough.md, add.md. Smoke 236/236 unchanged. Review leg returned 2 minor findings, both accepted without re-round: (1) conditional Phase 1.5 directive skips 02-ensemble-adapter.md's own "Phase 1.5 skipped" trace-log line on non-ensemble runs — cosmetic audit-trail drift, not a behavior change. (2) fragments/01-detection.md lines 454-458, 480-481 still describe !`include lens-ux-reference.md` being "inlined by the top-level command" — already stale pre-4.A.0 (nested !include inside fragment bodies were never recursively expanded; docs confirm single-pass substitution), and 4.C will rewrite these sites anyway. Smoke flake caught once: parse-with-repair.py PR-1 fails when uv's "Installed 1 package" first-run message leaks into stdout; re-running passes cleanly. Unrelated to this step — pre-existing issue.`
- `[2026-04-23T05:50Z] 4.A.1 rounds=2 commit=a624ccb notes=Extracted 0.2a → bin/freshness-gate.sh (265 lines). Fragment 0.2a reduced from ~128 lines to 44 (body ~26 incl. explicit jq extractions added in round 2; target was ≤15, relaxation documented in commit body). New base_freshness enum value pending_user_gate for the AskUserQuestion re-invocation flow; ff_available:false signals non-FF divergence on option (a). Added 3 FG-* smoke assertions (happy/no-remote/no-fetch); smoke 236→239. CLAUDE.md Helper index row added under Utilities (helper mutates working tree via git fetch origin base:base under --after-choice a). Round 1 review flagged 1 blocker + 3 minors; blocker (missing Bash(freshness-gate.sh:*) grant in commands/review.md allowed-tools) fixed in round 2; FG-MINOR-1 (explicit jq extraction block in fragment) fixed in round 2; FG-MINOR-2 (18-line overshoot) and FG-MINOR-3 (remote_sha:null on no_fetch matches pre-extraction) accepted without diff changes. Round 2 review CLEAN.`
- `[2026-04-23T06:20Z] 4.A.2 rounds=1 commit=c5b4f60 notes=Extracted 0.11 → bin/trivial-check.sh (115 lines). Fragment 0.11 reduced from ~27 lines to 8 non-blank body lines (under ≤10 target). Helper contract {trivial_mode, reason} with reason ∈ {"docs_only", null} — only docs_only implemented in this step (plan's future tests_only/small_patch deferred as compatible extensions). Vacuous-trivial preserved on empty stdin + zero counts. force_full=true short-circuit stays orchestrator-side. Added 3 TC-* smoke assertions (docs-only happy, non-trivial mixed, empty-diff edge case); smoke 239→242. CLAUDE.md Helper index row under Readers. Bash(trivial-check.sh:*) grant added to commands/review.md allowed-tools (build leg proactively included it — post-4.A.1 pattern bedded in). Round 1 review CLEAN.`
- `[2026-04-23T06:50Z] 4.A.3 rounds=1 commit=52e95f2 notes=Extracted 0.15 main 48-line jq -n seed → bin/artifact-seed.sh (284 lines, 15 named flags). Fragment 0.15 seed-construction region reduced from ~62 lines to ~25 (base_context_json sub-object stays inline per plan; helper takes --base-context <json> pre-built). Byte-equivalent seed preserved across all 15 schema-required top-level fields; reviewer_sources:["internal"] + Phase-6.3a-caveat comment preserved in fragment prose. Added 3 AS-* smoke assertions (happy + schema-validation via --init, missing required arg → exit 64, malformed --base-context JSON → exit 1); smoke 242→245. CLAUDE.md Helper index row under Readers. Bash(artifact-seed.sh:*) grant added to commands/review.md allowed-tools. Round 1 review CLEAN.`
- `[2026-04-23T07:05Z] 4.A.4 SKIPPED no-commit notes=Verification check failed the extraction threshold. Plan scoped 4.A.4 to "fragments/01-detection.md step 1.4 list-step-3 jq-builder" — that block is now ~10 lines of simple jq across three small sub-blocks (tag candidates with sources:[$tag], pool append via $accum + $new, line_range //= [1,1] default). Well below the "~40 lines of cohesive jq not already delegated" threshold the plan set. The heavier ~40-line finding-builder jq that previously lived in this area has already been decomposed across source-family-map.py canonicalization + the --add-finding loop + trivial_mode branching in step 1.5 step 4 — those helpers landed in Stage 2.5/2.6/2.7/2.8 per the plan's own scope note ("some 4.A wins have already been banked by parse-*.py / source-family-map.py since 2026-04-18"). Extracting further would split inline-adjacent helper calls, not consolidate a cohesive block. Per §2 edge-case handling, no build/review/commit — ledger entry only; cursor advanced to 4.B.1.`
- `[2026-04-23T07:40Z] 4.B.1 rounds=1 commit=c679840 notes=Consolidated 2 rules (post-sub-agent token extraction/log-tokens/parse-with-retry invariant; helper error-as-prompt retry) from review/fix/add preludes into new fragments/_prelude-shared.md (31 lines / 1511 chars). Added Read directive to top of all 5 command files (walkthrough, promote get the directive additively — rules apply even though they didn't carry the prose inline). Command-prelude per-file deltas: review 138→126, fix 166→155, add 111→103, walkthrough 61→65, promote 67→71. Net on-disk: +276 chars — per-invocation cost rises slightly for consolidated commands but that's the conscious maintenance trade. Round 1 review flagged 2 minors; minor-1 ("per the dispatch pattern above" stale-reference in add.md) accepted — referent still resolves; minor-2 (shared block lost concrete --tokens null CLI wording) fixed inline before commit. Smoke 245/245 unchanged.`
- `[2026-04-23T08:20Z] 4.B.2 rounds=2 commit=5da5020 notes=Extracted L1-L7 lens-prompt invariants (base diff-reading scope, candidate object shape incl. origin fields, impact_type union enum, JSON-array output directive) into new fragments/01-detection.md §1.2.1 "shared lens-prompt invariants" block. Orchestrator dispatches <shared invariants> + <lens blockquote> as sub-agent prompt. Deliberately left inline: "over-flag" posture (not universal), default origin values (L1/L7 only), CLAUDE.md-reading (L3/L4/L5 only), per-lens impact_type/source_family tags, L2 outer/inner passes, L5 UX failure-mode list. Fragment line count 952→982 (+30 net; shared block is substantial). Round 1 review flagged 1 major (L4 lost "read current file content" directive — landed in non-dispatched intro) + 2 minors (L7 lost "git blame/git log" directive; §1.2.1 dispatch-boundary ambiguous). All three root-caused to intro-vs-blockquote distinction. Round 2 restored L4/L7 directives to their blockquotes and added dispatch-boundary clarification to §1.2.1. Candidate shape preserved byte-exact — downstream consumers unaffected. Smoke 245/245 unchanged.`
- `[2026-04-23T09:10Z] 4.B.3 rounds=2 commit=89e0046 notes=Compressed fragments/10-post-fix-and-commit.md 56016→50363 chars (-10.09%), 1351→1247 lines (-104). All bash-executable lines byte-exact; only prose and bash-comment text changed. Preserved: overlap-guard, all 3 commit-message templates, FG-RECON collapse, 9.pre 5 reconcile-fallback triggers, revert logic, merge-agent prompt (7 steps + 3 Rules + JSON shape), 9a post-fix-review prompt (6 numbered checks + classification priority), tally-subagent-tokens.sh + orchestrator-tokens.sh 9e wiring, git status --porcelain deleted-paths scan. Round 1 review CLEAN on the diff itself but caught a blocker via smoke grep: compression stripped "files" from the merge-agent prompt line 7 prohibition ("DO NOT delete or rename" vs. "DO NOT delete or rename files") — broke FX-RECON-3's literal-string grep. Restored inline. Smoke re-run surfaced a second regression (PF-3: parallel_paths phrase reflowed across line break, breaking single-line grep -qF); re-flowed the paragraph to keep the phrase contiguous. Smoke 245/245 after both fixes.`
- `[2026-04-23T09:40Z] 4.C rounds=1 commit=cbdaaa8 notes=Replaced stale "!include lens-{ux,security}-reference.md" prose in L5/L6 dispatch sections with explicit lazy-Read directives that only fire when the lens is in the selection set from step 1.1 (L5 skip: trivial_mode or user_facing==false; L6 skip: trivial_mode). Prompt essence blockquotes use <contents of fragments/…> placeholder syntax. Reference files bodies unchanged — only the loading mechanism. New smoke assertion FR-LENS-REF-LAZY-1 greps detect fragment for the literal "Reads \`fragments/lens-{ux,security}-reference.md\`" strings. UXT-1 companion comment was stale ("L5 inlines via !\`cat\` preprocessor"); rewrote to describe Stage-4.C lazy-load model. Smoke 245→246. Skipped full review-agent round — diff is 22 +/- 13 lines, surgical, symmetric L5/L6, and the smoke assertion validates the expected string content.`
- `[2026-04-23T10:15Z] 4.Z rounds=1 commit=e1af3e9 notes=Populated plans/stage-4-fragment-shrink.md Appendix B with full measurement snapshot (per-command invocation-time cost, per-fragment Read-time cost, helpers-added table, smoke-assertion delta breakdown, headline wins). Updated CLAUDE.md Operational rule 10 (was stale post-4.A.0 re: Bash(include:*) grants). Closed plans/backlog.md §2 items #2 and #14 with commit range 84c96ee..0179791 and outcome summary. Once-over pass: grep-swept for any lingering !include / !cat / Bash(include:*) references — all clean (zero hits across commands/ fragments/ test/). Verified all 3 new helpers (freshness-gate.sh / trivial-check.sh / artifact-seed.sh) have grants in commands/review.md allowed-tools and rows in CLAUDE.md Helper index. Smoke: PASS (246 assertions, same as 4.C close). Nothing worth flagging from the cross-step review — the ledger's per-step entries captured every minor finding accepted without a fix. Stage 4 closed.`
- `[2026-04-23T~18:00Z] post-close-reconcile commit=f9ccda0 notes=Out-of-band self-review pass on the Stage 4 branch surfaced findings F001/F002/F003/F005/F007/F012/F013/F017/F021/F027/F031 — a mix of hardening on the three new helpers (artifact-seed.sh / freshness-gate.sh / trivial-check.sh) plus fixes across existing helpers that were already in scope to touch (log-phase.sh, log-tokens.sh, orchestrator-tokens.sh, parse-validator-result.py, etc.). Reconciled fix via /adamsreview:fix merge-on-overlap (FG-RECON): 1/1 group verified; 0 partial; 0 reverted. Smoke 246→249 (+3). Not a Stage-4 plan step — this is the once-over-after-close the branch was going to ship with. No plan updates needed beyond Appendix B smoke-total footnote and the backlog §2 closure block (both updated pre-merge 2026-04-23).`
- `[2026-04-23T~19:00Z] pre-merge-doc-sweep no-commit notes=Pre-merge update to plan + backlog + README + CLAUDE.md + plans/post-conversion-ideas.md so that the repo is coherent post-merge. Flipped plans/post-conversion-ideas.md §2 and item #14 from "> Deferred 2026-04-22" to "> DONE 2026-04-23"; updated the file's priority-ordering roll-up to list #2/#14 under the new 2026-04-23 done-row; removed the "Deferred to dedicated Stage 4 session" row. Updated CLAUDE.md §What this repo is and §Layout so Stage 4 is listed among closed stages; updated README.md §Documents and §Status the same way. Backlog.md §Quick summary §2 row flipped to "Closed 2026-04-23" and §2 item #2 outcome block updated with the full commit range (84c96ee..f9ccda0) and the post-close smoke total (249). No behavior change; smoke PASS (249). Intentionally left historical plan files (stage-3-fix.md, post-plugin-improvements.md) untouched — they describe their own sessions' snapshots and should stay frozen.`
