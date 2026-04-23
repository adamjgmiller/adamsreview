# Post-plugin improvements — execution plan

**Status:** APPROVED 2026-04-22 — ready for fresh-session execution. See §9 Decisions record for the four scope decisions locked in during plan review.

**Branch:** `post-plugin-improvements` (worktree at `.claude/worktrees/post-plugin-improvements`)

**Source backlog:** `plans/post-conversion-ideas.md` — each project below cites the item numbers it covers.

---

## 1. Goal

Execute the high-priority portion of the post-plugin-conversion backlog in one unattended session. The fresh-session agent works through projects in the order **A → B → C → G → F → D.partial**, using a builder/verifier loop per project, commits at each project boundary, and leaves a Build Journal entry per project that captures what happened.

The session is designed to be interruptible: every project commit is a standalone checkpoint, and projects are independent (no ordering requirement enforces itself beyond the heuristic "simpler first").

---

## 2. Scope

### In scope (this session)

| Project | Items | Estimated effort |
|---|---|---|
| **A — Orchestrator-tokens display cleanup** | #0 | S |
| **B — Prompt/fragment one-liners** | #11, #13, #18, #19, #23, #27 | S |
| **C — Infra housekeeping** | #15, #16, #21, #22, #25 | S |
| **G — Origin crosscheck rename-following** | #9 | M |
| **F — LLM output variance normalization** | #10, #12, #20 | L |
| **D.partial — `confirmed_auto` rename + Phase 3 telemetry** | #1A, #24 (instrumentation only) | M |

### Deliberately out of scope (separate sessions)

- **Project E — Stage 4 fragment shrink** (`plans/stage-4-fragment-shrink.md`). Multi-commit representational change across every fragment; its own plan already exists and warrants its own session. Item #14 (preprocessor truncation in the 2026-04-22 run) is fresh forcing-function evidence to cite when Stage 4 is picked up.
- **#1B / #1C decision** (light-lane threshold vs. lift-filter). Requires ~10 reviews of walkthrough behavior data to decide; Project D's telemetry is the prerequisite.
- **H items** (#3, #4, #5, #6, #7, #8, #17, #1D, #1E, #25-if-second-plugin, missing-#26). Each has an explicit "probably never" trigger in the backlog. Leave alone.

### Scope guardrails

- No schema-breaking changes except **Project D's `confirmed_auto` → `confirmed_mechanical` rename**, which is a coordinated multi-file rename with smoke coverage.
- No fragment behavior changes except where explicitly specified in a project's Reasoning section.
- No Stage 4 work. If a project requires touching a fragment Stage 4 will shrink, make the minimal edit here; do not pre-compress.

---

## 3. Execution model

Fresh-session orchestrator (you, reading this plan) runs a loop per project. Do NOT do the file edits in your own context — delegate to subagents so your own context stays shallow enough to finish the full session.

### Per-project loop

For each project in order:

1. **Dispatch Builder subagent** (`general-purpose`) with the project's Builder Brief (see project section). Builder reads the relevant files, makes edits, runs `test/smoke.sh`, returns a summary of what it changed + smoke result.
2. **Dispatch Verifier subagent** (`general-purpose`) with the project's Verifier Checklist. Verifier reads the current diff (`git diff` + `git status`), re-runs `test/smoke.sh` independently, checks the Verifier Checklist items, returns `VERDICT: PASS` or `VERDICT: FAIL` with specific findings.
3. **Decide**:
   - On `PASS`: run the project's Exit Criteria sanity check, append the Build Journal entry by editing this plan file (`plans/post-plugin-improvements.md` §6), stage ALL changes (project files + the plan-file journal update), commit with the project's commit message, advance to step 4.
   - On `FAIL` and iteration < 3: dispatch Builder again with the verifier's findings as the fix brief. Increment iteration counter. Re-verify.
   - On `FAIL` and iteration == 3: mark project `BLOCKED` via a two-commit sequence:
     1. Append the BLOCKED Build Journal entry (full verifier output) to `plans/post-plugin-improvements.md` §6.
     2. Stage ONLY the plan file: `git add plans/post-plugin-improvements.md`.
     3. Commit with message `plans/: journal Project X blocked after 3 iterations` (plus the standard Co-Authored-By trailer).
     4. Revert the builder's unstaged project-scope changes: `git checkout -- .` + `git clean -fd`. The journal entry is safely committed; only the failed work is discarded.
     5. Advance to step 4.
4. **Inter-project sanity smoke.** Before dispatching the next project, orchestrator runs `test/smoke.sh` itself (not in a subagent). This is a guardrail against silent tree corruption that a project's verifier might have missed.
   - On `PASS` with `N ≥ BASELINE_ASSERTIONS`: advance to step 5.
   - On `FAIL` or regression below baseline: **halt the session**. Write a `### CRITICAL: inter-project sanity smoke failed after Project X` entry in the Build Journal with the smoke output. Do NOT dispatch further projects. This is a qualitatively different blocker from an isolated project blocker (infrastructure-corrupting) and requires human diagnosis.
5. **Next project.** Context hygiene: between projects, the orchestrator's own context should only hold this plan, the Build Journal, and any blocker notes. Builder/verifier transcripts stay in subagent context.

### Why this pattern

Each project is small and independent. The builder/verifier split buys independent review (verifier doesn't see the builder's rationalization), and the 3-iteration cap bounds cost when a project turns out to be thornier than expected. Committing per project means a blocker on one project doesn't lose progress on the others.

### Subagent prompt shape

Builder prompt must include:
- The specific items' Reasoning (copied from this plan).
- The Files likely touched list.
- Explicit "run `test/smoke.sh` before reporting done" instruction.
- Explicit "do NOT commit — orchestrator owns git" instruction.
- Blast-radius reminder (check every writer, every consumer, stale comments).

Verifier prompt must include:
- The Verifier Checklist verbatim.
- The items' Reasoning (so verifier understands intended behavior).
- Explicit "re-run `test/smoke.sh` yourself; do not trust the builder's claim" instruction.
- Output format: `VERDICT: PASS` or `VERDICT: FAIL\nFINDINGS:\n- ...`.

---

## 4. Global invariants (enforced at every project commit)

1. `test/smoke.sh` reports `smoke: PASS (N assertions)` where N ≥ 204 (the pre-session baseline). N grows as new helpers add assertions.
2. `git status` reports clean AFTER the project's commit (no uncommitted leftovers).
3. No amended commits. Every project produces a new commit. If a hook fails, fix the issue and make a new commit.
4. `CLAUDE.md` is updated in the same commit if the project changed something that CLAUDE.md describes (state table, helper index, pipeline shape).
5. No Stage 4 pre-work.
6. Commit messages use imperative mood, reference item numbers from `plans/post-conversion-ideas.md`, and end with a `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer (matching repo convention in `a97fa03`, `721a03b`, etc.). Use `git commit -F <file>` with a HEREDOC-built body so prose with quotes/backticks/newlines doesn't get mangled (Operational rule 8).
7. Inter-project sanity smoke (§3 step 4) must pass before the next project dispatches. A failure here halts the session.

---

## 5. Pre-flight (orchestrator runs this once before Project A)

1. `pwd` — confirm `.claude/worktrees/post-plugin-improvements`.
2. `git status --short` — must be empty (plan file itself must already be committed before session starts; if it isn't, halt and ask the user to commit). Fail-fast before any session commits.
3. `test/smoke.sh` — must print `smoke: PASS (N assertions)`. Record N as `BASELINE_ASSERTIONS` in the Build Journal.
4. `git rev-parse HEAD` — record as `BASELINE_SHA` in the Build Journal. This is the **pre-session HEAD**, captured BEFORE the backlog-annotation commit in step 5. It's used at §7 close-out for `git log <BASELINE_SHA>..HEAD` to enumerate every session commit.
5. **Annotate the backlog.** Edit `plans/post-conversion-ideas.md` and add scope-decision markers under each affected item so the backlog stays authoritative throughout the session. Use this exact item→project mapping:

   | Project | Items |
   |---|---|
   | A | #0 |
   | B | #11, #13, #18, #19, #23, #27 |
   | C | #15, #16, #21, #22, #25 |
   | G | #9 |
   | F | #10, #12, #20 |
   | D.partial | #1A, #24 |

   Annotation rules:
   - **In-scope items** (all of the above): add `> Scheduled 2026-04-22: plans/post-plugin-improvements.md Project <X>` under each item, where `<X>` is the project name from the table.
   - **Stage 4 (#2, #14):** add `> Deferred 2026-04-22: dedicated session per plans/stage-4-fragment-shrink.md`.
   - **Light-lane threshold decision (#1B, #1C)** and **the decision portion of #24:** add `> Deferred 2026-04-22: awaiting ~10 reviews of data from Project D telemetry`. (Telemetry itself IS in scope as Project D.partial.)
   - **H items** (#3, #4, #5, #6, #7, #8, #17, #1D, #1E): leave untouched. Their existing `Trigger:` lines already amount to "probably never."

   Commit the backlog-annotation edit as its own commit (first session commit):
   ```
   plans/: annotate post-conversion-ideas backlog with 2026-04-22 scope decisions

   Pre-flight marker pass for plans/post-plugin-improvements.md execution.
   Every in-scope item now points to its project; deferred items point to
   their follow-up triggers.

   Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
   ```
6. Read this entire plan top to bottom. Then dispatch Project A's builder.

---

## 6. Build Journal

Fresh session: the orchestrator appends one entry per project as it goes. Keep each entry under ~20 lines. Use the template below verbatim.

### Template

```
### Project X — <name>
- Status: PENDING | IN-PROGRESS | COMPLETE | BLOCKED
- Started: <ISO-8601>
- Ended: <ISO-8601 or —>
- Builder iterations: <N>
- Smoke assertions: baseline <B> → post <P>
- Commit: <sha or —>
- Summary: <1–2 sentence what changed>
- Verifier findings (fail-then-pass or final-blocker): <short>
```

### Pre-flight record

- BASELINE_ASSERTIONS: 204
- BASELINE_SHA: e3b757349ba14f295acf02cfb3b264af332630fc
- Session start: 2026-04-23T01:11:13Z
- Backlog-annotation commit: b7b63b5

### Project A — Orchestrator-tokens display cleanup
- Status: COMPLETE
- Started: 2026-04-23T01:11:13Z
- Ended: 2026-04-23T01:18:30Z
- Builder iterations: 1
- Smoke assertions: baseline 204 → post 208
- Commit: 3009c07
- Summary: Narrowed `bin/artifact-render.py`'s orchestrator-tokens header to `<output> output / <input> input across <N> turns`; propagated the narrowing to the `Cumulative orchestrator spend:` lines in `commands/add.md` + `commands/walkthrough.md` (both template + jq builder); updated `CLAUDE.md` pipeline-shape prose; schema retains all four counters. 4 new OTR-* assertions.
- Verifier findings: PASS first-try. Manual sum of `cache_read_input_tokens` over the real-run transcript (`rev_01KPVDH50WY7JSTEXFWYDNGQNH`, 3 sessions) matched helper exactly at 53,046,666 — helper is sound, no fix needed; the 53M/324-turn number is genuine (three same-cwd sessions within window).
- Inter-project sanity smoke (post-A, pre-B): PASS (208 assertions).

### Project B — Prompt/fragment one-liners
- Status: COMPLETE
- Started: 2026-04-23T01:18:30Z
- Ended: 2026-04-23T01:25:10Z
- Builder iterations: 1
- Smoke assertions: baseline 208 → post 208 (no new assertions for prose-only edits)
- Commit: f0d7f19
- Summary: Six prose one-liners from the 2026-04-22 run — Phase 4a 0–100 rubric fence (#11, `fragments/05-validation.md`), Codex `ready` → `setup --json` JSON-parsed readiness gate (#13, `fragments/01-detection.md` — the baseline pattern actually lived here, not in `02-ensemble-adapter.md` as the plan's file-list guessed), prior-PR-comment retention notice in §0.14 (#18, `fragments/00-preflight.md`), Codex stderr-vs-stdout comment near the poll loop (#19, `fragments/02-ensemble-adapter.md`), Phase 0 foreground-only prescription (#23, `fragments/00-preflight.md`), walkthrough between-iteration anti-instruction (#27, `commands/walkthrough.md` step 5.3).
- Verifier findings: PASS first-try. All six greps confirmed, zero remaining `node "$CODEX_COMPANION" ready` hits in source tree, smoke held at 208.
- Inter-project sanity smoke (post-B, pre-C): PASS (208 assertions).

### Project C — Infra housekeeping
- Status: COMPLETE
- Started: 2026-04-23T01:25:10Z
- Ended: 2026-04-23T01:31:27Z
- Builder iterations: 1
- Smoke assertions: baseline 208 → post 208
- Commit: <filled below after commit>
- Summary: Five infra one-liners — Phase 2 dedup `jq -r '.[1:][]' | xargs -n 1` replaces shell word-splitting (#15, `fragments/03-dedup.md`); Phase 4.4.5 tree sweep excludes `.claude/` in BOTH probe and restore clauses (#16, `fragments/05-validation.md` — restore needs the same pathspec or it un-does files the probe ignored); `Bash(line-range-check.sh:*)` added to `commands/review.md` allowed-tools (#21); `bin/include text eol=lf` added to `.gitattributes` (#22); `metadata.description` added to `.claude-plugin/marketplace.json` (#25 — plan said top-level `description` but validator only accepts `metadata.description`; `claude plugin validate .` now passes with zero warnings).
- Verifier findings: PASS first-try. All five greps confirmed.
- Follow-up observation (out of Project C scope): `assign-finding-ids.sh` and `origin-crosscheck.sh` are also invoked bare in `fragments/01-detection.md` / `fragments/02-ensemble-adapter.md` and missing from `commands/review.md` allowed-tools — same class of pre-existing gap as #21. Flag for future backlog addition.

---

## Project A — Orchestrator-tokens display cleanup

**Items:** #0

### Reasoning

The orchestrator-tokens render string currently displays four counters: `cache-read / output / cache-creation / fresh input`. In a real run this rendered as `53,046,666 cache-read / 566,990 output / 2,134,808 cache-creation / 484 fresh input across 324 turns`. Two problems:

1. **TMI in the status line.** Cache-read and cache-creation are prompt-cache plumbing implementation details. The user-facing levers — what the orchestrator sent and what it produced — are fresh input and output. Four counters buries the signal.
2. **53M cache-read across 324 turns (~164K/turn) is plausible but suspicious.** Worth a sanity check before shipping the simpler display: if `bin/orchestrator-tokens.sh` is double-counting (e.g., summing across multiple transcripts under the same cwd when only one belongs to this review), the simpler display hides the bug.

Ordering matters: **verify the sum first**, fix the helper if the sum is wrong, then change the rendered string. Otherwise we hide a real bug behind a prettier label.

### Files likely touched

- `bin/orchestrator-tokens.sh` (IF the sanity check finds a bug)
- `bin/artifact-render.py` (render string)
- `bin/schema-v1.json` (keep all four fields — internal capture preserved)
- `test/smoke.sh` (add/adjust assertion for the new render string)
- `CLAUDE.md` (pipeline-shape callout box that quotes the render string, if present)

### Builder brief

1. Pick one real review artifact from `~/.adams-reviews/<slug>/<branch>/<id>/artifact.json` (most recent is fine). Note its `orchestrator_tokens` object values.
2. Open the corresponding Claude Code session transcript under `~/.claude/projects/<cwd-slug>/*.jsonl`. Sum `cache_read_input_tokens` over assistant lines with `timestamp >= review_started_at` manually (jq).
3. Compare to the artifact's `cache_read` value. If it matches within rounding, helper is fine. If it diverges materially, fix `bin/orchestrator-tokens.sh` in the same pass AND document the bug + fix in the builder's summary so the orchestrator can reflect it in the commit message body. The builder does NOT commit — orchestrator owns git (§3 subagent rules).
4. Update `bin/artifact-render.py` so the rendered line reads: `<output> output / <fresh_input> input across <N> turns` (drop cache-read and cache-creation from the display).
5. Keep the schema unchanged: `orchestrator_tokens` still has all four counters internally.
6. Add or adjust a smoke assertion that confirms the rendered string format.
7. Run `test/smoke.sh`; report final counts + what changed + whether the sanity check turned up a helper bug.

### Verifier checklist

- [ ] `git diff` shows `artifact-render.py` simplified to 2-counter render.
- [ ] `schema-v1.json` still lists `cache_read_input_tokens`, `cache_creation_input_tokens`, `fresh_input`, `output` (or equivalent field names) — internal capture preserved.
- [ ] Smoke passes with ≥ baseline assertion count.
- [ ] If the helper was edited, the builder's summary explains the bug found and the fix.
- [ ] No changes to `log-tokens.sh` or `tally-subagent-tokens.sh` (wrong file — those are for subagent tokens, not orchestrator).
- [ ] `CLAUDE.md` pipeline-shape section, if it quotes the old 4-counter string, is updated.

### Exit criteria

New render string format is in `artifact-render.py`, schema retains four fields, smoke green, helper's sanity check result documented in the commit message.

### Commit message (draft)

```
orchestrator-tokens: simplify display to output + fresh input only

Render string drops cache-read and cache-creation from the user-facing
line; schema keeps all four counters for cost diagnostics. Sanity-
checked the cache-read sum against session transcripts — <matched | 
diverged and fixed>.

Closes post-conversion-ideas #0.
```

### Estimated effort

~30–45 min. Sanity check is the long pole; display change is trivial.

---

## Project B — Prompt/fragment one-liners

**Items:** #11, #13, #18, #19, #23, #27

### Reasoning

Six independent prompt/fragment edits, each a one-liner, each with a direct justification from the 2026-04-22 production run. Bundled into one project because they all touch `fragments/` or `commands/` prose, none touch helpers or schema, and reviewing six tiny commits separately would cost more than reviewing one bundle.

- **#11 — Deep validator 0–100 rubric fence.** Wave-1 deep validators in the 2026-04-22 run returned `severity: "medium"`, `overall_numeric: 3.0` (1–5 scale), `score_phase4: 6` (1–10 scale). The orchestrator had to interpret each. One explicit line in the Phase 4a prompt ("Your `score_phase4` is a single integer 0–100. Do not output a 1–5 or 1–10 scale.") removes the drift surface entirely.
- **#13 — Codex `ready` → `setup --json`.** `fragments/02-ensemble-adapter.md` uses `node "$CODEX_COMPANION" ready 2>&1 | grep -q ready` but the companion's actual CLI surface is `setup --json` which returns `{"ready": true, ...}`. Broken as-shipped for `--ensemble` unless the orchestrator improvises (which it did in the 2026-04-22 run).
- **#18 — Prior-comment informational note.** §0.14 skips the new-vs-existing-comment decision when §0.13 found a prior artifact with `current_state=open`. Users running `:review` repeatedly silently accumulate PR comments. One-line note during §0.14: "Prior comment `<url>` will remain. Delete on GitHub if you want it gone."
- **#19 — Codex stderr-vs-stdout comment.** Codex writes progress to stderr; `.out` is empty until completion. One comment next to the wait/poll loop in `02-ensemble-adapter.md` prevents the next reader from being misled.
- **#23 — Phase 0 foreground-only guidance.** An earlier stuck-session incident was traced to the orchestrator backgrounding Phase 0's deterministic setup script, then being unable to read its output. Prescriptive line at the top of Phase 0: "Run setup script in the foreground — do NOT use `run_in_background`. Output is needed inline for dirty-tree / branch-detect decisions."
- **#27 — Walkthrough between-iteration continue/stop anti-instruction.** The orchestrator sometimes dispatches a spurious continue/stop prompt after the first walkthrough iteration (emergent safety hesitation). Fix: one-line anti-instruction at the top of the per-finding loop in `commands/walkthrough.md` near step 5.3. LLMs respect this class of explicit anti-instruction reliably.

### Files likely touched

- `fragments/05-validation.md` (#11 — add rubric fence to Phase 4a deep prompt)
- `fragments/02-ensemble-adapter.md` (#13, #19)
- `fragments/00-preflight.md` (#18 during §0.14, #23 at the top)
- `commands/walkthrough.md` (#27 near step 5.3)

### Builder brief

For each of the six items, make the minimal edit described in Reasoning. Use the wording in Reasoning as the starting point, but adjust to fit the surrounding fragment's voice and existing formatting. After all edits, run `test/smoke.sh`. Report each edit as a separate bullet in the builder summary.

Confirm #13's actual codex companion CLI surface by running `node "$CODEX_COMPANION" --help` or `node "$CODEX_COMPANION" setup --json` if the companion is installed locally. If it's not installed, note that in the summary — the fix stands either way based on the ideas-file observation.

### Verifier checklist

- [ ] `git diff fragments/ commands/` shows six discrete prose changes, no structural changes.
- [ ] Each of #11, #13, #18, #19, #23, #27 has a corresponding diff hunk, verifiable by grep-ing the new text.
- [ ] #11's rubric fence text literally contains "0–100" and "Do not output a 1–5 or 1–10 scale" (or equivalent imperative).
- [ ] #13 no longer contains the string `node "$CODEX_COMPANION" ready`.
- [ ] #23's note appears at the top of Phase 0 and contains both "foreground" and "run_in_background".
- [ ] #27 contains "Do not dispatch" and "AskUserQuestion" in proximity near step 5.3.
- [ ] Smoke passes ≥ baseline.
- [ ] No changes outside the four files named above.

### Exit criteria

All six items reflected in the diff; smoke green; no out-of-scope edits.

### Commit message (draft)

```
fragments: bundle of prompt/fragment one-liners from 2026-04-22 run

- Phase 4a rubric fence (0–100 integer, not 1–5 / 1–10)          [#11]
- Ensemble adapter: `ready` → `setup --json` contract fix        [#13]
- Preflight §0.14: note prior PR comment stays on the PR         [#18]
- Ensemble adapter: codex-stderr progress comment                [#19]
- Phase 0: foreground-only guidance for setup script             [#23]
- Walkthrough 5.3: anti-instruction on between-iteration AUQ     [#27]

Closes post-conversion-ideas #11, #13, #18, #19, #23, #27.
```

### Estimated effort

~30 min. Six small prose edits.

---

## Project C — Infra housekeeping

**Items:** #15, #16, #21, #22, #25

### Reasoning

Five more one-liners, this batch in shell / git / frontmatter territory. Separate project from B because the file surface is different (non-prose) and bundling across surfaces would make the commit harder to review.

- **#15 — Phase 2 zsh word-splitting bug.** `for dupe in $dupes` inside a `while read` pipe doesn't split on whitespace as expected under macOS zsh; multi-dupe groups failed on first pass in the 2026-04-22 run. Fix: either array-based iteration (`dupes_arr=($dupes); for d in "${dupes_arr[@]}"`) or `jq -r '.[1:][]' | xargs -n 1`. Prefer the latter — it sidesteps shell-quoting footguns entirely and matches the bash-3.2 portability rule in CLAUDE.md.
- **#16 — Exclude `.claude/` from Phase 4.4.5 tree sweep.** ScheduleWakeup infra writes `.claude/scheduled_tasks.lock` during a run, which the validator tree sweep flagged as dirty-tree pollution (false positive, already noted in the trace). Nothing in `.claude/` is substantive to a code review. Fix: explicit `git status` ignore pattern or `git status --ignored=no -- . ':!.claude/'` in the sweep.
- **#21 — `Bash(line-range-check.sh:*)` grant in `commands/review.md`.** Pre-existing gap (not conversion-introduced). `fragments/01-detection.md` invokes the helper bare; the command's `allowed-tools` frontmatter doesn't list it. May cause a permission prompt. One-line frontmatter addition.
- **#22 — `bin/include text eol=lf` in `.gitattributes`.** `bin/include` has no extension so the existing `*.sh`/`*.py`/`*.json`/`*.md` patterns don't cover it. LF on disk today; belt-and-suspenders against a future editor writing CRLF.
- **#25 — Top-level `description` in `.claude-plugin/marketplace.json`.** `claude plugin validate .` warns `metadata.description: No marketplace description provided`. Benign, but adding a short description silences the warning and prepares the marketplace for an eventual second plugin.

### Files likely touched

- `fragments/03-dedup.md` or wherever the Phase 2 `for dupe in $dupes` sits (#15; grep to locate)
- `fragments/05-validation.md` Phase 4.4.5 tree sweep (#16)
- `commands/review.md` frontmatter `allowed-tools` (#21)
- `.gitattributes` (#22)
- `.claude-plugin/marketplace.json` (#25)

### Builder brief

1. For #15: grep `for dupe in` under `fragments/` to find the exact line. Prefer the `jq -r '.[1:][]' | xargs -n 1 …` pattern (confirm what the inner command needs as input first). Preserve the surrounding `while read` structure.
2. For #16: find the Phase 4.4.5 tree-cleanliness sweep in `fragments/05-validation.md`. Add `.claude/` exclusion (prefer `git status --porcelain -- . ':!.claude/'` or an equivalent pathspec).
3. For #21: open `commands/review.md`, add `Bash(line-range-check.sh:*)` to the `allowed-tools` list in frontmatter. Match existing formatting (comma vs. newline style).
4. For #22: append `bin/include text eol=lf` to `.gitattributes` in the matching section (grouped with other explicit-name entries, or append at end if none).
5. For #25: add `"description": "..."` at top level of `marketplace.json`. Draft text: "Personal multi-lens code review plugin for Claude Code." One sentence; keep under 80 chars.
6. Run `test/smoke.sh`.

### Verifier checklist

- [ ] #15: the `for dupe in $dupes` pattern no longer appears in `fragments/`. A replacement iteration pattern exists.
- [ ] #16: the Phase 4.4.5 sweep command includes a `.claude/` exclusion.
- [ ] #21: `commands/review.md` frontmatter lists `line-range-check.sh` under `allowed-tools`.
- [ ] #22: `.gitattributes` contains a line matching `bin/include` + `eol=lf`.
- [ ] #25: `marketplace.json` has a top-level `"description"` field; `claude plugin validate .` (if available) no longer warns about `metadata.description` (run it if the CLI is installed; skip if not and note).
- [ ] Smoke passes ≥ baseline.

### Exit criteria

All five items reflected in the diff; smoke green.

### Commit message (draft)

```
infra: housekeeping one-liners from 2026-04-22 run

- Phase 2 dedup iteration: jq/xargs instead of $dupes wordsplit   [#15]
- Phase 4.4.5 tree sweep: exclude .claude/ (lock-file false pos)  [#16]
- commands/review.md: grant line-range-check.sh bash permission   [#21]
- .gitattributes: enforce LF on bin/include (extensionless)       [#22]
- marketplace.json: top-level description (silences validator)    [#25]

Closes post-conversion-ideas #15, #16, #21, #22, #25.
```

### Estimated effort

~30 min.

---

## Project G — Origin crosscheck rename-following

**Items:** #9

### Reasoning

`bin/origin-crosscheck.sh` is rename-blind: when a PR creates a new file by extracting code from an existing file, `git blame` on the new file lights up as PR-introduced, and the crosscheck misses that the underlying mechanism existed on main. F038 in the 2026-04-22 run hit exactly this — the Phase 4 deep validator blamed `de004fb` as the "precipitating change" on `recategorization.ts`, when in fact the file was a refactor-extraction and the bug existed in its predecessor.

Fix: when the touched file is new in the PR (`git log --diff-filter=A $comparison_ref..HEAD -- <file>` non-empty), use `git log --follow` (or `git log --find-renames`) to trace history through the rename/extraction boundary and reach the pre-PR ancestor. If the underlying mechanism is fully reachable from `$comparison_ref`, force `pre_existing:high` per the existing override.

This is the one project that genuinely changes helper behavior, so the verifier should explicitly construct a fixture to exercise the new code path.

### Files likely touched

- `bin/origin-crosscheck.sh`
- `test/smoke.sh` (add 2–3 OC-* assertions for rename-follow cases)
- `test/fixtures/` (add a rename fixture repo if one doesn't already cover this)
- `CLAUDE.md` Helper index row for `origin-crosscheck.sh` — note the rename behavior
- Possibly `docs/archive/DESIGN.md` §21 — **DO NOT edit** per CLAUDE.md ("archive is frozen"); add behavior note to CLAUDE.md instead.

### Builder brief

1. Read the current `bin/origin-crosscheck.sh` end to end. Note its existing phases (blame → reachability → disposition).
2. Identify the decision point where it decides "this candidate is blame-traceable to the PR." Before concluding "PR-introduced," check whether the file itself was added in the PR:
   ```
   git log --diff-filter=A --format=%H "$comparison_ref..HEAD" -- "$file"
   ```
   If non-empty, the file is new in the PR. Re-run the reachability check against the pre-rename ancestor using `git log --follow --format=%H -- "$file"` and take the earliest SHA reachable from `$comparison_ref`.
3. If the underlying mechanism is reachable from `$comparison_ref` (via the rename-traced ancestor), force `pre_existing:high`.
4. Keep existing behavior for non-new files unchanged (bailout path).
5. Add a smoke fixture: a scratch repo with `main` containing `old-file.ts` (with a bug), a PR branch that renames it to `new-file.ts` via `git mv` + minor edit. Assert the crosscheck reports `pre_existing:high` on a finding targeting `new-file.ts`.
6. Add 2–3 OC-* assertions. Existing OC-* assertions in smoke are the shape to mirror.
7. Update `CLAUDE.md` Helper index row for `origin-crosscheck.sh` with a short sentence on rename handling.
8. Run `test/smoke.sh`.

### Verifier checklist

- [ ] `bin/origin-crosscheck.sh` now calls `git log --diff-filter=A` (or equivalent rename-detection command) on the candidate file.
- [ ] A rename-extraction fixture exists under `test/fixtures/`.
- [ ] At least 2 new OC-* smoke assertions cover the rename case.
- [ ] Existing OC-* assertions still pass (no regression on non-rename cases).
- [ ] `CLAUDE.md` Helper index row for `origin-crosscheck.sh` mentions rename-following.
- [ ] `docs/archive/DESIGN.md` is NOT edited (the archive is frozen per CLAUDE.md; behavior notes live in CLAUDE.md).
- [ ] Smoke passes ≥ baseline + 2.

### Exit criteria

Crosscheck handles the rename-extraction case; fixture proves it; smoke green; CLAUDE.md updated.

### Commit message (draft)

```
origin-crosscheck: follow renames when target file is new in PR

When git log --diff-filter=A shows the touched file was added in the
PR, trace history through --follow and re-run the reachability check
against the pre-rename ancestor. Catches refactor-extraction cases
where the underlying mechanism existed on main but blame lights up as
PR-introduced (e.g. F038 from the 2026-04-22 run).

Closes post-conversion-ideas #9.
```

### Estimated effort

~1.5–2 h. Fixture construction is the long pole.

---

## Project F — LLM output variance normalization

**Items:** #10, #12, #20

### Reasoning

Three items attacking the same structural problem: sub-agent JSON output is unreliable in three distinct ways, and the orchestrator compensates by improvisation, which:
1. Isn't testable.
2. Burns orchestrator tokens (each compensation is a turn).
3. Silently fails on edge cases.

Three layered helpers buy us a reliable boundary:

- **#20 `bin/parse-with-repair.py`** — the foundation. Wraps `json.loads` with a `jsonrepair` or `json5` fallback for the common LLM slop: trailing commas, single quotes, unescaped newlines, stray markdown fences. Replaces ad-hoc code-fence stripping across fragments with one helper. Would eliminate most "retry once then fail" paths because trailing-comma class failures become non-issues.
- **#12 `bin/parse-validator-result.py`** — built on `parse-with-repair.py`. Takes a Phase 4 validator's raw JSON output and normalizes all known shapes into the canonical schema. Known shapes from the 2026-04-22 run: `score_phase4: int`, `score.correctness: int`, `score: {...}`, `overall_numeric: float` (1–5 scale), `severity: string` (low/medium/high). Normalizes to `{score_phase4: int (0–100), actionability: string, confirmed_strength: string}`. Removes the orchestrator's improvisation burden at Phase 4 dispatch and makes the behavior testable.
- **#10 `source_family` normalization** — a post-hoc mapping table in the Phase 1 join step. L4 returned `"stale-line-ref"` / `"stale-behavior-claim"`; L6 returned `"prompt-injection"` / `"input-validation"` / `"path-traversal"` / `"terminal-injection"`. Prompts already spell out the canonical families (`policy-family`, `security-family`, etc.) but Sonnet drifts under its own taxonomic urges. A mapping table with an allowlist + "reject unknowns" behavior is less fragile than tightening prompt fences, which keeps losing to model rewrites.

### Ordering

Build bottom-up: #20 (foundation) → #12 (uses #20) → #10 (uses #20, integrates at join step).

### Integration scope (middle path — decision locked 2026-04-22)

- **#20 helper itself:** fully built + smoke tested in this session.
- **#20 call-site migration:** the `fragments/02-ensemble-adapter.md` normalizer step IS migrated to use `parse-with-repair.py` as part of this project. This is the highest-value legacy site (external-tool output is messier than your own sub-agents' output) and serves as the real-world integration test for the helper. **Other legacy ad-hoc JSON parse sites across fragments remain unmigrated this session** — they can be addressed incrementally in future sessions once the helper's contract has proven itself.
- **#12 helper + integration in Phase 4 validation fragment:** both in scope. The call site IS the fix. Fragment calls `parse-validator-result.py` on each validator's raw JSON output and reads back the canonical shape.
- **#10 helper + integration in Phase 1 join step:** both in scope. The join step calls the mapping table; rejects + flags unknown families rather than silently passing them through.

### Files likely touched

- `bin/parse-with-repair.py` (new helper)
- `bin/parse-validator-result.py` (new helper)
- `bin/source-family-map.py` or `.sh` (new helper for #10 — lean toward Python for the mapping/allowlist logic)
- `fragments/02-ensemble-adapter.md` (migrate normalizer step to use `parse-with-repair.py` — middle-path decision)
- `fragments/05-validation.md` (integrate #12 at Phase 4a/4b dispatch)
- `fragments/01-detection.md` (integrate #10 at the join step)
- `commands/review.md` frontmatter `allowed-tools` (grant bare-name bash perms for the three new helpers)
- `test/smoke.sh` (FR-* assertions already exist; add new PR-* or similar namespace for parse-with-repair and validator-result)
- `test/fixtures/` (malformed-JSON fixtures for #20; scale-variance fixtures for #12; drift-family fixtures for #10)
- `CLAUDE.md` Helper index + Operational rules (if a new rule emerges)

### Builder brief

**Step 1 — #20 `parse-with-repair.py`.**

Contract:
```
parse-with-repair.py < input.json > output.json
# exit 0: output.json is valid JSON (repaired if needed)
# exit 1: unrecoverable even with repair
```

Library choice: `jsonrepair` (Python port) is the first pick. Fallback: hand-written repair for trailing commas + code-fence stripping + single-quote-to-double-quote. Use PEP 723 shebang per Operational rule 2. Error-as-prompt stderr per rule 4.

Smoke: 4–5 assertions covering trailing-comma, single-quote, code-fence wrapping, unescaped newline, and unrecoverable garbage (exit 1 expected).

**Step 2 — #12 `parse-validator-result.py`.**

Contract:
```
parse-validator-result.py --lane deep|light < raw.json > canonical.json
# Takes a Phase 4 validator's raw JSON (known-varied shape).
# Emits canonical: {score_phase4: int, actionability: string, confirmed_strength: string, notes: string}
# Uses parse-with-repair internally.
# Rejects outputs where no score field can be coerced to 0–100 (exit 2).
```

Known input shapes to handle:
- `{score_phase4: int}` — pass through.
- `{score: {correctness: int}}` — extract + pass through.
- `{overall_numeric: float}` on 1–5 scale — multiply by 20.
- `{severity: "low|medium|high"}` — map to buckets (35 / 60 / 85) and attach a `scale_inferred: true` flag in `notes`.
- `{score: 6}` with no scale hint — heuristic: if value ≤ 10, treat as 1–10 scale (multiply by 10); else if ≤ 100, pass through. Flag `scale_inferred: true`.

Smoke: assertion per input shape + one malformed case (exit 2).

**Step 3 — #10 source-family mapping.**

Simplest shape: a Python helper with an embedded mapping dict.

```
source-family-map.py --input raw_family > canonical_family
# exit 0: known family, canonical on stdout
# exit 3: unknown family, stderr includes "UNKNOWN_FAMILY: <raw>"
```

Canonical families (confirm from existing codebase / DESIGN.md before hardcoding): `correctness-family`, `security-family`, `ux-family`, `policy-family`, `architecture-family`. Map table covers at minimum the drift cases from 2026-04-22: `stale-line-ref → policy-family`, `stale-behavior-claim → policy-family`, `prompt-injection → security-family`, `input-validation → security-family`, `path-traversal → security-family`, `terminal-injection → security-family`.

Integration in `fragments/01-detection.md`: at the join step, pipe each candidate's `source_family` through this helper. On exit 3, log the unknown family and DROP the candidate (or flag for orchestrator escalation — pick one, be explicit in the fragment comment).

Smoke: happy path per canonical family + 1 drift case per → canonical mapping + 1 unknown case (exit 3).

**Step 4 — migrate ensemble-adapter normalizer to `parse-with-repair.py`** (middle-path integration for #20). Locate the normalizer step in `fragments/02-ensemble-adapter.md` where external-tool JSON is parsed — it currently has its own ad-hoc strip-code-fence-then-`jq` dance. Replace with `parse-with-repair.py < raw.json > clean.json` and pipe `clean.json` to the existing downstream `jq` handling. Preserve any existing retry/fallback semantics (on unrecoverable input, existing behavior was "retry once with sterner prompt"; keep that retry path — the helper exiting non-zero is the trigger).

**Step 5 — integrate #12 in `fragments/05-validation.md`** at the Phase 4a dispatch point. Replace orchestrator "interpret the score" prose with explicit `parse-validator-result.py --lane deep < validator-output.json` invocation.

**Step 6 — integrate #10 in `fragments/01-detection.md`** at the join step. Replace any current trust-the-lens handling with `source-family-map.py` filter.

**Step 7 — grant bare-name bash permissions** for the three new helpers in `commands/review.md` frontmatter `allowed-tools`: `Bash(parse-with-repair.py:*)`, `Bash(parse-validator-result.py:*)`, `Bash(source-family-map.py:*)`.

**Step 8 — update `CLAUDE.md` Helper index** with three new rows (reader/utility as appropriate).

**Step 9 — run `test/smoke.sh`** expecting ≥ baseline + ~12 new assertions (4 for #20, 5 for #12, ~3 for #10). Include at least one smoke assertion that exercises the ensemble-adapter normalizer path with a malformed-JSON fixture to prove the middle-path migration works end-to-end.

### Verifier checklist

- [ ] Three new helpers exist under `bin/` with PEP 723 shebang (or bash shebang if bash is used).
- [ ] Each helper has `--help` output (per error-as-prompt rule).
- [ ] `parse-with-repair.py` handles all four LLM slop classes listed in the builder brief.
- [ ] `parse-validator-result.py` handles all five known input shapes and outputs canonical schema.
- [ ] `source-family-map.py` rejects unknown families with exit 3 and `UNKNOWN_FAMILY:` stderr.
- [ ] `fragments/02-ensemble-adapter.md` invokes `parse-with-repair.py` at the normalizer step (middle-path integration).
- [ ] `fragments/05-validation.md` invokes `parse-validator-result.py` by bare name.
- [ ] `fragments/01-detection.md` invokes `source-family-map.py` by bare name.
- [ ] `CLAUDE.md` Helper index has new rows for all three helpers (with purpose and lang).
- [ ] `commands/review.md` frontmatter `allowed-tools` grants new helpers' `Bash(...:*)` bare-name permissions.
- [ ] Smoke passes with ≥ baseline + ~10 assertions, including at least one end-to-end assertion exercising the ensemble-adapter normalizer with malformed input.
- [ ] No call-site migration for `parse-with-repair.py` beyond the ensemble-adapter normalizer (middle-path boundary). Other legacy ad-hoc JSON parse sites in fragments remain untouched.

### Exit criteria

All three helpers built and tested, two integrations landed in fragments, allowed-tools and CLAUDE.md updated, smoke green.

### Commit strategy

Prefer **one commit per helper** (three commits: #20+ensemble-adapter migration, #12+Phase-4 integration, #10+Phase-1 integration) to keep blast radius bounded in history. Builder can stack them; verifier verifies at end. If one helper fails verification, revert just that commit; the others stand.

### Commit messages (draft, one per helper)

```
bin/parse-with-repair + fragments/02-ensemble-adapter: tolerant JSON parser

Wraps json.loads with a repair layer (trailing commas, code-fence
stripping, single-to-double quote coercion). Migrates the ensemble-
adapter normalizer step as the real-world integration proof — highest-
value legacy site since external-tool output is messier than the plugin's
own sub-agents. Other legacy ad-hoc parse sites remain untouched this
session; broader migration deferred per plan §9 decision 1.

Closes post-conversion-ideas #20.
```

```
bin/parse-validator-result + fragments/05-validation: normalize shapes

Phase 4 validators returned score_phase4 in 1–5 / 1–10 / 0–100 /
severity-string shapes in the 2026-04-22 run. Helper normalizes all
known shapes to canonical {score_phase4, actionability, strength}.
Fragment invokes the helper at each validator dispatch.

Closes post-conversion-ideas #12.
```

```
bin/source-family-map + fragments/01-detection: canonical family filter

Mapping table rejects lens-drift families (stale-line-ref, prompt-
injection, path-traversal, etc.) and maps to canonical families.
Integrates at the Phase 1 join step so downstream source_families
filters stay reliable.

Closes post-conversion-ideas #10.
```

### Estimated effort

~3–4 h (largest project in the session). Fixture construction and integration testing dominate.

---

## Project D (partial) — `confirmed_auto` rename + Phase 3 telemetry

**Items:** #1A (rename), #24 (instrumentation only — decision deferred)

### Reasoning

**#1A rename.** `confirmed_auto` has two meanings: deep-lane (auto-applies via Phase 8) and light-lane (skipped unless `human_confirmation` set via `:promote` or `:walkthrough`). The name implies Phase 8 will apply it; for light-lane findings, it won't. Rename the disposition to `confirmed_mechanical` to drop the false implication. Schema + fragment + helper + doc + smoke all touch the string; this is a coordinated rename.

**Not renaming `is_actionable` or the dispositions `partial` / `regression`** — those are unambiguous.

**#24 telemetry.** The 2026-04-22 run had 24 of 37 post-dedup candidates land `below_gate` (65%). Phase 3's err-up rubric is intentionally conservative, but 65% demoted means Phase 3 is doing a lot of Phase 4's work prematurely. Decision deferred (needs ~10 reviews of data), but **instrumentation** — writing the demote rate and `score_phase3` distribution to `phases.jsonl` at each Phase 3 close — is executable now and gates the data collection.

### Files likely touched

**For #1A (rename):**
- `bin/schema-v1.json` — `disposition` enum list
- `bin/artifact-patch.py` — the three disposition constants + invariant checks + error-as-prompt messages
- `bin/artifact-render.py` — section selectors that key on `confirmed_auto`
- `fragments/05-validation.md` — Phase 4 disposition assignment prose
- `fragments/08-fix-prep.md` or wherever Phase 8's gate lives — the eligible-finding filter
- `fragments/07-finalize.md` if it enumerates dispositions
- `commands/fix.md` — documentation
- `commands/walkthrough.md` — documentation
- `commands/promote.md` — documentation
- `CLAUDE.md` — the disposition table in the Finding state model section, plus any Phase 8 fix gate prose
- `test/smoke.sh` — every FR-* / FX-* assertion that references `confirmed_auto` verbatim
- `test/fixtures/` — any artifact fixtures with `confirmed_auto` in them

**For #24 (telemetry):**
- `fragments/04-scoring-gate.md` — Phase 3 close logging
- `bin/log-phase.sh` — confirm the event shape accommodates the new metric
- `test/smoke.sh` — new assertion that Phase 3 phase event contains `demote_rate` field

### Builder brief

**Step 1 — #1A rename.**

1. `grep -rn 'confirmed_auto' .` to enumerate every call site (fragments, helpers, commands, CLAUDE.md, smoke, schema). Expect 30–60 hits.
2. Make the rename across all files in one pass. Use `grep -rl 'confirmed_auto' . | xargs sed -i '' 's/confirmed_auto/confirmed_mechanical/g'` on macOS (or equivalent); then re-grep to confirm zero hits remain.
3. Update `schema-v1.json` disposition enum: replace `"confirmed_auto"` with `"confirmed_mechanical"`.
4. Update `CLAUDE.md` Finding state model disposition table row + Phase 8 fix gate pseudocode + any mention in prose.
5. Run `test/smoke.sh`. Several FR-* / FX-* assertions will fail until their expected strings are updated; update them.
6. Dry-run validation: construct an artifact fixture with one `confirmed_mechanical` finding and confirm `artifact-patch.py --apply-decisions` round-trips without rejection.

**Step 2 — #24 telemetry.**

1. Find the Phase 3 close step in `fragments/04-scoring-gate.md`. At the `log-phase.sh` call that closes Phase 3, add a computed field: `demote_rate = below_gate_count / total_candidates`.
2. Pass `demote_rate` and a histogram of `score_phase3` (buckets of 10: [0–9, 10–19, …, 90–100]) into the phase-close log event. If `log-phase.sh` needs a shape extension to accept arbitrary JSON payloads, add it (keep backward compatible).
3. Add one smoke assertion that a synthetic Phase 3 close writes a `phases.jsonl` line containing `demote_rate` and `score_phase3_histogram`.
4. Update `CLAUDE.md` Pipeline shape Phase 3 row to mention the new telemetry.

**Step 3 — run full smoke.**

Expect all assertions green. Count should be ≥ baseline + 1 (the telemetry assertion). `confirmed_auto → confirmed_mechanical` is a rename, not an addition, so assertion count doesn't move on #1A alone.

### Verifier checklist

- [ ] `grep -rn 'confirmed_auto' .` returns ZERO hits across the repo.
- [ ] `grep -rn 'confirmed_mechanical' .` shows the rename landed in: schema, artifact-patch.py, artifact-render.py, smoke, CLAUDE.md, at least one validation fragment, at least one command.
- [ ] `schema-v1.json` disposition enum contains `confirmed_mechanical` and NOT `confirmed_auto`.
- [ ] `CLAUDE.md` Finding state model disposition table has `confirmed_mechanical`.
- [ ] Smoke green ≥ baseline + 1 (the new telemetry assertion).
- [ ] `phases.jsonl` from a smoke synthetic run contains `demote_rate` and `score_phase3_histogram` on the Phase 3 close event.
- [ ] No behavior change in disposition assignment (only the label changed).
- [ ] No changes to `is_actionable` derivation logic.
- [ ] `docs/archive/` is NOT edited (frozen).
- [ ] Commits are two separate ones (rename + telemetry) so either can be reverted independently.

### Exit criteria

Rename complete across all files; Phase 3 telemetry lands in `phases.jsonl`; smoke green ≥ baseline + 1.

### Commit messages (draft, two commits)

```
schema: rename disposition confirmed_auto → confirmed_mechanical

confirmed_auto's name implied Phase 8 auto-application, but light-lane
findings with that disposition are gated unless human_confirmation is
set. Renaming drops the false implication. No behavior change — pure
label rename across schema, helpers, fragments, commands, smoke,
CLAUDE.md.

Closes post-conversion-ideas #1A.
```

```
fragments/04-scoring-gate: log Phase 3 demote rate + score histogram

Adds demote_rate and score_phase3 bucket histogram to the Phase 3
close event in phases.jsonl. Enables the #1B/#1C and #24 threshold-
calibration decisions once ~10 reviews of data accumulate.

Part of post-conversion-ideas #24 (decision deferred until data
collected).
```

### Estimated effort

~1.5–2 h. Rename is mechanical but touches many files; the grep/replace/re-grep cycle is the careful part.

---

## 7. Session close-out

After the final project (D.partial) exits, the orchestrator:

1. Final `test/smoke.sh` — paste the full last line of output into the Build Journal.
2. `git log --oneline <BASELINE_SHA>..HEAD` — paste into the Build Journal so the session's full commit stack is visible.
3. **CLAUDE.md drift sweep.** Read `CLAUDE.md` end-to-end against the net session diff. Specifically check these sections for missed updates:
   - **Pipeline shape** — Does it still describe what Phases 0–9 do correctly? (Project B edits Phase 0 / 4a / 4.4.5; Project F edits Phase 1 join + Phase 4 dispatch; Project D edits Phase 3 close.)
   - **Finding state model / disposition table** — Does it list `confirmed_mechanical` (not `confirmed_auto`)? Project D's rename.
   - **Score gates** — Phase 3 demote-rate telemetry mentioned if relevant.
   - **Helper index** — Rows for `parse-with-repair.py`, `parse-validator-result.py`, `source-family-map.py` (Project F). Row for `origin-crosscheck.sh` mentions rename-following (Project G). Row for `orchestrator-tokens.sh` updated if Project A's sanity check found a bug.
   - **Operational rules** — No new rule is required by any project in scope, but sweep to confirm none of the rule statements contradict the new behavior.

   If drift is found: fix it in a dedicated commit `CLAUDE.md: close-out drift fixes from 2026-04-22 session` (with Co-Authored-By trailer). If CLAUDE.md is already clean, note "CLAUDE.md drift check: clean" in the Build Journal and skip the commit.
4. Update `plans/post-conversion-ideas.md`:
   - For every item now COMPLETE, strike through the entry or prefix with `~~DONE (YYYY-MM-DD)~~`. Also flip the item's pre-flight `> Scheduled 2026-04-22:` marker to `> DONE 2026-04-22: <commit-sha>`.
   - For any item BLOCKED, change its `> Scheduled` marker to `> Blocked 2026-04-22: <reason>, see plans/post-plugin-improvements.md §6 Build Journal`.
   - The "Priority ordering" section at the bottom of the file should be updated to reflect new state.
   - Commit as `plans/: close-out post-plugin-improvements session (2026-04-22)`.
5. If any projects are BLOCKED, write a `## Blockers for follow-up` section at the bottom of this plan naming each blocker + pointing to the verifier output in the Build Journal.
6. Do NOT auto-open a PR. The user reviews commits locally and opens the PR manually.

---

## 8. Budget & pacing notes

Rough time budget if all projects pass first-try verification:

| Project | Est. | Budget cap |
|---|---|---|
| A | 45 min | 75 min |
| B | 30 min | 60 min |
| C | 30 min | 60 min |
| G | 2 h | 3 h |
| F | 4 h | 6 h |
| D.partial | 2 h | 3 h |
| **Total** | **~9 h 45 min** | **~16 h** |

Token pacing: if orchestrator context starts approaching compaction, dispatch the NEXT project's builder immediately and hard-stop the session after current project commits. Do NOT try to power through with a compacted orchestrator — leave the Build Journal in a clean state for a follow-up session instead.

---

## 9. Decisions record (locked 2026-04-22 during plan review)

Four scope decisions were resolved before plan approval. Each is cross-referenced to where it lands in the plan.

1. **Project F call-site migration scope — middle path.** `parse-with-repair.py` is built as a foundation AND the `fragments/02-ensemble-adapter.md` normalizer step is migrated to use it as the real-world integration proof. Other legacy ad-hoc JSON parse sites across fragments stay unmigrated this session. Rationale: ensemble-adapter sees the messiest LLM slop (external-tool output), so migrating it is the highest-value single legacy site and simultaneously exercises the helper against realistic input. Broader migration is a cheap incremental follow-up once the helper's contract has proven itself. *Reflected in:* Project F Integration scope, Files likely touched, Builder brief Step 4, Verifier checklist, Commit strategy.

2. **Stage 4 out of scope for this session.** Stage 4's own plan (`plans/stage-4-fragment-shrink.md`) requires a dedicated plan-approval round-trip per its own header. Attempting it inside this session risks orchestrator-context compaction mid-execution and dilutes reviewer attention on the 10 fragments that need semantic-preserving restructure. *Reflected in:* §2 Scope. *Follow-up tracking:* §5 Pre-flight Step 5 annotates `plans/post-conversion-ideas.md` entries #2 and #14 with `> Deferred 2026-04-22: dedicated session per plans/stage-4-fragment-shrink.md`.

3. **Blocker handling — continue, with inter-project sanity smoke guardrail.** On 3-iteration failure, project is marked BLOCKED and session continues. BUT between every project, the orchestrator runs `test/smoke.sh` itself as a cheap infrastructure-corruption check. If sanity smoke fails or regresses below baseline, the session halts — that class of blocker is qualitatively different (infrastructure-corrupting) and requires human diagnosis. *Reflected in:* §3 Per-project loop step 4, §4 Global invariants #7.

4. **Commit trailers — match existing repo convention.** Every project commit ends with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` (matches `a97fa03`, `721a03b`, etc.). Commit body style follows `095a741`'s "what's in each file" template. *Reflected in:* §4 Global invariants #6.

### Prerequisites captured during plan review, not in the original draft

- Token/LLM cost analysis was done before approval: session execution cost is ~1.5M–2M tokens (one-time), concentrated in Project F. Per-review cost after shipping is flat to 5–15% cheaper, driven almost entirely by Project F replacing orchestrator improvisation turns with deterministic Python helpers. Session pays for itself in 2–4 review runs.

---

*End of plan.*
