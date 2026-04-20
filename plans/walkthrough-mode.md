# Plan: /adams-review-walkthrough — interactive driver for non-auto-eligible findings

Status: approved, executing
Branch: `walkthrough-mode` (worktree `.claude/worktrees/walkthrough-mode`)
Related DESIGN sections to update: §27 (promote — add `--defer-publish`), new **§28** (walkthrough command), §7 (report format — decisions-log comment note)

## 1. Goal

Give the reviewer a single command that loads the latest review artifact on the current branch and walks them through every finding `/adams-review-fix` would skip at the chosen threshold — one at a time, with a structured **claim → options → recommendation** briefing per finding — dispatching `/adams-review-promote`'s patch logic (with render/publish deferred) per decision, then batching the re-render + re-publish to a single final round and posting an auditable "decisions log" PR comment.

Concrete use case (from session `75f10884-acf1-4857-8f4b-9127b4d3a635`, ray-finance PR #8): after `/adams-review --ensemble` produces 21 findings with 1 deep-manual + 9 light-lane non-eligibles, the reviewer runs `/adams-review-walkthrough`, spends ~20 minutes stepping through the 10, emerges with 11 promoted findings (each carrying a tailored `fix_hint`) + a PR comment summarizing decisions for future reviewers.

## 2. Non-goals / explicitly deferred

- **No fix-run.** Walkthrough ends at the promote step; user runs `/adams-review-fix` explicitly afterwards (same contract as promote).
- **No `disproven` handling.** Disproven findings need `--force` + conscious justification; walkthrough won't surface them. User can still promote a disproven finding one-off via `/adams-review-promote <id> --force`.
- **No resumption across sessions.** If the user quits mid-walkthrough, patches landed so far stand; a re-invocation walks the still-non-eligible remainder (naturally idempotent — already-promoted findings are filtered out by the scope query).
- **No bulk-skip / lane filters.** "Skip all ux findings" is future work. v1 requires one-at-a-time decisions.
- **No cross-branch walkthrough.** Operates on `latest.txt` for the current branch (same as promote / fix).

## 3. Key design decisions

### 3.1 Separate top-level command, not a flag on an existing command

Rejected `/adams-review --walkthrough` (couples review and decision timing; user may want to cool off between) and `/adams-review-promote --walkthrough` (inflates promote's one-finding contract). Separate `/adams-review-walkthrough` command:
- is discoverable (listed in `~/.claude/commands/`)
- stays loosely coupled — reuses promote's helpers via a shared fragment but owns its own loop semantics
- lets users run it same-session, later, or in a fresh session

### 3.2 Per-finding briefing via Sonnet sub-agent, not inline orchestrator

Inline orchestrator synthesis would burn ~20-50k Opus tokens per finding (finding body + file context + CLAUDE.md excerpts). Delegating to a Sonnet briefing sub-agent (one per finding) matches the Phase 4 validator pattern, keeps orchestrator context lean, and scales linearly with finding count.

Briefing schema (returned by sub-agent as strict JSON):

```json
{
  "summary": "2-4 sentences on what the finding is and what the validator concluded (include disproven halves, if any)",
  "options": [
    {"label": "A", "title": "...", "detail": "...", "fix_hint_if_picked": "..." | null},
    {"label": "B", "title": "...", "detail": "...", "fix_hint_if_picked": "..." | null},
    ...
  ],
  "recommendation": {"label": "A" | "B" | ..., "rationale": "..."}
}
```

Orchestrator presents this verbatim as markdown, then dispatches `AskUserQuestion`. Budget: ~3-5k Sonnet tokens per finding.

### 3.3 Deferred render/publish batching via a promote flag

Add `--defer-publish` to `/adams-review-promote`:
- skips render + publish + user-visible summary steps
- all other steps run normally
- walkthrough sets this per-iteration; calls `artifact-render.py` + `artifact-publish.sh` once at the end

Alternative considered: walkthrough inlines patch logic directly. Rejected — would duplicate promote's jq + precondition table + fix-hint heuristic, guaranteeing drift.

### 3.4 Walkthrough does NOT re-invoke `/adams-review-promote` as a slash command

Slash commands aren't cleanly callable from inside another slash command in Claude Code (fresh conversation turn, context not inherited). Instead, walkthrough reuses the same helper primitives via a new `commands/_shared/promote-core.md` shared fragment that BOTH promote and walkthrough include.

This is a refactor of promote (not a rewrite) — promote's current top-level file shrinks to arg-parse + artifact-locate + include + render/publish/summary; the middle steps move to the shared fragment.

### 3.5 Scope filter: "what `/adams-review-fix` would skip at threshold N"

Walkthrough iterates findings where:

```jq
.findings[]
| select(.current_state == "open")
| select(.human_confirmation == null)
| select(.disposition | IN("confirmed_manual", "confirmed_report", "confirmed_auto", "uncertain", "partial", "regression", "below_gate", "pre_existing_report"))
| select(
    (.human_confirmation != null)                 # already promoted → excluded (redundant with above, kept for clarity)
    or not (
      (.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
      and (
        (.impact_type == "correctness" or .impact_type == "security")
        and (.score_phase4 != null and .score_phase4 >= $thr)
      )
    )
  )
| .id
```

Explicitly **excluded**: `resolved`, `disproven`, `pending_validation`. The exclusion of disproven is deliberate — the validator found positive evidence it's wrong; promoting those is `--force` territory. The exclusion of `human_confirmation != null` means partially-walked sessions resume cleanly.

Critical included case: light-lane `confirmed_auto` (fails `impact_type` gate) AND below-threshold `confirmed_auto` (fails score gate). These are findings the validator believes are mechanically-fixable but the Phase 8 default gates skip. This was the F012/F013/F015/F017/F019 case in the ray-finance session that surfaced the need for this command.

### 3.6 Threshold from positional arg, default 60

`/adams-review-walkthrough [threshold]` — same positional-integer convention as `/adams-review-fix`. Default 60 per DESIGN §13.2. The threshold is used solely for the scope-filter jq; it isn't stored anywhere.

### 3.7 Decisions-log PR comment posted as a *new* comment, not edit-in-place

The main review comment is edited in place by the batched `artifact-publish.sh` call (via the persisted `comment_id`). A second `gh api -X POST` creates a distinct "walkthrough decisions" comment so both the current state (main comment) and the audit trail (decisions comment) live in the PR thread. The new comment id is written to `trace.md` but NOT to `artifact.comment_id` (which stays pointing at the main comment for future fix runs).

### 3.8 End-of-review passive mention, not auto-prompt

At the end of `/adams-review` Phase 6 (step 6.8 chat mirror), add a "Next steps" block describing the walkthrough command — what it does, when to use it, that it works same-session or later. **No AskUserQuestion prompt.** Reasons:
- The walkthrough is a 15-30 min interactive session; auto-prompting at review completion catches users at a potentially bad time (review just finished, they're reading output, thinking).
- Matches `/adams-review-fix` and `/adams-review-promote` design philosophy — both *tell* the user how to invoke the next step rather than auto-chaining.
- Avoids the "feeling pressured to say yes" UX problem.

The descriptive block gives discoverability without pressure.

## 4. New top-level command: `commands/adams-review-walkthrough.md`

Shape:

```markdown
---
allowed-tools: Bash(...), Agent, AskUserQuestion, Read
argument-hint: "[threshold]"
description: Walk interactively through findings /adams-review-fix would skip; promote or skip each, then batch-publish.
disable-model-invocation: false
---
```

Body outlines (one §-per-step):

1. **Arg parse**: positional int → `threshold` (default 60). Any other token → stop and ask.
2. **Locate artifact**: identical to promote step 2. Schema-validate.
3. **Compute walkthrough scope**: run §3.5 jq → `scope_ids` (CSV). If empty, print "Nothing to walk through at threshold=N" and exit 0.
4. **Pre-flight summary**: print a preview table (id / lane / score / disposition / one-line claim). Dispatch `AskUserQuestion` — "Proceed / Cancel." Cancel → exit 0.
5. **Per-finding loop** (core):
   - Dispatch Sonnet briefing sub-agent with finding JSON + file snippet (Read tool usage inside agent) + CLAUDE.md excerpts.
   - Parse returned JSON (one retry on parse failure; else log + "Skip (briefing failed)" option).
   - Render briefing markdown to chat.
   - `AskUserQuestion` — options = briefing options + always-present "Skip this finding" + "Stop the walkthrough".
   - Dispatch per choice:
     - Promote choice → inline `artifact-patch.py` call equivalent to promote-core steps 3-6 + 9, with `DEFER_PUBLISH=1` set so render/publish/summary stay skipped (see §3.3, §3.4).
     - Skip → append to `decisions[]` with no mutation.
     - Stop → break loop; proceed to finalize with decisions made so far.
   - Record to `decisions[]`: `{finding_id, action, reason, fix_hint?, prior_disposition}`.
6. **Finalize**:
   - Call `artifact-render.py` once.
   - Call `artifact-publish.sh` once (PR mode uses persisted `comment_id`).
   - Render decisions-log markdown from `decisions[]`; POST as new PR comment via `gh api`. Capture new comment id → trace. DO NOT mutate `artifact.comment_id`.
   - Append `## walkthrough (<ts>)` block to `trace.md`.
   - Print user-visible summary: promoted count / skipped count / next step.

## 5. Refactor: extract `commands/_shared/promote-core.md`

New fragment contains the current `commands/adams-review-promote.md` steps **3** (read finding), **4** (preconditions), **4.5** (fix-hint prompt heuristic), **5** (build hc object), **6** (atomic patch), **9** (trace entry).

Top-level `commands/adams-review-promote.md` reduces to:
- Front-matter + arg parse (step 1)
- Locate artifact (step 2)
- **`!`cat ~/.claude/commands/_shared/promote-core.md`** preprocessor include
- Render (step 7) — skip when `${DEFER_PUBLISH:-0}` is 1
- Publish (step 8) — skip when `${DEFER_PUBLISH:-0}` is 1
- User summary (step 10) — skip when `${DEFER_PUBLISH:-0}` is 1

The shared fragment is include-only; it doesn't itself include anything or assume a specific call style. Callers set `$finding_id`, `$reason`, `$fix_hint`, `$force`, `$artifact_path`, `$trace_log_path` in ambient Bash context and the fragment reads them.

Walkthrough's per-iteration block sets those vars, then invokes the core logic via the same include.

## 6. Promote `--defer-publish` flag

Minimal additions to `commands/adams-review-promote.md` step 1 (arg-parse):
- `--defer-publish` → `defer_publish=true` (else `false`)
- Propagate to steps 7, 8, 10 as skip conditions

Why on the flag level (not just an env var for walkthrough): lets users script `for id in F001 F002 F003; do /adams-review-promote $id --defer-publish --reason "..."; done; /adams-review-render-and-publish` workflows without invoking the walkthrough. Cheap surface addition; tracks the walkthrough's same semantics.

Note: if `--defer-publish` is used outside the walkthrough, the user is responsible for eventually running `artifact-render.py` + `artifact-publish.sh` themselves. The summary line in step 10 would normally remind them; in defer mode we print a terse one-liner pointing to the helpers.

## 7. Briefing sub-agent prompt (DESIGN §28.4 draft)

```
You are a code-review triage briefer. A reviewer is walking through a
single finding and needs:

  1. A 2-4 sentence summary of what the finding is about and what the
     validator concluded (include disproven halves, if any).
  2. 3-5 concrete options the reviewer can pick from, each with a
     one-line title and 1-2 sentence detail. Options should span:
       - one or more "fix" variants (different fix-hint shapes)
       - a "skip — intentional / design decision" option
       - a "defer" option where appropriate
  3. A recommendation: which option + rationale + (for fix options)
     a specific fix_hint string suitable to pass to the Phase 8
     fix-group agent. Include negative constraints when over-engineering
     is a risk ("do NOT add a new flag"; "do NOT change the code").

Context provided inline:
- finding JSON (claim, file, line_range, impact_type, disposition,
  validation_result, score_phase4, sources)
- nearby file snippet (±30 lines around line_range) — fetch via Read
- CLAUDE.md rules that cite the same file or pattern
- other findings on the same file (cross-cutting awareness)

Return strict JSON matching:
{
  "summary": string,
  "options": [{"label": "A"|"B"|..., "title": string, "detail": string, "fix_hint_if_picked": string|null}],
  "recommendation": {"label": string, "rationale": string}
}

Hard rules:
- Emit ONE JSON object only. No surrounding prose. No code fences.
- Labels are single uppercase letters starting from A.
- Prefer specific fix_hint strings with negative constraints. Avoid
  vague hints like "fix the docstring" — say what to change and what
  not to change.
```

Model: Sonnet. Tool access: Read (for the file snippet). Budget: ~3-5k tokens per finding.

## 8. Helper / tool changes

- **`artifact-render.py`** — no change.
- **`artifact-patch.py`** — no change.
- **`artifact-publish.sh`** — no change. Walkthrough calls it once, same contract.
- **Scope-filter jq** — lives inline in the command body; no helper script.
- **Decisions-log markdown** — rendered inline in the command body; no helper script.

No new helper scripts in this stage. Walkthrough is pure orchestration.

## 9. `/adams-review` next-steps footer (new behavior)

Add a "Next steps" block to Phase 6 step 6.8 (chat-mirror tail). Appears AFTER the `artifact.md` body in chat, BEFORE the existing "Full artifact:" / "Fix commit will land locally..." lines. Text (approximate — will render dynamic counts):

```
---

**Next steps:**

- **Apply the auto-eligible findings** — run `/adams-review-fix [threshold]` (default threshold 60). Will pick up all findings in the "✓ Auto-fixable" tables for the deep lane that score ≥ threshold. Light-lane rows in those tables are skipped by default.
- **Walk through non-auto-eligible findings** — run `/adams-review-walkthrough [threshold]`. Presents each skipped finding (deep-manual, light-manual, light-report, light-auto-fixable) with a summary, options, and a recommendation; promotes the ones you approve with tailored fix-hints; posts a decisions log to the PR. Works same-session or later — the review artifact persists under `~/.adams-reviews/`.
```

Wording pinned to promote-command naming so we don't have to update copy later. Lives ONLY in the chat mirror, NOT in `artifact.md` (keeps PR comment clean).

## 10. DESIGN.md updates

### §28 — new section: `/adams-review-walkthrough`

~80 lines mirroring §27's structure:
- **§28.1 Invocation** — args, behavior summary
- **§28.2 Preconditions** — artifact must exist; any dirty-tree state ignored (walkthrough is metadata-only)
- **§28.3 Scope filter** — normative form of §3.5 jq
- **§28.4 Briefing sub-agent** — prompt + schema (from §7 of this plan)
- **§28.5 Per-finding interaction** — AskUserQuestion flow, decisions array shape
- **§28.6 Mutations** — delegated to §27.3 via `--defer-publish`
- **§28.7 Side effects** — batched render/publish, decisions-log comment, trace entry
- **§28.8 What it does NOT do** — no fix-run, no disproven, no resume, no cross-branch
- **§28.9 Interaction with `/adams-review-fix`** — promoted findings flow through normally
- **§28.10 Audit trail** — trace + decisions-log comment

### §27.1 — update invocation

Add `--defer-publish` to the invocation line; one paragraph in §27.4 explains the skip behavior and that walkthrough is the primary consumer.

### §27.5 — reword "no batch mode" caveat

"No batch mode in the command itself. Use `/adams-review-walkthrough` for guided multi-finding promote flows, or shell-loop `/adams-review-promote --defer-publish` calls for scripted workflows."

### §7 — report format

Add one line to the post-rendered-report footer section noting that `/adams-review-walkthrough` posts a separate decisions-log comment when used.

## 11. README.md update (suggested flow)

Add a new "Recommended flow" section after the surface-area list, framed as a suggestion (not a requirement):

```
## Recommended flow

Not required, but the three commands work best in this order:

1. **Review.** `/adams-review` — or `/adams-review --ensemble` if you have CodeRabbit + Codex CLIs installed and want a multi-source review at higher token cost.
2. **Walkthrough.** `/adams-review-walkthrough` — step through every finding the fix command would skip at the default threshold (deep-manual, light-manual, light-report, light-auto-fixable). Each finding gets a briefing + options + recommendation; promote the ones you want auto-fixed with tailored fix-hints, skip the rest. Posts a decisions log to the PR for audit.
3. **Fix.** `/adams-review-fix` — applies all auto-eligible findings (including whatever was promoted in step 2). Commits each fix group separately with a full provenance trail.

Each step is independent: you can run fix without walkthrough, or walkthrough without fix. The artifact under `~/.adams-reviews/` persists across sessions, so steps 2 and 3 can land days or weeks after step 1.
```

Also update the three-command surface list to four commands (add `/adams-review-walkthrough`).

## 12. CLAUDE.md update

Update the "What this repo is" section's "three personal Claude Code slash commands" to four commands. Add `/adams-review-walkthrough` to the list with a one-liner. Update the "All three are built and in production use" line.

## 13. Symlink

```bash
ln -s "$PWD/commands/adams-review-walkthrough.md" \
      ~/.claude/commands/adams-review-walkthrough.md
```

`_shared/promote-core.md` propagates automatically via the existing `_shared/` directory symlink.

## 14. Smoke assertions (test/smoke.sh)

Add `WT-*` block with 7 assertions (WT-0 added during the once-over
per §18):

| # | Label | Checks |
|---|---|---|
| WT-0 | promote-core precondition proceeds on `confirmed_auto` + `curr_hc == null` | Structural grep: "**Proceed.**" verdict present; "already confirmed_auto by validator…no-op" absent (§18, §27.2, §27.6) |
| WT-1 | scope filter excludes resolved/disproven/pending | Fixture with mixed dispositions; scope jq returns only the in-scope ids |
| WT-2 | scope filter excludes already-promoted findings | Fixture with `human_confirmation != null` on F001; F001 not returned |
| WT-3 | scope filter excludes fix-eligible findings (correctness, score ≥ threshold) | Deep finding at score 80 / confirmed_auto / correctness → not in scope |
| WT-4 | scope filter includes light-lane confirmed_auto | ux / confirmed_auto / score 80 → IS in scope |
| WT-5 | promote `--defer-publish` flag + promote-core include are wired | Structural grep on `commands/adams-review-promote.md` for `--defer-publish`, `defer_publish.*true`, `promote-core.md` |
| WT-6 | decisions-log markdown template has required structural markers | Grep on walkthrough.md for `adams-review-walkthrough-v1`, `### Walkthrough decisions`, `#### Promoted/Skipped/Stopped` |

Current total: 122. New total: **129**.

## 15. Execution order (commit-by-commit)

1. **Plan file commit** (this file). Smoke stays green trivially.
2. **Extract `_shared/promote-core.md`.** Move steps 3-6, 9 into the shared fragment; promote command includes it. No behavior change. Smoke stays green.
3. **Add `--defer-publish` to promote.** Arg parse + skip conditions in steps 7/8/10 of the top-level promote command. Add WT-5 smoke assertion.
4. **Walkthrough command scaffolding.** Arg parse, artifact locate, scope filter jq, pre-flight summary. Add WT-1 through WT-4 smoke assertions.
5. **Briefing sub-agent + per-finding loop.** Wire Agent dispatch + AskUserQuestion + shared promote-core inclusion. No new smoke assertion (interactive flow is hard to smoke-test deterministically).
6. **Finalize step + decisions-log comment.** Batched render/publish, POST new comment, trace entry, user-visible summary. Add WT-6 smoke assertion.
7. **`/adams-review` next-steps footer.** One-block addition to 07-finalize.md step 6.8. No new smoke assertion.
8. **DESIGN §28 + §27 updates, CLAUDE.md, README.md recommended-flow, symlink.** Docs + one-shot symlink. No new smoke assertion.

Each commit runs `test/smoke.sh` and stays green.

## 16. Future work (explicit)

- **`--resume` flag** to restart a partially-walked session from a specific id.
- **`--lanes light` / `--lanes deep`** filters to walk only part of the backlog.
- **`--and-fix`** opt-in flag that chains to `/adams-review-fix` at the end. Deliberately omitted from v1 to keep promote's "no auto-fix" contract intact.
- **Committed `decisions.md` file** inside the review directory (in addition to the PR comment) for permanent audit. `trace.md` already has the full record; the separate committed file is future polish.
- **Overrides-sidecar integration**: when the `overrides.json` sidecar lands (`manual-review-promote.md §13`), walkthrough decisions should persist across `/adams-review` reruns via the same path as promote.

## 17. Risk check (blast radius)

- **Every writer of `human_confirmation`**: only `/adams-review-promote` (today) and the walkthrough (via promote-core.md) after this stage. Shared fragment means one writer implementation, two callers. Diff risk at extract time: must confirm no ambient state leaks between promote's steps 2 and 3. I believe yes — every var is captured explicitly; will verify during commit 2.
- **Every consumer of `comment_id`**: Phase 9e fix-publish, promote republish, new main-comment batched publish in walkthrough. Walkthrough does NOT mutate `comment_id` (decisions-log comment id is trace-only). No collision.
- **Parallel code paths**: the promote-core fragment becomes the ONLY place precondition + patch logic lives after the refactor. Walkthrough and promote converge on it.
- **Stale docs to check**:
  - §27 invocation line, §27.5 NOT-do list
  - CLAUDE.md "three commands" → "four commands"
  - README.md surface-area list + new Recommended flow section
  - 07-finalize.md step 6.8 mirror tail
  - DESIGN §7 report-format footer mention
- **Sub-agent cost**: N findings × ~3-5k Sonnet tokens ≈ 30-50k for a typical 10-finding walk. Manageable.
- **AskUserQuestion option-list length**: 4-6 options per finding. Verified OK — promote already uses 4-option `AskUserQuestion` in step 4.5.
- **Rate limiting on `gh api`**: walkthrough issues at most 2 API calls at finalize (PATCH main + POST decisions). Fine.
- **Idempotent re-invocation**: if user re-runs walkthrough mid-session (after promoting some), the scope filter excludes already-promoted findings; no double-promote possible.

Post-execution once-over re-reads the extracted `promote-core.md` against the original promote command to confirm behavioral parity, and re-reads each DESIGN / README / CLAUDE.md edit for drift.

## 18. Pre-existing bug surfaced during execution

The once-over caught that promote's `confirmed_auto` + `curr_hc == null` precondition was a blanket no-op ("already confirmed_auto by validator; no-op"). The bug predates this stage (present in the original `/adams-review-promote` since commit de54b4b) but silently broke promoting two classes of findings:

- **Light-lane `confirmed_auto`** (impact_type ∈ ux/policy/architecture) — fails the Phase 8 impact_type filter; needs `human_confirmation` to bypass (§27.6). This is the F017/F012/F013/F015/F019 class in the ray-finance session that motivated the walkthrough.
- **Deep-lane `confirmed_auto` below the user's planned `/adams-review-fix` threshold** — fails the score gate; needs `human_confirmation` to bypass the score gate. Not specific to the walkthrough but still wrong.

First fix attempt split the precondition row by `impact_type` (deep-lane → no-op; light-lane → proceed). That was still wrong because promote doesn't know the user's planned `/adams-review-fix` threshold — a deep-lane finding at score 55 is NOT eligible if the user runs fix at threshold 70, but my first-pass split would have declared it eligible and no-op'd the promote.

Correct fix (landed): **always proceed** when `confirmed_auto` + `curr_hc == null`, regardless of impact_type or score. Always setting `human_confirmation` is strictly necessary in the two broken cases above and harmlessly redundant for deep-lane above-threshold findings (adds audit metadata; doesn't change behavior because Phase 8 would have picked it up either way).

Applied to `commands/_shared/promote-core.md` step 4 + DESIGN §27.2. Smoke assertion WT-0 guards against regression: checks the "Proceed" verdict is present on the row AND the old "already confirmed_auto by validator; no-op" text is absent.
