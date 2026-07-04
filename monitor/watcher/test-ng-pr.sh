#!/usr/bin/env bash
# Unit tests for `ng pr` and its sub-verbs (cmd_pr / cmd_pr_create /
# cmd_pr_edit / cmd_pr_merge / cmd_pr_view in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-pr.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: PATH-shadow `gh` via make_gh_stub. Drive `ng pr <verb>`
# and assert on captured endpoint / method, request-body JSON payload,
# and the verb's stdout (URL or SHA) / stderr / exit code.
#
# Coverage map (from your-org/nexus-code#51):
#   cmd_pr dispatch — usage on missing subcommand.
#   cmd_pr_create — required --head, required --title, required body;
#     default --reviewer = github.user_login; --no-reviewer skips the
#     requested_reviewers POST; --reviewer <login> overrides; reviewer
#     POST failure is a warning, not fatal; --base defaults to main;
#     --repo override.
#   cmd_pr_edit — pure --title, pure --body-file, both together; usage
#     when neither is passed.
#   cmd_pr_merge — default method=squash, --merge / --rebase / --squash
#     toggle, --delete-branch fires a DELETE on git/refs/heads/<ref>.
#   cmd_pr_view — read-only one-liner from canned meta.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-ng-pr-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

setup_fake_nexus "$WORK/nexus"
NG="$FAKE_NEXUS/monitor/ng"

STUB_DIR="$WORK/bin"
CAPTURE="$WORK/gh-calls.txt"
BODY_CAPTURE="$WORK/gh-body.txt"

# Reviewer-POST failure toggle: `MOCK_REVIEWER_FAIL=1` makes the
# requested_reviewers endpoint exit 1 (ng must downgrade to a warning,
# not abort the verb).
make_gh_stub "$STUB_DIR/gh" "$CAPTURE" --with-body-capture "$BODY_CAPTURE" <<'CASES'
    */pulls/*/requested_reviewers)
        if [[ "${MOCK_REVIEWER_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock 422 — not a collaborator"}' >&2
            exit 1
        fi
        printf '%s' '{"users":[{"login":"reviewer-x"}]}'
        ;;
    */pulls/*/merge)
        printf '%s' '{"sha":"abc1234deadbeef","merged":true}'
        ;;
    */pulls/*)
        if [[ "$method" == "PATCH" ]]; then
            printf '%s' '{"html_url":"https://mock.example/pulls/42-edited","number":42}'
        elif [[ "$method" == "GET" ]]; then
            printf '%s' '{"number":42,"state":"open","user":{"login":"the-author"},"head":{"ref":"feature-branch"},"base":{"ref":"main"},"title":"a pr title"}'
        else
            printf '%s' '{}'
        fi
        ;;
    */pulls)
        printf '%s' '{"html_url":"https://mock.example/pulls/42","number":42}'
        ;;
    */git/refs/heads/*)
        printf '%s' '{}'
        ;;
    *)
        printf '%s' '{}'
        ;;
CASES

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
        MOCK_REVIEWER_FAIL="${MOCK_REVIEWER_FAIL:-0}" \
        -- "$NG" "$@" ) >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

PR_BODY="$WORK/pr-body.md"
echo "pr description here" > "$PR_BODY"

# ---- Test 1: cmd_pr dispatch — missing subcommand ----------------------

echo '=== ng pr (no subcommand) → usage ==='
run_ng out err rc pr
assert_eq        "exit non-zero"                     "$rc" "1"
assert_contains  "stderr names sub-verbs"            "$err" "ng pr create|edit|merge|view"

# ---- Test 2: cmd_pr_create — required --head ---------------------------

echo '=== ng pr create without --head → exit 1 ==='
run_ng out err rc pr create --title "x" --body-file "$PR_BODY"
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names missing --head"       "$err" "--head is required"

# ---- Test 3: cmd_pr_create — required --title -------------------------

echo '=== ng pr create without --title → exit 1 ==='
run_ng out err rc pr create --head feature --body-file "$PR_BODY"
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names missing --title"      "$err" "--title is required"

# ---- Test 4: cmd_pr_create — empty body → exit 1 -----------------------

echo '=== ng pr create with empty body → exit 1 ==='
: > "$WORK/empty.md"
run_ng out err rc pr create --head feature --title "x" --body-file "$WORK/empty.md"
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names empty body"           "$err" "empty body"

# ---- Test 5: cmd_pr_create — happy path with default reviewer ---------
#
# Note on body capture: make_gh_stub's --with-body-capture overwrites
# the file on each POST, so a multi-POST verb (pulls POST followed by
# requested_reviewers POST) leaves only the *last* body captured.
# Test 5 uses --no-reviewer so the only POST captured is the /pulls
# one — this lets us assert on the base/head/title/body payload.
# Default-reviewer behaviour is exercised by test 6/7/8.

echo '=== ng pr create --no-reviewer → POST pulls with full payload shape ==='
run_ng out err rc pr create --head feature --title "the title" --body-file "$PR_BODY" --no-reviewer
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout prints the pr html_url"     "$out" "https://mock.example/pulls/42"
calls=$(<"$CAPTURE")
assert_contains  "POST hits /pulls"                  "$calls" "-X POST /repos/default-org/default-repo/pulls"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload has head"                  "$body" '"head":"feature"'
assert_contains  "default base = main"               "$body" '"base":"main"'
assert_contains  "payload has title"                 "$body" '"title":"the title"'
assert_contains  "payload has body"                  "$body" '"body":"pr description here'

echo '=== ng pr create (defaults) → requested_reviewers POST fires ==='
run_ng out err rc pr create --head feature --title "x" --body-file "$PR_BODY"
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "requested_reviewers POST fires"    "$calls" "-X POST /repos/default-org/default-repo/pulls/42/requested_reviewers"
# The last body captured is the reviewer payload; assert it names the
# default reviewer (config github.user_login = "test-user").
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "reviewer payload names default"    "$body" '"reviewers":["test-user"]'

# ---- Test 6: cmd_pr_create — --no-reviewer skips the reviewers POST ----

echo '=== ng pr create --no-reviewer → no requested_reviewers POST ==='
run_ng out err rc pr create --head feature --title "x" --body-file "$PR_BODY" --no-reviewer
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_not_contains "no reviewer POST when --no-reviewer" "$calls" "/requested_reviewers"

# ---- Test 7: cmd_pr_create — --reviewer <login> override --------------

echo '=== ng pr create --reviewer custom-login → custom POSTed ==='
run_ng out err rc pr create --head feature --title "x" --body-file "$PR_BODY" --reviewer custom-login
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "reviewer POST endpoint hit"        "$calls" "/requested_reviewers"
# The request body for the reviewer POST was the second piped JSON of
# the test; only one body file is captured per run (the last write
# wins). That last body is the reviewer payload — assert it carries
# the custom login.
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "reviewer payload names custom"     "$body" '"reviewers":["custom-login"]'

# ---- Test 8: cmd_pr_create — reviewer POST failure → warning, not fatal

echo '=== ng pr create with reviewer POST 422 → exit 0 + warning ==='
MOCK_REVIEWER_FAIL=1 run_ng out err rc pr create \
    --head feature --title "x" --body-file "$PR_BODY"
assert_eq        "exit 0 despite reviewer failure"   "$rc" "0"
assert_contains  "stdout still prints pr URL"        "$out" "https://mock.example/pulls/42"
assert_contains  "stderr names a reviewer warning"   "$err" "failed to request review"

# ---- Test 9: cmd_pr_create — --base override --------------------------

echo '=== ng pr create --base release ==='
run_ng out err rc pr create --head feature --base release --title "x" --body-file "$PR_BODY"
assert_eq        "exit 0"                            "$rc" "0"
# The last body captured is the reviewer payload; assert against the
# first PR-create payload by inspecting the captured argv instead.
calls=$(<"$CAPTURE")
assert_contains  "/pulls POST present"               "$calls" "-X POST /repos/default-org/default-repo/pulls"

# ---- Test 10: cmd_pr_create — --repo override ------------------------

echo '=== ng pr create --repo override-org/override-repo ==='
run_ng out err rc pr create --repo override-org/override-repo \
    --head feature --title "x" --body-file "$PR_BODY" --no-reviewer
# Note: ng calls _preflight_repo for non-$REPO targets before POSTing.
# The preflight makes a GraphQL call (`gh api graphql ...`) — our stub
# returns `{}` by default, which lacks the expected viewerPermission
# field, so the preflight will exit 1 and ng aborts. Verify the
# preflight at least *fired* before failure (i.e. resolution worked),
# and confirm the verb's structured error surfaces.
assert_eq        "exit 1 (preflight stub returns empty)" "$rc" "1"
assert_contains  "stderr names preflight failure"    "$err" "preflight failed for override-org/override-repo"

# ---- Test 11: cmd_pr_edit — usage when neither --title nor --body-file -

echo '=== ng pr edit 42 (no flags) → usage ==='
run_ng out err rc pr edit 42
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names usage"                "$err" "--title and/or --body-file"

# ---- Test 12: cmd_pr_edit — --title only --------------------------------

echo '=== ng pr edit 42 --title only ==='
run_ng out err rc pr edit 42 --title "new title"
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout prints updated URL"         "$out" "https://mock.example/pulls/42-edited"
calls=$(<"$CAPTURE")
assert_contains  "PATCH /pulls/42"                   "$calls" "-X PATCH /repos/default-org/default-repo/pulls/42"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload has title"                 "$body" '"title":"new title"'
assert_not_contains "no body key in payload"         "$body" '"body":'

# ---- Test 13: cmd_pr_edit — --body-file only ----------------------------

echo '=== ng pr edit 42 --body-file only ==='
echo "new body content" > "$WORK/edit-body.md"
run_ng out err rc pr edit 42 --body-file "$WORK/edit-body.md"
assert_eq        "exit 0"                            "$rc" "0"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload has body"                  "$body" '"body":"new body content'
assert_not_contains "no title key in payload"        "$body" '"title":'

# ---- Test 14: cmd_pr_edit — both --title and --body-file ---------------

echo '=== ng pr edit 42 --title --body-file ==='
run_ng out err rc pr edit 42 --title "T" --body-file "$WORK/edit-body.md"
assert_eq        "exit 0"                            "$rc" "0"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload has title"                 "$body" '"title":"T"'
assert_contains  "payload has body"                  "$body" '"body":'

# ---- Test 15: cmd_pr_merge — default method = squash -------------------

echo '=== ng pr merge 42 → squash ==='
run_ng out err rc pr merge 42
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout prints merge SHA"           "$out" "abc1234deadbeef"
calls=$(<"$CAPTURE")
assert_contains  "PUT /pulls/42/merge"               "$calls" "-X PUT /repos/default-org/default-repo/pulls/42/merge"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload merge_method=squash"       "$body" '"merge_method":"squash"'

# ---- Test 16: cmd_pr_merge — --merge / --rebase ------------------------

echo '=== ng pr merge 42 --merge ==='
run_ng out err rc pr merge 42 --merge
assert_eq        "exit 0"                            "$rc" "0"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload merge_method=merge"        "$body" '"merge_method":"merge"'

echo '=== ng pr merge 42 --rebase ==='
run_ng out err rc pr merge 42 --rebase
assert_eq        "exit 0"                            "$rc" "0"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload merge_method=rebase"       "$body" '"merge_method":"rebase"'

# ---- Test 17: cmd_pr_merge — --delete-branch fires a DELETE -----------

echo '=== ng pr merge 42 --delete-branch → DELETE git/refs/heads/<ref> ==='
run_ng out err rc pr merge 42 --delete-branch
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "DELETE on branch ref"              "$calls" "-X DELETE /repos/default-org/default-repo/git/refs/heads/feature-branch"

echo '=== ng pr merge 42 (no --delete-branch) → no DELETE ==='
run_ng out err rc pr merge 42
calls=$(<"$CAPTURE")
assert_not_contains "no DELETE without flag"         "$calls" "-X DELETE"

# ---- Test 18: cmd_pr_view — one-liner from canned meta -----------------

echo '=== ng pr view 42 → one-liner ==='
run_ng out err rc pr view 42
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "one-liner shape"                   "$out" "#42 state=OPEN author=the-author feature-branch->main title=a pr title"

# ---- Test 19: cmd_pr_view --json — scriptable JSON output (#236 B4) -----

echo '=== ng pr view 42 --json (bare) → full object ==='
run_ng out err rc pr view 42 --json
assert_eq        "exit 0"                            "$rc" "0"
# Valid JSON carrying the canned fields.
assert_eq        "number parses from JSON"           "$(jq -r '.number' <<<"$out")" "42"
assert_eq        "nested head.ref present"           "$(jq -r '.head.ref' <<<"$out")" "feature-branch"

echo '=== ng pr view 42 --json number,state,title → field selection ==='
run_ng out err rc pr view 42 --json number,state,title
assert_eq        "exit 0"                            "$rc" "0"
assert_eq        "selected number"                   "$(jq -r '.number' <<<"$out")" "42"
assert_eq        "selected state"                    "$(jq -r '.state'  <<<"$out")" "open"
assert_eq        "selected title"                    "$(jq -r '.title'  <<<"$out")" "a pr title"
# Unselected fields must be absent.
assert_eq        "unselected field absent"           "$(jq -r 'has("base")' <<<"$out")" "false"

echo '=== ng pr view 42 --json head.ref → dotted path selection ==='
run_ng out err rc pr view 42 --json head.ref
assert_eq        "exit 0"                            "$rc" "0"
assert_eq        "dotted-path key resolves"          "$(jq -r '."head.ref"' <<<"$out")" "feature-branch"

echo '=== ng pr view 42 --json <missing-field> → null, not error ==='
run_ng out err rc pr view 42 --json number,nonexistent_field
assert_eq        "exit 0 (missing field tolerated)"  "$rc" "0"
assert_eq        "missing field is null"             "$(jq -r '.nonexistent_field' <<<"$out")" "null"

echo '=== ng pr view --json with --repo after it parses cleanly ==='
run_ng out err rc pr view 42 --json --repo owner/name
assert_eq        "exit 0 (bare --json then --repo)"  "$rc" "0"
assert_eq        "number parses"                     "$(jq -r '.number' <<<"$out")" "42"

echo '=== ng pr view --json injection-guarded field name → refused ==='
run_ng out err rc pr view 42 --json 'number)|.bad'
assert_eq        "exit non-zero on invalid field"    "$rc" "1"
assert_contains  "stderr flags invalid field"        "$err" "invalid field name"

# ---- summary -----------------------------------------------------------

th_summary_and_exit
