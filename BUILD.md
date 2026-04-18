# BUILD.md — build journal for adams-review

This is the running build journal. `DESIGN.md` is the normative design (rev 8). This file tracks **execution**: where we are, what's landed, what surprised us, and what still needs attention.

If you are a Claude Code session starting fresh (after compaction or on a new day), **read this file first**, then open `DESIGN.md`. Skim "Current state" and the active stage's section; you can treat the rest as reference.

---

## Current state

**As of 2026-04-17 — Stage 2 IN PROGRESS (C1–C12 landed + two audit rounds of fixes).** Stage 1 is done; Stage 2 has all 12 code/fragment commits plus post-audit fix commits. `test/smoke.sh` passes 33 assertions. Remaining: one more independent audit pass (Codex + CodeRabbit + Opus deduped), then C13 real-repo smoke + close-out.

- Design doc: `DESIGN.md` (rev 8 + §21.2 exit-code footnote + §5.2.1 `pending_validation` clarification + §12.1 example fix)
- Stage 1 plan: `plans/stage-1-foundation.md` (user-approved; closed out)
- Stage 2 plan: `plans/stage-2-review.md` (user-approved; C1–C12 done, C13 pending real-repo smoke)
- Symlink `~/.claude/commands/_shared → commands/_shared` is live
- `uv` (`/opt/homebrew/bin/uv 0.7.15`) supplies `jsonschema` to Python scripts via PEP 723 inline-script shebangs

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
| 2 | `/adams-review` end-to-end (Phases 0–6) | in progress | `plans/stage-2-review.md` | [Stage 2 section](#stage-2--adams-review) |
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

**Status:** in progress. C1–C12 landed; audit rounds 1–3 closed; C13 pending.

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

**Pending close-out (C13):**
- Real-repo smoke on `/Users/adammiller/Projects/ray/ray-finance` branch `feat/import-apple` (user-driven — approved in Stage 2 plan §10).
- Final BUILD.md close-out + grant-probe deferred items record.

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

- **2026-04-17 — §8.7 grant probe: PASSED.** Confirmed on macOS (`darwin 25.3.0`, Claude Code `default` mode): a frontmatter grant declared as `Bash(/Users/adammiller/.claude/commands/_shared/tools/probe.sh:*)` resolves cleanly when `~/.claude/commands/_shared` is a symlink to the dev repo — no permission prompt, script executed, stdout captured as expected. Verified in a separate Claude Code session invoking `/_shared-probe` (throwaway command + probe.sh). **Implication for Stage 2:** the full `/adams-review` `allowed-tools` block can use absolute paths under `~/.claude/commands/_shared/tools/...` per DESIGN §8.7's "canonical invocation path" rule; no need for the relative-name + `PATH` fallback. Probe files (`commands/_shared/tools/probe.sh` + `~/.claude/commands/_shared-probe.md`) torn down after verification; neither was committed.

---

## Handoff protocol — what to update at stage close-out

When a stage completes, before the user compacts:

1. **Current state** section at the top: update date, current stage, next action.
2. **Stage index table**: flip status for the completed stage, update close-out notes link.
3. **Completed stage's section**: fill in *Files landed*, *Verification evidence*, *Open issues / deviations*.
4. **Cross-stage notes**: append anything worth remembering across stages (e.g., a DESIGN ambiguity that we resolved one way, and the rationale).
5. Commit the `BUILD.md` update in its own commit before compacting.

The user will typically compact after step 5. The next session uses this file + `DESIGN.md` + the next stage's plan as its starting context.
