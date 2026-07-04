#!/usr/bin/env bash
# Compose-emit "nudge on new events" hook for the v2 scheduler.
#
# Why this exists. `_v2_task_compose_emit` runs at MONITOR_INTERVAL
# cadence (~60 s base). `deliveries_poll` fires every 15 s and appends
# fresh GitHub events to `$STATE_DIR/deliveries-queue.lines` (durable
# queue from PR #186); `github_poll` fires every 600 s and writes raw
# bytes to the scheduler staging `<stage>/github_poll.out`. Without a
# nudge, a delivery that lands one second after compose_emit's last fire
# sits in the queue for the full 60 s drain window. Observed worst case
# was 52 s end-to-end latency on your-org/your-nexus #1 comment
# 4559632841 (2026-05-27), of which ~50 s was the queue→drain gap.
#
# What it does. Once per scheduler tick (called by main.sh's
# `_scheduler_post_tick_hook`) the helper compares the current mtimes
# of the two source files against the last-seen mtimes held in module-
# scoped integer variables. When either mtime advances AND the file has
# bytes, the helper calls:
#
#   _schedule_fire_now  compose_emit          # next_fire ← 0
#   _schedule_override  compose_emit 5 60     # 5 s cadence for 60 s
#
# Identical primitive pair to `_v2_task_target_window_probe`'s rc=2
# branch (`monitor/watcher/main.sh` near the target-absent handler), so
# the scheduler test suite §8d coverage carries over to this trigger.
#
# Size guard. `github_poll.out` is atomically replaced on every fire via
# tmp+rename — the mtime advances even when the helper produced zero
# bytes. Without `size > 0` every 600 s GraphQL backstop tick would
# re-nudge for no useful work; with the guard, only non-empty fires
# trigger compose_emit. The deliveries queue is append-only and only
# created when a block is non-empty (`_append_to_deliveries_queue`
# early-returns on empty blocks), so the same size > 0 check is a no-op
# on its happy path but defensive against test fixtures.
#
# State persistence. Module variables. A watcher restart drops them
# back to 0, so a pre-existing non-empty queue or staging file nudges
# once on the first post-startup tick — which is exactly what we want:
# any unprocessed work surfaces immediately.
#
# Scope. The nudge is *additive*: compose_emit's MONITOR_INTERVAL base
# cadence and the 600 s github_poll backstop cadence are untouched. The
# only behaviour change is "demand-driven re-fire when new events
# arrive." `MONITOR_FULL_STATE_EMIT_INTERVAL_SECONDS` (the dead-state
# floor) is intentionally not touched — it's a different lever with
# different semantics.

# ---- double-source guard ------------------------------------------------
if [[ -n "${_NEXUS_COMPOSE_NUDGE_LOADED:-}" ]]; then
    return 0
fi
_NEXUS_COMPOSE_NUDGE_LOADED=1

# Module state: last observed mtime per source. 0 sentinel = never seen.
# Persists across ticks within a single watcher process; resets on
# restart (intentional — see "State persistence" above).
_compose_nudge_last_queue_mtime=0
_compose_nudge_last_github_mtime=0

# Return mtime in epoch seconds; 0 when the file is absent or stat fails.
_compose_nudge_mtime() {
    local f="$1"
    [[ -f "$f" ]] || { printf '0\n'; return 0; }
    stat -c %Y "$f" 2>/dev/null || printf '0\n'
}

# Return size in bytes; 0 when the file is absent or stat fails.
_compose_nudge_size() {
    local f="$1"
    [[ -f "$f" ]] || { printf '0\n'; return 0; }
    stat -c %s "$f" 2>/dev/null || printf '0\n'
}

# _compose_emit_nudge_check <queue_file> <gh_out_file>
#
# Returns 0 if a nudge fired (force-fire + override applied); 1 if not.
# Idempotent: a second call with unchanged mtimes is a no-op. The
# last-seen mtime advances regardless of size so a sequence of
# empty github_poll fires only consults the size guard once each.
_compose_emit_nudge_check() {
    local queue_file="$1" gh_out_file="$2"
    local queue_mtime queue_size gh_mtime gh_size
    queue_mtime=$(_compose_nudge_mtime "$queue_file")
    queue_size=$(_compose_nudge_size  "$queue_file")
    gh_mtime=$(_compose_nudge_mtime "$gh_out_file")
    gh_size=$(_compose_nudge_size  "$gh_out_file")

    local should_nudge=0

    if (( queue_mtime > _compose_nudge_last_queue_mtime )); then
        _compose_nudge_last_queue_mtime=$queue_mtime
        (( queue_size > 0 )) && should_nudge=1
    fi

    if (( gh_mtime > _compose_nudge_last_github_mtime )); then
        _compose_nudge_last_github_mtime=$gh_mtime
        (( gh_size > 0 )) && should_nudge=1
    fi

    (( should_nudge == 1 )) || return 1

    # Guard against the registry being absent (test scaffolds, very-
    # early-startup sequences). `_schedule_*` already returns 64 with a
    # stderr message in that case; silence noise here so the post-tick
    # hook stays best-effort.
    [[ -n "${TASK_FN[compose_emit]:-}" ]] || return 1
    _schedule_fire_now compose_emit 2>/dev/null || true
    _schedule_override compose_emit 5 60 2>/dev/null || true
    return 0
}

# Reset module state for tests. The watcher itself does not call this —
# state persists across ticks within the running process.
_compose_nudge_reset_for_tests() {
    _compose_nudge_last_queue_mtime=0
    _compose_nudge_last_github_mtime=0
}
