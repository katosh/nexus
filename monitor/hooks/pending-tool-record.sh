#!/usr/bin/env bash
# pending-tool-record.sh — PreToolUse/PostToolUse bookkeeping for the
# `pending-tool` record the orchestrator's decision-emit reads.
#
# ---------------------------------------------------------------------
# THIS HOOK FAILS OPEN. ALWAYS. IT EXITS 0 ON EVERY PATH.
# ---------------------------------------------------------------------
#
# It used to be an inline pipeline in monitor/worker-settings.json:
#
#     mkdir -p $NEXUS_ROOT/monitor/.state/pending-tool \
#       && jq -c '{...}' > $NEXUS_ROOT/monitor/.state/pending-tool/$WINDOW.json
#
# whose exit status was the exit status of a redirection into the project
# tree. On 2026-07-09 that tree went read-only, the redirect failed, and
# the hook's non-zero exit propagated into Claude Code's PreToolUse gate —
# so a bookkeeping write that nobody was waiting on took out `Bash`,
# `Write`, `Edit` and `NotebookEdit` for every hook-gated worker in the
# workspace. A storage hiccup became a total tool outage. (Independently
# confirmed by `w455-r3-skeptic` during the incident.)
#
# This record is a convenience for a status emit. It is NOT a security
# boundary, NOT a lock, and NOT a precondition for the tool call being
# safe. Nothing downstream is unsound if it is missing — `decision-emit.sh`
# already treats an absent file as "no tool context". So: when it cannot be
# written, warn on stderr and get out of the way.
#
# Usage (from settings.json hooks):
#   PreToolUse :  monitor/hooks/pending-tool-record.sh
#   PostToolUse:  monitor/hooks/pending-tool-record.sh --clear
#
# Exit status: 0. Unconditionally. If you find yourself adding a non-zero
# exit here, re-read the paragraph above; `test-fs-guard.sh` T6 will fail.

# No `set -e` and no `set -o pipefail` on purpose — a failing write inside
# this script must never become this script's exit status.
set -u

_warn() { printf 'pending-tool-record: %s\n' "$*" >&2; }

_root="${NEXUS_ROOT:-}"
_window="${NEXUS_WORKER_WINDOW:-}"

if [[ -z "$_root" || -z "$_window" ]]; then
    # Drain stdin so the producer never sees EPIPE, then leave.
    [[ "${1:-}" == "--clear" ]] || cat >/dev/null 2>&1
    _warn "NEXUS_ROOT/NEXUS_WORKER_WINDOW unset — skipping (tool call proceeds)"
    exit 0
fi

_dir="$_root/monitor/.state/pending-tool"
_file="$_dir/$_window.json"

if [[ "${1:-}" == "--clear" ]]; then
    rm -f "$_file" 2>/dev/null \
        || _warn "could not remove $_file (read-only filesystem?) — harmless, proceeding"
    exit 0
fi

# PreToolUse: stdin is the tool-call JSON. Consume it exactly once, so a
# failed write still drains the pipe rather than stranding the producer.
_payload=$(cat 2>/dev/null)

if ! mkdir -p "$_dir" 2>/dev/null; then
    _warn "could not create $_dir (read-only filesystem?) — proceeding WITHOUT a pending-tool record"
    exit 0
fi

_tmp="$_file.$$.tmp"
if ! printf '%s' "$_payload" \
        | jq -c '{tool:.tool_name, input_summary:(.tool_input | tostring | .[0:200]), ts:now}' \
        > "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" 2>/dev/null
    _warn "could not write $_file (read-only filesystem? malformed payload?) — proceeding WITHOUT a pending-tool record"
    exit 0
fi

# Atomic publish, so decision-emit never reads a half-written record.
mv -f "$_tmp" "$_file" 2>/dev/null || {
    rm -f "$_tmp" 2>/dev/null
    _warn "could not publish $_file — proceeding WITHOUT a pending-tool record"
}

exit 0
