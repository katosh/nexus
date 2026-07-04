#!/usr/bin/env bash
# Unit tests for `ng preflight <owner/repo>` (cmd_preflight in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-preflight.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: PATH-shadow `gh` so `gh api --paginate /installation/repositories`
# returns a controlled membership list. Drive `ng preflight` and assert
# the stdout / exit code reflect installed-or-not.
#
# Coverage map (from your-org/nexus-code#39):
#   - Required-arg validation.
#   - Target must contain "/" (not just "name").
#   - Target listed in install → "bot installed: yes", exit 0.
#   - Target absent from install → "bot installed: NO", exit 1.
#   - Bot name in error message respects the github.bot_git_name
#     config key (with the trailing `[bot]` stripped).

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

WORK=$(mktemp -d -t nexus-ng-preflight-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"

# config/load.sh stub: honors github.bot_git_name override via env
# so the bot-name assertion can flex without rewriting the stub.
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)                printf 'default-org/default-repo' ;;
    github.user_login)         printf 'test-user' ;;
    github.bot_installation_id) printf '999999' ;;
    github.bot_git_name)
        if [[ -n "${TEST_BOT_NAME:-}" ]]; then
            printf '%s' "$TEST_BOT_NAME"
        else
            # Fall through to load.sh's default-arg semantics.
            [[ $# -ge 2 ]] && { printf '%s' "$2"; exit 0; }
            exit 2
        fi
        ;;
    *) [[ $# -ge 2 ]] && { printf '%s' "$2"; exit 0; }; exit 2 ;;
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

# `gh api --paginate /installation/repositories` returns the wrapper
# object shape that _preflight_repo's jq slurp expects:
#   { total_count, repository_selection, repositories: [{full_name,
#     owner:{login}}, ...] }
#
# $MOCK_INSTALLED  (space-separated owner/name list) controls membership.
# $MOCK_SELECTION  (all|selected; default selected) controls the
#                  repository_selection field cmd_preflight surfaces.
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
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
    /installation/repositories*)
        # Build the JSON array from $MOCK_INSTALLED (space-separated).
        # An empty value yields the empty membership. Each repo carries
        # owner.login (derived from the owner/name split) so cmd_preflight
        # can decide whether to pin the installation id in the URL.
        repos="${MOCK_INSTALLED:-}"
        sel="${MOCK_SELECTION:-selected}"
        printf '{"total_count":0,"repository_selection":"%s","repositories":[' "$sel"
        first=1
        for r in $repos; do
            if (( first )); then first=0; else printf ','; fi
            printf '{"full_name":"%s","owner":{"login":"%s"}}' "$r" "${r%%/*}"
        done
        printf ']}'
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
    env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
        NEXUS_STATE_DIR="$WORK/state" \
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
run_ng out err rc preflight
assert_eq        "no target → exit non-zero"         "$rc" "1"
assert_contains  "stderr mentions usage"             "$err" "usage: ng preflight"

run_ng out err rc preflight bareword
assert_eq        "target without slash → exit non-zero" "$rc" "1"
assert_contains  "stderr explains OWNER/NAME shape"  "$err" "OWNER/NAME"

# ---- Test 2: target installed → yes -------------------------------------

echo '=== target in install list → yes, exit 0 ==='
MOCK_INSTALLED="acme/widget your-org/nexus-code other/repo" \
    run_ng out err rc preflight your-org/nexus-code
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout reports installed"          "$out" "bot installed: yes"
assert_contains  "stdout names the target"           "$out" "your-org/nexus-code"

# ---- Test 3: target absent → NO -----------------------------------------

echo '=== target absent from install list → NO, exit 1 ==='
MOCK_INSTALLED="acme/widget other/repo" \
    run_ng out err rc preflight your-org/nexus-code
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stdout reports NOT installed"      "$out" "bot installed: NO"
assert_contains  "stdout names install action"       "$out" "ask org admin"
assert_contains  "stdout names the target"           "$out" "your-org/nexus-code"

# Default bot name comes from the load.sh default-arg fallback
# (`the nexus bot`), since we didn't pin TEST_BOT_NAME.
assert_contains  "stdout uses default bot name"      "$out" "the nexus bot"

# ---- Test 4: empty install list → NO ------------------------------------

echo '=== empty install list → NO ==='
MOCK_INSTALLED="" run_ng out err rc preflight your-org/nexus-code
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stdout reports NOT installed"      "$out" "bot installed: NO"

# ---- Test 5: custom bot name + [bot] suffix stripping -------------------

echo '=== github.bot_git_name "[bot]" suffix stripped ==='
TEST_BOT_NAME="nexus-bot-test[bot]" MOCK_INSTALLED="other/repo" \
    run_ng out err rc preflight your-org/nexus-code
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stdout uses configured bot name"   "$out" "nexus-bot-test"
assert_not_contains "no '[bot]' suffix in stdout"    "$out" "[bot]"

# ---- Test 6: repository_selection surfaced on YES -----------------------
# (B5, your-org/your-nexus#236 — preflight must report scope, not just
#  yes/no. Fails on pre-fix cmd_preflight, which printed neither the
#  selection nor a URL.)

echo '=== repository_selection surfaced on installed (yes) ==='
MOCK_SELECTION="all" MOCK_INSTALLED="your-org/nexus-code other/repo" \
    run_ng out err rc preflight your-org/nexus-code
assert_eq        "exit 0"                            "$rc" "0"
assert_contains  "stdout reports installed"          "$out" "bot installed: yes"
assert_contains  "stdout surfaces repository_selection=all" "$out" "repository_selection=all"

# ---- Test 7: repository_selection surfaced on NO ------------------------

echo '=== repository_selection surfaced on absent (NO) ==='
MOCK_SELECTION="selected" MOCK_INSTALLED="your-org/other" \
    run_ng out err rc preflight your-org/nexus-code
assert_eq        "exit 1"                            "$rc" "1"
assert_contains  "stdout reports NOT installed"      "$out" "bot installed: NO"
assert_contains  "stdout surfaces repository_selection=selected" "$out" "repository_selection=selected"

# ---- Test 8: install URL pinned to the installation id when the bot's
#              install lives under the target owner ----------------------

echo '=== absent repo, owner matches install → id-pinned management URL ==='
# your-org/other is visible → install lives under your-org → URL pins id.
MOCK_SELECTION="selected" MOCK_INSTALLED="your-org/other" \
    run_ng out err rc preflight your-org/nexus-code
assert_contains  "stdout prints org-settings URL"    "$out" \
    "https://github.com/organizations/your-org/settings/installations/999999"

# ---- Test 9: install URL falls back to the list page when no visible
#              repo is owned by the target owner (stale id would 404) ----

echo '=== absent repo, owner does NOT match install → list-page URL ==='
# Only acme/widget visible → install is NOT under your-org → no id pin.
MOCK_SELECTION="selected" MOCK_INSTALLED="acme/widget" \
    run_ng out err rc preflight your-org/nexus-code
assert_contains     "stdout prints org installations list URL" "$out" \
    "https://github.com/organizations/your-org/settings/installations"
assert_not_contains "no stale id pinned under wrong org"       "$out" \
    "installations/999999"

# ---- summary ------------------------------------------------------------

th_summary_and_exit
