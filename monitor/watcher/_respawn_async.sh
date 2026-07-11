#!/usr/bin/env bash
# Async-respawn wrapper (issue #171).
#
# The scheduler is single-threaded, so a synchronous `respawn_agent`
# call (~22 s wall: tmux new-window + claude boot + paste recovery
# prompt + verify) would block every other scheduled task —
# including the 2 s `target_window` probe — for the entire respawn
# wall-time. The 2026-05-21 23:25 PDT incident showed an 87 s
# wedge during which the watcher was blind to its own recovery
# progress.
#
# This module wraps the respawn dance in a backgrounded subshell with
# the same sidecar-`.rc`-file done-detection contract the scheduler
# already uses for `--async` tasks (`_scheduler.sh`'s
# `_scheduler_fire_async` / `_scheduler_reap_async`). The caller
# decides + launches (cheap, sync) and reaps on a subsequent tick
# (also cheap). The heavy work — tmux, claude, paste — runs in the
# background while the scheduler keeps ticking fast-cadence tasks.
#
# State lives in `${STATE_DIR}/respawn-bg/{pid,rc}`. The directory
# choice is deliberate: surviving a watcher restart means a crash
# mid-respawn can't lose the pid pointer to an orphaned subshell, and
# the in-flight check uses `kill -0 $pid` to distinguish a still-
# running child from a stale pidfile.
#
# Source contract: callers provide a `respawn_agent <target>` function
# (the existing main.sh implementation) that does the actual work and
# updates the slow-grind / consec-failure / action-log state files
# from inside its own body. The wrapper here just backgrounds it.

# Returns the directory holding the async-respawn state files. Honours
# $STATE_DIR (set by main.sh / spawn-fresh-orchestrator.sh); falls
# back to /tmp for ad-hoc invocations / tests.
_respawn_async_state_dir() {
    printf '%s\n' "${STATE_DIR:-/tmp}/respawn-bg"
}

# _respawn_async_pid_starttime <pid>
#
# Echo <pid>'s start-time — field 22 of /proc/<pid>/stat, in clock
# ticks since boot. This value is fixed for the life of a process and
# differs for any later process that recycles the same PID, so it is
# the canonical fingerprint for distinguishing "our backgrounded
# respawn subshell is still alive" from "the PID was reused by an
# unrelated process after a restart" (issue #203 PID-reuse hazard:
# `respawn-bg/` survives a watcher restart by design, so a bare
# `kill -0 $pid` on a recycled low PID reads a false "in flight").
#
# Field 2 (comm) may contain spaces and parentheses, so we split on the
# LAST ')' before counting fields. Returns rc=1 (no stdout) when /proc
# is unavailable/unreadable — callers degrade to the bare `kill -0`
# behaviour (no worse than pre-#203).
_respawn_async_pid_starttime() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -r "/proc/$pid/stat" ]] || return 1
    # awk, not shell word-splitting: comm (field 2) may contain spaces
    # and parentheses, so strip the greedy `<pid> (comm) ` prefix (the
    # `.*\)` matches up to the LAST ')'), leaving field 3 (state) as $1.
    # starttime is field 22 → $20 of the remainder. Shell-agnostic and
    # immune to IFS/no-split-by-default quirks.
    local st
    st=$(awk '{ sub(/^[0-9]+ \(.*\) /, ""); print $20 }' "/proc/$pid/stat" 2>/dev/null) || return 1
    [[ "$st" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$st"
}

# Returns rc=0 if a previously-launched async respawn is still
# running, rc=1 otherwise (no pid file, stale pid, or rc file already
# present indicating completion). Side effect: sweeps a stale pid file
# (process gone without writing rc) so future launches aren't refused
# by a dead sentinel.
_respawn_async_in_flight() {
    local dir
    dir=$(_respawn_async_state_dir)
    local pid_file="$dir/pid"
    local rc_file="$dir/rc"
    [[ -f "$pid_file" ]] || return 1
    # rc-file present ⇒ child reached the line right before exit;
    # waiting to be reaped, not in flight.
    [[ -f "$rc_file" ]] && return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$pid_file" 2>/dev/null; return 1; }
    if kill -0 "$pid" 2>/dev/null; then
        # PID-reuse guard (issue #203). `respawn-bg/` survives a watcher
        # restart by design, so after a container/PID-namespace reset the
        # recorded pid can be recycled to an unrelated live process and a
        # bare `kill -0` would read a false "in flight" (and, worse, the
        # --replace cancel path below would signal a stranger). If we
        # recorded a start-time fingerprint at launch, the live pid must
        # still carry it; a mismatch means the subshell is gone and the
        # PID was reused — treat as stale.
        local start_file="$dir/start" rec_st cur_st
        if [[ -f "$start_file" ]]; then
            rec_st=$(cat "$start_file" 2>/dev/null)
            cur_st=$(_respawn_async_pid_starttime "$pid" 2>/dev/null || true)
            if [[ "$rec_st" =~ ^[0-9]+$ && "$cur_st" =~ ^[0-9]+$ && "$rec_st" != "$cur_st" ]]; then
                rm -f "$pid_file" "$start_file" 2>/dev/null
                return 1
            fi
        fi
        return 0
    fi
    # Stale pid (child died without writing rc — OOM, SIGKILL, etc.).
    # Clean up the pidfile so the next launch isn't refused.
    rm -f "$pid_file" "$dir/start" 2>/dev/null
    return 1
}

# Harvest a completed async respawn. Prints the child's exit code on
# stdout and returns rc=0 when a completion was reaped; returns rc=1
# (no stdout) when there's nothing to reap. Tolerates an already-
# reaped pid via `wait ... || true`.
_respawn_async_reap() {
    local dir
    dir=$(_respawn_async_state_dir)
    local rc_file="$dir/rc"
    local pid_file="$dir/pid"
    [[ -f "$rc_file" ]] || return 1
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null)
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            wait "$pid" 2>/dev/null || true
        fi
    fi
    local rc
    rc=$(cat "$rc_file" 2>/dev/null)
    [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
    rm -f "$rc_file" "$pid_file" "$dir/start" 2>/dev/null
    printf '%s\n' "$rc"
    return 0
}

# _respawn_async_cancel
#
# Cancel an in-flight async respawn (issue #203). The async-respawn
# subshell is deliberately disowned so it survives a watcher *crash*
# (crash recovery: a successor adopts + reaps it via the absent-target
# decision tree). But an intentional `launcher.sh --replace` is a
# different event: the operator/orchestrator is deliberately replacing
# a still-live watcher, and that watcher's half-finished respawn
# subshell must NOT be left orphaned to later fire a kill-then-spawn
# against whatever now occupies the orchestrator window. So the
# --replace path calls this to CANCEL (vs. a crash, which never reaches
# here and is adopted). That is the precise crash-vs-replace
# distinction.
#
# `_respawn_async_in_flight` already validates the PID-reuse fingerprint
# (above), so we only ever signal a pid that is genuinely our live
# respawn subshell — never a recycled stranger. Returns 0 if a live
# respawn was cancelled, 1 if there was nothing live to cancel (in
# either case the sentinel files are cleared so the successor watcher
# won't reap a respawn it did not launch).
_respawn_async_cancel() {
    local dir pid pid_file
    dir=$(_respawn_async_state_dir)
    pid_file="$dir/pid"
    if ! _respawn_async_in_flight; then
        rm -f "$dir/rc" "$pid_file" "$dir/start" 2>/dev/null
        return 1
    fi
    pid=$(cat "$pid_file" 2>/dev/null)
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        local _i
        for _i in 1 2 3 4; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.25
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$dir/rc" "$pid_file" "$dir/start" 2>/dev/null
    return 0
}

# Launch `respawn_agent` in a backgrounded subshell. Returns rc=0 on
# successful launch (parent stores pid in $STATE_DIR/respawn-bg/pid),
# rc=1 when a prior run is still in flight (caller should defer), or
# rc=2 on an I/O setup failure (mkdir of state dir). The subshell
# inherits the parent's RESPAWN_REASON env when the caller sets it
# before calling.
_respawn_async_launch() {
    local target="$1"
    if _respawn_async_in_flight; then
        return 1
    fi
    local dir
    dir=$(_respawn_async_state_dir)
    mkdir -p "$dir" 2>/dev/null || return 2
    # Sweep any orphan sidecar from a prior crashed launch before
    # spawning the new child — otherwise the immediate reap would
    # complete with the stale rc.
    rm -f "$dir/rc" "$dir/pid" "$dir/start" 2>/dev/null
    (
        # Close inherited lock fds (nexus-code#491, #451/#468/#471
        # fd-leak class): this subshell is disowned and can outlive the
        # watcher — it must never pin the instance flock.
        if declare -F _close_inherited_locks >/dev/null 2>&1; then
            _close_inherited_locks
        fi
        respawn_agent "$target"
        printf '%s\n' "$?" > "$dir/rc"
    ) &
    local launched_pid=$!
    printf '%s\n' "$launched_pid" > "$dir/pid"
    # Record the child's /proc start-time fingerprint (issue #203) so a
    # later in-flight check (across a watcher restart) can tell our live
    # subshell from a process that recycled its PID. Best-effort: a
    # missing fingerprint just degrades the in-flight check to the bare
    # `kill -0` (pre-#203 behaviour).
    local _st
    if _st=$(_respawn_async_pid_starttime "$launched_pid" 2>/dev/null); then
        printf '%s\n' "$_st" > "$dir/start" 2>/dev/null || true
    fi
    return 0
}
