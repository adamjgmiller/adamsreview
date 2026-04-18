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
    && grep -q "1 confirmed-auto, 1 uncertain" "$MD"; then
    pass "Y: Light-lane uncertain finding renders in table + summary (Stage 2.5.D)"
else
    fail "Y: expected F006 row + 'confirmed-auto, 1 uncertain' in $MD" "$(cat "$MD")"
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

echo
echo "smoke: PASS ($N assertions)"
exit 0
