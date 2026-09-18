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
        # #628: model GitHub's 409 when the pinned head no longer matches the
        # branch head. The body (with the pinned sha) is captured to the body
        # file for the test to assert on; the 409 path is driven by env so the
        # stub need not parse stdin.
        if [[ "${MOCK_MERGE_409:-0}" == "1" ]]; then
            echo '{"message":"Head branch was modified. Review and try the merge again."}'
            echo 'gh: Head branch was modified. Review and try the merge again. (HTTP 409)' >&2
            exit 1
        fi
        printf '%s' '{"sha":"abc1234deadbeef","merged":true}'
        ;;
    */pulls/*)
        # `_merge_ref_base` asks this endpoint for the base BRANCH NAME via
        # `--jq .base.ref`; `cmd_pr_merge` wants the whole object. ONE
        # GitHub-shaped object, served through `ghs_emit`, answers both: the
        # caller's own expression is EVALUATED (your-org/nexus-code#932), so
        # the #880 workaround — `if [[ "$jq_expr" == *base.ref* ]]; then
        # printf 'main'` — is gone, and a selection defect in the expression
        # is now VISIBLE to this suite instead of digested away.
        if [[ "$method" == "PATCH" ]]; then
            ghs_emit <<< '{"html_url":"https://mock.example/pulls/42-edited","number":42}'
        elif [[ "$method" == "GET" ]]; then
            ghs_emit <<< '{"number":42,"state":"open","user":{"login":"the-author"},"head":{"ref":"feature-branch","sha":"fetchedhead000"},"base":{"ref":"main"},"title":"a pr title"}'
        else
            ghs_emit <<< '{}'
        fi
        ;;
    */pulls)
        printf '%s' '{"html_url":"https://mock.example/pulls/42","number":42}'
        ;;
    */actions/runs?head_sha=*)
        # your-org/nexus-code#880's --verify-base runs the REAL _merge_ref_base,
        # which needs the run list (with its TOTALCOUNT header), the jobs list
        # and a job log. Empty by default so every pre-existing case keeps its
        # meaning: no runs -> `unread` -> permit -> the merge proceeds untouched.
        printf 'TOTALCOUNT 1\n'
        printf '%s\n' "${MOCK_MRB_RUN:-}"
        ;;
    */actions/runs/*/jobs*)
        printf '%s\n' "${MOCK_MRB_RUN:-}"
        ;;
    */actions/jobs/*/logs*)
        printf '%s\n' "${MOCK_MRB_LOG:-}"
        ;;
    */git/ref/heads/*)
        # Two callers, one endpoint: `_merge_ref_base` asks with
        # `--jq .object.sha` (wants a bare sha), `cmd_pr_merge --base-sha` asks
        # without and pipes through a local jq (wants the object). ONE
        # GitHub-shaped object through `ghs_emit` serves both (#932): the jq
        # caller's expression is evaluated for real, so a `.object.sha` that
        # stopped selecting the sha would red here instead of being digested.
        # your-org/nexus-code#880's --base-sha pin reads the LIVE TIP of the base
        # branch from the SINGULAR `git/ref/heads/<b>` endpoint. Distinct from the
        # PLURAL `git/refs/heads/<b>` arm below, which is the DELETE target for
        # --delete-branch; the two never collide as glob patterns.
        # MOCK_BASE_TIP_UNREADABLE models the endpoint failing, which must produce
        # a REFUSAL and never a fallback to the PR object's frozen `.base.sha`.
        if [[ "${MOCK_BASE_TIP_UNREADABLE:-0}" == "1" ]]; then
            echo 'gh: mock failure reading the base ref' >&2
            exit 1
        fi
        ghs_emit <<< "{\"object\":{\"sha\":\"${MOCK_BASE_TIP:-livebase777}\"}}"
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
        MOCK_MERGE_409="${MOCK_MERGE_409:-0}" \
        MOCK_BASE_TIP="${MOCK_BASE_TIP:-livebase777}" \
        MOCK_BASE_TIP_UNREADABLE="${MOCK_BASE_TIP_UNREADABLE:-0}" \
        MOCK_MRB_RUN="${MOCK_MRB_RUN:-}" \
        MOCK_MRB_LOG="${MOCK_MRB_LOG:-}" \
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

# ---- Test 17b: cmd_pr_merge — the #628 head-sha PIN --------------------
# The merge PUT must carry a `sha` so GitHub rejects a moved head (the #627
# verified-vs-merged divergence). Default pins the fetched head; --sha pins the
# caller's verified head; a 409 head-moved is surfaced loudly, never silent.

echo '=== ng pr merge 42 → body pins the fetched head sha + hint on stderr ==='
run_ng out err rc pr merge 42
assert_eq        "exit 0"                            "$rc" "0"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload pins fetched head sha"     "$body" '"sha":"fetchedhead000"'
assert_contains  "stderr hints to pass --sha"        "$err" "pass --sha <verified-head>"

echo '=== ng pr merge 42 --sha <verified> → body pins THAT sha, no hint ==='
run_ng out err rc pr merge 42 --sha verifiedhead999
assert_eq        "exit 0"                            "$rc" "0"
body=$(jq -c . < "$BODY_CAPTURE")
assert_contains  "payload pins the --sha value"      "$body" '"sha":"verifiedhead999"'
assert_not_contains "no hint when --sha given"       "$err" "pass --sha <verified-head>"

echo '=== ng pr merge 42 --sha <stale> when head moved → 409 surfaced, exit != 0 ==='
MOCK_MERGE_409=1 run_ng out err rc pr merge 42 --sha stalehead111
assert_eq        "exit 1 (merge rejected)"           "$rc" "1"
assert_contains  "names the head-moved rejection"    "$err" "REJECTED"
assert_contains  "tells the operator to re-verify"   "$err" "Re-verify the NEW head"

# ---- Test 17c: cmd_pr_merge — the #880 BASE-sha PIN --------------------
# The other half of 17b. `--sha` pins the HEAD the caller verified; `--base-sha`
# pins the BASE that head's green was computed against, which GitHub does NOT
# check: it 409s a moved head, and it 409s a base that moved CONFLICTINGLY, but
# a base that advanced and still merges cleanly is accepted silently. That is
# the whole hazard — measured on this repo, `#870` merged onto `4ed5aa1e` five
# minutes after `dev` left `a74805b5`, which is the base its suite ran against.

echo '=== ng pr merge 42 --base-sha <live tip> → base pin holds, merge proceeds ==='
MOCK_BASE_TIP=livebase777 run_ng out err rc pr merge 42 --sha verifiedhead999 --base-sha livebase777
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout still prints the merge SHA" "$out" "abc1234deadbeef"
assert_contains  "stderr confirms the base pin held" "$err" "base pin OK"
calls=$(<"$CAPTURE")
assert_contains  "the live tip is read from the SINGULAR ref endpoint, not the PR's frozen .base.sha" \
                 "$calls" "/git/ref/heads/main"
assert_contains  "and the merge PUT still fires"     "$calls" "-X PUT /repos/default-org/default-repo/pulls/42/merge"

echo '=== ng pr merge 42 --base-sha <stale> → REFUSED, and no PUT is sent ==='
MOCK_BASE_TIP=basemovedaaa run_ng out err rc pr merge 42 --sha verifiedhead999 --base-sha livebase777
assert_eq        "exit 1 (base moved)"               "$rc" "1"
assert_contains  "names the rejection"               "$err" "REJECTED: the BASE moved"
assert_contains  "names the sha the caller verified" "$err" "livebase777"
assert_contains  "…and the sha the branch is at now" "$err" "basemovedaaa"
assert_contains  "says GitHub would NOT have told you, which is the reason the flag exists" \
                 "$err" "merges CLEANLY"
# THE LOAD-BEARING ASSERTION. A refusal that still sends the PUT is not a
# refusal; it is a merge with a complaint attached. `#870` is exactly the merge
# this must not perform.
calls=$(<"$CAPTURE")
assert_not_contains "NO merge PUT was sent"          "$calls" "-X PUT"

echo '=== ng pr merge 42 --base-sha with an unreadable tip → refuses, no fallback ==='
MOCK_BASE_TIP_UNREADABLE=1 run_ng out err rc pr merge 42 --sha verifiedhead999 --base-sha livebase777
assert_eq        "exit 1 (fail-closed)"              "$rc" "1"
assert_contains  "refuses rather than guessing"      "$err" "REFUSED"
assert_contains  "and names WHY a fallback to .base.sha is not acceptable" \
                 "$err" "cannot detect base movement"
calls=$(<"$CAPTURE")
assert_not_contains "NO merge PUT on an unreadable tip" "$calls" "-X PUT"

echo '=== ng pr merge 42 WITHOUT --base-sha → the base is never read (opt-in) ==='
# THE CONTROL FOR THE OTHER FAILURE DIRECTION. A base check that fired on every
# merge would block the board every time `dev` moved during a review, and a gate
# that always fires is a gate somebody disables — strictly worse than not having
# it. So the default path must be byte-for-byte what it was: no ref read, no
# extra API call, no refusal.
run_ng out err rc pr merge 42 --sha verifiedhead999
assert_eq        "exit 0 — unchanged default"        "$rc" "0"
calls=$(<"$CAPTURE")
assert_not_contains "no base-tip read without the flag" "$calls" "/git/ref/heads/"
assert_not_contains "and no base refusal"            "$err" "BASE moved"

# ---- Test 17d: cmd_pr_merge — --verify-base, the SHA-FREE form ---------
# `--base-sha` makes the caller carry a sha from whenever `ci-attempts` last
# ran. Measured, that window has been as short as NINETEEN SECONDS (`#890`), so
# "re-read the tip immediately before merging" is advice an agent can follow and
# still lose. `--verify-base` re-derives the answer milliseconds before the PUT.
#
# The stub serves the merge-ref endpoints so the REAL `_merge_ref_base` runs:
# a `stale` head (the run tested an old base) must REFUSE, a `current` head must
# proceed, and — the load-bearing one — a refusal must send NO PUT.
MRB_H=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MRB_O=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

echo '=== ng pr merge 42 --verify-base with a STALE merge ref → REFUSED, no PUT ==='
MOCK_BASE_TIP=livebase777 MOCK_MRB_RUN=9001 MOCK_MRB_LOG="HEAD is now at ec3412f Merge $MRB_H into $MRB_O" \
    run_ng out err rc pr merge 42 --sha verifiedhead999 --verify-base
assert_eq        "exit 1 (base check withheld)"      "$rc" "1"
assert_contains  "names the refusal and its source"  "$err" "REFUSED by --verify-base"
assert_contains  "…and reports the state it got"     "$err" "stale"
calls=$(<"$CAPTURE")
assert_not_contains "NO merge PUT was sent"          "$calls" "-X PUT"

echo '=== ng pr merge 42 --verify-base with a CURRENT merge ref → proceeds ==='
# Same fixture, only the live tip changed to what the run actually tested. This
# is the control that keeps 17d from passing against a --verify-base that simply
# always refuses — which would be the gate-always-fires failure at the merge verb.
MOCK_BASE_TIP="$MRB_O" MOCK_MRB_RUN=9001 MOCK_MRB_LOG="HEAD is now at ec3412f Merge $MRB_H into $MRB_O" \
    run_ng out err rc pr merge 42 --sha verifiedhead999 --verify-base
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  'says the base was VERIFIED, a word reserved for `current`' \
                 "$err" "--verify-base VERIFIED"
calls=$(<"$CAPTURE")
assert_contains  "and the merge PUT fires"           "$calls" "-X PUT"

echo '=== ng pr merge 42 without --verify-base → the base check does not run ==='
run_ng out err rc pr merge 42 --sha verifiedhead999
assert_eq        "exit 0 — unchanged default"        "$rc" "0"
assert_not_contains "no base-check chatter"          "$err" "--verify-base"

echo '=== ng pr merge 42 --verify-base on an UNREAD base → proceeds, but does NOT say OK ==='
# `permit` is not `verified`. `unread` (logs expired) must not block — blocking
# would break the verb on every older head — but it must not be reported as a
# check that passed either. That conflation is the one this whole branch exists
# to remove; saying "OK" here would reintroduce it in the merge verb.
MOCK_BASE_TIP="$MRB_O" MOCK_MRB_RUN=9001 MOCK_MRB_LOG="no checkout line in this log at all" \
    run_ng out err rc pr merge 42 --sha verifiedhead999 --verify-base
assert_eq        "exit 0 — an unread base does not block"  "$rc" "0"
assert_contains  "…and is reported as NOT CHECKED"         "$err" "--verify-base NOT CHECKED"
assert_not_contains "…never as VERIFIED"                   "$err" "--verify-base VERIFIED"
calls=$(<"$CAPTURE")
assert_contains  "…and the merge still proceeds"           "$calls" "-X PUT"

echo '=== ng pr merge 42 --sha / --base-sha with a MISSING VALUE → refuses (S5) ==='
# `${2:-}` + `shift 2` on a final flag silently yielded an EMPTY pin and shifted
# past the end, so the merge ran UNPINNED while looking pinned.
run_ng out err rc pr merge 42 --sha
assert_eq        "exit 64 (EX_USAGE) on a valueless --sha"      "$rc" "64"
assert_contains  "…naming the flag"                  "$err" "--sha requires a value"
run_ng out err rc pr merge 42 --base-sha
assert_eq        "exit 64 (EX_USAGE) on a valueless --base-sha" "$rc" "64"
assert_contains  "…naming the flag"                  "$err" "--base-sha requires a value"
calls=$(<"$CAPTURE")
assert_not_contains "and NO merge PUT was sent"      "$calls" "-X PUT"

echo '=== ng pr merge 42 --sha "" → refuses TOO: an empty pin is not a pin ==='
# THE GUARD ASKS TWO QUESTIONS AND THEY ARE NOT THE SAME QUESTION. The cases
# above supply NO value (arity); this one supplies an EMPTY value (semantics).
# Both must refuse, for different reasons, and a fix that answers only one of
# them looks correct from whichever side its author tested:
#   * emptiness alone breaks `ng log-action --note ""`, a documented caller —
#     which is exactly what the first cut of this class fix did;
#   * arity alone lets `--sha ""` through, and an empty pin merges UNPINNED
#     while reading as pinned, which is the original S5 defect restored.
# So the discriminating pair is asserted here, next to its counterpart in
# `test-ng-log-action.sh`, rather than left to whichever half got attention.
run_ng out err rc pr merge 42 --sha ""
# EX_USAGE here too (your-org/nexus-code#990). A SUPPLIED-BUT-EMPTY value and a
# MISSING one are different questions — that is what this assertion and its
# `--note ""` counterpart in test-ng-log-action.sh exist to discriminate — but
# they are the same USER-VISIBLE CONDITION: the flag did not receive a usable
# value. Leaving this at 1 would have replaced the two-SCRIPT split #990 reports
# with a two-BRANCH split inside `_need_val`, which is harder to see and no more
# correct. `--note ""` still exits 0, because `--note` is `ng`'s single
# `--allow-empty` opt-out and that arm returns before the emptiness check.
#
# This assertion is why a wording-keyed sweep is not a population: the #990
# census found the two MISSING-value pins in this file by their "requires a
# value" text and explicitly flagged its own result as a FLOOR. This one says
# "EMPTY", matched no such search, and was found only by running the suite.
assert_eq        "exit 64 (EX_USAGE) on an EMPTY --sha" "$rc" "64"
assert_contains  "…and says the value may not be empty" "$err" "--sha requires a non-empty value"
calls=$(<"$CAPTURE")
assert_not_contains "and NO merge PUT was sent for an empty pin" "$calls" "-X PUT"

echo '=== ng pr merge 42 --verify-base with the LIBRARY MISSING → refuses, no PUT ==='
# Absence of the checker is not evidence the base is fine. This case was found
# by accident — `setup_fake_nexus` did not copy `_merge_ref_base.sh`, so the
# fail-closed arm fired on every --verify-base test and the fixture defect
# presented as a verdict. The fixture now copies the library, and the genuinely
# missing case is exercised ON PURPOSE by deleting it, so the arm stays covered
# instead of being covered by an accident nobody would notice going away.
mv "$FAKE_NEXUS/monitor/_merge_ref_base.sh" "$WORK/_merge_ref_base.sh.hidden"
MOCK_BASE_TIP="$MRB_O" MOCK_MRB_RUN=9001 MOCK_MRB_LOG="HEAD is now at ec3412f Merge $MRB_H into $MRB_O" \
    run_ng out err rc pr merge 42 --sha verifiedhead999 --verify-base
mv "$WORK/_merge_ref_base.sh.hidden" "$FAKE_NEXUS/monitor/_merge_ref_base.sh"
assert_eq        "exit 1 (fail-closed on a missing checker)" "$rc" "1"
assert_contains  "says the checker is missing"       "$err" "_merge_ref_base.sh is missing"
assert_contains  "…and why that is a refusal"        "$err" "absence of the checker is not evidence"
calls=$(<"$CAPTURE")
assert_not_contains "NO merge PUT without a checker" "$calls" "-X PUT"

# ---- Test 17e: the VALUELESS-FLAG class, guarded as a class (skeptic S5) ----
#
# THE INSTANCE WAS NOT THE BUG. Two flags were fixed by name while 67 arms three
# lines away kept the same defect — the fourth time in one day a fix closed the
# instances a reviewer named and left the class open. So this is a SOURCE LINT
# over every value-taking arm in `ng`, not a list of the flags anybody thought
# to test.
#
# The mechanism, reproduced in isolation before fixing: `shift 2` with ONE
# positional left FAILS and does NOT shift, so the parse loop spins on the same
# token — 2000+ iterations with `$1` still `--repo`. `${2:-}` hides the other
# half, an empty value that reads as a supplied one.
echo '=== every value-taking arm in ng refuses a missing value (class lint) ==='
unguarded=$(grep -nE '\$\{2:-\}"?\)?; *([a-z_]+=[0-9]+; *)?shift 2' "$FAKE_NEXUS/monitor/ng" \
            | grep -v '_need_val' || true)
# SCOPE, in the assertion text itself: this greps `monitor/ng`. `ng` delegates
# many verbs to scripts under `monitor/` that parse their own flags and are NOT
# covered here — `#924` owns those, and two of them (`guards-for-diff --base`,
# `ci-attempts --repo`) still spin. An assertion that said "in ng" would claim
# the verb surface while measuring one file, which is the overclaim this PR was
# reviewed for one layer up.
assert_eq "no value-taking arm IN monitor/ng ITSELF uses the bare \${2:-} + shift 2 idiom — the CLASS is closed within this file, not just the reported instances (delegated scripts: #924)" \
          "${unguarded:-none}" "none"
# The lint is a source check, so it needs a positive control: a planted arm must
# be SEEN. Otherwise a regex that matches nothing passes forever.
planted="$WORK/ng-planted"
sed 's#^\(\s*\)--repo) _need_val --repo .*$#\1--repo) repo_arg="${2:-}"; shift 2 ;;#' \
    "$FAKE_NEXUS/monitor/ng" > "$planted"
planted_hits=$(grep -nE '\$\{2:-\}"?\)?; *shift 2' "$planted" | grep -vc '_need_val' || true)
assert_eq "…and the lint's own regex SEES a planted unguarded arm — it is checking, not merely silent" \
          "$([[ "${planted_hits:-0}" -ge 1 ]] && echo saw-it || echo blind)" "saw-it"

# Behavioural spot-check on the stubbed verbs: a valueless flag must refuse and
# must not spin. Bounded by `timeout` so a regression FAILS rather than hangs
# the suite.
for _f in --repo --sha --base-sha; do
    _rc=0
    timeout 15 env NEXUS_STATE_DIR="$WORK/state" PATH="$STUB_DIR:$PATH" \
        "$NG" pr merge 42 "$_f" >/dev/null 2>&1 || _rc=$?
    # 124 = timed out, i.e. STILL SPINNING; 0 = accepted a missing value.
    assert_eq "ng pr merge 42 $_f refuses a missing value rather than spinning or merging unpinned (rc=$_rc)" \
              "$([[ "$_rc" != 0 && "$_rc" != 124 ]] && echo refused || echo "bad-rc-$_rc")" "refused"
done

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
