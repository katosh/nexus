#!/usr/bin/env bash
# Unit tests for `ng process` / `ng process-issue` (cmd_process /
# cmd_process_issue in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-process.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: PATH-shadow `gh` to control the reaction-list response so
# we can exercise every branch of the eligibility classifier (the
# load-bearing jq filter in cmd_process_*). Drive `ng process <id>`
# and `ng process-issue <n>`, assert on exit + stderr + the issue=/
# author=/body heredoc payload, and on the side effect of
# _mark_processed (the processed-comments.txt append).
#
# Coverage map (from your-org/nexus-code#60):
#   cmd_process — usage validation; non-user author refusal; eligibility
#     classifier (rocket-from-anyone, eyes-from-non-user, user-self-rocket,
#     user-self-eyes → eligible-or-not); successful eyes POST + cache
#     append; comment-fetch failure surface; reaction-fetch failure.
#   cmd_process_issue — same matrix on the /issues/<n>/reactions surface.
#   --repo override is covered by test-ng-react-repo.sh; here we keep
#     the default-repo path so the eligibility classifier dominates.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-ng-process-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

setup_fake_nexus "$WORK/nexus"
NG="$FAKE_NEXUS/monitor/ng"

STUB_DIR="$WORK/bin"
CAPTURE="$WORK/gh-calls.txt"
BODY_CAPTURE="$WORK/gh-body.txt"

# `gh` stub:
#   GET    /repos/.../issues/comments/<id>             — comment meta.
#                                                        $MOCK_COMMENT_META
#                                                        overrides the
#                                                        canned response;
#                                                        $MOCK_COMMENT_FAIL=1
#                                                        makes the GET 404.
#   GET    /repos/.../issues/comments/<id>/reactions   — reaction list.
#                                                        $MOCK_REACTIONS_FILE
#                                                        controls the JSON;
#                                                        defaults to `[]`.
#   GET    /repos/.../issues/<n>                       — issue meta. Same
#                                                        overrides via
#                                                        $MOCK_ISSUE_META /
#                                                        $MOCK_ISSUE_FAIL.
#   GET    /repos/.../issues/<n>/reactions             — same shape as
#                                                        comments reactions.
#   POST   /repos/.../*/reactions                      — returns {id:9001}.
#                                                        $MOCK_POST_FAIL=1 →
#                                                        non-zero.
#   Other endpoints → {}.
make_gh_stub "$STUB_DIR/gh" "$CAPTURE" --with-body-capture "$BODY_CAPTURE" <<'CASES'
    */issues/comments/*/reactions*|*/issues/*/reactions*)
        if [[ "$method" == "POST" ]]; then
            if [[ "${MOCK_POST_FAIL:-0}" == "1" ]]; then
                printf '%s' '{"message":"mock 422"}' >&2
                exit 1
            fi
            printf '%s' '{"id":9001,"content":"eyes"}'
        else
            if [[ -n "${MOCK_REACTIONS_FILE:-}" && -f "${MOCK_REACTIONS_FILE:-}" ]]; then
                cat "$MOCK_REACTIONS_FILE"
            else
                printf '%s' '[]'
            fi
        fi
        ;;
    */issues/comments/[0-9]*)
        # Comment GET. Meta carries user.login, body, issue_url. The
        # eligibility classifier needs all three; the issue_url tail
        # is parsed for the issue number embedded in the heredoc print.
        if [[ "${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            printf '%s' '{"message":"mock 404"}' >&2
            exit 1
        fi
        if [[ -n "${MOCK_COMMENT_META:-}" && -f "${MOCK_COMMENT_META:-}" ]]; then
            cat "$MOCK_COMMENT_META"
        else
            printf '%s' '{"user":{"login":"test-user"},"body":"hello there","issue_url":"https://api.github.com/repos/default-org/default-repo/issues/42"}'
        fi
        ;;
    */issues/[0-9]*)
        # Issue GET. Meta carries user.login + body.
        if [[ "${MOCK_ISSUE_FAIL:-0}" == "1" ]]; then
            printf '%s' '{"message":"mock 404"}' >&2
            exit 1
        fi
        if [[ -n "${MOCK_ISSUE_META:-}" && -f "${MOCK_ISSUE_META:-}" ]]; then
            cat "$MOCK_ISSUE_META"
        else
            printf '%s' '{"user":{"login":"test-user"},"body":"issue body"}'
        fi
        ;;
    *)
        printf '%s' '{}'
        ;;
CASES

NEUTRAL_CWD="$WORK/neutral"
mkdir -p "$NEUTRAL_CWD"

# Each test gets a fresh STATE_DIR under $WORK/state-<label>; this
# isolates _mark_processed's append-only cache file so we can pin
# the exact line written per scenario.
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3" _state_dir="$4"; shift 4
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE"; : > "$BODY_CAPTURE"
    ( cd "$NEUTRAL_CWD" && run_hermetic \
        NEXUS_STATE_DIR="$_state_dir" \
        PATH="$STUB_DIR:$PATH" \
        MOCK_COMMENT_META="${MOCK_COMMENT_META:-}" \
        MOCK_COMMENT_FAIL="${MOCK_COMMENT_FAIL:-0}" \
        MOCK_ISSUE_META="${MOCK_ISSUE_META:-}" \
        MOCK_ISSUE_FAIL="${MOCK_ISSUE_FAIL:-0}" \
        MOCK_REACTIONS_FILE="${MOCK_REACTIONS_FILE:-}" \
        MOCK_POST_FAIL="${MOCK_POST_FAIL:-0}" \
        -- "$NG" "$@" ) >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# Helper: write a reactions JSON array to a temp file, return its
# path. The eligibility classifier counts items matching:
#   .content == "rocket"
#   OR (.content == "eyes" AND .user.login != $USER_LOGIN)
# So the test scenarios are: empty list, user-eyes-only, non-user-eyes,
# user-rocket (self-opt-out), non-user-rocket, mixed.
write_reactions() {
    local file="$WORK/reactions-$1.json"; shift
    printf '%s' "$1" > "$file"
    printf '%s' "$file"
}

# ---- Test 1: cmd_process — usage on missing positional ----------------

echo '=== ng process (no comment-id) → exit 1, usage ==='
sd="$WORK/state-usage"
run_ng out err rc "$sd" process
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names usage shape"          "$err" "usage: ng process <comment-id>"

echo '=== ng process --bogus 42 → exit 1, unknown flag ==='
run_ng out err rc "$sd" process --bogus 42
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names unknown flag"         "$err" "unknown flag: --bogus"

# ---- Test 2: cmd_process — happy path, zero reactions → eligible ------

echo '=== ng process 42 with no reactions → eyes POST, heredoc payload ==='
sd="$WORK/state-happy"
MOCK_REACTIONS_FILE=$(write_reactions empty '[]') \
    run_ng out err rc "$sd" process 42
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "GET comment meta"                  "$calls" "/repos/default-org/default-repo/issues/comments/42"
assert_contains  "GET reactions list"                "$calls" "/repos/default-org/default-repo/issues/comments/42/reactions?per_page=100"
assert_contains  "POST eyes reaction"                "$calls" "-X POST /repos/default-org/default-repo/issues/comments/42/reactions"
# The POST body carries `-f content=eyes`. With --with-body-capture
# the file is overwritten on each call; the last write is the POST.
# Verify via the captured argv directly (the body capture is empty
# because gh `-f k=v` doesn't pipe to stdin).
assert_contains  "POST argv carries content=eyes"    "$calls" "-f content=eyes"
# Heredoc payload: issue=42, author=test-user, body via EOF heredoc.
assert_contains  "heredoc carries issue=42"          "$out" "issue=42"
assert_contains  "heredoc carries author=test-user"  "$out" "author=test-user"
assert_contains  "heredoc carries body content"      "$out" "hello there"
# Side effect: processed-comments.txt now lists comment:42.
assert_file_exists "processed-comments.txt written"  "$sd/processed-comments.txt"
cache=$(<"$sd/processed-comments.txt")
assert_contains  "cache entry is comment:42"         "$cache" "comment:42"

# ---- Test 3: cmd_process — user-self-eyes counts as ELIGIBLE ----------
#
# The classifier excludes the user's own eyes (so the bot can re-mark
# a comment if its own previous mark hasn't propagated). With only a
# user-self-eyes reaction, marks=0 → eligible.

echo '=== reactions=[user-eyes] only → eligible, eyes POST fires ==='
sd="$WORK/state-self-eyes"
MOCK_REACTIONS_FILE=$(write_reactions self-eyes '[{"content":"eyes","user":{"login":"test-user"}}]') \
    run_ng out err rc "$sd" process 42
assert_eq        "exit 0 on self-eyes only"          "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "POST eyes still fires"             "$calls" "-X POST /repos/default-org/default-repo/issues/comments/42/reactions"

# ---- Test 4: cmd_process — non-user eyes blocks (bot handling) -------

echo '=== reactions=[bot-eyes] → INELIGIBLE ==='
sd="$WORK/state-bot-eyes"
MOCK_REACTIONS_FILE=$(write_reactions bot-eyes '[{"content":"eyes","user":{"login":"some-other-bot[bot]"}}]') \
    run_ng out err rc "$sd" process 42
assert_eq        "exit 1 on non-user eyes"           "$rc" "1"
assert_contains  "die names already-processed"       "$err" "already marked processed"
calls=$(<"$CAPTURE")
assert_not_contains "no POST when ineligible"        "$calls" "-X POST"
assert_no_file   "no processed-comments cache write" "$sd/processed-comments.txt"

# ---- Test 5: cmd_process — user-self-rocket is self-opt-out ----------

echo '=== reactions=[user-rocket] → self-opt-out, INELIGIBLE ==='
sd="$WORK/state-self-rocket"
MOCK_REACTIONS_FILE=$(write_reactions self-rocket '[{"content":"rocket","user":{"login":"test-user"}}]') \
    run_ng out err rc "$sd" process 42
assert_eq        "exit 1 on self-rocket"             "$rc" "1"
assert_contains  "die names already-processed"       "$err" "already marked processed"
calls=$(<"$CAPTURE")
assert_not_contains "no POST when self-rocket"       "$calls" "-X POST"

# ---- Test 6: cmd_process — bot-rocket blocks --------------------------

echo '=== reactions=[bot-rocket] → INELIGIBLE ==='
sd="$WORK/state-bot-rocket"
MOCK_REACTIONS_FILE=$(write_reactions bot-rocket '[{"content":"rocket","user":{"login":"another-bot"}}]') \
    run_ng out err rc "$sd" process 42
assert_eq        "exit 1 on bot rocket"              "$rc" "1"
assert_contains  "die names already-processed"       "$err" "already marked processed"

# ---- Test 7: cmd_process — mixed irrelevant reactions are ignored -----
#
# +1 / heart / hooray / laugh / confused / -1 / thumbs_down are not
# in the eligibility set — the classifier only counts rocket OR
# (eyes && non-user). A pile of irrelevant reactions should still
# leave the comment eligible.

echo '=== reactions=[heart, +1, laugh] → ELIGIBLE (none match classifier) ==='
sd="$WORK/state-irrelevant"
MOCK_REACTIONS_FILE=$(write_reactions irrelevant \
    '[{"content":"heart","user":{"login":"a"}},{"content":"+1","user":{"login":"b"}},{"content":"laugh","user":{"login":"c"}}]') \
    run_ng out err rc "$sd" process 42
assert_eq        "exit 0 on irrelevant reactions"    "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "POST eyes fires"                   "$calls" "-X POST /repos/default-org/default-repo/issues/comments/42/reactions"

# ---- Test 8: cmd_process — non-user author refused --------------------

echo '=== comment authored by NOT $USER_LOGIN → exit 1 ==='
sd="$WORK/state-wrong-author"
wrong_author_meta="$WORK/comment-wrong-author.json"
printf '%s' '{"user":{"login":"the-stranger"},"body":"x","issue_url":"https://api.github.com/repos/o/r/issues/42"}' > "$wrong_author_meta"
MOCK_COMMENT_META="$wrong_author_meta" \
    run_ng out err rc "$sd" process 42
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "die names author mismatch"         "$err" "not authored by test-user"
calls=$(<"$CAPTURE")
assert_not_contains "no reactions GET on bad author" "$calls" "/reactions"
assert_not_contains "no eyes POST on bad author"     "$calls" "-X POST"

# ---- Test 9: cmd_process — comment fetch failure → structured die -----

echo '=== GET /issues/comments/<id> 404 → exit 1, die names fetch failure ==='
sd="$WORK/state-fetch-fail"
MOCK_COMMENT_FAIL=1 run_ng out err rc "$sd" process 42
assert_eq        "exit 1 on 404"                     "$rc" "1"
assert_contains  "die names fetch failure"           "$err" "fetch comment 42 failed"

# ---- Test 10: cmd_process — eyes POST failure → die "posting eyes ..." -

echo '=== POST reactions returns 1 → exit 1, die names eyes POST failure ==='
sd="$WORK/state-post-fail"
MOCK_REACTIONS_FILE=$(write_reactions empty '[]') \
MOCK_POST_FAIL=1 run_ng out err rc "$sd" process 42
assert_eq        "exit 1 on POST failure"            "$rc" "1"
assert_contains  "die names eyes POST failure"       "$err" "posting eyes reaction failed"
# The cache should NOT have been written when the POST failed (the
# append happens AFTER the POST succeeds).
assert_no_file   "no cache write on POST failure"    "$sd/processed-comments.txt"

# ---- Test 11: cmd_process — malformed comment meta → die "malformed" --

echo '=== comment meta missing user.login → die "malformed metadata" ==='
sd="$WORK/state-malformed"
no_author="$WORK/comment-no-author.json"
printf '%s' '{"body":"","issue_url":""}' > "$no_author"
MOCK_COMMENT_META="$no_author" \
    run_ng out err rc "$sd" process 42
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "die names malformed metadata"      "$err" "malformed metadata"

# ---- Test 12: cmd_process_issue — same eligibility matrix on /issues/<n>

echo '=== ng process-issue 17 with no reactions → eyes POST, heredoc ==='
sd="$WORK/state-pi-happy"
MOCK_REACTIONS_FILE=$(write_reactions empty '[]') \
    run_ng out err rc "$sd" process-issue 17
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "GET /issues/17"                    "$calls" "/repos/default-org/default-repo/issues/17"
assert_contains  "GET /issues/17/reactions"          "$calls" "/repos/default-org/default-repo/issues/17/reactions?per_page=100"
assert_contains  "POST /issues/17/reactions"         "$calls" "-X POST /repos/default-org/default-repo/issues/17/reactions"
assert_contains  "heredoc carries issue=17"          "$out" "issue=17"
assert_contains  "heredoc carries author=test-user"  "$out" "author=test-user"
assert_file_exists "issue cache append"              "$sd/processed-comments.txt"
cache=$(<"$sd/processed-comments.txt")
assert_contains  "cache entry is issue:17"           "$cache" "issue:17"

# ---- Test 13: cmd_process_issue — usage on missing positional --------

echo '=== ng process-issue (no n) → exit 1, usage ==='
sd="$WORK/state-pi-usage"
run_ng out err rc "$sd" process-issue
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stderr names usage"                "$err" "usage: ng process-issue <issue-number>"

# ---- Test 14: cmd_process_issue — bot eyes / user-rocket blocks ------

echo '=== process-issue with non-user eyes → INELIGIBLE ==='
sd="$WORK/state-pi-bot-eyes"
MOCK_REACTIONS_FILE=$(write_reactions bot-eyes-i '[{"content":"eyes","user":{"login":"foreign-bot"}}]') \
    run_ng out err rc "$sd" process-issue 17
assert_eq        "exit 1 on bot eyes"                "$rc" "1"
assert_contains  "die mentions already processed"    "$err" "already marked processed"

echo '=== process-issue with user self-rocket → INELIGIBLE ==='
sd="$WORK/state-pi-self-rocket"
MOCK_REACTIONS_FILE=$(write_reactions self-rocket-i '[{"content":"rocket","user":{"login":"test-user"}}]') \
    run_ng out err rc "$sd" process-issue 17
assert_eq        "exit 1 on self-rocket"             "$rc" "1"
assert_contains  "die mentions already processed"    "$err" "already marked processed"

# ---- Test 15: cmd_process_issue — non-user author refused ------------

echo '=== process-issue authored by stranger → exit 1 ==='
sd="$WORK/state-pi-wrong-author"
no_user_i="$WORK/issue-stranger.json"
printf '%s' '{"user":{"login":"the-stranger"},"body":""}' > "$no_user_i"
MOCK_ISSUE_META="$no_user_i" \
    run_ng out err rc "$sd" process-issue 17
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "die names author mismatch"         "$err" "not authored by test-user"

# ---- Test 16: cmd_process — _mark_processed is idempotent -----------
#
# Running process twice on the same comment-id should produce a single
# line in processed-comments.txt (the cache is dedup'd by grep -qxF
# before append). Use a shared STATE_DIR across two calls.

echo '=== process 42 twice → cache contains exactly one comment:42 line ==='
sd="$WORK/state-idempotent"
MOCK_REACTIONS_FILE=$(write_reactions empty '[]') \
    run_ng out err rc "$sd" process 42
assert_eq        "first call exit 0"                 "$rc" "0"
# Second call: re-issue the same process. The cache already has
# comment:42 — the dedup-on-append should be a no-op.
MOCK_REACTIONS_FILE=$(write_reactions empty '[]') \
    run_ng out err rc "$sd" process 42
assert_eq        "second call exit 0"                "$rc" "0"
cache_line_count=$(grep -c '^comment:42$' "$sd/processed-comments.txt" || true)
assert_eq        "cache has exactly one comment:42"  "$cache_line_count" "1"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
