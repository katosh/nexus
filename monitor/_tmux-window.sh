#!/usr/bin/env bash
# monitor/_tmux-window.sh — robust tmux window targeting by @id, resolved
# fresh from the durable window NAME. Fixes the dotted/special-name
# targeting bug (your-org/nexus-code#323).
#
# THE BUG: `tmux <verb> -t "$NAME"` parses NAME as a `window.pane`
# target. A name with a dot (`cc-update-2.1.183`) is read as window
# `cc-update-2`, pane `1.183` → `can't find pane 1.183`; the window
# exists but the op silently never lands (dead worker, no launcher).
#
# THE FIX: target by the tmux window id (`@NN`). `-t @id` never
# dot-parses and uniquely names a window, so it sidesteps `-t name`
# parsing entirely — robust to dots AND most other symbols.
#
# THE RESTART CAVEAT (load-bearing): @id is assigned per tmux SERVER
# LIFETIME. A server restart recreates every window with a NEW id. So
# @id is an EPHEMERAL handle, never a durable key — anything persisted
# (provenance records, action-log rows, the orchestrator's notion of a
# window across turns) keys on the NAME. Every targeting op therefore
# RE-RESOLVES name→@id fresh at use time. That both survives a restart
# (the name is recreated; we re-resolve to the new id) and fixes the
# dot bug (we never hand a dotted name to a `-t`). Within a single
# spawn — where no restart can interleave — capture the id once at
# `new-window` time and reuse it; across turns, re-resolve.
#
# RESOLUTION delimiter: a literal TAB between `#{window_id}` and
# `#{window_name}`. validate_window_name() rejects control chars
# (TAB/newline included) AND restricts names to a readable charset, so
# the TAB split is unambiguous and no name can corrupt the parse.
#
# Dual-mode: source it for the functions, or run it as a CLI —
#   resolve_window_id <name>     → `@id` on stdout, rc1 if not present
#   resolve_window_index <name>  → window index on stdout, rc1 if absent
#   validate_window_name <name>  → rc0 if safe; rc2 + reason on stderr
#   monitor/_tmux-window.sh {id|index|validate} <name>

# Allowed window-name charset. The point of #323 is that DOTS keep
# working for human-readable names (`cc-update-2.1.183`), so dots are
# explicitly in the set. We additionally forbid every delimiter the
# repo's various name→{id,index} resolvers split on (TAB, '|', space)
# plus tmux's own target metacharacters (':' '.' for -t are made safe
# by @id targeting, but a leading '-' could be read as a flag), so a
# name minted here stays parseable by every consumer:
#     first char  : [A-Za-z0-9]
#     remaining   : [A-Za-z0-9._-]
# This is a guard, not a transform: a conforming name (the only kind
# the orchestrator and reserved set use today) is passed through
# byte-for-byte unchanged.
_TMUX_WINDOW_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

validate_window_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        printf '_tmux-window: window name is empty\n' >&2
        return 2
    fi
    # Explicit control-char check first so the diagnostic names the real
    # problem (a stray TAB/newline) instead of the generic charset line.
    if [[ "$name" == *[$'\001'-$'\037\177']* ]]; then
        printf '_tmux-window: window name contains control characters (TAB/newline/etc): %q\n' "$name" >&2
        return 2
    fi
    if [[ ! "$name" =~ $_TMUX_WINDOW_NAME_RE ]]; then
        printf '_tmux-window: window name %q has characters outside [A-Za-z0-9._-] (must start alphanumeric). Dots are fine; spaces, %s, %s, %s, and other punctuation are not.\n' \
            "$name" "'|'" "':'" "'/'" >&2
        return 2
    fi
    return 0
}

# Re-resolve a window NAME to its current @id. Prints `@NN` on rc0;
# rc1 (no stdout) when tmux is unavailable or no window matches. First
# match wins (names are unique in the single nexus session). Exact,
# full-field string compare — never a prefix/glob — so `worker` does
# not match `worker-2`.
resolve_window_id() {
    local name="$1" id wn
    command -v tmux >/dev/null 2>&1 || return 1
    while IFS=$'\t' read -r id wn; do
        if [[ "$wn" == "$name" ]]; then
            printf '%s\n' "$id"
            return 0
        fi
    done < <(tmux list-windows -F '#{window_id}'$'\t''#{window_name}' 2>/dev/null)
    return 1
}

# Same resolution, returning the window INDEX (for index-keyed
# consumers like pane-state.sh). Prefer resolve_window_id for any
# `-t` targeting; the index is only for tools that demand it.
resolve_window_index() {
    local name="$1" idx wn
    command -v tmux >/dev/null 2>&1 || return 1
    while IFS=$'\t' read -r idx wn; do
        if [[ "$wn" == "$name" ]]; then
            printf '%s\n' "$idx"
            return 0
        fi
    done < <(tmux list-windows -F '#{window_index}'$'\t''#{window_name}' 2>/dev/null)
    return 1
}

# CLI entrypoint — active only when executed directly, never when
# sourced. Lets shell-level callers (skill docs, ad-hoc ops) resolve an
# id without writing the awk: `wid=$(monitor/_tmux-window.sh id "$WIN")`.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _cmd="${1:-}"
    case "$_cmd" in
        id)       resolve_window_id "${2:-}" ;;
        index)    resolve_window_index "${2:-}" ;;
        validate) validate_window_name "${2:-}" ;;
        *) printf 'usage: %s {id|index|validate} <window-name>\n' "$0" >&2; exit 64 ;;
    esac
fi
