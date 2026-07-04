#!/usr/bin/env bash
# Unit tests for `ng mint-jwt` (cmd_mint_jwt in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-mint-jwt.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: cmd_mint_jwt is a thin shim over `monitor/mint-token.sh
# --jwt-only`. We exercise it end-to-end against the real mint-token.sh
# with a fake config/load.sh, a generated test RSA key, and stubbed
# /dev/urandom-free dependencies (base64 / openssl already present).
# Each failure-mode test pins the config stub differently so we can
# pin specific resolution failures: missing pem file, missing keys,
# malformed pem. The happy-path test asserts on the 3-part JWT
# structure printed to stdout.
#
# Coverage map (from your-org/nexus-code#60):
#   cmd_mint_jwt — extra arg rejection; mint-token.sh failure
#     propagation (exit non-zero); empty-JWT edge case (exit 0 but
#     no stdout); happy path (3 base64url segments).
#   Plus integration through real mint-token.sh:
#     - missing pem file
#     - missing github.bot_app_id config key
#     - malformed pem (openssl signature failure)
#     - happy path: round-trip a 2048-bit RSA key, assert structural
#       shape of the printed JWT (header.payload.sig, each segment
#       base64url-decodable; header is {"alg":"RS256","typ":"JWT"};
#       payload carries iat/exp/iss).

set -uo pipefail

# Operator shells routinely export NEXUS_BOT_* and NEXUS_ROOT for
# day-to-day bot work. mint-token.sh reads those env vars BEFORE the
# config-key lookup (the env-overrides-config precedence), so a real
# $NEXUS_BOT_PRIVATE_KEY_PATH would mask our missing-key failure modes
# by short-circuiting `_cfg_required github.bot_pem_path`. Scrub the
# whole NEXUS_BOT_* family once for the test run — the same hermetic
# scrub that test-mint-token.sh already performs.
unset NEXUS_BOT_APP_ID NEXUS_BOT_INSTALLATION_ID \
      NEXUS_BOT_PRIVATE_KEY_PATH NEXUS_BOT_TOKEN_CACHE

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-ng-mint-jwt-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

setup_fake_nexus "$WORK/nexus"
NG="$FAKE_NEXUS/monitor/ng"

# Replace setup_fake_nexus's stubbed mint-token.sh with the REAL one
# so we exercise the actual config-resolution / signing path. The
# stubbed copy only printed a fake installation token, which would
# bypass everything we want to test here.
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cp "$_test_dir/../mint-token.sh" "$FAKE_NEXUS/monitor/mint-token.sh"
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# Sentinel nexus.yml file — mint-token.sh's _resolve_cfg requires the
# file to exist on disk; the contents don't matter because config/
# load.sh is stubbed and never actually parses YAML.
NEXUS_YML="$FAKE_NEXUS/config/nexus.yml"
: > "$NEXUS_YML"

# Generate a 2048-bit RSA test key once. openssl genpkey is the
# portable invocation across openssl 1.x and 3.x; takes ~0.3s.
GOOD_KEY="$WORK/test-key.pem"
openssl genpkey -algorithm RSA -out "$GOOD_KEY" \
    -pkeyopt rsa_keygen_bits:2048 2>/dev/null

# Variant config/load.sh stubs are written per-test; the harness
# always points $NEXUS_CONFIG at $NEXUS_YML and runs through the
# real mint-token.sh. Each `write_load_stub <variant>` overwrites
# config/load.sh.
write_load_stub() {
    case "$1" in
        good)
            cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)                  printf 'default-org/default-repo' ;;
    github.user_login)            printf 'test-user' ;;
    github.bot_app_id)            printf '12345' ;;
    github.bot_installation_id)   printf '67890' ;;
    github.bot_pem_path)          printf '%s' '$GOOD_KEY' ;;
    github.bot_token_cache)       printf '%s/bot-token.json' '$WORK' ;;
    *) [[ \$# -ge 2 ]] && { printf '%s' "\$2"; exit 0; }; exit 2 ;;
esac
STUB
            ;;
        missing_pem_path_key)
            # github.bot_pem_path resolves empty / exits 2 →
            # _cfg_required dies with "key missing from <yml>".
            cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)                  printf 'default-org/default-repo' ;;
    github.user_login)            printf 'test-user' ;;
    github.bot_app_id)            printf '12345' ;;
    github.bot_installation_id)   printf '67890' ;;
    github.bot_pem_path)          exit 2 ;;
    github.bot_token_cache)       printf '%s/bot-token.json' '$WORK' ;;
    *) [[ \$# -ge 2 ]] && { printf '%s' "\$2"; exit 0; }; exit 2 ;;
esac
STUB
            ;;
        missing_app_id_key)
            cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)                  printf 'default-org/default-repo' ;;
    github.user_login)            printf 'test-user' ;;
    github.bot_app_id)            exit 2 ;;
    github.bot_installation_id)   printf '67890' ;;
    github.bot_pem_path)          printf '%s' '$GOOD_KEY' ;;
    github.bot_token_cache)       printf '%s/bot-token.json' '$WORK' ;;
    *) [[ \$# -ge 2 ]] && { printf '%s' "\$2"; exit 0; }; exit 2 ;;
esac
STUB
            ;;
        missing_pem_file)
            cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)                  printf 'default-org/default-repo' ;;
    github.user_login)            printf 'test-user' ;;
    github.bot_app_id)            printf '12345' ;;
    github.bot_installation_id)   printf '67890' ;;
    github.bot_pem_path)          printf '%s/does-not-exist.pem' '$WORK' ;;
    github.bot_token_cache)       printf '%s/bot-token.json' '$WORK' ;;
    *) [[ \$# -ge 2 ]] && { printf '%s' "\$2"; exit 0; }; exit 2 ;;
esac
STUB
            ;;
        malformed_pem)
            local malformed="$WORK/malformed.pem"
            printf 'not actually a PEM key\n' > "$malformed"
            cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)                  printf 'default-org/default-repo' ;;
    github.user_login)            printf 'test-user' ;;
    github.bot_app_id)            printf '12345' ;;
    github.bot_installation_id)   printf '67890' ;;
    github.bot_pem_path)          printf '%s' '$malformed' ;;
    github.bot_token_cache)       printf '%s/bot-token.json' '$WORK' ;;
    *) [[ \$# -ge 2 ]] && { printf '%s' "\$2"; exit 0; }; exit 2 ;;
esac
STUB
            ;;
        missing_nexus_yml)
            # NEXUS_CONFIG points at a nonexistent file; load.sh is
            # never even consulted by mint-token.sh's _resolve_cfg.
            # Stub still needs to satisfy ng's startup REPO/USER_LOGIN
            # reads, which happen before cmd_mint_jwt fires.
            cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
            ;;
    esac
    chmod +x "$FAKE_NEXUS/config/load.sh"
}

NEUTRAL_CWD="$WORK/neutral"
mkdir -p "$NEUTRAL_CWD"

# Per-test runner. We point NEXUS_CONFIG at $NEXUS_YML so mint-token.sh
# doesn't go shopping in the operator's real ~/.claude/. NEXUS_ROOT is
# also exported so any internal path-anchored logic stays inside the
# fake tree.
run_ng() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    # HOME is re-pinned inside the hermetic env because mint-token.sh
    # references $HOME in the parameter-expansion default for
    # github.bot_token_cache (mint-token.sh:133). Bash evaluates that
    # `$HOME/.claude/...` expression unconditionally — `set -u` then
    # explodes with HOME unbound even when github.bot_token_cache is
    # explicitly configured. Pointing HOME at $WORK keeps mint-token.sh
    # inside the test sandbox without weakening run_hermetic's HOME
    # scrub for the rest of the suite.
    ( cd "$NEUTRAL_CWD" && run_hermetic \
        NEXUS_STATE_DIR="$WORK/state" \
        NEXUS_CONFIG="${MOCK_NEXUS_CONFIG:-$NEXUS_YML}" \
        NEXUS_ROOT="$FAKE_NEXUS" \
        HOME="$WORK" \
        PATH="$PATH" \
        -- "$NG" "$@" ) >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# Decode a base64url segment back to raw bytes. JWT segments lack
# `=` padding, so re-add it before piping into base64 -d.
b64url_decode() {
    local s="$1"
    local pad=$(( (4 - ${#s} % 4) % 4 ))
    while (( pad-- > 0 )); do s+="="; done
    printf '%s' "$s" | tr -- '-_' '+/' | base64 -d 2>/dev/null
}

# ---- Test 1: ng mint-jwt with extra arg → usage / exit 1 -----------------

echo '=== ng mint-jwt <extra> → exit 1 (takes no arguments) ==='
write_load_stub good
run_ng out err rc mint-jwt extra-arg
assert_eq        "exit 1 on extra arg"              "$rc" "1"
assert_contains  "stderr names usage shape"         "$err" "takes no arguments"

# ---- Test 2: --help short-circuits ---------------------------------------

echo '=== ng mint-jwt --help → exit 0, prints usage ==='
write_load_stub good
run_ng out err rc mint-jwt --help
assert_eq        "exit 0 on --help"                 "$rc" "0"
assert_contains  "usage block printed"              "$out" "usage: ng mint-jwt"

# ---- Test 3: missing nexus.yml → cmd_mint_jwt surfaces failure -----------

echo '=== ng mint-jwt with NEXUS_CONFIG pointing at nonexistent file → exit 1 ==='
write_load_stub missing_nexus_yml
MOCK_NEXUS_CONFIG="$WORK/does-not-exist.yml" run_ng out err rc mint-jwt
assert_eq        "exit 1 on missing nexus.yml"      "$rc" "1"
# cmd_mint_jwt's die message OR mint-token.sh's stderr (which leaks
# through). Either is fine — we just need a loud failure.
assert_contains  "stderr blames identity/config"    "$err" "bot identity cannot be obtained"

# ---- Test 4: missing github.bot_app_id key in config → exit 1 ------------

echo '=== ng mint-jwt with github.bot_app_id missing → exit 1 ==='
write_load_stub missing_app_id_key
run_ng out err rc mint-jwt
assert_eq        "exit 1 on missing bot_app_id"     "$rc" "1"
assert_contains  "stderr names the missing key"     "$err" "github.bot_app_id missing"

# ---- Test 5: missing github.bot_pem_path key in config → exit 1 ----------

echo '=== ng mint-jwt with github.bot_pem_path missing → exit 1 ==='
write_load_stub missing_pem_path_key
run_ng out err rc mint-jwt
assert_eq        "exit 1 on missing bot_pem_path"   "$rc" "1"
assert_contains  "stderr names the missing key"     "$err" "github.bot_pem_path missing"

# ---- Test 6: pem path resolves but file is absent → exit 1 ---------------

echo '=== ng mint-jwt with pem path → nonexistent file → exit 1 ==='
write_load_stub missing_pem_file
run_ng out err rc mint-jwt
assert_eq        "exit 1 on missing pem file"       "$rc" "1"
assert_contains  "stderr names pem-file gap"        "$err" "private key not found"

# ---- Test 7: malformed pem file → openssl-signing failure → exit 1 -------

echo '=== ng mint-jwt with malformed pem → exit 1 ==='
write_load_stub malformed_pem
run_ng out err rc mint-jwt
assert_eq        "exit 1 on malformed pem"          "$rc" "1"
# Either mint-token.sh's structured die or cmd_mint_jwt's wrapper die.
# Both go through the same identity-failure message in stderr.
assert_contains  "stderr blames identity/config"    "$err" "bot identity cannot be obtained"

# ---- Test 8: happy path — JWT structure spot-check ------------------------

echo '=== ng mint-jwt happy path → 3-part base64url JWT ==='
write_load_stub good
run_ng out err rc mint-jwt
assert_eq        "exit 0"                           "$rc" "0"
# A single trailing newline from `printf '%s\n'` in cmd_mint_jwt.
# Strip it and split on `.`.
jwt="${out%$'\n'}"
# IFS-split on `.`; expect exactly 3 segments.
IFS='.' read -r -a parts <<<"$jwt"
assert_eq        "JWT has 3 dot-separated parts"    "${#parts[@]}" "3"
# Segments must be base64url (URL-safe alphabet only, no padding).
for i in 0 1 2; do
    part="${parts[$i]}"
    if [[ "$part" =~ ^[A-Za-z0-9_-]+$ ]]; then
        printf '  PASS: segment %d is base64url\n' "$i"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: segment %d is not base64url: %q\n' "$i" "$part" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done
# Decode header → {"alg":"RS256","typ":"JWT"}.
header_json=$(b64url_decode "${parts[0]}")
assert_contains  "header carries alg=RS256"         "$header_json" '"alg":"RS256"'
assert_contains  "header carries typ=JWT"           "$header_json" '"typ":"JWT"'
# Decode payload → must carry iat/exp/iss with iss=12345.
payload_json=$(b64url_decode "${parts[1]}")
assert_contains  "payload carries iss=app_id"       "$payload_json" '"iss":12345'
iat=$(printf '%s' "$payload_json" | jq -r '.iat // empty')
exp=$(printf '%s' "$payload_json" | jq -r '.exp // empty')
if [[ "$iat" =~ ^[0-9]+$ && "$exp" =~ ^[0-9]+$ && $(( exp - iat )) -eq 630 ]]; then
    printf '  PASS: exp-iat = 630s (GitHub max 600 + 30s iat skew)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: exp-iat shape: iat=%q exp=%q\n' "$iat" "$exp" >&2
    FAIL=$(( FAIL + 1 ))
fi
# Signature segment is opaque bytes; just verify non-empty.
sig_bytes=$(b64url_decode "${parts[2]}" | wc -c)
if (( sig_bytes > 0 )); then
    printf '  PASS: signature segment decodes to non-empty bytes (%d)\n' "$sig_bytes"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: signature segment empty\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary ------------------------------------------------------------

th_summary_and_exit
