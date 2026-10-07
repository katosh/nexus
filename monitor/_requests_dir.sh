#!/usr/bin/env bash
# _requests_dir.sh — where the request inbox lives: the ONE resolver every
# reader and writer of `<inbox>/*.{new,claimed,…}.md` calls
# (your-org/nexus-code#1723).
#
# WHY. The inbox used to be `$STATE_DIR/requests`, composed independently in
# seven places. During a read-only incident on the project tree every write
# under `monitor/.state` fails with EROFS, and the remote channel's only
# RO-fatal dependency is this inbox. The live mitigation was a hand-made
# symlink `monitor/.state/requests -> ~/.claude/nexus-requests`: invisible
# state that a fresh clone, or anything recreating `.state`, silently reverts.
# A config key replaces it, and one resolver means the inbox cannot split in
# two (some readers following the key, others still composing the old path).
#
# PRECEDENCE
#   1. NEXUS_REQUESTS_DIR (env) — explicit, always wins.
#   2. config key `monitor.requests.dir` — honoured ONLY for the state dir the
#      config describes (`<nexus.root>/monitor/.state`). A test fixture or a
#      secondary clone that points NEXUS_STATE_DIR somewhere else therefore
#      keeps its own `<state>/requests` and can never be redirected into the
#      operator's LIVE inbox by their config (the your-org/nexus-code#833
#      class: a fixture must never read or write live state).
#   3. `<state_dir>/requests` — the default, unchanged.
# A configured value must be absolute (`~/` is expanded); anything else is
# REFUSED (rc 2, stderr), never silently replaced by the default.
#
# INVARIANT KEPT. Every `mv` in the channel protocol stays inside this one
# directory (publish temp, transitions, claims), so moving the inbox to
# another filesystem keeps each rename atomic. The watcher's cooldown TSV
# (`requests-emit-state.tsv`) deliberately stays in `.state`: its loss only
# re-emits, it never loses a request.
#
# Usage (sourced):
#   nexus_requests_dir <state_dir>          -> prints the inbox path; rc 2 refused
#   nexus_requests_dir_source <state_dir>   -> env | config | default
#   nexus_requests_dir_check <dir> <source> -> rc 3 + stderr when a READER would
#       otherwise see a silent zero: a configured (env/config) dir that does not
#       exist, or a symlink that does not resolve to a directory (the hand-made
#       mitigation left dangling). A missing DEFAULT dir is a fresh nexus with no
#       requests yet, and stays rc 0.

[[ -n "${_NEXUS_REQUESTS_DIR_LIB:-}" ]] && return 0
_NEXUS_REQUESTS_DIR_LIB=1
_nrd_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_nrd_cfg() {   # <dotted.key> -> value or empty
    local load="${NEXUS_ROOT:+$NEXUS_ROOT/config/load.sh}"
    [[ -x "$load" ]] || load="$_nrd_self_dir/../config/load.sh"
    [[ -x "$load" ]] || return 0
    "$load" "$1" 2>/dev/null || true
}

_nrd_canon() {   # <path> -> physical path when it exists, else the path as given
    local p="$1"
    if [[ -d "$p" ]]; then (cd "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"
    else printf '%s' "${p%/}"; fi
}

# _nrd_resolve <state_dir> -> "<source>\t<dir>"; rc 2 on a refused value.
_nrd_resolve() {
    local sd="${1:?state_dir required}" v root src
    if [[ -n "${NEXUS_REQUESTS_DIR:-}" ]]; then
        v="$NEXUS_REQUESTS_DIR"; src=env
    else
        v=$(_nrd_cfg monitor.requests.dir)
        src=config
        if [[ -n "$v" ]]; then
            root=$(_nrd_cfg nexus.root)
            if [[ -z "$root" || "$(_nrd_canon "$sd")" != "$(_nrd_canon "$root/monitor/.state")" ]]; then
                v=""
            fi
        fi
    fi
    if [[ -z "$v" ]]; then
        printf 'default\t%s/requests\n' "$sd"; return 0
    fi
    [[ "$v" == "~/"* && -n "${HOME:-}" ]] && v="$HOME/${v#\~/}"
    if [[ "$v" != /* || "$v" =~ ^/+$ ]]; then
        printf 'request inbox: REFUSED %s value %q — it must be an absolute directory (your-org/nexus-code#1723)\n' \
            "$( [[ $src == env ]] && echo NEXUS_REQUESTS_DIR || echo monitor.requests.dir)" "$v" >&2
        return 2
    fi
    printf '%s\t%s\n' "$src" "${v%/}"
}

nexus_requests_dir() {
    local r; r=$(_nrd_resolve "$@") || return $?
    printf '%s\n' "${r#*$'\t'}"
}

nexus_requests_dir_source() {
    local r; r=$(_nrd_resolve "$@") || return $?
    printf '%s\n' "${r%%$'\t'*}"
}

nexus_requests_dir_check() {
    local dir="${1:?dir required}" src="${2:-default}"
    if [[ -L "$dir" && ! -d "$dir" ]]; then
        printf 'request inbox: %s is a symlink that does not resolve to a directory — refusing to report an empty inbox (your-org/nexus-code#1723)\n' "$dir" >&2
        return 3
    fi
    if [[ "$src" != default && ! -d "$dir" ]]; then
        printf 'request inbox: the CONFIGURED inbox %s (from %s) does not exist — refusing to report an empty inbox; create it (mode 0700) or fix the setting (your-org/nexus-code#1723)\n' \
            "$dir" "$( [[ $src == env ]] && echo NEXUS_REQUESTS_DIR || echo monitor.requests.dir)" >&2
        return 3
    fi
    return 0
}
