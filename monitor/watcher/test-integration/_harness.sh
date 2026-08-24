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
        exit 77   # SKIP, not PASS (your-org/nexus-code#568 A6)
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        echo "skipped: $(basename "${0}") (tmux not on PATH)"
        exit 77   # SKIP, not PASS (your-org/nexus-code#568 A6)
    fi
}

# NOTE (your-org/nexus-code#568 A8, and why there is no capability-probe helper
# here). An earlier revision of this branch added `harness_require_capability`
# with a `window_absent_classification` probe, so that scenarios asserting the
# killed-window → `state=absent` transition would SKIP on a host that does not
# produce it rather than sit permanently red. That probe was WRONG, and deleting
# it is the fix.
#
# The transition it probed for does not exist and should not. `pane-state.sh`
# exits 3 with `no such tmux window` for a window that does not resolve — issue
# `#140`, deliberately, because old tmux writes its error to stdout while tmux
# 3.x silently falls back to the session's ACTIVE window and returns valid data
# for the WRONG one. Refusing to answer is the only safe response, and it is not
# a substrate deficiency to be skipped around.
#
# The genuine `absent` case — the one production actually produces — is a window
# kept alive by `remain-on-exit on` (`spawn-worker.sh`) whose claude has exited.
# `test-graceful-exit-relaunch.sh` already covers exactly that and is green.
# "The window is gone" is asserted against `list-windows`, as
# `test-wrapup-retain-close.sh` phase 6 does. Both idioms already existed in
# this band; the two scenarios that were failing simply used neither.
#
# The general lesson is worth more than the helper was: a capability probe built
# from a failure's DESCRIPTION rather than from its observed assertions will
# encode the misconception instead of the substrate. Probe by running the thing.

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

    # The fake nexus needs the resolver, because production code under test
    # sources `$NEXUS_ROOT/monitor/_claude-bin.sh` and the harness exports
    # NEXUS_ROOT=$HARNESS_DIR (your-org/nexus-code#764). Without it,
    # `monitor/claude-loop.sh` dies at its source line and then on `set -u`
    # ("CLAUDE_BIN: unbound variable"), so the window it was spawned into never
    # materialises.
    cp "$HARNESS_REPO_ROOT/monitor/_claude-bin.sh" "$HARNESS_DIR/monitor/_claude-bin.sh"

    # Stub claude, launched so the pane process really reports
    # `comm=claude`.
    #
    # your-org/nexus-code#554: copying the stub to `$HARNESS_BIN/claude`
    # does NOT achieve that. `/proc/<pid>/comm` is seeded from the
    # basename of the EXECUTABLE the kernel loads — not from argv[0] and
    # not from the script's name. For a `#!/usr/bin/env bash` script the
    # kernel loads bash, so comm is `bash` for every pane, and
    # `pane-state.sh::_pane_has_live_claude` (which matches comm against
    # `claude|claude-code`) could never match. Every scenario under
    # test-integration/ failed on pristine dev for exactly this reason.
    #
    # Fix: copy the bash BINARY to a file literally named `claude` (in a
    # sibling dir that is NOT on PATH), and keep the PATH entry as a thin
    # wrapper that `exec`s it with the stub as its script. The wrapper is
    # replaced by the exec, so the surviving pane process's executable is
    # the file named `claude` → comm=claude, and the production gate
    # matches. Keeping a PATH-resolvable `claude` that needs no arguments
    # means every existing call site still works unchanged — bare `claude`
    # (monitor/claude-loop.sh), `$HARNESS_BIN/claude`, and PATH lookups
    # from inside tmux panes alike. No production code bends to the test.
    HARNESS_REALBIN="$HARNESS_DIR/.realbin"
    mkdir -p "$HARNESS_REALBIN"
    cp "$HARNESS_STUB_CLAUDE_SRC" "$HARNESS_BIN/stub-claude.sh"
    cp "$(command -v bash)" "$HARNESS_REALBIN/claude"
    cat > "$HARNESS_BIN/claude" <<CLAUDEWRAP
#!/usr/bin/env bash
exec "$HARNESS_REALBIN/claude" "$HARNESS_BIN/stub-claude.sh" "\$@"
CLAUDEWRAP
    chmod +x "$HARNESS_BIN/claude" "$HARNESS_BIN/stub-claude.sh" \
             "$HARNESS_REALBIN/claude"

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
    # the socket; -f overrides the user's tmux.conf so a peculiar
    # personal config (status-bar plugins, hooks) can't perturb the
    # scenario.
    #
    # `-f /dev/null` alone was NOT enough (your-org/nexus-code#555).
    # default-shell is a compiled-in default derived from the invoking
    # user, so every pane — including each harness_spawn_worker window —
    # was still built from the operator's LOGIN shell and ran its whole
    # rc chain (Lmod/lua, conda, linuxbrew) before exec'ing the stub
    # claude. Measured 4.6-13.8 s for `zsh -lc true` on a loaded sandbox
    # host vs 0.00 s for `sh -c true`, against scenario predicates that
    # wait 3-10 s: five integration scenarios failed on pristine dev with
    # "predicate never satisfied", timing out before the stub had rendered
    # its first frame. th_tmux_fixture_conf pins a bare rc-less sh.
    declare -F th_tmux_fixture_conf >/dev/null 2>&1 \
        || . "$HARNESS_REPO_ROOT/monitor/watcher/_test_helpers.sh"

    # your-org/nexus-code#764. This harness pins NOTHING ahead of PATH: it sets
    # no CLAUDE_BIN and creates no $HARNESS_DIR/node_modules/.bin/claude, so
    # `_claude-bin.sh` reaches step 3 and `$HARNESS_BIN/claude` wins only if
    # nothing re-fronts ahead of it. On an operator box `locals-env.sh` does
    # exactly that, via BASH_ENV, for every non-interactive bash — so the stub
    # loses and a REAL, billed session is spawned into the scenario. Assert the
    # resolution here, once, on behalf of every scenario that calls harness_setup.
    th_require_stub_claude "$HARNESS_DIR" "$HARNESS_BIN"

    th_tmux_fixture_conf "$HARNESS_DIR/tmux.conf"
    "$HARNESS_TMUX" -f "$HARNESS_DIR/tmux.conf" new-session -d \
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
        "$HARNESS_TMUX" kill-server 2>/dev/null || true   # tmux-scoped: HARNESS_TMUX is the -L-injecting wrapper, guarded -n/-x above
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

# ---- spawn shapes ---------------------------------------------------------
#
# TWO shapes exist in production, and they differ in exactly the property every
# `absent` decision reads: WHAT IS UNDER `pane_pid`, AND WHEN
# (your-org/nexus-code#789).
#
#   command  `tmux new-window … "<cmd>"`. tmux execs <cmd> AS the pane process,
#            so the pane root is the launcher/agent from t=0 and tmux's
#            `#{pane_dead}` flips to 1 the instant it exits. This is
#            `_respawn.sh:_respawn_spawn_window`, which passes the generated
#            /tmp/nexus-respawn-launch-*.sh as the new-window command — and it
#            is the shape `#780`'s `pane_dead` arm fires against.
#
#   worker   `tmux new-window -d` with NO command, then `send-keys <launcher>`.
#            tmux execs `default-shell`, so the pane root is a SHELL that
#            outlives everything, `#{pane_dead}` stays 0 forever, and the agent
#            only becomes a descendant once that shell has finished its rc chain
#            and read the keys. This is `spawn-worker.sh` (bare `new-window` at
#            :1838, `send-keys` at :1866) — every worker on the board.
#
# Until #789 this harness modelled ONLY `command`, which is why the boot-window
# `absent` of `#777` was not merely untested but UNTESTABLE here: the shape that
# produces it never occurred. Both shapes are real; a fix that replaced one with
# the other would have traded coverage rather than added it, so `command` stays
# the default and every pre-existing scenario is byte-identical under it.
#
# Scenarios opt in per call (`harness_spawn_worker_shape worker …`) or globally
# (`HARNESS_SPAWN_SHAPE=worker`), the latter so an existing scenario can be
# driven through both without editing each call site.
HARNESS_SPAWN_SHAPE="${HARNESS_SPAWN_SHAPE:-command}"

# Seconds the `worker`-shape launcher spends in its preamble before starting the
# stub. Production's preamble is the fail-closed shim/nproc guard block, measured
# at ~2.2-2.9 s and reported at 20-30 s on a loaded box; throughout it the pane
# has a live launcher and NO claude. 0 keeps scenarios that don't care fast.
HARNESS_LAUNCHER_PREAMBLE_SECONDS="${HARNESS_LAUNCHER_PREAMBLE_SECONDS:-0}"

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
# Uses $HARNESS_SPAWN_SHAPE (default `command`) — see the block above.
harness_spawn_worker() {
    harness_spawn_worker_shape "$HARNESS_SPAWN_SHAPE" "$@"
}

# harness_spawn_worker_shape <command|worker> <name> [ENV=V ...]
#
# Implementation detail shared by both shapes: the stub is invoked by its
# absolute path ($HARNESS_BIN/claude). tmux's `setenv -g` only seeds the global
# env block read at new-session time, NOT subsequent new-windows on
# an existing session, so `claude` on PATH from setenv -g is
# unreliable. That wrapper execs the renamed bash binary, which is
# what makes /proc/<pid>/comm read `claude` so
# `pane-state.sh::_pane_has_live_claude` recognises the process tree
# (your-org/nexus-code#554 — argv[0] alone does NOT set comm).
harness_spawn_worker_shape() {
    local shape="$1" name="$2"; shift 2
    local env_assignments=("$@")
    local kv

    case "$shape" in
        command|worker) ;;
        *)
            # Fail LOUD rather than silently falling back to a shape the caller
            # did not ask for: a scenario that believes it is exercising the
            # worker shape while running the command one reports coverage it
            # does not have, which is the whole defect #789 names.
            echo "harness_spawn_worker_shape: unknown shape '$shape' (want command|worker)" >&2
            return 2
            ;;
    esac

    if [[ "$shape" == command ]]; then
        local cmd="exec env"
        for kv in "${env_assignments[@]}"; do
            cmd+=" $(printf '%q' "$kv")"
        done
        cmd+=" $(printf '%q' "$HARNESS_BIN/claude")"
        harness_tmux new-window -d \
            -t "${HARNESS_SESSION}:" \
            -n "$name" \
            -c "$HARNESS_DIR" \
            "$cmd"
    else
        # Branch on the VALUE, never on the STATUS (your-org/nexus-code#622).
        # `harness_open_worker_window` ends in `list-windows | awk '…; exit'`,
        # an EARLY-EXIT READER: awk closes the pipe on the first match, tmux
        # gets EPIPE, and under `pipefail` (set at the top of this file) the
        # pipeline's status becomes the writer's 141 — so `|| return` here
        # aborted a spawn that had in fact succeeded, non-deterministically,
        # depending only on whether tmux had finished writing. The window index
        # it prints is the honest signal; an empty one is the failure.
        local _idx
        _idx=$(harness_open_worker_window "$name")
        [[ -n "$_idx" ]] || return 3
        harness_send_worker_launcher "$name" "${env_assignments[@]+${env_assignments[@]}}" || return
    fi

    harness_tmux list-windows -t "$HARNESS_SESSION" \
        -F '#{window_name} #{window_index}' \
        | awk -v n="$name" '$1==n {print $2; exit}'
}

# ---- worker shape, split so the BOOT WINDOW is probeable ------------------
#
# `harness_spawn_worker_shape worker` runs these back to back. A scenario that
# wants to classify a pane DURING its boot window calls them separately:
#
#   idx=$(harness_open_worker_window w)      # window exists; pane is a bare
#   …assert on pane-state here…              #   shell with nothing under it
#   harness_send_worker_launcher w K=V       # the launcher starts
#
# Deliberately an explicit two-phase API rather than a `sleep`-before-send-keys
# knob. In production the interval is the pane shell's rc chain — measured
# 4.6-13.8 s for `zsh -lc true` on this loaded host (see harness_setup's
# `#555` note), which is why `#777` was 3-in-5 reproducible there. Reproducing
# it here with a timer would make every assertion a race against ambient load on
# a box that routinely sits at 34+ on 36 cores; holding the phase open instead
# makes the same window arbitrarily wide and perfectly deterministic. The
# property under test is the CLASSIFICATION of a bare pane, not how long tmux
# takes to get out of it.

# harness_open_worker_window <name> -> window index on stdout
#
# Phase 1 of the worker shape: spawn-worker.sh:1838's `new-window -d` carrying no
# launcher, plus the three window options it sets at :1848-:1864. The pane hosts
# a SHELL and NOTHING else from here until the launcher is sent — the exact shape
# `#777`'s false `absent` came from, and the one this harness could not express
# before `#789`.
#
# WHY `exec <sh>` RATHER THAN A LITERALLY BARE `new-window`. Production passes no
# command and tmux supplies `default-shell` (live server: `/usr/bin/zsh`,
# `default-command ""`), yielding ONE process with no children. A bare
# `new-window` on this harness's server does not reproduce that: `#555` pins
# `default-command` to an rc-less `sh` — deliberately, because the operator's
# LOGIN shell costs a measured 4.6-13.8 s of rc chain here — and tmux runs a set
# `default-command` as `default-shell -c <it>`, so the pane comes up as `sh`
# with a second `sh` CHILD. That doubling is invisible to a scenario reading
# `state=`, and fatal to what this phase exists to test: the child satisfies
# `_pane_has_live_descendant`, so the classifier takes the descendant arm and the
# `#777` grace arm — the one that actually fired in production — is never
# reached. `exec` collapses the pair back to a single shell.
#
# So the divergence from production is one we CHOSE and it is the rc chain, not
# the process shape: pane root is a lone shell with no descendants, exactly as
# `spawn-worker.sh` leaves it once zsh reaches its prompt. Measured on this host:
# bare `new-window` -> `sh` + 1 child; `exec /bin/sh` -> `sh`, 0 children.
harness_open_worker_window() {
    local name="$1" wid sh
    sh=$(command -v sh 2>/dev/null) || sh=/bin/sh
    wid=$(harness_tmux new-window -P -F '#{window_id}' -d \
        -t "${HARNESS_SESSION}:" \
        -n "$name" \
        -c "$HARNESS_DIR" \
        "exec $sh")
    if [[ -z "$wid" ]]; then
        echo "harness_open_worker_window: new-window returned no window id for '$name'" >&2
        return 3
    fi
    # spawn-worker.sh:1848. Without it the pane VANISHES when the stub exits,
    # and a scenario asserting the post-exit classification would be asserting
    # against a window that no longer resolves (pane-state.sh exits 3, `#140`)
    # rather than against `absent`.
    harness_tmux set-window-option -t "$wid" remain-on-exit on 2>/dev/null || true
    harness_tmux set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
    harness_tmux set-window-option -t "$wid" allow-rename off 2>/dev/null || true
    harness_tmux list-windows -t "$HARNESS_SESSION" \
        -F '#{window_name} #{window_index}' \
        | awk -v n="$name" '$1==n {print $2; exit}'
}

# harness_send_worker_launcher <name> [ENV=V ...]
#
# Phase 2: write the generated launcher and `send-keys` it, as
# spawn-worker.sh:1866 does. Honours $HARNESS_LAUNCHER_PREAMBLE_SECONDS.
harness_send_worker_launcher() {
    local name="$1"; shift
    local env_assignments=("$@")
    local kv
    local launcher="$HARNESS_DIR/spawn-launcher-${name}.$$.sh"
    {
        printf '#!/bin/bash\n'
        # Stands in for the fail-closed shim/nproc guard block: a live launcher
        # process under the pane shell with no claude anywhere in the tree.
        printf 'sleep %q\n' "$HARNESS_LAUNCHER_PREAMBLE_SECONDS"
        # NOT `exec`. spawn-worker.sh's default launcher runs
        # `"$CLAUDE_BIN" … "$prompt"` as a CHILD, so a production worker sits
        # BELOW both the pane shell and the launcher — which is what
        # `_lib.sh:_nexus_pid_tree_has_agent` documents ("workers sit at depth 2
        # under `-zsh` -> launcher") and walks. An `exec` here would collapse
        # that and quietly re-model something production does not do.
        printf 'env'
        for kv in "${env_assignments[@]+${env_assignments[@]}}"; do
            printf ' %q' "$kv"
        done
        printf ' %q\n' "$HARNESS_BIN/claude"
    } > "$launcher"
    chmod +x "$launcher"

    local wid
    wid=$(harness_tmux list-windows -t "$HARNESS_SESSION" \
        -F '#{window_name} #{window_id}' \
        | awk -v n="$name" '$1==n {print $2; exit}')
    if [[ -z "$wid" ]]; then
        echo "harness_send_worker_launcher: no window named '$name'" >&2
        return 3
    fi
    harness_tmux send-keys -t "$wid" "$launcher" Enter
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
    # `max` is in UNLOADED seconds; th_deadline scales it for the
    # parallelism this run competes with (your-org/nexus-code#558). These
    # scenarios drive a real tmux server, so they are the most
    # contention-sensitive tests in the tree.
    local deadline=$(( $(date +%s) + $(th_deadline "$max") ))
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
