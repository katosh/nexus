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
# messages"), then CONFIRMS the submission against the target
# session's own transcript, then appends a `paste-followup`
# action-log event for auditability.
#
# THE CONFIRMATION, and why it exists (issue #507). `tmux send-keys
# … Enter` returning 0 means tmux accepted a keystroke. It does NOT
# mean Claude Code submitted the prompt. This script used to print
# `delivered` unconditionally on that rc=0 — an assertion about an
# outcome it never observed. On 2026-07-09 a 4,136-char correction
# printed `delivered`, no UserPromptSubmit fired, and the target
# spent twenty minutes working against the very story the correction
# existed to retract. Only the watcher's `paste-unconfirmed` detector
# caught it. The sender must not need the watcher to find out whether
# it succeeded.
#
# So: after the Enter we poll a POST-CONDITION, bounded by a timeout,
# and the exit code reports only what we actually established.
#
#   THE EVIDENCE (two surfaces, either suffices):
#   a. The target session's own transcript
#      (`<cc-home>/projects/<slug>/<session-id>.jsonl`) gains a
#      TUI-submission record. This is Claude Code's own ledger; it is
#      authoritative.
#   b. The worker's UserPromptSubmit hook stamp
#      (`<state-dir>/user-prompt/<window>` = `epoch<TAB>session-id`)
#      advances past our paste epoch, for the SAME session-id. This is
#      the contract event the watcher already trusts.
#
#   NOT evidence, and why:
#   - `send-keys` rc — see above. This is the whole bug.
#   - The pane's scrollback. Claude Code collapses a long paste into a
#     `[Pasted text #N +N lines]` placeholder, so the pasted content
#     NEVER enters the pane. Grepping capture-pane for it cannot work.
#     (That placeholder is also why we retry the Enter once: a
#     collapsed paste can need a second Enter to submit.)
#
#   CLASSIFYING A TRANSCRIPT LINE. Every user-role line — including
#   every tool_result — is `"type":"user"`, so "a new user message"
#   is far too coarse a test: a busy agent emits them continuously.
#   Worse, Claude Code injects `<task-notification>` messages as
#   *string-content* user lines, which a content-shape test would
#   happily mistake for our prompt. The discriminator is the
#   `promptSource` field:
#       typed / queued / suggestion_accepted → a TUI submission ✓
#       system                               → task-notification ✗
#       sdk                                  → subagent / SDK turn  ✗
#       (absent)                             → a tool_result, or a
#                                              pre-`promptSource`
#                                              Claude Code
#   We therefore accept any PRESENT promptSource that is not `system`
#   or `sdk` (permissive against new TUI values), reject sidechain and
#   meta lines, and fall back to a string-content test only for
#   transcripts old enough to lack the field entirely.
#
#   FINDING THE TRANSCRIPT. We resolve the target's session-id from
#   its heartbeat (`<state-dir>/heartbeat/<window>.json`), then glob
#   `<cc-home>/projects/*/<session-id>.jsonl`. Two traps, both paid
#   for in blood:
#   - Do NOT pick "the newest jsonl in the project dir". A worker and
#     its skeptic share a clone, so one project dir holds several
#     sessions. The session-id is the key.
#   - Do NOT hand-derive the project-dir slug. The transform maps `/`
#     AND `_` to `-` (`/shared/your-lab-m/…` → `-fh-fast-setty-m-…`),
#     which is easy to get wrong; and a bare `find` over `~/.claude`
#     descends into `file-history/` + `cache/` and takes minutes.
#     Session-ids are UUIDs — globally unique — so a bounded glob over
#     `projects/*/` finds the file without deriving the slug at all.
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
#   --no-enter         paste without submitting (rare; queue text only).
#                      Skips confirmation — nothing was meant to submit.
#   --confirm-timeout <sec>
#                      total budget for the submission post-condition.
#                      Env: PASTE_CONFIRM_TIMEOUT_SECONDS; config:
#                      monitor.paste_confirm_timeout_seconds; default 20.
#
# Outcomes — the printed line and the exit code agree, always:
#   0  `submitted`                      evidence (a) or (b) observed.
#   0  `pasted (NOT submitted, --no-enter)`
#                                       deliberate; no claim made.
#   1  hard failure (usage, empty message, window absent, tmux error).
#   3  `pasted (submission unconfirmed: …)`
#      We could not establish EITHER outcome. Three causes, each named
#      in the message: no heartbeat/session-id/transcript to poll; the
#      session-id changed under us (the window was resumed mid-paste);
#      or a turn was in flight — the transcript grew, but with no
#      submission record, so our text is plausibly QUEUED behind the
#      running turn and will submit when it drains. Re-check; do not
#      assume either way.
#   4  `pasted (NOT submitted)`
#      Established negative: the Enter was retried once, the budget
#      elapsed, and the session stayed completely inert. The text is
#      sitting in the input box. This is the #507 failure, caught.
#
# The machine-input stamp is deliberately NOT rolled back on 3/4: the
# paste really did land in the pane, and leaving the stamp is what
# lets the watcher's `paste-unconfirmed` detector agree with us.
#
# A failed action-log append does NOT flip the exit code (the
# authoritative machine-input stamp already landed; the event is
# audit trail).
#
# Test seams (hermetic suite; never set in production):
#   NEXUS_STATE_DIR   state dir override.
#   NEXUS_CC_HOME     sole Claude-Code home to search for `projects/*/`.
#   PASTE_NG_BIN      `ng` binary for the action-log append.
#   PASTE_CONFIRM_POLL_SECONDS   confirmation poll interval (default 0.3).
#
# tmux ≥ 2.6 compatible: set-buffer -b / paste-buffer -b / send-keys
# only.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { printf 'paste-followup: %s\n' "$*" >&2; exit 1; }

# Exit codes for the confirmation verdicts (see header).
readonly RC_UNCONFIRMED=3
readonly RC_NOT_SUBMITTED=4

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

# Total confirmation budget: env → config → default.
_resolve_confirm_timeout() {
    local t="${PASTE_CONFIRM_TIMEOUT_SECONDS:-}"
    if [[ ! "$t" =~ ^[0-9]+$ ]]; then
        t=""
        if [[ -x "$_script_dir/../config/load.sh" ]]; then
            t=$("$_script_dir/../config/load.sh" monitor.paste_confirm_timeout_seconds 20 2>/dev/null) || t=""
        fi
        [[ "$t" =~ ^[0-9]+$ ]] || t=20
    fi
    printf '%s' "$t"
}

WINDOW="${1:-}"
[[ -n "$WINDOW" && "$WINDOW" != --* ]] || die "usage: paste-followup.sh <window> [--file <p> | --message <t>] [--note <t>] [--issue <n>] [--comment <id>] [--confirm-timeout <sec>] [--no-enter]"
shift

MSG_FILE=""
MSG_TEXT=""
NOTE=""
ISSUE=""
COMMENT=""
SRC=""
SEND_ENTER=1
CONFIRM_TIMEOUT=""
while (( $# > 0 )); do
    case "$1" in
        --file)     MSG_FILE="${2:-}"; shift 2 || die "--file needs a path" ;;
        --message)  MSG_TEXT="${2:-}"; shift 2 || die "--message needs text" ;;
        --note)     NOTE="${2:-}";     shift 2 || die "--note needs text" ;;
        --issue)    ISSUE="${2:-}";    shift 2 || die "--issue needs a number" ;;
        --comment)  COMMENT="${2:-}";  shift 2 || die "--comment needs an id" ;;
        --src)      SRC="${2:-}";      shift 2 || die "--src needs a label" ;;
        --confirm-timeout) CONFIRM_TIMEOUT="${2:-}"; shift 2 || die "--confirm-timeout needs seconds" ;;
        --no-enter) SEND_ENTER=0;      shift ;;
        --help|-h)
            awk 'NR > 1 { if ($0 == "") exit; print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

[[ -n "$CONFIRM_TIMEOUT" ]] || CONFIRM_TIMEOUT=$(_resolve_confirm_timeout)
[[ "$CONFIRM_TIMEOUT" =~ ^[0-9]+$ ]] || die "--confirm-timeout must be a non-negative integer: $CONFIRM_TIMEOUT"
POLL="${PASTE_CONFIRM_POLL_SECONDS:-0.3}"

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

STATE_DIR="$(_resolve_state_dir)"
mkdir -p "$STATE_DIR" || die "cannot create state dir: $STATE_DIR"

# ---- submission post-condition (issue #507) --------------------------

# A TUI-submission record. See the header for why `promptSource` is the
# discriminator and why "a new user message" is not.
_JQ_SUBMISSION='
select(.type == "user")
| select((.isMeta // false) | not)
| select((.isSidechain // false) | not)
| select(
    if has("promptSource") then
        (.promptSource != "system" and .promptSource != "sdk")
    else
        ((.message.content | type) == "string")
    end
  )
| 1'

# Claude Code homes to search, most specific first. NEXUS_CC_HOME, when
# set, is the ONLY root consulted (hermetic-test seam).
_cc_homes() {
    if [[ -n "${NEXUS_CC_HOME:-}" ]]; then
        printf '%s\n' "$NEXUS_CC_HOME"
        return 0
    fi
    [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && printf '%s\n' "$CLAUDE_CONFIG_DIR"
    printf '%s\n' "$HOME/.claude"
}

# Session-id of the agent living in `window`, from the heartbeat its own
# hooks write. Falls back to the UserPromptSubmit stamp's session column.
_session_id_for_window() {
    local window="$1" hb="$STATE_DIR/heartbeat/$1.json" sid=""
    if [[ -f "$hb" ]] && command -v jq >/dev/null 2>&1; then
        sid=$(jq -r '.session_id // empty' "$hb" 2>/dev/null) || sid=""
    fi
    if [[ -z "$sid" && -f "$STATE_DIR/user-prompt/$window" ]]; then
        sid=$(head -1 "$STATE_DIR/user-prompt/$window" 2>/dev/null | cut -f2) || sid=""
    fi
    [[ -n "$sid" ]] || return 1
    printf '%s' "$sid"
}

# `<cc-home>/projects/*/<session-id>.jsonl`. Bounded glob, never a find,
# never a hand-derived slug — see the header.
_transcript_for_session() {
    local sid="$1" home p
    [[ -n "$sid" ]] || return 1
    while IFS= read -r home; do
        [[ -n "$home" ]] || continue
        for p in "$home"/projects/*/"$sid.jsonl"; do
            [[ -f "$p" ]] || continue     # no nullglob: an unmatched glob is the literal
            printf '%s' "$p"
            return 0
        done
    done < <(_cc_homes)
    return 1
}

_file_size() {
    local f="$1" n
    [[ -f "$f" ]] || { printf '0'; return 0; }
    n=$(stat -c %s "$f" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# Count TUI submissions among the bytes appended after byte offset `base`.
#
# Byte offset, not line offset, and the difference is not cosmetic: a
# live worker transcript reaches hundreds of MB (792 MB observed on this
# operator), so `tail -n +N` — which must scan from byte 0 to count
# lines — costs ~0.25 s per poll, ~17 s per paste. `tail -c +N` seeks
# straight to the offset: 0.007 s, and O(1) in file size.
#
# The price of a byte offset is that it may land mid-line if we stat
# while a line is being appended, and jq aborts the whole stream on one
# malformed value. `^\{.*\}$` is the cheap, total guard: a leading
# fragment is some line's TAIL (never starts with `{`), a trailing
# fragment is some line's HEAD (never ends with `}`), and JSONL forbids
# raw newlines inside strings, so no complete record is ever rejected.
_submissions_since() {
    local t="$1" base="$2" n
    [[ -f "$t" ]] || { printf '0'; return 0; }
    n=$(tail -c +"$(( base + 1 ))" "$t" 2>/dev/null \
        | grep -E '^\{.*\}$' 2>/dev/null \
        | jq -c "$_JQ_SUBMISSION" 2>/dev/null | wc -l) || n=0
    n="${n//[^0-9]/}"
    printf '%s' "${n:-0}"
}

# Evidence (b): the worker's own UserPromptSubmit stamp advanced past
# our paste, in the session we baselined against.
_hook_stamp_confirms() {
    local f="$STATE_DIR/user-prompt/$WINDOW" epoch sid
    [[ -f "$f" ]] || return 1
    IFS=$'\t' read -r epoch sid < <(head -1 "$f" 2>/dev/null) || return 1
    [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
    [[ "$sid" == "$SESSION_ID" ]] || return 1
    (( epoch > PASTE_EPOCH ))
}

# Evidence (a) then (b). The transcript scan is gated on the file
# actually having grown — an inert session (the #507 failure) costs one
# stat per poll and never spawns tail/grep/jq at all.
LAST_SIZE=0
_confirmed() {
    local cur subs
    cur=$(_file_size "$TRANSCRIPT")
    if (( cur != LAST_SIZE )); then
        LAST_SIZE=$cur
        subs=$(_submissions_since "$TRANSCRIPT" "$BASE_SIZE")
        (( subs > 0 )) && return 0
    fi
    _hook_stamp_confirms
}

# Poll for the post-condition for `$1` seconds. rc0 the moment it holds.
_poll_confirm() {
    local secs="$1" iters i
    iters=$(awk -v s="$secs" -v p="$POLL" 'BEGIN { n = s / p; printf "%d", (n < 1 ? 1 : n) }')
    for (( i = 0; i < iters; i++ )); do
        _confirmed && return 0
        sleep "$POLL"
    done
    _confirmed
}

# Resolve the confirmation surfaces BEFORE pasting, so the baseline
# cannot include our own submission. VERIFY=0 with a reason set means
# "we will not be able to establish anything" — exit 3, never a lie.
VERIFY=1
UNVERIFIABLE_REASON=""
SESSION_ID=""
TRANSCRIPT=""
BASE_SIZE=0
if (( SEND_ENTER )); then
    if ! command -v jq >/dev/null 2>&1; then
        VERIFY=0; UNVERIFIABLE_REASON="jq not on PATH — cannot read the session transcript"
    elif ! SESSION_ID=$(_session_id_for_window "$WINDOW"); then
        VERIFY=0; UNVERIFIABLE_REASON="no session-id for window $WINDOW (no heartbeat at $STATE_DIR/heartbeat/$WINDOW.json — hooks not installed?)"
    elif ! TRANSCRIPT=$(_transcript_for_session "$SESSION_ID"); then
        VERIFY=0; UNVERIFIABLE_REASON="no transcript for session $SESSION_ID under $(_cc_homes | tr '\n' ' ')"
    else
        BASE_SIZE=$(_file_size "$TRANSCRIPT")
        LAST_SIZE=$BASE_SIZE
    fi
fi

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
PASTE_EPOCH=$(date +%s)
printf '%s\t%s\t%s\n' "$WINDOW" "$PASTE_EPOCH" "$SRC_TOKEN" \
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

# 3. Submit, then establish that it submitted.
OUTCOME="pasted (NOT submitted, --no-enter)"
RC=0
RETRIED=0
if (( SEND_ENTER )); then
    sleep 0.2
    tmux send-keys -t "$WIN_ID" Enter \
        || die "tmux send-keys Enter failed for window $WINDOW (message pasted but NOT submitted)"

    if (( ! VERIFY )); then
        OUTCOME="pasted (submission unconfirmed: $UNVERIFIABLE_REASON)"
        RC=$RC_UNCONFIRMED
    else
        # Split the budget: watch, retry the Enter once, watch again.
        # The retry is not superstition — a paste Claude Code collapsed
        # into a `[Pasted text #N +N lines]` placeholder can need a
        # second Enter to submit, and that is exactly the intermittent
        # mechanism #507 describes.
        first=$(awk -v t="$CONFIRM_TIMEOUT" 'BEGIN { n = int(t * 0.4); printf "%d", (n < 1 ? 1 : n) }')
        second=$(( CONFIRM_TIMEOUT - first ))
        (( second >= 1 )) || second=1

        if _poll_confirm "$first"; then
            OUTCOME="submitted"
        else
            RETRIED=1
            printf 'paste-followup: no submission after %ss — retrying Enter once (collapsed-paste placeholder?)\n' \
                "$first" >&2
            tmux send-keys -t "$WIN_ID" Enter 2>/dev/null || true
            if _poll_confirm "$second"; then
                OUTCOME="submitted (after one Enter retry)"
            else
                # Distinguish an established negative from an
                # unestablishable one. Never conflate them.
                sid_now=""
                sid_now=$(_session_id_for_window "$WINDOW") || sid_now=""
                end_size=$(_file_size "$TRANSCRIPT")
                if [[ -n "$sid_now" && "$sid_now" != "$SESSION_ID" ]]; then
                    OUTCOME="pasted (submission unconfirmed: session-id changed under us — $SESSION_ID → $sid_now; window resumed mid-paste?)"
                    RC=$RC_UNCONFIRMED
                elif (( end_size > BASE_SIZE )); then
                    OUTCOME="pasted (submission unconfirmed: a turn is in flight — the transcript grew by $(( end_size - BASE_SIZE )) bytes with no submission record, so the text is plausibly QUEUED behind it; re-check)"
                    RC=$RC_UNCONFIRMED
                else
                    OUTCOME="pasted (NOT submitted)"
                    RC=$RC_NOT_SUBMITTED
                fi
            fi
        fi
    fi
fi

# 4. Audit-trail action-log event (best-effort; the TSV stamp above
#    is what the attribution rule keys on). The outcome rides along so
#    the audit trail records what we established, not what we hoped.
NG_BIN="${PASTE_NG_BIN:-$_script_dir/ng}"
log_args=(monitor --event paste-followup --extra "window=$WINDOW"
          --extra "outcome=$OUTCOME" --extra "rc=$RC")
[[ -n "$NOTE" ]]    && log_args+=(--note "$NOTE")
[[ -n "$ISSUE" ]]   && log_args+=(--extra "issue=$ISSUE")
[[ -n "$COMMENT" ]] && log_args+=(--extra "comment=$COMMENT")
(( SEND_ENTER ))    || log_args+=(--extra "no_enter=1")
(( RETRIED ))       && log_args+=(--extra "enter_retried=1")
if ! "$NG_BIN" log-action "${log_args[@]}" >/dev/null 2>&1; then
    printf 'paste-followup: warning: ng log-action append failed (machine-input stamp already recorded; paste landed)\n' >&2
fi

# 5. Report ONLY what was established. The banner is never the evidence.
if (( RC == 0 )); then
    printf 'paste-followup: %s to %s (%s chars)\n' "$OUTCOME" "$WINDOW" "${#MSG}"
else
    printf 'paste-followup: %s to %s (%s chars)\n' "$OUTCOME" "$WINDOW" "${#MSG}" >&2
    if (( RC == RC_NOT_SUBMITTED )); then
        printf 'paste-followup: the text is sitting in %s'"'"'s input box unsent. Re-paste, or press Enter in the pane.\n' \
            "$WINDOW" >&2
    fi
fi
exit "$RC"
