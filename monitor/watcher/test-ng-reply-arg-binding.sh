#!/usr/bin/env bash
# `ng reply` / `ng comment` diagnostics must name the RIGHT token —
# your-org/nexus-code#858 B and C.
#
# B. Flags must follow the issue number. `ng comment --repo <owner/name>
#    <issue> …` bound `--repo` into the issue slot and then reported the
#    REPO as an unknown *flag* — which reads as "that repo is not
#    recognised" rather than "that argument is in the wrong position",
#    and sends the reader off checking install scope and tokens.
#
# C. The body comes from stdin, not a positional. A positional body was
#    rejected loudly, but the error text SPANNED THE BODY'S OWN LINES —
#    so the standard capture idiom for a write verb,
#    `url=$(ng … | tail -1)`, yielded the body's last line: no `ng:`
#    prefix, no visible rc, and a string plausible enough to be fed
#    onward to `assert-bot-author.sh`, whose refusal then reads as "the
#    URL capture failed" rather than "the write never happened".
#
# Both are LOUD failures, so neither is a correctness bug. They are
# misdirection: the tool knew exactly what was wrong and pointed
# somewhere else. The assertions below are about WHERE the diagnostic
# points and what survives a `| tail -1`, because that is the defect.
#
# Run: bash monitor/watcher/test-ng-reply-arg-binding.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-858-bc-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

setup_fake_nexus "$WORK/nexus" --allow-default --repo 'your-org/example-nexus'
NG="$FAKE_NEXUS/monitor/ng"

STUB_DIR="$WORK/bin"
CAPTURE="$WORK/gh-calls.txt"

# A `gh` that records every call and would happily "succeed" — so any
# assertion that a write did NOT happen is about `ng` refusing, never
# about the stub being unable to.
make_gh_stub "$STUB_DIR/gh" "$CAPTURE" <<'CASES'
    */comments*)
        printf '%s' '{"html_url":"https://mock.example/issues/846#issuecomment-1"}'
        ;;
    *)
        printf '%s' '{}'
        ;;
CASES

NEUTRAL_CWD="$WORK/neutral"; mkdir -p "$NEUTRAL_CWD"

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE"
    ( cd "$NEUTRAL_CWD" && run_hermetic \
        NEXUS_ROOT="$FAKE_NEXUS" \
        NEXUS_STATE_DIR="$WORK/state" \
        PATH="$STUB_DIR:$PATH" \
        -- "$NG" "$@" </dev/null ) >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# ---- B: a flag in the issue slot ---------------------------------------

echo '=== B: ng comment --repo <r> <issue> blames the POSITION, not the repo ==='
run_ng out err rc comment --repo your-org/nexus-code 846 --body-file /dev/null
assert_eq       "exit 1"                              "$rc" "1"
assert_contains "the diagnostic names the ORDER rule" "$err" 'ISSUE NUMBER first'
assert_contains "…and names the misplaced FLAG"       "$err" "'--repo'"
# The whole point: the repo must NOT be presented as the unrecognised
# thing. That is the sentence that sent the reader to check install scope.
assert_not_contains "the repo is not called an unknown flag" \
    "$err" 'unknown flag: your-org/nexus-code'
assert_eq "no write was attempted" "$(<"$CAPTURE")" ""

echo '=== B: ng reply <issue> --repo <r> (the correct order) is NOT rejected ==='
run_ng out err rc reply 846 --repo your-org/nexus-code --body-file /dev/null
# /dev/null is an empty body, so this dies on the body — the point is
# that it gets PAST argument binding rather than being rejected for it.
assert_not_contains "the correct order is not an ordering error" "$err" 'ISSUE NUMBER first'

# ---- C: a positional body ----------------------------------------------

echo '=== C: a positional body is named as such, truncated to one line ==='
BODY=$'first line of body\nMIDDLE LINE\nLAST LINE OF BODY'
run_ng out err rc reply 846 "$BODY"
assert_eq       "exit 1"                                  "$rc" "1"
assert_contains "the diagnostic says the body is stdin"   "$err" 'body on STDIN or via --body-file'
assert_contains "…and quotes only the FIRST line"         "$err" "'first line of body'"
assert_contains "…and names how much it dropped"          "$err" '(+2 more line(s))'
assert_not_contains "the body's later lines are NOT echoed back" "$err" 'LAST LINE OF BODY'
assert_not_contains "…nor its middle"                            "$err" 'MIDDLE LINE'
assert_eq "no write was attempted" "$(<"$CAPTURE")" ""

echo '=== C: what `| tail -1` captures is unmistakably a diagnostic ==='
LAST=$(printf '%s\n' "$err" | tail -1)
assert_contains "the last line still carries the ng: prefix" "$LAST" 'ng: '
assert_not_contains "…and is not the caller's own body text"  "$LAST" 'LAST LINE OF BODY'
assert_not_contains "…and could not be mistaken for a URL"    "$LAST" 'https://'
# Every line, not just the last: a multi-line diagnostic that prefixed
# only its first line is what made the tail-capture plausible.
unprefixed=$(grep -cv '^ng: ' <<<"$err")
assert_eq "every stderr line is prefixed" "$unprefixed" "0"

echo '=== C: a non-numeric issue is named as the issue, not as a flag ==='
run_ng out err rc reply notanumber --body-file /dev/null
assert_eq       "exit 1"                          "$rc" "1"
assert_contains "the diagnostic names the slot"   "$err" 'issue/PR NUMBER first'
assert_contains "…and quotes the offending token" "$err" "'notanumber'"

echo '=== an unknown flag is still reported as an unknown flag ==='
run_ng out err rc reply 846 --bogus x
assert_eq       "exit 1"                        "$rc" "1"
assert_contains "unknown flag still says so"    "$err" "unknown flag: '--bogus'"
assert_not_contains "…and is not misread as a positional body" \
    "$err" 'body on STDIN'

# ---- the positive control ----------------------------------------------
#
# Everything above asserts a refusal. A `cmd_reply` that refused
# unconditionally would pass all of it, so assert the verb still posts.

echo '=== positive control: a well-formed reply still posts ==='
printf 'a real body\n' > "$WORK/body.md"
run_ng out err rc reply 846 --body-file "$WORK/body.md"
assert_eq       "exit 0"                     "$rc" "0"
assert_contains "the comment URL is printed" "$out" 'issuecomment-1'
assert_contains "a POST was issued"          "$(<"$CAPTURE")" '/comments'

# EXPECTED-COUNT GUARD (required by test-summary-honesty-manifest.sh at the
# `ledger=yes` protection level).
#   5  B — a flag in the issue slot
# + 1  B — the correct order is not rejected
# + 7  C — a positional body, named and truncated
# + 4  C — what `| tail -1` captures
# + 3  C — a non-numeric issue
# + 3  an unknown flag is still an unknown flag
# + 3  positive control: a well-formed reply still posts
EXPECTED=$(( 5 + 1 + 7 + 4 + 3 + 3 + 3 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
