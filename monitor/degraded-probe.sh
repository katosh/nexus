#!/usr/bin/env bash
# degraded-probe.sh — can the nexus still WRITE where it keeps its state?
# (your-org/nexus-code#1724, the `probe` leg of `ng degraded`.)
#
# WHY A SEPARATE PROBE. The project tree's rw bind has detached from the filer
# several times (your-nexus#386: five read-only windows in two days, the last
# ~18 h; incident 10 on 2026-10-05). Every write under `monitor/.state` then
# fails with EROFS, and each tool met it alone: `ng send` could not write its
# ledger, request replies could not be filed, `ng longjob add` could not write
# its spec, and `ng wrap-up` reported success for writes that had failed
# (#1719). Nothing answered the one question underneath all of them — is the
# tree writable, and if not, HOW is it failing — so each agent rediscovered it
# from a different symptom. This answers it once, per surface, with the errno.
#
# `write-probe.sh` is NOT this tool and must not be reached for here: it probes
# a DELIVERABLE outside the tree, prints a sandbox-GRANT recipe on failure
# (wrong for a detached mount, whose path IS granted), cannot tell EROFS from
# ENOSPC, and is unbounded — a create on a stale NFS mount blocks it forever.
#
# WHAT IT DOES. For each surface it creates and removes one uniquely named temp
# file INSIDE that surface's directory, in a child bounded by `timeout`, and
# classifies the outcome from the child's own stderr:
#
#   OK       created and removed
#   EROFS    "Read-only file system"
#   ENOSPC   "No space left on device" / "Disk quota exceeded"
#   EACCES   "Permission denied" / "Operation not permitted"
#   HANG     the create did not return within the bound (a stale mount)
#   MISSING  the surface's directory does not exist (NOT created here: a
#            probe that mkdir'd would answer about a directory it just made)
#   ERROR    anything else; the child's stderr is printed as the detail
#
# THE BOUND HAS ONE KNOWN LIMIT: `timeout -k` delivers SIGKILL, and a process
# in uninterruptible sleep on a dead NFS server does not die until the server
# answers, so `timeout` itself can wait. That is a property of the kernel, not
# something a shell can bound; it is why HANG exists as a verdict at all.
#
# It never writes anywhere but inside an EXISTING surface directory, and it
# refuses `/`, an empty path and any relative path outright, so it cannot be
# pointed at the sandbox root by an unset variable.
#
# Usage:
#   degraded-probe.sh [--timeout S] [--surface NAME=ABS_DIR]...
#
# With no --surface, it probes the nexus's registered surfaces (below),
# resolved from NEXUS_STATE_DIR / NEXUS_ROOT the way monitor/ng resolves them.
# Output: one line per surface,
#   surface=<name> verdict=<VERDICT> path=<dir> [detail=<text>]
# then a `summary:` line.
#
# Exit codes:
#   0  every surface is OK
#   1  at least one surface is NOT OK (EROFS / ENOSPC / EACCES / HANG /
#      MISSING / ERROR) — read the rows; the verdict names the failure
#   2  bad usage, or a refused path (empty, relative, or `/`)
#   3  could not probe at all: no surfaces resolved, or no `timeout` binary
#      (an unbounded probe of a possibly-hung mount is refused, not run)
#  64  a value-taking flag given LAST with no value (the argument-loop
#      backstop every tool here shares, your-org/nexus-code#924)

set -u

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
    sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924): a value-taking flag
# given LAST must not spin. Full rationale: monitor/ng.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

# An argument echoed into a diagnostic is EXCERPTED, never raw: a pasted
# multi-line token must not swamp the refusal (your-org/nexus-code#906; the
# same helper monitor/send.sh carries, which test-ng-flag-order.sh's D2 ratchet
# recognises).
_arg_excerpt() {   # <token> → first line, excerpted, dropped-line count named
    local v="${1-}" first nl bytes
    first="${v%%$'\n'*}"
    # BYTE-capped, trimmed on a CHARACTER boundary (your-org/nexus-code#906).
    # Three axes, and only the third is the property:
    #   #858 C capped LINES   → a 900-char SINGLE-line token walked through
    #   the first #906 cut capped CHARACTERS → still a proxy; 72 multi-byte
    #                                          characters is 219 bytes
    #   this caps BYTES       → what "do not swamp the diagnostic" means
    # Character-boundary trimming is why the char cap comes first: slicing at
    # a byte offset would split a multi-byte character into mojibake, so the
    # loop removes whole characters until the byte budget is met.
    (( ${#first} > 72 )) && first="${first:0:72}"
    while (( ${#first} > 1 )); do
        bytes=$(LC_ALL=C printf '%s' "$first" | wc -c)
        (( bytes <= 96 )) && break
        first="${first:0:$(( ${#first} - 4 ))}"
    done
    # Ellipsis iff the excerpt is shorter than the line it came from. One
    # condition, because the two-clause version this replaced could in
    # principle append twice and only testing showed it did not.
    [[ "$first" != "${v%%$'\n'*}" ]] && first="${first}…"
    nl="${v//[^$'\n']/}"
    if (( ${#nl} > 0 )); then
        printf "'%s' (+%d more line(s))" "$first" "${#nl}"
    else
        printf "'%s'" "$first"
    fi
}


bound=10
declare -a names=() dirs=()
_argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --timeout)
            (( $# >= 2 )) || _argloop_stuck "$1"
            [[ "$2" =~ ^[1-9][0-9]*$ ]] || { printf 'degraded-probe: --timeout wants a positive integer, got %s\n' "$(_arg_excerpt "$2")" >&2; exit 2; }
            bound=$2; shift 2 ;;
        --surface)
            (( $# >= 2 )) || _argloop_stuck "$1"
            [[ "$2" == *=* ]] || { printf 'degraded-probe: --surface wants NAME=ABS_DIR, got %s\n' "$(_arg_excerpt "$2")" >&2; exit 2; }
            names+=("${2%%=*}"); dirs+=("${2#*=}"); shift 2 ;;
        -h|--help) usage ;;
        *) printf 'degraded-probe: unknown argument %s\n' "$(_arg_excerpt "$1")" >&2; usage ;;
    esac
done

# THE REGISTERED SURFACES — the writes the RO incidents actually broke. A new
# writer that matters during an incident belongs in this list. Resolved the way
# monitor/ng resolves STATE_DIR: NEXUS_STATE_DIR wins, else <root>/monitor/.state.
if (( ${#names[@]} == 0 )); then
    root="${NEXUS_ROOT:-$(cd "$_self_dir/.." && pwd)}"
    state="${NEXUS_STATE_DIR:-$root/monitor/.state}"
    # The inbox may be configured OUTSIDE the tree (your-org/nexus-code#1723):
    # probe where it really is, via the one shared resolver.
    # A refused or unresolvable location is reported as an ERROR row below,
    # never silently replaced by the default (which would probe a directory
    # nothing writes to).
    reqdir=$( . "$_self_dir/_requests_dir.sh" \
              && NEXUS_ROOT="$root" nexus_requests_dir "$state" ) || reqdir="-"
    names=(state requests skeptic longjob reports work)
    dirs=("$state" "$reqdir" "$state/skeptic/pending" "$state/longjob" \
          "$root/reports" "$root/work")
fi

command -v timeout >/dev/null 2>&1 || {
    printf 'degraded-probe: no `timeout` on PATH — refusing to probe unbounded (a hung mount would block this forever)\n' >&2
    exit 3
}

_classify() {   # <child-rc> <child-stderr>
    local rc="$1" err="$2"
    case "$rc" in
        0) printf 'OK'; return ;;
        124|137) printf 'HANG'; return ;;
    esac
    case "$err" in
        *"Read-only file system"*)                       printf 'EROFS' ;;
        *"No space left on device"*|*"quota exceeded"*)  printf 'ENOSPC' ;;
        *"Permission denied"*|*"Operation not permitted"*) printf 'EACCES' ;;
        *)                                               printf 'ERROR' ;;
    esac
}

n_bad=0 i=0
for (( i = 0; i < ${#names[@]}; i++ )); do
    name="${names[$i]}" dir="${dirs[$i]}"
    if [[ "$name" == requests && "$dir" == - ]]; then
        printf 'surface=requests verdict=ERROR path=- detail=the inbox location could not be resolved (your-org/nexus-code#1723; see stderr)\n'
        n_bad=$((n_bad + 1)); continue
    fi
    if [[ -z "$dir" || "$dir" != /* || "$dir" == / || "$dir" =~ ^/+$ ]]; then
        printf 'degraded-probe: REFUSED surface %s: path %s is empty, relative or the root\n' "$(_arg_excerpt "$name")" "$(_arg_excerpt "$dir")" >&2
        exit 2
    fi
    if [[ ! -d "$dir" ]]; then
        printf 'surface=%s verdict=MISSING path=%s\n' "$name" "$dir"
        n_bad=$((n_bad + 1)); continue
    fi
    probe="$dir/.degraded-probe.$$.$RANDOM"
    # The child does the create AND the remove, so a create that succeeds and a
    # remove that then hangs is still HANG rather than a stray file and an OK.
    # NEXUS_DEGRADED_PROBE_WRITER is a TEST SEAM only: it replaces the child so
    # a suite can produce EROFS/ENOSPC/HANG without a real broken mount.
    if [[ -n "${NEXUS_DEGRADED_PROBE_WRITER:-}" ]]; then
        writer=("$NEXUS_DEGRADED_PROBE_WRITER")
    else
        writer=(bash -c ': > "$1" && rm -f -- "$1"' _)
    fi
    err=$(timeout -k 2 "$bound" "${writer[@]}" "$probe" 2>&1 >/dev/null)
    rc=$?
    verdict=$(_classify "$rc" "$err")
    if [[ "$verdict" == OK ]]; then
        printf 'surface=%s verdict=OK path=%s\n' "$name" "$dir"
    else
        n_bad=$((n_bad + 1))
        detail=$(printf '%s' "$err" | tr '\n\t' '  ' | cut -c1-200)
        [[ "$verdict" == HANG ]] && detail="no return within ${bound}s (rc $rc)${detail:+; $detail}"
        printf 'surface=%s verdict=%s path=%s detail=%s\n' "$name" "$verdict" "$dir" "${detail:-rc $rc}"
    fi
done

printf 'summary: %d surface(s), %d not OK\n' "${#names[@]}" "$n_bad"
(( n_bad == 0 )) || exit 1
exit 0
