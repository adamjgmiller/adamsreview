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
TOOLS="$REPO/commands/_shared/tools"
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
expected_counts='{"findings_total":7,"by_disposition":{"below_gate":1,"confirmed_auto":1,"confirmed_manual":1,"pre_existing_report":1,"resolved":1,"uncertain":2}}'
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
# command carries its own continuation intent: fresh /adams-review
# omits --comment-id (→ POST); /adams-review-fix and /adams-review-promote
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

# OC-6: DESIGN §13.4 documents the new rule (fresh /adams-review POSTs).
if grep -q 'always .POST. a new comment' "$REPO/docs/DESIGN.md"; then
    pass "OC-6: DESIGN §13.4 documents fresh-/adams-review-POSTs rule"
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

# R. pending_validation → confirmed_auto Phase-4 transition works (R2 flow)
# F099 starts at below_gate; move through pending_validation → confirmed_auto
# (with is_actionable=true, confirmed_strength) simulating Phase 3→4.
cp "$ART" "$WORK/art-p34.json"
"$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" --finding-id F099 \
    --set disposition=pending_validation --set is_actionable=false >/dev/null
if "$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" --finding-id F099 \
        --set disposition=confirmed_auto \
        --set is_actionable=true \
        --set confirmed_strength=strong \
        --set "score_phase4=85" >/dev/null; then
    disp=$(jq -r '.findings[] | select(.id=="F099") | .disposition' "$WORK/art-p34.json")
    if [[ "$disp" == "confirmed_auto" ]]; then
        pass "R: pending_validation → confirmed_auto Phase-4 transition succeeds"
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
U_OUT=$(echo '["L1-diff-local","L3-claude-md","codex","external-pr:greptile-apps[bot]","random-tag"]' \
    | jq -c 'map(
        if test("^L[1-6]-") then "internal"
        elif . == "codex" or . == "coderabbit" then .
        elif startswith("external-pr:") then .
        else empty end
      ) | unique')
if [[ "$U_OUT" == '["codex","external-pr:greptile-apps[bot]","internal"]' ]]; then
    pass "U: reviewer_sources regex classifies L-tags, codex, external-pr: correctly"
else
    fail "U: reviewer_sources output = $U_OUT"
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
# pending_validation, run one --apply-decisions call with a confirmed_auto +
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
    && [[ "$F101_DISP" == "confirmed_auto" && "$F101_IA" == "true" && "$F101_CS" == "strong" && "$F101_VR" == "object" ]] \
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
# Stage 3 introduces `/adams-review-fix`. These assertions cover the helper
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
    --set disposition=confirmed_auto \
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
expected='{"current_state":"attempted","disposition":"confirmed_auto","attempts":1,"last_sha":null,"last_outcome":null,"last_finding":"run aborted: overlap on src/c.ts"}'
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

# ------------------------------------------------------------------ Stage 3 — render fix_runs
#
# artifact-render.py gained a richer `## Fix runs` section plus the
# retry-eligible partial/regression sections. These assertions pin the
# header shape, the outcome labels (including the overlap-abort label
# for phase_9_outcome=null), and the newest-first ordering invariant.
# expected.md already exercises the single-verified-run case at
# assertion 9 above; these tests focus on the edge cases not covered
# there.

RF_ART="$WORK/rf-art.json"

# Build a fresh artifact with F001 open/confirmed_auto and exercise the
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

# Assertion FX-RF-6: newest-first ordering. Two runs on the same artifact,
# different timestamps; expect the newer run's ### header to appear first.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/rf-two.json" >/dev/null
# Run A at 13:00
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-start '[{"id":"F007","run_id":"fixrun_old"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-outcomes \
  '[{"id":"F007","run_id":"fixrun_old","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"cccc333","phase_9_outcome":"verified","timestamp":"2026-04-18T13:00:00Z"}]' >/dev/null 2>&1
# F007 is now resolved — to run a second fix, we need a fresh open finding.
# Use F005 (currently open/confirmed_auto) for run B at 16:00.
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-start '[{"id":"F005","run_id":"fixrun_new"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-outcomes \
  '[{"id":"F005","run_id":"fixrun_new","fix_group_id":"FG-1","input_sha":"bbbb222","output_sha":"dddd444","phase_9_outcome":"verified","timestamp":"2026-04-18T16:00:00Z"}]' >/dev/null 2>&1

"$TOOLS/artifact-render.py" --input "$WORK/rf-two.json" --output "$WORK/rf-two.md" >/dev/null
# Extract line numbers of the two ### Run sub-headers; newer (fixrun_new) must come first.
line_new=$(grep -n '^### Run `fixrun_new`' "$WORK/rf-two.md" | cut -d: -f1)
line_old=$(grep -n '^### Run `fixrun_old`' "$WORK/rf-two.md" | cut -d: -f1)
if [[ -n "$line_new" && -n "$line_old" && "$line_new" -lt "$line_old" ]]; then
    pass "FX-RF-6 (§7): Fix runs ordered newest-first (line $line_new before $line_old)"
else
    fail "FX-RF-6: expected fixrun_new before fixrun_old, got new=$line_new old=$line_old"
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

# ------------------------------------------------------------------ MP-* /adams-review-promote (§27)
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
     | select(.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
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

# MP-5: after promoting F006 (disposition=confirmed_auto + actionability=auto_fixable +
# human_confirmation set), the same Phase 8 selector DOES include it. Tests the bypass.
MP_PROMOTED="$WORK/art-promote-done.json"
cp "$ART" "$MP_PROMOTED"
"$TOOLS/artifact-patch.py" --path "$MP_PROMOTED" --finding-id F006 \
    --set disposition=confirmed_auto \
    --set actionability=auto_fixable \
    --set-json "human_confirmation=$MP_HC_VALID" >/dev/null 2>&1 \
    || fail "MP-5 setup: promote patch failed"
mp5_ids=$(jq -r --argjson thr 60 '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
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
# /adams-review-promote --fix-hint "..." produces after step 5's jq build.
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
        --set disposition=confirmed_auto \
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
# WT-* cover the /adams-review-walkthrough command surface. WT-1..WT-4 exercise
# the scope-filter jq (the inverse of 09-fix-execution.md step 8.1); WT-5 is a
# structural check on /adams-review-promote's --defer-publish + shared-fragment
# wiring. The scope jq MUST stay in sync with Phase 8 eligibility — any drift
# surfaces here.

PROMOTE_MD="$REPO/commands/adams-review-promote.md"
PROMOTE_CORE_MD="$REPO/commands/_shared/promote-core.md"

# WT-0: promote-core precondition PROCEEDS (not no-op) for confirmed_auto +
# curr_hc == null. Pre-existing-bug guard: a blanket no-op on that row silently
# broke promoting light-lane findings and deep-lane below-threshold findings
# (§27.2, §27.6). If a future edit re-adds the no-op language, this surfaces.
# Checks: (a) the precondition table contains a **Proceed.** verdict on the
# confirmed_auto + curr_hc == null row, (b) it does NOT contain the old
# "already confirmed_auto by validator" no-op text.
if grep -q '`confirmed_auto` | `curr_hc == null` | \*\*Proceed' "$PROMOTE_CORE_MD" \
   && ! grep -q "already confirmed_auto by validator.*no-op" "$PROMOTE_CORE_MD"; then
    pass "WT-0 (§27.2, §27.6): promote-core precondition proceeds for confirmed_auto + no human_confirmation"
else
    fail "WT-0: promote-core.md missing 'Proceed' verdict or still has blanket no-op for confirmed_auto + no hc"
fi

# The walkthrough scope-filter jq — must stay in sync with the expression in
# commands/adams-review-walkthrough.md §3. Held as a shell variable so the
# assertions below can exercise it against different fixtures without drift.
WT_SCOPE_JQ='
[.findings[]
 | select(.current_state == "open")
 | select(.disposition != "resolved")
 | select(.disposition != "disproven")
 | select(.disposition != "pending_validation")
 | select(.human_confirmation == null)
 | select(
     (
       (.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
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
# score >= threshold + confirmed_auto/partial/regression) are excluded — the
# walkthrough's purpose is to surface what fix SKIPS. Fixture: deep/correctness
# confirmed_auto at score=80 should NOT appear.
wt3_findings=$(jq -nc \
    --argjson a "$(wt_finding W020 correctness deep confirmed_auto 80 open null)" \
    --argjson b "$(wt_finding W021 correctness deep confirmed_manual 80 open null)" \
    '[$a,$b]')
wt3_fx=$(wt_build_fixture "$wt3_findings")
wt3_ids=$(echo "$wt3_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt3_ids" == "W021" ]]; then
    pass "WT-3 (§28, §13.1): scope excludes fix-eligible findings (correctness confirmed_auto >= threshold)"
else
    fail "WT-3: expected W021 only; got '$wt3_ids'"
fi

# WT-4: light-lane confirmed_auto findings (which fail the impact_type gate)
# ARE included — this is the primary gap the walkthrough exists to close.
# Fixture: ux confirmed_auto at high score (which the fix command would skip
# due to impact_type != correctness/security) plus a below-threshold correctness
# confirmed_auto (which the fix command would skip due to the score gate).
wt4_findings=$(jq -nc \
    --argjson a "$(wt_finding W030 ux light confirmed_auto 80 open null)" \
    --argjson b "$(wt_finding W031 policy light confirmed_auto 50 open null)" \
    --argjson c "$(wt_finding W032 correctness deep confirmed_auto 40 open null)" \
    '[$a,$b,$c]')
wt4_fx=$(wt_build_fixture "$wt4_findings")
wt4_ids=$(echo "$wt4_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
# Order in jq output depends on array order, not a sort, so match any permutation.
if [[ ",$wt4_ids," == *,W030,* && ",$wt4_ids," == *,W031,* && ",$wt4_ids," == *,W032,* ]] \
   && [[ $(echo "$wt4_ids" | awk -F, '{print NF}') == "3" ]]; then
    pass "WT-4 (§28, §13.2): scope includes light-lane confirmed_auto + below-threshold deep confirmed_auto"
else
    fail "WT-4: expected W030,W031,W032 (any order); got '$wt4_ids'"
fi

# WT-6: /adams-review-walkthrough decisions-log template contains the required
# structural markers. Since the markdown is rendered inline by Claude at
# runtime (the command file is a prompt, not a shell script), this is a
# template-integrity check — guards against accidental removal of any
# section so the posted PR comment stays auditable.
WALK_MD="$REPO/commands/adams-review-walkthrough.md"
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

# WT-5: /adams-review-promote wires --defer-publish and includes promote-core.md.
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

echo
echo "smoke: PASS ($N assertions)"
exit 0
