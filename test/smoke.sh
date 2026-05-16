#!/usr/bin/env bash
# Codex plugin smoke tests for adamsreview.

set -u
set -o pipefail

THIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS/.." && pwd)"
PLUGIN="$REPO/plugins/adamsreview"
SKILL="$PLUGIN/skills/adamsreview"
TOOLS="$SKILL/scripts"
FIX="$THIS/fixtures"
WORK=/tmp/adamsreview-smoke
export UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/adamsreview-uv-cache}"

cleanup() {
    if [[ "${SMOKE_KEEP:-}" != "1" ]]; then
        rm -rf "$WORK"
    else
        echo "SMOKE_KEEP=1 -> artifacts preserved under $WORK" >&2
    fi
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK" "$UV_CACHE_DIR"

N=0
pass() { N=$((N+1)); printf 'ok %2d: %s\n' "$N" "$1"; }
fail() {
    N=$((N+1))
    printf 'FAIL %2d: %s\n' "$N" "$1" >&2
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
    echo "smoke: FAIL (assertion $N)" >&2
    exit 1
}
rc() { ( "$@" >/dev/null 2>&1 ); printf '%s' "$?"; }

# ---------------------------------------------------------------- structure

if [[ -f "$PLUGIN/.codex-plugin/plugin.json" ]] && jq empty "$PLUGIN/.codex-plugin/plugin.json" >/dev/null; then
    pass "plugin.json is present and valid"
else
    fail "plugin.json missing or invalid"
fi

if [[ "$(jq -r '.skills' "$PLUGIN/.codex-plugin/plugin.json")" == "./skills/" ]]; then
    pass "plugin.json points at ./skills/"
else
    fail "plugin.json skills path is not ./skills/"
fi

if [[ -f "$PLUGIN/.codex-plugin/marketplace-entry.json" ]] \
   && [[ "$(jq -r '.source.path' "$PLUGIN/.codex-plugin/marketplace-entry.json")" == "./plugins/adamsreview" ]]; then
    pass "marketplace entry points to ./plugins/adamsreview"
else
    fail "marketplace entry missing or wrong"
fi

if [[ -f "$REPO/.agents/plugins/marketplace.json" ]] \
   && [[ "$(jq -r '.plugins[] | select(.name == "adamsreview") | .source.path' "$REPO/.agents/plugins/marketplace.json")" == "./plugins/adamsreview" ]]; then
    pass "repo marketplace exposes adamsreview"
else
    fail "repo marketplace missing adamsreview entry"
fi

QUICK_VALIDATE="${CODEX_HOME:-$HOME/.codex}/skills/.system/skill-creator/scripts/quick_validate.py"
if [[ -f "$QUICK_VALIDATE" ]]; then
    if python3 "$QUICK_VALIDATE" "$SKILL" >/dev/null; then
        pass "SKILL.md validates"
    else
        fail "SKILL.md failed quick_validate.py"
    fi
else
    if awk '
        NR == 1 && $0 == "---" { started = 1; in_fm = 1; next }
        in_fm && $0 == "---" { closed = 1; exit !(seen_name && seen_description) }
        in_fm && /^name:[[:space:]]*adamsreview[[:space:]]*$/ { seen_name = 1 }
        in_fm && /^description:[[:space:]]*./ { seen_description = 1 }
        END { exit !(started && closed && seen_name && seen_description) }
    ' "$SKILL/SKILL.md"; then
        pass "SKILL.md has required metadata"
    else
        fail "SKILL.md missing required metadata"
    fi
fi

if ! grep -R -nE 'allowed-tools|AskUserQuestion|CLAUDE_PLUGIN_ROOT|/adamsreview:' "$PLUGIN" >/tmp/adamsreview-smoke-grep.txt; then
    pass "Codex plugin has no Claude command frontmatter or slash-command markers"
else
    fail "legacy command markers found in Codex plugin" "$(cat /tmp/adamsreview-smoke-grep.txt)"
fi

PAR="$SKILL/references/parallel-contract.md"
if grep -q 'Launch all independent work in parallel whenever Codex accepts' "$PAR" \
   && grep -q 'bounded rolling window at the accepted concurrency' "$PAR" \
   && grep -Fq '[agents].max_threads' "$PAR" \
   && grep -q 'at most 25 findings' "$PAR" \
   && grep -q 'Queue one `worker`' "$PAR" \
   && grep -q 'rolling-window elapsed time' "$PAR"; then
    pass "parallel contract documents bounded fallback without fixed cap"
else
    fail "parallel contract missing required invariants"
fi

if grep -q 'concurrent-agent limit' "$SKILL/references/review-workflow.md" \
   && grep -q 'concurrent-agent limit' "$SKILL/references/fix-workflow.md"; then
    pass "review and fix workflows describe configured-limit fallback"
else
    fail "workflow references do not describe configured-limit fallback"
fi

if grep -q 'always attempts PR bot-comment scrape' "$SKILL/references/review-workflow.md" \
   || grep -q 'run PR enrichment while lenses are active' "$SKILL/references/review-workflow.md"; then
    pass "review workflow makes PR scrape default"
else
    fail "review workflow does not describe default PR scrape"
fi

# ---------------------------------------------------------------- instruction paths

mkdir -p "$WORK/cm/a/b"
touch "$WORK/cm/AGENTS.md" "$WORK/cm/CLAUDE.md" "$WORK/cm/a/AGENTS.md" "$WORK/cm/a/b/file.ts"
actual=$("$TOOLS/instruction-paths.sh" --repo-root "$WORK/cm" --files "a/b/file.ts")
expected="$WORK/cm/AGENTS.md
$WORK/cm/CLAUDE.md
$WORK/cm/a/AGENTS.md"
if [[ "$actual" == "$expected" ]]; then
    pass "instruction-paths prefers AGENTS.md and keeps legacy CLAUDE.md fallback"
else
    fail "instruction-paths output mismatch" "expected=$expected actual=$actual"
fi

# ---------------------------------------------------------------- artifact helpers

ART="$WORK/art.json"
MD="$WORK/art.md"

if "$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$ART" >/dev/null; then
    pass "artifact-patch --init from seed succeeds"
else
    fail "artifact-patch --init failed"
fi

F099='{"id":"F099","sources":["detection"],"source_families":["code-review"],"impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"low","actionability":"report_only","validation_lane":"deep","current_state":"open","disposition":"below_gate","is_actionable":false,"reason":null,"confirmed_strength":null,"file":"src/misc/flake.ts","line_range":[1,1],"claim":"Minor below threshold","score_phase3":30,"score_phase4":30,"score_history":[{"phase":"phase_3","score":30},{"phase":"phase_4","score":30}],"validation_result":null,"fix_attempts":[],"introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}'
if "$TOOLS/artifact-patch.py" --path "$ART" --add-finding "$F099" >/dev/null; then
    pass "artifact-patch --add-finding succeeds"
else
    fail "artifact-patch --add-finding failed"
fi

if "$TOOLS/artifact-validate.sh" --path "$ART" >/dev/null; then
    pass "artifact validates"
else
    fail "artifact validation failed"
fi

code=$(rc "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=resolved)
if [[ "$code" == "2" ]]; then
    pass "invalid open->resolved transition is rejected"
else
    fail "open->resolved expected exit 2, got $code"
fi

if "$TOOLS/artifact-render.py" --input "$ART" --output "$MD" >/dev/null \
   && grep -q 'Code review' "$MD" \
   && grep -q 'Generated with the' "$MD"; then
    pass "artifact-render produces markdown"
else
    fail "artifact-render failed or output missing expected headings"
fi

summary=$("$TOOLS/artifact-read.sh" --path "$ART" --summary | jq -r '.findings_total')
if [[ "$summary" == "7" ]]; then
    pass "artifact-read --summary counts findings"
else
    fail "artifact-read summary expected 7 findings, got $summary"
fi

# ---------------------------------------------------------------- PR scrape fixtures

SCRAPE="$WORK/scrape"
mkdir -p "$SCRAPE"
cat > "$SCRAPE/issue_comments.json" <<'JSON'
[
  {"id":1,"user":{"login":"coderabbit-ai[bot]","type":"Bot"},"created_at":"2026-01-01T00:00:00Z","body":"Potential bug in src/a.ts"},
  {"id":2,"user":{"login":"dependabot[bot]","type":"Bot"},"created_at":"2026-01-01T00:00:00Z","body":"Bump deps"},
  {"id":3,"user":{"login":"human","type":"User"},"created_at":"2026-01-01T00:00:00Z","body":"Looks good"}
]
JSON
cat > "$SCRAPE/reviews.json" <<'JSON'
[
  {"id":4,"user":{"login":"greptile-apps[bot]","type":"Bot"},"submitted_at":"2026-01-01T00:01:00Z","body":"Check src/b.ts","commit_id":"abc123","state":"COMMENTED"}
]
JSON
cat > "$SCRAPE/review_comments.json" <<'JSON'
[
  {"id":5,"user":{"login":"coderabbit-ai[bot]","type":"Bot"},"created_at":"2026-01-01T00:02:00Z","body":"Inline issue","commit_id":"abc123","path":"src/c.ts","line":9}
]
JSON

scraped=$(ADAMS_REVIEW_FIXTURES_USER=smoke "$TOOLS/external-scrape.sh" --fixtures-dir "$SCRAPE")
if [[ "$(printf '%s' "$scraped" | jq 'length')" == "3" ]] \
   && printf '%s' "$scraped" | jq -e 'all(.author_type == "Bot")' >/dev/null \
   && ! printf '%s' "$scraped" | jq -e 'any(.author_login == "dependabot[bot]")' >/dev/null; then
    pass "external-scrape keeps reviewer bots and drops noise"
else
    fail "external-scrape fixture filtering failed" "$scraped"
fi

bad_code=$(rc "$TOOLS/external-scrape.sh" --pr 999999)
if [[ "$bad_code" != "0" ]]; then
    pass "external-scrape surfaces GitHub failures for fail-open caller handling"
else
    fail "external-scrape unexpectedly succeeded without fixture/auth context"
fi

# ---------------------------------------------------------------- source and grouping helpers

ordered=$(printf '%s\n' '[{"sources":["L7-holistic"],"file":"z.ts"},{"sources":["external-pr:coderabbit-ai[bot]"],"file":"b.ts"},{"sources":["L1-diff-local"],"file":"a.ts"}]' \
    | "$TOOLS/assign-finding-ids.sh" \
    | jq -r '[.[] | .id + ":" + .sources[0]] | join(",")')
if [[ "$ordered" == "F001:L1-diff-local,F002:L7-holistic,F003:external-pr:coderabbit-ai[bot]" ]]; then
    pass "assign-finding-ids preserves source priority including external-pr"
else
    fail "assign-finding-ids priority mismatch" "$ordered"
fi

echo "smoke: PASS ($N assertions)"
