# Plan: Comments-and-words cleanup

**Status:** draft 2026-04-27. Branch `comments-and-words`. Sourced from a 5-agent audit covering all 20 LLM-facing prompts (`commands/*.md` + `fragments/*.md`, 9,284 lines total).

---

## Why

Every byte in `commands/*.md` and `fragments/*.md` is sent to Claude at runtime — these files are not documentation, they are runtime prompts. An audit identified that ~10–15% of content in the heavier files is recoverable without changing what the LLM does:

- **Archive cross-references** (`per DESIGN §X.Y`, `see plans/foo.md`, `§13.10`) — pervasive across all 20 files. The LLM cannot resolve them at runtime; they exist for maintainers using `grep` against the frozen archive.
- **Internal task-tag rationale** (T1 / T1.trap / T8 / T9 / R2 / "Discussion item 2 resolution") — surviving plan-tracking tags from prior development stages, concentrated in `01-detection.md` lines 999–1206.
- **Historical narrative** ("Pre-Stage-2.8...", "Previously a blanket no-op...", "Originally we did X, switched to Y after PR #14") — change-log content embedded in the prompt.
- **Maintainer "keep in sync" warnings** — pure future-self protection, invisible value at runtime.
- **Recap trailers** — `### Working-set delta after Phase N` sections at end of every fragment, restating state the next phase reads from the artifact anyway.
- **Top-of-file preamble paragraphs** — re-stating what the section headers below already announce.
- **Helper-internals tutorials** — multi-paragraph shell-scripting walkthroughs (e.g., `walkthrough.md:1014-1032`'s pipefail/awk/exit-status explainer).

Stage 4 (closed 2026-04-23) attacked **structural** bloat — helper extraction, manifest-style command bodies, lazy-load lens references. **This plan attacks textual bloat** that survived Stage 4: programmer-facing comments and rationale that the LLM cannot use.

## Constraint (binding)

User-stated: *"very careful not to remove meaningful words but only target the relevant things."*

Operationalized:

1. **Remove ONLY content matching enumerated patterns.** Each stage spec lists exact patterns. Sub-agents may not extend the patterns or apply judgment beyond the spec.
2. **Preserve ALL operative content.** Operative = the LLM acts on it: schema specs, JSON examples, sub-agent prompts, gate-arithmetic bash, jq filters, "because Y" rationale that steers judgment, user-facing chat-rendered text.
3. **When in doubt, leave it.** Sub-agents must err toward conservation. A false-positive removal (cut something load-bearing) is worse than a false-negative (left something cuttable for follow-up).
4. **Verify per stage.** Each stage's verify includes (a) `test/smoke.sh` PASS, (b) diff-against-spec (every removal matches a pre-listed pattern), and (c) spot-read of the affected file's logical flow.

## Scope

In scope:

- HIGH-confidence removals from the audit (clearly programmer-facing, no LLM purpose).
- Categorically-mechanical MEDIUM removals where the spec is regex-tight (e.g., the `### Working-set delta after Phase N` trailers).

Out of scope (deferred):

- MEDIUM-confidence verbosity items where compression requires per-paragraph judgment (e.g., "this rationale paragraph could be tighter"). Listed in Appendix C for future plans.
- Lens prompt blockquotes inside `01-detection.md` (audit confirmed clean).
- The Opus deep-validator prompt body (`05-validation.md` §4.2 main blockquote — audit confirmed lean).
- The post-fix reviewer prompt body (`10-post-fix-and-commit.md` §9a main blockquote — audit confirmed lean).
- The fix-group editor agent prompt body (`09-fix-execution.md` §8.5 main blockquote — audit confirmed lean).
- User-facing chat-rendered text (e.g., walkthrough's "Understanding the scope" preamble, Phase 6 "Next steps" block).
- CLAUDE.md (not LLM-facing at runtime — separate concern).

## Patterns to TARGET (7)

### Pattern A: Archive cross-references

**Regex (case-sensitive):** `(?:per |see |from )?(?:DESIGN |archive |frozen )?§\s*\d+(\.\d+)*`, plus prose forms `see DESIGN §X`, `(DESIGN §X)`, `(see plans/<name>.md)`, `(per §X.Y)`.

**Examples to remove:**
- `commands/review.md:8` — *"Run an end-to-end code review per DESIGN §4 Phases 0–6."* → *"Run an end-to-end code review across Phases 0–6."* (citation removed; phase scope kept because it's structural)
- `commands/promote.md:11` — *"See DESIGN §27 for the contract and §5.2.1 for how the Phase 8 eligibility bypass works."* → delete the entire sentence.
- `fragments/_prelude-shared.md:15` — *"On parse failure, log with tokens value `null` (i.e. `--tokens null`) per DESIGN §11."* → strip *"per DESIGN §11"* trailing clause; keep the operative directive.
- `fragments/00-preflight.md:105` — *"Delegate to the canonical helper (DESIGN §9.2 — single source of truth shared with Phase 7's fix-loader so the two paths cannot drift)"* → *"Delegate to the canonical helper:"* (drop parenthetical).

**Preserve when:** the citation is followed by content the citation is *not* introducing (e.g., a trailing sentence is fine if it stands on its own after the citation is stripped). When the surrounding instruction relies on context the citation would have provided, leave the surrounding text — but the citation phrase itself can still go (the LLM can't read the archive regardless).

### Pattern B: Internal task-tag rationale

**Tags:** `T1`, `T1.trap`, `T8`, `T9`, `R2`, `Discussion item N`, `(R-...)`.

**Scope (default — applies unless an example below overrides):** remove ONLY the tag prefix (e.g., `T8 — `, `T1 — `, `(R2) `, `(Discussion item 2 resolution): `) and retain the comment body verbatim. The surrounding-paragraph removal applies ONLY when the paragraph contains an explicit historical phrase: *"previously"*, *"earlier draft"*, *"original design"*, *"pre-Stage-X.Y"*, or a dated reference. Operative comments (those documenting current contracts, invariants, or failure modes) are preserved even when tagged. Per-example overrides below specify which sites get the full-paragraph treatment.

**Examples (all in `fragments/01-detection.md`):**
- L999–1012 — *"Execution note (T9). Steps 3 and 4 in this section MUST run inside a single `Bash(...)` invocation. The shell variables (`$ided`, `$build_result`, `$findings_array`) are large..."* → keep the imperative *"Run steps 3 and 4 in a single Bash invocation."*; drop the multi-paragraph reasoning.
- L1027 — `# T8 — type-guard against non-string $raw. map_family() returns None for non-strings...` → **tag-prefix-only:** drop *"T8 — "* and retain the comment body verbatim.
- L1099 — `# Phase-1 sanity check (Discussion item 2 resolution): the jq builder...` → **tag-prefix-only:** drop *"(Discussion item 2 resolution): "* and retain the comment body verbatim.
- L1129–1142 — *"T1 — synchronous stderr capture instead of process substitution. Earlier draft used `2> >(tee -a "$trace_log_path" >&2)` (background subshell, async). That was safe for Phase 1.6's later grep..."* → full-paragraph deletion (qualifies — *"Earlier draft used..."*); the code stands on its own.
- L1167 — `# Distinct loud-failure surface (R2) for the catastrophic case` → drop the `(R2)` tag; keep the comment if it explains the decision (or trim if it duplicates obvious code).

**Preserve when:** the tag annotates a comment that is itself operative. If a comment says *"# Use awk's exit status, not the pipeline's, because pipefail is off here"* — that's operative and stays. If it says *"# T1 — see decision log"* — that's pure tag and goes.

### Pattern C: Historical narrative

**Phrase markers:** *"Previously..."*, *"Originally..."*, *"Pre-Stage-X.Y..."*, *"prior draft used..."*, *"this was added in PR #..."*, *"changed on YYYY-MM-DD..."*, *"... after Stage N..."*, *"the historical bug where..."*.

**Examples:**
- `fragments/00-preflight.md:169–173` — *"Pre-Stage-2.8 this timestamp also anchored..."* → delete entirely. **Note:** L168 (*"This is the review's start time — consumed by Phase 6 metrics..."*) is operative and PRESERVED.
- `fragments/promote-core.md:89–107` — 19-line *"Note on the `confirmed_mechanical` + `curr_hc == null` row. Previously a blanket no-op... That was correct only when..."* → delete the entire note; the table row already states *"always proceed."*
- `fragments/04-scoring-gate.md:62–69` — *"Why chunked, not per-finding. Per-finding fan-out (one Sonnet per candidate) was the original design but was empirically too expensive..."* → delete entirely.
- `commands/walkthrough.md:115–127` — *"Reading them once at the top of the run avoids the historical bug where §6.5 ran before §6.2's extraction..."* → keep the bash; drop the *"avoids the historical bug"* prose.

**Preserve when:** a "previously" reference is followed by *"so we now do X to avoid Y"* and the *Y* is a current behavioral invariant the LLM must respect. In that case, compress to *"Avoid Y by doing X."*

**Additional preserve rule (current-state failure modes, regardless of historical framing):** do NOT whole-block-delete any passage containing the words *"because"*, *"so"*, *"without"*, *"cannot detect"*, *"guard"*, *"trade-off"*, or *"invariant"* unless an explicit replacement is provided in the stage spec. Such passages document *current* failure modes that survived as judgment-shaping rationale; treating them as historical narrative based on a *"Previously..."* framing alone is insufficient. When in doubt, write the exact replacement text in the stage spec rather than ask the sub-agent to compress.

### Pattern D: "Keep in sync" maintainer warnings

**Phrase markers:** *"Keep in sync with..."*, *"mirrors X — must match"*, *"Edit alongside Y"*, *"the inverse of...; keep aligned"*, *"both readers exist by design"*.

**Examples:**
- `fragments/09-fix-execution.md:17–23` — *"The `/adamsreview:walkthrough` scope filter (§28, step 3 in `commands/walkthrough.md`) is the **inverse** of this selector... Keep the inverse piece in sync — any edit to the eligibility logic below must mirror into the walkthrough's scope jq."* → delete the keep-in-sync block (L17-23 only). PRESERVE L13-15 (operative human_confirmation bypass invariant — current-state documentation tied to the Phase 8 fix-gate).
- `commands/walkthrough.md:148–149` — *"**Keep the Phase-8-inverse shape in sync with `09-fix-execution.md`...**"* → **PRESERVE** as the canonical sync marker between walkthrough's scope jq and `09-fix-execution.md`'s eligibility jq (cross-LLM-orchestrated invariant — see Pattern D's "Preserve when" rule above and Stage 2.5's spec). The mirrors at `08-fix-loader.md` and `09-fix-execution.md` are still removed in Stage 3.4.

**Preserve when:** the warning protects an invariant between two LLM-orchestrated components that will be edited by future LLM-driven changes (e.g., parallel jq selectors in different fragments where one is the inverse of the other). In that case, preserve a single canonical reminder at the lower-volume site; remove the mirrors at higher-volume sites.

### Pattern E: Working-set delta / NOT-do trailers

**Targets (verified by grep):**

| File | Line | Heading |
|---|---|---|
| `fragments/01-detection.md` | 1266 | `### Working-set delta after Phase 1` |
| `fragments/02-ensemble-adapter.md` | 398 | `### Working-set delta after Phase 1.5` |
| `fragments/03-dedup.md` | 273 | `### Working-set delta after Phase 2` |
| `fragments/04-scoring-gate.md` | 275 | `### Working-set delta after Phase 3` |
| `fragments/05-validation.md` | 669 | `### Working-set delta after Phase 4` |
| `fragments/06-cross-cutting.md` | 159 | `### Working-set delta after Phase 5` |
| `fragments/07-finalize.md` | 361 | `### Working-set delta after Phase 6` |
| `fragments/08-fix-loader.md` | 249 | `### Working-set delta after Phase 7` |
| `fragments/09-fix-execution.md` | 354 | `### Working-set delta after Phase 8` |
| `fragments/10-post-fix-and-commit.md` | 1229 | `### Working-set delta after Phase 9` |

**Removal:** delete the heading and everything from the heading until the next `^## ` or `^### ` heading or end-of-file (whichever comes first).

**Plus** the parallel `## What this command does NOT do` sections at end of:
- `commands/review.md:168–176`
- `commands/fix.md:171–189`
- `commands/promote.md:250–263` — **but read carefully**: this section contains a `for id in F003 F037 F039` shell loop that's operational reference; if removing the section would lose user-actionable info, leave it. Audit Agent 2 noted this is partially operative.
- `commands/walkthrough.md:1298–1313`
- `commands/add.md:980–994`

**Decision rule for `## What this command does NOT do` sections:** delete a NOT-do section ONLY when EVERY bullet is a *"No X."* / *"Does NOT do X."* contrast against another adamsreview command. If any bullet describes:
- state behavior (e.g., resumption contracts)
- error semantics
- code recipes a user might paste
- operative state-machine claims

THEN preserve those bullets and delete only the pure-contrast ones around them.

**The walkthrough Phase 5 user-facing text is preserved verbatim per the constraint.**

### Pattern F: Top-of-file preamble paragraphs

**Pattern:** the first paragraph(s) after the frontmatter block (or first heading) that re-state what the file does, restating section headers below.

**Examples:**
- `commands/walkthrough.md:8–21` — opening 14-line description; the frontmatter `description:` already covers it. Keep the frontmatter; trim the prose to one orienting sentence.
- `commands/add.md:7–23` + `54–78` ("Execution overview — read this first" — re-lists §1–§10 verbatim) + `82–97` ("Sub-agent dispatch pattern" — previews §4/§5/§7). Delete the overview and dispatch-pattern previews; the section bodies already cover both.
- `commands/review.md:8–11`, `26–29`, `38–41`, `55–58`, `65–77`, `83–94`, `96–114` — preamble paragraphs and the §25.1 working-set-variables enumeration. Trim per stage spec below.
- `commands/fix.md:8–17`, `33–36`, `60–63`, `98–106`, `108–114`, `116–140`, `181–185` — same pattern. Trim per stage spec.
- `commands/promote.md:8–12`, `47–62`, `138–149`, `262–263` — trim per stage spec.
- `fragments/00-preflight.md:3–7` — preamble describing what the fragment does.
- `fragments/08-fix-loader.md:1–11`, `09-fix-execution.md:1–8`, `10-post-fix-and-commit.md:1–7` — fragment preambles.

**Preserve:** any sentence that names model/tool-call counts, side effects, skip sets (e.g., *"skipped in trivial mode"*), threshold semantics, cross-fragment execution rules, scope claims (what the command/fragment does NOT touch), or dispatch counts. Concrete examples that MUST be preserved:
- `00-preflight.md` L3-7: *"This phase is mostly deterministic shell — the only LLM call is the Sonnet user-facing-change classifier (step 0.9), and that's skipped in trivial mode."*
- `walkthrough.md` L8-18: defines walkthrough scope, threshold semantics, promote-core semantics, end-of-run side effects.

**Test:** if deleting the sentence would cause the LLM to make a worse decision somewhere downstream, preserve it.

### Pattern G: Helper-internals tutorials

**Pattern:** multi-paragraph explanations of how a helper script or shell idiom works, embedded in a runtime prompt.

**Examples:**
- `commands/walkthrough.md:1014–1032` — multi-paragraph tutorial on `gh` exit codes, awk pipeline behavior, `mktemp` vs `/tmp/...$$`. **Worst single concentration.** Delete entire tutorial; keep the bash.
- `commands/walkthrough.md:1167–1172` — `gh api` `{owner}/{repo}` substitution explanation.
- `fragments/00-preflight.md:113–115` — *"The helper runs `git remote get-url origin`, strips scheme + `git@` + trailing `.git`, normalizes separators, and lowercases. No remote → falls back to `local-<sanitized-path>`. See `bin/repo-slug.sh` for the exact algorithm and test matrix."* → delete (the helper invocation is what matters).
- `fragments/01-detection.md:1234–1241` — `grep -c` idiom tutorial (`|| true` vs `|| echo 0`).

**Preserve:** when the prose IS the instruction (e.g., *"Pipe through `parse-with-repair.py` because external-tool output is the messiest boundary"* — the *because* steers the LLM to use the pipe consistently). Distinguish from helper-internals tutorial by asking: does the LLM need this to choose its action, or does it just describe how the script the LLM is calling works internally?

## Patterns to PRESERVE (binding — sub-agents must not touch these)

1. **"Because Y" rationale that shapes judgment.** *"Be conservative — prefer splitting when unsure. False merging hides findings; false splitting only produces two near-identical entries"* — earns its tokens.
2. **Schema specs, JSON examples, structured output requirements.** The LLM needs them to produce conformant output.
3. **Section / Phase / Step headers.** LLMs use them to orient inside long prompts.
4. **Operative instructions, even when long.** *"When score < 45 AND single source family → set disposition to below_gate"*.
5. **Sub-agent prompt blockquotes** (the dispatched payload). Lens prompts in `01-detection.md` (L312–731 across L1–L7), the deep validator prompt in `05-validation.md` §4.2, the fix-group editor prompt in `09-fix-execution.md` §8.5, the post-fix reviewer prompt in `10-post-fix-and-commit.md` §9a, the reconcile-merge prompt in `10-post-fix-and-commit.md` §9.pre.reconcile.
6. **User-facing chat-rendered text.** Walkthrough Phase 5 briefer text, Phase 6 *"Next steps"* block in `07-finalize.md:296+`, the dirty-tree warning text in `00-preflight.md`, error-as-prompt messages.
7. **Bash blocks.** Even if a bash block looks heavy, the orchestrator IS an LLM and reads the bash. Do not "compress" bash. Comments inside bash are LLM-visible — strip per Pattern B/G when they match, but do not rewrite the bash itself.
8. **Comments that are factually wrong-as-written.** If a sub-agent identifies a comment that contradicts the code it sits next to (the code does X; the comment claims Y), flag the discrepancy for orchestrator review rather than removing or keeping. The right action is correction, which is out of scope for this cleanup.

## Stages

### Phase 0 — Pre-execution safety sweep + fixture build (must complete before Phase 1)

#### Stage 0.1: Fenced-block annotation sweep

Before any cleanup work begins, run:

```bash
grep -nE '^```' commands/*.md fragments/*.md
```

Build an annotated list of every fenced-block boundary `(file, open_line, close_line, kind)` where `kind ∈ {bash, prompt-body, json, plain, markdown}`. Identify every sub-agent prompt blockquote (those whose body opens with phrases like *"You are a..."*, *"Return JSON..."*, or whose surrounding fragment context labels them as dispatched payload).

Cross-check every Phase 2 / Phase 3 stage's cited line range against this list. Any range falling between an open-line and close-line of a sub-agent prompt blockquote is **REJECTED for that stage** — surface the conflict and the affected stage's spec must be revised before execution.

This sweep is structural insurance against the most-impactful failure mode (editing dispatched prompt-body content). Costs ~30 seconds; would have caught Fix 1's CRITICAL issue preventively.

**Verify:** the annotated list shows every fenced block; every Phase 2/3 stage's cited ranges have been cross-checked and fall outside sub-agent prompt blockquotes.

#### Stage 0.2: Behavioral fixture build (out of scope but blocking)

Stage 4.1's behavioral fixture diff (Fix 2) requires a pinned target + expected `artifact.json` snapshot under `test/fixtures/`. Building that fixture is OUT OF SCOPE for this cleanup plan, but it is BLOCKING for Stage 4.1's verify gate. If the fixture does not yet exist, either:
- (a) build it as a separate task before kicking off `/orchestrate`, or
- (b) execute Phases 1-3 with Stage 4.1's behavioral test downgraded to "best-effort hand verification of artifact shape on a real PR" — accepting the structural verify-gate gap.

The user should be asked to choose (a) or (b) before Phase 1 begins.

### Phase 1 — Mechanical sweeps (sequential, lock the tree)

These touch many files and must complete before per-file targeted work to avoid merge conflicts.

#### Stage 1.1: Archive cross-reference sweep

**Spec:** Apply Pattern A removals across all of `commands/*.md` and `fragments/*.md`.

**Method:** sub-agent reads each file in turn, identifies citation phrases per Pattern A's regex/prose forms, and removes the citation while preserving the surrounding instruction. For each removal, the sub-agent records (file, line, before, after) in the build journal.

**Hard constraints:**
- Do NOT delete entire sentences unless the entire sentence is the citation (e.g., *"See DESIGN §27 for the contract and §5.2.1 for how the Phase 8 eligibility bypass works."* — entire sentence is just citation, delete it).
- Do NOT touch sub-agent prompt blockquotes (preserve list #5).
- Do NOT touch references inside bash strings (e.g., a heredoc that emits text to a user, where the citation is part of the user-visible output — though I don't believe these exist in this codebase).

**Verify:**
1. `test/smoke.sh` → PASS.
2. `git diff --stat` → only `commands/*.md` and `fragments/*.md` modified.
3. `grep -nE 'DESIGN §|see plans/|per §[0-9]' commands/*.md fragments/*.md` → near-zero hits (a few may survive in user-visible text or sub-agent prompts).
4. Spot-read 3 modified files end-to-end: each operative directive that previously trailed a citation should now stand on its own.

**Estimated: ~30+ removals across ~15 files.**

#### Stage 1.2: Working-set delta + NOT-do trailer sweep

**Spec:** Apply Pattern E removals.

**Method:** for each file in Pattern E's table, delete the named heading and its content up to the next heading boundary. For the `## What this command does NOT do` sections in commands, apply the decision rule (delete pure-prose sections, preserve sections containing user-actionable code recipes; trim around the recipes).

**Hard constraints:**
- The `for id in F003 F037 F039` recipe in `commands/promote.md:250+` must survive.
- Walkthrough Phase 5 user-facing briefer prose is preserved (separate concern, not a NOT-do trailer).
- Do NOT delete sections that contain operative directives.

**Verify:**
1. `test/smoke.sh` → PASS.
2. `grep -nE '^### Working-set delta' fragments/*.md` → zero hits.
3. `wc -l` per-file shrink summary in build journal.
4. Spot-read each modified file's tail to confirm it ends cleanly (no orphan heading, no dangling reference).

**Estimated: ~10 trailer deletions + 5 NOT-do section trims.**

### Phase 2 — High-leverage targeted edits (parallel-safe — different files)

Stages 2.1 through 2.6 each touch a single file with a discrete cluster of HIGH-confidence findings. They can run in parallel because they touch disjoint files.

#### Stage 2.1: `fragments/_prelude-shared.md`

**Why first within Phase 2:** highest multiplier — loaded by every command on every invocation.

**Spec:**
- Apply Pattern A removals: lines 14–15 (`per DESIGN §11`), 17–19 (`DESIGN §24.4 invariant`), 27 (`DESIGN §8.6's error-as-prompt convention`).
- Apply Pattern F removal: lines 1–7 (preamble paragraph). **Caveat:** the line *"these rules apply across every phase of every adamsreview command that dispatches sub-agents or invokes helper scripts"* may be load-bearing as a scope statement. If keeping, trim to that single sentence.

**Verify:** smoke + the file should still read as a coherent set of cross-phase rules.

#### Stage 2.2: `fragments/promote-core.md`

**Spec:**
- Apply Pattern F removal: lines 1–8 (preamble + DESIGN §27 cross-ref).
- Apply Pattern C removal at L89-107 — **Surgical, not whole-block:** DELETE only L89-91 (the *"**Note on...**"* heading + *"Previously a blanket no-op..."* historical framing) and L101-107 (the *"harmlessly redundant"* trailing aside about deep-lane above-threshold findings). PRESERVE L92-99 (the two current-bypass example bullets — light-lane impact filter case and deep-lane below-threshold case — these document why the table row says *"always proceed"* and are not deletable history).
- Apply Pattern B removal: lines 224–227 (*"Step numbering (3, 4, 4.5, 5, 6, 9) matches the original /adamsreview:promote step numbers for continuity..."* — pure numbering meta-commentary).

**Verify:** smoke + the contract tables (lines 11–39) and step bodies must still flow without the deleted preamble.

#### Stage 2.3: `fragments/01-detection.md` — Phase 1 join step rationale (L999–L1206)

**Why this is its own stage:** densest concentration of task-tag rationale in the codebase, contained in one ~200-line region. Touching this in isolation lets the verify focus on the join step's correctness.

**Spec:**
- Apply Pattern B removals: L999–1012 (T9 execution note), L1027 (T8 jq comment), L1099 (Discussion item 2), L1129–1142 (T1, T1.trap historical), L1167 ((R2) tag — keep comment if it explains decision), L1197 (T1 reference in another comment).
- Apply Pattern G removal: L1234–1241 (`grep -c` idiom tutorial).
- Apply Pattern A removals: L1190–1206 (forward-references to other fragments using `§13.12`, `commands/add.md` cite, etc.) — the operative rules stand; cross-refs go.
- Apply Pattern A removal: L1261–1264 (joint-dispatch overlap rationale referencing §13.12).

**Hard constraint:** the actual jq builder code, the bash logic, and any `# operative comment that steers a decision` stay. Drop tags and trailing rationale; keep working code.

**Verify:** smoke + a Bash dry-run of the join-step jq builder against a tiny synthetic input (the smoke harness should already exercise this; if it doesn't, add an assertion).

#### Stage 2.4: `fragments/10-post-fix-and-commit.md`

**Why:** third-largest file, hosts the most-expensive Opus pass in `/adamsreview:fix`. Multi-site cleanup.

**Spec:** apply Pattern A + B + C + F removals at the following sites identified by Audit Agent 5:
- L1–7 — preamble + `§24.4` cross-ref → trim per Pattern F + A.
- L31 — *"Belt-and-suspenders for §19.8's prompt-only delete/rename prohibition"* → drop the cross-ref framing (Pattern A).
- L50–51 — justification aside (*"snapshot for audit (commit message + trace want it..."*)* → trim to *"Snapshot for commit message + trace:"*.
- L73–74 — *"matches prior behavior"* change-log noise (Pattern C).
- L278 — DELETE only the *"Why `git status --porcelain` not agent self-reports:"* header line. PRESERVE L279-289 (the four enumerated correctness bullets: *catches everything actually changed*, *catches rogue reconcile-agent edits*, *robust against agent-report disagreement*, *git diff can't substitute*) — these document failure modes the chosen approach prevents and pre-empt the obvious-but-wrong alternative (*"why not just `git diff`?"*) that a future LLM editor would propose.
- L351–352 — implementation rationale comment (Pattern G-adjacent — explains why FG-RECON is used).
- L818, L829–833 — *"per §13.6"* cross-ref + cross-section explanation → trim per Pattern A + drop the cross-section explanation.
- L861–863, L1130–1132 — implementation-rationale comments about FG-RECON id substitution → drop the comment; keep the code.
- L902–907 — Apply this exact replacement:
  *"On non-zero: log stderr verbatim to `trace.md`; do NOT retry — first-failure-halt means tuples 0..N-1 are already persisted, and the commit already happened; re-running would trip state-transition validation. Surface as the primary user error at end of 9e. Next run's leftover-attempted check catches the rest."*
  The "first-failure-halt" framing is the WHY behind "do NOT retry" — judgment-shaping rationale that earns its tokens.
- L1100–1105 — re-states what the body shows (Pattern F-adjacent).
- L1244–1247 — terminal invariant cross-ref (Pattern A).

**Hard constraints:**
- The `9.pre.reconcile` prompt blockquote (~L111–221) is preserved untouched (preserve list #5).
- The `9a` post-fix reviewer prompt blockquote (~L533–639) is preserved untouched.
- The 35d–35e branching logic + commit/revert bash is preserved untouched.
- L835–838 (the *"Capture `commit_sha` IMMEDIATELY"* rule) is operative and stays — the all-caps emphasis is OK.

**Verify:** smoke + spot-read §9.pre, §9a, §9d (commit-and-tag-survivors), §9c (revert) end-to-end. The file should still cleanly trace the post-fix state machine.

#### Stage 2.5: `commands/walkthrough.md`

**Spec:**
- Apply Pattern A removals: L20–21 (`see DESIGN §28...`), other inline `§N.N` cites at L459 (parenthetical only — *"Prompt (see DESIGN §28.4):"* → *"Prompt:"*), L535 (`per §11 / §24.4`), L901 (`per §3`), L965 (`per §5.2 convention`), L1093 (`DESIGN §27.6`).
- Apply Pattern C removals: L115–127 (*"Reading them once at the top of the run avoids the historical bug..."* — keep bash, drop prose), L283–286 (preventive-docs fix historical reference).
- Apply Pattern B-adjacent removal: L411–413 (meta-commentary about variable-capture position), L626–630 (implementation gripe about `${edited_hint:+...}`).
- Apply Pattern D removal: L880–887 (defensive maintainer rationale — keep operative *"re-extract per iteration"*; drop the *"if §6.5 runs after the §5 walk loop, $f_file otherwise carries..."* explanation).
- L148–149 — **PRESERVE** as the single canonical sync marker between walkthrough's scope jq and `09-fix-execution.md`'s eligibility jq (provably-inverse predicates). Future LLM-driven edits to either jq need this marker to know they must mirror. Mirrors at `08-fix-loader.md` L18-23 and `09-fix-execution.md` L13-23 are still removed in Stage 3.4 (walkthrough is canonical because it's the lower-volume invocation).
- Apply Pattern G removals:
  - L1013-1032 — **Surgical, not whole-block:**
    - PRESERVE L1017-1024 (the actual `gh issue create` bash invocation).
    - REPLACE the four-line bash comments at L1013-1016 with one operative comment: `# Capture gh_rc directly; piping gh through awk would swallow gh's exit (pipefail is off here).`
    - DELETE the standalone prose paragraph at L1026-1032 (post-bash tutorial about awk URL extraction, `tail` vs `awk`, `mktemp` vs PID-based tempfiles).
  - L1167–1172 (`gh api` owner/repo substitution explanation).
- Apply Pattern F removals:
  - L8-21 — **Surgical, not whole-block:** PRESERVE sentences that define walkthrough scope, threshold semantics, promote-core semantics with `--defer-publish`, and end-of-run side effects (per Pattern F's preserve list). DELETE only any duplicate-of-frontmatter sentences.
  - L1054–1062 (durable-side-effects note), L1314–1325 (Appendix — restates what step 5.5 already says).
- L1298-1313 — **Surgical:** PRESERVE the resumption-state bullet (*"No resumption state file. If you quit mid-walkthrough, the promotions you already made stand. Re-invoking the walkthrough skips them naturally..."*) — operative state-machine claim. DELETE only the three pure-contrast bullets (no fix-run, no disproven handling, no cross-branch).

**Hard constraints:**
- L283–314 *"Understanding the scope"* user-facing chat block is **preserved verbatim** (it renders to the reviewer running the walkthrough — UX text per preserve list #6).
- L38–58 *"What it does"* numbered list — if it duplicates §3–§9 headings, it can be trimmed (it's effectively a TOC for fragment readers); confirm it doesn't render to chat before deleting.
- The Phase 5 briefer prompt + Phase 6.5 issue-filer prompts are preserved untouched.

**Verify:** smoke + a careful read of §5 (per-finding walk loop), §6.5 (issue filer), and the appendix-removal site to confirm no orphan reference. **This stage has the highest read-cost in the verify; budget for it.**

#### Stage 2.6: `fragments/05-validation.md`

**Spec:**
- Apply Pattern C removals at the multi-paragraph rationale clusters:
  - L46-57 — Apply this exact replacement text in place of the existing 12-line block:
    *"**Never batch deep-lane candidates into one Opus call.** Each candidate needs independent blast-radius and fix-proposal work. The `--apply-decisions --expected $N` guard catches under-count violations but cannot catch the collapse-then-correct-unwrap failure mode (batching N candidates into one Opus call, then unwrapping the response into N tuples to satisfy the guard). The discipline is yours."*
    The unwrap-warning is judgment-shaping rationale per the preserve list and must survive in some form.
  - L206–215 (*"Why chunked, unlike the deep lane"*).
  - L283–288 (`Stage 2.5.B clarification` historical).
  - L326–336 (*"have been observed"* prose → keep operative *"Pipe through `parse-validator-result.py`"*; drop the rationale).
  - L496-502 — Apply this exact replacement: *"**Invariant:** Phase 0's dirty-tree gate clears the tree before Phase 1, and Phases 1–5 are tree-read-only. Any uncommitted change discovered post-validation is therefore validator-sourced and safely revertable; the trace tag `phase_4_tree_dirty_reverted:` surfaces the incident for post-mortem."*
  - L559-578 — Apply this exact replacement: *"**Drop-recovery for missing scores.** If a chunk-agent drops a finding from its returned array, the missing finding's `score_phase3` would normally default to null. In Wave 2 this is a silent confirmation loss: every Wave 2 candidate is structurally seeded with a single source family, so a null-scored Wave 2 candidate cannot auto-graduate, and the hard 2-wave cap means it will never be retried. Mitigation: when the returned chunk count is shy of the dispatched count, re-dispatch the scoring chunk for any missing ids before applying decisions. The `--apply-decisions --expected $N` guard alone cannot catch this — it sees the chunked-batch step, not the per-id-presence step."*
- Apply Pattern B removal: L64–66 (*"noted here for symmetry"*).
- Apply Pattern G removal: L304–312 (validator-helper internals).
- Apply Pattern A removals: L399–414 (cross-file line citation to `commands/add.md §7.6 lines 551–556` — drop the line ref; keep the awk caveat), L418–422 (mirror reference to add.md guard).

**Hard constraints:**
- The deep-validator prompt blockquote (§4.2 — typically begins with *"You are a deep validator..."*) is preserved untouched.
- The light-lane prompt blockquote (§4.3) is preserved untouched.
- Schema enumerations + JSON examples (L171–197 area) are preserved (preserve list #2).

**Verify:** smoke + spot-read §4.1 (dispatch routing), §4.2 (deep prompt — confirm untouched), §4.3 (light prompt — confirm untouched), §4.4 (decision application), §4.5 (Wave 2).

### Phase 3 — Medium-leverage targeted edits (parallel-safe)

Stages 3.1–3.4 are smaller per-file cleanups. Each targets HIGH-confidence findings that didn't earn a dedicated Phase 2 stage.

#### Stage 3.1: Top-level commands — `commands/{review,fix,promote}.md`

**Why grouped:** all three are smaller files (176 / 189 / 266 lines) with similar bloat patterns (frontmatter-restating preamble, working-set-variables enumeration, "What this command does NOT do" trailer).

**Spec — `review.md`:**
- L8–11, L26–29, L38–41, L55–58, L65–77, L83–94 — apply Pattern A + F (frontmatter-restating preamble, DESIGN cross-refs, effort paragraph).
- L96–114 — Pattern F (*"Working-set variables (§25.1 summary)"* enumeration; Phase 0 establishes these anyway).
- L168–176 — Pattern E (*"What this command does NOT do"*).

**Spec — `fix.md`:**
- L8–17, L33–36, L60–63 — Pattern A + F.
- L98–106 — Pattern F (*"Fix-group agent tool grants"* meta-commentary about constraints enforced elsewhere).
- L108–114 — Pattern F (effort paragraph).
- L116–140 — Pattern F (Working-set variables).
- L181–185 — Pattern B (TODO/futures: *"a future `--resume-interrupted` flag could automate..."*).
- L171–189 — Pattern E.

**Spec — `promote.md`:**
- L8–12 — Pattern A (DESIGN §27, §5.2.1 cross-ref).
- L47–62 — Pattern F (*"What it does"* 1–8 list — restates Execution steps below).
- L138–149 — Pattern F (*"Steps 3 (...), 4 (...), 4.5 (...), 5 (...)"* enumeration; replace with *"Read `fragments/promote-core.md` and execute steps 3, 4, 4.5, 5, 6, 9 inline."*).
- L262–263 — Pattern B (*"(Future work: `overrides.json` sidecar...)"*).
- L250–263 — Pattern E with the recipe-preservation rule (the `for id in F003 F037 F039` shell loop is preserved).

**Verify:** smoke + read each file end-to-end. Each command file should still cleanly orchestrate its phase fragments.

#### Stage 3.2: `commands/add.md`

**Spec:**
- L7–23 — Pattern F (opening intro paragraphs).
- L54–78 — Pattern F (*"Execution overview — read this first"* — re-lists §1–§10 verbatim; the section headers are sufficient).
- L82–97 — Pattern F (*"Sub-agent dispatch pattern"* — previews §4/§5/§7).
- L495–498 — Pattern C (Wave 2 absence justification — keep *"no Wave 2"*; drop the *"the user is adding a bounded set..."* rationale).
- L507–509 — Pattern A (cross-fragment design-decision cite to §3.8).
- L558–575 — Pattern A + B (cross-ref to `05-validation.md §4.2` + meta-commentary about why the prompt is inlined; keep the operative rule *"One Opus per candidate"*).
- L686-697 — Apply this exact replacement: *"When `pre_validator_clean == false`, skip the sweep — without a clean baseline we can't distinguish user state from validator writes, and a blind revert would clobber user work. `/adamsreview:add` has no Phase-0 dirty-tree gate, so this conditional is the only safeguard against that data-loss class."* (Preserves the "only safeguard" claim that documents the data-loss prevention.)
- L730–740 — Pattern F (*"The contract is the output, not the technique"* explanatory paragraph; replace with one operative sentence).
- L980–994 — Pattern E (*"What this command does NOT do"*).
- L996–1000 — Pattern B (*"Defined in this file (rather than as separate fragments)..."* prompt-organization rationale).
- L1056, L1102 — Pattern B (*"Model: Sonnet. Budget: ~3–8k tokens..."* maintainer hints — confirm the dispatch site already specifies the model; if so, the hint is decoration).

**Hard constraints:**
- The paste-normalizer Sonnet sub-agent prompt + the dedup Sonnet prompt + the validator dispatch prompts are preserved.
- L413–421 (Pattern F-adjacent — *"Read `trivial_mode` from the artifact..."*) — borderline; the *"if we skipped this branch here, new findings would ship with..."* rationale shapes the LLM's understanding of why the branch matters. Keep one operative sentence; trim the consequence prose.

**Verify:** smoke + spot-read §1 (paste-normalizer dispatch), §4 (dedup dispatch), §7 (validator dispatch), §10 (re-publish). The file should still cleanly orchestrate all five sub-agent calls.

#### Stage 3.3: Detection + early validation fragments

**Group:** `00-preflight.md`, `02-ensemble-adapter.md`, `03-dedup.md`, `04-scoring-gate.md`. Each has a few HIGH-confidence findings; grouping into one stage is appropriate because each individual file would have only 3–9 small edits.

**Spec — `00-preflight.md` (avoid overlap with Phase 1.1 archive sweep):**
- L3-7 — **Surgical, not whole-block:** PRESERVE the sentence *"This phase is mostly deterministic shell — the only LLM call is the Sonnet user-facing-change classifier (step 0.9), and that's skipped in trivial mode."* (phase-scope invariant per Pattern F's preserve list). DELETE only any duplicate-of-frontmatter sentences — typically the opening line that re-states what the fragment does.
- L49–51 — Pattern A + B (cross-reference rationale for code reorg).
- L88–90 — Pattern B (justifies why code lives here).
- L99–101 — Pattern C (comparison_ref vs base_branch rationale; confirm operative directive remains).
- L113–115 — Pattern G (helper algorithm description).
- L169–173 — Pattern C (*"Pre-Stage-2.8 this timestamp also anchored..."* through *"...metrics-only."*). Note: L168 (*"This is the review's start time — consumed by Phase 6 `metrics.time_elapsed_seconds` for cost-vs-size tracking."*) is operative and PRESERVED.
- L398–405 — Pattern A + F (forward-reference + cross-reference prose around `base_context` build).

**Preserve in 00-preflight.md (do NOT remove):**
- L513-520 — closing operative invariant naming which ref Phases 1-6 use for git diff / git blame / lens-prompt construction. NOT preamble; lives at end-of-file.

**Spec — `02-ensemble-adapter.md`:**
- L37–43 — Pattern A + F (token-accounting clarification).
- L44–73 — Pattern F (*"Readiness — already done in the Phase 1 fragment (§13.12)"* — compress to *"By this point, `coderabbit_available`, `codex_available`, ... are in working context (set by `01-detection.md` step 1.2a)."*).
- L298–300 — Pattern A (drop §13.12 citation; keep *"Do NOT call --add-finding"*).
- L301–326 — Pattern F (multi-clause preamble before parse-with-repair; compress).
- L361–365 — Pattern A + C (refactoring history).
- L373–375 — Pattern A (DESIGN §9.3 citation).

**Spec — `03-dedup.md`:**
- L21–28 — Pattern B (schema-state explanation).
- L177–184 — Pattern B (in-bash comment trailing rationale).
- L242–246 — Pattern A (`§13.7` cross-ref).

**Spec — `04-scoring-gate.md`:**
- L62-69 — Apply this exact replacement: *"Chunk into batches of at most 25 candidates per Sonnet sub-agent. Unbounded batches collapse score resolution onto the rubric anchors (every score landing on 0/25/50/75/100) and stop using parallelism on large reviews — the 25-cap restores both."*
- L228–249 — Pattern B + A (cross-references plan #24, restates what code does).

**Hard constraints:**
- All Phase 3 lens dispatch logic in `00-preflight.md` is operative — don't touch.
- The dedup prompt blockquote in `03-dedup.md` is preserved.
- The Phase 3 cheap-scoring Sonnet prompt in `04-scoring-gate.md` is preserved (audit confirmed lean).
- L97–101 of `04-scoring-gate.md` (*"Err-up instruction..."*) is judgment-shaping — preserve.
- L52–58 of `03-dedup.md` (*"Be conservative — prefer splitting when unsure"*) is judgment-shaping — preserve.

**Verify:** smoke + spot-read each modified file's main flow.

#### Stage 3.4: Late validation + fix-side fragments

**Group:** `07-finalize.md`, `08-fix-loader.md`, `09-fix-execution.md`. Each has a few HIGH-confidence findings.

**Spec — `07-finalize.md`:**
- L1–8 — Pattern F (section-list preamble).
- L36–42 — Pattern G (helper-internals: *"The helper slurps `tokens.jsonl`, computes totals..."*).
- L54–74 — Pattern G (sub-agent tally narrative).
- L76–88 — Pattern A + F (opt-in justification + cross-ref to README §"Token counts"; keep the operative *"set ADAMS_REVIEW_TALLY_ORCHESTRATOR=1"* invocation if any).
- L191–195 — Pattern B (*"Phase 0 already wrote this at step 0.16. Re-write here as idempotent safety rail..."*).
- L237–241 — Pattern A + B (bash comments laden with cross-step rationale + DESIGN §13.4).
- L296–301 — Pattern B (UX justification for using a descriptive block instead of AskUserQuestion; keep operative *"Do NOT use AskUserQuestion here"*).

**Hard constraints:**
- The Phase 6 *"Next steps"* user-facing chat block (typically at the tail of §6) is **preserved verbatim** (preserve list #6).

**Spec — `08-fix-loader.md`:**
- L1–11 — Pattern F (long preamble).
- L222–223 — Pattern A (DESIGN §6 schema cite).
- L236–239 — Pattern B (schema design factoid).

**Hard constraints:**
- The leftover-attempted error message (L85–99) is **preserved verbatim** (user-facing — preserve list #6).

**Spec — `09-fix-execution.md`:**
- L1–8 — Pattern F (sectional preamble).
- L17-23 — Pattern D removal (the keep-in-sync block only). PRESERVE L13-15 (operative human_confirmation bypass invariant — current-state documentation tied to the Phase 8 fix-gate).
- L124–126 — Pattern B (multi-clause parenthetical about hard-abort; keep *"surface the error and abort"*).
- L133–136 — Pattern B (state-machine narrative).

**Hard constraints:**
- The fix-group editor agent prompt blockquote (~§8.5) is preserved untouched.
- The fenced fix-group editor agent prompt body in §8.5 (opens at L146, closes at L266) is preserved in its entirety. Any line range falling inside this fence is out of scope for Stage 3.4.
- The Pattern D mirrors at `08-fix-loader.md` L18–23 and `09-fix-execution.md` L13–23 are removed here, but the canonical sync marker at `walkthrough.md` L148–149 is preserved (per Stage 2.5 / Fix 13). If Fix 13 is reverted later, restore at minimum one of these mirrors.

**Verify:** smoke + spot-read the fix-loader's eligibility-filter logic and the fix-execution's group-dispatch logic.

### Phase 4 — Verify and bump

#### Stage 4.1: Full diff review + smoke + sanity

**Spec:**
1. `git diff <execution-start-sha>..HEAD --stat` (using the SHA captured at the start of cleanup execution, not `main`) → only `commands/*.md`, `fragments/*.md`, and `plans/comments-and-words-execution.md` modified. The plan file itself (`plans/comments-and-words.md`) is part of the branch baseline and is expected to be already-committed before execution begins.
2. `test/smoke.sh` → PASS (exact assertion count vs `main` baseline; should be unchanged).
3. Full diff hand-read pass: every removal traces to one of Patterns A–G. Anything that doesn't is reverted.
4. Cross-fragment consistency check:
   - `grep -nE 'DESIGN §|see plans/|per §[0-9]'` across modified files → near-zero (only inside sub-agent prompt blockquotes and user-facing text, if anywhere).
   - `grep -nE '\b(T1|T8|T9|R2)\b' fragments/01-detection.md` → zero or operative-only.
   - `grep -nE '^### Working-set delta' fragments/*.md` → zero.
5. Run `claude --plugin-dir "$(pwd)" /adamsreview:review --help` (or equivalent dev-run) to confirm the orchestrator can still load the prompt without parse errors.
6. **Behavioral fixture diff (BLOCKING).** Run `/adamsreview:review` against a pinned target (a tagged commit committed under `test/fixtures/` for this purpose; see Phase 0 below). Diff the resulting `artifact.json` against an expected snapshot for: `findings[].id` set, `disposition` per id, `score_phase4` ± 5 tolerance per id, `actionability` per id. Material drift in any of these = revert the offending stage and re-spec.
7. Optional sanity: a real `/adamsreview:review` against a small test PR or fixture, if a target is available. **Don't gate on this — it's confirmation, not blocking.**

#### Stage 4.2: Plugin version bump

**Per CLAUDE.md operational rule:** *"Bump `.claude-plugin/plugin.json` version on user-visible behavior changes before merging."*

**Decision:** these are prompt-content changes, not behavioral. Per CLAUDE.md: *"Skip for docs-only / test-only / pure-refactor changes."* Argue this falls under "pure refactor of prompts" — the LLM should produce identical outputs. **Default: skip the version bump.**

But — token cost is user-observable (cumulative spend lines in the published comment will be lower; the statusline `ctx:` badge will move). Treat that as user-visible if any baseline measurements change materially. **Decision rule:** tied to Stage 4.1's behavioral fixture test (Fix 2). If the artifact diff shows ANY drift in `findings[]` set / `disposition` per id / `score_phase4` band — that is a behavioral change. Either revert the offending stage, or, if drift is acceptable per human review, bump patch (`0.2.5 → 0.2.6`). If no drift, skip the bump even if line count dropped substantially. Token-cost reduction alone is not a user-visible behavior change.

#### Stage 4.3: CLAUDE.md drift check

**Spec:** scan `CLAUDE.md` for any reference to a section/line that has been removed. Most prose changes won't affect CLAUDE.md (which references files and helpers, not specific lines). But: if a CLAUDE.md anchor like *"see fragments/01-detection.md L1131-1142 for the T1 rationale"* exists, update or remove the anchor.

**Method:** `grep -nE 'fragments/[^ ]+\.md L?[0-9]' CLAUDE.md`. If hits found, hand-check each.

## Out of scope (deferred)

- MEDIUM-confidence verbosity items where compression requires per-paragraph judgment (Appendix C).
- Lens prompt blockquote bodies (audit confirmed clean — no bloat).
- The Opus deep-validator prompt body, post-fix reviewer prompt body, fix-group editor prompt body, paste-normalizer prompt body, dedup prompt body (all confirmed lean).
- User-facing chat-rendered text (separate concern; if compression is wanted there, do it as a UX pass).
- CLAUDE.md trimming (separate audit if desired).
- Bumping schemas / helpers / tests.
- Re-flowing markdown that becomes oddly-spaced after deletions — leave for a final manual pass at end of Phase 4 if warranted.

## Risk register

1. **Removing rationale that was actually steering judgment.** Mitigation: each stage's preserve list explicitly calls out judgment-shaping rationale. Verify includes a hand-read.
2. **Breaking sub-agent prompt blockquote boundaries.** Mitigation: Patterns A–G never modify content inside blockquotes; sub-agents are explicitly instructed not to touch them.
3. **Smoke regressions from accidentally deleted operative content.** Mitigation: `test/smoke.sh` runs after every stage; per-stage spot-reads catch what smoke doesn't.
4. **Merge conflicts between Phase 2/3 stages.** Mitigation: stages within a phase touch disjoint files; Phase 1 sweeps complete before Phase 2 begins (the build journal locks the order).
5. **CLAUDE.md drift.** Mitigation: Stage 4.3.
6. **Hidden user-visible side effects** (e.g., the published PR comment's prose changes because a cited line was rendering through). Mitigation: prompt prose doesn't render to PR comments — only `artifact.md` does, and that's generated by `bin/artifact-render.py` from structured artifact data. Low risk; verify by Stage 4.1's optional sanity run.

## Build journal

Track per stage, in `plans/comments-and-words-execution.md`:
- Files touched
- Number of removals (counted against Patterns A–G)
- Smoke result
- Spot-read findings (any close calls; any reverts)
- Diff size

## Appendices

### Appendix A: Audit summary by file

| File | HIGH findings | Approx. recoverable lines | Stage |
|---|---|---|---|
| `commands/walkthrough.md` | 12 | ~80–100 | 2.5 |
| `commands/add.md` | 10 | ~80–100 | 3.2 |
| `commands/review.md` | 7 | ~50–70 | 3.1 |
| `commands/fix.md` | 7 | ~40–60 | 3.1 |
| `commands/promote.md` | 4 | ~20–30 | 3.1 |
| `fragments/00-preflight.md` | 9 | ~30–50 | 3.3 |
| `fragments/01-detection.md` | 12 (mostly L999–1206) | ~60–80 | 2.3 |
| `fragments/02-ensemble-adapter.md` | 7 | ~30–40 | 3.3 |
| `fragments/03-dedup.md` | 4 (one big at 99–130) | ~25–35 | 3.3 |
| `fragments/04-scoring-gate.md` | 3 | ~20–30 | 3.3 |
| `fragments/05-validation.md` | 10 | ~50–70 | 2.6 |
| `fragments/06-cross-cutting.md` | 0 (well-optimized) | — | (sweep only) |
| `fragments/07-finalize.md` | 5 | ~30–40 | 3.4 |
| `fragments/08-fix-loader.md` | 3 (incl. one big at 18–23) | ~15–25 | 3.4 |
| `fragments/09-fix-execution.md` | 4 | ~25–35 | 3.4 |
| `fragments/10-post-fix-and-commit.md` | 12 | ~80–100 | 2.4 |
| `fragments/_prelude-shared.md` | 3 | ~5–10 (highest multiplier) | 2.1 |
| `fragments/promote-core.md` | 3 (incl. 19-line block at 89–107) | ~25–35 | 2.2 |
| `fragments/lens-security-reference.md` | 0 (well-optimized) | — | (sweep only) |
| `fragments/lens-ux-reference.md` | 0 (well-optimized; one heavy section at 31–50) | — | (sweep only — defer compression) |

### Appendix B: How sub-agents should report per stage

For each stage, the executing sub-agent returns:

```
Stage X.Y completed.
Files touched: [list]
Removals: [count] across patterns [A, B, C, ...]
Smoke: PASS (N assertions)
Spot-read notes: [any close calls; any reverts]
Diff size: -[lines removed] / +[lines added (should be near zero for cleanup)]
```

Anything not matching this shape is flagged for orchestrator review before proceeding.

### Appendix C: Deferred MEDIUM items (future plan)

The audit identified MEDIUM-confidence verbosity items that this plan does NOT touch:

- **`03-dedup.md` L99-130 (C1/C2 reconciliation rationale)** — the prose encodes (a) C1's same-origin-lowest rule, (b) C2's cross-origin cap rule, (c) an order-independence proof, and (d) the F038 rename-follow trade-off. The jq at L184-204 encodes (a)+(b) but not (c)+(d). Compression requires explicit-replacement-text drafted in advance, not heuristic trim. Defer to a follow-up plan.
- Compressing rationale-into-one-liners in:
  - `05-validation.md` light-lane prompt opening (L217–232).
  - ~~`09-fix-execution.md` "What to do" rationale tails (L213-244)~~ — REMOVED from deferred work: this content is inside the §8.5 preserved fix-group editor agent prompt body. Any future compression of dispatched prompt bodies is a separate redesign exercise, not a comments-and-words sweep target.
- Restructuring `commands/walkthrough.md` *"What it does"* TOC (L38–58) — borderline-operative; treat in a follow-up.
- The lens-ux-reference.md *"Diagnostic message quality"* section (L31–50) — examples genuinely shape judgment but are heavier than the rest of the file.
- General markdown re-flow / tightening of bullet-list grammar.

If desired, draft a follow-up plan after Phase 4 completes and baseline measurements are in.

### Appendix D: Recommended `/orchestrate` invocation

```
/orchestrate plans/comments-and-words.md
```

Phases 1.1 and 1.2 run sequentially. Phase 2's six stages can fan out in parallel (different files). Phase 3's four stages can fan out in parallel. Phase 4 runs after both Phase 2 and Phase 3 quiesce. The build journal goes to `plans/comments-and-words-execution.md`.
