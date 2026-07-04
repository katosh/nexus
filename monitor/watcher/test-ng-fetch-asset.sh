#!/usr/bin/env bash
# Mock-curl/gh unit tests for `ng fetch-asset` (cmd_fetch_asset in
# monitor/ng).
#
# Run: bash monitor/watcher/test-ng-fetch-asset.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: monitor/ng dispatches at the bottom and is not source-able
# without side effects. We invoke it as a subprocess with PATH-shadowed
# `gh` and `curl` stubs that branch on env vars to canned responses.
# Output goes to per-test --out paths under $WORK so we never touch
# the real monitor/.state/assets/ tree.
#
# What is tested: argument parsing, exit-code contract (0/1/2/3/4),
# happy-path stdout shape, --image-only filter, default-path naming
# (asset-id + extension derivation from S3 basename and from
# response-content-type query param fallback).
#
# What is NOT tested here: live integration against the real
# user-attachments service. The image-fetch-poison rule (CLAUDE.md
# "Common gotchas") forbids handing live user-attachments URLs to
# sub-agents and to Read; the live smoke test was performed once by
# the implementing agent and recorded in PR #73's body.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG="$_test_dir/../ng"

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
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_no_file() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — unexpected file: %s\n' "$label" "$path" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Stage-2 byte payload that the curl mock writes when MOCK_S2_STATUS=200.
# Use a deterministic 16-byte sequence so byte-count assertions are stable.
MOCK_S2_BYTES_FILE="$WORK/s2-bytes.bin"
printf '0123456789ABCDEF' > "$MOCK_S2_BYTES_FILE"
EXPECT_BYTES=$(stat -c %s "$MOCK_S2_BYTES_FILE")

# PATH stub directory. We shadow `gh` (only `gh auth token` is invoked
# by cmd_fetch_asset) and `curl` (the two-stage download). Other
# commands fall through to the real PATH.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Mock gh. Only `gh auth token` is invoked by cmd_fetch_asset.
# MOCK_PAT controls the printed token; empty → empty stdout (auth
# fail path). Anything else passes through with empty stdout to
# avoid masking accidental calls; cmd_fetch_asset only cares about
# `auth token`.
if [[ "${1:-}" == "auth" && "${2:-}" == "token" ]]; then
    printf '%s' "${MOCK_PAT-}"
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# Mock curl. cmd_fetch_asset invokes curl twice with shapes:
#   stage 1: curl -sS -o /dev/null -D <h1> -w '%{http_code}' \
#                 -H 'Authorization: ...' -H 'Accept: ...' <user-attachments URL>
#   stage 2: curl -sS -f -o <out> -D <h2> -w '%{http_code}' <s3 URL>
#
# We discriminate by the URL host of the last positional. Stage 1
# writes a Location header into <h1> and prints MOCK_S1_STATUS to
# stdout. Stage 2 writes MOCK_S2_BYTES_FILE bytes into <out>, writes
# Content-Type into <h2>, and prints MOCK_S2_STATUS. The -f flag
# (fail-fast on 4xx/5xx) is honoured by exiting non-zero when the
# stage-2 status is not 2xx.
cat > "$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
# Walk the argv to extract -o, -D, -w, and the trailing URL.
out=""; head_dump=""; want_status=0; url=""
while (( \$# > 0 )); do
    case "\$1" in
        -o) out="\$2"; shift 2 ;;
        -D) head_dump="\$2"; shift 2 ;;
        -w) want_status=1; shift 2 ;;  # we always print http_code
        -H) shift 2 ;;
        -sS|-f|-s|-S) shift ;;
        --) shift; break ;;
        -*) shift ;;
        *)  url="\$1"; shift ;;
    esac
done

case "\$url" in
    https://github.com/user-attachments/*)
        # Stage 1.
        if [[ -n "\$head_dump" ]]; then
            location_url="\${MOCK_S1_LOCATION-https://github-production-user-asset-6210df.s3.amazonaws.com/\${MOCK_S3_BASENAME:-deadbeef.png}?X-Amz-Signature=mock}"
            {
                printf 'HTTP/1.1 %s\\r\\n' "\${MOCK_S1_STATUS:-302}"
                if [[ -n "\$location_url" && "\${MOCK_S1_OMIT_LOCATION:-0}" != "1" ]]; then
                    printf 'Location: %s\\r\\n' "\$location_url"
                fi
                printf '\\r\\n'
            } > "\$head_dump"
        fi
        printf '%s' "\${MOCK_S1_STATUS:-302}"
        # cmd_fetch_asset reads stdout via -w '%{http_code}' but
        # always treats curl's exit as connectivity-only; non-2xx
        # statuses are routed by the http_code branch.
        if [[ "\${MOCK_S1_CURL_FAIL:-0}" == "1" ]]; then
            exit 6
        fi
        exit 0
        ;;
    https://*amazonaws.com/*|https://github-production-user-asset*|"\${MOCK_S1_LOCATION-}")
        # Stage 2.
        s2_status="\${MOCK_S2_STATUS:-200}"
        if [[ "\$s2_status" == "200" ]]; then
            cat "$MOCK_S2_BYTES_FILE" > "\$out"
        fi
        if [[ -n "\$head_dump" ]]; then
            {
                printf 'HTTP/1.1 %s\\r\\n' "\$s2_status"
                printf 'Content-Type: %s\\r\\n' "\${MOCK_S2_CONTENT_TYPE:-image/png}"
                printf '\\r\\n'
            } > "\$head_dump"
        fi
        printf '%s' "\$s2_status"
        # -f makes curl exit non-zero on >=400 — emulate that.
        if [[ "\$s2_status" -ge 400 ]]; then
            exit 22
        fi
        exit 0
        ;;
    *)
        printf '000'
        exit 6
        ;;
esac
STUB
chmod +x "$STUB_DIR/curl"

# Hermetic STATE_DIR. ng's resolver consults NEXUS_STATE_DIR /
# NEXUS_ROOT / config nexus.root before falling back to
# $_script_dir/.state. Pin it to a $WORK-scoped path so the test
# doesn't depend on the developer's local config (or leave debris
# in the real monitor/.state/assets/).
TEST_STATE_DIR="$WORK/state"
mkdir -p "$TEST_STATE_DIR/assets"

# Run ng with stubs in front of PATH. Captures stdout, stderr, exit.
# Usage: run_ng <out-var> <err-var> <rc-var> <args...>
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    # Internal names deliberately distinct from the caller's variable
    # names — `local rc` would shadow the caller's `rc` and prevent
    # `printf -v rc` from reaching it (dynamic scoping).
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
        NEXUS_STATE_DIR="$TEST_STATE_DIR" \
        PATH="$STUB_DIR:$PATH" \
        "$NG" "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

reset_mocks() {
    unset MOCK_S1_STATUS MOCK_S1_LOCATION MOCK_S1_OMIT_LOCATION
    unset MOCK_S1_CURL_FAIL MOCK_S2_STATUS MOCK_S2_CONTENT_TYPE
    unset MOCK_S3_BASENAME
    export MOCK_PAT="ghp_fake-user-pat"
}

# Constants used across tests.
ASSET_URL='https://github.com/user-attachments/assets/aa07c415-1cd3-4c65-97f7-2b5a3f5925b0'
ASSET_ID='aa07c415-1cd3-4c65-97f7-2b5a3f5925b0'

# ---- Test 1: happy path with --out --------------------------------------

echo '=== happy path: --out + 302 + 200 → exit 0, full triple printed ==='
reset_mocks
OUT="$WORK/got.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT"
assert_eq        "exit 0 on happy path"               "$rc" "0"
assert_file_exists "output file written at --out"     "$OUT"
assert_contains  "stdout reports path=$OUT"           "$stdout" "path=$OUT"
assert_contains  "stdout reports content_type=image/png" "$stdout" "content_type=image/png"
assert_contains  "stdout reports byte count"          "$stdout" "bytes=$EXPECT_BYTES"
rm -f "$OUT"

# ---- Test 2: --image-only on a non-image content-type → exit 4 ----------

echo '=== --image-only + content-type=application/zip → exit 4 ==='
reset_mocks
export MOCK_S2_CONTENT_TYPE="application/zip"
OUT="$WORK/got.bin"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT" --image-only
assert_eq        "exit 4 when --image-only filter rejects"  "$rc" "4"
assert_no_file   "output file removed on --image-only reject" "$OUT"
assert_contains  "stderr names the actual content-type"      "$stderr" "application/zip"

# ---- Test 3: missing positional arg → exit 1 ----------------------------

echo '=== no args → exit 1 + usage line ==='
reset_mocks
run_ng stdout stderr rc fetch-asset
assert_eq       "exit 1 with no args"                "$rc" "1"
assert_contains "stderr prints usage"                "$stderr" "usage: ng fetch-asset"

# ---- Test 4: unknown flag → exit 1 --------------------------------------

echo '=== unknown flag → exit 1 ==='
reset_mocks
run_ng stdout stderr rc fetch-asset --bogus "$ASSET_URL"
assert_eq       "exit 1 on unknown flag"             "$rc" "1"
assert_contains "stderr names the unknown flag"      "$stderr" "--bogus"

# ---- Test 5: non-user-attachments URL → exit 1 --------------------------

echo '=== bare URL not on user-attachments host → exit 1 ==='
reset_mocks
run_ng stdout stderr rc fetch-asset 'https://example.com/not-an-asset'
assert_eq       "exit 1 on wrong host"               "$rc" "1"
assert_contains "stderr explains the host check"     "$stderr" "user-attachments"

# ---- Test 6: empty user PAT → exit 2 ------------------------------------

echo '=== gh auth token returns empty → exit 2 ==='
reset_mocks
export MOCK_PAT=""
OUT="$WORK/got-empty-pat.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT"
assert_eq       "exit 2 when user PAT empty"         "$rc" "2"
assert_contains "stderr mentions gh auth login"      "$stderr" "gh auth login"
assert_no_file  "no output file on auth fail"        "$OUT"

# ---- Test 7: stage-1 returns 401 (PAT rejected) → exit 2 ----------------

echo '=== stage 1 → 401 (PAT rejected) → exit 2 ==='
reset_mocks
export MOCK_S1_STATUS="401"
OUT="$WORK/got-401.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT"
assert_eq       "exit 2 on stage-1 401"              "$rc" "2"
assert_contains "stderr explains PAT rejection"      "$stderr" "user PAT rejected"
assert_no_file  "no output file on PAT reject"       "$OUT"

# ---- Test 8: stage-1 returns 403 (PAT rejected) → exit 2 ----------------

echo '=== stage 1 → 403 (PAT rejected) → exit 2 ==='
reset_mocks
export MOCK_S1_STATUS="403"
OUT="$WORK/got-403.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT"
assert_eq       "exit 2 on stage-1 403"              "$rc" "2"

# ---- Test 9: stage-1 returns 404 → exit 3 -------------------------------

echo '=== stage 1 → 404 (asset not found) → exit 3 + actionable workaround ==='
reset_mocks
export MOCK_S1_STATUS="404"
OUT="$WORK/got-404.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT"
assert_eq       "exit 3 on stage-1 404"              "$rc" "3"
assert_contains "stderr names the not-accessible surface" \
                "$stderr" "not accessible to bot or user PAT"
assert_contains "stderr suggests local-file workaround" \
                "$stderr" "place the file locally"
assert_contains "stderr points at the issue timeline fallback" \
                "$stderr" "timeline"
assert_no_file  "no output file on 404"              "$OUT"

# ---- Test 10: stage-1 missing Location header → exit 3 ------------------

echo '=== stage 1 → 302 but no Location header → exit 3 ==='
reset_mocks
export MOCK_S1_OMIT_LOCATION="1"
OUT="$WORK/got-noloc.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT"
assert_eq       "exit 3 when Location header missing" "$rc" "3"
assert_contains "stderr explains the missing redirect" "$stderr" "Location header"

# ---- Test 11: stage-1 unexpected status → exit 3 ------------------------

echo '=== stage 1 → 500 (unexpected) → exit 3 ==='
reset_mocks
export MOCK_S1_STATUS="500"
OUT="$WORK/got-500.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT"
assert_eq       "exit 3 on unexpected stage-1 status" "$rc" "3"

# ---- Test 12: stage-2 returns 403 (signed URL denied) → exit 3 ----------

echo '=== stage 2 → 403 (signed URL expired/denied) → exit 3 ==='
reset_mocks
export MOCK_S2_STATUS="403"
OUT="$WORK/got-s2-403.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT"
assert_eq       "exit 3 on stage-2 403"              "$rc" "3"
assert_no_file  "stage-2 failure cleans up partial file" "$OUT"

# ---- Test 13: --image-only on image/* passes through --------------------

echo '=== --image-only + content-type=image/png → exit 0 ==='
reset_mocks
export MOCK_S2_CONTENT_TYPE="image/png"
OUT="$WORK/got-img.png"
run_ng stdout stderr rc fetch-asset "$ASSET_URL" --out "$OUT" --image-only
assert_eq        "exit 0 when --image-only matches"   "$rc" "0"
assert_file_exists "output file written"              "$OUT"
rm -f "$OUT"

# ---- Test 14: default --out path uses asset-id + S3-basename extension --

echo '=== default --out → monitor/.state/assets/<asset-id>.<ext> from S3 basename ==='
reset_mocks
export MOCK_S3_BASENAME="myfile.gif"
DEFAULT_OUT="$TEST_STATE_DIR/assets/${ASSET_ID}.gif"
rm -f "$DEFAULT_OUT"
run_ng stdout stderr rc fetch-asset "$ASSET_URL"
assert_eq        "exit 0 on default-path happy path"  "$rc" "0"
assert_file_exists "default-path file created"        "$DEFAULT_OUT"
assert_contains  "stdout reports default path"        "$stdout" "${ASSET_ID}.gif"
rm -f "$DEFAULT_OUT"

# ---- Test 15: default --out extension fallback via response-content-type

echo '=== default --out → ext from response-content-type query when basename has none ==='
reset_mocks
# Hand-crafted Location URL: basename has no dot, content-type=image/jpeg.
# The query param is URL-encoded (%2F) just like GitHub's signed URLs.
export MOCK_S1_LOCATION='https://github-production-user-asset-6210df.s3.amazonaws.com/no-extension-here?response-content-type=image%2Fjpeg&X-Amz-Signature=mock'
DEFAULT_OUT="$TEST_STATE_DIR/assets/${ASSET_ID}.jpg"
rm -f "$DEFAULT_OUT"
run_ng stdout stderr rc fetch-asset "$ASSET_URL"
assert_eq        "exit 0 on content-type-fallback path" "$rc" "0"
assert_file_exists "fallback-extension file created"    "$DEFAULT_OUT"
rm -f "$DEFAULT_OUT"

# ---- Test 16: --help prints usage and exits 0 ---------------------------

echo '=== --help → exit 0 ==='
reset_mocks
run_ng stdout stderr rc fetch-asset --help
assert_eq       "--help exits 0"                     "$rc" "0"
assert_contains "--help prints usage line"           "$stdout" "usage: ng fetch-asset"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
