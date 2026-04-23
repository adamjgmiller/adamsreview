# Stage 4 plan — Fragment shrink + helper externalization

**Status:** closed 2026-04-23. Commit range `84c96ee..f9ccda0` on branch `stage-4-fragment-shrink` (close-out `e1af3e9`; `f9ccda0` is a post-close self-review reconcile). See Appendix B for the measurement snapshot and `plans/stage-4-fragment-shrink-execution.md` §4 for the per-step ledger. Original draft was 2026-04-19, revised 2026-04-22 after a validation pass (see commit log on this file); the scope below is what was executed.

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

Previously out of scope in the original plan; bundled here because 4.0's chosen structural response (manifest-style — see Appendix A) already touches the loading path.

`fragments/lens-ux-reference.md` (3k chars) and `fragments/lens-security-reference.md` (1.8k chars) are currently available to every lens pass. Load them only when L4 / L5 are actually selected in step 1.1. Under 4.0's chosen (c), lens references become ordinary `Read` calls gated by lens selection — falls out naturally from the manifest-style command body.

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

Filled in 2026-04-22. Research was conclusive — no manual repro needed.

### Sources consulted

- Claude Code docs — **Skills** page, section "Inject dynamic context." Documents the `` !`<command>` `` slash-command / skill preprocessor: "runs shell commands before the skill content is sent to Claude. The command output replaces the placeholder." Confirms `` !`command` `` is a thin preprocessor whose output is the command's stdout. No size cap is mentioned on this page. <https://code.claude.com/docs/en/skills>
- Claude Code docs — **Environment variables** page. Documents `BASH_MAX_OUTPUT_LENGTH` as "Maximum number of characters in bash outputs before they are middle-truncated." No default value, no documented maximum. <https://code.claude.com/docs/en/env-vars>
- Claude Code docs — **Slash commands** page. No mention of an output cap on the `!` preprocessor. <https://code.claude.com/docs/en/slash-commands>
- GitHub issue [anthropics/claude-code#19901](https://github.com/anthropics/claude-code/issues/19901) — "[DOCS] Missing documentation on Bash tool output limits (30k characters) and truncation behavior." Confirms the **Bash tool's** 30,000-character default cap and middle-truncation semantics, with `BASH_MAX_OUTPUT_LENGTH` as the knob.
- GitHub issue [anthropics/claude-code#17944](https://github.com/anthropics/claude-code/issues/17944) — "[BUG] `BASH_MAX_OUTPUT_LENGTH` ignored after v2.1.2 — large outputs persisted to disk regardless of setting." **The critical finding.** As of ≈v2.1.2, Claude Code replaced the middle-truncation path with an on-disk spill-over:
  > Output too large (50.2KB). Full output saved to: `/home/user/.claude/projects/.../tool-results/toolu_xxx.txt`
  > Preview (first 2KB): `{"output": [...beginning of output only...]`

  Persistence triggers at "as small as ~30–50 KB" (and per later search summaries, effectively ~10 KB in very recent versions). `BASH_MAX_OUTPUT_LENGTH=150000` does **not** prevent persistence. The bash output in the prompt is replaced by "a file path + a first-~2 KB preview."
- GitHub issue [anthropics/claude-code#11155](https://github.com/anthropics/claude-code/issues/11155) — bash-output-in-memory pathology, corroborates the persistence mechanism exists but with no numeric detail.
- GitHub issue [anthropics/claude-code#23948](https://github.com/anthropics/claude-code/issues/23948) — corroborates `<persisted-output>` tag wraps the preview + file path; threshold behavior evolved across versions.
- Community summary (via web search, not primary source): "Recent versions of Claude Code (≥ v2.1.88) appear to limit persisted output to 10 KB; larger than 10 KB → saved to file + trimmed to 2 KB preview." Not grep-able in official docs; treat as indicative.
- Manual repro not attempted — a sub-agent cannot launch slash commands, so a Claude-Code-to-Claude-Code repro needs a fresh session. Evidence is strong enough to decide without it. Follow-up if we need a hard number: throwaway `/adamsreview:test-include` command that `!include`s a generated fragment at 5 / 10 / 20 / 30 / 50 KB and reports which sizes got replaced by a `<persisted-output>` block.

### Observed behavior (2026-04-22 truncation)

During the `/adamsreview:review` run on 2026-04-22:

- The `!include` preprocessor persisted Phases 0, 1.5, and 2–6 inline as expected.
- Two phases (among the larger fragments — consistent with `fragments/01-detection.md` at 43 KB and `fragments/10-post-fix-and-commit.md` at 56 KB, or `fragments/00-preflight.md` at 27 KB) were silently replaced in the prompt by ~2 KB "previews."
- The orchestrator recovered by directly `Read`-ing the affected fragments from disk — recovery worked, but only because the orchestrator noticed the content was suspiciously thin. No error, no warning, no `<persisted-output>` tag surfaced in a way that the command author could pattern-match on in advance.

### Root cause / ceiling characterization

The `` !`<command>` `` slash-command preprocessor shares its output plumbing with the Bash tool. When the command's stdout exceeds Claude Code's internal persist-to-disk threshold (v2.1.88-era ≈ 10 KB per the community summary; issue #17944 reports persistence triggering at 30–50 KB under an earlier configuration), Claude Code:

1. Writes the full stdout to `~/.claude/projects/.../tool-results/toolu_*.txt`.
2. Replaces the output in the prompt with a `<persisted-output>` wrapper containing:
   - The file path.
   - A **first-~2 KB preview**.
3. Ignores `BASH_MAX_OUTPUT_LENGTH` (post-v2.1.2).

Our `bin/include` wrapper is just `cat "$fragment"` — its stdout volume equals the fragment's file size. Fragments `> ~10 KB` on current Claude Code therefore get clipped to a 2 KB preview. **Seven of our fragments are over 10 KB** (`01-detection.md` 43 KB, `10-post-fix-and-commit.md` 56 KB, `00-preflight.md` 27 KB, `05-validation.md` 23 KB, `02-ensemble-adapter.md` 16 KB, `07-finalize.md` 13 KB, `09-fix-execution.md` 13 KB). Even the ones that survived on 2026-04-22 are living on borrowed time — the threshold has been getting tighter across Claude Code minor versions, and nothing in our plumbing guards against a future tightening.

Characterization: **not a per-invocation bash cap we can turn off, not a cumulative cap, not a shell subprocess pipe limit — it is a Claude-Code-side persist-to-disk threshold that replaces the preprocessor's output with a `<persisted-output>` preview in the assembled prompt.** `BASH_MAX_OUTPUT_LENGTH` does not fix it.

### Chosen response: **(c) Manifest-style command bodies**

### Rationale

The three options, judged against (i) durability, (ii) blast radius, (iii) interaction with 4.C, and (iv) fit to the observed failure mode:

- **(a) Stay on `!include`, compress.** Compression alone is not viable. To fit `10-post-fix-and-commit.md` (56 KB) under a ~10 KB ceiling requires a 5.6× reduction without removing content; the same math applies to `01-detection.md` (4.3×) and `00-preflight.md` (2.7×). Best-case compression lands each fragment close to the cliff; the next Anthropic-side threshold tightening re-breaks us silently (this already happened once between v2.1.2 and now). Also: the threshold is undocumented in official docs, so we would be fitting to a number from a GitHub issue. Fails on durability.

- **(b) Split oversized fragments into sub-fragments.** Each `!include` is its own preprocessor invocation so the cap is per-invocation, and splitting does work mechanically. But the splits are semantically arbitrary — `01-detection-part-1.md` + `01-detection-part-2.md` reads worse as a standalone document than the current `01-detection.md`, and every future edit has to re-check that no sub-fragment has crept past 10 KB. We'd also be preserving the `!include` dependency long-term, which means 4.C (lens-reference lazy load) still needs its own conditional-read implementation inside the lens agent prompts. Medium durability, medium blast radius, doesn't help 4.C.

- **(c) Manifest-style.** Command body says "Phase 1: read `fragments/01-detection.md` and follow the instructions inside" — fragment content is reached via the `Read` tool, not the `!` preprocessor. `Read`'s limits are measured in thousands of lines (default 2000), which is orders of magnitude above any fragment we would write. Fragment size then only matters for the orchestrator's prompt token budget — exactly the problem 4.B prose compression is already sized to solve. Biggest one-time blast radius (all five command files), but:
  - **Durable.** Sidesteps the `<persisted-output>` mechanism entirely; immune to future threshold changes.
  - **4.C falls out for free.** Lens references become ordinary `Read` calls inside the lens agent prompt, gated on lens selection. No separate "conditional `!include`" machinery needed — which is the plan's own stated outcome for option (c).
  - **Blast radius is contained and one-pass.** The conversion is mechanical: each `!include <name>.md` becomes "Read `fragments/<name>.md` and execute the instructions inside." The fragment bodies don't change; only the splice point moves. Semantics of the orchestrator contract shift from "fragment prose was inlined in my prompt" to "fragment prose is in a file I'm instructed to read and follow" — a distinction the fragments already honor, since they are written as procedural instructions (e.g., "Phase 9.pre — overlap scan") not inline prose.
  - **No new behavior.** Every `!include` site becomes one `Read` + a "follow the instructions inside" directive. Trace-log boilerplate, helper invocations, and Phase numbering are unchanged.

The observed failure mode — silent 2 KB preview with no error surface — is specifically what (c) eliminates: `Read` failures are loud and recoverable, whereas `<persisted-output>` previews are indistinguishable from successful `!include` output until the model notices the content is truncated. For a command that matters to correctness (reviews can't afford to silently skip half of Phase 9), moving off the preprocessor is the right trade.

### Implementation notes for 4.A–4.C under (c)

- 4.A helpers don't care — they get called from fragment bodies either way. Extractions still land.
- 4.B prose compression targets fragment size for prompt-token reasons, not ceiling-avoidance reasons. The two largest fragments don't need to reach 10 KB — they need to reach "small enough that the orchestrator doesn't balloon." Net compression target relaxes; structural compression (dedupe, invariant extraction) remains the primary lever.
- 4.C becomes: lens-reference fragments (`lens-ux-reference.md`, `lens-security-reference.md`) move into each lens agent's `Read` list, gated on lens selection — exactly as the plan's (c) branch already specified.
- `bin/include` can stay in place for any remaining `!include` sites that are genuinely small and local (e.g., the shared prelude block if it lands under 10 KB). `Bash(include:*)` grants can be removed from command files that no longer `!include` anything — note for close-out pass.
- One subtle blast-radius point for the conversion PR: the `!include` preprocessor runs **once, at command-invocation time, before the orchestrator sees any content**. Manifest-style `Read` calls run **inside the orchestrator turn**. That means for any fragment whose instructions were written assuming prior fragments were already in prompt (cross-fragment references), the manifest style needs each fragment either (a) self-contained, or (b) read in order by the top-level command. The current fragments are already numbered and sequential, so this is mostly a naming discipline rather than a refactor.

### Open follow-ups

- Threshold number is not officially documented. If 4.B compression targets are tight, run the throwaway-repro command described above to pin the exact current threshold on the installed Claude Code version. Non-blocking for (c), which is immune to the threshold.
- If Anthropic later exposes a `DISABLE_BASH_PERSIST` or similar env var that fully disables the persist-to-disk path, (a) + aggressive compression becomes viable again. Worth revisiting at the next major Claude Code release.

## Appendix B — Close-out measurement

Stage 4 commit range: `84c96ee..f9ccda0` (21 commits on branch `stage-4-fragment-shrink`; close-out at `e1af3e9`, `f9ccda0` is a post-close self-review reconcile). Appendix B populated 2026-04-23.

### Command invocation cost

Under 4.0's chosen (c) manifest-style, the command file is what gets inlined at invocation time; fragments enter context via `Read` as phases reach them. Two numbers matter:

1. **Invocation-time prompt cost** — what's loaded when `/adamsreview:<cmd>` starts. Fragment bodies no longer participate.
2. **Aggregate fragment cost** — sum of fragment content that would be Read during a full command run.

| Command | Before (inlined) | After (command file only) | Δ invocation | Notes |
|---|---|---|---|---|
| `/adamsreview:review` | ~151k chars | **8,503** chars | −94.4% | Fragments 00-07 now Read on-demand. Under `!include` two phases truncated silently on 2026-04-22; after (c) that failure mode is gone. |
| `/adamsreview:fix` | ~89k chars | **9,875** chars | −88.9% | Fragments 08-10 now Read on-demand. |
| `/adamsreview:walkthrough` | ~60k chars | **50,851** chars | −15.3% | Self-contained command body; only `promote-core.md` (~10k) deferred. Walkthrough-specific prose compression deferred to future pass (§3 backlog). |
| `/adamsreview:add` | ~41k chars | **40,675** chars | −0.8% | No transcluded fragments pre-4.A.0; change limited to 4.B.1 prelude Read directive. |
| `/adamsreview:promote` | ~20k chars | **10,383** chars | −48.1% | `promote-core.md` (~10k) now Read on-demand. |

### Fragment body cost (per Read-time)

| File | Before chars | After chars | Δ | Notes |
|---|---|---|---|---|
| `fragments/10-post-fix-and-commit.md` | 56,016 | 50,369 | **−10.1%** | 4.B.3 prose compression; 0 executable-line changes. |
| `fragments/01-detection.md` | 42,827 | 44,883 | +4.8% | Net growth from 4.B.2 shared-invariants block + 4.C lazy-Read directives. Individual lens sub-sections trimmed; shared block additive. |
| `fragments/00-preflight.md` | 27,415 | 22,248 | **−18.9%** | 4.A.1 (freshness-gate) + 4.A.2 (trivial-check) + 4.A.3 (artifact-seed) all carved blocks out of step 0.2a / 0.11 / 0.15 into helpers. |
| `fragments/05-validation.md` | 23,044 | 23,044 | 0% | Untouched in Stage 4. |
| `fragments/_prelude-shared.md` | — | 1,500 | +NEW | 4.B.1 consolidation; Read once per command invocation that needs it. |

### Helpers added

| Helper | Stage | Source | Smoke assertions |
|---|---|---|---|
| `bin/freshness-gate.sh` (~11 KB) | 4.A.1 | Phase 0.2a §13.10 freshness reconciliation (was ~130 lines inline bash) | `FG-1/2/3` — happy / no-remote / fetch-failure |
| `bin/trivial-check.sh` (~4 KB) | 4.A.2 | Phase 0.11 §13.9 trivial-diff classifier (was ~27 lines inline bash) | `TC-1/2/3` — docs-only trivial / mixed non-trivial / empty-diff vacuous |
| `bin/artifact-seed.sh` (~9 KB) | 4.A.3 | Phase 0.15 main 48-line `jq -n` artifact-seed builder | `AS-1/2/3` — happy+schema-validation / missing-arg / malformed JSON |

### Smoke assertion delta

**Before (4aa0267):** 236 assertions. **After (Stage 4 close, e1af3e9):** 246 assertions (+10). **After post-close code-review reconcile (f9ccda0):** 249 assertions (+3 more on top of close).

Breakdown of additions through close (e1af3e9):
- 4.A.0 manifest conversion: 0 (pure restructuring; WT-5 grep survived unchanged).
- 4.A.1 freshness-gate: +3 (`FG-1`, `FG-2`, `FG-3`).
- 4.A.2 trivial-check: +3 (`TC-1`, `TC-2`, `TC-3`).
- 4.A.3 artifact-seed: +3 (`AS-1`, `AS-2`, `AS-3`).
- 4.A.4: SKIPPED (+0).
- 4.B.1 prelude: +0.
- 4.B.2 lens invariants: +0.
- 4.B.3 post-fix compression: +0 (but caught two smoke regressions from reflow-driven literal-grep breakage, both fixed).
- 4.C lens-reference lazy-load: +1 (`FR-LENS-REF-LAZY-1`, since renamed to `FR-LENS-REF-INLINE-1` by the f9ccda0 reconcile).

Post-close additions (f9ccda0 — addressed findings from the self-reviewed `/adamsreview:review` run against the branch): +3, covering hardening of the newly-extracted helpers (`bin/artifact-seed.sh`, `bin/freshness-gate.sh`, `bin/trivial-check.sh`) plus related fixes across existing helpers.

### Headline wins

- **Silent-truncation failure mode eliminated.** Pre-4.A.0, the `!include` preprocessor could persist fragments > ~10 KB to disk and substitute a 2 KB `<persisted-output>` preview in the prompt. Seven fragments were already over that threshold. Post-4.A.0, fragments are Read via the tool (no preview clipping); failures are loud (`Read` errors) instead of silent.
- **Invocation-time prompt cost for `/adamsreview:review` dropped ~94%** (151k → 8.5k chars at invocation).
- **Three ~40-130-line inline bash blocks externalized into helpers**, each with explicit JSON contracts, error-as-prompt stderr, smoke coverage, and CLAUDE.md Helper-index rows.
- **Post-fix fragment compressed 10.1%** (5,650 chars removed from the largest fragment) while preserving every bash-executable line byte-exact.
