#!/usr/bin/env bash
# Agent-side on-wake bootstrap for the nexus monitor.
#
# Run at the start of every orchestrator turn (or any time the agent
# is unsure whether the watcher is alive). It:
#
#   1. Invokes the shared `_watcher_alive` helper from
#      `monitor/watcher/_lib.sh`. The helper checks heartbeat presence,
#      heartbeat age, the pid recorded in the heartbeat, AND the
#      presence of the `watcher` tmux window — returning one of the
#      buckets 0/1/2/3 documented in `_lib.sh`. On anything but
#      "fresh + alive" (bucket 0), this script respawns the watcher
#      via `monitor/watcher/launcher.sh`. Keeping the check in one
#      place is how we avoid the regression from issue #14 where
#      bootstrap saw a fresh heartbeat with a dead pid and no-op'd.
#   2. Prints any archived diffs newer than `monitor/.state/last-ack.txt`
#      to stdout, one after another, newest-last. Empty output = nothing
#      missed since last ack.
#   3. On success, updates `last-ack.txt` to the current ISO timestamp.
#
# Idempotent: safe to run every turn even when nothing has changed.
# Prints a short status line (`[bootstrap] ...`) to stderr so the agent
# can see what happened; stdout is reserved for the concatenated missed
# diffs so they pipe cleanly into context.
#
# Flags:
#   --no-update-ack   print missed diffs but do not advance last-ack.txt
#                     (for dry-running / debugging)

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_script_dir/.." && pwd)
_nexus_root=$(cd "$_monitor_dir/.." && pwd)
_cfg="$_nexus_root/config/load.sh"

# shellcheck source=_lib.sh
source "$_script_dir/_lib.sh"

# `$NEXUS_ROOT` and `$NEXUS_STATE_DIR` are honored so tests can pin
# everything to a tmpdir without touching the operator's real tree.
# `main.sh` already honors `$NEXUS_ROOT` the same way; this keeps
# bootstrap.sh on the same convention. Production callers leave both
# unset and fall through to the script-relative paths.
NEXUS_ROOT="${NEXUS_ROOT:-$_nexus_root}"
STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
HEARTBEAT="$STATE_DIR/watcher-heartbeat"
LAST_ACK="$STATE_DIR/last-ack.txt"
REPORTS_DIR="$NEXUS_ROOT/reports"

# Override hook for tests: stub out the launcher so race tests don't
# need a real tmux server. Production callers leave it unset.
LAUNCHER_BIN="${BOOTSTRAP_LAUNCHER_BIN:-$_script_dir/launcher.sh}"

INTERVAL="${MONITOR_INTERVAL:-$("$_cfg" monitor.interval_seconds 60)}"

UPDATE_ACK=1
while (( $# > 0 )); do
    case "$1" in
        --no-update-ack) UPDATE_ACK=0; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "bootstrap.sh: unknown flag: $1" >&2; exit 1 ;;
    esac
done

log() { echo "[bootstrap] $*" >&2; }

# Config guard (your-org/your-nexus#236 B11; broadened per the #311
# operator ask). Before probing or respawning the watcher, refuse loudly
# if the nexus is unconfigured: config/load.sh would otherwise serve
# nexus.example.yml's placeholder values (config/nexus.yml is gitignored
# and may be absent in a worktree), and we'd respawn a watcher that posts
# to a non-existent repo and can't mint a bot token — then file a
# misleading "watcher incident" report instead of the real "setup
# required" signal (the TracyY123 symptom in U11). `--validate` covers the
# full required set (identity + the bot credentials mint-token needs), a
# superset of B11's `--check-identity`. Only a definitive placeholder
# verdict (exit 4) stops us; an inconclusive result (no config found —
# e.g. a hermetic test tmpdir) falls through. NEXUS_ROOT is intentionally
# NOT overridden: load.sh resolves the example relative to its own clone.
"$_cfg" --validate || _identity_rc=$?
if [[ "${_identity_rc:-0}" == 4 ]]; then
    log "REFUSING — nexus config is unconfigured (placeholder values; details above)."
    log "Copy config/nexus.example.yml to config/nexus.yml and fill it in, then re-run."
    exit 1
fi
unset _identity_rc

# Serialize concurrent bootstrap invocations. When N agents start their
# turn within the same stale-heartbeat window, each would otherwise see
# "watcher dead" before any wrote a fresh heartbeat and spawn its own
# watcher (issue #43). The lock is non-blocking — losing the race is
# a no-op, not an error: the winner does the check + spawn under
# exclusion, the loser exits 0 without re-checking.
#
# `flock` is reliable on local FS (ext/xfs); `.state/` is per-operator
# local storage, so the NFS-flakiness caveat doesn't apply here.
mkdir -p "$STATE_DIR"
exec {lock_fd}>"$STATE_DIR/watcher-bootstrap.lock"
if ! flock -n "$lock_fd"; then
    log "another agent is bootstrapping; skipping"
    exit 0
fi

# Write a watcher-incident report to reports/. Captures the evidence
# package the monitoring agent needs to triage the death: heartbeat
# state, last-archived-diff, watcher.log tail, and a tmux pane capture
# of the `watcher` window (if the window still exists).
#
# The script does NOT pick between "benign respawn" and "spawn a
# bugfix worker" — that call is the agent's, based on this evidence.
# Stdout: absolute path to the report.
write_incident_report() {
    local reason="$1"
    mkdir -p "$REPORTS_DIR"
    local ts=$(date +%Y-%m-%d_%H%M%S)
    local report="$REPORTS_DIR/nexus_${ts//_/_}_watcher-incident.md"
    # Rename to canonical form: nexus_YYYY-MM-DD_HHMMSS_watcher-incident.md
    report="$REPORTS_DIR/nexus_$(date +%Y-%m-%d)_$(date +%H%M%S)_watcher-incident.md"
    local hb_age="n/a" hb_ts="n/a" hb_pid="n/a" hb_target="n/a"
    if [[ -f "$HEARTBEAT" ]]; then
        hb_age="$(_watcher_heartbeat_age "$HEARTBEAT")s"
        hb_ts=$(date -Is -r "$HEARTBEAT" 2>/dev/null || echo unknown)
        hb_pid=$(_watcher_heartbeat_field "$HEARTBEAT" pid)
        hb_target=$(_watcher_heartbeat_field "$HEARTBEAT" target)
    fi
    local last_diff="(none)"
    if [[ -d "$STATE_DIR/diffs" ]]; then
        last_diff=$(ls -1 "$STATE_DIR/diffs"/*.md 2>/dev/null | tail -1 || true)
        [[ -z "$last_diff" ]] && last_diff="(none)"
    fi
    local log_tail="(no watcher.log)"
    [[ -f "$STATE_DIR/watcher.log" ]] && log_tail=$(tail -40 "$STATE_DIR/watcher.log")
    local pane_tail="(tmux unavailable or window missing)"
    if command -v tmux >/dev/null 2>&1 \
       && tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF watcher; then
        pane_tail=$(tmux capture-pane -t watcher -p -S -80 2>/dev/null || echo "(capture-pane failed)")
    fi
    cat > "$report" <<EOF
# Watcher incident

**Agent:** bootstrap (on-wake check)
**Project:** nexus
**Started:** $(date -Is)
**Status:** reported

## What Was Done
- bootstrap.sh detected: $reason
- emitting this evidence-package report before respawning the watcher
  via \`monitor/watcher/launcher.sh\`.

## Current State
- heartbeat mtime: $hb_ts (age=$hb_age)
- heartbeat pid: ${hb_pid:-n/a}
- heartbeat target: ${hb_target:-n/a}
- last archived diff: ${last_diff##*/}

## What Remains
- Monitoring agent (you) reads this report and decides:
  * **Benign respawn**: nothing actionable in the evidence below —
    the respawn bootstrap already fired is enough. Log with
    \`monitor/ng log-action monitor --event watcher-respawn \\
      --note benign --extra report=$(basename "$report")\`.
  * **Bug suspected**: kill the freshly-respawned watcher
    (\`tmux kill-window -t watcher\`), spawn a worker agent in a new
    tmux window (e.g. \`watcher-fix\`) briefed with this report,
    have them land a fix on a branch, redeploy via the launcher,
    and schedule a short-lived \`CronCreate\` (~every 10-15 min)
    that confirms the new watcher reached at least 3 consecutive
    healthy heartbeats before cancelling itself.

## How to Resume
- re-run \`monitor/watcher/bootstrap.sh\` to pick up any missed diffs
  and advance last-ack.

## Infrastructure Issues

### Bug candidates

#### Last 40 lines of monitor/.state/watcher.log
\`\`\`
$log_tail
\`\`\`

#### Last 80 lines of tmux window \`watcher\` pane
\`\`\`
$pane_tail
\`\`\`

#### Last archived diff
$([[ "$last_diff" != "(none)" ]] && echo "\`$last_diff\`" || echo "(none)")
EOF
    printf '%s' "$report"
}

# --- (1) liveness probe ---------------------------------------------------
#
# Delegates the heartbeat / pid-identity check to _watcher_alive in
# _lib.sh (the watcher is headless — no window check). Bucket 0 =
# fresh + alive; anything else means the watcher is not healthy and we
# respawn. The human-readable reason (for the log + incident report)
# comes from _watcher_reason.

_watcher_alive "$STATE_DIR" "$INTERVAL"
alive_rc=$?
respawn_needed=0
incident_reason=""
case $alive_rc in
    0)  age=$(_watcher_heartbeat_age "$HEARTBEAT")
        log "heartbeat OK (${age}s)" ;;
    *)  incident_reason=$(_watcher_reason "$STATE_DIR")
        log "$incident_reason"
        respawn_needed=1 ;;
esac

if (( respawn_needed == 1 )); then
    # Evidence package before we respawn — the monitoring agent
    # reads this to pick between "benign respawn" and "spawn bugfix
    # worker". The script itself does not triage; it just collects.
    report_path=$(write_incident_report "$incident_reason")
    log "incident report: $report_path"
    log "respawning via launcher.sh"
    if "$LAUNCHER_BIN" >&2; then
        log "launcher exited OK"
    else
        log "launcher exited nonzero (rc=$?)"
    fi

    # A dead watcher is the strongest signal the whole stack went down
    # (machine / tmux restart — the 2026-06-07 incident). Bring back
    # the registered infra services too. `--services-only` because we
    # just relaunched the watcher above; the sweep is idempotent
    # (healthy / window-present services are left untouched) and a
    # missing registry degrades to a no-op. Best-effort + guarded so a
    # service-recovery hiccup never blocks the diff catch-up below, and
    # older trees without the script just skip it.
    recover_bin="$_script_dir/../bootstrap-recover.sh"
    if [[ -x "$recover_bin" ]]; then
        log "full-stack service recovery: bootstrap-recover.sh --services-only"
        "$recover_bin" --services-only >&2 \
            || log "bootstrap-recover.sh exited nonzero (rc=$?)"
    fi
fi

# --- (2) missed diffs -----------------------------------------------------
#
# Archive is a directory of files sorted by filename timestamp. We print
# everything newer than last-ack.txt (by mtime); if last-ack.txt is
# missing, we print everything. No CLI wrapper: this is a one-liner.
diff_dir="$STATE_DIR/diffs"
if [[ -d "$diff_dir" ]]; then
    if [[ -f "$LAST_ACK" ]]; then
        mapfile -t missed < <(find "$diff_dir" -maxdepth 1 -type f -name '*.md' -newer "$LAST_ACK" 2>/dev/null | sort)
    else
        mapfile -t missed < <(find "$diff_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort)
    fi
    if (( ${#missed[@]} > 0 )); then
        for f in "${missed[@]}"; do
            printf '>>> %s\n' "$(basename "$f")"
            cat -- "$f"
            printf '\n'
        done
    else
        log "no missed diffs since $(test -f "$LAST_ACK" && cat "$LAST_ACK" || echo epoch)"
    fi
else
    log "diff archive dir missing (first-run?)"
fi

# --- (3) advance ack ------------------------------------------------------

if (( UPDATE_ACK == 1 )); then
    date -Is > "$LAST_ACK"
fi
