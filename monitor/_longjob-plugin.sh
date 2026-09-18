# shellcheck shell=bash
# monitor/_longjob-plugin.sh — sourced helper: SHOULD this launch arm the
# longjob-watch dispatcher, and with which flag? (your-org/nexus-code#1535)
#
#   longjob_plugin_flag [<window>] [<state-dir>]
#                                    → stdout: `--plugin-dir <dir>` or NOTHING
#                                      rc 0 armed · 1 not armed (reason on stderr)
#
# FAIL OPEN, BY CONSTRUCTION. Every launch surface in this nexus (worker
# spawn, worker resume, the claude-loop wrapper, the orchestrator respawn)
# calls this and splices whatever it prints into the `claude` command line.
# A session must launch with the plugin missing, malformed, disabled, or
# unsupported by the binary, because the alternative — a `claude` that
# refuses to start — breaks the watcher's own revival path, which nothing on
# the board can fix from inside. So this function NEVER exits, never returns
# a partial flag, and turns every doubt into "no flag + one stderr line":
#
#   1. kill switch:   monitor.longjob.enabled / MONITOR_LONGJOB_ENABLED
#                     (its OWN knob, not shared with any other feature — a
#                     field that selects is not a label, #1050)
#   2. the manifest must exist and be readable
#   3. the binary must advertise `--plugin-dir <path>` (capability probe,
#      bounded, monitor/_claude-bin.sh:claude_supports_plugin_dir_flag)
#   4. `claude plugin validate <dir>` must pass (bounded; a timeout is NOT
#      a pass; warnings are)
#
# MEASURED 2026-09-15 on 2.1.272, hermetic tmux, one session per case: a
# missing plugin dir, a malformed manifest, a manifest whose command does
# not exist, and a command that exits 3 at once ALL start a session that
# takes turns; the host logs the failure and continues. So steps 2–4 are not
# what keeps the board alive — the host already fails open — they are what
# keeps the failure LOUD and keeps a broken manifest from being handed to a
# session where its only symptom is an absent monitor.
#
# EVERY DECISION IS RECORDED in <state-dir>/longjob/arming.log
# (`<epoch>\t<window>\t<armed|skipped>\t<reason>\t<src>`), a detector that is
# not the emit path: `longjob-watch.sh status` and a human can read WHY a
# session was launched without a dispatcher, which the session itself
# cannot know.
#
# WHICH state dir: the CALLER's second argument first, then $NEXUS_STATE_DIR,
# then the inherited $NEXUS_ROOT, then this file's own tree. The caller's
# argument exists because of a measured leak (bundle-2609 soak, 2026-09-16):
# the operator's LIVE arming.log carried 17 `skipped … does not advertise`
# rows for `orchestrator` and `mission-control` that no launch ever wrote —
# test suites respawning against a FIXTURE root (test-target-config.sh,
# test-assert-shims-wrapped.sh) while this helper resolved its log from the
# agent shell's inherited NEXUS_ROOT, which is the primary. That log is where
# `skills/nexus.longjob` sends an agent to read WHY a session is unarmed, so
# fixture rows there manufacture a false diagnosis. `_respawn.sh` and
# `spawn-worker.sh` now pass the state dir they have already resolved.
# The fifth column is the producing SUITE when run under
# watcher/run-tests.sh (NEXUS_TEST_SUITE, the same field `ng`'s usage tap
# writes, #720) and EMPTY for a real launch — so a row naming a suite is a
# fixture row by construction, and `nexus-root-sensitivity.sh attribute`
# gates on it exactly as it gates `ng-usage.jsonl`.
#
# Requires $CLAUDE_BIN (source monitor/_claude-bin.sh first). $NEXUS_ROOT is
# the PRIMARY root (state); the plugin ships in the same tree as this file,
# which is what `_lj_plugin_dir` points at — a launcher in a secondary clone
# arms the clone's own dispatcher code, and the dispatcher routes its STATE to
# the primary through NEXUS_ROOT exactly as every other worker tool does.

_lj_plugin_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_lj_plugin_dir() { printf '%s/longjob-plugin' "$_lj_plugin_lib_dir"; }

_lj_plugin_log() {   # <window> <verdict> <reason> [<state-dir>]
    local sd="${4:-${NEXUS_STATE_DIR:-${NEXUS_ROOT:-$_lj_plugin_lib_dir/..}/monitor/.state}}"
    local src="${NEXUS_TEST_SUITE:-}"; src="${src//[^A-Za-z0-9:\/._-]/}"
    mkdir -p "$sd/longjob" 2>/dev/null || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%s)" "${1:--}" "$2" "${3//$'\n'/ }" "$src" >> "$sd/longjob/arming.log" 2>/dev/null || true
}

longjob_plugin_flag() {
    local win="${1:-${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-}}}"
    local sd="${2:-}"
    local enabled="${MONITOR_LONGJOB_ENABLED:-}" dir rc tb=""
    if [[ -z "$enabled" && -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/config/load.sh" ]]; then
        enabled=$("$NEXUS_ROOT/config/load.sh" monitor.longjob.enabled true 2>/dev/null) || enabled=true
    fi
    case "${enabled:-true}" in
        1|true|yes|on) ;;
        *)  echo "_longjob-plugin: longjob-watch dispatcher DISABLED (monitor.longjob.enabled / MONITOR_LONGJOB_ENABLED=${enabled}) — NOT passing --plugin-dir; this session cannot be woken by a long job (your-org/nexus-code#1535)." >&2
            _lj_plugin_log "$win" skipped "disabled: monitor.longjob.enabled=$enabled" "$sd"; return 1 ;;
    esac
    dir=$(_lj_plugin_dir)
    if [[ ! -r "$dir/.claude-plugin/plugin.json" ]]; then
        echo "_longjob-plugin: plugin manifest missing or unreadable at $dir/.claude-plugin/plugin.json — NOT passing --plugin-dir; this session cannot be woken by a long job (your-org/nexus-code#1535)." >&2
        _lj_plugin_log "$win" skipped "manifest unreadable: $dir" "$sd"; return 1
    fi
    if [[ -z "${CLAUDE_BIN:-}" ]]; then
        echo "_longjob-plugin: CLAUDE_BIN unset (source monitor/_claude-bin.sh first) — NOT passing --plugin-dir (your-org/nexus-code#1535)." >&2
        _lj_plugin_log "$win" skipped "CLAUDE_BIN unset" "$sd"; return 1
    fi
    if ! declare -F claude_supports_plugin_dir_flag >/dev/null 2>&1; then
        echo "_longjob-plugin: _claude-bin.sh has no claude_supports_plugin_dir_flag (older primary?) — NOT passing --plugin-dir (your-org/nexus-code#1535)." >&2
        _lj_plugin_log "$win" skipped "no capability probe in _claude-bin.sh" "$sd"; return 1
    fi
    if ! claude_supports_plugin_dir_flag; then
        _lj_plugin_log "$win" skipped "binary does not advertise --plugin-dir (or --help unreadable/timed out)" "$sd"; return 1
    fi
    # Bounded validate. `timeout` injects 124/137, neither of which is a
    # validator verdict (your-org/nexus-code#1248); both are "not armed".
    if command -v timeout >/dev/null 2>&1; then tb="timeout -k 2 ${NEXUS_LONGJOB_VALIDATE_TIMEOUT:-20}"; fi
    # shellcheck disable=SC2086
    $tb "$CLAUDE_BIN" plugin validate "$dir" >/dev/null 2>&1; rc=$?
    case "$rc" in
        0) ;;
        124|137)
            echo "_longjob-plugin: 'claude plugin validate' TIMED OUT (rc $rc) — NOT passing --plugin-dir; a validator this slow is a degraded binary or a stalled filesystem, not an answer (your-org/nexus-code#1535)." >&2
            _lj_plugin_log "$win" skipped "validate timed out rc=$rc" "$sd"; return 1 ;;
        *)
            echo "_longjob-plugin: 'claude plugin validate $dir' FAILED (rc $rc) — NOT passing --plugin-dir; fix the manifest (run the validate command by hand for the errors). This session cannot be woken by a long job (your-org/nexus-code#1535)." >&2
            _lj_plugin_log "$win" skipped "validate failed rc=$rc" "$sd"; return 1 ;;
    esac
    _lj_plugin_log "$win" armed "$dir" "$sd"
    printf -- '--plugin-dir %q' "$dir"
    return 0
}
