#!/usr/bin/env bash
# Shared library for watcher integration scenarios. Each scenario
# sources this file, calls `harness_setup`, runs its assertions, and
# exits — `harness_teardown` is wired through an EXIT trap so a
# crashing scenario still tears the tmux server down.
#
# Reuses the same isolation primitives as test-respawn-loop-integration.sh:
#   - Dedicated tmux server on a per-fixture socket (`-L <name>`) so
#     the scenario can never collide with the operator's live nexus
#     tmux, even across parallel test runs.
#   - Stubbed `claude` on PATH so the inner process is fully
#     controllable from env knobs.
#   - PATH-shadowing `tmux` wrapper so any watcher code under test
#     that calls bare `tmux ...` routes to the dedicated socket.
#
# Globals set by harness_setup (exported for child processes):
#   HARNESS_DIR        tmpdir holding the fake nexus tree
#   HARNESS_SOCK       absolute path to the tmux socket file
#   HARNESS_SOCKET     basename of the socket (the `-L` argument)
#   HARNESS_SESSION    tmux session name (unique per run)
#   HARNESS_TMUX       absolute path to the wrapper that injects -L
#   HARNESS_BIN        directory containing stub-claude + tmux wrapper
#   HARNESS_STATE_DIR  $HARNESS_DIR/monitor/.state
#
# Conventions:
#   - Scenarios use `harness_tmux` (function) to call tmux against
#     the dedicated socket without re-typing `-L`.
#   - `wait_for "<label>" <deadline-seconds> -- <cmd>` polls the
#     predicate every 0.25 s until it exits 0 or the deadline lapses;
#     prints PASS/FAIL via the standard assert_* counters.
#   - The harness does NOT source `_test_helpers.sh` itself — each
#     scenario sources it explicitly so the PASS / FAIL counters
#     stay scenario-local.

set -uo pipefail

# Skip-gate. Scenarios call `harness_skip_if_disabled` BEFORE
# `harness_setup` so the skip path doesn't pay the tmux-bring-up cost.
harness_skip_if_disabled() {
    if [[ "${RUN_INTEGRATION:-0}" != "1" ]]; then
        echo "skipped: $(basename "${0}") (set RUN_INTEGRATION=1 to enable)"
        exit 0
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        echo "skipped: $(basename "${0}") (tmux not on PATH)"
        exit 0
    fi
}

# Resolve repo paths from this file's location so the harness works
# in forks and worktrees without env hardcoding.
_harness_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HARNESS_REPO_ROOT=$(cd "$_harness_self_dir/../../.." && pwd)
HARNESS_STUB_CLAUDE_SRC="$_harness_self_dir/stub-claude.sh"

# Populate the fake nexus root + bring up the tmux server. Idempotent
# only at the level of "one harness_setup per scenario" — multiple
# calls in the same process leak state.
harness_setup() {
    HARNESS_DIR=$(mktemp -d -t nexus-watcher-integ-XXXXXX)
    HARNESS_STATE_DIR="$HARNESS_DIR/monitor/.state"
    HARNESS_BIN="$HARNESS_DIR/.bin"
    HARNESS_SOCKET="nexus-integ-$$-$RANDOM"
    HARNESS_SESSION="nexus-integ-$$-$RANDOM"
    # tmux stores its socket under $TMPDIR/tmux-$(id -u)/ by default;
    # we resolve the canonical path so the harness can `rm` it on
    # teardown even when the server crashes mid-run.
    HARNESS_SOCK="${TMPDIR:-/tmp}/tmux-$(id -u)/$HARNESS_SOCKET"

    mkdir -p "$HARNESS_DIR/monitor/watcher" \
             "$HARNESS_DIR/reports" \
             "$HARNESS_DIR/work" \
             "$HARNESS_STATE_DIR" \
             "$HARNESS_BIN"

    # Stub claude. Drop it on PATH as `claude` so
    # `pane-state.sh::_pane_has_live_claude` (which inspects
    # `ps -o comm=`) recognises the process tree.
    cp "$HARNESS_STUB_CLAUDE_SRC" "$HARNESS_BIN/claude"
    chmod +x "$HARNESS_BIN/claude"

    # tmux wrapper. Routes every `tmux ...` call to the dedicated
    # socket. Used both by scenarios (via harness_tmux) and by any
    # production code under test that calls bare `tmux`.
    cat > "$HARNESS_BIN/tmux" <<TMUXWRAP
#!/usr/bin/env bash
exec $(command -v tmux) -L "$HARNESS_SOCKET" "\$@"
TMUXWRAP
    chmod +x "$HARNESS_BIN/tmux"

    export HARNESS_DIR HARNESS_STATE_DIR HARNESS_BIN \
           HARNESS_SOCK HARNESS_SOCKET HARNESS_SESSION
    export HARNESS_TMUX="$HARNESS_BIN/tmux"
    export PATH="$HARNESS_BIN:$PATH"

    # Bring the server up with a detached scratch session. -L isolates
    # the socket; -F overrides the user's tmux.conf so a peculiar
    # personal config (status-bar plugins, hooks) can't perturb the
    # scenario.
    "$HARNESS_TMUX" -f /dev/null new-session -d \
        -s "$HARNESS_SESSION" -c "$HARNESS_DIR" 'sleep 36000'
    "$HARNESS_TMUX" setenv -g PATH "$HARNESS_BIN:$PATH"
    "$HARNESS_TMUX" setenv -g NEXUS_ROOT "$HARNESS_DIR"

    # Trap teardown so a failing assertion still kills the server.
    # If the scenario sets its own EXIT trap, it must call
    # harness_teardown explicitly.
    trap harness_teardown EXIT
}

harness_teardown() {
    if [[ -n "${HARNESS_TMUX:-}" && -x "$HARNESS_TMUX" ]]; then
        "$HARNESS_TMUX" kill-server 2>/dev/null || true
    fi
    if [[ -n "${HARNESS_DIR:-}" && -d "$HARNESS_DIR" ]]; then
        rm -rf "$HARNESS_DIR"
    fi
}

# Thin convenience wrapper so scenarios don't have to type the
# wrapper path on every call.
harness_tmux() {
    "$HARNESS_TMUX" "$@"
}

# Spawn a new tmux window running the stub claude. The caller passes
# the window name plus any env knobs the stub honours (see
# stub-claude.sh):
#
#   harness_spawn_worker my-worker \
#       STUB_CLAUDE_BUSY_SECONDS=4 STUB_CLAUDE_HOLD_SECONDS=20
#
# Returns the new window's 0-based index on stdout. Pane content is
# whatever the stub renders; the harness does not paste a prompt.
#
# Implementation detail: invokes the stub by its absolute path
# ($HARNESS_BIN/claude). tmux's `setenv -g` only seeds the global
# env block read at new-session time, NOT subsequent new-windows on
# an existing session, so `claude` on PATH from setenv -g is
# unreliable. The absolute path also keeps argv[0]'s basename equal
# to `claude` so `pane-state.sh::_pane_has_live_claude` (which
# matches on /proc/<pid>/comm) still recognises the process tree.
harness_spawn_worker() {
    local name="$1"; shift
    local env_assignments=("$@")
    local cmd="exec env"
    local kv
    for kv in "${env_assignments[@]}"; do
        cmd+=" $(printf '%q' "$kv")"
    done
    cmd+=" $(printf '%q' "$HARNESS_BIN/claude")"
    harness_tmux new-window -d \
        -t "${HARNESS_SESSION}:" \
        -n "$name" \
        -c "$HARNESS_DIR" \
        "$cmd"
    harness_tmux list-windows -t "$HARNESS_SESSION" \
        -F '#{window_name} #{window_index}' \
        | awk -v n="$name" '$1==n {print $2; exit}'
}

# Capture a window's pane bytes with ANSI escape codes intact. Mirrors
# the `tmux capture-pane -e -p -J -S -25` invocation in
# `pane-state.sh` so what scenarios assert on matches what production
# parses.
harness_capture() {
    local window="$1"
    harness_tmux capture-pane -t "${HARNESS_SESSION}:${window}" \
        -e -p -J -S -25 2>/dev/null
}

# Run the production `pane-state.sh` against a live window. Returns
# the full key=value emit on stdout. Scenarios can grep for
# `state=<x>` or pipe to awk.
harness_pane_state() {
    local window="$1"
    PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${window}"
}

# Poll a predicate until it exits 0 or the deadline lapses.
#
#   wait_for "<label>" <max-seconds> -- <cmd> [args...]
#
# Polls every 250 ms. On success: prints `PASS` line, returns 0. On
# timeout: prints `FAIL` line with the last failed command, returns 1.
# Increments PASS / FAIL counters when they exist (i.e. the scenario
# has sourced `_test_helpers.sh`).
wait_for() {
    local label="$1" max="$2"; shift 2
    [[ "$1" == "--" ]] || {
        echo "wait_for: missing -- separator" >&2
        return 2
    }
    shift
    local deadline=$(( $(date +%s) + max ))
    local attempts=0
    while (( $(date +%s) < deadline )); do
        if "$@" >/dev/null 2>&1; then
            printf '  PASS: %s (after %d polls)\n' "$label" "$attempts"
            : "${PASS:=0}"
            PASS=$(( PASS + 1 ))
            return 0
        fi
        attempts=$(( attempts + 1 ))
        sleep 0.25
    done
    printf '  FAIL: %s — predicate never satisfied within %ds (%d polls)\n' \
        "$label" "$max" "$attempts" >&2
    printf '         last cmd: %s\n' "$*" >&2
    : "${FAIL:=0}"
    FAIL=$(( FAIL + 1 ))
    return 1
}

# Same as wait_for but inverted: succeeds when the predicate STAYS
# false for the full window. Useful for "make sure the watcher
# doesn't false-positive on a busy worker for N seconds".
hold_false() {
    local label="$1" duration="$2"; shift 2
    [[ "$1" == "--" ]] || {
        echo "hold_false: missing -- separator" >&2
        return 2
    }
    shift
    local deadline=$(( $(date +%s) + duration ))
    while (( $(date +%s) < deadline )); do
        if "$@" >/dev/null 2>&1; then
            printf '  FAIL: %s — predicate became true mid-window\n' "$label" >&2
            printf '         cmd: %s\n' "$*" >&2
            : "${FAIL:=0}"
            FAIL=$(( FAIL + 1 ))
            return 1
        fi
        sleep 0.25
    done
    printf '  PASS: %s (held for %ds)\n' "$label" "$duration"
    : "${PASS:=0}"
    PASS=$(( PASS + 1 ))
    return 0
}
