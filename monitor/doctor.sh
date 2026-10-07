#!/usr/bin/env bash
# doctor.sh — `ng doctor`: a READ-ONLY setup check for a new or restarted
# nexus (your-org/nexus-code#1722, first version).
#
# WHY. Investigating another operator's restart errors turned up six setup gaps,
# each visible somewhere in .state/ or watcher.log, none stopping the stack from
# booting, so the operator saw only downstream symptoms. This puts the checks
# in one place, one row each.
#
# Every row is PASS, WARN, FAIL or UNKNOWN. UNKNOWN means the probe could not
# run, and it is NEVER folded into PASS: a check that could not look has not
# found the setup healthy.
#
# Checks (v1):
#   cc        the project-local Claude Code install vs the version this tree
#             expects (the operator-local pin, else package.json's floor).
#             Older than expected is WARN (pane-state and paste logic are
#             calibrated on newer renderers); no install is FAIL.
#   gh        a capable `gh` on PATH, by monitor/gh-capable.sh's floor
#             (NEXUS_GH_MIN_VERSION). Below the floor is FAIL: the #755 class
#             (zero-line job logs at rc 0).
#   config    `config/load.sh --validate`: placeholders (exit 4) are FAIL.
#   config-mode  config/nexus.yml readable by group/other is WARN (it holds the
#             bot's app credentials' location and the operator identity).
#   transcripts  $CLAUDE_CONFIG_DIR/projects as a REAL directory while
#             ~/.claude/projects is not the same directory is WARN: the
#             sandbox overlay did not symlink it (#1720; resume handles both
#             roots since, but other tools may not).
#
# Usage: doctor.sh [--quiet]     --quiet prints only the non-PASS rows
#
# Exit codes:
#   0  no FAIL (WARN and UNKNOWN rows may be present — read them)
#   1  at least one FAIL
#   2  bad usage
#  64  a value-taking flag given LAST with no value (the argument-loop
#      backstop every tool here shares, your-org/nexus-code#924)
#
# Read-only by construction: the gh resolver runs with its cache disabled, and
# nothing here writes under the tree, the state dir or $HOME.

set -u
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
quiet=0
# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924): a value-taking flag
# given LAST must not spin. Full rationale: monitor/ng.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}
_argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --quiet) quiet=1; shift ;;
        -h|--help) sed -n '/^# Usage:/,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
        *) echo "doctor: unknown argument: ${1:0:60}" >&2; exit 2 ;;
    esac
done
root="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"
n_fail=0

row() {   # <verdict> <check> <detail>
    [[ "$1" == FAIL ]] && n_fail=$((n_fail + 1))
    (( quiet )) && [[ "$1" == PASS ]] && return 0
    printf '%-7s %-12s %s\n' "$1" "$2" "$3"
}
ver_lt() {   # <a> <b> -> 0 when a < b (version order)
    [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]
}

# --- cc ----------------------------------------------------------------------
check_cc() {
    local pkg="@anthropic-ai/claude-code" pj="$root/package.json" want src have
    local inst="$root/node_modules/@anthropic-ai/claude-code/package.json"
    if ! . "$_self_dir/_cc-version.sh" 2>/dev/null; then
        row UNKNOWN cc "monitor/_cc-version.sh could not be loaded"; return
    fi
    if ! want=$(cc_version_effective "$pj" "$pkg" "$root" 2>/dev/null) || [[ -z "$want" ]]; then
        row UNKNOWN cc "no expected version: neither a local pin nor a floor in $pj"; return
    fi
    src=$(cc_version_effective_source "$pj" "$pkg" "$root" 2>/dev/null)
    if [[ ! -f "$inst" ]]; then
        row FAIL cc "no project-local install ($inst missing); expected $want ($src). Spawn surfaces resolve claude from node_modules/.bin."
        return
    fi
    have=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$inst" | head -1)
    if [[ ! "$have" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        row UNKNOWN cc "installed version unreadable from $inst"; return
    fi
    if [[ "$have" == "$want" ]]; then
        row PASS cc "installed $have = expected ($src)"
    elif ver_lt "$have" "$want"; then
        row WARN cc "installed $have is OLDER than expected $want ($src); pane-state/paste logic is calibrated on newer renderers"
    else
        row WARN cc "installed $have is NEWER than expected $want ($src); not vetted by the cc-update gate"
    fi
}

# --- gh ----------------------------------------------------------------------
check_gh() {
    local out cand st ver
    if ! . "$_self_dir/gh-capable.sh" 2>/dev/null || ! declare -F _ghc_resolve >/dev/null; then
        row UNKNOWN gh "monitor/gh-capable.sh could not be loaded"; return
    fi
    out=$(NEXUS_GH_CAPABLE_NOCACHE=1 _ghc_resolve "" "$PATH" 2>/dev/null)
    # `cut -f`, never `read` with IFS=tab: tab is IFS whitespace, so `read`
    # collapses the EMPTY first field of the `none` row and shifts every field.
    cand=$(printf '%s\n' "$out" | head -1 | cut -f1)
    st=$(printf '%s\n' "$out" | head -1 | cut -f2)
    ver=$(printf '%s\n' "$out" | head -1 | cut -f3)
    case "$st" in
        ok)         row PASS gh "$cand $ver (floor $(_ghc_floor))" ;;
        unverified) row WARN gh "$cand: version could not be established (floor $(_ghc_floor))" ;;
        degraded)   row FAIL gh "only below-floor clients on PATH: $cand ${ver:-?} < $(_ghc_floor) — zero-line job logs at rc 0 (#755)" ;;
        none)       row FAIL gh "no gh on PATH" ;;
        *)          row UNKNOWN gh "resolver gave no verdict" ;;
    esac
}

# --- config ------------------------------------------------------------------
check_config() {
    local load="$root/config/load.sh" rc out
    [[ -x "$load" ]] || { row UNKNOWN config "$load missing or not executable"; return; }
    out=$("$load" --validate 2>&1); rc=$?
    case "$rc" in
        0) row PASS config "config/load.sh --validate" ;;
        4) row FAIL config "placeholders in the config — the watcher refuses to start: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)" ;;
        *) row UNKNOWN config "config/load.sh --validate rc $rc (inconclusive): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)" ;;
    esac
    local yml="$root/config/nexus.yml" mode
    if [[ -f "$yml" ]]; then
        mode=$(stat -c '%a' "$yml" 2>/dev/null)
        if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then row UNKNOWN config-mode "cannot stat $yml"
        elif (( (8#$mode & 8#077) != 0 )); then row WARN config-mode "$yml is mode $mode; 600 keeps it private"
        else row PASS config-mode "$yml mode $mode"; fi
    else
        row UNKNOWN config-mode "no $yml (load.sh falls back to the example)"
    fi
}

# --- transcripts -------------------------------------------------------------
check_transcripts() {
    local cfg="${CLAUDE_CONFIG_DIR:-}" a b
    if [[ -z "$cfg" ]]; then row PASS transcripts "CLAUDE_CONFIG_DIR unset: one root (~/.claude/projects)"; return; fi
    a="$cfg/projects"; b="${HOME:-}/.claude/projects"
    if [[ ! -e "$a" ]]; then row PASS transcripts "$a absent (nothing written there yet)"; return; fi
    if [[ -L "$a" ]] || { [[ -d "$b" ]] && [[ "$(cd "$a" && pwd -P)" == "$(cd "$b" && pwd -P)" ]]; }; then
        row PASS transcripts "$a and $b are one directory"; return
    fi
    row WARN transcripts "$a is a REAL directory separate from $b (the sandbox overlay did not symlink it, #1720). Resume reads both; to merge, create $b OUTSIDE the sandbox (back up first)."
}

check_cc
check_gh
check_config
check_transcripts
(( n_fail == 0 )) || exit 1
exit 0
