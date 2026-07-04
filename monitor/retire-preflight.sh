#!/usr/bin/env bash
# retire-preflight.sh — the SYNCHRONOUS go/no-go gate the orchestrator
# MUST run immediately before any `tmux kill-window` on a worker window.
#
# Why this script exists (the 2026-06-15 incident):
#   The orchestrator killed worker window `pr277-liveness-review` 9 s
#   after the operator typed a directive into it, destroying an
#   in-flight interaction. Forensic timeline:
#     13:29     — worker ran `ng wrap-up` → `window-retain` logged
#                 (wrapped, retire-eligible).
#     13:38:20  — the OPERATOR submitted a prompt into the window
#                 (UserPromptSubmit hook fired → user-prompt stamp
#                 written; jsonl recorded the turn).
#     13:38:29  — the orchestrator ran `tmux kill-window`, having
#                 decided to retire from the 13:37:47 poll snapshot
#                 (`wrapped + idle`). The 13:38:20 submit was not yet
#                 reflected — the watcher poll attributes engagement
#                 with up to ~60 s lag, and no poll ran in the 9 s gap.
#   The load-bearing gap: the retire path did a NO synchronous re-check
#   of fresh operator input before the irreversible kill. This script
#   is that re-check. It reads LIVE state (not the ~60 s-stale poll
#   snapshot), so a just-arrived operator prompt counts even though the
#   poll has not attributed it yet.
#
# Design contract:
#   - Cheap and SIDE-EFFECT-FREE: only reads (pane capture via
#     pane-state.sh + a handful of small state-file reads). Writes
#     nothing, mutates no state.
#   - CONSERVATIVE: any doubt → no-go. A deferred retire costs one wake
#     cycle and is fully recoverable; a wrong-go destroys live operator
#     context (the incident). When the safety check itself cannot run
#     (pane-state unreadable, helper library missing), that is doubt →
#     no-go.
#
# What it checks (any one → no-go):
#   1. LIVE pane-state (monitor/pane-state.sh, the authoritative
#      autosuggest-vs-real-input classifier — never a raw capture-pane
#      grep). `user-typing` means the operator is in the input box
#      right now; `busy` / `working-*` means work is in flight; the
#      retire decision was made against a stale "idle" snapshot.
#      `unknown` (probe could not run) is doubt → no-go.
#   2. FRESH operator submit, attributed SYNCHRONOUSLY off the raw
#      UserPromptSubmit stamp (`$STATE_DIR/user-prompt/<window>`) — the
#      deterministic contract event Claude Code writes the instant a
#      prompt is submitted, immune to the TUI redraw distortion that
#      corrupts capture-pane reads. The stamp is read DIRECTLY so a
#      submit counts even before the watcher poll has attributed it.
#      A submit is the OPERATOR'S (→ no-go) when its epoch is newer
#      than any known machine input (paste-followup / machine-input.tsv
#      / spawn) by more than the attribution slack, AND it landed within
#      the freshness window. This is the exact gap the incident exposed.
#   1b. A LIVE required-skeptic marker
#      (`$STATE_DIR/skeptic/pending/<window>`, skills/nexus.skeptic). When
#      a wrap-up requires an independent skeptic pass, it writes this
#      marker; it clears only when a skeptic returns a verdict (or an
#      operator waives). While present, the task is not done → no-go.
#      This is the enforcement that makes `require` a hard gate rather
#      than an advisory print.
#   3. A VALID operator-engaged mark (`_openg_marked`, the watcher's own
#      self-expiring validity predicate). Catches the case where the
#      poll DID already attribute the engagement.
#
# Inputs:
#   $1   <window-name>            — the tmux window the orchestrator is
#                                   about to kill (state files are keyed
#                                   on the name). Also accepts a window
#                                   <index> or <session>:<window> form,
#                                   in which case the name is resolved
#                                   from tmux.
#        --now <epoch>            — override the clock (tests).
#        --state-dir <path>       — override STATE_DIR (tests).
#        --fresh-seconds <n>      — override the operator-submit
#                                   freshness window (tests).
#        --pane-state <token>     — inject the pane-state verdict instead
#                                   of invoking pane-state.sh (tests).
#
# Output (single line, key=value, machine-parseable):
#   safe=<0|1> window=<name> pane=<state> reason=<free text…>
#   `safe=1` ⇒ go; `safe=0` ⇒ no-go. Grep `safe=0` to abort the kill.
#
# Exit codes (the orchestrator ABORTS the kill on any non-zero):
#   0  go      — no fresh operator signal; safe to proceed.
#   1  no-go   — fresh operator input / engagement detected; ABORT.
#   2  bad usage.
#   3  requested window does not exist in tmux (mirrors pane-state.sh
#      issue #140: a typo'd window must fail loud, not read as "gone").
#
# The orchestrator MUST treat exit 1, 2, AND 3 as "do not kill" — only
# a clean `safe=1` exit 0 authorizes the irreversible `tmux kill-window`.

set -u

usage() {
    cat <<'EOF' >&2
usage: retire-preflight.sh <window-name|index|session:window>
                           [--now <epoch>] [--state-dir <path>]
                           [--fresh-seconds <n>] [--pane-state <token>]
EOF
    exit 2
}

# ---- arg parsing ----------------------------------------------------------
target=
now_override=
state_dir_override=
fresh_override=
pane_state_override=
while (( $# > 0 )); do
    case "$1" in
        --now)           now_override="${2:-}";        shift 2 || usage ;;
        --state-dir)     state_dir_override="${2:-}";   shift 2 || usage ;;
        --fresh-seconds) fresh_override="${2:-}";       shift 2 || usage ;;
        --pane-state)    pane_state_override="${2:-}";  shift 2 || usage ;;
        -h|--help)       usage ;;
        --)              shift; target="${1:-}"; break ;;
        -*)              usage ;;
        *)               target="$1"; shift ;;
    esac
done
[[ -n "$target" ]] || usage

now="${now_override:-$(date +%s)}"
[[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || self_dir="."

# ---- resolve STATE_DIR (mirrors pane-state.sh / worker-heartbeat.sh) ------
if [[ -n "$state_dir_override" ]]; then
    STATE_DIR="$state_dir_override"
elif [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    STATE_DIR="$NEXUS_STATE_DIR"
elif [[ -n "${NEXUS_ROOT:-}" ]]; then
    STATE_DIR="$NEXUS_ROOT/monitor/.state"
else
    STATE_DIR="$self_dir/.state"
fi
export STATE_DIR

# ---- resolve the window NAME and a pane-state target ----------------------
# State files are keyed on the window NAME. pane-state.sh takes an
# index / session:window. Accept either form on input and resolve the
# missing half from tmux.
win_name=""
pane_target=""
have_tmux=0
command -v tmux >/dev/null 2>&1 && have_tmux=1

if [[ "$target" =~ ^[0-9]+$ ]] || [[ "$target" =~ ^[^:]+:[0-9]+$ ]]; then
    # Given an index/target — resolve the name for state-file lookups.
    pane_target="$target"
    if (( have_tmux )); then
        win_name=$(tmux display-message -p -t "$target" '#{window_name}' 2>/dev/null) || win_name=""
    fi
    [[ -n "$win_name" ]] || win_name="$target"
else
    # Given a name — resolve its tmux index for the pane probe.
    win_name="$target"
    if (( have_tmux )); then
        # Exact-match the window name → index. Last match wins (rare dup).
        pane_target=$(tmux list-windows -F '#{window_name}|#{window_index}' 2>/dev/null \
            | awk -F'|' -v w="$win_name" '$1 == w { idx = $2 } END { if (idx != "") print idx }')
        if [[ -z "$pane_target" ]]; then
            # Name not present in tmux. With --pane-state injected (tests,
            # or a caller that already has the verdict) we proceed; else
            # this is a vanished/typo'd window — fail loud (exit 3) so the
            # caller does not read silence as "safe to kill".
            if [[ -z "$pane_state_override" ]]; then
                printf 'retire-preflight.sh: no such tmux window: %s\n' "$win_name" >&2
                exit 3
            fi
        fi
    fi
fi

emit() {
    # emit <safe 0|1> <pane-state> <reason…>
    local safe="$1" pane="$2"; shift 2
    printf 'safe=%s window=%s pane=%s reason=%s\n' \
        "$safe" "$win_name" "$pane" "$*"
}

# ---- check 1: LIVE pane-state --------------------------------------------
# The authoritative classifier — distinguishes operator-typed bright text
# from Claude Code's dim autosuggest ghost text, which a raw capture-pane
# grep cannot. Active states veto the kill; `unknown` (probe failed) is
# doubt and also vetoes.
pane_state="${pane_state_override:-}"
if [[ -z "$pane_state" ]]; then
    pane_script=""
    if [[ -n "${NEXUS_ROOT:-}" && -x "$NEXUS_ROOT/monitor/pane-state.sh" ]]; then
        pane_script="$NEXUS_ROOT/monitor/pane-state.sh"
    elif [[ -x "$self_dir/pane-state.sh" ]]; then
        pane_script="$self_dir/pane-state.sh"
    fi
    if [[ -n "$pane_script" && -n "$pane_target" ]]; then
        pane_line=$("$pane_script" "$pane_target" 2>/dev/null) || pane_line=""
        pane_state=$(printf '%s' "$pane_line" | sed -n 's/.*state=\([a-z-]*\).*/\1/p')
    fi
    [[ -n "$pane_state" ]] || pane_state="unknown"
fi

case "$pane_state" in
    user-typing)
        emit 0 "$pane_state" "operator is typing in the input box right now"
        exit 1 ;;
    busy|working-background|working-self-paced)
        emit 0 "$pane_state" "agent work in flight (pane=$pane_state) — retire decision was made against a stale idle snapshot"
        exit 1 ;;
    blocked)
        emit 0 "$pane_state" "pane sitting on an overlay (blocked) — surface to operator, do not kill"
        exit 1 ;;
    unknown)
        emit 0 "$pane_state" "pane-state could not be read — cannot verify safety, refusing kill"
        exit 1 ;;
    *)
        : ;;   # idle / autosuggest-only / empty / absent / over-limit / idle-orphan-async → continue
esac

# ---- source the watcher read-helpers (for checks 1b + 2 + 3) --------------
# Reuse the watcher's OWN attribution + mark-validity primitives so the
# preflight attributes a submit identically to the poll (consistency is
# the point). The library is pure functions (no top-level code), so
# sourcing is side-effect-free. If it cannot be sourced, the core
# incident fix (check 2) still runs via the self-contained fallback
# below; only the richer mark-validity check (3) is skipped. Sourced
# BEFORE check 1b so that check can reuse the watcher's skeptic-fidelity
# helper (`_idle_skeptic_orphaned`) — the same definition the idle probe
# uses, so the preflight and the poll agree on what an orphaned marker is.
probe_lib=""
if [[ -n "${NEXUS_ROOT:-}" && -r "$NEXUS_ROOT/monitor/watcher/_idle_probe.sh" ]]; then
    probe_lib="$NEXUS_ROOT/monitor/watcher/_idle_probe.sh"
elif [[ -r "$self_dir/watcher/_idle_probe.sh" ]]; then
    probe_lib="$self_dir/watcher/_idle_probe.sh"
fi
have_probe=0
if [[ -n "$probe_lib" ]]; then
    # shellcheck disable=SC1090
    source "$probe_lib" 2>/dev/null && have_probe=1
fi

# ---- check 1b: unresolved required-skeptic marker -------------------------
# The skeptic protocol (skills/nexus.skeptic) writes a pending marker at
# $STATE_DIR/skeptic/pending/<window> when a wrap-up REQUIRES an
# independent skeptic validation pass. It is cleared ONLY when a skeptic
# returns a verdict (or an operator waives). While it persists, the task
# is by definition NOT done — retiring the window would strand the
# required validation. This is the gate that makes `require` real.
#
# Fidelity (emit/exemption fidelity): the marker is refreshed by the
# WORKER's own await loop, so its mere presence does NOT prove a skeptic is
# reviewing. A marker with a LIVE skeptic (or still within the spawn grace)
# is a genuine no-go — refuse the kill. But a marker gone ORPHANED (fresh,
# yet NO live skeptic past the grace window) is a stuck state, NOT live
# validation: blocking the kill on it strands the window forever (exactly
# the all-night-linger bug). So on an orphaned marker the preflight ALLOWS
# the kill with a loud note — the orchestrator saw the matching
# `orphaned-skeptic-pending` signal from the poll and is consciously
# retiring it. When the fidelity helper is unavailable (probe lib missing),
# fall back to the original unconditional no-go (conservative: refuse).
sk_pending="$STATE_DIR/skeptic/pending/${win_name//[^a-zA-Z0-9_-]/_}"
if [[ -f "$sk_pending" ]]; then
    _sk_now=$(date +%s)
    if (( have_probe )) && declare -F _idle_skeptic_orphaned >/dev/null 2>&1 \
       && _idle_skeptic_orphaned "$win_name" "$_sk_now"; then
        # Orphaned marker: NOT live validation. Note it (stderr, so the single
        # stdout verdict stays authoritative) and fall through — the marker no
        # longer blocks retirement. Checks 2/3 below still guard operator
        # engagement, so a genuinely-in-use window is still refused.
        printf 'retire-preflight: skeptic-pending marker for %q is ORPHANED (no live skeptic past grace) — not blocking retirement\n' \
            "$win_name" >&2
    else
        emit 0 "$pane_state" "required skeptic has not returned a verdict (skeptic-pending marker live) — task not done, refusing kill"
        exit 1
    fi
fi

# ---- check 2: FRESH, operator-attributed user-prompt submit ---------------
# THE incident fix. Read the raw UserPromptSubmit stamp directly so a
# just-submitted prompt counts even though the poll has not run. Attribute
# it exactly as the watcher does: a submit newer than every known machine
# input by more than the slack is the operator's.
#
# Freshness window: defaults to the operator-engaged change-TTL
# (monitor.operator_engaged_change_ttl_seconds, default 600) so the gate
# stays aligned with how long an engagement is otherwise held. A submit
# older than this — already answered and handled — does not pin the
# window open (the operator-engaged mark would likewise have self-expired).
fresh_seconds="${fresh_override:-${MONITOR_RETIRE_PREFLIGHT_FRESH_SECONDS:-}}"
if [[ ! "$fresh_seconds" =~ ^[0-9]+$ ]]; then
    fresh_seconds=""
    if (( have_probe )) && declare -F _openg_change_ttl_seconds >/dev/null 2>&1; then
        fresh_seconds=$(_openg_change_ttl_seconds 2>/dev/null)
    fi
    [[ "$fresh_seconds" =~ ^[0-9]+$ ]] || fresh_seconds=600
fi

# up_epoch: newest UserPromptSubmit stamp for the window (raw read).
up_epoch=0
if (( have_probe )) && declare -F _openg_user_prompt_epoch >/dev/null 2>&1; then
    up_epoch=$(_openg_user_prompt_epoch "$win_name" 2>/dev/null)
else
    up_stamp="$STATE_DIR/user-prompt/$win_name"
    if [[ -f "$up_stamp" ]]; then
        up_epoch=$(awk -F'\t' 'NR == 1 { print $1; exit }' "$up_stamp" 2>/dev/null)
    fi
fi
[[ "$up_epoch" =~ ^[0-9]+$ ]] || up_epoch=0

if (( up_epoch > 0 )); then
    # machine_epoch: newest known machine input (paste-followup / unstick
    # nudge / spawn). When the probe lib is present use its authoritative
    # multi-source resolver; otherwise fall back to machine-input.tsv only
    # (the dominant signal — paste-followup.sh stamps it BEFORE pasting).
    machine_epoch=0
    if (( have_probe )) && declare -F _openg_machine_input_epoch >/dev/null 2>&1; then
        machine_epoch=$(_openg_machine_input_epoch "$win_name" 2>/dev/null)
    else
        mi="$STATE_DIR/machine-input.tsv"
        if [[ -f "$mi" ]]; then
            machine_epoch=$(awk -F'\t' -v w="$win_name" \
                '$1 == w && $2 ~ /^[0-9]+$/ && ($2 + 0) > m { m = $2 + 0 } END { print m + 0 }' \
                "$mi" 2>/dev/null)
        fi
    fi
    [[ "$machine_epoch" =~ ^[0-9]+$ ]] || machine_epoch=0

    slack=120
    if (( have_probe )) && declare -F _openg_input_slack_seconds >/dev/null 2>&1; then
        slack=$(_openg_input_slack_seconds 2>/dev/null)
        [[ "$slack" =~ ^[0-9]+$ ]] || slack=120
    fi

    up_age=$(( now - up_epoch ))
    (( up_age < 0 )) && up_age=0
    # Operator-attributed iff newer than machine input by > slack.
    if (( up_epoch > machine_epoch + slack )) && (( up_age <= fresh_seconds )); then
        emit 0 "$pane_state" "fresh operator submit ${up_age}s ago not attributable to machine input (up=$up_epoch machine=$machine_epoch) — operator re-engaged since the retire decision"
        exit 1
    fi
fi

# ---- check 3: VALID operator-engaged mark ---------------------------------
# Belt-and-suspenders: the poll may already have attributed the
# engagement. `_openg_marked` is the watcher's self-expiring validity
# predicate (seeded, not invalidated by engaged-done/spawn, AND still
# corroborated by recent pane change). Skipped only if the lib is absent
# — check 2 above is the guaranteed synchronous backstop in that case.
if (( have_probe )) && declare -F _openg_marked >/dev/null 2>&1; then
    if _openg_marked "$win_name" 2>/dev/null; then
        src=""
        if declare -F _openg_lookup >/dev/null 2>&1; then
            src=$(_openg_lookup "$win_name" 2>/dev/null | cut -f4)
        fi
        emit 0 "$pane_state" "valid operator-engaged mark (src=${src:-engaged}) — window belongs to the operator"
        exit 1
    fi
fi

# ---- go -------------------------------------------------------------------
emit 1 "$pane_state" "no fresh operator input or engagement — safe to retire"
exit 0
