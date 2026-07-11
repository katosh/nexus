#!/usr/bin/env bash
# node-forensics.sh — host-side resource black-box for the nexus node.
#
# WHY THIS EXISTS
#   The nexus agents run inside an agent-sandbox that lives in its OWN PID
#   namespace (`readlink /proc/self/ns/pid` != the host init ns). From inside
#   the sandbox `ps -e` sees ONLY the sandbox user's processes — it is
#   structurally blind to other users and to the node-wide PID table. That is
#   exactly the view you need to catch a fork bomb / PID-exhaustion event
#   (your-org/nexus-code#449, and the 2026-07-08 recurrence: a recursive-
#   subshell fork bomb from the watcher test-suite exhausted pid_max=36864 and
#   triggered a full-stack orchestrator recovery).
#
#   So this monitor MUST run on the HOST, OUTSIDE the sandbox, launched by the
#   operator. It periodically samples the WHOLE node and appends a compact
#   snapshot to a rotating log under the shared project dir, which the sandbox
#   can read back after a crash. On a threshold breach it writes a louder
#   ALERT with a fuller dump — the black-box that survives the next event.
#
# DESIGN CONSTRAINTS (a monitor that itself leaks would be ironic and dangerous)
#   - Read-only sampling only (ps / cat /proc). Never forks per-process.
#   - Bounded work per tick (fixed top-N, one ps call, awk aggregation).
#   - Size-capped log with rotation, so it can't fill the disk.
#   - One sleep per loop; no unbounded inner loops.
#   - Dependency-light: bash + coreutils + procps (ps, awk, sort, date). No
#     python, no jq, nothing exotic — it must run on a bare host shell.
#
# USAGE
#   ./monitor/node-forensics.sh &            # foreground loop, backgrounded
#   nohup ./monitor/node-forensics.sh >/dev/null 2>&1 &   # detached
#   NF_INTERVAL=15 NF_LOAD_ALERT=80 ./monitor/node-forensics.sh &
#   ./monitor/node-forensics.sh --once       # single snapshot, then exit
#
# ENV KNOBS (all optional; defaults are conservative)
#   NF_OUTDIR        log directory (default: <repo>/monitor/.state/node-forensics)
#   NF_INTERVAL      seconds between snapshots            (default 20)
#   NF_TOPN          top-N processes by CPU and by RSS    (default 12)
#   NF_LOAD_ALERT    1-min loadavg breach threshold       (default 64)
#   NF_PID_ALERT_PCT proc-count % of pid_max that alerts  (default 70)
#   NF_MAXBYTES      rotate current log when it exceeds    (default 5000000 = ~5MB)
#   NF_KEEP          rotated logs to retain               (default 5)
#
# OUTPUT
#   $NF_OUTDIR/node-forensics.log        rolling snapshots (+ ALERT records)
#   $NF_OUTDIR/node-forensics.log.1..N   rotated history
#   $NF_OUTDIR/last-alert.txt            most recent ALERT dump (quick read)
#
# STOP:  kill the PID you backgrounded (it also traps INT/TERM and exits clean).
#        pgrep -f node-forensics.sh   # find it (host side; safe outside sandbox)

set -uo pipefail

# --- resolve repo root so the default log path lands in the shared project dir
_self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"        # .../monitor
_repo="$(cd "$_self/.." && pwd)"                             # repo root

NF_OUTDIR="${NF_OUTDIR:-$_repo/monitor/.state/node-forensics}"
NF_INTERVAL="${NF_INTERVAL:-20}"
NF_TOPN="${NF_TOPN:-12}"
NF_LOAD_ALERT="${NF_LOAD_ALERT:-64}"
NF_PID_ALERT_PCT="${NF_PID_ALERT_PCT:-70}"
NF_MAXBYTES="${NF_MAXBYTES:-5000000}"
NF_KEEP="${NF_KEEP:-5}"

LOG="$NF_OUTDIR/node-forensics.log"
LAST_ALERT="$NF_OUTDIR/last-alert.txt"

mkdir -p "$NF_OUTDIR" || { echo "node-forensics: cannot create $NF_OUTDIR" >&2; exit 1; }

# `_ensure_service_log` (your-org/nexus-code#484): forensics output is read
# as evidence after an incident, so it must not be group-writable.
# shellcheck source=_log-mode.sh
source "$_self/_log-mode.sh"
_ensure_service_log "$LOG"

_running=1
trap '_running=0' INT TERM

# --- pid_max ceiling (the #449 failure surface). Read once; cheap.
_pid_max="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 0)"

# Rotate the current log when it grows past the cap. Size-based, bounded:
# shift .N-1 -> .N and current -> .1. Best-effort; never fatal.
_rotate_if_needed() {
    local sz
    sz="$(wc -c < "$LOG" 2>/dev/null || echo 0)"
    [[ "$sz" =~ ^[0-9]+$ ]] || return 0
    (( sz < NF_MAXBYTES )) && return 0
    local i
    for (( i=NF_KEEP-1; i>=1; i-- )); do
        [[ -f "$LOG.$i" ]] && mv -f "$LOG.$i" "$LOG.$((i+1))" 2>/dev/null || true
    done
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
    # `mv` took the old inode away, so this RE-CREATES the log. A bare
    # `: > "$LOG"` would mint it group-writable under the ambient umask —
    # rotation must not undo what creation got right (#484).
    _ensure_service_log "$LOG"
}

# One snapshot -> stdout. Pure sampling: a single ps for the process table,
# reused via a temp string, aggregated with awk. No per-process forks.
_snapshot() {
    local ts la ln procs threads pid_pct alert=0 reason=""
    ts="$(date -Is 2>/dev/null || date)"
    ln="$(cat /proc/loadavg 2>/dev/null || echo '? ? ? ?/? ?')"
    la="$(printf '%s' "$ln" | awk '{print $1}')"           # 1-min
    threads="$(printf '%s' "$ln" | awk '{split($4,a,"/"); print a[2]}')"

    # Single node-wide ps sample (host namespace sees ALL users). Kept in a
    # var so we aggregate without re-sampling (consistent + cheap).
    local snap
    snap="$(ps -eo user:20,pid,ppid,pcpu,pmem,rss,etimes,stat,comm --no-headers 2>/dev/null)"
    procs="$(printf '%s\n' "$snap" | grep -c . )"

    # PID pressure: proc count as % of pid_max (the exhaustion metric).
    if [[ "$_pid_max" =~ ^[0-9]+$ ]] && (( _pid_max > 0 )); then
        pid_pct=$(( procs * 100 / _pid_max ))
    else
        pid_pct=0
    fi

    # Threshold checks (integer-compare loadavg via its integer part).
    local la_int="${la%%.*}"; [[ "$la_int" =~ ^[0-9]+$ ]] || la_int=0
    if (( la_int >= NF_LOAD_ALERT )); then alert=1; reason+="load1=${la}>=${NF_LOAD_ALERT} "; fi
    if (( pid_pct >= NF_PID_ALERT_PCT )); then alert=1; reason+="procs=${procs}(${pid_pct}%pid_max) "; fi

    # Per-user aggregation: total %CPU and process count, top offenders first.
    local byuser
    byuser="$(printf '%s\n' "$snap" | awk '{cpu[$1]+=$4; n[$1]++} END{for(u in cpu) printf "%8.1f %6d  %s\n", cpu[u], n[u], u}' | sort -rn | head -8)"

    # Top-N by CPU and by RSS (user pid ppid cpu% mem% rssKB etimes stat comm).
    local topcpu toprss
    topcpu="$(printf '%s\n' "$snap" | sort -k4 -rn | head -n "$NF_TOPN" | awk '{printf "  %-14s pid=%-7s ppid=%-7s cpu=%-5s mem=%-4s rss=%-9s et=%-7s %s %s\n",$1,$2,$3,$4,$5,$6,$7,$8,$9}')"
    toprss="$(printf '%s\n' "$snap" | sort -k6 -rn | head -n "$NF_TOPN" | awk '{printf "  %-14s pid=%-7s ppid=%-7s rss=%-9s cpu=%-5s et=%-7s %s %s\n",$1,$2,$3,$6,$4,$7,$8,$9}')"

    # Compact one-line summary always; fuller block only on ALERT.
    printf '[%s] load=%s procs=%s/%s(%s%%pid_max) threads=%s\n' \
        "$ts" "$la" "$procs" "$_pid_max" "$pid_pct" "$threads"
    printf '  by-user(cpu%% procN): %s\n' \
        "$(printf '%s' "$byuser" | awk '{printf "%s=%s/%s ", $3,$1,$2}')"

    if (( alert == 1 )); then
        {
            printf '  *** ALERT: %s***\n' "$reason"
            printf '  --- per-user (cpu%%  procN  user) ---\n%s\n' "$byuser"
            printf '  --- top %s by CPU ---\n%s\n' "$NF_TOPN" "$topcpu"
            printf '  --- top %s by RSS ---\n%s\n' "$NF_TOPN" "$toprss"
        }
        # Also drop a standalone last-alert file for a fast post-crash read.
        {
            printf 'ALERT @ %s\nreason: %s\nload1=%s procs=%s/%s(%s%%) threads=%s\n\n' \
                "$ts" "$reason" "$la" "$procs" "$_pid_max" "$pid_pct" "$threads"
            printf '=== per-user (cpu%% procN user) ===\n%s\n\n' "$byuser"
            printf '=== top %s by CPU ===\n%s\n\n' "$NF_TOPN" "$topcpu"
            printf '=== top %s by RSS ===\n%s\n' "$NF_TOPN" "$toprss"
        } > "$LAST_ALERT" 2>/dev/null || true
    fi
}

# --once: one snapshot to stdout, no file, no loop (for testing / manual peek).
if [[ "${1:-}" == "--once" ]]; then
    _snapshot
    exit 0
fi

# Startup banner into the log so a reader knows the monitor's config + PID.
{
    printf '===== node-forensics START %s pid=%s host=%s =====\n' \
        "$(date -Is 2>/dev/null || date)" "$$" "$(hostname 2>/dev/null || echo '?')"
    printf '  interval=%ss topN=%s load_alert=%s pid_alert=%s%% pid_max=%s outdir=%s\n' \
        "$NF_INTERVAL" "$NF_TOPN" "$NF_LOAD_ALERT" "$NF_PID_ALERT_PCT" "$_pid_max" "$NF_OUTDIR"
} >> "$LOG" 2>/dev/null || true

while (( _running == 1 )); do
    _rotate_if_needed
    _snapshot >> "$LOG" 2>/dev/null || true
    # One bounded sleep per loop. `sleep` is interrupted by the trap so
    # INT/TERM exits promptly without waiting out the interval.
    sleep "$NF_INTERVAL" &
    wait $! 2>/dev/null || true
done

printf '===== node-forensics STOP %s pid=%s =====\n' \
    "$(date -Is 2>/dev/null || date)" "$$" >> "$LOG" 2>/dev/null || true
