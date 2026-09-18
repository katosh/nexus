#!/usr/bin/env bash
# _wait_id.sh — ONE shared shape floor for the (kind, id) pair that
# keys an async external wait. Sourced by `monitor/declare-wait.sh`
# and `monitor/declare-no-wait.sh`.
#
# WHY A SHARED FILE AND NOT TWO COPIES (your-org/nexus-code#1326):
# the declare side and the dismiss side must accept EXACTLY the same
# language. A floor on the dismiss side alone creates a state a
# worker can enter and cannot leave — it declares a wait, then
# cannot dismiss it — which is strictly worse than no floor at all,
# because the watcher's own guidance tells that worker to dismiss.
# Two hand-written lists is how that divergence arrives, so there is
# one list and both verbs source it.
#
# WHY A CHARACTER CLASS AND NOT A GRAMMAR. `#1326` proposed an id
# grammar per kind (`syn-<hex>`, `ar-<hex>`, numeric slurm) and a
# kind allowlist (`nohup`, `slurm`, `asyncrun`). Measured against the
# live population on this nexus — 237 entries across 1,883 heartbeat
# files, `jq -r '((.external_waits//[])+(.dismissed_waits//[]))[]'`
# over `monitor/.state/heartbeat/*.json`, 2026-09-02 — BOTH are wrong:
#
#   kinds present : asyncrun 121, slurm 63, nohup 35,
#                   slurm-srun-async 16, service 1
#   id shapes     : kind `slurm` carries BOTH `2219913` and
#                   `syn-02ce6257b730`; kind `service` carries
#                   `myviewer-8766`
#
# So the proposed kind allowlist would have refused 17 live entries,
# and the proposed per-kind id grammar would have refused the
# synthetic-id rows under `slurm` plus every `service` row. Worse,
# `declare-wait.sh` documents `kind` as deliberately open — "no enum
# so future wait shapes don't need a watcher change" — with a `ci`
# example. An enum here would contradict the documented contract of
# the verb next door.
#
# What IS safe to pin is the character class, because the hazard is
# not the vocabulary — it is a value that cannot have come from a
# launch: a display truncation (`syn-` + U+2026, reachable BY
# CONSTRUCTION from the 80-char `orphan-async-state.tsv` display cap,
# `#1101`), an English sentence, a path-traversal string, a
# command-substitution string, an option-shaped string. All are
# rejected below; all 237 live entries and every documented example
# pass.
#
# WHAT THIS FLOOR DELIBERATELY DOES NOT CATCH: a TRUNCATED-BUT-ASCII
# id such as a bare `syn-`. It is well-formed and no character class
# can know it is short. That case is caught by the other half of
# `#1326`'s fix — the callers report, in the exit status, whether the
# operation matched anything — and the split is stated here so a
# reader does not mistake this file for the whole defence.

# Guard against double-sourcing.
[[ -n "${_WAIT_ID_SH_LOADED:-}" ]] && return 0
_WAIT_ID_SH_LOADED=1

# A `kind` is a short free-form class name. Open by design (no enum);
# constrained only to a leading alphanumeric and a conservative body.
_WAIT_KIND_RE='^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'

# An `id` is a handle a launcher emitted. Printable ASCII, no
# whitespace, no shell metacharacters, leading alphanumeric so an
# option-shaped or dot-shaped value cannot slip in. `/` `:` `@` `+`
# `=` `.` `_` `-` are permitted because real ids carry them (a CI
# run path, a `host:port`, a Slurm array `12345_4`).
_WAIT_ID_RE='^[A-Za-z0-9][A-Za-z0-9_.:@+/=-]{0,127}$'

# _wait_id_why_bad <value> — echo a short reason the value is not a
# usable id/kind component, or nothing if the character content is
# fine. Ordered most-specific first so the message names the actual
# cause rather than a generic "bad characters".
_wait_id_why_bad() {
    local v="$1"
    # C locale so `[:print:]` means ASCII printable: a UTF-8 `…` is three
    # bytes >= 0x80 and is therefore NOT print here, which is the whole
    # point. Scoped `local` so the caller's locale is untouched.
    local LC_ALL=C
    if [[ -z "$v" ]]; then
        printf 'empty'
    elif [[ "$v" == *[![:print:]]* ]]; then
        printf 'contains a non-ASCII or control character'
    elif [[ "$v" == *[[:space:]]* ]]; then
        printf 'contains whitespace'
    elif [[ "$v" == -* ]]; then
        printf 'begins with "-" (option-shaped)'
    elif [[ "$v" == *".."* ]]; then
        printf 'contains ".." (path-traversal shaped)'
    else
        printf ''
    fi
}

# wait_id_check <kind> <id> — validate both components. On failure,
# print a diagnostic naming WHICH component and WHY, plus the one
# recovery step that actually works, and return 2 (the usage class
# both callers already use). On success return 0 and print nothing.
#
# `$_wait_id_prog` lets the caller put its own name in the message.
wait_id_check() {
    local kind="$1" id="$2"
    local prog="${_wait_id_prog:-${0##*/}}"
    local why

    why=$(_wait_id_why_bad "$kind")
    if [[ -n "$why" ]] || ! [[ "$kind" =~ $_WAIT_KIND_RE ]]; then
        [[ -n "$why" ]] || why='does not match '"$_WAIT_KIND_RE"
        printf '%s: REFUSED — kind %s.\n' "$prog" "$why" >&2
        printf '  kind was: [%s]\n' "$kind" >&2
        printf '  A kind is a short class name such as slurm, asyncrun, nohup, ci.\n' >&2
        return 2
    fi

    why=$(_wait_id_why_bad "$id")
    if [[ -n "$why" ]] || ! [[ "$id" =~ $_WAIT_ID_RE ]]; then
        [[ -n "$why" ]] || why='does not match '"$_WAIT_ID_RE"
        printf '%s: REFUSED — id %s.\n' "$prog" "$why" >&2
        printf '  id was: [%s]\n' "$id" >&2
        # U+2026 built with printf, NOT written as "\xe2\x80\xa6": bash does
        # not expand hex escapes inside double quotes, so the literal form
        # would compare against the 12-character string `\xe2\x80\xa6` and
        # never match a real ellipsis. It would also be invisible — the
        # generic branch below is a correct message, so the dead arm would
        # cost only the SPECIFIC guidance, silently.
        if [[ "$id" == *"$(printf '\xe2\x80\xa6')"* ]]; then
            printf '  That "…" is a DISPLAY TRUNCATION, not part of any id. The\n' >&2
            printf '  `waits=` column of monitor/.state/orphan-async-state.tsv is\n' >&2
            printf '  capped at 80 characters (your-org/nexus-code#1101); the row is a\n' >&2
            printf '  display string, not a list. Get the real ids from the\n' >&2
            printf '  authoritative record:  ng declare-wait --list\n' >&2
        else
            printf '  An id is the handle the launcher emitted — a Slurm job id, an\n' >&2
            printf '  async-run token, a `syn-<hex>` synthetic id. Read the\n' >&2
            printf '  authoritative record:  ng declare-wait --list\n' >&2
        fi
        return 2
    fi
    return 0
}
