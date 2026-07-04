#!/usr/bin/env bash
# Target-window-absent decision tree (issue #174).
#
# Encapsulates the per-observation work the watcher does when a target
# window probe returns rc=2 (orchestrator window missing):
#
#   1. Increment the missing_target_polls streak counter.
#   2. Harvest any prior async respawn via `_respawn_async_reap` and
#      fire slow-grind escalation if the consec-counter crossed
#      threshold inside the subshell (issue #171 reap surface).
#   3. Gate the next respawn on:
#        a. AGENT_MISSING_RESPAWN_DELAY (per-streak threshold).
#        b. RESPAWN_SLOW_GRIND_TRIPPED cooldown (issue #77).
#        c. _respawn_loop_check crash-loop guard.
#        d. _respawn_verify_target_absent re-verification (incident
#           2026-06-02): fresh window probe + orchestrator-process
#           pane scan + liveness-signal check at the moment of
#           decision. A transient absent reading must never spawn a
#           duplicate orchestrator.
#   4. Launch `_respawn_async_launch` if all gates allow; reset the
#      streak counter tentatively (the in-flight subshell will reap
#      next tick and confirm via the consec-counter file).
#
# Why a separate file: pre-#174 this logic lived inline in the
# watcher's main poll loop. Hoisting it lets the `target_window`
# scheduler probe (at 2 s cadence) call it directly — revival
# latency is bounded by probe cadence, not by whatever data-gather
# body was bundled with the absence check.
#
# Source contract: callers provide the following script-scope globals
# (defined in main.sh at top level — not function-local):
#
#   missing_target_polls         in/out — the streak counter
#   missing_target_since         in/out — epoch of the streak's first
#                                absent observation (0 = no streak).
#                                Anchors the re-verify's liveness-
#                                signal comparison.
#   TARGET                       target window name
#   AGENT_MISSING_RESPAWN_DELAY  config knob (default 3)
#   RESPAWN_SLOW_GRIND_TRIPPED   stamp file path
#   RESPAWN_SLOW_GRIND_COOLDOWN  config knob (seconds)
#   RESPAWN_CONSEC_COUNTER       counter file path
#   RESPAWN_CONSEC_LIMIT         config knob
#   RESPAWN_HISTORY              history file path
#   RESPAWN_LOOP_WINDOW          config knob (seconds)
#   RESPAWN_LOOP_LIMIT           config knob
#   RESPAWN_TRIPPED              stamp file path
#   _monitor_dir                 monitor/ dir (for ng log-action)
#
# Functions called (all from _respawn.sh / _respawn_async.sh / main.sh):
#
#   _respawn_async_reap          harvests sidecar .rc (issue #171)
#   _respawn_async_in_flight     kill -0 + .rc check
#   _respawn_async_launch        backgrounds respawn_agent
#   _respawn_consec_check        slow-grind threshold-crossing
#   _respawn_consec_reset        clears consec-counter file
#   _respawn_loop_check          crash-loop sliding-window guard
#   _respawn_verify_target_absent  pre-launch re-verification
#   log                          watcher logger (timestamps to LOGFILE)

# _watcher_handle_target_absent_observation
#
# Run one absent-observation pass through the decision tree. Idempotent
# in the sense that calling it repeatedly while a respawn is in flight
# is safe — the `_respawn_async_in_flight` guard ensures only one
# subshell at a time. Returns rc=0 always (caller doesn't branch on
# this; the decision is observable via in-flight + missing_target_polls
# state).
_watcher_handle_target_absent_observation() {
    missing_target_polls=$(( missing_target_polls + 1 ))
    # Anchor the streak's start so the re-verify gate below can tell
    # whether the orchestrator produced liveness signals WHILE its
    # window was reading absent (= alive, do not respawn).
    if (( missing_target_polls == 1 )); then
        missing_target_since=$(date +%s)
    fi

    # Issue #171 reap step. The consec-counter file was updated by
    # the previous async respawn's subshell when it returned; check
    # whether that crossed the slow-grind threshold and notify once
    # on the transition. Mirrors the pre-#171 sync path's post-
    # `if respawn_agent ...; then ... else ... fi` else branch.
    local reap_rc
    if reap_rc=$(_respawn_async_reap); then
        if (( reap_rc == 0 )); then
            log "respawn-agent (async): completed rc=0"
        else
            log "respawn-agent (async): completed rc=$reap_rc"
            local sg_reason
            if sg_reason=$(_respawn_consec_check "$RESPAWN_CONSEC_COUNTER" "$RESPAWN_CONSEC_LIMIT"); then
                if [[ ! -f "$RESPAWN_SLOW_GRIND_TRIPPED" ]]; then
                    date -Is > "$RESPAWN_SLOW_GRIND_TRIPPED"
                    log "slow-grind tripped: $sg_reason"
                    if command -v sandbox-notify >/dev/null 2>&1; then
                        sandbox-notify "watcher: ${sg_reason}; pausing respawns for ${RESPAWN_SLOW_GRIND_COOLDOWN}s" \
                            >/dev/null 2>&1 || true
                    fi
                    if [[ -x "$_monitor_dir/ng" ]]; then
                        "$_monitor_dir/ng" log-action watcher \
                            --event respawn-slow-grind-tripped \
                            --note "$sg_reason" \
                            >/dev/null 2>&1 || true
                    fi
                fi
            fi
        fi
    fi

    if (( missing_target_polls <= AGENT_MISSING_RESPAWN_DELAY )); then
        log "target window '${TARGET}' absent (poll-check, streak=${missing_target_polls}, delay=${AGENT_MISSING_RESPAWN_DELAY})"
        return 0
    fi

    # Slow-grind cooldown gate (issue #77). If the consec-failure
    # guard already tripped, suppress respawn attempts until the
    # cooldown elapses, then re-arm by clearing the stamp + counter.
    local slow_grind_skip=0
    if [[ -f "$RESPAWN_SLOW_GRIND_TRIPPED" ]]; then
        local sg_mtime sg_age
        sg_mtime=$(date +%s -r "$RESPAWN_SLOW_GRIND_TRIPPED" 2>/dev/null || echo 0)
        sg_age=$(( $(date +%s) - sg_mtime ))
        if (( sg_age < RESPAWN_SLOW_GRIND_COOLDOWN )); then
            slow_grind_skip=1
            log "respawn paused: slow-grind cooldown active (age=${sg_age}s, cooldown=${RESPAWN_SLOW_GRIND_COOLDOWN}s)"
        else
            log "respawn slow-grind cooldown elapsed (age=${sg_age}s); re-arming guard"
            rm -f "$RESPAWN_SLOW_GRIND_TRIPPED"
            _respawn_consec_reset "$RESPAWN_CONSEC_COUNTER"
        fi
    fi
    (( slow_grind_skip == 1 )) && return 0

    # Crash-loop sliding-window guard. Allows a new respawn only if
    # the recent history doesn't already exceed RESPAWN_LOOP_LIMIT in
    # RESPAWN_LOOP_WINDOW seconds.
    local guard_reason
    if ! guard_reason=$(_respawn_loop_check "$RESPAWN_HISTORY" "$RESPAWN_LOOP_WINDOW" "$RESPAWN_LOOP_LIMIT" "missing-target"); then
        log "respawn blocked: $guard_reason"
        if [[ ! -f "$RESPAWN_TRIPPED" ]]; then
            date -Is > "$RESPAWN_TRIPPED"
            if command -v sandbox-notify >/dev/null 2>&1; then
                sandbox-notify "watcher: orchestrator crash-loop suspected; halting respawn attempts (${guard_reason})" \
                    >/dev/null 2>&1 || true
            fi
            if [[ -x "$_monitor_dir/ng" ]]; then
                "$_monitor_dir/ng" log-action watcher \
                    --event respawn-loop-tripped \
                    --note "$guard_reason" \
                    >/dev/null 2>&1 || true
            fi
        fi
        return 0
    fi

    # All gates passed. Launch the async respawn unless one is already
    # in flight (the `_respawn_async_in_flight` guard prevents
    # double-launch when the probe fires repeatedly while the prior
    # respawn dance is still running).
    if _respawn_async_in_flight; then
        log "respawn-agent (async): launch deferred (in flight) (streak=${missing_target_polls})"
        return 0
    fi

    # Re-verify at the moment of decision (incident 2026-06-02: a
    # single false absent reading spawned a duplicate orchestrator
    # next to a live original, whose stand-down then took the watcher
    # down). A fresh window probe, an orchestrator-process pane scan
    # (with rename healing), and the liveness-signal comparison each
    # independently abort the launch. On abort: reset the streak so
    # the decision tree re-accumulates from scratch — if the abort
    # reason was itself transient, the next streak proceeds.
    local verify_reason
    if ! verify_reason=$(_respawn_verify_target_absent "$TARGET" "${missing_target_since:-0}"); then
        log "respawn aborted by re-verify: ${verify_reason} (streak=${missing_target_polls}, delay=${AGENT_MISSING_RESPAWN_DELAY})"
        if [[ -x "$_monitor_dir/ng" ]]; then
            "$_monitor_dir/ng" log-action watcher \
                --event respawn-aborted-reverify \
                --note "$verify_reason" \
                >/dev/null 2>&1 || true
        fi
        missing_target_polls=0
        missing_target_since=0
        return 0
    fi

    log "target window '${TARGET}' absent — launching async respawn (streak=${missing_target_polls}, delay=${AGENT_MISSING_RESPAWN_DELAY}, re-verify=${verify_reason})"
    if RESPAWN_REASON="target window '${TARGET}' absent for ${missing_target_polls} poll(s); spawned new agent" \
            _respawn_async_launch "$TARGET"; then
        # Tentative reset — the in-flight subshell hasn't confirmed
        # success yet. If the launch fails silently the next probe
        # re-increments and we retry.
        missing_target_polls=0
        missing_target_since=0
    else
        log "respawn-agent (async): launch refused (in-flight or setup error)"
    fi
    return 0
}
