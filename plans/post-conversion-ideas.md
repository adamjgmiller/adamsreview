# Post-conversion ideas

> **Historical record as of 2026-04-22.** This file is the chronological idea log for the plugin-conversion era. Eighteen items were executed in the 2026-04-22 session (see `> DONE` markers and `plans/post-plugin-improvements.md`). **For the forward-looking, prioritized view of everything still open, read [`plans/backlog.md`](./backlog.md).** This file is preserved for the original rationale / trigger wording on each item — edit it only to flip new items' scheduling markers as sessions complete them.

Architectural backlog for after the plugin conversion lands. Nothing here is
committed work. Each item has a trigger/signal for when to revisit so this
stays a real backlog rather than a pile of "maybe someday."

Pulled from conversations during the conversion plan review (see
`plans/plugin-conversion-flow.md` §5 for the visual + full trade-off
discussion on the items that came from there).

---

## 0. [HIGH PRIORITY] Simplify orchestrator-tokens display — drop cache lines

> DONE 2026-04-22: plans/post-plugin-improvements.md Project A — commit 3009c07

Current rendered line (from a real run):

> `53,046,666 cache-read / 566,990 output / 2,134,808 cache-creation / 484 fresh input across 324 turns`

Two problems:

1. **TMI.** Four counters in a status line is noise. The day-to-day signal
   users care about is "how much did this cost" at a glance. Fresh input +
   output are the user-facing levers (what the orchestrator sent, what it
   produced); cache-read and cache-creation are implementation detail about
   prompt-cache plumbing.
2. **Cache-read number looks wrong.** 53M cache-read tokens across 324 turns
   is ~164K tokens/turn of cache-read, which is plausible for a huge
   context being re-read every turn — but worth sanity-checking. Possible
   the summation in `bin/orchestrator-tokens.sh` is double-counting (e.g.,
   including cache-read across BOTH the main session AND sub-session
   transcripts under the same cwd, or re-counting cache hits that span
   multiple `message.usage` entries).

**Proposed fix:**

- Keep the four-counter capture internally (useful for cost diagnostics).
- Change the rendered string to just: `<output> output / <fresh_input> input across <N> turns`.
- Before shipping: spot-check one run by summing `cache_read_input_tokens`
  manually from the session transcript vs. the helper's output. If they
  diverge, the helper has a bug; fix that first.

Touchpoints: `bin/artifact-render.py` (rendered string) and `bin/orchestrator-tokens.sh` (the sanity-check). Schema keeps all four fields.

*Trigger:* next session after plugin-conversion merges. Highest priority in this backlog — trivial edit, immediate UX win.

---

## 1. Light-lane asymmetry (most substantive)

The asymmetry: `confirmed_auto` has two meanings. Deep-lane (correctness,
security) auto-applies via Phase 8. Light-lane (ux, policy, architecture)
gets skipped unless `human_confirmation` is set via `:promote` or
`:walkthrough`. The walkthrough exists specifically to close that gap.

### Collect data first

Over the next ~10 reviews, track walkthrough behavior:

- If you mostly **promote without editing the hint** → Phase 4b's fix shape
  is usually right; walkthrough is rubber-stamping. Lift the filter or
  switch to per-lane thresholds (options B/C below).
- If you mostly **edit the hint or skip** → walkthrough is earning its keep.
  Keep current shape; consider only option A (rename for clarity).
- If you **rarely run walkthrough at all** → light-lane findings are falling
  on the floor. Either codify walkthrough into your flow or lift the filter.

### Options, ranked by invasiveness

**A. Rename for clarity (cheap; always worth doing).** Rename
`confirmed_auto` to something clearer for light-lane, e.g.
`confirmed_mechanical`. Current name implies Phase 8 will apply it; it
won't. Schema + fragment + doc edits, ~half-day.
*Trigger:* whenever you've got a quiet afternoon.

> DONE 2026-04-22: plans/post-plugin-improvements.md Project D.partial (#1A rename) — commit 8e3453b

**B. Per-lane thresholds (better than hard filter).** Replace the lane
filter with `score_phase4 ≥ threshold_for(impact_type)` where
`threshold_for(correctness|security) = 60` and
`threshold_for(ux|policy|architecture) = 75`. Smooth continuum, still
asymmetric, more principled.
*Trigger:* data says walkthrough sometimes earns its keep but not always.

> Deferred 2026-04-22: awaiting ~10 reviews of data from Project D telemetry

**C. Lift filter, trust Phase 9a (simplest).** Phase 9a Opus post-fix
review runs on every surviving group. If it catches semantic mistakes
reliably, the lane filter is redundant. Risk: Phase 9a sees the diff, not
the intent — reworded error messages that subtly change meaning might slip
through.
*Trigger:* data says walkthrough rubber-stamps AND Phase 9a catches
semantic mistakes in practice.

> Deferred 2026-04-22: awaiting ~10 reviews of data from Project D telemetry

**D. Move decision upstream into Phase 4b (largest refactor).** Light-lane
validators default to `actionability=manual` unless explicit evidence of
"fix is a one-line rename with no semantic change" etc. Asymmetry becomes a
validator-prompt thing, not a gate. Walkthrough becomes pure inspection.
*Trigger:* probably never; the value isn't worth the refactor.

**E. Collapse lanes entirely (most expensive).** One Opus Phase 4 for
everything. Simplest architecture, highest cost.
*Trigger:* cost becomes irrelevant.

---

## 2. Stage 4 fragment-shrink (already planned, deferred)

> DONE 2026-04-23: plans/stage-4-fragment-shrink.md — commit range 84c96ee..f9ccda0 on branch `stage-4-fragment-shrink` (21 commits; close-out at e1af3e9, f9ccda0 is a post-close self-review reconcile). Measurements in plan Appendix B; backlog entry at `plans/backlog.md` §2 item #2.

Consolidate fragments where the boundary is arbitrary. Plan exists at
`plans/stage-4-fragment-shrink.md`. Post-conversion is a natural time to do
it — all `!include` paths are stable by then, and the migration already
touched every fragment.

*Trigger:* whenever the fragment count feels like it's costing more than it
saves (confused greps, stale cross-references, or "which fragment does
X live in?" moments).

---

## 3. Helper layout — flat vs subdirs

Currently 20 scripts flat under `bin/`. Could split into
`bin/readers/`, `bin/writers/`, `bin/utilities/` (mirrors the helper index
in CLAUDE.md). Trade-off: subdirs mean longer `allowed-tools` paths and a
less-flat discovery surface via `ls bin/`.

*Trigger:* when `ls bin/` stops fitting on one screen, or a new maintainer
asks where things are.

---

## 4. `codex:codex-rescue` / `coderabbit:code-reviewer` as first-class plugin agents

Ensemble mode already dispatches both via the ensemble adapter. Post-
conversion they could be first-class plugin sub-agents referenced by
`subagent_type` instead of shell-outs. Fewer process boundaries, structured
output. Trade-off: requires those plugins be installed at plugin-load time
rather than discovered by the adapter at dispatch time.

*Trigger:* ensemble mode becomes the default for your reviews (current
default is off).

---

## 5. PostToolUse hook for `attempted`-never-committed detection

Currently Phase 7 detects leftover `attempted` findings and hard-aborts. A
PostToolUse hook on `Bash(git commit:*)` could catch the gap earlier (commit
fired but Phase 9c didn't update the artifact to `resolved`).

Overkill for personal use; current gate works.

*Trigger:* probably never. Revisit only if you hit the leftover-attempted
hard-abort more than once in a quarter.

---

## 6. Single-command-with-subcommands shape

`/adamsreview review` / `/adamsreview fix` instead of `/adamsreview:review`
/ `/adamsreview:fix`. More conventional CLI. Loses Claude Code's native
five-command model (each with its own `allowed-tools` / `argument-hint` /
`description` frontmatter).

*Trigger:* probably never. The five-command model is working and plugin
namespacing (D18) makes it idiomatic.

---

## 7. SessionStart hook expansion

Currently only runs `dep-check.sh`. Could default
`ADAMS_REVIEW_REVIEWS_ROOT`, warm a `gh auth status` check, precompute
`repo_slug`. Recommendation: **don't**. Hook output injects into session
context and burns tokens every turn — anything environmental that can live
in a Python helper should live there.

*Trigger:* only if a specific high-value use case emerges that can't live in
a helper called by the first phase that needs it.

---

## 8. `latest.txt` vs explicit `--review-id`

Lifecycle commands resolve artifact via `latest.txt`. Failure mode: user
ran `:review` in a different branch between commands → `latest.txt` is
stale. Alternative: require `--review-id` on `:add` / `:fix` /
`:walkthrough`. Recommendation: **don't**. Personal-use tool, `latest.txt`
does its job; adding a required flag is friction for a rare failure mode.

*Trigger:* only if the stale-pointer failure mode bites in practice.

---

---

# Post-first-production-review findings

First real `/adamsreview:review --ensemble` run under the plugin conversion landed 2026-04-22 against `ray-finance/feat/import-apple` PR #8, rev `rev_01KPVDH50WY7JSTEXFWYDNGQNH`. 38 findings, 8 `confirmed_auto`, full lens fan-out worked, comment published. Everything below is quality/robustness cleanup surfaced by the run — not conversion-blocking, but concrete and repeatable.

The items split into (A) things the orchestrator flagged mid-run, and (B) orchestrator-side observations pulled from the trace afterward.

## A. Agent-observed quality issues

### 9. Origin cross-check is rename-blind

> DONE 2026-04-22: plans/post-plugin-improvements.md Project G — commit 55ea067

F038's mechanism existed on main before the PR. The Phase 4 deep validator called `de004fb` the "precipitating change" because `git blame` on `recategorization.ts` lit up as PR-introduced — the file was created in the PR via code extraction from a predecessor. Pre-existing detection doesn't follow renames, so refactors that move code into a new file hide real pre-existing bugs from the crosscheck.

**Fix**: teach `origin-crosscheck.sh` to follow `git log --follow` (or `--find-renames`) when the touched file is new in the PR, or have the Phase 4 deep validator explicitly `git show main:<related-file>` when a finding targets a newly-created file.

*Trigger:* when a refactor-heavy PR produces a false "new bug" for code that existed before. Once is a blip; twice means fix it.

### 10. Lens `source_family` normalization is voluntary

> DONE 2026-04-22: plans/post-plugin-improvements.md Project F — commit 95dc23d

L4 returned `"stale-line-ref"`/`"stale-behavior-claim"`; L6 returned `"prompt-injection"`/`"input-validation"`/`"path-traversal"`/`"terminal-injection"` instead of the prescribed `policy-family`/`security-family`. The prompts spell out the canonical families but Sonnet drifts under its own taxonomic urges. The orchestrator hand-overrode both.

**Fix**: either a post-hoc mapping table in the join step (lens-output → canonical family; reject unknowns), or stricter "return ONLY these exact strings" fence language in the lens prompts. A mapping table is less fragile — prompt fences keep losing to model rewrites.

*Trigger:* now, if you want downstream filters (`source_families: ["security-family"]`) to stay reliable. Pair with item #12.

### 11. Deep-lane validators drift off the 0–100 rubric

> DONE 2026-04-22: plans/post-plugin-improvements.md Project B — commit f0d7f19

F018 returned `severity: "medium"`, `overall_numeric: 3.0` (1–5 scale). F024 returned `score_phase4: 6` (probably 1–10). F025 returned `score.correctness: 6`. The orchestrator had to interpret and re-score each for the `--apply-decisions` batch.

**Fix**: add one explicit line to the Wave-1 deep prompt: "Your `score_phase4` is a single integer 0–100. Do not output a 1–5 or 1–10 scale." Two-word fix, huge reliability win.

*Trigger:* now. This is a prompt-engineering one-liner with no downside.

### 12. Validator output parsing should tolerate schema variance

> DONE 2026-04-22: plans/post-plugin-improvements.md Project F — commit 95dc23d

Related to #11 — but even with a 0–100 fence, validators return JSON with varied shapes (`score_phase4`, `score.correctness`, nested `score: {...}`, scale-encoded floats). The orchestrator compensates by interpreting. A `bin/parse-validator-result.py` helper that normalizes all known shapes into the canonical schema would remove the orchestrator's improvisation burden and make the behavior testable.

*Trigger:* bundle with #11 if a fix is landing; otherwise when schema variance bites in CI-mode review runs where there's no orchestrator to compensate.

### 13. Codex companion `ready` subcommand doesn't exist

> DONE 2026-04-22: plans/post-plugin-improvements.md Project B — commit f0d7f19

`fragments/02-ensemble-adapter.md` says:
```
node "$CODEX_COMPANION" ready 2>&1 | grep -q ready
```
Actual surface is `setup --json` which returns a `{"ready": true, ...}` structure. Probably drifted from an earlier companion CLI version.

**Fix**: one-line edit in the ensemble-adapter fragment. Confirm via running the codex companion manually and reading its `--help`.

*Trigger:* now. Broken as-shipped for `--ensemble` users unless the orchestrator improvises (which it did).

### 14. Fragment inlining can exceed the preprocessor's capacity

> DONE 2026-04-23: plans/stage-4-fragment-shrink.md step 4.0 + 4.A.0 — commits 84c96ee (Appendix A investigation) + 5b95bb6 (manifest-style conversion). Stage 4 chose option (c) "manifest-style command bodies": every `!include X.md` in the 5 command files replaced with a `Read fragments/X.md` directive, eliminating the post-v2.1.2 `<persisted-output>` silent-truncation failure mode. Backlog entry at `plans/backlog.md` §2 item #14.

During the run, the command's `!`include`` preprocessor persisted Phases 0, 1.5, and 2–6 inline but truncated Phases 1 and 3 to 2 KB "previews." The orchestrator had to `Read fragments/NN.md` directly to recover the rest.

**Fix options:**
- **Smaller manifest-style command.** Command body lists phases with explicit `Read fragments/NN.md` instructions; the fragments aren't inlined at preprocess time but fetched lazily by the orchestrator. Trades startup prompt size for a handful of `Read` calls.
- **Split fragments further.** Stage 4 (fragment shrink) is already scoped for this; the persistence-truncation is fresh evidence the ceiling is real and needs attention.
- **Check the actual cap** — if it's an output-size limit on bash-subprocess expansion in command preprocessing, moving to `Read` calls side-steps it entirely.

*Trigger:* Stage 4 gets prioritized. Already in `plans/stage-4-fragment-shrink.md`; this run gives it a forcing function.

### 15. Shell subshell word-splitting bit Phase 2 on macOS zsh

> DONE 2026-04-22: plans/post-plugin-improvements.md Project C — commit 10d200d

```
for dupe in $dupes
```
inside a `while read` pipe didn't split on whitespace as expected (zsh under macOS default settings). Multi-dupe groups failed on first pass; orchestrator re-ran explicitly.

**Fix**: switch to an array-based pattern, OR use `jq -r '.[1:][]'` to iterate one-per-line into `xargs -n 1`. The former is more idiomatic; the latter avoids shell-variable quoting footguns entirely.

*Trigger:* now. Pre-existing bug (not conversion-introduced) but fix it while the context is fresh.

### 16. Phase 4 tree-cleanliness sweep false-positives on `.claude/`

> DONE 2026-04-22: plans/post-plugin-improvements.md Project C — commit 10d200d

Phase 4.4.5 flagged `.claude/scheduled_tasks.lock` as dirty-tree validator pollution — false positive from ScheduleWakeup infra writing to the repo's `.claude/` dir during the run. Already noted as `phase_4_tree_dirty_false_positive` in `trace.md`.

**Fix**: exclude `.claude/` from the tree sweep (or use `git status --ignored=no` — hardest form), since nothing in `.claude/` is ever substantive to a code review.

*Trigger:* now. One-line fragment edit, stops the recurring false-positive noise.

### 17. Normalizer should expand multi-site findings natively

When Codex said "commands.ts:1492–1505 AND daily-sync.ts:323–337", the normalizer prompt was instructed to emit one candidate per site for clean dedup. That worked, but produced ~20 external candidates that Phase 2 dedup then folded. A native "expand multi-site findings into per-site candidates" pass (helper or prompt subtask) would be cleaner than relying on the normalizer to do it by instruction.

*Trigger:* if `--ensemble` mode starts producing consistent Phase 2 dedup bloat. Not urgent — the current shape works.

### 18. No warning when §0.13 finds a prior artifact but the old PR comment will stick around

> DONE 2026-04-22: plans/post-plugin-improvements.md Project B — commit f0d7f19

§0.14 (new-comment POST vs. existing-comment PATCH decision) skips when §0.13 found a prior artifact with `current_state=open`. That's per-spec, but the prior comment (e.g., from `rev_01KPSN4D94...`) stays on the PR alongside the new one. Users running `:review` repeatedly may silently accumulate review comments.

**Fix**: one-line user-facing note during §0.14: "Prior comment `<url>` will remain. Delete on GitHub if you want it gone." Purely informational.

*Trigger:* now. Tiny edit, prevents a "wait, why are there 4 adamsreview comments on this PR?" moment.

### 19. Codex progress goes to stderr; `.out` is empty until completion

> DONE 2026-04-22: plans/post-plugin-improvements.md Project B — commit f0d7f19

Mid-run diagnostic in the ensemble adapter — checking `.out` for Codex progress was misleading because Codex writes progress to stderr and stdout only fills on completion. One comment in `02-ensemble-adapter.md` next to the wait/poll loop would prevent the misread next time.

*Trigger:* now. One comment line.

---

## B. Orchestrator-side observations (from trace analysis)

### 20. JSON retry is one-shot, no repair, no model escalation

> DONE 2026-04-22: plans/post-plugin-improvements.md Project F — commit 95dc23d

Current pattern across every JSON-returning sub-agent site: parse → if fails, retry once with a "return only the schema" addendum → if still fails, safe-default / null+`uncertain` / drop / abort (site-dependent). No tolerant parser fallback, no model escalation on retry.

**Improvements (roughly ordered by payoff):**

- **`bin/parse-with-repair.py`** — wrap `json.loads` with a `jsonrepair`/`json5`/`demjson3` fallback for the common LLM slop (trailing commas, single quotes, unescaped newlines, stray markdown fences). Replace ad-hoc code-fence stripping across fragments with one helper. Would eliminate most "retry once then fail" paths because trailing-comma class failures become non-issues.
- **Model escalation on retry.** For high-value sites (Phase 4a/4b validators, Phase 9a post-fix review, ensemble normalizer), if Sonnet fails the retry, one final attempt at Opus before falling through. Near-zero marginal cost vs. an entire re-run.
- **Variable retry budget.** "One retry" is universal today; a 48-second Phase 4 validator is the same cost model as a 3-second Phase 0 classifier. Expensive-to-redo sites deserve two retries.
- **`response_format: {type: "json_schema", ...}` enforcement.** Long-term; needs Claude Code's Agent tool to expose the knob. Biggest lever we're not pulling, but may not be available today.

*Trigger:* when the L1-returned-empty pattern (now fixed by the Sonnet switch cherry-picked as commit 5748a6b) recurs on a different lens; OR when #11 / #12 accumulate enough real-run data to justify the helper.

### 21. `commands/review.md` missing `Bash(line-range-check.sh:*)` grant

> DONE 2026-04-22: plans/post-plugin-improvements.md Project C — commit 10d200d

`fragments/01-detection.md` invokes `line-range-check.sh` via bare name, but `review.md`'s `allowed-tools` doesn't include it. Pre-existing gap (not conversion-introduced — the pre-conversion review command had the same miss under its abs-path form). May cause a permission prompt during Phase 1 join.

**Fix**: one-line addition to `commands/review.md` frontmatter.

*Trigger:* if the permission prompt interrupts a review run.

### 22. `.gitattributes` doesn't cover `bin/include`

> DONE 2026-04-22: plans/post-plugin-improvements.md Project C — commit 10d200d

`bin/include` has no file extension, so the `*.sh` / `*.py` / `*.json` / `*.md` patterns in `.gitattributes` don't enforce LF on it. Currently LF on disk and LF in git, so no current risk. A future editor writing CRLF would produce a silent regression.

**Fix**: add `bin/include text eol=lf` to `.gitattributes`. Belt-and-suspenders; zero cost.

*Trigger:* now. One-liner.

### 23. Phase 0 `run_in_background` footgun

> DONE 2026-04-22: plans/post-plugin-improvements.md Project B — commit f0d7f19

During the earlier stuck-session incident (before the xhigh retry), the orchestrator backgrounded Phase 0's deterministic setup script, then couldn't read its output (harness turned `cat` into a new background task, blocked leading `sleep`, `Read` saw the file as effectively empty). Self-diagnosed, not conversion-specific.

**Fix**: the Phase 0 fragment could explicitly say "Run the setup script in the foreground — do NOT use `run_in_background`. You need its output inline to proceed through dirty-tree / branch-detect decisions." Prescriptive prompt edit prevents the failure mode.

*Trigger:* now. Cheap, prevents the session-trashing hang entirely.

### 24. Phase 3 demote rate may be miscalibrated

> DONE 2026-04-22: plans/post-plugin-improvements.md Project D.partial (#24 telemetry only) — commit ee81715
> Deferred 2026-04-22: awaiting ~10 reviews of data from Project D telemetry (threshold decision)

The first real review surfaced 37 findings past Phase 2 dedup; 24 landed `below_gate` (65%). Phase 3's "err-up" rubric is intentionally conservative, but a 65% demote rate means the gate is doing a lot of the work of Phase 4 prematurely. Data point of one — not conclusive.

**Fix**: track demote rate across the next ~10 reviews. If steady-state is 50–65% demoted and Phase 4 is comfortable-with-its-decisions on what it sees, rubric calibration is fine. If demote rate stays 65%+ AND Phase 4 rarely disproves what gets advanced, consider loosening Phase 3's cutoff (45 → 40) or weighting confidence higher.

*Trigger:* 10 reviews' worth of `advanced_to_phase_4` / `below_gate` metrics. Pair with the existing #1 data-collection ask from the architectural backlog.

### 25. Marketplace `metadata.description` warning

> DONE 2026-04-22: plans/post-plugin-improvements.md Project C — commit 10d200d

`claude plugin validate .` reports one warning: `metadata.description: No marketplace description provided`. Benign; the per-plugin description in `plugins[]` is populated.

**Fix** (optional): add a top-level `"description"` to `.claude-plugin/marketplace.json`. Silences the validator warning; no functional change.

*Trigger:* when the warning gets noisy enough to care, or when adding a second plugin to the marketplace makes the top-level description actually meaningful.

### 27. Walkthrough's spurious first-iteration continue/stop prompt

> DONE 2026-04-22: plans/post-plugin-improvements.md Project B — commit f0d7f19

After the user answers the first per-finding AskUserQuestion in `/adamsreview:walkthrough`, the orchestrator sometimes dispatches a spurious "continue or stop the walkthrough?" prompt before moving on. Not in the fragment spec — the per-finding AUQ at step 5.4 already includes "Stop the walkthrough" as a menu option, and step 5.6 ("Between iterations") is just meant to print a terse running-feedback line.

Root cause: emergent safety-hesitation from the orchestrator model. After the first state mutation (artifact patch), the model wants to confirm the flow is working before continuing through N more iterations. Once it has one successful iteration in context, it stops second-guessing. Matches the observed pattern of "always seems irrelevant" and "happens only once."

**Fix**: one-line prescriptive anti-instruction at the top of the per-finding loop section in `commands/walkthrough.md` (around step 5.3):

> **Do not dispatch any confirmation AskUserQuestion between iterations.** The reviewer opted into the walkthrough flow by invoking the command and answering the preflight scope question; the per-finding AskUserQuestion already includes "Stop the walkthrough" as an exit. Any additional "continue or stop?" prompt between iterations is a prompt-engineering bug — skip it.

LLMs respect this class of explicit anti-instruction reliably.

*Trigger:* now. 5-minute fragment edit; removes a consistent paper cut. Low-effort, noticeable UX win.

---

## Priority ordering (all items)

Post-2026-04-23 close-out state (see plans/post-plugin-improvements.md §6 and plans/stage-4-fragment-shrink-execution.md §4 for session details):

- **Done 2026-04-22 (post-plugin-improvements session):** #0, #1A (rename), #9, #10, #11, #12, #13, #15, #16, #18, #19, #20, #21, #22, #23, #24 (telemetry only — decision deferred), #25, #27
- **Done 2026-04-23 (stage-4-fragment-shrink session):** #2, #14 (see `plans/stage-4-fragment-shrink.md` Appendix B for measurements)
- **Data-driven decision awaiting ~10 reviews of Project D telemetry:** #1B, #1C, #24 (threshold-calibration decision portion)
- **Probably leave alone** (per-item triggers say "probably never"): #3, #4, #5, #6, #7, #8, #17, #1D, #1E (item #26 was never authored — numbering jumps from #25 to #27)
- **Follow-up surfaced during Project C** (not in scope, worth a future one-liner): `assign-finding-ids.sh` and `origin-crosscheck.sh` are invoked bare in transcluded fragments but missing from `commands/review.md` `allowed-tools` — same class of pre-existing gap as #21. Bundle with any future frontmatter touch. *(Tracked in `plans/backlog.md` §3 as FU-1.)*
