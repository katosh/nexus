#!/usr/bin/env bash
# Unit tests for `ng close` (cmd_close in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-close.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: PATH-shadow `gh` to capture argv (the issue # + endpoint
# combination is the load-bearing assertion) and to return canned
# PATCH responses. Drive `ng close` and check both the captured
# calls and the exit code / stdout / stderr.
#
# Coverage map (from your-org/nexus-code#39):
#   - Required-arg validation.
#   - Unknown flag rejection.
#   - With --comment: pre-close POST hits /issues/<n>/comments,
#     then PATCH state=closed.
#   - Without --comment: no comment POST, only PATCH.
#   - PATCH returning {state:"closed"} → prints "CLOSED", exit 0.
#   - PATCH returning a non-closed state → exit non-zero.
#   - Pre-close comment POST failure → exit non-zero, no PATCH.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

WORK=$(mktemp -d -t nexus-ng-close-XXXXXX)
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

# `gh` stub:
#   - POST /repos/.../issues/<n>/comments → returns {html_url:"..."}.
#     Honors $MOCK_COMMENT_FAIL=1 to simulate a 422.
#   - PATCH /repos/.../issues/<n> → returns {state:$MOCK_STATE} where
#     MOCK_STATE defaults to "closed".
#   - Other endpoints → empty JSON.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NG_CLOSE_CAPTURE"
if [[ "${1:-}" != "api" ]]; then exit 0; fi
shift
method="GET"; endpoint=""
while (( $# > 0 )); do
    case "$1" in
        -X)              method="$2"; shift 2 ;;
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
    */issues/*/comments)
        if [[ "${MOCK_COMMENT_FAIL:-0}" == "1" ]]; then
            echo '{"message":"mock comment POST 422"}' >&2
            exit 1
        fi
        printf '{"html_url":"https://mock.example/comment-9999"}'
        ;;
    */issues/*)
        if [[ "$method" == "PATCH" ]]; then
            printf '{"state":"%s"}' "${MOCK_STATE:-closed}"
        else
            printf '{}'
        fi
        ;;
    *)
        printf '{}'
        ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE"
    env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
        NEXUS_STATE_DIR="$WORK/state" \
        NG_CLOSE_CAPTURE="$CAPTURE" \
        PATH="$STUB_DIR:$PATH" \
        "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# ---- Test 1: required-arg validation ------------------------------------

echo '=== required-arg validation ==='
run_ng out err rc close
assert_eq        "no issue arg → exit non-zero"      "$rc" "1"
assert_contains  "stderr mentions usage"             "$err" "usage: ng close"

run_ng out err rc close 42 --bogus thing
assert_eq        "unknown flag → exit non-zero"      "$rc" "1"
assert_contains  "stderr names unknown flag"         "$err" "unknown flag: --bogus"

# ---- Test 2: close without --comment ------------------------------------

echo '=== close 42 (no comment) ==='
run_ng out err rc close 42
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout prints CLOSED"              "$out" "CLOSED"
calls=$(<"$CAPTURE")
assert_not_contains "no pre-close comment POST"      "$calls" "/issues/42/comments"
assert_contains  "PATCH /issues/42"                  "$calls" "-X PATCH /repos/default-org/default-repo/issues/42"
assert_contains  "PATCH state=closed"                "$calls" "state=closed"

# ---- Test 3: close with --comment ---------------------------------------

echo '=== close 42 --comment "shipped" ==='
run_ng out err rc close 42 --comment "shipped"
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout prints CLOSED"              "$out" "CLOSED"
calls=$(<"$CAPTURE")
# Order matters: comment POST must precede the PATCH.
order=$(grep -nE '/issues/42/comments|-X PATCH /repos' "$CAPTURE" | head -2 | cut -d: -f1)
first=$(awk 'NR==1' <<<"$order")
second=$(awk 'NR==2' <<<"$order")
assert_eq        "comment POST first"                "$first" "1"
assert_eq        "PATCH second"                      "$second" "2"

# ---- Test 4: PATCH returning non-closed state ---------------------------

echo '=== PATCH returns "open" (mock) → exit non-zero ==='
MOCK_STATE=open run_ng out err rc close 42
assert_eq        "exit non-zero"                     "$rc" "1"
assert_contains  "stderr explains close failure"     "$err" "close PATCH failed (state=open)"

# ---- Test 5: comment POST failure short-circuits ------------------------

echo '=== comment POST 422 → exit non-zero, no PATCH ==='
MOCK_COMMENT_FAIL=1 run_ng out err rc close 42 --comment "x"
assert_eq        "exit non-zero"                     "$rc" "1"
assert_contains  "stderr names pre-close failure"    "$err" "pre-close comment failed"
calls=$(<"$CAPTURE")
assert_not_contains "no PATCH after comment failure" "$calls" "-X PATCH"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
