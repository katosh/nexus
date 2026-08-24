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
#  4b. Cold start writes the WORKER-side handoff — a `mode=fresh`
#      boot-intent file, before `svc.sh up`, so bootstrap-recover's
#      worker walk resurrects nothing (your-org/nexus-code#651).
#  4c. --continue writes `mode=continue` instead.
#  4d. A live orchestrator window writes NO intent at all: re-running
#      ./watcher on a live stack is an idempotent bring-up, not a boot.
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

# Truncation sentinel. `run_entry` ends with `set -e` (it brackets the entry.sh
# invocation in `set +e` / `set -e`), so from the first case onward ANY
# top-level command returning non-zero aborts the script — mid-suite, with no
# summary and **exit 0**. A half-run that exits green is worse than a failing
# one: nothing downstream can tell it apart from a pass. Found by a mutant that
# made a `ls …archived.*` probe fail and silently truncated the suite after
# case 4d. The trap converts that class into a loud failure.
_SUITE_COMPLETED=0
trap '(( _SUITE_COMPLETED == 1 )) || { echo "FAIL: SUITE TRUNCATED — aborted after $(( PASS + FAIL )) assertions without reaching the summary (a non-zero command under the set -e that run_entry leaves enabled). Exit code forced non-zero." >&2; exit 1; }' EXIT

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
        # Canned pane table, one row per pane, pipe-separated:
        #   pane_id|pane_pid|window_id|window_name[|pane_dead]
        # The 5th field is optional and defaults to 0, so the pre-existing
        # 4-field fixtures (the peer-cockpit scan) are unchanged.
        #
        # Rendered THROUGH the requested `-F` format rather than dumped
        # verbatim: entry.sh's liveness probe asks for a different field
        # order (`#{window_name}|#{pane_dead}|#{pane_pid}`), and a stub that
        # ignores -F would silently hand it the cockpit scan's layout —
        # a fixture that answers a question nobody asked. Absent file → no
        # panes (callers fail open).
        fmt=""
        shift
        while (( $# > 0 )); do
            case "$1" in
                -F) fmt="$2"; shift 2 ;;
                *)  shift ;;
            esac
        done
        [[ -f "$state/tmux-panes.txt" ]] || exit 0
        while IFS='|' read -r p_id p_pid w_id w_name p_dead; do
            [[ -n "$p_id" ]] || continue
            if [[ -z "$fmt" ]]; then
                printf '%s|%s|%s|%s\n' "$p_id" "$p_pid" "$w_id" "$w_name"
                continue
            fi
            line="$fmt"
            line="${line//'#{pane_id}'/$p_id}"
            line="${line//'#{pane_pid}'/$p_pid}"
            line="${line//'#{window_id}'/$w_id}"
            line="${line//'#{window_name}'/$w_name}"
            line="${line//'#{pane_dead}'/${p_dead:-0}}"
            printf '%s\n' "$line"
        done < "$state/tmux-panes.txt"
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

# --- 4b: cold start hands the WORKER walk a fresh boot-intent -------------
# your-org/nexus-code#651. The pin above governs the orchestrator and
# nothing else; the worker agents are resurrected by bootstrap-recover's
# own walk, which runs after entry.sh has exited. The boot-intent file is
# how the operator's flag reaches it — and it must be written BEFORE
# `svc.sh up`, or the walk it is meant to govern has already happened.

ROOT=$(make_fixture)
PRESEED_WINDOWS="some-other-window" run_entry "$ROOT"
intent="$ROOT/monitor/.state/boot-intent"
if (( ENTRY_RC == 0 )) \
   && [[ -f "$intent" ]] \
   && grep -qx 'mode=fresh' "$intent" \
   && grep -qE '^ts=[0-9]+$' "$intent" \
   && grep -qx 'source=entry.sh' "$intent" \
   && [[ "$ENTRY_ERR" == *"NO worker agent will be resumed"* ]]; then
    pass "cold start: boot-intent written as mode=fresh with a timestamp (worker walk told to resurrect nothing)"
else
    fail "cold-start boot-intent: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
fi
# Ordering: the intent must predate the bring-up it governs. The svc.sh
# stub records each call, so an intent that exists by the time `up` ran
# is provable rather than assumed.
if [[ -f "$intent" ]] && [[ "$ENTRY_SVC_LOG" == *"svc.sh called: up"* ]] \
   && [[ "$(stat -c '%Y' "$intent")" -le "$(stat -c '%Y' "$ENTRY_STATE_DIR/svc-log.txt")" ]]; then
    pass "cold start: boot-intent written BEFORE svc.sh up (the walk it governs cannot outrun it)"
else
    fail "boot-intent ordering vs svc.sh up"
fi
rm -rf "$ROOT"

# --- 4c: --continue hands over mode=continue ------------------------------

ROOT=$(make_fixture)
PRESEED_WINDOWS="some-other-window" run_entry "$ROOT" --continue
intent="$ROOT/monitor/.state/boot-intent"
if (( ENTRY_RC == 0 )) \
   && [[ -f "$intent" ]] \
   && grep -qx 'mode=continue' "$intent" \
   && [[ "$ENTRY_ERR" == *"will be resumed by the stack bring-up"* ]]; then
    pass "--continue: boot-intent written as mode=continue (prior workers resumed)"
else
    fail "--continue boot-intent: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 4d: live orchestrator → no boot-intent written -----------------------
# Re-running ./watcher against a live orchestrator is an idempotent
# bring-up, not a boot. Writing mode=fresh here would tear the worker
# board out from under a running supervisor — a destructive reading of a
# no-op. Mirrors the pin, which is likewise left untouched in this branch.

ROOT=$(make_fixture)
PRESEED_WINDOWS=$'shell\norchestrator' run_entry "$ROOT"
intent="$ROOT/monitor/.state/boot-intent"
if (( ENTRY_RC == 0 )) \
   && [[ ! -f "$intent" ]] \
   && [[ "$ENTRY_ERR" == *"worker resume behaviour unchanged"* ]]; then
    pass "live orchestrator: NO boot-intent written (idempotent bring-up never drops a live worker board)"
else
    fail "live-orch boot-intent: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 4e: a `remain-on-exit` CORPSE window is a boot, not a live stack ------
# your-org/nexus-code#651 skeptic, finding 1 — the blocking one. `_respawn.sh`
# sets `remain-on-exit on`, so a claude that segfaults / OOMs / is `/exit`ed
# leaves its window LISTED with a dead pane. Deciding "is this a boot?" from
# the window NAME therefore took the already-alive branch in the commonest
# crash shape: no boot-intent written, whole board resurrected, escape hatch
# inoperative exactly when the operator reaches for it. Same class as `#643`
# (a pane's rendered existence mistaken for liveness).
#
# Two panes deliberately: the corpse AND an unrelated live window, so the test
# fails if the probe merely asks "are any panes dead anywhere".

#
# THE FIXTURE IS THE TEST. An earlier version pinned the corpse pane to
# `pane_pid=1` and appeared to pin the `pane_dead` guard — but only on this
# host, where pid 1 is `bwrap` with `/home/operator/.claude` in its argv 28 times.
# On CI (pid 1 = init/systemd, no `claude`, and `kill -0 1` EPERMs) deleting
# the guard changed nothing and the mutant SURVIVED: a test passing for an
# environment-specific accident, which is worse than no test because it reads
# as evidence. Never build a fixture on a pid you do not control.
#
# The discriminating shape is not the obvious one — a non-claude pid passes
# either way, because the tree walk also says "no agent". What isolates the
# guard is a DEAD pane whose pid DOES resolve to a claude-named process (the
# pid-reuse / lingering-child shape that makes `pane_dead` load-bearing):
# with the guard, dead wins and this is a boot; without it, the tree walk
# finds an agent and calls it alive.
ROOT=$(make_fixture)
PIN_SID="7234e315-5847-480c-a3d8-71478c6dc271"
printf '%s\n' "$PIN_SID" > "$ROOT/monitor/.state/orchestrator-session-id"
setsid bash -c 'exec -a claude-corpse-pid sleep 30' >/dev/null 2>&1 &
CORPSE_PID=$!
setsid bash -c 'exec -a plain-shell-fixture sleep 30' >/dev/null 2>&1 &
OTHER_PID=$!
sleep 0.3
PRESEED_WINDOWS=$'shell\norchestrator' \
PRESEED_PANES="%9|$OTHER_PID|@1|shell|0"$'\n'"%8|$CORPSE_PID|@2|orchestrator|1" \
    run_entry "$ROOT"
intent="$ROOT/monitor/.state/boot-intent"
# `|| true`: run_entry leaves errexit ON, and this glob legitimately matches
# nothing when the code under test misbehaves. Without the guard a REGRESSION
# aborts the whole suite here instead of reporting — which is exactly how a
# mutant truncated this file at case 4d and still exited 0.
archived=$(ls "$ROOT/monitor/.state/"orchestrator-session-id.archived.* 2>/dev/null | head -1 || true)
if (( ENTRY_RC == 0 )) \
   && [[ -f "$intent" ]] && grep -qx 'mode=fresh' "$intent" \
   && [[ "$ENTRY_ERR" == *"holds NO live agent"* ]] \
   && [[ "$ENTRY_ERR" == *"NO worker agent will be resumed"* ]]; then
    pass "dead-pane corpse window: treated as a BOOT — fresh boot-intent written (escape hatch works in the commonest crash shape)"
else
    fail "corpse-window intent: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
fi
# "Is this a boot?" is one question: the pin follows the same answer, or the
# operator gets a fresh worker board under a resumed orchestrator session.
if [[ ! -f "$ROOT/monitor/.state/orchestrator-session-id" ]] \
   && [[ -n "$archived" ]] \
   && [[ "$(tr -d '[:space:]' < "$archived")" == "$PIN_SID" ]]; then
    pass "dead-pane corpse window: the session pin follows the same verdict (archived, content intact)"
else
    fail "corpse-window pin: archived='$archived' still=$([[ -f "$ROOT/monitor/.state/orchestrator-session-id" ]] && echo yes || echo no)"
fi
for _p in "$CORPSE_PID" "$OTHER_PID"; do
    if kill -0 "$_p" 2>/dev/null \
       && grep -qE 'claude-corpse-pid|plain-shell-fixture' \
          <<<"$(tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null)"; then
        kill "$_p" 2>/dev/null
    fi
done
rm -rf "$ROOT"

# --- 4f: a LIVE claude in the pane tree still suppresses the intent --------
# The converse, and the one that protects a running board: a pane that is NOT
# dead and has a live `claude` in its process tree must still read as alive.
# Uses a real process whose argv contains `claude`, so the probe's /proc walk
# is genuinely exercised rather than short-circuited.

ROOT=$(make_fixture)
setsid bash -c 'exec -a claude-fixture sleep 30' >/dev/null 2>&1 &
LIVE_PID=$!
sleep 0.3
PRESEED_WINDOWS=$'shell\norchestrator' \
PRESEED_PANES="%9|1|@1|shell|0"$'\n'"%8|$LIVE_PID|@2|orchestrator|0" \
    run_entry "$ROOT"
intent="$ROOT/monitor/.state/boot-intent"
if (( ENTRY_RC == 0 )) \
   && [[ ! -f "$intent" ]] \
   && [[ "$ENTRY_ERR" != *"holds NO live agent"* ]] \
   && [[ "$ENTRY_ERR" == *"already alive"* ]]; then
    pass "live claude in the pane tree: NO intent written (a running board is never torn down by an idempotent bring-up)"
else
    fail "live-pane: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
fi
# Identity-checked kill: after a PID-space wrap a blind kill would signal
# whatever innocent process recycled the number.
if kill -0 "$LIVE_PID" 2>/dev/null \
   && grep -q claude-fixture \
      <<<"$(tr '\0' ' ' < "/proc/$LIVE_PID/cmdline" 2>/dev/null)"; then
    kill "$LIVE_PID" 2>/dev/null
fi
rm -rf "$ROOT"

# --- 4i: pane ALIVE but no agent in its process tree → still a boot -------
# The other half of the liveness test, and a distinct line from 4f. A mutant
# that bypassed the process-tree check entirely (`_pid_tree_has_claude … &&
# return 0` → bare `return 0`) SURVIVED with only 4f present, because 4f's pane
# genuinely does host a claude — it passes either way. What discriminates is a
# pane that is NOT dead and hosts NO agent: a plain shell left in the window, a
# launcher whose claude exited without remain-on-exit, an operator shell that
# happens to carry the name. There is no orchestrator there, so a default
# `./watcher` is a boot.

ROOT=$(make_fixture)
setsid bash -c 'exec -a not-an-agent sleep 30' >/dev/null 2>&1 &
BARE_PID=$!
sleep 0.3
PRESEED_WINDOWS=$'shell\norchestrator' \
PRESEED_PANES="%9|1|@1|shell|0"$'\n'"%8|$BARE_PID|@2|orchestrator|0" \
    run_entry "$ROOT"
intent="$ROOT/monitor/.state/boot-intent"
if (( ENTRY_RC == 0 )) \
   && [[ -f "$intent" ]] && grep -qx 'mode=fresh' "$intent" \
   && [[ "$ENTRY_ERR" == *"holds NO live agent"* ]]; then
    pass "live pane hosting NO claude: treated as a BOOT (pane liveness alone is not agent liveness)"
else
    fail "bare-pane: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
fi
if kill -0 "$BARE_PID" 2>/dev/null \
   && grep -q not-an-agent \
      <<<"$(tr '\0' ' ' < "/proc/$BARE_PID/cmdline" 2>/dev/null)"; then
    kill "$BARE_PID" 2>/dev/null
fi
rm -rf "$ROOT"

# --- 4j: a respawn in flight is ALIVE, not dead --------------------------
# your-org/nexus-code#651 skeptic r2, finding 4. Between `tmux new-window` and
# the launcher's `exec claude` the orchestrator pane is alive and hosts NO
# claude — measured at ~1.7 s on this host, dominated by
# `assert-shims-wrapped.sh` (~2.2 s). A bare claude-in-the-tree test calls that
# DEAD, so `./watcher` would archive the pin and declare a boot mid-respawn.
#
# Bounded (nothing is killed) but NOT rare: the trigger is correlated, not
# independent — the operator reaches for `./watcher` precisely when the
# orchestrator has just died, which is precisely when the watcher is respawning
# it. `_nexus_pid_is_spawning_agent` recognises the launcher by name, which
# closes the window exactly and with no polling: `exec` is atomic, so there is
# no gap between "launcher running" and "claude running".

ROOT=$(make_fixture)
LAUNCHER="$ROOT/nexus-respawn-launch-fixture.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$LAUNCHER"
chmod +x "$LAUNCHER"
setsid bash "$LAUNCHER" >/dev/null 2>&1 &
SPAWNING_PID=$!
sleep 0.3
PRESEED_WINDOWS=$'shell\norchestrator' \
PRESEED_PANES="%8|$SPAWNING_PID|@2|orchestrator|0" \
    run_entry "$ROOT"
intent="$ROOT/monitor/.state/boot-intent"
if (( ENTRY_RC == 0 )) && [[ ! -f "$intent" ]] \
   && [[ "$ENTRY_ERR" != *"holds NO live agent"* ]]; then
    pass "respawn in flight (launcher running, claude not yet exec'd): reads as ALIVE — no false boot mid-respawn"
else
    fail "respawn-race: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
fi
if kill -0 "$SPAWNING_PID" 2>/dev/null \
   && grep -q nexus-respawn-launch \
      <<<"$(tr '\0' ' ' < "/proc/$SPAWNING_PID/cmdline" 2>/dev/null)"; then
    kill "$SPAWNING_PID" 2>/dev/null
fi
rm -rf "$ROOT"

# --- 4g: undeterminable liveness reads as ALIVE (fail-safe direction) ------
# No pane rows at all for a window we know exists — tmux too old for the
# format, a racing kill, a stub that answers nothing. A false "dead" tears
# down a live worker board; a false "alive" only declines to, and the
# operator can re-run. The default must be ALIVE, and it must be asserted,
# because it is the arm nobody exercises by accident.

ROOT=$(make_fixture)
PRESEED_WINDOWS=$'shell\norchestrator' run_entry "$ROOT"   # no PRESEED_PANES
intent="$ROOT/monitor/.state/boot-intent"
if (( ENTRY_RC == 0 )) && [[ ! -f "$intent" ]] \
   && [[ "$ENTRY_ERR" == *"already alive"* ]]; then
    pass "undeterminable liveness (NO pane rows at all): reads as ALIVE — never drops a board it cannot prove is dead"
else
    fail "undeterminable liveness: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
fi
rm -rf "$ROOT"

# --- 4h: pane rows exist but NONE for the target → still ALIVE ------------
# The SAME fail-safe arm as 4g (`(( saw == 1 )) || return 0`), reached by a
# different INPUT SHAPE — not a distinct line, and the comment here used to
# claim otherwise. The probe once carried a separate `[[ -n "$rows" ]] ||
# return 0` early return that 4g was said to pin; deleting that line reddened
# NOTHING, because an empty `$rows` still yields one non-matching iteration and
# falls through to this same arm. It was behaviourally redundant and has been
# removed (your-org/nexus-code#651 skeptic r2, finding 3).
#
# Both cases stay: two input shapes into one fail-safe is worth having, and
# 4g is the shape a caller is most likely to hit. The accounting is what was
# wrong, not the coverage — and mis-stated coverage is exactly the failure
# this PR keeps re-learning.
#
# Shape here: tmux reports panes, but none belongs to the orchestrator window —
# a racing kill, a format the running tmux renders differently, a window whose
# panes tmux declined to list. We cannot judge, so we must not drop.

ROOT=$(make_fixture)
PRESEED_WINDOWS=$'shell\norchestrator' \
PRESEED_PANES='%9|1|@1|shell|0' \
    run_entry "$ROOT"
intent="$ROOT/monitor/.state/boot-intent"
if (( ENTRY_RC == 0 )) && [[ ! -f "$intent" ]] \
   && [[ "$ENTRY_ERR" == *"already alive"* ]] \
   && [[ "$ENTRY_ERR" != *"holds NO live agent"* ]]; then
    pass "pane rows exist but none for the target window: reads as ALIVE (the second fail-safe arm, distinct from 4g)"
else
    fail "saw-arm: rc=$ENTRY_RC intent='$(cat "$intent" 2>/dev/null)' err='$ENTRY_ERR'"
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

# Reaching here is what makes the run legitimate; the EXIT trap turns anything
# short of it into a loud non-zero.
_SUITE_COMPLETED=1
echo
echo "passed=$PASS failed=$FAIL"
(( FAIL == 0 ))
