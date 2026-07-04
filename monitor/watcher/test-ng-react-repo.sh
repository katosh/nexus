#!/usr/bin/env bash
# Unit tests for `ng react` / `ng react-issue` / `ng process` /
# `ng process-issue`'s --repo override (cmd_react family in
# monitor/ng).
#
# Run: bash monitor/watcher/test-ng-react-repo.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: same harness shape as test-ng-reply-repo.sh — minimal
# nexus tree under a temp dir, stubbed config + mint-token, gh
# shadowed on PATH to capture POSTed endpoints. Asserts the captured
# endpoint embeds the expected OWNER/REPO, mirroring the precedence
# rules from issue `#108`: explicit --repo wins, cwd-derive without
# --repo on a write verb is a structured error.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"

# State dir under the fake nexus so processed-comments cache writes
# don't pollute the real one. ng's _resolve_state_dir honors
# $NEXUS_STATE_DIR ahead of the script-dir fallback.
export NEXUS_STATE_DIR="$WORK/state"
mkdir -p "$NEXUS_STATE_DIR"

cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf '%s' "${TEST_DEFAULT_REPO:-default-org/default-repo}" ;;
    github.user_login)  printf '%s' "${TEST_DEFAULT_USER:-test-user}" ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-installation-token'
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# Stub gh. cmd_react's POST /reactions expects an `.id` in the
# response; cmd_process's GET expects user.login + body + issue_url
# fields and a non-empty reactions array (which must show ZERO
# eligibility marks for the eligibility check to pass).
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
CAPTURE_FILE="$WORK/gh-calls.txt"

cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$CAPTURE_FILE"
# Argv shape is: api [-X METHOD] <endpoint> [-f k=v ...]
[[ "\${1:-}" == "api" ]] || { exit 0; }
shift
method="GET"
endpoint=""
while (( \$# > 0 )); do
    case "\$1" in
        -X) method="\$2"; shift 2 ;;
        -f|--input) shift 2 ;;
        --paginate) shift ;;
        -*) shift ;;
        *)  endpoint="\$1"; shift ;;
    esac
done
# Drain stdin so any upstream pipeline doesn't SIGPIPE.
[[ -t 0 ]] || cat >/dev/null
case "\$endpoint" in
    */reactions*)
        if [[ "\$method" == "POST" ]]; then
            printf '{"id": 9999, "content": "eyes"}'
        else
            # GET reactions list: empty array → 0 eligibility marks
            printf '[]'
        fi
        ;;
    */issues/comments/*)
        # GET /repos/.../issues/comments/<id> — comment metadata
        printf '{"user":{"login":"test-user"},"body":"hi","issue_url":"https://api.github.com/repos/o/r/issues/42"}'
        ;;
    */issues/*)
        # GET /repos/.../issues/<n> — issue metadata
        printf '{"user":{"login":"test-user"},"body":"hi"}'
        ;;
    *)
        printf '{}'
        ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/gh"

run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3" _cwd="$4"; shift 4
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    : > "$CAPTURE_FILE"
    ( cd "$_cwd" && PATH="$STUB_DIR:$PATH" "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp" )
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

NON_GIT_CWD="$WORK/non-git"
mkdir -p "$NON_GIT_CWD"

CWD_REPO="$WORK/cwd-git"
mkdir -p "$CWD_REPO"
( cd "$CWD_REPO" \
    && git init -q \
    && git remote add origin "git@github.com:cwd-org/cwd-repo.git" )

# ---- Test 1: --repo trailing (the original failure shape) ---------------
#
# `monitor/ng react <id> <content> --repo OWNER/NAME` is the natural call
# shape and the one the orchestrator uses. Prior to the fix the flag was
# silently ignored; the POST went to /repos/$REPO/... → 404 if $REPO
# differed from the comment's repo.

echo '=== ng react <id> <content> --repo X (trailing flag) → POST /repos/X/... ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    react 4242 eyes --repo override-org/override-repo
assert_eq        "exit 0"                                "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST endpoint embeds --repo target"    "$gh_args" \
                 "/repos/override-org/override-repo/issues/comments/4242/reactions"
assert_not_contains "no fallback to config default"      "$gh_args" \
                    "default-org/default-repo"

# ---- Test 2: --repo leading -------------------------------------------

echo '=== ng react --repo X <id> <content> (leading flag) → POST /repos/X/... ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    react --repo override-org/override-repo 4242 eyes
assert_eq        "exit 0"                                "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST endpoint embeds --repo target"    "$gh_args" \
                 "/repos/override-org/override-repo/issues/comments/4242/reactions"

# ---- Test 3: no --repo, non-git cwd → $REPO from config ---------------

echo '=== ng react (no --repo, non-git cwd) → POST hits $REPO from config ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    react 4242 eyes
assert_eq        "exit 0"                                "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST endpoint embeds config \$REPO"    "$gh_args" \
                 "/repos/default-org/default-repo/issues/comments/4242/reactions"

# ---- Test 4: cwd mismatch without --repo → STRUCTURED ERROR ----------
#
# Issue `#108`: react is a write verb; cwd-origin != $REPO without
# explicit --repo must fail loud, not silently misroute.

echo '=== ng react (no --repo, cwd != $REPO) → structured error ==='
run_ng stdout stderr rc "$CWD_REPO" \
    react 4242 eyes
assert_eq        "exit 1 on cwd-mismatch write"          "$rc" "1"
assert_contains  "stderr names config target"            "$stderr" \
                 "writes to default-org/default-repo"
assert_contains  "stderr names cwd repo"                 "$stderr" \
                 "cwd is cwd-org/cwd-repo"
assert_contains  "stderr names --repo override"          "$stderr" \
                 "pass --repo explicitly"
gh_args=$(<"$CAPTURE_FILE")
assert_not_contains "no POST attempted on misroute-block" "$gh_args" \
                    "/reactions"

# ---- Test 5: --repo wins over cwd origin ------------------------------

echo '=== ng react --repo X, cwd Y → POST /repos/X/... (cwd ignored) ==='
run_ng stdout stderr rc "$CWD_REPO" \
    react 4242 eyes --repo win-org/win-repo
assert_eq        "exit 0 with --repo overriding cwd"     "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST endpoint embeds --repo target"    "$gh_args" \
                 "/repos/win-org/win-repo/issues/comments/4242/reactions"
assert_not_contains "cwd origin suppressed by --repo"    "$gh_args" \
                    "cwd-org/cwd-repo"

# ---- Test 6: react-issue (parallel verb) takes --repo too -------------

echo '=== ng react-issue 11 rocket --repo X → POST /repos/X/issues/11/reactions ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    react-issue 11 rocket --repo override-org/override-repo
assert_eq        "exit 0"                                "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "POST endpoint embeds --repo target"    "$gh_args" \
                 "/repos/override-org/override-repo/issues/11/reactions"

# ---- Test 7: process (read+write verb) takes --repo too --------------

echo '=== ng process 4242 --repo X → both GET and POST hit /repos/X/... ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    process 4242 --repo override-org/override-repo
assert_eq        "exit 0"                                "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "GET comment metadata on --repo target" "$gh_args" \
                 "/repos/override-org/override-repo/issues/comments/4242"
assert_contains  "POST eyes on --repo target"            "$gh_args" \
                 "/repos/override-org/override-repo/issues/comments/4242/reactions"
assert_not_contains "no leak to config default"          "$gh_args" \
                    "default-org/default-repo"

# ---- Test 8: process-issue (parallel verb) takes --repo too ----------

echo '=== ng process-issue 11 --repo X → GET+POST hit /repos/X/issues/11... ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    process-issue 11 --repo override-org/override-repo
assert_eq        "exit 0"                                "$rc" "0"
gh_args=$(<"$CAPTURE_FILE")
assert_contains  "GET issue metadata on --repo target"   "$gh_args" \
                 "/repos/override-org/override-repo/issues/11"
assert_contains  "POST eyes on --repo target"            "$gh_args" \
                 "/repos/override-org/override-repo/issues/11/reactions"

# ---- Test 9: bad content rejected before the network -----------------

echo '=== ng react 4242 thumbsup → rejected (only eyes|rocket allowed) ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    react 4242 thumbsup --repo o/r
assert_eq        "exit 1 on bad content"                 "$rc" "1"
assert_contains  "stderr names allowed values"           "$stderr" \
                 "eyes|rocket"
gh_args=$(<"$CAPTURE_FILE")
assert_not_contains "no network on bad content"          "$gh_args" \
                    "/reactions"

# ---- Test 10: unknown flag rejected ----------------------------------

echo '=== ng react 4242 eyes --bogus → exit 1 ==='
run_ng stdout stderr rc "$NON_GIT_CWD" \
    react 4242 eyes --bogus value
assert_eq        "exit 1 on unknown flag"                "$rc" "1"
assert_contains  "stderr names the unknown flag"         "$stderr" \
                 "--bogus"

# ---- summary ---------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
