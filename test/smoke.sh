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
expected_counts='{"findings_total":6,"by_disposition":{"below_gate":1,"confirmed_auto":1,"confirmed_manual":1,"pre_existing_report":1,"resolved":1,"uncertain":1}}'
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

# G. external-scrape.sh fixture-replay: bot filter + deny list + time window
EXT="$WORK/ext"
mkdir -p "$EXT"
cat > "$EXT/issue_comments.json" <<'JSON'
[
  {"id":1,"user":{"login":"humanuser","type":"User"},"created_at":"2026-02-01T00:00:00Z","body":"human comment"},
  {"id":2,"user":{"login":"coderabbit-ai[bot]","type":"Bot"},"created_at":"2026-02-01T00:00:00Z","body":"bot finding"},
  {"id":3,"user":{"login":"dependabot[bot]","type":"Bot"},"created_at":"2026-02-01T00:00:00Z","body":"dep bump"},
  {"id":5,"user":{"login":"coderabbit-ai[bot]","type":"Bot"},"created_at":"2025-01-01T00:00:00Z","body":"too old"}
]
JSON
echo '[]' > "$EXT/reviews.json"
echo '[]' > "$EXT/review_comments.json"
# Default config (no --config) — DEFAULT_DENY applies, allow=null.
out=$(ADAMS_REVIEW_FIXTURES_USER=smokeuser "$TOOLS/external-scrape.sh" \
        --since 2026-01-01T00:00:00Z --fixtures-dir "$EXT")
ids=$(echo "$out" | jq -c '[.[].id] | sort')
if [[ "$ids" == "[2]" ]]; then
    pass "G: external-scrape fixture replay keeps coderabbit, drops human/dep-bump/old"
else
    fail "G: expected ids [2], got $ids" "out=$out"
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

echo
echo "smoke: PASS ($N assertions)"
exit 0
