#!/usr/bin/env bash
# paste-followup.sh — the CANONICAL way to paste a follow-up message
# into a worker's tmux window (issue #201).
#
# Why a helper instead of raw tmux commands: every paste fires the
# worker's UserPromptSubmit hook, and the watcher attributes each
# stamped submit to either the operator or the orchestrator (see the
# "operator-engaged marks" section of
# monitor/watcher/_idle_probe.sh). An ORCHESTRATOR paste that isn't
# stamped looks like operator input, falsely marks the window
# `operator-engaged`, and mutes its stall-nag for up to a day. This
# helper stamps the machine-input ledger BEFORE pasting (so a paste
# can never outrun its stamp), then performs the VI-safe paste
# sequence from skills/nexus.tmux-spawn ("Sending follow-up
# messages"), then appends a `paste-followup` action-log event for
# auditability.
#
# Usage:
#   paste-followup.sh <window> --file <path>      message from a file
#   paste-followup.sh <window> --message <text>   message inline
#   paste-followup.sh <window>                    message from stdin
#
# Options:
#   --note <text>      action-log note (what/why of the follow-up)
#   --issue <n>        action-log issue cross-ref
#   --comment <id>     action-log trigger-comment cross-ref
#   --src <label>      injector-identity hint stamped as the ledger's
#                      src column (default `paste-followup`). Lets each
#                      injector class record a distinct, greppable
#                      identity (e.g. `skeptic-nudge`) — purely additive
#                      audit/debug provenance; consumers key on the
#                      window+epoch columns only and ignore src (#293).
#   --no-enter         paste without submitting (rare; queue text only)
#
# Exit: 0 on paste delivered; non-zero with a loud stderr line on any
# failure (window absent, tmux unreachable, empty message). A failed
# action-log append does NOT flip the exit code (the authoritative
# machine-input stamp already landed; the event is audit trail).
#
# tmux ≥ 2.6 compatible: set-buffer -b / paste-buffer -b / send-keys
# only.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf 'paste-followup: %s\n' "$*" >&2; exit 1; }

# State dir resolution — same precedence as monitor/ng:
# NEXUS_STATE_DIR override → NEXUS_ROOT → config nexus.root →
# script-relative fallback.
_resolve_state_dir() {
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
        printf '%s' "$NEXUS_STATE_DIR"
        return 0
    fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then
        printf '%s/monitor/.state' "$NEXUS_ROOT"
        return 0
    fi
    local cfg_root=""
    if [[ -x "$_script_dir/../config/load.sh" ]]; then
        cfg_root=$("$_script_dir/../config/load.sh" nexus.root 2>/dev/null) || cfg_root=""
    fi
    if [[ -n "$cfg_root" ]]; then
        printf '%s/monitor/.state' "$cfg_root"
        return 0
    fi
    printf '%s/.state' "$_script_dir"
}

WINDOW="${1:-}"
[[ -n "$WINDOW" && "$WINDOW" != --* ]] || die "usage: paste-followup.sh <window> [--file <p> | --message <t>] [--note <t>] [--issue <n>] [--comment <id>] [--no-enter]"
shift

MSG_FILE=""
MSG_TEXT=""
NOTE=""
ISSUE=""
COMMENT=""
SRC=""
SEND_ENTER=1
while (( $# > 0 )); do
    case "$1" in
        --file)     MSG_FILE="${2:-}"; shift 2 || die "--file needs a path" ;;
        --message)  MSG_TEXT="${2:-}"; shift 2 || die "--message needs text" ;;
        --note)     NOTE="${2:-}";     shift 2 || die "--note needs text" ;;
        --issue)    ISSUE="${2:-}";    shift 2 || die "--issue needs a number" ;;
        --comment)  COMMENT="${2:-}";  shift 2 || die "--comment needs an id" ;;
        --src)      SRC="${2:-}";      shift 2 || die "--src needs a label" ;;
        --no-enter) SEND_ENTER=0;      shift ;;
        --help|-h)
            sed -n '2,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

if [[ -n "$MSG_FILE" && -n "$MSG_TEXT" ]]; then
    die "--file and --message are mutually exclusive"
fi
MSG=""
if [[ -n "$MSG_FILE" ]]; then
    [[ -r "$MSG_FILE" ]] || die "cannot read --file: $MSG_FILE"
    MSG=$(<"$MSG_FILE")
elif [[ -n "$MSG_TEXT" ]]; then
    MSG="$MSG_TEXT"
else
    [[ -t 0 ]] && die "no --file/--message and stdin is a TTY; nothing to paste"
    MSG=$(cat)
fi
[[ -n "${MSG//[[:space:]]/}" ]] || die "message is empty"

command -v tmux >/dev/null 2>&1 || die "tmux not found on PATH"
if ! tmux list-windows -F '#{window_name}' 2>/dev/null | grep -qxF -- "$WINDOW"; then
    die "tmux window not found: $WINDOW (tmux list-windows to inspect; spawn-worker.sh --resume to recreate)"
fi

# Re-resolve the window NAME → its current @id and target the paste by
# id (#323). A dotted name (`cc-update-2.1.183`) handed to `send-keys
# -t name` / `paste-buffer -t name` dot-parses as window.pane → the
# paste silently never lands. The NAME stays the durable key (it is
# what the operator/orchestrator holds across turns and what the
# machine-input ledger + action log key on); we re-resolve to the
# ephemeral @id only for the actual tmux targeting here.
# shellcheck disable=SC1091
. "$_script_dir/_tmux-window.sh"
WIN_ID=$(resolve_window_id "$WINDOW") \
    || die "could not resolve a tmux window id for: $WINDOW (race with a close? tmux list-windows to inspect)"

# 1. Authoritative machine-input stamp, BEFORE the paste. Plain
#    append — the watcher-side reader takes the max epoch per window
#    and compacts the ledger periodically. A --no-enter paste stamps
#    the distinct `paste-followup-no-enter` src: it still claims the
#    (eventual) submit for the attribution rule, but the watcher's
#    injection↔hook pairing validation must not expect an immediate
#    UserPromptSubmit from a paste that deliberately doesn't submit.
# Default identity is the historical `paste-followup`; --src overrides
# it so each injector class (orchestrator follow-up, skeptic-nudge, …)
# records a distinct, greppable provenance. The `-no-enter` suffix is
# orthogonal and preserved on top of any src so the watcher's
# injection↔hook pairing validation still distinguishes a deliberately
# non-submitting paste.
SRC_TOKEN="${SRC:-paste-followup}"
(( SEND_ENTER )) || SRC_TOKEN="${SRC_TOKEN}-no-enter"
STATE_DIR="$(_resolve_state_dir)"
mkdir -p "$STATE_DIR" || die "cannot create state dir: $STATE_DIR"
printf '%s\t%s\t%s\n' "$WINDOW" "$(date +%s)" "$SRC_TOKEN" \
    >> "$STATE_DIR/machine-input.tsv" \
    || die "cannot stamp $STATE_DIR/machine-input.tsv — refusing to paste unstamped (the watcher would misattribute the input to the operator)"

# 2. VI-safe paste. `i BSpace` forces insert mode regardless of the
#    pane's current VI mode (the lone `i` would self-insert when
#    already in insert mode; BSpace erases it — and in normal mode
#    `i` switches and BSpace is a harmless cursor-left).
BUF="nexus-followup-$$-${RANDOM}"
tmux send-keys -t "$WIN_ID" i BSpace 2>/dev/null \
    || die "tmux send-keys (insert-mode guard) failed for window $WINDOW"
sleep 0.1
tmux set-buffer -b "$BUF" -- "$MSG" \
    || die "tmux set-buffer failed"
if ! tmux paste-buffer -d -b "$BUF" -t "$WIN_ID"; then
    tmux delete-buffer -b "$BUF" 2>/dev/null || true
    die "tmux paste-buffer failed for window $WINDOW"
fi
if (( SEND_ENTER )); then
    sleep 0.2
    tmux send-keys -t "$WIN_ID" Enter \
        || die "tmux send-keys Enter failed for window $WINDOW (message pasted but NOT submitted)"
fi

# 3. Audit-trail action-log event (best-effort; the TSV stamp above
#    is what the attribution rule keys on).
log_args=(monitor --event paste-followup --extra "window=$WINDOW")
[[ -n "$NOTE" ]]    && log_args+=(--note "$NOTE")
[[ -n "$ISSUE" ]]   && log_args+=(--extra "issue=$ISSUE")
[[ -n "$COMMENT" ]] && log_args+=(--extra "comment=$COMMENT")
(( SEND_ENTER ))    || log_args+=(--extra "no_enter=1")
if ! "$_script_dir/ng" log-action "${log_args[@]}" >/dev/null 2>&1; then
    printf 'paste-followup: warning: ng log-action append failed (machine-input stamp already recorded; paste delivered)\n' >&2
fi

printf 'paste-followup: delivered to %s (%s chars%s)\n' \
    "$WINDOW" "${#MSG}" "$( (( SEND_ENTER )) || printf ', NOT submitted' )"
exit 0
