# CLAUDE.md — operational guide for adams-review

Read this first on a fresh session. It's procedural (how to work in the repo) plus a compact reference for the pipeline shape, finding state model, score gates, and helper inventory — enough to work without opening the archive.

**Context discipline.** This file is self-contained for routine work. `docs/archive/DESIGN.md` (rev 8, frozen 2026-04-19) and `docs/archive/BUILD.md` are unmaintained historical references — consult them only when you need the rationale behind a specific past decision. Fragment-level `per §X.Y` citations still grep-resolve under the archive path. The schema (`commands/_shared/schema-v1.json`) is the source of truth for artifact shape — read it directly.

## What this repo is

Build repo for four personal Claude Code slash commands:

- **`/adams-review`** — multi-lens code review of a branch or PR (Phases 0–6).
- **`/adams-review-walkthrough`** — interactive driver that walks the reviewer through findings `/adams-review-fix` would skip. Preflight offers a two-tier scope choice (default **Qualifying** — excludes Phase-3-demoted `below_gate`; **Full skip set** adds them back). `pre_existing_report` findings are always excluded from both walk tiers and routed exclusively to the end-of-run issue-filing phase (one-by-one draft/confirm/edit flow that calls `gh issue create`). Per-finding Sonnet briefing with an "Edit the fix hint" override path; for `confirmed_manual` / `confirmed_report` the briefer proposes best-effort hints. Closes the light-lane `confirmed_auto` gap where the default Phase 8 lane filter skips mechanically-fixable ux/policy findings.
- **`/adams-review-fix`** — automated fix loop for auto-fixable findings (Phases 7–9).
- **`/adams-review-promote`** — human override that promotes a single finding to auto-fixable, bypassing the Phase 8 impact_type lane filter and score threshold. Metadata-only; run `/adams-review-fix` afterwards to apply. Used internally by `/adams-review-walkthrough` via `commands/_shared/promote-core.md` + `--defer-publish`.

All four are **built and in production use** as of 2026-04-19 (Stages 1, 2, 2.5, 2.6, 2.7, 2.8, 3 closed; walkthrough closed on branch `walkthrough-mode`). The only unexecuted original scope is Stage 4 (fragment shrink), scoped in `plans/stage-4-fragment-shrink.md`.

**Recommended flow on a non-trivial PR:** `/adams-review` → `/adams-review-walkthrough` (optional) → `/adams-review-fix`. Each command is independent; `/adams-review-promote` remains useful for one-off manual promotions outside the walkthrough.

## Pipeline shape

```
/adams-review [--ensemble]
├── Phase 0 — Pre-flight (branch/PR detect, base-branch freshness, dirty-tree,
│              push, prior-artifact prompt, record review_started_at,
│              trivial-diff detection, CLAUDE.md path lister)
├── Phase 1    ─┐ Detection (6 parallel lens agents, 7 under --ensemble — L7
│               │   is a holistic Opus safety net; origin cross-check corrects
│               │   blame-traceable verdicts; under --ensemble also dispatches
│               │   codex:codex-rescue + coderabbit:code-reviewer via the
│               │   ensemble adapter)
├── Phase 1.5  ─┘ External PR-comment scrape (gh api → bot filter → comment-freshness →
│                 Sonnet normalizer; ensemble mode only; joint dispatch with Phase 1)
├── Phase 2 — Dedup (one Sonnet call; merges equivalent candidates, unions source_families)
├── Phase 3 — Cheap scoring + gate (Sonnet err-up rubric; ≥2 families auto-graduate)
├── Phase 4 — Validation (deep Opus per candidate for correctness/security;
│              light Sonnet confirmation for ux/policy/architecture)
├── Phase 5 — Cross-cutting review (deep-lane only; dispatched Opus sub-agent)
└── Phase 6 — Finalize (phases.jsonl, artifact write, render, PR comment POST)

/adams-review-fix [threshold]
├── Phase 7 — Load artifact; leftover-attempted abort; clean-tree gate; staleness check
├── Phase 8 — Per-fix-group agents edit working tree (no git ops);
│              each group reports files_modified + files_created
└── Phase 9 — Post-fix Opus review pre-commit; aggregate outcomes per group;
              revert regression groups (checkout modified, rm created);
              commit surviving groups with outcome in message; push; append fix_attempts
```

## Finding state model

Three states, one disposition enum. States transition; dispositions classify.

**States:** `open` | `attempted` | `resolved`. Valid transitions (enforced by `artifact-patch.py`):

```
open → attempted       (Phase 8 ran)
attempted → resolved   (Phase 9 verified)
attempted → open       (Phase 9 classified partial or regression)
```

Any other transition is rejected. Leftover `attempted` on a fresh `/adams-review-fix` → **hard abort** with deterministic recovery message.

**Disposition enum** (the primary routing key — filters and report selectors read this, not combinations of prose fields):

| disposition | Meaning | `current_state` | `is_actionable` | Set by |
|---|---|---|---|---|
| `below_gate` | `score_phase3 < 45` and single source family | `open` | `false` | Phase 3 |
| `pending_validation` | Gate-in parking; awaiting Phase 4 | `open` | `false` | Phase 3 |
| `disproven` | `score_phase4 < 45` | `open` | `false` | Phase 4 |
| `uncertain` | `score_phase4 45–59` | `open` | `false` | Phase 4 |
| `confirmed_auto` | `score_phase4 ≥ 60`, deep lane, `actionability == auto_fixable` | `open` | `true` | Phase 4 |
| `confirmed_manual` | `score_phase4 ≥ 60`, `actionability == manual` | `open` | `false` | Phase 4 |
| `confirmed_report` | `score_phase4 ≥ 60`, `actionability == report_only` | `open` | `false` | Phase 4 |
| `pre_existing_report` | `origin == pre_existing` AND `origin_confidence == high` (normative override, regardless of score) | `open` | `false` | Phase 1 / re-asserted Phase 4 |
| `partial` | Phase 9 found fix incomplete; retry-eligible | `open` | `true` | Phase 9 |
| `regression` | Phase 9 found new adjacent issue; group was reverted; retry-eligible | `open` | `true` | Phase 9 |
| `resolved` | Phase 9 verified | `resolved` | `false` | Phase 9 |

**Invariants** (enforced by writers):

- `is_actionable` is derived: `true` iff `disposition ∈ {confirmed_auto, partial, regression}`. Never set it directly in conflict with `disposition`.
- `current_state == resolved` ⇔ `disposition == resolved`.
- `human_confirmation` is absent/null unless `/adams-review-promote` has run. Present-and-non-null is a Phase 8 bypass of both the lane filter and the threshold (see Score gates below). Promotion never mutates `score_phase4` — the validator's honest score is preserved for audit.

## Score gates (normative)

Each rule sets `disposition`; `is_actionable` follows by derivation.

**Pre-existing override** (highest priority — evaluated before any score rule, re-asserted at end of Phase 4):

```
origin == "pre_existing" AND origin_confidence == "high"
  → disposition: pre_existing_report
  → is_actionable: false
  → regardless of score
```

**Phase 3 validation gate** (applies to everything that survived the override):

```
score_phase3 < 45 AND single source family   → disposition: below_gate, does not enter Phase 4
score_phase3 < 45 AND ≥ 2 source families    → advance to Phase 4 (auto-graduation)
score_phase3 >= 45                           → advance to Phase 4
```

**Phase 4 validation decision** (applies after Phase 4a deep / 4b light):

```
score_phase4 < 45    → disposition: disproven,  is_actionable: false
score_phase4 45–59   → disposition: uncertain,  is_actionable: false
score_phase4 >= 60   → disposition depends on actionability set by validator:
                         auto_fixable  → confirmed_auto   (is_actionable: true)
                         manual        → confirmed_manual (is_actionable: false)
                         report_only   → confirmed_report (is_actionable: false)
                       confirmed_strength: "moderate" (60–74) or "strong" (75+)
```

**Phase 9 outcome** (for findings attempted in a fix run):

```
verified    → disposition: resolved,   current_state: resolved
partial     → disposition: partial,    current_state: open   (retry-eligible)
regression  → disposition: regression, current_state: open   (retry-eligible;
              fix group reverted; fix_attempts.output_sha = null)
```

**Phase 8 fix gate** (the combination that governs what `/adams-review-fix` will touch):

```
current_state == open
  AND disposition ∈ {confirmed_auto, partial, regression}
  AND (
    human_confirmation != null                                      // promote bypass
    OR (
      impact_type ∈ {correctness, security}                         // lane filter
      AND score_phase4 >= threshold                                 // default 60
    )
  )
```

**Threshold summary.** Validation gate (Phase 3) is constant 45. Confirmation decision (Phase 4) has breakpoints at 45, 60, 75. Fix gate (Phase 8) defaults to 60 and is user-tunable via `/adams-review-fix <N>`. `human_confirmation != null` bypasses both the lane filter and the threshold — promotion is additive metadata, not a state mutation.

**Gate terminology.** "Gate" means three different things in this repo and the distinction matters when reading command output or debugging a scope filter:

- **Phase 3 scoring gate (45)** — the threshold that decides which candidates enter Phase 4 validation. Candidates below it get `disposition=below_gate` and carry no `score_phase4`.
- **Phase 4 confirmation gate (45/60/75)** — the thresholds that map `score_phase4` into `disproven` / `uncertain` / `confirmed_*` dispositions.
- **Phase 8 fix gate (default 60)** — the composite gate governing `/adams-review-fix`: disposition ∈ {confirmed_auto, partial, regression} **AND** deep lane **AND** `score_phase4 ≥ threshold`, with `human_confirmation` as the human-override bypass.

`below_gate` is a *disposition name* (Phase 3), not a threshold. `/adams-review-walkthrough` at its default **Qualifying** scope excludes `below_gate` findings because Phase 3 already judged them low-impact × low-confidence; the **Full skip set** scope includes them when a reviewer wants to sanity-check what Phase 3 demoted.

## Lanes

- **Deep lane** (correctness, security): Phase 4a Opus per candidate with blast-radius tracing and a comprehensive fix proposal; passes through Phase 5 cross-cutting review. Phase 8 processes `confirmed_auto` findings here by default.
- **Light lane** (ux, policy, architecture): Phase 4b Sonnet confirmation, report-first by default. Phase 8's lane filter excludes light-lane `confirmed_auto` unless `human_confirmation != null` (set by promote or walkthrough).

That asymmetric default is what `/adams-review-walkthrough` exists to close — the walkthrough scope is every finding the Phase 8 filter would skip at the current threshold.

## Layout

```
adams-review/
├── CLAUDE.md                       ← this file
├── README.md                       ← setup + layout + recommended flow (user-facing)
├── docs/
│   └── archive/                    ← frozen historical docs (not maintained)
│       ├── README.md               ← frozen-as-of banner
│       ├── DESIGN.md               ← rev 8 normative design (historical)
│       └── BUILD.md                ← stage-by-stage build journal (historical)
├── plans/                          ← per-stage plans (1–3 + 2.5/2.6/2.7/2.8 closed;
│                                     stage-4-fragment-shrink live)
├── commands/
│   ├── adams-review.md             ← top-level slash command (Phases 0–6)
│   ├── adams-review-walkthrough.md ← top-level slash command (interactive)
│   ├── adams-review-fix.md         ← top-level slash command (Phases 7–9)
│   ├── adams-review-promote.md     ← top-level slash command (metadata promote)
│   └── _shared/                    ← symlinked into ~/.claude/commands/_shared
│       ├── 00-preflight.md … 10-post-fix-and-commit.md   ← phase fragments
│       ├── promote-core.md         ← shared precondition + patch (promote + walkthrough)
│       ├── lens-{ux,security}-reference.md
│       ├── schema-v1.json          ← artifact shape (source of truth)
│       └── tools/                  ← helper scripts (see Helper index below)
└── test/
    ├── smoke.sh                    ← 129-assertion harness
    └── fixtures/
```

Top-level command files need **per-command symlinks** into `~/.claude/commands/`, created by `scripts/install.sh`. The `_shared/` directory symlink propagates fragments + helpers automatically. Adding a new top-level command means adding its stem to the `for cmd in …` loops in both `scripts/install.sh` and `scripts/uninstall.sh` (the `adams-review*.md` sed glob covers new files automatically as long as the name matches that pattern), then re-running `scripts/install.sh`. See README §Installation for the end-user flow.

## How to test

```bash
test/smoke.sh
```

Expects `smoke: PASS (N assertions)` where N grows as helpers are added. Every helper script and renderer path is covered. Existing assertions should stay green across changes; new helpers should add 2–3 assertions in the OC-\* / FR-\* / RH-\* / FX-\* / MP-\* / WT-\* naming style.

## Dependencies

| Tool | Version | Notes |
|---|---|---|
| `uv` | 0.7+ | PEP 723 inline-script shebang (`#!/usr/bin/env -S uv run --script`) — no venv, no pip install. `brew install uv`. |
| `bash` | 4+ | Helpers use `#!/usr/bin/env bash`; macOS default `/bin/bash` is 3.2 so `brew install bash` or user's newer default is required. |
| `jq` | 1.6+ | `brew install jq`. |
| `gh` | 2.x | `brew install gh`, `gh auth login`. |
| `git` | 2.x | Standard. |

Reviews root: `~/.adams-reviews/<repo-slug>/<branch>/<review_id>/`. Override with `$ADAMS_REVIEW_REVIEWS_ROOT`.

## Operational rules

Enough to work without opening the archive. Each rule is a decision that was learned the hard way.

1. **Bash 3.2 portable.** Helpers run under macOS `/bin/bash` 3.2 in practice. Avoid `declare -A`, `mapfile`/`readarray`, `${var,,}`. `awk '!seen[$0]++' | sort` beats associative arrays for dedup. `set -euo pipefail` and process substitution are fine.

2. **uv shebang for Python helpers.** `#!/usr/bin/env -S uv run --script` with a `# /// script` inline dep spec. Never `pip install` directly (PEP 668 blocks it on Homebrew Python 3.12+).

3. **Exit codes are a contract.** Python helpers: `0=OK, 1=validation, 2=invalid-transition, 3=dry-run-invalid, 4=unexpected, 5=missing-dep, 64=usage`. Defined in `tools/_common.py`; reuse, don't invent.

4. **Error-as-prompt on every helper.** Non-zero exits emit `ERROR:` / `Valid input:` / `Did you mean:` / `Action:` stderr sections. No stack traces on expected errors. See `tools/_common.py:suggest()`.

5. **Atomic writes.** Writers go tmp-file → `rename` (see `tools/_common.py:atomic_write`). The on-disk artifact is never in an invalid state mid-run.

6. **Reviews root is `~/.adams-reviews/`, not `~/.claude/reviews/`.** Claude Code hardcodes a sensitive-file prompt on writes to `~/.claude/` that survives `bypassPermissions` mode. Overridable via `$ADAMS_REVIEW_REVIEWS_ROOT`.

7. **`repo_slug` comes from one helper.** `tools/repo-slug.sh --repo-root <path>` is the single source of truth. Phase 0 and Phase 7 both call it. Never reimplement inline.

8. **Commit messages via `git commit -F <file>`, not `-m "$(…)"`.** Finding claims can contain quotes/backticks/newlines. Temp-file message bodies sidestep the whole escape surface.

9. **Fix-group agents may not delete or rename files.** Layered enforcement: prompt prohibition + Phase 9.pre `git status --porcelain` scan for `D ` entries.

10. **Absolute paths in `allowed-tools` grants.** Under the `_shared/` symlink, `Bash(/Users/.../tools/<script>.sh:*)` resolves cleanly. No relative-name + `PATH` fallback needed. Committed state shows `/Users/adammiller/...` literally; `scripts/install.sh` substitutes the current user's `$HOME` into the working tree at install time (no-op for the maintainer), and `scripts/uninstall.sh` reverses it.

11. **Working set lives in-prompt, not shell vars.** Fragment composition (`` !`cat` ``) inlines markdown into a single prompt, so "variables" like `review_id`, `comparison_ref`, `reviewed_files_all` are orchestrator context values, not `$VAR`s. When a later fragment needs an artifact-stored value, call `artifact-read.sh --filter '.foo'` — don't pass it through prose. Run-level vars that don't live in the artifact (`run_id`, `threshold`, `stash_taken`) are surfaced once at the top of the top-level command file.

## Working set (what each phase establishes)

**`/adams-review`** Phase 0 establishes: `review_id` (ULID), `artifact_path` (absolute), `repo_root`, `repo_slug`, `base_branch`, `comparison_ref` (from §13.10 freshness reconciliation — use this, not `base_branch`, for every diff/blame/lens prompt), `reviewed_sha` (post-push), `review_started_at` (ISO-8601 UTC, captured before any push/stash so Phase 1.5's scrape window doesn't race), `mode` (`pr`/`local`), `pr_number`, `trivial_mode`, `reviewed_files_all` (staleness envelope — every file in the diff), `claude_md_paths`, and the three append-only log paths (`trace.md`, `phases.jsonl`, `tokens.jsonl`). `comment_id` is set by Phase 6+ on first POST and persisted into the artifact.

**`/adams-review-fix`** Phase 7 loads the artifact (which carries all of the above) and adds: `run_id` (ULID, `fixrun_<ULID>`), `threshold` (default 60; command arg), `latest_known_sha` (most-recent `fix_attempt.output_sha` OR `reviewed_sha`), `stash_taken` (bool), `input_sha` (pre-edit), `eligible_finding_ids` (pre-filtered per Phase 8 gate), `fix_groups` (from `group-fixes.py`). Phase 9 adds `phase_9a_outcomes`, `overlap_files`, `reverted_groups`, `surviving_groups`, and finally `commit_sha`.

Every helper script receives absolute paths; fragments never assume a cwd. `trace.md` / `phases.jsonl` / `tokens.jsonl` are append-only and keyed off the Phase-0 paths — a logging fragment calls `log-phase.sh` against the known path, never opens its own file handle.

## Helper index

All scripts live under `commands/_shared/tools/`. Grant `Bash(/Users/.../tools/<script>:*)` with absolute paths.

**Readers (safe for any agent):**

| Script | Lang | Purpose |
|---|---|---|
| `artifact-read.sh` | Bash | `jq` wrapper. Flags: `--filter <jq>`, `--finding-id <id>`, `--summary` (emits `counts_by_disposition`). |
| `staleness.sh` | Bash | Phase 7 file-overlap classifier. `git diff --name-only latest_known_sha..HEAD ∩ reviewed_files_all`. |
| `claude-md-paths.sh` | Bash | Walks up from each touched file to repo root; emits deduped CLAUDE.md paths root-first. |
| `origin-crosscheck.sh` | Bash | Phase 1 post-lens. Blame-traces each candidate; forces `pre_existing:high` if fully reachable from `$comparison_ref`; downgrades conflicting lens verdicts. |
| `line-range-check.sh` | Bash | Phase 1 join-step sanity filter. Drops candidates whose `line_range[1]` overshoots the file at `$reviewed_sha` (lens-hallucinated ranges); emits `lens_hallucinated_line_range:` / `lens_referenced_missing_file:` audit lines. Pass-through for `file == "(unknown)"`. |
| `comment-freshness.sh` | Bash | Phase 1.5 post-scrape. Drops bot comments whose referenced code has changed since the comment was posted (§13.13). |
| `repo-slug.sh` | Bash | Canonical `<repo-slug>` derivation. Single source of truth (Operational rule 7). |

**Writers (orchestrator-only):**

| Script | Lang | Purpose |
|---|---|---|
| `artifact-patch.py` | Python | Every finding-level mutation. Mutually-exclusive modes: `--init`, `--add-finding`, `--delete-finding`, `--apply-decisions`, `--apply-fix-start`, `--apply-fix-outcomes`. Finding-modify flags (pair with `--finding-id`): `--set`, `--set-json`, `--append-fix-attempt`. Global: `--dry-run`. Enforces state-transition whitelist + disposition/is_actionable invariants + error-as-prompt. |
| `artifact-publish.sh` | Bash | PR comment POST/PATCH. `--comment-id <id>` for PATCH; no auto-discovery (callers carry intent per §13.4). Local-mode no-op. |
| `artifact-render.py` | Python | `artifact.json` → `artifact.md`. Uses jsonschema validation; reads disposition for section selection. |
| `artifact-validate.sh` | Bash | Thin wrapper around the Python validator. |

**Utilities:**

| Script | Lang | Purpose |
|---|---|---|
| `log-phase.sh` | Bash | Appends `trace.md` + `phases.jsonl`. Every phase fragment calls this. |
| `log-tokens.sh` | Bash | Appends `tokens.jsonl`. Every sub-agent dispatch. |
| `group-fixes.py` | Python | Phase 8 union-find over `files_planned` across eligible findings. Emits `[{id, finding_ids, files_planned}]`. |
| `assign-finding-ids.sh` | Bash | Phase 1 post-join. Monotonic ID assignment over the pooled candidate list. |
| `external-scrape.sh` | Bash | Phase 1.5 PR-comment fetch + bot filter (allow/deny config). |
| `_common.py` | Python | Shared: schema validate, `atomic_write`, `suggest()` (error-as-prompt), exit-code constants. Imported by every Python helper. |

Three `artifact-patch.py` batched modes share a scaffold — see Batched-helper pattern below.

## How to work on new changes

- **Plan mode by default.** Per user's global CLAUDE.md: present plan, get approval, then execute. "Plan-and-execute" requests skip the approval round-trip. Bug fixes can go direct.
- **Blast-radius discipline before committing.** Check every writer, every consumer, parallel code paths, full function bodies, and stale comments. Self-review as if you were a reviewer.
- **Behavior changes land in the fragment + `CLAUDE.md` + smoke.** The archive is frozen — don't update `docs/archive/` to reflect new behavior. If the change is large enough that CLAUDE.md drifts materially from the archive, that's fine: CLAUDE.md is authoritative going forward.
- **New stages get a `plans/stage-N-<name>.md`** drafted in plan mode, user-approved before execution.

## Batched-helper pattern

The three `artifact-patch.py` modes `--apply-decisions` / `--apply-fix-start` / `--apply-fix-outcomes` share a pattern: JSON array of tuples, per-tuple atomic writes, first-failure halt, one summary line. If you add a fourth batched mode, reuse the scaffolding (`_check_*_tuple` validator + `_load_or_fail` per tuple + `_write_and_emit(silent=True)`). Accept that mid-batch failure leaves tuples 0..N-1 persisted; callers re-invoke with the remainder.

## Commits

Imperative mood. Reference the relevant fragment or section where useful (e.g., "Fix Phase 9.pre overlap guard for all-regression case"). Commit at natural breakpoints — one per fragment, one per helper, one per phase — not one giant final commit.

## Archive pointer

`docs/archive/DESIGN.md` (rev 8, 2792 lines) and `docs/archive/BUILD.md` (815 lines) are frozen as of 2026-04-19. Consult them only when CLAUDE.md doesn't cover what you need — typically the rationale behind a historical decision. Useful greps:

```bash
grep -n '^## '         docs/archive/DESIGN.md        # section index (~30 lines)
grep -n '^### 13\.1 '  docs/archive/DESIGN.md        # jump to §13.1 score decision table
grep -n '^### 19\.'    docs/archive/DESIGN.md        # sub-agent prompt sketches
grep -n '^### 21\.'    docs/archive/DESIGN.md        # per-helper algorithmic sketches
grep -n '2026-04-18'   docs/archive/BUILD.md         # everything that happened that day
grep -n 'Stage 2\.5'   docs/archive/BUILD.md         # rationale for the hardening stage
```

Read one section at a time (e.g., `Read docs/archive/DESIGN.md offset=1142 limit=70` for §13.1). The file is a reference manual; reading it sequentially wastes context.
