#!/usr/bin/env bash
# Cold-boot trigger for the nexus stack — a thin, idempotent,
# non-blocking guard meant to be fired from a boot/login context (a
# Claude Code SessionStart hook on the orchestrator, or a login-shell
# line). It decides whether the stack needs recovery and, if so,
# launches `bootstrap-recover.sh` in the background so it can never
# block the login / session start that invoked it.
#
# WHY this exists (the gap it closes)
# -----------------------------------
# `bootstrap-recover.sh` is the idempotent full-stack recovery, but
# nothing ran it at a true cold boot. Its only triggers were (a) the
# orchestrator running it by hand on wake, and (b) `bootstrap.sh`'s
# watcher-respawn path — both of which presuppose the orchestrator is
# already alive and taking turns. On a genuine sandbox/machine reboot,
# until something first revives the orchestrator nothing re-establishes
# the watcher or the registered infra services. This guard is the
# missing automatic trigger: wired to the orchestrator's SessionStart
# (`resume`) hook it fires the instant the chaperon brings the
# orchestrator back via `claude --resume` — the one component that
# reliably returns at boot — and from there re-establishes the rest.
#
# HONESTY — the limits of an in-sandbox trigger
# ---------------------------------------------
# The agent-sandbox mounts $HOME as an ephemeral tmpfs overlay and
# bind-mounts the real ~/.zprofile / ~/.zshrc / ~/.profile READ-ONLY,
# so a login-shell hook cannot be persisted from inside the sandbox.
# `systemctl --user` has no bus and cron has no spool here, so neither
# a user systemd unit nor an @reboot crontab is available either. The
# only persistent, sandbox-writable surfaces are the project repo and
# $CLAUDE_CONFIG_DIR (~/.claude/...). A SessionStart hook in the latter
# is therefore the strongest trigger deliverable from within the
# sandbox. A trigger that fires with ZERO dependence on the
# orchestrator resuming must live OUTSIDE the sandbox — see the
# operator one-liners in monitor/README.md ("Cold-boot recovery
# trigger"): the real ~/.zprofile (edited outside the sandbox) or a
# sandbox.conf on-start entry, each invoking THIS script.
#
# Behaviour
# ---------
#   1. Debounce. If this guard ran within BOOT_RECOVER_DEBOUNCE_SECONDS
#      (default 300), no-op. Many login shells / hook fires can stack
#      up at boot; the stamp under $STATE_DIR makes them collapse to a
#      single recovery attempt. `--force` bypasses the debounce.
#   2. Health gate. Ask `bootstrap-recover.sh --dry-run` whether it
#      WOULD launch anything (its stable `would relaunch` / `would run`
#      / `would resume` markers — services, watcher, workers). Nothing
#      to do -> the stack is healthy -> no-op, no background process
#      spawned.
#   3. Recover. Otherwise launch `bootstrap-recover.sh` detached
#      (nohup, output to $STATE_DIR/boot-recover.log) and return
#      immediately. The heavy lifting never blocks the caller.
#
# Safe to run anytime, by anyone, as often as you like: the debounce
# plus bootstrap-recover.sh's own idempotence (never double-launches a
# healthy or window-present service) make repeated invocations benign.
#
# Usage:
#   monitor/boot-recover.sh            # gate + (maybe) background recover
#   monitor/boot-recover.sh --force    # ignore the debounce stamp
#   monitor/boot-recover.sh --sync     # run recovery in the foreground
#                                       #   (don't background; for debugging)
#
# Env overrides (production leaves all unset):
#   NEXUS_ROOT                     — repo root (default: script-relative).
#   NEXUS_STATE_DIR                — state dir (default:
#                                    $NEXUS_ROOT/monitor/.state).
#   BOOT_RECOVER_BIN               — bootstrap-recover.sh (tests stub it).
#   BOOT_RECOVER_DEBOUNCE_SECONDS  — debounce window (default 300).

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_nexus_root_default=$(cd "$_script_dir/.." 2>/dev/null && pwd || echo "$_script_dir/..")
NEXUS_ROOT="${NEXUS_ROOT:-$_nexus_root_default}"

STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
BOOT_RECOVER_BIN="${BOOT_RECOVER_BIN:-$_script_dir/bootstrap-recover.sh}"
DEBOUNCE="${BOOT_RECOVER_DEBOUNCE_SECONDS:-300}"
STAMP="$STATE_DIR/boot-recover.stamp"
LOG="$STATE_DIR/boot-recover.log"

FORCE=0
SYNC=0

log() { echo "[boot-recover] $*" >&2; }

# True (0) when the debounce stamp exists and is younger than the
# debounce window. A non-numeric or future-dated stamp is treated as
# absent (fall through to a fresh attempt) rather than wedging the
# guard forever.
_within_debounce() {
    [[ "$DEBOUNCE" =~ ^[0-9]+$ ]] || return 1
    (( DEBOUNCE > 0 )) || return 1
    [[ -f "$STAMP" ]] || return 1
    local now stamp_mtime age
    now=$(date +%s)
    stamp_mtime=$(stat -c '%Y' "$STAMP" 2>/dev/null || stat -f '%m' "$STAMP" 2>/dev/null || echo "")
    [[ "$stamp_mtime" =~ ^[0-9]+$ ]] || return 1
    age=$(( now - stamp_mtime ))
    (( age >= 0 && age < DEBOUNCE ))
}

_write_stamp() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    : > "$STAMP" 2>/dev/null || true
}

# Ask bootstrap-recover.sh (dry-run, launches nothing) whether the
# stack needs recovery. Returns 0 when at least one watcher/service/
# worker WOULD be (re)launched — detected via its stable dry-run
# markers (`would run` watcher, `would relaunch` service, `would
# resume` worker) — and 1 when everything is healthy / window-present
# (nothing to do).
# A missing or non-executable recovery binary is reported as
# "needs recovery" so the real run surfaces the misconfiguration in
# the log rather than silently no-opping.
_recovery_needed() {
    [[ -x "$BOOT_RECOVER_BIN" ]] || return 0
    local dry
    dry=$("$BOOT_RECOVER_BIN" --dry-run 2>&1)
    grep -qE 'would (relaunch|run|resume)' <<<"$dry"
}

_run_recovery() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if (( SYNC == 1 )); then
        "$BOOT_RECOVER_BIN" >>"$LOG" 2>&1
        return $?
    fi
    # Detach fully so neither the login shell nor the SessionStart
    # hook waits on recovery. nohup + background + disown; the parent
    # returns straight away.
    nohup "$BOOT_RECOVER_BIN" >>"$LOG" 2>&1 &
    disown 2>/dev/null || true
    return 0
}

main() {
    while (( $# > 0 )); do
        case "$1" in
            --force) FORCE=1; shift ;;
            --sync)  SYNC=1; shift ;;
            -h|--help) sed -n '2,60p' "$0"; return 0 ;;
            *) echo "boot-recover.sh: unknown flag: $1" >&2; return 1 ;;
        esac
    done

    if (( FORCE == 0 )) && _within_debounce; then
        log "ran within ${DEBOUNCE}s (stamp $STAMP) — skipping"
        return 0
    fi

    if ! _recovery_needed; then
        log "stack healthy — nothing to recover"
        # Stamp anyway so a burst of login shells at boot doesn't each
        # re-probe; the next genuine need still fires after the window.
        _write_stamp
        return 0
    fi

    log "stack needs recovery — launching bootstrap-recover.sh ($([[ $SYNC == 1 ]] && echo sync || echo background))"
    _write_stamp
    _run_recovery
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit $?
fi
