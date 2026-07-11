#!/usr/bin/env bash
# _fs_probe.sh — the canonical "is this directory writable RIGHT NOW"
# probe for the nexus. Dual-mode: source it for the functions, or run it
# as a CLI.
#
# ---------------------------------------------------------------------
# THE LOAD-BEARING CONSTRAINT: a FRESH open(), never a cached fd.
# ---------------------------------------------------------------------
#
# An already-open file descriptor keeps working after its mount is
# detached. During both read-only-remount incidents (2026-06-29 and
# 2026-07-09) the RUNNING watcher held `watcher.log` open and therefore
# logged normally, at full fidelity, straight through a total filesystem
# outage. Nothing it wrote was a lie; its fd simply outlived its mount.
#
# The successor watcher had to resolve the same path afresh. It died in
# `launcher.sh`'s `>>"$LOGFILE"` redirection — a fresh open() — before a
# single line of `main.sh` ran.
#
# The consequence for this file: a probe that appends to an fd it already
# holds reports HEALTHY during a total outage. That is strictly worse than
# having no probe at all, because it converts an outage into a lie. Every
# probe below therefore performs a create + unlink of a NEW path on EVERY
# call. Do not "optimise" this into a held fd, a memoised result, or a
# stat() of a pre-existing file. `test-fs-guard.sh` T2 pins exactly this
# property and will fail if you do.
#
# Errno-agnostic by design: EROFS (read-only mount), EACCES (mode bits),
# and ENOSPC (full filesystem) are all "cannot write watcher state", which
# is the only condition callers act on. That is also what lets a 0555
# fixture dir stand in hermetically for a read-only mount in tests.
#
# Usage (CLI):
#   _fs_probe.sh <dir>            prints 'OK' or 'READ-ONLY'; exit 0 / 1
#   _fs_probe.sh -q <dir>         exit status only
#
# Usage (sourced):
#   source monitor/_fs_probe.sh
#   nexus_dir_writable "$STATE_DIR" || handle_read_only
#   nexus_fs_status "$STATE_DIR"    # -> 'OK' | 'READ-ONLY'

# nexus_dir_writable <dir>
#
# 0 if <dir> accepts a new file right now, 1 otherwise (including when
# <dir> does not exist or is not a directory). Never writes anything that
# outlives the call: the probe file is unlinked on success, and on failure
# it was never created.
nexus_dir_writable() {
    local dir="${1:?dir required}"
    [[ -d "$dir" ]] || return 1
    # Distinct name per call. `$$` alone collides across calls in one
    # process; the counter makes successive probes in a single shell
    # provably distinct paths, so no call can ever be served by a
    # previous call's inode.
    _NEXUS_FS_PROBE_SEQ=$(( ${_NEXUS_FS_PROBE_SEQ:-0} + 1 ))
    local t="$dir/.nexus-fs-probe.$$.${RANDOM:-0}.${_NEXUS_FS_PROBE_SEQ}"
    # A subshell redirection: O_WRONLY|O_CREAT|O_TRUNC on a path resolved
    # NOW. Returns cleanly on EROFS rather than segfaulting the way some
    # libraries do on a read-only mount.
    if ( : > "$t" ) 2>/dev/null; then
        rm -f "$t" 2>/dev/null
        return 0
    fi
    return 1
}

# nexus_nearest_existing_dir <path>
#
# Walk up to the nearest existing ancestor DIRECTORY of <path>. Used when a
# target may not exist yet: a not-yet-created `monitor/.state` on a healthy
# filesystem must not be mistaken for a read-only one.
nexus_nearest_existing_dir() {
    local p="${1:?path required}"
    while [[ -n "$p" && "$p" != "/" && ! -e "$p" ]]; do
        p="${p%/*}"
        [[ -z "$p" ]] && p="/"
    done
    if [[ -e "$p" && ! -d "$p" ]]; then
        p="${p%/*}"
        [[ -z "$p" ]] && p="/"
    fi
    printf '%s' "$p"
}

# nexus_path_writable <path>
#
# Like nexus_dir_writable, but tolerant of a <path> that does not exist yet:
# it probes the nearest existing ancestor. Callers that must treat a missing
# directory as a FAILURE (the watcher's state dir, revive-watcher) keep using
# nexus_dir_writable; callers that merely ask "could I write here" (svc.sh's
# status row on a fresh clone) use this.
nexus_path_writable() {
    nexus_dir_writable "$(nexus_nearest_existing_dir "${1:?path required}")"
}

# nexus_fs_status <dir> — the human-facing word for the probe result.
nexus_fs_status() {
    if nexus_dir_writable "${1:?dir required}"; then
        printf 'OK'
    else
        printf 'READ-ONLY'
    fi
}

# CLI mode only when executed directly; sourcing yields the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -u
    _quiet=0
    [[ "${1:-}" == "-q" ]] && { _quiet=1; shift; }
    _dir="${1:-}"
    if [[ -z "$_dir" ]]; then
        echo "usage: _fs_probe.sh [-q] <dir>" >&2
        exit 2
    fi
    if nexus_dir_writable "$_dir"; then
        (( _quiet )) || echo OK
        exit 0
    fi
    (( _quiet )) || echo READ-ONLY
    exit 1
fi
