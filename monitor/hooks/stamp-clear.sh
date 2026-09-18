#!/usr/bin/env bash
# monitor/hooks/stamp-clear.sh — the `Stop`-hook CLEAR for a per-window stamp
# (your-org/nexus-code#1143).
#
# Usage, from a settings.json `Stop` block:
#
#   $NEXUS_ROOT/monitor/hooks/stamp-clear.sh over-limit
#   $NEXUS_ROOT/monitor/hooks/stamp-clear.sh turn-failure
#
# WHAT IT REPLACES, and why a script rather than a repaired string. The clear
# used to be a bare `rm -f` written out three times in two JSON files:
#
#   worker-settings.json:        rm -f $NEXUS_ROOT/monitor/.state/over-limit/$NEXUS_WORKER_WINDOW.json
#   worker-settings.json:        rm -f $NEXUS_ROOT/monitor/.state/turn-failure/$NEXUS_WORKER_WINDOW.json
#   orchestrator-settings.json:  rm -f "$NEXUS_ROOT/monitor/.state/over-limit/${NEXUS_ORCHESTRATOR_WINDOW:-orchestrator}.json"
#
# Each hardcoded `$NEXUS_ROOT/monitor/.state` while BOTH writers
# (`over-limit-emit.sh`, `turn-failure-emit.sh`) honour `NEXUS_STATE_DIR`. Under
# any override the stamp is written where `pane-state.sh` reads it and cleared
# where nobody wrote — so the cleanup contract each writer documents ("the file
# persists until a successful Stop event clears it") is unreachable by
# construction. The two worker forms additionally left `$NEXUS_WORKER_WINDOW`
# UNQUOTED, so an unset window expanded to `.../over-limit/.json`.
#
# Every one of those failures is silent: `rm -f` on a path that does not exist
# succeeds and prints nothing. The clear therefore reported success for a stamp
# it never touched — this workspace's dominant defect class, a manufactured
# success whose only evidence is an absence.
#
# WHY THAT IS EXPENSIVE. `pane-state.sh` §1b short-circuits to
# `state=over-limit` on the stamp's presence and returns BEFORE inspecting the
# pane. An unclearable stamp is therefore a PERMANENT false `over-limit` for
# that pane — read by the watcher's scan, the orchestrator's emit gate, the
# wake-paste path and `retire-preflight.sh` alike. `#1141` measured the cost of
# a stamp that merely cleared LATE; one that cannot clear at all is strictly
# worse.
#
# The path is resolved by `_stamp_path.sh`, which the writers also use, so the
# clear cannot be wrong without the writer being wrong in the same way. That
# co-wrongness is the property being bought; two independently-correct string
# literals are what this replaced.
#
# EXIT STATUS IS ALWAYS 0. A Stop hook must never block or fail a turn. An
# unresolvable path is not an error here — a pane with no window name never had
# a stamp to clear. `NEXUS_STAMP_CLEAR_DEBUG=1` reports what was resolved on
# stderr, for the suites; the hot path prints nothing.

set -u

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || exit 0
[[ -r "$_self_dir/_stamp_path.sh" ]] || exit 0
# shellcheck source=/dev/null
. "$_self_dir/_stamp_path.sh" || exit 0

kind="${1:-}"

# `stamp_file` fails closed — it prints NOTHING and returns 1 rather than a
# half-resolved path. Captured into a variable and tested, never interpolated
# straight into the `rm`, because `rm -f ""` is a no-op that looks like nothing
# whereas `rm -f "/over-limit/.json"` is a no-op that looks like a path.
target=$(stamp_file "$kind") || target=""

if [[ -z "$target" ]]; then
    if [[ -n "${NEXUS_STAMP_CLEAR_DEBUG:-}" ]]; then
        printf 'stamp-clear: unresolved (kind=%s window=%s state_dir=%s)\n' \
            "${kind:-<none>}" \
            "${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-<none>}}" \
            "${NEXUS_STATE_DIR:-${NEXUS_ROOT:+$NEXUS_ROOT/monitor/.state}}" >&2
    fi
    exit 0
fi

rm -f -- "$target" 2>/dev/null || true

if [[ -n "${NEXUS_STAMP_CLEAR_DEBUG:-}" ]]; then
    printf 'stamp-clear: cleared %s\n' "$target" >&2
fi

exit 0
