# Helper inventory

All scripts live under `bin/`. Claude Code's plugin runtime makes `bin/`
available on `$PATH`, so `allowed-tools` grants and in-body invocations both
use bare names: `Bash(<script>:*)` / `<script> --flag ...`.

Each script has a 20–60 line file-header docblock that's authoritative for the
contract — `head -40 bin/<script>` for any helper. This file is the one-page
overview; CLAUDE.md keeps a one-liner pointer.

## Readers (safe for any agent)

| Script | Lang | Purpose |
|---|---|---|
| `artifact-read.sh` | Bash | `jq` wrapper. Flags: `--filter <jq>`, `--finding-id <id>`, `--summary` (emits `counts_by_disposition`). |
| `staleness.sh` | Bash | Phase 7 file-overlap classifier. `git diff --name-only latest_known_sha..HEAD ∩ reviewed_files_all`. |
| `claude-md-paths.sh` | Bash | Walks up from each touched file to repo root; emits deduped CLAUDE.md paths root-first. |
| `origin-crosscheck.sh` | Bash | Phase 1 post-lens. Blame-traces each candidate. Main path (file in `$comparison_ref` tree): respects lens-supplied `pre_existing/high` when blame agrees; for any lens output that is NOT `pre_existing/high` (introduced_by_pr at any confidence, `pre_existing/medium`, `pre_existing/low`, or unknown) whose blame is fully ancestor of `$comparison_ref`, sets `pre_existing/medium` (action=downgraded) so §13.1 doesn't force-route exposure findings or wrong-line-range cites to the report-only footnote — Phase 3 + Phase 4 decide instead. The audit `reason` distinguishes the lens-introduced-by-pr case (`lens-introduced-by-pr-but-all-blame-ancestor`) from the catch-all (`lens-not-preexisting-high-but-all-blame-ancestor`). Also downgrades lens-supplied `pre_existing/high` to medium when blame includes PR commits. Rename-follow path (file NOT in `$comparison_ref` tree): walks `git log --follow` to the pre-rename / pre-extraction ancestor and re-checks — if every blame SHA is either an ancestor of `$comparison_ref` or one of the file-add commits (content-preserving extraction — F038 case), overrides lens to `pre_existing/high` (--follow extraction trace is stronger evidence than the main path's all-ancestor check); PR-added lines inside an extracted file still respect the lens (`rename-follow-but-lines-modified-in-pr`). Genuinely-new files (no rename ancestor) keep the `reason=new-file` respect-lens path. |
| `line-range-check.sh` | Bash | Phase 1 join-step sanity filter. Drops candidates whose `line_range[1]` overshoots the file at `$reviewed_sha` (lens-hallucinated ranges); emits `lens_hallucinated_line_range:` / `lens_referenced_missing_file:` audit lines. Pass-through for `file == "(unknown)"`. Complements the file-absolute `line_range` invariant in `fragments/01-detection.md` §1.2.1 (preventive prompt-level rule + corrective runtime filter). |
| `comment-freshness.sh` | Bash | Phase 1.5 post-scrape. Drops bot comments whose referenced code has changed since the comment was posted (§13.13). |
| `prior-fix-diff.sh` | Bash | Phase 1 L2 input. Deterministic prior-fix suspect scan: walks `git log -L` per hunk in the PR diff, filters to fix-intent commit subjects whose SHAs are ancestors of `$comparison_ref` (excluding the PR's own internal fix commits), emits a JSON array of suspect records for L2's prompt to judge as reverts. |
| `repo-slug.sh` | Bash | Canonical `<repo-slug>` derivation. Single source of truth (Operational rule 7). |
| `trivial-check.sh` | Bash | Phase 0.11 trivial-diff classifier (§13.9). Reads newline-separated file list from stdin + `--num-files` + `--lines-changed`; emits `{trivial_mode, reason}` with `reason ∈ {docs_only, null}` (only `docs_only` implemented — other enum members reserved for future expansion). Vacuously trivial on empty stdin + zero counts, matching the pre-extraction inline fragment. The orchestrator-side `force_full=true` short-circuit stays in `fragments/00-preflight.md` step 0.11 (helper has no knowledge of `force_full`). |
| `artifact-seed.sh` | Bash | Phase 0.15 initial-artifact seed builder. Takes Phase-0 outputs as flags (`--review-id`, `--review-started-at`, `--reviewed-sha`, `--base-branch`, `--head-branch`, `--mode`, `--pr-state`, `--pr-number`, `--comment-id`, `--trivial-mode`, `--base-context <json>`, `--reviewed-files-all <newline-sep>`, `--claude-md-paths <newline-sep>`, `--files-changed`, `--lines-changed`) and emits the schema-shaped seed JSON on stdout. Pipe to `artifact-patch.py --init -` for persistence. Seeds `reviewer_sources: ["internal"]`, `generated_at = review_started_at`, empty `findings` / `cross_cutting_groups`, zeroed `subagent_tokens`, nulled `metrics`. Nullable flags (`--pr-state`, `--pr-number`, `--comment-id`) accept empty string → JSON null. The §13.10 `base_context` sub-object is still built via `jq -n` in the fragment (preserves explicit null-handling for offline paths) and passed as a single JSON string. Pure output helper — no on-disk mutations; `--init` is what writes. |
| `parse-with-repair.py` | Python | Stdin-to-stdout tolerant JSON parser. Layers: strict `json.loads` → fence-strip → `json-repair` → fence-strip+repair. Exit 0 = clean JSON on stdout, exit 1 = unrecoverable with error-as-prompt stderr. Foundation for the two normalizers below; used at the ensemble-adapter normalizer boundary (messiest external-tool output). |
| `parse-validator-result.py` | Python | Canonicalizes Phase 4 validator output to `{score_phase4, actionability, confirmed_strength, decision, notes, validation_result, related_candidates_to_investigate}`. Handles shape drift: `{score_phase4}`, `{score:{correctness}}`, `{overall_numeric}` (1-5), `{severity: low/medium/high}`, ambiguous `{score: N}` (heuristic 1-5 / 1-10 / pass-through). `--lane deep\|light`. Exit 2 = score unrecoverable (caller routes to `uncertain` with `score_phase4: null`). Uses `parse-with-repair.py` internally. Deep-lane `validation_result` is schema-checked against `bin/schema-v1.json#/$defs/validation_result` after any top-level lift; drift (missing sub-objects, alternative keys, malformed `blast_radius`, etc.) drops `validation_result` to `null` with a "shape unrecoverable" note so the downstream `--apply-decisions` batch doesn't halt on one drifted tuple. |
| `source-family-map.py` | Python | Maps lens-emitted `source_family` to canonical (eight families, all `*-family`-suffixed: `diff-family`, `structural-family`, `policy-family`, `ux-family`, `security-family`, `holistic-family`, `external-deep-family`, `external-add-family` — the last emitted by `/adamsreview:add`). `--input <raw>` → canonical on stdout (exit 0) or `UNKNOWN_FAMILY:` on stderr (exit 3). Phase 1 join-step uses exit 3 to tag the candidate `source_family: "unknown"` + log drift — preserves the finding rather than silently dropping it. |

## Writers (orchestrator-only)

| Script | Lang | Purpose |
|---|---|---|
| `artifact-patch.py` | Python | Every finding-level mutation. Mutually-exclusive modes: `--init`, `--add-finding`, `--add-findings` (continue-on-error; single atomic write across the accepted batch; exit 7 = all-rejected, distinct from exit 1 = post-write validation failed), `--delete-finding`, `--apply-decisions`, `--apply-fix-start`, `--apply-fix-outcomes`. Finding-modify flags (pair with `--finding-id`): `--set`, `--set-json`, `--append-fix-attempt`. Global: `--dry-run`. Enforces state-transition whitelist + disposition/is_actionable invariants + error-as-prompt. |
| `artifact-publish.sh` | Bash | PR comment POST/PATCH. `--comment-id <id>` for PATCH; no auto-discovery (callers carry intent per §13.4). Local-mode no-op. |
| `artifact-render.py` | Python | `artifact.json` → `artifact.md`. Uses jsonschema validation; reads disposition for section selection. |
| `artifact-validate.sh` | Bash | Thin wrapper around the Python validator. |

## Utilities

| Script | Lang | Purpose |
|---|---|---|
| `log-phase.sh` | Bash | Appends `trace.md` + `phases.jsonl`. Every phase fragment calls this. |
| `log-tokens.sh` | Bash | Appends `tokens.jsonl`. Every sub-agent dispatch. |
| `freshness-gate.sh` | Bash | Phase 0.2a base-branch freshness reconciliation. Detects remote, fetches (30s soft timeout), computes behind_count; emits JSON `{comparison_ref, base_freshness, remote_sha, behind_count, preflight_warnings[]}` with `base_freshness ∈ {fresh, fast_forwarded, used_remote_ref, proceeded_stale, no_remote, no_fetch, pending_user_gate}`. `pending_user_gate` signals the orchestrator to dispatch `AskUserQuestion` and re-invoke with `--after-choice <a|b|c>`; the helper then applies the chosen side-effect (fast-forward / used_remote_ref / proceeded_stale) and re-emits terminal JSON. Non-FF on (a) re-emits pending with `ff_available: false` so the orchestrator re-asks with only (b)/(c)/(d). |
| `codex-poll.sh` | Bash | Phase 1 / 4 / 5 codex-job liveness watchdog (codex-review only). Wraps `node "$CODEX_COMPANION" status --json` with a two-signal stall check (logFile mtime > 90s + `result --json` "No job found" desync probe) and a per-effort wall-clock ceiling. Emits one JSON verdict per call: `alive` / `stalled_suspect` (keep polling) / `broker_desynced` / `wall_clock_exceeded` / `failed_terminal` (cancel + §3.7 retry) / `completed` (with plucked `raw_output`). Single source of truth — fragments must NOT call `node "$CODEX_COMPANION" status` directly (smoke `CR-13c` enforces). Defends against the bug class where the codex-companion broker reports `running` indefinitely after the underlying turn dies (real failure 2026-05-03; see `plans/codex-watchdog.md`). |
| `tally-subagent-tokens.sh` | Bash | Rolls `tokens.jsonl` into `subagent_tokens` on the artifact. Pure readback, idempotent. Called at Phase 6 finalize and before each lifecycle command's final re-render so the published total stays cumulative across review → fix / add / walkthrough. |
| `orchestrator-tokens.sh` | Bash | Rolls Claude Code session transcripts under `~/.claude/projects/<cwd-slug>/` into `orchestrator_tokens`. Complements `tally-subagent-tokens.sh` by capturing the main-session per-turn spend that `subagent_tokens` deliberately excludes. **Opt-in via `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1`** (default skip — the transcript scan trips the macOS Sequoia/Tahoe "access data from other apps" prompt because Claude Code marks transcripts with the `com.apple.provenance` xattr; opt-out exits 0 with a `skipped` stdout line and leaves the artifact untouched, preserving any prior opted-in value). Slug algorithm is `tr '/.' '-'` (both chars map to `-`). `--since` filters by assistant-line timestamp; when opted in, v1 accepts soft over-count modes from unrelated same-cwd sessions or intermission chat between lifecycle commands. |
| `group-fixes.py` | Python | Phase 8 union-find over `files_planned` across eligible findings. Emits `[{id, finding_ids, files_planned}]`. |
| `assign-finding-ids.sh` | Bash | Phase 1 post-join. Monotonic ID assignment over the pooled candidate list. |
| `external-scrape.sh` | Bash | Phase 1.5 PR-comment fetch + bot filter (allow/deny config). |
| `_common.py` | Python | Shared: schema validate, `atomic_write`, `suggest()` (error-as-prompt), exit-code constants. Imported by every Python helper. |

## Batched-helper pattern

`artifact-patch.py` has four batched modes. Three (`--apply-decisions` /
`--apply-fix-start` / `--apply-fix-outcomes`) share a first-fail-halt scaffold;
`--add-findings` is continue-on-error.

The first three: JSON array of tuples, per-tuple atomic writes, first-failure
halt, one summary line. They also accept `--expected N` to reject under-sized
batches (exit 6 = `EXIT_EXPECTED_MISMATCH`, recoverable by re-dispatch with the
correct count). If you add a fourth like-shaped batched mode, reuse the
scaffolding (`_check_*_tuple` validator + `_load_or_fail` per tuple +
`_write_and_emit(silent=True)`). Accept that mid-batch failure leaves tuples
0..N-1 persisted; callers re-invoke with the remainder.

`--add-findings` uses a different recovery pattern: continue-on-error per
finding + one atomic write across the accepted batch. The asymmetry tracks the
underlying operation — mutating existing findings (apply-decisions /
apply-fix-*) preserves meaningful state at every successful tuple, so
first-failure-halt with re-dispatch on the remainder is the right shape;
creating new findings has no equivalent "tuples 0..N-1 are still meaningful"
property, so dropping a single bad candidate while committing the rest in one
transaction matches the upstream lens-drift recovery story (per-finding
rejections surface in `trace.md` as `add-findings-rejected:` lines for the
operator to investigate).

Future batched modes should pick the matching pattern: mutate → first-fail-halt
+ per-tuple atomic; create → continue-on-error + single atomic.
