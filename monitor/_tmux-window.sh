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
#   resolve_window_id <name>     → `@id` on stdout; see the rc table below
#   resolve_window_index <name>  → window index on stdout; same rc table
#   validate_window_name <name>  → rc0 if safe; rc2 + reason on stderr
#   monitor/_tmux-window.sh {id|index|validate} <name>
#
# ---------------------------------------------------------------------
# THE RESOLUTION CONTRACT IS THREE-STATE (your-org/nexus-code#699)
# ---------------------------------------------------------------------
#
#   rc 0  PRESENT             — `@id` / index on stdout.
#   rc 1  LOOKED, AND ABSENT  — tmux answered; no window has this name.
#   rc 2  CANNOT ASK          — the name is empty, so no query was made.
#   rc 3  COULD NOT LOOK      — no `tmux` on PATH, or `list-windows`
#                               failed (no server, no session, socket or
#                               permission error, protocol mismatch).
#
# WHY. These resolvers used to return rc 1 for all four, and `2>/dev/null`
# swallowed the reason, so "I could not look" was indistinguishable from
# "I looked and it is gone". Any consumer whose non-zero arm is permissive
# then takes an irreversible action on a window it never observed — which
# is exactly what `ng retire-window` did: rc 1 → empty wid → its own
# preflight gate skipped → state pruned for a window that may have been
# alive the whole time. That is your-org/nexus-code#646 one layer down.
#
# This repo had already solved this once. `_target_window_present`
# (monitor/watcher/_lib.sh) carries the same three buckets, built after a
# failed `list-windows` was read as "absent" and spun up a duplicate
# orchestrator (the U1 respawn-storm). It never propagated here, because
# this file was written for a different bug (#323, dot-parsing) and
# re-implemented the query rather than reusing the contract.
#
# POLARITY — deliberately INVERTED from `_target_window_present`, which
# uses 1=can't-classify / 2=absent. The difference is forced, not
# stylistic: this file is also EXECUTED as a CLI, where 126 and 127
# already mean "could not run" (your-org/nexus-code#650). A contract
# whose HIGHER code means "absent" would collide with the shell's own
# could-not-run codes, so the only composable arrangement is
# `1 = absent, >= 2 = could not determine`. `_target_window_present` is
# sourced-only and never faces 126/127, so it is free of that constraint.
# The one-line rule for every consumer of EITHER:
#
#     rc 0 is the only "yes"; only rc 1 here is a "no";
#     everything else means DO NOT ACT.

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

# Ask tmux for the window table. Prints rows on stdout (rc 0); rc 3 —
# with a DIAGNOSTIC on stderr — when the question could not be put to
# tmux at all. The whole point of the function is that the caller can
# tell those apart, so the old `2>/dev/null` is gone: a query that fails
# now says why. Sole querier for both resolvers, so neither can drift
# back to a two-valued shape independently.
#
# The `2>&1` merge is safe for the row stream. tmux is silent on stderr
# when it succeeds, and every consumer below requires a row to carry a
# TAB *and* a correctly-shaped first field (`@N` / a bare integer), which
# no diagnostic line satisfies. So a stray warning can neither match a
# name nor be handed back as an id — it is simply skipped.
_tmux_window_rows() {
    local fmt="$1" out rc=0 err
    if ! command -v tmux >/dev/null 2>&1; then
        printf '_tmux-window: tmux is not on PATH — window presence is UNKNOWN, not absent\n' >&2
        return 3
    fi
    out=$(tmux list-windows -F "$fmt" 2>/dev/null) || rc=$?
    if (( rc != 0 )); then
        # Re-run ONLY to capture the reason. The verdict comes from the first
        # call's rc; this second one just decorates the diagnostic, which is
        # what `2>/dev/null` used to throw away.
        err=$(tmux list-windows -F "$fmt" 2>&1 >/dev/null)
        printf '_tmux-window: tmux list-windows failed (rc %d) — window presence is UNKNOWN, not absent: %s\n' \
            "$rc" "${err//$'\n'/ }" >&2
        return 3
    fi
    printf '%s\n' "$out"
    return 0
}

# ---------------------------------------------------------------------
# THE DELIMITER IS '|', AND IT MUST NOT BE A TAB (your-org/nexus-code#699)
# ---------------------------------------------------------------------
#
# These resolvers used to split on a literal TAB. Under a C/POSIX locale,
# tmux SUBSTITUTES the tab in `-F` output with `_`:
#
#   LC_ALL=en_US.utf8  tmux list-windows -F '#{window_id}\t#{window_name}'
#       -> "@0" TAB "orchestrator"
#   LC_ALL=C           (same command, same tmux, same server)
#       -> "@0_orchestrator"
#
# Measured on tmux 2.6, the repo's floor version. The row then fails to
# split, the name never matches, and the resolver reports rc 1 — "I looked
# and it is ABSENT" — for a window that is demonstrably present. That is
# worse than the laundering this contract fixes: not "could not look" sold
# as absence, but a WRONG ANSWER sold as absence. On the old two-valued
# contract it drove `ng retire-window` to skip its preflight and prune the
# state of a LIVE window, under nothing more exotic than `LC_ALL=C` — the
# default in many cron, systemd and CI contexts.
#
# '|' is printable, so no locale rewrites it, and it is already the
# delimiter the repo's four other window resolvers use. It is safe as a
# delimiter for the same reason the TAB was believed to be:
# validate_window_name() forbids it in a minted name, and the charset
# `[A-Za-z0-9._-]` cannot produce one.
_TMUX_WINDOW_DELIM='|'

# Belt to the delimiter's braces. If a row ever fails to split into a
# well-shaped (id, name) pair, do NOT skip it and fall through to "absent" —
# that is precisely how the tab bug stayed invisible. A row we cannot parse
# means we did not get an answer we understand, which is rc 3.
_tmux_window_check_row() {
    local key="$1" name="$2" shape="$3"
    if [[ -z "$name" || "$key" != $shape ]]; then
        printf '_tmux-window: unparseable list-windows row %q — the delimiter %q did not split it (a locale that rewrites the delimiter does this; see the header). Window presence is UNKNOWN, not absent.\n' \
            "$key$name" "$_TMUX_WINDOW_DELIM" >&2
        return 1
    fi
    return 0
}

# An empty name is a CALLER BUG, not a missing window: nothing was asked,
# so "absent" would be a fabricated answer. rc 2 — shared by both
# resolvers and by validate_window_name, which already used it.
_tmux_window_require_name() {
    [[ -n "$1" ]] && return 0
    printf '_tmux-window: %s called with an EMPTY window name — refusing to answer (a question never asked is not an absent window)\n' \
        "$2" >&2
    return 2
}

# Re-resolve a window NAME to its current @id. Prints `@NN` on rc 0; see
# the three-state contract in the header for the non-zero codes. First
# match wins (names are unique in the single nexus session). Exact,
# full-field string compare — never a prefix/glob — so `worker` does
# not match `worker-2`.
resolve_window_id() {
    local name="$1" id wn rows
    _tmux_window_require_name "$name" resolve_window_id || return 2
    rows=$(_tmux_window_rows "#{window_id}${_TMUX_WINDOW_DELIM}#{window_name}") || return 3
    while IFS="$_TMUX_WINDOW_DELIM" read -r id wn; do
        [[ -n "$id$wn" ]] || continue
        _tmux_window_check_row "$id" "$wn" '@[0-9]*' || return 3
        if [[ "$wn" == "$name" ]]; then
            printf '%s\n' "$id"
            return 0
        fi
    done <<<"$rows"
    return 1
}

# Same resolution, returning the window INDEX (for index-keyed
# consumers like pane-state.sh). Prefer resolve_window_id for any
# `-t` targeting; the index is only for tools that demand it. Same
# three-state contract.
resolve_window_index() {
    local name="$1" idx wn rows
    _tmux_window_require_name "$name" resolve_window_index || return 2
    rows=$(_tmux_window_rows "#{window_index}${_TMUX_WINDOW_DELIM}#{window_name}") || return 3
    while IFS="$_TMUX_WINDOW_DELIM" read -r idx wn; do
        [[ -n "$idx$wn" ]] || continue
        _tmux_window_check_row "$idx" "$wn" '[0-9]*' || return 3
        if [[ "$wn" == "$name" ]]; then
            printf '%s\n' "$idx"
            return 0
        fi
    done <<<"$rows"
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
