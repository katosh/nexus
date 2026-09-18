# shellcheck shell=bash
# monitor/longjob-probes.d/pid.sh — longjob-watch subject probe: a local process.
# Contract: see slurm.sh (lj_probe_main <target> <spec-json> → "<state>|<detail>").
#
# Target: `<pid>` or `<pid>:<starttime>`. `longjob-watch.sh add` fills in the
# kernel start-time (`/proc/<pid>/stat` field 22) at add time when the caller
# gave a bare pid, so by the time this probe runs the identity is checkable —
# a RECYCLED pid must never read as `running` (your-org/nexus-code#1351, the
# same discipline as async-run.sh and proc-exists-authorized).
#
# WHAT THIS KIND CANNOT SAY: the exit status. When the pid is gone, the
# process's rc was reaped by whoever its parent was, not by us, so the only
# honest terminal state is `done|process gone (exit status NOT retained by
# this subject kind)`. A caller who needs the rc launches through
# `monitor/async-run.sh` and watches `asyncrun:<token>` instead; the `add`
# verb says so on stdout when a pid: subject is registered.

_lj_pid_starttime() {   # <pid> → field 22 of /proc/<pid>/stat, or empty
    local stat
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 0
    stat="${stat##*) }"            # everything after the comm's closing paren
    # The remainder starts at stat field 3 (state), so overall field 22
    # (starttime, clock ticks since boot, immutable for the process's life) is
    # word 20 of the remainder. `comm` can contain spaces, which is why the
    # split happens AFTER the closing paren rather than on the whole line.
    # shellcheck disable=SC2086
    set -- $stat
    printf '%s' "${20-}"
}

lj_probe_main() {
    local target="$1" pid st want
    pid="${target%%:*}"
    want=""; [[ "$target" == *:* ]] && want="${target#*:}"
    [[ "$pid" =~ ^[0-9]+$ ]] || { printf 'unknown|not a pid: %s' "$target"; return 0; }
    if [[ ! -d "/proc/$pid" ]]; then
        printf 'done|process %s gone (exit status NOT retained by the pid: kind — use asyncrun: for a status)' "$pid"
        return 0
    fi
    st=$(_lj_pid_starttime "$pid")
    if [[ -z "$want" ]]; then
        printf 'unknown|pid %s is occupied but no start-time was recorded, so it cannot be told from a recycled pid — re-add as pid:%s:%s' "$pid" "$pid" "${st:-?}"
        return 0
    fi
    if [[ -z "$st" ]]; then
        printf 'unknown|/proc/%s/stat unreadable' "$pid"; return 0
    fi
    if [[ "$st" == "$want" ]]; then
        printf 'running|pid %s alive (start-time %s verified)' "$pid" "$st"
    else
        printf 'done|pid %s was RECYCLED (start-time %s ≠ recorded %s): the original process is gone; exit status not retained' "$pid" "$st" "$want"
    fi
    return 0
}
