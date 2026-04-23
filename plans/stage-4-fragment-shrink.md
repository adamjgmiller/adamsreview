# Stage 4 plan — Fragment shrink + helper externalization

**Status:** not started. Revised 2026-04-22 after a validation pass — see commit log on this file for the pre-revision version.

**Plan-approval round-trip required** before execution — non-trivial representational change across many files.

---

## Why "Stage 4"?

Carryover from the original numbered build sequence (Stage 1 → 2 → 2.5 → 2.6 → 2.7 → 2.8 → 3). Stage 4 was the last unexecuted item when the docs were reorganized on 2026-04-18; the plan was extracted from the frozen `docs/archive/BUILD.md` into this file so the scope survived outside the archive. The filename is preserved because `plans/backlog.md §2`, `CLAUDE.md`, and `plans/post-conversion-ideas.md` all link to it. It is not "the fourth thing we are doing now" — it is "the stage that remained."

## Rationale — two problems, one stage

### Problem 1: context cost

`/adamsreview:review` now inlines ~38k tokens of command + fragments before any work runs. Total plugin surface across 5 commands + 14 fragments is ~90k tokens / 359k chars / 8795 lines. On top of the Claude Code harness and user MCP/plugin surface, a typical session lands at 130k+ context before the first lens dispatches.

### Problem 2: `!include` preprocessor ceiling (backlog #14)

During the 2026-04-22 review run, the `!include` preprocessor persisted Phases 0, 1.5, and 2–6 inline but silently truncated two phases to 2 KB "previews"; the orchestrator recovered by directly `Read`-ing the affected fragments. This is a **correctness** failure, not just a cost issue — some fragment content never reaches the model unless recovered by hand. Until the ceiling is characterized, prose compression alone may not fix it.

## Baseline (2026-04-22)

**Per-command cost when invoked (command file + all transcluded fragments):**

| Command | Command file | Transcludes | Total chars | ~Tokens |
|---|---|---|---|---|
| `/adamsreview:review` | 8k | 00–07 (143k) | 151k | **~38k** |
| `/adamsreview:fix` | 10k | 08–10 (79k) | 89k | ~22k |
| `/adamsreview:walkthrough` | 50k | promote-core (10k) | 60k | ~15k |
| `/adamsreview:add` | 41k | — | 41k | ~10k |
| `/adamsreview:promote` | 10k | promote-core (10k) | 20k | ~5k |

**Largest files on disk:**

| File | Lines | Chars |
|---|---|---|
| `fragments/10-post-fix-and-commit.md` | 1351 | 56k |
| `commands/walkthrough.md` | 1285 | 50k |
| `fragments/01-detection.md` | 952 | 43k |
| `commands/add.md` | 1060 | 41k |
| `fragments/00-preflight.md` | 655 | 27k |
| `fragments/05-validation.md` | 511 | 23k |

Re-measure at stage close; record the delta in Appendix B.

## Scope

### 4.0 — `!include` ceiling investigation (do first)

**Step 1: research online before manual testing.**

- Claude Code documentation for slash-command `` !`command` `` preprocessor — output-size caps, per-invocation vs. cumulative limits, truncation semantics.
- GitHub issues in `anthropics/claude-code` for `!include`-style transclusion truncation or output-size limits.
- The `!` preprocessor's documented behavior vs. the observed 2026-04-22 truncation.

**Step 2 (conditional): minimal manual repro, only if research is inconclusive.**

Invoke a throwaway test command that `!include`s progressively larger fragments; bisect where truncation kicks in.

**Step 3: decide.** Pick one of three structural responses for the rest of Stage 4:

- **(a) Stay on `!include`** and trust compression to fit under the ceiling. Cheapest, but risks re-exposure.
- **(b) Split oversized fragments** into sub-fragments below the ceiling (e.g., `01-detection-1.md` + `01-detection-2.md`, transcluded sequentially). Medium blast radius.
- **(c) Manifest-style command bodies** — command file says "Phase 1: Read `fragments/01-detection.md` and execute per the instructions inside" rather than `!include`-ing. Biggest change; sidesteps the preprocessor entirely and makes 4.C (lens-reference lazy-load) trivial. Changes the orchestrator contract for fragments from "inlined prose" to "read-and-execute."

Record findings and the chosen response in **Appendix A** below before executing 4.A–4.C.

### 4.A — Helper extractions

Concrete bash/jq blocks in current fragments, each yielding a ~10-line fragment contract + one helper invocation:

1. **`freshness-gate.sh`** — `fragments/00-preflight.md` step 0.2a (~80 lines: fetch + 30s timeout + behind-count + FF logic). Takes `--base-branch` + `--head-branch`, returns JSON `{comparison_ref, base_freshness, remote_sha, behind_count, preflight_warnings[]}`. Fragment reduces to the `AskUserQuestion` dispatch (which stays orchestrator-driven) plus the helper invocation.
2. **`trivial-check.sh`** — `fragments/00-preflight.md` step 0.11 (~15–30 lines: extension-allowlist + line-count + file-count). Returns `{trivial_mode, reason}`.
3. **`artifact-seed.sh`** — `fragments/00-preflight.md` step 0.15 (48-line `jq -n --argjson …` block starting at line 517). Takes the ~15 Phase-0 outputs as args/env, emits the schema-shaped seed JSON on stdout; `artifact-patch.py --init -` consumes it unchanged.
4. **`finding-builder.py`** *(conditional)* — `fragments/01-detection.md` step 1.4 list-step-3's jq-builder. **Verify before extracting** that it is still ~40 lines of jq not already absorbed by `parse-with-repair.py` / `parse-validator-result.py` / `source-family-map.py` (built post-Stage-2.6). Extract only if it's still a fragment-bloating cohesive block.

Helper contract (applies to all): bash-3.2 portable; uv-shebang for Python (`#!/usr/bin/env -S uv run --script`); exit-code constants from `bin/_common.py` (0=OK, 1=validation, 2=invalid-transition, 3=dry-run-invalid, 4=unexpected, 5=missing-dep, 64=usage); error-as-prompt stderr; `--help`; 2–3 smoke assertions per helper in the OC-*/FR-*/RH-*/FX-*/MP-*/WT-* style; one row in the **CLAUDE.md Helper index** (replaces the frozen `docs/archive/DESIGN.md §21` target).

### 4.B — Prose compression

Scope-trimmed from the original plan — some 4.A wins have already been banked by `parse-*.py` / `source-family-map.py` since 2026-04-18.

- **Prelude consolidation across 5 commands.** `commands/review.md` / `fix.md` / `walkthrough.md` / `add.md` / `promote.md` each open with the same sub-agent-dispatch / working-set / effort-is-session-wide boilerplate in abbreviated form; the same prose also recurs inside fragments. Consolidate into one shared block, reference by name.
- **L1–L7 lens-prompt invariant extraction.** Every lens prompt in `fragments/01-detection.md` currently repeats "Read ONLY the diff between `$comparison_ref` and HEAD…" / "Return a JSON array of candidates…" scaffolding with minor variations. Move invariants into step 1.2's shared input block; leave only lens-specific guidance in each lens prompt.
- **`fragments/10-post-fix-and-commit.md` compression.** Largest fragment in the repo; Phase 9.pre / 9a / 9b / 9c sections have structural repetition that likely compresses cleanly without touching logic.

### 4.C — Lens-reference lazy load

Previously out of scope in the original plan; bundled here because 4.0's chosen structural response likely touches the loading path already.

`fragments/lens-ux-reference.md` (3k chars) and `fragments/lens-security-reference.md` (1.8k chars) are currently available to every lens pass. Load them only when L4 / L5 are actually selected in step 1.1. Implementation depends on 4.0:

- Under (a) `!include`: replace transclusion with a conditional `Read` from the lens agent prompt.
- Under (c) manifest: lens references become ordinary `Read` calls gated by lens selection — falls out naturally.

### Not in scope for this stage

- Any behavior change — purely representational.
- `commands/walkthrough.md` and `commands/add.md` self-contained prose compression — file as a §3 item in `plans/backlog.md` for a future pass once Stage 4's structural decisions have bedded in.
- Plugin/MCP pruning — user-level decision, not ours.
- Any update to `docs/archive/` — frozen.

## Done when

1. `test/smoke.sh` passes unchanged — no behavior drift. Each new helper adds 2–3 assertions in the established naming style; existing assertions stay green.
2. Each new helper has a row in the **CLAUDE.md Helper index** table (the frozen `DESIGN §21` target is replaced by this).
3. **No hard token target.** Close-out records before/after per-command char and token measurements in **Appendix B**. Measurement is the deliverable, not the gate — we'll see how much the chosen approach actually saves.
4. 4.0 investigation produces a documented decision between structural responses (a)/(b)/(c), recorded in **Appendix A**.
5. `plans/backlog.md` §2 (items #2 and #14) updated to reflect Stage 4's closure and any follow-ups deferred to future passes (e.g., walkthrough/add prose compression).
6. CLAUDE.md pipeline-shape section is re-read for drift; any newly extracted helpers appear in the Helper index, and any fragment paths referenced in the ops rules stay accurate.

## Commit cadence (estimated)

1. **4.0** — investigation + decision appendix. 1 commit (or zero if findings land in plan text only).
2. **4.A** — one commit per extracted helper: freshness-gate → trivial-check → artifact-seed → (conditional) finding-builder. Each commit includes helper + smoke assertions + fragment shrink + CLAUDE.md Helper-index row.
3. **4.B** — 2–3 commits: prelude consolidation; lens-prompt invariant extraction; post-fix-and-commit pass.
4. **4.C** — lens-reference lazy load. 1 commit.
5. **Close-out** — Appendix B measurement snapshot, `plans/backlog.md` updates, final CLAUDE.md Helper-index pass. 1 commit.

~8–11 commits total.

## Related context to inherit when planning

- `bin/_common.py` exit-code constants and `atomic_write` / `suggest()` utilities — every new helper reuses these.
- `CLAUDE.md` Operational rules — uv-shebang, bash-3.2 portability, bare-name `allowed-tools` grants, reviews root in `~/.adams-reviews/`, error-as-prompt stderr.
- `CLAUDE.md` Helper index — the shape each new row must follow (Script | Lang | Purpose).
- `docs/archive/DESIGN.md §21` — historical reference for helper-contract shape. Read for shape; never update (frozen).
- `docs/archive/BUILD.md` Cross-stage notes (2026-04-17 bash-3.2 portability, exit-code conventions, uv-shebang pattern) — same status.

---

## Appendix A — 4.0 investigation findings

*(To be filled in during 4.0.)*

- **Sources consulted:**
- **Observed behavior:**
- **Root cause / ceiling characterization:**
- **Chosen response:** (a) / (b) / (c)
- **Rationale:**

## Appendix B — Close-out measurement

*(To be filled in at stage close.)*

Before / after by command (mirrors the Baseline table in this file):

| Command | Before chars | After chars | Δ |
|---|---|---|---|
| `/adamsreview:review` |  |  |  |
| `/adamsreview:fix` |  |  |  |
| `/adamsreview:walkthrough` |  |  |  |
| `/adamsreview:add` |  |  |  |
| `/adamsreview:promote` |  |  |  |

Before / after by largest fragment:

| File | Before | After | Δ |
|---|---|---|---|
| `fragments/10-post-fix-and-commit.md` |  |  |  |
| `fragments/01-detection.md` |  |  |  |
| `fragments/00-preflight.md` |  |  |  |
| `fragments/05-validation.md` |  |  |  |

Helpers added: (list)
Smoke assertion delta: (before count → after count)
