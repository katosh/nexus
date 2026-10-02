#!/usr/bin/env bash
# monitor/context-usage.sh
#
# Report the CURRENT context size of a Claude Code session, in tokens.
#
# WHY THIS EXISTS (jacob-greene/nexus#1 / #2 — token-cost audit 2026-07-31). Every
# assistant message re-reads the whole conversation, so the price of an
# identical action grows monotonically with session age. An orchestrator
# that drifts from 100k to 998k context pays ~10x for the same wake. The
# fix is to rotate the session (report + respawn) at a threshold instead
# of running to the 1M ceiling — and rotation needs a number to act on.
# This script is that number.
#
# The number itself is the same one Claude Code's status bar shows: the
# prompt size of the most recent assistant message,
#
#     input_tokens + cache_creation_input_tokens + cache_read_input_tokens
#
# read from the session's transcript jsonl (`message.usage`). It is a
# floor, not a ceiling: it does not include the tool results produced
# after that message. That is deliberate — a floor never triggers a
# rotation the operator would call premature.
#
# USAGE
#   monitor/context-usage.sh [selector] [options]
#
#   Selectors (first match wins; without one, the CALLER's own session):
#     --transcript <path>   explicit transcript jsonl
#     --session <uuid>      session id; searched under the projects root
#     --window <name>       tmux window name; resolved via
#                           monitor/.state/windows/<name>.json (workers)
#                           or monitor/.state/orchestrator-session-id
#                           (the configured orchestrator target window)
#
#   Options:
#     --threshold <tokens>  override the configured rotation threshold
#     --limit <tokens>      override the configured context ceiling
#     --format kv|json      output shape (default kv)
#     --quiet               print nothing; use the exit code only
#     -h | --help
#
# OUTPUT (kv, one line)
#   tokens=248113 limit=1000000 pct=24 threshold=250000 over=0 \
#     session=<uuid> window=<name> transcript=<path>
#
# EXIT CODES — the branch surface. Callers switch on these rather than
# parsing, so a malformed read can never be mistaken for "under budget":
#   0   read OK, context BELOW threshold
#   10  read OK, context AT OR ABOVE threshold  → rotate
#   1   could not resolve a transcript / no usable usage record
#   2   usage error (bad flag)
#
# HOT-PATH DISCIPLINE. The watcher calls this every compose cycle, so
# the read is bounded: a `tail -n $SCAN_LINES` window (default 400 lines,
# ~1 assistant message per 2-4 lines even in a tool-heavy turn) is tried
# first and only a miss falls back to a full scan. One jq invocation per
# attempt.
#
# SIDECHAIN ENTRIES ARE EXCLUDED. Subagent (`Agent` tool) turns are
# written into the SAME transcript with `isSidechain: true` and their own
# — much smaller — usage. Counting them would report a subagent's fresh
# 20k context as the main thread's, silently defeating rotation exactly
# when a long session is spawning helpers. Filtered out explicitly.
#
# COMPACTION IS RESPECTED. `/compact` shrinks the real context; the next
# assistant message's usage reflects the shrunk prompt. Reading the LAST
# message (not the max over the file) is what makes that true.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_script_dir/.." && pwd)}"
_cfg="$NEXUS_ROOT/config/load.sh"

SCAN_LINES="${NEXUS_CONTEXT_SCAN_LINES:-400}"
[[ "$SCAN_LINES" =~ ^[0-9]+$ ]] || SCAN_LINES=400

usage() {
    sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "context-usage: $*" >&2; exit 2; }

transcript=""
session=""
window=""
threshold=""
limit=""
format="kv"
quiet=0

_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

_argloop_prev_1=-1; while [[ $# -gt 0 ]]; do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --transcript) [[ -n "${2:-}" ]] || die "--transcript needs a value"; transcript="$2"; shift 2 ;;
        --session)    [[ -n "${2:-}" ]] || die "--session needs a value";    session="$2";    shift 2 ;;
        --window)     [[ -n "${2:-}" ]] || die "--window needs a value";     window="$2";     shift 2 ;;
        --threshold)  [[ -n "${2:-}" ]] || die "--threshold needs a value";  threshold="$2";  shift 2 ;;
        --limit)      [[ -n "${2:-}" ]] || die "--limit needs a value";      limit="$2";      shift 2 ;;
        --format)     [[ -n "${2:-}" ]] || die "--format needs a value";     format="$2";     shift 2 ;;
        --quiet)      quiet=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
done

case "$format" in kv|json) ;; *) die "--format must be kv or json" ;; esac

# ---- config -------------------------------------------------------------
# Env override → config → default, the standard nexus resolution order.
# A missing/uninstalled config/load.sh degrades to the defaults rather
# than failing: this script must stay usable in a bare clone and in the
# unit tests.
_cfg_get() {
    local key="$1" default="$2" val=""
    if [[ -x "$_cfg" ]]; then
        val=$("$_cfg" "$key" "$default" 2>/dev/null) || val=""
    fi
    [[ -n "$val" ]] || val="$default"
    printf '%s' "$val"
}

if [[ -z "$limit" ]]; then
    limit="${MONITOR_CONTEXT_ROTATION_LIMIT_TOKENS:-$(_cfg_get monitor.context_rotation.limit_tokens 1000000)}"
fi
[[ "$limit" =~ ^[0-9]+$ ]] && (( limit > 0 )) || limit=1000000

if [[ -z "$threshold" ]]; then
    # The orchestrator threshold is the default for a bare call. A
    # worker-targeted caller passes --threshold explicitly (PR for
    # jacob-greene/nexus#2 wires monitor.context_rotation.worker_tokens through
    # the worker floor).
    threshold="${MONITOR_CONTEXT_ROTATION_ORCHESTRATOR_TOKENS:-$(_cfg_get monitor.context_rotation.orchestrator_tokens 250000)}"
fi
[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=250000

# ---- transcript resolution ---------------------------------------------
# Projects root. Claude Code writes transcripts under
# $CLAUDE_CONFIG_DIR/projects when that env var is set (the agent-sandbox
# sets it to ~/.claude/sandbox-config) and ~/.claude/projects otherwise.
# `monitor/ng`'s _report_session_id predates the sandbox and only knows
# the latter; honouring both here is what makes this work in-sandbox.
_projects_root() {
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" && -d "$CLAUDE_CONFIG_DIR/projects" ]]; then
        printf '%s' "$CLAUDE_CONFIG_DIR/projects"
    else
        printf '%s' "$HOME/.claude/projects"
    fi
}

# Find <root>/*/<session>.jsonl. Newest wins if a session id somehow
# appears under two project slugs (it should not).
_transcript_for_session() {
    local sid="$1" root
    root=$(_projects_root)
    [[ -n "$sid" && -d "$root" ]] || return 1
    # A loop, not `ls -t <glob> | head -1`: under nullglob an unmatched
    # glob would hand `ls` no operand and it would list the cwd instead
    # (the nullglob bare-form class), and the pipe adds a SIGPIPE hazard.
    local f match=""
    for f in "$root"/*/"$sid".jsonl; do
        [[ -e "$f" ]] || continue
        if [[ -z "$match" || "$f" -nt "$match" ]]; then match=$f; fi
    done
    [[ -n "$match" ]] || return 1
    printf '%s' "$match"
}

_state_dir() { printf '%s' "${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"; }

# window → session id. The orchestrator's pin is authoritative for the
# configured target window (a hook rewrites it every turn, including
# after a /clear which mints a new id); workers resolve through the
# spawn provenance record.
_session_for_window() {
    local win="$1" state target rec sid=""
    state=$(_state_dir)
    target="${MONITOR_TARGET:-$(_cfg_get monitor.target_window orchestrator)}"
    if [[ "$win" == "$target" ]] && [[ -f "$state/orchestrator-session-id" ]]; then
        sid=$(head -n1 "$state/orchestrator-session-id" 2>/dev/null | tr -d '[:space:]')
        [[ -n "$sid" ]] && { printf '%s' "$sid"; return 0; }
    fi
    rec="$state/windows/$win.json"
    # jq is guaranteed here: the one jq gate below runs before any caller.
    if [[ -f "$rec" ]]; then
        sid=$(jq -r '.session_id // ""' "$rec" 2>/dev/null)
        [[ "$sid" == "null" ]] && sid=""
        [[ -n "$sid" ]] && { printf '%s' "$sid"; return 0; }
    fi
    return 1
}

# The caller's own session, when no selector was given. Same layering as
# monitor/ng's _report_session_id, minus the freshest-jsonl heuristic:
# guessing the wrong session here would report someone else's context and
# rotate the wrong agent, which is worse than reporting nothing.
_own_session() {
    local sid="${CLAUDE_CODE_SESSION_ID:-}"
    sid="${sid//[$'\n\r\t ']/}"
    if [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        printf '%s' "$sid"; return 0
    fi
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -f "$CLAUDE_PROJECT_DIR/sessions/current_session_id" ]]; then
        sid=$(<"$CLAUDE_PROJECT_DIR/sessions/current_session_id")
        sid="${sid//[$'\n\r\t ']/}"
        [[ -n "$sid" ]] && { printf '%s' "$sid"; return 0; }
    fi
    return 1
}

fail() {
    local msg="$1"
    if (( quiet == 0 )); then
        if [[ "$format" == "json" ]]; then
            printf '{"ok":false,"error":"%s"}\n' "$msg"
        else
            printf 'error=%s\n' "$msg"
        fi
    fi
    exit 1
}

# The ONE jq gate, LOUD, ahead of every jq use (window lookup included).
# `fail` exits 1; the explicit `exit 1` makes the refusal visible here.
command -v jq >/dev/null 2>&1 || { fail "jq-missing"; exit 1; }

if [[ -z "$transcript" ]]; then
    if [[ -n "$session" ]]; then
        :
    elif [[ -n "$window" ]]; then
        session=$(_session_for_window "$window") || fail "no-session-for-window:$window"
    else
        session=$(_own_session) || fail "no-session-id"
    fi
    transcript=$(_transcript_for_session "$session") || fail "no-transcript:$session"
fi

[[ -f "$transcript" ]] || fail "transcript-missing"

# ---- read the last main-chain assistant usage ---------------------------
# One jq program, applied to a bounded tail first. `select(.isSidechain
# != true)` drops subagent turns; the `// empty` guards cover the
# summary / file-history-snapshot lines that carry no usage at all.
_read_usage() {
    jq -rs '
        [ .[]
          | select(type == "object")
          | select(.type == "assistant")
          | select(.isSidechain != true)
          | .message.usage // empty
          | ((.input_tokens // 0)
             + (.cache_creation_input_tokens // 0)
             + (.cache_read_input_tokens // 0))
          | select(. > 0)
        ] | last // empty
    ' 2>/dev/null
}

tokens=$(tail -n "$SCAN_LINES" "$transcript" 2>/dev/null | _read_usage)
if [[ -z "$tokens" ]]; then
    tokens=$(_read_usage < "$transcript")
fi
[[ "$tokens" =~ ^[0-9]+$ ]] || fail "no-usage-record"

pct=$(( tokens * 100 / limit ))
over=0
(( threshold > 0 && tokens >= threshold )) && over=1

if (( quiet == 0 )); then
    if [[ "$format" == "json" ]]; then
        jq -nc \
            --argjson tokens    "$tokens" \
            --argjson limit     "$limit" \
            --argjson pct       "$pct" \
            --argjson threshold "$threshold" \
            --argjson over      "$over" \
            --arg     session   "$session" \
            --arg     window    "$window" \
            --arg     transcript "$transcript" \
            '{ok: true, tokens: $tokens, limit: $limit, pct: $pct,
              threshold: $threshold, over: ($over == 1),
              session: $session, window: $window, transcript: $transcript}'
    else
        printf 'tokens=%s limit=%s pct=%s threshold=%s over=%s session=%s window=%s transcript=%s\n' \
            "$tokens" "$limit" "$pct" "$threshold" "$over" \
            "${session:-unknown}" "${window:-}" "$transcript"
    fi
fi

(( over == 1 )) && exit 10
exit 0
