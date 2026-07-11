#!/usr/bin/env bash
# shellcheck shell=sh
# monitor/_log-mode.sh — create service logs with an explicit mode
# (your-org/nexus-code#484).
#
# THE DEFECT. A bare `>>"$lf"` creates the file under the ambient umask.
# On this operator's stack that is `007`, so `0666 & ~007` = **0660** —
# group-writable — inside a group-shared project tree (`drwxrws---` on
# /shared). Eight of nine registry service logs were created that way.
#
# This is a LOG-INTEGRITY concern, not a confidentiality one. The
# contents are connection IPs, key fingerprints and service stdout;
# nothing secret leaks. But a group-writable log is a log whose contents
# cannot be trusted as evidence: any member of the unix group can append
# to it, truncate it, or rewrite it, and nothing would record that they
# did. We reason from these logs routinely — liveness, incident
# forensics, "did the watcher emit" — so they must be
# append-only-by-their-writer in practice.
#
# THE MODE MUST BE SET WHERE THE FILE IS CREATED, not where it is
# trimmed. `_remote_rotate_service_log` (monitor/_remote_lib.sh) already
# does `chmod 640`, but only after its size check passes — so rotation
# repairs exactly the logs that grow past 8 MiB and survive to be
# rotated. A log that is created, written for a week, and then read as
# evidence is never touched by it.
#
# TARGET MODE 0640, deliberately not 0600: group *read* is wanted (the
# tree is group-shared and `svc.sh logs` tails these files); group
# *write* is the defect.
#
# Usage — call immediately before the redirect that would create the log:
#
#     . "$(dirname "${BASH_SOURCE[0]}")/_log-mode.sh"
#     _ensure_service_log "$lf"
#     setsid bash -c "$inner" </dev/null >>"$lf" 2>&1 &
#
# POSIX sh, deliberately. `monitor/gh-shim.sh` is a `sh` library, so this
# file avoids `[[ ]]`, `local`, and `test -O` (dash has none of them) and
# namespaces its variables `_esl_*` so a sourced call can never clobber a
# caller's `lf` / `dir`. One implementation, every consumer.
#
# CONTRACT — this helper must NEVER fail a service launch. It returns 0
# unconditionally. Every step is best-effort:
#   - a log owned by another uid (nginx rotates its own access.log;
#     labsh writes its own) is left strictly alone — we do not even
#     attempt the chmod, because the EPERM is guaranteed and meaningless;
#   - an unwritable parent, a read-only FS, a racing creator: swallowed;
#   - an existing log is NEVER truncated (`:>>` appends nothing) and
#     never LOOSENED — `g-w,o-rwx` only ever removes bits, so a log
#     already at 0600 stays 0600.
# It is idempotent: safe to call on every launch, and on every append.

# Create `$1` if absent, and ensure it is not group- or other-writable.
_ensure_service_log() {
    _esl_lf="${1:-}"
    [ -n "$_esl_lf" ] || return 0

    _esl_dir=$(dirname -- "$_esl_lf" 2>/dev/null) || return 0
    [ -d "$_esl_dir" ] || mkdir -p -- "$_esl_dir" 2>/dev/null || true

    # Create under a tight umask rather than creating then chmod-ing:
    # there is no window in which the file exists group-writable.
    # `:>>` is an append-open — it can never truncate an existing log,
    # even if the `-e` guard loses a race with a concurrent creator.
    if [ ! -e "$_esl_lf" ]; then
        ( umask 0027; : >> "$_esl_lf" ) 2>/dev/null || true
    fi

    # Repair a pre-existing log, but only one we own. chmod on another
    # uid's file always fails; skipping is honest, not merely quieter.
    # `stat -c %u` rather than `test -O`: dash has no `-O`.
    [ -f "$_esl_lf" ] || return 0
    _esl_uid=$(stat -c %u -- "$_esl_lf" 2>/dev/null) || return 0
    [ -n "$_esl_uid" ] || return 0
    [ "$_esl_uid" = "$(id -u)" ] || return 0
    chmod g-w,o-rwx -- "$_esl_lf" 2>/dev/null || true
    return 0
}
