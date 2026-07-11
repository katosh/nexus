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
assert_empty() {
    local label="$1" val="$2"
    if [[ -z "$val" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — expected empty, got %q\n' "$label" "$val" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — missing file %q\n' "$label" "$path" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_no_file() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — unexpected file %q\n' "$label" "$path" >&2; FAIL=$(( FAIL + 1 )); fi
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

# ===========================================================================
# your-org/nexus-code#488 — the cache is an OPTIMISATION; the token is the
# PRODUCT. A successfully minted token must never be discarded because a
# cache SIDE EFFECT failed. Under `set -e` a bare mktemp/mv/chmod/date
# failure aborted the script before the final `printf`: rc 1, empty stdout,
# and a correct operation reported as broken.
#
# Root-only note: a 0555 dir is writable by root, so these read-only cases
# are skipped when running as uid 0.
# ===========================================================================
_ro_ok=1
[[ "$(id -u)" == "0" ]] && _ro_ok=0

if (( _ro_ok )); then

echo '=== #488: read-only cache dir — token is RETURNED, not discarded ==='
clean_cache
chmod 0555 "$WORK/cache"
out=$(env "${HAPPY_ENV[@]}" "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt"); rc=$?
err=$(cat "$WORK/err.txt")
chmod 0755 "$WORK/cache"
assert_eq       "488/ro-dir: exit 0 (the mint succeeded)"        "$rc"  "0"
assert_eq       "488/ro-dir: the TOKEN is on stdout"             "$out" "ghs_testtoken123abc"
assert_contains "488/ro-dir: warns that the cache was skipped"   "$err" "skipping the cache"
assert_contains "488/ro-dir: says the token is still valid"      "$err" "token is valid"

echo '=== #488: cache dir does not exist AND cannot be created — still mints ==='
# The double-outage case: project FS read-only (#473) AND $HOME read-only.
# The old code ran `mkdir -p` BEFORE the network call and died rc 2 without
# ever attempting the mint, with a healthy network one curl away.
rm -rf "$WORK/cache"
mkdir -p "$WORK/rohome"; chmod 0555 "$WORK/rohome"
out=$(env "${HAPPY_ENV[@]}" TEST_CACHE_PATH="$WORK/rohome/sub/token.json" \
      "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt"); rc=$?
err=$(cat "$WORK/err.txt")
chmod 0755 "$WORK/rohome"; mkdir -p "$WORK/cache"
assert_eq       "488/cold-ro: exit 0 (mint attempted and succeeded)" "$rc"  "0"
assert_eq       "488/cold-ro: the TOKEN is on stdout"                "$out" "ghs_testtoken123abc"
assert_contains "488/cold-ro: warns it continues without a cache"    "$err" "continuing without a cache"

fi   # _ro_ok

echo '=== #488: unparseable expires_at — token returned, cache skipped ==='
clean_cache
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"token":"ghs_testtoken123abc","expires_at":"not-a-date"}'
STUB
chmod +x "$WORK/bin/curl"
out=$(env "${HAPPY_ENV[@]}" "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt"); rc=$?
err=$(cat "$WORK/err.txt")
assert_eq       "488/bad-date: exit 0"                        "$rc"  "0"
assert_eq       "488/bad-date: the TOKEN is on stdout"        "$out" "ghs_testtoken123abc"
assert_contains "488/bad-date: warns about expires_at"        "$err" "unparseable expires_at"
assert_no_file  "488/bad-date: no cache written"              "$WORK/cache/token.json"

echo '=== #488: no tmp file is left behind when the cache write fails ==='
leftover=$(find "$WORK/cache" -name 'token.json.*' 2>/dev/null | wc -l)
assert_eq "488/no-residue: zero cache tempfiles left" "$leftover" "0"

# Restore the good curl stub for the remaining cases.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"token":"ghs_testtoken123abc","expires_at":"2099-01-01T00:00:00Z"}'
STUB
chmod +x "$WORK/bin/curl"

echo '=== #488: a corrupt cache (fresh epoch, no .token) must NOT emit "null" ==='
clean_cache
# jq -r on a missing key prints the literal string `null`. The old warm-cache
# path emitted it and exited 0; the caller`s `[[ -n "$tok" ]]` guard passes
# and every subsequent write 401s. Fall through and mint instead.
printf '{"expires_at_epoch":4102444800}' > "$WORK/cache/token.json"
out=$(env "${HAPPY_ENV[@]}" "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt"); rc=$?
assert_eq "488/corrupt: exit 0"                          "$rc"  "0"
assert_eq "488/corrupt: fell through to a fresh mint"    "$out" "ghs_testtoken123abc"
if [[ "$out" == "null" ]]; then
    echo "  FAIL: 488/corrupt: emitted the literal string null" >&2; FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: 488/corrupt: never emits the literal string null"; PASS=$(( PASS + 1 ))
fi

echo '=== #488: (control) a WRITABLE cache is still written and still served ==='
clean_cache
out=$(env "${HAPPY_ENV[@]}" "$NEXUS/monitor/mint-token.sh" 2>/dev/null); rc=$?
assert_eq          "488/control: exit 0"                    "$rc"  "0"
assert_eq          "488/control: token returned"            "$out" "ghs_testtoken123abc"
assert_file_exists "488/control: cache WAS written"         "$WORK/cache/token.json"
# Second call must be served from the cache without touching curl at all.
mv "$WORK/bin/curl" "$WORK/bin/curl.hidden"
out=$(env "${HAPPY_ENV[@]}" "$NEXUS/monitor/mint-token.sh" 2>/dev/null); rc=$?
mv "$WORK/bin/curl.hidden" "$WORK/bin/curl"
assert_eq "488/control: warm cache served without a mint" "$out" "ghs_testtoken123abc"
assert_eq "488/control: warm-cache exit 0"                "$rc"  "0"
# And its mode is still 600 (chmod moved before the rename).
mode=$(stat -c '%a' "$WORK/cache/token.json" 2>/dev/null || echo '?')
assert_eq "488/control: cache is mode 600" "$mode" "600"

echo '=== #488: (control) a genuine mint FAILURE is still fatal (no false negative) ==='
clean_cache
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"message":"Bad credentials"}'
STUB
chmod +x "$WORK/bin/curl"
out=$(env "${HAPPY_ENV[@]}" "$NEXUS/monitor/mint-token.sh" 2>"$WORK/err.txt"); rc=$?
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '{"token":"ghs_testtoken123abc","expires_at":"2099-01-01T00:00:00Z"}'
STUB
chmod +x "$WORK/bin/curl"
assert_eq    "488/control: failed mint still exits 3" "$rc" "3"
assert_empty "488/control: failed mint prints no token" "$out"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
