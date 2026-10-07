#!/usr/bin/env bash
# uv-builds-gc.sh — reap ORPHANED uv build dirs, `<cache>/builds-v0/.tmp*`
# (your-org/nexus-code#1686). DRY RUN unless --yes.
#
#   uv-builds-gc.sh [--cache DIR] [--min-age SECONDS] [--yes] [--no-sizes]
#
#   --cache DIR      the uv cache root (default: $UV_CACHE_DIR; refused if unset)
#   --min-age S      only dirs whose mtime is at least S seconds old
#                    (default 86400 — see "Why 24 h" below)
#   --yes            DELETE the qualifying dirs. Without it nothing is touched.
#   --no-sizes       skip the per-dir size walk (it is the slow part on NFS)
#
# One line per .tmp dir on stdout, tab-separated:
#   <verdict> <path> age=<s> du=<bytes> freed=<bytes> [reason]
# verdict is one of: would-reap | reaped | keep | reap-failed
# then one `total` line. Freed bytes count only files whose link count is 1:
# the cache runs with UV_LINK_MODE=hardlink, so a .tmp dir shares most of its
# inodes with `archive-v0` and its siblings, and deleting it frees none of
# those. `du` is therefore an UPPER bound on what a reap frees and `freed` a
# LOWER bound (an inode shared ONLY between two reaped dirs is freed but is
# counted by neither).
#
# Exit codes:
#   0  done (dry run, or every qualifying dir reaped; "nothing qualifies" too)
#   1  at least one qualifying dir could not be removed (named on stdout)
#   2  usage
#   3  REFUSED — a safety precondition could not be ESTABLISHED (no cache, /proc
#      or /proc/locks unreadable, a process of ours whose handles cannot be
#      read, a lock holder whose start time cannot be read), or under --yes
#      the cache is IN USE (its exclusive lock cannot be taken). Nothing deleted.
#
# ── What these dirs are ───────────────────────────────────────────────────
# uv materialises an environment into a fresh `builds-v0/.tmpXXXXXX` and only
# RENAMES it into `archive-v0` when the build completes. A build that is
# killed — the labsh cold-build kill loop of your-org/nexus-code#1676 killed
# them every 30 min — leaves the half-built dir behind forever.
#
# `uv cache prune` does NOT reclaim them (uv 0.9.25, measured 2026-09-30 on a
# throwaway cache: a planted 3-day-old `builds-v0/.tmpOLD1` survived `prune`,
# which removed only an unreferenced `archive-v0` entry). Prune also takes an
# EXCLUSIVE lock on the cache, which every running uv — including the
# long-lived `uvx jupyter-lab` serving labsh — holds SHARED for its whole life,
# so it cannot even start while the service is up. Hence this tool.
#
# ── When a dir qualifies (ALL must hold; anything unestablished ⇒ keep) ────
#   1. it is a real directory (not a symlink) named `.tmp*`, owned by us;
#   2. its mtime is at least --min-age old;
#   3. it is OLDER THAN EVERY LIVE BUILDER (+ a clock margin). uv names each
#      build dir fresh and never adopts an existing one, so a dir whose mtime
#      predates a process's start cannot be that process's build. Builders =
#      every process of our uid whose /proc/<pid>/exe is `uv`/`uvx` (the same
#      executable gate `_labsh_build_evidence.sh` uses; argv is never read —
#      it can say anything), PLUS every process holding a lock on
#      `<cache>/.lock` that /proc/locks shows or, of ours, an fd open on it
#      (a lock outlives the pid /proc/locks names). /proc/locks is NOT
#      host-wide: it lists only locks taken by processes in THIS PID namespace
#      (measured in this sandbox: one line, the labsh uvx), and never locks
#      held by other NFS clients. A builder outside that view reads as "no
#      builder" here — which is why --yes also takes the EXCLUSIVE lock below;
#   4. no process of our uid has a cwd, an open fd, a mapped file, or a
#      VIRTUAL_ENV / CONDA_PREFIX / PYTHONHOME / PATH entry inside it (the last
#      catches a `uv run --with` child whose uv parent is gone);
#   5. no `environments-v2/*/*` symlink resolves into it.
# Rules 3-5 are re-checked for each dir immediately before it is removed, and
# --yes runs only while it holds <cache>/.lock EXCLUSIVELY (see main), which no
# running uv on any host sharing the cache allows.
#
# THE RESIDUAL, stated because nothing here can see it: a `uv run` child whose
# uv parent has DIED (so the lock is released) and which runs OUTSIDE this
# PID namespace (another host, a Slurm node) holds no lock and shows no
# process. Its ephemeral env is reaped once it is older than --min-age. Do not
# run --yes while long `uv run` jobs of ours may be orphaned elsewhere.
#
# Why 24 h: no live build runs that long — #1677's hard cap releases a labsh
# build at 7200 s — so 24 h is 12x the longest legitimate build. WE CHOSE it.
#
# Knobs:
#   UV_BUILDS_GC_CLOCK_MARGIN  seconds subtracted from the earliest builder
#       start in rule 3 (default 300; WE CHOSE it to absorb NFS-server vs
#       local clock skew on the mtime).
#   UV_BUILDS_GC_TEST_SID  TEST SEAM, never set in production: restrict the
#       process scan (rules 3-4) to processes of session SID. It NARROWS the
#       safety scan, so the header names it whenever it is set. It exists
#       because rule 4 refuses on ANY live process of ours whose handles it
#       cannot read, and a host can carry such a process forever: one that is
#       non-dumpable (prctl PR_SET_DUMPABLE 0, or credentials changed without
#       an exec, e.g. `(sd-pam)`) has /proc/<pid>/cwd, fd and environ owned by
#       root. The GitHub runner has one, so the suite refused every run there
#       (#1703); the suite runs in its own session and passes that SID.
#
# Cost: the size walk visits every file. On the production NFS cache the
# 2026-09-30 census of 329 dirs took 1h44m under `ionice -c3`. Run it under
# `ng longjob run`, or pass --no-sizes for a fast verdict-only listing.

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_labsh_build_evidence.sh
source "$SCRIPT_DIR/_labsh_build_evidence.sh"

usage() { sed -n '2,/^# ── What these dirs/{/^# ── What these dirs/d;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

CACHE="${UV_CACHE_DIR:-}"
MIN_AGE=86400
YES=0
SIZES=1
while (( $# )); do
    case "$1" in
        --cache)    CACHE="${2:-}"; shift 2 || usage ;;
        --min-age)  MIN_AGE="${2:-}"; shift 2 || usage ;;
        --yes)      YES=1; shift ;;
        --no-sizes) SIZES=0; shift ;;
        -h|--help)  usage ;;
        *) echo "uv-builds-gc: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ "$MIN_AGE" =~ ^[0-9]+$ ]] || { echo "uv-builds-gc: --min-age must be an integer" >&2; exit 2; }
MARGIN="${UV_BUILDS_GC_CLOCK_MARGIN:-300}"
[[ "$MARGIN" =~ ^[0-9]+$ ]] || MARGIN=300
SCOPE_SID="${UV_BUILDS_GC_TEST_SID:-}"
[[ -z "$SCOPE_SID" || "$SCOPE_SID" =~ ^[1-9][0-9]*$ ]] || { echo "uv-builds-gc: UV_BUILDS_GC_TEST_SID must be a pid" >&2; exit 2; }

refuse() { echo "uv-builds-gc: REFUSED — $*; nothing deleted" >&2; exit 3; }

[[ -n "$CACHE" ]] || refuse "no cache given (--cache or UV_CACHE_DIR)"
CACHE=$(readlink -f "$CACHE" 2>/dev/null) || refuse "cache path does not resolve"
BUILDS="$CACHE/builds-v0"
[[ -d "$BUILDS" && ! -L "$BUILDS" ]] || refuse "$BUILDS is not a directory — not a uv cache?"
ME=$(id -u)
[[ -r /proc/self/status && -d /proc/self/fd ]] || refuse "/proc is not readable"

# ── live state ─────────────────────────────────────────────────────────────

# _start_epoch <pid> — the process's start time in epoch seconds (rc 1 when
# it cannot be read, including "already gone").
_start_epoch() {
    local age
    age=$(labsh_build_age "$1") || return 1
    printf '%s' $(( $(date +%s) - age ))
}

# _our_pids — every pid whose real uid is ours (and, under the test seam
# UV_BUILDS_GC_TEST_SID, whose session is that one).
_our_pids() {
    local d u
    for d in /proc/[0-9]*; do
        u=$(awk '/^Uid:/{print $2; exit}' "$d/status" 2>/dev/null) || continue
        [[ "$u" == "$ME" ]] || continue
        if [[ -n "$SCOPE_SID" ]]; then
            # stat fields after `(comm) `: state ppid pgrp session
            [[ "$(awk '{ sub(/^.*\) /, ""); print $4; exit }' "$d/stat" 2>/dev/null)" == "$SCOPE_SID" ]] || continue
        fi
        printf '%s\n' "${d#/proc/}"
    done
    return 0
}

# _earliest_builder [pid…] — print "<earliest-start-epoch|none> <pid,pid,…|none>"
# over every live builder (rule 3); the arguments are extra builders found by
# the handle scan (processes of ours with an fd open on <cache>/.lock — see
# _scan). rc 1 = could not establish.
_earliest_builder() {
    local ino pid e s x earliest='' seen='' pids=("$@")
    [[ -r /proc/locks ]] || return 1
    ino=$(stat -c %i "$CACHE/.lock" 2>/dev/null) || ino=''
    if [[ -n "$ino" ]]; then
        # Lines look like `24: FLOCK ADVISORY READ 20037 00:88:31322504186 0 EOF`
        # (a blocked waiter carries an extra `->`); the pid is the field
        # before MAJ:MIN:INODE.
        while read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] && pids+=("$pid")
        done < <(awk -v ino="$ino" '{
                    for (i = 2; i <= NF; i++) if ($i ~ /^[0-9a-f]+:[0-9a-f]+:[0-9]+$/) {
                        n = split($i, a, ":"); if (a[n] == ino) print $(i-1); break } }' /proc/locks)
    fi
    while read -r pid; do
        e=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
        for x in "${_LABSH_BUILD_EXES[@]}"; do
            [[ "${e##*/}" == "$x" ]] && { pids+=("$pid"); break; }
        done
    done < <(_our_pids)
    for pid in "${pids[@]+"${pids[@]}"}"; do
        [[ ",$seen," == *",$pid,"* ]] && continue
        if ! s=$(_start_epoch "$pid"); then
            _gone_or_zombie "$pid" && continue    # exited meanwhile ⇒ not a builder
            return 1                              # alive yet unreadable ⇒ unestablished
        fi
        seen+="${seen:+,}$pid"
        [[ -z "$earliest" ]] || (( s < earliest )) && earliest=$s
    done
    printf '%s %s' "${earliest:-none}" "${seen:-none}"
}

# _gone_or_zombie <pid> — rc 0 when the process no longer holds anything: it
# has exited, or is a zombie (whose cwd/fd links read as absent).
_gone_or_zombie() {
    local st
    [[ -d "/proc/$1" ]] || return 0
    st=$(awk '{ sub(/^.*\) /, ""); print $1; exit }' "/proc/$1/stat" 2>/dev/null) || return 0
    [[ -z "$st" || "$st" == Z || "$st" == X ]]
}

# _scan — one pass over every process of ours. Prints `H <path>` for each cwd,
# fd target and mapped file under builds-v0, and `L <pid>` for each process
# with an fd open on <cache>/.lock. The second matters because /proc/locks
# names the pid that TOOK a flock, and that process may have exited while a
# child it handed the fd to still holds the lock (measured: `flock -s FILE cmd`
# shows the `flock` pid, and `exec 8>FILE; flock -s 8; exec cmd` shows a pid
# that is already gone). rc 1 = some live process's handles could not be read
# (fail closed).
_scan() {
    local pid cwd out envp tries
    while read -r pid; do
        [[ "$pid" == "$BASHPID" || "$pid" == "$$" ]] && continue
        # A process caught MID-EXIT has already released its fs/files but is
        # not yet a zombie, so its links read as absent for a moment (measured:
        # a refusal under a concurrent test load). Retry briefly; a process
        # that STAYS unreadable while alive still refuses the run.
        tries=0
        until cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) \
              && out=$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 -type l -printf '%l\n' 2>/dev/null) \
              && envp=$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null); do
            _gone_or_zombie "$pid" && continue 2
            # Name the process: a refusal that says only "some process" cannot
            # be acted on (#1703 took a CI round-trip to attribute). comm is the
            # kernel's 16-byte name, never argv.
            (( ++tries >= 5 )) && { printf 'U %s (%s)\n' "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')"; return 1; }
            sleep 0.2
        done
        printf '%s\n' "$out" | awk -v l="$CACHE/.lock" -v p="$pid" '$0 == l { print "L " p }'
        # The ENVIRONMENT too: a `uv run --with` child runs from its ephemeral
        # env in builds-v0/.tmp* while holding no cwd, fd or map there, and once
        # its uv parent is gone nothing else marks the dir live (measured,
        # your-org/nexus-code#1701 skeptic F1). Only the path-valued variables
        # an interpreter is launched under are read, and only values under
        # builds-v0 are ever printed.
        { printf '%s\n' "$cwd" "$out"
          awk '$6 ~ /^\// { print $6 }' "/proc/$pid/maps" 2>/dev/null
          printf '%s\n' "$envp" | awk -F= '
              $1 == "VIRTUAL_ENV" || $1 == "CONDA_PREFIX" || $1 == "PYTHONHOME" { print substr($0, length($1) + 2) }
              $1 == "PATH" { n = split(substr($0, 6), a, ":"); for (i = 1; i <= n; i++) print a[i] }'
        } | awk -v b="$BUILDS/" 'index($0, b) == 1 { print "H " $0 }'
    done < <(_our_pids)
    return 0
}

# _env_targets — the resolved target of every environments-v2/*/* symlink that
# lands under builds-v0. rc 1 = environments-v2 exists but cannot be read.
_env_targets() {
    local ev="$CACHE/environments-v2" l t
    [[ -e "$ev" ]] || return 0
    [[ -r "$ev" && -x "$ev" ]] || return 1
    for l in "$ev"/*/*; do
        [[ -L "$l" ]] || continue
        t=$(readlink -f "$l" 2>/dev/null) || continue
        [[ "$t" == "$BUILDS/"* ]] && printf '%s\n' "$t"
    done
    return 0
}

# _blocked <dir> <held> <targets> <earliest> — print the reason the dir must
# be KEPT under rules 3-5, or nothing when it may go.
_blocked() {
    local d="$1" held="$2" targets="$3" earliest="$4" mt
    mt=$(stat -c %Y "$d" 2>/dev/null) || { echo "mtime unreadable"; return; }
    if [[ -n "$earliest" ]] && (( mt > earliest - MARGIN )); then
        echo "not older than a live builder (started $(date -d "@$earliest" '+%F %T'))"; return
    fi
    if printf '%s\n' "$held" | awk -v d="$d" '$0 == d || index($0, d "/") == 1 { f = 1 } END { exit !f }'; then
        echo "held open by a live process (cwd/fd/map/env)"; return
    fi
    if printf '%s\n' "$targets" | awk -v d="$d" '$0 == d || index($0, d "/") == 1 { f = 1 } END { exit !f }'; then
        echo "an environments-v2 symlink resolves into it"; return
    fi
}

# _sizes <dir> — "du freed" in bytes: du over distinct inodes, freed over
# regular files with link count 1.
_sizes() {
    find "$1" -xdev -printf '%i %n %s %b %y\n' 2>/dev/null | awk '
        !seen[$1]++ { du += $4 * 512; if ($5 == "f" && $2 == 1) fr += $3 }
        END { printf "%d %d", du, fr }'
}

_snapshot() {   # sets HELD TARGETS EARLIEST, or refuses
    local b scan lockers
    scan=$(_scan)                 || refuse "a live process of ours has unreadable /proc handles (pid $(printf '%s\n' "$scan" | sed -n 's/^U //p'); non-dumpable or credential-changed — it could hold a build dir unseen)"
    HELD=$(printf '%s\n' "$scan" | sed -n 's/^H //p')
    lockers=$(printf '%s\n' "$scan" | sed -n 's/^L //p')
    # shellcheck disable=SC2086 — pids, split on purpose
    b=$(_earliest_builder $lockers) || refuse "could not establish the start time of a live uv builder or cache-lock holder"
    read -r EARLIEST BUILDERS <<<"$b"
    [[ "$EARLIEST" == none ]] && EARLIEST=''
    TARGETS=$(_env_targets)       || refuse "$CACHE/environments-v2 is not readable"
}

# ── main ───────────────────────────────────────────────────────────────────

# --yes holds uv's OWN in-use lock, EXCLUSIVE, for the whole run — the check
# `uv cache prune` makes (its --force is "ignoring in-use checks"). Every
# running uv holds <cache>/.lock SHARED, so this refuses while ANY uv uses the
# cache, including ones /proc cannot show: other PID namespaces (Slurm jobs
# inheriting UV_CACHE_DIR) and, on this NFSv3 mount (local_lock=none), other
# hosts. Consequence, by design: --yes cannot run while the labsh server's
# `uvx` is up (it holds the lock for its whole life). The dry run takes no lock.
if (( YES )); then
    command -v flock >/dev/null 2>&1 || refuse "flock(1) not found — cannot take the cache's in-use lock"
    # flock-fd: held for the whole run ON PURPOSE; every child spawned while it is held (find, awk, stat, rm, sleep) is synchronous and exits before this script does, so no child can outlive and extend the hold
    exec 9>>"$CACHE/.lock" || refuse "cannot open $CACHE/.lock"
    flock -x -n 9 || refuse "the uv cache is IN USE (a uv process holds $CACHE/.lock — e.g. a running labsh server, a build, or a job on another host); --yes needs it idle"
fi

_snapshot
NOW=$(date +%s)
n=0; nq=0; nreaped=0; nfail=0; du_q=0; fr_q=0; rc=0
mode=$( (( YES )) && echo REAP || echo DRY-RUN )
echo "# uv-builds-gc $mode cache=$CACHE min-age=${MIN_AGE}s margin=${MARGIN}s${SCOPE_SID:+ scan-scope=TEST-SEAM-session:$SCOPE_SID} builders=$BUILDERS earliest-builder-start=$( [[ -n "$EARLIEST" ]] && date -d "@$EARLIEST" '+%F %T' || echo none)"

shopt -s nullglob dotglob
for d in "$BUILDS"/.tmp*; do
    n=$(( n + 1 ))
    du=-; fr=-
    if [[ -L "$d" || ! -d "$d" ]]; then
        printf 'keep\t%s\tage=-\tdu=-\tfreed=-\tnot a real directory\n' "$d"; continue
    fi
    if [[ "$(stat -c %u "$d" 2>/dev/null)" != "$ME" ]]; then
        printf 'keep\t%s\tage=-\tdu=-\tfreed=-\tnot owned by us\n' "$d"; continue
    fi
    mt=$(stat -c %Y "$d" 2>/dev/null) || { printf 'keep\t%s\tage=-\tdu=-\tfreed=-\tmtime unreadable\n' "$d"; continue; }
    age=$(( NOW - mt ))
    if (( age < MIN_AGE )); then
        printf 'keep\t%s\tage=%s\tdu=-\tfreed=-\tyounger than --min-age\n' "$d" "$age"; continue
    fi
    why=$(_blocked "$d" "$HELD" "$TARGETS" "$EARLIEST")
    if [[ -n "$why" ]]; then
        printf 'keep\t%s\tage=%s\tdu=-\tfreed=-\t%s\n' "$d" "$age" "$why"; continue
    fi
    if (( SIZES )); then read -r du fr < <(_sizes "$d"); fi
    nq=$(( nq + 1 ))
    [[ "$du" =~ ^[0-9]+$ ]] && du_q=$(( du_q + du ))
    [[ "$fr" =~ ^[0-9]+$ ]] && fr_q=$(( fr_q + fr ))
    if (( ! YES )); then
        printf 'would-reap\t%s\tage=%s\tdu=%s\tfreed=%s\n' "$d" "$age" "$du" "$fr"; continue
    fi
    # Re-establish rules 3-5 against FRESH state, right before removal.
    _snapshot
    why=$(_blocked "$d" "$HELD" "$TARGETS" "$EARLIEST")
    if [[ -n "$why" ]]; then
        printf 'keep\t%s\tage=%s\tdu=%s\tfreed=%s\t%s (at re-check)\n' "$d" "$age" "$du" "$fr" "$why"; continue
    fi
    # A read-only subdirectory (some wheels ship them) makes rm fail on its
    # entries; grant ourselves write on our own tree and retry once.
    rm -rf -- "$d" 2>/dev/null || { chmod -R u+w -- "$d" 2>/dev/null; rm -rf -- "$d" 2>/dev/null; }
    if [[ ! -e "$d" ]]; then
        nreaped=$(( nreaped + 1 ))
        printf 'reaped\t%s\tage=%s\tdu=%s\tfreed=%s\n' "$d" "$age" "$du" "$fr"
    else
        nfail=$(( nfail + 1 )); rc=1
        printf 'reap-failed\t%s\tage=%s\tdu=%s\tfreed=%s\n' "$d" "$age" "$du" "$fr"
    fi
done
shopt -u nullglob dotglob

sz=$( (( SIZES )) && printf 'du=%s (UPPER bound) freed=%s (nlink-1 files, LOWER bound)' "$du_q" "$fr_q" || printf 'sizes not measured (--no-sizes)')
printf 'total\t%s dirs, %s qualifying, %s reaped, %s failed\t%s\n' "$n" "$nq" "$nreaped" "$nfail" "$sz"
exit "$rc"
