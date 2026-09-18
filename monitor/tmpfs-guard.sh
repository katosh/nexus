#!/usr/bin/env bash
# tmpfs-guard.sh — a LOUD guard for MEMORY PRESSURE on /tmp, and a
# default-deny reaper for what leaks into it.
#
# WHY (2026-09-03). /tmp on the sandbox host is tmpfs — RAM, not disk — and
# 204 GiB of it (54% of this mount, 26% of the node's RAM, on a machine shared
# with other users) was held by abandoned scratch directories owned by this
# uid, accrued over six days with NO SIGNAL AT ALL. Three producers, three
# distinct cleanup defects, all measured (see the report filed with
# your-org/nexus-code, "tmpfs leak"):
#
#   .th-*        105,552 files    ~0     _test_helpers.sh per-process ledger and
#                                        port files; the ports file had no removal.
#   olay-guard-*   4,603 dirs  82 GiB   a test helper allocates, and cleanup is
#                                        opt-in at each of 29 call sites; 11 omit
#                                        it. Leaks on the SUCCESS path.
#   mutgate-*      4,006 dirs  27 MiB   monitor/mutation-gate.sh allocated a
#                                        workdir and never removed it on any path.
#                                        (fixed alongside this file)
#   tt-<pid>           1 dir   43 GiB   a correctly-trapped suite, SIGKILLed —
#                                        the one gap `trap ... EXIT` cannot close.
#
# WHAT THE GUARD MEASURES, AND WHAT IT USED TO (your-org/nexus-code#1423).
# It used to trip on an ENTRY COUNT, and on 2026-09-07 that produced a FINDING
# every ~2 minutes for seventeen hours while the resource it guards was
# NINE-TENTHS FREE:
#
#     tmpfs 378G size, 36G used, 343G avail, 10%  /tmp
#     MemTotal 791 GB   MemAvailable 558 GB   Shmem 107 GB
#     trigger: entries 14,129 > 6,000
#
# Three things were wrong with that number and they compound:
#   * it is an INVENTORY, not a consumption — 14,129 empty files and 14,129
#     one-GiB files are the same number and not the same problem;
#   * it EXCLUDED the largest family on the node (`.th-*`, ~62,000 files) by
#     construction, because folding them in made the check red on a healthy
#     day — so the alarm was blind to its own dominant contributor;
#   * the standard remedy barely moves it: `--reap --dry-run` planned 51,379
#     removals of which 97% were `.th-*`, leaving 1,638 rows the trigger could
#     even see.
#
# A threshold that excludes its biggest contributor AND is unmoved by its own
# remedy is measuring something nobody chose. The trigger is now CONSUMPTION
# RELATIVE TO CAPACITY. Silent at 10%; loud at the shape that motivated the
# tool.
#
# Modes — the first matters more than the rest:
#
#   --check   MEASURE and, over a pressure threshold, report a FINDING (exit
#             100: alive, condition present). Registered as a services.registry
#             healthcheck so the watcher's service-health machinery surfaces it
#             to the orchestrator. A leak nobody is told about is the same
#             class as a false BLOCK nobody is told about
#             (your-org/nexus-code#1400): silence read as health. Pure
#             measurement — never mutates.
#   --reap    remove what escapes per-site cleanup, under a predicate that is
#             DEFAULT-DENY on every axis (see "The safety predicate" below).
#   --daemon  a foreground loop calling --reap on an interval; the registry's
#             launch-cmd for the DELETING half. The registry is the nexus's
#             only periodic machinery, so the reaper is a service rather than
#             a new scheduler.
#   --check-daemon
#             a foreground loop calling --check on an interval and NEVER
#             reaping (your-org/nexus-code#1441). The registry's launch-cmd
#             for the READ-ONLY half, which is the half every operator should
#             inherit by default: ~168 GiB accumulated here because nobody was
#             LOOKING, not because nobody was deleting, and a default-on
#             service whose steady state is `rm -rf` on a regex family list
#             is a destructive default shipped to people who have not read
#             the list.
#   --status  --check plus the tail of the reap log.
#
# THE CONDITIONS. Each has its own honest name and its own threshold. NONE of
# them is a file count.
#
#   tmp_capacity   $ROOT USED bytes against the tmpfs SIZE. The primary axis:
#                  tmpfs is RAM, so filling this mount spends the node's
#                  memory. Banded warn / high / critical.
#   node_memory    MemAvailable against MemTotal. The node can be short of
#                  memory because of something that is NOT us, and the right
#                  response differs — which is why the finding carries OWNER
#                  attribution instead of assuming.
#   inodes         `df -i` IUse%. Inodes ARE a real resource with a real
#                  ceiling, so they get their OWN condition, their own
#                  threshold and an honest name — never smuggled in as
#                  "memory". This is where the old entry count's legitimate
#                  half went.
#   socket_root    non-socket payload in $ROOT/c71780. A CONTRACT violation
#                  (your-org/nexus-code#1422), NOT memory pressure — banded
#                  `elevated` and never higher, so it cannot masquerade as
#                  pressure. ON by default; `monitor.tmpfs.socket_root_is_trigger=0`
#                  silences it.
#
#                  WHAT WAS ACTUALLY WRONG WITH IT WAS THE REPETITION, NOT THE
#                  CONDITION, and the stable key is what fixes that. Measured
#                  over this guard's own 205-emit history: the socket-root leg
#                  took exactly ONE value (2,541 MiB) across all 205 emits while
#                  the entry-count leg took 13 — so the stable, actionable leg
#                  was re-broadcast every two minutes only because a noisy leg's
#                  integer sat in the same string. Keyed per condition it now
#                  says its piece ONCE and stays silent until it changes band.
#
#                  It is the ACTIONABLE leg and it would have been the wrong one
#                  to drop: re-derived 2026-09-08, the payload is 100% ours
#                  (1,725 of 1,725 top-level entries `operator`), entirely STALE
#                  (0 modified in 24 h), and concentrated (one directory is 45%
#                  of it). An earlier cut of this change silenced it outright
#                  and that was an over-correction — the mount's own bytes
#                  argument (a runaway here raises `tmp_capacity` anyway) is
#                  about SEVERITY, and it justifies the `elevated` cap rather
#                  than silence.
#
# THE ENTRY COUNTS ARE DEMOTED, NOT DELETED. They are rendered inside the
# finding under a heading that says they are context, because "how many files"
# is genuinely useful once you already know there is pressure. They decide
# nothing.
#
# THRESHOLD PROVENANCE — every one of these is CHOSEN, not a default inherited
# from any tool, and this comment is the record of choosing them:
#   warn 50%       the motivating incident sat at 204 GiB of a 378 GiB tmpfs =
#                  54%, so 50 is the highest round number that still catches
#                  it. Today's 10% is nowhere near it.
#   high 65%       headroom to act.
#   critical 80%   headroom to panic.
#   mem_avail 15%  below this the NODE is short of memory, whoever caused it.
#   inode 60%      tmpfs inodes are bounded by memory too; 60% leaves room to
#                  reap before allocation starts failing.
#
# BANDS, AND WHY THE BAND IS THE SUPPRESSION KEY. The finding's dedupe key used
# to be its own rendered text, and that text carried a live counter: `14129` ->
# `14127` re-fired it two minutes later while the state a reader cares about —
# still over threshold — had changed zero times. So `--check` DECLARES a stable
# key (`finding-key:`) built from the band and the set of tripped conditions,
# plus a monotone `finding-band:` severity. Numbers move freely inside the
# rendered text without re-firing anything; crossing INTO A WORSE BAND re-fires
# immediately and breaks any mute.
#
# THE SAFETY PREDICATE (--reap). An entry is removed ONLY if ALL of these hold:
#   1. it is a DIRECT child of --root (never a nested path), a dir or a
#      plain file — the `.th-ledger.*`/`.th-ports.*` families are files;
#   2. it is owned by THIS uid (never another user's files);
#   3. its basename matches a REGISTERED leak family (allowlist; a name the
#      allowlist does not enumerate is never touched);
#   4. it is not on the DENYLIST — names that hold live sockets or live
#      sessions (c71780, claude-71780, tmux-*, .nexus-trash) are never touched
#      whatever the allowlist says (deny arms precede allow arms; #1121);
#   5. nothing inside it was modified within --older-than-hours (default 24);
#   6. it contains NO socket file, bound or not — sockets are what the shared
#      scratch root exists to hold, and deleting a live one breaks a running
#      service silently;
#   7. no live process REFERENCES it: /proc/*/{cwd,root,exe,fd/*,maps,cmdline,
#      environ} and /proc/net/unix are walked once per reap and any path at or under
#      the entry is a veto. (Only the CURRENT pid namespace is visible; the
#      report states that boundary. Argv matching over-includes — an agent
#      whose PROMPT names a path protects it — which is the safe direction.)
#
# `.nexus-trash` is reaped by its own tool, `monitor/_trash.sh --clear`, which
# until this file had NO CALLER — three comments promised "reaped later by
# `_trash.sh --clear`" and nothing ever ran it (3.3 GiB, 115 entries).
#
# Every removal is logged to $STATE_DIR/tmpfs-guard.log with the predicate
# that admitted it. --dry-run prints the plan and the total, removes nothing.
#
# RETIRED KNOBS. `monitor.tmpfs.max_used_pct`, `.max_entries` and
# `.max_th_files` selected the old inventory trigger. They are REFUSED rather
# than ignored: a config key that silently stops doing anything is this
# repo's dominant defect class, and an operator who tuned a threshold deserves
# to be told it no longer exists rather than to keep believing it applies.
#
# Exit codes
#   --check:  0 healthy · 100 FINDING (alive, condition PRESENT; stderr is the
#             finding) · 3 could not measure (fail-closed: "I could not look"
#             is not "fine") · 2 usage / a retired knob is still configured
#   --reap:   0 · 2 usage · 3 could not enumerate live references (nothing removed)
#
# Tested by monitor/watcher/test-tmpfs-guard.sh (plants each predicate axis).
set -uo pipefail

# THE WHOLE FILE IS ONE BRACE GROUP, and that is load-bearing. bash reads a
# script INCREMENTALLY, so a long-running instance keeps reading bytes from
# disk as it goes — and this reaper runs for minutes to hours. Measured
# 2026-09-03: two live reaps, each edited underneath, died with
# `line 345: c: command not found` (rc 127) and `line 333: syntax error near
# unexpected token }` AFTER having done their work. A brace group is parsed to
# its closing brace before any of it executes, so an edit landing mid-run
# changes the next invocation, never this one.
{
_self_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
NEXUS_ROOT_DEFAULT=$(cd "$_self_dir/.." && pwd)
: "${NEXUS_ROOT:=$NEXUS_ROOT_DEFAULT}"
STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
_cfg="$NEXUS_ROOT/config/load.sh"

# config knob -> env override -> default. Tests pass flags, so a fixture never
# reads the operator's live config (your-org/nexus-code#833 class).
cfg() {   # <dotted.key> <default>
    local k="$1" d="$2" v=""
    [ -x "$_cfg" ] && v=$("$_cfg" "$k" "$d" 2>/dev/null)
    printf '%s' "${v:-$d}"
}

ROOT=/tmp
MODE=""
DRY=0
OLDER_H=""
WARN_PCT=""
HIGH_PCT=""
CRIT_PCT=""
MEM_AVAIL_LOW_PCT=""
MAX_INODE_PCT=""
MAX_C71780_MIB=""
INTERVAL_S=""
REAP_ENABLED=""
INUSE_FILE=""      # test seam: a precomputed in-use list instead of a /proc walk
TRASH_DAYS=""
QUIET=0

# The leading comment block IS the usage text. Derived rather than a hardcoded
# line range: `sed -n '2,60p'` truncated mid-header and silently stopped
# showing the exit codes when the header grew past line 60 — a help text that
# is wrong in a way nobody notices is the same family as everything else in
# this file's subject matter.
usage() {
    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
    exit "${1:-2}"
}
die() { printf 'tmpfs-guard: %s\n' "$*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check|--reap|--daemon|--status) MODE="${1#--}"; shift ;;
        --check-daemon) MODE=check-daemon; shift ;;
        --root) ROOT="${2:?}"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --older-than-hours) OLDER_H="${2:?}"; shift 2 ;;
        --warn-pct) WARN_PCT="${2:?}"; shift 2 ;;
        --high-pct) HIGH_PCT="${2:?}"; shift 2 ;;
        --critical-pct) CRIT_PCT="${2:?}"; shift 2 ;;
        --mem-avail-low-pct) MEM_AVAIL_LOW_PCT="${2:?}"; shift 2 ;;
        --max-inode-pct) MAX_INODE_PCT="${2:?}"; shift 2 ;;
        --max-c71780-mib) MAX_C71780_MIB="${2:?}"; shift 2 ;;
        --interval-seconds) INTERVAL_S="${2:?}"; shift 2 ;;
        --trash-days) TRASH_DAYS="${2:?}"; shift 2 ;;
        --inuse-file) INUSE_FILE="${2:?}"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        # RETIRED, and REFUSED rather than ignored (your-org/nexus-code#1423).
        # These selected the entry-count trigger. Accepting them as no-ops
        # would let a caller keep believing a threshold applies while nothing
        # reads it — the manufactured-success shape this whole file is about.
        --max-used-pct|--max-entries|--max-th-files)
            die "$1 is RETIRED: the trigger is memory PRESSURE, not inventory (your-org/nexus-code#1423). Use --warn-pct/--high-pct/--critical-pct for capacity, --max-inode-pct for the inode ceiling. Entry counts are still REPORTED as diagnostic context inside the finding; they no longer decide anything." ;;
        -h|--help) usage 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$MODE" ] || usage 2
[ -d "$ROOT" ] || die "root is not a directory: $ROOT"

# A RETIRED CONFIG KEY MUST NOT BE SILENTLY IGNORED. `cfg` cannot tell "unset"
# from "set to the default", so it is asked for a sentinel: anything other than
# the sentinel means the operator has a value on file for a knob that no longer
# selects anything, and they are told rather than left believing it applies.
for _retired in monitor.tmpfs.max_used_pct monitor.tmpfs.max_entries monitor.tmpfs.max_th_files; do
    _rv=$(cfg "$_retired" '__UNSET__')
    [ "$_rv" = '__UNSET__' ] || die "config key '$_retired' is RETIRED (value on file: '$_rv') — it selected the entry-count trigger, which your-org/nexus-code#1423 replaced with memory-pressure banding. Remove it, or move the intent to monitor.tmpfs.pressure_warn_pct / .pressure_high_pct / .pressure_critical_pct / .max_inode_use_pct."
done

OLDER_H="${OLDER_H:-$(cfg monitor.tmpfs.reap_older_than_hours 24)}"
WARN_PCT="${WARN_PCT:-$(cfg monitor.tmpfs.pressure_warn_pct 50)}"
HIGH_PCT="${HIGH_PCT:-$(cfg monitor.tmpfs.pressure_high_pct 65)}"
CRIT_PCT="${CRIT_PCT:-$(cfg monitor.tmpfs.pressure_critical_pct 80)}"
MEM_AVAIL_LOW_PCT="${MEM_AVAIL_LOW_PCT:-$(cfg monitor.tmpfs.mem_available_low_pct 15)}"
MAX_INODE_PCT="${MAX_INODE_PCT:-$(cfg monitor.tmpfs.max_inode_use_pct 60)}"
MAX_C71780_MIB="${MAX_C71780_MIB:-$(cfg monitor.tmpfs.max_c71780_payload_mib 2048)}"
# ON by default — see the socket_root note in the header. Set to 0 to silence
# it without a code change.
SOCKET_ROOT_TRIGGER="${SOCKET_ROOT_TRIGGER:-$(cfg monitor.tmpfs.socket_root_is_trigger 1)}"
INTERVAL_S="${INTERVAL_S:-$(cfg monitor.tmpfs.reap_interval_seconds 3600)}"
TRASH_DAYS="${TRASH_DAYS:-$(cfg monitor.tmpfs.trash_days 7)}"
for v in OLDER_H WARN_PCT HIGH_PCT CRIT_PCT MEM_AVAIL_LOW_PCT MAX_INODE_PCT MAX_C71780_MIB SOCKET_ROOT_TRIGGER INTERVAL_S TRASH_DAYS; do
    eval "x=\$$v"
    case "$x" in ''|*[!0-9]*) die "$v must be a non-negative integer (got '$x')" ;; esac
done
# The bands must be ORDERED or the banding is meaningless — and an unordered
# set of thresholds fails SILENTLY (every value lands in one band), which is
# exactly the shape of defect this file exists to catch.
[ "$WARN_PCT" -le "$HIGH_PCT" ] && [ "$HIGH_PCT" -le "$CRIT_PCT" ] \
    || die "pressure thresholds must satisfy warn <= high <= critical (got ${WARN_PCT}/${HIGH_PCT}/${CRIT_PCT})"
LOG="$STATE_DIR/tmpfs-guard.log"

# emit_both — write to BOTH stdout and stderr WITHOUT REOPENING EITHER.
#
# NEVER `tee /dev/stderr` (your-org/nexus-code#1490). `tee` OPENS its file
# argument, `/dev/stderr` resolves to whatever fd 2 currently points at, and
# an open of a regular file TRUNCATES it. The `>>` a service was launched with
# governs the ORIGINAL open, not tee's reopen — so a service started
# `>>"$log" 2>&1` loses its entire history on the FIRST line it emits.
# Measured: a seeded 40-line log came back as 1 line, rc 0, nothing on stderr.
#
# This guard is the worst possible host for that bug: it exists to describe an
# accumulating condition OVER TIME, so its log IS the evidence, and the
# construct fired on every finding it reported.
#
# `>&2` DUPLICATES fd 2; it does not open a path, so no truncation is
# possible. `/dev/fd/2` is NOT a remedy — on Linux it is a symlink to the same
# file and opening it truncates identically.
#
# Both call shapes are supported deliberately: the finding block pipes a
# multi-line group in, and the df-failure arm has one string and no pipeline.
# When fd 1 and fd 2 are the same file (a `>>log 2>&1` launch) each line lands
# twice, exactly as `tee` did — the duplication is pre-existing behaviour and
# production routes fd 1 to /dev/null; only the truncation is removed.
emit_both() {
    if (( $# > 0 )); then
        printf '%s\n' "$*"
        printf '%s\n' "$*" >&2
        return 0
    fi
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
        printf '%s\n' "$line" >&2
    done
}

log() {
    local line; line="[$(date -Is)] pid=$$ $*"
    [ "$QUIET" = 1 ] || printf '%s\n' "$line"
    { mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s\n' "$line" >> "$LOG"; } 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The allowlist: leak FAMILIES with an identified producer and a measured
# cleanup gap. A basename must match one of these to be a candidate. Extend via
# config `monitor.tmpfs.reap_families` (space-separated extended-regex anchors),
# and say in the commit which producer and which gap each addition names.
# ---------------------------------------------------------------------------
REAP_FAMILIES_DEFAULT='^olay-guard[a-z-]*-[A-Za-z0-9_]+$ ^mutgate-[0-9]+$ ^tt-[0-9]+$ ^\.th-ledger\.[0-9]+-[0-9a-z]+$ ^\.th-ports\.[0-9]+$'
# Bare `tmp.*` (unprefixed `mktemp -d`) is deliberately NOT a default family, and
# the reason is a residual the veto cannot close: the live watcher's own scratch
# is `tmp_dir=$(mktemp -d)` at monitor/watcher/main.sh (a `tmp.*` name held in a
# NON-EXPORTED shell variable for the watcher's whole life). No /proc walk sees a
# path that lives only in a shell variable — cwd/fd/maps/cmdline/environ all
# miss it. The family also fails this file's own rule for admission: no single
# identified producer. An operator who has audited their `tmp.*` writers can add
# `^tmp\\.[A-Za-z0-9]{6,}$` via monitor.tmpfs.reap_families; the residual then
# is theirs to state. (11,746 such dirs / 0.21 GiB were reaped on 2026-09-03 under
# the earlier default; the watcher survived because it rewrites its scratch every
# cycle, which kept the dir's mtime inside the 24 h window — an accident, not a
# guarantee, which is why the default changed.)
REAP_FAMILIES="${TMPFS_REAP_FAMILIES:-$(cfg monitor.tmpfs.reap_families "$REAP_FAMILIES_DEFAULT")}"

# The denylist: never touched, whatever the allowlist says. Checked FIRST.
is_denied() {   # <basename>
    case "$1" in
        c71780|c71780-*|claude-*|tmux-*|.nexus-trash|.X11-unix|.ICE-unix|.font-unix|systemd-*) return 0 ;;
    esac
    return 1
}
is_family() {   # <basename>
    local re
    for re in $REAP_FAMILIES; do
        [[ "$1" =~ $re ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Live references: every path under $ROOT that any visible process holds via
# cwd/root/exe/fd/maps/cmdline, plus every bound unix socket path. One file,
# one walk per reap. Exit 3 if /proc is unreadable — a reaper that cannot see
# who holds what must not remove anything.
# ---------------------------------------------------------------------------
enumerate_inuse() {   # -> writes $1
    local out="$1" p l t fd n=0
    [ -r /proc/self/fd ] || return 3
    : > "$out" || return 3
    for p in /proc/[0-9]*; do
        n=$((n+1))
        for l in cwd root exe; do
            t=$(readlink "$p/$l" 2>/dev/null) || continue
            case "$t" in "$ROOT"/*) printf '%s\n' "$t" >> "$out";; esac
        done
        for fd in "$p"/fd/*; do
            t=$(readlink "$fd" 2>/dev/null) || continue
            case "$t" in "$ROOT"/*) printf '%s\n' "${t% (deleted)}" >> "$out";; esac
        done
        # Braced: a pid that exits mid-walk makes the `<` REDIRECTION fail, and
        # that error is the shell's, not tr's — a trailing 2>/dev/null misses it.
        { awk -v r="$ROOT/" 'index($6, r)==1 {print $6}' "$p/maps" >> "$out"; } 2>/dev/null || true
        { tr '\0' '\n' < "$p/cmdline" | grep -o -- "$ROOT/[^ \"'\`]*" >> "$out"; } 2>/dev/null || true
        # ENVIRONMENT too: a dir held only as an exported variable (TMPDIR=…, a
        # HOLD_DIR handed to a child) is a live reference with no fd, cwd or argv.
        { tr '\0' '\n' < "$p/environ" | grep -o -- "$ROOT/[^ \"'\`]*" >> "$out"; } 2>/dev/null || true
    done
    awk -v r="$ROOT/" 'NR>1 && index($NF, r)==1 {print $NF}' /proc/net/unix 2>/dev/null >> "$out" || true
    sort -u -o "$out" "$out"
    [ "$n" -gt 0 ] || return 3
    return 0
}
is_referenced() {   # <dir> <inuse-file>
    grep -qxF -- "$1" "$2" && return 0
    grep -qF -- "$1/" "$2" && return 0
    return 1
}

# ---------------------------------------------------------------------------
# --reap
# ---------------------------------------------------------------------------
# Global, not `local`: the EXIT trap below runs after do_reap has returned,
# where a local is out of scope and `set -u` turns the cleanup into an error —
# a reaper that leaks its own scratch file. Measured while testing.
TMPINUSE=""
do_reap() {
    local inuse="$INUSE_FILE"
    if [ -z "$inuse" ]; then
        TMPINUSE=$(mktemp "${TMPDIR:-/tmp}/tmpfs-guard-inuse.XXXXXX") || die "mktemp failed"
        trap '[ -n "$TMPINUSE" ] && rm -f -- "$TMPINUSE"' EXIT
        if ! enumerate_inuse "$TMPINUSE"; then
            log "REFUSED: could not enumerate live references (/proc) — nothing removed"
            return 3
        fi
        inuse="$TMPINUSE"
    fi
    # An in-use list that cannot be READ is not an empty one. `grep -q` on a
    # missing file exits 2, which reads as "not referenced" — a fail-OPEN
    # reaper. Refuse instead: nothing is removed without a list to consult.
    if [ ! -r "$inuse" ]; then
        log "REFUSED: in-use list unreadable ($inuse) — nothing removed"
        return 3
    fi
    local myuid; myuid=$(id -u)
    local mins=$((OLDER_H * 60)) cutoff
    cutoff=$(( $(date +%s) - OLDER_H * 3600 ))
    local n_cand=0 n_rm=0 n_keep=0 bytes=0 d b why sz mt uid ty hit ts
    local -a batch=()
    flush_batch() {   # files are removed in batches: one rm per 500, not per file
        [ "${#batch[@]}" -gt 0 ] || return 0
        if [ "$DRY" != 1 ]; then rm -f -- "${batch[@]}" 2>/dev/null; fi
        batch=()
    }
    # ONE enumeration, oldest first (so a mistake is bounded), carrying mtime,
    # owner, type and size — the per-candidate stat/find/du spawns that made the
    # first cut take hours over a 130k-entry backlog are gone. A directory still
    # costs one `find` (fresh-content OR socket, in one walk) and one `grep`.
    # NUL-delimited: a newline in a name splits a `\n`-terminated record into two
    # phantom paths, and the old `! -e` test then logged both as "removed".
    while IFS=$'\t' read -r -d '' mt uid ty sz d; do
        b=${d##*/}
        is_denied "$b" && continue
        is_family "$b" || continue
        n_cand=$((n_cand+1))
        why=""
        if [ "$uid" != "$myuid" ]; then why="not-our-uid"
        elif [ "${mt%.*}" -gt "$cutoff" ]; then why="modified<${OLDER_H}h"
        elif [ "$ty" = d ]; then
            hit=$(find "$d" \( -mmin "-$mins" -o -type s \) -print -quit 2>/dev/null)
            [ -n "$hit" ] && why="fresh-content-or-socket:${hit#$d/}"
        fi
        if [ -z "$why" ] && grep -qF -- "$d" "$inuse"; then why="referenced-by-live-process"; fi
        if [ -n "$why" ]; then
            n_keep=$((n_keep+1)); [ "$QUIET" = 1 ] || printf 'keep  %-60s %s\n' "$d" "$why"
            continue
        fi
        if [ "$ty" = d ]; then sz=$(du -sb -- "$d" 2>/dev/null | cut -f1); sz=${sz:-0}; fi
        printf -v ts '%(%FT%T%z)T' -1
        if [ "$DRY" = 1 ]; then
            printf 'would-remove %-50s %10d bytes\n' "$d" "$sz"
        elif [ "$ty" = d ]; then
            # "removed" means: it EXISTED when we got here AND rm returned 0. The
            # old `! -e` after a silenced rm was a proxy that also fired for a
            # path a concurrent reaper had already taken (two such duplicates in
            # the real ledger, 13:00–13:16) and for a phantom that never existed.
            if [ ! -e "$d" ] && [ ! -L "$d" ]; then log "already-gone $d"; n_keep=$((n_keep+1)); continue; fi
            if ! rm -rf -- "$d" 2>/dev/null || [ -e "$d" ]; then log "FAILED to remove $d"; n_keep=$((n_keep+1)); continue; fi
            log "removed $d bytes=$sz older_than_h=$OLDER_H unreferenced=yes"
        else
            if [ ! -e "$d" ] && [ ! -L "$d" ]; then log "already-gone $d"; n_keep=$((n_keep+1)); continue; fi
            batch+=("$d"); [ "${#batch[@]}" -ge 500 ] && flush_batch
            [ "$QUIET" = 1 ] || printf '[%s] removed %s bytes=%s (batched)\n' "$ts" "$d" "$sz"
        fi
        n_rm=$((n_rm+1)); bytes=$((bytes+sz))
    done < <(find "$ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -printf '%T@\t%U\t%y\t%s\t%p\0' 2>/dev/null | sort -z -n)
    flush_batch
    [ "$DRY" = 1 ] || log "removed-files-batched: $((n_rm)) total removals so far include batched plain files (families .th-*)"

    # .nexus-trash: the tool exists; give it its first caller.
    local trash="$ROOT/.nexus-trash" tr_out=""
    if [ -d "$trash" ]; then
        if [ "$DRY" = 1 ]; then
            printf 'would-run    _trash.sh --clear --older-than %s --root %s (%s entries)\n' "$TRASH_DAYS" "$trash" "$(ls -1A "$trash" 2>/dev/null | wc -l)"
        else
            tr_out=$("$_self_dir/_trash.sh" --clear --older-than "$TRASH_DAYS" --root "$trash" 2>&1) || true
            log "trash: $(printf '%s' "$tr_out" | tail -n1)"
        fi
    fi
    # Our own scratch goes every pass, not only at EXIT — the daemon loops, and
    # the EXIT trap alone leaked one `tmpfs-guard-inuse.*` per iteration
    # (measured 4 for 4 by the skeptic): a leak-reaper that leaks.
    if [ -n "$TMPINUSE" ]; then rm -f -- "$TMPINUSE"; TMPINUSE=""; fi
    local verb="removed"; [ "$DRY" = 1 ] && verb="would-remove"
    log "reap summary: candidates=$n_cand $verb=$n_rm kept=$n_keep bytes=$bytes ($((bytes/1048576)) MiB) root=$ROOT older_than_h=$OLDER_H"
    return 0
}

# ---------------------------------------------------------------------------
# --check — MEMORY PRESSURE, never inventory (your-org/nexus-code#1423).
# The argument, the conditions and the threshold provenance are in the header;
# this is the machinery.
# ---------------------------------------------------------------------------

# Band vocabulary. Monotone integers, so "worse than" is arithmetic and a mute
# recorded at one band can be broken by a higher one.
BAND_OK=0; BAND_ELEVATED=1; BAND_HIGH=2; BAND_CRITICAL=3
band_name() {
    case "${1:-}" in
        0) printf 'ok' ;; 1) printf 'elevated' ;;
        2) printf 'high' ;; 3) printf 'critical' ;; *) printf 'unknown' ;;
    esac
}
# band_for_pct <pct> <warn> <high> <critical> — INCLUSIVE at each edge, so a
# threshold of 50 means "at or above 50%", which is what a reader assumes when
# they set it.
band_for_pct() {
    local p="$1" w="$2" h="$3" c="$4"
    if   [ "$p" -ge "$c" ]; then printf '%s' "$BAND_CRITICAL"
    elif [ "$p" -ge "$h" ]; then printf '%s' "$BAND_HIGH"
    elif [ "$p" -ge "$w" ]; then printf '%s' "$BAND_ELEVATED"
    else printf '%s' "$BAND_OK"; fi
}
meminfo_kb() { awk -v k="${1}:" '$1==k { print $2; exit }' /proc/meminfo 2>/dev/null; }
# pct_of <part> <whole> — integer percent, floored. Returns EMPTY and rc 1 when
# the inputs are unusable, so a caller can never read "could not measure" as 0%.
pct_of() {
    local a="${1:-}" b="${2:-}"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
    [ "$b" -gt 0 ] || return 1
    printf '%s' $(( a * 100 / b ))
}
human_b() {   # <bytes> -> "12.3 GiB" / "4.0 MiB" / "512 B"
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || { printf '?'; return; }
    awk -v b="$b" 'BEGIN{
        if (b >= 1073741824) printf "%.1f GiB", b/1073741824
        else if (b >= 1048576) printf "%.1f MiB", b/1048576
        else if (b >= 1024) printf "%.1f KiB", b/1024
        else printf "%d B", b
    }'
}
human_kb() { human_b $(( ${1:-0} * 1024 )); }

# ---------------------------------------------------------------------------
# Growth history. Appended on EVERY check, healthy or not — the rate that
# matters is the one that GOT US HERE, and a sample first taken once we are
# already alarmed cannot supply it. Two integers and a count per line; trimmed
# to SAMPLES_KEEP so this file cannot grow without bound inside the directory
# whose growth this tool exists to watch.
# ---------------------------------------------------------------------------
SAMPLES_KEEP=600
samples_file() { printf '%s/tmpfs-guard.samples' "$STATE_DIR"; }
record_sample() {   # <epoch> <used_kb> <entries>
    local sf n; sf="$(samples_file)"
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$sf" 2>/dev/null || return 0
    n=$(wc -l < "$sf" 2>/dev/null || echo 0)
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt $(( SAMPLES_KEEP * 2 )) ]; then
        tail -n "$SAMPLES_KEEP" "$sf" > "$sf.tmp.$$" 2>/dev/null \
            && mv "$sf.tmp.$$" "$sf" 2>/dev/null || rm -f "$sf.tmp.$$" 2>/dev/null
    fi
}
# growth_line <now_epoch> <now_used_kb> — one human line, or a statement that
# there is not enough history. NEVER a fabricated zero: "no history" and "flat"
# are different facts and a reader acts differently on each.
growth_line() {
    local now="$1" used="$2" sf first_t="" first_u="" dt
    sf="$(samples_file)"
    [ -r "$sf" ] || { printf 'no history yet (this is the first recorded sample)'; return; }
    read -r first_t first_u _ < <(head -n1 "$sf" 2>/dev/null) || true
    [[ "$first_t" =~ ^[0-9]+$ && "$first_u" =~ ^[0-9]+$ ]] || { printf 'no usable history on file'; return; }
    dt=$(( now - first_t ))
    [ "$dt" -ge 300 ] || { printf 'history spans only %ss — too short to state a rate' "$dt"; return; }
    awk -v du=$(( used - first_u )) -v dt="$dt" 'BEGIN{
        printf "%+.2f GiB/hour averaged over the last %.1f h", (du/1048576.0)/(dt/3600.0), dt/3600.0
    }'
}

# ---------------------------------------------------------------------------
# Attribution — top families BY BYTES, WITH OWNER. Computed ONLY when a
# condition has tripped, which is now the rare case rather than the standing
# one, so its cost is paid at the moment it buys something.
#
# COST, MEASURED 2026-09-07 on this host (76,453 depth-1 entries, 33.4 GiB,
# 1.04 M inodes): the batched `du -sb` is 4 s and the depth-1 `find` under 1 s.
# A single-pass `find` over every inode was still running at two minutes, so
# the batched form is the one that ships.
#
# BY BYTES, NOT BY COUNT. Ranking families by file count is the same defect as
# the trigger this replaced: it makes 105,552 zero-byte ledger files outrank
# 43 GiB sitting in one directory.
#
# NEWLINE-NAMED ENTRIES ARE EXCLUDED AND COUNTED, NEVER SILENTLY MIS-JOINED.
# `du` has no NUL output mode, so a newline in a path splits its output record
# and the join would credit bytes to a family that does not exist. They are
# filtered out and reported as an explicit residual: an unattributed remainder
# a reader can SEE beats a plausible number that is wrong.
#
# ONE AWK PASS, NOT A LOOKUP PER ROW. The first cut re-scanned the metadata
# once per reap candidate — O(n^2) over 76k entries, the difference on this
# host between five seconds and not finishing. The family and denylist
# predicates are compiled into EREs and applied inside the join.
# ---------------------------------------------------------------------------
ATTRIB_TIMEOUT_S="${ATTRIB_TIMEOUT_S:-120}"
# Written WITHOUT an interval expression (`{4,}`): intervals are a portability
# coin-flip across awk implementations and this must behave identically
# wherever the watcher runs.
_FAM_FOLD='[.-][A-Za-z0-9_][A-Za-z0-9_][A-Za-z0-9_][A-Za-z0-9_]*$'
_families_ere() {   # REAP_FAMILIES is space-separated anchored EREs; awk wants one
    local re out=""
    for re in $REAP_FAMILIES; do out="${out:+$out|}($re)"; done
    printf '%s' "${out:-^$}"
}
_deny_ere() { printf '%s' '^(c71780|c71780-.*|claude-.*|tmux-.*|\.nexus-trash|\.X11-unix|\.ICE-unix|\.font-unix|systemd-.*)$'; }

attribution_block() {   # <root> <top-n> — renders indented lines on stdout
    local root="$1" top="${2:-8}" work rc=0 nl_count total rb rn cutoff
    work=$(mktemp -d "${TMPDIR:-/tmp}/tmpfs-attrib.XXXXXX") \
        || { printf '    (attribution UNAVAILABLE: mktemp failed — UNMEASURED, not zero)\n'; return 0; }
    find "$root" -mindepth 1 -maxdepth 1 -printf '%u\t%T@\t%p\0' 2>/dev/null > "$work/meta" || true
    if [ ! -s "$work/meta" ]; then
        printf '    (attribution UNAVAILABLE: the depth-1 walk produced nothing — UNMEASURED, not zero)\n'
        rm -rf -- "$work"; return 0
    fi
    nl_count=$(awk -v RS='\0' 'index($0, "\n") { n++ } END { print n+0 }' "$work/meta" 2>/dev/null)
    [[ "$nl_count" =~ ^[0-9]+$ ]] || nl_count=0
    awk -v RS='\0' -v ORS='\0' -F'\t' '!index($0, "\n") { print $3 }' "$work/meta" 2>/dev/null \
        | timeout "$ATTRIB_TIMEOUT_S" xargs -0 -r du -sb -- 2>/dev/null > "$work/bytes" || rc=$?
    if [ ! -s "$work/bytes" ]; then
        printf '    (attribution UNAVAILABLE: the byte walk produced nothing, rc %s — reported as UNMEASURED, never as zero)\n' "$rc"
        rm -rf -- "$work"; return 0
    fi
    awk -v RS='\0' -F'\t' '!index($0, "\n") { printf "%s\t%s\t%s\n", $3, $1, $2 }' "$work/meta" > "$work/own" 2>/dev/null
    cutoff=$(( $(date +%s) - OLDER_H * 3600 ))
    awk -F'\t' -v fold="$_FAM_FOLD" -v fams="$(_families_ere)" -v deny="$(_deny_ere)" \
               -v cutoff="$cutoff" -v me="$(id -un)" '
        NR==FNR { owner[$1]=$2; mtime[$1]=$3; next }
        {
            b=$1; p=$2
            n=split(p, seg, "/"); base=seg[n]; fam=base
            sub(fold, "", fam); sub(/[0-9]+$/, "", fam)
            if (fam == "") fam = base
            o = (p in owner) ? owner[p] : "?"
            bytes[fam SUBSEP o] += b; cnt[fam SUBSEP o]++
            own_b[o] += b
            total += b
            if (base ~ fams && base !~ deny && o == me) {
                mt = mtime[p]; sub(/[.].*$/, "", mt)
                if (mt != "" && mt+0 < cutoff+0) { rb += b; rn++ }
            }
        }
        END {
            for (k in bytes) { split(k, a, SUBSEP); printf "F\t%s\t%s\t%s\t%s\n", bytes[k], cnt[k], a[1], a[2] }
            for (o in own_b) printf "O\t%s\t%s\n", own_b[o], o
            printf "T\t%s\n", total+0
            printf "R\t%s\t%s\n", rb+0, rn+0
        }
    ' "$work/own" "$work/bytes" > "$work/agg" 2>/dev/null
    total=$(awk -F'\t' '$1=="T"{print $2}' "$work/agg"); [[ "$total" =~ ^[0-9]+$ ]] || total=0
    printf '    %-18s %12s %9s  %-10s %s\n' FAMILY BYTES ENTRIES OWNER SHARE
    awk -F'\t' '$1=="F"{print $2"\t"$3"\t"$4"\t"$5}' "$work/agg" | sort -rn | head -n "$top" \
        | while IFS=$'\t' read -r b n fam own; do
            printf '    %-18s %12s %9s  %-10s %s%%\n' "$fam" "$(human_b "$b")" "$n" "$own" \
                "$( [ "$total" -gt 0 ] && printf '%s' $(( b * 100 / total )) || printf '?' )"
        done
    # OWNER ROLL-UP — the "is this even ours?" question ANSWERED rather than
    # assumed (your-org/nexus-code#1423, operator). Measured here 2026-09-07:
    # 76,452 of 76,453 depth-1 entries are `operator`, so on this node it prints
    # ~100% ours and the finding is legitimately ours to act on. On a SHARED
    # node it would say so, and the orchestrator would learn that the remedy is
    # a conversation with another user rather than a reap. This is a smaller
    # change than muting and it removes most of the motive for muting:
    # attribution stays TRUE as the situation changes, where a mute answers the
    # question by discarding it.
    printf '    owners by bytes:'
    awk -F'\t' '$1=="O"{print $2"\t"$3}' "$work/agg" | sort -rn | head -n 5 \
        | while IFS=$'\t' read -r b own; do
            printf ' %s=%s(%s%%)' "$own" "$(human_b "$b")" \
                "$( [ "$total" -gt 0 ] && printf '%s' $(( b * 100 / total )) || printf '?' )"
        done
    printf '\n'
    [ "$nl_count" -gt 0 ] && printf '    NOTE: %s depth-1 entries carry a NEWLINE in the name and are EXCLUDED from the breakdown above (du has no NUL output mode). Their bytes are UNATTRIBUTED, not zero.\n' "$nl_count"
    rb=$(awk -F'\t' '$1=="R"{print $2}' "$work/agg"); rn=$(awk -F'\t' '$1=="R"{print $3}' "$work/agg")
    [[ "$rb" =~ ^[0-9]+$ ]] || rb=0; [[ "$rn" =~ ^[0-9]+$ ]] || rn=0
    # WHAT A REAP WOULD RECLAIM, and THE DIRECTION IT ERRS IN, because stating
    # the direction is what makes a number usable. This counts depth-1 entries
    # in a reap family, not denylisted, owned by us, whose TOP-LEVEL mtime is
    # older than the window. The reaper additionally vetoes on fresh content
    # anywhere inside, on a live process reference and on a contained socket —
    # each of which can only REMOVE rows. So the true figure is <= this one and
    # a reader is disappointed downward, never upward.
    printf '    a reap would reclaim AT MOST %s across %s entries (UPPER BOUND — the reaper also vetoes on fresh content, live references and sockets, each of which only removes rows). Reaping is NOT armed here: only --check-daemon is registered (your-org/nexus-code#957).\n' \
        "$(human_b "$rb")" "$rn"
    rm -rf -- "$work"
    return 0
}

do_check() {
    local now size_kb="" used_kb="" used_pct="" inode_pct="" entries="" th="" all=""
    now=$(date +%s)
    # ---- the cheap measurement. Every tick pays only this: two df calls and
    # one read of /proc/meminfo. The expensive attribution below runs ONLY
    # once a condition has tripped, which on a healthy node is never.
    read -r size_kb used_kb used_pct < <(df -P -- "$ROOT" 2>/dev/null | awk 'NR==2 { gsub("%","",$5); print $2, $3, $5 }')
    [[ "$used_pct" =~ ^[0-9]+$ && "$size_kb" =~ ^[0-9]+$ && "$used_kb" =~ ^[0-9]+$ ]] \
        || { emit_both "$(printf 'tmpfs-guard: UNHEALTHY: could not measure %s (df)\n' "$ROOT")"; return 3; }
    inode_pct=$(df -Pi -- "$ROOT" 2>/dev/null | awk 'NR==2 { gsub("%","",$5); print $5 }')
    [[ "$inode_pct" =~ ^[0-9]+$ ]] || inode_pct=""
    local mem_total mem_avail shmem mem_avail_pct shmem_pct tmp_of_ram_pct
    mem_total=$(meminfo_kb MemTotal); mem_avail=$(meminfo_kb MemAvailable); shmem=$(meminfo_kb Shmem)
    mem_avail_pct=$(pct_of "$mem_avail" "$mem_total" || true)
    shmem_pct=$(pct_of "$shmem" "$mem_total" || true)
    tmp_of_ram_pct=$(pct_of "$used_kb" "$mem_total" || true)
    # Entry counts: DIAGNOSTIC CONTEXT from here on. They decide nothing.
    all=$(ls -1A -- "$ROOT" 2>/dev/null)
    entries=$(printf '%s\n' "$all" | grep -cvE '^\.th-(ledger|ports)\.')
    th=$(printf '%s\n' "$all" | grep -cE '^\.th-(ledger|ports)\.')
    [[ "$entries" =~ ^[0-9]+$ ]] || entries='?'
    [[ "$th" =~ ^[0-9]+$ ]] || th='?'
    record_sample "$now" "$used_kb" "$entries"

    # ---- conditions ----
    local band="$BAND_OK" b_cap c_mib="" c_entries=""
    local -a conds=() detail=() cond_pairs=()
    b_cap=$(band_for_pct "$used_pct" "$WARN_PCT" "$HIGH_PCT" "$CRIT_PCT")
    if [ "$b_cap" -gt "$BAND_OK" ]; then
        conds+=("tmp_capacity"); cond_pairs+=("tmp_capacity=$(band_name "$b_cap")")
        detail+=("tmp_capacity: $ROOT is ${used_pct}% FULL — $(human_kb "$used_kb") of $(human_kb "$size_kb") (warn ${WARN_PCT}% / high ${HIGH_PCT}% / critical ${CRIT_PCT}%). This mount is tmpfs, so those bytes ARE the node's RAM: ${tmp_of_ram_pct:-?}% of MemTotal.")
        [ "$b_cap" -gt "$band" ] && band="$b_cap"
    fi
    if [[ "$mem_avail_pct" =~ ^[0-9]+$ ]] && [ "$mem_avail_pct" -le "$MEM_AVAIL_LOW_PCT" ]; then
        conds+=("node_memory"); cond_pairs+=("node_memory=high")
        detail+=("node_memory: only ${mem_avail_pct}% of MemTotal is available ($(human_kb "$mem_avail") of $(human_kb "$mem_total")); Shmem is $(human_kb "$shmem") (${shmem_pct:-?}% of MemTotal). The NODE is short of memory — read the owner roll-up below BEFORE assuming it is ours.")
        [ "$BAND_HIGH" -gt "$band" ] && band="$BAND_HIGH"
    fi
    if [[ "$inode_pct" =~ ^[0-9]+$ ]] && [ "$inode_pct" -ge "$MAX_INODE_PCT" ]; then
        conds+=("inodes"); cond_pairs+=("inodes=high")
        detail+=("inodes: $ROOT is at ${inode_pct}% of its inode ceiling (threshold ${MAX_INODE_PCT}%). Its OWN condition with its own name, NOT memory: an inode ceiling stops allocation while bytes are still free, so the two need different remedies.")
        [ "$BAND_HIGH" -gt "$band" ] && band="$BAND_HIGH"
    fi
    # socket_root — MEASURED ALWAYS, TRIGGERS ONLY IF ARMED. `socket_over` is
    # carried into both the healthy line and the finding, so the contract
    # violation stays VISIBLE either way; what it no longer does is wake the
    # orchestrator on its own while the mount it lives on is nine-tenths free.
    local socket_over=0
    if [ -d "$ROOT/c71780" ]; then
        local c_bytes
        c_bytes=$(timeout "$ATTRIB_TIMEOUT_S" find "$ROOT/c71780" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')
        [[ "$c_bytes" =~ ^[0-9]+$ ]] && c_mib=$(( c_bytes / 1048576 ))
        c_entries=$(find "$ROOT/c71780" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c)
        if [[ "$c_mib" =~ ^[0-9]+$ ]] && [ "$c_mib" -gt "$MAX_C71780_MIB" ]; then
            socket_over=1
            if [ "$SOCKET_ROOT_TRIGGER" = 1 ]; then
                conds+=("socket_root"); cond_pairs+=("socket_root=elevated")
                detail+=("socket_root: $ROOT/c71780 holds ${c_mib} MiB of non-socket payload (limit ${MAX_C71780_MIB} MiB). A CONTRACT violation, NOT memory pressure (your-org/nexus-code#1422): that directory has a short name for the 107-byte sun_path limit and holds sockets and nothing else. Re-derived 2026-09-08: the payload is 100% ours, entirely STALE (0 of ${c_entries:-?} top-level entries modified in 24 h) and concentrated. Silence it with monitor.tmpfs.socket_root_is_trigger=0; it is banded 'elevated' and never higher, so it can never read as pressure.")
                [ "$BAND_ELEVATED" -gt "$band" ] && band="$BAND_ELEVATED"
            fi
        fi
    fi

    if [ "$band" -eq "$BAND_OK" ]; then
        [ "$QUIET" = 1 ] || printf 'tmpfs-guard: healthy: %s used=%s%% (%s of %s) inodes=%s%% mem-avail=%s%% | context only: entries=%s th-files=%s%s\n' \
            "$ROOT" "$used_pct" "$(human_kb "$used_kb")" "$(human_kb "$size_kb")" "${inode_pct:-?}" "${mem_avail_pct:-?}" "$entries" "$th" \
            "$( [ "$socket_over" = 1 ] && printf ' | NOTE c71780 holds %s MiB of non-socket payload (contract limit %s MiB, your-org/nexus-code#1422) — reported here rather than raised, because monitor.tmpfs.socket_root_is_trigger is 0' "$c_mib" "$MAX_C71780_MIB" )"
        return 0
    fi

    # ---- a FINDING. The payload IS the product here: the orchestrator is
    # being asked to ACT, and acting needs families, owners and magnitudes
    # rather than a truncated first line.
    local cond_csv cond_bands d
    cond_csv=$(printf '%s,' "${conds[@]}"); cond_csv="${cond_csv%,}"
    # `<condition>=<band>` pairs, sorted so the key is a property of the
    # SITUATION rather than of evaluation order.
    cond_bands=$(printf '%s\n' "${cond_pairs[@]}" | sort | paste -sd, -)
    {
        # THE HEADLINE MUST NOT CALL SOMETHING PRESSURE THAT THIS FILE SPENDS
        # a paragraph insisting is not pressure. `socket_root` is a CONTRACT
        # condition; a finding carrying only contract conditions says so.
        local headline='is under MEMORY PRESSURE'
        case "$cond_csv" in
            socket_root) headline='has a CONTRACT violation (not memory pressure)' ;;
        esac
        printf 'tmpfs-guard: FINDING: %s %s — band %s (%s)\n' \
            "$ROOT" "$headline" "$(band_name "$band")" "$cond_csv"
        # The STABLE SUPPRESSION KEY and its monotone severity. Everything
        # below may move freely without re-firing the finding; a change HERE
        # means the situation itself changed.
        # THE KEY IS PER-CONDITION, and no measurement enters it. Instrumented
        # over this guard's own 205-emit history: the entry-count leg took 13
        # distinct values while the socket-root leg took ONE (2541, in all 205),
        # and keying on the rendered text let the noisy leg's integer launder
        # away the quiet leg's silence — the stable condition was re-broadcast
        # every ~2 minutes because a different leg's number moved inside the
        # same string. Naming each condition WITH ITS OWN BAND means a leg that
        # worsens changes the key (correct — the situation changed) while a leg
        # that merely wobbles cannot, because its numbers are not in here.
        printf 'finding-key: tmpfs:%s:%s\n' "$ROOT" "$cond_bands"
        printf 'finding-band: %s\n' "$band"
        for d in "${detail[@]}"; do printf '  %s\n' "$d"; done
        printf '  growth: %s\n' "$(growth_line "$now" "$used_kb")"
        printf '  top families BY BYTES (never by count — ranking by count is the defect this replaced):\n'
        attribution_block "$ROOT" 8
        printf '  DIAGNOSTIC CONTEXT (decides nothing; here because it is useful once you already know there is pressure): depth-1 entries excluding .th-* = %s; .th-ledger/.th-ports helper files = %s.\n' "$entries" "$th"
        [ "$socket_over" = 1 ] && printf '  DIAGNOSTIC CONTEXT: %s/c71780 holds %s MiB of non-socket payload against a %s MiB contract limit (your-org/nexus-code#1422). Not a trigger unless armed; its bytes are already counted in tmp_capacity above.\n' "$ROOT" "$c_mib" "$MAX_C71780_MIB"
        printf '  remedy: this is a READ-ONLY monitor. Inspect with `monitor/tmpfs-guard.sh --status --root %s`; reaping is NOT armed (your-org/nexus-code#957) and `--reap --dry-run` prints a plan without removing anything.\n' "$ROOT"
    } | emit_both
    # exit 100: a FINDING — this monitor is alive and the condition it watches
    # is present (your-org/nexus-code#1423). NOT exit 1: as a registry
    # healthcheck, 1 means DOWN and the watcher then offered `svc.sh restart`
    # for a report that a restart cannot change. The measurement failures above
    # stay 3 — a monitor that cannot measure IS unhealthy.
    return 100
}
do_status() {
    do_check; local rc=$?
    printf 'last reap log lines:\n'; tail -n 5 -- "$LOG" 2>/dev/null | sed 's/^/  /'
    return $rc
}

do_daemon() {
    log "daemon start root=$ROOT interval=${INTERVAL_S}s older_than_h=$OLDER_H families=[$REAP_FAMILIES]"
    while :; do
        QUIET=1 do_reap || log "daemon: reap returned $?"
        sleep "$INTERVAL_S" &
        wait $! || true
    done
}

do_check_daemon() {
    log "check-daemon start root=$ROOT interval=${INTERVAL_S}s (read-only: this loop NEVER reaps)"
    while :; do
        QUIET=1 do_check || { _rc=$?; if [ "$_rc" = 100 ]; then log "check-daemon: FINDING (rc 100) — a pressure band was entered; see --check for the conditions, the owners and the byte breakdown. Nothing was removed."; else log "check-daemon: UNHEALTHY (rc $_rc — could not measure); nothing was removed"; fi; }
        sleep "$INTERVAL_S" &
        wait $! || true
    done
}

case "$MODE" in
    check)  do_check ;;
    reap)   do_reap ;;
    daemon) do_daemon ;;
    check-daemon) do_check_daemon ;;
    status) do_status ;;
esac
exit $?
}
