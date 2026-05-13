---
branch: evals
base: main
started: 2026-05-13
---

# evals — test adamsreview against public AI-code-review benchmarks

Goal: find a public benchmark we can run adamsreview against without contacting anyone, both to track regressions over time and to compare against named competitors (CodeRabbit, Greptile, Codex, etc.).

## Two benchmarks investigated

### Martian — `codereview.withmartian.com` ✅ self-runnable, MIT

- Repo: <https://github.com/withmartian/code-review-benchmark>
- **Offline set:** 50 PRs from Sentry / Grafana / Cal.com / Discourse / Keycloak, each with human-curated "golden comments" (claim text + severity Low/Med/High/Critical) in `offline/golden_comments/{project}.json`.
- **Online stream:** continuously samples fresh GitHub PRs that already have bot comments — anti train-set-contamination.
- 6-step pipeline under `offline/code_review_benchmark/` (uv-run Python):
  `step0_fork_prs` → `step1_download_prs` → `step2_extract_comments` → `step2_5_dedup_candidates` → `step3_judge_comments` → `step4_generate_dashboard`
- **`step2` is format-agnostic** — uses an LLM to pull individual issue claims from any comment body. Our PR-comment shape works as-is, no custom parser needed.
- Judge configurable: Claude Opus 4.5, Sonnet 4.5, or GPT-5.2.
- Methodology paper: <https://withmartian.com/post/code-review-bench-v0>
- Full methodology: <https://github.com/withmartian/code-review-benchmark/blob/main/methodology/full.md>

### Kodus — `codereviewbench.com` ⚠️ unclear if separately runnable

- Marketing says "75 synthetic regressions across 5 languages, dual-judged by Sonnet 4.5 + GPT."
- Site claims a public GitHub but every search collapses back to the Martian repo.
- Likely either built on Martian's harness with their own dataset, or hosted-only with submission gated by contact.
- **Skip until they publish a clearly separable harness.**

## What "golden comments" are

The human-curated ground truth for each PR: a list of the real bugs that PR contains, written by human reviewers, each tagged with severity. The LLM judge measures:

- **Recall** = of N golden comments, how many did your tool surface?
- **Precision** = of M comments your tool surfaced, how many matched something in the golden set?

Known caveat (Martian's methodology doc admits this): the golden set is *not exhaustive*. If your tool finds a real bug nobody catalogued, the judge marks it a false positive. A "low precision" score may partly mean "found bugs not in the gold set," not "noisy." Worth remembering when reading our own results.

## Recommended first manual run

Pick a single PR, run locally, eyeball against the gold set. No fork-into-org / GitHub App machinery required.

**Discourse PR #4 — "Enhance embed URL handling and validation system"**
<https://github.com/ai-code-review-evaluation/discourse-graphite/pull/4>

- 666 changed lines (653+/13-), 28 files, **6 golden comments** — the heaviest entry in the entire dataset on the "bugs per PR" axis.
- URL embed / validation is a good domain stress-test for our security lens.
- 28 files / 666 lines is near the upper end of what Phase 1 detection lenses fit in one Opus context without truncation — also a useful long-context check.
- Note: discourse and keycloak golden entries use the *forked* `ai-code-review-evaluation/*-graphite` URLs; cal.com / grafana / sentry use upstream URLs. Practical: for discourse, `gh repo clone ai-code-review-evaluation/discourse-graphite && gh pr checkout 4` Just Works.

### Commands

```bash
# 1. Clone the benchmark fork outside this worktree
cd ~/Projects
gh repo clone ai-code-review-evaluation/discourse-graphite
cd discourse-graphite

# 2. Check out the PR branch
gh pr checkout 4
# If "could not find branch": gh pr checkout 4 --branch crb-discourse-pr4

# 3. Confirm diff size
git diff main...HEAD --stat | tail -5
```

In Claude Code from that directory:
```
/adamsreview:review
```
(no PR# = branch mode — diffs branch vs `main` locally; no PR-comment publish attempted, which matters because we don't have write access to the fork)

Optional: `/adamsreview:review --ensemble` to compare against ensemble lane (extra ~$3 Codex spend; bot-comment scrape will be empty on the fork, harmless).

### Compare against gold

```bash
# Golden comments for discourse PR #4
curl -s https://raw.githubusercontent.com/withmartian/code-review-benchmark/main/offline/golden_comments/discourse.json \
  | jq '.[] | select(.url | endswith("/pull/4")) | .comments'
```

Read our findings:
```bash
ls -lt ~/.adams-reviews/ | head -5  # newest run on top
jq '.findings[] | {id, claim, disposition, effective_score, lane,
                   file: .evidence.file, lines: .evidence.line_range}' \
  ~/.adams-reviews/<RUN_ID>/artifact.json
```

Eyeball each `confirmed_*` finding against the 6 golden comments. Track three numbers:
- Recall: matched-golden / 6
- Precision-ish: matched-golden / total-confirmed
- What landed in `disproven` / `below_gate` / filtered — gate calibration signal
- Run cost from `.tokens.subagent_tokens` for the $/PR estimate before scaling.

## Backup PR choices (also 5-comment)

All other ≥5-comment PRs in the dataset, in case discourse#4 hits some blocker:

| Project | PR | Lines | Files | Comments |
|---|---|---|---|---|
| discourse | #4 | 666 (653+/13-) | 28 | 6 |
| cal.com | #10967 | 584 (368+/216-) | 22 | 5 |
| cal.com | #11059 | 494 (375+/119-) | 40 | 5 |
| cal.com | #14740 | 555 (555+/0-) | 15 | 5 |
| grafana | #79265 | 142 | 11 | 5 |
| sentry | #93824 | 249 | 6 | 5 |

(grafana and sentry are smaller-diff but still 5 comments — could be useful for fast cheap iteration runs.)

## Path to full benchmark integration (deferred)

If the manual run looks promising, the path to a "real" submission:

1. Fork the 50 PRs into an `adamsreview-bench` GitHub org (their `step0_fork_prs` does this).
2. Driver script: loop over forked PRs, run headless `claude -p "/adamsreview:review $PR_URL" --plugin-dir <path>` per PR. ~50 sequential invocations is hours; parallelize as fanout.
3. `step1_download_prs` scrapes comments by author — filter by our bot account.
4. `step2_extract_comments` LLM-extracts individual claims (format-agnostic, our shape works).
5. `step3_judge_comments` produces precision/recall against gold.
6. `step4_generate_dashboard` renders.

**Cost ballpark for a full run:** 50 × adamsreview spend ($50–150 on Anthropic, more with `--ensemble`) + judge spend ($30–60). Driver wall-clock: hours sequential, less if parallelized.

**Friction to expect:**
- adamsreview is a Claude Code slash command, not a GitHub App. Need `claude -p` headless driver.
- Our PR comment includes `filtered_findings_summary` (suppressed/disproven items). If step2's LLM extractor treats those as claimed issues we get phantom false positives. Worth a smoke run on 2-3 PRs first; if it's a problem, fence the filtered block inside an HTML comment that the extractor skips, or strip it in a benchmark-mode flag.
- Author filter: PR comments posted via `gh pr comment` come from the user running it, not a bot. Use a dedicated bot account or filter by author in step1.

## Open questions / next steps

- [ ] Run the manual discourse#4 eval and capture recall/precision-ish/cost numbers.
- [ ] If results are encouraging, decide whether to invest in the full 50-PR pipeline (depends on $ budget appetite + how stable the methodology is — it's still v0).
- [ ] Decide whether to also evaluate the Codex-driven path (`/adamsreview:codex-review`) separately — it's a different "product" from the benchmark's POV.
- [ ] Check whether Kodus's harness ever ships separately (`codereviewbench.com`); revisit if it does.
