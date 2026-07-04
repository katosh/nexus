#!/usr/bin/env bash
# monitor/cc-harness/_lib.sh — shared library for the real-binary CC
# test harness. Boots the *real* `claude` against the auth-free mock
# backend (mock-backend.py) in a dedicated, isolated tmux socket, then
# drives it and classifies its panes with the production
# monitor/pane-state.sh.
#
# This is the complement to monitor/watcher/test-integration/_harness.sh:
# that harness drives a fully *fake* `claude` shim (stub-claude.sh); this
# one drives the *real* binary so the actual boot / hook / tool-loop /
# pane-rendering surface is exercised. The mock supplies the "model"
# (canned or control-file-injected responses) with NO Anthropic auth and
# NO network egress.
#
# Globals set by cch_setup (exported for child processes):
#   CCH_DIR        tmpdir root for this run
#   CCH_CFG        isolated CLAUDE_CONFIG_DIR (no real creds ever live here)
#   CCH_WORKDIR    pinned project cwd for the booted claude (pre-trusted)
#   CCH_STATE_DIR  $CCH_DIR/state (NEXUS_STATE_DIR for pane-state)
#   CCH_SOCKET     tmux -L socket name (isolated; never the live session)
#   CCH_SESSION    tmux session name
#   CCH_MOCK_PORT  port the mock bound (discovered when launched with :0)
#   CCH_MOCK_PID   pid of the mock backend
#   CCH_CONTROL    path to the injectable control.json
#   CCH_TMUXWRAP   PATH-shadow tmux wrapper that injects -L $CCH_SOCKET
#   CLAUDE_BIN     resolved real claude binary (override to gate a candidate)
#
# Conventions mirror _harness.sh: cch_tmux for socket-scoped tmux,
# wait_for/hold_false for polling predicates, assert_* from
# _test_helpers.sh.

set -uo pipefail

_cch_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CCH_REPO_ROOT=$(cd "$_cch_self_dir/../.." && pwd)

# trash_path: rename-aside instead of unlink for teardown, so a still-
# releasing claude config dir over NFS can't make `rm` fail with
# `.nfs`/"Directory not empty".
# shellcheck source=../_trash.sh
. "$CCH_REPO_ROOT/monitor/_trash.sh"
CCH_MOCK_PY="$_cch_self_dir/mock-backend.py"
CCH_PANE_STATE="$CCH_REPO_ROOT/monitor/pane-state.sh"

# Resolve the REAL tmux executable, ignoring any shell alias/function
# (`type -P` returns the PATH binary only). The agent-sandbox ships an
# aliased `tmux='tmux -2'`; a bare `command -v tmux` would capture the
# alias and produce a broken wrapper.
_cch_real_tmux() {
    local t
    t=$(type -P tmux 2>/dev/null) && [[ -n "$t" ]] && { printf '%s' "$t"; return; }
    for c in /usr/bin/tmux /usr/local/bin/tmux; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return; }
    done
    return 1
}

# Resolve the real python3.
_cch_python() {
    command -v python3 2>/dev/null || command -v python 2>/dev/null
}

# Skip-gate. Scenarios call this BEFORE cch_setup so the skip path is
# cheap. Gated on RUN_CC_HARNESS=1 (separate axis from RUN_INTEGRATION,
# since this suite additionally needs node + a real claude binary).
#
# Exit code: 0 normally (so the fast-loop runner monitor/watcher/
# run-tests.sh — which counts rc==0 as PASS — treats a self-skip as a
# clean non-failure, matching SLOW_TESTS / RUN_INTEGRATION). BUT under the
# pre-update gate (CCH_GATE=1) a skip is NOT benign: it means the gate
# could not actually validate the candidate, so it must NOT be confused
# with a pass. There we exit 77 (the autotools "SKIP" sentinel) so
# gate.sh can fail RED on any skip — the exact green-via-skip hole B12
# closes (your-org/your-nexus#236 U12). 77 is unused by these scenarios'
# real pass/fail paths.
cch_skip_if_disabled() {
    local why=""
    if [[ "${RUN_CC_HARNESS:-0}" != "1" ]]; then
        why="set RUN_CC_HARNESS=1 to enable"
    elif ! _cch_real_tmux >/dev/null; then
        why="tmux not on PATH"
    elif ! command -v node >/dev/null 2>&1; then
        why="node not on PATH"
    elif ! _cch_python >/dev/null; then
        why="python3 not on PATH"
    elif ! cch_resolve_claude >/dev/null 2>&1; then
        why="no claude binary (run monitor/install-claude-local.sh, or set CLAUDE_BIN)"
    fi
    if [[ -n "$why" ]]; then
        echo "skipped: $(basename "${0}") ($why)"
        [[ "${CCH_GATE:-0}" == "1" ]] && exit 77
        exit 0
    fi
}

# Resolve the claude binary. Honors CLAUDE_BIN (the pre-update gate sets
# this to a candidate-version install in a throwaway prefix); else the
# project-local install. Echoes the path; rc=1 if none found.
cch_resolve_claude() {
    if [[ -n "${CLAUDE_BIN:-}" ]] && [[ -x "$CLAUDE_BIN" ]]; then
        printf '%s' "$CLAUDE_BIN"; return 0
    fi
    local local_bin="$CCH_REPO_ROOT/node_modules/.bin/claude"
    if [[ -x "$local_bin" ]]; then
        printf '%s' "$local_bin"; return 0
    fi
    return 1
}

# Bring up the run: tmpdir, mock backend, isolated config + tmux socket.
cch_setup() {
    CLAUDE_BIN=$(cch_resolve_claude) || { echo "cch_setup: no claude binary" >&2; return 1; }
    export CLAUDE_BIN

    CCH_DIR=$(mktemp -d -t cc-harness-XXXXXX)
    CCH_CFG="$CCH_DIR/cfg"
    CCH_WORKDIR="$CCH_DIR/proj"
    CCH_STATE_DIR="$CCH_DIR/state"
    CCH_CONTROL="$CCH_DIR/control.json"
    CCH_LOG="$CCH_DIR/requests.log"
    CCH_SOCKET="cch-$$-$RANDOM"
    CCH_SESSION="cch-$$-$RANDOM"
    mkdir -p "$CCH_CFG" "$CCH_WORKDIR" "$CCH_STATE_DIR" "$CCH_DIR/.bin"

    # Pre-seed config so the real binary skips ALL first-run gates:
    #   theme picker -> theme + hasCompletedOnboarding
    #   folder trust -> per-project projects.<cwd>.hasTrustDialogAccepted
    # (custom-API-key dialog is avoided by using ANTHROPIC_AUTH_TOKEN
    # rather than ANTHROPIC_API_KEY — see cch_boot_worker.)
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg wd "$CCH_WORKDIR" '{
            theme: "dark", hasCompletedOnboarding: true,
            bypassPermissionsModeAccepted: true,
            projects: { ($wd): {
                hasTrustDialogAccepted: true,
                hasCompletedProjectOnboarding: true, allowedTools: [] } }
        }' > "$CCH_CFG/.claude.json"
    else
        printf '{"theme":"dark","hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true,"projects":{"%s":{"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true,"allowedTools":[]}}}\n' \
            "$CCH_WORKDIR" > "$CCH_CFG/.claude.json"
    fi

    # Default control directive: single-shot canned text.
    cch_control '{"mode":"text","text":"MOCK_OK_HELLO"}'

    # Start the mock on an ephemeral port; discover what it bound.
    local py; py=$(_cch_python)
    local port_file="$CCH_DIR/mock.port"
    MOCK_DIR="$CCH_DIR" MOCK_LOG="$CCH_LOG" MOCK_CONTROL="$CCH_CONTROL" \
        MOCK_PORT_FILE="$port_file" \
        "$py" "$CCH_MOCK_PY" 0 >"$CCH_DIR/mock.stderr" 2>&1 &
    CCH_MOCK_PID=$!
    local waited=0
    while [[ ! -s "$port_file" ]]; do
        sleep 0.1; waited=$((waited+1))
        if (( waited > 50 )); then
            echo "cch_setup: mock backend never advertised a port" >&2
            cat "$CCH_DIR/mock.stderr" >&2 || true
            return 1
        fi
        kill -0 "$CCH_MOCK_PID" 2>/dev/null || {
            echo "cch_setup: mock backend died on startup" >&2
            cat "$CCH_DIR/mock.stderr" >&2 || true
            return 1
        }
    done
    CCH_MOCK_PORT=$(<"$port_file")

    # PATH-shadow tmux wrapper so pane-state.sh's bare `tmux` calls hit
    # our isolated socket. Resolve the real tmux at write time.
    local real_tmux; real_tmux=$(_cch_real_tmux)
    CCH_TMUXWRAP="$CCH_DIR/.bin/tmux"
    printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$real_tmux" "$CCH_SOCKET" > "$CCH_TMUXWRAP"
    chmod +x "$CCH_TMUXWRAP"

    # Bring up the isolated server with a detached scratch window. -f
    # /dev/null ignores the operator's personal tmux.conf.
    cch_tmux -f /dev/null new-session -d -s "$CCH_SESSION" \
        -x 120 -y 40 -c "$CCH_WORKDIR" 'sleep 36000'

    export CCH_DIR CCH_CFG CCH_WORKDIR CCH_STATE_DIR CCH_CONTROL CCH_LOG \
           CCH_SOCKET CCH_SESSION CCH_MOCK_PORT CCH_MOCK_PID CCH_TMUXWRAP

    trap cch_teardown EXIT
}

cch_teardown() {
    if [[ -n "${CCH_TMUXWRAP:-}" && -x "${CCH_TMUXWRAP:-}" ]]; then
        cch_tmux kill-server 2>/dev/null || true
    fi
    if [[ -n "${CCH_MOCK_PID:-}" ]]; then
        kill "$CCH_MOCK_PID" 2>/dev/null || true
    fi
    if [[ -n "${CCH_DIR:-}" && -d "${CCH_DIR:-}" ]]; then
        # Move the run dir aside (rename) instead of rm: the killed claude
        # may still be releasing its config dir, and over NFS unlink would
        # silly-rename open files to `.nfs*` and make rm report "Directory
        # not empty". A same-fs rename always succeeds regardless of holders;
        # the entry is reaped later by `_trash.sh --clear`. Fall back to the
        # old settle+retry rm if trashing is unavailable.
        trash_path "$CCH_DIR" >/dev/null 2>&1 \
            || { sleep 0.3; rm -rf "$CCH_DIR" 2>/dev/null \
                || { sleep 0.7; rm -rf "$CCH_DIR" 2>/dev/null || true; }; }
    fi
}

# Socket-scoped tmux (uses the real binary directly with -L).
cch_tmux() {
    local real_tmux; real_tmux=$(_cch_real_tmux)
    "$real_tmux" -L "$CCH_SOCKET" "$@"
}

# Write a control directive (JSON string) for the mock's NEXT request.
cch_control() {
    printf '%s\n' "$1" > "$CCH_CONTROL"
}

# Boot the real claude in a new tmux window against the mock. Echoes the
# new window's index. Renderer-path only (no --settings hooks) so this
# exercises pane-state's renderer classification; a heartbeat-substrate
# variant is a documented follow-up.
cch_boot_worker() {
    local name="$1"
    # env -i for a hermetic child: only the vars claude needs. PATH must
    # carry node (claude is a node program) — pass the harness PATH
    # through. ANTHROPIC_AUTH_TOKEN (bearer) instead of ANTHROPIC_API_KEY
    # avoids the interactive custom-API-key approval dialog.
    local launch
    printf -v launch 'env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q \
ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 \
DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 \
TERM=%q %q --dangerously-skip-permissions' \
        "$CCH_CFG" "$PATH" "$CCH_CFG" \
        "http://127.0.0.1:$CCH_MOCK_PORT" "${TERM:-xterm-256color}" "$CLAUDE_BIN"

    cch_tmux new-window -d -t "$CCH_SESSION": -n "$name" -c "$CCH_WORKDIR" "$launch"
    local idx
    idx=$(cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' \
        | awk -v n="$name" '$1==n {print $2; exit}')
    # remain-on-exit keeps the dead pane (and its last frame) around after
    # the inner REPL exits, so pane-state's process-liveness gate can
    # emit `absent` instead of the window vanishing — mirrors how the
    # production watcher configures worker windows.
    [[ -n "$idx" ]] && cch_tmux set-option -t "$CCH_SESSION:$idx" -w remain-on-exit on 2>/dev/null
    printf '%s' "$idx"
}

# Run the production pane-state.sh against a live window via the wrapper.
cch_pane_state() {
    local window="$1"
    PATH="$CCH_DIR/.bin:$PATH" NEXUS_STATE_DIR="$CCH_STATE_DIR" \
        "$CCH_PANE_STATE" "$CCH_SESSION:$window"
}

# Convenience: just the state= token.
cch_state() {
    cch_pane_state "$1" | sed -n 's/.*state=\([^ ]*\).*/\1/p'
}

# Capture a window's pane (plain text, last 25 rows like pane-state).
cch_capture() {
    cch_tmux capture-pane -t "$CCH_SESSION:$1" -p -J -S -25 2>/dev/null
}

# Send a prompt the way the watcher injects: type the text, then Enter
# as a separate key (mirrors the send-keys paste-to-target path).
cch_send() {
    local window="$1" text="$2"
    cch_tmux send-keys -t "$CCH_SESSION:$window" "$text"
    sleep 0.4
    cch_tmux send-keys -t "$CCH_SESSION:$window" Enter
}

# Kill the inner claude process for a window (simulate a crash) so the
# pane goes to state=absent under remain-on-exit. PID-SCOPED ONLY: walks the
# pane shell's descendant tree by parent-PID and TERMs each node. NEVER use a
# cmdline-pattern kill (`pkill -f`) here — every nexus agent runs the SAME
# project-local claude binary inside ONE shared sandbox PID namespace, so a
# command-line match SIGTERMs the whole control plane at once (crash
# postmortem 2026-05-29; reports/nexus_2026-05-29_142117_crash-postmortem-pkill-mass-kill.md).
# lint-no-mass-kill.sh enforces this ban.
cch_kill_claude() {
    local window="$1" pane_pid
    pane_pid=$(cch_tmux display-message -p -t "$CCH_SESSION:$window" '#{pane_pid}' 2>/dev/null)
    [[ -n "$pane_pid" ]] || return 1
    _cch_kill_tree "$pane_pid"
}

# Collect a PID and all its descendants, leaves first, via `pgrep -P`
# (parent-PID) walks only — never by command-line pattern.
_cch_tree_pids() {
    local pid="$1" child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        _cch_tree_pids "$child"
    done
    printf '%s\n' "$pid"
}

# TERM a PID subtree (leaves first), grant a short grace, then KILL any
# survivor. Scoped strictly to a one-shot snapshot of the subtree rooted
# at $1 — pid-scoped, never cmdline-matched (see cch_kill_claude above).
#
# The KILL escalation is load-bearing for the absent scenario: claude
# installs a graceful-shutdown SIGTERM handler, and on slow shared CI
# runners its teardown has been observed to outlive the scenario's 15 s
# `state=absent` window (cc-harness runs 26909460209 on dev and
# 27389919749 on PR 270 — identical flake signature on both sides of
# the #205 change; locally TERM→exit measures ~0.1 s). The scenario
# simulates a CRASH, so forcing the exit after a 2 s grace is faithful
# to the intent and removes the dependence on claude's teardown latency.
_cch_kill_tree() {
    local root="$1" pids pid alive i
    pids=$(_cch_tree_pids "$root")
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    for i in 1 2 3 4 5 6 7 8; do
        alive=0
        for pid in $pids; do
            kill -0 "$pid" 2>/dev/null && { alive=1; break; }
        done
        (( alive )) || return 0
        sleep 0.25
    done
    for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
}

# ---- polling predicates (mirrors _harness.sh) ----------------------------
wait_for() {
    local label="$1" max="$2"; shift 2
    [[ "$1" == "--" ]] || { echo "wait_for: missing -- separator" >&2; return 2; }
    shift
    local deadline=$(( $(date +%s) + max )) attempts=0
    while (( $(date +%s) < deadline )); do
        if "$@" >/dev/null 2>&1; then
            printf '  PASS: %s (after %d polls)\n' "$label" "$attempts"
            : "${PASS:=0}"; PASS=$(( PASS + 1 )); return 0
        fi
        attempts=$(( attempts + 1 )); sleep 0.25
    done
    printf '  FAIL: %s — predicate never satisfied within %ds (%d polls)\n' \
        "$label" "$max" "$attempts" >&2
    printf '         last cmd: %s\n' "$*" >&2
    : "${FAIL:=0}"; FAIL=$(( FAIL + 1 )); return 1
}

# Predicate helper: pane state equals expected.
cch_state_is() {
    [[ "$(cch_state "$1")" == "$2" ]]
}
