#!/usr/bin/env bash
# monitor/watcher/test-issue-ref.sh
#
# monitor/issue-ref.sh — resolve a configured issue reference, or REFUSE
# (your-org/nexus-code#866).
#
# The property under test is NOT "does it parse owner/repo#N". It is:
# **does an unqualified value REFUSE rather than resolve?** The defect this
# exists to prevent was not a parse error — it was a bare number quietly paired
# with whichever repo the consumer supplied, so writes landed, succeeded, and
# were never seen. Every assertion below therefore checks that the ambiguous
# input produces a refusal, not merely that the good input works.

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REF="$_test_dir/../issue-ref.sh"

. "$_test_dir/_test_helpers.sh"

# Every assertion helper must EXIST before any is called. An undefined
# `assert_*` is not a failing assertion — it is rc 127, tallied by nothing,
# and the footer still says ALL TESTS PASSED with a quieter number.
for _th in assert_eq assert_contains assert_not_contains th_summary_and_exit; do
    declare -F "$_th" >/dev/null 2>&1 || {
        echo "FATAL: assertion helper '$_th' is not defined by _test_helpers.sh." >&2
        exit 1
    }
done

# rc_of <value> — exit code only
rc_of() { bash "$REF" "$1" --field test.field >/dev/null 2>&1; printf '%s' "$?"; }
out_of() { bash "$REF" "$1" --field test.field 2>&1; }

expect_rc() { # <desc> <expected> <value>
    assert_eq "$1" "$(rc_of "$3")" "$2"
}

echo '=== qualified references resolve, and carry BOTH halves ==='
expect_rc "owner/repo#N => rc 0" 0 'your-org/nexus-code#229'
out=$(out_of 'your-org/nexus-code#229')
assert_eq "…and prints the REPO half"  "$(sed -n 's/^REPO=//p'  <<<"$out")" 'your-org/nexus-code'
assert_eq "…and prints the ISSUE half" "$(sed -n 's/^ISSUE=//p' <<<"$out")" '229'
# The two repos this workspace actually confuses must BOTH resolve, and to
# themselves — the field is not restricted to one of them.
out=$(out_of 'your-org/your-nexus#229')
assert_eq "an asset-repo reference resolves to the ASSET repo" \
    "$(sed -n 's/^REPO=//p' <<<"$out")" 'your-org/your-nexus'
expect_rc "dots and dashes in owner/repo are accepted" 0 'my-org.x/my_repo.y#7'

echo '=== EMPTY is not a reference and not an error ==='
expect_rc "empty => rc 3" 3 ''
expect_rc "whitespace-only => rc 3" 3 '   '

echo '=== the defect itself: a BARE NUMBER must REFUSE, never resolve ==='
expect_rc "bare 229 => rc 4" 4 '229'
expect_rc "#229 => rc 4" 4 '#229'
expect_rc "quoted-looking bare number => rc 4" 4 ' 229 '
out=$(out_of '229')
assert_contains "…and explains that the repo is missing" "$out" "does not say WHICH REPO"
assert_contains "…and shows the exact corrected form, keeping the number" "$out" 'owner/repo#229'
# It must NOT pick a repo for you — the whole defect was a plausible guess.
assert_not_contains "…and emits NO REPO= line (it refuses rather than guessing)" "$out" 'REPO='

echo '=== half-qualified and malformed values also refuse ==='
expect_rc "repo without owner => rc 4" 4 'nexus-code#229'
expect_rc "owner/repo with no #N => rc 4" 4 'your-org/nexus-code'
expect_rc "trailing # with no number => rc 4" 4 'your-org/nexus-code#'
expect_rc "issue 0 => rc 4" 4 'your-org/nexus-code#0'
# A leading zero is a typo; accepting it would send a differently-spelled
# number to the API instead of refusing an input the operator did not mean.
expect_rc "leading-zero number => rc 4" 4 'your-org/nexus-code#0229'
out=$(out_of 'your-org/nexus-code#0229')
assert_contains "…and its remedy strips the leading zero" "$out" 'owner/repo#229'

echo '=== a pasted issue URL gets the exact translation, not a grammar lecture ==='
expect_rc "issue URL => rc 4" 4 'https://github.com/your-org/nexus-code/issues/229'
out=$(out_of 'https://github.com/your-org/nexus-code/issues/229')
assert_contains "…and prints the equivalent config form" "$out" 'your-org/nexus-code#229'

echo '=== the field name is echoed so the operator knows WHICH key to fix ==='
out=$(bash "$REF" '229' --field monitor.cc_auto_update.tracking_issue 2>&1)
assert_contains "names the offending config key" "$out" 'monitor.cc_auto_update.tracking_issue'

echo '=== DIFFERENTIAL: the two validators must agree on every input (#874 F4) ==='
# There are TWO implementations of one grammar — bash in issue-ref.sh, Python
# `re.match` in config/load.sh — and last round they were credited as "the same
# regex". The TEXT was the same; the SEMANTICS were not. `grep -E` anchors ^/$
# PER LINE, Python anchors to the STRING, so on a multi-line value the shell
# accepted a reference sitting on line 2 while Python refused it — an ACCEPT
# yielding a bogus repo.
#
# Asserting "they agree" is what failed. This RUNS both over one corpus and
# compares verdicts, so a future edit to either cannot silently diverge.
_diff_root="$(mktemp -d)"
trap 'rm -rf "$_diff_root"' EXIT
cp "$_test_dir/../../config/nexus.example.yml" "$_diff_root/example.yml"
_py_verdict() {  # accept|refuse, per config/load.sh --validate
    printf '%s\n' \
      'nexus: {root: /real/nexus, node_module: nodejs}' \
      'github:' '  repo: myorg/my-nexus' '  user_login: someone' \
      '  bot_app_id: 12345' '  bot_installation_id: 67890' \
      '  bot_pem_path: /real/key.pem' \
      'monitor:' '  cc_auto_update:' > "$_diff_root/c.yml"
    python3 -c 'import sys,json; print("    tracking_issue: " + json.dumps(sys.argv[1]))' \
        "$1" >> "$_diff_root/c.yml"
    if NEXUS_EXAMPLE_PATH="$_diff_root/example.yml" NEXUS_CONFIG="$_diff_root/c.yml" \
         bash "$_test_dir/../../config/load.sh" --validate >/dev/null 2>&1
    then printf 'accept'; else printf 'refuse'; fi
}
_sh_verdict() { # accept|refuse, per monitor/issue-ref.sh (empty => not a reference)
    bash "$REF" "$1" --field f >/dev/null 2>&1
    case $? in 0) printf 'accept' ;; *) printf 'refuse' ;; esac
}
while IFS= read -r _case; do
    [ -n "$_case" ] || continue
    _val=$(printf '%b' "$_case")
    # Label from the RAW case text with any backslash-escape neutralised: the
    # label goes through printf, so a literal \n in the case would split the
    # result line and make one assertion look like two.
    _label=${_case//\\/\\\\}
    assert_eq "validators agree on [${_label}]" "$(_sh_verdict "$_val")" "$(_py_verdict "$_val")"
done <<'CASES'
your-org/nexus-code#229
229
#229
nexus-code#229
your-org/nexus-code#0229
your-org/nexus-code#0
garbage\nyour-org/nexus-code#229
your-org/nexus-code#229\ngarbage
https://github.com/your-org/nexus-code/issues/229
CASES

# EXACT count, not a floor. `th_summary_and_exit` reports the assertions that
# RAN; a case that stops running is silently absent from that number unless it
# is compared against a declared total. No conditional cases here, so the count
# is exact — bump it deliberately when adding one; a DROP means a case died.
_EXPECTED_ASSERTIONS=31
_ran=$(( PASS + FAIL ))
assert_eq "every declared assertion executed ($_EXPECTED_ASSERTIONS)" "$_ran" "$_EXPECTED_ASSERTIONS"

th_summary_and_exit
