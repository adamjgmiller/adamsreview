# 03 — Commands and UX

The user-facing surface. Namespaced slash commands under a single plugin, predictable flags, an interactive walkthrough that uses native Claude Code UI elements.

## Commands

Today's four flat top-level commands collapse into a single plugin namespace — one command file per verb so each gets its own `description`, `argument-hint`, and `allowed-tools`:

```
/adams-review:review                    # Full review: preflight → scan → triage → investigate → finalize
/adams-review:walkthrough               # Interactive per-finding walk; promote/skip/file-issue/dismiss
/adams-review:fix                       # Apply eligible fixes; post-fix review; commit or revert
/adams-review:add [<paste...>]          # Inject externally-sourced findings (paste / structured) into existing artifact
/adams-review:promote <id> [...]        # Manual promotion of a single finding
/adams-review:history                   # List recent reviews with tokens + wall-clock
```

**Recommended flow on a non-trivial PR:** `/adams-review:review` → (optional) `/adams-review:add` → (optional) `/adams-review:walkthrough` → `/adams-review:fix`. Each verb is independent; `:promote` is for one-off manual promotions outside the walkthrough.

Each command file is a short trampoline that shells into the orchestrator with its verb. Example:

```markdown
# commands/review.md → /adams-review:review

---
description: Multi-perspective code review. Scan → triage → investigate → publish.
argument-hint: "[--mode quick|standard|thorough|ensemble] [--scanners a,b,c] [--repeat ID=N] [--full] [--dry-run]"
allowed-tools: Bash(node:*), Agent, AskUserQuestion, Read, Bash(git:*), Bash(gh:*)
---

Invoke the orchestrator:

    node "${CLAUDE_PLUGIN_ROOT}/scripts/orchestrator.mjs" review $ARGUMENTS

The orchestrator emits one JSON step object per turn. For each step:
  - next_step == "dispatch_agents" → fire one Agent tool-use per entry in `dispatches`,
    all in the same turn for parallelism; pipe results back via `… apply <json>`.
  - next_step == "ask_user"        → fire AskUserQuestion with the provided options.
  - next_step == "user_visible"    → print the provided block to chat.
  - next_step == "done"            → print final summary and stop.

See `01-architecture.md § Dispatch-turn protocol` for the full protocol.
```

The other command files (`walkthrough.md`, `fix.md`, `add.md`, `promote.md`, `history.md`) follow the same shape — only the first arg to the orchestrator (the verb) and the `allowed-tools` differ (e.g. `history` doesn't need `Agent`; `walkthrough` needs `AskUserQuestion`).

Per-turn slash-command prompt surface: a short loop-and-dispatch fragment, *constant across every review*. No phase-specific fragments inlined. The same protocol fragment appears in every command file; the orchestrator provides the step JSON that determines the work.

## Flags (summary)

Global flags available on every verb:

```
--dry-run             for review/add: run through detection + triage but skip investigate/publish.
                      For fix/walkthrough/promote: skip side effects (no git writes, no PR POST/PATCH).
                      For history: no-op.
```

`/adams-review:review`:

```
/adams-review:review [--mode MODE] [--scanners LIST] [--no-scanner NAME] [--repeat ID=N]
                     [--full] [--threshold N] [--base BRANCH] [--dry-run]

--mode MODE           quick | standard | thorough (default) | ensemble — see 02-scanners.md § Modes
--scanners LIST       override mode with comma-separated scanner ids
--no-scanner NAME     remove one scanner from the selected set
--repeat ID=N         run scanner ID N times (repeatable flag; overrides mode default)
--full                force user_facing=true, skip trivial-mode early-exit
--threshold N         Investigate → eligibility gate (default: confidence high)
--base BRANCH         override detected base branch
```

`--mode thorough` is the default. It runs the full base portfolio plus holistic with replicas on careful-reader and combined-sweep, projecting ~1.5–1.6M tokens — comparable to today's spend but with significantly higher recall from corroboration voting + the unconstrained holistic safety net. Pick `--mode standard` for the cheaper (~900k) pass; `--mode quick` for trivial diffs; `--mode ensemble` to add CodeRabbit / Codex / PR-scrape on top of thorough.

`/adams-review:fix`:

```
/adams-review:fix [--threshold N] [--granular-commits] [--only IDS] [--interactive]

--threshold N         override the fix-eligibility threshold (default: high confidence)
--granular-commits    one commit per surviving fix group (default: one combined commit)
--only IDS            comma-separated finding ids; restrict the run
--interactive         pause before fix-group dispatch and show the plan for user confirmation
```

`/adams-review:promote`:

```
/adams-review:promote <id> [--reason "..."] [--hint "..."] [--force]
```

`/adams-review:add`:

```
/adams-review:add [<paste...>] [--file PATH --line N --claim "..."] [--impact TYPE] [--no-dedup]

(positional)          free-form paste body — chat dump, review summary, multi-bug list
--file PATH           structured-mode: file path for the new finding (requires --line + --claim)
--line N              structured-mode: line number
--claim "..."         structured-mode: one-sentence claim
--impact TYPE         override impact_type for emitted candidates (default: correctness)
                      one of: correctness | security | ux | policy | architecture
--no-dedup            skip the dedup pass against existing findings
```

`--file`, `--line`, and `--claim` must be supplied together (structured mode); omit all three for paste mode.

`/adams-review:history`:

```
/adams-review:history [--since 30d | --all] [--repo SLUG] [--format table | json]
```

## Interactive flows

### Walkthrough

Walks the reviewer through every finding `/adams-review:fix` would skip at the current threshold.

Flow (summarized; details in orchestrator code):

1. Preflight: load latest artifact, compute skip set (confidence < threshold, !fixable, pre-existing, manual-lane, etc.).
2. Scope prompt (AskUserQuestion, one-shot):
   - Qualifying skip set (default) — skip Phase-3-demoted low-confidence findings
   - Full skip set — include everything the fixer won't touch
3. For each finding in the chosen scope:
   - Dispatch a Sonnet briefing agent: `{summary, options, recommendation}`.
   - Render the briefing in chat.
   - AskUserQuestion with options:
     - Promote → run `/adams-review:promote <id>` with `--defer-publish`.
     - Skip → append event, move on.
     - Edit hint → prompt for free-form hint text, then promote.
     - Dismiss (with reason) → append `human_override(kind: "dismiss")` event.
     - Stop walkthrough.
4. After the loop: re-render `artifact.md`, re-publish the main review comment once.
5. For each `pre_existing` finding (PR mode only): offer to draft + create a GitHub issue.
6. Post a "Walkthrough decisions" comment to the PR.

Walkthrough is ~80 LoC of TypeScript orchestrator + one Sonnet prompt file + one comment-rendering function.

### Fix

`/adams-review:fix` runs end-to-end without user input by default. With `--interactive`, it pauses before fix-group dispatch and shows the user the fix-group plan ("FG-1 will modify src/foo.ts, src/bar.ts; FG-2 will modify src/baz.ts — proceed?").

### Promote

`/adams-review:promote <id>` is a metadata-only mutation. Appends `override_applied(kind: "promote", ...)` event, re-renders, re-publishes. No re-investigation. If `--force` is omitted and the finding is at `verdict: disproven`, aborts with a pointer to the investigator's conclusion.

### Add

`/adams-review:add` injects findings sourced from outside `/adams-review:review` into the existing artifact for the current branch. Three invocation shapes:

- **Paste mode** (default): every positional `$ARGUMENTS` token joins into the paste body. A Sonnet "paste normalizer" sub-agent extracts one or more candidates from prose. Use for chat dumps from Claude Code's `/ultrareview`, Opus once-overs, CodeRabbit prose output, teammate Slack messages.
- **Structured mode**: `--file/--line/--claim` (all three required together) skip the normalizer and build one candidate inline. Use for hand-crafted findings.
- **Mixed mode**: paste + `--impact <type>` overrides the normalizer's per-candidate guess. Use when you know the input is "all security" or "all UX."

Flow:

1. Locate the artifact via `latest.txt`. Refuse if no review exists for this branch.
2. Hard abort if any finding has a `fix_attempted` event without a matching `fix_classified` (mirrors fix's leftover-attempted gate).
3. Build candidate(s) per the invocation shape. Normalizer or inline.
4. Dedup against existing findings (one Sonnet call) unless `--no-dedup`. Matched candidates merge their source into the existing finding's `sources[]`; unmatched proceed.
5. Assign new IDs continuing past the highest existing F-id (no F001 collision).
6. Investigate (lane-aware Opus deep / Sonnet light, no Wave 2 chain retry).
7. Re-render `artifact.md`; PATCH the existing PR comment via the persisted `comment_id`.
8. Print a summary block:

   ```
   Added 3 new findings to rev_01K…:
     F037 confirmed_auto    correctness  src/foo.ts:142 — early-return skips audit-log
     F038 uncertain         correctness  src/bar.ts:88  — possible race in cache invalidation
     F039 disproven         correctness  src/baz.ts:12  — (validator: not a real issue)
   Deduplicated 1 candidate against existing F003 (sources merged).

   Next: /adams-review:fix or /adams-review:walkthrough to act on the new actionable findings.
   ```

External candidates carry `confidence: high` and **skip Triage** — see `01-architecture.md § Why merge dedup + scoring (Triage)` rule 2 and `§ Add flow`. The reasoning: a human bothered to escalate them; deep Investigate is the right precision gate, not a Sonnet rubric.

## Output UX

The rendered `artifact.md` and PR comment group findings by **section**, derived from the view layer. Each section corresponds to a derived view identifier (see `01-architecture.md § Data model` for the mapping):

```
## Auto-fixable                            (verdict: confirmed; fixable; origin: introduced)
## Manual attention needed                 (verdict: confirmed; not fixable)
## Uncertain — worth a second look         (verdict: uncertain)
## Pre-existing — informational            (origin: pre_existing; origin_confidence: high)
## Informational                           (verdict: confirmed; impact: architecture/ux/policy and report-only)
## Below detection gate                    (confidence: low) — collapsed by default
## Disproven                               (verdict: disproven) — collapsed by default
## Fix results                             (shown only when fix_attempts exist)
```

Each finding shows: confidence badge, scanner tags (which scanners flagged it), impact, file:line, one-sentence claim, expandable evidence/blast-radius block, expandable fix proposal, optional human_override note.

## PR comment strategy

Same as today: one "main" comment identified by a stable HTML marker at the top (`<!-- adams-review-v1 -->`), POST on first publish and PATCH on re-publish. A separate "Walkthrough decisions" comment when the walkthrough runs. `gh api` calls through Octokit (TS), so no shell dance.

## Effort-level exposure

Claude Code exposes a session-wide effort setting (low / medium / high / xhigh / max). The tool respects it via `Agent` dispatch — the parent's effort flows into sub-agents. The orchestrator prints a one-liner at review start:

```
Running /adams-review:review at effort=high (mode=thorough) — expect ~1.5–1.6M tokens, ~35 min wall-clock.
```

Numbers are derived from the chosen mode's budget estimate (see `00-overview.md § Baseline`).

## Tokens & cost transparency

After every `/adams-review:review`, the user sees a summary block. Example for `--mode thorough` (default):

```
Review complete (rev_01K…)  mode=thorough

Findings: 34 total → 12 confirmed, 5 uncertain, 5 disproven, 2 pre-existing, 10 below gate
  Auto-fixable: 9    Manual: 2    Informational: 1
  Corroborated (≥2 scanners): 11 (auto-graduated)

Tokens: 1.52M total (vs 1.48M on old pipeline — parity, with corroboration voting)
  Preflight (incl. enrichment):  18k
  Scan (thorough portfolio):    1.04M
    Cached prefix saved:         ~180k at ~10% cost
  Triage (dedup + scoring):      78k
  Investigate (confirmed set):  392k
  Finalize (render + comment):   20k

Wall-clock: 33 min 04 sec
Report: <pr_comment_url>

Next: /adams-review:walkthrough (for the 8 skippable findings) or /adams-review:fix (9 auto-fixable).
```

The same block under `--mode standard` lands around ~900k tokens / ~22 min wall-clock with fewer findings (no holistic safety net, no corroboration boost).

This visibility creates its own pressure to keep the budget in check. It's also the data the user needs to judge whether `--thorough` is worth it on a given repo.

## Recoverable errors

All user-visible errors follow the format:

```
ERROR: <what happened>

CONTEXT: <why it matters>

VALID: <what should have been provided>

ACTION: <what to do next>
```

Examples:

- `review fix` with a stale working-tree:

```
ERROR: working tree has uncommitted changes.

CONTEXT: /adams-review:fix will stage and commit edits; starting with
uncommitted changes would conflate your work with the fix run.

ACTION: stash or commit your changes, then re-run:
  git stash -u && /adams-review:fix && git stash pop
```

- `review promote` on a non-existent id:

```
ERROR: finding id F099 not found in latest review (rev_01K…).

CONTEXT: available ids: F001–F029.

ACTION: double-check the id in the PR comment or in artifact.md.
```

## Testability

The orchestrator's JSON-step protocol means every dispatch decision is inspectable without running an actual review. Integration tests fixture `events.jsonl` inputs → expected `next_step` outputs. One "golden review" fixture replaces today's 2,502-line smoke.sh with ~30 TypeScript test cases.

## Conversion table (today → new)

| Today | New | Notes |
|---|---|---|
| `/adams-review` | `/adams-review:review` | Same job, fewer flags; plugin-namespaced. Default mode shifts from today's "all lenses" to `--mode thorough` (full portfolio with replicas + holistic safety net). |
| `/adams-review --ensemble` | `/adams-review:review --mode ensemble` | External scanners are regular scanners in the new world. |
| `/adams-review --full` | `/adams-review:review --full` | Same flag. |
| `/adams-review-walkthrough [threshold]` | `/adams-review:walkthrough [--threshold N]` | |
| `/adams-review-fix [threshold]` | `/adams-review:fix [--threshold N]` | |
| `/adams-review-fix --granular-commits` | `/adams-review:fix --granular-commits` | |
| `/adams-review-add ...` | `/adams-review:add ...` | New verb in today's `review-add` branch (built, unmerged in main). Carried forward into v2 unchanged in spirit. |
| `/adams-review-promote <id> ...` | `/adams-review:promote <id> ...` | |

No deprecation window for the old commands during rebuild — the spec is a clean slate. `/plugin install adams-review` provides the new command set; users `/plugin uninstall` the old-shape install (or delete the four old command symlinks manually) alongside.
