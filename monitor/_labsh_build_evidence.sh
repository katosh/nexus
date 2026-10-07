#!/usr/bin/env bash
# _labsh_build_evidence.sh — "is this process OUR labsh cold build, and is it
# stale?", answered from EVIDENCE rather than resemblance.
#
# Sourced by BOTH consumers so they cannot drift apart:
#   * monitor/labsh-supervised.sh   `reap_stale_builds`        (kill it?)
#   * monitor/watcher/_service_health.sh `_sh_labsh_build_in_progress`
#                                                              (defer restart?)
#
# Those two ask the same question with OPPOSITE polarity, which is exactly why
# they must share one answer (your-org/nexus-code#467, extending #465).
#
# ── Why resemblance is not identity ────────────────────────────────────────
# Both call sites previously decided by ARGV SUBSTRING:
#
#     pgrep -u "$(id -u)" -f 'jupyter-lab'
#     [[ "$cmd" == *jupyter-lab* && "$cmd" == *"--port $port"* ]]
#     case "$cmd" in *jupyter-lab*|*jupyter_lab*|*uvx*) ... esac
#
# An argv can contain any string. On 2026-07-09 a TEST FIXTURE whose command
# line merely contained `jupyter-lab` and `--port 9704` was matched by the live
# supervisor's reaper, killed as "an orphaned uvx jupyter-lab build", and took
# the operator's real JupyterLab down with it; the watcher then read the same
# resemblance, concluded a cold build was in progress, and SUSPENDED
# auto-restart. One string match both destroyed the service and silenced the
# machinery that would have recovered it.
#
# The reaper had never fired before that. It was not that the predicate was
# adequate — it was that nothing had yet resembled a build.
#
# Also live on this node, permanently: `uv tool uvx --from zotero-mcp-server`.
# Its /proc/<pid>/exe IS `uv`, so any `*uvx*` glob selects it.
#
# ── What counts as evidence ────────────────────────────────────────────────
# A process is OUR build only if ALL of these hold:
#
#   1. it is alive, is not us, and its uid is ours.
#      (`[[ -O /proc/<pid> ]]` is unreliable under the sandbox user namespace —
#      it reports true for pid 1 — so uids are compared explicitly.)
#   2. /proc/<pid>/exe basename is `uv` or `uvx`. A process cannot fake its
#      executable; it can put anything in argv. This is the gate that argv
#      matching never had.
#   3. /proc/<pid>/cwd IS the service's workdir. labsh launches the build from
#      the project directory, so cwd binds the process to THIS service.
#      Deliberately chosen over a ppid walk: a prior supervisor generation's
#      orphan has reparented to init, so no ppid walk can reach it — but its
#      cwd still names the service it belongs to.
#   4. its argv names a jupyterlab build at all.
#   5. it is THIS service's build: either the pid labsh recorded in
#      `<wd>/.jupyter/labsh.bg.pid`, or its argv carries this service's
#      `--port <port>`. (The pid file alone is not enough — a recorded pid can
#      be RECYCLED onto an unrelated process. Rules 2-4 are what make that safe.)
#
# Rule 4 and the argv half of rule 5 are corroboration on top of identity
# (rules 2-3), never a substitute for it.
#
# ── Fail closed, in both directions ────────────────────────────────────────
# "Fail closed" means: if we cannot ESTABLISH the claim, we do not act on it.
# The safe action differs per caller, so each gets its own verb:
#
#   labsh_build_is_ours  → false when unestablished. The reaper kills nothing;
#                          the watcher does not suspend recovery.
#   labsh_build_is_stale → false when unestablished OR still within budget.
#
# The asymmetry is the whole argument. A wrong "not stale" costs a delayed
# reap. A wrong "stale" destroys a bring-up in flight, or kills an operator's
# shell, or (as on 2026-07-09) both silences the watchdog and kills the server.
#
# Pure functions: they read /proc and print/return. They never signal, never
# write, and never touch the network. All are safe to call on any pid.
# ONE exception, at the bottom of the file: the PROGRESS predicate
# (`labsh_build_stalled`, and `labsh_build_release` through it) writes one
# sample file under the service's own <workdir>/.jupyter — it still never
# signals.

if [[ -n "${_NEXUS_LABSH_BUILD_EVIDENCE_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_NEXUS_LABSH_BUILD_EVIDENCE_LOADED=1

# Executables a labsh cold build may legitimately run as. `uvx` is a thin
# front-end for `uv`, so a build in the materialisation phase reports `uv`.
# A BOUND jupyter server is `python*` and is deliberately NOT here: a bound
# server is not a cold build, and must never be reaped as one.
_LABSH_BUILD_EXES=("uv" "uvx")

# labsh_build_age <pid>
# Print the process's age in seconds; return 1 if it cannot be established.
labsh_build_age() {
    local pid="${1:-}" age
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [[ "$age" =~ ^[0-9]+$ ]] || return 1     # unknown age ⇒ not established
    printf '%s' "$age"
}

# labsh_build_is_ours <pid> <workdir> [port]
# Return 0 iff <pid> is, on positive evidence, THIS service's labsh cold build.
# Fails closed on anything unreadable or unestablished.
labsh_build_is_ours() {
    local pid="${1:-}" workdir="${2:-}" port="${3:-}"
    local uid exe cwd cmd wd_abs bgpid matched_exe=0 e

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$workdir" ]]      || return 1
    [[ "$pid" == "$$" ]]     && return 1
    kill -0 "$pid" 2>/dev/null || return 1

    # (1) ours by uid.
    uid=$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null)
    [[ -n "$uid" && "$uid" == "$(id -u)" ]] || return 1

    # (2) identity by executable — argv cannot forge this.
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
    [[ -n "$exe" ]] || return 1
    for e in "${_LABSH_BUILD_EXES[@]}"; do
        [[ "${exe##*/}" == "$e" ]] && { matched_exe=1; break; }
    done
    (( matched_exe )) || return 1

    # (3) identity by working directory — binds the process to THIS service,
    #     and survives reparenting to init (a ppid walk does not).
    wd_abs=$(readlink -f "$workdir" 2>/dev/null) || return 1
    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null) || return 1
    [[ -n "$cwd" && "$cwd" == "$wd_abs" ]] || return 1

    # (4) corroboration: it is a jupyterlab build at all.
    # `{ …; } 2>/dev/null` — redirection ORDER (your-org/nexus-code#1305).
    cmd=$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null ) || return 1
    [[ -n "$cmd" ]] || return 1
    [[ "$cmd" == *jupyter-lab* || "$cmd" == *jupyter_lab* ]] || return 1

    # (5) it is THIS service's build: the recorded pid, or our port in argv.
    bgpid=$(cat "$workdir/.jupyter/labsh.bg.pid" 2>/dev/null)
    if [[ "$bgpid" =~ ^[0-9]+$ && "$bgpid" == "$pid" ]]; then
        return 0
    fi
    if [[ "$port" =~ ^[0-9]+$ && "$cmd" == *"--port $port"* ]]; then
        return 0
    fi
    return 1
}

# labsh_build_is_stale <pid> <workdir> <port> <budget_seconds>
# Return 0 iff <pid> is OUR build AND has been running at least <budget>
# seconds. Anything unestablished ⇒ 1 (not stale ⇒ do not kill).
labsh_build_is_stale() {
    local pid="${1:-}" workdir="${2:-}" port="${3:-}" budget="${4:-}" age
    [[ "$budget" =~ ^[0-9]+$ ]] || return 1
    labsh_build_is_ours "$pid" "$workdir" "$port" || return 1
    age=$(labsh_build_age "$pid") || return 1
    (( age >= budget ))
}

# labsh_build_scan <workdir> <port>
# Print the pid of every process that IS our build for this service, one per
# line. A /proc scan, never `pgrep -f`: `-f` matches the full argv, so it
# selects any process that merely mentions `jupyter-lab` — including the shells
# other agents are running right now, and this one.
labsh_build_scan() {
    local workdir="${1:-}" port="${2:-}" d pid
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        labsh_build_is_ours "$pid" "$workdir" "$port" && printf '%s\n' "$pid"
    done
    return 0
}

# labsh_build_in_progress <workdir>
# Return 0 iff a labsh COLD BUILD is materialising for this service right now,
# printing "<pid> <age-seconds>". This is the predicate `svc.sh` consults before
# it TERMs a service, so that a restart cannot silently discard a bring-up that
# is minutes into a ~19-minute NFS materialisation (your-org/your-nexus#273).
#
# Same two-part evidence as the watcher's `_sh_labsh_build_in_progress`, hosted
# here — in the file that already owns build identity — so the caller that must
# not DISTURB a build and the caller that must not MASK a dead service cannot
# drift apart:
#   (a) NO live server URL in the build log yet. labsh prints the banner only
#       once jupyter-lab binds, i.e. AFTER the whole uvx materialisation. A URL
#       present ⇒ the cold phase is over ⇒ NOT in progress, and the ordinary
#       restart machinery applies — a bound-but-wedged server is still fully
#       restartable, so this never weakens recovery; AND
#   (b) a live build PROCESS, proven ours by uid + exe + cwd + pidfile/port.
#
# Fails CLOSED (⇒ 1, "not in progress") on anything unestablished. The asymmetry
# is deliberate and is the opposite of the reaper's: a wrong "in progress" would
# block recovery of a genuinely dead service, which is strictly worse than a
# wrong "not in progress" (that costs one rebuild). Never suspend a restart for
# a process we cannot PROVE is our build.
labsh_build_in_progress() {
    local workdir="${1:-}" jdir bglog port pid age
    [[ -n "$workdir" ]] || return 1
    jdir="$workdir/.jupyter"
    [[ -d "$jdir" ]] || return 1

    bglog="$jdir/labsh.bg.log"
    if [[ -f "$bglog" ]] \
       && grep -qE 'is running at|https?://[0-9A-Za-z._-]+:[0-9]+/' "$bglog" 2>/dev/null; then
        return 1
    fi

    port=$(sed -n 's/^PORT=//p' "$jdir/labsh-service.env" 2>/dev/null | head -1)

    # (b1) the pid labsh recorded for the backgrounded build.
    pid=$(cat "$jdir/labsh.bg.pid" 2>/dev/null)
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! labsh_build_is_ours "$pid" "$workdir" "$port"; then
        # (b2) a build from a prior supervisor generation whose bg.pid we no
        #      longer hold — same identity gates, never an argv substring.
        pid=$(labsh_build_scan "$workdir" "$port" | head -1)
    fi
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    age=$(labsh_build_age "$pid") || return 1
    printf '%s %s' "$pid" "$age"
    return 0
}

# ── PROGRESS: is a live build still MOVING? ────────────────────────────────
# ONE answer for the three layers that can kill a build in flight
# (your-org/nexus-code#1676): svc.sh's cold-build guard, the
# watcher's service-health defer, and the supervisor's own stale-build reaper.
# Each used to decide on AGE ALONE against its own 1800 s bound, and on
# 2026-09-29 all three killed PROGRESSING builds: a cold materialisation on a
# load-100 node needs more than 30 min, so every build was discarded at the
# bound and the next one started from zero — a kill loop that read as a flap.
# (The watcher's bound also ran on the INCIDENT clock, so once the incident was
# 30 min old every NEW build was "past the ceiling" the moment it started.)
#
# The model, applied identically by every caller through `labsh_build_release`:
#
#   age <  soft ceiling            PROTECTED  (bring-up; nothing to prove)
#   age >= soft ceiling, MOVING    PROTECTED  (slow, not wedged)
#   age >= soft ceiling, STALLED   RELEASED   (no progress for the stall window)
#   age >= hard cap                RELEASED   (backstop: a "build" that keeps
#                                              moving for hours is not a build)
#
# THE ONE EXCEPTION TO "pure" IN THIS FILE: `labsh_build_stalled` persists a
# progress sample (it must compare across calls). The sample lives with the
# build it describes, in <workdir>/.jupyter/labsh.buildprogress, so every
# caller shares ONE baseline — never in any caller's own state dir, which is
# how three layers would come to disagree about the same process.
#
# Knobs (all seconds; 0 disables the respective bound):
#   LABSH_BUILD_STALL_SECONDS  default 600. A HEALTHY build on this NFS cache
#       was measured frozen (no CPU, no wchar, no log growth) for 90+ s at a
#       stretch while legitimately progressing (2026-07-13), so the window is
#       ~6.7x the longest stall observed. Chosen, not inherited.
#   LABSH_COLD_BUILD_HARD_CAP  default 7200. WE CHOSE 2 h: the longest build
#       measured on this nexus was >28 min at load ~100 (2026-09-29, killed at
#       30 min, still progressing), so 2 h is ~4x that; past it, recovery must
#       be able to proceed even if the counter keeps ticking (a spinning
#       process advances CPU time forever).

# labsh_build_progress <pid> <workdir>
# A monotone forward-motion counter: CPU ticks + bytes written + build-log size.
# Any increase is progress. Fails (prints nothing) when /proc is unreadable.
labsh_build_progress() {
    local pid="${1:-}" workdir="${2:-}" stat rest ticks=0 wchar=0 bg=0
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    rest=${stat#*") "}                        # drop "pid (comm) " — comm may hold spaces
    # shellcheck disable=SC2086
    set -- $rest                              # ${12}=utime, ${13}=stime (fields 14/15 overall)
    # ${12} NOT $12 — the latter is ${1}2, i.e. the state char with a "2" glued on.
    [[ "${12:-}" =~ ^[0-9]+$ && "${13:-}" =~ ^[0-9]+$ ]] || return 1
    ticks=$(( ${12} + ${13} ))
    wchar=$(awk '/^wchar/{print $2; exit}' "/proc/$pid/io" 2>/dev/null)
    [[ "$wchar" =~ ^[0-9]+$ ]] || wchar=0
    bg=$(stat -c %s "$workdir/.jupyter/labsh.bg.log" 2>/dev/null)
    [[ "$bg" =~ ^[0-9]+$ ]] || bg=0
    printf '%s' $(( ticks + wchar + bg ))
}

# labsh_build_stalled <pid> <workdir>
# rc 0 iff the build has PROVABLY made no forward progress for >= the stall
# window. Unprovable (unreadable counters, first sight, a new pid) ⇒ 1, i.e.
# "not stalled": a wrong "stalled" destroys a bring-up, a wrong "not stalled"
# only delays a release, and the hard cap bounds that delay.
labsh_build_stalled() {
    local pid="${1:-}" workdir="${2:-}"
    local stall="${LABSH_BUILD_STALL_SECONDS:-600}"
    local f="$workdir/.jupyter/labsh.buildprogress"
    local now cur prev_pid='' prev_ts='' prev_cur=''

    [[ "$stall" =~ ^[0-9]+$ ]] && (( stall > 0 )) || return 1
    [[ -d "$workdir/.jupyter" ]] || return 1
    cur=$(labsh_build_progress "$pid" "$workdir") || return 1
    now=$(date +%s 2>/dev/null) || return 1

    # Test readability first: `< "$f"` on a missing file is a REDIRECT failure
    # bash reports itself, which a `2>/dev/null` on `read` cannot suppress.
    if [[ -r "$f" ]]; then
        read -r prev_pid prev_ts prev_cur < "$f" || true
    fi

    # A different pid, an unreadable sample, or forward motion ⇒ re-baseline.
    if [[ "$prev_pid" != "$pid" ]] \
       || [[ ! "$prev_ts"  =~ ^[0-9]+$ ]] \
       || [[ ! "$prev_cur" =~ ^[0-9]+$ ]] \
       || (( cur > prev_cur )); then
        printf '%s %s %s\n' "$pid" "$now" "$cur" > "$f.tmp.$$" 2>/dev/null \
            && mv -f "$f.tmp.$$" "$f" 2>/dev/null
        rm -f "$f.tmp.$$" 2>/dev/null
        return 1
    fi

    # Same pid, no advance since prev_ts. The timestamp is deliberately NOT
    # refreshed — the stall is measured from when motion stopped.
    (( now - prev_ts >= stall ))
}

# labsh_build_release <pid> <age-seconds> <workdir> <soft-ceiling-seconds>
# THE verdict every caller acts on. Prints ONE line, "<token> <explanation>",
# and returns 0 iff the build may be killed (RELEASED), 1 iff it must be left
# alone (PROTECTED). Tokens:
#   released: defer-disabled | past-hard-cap | stalled
#   protected: within-ceiling | progressing
# A soft ceiling of 0 means the caller's cold-build defer is disabled, so there
# is nothing to protect. The stall sample is taken on EVERY call (even inside
# the ceiling), so the baseline is warm by the time the ceiling passes.
labsh_build_release() {
    local pid="${1:-}" age="${2:-}" workdir="${3:-}" soft="${4:-}"
    local hard="${LABSH_COLD_BUILD_HARD_CAP:-7200}" stall="${LABSH_BUILD_STALL_SECONDS:-600}"
    local stalled=1 mins
    [[ "$hard"  =~ ^[0-9]+$ ]] || hard=7200
    [[ "$stall" =~ ^[0-9]+$ ]] || stall=600
    [[ "$soft"  =~ ^[0-9]+$ ]] || soft=1800
    if [[ ! "$age" =~ ^[0-9]+$ ]]; then
        # Cannot age it ⇒ cannot bound it. Protecting an unbounded build would
        # block recovery forever; releasing one we cannot age is what the
        # callers did before this predicate existed.
        printf 'past-hard-cap build age unknown — cannot be bounded, so not protected\n'
        return 0
    fi
    mins=$(( age / 60 ))
    if (( soft == 0 )); then
        printf 'defer-disabled the cold-build defer is disabled (ceiling 0)\n'
        return 0
    fi
    labsh_build_stalled "$pid" "$workdir" && stalled=0
    if (( hard > 0 && age >= hard )); then
        if (( stalled == 0 )); then
            printf 'past-hard-cap build running %sm (%ss), past the %ss hard cap, and not progressing\n' "$mins" "$age" "$hard"
        else
            printf 'past-hard-cap build running %sm (%ss), past the %ss hard cap — released even though it may still be moving\n' "$mins" "$age" "$hard"
        fi
        return 0
    fi
    if (( age < soft )); then
        printf 'within-ceiling build running %sm (%ss), inside the %ss ceiling\n' "$mins" "$age" "$soft"
        return 1
    fi
    if (( stalled == 0 )); then
        printf 'stalled build running %sm (%ss) has made NO forward progress (CPU, bytes written, log growth) for >= %ss — presumed wedged\n' "$mins" "$age" "$stall"
        return 0
    fi
    printf 'progressing build running %sm (%ss), past the %ss ceiling but still making progress — slow, not wedged (hard cap %ss)\n' "$mins" "$age" "$soft" "$hard"
    return 1
}
