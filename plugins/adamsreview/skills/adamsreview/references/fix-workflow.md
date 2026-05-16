# Fix Workflow

Run this workflow for `$adamsreview fix`.

## Load And Gate

Locate the latest artifact for the current branch under `${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}` and validate it with `scripts/artifact-validate.sh`.

Abort on leftover `current_state == "attempted"` findings. The user must inspect the tree and reset those findings manually.

Filter eligible findings using the schema-v1 Phase 8 selector: open findings with `confirmed_mechanical`, `partial`, or `regression`, in the deep lane and at or above threshold, plus any finding with `human_confirmation`.

Run `scripts/group-fixes.py` to produce disjoint fix groups.

## Parallel Fix Groups

Read `references/parallel-contract.md`.

Apply `open -> attempted` for all eligible findings with one `scripts/artifact-patch.py --apply-fix-start` call.

When parallel agents are authorized, queue one `worker` per fix group and run
them in parallel, using the bounded rolling-window fallback from
`parallel-contract.md` only if Codex reports the user's configured
concurrent-agent limit. Each worker gets:

- Its finding JSON and validation context.
- Human `fix_hint`, when present.
- Cross-cutting groups intersecting the fix group.
- Sibling findings on planned files for collision awareness.
- Explicit file ownership from `group-fixes.py`.

Worker constraints:

- Edit only owned files.
- Do not run git operations.
- Do not delete or rename files.
- Return `files_modified`, `files_created`, per-finding verification results, and a concise summary.

After all queued workers finish, the parent integrates worker results in
deterministic group order and rejects deletes/renames before continuing.

## Post-Fix Review

Run one post-fix reviewer over the integrated working-tree diff. Classify every attempted finding as `verified`, `partial`, or `regression`.

Revert regression groups, commit surviving groups, update fix attempts with `scripts/artifact-patch.py --apply-fix-outcomes`, re-render, and publish.

If revert or integration fails, do not commit. Leave trace output and give the user recovery steps.
