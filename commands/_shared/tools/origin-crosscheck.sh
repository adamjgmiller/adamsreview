#!/usr/bin/env bash
# origin-crosscheck.sh — blame-based origin classifier (DESIGN §13.11, §21.9).
#
# Takes a JSON array of Phase-1 candidates and a comparison ref, then uses
# `git blame` + `git merge-base --is-ancestor` to decide whether each
# candidate's line range is entirely pre-existing (every implicated SHA is
# reachable from $comparison_ref) vs. PR-modified. The §13.1 pre-existing
# override (origin=pre_existing AND origin_confidence=high →
# disposition=pre_existing_report) keys off origin, so correcting it here
# — before --add-finding — routes pre-existing candidates to the footnote
# section automatically.
#
# Decision table per candidate:
#   file not in comparison_ref tree      → respect lens (new-file)
#   blame fails                          → respect lens (skipped)
#   all SHAs reachable from comparison_ref:
#       lens already pre_existing/high   → respect (no-op)
#       otherwise                        → override to pre_existing/high
#   any SHA NOT reachable:
#       lens is pre_existing/high        → downgrade confidence to medium
#       otherwise                        → respect
#
# Usage:
#   origin-crosscheck.sh --comparison-ref <ref> --candidates <path|@-|inline-json>
#
# Input: JSON array of objects with at least {id, file, line_range, origin,
# origin_confidence}. Extra fields pass through untouched.
#
# Output: same array on stdout, with origin / origin_confidence possibly
# corrected. One stderr line per candidate:
#   origin_crosscheck: id=<id> action=<respected|overridden|downgraded|skipped>[ reason=<...>]
#
# Exits: 0 success (per-candidate blame failures do NOT abort the run —
# they're captured as action=skipped); 1 EXIT_VALIDATION (unknown ref,
# bad JSON); 5 EXIT_MISSING_DEP (no git, no jq); 64 usage.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --comparison-ref <ref> --candidates <path|@-|inline-json>

Blame-classifies each candidate's origin (DESIGN §13.11). Reads a JSON
array (via file path, stdin with "@-", or inline JSON on the command
line) and emits the same array with corrected {origin, origin_confidence}.
Per-candidate audit lines land on stderr.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }
die_validation() { echo "ERROR: $1" >&2; exit 1; }
die_missing_dep() { echo "ERROR: $1" >&2; exit 5; }

COMPARISON_REF=""
CANDIDATES_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --comparison-ref) COMPARISON_REF="${2:-}"; shift 2 ;;
        --candidates)     CANDIDATES_ARG="${2:-}"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$COMPARISON_REF" ]] || die_usage "--comparison-ref is required"
[[ -n "$CANDIDATES_ARG" ]] || die_usage "--candidates is required (path, @- for stdin, or inline JSON)"

command -v git >/dev/null 2>&1 || die_missing_dep "git not found on PATH"
command -v jq  >/dev/null 2>&1 || die_missing_dep "jq not found on PATH"

# Validate the ref up-front — error-as-prompt per DESIGN §8.6.
if ! git rev-parse --verify --quiet "$COMPARISON_REF" >/dev/null 2>&1; then
    {
        echo "ERROR: --comparison-ref '$COMPARISON_REF' did not resolve to a commit"
        echo "Context: origin-crosscheck.sh needs a ref that git rev-parse can resolve so blame-reachability checks have a valid anchor."
        echo "Valid values: any revspec git understands (branch name, tag, remote-tracking name, SHA)."
        echo "Did you mean:"
        git rev-parse --symbolic --branches --remotes=origin 2>/dev/null | head -10 | sed 's/^/  /'
        echo "Action: pass a ref that resolves (e.g. 'main', 'origin/main', or a full SHA)."
    } >&2
    exit 1
fi

# Load candidates into a variable (file path, stdin, or inline).
if [[ "$CANDIDATES_ARG" == "@-" ]]; then
    CANDIDATES_JSON="$(cat)"
elif [[ "${CANDIDATES_ARG:0:1}" == "@" ]]; then
    path="${CANDIDATES_ARG:1}"
    [[ -r "$path" ]] || die_validation "candidates file not readable: $path"
    CANDIDATES_JSON="$(cat "$path")"
elif [[ -f "$CANDIDATES_ARG" && "${CANDIDATES_ARG:0:1}" != "[" && "${CANDIDATES_ARG:0:1}" != "{" ]]; then
    CANDIDATES_JSON="$(cat "$CANDIDATES_ARG")"
else
    CANDIDATES_JSON="$CANDIDATES_ARG"
fi

# Validate shape — must be a JSON array.
if ! echo "$CANDIDATES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    die_validation "--candidates must parse as a JSON array; got $(echo "$CANDIDATES_JSON" | jq -r 'type' 2>/dev/null || echo 'unparseable JSON')"
fi

N=$(echo "$CANDIDATES_JSON" | jq 'length')

# Per-candidate processing. We emit corrected objects to a temp file then
# wrap them in an array for stdout.
out_tmp="$(mktemp)"
trap 'rm -f "$out_tmp"' EXIT

for (( i = 0; i < N; i++ )); do
    cand=$(echo "$CANDIDATES_JSON" | jq ".[$i]")
    cand_id=$(echo "$cand" | jq -r '.id // ("idx-" + (env.I // "'$i'"))' 2>/dev/null || echo "idx-$i")
    file=$(echo "$cand" | jq -r '.file // ""')
    start=$(echo "$cand" | jq -r '.line_range[0] // 0')
    end=$(echo "$cand" | jq -r '.line_range[1] // 0')
    lens_origin=$(echo "$cand" | jq -r '.origin // "introduced_by_pr"')
    lens_conf=$(echo "$cand" | jq -r '.origin_confidence // "high"')

    action="respected"
    reason=""
    new_origin="$lens_origin"
    new_conf="$lens_conf"

    if [[ -z "$file" || "$start" == "0" || "$end" == "0" ]]; then
        action="skipped"
        reason="missing file or line_range"
    elif ! git cat-file -e "$COMPARISON_REF:$file" 2>/dev/null; then
        # File did not exist at the comparison ref — trivially PR-introduced.
        action="respected"
        reason="new-file"
    else
        # Collect distinct commit SHAs from blame -L <start>,<end>.
        # Capture stderr so rc=128 is diagnosable in trace.md instead
        # of opaque — the reason string gets a "; <stderr first line>"
        # suffix on failure.
        _bl_err_tmp=$(mktemp)
        blame_rc=0
        blame_out=$(git blame -L "$start,$end" --porcelain HEAD -- "$file" 2>"$_bl_err_tmp") || blame_rc=$?
        blame_err=""
        if [[ $blame_rc -ne 0 ]]; then
            blame_err=$(head -c 200 "$_bl_err_tmp" 2>/dev/null | tr '\n' ' ' | awk '{$1=$1; print}')
        fi
        rm -f "$_bl_err_tmp"
        if [[ $blame_rc -ne 0 ]]; then
            action="skipped"
            reason="blame-failed rc=$blame_rc${blame_err:+; $blame_err}"
        else
            # Porcelain SHAs are 40 hex chars at column 1, followed by
            # line-number fields. Match strictly to avoid false-positives
            # on porcelain header lines ("author ...", "summary ...", etc.)
            # which ALSO start at column 1.
            shas=$(printf '%s\n' "$blame_out" \
                | awk '/^[0-9a-f]{40} / { print $1 }' \
                | awk '!seen[$0]++')
            if [[ -z "$shas" ]]; then
                action="skipped"
                reason="no-blame-shas"
            else
                all_ancestor=1
                for sha in $shas; do
                    if ! git merge-base --is-ancestor "$sha" "$COMPARISON_REF" 2>/dev/null; then
                        all_ancestor=0
                        break
                    fi
                done
                if [[ "$all_ancestor" == "1" ]]; then
                    # Every implicated SHA predates the PR.
                    if [[ "$lens_origin" == "pre_existing" && "$lens_conf" == "high" ]]; then
                        action="respected"
                        reason="blame-confirms-preexisting"
                    else
                        new_origin="pre_existing"
                        new_conf="high"
                        action="overridden"
                        reason="all-blame-ancestor-of-comparison-ref"
                    fi
                else
                    # At least one SHA is in comparison_ref..HEAD.
                    if [[ "$lens_origin" == "pre_existing" ]]; then
                        # Lens said pre-existing; blame disagrees. Downgrade
                        # confidence so §13.1 override does not fire, but
                        # keep the pre_existing label so the finding is still
                        # visible in its lane (§13.11 step 4).
                        if [[ "$lens_conf" == "high" ]]; then
                            new_conf="medium"
                            action="downgraded"
                            reason="blame-includes-pr-commits"
                        else
                            action="respected"
                            reason="already-non-high"
                        fi
                    else
                        action="respected"
                        reason="blame-includes-pr-commits"
                    fi
                fi
            fi
        fi
    fi

    # Emit audit line to stderr.
    if [[ -n "$reason" ]]; then
        echo "origin_crosscheck: id=$cand_id action=$action reason=$reason" >&2
    else
        echo "origin_crosscheck: id=$cand_id action=$action" >&2
    fi

    # Emit corrected candidate to out_tmp.
    echo "$cand" | jq --arg o "$new_origin" --arg c "$new_conf" \
        '.origin = $o | .origin_confidence = $c' >> "$out_tmp"
done

# Wrap the per-line objects back into an array.
jq -s '.' "$out_tmp"
