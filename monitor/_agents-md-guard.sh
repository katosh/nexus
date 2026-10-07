#!/usr/bin/env bash
# monitor/_agents-md-guard.sh — spawn-time scan for AGENTS.md files a worker's
# harness would load as PROJECT INSTRUCTIONS (your-org/nexus-code#1671).
#
# WHY. A repo cloned under work/ that ships an AGENTS.md hands its text to the
# agent started there as instructions, not data — a prompt-injection surface in
# exactly the directories where workers run. This file answers, at spawn time,
# "which AGENTS.md files between the workdir and the nexus root would this
# harness load?", so spawn-worker.sh can say so loudly and tell the worker the
# content is untrusted DATA.
#
# MEASURED SEMANTICS, Claude Code 2.1.284 (the pinned build), against the
# cc-harness mock backend with unique-token AGENTS.md files; the evidence is on
# your-org/nexus-code#1671. The loader is the built-in plugin `agents-md@builtin`
# (GrowthBook gate `tengu_agents_md_mod`, client default ON):
#   - default mode `claude-md-or-agents-md`: `AGENTS.md` and `.claude/AGENTS.md`
#     in the cwd and EVERY ancestor (past the git root, up to /) are loaded —
#     unless ANY `CLAUDE.md` / `.claude/CLAUDE.md` / `CLAUDE.local.md` sits in
#     the cwd or an ancestor, which suppresses the whole fallback. A CLAUDE.md
#     BELOW the cwd does NOT suppress. With the fallback active, an AGENTS.md
#     BELOW the cwd is loaded when a file beside it is Read.
#   - IN THE DEFAULT NEXUS LAYOUT NOTHING IS LOADED: the nexus root's own
#     CLAUDE.md is an ancestor of every work/<proj>, so the fallback is
#     suppressed (measured: a git repo and a plain dir under work/, and the
#     nested on-Read path, all load no token). The exposure is a workdir
#     OUTSIDE the nexus root, or a mode switched away from the default.
#   - the mode is `pluginConfigs["agents-md@builtin"].options.instructionFiles`
#     (claude-md | claude-md-or-agents-md | claude-md-and-agents-md |
#     managed-only), read from user, --settings and managed settings — NOT from
#     project settings. `enabledPlugins["agents-md@builtin"]: false` turns the
#     plugin off. Both measured; an unknown value reads as the default, as the
#     binary does.
# Codex (NOT measured here — no codex binary on the measuring host; this is
# its documented behaviour): `AGENTS.override.md` / `AGENTS.md` in every
# directory from the project root (nearest ancestor holding `.git`) down to the
# cwd. A CLAUDE.md does not suppress it, so for a Codex worker the exposure is
# real in the default layout.
#
# SCOPE. The directories scanned are the workdir and its ancestors up to, NOT
# including, the nexus root (all the way to / when the workdir is outside it).
# The nexus root and above are the operator's own tree, not a foreign clone,
# and for Claude the root CLAUDE.md suppresses them anyway.
#
# BOUNDARY, stated so a zero is not over-read: managed (policy) settings are
# not consulted for the mode; files BELOW the workdir are not enumerated (a
# subtree walk at spawn time is unbounded) — the warning text says they load on
# Read when the fallback is active.
#
# API
#   amg_scan <workdir> <nexus_root> <harness> [settings_file]
#     harness: claude-code | codex. settings_file: the --settings file the
#     worker is launched with (flag settings; they override user settings).
#     stdout, one TAB-separated record per file found:
#         loaded<TAB><path><TAB><reason>
#         suppressed<TAB><path><TAB><reason>
#     rc 0 = scanned (zero records means none found); rc 2 = could not scan
#     (workdir not a directory, unknown harness) — NOT "none found".
#   amg_claude_mode [settings_file]   → the effective instructionFiles mode,
#     or `plugin-disabled`.

_AMG_CLAUDE_NAMES=(AGENTS.md .claude/AGENTS.md)
_AMG_CODEX_NAMES=(AGENTS.override.md AGENTS.md)
_AMG_CLAUDE_MD_NAMES=(CLAUDE.md .claude/CLAUDE.md CLAUDE.local.md)
_AMG_DEFAULT_MODE=claude-md-or-agents-md

_amg_real() { ( CDPATH= cd -- "$1" 2>/dev/null && pwd -P ); }

# The user-settings file Claude Code reads: $CLAUDE_CONFIG_DIR/settings.json,
# else ~/.claude/settings.json.
_amg_user_settings() {
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        printf '%s/settings.json\n' "$CLAUDE_CONFIG_DIR"
    else
        printf '%s/.claude/settings.json\n' "${HOME:-/nonexistent}"
    fi
}

amg_claude_mode() {
    local flag_settings="${1:-}" mode="$_AMG_DEFAULT_MODE" f v disabled=0 havejq=1
    command -v jq >/dev/null 2>&1 || havejq=0
    # Precedence as the binary merges it: user, then --settings (later wins).
    # A settings file that EXISTS but cannot be read here (no jq, or JSON jq
    # rejects) could say anything, including `claude-md-and-agents-md`, so it
    # yields `unreadable`, which amg_scan treats as LOADED. That is the warn
    # direction. Deferring to the default would silently report `suppressed`
    # for a file the binary loads.
    for f in "$(_amg_user_settings)" "$flag_settings"; do
        [ -n "$f" ] && [ -e "$f" ] || continue
        if [ "$havejq" -eq 0 ] || [ ! -r "$f" ] || ! jq -e . "$f" >/dev/null 2>&1; then
            printf 'unreadable\n'; return 0
        fi
        v=$(jq -r '.pluginConfigs["agents-md@builtin"].options.instructionFiles // empty' "$f" 2>/dev/null) || v=""
        [ -n "$v" ] && mode="$v"
        # NOT `// empty`: jq's `//` treats `false` as absent, which would
        # erase exactly the value this line exists to read.
        v=$(jq -r '.enabledPlugins["agents-md@builtin"] | if . == null then empty else tostring end' "$f" 2>/dev/null) || v=""
        case "$v" in false) disabled=1 ;; true) disabled=0 ;; esac
    done
    if [ "$disabled" -eq 1 ]; then printf 'plugin-disabled\n'; return 0; fi
    case "$mode" in
        claude-md|claude-md-or-agents-md|claude-md-and-agents-md|managed-only) ;;
        *) mode="$_AMG_DEFAULT_MODE" ;;   # the binary's own fallback for an unknown value
    esac
    printf '%s\n' "$mode"
}

# First CLAUDE.md-family file in <dir> or any ancestor up to /, or nothing.
_amg_claude_md_on_walk() {
    local d="$1" n
    while :; do
        for n in "${_AMG_CLAUDE_MD_NAMES[@]}"; do
            [ -f "$d/$n" ] && { printf '%s\n' "$d/$n"; return 0; }
        done
        [ "$d" = / ] && return 1
        d=$(dirname -- "$d")
    done
}

# Nearest ancestor-or-self holding `.git` (dir or file), or nothing.
_amg_git_root() {
    local d="$1"
    while :; do
        [ -e "$d/.git" ] && { printf '%s\n' "$d"; return 0; }
        [ "$d" = / ] && return 1
        d=$(dirname -- "$d")
    done
}

# Directories scanned, workdir first: up to NOT including nexus_root when the
# workdir is below it; to / inclusive otherwise; none when workdir IS the root.
_amg_scan_dirs() {
    local wd="$1" root="$2" d="$1"
    [ "$wd" = "$root" ] && return 0
    case "$wd/" in
        "$root"/*)
            while [ "$d" != "$root" ]; do printf '%s\n' "$d"; d=$(dirname -- "$d"); done ;;
        *)
            while :; do printf '%s\n' "$d"; [ "$d" = / ] && break; d=$(dirname -- "$d"); done ;;
    esac
}

amg_scan() {
    local wd root harness="${3:-}" settings="${4:-}" d n f
    wd=$(_amg_real "${1:-}") || { echo "amg_scan: workdir ${1:-<empty>} is not a directory" >&2; return 2; }
    [ -n "$wd" ] || { echo "amg_scan: workdir ${1:-<empty>} is not a directory" >&2; return 2; }
    root=$(_amg_real "${2:-}") || root="${2:-}"
    [ -n "$root" ] || { echo "amg_scan: nexus root is empty" >&2; return 2; }
    local -a names=()
    case "$harness" in
        claude-code|claude|'') harness=claude-code; names=("${_AMG_CLAUDE_NAMES[@]}") ;;
        codex)                 names=("${_AMG_CODEX_NAMES[@]}") ;;
        *) echo "amg_scan: unknown harness '$harness'" >&2; return 2 ;;
    esac

    local -a found=()
    while IFS= read -r d; do
        for n in "${names[@]}"; do
            [ -f "$d/$n" ] && found+=("$d/$n")
        done
    done < <(_amg_scan_dirs "$wd" "$root")
    [ "${#found[@]}" -gt 0 ] || return 0

    local verdict reason
    if [ "$harness" = codex ]; then
        local groot
        groot=$(_amg_git_root "$wd") || groot="$wd"
        for f in "${found[@]}"; do
            case "$(dirname -- "$f")/" in
                "$groot"/*) verdict=loaded; reason="codex reads AGENTS files from the project root $groot down to the workdir" ;;
                *)          verdict=suppressed; reason="above the codex project root $groot" ;;
            esac
            printf '%s\t%s\t%s\n' "$verdict" "$f" "$reason"
        done
        return 0
    fi

    local mode cm
    mode=$(amg_claude_mode "$settings")
    case "$mode" in
        claude-md|managed-only|plugin-disabled)
            verdict=suppressed; reason="agents-md mode $mode" ;;
        claude-md-and-agents-md)
            verdict=loaded; reason="agents-md mode $mode loads AGENTS.md beside CLAUDE.md" ;;
        unreadable)
            verdict=loaded; reason="a settings file could not be read (jq absent or invalid JSON), so the agents-md mode is unknown; assuming LOADED" ;;
        *)
            if cm=$(_amg_claude_md_on_walk "$wd"); then
                verdict=suppressed; reason="fallback suppressed by $cm"
            else
                verdict=loaded; reason="no CLAUDE.md in the workdir or any ancestor, so AGENTS.md is the fallback; AGENTS.md below the workdir also loads when a file beside it is Read"
            fi ;;
    esac
    for f in "${found[@]}"; do
        printf '%s\t%s\t%s\n' "$verdict" "$f" "$reason"
    done
    return 0
}
