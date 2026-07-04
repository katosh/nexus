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

while (( $# > 0 )); do
    case "$1" in
        --target)  TARGET="${2:-}"; shift 2 ;;
        --window)  WINDOW="${2:-}"; shift 2 ;;
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
    # Block bounded; on timeout we proceed (the instance lock backstops
    # uniqueness) rather than deadlock recovery. The held fd IS the lock —
    # left open until this process exits (closed in the watcher child, below).
    if ! flock -w "${WATCHER_RESTART_LOCK_WAIT:-45}" "$_RESTART_LOCK_FD"; then
        echo "launcher.sh: WARN could not acquire restart lock ($RESTART_LOCK) within ${WATCHER_RESTART_LOCK_WAIT:-45}s; proceeding (instance lock is the uniqueness backstop)" >&2
    fi
else
    _RESTART_LOCK_FD=""
    echo "launcher.sh: WARN could not open restart lock $RESTART_LOCK; proceeding without single-flight serialization" >&2
fi

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
        echo "launcher.sh: --replace: sending SIGTERM to watcher process group $existing_pid" >&2
        kill -TERM -- "-$existing_pid" 2>/dev/null \
            || kill -TERM "$existing_pid" 2>/dev/null || true
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$existing_pid" 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 "$existing_pid" 2>/dev/null; then
            echo "launcher.sh: --replace: watcher $existing_pid did not exit within 5s, sending SIGKILL to the process group" >&2
            kill -9 -- "-$existing_pid" 2>/dev/null \
                || kill -9 "$existing_pid" 2>/dev/null || true
            # Give the kernel a brief moment to reap, then force-
            # remove the pid file (the trap won't fire on SIGKILL).
            sleep 0.2
            rm -f "$PIDFILE"
        else
            echo "launcher.sh: --replace: watcher $existing_pid exited gracefully" >&2
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
        # operator reading the state dir isn't misled. --replace
        # doesn't change this path — there's no live watcher to wait
        # on, so we don't pay the grace window. We also do NOT signal
        # the recycled PID's current owner: it isn't ours to kill.
        rm -f "$PIDFILE"
    fi
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
# Rotate on spawn past ~10MB (one prior generation kept): the windowed
# watcher had bounded pane scrollback; an append-forever file doesn't.
if [[ -f "$LOGFILE" ]] && (( $(stat -c%s "$LOGFILE" 2>/dev/null || echo 0) > 10485760 )); then
    mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || true
fi
command -v setsid >/dev/null 2>&1 || { echo "launcher.sh: setsid required for headless launch" >&2; exit 2; }
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
if [[ -n "$_RESTART_LOCK_FD" ]]; then
    setsid env WATCHER_WINDOW=headless \
        "$_script_dir/main.sh" --target "$TARGET" </dev/null >>"$LOGFILE" 2>&1 {_RESTART_LOCK_FD}>&- &
else
    setsid env WATCHER_WINDOW=headless \
        "$_script_dir/main.sh" --target "$TARGET" </dev/null >>"$LOGFILE" 2>&1 &
fi

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
    echo "launcher.sh: watcher did not publish a live pidfile within 15s — check $LOGFILE" >&2
    exit 3
fi

echo "launcher.sh: spawned headless pid=$spawned target='$TARGET' log='$LOGFILE'"
