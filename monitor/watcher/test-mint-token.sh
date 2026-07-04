#!/usr/bin/env bash
# Unit tests for `monitor/mint-token.sh`'s fail-loud config resolution
# and happy-path mint.
#
# Run: bash monitor/watcher/test-mint-token.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Background: prior to this fix the script silently fell through to
# `config/nexus.example.yml` when `config/nexus.yml` was missing —
# typically the case in a fresh worktree spawned for a worker. The
# example.yml template's placeholder bot_pem_path (`~/.claude/
# your-bot.pem`) doesn't exist, mint-token exited 2 with empty stdout,
# and the canonical caller pattern `GH_TOKEN=$(...) gh ...` substituted
# "" — which `gh` treats as "no override" and silently fell back to the
# user's ambient `gh auth token`. Net effect: PR #25 on your-org/
# nexus-code shipped under @operator, then had to be re-opened as PR #26
# under the bot once config was wired up.
#
# The new resolver's precedence (most-specific first):
#   1. $NEXUS_CONFIG   explicit YAML file path.
#   2. $NEXUS_ROOT     `<root>/config/nexus.yml`.
#   3. <script-dir>/../config/nexus.yml  (script-relative fallback).
#
# example.yml fallback is intentionally disabled — the loud failure is
# the point.
#
# Strategy: stub `config/load.sh`, `openssl`, and `curl` so the test
# exercises mint-token.sh's own logic without needing pyyaml, a real
# RSA key, or network access. Each failure-mode test asserts the
# specific stderr substring so a future refactor can't quietly drop
# the diagnostic that's load-bearing for operator triage.

set -uo pipefail

# Hermetic env: the operator's shell often has NEXUS_BOT_* set from
# day-to-day use (the orchestrator's mint cache lives under $HOME).
# Those values would short-circuit the script's config-loading logic
# (env wins over config), so unset them once for the whole test run.
unset NEXUS_BOT_APP_ID NEXUS_BOT_INSTALLATION_ID \
      NEXUS_BOT_PRIVATE_KEY_PATH NEXUS_BOT_TOKEN_CACHE \
      NEXUS_CONFIG NEXUS_ROOT

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MINT_REAL="$_test_dir/../mint-token.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — needle %q not in %q\n' "$label" "$needle" "$haystack" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_ne_zero() {
    local label="$1" rc="$2"
    if (( rc != 0 )); then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — expected non-zero exit, got 0\n' "$label" >&2; FAIL=$(( FAIL + 1 )); fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Worktree-shape: copy mint-token.sh under monitor/, stub load.sh
# under config/. The script anchors at $SCRIPT_DIR/.. so this layout
# mirrors a real clone.
NEXUS="$WORK/nexus"
mkdir -p "$NEXUS/monitor" "$NEXUS/config" "$WORK/bin" "$WORK/cache"
cp "$MINT_REAL" "$NEXUS/monitor/mint-token.sh"
chmod +x "$NEXUS/monitor/mint-token.sh"

# nexus.yml content is irrelevant — load.sh is stubbed. The file just
# needs to exist for the strict config-resolve check to pass.
echo '# placeholder' > "$NEXUS/config/nexus.yml"

# Stub config/load.sh. Each key's value is driven by a TEST_* env var;
# unsetting (or empty) makes the stub exit 2, mirroring real load.sh's
# "key not found and no default" behaviour. Supports the 2-arg
# "default" form for github.bot_token_cache.
cat > "$NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
key="$1"
default="${2-}"
case "$key" in
    github.bot_app_id)
        if [[ -n "${TEST_APP_ID-}" ]]; then printf '%s' "$TEST_APP_ID"; exit 0; fi
        [[ -n "$default" ]] && { printf '%s' "$default"; exit 0; }
        echo "load.sh: github.bot_app_id missing" >&2; exit 2 ;;
    github.bot_installation_id)
        if [[ -n "${TEST_INSTALL_ID-}" ]]; then printf '%s' "$TEST_INSTALL_ID"; exit 0; fi
        [[ -n "$default" ]] && { printf '%s' "$default"; exit 0; }
        echo "load.sh: github.bot_installation_id missing" >&2; exit 2 ;;
    github.bot_pem_path)
        if [[ -n "${TEST_KEY_PATH-}" ]]; then printf '%s' "$TEST_KEY_PATH"; exit 0; fi
        echo "load.sh: github.bot_pem_path missing" >&2; exit 2 ;;
    github.bot_token_cache)
        if [[ -n "${TEST_CACHE_PATH-}" ]]; then printf '%s' "$TEST_CACHE_PATH"; exit 0; fi
        [[ -n "$default" ]] && { printf '%s' "$default"; exit 0; }
        echo "load.sh: github.bot_token_cache missing" >&2; exit 2 ;;
    *) echo "load.sh: stub does not know $key" >&2; exit 2 ;;
esac
STUB
chmod +x "$NEXUS/config/load.sh"

# Stub openssl. Drains stdin (mint-token pipes header.payload through
# it) and emits a deterministic 32-byte "signature" so the JWT shape is
# preserved without RSA. Real openssl is not invoked.
cat > "$WORK/bin/openssl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'STUB-SIGNATURE-32-BYTES-XXXXXX!!'
STUB
chmod +x "$WORK/bin/openssl"

# Stub curl. Returns a fixed installation-token response. The token
# uses the `ghs_` prefix that GitHub's installation tokens carry; the
# happy-path test asserts the prefix to catch any future refactor that
# accidentally returns the App JWT instead.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Discard args; emit a fixed installation-token payload.
printf '{"token":"ghs_testtoken123abc","expires_at":"2099-01-01T00:00:00Z"}'
STUB
chmod +x "$WORK/bin/curl"

# Convenience: a minimal valid PEM-shaped placeholder. openssl is
# stubbed so the contents don't matter, but mint-token.sh checks
# `[[ -f "$KEY_PATH" ]]` and `[[ -r "$KEY_PATH" ]]`.
KEY_OK="$WORK/key-ok.pem"
echo 'placeholder-key' > "$KEY_OK"
chmod 600 "$KEY_OK"

# Default env clause used by the happy-path runs. Per-test runs
# override individual vars via additional `env` flags.
HAPPY_ENV=(
    "NEXUS_ROOT=$NEXUS"
    "TEST_APP_ID=12345"
    "TEST_INSTALL_ID=67890"
    "TEST_KEY_PATH=$KEY_OK"
    "TEST_CACHE_PATH=$WORK/cache/token.json"
    "PATH=$WORK/bin:$PATH"
)

run_mint() {
    # $1: label for diagnostics (unused but kept for parity with test
    # patterns in this dir). The caller passes additional env -u / VAR=
    # tokens before invoking the script.
    shift
    "$@" "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt"
}

# Wipe the cache between runs so the cache-hit short-circuit can't mask
# a regression in the mint path.
clean_cache() { rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; }

# ---- Test 1: missing nexus.yml dies loud (no env override) -------------

echo '=== missing nexus.yml — no NEXUS_CONFIG, no NEXUS_ROOT, no script-relative ==='
clean_cache
# Move nexus.yml aside so script-relative resolution fails.
mv "$NEXUS/config/nexus.yml" "$NEXUS/config/nexus.yml.hidden"
out=$(env -u NEXUS_CONFIG -u NEXUS_ROOT \
    PATH="$WORK/bin:$PATH" \
    "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt")
rc=$?
err=$(cat "$WORK/err.txt")
mv "$NEXUS/config/nexus.yml.hidden" "$NEXUS/config/nexus.yml"
assert_eq "exit code is 2 (config not found)"     "$rc"  "2"
assert_contains "stderr names nexus.yml"           "$err" "config/nexus.yml not found"
assert_contains "stderr suggests NEXUS_ROOT fix"   "$err" "NEXUS_ROOT"
assert_eq "stdout is empty"                        "$out" ""

# ---- Test 2: NEXUS_CONFIG points at missing file -----------------------

echo '=== NEXUS_CONFIG points at a file that does not exist ==='
clean_cache
out=$(env -u NEXUS_ROOT NEXUS_CONFIG="$WORK/does-not-exist.yml" \
    PATH="$WORK/bin:$PATH" \
    "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt")
rc=$?
err=$(cat "$WORK/err.txt")
assert_eq "exit code is 2"                                "$rc"  "2"
assert_contains "stderr names NEXUS_CONFIG path"          "$err" "does-not-exist.yml"
assert_contains "stderr explains file does not exist"     "$err" "does not exist"

# ---- Test 3: NEXUS_ROOT set but missing config/nexus.yml under it ------

echo '=== NEXUS_ROOT set, but config/nexus.yml not under it ==='
clean_cache
EMPTY_ROOT="$WORK/empty-root"
mkdir -p "$EMPTY_ROOT/config"
out=$(env -u NEXUS_CONFIG NEXUS_ROOT="$EMPTY_ROOT" \
    PATH="$WORK/bin:$PATH" \
    "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt")
rc=$?
err=$(cat "$WORK/err.txt")
assert_eq "exit code is 2"                                "$rc"  "2"
assert_contains "stderr names the expected path"          "$err" "$EMPTY_ROOT/config/nexus.yml"

# ---- Test 4: nexus.yml present but github.bot_app_id missing -----------

echo '=== bot_app_id key missing in loaded config ==='
clean_cache
out=$(env -u NEXUS_CONFIG \
    NEXUS_ROOT="$NEXUS" \
    TEST_INSTALL_ID=67890 \
    TEST_KEY_PATH="$KEY_OK" \
    TEST_CACHE_PATH="$WORK/cache/token.json" \
    PATH="$WORK/bin:$PATH" \
    "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt")
rc=$?
err=$(cat "$WORK/err.txt")
assert_eq "exit code is 2"                                "$rc"  "2"
assert_contains "stderr names github.bot_app_id"          "$err" "github.bot_app_id"

# ---- Test 5: private key path points at non-existent file --------------

echo '=== github.bot_pem_path points at a missing file ==='
clean_cache
out=$(env -u NEXUS_CONFIG \
    NEXUS_ROOT="$NEXUS" \
    TEST_APP_ID=12345 \
    TEST_INSTALL_ID=67890 \
    TEST_KEY_PATH="$WORK/no-such-key.pem" \
    TEST_CACHE_PATH="$WORK/cache/token.json" \
    PATH="$WORK/bin:$PATH" \
    "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt")
rc=$?
err=$(cat "$WORK/err.txt")
assert_eq "exit code is 2"                                "$rc"  "2"
assert_contains "stderr says private key not found"       "$err" "private key not found"

# ---- Test 6: private key exists but is not readable --------------------
#
# Skip when running as root: root's read bit defeats chmod 000.
echo '=== github.bot_pem_path exists but is mode 000 ==='
if [[ "$(id -u)" == "0" ]]; then
    printf '  SKIP: running as root — chmod 000 does not block reads\n'
else
    clean_cache
    UNREADABLE="$WORK/key-unreadable.pem"
    echo 'placeholder' > "$UNREADABLE"
    chmod 000 "$UNREADABLE"
    out=$(env -u NEXUS_CONFIG \
        NEXUS_ROOT="$NEXUS" \
        TEST_APP_ID=12345 \
        TEST_INSTALL_ID=67890 \
        TEST_KEY_PATH="$UNREADABLE" \
        TEST_CACHE_PATH="$WORK/cache/token.json" \
        PATH="$WORK/bin:$PATH" \
        "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt")
    rc=$?
    err=$(cat "$WORK/err.txt")
    chmod 600 "$UNREADABLE"
    assert_eq "exit code is 2"                            "$rc"  "2"
    assert_contains "stderr says private key not readable" "$err" "not readable"
fi

# ---- Test 7: happy path — mocked openssl + curl return ghs_ token ------

echo '=== happy path: stubbed openssl + curl → ghs_ installation token ==='
clean_cache
out=$(env -u NEXUS_CONFIG \
    NEXUS_ROOT="$NEXUS" \
    TEST_APP_ID=12345 \
    TEST_INSTALL_ID=67890 \
    TEST_KEY_PATH="$KEY_OK" \
    TEST_CACHE_PATH="$WORK/cache/token.json" \
    PATH="$WORK/bin:$PATH" \
    "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt")
rc=$?
err=$(cat "$WORK/err.txt")
assert_eq "exit code is 0"                                "$rc"  "0"
assert_eq "stdout is the stub installation token"         "$out" "ghs_testtoken123abc"
assert_eq "stderr is empty on success"                    "$err" ""
# Cache write happened.
if [[ -f "$WORK/cache/token.json" ]]; then
    printf '  PASS: %s\n' "cache file written"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — %s missing\n' "cache file written" "$WORK/cache/token.json" >&2; FAIL=$(( FAIL + 1 ))
fi

# ---- Test 8: --jwt-only emits the App JWT, skips the install exchange --

echo '=== --jwt-only emits header.payload.signature, no curl call ==='
clean_cache
# Trip-wire curl: if --jwt-only mistakenly invokes curl, the stub
# returns the install-token JSON and the test will see "ghs_..." or
# JSON in stdout instead of the dot-separated JWT.
out=$(env -u NEXUS_CONFIG \
    NEXUS_ROOT="$NEXUS" \
    TEST_APP_ID=12345 \
    TEST_INSTALL_ID=67890 \
    TEST_KEY_PATH="$KEY_OK" \
    PATH="$WORK/bin:$PATH" \
    "$NEXUS/monitor/mint-token.sh" --jwt-only 2>"$WORK/err.txt")
rc=$?
err=$(cat "$WORK/err.txt")
assert_eq "exit code is 0"                                "$rc"  "0"
# JWT shape: three base64url segments separated by dots.
if [[ "$out" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
    printf '  PASS: %s\n' "stdout matches JWT shape"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — stdout=%q\n' "stdout matches JWT shape" "$out" >&2; FAIL=$(( FAIL + 1 ))
fi

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
