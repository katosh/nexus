#!/usr/bin/env bash
# _entry_signals.sh — restore a SIGINT that was already IGNORED when this shell
# started, by re-exec'ing through an interpreter that can reset it
# (your-org/nexus-code#1445).
#
# WHY A SOURCED HELPER AND NOT `set -m`. Bash keeps a signal that was ignored
# at entry ignored for the life of the shell — `trap` on it is a no-op, and
# `set -m` only changes what bash does for the async children IT starts. The
# ignore itself arrives from an ANCESTOR: a non-interactive shell starting an
# async command with job control OFF sets SIGINT/SIGQUIT to SIG_IGN, and the
# ignore is inherited across every exec below it. `monitor/async-run.sh`'s
# `setsid bash … &`, the Bash tool's `run_in_background`, and a bare
# `nohup … &` all leave it behind. Measured on this host:
#
#     bash -c 'trap -p INT'                              # (empty)  — foreground
#     bash -c '( bash -c "trap -p INT" & wait )'         # trap -- '' SIGINT
#     bash -c '( bash -c "set -m; ( bash -c \"trap -p INT\" & wait )" & wait )'
#                                                        # trap -- '' SIGINT — `set -m` in the middle cannot undo it
#
# So a suite that sends SIGINT to a child it started and expects the child's
# INT trap to fire is green in the foreground (CI) and red under every
# backgrounded launcher on an operator's board — the child never installs the
# handler, the signal is dropped, and the suite reads a missed deadline as a
# regression. The TERM arm of the same suite stays green, because `&` never
# ignores SIGTERM. That asymmetry is the fingerprint.
#
# The only repair is to reset the disposition in a process that CAN — python3
# or perl set SIG_DFL and exec — before bash starts. Hence: source this file
# first, then call `entry_signals_restore_or_exec "$0" "$@"`. It returns 0
# when nothing was ignored, and never returns when it re-execs. A loop guard
# (`NEXUS_ENTRY_SIGNALS_RESTORED`) makes a failed restore LOUD (exit 96) rather
# than an infinite re-exec.
#
# Driven by monitor/watcher/test-entry-signals.sh.

entry_signals_ignored() {
    # `trap -p INT` prints `trap -- '' SIGINT` for a signal ignored at entry.
    local t; t=$(trap -p INT 2>/dev/null) || t=""
    [[ "$t" == *"''"* ]]
}

entry_signals_restore_or_exec() {
    entry_signals_ignored || return 0
    if [[ -n "${NEXUS_ENTRY_SIGNALS_RESTORED:-}" ]]; then
        printf '%s: SIGINT is STILL ignored after a re-exec that should have restored it — refusing to run a signal test whose signal cannot arrive (your-org/nexus-code#1445)\n' \
            "${0##*/}" >&2
        exit 96
    fi
    export NEXUS_ENTRY_SIGNALS_RESTORED=1
    if command -v python3 >/dev/null 2>&1; then
        exec python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' bash "$@"
    elif command -v perl >/dev/null 2>&1; then
        exec perl -e '$SIG{INT} = "DEFAULT"; $SIG{QUIT} = "DEFAULT"; exec @ARGV or die "exec: $!"' bash "$@"
    fi
    printf '%s: SIGINT is ignored at entry and neither python3 nor perl is available to restore it (your-org/nexus-code#1445)\n' \
        "${0##*/}" >&2
    exit 96
}
