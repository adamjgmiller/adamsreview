# Review Workflow

Run this workflow for `$adamsreview review`.

## Preflight

Resolve the repo root, branch, base branch, PR number/state when available, comparison ref, reviewed SHA, touched files, and project instruction paths:

```bash
scripts/instruction-paths.sh --repo-root "$repo_root" --files @-
```

Seed the artifact with `scripts/artifact-seed.sh`, then initialize with `scripts/artifact-patch.py --init`.

Detect trivial reviews with `scripts/trivial-check.sh`. Trivial reviews may skip L2, L6, and L7, and route all validation through the light lane.

## Detection And PR Enrichment

Read `references/parallel-contract.md`.

Prepare lens prompts from `references/lens-prompts/_shared-invariants.md` plus each applicable `L<N>.md`. Replace `$comparison_ref`, `$reviewed_sha`, and `$claude_md_paths` placeholders with the current values. The field name stays `claude_md_paths` for schema-v1 compatibility, but the values come from `instruction-paths.sh`.

If parallel agents are authorized, dispatch all applicable lenses as read-only `explorer` agents in one batch.

When `mode == pr` and `pr_number` exists, run PR enrichment while lenses are active:

```bash
scripts/external-scrape.sh --pr "$pr_number" > "$scratch/pr-scrape.raw.json" 2> "$scratch/pr-scrape.err"
```

On success, pipe through `scripts/comment-freshness.sh`. On failure, write `[]`, append the stderr to `trace.md` with `external_pr_scrape_failed`, and continue.

Normalize actionable PR bot comments into normal candidates with `sources: ["external-pr:<bot-login>"]`.

## Join And Score

Wait for every lens and PR-enrichment source. Combine candidates, run `scripts/line-range-check.sh`, assign IDs with `scripts/assign-finding-ids.sh`, and add accepted findings in one batched `scripts/artifact-patch.py --add-findings` call.

Dedup, score, validate, generate auto-fix hints, render, and publish using the existing helper contracts. Keep deep validation and light validation parallel as described in `parallel-contract.md`.

## Output

Always produce or refresh `artifact.json`, `artifact.md`, `trace.md`, `phases.jsonl`, and `tokens.jsonl`. In PR mode, publish or patch the PR review comment with `scripts/artifact-publish.sh`.
