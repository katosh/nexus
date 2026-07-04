#!/usr/bin/env bash
# Unit tests for `monitor/ng`'s STATE_DIR resolver.
#
# Run: bash monitor/watcher/test-ng-state-dir.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Background: prior to this fix `ng` resolved STATE_DIR as
# `$_script_dir/.state` unconditionally. A worker that ran
# `monitor/ng wrap-up` from a worktree's copy of the script
# wrote the action-log to the worktree's `.state/`, never to
# the primary clone's `.state/` where the watcher reads.
#
# The resolver's precedence (most-specific first):
#   1. NEXUS_STATE_DIR     direct path; test escape hatch.
#   2. NEXUS_ROOT          `<root>/monitor/.state`.
#   3. config nexus.root   `<root>/monitor/.state`.
#   4. $_script_dir/.state script-relative fallback.
#
# Strategy: build a minimal nexus tree, drive `ng log-action`
# (which writes to STATE_DIR/action-log.jsonl), then assert
# the log file landed at the expected path.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_not_exists() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — unexpected file exists: %s\n' "$label" "$path" >&2; FAIL=$(( FAIL + 1 )); fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Worktree-shape copy: mirrors a worker's clone where
# `monitor/ng` is under `work/<project>/monitor/`.
WORKTREE="$WORK/worktree"
mkdir -p "$WORKTREE/monitor" "$WORKTREE/config"
cp "$NG_REAL" "$WORKTREE/monitor/ng"
WORKTREE_NG="$WORKTREE/monitor/ng"

# Primary-clone-shape: where the watcher reads from. Has its
# own `monitor/.state/` that wrap-ups should land in by default
# under the new resolver (precedence 3).
PRIMARY="$WORK/primary"
mkdir -p "$PRIMARY/monitor/.state"

# Stub config that points nexus.root at $PRIMARY by default. The
# tests override $TEST_NEXUS_ROOT to flip the value.
cat > "$WORKTREE/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)       printf 'default-org/default-repo' ;;
    github.user_login) printf 'test-user' ;;
    nexus.root)
        if [[ -n "\${TEST_NEXUS_ROOT_KEY:-}" ]]; then
            printf '%s' "\${TEST_NEXUS_ROOT_KEY}"
        else
            # 'no config-key set' branch — exit 2 like load.sh
            # does on missing key with no default supplied.
            exit 2
        fi
        ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$WORKTREE/config/load.sh"

# mint-token stub — log-action doesn't call gh but defensive.
cat > "$WORKTREE/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-token'
STUB
chmod +x "$WORKTREE/monitor/mint-token.sh"

# Drive log-action; returns rc + path to the (presumed) log file
# under each candidate STATE_DIR.
run_log_action() {
    local _env_clause="$1" _rc_var="$2"; shift 2
    local _rc _tmp
    _tmp=$(mktemp)
    eval "$_env_clause $WORKTREE_NG log-action validator --event smoke-test" \
        >"$_tmp" 2>&1
    _rc=$?
    rm -f "$_tmp"
    printf -v "$_rc_var" '%s' "$_rc"
}

# ---- Test 1: NEXUS_STATE_DIR wins (precedence 1) -----------------------

echo '=== NEXUS_STATE_DIR overrides everything (test escape hatch) ==='
ESC_DIR="$WORK/escape-state"
mkdir -p "$ESC_DIR"
run_log_action "env -u NEXUS_ROOT TEST_NEXUS_ROOT_KEY='$PRIMARY' NEXUS_STATE_DIR='$ESC_DIR'" rc
assert_eq         "exit 0"                             "$rc" "0"
assert_file_exists "log lands in NEXUS_STATE_DIR"      "$ESC_DIR/action-log.jsonl"
assert_not_exists "no log in worktree .state/"        "$WORKTREE/monitor/.state/action-log.jsonl"
assert_not_exists "no log in primary nexus.root/.state" "$PRIMARY/monitor/.state/action-log.jsonl"

# ---- Test 2: NEXUS_ROOT env wins over config nexus.root (precedence 2) -

echo '=== NEXUS_ROOT env wins over config nexus.root ==='
ROOT_A="$WORK/root-a"
ROOT_B="$WORK/root-b"
mkdir -p "$ROOT_A/monitor" "$ROOT_B/monitor"
run_log_action "env -u NEXUS_STATE_DIR TEST_NEXUS_ROOT_KEY='$ROOT_B' NEXUS_ROOT='$ROOT_A'" rc
assert_eq         "exit 0"                             "$rc" "0"
assert_file_exists "log lands in NEXUS_ROOT/monitor/.state" \
                  "$ROOT_A/monitor/.state/action-log.jsonl"
assert_not_exists "no log in config-pinned root"      "$ROOT_B/monitor/.state/action-log.jsonl"

# ---- Test 3: config nexus.root used when no env (precedence 3) ---------

echo '=== config nexus.root → <root>/monitor/.state when no env set ==='
# Reset PRIMARY's state-dir for a clean second-run.
rm -rf "$PRIMARY/monitor/.state"
run_log_action "env -u NEXUS_STATE_DIR -u NEXUS_ROOT TEST_NEXUS_ROOT_KEY='$PRIMARY'" rc
assert_eq         "exit 0"                             "$rc" "0"
assert_file_exists "log lands in config-pinned root"  "$PRIMARY/monitor/.state/action-log.jsonl"
assert_not_exists "no log in worktree .state/"        "$WORKTREE/monitor/.state/action-log.jsonl"

# ---- Test 4: script-relative fallback when nothing set (precedence 4) --

echo '=== fallback to $_script_dir/.state when no env + no config key ==='
# Reset worktree's .state for a clean run.
rm -rf "$WORKTREE/monitor/.state"
run_log_action "env -u NEXUS_STATE_DIR -u NEXUS_ROOT -u TEST_NEXUS_ROOT_KEY" rc
assert_eq         "exit 0"                             "$rc" "0"
assert_file_exists "log falls back to worktree .state/" \
                  "$WORKTREE/monitor/.state/action-log.jsonl"

# ---- Test 5: real cross-clone smoke — worker writes to primary ---------
#
# Simulates the issue-#108-aftermath scenario: worker invokes the
# worktree's `ng wrap-up` (here approximated by log-action), but
# the entry MUST land in the primary clone's action-log so the
# watcher (which reads only the primary's) sees it.

echo '=== cross-clone smoke: worker `ng` → primary clone .state/ ==='
rm -rf "$PRIMARY/monitor/.state" "$WORKTREE/monitor/.state"
run_log_action "env -u NEXUS_STATE_DIR -u NEXUS_ROOT TEST_NEXUS_ROOT_KEY='$PRIMARY'" rc
assert_eq         "exit 0"                             "$rc" "0"
assert_file_exists "worker entry landed in primary" \
                  "$PRIMARY/monitor/.state/action-log.jsonl"
assert_not_exists "worktree .state/ stays empty" \
                  "$WORKTREE/monitor/.state"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
