---
name: adamsreview
description: Parallel Codex code review workflow for pull requests and local branches. Use when Codex should run Adamsreview review, add, walkthrough, promote, or fix modes; create persistent review artifacts under ~/.adams-reviews; enrich PR reviews with automated GitHub reviewer comments; validate findings; or apply eligible fixes with parallel workers.
---

# Adamsreview

## Overview

Use this skill to run the Adamsreview pipeline as a Codex-native workflow. The skill keeps the existing artifact schema and helper scripts, but replaces Claude slash commands with natural-language modes.

Supported modes:

- `review`: run a parallel multi-lens review and write `artifact.json` / `artifact.md`.
- `add`: inject external or manual findings into the latest artifact.
- `walkthrough`: triage findings that `fix` would skip.
- `promote`: mark one finding as auto-fixable through human override.
- `fix`: apply eligible findings with parallel fix-group workers, review the result, and commit survivors.

## Resource Map

- Read `references/parallel-contract.md` before any mode that launches sub-agents or worker agents.
- Read `references/review-workflow.md` for `review`.
- Read `references/fix-workflow.md` for `fix`.
- Read `references/lifecycle-workflows.md` for `add`, `walkthrough`, and `promote`.
- Lens prompt bodies live in `references/lens-prompts/`.
- Helper scripts live in `scripts/`; run them by absolute path from this skill folder unless the environment already put them on `PATH`.
- `scripts/schema-v1.json` is the artifact schema source of truth.

## Global Rules

Keep state under `${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}`.

Preserve schema v1 compatibility. The top-level `claude_md_paths` field remains in schema v1 and now stores project instruction files discovered by `scripts/instruction-paths.sh` (`AGENTS.md` first, legacy `CLAUDE.md` fallback).

For PR mode, always attempt automated GitHub reviewer comment scraping. Use `scripts/external-scrape.sh` and `scripts/comment-freshness.sh`; on auth, network, or rate-limit failure, log the failure and continue without PR-comment enrichment.

Before mutating files in `fix`, require a clean or intentionally stashed working tree. Never delete or rename files in automated fix workers.

## Parallelism

Parallelism is a correctness and latency requirement. If the user has not clearly authorized parallel sub-agents, ask once for permission to run the parallel workflow; recommend parallel. Serial execution is only a fallback.

Use Codex sub-agents only when the user explicitly authorizes parallel agent
work in the current request or response. When authorized, follow
`references/parallel-contract.md` exactly. If Codex refuses a fan-out because
the user's configured agent limit is lower than the queued work, tell the user
they can raise `[agents].max_threads` in their Codex config, then continue with
the bounded rolling-window fallback described there.
