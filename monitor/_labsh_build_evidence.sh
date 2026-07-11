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
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
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
