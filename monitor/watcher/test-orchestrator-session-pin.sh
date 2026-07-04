#!/usr/bin/env bash
# Unit tests for monitor/hooks/orchestrator-session-pin.sh — the
# UserPromptSubmit hook that records the orchestrator's session-id
# to monitor/.state/orchestrator-session-id, consumed by
# monitor/watcher/entry.sh's resume path.
#
# Strategy: feed the hook a synthetic Claude Code hook payload on
# stdin against a temporary NEXUS_ROOT, then assert on the pinned
# file's contents.
#
# Covers:
#   1. Canonical UUID payload → pin written verbatim.
#   2. Atomic rewrite — second invocation with a different SID replaces.
#   3. Empty session_id → pin untouched (no clobber of last-good).
#   4. Malformed session_id → pin untouched.
#   5. Missing session_id field → pin untouched.
#   6. NEXUS_ROOT unset → falls back to script-relative resolution.
#
# Run directly: ./monitor/watcher/test-orchestrator-session-pin.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$_test_dir/../hooks/orchestrator-session-pin.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

make_root() {
    local root
    root=$(mktemp -d)
    mkdir -p "$root/monitor/.state" "$root/monitor/hooks"
    cp "$HOOK" "$root/monitor/hooks/orchestrator-session-pin.sh"
    chmod +x "$root/monitor/hooks/orchestrator-session-pin.sh"
    echo "$root"
}

run_hook() {
    local root="$1" payload="$2"
    NEXUS_ROOT="$root" \
        bash "$root/monitor/hooks/orchestrator-session-pin.sh" <<<"$payload"
}

# Read the pinned session-id (newline-stripped). Uses `read -r < file`
# rather than `$(<file)` — the latter returns empty inside `$(...)`
# command substitution under bash 4.4 + `set -uo pipefail` even when
# the file exists with the expected bytes (`ls -la` confirms 37 bytes;
# `$(<file)` returns ''). The read loop is robust and explicit.
read_pin() {
    local f="$1/monitor/.state/orchestrator-session-id"
    if [[ -f "$f" ]]; then
        IFS= read -r line < "$f" || true
        printf '%s' "$line"
    else
        printf 'MISSING'
    fi
}

# --- 1: canonical UUID payload → pin written ------------------------------

ROOT=$(make_root)
SID="7234e315-5847-480c-a3d8-71478c6dc271"
payload='{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'","prompt":"hi"}'
run_hook "$ROOT" "$payload"
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID" ]]; then
    pass "canonical UUID payload → pin file holds session-id"
else
    fail "canonical UUID: pinned='$pinned' expected='$SID'"
fi
rm -rf "$ROOT"

# --- 2: rewrite — newer SID replaces prior -------------------------------

ROOT=$(make_root)
SID1="11111111-1111-1111-1111-111111111111"
SID2="22222222-2222-2222-2222-222222222222"
run_hook "$ROOT" '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID1"'"}'
run_hook "$ROOT" '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID2"'"}'
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID2" ]]; then
    pass "rewrite: second-invocation SID replaces first"
else
    fail "rewrite: pinned='$pinned' expected='$SID2'"
fi
rm -rf "$ROOT"

# --- 3: empty session_id → pin untouched ---------------------------------

ROOT=$(make_root)
SID_GOOD="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
run_hook "$ROOT" '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID_GOOD"'"}'
# Now feed an empty session_id — must NOT clobber the good pin.
run_hook "$ROOT" '{"hook_event_name":"UserPromptSubmit","session_id":""}'
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID_GOOD" ]]; then
    pass "empty session_id → last-good pin preserved (no clobber)"
else
    fail "empty session_id clobbered pin: '$pinned' expected='$SID_GOOD'"
fi
rm -rf "$ROOT"

# --- 4: malformed session_id → pin untouched -----------------------------

ROOT=$(make_root)
run_hook "$ROOT" '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID_GOOD"'"}'
# Garbage SID — not a UUID. Hook must reject.
run_hook "$ROOT" '{"hook_event_name":"UserPromptSubmit","session_id":"not-a-uuid"}'
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID_GOOD" ]]; then
    pass "malformed session_id → last-good pin preserved"
else
    fail "malformed session_id clobbered: '$pinned' expected='$SID_GOOD'"
fi
rm -rf "$ROOT"

# --- 5: missing session_id field → pin untouched -------------------------

ROOT=$(make_root)
run_hook "$ROOT" '{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID_GOOD"'"}'
# Payload without session_id at all.
run_hook "$ROOT" '{"hook_event_name":"UserPromptSubmit","prompt":"orphan"}'
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID_GOOD" ]]; then
    pass "missing session_id field → last-good pin preserved"
else
    fail "missing session_id clobbered: '$pinned' expected='$SID_GOOD'"
fi
rm -rf "$ROOT"

# --- 6: self-rename to "orchestrator" + automatic-rename off ----------
# When TMUX_PANE is set and tmux is available, the hook should invoke
#   tmux rename-window -t "$TMUX_PANE" orchestrator
#   tmux set-window-option -t "$TMUX_PANE" automatic-rename off
# These calls must be best-effort — failures must not block the hook.

ROOT=$(make_root)
# Stub tmux: log every invocation, exit 0.
STUB_BIN=$(mktemp -d)
trap 'rm -rf "$STUB_BIN"' EXIT
TMUX_LOG="$ROOT/tmux-calls.log"
cat > "$STUB_BIN/tmux" <<EOF
#!/usr/bin/env bash
printf 'tmux %s\n' "\$*" >> "$TMUX_LOG"
exit 0
EOF
chmod +x "$STUB_BIN/tmux"
: > "$TMUX_LOG"

SID="44444444-5555-6666-7777-888888888888"
PATH="$STUB_BIN:$PATH" TMUX_PANE="%99" NEXUS_ROOT="$ROOT" \
    NEXUS_IS_ORCHESTRATOR=1 \
    bash "$ROOT/monitor/hooks/orchestrator-session-pin.sh" \
    <<<'{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'"}'

calls=$(<"$TMUX_LOG")
if grep -qF 'rename-window -t %99 orchestrator' <<<"$calls"; then
    pass "self-rename: hook runs tmux rename-window -t \$TMUX_PANE orchestrator"
else
    fail "self-rename: rename-window not invoked. calls: $calls"
fi
if grep -qF 'set-window-option -t %99 automatic-rename off' <<<"$calls"; then
    pass "self-rename: hook disables tmux automatic-rename on the pane"
else
    fail "self-rename: automatic-rename off not invoked. calls: $calls"
fi
if grep -qF 'set-window-option -t %99 allow-rename off' <<<"$calls"; then
    pass "self-rename: hook disables tmux allow-rename on the pane (issue 209 hardening)"
else
    fail "self-rename: allow-rename off not invoked. calls: $calls"
fi
# Pin must still land on this path — rename is additive, never gates the pin.
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID" ]]; then
    pass "self-rename path: pin still written"
else
    fail "self-rename path: pin missing: '$pinned' expected='$SID'"
fi
rm -rf "$ROOT"

# --- 6b: self-rename follows NEXUS_ORCHESTRATOR_WINDOW ----------------
# Configurable-target plumbing: when the orchestrator's launch path
# exported NEXUS_ORCHESTRATOR_WINDOW (the watcher's configured
# target_window), the hook must rename to THAT, not to the hardcoded
# "orchestrator". A mismatch here is the issue-209 crash-loop: the
# watcher polls for its configured window while the hook keeps
# renaming it away.

ROOT=$(make_root)
TMUX_LOG="$ROOT/tmux-calls.log"
cat > "$STUB_BIN/tmux" <<EOF
#!/usr/bin/env bash
printf 'tmux %s\n' "\$*" >> "$TMUX_LOG"
exit 0
EOF
chmod +x "$STUB_BIN/tmux"
: > "$TMUX_LOG"

SID="55555555-6666-7777-8888-999999999999"
PATH="$STUB_BIN:$PATH" TMUX_PANE="%99" NEXUS_ROOT="$ROOT" \
    NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCHESTRATOR_WINDOW="mission-control" \
    bash "$ROOT/monitor/hooks/orchestrator-session-pin.sh" \
    <<<'{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'"}'

calls=$(<"$TMUX_LOG")
if grep -qF 'rename-window -t %99 mission-control' <<<"$calls"; then
    pass "configured-target rename: hook renames to \$NEXUS_ORCHESTRATOR_WINDOW"
else
    fail "configured-target rename: expected rename to mission-control. calls: $calls"
fi
if grep -qF 'rename-window -t %99 orchestrator' <<<"$calls"; then
    fail "configured-target rename: hook still renamed to hardcoded 'orchestrator'. calls: $calls"
else
    pass "configured-target rename: no rename to the hardcoded 'orchestrator'"
fi
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID" ]]; then
    pass "configured-target rename path: pin still written"
else
    fail "configured-target rename path: pin missing: '$pinned' expected='$SID'"
fi
rm -rf "$ROOT"

# --- 7: rename failure does not block the hook ------------------------
# If tmux is missing or rename fails, the hook must still exit 0 and
# still write the pin (hot-path discipline).

ROOT=$(make_root)
FAIL_STUB=$(mktemp -d)
cat > "$FAIL_STUB/tmux" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAIL_STUB/tmux"
SID="55555555-6666-7777-8888-999999999999"
rc=0
PATH="$FAIL_STUB:$PATH" TMUX_PANE="%88" NEXUS_ROOT="$ROOT" \
    NEXUS_IS_ORCHESTRATOR=1 \
    bash "$ROOT/monitor/hooks/orchestrator-session-pin.sh" \
    <<<'{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'"}' \
    || rc=$?
if (( rc == 0 )); then
    pass "rename failure: hook exits 0 (non-blocking)"
else
    fail "rename failure: hook returned rc=$rc"
fi
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID" ]]; then
    pass "rename failure: pin still written"
else
    fail "rename failure: pin missing: '$pinned' expected='$SID'"
fi
rm -rf "$ROOT" "$FAIL_STUB"

# --- 8: rename SUPPRESSED when NEXUS_IS_ORCHESTRATOR unset ----------
# Critical regression: ensure the gate actually gates. If TMUX_PANE +
# tmux are present but NEXUS_IS_ORCHESTRATOR is absent (or != "1"),
# the hook must NOT invoke any tmux rename / set-window-option call.
# Pre-fix incident: a worker pane got renamed during this very test.

ROOT=$(make_root)
GATE_STUB=$(mktemp -d)
GATE_LOG="$ROOT/tmux-calls-gate.log"
cat > "$GATE_STUB/tmux" <<EOF
#!/usr/bin/env bash
printf 'tmux %s\n' "\$*" >> "$GATE_LOG"
exit 0
EOF
chmod +x "$GATE_STUB/tmux"
: > "$GATE_LOG"

SID="66666666-7777-8888-9999-aaaaaaaaaaaa"
# NEXUS_IS_ORCHESTRATOR deliberately unset.
PATH="$GATE_STUB:$PATH" TMUX_PANE="%77" NEXUS_ROOT="$ROOT" \
    bash "$ROOT/monitor/hooks/orchestrator-session-pin.sh" \
    <<<'{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'"}'

calls=$(<"$GATE_LOG")
if [[ -z "$calls" ]]; then
    pass "gate: NEXUS_IS_ORCHESTRATOR unset → zero tmux calls"
else
    fail "gate: rename fired without marker. calls: $calls"
fi
# Pin must still be written — gating only affects the rename, not the pin.
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID" ]]; then
    pass "gate: pin still written when marker absent"
else
    fail "gate: pin missing without marker: '$pinned' expected='$SID'"
fi

# Also verify NEXUS_IS_ORCHESTRATOR set to a non-"1" value is treated
# as absent. Defensive: prevents accidental truthy values (e.g., "0",
# "false") from enabling the rename.
: > "$GATE_LOG"
PATH="$GATE_STUB:$PATH" TMUX_PANE="%77" NEXUS_ROOT="$ROOT" \
    NEXUS_IS_ORCHESTRATOR=0 \
    bash "$ROOT/monitor/hooks/orchestrator-session-pin.sh" \
    <<<'{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'"}'
calls=$(<"$GATE_LOG")
if [[ -z "$calls" ]]; then
    pass "gate: NEXUS_IS_ORCHESTRATOR=0 → zero tmux calls (only \"1\" enables)"
else
    fail "gate: rename fired on NEXUS_IS_ORCHESTRATOR=0. calls: $calls"
fi
rm -rf "$ROOT" "$GATE_STUB"

# --- 9: NEXUS_ROOT unset → script-relative fallback ----------------------
# The hook resolves $root via NEXUS_ROOT first, then falls back to
# `cd <script-dir>/../..`. Verify the fallback by running without
# NEXUS_ROOT and confirming the pin lands in the fixture's .state.

ROOT=$(make_root)
SID="33333333-4444-5555-6666-777777777777"
env -u NEXUS_ROOT \
    bash "$ROOT/monitor/hooks/orchestrator-session-pin.sh" \
    <<<'{"hook_event_name":"UserPromptSubmit","session_id":"'"$SID"'"}'
pinned=$(read_pin "$ROOT")
if [[ "$pinned" == "$SID" ]]; then
    pass "NEXUS_ROOT unset → script-relative fallback writes pin"
else
    fail "fallback resolver: pinned='$pinned' expected='$SID'"
fi
rm -rf "$ROOT"

# --- summary -------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
