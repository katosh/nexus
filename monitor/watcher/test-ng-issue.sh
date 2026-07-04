#!/usr/bin/env bash
# Unit tests for `ng issue` and its sub-verbs (cmd_issue / cmd_issue_view
# / cmd_issue_create / cmd_issue_comment in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-issue.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: PATH-shadow `gh` via make_gh_stub to capture argv (the
# endpoint + method combination is the load-bearing assertion). Drive
# `ng issue <verb>` and check both captured calls and the exit code /
# stdout / stderr.
#
# Coverage map (from your-org/nexus-code#51, follow-up to #39):
#   cmd_issue dispatch — numeric → view, named subcommands, error
#     paths for missing arg / unknown subcommand.
#   cmd_issue_view — one-liner default, --with-body, --with-comments,
#     --repo override, missing-issue (empty meta) failure.
#   cmd_issue_create — required --title, required body, label encoding
#     (zero / one / many), --repo write target.
#   cmd_issue_comment — required <n>, body from --body-file vs. stdin,
#     POST endpoint shape.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-ng-issue-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

setup_fake_nexus "$WORK/nexus"
NG="$FAKE_NEXUS/monitor/ng"

STUB_DIR="$WORK/bin"
CAPTURE="$WORK/gh-calls.txt"
BODY_CAPTURE="$WORK/gh-body.txt"

# `gh` stub:
#   GET  /repos/.../issues/<n>          → canned meta (number/state/title/body)
#                                          unless MOCK_EMPTY=1 (→ "{}").
#   GET  /repos/.../issues/<n>/comments → canned 2-comment array.
#   POST /repos/.../issues              → {html_url:"https://mock/issue-7"}.
#   POST /repos/.../issues/<n>/comments → {html_url:"https://mock/comment-99"}.
#   Anything else                       → empty JSON object.
make_gh_stub "$STUB_DIR/gh" "$CAPTURE" --with-body-capture "$BODY_CAPTURE" <<'CASES'
    */issues/*/comments*)
        if [[ "$method" == "POST" ]]; then
            printf '%s' '{"html_url":"https://mock.example/comment-99"}'
        else
            printf '%s' '[{"created_at":"2026-05-12T10:00:00Z","user":{"login":"a"},"body":"first"},{"created_at":"2026-05-12T11:00:00Z","user":{"login":"b"},"body":"second"}]'
        fi
        ;;
    */issues)
        printf '%s' '{"html_url":"https://mock.example/issue-7","number":7}'
        ;;
    */issues/*)
        if [[ "${MOCK_EMPTY:-0}" == "1" ]]; then
            printf '%s' '{}'
        else
            printf '%s' '{"number":42,"state":"open","title":"the title","body":"the body content"}'
        fi
        ;;
    *)
        printf '%s' '{}'
        ;;
CASES

# Non-git cwd: ng's write verbs cwd-derive and would refuse to run when
# the test happens to live inside a git worktree whose origin differs
# from the config $REPO (issue #108 misroute block). The view verbs
# don't refuse, but they do emit a stderr warning when the cwd-origin
# differs — keeping the cwd neutral avoids both surfaces.
NEUTRAL_CWD="$WORK/neutral"
mkdir -p "$NEUTRAL_CWD"

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE"; : > "$BODY_CAPTURE"
    ( cd "$NEUTRAL_CWD" && run_hermetic \
        NEXUS_STATE_DIR="$WORK/state" \
        PATH="$STUB_DIR:$PATH" \
        MOCK_EMPTY="${MOCK_EMPTY:-0}" \
        -- "$NG" "$@" ) >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# ---- Test 1: dispatch — missing arg / unknown subcommand ---------------

echo '=== dispatch: missing arg / unknown subcommand ==='
run_ng out err rc issue
assert_eq        "no arg → exit non-zero"            "$rc" "1"
assert_contains  "stderr lists subcommands"          "$err" "ng issue create"

run_ng out err rc issue gibberish
assert_eq        "non-numeric non-subcmd → non-zero" "$rc" "1"
assert_contains  "stderr names the bad subcmd"       "$err" "not a known subcommand: gibberish"

# ---- Test 2: cmd_issue_view default (numeric dispatch) ------------------

echo '=== ng issue 42 → one-liner from canned meta ==='
run_ng out err rc issue 42
assert_eq        "exit 0 on happy path"              "$rc" "0"
assert_contains  "one-liner state ascii-upcased"     "$out" "#42 state=OPEN title=the title"
assert_not_contains "no --with-body section by default" "$out" "--- body ---"
assert_not_contains "no --with-comments by default"  "$out" "--- comments ---"
calls=$(<"$CAPTURE")
assert_contains  "GET /issues/42"                    "$calls" "/repos/default-org/default-repo/issues/42"

# ---- Test 3: --with-body appends body section --------------------------

echo '=== ng issue 42 --with-body ==='
run_ng out err rc issue 42 --with-body
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "body header appears"               "$out" "--- body ---"
assert_contains  "body content rendered"             "$out" "the body content"

# ---- Test 4: --with-comments triggers paginate hit ---------------------

echo '=== ng issue 42 --with-comments ==='
run_ng out err rc issue 42 --with-comments
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "comments header appears"           "$out" "--- comments ---"
assert_contains  "first comment rendered"            "$out" "first"
assert_contains  "second comment rendered"           "$out" "second"
calls=$(<"$CAPTURE")
assert_contains  "comments endpoint hit"             "$calls" "/issues/42/comments"

# ---- Test 5: --repo override on view --------------------------------

echo '=== ng issue 42 --repo other-org/other-repo ==='
run_ng out err rc issue 42 --repo other-org/other-repo
assert_eq        "exit 0 with --repo override"       "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "GET hits override repo"            "$calls" "/repos/other-org/other-repo/issues/42"
assert_not_contains "no fallback to config default"  "$calls" "/repos/default-org/default-repo/issues/42"

# ---- Test 6: missing-issue failure mode --------------------------------

echo '=== ng issue 42 with empty meta → exit non-zero ==='
MOCK_EMPTY=1 run_ng out err rc issue 42
assert_eq        "exit non-zero on empty meta"       "$rc" "1"
assert_contains  "stderr mentions fetch failure"     "$err" "issue 42: fetch failed"

# ---- Test 7: cmd_issue_create — required --title --------------------------

echo '=== ng issue create without --title → exit 1 ==='
echo "body content" > "$WORK/body.md"
run_ng out err rc issue create --body-file "$WORK/body.md"
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names missing --title"      "$err" "--title is required"

# ---- Test 8: cmd_issue_create — required body --------------------------

echo '=== ng issue create with empty body → exit 1 ==='
: > "$WORK/empty.md"
run_ng out err rc issue create --title "test" --body-file "$WORK/empty.md"
assert_eq        "exit 1 on empty body"              "$rc" "1"
assert_contains  "stderr names empty-body failure"   "$err" "empty body"

# ---- Test 9: cmd_issue_create — happy path, no labels -------------------

echo '=== ng issue create --title --body-file → POST returns URL ==='
run_ng out err rc issue create --title "the title" --body-file "$WORK/body.md"
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout prints the html_url"        "$out" "https://mock.example/issue-7"
calls=$(<"$CAPTURE")
assert_contains  "POST hits /issues endpoint"        "$calls" "-X POST /repos/default-org/default-repo/issues"
# Body payload was piped via --input -; verify the JSON shape. jq's
# default formatter pretty-prints, so normalise to compact JSON before
# substring-matching.
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload includes title"            "$body" '"title":"the title"'
assert_contains  "payload includes body"             "$body" '"body":"body content'
assert_not_contains "no labels key emitted when none passed" "$body" '"labels"'

# ---- Test 10: cmd_issue_create — labels encoded as JSON array -----------

echo '=== ng issue create --label a --label b → payload labels:[a,b] ==='
run_ng out err rc issue create --title "t" --body-file "$WORK/body.md" --label bug --label triage
assert_eq        "exit 0"                            "$rc" "0"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload has labels key as JSON array" "$body" '"labels":["bug","triage"]'

# ---- Test 11: cmd_issue_create — --repo override -----------------------

echo '=== ng issue create --repo OWNER/NAME → POST hits OWNER/NAME ==='
run_ng out err rc issue create --repo override-org/override-repo \
    --title "t" --body-file "$WORK/body.md"
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "POST endpoint embeds --repo"       "$calls" "/repos/override-org/override-repo/issues"
assert_not_contains "no fallback to config default"  "$calls" "/repos/default-org/default-repo/issues"

# ---- Test 12: cmd_issue_create — unknown flag --------------------------

echo '=== ng issue create --bogus → exit 1 ==='
run_ng out err rc issue create --bogus foo --title t --body-file "$WORK/body.md"
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names the unknown flag"     "$err" "unknown flag: --bogus"

# ---- Test 13: cmd_issue_comment — required <n> --------------------------

echo '=== ng issue comment without <n> → exit 1 ==='
run_ng out err rc issue comment
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr mentions usage"             "$err" "usage: ng issue comment"

# ---- Test 14: cmd_issue_comment — body-file path -----------------------

echo '=== ng issue comment 7 --body-file → POST hits /issues/7/comments ==='
echo "hello world" > "$WORK/c.md"
run_ng out err rc issue comment 7 --body-file "$WORK/c.md"
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "POST hits /issues/7/comments"      "$calls" "-X POST /repos/default-org/default-repo/issues/7/comments"
# Comment body posted as plain text via _post_body (raw string body).
body=$(<"$BODY_CAPTURE")
assert_contains  "posted body contains the text"     "$body" "hello world"

# ---- Test 15: cmd_issue_comment — --repo override ----------------------

echo '=== ng issue comment 9 --repo X → POST hits X ==='
run_ng out err rc issue comment 9 --repo other-org/other-repo --body-file "$WORK/c.md"
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "POST endpoint embeds --repo"       "$calls" "/repos/other-org/other-repo/issues/9/comments"

# ---- summary -----------------------------------------------------------

th_summary_and_exit
