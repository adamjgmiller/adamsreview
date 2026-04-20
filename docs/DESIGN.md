# Code review command redesign — plan

> **Reference manual — do not read end-to-end.** This file is ~2400 lines and is consulted by anchor, not by reading from the top. Entry point for routine work is `CLAUDE.md`; the `commands/_shared/` fragments cite specific sections (e.g. "per §13.1") when behavior depends on them. To navigate:
> ```bash
> grep -n '^## '       docs/DESIGN.md     # ~30-line section index
> grep -n '^### 13\.1 ' docs/DESIGN.md    # jump to §13.1
> ```
> The revision notes below are history; current behavior lives in the numbered sections.

**Author:** Adam (with Claude)
**Date:** 2026-04-17 (rev 8 — implementation-language split)
**Status:** Draft for review

**Revision notes.** Rev 1 established the pipeline split. Rev 2 incorporated the first round of outside review (two-lane pipeline, fix groups, orchestrator-owned git, artifact hardening). Rev 3 incorporated a second round (unified `findings[]` state model, finer-grained routing, explicit score decision table, chunked PR comments, file-overlap staleness check, source-family auto-graduation, Phase 9 pre-commit, helper-script error-as-prompt, per-review observability). Rev 4 was a simplification pass: persistence local-only, state machine collapsed to three states, dedup LLM-only, `/adams-ensemble-review` collapsed, phase snapshots consolidated, `fix_runs[]` / `disproven_fingerprints[]` / `capture_transcripts` / deterministic tests dropped, ten rev-3 consistency issues fixed. Rev 5 applied the rev-4 review pass: Phase 5 and Phase 9 made explicit Opus sub-agents; CLAUDE.md path lister became a deterministic Bash helper; `score_phase3` / `score_phase4` cached on findings; `<repo-slug>` derivation and PR-comment edit marker specified; external-reviewer orchestration-token tracking clarified; `allowed-tools` absolute-path grant validation note added; Phase 8 eligibility tightened to deep-lane-only for v1; new Phase 1.5 external PR-comment scrape. Rev 6 addresses the rev-5 outside-review pass: (a) **trust-boundary fixes** — per-group revert at Phase 9 (regression groups never commit; all-regression is a degenerate case), clean-tree gate on `/adams-review-fix`, stable `<!-- adams-review-v1 -->` marker + persisted `comment_id` so fresh reviews on the same PR replace the prior comment, `review_started_at` captured before push to close the Phase 1.5 scrape-window race; (b) **disposition enum** — machine-readable classifier orthogonal to `current_state`, replaces free-form `reason` parsing for reporting/filtering; (c) **pre-existing hard rule** — high-confidence `origin: pre_existing` → `disposition: pre_existing_report` regardless of score; (d) **reviewed_files_all** for staleness envelope (distinct from per-finding file list); (e) narrow Bash-only trivial-diff early exit for doc/config-only PRs; (f) schema, report math, directory-layout, and open-question fixes from the rev-5 consistency cluster. Rev 7 applies the rev-6 outside-review pass — purely execution-contract tightening, no architecture changes: (1) **leftover-`attempted` hard abort** with deterministic recovery message (replaces rev-6's "resolved manually" wording in §5.2; adds an explicit Phase 7 pre-check step); (2) **disposition standardized** in every summary / diagnostic / post-mortem surface — `phases.jsonl` now emits `counts_by_disposition`, `artifact-read --summary` aligned, §14.2 evaluation text swapped from `reason` to `disposition`; (3) **trivial mode is review-only in v1** — trivial-mode correctness candidates pass through Phase 4b but are never Phase-8-eligible, stated normatively in §13.9 and §19.6; (4) **§19.8 Output schema** corrected to match the `files_modified`/`files_created` contract Phase 9b depends on; (5) **deletes/renames forbidden** in v1 fix agents; (6) **actual-touched-file overlap guard** across fix groups before revert/commit; (7) **deterministic terminal cleanup** — once a commit exists, `fix_attempts.output_sha` is recorded *before* push or publish can fail, with the symmetric rule for no-commit runs (regression outcome recorded to `fix_attempts` with `output_sha: null` before surfacing); (8) small contract fixes — `artifact-publish.sh --mode local` no longer duplicates `latest.txt` writes, `fix_group_id` scoped to `run_id`; (9) two new structural sections — **§25 Orchestrator working set** (variables every fragment must carry) and **§26 Worked mixed-outcome example** (end-to-end walk of a regression-reverted + verified mixed run).

Rev 8 is a pre-build implementation-language split, no behavioral changes: the two JSON-heavy helpers (`artifact-patch` and `artifact-render`) are renamed to `.py` to reflect that they'll be implemented in Python (for robust JSON manipulation and schema validation), while the shell-heavy helpers (`artifact-init.sh`, `artifact-publish.sh`, and error-as-prompt wrappers) stay as Bash. All interfaces, flags, and behaviors are unchanged — only the filename extensions and the `allowed-tools` grants reflect the language split.

---

## 1. Problem statement

Adam reviews code only via agentic tools (no human review) and currently uses a single monolithic slash command `/adams-code-review` that performs review and fix in one run. Two chronic problems:

1. **Missed bugs.** Real bugs get scored too low by a single-pass scorer, drop below the fix threshold, and never surface. Adam runs reviews repeatedly against the same PR before it feels clean.
2. **Incomplete fixes.** When the tool does fix something, the fixes frequently:
   - Address one site while missing an equivalent pattern elsewhere in the codebase
   - Introduce a new bug adjacent to the fix (blast-radius miss)
   - Are only partial (the root cause lives deeper than the fix went)

These aren't symmetrical — the "incomplete fixes" failure mode is the dominant complaint, and it means the solution is less about "detect more bugs" and more about "validate and fix bugs correctly and comprehensively."

A secondary goal: split the monolith so review and fix can be run separately — typically in the same session (review, inspect, then decide whether to fix), but the artifact is also persisted on disk so you could come back later.

---

## 2. Current architecture (in one paragraph)

`/adams-code-review` is an 8-step command: parse args and detect PR/local mode, list CLAUDE.md paths, summarize change, fan out 6 parallel Opus review agents, score each issue with a Sonnet agent (0–100), fix issues scoring ≥45 with per-file Opus fix agents, recheck eligibility, and post a formatted report. Review and fix are coupled in a single run; there is no persistence of review state between sessions.

---

## 3. What's changing — high-level

### 3.1 Two commands

| Command | Purpose | Args |
|---|---|---|
| `/adams-review` | Run the review pipeline. Pass `--ensemble` to additionally include external reviewers (Codex, CodeRabbit) in the candidate pool. Persist a structured artifact locally. | `[--ensemble]` |
| `/adams-review-fix [threshold]` | Consume the most recent review artifact for the current branch. Apply fixes above `threshold`. Re-review against working tree before commit. May be run multiple times against the same review. | optional int, default `60` |
| `/adams-review-promote <finding_id>` | Human override: promote a single finding to auto-fixable, bypassing the Phase 8 lane filter and score threshold. Records provenance in `human_confirmation`. See §27. | `<finding_id> [--reason "..."] [--force]` |

The fix command is agnostic to how the review was produced — it only reads the artifact. `--ensemble` is a detection-phase flag only; downstream phases are identical.

### 3.2 Key structural changes

1. **Producer / consumer split with persistent artifact.** Review produces the artifact. Fix consumes it. Multiple fix runs per review via an append-only `fix_attempts` trail in each finding.
2. **Single canonical `findings[]` array with a three-state machine.** States are `open | attempted | resolved`. Two extra fields capture nuance without proliferating states: `is_actionable` (bool — can Phase 8 touch this on the next fix run?) and `reason` (free-form display string). Routing fields (`impact_type` / `origin` / `actionability` / `validation_lane`) still determine how each finding flows through Phase 4 and Phase 8. The rendered report is a *view* of this array, not a second source of truth.
3. **Deep per-candidate validation replaces one-shot scoring** for correctness and security findings. Each candidate surviving an initial cheap-score gate gets its own Opus investigation agent.
4. **Explicit score decision table and separated threshold concepts** (validation gate vs. confirmation decision vs. fix gate).
5. **Two validation lanes.** Correctness and security findings go through the deep lane (full investigation, blast-radius tracing, comprehensive fix proposal). UX, policy, and architecture findings go through the light lane (Sonnet verification, report-first).
6. **LLM-only dedup** — one Sonnet call groups candidates into equivalence classes. Source-family auto-graduation uses the source-family tags, not a structural fingerprint.
7. **Cross-cutting review pass** before fix: a dispatched Opus sub-agent identifies bugs that must be fixed together.
8. **Fix execution via fix groups.** Bugs sharing files or flagged as cross-cutting are handled by one agent. Fix agents edit files only; orchestrator handles git.
9. **Phase 9 runs against working tree, before commit; regressed groups are reverted.** Post-fix review happens pre-commit via a dispatched Opus sub-agent so we never ship commits we already know are incomplete. Outcomes aggregate per fix group: a group is `regression` if any of its findings regressed, else `partial` if any partial, else `verified`. Before commit, the orchestrator reverts every regression group's edits (modified files restored, new files deleted), and commits only the verified + partial groups. The all-regression case (every group regressed) falls out naturally: nothing survives, no commit is made. Per-run outcome is recorded in the commit message.
10. **Helper scripts for state mutation.** Model decides semantics; deterministic scripts perform JSON mutations with schema validation and error-as-prompt failure messages.
11. **Observability as a v1 feature.** Per-review directory with a consolidated `phases.jsonl`, narrative trace log (including each sub-agent's `agentId` for direct transcript lookup), and per-agent token tracking.

### 3.3 Persistence

Artifacts live on the local filesystem:

```
~/.adams-reviews/<repo-slug>/<branch>/<review_id>/
  ├── artifact.json
  ├── artifact.md
  ├── trace.md
  ├── tokens.jsonl
  └── phases.jsonl
```

A small `~/.adams-reviews/<repo-slug>/<branch>/latest.txt` holds the most-recent `review_id` for that branch. Cross-session continuity is provided by this on-disk state; there is no cross-machine synchronization.

In PR mode, the rendered Markdown report is posted as a PR comment so it's visible to collaborators and to Adam scrolling through GitHub. The comment is authoritative for **display**; the local `artifact.json` is authoritative for **state**. `/adams-review-fix` reads only the local artifact.

---

## 4. Pipeline — phase by phase

```
/adams-review [--ensemble]
├── Phase 0 — Pre-flight (branch/PR detect, dirty-tree, push, prior-artifact prompt, record review_started_at)
├── Phase 1    ─┐ Detection (parallel lens agents; tag impact_type/origin per candidate)
│               │   (under --ensemble, Phases 1 + 1.5 dispatch in one turn — §13.12)
├── Phase 1.5  ─┘ External PR-comment scrape + CodeRabbit/Codex CLIs + Sonnet normalizer (ensemble mode only)
├── Phase 2 — Dedup (LLM pass, one Sonnet call)
├── Phase 3 — Cheap scoring + gate (err-up rubric; source-family auto-graduation)
├── Phase 4 — Validation (lane-aware: deep Opus for correctness/security; light Sonnet for others)
├── Phase 5 — Cross-cutting review (deep-lane findings; dispatched Opus sub-agent)
└── Phase 6 — Finalize (phases.jsonl, artifact write, render, post markdown to PR)

/adams-review-fix [threshold]
├── Phase 7 — Load artifact; clean-tree gate; file-overlap staleness check
├── Phase 8 — Per-fix-group agents edit working tree (no git operations); each group
│             reports files_modified and files_created
└── Phase 9 — Post-fix review against working tree; aggregate outcomes per group;
              revert regression groups (checkout modified, rm created); commit surviving
              groups (verified + partial) with outcome in message; if every group is a
              regression, no commit is made; push (PR mode); append fix_attempt entries
```

### Phase 0 — Pre-flight

1. Resolve branch: `git rev-parse --abbrev-ref HEAD`.
2. Resolve base: `origin/HEAD` → `main` → `master` → error.
3. Detect PR: `gh pr view --json number,state,isDraft,url,author,headRefName,baseRefName`. Closed/merged stop the command. Draft proceeds.
4. **Reconcile base-branch freshness** (§13.10). Fetch `origin/<base>` with a 30s soft timeout; compute `behind_count` against local `<base>`; if behind, `AskUserQuestion` with four options (fast-forward local, use `origin/<base>` as comparison ref, proceed stale with warning, abort). Fetch failure degrades silently to `base_freshness="no_fetch"` with a trace warning. Output is `comparison_ref` (the ref every later diff/blame/lens-prompt uses) and `base_context = {freshness, comparison_ref, remote_sha, behind_count}` recorded on the artifact.
5. **Record `review_started_at`** (ISO-8601 UTC timestamp). Captured *before* any local state mutation (push, stash) so that Phase 1.5's external-comment scrape window doesn't miss bot comments posted in the gap between pushing the branch and marking the review as started.
6. List CLAUDE.md paths via `claude-md-paths.sh` (deterministic Bash helper — walks up from each touched file to repo root, collects `CLAUDE.md` paths, dedupes, orders root-first). Result stored on the artifact as `claude_md_paths`.
7. Dirty-tree handling via `AskUserQuestion` (stash+pop, include-in-commit, stop).
8. Push any unpushed commits if PR exists.
9. Sanity check: `git rev-list --count <comparison_ref>..HEAD` must be > 0.
10. **Trivial-diff detection.** Pure Bash — check file extensions and line counts per §13.9. If the diff qualifies, set `artifact.trivial_mode = true` (effect: L2/L5/L6 skipped, Phase 4a deep validation skipped). User can force full pipeline with `--full`.
11. **User-facing change detection (Haiku classifier).** Determines whether L5 (UX lens) runs at all. Skipped when `trivial_mode = true` (L5 already off in that mode). See §19.1.
12. **Prior-artifact detection.** Read `~/.adams-reviews/<repo>/<branch>/latest.txt` if present. If an existing review exists for this branch, `AskUserQuestion`:

| Prior state | Prompt |
|---|---|
| HEAD matches `reviewed_sha`, no fix_attempts | "You have a review for this exact commit from `<date>`. Re-run fresh (replaces), or abort?" |
| HEAD matches most recent fix_attempt `output_sha` | "You have a review that was already fixed at this commit. Re-run fresh (replaces), or abort?" |
| HEAD moved beyond any known SHA | "Prior review at `<sha>`. Current HEAD is `<sha>`. Proceed with fresh review?" |
| Any finding has `current_state: open` with `is_actionable: true` | "Previous review has unresolved actionable findings. Options: (a) run `/adams-review-fix` to address, (b) proceed with fresh review, (c) abort." |

A fresh review supersedes the prior local artifact; in PR mode it also posts a new PR comment alongside the prior one — the prior is **not** overwritten (§13.4). If the user wants the prior comment gone they delete it on GitHub first.

13. **Prior-PR-comment detection (PR mode, even without local artifact).** If `gh api` shows a comment on this PR authored by the current `gh auth` user containing the stable marker `<!-- adams-review-v1 -->`, AND no local `latest.txt` exists (e.g. re-run from a different machine, or local reviews were cleaned), `AskUserQuestion` with three choices: (a) post a new comment alongside the existing one (default — prior stays untouched), (b) replace the existing comment in place (captures the comment id as `existing_comment_id`; Phase 6 PATCHes it via `--comment-id`), (c) abort and recover the prior artifact first. This closes the cross-machine gap — local-only persistence is still the design, but PR state is a secondary signal that at least lets the user choose whether to rehydrate onto the prior comment.

A note on race conditions: two simultaneous `/adams-review` runs on the same branch would race on `latest.txt`. In practice this is a one-user tool on one machine; the risk is a stale pointer. Writes to `latest.txt` are atomic (temp file + rename), so the file itself stays readable; at worst the "latest" pointer loses a race with another run completing a few seconds later. Acceptable for v1.

### Phase 1 — Detection

Six internal lenses run in parallel. Each produces candidates tagged with initial routing fields. On `--ensemble` runs, Phase 1 lens dispatches and Phase 1.5 external CLI launches fan out from the same orchestrator turn (see §13.12); the ensemble-CLI readiness gate has been hoisted ahead of dispatch so missing-CLI prompts surface before any lens token spend.

| Lens | Name | Depth | Model | Default impact_type |
|---|---|---|---|---|
| L1 | Diff-local scan | diff only | Haiku | correctness |
| L2 | **Structural / blast-radius** | callers, writers, parallel paths | Opus | correctness |
| L3 | CLAUDE.md compliance | CLAUDE.md + diff | Sonnet | correctness OR policy (per-finding) |
| L4 | Comment compliance | in-file comments + diff | Sonnet | policy |
| L5 | UX (conditional on user-facing change) | diff + `lens-ux-reference.md` | Sonnet | ux |
| L6 | Lightweight security | diff + `lens-security-reference.md` | Sonnet | security |

Historical git context is NOT a lens — it's a *supporting resource* consulted by Phase 4a validators per-bug.

**Per-candidate output includes** a normalized `evidence_snippet`, a proposed `impact_type`, a proposed `origin` (introduced_by_pr | pre_existing | unknown) with `origin_confidence` (high | medium | low), and a `source_family`.

**Origin cross-check (§13.11) runs between lens aggregation and `--add-finding`.** `origin-crosscheck.sh` (§21.9) takes the aggregated candidate list plus `$comparison_ref` and returns a corrected list: every candidate whose line range blame-traces entirely to commits reachable from `$comparison_ref` is forced to `origin=pre_existing, origin_confidence=high`; every lens-supplied `origin=pre_existing` whose blame includes a PR commit is downgraded to `origin_confidence=medium`; new files and mixed ranges keep the lens verdict. Phases 2–3 see only post-correction origin values, which is what the §13.1 pre-existing override keys on.

**Source families** (for auto-graduation in Phase 3):
- `diff-family`: L1 + any shallow external scan
- `structural-family`: L2
- `policy-family`: L3, L4
- `ux-family`: L5
- `security-family`: L6
- `external-deep-family`: ensemble adapter deep findings (if any)

**Ensemble adapter** (when `/adams-review --ensemble` is used): runs external reviewers from a registry, normalizing their output to the shared candidate schema. Initial registry:

```
reviewers:
  - name: codex,      subagent: codex:codex-rescue,       enabled: true
  - name: coderabbit, subagent: coderabbit:code-reviewer, enabled: true
```

External findings get a best-effort `impact_type` but are flagged `origin_confidence: low` unless corroborated. They do NOT auto-graduate on their own — see Phase 3.

**Over-flag guidance:** all lenses are told to over-flag rather than under-flag. Phase 2 dedup and Phase 3+4 gating will filter.

### Phase 1.5 — External PR-comment scrape (ensemble mode only)

Runs concurrently with Phase 1's lens fan-out under `--ensemble` (see §13.12 for the parallel dispatch pattern). Automated external reviewers (e.g., Greptile, CodeRabbit-as-GitHub-app, Codacy, SonarCloud) are given the internal lens wall-clock to react to the pushed branch and post — the PR scrape reads whatever bot comments exist when the scrape fires, which under parallel dispatch is no later than under the former serial ordering. The normalizer's candidate array joins Phase 1's pool at a single post-dispatch join point; no `--add-finding` calls happen during collection.

The CLI readiness gate that used to live here has been hoisted into Phase 1's fragment (step 1.2a) so missing-CLI prompts surface before any token spend.

**Inputs:** PR number, `review_started_at` (from Phase 0), bot allow/deny config (§13.8).

**Steps:**

1. Call `external-scrape.sh --pr <num>` which runs:
   - `gh api repos/{owner}/{repo}/issues/{num}/comments`
   - `gh api repos/{owner}/{repo}/pulls/{num}/reviews`
   - `gh api repos/{owner}/{repo}/pulls/{num}/comments`
2. Filter each to: (`user.type == "Bot"` OR `user.login` ends with `[bot]`) and author is not the current `gh auth` user.
3. Apply config deny-list (default: `dependabot[bot]`, `renovate[bot]`, `github-actions[bot]`, `codecov[bot]` — these are automation/status bots, not reviewers). If user config has an explicit `allow` list, intersect with it instead.
4. Pipe the scrape output through `comment-freshness.sh --pr <num> --reviewed-files <csv>` (§21.10 / §13.13) so records whose referenced code has changed since the comment was posted are dropped. Per-record audit lines (`comment_freshness: id=… action=…`) flow into `trace.md` via `tee -a`.
5. Pipe the freshness-filtered comment list to a Sonnet normalizer sub-agent that emits candidates in the same schema as other lenses, with `sources: ["external-pr:<bot-login>"]` and `source_family: "external-deep-family"`. `origin_confidence: low` (same rule as other external findings — must corroborate internally to be treated as high-signal).
6. Candidates join the Phase 2 dedup pool alongside internal and codex/coderabbit-adapter candidates.

**Scope boundary:** this scrape runs exactly once. Late-posting bot comments (after Phase 1.5 closes) are not retroactively picked up — they'd miss dedup and validation. Rationale: deterministic window; user can re-run `/adams-review --ensemble` if they want to pick up late additions.

**Failure mode:** if `gh api` rate-limits or fails, log to `trace.md`, drop the scrape for this run, continue with internal + adapter findings. Do not abort.

### Phase 2 — Dedup (LLM-only)

All Phase 1 candidates are passed to a single Sonnet agent with the prompt: "group these candidates into sets where each set represents the same underlying issue described in different language." The agent returns a grouping; each group is merged into one canonical candidate, unioning `sources` and `source_families`.

That's it — no structural fingerprinting layer. One call, ~50 candidates, pennies of Sonnet cost.

### Phase 3 — Cheap scoring + gate

Each deduped candidate gets a Sonnet scoring agent using the 0-100 rubric (§20) with two modifications:

1. **Err-up rubric.** When uncertain between two scores, pick the higher. False positives are cheap here; Phase 4 filters them. Missed bugs are expensive.
2. **Source-family auto-graduation.** A candidate with ≥2 *distinct source families* in its `source_families` auto-graduates to Phase 4 regardless of score. This requires independent angles (e.g., structural + security), not just multiple sources within the same family. External findings do not auto-graduate unless corroborated by an internal family.

**Validation gate:** `score_phase3 ≥ 45` OR multi-family → Phase 4. Below the gate, candidates are retained in the artifact as `current_state: open, is_actionable: false, reason: "below validation gate (score X)"`. `45` is an internal constant, not user-facing.

### Phase 4 — Validation (lane-aware)

Each candidate is routed by `validation_lane`, derived from `impact_type`:

- `correctness` → deep lane (Phase 4a)
- `security` → deep lane (Phase 4a)
- `ux`, `policy`, `architecture` → light lane (Phase 4b)

Overridable per-candidate if needed.

#### 4a — Deep lane (Opus per candidate)

Each Opus validator:

- Reads the candidate claim + evidence + CLAUDE.md paths
- Traces blast radius: every writer, every consumer, every parallel code path, every test
- Consults git blame / history *if relevant to the investigation*
- Re-scores on the 0-100 rubric
- Constructs concrete reproduction or disproof
- If real, emits a **fix_proposal** with every file to modify, per-file `what` and `why`
- May emit `related_candidates_to_investigate` (triggers Wave 2)

Verdict maps to decision table (see §13.1):
- score < 45 → `current_state: open, is_actionable: false, reason: "disproven by Phase 4: <summary>"`
- 45-59 → `current_state: open, is_actionable: false, reason: "uncertain (Phase 4 inconclusive)"`
- 60-74 → `current_state: open, is_actionable: true, confirmed_strength: moderate`
- 75+ → `current_state: open, is_actionable: true, confirmed_strength: strong`

**Chain-wave retry.** Sub-agents cannot spawn sub-agents; sibling investigations are dispatched at the orchestrator level.
- Wave 1: one validator per Phase 3 candidate that passed the gate
- Wave 2 (optional): if Wave 1 outputs contain `related_candidates_to_investigate`, orchestrator dedups across outputs and dispatches a second wave
- Hard cap at 2 waves

#### 4b — Light lane (Sonnet per candidate)

- Reads claim + relevant CLAUDE.md / file section
- Verifies accuracy (does CLAUDE.md actually say this? does the comment really conflict?)
- Returns `decision: confirmed | disproven | uncertain` + adjusted score
- Flags `actionability: auto_fixable` ONLY for very mechanical rules (e.g., "imports sorted per CLAUDE.md"). Most light-lane findings get `actionability: manual` or `report_only`.
- Does NOT do blast-radius tracing or produce a fix proposal

Light-lane findings skip Phase 5. A disproven light-lane finding is dropped from the report the same way a disproven deep-lane finding is (`is_actionable: false, reason: "disproven by Phase 4b"`).

### Phase 5 — Cross-cutting review (deep lane only)

The orchestrator dispatches an Opus sub-agent that looks across all deep-lane findings with `is_actionable: true` and inspects their fix_proposals. The sub-agent receives the findings (with full `validation_result`) as serialized JSON in its prompt; no tool access is needed. Outputs:

- `cross_cutting_groups`: sets of findings that must be fixed together, each with a combined approach
- Per-finding annotations noting group membership

Non-deep-lane findings skip Phase 5.

### Phase 6 — Finalize

1. Validate the in-memory findings[] array against the v1 schema (§6). Fail loudly on drift.
2. Append a per-phase record to `phases.jsonl` (see §12.1). One line per phase; each line contains `{phase, elapsed_sec, counts_by_state, delta_from_prev}`.
3. Write final `artifact.json` + `artifact.md` + `trace.md` to `~/.adams-reviews/<repo>/<branch>/<review_id>/`.
4. Update `~/.adams-reviews/<repo>/<branch>/latest.txt` with the new `review_id`.
5. If PR exists: post the rendered `artifact.md` (Markdown only) as a PR comment. No JSON embed. The local `artifact.json` is the source of truth for state; the PR comment is a human-readable mirror.
6. Mirror rendered report to chat (all modes).

### Phase 7 — Load artifact + leftover-attempted check + clean-tree gate + staleness check (fix command)

1. Parse threshold arg (default 60).
2. Resolve artifact path: `~/.adams-reviews/<repo>/<branch>/latest.txt` → `<review_id>/artifact.json`. If missing, abort with "no review found for this branch. Run `/adams-review` first."
3. Validate against schema.
4. **Leftover-`attempted` check (hard abort).** If any finding has `current_state == attempted`, a prior `/adams-review-fix` run was interrupted between Phase 8 (edits applied) and Phase 9 (classification + terminal cleanup). Abort with a deterministic recovery message:

    ```
    ERROR: previous /adams-review-fix run did not finish (N findings still in 'attempted').
    The working tree may still contain partial fix edits from that run.

    Recover:
      1. `git status` — inspect what's uncommitted.
      2. If the uncommitted changes are ONLY from the interrupted fix run and you
         want to discard them: `git restore .` (and `git clean -fd` for any new
         files the fix agents created). Alternatively, commit or stash them yourself
         if you want to keep them.
      3. For each leftover 'attempted' finding, reset state manually:
         artifact-patch.py --finding-id <id> --set current_state=open
      4. Re-run /adams-review-fix.

    Leftover 'attempted' finding ids: <list>
    ```

    No automated recovery is attempted: the orchestrator cannot tell whether leftover edits represent good fixes the user may want to keep, half-finished state, or a genuine regression. The user is the only actor who can make that call. This is the default v1 behavior; a future `--resume-interrupted` flag could offer automated cleanup once we've learned enough from real interruptions.

5. **Clean-tree gate.** `git status --porcelain`. If non-empty, `AskUserQuestion`:
   - `stash` — stash current changes (with `--include-untracked`), proceed with fix, then re-apply via `git stash pop` after the final commit or after per-group revert. Stash conflicts at pop are reported to the user; the stash ref is preserved so they can recover manually.
   - `abort` — exit; user resolves the working tree before retrying.

   Clean tree is required because Phase 9's per-group revert (§4 Phase 9b) relies on "anything new in the tree after Phase 8 was produced by a fix group." Mixing user edits with fix-group edits would make selective revert unsafe: `git checkout -- <file>` would discard the user's in-flight work. The stash route preserves user work behind a clean baseline; the abort route hands responsibility back to the user.
6. **File-overlap staleness check:**
   ```
   latest_known_sha = most recent fix_attempt output_sha OR reviewed_sha (if no fix_attempts)
   if HEAD == latest_known_sha: safe
   else:
       changed_files = `git diff --name-only latest_known_sha..HEAD`
       if changed_files ∩ reviewed_files_all is empty:
           warn but proceed  (branch moved; no reviewed files changed)
       else:
           abort  (reviewed files changed; re-run /adams-review or --force)
   ```
   `reviewed_files_all` (from the artifact) is the full set of files in the diff at review time — see §13.3.
7. PR eligibility recheck (closed/merged → abort).

### Phase 8 — Per-fix-group agents

#### Fix-group algorithm (orchestrator-inline)

Eligible findings for this fix run:
- `current_state == open` AND
- `is_actionable == true` AND
- `actionability == auto_fixable` AND
- `impact_type ∈ {correctness, security}` (deep lane only; light-lane auto_fixable is out of scope for v1 per §13.2) AND
- `score_phase4 ≥ threshold`

The orchestrator computes the eligible finding-id list inline, then calls `group-fixes.py --artifact <path> --eligible-finding-ids <list>` which performs the union-find and returns fix groups. Grouping rules:

1. Seed groups from `cross_cutting_groups`.
2. Merge groups sharing any file across `fix_proposal.files_to_modify[].file`. Transitive closure.

Each group → one Opus fix-group agent.

#### Each fix-group agent receives

- All findings in the group with their full validation result (evidence, blast radius, fix proposal, verification context)
- Any cross-cutting annotations
- CLAUDE.md paths (for reading as needed)
- For findings whose most recent `fix_attempts[-1].phase_9_outcome` is `partial` or `regression`: the `phase_9_finding` and any `revised_fix_proposal` — so retry-runs have context on what went wrong previously
- Union of files the group will touch

#### Each fix-group agent does

1. Reads all files in the group once
2. Plans fix ordering within the group
3. **Applies edits via Edit/Write only. Does NOT run any git commands.** Also: **no deletes, renames, or moves** in v1 — no `rm`, `git rm`, `git mv`, or any filesystem-mutating Bash. The revert model (§4 Phase 9b) only handles edits and creates; extending it to cover deletion/movement would change the safety surface. A fix that genuinely requires deletion or rename is `actionability: manual` in Phase 4 and should never reach Phase 8; if a fix agent discovers mid-edit that a delete/rename is the only clean path, it returns a verification failure on that finding and does not attempt the operation. Future v2 can relax this.
4. Runs each finding's `verification_context.how_to_verify_fix` steps (greps, reads)
5. If project has `verification_commands` configured (§13.5), runs them for touched files
6. Returns per-finding + per-file results, **including two distinct file lists:** `files_modified` (existed before Phase 8; edited via Edit) and `files_created` (did not exist before Phase 8; created via Write). Per-group revert (§4 Phase 9b) uses these lists to decide whether to `git checkout --` a file or `rm -f` it. The two lists are disjoint and cover every file the agent touched — no third category exists because deletes/renames are forbidden (see step 3).

### Phase 9 — Post-fix review (BEFORE commit); then commit

#### 9.pre. Touched-file overlap guard (runs before 9a)

As soon as Phase 8 returns, the orchestrator reconciles each group's *actual* touched files against other groups' before doing anything else. For each group, `actual_touched = files_modified ∪ files_created` from the Phase 8 return value. Compute:

```
overlap = files appearing in ≥ 2 groups' actual_touched
```

If `overlap` is non-empty, **abort the automated fix run before Phase 9a runs**. Rationale: fix groups are formed at plan time from `fix_proposal.files_to_modify` (§21.5 union-find). If two groups plan disjoint files but an agent in group A actually touches a file in group B's planned set, group identity no longer partitions the tree — a regression-driven revert in B could discard A's edit, and vice versa. Selective per-group revert becomes unsafe; the user is the right decision-maker for reconciling.

Orchestrator response:

1. Skip Phase 9a entirely (no per-finding classification runs — the groups aren't actually independent, so classifying them independently would be misleading).
2. Log the overlapping files and their owning groups to `trace.md` with a clear orchestrator-error prefix.
3. Do **not** run per-group revert (a revert in one group could discard another group's edit on the same file).
4. Do **not** stage or commit anything. Leave the working tree as-is so the user can inspect.
5. Record each affected finding's `fix_attempts` with `output_sha: null`, `phase_9_outcome: null` (Phase 9 never ran), `phase_9_finding: "run aborted: fix agents touched overlapping files across groups — <file-list>"`, and leave the finding's `current_state` at `attempted` (which will trigger the leftover-`attempted` hard abort on the next `/adams-review-fix`, giving the user deterministic recovery).

    Exception: the terminal cleanup block (§4 Phase 9e / §24.4) runs in its degenerate "no commit" branch — artifact is rendered with the overlap-abort note, stash is restored if taken, the user-visible error is surfaced last. This keeps artifact state consistent with "nothing was committed but the run is accounted for."
6. Surface a user-visible error naming the overlapping files, the groups involved, and a recommended next step (inspect the working tree and decide what to keep; `git restore .` + `git clean -fd` to discard; reset `current_state` on the affected findings with `artifact-patch.py`; re-run `/adams-review-fix`). Exit without commit.

If `overlap` is empty, proceed to 9a normally.

#### 9a. Phase 9 review against working tree

With all fix-group agents returned and having edited the working tree (but no commits yet), the orchestrator dispatches an Opus sub-agent for post-fix review. The sub-agent receives: the attempted findings with full `validation_result`, the fix-group agents' structured results (including `files_modified` and `files_created` per group), and `git diff HEAD` pre-embedded in its prompt. It has `Read`, `Bash(git diff:*)`, and `Bash(grep:*)` tool access for fresh verification; it does NOT have `git add`/`commit`/`checkout` access — those stay with the orchestrator. For each finding whose state was attempted in this fix run, the sub-agent determines:

- Did the fix actually eliminate the bug? (Re-check the evidence path against current file state.)
- Did every place in `fix_proposal.files_to_modify` get a corresponding edit?
- Did agent-run `verification_context.how_to_verify_fix` pass?
- Did project `verification_commands` pass?
- Are there new issues adjacent to the fix that weren't there before?

Per-finding outcome is one of: `verified`, `partial` (with a `phase_9_finding` describing what's missing and a `revised_fix_proposal`), or `regression` (the fix introduced a new problem adjacent to the fixed code).

#### 9b. Per-group outcome aggregation + revert of regression groups

Precondition: the 9.pre overlap guard has passed (groups' `actual_touched` sets are disjoint).

Before committing, the orchestrator aggregates per-finding outcomes **per fix group**:

- `group_outcome = regression` if ANY finding in the group ended `regression`
- Else `group_outcome = partial` if ANY finding in the group ended `partial`
- Else `group_outcome = verified`

Classification priority `regression > partial > verified` matches Phase 9's per-finding priority. A group is "poisoned" by any regression within it because the group's fixes share files and intent — keeping some edits while discarding others within the same group risks leaving incoherent state.

**Revert regression groups.** For every fix group with `group_outcome == regression`:

1. For each path in `group.files_modified`: `git checkout -- <path>` to restore pre-Phase-8 content.
2. For each path in `group.files_created`: `rm -f -- <path>` to remove the new file.
3. Record the regression in each affected finding's `fix_attempts` trail (so the user sees what failed).

**Survivor commit.** After regression reverts, surviving fix groups (verified + partial) remain in the working tree. Staging and commit (9c) include only those groups' files.

**All-regression degenerate case.** If every group is `regression`, the revert loop above reverts the entire working tree. Nothing remains to commit. Orchestrator:

1. Records the regressions (already done above).
2. Writes the outcome to the report and `trace.md`.
3. Does **not** create a commit.
4. Exits with a user-visible "all fixes regressed — working tree restored; no commit made." message.

**Mixed case (at least one verified or partial group survives).** Proceed to 9c with the surviving-group file list.

This preserves the commit invariant: every file in the commit came from a group Phase 9 classified as verified or partial. A regression detected by Phase 9 never ships, even when other groups succeeded in the same run.

#### 9c. State update + commit (with at least one surviving group)

Orchestrator commits. The commit message carries per-group Phase 9 truth, including reverted groups so the history record is honest:

```
fix: address code review findings (N groups committed, M reverted)

Fix groups (committed):
- [FG-1] F001, F003 — session.ts, guest.ts, _error.tsx: null contract enforcement ✓ verified
- [FG-2] F002 — cache/sync.ts: missing invalidation after write ✓ verified
- [FG-4] F005 — api/users.ts: off-by-one in pagination ⚠ partial (missed the search-results path)

Fix groups (reverted — regression detected):
- [FG-3] F004 — api/auth.ts: auth-check fix introduced new 401 path for valid tokens

Post-fix review: 2/4 groups verified complete; 1 group partial; 1 group reverted.
Re-run /adams-review-fix to address partial and regression findings (retry with revised_fix_proposal context).
```

Orchestrator:
1. `git status --porcelain` to confirm what changed — should show only surviving-group files after the regression reverts ran in 9b.
2. Stage only surviving-group files (`git add -- <files>`; never `-A`; exclude any file that also appeared in a reverted group — the revert wins).
3. **Default commit strategy: one combined commit** of all surviving groups. `--granular-commits` opts into one commit per surviving fix group.
4. Commit with per-group Phase 9 outcomes in the message (including reverted groups as a separate section). **On commit success, immediately capture the new SHA (`git rev-parse HEAD`) before any further action.** Push is deliberately deferred to 9e so that artifact state is persisted before any network call can fail.

#### 9d. State transitions (via helper script)

For each finding touched in this run, orchestrator calls `artifact-patch.py` to transition state and set `disposition` (§5.2.1):

- `open → attempted` (Phase 8 ran). Disposition unchanged at this step.
- `attempted → resolved`, `disposition: resolved` (Phase 9 verified).
- `attempted → open`, `is_actionable: true`, `disposition: partial`, `reason: "fix partial: <phase_9_finding>"` (Phase 9 found incomplete).
- `attempted → open`, `is_actionable: true`, `disposition: regression`, `reason: "fix regressed: <phase_9_finding>"` (Phase 9 found new adjacent issue; the finding's group was reverted from the working tree in 9b).

Append a new `fix_attempts` entry per finding with `run_id`, `fix_group_id`, `input_sha`, `output_sha` (if a commit was made for this finding's surviving group; null for reverted regression-group findings, all-regression runs, and overlap-aborted runs), `phase_9_outcome`, `phase_9_finding` (if applicable), and `revised_fix_proposal` (if applicable).

There is no separate `fix_runs[]` collection — per-run summaries are derived at render time by grouping `fix_attempts` across findings by `run_id`.

#### 9e. Terminal cleanup (deterministic order, runs on every Phase 8 → Phase 9 completion regardless of commit outcome)

The terminal block exists so that the local artifact is always consistent with git reality *before* any later step can fail. This matters because the next `/adams-review-fix`'s staleness check keys off `fix_attempts[-1].output_sha`; if we skipped artifact writes on push or publish failure, the local state would diverge from git state, and the next run's staleness logic would silently misfire.

Run every step below, in order, regardless of earlier-step failures. Each step's success or failure is recorded in `trace.md` with an explicit tag. Only after all steps complete does the orchestrator surface the *first* failure (if any) as a user-visible error — subsequent failures are still recorded but are not the primary error the user sees.

**For runs that produced a commit** (surviving-group mixed case):

1. **Append `fix_attempts` entries and apply state transitions** (9d above). `output_sha` is the commit SHA captured at the end of 9c. Happens *before* any push or publish.
2. **Validate schema** on the mutated artifact.
3. **Re-render `artifact.md`** from the updated `artifact.json`.
4. **Append to `trace.md` and `phases.jsonl`** — Phase 9 record includes `counts_by_disposition`, per-group outcomes, and committed/reverted group ids.
5. **Attempt `git push`** (PR mode). Push failure does not undo the commit or the artifact update — `output_sha` is already recorded, so the next run's staleness check will see the commit correctly. If push fails, log stderr to `trace.md` with the tag `push_failed`.
6. **Attempt `artifact-publish.sh --mode pr --comment-id <id>`** (PR mode). Publish failure does not touch the artifact either — the local state is already authoritative. Log to `trace.md` with the tag `publish_failed`.
7. **Pop stash** if one was taken at the Phase 7 clean-tree gate. Conflict at pop leaves the stash ref in place and is logged with tag `stash_pop_conflict`.
8. **Surface the first failure** (if any) to the user, ordered: `push_failed` > `publish_failed` > `stash_pop_conflict`. Each failure message names the next step the user should take.

**For runs that produced no commit** (all-regression, all groups reverted; or overlap-abort from 9.pre; or per-group-revert failure from 9b; or all-partial with zero survivors — any degenerate case that leaves no committable state):

1. **Append `fix_attempts` entries with `output_sha: null`** and apply state transitions (9d). For all-regression runs, each finding's `phase_9_outcome` is `regression`. For overlap-abort, `phase_9_outcome: null` with `phase_9_finding: "run aborted: ..."` and `current_state` left as `attempted` (triggers leftover-`attempted` hard abort on next run for deterministic recovery). For revert-failure, `phase_9_outcome` is whatever Phase 9a classified plus a `phase_9_finding` describing the revert error. Artifact records the outcome of every finding the run touched, before anything else can go wrong.
2. **Validate schema.**
3. **Re-render `artifact.md`.**
4. **Append to `trace.md` and `phases.jsonl`** — Phase 9 record notes the degenerate case (e.g., `"all_regression": true`, `"overlap_abort": true`, `"revert_failure": true`).
5. **Pop stash** if one was taken, unless the degenerate case is a revert-failure that left the tree in an unknown state — in that case leave the stash and note the stash ref in the user-visible error. (Stash popping into a "we don't know what's in the tree" state could destroy user work.)
6. **No push, no publish** — there's nothing new to push or publish. The artifact-side update is still valuable for the next run's staleness logic and for the user to inspect.
7. **Surface the user-visible degenerate-case error** describing what happened and the recommended next step.

This symmetry — record the run in the artifact before any later step can fail — is the cleanup invariant. A partially-failed terminal block can only leave `trace.md` noting the failure; it can never leave the artifact out of sync with git.

---

## 5. Finding state model

### 5.1 States (three)

```
           detection + dedup + scoring + validation
                            │
                            ▼
                       ┌─────────┐
                       │  open   │
                       └─────────┘
                      ╱           ╲
       is_actionable=false         is_actionable=true
         (reported only)        (eligible for Phase 8)
                                        │
                                 Phase 8 runs
                                        │
                                        ▼
                                ┌───────────────┐
                                │  attempted    │  (transient; Phase 9 classifies)
                                └───────────────┘
                                        │
                          ┌─────────────┼─────────────┐
                          ▼             ▼             ▼
                    ┌──────────┐  ┌──────────┐  ┌──────────┐
                    │ resolved │  │   open   │  │   open   │
                    │          │  │ actionable│  │ actionable│
                    │          │  │ reason=  │  │ reason=  │
                    │          │  │ "partial"│  │"regressed"│
                    └──────────┘  └──────────┘  └──────────┘
                       verified        partial      regression
```

Three extra fields do the work that extra states used to do:

- **`disposition`** (enum): machine-readable classifier. Values listed in §5.2.1. Drives report section selection and Phase 8 eligibility. This is the primary routing key — filters and report selectors read this, not combinations of prose fields.
- **`is_actionable`** (bool): derived from `disposition` (`true` iff disposition ∈ `{confirmed_auto, partial, regression}`). Present as a convenience for short jq expressions; writer scripts keep it in sync with `disposition`.
- **`reason`** (string): free-form display text layered on top of `disposition` — "below validation gate (score 32)", "disproven by Phase 4: no null path reaches caller", "fix partial: missed guest.ts writer", "manual — requires design decision". For humans; never parsed by machine logic.

### 5.2 State meanings

- **open** — the finding has not been resolved. Combined with `disposition`, this covers every non-resolved status: pending fix, uncertain, below threshold, disproven, manual-only, report-only, pre-existing report-only, and post-fix-partial or post-fix-regression.
- **attempted** — Phase 8 ran on this finding during the current fix run, but Phase 9 hasn't classified yet. Transient *at the run level*: after a completed fix run, no finding remains in `attempted` — Phase 9 always transitions it forward. But the on-disk artifact *can* contain `attempted` entries mid-run, between Phase 8 completion and Phase 9 completion. This is intentional: if Phase 9 crashes or is interrupted, the on-disk state lets a post-mortem see which findings had edits applied before the crash. On a fresh `/adams-review-fix`, leftover `attempted` findings trigger a **hard abort** with deterministic recovery instructions (§4 Phase 7 step 4) — `git restore` + manual state reset, then retry. v1 does not attempt automated recovery: the orchestrator has no safe way to tell whether the leftover working-tree edits are good, half-broken, or regressions, so the user is the only actor who can decide.
- **resolved** — Phase 9 confirmed the fix eliminated the bug.

### 5.2.1 Disposition (machine-readable classifier)

`disposition` is a per-finding enum orthogonal to `current_state`. It encodes *why* a finding is in its current state — the thing that prose `reason` text used to carry implicitly. Report sections (§7) and Phase 8 eligibility filter on `disposition`, not on combinations of `is_actionable + actionability + origin + score_phase4 + reason`.

| disposition | Meaning | `current_state` | `is_actionable` | Typical phase that sets it |
|---|---|---|---|---|
| `below_gate` | `score_phase3 < 45` and single source family | `open` | `false` | Phase 3 |
| `pending_validation` | Phase 3 gate-in parking state; awaiting Phase 4 validation | `open` | `false` | Phase 3 |
| `disproven` | `score_phase4 < 45` (Phase 4 actively disproved) | `open` | `false` | Phase 4 |
| `uncertain` | `score_phase4 45–59` (Phase 4 inconclusive) | `open` | `false` | Phase 4 |
| `confirmed_auto` | `score_phase4 ≥ 60`, deep lane, `actionability == auto_fixable` | `open` | `true` | Phase 4 |
| `confirmed_manual` | `score_phase4 ≥ 60`, `actionability == manual` (confirmed real but requires human judgment) | `open` | `false` | Phase 4 |
| `confirmed_report` | `score_phase4 ≥ 60`, `actionability == report_only` (confirmed real but informational) | `open` | `false` | Phase 4 |
| `pre_existing_report` | `origin == pre_existing` AND `origin_confidence == high` (normative override — set regardless of score; see §13.1) | `open` | `false` | Phase 1 / re-asserted Phase 4 |
| `partial` | Phase 9 found the fix incomplete; retry-eligible | `open` | `true` | Phase 9 |
| `regression` | Phase 9 found a new adjacent issue; the fix group was reverted; retry-eligible | `open` | `true` | Phase 9 |
| `resolved` | Phase 9 verified the fix | `resolved` | `false` | Phase 9 |

**Invariants enforced by writer scripts:**

- `is_actionable` is derived: `true` iff `disposition ∈ {confirmed_auto, partial, regression}`. Writer scripts keep the two in sync. A `--set is_actionable=X` that contradicts `disposition` is rejected.
- `current_state == resolved` ⇔ `disposition == resolved`. Any other combination is invalid.
- `current_state == attempted` transiently has whatever `disposition` the finding had before Phase 8 ran (typically `confirmed_auto`, `partial`, or `regression`). Phase 9 updates it.
- `human_confirmation` is absent or `null` on validator-driven findings. Set only by `/adams-review-promote` (§27). Present-and-non-null implies the human has overridden the validator's verdict; Phase 8 eligibility treats `human_confirmation != null` as a bypass of both the impact_type lane filter (§13.2) and the `score_phase4 >= threshold` gate (§13.1). The field is additive — it does not couple to `disposition` or `current_state`, and promotion does NOT mutate `score_phase4` (the validator's honest score is preserved for audit).

**Phase 8 eligibility** (§13.1):

```
current_state == open
  AND disposition ∈ {confirmed_auto, partial, regression}
  AND (
    human_confirmation != null                                      // §27 bypass
    OR (
      impact_type ∈ {correctness, security}                         // §13.2 lane filter
      AND score_phase4 >= threshold                                 // §13.2 fix gate
    )
  )
```

`partial` and `regression` both stay fix-eligible so that a subsequent `/adams-review-fix` can pick them up armed with the `revised_fix_proposal` and the prior `phase_9_finding`. Regression retries are not user-gated in v1 — the user can inspect the artifact and pass a higher threshold to exclude them if desired.

A non-null `human_confirmation` (set by `/adams-review-promote`, §27) bypasses both the impact_type lane filter and the score threshold. The point of manual promotion is that a human has explicitly overridden the validator's conservative defaults; re-gating on those defaults would make promotion a no-op for exactly the cases where it matters most (ux / architecture findings, findings below threshold).

`reason` remains a free-form display string (e.g. "fix partial: missed guest.ts writer") layered on top of `disposition`. Carries specificity for humans; never parsed by machine logic.

### 5.3 Valid transitions (enforced by helper script)

```
open → attempted       (Phase 8 ran)
attempted → resolved   (Phase 9 verified)
attempted → open       (Phase 9 classified partial or regression)
resolved → [terminal]  (a fresh /adams-review may re-detect, but in a new review_id)
```

Any other transition is an error: the helper script rejects it with a valid-transition-list error.

### 5.4 What each actor reads / writes

- **Sub-agents** (lens agents, validator agents, fix-group agents): never write state directly. They return structured results.
- **Orchestrator**: the only actor that calls writer scripts. It translates sub-agent results into state transitions.
- **Writer scripts** (`artifact-patch.py` and friends): enforce schema, transition whitelist, and produce error-as-prompt responses on invalid input.

---

## 6. Artifact schema (v1)

```jsonc
{
  "schema_version": 1,
  "review_id": "rev_01JX9A3P4B8M...",
  "generated_at": "2026-04-17T19:23:11Z",
  "review_started_at": "2026-04-17T19:02:45Z",  // Phase 0 entry timestamp; bounds Phase 1.5 scrape window
  "reviewed_sha": "a3f8d7c9...",
  "base_branch": "main",
  "head_branch": "feature/auth-hardening",
  "mode": "pr",                              // "pr" | "local"
  "pr_state": "draft",                       // "draft" | "open" | null
  "pr_number": 1234,
  "comment_id": 2093481234,                  // set by artifact-publish.sh on first PR comment post; null in local mode or before first publish; used for efficient PATCH on subsequent publishes
  "trivial_mode": false,                     // set in Phase 0 per §13.9; true downshifts the pipeline (skip L2/L5/L6, skip Phase 4a)
  "base_context": {                          // §13.10 freshness record; optional (absent in pre-§13.10 artifacts). comparison_ref is the actual ref every lens/blame/diff used; base_branch (above) stays as the human name.
    "freshness": "fresh",                    // fresh | fast_forwarded | used_remote_ref | proceeded_stale | no_fetch | no_remote
    "comparison_ref": "main",
    "remote_sha": "a3f8d7c9...",             // origin/<base_branch> at fetch time; null if no_fetch / no_remote
    "behind_count": 0                        // local <base_branch> behind origin/<base_branch>; null if no_fetch / no_remote
  },
  "reviewer_sources": ["internal", "codex", "coderabbit", "external-pr:greptile-apps[bot]"],
  "reviewed_files_all": ["src/auth/session.ts", "src/cache/sync.ts", "src/cache/helpers.ts", "docs/auth.md", "..."],  // every file in the diff at review time; staleness envelope (§13.3). reviewed_files_with_findings (union of finding.file) is derived at render time, not stored.
  "claude_md_paths": ["/abs/repo/CLAUDE.md", "/abs/repo/src/CLAUDE.md"],

  "findings": [
    {
      "id": "F001",

      "sources": ["L2-structural", "codex"],
      "source_families": ["structural-family", "external-deep-family"],

      // Routing
      "impact_type": "correctness",          // correctness | security | ux | policy | architecture
      "origin": "introduced_by_pr",          // introduced_by_pr | pre_existing | unknown
      "origin_confidence": "high",           // high | medium | low
      "actionability": "auto_fixable",       // auto_fixable | manual | report_only
      "validation_lane": "deep",             // deep | light

      // State
      "current_state": "open",               // open | attempted | resolved
      "disposition": "confirmed_auto",       // §5.2.1 enum — machine-readable classifier; drives report sections and Phase 8 eligibility
      "is_actionable": true,                 // derived: true iff disposition ∈ {confirmed_auto, partial, regression}
      "reason": null,                        // free-form display string layered on top of disposition; null when trivial
      "confirmed_strength": "strong",        // moderate | strong; set post-Phase-4; null if not confirmed

      // Location
      "file": "src/auth/session.ts",
      "line_range": [42, 58],
      "claim": "authenticateUser() returns null to callers assuming non-null",

      // Cached latest scores (derived from score_history; duplicated for quick jq/filter access)
      "score_phase3": 55,
      "score_phase4": 85,

      // Score history (append-only across phases)
      "score_history": [
        { "phase": "phase_3", "score": 55 },
        { "phase": "phase_4", "score": 85 }
      ],

      // Validation result (set by Phase 4)
      "validation_result": {
        "evidence": [
          "session.ts:47 — catch returns null",
          "home.ts:14, profile.ts:22, settings.ts:31 — deref without null check",
          "Reproduction: DB timeout → crash on 11 routes"
        ],
        "blast_radius": {
          "writers": ["session.ts:47", "session.ts:62"],
          "consumers": ["home.ts:14", "profile.ts:22", "+8 routes/*"],
          "parallel_paths": ["guest.ts:18 guestSession() — same shape"],
          "invariants_at_stake": ["User non-null contract unenforced"]
        },
        "fix_proposal": {
          "approach": "Throw typed SessionUnavailable; add route-level error boundary",
          "files_to_modify": [
            {"file": "src/auth/session.ts",   "what": "...", "why": "..."},
            {"file": "src/auth/guest.ts",     "what": "...", "why": "parallel path"},
            {"file": "src/routes/_error.tsx", "what": "...", "why": "user recovery"}
          ]
        },
        "verification_context": {
          "how_to_verify_fix": [
            "grep 'authenticateUser' — confirm no caller has dead null-check",
            "grep 'guestSession' — confirm same pattern applied",
            "Confirm _error.tsx catches SessionUnavailable"
          ],
          "edge_cases_to_preserve": ["Empty response body", "Session expired mid-request"],
          "what_would_break_if_incomplete": [
            "If guest.ts not fixed: guest flows still crash on DB timeout"
          ]
        }
      },

      // Fix attempts (append-only; one entry per fix_run that touched this finding)
      "fix_attempts": [
        {
          "run_id": "fixrun_01JX9B...",
          "timestamp": "2026-04-17T20:15:03Z",
          "fix_group_id": "FG-1",
          "input_sha": "a3f8d7c9",
          "output_sha": "c01ab2ef",                // null for findings whose fix group was reverted as a regression (§4 Phase 9b) — no commit was made for this finding
          "phase_9_outcome": "verified"            // verified | partial | regression
          // for partial: "phase_9_finding": "fix missed 3rd writer in session.ts:62", "revised_fix_proposal": { ... }
          // for regression: "phase_9_finding": "fix created new 401 path for valid tokens in auth.ts:95", "revised_fix_proposal": { ... }, and the fix_group_id's edits were reverted from the working tree before commit
        }
      ],

      // Pre-existing bookkeeping (null when origin != pre_existing)
      "introduced_in_sha": null,
      "suggested_follow_up": null,

      // Sibling investigation linkage (for Wave 2; usually null)
      "related_parent_finding_id": null
    }
  ],

  "cross_cutting_groups": [
    {
      "id": "G1",
      "finding_ids": ["F001", "F003"],
      "combined_approach": "Fix F001's pattern first; F003 becomes trivial once..."
    }
  ],

  "subagent_tokens": {
    "total": 482301,
    "invocations": 34,
    "by_phase":  { "phase_1": 47892, "phase_2": 3120, "phase_3": 8901, "phase_4": 389127, "phase_5": 891 },
    "by_model":  { "opus": 421608, "sonnet": 58112, "haiku": 2581 },
    "by_lens":   { "L1": 2581, "L2": 32100, "L3": 4211, "L4": 3100, "L5": 4200, "L6": 1700 },
    "by_finding_phase4": { "F001": 28100, "F002": 22400 }
  },

  "metrics": {                               // per-run, for rollout evaluation
    "phase_9_verified_pct": null,            // set after first fix_run
    "required_followup": null,               // set after first fix_run
    "time_elapsed_seconds": 1247,
    "pr_size_buckets": { "files_changed": 11, "lines_changed": 340 }
  }
}
```

### Schema notes

- **Single `findings[]` is the canonical list.** Report sections (§7) are *views* over this array, not separate stored collections. Section selectors filter on `disposition` (§5.2.1), not on prose `reason` text.
- **`disposition` is a finding-level enum** (§5.2.1) set by Phase 3, Phase 4, or Phase 9. `is_actionable` is derived from it. Writer scripts reject writes where the two disagree.
- **`fix_attempts` is per-finding, append-only.** Run-level summaries are derived at render time by grouping entries across findings by `run_id`. `output_sha` is `null` in several cases: regression-classified findings whose fix group was reverted, all-regression runs, overlap-abort runs (Phase 9.pre), and per-group-revert-failure runs. Any run that did not produce a commit records `output_sha: null` rather than omitting the entry — this keeps the next run's staleness check accurate (§13.3, §24.4).
- **Fix groups are not persisted** in the artifact — `group-fixes.py` recomputes them per fix run. Their identifiers appear only in each finding's `fix_attempts[].fix_group_id` for linkage back to the run's per-group outcome. **`fix_group_id` is unique only within a `run_id`**, not globally; the pair `(run_id, fix_group_id)` is what actually identifies a specific group. Cross-run joins key off `run_id` first.
- **No chunking; no checksum; no `disproven_fingerprints[]`; no `fix_runs[]`.** All dropped in rev 4.
- **`score_phase3` / `score_phase4` are cached top-level fields** on each finding for fast filter access (e.g. `jq '.findings[] | select(.score_phase4 >= 60)'`). They duplicate the latest entry in `score_history` for their respective phase. Writer scripts keep them in sync when appending to `score_history`.
- **`reviewer_sources`** (top-level) is the run-level list of reviewer providers that produced at least one candidate: `"internal"`, adapter-registry names (`"codex"`, `"coderabbit"`), and `"external-pr:<bot-login>"` entries from Phase 1.5 scrape. Distinct from each finding's `sources[]`, which is fine-grained (e.g. `"L2-structural"`, `"codex"`, `"external-pr:greptile-apps[bot]"`).
- **`review_started_at`** is captured at Phase 0 entry **before any state mutation (push, stash)** so Phase 1.5's external-comment scrape window doesn't miss bot comments posted in the gap between push and capture.
- **`reviewed_files_all`** is the staleness envelope (every file in the diff at review time). The narrower `reviewed_files_with_findings` (union of `finding.file` across `findings[]`) is computed at render time for display and is *not* stored. Staleness logic (§13.3) uses `reviewed_files_all`.
- **`comment_id`** is set the first time `artifact-publish.sh` successfully posts the review comment. `/adams-review-fix` and `/adams-review-promote` read it and pass it forward as `--comment-id` to PATCH the same comment in place. Fresh `/adams-review` runs start with `comment_id: null` and POST a new comment — the publisher has no marker-search auto-discovery fallback (§13.4).
- **`trivial_mode`** downshifts the pipeline (§13.9). Stored so post-mortem and `phases.jsonl` diffs can explain why certain lenses didn't run.
- **`base_context`** records the §13.10 freshness reconciliation for this run. Optional — artifacts written before §13.10 landed (or from builds that skip the fetch, e.g., offline) still validate without it. When present, `comparison_ref` is the authoritative ref that Phase 0/1 diff-producing code actually used; `base_branch` (required, top-level) stays as the user-visible name. Renderers surface non-`fresh` states via a header line (§7).
- **Schema validation** runs at every write boundary. Invalid writes fail loud; the orchestrator sees the error and can retry.

---

## 7. Report format

The rendered report is a set of filtered views over `findings[]`. **Section selectors filter on `disposition`** (§5.2.1), so report counts are deterministic derivations from the same machine-readable field Phase 8 uses. Same content in the chat mirror and the PR comment. Markdown only — no embedded JSON block. The very first line of the body is a stable HTML-comment marker — used by Phase 0 step 0.14's recovery lookup when a prior PR comment exists but the local artifact was wiped (§13.4).

```markdown
<!-- adams-review-v1 -->
### Code review

**Branch:** `feature/auth-hardening` → `main`
**PR:** #1234 (draft)
**Review ID:** `rev_01JX9A3P4B8M...`
**Base freshness:** ⚠ local `main` was 12 commits behind `origin/main`; compared against `origin/main` instead
**Fix threshold:** not yet set (run `/adams-review-fix [threshold]` to apply fixes)
**Sub-agent tokens:** 482,301 across 34 invocations

Found 9 findings across all lanes:
- Deep lane (correctness/security): 4 auto-fixable, 1 manual, 1 uncertain
- Light lane (ux/policy/architecture): 1 auto-fixable, 1 manual
- Pre-existing (high-confidence origin, report-only): 1

---

## Deep lane — correctness & security

### ✓ Auto-fixable (4)

| # | Score | Impact | File | Issue |
|---|-------|--------|------|-------|
| F001 | 85 | correctness | `src/auth/session.ts:42-58` | Null leak to callers assuming non-null |
| F002 | 80 | correctness | `src/cache/sync.ts:110-130` | Missing invalidation after write |
| F003 | 78 | correctness | `src/auth/guest.ts:18-30` | Same pattern as F001 (parallel path) |
| F004 | 72 | security | `src/api/auth.ts:80-95` | Missing auth check on admin-only route |

**Cross-cutting group G1:** F001 + F003 — parallel code paths, fix together.

<details><summary>Details and fix proposals</summary>... per-finding rich blocks ...</details>

### ⚠ Requires manual attention (1)

_Not touched by `/adams-review-fix` by default. To force-apply as auto-fix, run `/adams-review-promote <finding_id>`._

| # | Score | Impact | File | Issue | Why manual |
|---|-------|--------|------|-------|-------------|
| F005 | 78 | correctness | `src/billing/invoice.ts:55-80` | Partial-refund branch incomplete | design decision; needs product input |

### ℹ Uncertain (1)

| # | Score | Impact | File | Issue |
|---|-------|--------|------|-------|
| F006 | 55 | correctness | `src/api/search.ts:33` | Query string possibly not escaped |

Phase 4 couldn't confirm decisively. Re-run `/adams-review` if you suspect this deserves
further investigation with fresh context.

---

## Light lane — ux, policy, architecture

_Light-lane findings are not touched by `/adams-review-fix` by default — including rows labeled auto-fixable. To force-apply any row as auto-fix, run `/adams-review-promote <finding_id>`._

| # | Score | Impact | File | Finding | Disposition |
|---|-------|--------|------|---------|-------------|
| F007 | 60 | ux | `src/components/DeleteButton.tsx:12` | Missing loading state on destructive action | manual |
| F008 | 65 | policy | `src/utils/array.ts:4` | Should use `Array.from` per CLAUDE.md | auto-fixable |

---

## Pre-existing — report-only (1)

Shown only when `origin_confidence: high`. Never auto-fixed in v1 (§13.1 pre-existing override).

| # | Score | File | Finding | Follow-up |
|---|-------|------|---------|-----------|
| F009 | 70 | `src/models/user.ts:12` | No index on `email` | File as separate issue |

---

🤖 Generated with Adam's Claude Code Review Command
```

After `/adams-review-fix` runs, the primary comment is edited in place (`gh api -X PATCH` via the `comment_id` the fix loop reads from the artifact, §13.4). A `## Fix runs` section is appended showing each run's summary, and the "Auto-fixable" table gains a Status column with `✓ verified` / `⚠ partial` / `✗ regression (reverted)`, each linking to a commit SHA (when a commit exists — regression-group findings link to no SHA because the revert means no commit was made for them; all-regression runs have no SHA at all).

When `/adams-review-walkthrough` runs (§28), the primary comment is re-rendered in place via the same `comment_id` path so it reflects any newly-promoted findings. Independently, a separate **Walkthrough decisions** comment is POSTed as a new comment — not an edit — carrying the per-finding audit log (briefing option picked, rationale, fix-hint) for that session. Each walkthrough run posts a fresh decisions comment; the primary comment stays canonical for current state.

---

## 8. Helper scripts contract

Four categories of scripts live in `~/.claude/commands/_shared/tools/`. All receive absolute paths and named args; all produce error-as-prompt messages on failure.

### 8.1 Readers (safe for any agent)

| Script | Purpose |
|---|---|
| `artifact-read.sh --filter '<jq expr>'` | Query findings[] (e.g., fix-eligible: `current_state == "open" AND (.disposition \| IN("confirmed_auto", "partial", "regression")) AND score_phase4 >= threshold`; report sections: filter by `disposition`) |
| `artifact-read.sh --finding-id <F001>` | Single finding lookup |
| `artifact-read.sh --summary` | Counts per `current_state`, `disposition`, `impact_type`, `validation_lane` |

### 8.2 Writers (orchestrator-only)

| Script | Purpose |
|---|---|
| `artifact-patch.py --finding-id <F001> --set <field=value> [--append-fix-attempt '<json>']` | Mutate a finding; enforces state-transition whitelist |
| `artifact-patch.py --add-finding '<json>'` | Add a new finding (used during detection result aggregation) |
| `artifact-patch.py --init <json>` | Create a fresh artifact from a seed doc (used once at the start of Phase 6) |

All writers support `--dry-run` to validate without applying.

### 8.3 Validators

| Script | Purpose |
|---|---|
| `artifact-validate.sh --path <file>` | Schema validation; exits non-zero with human-readable issues |

### 8.4 Finalizers / rendering

| Script | Purpose |
|---|---|
| `artifact-render.py` | Render `artifact.json` → `artifact.md` |
| `artifact-publish.sh --mode pr \| local` | PR mode: post `artifact.md` to PR comment (edit if exists, else create). Local mode: no-op (the rendered `artifact.md` is already on disk from `artifact-render.py`, and `latest.txt` was set by Phase 6). See §21.6. |

### 8.5 Utility

| Script | Purpose |
|---|---|
| `claude-md-paths.sh --repo-root <path> --files <f>[,<f>...]` | Walk up from each file to repo root; collect `CLAUDE.md`; dedupe; root-first. Pure Bash — no LLM. |
| `staleness.sh --reviewed-sha <s> --reviewed-files <f>...` | File-overlap classification: safe / warn / unsafe |
| `group-fixes.py --artifact <path> --eligible-finding-ids <list>` | Union-find fix grouping — orchestrator passes the pre-filtered eligible list |
| `external-scrape.sh --pr <num>` | Query GitHub for issue / review / review-comment streams; filter to bot authors not on the deny-list; emit normalized comment JSON for `comment-freshness.sh` and the Sonnet normalizer. |
| `comment-freshness.sh --pr <num> --reviewed-files <csv\|@->` | Code-locality filter on the scrape output — drops bot comments whose referenced code has changed between when they were posted and HEAD (§13.13). |
| `log-phase.sh --phase <n> --name <name> --summary <text>` | Append to `trace.md` |
| `log-phase.sh --phase <n> --record <json>` | Append a record to `phases.jsonl` |

### 8.6 Error-as-prompt convention

Every script on non-zero exit emits to stderr:

- **What went wrong** (specific field, specific constraint)
- **Valid values / IDs** (enum members, available finding IDs)
- **How to recover** (did-you-mean, next required step)

Example:

```
$ artifact-patch.py --finding-id F001 --set current_state=in_progress
ERROR: invalid state value 'in_progress'
Valid states: open | attempted | resolved
Did you mean 'attempted'?

$ artifact-patch.py --finding-id F001 --set current_state=resolved
ERROR: invalid transition from 'open' to 'resolved'
Valid transitions from 'open': attempted
A finding must be attempted before it can be resolved.
```

The orchestrator (a model) sees these and retries correctly. Cryptic technical errors (raw `jq` errors) are always wrapped in our human-readable layer.

**Implementation note.** Each top-level command (`adams-review.md`, `adams-review-fix.md`) must include a short instruction block teaching the orchestrator how to handle script errors — e.g., *"When a helper script exits non-zero, the stderr message will list valid values and suggest corrections. Parse it, retry the call with corrected inputs, and only escalate to the user if a second retry fails."* Without this, the orchestrator has to infer the convention from examples, which is less reliable.

### 8.7 `allowed-tools` grants

Each script is explicitly listed in the top-level command's frontmatter:

```yaml
allowed-tools:
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-read.sh:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-patch.py:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-validate.sh:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-render.py:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-publish.sh:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/claude-md-paths.sh:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/staleness.sh:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/group-fixes.py:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/external-scrape.sh:*)
  - Bash(/Users/adammiller/.claude/commands/_shared/tools/log-phase.sh:*)
  - Bash(git:*)
  - Bash(gh:*)
  - AskUserQuestion
  - Agent
  - Read
```

Absolute paths so the grant is specific. Tight-scoped is deliberate.

**Validation note.** Before building all scripts, create one throwaway command with a single `Bash(/absolute/path:*)` grant and confirm Claude Code honors it without prompting on every call. If absolute-path patterns don't match as expected in the running version of Claude Code, fall back to relative command names (`Bash(artifact-read.sh:*)`) and ensure `~/.claude/commands/_shared/tools` is on `PATH` via a shell rc or a `!\`export PATH=...\`` preamble in the command file. Don't discover this mid-build.

**Symlink / grant-path interaction (for the recommended hybrid build layout — develop in `~/Projects/adams-review-command/`, symlink into `~/.claude/commands/`).** Claude Code's documented permission model for file-access allow-rules requires *both* the symlink path and its resolved target to satisfy the rule. Whether the same two-path semantics applies to `Bash(/script:*)` grants (rather than to Read/Edit file rules) is **not explicitly documented** — it's unverified at time of writing. The safe assumption: the declared grant path and the invocation path must match exactly as strings, AND the resolved target path may *also* need to match. Don't assume either behavior — test it.

**Rule to follow in the command files, regardless of the underlying semantics.** Always invoke helpers via the `~/.claude/commands/_shared/tools/...` path (or its absolute form, `/Users/adammiller/.claude/commands/_shared/tools/...`). That path exists whether `_shared` is a real directory or a symlink. Never invoke helpers via the dev-repo path directly — that couples the command to a local dev layout, breaks portability, and adds an extra axis of grant-match divergence. Using the canonical `~/.claude/...` invocation path minimizes the number of string combinations the grant system has to accept.

**Permission-mode interaction (terminology corrected from Claude Code docs).** The modes are `bypassPermissions` (the `--dangerously-skip-permissions` flag, informally "YOLO"), `acceptEdits` (shift+tab auto-accept, edits-only), `plan`, and `default`. Behaviors relevant here:

- **`bypassPermissions`** skips the user-prompt layer for most tool calls, which makes `allowed-tools` grants largely moot *for interactive prompt avoidance*. But there is a separate protected-directory layer: writes to `.git`, `.claude`, `.vscode`, `.idea`, `.husky` still prompt even in `bypassPermissions` — except that writes to `.claude/commands`, `.claude/agents`, and `.claude/skills` are explicitly exempted from the protection. Review state is deliberately kept outside `~/.claude/` at `~/.adams-reviews/` (§9.2) to avoid this layer: an early draft of the layout put state at `~/.claude/reviews/...`, which triggered the gate on every write during real runs (build journal cross-stage note 2026-04-18) and is not on the exempt list. With the current layout, `/adams-review` and `/adams-review-fix` writes don't intersect the protected directories in practice.
- **`acceptEdits`** auto-accepts file-editing tools (Edit, Write, NotebookEdit) and common filesystem commands (`mkdir`, `touch`, `mv`, `cp`) within working-directory paths. `Bash` (beyond those file ops), `Agent`, `AskUserQuestion`, and helper scripts still prompt unless listed in `allowed-tools`. This is the mode most affected by grant completeness.
- **`plan`** mode blocks tool calls that make changes entirely.
- **`default`** prompts on every unregistered tool call.

Keep the full grant block written regardless of the mode the user runs under: (a) self-documentation for a reader, (b) the command needs to work in `acceptEdits` or `default` mode for anyone outside YOLO, (c) accidentally running in a non-`bypassPermissions` session without grants creates cascading prompts that disrupt fan-out timing.

**Validation is more important than originally suggested, not less.** Three distinct behaviors interact here — literal grant-string matching, symlink target resolution, and protected-directory rules — and the interactions are underdocumented. Before the full build:

1. Create a throwaway command in the dev repo, symlinked into `~/.claude/commands/throwaway.md`.
2. Add a single grant like `Bash(/Users/adammiller/.claude/commands/_shared/tools/probe.sh:*)` and a matching trivial `probe.sh`.
3. Run the command in `default` mode (not YOLO). Confirm no prompt for `probe.sh`.
4. Try invoking via the resolved dev-repo path to see whether the grant still matches (expected: it may or may not; document what you find).
5. Try invoking via a tilde form (`~/.claude/...`) vs the absolute form (`/Users/adammiller/.claude/...`) to see whether Claude Code normalizes or matches literally.

Once the experiment converges on the actual behavior, update this section to replace the "unverified" language with an empirically confirmed rule. If absolute-path patterns don't match reliably, fall back to relative command names (`Bash(artifact-read.sh:*)`) with `~/.claude/commands/_shared/tools` on `PATH`. Don't discover this mid-build.

---

## 9. File and directory layout

### 9.1 Command files

```
~/.claude/commands/
├── _shared/
│   ├── 00-preflight.md
│   ├── 01-detection.md
│   ├── 02-ensemble-adapter.md      ← conditionally included when --ensemble is set
│   ├── 03-dedup.md
│   ├── 04-scoring-gate.md
│   ├── 05-validation.md
│   ├── 06-cross-cutting.md
│   ├── 07-finalize.md
│   ├── 08-fix-loader.md
│   ├── 09-fix-execution.md
│   ├── 10-post-fix-and-commit.md
│   ├── lens-ux-reference.md
│   ├── lens-security-reference.md
│   ├── schema-v1.json
│   └── tools/
│       ├── artifact-read.sh
│       ├── artifact-patch.py
│       ├── artifact-validate.sh
│       ├── artifact-render.py
│       ├── artifact-publish.sh
│       ├── claude-md-paths.sh
│       ├── external-scrape.sh
│       ├── staleness.sh
│       ├── group-fixes.py
│       └── log-phase.sh
├── adams-review.md
└── adams-review-fix.md
```

Top-level command files are thin shells: frontmatter + sequence of `` !`cat` `` preprocessor includes.

### 9.2 Review state directory (per run)

```
~/.adams-reviews/
└── <repo-slug>/                         ← e.g. "adammiller-projects-foo"
    └── <branch>/                        ← e.g. "feature-auth-hardening"
        ├── latest.txt                   ← contains most recent <review_id>
        └── <review_id>/
            ├── artifact.json            ← canonical machine state
            ├── artifact.md              ← rendered report
            ├── trace.md                 ← narrative phase log (includes each sub-agent's agentId)
            ├── tokens.jsonl             ← per-sub-agent usage entries
            └── phases.jsonl             ← one line per completed phase
```

- `<repo-slug>` derivation: `git remote get-url origin 2>/dev/null` → strip scheme, strip leading `git@`, replace `:` with `/`, **strip trailing `.git`**, lowercase, replace `/` with `-`, allow only `[a-z0-9._-]` (substitute `_` for anything else). Example: `git@github.com:adammiller/projects-foo.git` → `github.com-adammiller-projects-foo`. Fallback if no remote: sanitized absolute path of repo root (prefixed `local-`). Canonical implementation: `commands/_shared/tools/repo-slug.sh` — Phase 0 (step 0.3) and Phase 7 (fix-loader step 7.2) both call this helper so the two paths cannot drift; the trailing-`.git` strip is the step prose readers historically missed (rev-7 build-journal note 2026-04-18, first-run `/adams-review-fix` produced a slug that didn't match Phase 0's on-disk directory). This avoids collisions between distinct repos that happen to share a directory name and keeps the slug stable across checkouts.
- `latest.txt` is a tiny file with the `review_id` of the most recent review on this branch. Helper scripts read this to find "current" without explicit args. Atomic writes (temp + rename).
- No `sub-agent-transcripts/` directory: Claude Code already persists each sub-agent's full conversation to `~/.claude/projects/<project-slug>/<session-id>/subagents/agent-<agentId>.jsonl`. Recording the `agentId` in `trace.md` is sufficient to locate any transcript on demand.
- History is preserved: old reviews stay in place. Rough disk usage: ~200KB–1MB per review. A future `/adams-review-cleanup` command can prune if needed.
- **Root override via `$ADAMS_REVIEW_REVIEWS_ROOT`.** The default reviews root is `~/.adams-reviews/`. Users who want their review state elsewhere — e.g., on a different volume, or to keep the pre-Stage-2.5 location at `~/.claude/reviews/` — can export `ADAMS_REVIEW_REVIEWS_ROOT` to override. Helper scripts (`artifact-publish.sh`, `external-scrape.sh`) and the `00-preflight` fragment all consult this env var. The root lives **outside** `~/.claude/` deliberately: Claude Code hardcodes a sensitive-file permission prompt for writes to `~/.claude/...` that survives even `bypassPermissions` mode (see §8.7), and writing review state there would prompt the user on every `trace.md` append, `artifact.json` mutation, and `phases.jsonl` line. Stage 2.5.A (build journal, 2026-04-18) probed this and relocated to bypass the gate entirely.

### 9.3 Scratch files during a run

- `/tmp/adams-review-<run-id>/` for transient Bash and jq outputs. Cleared at run end.

---

## 10. Model allocation summary

| Task | Model | Notes |
|---|---|---|
| Phase 0 CLAUDE.md path list | (none — Bash) | Deterministic file-walk; no LLM |
| Phase 0 user-facing classifier | Haiku | Decides whether L5 runs |
| Phase 0 prior-artifact prompt | (inline) | AskUserQuestion |
| Phase 1 L1 (diff-local) | Haiku | Mechanical scan |
| Phase 1 L2 (structural) | **Opus** | Reasoning-heavy |
| Phase 1 L3 / L4 / L5 / L6 | Sonnet | Structured reads |
| Phase 1 Ensemble externals | (external) | Codex + CodeRabbit wrapper agents; wrapper orchestration tokens tracked |
| Phase 1.5 PR-comment normalizer | Sonnet | One call — normalize scraped bot comments to candidate schema |
| Phase 2 dedup | Sonnet | One call |
| Phase 3 scoring | Sonnet | Err-up rubric |
| Phase 4a deep validation | **Opus** per candidate | Central to correctness |
| Phase 4b light confirmation | Sonnet per candidate | Lighter |
| Phase 5 cross-cutting | **Opus sub-agent** | Pure reasoning over serialized findings; no tool access |
| Phase 8 fix groups | **Opus** per group | Must execute across all files |
| Phase 9 post-fix review | **Opus sub-agent** | Fresh-context reviewer; Read + git-diff + grep only |

Model selection for a sub-agent is expressed in the Agent tool's `model` parameter (when available) or in the orchestrator's prompt ("launch a Sonnet sub-agent that does X"), matching how the existing `/adams-code-review` command operates today. Prefer the explicit `model` parameter — more deterministic.

### 10.1 Effort is a session-wide multiplier (not a per-sub-agent knob)

Claude Code's `effort` setting is session-wide. Sub-agents dispatched from this command inherit the parent session's effort level, and there is **no documented way to override effort per-sub-agent at dispatch time** — the Agent tool exposes a `model` parameter but no `effort` parameter. This has been verified against the docs and against three open feature requests on `anthropics/claude-code` ([#25591](https://github.com/anthropics/claude-code/issues/25591), [#31536](https://github.com/anthropics/claude-code/issues/31536), [#43083](https://github.com/anthropics/claude-code/issues/43083)) — all requesting the ability to set per-agent effort, which would not exist as open requests if the capability were already present.

**Cost implications.** Effort multiplies orthogonally with the model-tier table above. A `/adams-review` run at session effort `xhigh` causes *every* sub-agent — the Opus L2, the Opus validators (one per Phase-4a candidate, typically 10-20), the Opus cross-cutting reviewer, the Opus fix-group agents, the Opus post-fix reviewer, and every Sonnet/Haiku sub-agent — to run at `xhigh`. The plan's model-tier allocation controls *which model* runs each task; session effort controls *how hard each of those models thinks*. Both multiply.

**Practical guidance for v1:**

- **Routine runs:** `medium` or `high` is likely the right baseline. Reserve `xhigh`/`max` for deliberate cases (a PR known to be subtle, a post-mortem of a missed bug, or a calibration run where you want the highest-fidelity agent reasoning you can get to compare against lower-effort runs).
- **Observability catches surprises.** The `subagent_tokens` tallies in `tokens.jsonl` (§11) are exactly the tool for noticing when session-effort changes blow up costs. After the first couple of real runs at a given effort level, check the per-phase totals and compare to what you'd expect.
- **If the per-sub-agent effort feature ships in a future Claude Code version, this plan's effort guidance becomes finer-grained** — e.g., run Haiku/Sonnet lenses at low/medium effort while keeping deep validators at high/max. Until then, one session-level setting governs them all.
- **Fix-mode can tolerate a lower effort than review-mode.** `/adams-review-fix` mostly runs Opus fix-group agents + one Opus post-fix reviewer (Phase 9). If fix retries are becoming expensive under high session effort, consider running `/adams-review-fix` at a notch lower — the fix work is more mechanical than the deep-validation reasoning in Phase 4a. This is advisory; users set effort to their preference.

---

## 11. Sub-agent token tracking

Each sub-agent's `<usage>total_tokens: N</usage>` block is parsed from its tool result and appended to `tokens.jsonl`:

```jsonl
{"phase": "phase_4a", "agent_role": "validator", "finding_id": "F001",
 "agent_id": "a155388c8759b84b6", "model": "opus", "tokens": 27714,
 "timestamp": "2026-04-17T19:23:14Z"}
```

The `agent_id` field lets future post-mortem work locate the sub-agent's full JSONL transcript at `~/.claude/projects/<slug>/<session>/subagents/agent-<agent_id>.jsonl`.

**Parse-failure fallback.** If the `<usage>` block can't be extracted (unexpected format, missing block, non-numeric content), log `"tokens": null` in the JSONL row and continue. Token tracking is observability, not correctness — a failed parse must never break the pipeline.

At report time, a Bash/jq pass tallies into `subagent_tokens` in the artifact (total, invocation count, per-phase, per-model, per-lens, per-finding). Example `by_phase` keys: `phase_1`, `phase_1_5`, `phase_2`, `phase_3`, `phase_4a`, `phase_4b`, `phase_5`, `phase_8`, `phase_9`. Name is deliberately `subagent_tokens` (not `total_tokens`) — it excludes main orchestrator usage (separately available in Claude Code usage tracking).

**External-reviewer orchestration tokens.** The wrapper agents for external reviewers (e.g., `codex:codex-rescue`, `coderabbit:code-reviewer`) ARE Claude sub-agents whose `<usage>` blocks report Claude orchestration tokens — those wrapper costs ARE tracked, bucketed under `phase_1_ensemble`. What is NOT tracked is the external service's own internal LLM spend (Codex's or CodeRabbit's API costs), which is billed separately by the respective provider.

---

## 12. Observability and retrospective evaluation

First-class v1 feature. When a run finishes (successfully or not), the per-review directory contains everything needed to diagnose what happened.

### 12.1 `phases.jsonl`

One line per completed phase, JSON object. Each record carries `counts_by_state` AND `counts_by_disposition` — the former lets you see the open/attempted/resolved shape, the latter shows *why* each finding is where it is (the primary routing key from §5.2.1). For phases that predate disposition assignment (Phase 1, Phase 2), `counts_by_disposition` may be `{"unassigned": N}`.

```jsonl
{"phase":1,"name":"detection","elapsed_sec":45,"counts_by_state":{"open":47},"counts_by_disposition":{"unassigned":47},"delta":"+47 open","ts":"..."}
{"phase":2,"name":"dedup","elapsed_sec":8,"counts_by_state":{"open":38},"counts_by_disposition":{"unassigned":38},"delta":"-9 merged","ts":"..."}
{"phase":3,"name":"scoring-gate","elapsed_sec":22,"counts_by_state":{"open":38},"counts_by_disposition":{"below_gate":14,"pending_validation":24},"delta":"14 gated below validation, 24 advanced","ts":"..."}
{"phase":4,"name":"validation","elapsed_sec":612,"counts_by_state":{"open":38},"counts_by_disposition":{"below_gate":14,"disproven":5,"uncertain":4,"confirmed_auto":9,"confirmed_manual":4,"confirmed_report":1,"pre_existing_report":1},"delta":"24 validated: 9 auto, 4 manual, 1 report, 5 disproven, 4 uncertain, 1 pre-existing","ts":"..."}
{"phase":9,"name":"post-fix-review","elapsed_sec":187,"counts_by_state":{"open":32,"resolved":6},"counts_by_disposition":{"below_gate":14,"disproven":5,"uncertain":4,"confirmed_manual":4,"confirmed_report":1,"pre_existing_report":1,"partial":2,"regression":1,"resolved":6},"delta":"6 verified, 2 partial, 1 regression (group FG-3 reverted)","ts":"..."}
```

Diffing two consecutive lines tells you exactly what each phase changed. Replaces rev 3's separate `phase-snapshots/*.json` files. Post-mortem tools filter on `counts_by_disposition` because that's how report sections (§7), Phase 8 eligibility (§5.2.1), and summary counts (§8.1, §21.1) are defined — `counts_by_state` is kept alongside mostly for at-a-glance "did anything resolve" visibility.

### 12.2 Narrative trace

`trace.md` is appended to as phases complete. Short, human-readable, and includes each sub-agent's `agentId`. Typical content:

```markdown
## Phase 1 — Detection (elapsed: 45s)
- Ran 6 internal lenses in parallel (L1, L2, L3, L4, L5, L6)
- Candidates per lens: L1=8, L2=14, L3=9, L4=3, L5=6, L6=7 → total 47
- Sub-agents: L1=agent-abc123, L2=agent-def456, L3=agent-ghi789, ...
- Ensemble: codex=agent-xxx111 (5 findings), coderabbit=agent-yyy222 (9 findings)

## Phase 2 — Dedup (elapsed: 8s)
- LLM dedup pass (agent-jkl321): 47 → 38 (merged 9 near-duplicates)
- Source-family auto-graduations in Phase 3 gate: 6 candidates

## Phase 3 — Scoring + gate (elapsed: 22s)
- Gate pass (≥45 or multi-family): 24 candidates
- Below gate: 14 → is_actionable=false with reason "below validation gate"
```

### 12.3 Post-mortem workflow

```bash
cd ~/.adams-reviews/<repo>/<branch>/<review_id>/

# "Did the run find bug X in file Y?"
jq '.findings[] | select(.file | contains("Y"))' artifact.json

# "What did the phases look like overall?"
cat phases.jsonl

# "Cost breakdown"
jq 'group_by(.phase) | map({phase: .[0].phase, tokens: map(.tokens) | add})' tokens.jsonl

# "Narrative"
cat trace.md

# "What exactly did lens L2 see and say?" — grep trace.md for L2's agentId,
# then open the JSONL transcript directly.
grep 'L2=agent-' trace.md
cat ~/.claude/projects/<slug>/<session>/subagents/agent-<id>.jsonl | jq .
```

Because Claude Code persists sub-agent transcripts automatically, there's no ceremony to capture them — `trace.md` only needs the IDs.

---

## 13. Cross-cutting design decisions

### 13.1 Score decision table (normative)

Each rule sets `disposition` (§5.2.1); `is_actionable` is derived (`true` iff disposition ∈ {`confirmed_auto`, `partial`, `regression`}).

**Pre-existing override (highest priority — evaluated before any score rule):**

```
origin == "pre_existing" AND origin_confidence == "high"
  → disposition: pre_existing_report
  → actionability: report_only
  → is_actionable: false
  → regardless of score
```

This rule is re-asserted at the end of Phase 4 to catch cases where Phase 4a's deep validation bumped a pre-existing finding's score into the confirmed band. v1 never auto-fixes pre-existing issues; a future `--cleanup-pre-existing` flag could override this gate. This preserves the old-command behavior of routing historical issues to the footnote rather than scoping them into the current PR's fix work.

**Phase 3 validation gate (applies to everything that survived the pre-existing override):**

```
score_phase3 < 45 AND single source family
  → disposition: below_gate
  → current_state: open
  → is_actionable: false
  → artifact records it but it does not enter Phase 4

score_phase3 < 45 AND ≥ 2 source families
  → advance to Phase 4 anyway (source-family auto-graduation)

score_phase3 >= 45
  → advance to Phase 4
```

**Phase 4 validation decision (applies after Phase 4a / 4b):**

```
score_phase4 < 45    → disposition: disproven,  is_actionable: false
score_phase4 45-59   → disposition: uncertain,  is_actionable: false
score_phase4 >= 60   → disposition depends on actionability (set by validator):
                         auto_fixable  → disposition: confirmed_auto,    is_actionable: true
                         manual        → disposition: confirmed_manual,  is_actionable: false
                         report_only   → disposition: confirmed_report,  is_actionable: false
                       confirmed_strength: "moderate" (60-74) or "strong" (75+)
```

**Phase 9 outcome (for findings attempted in a fix run):**

```
Phase 9 verified    → disposition: resolved,   current_state: resolved, is_actionable: false
Phase 9 partial     → disposition: partial,    current_state: open,     is_actionable: true
Phase 9 regression  → disposition: regression, current_state: open,     is_actionable: true
                      (finding's fix group reverted in §4 Phase 9b; fix_attempts.output_sha = null)
```

**Fix gate (applied in Phase 8):**

```
current_state == open
  AND disposition ∈ {confirmed_auto, partial, regression}
  AND (
    human_confirmation != null                                      // §27 bypass
    OR (
      impact_type ∈ {correctness, security}                         // §13.2 lane filter
      AND score_phase4 >= threshold                                 // default 60; /adams-review-fix arg
    )
  )
```

Note that `partial` and `regression` are both retry-eligible. The v1 default lets the user re-run fix without a flag to clear residual partial/regression findings, armed with the `revised_fix_proposal` and prior `phase_9_finding` from each finding's last `fix_attempts` entry. Pass a higher threshold (e.g., `/adams-review-fix 80`) to exclude them if needed.

**Manual override.** `/adams-review-promote` (§27) sets `disposition=confirmed_auto`, `actionability=auto_fixable`, and `human_confirmation=<object>` on any finding except `confirmed_auto` (no-op) and `resolved` (rejected). `disproven` requires `--force`. The existing `score_phase4` is preserved (the validator's honest score stays in the audit trail); the `human_confirmation != null` bypass above is what makes the finding fix-eligible regardless of impact_type or score.

The three gating concepts remain distinct:

1. **Validation gate** — Phase 3, internal, constant 45. Keeps junk out of expensive Phase 4.
2. **Confirmation decision** — Phase 4, breakpoints at 45, 60, 75. Maps score to `disposition` + `confirmed_strength`.
3. **Fix gate** — Phase 8, user-tunable (default 60). Determines which `confirmed_auto`/`partial`/`regression` findings actually run through the fix engine.

### 13.2 Thresholds

| Threshold | Applied to | Default | User-facing? |
|---|---|---|---|
| Validation gate | `score_phase3` | 45 | No |
| Fix gate | `score_phase4` (on auto_fixable deep-lane findings) | 60 (provisional) | Yes, arg to `/adams-review-fix` |

Optional flag (future): `--include-light-fixes` to also fix light-lane `auto_fixable` findings (e.g., mechanical CLAUDE.md rule compliance). Off by default.

**Human override precedence.** A non-null `finding.human_confirmation` (set by `/adams-review-promote`, §27) bypasses both the impact_type lane filter and the `score_phase4` threshold. The threshold above still applies to every validator-scored finding; it only ceases to apply to the specific findings a human has explicitly promoted.

### 13.3 Staleness protection

File-overlap check in Phase 7:

```
If HEAD == latest_known_sha: safe, proceed
Else:
  changed_files = git diff --name-only latest_known_sha..HEAD
  if changed_files ∩ reviewed_files_all == ∅: warn and proceed
  else: abort (or --force to override with warning)
```

`reviewed_files_all` is stored in the artifact (every file in the diff at review time — the full safety envelope). This differs from a narrower "files that produced findings" set because a file could have been reviewed and found clean; if it subsequently changes, that's still a reason to consider the review stale. The narrower `reviewed_files_with_findings` (union of `finding.file`) is computed at render time for display purposes only and is not used for staleness.

### 13.4 Comment updating (PR mode)

Each of the three top-level commands has a clear rule for how it interacts with the PR comment:

- **Fresh `/adams-review`** — always `POST` a new comment. Every invocation is a distinct review event; the prior comment (if any) is left untouched on the PR.
- **`/adams-review-fix`** — always `PATCH` the prior review's comment. The fix loop inherits `comment_id` from the artifact it's fixing and passes it to the publisher via `--comment-id`, so updated state lands on the same comment the review originally posted.
- **`/adams-review-promote`** — always `PATCH` the same comment. Promote is a metadata edit of an existing review; it reads `comment_id` from the artifact and passes it explicitly.

**Comment discovery — in order:**

1. **`--comment-id` supplied** → `PATCH` that comment directly. Caller has established continuation intent by passing the id.
2. **No `--comment-id`** → `POST` a new comment.

The publisher does not auto-discover a prior comment. Continuation is the caller's responsibility.

**Fallback behavior.** If `PATCH` fails mid-edit (e.g., the comment was deleted out of band), fall back to `POST`; log the old `comment_id` to `trace.md`; emit the new id for the caller to persist. Never leaves the user without a visible review on the PR.

**Stable marker.** Every rendered `artifact.md` still opens with `<!-- adams-review-v1 -->`. It is no longer used by the publisher, but Phase 0 step 0.14 uses it as a recovery-lookup signal: when a prior PR comment exists with no local artifact, step 0.14 finds that comment by marker and offers the user three choices — post new (default), replace-in-place (opts into PATCH by capturing the comment id as `existing_comment_id`), or abort.

**Design history.** Rev 5 used a `review_id`-bearing marker and a new run posted a fresh comment alongside the prior — the review comments accumulated. Rev 6 replaced this with a stable marker and auto-PATCH-by-marker-search in the publisher, so every run edited the same comment in place. Rev 7 (this rev) removes the publisher's auto-discovery: `/adams-review` reverts to the rev-5 behavior (new comment per run), but `/adams-review-fix` and `/adams-review-promote` keep the rev-6 behavior (edit in place) by carrying `comment_id` forward from the artifact. This lets each command follow the rule that actually matches its semantics, instead of a one-size-fits-all policy in the publisher.

### 13.5 Project-configurable verification commands

Optional `~/.adams-reviews/review-config.json` (global) or `.claude/review-config.json` (per-repo; takes precedence):

```json
{
  "verification_commands": [
    { "name": "typecheck", "command": "tsc --noEmit {{files}}",
      "on": ["**/*.ts", "**/*.tsx"] },
    { "name": "lint", "command": "eslint {{files}}",
      "on": ["**/*.{ts,tsx,js,jsx}"] }
  ]
}
```

Off by default. When configured, Phase 8 runs matching commands for fix-group files; Phase 9 consumes exit codes into post-fix review. Per-repo config fully overrides global when both exist.

### 13.6 Commit strategy

- **Execution unit:** per fix group (parallel Opus agents).
- **Default history unit:** one combined commit for all *surviving* fix groups (verified + partial) after Phase 9 completes.
- **`--granular-commits`:** opt into one commit per surviving fix group.
- **Per-group revert:** regression-classified groups are reverted (modified files restored, created files deleted) before commit. Never ship a Phase-9-classified regression (§4 Phase 9b).
- **All-regression degenerate case:** every group regressed → reverts cover the entire working tree → no commit.

Execution unit (efficiency) is decoupled from history unit (reviewability) and from trust unit (per-group revert).

### 13.7 State mutation discipline

- Sub-agents never mutate artifact state directly.
- Orchestrator is the only mutating actor.
- Writes go through writer scripts with schema validation + state-transition whitelist.
- Schema validation at every write boundary catches drift before it persists.

### 13.8 External-reviewer bot allow/deny (Phase 1.5)

Phase 1.5 scrapes PR comments by bot authors posted after `review_started_at`. The bot universe is policed by a small allow/deny config, read from (in order of precedence) `.claude/review-config.json` (per-repo) then `~/.adams-reviews/review-config.json` (global):

```json
{
  "external_reviewer_bots": {
    "allow": null,
    "deny":  ["dependabot[bot]", "renovate[bot]", "github-actions[bot]", "codecov[bot]"]
  }
}
```

Semantics:

- `allow: null` (default) → allow all bot authors except those in `deny`. New reviewers you add to a repo auto-participate with zero config.
- `allow: [list]` → strict allowlist; only listed bots are scraped. `deny` still wins over `allow` when both contain the same login.
- The built-in `deny` list above captures status/automation bots that aren't reviewers. User config can extend or replace it.

When in doubt, a bot's candidates can also be filtered later: `origin_confidence: low` for all external findings means they only surface after corroboration with an internal family (same rule as codex/coderabbit — §4 Phase 1).

### 13.9 Trivial-diff early exit (narrow)

Phase 0 runs a cheap Bash check to identify PRs where the full pipeline's cost isn't justified. If **all** of the following conditions hold, `artifact.trivial_mode = true`:

- `git diff --name-only <base>..HEAD` returns ≤ 3 files
- `git diff --shortstat <base>..HEAD` reports ≤ 30 total lines changed (additions + deletions)
- **Every** changed file matches a doc/config extension from this allow-list:
  `*.md`, `*.mdx`, `*.txt`, `*.rst`, `*.yaml`, `*.yml`, `*.json`, `*.jsonc`, `*.toml`, `*.ini`, `*.cfg`, `*.conf`, `LICENSE`, `LICENSE.*`, `CHANGELOG*`, `NOTICE*`, `.gitignore`, `.editorconfig`, `.npmrc`, `.nvmrc`

**Effect on the pipeline when `trivial_mode == true`:**

| Phase | Effect |
|---|---|
| Phase 1 | L2 (structural), L5 (UX), L6 (security) are **skipped**. L1 (diff-local), L3 (CLAUDE.md), L4 (comment compliance) still run — these stay cheap and still matter for doc/config PRs. |
| Phase 1.5 | **Unaffected.** External reviewers decide independently whether to comment. |
| Phase 2 | Dedup runs normally. |
| Phase 3 | Scoring runs normally (cheap). |
| Phase 4 | Deep lane (4a) is **skipped** — all candidates go through 4b light confirmation. |
| Phase 5 | Skipped (no deep-lane findings exist). |
| Phases 6-9 | Unaffected structurally. |

**Review-only in v1.** Trivial-mode findings are **never Phase-8-eligible** in v1. Phase 4a is skipped in trivial mode, so no candidate acquires the Phase 4a `validation_result` (with `blast_radius`, `fix_proposal`, and `verification_context`) that Phase 8 and Phase 9 depend on. To enforce this at the disposition layer rather than relying on fragile downstream checks, **Phase 4b running under `trivial_mode == true` never assigns `actionability: auto_fixable`** (§19.6) — it can only emit `manual` or `report_only`. The Phase 4 decision in §13.1 then routes every confirmed trivial-mode finding to `confirmed_manual` or `confirmed_report`, both of which are outside the Phase 8 eligibility set (`disposition ∈ {confirmed_auto, partial, regression}`). Net: `/adams-review-fix` on a trivial-mode artifact is a no-op (zero eligible findings) and exits with "nothing to fix in trivial-mode review". If this turns out to miss real auto-fixable doc/config issues, lift the restriction in v2 with a dedicated light-auto-fix path that produces the structured `fix_proposal`/`verification_context` shape Phase 8 requires. The current rule prevents a one-shot builder from accidentally wiring Phase 4b output into Phase 8's expected schema.

**Rationale.** Doc/config PRs produce near-zero structural bugs; the Opus-heavy lenses and validators are waste there. The user still gets CLAUDE.md compliance (L3) and comment drift (L4) checks, which are where real doc/config issues live. Deliberately narrow:

- **Any** file with a code extension (.ts, .py, .go, .rs, .java, etc.) forces `trivial_mode = false` and the full pipeline runs, even if the change is 1 line.
- No Haiku classifier is added. A pure Bash ext-check + line-count is deterministic, near-free, and has zero LLM surface area — trivial-misclassification risk is much lower than a model-based classifier, at the cost of some PRs that would have qualified not being detected.

**User override.** `/adams-review --full` forces `trivial_mode = false` for the run, regardless of the diff. Useful when the user knows a doc-only change encodes subtle meaning (e.g., an OpenAPI spec edit that changes runtime behavior, or a CHANGELOG entry that's actually documenting a security disclosure).

**Visible to post-mortem.** `trivial_mode` is stored on the artifact and reflected in `phases.jsonl` (phase 1 skipped-lenses annotation) so a user reviewing results can always see which lenses did and didn't run.

### 13.10 Base-branch freshness (Phase 0 gate)

The review's entire input — diff surface, lens context, origin cross-check — depends on `$base_branch` pointing at the same commit the PR would be compared against upstream. A silently stale local base (local `main` behind `origin/main`) produces correct-looking output at every later phase: lenses see pre-existing commits inside their diff, classify them as introduced, and the §13.1 pre-existing override never fires. The damage is invisible because the renderer's Pre-existing section collapses to nothing when the bucket is empty. This is a Phase-0 invariant, not a post-hoc fix.

**Behavior.** Between base-branch resolution and the first consumer of `base..HEAD`, Phase 0 reconciles local against remote:

1. Run `git fetch origin "$base_branch" --quiet` with a 30s soft timeout.
2. On fetch success, compute `behind_count = git rev-list --count "$base_branch..origin/$base_branch"`.
3. `behind_count == 0` → `base_freshness = "fresh"`, `comparison_ref = $base_branch`, proceed.
4. `behind_count > 0` → `AskUserQuestion` with four options:
   - **(a) Fast-forward local `<base_branch>` and compare against it** (recommended). Runs `git fetch origin <base_branch>:<base_branch>` — refuses non-FF, so local diverged histories surface as an error and (a) is retried with (a) disabled. Sets `comparison_ref = $base_branch`, `base_freshness = "fast_forwarded"`.
   - **(b) Compare against `origin/<base_branch>` without touching local.** `comparison_ref = "origin/$base_branch"`, `base_freshness = "used_remote_ref"`. Nothing in the worktree mutates.
   - **(c) Proceed with stale local `<base_branch>`** (strongly discouraged). `comparison_ref = $base_branch`, `base_freshness = "proceeded_stale"`. Warning appended to `trace.md` and surfaced in the rendered report header (§7).
   - **(d) Abort.**
5. On fetch failure (network, no upstream, timeout): `base_freshness = "no_fetch"`, `comparison_ref = $base_branch`, one-line warning to `trace.md` tagged `fetch_failed`. **Never hard-fails** — offline/airgapped runs must proceed.
6. Repo has no `origin` remote at all: `base_freshness = "no_remote"`, `comparison_ref = $base_branch`. Purely local repos have no remote to be behind.

**Plumbing.** `comparison_ref` is a working-set variable (§25.1). Every downstream `$base_branch..HEAD` reference in Phase 0/1 prompts and helpers resolves through `$comparison_ref..HEAD`. The artifact's top-level `base_branch` field keeps the human name (`"main"`) for display; a new optional `base_context` object records `{freshness, comparison_ref, remote_sha, behind_count}` for reproducibility and report surfacing. `base_context` is optional in the schema — artifacts written by pre-§13.10 builds still validate.

**Why no `--no-fetch` flag.** The fetch cost is small on every repo we care about, the offline path already degrades gracefully to `no_fetch` without prompting, and exposing an opt-out for a data-quality invariant would let users silently reintroduce the original bug class. If the soft timeout becomes a recurring problem on pathological repos, revisit.

### 13.11 Origin cross-check (Phase 1 post-lens)

Phase 1 lens prompts bias toward `origin: introduced_by_pr, origin_confidence: high`: "Default to introduced_by_pr with high confidence unless the implicated code is clearly unchanged by this diff." The default is safe when the diff is correct but silently drops the §13.1 pre-existing override in two failure modes:

1. A user proceeds with a stale base (§13.10 option (c)): pre-existing commits are literally inside the diff, so the lens correctly sees them as modified and defaults to introduced.
2. A candidate's line range straddles a modified hunk boundary: the lens flags a section of pre-existing code because it's *near* changed code, and the default kicks in.

A deterministic blame-based cross-check corrects both cases without an LLM call.

**Algorithm (per candidate from Phase 1, before `--add-finding`).** Given `{file, line_range}`:

1. If `file` did not exist at `comparison_ref` (added by the PR): keep the lens-supplied origin. The file is trivially PR-introduced.
2. Else, run `git blame -L <start>,<end> --porcelain <file>` at HEAD. Collect the distinct commit SHAs touching those lines.
   - **Every SHA is reachable from `comparison_ref`** (none in `comparison_ref..HEAD`): the whole range pre-dates the PR. Override to `origin = "pre_existing", origin_confidence = "high"`. Log `action=overridden` to `trace.md`.
   - **At least one SHA is in `comparison_ref..HEAD`**: the range was modified by this PR. Respect the lens-supplied value. Log `action=respected`.
   - Blame fails (deleted lines, binary file, etc.): respect the lens value, log `action=skipped reason=<...>`.
3. Lens already returned `origin: "pre_existing", origin_confidence: "high"` and blame confirms: no change (fast path; logged as `action=respected`).
4. Lens returned `origin: "pre_existing"` but blame disagrees (at least one SHA in `comparison_ref..HEAD`): keep `origin = "pre_existing"` but drop `origin_confidence` to `"medium"`. The §13.1 override does not fire at medium confidence, so the finding stays in its normal disposition lane instead of being shunted to `pre_existing_report`. Log `action=downgraded`.

**Conservative policy (mixed ranges).** A finding whose range spans PR-modified *and* pre-existing lines is typically about the PR's change creating a problem near pre-existing code; classifying it as pre-existing would hide it from the deep-lane tables. Only the fully-pre-existing case is unambiguous enough to auto-override.

**Placement.** Runs as a Phase-1 step between lens aggregation and `--add-finding`. Phase 2 (dedup) and Phase 3 (scoring) see only post-correction origin values, which is what the §13.1 override keys on. Cost per candidate is one blame + a small number of `git merge-base --is-ancestor` tests — roughly 50ms on typical repos. At 50 candidates that's ~2.5s, a rounding error against Phase 1's 5–10min LLM cost. No tokens.

**Implementation.** `origin-crosscheck.sh` (§21.9) takes `--comparison-ref <ref>` and `--candidates <path|@->` (JSON array), emits the same array with origin/origin_confidence corrected to stdout, and writes one `origin_crosscheck: id=<...> action=<respected|overridden|downgraded|skipped>` line to stderr per candidate for `trace.md`.

### 13.12 Detection parallelization (Phase 1 + Phase 1.5)

On `--ensemble` runs, Phase 1 (six internal lens `Agent` dispatches) and Phase 1.5 (CodeRabbit CLI + Codex CLI + PR bot-comment scrape + Sonnet normalizer) have no data dependency — Phase 2 (dedup) is the first cross-phase consumer. Serial ordering costs 30–50% of detection wall-clock on ensemble runs. This section normalizes the parallel pattern so both phases fan out from a single orchestrator turn. The pipeline remains two logical phases (for schema, logging, and audit attribution); only their wall-clock windows overlap.

**Invariants:**

1. **Single dispatch turn.** When `ensemble_mode == true`, the orchestrator's dispatch turn contains the applicable lens `Agent` tool-use blocks, the CodeRabbit + Codex background `Bash` launches, and the foreground PR-scrape `Bash` call. Waiting a turn between blocks serializes them and negates the entire parallelism gain. Non-ensemble runs fire the lens `Agent` blocks alone in one turn (unchanged from pre-§13.12 behavior).
2. **No IDs during collection.** Both phases accumulate their candidate arrays into orchestrator-context pools (`internal_candidates`, `external_candidates`) with no `id` field set. Partial `--add-finding` writes during collection would race the finding-id counter and produce schema-rejection errors for duplicate ids.
3. **Single join point.** After every lens and the Sonnet normalizer have resolved, one step assigns `F001…F0NN` across the pooled set via the `assign-finding-ids.sh` helper (deterministic sort by source: L1, L2, L3, L4, L5, L6, external-pr, codex, coderabbit; stable within source). One `--add-finding` sweep then commits the full pool.
4. **Pre-dispatch readiness gate.** The ensemble CLI readiness check (CodeRabbit version + auth, Codex companion + ready) runs BEFORE either phase dispatches — in the Phase 1 fragment, not the Phase 1.5 fragment. `AskUserQuestion` on missing CLIs surfaces ahead of any lens token spend, so "stop so I can set them up first" is a zero-token exit.
5. **Non-ensemble short-circuit.** `ensemble_mode == false` skips the readiness gate, the CLI launches, and the normalizer. The join step iterates the internal-only pool. Observable behavior matches pre-§13.12 exactly.

**Token accounting.** Unchanged from §11 — each lens and the normalizer are logged per-agent under their owning phase (`phase_1` for lenses, `phase_1_5` for the normalizer). External CLIs remain untracked per §11's existing carve-out. Parallel dispatch changes wall-clock, not token spend.

**phases.jsonl semantics.** Each phase still logs its own record with its own `elapsed_sec`. Phase 1 elapsed is measured from the dispatch-turn start to the last lens result returning. Phase 1.5 elapsed is measured from the same dispatch-turn start (`phase_1_5_start_epoch` is captured in the readiness gate, immediately before the dispatch turn) to the normalizer result returning. Under parallel dispatch, the `ts` timestamps on the two phase records overlap — that's what makes concurrency observable in the log. `elapsed_sec` reflects each phase's own longest path, so typically `phase_1_5.elapsed_sec ≥ phase_1.elapsed_sec` (the normalizer tails after the last lens), approaching `max(internal, external)` overall rather than the pre-§13.12 `phase_1 + phase_1_5`.

**UX note on readiness gate placement.** Hoisting the gate ahead of dispatch means a user invoking `/adams-review --ensemble` sees the "CodeRabbit/Codex missing" prompt promptly after Phase 0 completes, not after Phase 1 has already run. This is the intentional direction of the change: zero wasted token spend on "stop to set up" exits. The tradeoff is a user-visible prompt that may feel early if they're expecting the command to plow ahead — acceptable for a user-authorization surface.

**Implementation pointer.** Readiness gate lives in `01-detection.md` step 1.2a. Joint dispatch is documented in `01-detection.md` step 1.3 with launch specs referenced from `02-ensemble-adapter.md`. Join + ID assignment lives at `01-detection.md` step 1.5 and calls `assign-finding-ids.sh`. Non-ensemble short-circuits are handled per-step with `ensemble_mode` guards.

### 13.13 PR comment freshness (Phase 1.5 post-scrape filter)

Phase 1.5's PR-comment scrape (`external-scrape.sh`, §21.8) returns every bot-authored comment from the three GitHub PR-comment endpoints. Not every one is still relevant: a bot comment whose referenced code has changed since it was posted is stale signal. Time-axis filters ("only comments posted after the review started") don't correlate with relevance — a three-week-old inline comment on an unchanged file is still actionable; a minute-old summary on a file that just got rewritten isn't. This section defines a code-locality filter applied between the scraper and the Sonnet normalizer.

**Per-record decision (keyed on the `kind` field the scraper emits):**

| `kind` | `commit_id` | `path` | Check |
|---|---|---|---|
| `review_comment` (inline) | present | present | `git diff --name-only <commit_id>..HEAD -- <path>` empty → include. Non-empty → exclude. |
| `review` (submission) | present | null | `git diff --name-only <commit_id>..HEAD` ∩ `reviewed_files_all` empty → include. Non-empty → exclude. |
| `issue_comment` (general) | null | null | Fetch `pulls/<pr>/commits`; `latest = max(.commit.committer.date)`. Include iff `comment.created_at > latest`. Otherwise exclude. |

**Issue-comment policy (C2).** Diff-wide comments carry no code coord, so the closest-equivalent freshness signal is "did any commit land on the PR branch after this comment was posted." A PR-level summary (e.g. Greptile posting an overall review) posted *after* the latest commit is included; any subsequent push invalidates prior summaries. This is strictly stronger than the simpler "include all issue_comments" (policy A) and simpler than per-comment timeline lookup (policy C). For PRs where the strictness matters — a bot summary posted before a later commit landed — the summary is excluded deliberately: a later commit implies the summary's mental model of the diff is at least partially stale.

**Reachability edge case.** `commit_id` in the GitHub API points at the commit that was HEAD of the PR branch when the comment was attached. Force-push or shallow clone can leave that SHA unreachable from local history. Attempt one `git fetch origin +refs/pull/<pr>/head` to pull the PR ref; retry `git cat-file -e`. Still missing → exclude with `action=unreachable` (the comment's referenced code state can't be compared).

**API-failure fallback.** If the `pulls/<pr>/commits` fetch fails (rate limit, auth, network) AND any record is an `issue_comment`, emit `comment_freshness_api_failed` to trace.md once and fall back to **include all issue_comments unchanged** (policy A). Records with real `commit_id`s still get their normal check — the API failure only affects the diff-wide path. This mirrors Phase 1.5's broader "degrade gracefully, never abort the pipeline" stance (§24.2).

**Placement.** Runs as a post-scrape step inside Phase 1.5, after `external-scrape.sh` returns and before the Sonnet normalizer sees any candidates. The normalizer's inputs are already-filtered; downstream (Phase 2 dedup, Phase 3 scoring) never sees stale-coded comments.

**Rationale — why not a time filter.** `review_started_at` was the Stage-2 filter anchor; two observations during Stage-2 real-repo ensemble runs made it clearly wrong. (1) A bot summary posted a week before the review is still signal if the files it talks about haven't changed since; the time filter drops it. (2) A bot summary posted five minutes before the review starts but referring to a file that was force-pushed into a different shape is noise; the time filter keeps it. Newness does not correlate with relevance. Code locality does.

**Implementation.** `comment-freshness.sh` (§21.10) takes `--pr <num>` + `--reviewed-files <csv|@->` + `--comments <path|@->`, emits the filtered array on stdout, and writes one `comment_freshness: id=<...> kind=<...> action=<fresh|stale|fresh-summary|stale-summary|unreachable|api-degraded>` line per record to stderr.

---

## 14. Rollout metrics

### 14.1 Per-run metrics (auto-logged)

Each review's artifact contains a `metrics` block populated as phases complete and after any fix runs:

| Metric | Set by | Purpose |
|---|---|---|
| `phase_9_verified_pct` | Phase 9 | Fraction of attempted fixes verified complete |
| `required_followup` | Set true if any finding ends `open` with `is_actionable=true` after a fix run | "Did this review require a second `/adams-review-fix`?" |
| `time_elapsed_seconds` | Orchestrator | Wall-clock |
| `subagent_tokens.*` | Phase 6 / Phase 9 | Cost attribution |
| `pr_size_buckets` | Phase 0 | For cost-vs-size regression tracking |

After a handful of real-PR runs, aggregating these across `~/.adams-reviews/*` gives empirical signal on Phase 4 precision, fix-completion rate, and cost profile.

### 14.2 Evaluation protocol for first real-PR runs

1. Run on 1 PR with `/adams-review` (review-only).
2. Read the rendered report.
3. Inspect `phases.jsonl` and `trace.md` to understand what each phase produced.
4. If a bug you know exists wasn't found, trace through: which lens should have caught it? Did it produce a candidate (check `phases.jsonl` for phase 1 counts)? Was it deduped (check phase 2 delta)? Was it gated out by scoring (phase 3 — `disposition: below_gate`)? Was it disproven in Phase 4 (`disposition: disproven` or `uncertain`)? The finding's `disposition` is the primary lookup — filter `artifact.json` with `jq '.findings[] | select(.disposition == "disproven")'` to list every Phase-4-rejected finding; read its `reason` afterward for human-readable detail. Open the relevant sub-agent's JSONL transcript via the agentId in `trace.md` if you need to see the agent's actual reasoning.
5. Make targeted adjustments (lens prompts, rubric wording) based on findings.
6. Re-run `/adams-review`.
7. When the review looks right, run `/adams-review-fix`.
8. Inspect the fix commit and the Phase 9 outcome.
9. Iterate on remaining gaps.

---

## 15. Open questions

Decided (after rounds 1, 2, and 3 of outside review, plus rev-4 simplification):

- ✓ Split review and fix; persistent artifact (local); single `findings[]` with three-state machine
- ✓ Fix-group dispatching; orchestrator handles git; per-group revert for regression groups (rev 6)
- ✓ Two-lane pipeline with four-field routing
- ✓ Explicit score decision table; three distinct threshold concepts
- ✓ File-overlap staleness check
- ✓ Source-family auto-graduation; external findings must corroborate internally
- ✓ Phase 9 runs against working tree before commit
- ✓ Helper scripts for state mutation with error-as-prompt and state-transition whitelisting
- ✓ Observability: per-review directory, `phases.jsonl`, trace log with agentIds
- ✓ Per-run metrics for rollout evaluation
- ✓ LLM-only dedup (structural fingerprint dropped)
- ✓ `fix_attempts[]` is the only per-run record (no separate `fix_runs[]`)
- ✓ `origin_confidence` for pre-existing classification; only high-confidence routes to report-only
- ✓ Local-only persistence (no chunked PR-embedded JSON)
- ✓ `/adams-ensemble-review` collapsed into `/adams-review --ensemble`
- ✓ No deterministic test suite in v1
- ✓ No `capture_transcripts` config — Claude Code persists sub-agent JSONL transcripts automatically; agentIds in `trace.md` make them discoverable

Still genuinely open:

1. **Is the deep/light lane boundary drawn at the right place?** Some architecture findings (e.g., "this boundary is being violated in a way that could cause cascading failures") arguably deserve deep treatment. Options: let Phase 4b promote individual findings to deep lane, or keep the boundary strict for v1 and revisit.

2. **Does "err-up scoring" actually shift the distribution?** A calibration concern: the rubric phrasing may not achieve the intended effect. Unclear until measured. If err-up fails to shift, source-family auto-graduation is the main guardrail.

3. **Auto-graduation requires ≥2 source families.** A very-high-score candidate from a single family is not auto-graduated; it still has to clear the Phase 3 score gate (≥ 45) on the cheap-scorer's judgment. This relies on Phase 3 scoring single-family strong candidates ≥ 45 consistently — if the Phase 3 scorer under-rates a strong single-family finding, it's gated out before Phase 4 ever sees it. Worth measuring: are there real bugs that got detected by one lens only, scored < 45 by Phase 3, and skipped deep validation as a result? (Note: a previous version of this open question claimed "structural already goes deep via Opus L2" as a justification for the asymmetry. That was wrong — L2 is a *detection* lens, but its candidates still flow through Phase 3 Sonnet scoring and can be gated out. The real justification is cost: auto-graduating every single-family candidate defeats the gate. The ≥2-family rule is a compromise; measure whether it's the right one.)

4. **Fix gate default of 60.** Provisional. Tune after running on real PRs.

5. **Artifact schema versioning.** Bumping v2 breaks v1 fix commands. Mitigations: grace period keeping v1 support in the fix command; explicit migration note.

6. **Cross-cutting review in Phase 5 — Opus overkill?** On PRs with 1-5 actionable findings, Sonnet might suffice. Measure and adjust.

7. **Migration of existing `/adams-code-review`.** Delete? `legacy`? Archive to `~/.claude/commands-archive/`? Lean: archive after several real runs of the new commands.

8. **`--granular-commits` flag default.** Off by default (one combined commit). Worth confirming that per-group commits aren't actually preferred for review ergonomics.

9. **History as an independent detection source.** Rev-2+ made git history a *validator-side resource* (consulted in Phase 4a), not a detection lens. This is cheaper and avoids duplicate candidates, but means "history-only" issues (regression of a pattern reverted last month, churn hotspots, deprecated-API reintroductions the old command would have caught) may never be nominated by Phase 1. If Phase 4 is never invoked on the right candidate, the validator-side history access doesn't help. Options if recall lacks: (a) add a very cheap history lens (Haiku reads `git log --since=... <file>` + blame on changed files, flags reverted patterns), (b) let L2 explicitly incorporate recent history when scanning contracts, (c) accept the tradeoff. Currently leaning (c) until evidence says otherwise.

10. **Previous-PR-comments as a detection input.** The old `/adams-code-review` read comments from prior PRs touching the same files — historical human/bot review lessons that encode project-specific caution. Rev-5's Phase 1.5 scrape only picks up bot comments on the *current* PR, which is a different problem. Skipped in v1 because the signal is noisy (old comments may be resolved, context-specific, or contradicted by subsequent decisions) and the gh-api cost is high. Revisit if recall tracking (Q9's sibling concern) shows missed issues that a prior-PR-comments lens would have caught.

11. **Retry of regressions without user gating.** Currently (§5.2.1) `disposition: regression` is fix-eligible on the next `/adams-review-fix` run by default, same as `partial`. This lets the user iterate quickly. But a pattern of "regressed → retry → regressed again" would burn cost without converging. Worth tracking: do regression retries succeed at a meaningfully higher rate than initial fixes? If not, consider gating regression retries behind a `--retry-regressions` flag.

---

## 16. What's explicitly NOT in scope

- Restructuring `/adams-super-code-review` or `/adams-entire-codebase-review`.
- A `/adams-validate-candidate <id>` command. Possible future; schema supports it.
- UI tooling for the artifact.
- Self-healing auto-loop after Phase 9.
- Promoting Phase 9 regressions to first-class findings in the same review. Re-running `/adams-review` (fresh review) is the path to re-detect persistent regressions.
- CI/test-suite integration as a primary input. The project-configurable `verification_commands` in §13.5 is a narrower opt-in.
- Cross-machine artifact portability. The local artifact directory is authoritative; the PR comment is display-only.

---

## 17. Rollout plan

1. Draft shared fragments, top-level command files, helper scripts.
2. Run `/adams-review` on a small real PR. Inspect `phases.jsonl`, `trace.md`, and (as needed) the sub-agent JSONL transcripts via their agentIds. Verify dedup behavior and source-family tagging; verify `disposition` values render consistently in the report sections.
3. Run `/adams-review` on a doc-only PR. Confirm `trivial_mode = true` in the artifact and that L2/L5/L6/Phase 4a are skipped per `phases.jsonl`.
4. Run `/adams-review --ensemble` on a PR with active bot reviewers (e.g., Greptile). Confirm Phase 1.5 scrape picks up post-`review_started_at` bot comments and the normalizer emits candidates with `origin_confidence: low`.
5. Run a fresh `/adams-review` on a PR that already has a prior review comment (with the local artifact still on disk). Confirm the prior comment is **not** touched and a new comment is posted alongside it (§13.4 rev-7: each fresh run is its own event). Then separately, on a branch where the local artifact has been wiped, confirm Phase 0 step 0.14 offers (a) post new / (b) replace in place / (c) abort; picking (b) PATCHes the prior comment via `--comment-id`.
6. Run `/adams-review-fix` against the artifact with a clean working tree. Confirm fix-group dispatch, Phase 9 pre-commit sequence, `fix_attempts` appending, `disposition` transitions, state transitions via helper script.
7. Run `/adams-review-fix` with a dirty working tree. Confirm the clean-tree gate (§4 Phase 7 step 5) prompts via AskUserQuestion; test both `stash` and `abort` branches.
8. Re-run `/adams-review-fix` after Phase 9 finds partials. Confirm staleness check uses most-recent-known SHA and that retry uses `revised_fix_proposal` from each finding's last `fix_attempts` entry.
9. **Per-group revert test (critical — trust boundary).** Construct a toy PR with at least two fixable findings that land in two distinct fix groups. Deliberately seed one group's fix to regress (e.g., by manually staging bad content or by prompt-engineering the fix agent). Run `/adams-review-fix`. Confirm: the regression group's files are reverted from the working tree (checkout for modified, rm for created); the verified/partial group's edits are committed; the commit message lists both committed and reverted groups.
10. **All-regression degenerate case.** Same setup but all groups regress. Confirm no commit is made and the working tree is fully restored. Confirm `fix_attempts` entries for all affected findings have `output_sha: null` and `phase_9_outcome: regression` (rev-7 symmetric no-commit accounting, §24.4).
11. **Leftover-`attempted` hard abort (rev 7).** Start `/adams-review-fix`, force-kill the orchestrator between Phase 8 completion and Phase 9 completion (e.g., interrupt while 9a is running) so at least one finding is left in `current_state: attempted`. Re-run `/adams-review-fix`. Confirm: hard abort with the recovery message (§4 Phase 7 step 4), list of leftover `attempted` finding ids displayed, no automated cleanup attempted. Reset manually per the recovery steps and confirm the next run succeeds.
12. **Overlap-guard test (rev 7).** Construct a fix run where two groups' Phase-8 agents end up touching a shared file despite their planned `fix_proposal.files_to_modify` being disjoint. Confirm: Phase 9.pre short-circuits before 9a, no revert runs, no commit made, `fix_attempts` entries recorded with `output_sha: null` and `phase_9_finding` naming the overlap files, `current_state` left at `attempted` so the next run's leftover check fires.
13. **Terminal-cleanup ordering test (rev 7).** Run `/adams-review-fix` on a branch that has no remote (`git push` will fail). Confirm: commit is made locally, `fix_attempts.output_sha` is set to the commit SHA *before* the push attempt, artifact records the commit, push failure is surfaced as the final user-visible error. Run again — confirm the next run's staleness check keys off the already-recorded `output_sha` and doesn't re-attempt the committed fixes.
14. Run on 2-3 more PRs of varying complexity. Tune prompts and thresholds based on `trace.md` and `phases.jsonl`.
15. Review rollout metrics: `phase_9_verified_pct`, `required_followup`, cost distribution.
16. Archive `/adams-code-review`.

Manual validation throughout.

---

## 18. Glossary

- **Finding** — any potential issue in the review's `findings[]` array; the canonical item type. Every candidate surfaced by detection becomes a finding with routing + state fields.
- **Candidate** — informal term for a finding in early phases, before validation has classified it.
- **Source family** — grouping of detection sources by angle (diff-family, structural-family, policy-family, ux-family, security-family, external-deep-family). Auto-graduation requires multiple families, not multiple sources within one family.
- **Lens** — one Phase 1 detection agent (L1-L6). Historical context is NOT a lens — it's a supporting resource used by Phase 4a.
- **Validation lane** — routing target for Phase 4: deep (Opus per candidate with blast-radius tracing) or light (Sonnet per candidate, verification only).
- **Impact type** — the kind of issue: correctness, security, ux, policy, architecture. Separate from origin, actionability, and lane.
- **Origin** — where the issue came from: introduced_by_pr, pre_existing, unknown. Combined with `origin_confidence` to determine routing.
- **Actionability** — what can be done about it at the *fix-engine* level: auto_fixable (Phase 8 can attempt), manual (needs human), report_only (informational).
- **`is_actionable`** — derived bool on each finding. `true` iff `disposition ∈ {confirmed_auto, partial, regression}`. Kept in sync with `disposition` by writer scripts. Present as a convenience for short jq filters; the canonical routing key is `disposition`.
- **`disposition`** — machine-readable per-finding enum (§5.2.1): `below_gate | disproven | uncertain | confirmed_auto | confirmed_manual | confirmed_report | pre_existing_report | partial | regression | resolved`. Orthogonal to `current_state`. Drives report section selection and Phase 8 eligibility without parsing free-form text.
- **`reason`** — free-form display string layered on top of `disposition`. Carries specificity for humans ("fix partial: missed guest.ts writer"); never parsed by machine logic.
- **Current state** — position in the three-state machine: open / attempted / resolved.
- **Confirmed strength** — moderate (score 60-74 after Phase 4) or strong (75+).
- **Wave** — one round of parallel Opus Phase 4a dispatch. Two waves max (orchestrator-chained sibling investigations).
- **Fix group** — set of findings dispatched to one Phase 8 agent because they share files or are cross-cutting. One agent reads all files, applies all fixes, runs all verification.
- **Fix run** — one invocation of `/adams-review-fix` against the review artifact. Appends a `fix_attempts` entry per touched finding with a shared `run_id`.
- **Artifact** — the complete v1-schema JSON record. Persisted at `~/.adams-reviews/<repo>/<branch>/<review_id>/artifact.json`. Survives between sessions on the same machine.
- **Trace** — `trace.md` in the review directory; narrative phase log for human reading. Includes each sub-agent's `agentId` so their full JSONL transcripts can be opened directly.
- **Phases log** — `phases.jsonl` in the review directory; one JSON object per phase, for machine-readable post-mortem diff.
- **Helper script** — deterministic tool in `_shared/tools/` for reading, mutating, validating, rendering, publishing, or computing on the artifact. Scripts produce error-as-prompt messages.

---

# Part II — Implementation reference

This part provides the concrete content a builder needs to translate Part I's design into working commands without re-deriving decisions from scratch. Agent role prompts, the scoring rubric, helper script algorithms, lens reference files, the CLAUDE.md path mechanism, and error-recovery conventions.

---

## 19. Agent role prompt sketches

Each sketch specifies **Input** (what the agent receives), **Output** (the shape to return as structured result), and **Prompt essence** (the core instructions). These are not final prompts — they're the minimum specificity needed for a builder to write prompts that match design intent.

### 19.1 Phase 0 — classifiers and deterministic checks

#### Trivial-diff check — not an agent
Pure Bash snippet in the Phase 0 preamble (not a separate script, because it's tiny and inlineable). Algorithm:

```bash
files_changed=$(git diff --name-only "$base".."HEAD")
num_files=$(printf '%s\n' "$files_changed" | grep -c .)
lines_changed=$(git diff --shortstat "$base".."HEAD" | awk '{print $4+$6}')
# Match against the doc/config allow-list from §13.9; if every file matches
# AND num_files <= 3 AND lines_changed <= 30 → trivial_mode=true
```

Sets `artifact.trivial_mode`. No LLM call. See §13.9 for the allow-list and downshift effects. Skipped entirely if `--full` is passed.

#### User-facing-change classifier (Haiku)
**Input:** `{files_changed}` with short description of each file type.
**Output:** `{user_facing: bool, surfaces?: [string]}`.
**Prompt essence:** Return `user_facing: true` if the diff touches any of: UI components, route or page files, templates, user-visible strings/copy, CSS/styles, i18n files. Return `false` for pure backend logic, build tooling, internal utilities, config. The UX lens is skipped entirely when `false`.
**Skipped when `trivial_mode == true`** (L5 is already off in trivial mode).

#### CLAUDE.md path listing — not an agent
Handled by `claude-md-paths.sh` (see §21.7). Deterministic Bash file-walk; no LLM call. The script walks upward from each touched file's directory to the repo root, collects any `CLAUDE.md` it encounters, dedupes, and orders root-first. Result stored in `artifact.claude_md_paths`.

### 19.2 Phase 1 — detection lenses

#### L1 Diff-local scan (Haiku)
**Input:** the diff only. No other files.
**Output:** `[candidate]` where each candidate has `{file, line_range, claim, evidence_snippet, impact_type: "correctness", origin, origin_confidence, source_family: "diff-family"}`.
**Prompt essence:** Read only the diff. Do not open other files or grep the repo. Flag off-by-one errors, inverted conditions, typos in identifiers, dead branches, obvious null-deref patterns, mismatched quotes or parens. **Over-flag — Phase 3 will filter.** Ignore style issues; ignore anything a linter would catch. Default `origin: introduced_by_pr, origin_confidence: high` unless the code looks unchanged.

#### L2 Structural / blast-radius (Opus)
**Input:** diff + full repo access.
**Output:** `[candidate]` with `source_family: "structural-family"`.
**Prompt essence:** For every function, type, field, or API the diff changes, **trace into the rest of the repo**:
- Who calls this? Are callers updated consistently?
- Who writes to this field? Do all writers share the same contract?
- Is there a parallel code path (e.g., `foo()` and `fooAsync()`) that should receive a matching change?
- What invariants does the surrounding code assume? Does the diff preserve them?

Flag contract changes, null-ability shifts, return-shape changes, concurrent-write assumption violations, missing matching updates in parallel paths. **This is the lens whose absence causes incomplete fixes — be thorough.** Over-flag.

#### L3 CLAUDE.md compliance (Sonnet)
**Input:** diff + CLAUDE.md paths (from Phase 0).
**Output:** `[candidate]` tagged per-finding.
**Prompt essence:** Read the relevant CLAUDE.md files. For each rule, check whether the diff violates it. **Tag each violation's `impact_type`:** `correctness` if the rule concerns runtime behavior / error handling / invariants / safety; `policy` if the rule concerns style / conventions / preferences / formatting. Cite the exact CLAUDE.md file and line. If a rule is silenced by an explicit ignore comment on the relevant code, skip it.

#### L4 Comment compliance (Sonnet)
**Input:** diff + modified files.
**Output:** `[candidate]` with `impact_type: "policy"` (primarily).
**Prompt essence:** Read comments and doc strings (JSDoc, TSDoc, Python docstrings, etc.) adjacent to changed code. Flag when the diff contradicts a comment's claim — e.g., a docstring says "returns non-null" but the change now returns null. If the contradiction is runtime-impactful, upgrade `impact_type: correctness`.

#### L5 UX (Sonnet) — only runs if user-facing
**Input:** diff + `lens-ux-reference.md` content (see §22.1).
**Output:** `[candidate]` with `impact_type: "ux"`.
**Prompt essence:** Read the UX reference. Focus on behavioral gaps visible from the diff: missing loading/empty/error states, inadequate confirmation on destructive actions, silent failures, missing keyboard/a11y affordances, copy that doesn't match existing patterns. Prefer project CLAUDE.md conventions over the generic examples when they conflict.

The orchestrator feeds the reference file by preprocessor-including it into the lens fragment via `` !`cat ~/.claude/commands/_shared/lens-ux-reference.md` ``, so the sub-agent sees the file content inline in its prompt.

#### L6 Lightweight security (Sonnet)
**Input:** diff + `lens-security-reference.md` content (see §22.2).
**Output:** `[candidate]` with `impact_type: "security"`.
**Prompt essence:** Scan for the security categories in the reference: missing auth/permission checks on new surfaces, input validation gaps, injection risks, secrets in code or logs, sensitive data in responses, privilege escalation. If structural reasoning (similar to L2) suggests a security implication, flag it even when the immediate code isn't obviously a security surface. Over-flag.

Same delivery mechanism as L5 — the reference file is inlined via `` !`cat` `` in the fragment.

### 19.2a Phase 1.5 — external PR-comment normalizer (Sonnet, one call)

**Input:** list of raw bot comments from `external-scrape.sh`: `[{id, author_login, author_type, created_at, body, kind: "issue_comment"|"review"|"review_comment", path?, line?, commit_id?}]`.
**Output:** `[candidate]` in the shared candidate schema, each with `{file, line_range, claim, evidence_snippet, impact_type, origin: "introduced_by_pr" | "pre_existing" | "unknown", origin_confidence: "low", sources: ["external-pr:<author_login>"], source_family: "external-deep-family"}`.
**Prompt essence:** Each input comment is a free-form bot review. Extract the concrete issue(s) it describes. If a single comment covers multiple distinct issues, emit one candidate per issue. Infer `file` and `line_range` from the comment's `path`/`line` when present, or from the body text (e.g., "In `src/foo.ts:45`..."). If neither is available, emit the comment with `file: null` — Phase 2 dedup and Phase 4 may still match it against internal candidates. Classify `impact_type` conservatively — prefer `correctness` when unclear, never reach for `security` without concrete evidence. `origin_confidence` is always `low` — the internal corroboration rule in §4 Phase 1 decides whether these findings surface in the report. Discard comments that are questions, praise, or general commentary — only normalize content that identifies an issue in the diff.

### 19.3 Phase 2 — LLM dedup (Sonnet, one call)

**Input:** list of all Phase 1 candidates, each with `{id, file, line_range, claim, evidence_snippet, source_family}`.
**Output:** `{groups: [[id, id, ...], [id, ...], ...]}` — every id appears in exactly one group; single-id groups represent unique candidates.
**Prompt essence:** Group candidates that describe the same underlying issue in different language (e.g., "authenticateUser can return null" and "session.ts doesn't handle DB failure" pointing at the same behavior). Candidates about overlapping code but distinct issues are separate groups. **Be conservative — prefer splitting when unsure.** The orchestrator will merge each group into one candidate, unioning `sources` and `source_families`.

### 19.4 Phase 3 — cheap scorer (Sonnet per candidate)

**Input:** one candidate + CLAUDE.md paths.
**Output:** `{score: 0-100, score_rationale: string}`.
**Prompt essence:** Use the rubric in §20. **When genuinely uncertain between two scores, pick the higher one** — false positives are cheap here (Phase 4 filters), missed bugs are expensive. Stylistic issues not explicitly called out in CLAUDE.md cap at 25.

### 19.5 Phase 4a — deep validator (Opus per candidate)

**Input:** one candidate with claim, evidence, sources, `score_phase3`, CLAUDE.md paths, full repo access, prior `fix_attempts` if this is a retry.
**Output:** `{validation_result: {evidence, blast_radius, fix_proposal, verification_context}, score_phase4, decision, related_candidates_to_investigate?}`.
**Prompt essence:**
1. **Confirm or disprove.** Trace the claim end-to-end in the code. Read function bodies, not just signatures. Consult git blame if a change's history clarifies intent.
2. **Trace blast radius.** For every writer, consumer, parallel path, and relevant test — list them in `blast_radius`. A fix that assumes "X is always non-null" breaks when one writer disagrees — the job is to find those writers now.
3. **Construct reproduction or disproof.** Concrete path (inputs + state + call sequence) that reproduces, or evidence showing it can't happen.
4. **If real, produce `fix_proposal`.** Name every file that needs to change, with `what` and `why` per file. Do not list only the obvious site — list every parallel path and consumer that matters.
5. **Produce `verification_context`** with: `how_to_verify_fix` (specific grep / file-read commands that would confirm the fix landed in all required places), `edge_cases_to_preserve`, `what_would_break_if_incomplete` (concrete scenarios).
6. **Re-score** 0-100 based on evidence. Not your initial gut — re-score based on what you found.
7. If investigation surfaces a related candidate (different bug, related root cause), add it to `related_candidates_to_investigate` with one-line rationale. Do NOT investigate it yourself — Wave 2 will.

### 19.6 Phase 4b — light confirmation (Sonnet per candidate)

**Input:** one non-deep-lane candidate: either a light-lane candidate (`impact_type` in {`ux`, `policy`, `architecture`}) *or* any candidate routed here by `trivial_mode == true` (§13.9), including correctness / security. Plus relevant CLAUDE.md / file section.
**Output:** `{decision: "confirmed" | "disproven" | "uncertain", score_phase4, actionability}`.
**Prompt essence:** Verify the finding's accuracy only — does CLAUDE.md actually contain this rule? Does the comment actually conflict? Adjust score. **Flag `actionability: auto_fixable` only for very mechanical rules** where the fix is unambiguous and mechanical (e.g., import ordering, specific constant naming). Anything requiring judgment → `manual`. Architecture findings default to `report_only`.

**Trivial-mode constraint (§13.9).** When invoked with `trivial_mode == true`, never emit `actionability: auto_fixable` — pick `manual` (if the finding is real and user-actionable) or `report_only` (if purely informational). The orchestrator treats the absence of `auto_fixable` in trivial mode as the enforcement point for "trivial-mode findings are review-only in v1"; this keeps Phase 4b's output shape simple (it doesn't have to produce `fix_proposal` / `verification_context` like Phase 4a does) while still allowing trivial-mode correctness candidates to pass through for reporting.

### 19.7 Phase 5 — cross-cutting reviewer (Opus)

**Input:** all deep-lane findings with `is_actionable: true` including their fix_proposals.
**Output:** `{cross_cutting_groups: [{id, finding_ids, combined_approach}], per_finding_annotations?}`.
**Prompt essence:** Look across confirmed findings for interactions:
- Parallel code paths needing matching fixes
- Shared invariants stressed by multiple findings
- Fix proposals that would collide if applied independently
- Findings whose root cause is the same, where fixing only one leaves the others broken

For each group, give a single `combined_approach`. **Only group when combining is actually required** — not when findings are merely thematically related. Findings that stand alone get no annotation.

### 19.8 Phase 8 — fix-group agent (Opus per group)

**Input:** all findings in the group + cross-cutting annotation (if any) + CLAUDE.md paths + prior `fix_attempts` for any findings whose latest attempt was `partial` or `regression` + union of files in the group + any finding's `human_confirmation.fix_hint` when set (labeled "Human-authored fix direction" in the prompt; takes precedence over claim-text ambiguity and over the validator's `fix_proposal.approach` when they conflict — see §27.6).

**Output** (must match this shape verbatim; Phase 9b revert logic depends on the exact fields):

```json
{
  "per_finding": [
    {
      "finding_id": "F001",
      "edits_applied": ["src/auth/session.ts", "src/auth/guest.ts"],
      "verification_results": [
        { "step": "grep 'authenticateUser' — no dead null-checks", "passed": true, "note": "..." }
      ]
    }
  ],
  "files_modified": ["src/auth/session.ts", "src/auth/guest.ts"],
  "files_created": ["src/routes/_error.tsx"],
  "per_file_summary": [
    { "file": "src/auth/session.ts", "lines_changed": 18 }
  ]
}
```

- `files_modified`: paths that **existed before this Phase 8 invocation** and were edited via the `Edit` tool. Phase 9b's revert for a regression group runs `git checkout -- <path>` on each of these.
- `files_created`: paths that did **not** exist before this Phase 8 invocation and were created via the `Write` tool. Phase 9b's revert runs `rm -f -- <path>` on each of these.
- The two lists must be disjoint. A file that was modified stays in `files_modified`; a file that was created stays in `files_created`; no third category exists in v1 (see deletes/renames prohibition below).
- `per_finding.edits_applied` is informational per-finding linkage (which files a specific finding touched). It may intersect both `files_modified` and `files_created`.

**Prompt essence:**
1. **Read all files in the group once before editing.** Duplicated reads waste tokens.
2. **Plan fix ordering.** Some fixes may depend on earlier ones' changes.
3. **Apply edits via Edit/Write tools only. DO NOT run git commands** — the orchestrator handles staging, commits, and push.
4. **No deletes, renames, or moves in v1.** Do not call `Bash` for `rm`, `git rm`, `git mv`, or any other filesystem-mutating shell command. If a fix genuinely requires deleting or renaming a file, do not attempt the fix: return a `verification_results` entry with `passed: false` and `note: "requires delete/rename — manual intervention"` for the affected finding, and leave the file untouched. The orchestrator's revert model only handles edits and creates; deletes and renames would make revert ambiguous. A future v2 can relax this.
5. **For each finding, run `verification_context.how_to_verify_fix` steps** after editing. Report per-step pass/fail.
6. **If project `verification_commands` are configured**, run matching ones for changed files. Report exit codes.
7. **For findings with a prior `partial` or `regression` attempt:** consult `fix_attempts[-1].phase_9_finding` and `revised_fix_proposal`. If the prior attempt was `regression`, understand what broke before trying again — do not replay the same edit that regressed.
8. **Emit the two file lists explicitly.** Track each file you touch and classify it as modified (pre-existing) or created (new). Return both lists in the top-level output — the orchestrator cannot reconstruct them after the fact from `git status` alone because a file could have been both renamed-via-create-and-delete (which we forbid) and still appear "new." Be explicit.
9. Return the structured result above. The orchestrator uses your report to drive Phase 9.

### 19.9 Phase 9 — post-fix reviewer (Opus)

**Input:** artifact + fix-group agent results + `git diff HEAD` (unstaged working tree before commit).
**Output:** `{per_finding: [{finding_id, outcome: "verified" | "partial" | "regression", phase_9_finding?, revised_fix_proposal?}]}`.
**Prompt essence:** For each finding attempted this run:
1. Did the fix actually eliminate the bug? Re-trace the original `validation_result.evidence` against the new code state.
2. Did every file in `fix_proposal.files_to_modify` receive a corresponding edit? Missing any → `partial`.
3. Did the agent's `verification_context.how_to_verify_fix` steps all pass? Any failure → `partial`.
4. Did project `verification_commands` pass (if run)? Failure → `partial` or `regression` depending on nature.
5. Does any code adjacent to the fix (same file, changed hunk ±20 lines) now contain a new issue that wasn't there before the fix? If so → `regression`, describe concretely.

Classification priority: `regression > partial > verified`. **If in doubt between `verified` and `partial`, choose `partial`** — over-caution here produces a second run, under-caution ships incomplete fixes. For `partial` or `regression`: fill `phase_9_finding` (concrete description of what's missing / what broke) and `revised_fix_proposal` (updated plan for next retry).

The orchestrator then **aggregates per-finding outcomes up to the fix-group level** (§4 Phase 9b): a group's outcome is `regression` if any of its findings regressed, else `partial` if any are partial, else `verified`. The group-level outcome drives revert logic — regression groups' files are reverted from the working tree before commit. The all-regression case (every group regressed) is a degenerate case of this rule: no groups survive, no commit. This sub-agent is responsible only for per-finding classification; the orchestrator handles the rollup and the revert decisions with its `git` access.

---

## 20. Scoring rubric (0-100)

Used by Phase 3 (cheap scoring) and Phase 4 (deep re-scoring). Apply it identically in both phases; Phase 4's advantage is *evidence*, not a different rubric.

| Score | Meaning |
|---|---|
| **0** | Not confident at all. Clear false positive that doesn't stand up to light scrutiny. |
| **25** | Somewhat confident. Might be real, but more likely a false positive or a stylistic issue not explicitly called out in CLAUDE.md. |
| **50** | Moderately confident. Verified as a real issue, but a nitpick or edge case; not important relative to the rest of the PR. |
| **75** | Highly confident. Verified real; will likely be hit in practice; directly impacts functionality OR directly violates a CLAUDE.md rule. |
| **100** | Absolutely certain. Real; will happen frequently; evidence directly confirms. |

### Err-up instruction (Phase 3 only)

> "When you are genuinely uncertain between two adjacent score levels, **pick the higher one**. This gate is followed by expensive investigation that filters false positives. The cost of flagging a false positive here is roughly one Opus agent's worth of investigation. The cost of missing a real bug is that the bug ships. The cost asymmetry means you should err upward when the evidence is ambiguous."

### UX scoring note

UX issues score on the same rubric. A destructive-action regression or silent-failure-no-feedback warrants 75+. A minor copy tweak or visual inconsistency warrants 25. Do not systematically under-weight UX, but do not inflate preference-level visual opinions that aren't backed by CLAUDE.md or existing project patterns.

### Interaction with the decision table

After Phase 4 re-scoring, the score maps to state per §13.1:

- `< 45` → `current_state: open, is_actionable: false, reason: "disproven by Phase 4"`
- `45-59` → `current_state: open, is_actionable: false, reason: "uncertain"`
- `60-74` → `current_state: open, is_actionable: true, confirmed_strength: moderate`
- `75+` → `current_state: open, is_actionable: true, confirmed_strength: strong`

---

## 21. Helper script algorithmic sketches

Each entry gives the script's interface, key algorithm, invariants, and error cases. Writer scripts all validate the full artifact after mutation and reject writes that would produce invalid state.

### 21.1 `artifact-read.sh`

**Interface:** `artifact-read.sh [--path <file>] [--filter '<jq expr>' | --finding-id <id> | --summary]`
**Default path:** from `~/.adams-reviews/<repo>/<branch>/latest.txt` → `<review_id>/artifact.json`.
**Impl:** thin wrapper around `jq`. `--summary` runs a canned jq that aggregates counts per `current_state`, `disposition`, `impact_type`, `validation_lane` — matching §8.1 and §12.1. `disposition` is the primary routing key; `is_actionable` is derived from it and not included in the summary to avoid two views of the same information.
**Errors:** artifact not found → clear message naming expected path; `jq` syntax error → wrapped with "filter was: <expr>".

### 21.2 `artifact-patch.py`

**Interface:** `artifact-patch.py --finding-id <id> [--set <field=value>]... [--append-fix-attempt '<json>'] [--dry-run]`
**Also:** `--add-finding '<json>'`, `--init '<json>'` (create fresh artifact from seed).
**Algorithm:**
1. Read current artifact.
2. Compute patched artifact in-memory.
3. **State transition check** (if `--set current_state=X`):
   - Look up `{current_state_before → allowed_nexts}` from §5.3.
   - If the requested transition is not allowed, exit non-zero with:
     ```
     ERROR: invalid transition from '<before>' to '<requested>'
     Valid next states from '<before>': <list>
     <brief semantic note>
     ```
4. **Schema validation** of patched result. Fail with readable error if invalid.
5. If `--dry-run`: print diff and exit 0 without writing.
6. Else: atomic write (write to temp, rename).

**Invariants:** `fix_attempts` is append-only. `score_history` is append-only. Other fields may mutate.

**Disposition / is_actionable consistency (§5.2.1).** When `--set disposition=<value>` is present, `artifact-patch.py` automatically derives `is_actionable` (`true` iff disposition ∈ {`confirmed_auto`, `partial`, `regression`}) and writes both atomically. A user-passed `--set is_actionable=<value>` that contradicts the derived value is rejected with an error-as-prompt message listing the valid combinations. This keeps the two fields in lockstep without the caller having to remember the rule. Likewise, `--set current_state=resolved` requires `disposition=resolved` (either already present or set in the same call); other combinations of `current_state=resolved` with a non-`resolved` disposition are rejected.

**Exit codes (clarification — codified Stage 1).** §21.2 originally said only "exit non-zero" on failure. Stage 1 standardized the following split so orchestrator prompts can route on specific codes:

| Code | Meaning |
|---|---|
| 0 | success (or `--dry-run` valid) |
| 1 | schema / field validation error |
| 2 | invalid state transition |
| 3 | `--dry-run` would produce an invalid artifact |
| 4 | unexpected error (uncaught exception) |
| 5 | missing Python dep (`jsonschema`) |
| 64 | usage / argparse error (conventional) |

Also applies to `artifact-validate.sh` (0/1/64) and `artifact-render.py` (0/1/4/64) where relevant.

**`--apply-decisions <array>` (clarification — Stage 2.5.B).** Batch application of Phase-4 decision tuples. Input is a JSON array (inline, `@<path>`, or `-` for stdin); each element is `{id, score_phase4, decision?, actionability?, validation_result?, reason?, confirmed_strength?, related_parent_finding_id?}`. The helper derives `disposition` per §13.1 Phase 4 (score_phase4 → disproven/uncertain/confirmed-band, confirmed_strength moderate/strong from the band split) and `is_actionable` via the §21.2 coupling rule. The `decision` field is audit-only — derivation runs off `score_phase4 + actionability`, matching the score-wins-over-decision rule already in 05-validation. `validation_result` is written only when the derived disposition lands in the confirmed band; disproven/uncertain tuples that carry one have it ignored (schema requires nested non-null, and those bands don't produce the `fix_proposal` / `verification_context` sections). Per-tuple atomic writes with first-failure halt: if tuple N fails (unknown actionability, missing actionability on a ≥60 score, unknown tuple keys, post-patch schema invalid), tuples 0..N-1 are already persisted and the caller can re-invoke with tuples N.. once the bad tuple is fixed. Exit codes reuse the table above (1 for validation failures, 2 for transition failures — though Phase 4 tuples don't normally change `current_state`). `--dry-run` is intentionally not supported on this mode: it writes per tuple and a dry-run that tracked preceding-tuple writes would add significant complexity for little gain — callers who want a pre-flight check should validate the tuple JSON upstream and run the batch on a throwaway artifact copy.

**`--apply-fix-start <array>` (clarification — Stage 3).** Batched bulk `open → attempted` transition at the start of Phase 8 (§4 Phase 8 step 8.4). Input is a JSON array of `{id, run_id}` tuples. For each tuple the helper loads the artifact, locates the finding, and transitions its `current_state` to `attempted` via `_apply_finding_set` (same code path as `--set current_state=attempted` — §5.3 transition whitelist + schema validation fire atomically). Defense against a silent no-op: the helper explicitly rejects any tuple whose finding is not `current_state == "open"` at entry with `EXIT_INVALID_TRANSITION` (2) — the Phase 7 step 4 leftover-`attempted` hard abort is the only legitimate recovery path for stale `attempted` state, and `_apply_finding_set`'s same→same short-circuit would hide an orchestrator bug. `run_id` is required per tuple for audit correlation with the Phase 9d `--apply-fix-outcomes` call but isn't persisted on findings at this stage (Phase 9d writes it into `fix_attempts[]`). Per-tuple atomic writes + first-failure halt, matching the `--apply-decisions` pattern. `--dry-run` is not supported (same rationale).

**`--apply-fix-outcomes <array>` (clarification — Stage 3).** Phase 9d state transition + `fix_attempts[]` append in one batched call. Input is a JSON array of `{id, run_id, fix_group_id, input_sha, output_sha, phase_9_outcome, timestamp, phase_9_finding?, revised_fix_proposal?}`. All seven keys except the two optionals are required per tuple — the helper rejects tuples missing any required key with an error-as-prompt listing what's missing, so an orchestrator bug can't produce a fix_attempts entry the schema later rejects at a harder-to-diagnose boundary. Derivation per §13.1 Phase 9 row:

| `phase_9_outcome` | `current_state` transition | `disposition` set | `reason` set | Invariants enforced |
|---|---|---|---|---|
| `"verified"` | `attempted → resolved` | `resolved` | `null` | — |
| `"partial"` | `attempted → open` | `partial` | `"fix partial: <phase_9_finding>"` | — |
| `"regression"` | `attempted → open` | `regression` | `"fix regressed: <phase_9_finding>"` | `output_sha` MUST be `null` (§4 Phase 9b revert leaves no commit for this finding) |
| `null` (overlap-abort) | no transition | unchanged | unchanged | `output_sha` MUST be `null`; `phase_9_finding` MUST be present (diagnostic text) |

The overlap-abort case (`phase_9_outcome == null`, §4 Phase 9.pre) deliberately preserves `current_state == "attempted"` — the next `/adams-review-fix` run's Phase 7 step 4 hard abort catches it and produces the deterministic recovery prompt. The helper enforces the two overlap-abort invariants (null `output_sha`, present `phase_9_finding`) with targeted error-as-prompts so the Phase 9.pre orchestrator path can't silently drop audit context.

Per-tuple atomic writes + first-failure halt. Each tuple's `fix_attempts` append is committed to disk before the next tuple loads, so a mid-batch failure leaves the preceding tuples' audit record intact; the caller re-invokes with the remaining tuples after fixing the offender. Exit codes reuse the table (1 for tuple-shape validation, 2 for invalid `current_state` transition, 4 for unexpected crashes). `--dry-run` is not supported (same rationale as `--apply-decisions` and `--apply-fix-start`).

### 21.3 `artifact-validate.sh`

**Interface:** `artifact-validate.sh --path <file>`
**Impl:** JSON Schema validation. Use `ajv-cli` or equivalent. The schema lives at `_shared/schema-v1.json`.
**Errors:** enumerate each validation failure in human-readable form ("$.findings[3].current_state must be one of [open, attempted, resolved], got 'in_progress'").

### 21.4 `staleness.sh`

**Interface:** `staleness.sh --reviewed-sha <sha> --reviewed-files <f>[,<f>...]`
**Algorithm:**
1. `HEAD=$(git rev-parse HEAD)`. If `HEAD == reviewed_sha`: exit 0, stdout `safe`.
2. Else: `changed_files=$(git diff --name-only <reviewed_sha>..HEAD)`.
3. Intersection with the passed `--reviewed-files` list:
   - Empty intersection → exit 0, stdout `warn: branch moved but no reviewed files changed`.
   - Non-empty → exit non-zero with `unsafe: files <list> changed since review; re-run /adams-review or use --force`.

The orchestrator passes `artifact.reviewed_files_all` as the `--reviewed-files` value (staleness envelope, §13.3). The script's CLI argument is generic — it doesn't care which artifact field the list came from, just intersects it with the diff.

### 21.5 `group-fixes.py`

**Interface:** `group-fixes.py --artifact <path> --eligible-finding-ids <list>`
**Contract:** the orchestrator is responsible for filtering `findings[]` down to the fix-eligible set (`current_state == "open"` AND `disposition ∈ {confirmed_auto, partial, regression}` AND `score_phase4 >= threshold`) and passing those IDs in. The script does *not* re-derive eligibility.
**Algorithm (union-find):**
1. Initialize parent map: each eligible finding is its own parent.
2. For each `cross_cutting_group` that includes any eligible finding: union all its eligible members.
3. For each pair of eligible findings: if `union(f1.files_to_modify) ∩ union(f2.files_to_modify) != ∅`: union them.
4. Compact to components. Each component is a fix group.
5. Emit JSON: `[{id: "FG-N", finding_ids: [...], files: [...]}]`.

**Invariants:** pathological case (everything shares a file) collapses to one group. Disjoint-file singletons stay singletons.

**Promoted-finding fallback (§27).** When an eligible finding has `human_confirmation != null` (promoted via `/adams-review-promote`) AND `validation_result` is `null` OR lacks `fix_proposal.files_to_modify`, the grouper accepts the finding and falls back to `[finding.file]` as its single planned file. This preserves the §27 bypass for Phase 8: a light-lane promotion (or a deep-lane promotion of an uncertain/disproven finding) no longer aborts the grouper for lack of Phase-4 `fix_proposal`. The human override stands in for the validator's file plan. Non-promoted findings with null `validation_result` / missing `fix_proposal` continue to hard-error — the fallback is narrowly scoped to `human_confirmation != null`.

### 21.6 Simpler scripts

- `artifact-render.py --input <json>` — runs a template that produces the Markdown report from the JSON. Template sections match §7. Markdown only; no embedded JSON data block.
- `artifact-publish.sh --mode pr|local --review-id <id> [--pr <num>] [--comment-id <id>]` — if `pr`: run comment discovery per §13.4. Discovery order: (1) `--comment-id` supplied → `gh api -X PATCH` that comment directly; (2) no `--comment-id` → `gh api -X POST` a new comment. The publisher does not auto-discover a prior comment by marker search — continuation intent is the caller's responsibility (fresh `/adams-review` omits `--comment-id`; `/adams-review-fix` and `/adams-review-promote` read `artifact.comment_id` and pass it forward). **When a new comment is POSTed, emit the comment id to stdout as `{"comment_id": <n>}`** so the orchestrator can persist it into the artifact via `artifact-patch.py --set comment_id=<n>`. Fallback on `PATCH` failure (e.g. comment deleted out of band): POST a new comment, log the failure to `trace.md`, emit the new `comment_id` on stdout. If `local`: no-op — the rendered `artifact.md` is already written to the per-review directory by `artifact-render.py`, and `latest.txt` was set by Phase 6's artifact-init (not by publish). Local mode exists so the orchestrator can call `artifact-publish.sh` unconditionally in every mode; it logs "local mode, nothing to publish" to `trace.md` and exits 0.
- `log-phase.sh --phase <n> --name <name> --summary <text> [--elapsed <sec>]` — appends a section to `trace.md`.
- `log-phase.sh --phase <n> --record '<json>'` — appends a one-line record to `phases.jsonl`.

### 21.7 `claude-md-paths.sh`

**Interface:** `claude-md-paths.sh --repo-root <abs-path> --files <f>[,<f>...]`
**Algorithm:**
1. Resolve `--repo-root` to an absolute, realpath'd directory.
2. For each `--files` entry: walk from that file's parent directory upward to `--repo-root`, appending any directory that contains a `CLAUDE.md` file.
3. Always include `<repo-root>/CLAUDE.md` if it exists (covers the case where no touched file lives directly under a subtree with its own CLAUDE.md).
4. Dedupe path list; sort by path depth ascending (root-first).
5. Emit one absolute path per line to stdout.
**Errors:** `--repo-root` missing or not a directory → non-zero with message. No CLAUDE.md anywhere → exit 0 with empty stdout (not an error — plenty of repos don't use them).

### 21.8 `external-scrape.sh`

**Interface:** `external-scrape.sh --pr <num> [--config <path>]` (or `--fixtures-dir <dir>` for offline replay)
**Algorithm:**
1. Resolve owner/repo from `gh repo view --json owner,name` (or from git remote if `gh` isn't configured for this repo).
2. Load config: per-repo `.claude/review-config.json` overrides global `~/.adams-reviews/review-config.json`. Extract `external_reviewer_bots.allow` (may be null) and `external_reviewer_bots.deny` (array; merge with built-in defaults if user didn't replace).
3. Query three endpoints in parallel:
   - `gh api "repos/{owner}/{repo}/issues/{pr}/comments"`
   - `gh api "repos/{owner}/{repo}/pulls/{pr}/reviews"`
   - `gh api "repos/{owner}/{repo}/pulls/{pr}/comments"`
4. Union the results. For each entry:
   - Require (`user.type == "Bot"` OR `user.login` ends with `[bot]`)
   - Require `user.login != current_gh_user` (skip self-authored, including our previous review comments)
   - Apply deny-list: drop if `user.login` appears in `deny`
   - If `allow` is a non-null array: drop unless `user.login` appears in `allow`
5. Emit JSON array to stdout: `[{id, author_login, author_type, created_at, body, kind, path?, line?, commit_id?}]`. The `kind` field tags which endpoint the entry came from (issue_comment / review / review_comment) so downstream consumers can handle inline-review comments specifically.
**Errors:** `gh` rate-limit (HTTP 429, 403 with `X-RateLimit-Remaining: 0`) → non-zero with message naming reset time; orchestrator handles per §24 (log and skip scrape, continue pipeline).

**Freshness filtering (Stage 2.8, §13.13).** This helper no longer applies a time filter. Newness of a comment doesn't correlate with whether its referenced code is still current. Callers pipe the output through `comment-freshness.sh` (§21.10) for code-locality filtering. Pre-Stage-2.8, this helper accepted `--since <iso-8601>` and dropped comments older than that timestamp; the arg has been removed and any script passing `--since` now hits the unknown-arg branch of `die_usage`. `review_started_at` (§4 Phase 0 step 4) survives as the Phase-6 metrics anchor only; it no longer parameterizes any scrape window.

### 21.9 `origin-crosscheck.sh`

**Interface:** `origin-crosscheck.sh --comparison-ref <ref> --candidates <path|@->`
**Input:** JSON array of candidates with at least `{id, file, line_range, origin, origin_confidence}` fields.
**Output (stdout):** the same JSON array with `origin` / `origin_confidence` corrected per §13.11. Unspecified fields pass through untouched.
**Output (stderr):** one `origin_crosscheck: id=<id> action=<respected|overridden|downgraded|skipped>[ reason=<...>]` line per candidate, intended for trace.md flushing by the orchestrator.
**Algorithm (per candidate):**
1. `git cat-file -e "$comparison_ref:<file>"` — if non-zero, file is new to the PR; respect the lens (`action=respected reason=new-file`).
2. Else `git blame -L <start>,<end> --porcelain HEAD -- <file>`, parse distinct commit SHAs from the porcelain output. On blame failure, respect the lens (`action=skipped reason=<rc>`).
3. For each SHA, `git merge-base --is-ancestor <sha> <comparison_ref>` decides "pre-existing" (ancestor) vs "PR-introduced" (not ancestor).
4. Apply the §13.11 decision table: all-ancestor → override to `pre_existing/high`; any-non-ancestor with lens=`pre_existing` → downgrade confidence to `medium`; otherwise → respect.
**Errors:** missing `git` (EXIT_MISSING_DEP), unknown `--comparison-ref` (EXIT_VALIDATION with suggestions via `git rev-parse --symbolic --branches`), malformed JSON (EXIT_VALIDATION with jq error). Per-candidate blame/blame-parse failures do NOT abort; they emit `action=skipped` and flow through as respected.
**Cost:** 1 blame + N ancestry checks per candidate; ~50ms on typical repos. No LLM tokens.

### 21.10 `comment-freshness.sh`

**Interface:**
```
comment-freshness.sh --pr <num> --reviewed-files <csv|@-> [--comments <path|@->]
comment-freshness.sh --fixtures-dir <dir> --reviewed-files <csv|@-> [--comments <path|@->]
```
Only one of `--reviewed-files` / `--comments` may use `@-` per invocation (both consume stdin). Default `--comments` is `@-` so the helper pipes cleanly from `external-scrape.sh`.
**Input:** JSON array matching `external-scrape.sh`'s output schema — each record has `{id, kind, created_at, commit_id?, path?, line?, ...}` plus any pass-through fields.
**Output (stdout):** filtered array in the same shape. Records passing the freshness check are emitted unchanged; records failing are dropped.
**Output (stderr):** one audit line per input record,
```
comment_freshness: id=<n> kind=<issue_comment|review|review_comment> action=<fresh|stale|fresh-summary|stale-summary|unreachable|api-degraded> [reason=<short>]
```
intended for `trace.md` flushing via `tee -a` (mirrors §21.9 origin-crosscheck.sh convention).
**Algorithm:** per-record check per the §13.13 table. `pulls/<pr>/commits` is fetched lazily (only when a record needs the diff-wide timestamp compare) and cached across records. Commit-reachability probes are cached per `commit_id`.
**Fixture replay (`--fixtures-dir`).** Reads `<dir>/pr_commits.json` instead of calling `gh`. The fetch-fallback for unreachable commit_ids is skipped in this mode (no network). Used by `test/smoke.sh` for deterministic CF-* coverage.
**Errors:** missing `git` / `jq` / `gh` (exit 1 with a named dep); bad stdin JSON (exit 1); conflicting `@-` use on both list args (exit 64 usage). Per-record decisions never abort the run; unreachable / api-degraded records produce audit lines and move on.
**Cost:** one `gh api --paginate pulls/<pr>/commits` call if any issue_comment is present (otherwise zero gh calls). Each `commit_id`-bearing record does one `git cat-file -e` + one `git diff --name-only`. Typical runs are under 2 seconds; bound is proportional to distinct commit_ids, not record count.

---

## 22. Lens reference files (draft content)

These files live in `_shared/` and are preprocessor-included into the relevant lens fragment via `` !`cat ~/.claude/commands/_shared/lens-ux-reference.md` `` so their contents appear inline in the sub-agent's prompt. A builder can copy them verbatim as starting content.

### 22.1 `lens-ux-reference.md`

```markdown
# UX lens reference

You are reviewing whether this diff produces a good user experience —
distinct from whether it is technically correct.

## What to check (when the diff is user-facing)

**Destructive actions.** Does confirmation match blast radius? A single-click
that irreversibly destroys user data is a finding. A heavyweight typed-confirm
on something fully reversible is also a finding (wrong direction).

**State coverage.** Are empty, loading, error, and in-progress states handled?
Missing empty states; generic "Loading..." with no progress on long operations;
errors that silently swallow; intermediate states the UI doesn't represent.

**Feedback.** When the user acts, is it visibly clear the action worked (or
clear why it failed)? Actions that complete with no visible change; errors
that disappear before the user can read them; async ops with no progress.

**Affordances.** Is it obvious what's interactive vs. static? Clickable things
that don't look clickable; non-clickable things that do; ambiguous icons
without labels; buttons whose label doesn't predict the action.

**Keyboard & accessibility.** Escape closes modals; Enter submits; focus lands
sensibly (not on the destructive button by default); tab order matches visual
order; ARIA labels for icon-only controls; sufficient color contrast.

**Copy.** Microcopy is clear, concise, and consistent with project voice.
Errors say what happened AND what the user can do. Button labels are verbs
describing the action, not generic "OK"/"Yes".

**Visual consistency.** Uses the project's existing design tokens, CSS
variables, or utility classes rather than ad-hoc values. CLAUDE.md and the
existing codebase take precedence over generic examples above.

## Scope guard

If the PR has no user-facing surface, return an empty list. Do not reach for
UX findings that don't apply.
```

### 22.2 `lens-security-reference.md`

```markdown
# Security lens reference

You are doing a **lightweight** security scan on this diff. This is not a
full audit — flag issues where the code change creates or worsens a security
risk. Over-flag; Phase 4 will filter.

## Categories to check

**Authorization & authentication.**
- New routes, API endpoints, or mutations without an auth check
- New fields exposed through responses that shouldn't be (e.g. internal IDs,
  credentials, PII)
- Permission checks that accept a broader role than intended
- Session handling changes (token lifetime, invalidation, refresh)

**Input validation & injection.**
- User-controlled input concatenated into SQL, shell commands, or HTML without
  escaping/parameterization
- File paths built from user input without sanitization (path traversal)
- Regex or parser changes that accept previously-rejected malformed input

**Secrets & sensitive data.**
- Hardcoded API keys, tokens, passwords, or connection strings
- Sensitive values logged (passwords, tokens, PII, auth headers)
- Debug output or error messages that leak internal structure or secrets

**Cryptography.**
- New crypto primitives (if the project already has conventions, flag
  deviation; do not recommend specific algorithms beyond that)
- Random values used where cryptographic randomness is required

**Cross-cutting security patterns.**
- Race conditions in access checks (TOCTOU)
- Error paths that bypass normal auth/validation flow
- New code that handles untrusted input and calls into a structural pattern
  the rest of the code assumes is trusted (structural-family reasoning)

## Scope guard

If the diff touches no security-adjacent surface (pure UI tweak, pure test
refactor, etc.), return an empty list. Do not reach for security findings
that don't apply.
```

---

## 23. CLAUDE.md path mechanism

Where: Phase 0, step 6 of the pre-flight (§4).
Implementation: `claude-md-paths.sh` (deterministic Bash helper — §21.7). No LLM.
Input: repository root + list of files the PR touches.
Algorithm: locate `<repo_root>/CLAUDE.md` if it exists; for each touched file, walk upward from its directory to the repo root and record any `CLAUDE.md` encountered. Deduplicate, order root-first.
Storage: result is written into `artifact.claude_md_paths: [string]` at the top level of the artifact (present in the §6 schema).
Consumers: L3 (CLAUDE.md compliance lens), Phase 4a (deep validators), Phase 4b (light confirmation), Phase 8 (fix-group agents). All receive the path list; each reads the files as needed. The lister does NOT read file contents — it only enumerates paths — because the paths are cheap metadata, but the contents can be large, and different consumers want different slices.

---

## 24. Error recovery conventions

The orchestrator and sub-agents encounter failures. A fresh agent implementing this should follow these conventions uniformly.

### 24.1 Sub-agent failures

| Failure | Orchestrator response |
|---|---|
| Sub-agent returns non-zero (Agent tool error) | Log to `trace.md`; retry once with identical prompt; if still fails, drop this candidate/fix-group from the run with a note in the report. Do not abort the whole command. |
| Sub-agent returns output but it fails to parse as the expected JSON shape | Attempt light repair (strip code fences, extract JSON block). If still fails, retry with prompt addendum: "Your prior response was not valid JSON. Return only the JSON object described in the schema." If still fails after one retry, drop with note. |
| Sub-agent returns schema-valid JSON but semantically wrong (e.g. references finding IDs that don't exist) | Log the mismatch; drop the offending portion; continue with the rest of the output. |
| Sub-agent times out | Treat as non-zero. Same response. |

### 24.2 Shell command failures

| Failure | Response |
|---|---|
| `gh pr view` fails because no PR for branch | Expected in local mode. Proceed as local. |
| `gh` fails with auth or network error | Abort with user-facing message: "GitHub CLI failed: `<stderr>`. Check `gh auth status` or connectivity." |
| `gh api` rate-limited during Phase 1.5 scrape | Log to `trace.md` with reset time; skip Phase 1.5 for this run (treat external scrape as yielding zero candidates); continue pipeline. Never abort — internal lenses + adapter findings still deliver value. |
| `git` conflict during Phase 0 stash | Abort; let user resolve. Do not auto-resolve. |
| `git push` fails (no upstream, rejected) | Runs inside Phase 9e step 5 — by this point the commit exists AND the artifact has already recorded `fix_attempts.output_sha`, state transitions, and re-rendered `artifact.md` (steps 1-4). Push failure does NOT undo any of that. Log stderr to `trace.md` with tag `push_failed`; continue the terminal block (publish attempt, stash pop); surface the push error as the primary user-visible failure at the end. Do not retry. |
| `artifact-publish.sh` fails (GitHub API error, comment deleted out of band, network) | Runs inside Phase 9e step 6 — artifact is already updated and committed locally. Log stderr to `trace.md` with tag `publish_failed`; continue the terminal block. If this is the primary failure (push succeeded), surface it with a suggestion to re-run `artifact-publish.sh` manually or re-run `/adams-review-fix --republish-only` (future flag). |
| Touched-file overlap detected in Phase 9.pre | Short-circuit before Phase 9a runs. Artifact still gets the "no commit" terminal cleanup path (fix_attempts entries with `output_sha: null`, `phase_9_outcome: null`, `phase_9_finding: "run aborted: fix agents touched overlapping files across groups — <list>"`, `current_state` left at `attempted` so next run's leftover-attempted hard abort fires for deterministic recovery). No revert, no commit. User-visible error names the files + groups + recovery steps. |
| Helper script exits non-zero with error-as-prompt message | Parse the message; adjust inputs per the guidance; retry once. If still fails, escalate to the user with the error text. |
| Helper script exits non-zero with unexpected error (crash, unknown) | Log full stderr to `trace.md`; abort the current phase; continue to Phase 6 (finalize) with what's been accomplished so far flagged in the report. |
| Clean-tree gate (Phase 7 step 5) user picks `stash`, then `git stash push --include-untracked` fails | Abort fix run; report stderr; the artifact is unchanged. User resolves and retries. |
| Clean-tree gate: `git stash pop` after fix run conflicts with fix edits | Do not force resolution. Report the failure; leave the stash ref in place (user can `git stash list` / `git stash apply`); note the stash ref in `trace.md` and the user-visible output. |
| Per-group revert (§4 Phase 9b) triggered; `git checkout -- <file>` fails on a regression-group modified file | Do not commit. Log the failure verbatim; note that the regression group's edits may still be in the tree. Leave the tree as-is (do NOT retry checkout blindly); user handles. Other (verified/partial) groups' edits also remain unstaged — user can inspect and commit manually if desired, but the automated run exits without a commit. |
| Per-group revert: `rm -f` fails on a regression-group created file | Same handling as above. |
| All-regression degenerate case, one of the reverts fails | Same as per-group revert failure — no commit; user handles. |

### 24.3 File system failures

| Failure | Response |
|---|---|
| Artifact file not found when expected | For `/adams-review-fix`: abort with "no review found for this branch. Run `/adams-review` first." For `/adams-review` detecting its own prior state: treat as "no prior", proceed with fresh review. |
| Permission denied writing to `~/.adams-reviews/...` | Abort with message including the target path. User will handle. |
| Disk full during artifact write | Abort cleanly — the write is atomic (temp + rename), so the prior artifact is intact. |
| Schema validation failure at write boundary | Do NOT write. Dump the invalid artifact to `/tmp/adams-review-invalid-<ts>.json` for debugging. Emit an error naming the validation failure. |

### 24.4 Invariants that must hold even through failures

- The artifact on disk is never in an invalid state (atomic writes + validation gate).
- Every sub-agent's token usage is logged before any branching on its result (so cost is accounted even for failed agents).
- `trace.md` is append-only and always reflects the current run's progress.
- A partial run that aborts mid-phase can be diagnosed from `phases.jsonl` + `trace.md`.
- The PR comment is only updated once per phase (finalize step). A failure mid-phase does not leave a half-written comment.
- A fix run either commits with Phase 9 truth in the message (listing per-group outcomes for all groups, reverted and surviving), or — in the all-regression degenerate case — makes no commit and discards all working-tree edits. No file that appeared in a regression-classified group is ever present in a commit produced by this system. It never commits a state it has not already classified.
- **Artifact-records-commit-before-network.** Whenever Phase 9c produces a commit, `fix_attempts.output_sha` (plus state transitions and the re-rendered `artifact.md`) are written to the local artifact *before* any network call (`git push`, `artifact-publish.sh`). Push failure, publish failure, or any later-step failure never leaves the local artifact out of sync with the local git state. (Phase 9e steps 1-4 run before step 5 push; this ordering is normative.)
- **Symmetric no-commit accounting.** Runs that produce no commit (all-regression, overlap-abort, revert failure, per-group revert failure) still write `fix_attempts` entries with `output_sha: null` before surfacing the error. This keeps the next run's staleness check accurate and gives the user a complete artifact to inspect.
- **Group touched-file disjointness at commit time.** Any commit produced by this system has the property that, for every fix group contributing to the commit, that group's `actual_touched` (`files_modified ∪ files_created`) is disjoint from every other contributing group's `actual_touched`. Overlaps are detected in Phase 9.pre and force the run into the no-commit branch. This guarantees per-group revert is always unambiguous.
- **`fix_group_id` scoping.** A `fix_group_id` is unique *within* a `run_id` but not across runs — fix groups are recomputed per run by `group-fixes.py`. The pair `(run_id, fix_group_id)` identifies a specific group; `fix_group_id` alone does not.

### 24.5 User-visible failure surface

When the command aborts for any reason, the chat output tells the user:
- Which phase was running
- The specific error (from the shell / script / sub-agent)
- Where to look for more detail (`trace.md`, `phases.jsonl`)
- What state the artifact is in (new, unchanged from prior, or `/tmp/adams-review-invalid-<ts>.json`)
- Recommended next step (re-run, check `gh auth`, resolve conflicts, etc.)

Failure messages are part of the product UX, not an implementation detail. Write them like the error-as-prompt script messages — specific, actionable, with a next step.

---

## 25. Orchestrator working set

The top-level command files (`adams-review.md`, `adams-review-fix.md`) are thin shells composed from `_shared/` fragments via `` !`cat` `` preprocessor includes (§9.1). That composition model means each fragment must assume a shared "working set" of orchestrator-level variables — things computed or established in one fragment and read by later ones. This section enumerates that set so the builder can be explicit about what every fragment carries forward.

Variables are scoped to a single command invocation. Nothing in this set persists across commands; cross-command persistence is via the artifact (`artifact.json`) on disk.

### 25.1 Review command (`/adams-review`) working set

Set up in Phase 0; consumed by every later phase.

| Variable | Set by | Consumed by | Notes |
|---|---|---|---|
| `review_id` | Phase 0 (generated ULID at artifact init) | All phases, helper scripts, render templates | Written to `latest.txt` and into `artifact.json`. Not used for comment discovery (§13.4) — continuation intent flows through `artifact.comment_id`, which fix/promote pass forward as `--comment-id`. |
| `artifact_path` | Phase 0 (`~/.adams-reviews/<repo-slug>/<branch>/<review_id>/artifact.json`) | All writer scripts, render, publish | Absolute path; avoid recomputing it in each fragment. |
| `repo_root` | Phase 0 (`git rev-parse --show-toplevel`) | L2, Phase 4a, Phase 8, `claude-md-paths.sh` | Used for path resolution. |
| `repo_slug` | Phase 0 (per §9.2 derivation) | Directory creation, `latest.txt` path | Stable across checkouts. |
| `base_branch` | Phase 0 (PR base, or inferred from merge-base) | Artifact display, report header | Human name (e.g. `"main"`); the *comparison* ref is `comparison_ref` below. |
| `comparison_ref` | Phase 0 step 0.2a (§13.10 freshness reconciliation) | L1/L2 diff computation, Phase 0 trivial check, all lens prompts, Phase 1 origin cross-check, Phase 1.5 ensemble externals | `git diff <comparison_ref>..HEAD` is the canonical diff. Equals `base_branch` except under option (b) where it's `origin/<base_branch>`. |
| `base_freshness`, `remote_sha`, `behind_count`, `preflight_warnings` | Phase 0 step 0.2a | Artifact `base_context`, renderer header, trace.md | `preflight_warnings` is flushed to `trace.md` at step 0.15 after `--init`. |
| `head_branch` | Phase 0 (`git rev-parse --abbrev-ref HEAD`) | Artifact, publish | Used for slug + artifact directory. |
| `reviewed_sha` | Phase 0 (`git rev-parse HEAD`, captured after any Phase 0 push) | Staleness envelope, artifact | Always the post-push SHA in PR mode. |
| `review_started_at` | Phase 0 (captured **before** any push/stash — per §6 schema note) | Phase 1.5 scrape window | ISO-8601 UTC. |
| `mode` | Phase 0 (`pr` or `local` — presence of PR via `gh pr view`) | Publish, Phase 1.5, Phase 9e | Local mode skips Phase 1.5 and publish. |
| `pr_number` | Phase 0 (from `gh pr view --json number`) | Publish, Phase 1.5 | Null in local mode. |
| `pr_state` | Phase 0 (from `gh pr view --json state`) | Phase 0 eligibility, artifact | `draft`/`open`/null. |
| `comment_id` | Phase 6+ (publish returns it on first POST; subsequently read from artifact) | Phase 9e publish | Persisted into artifact to survive across runs. |
| `trivial_mode` | Phase 0 (§13.9 Bash check) | All phase fragments (skip/include logic) | Bool; `--full` forces false. |
| `reviewer_sources` | Phase 0 initial + updated post-Phase 1.5 | Artifact | Run-level list of providers. |
| `reviewed_files_all` | Phase 0 (`git diff --name-only <comparison_ref>..HEAD`) | Phase 9 staleness, artifact | Staleness envelope. `comparison_ref` (§13.10), not `base_branch`. |
| `claude_md_paths` | Phase 0 (`claude-md-paths.sh`) | L3, Phase 4a/4b, Phase 8 | Absolute paths, root-first. |
| `phases_log_path` | Phase 0 (`<artifact dir>/phases.jsonl`) | Every phase fragment | Passed to `log-phase.sh --record`. |
| `tokens_log_path` | Phase 0 (`<artifact dir>/tokens.jsonl`) | Every sub-agent dispatch | Appended after parse. |
| `trace_log_path` | Phase 0 (`<artifact dir>/trace.md`) | Every phase fragment | Narrative log. |

### 25.2 Fix command (`/adams-review-fix`) working set

Loads the artifact in Phase 7; adds fix-run-specific vars.

| Variable | Set by | Consumed by | Notes |
|---|---|---|---|
| (all of §25.1) | Loaded from artifact in Phase 7 | — | `comment_id`, `reviewed_sha`, `reviewed_files_all`, etc. all come from the artifact. |
| `run_id` | Phase 7 (generated ULID — `fixrun_<ULID>`) | Phase 8, Phase 9, `fix_attempts` append | Unique per fix-run invocation. |
| `threshold` | Phase 7 (command arg; default 60) | Fix-eligibility filter (§4 Phase 8), report | `/adams-review-fix 80` overrides. |
| `latest_known_sha` | Phase 7 step 6 (most recent `fix_attempt.output_sha` OR `reviewed_sha`) | Staleness check | Keys off the artifact's fix history. |
| `stash_taken` | Phase 7 step 5 (if user picked `stash`) | Phase 9e step 5/7 | Bool; drives stash-pop in terminal cleanup. |
| `input_sha` | Phase 7 final (`git rev-parse HEAD` after any stash) | Phase 8 (recorded in `fix_attempts`) | Pre-edit SHA; paired with `output_sha`. |
| `eligible_finding_ids` | Phase 8 (computed from artifact per §4 Phase 8 filter) | `group-fixes.py`, fix-group dispatch | Pre-filtered; `group-fixes.py` doesn't re-derive. |
| `fix_groups` | Phase 8 (output of `group-fixes.py`) | Phase 8 dispatch, Phase 9.pre/9b/9c | `[{id, finding_ids, files_planned}]` plus, post-Phase-8, `files_modified`/`files_created` actuals. |
| `phase_9a_outcomes` | Phase 9a (per-finding Phase 9 sub-agent result) | Phase 9b aggregation, 9d | `{finding_id, outcome, phase_9_finding?, revised_fix_proposal?}`. |
| `overlap_files` | Phase 9.pre | Phase 9e no-commit branch, user error | Empty if no overlap; triggers short-circuit if non-empty. |
| `reverted_groups` / `surviving_groups` | Phase 9b | Phase 9c staging, commit message | Lists of group ids. |
| `commit_sha` | Phase 9c (captured immediately after commit via `git rev-parse HEAD`) | Phase 9d (`fix_attempts.output_sha`), 9e | Null if no commit (degenerate cases). |

### 25.3 What every fragment is expected to do

The orchestrator fragment-composition style means each fragment gets inlined into the single prompt. For the builder:

- **State is carried in-prompt, not in shell vars.** Because each fragment is markdown that gets `` !`cat` ``'d in, variables aren't shell variables — they're values the orchestrator holds in its working context. Each fragment should reference the variables by name ("use `review_id` captured in Phase 0") rather than assuming a Bash export lives.
- **Helper scripts read the artifact.** When a fragment needs one of the artifact-stored vars (e.g., `reviewed_files_all`), the normative pattern is to call `artifact-read.sh --filter '.reviewed_files_all'` from within the fragment, not to pass the value through prose. This keeps the artifact as the single source of truth.
- **Run-level vars that don't live in the artifact** (`run_id`, `threshold`, `stash_taken`) must be explicitly surfaced at the top of `/adams-review-fix` — Phase 7 sets them, every later fragment references them. A dedicated "Run context" block in the top-level command file, reproduced into the prompt as an initial system-style note, is the cleanest pattern.

### 25.4 Worked invariants

- Every variable in the working set has exactly one source of truth (either the artifact, or a well-defined Phase-N capture). No fragment recomputes a value another fragment already established.
- Every helper script receives absolute paths; fragments never assume a cwd.
- `trace.md`, `phases.jsonl`, and `tokens.jsonl` are all append-only and all keyed off the paths established in Phase 0. A fragment that wants to log sets no new file handles — it calls `log-phase.sh` against the known path.

---

## 26. Worked mixed-outcome example

End-to-end walk of one `/adams-review-fix` run that produces a mixed outcome: one fix group verifies and commits; another regresses and is reverted. Paired with the exact `fix_attempts` shape each finding acquires, the commit message, the comment PATCH, and the terminal cleanup ordering.

### 26.1 Setup

Assume `/adams-review` already ran on this PR and produced an artifact with four confirmed-auto findings:

| Finding | File(s) | Group |
|---|---|---|
| F001 | `src/auth/session.ts`, `src/auth/guest.ts`, `src/routes/_error.tsx` | FG-1 |
| F002 | `src/cache/sync.ts` | FG-2 |
| F003 | `src/api/auth.ts` | FG-3 |
| F004 | `src/api/users.ts` | FG-4 |

All four have `current_state: open`, `disposition: confirmed_auto`, `score_phase4 >= 60`. The user runs `/adams-review-fix`.

### 26.2 Phase 7 — artifact load + gates

- Leftover-`attempted` check: clear (no leftover state).
- Clean-tree gate: working tree is clean, no stash needed.
- Staleness: `HEAD == reviewed_sha`, safe.
- PR state: open.

`run_id = fixrun_01JX9B5...` generated. `input_sha = <reviewed_sha>`.

### 26.3 Phase 8 — fix groups dispatched

`group-fixes.py` returns four groups (the file sets are disjoint; no cross-cutting merges). Four Opus fix-group agents launch in parallel.

Agent returns:

- **FG-1**: `files_modified: ["src/auth/session.ts", "src/auth/guest.ts"]`, `files_created: ["src/routes/_error.tsx"]`. Verification steps pass.
- **FG-2**: `files_modified: ["src/cache/sync.ts"]`, `files_created: []`. Verification passes.
- **FG-3**: `files_modified: ["src/api/auth.ts"]`, `files_created: []`. Verification passes (from the fix agent's perspective — but the agent's local `grep` can't see the adjacent 401 issue Phase 9 will find).
- **FG-4**: `files_modified: ["src/api/users.ts"]`, `files_created: []`. Verification partially passes — one of the planned `files_to_modify` paths (`src/api/search.ts`) was not touched.

### 26.4 Phase 9.pre — overlap guard

`actual_touched` sets across the four groups are disjoint. No overlap. Proceed to 9a.

### 26.5 Phase 9a — post-fix review

Opus Phase 9 sub-agent reviews the working-tree diff. Per-finding outcomes:

- F001 → `verified` (FG-1 ok).
- F002 → `verified` (FG-2 ok).
- F003 → `regression`: the auth-check fix in `src/api/auth.ts` introduced a new 401 path for valid tokens. `phase_9_finding: "auth.ts:95 new 401 on valid session tokens when X-Request-Id is absent"`. `revised_fix_proposal: { ... }`.
- F004 → `partial`: the pagination fix missed `src/api/search.ts`. `phase_9_finding: "off-by-one unchanged in search.ts:142"`. `revised_fix_proposal: { add search.ts:142 to edits }`.

### 26.6 Phase 9b — group aggregation + revert

Per-group rollup (`regression > partial > verified`):

- FG-1: `verified`. Survives.
- FG-2: `verified`. Survives.
- FG-3: `regression`. **Reverted.** `git checkout -- src/api/auth.ts`.
- FG-4: `partial`. Survives.

Surviving-group file list: `src/auth/session.ts, src/auth/guest.ts, src/routes/_error.tsx, src/cache/sync.ts, src/api/users.ts`.

### 26.7 Phase 9c — commit

```
$ git status --porcelain
 M src/auth/session.ts
 M src/auth/guest.ts
?? src/routes/_error.tsx
 M src/cache/sync.ts
 M src/api/users.ts

$ git add -- src/auth/session.ts src/auth/guest.ts src/routes/_error.tsx src/cache/sync.ts src/api/users.ts
$ git commit -m "..."
[feature/auth-hardening c01ab2e] fix: address code review findings (3 groups committed, 1 reverted)

$ git rev-parse HEAD
c01ab2ef9d4a3b1c...
```

`commit_sha = c01ab2ef...` captured immediately. Commit message:

```
fix: address code review findings (3 groups committed, 1 reverted)

Fix groups (committed):
- [FG-1] F001 — session.ts, guest.ts, _error.tsx: null contract enforcement ✓ verified
- [FG-2] F002 — cache/sync.ts: missing invalidation after write ✓ verified
- [FG-4] F004 — api/users.ts: off-by-one in pagination ⚠ partial (missed search.ts)

Fix groups (reverted — regression detected):
- [FG-3] F003 — api/auth.ts: auth-check fix introduced new 401 path for valid tokens

Post-fix review: 2/4 groups verified; 1 group partial; 1 group reverted.
Re-run /adams-review-fix to address partial and regression findings.
```

### 26.8 Phase 9d — state transitions + fix_attempts append

Four `artifact-patch.py` calls, all before push:

```
# F001: verified
artifact-patch.py --finding-id F001 \
  --set current_state=resolved \
  --set disposition=resolved \
  --append-fix-attempt '{"run_id":"fixrun_01JX9B5...","timestamp":"...","fix_group_id":"FG-1","input_sha":"<input_sha>","output_sha":"c01ab2ef...","phase_9_outcome":"verified"}'

# F002: verified
artifact-patch.py --finding-id F002 \
  --set current_state=resolved \
  --set disposition=resolved \
  --append-fix-attempt '{ ... "phase_9_outcome":"verified", "output_sha":"c01ab2ef..." }'

# F003: regression (group reverted → output_sha null)
artifact-patch.py --finding-id F003 \
  --set current_state=open \
  --set disposition=regression \
  --set reason="fix regressed: auth.ts:95 new 401 on valid session tokens" \
  --append-fix-attempt '{ ... "phase_9_outcome":"regression", "output_sha":null, "phase_9_finding":"...", "revised_fix_proposal":{ ... } }'

# F004: partial (group survived → output_sha set)
artifact-patch.py --finding-id F004 \
  --set current_state=open \
  --set disposition=partial \
  --set reason="fix partial: missed search.ts:142" \
  --append-fix-attempt '{ ... "phase_9_outcome":"partial", "output_sha":"c01ab2ef...", "phase_9_finding":"...", "revised_fix_proposal":{ ... } }'
```

All four writes land *before* the push step. This is the key invariant from §24.4: the artifact records the commit before any network call can fail.

### 26.9 Phase 9e — terminal cleanup

1. `fix_attempts` appended (done in 9d).
2. Schema validated.
3. `artifact-render.py` regenerates `artifact.md`. Report sections (§7) filter on `disposition`: F001/F002 under "resolved", F003 under "regression", F004 under "partial — retry-eligible".
4. Append to `trace.md` and `phases.jsonl`. Phase 9 record:
   ```jsonl
   {"phase":9,"name":"post-fix-review","elapsed_sec":187,
    "counts_by_state":{"open":32,"resolved":6},
    "counts_by_disposition":{"below_gate":14,"disproven":5,"uncertain":4,"confirmed_manual":4,"confirmed_report":1,"pre_existing_report":1,"partial":2,"regression":1,"resolved":6},
    "delta":"6 verified, 2 partial, 1 regression (FG-3 reverted)","ts":"..."}
   ```
5. `git push origin feature/auth-hardening`. Succeeds.
6. `artifact-publish.sh --mode pr --comment-id 2093481234`. PATCH succeeds; no new comment id emitted (already had one). The comment body is the updated `artifact.md`, first line still `<!-- adams-review-v1 -->`.
7. No stash to pop.
8. No failures to surface. User-visible summary:
   ```
   /adams-review-fix complete.

   Committed: 3 groups (4 findings → 2 verified, 1 partial).
   Reverted:  1 group (1 finding → regression detected).

   2 findings remain open and retry-eligible (disposition: partial, regression).
   Re-run /adams-review-fix to attempt again with revised_fix_proposal context.

   Commit: c01ab2e
   PR comment updated: https://github.com/.../pull/1234#issuecomment-2093481234
   ```

### 26.10 What the next `/adams-review-fix` run will see

On re-run without changing threshold:

- Leftover-`attempted` check: clear (none).
- Clean-tree gate: clean (the reverted FG-3 file is back to pre-run state; the committed groups are now `HEAD`).
- Staleness: `HEAD == c01ab2ef` (most recent `fix_attempt.output_sha` for F001/F002/F004), and F003's last `output_sha` is null so `latest_known_sha` falls through to the next-most-recent — which is `c01ab2ef` from the same run. Safe.
- Phase 8 eligibility filter: F003 (regression) and F004 (partial) pass. F001/F002 are resolved — excluded. The rest unchanged.
- Phase 8 dispatches two agents: one for F003 (with the `revised_fix_proposal` from its last attempt) and one for F004 (same).

### 26.11 What changed vs. prior revs

This walk demonstrates rev-7's contract tightening in action:

- Per-group `files_modified` / `files_created` returned by Phase 8 (item #4) is what 9b uses for revert.
- Overlap guard (item #6) ran in 9.pre and passed — if FG-3 had also touched `src/api/users.ts`, the run would short-circuit here with no commit.
- `disposition` (not `reason`) drives report section selection and Phase 8 eligibility (item #2).
- `fix_attempts` entries land before push (item #7): if `git push` had failed in step 5, the artifact would still correctly report F001/F002/F004 as committed with `output_sha: c01ab2ef...`, so the next run's staleness logic would still be accurate.
- `fix_group_id` values (FG-1..FG-4) are unique within this `run_id` only (item #8) — the next run may use the same ids for entirely different groupings.

This is the canonical "reference trace" for what the system does when things mostly-work. Edge cases (overlap-abort, all-regression, revert failure) use the symmetric no-commit branch of §4 Phase 9e step 2.

## 27. `/adams-review-promote` — human-override slash command

Single-finding human override path. The automated pipeline's score and
lane gates are calibrated conservatively (LLM validators are least
trustworthy on subjective ux / architecture claims and on findings
near the 45–60 score band). When a reviewer reads the PR comment and
decides the pipeline missed a real issue, `/adams-review-promote`
patches the artifact so the finding flows into `/adams-review-fix`'s
eligibility set on the next run.

### 27.1 Invocation

```
/adams-review-promote <finding_id> [--reason "..."] [--fix-hint "..."] [--force] [--defer-publish]
```

- `<finding_id>` — positional, required. Matches `^F[0-9]+$`.
- `--reason` — optional quoted string. Audit-focused ("why I
  promoted"). If absent, the command prompts with three canned
  reasons and a free-form option.
- `--fix-hint` — optional quoted string. Instruction-focused ("how
  to fix"). Surfaced to the Phase 8 fix-group agent alongside the
  finding's claim and `validation_result`. When absent AND the
  finding has `validation_result == null` (no validator
  `fix_proposal.approach` to fall back on — the common case for
  light-lane findings and for deep-lane findings Phase 4 marked
  `uncertain`/`disproven`), the command prompts with a
  claim-text-heuristic option set: doc/comment-vs-code canned picks
  plus free-form and skip when the claim mentions
  docs/comments/mismatch; just free-form and skip otherwise.
  Findings with `validation_result` populated can still pass
  `--fix-hint` explicitly to override the validator's
  `fix_proposal.approach` but are never auto-prompted.
- `--force` — required when promoting a `disposition=disproven`
  finding (Phase 4 found positive evidence the issue isn't real;
  force makes the human override the validator's counter-evidence
  rather than filling a null).
- `--defer-publish` — skip steps 7 (re-render), 8 (re-publish), and
  10 (user-visible summary). The artifact patch and trace entry
  still land. Intended for scripted multi-promote workflows where
  render + publish should batch once at the end — primary consumer
  is `/adams-review-walkthrough` (§28). When set, the caller is
  responsible for running `artifact-render.py` and
  `artifact-publish.sh` afterward.

### 27.2 Preconditions

Read the finding's current disposition. Reject or no-op per the
table below; otherwise proceed. Trace every rejection to `trace.md`
under a `## promote (<ts>) — rejected` block.

| Current `disposition` | Additional condition | Action |
|---|---|---|
| `confirmed_auto` | `human_confirmation != null` | exit 0: already promoted, no-op |
| `confirmed_auto` | `human_confirmation == null` | **proceed.** Promote can't know the user's planned `/adams-review-fix` threshold, so always set `human_confirmation`. Strictly necessary for light-lane (fails impact_type filter) and deep-lane below-threshold (fails score gate); redundant-but-harmless audit for deep-lane above-threshold (already eligible). |
| `resolved` | — | exit 1: fix already ran; cannot promote |
| `disproven` | `--force` absent | exit 1: validator found positive evidence this isn't real; use `--force` to override |
| `disproven` | `--force` present | proceed (log warning to trace) |
| `uncertain` / `below_gate` / `pre_existing_report` / `confirmed_manual` / `confirmed_report` / `pending_validation` / `partial` / `regression` | — | proceed |

### 27.3 Mutations

One atomic `artifact-patch.py` call writes:

```
finding.disposition        = confirmed_auto
finding.actionability      = auto_fixable
finding.human_confirmation = {
  reviewer:      <git config user.email or user.name, else "unknown">,
  reason:        <--reason arg or user-selected reason>,
  ts:            <now, UTC ISO-8601>,
  promoted_from: {
    disposition:   <prior disposition>,
    actionability: <prior actionability>,
    score_phase4:  <prior score_phase4 — preserved, NOT mutated>
  },
  fix_hint?:     <--fix-hint arg or user-selected hint, when non-empty>
}
# is_actionable is derived by the helper from the new disposition.
# fix_hint is OMITTED from the object (not literal null) when empty,
# keeping pre-§14 human_confirmation objects and promotions-without-
# steering structurally identical on disk.
```

`fix_hint` is instruction-focused; `reason` is audit-focused. Keeping
them separate means trace.md readers and audit reviewers can tell
"why the human promoted" apart from "how the human told the fix
agent to proceed." The two fields never subsume each other.

`score_phase4` is explicitly NOT mutated. The validator's honest score
stays in the artifact for audit; Phase 8 eligibility bypasses the
score threshold via the `human_confirmation != null` selector gate
(§5.2.1, §13.1, §13.2).

### 27.4 Side effects

1. **Re-render.** `artifact.md` regenerates from the patched JSON so
   the auto-fixable table picks up the promoted finding and carries a
   `(human-confirmed)` tag (§7 renderer).
2. **Re-publish.** PR mode: PATCH the existing `comment_id` on the PR
   via `artifact-publish.sh`, same path Phase 9e uses. Local mode:
   trace-only no-op.
3. **Trace.** Append a `## promote (<ts>)` block to `trace.md` with
   `finding`, `reviewer`, `force`, `promoted_from`, `reason`, and
   — when set — `fix_hint`.

Publish failures are non-fatal — the artifact patch stands; the user
gets a final-status note telling them how to re-publish manually
(§24.4 artifact-records-commit-before-network invariant applies).

### 27.5 What it does NOT do

- **Does not run `/adams-review-fix`.** Promote is metadata-only; the
  user runs fix explicitly when ready.
- **No batch mode in the command itself.** One finding per invocation.
  For guided multi-finding promote flows, use
  `/adams-review-walkthrough` (§28); for scripted loops, shell-loop
  `/adams-review-promote --defer-publish` calls and run
  `artifact-render.py` + `artifact-publish.sh` once at the end.
- **No demotion / undo command.** If the user changes their mind
  before the next fix run, they patch manually with
  `artifact-patch.py --set-json human_confirmation=null --set
  disposition=<prior>`. A symmetric `/adams-review-demote` is future
  work.
- **No re-run persistence.** Fresh `/adams-review` on the same branch
  overwrites the artifact. A future sidecar `overrides.json` keyed by
  claim fingerprint is sketched in `plans/manual-review-promote.md §13`.

### 27.6 Interaction with Phase 8

The Phase 8 selector (§5.2.1, §13.1) treats `human_confirmation != null`
as a bypass of BOTH the impact_type lane filter and the score_phase4
threshold. Validator-scored findings continue to pass both gates
independently. The bypass is narrowly targeted: only the specific
findings a human explicitly promoted skip the automatic gates.

A promoted finding goes through Phase 8 → Phase 9 exactly like any
other `confirmed_auto` finding: the fix-group agent attempts the fix,
the Phase 9a post-fix reviewer verifies, and the finding transitions
to `resolved` / `partial` / `regression` accordingly. `human_confirmation`
rides along untouched — it's provenance metadata that survives the
full fix lifecycle.

When `human_confirmation.fix_hint` is present, the Phase 8 fix-group
agent (§19.8) receives it as an explicit reviewer instruction in its
per-finding payload, labeled "Human-authored fix direction" and
framed as taking precedence over claim-text ambiguity and — when the
two disagree — over the validator's `fix_proposal.approach`. This
closes the light-lane auto-fix gap where `validation_result` is
`null` and the claim alone can't tell the agent which side of a
code/text mismatch to change (e.g. "docstring disagrees with code":
fix which one?). For deep-lane findings that were promoted with
`--fix-hint`, the hint acts as an override rather than a fallback
— the validator's approach is still provided to the agent for
context, but the agent is instructed to follow the hint when they
conflict.

### 27.7 Audit trail

A reader investigating "why did this ux finding get auto-fixed?"
traces:

1. `artifact.md` auto-fixable table shows the `(human-confirmed)` tag.
2. Details block shows the Human-confirmed line (reviewer + ts + reason),
   the Promoted-from line (prior disposition/actionability/score), and
   — when the promotion supplied a hint — a `Fix direction:` line with
   the `fix_hint` verbatim.
3. `artifact.json` stores the full `human_confirmation` object,
   including optional `fix_hint`.
4. `trace.md` has the `## promote` entry recording when + by whom,
   and the `fix_hint` when set.
5. If Phase 9 resolved it, `fix_attempts[].run_id` links to the fix
   run; if it regressed, the revert is in the same trace.

Every signal needed to reconstruct the decision is local to the review
directory — no cross-referencing Git history or external systems.

## 28. `/adams-review-walkthrough` — guided non-eligible review

Interactive driver for the findings `/adams-review-fix` would skip
at a given threshold. Loads the latest review artifact for the
current branch and walks the reviewer through each non-eligible
finding one at a time (deep-lane manual/report/below-gate, and
light-lane everything including `confirmed_auto` — which fails
the §13.2 impact_type gate by default). For each finding, a Sonnet
briefing agent produces a `{summary, options[], recommendation}`
structured briefing; the reviewer picks an option; the command
dispatches `/adams-review-promote`'s patch logic (via the shared
`commands/_shared/promote-core.md` fragment, with `--defer-publish`
semantics) or records a skip. At the end, the artifact is
re-rendered and re-published once, and a separate "Walkthrough
decisions" comment is POSTed to the PR for audit.

Closes the light-lane `confirmed_auto` gap: the validator may mark
a ux/policy finding mechanically-fixable, but the default Phase 8
lane filter (§13.1, §13.2) skips it. Without walkthrough, each such
finding would need a manual `/adams-review-promote <id>` invocation
with the reviewer synthesizing `reason` and `fix_hint` from scratch.
The walkthrough automates the synthesis and batches the side
effects.

### 28.1 Invocation

```
/adams-review-walkthrough [threshold]
```

- `[threshold]` — optional positional non-negative integer. Default
  60 (§13.2). Used only to decide which `confirmed_auto` /
  `partial` / `regression` findings would already be fix-eligible
  and are therefore excluded from the walkthrough scope.

### 28.2 Preconditions

- `latest.txt` for the current branch must exist and point at a
  schema-valid artifact. Otherwise error-as-prompt "run /adams-review first."
- Dirty-tree state is IGNORED — walkthrough is metadata-only (no
  working-tree edits). Matches `/adams-review-promote`'s
  precondition set (§27.2).

### 28.3 Scope filter

The walkthrough enumerates findings where:

```jq
.current_state == "open"
AND .disposition NOT IN {resolved, disproven, pending_validation}
AND .human_confirmation == null
AND NOT (Phase 8 eligibility passes at $threshold)
```

This is the **inverse** of `09-fix-execution.md` step 8.1 — the two
jq expressions must stay in sync. Cross-reference comments in both
files flag the coupling.

Excluded by design:
- `resolved` — fix already landed
- `disproven` — validator found positive evidence this isn't real;
  user must still override via `/adams-review-promote <id> --force`
- `pending_validation` — shouldn't exist post-Phase 6; defensive
- `human_confirmation != null` — already promoted, mid-session resume
  skips these naturally

### 28.4 Briefing sub-agent

One Sonnet sub-agent per finding, dispatched with a shared prompt
(see `commands/adams-review-walkthrough.md` step 5.2 for the full
text). Inputs: finding JSON, file snippet (±30 lines via Read tool),
CLAUDE.md rules that cite the same file or pattern, other findings
on the same file. Budget ~3-5k tokens per invocation.

Returns strict JSON:

```json
{
  "summary": "2-4 sentences on what the finding is and what the validator concluded",
  "options": [
    {"label": "A", "title": "...", "detail": "...", "fix_hint_if_picked": string},
    ...
  ],
  "recommendation": {"label": "A" | "B" | ..., "rationale": "..."}
}
```

**Every option is a fix variant.** The briefer does NOT emit "skip"
or "defer" options — those are provided separately by the
walkthrough's own `AskUserQuestion` (§28.5). Emitting a parallel
skip option from the briefer creates routing ambiguity (user-picked
skip options get routed through the promote path with an empty
`fix_hint`, triggering `promote-core.md` step 4.5's fallback
prompt). `fix_hint_if_picked` MUST therefore be a non-null string
on every emitted option.

One retry on parse failure; degraded UX on second failure (raw
finding + skip/promote-without-hint options).

### 28.5 Per-finding interaction

The orchestrator presents the briefing as a markdown block (with
the recommended option visually labeled), then dispatches
`AskUserQuestion` with:

- One option per `briefing.options[]` entry
- `Skip this finding`
- `Stop the walkthrough (finalize with decisions made so far)`

On a promote choice: set ambient `fix_hint`, `reason`, `force=false`,
`defer_publish=true` / `DEFER_PUBLISH=1`, then include
`commands/_shared/promote-core.md` (the same fragment
`/adams-review-promote` uses for its steps 3-6, 9). The patch + trace
entry land; render + publish stay skipped.

On skip / stop: no mutation. Decision recorded in the in-memory
`decisions[]` array for the final audit comment.

### 28.6 Mutations

Delegated entirely to `/adams-review-promote`'s patch logic (§27.3)
via the shared fragment. Walkthrough itself performs no direct
artifact writes beyond what the fragment emits.

### 28.7 Side effects

1. **Batched re-render.** `artifact-render.py` runs once at the end,
   after all promotes have landed. Skipped if zero promotions were
   made.
2. **Batched re-publish.** `artifact-publish.sh` edits the persisted
   `comment_id` in place once. Skipped if zero promotions.
3. **Decisions-log PR comment.** A NEW comment (not an edit) with
   the `<!-- adams-review-walkthrough-v1 -->` marker. Contains
   Promoted / Skipped / Stopped sections with full per-finding
   provenance. The new comment's id is written to `trace.md` but
   NOT to `artifact.comment_id` (which stays pointing at the main
   review comment so `/adams-review-fix` edits the right thing).
4. **Trace.** `## walkthrough (<ts>)` block appended with per-finding
   decision lines + the decisions-comment id.

All four side effects are non-fatal — a failure in any one logs to
trace and the run continues. The artifact patches land atomically
per promote; no transactional coupling between iterations.

### 28.8 What this command does NOT do

- **No fix-run.** Metadata-only. User runs `/adams-review-fix`
  explicitly when ready (same contract as `/adams-review-promote`).
- **No `disposition=disproven` handling.** Scope filter excludes
  them; promote via `--force` one-off for disproven findings.
- **No resumption state file.** Partial walks leave the promoted
  findings committed to the artifact; re-invocation picks up the
  still-in-scope remainder naturally.
- **No bulk skip / lane filters.** One-at-a-time decisions in v1.
  Future: `--lanes light` / `--lanes deep`.
- **No auto-chaining.** No `--and-fix` flag. Walkthrough ends at
  the decisions-log comment.

### 28.9 Interaction with `/adams-review-fix`

A promoted finding goes through Phase 8 → Phase 9 exactly like any
other `confirmed_auto` finding with `human_confirmation` set: the
fix-group agent attempts the fix (using the walkthrough-authored
`fix_hint` as its primary steering instruction per §27.6), Phase 9a
verifies, and the finding transitions to `resolved` / `partial` /
`regression`. `human_confirmation` including `fix_hint` rides along
untouched.

If the reviewer runs `/adams-review-fix [threshold]` immediately
after the walkthrough, the eligibility set is:
- original deep-lane `confirmed_auto` findings above threshold
  (unchanged)
- PLUS every finding promoted during the walkthrough (via the
  `human_confirmation != null` bypass)

### 28.10 Audit trail

A reader reconstructing "how did F016 get auto-fixed?" traces:

1. `artifact.md` auto-fixable table shows the `(human-confirmed)` tag.
2. Details block shows the Human-confirmed line (reviewer + ts +
   reason), Promoted-from line, and Fix-direction line with the
   walkthrough-authored `fix_hint`.
3. The main review comment on the PR is the current state.
4. The **Walkthrough decisions** comment on the PR shows the full
   context: which option the reviewer picked, the briefing's
   rationale for recommending it, all other decisions made in that
   session.
5. `trace.md` has a `## walkthrough` block linking the
   decisions-comment id, plus the `## promote` block the shared
   fragment appended per-finding.
6. `artifact.json` stores the full `human_confirmation` object
   including `fix_hint`.

Every signal is local to the review directory + the PR thread —
no cross-referencing Git history.
