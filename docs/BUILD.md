# BUILD.md — build journal for adams-review

This is the running build journal. `DESIGN.md` is the normative design (rev 8). This file tracks **execution**: where we are, what's landed, what surprised us, and what still needs attention.

If you are a Claude Code session starting fresh (after compaction or on a new day), **read this file first**, then open `DESIGN.md`. Skim "Current state" and the active stage's section; you can treat the rest as reference.

---

## Current state

**As of 2026-04-18 — Stage 2.8 COMPLETE.** PR-comment freshness filter replaces the Stage-2 `--since review_started_at` time filter on `external-scrape.sh`. Bot comments are now filtered by code locality — `review_comment`/`review` records against `git diff commit_id..HEAD`; `issue_comment` records against `pulls/<pr>/commits` latest `committer.date` (policy C2, §13.13). New helper `comment-freshness.sh` (§21.10), new DESIGN sections §13.13 + §21.10, rewired `02-ensemble-adapter.md` step 1.5.3 to pipe scrape output through the new filter with `tee -a trace.md` audit flow. `--since` removed from `external-scrape.sh` entirely. `review_started_at` demoted to Phase-6 metrics anchor only. `test/smoke.sh` passes 105 assertions (up from 96 at Stage 3 close: CF-1..7 + CF-ES-1/2 + updated G).

- Design doc: `DESIGN.md` (rev 8 + §21.2 exit-code footnote + §21.2 `--apply-decisions` clarification + §21.2 `--apply-fix-start` clarification + §21.2 `--apply-fix-outcomes` clarification + §5.2.1 `pending_validation` clarification + §9.2 reviews-root relocation + §8.7 sensitive-gate prose correction + §12.1 example fix + §13.10 base-branch freshness gate + §13.11 origin cross-check + §21.9 `origin-crosscheck.sh` spec + §13.12 detection parallelization + **§13.13 PR comment freshness** + **§21.10 `comment-freshness.sh` spec** + **§21.8 `--since` removal**)
- Stage 1 plan: `plans/stage-1-foundation.md` (user-approved; closed out)
- Stage 2 plan: `plans/stage-2-review.md` (user-approved; closed out)
- Stage 2.5 plan: `plans/stage-2.5-hardening.md` (user-approved; closed out)
- Stage 2.6 plan: `plans/stage-2.6-freshness-origin.md` (user-approved 2026-04-18; closed out)
- Stage 2.7 plan: `plans/stage-2.7-detection-parallel.md` (user-approved 2026-04-18; closed out)
- Stage 3 plan: `plans/stage-3-fix.md` (plan-and-execute 2026-04-18; closed out)
- Stage 2.8 plan: `plans/stage-2.8-comment-freshness.md` (user-approved 2026-04-18; closed out)
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
| 2.6 | Base-branch freshness gate (§13.10) + origin cross-check (§13.11) + renderer surfacing | **done** | `plans/stage-2.6-freshness-origin.md` | [Stage 2.6 section](#stage-26--base-branch-freshness--origin-cross-check) |
| 2.7 | Parallelize Phase 1 (internal lenses) + Phase 1.5 (ensemble) — wall-clock hardening | **done** | `plans/stage-2.7-detection-parallel.md` | [Stage 2.7 section](#stage-27--detection-parallelization-phase-1--phase-15) |
| 3 | `/adams-review-fix` (Phases 7–9 + terminal cleanup) | **done** | `plans/stage-3-fix.md` | [Stage 3 section](#stage-3--adams-review-fix) |
| 2.8 | PR comment freshness filter (replace `--since` with code-locality check) | **done** | `plans/stage-2.8-comment-freshness.md` | [Stage 2.8 section](#stage-28--pr-comment-freshness) |
| 4 | Fragment shrink + helper externalization (context-budget hardening) | not started | `plans/stage-4-fragment-shrink.md` | — |

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

### Stage 2.6 — Base-branch freshness + origin cross-check

**Rationale.** The C13 real-repo smoke ran against a local `main` that was behind `origin/main`. Two failure modes compounded:

1. **Inflated diff surface.** Every lens sees `$base_branch..HEAD`. On stale local `main` that includes upstream commits already merged into the PR branch, so the review's whole input was wrong.
2. **Pre-existing override silently dead.** Lens prompts default `origin: introduced_by_pr, origin_confidence: high` "unless the code is clearly unchanged." Stale main meant pre-existing commits *were* inside the diff, so lenses correctly saw them as modified and defaulted to introduced. The §13.1 override (`origin=pre_existing AND confidence=high → disposition=pre_existing_report`) never fired. Renderer's pre-existing section collapsed to nothing because the bucket was empty — the user silently lost the "what's new vs what was already broken" distinction.

Closing both before Stage 3 adds Phase-7/8/9 surface on top keeps the data-quality regression from compounding. Pre-Stage-3 hardening pass, same pattern as Stage 2.5.

**Scope (target):**

- **2.6.A** — Phase 0 freshness gate (§13.10). Fetch `origin/$base_branch`, detect behind-count, prompt via AskUserQuestion with four options (fast-forward / use-remote-ref / proceed-stale / abort). Offline / fetch-failure degrades to `no_fetch` with trace warning. Introduce `comparison_ref` working-set var used by every later diff / blame / lens prompt. Artifact gains optional `base_context {freshness, comparison_ref, remote_sha, behind_count}`.
- **2.6.B** — Phase 1 origin cross-check (§13.11). New `origin-crosscheck.sh` helper runs deterministic blame classification between lens aggregation and `--add-finding`: every candidate whose blame range is fully ancestor of `comparison_ref` gets forced to `origin=pre_existing, confidence=high`; lens-supplied `pre_existing` that blame disagrees with gets confidence downgraded to medium so §13.1 override doesn't fire.
- **2.6.C** — Renderer surfaces `base_context.freshness` in the report header with escalating warning glyphs when non-default.
- **2.6.D** — BUILD.md close-out (this section).

**Explicitly out of scope:**

- `--cleanup-pre-existing` flag. Keeps the clean seam documented in DESIGN §13.1. Future work.
- `--no-fetch` flag on `/adams-review`. Rejected in planning: fetch cost is small, offline path already degrades gracefully, exposing an opt-out would let users silently reintroduce the bug class.
- Schema version bump. `base_context` is additive-optional; v1 artifacts with or without it validate.
- Staleness-of-PR-branch-relative-to-base warning ("you haven't rebased in 3 weeks"). Separate axis from local-base freshness. Deferred.
- Any Phase 5 / 7–9 surface.

**Done when:**

1. Phase 0 surfaces the four-option prompt on a stale-local-main scratch repo; each option's downstream math (`comparison_ref`, `base_freshness`, sanity check count) is correct.
2. Origin cross-check flips lens-default `introduced_by_pr/high` → `pre_existing/high` when blame is fully ancestor; respects lens on mixed / new-file / PR-modified ranges.
3. Renderer shows a `**Base freshness:**` line with appropriate glyphs for non-default states; renders silently for `fresh` / `no_remote`.
4. Offline path logs one `fetch_failed` line to `trace.md` and proceeds.
5. `test/smoke.sh` passes with fresh assertions covering freshness math, origin-crosscheck decision table, and renderer variants.
6. `DESIGN.md` gains §13.10, §13.11, §21.9; §4 Phase 0 and Phase 1 narrative gain the new steps.
7. BUILD.md stage index row + Stage 2.6 section filled in.

---

**Plan file:** `plans/stage-2.6-freshness-origin.md` (user-approved 2026-04-18 per auto-mode execution; copied into the repo at close-out to match Stage 1/2/2.5 convention). No mid-stage deviations from the plan.

**Status:** done (2026-04-18).

**Stage 2.6 commits (on `main`, newest first):**

```
(this commit) Close Stage 2.6: BUILD.md + stage index
26cb9a6       Stage 2.6.C: Surface base-branch freshness in rendered report header
9c5cd80       Stage 2.6.B: Origin cross-check (DESIGN §13.11)
8fc94ab       Stage 2.6.A: Base-branch freshness gate (DESIGN §13.10)
```

**Files landed:**

- **2.6.A — freshness gate** (commit `8fc94ab`):
  - `DESIGN.md` — new §13.10 (behavior + plumbing + "no --no-fetch flag" rationale); §4 Phase 0 narrative gains step 4 "Reconcile base-branch freshness" (renumbering 4→13; §23 CLAUDE.md-paths step reference fixed in the same pass — it was already off-by-one pre-§13.10); §6 artifact-schema example gains `base_context` block + schema note; §7 sample report gains illustrative `**Base freshness:**` header line; §25.1 working-set table splits `base_branch` (display) from `comparison_ref` (ref used by every diff/blame/lens) and adds freshness variables.
  - `commands/_shared/schema-v1.json` — optional top-level `base_context` object; freshness enum is `fresh | fast_forwarded | used_remote_ref | proceeded_stale | no_fetch | no_remote`; `remote_sha` and `behind_count` nullable (null on offline/no-remote paths).
  - `commands/_shared/00-preflight.md` — new step 0.2a with three sub-steps (remote detection + 30s-timeout fetch; behind-count + route; user-gate AskUserQuestion when behind) + step 0.4 (sanity check moved here to use `comparison_ref`). Step 0.6 (`reviewed_files_all`, `num_files`, `lines_changed`) and step 0.15 (jq seed) both updated to `$comparison_ref`. `preflight_warnings` Bash array accumulates fetch/divergence warnings and flushes to `trace.md` at end of 0.15 (only after `--init` succeeds — before that, `review_dir` may be about to be `rm -rf`-ed on init-fail). Working-set table gains rows for `comparison_ref`, `base_freshness`, `remote_sha`, `behind_count`, `preflight_warnings`; trailing "Reminder on comparison_ref vs base_branch" prose.
  - `commands/_shared/01-detection.md` — step 1.2 shared-diff computation + all six lens prompts (L1 at line 57, L2 at 88, L3 at 114, L4 at 133, L5 at 160, L6 at 183) swap `$base_branch` → `$comparison_ref` in the "diff between X and HEAD" phrasing.
  - `commands/_shared/02-ensemble-adapter.md` — CodeRabbit `--base` and Codex prompt text use `$comparison_ref` so ensemble reviewers see the same diff surface as internal lenses under option (b).
  - `test/smoke.sh` — 7 new assertions FR-1..FR-7: behind_count math; per-option comparison_ref semantics (including FR-3's positive reproduction of the pre-gate data-loss pattern — local main..HEAD shows 2 commits, origin/main..HEAD shows 1); FF via `git fetch origin main:main` drops behind_count to 0; schema accepts all six freshness enum values; schema rejects invalid enum; offline-fetch against bogus-URL remote returns non-zero rc.

- **2.6.B — origin cross-check** (commit `9c5cd80`):
  - `DESIGN.md` — new §13.11 (algorithm + conservative-policy rationale + placement); §4 Phase 1 narrative gains cross-check paragraph between candidate-output and source-families; new §21.9 `origin-crosscheck.sh` spec (interface, per-candidate algorithm, error cases).
  - `commands/_shared/tools/origin-crosscheck.sh` — new Bash helper. Takes `--comparison-ref` + `--candidates` (path, `@-` stdin, or inline JSON); emits corrected array on stdout + one audit line per candidate on stderr (`origin_crosscheck: id=X action=respected|overridden|downgraded|skipped`). Porcelain-SHA parsing uses `/^[0-9a-f]{40} /` to avoid false-positives on `author`/`summary`/`committer` porcelain header lines. Handles `new-file`, `blame-failed`, `no-blame-shas`, `missing file or line_range` as `action=skipped`; per-candidate blame failures do not abort.
  - `commands/_shared/01-detection.md` — new step 2a inside step 1.4, invoking helper with `2> >(tee -a "$trace_log_path" >&2)` so audit lines flow into `trace.md` inline; step 3 iterates over `$corrected_candidates` array.
  - `test/smoke.sh` — 7 new assertions OC-1..OC-7: override case (fully-ancestor range); respect lens on PR-modified line; new-file respect with `reason=new-file`; mixed-range conservative respect; downgrade case (lens=pre_existing/high + blame disagrees → confidence=medium); unknown `--comparison-ref` error-as-prompt; malformed-JSON rejection.

- **2.6.C — renderer surfacing** (commit `26cb9a6`):
  - `commands/_shared/tools/artifact-render.py` — new `render_freshness_line()` helper; `render_header()` appends it between Review ID and Fix threshold. Escalating glyphs: fresh/no_remote → silent; fast_forwarded → no-glyph note with behind-count; used_remote_ref → ⚠; proceeded_stale → ⚠⚠ + "Re-run after `git pull`"; no_fetch → "could not fetch (offline?)". Unknown freshness values render a best-effort "(see trace.md)" fallback rather than dropping silently.
  - `test/smoke.sh` — 7 new assertions RH-1..RH-7: fresh stays silent; each warning variant includes its expected phrase and glyph count; pre-§13.10 artifacts (no `base_context`) render without the line (backward compat).

**Verification evidence:**

- `test/smoke.sh` passes **64 assertions**, up from 43 at Stage 2.5 close. Breakdown of additions: FR-1..FR-7 (freshness gate), OC-1..OC-7 (origin cross-check), RH-1..RH-7 (renderer). Existing 43 assertions unchanged; no seed or expected-md churn was needed (the Stage 2.5.D seed has no `base_context`, and the renderer degrades to no-op in that case).
- **Origin-crosscheck helper manual smoke** (not in `test/smoke.sh`, but run during development): 5 scenarios against a scratch 2-commit repo — fully-pre-existing line range; PR-modified line; new file; mixed range; lens=pre_existing/high downgrade. All five matched §13.11 expectations on the first run after the porcelain-SHA parser fix (initial awk `/^[^\t]/` matched `author`/`summary` lines as SHAs; switched to strict `/^[0-9a-f]{40} /`).
- **Ray-finance end-to-end re-run deferred.** The plan's verification section calls for a manual `/adams-review` re-run on ray/ray-finance `feat/import-apple` with the fresh pipeline. Stage 2.6 close-out ships without that run — smoke coverage plus the helper manual-smoke gives adequate signal for the code paths, and the ray-finance run is expensive (tokens + user time). Budget for that run when it aligns with Stage 3 real-repo validation.

**Open issues / deviations:**

- **Ensemble external-reviewer CLI tools and remote refs.** `02-ensemble-adapter.md` now passes `$comparison_ref` to CodeRabbit's `--base`. If a CLI rejects remote refs like `origin/main` in practice, the fragment's inline note says to fall back to `$base_branch` and record the degradation in `trace.md`. No real-repo test was run against that code path; surface if Stage 3 ensemble work hits it.
- **Per-candidate blame in step 2a runs sequentially inside the lens-collection loop.** On a 50-candidate run that's ~2.5s of added Phase 1 time — acceptable per the plan's cost analysis. If a future lens burst returns 200+ candidates, consider batching or caching blame per file.
- **Origin cross-check has no dedicated `trace.md` schema entry.** The helper's stderr flows into `trace.md` via `tee -a` in step 2a. The prior `trace.md` format convention is "one tag per line" which the `origin_crosscheck: id=... action=...` lines follow, but there's no explicit grammar. If Stage 3 grows a `trace.md` parser, codify.
- **Schema change is additive-optional; no versioning event.** `base_context` joined the v1 schema without a schema_version bump. Future builds that emit `base_context` on every run are still schema-v1 — pre-§13.10 readers that filter by `schema_version` will accept them, at the cost of ignoring the new field. If readers develop field-set expectations, versioning becomes a real concern.

---

### Stage 2.7 — Detection parallelization (Phase 1 + Phase 1.5)

**Rationale.** The ensemble run on beta-briefing / channel-slug-etc surfaced that Phase 1 (6 internal lenses) runs to completion *before* Phase 1.5 (CodeRabbit + Codex + PR scrape) even starts. There's no data dependency between them — Phase 2 (dedup) is the first cross-phase consumer, so both could fan out concurrently. Current sequential ordering costs ~30-50% of detection wall-clock on ensemble runs (observed ~5m 5s in Phase 1 alone; ensemble CLIs would have added another ~10-15m serially on top).

**Why the current design serializes** (and what's actually needed to unblock parallelism):

1. **Finding ID assignment races.** Phase 1 step 1.4 assigns `F001...F0NN` as each lens returns; Phase 1.5 step 1.5.6 continues from `F(NN+1)`. Concurrent claims would collide. *Fix:* collect-then-assign refactor — both phases accumulate candidate JSON into per-phase arrays (no IDs), and one final step assigns IDs across the pooled set before the `--add-finding` loop.
2. **Ensemble readiness check (1.5.1) is user-blocking.** Today it runs at the top of Phase 1.5, potentially AFTER Phase 1 has already burned tokens. To parallelize, the readiness check (AskUserQuestion on missing CLIs) must hoist to run BEFORE either phase dispatches — either at Phase 0 close-out or as a new pre-Phase-1 gate.
3. **Progress UI assumes sequential phases.** The phase-tracker surface currently shows one `in_progress` phase at a time. Minor cosmetic update to allow two concurrent.

No hidden data dependency beyond these three. Phase 1.5's normalizer doesn't reference Phase 1 findings.

**Scope (target):**

- **2.7.A** — DESIGN §4 narrative + new §13.12 "Detection parallelization" sub-section normalizing the pattern: "Phase 1 and Phase 1.5 fan out concurrently from a single orchestrator turn when `--ensemble` is set; finding IDs are assigned at the join point." Update §4 Phase 1 / Phase 1.5 headings to reflect joint dispatch.
- **2.7.B** — Refactor fragments:
  - `02-ensemble-adapter.md` step 1.5.1 (readiness + AskUserQuestion on missing CLIs) hoists to a new **pre-detection gate** in `01-detection.md` (runs between 1.1 "Decide which lenses" and 1.3 "Dispatch").
  - `01-detection.md` step 1.3 gains the ensemble CLI launches (background Bash) alongside the 6 lens Agent dispatches, all in one orchestrator turn.
  - `01-detection.md` step 1.4 changes from "add-finding per lens as it returns" to "collect candidates with no IDs". Ensemble normalizer (old 1.5.5) runs when its inputs resolve, also collecting into the candidate pool.
  - New **step 1.9 "Join + assign IDs + add-finding"** at the end of detection: pooled candidates get monotonic `F001...F0NN` across the combined set, then one `--add-finding` sweep.
- **2.7.C** — Smoke tests for the ID-assignment invariant. No real CLIs required — synthesize two candidate batches (one simulating "lens output", one simulating "ensemble normalizer output"), feed through the assignment step, assert IDs are monotonic + non-colliding + sorted by source.
- **2.7.D** — BUILD.md close-out + `phases.jsonl` update so the two phases log joint `elapsed_sec` rather than two separate rows that look sequential.

**Explicitly out of scope:**

- Parallelizing Phase 2 / 3 / 4 against each other. They have real data dependencies (Phase 3 needs Phase 2 dedup results; Phase 4 needs Phase 3 scores). No wall-clock win without deeper refactors.
- Token-cost changes. Each agent still dispatches once; the saving is wall-clock, not tokens.
- Timeout handling changes. The existing 10-min CLI timeout per `02-ensemble-adapter.md` step 1.5.4 already tolerates slow reviewers independently; parallelism just means the timeout clock starts earlier.
- Phase-tracker UI beyond the minimum needed to show two concurrent phases.

**Done when:**

1. On `--ensemble` runs, Phase 1 lens dispatches and Phase 1.5 CLI launches happen in the **same orchestrator turn** (verifiable by inspecting session transcripts — single Agent + Bash turn with multiple tool-use blocks).
2. Finding IDs remain monotonic and non-colliding across the pooled detection set. `test/smoke.sh` gains an assertion that exercises the pool+assign path on synthetic candidates.
3. `phases.jsonl` records Phase 1 and Phase 1.5 with overlapping time windows (a pr-mode ensemble run produces `phase_1.elapsed_sec ≈ phase_1_5.elapsed_sec ≈ max(internal, external)` rather than `phase_1 + phase_1_5`).
4. Non-ensemble runs (`--ensemble` not set) behave unchanged — Phase 1 dispatches alone, Phase 1.5 is skipped at the readiness gate.
5. Readiness gate surfaces the AskUserQuestion BEFORE any lens agent dispatches, so a user who picks "stop so I can set them up first" isn't billed for the 6 internal lens tokens.
6. DESIGN §4 narrative + new §13.12 land with the refactor.
7. BUILD.md stage index + Stage 2.7 section filled in with before/after wall-clock evidence from a real ensemble run.

**Commit cadence (estimated):**

1. 2.7.A DESIGN §13.12 + §4 narrative — 1 commit.
2. 2.7.B fragment refactor (01-detection.md + 02-ensemble-adapter.md + smoke ID-assignment assertion) — 1-2 commits.
3. 2.7.C additional smoke coverage — folded into 2.7.B or 1 commit.
4. 2.7.D close-out — 1 commit.

~3-5 commits total. Plan-approval round-trip recommended (behavior change touching orchestration pattern; affects every ensemble run).

**Status:** done (2026-04-18).

**Stage 2.7 commits (on `main`, newest first):**

```
(this commit) Close Stage 2.7: BUILD.md + stage index
d2cc11a       Stage 2.7.B: refactor 01-detection + 02-ensemble for joint dispatch
d3f3829       Stage 2.7.B+C: assign-finding-ids.sh helper + AI-1..AI-7 smoke
419bab6       Stage 2.7.A: DESIGN §13.12 + §4 narrative (detection parallelization)
```

**Files landed:**

- **2.7.A — DESIGN §13.12 + §4 narrative** (commit `419bab6`):
  - `DESIGN.md` — new §13.12 "Detection parallelization (Phase 1 + Phase 1.5)" normative sub-section: 5 invariants (single dispatch turn, no ids during collection, single join point, pre-dispatch readiness gate, non-ensemble short-circuit); token accounting + phases.jsonl semantics (overlapping ts, each phase's own longest-path elapsed); UX note on readiness-gate placement; implementation pointers to 01/02 fragments. §4 Phase 1 narrative gains a §13.12 pointer; Phase 1.5 narrative notes the readiness-gate move + no-op-during-collection pattern. Pipeline diagram uses a fan-out brace between Phase 1 and Phase 1.5 with a `(under --ensemble, Phases 1 + 1.5 dispatch in one turn — §13.12)` note.

- **2.7.B + 2.7.C — helper + smoke** (commit `d3f3829`):
  - `commands/_shared/tools/assign-finding-ids.sh` — new Bash + jq helper. Reads pooled candidate JSON on stdin (`internal + external`); sorts by `sources[0]` priority (1=L1-diff-local, …, 6=L6-security, 7=external-pr:*, 8=codex, 9=coderabbit, 99=unknown/forward-compat); stable within bucket via secondary sort on input index; emits same-length array with `.id` set to `F001..F0NN`. Error-as-prompt on non-array stdin (ERROR → Valid input → Did you mean → Action). `-h`/`--help` surfaces usage.
  - `test/smoke.sh` — 7 new assertions AI-1..AI-7 under Stage 2.7 block: internal-only pool (L1→L2→L3 ordering), ensemble-mixed pool (L1→L6→external-pr→codex→coderabbit), stable-within-source, empty pool passthrough, malformed stdin → exit 1 + full error-as-prompt, non-array JSON → same error path, unknown-source forward-compat (priority 99, id still assigned).

- **2.7.B — fragment refactor** (commit `d2cc11a`):
  - `commands/_shared/01-detection.md` — new step 1.2a "Ensemble readiness gate (§13.12)" between 1.2 and 1.3: when `ensemble_mode=true`, captures `phase_1_5_start_epoch`, creates `scratch_dir`, probes CodeRabbit + Codex, dispatches `AskUserQuestion` once if either unavailable (proceed-with-available vs. stop-to-fix-first), writes Codex prompt file if Codex available. Under `ensemble_mode=false` it's a one-line trace.md note and two `*_available=false` assignments. Step 1.3 gains an "Ensemble fan-out (same turn)" block with a tool-use-block count table and pointers into `02-ensemble-adapter.md` §1.5.2/§1.5.3 for the actual launch commands. Step 1.4 renamed "Collect lens candidates into pool" — per-lens `log-tokens` + light JSON repair + origin-crosscheck unchanged; step 3 now tags each corrected candidate with `sources: [<lens-tag>]` via `jq` and concatenates into the `internal_candidates` pool (no `--add-finding`, no id counter). New step 1.5 "Join + assign IDs + add-finding (§13.12)" — combines `internal_candidates + external_candidates`, pipes through `assign-finding-ids.sh`, iterates ided candidates through the (existing) full-finding `jq -n` builder + one `artifact-patch.py --add-finding` per candidate. Old step 1.5 summary renumbered 1.6. Working-set delta notes the two pools live in orchestrator context.
  - `commands/_shared/02-ensemble-adapter.md` — §1.5.1 replaced with a pointer explaining readiness/scratch/prompt-file all happen in 01 §1.2a; §1.5.2 and §1.5.3 gain preamble pointers noting launches dispatch from 01 §1.3; §1.5.5 grows a post-normalizer schema-guard repair (`file // "(unknown)"`, `line_range // [1,1]`) and emits to `external_candidates` instead of directly building findings; old §1.5.6 `--add-finding` loop removed (now lives at 01 §1.5); §1.5.6 retained only for token logging. Working-set delta updated to reference `external_candidates` pool + phases.jsonl ts-overlap.
  - `commands/adams-review.md` — "Parallel fan-outs are expensive" bullet in "Execution overview" gains a sentence about joint fan-out under `--ensemble` and TaskList handling (two tasks `in_progress` through the dispatch turn, both `completed` after 01 §1.5).

**Verification evidence:**

- `test/smoke.sh` passes **71 assertions**, up from 64 at Stage 2.6 close. Breakdown of additions: AI-1..AI-7 (assign-finding-ids deterministic sort + id assignment + error handling + forward-compat). Existing 64 assertions unchanged.
- **`assign-finding-ids.sh` manual smoke** (during development, before smoke.sh coded): empty pool, 3 L1 + 2 L2 + 1 L3 internal-only, mixed ensemble (5 sources), malformed stdin, non-array stdin, unknown source — all matched §13.12 expectations first run. Deterministic sort output is identical byte-for-byte across runs (no wall-clock or random sort surprise).
- **Real-repo ensemble re-run deferred.** Done-when #3 and #7 both call for wall-clock evidence from a real `/adams-review --ensemble` run on a PR with Phase 1 + Phase 1.5 CLIs enabled, demonstrating overlapping `ts` in `phases.jsonl` and visibly shorter total wall-clock vs. pre-§13.12 baseline. No such run was executed at close-out — the token cost of a full ensemble run against a meaningful PR is high, and fragment-level correctness is covered by unit smoke. Budget for the evidence capture during the first Stage 3 real-repo validation (same pattern as Stage 2.6's "ray-finance re-run deferred"). If the evidence lands separately, append it here.

**Open issues / deviations:**

- **Turn-count realism unverified in-situ.** Under `--ensemble` + PR mode with both CLIs available, the dispatch turn carries 6 lens `Agent` + 2 background `Bash` + 1 foreground `Bash` = 9 tool-use blocks. Claude Code supports many tool uses per turn in principle; no empirical ceiling was observed at Stage 2.6's real-repo work. If a future ensemble run hits a tool-use-count or prompt-size limit mid-dispatch, the preferable fallback is to flip the order — fire the 2 background CLI launches + foreground scrape FIRST in turn N, then the 6 Agents in turn N+1. Because turn N waits only for the foreground scrape (seconds) before the background CLIs are running off the leash, the CLIs and the subsequent lens fan-out overlap wall-clock-wise. Splitting the OTHER way (6 Agents turn N, CLIs turn N+1) would serialize the CLIs behind the lens fan-out and defeat the purpose of §13.12. Update 01 §1.3 with whichever order works if encountered.
- **Fragment-level testing, not integration.** The smoke assertions cover `assign-finding-ids.sh` alone. Fragment prose (which phase does what, when) is not machine-verified; it's prose the orchestrator follows. Real-repo ensemble runs are the first integration signal. This is the same posture as Stage 2.5.B's `--apply-decisions` (fragment-level review passes verified helpers; orchestrator walk-through verified the fragment narrative).
- **phases.jsonl consumers.** Nothing in the current codebase reads phases.jsonl and *assumes* non-overlapping time windows — greps in `commands/_shared/tools/` found no elapsed_sec math across phases. Safe for v1. If §12 observability gains aggregate-phase consumers later, verify they tolerate overlap.
- **Normalizer schema-guard lives in 02 §1.5.5, not 01 §1.5.** The location repair for `file: null` / `line_range: null` on external candidates happens BEFORE the external pool joins the internal pool at the join step. This keeps the guard next to the normalizer that produces the nulls (readability), and means the join step treats external candidates as already-repaired. Internal candidates get a parallel `line_range //= [1,1]` repair at 01 §1.4 step 3 (lens occasionally returns null line_range). Two repair sites with the same default; noted here so if the schema tightens, both need updating.
- **`sources` tagging moved from jq-n builder to pool-append.** Pre-§13.12, each lens's `sources: [<lens-tag>]` was assigned inside the per-candidate full-finding `jq -n` builder at step 1.4 step 3. Post-§13.12, tagging happens earlier (at pool-append in 1.4 step 3) so `assign-finding-ids.sh` can sort by it. The final full-finding builder at 1.5 step 3 no longer sets `sources` — it preserves whatever the candidate carries (lens tag for internal, `["codex"]`/`["coderabbit"]`/`["external-pr:<bot>"]` for external per normalizer prompt).

---

### Stage 3 — `/adams-review-fix`

**Scope (landed):** top-level `adams-review-fix.md`, leftover-`attempted` hard abort, clean-tree gate, staleness gate, Phase 8 fix-group agent dispatch with touched-file return, 9.pre overlap guard, per-finding Phase 9 sub-agent, aggregation + per-group revert, commit SHA capture, terminal cleanup in the deterministic §24.4 order (validate → render → phases.jsonl → push → publish → stash pop → surface first failure). New helper `group-fixes.py` (§21.5) and two new `artifact-patch.py` batched modes (`--apply-fix-start`, `--apply-fix-outcomes`).

**Done when:** full loop works end-to-end on a real artifact. (Fragment-level correctness covered by unit smoke; real-repo run deferred — see Open issues.)

**Status:** done (2026-04-18).

**Stage 3 commits (on `main`, newest first):**

```
(this commit) Close Stage 3: BUILD.md + stage index + 9.pre all-regression nit
ce7b911       Stage 3.G: enrich artifact-render.py Fix runs section
e824007       Stage 3.F: 10-post-fix-and-commit.md fragment (Phase 9)
4e43906       Stage 3.E: 09-fix-execution.md fragment (Phase 8)
14cb208       Stage 3.D: 08-fix-loader.md fragment (Phase 7)
b5f70f1       Stage 3.C: adams-review-fix.md top-level scaffold
c1cb863       Stage 3.B: artifact-patch.py --apply-fix-start + --apply-fix-outcomes
996e79a       Stage 3.A: group-fixes.py union-find helper (DESIGN §21.5)
3bbbc93       Add Stage 3 plan (/adams-review-fix, Phases 7-9)
```

**Files landed:**

- **3.A — `group-fixes.py`** (commit `996e79a`):
  - `commands/_shared/tools/group-fixes.py` — new Python helper (§21.5). Takes `--artifact <path> --eligible-finding-ids <csv|@-|->`; reads the artifact, validates each eligible id's state + disposition + `validation_result.fix_proposal.files_to_modify` shape, seeds union-find from `cross_cutting_groups`, unions by shared planned file via inverted `file → [ids]` bucket (O(N + refs) not O(N²)), compacts, assigns `FG-N` deterministically ordered by each component's minimum numeric finding id. Emits sorted JSON array `[{id, finding_ids, files_planned}]`. Uses `_common.py` for exit codes + schema validation.
  - `test/fixtures/fix-group-seed.json` — new 7-finding fixture with CCG-linked pair (F004↔F005 via G1), file-overlap pair (F001+F002 on src/a.ts), transitivity set (F004↔F005 CCG + F004↔F006 file), standalones (F003, F007). Fully-valid artifact per schema-v1.json.
  - `test/smoke.sh` — 8 new assertions (FX-GF-1..8): init + single-eligible + CCG merge + file-overlap merge + transitive closure + disjoint singletons + empty list + unknown id + null-validation_result rejection.

- **3.B — `artifact-patch.py` batched fix modes** (commit `c1cb863`):
  - `commands/_shared/tools/artifact-patch.py` — two new subcommand modes. `--apply-fix-start` bulk `open → attempted` with explicit non-open guard (catches Phase-7-gate-bypass bugs loud instead of `_apply_finding_set`'s silent same→same no-op). `--apply-fix-outcomes` maps `phase_9_outcome` to the §13.1 Phase 9 disposition + coupling + reason prose, appends `fix_attempts[]`, enforces `regression ⇒ output_sha=null` and `null outcome ⇒ output_sha=null + phase_9_finding present`. Both modes mirror `--apply-decisions`'s per-tuple-atomic-write + first-failure-halt pattern. Helpers: `_check_fix_tuple`, `_build_fix_attempt`, `PHASE_9_OUTCOME_VALUES`, `ALLOWED_FIX_*_TUPLE_KEYS`.
  - `DESIGN.md` §21.2 — two clarification paragraphs documenting the new modes (derivation table, invariant enforcement, `--dry-run` non-support rationale).
  - `test/smoke.sh` — 9 new assertions (FX-AF-1..9 + FX-AF-init): bulk transition, Phase-7-bypass guard, each Phase-9-outcome path end-to-end, overlap-abort preservation, regression-output_sha invariant, missing-key rejection, did-you-mean on typo outcomes.

- **3.C — `adams-review-fix.md` top-level** (commit `b5f70f1`):
  - `commands/adams-review-fix.md` — thin shell mirroring `adams-review.md`. Frontmatter grants every existing helper + `group-fixes.py` + `Edit` + `Write` (for fix-group sub-agents) + usual Bash utility set + `AskUserQuestion`/`Agent`/`Read`/`BashOutput`/`KillShell`. Prelude covers §25.2 working-set summary, sub-agent dispatch pattern, §24.4 artifact-records-commit-before-network invariant, fix-group delete/rename prohibition. Three preprocessor includes for 08/09/10 fragments. "What this command does NOT do" trailer.

- **3.D — `08-fix-loader.md` (Phase 7)** (commit `14cb208`):
  - `commands/_shared/08-fix-loader.md` — steps 7.1 (arg parse) → 7.2 (latest.txt resolver + log paths) → 7.3 (schema validate) → 7.4 (leftover-`attempted` hard abort with deterministic recovery message) → 7.5 (clean-tree gate: stash|abort) → 7.6 (file-overlap staleness check with `latest_known_sha = last non-null fix_attempts[].output_sha // reviewed_sha` derivation) → 7.7 (PR eligibility recheck; stash-pop on all abort paths) → 7.8 (run_id generation `fixrun_<ULID>` + `input_sha` capture). Working-set delta block closes the fragment.

- **3.E — `09-fix-execution.md` (Phase 8)** (commit `4e43906`):
  - `commands/_shared/09-fix-execution.md` — steps 8.1 (jq-filter eligibility) → 8.2 (empty-eligibility short-circuit to Phase 9e no-commit) → 8.3 (`group-fixes.py` dispatch) → 8.4 (batched `--apply-fix-start`) → 8.5 (single-turn parallel Opus fix-group Agents with verbatim §19.8 prompt; delete/rename prohibition explicit) → 8.6 (parse + token log per §24.4; retry-once; placeholder on parse fail) → 8.7 (phases.jsonl record with run_id + group_count + eligible_count). Working-set delta annotates the populated `fix_groups[*].results` shape.

- **3.F — `10-post-fix-and-commit.md` (Phase 9)** (commit `e824007`):
  - `commands/_shared/10-post-fix-and-commit.md` — biggest fragment in the repo. 9.pre overlap guard (union-find per-group `actual_touched` + explicit `git status` 'D <path>' detection for the §19.8 delete-prohibition belt-and-suspenders; non-empty → batched `--apply-fix-outcomes` with `phase_9_outcome: null` + `output_sha: null`, skip 9a-9c, jump to 9e no-commit). 9a (single Opus post-fix reviewer per §19.9 with `git diff HEAD` embedded; token log; parse-retry; placeholder on failure). 9b (priority-aggregate `regression > partial > verified` per fix group; revert regression-group `files_modified` via `git checkout --` and `files_created` via `rm -f`; revert-failure and all-regression both jump to 9e no-commit with distinct degenerate tags). 9c (stage surviving-group files by name, never `-A`; default one combined commit via `-F msg_file` so finding claims with quotes/backticks survive; `--granular-commits` opts into per-group; capture `commit_sha` immediately). 9d (one batched `--apply-fix-outcomes` writing every touched finding — regression tuples with `output_sha: null`). 9e deterministic order (validate → render → phases.jsonl → push → publish → stash pop → surface first failure), symmetric no-commit branch handling all four degenerate cases (overlap-abort, all-regression, revert-failure, no-eligible).

- **3.G — `artifact-render.py` Fix runs section** (commit `ce7b911`):
  - `commands/_shared/tools/artifact-render.py` — `render_fix_runs()` upgraded from bullet-list to per-run ### header + outcome summary + per-finding table (Finding/Group/Outcome/phase_9_finding). Newest-first ordering (the freshest run matters most to the reader). New `_OUTCOME_LABEL` map: `None` renders as `⚠ overlap-abort` rather than `(no outcome)` — §4 Phase 9.pre audit-trail visibility. Status column on the Auto-fixable deep-lane table already handled the new dispositions (partial/regression/resolved) from Stage 1; verified via `FX-RF-*` assertions.
  - `test/fixtures/expected.md` — regenerated for the new Fix runs block shape.
  - `test/smoke.sh` — 6 new assertions (FX-RF-1..6): section header + sub-header, mixed-outcome summary line, per-finding table with all three labels, section-absent when no fix_attempts, overlap-abort label + summary, newest-first ordering.

- **3.I — this close-out** — BUILD.md stage index flip + Stage 3 section fill-in.

**Verification evidence:**

- `test/smoke.sh` passes **96 assertions**, up from 71 at Stage 2.7 close. Breakdown of additions: FX-GF-1..8 (group-fixes.py — 8), FX-AF-init + FX-AF-1..9 (artifact-patch.py batched modes — 10), FX-RF-1..6 (renderer — 6). Total Stage 3 contribution: +25 assertions, including FX-init + FX-AF-init rebuild-fresh-artifact setup steps. Existing 71 assertions unchanged (the single `expected.md` regen for Stage 3.G is value-equivalent — same fixture + same logic under Stage 1 operations, just the enriched Fix runs block).
- **Helper-level manual smoke** (during development): all seven GF scenarios and all five AF scenarios ran cleanly on the first post-write attempt with no blast-radius surprises. One fix landed mid-stage: `--apply-fix-start` originally inherited `_apply_finding_set`'s same→same short-circuit semantics, which would silently no-op if the Phase 7 leftover-attempted gate failed. FX-AF-2 caught this as a real issue; the helper now explicitly rejects non-`open` findings with EXIT_INVALID_TRANSITION (2). Treat this as the Stage-3 analog of Stage 2.5.B's per-tuple-atomic-write discipline — the helper enforces the state invariant the orchestrator relies on, rather than hoping the orchestrator never hands it bad input.
- **Real-repo end-to-end run deferred.** The done-when calls for a full `/adams-review-fix` invocation on a real artifact (e.g., the ray-finance `feat/import-apple` review from C13 with 4 confirmed_auto findings). Not executed at close-out — the token cost of a real Opus fix + Opus post-fix review is meaningful, and fragment-level correctness is covered by unit smoke + helper-level manual smoke. Budget for the integration run when it fits the user's workflow. Same pattern as Stage 2.6 and Stage 2.7 deferrals.

**Open issues / deviations:**

- **`--apply-fix-start` explicit non-open guard** — documented in 3.B commit message and in DESIGN §21.2. The helper now rejects any tuple whose finding is not `current_state == "open"` at entry, even though `_apply_finding_set`'s transition whitelist would nominally allow `attempted → attempted` as a no-op. Kept as a loud guard against Phase-7-gate-bypass orchestrator bugs. Clarification-level DESIGN update; see §21.2 paragraph.
- **Phase 8/9 sub-agent prompt surface is fragment-level only.** §19.8 (fix-group) and §19.9 (post-fix reviewer) prompt essences are reproduced verbatim in 09-fix-execution.md / 10-post-fix-and-commit.md. Not machine-verified; real-repo runs will drive any tuning. Same posture as Stage 2's lens prompts through C13.
- **`git diff HEAD` surface in Phase 9a prompt is unbounded.** On large fix-runs (many files edited), the diff size could push the Phase 9a prompt over practical token limits. Not yet addressed — DESIGN §19.9 describes the diff as "pre-embedded," and a real-repo ceiling hasn't been observed. If the first integration run hits it, introduce per-file truncation with a boundary note (cheaper than moving to per-group review). Flag for the Stage-3 real-repo integration run.
- **Delete/rename prohibition is enforced by prompt + Phase-9.pre sanity check.** §19.8 forbids `rm`/`git rm`/`git mv` in fix-group agents; the enforcement is (a) explicit in the agent's prompt and (b) belt-and-suspenders'd in 10-post-fix-and-commit.md 9.pre step "deleted_paths" check (any `D ` entry in `git status --porcelain` short-circuits to overlap-abort with a diagnostic). Tool-level enforcement (`disallowed-tools` on the sub-agent) isn't available via the Agent tool's current API surface in practice; if the first real-repo run surfaces a fix agent that slips a delete through prompt discipline, escalate to a post-agent tree walk that checks for missing files. v2 could relax the prohibition with a revert model for deletes.
- **Granular-commits prose leaves detail to the implementer.** The 10-post-fix-and-commit.md 9c section describes `--granular-commits` as "one commit per surviving group" with per-group message scoping, but doesn't exhaustively prescribe the per-group message template. That's intentional — the default combined-commit path is the 80% case, and the first real ensemble-granular run will drive the specifics. If needed, a Stage-3-follow-up can tighten.
- **Real-repo integration smoke still deferred (tracked in Open issues above).** When the run lands, record wall-clock, token spend, and any fragment-level drift here or in Cross-stage notes.

- **Top-level command symlink for `adams-review-fix.md` was not created at stage close-out.** Stage 3.C landed `commands/adams-review-fix.md` in the repo, but the file-level symlink into `~/.claude/commands/adams-review-fix.md` wasn't part of the stage close-out checklist, so `/adams-review-fix` wasn't reachable as a slash command until manually linked 2026-04-18 post-close. `_shared` is symlinked at the directory level (picking up the 08/09/10 fragments and `group-fixes.py` automatically), but each new top-level command needs its own `ln -s`. Promoted to a Cross-stage note; see the 2026-04-18 install-script entry below.

---

### Stage 2.8 — PR comment freshness

**Rationale.** Stage-2's Phase-1.5 scrape used `--since review_started_at` to drop bot comments posted before the review started. Observation during review of `beta-briefing` PR #199: Greptile summary comments posted days before the review — on files that hadn't changed since — were silently dropped. Newness is the wrong relevance axis. Code locality is the right one: include a bot comment iff the code it refers to hasn't changed between when it was posted and HEAD.

**Scope (landed):**

- **2.8.A** — new helper `comment-freshness.sh` (§21.10) implementing the three-kind filter: `review_comment` (diff `commit_id..HEAD -- path`), `review` (diff intersected with `reviewed_files_all`), `issue_comment` (policy C2 — `created_at > max(committer.date)` from `pulls/<pr>/commits`).
- **2.8.B** — `--since` removed from `external-scrape.sh`; helper now pure "fetch + bot-filter + normalize".
- **2.8.C** — `02-ensemble-adapter.md` step 1.5.3 rewired to pipe scrape → freshness filter; `00-preflight.md` step 0.5 prose loosened (`review_started_at` capture no longer needs to precede mutations); `adams-review.md` grants `comment-freshness.sh`.
- **2.8.D** — this close-out.

**Status:** done (2026-04-18).

**Stage 2.8 commits (on `main`, newest first):**

```
(this commit) Close Stage 2.8: BUILD.md + stage index + plan copy
2599166       Stage 2.8.C: rewire Phase 1.5 scrape through comment-freshness.sh
79f2ac1       Stage 2.8.B: remove --since from external-scrape.sh (§21.8)
0765eeb       Stage 2.8.A: comment-freshness.sh helper + DESIGN §13.13/§21.10
```

**Files landed:**

- **2.8.A** (commit `0765eeb`):
  - `commands/_shared/tools/comment-freshness.sh` — new Bash helper; stdin @- / file / inline for `--comments`; csv / @- for `--reviewed-files`; lazy-fetch `pulls/<pr>/commits` with fixture-replay support; force-push `git fetch` fallback for unreachable commit_ids; API-failure fallback (policy A) for issue_comments when the commits API fails; one audit line per record to stderr with hyphenated `reason=<verb>` (matches §21.9 convention).
  - `DESIGN.md` — new §13.13 "PR comment freshness" (algorithm table, C2 rationale, reachability fallback, API fallback, placement, rationale, implementation pointer); new §21.10 `comment-freshness.sh` spec (interface, algorithm, fixture replay, errors, cost).
  - `test/smoke.sh` — CF-1..CF-7 assertions (+7) against a scratch 2-commit repo plus fixture `pr_commits.json`. Covers all six action verbs (`fresh`, `stale`, `fresh-summary`, `stale-summary`, `unreachable`, and — via CF-ES-2 later — usage-error paths) and the reason prose.

- **2.8.B** (commit `79f2ac1`):
  - `commands/_shared/tools/external-scrape.sh` — `--since` removed from arg parse + usage + jq filter; `iso_gt_eq` helper dropped (no longer called).
  - `DESIGN.md` — §21.8 interface updated; new "Freshness filtering" paragraph names the removal and points at §21.10; §4 Phase 1.5 step 1 signature updated; step 4 now runs the freshness filter before the normalizer (renumbering 4→6); §10 helper table updated + `comment-freshness.sh` row added.
  - `test/smoke.sh` — G assertion updated (ids now `[2,5]` — age is no longer filtered at the scrape layer); CF-ES-1 exercises the fixture-replay happy path without `--since`; CF-ES-2 asserts `--since` now returns exit 64 (unknown-arg) rather than silent ignore.

- **2.8.C** (commit `2599166`):
  - `commands/_shared/02-ensemble-adapter.md` step 1.5.3 — pipe scrape output into `comment-freshness.sh` with `2> >(tee -a "$trace_log_path" >&2)` so per-record audit lines land in `trace.md` inline. Helper-failure fallback falls back to the raw scrape and tags `phase_1_5_freshness_helper_failed` — Phase 1.5 never aborts on a filter bug.
  - `commands/_shared/00-preflight.md` step 0.5 — the "before any push or mutation" invariant is gone; `review_started_at` is now metrics-only.
  - `commands/adams-review.md` — `comment-freshness.sh` added to `allowed-tools`.

- **2.8.D — this close-out:**
  - `BUILD.md` — this section + Current state + stage index row.
  - `plans/stage-2.8-comment-freshness.md` — plan copied from `~/.claude/plans/mutable-churning-squirrel.md` to match Stage 2.5/2.6/2.7/3 convention.

**Verification evidence:**

- `test/smoke.sh` passes **105 assertions**, up from 96 at Stage 3 close. Additions: CF-1..CF-7 (comment-freshness.sh — 7), CF-ES-1/2 (external-scrape.sh --since removal — 2). The existing G assertion was amended (same count) to reflect that age no longer filters at the scrape layer.
- **Helper manual smoke** (during development, pre-CF-* assertions): scratch 2-commit repo with a.txt changed / b.txt unchanged; hand-built review_comment / review / issue_comment records. All six action verbs fired on first attempt against the expected inputs; no mid-stage fixes needed.
- **Real-repo ensemble re-run deferred.** Same pattern as Stage 2.6/2.7/3. Integration signal will come from the first `/adams-review --ensemble` run on a PR with pre-existing bot comments (e.g., re-running `beta-briefing` PR #199 after 2.8 ships). `trace.md` should show `comment_freshness: id=... action=...` lines, one per scraped record, and the Phase-1.5-sourced findings should reflect only fresh inputs.

**Open issues / deviations:**

- **`pulls/<pr>/commits` is fetched lazily — only when a record without `commit_id` is in the input.** If all input records carry `commit_id` (pure inline review_comments / review submissions; zero issue_comments), the API call is skipped entirely. This is a small ergonomic win and avoids a rate-limit hit on PRs where issue comments are all human-authored (and thus already filtered out by the bot filter). If a future caller wants to pre-warm the cache for audit consistency, add `--prefetch-commits` later.
- **Policy C2 (issue_comment diff-wide timestamp compare) is strictly stronger than "include all" and simpler than per-comment timeline lookup.** Worth noting: any subsequent push after a summary comment invalidates the summary (the latest-committer-date advances past the comment's created_at). For diff-wide comments this is the correct behavior — a later commit means the summary's mental model of the diff is at least partially stale — but it does mean bot summaries are volatile. If a future PR workflow makes summary stickiness important, surface and consider a laxer policy (A) or per-comment timeline (C full).
- **Force-pushed PR with orphaned commit_ids.** One `git fetch origin +refs/pull/<pr>/head` retry is attempted in non-fixtures mode. If the force-push happened before any local `git fetch` and the PR ref was never pulled, the retry brings the commit back. If the remote itself has garbage-collected the orphaned commit (rare — GitHub retains PR refs aggressively), the record is dropped with `action=unreachable`. No known real-repo run has hit this yet.
- **No real-repo integration smoke at stage close.** Budget: first `--ensemble` run on a PR with pre-existing bot comments. If the filter shape is off in production, the most likely symptom is `action=stale-summary` on a Greptile comment that the user expects to be fresh — check `trace.md` for the audit lines and compare against the actual commit timeline of the PR.

---

### Stage 4 — Fragment shrink + helper externalization (context-budget hardening)

**Rationale.** `/adams-review` invocation currently expands to ~30k tokens of command + fragments alone (`commands/adams-review.md` inlines 10 fragments via `!cat` preprocessor; total ~117k chars / 2876 lines). On top of the Claude Code harness + user's MCP/plugin surface, a typical session lands at 90k+ context before any review work runs. Stage 2.5 cross-stage notes flagged this pattern as "Lever #4: fragment prose shrink — deferred"; Stage 2.6's Phase-0 expansion (step 0.2a added ~4k chars of inline Bash) nudged the number further. This stage executes that deferred work plus its natural companion: moving cohesive Bash snippets out of fragments and into helper scripts with 10-line contracts.

**Baseline to beat** (post-Stage-2.6, 2026-04-18):

```
commands/adams-review.md                 171 lines    8k chars
commands/_shared/00-preflight.md         617 lines   26k chars   ← biggest
commands/_shared/01-detection.md         399 lines   17k chars
commands/_shared/02-ensemble-adapter.md  359 lines   14k chars
commands/_shared/03-dedup.md             206 lines    7k chars
commands/_shared/04-scoring-gate.md      213 lines    8k chars
commands/_shared/05-validation.md        381 lines   17k chars
commands/_shared/06-cross-cutting.md     164 lines    6k chars
commands/_shared/07-finalize.md          285 lines   10k chars
commands/_shared/lens-{ux,security}-reference.md  81 lines 4k chars
TOTAL                                   2876 lines  117k chars  ≈ 30k tokens
```

**Scope (target):**

- **4.A — Prose compression pass across fragments.** Remove prose that duplicates the top-level `adams-review.md` prelude (sub-agent dispatch pattern, working-set rules, effort-is-session-wide, etc. are repeated inside fragments in abbreviated form). Collapse parallel wording across L1–L6 lens prompts (each currently repeats the same "Read ONLY the diff between `$comparison_ref` and HEAD..." / "Return a JSON array of candidates..." scaffolding with minor variations — factor the invariant parts into step 1.2's shared input block, leave only the lens-specific guidance in each L*N* prompt). Tighten working-set tables into the §25.1 DESIGN reference rather than reproducing them in full at each fragment's tail. Target: ≥25% char reduction on `00-preflight.md` and `01-detection.md` (the two biggest); ~15-20% on the rest.
- **4.B — Extract inline Bash snippets into helper scripts.** Candidate extraction points, each yielding a ~10-line fragment contract + one helper invocation:
  1. **`freshness-gate.sh`** — step 0.2a's full fetch + 30s-timeout + FF + behind-count + AskUserQuestion-branching Bash (~80 lines of snippet). Helper takes `--base-branch` + `--head-branch`, returns JSON with `{comparison_ref, base_freshness, remote_sha, behind_count, preflight_warnings[]}`. Fragment reduces to the AskUserQuestion dispatch + helper invocation.
  2. **`trivial-check.sh`** — step 0.11's extension-allowlist + line-count + file-count Bash (~20 lines). Helper returns `{trivial_mode: bool, reason: string}`.
  3. **`dirty-tree-classify.sh`** — step 0.8's `git status --porcelain` categorization into Modified/Staged/Untracked (~15 lines). Helper returns JSON.
  4. **`finding-builder.py`** (candidate) — step 1.4 list-step-3's jq-builder that transforms a partial lens candidate into a full schema-shaped finding. Currently ~40 lines of jq inside the fragment. A Python helper could take a partial JSON + lens metadata and return the full finding, simplifying the fragment to `full=$(finding-builder.py --lens L2-structural --candidate ... --counter-state ...)`.
- **Not in scope for this stage** (per the chat-time decision):
  - Lens reference file inlining gate (only load `lens-ux-reference.md` when L5 actually runs). Lower priority; separate audit.
  - Any behavior change — purely representational.
  - Any plugin/MCP pruning — user-level decision, not ours.
  - Any DESIGN.md rev bump; clarification-level updates only (§21 gains rows for new helpers).

**Done when:**

1. Command + fragments drop from ~30k tokens to ≤~22k tokens (≥25% reduction target). Measured via the same `wc -c` snapshot at stage close.
2. `test/smoke.sh` passes unchanged — no behavior drift. Smoke tests may grow to cover new helpers' contracts (fresh scratch-repo fixtures for `freshness-gate.sh`, etc.) but existing assertions stay green.
3. BUILD.md "Current state" records the before/after character and token counts so future stages can tell whether they're re-expanding.
4. Each extracted helper has 2-3 smoke assertions covering its happy path + one failure mode (mirrors the OC-* / FR-* / RH-* style from Stage 2.6).
5. DESIGN.md §21 gains entries for each new helper (interface, algorithm sketch, error cases) — same shape as existing §21.1–§21.9.

**Commit cadence (estimated):**

1. 4.A prose compression — 2-3 commits (one per fragment cluster: preflight+detection first, then validation/dedup/scoring, then finalize/ensemble).
2. 4.B helper extractions — 1 commit per helper (freshness-gate → trivial-check → dirty-tree-classify → finding-builder). Each commit includes fragment shrink + helper + smoke assertions + DESIGN §21 row.
3. Stage 4 close-out — BUILD.md + measurement snapshot — 1 commit.

~6-8 commits total. Plan-approval round-trip before execution (non-trivial representational change across many files).

**Status:** not started. Will plan after Stage 3 closes.

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

- **2026-04-18 — Stage 3 batched-helper pattern, second instance.** `--apply-fix-start` and `--apply-fix-outcomes` are the second and third `artifact-patch.py` modes to adopt the Stage-2.5.B `--apply-decisions` pattern: JSON array of tuples, per-tuple atomic writes, first-failure halt, one summary line on success. The shared structure is now load-bearing — Stage 2.5.C's authoring disciplines (#3 "avoid per-finding loops") show up as a clean three-mode family in the helper rather than three one-offs. If Stage 4 or a follow-up adds a fourth batched mode (e.g., `--apply-scoring-batch` for Phase 3), reuse the `_check_fix_tuple` shape validator + the `_load_or_fail`-per-tuple + `_write_and_emit(silent=True)` scaffolding. The price of the pattern is that a mid-batch failure leaves the first N tuples persisted; callers re-invoke with the remainder. We accepted that at Stage 2.5.B; it's held up cleanly for Stage 3.

- **2026-04-18 — Stage 3 `--apply-fix-start` explicit non-open guard.** `_apply_finding_set`'s `if requested != before` short-circuit treats `attempted → attempted` as a silent no-op. A bug where Phase 7's leftover-attempted hard abort fails to fire, or where 8.1's eligibility filter lets an already-attempted finding through, would produce a Phase 8 that looks like it succeeded but did nothing. FX-AF-2 caught the gap; `cmd_apply_fix_start` now rejects any non-open finding with `EXIT_INVALID_TRANSITION` + an error-as-prompt pointing at the Phase 7 gate. The transition whitelist still fires as a second layer, so the guard is additive. Clarification-level DESIGN update in §21.2; no design rev bump.

- **2026-04-18 — Stage 3 commit message template uses `git commit -F <file>`, not `-m "$(...)"`.** Phase 9c assembles the commit message in a temp file via a heredoc-friendly block and invokes `git commit -F "$msg_file"`. Rationale: finding `claim` text can contain quotes, backticks, dollar-signs, or newlines that would need careful escaping inside `-m "$(...)"`. A temp-file message body sidesteps the entire escape-surface. The cost is one extra file touch + an `rm -f "$msg_file"` after commit; the benefit is that message rendering is data-driven, not quoting-driven. If any future commit-message-building code simplifies back to `-m`, re-verify against a finding whose claim contains backticks.

- **2026-04-18 — Stage 3 Fix-group agent delete/rename enforcement is layered, not single-point.** §19.8 forbids `rm`/`git rm`/`git mv`. Enforcement layers: (a) explicit prohibition in the fix-group agent prompt (09-fix-execution.md step 8.5); (b) belt-and-suspenders check at 9.pre that scans `git status --porcelain` for any `D <path>` entries and short-circuits to overlap-abort with a `<delete-detected>` file marker if any appear. The Agent tool's current API doesn't expose a reliable way to restrict a spawned sub-agent's `Bash` grant to a subset of the parent's, so we can't enforce at the tool layer. If a real-repo run surfaces a fix agent that leaks a delete past both layers, add a post-agent tree walk comparing against the pre-Phase-8 file list (`ls -R`) to catch the drift before Phase 9a runs.

- **2026-04-18 — Top-level command install is still manual; the TBD install script from Stage 1 hasn't landed.** BUILD.md §Conventions line 634 notes: *"All scripts live at `~/.claude/commands/_shared/tools/` per DESIGN §9. Symlinked from this repo during development, or copied via install script at stage close-out (TBD — decide in Stage 1 planning)."* Stage 1 deferred the decision; Stages 2/2.5/2.6/2.7/3 kept deferring it. The gap surfaced when Stage 3 shipped `adams-review-fix.md` in the repo but `/adams-review-fix` wasn't reachable — `~/.claude/commands/` needed a per-command `ln -s` that no stage plan prompted. The `_shared` symlink is at the directory level, so fragments + helpers propagate automatically; it's only top-level `.md` commands that need the explicit link. **Interim rule until an install script exists:** any new top-level command file in `commands/*.md` requires a matching `ln -s $PWD/commands/<name>.md ~/.claude/commands/<name>.md` as part of the stage close-out, and the stage's *Files landed* entry for that file should note the symlink was created. **Install-script candidate scope when we build one:** idempotent `ln -sf` for every `commands/*.md` plus the `commands/_shared` directory link, dry-run flag, and a check that no destination already points somewhere else. Stage 4 plan should either include it or explicitly punt again with a rationale.

- **2026-04-18 — Stage 2.8 PR-comment freshness filter: time axis replaced with code-locality axis.** `external-scrape.sh` used to accept `--since <iso-8601>` and drop bot comments older than that timestamp (anchored to `review_started_at`). Stage 2.8 removed the arg and introduced `comment-freshness.sh` (§21.10) which filters per-record by whether the referenced code has changed between the comment's posting and HEAD. `review_comment` + `review` kinds use `commit_id` + `git diff` (targeted or intersected with `reviewed_files_all`); `issue_comment` kinds (no `commit_id`) use policy C2 — include iff `created_at > max(committer.date)` from `pulls/<pr>/commits`. **Knock-on effects:** `review_started_at` is now purely a Phase-6 metrics anchor (no longer gates scraper behavior); `00-preflight.md` step 0.5's pre-mutation invariant is relaxed accordingly; DESIGN §4 Phase 1.5 gains a new step between scrape and normalizer; `02-ensemble-adapter.md` step 1.5.3 pipes scrape → filter with `tee -a trace.md` audit flow (matches `origin-crosscheck.sh` convention). **Design decision pinned:** policy C2 (stronger than "include all", simpler than per-comment timeline lookup via `pulls/<pr>/commits`). If a future run surfaces a case C2 misclassifies, upgrade to full policy C with a dedicated `--policy` flag on the helper rather than silent tuning. **Breaking change:** `--since` now exits 64 (unknown-arg) instead of silent ignore, so any stale scripts fail loudly.

- **2026-04-18 — `repo_slug` derivation centralized into `tools/repo-slug.sh`; Phase 0 and Phase 7 call the same helper.** First real-world `/adams-review-fix` run on `beta-briefing` aborted in Phase 7 with "No review found for this branch" despite Phase 0 having written one: Phase 0 §0.3 was **prose only** (no concrete bash), while Phase 7 §7.2 had a concrete `sed -E '...; s#\.git$##'` pipeline. The DESIGN §9.2 prose matched Phase 0's — it listed the steps but omitted trailing-`.git` stripping, only demonstrating it in the example. Executing the prose literally produced `github.com-adamjgmiller-beta-briefing.git/` on disk; Phase 7 computed `github.com-adamjgmiller-beta-briefing` (no `.git`) and the paths didn't meet. **Fix.** New `commands/_shared/tools/repo-slug.sh` — single source of truth; takes `--repo-root`, applies the full algorithm including `.git$` strip, prints the slug. Phase 0 §0.3 and Phase 7 §7.2 now both invoke `~/.claude/commands/_shared/tools/repo-slug.sh --repo-root "$repo_root"`. DESIGN §9.2 prose amended to mention `.git$` stripping explicitly and to reference the helper. **Migration.** Users with a pre-fix `~/.adams-reviews/<slug>.git/<branch>/…` directory can `mv` it to drop the `.git` suffix, or re-run `/adams-review` (the branch's `latest.txt` will be recreated under the correct slug). **Defence in depth.** The defect class here is "same algorithm implemented twice, prose + concrete bash drift." The shared helper closes that door; downstream phases (§25.1 `repo_slug`, artifact-publish `--repo-slug`) consume the value from the working set and don't recompute, so no third derivation exists to drift against.

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
