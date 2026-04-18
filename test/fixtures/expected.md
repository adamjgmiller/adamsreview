<!-- adams-review-v1 -->

### Code review

**Branch:** `feature/stage1-smoke` → `main`
**Mode:** local
**Review ID:** `rev_stage1smoke`
**Sub-agent tokens:** 12,000 across 8 invocations

Found 7 findings across all lanes:
- Deep lane (correctness/security): 1 resolved, 1 confirmed-manual, 1 uncertain
- Light lane (ux/policy/architecture): 1 confirmed-auto, 1 uncertain
- Pre-existing (high-confidence origin, report-only): 1

---

## Deep lane — correctness & security

### ✓ Auto-fixable (1) — `disposition: confirmed_auto | partial | regression | resolved`

| # | Score | Impact | File | Issue | Status |
|---|-------|--------|------|-------|--------|
| F001 | 85 | correctness | `src/auth/session.ts:42-58` | Null leak to callers assuming non-null | ✓ fixed and verified (`fedcba9`) |

<details><summary>Details and fix proposals</summary>

#### F001 — Null leak to callers assuming non-null

**File:** `src/auth/session.ts:42-58`
**Score:** 85 (strong)

**Latest fix attempt (fixrun_stage1smoke):** fixed and verified

</details>

### ⚠ Requires manual attention (1) — `disposition: confirmed_manual`

| # | Score | Impact | File | Issue | Why manual |
|---|-------|--------|------|-------|-------------|
| F002 | 78 | correctness | `src/billing/invoice.ts:55-80` | Partial-refund branch incomplete | design decision; needs product input |

### ℹ Uncertain (1) — `disposition: uncertain`

| # | Score | Impact | File | Issue |
|---|-------|--------|------|-------|
| F003 | 55 | correctness | `src/api/search.ts:33` | Query string possibly not escaped |

Phase 4 couldn't confirm decisively. Re-run `/adams-review` if you suspect this deserves
further investigation with fresh context.

## Light lane — ux, policy, architecture

| # | Score | Impact | File | Finding | Disposition |
|---|-------|--------|------|---------|-------------|
| F004 | 60 | ux | `src/components/DeleteButton.tsx:12` | Missing loading state on destructive action | confirmed_auto |
| F006 | 48 | architecture | `src/models/preferences.ts:15-22` | Deprecated pattern used in new code path | uncertain |

## Pre-existing — report-only (1) — `disposition: pre_existing_report`

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

🤖 Generated with Adam's Claude Code Review Command
