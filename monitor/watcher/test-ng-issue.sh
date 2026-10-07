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
        ${NG_EXTRA_ENV[@]+"${NG_EXTRA_ENV[@]}"} \
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
assert_contains  "stderr names the unknown flag"     "$err" "unknown flag: '--bogus'"

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

# ---- Test 16 (your-org/nexus-code#641 part 1): the post RECEIPT ---------
#
# The reported defect was a 4 kB intent posting as 239 B with nothing making
# the discrepancy visible. `ng` posted faithfully; the operator had no cheap
# way to notice. So the verb now says what it sent — and, for a `--body-file`
# specifically, warns when the file resolved to almost nothing.
#
# The two constraints are as important as the feature and are asserted here,
# not just documented: the receipt is on STDERR (stdout is the URL and callers
# parse it), and it NEVER flips the exit code (the comment DID post; failing a
# successful publish is a worse trade than the one being fixed).

echo '=== #641 the receipt reports the byte count on STDERR ==='
printf 'x%.0s' {1..800} > "$WORK/big.md"
run_ng out err rc issue comment 7 --body-file "$WORK/big.md"
assert_eq        "#641 a normal comment still exits 0"  "$rc" "0"
assert_contains  "#641 stderr reports the byte count"   "$err" "ng: posting 800 bytes"
assert_contains  "#641 …and names where the body came from" "$err" "$WORK/big.md"
# STDOUT must stay parseable — the URL and nothing else. A receipt on stdout
# would corrupt every caller that captures it.
assert_not_contains "#641 the receipt is NOT on stdout" "$out" "ng: posting"
# An 800-byte file is over the floor, so the warning must be SILENT here or
# the warning carries no information.
assert_not_contains "#641 no warning for a body over the floor" "$err" "WARNING"

echo '=== #641 a suspiciously small --body-file WARNS, and still posts ==='
printf 'oops\n' > "$WORK/tiny.md"
run_ng out err rc issue comment 7 --body-file "$WORK/tiny.md"
assert_contains  "#641 stderr warns the file is under the floor" "$err" "under the 200-byte floor"
# LOAD-BEARING: the warning must not become a failure. The comment posted;
# turning a successful publish into a non-zero exit would be a regression
# worse than the silence it replaces.
assert_eq        "#641 the warning does NOT flip the exit code" "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "#641 …and the comment is still POSTed"        "$calls" \
                 "-X POST /repos/default-org/default-repo/issues/7/comments"

echo '=== #641 CONTROL: stdin is the short-comment channel and is NOT warned ==='
# Warning on stdin would fire on every legitimate one-line comment, and a
# guard that cries wolf is how operators learn to ignore it.
# NB: feed stdin by REDIRECT, not by pipe. `printf ... | run_ng ...` puts the
# helper in a pipeline SUBSHELL, so its `printf -v` never reaches the caller
# and every assertion silently reads the PREVIOUS test's stderr. That is how
# this block first "passed" the byte-count assertion while checking the wrong
# run entirely.
printf 'ack\n' > "$WORK/ack.txt"
run_ng out err rc issue comment 7 < "$WORK/ack.txt"
assert_eq        "#641 a short stdin comment exits 0"   "$rc" "0"
assert_contains  "#641 …is still counted"               "$err" "ng: posting 3 bytes"
assert_contains  "#641 …and attributed to stdin"        "$err" "from stdin"
assert_not_contains "#641 …but is NOT warned about"     "$err" "WARNING"

# ---- your-org/nexus-code#1636: the nexus ROOT's origin is not the target ----
#
# A nexus root is a clone of the IMPLEMENTATION repo, so its `origin` is
# your-org/nexus-code for every operator. The cwd-origin rule used to select
# that repo AT THE ROOT: `ng issue 383` read nexus-code #383 at rc 0 (the
# operator meant their own github.repo), and every write verb refused.
#
# The root is recognised by IDENTITY — the cwd toplevel IS the tree this `ng`
# runs from — so the fixture root is a full copy of the fake nexus, made a git
# repo, and `ng` is invoked from INSIDE it. Fixtures:
#   ROOT            git repo, origin nexus-code, the ng under test lives here
#   ROOT/work/x     a non-repo dir: git walks UP to the root
#   ROOT/work/sec   a SECONDARY clone, origin nexus-code, no config
#   ROOT/work/stale a SECONDARY clone carrying a STALE config/nexus.yml +
#                   monitor/ng — the skeptic's measured case (2 of 815 on one
#                   host): a file-presence predicate read it as a root and sent
#                   a write to github.repo at rc 0. It must keep cwd-origin and
#                   the write must still REFUSE.
R1636="$WORK/r1636/nexus"
mkdir -p "$R1636"
cp -a "$FAKE_NEXUS/." "$R1636/"
git -C "$R1636" init -q
th_require_fixture_repo "$R1636"
git -C "$R1636" remote add origin "https://github.com/your-org/nexus-code.git"
printf 'github:\n  repo: default-org/default-repo\n' > "$R1636/config/nexus.yml"
mkdir -p "$R1636/work/not-a-repo"
_mk_1636_clone() {  # <dir> [stale-config]
    mkdir -p "$1/monitor" "$1/config"
    git -C "$1" init -q
    th_require_fixture_repo "$1"
    git -C "$1" remote add origin "https://github.com/your-org/nexus-code.git"
    if [[ "${2:-}" == stale-config ]]; then
        : > "$1/monitor/ng"
        printf 'github:\n  repo: default-org/default-repo\n' > "$1/config/nexus.yml"
    fi
    return 0
}
S1636="$R1636/work/nexus-code-task"
T1636="$R1636/work/nexus-code-stale"
_mk_1636_clone "$S1636"
_mk_1636_clone "$T1636" stale-config
_saved_neutral="$NEUTRAL_CWD"; _saved_ng="$NG"
NG="$R1636/monitor/ng"
printf 'root comment body\n' > "$WORK/c1636.txt"

echo '=== #1636 read verb at the nexus ROOT targets github.repo, not the root origin ==='
NEUTRAL_CWD="$R1636"
run_ng out err rc issue 383
calls=$(<"$CAPTURE")
assert_eq        "#1636 root: issue view exits 0"                 "$rc" "0"
assert_contains  "#1636 root: GET targets github.repo"            "$calls" "/repos/default-org/default-repo/issues/383"
assert_not_contains "#1636 root: …and NOT the root's own origin"  "$calls" "your-org/nexus-code"
assert_not_contains "#1636 root: no 'targeting cwd origin' notice" "$err" "targeting cwd origin"

echo '=== #1636 write verb at the nexus ROOT is no longer refused ==='
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1636 root: issue comment exits 0"              "$rc" "0"
assert_contains  "#1636 root: POST goes to github.repo"           "$calls" \
                 "-X POST /repos/default-org/default-repo/issues/383/comments"

echo '=== #1636 a non-repo dir under work/ walks UP to the root: same answer ==='
NEUTRAL_CWD="$R1636/work/not-a-repo"
run_ng out err rc issue 383
calls=$(<"$CAPTURE")
assert_contains  "#1636 walk-up: GET targets github.repo"         "$calls" "/repos/default-org/default-repo/issues/383"
assert_not_contains "#1636 walk-up: …and NOT nexus-code"          "$calls" "your-org/nexus-code"

echo '=== #1636 CONTROL: a SECONDARY clone keeps cwd-origin ==='
NEUTRAL_CWD="$S1636"
run_ng out err rc issue 383
calls=$(<"$CAPTURE")
assert_contains  "#1636 control: secondary clone reads its own origin" "$calls" "/repos/your-org/nexus-code/issues/383"
assert_contains  "#1636 control: …and says so on stderr"          "$err" "targeting cwd origin your-org/nexus-code"

echo '=== #1636 CONTROL: a secondary clone with a STALE config/nexus.yml is NOT a root ==='
NEUTRAL_CWD="$T1636"
run_ng out err rc issue 383
calls=$(<"$CAPTURE")
assert_contains  "#1636 stale-config: read keeps the clone's own origin" "$calls" "/repos/your-org/nexus-code/issues/383"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_not_contains "#1636 stale-config: a write is NOT sent to github.repo" "$calls" "-X POST"
assert_contains  "#1636 stale-config: …it REFUSES and asks for --repo" "$err" "pass --repo explicitly"
assert_eq        "#1645 stale-config: the write exits 1 (refused, not a silent no-op)" "$rc" "1"

# ---- your-org/nexus-code#1645: the wrong-target direction, from every angle --
#
# The fix keys the root on ng's OWN tree (de-nested). What these cases pin is
# the REFUSAL: from each cwd below a no-`--repo` WRITE must refuse (rc 1, no
# POST), plus the control that it still reaches github.repo from under work/.
#
# These cases run on setup_fake_nexus's config stub, which hardcodes
# github.repo, so they pin the REFUSAL only. WHICH repo a write reaches is
# pinned by the #1650 section below, on a REAL config/load.sh: ng now reads
# github.repo from the same de-nested tree it keys the root on, and refuses
# when NEXUS_ROOT names a nexus with a different github.repo.
echo '=== #1645 a SUBDIRECTORY of the stale clone: walks up to the clone, still refused ==='
mkdir -p "$T1636/monitor/sub"
NEUTRAL_CWD="$T1636/monitor/sub"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1645 stale subdir: write refused (rc 1)"            "$rc" "1"
assert_not_contains "#1645 stale subdir: NO POST"                      "$calls" "-X POST"

echo '=== #1645 NEXUS_ROOT aimed AT the stale clone changes nothing ==='
NEUTRAL_CWD="$T1636"
NG_EXTRA_ENV=(NEXUS_ROOT="$T1636")
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1645 stale + NEXUS_ROOT=stale: write refused (rc 1)" "$rc" "1"
assert_not_contains "#1645 stale + NEXUS_ROOT=stale: NO POST"          "$calls" "-X POST"
NG_EXTRA_ENV=()

echo '=== #1645 the stale clone running its OWN monitor/ng from inside it ==='
# A worker in a stale clone reaches for the ng beside it. That ng's tree is the
# clone, which de-nests to the primary: the clone is still not the root.
T1636B="$R1636/work/nexus-code-stale-own"
mkdir -p "$T1636B"
cp -a "$FAKE_NEXUS/." "$T1636B/"
git -C "$T1636B" init -q
th_require_fixture_repo "$T1636B"
git -C "$T1636B" remote add origin "https://github.com/your-org/nexus-code.git"
printf 'github:\n  repo: default-org/default-repo\n' > "$T1636B/config/nexus.yml"
NEUTRAL_CWD="$T1636B"; NG="$T1636B/monitor/ng"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1645 stale clone's own ng: write refused (rc 1)"    "$rc" "1"
assert_not_contains "#1645 stale clone's own ng: NO POST"              "$calls" "-X POST"
NG="$R1636/monitor/ng"

echo '=== #1645 a FOREIGN nexus root (not this ng'"'"'s tree), even with NEXUS_ROOT aimed at it ==='
F1645="$WORK/r1645-foreign/nexus"
mkdir -p "$F1645"
cp -a "$FAKE_NEXUS/." "$F1645/"
git -C "$F1645" init -q
th_require_fixture_repo "$F1645"
git -C "$F1645" remote add origin "https://github.com/your-org/nexus-code.git"
printf 'github:\n  repo: other-org/other-repo\n' > "$F1645/config/nexus.yml"
NEUTRAL_CWD="$F1645"
NG_EXTRA_ENV=(NEXUS_ROOT="$F1645")
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1645 foreign root: write refused (rc 1)"            "$rc" "1"
assert_not_contains "#1645 foreign root: NO POST"                      "$calls" "-X POST"
NG_EXTRA_ENV=()

echo '=== #1645 a FRESH secondary clone (no config): write refused ==='
NEUTRAL_CWD="$S1636"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1645 fresh secondary: write refused (rc 1)"         "$rc" "1"
assert_not_contains "#1645 fresh secondary: NO POST"                   "$calls" "-X POST"

echo '=== #1645 CONTROL: from work/ (walks up to the root) the write reaches github.repo ==='
NEUTRAL_CWD="$R1636/work/not-a-repo"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1645 control work/: write exits 0"                  "$rc" "0"
assert_contains  "#1645 control work/: POST goes to github.repo"       "$calls" \
                 "-X POST /repos/default-org/default-repo/issues/383/comments"
NEUTRAL_CWD="$_saved_neutral"; NG="$_saved_ng"

# ---- your-org/nexus-code#1650: github.repo comes from the SAME tree as the root --
#
# Skeptic N1 on #1648. The root identity is keyed on ng's own tree (de-nested),
# but `config/load.sh` read `$NEXUS_ROOT/config/nexus.yml`, and without
# NEXUS_ROOT its own tree NOT de-nested. With NEXUS_ROOT aimed at a foreign
# root a write POSTed to THAT root's repo at rc 0; a stale work/<clone>'s own
# ng POSTed to the clone's stale repo. The stub above cannot see this, so every
# fixture here runs the REAL config/load.sh against a real nexus.yml, each with
# a DISTINCT github.repo so the captured endpoint names the tree it came from.
#   P   primary root           p-org/p-repo   (the ng under test)
#   F   foreign root           f-org/f-repo
#   F2  foreign root, SAME repo p-org/p-repo  (control: no disagreement)
#   S   P/work stale clone     s-org/stale-repo, carrying its own monitor/ng
_th_repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
_mk_1650_root() {  # <dir> <github.repo>
    mkdir -p "$1"
    cp -a "$FAKE_NEXUS/." "$1/"
    cp "$_th_repo_root/config/load.sh" "$1/config/load.sh"
    cp "$_th_repo_root/config/nexus.example.yml" "$1/config/nexus.example.yml"
    printf 'github:\n  repo: %s\n  user_login: test-user\n' "$2" > "$1/config/nexus.yml"
    git -C "$1" init -q
    th_require_fixture_repo "$1"
    git -C "$1" remote add origin "https://github.com/your-org/nexus-code.git"
}
P1650="$WORK/n1650/nexus"
F1650="$WORK/n1650-foreign/nexus"
F2_1650="$WORK/n1650-foreign2/nexus"
_mk_1650_root "$P1650"   p-org/p-repo
_mk_1650_root "$F1650"   f-org/f-repo
_mk_1650_root "$F2_1650" p-org/p-repo
S1650="$P1650/work/nexus-code-stale"
_mk_1650_root "$S1650"   s-org/stale-repo
mkdir -p "$P1650/work/not-a-repo"
NG_P="$P1650/monitor/ng"; NG_S="$S1650/monitor/ng"

# POSITIVE CONTROL first: the real loader, un-stubbed, answers p-org/p-repo.
_cfg_probe=$(env -u NEXUS_ROOT -u NEXUS_CONFIG "$P1650/config/load.sh" github.repo 2>&1)
assert_eq "#1650 control: the REAL load.sh in P answers P's github.repo" "$_cfg_probe" "p-org/p-repo"

echo '=== #1650 CONTROL: P'"'"'s ng, no NEXUS_ROOT, at P → POST p-org/p-repo ==='
NG="$NG_P"; NEUTRAL_CWD="$P1650"; NG_EXTRA_ENV=()
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1650 A: exits 0"                                    "$rc" "0"
assert_contains  "#1650 A: POST reaches P's github.repo"               "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"

echo '=== #1650 NEXUS_ROOT aimed at a FOREIGN root: refused, and names both sides ==='
NG_EXTRA_ENV=(NEXUS_ROOT="$F1650")
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1650 B: write refused (rc 1)"                       "$rc" "1"
assert_not_contains "#1650 B: NO POST at all"                          "$calls" "-X POST"
assert_not_contains "#1650 B: …and in particular not to F's repo"      "$calls" "f-org/f-repo"
assert_contains  "#1650 B: refusal says it will not guess"             "$err" "refusing to guess the target repo"
assert_contains  "#1650 B: …names F's repo"                            "$err" "github.repo=f-org/f-repo"
assert_contains  "#1650 B: …and P's repo"                              "$err" "github.repo=p-org/p-repo"

echo '=== #1650 same, from a non-repo dir under P/work/ (walks up to P) ==='
NEUTRAL_CWD="$P1650/work/not-a-repo"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1650 C: write refused (rc 1)"                       "$rc" "1"
assert_not_contains "#1650 C: NO POST"                                 "$calls" "-X POST"

echo '=== #1650 a READ at P under the same conflict is refused too (no cwd origin to use) ==='
NEUTRAL_CWD="$P1650"
run_ng out err rc issue 383
calls=$(<"$CAPTURE")
assert_eq        "#1650 I: read refused (rc 1)"                        "$rc" "1"
assert_not_contains "#1650 I: no GET to F's repo"                      "$calls" "f-org/f-repo"
assert_contains  "#1650 I: refusal names the disagreement"             "$err" "refusing to guess the target repo"

echo '=== #1650 dashboard (a direct-$REPO consumer) under the conflict is refused ==='
run_ng out err rc dashboard get
calls=$(<"$CAPTURE")
assert_eq        "#1650 J: dashboard get refused (rc 1)"               "$rc" "1"
assert_contains  "#1650 J: …with the disagreement named"               "$err" "refusing to guess the target repo"
assert_not_contains "#1650 J: no API call to F's repo"                 "$calls" "f-org/f-repo"

echo '=== #1650 an explicit --repo is the override, conflict or not ==='
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt" --repo x-org/x-repo
calls=$(<"$CAPTURE")
assert_eq        "#1650 D: --repo write exits 0"                       "$rc" "0"
assert_contains  "#1650 D: POST goes to the explicit repo"             "$calls" "-X POST /repos/x-org/x-repo/issues/383/comments"

echo '=== #1650 CONTROL: a foreign NEXUS_ROOT with the SAME github.repo is not refused ==='
NG_EXTRA_ENV=(NEXUS_ROOT="$F2_1650")
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1650 E: exits 0"                                    "$rc" "0"
assert_contains  "#1650 E: POST reaches p-org/p-repo"                  "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"

echo '=== #1650 NEXUS_ROOT aimed at P'"'"'s stale CLONE de-nests to P: no stale repo ==='
NG_EXTRA_ENV=(NEXUS_ROOT="$S1650")
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1650 H: exits 0"                                    "$rc" "0"
assert_contains  "#1650 H: POST reaches P's repo"                      "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"
assert_not_contains "#1650 H: …never the clone's stale repo"           "$calls" "s-org/stale-repo"

echo '=== #1650 the stale clone'"'"'s OWN ng, run at P, no NEXUS_ROOT: reads P'"'"'s config ==='
NG="$NG_S"; NG_EXTRA_ENV=()
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1650 F: exits 0"                                    "$rc" "0"
assert_contains  "#1650 F: POST reaches P's repo"                      "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"
assert_not_contains "#1650 F: …never the clone's stale repo"           "$calls" "s-org/stale-repo"

echo '=== #1650 CONTROL: the stale clone'"'"'s ng with NEXUS_ROOT=P, at P ==='
NG_EXTRA_ENV=(NEXUS_ROOT="$P1650")
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1650 G: exits 0"                                    "$rc" "0"
assert_contains  "#1650 G: POST reaches P's repo"                      "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"
NG_EXTRA_ENV=(); NEUTRAL_CWD="$_saved_neutral"; NG="$_saved_ng"

# ---- #1651 skeptic item 2: a CONFIG-LESS checkout OUTSIDE work/ acts for NEXUS_ROOT --
#
# The first cut of #1650 compared ng's own github.repo with NEXUS_ROOT's, and a
# config-less tree's "own" repo is the nexus.example.yml PLACEHOLDER — so a
# checkout with no nexus.yml, outside any work/ (nothing de-nests it), run with
# NEXUS_ROOT=<primary> REFUSED a write that base sent to the primary's repo.
# A tree with no config, or a copied-but-unedited one, has NO OPINION.
#   C   $WORK/n1651-outside/nexus   no nexus.yml, real load.sh + example
#   C2  same, nexus.yml = the example copied unedited
#   X   same, but a REAL nexus.yml naming x-org/x-repo (control: still conflicts)
_mk_1651_outside() {  # <dir> [none|placeholder|<repo>]
    mkdir -p "$1"
    cp -a "$FAKE_NEXUS/." "$1/"
    cp "$_th_repo_root/config/load.sh" "$1/config/load.sh"
    cp "$_th_repo_root/config/nexus.example.yml" "$1/config/nexus.example.yml"
    case "$2" in
        none)        rm -f "$1/config/nexus.yml" ;;
        placeholder) cp "$1/config/nexus.example.yml" "$1/config/nexus.yml" ;;
        malformed)   printf 'github:\n  repo: [unclosed\n' > "$1/config/nexus.yml" ;;
        *)           printf 'github:\n  repo: %s\n  user_login: test-user\n' "$2" > "$1/config/nexus.yml" ;;
    esac
    git -C "$1" init -q
    th_require_fixture_repo "$1"
    git -C "$1" remote add origin "https://github.com/your-org/nexus-code.git"
}
C1651="$WORK/n1651-outside/nexus";   _mk_1651_outside "$C1651"  none
C2_1651="$WORK/n1651-outside2/nexus"; _mk_1651_outside "$C2_1651" placeholder
X1651="$WORK/n1651-outside3/nexus";  _mk_1651_outside "$X1651"  x-org/x-repo
_ph_repo=$(env -u NEXUS_ROOT -u NEXUS_CONFIG "$C1651/config/load.sh" github.repo 2>&1)
assert_contains "#1651 control: C's own loader answers the PLACEHOLDER" "$_ph_repo" "your-org/"

echo '=== #1651 config-less checkout outside work/, NEXUS_ROOT=P, neutral cwd → P'"'"'s repo (as at base) ==='
NG="$C1651/monitor/ng"; NEUTRAL_CWD="$WORK/neutral"; NG_EXTRA_ENV=(NEXUS_ROOT="$P1650")
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1651 K: exits 0"                                    "$rc" "0"
assert_contains  "#1651 K: POST reaches P's github.repo"               "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"
assert_not_contains "#1651 K: …never the placeholder"                  "$calls" "your-org/"
assert_not_contains "#1651 K: no refusal"                              "$err" "refusing to guess"

echo '=== #1651 same ng, cwd = P: P is the root it acts for, so github.repo, not P'"'"'s origin ==='
NEUTRAL_CWD="$P1650"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1651 L: exits 0"                                    "$rc" "0"
assert_contains  "#1651 L: POST reaches P's github.repo"               "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"

echo '=== #1651 cwd = the checkout itself: its own tree is home too, so P'"'"'s repo (as at base) ==='
NEUTRAL_CWD="$C1651"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1651 M: exits 0"                                    "$rc" "0"
assert_contains  "#1651 M: POST reaches P's github.repo"               "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"
assert_not_contains "#1651 M: …never the checkout's own origin"        "$calls" "your-org/nexus-code"

echo '=== #1651 a copied-but-UNEDITED nexus.yml is no opinion either ==='
NG="$C2_1651/monitor/ng"; NEUTRAL_CWD="$WORK/neutral"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1651 N: exits 0"                                    "$rc" "0"
assert_contains  "#1651 N: POST reaches P's github.repo"               "$calls" "-X POST /repos/p-org/p-repo/issues/383/comments"

echo '=== #1651 CONTROL: a checkout with a REAL, DIFFERENT config still conflicts ==='
NG="$X1651/monitor/ng"
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1651 O: write refused (rc 1)"                       "$rc" "1"
assert_not_contains "#1651 O: NO POST"                                 "$calls" "-X POST"
assert_contains  "#1651 O: the refusal names the disagreement"         "$err" "refusing to guess the target repo"

# ---- your-org/nexus-code#1652 item 3: a BROKEN own config is not an ABSENT one --
# nexus_tree_identity returned rc 1 both for "no nexus.yml" and for "load.sh
# FAILED on it", so the checkout below — a MALFORMED nexus.yml, NEXUS_ROOT=P —
# was read as "no opinion" and POSTed to P's repo at rc 0 (measured at
# 33a44f48). K above is the no-config control and must stay green.
M1652="$WORK/n1652-outside/nexus";  _mk_1651_outside "$M1652"  malformed
_m_probe=$(env -u NEXUS_ROOT NEXUS_CONFIG="$M1652/config/nexus.yml" "$M1652/config/load.sh" github.repo 2>/dev/null); _m_rc=$?
assert_eq "#1652 control: the REAL load.sh FAILS on the malformed nexus.yml" "$_m_rc" "1"

echo '=== #1652 a MALFORMED nexus.yml outside work/, NEXUS_ROOT=P: REFUSED, no POST ==='
NG="$M1652/monitor/ng"; NEUTRAL_CWD="$WORK/neutral"; NG_EXTRA_ENV=(NEXUS_ROOT="$P1650")
run_ng out err rc issue comment 383 --body-file "$WORK/c1636.txt"
calls=$(<"$CAPTURE")
assert_eq        "#1652 P: write refused (rc 1)"                       "$rc" "1"
assert_not_contains "#1652 P: NO POST at all"                          "$calls" "-X POST"
assert_not_contains "#1652 P: …and in particular not to P's repo"      "$calls" "p-org/p-repo"
assert_contains  "#1652 P: the refusal says the config cannot be read" "$err" "config/nexus.yml that cannot be read"

NG_EXTRA_ENV=(); NEUTRAL_CWD="$_saved_neutral"; NG="$_saved_ng"

# ---- summary -----------------------------------------------------------

th_summary_and_exit
