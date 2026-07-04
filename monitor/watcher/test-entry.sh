#!/usr/bin/env bash
# Integration tests for monitor/watcher/entry.sh — the user-facing
# entry point, retargeted to the unified headless model (issue 182):
# entry.sh no longer hosts the watcher in a window or spawns claude
# itself. It self-checks, reconciles the operator's fresh-vs-resume
# intent onto the orchestrator session-id pin, delegates stack
# bring-up to `monitor/svc.sh up`, and execs the svc.sh cockpit in
# the invoking window (renamed `services`).
#
# Strategy: for each scenario, set up a fresh temporary nexus root
# with a stub `tmux` and a stub `monitor/svc.sh` on disk, then invoke
# entry.sh directly (not through agent-sandbox). The stubs record
# their arguments to files we assert against; the svc.sh stub's exit
# replaces the real cockpit exec, so the test exits instead of
# entering the dashboard loop.
#
# Covers:
#   1. Missing-tmux self-check fails clearly.
#   2. Missing-sandbox self-check fails clearly.
#   3. Cold start (default): pin archived (fresh intent), svc.sh up
#      invoked with NEXUS_ROOT exported, invoking window renamed to
#      `services`, cockpit exec'd, claude NEVER invoked directly.
#   4. Cold start (default) without a pin: no archive, still boots.
#   5. --continue + valid pin → pin retained; resume messaging names
#      the exact sid.
#   6. --continue + stale pin (no jsonl) → pin retained; fresh-spawn
#      messaging (the watcher never falls back to `claude --continue`).
#   7. --continue without a pin → fresh-spawn messaging.
#   8. Orchestrator window already present (default) → pin untouched,
#      no archive, idempotent bring-up still runs.
#   9. Orchestrator window already present + --continue → "no effect"
#      messaging, pin untouched.
#  10. svc.sh up failure → warning, cockpit still exec'd.
#  11. Legacy `watcher` window present → NOT refused (the launcher
#      sweeps it); bring-up proceeds.
#  12. Rename targets the invoking window by id even when another
#      window is the session-active one.
#
# Run directly: ./monitor/watcher/test-entry.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# --- shared fixture builder ----------------------------------------------

# Build a self-contained fake nexus tree under a temp dir. Returns
# the root path on stdout.
make_fixture() {
    local root
    root=$(mktemp -d)
    mkdir -p "$root/config" "$root/monitor/watcher" "$root/monitor/.state"
    # Copy entry.sh into the fixture (NOT a symlink — entry.sh's
    # `readlink -f "${BASH_SOURCE[0]}"` resolves through symlinks
    # back to the real source, which would break test isolation).
    cp "$_test_dir/entry.sh" "$root/monitor/watcher/entry.sh"
    chmod +x "$root/monitor/watcher/entry.sh"
    # entry.sh sources _respawn.sh for `_respawn_choose_resume_mode`
    # (the pin resolver used for --continue messaging). Copy it so the
    # real resolver is exercised, not the degraded fallback.
    cp "$_test_dir/_respawn.sh" "$root/monitor/watcher/_respawn.sh"
    # entry.sh sources _lib.sh for the wrong-launch guard helpers
    # (issue #203 revision: own-window check + peer-cockpit scan).
    cp "$_test_dir/_lib.sh" "$root/monitor/watcher/_lib.sh"
    # The top-level `./watcher` IS a symlink in the real layout; mirror
    # that. readlink -f resolves it to the fixture's entry.sh.
    ln -s "monitor/watcher/entry.sh" "$root/watcher"
    # Stub config/load.sh: prints the second-arg default, ignoring keys.
    cat > "$root/config/load.sh" <<'CFG'
#!/usr/bin/env bash
key="$1"
default="${2:-}"
case "$key" in
    monitor.target_window)              echo "${TEST_TARGET_WINDOW:-orchestrator}" ;;
    *)                                  echo "$default" ;;
esac
CFG
    chmod +x "$root/config/load.sh"
    # Stub monitor/svc.sh: record every invocation. `up` honours
    # $SVC_UP_RC so a test can simulate bring-up failure; the bare
    # (cockpit) invocation exits 0 — entry.sh exec's it, so its exit
    # code IS entry.sh's.
    cat > "$root/monitor/svc.sh" <<'SVC'
#!/usr/bin/env bash
echo "svc.sh called: ${*:-<cockpit>}" >> "${SVC_LOG:?SVC_LOG required}"
echo "NEXUS_ROOT=${NEXUS_ROOT:-<unset>}" >> "$SVC_LOG"
echo "current-window-name: $(tmux display -p '#{window_name}' 2>/dev/null)" >> "$SVC_LOG"
if [[ "${1:-}" == "up" ]]; then
    exit "${SVC_UP_RC:-0}"
fi
exit 0
SVC
    chmod +x "$root/monitor/svc.sh"
    echo "$root"
}

# Build a stub bin dir with `tmux` and `claude` recorders on PATH.
# State model:
#   $state/tmux-windows.txt    one window name per line (1-indexed)
#   $state/tmux-winids.txt     one window-id per line, parallel to
#                              windows.txt (e.g. '@1','@2',…)
#   $state/tmux-current.txt    single integer: session-active window
#                              index (1-indexed) — what un-targeted
#                              rename-window would hit.
make_stubs() {
    local stubdir="$1" state="$2"
    mkdir -p "$stubdir"
    cat > "$stubdir/tmux" <<'TMUX'
#!/usr/bin/env bash
state="${TMUX_STATE_DIR:?TMUX_STATE_DIR required}"
windows="$state/tmux-windows.txt"
winids="$state/tmux-winids.txt"
current_f="$state/tmux-current.txt"
log="$state/tmux-log.txt"
[[ -f "$windows" ]] || : > "$windows"
echo "tmux $*" >> "$log"

_ensure_winids() {
    if [[ ! -s "$winids" ]] && [[ -s "$windows" ]]; then
        awk '{ printf "@%d\n", NR }' "$windows" > "$winids"
    fi
}
_ensure_current() {
    if [[ ! -s "$current_f" ]]; then echo 1 > "$current_f"; fi
}
# Map a pane id (%0, %1, …) → window index. The fixture only ever
# invokes entry.sh in window 1, so pane %0 is in window 1.
_pane_window_index() {
    local pane="$1"
    case "$pane" in
        %0|"") echo 1 ;;
        %[0-9]*) echo $(( ${pane#%} + 1 )) ;;
        *) echo 1 ;;
    esac
}
_window_index_for_ref() {
    local ref="$1"
    if [[ "$ref" == @* ]]; then
        awk -v want="$ref" '$0 == want { print NR; exit }' "$winids"
    else
        awk -v want="$ref" '$0 == want { print NR; exit }' "$windows"
    fi
}

case "$1" in
    list-windows)
        _ensure_winids
        if [[ "$2" == "-F" && "$3" == '#{window_name}' ]]; then
            cat "$windows"
        else
            awk '{ printf "%d: %s\n", NR, $0 }' "$windows"
        fi
        ;;
    rename-window)
        _ensure_winids; _ensure_current
        ref=""
        shift
        while (( $# > 0 )); do
            case "$1" in
                -t) ref="$2"; shift 2 ;;
                *) new="$1"; shift ;;
            esac
        done
        if [[ -n "$ref" ]]; then
            idx=$(_window_index_for_ref "$ref")
        else
            idx=$(<"$current_f")
        fi
        [[ -z "$idx" ]] && idx=1
        if [[ -s "$windows" ]]; then
            awk -v idx="$idx" -v new="$new" 'NR==idx {print new; next} {print}' "$windows" > "$windows.tmp"
            mv "$windows.tmp" "$windows"
        else
            echo "$new" >> "$windows"
        fi
        ;;
    display|display-message)
        _ensure_winids; _ensure_current
        target=""
        fmt=""
        shift
        while (( $# > 0 )); do
            case "$1" in
                -p) shift ;;
                -t) target="$2"; shift 2 ;;
                *) fmt="$1"; shift ;;
            esac
        done
        if [[ -z "$target" ]]; then
            idx=$(<"$current_f")
        elif [[ "$target" == %* ]]; then
            idx=$(_pane_window_index "$target")
        else
            idx=$(_window_index_for_ref "$target")
        fi
        [[ -z "$idx" ]] && idx=1
        case "$fmt" in
            '#{window_name}') sed -n "${idx}p" "$windows" ;;
            '#{window_id}')   sed -n "${idx}p" "$winids" ;;
            *)                sed -n "${idx}p" "$windows" ;;
        esac
        ;;
    list-panes)
        # Serve a canned pane table (pane_id|pane_pid|window_id|
        # window_name) for the peer-cockpit scan; absent file → no
        # panes (the scan finds nothing and fails open).
        cat "$state/tmux-panes.txt" 2>/dev/null
        ;;
    *) ;;  # ignore anything else (set-window-option, select-window, …)
esac
exit 0
TMUX
    chmod +x "$stubdir/tmux"
    # claude stub: entry.sh must NEVER invoke claude directly anymore
    # (the watcher owns the orchestrator spawn). The stub records any
    # invocation; tests assert the log stays empty.
    cat > "$stubdir/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude $*" >> "${CLAUDE_LOG:?CLAUDE_LOG required}"
exit 0
CLAUDE
    chmod +x "$stubdir/claude"
}

# Run entry.sh in a controlled environment. Captures stdout / stderr /
# exit code into globals: ENTRY_OUT, ENTRY_ERR, ENTRY_RC; state dir in
# ENTRY_STATE_DIR.
run_entry() {
    local root="$1"; shift
    local state="$root/.teststate"
    mkdir -p "$state"
    local stubs="$root/.stubs"
    make_stubs "$stubs" "$state"
    : > "$state/tmux-windows.txt"
    : > "$state/tmux-winids.txt"
    : > "$state/tmux-current.txt"
    if [[ -n "${PRESEED_WINDOWS:-}" ]]; then
        printf '%s\n' $PRESEED_WINDOWS > "$state/tmux-windows.txt"
        awk '{ printf "@%d\n", NR }' "$state/tmux-windows.txt" > "$state/tmux-winids.txt"
        echo "${PRESEED_CURRENT:-1}" > "$state/tmux-current.txt"
    fi
    rm -f "$state/tmux-panes.txt"
    if [[ -n "${PRESEED_PANES:-}" ]]; then
        printf '%s\n' "$PRESEED_PANES" > "$state/tmux-panes.txt"
    fi
    : > "$state/tmux-log.txt"
    local svc_log="$state/svc-log.txt"
    : > "$svc_log"
    local claude_log="$state/claude-log.txt"
    : > "$claude_log"
    set +e
    ENTRY_OUT=$(env -i \
        HOME="$HOME" \
        PATH="$stubs:$PATH" \
        TMUX="${TMUX_OVERRIDE-/tmp/tmux-fake,1234,5}" \
        TMUX_PANE="${TMUX_PANE_OVERRIDE-%0}" \
        SANDBOX_ACTIVE="${SANDBOX_ACTIVE_OVERRIDE-1}" \
        SANDBOX_PROJECT_DIR="${SANDBOX_PROJECT_DIR_OVERRIDE-$root}" \
        TMUX_STATE_DIR="$state" \
        SVC_LOG="$svc_log" \
        SVC_UP_RC="${SVC_UP_RC:-0}" \
        CLAUDE_LOG="$claude_log" \
        TEST_TARGET_WINDOW="${TEST_TARGET_WINDOW:-orchestrator}" \
        bash "$root/watcher" "$@" 2>"$state/stderr.txt")
    ENTRY_RC=$?
    set -e
    ENTRY_ERR=$(<"$state/stderr.txt")
    ENTRY_SVC_LOG=$(<"$svc_log")
    ENTRY_CLAUDE_LOG=$(<"$claude_log")
    ENTRY_STATE_DIR="$state"
}

# --- 1: missing TMUX env --------------------------------------------------

ROOT=$(make_fixture)
TMUX_OVERRIDE="" run_entry "$ROOT"
if (( ENTRY_RC == 2 )) && [[ "$ENTRY_ERR" == *"not running inside a tmux session"* ]]; then
    pass "missing TMUX → rc=2 with helpful error"
else
    fail "missing TMUX: rc=$ENTRY_RC err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 2: out-of-sandbox, no flag, no marker → REFUSE ----------------------
# your-org/nexus-code#350: the sandbox gate fails loud and refuses to
# bring the stack up when there is no kernel-enforced isolation and the
# operator has not opted out. No marker must be written, svc.sh untouched.

ROOT=$(make_fixture)
SANDBOX_ACTIVE_OVERRIDE="" SANDBOX_PROJECT_DIR_OVERRIDE="" run_entry "$ROOT"
if (( ENTRY_RC == 2 )) \
   && [[ "$ENTRY_ERR" == *"REFUSING to start the nexus outside the agent-sandbox"* ]] \
   && [[ "$ENTRY_ERR" == *"--i-accept-no-sandbox"* ]] \
   && [[ ! -f "$ROOT/monitor/.state/no-sandbox-accepted" ]] \
   && [[ "$ENTRY_SVC_LOG" != *"svc.sh called"* ]]; then
    pass "out-of-sandbox, no flag → rc=2 refusal, no marker, no bring-up"
else
    fail "out-of-sandbox refuse: rc=$ENTRY_RC marker=$([[ -f "$ROOT/monitor/.state/no-sandbox-accepted" ]] && echo yes || echo no) svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 2b: out-of-sandbox + --i-accept-no-sandbox → start with WARNING ------
# The explicit opt-out lets the stack come up but warns loudly and
# records the acceptance marker so self-heal relaunches inherit it.

ROOT=$(make_fixture)
SANDBOX_ACTIVE_OVERRIDE="" SANDBOX_PROJECT_DIR_OVERRIDE="" \
    PRESEED_WINDOWS="some-other-window" run_entry "$ROOT" --i-accept-no-sandbox
marker="$ROOT/monitor/.state/no-sandbox-accepted"
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"WARNING — starting OUTSIDE the agent-sandbox"* ]] \
   && [[ -f "$marker" ]] \
   && grep -q '^context: watcher' "$marker" \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: <cockpit>"* ]]; then
    pass "out-of-sandbox + --i-accept-no-sandbox → rc=0, warning, marker recorded, bring-up runs"
else
    fail "out-of-sandbox accept: rc=$ENTRY_RC marker=$([[ -f "$marker" ]] && echo yes || echo no) svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 2c: out-of-sandbox + pre-existing marker (no flag) → start ----------
# A prior acceptance persists: a no-flag start (e.g. a self-heal relaunch
# path that goes through entry.sh) inherits it and proceeds with a warning.

ROOT=$(make_fixture)
printf 'accepted_at: earlier\ncontext: watcher\n' > "$ROOT/monitor/.state/no-sandbox-accepted"
SANDBOX_ACTIVE_OVERRIDE="" SANDBOX_PROJECT_DIR_OVERRIDE="" \
    PRESEED_WINDOWS="some-other-window" run_entry "$ROOT"
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"WARNING — starting OUTSIDE the agent-sandbox"* ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]]; then
    pass "out-of-sandbox + existing marker (no flag) → rc=0, warning, bring-up runs"
else
    fail "out-of-sandbox existing marker: rc=$ENTRY_RC svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 2d: in-sandbox → flag irrelevant, no marker, no warning -------------
# The normal path must see ZERO behaviour change: in-sandbox the gate
# short-circuits before consulting the flag or marker.

ROOT=$(make_fixture)
PRESEED_WINDOWS="some-other-window" run_entry "$ROOT"
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" != *"OUTSIDE the agent-sandbox"* ]] \
   && [[ "$ENTRY_ERR" != *"REFUSING"* ]] \
   && [[ ! -f "$ROOT/monitor/.state/no-sandbox-accepted" ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]]; then
    pass "in-sandbox: gate is a no-op (no warning, no marker), normal bring-up"
else
    fail "in-sandbox no-op: rc=$ENTRY_RC marker=$([[ -f "$ROOT/monitor/.state/no-sandbox-accepted" ]] && echo yes || echo no) err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 3: cold start (default) — pin archived, stack up, cockpit -------------

ROOT=$(make_fixture)
PIN_SID="7234e315-5847-480c-a3d8-71478c6dc271"
printf '%s\n' "$PIN_SID" > "$ROOT/monitor/.state/orchestrator-session-id"
PRESEED_WINDOWS="some-other-window" run_entry "$ROOT"
windows=$(<"$ENTRY_STATE_DIR/tmux-windows.txt")
archived=$(ls "$ROOT/monitor/.state/"orchestrator-session-id.archived.* 2>/dev/null | head -1)
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"fresh boot (default) — archived prior session pin"* ]] \
   && [[ ! -f "$ROOT/monitor/.state/orchestrator-session-id" ]] \
   && [[ -n "$archived" && "$(tr -d '[:space:]' < "$archived")" == "$PIN_SID" ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]] \
   && [[ "$ENTRY_SVC_LOG" == *"NEXUS_ROOT=$ROOT"* ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: <cockpit>"* ]] \
   && [[ "$windows" == "services" ]] \
   && [[ -z "$ENTRY_CLAUDE_LOG" ]]; then
    pass "cold start (default): pin archived (content intact), svc.sh up + cockpit with NEXUS_ROOT, window renamed 'services', claude never invoked"
else
    fail "cold start default: rc=$ENTRY_RC windows='$windows' archived='$archived' svc='$ENTRY_SVC_LOG' claude='$ENTRY_CLAUDE_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 4: cold start (default) without a pin ---------------------------------

ROOT=$(make_fixture)
PRESEED_WINDOWS="some-other-window" run_entry "$ROOT"
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"no prior session pin"* ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: <cockpit>"* ]]; then
    pass "cold start without pin: no archive attempted, stack up + cockpit still run"
else
    fail "cold start no-pin: rc=$ENTRY_RC svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 5: --continue + valid pin → pin retained, resume messaging -----------

ROOT=$(make_fixture)
PIN_SID="7234e315-5847-480c-a3d8-71478c6dc271"
printf '%s\n' "$PIN_SID" > "$ROOT/monitor/.state/orchestrator-session-id"
slug="${ROOT//[^a-zA-Z0-9-]/-}"
proj="$HOME/.claude/projects/$slug"
mkdir -p "$proj"
touch "$proj/$PIN_SID.jsonl"
PRESEED_WINDOWS="some-other-window" run_entry "$ROOT" --continue
pin_after=""
[[ -f "$ROOT/monitor/.state/orchestrator-session-id" ]] \
    && pin_after=$(tr -d '[:space:]' < "$ROOT/monitor/.state/orchestrator-session-id")
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"pin valid; the watcher will resume the pinned session (claude --resume $PIN_SID)"* ]] \
   && [[ "$pin_after" == "$PIN_SID" ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]]; then
    pass "--continue + valid pin: pin retained, resume messaging names the sid"
else
    fail "--continue valid pin: rc=$ENTRY_RC pin_after='$pin_after' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT" "$proj"

# --- 6: --continue + stale pin (jsonl missing) → fresh messaging -----------
# The watcher never falls back to `claude --continue` (issue 200 —
# resuming the arbitrary freshest jsonl resurrected a transient
# recovery session); entry.sh must say so instead of promising resume.

ROOT=$(make_fixture)
DEAD_SID="ffffffff-0000-1111-2222-333333333333"
printf '%s\n' "$DEAD_SID" > "$ROOT/monitor/.state/orchestrator-session-id"
PRESEED_WINDOWS="some-other-window" run_entry "$ROOT" --continue
pin_after=""
[[ -f "$ROOT/monitor/.state/orchestrator-session-id" ]] \
    && pin_after=$(tr -d '[:space:]' < "$ROOT/monitor/.state/orchestrator-session-id")
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"missing or stale — the watcher will spawn a FRESH orchestrator"* ]] \
   && [[ "$pin_after" == "$DEAD_SID" ]]; then
    pass "--continue + stale pin: fresh-spawn messaging, pin left for audit (resolver ignores it)"
else
    fail "--continue stale pin: rc=$ENTRY_RC pin_after='$pin_after' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 7: --continue without a pin → fresh messaging -------------------------

ROOT=$(make_fixture)
PRESEED_WINDOWS="some-other-window" run_entry "$ROOT" --continue
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"missing or stale — the watcher will spawn a FRESH orchestrator"* ]]; then
    pass "--continue without pin: fresh-spawn messaging (no resume promise)"
else
    fail "--continue no pin: rc=$ENTRY_RC err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 8: orchestrator window already present (default) → pin untouched ------

ROOT=$(make_fixture)
PIN_SID="7234e315-5847-480c-a3d8-71478c6dc271"
printf '%s\n' "$PIN_SID" > "$ROOT/monitor/.state/orchestrator-session-id"
PRESEED_WINDOWS=$'shell\norchestrator' run_entry "$ROOT"
pin_after=""
[[ -f "$ROOT/monitor/.state/orchestrator-session-id" ]] \
    && pin_after=$(tr -d '[:space:]' < "$ROOT/monitor/.state/orchestrator-session-id")
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"already alive — no spawn, pin untouched"* ]] \
   && [[ "$pin_after" == "$PIN_SID" ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]]; then
    pass "orchestrator alive (default): pin untouched, idempotent bring-up still runs"
else
    fail "orch alive default: rc=$ENTRY_RC pin_after='$pin_after' svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 9: orchestrator window already present + --continue → no effect -------

ROOT=$(make_fixture)
PIN_SID="7234e315-5847-480c-a3d8-71478c6dc271"
printf '%s\n' "$PIN_SID" > "$ROOT/monitor/.state/orchestrator-session-id"
PRESEED_WINDOWS=$'shell\norchestrator' run_entry "$ROOT" --continue
pin_after=""
[[ -f "$ROOT/monitor/.state/orchestrator-session-id" ]] \
    && pin_after=$(tr -d '[:space:]' < "$ROOT/monitor/.state/orchestrator-session-id")
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"--continue has no effect"* ]] \
   && [[ "$pin_after" == "$PIN_SID" ]]; then
    pass "orchestrator alive + --continue: 'no effect' messaging, pin untouched"
else
    fail "orch alive --continue: rc=$ENTRY_RC pin_after='$pin_after' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 10: svc.sh up failure → warning, cockpit still reached ----------------

ROOT=$(make_fixture)
SVC_UP_RC=1 PRESEED_WINDOWS="some-other-window" run_entry "$ROOT"
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"'svc.sh up' exited non-zero"* ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: <cockpit>"* ]]; then
    pass "svc.sh up failure: loud warning, operator still lands in the cockpit"
else
    fail "up failure: rc=$ENTRY_RC svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 11: legacy `watcher` window present → no refusal ----------------------
# Pre-cutover entry.sh refused with rc=3 ("a watcher is already
# running"). Headless model: the window is a migration leftover; the
# launcher (via svc.sh up) sweeps it once no live pidfile-owning
# watcher exists, and a live legacy watcher is left alone by the
# idempotent recovery. entry.sh proceeds either way.

ROOT=$(make_fixture)
PRESEED_WINDOWS="watcher" run_entry "$ROOT"
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]] \
   && [[ "$ENTRY_ERR" != *"already exists"* ]]; then
    pass "legacy 'watcher' window: no refusal — idempotent bring-up proceeds"
else
    fail "legacy watcher window: rc=$ENTRY_RC svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 12: rename targets the invoking window by id, not the active one ------
# entry.sh runs in window 1 (pane %0) but the session-active window is
# window 2. An un-targeted rename-window would hit window 2; the
# id-targeted rename must hit window 1.

ROOT=$(make_fixture)
PRESEED_WINDOWS=$'mine\nother' PRESEED_CURRENT=2 run_entry "$ROOT"
windows=$(<"$ENTRY_STATE_DIR/tmux-windows.txt")
expected_windows=$'services\nother'
if (( ENTRY_RC == 0 )) && [[ "$windows" == "$expected_windows" ]]; then
    pass "rename: invoking window (by id) became 'services'; active window untouched"
else
    fail "rename targeting: rc=$ENTRY_RC windows='$windows' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 13: invoked from inside the orchestrator window → refuse -------------
# (issue #203 revision / 2026-06-11 incident class). entry.sh ends by
# renaming its own window to 'services' + exec'ing the cockpit; from a
# pane inside the orchestrator's window that vaporises the target name
# (watcher: absent → kill-then-spawn) and plants a cockpit where the
# agent lived. The guard must refuse BEFORE the pin archive and the
# bring-up.

ROOT=$(make_fixture)
echo "12345678-1234-1234-1234-123456789abc" > "$ROOT/monitor/.state/orchestrator-session-id"
PRESEED_WINDOWS=$'orchestrator\nservices' PRESEED_CURRENT=1 run_entry "$ROOT"
windows=$(<"$ENTRY_STATE_DIR/tmux-windows.txt")
if (( ENTRY_RC == 2 )) \
   && [[ "$ENTRY_ERR" == *"REFUSING to run from inside the 'orchestrator' window"* ]] \
   && [[ "$windows" == $'orchestrator\nservices' ]] \
   && [[ -f "$ROOT/monitor/.state/orchestrator-session-id" ]] \
   && ! ls "$ROOT/monitor/.state/"orchestrator-session-id.archived.* >/dev/null 2>&1 \
   && [[ "$ENTRY_SVC_LOG" != *"svc.sh called"* ]]; then
    pass "orchestrator-window invocation refused: rc=2, no rename, pin intact, no bring-up"
else
    fail "orchestrator-window guard: rc=$ENTRY_RC windows='$windows' svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 14: live peer cockpit → bring-up runs, rename+cockpit skipped ---------
# A second `./watcher` (e.g. from a fresh window while 1:services holds
# the dashboard) must stay idempotent: stack bring-up yes, but no second
# cockpit and no window renamed to 'services'.

ROOT=$(make_fixture)
# A real long-running process whose cmdline ends in svc.sh (argc=2) —
# what _nexus_pid_is_cockpit positively identifies.
mkdir -p "$ROOT/fakecockpit"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$ROOT/fakecockpit/svc.sh"
FAKE_COCKPIT_LOG=/dev/null bash "$ROOT/fakecockpit/svc.sh" &
FAKE_COCKPIT_PID=$!
sleep 0.2
PRESEED_WINDOWS=$'mine\nservices' PRESEED_CURRENT=1 PRESEED_PANES="%5|$FAKE_COCKPIT_PID|@2|services" run_entry "$ROOT"
windows=$(<"$ENTRY_STATE_DIR/tmux-windows.txt")
if (( ENTRY_RC == 0 )) \
   && [[ "$ENTRY_ERR" == *"cockpit is already running"* ]] \
   && [[ "$windows" == $'mine\nservices' ]] \
   && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]] \
   && [[ "$ENTRY_SVC_LOG" != *"<cockpit>"* ]]; then
    pass "live peer cockpit: bring-up ran, rename + second cockpit skipped (rc=0)"
else
    fail "peer-cockpit guard: rc=$ENTRY_RC windows='$windows' svc='$ENTRY_SVC_LOG' err='$ENTRY_ERR'"
fi
# `|| true` is load-bearing: run_entry leaves errexit ON (its set +e /
# set -e bracket), and `wait` on a TERM-killed child returns 143 —
# without the guard the whole suite dies here with rc=143.
kill "$FAKE_COCKPIT_PID" 2>/dev/null || true
wait "$FAKE_COCKPIT_PID" 2>/dev/null || true
rm -rf "$ROOT"

# --- summary --------------------------------------------------------------

echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
