# CLAUDE.md — operational guide for adamsreview

Read this first on a fresh session. It's procedural (how to work in the repo) plus a compact reference for the pipeline shape, finding state model, score gates, and helper inventory — enough to work without opening the archive.

**Context discipline.** This file is self-contained for routine work. `docs/archive/DESIGN.md` (rev 8, frozen 2026-04-19) and `docs/archive/BUILD.md` are unmaintained historical references — consult them only when you need the rationale behind a specific past decision. Fragment-level `per §X.Y` citations still grep-resolve under the archive path. The schema (`bin/schema-v1.json`) is the source of truth for artifact shape — read it directly.

## What this repo is

Build repo for five personal Claude Code slash commands, packaged as a plugin (`adamsreview`) distributable via `/plugin marketplace add`:

- **`/adamsreview:review`** — multi-lens code review of a branch or PR (Phases 0–6).
- **`/adamsreview:add`** — inject externally-sourced findings (cloud `/ultrareview` paste, Opus once-over, manual finds, etc.) into the most recent review's existing artifact. Free-form paste mode dispatches a Sonnet normalizer; structured `--file/--line/--claim` mode skips the normalizer; one Sonnet dedup pass against existing findings; Phase 4 validation lane-aware (Opus deep / Sonnet light) without Wave 2; re-renders + re-publishes to the existing PR comment.
- **`/adamsreview:walkthrough [threshold]`** — interactive driver that walks the reviewer through findings `/adamsreview:fix` would skip, restricted to those with effective score (`COALESCE(score_phase4, score_phase3, -1)`) ≥ `$threshold` so low-signal findings don't pad the session. The threshold is a walkthrough-local score floor (default 60) and is decoupled from `/adamsreview:fix`'s threshold — promoted findings are picked up at any fix threshold via the `human_confirmation` bypass. Preflight offers a two-tier scope choice (default **Qualifying** — excludes Phase-3-demoted `below_gate`; **Full skip set** adds them back; note that `below_gate` findings only surface in Full when the threshold is low enough to admit their `score_phase3`). `pre_existing_report` findings are always excluded from both walk tiers and not score-floored; they are routed exclusively to the end-of-run issue-filing phase (one-by-one draft/confirm/edit flow that calls `gh issue create`). Per-finding Sonnet briefing with an "Edit the fix hint" override path; for `confirmed_manual` / `confirmed_report` the briefer proposes best-effort hints. Closes the light-lane `confirmed_mechanical` gap where the default Phase 8 lane filter skips mechanically-fixable ux/policy findings.
- **`/adamsreview:fix`** — automated fix loop for auto-fixable findings (Phases 7–9).
- **`/adamsreview:promote`** — human override that promotes a single finding to auto-fixable, bypassing the Phase 8 impact_type lane filter and score threshold. Metadata-only; run `/adamsreview:fix` afterwards to apply. Used internally by `/adamsreview:walkthrough` via `fragments/promote-core.md` + `--defer-publish`.

The original four are **built and in production use** as of 2026-04-19 (Stages 1, 2, 2.5, 2.6, 2.7, 2.8, 3 closed; walkthrough closed on branch `walkthrough-mode`). `/adamsreview:add` was added on branch `review-add` (plan: `plans/review-add.md`). Plugin conversion (repackaging as a Claude Code plugin, D18 namespacing from `/adams-review-<stem>` to `/adamsreview:<stem>`) landed on branch `plugin-conversion` (plan: `plans/plugin-conversion-execution.md`). Stage 4 (fragment shrink — manifest-style command bodies, helper extractions, prose compression) closed 2026-04-23 on branch `stage-4-fragment-shrink` (plan: `plans/stage-4-fragment-shrink.md`; execution journal: `plans/stage-4-fragment-shrink-execution.md`). All original-roadmap scope is now executed; forward-looking work lives in `plans/backlog.md`.

**Recommended flow on a non-trivial PR:** `/adamsreview:review` → (optional) `/adamsreview:add` to inject parallel-review findings → `/adamsreview:walkthrough` (optional) → `/adamsreview:fix`. Each command is independent; `/adamsreview:promote` remains useful for one-off manual promotions outside the walkthrough.

## Pipeline shape

```
/adamsreview:review [--ensemble]
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
├── Phase 3 — Cheap scoring + gate (chunked-batch Sonnet err-up rubric, ≤25
│              candidates per chunk-agent; ≥2 families auto-graduate; logs
│              demote_rate + score_phase3_histogram to phases.jsonl for #24 calibration)
├── Phase 4 — Validation (deep Opus per candidate for correctness/security —
│              one Agent per finding, structurally enforced by `--apply-decisions
│              --expected $N`; light Sonnet confirmation for ux/policy/architecture
│              via chunked-batch chunk-agents, ≤25 per chunk)
├── Phase 5 — Cross-cutting review (deep-lane only; dispatched Opus sub-agent)
└── Phase 6 — Finalize (phases.jsonl, tally-subagent-tokens.sh → subagent_tokens,
               orchestrator-tokens.sh → orchestrator_tokens, artifact write,
               render, PR comment POST)

/adamsreview:fix [threshold]
├── Phase 7 — Load artifact; leftover-attempted abort; clean-tree gate; staleness check
├── Phase 8 — Per-fix-group agents edit working tree (no git ops);
│              each group reports files_modified + files_created
└── Phase 9 — Post-fix Opus review pre-commit; aggregate outcomes per group;
              revert regression groups (checkout modified, rm created);
              re-tally subagent_tokens + orchestrator_tokens; commit surviving groups with outcome
              in message; push; append fix_attempts
              (on 9.pre overlap: offer reconcile | abort | inspect — reconcile
               dispatches one Opus merge agent, collapses fix_groups to FG-RECON
               in memory, then runs Phase 9a/9b/9c unchanged; original
               fix_group_id preserved per-finding in fix_attempts)

/adamsreview:add [<paste...>] [--file path --line N --claim "..."] [--impact <type>] [--no-dedup]
└── Locate artifact (latest.txt) → leftover-attempted gate → build candidates
    (paste-normalizer Sonnet | structured one-shot | mixed) → dedup against
    existing findings (Sonnet, one-direction) → assign IDs continuing past
    max existing F-id (assign-finding-ids.sh --start-from) → --add-finding loop →
    Phase 4 validation lane-aware, NO Wave 2 (Opus deep one-per-candidate /
    Sonnet light chunked-batch ≤25/chunk) → --apply-decisions --expected $N →
    §13.1 pre-existing override re-assertion →
    re-tally subagent_tokens + orchestrator_tokens → re-render →
    re-publish to existing comment_id → trace + summary
```

Every lifecycle command re-tallies two sibling fields before its final
re-render so the published PR comment reflects cumulative spend across
the full review → fix / add / walkthrough arc:

- **`subagent_tokens`** — rolled up from `tokens.jsonl` (every
  dispatched sub-agent's cost). Captures Phase 1 lenses, Phase 4
  validators, Phase 8 fix groups, Phase 9 post-fix reviewer, etc.
- **`orchestrator_tokens`** — rolled up from the Claude Code session
  transcript(s) under `~/.claude/projects/<cwd-slug>/` (main-session
  `message.usage` per assistant turn, filtered by timestamp ≥
  `review_started_at`). Captures what `subagent_tokens` deliberately
  excludes: the orchestrator's own per-turn spend, which is what the
  statusline's live `ctx:` badge is measuring the depth of. **Opt-in
  via `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1`** — defaults to skip because
  the transcript scan trips the macOS Sequoia/Tahoe "access data from
  other apps" prompt (Claude Code marks every transcript with the
  `com.apple.provenance` xattr). When opted out, the helper exits 0
  with a `skipped` stdout line and leaves the artifact field absent;
  the renderer omits the line cleanly. See README §"Token counts" for
  the user-facing rationale and the FDA + env-var enable path.

The two are non-overlapping (sub-agent internal API calls vs.
main-session turns). Four separate orchestrator counters — fresh
input / output / cache-read / cache-creation — are preserved in the
artifact because their $/token pricing differs by roughly an order of
magnitude, but only two (output + fresh input) surface in the rendered
PR-comment line: cache-read and cache-creation are prompt-cache
plumbing, not user-facing signal. All four remain in
`artifact.orchestrator_tokens` for offline cost analysis.

`/adamsreview:walkthrough` re-tallies both before §6.1's re-publish;
issue-filer agents dispatched in §6.5 (and the orchestrator turns that
dispatch them) land in the logs/transcript after the tally, so their
cost surfaces on the next lifecycle command's tally.

**Orchestrator-tokens over-count modes (v1 accepted, opted-in only).**
When `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1` is set, the time-window
filter (`timestamp >= review_started_at`) counts every assistant turn
in any transcript under `~/.claude/projects/<cwd-slug>/`, regardless
of whether it belongs to this review. Clean cases: review → fix
back-to-back; review → new review on the updated codebase (each new
review's `review_started_at` excludes the prior arc). Over-count
cases: any unrelated session or unrelated same-session chat in the
same cwd between `review_started_at` and the tally's invocation.
Sub-agent tokens are unaffected (their log is per-review-id, not
cwd-wide). When opted out (the default) there is no over-count *or*
under-count from this filter — the field stays absent and only any
prior opted-in value survives. See `bin/orchestrator-tokens.sh`
header for the full caveat list; `plans/orchestrator-tokens.md`
§"Known limitations" for why the time-window filter was accepted
over a `SessionStart`-hook-based fix.

**Stale-data preservation across opt-in toggles.** Skip on opt-out
deliberately does not wipe a previously-written `orchestrator_tokens`
value. So an opted-in `/adamsreview:review` followed by an opted-out
`/adamsreview:fix` will publish the cumulative-cost line with the
review-time value, not a refreshed one — the rendered number can
lag actual spend. Re-opt-in on the next lifecycle command refreshes.

## Finding state model

Three states, one disposition enum. States transition; dispositions classify.

**States:** `open` | `attempted` | `resolved`. Valid transitions (enforced by `artifact-patch.py`):

```
open → attempted       (Phase 8 ran)
attempted → resolved   (Phase 9 verified)
attempted → open       (Phase 9 classified partial or regression)
```

Any other transition is rejected. Leftover `attempted` on a fresh `/adamsreview:fix` → **hard abort** with deterministic recovery message.

**Disposition enum** (the primary routing key — filters and report selectors read this, not combinations of prose fields):

| disposition | Meaning | `current_state` | `is_actionable` | Set by |
|---|---|---|---|---|
| `below_gate` | `score_phase3 < 45` and single source family | `open` | `false` | Phase 3 |
| `pending_validation` | Gate-in parking; awaiting Phase 4 | `open` | `false` | Phase 3 |
| `disproven` | `score_phase4 < 45` | `open` | `false` | Phase 4 |
| `uncertain` | `score_phase4 45–59` | `open` | `false` | Phase 4 |
| `confirmed_mechanical` | `score_phase4 ≥ 60`, deep lane, `actionability == auto_fixable` | `open` | `true` | Phase 4 |
| `confirmed_manual` | `score_phase4 ≥ 60`, `actionability == manual` | `open` | `false` | Phase 4 |
| `confirmed_report` | `score_phase4 ≥ 60`, `actionability == report_only` | `open` | `false` | Phase 4 |
| `pre_existing_report` | `origin == pre_existing` AND `origin_confidence == high` (normative override, regardless of score) | `open` | `false` | Phase 1 / re-asserted Phase 4 |
| `partial` | Phase 9 found fix incomplete; retry-eligible | `open` | `true` | Phase 9 |
| `regression` | Phase 9 found new adjacent issue; group was reverted; retry-eligible | `open` | `true` | Phase 9 |
| `resolved` | Phase 9 verified | `resolved` | `false` | Phase 9 |

**Invariants** (enforced by writers):

- `is_actionable` is derived: `true` iff `disposition ∈ {confirmed_mechanical, partial, regression}`. Never set it directly in conflict with `disposition`.
- `current_state == resolved` ⇔ `disposition == resolved`.
- `human_confirmation` is absent/null unless `/adamsreview:promote` has run. Present-and-non-null is a Phase 8 bypass of both the lane filter and the threshold (see Score gates below). Promotion never mutates `score_phase4` — the validator's honest score is preserved for audit.

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
                         auto_fixable  → confirmed_mechanical   (is_actionable: true)
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

**Phase 8 fix gate** (the combination that governs what `/adamsreview:fix` will touch):

```
current_state == open
  AND disposition ∈ {confirmed_mechanical, partial, regression}
  AND (
    human_confirmation != null                                      // promote bypass
    OR (
      impact_type ∈ {correctness, security}                         // lane filter
      AND score_phase4 >= threshold                                 // default 60
    )
  )
```

**Threshold summary.** Validation gate (Phase 3) is constant 45. Confirmation decision (Phase 4) has breakpoints at 45, 60, 75. Fix gate (Phase 8) defaults to 60 and is user-tunable via `/adamsreview:fix <N>`. `human_confirmation != null` bypasses both the lane filter and the threshold — promotion is additive metadata, not a state mutation.

**Gate terminology.** "Gate" means three different things in this repo and the distinction matters when reading command output or debugging a scope filter:

- **Phase 3 scoring gate (45)** — the threshold that decides which candidates enter Phase 4 validation. Candidates below it get `disposition=below_gate` and carry no `score_phase4`.
- **Phase 4 confirmation gate (45/60/75)** — the thresholds that map `score_phase4` into `disproven` / `uncertain` / `confirmed_*` dispositions.
- **Phase 8 fix gate (default 60)** — the composite gate governing `/adamsreview:fix`: disposition ∈ {confirmed_mechanical, partial, regression} **AND** deep lane **AND** `score_phase4 ≥ threshold`, with `human_confirmation` as the human-override bypass.

`below_gate` is a *disposition name* (Phase 3), not a threshold. `/adamsreview:walkthrough` at its default **Qualifying** scope excludes `below_gate` findings because Phase 3 already judged them low-impact × low-confidence; the **Full skip set** scope adds them back — subject to the walkthrough score floor, which at default `$threshold=60` will exclude them anyway (their `score_phase3` is by definition <45). A reviewer who wants to sanity-check what Phase 3 demoted should run `/adamsreview:walkthrough 0` (or any floor below the demoted finding's `score_phase3`) along with picking the Full tier.

## Lanes

- **Deep lane** (correctness, security): Phase 4a Opus per candidate with blast-radius tracing and a comprehensive fix proposal; passes through Phase 5 cross-cutting review. Phase 8 processes `confirmed_mechanical` findings here by default.
- **Light lane** (ux, policy, architecture): Phase 4b Sonnet confirmation, report-first by default. Phase 8's lane filter excludes light-lane `confirmed_mechanical` unless `human_confirmation != null` (set by promote or walkthrough).

That asymmetric default is what `/adamsreview:walkthrough` exists to close — the walkthrough scope is every finding the Phase 8 filter would skip, further restricted by the walkthrough's own score floor (`$threshold`, default 60) so the session stays on high-signal items. The walkthrough floor is independent of the fix-gate threshold; promotions land regardless.

## Layout

```
adamsreview/
├── CLAUDE.md                       ← this file
├── README.md                       ← setup + layout + recommended flow (user-facing)
├── .claude-plugin/
│   ├── plugin.json                 ← plugin manifest (name, version, keywords, repo)
│   └── marketplace.json            ← single-plugin marketplace (source: "./")
├── .gitattributes                  ← LF enforcement for *.sh / *.py / *.json / *.md
├── docs/
│   └── archive/                    ← frozen historical docs (not maintained)
│       ├── README.md               ← frozen-as-of banner
│       ├── DESIGN.md               ← rev 8 normative design (historical)
│       └── BUILD.md                ← stage-by-stage build journal (historical)
├── plans/                          ← per-stage plans (all original-roadmap stages closed:
│                                     1–3 + 2.5/2.6/2.7/2.8, plugin-conversion,
│                                     post-plugin-improvements, stage-4-fragment-shrink).
│                                     Forward-looking work lives in `plans/backlog.md`;
│                                     chronological idea log + DONE markers live in
│                                     `plans/post-conversion-ideas.md`.
├── commands/                       ← bare-stem command files (D18 namespacing)
│   ├── review.md                   ← /adamsreview:review     (Phases 0–6)
│   ├── add.md                      ← /adamsreview:add        (inject external findings)
│   ├── walkthrough.md              ← /adamsreview:walkthrough (interactive)
│   ├── fix.md                      ← /adamsreview:fix        (Phases 7–9)
│   └── promote.md                  ← /adamsreview:promote    (metadata promote)
├── fragments/                      ← shared phase fragments + prompt references
│   ├── 00-preflight.md … 10-post-fix-and-commit.md   ← phase fragments
│   ├── _prelude-shared.md          ← shared startup rules loaded by every command (operational rules + error conventions)
│   ├── promote-core.md             ← shared precondition + patch (promote + walkthrough)
│   └── lens-{ux,security}-reference.md
├── bin/                            ← helper scripts (auto-added to $PATH by plugin runtime)
│   ├── include                     ← wrapper for `!include <fragment>.md` transclusion
│   ├── schema-v1.json              ← artifact shape (source of truth)
│   └── (helpers: see Helper index below)
├── hooks/
│   ├── hooks.json                  ← SessionStart registration
│   └── dep-check.sh                ← SessionStart dep warning (soft, never fails)
├── scripts/
│   └── dev-run.sh                  ← `claude --plugin-dir` wrapper for plugin-author iteration
└── test/
    ├── smoke.sh                    ← 204-assertion harness
    └── fixtures/
```

Plugin users install via `/plugin marketplace add adamjgmiller/adamsreview` + `/plugin install adamsreview@adamsreview` in Claude Code — no symlinks, no install script. Plugin authors iterate with `scripts/dev-run.sh` (loads the working tree as a plugin via `claude --plugin-dir "$(pwd)"`). Adding a new top-level command means dropping `commands/<stem>.md` at bare-stem path (no `adamsreview-` prefix — namespacing lives in the plugin name); post-install invocation is automatically `/adamsreview:<stem>`. See README §Installation for the end-user flow.

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
| Windows | — | Install [Git for Windows](https://git-scm.com/downloads/win) — Claude Code auto-routes `#!/usr/bin/env bash` helpers through Git Bash (bash 5+). `CLAUDE_CODE_GIT_BASH_PATH` overrides the discovery path if Git Bash lives in a non-default location. |

Reviews root: `~/.adams-reviews/<repo-slug>/<branch>/<review_id>/`. Override with `$ADAMS_REVIEW_REVIEWS_ROOT`.

## Operational rules

Enough to work without opening the archive. Each rule is a decision that was learned the hard way.

1. **Bash 3.2 portable.** Helpers run under macOS `/bin/bash` 3.2 in practice. Avoid `declare -A`, `mapfile`/`readarray`, `${var,,}`. `awk '!seen[$0]++' | sort` beats associative arrays for dedup. `set -euo pipefail` and process substitution are fine.

2. **uv shebang for Python helpers.** `#!/usr/bin/env -S uv run --script` with a `# /// script` inline dep spec. Never `pip install` directly (PEP 668 blocks it on Homebrew Python 3.12+).

3. **Exit codes are a contract.** Python helpers: `0=OK, 1=validation, 2=invalid-transition, 3=dry-run-invalid, 4=unexpected, 5=missing-dep, 6=expected-mismatch (--apply-decisions tuple count != --expected; recover by re-dispatch), 64=usage`. Defined in `bin/_common.py`; reuse, don't invent.

4. **Error-as-prompt on every helper.** Non-zero exits emit `ERROR:` / `Valid input:` / `Did you mean:` / `Action:` stderr sections. No stack traces on expected errors. See `bin/_common.py:suggest()`.

5. **Atomic writes.** Writers go tmp-file → `rename` (see `bin/_common.py:atomic_write`). The on-disk artifact is never in an invalid state mid-run.

6. **Reviews root is `~/.adams-reviews/`, not `~/.claude/reviews/`.** Claude Code hardcodes a sensitive-file prompt on writes to `~/.claude/` that survives `bypassPermissions` mode. Overridable via `$ADAMS_REVIEW_REVIEWS_ROOT`.

7. **`repo_slug` comes from one helper.** `bin/repo-slug.sh --repo-root <path>` is the single source of truth. Phase 0 and Phase 7 both call it. Never reimplement inline.

8. **Commit messages via `git commit -F <file>`, not `-m "$(…)"`.** Finding claims can contain quotes/backticks/newlines. Temp-file message bodies sidestep the whole escape surface.

9. **Fix-group agents may not delete or rename files.** Layered enforcement: prompt prohibition + Phase 9.pre `git status --porcelain` scan for `D ` entries.

10. **Bare-name grants in `allowed-tools`.** The plugin runtime puts `bin/` on `$PATH` automatically, so `Bash(<script>.sh:*)` resolves cleanly — no absolute paths, no `$HOME` substitution, no user-specific rewrite at install time. Helper invocations in command bodies and fragments also use bare names (`artifact-read.sh --filter '.foo'`, not `~/.claude/...`). Post-Stage-4, fragments are Read-loaded via manifest-style directives, not the `!include` preprocessor — no top-level command currently grants `Bash(include:*)`. `bin/include` remains available for any future small, size-safe transclusion (<~10 KB given Claude Code's post-v2.1.2 persist-to-disk threshold; see `plans/stage-4-fragment-shrink.md` Appendix A); adding back an `!include` site requires reinstating the grant on the relevant command.

11. **Working set lives in-prompt, not shell vars.** Fragments are Read-loaded into the orchestrator prompt as inline markdown (per rule 10), so "variables" like `review_id`, `comparison_ref`, `reviewed_files_all` are orchestrator context values, not `$VAR`s. When a later fragment needs an artifact-stored value, call `artifact-read.sh --filter '.foo'` — don't pass it through prose. Run-level vars that don't live in the artifact (`run_id`, `threshold`, `stash_taken`) are surfaced once at the top of the top-level command file.

## Working set (what each phase establishes)

**`/adamsreview:review`** Phase 0 establishes: `review_id` (ULID), `artifact_path` (absolute), `repo_root`, `repo_slug`, `base_branch`, `comparison_ref` (from §13.10 freshness reconciliation — use this, not `base_branch`, for every diff/blame/lens prompt), `reviewed_sha` (post-push), `review_started_at` (ISO-8601 UTC, captured before any push/stash so Phase 1.5's scrape window doesn't race), `mode` (`pr`/`local`), `pr_number`, `trivial_mode`, `reviewed_files_all` (staleness envelope — every file in the diff), `claude_md_paths`, and the three append-only log paths (`trace.md`, `phases.jsonl`, `tokens.jsonl`). `comment_id` is set by Phase 6+ on first POST and persisted into the artifact.

**`/adamsreview:fix`** Phase 7 loads the artifact (which carries all of the above) and adds: `run_id` (ULID, `fixrun_<ULID>`), `threshold` (default 60; command arg), `latest_known_sha` (most-recent `fix_attempt.output_sha` OR `reviewed_sha`), `stash_taken` (bool), `input_sha` (pre-edit), `eligible_finding_ids` (pre-filtered per Phase 8 gate), `fix_groups` (from `group-fixes.py`). Phase 9 adds `phase_9a_outcomes`, `overlap_files`, `reverted_groups`, `surviving_groups`, and finally `commit_sha`.

Every helper script receives absolute paths; fragments never assume a cwd. `trace.md` / `phases.jsonl` / `tokens.jsonl` are append-only and keyed off the Phase-0 paths — a logging fragment calls `log-phase.sh` against the known path, never opens its own file handle.

## Helper index

All scripts live under `bin/`. The plugin runtime adds `bin/` to `$PATH` on load, so `allowed-tools` grants and in-body invocations both use bare names: `Bash(<script>:*)` / `<script> --flag ...`.

**Readers (safe for any agent):**

| Script | Lang | Purpose |
|---|---|---|
| `artifact-read.sh` | Bash | `jq` wrapper. Flags: `--filter <jq>`, `--finding-id <id>`, `--summary` (emits `counts_by_disposition`). |
| `staleness.sh` | Bash | Phase 7 file-overlap classifier. `git diff --name-only latest_known_sha..HEAD ∩ reviewed_files_all`. |
| `claude-md-paths.sh` | Bash | Walks up from each touched file to repo root; emits deduped CLAUDE.md paths root-first. |
| `origin-crosscheck.sh` | Bash | Phase 1 post-lens. Blame-traces each candidate; forces `pre_existing:high` if fully reachable from `$comparison_ref`; downgrades conflicting lens verdicts. When the target file is PR-added (no `$comparison_ref:$file`), walks `git log --follow` to the pre-rename / pre-extraction ancestor and re-checks: if every blame SHA is either an ancestor of `$comparison_ref` or one of the file-add commits (content-preserving extraction — F038 case), forces `pre_existing:high`; PR-added lines inside an extracted file still respect the lens (`rename-follow-but-lines-modified-in-pr`). Genuinely-new files (no rename ancestor) keep the `reason=new-file` respect-lens path. |
| `line-range-check.sh` | Bash | Phase 1 join-step sanity filter. Drops candidates whose `line_range[1]` overshoots the file at `$reviewed_sha` (lens-hallucinated ranges); emits `lens_hallucinated_line_range:` / `lens_referenced_missing_file:` audit lines. Pass-through for `file == "(unknown)"`. Complements the file-absolute `line_range` invariant in `fragments/01-detection.md` §1.2.1 (preventive prompt-level rule + corrective runtime filter). |
| `comment-freshness.sh` | Bash | Phase 1.5 post-scrape. Drops bot comments whose referenced code has changed since the comment was posted (§13.13). |
| `prior-fix-diff.sh` | Bash | Phase 1 L2 input. Deterministic prior-fix suspect scan: walks `git log -L` per hunk in the PR diff, filters to fix-intent commit subjects whose SHAs are ancestors of `$comparison_ref` (excluding the PR's own internal fix commits), emits a JSON array of suspect records for L2's prompt to judge as reverts. |
| `repo-slug.sh` | Bash | Canonical `<repo-slug>` derivation. Single source of truth (Operational rule 7). |
| `trivial-check.sh` | Bash | Phase 0.11 trivial-diff classifier (§13.9). Reads newline-separated file list from stdin + `--num-files` + `--lines-changed`; emits `{trivial_mode, reason}` with `reason ∈ {docs_only, null}` (only `docs_only` implemented — other enum members reserved for future expansion). Vacuously trivial on empty stdin + zero counts, matching the pre-extraction inline fragment. The orchestrator-side `force_full=true` short-circuit stays in `fragments/00-preflight.md` step 0.11 (helper has no knowledge of `force_full`). |
| `artifact-seed.sh` | Bash | Phase 0.15 initial-artifact seed builder. Takes Phase-0 outputs as flags (`--review-id`, `--review-started-at`, `--reviewed-sha`, `--base-branch`, `--head-branch`, `--mode`, `--pr-state`, `--pr-number`, `--comment-id`, `--trivial-mode`, `--base-context <json>`, `--reviewed-files-all <newline-sep>`, `--claude-md-paths <newline-sep>`, `--files-changed`, `--lines-changed`) and emits the schema-shaped seed JSON on stdout. Pipe to `artifact-patch.py --init -` for persistence. Seeds `reviewer_sources: ["internal"]`, `generated_at = review_started_at`, empty `findings` / `cross_cutting_groups`, zeroed `subagent_tokens`, nulled `metrics`. Nullable flags (`--pr-state`, `--pr-number`, `--comment-id`) accept empty string → JSON null. The §13.10 `base_context` sub-object is still built via `jq -n` in the fragment (preserves explicit null-handling for offline paths) and passed as a single JSON string. Pure output helper — no on-disk mutations; `--init` is what writes. |
| `parse-with-repair.py` | Python | Stdin-to-stdout tolerant JSON parser. Layers: strict `json.loads` → fence-strip → `json-repair` → fence-strip+repair. Exit 0 = clean JSON on stdout, exit 1 = unrecoverable with error-as-prompt stderr. Foundation for the two normalizers below; used at the ensemble-adapter normalizer boundary (messiest external-tool output). |
| `parse-validator-result.py` | Python | Canonicalizes Phase 4 validator output to `{score_phase4, actionability, confirmed_strength, decision, notes, validation_result, related_candidates_to_investigate}`. Handles shape drift: `{score_phase4}`, `{score:{correctness}}`, `{overall_numeric}` (1-5), `{severity: low/medium/high}`, ambiguous `{score: N}` (heuristic 1-5 / 1-10 / pass-through). `--lane deep\|light`. Exit 2 = score unrecoverable (caller routes to `uncertain` with `score_phase4: null`). Uses `parse-with-repair.py` internally. Deep-lane `validation_result` is schema-checked against `bin/schema-v1.json#/$defs/validation_result` after any top-level lift; drift (missing sub-objects, alternative keys, malformed `blast_radius`, etc.) drops `validation_result` to `null` with a "shape unrecoverable" note so the downstream `--apply-decisions` batch doesn't halt on one drifted tuple. |
| `source-family-map.py` | Python | Maps lens-emitted `source_family` to canonical (eight families: diff, structural, policy, ux, security, holistic, external-deep, external-add — the last emitted by `/adamsreview:add`). `--input <raw>` → canonical on stdout (exit 0) or `UNKNOWN_FAMILY:` on stderr (exit 3). Phase 1 join-step uses exit 3 to tag the candidate `source_family: "unknown"` + log drift — preserves the finding rather than silently dropping it. |

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
| `freshness-gate.sh` | Bash | Phase 0.2a base-branch freshness reconciliation. Detects remote, fetches (30s soft timeout), computes behind_count; emits JSON `{comparison_ref, base_freshness, remote_sha, behind_count, preflight_warnings[]}` with `base_freshness ∈ {fresh, fast_forwarded, used_remote_ref, proceeded_stale, no_remote, no_fetch, pending_user_gate}`. `pending_user_gate` signals the orchestrator to dispatch `AskUserQuestion` and re-invoke with `--after-choice <a|b|c>`; the helper then applies the chosen side-effect (fast-forward / used_remote_ref / proceeded_stale) and re-emits terminal JSON. Non-FF on (a) re-emits pending with `ff_available: false` so the orchestrator re-asks with only (b)/(c)/(d). |
| `tally-subagent-tokens.sh` | Bash | Rolls `tokens.jsonl` into `subagent_tokens` on the artifact. Pure readback, idempotent. Called at Phase 6 finalize and before each lifecycle command's final re-render so the published total stays cumulative across review → fix / add / walkthrough. |
| `orchestrator-tokens.sh` | Bash | Rolls Claude Code session transcripts under `~/.claude/projects/<cwd-slug>/` into `orchestrator_tokens`. Complements `tally-subagent-tokens.sh` by capturing the main-session per-turn spend that `subagent_tokens` deliberately excludes (§11). **Opt-in via `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1`** (default skip — the transcript scan trips the macOS Sequoia/Tahoe "access data from other apps" prompt because Claude Code marks transcripts with the `com.apple.provenance` xattr; opt-out exits 0 with a `skipped` stdout line and leaves the artifact untouched, preserving any prior opted-in value). Slug algorithm is `tr '/.' '-'` (both chars map to `-`). `--since` filters by assistant-line timestamp; when opted in, v1 accepts soft over-count modes from unrelated same-cwd sessions or intermission chat between lifecycle commands. |
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
