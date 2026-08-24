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
#     AND `_` to `-` (`/shared/your-lab-m/…` → `-shared-your-lab-m-…`),
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
#   --note <action-log-text>
#                      action-log note (what/why of the follow-up).
#                      NOT PAYLOAD — it is never pasted into the window.
#                      The placeholder used to read `<text>`, which beside
#                      `--message <text>` reads as an addendum to the
#                      message; four per-worker addenda were sent this way
#                      and none reached a worker (your-org/nexus-code#848).
#                      The receipt now names the destination explicitly, so
#                      the misreading is self-correcting at the call site.
#   --issue <n>        action-log issue cross-ref
#   --comment <id>     action-log trigger-comment cross-ref
#   --src <label>      injector-identity hint stamped as the ledger's
#                      src column (default `paste-followup`). Lets each
#                      injector class record a distinct, greppable
#                      identity (e.g. `skeptic-nudge`).
#                      NOT purely additive — this said so until
#                      your-org/nexus-code#679, repeating a claim `#690`
#                      had already had to correct in _lib.sh and which
#                      survived here verbatim. The src column is a
#                      SELECTOR: `_idle_unconfirmed_paste_epoch` matches
#                      `$3 == "paste-followup"` EXACTLY
#                      (monitor/watcher/_idle_probe.sh), so relabelling a
#                      paste exempts it from the `paste-unconfirmed`
#                      detector entirely. skeptic-channel.sh:1086-1088
#                      declines to override the src for exactly this
#                      reason. Changing a src token is a behavioural
#                      change, not a logging change.
#   --administrative   (alias --no-retask) this follow-up does NOT
#                      re-task the worker, so it must not consume the
#                      window's standing `window-retain` nor supersede
#                      an older wrap-up (your-org/nexus-code#683). Use
#                      for `worker-health` clarifications and for
#                      release-from-deadlock pastes — anything that asks
#                      for no new work. The DEFAULT is re-task, so real
#                      re-tasks are unaffected. Recorded in column 4 of
#                      machine-input.tsv and in the action-log event, so
#                      the decision is auditable rather than inferred;
#                      it is deliberately NOT guessed from --note prose.
#                      Orthogonal to delivery: an administrative paste is
#                      still checked by `paste-unconfirmed`, because a
#                      lost administrative paste is exactly as lost.
#   --no-enter         paste without submitting (rare; queue text only).
#                      Skips confirmation — nothing was meant to submit.
#   --help, -h         print this reference plus the derived synopsis.
#                      Accepted as the FIRST argument too — it used to be
#                      reachable only as `<window> --help`, because the
#                      arm that handles it lives inside the argument loop
#                      and the loop is only reached once a window has been
#                      accepted (your-org/nexus-code#883, same surface).
#   --confirm-timeout <sec>
#                      total budget for the submission post-condition.
#                      Env: PASTE_CONFIRM_TIMEOUT_SECONDS; config:
#                      monitor.paste_confirm_timeout_seconds; default 20.
#
# THE RECEIPT DESCRIBES WHAT THE RECEIPT COVERS (your-org/nexus-code#848).
# The success line carries a character count, which is the most
# authoritative-looking thing a paste tool can print — and it counts the
# PASTED payload only. A `--note` is an action-log annotation and never
# reaches the window, so four calls carrying four different notes used to
# print four IDENTICAL success lines, each consistent with the notes having
# arrived. When `--note` is given, the receipt now names its destination and
# its size, and says NOT pasted in as many words; if the action-log append
# failed, it says that instead. Same rule as the confirmation above: report
# only what was established, and describe the boundary of the claim.
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
# THE CONTENT MARKER (your-org/nexus-code#665 item 1). Beside the verdict
# we record `digest=` — sha256 over the canonical bytes of this message —
# in the same epoch-keyed sidecar, and we write it BEFORE pasting. The
# watcher then resolves "was THIS paste consumed" by matching that digest
# in the target's transcript, instead of asking the temporal proxy "did
# SOME submission follow this epoch". The two differ exactly when a lost
# paste is followed by unrelated traffic, which is the case that used to
# be silenced. Canonical = the measured channel transform, a literal TAB
# arriving as four spaces; see monitor/_submit_evidence.sh.
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

# Every LINE carries the prefix. The unknown-option arm now appends the
# derived synopsis, and a multi-line diagnostic that prefixes only its
# first line leaves bare, tool-less lines behind — the same shape
# your-org/nexus-code#858 C describes for `ng`, where a `| tail -1`
# capture then reads as a plausible value.
die() { printf '%s\n' "$*" | sed 's/^/paste-followup: /' >&2; exit 1; }

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

# ---- the synopsis is DERIVED from the parser (your-org/nexus-code#883) ----
#
# The usage line is the ONLY surface a caller reads: an agent that wants to
# know how to invoke a script runs it with no arguments. Until now that line
# was a hand-maintained literal sitting beside a hand-maintained parser, and
# it had already drifted — `--administrative` and `--src` were both parsed
# and both documented in the header block above, and NEITHER appeared in it.
# `--administrative` is the entire remedy for `#683`, so following this
# tool's own usage reproduced a closed bug, and did so more reliably the
# more carefully the caller consulted the interface.
#
# So there is now ONE declaration of the accepted flags: the `case` arms
# between the ARG-LOOP sentinels below. Names and aliases come from the arm
# patterns; arity comes from the arm's own `shift 2`; the value placeholder
# rides on the arm as a trailing `#= <placeholder>` comment. A flag cannot
# be added to the parser without appearing in the synopsis, which is the
# property `#883` asks for — not "the current list is now correct", which
# is true of every list on the day it is written.
#
# This is a DERIVATION, not a second parser. It reads the arm patterns; it
# never interprets an argument. And it FAILS LOUD when it cannot find them:
# a synopsis that silently omits flags IS the defect, so a degraded one
# would be the defect wearing the fix's clothes.
#
# The sed ranges are written `ARG-LOOP[-]BEGIN` so this function's own
# source lines cannot match the sentinels it is looking for.
_usage_synopsis() {
    local line pat ph n=0 out=""
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(-[a-zA-Z0-9|_-]*[a-zA-Z0-9])\) ]] || continue
        pat="${BASH_REMATCH[1]}"
        if [[ "$line" == *"shift 2"* ]]; then
            ph="<arg>"
            [[ "$line" =~ '#='[[:space:]]*(\<[^\>]*\>) ]] && ph="${BASH_REMATCH[1]}"
            out+=" [$pat $ph]"
        else
            out+=" [$pat]"
        fi
        n=$(( n + 1 ))
    done < <(sed -n '/ARG-LOOP[-]BEGIN/,/ARG-LOOP[-]END/p' "${BASH_SOURCE[0]}" 2>/dev/null)
    if (( n == 0 )); then
        printf 'paste-followup: INTERNAL: could not derive the flag synopsis from %s — refusing to print a usage line that would silently omit flags (your-org/nexus-code#883)\n' \
            "${BASH_SOURCE[0]}" >&2
        return 1
    fi
    printf 'usage: paste-followup.sh <window>%s\n' "$out"
    printf '       message from --file, --message, or stdin. Run --help for the full reference.\n'
}

# The full reference: this file's own header block, which is where each
# flag's rationale lives. One function, two call sites (the pre-dispatch
# just below and the `--help` arm inside the loop), so the two forms can
# never print different things.
_print_help() {
    awk 'NR > 1 { if ($0 == "") exit; print }' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    _usage_synopsis
}

# `--help` BEFORE the window check. The `--help` arm lives inside the
# argument loop, and the loop is only reached once a window has been
# accepted — so `paste-followup.sh --help`, the form every caller types
# first, fell through the `"$WINDOW" != --*` guard to the usage line and
# exit 1, and the full reference was reachable only as
# `paste-followup.sh <some-window> --help`. Same defect as #883 one
# surface over: the documentation existed and the obvious invocation did
# not reach it. The usage line now says "run --help", so leaving this
# would have made that instruction a circle.
case "${1:-}" in
    --help|-h) _print_help; exit 0 ;;
esac

WINDOW="${1:-}"
[[ -n "$WINDOW" && "$WINDOW" != --* ]] || { _usage_synopsis >&2; exit 1; }
shift

MSG_FILE=""
MSG_TEXT=""
NOTE=""
ISSUE=""
COMMENT=""
SRC=""
SEND_ENTER=1
ADMINISTRATIVE=0
CONFIRM_TIMEOUT=""
# ARG-LOOP-BEGIN — the single declaration of this script's flags. Every arm
# is read by _usage_synopsis above; `#= <placeholder>` names the value.
while (( $# > 0 )); do
    case "$1" in
        --file)     MSG_FILE="${2:-}"; shift 2 || die "--file needs a path" ;; #= <path>
        --message)  MSG_TEXT="${2:-}"; shift 2 || die "--message needs text" ;; #= <text>
        --administrative|--no-retask) ADMINISTRATIVE=1; shift ;;
        --note)     NOTE="${2:-}";     shift 2 || die "--note needs text" ;; #= <action-log-text>
        --issue)    ISSUE="${2:-}";    shift 2 || die "--issue needs a number" ;; #= <n>
        --comment)  COMMENT="${2:-}";  shift 2 || die "--comment needs an id" ;; #= <id>
        --src)      SRC="${2:-}";      shift 2 || die "--src needs a label" ;; #= <label>
        --confirm-timeout) CONFIRM_TIMEOUT="${2:-}"; shift 2 || die "--confirm-timeout needs seconds" ;; #= <sec>
        --no-enter) SEND_ENTER=0;      shift ;;
        --help|-h)  _print_help; exit 0 ;;
        *) die "unknown option: $1"$'\n'"$(_usage_synopsis 2>&1)" ;;
    esac
done
# ARG-LOOP-END

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
if ! grep -qxF -- "$WINDOW" <<<"$(tmux list-windows -F '#{window_name}' 2>/dev/null)"; then
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
# Dead-pane paste guard (#745). This helper is THE canonical follow-up
# paste into a worker window, and every worker window carries
# `remain-on-exit` — so this is the site the hazard is reached through
# most often. Fail LOUD if the guard cannot be loaded.
# shellcheck source=_pane-live.sh
# shellcheck disable=SC1091
[[ -r "$_script_dir/_pane-live.sh" ]] && . "$_script_dir/_pane-live.sh"
if ! declare -F _tmux_pane_is_dead >/dev/null 2>&1; then
    # FAIL-CLOSED FALLBACK (#745). Without the real predicate we cannot
    # tell a live pane from a corpse, and a paste into a corpse kills the
    # tmux SERVER — so every paste refuses, loudly, at the moment it is
    # attempted.
    #
    # Deliberately NOT an `exit`/`return` at load time. The first cut
    # refused to LOAD, and CI showed why that is wrong: several fixtures
    # build partial trees from ENUMERATED copy lists, so the file is
    # simply absent there, and four unrelated suites died on modules
    # they never paste from. A missing paste guard must stop PASTES, not
    # module loading. Quiet at load, loud at use: the noise belongs where
    # the hazard is.
    _tmux_pane_is_dead() {
        printf '%s: _pane-live.sh unavailable — cannot prove %q is a live pane, refusing to paste (your-org/nexus-code#745: a paste into a dead pane kills the tmux server)\n' \
            "${BASH_SOURCE[1]##*/}" "${1:-?}" >&2
        return 0
    }
fi
# Three-state (your-org/nexus-code#699). Every non-zero refuses here — this
# site was already fail-closed and stays that way — but the DIAGNOSTIC has to
# distinguish them, because "the window closed under you" and "tmux would not
# answer" send the operator to completely different places. The old single
# message guessed "race with a close?" for all of them.
_wid_rc=0
WIN_ID=$(resolve_window_id "$WINDOW") || _wid_rc=$?
if (( _wid_rc == 1 )); then
    die "tmux has no window named: $WINDOW — it closed between the check above and now (race with a close; spawn-worker.sh --resume to recreate)"
elif (( _wid_rc != 0 )); then
    die "could NOT determine whether window '$WINDOW' exists (resolver rc $_wid_rc; see the diagnostic above) — refusing to paste. This is not 'the window is gone'; tmux itself would not answer."
fi

STATE_DIR="$(_resolve_state_dir)"
mkdir -p "$STATE_DIR" || die "cannot create state dir: $STATE_DIR"

# ---- the CONTENT MARKER (your-org/nexus-code#665, item 1) --------------
#
# The watcher's `paste-unconfirmed` detector used to resolve consumption
# by TIMESTAMP ORDERING — "was there a submission after this paste's
# epoch". That is a proxy for the question it is actually asking, and the
# two come apart in the direction that costs the most: a paste genuinely
# lost, in a window where the worker submitted anything else afterwards,
# reads `yes` and is silenced forever. #665 asks for a marker recorded
# alongside the paste record so the answer keys on CONTENT instead.
#
# We are the only party that knows the bytes, so we are the party that
# has to record their digest. Computed and written BEFORE the paste, and
# deliberately not folded into step 3b: the sidecar's rc is a verdict
# about an OUTCOME and cannot exist yet, whereas the digest is a fact
# about the message that is already true. A sender killed mid-poll then
# still leaves the watcher a usable marker — which is exactly the
# situation in which the watcher is the only party still looking.
#
# Shared with the watcher through monitor/_submit_evidence.sh so the two
# cannot drift about what the canonical bytes are. Absent hasher → empty
# digest → no `digest=` line → the watcher falls back to its pre-#665
# temporal surface. Degrade, never lie.
# shellcheck source=monitor/_submit_evidence.sh
if [[ -r "$_script_dir/_submit_evidence.sh" ]]; then
    . "$_script_dir/_submit_evidence.sh"
fi
PASTE_DIGEST=""
if declare -F se_paste_digest >/dev/null 2>&1; then
    PASTE_DIGEST=$(se_paste_digest "$MSG" 2>/dev/null) || PASTE_DIGEST=""
fi
[[ "$PASTE_DIGEST" =~ ^[0-9a-f]{64}$ ]] || PASTE_DIGEST=""

# Single writer for the sidecar, used both pre-paste (marker only) and
# post-paste (marker + verdict). One function so a later edit to the
# verdict write cannot silently drop the digest — the failure mode would
# be invisible, because a missing marker degrades quietly to the old
# behaviour rather than erroring.
#
# `rc` is written FIRST when present: _idle_paste_verdict reads it with
# `awk -F= '$1=="rc"{print;exit}'`, and a sidecar with no rc line is
# `unknown` by design, which is what the pre-paste write must look like.
_write_paste_sidecar() {
    local rc_val="${1:-}" dir tmp
    dir="$STATE_DIR/paste-verdicts"
    mkdir -p "$dir" 2>/dev/null || return 0
    tmp="$dir/.$WINDOW.$PASTE_EPOCH_KEY.$$"
    {
        [[ -n "$rc_val" ]] && printf 'rc=%s\n' "$rc_val"
        printf 'window=%s\nepoch=%s\n' "$WINDOW" "$PASTE_EPOCH_KEY"
        [[ -n "$PASTE_DIGEST" ]] && printf 'digest=%s\n' "$PASTE_DIGEST"
        # `${OUTCOME:-}`: the pre-paste call runs before OUTCOME exists.
        # The `&&` short-circuit already prevents the expansion under
        # `set -u`, but that safety is a property of the CALL ORDER, and
        # a later reordering would turn it into an unbound-variable exit
        # in the middle of a paste.
        [[ -n "$rc_val" ]] && printf 'outcome=%s\n' "${OUTCOME:-}"
        :
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
    # Atomic publish — the watcher may read concurrently.
    mv -f "$tmp" "$dir/$WINDOW.$PASTE_EPOCH_KEY" 2>/dev/null \
        || rm -f "$tmp" 2>/dev/null
    return 0
}

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
# ---- your-org/nexus-code#679: the recorded key is MICROSECONDS -------
#
# This value is consumed at TWO granularities and the distinction is
# load-bearing:
#
#   KEY  — the TSV column and the `#676` verdict sidecar name. Must be
#          unique per paste, because two pastes into one window sharing
#          a key means last-writer-wins on the sidecar, and an `rc=4`
#          (established non-delivery) overwritten by a later `rc=0`
#          SILENCES a genuinely lost paste. That is `#679`.
#   TIME  — every comparison against another clock reading: the hook
#          stamp in `user-prompt/<window>`, the transcript's submission
#          records, the window's spawn timestamp, the emit's "paste NNNs
#          ago". All of those are SECONDS and none of them changes here.
#
# So the key gains resolution and `PASTE_EPOCH` stays seconds, derived
# from the very same reading — one clock sample, two views, so they can
# never disagree about which paste they describe.
#
# MICROSECONDS, not the nanoseconds `#679` proposes. The detector selects
# the newest row with awk (`($2 + 0) > m`, then prints it) and awk carries
# integers in a double: exact only below 2^53 ≈ 9.007e15. A nanosecond
# epoch is ~1.79e18, so it does NOT round-trip — measured on this host,
# `1754270400123456790` prints back as `1754270400123456768`, and two
# distinct nanosecond keys become indistinguishable. That printed value
# is what builds the sidecar path, so nanoseconds would make `#676`'s
# verdict lookup miss a file that is sitting right there — trading a
# collision for a silent total miss. A microsecond epoch is ~1.79e15,
# exact in a double until the year 2255, and still bounds the collision
# window at 1e-6 s against a sender that blocks ~20 s per paste.
#
# `%6N` is GNU-specific. If it is unavailable the expansion is not all
# digits, so fall back to seconds SCALED to microseconds: the unit stays
# consistent everywhere and only the collision-resolution improvement is
# lost, which is exactly the pre-#679 behaviour rather than a new failure.
PASTE_EPOCH_KEY=$(date +%s%6N 2>/dev/null)
[[ "$PASTE_EPOCH_KEY" =~ ^[0-9]{16,}$ ]] || PASTE_EPOCH_KEY=$(( $(date +%s) * 1000000 ))
PASTE_EPOCH=$(( PASTE_EPOCH_KEY / 1000000 ))
# ---- your-org/nexus-code#683: the ADMINISTRATIVE marker, column 4 ----
#
# A machine-attributed submit REGRESSES the window to busy: it consumes
# the standing `window-retain` and writes a `machine-submit` stamp that
# makes any OLDER wrap-up read as superseded. That premise is right for
# a RE-TASK and wrong for everything else, and the two follow-ups this
# workspace prescribes most often are neither: the `worker-health.sh`
# clarification the emit itself instructs you to paste, and a release
# paste telling a worker to stop awaiting something that will never
# arrive. The window then reports `idle NNNs WITHOUT wrap-up` forever
# and drops out of the retained-windows footer.
#
# The un-retain is cured by any LATER wrap-up, which makes this look
# minor. It is not — it is SELECTIVE. It is permanent exactly when no
# further wrap-up will occur, and the administrative pastes that trigger
# it are disproportionately the ones that guarantee that (one of them
# said, verbatim, "do NOT re-run `ng wrap-up`"). So "just wrap up again"
# is unavailable in precisely the case that matters and must not become
# the remedy.
#
# An EXPLICIT flag, never an inference from the `--note` prose. A
# heuristic on text is the "sixth proxy" `#635` rejected, and this file's
# own header now records what happens when a marker's meaning is guessed
# at rather than declared.
#
# COLUMN 4, not a new src token. The src column is a SELECTOR:
# `_idle_unconfirmed_paste_epoch` matches `$3 == "paste-followup"`
# EXACTLY, so relabelling an administrative paste would exempt it from
# the `paste-unconfirmed` detector — and an administrative paste that
# silently fails to arrive is exactly as lost as a re-task that does.
# The delivery check and the re-task claim are different questions and
# must not share a carrier. A 3-column row reads `$4 == ""` → not
# administrative, so every pre-#683 row and every other writer keeps
# working untouched.
_ADMIN_COL=""
(( ADMINISTRATIVE )) && _ADMIN_COL="admin"
printf '%s\t%s\t%s\t%s\n' "$WINDOW" "$PASTE_EPOCH_KEY" "$SRC_TOKEN" "$_ADMIN_COL" \
    >> "$STATE_DIR/machine-input.tsv" \
    || die "cannot stamp $STATE_DIR/machine-input.tsv — refusing to paste unstamped (the watcher would misattribute the input to the operator)"

# 1b. The content marker, keyed by the SAME epoch as the stamp above and
#     written BEFORE a single byte goes out (your-org/nexus-code#665).
#     Best-effort like every other sidecar write: the authoritative TSV
#     stamp has already landed and a missing marker costs only precision.
if (( SEND_ENTER )); then
    _write_paste_sidecar ""
fi

# 2. VI-safe paste. `i BSpace` forces insert mode regardless of the
#    pane's current VI mode (the lone `i` would self-insert when
#    already in insert mode; BSpace erases it — and in normal mode
#    `i` switches and BSpace is a harmless cursor-left).
#
#    `-p` (bracketed paste) is LOAD-BEARING for multi-line messages
#    (your-org/nexus-code#521). Without it, tmux replaces every embedded
#    linefeed with its separator (carriage return by default), so each
#    newline reaches the REPL as an Enter keystroke: on an idle pane the
#    first line is submitted alone as its own turn and the rest is stranded
#    in the input box; on a busy pane the words glue across the break. `-p`
#    wraps the buffer in bracketed-paste control codes IFF the receiving
#    application has requested bracketed-paste mode (per tmux(1)) — the
#    Claude REPL does, so the whole message arrives as one literal paste
#    and the newlines are text, not submits. The explicit Enter in step 3
#    remains the sole submit. Verified on the deployed tmux 2.6:
#    `paste-buffer -p` emits `ESC[200~ … ESC[201~` around the buffer once
#    the pane has requested mode ?2004 (see test-paste-bracketed.sh).
#    Safe-by-construction: on an application that did NOT request the mode,
#    tmux inserts no codes and `-p` is identical to the prior behaviour —
#    it can only fix, never regress.
# #745. THE highest-frequency instance of the hazard. This helper is
# the canonical way an orchestrator sends a follow-up (and the skeptic
# nudge) into a WORKER window, and `spawn-worker.sh` sets
# `remain-on-exit` on every worker it creates — so a follow-up pasted
# into a worker whose agent has already exited is an ordinary Tuesday,
# and it kills the tmux server: 20/20 measured on this exact `-p -d`
# call form. Refuse before the send-keys, not just before the paste.
if _tmux_pane_is_dead "$WIN_ID"; then
    die "window $WINDOW is a DEAD pane (its agent has exited; remain-on-exit left the window listed). Refusing to paste — a paste into a dead pane kills the tmux SERVER, taking the watcher and every other window with it (your-org/nexus-code#745). Respawn the window, or use \`tmux send-keys\` if you only need to poke a corpse."
fi

BUF="nexus-followup-$$-${RANDOM}"
tmux send-keys -t "$WIN_ID" i BSpace 2>/dev/null \
    || die "tmux send-keys (insert-mode guard) failed for window $WINDOW"
sleep 0.1
tmux set-buffer -b "$BUF" -- "$MSG" \
    || die "tmux set-buffer failed"
if ! tmux paste-buffer -p -d -b "$BUF" -t "$WIN_ID"; then
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

# 3b. Persist the verdict where the WATCHER can find it
#     (your-org/nexus-code#665).
#
#     Until now this verdict died with the process. The watcher's
#     `paste-unconfirmed` detector then re-derived consumption from
#     scratch — and with STRICTLY LESS information than we had here,
#     because we polled the transcript at paste time while it re-reads
#     it minutes later through a session-id that may since have
#     rotated. On 2026-08-02 that asymmetry produced 11 false positives
#     and 0 true positives: 16 of the day's 20 pastes recorded
#     `submitted` (rc 0 — an ESTABLISHED transcript submission), 4
#     recorded `plausibly QUEUED` (rc 3), and NOT ONE recorded the
#     established negative (rc 4) that the detector exists to catch.
#     The detector nonetheless told the operator "no submission found
#     in the transcript" about pastes we had watched submit.
#
#     Keyed by the SAME epoch we stamped into machine-input.tsv above,
#     so the sender and the watcher cannot disagree about which paste a
#     verdict belongs to — the watcher takes the max epoch per window
#     from that ledger and looks the sidecar up by it directly. No time
#     window, no fuzzy matching.
#
#     A SIDECAR, not a fourth TSV column: `machine-input.tsv` is
#     tab-delimited and consumed positionally, and the watcher's
#     >200-line compaction keeps one max-epoch row per window, which
#     would silently drop a verdict row on a busy board.
#
#     Best-effort, exactly like the action-log append below: the
#     authoritative TSV stamp has already landed and the paste really
#     did go out, so a failure here must not flip the exit code. A
#     missing sidecar degrades the watcher to its current behaviour
#     (`unknown`), never to a false negative.
#
#     Skipped for --no-enter: such a paste makes no submission claim,
#     and the detector already exempts it by src token.
#     Keyed by PASTE_EPOCH_KEY — the SAME value stamped into the TSV
#     above, which is what the watcher rediscovers and hands to
#     _idle_paste_verdict_path. That identity is what `#676` rests on;
#     deriving the name from the seconds view instead would reintroduce
#     the very collision `#679` is about.
#
#     This REWRITES the marker sidecar step 1b published, through the same
#     single writer, so the digest is carried forward rather than
#     clobbered by the verdict.
if (( SEND_ENTER )); then
    _write_paste_sidecar "$RC"
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
# your-org/nexus-code#683 asks for the decision to be auditable rather
# than inferred. The ledger's column 4 is what the classifier reads; this
# is the human-readable trail beside it, so "was this paste administrative"
# is answerable from the action log without parsing the TSV.
(( ADMINISTRATIVE )) && log_args+=(--extra "administrative=1")
(( RETRIED ))       && log_args+=(--extra "enter_retried=1")
LOG_OK=1
if ! "$NG_BIN" log-action "${log_args[@]}" >/dev/null 2>&1; then
    LOG_OK=0
    printf 'paste-followup: warning: ng log-action append failed (machine-input stamp already recorded; paste landed)\n' >&2
fi

# ---- your-org/nexus-code#848: the receipt states what it covers ----------
#
# The char count below is the PASTED payload and nothing else. `--note` is
# an action-log annotation, so a note never reaches the window — and the
# receipt used to be silent about that, which made four calls carrying four
# different notes print four byte-identical success lines. The count is the
# most authoritative-looking thing here, so its silence read as coverage.
#
# One clause fixes it at the call site: name the note's destination, its
# size, and the fact that it was NOT pasted — and when the action-log append
# failed, say THAT instead, because "recorded to the action log" would then
# be the same lie one level down.
NOTE_CLAUSE=""
if [[ -n "$NOTE" ]]; then
    if (( LOG_OK )); then
        NOTE_CLAUSE="; --note recorded to the action log (${#NOTE} chars, NOT pasted)"
    else
        NOTE_CLAUSE="; --note NOT recorded — the action-log append failed (${#NOTE} chars, and NOT pasted)"
    fi
fi

# 5. Report ONLY what was established. The banner is never the evidence.
if (( RC == 0 )); then
    printf 'paste-followup: %s to %s (%s chars pasted)%s\n' "$OUTCOME" "$WINDOW" "${#MSG}" "$NOTE_CLAUSE"
else
    printf 'paste-followup: %s to %s (%s chars pasted)%s\n' "$OUTCOME" "$WINDOW" "${#MSG}" "$NOTE_CLAUSE" >&2
    if (( RC == RC_NOT_SUBMITTED )); then
        printf 'paste-followup: the text is sitting in %s'"'"'s input box unsent. Re-paste, or press Enter in the pane.\n' \
            "$WINDOW" >&2
    fi
fi
exit "$RC"
