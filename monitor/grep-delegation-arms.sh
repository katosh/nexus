#!/usr/bin/env bash
# monitor/grep-delegation-arms.sh — does this harness still split `grep` the way
# CLAUDE.md says it does? your-org/nexus-code#1234.
#
# WHAT THIS IS FOR. Claude Code's shell snapshot installs `grep` as a shell
# FUNCTION running ugrep embedded in the `claude` executable, with a leading
# `case` whose arms DELEGATE certain arguments to `command grep` instead. Two
# CLAUDE.md entries straddle that split and are correct only on their own side
# of it. The arm set lives in the harness build, not in this repo, so a version
# bump can move it and invalidate documented remedies with no diff anywhere a
# suite looks — which has already happened once (`#1186`).
#
# WHAT IT DOES *NOT* DO, deliberately. It does not pin the arm set. This repo
# cannot version somebody else's binary, and a suite asserting THIS host's arms
# would be green for this operator and red for every other one — a harness-build
# property wearing a repo invariant's clothes. The arm set is recorded for
# REVIEW; the ASSERTION is on the DEPENDENCY, evaluated by running the live arms
# as a shell `case` against a representative argument. "Does `---` still reach
# GNU?" has the same right answer on every host, and when it changes, the
# documentation has genuinely been invalidated there.
#
# COVERAGE BOUNDARY — read this before treating a 0 as safety:
#   * It sees the delegation ARMS. It cannot see a change in what the embedded
#     ugrep DOES with an argument it accepts: same arms, different behaviour, is
#     invisible here.
#   * It reads a SNAPSHOT FILE, not the running shell's function table. If the
#     harness stops writing snapshots, or writes them elsewhere, this reports
#     NOT-APPLICABLE — which is honest, and is not a check.
#   * The version in ARMS rows is a review record. An unreviewed bump is exit 4,
#     never exit 1, for the portability reason above. Making a bump red is
#     `skills/nexus.cc-update`'s job, at the gate, where a human is already
#     looking.
#
# Usage:
#   monitor/grep-delegation-arms.sh [--snapshot <file>] [--manifest <file>] [--quiet]
#   monitor/grep-delegation-arms.sh --print-arms [--snapshot <file>]
#
# Exit codes:
#   0  every documented dependency still holds, and the live arms match a
#      recorded version
#   1  a documented dependency is BROKEN — a CLAUDE.md entry is invalid on this
#      harness. The output names the entry.
#   2  usage
#   3  NOT APPLICABLE — no snapshot `grep` function on this host (a plain bash
#      login, CI, another harness). Not a failure and not a clearance.
#   4  UNREVIEWED — the dependencies hold, but the live arm set is not the one
#      recorded for this Claude Code version (or the version is unrecorded).
#      This is the bump signal.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MANIFEST="$_self_dir/grep-delegation-arms.manifest"
SNAPSHOT=""
QUIET=0
PRINT_ARMS=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --snapshot)   SNAPSHOT="${2-}"; shift 2 || { echo "--snapshot needs a path" >&2; exit 2; } ;;
        --manifest)   MANIFEST="${2-}"; shift 2 || { echo "--manifest needs a path" >&2; exit 2; } ;;
        --quiet)      QUIET=1; shift ;;
        --print-arms) PRINT_ARMS=1; shift ;;
        -h|--help)    sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
        *)            echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# --- locate a snapshot that defines the function ---------------------------
#
# There is no environment variable naming the active snapshot (checked: none of
# the CLAUDE_* variables carries it), and this script runs under bash where the
# zsh function is not in scope, so the file has to be found. Newest-first, and
# the chosen path is REPORTED — a discovered input that is not named is not
# checkable.
_find_snapshot() {
    local d
    for d in "${CLAUDE_CONFIG_DIR:-}/shell-snapshots" "$HOME/.claude/shell-snapshots"; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        # -print0 / read -d: a snapshot name is generated, but a path with a
        # space would otherwise silently select the wrong file.
        local newest="" f
        while IFS= read -r -d '' f; do
            grep -q '^function grep {' -- "$f" 2>/dev/null || continue
            if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
        done < <(find "$d" -maxdepth 1 -type f -name 'snapshot-*' -print0 2>/dev/null)
        [ -n "$newest" ] && { printf '%s' "$newest"; return 0; }
    done
    return 1
}

if [ -z "$SNAPSHOT" ]; then
    SNAPSHOT=$(_find_snapshot) || {
        say "grep-delegation-arms: NOT APPLICABLE — no shell snapshot defining a \`grep\` function."
        say "  Looked in: \${CLAUDE_CONFIG_DIR}/shell-snapshots and ~/.claude/shell-snapshots"
        say "  This host's bare \`grep\` is the system binary, so the CLAUDE.md entries'"
        say "  harness-specific caveats do not apply here. Not a clearance."
        exit 3
    }
fi
[ -r "$SNAPSHOT" ] || { err "grep-delegation-arms: cannot read snapshot: $SNAPSHOT"; exit 2; }
# An explicitly-supplied snapshot bypasses discovery, so the "no snapshot" arm
# above cannot speak for it. Say the same thing about the file we were handed.
if ! grep -q -e '^function grep {' -- "$SNAPSHOT" 2>/dev/null; then
    say "grep-delegation-arms: NOT APPLICABLE — $SNAPSHOT defines no \`grep\` function."
    say "  This host's bare \`grep\` is the system binary, so the CLAUDE.md entries'"
    say "  harness-specific caveats do not apply here. Not a clearance."
    exit 3
fi

# --- extract the arm set ---------------------------------------------------
#
# One awk program rather than a grep/sed pipeline: awk is a PROGRAM, so it
# cannot resolve to the very shell function under examination, and there is no
# BRE/ERE dialect question about the pattern (CLAUDE.md, GREP-BRE-DIALECT).
ARMS=$(awk '
    /^function grep \{/ { inf = 1 }
    inf && /case .*_cc_a.* in/ {
        line = $0
        sub(/.*[ \t]in[ \t]+/, "", line)     # drop up to and including `in`
        sub(/\).*$/, "", line)               # drop the `)` and everything after
        print line
        exit
    }
    inf && /^\}/ { exit }
' "$SNAPSHOT")

if [ -z "$ARMS" ]; then
    say "grep-delegation-arms: NOT APPLICABLE — $SNAPSHOT defines no \`grep\` delegation \`case\`."
    say "  The function exists but has no argument-delegation loop, so the split the"
    say "  CLAUDE.md entries describe is not present on this harness. Not a clearance."
    exit 3
fi

if [ "$PRINT_ARMS" -eq 1 ]; then printf '%s\n' "$ARMS"; exit 0; fi

# CAPTURE, THEN PARSE — no pipe. `claude --version | awk '{…; exit}'` is an
# EARLY-EXIT READER: awk closing the pipe SIGPIPEs the producer, so under
# pipefail the substitution's status can be 141 at the moment the value was
# obtained correctly. monitor/watcher/early-exit-readers.sh flags exactly this,
# and flagged this line (`awk-exit prod 1`) before it shipped.
_cc_raw=$(claude --version 2>/dev/null) || _cc_raw=''
CC_VERSION=${_cc_raw%% *}
[ -n "$CC_VERSION" ] || CC_VERSION="<unknown>"

say "grep-delegation-arms (your-org/nexus-code#1234)"
say "  snapshot   : $SNAPSHOT"
say "  cc version : $CC_VERSION"
say "  live arms  : $ARMS"

# --- evaluate the documented dependencies ----------------------------------
#
# The arms are RUN, as the harness runs them, rather than compared as text: a
# reworded but equivalent arm set must pass, and a genuinely moved boundary must
# fail. `eval` is the only way to use a runtime string as `case` patterns; the
# string comes from a file this operator's own harness wrote, which is the same
# trust boundary as the shell that sources it at every prompt.
_is_delegated() {   # <argument> -> 0 when the live arms would delegate it
    local _a="$1" _r=1
    eval "case \"\$_a\" in $ARMS) _r=0 ;; esac"
    return "$_r"
}

[ -r "$MANIFEST" ] || { err "grep-delegation-arms: cannot read manifest: $MANIFEST"; exit 2; }

broken=0
checked=0
recorded_arms=""
while IFS=$'\t' read -r kind a b c; do
    case "${kind:-}" in
        ARMS)
            [ "$a" = "$CC_VERSION" ] && recorded_arms="$b"
            ;;
        DELEGATES|REACHES)
            checked=$(( checked + 1 ))
            if _is_delegated "$a"; then live=DELEGATES; else live=REACHES; fi
            if [ "$live" != "$kind" ]; then
                broken=$(( broken + 1 ))
                err "grep-delegation-arms: BROKEN DEPENDENCY — CLAUDE.md block '$b'"
                err "  argument  : $a"
                err "  documented: $kind      (must $( [ "$kind" = DELEGATES ] && echo 'reach command grep' || echo 'reach the embedded ugrep' ))"
                err "  live      : $live"
                err "  consequence: $c"
            fi
            ;;
    esac
done < <(sed -e 's/[[:space:]]*$//' "$MANIFEST" | awk 'NF && $0 !~ /^#/')

# A dependency count of zero is not "all dependencies hold" — it is "the
# manifest declared none", which reads the same and means the opposite.
if [ "$checked" -eq 0 ]; then
    err "grep-delegation-arms: REFUSING — the manifest declares no DELEGATES/REACHES rows,"
    err "  so a green here would assert nothing. Add the dependency this entry is about."
    exit 2
fi

if [ "$broken" -gt 0 ]; then
    err "grep-delegation-arms: $broken of $checked documented dependencies BROKEN on this harness."
    err "  The named CLAUDE.md blocks describe a split this build no longer has."
    exit 1
fi
say "  dependencies: $checked checked, all hold"

if [ -z "$recorded_arms" ]; then
    say "  REVIEW: cc $CC_VERSION has no ARMS record in $(basename "$MANIFEST")."
    say "  Every documented dependency still holds, so nothing is broken — but the arm"
    say "  set for this build has not been reviewed. Add an ARMS row, and see"
    say "  skills/nexus.cc-update/GUIDE.md's collision analysis."
    exit 4
fi
if [ "$recorded_arms" != "$ARMS" ]; then
    say "  REVIEW: the live arms differ from the record for cc $CC_VERSION."
    say "    recorded: $recorded_arms"
    say "    live    : $ARMS"
    say "  Every documented dependency still holds, so nothing is broken — but the same"
    say "  version answering differently is worth a look before the record is updated."
    exit 4
fi
say "  arms match the record for cc $CC_VERSION"
exit 0
