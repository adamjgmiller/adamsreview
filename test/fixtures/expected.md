<!-- adams-review-v1 -->

### Code review

**Branch:** `feature/stage1-smoke` → `main`
**Mode:** local
**Review ID:** `rev_stage1smoke`
**Sub-agent tokens:** 12,000 across 8 invocations

Found 8 findings across all lanes:
- Deep lane (correctness/security): 1 resolved, 1 manual, 1 uncertain
- Light lane (ux/policy/architecture): 1 auto-fixable, 1 uncertain
- Pre-existing (high-confidence origin, report-only): 1
- Filtered out: 1 disproven, 1 below score gate (<45)

---

## Deep lane — correctness & security

### ✓ Auto-fixable (1)

| # | Score | Impact | File | Issue | Status |
|---|-------|--------|------|-------|--------|
| F001 | 85 | correctness | `src/auth/session.ts:42-58` | Null leak to callers assuming non-null | ✓ fixed and verified (`fedcba9`) |

<details><summary>Details and fix proposals</summary>

#### F001 — Null leak to callers assuming non-null

**File:** `src/auth/session.ts:42-58`
**Score:** 85 (strong)

**Latest fix attempt (fixrun_stage1smoke):** fixed and verified

</details>

### ⚠ Requires manual attention (1)

_Not auto-applied by `/adamsreview:fix` directly — these need a confirmation step. Findings with an auto-recommendation get batch-confirmed at `:fix`'s Phase 7.5 preflight (or `:walkthrough` Step 4.5); use `/adamsreview:promote <finding_id>` for a single-finding manual override._

| # | Score | Impact | File | Issue | Why manual |
|---|-------|--------|------|-------|-------------|
| F002 | 78 | correctness | `src/billing/invoice.ts:55-80` | Partial-refund branch incomplete | design decision; needs product input |

### ℹ Uncertain (1)

| # | Score | Impact | File | Issue |
|---|-------|--------|------|-------|
| F003 | 55 | correctness | `src/api/search.ts:33` | Query string possibly not escaped |

Phase 4 couldn't confirm decisively. Re-run `/adamsreview:review` if you suspect this deserves
further investigation with fresh context.

## Light lane — ux, policy, architecture

_Light-lane findings — including rows labeled auto-fixable — aren't applied by `/adamsreview:fix` directly. Findings with an auto-recommendation get batch-confirmed at `:fix`'s Phase 7.5 preflight (or `:walkthrough` Step 4.5); use `/adamsreview:promote <finding_id>` for a single-finding manual override._

| # | Score | Impact | File | Finding | Disposition |
|---|-------|--------|------|---------|-------------|
| F004 | 60 | ux | `src/components/DeleteButton.tsx:12` | Missing loading state on destructive action | auto-fixable |
| F006 | 48 | architecture | `src/models/preferences.ts:15-22` | Deprecated pattern used in new code path | uncertain |

## Pre-existing — report-only (1)

Shown only when `origin_confidence: high`. Never auto-fixed in v1 (§13.1 pre-existing override).

| # | Score | File | Finding | Follow-up |
|---|-------|------|---------|-----------|
| F005 | 70 | `src/models/user.ts:12` | No index on `email` | File as separate issue |

## Fix runs

### Run `fixrun_stage1smoke` — 2026-04-17T21:30:00Z

- Outcomes: 1 fixed and verified
- Commits: `fedcba9`

| Finding | Group | Outcome | phase_9_finding |
|---------|-------|---------|-----------------|
| F001 | FG-1 | ✓ fixed and verified |  |

---

🤖 Generated with the [adamsreview](https://github.com/adamjgmiller/adamsreview) Claude Code Review Plugin
