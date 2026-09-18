#!/usr/bin/env bash
# test-hook-matcher-body-coherence.sh — every tool a hook is REGISTERED for
# must be a tool its BODY accepts (your-org/nexus-code#936, credit: skeptic
# pass sk930, which built the first version of this audit).
#
# THE FAILURE THIS CATCHES IS SILENT BY CONSTRUCTION. A hook's reach is set in
# two places that nothing compares: the `matcher` in worker-settings.json, and
# the hook's own `tool_name` gate. When they disagree in the permissive
# direction — matcher routes a tool the body rejects — the hook is REGISTERED
# AND NEVER CONSULTED. Nothing errors. The next person greps
# worker-settings.json for a tool, sees the hook listed, and concludes it is
# covered.
#
# It is also a MERGE-ORDER hazard, which is why a review cannot catch it: the
# matcher and the body can live in two different open PRs, each coherent alone.
# `#947` widened `gh-write-guard`'s matcher and body together, and split the
# block it shared with `bash-footgun-guard` — then widened that hook's matcher
# too while its body change sat in `#933`. Neither PR was wrong; the defect
# existed only in one merge order. This suite is what makes that state a red
# rather than a fact somebody has to remember at merge time.
#
# THE SELF-CHECK IS THE LOAD-BEARING PART, and it is not decoration. sk930's
# first version of this audit reported `(none)` for two hooks whose gates it had
# already read by hand, because its pattern required `==` while a
# single-bracket test uses `=`. **An audit that silently finds nothing looks
# identical to a clean repo.** So this refuses to render a verdict at all unless
# it can still see a known-present population of gates.
#
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SETTINGS="$REPO_ROOT/monitor/worker-settings.json"
HOOK_DIR="$REPO_ROOT/monitor/hooks"

# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s (%s)\n' "$1" "${2:-}" >&2; _th_fail; }

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 77; }
[[ -r "$SETTINGS" ]] || { echo "missing $SETTINGS" >&2; exit 1; }

# _eq_tools <hook-path> -> tool names from an EQUALITY gate.
#
# Both bracket forms, because they differ: `[[ "$tool_name" == "Bash" ]]` and
# `[ "$_tool" = "Bash" ]`. Requiring `==` is the exact bug the self-check below
# exists to catch.
_eq_tools() {
    grep -oE '"\$(tool_name|_tool)"[[:space:]]*[=!]=?[[:space:]]*"[A-Za-z]+"' "$1" 2>/dev/null \
      | grep -oE '"[A-Za-z]+"$' | tr -d '"' | sort -u
}

# _case_tools <hook-path> -> tool names from a `case` gate:
#
#     case "$_tool" in
#         Bash|Monitor) ;;
#         *) exit 0 ;;
#     esac
#
# THIS ARM IS THE SAME BUG AS THE `==` ONE, ONE GATE FORM LATER, and it is not
# hypothetical: `your-org/nexus-code#933` replaced bash-footgun-guard's
# `[ "$_tool" = "Bash" ]` with exactly the above. With `#933` and `#947` both
# in the tree the equality-only extractor returns nothing for that hook and the
# SELF-CHECK below goes red — the instrument correctly refusing to certify a
# gate form it cannot read. Teaching it the form is the fix. NARROWING THE
# SELF-CHECK WOULD BE THE BUG, because a self-check that only asserts what the
# extractor already sees asserts nothing.
#
# `*` and other glob arms are skipped: they are the fall-through, not a tool.
_case_tools() {
    awk '
        /case[[:space:]]+"\$(tool_name|_tool)"[[:space:]]+in/ { inblock = 1; next }
        inblock && /^[[:space:]]*esac/                       { inblock = 0 }
        inblock && /\)/ {
            arm = $0
            sub(/\).*/, "", arm)
            gsub(/[[:space:]"(]/, "", arm)
            n = split(arm, pats, "|")
            for (i = 1; i <= n; i++)
                if (pats[i] ~ /^[A-Za-z]+$/) print pats[i]
        }
    ' "$1" 2>/dev/null | sort -u
}

# body_tools <hook-path> -> the tool names the body accepts, one per line;
# empty when the body has no tool gate this instrument can read at all.
body_tools() {
    { _eq_tools "$1"; _case_tools "$1"; } | sed '/^$/d' | sort -u
}

# references_tool <hook-path> -> rc 0 if the body mentions a tool variable at
# all. Distinguishes "no gate, accepts everything" from "gate present but my
# pattern could not read it", which must never be reported as coherent.
references_tool() { grep -qE '\$(tool_name|_tool)\b' "$1" 2>/dev/null; }

echo "=== self-check: the instrument can still see the gates it must see ==="
#
# Three hooks are known to carry a tool gate at every ref this suite has run
# against. If the extractor stops seeing them, its silence is a broken pattern,
# not a clean repo — so refuse to render the audit rather than pass it.
_known=0
for h in gh-write-guard async-launch-detect bash-footgun-guard; do
    f="$HOOK_DIR/$h.sh"
    [[ -r "$f" ]] || continue
    if references_tool "$f" && [[ -n "$(body_tools "$f")" ]]; then
        _known=$(( _known + 1 ))
    else
        bad "instrument blind on a known gate: $h" "body_tools returned nothing"
    fi
done
if (( _known >= 3 )); then
    ok "the gate extractor finds all $_known known tool gates"
else
    bad "SELF-CHECK FAILED — refusing to render a verdict" \
        "found $_known of 3 known gates; a silent audit is indistinguishable from a clean repo"
    th_summary_and_exit
fi

echo "=== every registered tool must be accepted by the hook's body ==="
_rows=0 _incoherent=0
while IFS=$'\t' read -r event matcher cmd; do
    [[ -n "$matcher" && "$matcher" != "null" ]] || continue     # null = universal
    hook="${cmd##*/}"
    f="$HOOK_DIR/$hook"
    [[ -r "$f" ]] || continue
    _rows=$(( _rows + 1 ))
    accepted=$(body_tools "$f")
    if [[ -z "$accepted" ]]; then
        if references_tool "$f"; then
            bad "$hook: body references a tool variable but no gate could be read" \
                "fail-closed: cannot certify coherence"
            _incoherent=$(( _incoherent + 1 ))
        else
            ok "$event $matcher -> $hook (no tool gate: accepts every routed tool)"
        fi
        continue
    fi
    missing=""
    IFS='|' read -r -a wanted <<<"$matcher"
    for t in "${wanted[@]}"; do
        grep -qxF -- "$t" <<<"$accepted" || missing="${missing}${t} "
    done
    if [[ -z "$missing" ]]; then
        ok "$event $matcher -> $hook (body accepts all routed tools)"
    else
        bad "$event $matcher -> $hook ROUTES A TOOL ITS BODY REJECTS" \
            "registered-and-never-consulted for: ${missing% }"
        _incoherent=$(( _incoherent + 1 ))
    fi
done < <(jq -r '.hooks | to_entries[] | .key as $e | .value[]
                | .matcher as $m | .hooks[]
                | [$e, ($m // "null"), .command] | @tsv' "$SETTINGS")

# NON-VACUITY. A jq that returned nothing, or a settings file that lost its
# tool-gated registrations, would otherwise sail through with zero rows.
if (( _rows >= 3 )); then
    ok "the audit examined $_rows tool-gated registrations (non-vacuous)"
else
    bad "audit examined only $_rows tool-gated registrations" \
        "expected at least 3; an empty enumeration is not a clean result"
fi

# COUNT GUARD. The row count varies with the settings file, so this pins the
# FIXED assertions (self-check + non-vacuity) and asserts the variable part is
# non-zero separately above. A case that stops running is a red, not a smaller
# green.
_EXPECTED_ASSERTIONS=$(( 2 + _rows ))
if (( PASS + FAIL == _EXPECTED_ASSERTIONS )); then
    ok "assertion count reconciles (2 fixed + $_rows per-registration)"
else
    bad "assertion count drifted" \
        "ran $(( PASS + FAIL )), expected $_EXPECTED_ASSERTIONS"
fi

echo "=== summary ==="
if (( _incoherent > 0 )); then
    printf '  %d registration(s) route a tool the body rejects.\n' "$_incoherent" >&2
    printf '  A hook widens its matcher ONLY in the PR that also widens its body.\n' >&2
    printf '  If the body change lives in another PR, leave the matcher to that PR.\n' >&2
fi
th_summary_and_exit
