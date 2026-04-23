#!/usr/bin/env bash
# smoke.sh — Stage 1 done-when walk-through (plan/stage-1-foundation.md §7).
#
# Exercises artifact-patch.py + artifact-render.py + every Bash helper
# against the hand-authored fixture under ./fixtures/. Each assertion
# prints `ok N: <label>` on success and `FAIL N: <label>` + the
# offending stderr on failure. Exits non-zero on first failure.
#
# Test artifacts live under /tmp/s1; trap cleans on exit unless
# SMOKE_KEEP=1 (for debugging).
#
# Usage:
#   ./test/smoke.sh                 # run from any cwd; paths are absolute
#   SMOKE_KEEP=1 ./test/smoke.sh    # keep /tmp/s1 for inspection

set -u   # intentionally no -e: we manage failures per-assertion
set -o pipefail

THIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS/.." && pwd)"
TOOLS="$REPO/bin"
FIX="$THIS/fixtures"

WORK=/tmp/s1
ART="$WORK/art.json"
MD="$WORK/art.md"

cleanup() {
    if [[ "${SMOKE_KEEP:-}" != "1" ]]; then
        rm -rf "$WORK"
    else
        echo "SMOKE_KEEP=1 → artifacts preserved under $WORK" >&2
    fi
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"

# ---------------------------------------------------------------- helpers

N=0
FAIL=0

pass() { N=$((N+1)); printf 'ok %2d: %s\n' "$N" "$1"; }
fail() {
    N=$((N+1)); FAIL=1
    printf 'FAIL %2d: %s\n' "$N" "$1" >&2
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
    echo "smoke: FAIL (assertion $N)" >&2
    exit 1
}

# run command, capture exit; return the exit code as a string
rc() { ( "$@" >/dev/null 2>&1 ); printf '%s' "$?"; }

sha_of() { shasum "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------- main 12

# 1. --init from seed
if "$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$ART" >/dev/null; then
    pass "--init from seed produces valid artifact"
else
    fail "--init from seed" "exit=$?"
fi

# 2. --add-finding F099 (below_gate; schema-valid)
F099='{"id":"F099","sources":["detection"],"source_families":["code-review"],"impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"low","actionability":"report_only","validation_lane":"deep","current_state":"open","disposition":"below_gate","is_actionable":false,"reason":null,"confirmed_strength":null,"file":"src/misc/flake.ts","line_range":[1,1],"claim":"Minor below threshold","score_phase3":30,"score_phase4":30,"score_history":[{"phase":"phase_3","score":30},{"phase":"phase_4","score":30}],"validation_result":null,"fix_attempts":[],"introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}'
if "$TOOLS/artifact-patch.py" --path "$ART" --add-finding "$F099" >/dev/null; then
    pass "--add-finding F099 succeeds"
else
    fail "--add-finding F099"
fi

# 3. standalone validate
if "$TOOLS/artifact-validate.sh" --path "$ART" >/dev/null; then
    pass "artifact-validate.sh reports valid"
else
    fail "artifact-validate.sh --path $ART"
fi

# 4. open → resolved must fail with exit 2 (invalid transition)
code=$(rc "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=resolved)
if [[ "$code" == "2" ]]; then
    pass "open→resolved rejected with exit 2"
else
    fail "open→resolved should exit 2, got $code"
fi

# 5. open → attempted succeeds
if "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=attempted >/dev/null; then
    pass "open→attempted succeeds"
else
    fail "open→attempted"
fi

# 6. attempted → resolved alone (without disposition=resolved) must fail coupling (exit 1)
code=$(rc "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=resolved)
if [[ "$code" == "1" ]]; then
    pass "attempted→resolved without disposition rejected (coupling, exit 1)"
else
    fail "attempted→resolved alone should exit 1, got $code"
fi

# 7. attempted → resolved WITH disposition=resolved in same call succeeds
if "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 \
        --set current_state=resolved --set disposition=resolved >/dev/null; then
    pass "current_state=resolved + disposition=resolved succeeds"
else
    fail "coupled resolve"
fi

# 8. --append-fix-attempt (append; not replace)
ATT='{"run_id":"fixrun_stage1smoke","timestamp":"2026-04-17T21:30:00Z","fix_group_id":"FG-1","input_sha":"abcdef0123","output_sha":"fedcba9876","phase_9_outcome":"verified"}'
if "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --append-fix-attempt "$ATT" >/dev/null; then
    # verify length == 1
    len=$(jq '.findings[] | select(.id=="F001") | .fix_attempts | length' "$ART")
    if [[ "$len" == "1" ]]; then
        pass "--append-fix-attempt appended exactly one attempt to F001"
    else
        fail "fix_attempts length should be 1, got $len"
    fi
else
    fail "--append-fix-attempt"
fi

# 9. render and diff against expected.md
if "$TOOLS/artifact-render.py" --input "$ART" --output "$MD" >/dev/null; then
    if diff -u "$FIX/expected.md" "$MD" >/dev/null; then
        pass "rendered markdown matches expected.md"
    else
        diff -u "$FIX/expected.md" "$MD" >&2 || true
        fail "rendered markdown differs from expected.md (see diff above)"
    fi
else
    fail "artifact-render.py"
fi

# 10. bad disposition value — schema violation
stderr=$("$TOOLS/artifact-patch.py" --path "$ART" --finding-id F099 --set disposition=bogus 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "schema violation"; then
    pass "bad disposition rejected with schema-violation error-as-prompt"
else
    fail "bad disposition test: exit=$code, stderr lacked 'schema violation'" "$stderr"
fi

# 11. is_actionable/disposition coupling violation
stderr=$("$TOOLS/artifact-patch.py" --path "$ART" --finding-id F099 --set is_actionable=true --set disposition=below_gate 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "is_actionable"; then
    pass "is_actionable/disposition mismatch rejected with coupling error-as-prompt"
else
    fail "coupling test: exit=$code, stderr lacked 'is_actionable'" "$stderr"
fi

# 12. --dry-run on invalid input: non-zero AND artifact on disk unchanged
SHA_BEFORE=$(sha_of "$ART")
code=$(rc "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=bogus --dry-run)
SHA_AFTER=$(sha_of "$ART")
if [[ "$code" != "0" ]] && [[ "$SHA_BEFORE" == "$SHA_AFTER" ]]; then
    pass "--dry-run on invalid exits non-zero and leaves artifact unchanged"
else
    fail "--dry-run test: exit=$code, sha_before=$SHA_BEFORE sha_after=$SHA_AFTER"
fi

# ---------------------------------------------------------------- sidecars

# A. artifact-read.sh --summary returns expected counts
expected_counts='{"findings_total":7,"by_disposition":{"below_gate":1,"confirmed_manual":1,"confirmed_mechanical":1,"pre_existing_report":1,"resolved":1,"uncertain":2}}'
actual=$("$TOOLS/artifact-read.sh" --path "$ART" --summary \
    | jq -c '{findings_total, by_disposition: .counts_by_disposition}')
if [[ "$actual" == "$expected_counts" ]]; then
    pass "A: artifact-read.sh --summary counts match"
else
    fail "A: summary counts mismatch" "expected=$expected_counts actual=$actual"
fi

# B. artifact-publish.sh local no-op
mkdir -p "$WORK/pub"
if "$TOOLS/artifact-publish.sh" --mode local --review-id rev_stage1smoke --review-dir "$WORK/pub" >/dev/null; then
    if grep -q "local mode, nothing to publish" "$WORK/pub/trace.md"; then
        pass "B: publish --mode local appends trace line and exits 0"
    else
        fail "B: publish --mode local did not write trace line"
    fi
else
    fail "B: publish --mode local exit non-zero"
fi

# B2. publish with bogus mode → 64
code=$(rc "$TOOLS/artifact-publish.sh" --mode bogus --review-id rev_x)
if [[ "$code" == "64" ]]; then
    pass "B2: publish --mode bogus rejected with exit 64"
else
    fail "B2: publish --mode bogus should exit 64, got $code"
fi

# B3. publish --mode pr with no md source → non-zero + "cannot resolve md path"
stderr=$("$TOOLS/artifact-publish.sh" --mode pr --review-id rev_x --pr 1 --dry-run 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "cannot resolve md path"; then
    pass "B3: publish --mode pr with no md source rejected with resolution error"
else
    fail "B3: expected non-zero + 'cannot resolve md path', got code=$code stderr=$stderr"
fi

# B4. publish --mode pr --dry-run with latest.txt resolves + prints path
FAKE_ROOT="$WORK/reviews"
mkdir -p "$FAKE_ROOT/fake-slug/fake-branch/rev_fake"
echo "rev_fake" > "$FAKE_ROOT/fake-slug/fake-branch/latest.txt"
echo "# rendered" > "$FAKE_ROOT/fake-slug/fake-branch/rev_fake/artifact.md"
out=$(ADAMS_REVIEW_REVIEWS_ROOT="$FAKE_ROOT" "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_fake --pr 1 \
        --repo-slug fake-slug --branch fake-branch --dry-run 2>&1); code=$?
expected_path="$FAKE_ROOT/fake-slug/fake-branch/rev_fake/artifact.md"
if [[ "$code" == "0" ]] && [[ "$out" == "$expected_path" ]]; then
    pass "B4: publish --dry-run resolves latest.txt → $expected_path"
else
    fail "B4: dry-run resolution mismatch" "code=$code out=$out expected=$expected_path"
fi

# B5. publish --mode pr with latest.txt disagreeing with --review-id → non-zero + staleness note
stderr=$(ADAMS_REVIEW_REVIEWS_ROOT="$FAKE_ROOT" "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_stale --pr 1 \
        --repo-slug fake-slug --branch fake-branch --dry-run 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "latest.txt points to review_id='rev_fake'"; then
    pass "B5: publish rejects --review-id mismatch against latest.txt"
else
    fail "B5: expected staleness error, got code=$code stderr=$stderr"
fi

# B6. publish default root (no ADAMS_REVIEW_REVIEWS_ROOT override) → ~/.adams-reviews.
# Stage 2.5.A relocated the default root outside ~/.claude/ so that Claude Code's
# hardcoded sensitive-file gate for ~/.claude/... paths doesn't fire. Assert the
# new default by triggering a latest.txt-not-found error against a slug guaranteed
# not to exist under the real home dir; the error message names the resolved path
# so we can grep for ~/.adams-reviews without polluting actual state.
ghost_slug="adams-review-smoke-missing-$$-$(date +%s)"
stderr=$(env -u ADAMS_REVIEW_REVIEWS_ROOT "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_ghost --pr 1 \
        --repo-slug "$ghost_slug" --branch ghost-branch --dry-run 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "\.adams-reviews/$ghost_slug/ghost-branch/latest.txt"; then
    pass "B6: publish default reviews root resolves under ~/.adams-reviews (Stage 2.5.A)"
else
    fail "B6: expected error naming ~/.adams-reviews/$ghost_slug/ghost-branch/latest.txt; code=$code stderr=$stderr"
fi

# OC. Fresh-run-won't-overwrite (DESIGN §13.4, rev 7).
# The publisher no longer auto-discovers a prior comment by marker. Each
# command carries its own continuation intent: fresh /adamsreview:review
# omits --comment-id (→ POST); /adamsreview:fix and /adamsreview:promote
# pass --comment-id read from the artifact (→ PATCH).

# OC-1: find_by_marker function is gone from the publisher.
if grep -q 'find_by_marker' "$TOOLS/artifact-publish.sh"; then
    fail "OC-1: artifact-publish.sh still references find_by_marker"
else
    pass "OC-1: artifact-publish.sh no longer contains find_by_marker"
fi

# OC-2: gh_current_user helper is gone (tier-2 was its only caller).
if grep -q 'gh_current_user' "$TOOLS/artifact-publish.sh"; then
    fail "OC-2: artifact-publish.sh still references gh_current_user"
else
    pass "OC-2: artifact-publish.sh no longer resolves current gh user"
fi

# OC-3: help text no longer lists 'marker search' as an active
# discovery step. The header's negative reference ("never auto-discovers
# ... via marker search") is fine — it's documentation of what the
# publisher deliberately doesn't do. Scope the check to the usage block.
usage_txt=$("$TOOLS/artifact-publish.sh" --help 2>&1)
if echo "$usage_txt" | grep -qi 'marker search'; then
    fail "OC-3: --help usage still documents 'marker search' tier"
else
    pass "OC-3: --help usage documents two-tier discovery only"
fi

# OC-4: --comment-id path still present (tier 1 intact).
if grep -q '\-\-comment-id' "$TOOLS/artifact-publish.sh" \
   && grep -q 'patch_comment "$COMMENT_ID"' "$TOOLS/artifact-publish.sh"; then
    pass "OC-4: artifact-publish.sh --comment-id → PATCH path preserved"
else
    fail "OC-4: --comment-id PATCH path missing"
fi

# OC-5: publisher still lints clean after the removal.
if bash -n "$TOOLS/artifact-publish.sh" 2>/dev/null; then
    pass "OC-5: artifact-publish.sh is syntactically valid after tier-2 removal"
else
    fail "OC-5: artifact-publish.sh has syntax errors"
fi

# OC-6: DESIGN §13.4 documents the new rule (fresh /adamsreview:review POSTs).
# Path repointed to docs/archive/ after the 2026-04-19 docs-consolidation move.
if grep -q 'always .POST. a new comment' "$REPO/docs/archive/DESIGN.md"; then
    pass "OC-6: DESIGN §13.4 documents fresh-/adamsreview:review-POSTs rule"
else
    fail "OC-6: DESIGN §13.4 missing new POST-on-fresh-review rule"
fi

# C. claude-md-paths synthetic tree: root + a/CLAUDE.md expected, root-first
mkdir -p "$WORK/cm/a/b" "$WORK/cm/a/c"
touch "$WORK/cm/CLAUDE.md" "$WORK/cm/a/CLAUDE.md" "$WORK/cm/a/b/file.ts" "$WORK/cm/a/c/file.ts"
actual=$("$TOOLS/claude-md-paths.sh" --repo-root "$WORK/cm" --files "a/b/file.ts,a/c/file.ts")
# realpath via `cd && pwd -P` — match the script's resolved form
resolved_root=$(cd "$WORK/cm" && pwd -P)
expected_cm="$resolved_root/CLAUDE.md
$resolved_root/a/CLAUDE.md"
if [[ "$actual" == "$expected_cm" ]]; then
    pass "C: claude-md-paths.sh deduped and root-first sorted"
else
    fail "C: claude-md-paths output mismatch" "expected=$expected_cm | actual=$actual"
fi

# D. staleness: safe / warn / unsafe on throwaway repo
mkdir -p "$WORK/repo"
(
    cd "$WORK/repo"
    git init -q -b main
    git config user.email smoke@example.com
    git config user.name smoke
    echo one > foo.txt
    echo one > bar.txt
    git add . && git commit -q -m c1
    SHA1=$(git rev-parse HEAD)
    # safe
    [[ "$("$TOOLS/staleness.sh" --reviewed-sha "$SHA1" --reviewed-files foo.txt,bar.txt)" == "safe" ]] || exit 10
    # warn
    echo two > bar.txt && git commit -q -am c2
    out=$("$TOOLS/staleness.sh" --reviewed-sha "$SHA1" --reviewed-files foo.txt) || exit 11
    [[ "$out" == warn:* ]] || exit 12
    # unsafe
    echo two > foo.txt && git commit -q -am c3
    err=$("$TOOLS/staleness.sh" --reviewed-sha "$SHA1" --reviewed-files foo.txt 2>&1); code=$?
    [[ "$code" != "0" ]] || exit 13
    [[ "$err" == unsafe:* ]] || exit 14
)
subrc=$?
if [[ "$subrc" == "0" ]]; then
    pass "D: staleness safe / warn / unsafe all classified correctly"
else
    fail "D: staleness subtest failure code=$subrc"
fi

# E. log-phase.sh --record + log-tokens.sh produce valid JSONL
# Covers both numeric and string-bucket phase values (e.g. "1_5" for
# Phase 1.5 per §11 conventions).
mkdir -p "$WORK/rev"
"$TOOLS/log-phase.sh" --review-dir "$WORK/rev" --phase 6 --name detection --summary "smoke" --elapsed 5
"$TOOLS/log-phase.sh" --review-dir "$WORK/rev" --phase 6 --record '{"name":"detection","elapsed_sec":5}'
"$TOOLS/log-phase.sh" --review-dir "$WORK/rev" --phase 1_5 --record '{"name":"ensemble-adapter","elapsed_sec":7}'
"$TOOLS/log-tokens.sh" --review-dir "$WORK/rev" --phase phase_3 --agent-role validator --agent-id ag_abc --model opus --tokens 12345 --finding-id F001
# Verify both records landed; the 1_5 entry should keep phase as the
# literal string.
phase_1_5_phase=$(jq -r 'select(.name == "ensemble-adapter") | .phase' "$WORK/rev/phases.jsonl" | head -1)
phase_6_phase=$(jq -r 'select(.name == "detection") | .phase' "$WORK/rev/phases.jsonl" | head -1)
if jq -e . "$WORK/rev/phases.jsonl" >/dev/null \
        && jq -e . "$WORK/rev/tokens.jsonl" >/dev/null \
        && grep -q "## Phase 6 — detection" "$WORK/rev/trace.md" \
        && [[ "$phase_1_5_phase" == "1_5" ]] \
        && [[ "$phase_6_phase" == "6" ]]; then
    pass "E: log-phase accepts numeric + string phases; tokens/phases JSONL valid"
else
    fail "E: phase_1_5=$phase_1_5_phase phase_6=$phase_6_phase; check $WORK/rev/phases.jsonl"
fi

# E2. Phase 3 telemetry payload shape (#24 calibration): demote_rate float
# and score_phase3_histogram (10 buckets) land in phases.jsonl via --record
# pass-through. Sanity-check that log-phase.sh carries arbitrary JSON
# payloads through unchanged, so the fragments/04-scoring-gate.md wiring
# doesn't need a bespoke helper.
p3_record=$(jq -nc \
    --argjson hist '{"0-9":1,"10-19":2,"20-29":3,"30-39":2,"40-49":4,"50-59":3,"60-69":5,"70-79":4,"80-89":2,"90-100":1}' \
    '{name:"scoring-gate", elapsed_sec:42, demote_rate:0.6486486486486487, score_phase3_histogram:$hist}')
"$TOOLS/log-phase.sh" --review-dir "$WORK/rev" --phase 3 --record "$p3_record"
p3_demote=$(jq -r 'select(.name == "scoring-gate" and .phase == 3) | .demote_rate' "$WORK/rev/phases.jsonl" | head -1)
p3_hist_keys=$(jq -r 'select(.name == "scoring-gate" and .phase == 3) | .score_phase3_histogram | keys | length' "$WORK/rev/phases.jsonl" | head -1)
p3_bucket_90_100=$(jq -r 'select(.name == "scoring-gate" and .phase == 3) | .score_phase3_histogram["90-100"]' "$WORK/rev/phases.jsonl" | head -1)
if [[ "$p3_demote" == "0.6486486486486487" ]] \
        && [[ "$p3_hist_keys" == "10" ]] \
        && [[ "$p3_bucket_90_100" == "1" ]]; then
    pass "E2: Phase 3 phases.jsonl record carries demote_rate + score_phase3_histogram (#24 telemetry)"
else
    fail "E2: phase 3 telemetry shape wrong — demote_rate=$p3_demote hist_keys=$p3_hist_keys bucket_90_100=$p3_bucket_90_100"
fi

# F. Schema-invalid fixture rejected by artifact-validate.sh
stderr=$("$TOOLS/artifact-validate.sh" --path "$FIX/invalid/bad-disposition.json" 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "bogus_disposition"; then
    pass "F: artifact-validate.sh rejects bad-disposition fixture with readable error"
else
    fail "F: validator should reject bad-disposition fixture" "exit=$code stderr=$stderr"
fi

# H. --delete-finding removes the finding
# (Make a disposable copy so we don't disturb the main $ART.)
cp "$ART" "$WORK/art-del.json"
before_count=$(jq '.findings | length' "$WORK/art-del.json")
if "$TOOLS/artifact-patch.py" --path "$WORK/art-del.json" --delete-finding F099 >/dev/null; then
    after_count=$(jq '.findings | length' "$WORK/art-del.json")
    if [[ "$after_count" == "$((before_count - 1))" ]] && \
       ! jq -e '.findings[] | select(.id == "F099")' "$WORK/art-del.json" >/dev/null 2>&1; then
        pass "H: --delete-finding F099 removes the finding"
    else
        fail "H: count before=$before_count after=$after_count; F099 still present?"
    fi
else
    fail "H: --delete-finding F099 exit non-zero"
fi

# I. --delete-finding on unknown id → non-zero with did-you-mean
stderr=$("$TOOLS/artifact-patch.py" --path "$ART" --delete-finding F999 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "no finding with id"; then
    pass "I: --delete-finding on unknown id rejected with error-as-prompt"
else
    fail "I: expected error for unknown id; got code=$code stderr=$stderr"
fi

# J. --set-json writes an array field (sources)
cp "$ART" "$WORK/art-sj.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-sj.json" --finding-id F001 \
        --set-json "sources=[\"detection\",\"codex\"]" >/dev/null; then
    actual=$(jq -c '.findings[] | select(.id=="F001") | .sources' "$WORK/art-sj.json")
    if [[ "$actual" == '["detection","codex"]' ]]; then
        pass "J: --set-json sources=<array> writes correctly"
    else
        fail "J: sources after --set-json = $actual"
    fi
else
    fail "J: --set-json exit non-zero"
fi

# K. --set-json with @file reads from disk
echo '["external-pr:greptile-apps[bot]"]' > "$WORK/sj.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-sj.json" --finding-id F001 \
        --set-json "sources=@$WORK/sj.json" >/dev/null; then
    actual=$(jq -c '.findings[] | select(.id=="F001") | .sources' "$WORK/art-sj.json")
    if [[ "$actual" == '["external-pr:greptile-apps[bot]"]' ]]; then
        pass "K: --set-json @file reads JSON from disk"
    else
        fail "K: expected greptile source, got $actual"
    fi
else
    fail "K: --set-json @file exit non-zero"
fi

# L. --set-json on non-whitelisted field rejects
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/art-sj.json" --finding-id F001 \
        --set-json 'fix_attempts=[]' 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "cannot touch"; then
    pass "L: --set-json rejects fix_attempts (append-only via --append-fix-attempt)"
else
    fail "L: expected rejection; got code=$code stderr=$stderr"
fi

# M. --set-json --top-level (no --finding-id) writes artifact-level JSON field
# Schema requires CCG id ^G[0-9]+$ and finding_ids length >= 2.
if "$TOOLS/artifact-patch.py" --path "$WORK/art-sj.json" \
        --set-json "cross_cutting_groups=[{\"id\":\"G1\",\"finding_ids\":[\"F001\",\"F002\"],\"combined_approach\":\"x\"}]" >/dev/null; then
    actual=$(jq -c '.cross_cutting_groups | length' "$WORK/art-sj.json")
    if [[ "$actual" == "1" ]]; then
        pass "M: --set-json writes top-level cross_cutting_groups"
    else
        fail "M: cross_cutting_groups length = $actual"
    fi
else
    fail "M: --set-json top-level exit non-zero"
fi

# G. external-scrape.sh fixture-replay: bot filter + deny list (no time window —
# see Stage 2.8: --since removed because code locality, not newness, is
# the right relevance axis. Both coderabbit bot comments now survive; the
# "too old" case is kept because age no longer matters at this layer).
EXT="$WORK/ext"
mkdir -p "$EXT"
cat > "$EXT/issue_comments.json" <<'JSON'
[
  {"id":1,"user":{"login":"humanuser","type":"User"},"created_at":"2026-02-01T00:00:00Z","body":"human comment"},
  {"id":2,"user":{"login":"coderabbit-ai[bot]","type":"Bot"},"created_at":"2026-02-01T00:00:00Z","body":"bot finding"},
  {"id":3,"user":{"login":"dependabot[bot]","type":"Bot"},"created_at":"2026-02-01T00:00:00Z","body":"dep bump"},
  {"id":5,"user":{"login":"coderabbit-ai[bot]","type":"Bot"},"created_at":"2025-01-01T00:00:00Z","body":"age no longer filtered"}
]
JSON
echo '[]' > "$EXT/reviews.json"
echo '[]' > "$EXT/review_comments.json"
# Default config (no --config) — DEFAULT_DENY applies, allow=null.
out=$(ADAMS_REVIEW_FIXTURES_USER=smokeuser "$TOOLS/external-scrape.sh" \
        --fixtures-dir "$EXT")
ids=$(echo "$out" | jq -c '[.[].id] | sort')
if [[ "$ids" == "[2,5]" ]]; then
    pass "G: external-scrape fixture replay keeps both coderabbit records, drops human + dep-bump"
else
    fail "G: expected ids [2,5], got $ids" "out=$out"
fi

# N. pending_validation is a valid disposition enum (R2 fix)
cp "$ART" "$WORK/art-pv.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-pv.json" --finding-id F099 \
        --set disposition=pending_validation --set is_actionable=false >/dev/null 2>&1; then
    actual=$(jq -r '.findings[] | select(.id=="F099") | .disposition' "$WORK/art-pv.json")
    if [[ "$actual" == "pending_validation" ]]; then
        pass "N: pending_validation accepted as disposition (R2 parking state)"
    else
        fail "N: disposition after set = $actual"
    fi
else
    fail "N: --set disposition=pending_validation exit non-zero"
fi

# O. artifact-read.sh --summary emits counts_by_state (R6 rename)
if "$TOOLS/artifact-read.sh" --path "$ART" --summary | jq -e '.counts_by_state' >/dev/null; then
    # Also confirm the deprecated key is gone
    if "$TOOLS/artifact-read.sh" --path "$ART" --summary | jq -e '.counts_by_current_state' >/dev/null 2>&1; then
        fail "O: counts_by_current_state still present; rename incomplete"
    else
        pass "O: --summary emits counts_by_state (DESIGN §12.1 naming)"
    fi
else
    fail "O: --summary does not emit counts_by_state"
fi

# P. empty-string list → [] via jq -Rn inputs|select(length>0) (R4 fix pattern)
# (Exercises the exact jq expression used in 00-preflight.md:306-307.)
empty_out=$(printf '%s' "" | jq -Rn '[inputs | select(length>0)]')
if [[ "$empty_out" == "[]" ]]; then
    pass "P: jq -Rn 'inputs|select(length>0)' returns [] on empty input (R4)"
else
    fail "P: expected [] got $empty_out"
fi

# Q. --set disposition=pending_validation + is_actionable=true → coupling reject
# (pending_validation is not in ACTIONABLE_DISPOSITIONS.)
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/art-pv.json" --finding-id F099 \
        --set disposition=pending_validation --set is_actionable=true 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "is_actionable"; then
    pass "Q: pending_validation + is_actionable=true rejected (coupling invariant)"
else
    fail "Q: expected coupling error; got code=$code stderr=$stderr"
fi

# R. pending_validation → confirmed_mechanical Phase-4 transition works (R2 flow)
# F099 starts at below_gate; move through pending_validation → confirmed_mechanical
# (with is_actionable=true, confirmed_strength) simulating Phase 3→4.
cp "$ART" "$WORK/art-p34.json"
"$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" --finding-id F099 \
    --set disposition=pending_validation --set is_actionable=false >/dev/null
if "$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" --finding-id F099 \
        --set disposition=confirmed_mechanical \
        --set is_actionable=true \
        --set confirmed_strength=strong \
        --set "score_phase4=85" >/dev/null; then
    disp=$(jq -r '.findings[] | select(.id=="F099") | .disposition' "$WORK/art-p34.json")
    if [[ "$disp" == "confirmed_mechanical" ]]; then
        pass "R: pending_validation → confirmed_mechanical Phase-4 transition succeeds"
    else
        fail "R: final disposition = $disp"
    fi
else
    fail "R: Phase-4 transition exit non-zero"
fi

# S. Schema-valid validation_result via --set-json @file (R3 write path)
VR=$(cat <<'JSON'
{
  "evidence": ["src/foo.ts:42 — null deref"],
  "blast_radius": {
    "writers": ["src/foo.ts:40"],
    "consumers": ["src/bar.ts:88"],
    "parallel_paths": [],
    "invariants_at_stake": ["user_id is non-null"]
  },
  "fix_proposal": {
    "approach": "Add null-check + fallback path",
    "files_to_modify": [
      {"file":"src/foo.ts","what":"guard null","why":"prevents NPE"}
    ]
  },
  "verification_context": {
    "how_to_verify_fix": ["grep 'user_id' src/"],
    "edge_cases_to_preserve": ["empty string"],
    "what_would_break_if_incomplete": ["API returns 500 on unauth"]
  }
}
JSON
)
echo "$VR" > "$WORK/vr.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" --finding-id F099 \
        --set-json "validation_result=@$WORK/vr.json" >/dev/null; then
    actual=$(jq -r '.findings[] | select(.id=="F099") | .validation_result.fix_proposal.approach' "$WORK/art-p34.json")
    if [[ "$actual" == "Add null-check + fallback path" ]]; then
        pass "S: --set-json validation_result=@file writes schema-valid object (R3)"
    else
        fail "S: fix_proposal.approach readback = $actual"
    fi
else
    fail "S: --set-json validation_result @file exit non-zero"
fi

# T. --set-json reviewer_sources=@file at top level (Phase 6.3a recompute path)
echo '["internal","codex"]' > "$WORK/rs.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" \
        --set-json "reviewer_sources=@$WORK/rs.json" >/dev/null; then
    actual=$(jq -c '.reviewer_sources' "$WORK/art-p34.json")
    if [[ "$actual" == '["internal","codex"]' ]]; then
        pass "T: --set-json reviewer_sources at top-level (Phase 6.3a path)"
    else
        fail "T: reviewer_sources readback = $actual"
    fi
else
    fail "T: --set-json reviewer_sources exit non-zero"
fi

# U. reviewer_sources Phase-6.3a regex correctly classifies lens tags.
# Simulates the jq expression in 07-finalize.md step 6.3a against a
# synthetic sources[] union.
U_OUT=$(echo '["L1-diff-local","L3-claude-md","L7-holistic","codex","external-pr:greptile-apps[bot]","random-tag"]' \
    | jq -c 'map(
        if test("^L[0-9]+-") then "internal"
        elif . == "codex" or . == "coderabbit" then .
        elif startswith("external-pr:") then .
        else empty end
      ) | unique')
if [[ "$U_OUT" == '["codex","external-pr:greptile-apps[bot]","internal"]' ]]; then
    pass "U: reviewer_sources regex classifies L1..L7 lens tags, codex, external-pr: correctly"
else
    fail "U: reviewer_sources output = $U_OUT"
fi

# Ubis. Strict L7-only variant — guards the post-Stage-2.9 forward-
# compat regex specifically. With the old buggy regex ^L[1-6]- and only
# L7 tags in sources[], the union would collapse to [] (L7 classified as
# `empty`, dropped). With the fixed ^L[0-9]+-, the union is ["internal"].
# U alone doesn't distinguish the two regexes when L1..L6 are also present
# — this test does.
U_OUT_STRICT=$(echo '["L7-holistic"]' \
    | jq -c 'map(
        if test("^L[0-9]+-") then "internal"
        elif . == "codex" or . == "coderabbit" then .
        elif startswith("external-pr:") then .
        else empty end
      ) | unique')
if [[ "$U_OUT_STRICT" == '["internal"]' ]]; then
    pass "Ubis: L7-holistic alone classifies as 'internal' (forward-compat regex guard)"
else
    fail "Ubis: expected [\"internal\"]; got $U_OUT_STRICT"
fi

# Vbis. review_id fallback format matches ^rev_[A-Za-z0-9]+$.
# Regression test for real-repo round-5 red: the 0.15 fallback used
# `rev_${date}_${random}` with an underscore separator; the regex
# rejects underscores after the `rev_` prefix.
fallback_id="rev_$(date -u +%Y%m%dT%H%M%SZ)$(openssl rand -hex 3)"
if [[ "$fallback_id" =~ ^rev_[A-Za-z0-9]+$ ]]; then
    pass "Vbis: review_id fallback '$fallback_id' matches schema regex"
else
    fail "Vbis: fallback id '$fallback_id' does not match ^rev_[A-Za-z0-9]+$"
fi

# V. pr_state=OPEN (uppercase from gh) would fail schema — the 00-preflight
# transform at step 0.4 must lowercase it. This asserts the schema rejects
# uppercase directly, so the transform has something to protect.
BAD_SEED=$(jq '.pr_state = "OPEN"' "$FIX/artifact-seed.json")
stderr=$("$TOOLS/artifact-patch.py" --init "$BAD_SEED" --path "$WORK/art-badstate.json" 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "pr_state"; then
    pass "V: schema rejects pr_state='OPEN' (uppercase — protects 00-preflight transform)"
else
    fail "V: schema should reject uppercase pr_state; code=$code stderr=$stderr"
fi

# W. --apply-decisions: mixed batch routes via §13.1 and writes validation_result
# only for the confirmed band (Stage 2.5.B). Build a seed with 3 findings in
# pending_validation, run one --apply-decisions call with a confirmed_mechanical +
# uncertain + disproven tuple set, and check each finding's post-state.
APPLY_DIR="$WORK/apply-decisions"
mkdir -p "$APPLY_DIR"

PV_SEED=$(jq '.review_id = "rev_applydecisions" | .findings = [
  {"id":"F101","sources":["L1-diff-local"],"source_families":["structural-family"],
   "impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"high",
   "actionability":"auto_fixable","validation_lane":"deep",
   "current_state":"open","disposition":"pending_validation","is_actionable":false,
   "reason":null,"confirmed_strength":null,
   "file":"src/a.ts","line_range":[10,20],"claim":"confirmed-band candidate",
   "score_phase3":55,"score_phase4":null,
   "score_history":[{"phase":"phase_3","score":55}],
   "validation_result":null,"fix_attempts":[],
   "introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null},
  {"id":"F102","sources":["L2-structural"],"source_families":["structural-family"],
   "impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"medium",
   "actionability":"auto_fixable","validation_lane":"deep",
   "current_state":"open","disposition":"pending_validation","is_actionable":false,
   "reason":null,"confirmed_strength":null,
   "file":"src/b.ts","line_range":[30,40],"claim":"uncertain-band candidate",
   "score_phase3":50,"score_phase4":null,
   "score_history":[{"phase":"phase_3","score":50}],
   "validation_result":null,"fix_attempts":[],
   "introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null},
  {"id":"F103","sources":["L3-claude-md"],"source_families":["code-review"],
   "impact_type":"policy","origin":"introduced_by_pr","origin_confidence":"low",
   "actionability":"manual","validation_lane":"light",
   "current_state":"open","disposition":"pending_validation","is_actionable":false,
   "reason":null,"confirmed_strength":null,
   "file":"src/c.ts","line_range":[1,5],"claim":"disproven-band candidate",
   "score_phase3":45,"score_phase4":null,
   "score_history":[{"phase":"phase_3","score":45}],
   "validation_result":null,"fix_attempts":[],
   "introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}
]' "$FIX/artifact-seed.json")

"$TOOLS/artifact-patch.py" --init "$PV_SEED" --path "$APPLY_DIR/art.json" >/dev/null

VR_JSON='{
  "evidence":["src/a.ts:12 calls .user.id without null check"],
  "blast_radius":{"writers":["src/a.ts:12"],"consumers":["src/b.ts:40"],
                  "parallel_paths":[],"invariants_at_stake":["user non-null after login"]},
  "fix_proposal":{"approach":"guard before deref",
    "files_to_modify":[{"file":"src/a.ts","what":"add null check","why":"prevents crash"}]},
  "verification_context":{"how_to_verify_fix":["run unit tests"],
                          "edge_cases_to_preserve":["guest auth flow"],
                          "what_would_break_if_incomplete":["crash on cold cache"]}
}'

BATCH=$(jq -n --argjson vr "$VR_JSON" '[
  {id:"F101",score_phase4:80,decision:"confirmed",actionability:"auto_fixable",validation_result:$vr},
  {id:"F102",score_phase4:50,decision:"uncertain",actionability:null},
  {id:"F103",score_phase4:30,decision:"disproven",actionability:null,reason:"Phase 4: not reproducible"}
]')

out=$("$TOOLS/artifact-patch.py" --apply-decisions "$BATCH" --path "$APPLY_DIR/art.json" 2>&1); code=$?

F101_DISP=$(jq -r '.findings[] | select(.id=="F101") | .disposition' "$APPLY_DIR/art.json")
F101_IA=$(jq -r '.findings[] | select(.id=="F101") | .is_actionable' "$APPLY_DIR/art.json")
F101_CS=$(jq -r '.findings[] | select(.id=="F101") | .confirmed_strength' "$APPLY_DIR/art.json")
F101_VR=$(jq -r '.findings[] | select(.id=="F101") | if .validation_result == null then "null" else "object" end' "$APPLY_DIR/art.json")
F102_DISP=$(jq -r '.findings[] | select(.id=="F102") | .disposition' "$APPLY_DIR/art.json")
F102_VR=$(jq -r '.findings[] | select(.id=="F102") | .validation_result' "$APPLY_DIR/art.json")
F103_DISP=$(jq -r '.findings[] | select(.id=="F103") | .disposition' "$APPLY_DIR/art.json")
F103_VR=$(jq -r '.findings[] | select(.id=="F103") | .validation_result' "$APPLY_DIR/art.json")
F103_REASON=$(jq -r '.findings[] | select(.id=="F103") | .reason' "$APPLY_DIR/art.json")

if [[ "$code" == "0" ]] \
    && [[ "$F101_DISP" == "confirmed_mechanical" && "$F101_IA" == "true" && "$F101_CS" == "strong" && "$F101_VR" == "object" ]] \
    && [[ "$F102_DISP" == "uncertain" && "$F102_VR" == "null" ]] \
    && [[ "$F103_DISP" == "disproven" && "$F103_VR" == "null" && "$F103_REASON" == "Phase 4: not reproducible" ]] \
    && echo "$out" | grep -q "applied 3 decisions"; then
    pass "W: --apply-decisions batch routes per §13.1; validation_result only for confirmed band (Stage 2.5.B)"
else
    fail "W: apply-decisions state mismatch" "code=$code F101=($F101_DISP,$F101_IA,$F101_CS,$F101_VR) F102=($F102_DISP,$F102_VR) F103=($F103_DISP,$F103_VR,$F103_REASON) out=$out"
fi

# Y. Light-lane uncertain findings render in both summary and table (Stage 2.5.D).
# Regression guard for a real data-loss bug: artifact-render.py's light-lane
# iteration tuples omitted "uncertain" — C13 on ray-finance had 3 light-lane
# uncertain findings (F021/F022/F032) present in artifact.json but silently
# missing from the rendered PR comment. Fixture seed now includes F006 as a
# light-lane uncertain finding; this assertion is belt-and-suspenders next to
# the existing expected.md byte-diff (step 9) so a future tuple-literal drop
# surfaces with a clear "light uncertain dropped" signal rather than a generic
# rendering diff.
if grep -q "^| F006 | 48 | architecture |" "$MD" \
    && grep -q "1 auto-fixable, 1 uncertain" "$MD"; then
    pass "Y: Light-lane uncertain finding renders in table + summary (Stage 2.5.D)"
else
    fail "Y: expected F006 row + '1 auto-fixable, 1 uncertain' in $MD" "$(cat "$MD")"
fi

# X. --apply-decisions rejects a confirmed-band tuple that omits actionability.
# Error-as-prompt names the failing tuple id so the caller can re-invoke with
# the remainder. Reset state first: re-init so the earlier W writes don't
# color this assertion's "nothing changed" guarantee.
"$TOOLS/artifact-patch.py" --init "$PV_SEED" --path "$APPLY_DIR/art.json" >/dev/null
BEFORE_SHA=$(sha_of "$APPLY_DIR/art.json")
BAD_BATCH='[{"id":"F101","score_phase4":70}]'
stderr=$("$TOOLS/artifact-patch.py" --apply-decisions "$BAD_BATCH" --path "$APPLY_DIR/art.json" 2>&1 >/dev/null); code=$?
AFTER_SHA=$(sha_of "$APPLY_DIR/art.json")
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "F101" \
    && echo "$stderr" | grep -q "actionability" \
    && [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    pass "X: --apply-decisions rejects confirmed-band tuple without actionability; leaves artifact unchanged"
else
    fail "X: expected EXIT_VALIDATION + stderr naming F101+actionability + unchanged file; code=$code sha_eq=$([[ "$BEFORE_SHA" == "$AFTER_SHA" ]] && echo Y || echo N) stderr=$stderr"
fi

# ------------------------------------------------------------------ Stage 2.6.A
# Base-branch freshness gate (§13.10). Exercises the non-interactive pieces of
# 00-preflight.md step 0.2a against scratch git repos — the AskUserQuestion
# branching is orchestrator-level and untestable in Bash, but the fetch +
# behind-count math + per-option ref resolution + offline fallback are pure
# git plumbing and are covered here.

FRESH_DIR="$WORK/freshness"
mkdir -p "$FRESH_DIR"

# Build a bare "remote" repo + a local clone that's one commit behind.
ORIGIN_BARE="$FRESH_DIR/origin.git"
LOCAL="$FRESH_DIR/local"

git init --bare --initial-branch=main "$ORIGIN_BARE" >/dev/null 2>&1 || \
    git init --bare "$ORIGIN_BARE" >/dev/null 2>&1

# Seed the remote via a throwaway clone.
SEED="$FRESH_DIR/seed"
git clone "$ORIGIN_BARE" "$SEED" >/dev/null 2>&1
(
    cd "$SEED"
    git checkout -b main >/dev/null 2>&1 || git checkout main >/dev/null 2>&1
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    echo "v1" > README.md
    git add README.md
    git commit -q -m "initial"
    git push -q -u origin main
)

# Clone locally — local main == origin main at this point.
git clone "$ORIGIN_BARE" "$LOCAL" >/dev/null 2>&1
(
    cd "$LOCAL"
    git config user.email "smoke@example.com"
    git config user.name "smoke"
)

# Advance origin main by one commit (local is now 1 behind).
(
    cd "$SEED"
    echo "v2" >> README.md
    git commit -q -am "upstream advance"
    git push -q origin main
)

# Fetch so origin/main is visible locally (step 0.2a step 2 equivalent).
(
    cd "$LOCAL"
    git fetch origin main --quiet
)

# Create feat/smoke based on origin/main — this is the realistic post-
# rebase/merge state: the feature has the upstream commit already integrated,
# but *local* main is still at v1 (stale). Reviewing against stale local main
# would inflate the diff by including the upstream commit; reviewing against
# origin/main correctly sees only the feature commit.
(
    cd "$LOCAL"
    git checkout -q -b feat/smoke origin/main
    echo "feature" > feature.txt
    git add feature.txt
    git commit -q -m "feature change"
)

# Assertion FR-1: behind_count computed correctly.
behind_count=$(cd "$LOCAL" && git rev-list --count main..origin/main)
if [[ "$behind_count" == "1" ]]; then
    pass "FR-1 (§13.10): behind_count correctly reports local main 1 commit behind origin/main"
else
    fail "FR-1: expected behind_count=1, got $behind_count"
fi

# Assertion FR-2: option (b) used_remote_ref — comparison against origin/main
# sees ONLY the feature commit (the correct, post-§13.10 behavior).
count_via_remote=$(cd "$LOCAL" && git rev-list --count "origin/main..HEAD")
if [[ "$count_via_remote" == "1" ]]; then
    pass "FR-2 (§13.10): option (b) comparison_ref=origin/main sees 1 commit (feature only) — correct diff surface"
else
    fail "FR-2: expected 1 commit via origin/main..HEAD, got $count_via_remote"
fi

# Assertion FR-3: option (c) proceeded_stale — comparison against stale local
# main sees BOTH the feature commit AND the upstream commit. This is the
# inflated diff the freshness gate exists to defend against. Documenting the
# pre-§13.10 bug class as a positive assertion.
count_via_local=$(cd "$LOCAL" && git rev-list --count "main..HEAD")
if [[ "$count_via_local" == "2" ]]; then
    pass "FR-3 (§13.10): option (c) comparison_ref=main sees 2 commits (feature + inflated upstream) — reproduces pre-gate data loss"
else
    fail "FR-3: expected 2 commits via main..HEAD (inflated), got $count_via_local"
fi

# Assertion FR-4: option (a) fast-forward via `git fetch origin main:main` —
# refuses non-FF. On this scratch repo local main is strictly behind origin,
# so FF succeeds and behind_count drops to 0.
(
    cd "$LOCAL"
    # Must run from a checkout that is NOT main (currently feat/smoke). Git
    # refuses to update a checked-out branch via this form.
    git fetch origin main:main --quiet
)
ff_behind=$(cd "$LOCAL" && git rev-list --count main..origin/main)
if [[ "$ff_behind" == "0" ]]; then
    pass "FR-4 (§13.10): option (a) 'git fetch origin main:main' fast-forwards local main (behind_count now 0)"
else
    fail "FR-4: expected behind_count=0 post-FF, got $ff_behind"
fi

# Assertion FR-5: schema accepts base_context with each freshness enum value.
# One synthetic artifact per freshness variant, validate each via artifact-validate.
FR5_PASS=1
for freshness in fresh fast_forwarded used_remote_ref proceeded_stale no_fetch no_remote; do
    case "$freshness" in
        no_fetch|no_remote) remote_sha=null; behind=null ;;
        *) remote_sha='"abc1234"'; behind=0 ;;
    esac
    # proceeded_stale / used_remote_ref / fast_forwarded can also have null
    # behind, but the non-null form is the common one so we test that.
    if [[ "$freshness" == "fresh" ]]; then
        behind=0
    fi
    SEED_JSON=$(jq --arg f "$freshness" \
                  --argjson rs "$remote_sha" \
                  --argjson bc "$behind" \
                  '.base_context = {freshness: $f, comparison_ref: "main", remote_sha: $rs, behind_count: $bc}' \
                  "$FIX/artifact-seed.json" | jq --arg f "$freshness" '.review_id = ("rev_" + ($f | gsub("_"; "")))')
    if ! "$TOOLS/artifact-patch.py" --init "$SEED_JSON" --path "$FRESH_DIR/art-$freshness.json" >/dev/null 2>&1; then
        FR5_PASS=0
        echo "  freshness=$freshness FAILED init" >&2
        break
    fi
done
if [[ "$FR5_PASS" == "1" ]]; then
    pass "FR-5 (§13.10): schema accepts base_context for every freshness enum value (fresh, fast_forwarded, used_remote_ref, proceeded_stale, no_fetch, no_remote)"
else
    fail "FR-5: schema rejected at least one freshness variant"
fi

# Assertion FR-6: schema rejects an invalid freshness enum value (guards the
# enum against typos).
BAD=$(jq '.base_context = {freshness: "stale", comparison_ref: "main", remote_sha: null, behind_count: null}' "$FIX/artifact-seed.json")
stderr=$("$TOOLS/artifact-patch.py" --init "$BAD" --path "$FRESH_DIR/art-bad.json" 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "freshness"; then
    pass "FR-6 (§13.10): schema rejects invalid freshness enum value with error-as-prompt"
else
    fail "FR-6: expected rejection of freshness='stale'; code=$code stderr=$stderr"
fi

# Assertion FR-7: offline fallback — fetch against a bogus remote URL fails
# (non-zero rc) in under 30s. This is the guarded path that must degrade to
# base_freshness="no_fetch" rather than hard-abort.
OFFLINE="$FRESH_DIR/offline"
mkdir -p "$OFFLINE"
(
    cd "$OFFLINE"
    git init --quiet
    git remote add origin /nonexistent/path/to/nowhere.git
)
fetch_rc=0
(cd "$OFFLINE" && git fetch origin main --quiet 2>/dev/null) || fetch_rc=$?
if [[ "$fetch_rc" != "0" ]]; then
    pass "FR-7 (§13.10): fetch against unreachable remote fails (rc=$fetch_rc) — exercises no_fetch degradation path"
else
    fail "FR-7: expected non-zero fetch rc against bogus remote, got 0"
fi

# ------------------------------------------------------------------ Stage 2.6.B
# Origin cross-check (§13.11). Deterministic blame-based classifier —
# origin-crosscheck.sh takes a candidate JSON array and corrects
# {origin, origin_confidence} based on whether every implicated commit
# is reachable from $comparison_ref.

OC_DIR="$WORK/origin-crosscheck"
mkdir -p "$OC_DIR/repo"
(
    cd "$OC_DIR/repo"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    # Rename default branch to main if init didn't honor --initial-branch.
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    cat > file_a.py <<PY
def a():
    return 1
def b():
    return 2
PY
    git add file_a.py
    git commit --quiet -m "initial main"
    git checkout --quiet -b feat
    # Add a new file (trivially PR-introduced).
    cat > file_b.py <<PY
def new_feature():
    return 'hi'
PY
    # Modify one line of file_a.py (line 4: "return 2" → "return 3").
    sed -i.bak 's/return 2/return 3/' file_a.py
    rm -f file_a.py.bak
    git add file_a.py file_b.py
    git commit --quiet -m "feature"
)

# Assertion OC-1: pre-existing range (lines 1-2 of file_a.py — untouched).
# Lens default (introduced_by_pr/high) should be OVERRIDDEN to pre_existing/high.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C1","file":"file_a.py","line_range":[1,2],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>/dev/null)
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "high" ]]; then
    pass "OC-1 (§13.11): fully-ancestor line range overrides lens to pre_existing/high"
else
    fail "OC-1: expected origin=pre_existing,conf=high; got origin=$origin conf=$conf"
fi

# Assertion OC-2: PR-modified range (line 4 of file_a.py — the sed change).
# Lens value (introduced_by_pr/high) should be RESPECTED.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C2","file":"file_a.py","line_range":[4,4],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>/dev/null)
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]]; then
    pass "OC-2 (§13.11): PR-modified line respects lens (introduced_by_pr/high)"
else
    fail "OC-2: expected origin=introduced_by_pr,conf=high; got origin=$origin conf=$conf"
fi

# Assertion OC-3: new file (file_b.py). Whole file is PR-introduced.
# Lens value should be RESPECTED with reason=new-file.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C3","file":"file_b.py","line_range":[1,2],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2> "$OC_DIR/c3.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]] \
    && grep -q "action=respected" "$OC_DIR/c3.err" \
    && grep -q "reason=new-file" "$OC_DIR/c3.err"; then
    pass "OC-3 (§13.11): new-file candidate respects lens with reason=new-file"
else
    fail "OC-3: expected origin=introduced_by_pr,conf=high + new-file reason; got origin=$origin conf=$conf; stderr=$(cat "$OC_DIR/c3.err")"
fi

# Assertion OC-4: mixed range (file_a.py lines 1-4 — spans pre-existing AND
# the sed'd line). Conservative policy: RESPECT lens (don't auto-override).
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C4","file":"file_a.py","line_range":[1,4],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>/dev/null)
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]]; then
    pass "OC-4 (§13.11): mixed PR+pre-existing range respects lens (conservative policy)"
else
    fail "OC-4: expected origin=introduced_by_pr,conf=high (mixed range); got origin=$origin conf=$conf"
fi

# Assertion OC-5: lens says pre_existing/high but blame disagrees.
# DOWNGRADE confidence to medium so §13.1 override does not fire.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C5","file":"file_a.py","line_range":[4,4],"origin":"pre_existing","origin_confidence":"high"}]' 2> "$OC_DIR/c5.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "medium" ]] \
    && grep -q "action=downgraded" "$OC_DIR/c5.err"; then
    pass "OC-5 (§13.11): lens=pre_existing/high + blame-disagrees → confidence downgraded to medium"
else
    fail "OC-5: expected origin=pre_existing,conf=medium + action=downgraded; got origin=$origin conf=$conf stderr=$(cat "$OC_DIR/c5.err")"
fi

# Assertion OC-6: unknown --comparison-ref surfaces error-as-prompt with
# suggestions (git rev-parse --symbolic --branches). Exits EXIT_VALIDATION=1.
stderr=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref nonexistent-ref \
    --candidates '[{"id":"C6","file":"file_a.py","line_range":[1,1],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "did not resolve" \
    && echo "$stderr" | grep -q "Did you mean"; then
    pass "OC-6 (§13.11): unknown --comparison-ref rejected with error-as-prompt + suggestions (exit 1)"
else
    fail "OC-6: expected exit 1 + error-as-prompt; got code=$code stderr=$stderr"
fi

# Assertion OC-7: malformed JSON rejected. Exits EXIT_VALIDATION=1.
stderr=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main --candidates 'not-json' 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] && echo "$stderr" | grep -q "JSON array"; then
    pass "OC-7 (§13.11): malformed --candidates JSON rejected with exit 1"
else
    fail "OC-7: expected exit 1; got code=$code stderr=$stderr"
fi

# Assertion OC-8: blame failure captures stderr into the audit reason so
# rc=128 cases are diagnosable in trace.md instead of opaque. Force the
# failure by requesting a line range that overshoots file_a.py (4 lines).
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C8","file":"file_a.py","line_range":[99,100],"origin":"introduced_by_pr","origin_confidence":"high"}]' \
    2> "$OC_DIR/c8.err")
if grep -qE 'reason=blame-failed rc=[0-9]+; .+' "$OC_DIR/c8.err" \
    && grep -q 'action=skipped' "$OC_DIR/c8.err"; then
    pass "OC-8 (§13.11): blame failure records rc and captured stderr suffix in reason"
else
    fail "OC-8: expected 'reason=blame-failed rc=<N>; <stderr>' + action=skipped; got: $(cat "$OC_DIR/c8.err")"
fi

# ------------------------------------------------------------------ Stage 2.6.B (rename-follow)
# Rename- and extraction-follow (§13.11, Project G). `git cat-file -e
# $ref:$file` fails for any PR-added file — the old helper exited with
# reason=new-file and respected the lens, missing F038-class cases
# where the "new" file is actually an extraction from a pre-PR
# predecessor. origin-crosscheck.sh now walks `git log --follow` to
# reach the pre-rename ancestor and re-checks reachability.

OC_RN_DIR="$WORK/origin-crosscheck-rename"
mkdir -p "$OC_RN_DIR/extract-repo"
(
    cd "$OC_RN_DIR/extract-repo"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    # main: monolith with a bug inside recategorize().
    cat > monolith.ts <<'TS'
export function helper() { return 1; }
export function recategorize(x: unknown) {
    // BUG: missing null check
    return (x as any).kind;
}
export function other() { return 2; }
TS
    git add monolith.ts
    git commit --quiet -m "initial main with bug in monolith"
    git checkout --quiet -b pr
    # PR extracts recategorize into its own file, preserving content.
    cat > monolith.ts <<'TS'
export function helper() { return 1; }
export function other() { return 2; }
export { recategorize } from "./recategorization";
TS
    cat > recategorization.ts <<'TS'
export function recategorize(x: unknown) {
    // BUG: missing null check
    return (x as any).kind;
}
TS
    git add monolith.ts recategorization.ts
    git commit --quiet -m "extract recategorize into its own file"
    # A follow-up PR commit adds a genuinely-new line to the extracted file.
    cat >> recategorization.ts <<'TS'
export const NEW_BUG_CONST = null as any;
TS
    git add recategorization.ts
    git commit --quiet -m "add new buggy constant in PR"
)

# Assertion OC-9: happy path. Lines 1-3 of recategorization.ts came
# across the extraction boundary from monolith.ts (pre-PR). `git log
# --follow` reaches a commit on main; blame points to the file-add
# commit. Override lens → pre_existing/high.
out=$(cd "$OC_RN_DIR/extract-repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"RF1","file":"recategorization.ts","line_range":[1,3],"origin":"introduced_by_pr","origin_confidence":"high"}]' \
    2> "$OC_RN_DIR/rf1.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "high" ]] \
    && grep -q 'action=overridden' "$OC_RN_DIR/rf1.err" \
    && grep -q 'reason=rename-followed-to-preexisting' "$OC_RN_DIR/rf1.err"; then
    pass "OC-9 (§13.11, Project G): extracted lines of PR-added file traced via git log --follow to pre-PR ancestor → override to pre_existing/high"
else
    fail "OC-9: expected overridden to pre_existing/high with reason=rename-followed-to-preexisting; got origin=$origin conf=$conf stderr=$(cat "$OC_RN_DIR/rf1.err")"
fi

# Assertion OC-10: regression guard. A brand-new file with no rename
# history must still exit via reason=new-file and respect the lens.
mkdir -p "$OC_RN_DIR/genuine-repo"
(
    cd "$OC_RN_DIR/genuine-repo"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    echo "baseline" > existing.txt
    git add existing.txt
    git commit --quiet -m "initial main"
    git checkout --quiet -b pr
    cat > brand-new.ts <<'TS'
export function foo() { return 1; }
export function bug() { return (null as any).x; }
TS
    git add brand-new.ts
    git commit --quiet -m "add brand-new.ts"
)
out=$(cd "$OC_RN_DIR/genuine-repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"RF2","file":"brand-new.ts","line_range":[1,2],"origin":"introduced_by_pr","origin_confidence":"high"}]' \
    2> "$OC_RN_DIR/rf2.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]] \
    && grep -q 'action=respected' "$OC_RN_DIR/rf2.err" \
    && grep -q 'reason=new-file' "$OC_RN_DIR/rf2.err"; then
    pass "OC-10 (§13.11, Project G): genuinely-new PR file (no rename/extraction ancestor) still respects lens with reason=new-file"
else
    fail "OC-10: expected introduced_by_pr/high + reason=new-file; got origin=$origin conf=$conf stderr=$(cat "$OC_RN_DIR/rf2.err")"
fi

# Assertion OC-11: extraction-with-PR-additions. When an extracted file
# also gets new lines added in a later PR commit, blame on those new
# lines points to a non-ancestor, non-add-commit SHA. The override
# must NOT fire — respect the lens with an audit reason that signals
# why (so a reviewer reading trace.md can distinguish "extracted"
# from "mixed-extracted-plus-new" findings).
out=$(cd "$OC_RN_DIR/extract-repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"RF3","file":"recategorization.ts","line_range":[5,5],"origin":"introduced_by_pr","origin_confidence":"high"}]' \
    2> "$OC_RN_DIR/rf3.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]] \
    && grep -q 'action=respected' "$OC_RN_DIR/rf3.err" \
    && grep -q 'reason=rename-follow-but-lines-modified-in-pr' "$OC_RN_DIR/rf3.err"; then
    pass "OC-11 (§13.11, Project G): PR-added lines in an extracted file are NOT overridden (blame SHA not in ancestor nor file-add set) — lens respected"
else
    fail "OC-11: expected introduced_by_pr/high + reason=rename-follow-but-lines-modified-in-pr; got origin=$origin conf=$conf stderr=$(cat "$OC_RN_DIR/rf3.err")"
fi

# ------------------------------------------------------------------ Stage 2.6.C
# Renderer surfaces §13.10 freshness state in the header when non-default.

RH_DIR="$WORK/render-header"
mkdir -p "$RH_DIR"

# Helper: build an artifact with a given base_context and render it. Returns
# the rendered markdown's header block.
render_with_freshness() {
    local freshness="$1"
    local behind="$2"
    local remote_sha_arg
    if [[ "$freshness" == "no_fetch" || "$freshness" == "no_remote" ]]; then
        remote_sha_arg=null
    else
        remote_sha_arg='"abc1234"'
    fi
    local id="rev_$(echo "$freshness" | tr -d '_')"
    local seed
    seed=$(jq --arg f "$freshness" \
              --arg id "$id" \
              --argjson rs "$remote_sha_arg" \
              --argjson bc "$behind" \
              '.review_id = $id
               | .base_context = {freshness: $f, comparison_ref: "main", remote_sha: $rs, behind_count: $bc}' \
              "$FIX/artifact-seed.json")
    "$TOOLS/artifact-patch.py" --init "$seed" --path "$RH_DIR/art-$freshness.json" >/dev/null
    "$TOOLS/artifact-render.py" --input "$RH_DIR/art-$freshness.json"
}

# Assertion RH-1: freshness=fresh → NO "Base freshness:" line (happy path
# stays quiet so the header isn't cluttered for 99% of runs).
md=$(render_with_freshness fresh 0)
if ! echo "$md" | grep -q "Base freshness:"; then
    pass "RH-1 (§13.10/§7): freshness=fresh renders WITHOUT a Base freshness line"
else
    fail "RH-1: fresh should render quietly; saw: $(echo "$md" | grep 'Base freshness')"
fi

# Assertion RH-2: fast_forwarded → single ⚠-free line noting the prior behind count.
md=$(render_with_freshness fast_forwarded 12)
if echo "$md" | grep -q "Base freshness:" \
    && echo "$md" | grep -q "fast-forwarded before review" \
    && echo "$md" | grep -q "12 commits behind"; then
    pass "RH-2 (§13.10/§7): fast_forwarded renders prior behind-count with fast-forwarded note"
else
    fail "RH-2: expected fast_forwarded header; saw: $md"
fi

# Assertion RH-3: used_remote_ref → single ⚠ with the review-used-remote phrasing.
md=$(render_with_freshness used_remote_ref 12)
if echo "$md" | grep -q "Base freshness:" \
    && echo "$md" | grep -q "compared against" \
    && echo "$md" | grep -q 'origin/main' \
    && echo "$md" | grep -q "⚠"; then
    pass "RH-3 (§13.10/§7): used_remote_ref renders ⚠ + 'compared against origin/main'"
else
    fail "RH-3: expected used_remote_ref header with ⚠; saw: $md"
fi

# Assertion RH-4: proceeded_stale → ⚠⚠ with explicit data-loss warning.
md=$(render_with_freshness proceeded_stale 12)
if echo "$md" | grep -q "⚠⚠" \
    && echo "$md" | grep -q "stale local" \
    && echo "$md" | grep -q "git pull"; then
    pass "RH-4 (§13.10/§7): proceeded_stale renders ⚠⚠ + explicit stale warning + git pull hint"
else
    fail "RH-4: expected proceeded_stale header with ⚠⚠; saw: $md"
fi

# Assertion RH-5: no_fetch → offline note. No ⚠ (offline is a soft degradation).
md=$(render_with_freshness no_fetch 0)
if echo "$md" | grep -q "could not fetch" \
    && echo "$md" | grep -q "offline"; then
    pass "RH-5 (§13.10/§7): no_fetch renders 'could not fetch (offline?)' note"
else
    fail "RH-5: expected no_fetch header; saw: $md"
fi

# Assertion RH-6: no_remote → no line rendered (local-only repo is normal,
# not a warning-worthy state).
md=$(render_with_freshness no_remote 0)
if ! echo "$md" | grep -q "Base freshness:"; then
    pass "RH-6 (§13.10/§7): no_remote renders silently (no warning for local-only repos)"
else
    fail "RH-6: no_remote should render quietly; saw: $(echo "$md" | grep 'Base freshness')"
fi

# Assertion RH-7: artifacts without base_context (pre-§13.10) render without
# any freshness line — backward compat.
md=$("$TOOLS/artifact-render.py" --input "$ART")
if ! echo "$md" | grep -q "Base freshness:"; then
    pass "RH-7 (§13.10/§7): pre-§13.10 artifact (no base_context) renders without freshness line"
else
    fail "RH-7: pre-§13.10 artifact should not render freshness; saw: $(echo "$md" | grep 'Base freshness')"
fi

# --- OTR-* : orchestrator-tokens render line shape (post-plugin-improvements
# Project A). The header line used to display four counters (cache-read /
# output / cache-creation / fresh input) which buried the signal; the four
# values stay in the artifact for cost analysis, but the rendered line now
# shows only the user-facing levers (output / input across N turns). See
# CLAUDE.md §"Pipeline shape" for the rationale.

OTR_DIR="$WORK/render-orch"
mkdir -p "$OTR_DIR"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$OTR_DIR/art.json" >/dev/null
"$TOOLS/artifact-patch.py" --path "$OTR_DIR/art.json" --set-json \
    'orchestrator_tokens={"total_input":484,"total_output":566990,"cache_read":53046666,"cache_creation":2134808,"turn_count":324,"sessions":[]}' \
    >/dev/null
md=$("$TOOLS/artifact-render.py" --input "$OTR_DIR/art.json")

# Assertion OTR-1: rendered line is the simplified `<output> output /
# <input> input across <N> turns` shape. Exact, because this string is the
# whole point of the display-cleanup — regressions silently re-bury signal.
expected_line='**Orchestrator tokens:** 566,990 output / 484 input across 324 turns'
if echo "$md" | grep -qxF "$expected_line"; then
    pass "OTR-1 (post-plugin-improvements A): rendered orchestrator-tokens line is '<output> output / <input> input across <N> turns'"
else
    fail "OTR-1: expected '$expected_line'; saw: $(echo "$md" | grep -F 'Orchestrator tokens:' || echo '(no Orchestrator tokens line)')"
fi

# Assertion OTR-2: cache-read and cache-creation must NOT appear on the
# rendered header. The artifact still carries them (see schema-v1.json and
# OT-* helper assertions below) — they just stay machine-facing.
if echo "$md" | grep -F 'Orchestrator tokens:' | grep -Eq 'cache-read|cache-creation|fresh input'; then
    fail "OTR-2: rendered header still leaks cache-read/cache-creation/'fresh input'; saw: $(echo "$md" | grep -F 'Orchestrator tokens:')"
else
    pass "OTR-2 (post-plugin-improvements A): cache-read/cache-creation/'fresh input' dropped from rendered header (still in artifact)"
fi

# Assertion OTR-3: all four counters still present in the stored artifact
# — schema-v1.json still requires them; narrowing the display must not
# collapse the internal capture.
stored=$(jq -c '.orchestrator_tokens | {total_input, total_output, cache_read, cache_creation, turn_count}' "$OTR_DIR/art.json")
expected_stored='{"total_input":484,"total_output":566990,"cache_read":53046666,"cache_creation":2134808,"turn_count":324}'
if [[ "$stored" == "$expected_stored" ]]; then
    pass "OTR-3 (post-plugin-improvements A): all four counters preserved in artifact.orchestrator_tokens after narrowed render"
else
    fail "OTR-3: artifact counters drifted after narrowed render; got $stored, expected $expected_stored"
fi

# Assertion OTR-4: render still guards on missing orchestrator_tokens
# (pre-feature artifacts, interrupted runs) — the seed.json has no
# orchestrator_tokens object, so the base $ART render from earlier
# assertions shouldn't carry an Orchestrator line at all.
md_base=$("$TOOLS/artifact-render.py" --input "$ART")
if echo "$md_base" | grep -qF 'Orchestrator tokens:'; then
    fail "OTR-4: pre-feature artifact (no orchestrator_tokens) should not render header line"
else
    pass "OTR-4 (post-plugin-improvements A): missing orchestrator_tokens still omits header line (backward compat)"
fi

# ------------------------------------------------------------------ Stage 2.7
# assign-finding-ids.sh (§13.12) — deterministic source-priority sort +
# monotonic F### assignment over pooled internal + external candidates.
# Stage 2.7 hoists id assignment to a single join point after Phase 1 +
# Phase 1.5 dispatch so the two phases can fan out concurrently without
# racing a shared id counter.

AI_TOOL="$TOOLS/assign-finding-ids.sh"

# Assertion AI-1: internal-only pool — 3 L1 + 2 L2 + 1 L3. Expect
# F001..F006 in source-priority order (L1 → L2 → L3) with input order
# preserved within each source bucket.
in='[{"sources":["L1-diff-local"],"file":"a.ts"},{"sources":["L1-diff-local"],"file":"b.ts"},{"sources":["L1-diff-local"],"file":"c.ts"},{"sources":["L2-structural"],"file":"d.ts"},{"sources":["L2-structural"],"file":"e.ts"},{"sources":["L3-claude-md"],"file":"f.ts"}]'
out=$(echo "$in" | "$AI_TOOL")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.sources[0]):\(.file)"] | join(",")')
expected="F001:L1-diff-local:a.ts,F002:L1-diff-local:b.ts,F003:L1-diff-local:c.ts,F004:L2-structural:d.ts,F005:L2-structural:e.ts,F006:L3-claude-md:f.ts"
if [[ "$line" == "$expected" ]]; then
    pass "AI-1 (§13.12): internal-only pool assigns F001..F006 in L1→L2→L3 source order"
else
    fail "AI-1: expected '$expected', got '$line'"
fi

# Assertion AI-2: ensemble-mixed pool — 1 L1 + 1 L6 + 1 external-pr +
# 1 codex + 1 coderabbit. Expect L1 → L6 → external-pr → codex → coderabbit.
in='[{"sources":["L1-diff-local"],"file":"a.ts"},{"sources":["L6-security"],"file":"b.ts"},{"sources":["external-pr:greptile[bot]"],"file":"c.ts"},{"sources":["codex"],"file":"d.ts"},{"sources":["coderabbit"],"file":"e.ts"}]'
out=$(echo "$in" | "$AI_TOOL")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.sources[0])"] | join(",")')
expected="F001:L1-diff-local,F002:L6-security,F003:external-pr:greptile[bot],F004:codex,F005:coderabbit"
if [[ "$line" == "$expected" ]]; then
    pass "AI-2 (§13.12): ensemble-mixed pool orders L1 → L6 → external-pr → codex → coderabbit"
else
    fail "AI-2: expected '$expected', got '$line'"
fi

# Assertion AI-3: stable within source. 4 L1 candidates in input order
# A,B,C,D should emerge in the same order — jq sort_by is stable and
# our secondary key on input index preserves it across identical priorities.
in='[{"sources":["L1-diff-local"],"file":"A"},{"sources":["L1-diff-local"],"file":"B"},{"sources":["L1-diff-local"],"file":"C"},{"sources":["L1-diff-local"],"file":"D"}]'
out=$(echo "$in" | "$AI_TOOL")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.file)"] | join(",")')
expected="F001:A,F002:B,F003:C,F004:D"
if [[ "$line" == "$expected" ]]; then
    pass "AI-3 (§13.12): same-source candidates preserve input order (stable sort)"
else
    fail "AI-3: expected '$expected', got '$line'"
fi

# Assertion AI-4: empty pool. `[]` in, `[]` out, exit 0. Non-ensemble
# runs with zero Phase 1 findings exercise this path.
out=$(echo '[]' | "$AI_TOOL"); code=$?
if [[ "$code" == "0" && "$out" == "[]" ]]; then
    pass "AI-4 (§13.12): empty pool returns '[]' with exit 0"
else
    fail "AI-4: expected empty-array passthrough; got code=$code out='$out'"
fi

# Assertion AI-5: malformed stdin → exit 1 with error-as-prompt.
stderr=$(echo 'not-json' | "$AI_TOOL" 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "not a JSON array" \
    && echo "$stderr" | grep -q "Did you mean" \
    && echo "$stderr" | grep -q "Action:"; then
    pass "AI-5 (§13.12): malformed stdin rejected with exit 1 + error-as-prompt"
else
    fail "AI-5: expected exit 1 + full error-as-prompt; got code=$code stderr='$stderr'"
fi

# Assertion AI-6: non-array stdin (JSON object) → same error path.
stderr=$(echo '{}' | "$AI_TOOL" 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] && echo "$stderr" | grep -q "not a JSON array"; then
    pass "AI-6 (§13.12): non-array JSON stdin rejected with exit 1"
else
    fail "AI-6: expected exit 1 for non-array JSON; got code=$code stderr='$stderr'"
fi

# Assertion AI-7: unknown source falls to priority 99 (sorted last) but
# still gets an id. Forward-compat for future source-family additions
# (e.g. a hypothetical 'semgrep' CLI reviewer) that ship before the
# helper is updated — the id assignment must not drop the candidate.
in='[{"sources":["mystery-source"],"file":"unknown.ts"},{"sources":["L1-diff-local"],"file":"known.ts"}]'
out=$(echo "$in" | "$AI_TOOL")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.sources[0]):\(.file)"] | join(",")')
expected="F001:L1-diff-local:known.ts,F002:mystery-source:unknown.ts"
if [[ "$line" == "$expected" ]]; then
    pass "AI-7 (§13.12): unknown source falls to priority 99 (sorted last), id still assigned"
else
    fail "AI-7: expected '$expected', got '$line'"
fi

# ------------------------------------------------------------------ Stage 3
#
# Stage 3 introduces `/adamsreview:fix`. These assertions cover the helper
# contracts it depends on — `group-fixes.py` (§21.5) fix-group union-find
# and `artifact-patch.py` batched fix-outcome modes. Fragment-level prose
# (Phase 7/8/9 orchestration) is not machine-tested here; real-repo runs
# are the first integration signal, same posture as Stage 2.5.B / 2.7.

GF_TOOL="$TOOLS/group-fixes.py"
GF_ART="$WORK/gf-art.json"

# Rebuild artifact from the fix-group fixture. Independent of the Stage 1/2
# state above; validator in --init guards schema shape.
if "$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$GF_ART" >/dev/null; then
    pass "FX-init: fix-group fixture loads into valid artifact"
else
    fail "FX-init: fix-group-seed.json --init failed"
fi

# Assertion FX-GF-1: single-finding eligible list → single FG with one id.
# F007 is standalone on src/e.ts — the happy path.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F007")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F007"],"files_planned":["src/e.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-1 (§21.5): single eligible finding produces single FG group"
else
    fail "FX-GF-1: expected '$expected', got '$line'"
fi

# Assertion FX-GF-2: two findings in the same cross_cutting_group merge.
# F004+F005 are on disjoint files (c.ts / d.ts) but linked by G1. The
# cross-cutting seed in §21.5 step 2 must fire before file-union step 3
# decides they're disjoint.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F004,F005")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F004","F005"],"files_planned":["src/c.ts","src/d.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-2 (§21.5): cross_cutting_groups merge eligible members (disjoint files)"
else
    fail "FX-GF-2: expected '$expected', got '$line'"
fi

# Assertion FX-GF-3: two findings sharing a planned file merge. F001 and
# F002 both plan src/a.ts — no cross-cutting link, the file-overlap step
# alone must catch this.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F001,F002")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F001","F002"],"files_planned":["src/a.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-3 (§21.5): findings sharing a planned file merge into one group"
else
    fail "FX-GF-3: expected '$expected', got '$line'"
fi

# Assertion FX-GF-4: transitive closure. F004+F005 linked by CCG; F004+F006
# share src/c.ts. All three must collapse to one group — tests that the
# union-find picks up the transitive relation (F005 → F004 → F006).
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F004,F005,F006")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F004","F005","F006"],"files_planned":["src/c.ts","src/d.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-4 (§21.5): transitive closure (CCG + file-share) merges all three"
else
    fail "FX-GF-4: expected '$expected', got '$line'"
fi

# Assertion FX-GF-5: disjoint singletons stay singletons. F003 on b.ts,
# F007 on e.ts, no CCG — two separate FGs, numbered by minimum-id rule.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F003,F007")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F003"],"files_planned":["src/b.ts"]},{"id":"FG-2","finding_ids":["F007"],"files_planned":["src/e.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-5 (§21.5): disjoint singletons produce two FGs, numbered by minimum id"
else
    fail "FX-GF-5: expected '$expected', got '$line'"
fi

# Assertion FX-GF-6: empty eligible list → empty JSON array, exit 0.
# Orchestrator path: threshold filter excluded every finding; no fix
# groups to form, but the helper must not error.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids ""); code=$?
if [[ "$code" == "0" && "$out" == "[]" ]]; then
    pass "FX-GF-6 (§21.5): empty eligible list returns '[]' with exit 0"
else
    fail "FX-GF-6: expected '[]' + exit 0, got code=$code out='$out'"
fi

# Assertion FX-GF-7: unknown finding id → EXIT_VALIDATION (1) + error-as-prompt
# naming the bad id AND listing valid ids.
stderr=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F999" 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "unknown id" \
    && echo "$stderr" | grep -q "F999" \
    && echo "$stderr" | grep -q "existing ids" \
    && echo "$stderr" | grep -q "Action:"; then
    pass "FX-GF-7 (§21.5): unknown eligible id rejected with exit 1 + error-as-prompt"
else
    fail "FX-GF-7: expected exit 1 + error-as-prompt; got code=$code stderr='$stderr'"
fi

# Assertion FX-GF-8: eligible finding with null validation_result is
# rejected. The orchestrator must not hand trivial-mode or below-gate
# findings to the grouper — the helper confirms it via error-as-prompt
# rather than silently dropping them. Rebuild a fresh artifact from the
# Stage-1 seed (whose F001 has validation_result=null per its fixture
# design) so this test is independent of whatever $ART is after the
# earlier Stage 1/2 assertions mutated it.
NULL_VR_ART="$WORK/gf-null-vr.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$NULL_VR_ART" >/dev/null
stderr=$("$GF_TOOL" --artifact "$NULL_VR_ART" --eligible-finding-ids "F001" 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] && echo "$stderr" | grep -q "validation_result is required"; then
    pass "FX-GF-8 (§21.5): eligible finding missing validation_result rejected"
else
    fail "FX-GF-8: expected exit 1 + validation_result message; got code=$code stderr='$stderr'"
fi

# Assertion FX-GF-9: a PROMOTED finding with null validation_result is accepted
# by the grouper — the human_confirmation override (§27) bypasses the
# fix_proposal requirement. files_planned falls back to [finding.file].
# Covers the §27 light-lane end-to-end path: promote → Phase 8 grouping →
# fix-group dispatch. Without this fallback, group-fixes.py would hard-error
# before Phase 8 ever sees the finding, nullifying the --fix-hint steering.
GF_PROMOTED_ART="$WORK/gf-promoted.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$GF_PROMOTED_ART" >/dev/null
GF_PROMOTE_HC=$(jq -nc '{
    reviewer: "tester@example.com",
    reason:   "promote light-lane for fix",
    ts:       "2026-04-19T12:00:00Z",
    promoted_from: {disposition:"uncertain", actionability:"report_only", score_phase4:null},
    fix_hint: "Update the docstring to match the code; do not modify the code."
}')
"$TOOLS/artifact-patch.py" --path "$GF_PROMOTED_ART" --finding-id F001 \
    --set disposition=confirmed_mechanical \
    --set current_state=open \
    --set actionability=auto_fixable \
    --set-json "human_confirmation=$GF_PROMOTE_HC" >/dev/null 2>&1 \
    || fail "FX-GF-9 setup: promote patch failed"
gf9_out=$("$GF_TOOL" --artifact "$GF_PROMOTED_ART" --eligible-finding-ids "F001" 2>"$WORK/gf9.err"); gf9_code=$?
gf9_files=$(echo "$gf9_out" | jq -c '.[0].files_planned' 2>/dev/null)
if [[ "$gf9_code" == "0" ]] && [[ "$gf9_files" == '["src/auth/session.ts"]' ]]; then
    pass "FX-GF-9 (§21.5, §27): promoted finding with null validation_result groups with files_planned=[finding.file]"
else
    fail "FX-GF-9: expected exit 0 + files_planned=[src/auth/session.ts]; got code=$gf9_code files=$gf9_files stderr=$(cat "$WORK/gf9.err")"
fi

# ------------------------------------------------------------------ Stage 3 — apply-fix-* modes
#
# --apply-fix-start collapses Phase 8 step 8.4 (bulk open→attempted) to a
# single call. --apply-fix-outcomes collapses Phase 9d (per-finding state
# transition + fix_attempt append) to a single call. Both follow the
# Stage-2.5.B --apply-decisions pattern: per-tuple atomic writes, first
# failure halts, one summary line on success.

AF_ART="$WORK/af-art.json"

# Build a fresh artifact for apply-fix-* assertions. Avoid reusing the
# gf-art state (which has been mutated by earlier GF assertions in theory,
# though in practice group-fixes.py is read-only — still, independence
# matters for test isolation).
if "$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$AF_ART" >/dev/null; then
    pass "FX-AF-init: rebuilt artifact for apply-fix-* tests"
else
    fail "FX-AF-init: --init failed"
fi

# Assertion FX-AF-1: --apply-fix-start bulk transition open→attempted.
# Three eligible findings; post-call all three have current_state=attempted.
"$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_smoke1"},{"id":"F002","run_id":"fixrun_smoke1"},{"id":"F003","run_id":"fixrun_smoke1"}]' \
  >/dev/null 2>&1
states=$(jq -r '.findings[0:3] | [.[].current_state] | join(",")' "$AF_ART")
if [[ "$states" == "attempted,attempted,attempted" ]]; then
    pass "FX-AF-1 (§21.2/§4 Phase 8): --apply-fix-start bulk open→attempted"
else
    fail "FX-AF-1: expected all three attempted, got '$states'"
fi

# Assertion FX-AF-2: --apply-fix-start halts loudly when a tuple's finding
# is not current_state=open. Re-running start on F001 (already attempted
# from AF-1) tests the Phase-7-gate-bypass guard: the Phase-7 leftover-
# attempted hard abort is supposed to catch stale state; --apply-fix-start
# refuses to silently no-op on same→same.
stderr=$("$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_smoke2"}]' 2>&1 >/dev/null); code=$?
if [[ "$code" == "2" ]] \
    && echo "$stderr" | grep -q "current_state='attempted' is not 'open'"; then
    pass "FX-AF-2 (§4 Phase 8): --apply-fix-start rejects non-open finding (exit 2)"
else
    fail "FX-AF-2: expected exit 2 + non-open guard, got code=$code stderr='$stderr'"
fi

# Assertion FX-AF-3: --apply-fix-outcomes verified outcome transitions
# attempted→resolved, disposition=resolved, reason=null, fix_attempt
# appended with output_sha.
"$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_smoke1","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"verified","timestamp":"2026-04-18T13:00:00Z"}]' \
  >/dev/null 2>&1
f1=$(jq -c '.findings[] | select(.id=="F001") | {current_state,disposition,reason,attempts:(.fix_attempts|length),last_outcome:(.fix_attempts[-1].phase_9_outcome),last_sha:(.fix_attempts[-1].output_sha)}' "$AF_ART")
expected='{"current_state":"resolved","disposition":"resolved","reason":null,"attempts":1,"last_outcome":"verified","last_sha":"bbbb222"}'
if [[ "$f1" == "$expected" ]]; then
    pass "FX-AF-3 (§13.1 Phase 9): verified → resolved+resolved, fix_attempt with output_sha"
else
    fail "FX-AF-3: expected '$expected', got '$f1'"
fi

# Assertion FX-AF-4: partial outcome → attempted→open, disposition=partial,
# reason prose includes phase_9_finding, fix_attempt captures the diagnostic.
"$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-outcomes \
  '[{"id":"F002","run_id":"fixrun_smoke1","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"partial","timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"missed x.ts:10"}]' \
  >/dev/null 2>&1
f2=$(jq -c '.findings[] | select(.id=="F002") | {current_state,disposition,reason,last_finding:(.fix_attempts[-1].phase_9_finding)}' "$AF_ART")
expected='{"current_state":"open","disposition":"partial","reason":"fix partial: missed x.ts:10","last_finding":"missed x.ts:10"}'
if [[ "$f2" == "$expected" ]]; then
    pass "FX-AF-4 (§13.1 Phase 9): partial → open+partial, reason prose + phase_9_finding"
else
    fail "FX-AF-4: expected '$expected', got '$f2'"
fi

# Assertion FX-AF-5: regression outcome → attempted→open, disposition=regression,
# output_sha on the fix_attempt MUST be null (group was reverted).
"$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-outcomes \
  '[{"id":"F003","run_id":"fixrun_smoke1","fix_group_id":"FG-2","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":"regression","timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"new 401 in y.ts:22"}]' \
  >/dev/null 2>&1
f3=$(jq -c '.findings[] | select(.id=="F003") | {current_state,disposition,reason,last_sha:(.fix_attempts[-1].output_sha),last_outcome:(.fix_attempts[-1].phase_9_outcome)}' "$AF_ART")
expected='{"current_state":"open","disposition":"regression","reason":"fix regressed: new 401 in y.ts:22","last_sha":null,"last_outcome":"regression"}'
if [[ "$f3" == "$expected" ]]; then
    pass "FX-AF-5 (§13.1 Phase 9 / §6): regression → open+regression, output_sha=null preserved"
else
    fail "FX-AF-5: expected '$expected', got '$f3'"
fi

# Assertion FX-AF-6: overlap-abort (phase_9_outcome=null). current_state
# MUST stay at attempted — this is what triggers the next run's
# leftover-attempted hard abort for deterministic recovery. fix_attempt is
# still appended for audit.
OA_ART="$WORK/af-oa.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$OA_ART" >/dev/null
"$TOOLS/artifact-patch.py" --path "$OA_ART" --apply-fix-start '[{"id":"F004","run_id":"fixrun_oa"}]' >/dev/null
"$TOOLS/artifact-patch.py" --path "$OA_ART" --apply-fix-outcomes \
  '[{"id":"F004","run_id":"fixrun_oa","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":null,"timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"run aborted: overlap on src/c.ts"}]' \
  >/dev/null 2>&1
f4=$(jq -c '.findings[] | select(.id=="F004") | {current_state,disposition,attempts:(.fix_attempts|length),last_sha:(.fix_attempts[-1].output_sha),last_outcome:(.fix_attempts[-1].phase_9_outcome),last_finding:(.fix_attempts[-1].phase_9_finding)}' "$OA_ART")
expected='{"current_state":"attempted","disposition":"confirmed_mechanical","attempts":1,"last_sha":null,"last_outcome":null,"last_finding":"run aborted: overlap on src/c.ts"}'
if [[ "$f4" == "$expected" ]]; then
    pass "FX-AF-6 (§4 Phase 9.pre): overlap-abort preserves current_state=attempted, appends audit fix_attempt"
else
    fail "FX-AF-6: expected '$expected', got '$f4'"
fi

# Assertion FX-AF-7: regression with non-null output_sha rejected. The
# helper enforces the §13.1 invariant that regressions have no commit.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/af-rej.json" >/dev/null
"$TOOLS/artifact-patch.py" --path "$WORK/af-rej.json" --apply-fix-start '[{"id":"F001","run_id":"fixrun_rej"}]' >/dev/null
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/af-rej.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rej","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"ffff999","phase_9_outcome":"regression","timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"x"}]' \
  2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] && echo "$stderr" | grep -q "regression outcome requires output_sha=null"; then
    pass "FX-AF-7 (§13.1): regression with non-null output_sha rejected (exit 1)"
else
    fail "FX-AF-7: expected exit 1 + regression-null message; got code=$code stderr='$stderr'"
fi

# Assertion FX-AF-8: --apply-fix-outcomes tuple missing required key rejected.
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/af-rej.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rej","phase_9_outcome":"verified"}]' \
  2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "missing required key" \
    && echo "$stderr" | grep -q "fix_group_id"; then
    pass "FX-AF-8 (§21.2): --apply-fix-outcomes rejects tuple missing required key(s)"
else
    fail "FX-AF-8: expected exit 1 + missing-key message; got code=$code stderr='$stderr'"
fi

# Assertion FX-AF-9: unknown phase_9_outcome rejected. Defense against
# sub-agent response-parsing drift (e.g., a validator returns "verifed"
# instead of "verified" — a close typo where difflib's did-you-mean fires).
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/af-rej.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rej","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":"verifed","timestamp":"2026-04-18T13:00:00Z"}]' \
  2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "unknown phase_9_outcome" \
    && echo "$stderr" | grep -q "Did you mean 'verified'"; then
    pass "FX-AF-9 (§13.1 Phase 9): unknown phase_9_outcome rejected with did-you-mean"
else
    fail "FX-AF-9: expected exit 1 + unknown outcome + suggestion; got code=$code stderr='$stderr'"
fi

# ------------------------------------------------------------------ Reconcile-on-overlap (plans/reconcile-on-overlap.md)
#
# Assertions FX-RECON-*: the 9.pre.offer + 9.pre.reconcile + FG-RECON
# synthetic-group wiring in 10-post-fix-and-commit.md. Grep-level over the
# fragment text for the structural contracts (options, preservation
# snapshot, merge-agent prompt core, delete-leak ordering), plus one
# fixture-level check that --apply-fix-outcomes still accepts the
# ORIGINAL FG-N as fix_group_id on a reconciled run (FG-RECON is
# in-memory only; schema-valid FG-N lands on disk).

FRAG="$REPO/fragments/10-post-fix-and-commit.md"

# FX-RECON-1: fragment offers a three-way AskUserQuestion on overlap,
# with Abort as the default (recommended) choice.
if grep -q "9.pre.offer" "$FRAG" \
   && grep -q "AskUserQuestion" "$FRAG" \
   && grep -q "Abort (recommended)" "$FRAG" \
   && grep -q "Reconcile — dispatch one merge agent" "$FRAG" \
   && grep -q "Inspect — leave tree as-is" "$FRAG"; then
    pass "FX-RECON-1: 9.pre.offer presents three-way AskUserQuestion with Abort as default"
else
    fail "FX-RECON-1: fragment missing one of {9.pre.offer, AskUserQuestion, Abort/Reconcile/Inspect options}"
fi

# FX-RECON-2: reconcile branch collapses fix_groups to a synthetic
# FG-RECON entry AND snapshots the original per-finding fix_group_id
# (original_fix_group_by_finding) for 9d schema compat.
if grep -q 'id: "FG-RECON"' "$FRAG" \
   && grep -q "original_fix_group_by_finding" "$FRAG" \
   && grep -q "reconciled_flag=true" "$FRAG"; then
    pass "FX-RECON-2: fragment collapses fix_groups to FG-RECON and snapshots original per-finding group"
else
    fail "FX-RECON-2: fragment missing FG-RECON collapse or original-group snapshot"
fi

# FX-RECON-3: merge-agent prompt carries the core contract (unresolved
# conflicts escape hatch, delete/rename prohibition, per-group tracking).
if grep -q "unresolved_conflicts" "$FRAG" \
   && grep -q "DO NOT delete or rename files" "$FRAG" \
   && grep -q "reconciled_from_groups" "$FRAG" \
   && grep -q "Phase 9 reconciliation agent" "$FRAG"; then
    pass "FX-RECON-3: merge-agent prompt carries core contract (unresolved_conflicts + delete prohibition + group tracking)"
else
    fail "FX-RECON-3: merge-agent prompt missing one of the core contract pieces"
fi

# FX-RECON-4: on a reconciled run, apply-fix-outcomes tuples MUST use
# each finding's original FG-N (schema rejects FG-RECON). This is a
# smoke-level guard that the schema still validates when the
# reconciled run's fix_attempts preserve FG-1/FG-2 rather than
# FG-RECON — i.e., that 9d's fix_group_id override actually prevents
# the schema violation we'd otherwise hit.
stderr=$("$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/recon-ok.json" 2>&1); code=$?
[[ "$code" != "0" ]] && fail "FX-RECON-4 setup: --init failed (code=$code stderr=$stderr)"
"$TOOLS/artifact-patch.py" --path "$WORK/recon-ok.json" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_rc"},{"id":"F002","run_id":"fixrun_rc"}]' >/dev/null 2>&1
# F001 and F002 originally belonged to different groups (FG-1, FG-2);
# on a reconciled run, both commit under a single commit_sha but each
# preserves its ORIGINAL fix_group_id.
"$TOOLS/artifact-patch.py" --path "$WORK/recon-ok.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rc","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"cccc333","phase_9_outcome":"verified","timestamp":"2026-04-21T10:00:00Z"},
    {"id":"F002","run_id":"fixrun_rc","fix_group_id":"FG-2","input_sha":"aaaa111","output_sha":"cccc333","phase_9_outcome":"verified","timestamp":"2026-04-21T10:00:00Z"}]' \
  >/dev/null 2>&1
recon_ids=$(jq -r '[.findings[] | select(.id=="F001" or .id=="F002") | .fix_attempts[-1].fix_group_id] | join(",")' "$WORK/recon-ok.json")
if [[ "$recon_ids" == "FG-1,FG-2" ]]; then
    pass "FX-RECON-4: reconciled run preserves original per-finding fix_group_id (schema-valid FG-N, not FG-RECON)"
else
    fail "FX-RECON-4: expected 'FG-1,FG-2', got '$recon_ids'"
fi

# FX-RECON-5: delete-leak path still short-circuits to abort WITHOUT
# showing the offer. The fragment ordering must place the deleted_paths
# branch above 9.pre.offer.
deleted_line=$(grep -n 'deleted_paths=.*git status' "$FRAG" | head -1 | cut -d: -f1)
offer_line=$(grep -n '^#### 9.pre.offer' "$FRAG" | head -1 | cut -d: -f1)
if [[ -n "$deleted_line" && -n "$offer_line" && "$deleted_line" -lt "$offer_line" ]]; then
    pass "FX-RECON-5: delete-leak detection precedes 9.pre.offer (delete-leak never sees the reconcile offer)"
else
    fail "FX-RECON-5: expected deleted_paths detection BEFORE 9.pre.offer (got deleted_line=$deleted_line offer_line=$offer_line)"
fi

# ------------------------------------------------------------------ Stage 3 — render fix_runs
#
# artifact-render.py gained a richer `## Fix runs` section plus the
# retry-eligible partial/regression sections. These assertions pin the
# header shape, the outcome labels (including the overlap-abort label
# for phase_9_outcome=null), and the oldest-first ordering invariant
# (runs flow top-to-bottom chronologically, matching how GitHub renders
# the enclosing PR comment).
# expected.md already exercises the single-verified-run case at
# assertion 9 above; these tests focus on the edge cases not covered
# there.

RF_ART="$WORK/rf-art.json"

# Build a fresh artifact with F001 open/confirmed_mechanical and exercise the
# full fix cycle to produce a verified+partial+regression multi-outcome
# run.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$RF_ART" >/dev/null
"$TOOLS/artifact-patch.py" --path "$RF_ART" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_rf"},{"id":"F002","run_id":"fixrun_rf"},{"id":"F003","run_id":"fixrun_rf"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$RF_ART" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rf","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"verified","timestamp":"2026-04-18T14:00:00Z"},
    {"id":"F002","run_id":"fixrun_rf","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"partial","timestamp":"2026-04-18T14:00:00Z","phase_9_finding":"missed q.ts:5"},
    {"id":"F003","run_id":"fixrun_rf","fix_group_id":"FG-2","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":"regression","timestamp":"2026-04-18T14:00:00Z","phase_9_finding":"new 401 in z.ts"}]' >/dev/null 2>&1

"$TOOLS/artifact-render.py" --input "$RF_ART" --output "$WORK/rf.md" >/dev/null

# Assertion FX-RF-1: Fix runs section header + per-run sub-header present.
if grep -q '^## Fix runs$' "$WORK/rf.md" && grep -q '^### Run `fixrun_rf` — 2026-04-18T14:00:00Z$' "$WORK/rf.md"; then
    pass "FX-RF-1 (§7): Fix runs section with per-run ### sub-header and timestamp"
else
    fail "FX-RF-1: expected ## Fix runs + ### Run header; $WORK/rf.md"
fi

# Assertion FX-RF-2: outcome summary line captures all three labels.
if grep -Fq '1 fixed and verified, 1 partial, 1 regression' "$WORK/rf.md"; then
    pass "FX-RF-2 (§7): outcome summary shows verified + partial + regression counts"
else
    fail "FX-RF-2: expected mixed-outcome summary line, got:
$(grep -A1 'Outcomes:' "$WORK/rf.md")"
fi

# Assertion FX-RF-3: per-finding table renders each outcome label correctly
# (✓ fixed and verified / ⚠ partial / ✗ regression) plus the phase_9_finding text.
if grep -Fq '| F001 | FG-1 | ✓ fixed and verified |' "$WORK/rf.md" \
    && grep -Fq '| F002 | FG-1 | ⚠ partial | missed q.ts:5 |' "$WORK/rf.md" \
    && grep -Fq '| F003 | FG-2 | ✗ regression (reverted) | new 401 in z.ts |' "$WORK/rf.md"; then
    pass "FX-RF-3 (§7): per-finding table renders verified/partial/regression with phase_9_finding"
else
    fail "FX-RF-3: per-finding table row(s) missing or mis-rendered; $WORK/rf.md"
fi

# Assertion FX-RF-4: Fix runs section absent when no fix_attempts exist.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/rf-fresh.json" >/dev/null
"$TOOLS/artifact-render.py" --input "$WORK/rf-fresh.json" --output "$WORK/rf-fresh.md" >/dev/null
if ! grep -q '^## Fix runs$' "$WORK/rf-fresh.md"; then
    pass "FX-RF-4 (§7): Fix runs section ABSENT on artifacts with no fix_attempts"
else
    fail "FX-RF-4: Fix runs section rendered on an artifact with zero fix_attempts"
fi

# Assertion FX-RF-5: overlap-abort (phase_9_outcome=null) renders as
# '⚠ overlap-abort' in the per-finding table rather than raw 'None' or
# disappearing. Tests the §4 Phase 9.pre audit-trail visibility.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/rf-oa.json" >/dev/null
"$TOOLS/artifact-patch.py" --path "$WORK/rf-oa.json" --apply-fix-start \
  '[{"id":"F004","run_id":"fixrun_oa"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$WORK/rf-oa.json" --apply-fix-outcomes \
  '[{"id":"F004","run_id":"fixrun_oa","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":null,"timestamp":"2026-04-18T15:00:00Z","phase_9_finding":"run aborted: overlap on src/a.ts"}]' >/dev/null 2>&1
"$TOOLS/artifact-render.py" --input "$WORK/rf-oa.json" --output "$WORK/rf-oa.md" >/dev/null
if grep -Fq '| F004 | FG-1 | ⚠ overlap-abort | run aborted: overlap on src/a.ts |' "$WORK/rf-oa.md" \
    && grep -Fq '1 overlap-abort' "$WORK/rf-oa.md"; then
    pass "FX-RF-5 (§4 Phase 9.pre / §7): overlap-abort renders distinctly in per-finding table + outcome summary"
else
    fail "FX-RF-5: expected overlap-abort label; got:
$(grep -A3 'Fix runs' "$WORK/rf-oa.md")"
fi

# Assertion FX-RF-6: oldest-first ordering. Two runs on the same artifact,
# different timestamps; expect the older run's ### header to appear first
# so the Fix runs section flows chronologically top-to-bottom like the
# enclosing PR comment thread.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/rf-two.json" >/dev/null
# Run A at 13:00
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-start '[{"id":"F007","run_id":"fixrun_old"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-outcomes \
  '[{"id":"F007","run_id":"fixrun_old","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"cccc333","phase_9_outcome":"verified","timestamp":"2026-04-18T13:00:00Z"}]' >/dev/null 2>&1
# F007 is now resolved — to run a second fix, we need a fresh open finding.
# Use F005 (currently open/confirmed_mechanical) for run B at 16:00.
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-start '[{"id":"F005","run_id":"fixrun_new"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-outcomes \
  '[{"id":"F005","run_id":"fixrun_new","fix_group_id":"FG-1","input_sha":"bbbb222","output_sha":"dddd444","phase_9_outcome":"verified","timestamp":"2026-04-18T16:00:00Z"}]' >/dev/null 2>&1

"$TOOLS/artifact-render.py" --input "$WORK/rf-two.json" --output "$WORK/rf-two.md" >/dev/null
# Extract line numbers of the two ### Run sub-headers; older (fixrun_old) must come first.
line_new=$(grep -n '^### Run `fixrun_new`' "$WORK/rf-two.md" | cut -d: -f1)
line_old=$(grep -n '^### Run `fixrun_old`' "$WORK/rf-two.md" | cut -d: -f1)
if [[ -n "$line_new" && -n "$line_old" && "$line_old" -lt "$line_new" ]]; then
    pass "FX-RF-6 (§7): Fix runs ordered oldest-first (line $line_old before $line_new)"
else
    fail "FX-RF-6: expected fixrun_old before fixrun_new, got old=$line_old new=$line_new"
fi

# ------------------------------------------------------------------ Stage 2.8
# PR comment freshness filter (§21.10, §13.13). Replaces the Stage-2
# `--since` time filter with a per-record code-locality check.
#
# Scratch 2-commit repo: C1 creates a.txt + b.txt; C2 modifies a.txt.
# Review comments pinned to C1 are fresh if their path wasn't touched in
# C1..HEAD, stale otherwise. Review submissions (no path) intersect the
# C1..HEAD diff with --reviewed-files. Issue comments (no commit_id) use
# a fixture pr_commits.json with known committer.date values.

CF_DIR="$WORK/comment-freshness"
mkdir -p "$CF_DIR/repo" "$CF_DIR/fixtures"
(
    cd "$CF_DIR/repo"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    echo "alpha" > a.txt
    echo "beta"  > b.txt
    git add a.txt b.txt
    git commit --quiet -m "c1: add a + b"
    echo "alpha-modified" > a.txt
    git add a.txt
    git commit --quiet -m "c2: modify a"
)
CF_C1=$(cd "$CF_DIR/repo" && git rev-parse HEAD~1)
CF_C2=$(cd "$CF_DIR/repo" && git rev-parse HEAD)

# Fixture pr_commits.json mimics pulls/<pr>/commits shape — an array of
# records with .commit.committer.date. Latest date = 2026-04-18T12:00:00Z.
cat > "$CF_DIR/fixtures/pr_commits.json" <<JSON
[
  {"sha":"aaa111","commit":{"committer":{"date":"2026-04-18T10:00:00Z"}}},
  {"sha":"bbb222","commit":{"committer":{"date":"2026-04-18T12:00:00Z"}}}
]
JSON

# Assertion CF-1: review_comment pinned to C1, path b.txt (untouched in
# C1..HEAD). Freshness helper includes it; audit action=fresh.
in_json=$(jq -nc --arg sha "$CF_C1" \
    '[{id:1,author_login:"bot[bot]",author_type:"Bot",created_at:"2026-04-18T15:00:00Z",body:"x",kind:"review_comment",path:"b.txt",line:1,commit_id:$sha}]')
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf1.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "1" ]] && grep -q "action=fresh" "$CF_DIR/cf1.err" \
    && grep -q "reason=path-unchanged" "$CF_DIR/cf1.err"; then
    pass "CF-1 (§21.10): review_comment on unchanged path is included (action=fresh)"
else
    fail "CF-1: expected include + action=fresh; got len=$len stderr=$(cat "$CF_DIR/cf1.err")"
fi

# Assertion CF-2: review_comment pinned to C1, path a.txt (touched in
# C1..HEAD). Freshness helper excludes it; audit action=stale.
in_json=$(jq -nc --arg sha "$CF_C1" \
    '[{id:2,author_login:"bot[bot]",author_type:"Bot",created_at:"2026-04-18T15:00:00Z",body:"x",kind:"review_comment",path:"a.txt",line:1,commit_id:$sha}]')
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf2.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]] && grep -q "action=stale" "$CF_DIR/cf2.err" \
    && grep -q "reason=path-touched" "$CF_DIR/cf2.err"; then
    pass "CF-2 (§21.10): review_comment on touched path is excluded (action=stale)"
else
    fail "CF-2: expected exclude + action=stale; got len=$len stderr=$(cat "$CF_DIR/cf2.err")"
fi

# Assertion CF-3: review submission (no path) pinned to C1, reviewed_files
# includes only b.txt. Diff C1..HEAD touches a.txt but not b.txt → empty
# intersection → include.
in_json=$(jq -nc --arg sha "$CF_C1" \
    '[{id:3,author_login:"bot[bot]",author_type:"Bot",created_at:"2026-04-18T15:00:00Z",body:"x",kind:"review",path:null,line:null,commit_id:$sha}]')
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "b.txt" 2>"$CF_DIR/cf3.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "1" ]] && grep -q "action=fresh" "$CF_DIR/cf3.err"; then
    pass "CF-3 (§21.10): review submission with no reviewed-file touched is included"
else
    fail "CF-3: expected include; got len=$len stderr=$(cat "$CF_DIR/cf3.err")"
fi

# Assertion CF-4: review submission pinned to C1, reviewed_files includes
# a.txt. Diff C1..HEAD touches a.txt → non-empty intersection → exclude.
in_json=$(jq -nc --arg sha "$CF_C1" \
    '[{id:4,author_login:"bot[bot]",author_type:"Bot",created_at:"2026-04-18T15:00:00Z",body:"x",kind:"review",path:null,line:null,commit_id:$sha}]')
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf4.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]] && grep -q "action=stale" "$CF_DIR/cf4.err" \
    && grep -q "reason=reviewed-file-touched" "$CF_DIR/cf4.err"; then
    pass "CF-4 (§21.10): review submission with touched reviewed-file is excluded"
else
    fail "CF-4: expected exclude; got len=$len stderr=$(cat "$CF_DIR/cf4.err")"
fi

# Assertion CF-5: issue_comment (no commit_id) with created_at newer than
# the latest committer.date in the fixture → included (action=fresh-summary).
# Fixture latest = 2026-04-18T12:00:00Z.
in_json='[{"id":5,"author_login":"greptile[bot]","author_type":"Bot","created_at":"2026-04-18T13:00:00Z","body":"nits","kind":"issue_comment","path":null,"line":null,"commit_id":null}]'
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf5.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "1" ]] && grep -q "action=fresh-summary" "$CF_DIR/cf5.err" \
    && grep -q "reason=newer-than-latest-commit" "$CF_DIR/cf5.err"; then
    pass "CF-5 (§21.10): issue_comment posted after latest commit is included (C2 policy)"
else
    fail "CF-5: expected fresh-summary + include; got len=$len stderr=$(cat "$CF_DIR/cf5.err")"
fi

# Assertion CF-6: issue_comment with created_at older than the latest
# committer.date → excluded (action=stale-summary).
in_json='[{"id":6,"author_login":"greptile[bot]","author_type":"Bot","created_at":"2026-04-18T08:00:00Z","body":"old","kind":"issue_comment","path":null,"line":null,"commit_id":null}]'
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf6.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]] && grep -q "action=stale-summary" "$CF_DIR/cf6.err" \
    && grep -q "reason=latest-commit-newer" "$CF_DIR/cf6.err"; then
    pass "CF-6 (§21.10): issue_comment posted before latest commit is excluded (C2 policy)"
else
    fail "CF-6: expected stale-summary + exclude; got len=$len stderr=$(cat "$CF_DIR/cf6.err")"
fi

# Assertion CF-7: review_comment pinned to a commit_id that doesn't exist
# in the scratch repo (simulates force-push / shallow clone). Fetch fallback
# is skipped in --fixtures-dir mode, so the helper excludes with
# action=unreachable.
in_json='[{"id":7,"author_login":"bot[bot]","author_type":"Bot","created_at":"2026-04-18T15:00:00Z","body":"x","kind":"review_comment","path":"a.txt","line":1,"commit_id":"deadbeef00000000000000000000000000000000"}]'
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf7.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]] && grep -q "action=unreachable" "$CF_DIR/cf7.err" \
    && grep -q "reason=commit_id-not-in-history" "$CF_DIR/cf7.err"; then
    pass "CF-7 (§21.10): unreachable commit_id excluded with action=unreachable"
else
    fail "CF-7: expected unreachable; got len=$len stderr=$(cat "$CF_DIR/cf7.err")"
fi

# ------------------------------------------------------------------ Stage 2.8.B guards
# These two assertions confirm --since is actually gone (not just ignored).
# CF-ES-1 also exercises the fixture-replay happy path without --since — was
# previously a usage error before Stage 2.8 because --since was required.

# CF-ES-1: external-scrape.sh --fixtures-dir succeeds without --since.
es_out=$(ADAMS_REVIEW_FIXTURES_USER=smokeuser "$TOOLS/external-scrape.sh" \
            --fixtures-dir "$EXT" 2>"$CF_DIR/es1.err")
es_rc=$?
es_type=$(echo "$es_out" | jq -r 'type' 2>/dev/null)
if [[ "$es_rc" == "0" && "$es_type" == "array" ]]; then
    pass "CF-ES-1 (§21.8): external-scrape.sh succeeds without --since (post-2.8 default)"
else
    fail "CF-ES-1: expected rc=0 + array; got rc=$es_rc type=$es_type stderr=$(cat "$CF_DIR/es1.err")"
fi

# CF-ES-2: external-scrape.sh --since <iso> is rejected (unknown-arg usage error).
es_stderr=$("$TOOLS/external-scrape.sh" --since 2026-01-01T00:00:00Z \
              --fixtures-dir "$EXT" 2>&1 >/dev/null); es_code=$?
if [[ "$es_code" == "64" ]] && echo "$es_stderr" | grep -q "unknown arg '--since'"; then
    pass "CF-ES-2 (§21.8): external-scrape.sh --since is rejected with exit 64 + unknown-arg"
else
    fail "CF-ES-2: expected exit 64 + unknown-arg; got code=$es_code stderr=$es_stderr"
fi

# ------------------------------------------------------------------ MP-* /adamsreview:promote (§27)
#
# Covers the human_confirmation field, Phase 8 eligibility bypass
# (§5.2.1, §13.1, §13.2), and the renderer's (human-confirmed) tag.
# Fixture's F006 is architecture/light-lane/score=48/uncertain — the
# canonical "would never be Phase-8-eligible without a human override"
# case, so perfect for the eligibility-bypass assertions.

MP_ART="$WORK/art-promote.json"
cp "$ART" "$MP_ART"  # reuse the fully-populated post-stage-1 artifact

# MP-1: --set-json human_confirmation=null succeeds (schema accepts null).
if "$TOOLS/artifact-patch.py" --path "$MP_ART" --finding-id F006 \
        --set-json human_confirmation=null >/dev/null 2>&1; then
    pass "MP-1 (§27.3): --set-json human_confirmation=null accepted"
else
    fail "MP-1: --set-json human_confirmation=null should succeed"
fi

# MP-2: --set-json human_confirmation=<valid object> succeeds.
MP_HC_VALID=$(jq -nc '{
    reviewer: "tester@example.com",
    reason:   "smoke test promotion",
    ts:       "2026-04-18T12:00:00Z",
    promoted_from: {disposition:"uncertain", actionability:"report_only", score_phase4:48}
}')
if "$TOOLS/artifact-patch.py" --path "$MP_ART" --finding-id F006 \
        --set-json "human_confirmation=$MP_HC_VALID" >/dev/null 2>&1; then
    pass "MP-2 (§27.3): --set-json human_confirmation=<valid object> accepted"
else
    fail "MP-2: --set-json with valid human_confirmation object should succeed"
fi

# MP-3: incomplete human_confirmation (missing promoted_from) rejected.
# Top-level schema is anyOf: [null, <object-with-required-fields>]; jsonschema
# reports "is not valid under any of the given schemas" with the field path
# ($findings[N].human_confirmation) rather than naming the specific missing
# sub-field. Grep on the field path — specific enough to prove the rejection
# is about this field and not, say, a typo elsewhere.
MP_HC_BAD=$(jq -nc '{reviewer: "x", reason: "y", ts: "2026-04-18T12:00:00Z"}')
mp3_stderr=$("$TOOLS/artifact-patch.py" --path "$MP_ART" --finding-id F006 \
        --set-json "human_confirmation=$MP_HC_BAD" 2>&1 >/dev/null); mp3_code=$?
if [[ "$mp3_code" != "0" ]] && echo "$mp3_stderr" | grep -q "human_confirmation"; then
    pass "MP-3 (§27.3): incomplete human_confirmation (missing promoted_from) rejected"
else
    fail "MP-3: expected non-zero + 'human_confirmation' in stderr; code=$mp3_code stderr=$mp3_stderr"
fi

# MP-4: F006 is NOT in Phase 8 eligible set at baseline — architecture impact_type
# fails the lane filter, score 48 fails the 60-threshold, and no human_confirmation
# to bypass. Asserts the unpromoted path (the failure case the bypass is designed
# to rescue). Uses the same jq as 09-fix-execution.md step 8.1.
MP_BASELINE="$WORK/art-promote-baseline.json"
cp "$ART" "$MP_BASELINE"  # fresh copy, no MP-2 mutation
mp4_ids=$(jq -r --argjson thr 60 '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
     | select(
         (.human_confirmation != null)
         or (
           (.impact_type == "correctness" or .impact_type == "security")
           and (.score_phase4 != null and .score_phase4 >= $thr)
         )
       )
     | .id
    ] | join(",")
' "$MP_BASELINE")
if [[ ",$mp4_ids," != *,F006,* ]]; then
    pass "MP-4 (§5.2.1, §13.1): unpromoted F006 (architecture, score=48, uncertain) is NOT Phase-8-eligible"
else
    fail "MP-4: F006 should be ineligible without human_confirmation; got ids=$mp4_ids"
fi

# MP-5: after promoting F006 (disposition=confirmed_mechanical + actionability=auto_fixable +
# human_confirmation set), the same Phase 8 selector DOES include it. Tests the bypass.
MP_PROMOTED="$WORK/art-promote-done.json"
cp "$ART" "$MP_PROMOTED"
"$TOOLS/artifact-patch.py" --path "$MP_PROMOTED" --finding-id F006 \
    --set disposition=confirmed_mechanical \
    --set actionability=auto_fixable \
    --set-json "human_confirmation=$MP_HC_VALID" >/dev/null 2>&1 \
    || fail "MP-5 setup: promote patch failed"
mp5_ids=$(jq -r --argjson thr 60 '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
     | select(
         (.human_confirmation != null)
         or (
           (.impact_type == "correctness" or .impact_type == "security")
           and (.score_phase4 != null and .score_phase4 >= $thr)
         )
       )
     | .id
    ] | join(",")
' "$MP_PROMOTED")
if [[ ",$mp5_ids," == *,F006,* ]]; then
    pass "MP-5 (§5.2.1, §13.1, §27.6): promoted F006 IS Phase-8-eligible (bypass works)"
else
    fail "MP-5: F006 should be eligible after promotion; got ids=$mp5_ids"
fi

# MP-6: renderer output contains "(human-confirmed)" somewhere after promotion.
# F006 is light-lane so it lands in render_light_lane; the helper inserts the tag
# in both deep and light lane tables, so this also exercises _claim_with_promotion.
MP_MD="$WORK/art-promote-done.md"
"$TOOLS/artifact-render.py" --input "$MP_PROMOTED" --output "$MP_MD" \
    || fail "MP-6 setup: render failed"
if grep -q "(human-confirmed)" "$MP_MD"; then
    pass "MP-6 (§7, §27.7): rendered artifact.md shows (human-confirmed) tag on promoted finding"
else
    fail "MP-6: '(human-confirmed)' tag missing from rendered output"
fi

# MP-7: schema accepts human_confirmation with non-empty fix_hint string. Covers
# the §27.3 / schema rev-adding-fix_hint path — this is the on-disk shape
# /adamsreview:promote --fix-hint "..." produces after step 5's jq build.
MP_HC_WITH_HINT=$(jq -nc '{
    reviewer: "tester@example.com",
    reason:   "promote with steering",
    ts:       "2026-04-19T12:00:00Z",
    promoted_from: {disposition:"uncertain", actionability:"report_only", score_phase4:48},
    fix_hint: "Update the docstring to match the code; do not modify the code."
}')
MP_ART_HINT="$WORK/art-promote-hint.json"
cp "$ART" "$MP_ART_HINT"
if "$TOOLS/artifact-patch.py" --path "$MP_ART_HINT" --finding-id F006 \
        --set disposition=confirmed_mechanical \
        --set actionability=auto_fixable \
        --set-json "human_confirmation=$MP_HC_WITH_HINT" >/dev/null 2>&1; then
    pass "MP-7 (§27.3, schema): human_confirmation with non-empty fix_hint accepted"
else
    fail "MP-7: human_confirmation with fix_hint should succeed"
fi

# MP-8: empty-string fix_hint rejected (schema minLength: 1 on the non-null branch).
# Null or absent are both fine; empty-string is not. Guards the invariant that
# "absent == no hint" — callers should omit the key, not pass "".
MP_HC_EMPTY_HINT=$(jq -nc '{
    reviewer: "tester@example.com",
    reason:   "x",
    ts:       "2026-04-19T12:00:00Z",
    promoted_from: {disposition:"uncertain", actionability:"report_only", score_phase4:48},
    fix_hint: ""
}')
mp8_stderr=$("$TOOLS/artifact-patch.py" --path "$MP_ART" --finding-id F006 \
        --set-json "human_confirmation=$MP_HC_EMPTY_HINT" 2>&1 >/dev/null); mp8_code=$?
if [[ "$mp8_code" != "0" ]] && echo "$mp8_stderr" | grep -q "human_confirmation"; then
    pass "MP-8 (§27.3, schema): empty-string fix_hint rejected (minLength: 1)"
else
    fail "MP-8: expected non-zero + 'human_confirmation' in stderr; code=$mp8_code stderr=$mp8_stderr"
fi

# MP-9: renderer emits "**Fix direction:**" when fix_hint is set. Uses the same
# rendering path MP-6 exercises; this catches the new _finding_detail branch.
MP_MD_HINT="$WORK/art-promote-hint.md"
"$TOOLS/artifact-render.py" --input "$MP_ART_HINT" --output "$MP_MD_HINT" \
    || fail "MP-9 setup: render failed"
if grep -q "Fix direction:.*Update the docstring" "$MP_MD_HINT"; then
    pass "MP-9 (§7, §27.7): rendered artifact.md shows Fix direction line when fix_hint is set"
else
    fail "MP-9: '**Fix direction:**' line missing from rendered output with fix_hint"
fi

# MP-10: renderer does NOT emit "**Fix direction:**" when fix_hint is absent.
# Reuses MP-6's MP_MD (rendered from MP_PROMOTED, whose human_confirmation has
# no fix_hint). Guards against an accidental unconditional emit.
if ! grep -q "Fix direction:" "$MP_MD"; then
    pass "MP-10 (§7, §27.7): rendered artifact.md omits Fix direction line when fix_hint is absent"
else
    fail "MP-10: 'Fix direction:' should NOT appear when fix_hint is absent"
fi

# ---------------------------------------------------------------- walkthrough
#
# WT-* cover the /adamsreview:walkthrough command surface. WT-1..WT-4 exercise
# the scope-filter jq (the inverse of 09-fix-execution.md step 8.1); WT-5 is a
# structural check on /adamsreview:promote's --defer-publish + shared-fragment
# wiring. The scope jq MUST stay in sync with Phase 8 eligibility — any drift
# surfaces here.

PROMOTE_MD="$REPO/commands/promote.md"
PROMOTE_CORE_MD="$REPO/fragments/promote-core.md"

# WT-0: promote-core precondition PROCEEDS (not no-op) for confirmed_mechanical +
# curr_hc == null. Pre-existing-bug guard: a blanket no-op on that row silently
# broke promoting light-lane findings and deep-lane below-threshold findings
# (§27.2, §27.6). If a future edit re-adds the no-op language, this surfaces.
# Checks: (a) the precondition table contains a **Proceed.** verdict on the
# confirmed_mechanical + curr_hc == null row, (b) it does NOT contain the old
# "already confirmed_mechanical by validator" no-op text.
if grep -q '`confirmed_mechanical` | `curr_hc == null` | \*\*Proceed' "$PROMOTE_CORE_MD" \
   && ! grep -q "already confirmed_mechanical by validator.*no-op" "$PROMOTE_CORE_MD"; then
    pass "WT-0 (§27.2, §27.6): promote-core precondition proceeds for confirmed_mechanical + no human_confirmation"
else
    fail "WT-0: promote-core.md missing 'Proceed' verdict or still has blanket no-op for confirmed_mechanical + no hc"
fi

# The walkthrough scope-filter jq — must stay in sync with the expression in
# commands/walkthrough.md §3. Held as a shell variable so the
# assertions below can exercise it against different fixtures without drift.
# NOTE: pre_existing_report findings are excluded from scope_full_ids — they
# are routed exclusively to §6.5 issue filing, never walked for promotion.
WT_SCOPE_JQ='
[.findings[]
 | select(.current_state == "open")
 | select(.disposition != "resolved")
 | select(.disposition != "disproven")
 | select(.disposition != "pending_validation")
 | select(.disposition != "pre_existing_report")
 | select(.human_confirmation == null)
 | select(
     (
       (.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
       and (
         (.impact_type == "correctness" or .impact_type == "security")
         and (.score_phase4 != null and .score_phase4 >= $thr)
       )
     ) | not
   )
 | .id
] | join(",")
'

# WT fixture builder. Accepts a findings[] JSON array on stdin; emits a minimal
# artifact stub that passes just enough of the schema's top-level requirements
# for the jq filter to run against. Only .findings is queried, so we don't need
# a full schema-valid seed.
wt_build_fixture() {
    local findings_json="$1"
    jq -nc --argjson findings "$findings_json" '{findings: $findings}'
}

# Shared finding templates — varying only the fields the scope filter inspects.
# All other fields stubbed with plausible defaults; the scope jq ignores them.
wt_finding() {
    # args: id impact_type validation_lane disposition score_phase4 current_state human_confirmation
    jq -nc \
        --arg id "$1" \
        --arg impact "$2" \
        --arg lane "$3" \
        --arg disp "$4" \
        --arg score "$5" \
        --arg state "$6" \
        --arg hc "$7" \
        '{
            id: $id,
            impact_type: $impact,
            validation_lane: $lane,
            disposition: $disp,
            score_phase4: (if $score == "null" then null else ($score | tonumber) end),
            current_state: $state,
            human_confirmation: (if $hc == "null" then null else ($hc | fromjson) end)
        }'
}

WT_HC='{"reviewer":"x","reason":"y","ts":"2026-04-19T00:00:00Z","promoted_from":{"disposition":"uncertain","actionability":"manual","score_phase4":null}}'

# WT-1: resolved / disproven / pending_validation findings are excluded.
# Fixture includes one of each terminal/unused disposition plus one in-scope
# finding (uncertain) to prove the filter isn't dropping everything.
wt1_findings=$(jq -nc \
    --argjson a "$(wt_finding W001 correctness deep resolved 80 resolved null)" \
    --argjson b "$(wt_finding W002 correctness deep disproven 70 open null)" \
    --argjson c "$(wt_finding W003 correctness deep pending_validation null open null)" \
    --argjson d "$(wt_finding W004 correctness deep uncertain 55 open null)" \
    '[$a,$b,$c,$d]')
wt1_fx=$(wt_build_fixture "$wt1_findings")
wt1_ids=$(echo "$wt1_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt1_ids" == "W004" ]]; then
    pass "WT-1 (§28, plans/walkthrough-mode.md §3.5): scope excludes resolved/disproven/pending_validation"
else
    fail "WT-1: expected W004 only; got '$wt1_ids'"
fi

# WT-2: already-promoted findings (human_confirmation != null) are excluded
# so a partially-walked session resumes cleanly without re-surfacing them.
wt2_findings=$(jq -nc \
    --argjson a "$(wt_finding W010 architecture light uncertain 40 open "$WT_HC")" \
    --argjson b "$(wt_finding W011 architecture light uncertain 40 open null)" \
    '[$a,$b]')
wt2_fx=$(wt_build_fixture "$wt2_findings")
wt2_ids=$(echo "$wt2_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt2_ids" == "W011" ]]; then
    pass "WT-2 (§28, §27.6): scope excludes already-promoted findings (human_confirmation set)"
else
    fail "WT-2: expected W011 only; got '$wt2_ids'"
fi

# WT-3: findings the Phase 8 gate would ALREADY pass (correctness/security +
# score >= threshold + confirmed_mechanical/partial/regression) are excluded — the
# walkthrough's purpose is to surface what fix SKIPS. Fixture: deep/correctness
# confirmed_mechanical at score=80 should NOT appear.
wt3_findings=$(jq -nc \
    --argjson a "$(wt_finding W020 correctness deep confirmed_mechanical 80 open null)" \
    --argjson b "$(wt_finding W021 correctness deep confirmed_manual 80 open null)" \
    '[$a,$b]')
wt3_fx=$(wt_build_fixture "$wt3_findings")
wt3_ids=$(echo "$wt3_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt3_ids" == "W021" ]]; then
    pass "WT-3 (§28, §13.1): scope excludes fix-eligible findings (correctness confirmed_mechanical >= threshold)"
else
    fail "WT-3: expected W021 only; got '$wt3_ids'"
fi

# WT-4: light-lane confirmed_mechanical findings (which fail the impact_type gate)
# ARE included — this is the primary gap the walkthrough exists to close.
# Fixture: ux confirmed_mechanical at high score (which the fix command would skip
# due to impact_type != correctness/security) plus a below-threshold correctness
# confirmed_mechanical (which the fix command would skip due to the score gate).
wt4_findings=$(jq -nc \
    --argjson a "$(wt_finding W030 ux light confirmed_mechanical 80 open null)" \
    --argjson b "$(wt_finding W031 policy light confirmed_mechanical 50 open null)" \
    --argjson c "$(wt_finding W032 correctness deep confirmed_mechanical 40 open null)" \
    '[$a,$b,$c]')
wt4_fx=$(wt_build_fixture "$wt4_findings")
wt4_ids=$(echo "$wt4_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
# Order in jq output depends on array order, not a sort, so match any permutation.
if [[ ",$wt4_ids," == *,W030,* && ",$wt4_ids," == *,W031,* && ",$wt4_ids," == *,W032,* ]] \
   && [[ $(echo "$wt4_ids" | awk -F, '{print NF}') == "3" ]]; then
    pass "WT-4 (§28, §13.2): scope includes light-lane confirmed_mechanical + below-threshold deep confirmed_mechanical"
else
    fail "WT-4: expected W030,W031,W032 (any order); got '$wt4_ids'"
fi

# WT-6: /adamsreview:walkthrough decisions-log template contains the required
# structural markers. Since the markdown is rendered inline by Claude at
# runtime (the command file is a prompt, not a shell script), this is a
# template-integrity check — guards against accidental removal of any
# section so the posted PR comment stays auditable.
WALK_MD="$REPO/commands/walkthrough.md"
if grep -q 'adams-review-walkthrough-v1' "$WALK_MD" \
   && grep -q '### Walkthrough decisions' "$WALK_MD" \
   && grep -q '#### Promoted' "$WALK_MD" \
   && grep -q '#### Skipped' "$WALK_MD" \
   && grep -q '#### Stopped' "$WALK_MD" \
   && grep -q 'human_confirmation.* bypass' "$WALK_MD"; then
    pass "WT-6 (§28.7): walkthrough decisions-log template has marker + Promoted/Skipped/Stopped sections"
else
    fail "WT-6: walkthrough decisions-log template missing required sections in $WALK_MD"
fi

# WT-5: /adamsreview:promote wires --defer-publish and includes promote-core.md.
# Structural check guarding against accidental removal of either piece (plans/
# walkthrough-mode.md §5, §6). If a future refactor merges the shared fragment
# back inline or drops the --defer-publish flag, this assertion surfaces it
# before the walkthrough command breaks.
if grep -q -- '--defer-publish' "$PROMOTE_MD" \
   && grep -q 'defer_publish.*true' "$PROMOTE_MD" \
   && grep -q 'promote-core.md' "$PROMOTE_MD"; then
    pass "WT-5 (§27, §28): promote command wires --defer-publish guards + includes promote-core fragment"
else
    fail "WT-5: --defer-publish or promote-core include missing from $PROMOTE_MD"
fi

# WT-7: the "Qualifying" scope jq (step 3 of walkthrough) must additionally
# exclude below_gate (which the full scope keeps for the reviewer who wants
# to audit Phase-3-demoted findings). BOTH the full and qualifying scopes
# exclude pre_existing_report — those are routed only to §6.5 issue filing
# and are never walked for promotion. Mirrors the second jq in
# commands/walkthrough.md; keep in sync when that file changes.
WT_QUALIFYING_JQ='
[.findings[]
 | select(.current_state == "open")
 | select(.disposition != "resolved")
 | select(.disposition != "disproven")
 | select(.disposition != "pending_validation")
 | select(.disposition != "below_gate")
 | select(.disposition != "pre_existing_report")
 | select(.human_confirmation == null)
 | select(
     (
       (.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
       and (
         (.impact_type == "correctness" or .impact_type == "security")
         and (.score_phase4 != null and .score_phase4 >= $thr)
       )
     ) | not
   )
 | .id
] | join(",")
'
wt7_findings=$(jq -nc \
    --argjson a "$(wt_finding W050 correctness deep below_gate null open null)" \
    --argjson b "$(wt_finding W051 correctness deep pre_existing_report null open null)" \
    --argjson c "$(wt_finding W052 ux light confirmed_mechanical 80 open null)" \
    --argjson d "$(wt_finding W053 correctness deep uncertain 55 open null)" \
    '[$a,$b,$c,$d]')
wt7_fx=$(wt_build_fixture "$wt7_findings")
wt7_full=$(echo "$wt7_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
wt7_qual=$(echo "$wt7_fx" | jq -r --argjson thr 60 "$WT_QUALIFYING_JQ")
# Full scope includes below_gate (W050) but excludes pre_existing_report (W051)
# — pre-existing is routed only to §6.5. Qualifying additionally excludes
# below_gate (W050).
if [[ ",$wt7_full," == *,W050,* && ",$wt7_full," != *,W051,* && ",$wt7_full," == *,W052,* && ",$wt7_full," == *,W053,* ]] \
   && [[ ",$wt7_qual," != *,W050,* && ",$wt7_qual," != *,W051,* ]] \
   && [[ ",$wt7_qual," == *,W052,* && ",$wt7_qual," == *,W053,* ]]; then
    pass "WT-7 (§28 §3): full scope excludes pre_existing_report but keeps below_gate; qualifying excludes both"
else
    fail "WT-7: full='$wt7_full' qual='$wt7_qual' (expected full=W050,W052,W053; qual=W052,W053)"
fi

# WT-8: the pre-existing isolation jq (step 3, third expression) must
# select only open, non-promoted pre_existing_report findings.
WT_PREEXISTING_JQ='
[.findings[]
 | select(.current_state == "open")
 | select(.disposition == "pre_existing_report")
 | select(.human_confirmation == null)
 | .id
] | join(",")
'
wt8_findings=$(jq -nc \
    --argjson a "$(wt_finding W060 correctness deep pre_existing_report null open null)" \
    --argjson b "$(wt_finding W061 correctness deep pre_existing_report null open "$WT_HC")" \
    --argjson c "$(wt_finding W062 correctness deep below_gate null open null)" \
    '[$a,$b,$c]')
wt8_fx=$(wt_build_fixture "$wt8_findings")
wt8_ids=$(echo "$wt8_fx" | jq -r "$WT_PREEXISTING_JQ")
if [[ "$wt8_ids" == "W060" ]]; then
    pass "WT-8 (§28 §3): pre-existing scope isolates only open, non-promoted pre_existing_report findings"
else
    fail "WT-8: expected W060 only; got '$wt8_ids'"
fi

# WT-9: preflight (§4) presents the three-tier AskUserQuestion and the
# terminology preamble naming all three gates. Template-integrity check.
if grep -q 'Qualifying only' "$WALK_MD" \
   && grep -q 'Full skip set' "$WALK_MD" \
   && grep -q 'Cancel' "$WALK_MD" \
   && grep -q 'Phase 3 scoring gate' "$WALK_MD" \
   && grep -q 'Phase 4 confirmation gate' "$WALK_MD" \
   && grep -q 'Phase 8 fix gate' "$WALK_MD" \
   && grep -q 'scope_qualifying_ids' "$WALK_MD" \
   && grep -q 'scope_full_ids' "$WALK_MD" \
   && grep -q 'scope_preexisting_ids' "$WALK_MD"; then
    pass "WT-9 (§28 §4): preflight has three-tier choice + gate-terminology preamble + three scope variables"
else
    fail "WT-9: preflight tier options or gate preamble missing from $WALK_MD"
fi

# WT-10: pre-existing issue filing (§6.5) + decisions-log subsection are
# wired. Template-integrity check.
if grep -q '### 6.5' "$WALK_MD" \
   && grep -q 'gh issue create' "$WALK_MD" \
   && grep -q 'issues_filed' "$WALK_MD" \
   && grep -q '#### Pre-existing issues filed' "$WALK_MD" \
   && grep -q 'pre_existing_issue_draft' "$WALK_MD"; then
    pass "WT-10 (§28 §6.5, §7.1): pre-existing issue filing + decisions-log subsection wired"
else
    fail "WT-10: step 6.5 or decisions-log 'Pre-existing issues filed' subsection missing from $WALK_MD"
fi

# WT-11: briefer prompt (§5.2) tells the agent to propose best-effort
# hints for confirmed_manual/confirmed_report. Template-integrity check.
if grep -q 'confirmed_manual.*confirmed_report' "$WALK_MD" \
   || grep -q 'confirmed_manual` and `confirmed_report' "$WALK_MD"; then
    pass "WT-11 (§28 §5.2): briefer prompt addresses confirmed_manual + confirmed_report findings"
else
    fail "WT-11: briefer prompt missing confirmed_manual/confirmed_report clause in $WALK_MD"
fi

# ------------------------------------------------------------------ Stage 2.6.D
# Line-range sanity filter at Phase 1 join. line-range-check.sh rejects
# candidates whose line_range[1] overshoots the file's actual length at
# $reviewed_sha, catches missing-file references, and passes through the
# Phase 1.5 "(unknown)" sentinel. Addresses the L5-ux hallucination
# observed on the ray-finance 2026-04-19 run (ranges 1815-1826 in a
# 1042-line file).
#
# Reuses the OC_DIR git fixture so file_a.py (4 lines) + file_b.py
# (2 lines) provide concrete upper bounds to overshoot.

# LR-1: valid in-range candidate is passed through unchanged.
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["L1-diff-local"],"file":"file_a.py","line_range":[1,4]}]') \
    2> "$WORK/lr1.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "1" ]] && [[ ! -s "$WORK/lr1.err" ]]; then
    pass "LR-1: in-range candidate passes through unchanged (no audit stderr)"
else
    fail "LR-1: expected 1 kept and empty stderr; got kept=$kept stderr=$(cat "$WORK/lr1.err")"
fi

# LR-2: hallucinated range (99-100 on 4-line file_a.py) is dropped with
# the lens_hallucinated_line_range trace tag on stderr.
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["L5-ux"],"file":"file_a.py","line_range":[99,100]}]') \
    2> "$WORK/lr2.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "0" ]] \
    && grep -q 'lens_hallucinated_line_range:' "$WORK/lr2.err" \
    && grep -q 'source=L5-ux' "$WORK/lr2.err" \
    && grep -q 'actual_lines=4' "$WORK/lr2.err"; then
    pass "LR-2: overshot range dropped with lens_hallucinated_line_range + source + actual_lines"
else
    fail "LR-2: expected 0 kept + hallucinated-range trace; got kept=$kept stderr=$(cat "$WORK/lr2.err")"
fi

# LR-3: file=="(unknown)" (Phase 1.5 external-scrape sentinel) passes
# through without any audit stderr.
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["external-pr:coderabbitai"],"file":"(unknown)","line_range":[1,1]}]') \
    2> "$WORK/lr3.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "1" ]] && [[ ! -s "$WORK/lr3.err" ]]; then
    pass "LR-3: file=='(unknown)' sentinel passes through with no audit stderr"
else
    fail "LR-3: expected 1 kept and empty stderr; got kept=$kept stderr=$(cat "$WORK/lr3.err")"
fi

# LR-5: a file without a trailing newline must NOT produce false-
# positive drops at its last visible line. The helper counts records
# via `awk 'END{print NR}'` (not `wc -l`, which counts newlines and
# would undercount by 1 on no-EOL files).
(
    cd "$OC_DIR/repo"
    printf 'line1\nline2\nline3' > file_no_nl.py   # 3 lines, NO trailing newline
    git add file_no_nl.py
    git commit --quiet -m "add no-trailing-newline fixture"
)
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["L1-diff-local"],"file":"file_no_nl.py","line_range":[1,3]}]') \
    2> "$WORK/lr5.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "1" ]] && [[ ! -s "$WORK/lr5.err" ]]; then
    pass "LR-5: no-trailing-newline file — range to last line passes through (awk NR counts records, not newlines)"
else
    fail "LR-5: expected 1 kept + empty stderr for no-EOL file range [1,3]; got kept=$kept stderr=$(cat "$WORK/lr5.err")"
fi

# LR-4: file missing at $reviewed_sha is dropped with the
# lens_referenced_missing_file trace tag.
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["L5-ux"],"file":"does_not_exist.py","line_range":[1,1]}]') \
    2> "$WORK/lr4.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "0" ]] \
    && grep -q 'lens_referenced_missing_file:' "$WORK/lr4.err" \
    && grep -q 'file=does_not_exist.py' "$WORK/lr4.err"; then
    pass "LR-4: missing file dropped with lens_referenced_missing_file trace tag"
else
    fail "LR-4: expected 0 kept + missing-file trace; got kept=$kept stderr=$(cat "$WORK/lr4.err")"
fi

# LR-6: fragments/01-detection.md §1.2.1 shared-invariants blockquote
# carries the file-absolute + in-bounds + hunk-header prohibition for
# `line_range`. Prompt-level guard against the L5-ux classification from
# GH #2 (P3) where lenses copied hunk-header numbers verbatim and
# produced out-of-bounds ranges. The invariant lives inside the shared
# blockquote (dispatched to every lens sub-agent), not lens-specific.
DETECT_MD_LR6="$REPO/fragments/01-detection.md"
lr6_missing=()
for phrase in \
    '`line_range` must be file-absolute' \
    "the file's total line count" \
    'Do not copy the numbers inside unified-' \
    '@@ -a,b +c,d @@'; do
    if ! grep -qF "$phrase" "$DETECT_MD_LR6"; then
        lr6_missing+=("$phrase")
    fi
done
if [[ ${#lr6_missing[@]} -eq 0 ]]; then
    pass "LR-6: §1.2.1 line_range invariant requires file-absolute + hunk-header prohibition (P3, GH #2)"
else
    fail "LR-6: missing §1.2.1 invariant phrases: ${lr6_missing[*]}"
fi

# ------------------------------------------------------------------ Stage 2.6.E
# Polish / below-gate cluster renderer section. Dense runs of below_gate
# findings in one area are hidden by default (Phase 3 parks them so the
# report stays skimmable), but ≥3 within a 100-line window is its own
# signal — surface them in a dedicated section with a cluster label so
# a reviewer can spot what the pipeline filtered out.

PC_DIR="$WORK/polish-clusters"
mkdir -p "$PC_DIR"

# Template for a below_gate finding; overrides via jq at call site.
PC_TMPL='{"id":"F101","sources":["L5-ux"],"source_families":["ux-family"],"impact_type":"ux","origin":"introduced_by_pr","origin_confidence":"low","actionability":"manual","validation_lane":"light","current_state":"open","disposition":"below_gate","is_actionable":false,"reason":null,"confirmed_strength":null,"file":"src/cli/commands.ts","line_range":[920,920],"claim":"Net worth formatting mismatch","score_phase3":30,"score_phase4":null,"score_history":[{"phase":"phase_3","score":30}],"validation_result":null,"fix_attempts":[],"introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}'

jq '.findings = []' "$FIX/artifact-seed.json" > "$PC_DIR/base.json"

# PC-1: 3 below_gate findings in one file, spanning 97 lines
# (920, 960, 1017). ≤ 100 → cluster → section emitted.
f1=$(echo "$PC_TMPL" | jq '.id="F101"|.line_range=[920,920]|.claim="nit-a"')
f2=$(echo "$PC_TMPL" | jq '.id="F102"|.line_range=[960,960]|.claim="nit-b"')
f3=$(echo "$PC_TMPL" | jq '.id="F103"|.line_range=[1017,1017]|.claim="nit-c"')
jq --argjson a "$f1" --argjson b "$f2" --argjson c "$f3" \
    '.findings=[$a,$b,$c]|.review_id="rev_pc1"' "$PC_DIR/base.json" > "$PC_DIR/pc1.json"
"$TOOLS/artifact-render.py" --input "$PC_DIR/pc1.json" --output "$PC_DIR/pc1.md" >/dev/null
if grep -q '## Polish — below threshold, clustered' "$PC_DIR/pc1.md" \
    && grep -q '| F101 |' "$PC_DIR/pc1.md" \
    && grep -q '| F102 |' "$PC_DIR/pc1.md" \
    && grep -q '| F103 |' "$PC_DIR/pc1.md"; then
    pass "PC-1 (§7): polish-cluster section emitted for 3+ below_gate in 100-line window"
else
    fail "PC-1: expected polish-cluster section with F101/F102/F103; got:\n$(cat "$PC_DIR/pc1.md")"
fi

# PC-2: 3 below_gate findings in same file but spanning > 100 lines.
# No sliding window of size ≥3 fits → no cluster → no section.
f1=$(echo "$PC_TMPL" | jq '.id="F201"|.line_range=[100,100]')
f2=$(echo "$PC_TMPL" | jq '.id="F202"|.line_range=[250,250]')
f3=$(echo "$PC_TMPL" | jq '.id="F203"|.line_range=[500,500]')
jq --argjson a "$f1" --argjson b "$f2" --argjson c "$f3" \
    '.findings=[$a,$b,$c]|.review_id="rev_pc2"' "$PC_DIR/base.json" > "$PC_DIR/pc2.json"
"$TOOLS/artifact-render.py" --input "$PC_DIR/pc2.json" --output "$PC_DIR/pc2.md" >/dev/null
if ! grep -q 'Polish — below threshold' "$PC_DIR/pc2.md"; then
    pass "PC-2 (§7): polish-cluster section omitted when 3 findings span > 100 lines in same file"
else
    fail "PC-2: section should be absent; got:\n$(cat "$PC_DIR/pc2.md")"
fi

# PC-3: only 2 below_gate findings, densely clustered. < 3 → no section.
f1=$(echo "$PC_TMPL" | jq '.id="F301"|.line_range=[100,100]')
f2=$(echo "$PC_TMPL" | jq '.id="F302"|.line_range=[110,110]')
jq --argjson a "$f1" --argjson b "$f2" \
    '.findings=[$a,$b]|.review_id="rev_pc3"' "$PC_DIR/base.json" > "$PC_DIR/pc3.json"
"$TOOLS/artifact-render.py" --input "$PC_DIR/pc3.json" --output "$PC_DIR/pc3.md" >/dev/null
if ! grep -q 'Polish — below threshold' "$PC_DIR/pc3.md"; then
    pass "PC-3 (§7): polish-cluster section omitted when fewer than 3 below_gate findings (even dense)"
else
    fail "PC-3: section should be absent; got:\n$(cat "$PC_DIR/pc3.md")"
fi

# ------------------------------------------------------------------ Phase 4 validator hardening
# VR-* assertions cover the read-only preamble + fix-scope cross-check + post-wave
# tree-cleanliness sweep added to 05-validation.md after the ray-finance 2026-04-19
# run surfaced a validator that edited the working tree (F027) and two class-of-bug
# misses whose prior fixes had scoped only to the obvious site (F032 ← F011,
# F034 ← F037).
VALIDATION_MD="$REPO/fragments/05-validation.md"

# VR-1: Phase 4a + 4b validator prompts contain a read-only preamble forbidding
# Edit/Write. Prevents a repeat of the F027 incident where an Opus validator
# modified src/cli/commands.ts and the orchestrator had to inline-revert with
# no formal guardrail.
if grep -qF '**Read-only.**' "$VALIDATION_MD" \
    && grep -qF 'Do not use `Edit` or `Write`' "$VALIDATION_MD" \
    && [[ "$(grep -cF '**Read-only.**' "$VALIDATION_MD")" -ge 2 ]]; then
    pass "VR-1 (§19.5/§19.6): Phase 4a + 4b validator prompts contain read-only preamble"
else
    fail "VR-1: read-only preamble missing from one or both validator prompts in $VALIDATION_MD"
fi

# VR-2: Phase 4a validator prompt step 4 requires cross-checking
# blast_radius.parallel_paths + grepping for in-repo precedent before
# finalizing fix_proposal. Addresses the class-vs-instance gap.
if grep -qF 'blast_radius.parallel_paths' "$VALIDATION_MD" \
    && grep -qF 'in-repo precedent' "$VALIDATION_MD" \
    && grep -qF 'the full class' "$VALIDATION_MD"; then
    pass "VR-2 (§19.5): validator prompt step 4 requires parallel-path cross-check + precedent grep"
else
    fail "VR-2: class-not-instance fix-scope rule missing from $VALIDATION_MD"
fi

# VR-3: Post-wave tree-cleanliness sweep present as belt-and-braces for VR-1.
# If a validator ignores the read-only preamble, the sweep reverts the tree
# before Phase 5 and logs the incident to trace.md under phase_4_tree_dirty_reverted.
if grep -qF 'phase_4_tree_dirty_reverted' "$VALIDATION_MD" \
    && grep -qF 'status --porcelain' "$VALIDATION_MD"; then
    pass "VR-3 (§4.4.5): post-wave tree-cleanliness sweep present with phase_4_tree_dirty_reverted trace tag"
else
    fail "VR-3: tree-cleanliness sweep missing from $VALIDATION_MD"
fi

# ------------------------------------------------------------------ Phase 9a post-fix hardening
# PF-* assertions cover the premise audit + convention-drift sweep added to
# 10-post-fix-and-commit.md after the ray-finance feat/import-apple 2026-04-20
# ultrareview surfaced two bugs Phase 9a missed: a wrong COALESCE direction
# justified by a false inline comment (bug_007, F021) and a new scoring loop
# whose bound drifted from every sibling scoring path in the codebase
# (bug_001, F023).
POSTFIX_MD="$REPO/fragments/10-post-fix-and-commit.md"

# PF-1: Phase 9a prompt step 5a — adjacent-regression sweep kept as the local
# ±20-lines same-file check. Split from the old combined step 5 so step 5b can
# own the cross-file convention drift case.
if grep -qF 'Adjacent-regression sweep (local)' "$POSTFIX_MD"; then
    pass "PF-1 (§19.9): Phase 9a prompt retains adjacent-regression sweep as step 5a"
else
    fail "PF-1: adjacent-regression sweep missing from $POSTFIX_MD"
fi

# PF-2: Phase 9a prompt step 5b(i) — validator-identified parallels cross-check.
# Uses blast_radius.parallel_paths and explicitly names the COALESCE-direction
# example from bug_007 so the check surface stays narrow and scannable.
if grep -qF 'Convention-drift sweep (cross-file)' "$POSTFIX_MD" \
    && grep -qF 'blast_radius.parallel_paths' "$POSTFIX_MD" \
    && grep -qF 'COALESCE(a, b)' "$POSTFIX_MD"; then
    pass "PF-2 (§19.9): Phase 9a prompt step 5b(i) cross-checks blast_radius.parallel_paths"
else
    fail "PF-2: convention-drift sweep (validator parallels) missing from $POSTFIX_MD"
fi

# PF-3: Phase 9a prompt step 5b(ii) — fix-introduced-siblings instruction.
# The *bug*/*fix* distinction is load-bearing: Phase 4 computes parallel_paths
# on the bug pattern, so new code the fix introduces needs independent sibling
# search. This closes the gap that let bug_001 (cleanupDerivedAfterRemove loop
# bound drifted from calculateDailyScore callers) past Phase 9a.
if grep -qF 'parallel_paths` was computed on the *bug*' "$POSTFIX_MD" \
    && grep -qF 'new parallels the validator didn' "$POSTFIX_MD"; then
    pass "PF-3 (§19.9): Phase 9a prompt step 5b(ii) flags fix-introduced new siblings"
else
    fail "PF-3: fix-introduced-siblings instruction missing from $POSTFIX_MD"
fi

# PF-4: Phase 9a prompt step 6 — premise audit of added inline comments.
# A wrong comment is worse than no comment because it propagates to future
# readers. Scoped to comments in the same hunk as a logic change so pre-existing
# comments are out of scope. This is what catches bug_007's false
# `// fresh INSERT leaves label NULL` justification.
if grep -qF 'Premise audit of added inline comments' "$POSTFIX_MD" \
    && grep -qF 'falsifiable claim' "$POSTFIX_MD" \
    && grep -qF 'same hunk as a logic change' "$POSTFIX_MD"; then
    pass "PF-4 (§19.9): Phase 9a prompt step 6 audits added inline-comment premises"
else
    fail "PF-4: premise audit missing from $POSTFIX_MD"
fi

# ------------------------------------------------------------------ assign-finding-ids --start-from
# AS-* assertions cover the --start-from flag added for /adamsreview:add (so
# new findings injected into an existing artifact continue the id sequence
# instead of colliding from F001). The default-no-flag behavior must remain
# F001..F0NN to keep Phase 1's pooled-candidate join unchanged.

# AS-1: default behavior preserved (no flag → F001..).
out=$(echo '[{"sources":["L1-diff-local"],"claim":"a"},{"sources":["L1-diff-local"],"claim":"b"}]' \
        | "$TOOLS/assign-finding-ids.sh" | jq -r '[.[].id] | join(",")')
if [[ "$out" == "F001,F002" ]]; then
    pass "AS-1: assign-finding-ids.sh default start emits F001,F002 (regression check)"
else
    fail "AS-1: expected F001,F002, got $out"
fi

# AS-2: --start-from F037 emits F037..
out=$(echo '[{"sources":["L1-diff-local"],"claim":"a"},{"sources":["L1-diff-local"],"claim":"b"},{"sources":["L1-diff-local"],"claim":"c"}]' \
        | "$TOOLS/assign-finding-ids.sh" --start-from F037 | jq -r '[.[].id] | join(",")')
if [[ "$out" == "F037,F038,F039" ]]; then
    pass "AS-2: --start-from F037 emits F037,F038,F039"
else
    fail "AS-2: expected F037,F038,F039, got $out"
fi

# AS-3: --start-from with bad value rejected with exit 64.
code=$(rc "$TOOLS/assign-finding-ids.sh" --start-from notF)
if [[ "$code" == "64" ]]; then
    pass "AS-3: --start-from with non-F<NNN> value rejected (exit 64)"
else
    fail "AS-3: expected exit 64, got $code"
fi

# ------------------------------------------------------------------ /adamsreview:add command
# RA-* assertions cover the structural shape of the new top-level command
# (commands/add.md). The command is a prose markdown file
# that Claude Code interprets — these assertions verify the load-bearing
# pieces are present, mirroring the VR-* / PF-* pattern for prompts that
# only an LLM can execute.
ADD_MD="$REPO/commands/add.md"

# RA-1: command file exists.
if [[ -f "$ADD_MD" ]]; then
    pass "RA-1: commands/add.md exists"
else
    fail "RA-1: commands/add.md missing"
fi

# RA-2: leftover-attempted hard abort present (mirrors Phase 7 step 4).
# Re-uses the same "attempted" detection + recovery message shape so a
# /adamsreview:fix run in flight cannot be silently extended by an add.
if grep -qF 'select(.current_state == "attempted")' "$ADD_MD" \
    && grep -qF 'leftover_ids' "$ADD_MD"; then
    pass "RA-2: leftover-attempted hard abort present (mirrors Phase 7)"
else
    fail "RA-2: leftover-attempted gate missing from $ADD_MD"
fi

# RA-3: --start-from wired through assign-finding-ids.sh so new findings
# continue past the highest existing F-id (the AS-2 helper assertion is
# the helper-side proof; this is the wiring proof).
if grep -qF 'assign-finding-ids.sh --start-from' "$ADD_MD"; then
    pass "RA-3: assign-finding-ids.sh --start-from wired into ID assignment"
else
    fail "RA-3: --start-from invocation missing from $ADD_MD"
fi

# RA-4: paste-mode normalizer Sonnet prompt present. Returns the
# standard candidate-array shape with origin_confidence: low and
# external-add-family family.
if grep -qF 'normalizing an externally-sourced code-review note' "$ADD_MD" \
    && grep -qF 'external-add-family' "$ADD_MD" \
    && grep -qF '"origin_confidence": "low"' "$ADD_MD"; then
    pass "RA-4: paste-normalizer prompt present (origin_confidence=low, external-add-family)"
else
    fail "RA-4: paste-normalizer prompt missing or malformed in $ADD_MD"
fi

# RA-5: one-direction dedup Sonnet prompt present. Each new candidate
# matches AT MOST ONE existing finding; existing findings are NOT
# compared against each other.
if grep -qF 'deduplicating new bug candidates' "$ADD_MD" \
    && grep -qF 'matches AT MOST ONE existing finding' "$ADD_MD" \
    && grep -qF 'NOT compared against each other' "$ADD_MD"; then
    pass "RA-5: dedup prompt present with one-direction matching constraint"
else
    fail "RA-5: dedup prompt missing or malformed in $ADD_MD"
fi

# RA-6: structured one-shot mode (--file/--line/--claim) builds a
# candidate inline without invoking the normalizer.
if grep -qF '"external-add:cli"' "$ADD_MD" \
    && grep -qF 'external-add-family' "$ADD_MD" \
    && grep -qF 'cli_file' "$ADD_MD" \
    && grep -qF 'cli_claim' "$ADD_MD"; then
    pass "RA-6: structured one-shot mode builds inline candidate (cli sources)"
else
    fail "RA-6: structured one-shot mode missing from $ADD_MD"
fi

# RA-7: re-render + re-publish to existing comment_id (so the new
# findings appear in the same PR comment, not a duplicate).
if grep -qF 'artifact-render.py' "$ADD_MD" \
    && grep -qF 'artifact-publish.sh' "$ADD_MD" \
    && grep -qF -e '--comment-id "$comment_id"' "$ADD_MD"; then
    pass "RA-7: re-render + re-publish to existing comment_id wired"
else
    fail "RA-7: render/publish flow missing from $ADD_MD"
fi

# RA-8: Phase 4 validation lane-aware with NO Wave 2 chain retry.
# Verifies the deep + light dispatch is present AND that the no-Wave-2
# constraint is documented in the deep validator prompt.
if grep -qF 'no Wave 2' "$ADD_MD" \
    && grep -qF 'deep validator' "$ADD_MD" \
    && grep -qF 'light confirmation validator' "$ADD_MD" \
    && grep -qF 'apply-decisions' "$ADD_MD"; then
    pass "RA-8: Phase 4 validation lane-aware, no Wave 2, --apply-decisions wired"
else
    fail "RA-8: Phase 4 dispatch incomplete in $ADD_MD"
fi

# PL-1: scripts/dev-run.sh exists and is executable. The old
# install.sh/uninstall.sh symlink flow is obsolete under the plugin
# runtime — Claude Code discovers commands from the plugin package
# directly. dev-run.sh is the plugin-author iteration wrapper.
if [[ -x "$REPO/scripts/dev-run.sh" ]]; then
    pass "PL-1: scripts/dev-run.sh exists and is executable"
else
    fail "PL-1: scripts/dev-run.sh missing or not executable"
fi

# PL-2: .claude-plugin/plugin.json is present and valid JSON. Required
# by the Claude Code plugin runtime; a malformed file silently prevents
# plugin load.
if [[ -f "$REPO/.claude-plugin/plugin.json" ]] \
    && jq empty "$REPO/.claude-plugin/plugin.json" >/dev/null 2>&1; then
    pass "PL-2: .claude-plugin/plugin.json present and valid JSON"
else
    fail "PL-2: .claude-plugin/plugin.json missing or invalid JSON"
fi

# RA-10: allowed-tools front-matter grants every Bash binary the command
# actually invokes. Catches the permissions-vs-usage drift class — e.g.
# a step using mktemp without a Bash(mktemp:*) grant would prompt the
# user mid-run instead of running cleanly. The check below pins the
# subset of binaries this command literally invokes; common shell
# builtins (echo, paste) are deliberately omitted to match the
# established pattern of relying on the user's global allowlist for
# those (see promote/walkthrough).
front=$(awk '/^---$/{c++; next} c==1{print}' "$ADD_MD")
missing=()
for tool in mktemp jq git awk grep mkdir rm tr cat printf date; do
    if ! echo "$front" | grep -qF "Bash($tool:"; then
        missing+=("$tool")
    fi
done
if [[ ${#missing[@]} -eq 0 ]]; then
    pass "RA-10: allowed-tools grants every Bash binary the command invokes"
else
    fail "RA-10: missing Bash grants for: ${missing[*]}"
fi

# RA-11: step 6's finding builder honors trivial_mode when deriving
# validation_lane, matching Phase 1's detection builder
# (01-detection.md §1.10). Without this, new findings added to a
# trivial-mode artifact would be stored as validation_lane=deep for
# correctness/security while the rest of the artifact is all-light,
# and artifact-render.py's lane-section filter would misplace them.
if grep -qF 'trivial_mode=$(jq -r ' "$ADD_MD" \
    && grep -qF -e '--argjson trivial "$trivial_mode"' "$ADD_MD" \
    && grep -qF 'if $trivial then "light"' "$ADD_MD"; then
    pass "RA-11: step 6 validation_lane honors trivial_mode (Phase 1 parity)"
else
    fail "RA-11: step 6 validation_lane missing trivial_mode branch in $ADD_MD"
fi

# RA-12: step 7.5 tree-cleanliness sweep is GATED on pre_validator_clean
# so the sweep does not clobber the user's own uncommitted work.
# /adamsreview:add has no clean-tree gate (§3.8 design decision) — if
# the user had dirty state going in, the sweep would revert it. The
# gate + skip-branch + distinct trace tag together prove the guard is
# wired correctly.
if grep -qF 'pre_validator_clean=true' "$ADD_MD" \
    && grep -qF 'pre_validator_clean=false' "$ADD_MD" \
    && grep -qF '"$pre_validator_clean" == "true"' "$ADD_MD" \
    && grep -qF 'add_tree_dirty_sweep_skipped' "$ADD_MD"; then
    pass "RA-12: step 7.5 sweep is gated on pre_validator_clean (preserves user work)"
else
    fail "RA-12: step 7.5 sweep guard missing or malformed in $ADD_MD"
fi

# RA-13: step 5 dedup guards against the sub-agent hallucinating a
# match_id that doesn't exist. The existing_ids_csv extraction + the
# hallucinated-trace-tag + the count/drop jq's membership check
# (.matches | IN($known[])) prevent a crash in the sources-merge
# pipeline when match_id is unknown.
if grep -qF 'existing_ids_csv=' "$ADD_MD" \
    && grep -qF 'add_dedup_hallucinated' "$ADD_MD" \
    && grep -qF '.matches | IN($known[])' "$ADD_MD"; then
    pass "RA-13: step 5 dedup has hallucinated-match_id guard"
else
    fail "RA-13: step 5 dedup hallucination guard missing from $ADD_MD"
fi

# ------------------------------------------------------------------ Stage 2.9
# prior-fix-diff.sh (§13.11b) — deterministic prior-fix suspect scan that
# feeds L2's prompt. Construct scratch repos, exercise every branch.
# Prefix is PFD-* (not PF-*) to avoid collision with the Post-Fix block
# above.

PFD_DIR="$WORK/prior-fix-diff"

# PFD-1: Empty prior-fix history. feat branch changes a line; no prior
# commit has fix-intent wording. Expect: empty output array.
mkdir -p "$PFD_DIR/r1"
(
    cd "$PFD_DIR/r1"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    git checkout --quiet -b feat
    printf 'a\nb\nCHANGED\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "change line 3"
)
out=$(cd "$PFD_DIR/r1" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]]; then
    pass "PFD-1 (§13.11b): no fix-intent commits in history → empty suspects array"
else
    fail "PFD-1: expected empty array; got length=$len out=$out"
fi

# PFD-2: Prior commit touches same lines but lacks fix-intent keywords.
mkdir -p "$PFD_DIR/r2"
(
    cd "$PFD_DIR/r2"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    printf 'a\nb\nc-refactored\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "refactor: tidy up phrasing"
    git checkout --quiet -b feat
    printf 'a\nb\nc-broadened\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "broaden line 3"
)
out=$(cd "$PFD_DIR/r2" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]]; then
    pass "PFD-2 (§13.11b): prior commit with non-fix-intent message filtered out"
else
    fail "PFD-2: expected empty array; got length=$len out=$out"
fi

# PFD-3: The P1.1 pattern — prior "Fix ..." commit at overlapping lines,
# current diff reverts the narrow fix. Expect one suspect naming the fix.
mkdir -p "$PFD_DIR/r3"
(
    cd "$PFD_DIR/r3"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    printf 'a\nb\nc // narrowly scoped\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "Fix manual-accounts label regression"
    printf 'a\nb\nc // narrowly scoped\nd\n# trailing\n' > f.txt
    git add f.txt && git commit --quiet -m "add trailing note"
    git checkout --quiet -b feat
    printf 'a\nb\nc\nd\n# trailing\n' > f.txt
    git add f.txt && git commit --quiet -m "SQL refactor"
)
out=$(cd "$PFD_DIR/r3" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
subject=$(echo "$out" | jq -r '.[0].prior_fix_commit_message_subject // ""')
if [[ "$len" == "1" ]] && [[ "$subject" == "Fix manual-accounts label regression" ]]; then
    pass "PFD-3 (§13.11b): overlapping fix-intent commit surfaces as one suspect"
else
    fail "PFD-3: expected one suspect naming the Fix commit; got length=$len subject='$subject' out=$out"
fi

# PFD-4: Fix-intent commit exists but touches different lines than the PR.
# git log -L should not select it; expect empty.
mkdir -p "$PFD_DIR/r4"
(
    cd "$PFD_DIR/r4"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    # Fix at line 2 — different from where feat will change.
    sed -i.bak 's/line2/line2-fixed/' f.txt && rm -f f.txt.bak
    git add f.txt && git commit --quiet -m "Fix bug at line 2"
    git checkout --quiet -b feat
    # feat change at line 8 (no overlap with the fix at line 2).
    sed -i.bak 's/line8/line8-changed/' f.txt && rm -f f.txt.bak
    git add f.txt && git commit --quiet -m "change line 8"
)
out=$(cd "$PFD_DIR/r4" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]]; then
    pass "PFD-4 (§13.11b): fix-intent commit with no line overlap filtered out"
else
    fail "PFD-4: expected empty array; got length=$len out=$out"
fi

# PFD-5: PR-internal fix commits filtered by --is-ancestor check.
# feat branch has its own "Fix" commit that must NOT be surfaced as a
# suspect (it isn't reachable from main).
mkdir -p "$PFD_DIR/r5"
(
    cd "$PFD_DIR/r5"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    git checkout --quiet -b feat
    # Feat commit 1: intentionally introduce a bug at line 3
    printf 'a\nb\nBROKEN\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "feat work (introduces bug)"
    # Feat commit 2: self-fix at line 3 ("Fix...") — PR-INTERNAL
    printf 'a\nb\nFIXED\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "Fix bug introduced above"
    # Feat commit 3: further change at line 3
    printf 'a\nb\nFINAL\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "finalize line 3"
)
out=$(cd "$PFD_DIR/r5" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]]; then
    pass "PFD-5 (§13.11b): PR-internal fix commits filtered by --is-ancestor"
else
    fail "PFD-5: expected empty array (feat's own fixes excluded); got length=$len out=$out"
fi

# PFD-6: Usage errors — missing --comparison-ref → exit 64; unknown
# ref → exit 1 with error-as-prompt suggestions.
mkdir -p "$PFD_DIR/r6"
(
    cd "$PFD_DIR/r6"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt && git add f.txt && git commit --quiet -m "seed"
)
rc_missing=$(cd "$PFD_DIR/r6" && ("$TOOLS/prior-fix-diff.sh" --reviewed-files f.txt >/dev/null 2>&1); echo $?)
rc_badref=$(cd "$PFD_DIR/r6" && ("$TOOLS/prior-fix-diff.sh" --comparison-ref no-such-ref --reviewed-files f.txt >/dev/null 2>&1); echo $?)
if [[ "$rc_missing" == "64" && "$rc_badref" == "1" ]]; then
    pass "PFD-6 (§13.11b): usage errors surface correct exit codes (64 missing / 1 bad-ref)"
else
    fail "PFD-6: expected 64/1; got missing=$rc_missing badref=$rc_badref"
fi

# L7-1..L7-4 guard the holistic-lens plumbing (Stage 2.9.D). L7 runs
# only under --ensemble; these tests exercise the wiring that happens
# on every run (source-priority slot, origin-crosscheck, fragment
# presence) without the LLM dispatch itself.

# L7-1: fragment presence — 01-detection.md step 1.1 table has L7 row,
# step 1.3 has a dispatch block with the L7 header, and step 1.4's
# lens-tag list names L7-holistic.
if grep -qE '^\| L7 — holistic review' "$REPO/fragments/01-detection.md" \
    && grep -qF '#### L7 — holistic review (Opus' "$REPO/fragments/01-detection.md" \
    && grep -qF 'L7-holistic' "$REPO/fragments/01-detection.md"; then
    pass "L7-1 (§2.9.D): 01-detection.md fragment has L7 table row, dispatch block, and lens-tag"
else
    fail "L7-1: L7 fragment wiring incomplete"
fi

# L7-2: assign-finding-ids.sh slots L7-holistic between L6-security and
# external-pr. Synthetic pool of one L6 + one L7 + one external-pr.
in='[{"sources":["L7-holistic"],"file":"h.ts"},{"sources":["external-pr:bot"],"file":"e.ts"},{"sources":["L6-security"],"file":"s.ts"}]'
out=$(echo "$in" | "$TOOLS/assign-finding-ids.sh")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.sources[0])"] | join(",")')
expected="F001:L6-security,F002:L7-holistic,F003:external-pr:bot"
if [[ "$line" == "$expected" ]]; then
    pass "L7-2 (§2.9.D): assign-finding-ids.sh slots L7-holistic between L6 and external-pr"
else
    fail "L7-2: expected '$expected'; got '$line'"
fi

# L7-3: origin-crosscheck on a synthetic L7 candidate whose line range
# is entirely ancestor of $comparison_ref gets overridden to
# pre_existing/high — same behavior as L1..L6 (source-family-agnostic).
# Reuse the OC scratch repo if it still exists from OC-*.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"L7C1","sources":["L7-holistic"],"source_family":"holistic-family","file":"file_a.py","line_range":[1,2],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>/dev/null)
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "high" ]]; then
    pass "L7-3 (§2.9.D): origin-crosscheck flips L7-holistic candidate (ancestor range) to pre_existing/high"
else
    fail "L7-3: expected pre_existing/high on ancestor L7 range; got origin=$origin conf=$conf"
fi

# L7-4: CLAUDE.md pipeline-shape narrative reflects the 6-vs-7 lens
# count. A sanity guard so this meta-doc doesn't silently drift from
# the fragment.
if grep -qF '7 under --ensemble' "$REPO/CLAUDE.md" \
    && grep -qF 'holistic Opus safety net' "$REPO/CLAUDE.md"; then
    pass "L7-4 (§2.9.D): CLAUDE.md pipeline-shape narrative mentions L7 under --ensemble"
else
    fail "L7-4: CLAUDE.md pipeline-shape block missing L7 / --ensemble update"
fi

# L7-5: artifact-patch.py --add-finding accepts source_families:
# ["holistic-family"] (new source_family value). schema-v1.json has
# source_families items as {type:string, minLength:1} with no enum,
# so the addition should pass — but we verify rather than assume.
L7_ART="$WORK/l7-schema.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$L7_ART" >/dev/null
F_L7='{"id":"F901","sources":["L7-holistic"],"source_families":["holistic-family"],"impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"high","actionability":"auto_fixable","validation_lane":"deep","current_state":"open","disposition":"confirmed_mechanical","is_actionable":true,"reason":"test","confirmed_strength":"moderate","file":"src/holistic/test.ts","line_range":[10,12],"claim":"L7 schema smoke","score_phase3":65,"score_phase4":70,"score_history":[{"phase":"phase_3","score":65},{"phase":"phase_4","score":70}],"validation_result":null,"fix_attempts":[],"introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}'
if "$TOOLS/artifact-patch.py" --path "$L7_ART" --add-finding "$F_L7" >/dev/null 2>&1 \
    && "$TOOLS/artifact-validate.sh" --path "$L7_ART" >/dev/null 2>&1; then
    pass "L7-5 (§2.9.D): holistic-family source_family passes schema validation"
else
    fail "L7-5: schema rejected L7-holistic finding or validator failed"
fi

# UXT-1 guards the L5-ux diagnostic-message-quality addition (Stage
# 2.9.B). Content lives in lens-ux-reference.md, which L5's dispatch
# Reads and embeds into its sub-agent prompt (Stage 4.C lazy load —
# fetched only when L5 is in the lens-selection set), so grep the
# reference file directly.
if grep -qF 'Diagnostic message quality' "$REPO/fragments/lens-ux-reference.md" \
    && grep -qF 'parseDate' "$REPO/fragments/lens-ux-reference.md" \
    && grep -qF 'empty-buffer' "$REPO/fragments/lens-ux-reference.md"; then
    pass "UXT-1 (§2.9.B): lens-ux-reference.md includes diagnostic-message-quality section"
else
    fail "UXT-1: diagnostic-message-quality content missing from lens-ux-reference.md"
fi

# FR-LENS-REF-INLINE-1 (formerly FR-LENS-REF-LAZY-1): the L5 and L6
# dispatch sub-sections in fragments/01-detection.md must contain the
# lens-reference content verbatim (inlined, not lazy-Read). F013
# replaced the Stage 4.C lazy-Read directive with full inlining so the
# placeholder `<contents of fragments/lens-*-reference.md>` pattern can
# never ship to a dispatched sub-agent. Grep for a distinctive phrase
# from each reference file; if both phrases are present the inlining is
# intact, and a regression that deletes the inlined content (or
# reverts to a placeholder) would fail this assertion. The reference
# files themselves remain on disk for future delta-editing and any
# other call sites.
DETECT_MD="$REPO/fragments/01-detection.md"
if grep -qF 'empty-buffer or mid-flush failure' "$DETECT_MD" \
    && grep -qF 'Input validation & injection' "$DETECT_MD"; then
    pass "FR-LENS-REF-INLINE-1: L5/L6 dispatch inlines lens-reference content"
else
    fail "FR-LENS-REF-INLINE-1: inlined lens-reference content missing from $DETECT_MD"
fi

# LT-1..LT-3 guard the L2 prompt tune (Stage 2.9.A). Stage-2.9 closes
# several P1/P2 misses by adding named prompt sections; silent removal
# would regress detection without failing any helper-level test.

# LT-1: Outer-pass contains the consumer-surface value trace bullet.
if grep -qF 'Consumer-surface value trace' "$REPO/fragments/01-detection.md" \
    && grep -qF '"0% APR"' "$REPO/fragments/01-detection.md"; then
    pass "LT-1 (§2.9.A): L2 outer pass includes consumer-surface value trace"
else
    fail "LT-1: consumer-surface bullet missing from L2 prompt"
fi

# LT-2: Outer-pass contains the cross-provider / domain-scope bullet.
if grep -qF 'Cross-provider / domain-scope check' "$REPO/fragments/01-detection.md" \
    && grep -qF 'recategorization pass triggered by Apple-import' "$REPO/fragments/01-detection.md"; then
    pass "LT-2 (§2.9.A): L2 outer pass includes cross-provider / domain-scope check"
else
    fail "LT-2: cross-provider bullet missing from L2 prompt"
fi

# LT-3: Inner-pass item 5 is SQL-JOIN-vs-UNIQUE and item 6 is Same-
# block adjacency (renumbered). Both anchors must be present in the
# expected order.
if grep -qF '5. **SQL JOIN join-key vs. target-table UNIQUE-constraint' "$REPO/fragments/01-detection.md" \
    && grep -qF '6. **Same-block adjacency.**' "$REPO/fragments/01-detection.md"; then
    pass "LT-3 (§2.9.A): inner-pass item 5=SQL-JOIN-vs-UNIQUE, item 6=Same-block adjacency"
else
    fail "LT-3: inner-pass renumbering / JOIN item missing"
fi

# PFD-8: 01-detection.md contains the step 1.2b wiring block. Guards
# against silent removal — smoke passes for the helper even if the
# wiring is deleted, so add an explicit presence check.
DETECTION_MD="$REPO/fragments/01-detection.md"
if grep -qF '### 1.2b. Prior-fix suspect scan' "$DETECTION_MD" \
    && grep -qF 'prior-fix-diff.sh' "$DETECTION_MD" \
    && grep -qF 'prior_fix_suspects=' "$DETECTION_MD"; then
    pass "PFD-8 (§13.11b): 01-detection.md step 1.2b wires prior-fix-diff.sh"
else
    fail "PFD-8: step 1.2b wiring missing from $DETECTION_MD"
fi

# PFD-9: L2 prompt contains the prior-fix reversion addendum. Guards
# against the wiring existing but L2's prompt never consuming it.
if grep -qF 'Prior-fix reversion check' "$DETECTION_MD" \
    && grep -qF '$prior_fix_suspects' "$DETECTION_MD"; then
    pass "PFD-9 (§13.11b): L2 prompt consumes \$prior_fix_suspects"
else
    fail "PFD-9: L2 prior-fix addendum missing from $DETECTION_MD"
fi

# PFD-7: Lookback cap — prior fix committed before the --lookback-days
# window is filtered out of git log --since output, so no suspect.
mkdir -p "$PFD_DIR/r7"
(
    cd "$PFD_DIR/r7"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    GIT_AUTHOR_DATE="2022-01-01T00:00:00Z" GIT_COMMITTER_DATE="2022-01-01T00:00:00Z" \
        git add f.txt && \
        GIT_AUTHOR_DATE="2022-01-01T00:00:00Z" GIT_COMMITTER_DATE="2022-01-01T00:00:00Z" \
        git commit --quiet -m "initial (2022)"
    # Fix committed ~3 years ago.
    sed -i.bak 's/c$/c-fixed/' f.txt && rm -f f.txt.bak
    GIT_AUTHOR_DATE="2022-06-01T00:00:00Z" GIT_COMMITTER_DATE="2022-06-01T00:00:00Z" \
        git add f.txt && \
        GIT_AUTHOR_DATE="2022-06-01T00:00:00Z" GIT_COMMITTER_DATE="2022-06-01T00:00:00Z" \
        git commit --quiet -m "Fix stale-c regression"
    # Tail commit with fresh date so main has recent activity.
    echo "# tail" >> f.txt
    git add f.txt && git commit --quiet -m "tail"
    git checkout --quiet -b feat
    sed -i.bak 's/c-fixed/c/' f.txt && rm -f f.txt.bak
    git add f.txt && git commit --quiet -m "revert c-fixed"
)
# With default lookback (365 days), the 2022 fix is outside the window.
out=$(cd "$PFD_DIR/r7" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
# With a wide lookback (2000 days ≈ 5.5 years), the fix should appear.
out_wide=$(cd "$PFD_DIR/r7" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt --lookback-days 2000 2>/dev/null)
len_wide=$(echo "$out_wide" | jq 'length')
if [[ "$len" == "0" && "$len_wide" == "1" ]]; then
    pass "PFD-7 (§13.11b): --lookback-days bounds git-log --since window"
else
    fail "PFD-7: expected default=0 / wide=1; got default=$len wide=$len_wide"
fi

# ------------------------------------------------------------------ tally-subagent-tokens.sh

TK_DIR="$WORK/tk"
mkdir -p "$TK_DIR"
cp "$FIX/artifact-seed.json" "$TK_DIR/artifact.json"
: > "$TK_DIR/tokens.jsonl"

# TK-1: empty tokens.jsonl → zero rollup that schema-validates.
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-1: helper exit non-zero on empty log"
tk1_total=$(jq -r '.subagent_tokens.total' "$TK_DIR/artifact.json")
tk1_invs=$(jq -r '.subagent_tokens.invocations' "$TK_DIR/artifact.json")
tk1_by_phase=$(jq -c '.subagent_tokens.by_phase' "$TK_DIR/artifact.json")
if [[ "$tk1_total" == "0" && "$tk1_invs" == "0" && "$tk1_by_phase" == "{}" ]] \
   && "$TOOLS/artifact-validate.sh" --path "$TK_DIR/artifact.json" >/dev/null 2>&1; then
    pass "TK-1: empty log → zero rollup; schema-validates"
else
    fail "TK-1: expected zeros; got total=$tk1_total invs=$tk1_invs by_phase=$tk1_by_phase"
fi

# TK-2: 4-line log with a tokens:null entry → correct totals, null coerced to 0.
cat > "$TK_DIR/tokens.jsonl" <<'JSONL'
{"phase":"phase_1","agent_role":"lens_security","agent_id":"a1","model":"sonnet","tokens":1000,"ts":"2026-04-21T10:00:00Z"}
{"phase":"phase_1","agent_role":"lens_ux","agent_id":"a2","model":"sonnet","tokens":2000,"ts":"2026-04-21T10:00:05Z"}
{"phase":"phase_4a","agent_role":"validator","agent_id":"a3","model":"opus","tokens":null,"ts":"2026-04-21T10:01:00Z","finding_id":"F001"}
{"phase":"phase_4a","agent_role":"validator","agent_id":"a4","model":"opus","tokens":5000,"ts":"2026-04-21T10:01:10Z","finding_id":"F002"}
JSONL
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-2: helper exit non-zero on populated log"
tk2_total=$(jq -r '.subagent_tokens.total' "$TK_DIR/artifact.json")
tk2_invs=$(jq -r '.subagent_tokens.invocations' "$TK_DIR/artifact.json")
tk2_lens_sec=$(jq -r '.subagent_tokens.by_lens.lens_security' "$TK_DIR/artifact.json")
tk2_p4_f001=$(jq -r '.subagent_tokens.by_finding_phase4.F001' "$TK_DIR/artifact.json")
if [[ "$tk2_total" == "8000" && "$tk2_invs" == "4" \
      && "$tk2_lens_sec" == "1000" && "$tk2_p4_f001" == "0" ]]; then
    pass "TK-2: 4-line log with tokens:null → total=8000 invs=4, null coerced to 0"
else
    fail "TK-2: expected total=8000 invs=4 lens_security=1000 F001=0; got total=$tk2_total invs=$tk2_invs lens_security=$tk2_lens_sec F001=$tk2_p4_f001"
fi

# TK-3: re-invocation is idempotent (bit-for-bit subagent_tokens).
tk3_before=$(jq -cS '.subagent_tokens' "$TK_DIR/artifact.json")
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-3: helper exit non-zero on re-run"
tk3_after=$(jq -cS '.subagent_tokens' "$TK_DIR/artifact.json")
if [[ "$tk3_before" == "$tk3_after" ]]; then
    pass "TK-3: idempotent re-invocation on unchanged log"
else
    fail "TK-3: subagent_tokens diverged on re-run" "before=$tk3_before after=$tk3_after"
fi

# TK-4: append new lines → total strictly grows by the appended sum (the
# cumulative-growth invariant that the lifecycle wiring relies on).
printf '{"phase":"phase_9","agent_role":"post_fix_reviewer","agent_id":"a5","model":"opus","tokens":3500,"ts":"2026-04-21T11:00:00Z"}\n' >> "$TK_DIR/tokens.jsonl"
printf '{"phase":"phase_9","agent_role":"fix_group","agent_id":"a6","model":"opus","tokens":1500,"ts":"2026-04-21T11:00:30Z"}\n' >> "$TK_DIR/tokens.jsonl"
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-4: helper exit non-zero after append"
tk4_total=$(jq -r '.subagent_tokens.total' "$TK_DIR/artifact.json")
tk4_invs=$(jq -r '.subagent_tokens.invocations' "$TK_DIR/artifact.json")
tk4_p9=$(jq -r '.subagent_tokens.by_phase.phase_9' "$TK_DIR/artifact.json")
if [[ "$tk4_total" == "13000" && "$tk4_invs" == "6" && "$tk4_p9" == "5000" ]]; then
    pass "TK-4: cumulative growth — total=8000→13000 (+5000), phase_9=5000"
else
    fail "TK-4: expected total=13000 invs=6 phase_9=5000; got total=$tk4_total invs=$tk4_invs phase_9=$tk4_p9"
fi

# TK-5: the chat-summary jq -r filter used by adamsreview:add step 10 and
# adamsreview:walkthrough step 9. Must produce a clean (unquoted) line on
# a populated artifact and empty stdout when subagent_tokens is absent.
token_filter='if (.subagent_tokens.total // null) != null and (.subagent_tokens.invocations // null) != null
    then "Cumulative sub-agent spend: \(.subagent_tokens.total) tokens across \(.subagent_tokens.invocations) invocations."
    else empty end'
tk5_line=$(jq -r "$token_filter" "$TK_DIR/artifact.json")
tk5_expected="Cumulative sub-agent spend: 13000 tokens across 6 invocations."
if [[ "$tk5_line" == "$tk5_expected" ]]; then
    pass "TK-5: chat-summary jq -r filter produces clean line on populated artifact"
else
    fail "TK-5: filter output mismatch" "expected=[$tk5_expected] got=[$tk5_line]"
fi

jq 'del(.subagent_tokens)' "$TK_DIR/artifact.json" > "$TK_DIR/art-no-st.json"
tk5_missing=$(jq -r "$token_filter" "$TK_DIR/art-no-st.json")
if [[ -z "$tk5_missing" ]]; then
    pass "TK-6: chat-summary filter omits line when subagent_tokens absent"
else
    fail "TK-6: expected empty output; got [$tk5_missing]"
fi

# ------------------------------------------------------------------ orchestrator-tokens.sh

OT_DIR="$WORK/ot"
mkdir -p "$OT_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/artifact.json"

# OT-1: slug derivation — both `/` AND `.` map to `-`. Claude Code's own
# convention; easy to miss because `/ → -` alone would handle the worktree
# path too, but `/.claude/` must become `--claude-` (double hyphen from
# the slash+dot pair), not `-.claude-`. Guard the algorithm directly so
# a future refactor can't break it silently.
ot1_slug=$(printf '%s' "/Users/x/Projects/adams-review/.claude/worktrees/y" | tr '/.' '-')
ot1_expected="-Users-x-Projects-adams-review--claude-worktrees-y"
if [[ "$ot1_slug" == "$ot1_expected" ]]; then
    pass "OT-1: slug derivation (tr '/.' '-') — both chars collapse correctly"
else
    fail "OT-1: slug mismatch" "expected=[$ot1_expected] got=[$ot1_slug]"
fi

# OT-2: missing transcript dir → zero rollup; schema-validates.
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/artifact.json" \
    --since    "2026-04-21T00:00:00.000Z" \
    --transcript-dir "$OT_DIR/does-not-exist" \
    >/dev/null 2>&1 || fail "OT-2: helper exit non-zero on missing dir"
ot2_total_input=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/artifact.json")
ot2_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/artifact.json")
ot2_sessions=$(jq -c '.orchestrator_tokens.sessions' "$OT_DIR/artifact.json")
if [[ "$ot2_total_input" == "0" && "$ot2_turns" == "0" && "$ot2_sessions" == "[]" ]] \
   && "$TOOLS/artifact-validate.sh" --path "$OT_DIR/artifact.json" >/dev/null 2>&1; then
    pass "OT-2: missing transcript dir → zero rollup; schema-validates"
else
    fail "OT-2: expected zeros + valid artifact; got input=$ot2_total_input turns=$ot2_turns sessions=$ot2_sessions"
fi

# OT-3: one synthetic transcript, 3 in-window assistant turns with known
# usage counts. Verify all four counters sum correctly, turn_count=3,
# sessions[] has exactly one entry with the right ids and transcript_path.
OT3_DIR="$OT_DIR/t3"
mkdir -p "$OT_DIR/art3" "$OT3_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art3/artifact.json"
cat > "$OT3_DIR/sess-a.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:00.000Z","sessionId":"sess-a","message":{"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}
{"type":"assistant","timestamp":"2026-04-21T10:01:00.000Z","sessionId":"sess-a","message":{"usage":{"input_tokens":5,"output_tokens":15,"cache_read_input_tokens":25,"cache_creation_input_tokens":35}}}
{"type":"assistant","timestamp":"2026-04-21T10:02:00.000Z","sessionId":"sess-a","message":{"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art3/artifact.json" \
    --since    "2026-04-21T00:00:00.000Z" \
    --transcript-dir "$OT3_DIR" \
    >/dev/null 2>&1 || fail "OT-3: helper exit non-zero on populated transcript"
ot3_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art3/artifact.json")
ot3_out=$(jq -r '.orchestrator_tokens.total_output' "$OT_DIR/art3/artifact.json")
ot3_cr=$(jq -r '.orchestrator_tokens.cache_read' "$OT_DIR/art3/artifact.json")
ot3_cc=$(jq -r '.orchestrator_tokens.cache_creation' "$OT_DIR/art3/artifact.json")
ot3_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art3/artifact.json")
ot3_sid=$(jq -r '.orchestrator_tokens.sessions[0].session_id' "$OT_DIR/art3/artifact.json")
ot3_slen=$(jq -r '.orchestrator_tokens.sessions | length' "$OT_DIR/art3/artifact.json")
if [[ "$ot3_in" == "16" && "$ot3_out" == "37" && "$ot3_cr" == "58" && "$ot3_cc" == "79" \
   && "$ot3_turns" == "3" && "$ot3_sid" == "sess-a" && "$ot3_slen" == "1" ]]; then
    pass "OT-3: 3-turn transcript → correct four-counter sums + sessions[] entry"
else
    fail "OT-3: sum mismatch" "in=$ot3_in out=$ot3_out cr=$ot3_cr cc=$ot3_cc turns=$ot3_turns sid=$ot3_sid slen=$ot3_slen"
fi

# OT-4: cross-session merge — two transcripts in the same dir with
# distinct sessionIds. Verify sessions[] has 2 entries sorted by
# first_seen, and totals sum across both.
cat > "$OT3_DIR/sess-b.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T09:00:00.000Z","sessionId":"sess-b","message":{"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":400}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art3/artifact.json" \
    --since    "2026-04-21T00:00:00.000Z" \
    --transcript-dir "$OT3_DIR" \
    >/dev/null 2>&1 || fail "OT-4: helper exit non-zero on multi-transcript"
ot4_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art3/artifact.json")
ot4_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art3/artifact.json")
ot4_slen=$(jq -r '.orchestrator_tokens.sessions | length' "$OT_DIR/art3/artifact.json")
# sort_by(.first_seen): sess-b (09:00) comes before sess-a (10:00).
ot4_first=$(jq -r '.orchestrator_tokens.sessions[0].session_id' "$OT_DIR/art3/artifact.json")
ot4_second=$(jq -r '.orchestrator_tokens.sessions[1].session_id' "$OT_DIR/art3/artifact.json")
if [[ "$ot4_turns" == "4" && "$ot4_in" == "116" && "$ot4_slen" == "2" \
   && "$ot4_first" == "sess-b" && "$ot4_second" == "sess-a" ]]; then
    pass "OT-4: cross-session merge — totals sum; sessions[] sorted by first_seen"
else
    fail "OT-4: merge mismatch" "turns=$ot4_turns in=$ot4_in slen=$ot4_slen first=$ot4_first second=$ot4_second"
fi

# OT-5: time-window filter — --since in the future excludes all turns,
# yielding zero rollup even though transcripts are populated. Also
# verifies the partial-window case where only some turns survive.
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art3/artifact.json" \
    --since    "2099-01-01T00:00:00.000Z" \
    --transcript-dir "$OT3_DIR" \
    >/dev/null 2>&1 || fail "OT-5: helper exit non-zero on future --since"
ot5_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art3/artifact.json")
ot5_slen=$(jq -r '.orchestrator_tokens.sessions | length' "$OT_DIR/art3/artifact.json")
# Partial window: cut between the two sess-a turns at 10:00 and 10:01.
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art3/artifact.json" \
    --since    "2026-04-21T10:00:30.000Z" \
    --transcript-dir "$OT3_DIR" \
    >/dev/null 2>&1 || fail "OT-5: helper exit non-zero on partial window"
ot5p_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art3/artifact.json")
ot5p_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art3/artifact.json")
# Surviving: two sess-a turns (10:01 and 10:02) — input = 5 + 1 = 6.
if [[ "$ot5_turns" == "0" && "$ot5_slen" == "0" && "$ot5p_turns" == "2" && "$ot5p_in" == "6" ]]; then
    pass "OT-5: --since filter — future excludes all; partial window keeps only post-since turns"
else
    fail "OT-5: window filter mismatch" "future_turns=$ot5_turns future_slen=$ot5_slen partial_turns=$ot5p_turns partial_in=$ot5p_in"
fi

# OT-7: --since at second precision (matching Phase 0's
# `date -u +%Y-%m-%dT%H:%M:%SZ` format) correctly includes same-second
# turns that carry millisecond-precision timestamps. Without the helper's
# internal .000Z normalization, lexical `.500Z >= Z` evaluates FALSE
# (because `.` < `Z`), and the helper would silently drop turns that
# happened in the same wall-clock second as review_started_at.
OT7_DIR="$OT_DIR/t7"
mkdir -p "$OT_DIR/art7" "$OT7_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art7/artifact.json"
cat > "$OT7_DIR/sess.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:00.500Z","sessionId":"sess-d","message":{"usage":{"input_tokens":100,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-04-21T10:00:01.000Z","sessionId":"sess-d","message":{"usage":{"input_tokens":100,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art7/artifact.json" \
    --since    "2026-04-21T10:00:00Z" \
    --transcript-dir "$OT7_DIR" \
    >/dev/null 2>&1 || fail "OT-7: helper exit non-zero on second-precision since"
ot7_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art7/artifact.json")
ot7_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art7/artifact.json")
# Both turns (10:00:00.500Z and 10:00:01.000Z) are AT or AFTER 10:00:00Z
# and should be included. Without normalization we'd get turns=1 in=100.
if [[ "$ot7_turns" == "2" && "$ot7_in" == "200" ]]; then
    pass "OT-7: second-precision --since includes same-second ms-precision turns (normalized to .000Z)"
else
    fail "OT-7: expected turns=2 in=200 (normalization works); got turns=$ot7_turns in=$ot7_in"
fi

# OT-6: non-assistant lines (user messages, worktree-state snapshots, etc.)
# are ignored. This guards the `type == "assistant"` filter specifically —
# real Claude Code transcripts mix many line types and the helper must
# not accidentally count `type == "user"` or `type == "worktree-state"`
# lines that happen to have nested numeric fields.
OT6_DIR="$OT_DIR/t6"
mkdir -p "$OT_DIR/art6" "$OT6_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art6/artifact.json"
cat > "$OT6_DIR/mix.jsonl" <<'JSONL'
{"type":"user","timestamp":"2026-04-21T10:00:00.000Z","message":{"content":"hi"}}
{"type":"system","timestamp":"2026-04-21T10:00:01.000Z","message":"boot"}
{"type":"worktree-state","timestamp":"2026-04-21T10:00:02.000Z"}
{"type":"assistant","timestamp":"2026-04-21T10:00:03.000Z","sessionId":"sess-c","message":{"usage":{"input_tokens":7,"output_tokens":8,"cache_read_input_tokens":9,"cache_creation_input_tokens":10}}}
{"type":"attachment","timestamp":"2026-04-21T10:00:04.000Z"}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art6/artifact.json" \
    --since    "2026-04-21T00:00:00.000Z" \
    --transcript-dir "$OT6_DIR" \
    >/dev/null 2>&1 || fail "OT-6: helper exit non-zero on mixed-types transcript"
ot6_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art6/artifact.json")
ot6_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art6/artifact.json")
ot6_out=$(jq -r '.orchestrator_tokens.total_output' "$OT_DIR/art6/artifact.json")
if [[ "$ot6_turns" == "1" && "$ot6_in" == "7" && "$ot6_out" == "8" ]]; then
    pass "OT-6: non-assistant line types (user/system/worktree-state/attachment) ignored"
else
    fail "OT-6: filter let non-assistant lines through" "turns=$ot6_turns in=$ot6_in out=$ot6_out"
fi

# ------------------------------------------------------------------ Project F: LLM output normalization
#
# Three helpers attack three distinct LLM-output-shape problems:
#   PR-* — parse-with-repair.py (tolerant JSON parse, foundation)
#   VR-* — parse-validator-result.py (Phase 4 score/shape normalizer)
#   SF-* — source-family-map.py (Phase 1 lens-family canonicalizer)
# Plus PF-INT-* for fragment integration proof.

# --- PR-* parse-with-repair.py

# PR-1: trailing-comma input → repaired to valid JSON.
pr1_out=$(echo '{"a": 1, "b": 2,}' | "$TOOLS/parse-with-repair.py" 2>&1)
if [[ $? -eq 0 ]] && echo "$pr1_out" | jq -e '.a == 1 and .b == 2' >/dev/null; then
    pass "PR-1: trailing-comma input repaired"
else
    fail "PR-1: trailing-comma repair failed" "$pr1_out"
fi

# PR-2: ```json ... ``` fence-wrapped input → fences stripped.
pr2_out=$(printf '```json\n{"x": "y"}\n```\n' | "$TOOLS/parse-with-repair.py" 2>&1)
if [[ $? -eq 0 ]] && echo "$pr2_out" | jq -e '.x == "y"' >/dev/null; then
    pass 'PR-2: code-fence (```json) stripped'
else
    fail "PR-2: fence-strip failed" "$pr2_out"
fi

# PR-3: single-quoted strings → repaired.
pr3_out=$(echo "{'a': 'hello'}" | "$TOOLS/parse-with-repair.py" 2>&1)
if [[ $? -eq 0 ]] && echo "$pr3_out" | jq -e '.a == "hello"' >/dev/null; then
    pass "PR-3: single-quoted strings repaired"
else
    fail "PR-3: single-quote repair failed" "$pr3_out"
fi

# PR-4: unrecoverable garbage → exit 1 with error-as-prompt.
pr4_out=$(echo "not json at all" | "$TOOLS/parse-with-repair.py" 2>&1)
pr4_exit=$?
if [[ $pr4_exit -eq 1 ]] && echo "$pr4_out" | grep -qF "ERROR: could not parse"; then
    pass "PR-4: unrecoverable input → exit 1 + error-as-prompt"
else
    fail "PR-4: expected exit 1 with ERROR line; exit=$pr4_exit" "$pr4_out"
fi

# PR-5: empty stdin → exit 1 (distinct from parse-failure exit 1 but same code).
pr5_out=$(printf '' | "$TOOLS/parse-with-repair.py" 2>&1)
if [[ $? -eq 1 ]] && echo "$pr5_out" | grep -qF "empty input on stdin"; then
    pass "PR-5: empty stdin → exit 1 + specific error"
else
    fail "PR-5: empty-stdin handling" "$pr5_out"
fi

# --- VR-* parse-validator-result.py

# VR-1: canonical shape — {score_phase4, actionability} passes through.
vr1_out=$(echo '{"score_phase4": 72, "actionability": "auto_fixable", "decision": "confirmed"}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr1_out" | jq -e '.score_phase4 == 72 and .actionability == "auto_fixable" and .confirmed_strength == "moderate"' >/dev/null; then
    pass "VR-1: canonical {score_phase4,actionability} pass-through + strength derivation"
else
    fail "VR-1: canonical shape failed" "$vr1_out"
fi

# VR-2: nested shape — {score:{correctness:N}}.
vr2_out=$(echo '{"score": {"correctness": 55}, "actionability": "manual"}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr2_out" | jq -e '.score_phase4 == 55 and .actionability == "manual" and .confirmed_strength == "weak"' >/dev/null; then
    pass "VR-2: nested score.correctness extracted"
else
    fail "VR-2: nested shape failed" "$vr2_out"
fi

# VR-3: 1-5 scale via overall_numeric.
vr3_out=$(echo '{"overall_numeric": 3.5}' \
    | "$TOOLS/parse-validator-result.py" --lane light 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr3_out" | jq -e '.score_phase4 == 70 and (.notes | contains("scale_inferred"))' >/dev/null; then
    pass "VR-3: 1-5 overall_numeric scaled (*20) + scale_inferred in notes"
else
    fail "VR-3: overall_numeric scaling failed" "$vr3_out"
fi

# VR-4: severity string maps to bucket.
vr4_out=$(echo '{"severity": "medium", "actionability": "manual"}' \
    | "$TOOLS/parse-validator-result.py" --lane light 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr4_out" | jq -e '.score_phase4 == 60 and (.notes | contains("severity=medium"))' >/dev/null; then
    pass "VR-4: severity=medium → 60 (scale_inferred noted)"
else
    fail "VR-4: severity mapping failed" "$vr4_out"
fi

# VR-5: ambiguous {score: 6} → heuristic 1-10 (*10).
vr5_out=$(echo '{"score": 6}' \
    | "$TOOLS/parse-validator-result.py" --lane light 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr5_out" | jq -e '.score_phase4 == 60 and (.notes | contains("1-10"))' >/dev/null; then
    pass "VR-5: ambiguous {score: 6} heuristic (1-10 *10)"
else
    fail "VR-5: ambiguous-score heuristic failed" "$vr5_out"
fi

# VR-6: malformed input → exit 2 (score unrecoverable).
vr6_out=$(echo 'garbage' | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
vr6_exit=$?
if [[ $vr6_exit -eq 2 ]] && echo "$vr6_out" | grep -qF "ERROR:"; then
    pass "VR-6: malformed input → exit 2 + error-as-prompt"
else
    fail "VR-6: expected exit 2 on malformed; got $vr6_exit" "$vr6_out"
fi

# VR-7: deep-lane validation_result passthrough. Post-VR-10 the helper
# schema-checks vr against #/$defs/validation_result, so this fixture is
# a fully-shaped object (the old stub {"blast_radius": {}} pattern would
# now route to vr=null — correctly — and is covered by VR-10).
vr7_out=$(echo '{"score_phase4": 80, "actionability": "auto_fixable", "decision": "confirmed", "validation_result": {"evidence": ["e1"], "blast_radius": {"writers": [], "consumers": [], "parallel_paths": [], "invariants_at_stake": []}, "fix_proposal": {"approach": "x", "files_to_modify": []}, "verification_context": {"how_to_verify_fix": [], "edge_cases_to_preserve": [], "what_would_break_if_incomplete": []}}}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr7_out" | jq -e '.validation_result.evidence[0] == "e1" and .confirmed_strength == "strong"' >/dev/null; then
    pass "VR-7: deep-lane validation_result passthrough + strong strength at 80"
else
    fail "VR-7: deep-lane passthrough failed" "$vr7_out"
fi

# VR-8: precedence — out-of-band score_phase4 + out-of-band overall_numeric.
# Section A stashes the out-of-range score_phase4 (150) as the heuristic
# candidate; Section C must NOT overwrite that with its own out-of-band
# overall_numeric (7.5). Expected: heuristic rejects 150 → exit 2.
# Pre-fix (bug): C silently overwrote A, heuristic scaled 7.5 → 75 and
# exit 0 fabricated a confirmed_mechanical disposition.
vr8_out=$(echo '{"score_phase4": 150, "overall_numeric": 7.5}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
vr8_exit=$?
if [[ $vr8_exit -eq 2 ]] && echo "$vr8_out" | grep -qF "ERROR: cannot coerce score to 0-100"; then
    pass "VR-8: out-of-band score_phase4 + out-of-band overall_numeric → exit 2 (A precedes C)"
else
    fail "VR-8: expected exit 2 on double-out-of-band; got $vr8_exit" "$vr8_out"
fi

# VR-9: in-band score_phase4 still wins over out-of-band overall_numeric.
# Section A's canonical-range return happens before Section C runs, so
# the guard added in VR-8's fix doesn't regress the common case.
vr9_out=$(echo '{"score_phase4": 72, "overall_numeric": 7.5}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr9_out" | jq -e '.score_phase4 == 72 and .confirmed_strength == "moderate"' >/dev/null; then
    pass "VR-9: in-band score_phase4 (72) wins over out-of-band overall_numeric"
else
    fail "VR-9: in-band score_phase4 precedence failed" "$vr9_out"
fi

# VR-10: deep-lane drifted validation_result is schema-checked and dropped
# to null with a "shape unrecoverable" note, rather than passing through
# malformed (F005-drift case: files_planned/sketch/risk/alternative_rejected
# instead of the schema's evidence/blast_radius/fix_proposal/verification_context
# shape). This prevents the downstream --apply-decisions batch-halt that
# the stage-4 regression surfaced.
vr10_out=$(echo '{"score_phase4": 80, "actionability": "auto_fixable", "decision": "confirmed", "validation_result": {"files_planned": ["a"], "sketch": "x", "risk": "r", "alternative_rejected": "alt"}}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr10_out" | jq -e '.validation_result == null and (.notes | contains("validation_result shape unrecoverable"))' >/dev/null; then
    pass "VR-10: drifted deep-lane validation_result → null + shape-unrecoverable note"
else
    fail "VR-10: expected vr=null + note on drift" "$vr10_out"
fi

# VR-11: valid deep-lane validation_result passes schema check and
# passes through unchanged — ensures VR-10's guard didn't break the
# happy path. Uses fully-shaped sub-objects so every required key is
# present per schema-v1.json#/$defs/validation_result.
vr11_out=$(echo '{"score_phase4": 72, "actionability": "auto_fixable", "decision": "confirmed", "validation_result": {"evidence": ["file:12 — observation"], "blast_radius": {"writers": ["a.py:1"], "consumers": [], "parallel_paths": [], "invariants_at_stake": []}, "fix_proposal": {"approach": "fix x", "files_to_modify": [{"file":"a.py","what":"change","why":"required"}]}, "verification_context": {"how_to_verify_fix": ["grep x"], "edge_cases_to_preserve": [], "what_would_break_if_incomplete": []}}}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr11_out" | jq -e '.validation_result.evidence[0] == "file:12 — observation" and .validation_result.fix_proposal.approach == "fix x" and (.notes | contains("shape unrecoverable") | not)' >/dev/null; then
    pass "VR-11: valid deep-lane validation_result passes through unchanged"
else
    fail "VR-11: valid vr failed to pass through" "$vr11_out"
fi

# VR-12: top-level lift still fires when validation_result is absent but
# the raw carries evidence/blast_radius/fix_proposal/verification_context
# at the top level (legitimate recoverable shape drift). The lift runs
# BEFORE the schema check, so a well-shaped lift still reaches the
# passthrough without a "shape unrecoverable" note.
vr12_out=$(echo '{"score_phase4": 72, "actionability": "auto_fixable", "decision": "confirmed", "evidence": ["x"], "blast_radius": {"writers": [], "consumers": [], "parallel_paths": [], "invariants_at_stake": []}, "fix_proposal": {"approach": "x", "files_to_modify": []}, "verification_context": {"how_to_verify_fix": [], "edge_cases_to_preserve": [], "what_would_break_if_incomplete": []}}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr12_out" | jq -e '.validation_result.evidence[0] == "x" and (.notes | contains("lifted from top-level"))' >/dev/null; then
    pass "VR-12: top-level lift still fires when validation_result absent"
else
    fail "VR-12: top-level lift regressed" "$vr12_out"
fi

# --- SF-* source-family-map.py

# SF-1: canonical family pass-through.
sf1_out=$("$TOOLS/source-family-map.py" --input security-family 2>&1)
if [[ $? -eq 0 ]] && [[ "$sf1_out" == "security-family" ]]; then
    pass "SF-1: canonical family (security-family) pass-through"
else
    fail "SF-1: canonical pass-through failed" "$sf1_out"
fi

# SF-2: known drift case maps to canonical.
sf2_out=$("$TOOLS/source-family-map.py" --input prompt-injection 2>&1)
if [[ $? -eq 0 ]] && [[ "$sf2_out" == "security-family" ]]; then
    pass "SF-2: drift prompt-injection → security-family"
else
    fail "SF-2: drift mapping failed" "$sf2_out"
fi

# SF-3: stale-line-ref → policy-family (different canonical target).
sf3_out=$("$TOOLS/source-family-map.py" --input stale-line-ref 2>&1)
if [[ $? -eq 0 ]] && [[ "$sf3_out" == "policy-family" ]]; then
    pass "SF-3: drift stale-line-ref → policy-family"
else
    fail "SF-3: stale-line-ref mapping failed" "$sf3_out"
fi

# SF-4: unknown family → exit 3 + UNKNOWN_FAMILY on stderr.
sf4_out=$("$TOOLS/source-family-map.py" --input completely-made-up 2>&1)
sf4_exit=$?
if [[ $sf4_exit -eq 3 ]] && echo "$sf4_out" | grep -qF "UNKNOWN_FAMILY: completely-made-up"; then
    pass "SF-4: unknown family → exit 3 + UNKNOWN_FAMILY stderr"
else
    fail "SF-4: expected exit 3 with UNKNOWN_FAMILY; got $sf4_exit" "$sf4_out"
fi

# SF-5: external-add-family canonical pass-through (commands/add.md emits this).
sf5_out=$("$TOOLS/source-family-map.py" --input external-add-family 2>&1)
if [[ $? -eq 0 ]] && [[ "$sf5_out" == "external-add-family" ]]; then
    pass "SF-5: canonical family (external-add-family) pass-through"
else
    fail "SF-5: external-add-family pass-through failed" "$sf5_out"
fi

# --- PF-INT-*: fragment integration guards

# PF-INT-1: middle-path ensemble-adapter migration — fragments/02-ensemble-adapter.md
# pipes the normalizer output through parse-with-repair.py BEFORE the
# jq schema-guard. This proves the middle-path migration landed in the
# fragment, not just in the helper. The grep pattern is specific enough
# that it catches the new bash block (not a stale reference).
ENSEMBLE_MD="$REPO/fragments/02-ensemble-adapter.md"
if grep -qF 'parse-with-repair.py' "$ENSEMBLE_MD" \
    && grep -qF 'normalizer_clean=' "$ENSEMBLE_MD" \
    && grep -qF 'phase_1_5_normalizer_unparseable' "$ENSEMBLE_MD"; then
    pass "PF-INT-1: ensemble-adapter normalizer migrated to parse-with-repair.py"
else
    fail "PF-INT-1: ensemble-adapter migration missing markers in $ENSEMBLE_MD"
fi

# PF-INT-2: parse-with-repair.py actually handles the kind of malformed
# JSON the ensemble normalizer emits in practice (single-quote + trailing
# comma + fence combo). End-to-end proof, not helper-unit.
# Write to a temp file via printf with escape codes to sidestep bash
# backtick-in-heredoc parsing issues — the raw payload is a JSON array
# wrapped in a markdown code fence ( triple-backtick + "json" ).
pf2_file=$(mktemp)
printf '\140\140\140json\n[{"file": "src/a.ts", "claim": "x'\''y",}]\n\140\140\140\n' > "$pf2_file"
pf2_out=$("$TOOLS/parse-with-repair.py" < "$pf2_file" 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$pf2_out" | jq -e '.[0].file == "src/a.ts"' >/dev/null; then
    pass "PF-INT-2: ensemble-adapter-style malformed input (fence+single-quote+trailing-comma) repaired end-to-end"
else
    fail "PF-INT-2: ensemble-style malformed repair failed" "$pf2_out"
fi
rm -f "$pf2_file"

# PF-INT-3: fragments/05-validation.md references parse-validator-result.py
# for canonical shape normalization before --apply-decisions tuple compose.
VAL_MD="$REPO/fragments/05-validation.md"
if grep -qF 'parse-validator-result.py' "$VAL_MD" \
    && grep -qF -e '--lane deep' "$VAL_MD" \
    && grep -qF 'Phase 4 parse/score unrecoverable' "$VAL_MD"; then
    pass "PF-INT-3: fragments/05-validation.md integrates parse-validator-result.py"
else
    fail "PF-INT-3: validation fragment integration missing markers in $VAL_MD"
fi

# PF-INT-4: fragments/01-detection.md integrates source-family-map.py at
# the join step with "unknown"-tag escalation (not silent drop).
DET_MD="$REPO/fragments/01-detection.md"
if grep -qF 'source-family-map.py' "$DET_MD" \
    && grep -qF 'canonical_family="unknown"' "$DET_MD" \
    && grep -qF 'lens_source_family_unknown' "$DET_MD"; then
    pass "PF-INT-4: detection fragment integrates source-family-map.py (escalate-not-drop)"
else
    fail "PF-INT-4: detection fragment integration missing markers in $DET_MD"
fi

# PF-INT-5: commands/review.md frontmatter grants bare-name Bash permissions
# for the Phase 1 detection helpers invoked in transcluded fragments.
# Catches the permissions-vs-usage drift class.
REVIEW_CMD="$REPO/commands/review.md"
review_front=$(awk '/^---$/{c++; next} c==1{print}' "$REVIEW_CMD")
rh_missing=()
for helper in parse-with-repair.py parse-validator-result.py source-family-map.py assign-finding-ids.sh origin-crosscheck.sh; do
    if ! echo "$review_front" | grep -qF "Bash($helper:"; then
        rh_missing+=("$helper")
    fi
done
if [[ ${#rh_missing[@]} -eq 0 ]]; then
    pass "PF-INT-5: commands/review.md allowed-tools grants Phase 1 detection helpers"
else
    fail "PF-INT-5: missing Bash grants for: ${rh_missing[*]}"
fi

# ------------------------------------------------------------------ FG-* freshness-gate.sh
# Stage 4.A.1 — Phase 0.2a freshness reconciliation extracted into a
# helper. Covers happy path (clean remote, zero behind), no-remote case,
# and fetch-failure case.

FG_DIR="$WORK/freshness-gate"

# FG-1: happy path — origin exists, local base is up-to-date, behind=0.
mkdir -p "$FG_DIR/fg1/origin"
(
    cd "$FG_DIR/fg1/origin"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
)
git clone --quiet "$FG_DIR/fg1/origin" "$FG_DIR/fg1/repo" 2>/dev/null
(
    cd "$FG_DIR/fg1/repo"
    git config user.email smoke@example.com
    git config user.name smoke
    git checkout --quiet -b feat
    printf 'b\n' > f.txt
    git commit --quiet -am "feature"
)
out=$(cd "$FG_DIR/fg1/repo" && "$TOOLS/freshness-gate.sh" \
    --base-branch main --head-branch feat 2>/dev/null)
fg1_freshness=$(echo "$out" | jq -r '.base_freshness')
fg1_compref=$(echo "$out" | jq -r '.comparison_ref')
fg1_behind=$(echo "$out" | jq -r '.behind_count')
fg1_warn_len=$(echo "$out" | jq '.preflight_warnings | length')
if [[ "$fg1_freshness" == "fresh" && "$fg1_compref" == "main" \
    && "$fg1_behind" == "0" && "$fg1_warn_len" == "0" ]]; then
    pass "FG-1 (§13.10): happy path — origin fresh, behind=0 → base_freshness=fresh"
else
    fail "FG-1: expected fresh/main/0/[]; got freshness=$fg1_freshness compref=$fg1_compref behind=$fg1_behind warn_len=$fg1_warn_len"
fi

# FG-2: no-remote case — repo has no `origin` remote at all.
mkdir -p "$FG_DIR/fg2"
(
    cd "$FG_DIR/fg2"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    git checkout --quiet -b feat
    printf 'b\n' > f.txt
    git commit --quiet -am "feature"
)
out=$(cd "$FG_DIR/fg2" && "$TOOLS/freshness-gate.sh" \
    --base-branch main --head-branch feat 2>/dev/null)
fg2_freshness=$(echo "$out" | jq -r '.base_freshness')
fg2_compref=$(echo "$out" | jq -r '.comparison_ref')
fg2_remote_sha=$(echo "$out" | jq -r '.remote_sha')
fg2_behind=$(echo "$out" | jq -r '.behind_count')
if [[ "$fg2_freshness" == "no_remote" && "$fg2_compref" == "main" \
    && "$fg2_remote_sha" == "null" && "$fg2_behind" == "null" ]]; then
    pass "FG-2 (§13.10): no-remote case — base_freshness=no_remote, remote_sha/behind_count null"
else
    fail "FG-2: expected no_remote/main/null/null; got freshness=$fg2_freshness compref=$fg2_compref rsha=$fg2_remote_sha behind=$fg2_behind"
fi

# FG-3: fetch-failure case — `origin` remote points at a nonexistent path.
mkdir -p "$FG_DIR/fg3"
(
    cd "$FG_DIR/fg3"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    git remote add origin "$FG_DIR/fg3/nonexistent_remote_xyz"
    git checkout --quiet -b feat
    printf 'b\n' > f.txt
    git commit --quiet -am "feature"
)
out=$(cd "$FG_DIR/fg3" && "$TOOLS/freshness-gate.sh" \
    --base-branch main --head-branch feat 2>/dev/null)
fg3_freshness=$(echo "$out" | jq -r '.base_freshness')
fg3_compref=$(echo "$out" | jq -r '.comparison_ref')
fg3_warn_len=$(echo "$out" | jq '.preflight_warnings | length')
fg3_warn_head=$(echo "$out" | jq -r '.preflight_warnings[0] // ""')
if [[ "$fg3_freshness" == "no_fetch" && "$fg3_compref" == "main" \
    && "$fg3_warn_len" == "1" ]] \
    && echo "$fg3_warn_head" | grep -q '^fetch_failed '; then
    pass "FG-3 (§13.10): fetch-failure case — base_freshness=no_fetch, fetch_failed warning buffered"
else
    fail "FG-3: expected no_fetch/main/warn_len=1/'fetch_failed ...'; got freshness=$fg3_freshness compref=$fg3_compref warn_len=$fg3_warn_len warn_head='$fg3_warn_head'"
fi

# ------------------------------------------------------------------ TC-* trivial-check.sh
# Stage 4.A.2 — Phase 0.11 trivial-diff classification extracted into a
# helper. Covers trivial docs-only case, non-trivial mixed case, and
# empty-diff edge case (vacuously trivial; matches pre-extraction
# fragment behavior).

# TC-1: trivial docs-only — every file in the doc/config allow-list,
# num_files <= 3, lines_changed <= 30.
tc1_out=$(printf '%s\n' "README.md" "CHANGELOG.md" ".gitignore" \
    | "$TOOLS/trivial-check.sh" --num-files 3 --lines-changed 20)
tc1_mode=$(echo "$tc1_out" | jq -r '.trivial_mode')
tc1_reason=$(echo "$tc1_out" | jq -r '.reason')
if [[ "$tc1_mode" == "true" && "$tc1_reason" == "docs_only" ]]; then
    pass "TC-1 (§13.9): trivial docs-only — trivial_mode=true, reason=docs_only"
else
    fail "TC-1: expected true/docs_only; got mode=$tc1_mode reason=$tc1_reason"
fi

# TC-2: non-trivial mixed — one doc file + one source file fails the
# allow-list walk; reason must be null.
tc2_out=$(printf '%s\n' "README.md" "src/foo.ts" \
    | "$TOOLS/trivial-check.sh" --num-files 2 --lines-changed 10)
tc2_mode=$(echo "$tc2_out" | jq -r '.trivial_mode')
tc2_reason=$(echo "$tc2_out" | jq -r '.reason')
if [[ "$tc2_mode" == "false" && "$tc2_reason" == "null" ]]; then
    pass "TC-2 (§13.9): non-trivial mixed — trivial_mode=false, reason=null"
else
    fail "TC-2: expected false/null; got mode=$tc2_mode reason=$tc2_reason"
fi

# TC-3: empty-diff edge case — no files on stdin, zero counts. Vacuously
# trivial (allow-list walk never trips, 0<=3, 0<=30). Matches pre-
# extraction fragment behavior exactly.
tc3_out=$(printf '' | "$TOOLS/trivial-check.sh" --num-files 0 --lines-changed 0)
tc3_mode=$(echo "$tc3_out" | jq -r '.trivial_mode')
tc3_reason=$(echo "$tc3_out" | jq -r '.reason')
if [[ "$tc3_mode" == "true" && "$tc3_reason" == "docs_only" ]]; then
    pass "TC-3 (§13.9): empty-diff edge case — vacuously trivial, reason=docs_only"
else
    fail "TC-3: expected true/docs_only; got mode=$tc3_mode reason=$tc3_reason"
fi

# ------------------------------------------------------------------ AS-* artifact-seed.sh
# Stage 4.A.3 — Phase 0.15 artifact seed construction extracted into a
# helper. Covers happy-path (seed schema-validates via `artifact-patch.py
# --init -` and carries the expected top-level shape), missing-required-
# arg failure (error-as-prompt stderr + exit 64), and malformed
# `--base-context` failure (error-as-prompt stderr + exit 1).

AS_DIR="$WORK/artifact-seed"
mkdir -p "$AS_DIR"

# AS-1: happy-path — helper output satisfies schema-v1.json via
# `artifact-patch.py --init -`, and the resulting artifact carries the
# expected top-level fields (schema_version, review_id, mode, nullable
# comment_id persisted as null, reviewer_sources seeded to ["internal"],
# pr_size_buckets nested under metrics).
as1_base_ctx='{"freshness":"fresh","comparison_ref":"main","remote_sha":"def5678","behind_count":0}'
as1_art="$AS_DIR/as1.json"
as1_err="$AS_DIR/as1.err"
if "$TOOLS/artifact-seed.sh" \
    --review-id "rev_01HXAS1TESTIDENTIFIER" \
    --review-started-at "2026-04-22T12:34:56Z" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "feature/foo" \
    --mode "pr" --pr-state "open" \
    --pr-number "42" --comment-id "" \
    --trivial-mode "false" --base-context "$as1_base_ctx" \
    --reviewed-files-all "$(printf 'a.py\nb.py\n')" \
    --claude-md-paths "$(printf '/CLAUDE.md\n')" \
    --files-changed "2" --lines-changed "10" \
    | "$TOOLS/artifact-patch.py" --init - --path "$as1_art" 2>"$as1_err" >/dev/null; then
    as1_schema=$(jq -r '.schema_version' "$as1_art")
    as1_rid=$(jq -r '.review_id' "$as1_art")
    as1_mode=$(jq -r '.mode' "$as1_art")
    as1_cid=$(jq -r '.comment_id' "$as1_art")
    as1_rs=$(jq -r '.reviewer_sources | join(",")' "$as1_art")
    as1_files=$(jq -r '.metrics.pr_size_buckets.files_changed' "$as1_art")
    if [[ "$as1_schema" == "1" && "$as1_rid" == "rev_01HXAS1TESTIDENTIFIER" \
        && "$as1_mode" == "pr" && "$as1_cid" == "null" \
        && "$as1_rs" == "internal" && "$as1_files" == "2" ]]; then
        pass "AS-1 (§0.15): happy-path — seed schema-validates via --init and carries expected top-level shape"
    else
        fail "AS-1: shape mismatch — schema=$as1_schema rid=$as1_rid mode=$as1_mode cid=$as1_cid rs=$as1_rs files=$as1_files"
    fi
else
    fail "AS-1: --init rejected helper output" "$(cat "$as1_err" 2>/dev/null)"
fi

# AS-2: missing-required-arg — omit --review-started-at; expect usage
# error (exit 64) with error-as-prompt stderr (`ERROR:` + `Usage:`).
as2_err="$AS_DIR/as2.err"
"$TOOLS/artifact-seed.sh" \
    --review-id "rev_abc" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "hb" \
    --mode "pr" --pr-state "" --pr-number "" --comment-id "" \
    --trivial-mode "false" \
    --base-context '{"freshness":"fresh","comparison_ref":"main","remote_sha":null,"behind_count":null}' \
    --reviewed-files-all "" --claude-md-paths "" \
    --files-changed "0" --lines-changed "0" \
    >/dev/null 2>"$as2_err"
as2_rc=$?
if [[ "$as2_rc" == "64" ]] \
    && grep -q '^ERROR: --review-started-at is required' "$as2_err" \
    && grep -q '^Usage: ' "$as2_err"; then
    pass "AS-2 (§0.15): missing --review-started-at → exit 64 + error-as-prompt stderr"
else
    fail "AS-2: expected rc=64 with ERROR/Usage stderr; got rc=$as2_rc" "$(cat "$as2_err" 2>/dev/null)"
fi

# AS-3: malformed --base-context — not JSON; expect validation error
# (exit 1) with error-as-prompt stderr (`ERROR:` + `Action:`).
as3_err="$AS_DIR/as3.err"
"$TOOLS/artifact-seed.sh" \
    --review-id "rev_abc" \
    --review-started-at "2026-04-22T00:00:00Z" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "hb" \
    --mode "pr" --pr-state "" --pr-number "" --comment-id "" \
    --trivial-mode "false" --base-context "not-json" \
    --reviewed-files-all "" --claude-md-paths "" \
    --files-changed "0" --lines-changed "0" \
    >/dev/null 2>"$as3_err"
as3_rc=$?
if [[ "$as3_rc" == "1" ]] \
    && grep -q '^ERROR: --base-context must be a JSON object' "$as3_err" \
    && grep -q '^Action: ' "$as3_err"; then
    pass "AS-3 (§0.15): malformed --base-context → exit 1 + error-as-prompt stderr"
else
    fail "AS-3: expected rc=1 with ERROR/Action stderr; got rc=$as3_rc" "$(cat "$as3_err" 2>/dev/null)"
fi

echo
echo "smoke: PASS ($N assertions)"
exit 0
