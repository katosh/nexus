#!/usr/bin/env bash
# Tests for the placeholder-config fail-loud guard
# (your-org/your-nexus#236 B11, broadened per the your-org/nexus-code#311
# operator ask to "explicitly check for some values that should be set to
# a non-placeholder value").
#
# config/nexus.yml is gitignored; a worktree or fresh clone that never
# received it makes config/load.sh fall through to the repo-tracked
# nexus.example.yml, whose required keys hold placeholders
# (github.repo=your-org/..., nexus.root=/path/to/nexus,
# github.bot_app_id=0000000, ...). Before the fix the watcher "started
# clean" against those placeholders: it posted to a non-existent repo AND
# could not mint a bot token (snapshot_github mints every cycle and
# silently skips on failure, so eligible comments never surfaced);
# bootstrap.sh respawned it and filed a misleading "watcher incident"
# instead of a "setup required" signal.
#
# Two detection modes, both keyed off equality with the example template:
#   * --check-identity — the B11 subset: nexus.root, github.repo,
#     github.user_login.
#   * --validate       — the full required set: the identity subset PLUS
#     the bot credentials mint-token.sh needs (github.bot_app_id,
#     github.bot_installation_id, github.bot_pem_path).
#
# Layers under test:
#   A. config/load.sh --check-identity — the identity-subset contract:
#        * placeholder fall-through            → exit 4 (loud)
#        * copied-but-unedited nexus.yml       → exit 4
#        * partial edit (one identity field)   → exit 4
#        * real identity (NEXUS_CONFIG)        → exit 0
#        * real identity via env overrides     → exit 0 (no false positive)
#        * no config file at all               → exit 1, NOT 4
#          (so start-up guards that key on `== 4` don't refuse on the
#           hermetic no-config tmpdirs the other tests build)
#   D. config/load.sh --validate — the full-set contract (#311):
#        * real identity but placeholder bot creds → exit 4, names each
#          bot key (the gap --check-identity alone misses)
#        * fully-real identity + bot creds         → exit 0
#        * placeholder bot creds + real env override → exit 0 (honours
#          NEXUS_BOT_* precedence; no false positive)
#        * real required set + placeholder OPTIONAL keys (notifications.*,
#          bot_login) left untouched               → exit 0 (no overreach)
#        * --check-identity is a strict SUBSET: real identity + placeholder
#          bot creds passes --check-identity but fails --validate
#   B. monitor/watcher/main.sh — refuses to start on a `== 4` verdict.
#   C. monitor/watcher/bootstrap.sh — refuses (and writes NO incident
#        report, calls NO launcher) on a `== 4` verdict.
#
# Run: bash monitor/watcher/test-config-validate-guard.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_src_root=$(cd "$_test_dir/../.." && pwd)
LOAD="$_src_root/config/load.sh"
EXAMPLE="$_src_root/config/nexus.example.yml"

# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Read the live placeholder values straight from the template so this
# test tracks the example file instead of hard-coding sentinels.
ph_repo=$(NEXUS_CONFIG="$EXAMPLE" "$LOAD" github.repo)
ph_root=$(NEXUS_CONFIG="$EXAMPLE" "$LOAD" nexus.root)
ph_app=$(NEXUS_CONFIG="$EXAMPLE" "$LOAD" github.bot_app_id)
ph_inst=$(NEXUS_CONFIG="$EXAMPLE" "$LOAD" github.bot_installation_id)

# Build a nexus.yml from the example with the three IDENTITY fields made
# real (bot creds left as placeholders). $1 = dest path, $2 = nexus.root.
write_real_identity() {
    sed -e "s#repo: ${ph_repo}#repo: real-org/real-assets#" \
        -e 's#user_login: <your-github-username>#user_login: realuser#' \
        -e "s#root: ${ph_root}#root: ${2}#" "$EXAMPLE" > "$1"
}

# Build a nexus.yml with identity AND bot credentials all made real.
# $1 = dest path, $2 = nexus.root.
write_fully_real() {
    write_real_identity "$1" "$2"
    sed -i \
        -e "s#bot_app_id: ${ph_app}#bot_app_id: 1234567#" \
        -e "s#bot_installation_id: ${ph_inst}#bot_installation_id: 87654321#" \
        -e 's#bot_pem_path: ~/.claude/your-bot.pem#bot_pem_path: ~/.claude/real-bot.pem#' \
        "$1"
}

echo '=== A. config/load.sh --check-identity (identity subset) contract ==='

# A1: placeholder fall-through. A clone whose config dir has ONLY the
# example template (no nexus.yml) and no NEXUS_ROOT/NEXUS_CONFIG env.
a1=$WORK/a1; mkdir -p "$a1/config"; cp "$EXAMPLE" "$a1/config/nexus.example.yml"
rc=0; env -u NEXUS_ROOT -u NEXUS_CONFIG NEXUS_ROOT="$a1" "$LOAD" --check-identity >/dev/null 2>&1 || rc=$?
assert_eq "placeholder fall-through → exit 4" "$rc" "4"

# A2: copied-but-unedited nexus.yml (identical to the example). Pin
# NEXUS_ROOT so the nexus.root field isn't masked by an env override.
a2=$WORK/a2; mkdir -p "$a2/config"
cp "$EXAMPLE" "$a2/config/nexus.example.yml"; cp "$EXAMPLE" "$a2/config/nexus.yml"
rc=0; env -u MONITOR_REPO -u MONITOR_USER_LOGIN NEXUS_ROOT="$a2" "$LOAD" --check-identity >/dev/null 2>&1 || rc=$?
assert_eq "copied-but-unedited nexus.yml → exit 4" "$rc" "4"

# A3: partial edit — github.repo fixed, github.user_login still a
# placeholder. Must still refuse.
a3=$WORK/a3; mkdir -p "$a3/config"; cp "$EXAMPLE" "$a3/config/nexus.example.yml"
sed "s#repo: ${ph_repo}#repo: real-org/real-assets#" "$EXAMPLE" > "$a3/config/nexus.yml"
rc=0; env -u MONITOR_REPO -u MONITOR_USER_LOGIN NEXUS_ROOT="$a3" "$LOAD" --check-identity >/dev/null 2>&1 || rc=$?
assert_eq "partial edit (one placeholder left) → exit 4" "$rc" "4"

# A4: a real, fully-edited (identity) nexus.yml → clean.
a4=$WORK/a4; mkdir -p "$a4/config"; cp "$EXAMPLE" "$a4/config/nexus.example.yml"
write_real_identity "$a4/config/nexus.yml" "$a4"
rc=0; env -u MONITOR_REPO -u MONITOR_USER_LOGIN NEXUS_ROOT="$a4" "$LOAD" --check-identity >/dev/null 2>&1 || rc=$?
assert_eq "real (identity) nexus.yml → exit 0" "$rc" "0"

# A5: placeholder config BUT real identity supplied via the documented
# env overrides — no false positive (mirrors the watcher's own
# env-over-config precedence).
a5=$WORK/a5; mkdir -p "$a5/config"; cp "$EXAMPLE" "$a5/config/nexus.example.yml"
rc=0; env MONITOR_REPO=real-org/real-assets MONITOR_USER_LOGIN=realuser NEXUS_ROOT="$a5" \
    "$LOAD" --check-identity >/dev/null 2>&1 || rc=$?
assert_eq "placeholder config + real env overrides → exit 0" "$rc" "0"

# A6: no config file at all (not even the example) → exit 1, NOT 4. The
# start-up guards key on `== 4`, so this must NOT read as a placeholder
# verdict — it is what lets the hermetic no-config test tmpdirs pass.
a6=$WORK/a6; mkdir -p "$a6/config"
rc=0; env -u NEXUS_CONFIG NEXUS_ROOT="$a6" "$LOAD" --check-identity >/dev/null 2>&1 || rc=$?
assert_eq "no config file at all → exit 1 (not 4)" "$rc" "1"

# A7: the refusal message is actionable (names the offending key + the fix).
msg=$(env -u NEXUS_CONFIG NEXUS_ROOT="$a1" "$LOAD" --check-identity 2>&1 || true)
assert_contains "refusal names github.repo" "$msg" "github.repo"
assert_contains "refusal points at config/nexus.yml" "$msg" "config/nexus.yml"

echo '=== D. config/load.sh --validate (full required set; #311) ==='

# D1: identity is real but the bot credentials are still placeholders —
# the exact gap --check-identity alone misses. --validate must refuse and
# name each offending bot key + the file.
d1=$WORK/d1; mkdir -p "$d1/config"; cp "$EXAMPLE" "$d1/config/nexus.example.yml"
write_real_identity "$d1/config/nexus.yml" "$d1"
rc=0
msg=$(env -u MONITOR_REPO -u MONITOR_USER_LOGIN \
    -u NEXUS_BOT_APP_ID -u NEXUS_BOT_INSTALLATION_ID -u NEXUS_BOT_PRIVATE_KEY_PATH \
    NEXUS_ROOT="$d1" "$LOAD" --validate 2>&1) || rc=$?
assert_eq "real identity + placeholder bot creds → --validate exit 4" "$rc" "4"
assert_contains "--validate names github.bot_app_id" "$msg" "github.bot_app_id"
assert_contains "--validate names github.bot_installation_id" "$msg" "github.bot_installation_id"
assert_contains "--validate names github.bot_pem_path" "$msg" "github.bot_pem_path"
assert_contains "--validate gives an actionable remedy" "$msg" "mint-token"

# D1b: the SAME config passes --check-identity — proving the modes are a
# strict subset relationship (identity ok, bot creds not yet checked).
rc=0; env -u MONITOR_REPO -u MONITOR_USER_LOGIN NEXUS_ROOT="$d1" \
    "$LOAD" --check-identity >/dev/null 2>&1 || rc=$?
assert_eq "same config: --check-identity passes (subset) → exit 0" "$rc" "0"

# D2: a fully-real nexus.yml (identity + bot creds) → clean under --validate.
d2=$WORK/d2; mkdir -p "$d2/config"; cp "$EXAMPLE" "$d2/config/nexus.example.yml"
write_fully_real "$d2/config/nexus.yml" "$d2"
rc=0; env -u MONITOR_REPO -u MONITOR_USER_LOGIN \
    -u NEXUS_BOT_APP_ID -u NEXUS_BOT_INSTALLATION_ID -u NEXUS_BOT_PRIVATE_KEY_PATH \
    NEXUS_ROOT="$d2" "$LOAD" --validate >/dev/null 2>&1 || rc=$?
assert_eq "fully-real config → --validate exit 0" "$rc" "0"

# D3: placeholder bot creds in the file BUT real values via the documented
# NEXUS_BOT_* env overrides — no false positive (mirrors mint-token.sh's
# own env-over-config precedence). Identity comes via env too.
d3=$WORK/d3; mkdir -p "$d3/config"; cp "$EXAMPLE" "$d3/config/nexus.example.yml"
rc=0; env MONITOR_REPO=real-org/real-assets MONITOR_USER_LOGIN=realuser NEXUS_ROOT="$d3" \
    NEXUS_BOT_APP_ID=1234567 NEXUS_BOT_INSTALLATION_ID=87654321 \
    NEXUS_BOT_PRIVATE_KEY_PATH=~/.claude/real-bot.pem \
    "$LOAD" --validate >/dev/null 2>&1 || rc=$?
assert_eq "placeholder bot creds + real NEXUS_BOT_* env → --validate exit 0" "$rc" "0"

# D4: no overreach. The required set is real, but OPTIONAL keys that ship
# as placeholders (notifications.email.address, github.bot_login,
# github.bot_webhook_url) are left UNTOUCHED. These degrade gracefully or
# carry documented fallbacks, so --validate must NOT demand real values.
d4=$WORK/d4; mkdir -p "$d4/config"; cp "$EXAMPLE" "$d4/config/nexus.example.yml"
write_fully_real "$d4/config/nexus.yml" "$d4"   # optional keys stay placeholder
rc=0; env -u MONITOR_REPO -u MONITOR_USER_LOGIN \
    -u NEXUS_BOT_APP_ID -u NEXUS_BOT_INSTALLATION_ID -u NEXUS_BOT_PRIVATE_KEY_PATH \
    NEXUS_ROOT="$d4" "$LOAD" --validate >/dev/null 2>&1 || rc=$?
assert_eq "real required set + placeholder OPTIONAL keys → --validate exit 0" "$rc" "0"

# D5: a present-but-EMPTY required key is "not set to a real value" just as
# much as a leftover placeholder, so --validate must refuse and name it.
# (Closes the skeptic's #311 CONCERN; a real config never has this, so
# there is no false-positive risk.) Identity made real except github.repo,
# which is blanked to "".
d5=$WORK/d5; mkdir -p "$d5/config"; cp "$EXAMPLE" "$d5/config/nexus.example.yml"
write_fully_real "$d5/config/nexus.yml" "$d5"
sed -i 's#^  repo: real-org/real-assets#  repo: ""#' "$d5/config/nexus.yml"
rc=0
msg=$(env -u MONITOR_REPO -u MONITOR_USER_LOGIN \
    -u NEXUS_BOT_APP_ID -u NEXUS_BOT_INSTALLATION_ID -u NEXUS_BOT_PRIVATE_KEY_PATH \
    NEXUS_ROOT="$d5" "$LOAD" --validate 2>&1) || rc=$?
assert_eq "present-but-empty required key → --validate exit 4" "$rc" "4"
assert_contains "empty-key refusal names github.repo" "$msg" "github.repo"
assert_contains "empty-key refusal marks it (empty)" "$msg" "(empty)"

# D6: an entirely-ABSENT required key (line removed, no env override) is
# left alone — the legitimately-absent + defaulted boundary. Removing
# github.user_login while the rest is real must NOT trip --validate.
d6=$WORK/d6; mkdir -p "$d6/config"; cp "$EXAMPLE" "$d6/config/nexus.example.yml"
write_fully_real "$d6/config/nexus.yml" "$d6"
sed -i '/^  user_login: realuser$/d' "$d6/config/nexus.yml"
rc=0; env -u MONITOR_REPO -u MONITOR_USER_LOGIN \
    -u NEXUS_BOT_APP_ID -u NEXUS_BOT_INSTALLATION_ID -u NEXUS_BOT_PRIVATE_KEY_PATH \
    NEXUS_ROOT="$d6" "$LOAD" --validate >/dev/null 2>&1 || rc=$?
assert_eq "absent (removed) required key → --validate exit 0 (defaulted boundary)" "$rc" "0"

echo '=== B. main.sh refuses to start on a placeholder (exit-4) verdict ==='

# Mirror the watcher tree so main.sh resolves its `source` lines and
# its $_cfg = $_monitor_dir/../config/load.sh path inside the fixture
# (same approach as test-pidfile-early-publish.sh). Stub config/load.sh
# to return the placeholder verdict (exit 4) for --validate and a
# harmless default for every other key.
BROOT="$WORK/main-tree"
mkdir -p "$BROOT/monitor/watcher" "$BROOT/config" "$BROOT/monitor/.state" "$WORK/bin"
cp "$_test_dir"/*.sh "$BROOT/monitor/watcher/"
cp "$_src_root/monitor/_cc-version.sh" "$BROOT/monitor/" 2>/dev/null || true
chmod +x "$BROOT/monitor/watcher/main.sh"
cat > "$BROOT/config/load.sh" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    --validate|--check-identity)
        echo "load.sh: REFUSING — placeholder config (test stub)" >&2
        exit 4 ;;
    nexus.root) printf '%s\n' "$BROOT"; exit 0 ;;
    *) printf '%s\n' "\${2:-}"; exit 0 ;;
esac
EOF
chmod +x "$BROOT/config/load.sh"
# Inert tmux/gh so any path that would run if the guard regressed is
# harmless (the guard should exit before any of it).
printf '#!/bin/bash\nexit 0\n' > "$WORK/bin/tmux"
printf '#!/bin/bash\necho "{}"\n'  > "$WORK/bin/gh"
chmod +x "$WORK/bin/tmux" "$WORK/bin/gh"

main_out=$(PATH="$WORK/bin:$PATH" NEXUS_ROOT="$BROOT" MONITOR_TARGET=nonexistent \
    timeout 25 bash "$BROOT/monitor/watcher/main.sh" --once 2>&1)
main_rc=$?
assert_eq "main.sh exits 1 on placeholder verdict" "$main_rc" "1"
assert_contains "main.sh prints its REFUSING-to-start message" "$main_out" \
    "REFUSING to start — nexus config is unconfigured"

echo '=== C. bootstrap.sh refuses + writes no incident report ==='

# Real bootstrap.sh, NEXUS_ROOT pinned to a fixture that has ONLY the
# example template. bootstrap's $_cfg is the REAL config/load.sh, which
# (inheriting NEXUS_ROOT) resolves the fixture's example → exit 4.
CROOT="$WORK/boot-tree"
mkdir -p "$CROOT/config" "$CROOT/monitor/.state" "$CROOT/reports"
cp "$EXAMPLE" "$CROOT/config/nexus.example.yml"
# Stub launcher so a regression can't spawn a real watcher.
STUB_LAUNCHER="$WORK/stub-launcher.sh"
printf '#!/usr/bin/env bash\necho launched >> "%s"\n' "$WORK/launcher.calls" > "$STUB_LAUNCHER"
chmod +x "$STUB_LAUNCHER"
: > "$WORK/launcher.calls"

boot_out=$(NEXUS_ROOT="$CROOT" NEXUS_STATE_DIR="$CROOT/monitor/.state" \
    BOOTSTRAP_LAUNCHER_BIN="$STUB_LAUNCHER" \
    timeout 25 bash "$_test_dir/bootstrap.sh" 2>&1)
boot_rc=$?
assert_eq "bootstrap.sh exits 1 on placeholder verdict" "$boot_rc" "1"
assert_contains "bootstrap.sh prints its REFUSING message" "$boot_out" \
    "REFUSING — nexus config is unconfigured"
# The whole point of the bootstrap guard: no misleading incident report,
# no respawn of a doomed watcher.
incident_count=$(find "$CROOT/reports" -name '*watcher-incident.md' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "bootstrap.sh writes NO watcher-incident report" "$incident_count" "0"
assert_eq "bootstrap.sh calls NO launcher" "$(cat "$WORK/launcher.calls")" ""

th_summary_and_exit
