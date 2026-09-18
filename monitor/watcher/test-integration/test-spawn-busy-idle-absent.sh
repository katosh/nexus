#!/usr/bin/env bash
# Integration scenario: spawn → busy → idle → absent.
#
# The narrow but valuable subset of the issue body's first listed
# scenario ("Spawn → busy → wrap-up → idle → retain → close"). The
# wrap-up + retain + close transitions touch `monitor/ng wrap-up`
# and the orchestrator's action-log policy — those are Pass B; Pass
# A lands the tmux + stub-claude infrastructure and exercises the
# three transitions that have regressed the most often in
# production:
#
#   1. busy spinner present   → state=busy   (NOT absent)
#   2. spinner clears, idle   → state=idle
#   3. claude exits, window
#      retained by remain-on-exit
#                             → state=absent
#   4. tmux kill-window       → gone from `list-windows`; pane-state
#                               REFUSES to classify it (rc=3, `#140`)
#
# Each transition catches a class of regression catalogued in
# your-org/nexus-code#72:
#   - The brand-new-window `pane-absent` false-positive that
#     PR #55 was meant to fix and that the operator session of
#     2026-05-12 still observed ~10 times.
#   - The empty-input misclassification when the spinner clears
#     in the same render cycle as the chevron repaints.
#   - The genuine `absent` case we MUST keep correctly detecting
#     so a dead worker still triggers respawn. Note what "genuine"
#     means: production keeps the window (`remain-on-exit on`) and
#     loses the claude process. A window that has been REMOVED is a
#     different condition entirely, asserted against `list-windows`
#     — `pane-state.sh` will not classify a window it cannot resolve
#     (`#140`), because tmux 3.x would otherwise answer for the
#     session's active window instead.
#
# BOTH SPAWN SHAPES (your-org/nexus-code#789). Every probe below runs twice, once
# per shape, because the two differ in exactly the property each `absent`
# decision reads:
#
#   command  pane root IS the agent (`_respawn.sh`). When it exits tmux flips
#            `#{pane_dead}` to 1, and `pane-state.sh`'s ladder settles on that
#            first-party signal.
#   worker   pane root is a SHELL that outlives the agent (`spawn-worker.sh`).
#            `#{pane_dead}` stays 0 forever, so the SAME transition has to be
#            adjudicated by the process-tree + boot-grace arms instead.
#
# Before `#789` this file ran only the first, and its probe-4 comment said so out
# loud — "harness_spawn_worker runs the stub via `exec`, so the pane's process IS
# the stub claude". That is the assumption `#777` hid behind: the shape every
# worker on the board actually has was not merely untested here, it could not be
# expressed. Running the identical probes under both is the point; a shape that
# needs a different POKE (which pid to kill) still has to reach the same VERDICT.
#
# Run: RUN_INTEGRATION=1 bash monitor/watcher/test-integration/test-spawn-busy-idle-absent.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_harness.sh
. "$_self_dir/_harness.sh"
# shellcheck source=../_test_helpers.sh
. "$_self_dir/../_test_helpers.sh"

harness_skip_if_disabled
harness_setup

echo "=== harness ==="
echo "  HARNESS_DIR=$HARNESS_DIR"
echo "  HARNESS_SESSION=$HARNESS_SESSION"
echo "  HARNESS_SOCKET=$HARNESS_SOCKET"

# Predicate: pane-state.sh emits a `state=<x>` line; we grep for the
# expected state. Defined as a function (not an inline bash -c) so
# wait_for can invoke it without re-sourcing _harness.sh in a child
# shell — shell-function inheritance does NOT cross `bash -c`.
#
# `win` is set per shape by run_shape below.
pane_state_is() {
    local expected="$1"
    local out
    out=$(PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${win}" 2>/dev/null) || return 1
    grep -q "state=${expected}" <<<"$out"
}

# Same, with the `#777` boot grace pinned. Probe 4's worker half needs it: the
# production default is 90 s and the scenario's pane is ~30 s old when its agent
# is killed, so an unpinned assertion would either wait a minute for a fact it
# can establish in three seconds, or — far worse — be written to a deadline
# short enough that it passes for the WRONG reason on a slow host.
pane_state_is_at_grace() {
    local grace="$1" expected="$2" out
    out=$(NEXUS_PANE_BOOT_GRACE_SECONDS="$grace" PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${win}" 2>/dev/null) || return 1
    grep -q "state=${expected}" <<<"$out"
}

window_is_listed() {
    grep -qx "$win" <<<"$(harness_tmux list-windows -t "$HARNESS_SESSION" -F '#{window_index}' 2>/dev/null)"
}
window_is_gone() { ! window_is_listed; }

# The one thing that legitimately differs per shape: WHICH pid hosts the agent.
#
# In the `command` shape the pane process IS the stub, so pane_pid is the target.
# In the `worker` shape the pane process is a shell that must SURVIVE — killing
# it would destroy the very condition under test (a live pane whose agent died),
# and would silently convert probe 4 into a `#{pane_dead}` assertion, i.e. back
# into the command shape. So walk the tree for the `claude` pid instead.
#
# Exact pid, never a pattern kill.
_agent_pid_for_shape() {
    local shape="$1" pane_pid
    pane_pid=$(harness_tmux display-message -p -t "${HARNESS_SESSION}:${win}" '#{pane_pid}' 2>/dev/null)
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    if [[ "$shape" == command ]]; then
        printf '%s' "$pane_pid"
        return 0
    fi
    local depth queue next pid
    queue="$pane_pid"
    for depth in 0 1 2 3 4 5; do
        [[ -n "${queue// /}" ]] || return 1
        for pid in $queue; do
            # IDENTITY, NOT NAME (your-org/nexus-code#908). `comm` is the
            # invocation name: the same binary reads `claude` through the
            # node_modules/.bin symlink and `claude.exe` by real path, and
            # cc-harness's own gate sets CLAUDE_BIN to a staged real path —
            # so an exact `== claude` here waits forever on the very
            # configuration the gate runs under.
            if [[ "$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')" == claude \
               || "$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')" == claude.exe \
               || "$(readlink -f "/proc/$pid/exe" 2>/dev/null)" == *claude-code* ]]; then
                printf '%s' "$pid"; return 0
            fi
        done
        next=""
        for pid in $queue; do next+=" $(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')"; done
        queue=$(printf '%s' "$next" | tr -s ' ')
    done
    return 1
}

run_shape() {
    local shape="$1"
    echo
    echo "############################################################"
    echo "### spawn shape: $shape"
    echo "############################################################"

    # Spawn the worker. 4 s of busy spinner, then idle, then hold idle
    # for 25 s — plenty of buffer for the assertions below.
    echo
    echo "=== spawn ($shape) ==="
    win=$(harness_spawn_worker_shape "$shape" "test-worker-$shape" \
        "STUB_CLAUDE_BUSY_SECONDS=4" \
        "STUB_CLAUDE_HOLD_SECONDS=25")
    if ! [[ "$win" =~ ^[0-9]+$ ]]; then
        echo "  FAIL: spawn returned non-numeric window index: $win" >&2
        FAIL=$(( FAIL + 1 ))
        return 1
    fi
    echo "  spawned at window=$win"

    # The shapes must actually BE different, or running the suite twice proves
    # nothing. Pin the discriminating fact directly: what is at the pane root.
    local pane_comm
    pane_comm=$(ps -o comm= -p "$(harness_tmux display-message -p \
        -t "${HARNESS_SESSION}:${win}" '#{pane_pid}')" 2>/dev/null | tr -d '[:space:]')
    if [[ "$shape" == command ]]; then
        assert_eq "[$shape] pane root is the agent itself" "$pane_comm" "claude"
    else
        if [[ -n "$pane_comm" && "$pane_comm" != claude ]]; then
            echo "  PASS: [$shape] pane root is a shell that outlives the agent ($pane_comm)"
            PASS=$(( PASS + 1 ))
        else
            echo "  FAIL: [$shape] pane root should NOT be the agent, got '$pane_comm' —" >&2
            echo "        this shape has silently collapsed into the command shape" >&2
            FAIL=$(( FAIL + 1 ))
        fi
    fi

    # Probe 1: pane-state.sh should see `state=busy` within ~3 s. Allow
    # 6 s — the first capture often hits the gap between `tmux
    # new-window` returning and the stub's first `printf` reaching the
    # pty buffer.
    wait_for "[$shape] pane-state reports busy" 6 -- pane_state_is busy

    # Probe 2: hold the assertion for 2 s. Catches the post-`#55`
    # residual where `state=absent` flapped mid-busy.
    hold_false "[$shape] pane-state never flips to absent during busy" 2 -- pane_state_is absent

    # Probe 3: after the 4 s busy window, the stub transitions to idle.
    # Allow up to 8 s — the spinner has to stop, the idle render has
    # to land, and the next pane-state poll has to see it.
    wait_for "[$shape] pane-state reports idle after spinner clears" 8 -- pane_state_is idle

    # Probe 4: the genuine `absent` transition — claude dies, the WINDOW
    # SURVIVES. That is what production produces: `spawn-worker.sh` sets
    # `remain-on-exit on` precisely so a finished worker's output stays
    # readable, and its own comment records the consequence ("the pane shows
    # `[exited]` … pane-state.sh classifies that as `absent`, which is fine").
    #
    # your-org/nexus-code#568: this probe used to `kill-window` and assert
    # `state=absent`, which is why it had been red on this host. That is a
    # contract `#140` deliberately RETIRED — `pane-state.sh` exits 3 with
    # `no such tmux window` for a window that does not resolve, because tmux
    # 3.x otherwise falls back to the session's active window and reports the
    # WRONG window's state. The scenario was asserting pre-`#140` behaviour,
    # and it was classified as an environmental tmux limitation on the
    # strength of that assertion. Probes 1-3 passed all along; only this one
    # failed. Both halves are now pinned separately below.
    #
    # In the `worker` shape this probe is ALSO the deferral-lapse proof: the
    # verdict has to travel unknown → absent on its own, through the
    # boot-grace and live-descendant arms, with `#{pane_dead}` pinned at 0
    # throughout. A grace that never lapsed would hang here rather than pass.
    echo
    echo "=== [$shape] claude exits, window retained (production remain-on-exit path) ==="
    harness_tmux set-window-option -t "${HARNESS_SESSION}:${win}" remain-on-exit on

    local agent_pid
    if agent_pid=$(_agent_pid_for_shape "$shape"); then
        kill -9 "$agent_pid" 2>/dev/null || true
        echo "  killed agent pid $agent_pid"
    else
        echo "  FAIL: [$shape] could not resolve the agent pid for window $win" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    if [[ "$shape" == command ]]; then
        wait_for "[$shape] pane-state reports absent once claude exits (window retained)" 5 \
            -- pane_state_is absent
    else
        # THE DEFERRAL, BOTH HALVES. The worker shape reaches `absent` only
        # through the boot-grace arm, so assert that the grace ENGAGES and that
        # it LAPSES. Asserting only the first would be satisfied by a classifier
        # that had made the pane permanently unreapable — trading `#777`'s kill
        # hazard for its mirror image, which is the failure mode the fix must
        # not buy.
        #
        # Engages: this pane is ~30 s old, well inside the 90 s default.
        hold_false "[$shape] a young pane whose agent just died defers (never absent at default grace)" 3 \
            -- pane_state_is absent
        # Lapses: same pane, same instant, grace pinned past its age. If the
        # deferral were permanent this reddens instead of hanging forever.
        wait_for "[$shape] the deferral LAPSES — absent once the grace is past (window retained)" 10 \
            -- pane_state_is_at_grace 3 absent
    fi

    # `#{pane_dead}` distinguishes the shapes at the exact moment that matters,
    # so pin which arm of the ladder each verdict came from. Without this the
    # two runs could both be passing through the same branch.
    local dead
    dead=$(harness_tmux display-message -p -t "${HARNESS_SESSION}:${win}" '#{pane_dead}' 2>/dev/null)
    if [[ "$shape" == command ]]; then
        assert_eq "[$shape] absent was backed by tmux's own pane_dead" "$dead" "1"
    else
        assert_eq "[$shape] absent was reached with pane_dead=0 (process-tree arm)" "$dead" "0"
    fi

    # The retained window must still be listed — otherwise the assertion
    # above would be indistinguishable from the window having vanished.
    if window_is_listed; then
        echo "  PASS: [$shape] dead pane's window is still listed (remain-on-exit held)"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: [$shape] dead pane's window vanished — remain-on-exit did not hold," >&2
        echo "        so the absent assertion above proves nothing" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    # Probe 5: now remove the window for real. "The window is gone" is
    # asserted against `list-windows` — the same idiom
    # `test-wrapup-retain-close.sh` phase 6 uses — NOT against pane-state,
    # which by `#140` refuses to classify an unresolvable window at all.
    echo
    echo "=== [$shape] kill-window ==="
    harness_tmux kill-window -t "${HARNESS_SESSION}:${win}"

    wait_for "[$shape] window absent from tmux list-windows after kill-window" 3 -- window_is_gone

    # Pin the `#140` contract itself, so a future change that reverts it to
    # "report absent for a window that doesn't resolve" goes red here rather
    # than silently reintroducing the tmux-3.x wrong-window misread.
    local ps_out ps_rc
    ps_out=$(PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${win}" 2>&1); ps_rc=$?
    assert_eq "[$shape] pane-state exits 3 for a window that no longer resolves (#140)" "$ps_rc" 3
    case "$ps_out" in
        *"no such tmux window"*)
            echo "  PASS: [$shape] pane-state names the unresolvable window instead of classifying it"
            PASS=$(( PASS + 1 )) ;;
        *)
            echo "  FAIL: [$shape] expected 'no such tmux window' on stderr, got: $ps_out" >&2
            FAIL=$(( FAIL + 1 )) ;;
    esac
}

# The boot window, which ONLY the worker shape can express
# (your-org/nexus-code#789). Phase 1 of the split API leaves the pane holding a
# bare shell and nothing else — the state `#777` misclassified as `absent` for
# ~20-30 s of every production spawn. Held open explicitly rather than raced
# against, so this assertion is deterministic on a loaded host.
run_boot_window() {
    echo
    echo "############################################################"
    echo "### boot window (worker shape only)"
    echo "############################################################"
    win=$(harness_open_worker_window boot-window)
    if ! [[ "$win" =~ ^[0-9]+$ ]]; then
        echo "  FAIL: harness_open_worker_window returned non-numeric index: $win" >&2
        FAIL=$(( FAIL + 1 )); return 1
    fi

    local pane_pid kids
    pane_pid=$(harness_tmux display-message -p -t "${HARNESS_SESSION}:${win}" '#{pane_pid}')
    kids=$(pgrep -P "$pane_pid" 2>/dev/null | tr -d '[:space:]')
    # The precondition. If the pane has descendants the classifier takes the
    # live-descendant arm and this phase is testing something else entirely.
    assert_eq "boot pane has NOTHING under it (the #777 condition)" "${kids:-none}" "none"
    assert_eq "boot pane is not dead" \
        "$(harness_tmux display-message -p -t "${HARNESS_SESSION}:${win}" '#{pane_dead}')" "0"

    # THE assertion: a live pane the classifier cannot vouch for must not
    # authorise a kill. `unknown` is off bk_pane_kill_authorized's allowlist;
    # `absent` is on it.
    local out state
    out=$(PATH="$HARNESS_BIN:$PATH" "$HARNESS_REPO_ROOT/monitor/pane-state.sh" \
        "${HARNESS_SESSION}:${win}" 2>/dev/null)
    state=$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$out")
    assert_eq "booting pane is NOT absent (#777)" "$state" "unknown"

    # Negative control. Same pane, same instant, grace pinned to 0 — the
    # pre-#780 configuration must reach `absent`. Without this the assertion
    # above would also pass if the grace arm were unreachable, or if `absent`
    # had become unreachable altogether, and this suite would be asserting a
    # constant.
    local out0 state0
    out0=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 PATH="$HARNESS_BIN:$PATH" \
        "$HARNESS_REPO_ROOT/monitor/pane-state.sh" "${HARNESS_SESSION}:${win}" 2>/dev/null)
    state0=$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$out0")
    assert_eq "with grace=0 the same pane DOES reach absent (control: the arm is live)" \
        "$state0" "absent"

    # Phase 2 closes the boot window; the pane must then classify normally.
    harness_send_worker_launcher boot-window "STUB_CLAUDE_HOLD_SECONDS=25"
    wait_for "boot window closes once the launcher lands" 15 -- pane_state_is idle
    harness_tmux kill-window -t "${HARNESS_SESSION}:${win}" 2>/dev/null || true
}

run_boot_window
for _shape in command worker; do
    run_shape "$_shape"
done

# Sanity dump for debugging. Cheap when everything passes; precious
# when a future regression flips one of the assertions.
if (( FAIL > 0 )); then
    echo
    echo "=== diagnostic dump (failure path) ==="
    echo "--- list-windows ---"
    harness_tmux list-windows -t "$HARNESS_SESSION" \
        -F '#{window_index}: #{window_name} active=#{window_active}' || true
fi

th_summary_and_exit
