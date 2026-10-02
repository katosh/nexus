#!/usr/bin/env bash
# Worker context-budget scan — the orchestrator-facing half of issue #2.
#
# A worker at 600k context pays ~6x per tool call what the same worker
# paid at 100k, and nothing in the current lifecycle notices. Measured
# 2026-07-31: four worker sessions between 465k and 997k max context,
# one of them 790M cache-read tokens in a single 2-day run.
#
# The worker floor (skills/nexus.worker-defaults) tells a worker to
# self-rotate at the threshold. This file is the backstop for the
# workers that DON'T — a wedged agent, one mid-task and unwilling to
# stop, or one whose floor predates the rule. It scans worker contexts
# on a slow cadence and surfaces the over-threshold ones to the
# orchestrator, which owns wrap-up + respawn.
#
# ── A NOTE ON THE ISSUE TEXT ──────────────────────────────────────────
# Issue #2's proposal says "the watcher already computes an `over-limit`
# count in the workspace line; make that threshold context-based". That
# is a misreading, and following it would have broken a working feature.
# `over-limit` (issue #87) counts panes suspended by the Anthropic
# **rate limit** — the "You've hit your limit · resets <time>" notice,
# stamped by monitor/hooks/over-limit-emit.sh from a `rate_limit`
# StopFailure payload. It is a *functional suspension with a reset time*,
# and the watcher schedules resume wakes against it. It has nothing to
# do with context size, and re-pointing it at a token threshold would
# have silently destroyed the rate-limit resume machinery.
#
# So this adds a SEPARATE axis rather than repurposing that one.
# ──────────────────────────────────────────────────────────────────────
#
# WHY A CACHED SCAN AND NOT A LIVE READ. Measuring a worker costs a
# `tail` + `jq` per window. `_compose_report_body` runs on every compose
# cycle; doing that inline for every worker would put N subprocesses on
# the watcher's synchronous hot path, which has a ≤100 ms budget. So the
# scan is a scheduled ASYNC task on a slow cadence (default 300 s —
# context does not move fast enough to warrant more) that writes a TSV,
# and the renderer just reads the file.
#
# WHY THE RENDERED SECTION CARRIES NO LIVE TOKEN FIGURE PER ROW. It
# reports a bucketed `>=<threshold>` marker, not the exact count. The
# emit-dedup stable hash and the full-state canonical identity check
# both compare rendered bodies; a per-row number that drifts every scan
# would make every emit unique, defeat both gates, and generate exactly
# the extra wakes this whole effort exists to remove. The one place an
# exact figure appears is the summary line, which changes only when a
# worker crosses the threshold. See `_emit_volatile_strip` in
# _emit_dedup.sh — same contract, different mechanism.
#
# Functions:
#   _context_scan_workers <state_dir> <nexus_root>
#       Scan every non-reserved worker window; write
#       `<window>\t<tokens>\t<over>\t<epoch>` to
#       `$state_dir/worker-context.tsv` (atomic tmp+rename).
#       Windows whose context can't be resolved are OMITTED, never
#       written as 0 — an unresolved read must not read as "healthy".
#
#   _context_over_emit_section <state_dir>
#       Render the `--- workers over context ---` body from that TSV,
#       or nothing. Ignores a stale TSV (older than
#       MONITOR_CONTEXT_SCAN_STALE_SECONDS) rather than nagging on
#       numbers that may predate a rotation that already happened.
#
# Side-effect-free on source: function definitions only.
#
# Caller globals (read at CALL time):
#   MONITOR_CONTEXT_ROTATION_ENABLED       master switch
#   MONITOR_CONTEXT_ROTATION_WORKER_TOKENS threshold
#   MONITOR_CONTEXT_SCAN_STALE_SECONDS     TSV freshness bound
#   log                                    watcher logger (optional)

_CONTEXT_SCAN_TSV_NAME="worker-context.tsv"

# Scan worker windows and refresh the TSV. Slow path; called from the
# scheduler, never from compose.
_context_scan_workers() {
    local state_dir="${1:-}" nexus_root="${2:-}"

    local enabled="${MONITOR_CONTEXT_ROTATION_ENABLED:-true}"
    [[ "$enabled" == "true" ]] || return 0

    local threshold="${MONITOR_CONTEXT_ROTATION_WORKER_TOKENS:-250000}"
    [[ "$threshold" =~ ^[0-9]+$ ]] || return 0
    (( threshold > 0 )) || return 0

    local helper="$nexus_root/monitor/context-usage.sh"
    [[ -x "$helper" ]] || return 0
    [[ -d "$state_dir" ]] || return 0

    # `_idle_list_worker_windows` (sourced from _idle_probe.sh by the
    # caller) already excludes the orchestrator target, the cockpit,
    # registered services, and the reserved names. Degrade to no-op if
    # it isn't available rather than inventing a second window list.
    declare -F _idle_list_worker_windows >/dev/null 2>&1 || return 0

    local dest="$state_dir/$_CONTEXT_SCAN_TSV_NAME"
    local tmp="$dest.tmp.$$"
    local now win tokens rc out over n_over=0 n_seen=0
    now=$(date +%s)

    : > "$tmp" 2>/dev/null || return 0
    while IFS=$'\t' read -r win _ _; do
        [[ -n "$win" ]] || continue
        n_seen=$(( n_seen + 1 ))
        rc=0
        out=$(NEXUS_ROOT="$nexus_root" NEXUS_STATE_DIR="$state_dir" \
              "$helper" --window "$win" --threshold "$threshold" 2>/dev/null) || rc=$?
        # rc 1 (unresolved) → omit the row entirely. A worker we cannot
        # measure is unknown, not fine.
        (( rc == 0 || rc == 10 )) || continue
        tokens=$(sed -n 's/.*\btokens=\([0-9]*\).*/\1/p' <<<"$out")
        [[ "$tokens" =~ ^[0-9]+$ ]] || continue
        over=0
        (( rc == 10 )) && { over=1; n_over=$(( n_over + 1 )); }
        printf '%s\t%s\t%s\t%s\n' "$win" "$tokens" "$over" "$now" >> "$tmp"
    done < <(_idle_list_worker_windows 2>/dev/null)

    mv -f "$tmp" "$dest" 2>/dev/null || { rm -f "$tmp"; return 0; }

    if declare -F log >/dev/null 2>&1; then
        log "context-scan: ${n_seen} worker window(s) scanned, ${n_over} at/over ${threshold} tokens"
    fi
    return 0
}

# Render the over-context section body, or nothing.
_context_over_emit_section() {
    local state_dir="${1:-}"

    local enabled="${MONITOR_CONTEXT_ROTATION_ENABLED:-true}"
    [[ "$enabled" == "true" ]] || return 0

    local threshold="${MONITOR_CONTEXT_ROTATION_WORKER_TOKENS:-250000}"
    [[ "$threshold" =~ ^[0-9]+$ ]] || return 0
    (( threshold > 0 )) || return 0

    local tsv="$state_dir/$_CONTEXT_SCAN_TSV_NAME"
    [[ -f "$tsv" ]] || return 0

    # Staleness guard. A TSV from before the last scan cadence may name
    # a worker that has since rotated or been retired; nagging on it
    # would cost a wake and be wrong.
    local stale="${MONITOR_CONTEXT_SCAN_STALE_SECONDS:-1800}"
    [[ "$stale" =~ ^[0-9]+$ ]] || stale=1800
    if (( stale > 0 )); then
        local file_ts now_ts
        file_ts=$(stat -c %Y "$tsv" 2>/dev/null || echo 0)
        now_ts=$(date +%s)
        [[ "$file_ts" =~ ^[0-9]+$ ]] || file_ts=0
        (( now_ts - file_ts < stale )) || return 0
    fi

    local rows
    rows=$(awk -F'\t' -v thr="$threshold" '
        $3 == 1 && $1 != "" {
            # Bucketed, NOT the live figure — see the header note on
            # why an exact per-row number would defeat emit dedup.
            printf "  %s — context >= %s tokens\n", $1, thr
            n++
        }
        END { exit (n ? 0 : 1) }
    ' "$tsv" 2>/dev/null) || return 0
    [[ -n "$rows" ]] || return 0

    printf 'These workers are past the context threshold (%s tokens). Every\n' "$threshold"
    printf 'tool call they make from here is billed at that size:\n'
    printf '%s\n' "$rows"
    printf 'For each: check whether it is mid-task. If it has a report, close it\n'
    printf 'out (`monitor/ng wrap-up-check <window>`) and respawn from the report.\n'
    printf 'If it does not, ask it to file one first — a bare kill loses the work.\n'
    printf 'A worker legitimately needing one long session (stateful kernel, long\n'
    printf 'debug thread) is a valid exception: leave it and say so.\n'
}
