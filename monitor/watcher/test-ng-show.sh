#!/usr/bin/env bash
# Unit tests for `ng show <comment-id>` (cmd_show in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-show.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: PATH-shadow `gh` to return canned comment metadata for
# /repos/<o>/<r>/issues/comments/<id>. Drive `ng show` and check both
# the resolved endpoint (captured) and the stdout body.
#
# Coverage map (from your-org/nexus-code#39):
#   - Required-arg validation (missing comment-id).
#   - Unknown flag rejection.
#   - Successful fetch returns the body field.
#   - Empty body → exit non-zero.
#   - `--repo OWNER/NAME` override embedded in the endpoint.
#   - `--repo` overrides the cwd-derived origin (read-mode).

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

WORK=$(mktemp -d -t nexus-ng-show-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"

cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-installation-token'
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
CAPTURE="$WORK/gh-calls.txt"

# Returns canned comment metadata. $MOCK_EMPTY=1 simulates the
# "empty body" failure path.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NG_SHOW_CAPTURE"
if [[ "${1:-}" != "api" ]]; then exit 0; fi
shift
endpoint=""
while (( $# > 0 )); do
    case "$1" in
        -X)              shift 2 ;;
        -H|-f|--input)   shift 2 ;;
        --paginate)      shift ;;
        --)              shift; break ;;
        /*)              endpoint="$1"; shift ;;
        -*)              shift ;;
        *)               shift ;;
    esac
done
if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi
case "$endpoint" in
    */issues/comments/*)
        if [[ "${MOCK_EMPTY:-0}" == "1" ]]; then
            printf '{"body":""}'
        else
            printf '{"body":"hello from a stubbed comment\\nsecond line"}'
        fi
        ;;
    *)
        printf '{}'
        ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# Non-git cwd avoids _resolve_repo's cwd-origin path; the default-repo
# in config/load.sh wins for read-mode.
NON_GIT_CWD="$WORK/non-git"
mkdir -p "$NON_GIT_CWD"

CWD_REPO="$WORK/cwd-git"
mkdir -p "$CWD_REPO"
( cd "$CWD_REPO" \
    && git init -q \
    && git remote add origin "git@github.com:cwd-org/cwd-repo.git" )

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3" _cwd="$4"; shift 4
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE"
    env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
        NEXUS_STATE_DIR="$WORK/state" \
        NG_SHOW_CAPTURE="$CAPTURE" \
        PATH="$STUB_DIR:$PATH" \
        bash -c 'cd "$1" && shift && "$@"' _ "$_cwd" "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# ---- Test 1: required-arg validation ------------------------------------

echo '=== required-arg validation ==='
run_ng out err rc "$NON_GIT_CWD" show
assert_eq        "no comment-id → exit non-zero"     "$rc" "1"
assert_contains  "stderr mentions usage"             "$err" "usage: ng show"

run_ng out err rc "$NON_GIT_CWD" show 1234 --bogus thing
assert_eq        "unknown flag → exit non-zero"      "$rc" "1"
assert_contains  "stderr names unknown flag"         "$err" "unknown flag: --bogus"

# ---- Test 2: successful fetch -------------------------------------------

echo '=== successful fetch returns body ==='
run_ng out err rc "$NON_GIT_CWD" show 1234
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout has line 1"                 "$out" "hello from a stubbed comment"
assert_contains  "stdout has line 2"                 "$out" "second line"
calls=$(<"$CAPTURE")
assert_contains  "endpoint includes /issues/comments/1234" "$calls" \
                 "/repos/default-org/default-repo/issues/comments/1234"

# ---- Test 3: empty body → failure path ----------------------------------

echo '=== empty body → exit non-zero ==='
MOCK_EMPTY=1 run_ng out err rc "$NON_GIT_CWD" show 5555
assert_eq        "exit non-zero"                     "$rc" "1"
assert_contains  "stderr explains empty body"        "$err" "fetch failed (or empty body)"

# ---- Test 4: --repo override --------------------------------------------

echo '=== --repo OWNER/NAME override ==='
run_ng out err rc "$NON_GIT_CWD" show 7777 --repo other-org/other-repo
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "endpoint reflects --repo"          "$calls" \
                 "/repos/other-org/other-repo/issues/comments/7777"

# ---- Test 5: --repo wins over cwd-origin (read-mode) --------------------

echo '=== --repo overrides cwd-origin ==='
run_ng out err rc "$CWD_REPO" show 8888 --repo explicit/winner
assert_eq        "exit 0"                            "$rc" "0"
calls=$(<"$CAPTURE")
assert_contains  "endpoint reflects --repo, not cwd" "$calls" \
                 "/repos/explicit/winner/issues/comments/8888"
assert_not_contains "no cwd-derived endpoint"        "$calls" \
                    "/repos/cwd-org/cwd-repo/"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
