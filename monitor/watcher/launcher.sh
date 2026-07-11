#!/usr/bin/env bash
# Spawn the nexus watcher HEADLESS — setsid-detached, no tmux window,
# stdout/stderr appended to monitor/.state/watcher.log. The watcher is
# supervised like every other registered service (pidfile +
# heartbeat); `monitor/svc.sh` shows it as the pinned core row and
# `svc.sh logs watcher` / cockpit key `0` tail its log.
#
# Usage:
#   monitor/watcher/launcher.sh [--target <window>] [--replace] [--instance-status]
#
# --target   tmux window the watcher pastes reports into (default:
#            $MONITOR_TARGET or monitor.target_window from config,
#            falling back to "orchestrator")
# --replace  if a watcher PROCESS is alive per the PID file, kill it
#            (SIGTERM, escalating to SIGKILL after 5s) before spawning.
#            Without this flag, an alive PID-file process causes the
#            launcher to refuse. This is the SUCCESSION path; it does
#            NOT cross sandboxes (you cannot signal a peer you can't see).
# --instance-status
#            print the state-dir singleton lock holder's recorded
#            metadata + a stale-vs-live assessment, then exit without
#            spawning. Use it to decide between using/closing the other
#            instance and clearing a false-positive (stale) lock.
# --i-accept-no-sandbox
#            spawn the watcher even when NOT inside the agent-sandbox,
#            accepting the loss of kernel-enforced isolation. Default is
#            to REFUSE outside the sandbox. Records a per-NEXUS_ROOT
#            acceptance marker so self-heal relaunches inherit it.
#            (Also honoured: env NEXUS_I_ACCEPT_NO_SANDBOX=1.) Irrelevant
#            in-sandbox.
# --window / --force   LEGACY (accepted, ignored): once used to find and
#            kill a leftover windowed watcher host during migration.
#
# The orchestrator's agent-bootstrap snippet calls this on wake when
# the heartbeat is stale. tmux is still required — not to host the
# watcher, but because the watcher pastes into the target window; if
# TMUX is unset, the launcher attaches to (or creates) a session named
# "nexus" so the paste target has somewhere to live.
#
# Project-local Claude Code self-install: before spawning the watcher
# window, this script invokes `monitor/install-claude-local.sh` if the
# project-local install is absent. The orchestrator and every spawned
# worker resolve `$CLAUDE_BIN` against `$NEXUS_ROOT/node_modules/.bin/
# claude` when present; this step ensures it exists so all subsequent
# spawns land on the pinned local binary instead of the
# un-updateable system one. Install failures degrade gracefully (the
# `$CLAUDE_BIN` resolver falls back to PATH) and write a
# `monitor/.state/local-claude-install-failed.<epoch>` flag the
# watcher's first emit surfaces to the orchestrator.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_script_dir/.." && pwd)
_nexus_root=$(cd "$_monitor_dir/.." && pwd)
_cfg="$_nexus_root/config/load.sh"

# Join the nexus-wide toolchain so the watcher (and the headless main.sh it
# setsid-spawns, which inherits this env) can invoke `uv`/nexus tools by name
# with UV_* state redirected out of $HOME. Pure env, idempotent, guarded:
# a missing file is a silent no-op.
# shellcheck source=../locals-env.sh
[ -f "$_monitor_dir/locals-env.sh" ] && NEXUS_ROOT="$_nexus_root" . "$_monitor_dir/locals-env.sh" || true

# Shared liveness helpers. We need `_watcher_pid_is_live_watcher` to
# validate the PID-file owner's identity (not just `kill -0` it) so a
# recycled low PID after a restart can't deadlock recovery. `_lib.sh`
# is side-effect-free and safe to source under `set -uo pipefail`.
# shellcheck source=_lib.sh
source "$_script_dir/_lib.sh"

# Explicit log mode at creation (your-org/nexus-code#484/#509): the
# `>>"$LOGFILE"` spawn redirects below create watcher.log under the
# ambient umask (0660 on group-shared trees) — a log any group member
# could rewrite with nothing recording that they did.
# shellcheck source=../_log-mode.sh
source "$_monitor_dir/_log-mode.sh"

# Async-respawn primitives. We need `_respawn_async_cancel` so a
# `--replace` (an INTENTIONAL watcher replacement) can cancel any
# in-flight respawn subshell the replaced watcher backgrounded — those
# are disowned to survive a CRASH (adopt+reap), but an intentional
# replace must not leave one orphaned to fire a kill-then-spawn against
# the now-live orchestrator window (issue #203). Function-only on
# source; safe under `set -uo pipefail`.
# shellcheck source=_respawn_async.sh
source "$_script_dir/_respawn_async.sh"

TARGET="${MONITOR_TARGET:-$("$_cfg" monitor.target_window orchestrator)}"
WINDOW="watcher"
FORCE=0
REPLACE=0
ENSURE=0
INSTANCE_STATUS=0
IACCEPT_NO_SANDBOX=0

# An EMPTY --target / --window must FAIL LOUD, never silently override the
# config-resolved defaults above (nexus-code#459).
#
# `--target) TARGET="${2:-}"` accepted an empty argument, so a runbook line that
# interpolates an UNSET variable — `launcher.sh --target "$TARGET_WINDOW"` —
# expands to `--target ''` in any shell without `set -u` and the empty string
# WINS over `monitor.target_window`. The watcher then launches with no
# coordinator window to paste into: a nexus that looks healthy and reaches
# nobody. Because the resolved default is the correct value in every such case,
# refusing is strictly safer than accepting, and refusing LOUDLY is the only
# thing that tells the caller their variable was empty.
#
# Guard the flag, not just the one runbook that got it wrong: the flag is the
# copy-pasteable surface, and this file cannot see its callers.
_require_arg() { # flag value
    [[ -n "${2:-}" ]] && return 0
    echo "launcher.sh: $1 requires a non-empty value (got an empty argument —" \
         "an unset variable in the caller?). Omit $1 to use the configured" \
         "default. Resolved defaults: --target '$TARGET' --window '$WINDOW'." >&2
    exit 2
}

while (( $# > 0 )); do
    case "$1" in
        --target)  _require_arg --target "${2:-}"; TARGET="$2"; shift 2 ;;
        --window)  _require_arg --window "${2:-}"; WINDOW="$2"; shift 2 ;;
        --force)   FORCE=1; shift ;;
        --replace) REPLACE=1; shift ;;
        --i-accept-no-sandbox) IACCEPT_NO_SANDBOX=1; shift ;;
        # --ensure  IDEMPOTENT spawn-if-dead: a live watcher → exit 0
        #           (no-op); a dead/absent one → spawn exactly one. The
        #           watcher-supervisor daemon + bootstrap-recover use this
        #           so a concurrent restart that beat us to the spawn
        #           converges to "already live, success" instead of the
        #           bare-spawn refusal (exit 1). Single-flighted like every
        #           other path (the restart lock below).
        --ensure)  ENSURE=1; shift ;;
        --instance-status) INSTANCE_STATUS=1; shift ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "launcher.sh: unknown flag: $1" >&2; exit 1 ;;
    esac
done

# --instance-status — inspect-before-deciding helper (operator ask on
# PR #281). Print the current instance-lock holder's recorded metadata
# plus the stale-vs-live assessment, then exit WITHOUT spawning, so an
# operator can decide between "use/close the other instance" and "this
# is a false positive, clear the stale lock". No tmux needed.
if (( INSTANCE_STATUS )); then
    _il="$_nexus_root/monitor/.state/nexus-instance.lock"
    if _ih=$(_nexus_instance_lock_live "$_il"); then
        echo "instance-lock: HELD"
        echo "  lock=$_il"
        echo "  assessment=$(_nexus_instance_lock_assess "$_ih")"
        while IFS= read -r _l; do [[ -n "$_l" ]] && echo "  $_l"; done <<<"$_ih"
        echo "  (held = a live cockpit owns this NEXUS_ROOT; see 'assessment' for stale-vs-live, and"
        echo "   'launcher.sh --replace' / 'rm $_il' for the succession vs clear-stale paths.)"
    else
        echo "instance-lock: free (no live holder)"
        echo "  lock=$_il"
        if [[ -e "$_il" ]]; then
            echo "  (a lock FILE exists but no process holds the flock — stale metadata; the next"
            echo "   start reclaims it automatically. Its recorded holder:)"
            while IFS= read -r _l; do [[ -n "$_l" ]] && echo "    $_l"; done < "$_il"
        fi
    fi
    exit 0
fi

# Agent-sandbox gate (your-org/nexus-code#350). The launcher is the
# SINGLE choke point every watcher (re)start runs through — the
# supervisor daemon, version-drift self-restart, bootstrap-recover, a
# manual `svc.sh restart watcher`, and the cold first spawn (see the
# block below). Gating here (not just in entry.sh) is what makes the
# refusal un-bypassable: starting the watcher via ANY of those paths
# outside the sandbox without acceptance fails loud. In-sandbox this is
# a no-op. Self-heal relaunches don't carry the flag, but they inherit
# the persisted marker entry.sh / a prior accepting launch wrote — so an
# accepted out-of-sandbox deployment keeps recovering on its own.
if ! _nexus_sandbox_gate "$_nexus_root/monitor/.state" "$IACCEPT_NO_SANDBOX" "launcher.sh"; then
    exit 2
fi

command -v tmux >/dev/null 2>&1 || { echo "launcher.sh: tmux required" >&2; exit 2; }

# Single-flight restart lock (your-org/your-nexus watcher-supervision).
# EVERY watcher (re)start path runs the launcher — the supervisor daemon
# (--ensure), the version-drift self-restart (--replace, detached),
# bootstrap-recover, a manual `svc.sh restart watcher` (--replace), and a
# cold first spawn. With three+ things able to fire concurrently, two
# launchers could otherwise race: A spawns a fresh watcher while B's
# in-flight --replace SIGKILLs it, leaving zero or a thrashed tree. We
# serialize them on one flock held for the whole kill+spawn+verify window:
# a second launcher BLOCKS until the first finishes, then re-evaluates the
# now-current pidfile below (a fresh live watcher → --ensure no-ops; a
# --replace proceeds to a clean succession). The instance flock main.sh
# holds for its lifetime is the ultimate uniqueness backstop (≤1 main.sh
# can hold it, across pid-namespaces + hosts); this lock just removes the
# transient kill-the-other's-fresh-spawn churn so callers converge to
# exactly one. Distinct from nexus-instance.lock: this is held ONLY for
# the duration of a (re)start, never for the watcher's lifetime.
RESTART_LOCK="$_nexus_root/monitor/.state/watcher-restart.lock"
mkdir -p "$_nexus_root/monitor/.state" 2>/dev/null || true
_RESTART_LOCK_FD=""
# NOTE: a bare `exec {fd}<>file` with a trailing `2>/dev/null` would make
# that stderr redirect PERMANENT for the whole script (exec with no
# command applies its redirections to the current shell) — silencing
# every later message. So we open WITHOUT a trailing redirect, mirroring
# main.sh's acquire_instance_lock. mkdir -p above makes the open
# effectively never fail; the `if !` degrades gracefully if it somehow does.
if exec {_RESTART_LOCK_FD}<>"$RESTART_LOCK"; then
    # Block bounded; on timeout REFUSE (fail closed, nexus-code#491). The
    # old behaviour — "proceed, the instance lock backstops uniqueness" —
    # was one of the windows through which the 2026-07-09 duplicate
    # watchers arrived: under load (exactly when restart storms fire and
    # launchers run long) two launchers could both be past the lock, and
    # the instance flock only closes the race minutes later, after the
    # spawned main.sh finishes its config sourcing. A refused launcher is
    # retryable and loud; a duplicate watcher is silent double-writes.
    if ! flock -w "${WATCHER_RESTART_LOCK_WAIT:-45}" "$_RESTART_LOCK_FD"; then
        echo "launcher.sh: REFUSING — could not acquire the single-flight restart lock ($RESTART_LOCK) within ${WATCHER_RESTART_LOCK_WAIT:-45}s: another (re)start is in flight." >&2
        echo "  Retry after it finishes; a concurrent second spawn risks duplicate watchers (double emits, racing state writes)." >&2
        exit 5
    fi
else
    _RESTART_LOCK_FD=""
    echo "launcher.sh: WARN could not open restart lock $RESTART_LOCK; proceeding without single-flight serialization" >&2
fi

# Durable spawn attribution (nexus-code#491). During the 2026-07-09
# duplicate-watcher incident the second spawner was UNATTRIBUTABLE:
# launcher runs from orchestrator-side surfaces log only to their
# caller's stderr. Every consequential launcher decision now also
# appends one line to a shared audit log, stamped with the caller
# (WATCHER_LAUNCH_CALLER when the caller sets it, else the parent's
# argv). Best-effort — auditing never blocks a (re)start.
SPAWN_AUDIT_LOG="$_nexus_root/monitor/.state/watcher-spawns.log"
_launch_caller() {
    if [[ -n "${WATCHER_LAUNCH_CALLER:-}" ]]; then
        printf '%s' "$WATCHER_LAUNCH_CALLER"
    else
        tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | head -c 120 || printf 'ppid=%s' "$PPID"
    fi
}
_launch_audit() {
    if [[ -f "$SPAWN_AUDIT_LOG" ]] && (( $(stat -c%s "$SPAWN_AUDIT_LOG" 2>/dev/null || echo 0) > 1048576 )); then
        mv -f "$SPAWN_AUDIT_LOG" "$SPAWN_AUDIT_LOG.1" 2>/dev/null || true
    fi
    printf '%s launcher[%d] caller=[%s] %s\n' \
        "$(date -Is 2>/dev/null || echo '?')" "$$" "$(_launch_caller)" "$*" \
        >> "$SPAWN_AUDIT_LOG" 2>/dev/null || true
}

# Defense-in-depth against the bootstrap race (issue #43). Even with
# bootstrap.sh's flock, an orphan watcher process can exist without a
# tmux window — e.g. a previous `tmux kill-window -t watcher` left
# the main.sh process alive — so the window-name check below wouldn't
# catch it. Refuse outright; the operator must clean up the orphan.
#
# Detect the orphan via the PID file the watcher self-publishes on
# startup (`monitor/.state/watcher.pid`, written atomically before
# any heavy setup; see main.sh). The previous `pgrep -f
# 'bash.*monitor/watcher/main\.sh'` check matched against the global
# process table and false-positive'd on worker `claude` processes
# whose argv text quoted the watcher path (issues #57, #96). A
# self-published PID is immune to that class of confusion.
#
# But `kill -0 <pid>` alone is NOT enough: after a machine/container
# restart the PID namespace resets, the recorded pid gets recycled to
# an unrelated process, and `kill -0` succeeds against it — so the
# launcher refuses to spawn and deadlocks recovery (incident
# 2026-06-07, the recurring `pid=13`). We therefore validate the PID's
# *identity* via `_watcher_pid_is_live_watcher` (argv must reference
# monitor/watcher/main.sh), so a recycled-PID stale file is correctly
# treated as dead.
PIDFILE="$_nexus_root/monitor/.state/watcher.pid"
if [[ -f "$PIDFILE" ]]; then
    existing_pid=$(cat "$PIDFILE" 2>/dev/null)
    # `_watcher_pid_is_live_watcher` validates that `$existing_pid` is
    # not merely alive but is actually a watcher process. After a
    # restart the PID namespace resets and the recorded pid (the
    # recurring `pid=13`) can be recycled to an unrelated process; a
    # bare `kill -0` would then refuse to spawn and deadlock recovery
    # (incident 2026-06-07). The helper subsumes the old numeric-regex
    # + `kill -0` guard — garbage / dead / recycled all fall to the
    # stale-file `else` branch below.
    if _watcher_pid_is_live_watcher "$existing_pid"; then
        # --ensure is idempotent: a live watcher is success, not a refusal.
        # This is how the supervisor daemon / bootstrap-recover converge
        # when another path won the single-flight lock and already spawned.
        if (( ENSURE == 1 )); then
            echo "launcher.sh: watcher $existing_pid already live (per $PIDFILE) — --ensure no-op (idempotent)"
            exit 0
        fi
        if (( REPLACE == 0 )); then
            echo "launcher.sh: watcher process $existing_pid is alive (per $PIDFILE); refusing to spawn" >&2
            echo "  (pass --replace to kill it first, or kill it explicitly: kill $existing_pid; rm $PIDFILE)" >&2
            exit 1
        fi
        # --replace on a READ-ONLY project FS is a DECAPITATION.
        #
        # An already-open fd survives its mount being detached: the
        # incumbent watcher holds `watcher.log` open and keeps working, at
        # full fidelity, straight through a read-only remount. Its
        # successor does not — it must resolve every path afresh, and dies
        # in the `>>"$LOGFILE"` redirection below before `main.sh` runs a
        # single line. So a `--replace` here kills the ONLY functioning
        # watcher and puts nothing in its place: exactly what happened on
        # 2026-06-29 and again on 2026-07-09 (both incidents open with
        # `version_check` -> `--replace` -> SIGTERM -> EROFS -> "did not
        # publish a live pidfile", then silence until a human noticed).
        #
        # A FRESH probe (never a cached fd — see monitor/_fs_probe.sh)
        # decides. Read-only ⇒ refuse to replace, leave the incumbent
        # running, escalate once over a channel that needs no filesystem
        # write, and exit non-zero. Degrading beats decapitating.
        if ! _nexus_dir_writable "$_nexus_root/monitor/.state"; then
            echo "launcher.sh: --replace REFUSED: the project FS is READ-ONLY ($_nexus_root/monitor/.state)." >&2
            echo "  The running watcher (pid=$existing_pid) still works on its already-open fds; its replacement could not start." >&2
            echo "  Leaving the incumbent alive. Restart the sandbox from OUTSIDE to restore the writable bind." >&2
            _nexus_critical_alarm "watcher-rofs" "${MONITOR_ROFS_ALARM_THROTTLE_SECONDS:-120}" \
                "$(_nexus_rofs_alarm_text "$_nexus_root/monitor/.state" "launcher.sh --replace")" \
                && _nexus_github_incident_escalate "$_nexus_root" \
                       "$_nexus_root/monitor/.state" "launcher.sh --replace" \
                       "incumbent watcher pid=$existing_pid left ALIVE (replace refused)" || true
            exit 5
        fi

        # --replace: terminate the running watcher before spawning.
        # Graceful first (SIGTERM, up to 5s) so its EXIT/INT/TERM
        # trap in main.sh can release_pidfile + release_lock and
        # rm -rf the tmp_dir. Escalate to SIGKILL only if the
        # process is still alive after the grace window — the
        # process may be blocked in `sleep "${INTERVAL}"`
        # (default 60s), in which case bash defers the trap until
        # sleep returns and a polite shutdown won't fit in the
        # budget. SIGKILL leaves the lock + pid files on disk; we
        # clean them here, and the next watcher's `acquire_lock`
        # tolerates a stale lock anyway.
        # Reap the ENTIRE watcher PROCESS GROUP, not just the root pid.
        # launcher spawns the watcher under `setsid`, making main.sh a
        # session+group leader whose PGID == its PID, so `kill -- -<pid>`
        # signals main.sh AND every child it left in that group (scheduler
        # async subshells, an in-flight spawn-fresh-orchestrator helper).
        # The old root-only `kill <pid>` left those children orphaned on a
        # SIGKILL (no trap fires) — the "overlapping process trees" the
        # operator hit. The orchestrator is NOT in this group (it lives in
        # the tmux server's tree), so a group kill never touches it. Fall
        # back to the bare pid if the group signal is rejected.
        # The death test is GROUP emptiness, not leader exit
        # (nexus-code#491): main.sh forks a subshell chain, and a
        # leader-only wait "succeeds" while orphaned children keep
        # running the loop (decapitation, observed live 2026-07-09
        # 17:45 — a leader dead 6 minutes with its chain still forking
        # tac/jq). TERM the group, wait for EVERY member to be gone,
        # escalate to KILL, and VERIFY emptiness before spawning.
        echo "launcher.sh: --replace: sending SIGTERM to watcher process group $existing_pid (waiting for the WHOLE group)" >&2
        kill -TERM -- "-$existing_pid" 2>/dev/null \
            || kill -TERM "$existing_pid" 2>/dev/null || true
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            _watcher_group_alive "$existing_pid" || kill -0 "$existing_pid" 2>/dev/null || break
            sleep 0.5
        done
        if _watcher_group_alive "$existing_pid" || kill -0 "$existing_pid" 2>/dev/null; then
            echo "launcher.sh: --replace: watcher group $existing_pid did not empty within 5s, sending SIGKILL to the process group" >&2
            kill -9 -- "-$existing_pid" 2>/dev/null \
                || kill -9 "$existing_pid" 2>/dev/null || true
            sleep 0.5
            if _watcher_group_alive "$existing_pid"; then
                echo "launcher.sh: FATAL: watcher group $existing_pid has survivors after SIGKILL; REFUSING to spawn alongside them" >&2
                _launch_audit "refuse-unkillable pgid=$existing_pid"
                exit 6
            fi
            # The trap won't fire on SIGKILL; force-remove the pidfile.
            rm -f "$PIDFILE"
        else
            echo "launcher.sh: --replace: watcher $existing_pid exited gracefully (group empty)" >&2
            # The trap should have removed PIDFILE; guard anyway.
            rm -f "$PIDFILE"
        fi
        # Cancel any in-flight async respawn the replaced watcher
        # backgrounded (issue #203). The respawn subshell is disowned so
        # it survives a CRASH — there, a successor watcher adopts + reaps
        # it via the absent-target decision tree. But THIS is an
        # intentional `--replace`: the live watcher we just killed may
        # have a half-finished respawn subshell mid-flight, and leaving
        # it orphaned lets it later run `spawn-fresh-orchestrator`'s
        # kill-then-spawn against whatever now occupies the orchestrator
        # window — the 2026-06-11 catastrophe class. `_respawn_async_cancel`
        # validates the PID-reuse fingerprint before signalling, so it
        # never kills a recycled-PID stranger; it clears the sentinel
        # either way so the successor doesn't reap a respawn it didn't
        # launch. STATE_DIR must match the watcher's (main.sh:285).
        STATE_DIR="${STATE_DIR:-$_nexus_root/monitor/.state}"
        if _respawn_async_cancel; then
            echo "launcher.sh: --replace: cancelled an in-flight async respawn (orphan-clobber guard)" >&2
        fi
    else
        # Stale PID file (dead pid, garbage content, or a recycled PID
        # now owned by a non-watcher process). Remove it so a future
        # operator reading the state dir isn't misled. We do NOT signal
        # the recycled PID's current owner: it isn't ours to kill.
        #
        # BUT a dead recorded pid does NOT mean a dead watcher TREE
        # (nexus-code#491 decapitation): the leader's orphaned subshell
        # chain keeps the pgid alive and keeps running the loop.
        #
        # IDENTITY BEFORE SIGNAL (skeptic finding 1 on PR#503): the pid
        # is NOT the identity. A recycled pid can name ANY setsid
        # leader's group — a worker pane, a registry service, another
        # agent's job — and an unverified group kill here TERMed an
        # innocent `setsid sleep` group in the skeptic's repro.
        # _watcher_reap_group is therefore called WITH the nexus root:
        # it signals the group ONLY if it still contains an
        # argv-verified watcher member for this root, and REFUSES
        # (rc 2) otherwise — leaving a recycled pid's owner untouched.
        # A refused group with no argv member is by definition not a
        # watcher loop; verified decapitated trees are also reaped by
        # the group-scan gate below.
        if [[ "$existing_pid" =~ ^[0-9]+$ ]] && _watcher_group_alive "$existing_pid"; then
            _reap_rc=0
            _watcher_reap_group "$existing_pid" 5 "$_nexus_root" || _reap_rc=$?
            case "$_reap_rc" in
                0)
                    echo "launcher.sh: recorded watcher pid $existing_pid was dead but its argv-verified group still had members (decapitated orphan loop) — reaped" >&2
                    _launch_audit "reap-decapitated pgid=$existing_pid"
                    ;;
                2)
                    echo "launcher.sh: recorded pid $existing_pid is dead and group $existing_pid has live members but NO argv-verified watcher among them (recycled pid / foreign group) — NOT ours to kill; leaving it untouched" >&2
                    _launch_audit "refuse-unverified-group pgid=$existing_pid"
                    ;;
                *)
                    echo "launcher.sh: FATAL: decapitated group $existing_pid has survivors after SIGKILL; REFUSING to spawn alongside them" >&2
                    _launch_audit "refuse-unkillable pgid=$existing_pid"
                    exit 6
                    ;;
            esac
        fi
        rm -f "$PIDFILE"
    fi
fi

# PROCESS-GROUP singleton gate (nexus-code#491). The pidfile guard above
# is blind (a) between a spawn and its — possibly minutes-late, under
# load — pidfile publish, and (b) to DECAPITATED trees: main.sh's
# orphaned subshell chain keeps running the loop after the recorded
# leader dies (observed live 2026-07-09 17:45). Enumerate every process
# GROUP containing argv-identified watcher members for THIS nexus root
# (_watcher_list_live_groups; argv identity + pgrp, never ppid==1 —
# orphans reparent to init and inherit argv).
#
#   decapitated group (leader dead)  reaped in EVERY mode — a
#                                    leaderless loop is defunct: it
#                                    heartbeats for a dead pid, races
#                                    state writes, and can never be
#                                    supervised. Reap by pgid, verify
#                                    empty, refuse on survivors.
#   live-leader group + --ensure     idempotent no-op success
#   live-leader group + bare         refuse (same contract as pidfile)
#   live-leader group + --replace    reap by pgid (TERM, wait for the
#                                    WHOLE group, KILL, verify empty);
#                                    REFUSE to spawn on survivors —
#                                    never spawn alongside a watcher
#                                    that may still be exiting.
_live_leader_groups=()
while IFS=$'\t' read -r _wg _wleader _wn; do
    [[ "$_wg" =~ ^[0-9]+$ ]] || continue
    if [[ "$_wleader" == dead ]]; then
        echo "launcher.sh: decapitated watcher group $_wg (leader dead, $_wn orphaned member(s) still looping) — reaping before any spawn" >&2
        _launch_audit "reap-decapitated pgid=$_wg members=$_wn"
        # Root passed: the reap re-verifies argv identity at kill time
        # (rc 2 = the group's watcher members vanished since the scan —
        # nothing left that is ours to kill; benign).
        _reap_rc=0
        _watcher_reap_group "$_wg" "${WATCHER_REPLACE_KILL_WAIT:-10}" "$_nexus_root" || _reap_rc=$?
        if (( _reap_rc == 1 )); then
            echo "launcher.sh: FATAL: decapitated group $_wg has survivors after SIGKILL; REFUSING to spawn alongside them" >&2
            _launch_audit "refuse-unkillable pgid=$_wg"
            exit 6
        fi
    else
        _live_leader_groups+=("$_wg")
    fi
done < <(_watcher_list_live_groups "$_nexus_root")

if (( ${#_live_leader_groups[@]} > 0 )); then
    if (( ENSURE == 1 )); then
        echo "launcher.sh: live watcher group(s) ${_live_leader_groups[*]} found for $_nexus_root — --ensure no-op (idempotent)"
        _launch_audit "ensure-noop live=${_live_leader_groups[*]}"
        exit 0
    fi
    if (( REPLACE == 0 )); then
        echo "launcher.sh: live watcher group(s) ${_live_leader_groups[*]} exist for $_nexus_root (found via process table; pidfile may lag); refusing to spawn" >&2
        echo "  (pass --replace to kill them first)" >&2
        _launch_audit "refuse-bare live=${_live_leader_groups[*]}"
        exit 1
    fi
    echo "launcher.sh: --replace: reaping ${#_live_leader_groups[@]} live watcher group(s) not covered by the pidfile: ${_live_leader_groups[*]}" >&2
    for _wg in "${_live_leader_groups[@]}"; do
        # Root passed: identity re-verified at kill time (rc 2 = gone
        # between scan and kill — benign).
        _reap_rc=0
        _watcher_reap_group "$_wg" "${WATCHER_REPLACE_KILL_WAIT:-10}" "$_nexus_root" || _reap_rc=$?
        if (( _reap_rc == 1 )); then
            echo "launcher.sh: FATAL: watcher group $_wg has survivors after SIGKILL; REFUSING to spawn alongside them" >&2
            _launch_audit "refuse-unkillable pgid=$_wg"
            exit 6
        fi
    done
    _launch_audit "replace-reaped groups=${_live_leader_groups[*]}"
    rm -f "$PIDFILE" 2>/dev/null || true
fi

# Self-install Claude Code if absent. The orchestrator + every spawned
# worker resolves $CLAUDE_BIN against $NEXUS_ROOT/node_modules/.bin/
# claude when present; this step ensures it exists. One-shot per
# launcher invocation — no polling, no retry loop. Failures degrade
# gracefully (spawn surfaces fall back to system claude on PATH) AND
# get surfaced to the orchestrator via a flag file that main.sh
# includes in its first paste.
if [[ ! -x "$_nexus_root/node_modules/.bin/claude" ]]; then
    echo "launcher.sh: local claude missing; running monitor/install-claude-local.sh" >&2
    install_stderr=$(mktemp /tmp/launcher-install-stderr.XXXXXX) || install_stderr=""
    if "$_nexus_root/monitor/install-claude-local.sh" 2> >(tee "$install_stderr" >&2); then
        echo "launcher.sh: local claude install succeeded" >&2
        rm -f "$install_stderr"
    else
        rc=$?
        echo "launcher.sh: local claude install FAILED (rc=$rc); spawn surfaces will fall back to system claude" >&2
        # Stamp a flag so the watcher's first emit can surface the
        # failure to the orchestrator. Best-effort: a failed write
        # just means the orchestrator won't see the diagnostic;
        # spawns still work via the PATH fallback.
        flag_dir="$_nexus_root/monitor/.state"
        mkdir -p "$flag_dir" 2>/dev/null || true
        flag_file="$flag_dir/local-claude-install-failed.$(date +%s)"
        if [[ -n "$install_stderr" && -s "$install_stderr" ]]; then
            cp "$install_stderr" "$flag_file" 2>/dev/null || true
        else
            printf 'monitor/install-claude-local.sh exited rc=%d (no stderr captured)\n' "$rc" > "$flag_file"
        fi
        rm -f "$install_stderr"
    fi
fi

# Provision the stable locals/bin tool links (claude, ng, nexus, watcher)
# so PATH-based resolution — workers AND manually-spawned tmux windows
# (#307 items 3+4) — finds them by name. install-claude-local.sh already
# does this on a (re)install; calling it here too covers the common case
# where claude was already at the pinned version (install fast-pathed, no
# link step) but a link is missing — e.g. first watcher start after this
# change landed on an existing install. Idempotent + best-effort.
if [[ -x "$_monitor_dir/link-nexus-tools.sh" ]]; then
    NEXUS_ROOT="$_nexus_root" "$_monitor_dir/link-nexus-tools.sh" --quiet \
        || echo "launcher.sh: warning: could not provision locals/bin tool links" >&2
fi

# Ensure a tmux session exists. The watcher itself is windowless, but
# it pastes into the target window — `nexus` is the fallback session
# for cron / at / ssh contexts where no server is up yet.
if [[ -z "${TMUX:-}" ]] && ! tmux has-session 2>/dev/null; then
    tmux new-session -d -s nexus -c "$_nexus_root"
fi

# Migration sweep: a window named after the old watcher host is a
# leftover from the windowed era (the process guard above already
# ensured no live pidfile-owning watcher exists, so at most the window
# holds a dead pane or an unregistered orphan whose HUP trap exits it
# cleanly). Kill it so the stack converges on headless.
if tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF "$WINDOW"; then
    echo "launcher.sh: removing legacy '$WINDOW' window (watcher runs headless now)" >&2
    tmux kill-window -t "$WINDOW" 2>/dev/null || true
fi

# Launch HEADLESS: setsid detaches the watcher into its own process
# session so it survives the launcher and any tmux teardown; output
# appends to the logfile the cockpit tails. main.sh self-publishes
# $PIDFILE on startup — that, not a window, is the liveness anchor
# (_watcher_alive).
#
# tmux-target note: windowless, the watcher's bare `tmux` calls (bell
# scan, target-window probe, paste) resolve against the attached /
# most-recently-used session instead of an implicit current one. The
# nexus deployment contract is ONE tmux session per server, so this
# resolves identically — multi-session servers are out of contract.
# State-dir-scoped singleton fast-fail (issue: multi-instance-guard).
# The pidfile guard above is BLIND across agent-sandbox's `bwrap
# --unshare-pid` boundary: a peer sandbox's watcher pid isn't in this
# namespace's /proc, so `_watcher_pid_is_live_watcher` reads a live peer
# as dead and we'd happily spawn a second watcher onto the shared
# state dir (double GitHub writes, emit races). An flock crosses that
# boundary (and, on the NFSv3 state mount, the host boundary). main.sh
# holds this lock for its lifetime and is the authoritative gate; here
# we only PROBE it so a doomed second start refuses immediately with an
# actionable message instead of burning ~15s of config-sourcing before
# main.sh refuses itself. A `--replace` has already terminated the prior
# watcher above, releasing its flock, so this probe passes and
# succession is unaffected.
INSTANCE_LOCK="$_nexus_root/monitor/.state/nexus-instance.lock"
mkdir -p "$_nexus_root/monitor/.state" 2>/dev/null || true
if _instance_holder=$(_nexus_instance_lock_live "$INSTANCE_LOCK"); then
    {
        echo "launcher.sh: REFUSING to spawn — another nexus cockpit holds the instance lock for this NEXUS_ROOT."
        # Situation-aware block shared with main.sh's authoritative gate
        # (normal vs false-positive resolution + stale-lock assessment).
        _nexus_instance_lock_refusal "$_instance_holder" "$INSTANCE_LOCK" "$_nexus_root"
    } >&2
    exit 4
fi

# Cross-host companion to the flock probe above. flock over NFSv3 does not
# reliably arbitrate between CLIENTS, so the probe can read FREE even while a
# live cockpit runs on ANOTHER host sharing this NFS state dir. Consult the
# heartbeat beacon: a FRESH beacon from a different host → refuse (we cannot
# --replace a peer we cannot see). A stale/absent/same-host beacon → proceed
# — a same-host --replace already released the local flock above, and its
# beacon (host == ours) reads same-host → free, so succession is unaffected.
# Only live-remote refuses here; a corrupt beacon is left to main.sh's
# authoritative acquire (which holds the flock, so it never self-blocks).
_hb_file="$_nexus_root/monitor/.state/nexus-instance.heartbeat"
_hb_verdict=$(_nexus_instance_remote_verdict \
    "$(cat "$_hb_file" 2>/dev/null || true)" \
    "$(hostname 2>/dev/null || echo unknown)" \
    "$(date +%s 2>/dev/null || echo 0)" \
    "$(_nexus_instance_staleness_window)")
if [[ "$_hb_verdict" == "live-remote" ]]; then
    {
        _rh=$(_nexus_instance_lock_field "$(cat "$_hb_file" 2>/dev/null)" host) || _rh="?"
        _rts=$(_nexus_instance_lock_field "$(cat "$_hb_file" 2>/dev/null)" ts) || _rts="?"
        echo "launcher.sh: REFUSING to spawn — a live nexus instance on host $_rh holds the cross-host heartbeat (as of $_rts)."
        echo "  monitor/.state is shared over NFS — two cockpits would race it. Use / stop the instance on $_rh."
        echo "  You cannot --replace a peer on another host from here. If $_rh is down, the beacon ages out"
        echo "  (staleness $(_nexus_instance_staleness_window)s) and this host takes over automatically: $_hb_file"
    } >&2
    exit 4
fi

LOGFILE="$_nexus_root/monitor/.state/watcher.log"
mkdir -p "$_nexus_root/monitor/.state" 2>/dev/null || true

# The redirection `>>"$LOGFILE"` below is a FRESH open(), performed by the
# forked child before it execs main.sh. On a read-only project FS that
# open fails with EROFS, bash aborts the command, and main.sh NEVER RUNS —
# no probe, no degraded mode, no escalation, no log line explaining why.
# That single unguarded redirect is what turned two transient remounts
# into total, silent, multi-hour watcher outages. (The incumbent, holding
# this same path on an fd opened before the remount, went on logging
# perfectly — which is exactly why the outages were so confusing.)
#
# So: probe the state dir with a fresh create+unlink, and if it is not
# writable, redirect the successor's output to a log on a mount that IS
# writable. The watcher then starts, discovers the read-only FS itself,
# and degrades loudly instead of dying silently. `${TMPDIR:-/tmp}` is the
# same independent mount `_nexus_critical_alarm` throttles on.
if ! _nexus_dir_writable "$_nexus_root/monitor/.state"; then
    _degraded_log="${TMPDIR:-/tmp}/nexus-watcher-degraded.log"
    echo "launcher.sh: project FS is READ-ONLY — cannot open $LOGFILE for append." >&2
    echo "launcher.sh: redirecting watcher output to $_degraded_log so the watcher can START and report the condition instead of dying in its own redirect." >&2
    LOGFILE="$_degraded_log"
    _ensure_service_log "$LOGFILE"
    NEXUS_FS_DEGRADED=1
    export NEXUS_FS_DEGRADED
fi
# Rotate on spawn past ~10MB (one prior generation kept): the windowed
# watcher had bounded pane scrollback; an append-forever file doesn't.
if [[ -f "$LOGFILE" ]] && (( $(stat -c%s "$LOGFILE" 2>/dev/null || echo 0) > 10485760 )); then
    mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || true
fi
command -v setsid >/dev/null 2>&1 || { echo "launcher.sh: setsid required for headless launch" >&2; exit 2; }
# Restore the soft RLIMIT_NPROC to the hard limit (fork-storm class,
# your-org/nexus-code#487). Worker shells run under a soft nproc ceiling
# from spawn-worker.sh; the watcher must never inherit it — a capped
# watcher starves during exactly the storms it exists to survive. The
# worker ceiling is soft-only, so this raise is always permitted.
ulimit -Su "$(ulimit -Hu)" 2>/dev/null || true
# CRITICAL: close the single-flight restart-lock fd IN THE SPAWNED WATCHER
# (`{_RESTART_LOCK_FD}>&-`). Without this the long-lived watcher INHERITS
# the open fd and thus HOLDS the restart lock for its entire lifetime, so
# the next `--replace`/`--ensure` would block on `flock -w` until the
# watcher dies — deadlocking every subsequent restart. The launcher PARENT
# keeps the fd open (the lock stays held through this spawn+verify window);
# only the child is denied it.
#
# The close MUST be a literal redirection word in the SOURCE, not produced
# by a parameter expansion. Bash performs redirections by scanning the
# command's words for redirection operators BEFORE expansion; a word like
# `10>&-` synthesised via `${_RESTART_LOCK_FD:+${_RESTART_LOCK_FD}>&-}` is
# NOT re-tokenized as a redirect — it is handed to `main.sh` as a positional
# ARGUMENT (`main.sh: unknown flag: 10>&-` → the watcher dies at startup,
# your-org/nexus-code #292 regression). Since the redirect can't be made
# conditional via expansion, branch on whether the fd is set and emit the
# brace-form `{_RESTART_LOCK_FD}>&-` literally (bash ≥ 4.1).
# Create/repair the log with an explicit 0640 mode immediately before
# the redirect that would otherwise create it under the ambient umask
# (nexus-code#509) — after the rotation above, which can leave the path
# absent.
_ensure_service_log "$LOGFILE"
if [[ -n "$_RESTART_LOCK_FD" ]]; then
    setsid env WATCHER_WINDOW=headless \
        "$_script_dir/main.sh" --target "$TARGET" </dev/null >>"$LOGFILE" 2>&1 {_RESTART_LOCK_FD}>&- &
else
    setsid env WATCHER_WINDOW=headless \
        "$_script_dir/main.sh" --target "$TARGET" </dev/null >>"$LOGFILE" 2>&1 &
fi
_spawn_child_pid=$!

# Verify the spawn took: main.sh writes its pidfile before any heavy
# setup. 15s budget — 5s false-negatived in the field (2026-06-09: a
# successful live spawn on hpc-mount NFS took >5s to publish; the
# launcher reported failure while the watcher came up fine). Failing
# loud here (rc 3)
# lets recover_watcher / `svc.sh up` report a launch that didn't stick
# instead of pretending success the old fire-and-forget way.
spawned=''
for _i in $(seq 1 60); do
    if [[ -f "$PIDFILE" ]]; then
        spawned=$(cat "$PIDFILE" 2>/dev/null)
        if _watcher_pid_is_live_watcher "$spawned"; then
            break
        fi
        spawned=''
    fi
    sleep 0.25
done
if [[ -z "$spawned" ]]; then
    # A watcher on a read-only FS CANNOT publish a pidfile — that write is
    # the very thing that is failing. Absence of the pidfile is then not
    # evidence of a failed spawn, and treating it as one is how a degraded
    # but perfectly useful watcher gets reported as dead (and, worse, how a
    # caller is tempted to "retry" the launch forever). Fall back to the
    # ground truth we still have: is the child we just forked alive?
    if [[ "${NEXUS_FS_DEGRADED:-0}" == "1" ]] \
       && [[ -n "${_spawn_child_pid:-}" ]] && kill -0 "$_spawn_child_pid" 2>/dev/null; then
        echo "launcher.sh: watcher started in READ-ONLY DEGRADED mode (pid=$_spawn_child_pid); no pidfile is possible on a read-only FS. Log: $LOGFILE" >&2
        echo "launcher.sh: restart the sandbox from OUTSIDE to restore the writable bind; the watcher will resume normal operation on its own." >&2
        exit 0
    fi
    # Slow-publish fallback (nexus-code#491). Under load (exactly when
    # restart storms fire) main.sh's early pidfile publish can lag past
    # any fixed budget; reporting FAILURE for a spawn that is coming up
    # invites the caller to retry — the retry raced the slow starter and
    # produced the 2026-07-09 duplicate. Consult the process table: a
    # single live watcher for this root IS the success we were waiting
    # to confirm.
    mapfile -t _post_watchers < <(_watcher_list_live_pids "$_nexus_root")
    if (( ${#_post_watchers[@]} == 1 )); then
        spawned="${_post_watchers[0]}"
        echo "launcher.sh: WARN pidfile not published within 15s, but exactly one live watcher (pid=$spawned) is up — slow start under load, treating as success" >&2
    elif (( ${#_post_watchers[@]} > 1 )); then
        echo "launcher.sh: FATAL: ${#_post_watchers[@]} live watchers after spawn (${_post_watchers[*]}) — DUPLICATE; reconcile with: $_nexus_root/monitor/svc.sh restart watcher" >&2
        _launch_audit "post-spawn-duplicate pids=${_post_watchers[*]}"
        exit 6
    else
        echo "launcher.sh: watcher did not publish a live pidfile within 15s and no live watcher process found — check $LOGFILE" >&2
        _launch_audit "spawn-failed (no pidfile, no process)"
        exit 3
    fi
fi

# The singleton claim is CHECKED, not asserted (nexus-code#491): count
# the live top-level watchers for this root after the spawn. Anything
# other than exactly one is a loud, distinct failure.
mapfile -t _post_watchers < <(_watcher_list_live_pids "$_nexus_root")
if (( ${#_post_watchers[@]} > 1 )); then
    echo "launcher.sh: FATAL: ${#_post_watchers[@]} live watchers after spawn (${_post_watchers[*]}) — DUPLICATE; reconcile with: $_nexus_root/monitor/svc.sh restart watcher" >&2
    _launch_audit "post-spawn-duplicate pids=${_post_watchers[*]}"
    exit 6
fi

_launch_audit "spawned pid=$spawned target=$TARGET replace=$REPLACE ensure=$ENSURE"
echo "launcher.sh: spawned headless pid=$spawned target='$TARGET' log='$LOGFILE'"
