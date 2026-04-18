# BUILD.md — build journal for adams-review

This is the running build journal. `DESIGN.md` is the normative design (rev 8). This file tracks **execution**: where we are, what's landed, what surprised us, and what still needs attention.

If you are a Claude Code session starting fresh (after compaction or on a new day), **read this file first**, then open `DESIGN.md`. Skim "Current state" and the active stage's section; you can treat the rest as reference.

---

## Current state

**As of 2026-04-18 — Stage 2.5 COMPLETE.** Four hardening commits landed: sensitive-file gate resolved via reviews-root relocation (Claude Code's `.claude/` gate is hardcoded; docs-probe confirmed `additionalDirectories` can't bypass it, so the default root moved to `~/.adams-reviews/`); Phase-4 decision-table collapsed into `artifact-patch.py --apply-decisions` (one helper call per wave replaces the per-finding loop, matching the Stage-3 authoring-discipline for context budget); light-lane `uncertain` renderer bug fixed (re-rendering C13's ray-finance artifact now surfaces F021/F022/F032 which had been silently dropped from PR comment `4274059620`). `test/smoke.sh` passes 43 assertions. Next: plan Stage 3 (`/adams-review-fix`).

- Design doc: `DESIGN.md` (rev 8 + §21.2 exit-code footnote + §21.2 `--apply-decisions` clarification + §5.2.1 `pending_validation` clarification + §9.2 reviews-root relocation + §8.7 sensitive-gate prose correction + §12.1 example fix)
- Stage 1 plan: `plans/stage-1-foundation.md` (user-approved; closed out)
- Stage 2 plan: `plans/stage-2-review.md` (user-approved; closed out)
- Stage 2.5 plan: `plans/stage-2.5-hardening.md` (user-approved; closed out)
- Symlink `~/.claude/commands/_shared → commands/_shared` is live
- `uv` (`/opt/homebrew/bin/uv 0.7.15`) supplies `jsonschema` to Python scripts via PEP 723 inline-script shebangs
- Default reviews root: `~/.adams-reviews/<slug>/<branch>/<review_id>/` (override via `$ADAMS_REVIEW_REVIEWS_ROOT`)

**Stage 1 commits (on `main`, newest first):**

```
(this commit) Close Stage 1: BUILD.md + DESIGN §21.2 exit-code footnote
1324dfc       Add Stage 1 smoke harness (plan §7 done-when walk-through)
2c765f4      Add artifact-publish.sh (DESIGN §21.6, §13.4)
84f9d71      Add staleness.sh (DESIGN §21.4, §13.3)
e624f00      Stage 1 mid-stage compaction checkpoint
17a18a4      Add claude-md-paths.sh (DESIGN §21.7, §23)
53cc516      Add log-phase.sh and log-tokens.sh (DESIGN §11, §12, §21.6)
fe032d0      Add artifact-read.sh (DESIGN §8.1, §21.1)
8fca196      Add artifact-validate.sh (DESIGN §8.3, §21.3)
a3bede7      Add artifact-render.py (DESIGN §7, §21.6)
83ee47a      Add artifact-patch.py --dry-run
d669d5f      Add artifact-patch.py --append-fix-attempt (combinable with --set)
2504b09      Add artifact-patch.py --set mode (transitions + coupling)
926d9fe      Add artifact-patch.py --add-finding mode
cd1991c      Add artifact-patch.py --init mode (DESIGN §8.2, §21.2)
f374a36      Add _common.py: shared Python helpers for writer scripts
98c0fb5      Add schema-v1.json codifying artifact shape (DESIGN §5, §6)
3c82a1e      Scaffold Stage 1 layout: symlink, READMEs, durable plan
bd6b610      Bootstrap repo with design doc (rev 8) and build journal
```

**Deferred from Stage 1:**
- **§8.7 grant probe** (Task #29, pending). Not in the mainline close-out; can be done ad-hoc before Stage 2 builds the top-level command file with a real grant block. When done, record outcome in *Cross-stage notes*.

**Next action:** plan Stage 2 (`plans/stage-2-review.md`). Read this BUILD.md + DESIGN.md + the durable Stage 1 plan before entering plan mode.

---

## Stage index

| # | Name | Status | Plan | Close-out notes |
|---|------|--------|------|-----------------|
| 1 | Foundation (data layer + shared helpers) | **done** | `plans/stage-1-foundation.md` | [Stage 1 section](#stage-1--foundation) |
| 2 | `/adams-review` end-to-end (Phases 0–6) | **done** | `plans/stage-2-review.md` | [Stage 2 section](#stage-2--adams-review) |
| 2.5 | Hardening — reviews-root relocation + Phase-4 batch + renderer fix | **done** | `plans/stage-2.5-hardening.md` | [Stage 2.5 section](#stage-25--hardening) |
| 3 | `/adams-review-fix` (Phases 7–9 + terminal cleanup) | not started | `plans/stage-3-fix.md` | — |

### Stage 1 — Foundation

**Scope (target, subject to plan refinement):**
- JSON Schema for `artifact.json` (codifies DESIGN §5–§6)
- `artifact-patch.py` — field-level mutations, state-transition whitelist, `--append-fix-attempt`, `--init`, `--add-finding`, `--dry-run`
- `artifact-render.py` — `artifact.json` → `artifact.md` (filter-by-`disposition` sections per §7)
- Shared helpers (Bash): `artifact-publish.sh`, error-as-prompt wrappers, repo-context / reviewer-sources / mode-detection / CLAUDE.md-paths fragments
- `phases.jsonl` / `trace.md` / `tokens.jsonl` loggers
- Directory scaffolding per DESIGN §9

**Done when:** I can hand-author a synthetic `artifact.json`, run `artifact-patch.py` + `artifact-render.py` against it, and produce a correct `artifact.md`. Schema validation rejects malformed inputs with error-as-prompt messages. No slash command runs yet.

**Status:** done (2026-04-17).

**Files landed:**
- `commands/_shared/schema-v1.json` — JSON Schema Draft 2020-12 codifying DESIGN §5–§6 (strict enums, `additionalProperties: false` everywhere, regex-constrained ids and SHAs, nullable-where-§6-allows).
- `commands/_shared/tools/_common.py` — shared Python helpers: exit-code constants, `err_prompt()` + `suggest()`, schema validator loader (with `ImportError → EXIT_MISSING_DEP`), `validate()`, `atomic_write()`, `is_append_only()`, `derive_is_actionable()`, `transitions_from()`.
- `commands/_shared/tools/artifact-patch.py` — canonical writer: `--init`, `--add-finding`, `--set` (repeatable; allowlisted), `--append-fix-attempt` (combinable with `--set` per §26), `--dry-run`. Enforces state-transition whitelist, disposition/is_actionable coupling, and the `current_state=resolved ⇔ disposition=resolved` coupling. Auto-appends `score_history` when `score_phase3/4` is set.
- `commands/_shared/tools/artifact-render.py` — renders `artifact.json` → Markdown per §7: stable marker, header, disposition-filtered deep/light/pre-existing sections, fix-runs section when any finding has attempts, auto-fixable rows sorted by finding id, Status column auto-appears post-fix.
- `commands/_shared/tools/artifact-validate.sh` — Bash-fronted validator using the uv-heredoc pattern; no companion `.py` required.
- `commands/_shared/tools/artifact-read.sh` — jq wrapper: `--filter`, `--finding-id`, `--summary` (counts by current_state / disposition / impact_type / validation_lane).
- `commands/_shared/tools/artifact-publish.sh` — PR-mode comment discovery (`--comment-id` → marker search → create), local-mode no-op, `{"comment_id": N}` stdout emit, `trace.md` appender.
- `commands/_shared/tools/claude-md-paths.sh` — walk-up CLAUDE.md finder, `@-` stdin mode, root-first dedup in Bash-3.2-portable style.
- `commands/_shared/tools/staleness.sh` — git-diff intersection classifier (safe / warn / unsafe), `@-` stdin mode, reachability check (shallow-clone / force-push guard).
- `commands/_shared/tools/log-phase.sh` — narrative (`trace.md`) and structured (`phases.jsonl`) modes via `--record`.
- `commands/_shared/tools/log-tokens.sh` — one-line-per-invocation JSONL appender (`tokens.jsonl`); supports `--tokens null` literal for the §11 parse-failure fallback.
- `commands/_shared/README.md` + repo-root `README.md` — setup + dependency docs.
- `test/fixtures/artifact-seed.json`, `test/fixtures/expected.md`, `test/fixtures/invalid/bad-disposition.json`, `test/smoke.sh` — 19-assertion done-when harness.

**Verification evidence:**
- `test/smoke.sh` → `smoke: PASS (19 assertions)`. Covers the 12 plan §7 assertions (init / add-finding / validate / four state-machine transitions / append-fix-attempt / render-diff / schema-violation / coupling-violation / dry-run-unchanged) plus sidecar A–F (summary counts, publish-local, claude-md-paths, staleness three-verdict, JSONL loggers, validator rejects bad fixture).
- `test/fixtures/expected.md` and the smoke run's rendered output diff empty byte-for-byte.
- All helper scripts are executable and symlinked into the live path `~/.claude/commands/_shared/tools/...`.

**Open issues / deviations:**
- **`artifact-publish.sh --md-path`** — Stage-1 extension (not in DESIGN §21.6's listed signature). Needed so smoke tests can operate without stubbing `latest.txt`. Stage 2 should make `--md-path` optional with the §13.4 latest.txt fallback. Orchestrator-facing contract unchanged.
- **`staleness.sh` unreachable-SHA guard** — clarification-level addition. §21.4 doesn't specify behavior when the reviewed SHA isn't reachable from HEAD (shallow clone, force-push); Stage 1 exits 1 with an explanatory message rather than silently comparing to unknown history. No DESIGN update required.
- **§8.7 grant probe** (Task #29) — still pending. Not on the critical path for Stage 2 planning, but should be exercised before Stage 2 ships the real top-level command with a full `allowed-tools` block.
- **Summary line vs. bucket list** — `render_summary()` counts `below_gate` in the total but doesn't list it per-lane (since no report section displays sub-threshold findings). Visible in smoke output as "Found 6 findings" but only 5 enumerated. Not a bug; just a rendering choice worth knowing about when reading real output.

### Stage 2 — `/adams-review`

**Scope (target):** top-level `adams-review.md` command, Phase 0–6 fragments, sub-agent dispatch pattern, effort inheritance, trivial-mode gate, publish path.

**Done when:** `/adams-review` run on a real repo produces a valid artifact; PR mode posts/edits the comment; local mode is a no-op on publish.

**Status:** done (2026-04-18). C1–C12 landed; audit rounds 1–4 closed; C13 real-repo smoke on `ray-finance` `feat/import-apple` PASSED with PR comment `4274059620` posted.

**Files landed (C1–C12 + audit fixes):**
- `commands/adams-review.md` — top-level slash command with full `allowed-tools` block and preprocessor-include wiring for fragments.
- `commands/_shared/00-preflight.md` (Phase 0) — argument parsing, branch/base/repo resolution, PR-mode detect with `gh pr view` lowercase transform, `review_started_at` capture, diff surface enumeration, CLAUDE.md path walk, dirty-tree / unpushed-commit / trivial / prior-artifact gates, `review_id` + `review_dir` creation, artifact seed + `latest.txt` atomic write.
- `commands/_shared/01-detection.md` (Phase 1) — six-way parallel lens fan-out (L1 Haiku, L2 Opus, L3/L4/L6 Sonnet, L5 Sonnet conditional on `user_facing && !trivial`), partial→full finding builder stripping candidate-only fields (`source_family`, `evidence_snippet`) and forcing `validation_lane=light` under trivial mode.
- `commands/_shared/02-ensemble-adapter.md` (Phase 1.5) — `--ensemble`-gated CodeRabbit + Codex CLI dispatch in background Bash, PR-comment scrape via `external-scrape.sh`, single Sonnet normalizer, scratch directory under `/tmp/adams-review-$review_id/` for ephemeral CLI I/O.
- `commands/_shared/03-dedup.md` (Phase 2) — single-Sonnet-pass grouping, keeper selection, `--set-json` union of `sources` + `source_families`, `--delete-finding` for dupes.
- `commands/_shared/04-scoring-gate.md` (Phase 3) — pre-existing override sweep, per-finding Sonnet scoring against §20 rubric with err-up, Phase-3 gate that transitions findings to `pending_validation` (advance) or `below_gate` (gate-fail).
- `commands/_shared/05-validation.md` (Phase 4) — lane partition (`pending_validation` survivors only), per-candidate Opus (deep) or Sonnet (light) validators, chain-wave retry capped at 2 waves, Phase-4 decision table, schema-aligned `validation_result` writes (confirmed only), pre-existing re-assertion.
- `commands/_shared/06-cross-cutting.md` (Phase 5) — single Opus pass over deep-lane actionable findings, `cross_cutting_groups` emission with schema-enforced `^G[0-9]+$` + `finding_ids.length >= 2`.
- `commands/_shared/07-finalize.md` (Phase 6) — validate, tally `subagent_tokens` + `metrics`, recompute `reviewer_sources` from actual `findings[].sources[]` union (DESIGN §6), render `artifact.md`, re-assert `latest.txt`, publish (PR mode) or local no-op, mirror report to chat, stash pop.
- `commands/_shared/lens-ux-reference.md` / `lens-security-reference.md` — DESIGN §22.1 / §22.2 inlined verbatim for L5 / L6 prompt preprocessor includes.
- `commands/_shared/tools/external-scrape.sh` — DESIGN §21.8 implementation; parallel `gh api` fetch of 3 endpoints, bot filter + allow/deny config, `--fixtures-dir` replay mode.
- `commands/_shared/tools/artifact-publish.sh` — extended with `--repo-slug` / `--branch` / `--dry-run`; three-tier md-path resolution (`--md-path` > `--review-dir` > `latest.txt`).
- `commands/_shared/tools/artifact-patch.py` — extended with `--delete-finding` and `--set-json` (whitelisted fields: `sources`, `source_families`, `validation_result`, `cross_cutting_groups`, `subagent_tokens`, `metrics`, `reviewer_sources`).
- `commands/_shared/tools/log-phase.sh` — accepts both numeric and string-bucket phases (e.g., `1_5`).
- `commands/_shared/tools/artifact-read.sh` — `--summary` emits `counts_by_state` key to match DESIGN §12.1 naming.
- `commands/_shared/schema-v1.json` — disposition enum extended with `pending_validation` (gate-in parking state).
- `test/smoke.sh` — grew from 19 to 33 assertions covering publish tiers (B3–B5), external-scrape fixture (G), delete-finding + set-json (H–M), numeric + string phase logging (E), pending_validation enum (N), counts_by_state rename (O), empty-list jq safety (P), disposition/is_actionable coupling (Q).

**Open deviations / clarifications (inherited from audit rounds):**
- **DESIGN §5.2.1 `pending_validation` enum** — gap that the two consecutive audits surfaced: schema forbids null `disposition`, but `below_gate` semantically means "gate-failed"; gate-in needed its own parking value. Added as a clarification-level DESIGN + schema + `_common.py` change, mirrored into 01-detection / 04-scoring-gate / 05-validation.
- **`validation_result` schema alignment** — 05-validation step 4.2 prompt now returns the exact shape `schema-v1.json` validates, and step 4.4 only writes `validation_result` for confirmed findings (disproven/uncertain get no nested object — schema's non-null nested requirement would otherwise reject them).
- **`reviewer_sources` Phase-6 recompute** — seed at Phase 0 is `["internal"]`; Phase 6 step 6.3a unions over `findings[].sources[]` for the final list per DESIGN §6.
- **`sources[]` per-finding lens vocabulary** — `L1-diff-local` / `L2-structural` / `L3-claude-md` / `L4-comments` / `L5-ux` / `L6-security` (matches DESIGN §6 example).
- **`counts_by_state` key rename** — `artifact-read.sh --summary` now emits `counts_by_state` (was `counts_by_current_state`) so phases.jsonl aggregators in 07-finalize don't produce `null` keys.

**C13 real-repo smoke — PASSED (2026-04-18).**

First end-to-end execution of `/adams-review` on `ray-finance` `feat/import-apple`:

| Phase | Elapsed | Outcome |
|---|---|---|
| 0 preflight | 1849s | user-prompt-heavy (dirty-tree gate, prior-artifact prompt, sensitive-file permission prompts); mode=pr, PR #8 draft, 43 files / 4270 lines |
| 1 detection | 737s | 6 lenses parallel; 38 candidates |
| 1.5 ensemble | — | skipped (no `--ensemble`) |
| 2 dedup | 5s | 5 merged → 33 survivors |
| 3 scoring-gate | 30s | 15 gate-fail → `below_gate`; 18 advanced → `pending_validation` |
| 4 validation | 420s | 4 `confirmed_auto`, 4 `uncertain`, 10 `disproven` |
| 5 cross-cutting | 15s | 0 groups (4 deep-lane actionables, no cross-file dependencies surfaced) |
| 6 finalize | <1s | artifact.md 15,671 bytes; PR comment `4274059620` posted |

- **Token spend:** 978,924 total / 19 invocations (Opus 450k, Sonnet 415k, Haiku 114k)
- **Trace failures:** none
- **Reviewer_sources recompute:** `["internal"]` (correct — no ensemble)
- **comment_id persisted:** yes; next run on this PR will PATCH rather than POST

**The 4 confirmed_auto findings were all real bugs** (F011 SQL filter drops accounts with zero liability balance; F013 parallel-path disagreement between `showAccounts` and `runRemove` manual-detection; F014 `useAgent.submit()` dead-input during onboarding; F017 LOAN_PAYMENTS prefix mismatch polluting recap totals). 4 uncertain findings recorded for human review.

**Round-2/3/4 audit fixes exercised and held:** `pending_validation` state machine transitions cleanly; `pr_state` transform produced `"draft"` on first try; `counts_by_state` correctly populated in phases.jsonl; `validation_result` extraction path would have fired on any deep-lane confirmed finding (did on F011/F013/F014/F017 — all schema-valid). No Phase 5 extraction code path fired because the sub-agent returned `[]` groups for this diff.

**Hot-fix landed mid-smoke:** first attempt hit Phase 0 step 0.15 `review_id` fallback format bug — `rev_<ts>_<rand>` contained an underscore after `rev_` which the schema regex rejected. Fix at commit `e0df35d` + smoke assertion Vbis; a fresh `uv run --with ulid-py` path works too (26-char Crockford base32 is pure alphanumeric).

### Stage 2.5 — Hardening

**Rationale.** Two observations from the C13 real-repo smoke surfaced UX / scalability concerns that are cheaper to resolve before Stage 3 ships `/adams-review-fix` than after:

1. **Sensitive-file gate** (cross-stage note 2026-04-18) — every write under `~/.claude/reviews/...` triggers a Claude Code permission prompt regardless of `allowed-tools` grants. User sees dozens of prompts per run. Every new user hits this on first run.
2. **Orchestrator context budget** (cross-stage note 2026-04-18) — 243k of session context at 33 findings / 43 files. Headroom at 1M, but Stage 3 adds Phases 7–9 and per-finding loop scaffolding accumulates. Collapsing the Phase-4 decision-table loop is the highest-payoff / lowest-cost lever; other levers become Stage-3 authoring discipline rather than code changes.

**Scope (target):**

- **2.5.A** — Resolve the sensitive-file gate permanently, via one of two paths depending on probe outcome.
- **2.5.B** — Add `artifact-patch.py --apply-decisions <json>` and rewrite `05-validation.md` step 4.4 to call it once instead of looping per-finding.
- **2.5.C** — Append Stage-3 authoring-discipline guidance to *Cross-stage notes* (no code).

**Explicitly out of scope:**

- **Note 1 Lever #1** (Phase-5 `xc_input_json` sub-agent preprocessor) — deferred. Revisit only if a Stage 3 real-repo run shows the orchestrator approaching context limits.
- **Note 1 Lever #4** (fragment prose shrink) — deferred. Not blocking.
- ~~**Renderer bug: Light-lane `uncertain` dispositions silently dropped from PR comment**~~ — decision made during planning review: folded into Stage 2.5 as its own sub-item (**2.5.D**), not into 2.5.B. C13 evidence (F021/F022/F032 present in artifact.json but missing from PR comment `4274059620`) made deferring to Stage 3 too costly to justify. See `plans/stage-2.5-hardening.md` §4 for the decision rationale and §5.4 for execution.

**Done when:**

- A fresh `/adams-review` run on a real repo (sample: ray-finance `feat/import-apple` re-run) completes with **zero** sensitive-file permission prompts, OR one-time prompts only if the probe chose the `additionalDirectories` path.
- `artifact-patch.py --apply-decisions` applies a full Phase-4 decision batch in one call; `05-validation.md` step 4.4 contains one invocation, not a per-finding loop.
- `test/smoke.sh` gains two assertions: one for the `--apply-decisions` batch path; one for the relocated reviews root (if 2.5.A lands the flip).
- DESIGN §9.1 and §21.2 updated if-and-only-if reality moved (clarification-level; no approval round-trip).

---

**2.5.A — Sensitive-file gate resolution**

1. **Probe** `additionalDirectories` in `.claude/settings.json` as a bypass. Single scratch session: create a test project with `.claude/settings.json` containing `{"permissions": {"additionalDirectories": ["~/.claude/reviews"]}}` (exact key TBD per Claude Code docs), trigger a write to `~/.claude/reviews/probe_test/trace.md`, observe whether the sensitive-file prompt fires. ~15 min of work. Record outcome in Cross-stage notes.

2. **Branch on probe outcome:**

   **(B) bypasses the gate** → Ship documentation only. No code change.
   - Add a `setup` section to repo-root `README.md` instructing users to add the `additionalDirectories` line to their project's `.claude/settings.json`.
   - DESIGN §9.1 gains a one-line note documenting the requirement.
   - Release-notes text for users upgrading.

   **(B) does NOT bypass the gate** → Flip the default reviews root.
   - `$ADAMS_REVIEW_REVIEWS_ROOT` default changes from `~/.claude/reviews` to `~/.adams-reviews` (leading dot = hidden-state-dir convention; outside `.claude/` → gate doesn't fire).
   - Grep for every hardcoded `~/.claude/reviews` reference; touch points at minimum:
     - `commands/_shared/00-preflight.md` (review_dir construction)
     - `commands/_shared/tools/artifact-publish.sh` (latest.txt resolution)
     - `commands/_shared/tools/external-scrape.sh` (scratch dir — if present)
     - README.md, DESIGN.md §9.1
   - Migration text in README: *"If you have pre-2.5 reviews under `~/.claude/reviews/`, either `mv ~/.claude/reviews ~/.adams-reviews` OR `export ADAMS_REVIEW_REVIEWS_ROOT=~/.claude/reviews` to keep them where they are."*
   - DESIGN §9.1 rewording: canonical default is now `~/.adams-reviews/`; env-var override documented.

3. **Verification:** re-run `/adams-review` on ray-finance `feat/import-apple` (or a smaller test repo); confirm zero permission prompts end-to-end.

---

**2.5.B — Phase-4 decision-table collapse**

1. **`commands/_shared/tools/artifact-patch.py`** — add `--apply-decisions <path-or-@->` mode.
   - Consumes a JSON array of tuples shaped:
     ```json
     {
       "id": "F011",
       "score_phase4": 78,
       "decision": "confirmed",
       "actionability": "auto_fixable",
       "validation_result": { ... },
       "reason": "...",
       "confirmed_strength": "strong",
       "related_parent_finding_id": null
     }
     ```
     (`validation_result` present only when `decision == confirmed`; other fields optional per §13.1.)
   - Internally applies §13.1 decision table to each tuple — same transition/coupling checks as `--set`; `--set-json validation_result=…` applied atomically per-tuple.
   - Exit-code semantics: 0 success; 1 if any tuple fails validation (batch halts at first failure, preceding tuples already committed atomically); clear stderr identifying which tuple failed.
   - No partial-batch rollback. First-failure-halts keeps the helper simple; callers re-invoke with the remainder.

2. **`commands/_shared/05-validation.md`** — rewrite step 4.4.
   - **Before:** per-finding loop, each iteration building a decision tuple and invoking `artifact-patch.py --set …` with prose summary.
   - **After:** accumulate all Phase-4 validator outputs into one JSON array (in a temp file under `/tmp/adams-review-$review_id/`), single `artifact-patch.py --apply-decisions @file` call. Summary prose collapses to one line: `applied N decisions (confirmed_auto=X, confirmed_manual=Y, uncertain=Z, disproven=W)`.

3. **`test/smoke.sh`** — add one assertion: seed an artifact with 3 findings in `pending_validation`, feed a mixed-decision batch (one confirmed-auto, one uncertain, one disproven), assert post-state matches per-tuple expectations.

4. **DESIGN.md §21.2** — add `--apply-decisions` row to the `artifact-patch.py` sub-section. Clarification-level (no behavior change beyond the helper gaining a new mode).

---

**2.5.C — Stage-3 authoring guidance (no code)**

Append to *Cross-stage notes* the following principles captured from Note 1 Levers #1, #2, #4 — to be consulted when drafting Stage 3 phases:

- **Read for decisions, not for holding.** Prefer narrow `jq` filters that return a verdict (`.findings | length`, `.findings | map(.disposition) | unique`) over reading full records into orchestrator context when the orchestrator only needs a branch decision.
- **Delegate large-context synthesis to sub-agents** that return structured summaries (ids, group memberships, verdicts) rather than handing the full prompt+data to the orchestrator and emitting back prose.
- **Avoid per-finding loops in fragments when a single helper call can carry the same semantics.** Each loop iteration accumulates prose in orchestrator context; a batched helper invocation does not.

These are authoring disciplines, not enforced by tooling. Stage 3 planning should apply them from the start.

---

**Commit cadence (estimated):**

1. 2.5.A probe + outcome recording — 1 commit.
2. 2.5.A fix path (either docs-only or the relocation patch) — 1–2 commits.
3. 2.5.B helper-mode + fragment rewrite + smoke + DESIGN footnote — 1–2 commits.
4. Stage 2.5 close-out — BUILD.md fill-in + *Cross-stage notes* append — 1 commit.

~5 commits total. Smaller than Stages 1/2.

**Plan file:** `plans/stage-2.5-hardening.md` (user-approved 2026-04-18). Added 2.5.D (renderer bug) as its own sub-item during planning review per the BUILD.md "Explicitly out of scope" open decision.

**Status:** done (2026-04-18).

**Stage 2.5 commits (on `main`, newest first):**

```
(this commit) Close Stage 2.5: fix light-lane uncertain renderer + hardening close-out
e74d8d7       Collapse Phase-4 decision loop to single apply-decisions call (05-validation)
3c9429a       Add artifact-patch.py --apply-decisions for Phase-4 batch application (§13.1, §21.2)
d576214       Relocate reviews root to ~/.adams-reviews to bypass sensitive-file gate (§9.2)
169651b       Record Stage 2.5.A probe: additionalDirectories does not bypass .claude/ gate
b262738       Add Stage 2.5 hardening plan
```

**Files landed:**

- `plans/stage-2.5-hardening.md` — durable plan with the renderer-bug decision folded in as 2.5.D (commit `b262738`).
- `BUILD.md` — probe-outcome cross-stage note (commit `169651b`).
- **2.5.A — reviews-root relocation** (commit `d576214`):
  - `commands/_shared/00-preflight.md` — env-var fallback default flipped to `$HOME/.adams-reviews`.
  - `commands/_shared/tools/artifact-publish.sh` — tier-3 `latest.txt` resolver default flipped.
  - `commands/_shared/tools/external-scrape.sh` — global `review-config.json` default path flipped.
  - `commands/_shared/tools/artifact-read.sh` — header comment updated.
  - `DESIGN.md` — §9.2 canonical layout flipped + new override/rationale bullet; §8.7 prose corrected (earlier draft claimed review writes didn't hit the protected-directory layer; C13 proved false); 13 other section references bulk-updated (§3.3 / §4 Phase 0 / §12.1 / §13.5 / §13.8 / §14 / §18 / §21.1 / §21.8 / §24 / §25).
  - `README.md` — new "Review state location" section with migration instructions.
  - `test/smoke.sh` — +1 assertion (B6) verifying default resolves under `~/.adams-reviews`.
- **2.5.B — `artifact-patch.py --apply-decisions`** (commit `3c9429a`):
  - `commands/_shared/tools/artifact-patch.py` — new mode: `ALLOWED_DECISION_TUPLE_KEYS`, `CONFIRMED_BAND`, `_ACTIONABILITY_TO_DISPOSITION`, `_derive_phase4_disposition`, `cmd_apply_decisions`. `_write_and_emit` gains `silent=True` so the batch loop emits one summary line instead of N per-tuple lines.
  - `DESIGN.md` §21.2 — new clarification paragraph documenting the mode, including the score-wins-over-decision derivation, the confirmed-band-only `validation_result` write, per-tuple atomic writes with first-failure halt, and the `--dry-run` non-support rationale.
  - `test/smoke.sh` — +2 assertions (W: mixed 3-tuple batch; X: confirmed-band tuple without actionability halts + leaves artifact unchanged).
- **2.5.B — `05-validation.md` fragment rewrite** (commit `e74d8d7`):
  - Step 4.4 replaced per-finding loop with one `--apply-decisions` call per wave (jq composes the tuple array; single helper invocation emits the summary line).
  - Step 4.5 step 4 (Wave 2 application) routed to the same batched approach.
- **2.5.D — renderer fix + close-out** (this commit):
  - `commands/_shared/tools/artifact-render.py` — lines 148 and 323 tuples gain `"uncertain"` with a comment explaining the regression and the C13 data-loss context.
  - `test/fixtures/artifact-seed.json` — F006 added (light-lane uncertain architecture finding; `src/models/preferences.ts:15-22`) + `reviewed_files_all` updated.
  - `test/fixtures/expected.md` — regenerated; summary count 6 → 7, Light lane table gains F006 row.
  - `test/smoke.sh` — A assertion's expected counts updated (findings_total 6 → 7, uncertain 1 → 2); +1 assertion (Y) explicitly grepping for F006 in the rendered output so a future tuple-literal drop surfaces with a clear signal.
  - `BUILD.md` — this close-out block and the new cross-stage notes below.

**Verification evidence:**

- `test/smoke.sh` passes **43 assertions**, up from 39 at Stage 2 close. Added: B6 (2.5.A default root), W + X (2.5.B batch + failure), Y (2.5.D renderer regression guard); A assertion updated for the new seed counts.
- **C13 re-render.** Re-rendering `~/.claude/reviews/github.com-cdinnison-ray-finance/feat/import-apple/rev_01KPGJVT5DBEJXR5WHB5Z62PS3/artifact.json` with the Stage 2.5.D renderer surfaces all three previously-dropped findings. The Light-lane summary now reads `3 uncertain` (was absent entirely); the Light lane table includes:
  - `F021` — `src/cli/ink/mount.ts:11-13` — "Non-TTY case returns silently with no exit code…"
  - `F022` — `src/cli/ink/ChatApp.tsx:108-116` — "While isBusy the PromptFrame is entirely unmounted…"
  - `F032` — `src/cli/commands.ts:808-812` — "When `--replace-range` is passed but there are zero existing rows…"
  Output captured locally at `/tmp/c13-rerender.md` during close-out. The live PR comment `4274059620` still shows the pre-fix rendering (not re-published — this is a stage close-out, not a fresh review).
- **Probe outcome recorded** in *Cross-stage notes* 2026-04-18 entry (commit `169651b`).
- **Helper behavior** exercised via smoke W/X and by re-running the full suite after each of the four behavioral commits; no regression observed at any step.

**Open issues / deviations:**

- ~~PR comment 4274059620 still shows pre-fix rendering.~~ **Resolved 2026-04-18.** After close-out, republished via `artifact-publish.sh --mode pr --comment-id 4274059620 --md-path <re-rendered>`. Comment body went 15,550 → 16,641 bytes and now includes F021 / F022 / F032 in the Light lane table. `trace.md` appended a `patched comment_id=4274059620` line. Pre-flight validated stored comment_id / pr_number / gh user = comment author / `gh repo view` resolving to the upstream `cdinnison/ray-finance` (not the `adamjgmiller` fork remote) before executing.
- **`--apply-decisions` does not support `--dry-run`.** Intentional (DESIGN §21.2 clarification). Stage 3 callers who want pre-flight validation of a tuple array should run it on a throwaway artifact copy. Surface if Stage 3 develops a real need.
- **Pre-Stage-2.5 `~/.claude/reviews/` state.** Not migrated automatically. Users follow README's `mv ~/.claude/reviews ~/.adams-reviews` or `export ADAMS_REVIEW_REVIEWS_ROOT=~/.claude/reviews` to preserve. The C13 `rev_01KPGJVT5DBEJXR5WHB5Z62PS3` evidence dir stays where it is under `~/.claude/reviews/` and is referenced by absolute path in the re-render command above.
- **Per-tuple writes in `--apply-decisions` means partial state on tuple-failure.** If tuple #N fails, tuples 0..N-1 are committed to disk. The error-as-prompt names the failing finding id so the caller can re-invoke with the remainder, but it does increase the orchestrator's cognitive load if a batch fails mid-way. Alternative (atomic-whole-batch) was considered in planning and rejected per the plan's intent. Revisit if Stage 3 shows the per-tuple-commit model causing audit-trail confusion.

### Stage 3 — `/adams-review-fix`

**Scope (target):** top-level `adams-review-fix.md`, leftover-`attempted` hard abort, clean-tree gate, staleness gate, Phase 8 fix-group agent dispatch with touched-file return, **9.pre overlap guard**, per-finding Phase 9 sub-agent, aggregation + per-group revert, commit SHA capture, **terminal cleanup** in the deterministic order (artifact records → push → publish → stash pop), error-recovery helper scripts.

**Done when:** full loop works. Mixed-outcome runs transition state correctly. Regression groups revert cleanly. Overlap abort leaves `current_state=attempted` and the next run's hard abort fires. Terminal cleanup ordering holds under push-fail and publish-fail.

**Status:** not started. Will plan after Stage 2 closes.

---

## Conventions

### Language split (rev 8)
- **Python** for JSON-heavy scripts: `artifact-patch.py`, `artifact-render.py`. Schema validation via `jsonschema`. Prefer stdlib + one dependency where possible.
- **Bash** for shell-glue scripts: `artifact-publish.sh`, error-as-prompt wrappers, any helper that's mostly `git` / `gh` calls.
- All scripts live at `~/.claude/commands/_shared/tools/` per DESIGN §9. Symlinked from this repo during development, or copied via install script at stage close-out (TBD — decide in Stage 1 planning).

### Commit cadence
Commit **inside** each stage at natural breakpoints (one per shared fragment, one per helper script, one per phase in Stage 2). Stage close-outs also commit `BUILD.md` updates. Don't batch into one giant stage-final commit.

Commit messages: imperative mood, reference DESIGN section where relevant (e.g., "Add artifact-patch.py with state-transition whitelist (DESIGN §5.2)").

### Stage flow
1. Draft stage plan in `plans/stage-N-name.md` (plan mode).
2. User reviews and approves.
3. Execute, committing regularly.
4. Update this file's stage section (Status, Files landed, Verification evidence, Open issues).
5. Compact session between stages.
6. Next session reads `BUILD.md` → `DESIGN.md` → relevant stage plan.

### Plan mode vs direct execution
Per user's CLAUDE.md: default is plan-mode-before-changes. For tactical mid-stage fixes (bug in a single script, typo, small refactor), direct execution is fine. For anything that touches stage scope or the design, re-enter plan mode.

---

## Adjusting the design as we build

**DESIGN.md is normative, not frozen.** Building always surfaces things the design didn't anticipate, got slightly wrong, or under-specified. Don't blindly follow a stage's design section if reality has shifted — but don't silently diverge either.

When a discrepancy comes up during a stage:

1. **Is it a clarification or a behavioral change?**
   - **Clarification** (design under-specified, you're filling in a detail that doesn't alter observable behavior — e.g., "DESIGN doesn't say what exit code `artifact-patch.py --dry-run` returns on invalid JSON; standardizing on 2"): update DESIGN inline as you make the call, note it in *Cross-stage notes* below with a one-line rationale. No approval round-trip needed.
   - **Behavioral change** (DESIGN says X, you now believe the right answer is Y — e.g., "§9.pre should also check files_modified vs files_created separately, not as a union"): stop, surface it to the user, agree on the change, then update DESIGN and proceed. Don't ship the divergence and leave DESIGN stale.

2. **Does it affect later stages?** After any DESIGN update, scan the unbuilt stages' scope. If a later stage depends on the thing you changed (e.g., Stage 3's terminal cleanup assumes a schema field Stage 1 ended up naming differently), add a line to that stage's section in the *Stage index* and/or append to *Cross-stage notes*. The goal: the next stage's plan draft should inherit these adjustments automatically, not rediscover them.

3. **When in doubt, check with the user.** Cheap to ask; expensive to ship a quiet divergence that surfaces as a bug two stages later. Err on the side of asking — especially for anything touching schemas, state transitions, file layout, or cross-command contracts.

Bias is toward **making DESIGN track reality**, not defending the rev-8 wording. If DESIGN and the code disagree at stage close-out, that's a defect to fix before compacting.

---

## Cross-stage notes

*Deviations from DESIGN, deferred items, things to revisit. Append as discovered.*

- **2026-04-17 — Python dep strategy changed from plain `pip install` to `uv` inline-script shebang (PEP 723).** Stage 1 plan §3 assumed plain pip would work. PEP 668 (Homebrew Python 3.12+) refuses direct pip installs, even with `--user`. Switched to `#!/usr/bin/env -S uv run --script` with `# /// script` inline dep spec; `uv` (already installed at `/opt/homebrew/bin/uv`) fetches `jsonschema` on first invocation and caches it. No venv, no activation. Behavioral deviation (affects shebangs and the runtime dep on every machine that runs these commands) — surfaced and approved before any Python script was written. README.md deps table updated. DESIGN doesn't prescribe a Python install mechanism, so no DESIGN change needed; this is a build-time implementation choice, not a design drift.

- **2026-04-17 — Exit-code clarifications for `artifact-patch.py` (DESIGN §21.2).** §21.2 only says "non-zero" on failure. Standardized in `_common.py`: `1=validation`, `2=invalid-transition`, `3=dry-run-invalid`, `4=unexpected`, `5=missing-dep`, `64=usage`. Clarification-level update per BUILD.md protocol. DESIGN §21.2 footnote is part of Stage 1 commit 17 (close-out) — not yet applied to DESIGN.md.

- **2026-04-17 — `artifact-validate.sh` uses a uv heredoc pattern, not a companion `.py`.** DESIGN §9.1 lists `artifact-validate.sh` only; no companion `.py`. Implemented as a Bash script that invokes Python via `uv run --with jsonschema python3 -` with an inline heredoc, importing `_common.py` via `PYTHONPATH`. Single file, matches §9.1. Same pattern available for any future thin Bash-fronted validator.

- **2026-04-17 — Bash scripts target portable Bash 3.2 features.** Shebang is `#!/usr/bin/env bash`, which resolves to macOS default `/bin/bash` (Bash 3.2, no associative arrays). `claude-md-paths.sh` used `declare -A` in its first draft and failed; rewrote to use `awk '!seen[$0]++' | sort` for dedup. Rule: avoid `declare -A`, `mapfile`, `readarray`, and `${var,,}` (lowercase) — they're all Bash 4+. `nameref` and process substitution ok; `set -euo pipefail` ok. Apply to all future Bash helpers across stages.

- **2026-04-17 — Detail-block auto-fixable row ordering by finding id.** `artifact-render.py` first iterated `DEEP_AUTO_FIX_DISPOSITIONS = (confirmed_auto, partial, regression, resolved)` in order, which put partials before resolveds inside the same Auto-fixable table. Changed to sort by finding id for stable natural order. Matches DESIGN §7's implicit natural ordering of F001→F002→F003 in the worked example. Not a DESIGN change; just a rendering decision.

- **2026-04-17 — Status-column behavior in Auto-fixable table.** DESIGN §7 says "the Auto-fixable table gains a Status column with `✓ verified` / `⚠ partial` / `✗ regression (reverted)`". Implemented: the column appears automatically when any row has a `fix_attempts` entry; it's absent pre-fix. Each cell shows outcome + short `output_sha` link or "(no commit)" for regression-reverted attempts. Matches §7 wording.

- **2026-04-17 — `--set` allowlists are explicit** (`SETTABLE_FINDING_FIELDS`, `SETTABLE_ARTIFACT_FIELDS` in `artifact-patch.py`). DESIGN §21.2 doesn't enumerate patchable fields; I chose an allowlist over a blocklist for safer error-as-prompt UX. Finding-level allowed: scalar enums, reason, confirmed_strength, score_phase3/4, introduced_in_sha, suggested_follow_up, related_parent_finding_id, plus the coupling triple (current_state, disposition, is_actionable). Top-level allowed: comment_id, trivial_mode, pr_state, pr_number. Arrays/objects and immutable fields (id, file, claim, sources, score_history, fix_attempts, validation_result, line_range) are rejected with a listing of allowed names. Stage 2 may need to add top-level `metrics` / `subagent_tokens` setters — will add a `--set-json` flag when that comes up, rather than overloading `--set`.

- **2026-04-17 — `--append-fix-attempt` combines with `--set` per DESIGN §26.** In one patch: `--set current_state=resolved --set disposition=resolved --append-fix-attempt '...'`. Order within the call is `--set` first (transitions + coupling checks run), then the attempt is appended. Cleaner than forcing two sequential `artifact-patch.py` invocations for every Phase 9 step.

- **2026-04-17 (close-out) — `artifact-publish.sh --md-path` is a Stage-1 extension.** DESIGN §21.6's signature is `--mode pr|local --review-id <id> [--pr <num>] [--comment-id <id>]` and assumes `latest.txt` resolution resolves the per-review dir. Stage 1 smoke tests need to avoid stubbing that resolver, so `--md-path <path>` was added. Stage 2's Phase 6 / orchestrator work should add the `latest.txt` fallback so `--md-path` becomes optional; the orchestrator-facing contract then matches §21.6 unchanged. Similarly `--review-dir <path>` is a testability extension for the trace.md appender.

- **2026-04-17 (close-out) — `staleness.sh` unreachable-SHA handling.** §21.4 specifies HEAD / changed-files intersection but doesn't say what to do when the reviewed SHA isn't in local history (shallow clone, force-push that discarded the SHA). Stage 1 chose: `git rev-parse --verify <sha>^{commit}` + `git merge-base --is-ancestor <sha> HEAD`; on failure exit 1 with a message explaining likely causes and action ("re-run /adams-review"). Treated same as unsafe — the safest default.

- **2026-04-17 (close-out) — DESIGN §21.2 exit codes codified.** Footnoted into DESIGN.md §21.2 in this commit: 0 success / 1 validation / 2 invalid-transition / 3 dry-run-invalid / 4 unexpected / 5 missing-dep / 64 usage. Also applies to `artifact-validate.sh` (0/1/64) and `artifact-render.py` (0/1/4/64). Observed during smoke: step 12 (`--set current_state=bogus --dry-run` on a finding in `resolved` terminal state) exits 2 (transition-check catches "bogus" as not in the empty allowed-next set for terminal states) rather than 1 or 3. The smoke assertion checks non-zero + unchanged sha, not a specific code — robust to this layering.

- **2026-04-17 — Stage 2 audit rounds 1 + 2 closed.** Two independent fresh-context audits flagged compounding issues: R1 `pr_state` uppercase-from-gh didn't match schema enum; R2 Phase 4 filter excluded `below_gate` findings but Phase 3 left gate-in candidates there too (the schema-required-non-null disposition forced reuse of `below_gate` as a parking state — a round-1 fix that round-2 caught as a Phase-4 no-op); R3 `validation_result` prompt shape mismatched the schema's nested-non-null objects; R4 empty `claude_md_paths` produced `[""]` via `jq -R`; R5 `evidence_snippet` candidate field survived into the finding write under `additionalProperties:false`; R6 `counts_by_state` phases.jsonl key was silently null because the helper emitted `counts_by_current_state`. All six + 8 of the 14 yellow flags fixed in round-2 commit(s); smoke grew from 29 to 33 assertions covering the new invariants. **Cleanest architectural change:** introducing `pending_validation` as a distinct §5.2.1 disposition enum value for Phase-3 gate-in findings, restoring Phase 4's dispatch set without overloading `below_gate`.

- **2026-04-18 — Orchestrator session context budget observation.** The C13 smoke's `subagent_tokens.total` was 978,924 (the 19 sub-agents), but the **orchestrator's own Claude Code session** used ~243,000 tokens of context by the time the run finished. That's a separate budget from `subagent_tokens` and is not tracked in the artifact. Implications for sizing: a 1M-context session has ~4x headroom at this diff size (43 files / 4270 lines / 33 findings) before the orchestrator risks context pressure. Larger diffs, `--ensemble` runs, or any phase that dumps large JSON back into orchestrator context (Phase 1 lens aggregation, Phase 2 dedup input, Phase 4 decision-table loop, Phase 5 xc_input_json) scale this number up. **Levers to keep it lower in future runs:**
   1. **Push more work into sub-agents that return only structured summaries** rather than full file contents. Phase 2 dedup currently reads `[.findings[] | {id, file, line_range, claim, source_families, sources}]` into orchestrator context — already trimmed. Phase 5's `xc_input_json` is the biggest offender (full `validation_result` per deep-lane finding, inlined into the Opus prompt AND loaded into orchestrator context to build the prompt). Consider having Phase 5's prep be done by a sub-agent that returns only the finding ids it recommends grouping, then the orchestrator fetches details.
   2. **Helper-script output truncation.** Some `artifact-read.sh --filter` results are consumed for decision-making only — orchestrator doesn't need to hold them after the branch is taken. Right now they live in conversation history.
   3. **Collapse the decision-table loop.** Phase 4.4 currently loops per-finding with per-finding prose. The loop output accumulates in context. A single `artifact-patch.py` invocation that consumes a JSON array of `{id, score, decision, actionability}` tuples and applies the table internally would eliminate the loop-chatter.
   4. **Trim fragment prose loaded via `!cat` preprocessor.** The 8 fragments together inline ~3k lines of markdown into the initial prompt. Most of that is one-time orientation for the orchestrator; after Phase 0 it's noise. Not directly fixable without changing the Claude Code slash-command model, but worth knowing.

   Not blocking for Stage 2; flag for Stage 3 planning since `/adams-review-fix` adds Phases 7–9 on top of Phases 0–6's artifact context load. If the fix command needs to re-read a fresh artifact from disk and run its own phases, context pressure compounds.

- **2026-04-18 — Claude Code sensitive-file gate fires on every write to `~/.claude/reviews/...`.** Observed during C13 real-repo smoke: every `printf >> trace.md`, every `artifact-patch.py --set*` write, every `log-phase.sh --record` invocation under the review dir prompted the user for permission ("Claude requested permissions to edit ... which is a sensitive file"). The `allowed-tools` grants at `adams-review.md` do NOT bypass this — Claude Code runs a separate sensitivity check on any file under `.claude/` regardless of tool-use grants. Mid-run workaround: user picked "Yes, and always allow access to `rev_<id>/` from this project" — scope-approves the rest of that run but does NOT persist to future review_ids (each run picks up a new `rev_` directory). **Fix options for Stage 3 planning:** (a) set `ADAMS_REVIEW_REVIEWS_ROOT` to a path outside `~/.claude/` (e.g. `~/adams-reviews`) — cleanest, but means DESIGN §9.1's "canonical layout under `~/.claude/reviews/`" becomes an opt-in default rather than a hard rule; (b) document a project-level `.claude/settings.json` additionalDirectories entry that whitelists the reviews root; (c) hope Claude Code grows a glob-pattern permission for reviews dirs. Option (a) is simplest and user-visible. Either way, the current Stage 2 shipping state leaks this UX issue onto the user — flag in release notes and likely resolve before Stage 3 ships.

- **2026-04-17 — Stage 2 audit rounds 3 + 4 closed.** Two more independent fresh-context audit rounds (Opus general-purpose + Codex CLI + CodeRabbit CLI in parallel, deduped) — each round found a single red flag that the previous rounds missed. **Round 3** caught two prose-level regressions that would have failed real runs: (a) Wave 2 `--add-finding` at 05-validation step 4.5 used singular `source_family` which the schema rejects under `additionalProperties:false`; (b) the sub-agent response wrapper for `validation_result` contains `{validation_result: ..., score_phase4, decision, ...}` but the orchestrator was feeding the whole envelope to `--set-json validation_result=@file` — every Phase-4 confirmed write would have hit the nested-object schema check. Round 3 fix: orchestrator extracts `.validation_result` with `jq -c '.validation_result // .'` before the write. **Round 4** caught the same wrapper-extraction bug in Phase 5's `cross_cutting_groups` write (same jq extraction applied), plus a subtler interaction: round-3's "score_phase4 beats decision when they disagree" precedence rule made the validation_result gate (keyed on `decision == "confirmed"`) wrong — a validator returning `{decision: disproven, score: 70}` would be routed to `confirmed_auto` by the table but skip the validation_result write. Round-4 fix: gate the write on the resolved disposition, not the raw decision label. Round 4 also added deterministic reconciliation rules to Phase-2 dedup (origin_confidence / validation_lane / actionability union by highest-rank-wins). Smoke grew 33 → 38 assertions. **Theme across rounds 2–4:** every red flag was prose ambiguity in the orchestrator fragments, not a schema or helper-script bug. The schema + helper surface was solid from Stage 1; the fragments needed three passes to reach consistent orchestrator-visible behavior. Recommendation from all three round-4 auditors: proceed with real-repo smoke.

- **2026-04-17 — §8.7 grant probe: PASSED.** Confirmed on macOS (`darwin 25.3.0`, Claude Code `default` mode): a frontmatter grant declared as `Bash(/Users/adammiller/.claude/commands/_shared/tools/probe.sh:*)` resolves cleanly when `~/.claude/commands/_shared` is a symlink to the dev repo — no permission prompt, script executed, stdout captured as expected. Verified in a separate Claude Code session invoking `/_shared-probe` (throwaway command + probe.sh). **Implication for Stage 2:** the full `/adams-review` `allowed-tools` block can use absolute paths under `~/.claude/commands/_shared/tools/...` per DESIGN §8.7's "canonical invocation path" rule; no need for the relative-name + `PATH` fallback. Probe files (`commands/_shared/tools/probe.sh` + `~/.claude/commands/_shared-probe.md`) torn down after verification; neither was committed.

- **2026-04-18 — Stage 2.5.A probe: `additionalDirectories` does NOT bypass the sensitive-file gate for `.claude/` paths. Resolution: branch (b) — relocate reviews root.** Probed via Claude Code permissions documentation (https://code.claude.com/docs/en/permissions.md) rather than a hands-on scratch session; the docs give a definitive and stronger answer. Key findings: (1) `additionalDirectories` extends *read/edit scope* but is explicitly "file access, not configuration" — it does not override path-specific sensitivity rules. (2) Writes to `.git`, `.claude`, `.vscode`, `.idea`, and `.husky` **still prompt for confirmation even in `bypassPermissions` mode**, the least-restrictive mode Claude Code offers; the `.claude/` gate is hardcoded in the permission layer, not config-driven. The documented exempt subdirs are `.claude/commands`, `.claude/agents`, `.claude/skills` — `~/.claude/reviews/` is not on that list. (3) Tilde expansion works in `additionalDirectories` paths; glob patterns do not. (4) No other settings key / env var / CLI flag grants persistent write permission to `~/.claude/reviews/**` that survives beyond the current session; `/permissions` "Yes, don't ask again" saves Allow rules but Edit-tool approvals reset on session end per the docs. **Decision:** flip default `$ADAMS_REVIEW_REVIEWS_ROOT` from `~/.claude/reviews` to `~/.adams-reviews` in Stage 2.5.A Commit 2. Leading-dot hidden state dir, outside `.claude/`, gate doesn't fire. DESIGN §9.1's "canonical layout under `~/.claude/reviews/`" becomes historical; the new canonical is `~/.adams-reviews/<slug>/<branch>/<review_id>/`. Users with pre-2.5 reviews migrate via `mv ~/.claude/reviews ~/.adams-reviews` OR override with `export ADAMS_REVIEW_REVIEWS_ROOT=~/.claude/reviews` (will continue to prompt, but their choice). No hands-on probe was run — the docs are authoritative and the hardcoded-gate answer is unambiguous; running an empirical probe would duplicate what the docs already state. Recorded here so Stage 3 doesn't re-ask the question.

- **2026-04-18 — Stage 2.5.B clarification: `--apply-decisions` and derivation authority.** The §13.1 Phase-4 table now lives in `artifact-patch.py`'s `_derive_phase4_disposition` (plus the `_ACTIONABILITY_TO_DISPOSITION` map and `CONFIRMED_BAND` set). The fragment at `05-validation.md` step 4.4 describes the tuple shape and calls the helper; it no longer encodes the table itself in prose. Authority stays in code, not in fragments — if the rule changes, it changes in one place. The helper's `decision` field is accepted but audit-only: derivation runs off `score_phase4 + actionability`, which implements the existing "score wins over decision when they disagree" rule automatically. `validation_result` is written only when the derived disposition lands in the confirmed band; disproven/uncertain tuples with a `validation_result` attached have it silently ignored (schema requires nested non-null, and those bands don't produce `fix_proposal` / `verification_context`). Per-tuple atomic writes with first-failure halt: caller re-invokes with the remainder after fixing the bad tuple, not the whole batch (score_history would re-append and pollute the audit trail).

- **2026-04-18 — Stage 2.5.C authoring disciplines for Stage 3.** Three principles captured from C13's orchestrator-context-budget observation (Note 1 Levers #1, #2, #4). Apply when drafting Phases 7–9:
  1. **Read for decisions, not for holding.** Prefer narrow `jq` filters that return a verdict (`.findings | length`, `.findings | map(.disposition) | unique`) over reading full records into orchestrator context when the orchestrator only needs a branch decision.
  2. **Delegate large-context synthesis to sub-agents** that return structured summaries (ids, group memberships, verdicts) rather than handing the full prompt+data to the orchestrator and emitting back prose.
  3. **Avoid per-finding loops in fragments when a single helper call can carry the same semantics.** Each loop iteration accumulates prose in orchestrator context; a batched helper invocation does not. Stage 2.5.B's `--apply-decisions` is the first instance; `group-fixes.py` in Stage 3 Phase 8 and the per-group Phase 9 result aggregation are candidates for the same pattern.

  Not enforced by tooling — authoring disciplines only. Stage 3 planning should apply them from the start rather than retrofitting mid-stage.

- **2026-04-18 — Stage 2.5.D renderer fix: light-lane `uncertain` was silently dropped from PR comments.** `artifact-render.py` lines 148 (summary) and 323 (table) iterated only `(confirmed_auto, confirmed_manual, confirmed_report)` for the light lane; DESIGN §13.1 Phase-4 "score 45-59 → uncertain" applies regardless of lane, so light-lane findings with `disposition: uncertain` were present in `artifact.json` but invisible in the rendered `artifact.md`. `findings_count` still counted them in the "Found N findings" total (the buckets iteration at render_summary line 133 sums all dispositions), producing a subtle count mismatch: "Found 6 findings" but only 5 enumerated per-section. **Real-world impact.** C13's ray-finance `feat/import-apple` run had three light-lane uncertain findings (F021 `src/cli/ink/mount.ts:11-13`, F022 `src/cli/ink/ChatApp.tsx:108-116`, F032 `src/cli/commands.ts:808-812`) that were present in the artifact but silently missing from PR comment `4274059620` — exactly the findings the user most needs to decide on manually. **Fix.** Two-tuple-literal edit adding `"uncertain"` to both iteration tuples; `render_light_lane()`'s existing single-table-with-Disposition-column shape accommodates mixed dispositions with no structural change. Re-rendering the C13 artifact locally now surfaces all three findings in the Light lane table. **Defence in depth.** Fixture seed extended with F006 (architecture/uncertain/light) so the existing `diff expected.md` assertion (step 9) would surface any regression; added a belt-and-suspenders smoke assertion Y grepping for F006 in the rendered output with a clear "light uncertain dropped" signal. **Adjacent rendering quirk.** `render_summary()` still counts `below_gate` in the "Found N findings" total but doesn't list it per-lane (no section displays sub-threshold findings, so they exist in the artifact for debuggability but don't surface). That's intentional per the Stage 1 close-out note; this Stage 2.5.D fix is orthogonal and does not touch `below_gate` handling.

---

## Handoff protocol — what to update at stage close-out

When a stage completes, before the user compacts:

1. **Current state** section at the top: update date, current stage, next action.
2. **Stage index table**: flip status for the completed stage, update close-out notes link.
3. **Completed stage's section**: fill in *Files landed*, *Verification evidence*, *Open issues / deviations*.
4. **Cross-stage notes**: append anything worth remembering across stages (e.g., a DESIGN ambiguity that we resolved one way, and the rationale).
5. Commit the `BUILD.md` update in its own commit before compacting.

The user will typically compact after step 5. The next session uses this file + `DESIGN.md` + the next stage's plan as its starting context.
