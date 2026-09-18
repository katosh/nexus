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
#   monitor/_tmux-window.sh {id|index|key|validate} <name-or-key>
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
#
# THE SESSION ARGUMENT (your-org/nexus-code#944). A bare `tmux list-windows`
# lists the CURRENT session only. That is the right scope for a question
# phrased as a NAME — "the window I am in" — and the WRONG scope for a key
# that explicitly NAMES a session, because the rows then describe a session
# the key does not refer to and nothing errors. Measured on a private socket,
# two sessions, `other` current: `resolve_window_key 0:1` returned `zulu`, a
# window in session `other`, and `paste-followup.sh` consumed that stdout and
# pasted into it. Wrong-window delivery, rc 0, no diagnostic.
#
# So the scope is now a PARAMETER rather than an accident of which session
# tmux considers current. Omitted (every NAME-keyed caller) it is unchanged:
# the current session, which is what a name means. Supplied, the rows come
# from the session the key names.
#
# A session that does not exist makes `list-windows -t` FAIL, which lands in
# the rc 3 arm below — COULD NOT LOOK, never "absent". That is the direction
# this whole file exists to preserve, and it is load-bearing here: `absent` is
# in `_bookkeeping.sh`'s kill allowlist, so a resolver that answered "absent"
# for an unreachable session would be authorising a kill on no evidence.
_tmux_window_rows() {
    local fmt="$1" session="${2-}" out rc=0 err
    if ! command -v tmux >/dev/null 2>&1; then
        printf '_tmux-window: tmux is not on PATH — window presence is UNKNOWN, not absent\n' >&2
        return 3
    fi
    # Never an empty expansion: the array always carries `-F "$fmt"`, so this
    # is safe under `set -u` in a sourcing caller.
    local -a _twr_args=(list-windows -F "$fmt")
    [[ -n "$session" ]] && _twr_args=(list-windows -t "${session}:" -F "$fmt")
    out=$(tmux "${_twr_args[@]}" 2>/dev/null) || rc=$?
    if (( rc != 0 )); then
        # Re-run ONLY to capture the reason. The verdict comes from the first
        # call's rc; this second one just decorates the diagnostic, which is
        # what `2>/dev/null` used to throw away.
        err=$(tmux "${_twr_args[@]}" 2>&1 >/dev/null)
        printf '_tmux-window: tmux list-windows%s failed (rc %d) — window presence is UNKNOWN, not absent: %s\n' \
            "${session:+ -t ${session}:}" "$rc" "${err//$'\n'/ }" >&2
        return 3
    fi
    printf '%s\n' "$out"
    return 0
}

# _tmux_window_rows_all <fmt> — EVERY window on the server, across EVERY
# session. Same tmux-on-PATH guard and the same rc-3-COULD-NOT-LOOK arm as
# `_tmux_window_rows`; only the scope differs.
#
# WHY IT IS A SEPARATE FUNCTION AND NOT A FLAG (your-org/nexus-code#1318).
# `_tmux_window_rows`'s scope is load-bearing: `#944` made the session a
# PARAMETER precisely so a NAME-keyed question keeps meaning "the window I am
# in" and a `session:window` key is judged against the session it names. A
# mode flag on that function is one careless edit away from leaking `-a` into
# the ANSWER path, which would silently change what a bare name resolves to on
# a multi-session server — and `paste-followup.sh` consumes that stdout to
# target a paste. Two functions cannot be confused; one function with a mode
# can.
#
# IT TAKES NO SESSION, AND REFUSES ONE. Measured on tmux 2.6, two sessions:
# `list-windows -a -t A:` returns ALL rows at rc 0 — `-a` overrides `-t` for
# the row set — while `-a -t nosuch:` still FAILS at rc 1. A confusing hybrid
# that validates an argument it then ignores, so the combination is refused
# here rather than reasoned about at each call site.
_tmux_window_rows_all() {
    local fmt="$1" out rc=0 err
    if (( $# > 1 )); then
        printf '_tmux-window: _tmux_window_rows_all takes no session — `-a` overrides `-t` for the row set while still validating it (measured, tmux 2.6). Use _tmux_window_rows for a scoped question.\n' >&2
        return 2
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        printf '_tmux-window: tmux is not on PATH — window presence is UNKNOWN, not absent\n' >&2
        return 3
    fi
    out=$(tmux list-windows -a -F "$fmt" 2>/dev/null) || rc=$?
    if (( rc != 0 )); then
        err=$(tmux list-windows -a -F "$fmt" 2>&1 >/dev/null)
        printf '_tmux-window: tmux list-windows -a failed (rc %d) — window presence is UNKNOWN, not absent: %s\n' \
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
# The optional SECOND argument scopes the lookup to a session, for the same
# reason `resolve_window_key` takes one (your-org/nexus-code#944). Omitted, the
# behaviour is unchanged: the current session, which is what a bare name means.
# It exists because `resolve_window_key` can now correctly resolve a
# `session:window` key to a NAME that lives in ANOTHER session — and a caller
# that then re-resolved that name to an @id here got rc 1, "no such window",
# which `paste-followup.sh` reported as "it closed between the check above and
# now (race with a close)". A false diagnosis is worse than none: it sends the
# reader to a mechanism that did not occur.
resolve_window_id() {
    local name="$1" session="${2-}" id wn rows
    _tmux_window_require_name "$name" resolve_window_id || return 2
    rows=$(_tmux_window_rows "#{window_id}${_TMUX_WINDOW_DELIM}#{window_name}" "$session") || return 3
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
    local name="$1" session="${2-}" idx wn rows
    _tmux_window_require_name "$name" resolve_window_index || return 2
    rows=$(_tmux_window_rows "#{window_index}${_TMUX_WINDOW_DELIM}#{window_name}" "$session") || return 3
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

# ── ONE KEY VOCABULARY FOR BOTH SIBLINGS (your-org/nexus-code#905) ──────
# `pane-state.sh` was INDEX-keyed and `paste-followup.sh` NAME-keyed — two
# helpers in one directory, driven in adjacent commands by every orchestrator,
# disagreeing about what a window key is. Measured on the live board, same
# shell, same window: `pane-state.sh 9` worked, `paste-followup.sh 9` and
# `paste-followup.sh 0:9` were both REJECTED, `paste-followup.sh diagclean`
# worked. `CLAUDE.md` documented the first convention only, so a reader who
# had internalised "these helpers are index-keyed" got a loud failure from the
# one that is not.
#
# Both failures are loud, so this was friction rather than corruption — but a
# convention nobody can predict is one that gets got wrong under pressure, and
# the tax is paid on every adjacent pair of commands. So both helpers now
# accept BOTH spellings, sharing this vocabulary.
#
# THEY SHARE THE VOCABULARY, NOT ONE ENTRY POINT, and saying otherwise was
# itself a defect here: `paste-followup.sh` calls `resolve_window_key`;
# `pane-state.sh` resolves a NAME through `resolve_window_index` and calls
# `resolve_window_key` for the ambiguity check. A first version of this
# comment claimed both went through `resolve_window_key` while `pane-state.sh`
# did not reference it at all.
#
# THE AMBIGUOUS CASE IS REFUSED, NOT GUESSED. A window NAMED `9` and a window
# AT INDEX `9` are different windows, and picking one silently is how a paste
# lands in the wrong pane. Names win only when unambiguous; a collision is
# rc 4 with both candidates named, because the caller can disambiguate and
# this resolver cannot.
#
#   rc 0 -> prints the window NAME (the durable key both tools target by)
#   rc 1 -> no such window        rc 2 -> empty key
#   rc 3 -> tmux would not answer rc 4 -> AMBIGUOUS (name and index collide)
resolve_window_key() {
    local key="$1" rows idx wn
    _tmux_window_require_name "$key" resolve_window_key || return 2

    # `session:window` — split the session off, keep the window part.
    #
    # THE SESSION IS NOW SCOPE, NOT MERELY DISCARDED (your-org/nexus-code#944).
    # It used to be stripped and thrown away while the row list came from
    # whichever session tmux considered current, so a key that NAMED a session
    # was judged against a different one. `validate_window_name` forbids `:` in
    # a minted name (charset `[A-Za-z0-9._-]`), so a colon in the key is always
    # the session delimiter and never part of a name.
    local bare="$key" session=""
    if [[ "$bare" == *:* ]]; then
        session="${key%%:*}"
        bare="${bare##*:}"
    fi
    # PUBLISHED for the caller. The rc-0 contract still prints the NAME and
    # nothing else — a caller that re-resolves that name to an @id needs the
    # session too, or it looks in the wrong one (your-org/nexus-code#944).
    RESOLVED_WINDOW_SESSION="$session"
    rows=$(_tmux_window_rows "#{window_index}${_TMUX_WINDOW_DELIM}#{window_name}" "$session") || return 3

    local name_hit="" index_hit=""
    while IFS="$_TMUX_WINDOW_DELIM" read -r idx wn; do
        [[ -n "$idx$wn" ]] || continue
        _tmux_window_check_row "$idx" "$wn" '[0-9]*' || return 3
        [[ "$wn"  == "$key"  ]] && name_hit="$wn"
        [[ "$wn"  == "$bare" ]] && name_hit="$wn"
        [[ "$idx" == "$bare" ]] && index_hit="$wn"
    done <<<"$rows"

    # Only an all-digit key can be an index, so only an all-digit key can
    # collide. Anything else resolves by name or not at all.
    if [[ "$bare" =~ ^[0-9]+$ ]]; then
        # THE COLLISION CHECK SPANS SESSIONS; THE ANSWER DOES NOT
        # (your-org/nexus-code#1318).
        #
        # The rows above come from ONE session — the current one, for a BARE
        # key, because no caller supplies a session and none can see which one
        # tmux considers current. So a name/index collision that SPANS
        # sessions was invisible: the resolver saw only one session's rows,
        # found no collision, and returned a confident answer about a window
        # the key names in no sense. Downstream, `pane-state.sh` classified
        # THAT window, and the classification measured on a private socket was
        # `absent` — the one KILL-AUTHORISING state (`_bookkeeping.sh`,
        # `_BK_KILL_OK_STATES`), at rc 0, with an empty stderr.
        #
        # Which window you got depended on which session tmux considered
        # current, which is not derivable from the arguments — so the wrong
        # answer was not even reproducible.
        #
        # ADJACENT TO `#1281`, NOT A REFUTATION OF IT. `#1281` closed a
        # fail-open reached when the resolver library is UNAVAILABLE; this is
        # a fail-open reached while it is present and working, found by
        # varying an axis nobody had varied — the number of tmux sessions.
        # Both end at the same hazard through different doors.
        #
        # ONLY THE REFUSAL WIDENS. The rc-0 answer path is untouched: a bare
        # key still resolves against the current session, so `paste-followup`
        # still pastes where it always did and `#944`'s I6 control ("a key
        # with no session part means the session I am in") still holds. An
        # explicit `session:window` key skips this block entirely, so I1-I5
        # are untouched by construction. What is added is a refusal the caller
        # can act on and the resolver cannot — pass the name, or `session:window`.
        #
        # A SWEEP THAT COULD NOT RUN IS rc 3, NEVER "NOT AMBIGUOUS". Spelling
        # a failed check as a passed one is `#1281`'s mechanism, and writing
        # it that way here would rebuild it inside its own fix.
        if [[ -z "$session" ]]; then
            local all_rows all_sess all_idx all_wn tok
            # SETS, not last-writer-wins. A single `xs_name_win` variable
            # overwritten per matching row keeps only the LAST hit, and the
            # comparison then answers about whichever row tmux happened to
            # print last — so a genuine collision whose last name-hit and last
            # index-hit coincide reads as unambiguous. That is the shape this
            # whole file exists to refuse, arriving inside its own fix.
            local xs_names=" " xs_indexes=" " xs_union=" " xs_union_n=0
            # A SWEEP THAT CANNOT RUN DEGRADES TO THE PRE-#1318 CHECK, LOUDLY —
            # it does NOT fail the whole resolve, and the distinction is the
            # difference between a fix and a regression.
            #
            # The first cut returned rc 3 here. That is right about the SWEEP
            # (a check that did not run must never be spelled "not ambiguous")
            # and wrong about the RESOLVER, because it made the tool strictly
            # LESS AVAILABLE than before this change: the scoped rows are
            # already in hand and already sufficient for the single-session
            # answer, so refusing outright breaks ordinary retirement — which
            # this suite's own rule says is not a fix. Measured: it turned
            # `_tmux-window.sh key` from rc 0 to rc 3 on an UNAMBIGUOUS numeric
            # key, in every environment whose tmux stub models the scoped
            # `list-windows` and not `-a`.
            #
            # AND THE ENVIRONMENT IS THE ARGUMENT. If the SCOPED call succeeded
            # and `-a` did not, this is not a real tmux: `-a` has existed since
            # long before 2.6, the repo's floor, so no production server answers
            # one and refuses the other. What is left is a mock — where the
            # cross-session hazard cannot exist, because a mock has no second
            # session to hide a collision in.
            #
            # So the degradation is announced on stderr and the single-session
            # check below still runs. Callers are then exactly as exposed as
            # they were before `#1318` — never more — and nothing is silently
            # relabelled: the one thing this must not do is spell a skipped
            # sweep as a passed one, and the diagnostic is what stops it.
            local _xs_swept=1
            all_rows=$(_tmux_window_rows_all \
                "#{session_name}${_TMUX_WINDOW_DELIM}#{window_index}${_TMUX_WINDOW_DELIM}#{window_name}") \
                || _xs_swept=0
            while (( _xs_swept == 1 )) && IFS="$_TMUX_WINDOW_DELIM" read -r all_sess all_idx all_wn; do
                [[ -n "$all_sess$all_idx$all_wn" ]] || continue
                if ! _tmux_window_check_row "$all_idx" "$all_wn" '[0-9]*'; then
                    _xs_swept=0; break
                fi
                # `session:index` is the only identifier unique server-wide.
                # Comparing NAMES would miss a collision between two windows
                # that happen to share one — the very confusion in question.
                tok="$all_sess:$all_idx"
                if [[ "$all_wn" == "$bare" ]]; then
                    [[ "$xs_names" == *" $tok "* ]] || xs_names+="$tok "
                    if [[ "$xs_union" != *" $tok "* ]]; then
                        xs_union+="$tok "; xs_union_n=$(( xs_union_n + 1 ))
                    fi
                fi
                if [[ "$all_idx" == "$bare" ]]; then
                    [[ "$xs_indexes" == *" $tok "* ]] || xs_indexes+="$tok "
                    if [[ "$xs_union" != *" $tok "* ]]; then
                        xs_union+="$tok "; xs_union_n=$(( xs_union_n + 1 ))
                    fi
                fi
            done <<<"$all_rows"
            # AMBIGUOUS iff BOTH readings have a candidate AND they do not name
            # one and the same window. `|union| >= 2` is the exact test: with
            # both sides non-empty, a union of one means every candidate IS
            # that window.
            #
            # INDEX-VS-INDEX ACROSS SESSIONS IS DELIBERATELY NOT REFUSED. Two
            # sessions both holding an index `2`, with no window NAMED `2`
            # anywhere, leaves `xs_names` empty and falls through. Refusing it
            # would make essentially EVERY bare index key rc 4 the moment a
            # second session exists — and this suite's own rule is that a
            # change which only widens refusal is not a fix, because it breaks
            # ordinary retirement, the far more common path. That gap is real
            # and is recorded rather than quietly closed.
            if (( _xs_swept == 0 )); then
                printf '_tmux-window: the CROSS-SESSION ambiguity sweep for %s could not run (tmux would not answer `list-windows -a`, or answered in a shape this resolver cannot parse). Falling back to the single-session check, which is the pre-#1318 behaviour — so this answer is NOT a claim that %s is unambiguous SERVER-WIDE. A real tmux answers `-a`; an environment that answers the scoped list and not `-a` is a mock, where the cross-session hazard cannot arise.\n' \
                    "$key" "$key" >&2
            elif [[ "$xs_names" != " " && "$xs_indexes" != " " ]] && (( xs_union_n >= 2 )); then
                printf '_tmux-window: AMBIGUOUS key %s — across ALL sessions, a window is NAMED %s at [%s] and a DIFFERENT window sits at INDEX %s at [%s]. Refusing to guess; pass the other one'"'"'s name, or an explicit session:window key.\n' \
                    "$key" "$bare" "${xs_names# }" "$bare" "${xs_indexes# }" >&2
                return 4
            fi
        fi
        if [[ -n "$name_hit" && -n "$index_hit" && "$name_hit" != "$index_hit" ]]; then
            printf '_tmux-window: AMBIGUOUS key %s — a window is NAMED %s, and a DIFFERENT window sits at INDEX %s (window %s). Refusing to guess; pass the other one'"'"'s name.\n' \
                "$key" "$bare" "$bare" "$index_hit" >&2
            return 4
        fi
        [[ -n "$name_hit"  ]] && { printf '%s\n' "$name_hit";  return 0; }
        [[ -n "$index_hit" ]] && { printf '%s\n' "$index_hit"; return 0; }
        return 1
    fi
    [[ -n "$name_hit" ]] && { printf '%s\n' "$name_hit"; return 0; }
    return 1
}

# ---------------------------------------------------------------------
# WINDOW SELECTION ACROSS AN ORCHESTRATOR RESTART (your-org/nexus-code#1528)
# ---------------------------------------------------------------------
#
# THE DEFECT. `cc-auto-update-apply.sh restart-orchestrator` ends in
# `kill-window -t orchestrator`; the watcher's absent-target recovery recreates
# the window in `_respawn.sh` with `new-window -d`. Killing a session's ACTIVE
# window makes tmux select another window in that session, and `-d` never
# selects, so an operator who was looking at the orchestrator is left on
# `services`, a worker, or the restart watchdog — and stays there.
#
# MEASURED ON tmux 2.6 (this host's version; nothing here is claimed for a
# newer tmux), private `-L` socket, 2026-09-13:
#
#   * killing the ACTIVE window selects the session's LAST window when one is
#     set (`@0` active, last `@2` -> `@2`), else some neighbour (`@4` -> `@6`,
#     not `@5`). tmux's choice is therefore RECORDED after the kill, never
#     derived.
#   * killing a NON-active window moves nothing; `new-window -d` moves nothing
#     in any session, grouped or not.
#   * the active window is PER SESSION. In a grouped pair (`new-session -t S`)
#     both sessions list the same `@id`s with their own `window_active`, and
#     killing a window active in S but not in G moved only S.
#   * a BARE `select-window -t @8` in that pair moved G — the session tmux
#     considered current — not S, the session the operator was in. Every
#     select here is therefore `-t '<session_id>:@id'`; both `S:@2` and
#     `$0:@2` were accepted (rc 0) and landed on the named session.
#   * `-t @999` (a dead id) is `can't find window @999`, rc 1 — a closed
#     window fails LOUD, which is what lets rule 3 below be a plain check.
#
# THE FOUR RULES, applied per session that held the target (issue #1528):
#   1. prior selection WAS the target        -> select the NEW orchestrator
#   2. prior selection still exists          -> select it (usually a no-op)
#   3. prior selection has CLOSED            -> select the orchestrator
#   4. capture missing / unreadable / stale  -> see NO-CAPTURE POLICY
#
# NEVER OVERRIDE A DELIBERATE CHOICE. The capture records, per session, the
# window tmux auto-selected right after the kill (`post` row). If the session's
# active window at restore time is not that one AND that one still exists, the
# operator navigated in the gap; the session is left alone. (If the post-kill
# window itself closed — a worker retired — tmux moved the selection again and
# nobody chose; the rules apply.)
#
# RULE 4 — NO CAPTURE (operator decision on #1528, 2026-09-13: "yes, default
# to the orchestrator after crashes too"). The capture is taken by WHOEVER
# KILLS — `cc-auto-update-apply.sh` before its kill, `_respawn_spawn_window`
# before its own (the crash / version / force-replace paths, where the target
# window is still present with a dead pane) — so a respawn with no capture
# means the window VANISHED on its own: an external kill, a window created
# without remain-on-exit, an older cc-update. tmux moved the selection iff the
# orchestrator was that session's ACTIVE window when it went (killing a
# non-active window moves nothing — measured), so that is the only question,
# and a blind "select the orchestrator" would answer it wrong for an operator
# who was working in a worker window. The watcher therefore keeps a rolling
# LAST-SEEN SNAPSHOT (`tmux_selection_snapshot`, one `list-windows -a` per
# scheduler task fire, 10 s cadence, `<state-dir>/tmux-selection-snapshot`),
# and the restore precedence is:
#
#     kill-time capture  ->  else last-seen snapshot  ->  else the orchestrator
#
# Snapshot arm (`tmux_selection_restore_fallback`), per session holding the
# new window: the snapshot says the orchestrator was active, or the window it
# says was active has since CLOSED -> select the new orchestrator; that window
# still exists -> leave the selection alone (the death did not move the
# operator); no snapshot, unreadable, or older than the SNAPSHOT STALE BOUND
# -> select the orchestrator, the operator's literal default. The snapshot is
# the watcher's rolling file and is never consumed here.
#
# THE WRITER KEEPS THE LAST SNAPSHOT THAT SAW THE TARGET. The watcher keeps
# ticking after the window vanishes, so a writer that overwrote on every fire
# would replace the pre-vanish snapshot with one describing the board AFTER
# tmux moved the selection — "active = W, W present" — and the arm would then
# never select the orchestrator. Measured in the respawn-loop integration
# suite before this rule: the real watcher's respawn read a 52-byte snapshot
# with NO row for its session (`rule=no-snapshot-row`). So when no session
# holds a window named the target, `tmux_selection_snapshot` writes nothing
# and the previous file stands (rc 1); the stale bound is what retires it.
#
# SNAPSHOT STALE BOUND: 120 s (`TMUX_SELECTION_SNAPSHOT_STALE_SECONDS`),
# twelve cadences, derived from the measured recovery latency (w240sk F2,
# 27 absent-target events 2026-06-27..2026-09-13): the window vanishes, the
# 2 s probe reaches its 3-poll streak and launches the respawn 10-17 s later
# (one outlier at 71 s), and the new window exists 8-38 s after launch. The
# snapshot read at restore is therefore the last pre-vanish one: at most one
# cadence (10 s) old at the vanish, plus 18-55 s typical, 109 s at the worst
# observed pairing. 120 s covers every observed case; a snapshot older than
# that at restore time did not precede THIS vanish by one loop — the watcher
# was in FS-degraded backoff (`_fs_guard_tick`, 15 s polls, scheduler
# suspended), down or wedged while a manual `spawn-fresh-orchestrator.sh`
# ran, or the recovery itself took longer than anything measured — and it is
# treated as ABSENT: the operator's default, the orchestrator. The snapshot
# is ADVISORY: it never outranks a kill-time capture (precedence above), and
# this bound is what keeps it from becoming a permanent form of a leftover
# capture.
#
# ERROR DIRECTION OF THE SNAPSHOT ARM, stated because it is a proxy: the
# snapshot is up to one cadence (10 s) old. An operator who moved from window
# W onto the orchestrator inside that last cadence, just before it vanished,
# is recorded as "on W"; W still exists, so the arm leaves the selection where
# tmux put it — which is tmux's LAST window, W, the window they came from. So
# the residual wrong answer is the least surprising one available, and it is
# accepted. The two things that would close it: the 2 s probe cadence (five
# times the state-file writes for a 5x smaller window) or a tmux
# `after-select-window` hook writing the snapshot on every switch (zero lag,
# but a global hook on the operator's server running a shell per switch, and
# it outlives the watcher). Neither is taken; the 10 s cadence is the trade.
#
# THE CAPTURE FILE lives in the state dir (`tmux_selection_capture_file`),
# carries an epoch, and is consumed EXACTLY ONCE: `tmux_selection_restore`
# removes it on every path except "no file". STALE BOUND: 1800 s. A restart
# reaches the respawn in well under that — the cc-update watchdog's own
# deadline is 180 s (`cc-restart-watchdog-loop.sh`), the watcher's
# absent-target streak is a few polls, the respawn itself ~22 s — and a
# manual `spawn-fresh-orchestrator.sh` after a watchdog-flagged restart lands
# inside it too; beyond it the capture describes a restart that is no longer
# this one. Override with TMUX_SELECTION_STALE_SECONDS.
#
# TWO-PHASE CAPTURE, because something earlier in the restart CAN move
# selection: `restart-orchestrator` kills a STALE watchdog window from a prior
# attempt before spawning its own, and if the operator happened to be on it
# the kill moves them (measured: killing the active window does). So the
# capture is taken BEFORE that kill, then REFRESHED immediately before the
# orchestrator kill: per session, a prior window that is STILL PRESENT is
# replaced by the current active (unchanged if the operator did not move;
# their new choice if they did), and a prior window that has CLOSED is kept
# — that is the stale-watchdog case, and it resolves by rule 3.
#
# RESTORE IS COSMETIC. It never changes the caller's rc, every tmux call in it
# is best-effort, and it is one `list-windows -a` plus at most one
# `select-window` per session. The tmux command is `TMUX_WINDOW_TMUX_CMD`
# (default `tmux`) so `cc-auto-update-apply.sh`'s `CC_AUTO_TMUX` seam and the
# suites' private-socket shims both reach it.
#
# Row shapes (a `|`-delimited file; nothing tmux emits is written unparsed):
#   v=1 / ts=<epoch> / target=<name>
#   prior|<session_id>|<active_window_id>|<1 if that window is the target>
#   post|<session_id>|<window_id tmux selected after the kill>
_TMUX_SELECTION_STALE_DEFAULT=1800

# tmux_selection_capture_file <state_dir> — the one path both writers and the
# reader use.
tmux_selection_capture_file() {
    printf '%s/tmux-selection-capture\n' "${1:?state dir required}"
}

# _tmux_selection_rows — `session_id|window_id|window_name|window_active` for
# every window on the server. rc 3 when tmux would not answer or answered in
# a shape this file cannot parse (a stub printing names, a locale rewriting
# the delimiter): a capture that cannot vouch for its rows writes nothing.
_tmux_selection_rows() {
    local tm="${TMUX_WINDOW_TMUX_CMD:-tmux}" out rc=0 sid wid wn act
    out=$("$tm" list-windows -a -F "#{session_id}|#{window_id}|#{window_name}|#{window_active}" 2>/dev/null) || rc=$?
    (( rc == 0 )) || return 3
    while IFS='|' read -r sid wid wn act; do
        [[ -n "$sid$wid$wn$act" ]] || continue
        [[ "$sid" == \$[0-9]* && "$wid" == @[0-9]* && ( "$act" == 0 || "$act" == 1 ) ]] || return 3
    done <<<"$out"
    printf '%s\n' "$out"
    return 0
}

# _tmux_selection_write <file> <target> <prior-rows> [<post-rows>] — atomic
# rewrite with a fresh epoch.
_tmux_selection_write() {
    local file="$1" target="$2" prior="$3" post="${4-}" tmp
    tmp="$file.tmp.$$"
    # `if`, not `[[ … ]] &&`: a brace group's status is its LAST command's,
    # and an empty <post> would make the group fail and the file vanish.
    {
        printf 'v=1\nts=%s\ntarget=%s\n' "$(date +%s)" "$target"
        if [[ -n "$prior" ]]; then printf '%s\n' "$prior"; fi
        if [[ -n "$post"  ]]; then printf '%s\n' "$post";  fi
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null && return 0
    rm -f "$tmp" 2>/dev/null
    return 1
}

# tmux_selection_capture [--refresh] <target-window-name> <file>
#
# Record, for every session holding a window named <target>, that session's
# active window and whether it IS the target. Without `--refresh` the capture
# is FRESH: an existing file is overwritten, whatever it says. With
# `--refresh` (the pre-kill call) an earlier capture's priors are reconciled
# as described above: a prior still present is superseded by the current
# active, a prior that has closed is kept. rc 0 written; rc 1 written but no
# session holds the target; rc 2 usage; rc 3 tmux would not answer — the file
# is REMOVED, so a stale earlier capture cannot be consumed in its place.
tmux_selection_capture() {
    local refresh=0
    if [[ "${1-}" == --refresh ]]; then refresh=1; shift; fi
    local target="${1-}" file="${2-}" rows
    [[ -n "$target" && -n "$file" ]] || return 2
    if ! rows=$(_tmux_selection_rows); then
        rm -f "$file" 2>/dev/null
        return 3
    fi
    # Earlier priors (the refresh case). A prior that is STILL PRESENT in its
    # session is superseded by the current active; one that has CLOSED is
    # kept, because the closer was this restart's own earlier kill.
    local old_prior=" " old_sid old_wid old_t kind rest
    if (( refresh == 1 )) && [[ -r "$file" ]]; then
        while IFS='|' read -r kind old_sid old_wid old_t; do
            [[ "$kind" == prior && "$old_sid" == \$[0-9]* && "$old_wid" == @[0-9]* ]] || continue
            old_prior+="$old_sid=$old_wid=$old_t "
        done < "$file"
    fi
    local sid wid wn act
    local targets=" " present=" " active=" " sessions=" "
    while IFS='|' read -r sid wid wn act; do
        [[ -n "$sid" ]] || continue
        present+="$sid:$wid "
        [[ "$act" == 1 ]] && active+="$sid=$wid "
        if [[ "$wn" == "$target" ]]; then
            targets+="$sid:$wid "
            [[ "$sessions" == *" $sid "* ]] || sessions+="$sid "
        fi
    done <<<"$rows"
    local prior="" s cur_wid is_t tok
    for s in $sessions; do
        cur_wid="${active##* $s=}"; cur_wid="${cur_wid%% *}"
        [[ "$active" == *" $s="* && -n "$cur_wid" ]] || continue
        # Refresh: keep an earlier prior only if it has since CLOSED.
        if [[ "$old_prior" == *" $s=@"* ]]; then
            tok="${old_prior##* $s=}"; tok="${tok%% *}"       # "@wid=t"
            old_wid="${tok%%=*}"; old_t="${tok##*=}"
            if [[ "$present" != *" $s:$old_wid "* ]]; then
                prior+="prior|$s|$old_wid|${old_t:-0}"$'\n'
                continue
            fi
        fi
        is_t=0; [[ "$targets" == *" $s:$cur_wid "* ]] && is_t=1
        prior+="prior|$s|$cur_wid|$is_t"$'\n'
    done
    _tmux_selection_write "$file" "$target" "${prior%$'\n'}" || return 3
    [[ -n "$prior" ]] && return 0
    return 1
}

# tmux_selection_note_post_kill <file> — append, per captured session, the
# window tmux auto-selected after the kill. Best-effort: rc 0 appended,
# rc 1 no file, rc 3 tmux would not answer (the prior rows stand; the
# restore then cannot detect navigation and applies the rules as captured).
tmux_selection_note_post_kill() {
    local file="$1" rows
    [[ -n "$file" && -r "$file" ]] || return 1
    rows=$(_tmux_selection_rows) || return 3
    local sid wid wn act active=" "
    while IFS='|' read -r sid wid wn act; do
        [[ "$act" == 1 ]] && active+="$sid=$wid "
    done <<<"$rows"
    local kind s w t post="" cur
    while IFS='|' read -r kind s w t; do
        [[ "$kind" == prior ]] || continue
        cur="${active##* $s=}"; cur="${cur%% *}"
        [[ "$active" == *" $s="* && -n "$cur" ]] || continue
        post+="post|$s|$cur"$'\n'
    done < "$file"
    [[ -n "$post" ]] || return 0
    printf '%s' "$post" >> "$file" 2>/dev/null || return 3
    return 0
}

# tmux_selection_restore <new-orchestrator-window-id> <file>
#
# Apply the four rules per captured session, consume the file. Prints one
# line per session on stdout (`session=$N rule=<...> select=@M|kept|skipped`)
# for the caller's log. rc: 0 applied (possibly nothing to move); 1 no file
# (the caller falls back to the snapshot arm — rule 4); 2 usage or the id is
# not `@N`; 3 file unreadable, stale, or tmux would not answer (file removed,
# nothing moved; a stale or unreadable capture also falls back).
# Never raises; every tmux call is best-effort.
tmux_selection_restore() {
    local new_wid="$1" file="$2"
    [[ -n "$file" ]] || return 2
    [[ "$new_wid" =~ ^@[0-9]+$ ]] || return 2
    [[ -r "$file" ]] || return 1
    local stale="${TMUX_SELECTION_STALE_SECONDS:-$_TMUX_SELECTION_STALE_DEFAULT}"
    local ts="" now _k _v
    # A draining read, not `sed | head`: the file is a handful of lines, and an
    # early-exit reader would enter early-exit-readers.manifest for nothing.
    while IFS='=' read -r _k _v; do
        [[ "$_k" == ts && -z "$ts" ]] && ts="$_v"
    done < "$file"
    now=$(date +%s)
    if [[ ! "$ts" =~ ^[0-9]+$ ]] || (( now - ts > stale )) || (( ts > now + 60 )); then
        printf 'capture=stale-or-unreadable ts=%s now=%s bound=%ss\n' "${ts:-?}" "$now" "$stale"
        rm -f "$file" 2>/dev/null
        return 3
    fi
    local rows
    if ! rows=$(_tmux_selection_rows); then
        printf 'capture=present tmux=would-not-answer\n'
        rm -f "$file" 2>/dev/null
        return 3
    fi
    local sid wid wn act present=" " active=" "
    while IFS='|' read -r sid wid wn act; do
        [[ -n "$sid" ]] || continue
        present+="$sid:$wid "
        [[ "$act" == 1 ]] && active+="$sid=$wid "
    done <<<"$rows"
    local kind s w t post=" "
    while IFS='|' read -r kind s w t; do
        [[ "$kind" == post && "$s" == \$[0-9]* && "$w" == @[0-9]* ]] && post+="$s=$w "
    done < "$file"
    local tm="${TMUX_WINDOW_TMUX_CMD:-tmux}" cur pk want rule
    while IFS='|' read -r kind s w t; do
        [[ "$kind" == prior && "$s" == \$[0-9]* && "$w" == @[0-9]* ]] || continue
        cur="${active##* $s=}"; cur="${cur%% *}"
        if [[ "$active" != *" $s="* || -z "$cur" ]]; then
            printf 'session=%s rule=session-gone select=skipped\n' "$s"; continue
        fi
        pk=""
        if [[ "$post" == *" $s="* ]]; then pk="${post##* $s=}"; pk="${pk%% *}"; fi
        # DELIBERATE NAVIGATION: the active window is not the one tmux chose
        # at the kill, AND that window still exists. If it has since CLOSED
        # (the operator was on a worker that retired in the gap), tmux moved
        # the selection a second time and the operator chose nothing — that
        # is rule 3's own scenario, so fall through to the rules. An operator
        # who navigated AND whose post-kill window then closed is read as the
        # latter; the cost is one select-window onto the orchestrator.
        if [[ -n "$pk" && "$cur" != "$pk" && "$present" == *" $s:$pk "* ]]; then
            printf 'session=%s rule=deliberate-navigation active=%s post-kill=%s select=kept\n' "$s" "$cur" "$pk"
            continue
        fi
        if [[ "$t" == 1 ]]; then
            want="$new_wid"; rule=prior-was-target
        elif [[ "$present" == *" $s:$w "* ]]; then
            want="$w"; rule=prior-still-present
        else
            want="$new_wid"; rule=prior-closed
        fi
        if [[ "$present" != *" $s:$want "* ]]; then
            printf 'session=%s rule=%s want=%s select=skipped (not in session)\n' "$s" "$rule" "$want"
            continue
        fi
        if [[ "$cur" == "$want" ]]; then
            printf 'session=%s rule=%s select=already-active %s\n' "$s" "$rule" "$want"
            continue
        fi
        if "$tm" select-window -t "${s}:${want}" >/dev/null 2>&1; then
            printf 'session=%s rule=%s select=%s\n' "$s" "$rule" "$want"
        else
            printf 'session=%s rule=%s select=%s FAILED (best-effort)\n' "$s" "$rule" "$want"
        fi
    done < "$file"
    rm -f "$file" 2>/dev/null
    return 0
}

# ── the rule-4 snapshot arm ──────────────────────────────────────────────
_TMUX_SELECTION_SNAPSHOT_STALE_DEFAULT=120

# tmux_selection_snapshot_file <state_dir> — the watcher's rolling last-seen
# file. Distinct from the capture file on purpose: the capture is consumed
# once by the restore, the snapshot is rewritten every task fire.
tmux_selection_snapshot_file() {
    printf '%s/tmux-selection-snapshot\n' "${1:?state dir required}"
}

# tmux_selection_snapshot <target-window-name> <file> — the watcher's per-fire
# writer: a FRESH capture (same rows: per session, the active window and
# whether it is the target) under its own name. rc 0 written; rc 1 NO session
# holds the target — nothing written, the previous snapshot STANDS (see the
# header: it is the pre-vanish board the restore needs, and the stale bound
# retires it); rc 2 usage; rc 3 tmux would not answer — the previous snapshot
# is removed, because one that cannot be refreshed would otherwise age into a
# confident wrong answer about a board tmux would not describe.
tmux_selection_snapshot() {
    local target="${1-}" file="${2-}" tmp rc=0
    [[ -n "$target" && -n "$file" ]] || return 2
    tmp="$file.new.$$"
    tmux_selection_capture "$target" "$tmp" || rc=$?
    case "$rc" in
        0) mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 3; } ;;
        1) rm -f "$tmp" 2>/dev/null ;;
        *) rm -f "$tmp" "$file" 2>/dev/null ;;
    esac
    return "$rc"
}

# tmux_selection_restore_fallback <new-orchestrator-window-id> <snapshot-file>
#
# Rule 4. Applied when no kill-time capture was usable. Per session holding
# the new window, decide from the last-seen snapshot as described in the
# header; with no usable snapshot, select the orchestrator. Prints one line
# per session (`session=$N rule=<...> select=...`). rc: 0 applied; 2 usage or
# the id is not `@N`; 3 tmux would not answer (nothing moved). Never consumes
# the snapshot. Best-effort: every tmux call is.
tmux_selection_restore_fallback() {
    local new_wid="$1" file="${2-}"
    [[ -n "$file" ]] || return 2
    [[ "$new_wid" =~ ^@[0-9]+$ ]] || return 2
    local rows
    if ! rows=$(_tmux_selection_rows); then
        printf 'snapshot-arm tmux=would-not-answer\n'
        return 3
    fi
    local sid wid wn act present=" " active=" " holders=" "
    while IFS='|' read -r sid wid wn act; do
        [[ -n "$sid" ]] || continue
        present+="$sid:$wid "
        [[ "$act" == 1 ]] && active+="$sid=$wid "
        [[ "$wid" == "$new_wid" && "$holders" != *" $sid "* ]] && holders+="$sid "
    done <<<"$rows"
    # Read the snapshot: fresh -> its prior rows; else a named reason.
    local stale="${TMUX_SELECTION_SNAPSHOT_STALE_SECONDS:-$_TMUX_SELECTION_SNAPSHOT_STALE_DEFAULT}"
    local why="" ts="" now _k _v snap=" " kind s w t
    now=$(date +%s)
    if [[ ! -r "$file" ]]; then
        why=no-snapshot
    else
        while IFS='=' read -r _k _v; do
            [[ "$_k" == ts && -z "$ts" ]] && ts="$_v"
        done < "$file"
        if [[ ! "$ts" =~ ^[0-9]+$ ]]; then
            why=snapshot-unreadable
        elif (( now - ts > stale )) || (( ts > now + 60 )); then
            why="snapshot-stale age=$(( now - ts ))s bound=${stale}s"
        else
            while IFS='|' read -r kind s w t; do
                [[ "$kind" == prior && "$s" == \$[0-9]* && "$w" == @[0-9]* ]] || continue
                snap+="$s=$w=${t:-0} "
            done < "$file"
        fi
    fi
    local tm="${TMUX_WINDOW_TMUX_CMD:-tmux}" cur tok rule want
    for s in $holders; do
        cur="${active##* $s=}"; cur="${cur%% *}"
        want="$new_wid"
        if [[ -n "$why" ]]; then
            rule="$why default=orchestrator"
        elif [[ "$snap" == *" $s=@"* ]]; then
            tok="${snap##* $s=}"; tok="${tok%% *}"          # "@wid=t"
            w="${tok%%=*}"; t="${tok##*=}"
            if [[ "$t" == 1 ]]; then
                rule=snapshot-active-was-target
            elif [[ "$present" == *" $s:$w "* ]]; then
                printf 'session=%s rule=snapshot-active-still-present active=%s select=kept\n' "$s" "$w"
                continue
            else
                rule="snapshot-active-closed ($w)"
            fi
        else
            rule="no-snapshot-row default=orchestrator"
        fi
        if [[ "$cur" == "$want" ]]; then
            printf 'session=%s rule=%s select=already-active %s\n' "$s" "$rule" "$want"
            continue
        fi
        if "$tm" select-window -t "${s}:${want}" >/dev/null 2>&1; then
            printf 'session=%s rule=%s select=%s\n' "$s" "$rule" "$want"
        else
            printf 'session=%s rule=%s select=%s FAILED (best-effort)\n' "$s" "$rule" "$want"
        fi
    done
    return 0
}

# CLI entrypoint — active only when executed directly, never when
# sourced. Lets shell-level callers (skill docs, ad-hoc ops) resolve an
# id without writing the awk: `wid=$(monitor/_tmux-window.sh id "$WIN")`.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _cmd="${1:-}"
    case "$_cmd" in
        id)       resolve_window_id "${2:-}" ;;
        index)    resolve_window_index "${2:-}" ;;
        key)      resolve_window_key "${2:-}" ;;
        validate) validate_window_name "${2:-}" ;;
        # `key` was dispatched but omitted from both usage strings, so the
        # one verb that accepts a `session:window` key was undiscoverable from
        # the CLI that implements it (your-org/nexus-code#944).
        *) printf 'usage: %s {id|index|key|validate} <window-name-or-session:window>\n' "$0" >&2; exit 64 ;;
    esac
fi
