#!/usr/bin/env bash
# monitor/hooks/bash-footgun-guard.sh
#
# Claude Code PreToolUse hook for the `Bash` matcher. Delivers a
# JUST-IN-TIME reminder the moment a worker reaches for a known shell
# footgun, so the worker floor doesn't have to front-load every
# footgun into every spawn prompt (where it dilutes the task and is
# forgotten before it's needed). This is the mechanism that lets the
# always-injected floor shrink: the rules that only matter at a
# specific command move OUT of the prompt and INTO this hook, fired at
# the exact tool call that would trip them.
#
# Same proven shape as monitor/hooks/gh-write-guard.sh (PreToolUse,
# Bash matcher, inspects .tool_input.command) and the data-driven
# design of monitor/hooks/async-launch-detect.sh (patterns live in a
# conf file; adding a footgun is a data edit, not a code change).
#
# DELIVERY: on a `warn` match the hook prints
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#    "additionalContext":"<message>"}}
# on stdout and exits 0 — the tool still runs, and the model reads the
# reminder in-context and self-corrects on its next call. On a `block`
# match the hook prints the message to stderr and exits 2, which
# BLOCKS the tool and shows the message to the model (per the Claude
# Code hooks reference: PreToolUse exit 2 = blocking error, stderr
# shown to Claude). `block` is reserved for severe, session-wide
# consequences; the footgun conf ships `warn`-only.
#
# DEDUP: each reminder fires at most ONCE per worker session, keyed on
# (window, tag) via a sentinel under monitor/.state/footgun-seen/.
# A worker who has seen the pkill warning doesn't re-read it on every
# later pkill — the reminder has done its job.
#
# Hot-path discipline: every failure path exits 0 (allow). A wedged or
# erroring PreToolUse hook would block the worker's turn; degrade
# silently instead. O(milliseconds): one conf read, cheap regexes.
#
# Inputs: PreToolUse payload JSON on stdin (.tool_name, .tool_input.command).
# Env: $NEXUS_WORKER_WINDOW (dedup key), $NEXUS_ROOT (state + conf root),
#      $NEXUS_STATE_DIR / $NEXUS_FOOTGUN_PATTERNS (test overrides).

set -u

command -v jq >/dev/null 2>&1 || exit 0

if [ -n "${NEXUS_STATE_DIR:-}" ]; then
    _state_dir="$NEXUS_STATE_DIR"
elif [ -n "${NEXUS_ROOT:-}" ]; then
    _state_dir="$NEXUS_ROOT/monitor/.state"
else
    exit 0
fi

if [ -n "${NEXUS_FOOTGUN_PATTERNS:-}" ]; then
    _pattern_file="$NEXUS_FOOTGUN_PATTERNS"
elif [ -n "${NEXUS_ROOT:-}" ]; then
    _pattern_file="$NEXUS_ROOT/monitor/bash-footgun-patterns.conf"
else
    _self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || _self_dir="."
    _pattern_file="$_self_dir/../bash-footgun-patterns.conf"
fi

_window="${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-unknown}}"

_payload=$(head -c 65536 2>/dev/null || true)
[ -n "$_payload" ] || exit 0

_tool=$(printf '%s' "$_payload" | jq -r '.tool_name // empty' 2>/dev/null) || _tool=""
[ "$_tool" = "Bash" ] || exit 0

_cmd=$(printf '%s' "$_payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || _cmd=""
[ -n "$_cmd" ] || exit 0

_seen_dir="$_state_dir/footgun-seen"

# already_seen <tag> — rc 0 if this (window, tag) reminder has already
# fired this session. Sentinel filename encodes both keys.
already_seen() {
    local tag="$1"
    local key="${_window//[^a-zA-Z0-9_-]/_}.${1//[^a-zA-Z0-9_-]/_}"
    [ -f "$_seen_dir/$key" ]
}
mark_seen() {
    local tag="$1"
    local key="${_window//[^a-zA-Z0-9_-]/_}.${1//[^a-zA-Z0-9_-]/_}"
    mkdir -p "$_seen_dir" 2>/dev/null || return 0
    : > "$_seen_dir/$key" 2>/dev/null || true
}

# deliver <severity> <tag> <message>: warn => additionalContext + exit 0;
# block => stderr + exit 2. Marks the (window, tag) seen either way.
deliver() {
    local severity="$1" tag="$2" msg="$3"
    mark_seen "$tag"
    if [ "$severity" = "block" ]; then
        printf 'bash-footgun-guard [%s]: %s\n' "$tag" "$msg" >&2
        exit 2
    fi
    # warn: inject as additionalContext. jq -n builds valid JSON and
    # escapes the message safely.
    jq -nc --arg m "bash-footgun-guard [$tag]: $msg" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$m}}' \
        2>/dev/null || true
    exit 0
}

# ---- conf-driven matches (command-name / flag triggers) ----------------
# First matching row wins. Rows sharing a tag collapse via the dedup
# sentinel, so pkill and pgrep fire the pkill-self reminder once.
if [ -f "$_pattern_file" ]; then
    while IFS='|' read -r tag severity cmd_re message; do
        [ -z "${tag// /}" ] && continue
        case "$tag" in '#'*) continue ;; esac
        [ -n "$cmd_re" ] || continue
        if [[ "$_cmd" =~ $cmd_re ]]; then
            already_seen "$tag" && exit 0
            deliver "${severity:-warn}" "$tag" "$message"
        fi
    done < "$_pattern_file"
fi

# ---- in-code matches (pipe-triggered; can't live in a |-delimited conf) --
# These footguns trigger on a literal shell pipe, which the conf's field
# separator forbids. Matched here instead. Same dedup + delivery.

# python … | tail/tee block-buffers and reads as a hang.
if printf '%s' "$_cmd" | grep -Eq 'python[0-9.]*\b[^|]*\|[[:space:]]*(tail|tee)\b'; then
    already_seen "pipe-buffer" || deliver warn "pipe-buffer" \
        "Pipelines block-buffer: python … | tail/tee emits nothing until the process exits and reads as a hang. Add python -u (or flush=True), or drop the pipe."
fi

# ml/module piped: the env-changing eval is discarded in the subshell.
if printf '%s' "$_cmd" | grep -Eq '\b(ml|module)[[:space:]][^|]*\|'; then
    already_seen "ml-pipe" || deliver warn "ml-pipe" \
        "ml/module is a shell function; piping it forks a subshell and the env-changing eval is silently discarded (the module never loads). Run ml … on its own line, unpiped."
fi

exit 0
