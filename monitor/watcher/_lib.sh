#!/usr/bin/env bash
# Shared helpers for monitor/watcher/*.sh and monitor/ng.
#
# Keep this file side-effect-free: no set -e, no top-level config
# lookups, no global variables. Only function definitions — so it is
# safe to source from a script that has already configured its own
# shell options.
#
# Callers:
#   - monitor/watcher/bootstrap.sh  (to decide whether to respawn)
#   - monitor/ng  (cmd_watcher_status, for exit-code reporting)
#
# The liveness probe lives in ONE place so the two can't drift apart
# and reintroduce the bug from issue #14 (fresh heartbeat mtime but
# dead pid / missing tmux window -> bootstrap incorrectly no-ops).

# _watcher_heartbeat_field <heartbeat_file> <key>
# Print the value of a `key=value` line (pid / ts / target) from the
# heartbeat file, or nothing if absent. Kept here so ng and
# bootstrap.sh read the same lines with the same parser.
_watcher_heartbeat_field() {
    local hb="$1" key="$2"
    [[ -f "$hb" ]] || return 0
    awk -F= -v k="$key" '$1==k {print $2; exit}' "$hb" 2>/dev/null
}

# _watcher_lock_field <lock_file> <key>
# Print the value of a `key: value` line (pid / started_at /
# target_window / tmux_window / interval_seconds) from the watcher
# lockfile, or nothing if absent. Whitespace after the `:` is trimmed.
_watcher_lock_field() {
    local lock="$1" key="$2"
    [[ -f "$lock" ]] || return 0
    # Match `^<key>:` then strip the prefix with sub() so any colons
    # inside the value (e.g. an ISO-8601 timestamp) are preserved.
    awk -v k="$key" '
        $0 ~ "^"k":" {
            sub("^"k":[[:space:]]*", "")
            print
            exit
        }' "$lock" 2>/dev/null
}

# _watcher_heartbeat_age <heartbeat_file>
# Prints the age in seconds of the heartbeat file's mtime. If the file
# is missing or mtime can't be read, prints a very large number (so
# callers compare "age > cutoff" without needing to special-case).
_watcher_heartbeat_age() {
    local hb="$1" now hb_mtime
    now=$(date +%s)
    if [[ -f "$hb" ]]; then
        hb_mtime=$(date +%s -r "$hb" 2>/dev/null || echo 0)
    else
        hb_mtime=0
    fi
    echo $(( now - hb_mtime ))
}

# ---------------------------------------------------------------------------
# Sandbox gate (your-org/nexus-code#350)
#
# The agent-sandbox is a SECURITY wrapper, not a runtime dependency: the
# nexus is plain bash + tmux + gh and runs anywhere. But running OUTSIDE
# the sandbox means the orchestrator and every worker `claude` execute
# UNCONFINED — a runaway agent can write anywhere the user can. The
# honest contract is therefore:
#
#   in-sandbox                       -> start normally (flag irrelevant)
#   out-of-sandbox, not accepted     -> REFUSE (fail loud)
#   out-of-sandbox, explicitly opted -> start, but WARN every time
#
# The opt-out is `--i-accept-no-sandbox` (threaded by entry.sh and
# launcher.sh) or the env var NEXUS_I_ACCEPT_NO_SANDBOX=1. Because the
# stack self-heals (the supervisor, version-restart, and bootstrap-
# recover all re-run launcher.sh WITHOUT carrying the original flag), a
# one-time acceptance is PERSISTED as a marker file in the state dir so
# those relaunches inherit it instead of refusing mid-recovery. The
# marker is per-NEXUS_ROOT and records who/when, so the choice is
# auditable. Writing the marker by hand is itself a deliberate opt-out —
# equivalent to passing the flag — so this gate never claims to be
# unbypassable; its job is to stop an ACCIDENTAL unconfined run, which a
# fail-loud default does.

# _nexus_in_sandbox
#
# Return 0 iff running inside the agent-sandbox. Canonical signal:
# SANDBOX_ACTIVE=1 AND a non-empty SANDBOX_PROJECT_DIR — the same markers
# monitor/bootstrap-install.sh, monitor/watcher/entry.sh, and
# monitor/write-probe.sh gate on. The sandbox sets both at session
# creation; outside the sandbox neither is set. A user could export them
# by hand to fake "in sandbox", but that is a deliberate act equivalent
# to opting out, so it never weakens the accidental-run protection.
_nexus_in_sandbox() {
    [[ "${SANDBOX_ACTIVE:-}" == "1" && -n "${SANDBOX_PROJECT_DIR:-}" ]]
}

# _nexus_no_sandbox_marker <state_dir>
# Path of the persisted out-of-sandbox acceptance marker.
_nexus_no_sandbox_marker() {
    printf '%s/no-sandbox-accepted' "${1:?state_dir required}"
}

# _nexus_no_sandbox_accepted <state_dir>
# Return 0 iff an out-of-sandbox run has been accepted — either the
# persisted marker exists or NEXUS_I_ACCEPT_NO_SANDBOX=1 is set in the
# environment (the latter is the non-file channel used by tests and by
# callers that prefer not to leave a file).
_nexus_no_sandbox_accepted() {
    local state_dir="${1:?state_dir required}"
    [[ -f "$(_nexus_no_sandbox_marker "$state_dir")" ]] && return 0
    [[ "${NEXUS_I_ACCEPT_NO_SANDBOX:-}" == "1" ]]
}

# _nexus_sandbox_gate <state_dir> <flag_set:0|1> [context-label]
#
# The decision, single-sourced so entry.sh and launcher.sh emit
# identical semantics:
#   - in-sandbox                          -> return 0, silent
#   - flag set / env / prior marker       -> return 0, WARN to stderr
#       (and record the marker when the flag was passed this run)
#   - otherwise                           -> return 1, LOUD refusal
# The caller chooses its own exit code on a non-zero return.
_nexus_sandbox_gate() {
    local state_dir="${1:?state_dir required}"
    local flag="${2:-0}"
    local ctx="${3:-nexus}"

    # In-sandbox: the flag is irrelevant and the marker is never
    # consulted, so the normal path sees ZERO behaviour change.
    if _nexus_in_sandbox; then
        return 0
    fi

    local marker
    marker=$(_nexus_no_sandbox_marker "$state_dir")

    if [[ "$flag" == "1" ]] || _nexus_no_sandbox_accepted "$state_dir"; then
        # Persist the acceptance the FIRST time the flag is passed, so
        # later self-heal relaunches (which don't carry the flag) inherit
        # it. Best-effort: a failed write just means the operator may
        # have to re-pass the flag on the next manual start.
        if [[ "$flag" == "1" && ! -f "$marker" ]]; then
            mkdir -p "$state_dir" 2>/dev/null || true
            {
                printf 'accepted_at: %s\n' "$(date -Is 2>/dev/null || echo unknown)"
                printf 'user: %s\n'        "$(id -un 2>/dev/null || echo unknown)"
                printf 'host: %s\n'        "$(hostname 2>/dev/null || echo unknown)"
                printf 'context: %s\n'     "$ctx"
            } > "$marker" 2>/dev/null || true
        fi
        {
            echo "$ctx: WARNING — starting OUTSIDE the agent-sandbox (--i-accept-no-sandbox)."
            echo "  No kernel-enforced filesystem isolation: a runaway Claude Code agent can"
            echo "  write anywhere your user can. Acceptance recorded at: $marker"
        } >&2
        return 0
    fi

    {
        echo "$ctx: REFUSING to start the nexus outside the agent-sandbox."
        echo
        echo "What's missing: the agent-sandbox provides kernel-enforced filesystem"
        echo "isolation, signalled by SANDBOX_ACTIVE / SANDBOX_PROJECT_DIR — both unset"
        echo "here. Without it the orchestrator and every worker run UNCONFINED; a"
        echo "runaway agent can write anywhere your user can."
        echo
        echo "To proceed, pick one:"
        echo "  - RECOMMENDED — launch inside the sandbox:"
        echo "        cd <nexus-root>"
        echo "        agent-sandbox tmux new-session ./watcher"
        echo "  - Or, accepting the loss of kernel-enforced isolation, opt out explicitly:"
        echo "        ./watcher --i-accept-no-sandbox"
        echo "    (acceptance is recorded so the stack can self-heal without re-passing it)"
    } >&2
    return 1
}

# _nexus_watcher_lock_held <state_dir>
#
# Return 0 iff a live process holds the instance flock for this
# NEXUS_ROOT — i.e. a live watcher owns the state dir, EVEN IF it lives
# in a different pid namespace or on a different host. Thin namespace-
# agnostic wrapper around _nexus_instance_lock_live, used by
# _watcher_alive to avoid false-reporting a cross-namespace peer watcher
# as dead (your-org/nexus-code#350 — Connor's split-topology failure).
_nexus_watcher_lock_held() {
    local state_dir="${1:?state_dir required}"
    _nexus_instance_lock_live "$state_dir/nexus-instance.lock" >/dev/null 2>&1
}

# _watcher_pid_is_live_watcher <pid>
#
# Return 0 iff <pid> is alive AND is a nexus watcher process (a
# `monitor/watcher/main.sh` invocation). Return 1 otherwise (no pid,
# non-numeric, dead, or a live process that is NOT a watcher).
#
# Why this is stricter than a bare `kill -0`: after a machine or
# container restart the PID namespace resets and low PIDs get recycled
# to unrelated processes. A stale lock/pid file naming such a recycled
# PID (the recurring `pid=13` in watcher.log) makes `kill -0 <pid>`
# succeed against a process that is NOT the watcher, so recovery
# refuses to start and the whole stack stays dead until a human
# intervenes (incident 2026-06-07). Validating the process identity via
# its argv closes that hole: an unrelated process at the recycled PID
# fails the cmdline match, the stale lock is correctly treated as dead,
# and recovery proceeds.
#
# Identity source (first readable one wins):
#   1. /proc/<pid>/cmdline  — Linux, the production path.
#   2. ps -o args= -p <pid> — portable fallback.
#   3. neither readable     — fall back to bare `kill -0` (already
#      passed above) so we are never MORE conservative than the
#      historical behaviour on exotic hosts without /proc or ps. There
#      a false "alive" is recoverable via `launcher.sh --replace`,
#      whereas a false "dead" could race two watchers onto one state
#      dir — so when we genuinely cannot inspect argv we keep the old
#      permissive semantics.
#
# The match looks ONLY at the program slot — argv[0] (the watcher when
# exec'd directly) or argv[1] (the script when run as `bash main.sh`).
# Restricting to those two positions is what keeps a worker `claude`
# whose PROMPT merely quotes the watcher path (issues #57/#96) from
# false-positiving: a quoted path lands in a later argument, never in
# the program slot. A bare substring scan of the whole argv would
# reintroduce that exact false-positive class.
_watcher_pid_is_live_watcher() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1

    local -a argv=()
    if [[ -r "/proc/$pid/cmdline" ]]; then
        # cmdline is NUL-delimited; read each argument as an element.
        local arg
        while IFS= read -r -d '' arg; do argv+=("$arg"); done \
            < "/proc/$pid/cmdline" 2>/dev/null
    elif command -v ps >/dev/null 2>&1; then
        # ps space-joins argv (we lose exact tokenisation, but ps is
        # only the non-Linux fallback). Word-split on whitespace.
        local line
        line=$(ps -o args= -p "$pid" 2>/dev/null)
        # shellcheck disable=SC2206
        argv=( $line )
    else
        # No way to inspect argv — preserve legacy kill -0 semantics.
        return 0
    fi

    # Alive but no argv (zombie / kernel thread): not our watcher.
    (( ${#argv[@]} )) || return 1

    local slot
    for slot in 0 1; do
        case "${argv[slot]:-}" in
            */monitor/watcher/main.sh|monitor/watcher/main.sh) return 0 ;;
        esac
    done
    return 1
}

# _nexus_instance_lock_live <lockfile>
#
# Return 0 (and print the holder's metadata block on stdout) if some
# process currently holds an exclusive flock on <lockfile> — i.e. a
# live nexus watcher owns this NEXUS_ROOT's state dir. Return 1 if the
# lock is free (no live holder) or the file is absent.
#
# WHY flock and not the pid files. monitor/.state/ is a SHARED rw bind
# mount, but every agent-sandbox cockpit runs under `bwrap
# --unshare-pid`, so a *peer* sandbox's watcher pid lives in a
# different pid namespace and is invisible in this namespace's /proc.
# Every pid-based guard we have (_watcher_pid_is_live_watcher,
# acquire_lock, the launcher pidfile check) therefore reads a live peer
# watcher as DEAD and would clobber its shared state. An flock is keyed
# by the kernel on the inode + open-file-description, NOT the pid — two
# processes in different pid namespaces opening the same inode still
# contend on the same lock, and on the NFSv3 state mount
# (local_lock=none) the request is forwarded to the server's NLM so the
# lock also holds across HOSTS. flock is thus the one primitive that
# crosses both boundaries the pid checks go blind across.
#
# The probe is non-destructive: it opens O_RDWR without O_TRUNC, tries a
# non-blocking acquire, and releases immediately on success — so it
# neither disturbs a live holder's metadata nor blocks a legitimate
# successor that is about to take the lock. Liveness is the flock state
# itself; the file's text is advisory diagnostics only. The lock
# auto-releases when the holder dies (even on SIGKILL — the kernel
# closes its fds), so there is no stale-lock class to reclaim.
_nexus_instance_lock_live() {
    local lockfile="${1:?lockfile required}"
    # Absent file ⇒ no holder. Guard before the O_CREAT open below so a
    # pure probe never litters a lock file where none existed.
    [[ -e "$lockfile" ]] || return 1
    local fd
    exec {fd}<>"$lockfile" 2>/dev/null || return 1
    if flock -n "$fd"; then
        # Acquired ⇒ nobody held it ⇒ free. Release + close, report free.
        flock -u "$fd" 2>/dev/null || true
        exec {fd}>&- 2>/dev/null || true
        return 1
    fi
    # Could not acquire ⇒ a live holder exists. Dirty-read its metadata
    # for the caller's refusal message, then report held.
    exec {fd}>&- 2>/dev/null || true
    cat "$lockfile" 2>/dev/null
    return 0
}

# _nexus_boot_id
#
# Print this machine's boot id — a UUID the kernel regenerates on every
# boot. Empty if unreadable. Recorded in the lock file so a same-host
# refusal can tell "the holder's machine is still up" (boot id matches)
# from "this host rebooted since the lock was taken, the holder is dead,
# the lock is a stale NFS remnant" (boot id differs).
_nexus_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

# _nexus_instance_lock_metadata
#
# Emit the advisory metadata block recorded in the instance lock file at
# acquire time — "all helpful info" for the refusal message and the
# --instance-status inspector (operator ask on PR #281). Liveness is the
# flock itself; this text is diagnostics only, never trusted for the
# guard decision. One writer, so launcher/main/status read a stable
# field set. No secrets — host/pid/sandbox path/tmux socket/user only.
_nexus_instance_lock_metadata() {
    printf 'pid: %s\n'         "$$"
    printf 'host: %s\n'        "$(hostname 2>/dev/null || echo unknown)"
    printf 'boot_id: %s\n'     "$(_nexus_boot_id)"
    printf 'pid_ns: %s\n'      "$(readlink /proc/self/ns/pid 2>/dev/null || echo unknown)"
    printf 'sandbox: %s\n'     "${SANDBOX_PROJECT_DIR:-none}"
    printf 'tmux: %s\n'        "${TMUX:-none}"
    printf 'user: %s\n'        "$(id -un 2>/dev/null || echo unknown)"
    printf 'nexus_root: %s\n'  "${NEXUS_ROOT:-unknown}"
    printf 'started_at: %s\n'  "$(date -Is)"
}

# _nexus_instance_lock_field <metadata-text> <key>
#
# Pull a single `key: value` line out of the lock metadata. Prefix match
# (not an FS=: split) because several values legitimately contain colons
# — pid_ns `pid:[4026531836]`, the ISO `started_at`, a tmux socket path.
#
# Candidate for _fm_get migration in the instance-lock phase — see #405 P2.
# (Deferred deliberately: this reads a text STRING, not a file, and the
# instance-lock machinery is a separately gated high-risk phase.)
_nexus_instance_lock_field() {
    local text="$1" key="$2" line
    while IFS= read -r line; do
        if [[ "$line" == "$key: "* ]]; then
            printf '%s\n' "${line#"$key": }"
            return 0
        fi
    done <<<"$text"
    return 1
}

# _nexus_instance_lock_assess <metadata-text> [cur_host] [cur_boot_id]
#
# Classify a HELD instance lock from its recorded metadata so the
# refusal message can answer operator's question — "could the flock be
# stale?" — honestly for each case. The flock being held is the
# authority; this only annotates CONFIDENCE and the right resolution.
# Echoes exactly one verdict token:
#
#   live-local    recorded host == this host AND boot id matches → the
#                 holder's machine is the same boot as ours, so it is a
#                 genuinely live peer in another sandbox / pid namespace.
#                 (Same-host flock — incl. NFS local arbitration — is
#                 trustworthy; never stale.)
#   stale-reboot  recorded host == this host BUT boot id differs → this
#                 machine has rebooted since the lock was taken, so the
#                 recorded holder cannot still be alive. A held flock in
#                 that state is a stale remnant the NFS lock manager
#                 never reclaimed → safe to clear.
#   live-remote   recorded host != this host → held by a peer on another
#                 host via the NFS NLM. Authoritative WHILE that host is
#                 up (then it is a live peer); if that host is down/gone
#                 it may be a stale cross-host lock — unverifiable from
#                 here, so we refuse conservatively and tell the user.
#   unknown       metadata predates host/boot recording → cannot classify.
#
# cur_host/cur_boot_id are injectable so the classifier is a pure
# function under test; production calls read them live.
_nexus_instance_lock_assess() {
    local text="$1"
    local cur_host="${2:-$(hostname 2>/dev/null || echo unknown)}"
    local cur_boot="${3:-$(_nexus_boot_id)}"
    local rec_host rec_boot
    rec_host=$(_nexus_instance_lock_field "$text" host) || rec_host=""
    rec_boot=$(_nexus_instance_lock_field "$text" boot_id) || rec_boot=""
    if [[ -z "$rec_host" ]]; then echo unknown; return 0; fi
    if [[ "$rec_host" != "$cur_host" ]]; then echo live-remote; return 0; fi
    if [[ -n "$rec_boot" && -n "$cur_boot" && "$rec_boot" != "$cur_boot" ]]; then
        echo stale-reboot; return 0
    fi
    echo live-local
}

# _nexus_instance_lock_refusal <metadata-text> <lockfile> [nexus_root]
#
# Compose the situation-aware, actionable refusal block printed when a
# second start is blocked. Centralized so the launcher fast-fail and
# main.sh's authoritative gate emit IDENTICAL guidance. Built FROM the
# recorded metadata: states the suspected situation, the assessment, the
# NORMAL resolution (use / close / --replace the other instance), and
# the FALSE-POSITIVE resolution (verify, then remove the stale lock)
# with the load-bearing caveat that `rm` is only safe when no live peer
# holds it. Caller redirects stdout to its own stderr/log.
_nexus_instance_lock_refusal() {
    local text="$1" lockfile="$2" nexus_root="${3:-${NEXUS_ROOT:-unknown}}"
    local cur_host verdict rec_host rec_pid rec_sandbox rec_started rec_tmux
    cur_host=$(hostname 2>/dev/null || echo unknown)
    verdict=$(_nexus_instance_lock_assess "$text")
    rec_host=$(_nexus_instance_lock_field "$text" host) || rec_host="?"
    rec_pid=$(_nexus_instance_lock_field "$text" pid) || rec_pid="?"
    rec_sandbox=$(_nexus_instance_lock_field "$text" sandbox) || rec_sandbox="?"
    rec_started=$(_nexus_instance_lock_field "$text" started_at) || rec_started="?"
    rec_tmux=$(_nexus_instance_lock_field "$text" tmux) || rec_tmux="?"

    echo "  NEXUS_ROOT = $nexus_root"
    echo "  lock file  = $lockfile"
    echo "  Suspected holder (advisory metadata recorded in the lock file):"
    echo "    started ${rec_started}  host ${rec_host}  pid ${rec_pid}  sandbox ${rec_sandbox}  tmux ${rec_tmux}"
    case "$verdict" in
        live-local)
            echo "  Assessment: a nexus cockpit appears to be running on THIS host (${rec_host}) in"
            echo "    another sandbox / pid namespace. Same-host flock is authoritative — treat it as LIVE."
            ;;
        stale-reboot)
            echo "  Assessment: the lock records host ${rec_host}, but this machine has REBOOTED since"
            echo "    (boot id changed) — the recorded holder (pid ${rec_pid}) cannot still be alive."
            echo "    This is almost certainly a STALE lock the NFS lock manager never reclaimed."
            ;;
        live-remote)
            echo "  Assessment: the lock is held by a peer on host ${rec_host} (you are on ${cur_host})."
            echo "    Over NFS that lock is authoritative WHILE ${rec_host} is up — if it is, that peer"
            echo "    is LIVE. If ${rec_host} is down or gone, this may be a stale cross-host lock."
            ;;
        *)
            echo "  Assessment: lock metadata predates host/boot recording — cannot auto-classify."
            echo "    Treat it as a live peer unless you can confirm otherwise."
            ;;
    esac
    echo "  Normal resolution (a LIVE peer — the supported topology is ONE cockpit per NEXUS_ROOT):"
    echo "    - use the other instance, or close it (find it via the host / sandbox / tmux above);"
    echo "    - same sandbox? take it over:  monitor/watcher/launcher.sh --replace"
    echo "    - different sandbox/host? you cannot --replace a peer you cannot see — stop it in its"
    echo "      own sandbox; or run THIS instance against a DIFFERENT NEXUS_ROOT."
    echo "  False-positive resolution (the holder is gone / its host is down — stale lock):"
    echo "    - confirm first:  monitor/watcher/launcher.sh --instance-status"
    if [[ "$verdict" == "live-remote" ]]; then
        echo "      (and confirm host ${rec_host} is actually down — you cannot see its processes from here);"
    fi
    echo "    - then clear it:  rm $lockfile"
    echo "    - CAVEAT: only rm when you are SURE no live peer holds it. Removing the file while a peer"
    echo "      is alive lets BOTH run (the peer keeps the old inode's lock; you create + lock a new file)."
}

# ===========================================================================
# Cross-host instance heartbeat (nexus instance lock — cross-machine layer).
#
# The flock on nexus-instance.lock is the AUTHORITATIVE *same-host* singleton
# guard: two cockpits on one host — even in different `bwrap --unshare-pid`
# namespaces — contend on the inode, so the second refuses. But flock over
# NFSv3 relies on the server's NLM forwarding locks BETWEEN CLIENTS, which is
# unreliable in practice (implementation-dependent, and empirically it did
# not block a second cockpit on another host sharing this NFS state dir). So
# a second cockpit on a DIFFERENT host can see the flock as free and start,
# racing the live instance on the shared monitor/.state.
#
# The heartbeat is the best-effort cross-host layer. The live watcher
# refreshes a beacon file (nexus-instance.heartbeat) every loop iteration; a
# starter on another host reads it and REFUSES while the beacon is FRESH,
# taking over only once it goes STALE (holder dead/gone). Same-host decisions
# stay with the flock (instant, reliable); the heartbeat only arbitrates the
# cross-host case the flock cannot see. Writes are atomic (tmp + rename) so a
# reader never sees a torn file, and — critically — the beacon is a SEPARATE
# file from the flock target, so refreshing it never renames the inode the
# held flock keys on.
# ===========================================================================

# _nexus_instance_heartbeat_path <state_dir> — canonical beacon path.
_nexus_instance_heartbeat_path() {
    printf '%s/nexus-instance.heartbeat\n' "${1:?state_dir required}"
}

# _nexus_instance_staleness_window
#
# Seconds a cross-host beacon may age before it is treated as stale (holder
# dead → takeover allowed). Deliberately GENEROUS relative to the ≤10s loop
# refresh cadence: a too-SHORT window risks a false takeover that evicts a
# live remote peer during a transient stall (slow loop, cc-update restart);
# a too-LONG one only delays reclaiming a genuinely-dead remote holder. The
# default (600s = 10 min) survives a cc-update self-restart gap with wide
# margin. Override via NEXUS_INSTANCE_HEARTBEAT_STALENESS (_config.sh exports
# it from monitor.instance_heartbeat_staleness_seconds for the watcher).
_nexus_instance_staleness_window() {
    local w="${NEXUS_INSTANCE_HEARTBEAT_STALENESS:-}"
    [[ "$w" =~ ^[0-9]+$ ]] && { printf '%s\n' "$w"; return 0; }
    printf '600\n'
}

# _nexus_instance_gen_nonce
#
# A per-INSTANCE identity token, generated ONCE at watcher startup and pinned
# in NEXUS_INSTANCE_NONCE for that process's lifetime. The beacon records it so
# the per-loop self-fence (see _nexus_instance_fence_decision) can tell "this
# beacon is MINE" from "a DIFFERENT instance overwrote it" at a finer grain
# than host — two cockpits on ONE host share a hostname but get distinct
# nonces, so a same-host takeover still fences. A random UUID when the kernel
# offers one; otherwise epoch+pid+RANDOM, which is unique enough for the job
# (the fence only ever compares a live beacon against the writer's own token).
_nexus_instance_gen_nonce() {
    local u
    u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) && [[ -n "$u" ]] && { printf '%s\n' "$u"; return 0; }
    printf '%s-%s-%s\n' "$(date +%s 2>/dev/null || echo 0)" "$$" "${RANDOM:-0}"
}

# _nexus_instance_heartbeat_write <path>
#
# Atomically write the beacon from the live env. tmp + rename so a concurrent
# reader always sees a COMPLETE file (old or new), never a torn one. Records
# host/boot_id/pid_ns/pid/tmux/nexus_root plus the staleness clock (`epoch`,
# integer seconds), a human `ts`, and the per-instance `nonce` (empty when the
# caller has not pinned NEXUS_INSTANCE_NONCE — an older watcher, so the field
# is absent and readers fall back to host identity; see the fence-decision
# compatibility rule). Best-effort: a failed write just means a transient
# absent/old beacon — the flock still guards the same-host case.
_nexus_instance_heartbeat_write() {
    local path="${1:?path required}" tmp
    tmp="${path}.tmp.$$"
    {
        printf 'host: %s\n'       "$(hostname 2>/dev/null || echo unknown)"
        printf 'boot_id: %s\n'    "$(_nexus_boot_id)"
        printf 'pid_ns: %s\n'     "$(readlink /proc/self/ns/pid 2>/dev/null || echo unknown)"
        printf 'pid: %s\n'        "$$"
        printf 'tmux: %s\n'       "${TMUX:-none}"
        printf 'nexus_root: %s\n' "${NEXUS_ROOT:-unknown}"
        printf 'nonce: %s\n'      "${NEXUS_INSTANCE_NONCE:-}"
        printf 'epoch: %s\n'      "$(date +%s)"
        printf 'ts: %s\n'         "$(date -Is)"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# _nexus_instance_remote_verdict <hb_text> <cur_host> <now_epoch> <window>
#
# Classify a heartbeat beacon from the vantage of a caller whose same-host
# flock probe already found the lock FREE (so any live holder is either
# nonexistent or on ANOTHER host the flock can't see). Pure — all inputs
# injected, so it is fully unit-testable. Echoes exactly one token:
#
#   none          empty/absent beacon → nothing to arbitrate (free).
#   same-host     beacon recorded THIS host → the flock (free) is
#                 authoritative same-host, so that holder is dead → free.
#   live-remote   beacon from another host, epoch FRESH (age <= window, or
#                 future-dated via clock skew) → a live peer → REFUSE.
#   stale-remote  beacon from another host, epoch STALE (age > window) →
#                 holder dead/gone → free (take over + log).
#   corrupt       beacon present but host missing, or a remote beacon whose
#                 epoch is not an integer → cannot prove staleness → the
#                 caller decides whether to fail closed.
_nexus_instance_remote_verdict() {
    local text="$1" cur_host="$2" now="$3" window="$4"
    [[ -n "$text" ]] || { echo none; return 0; }
    local rec_host rec_epoch
    rec_host=$(_nexus_instance_lock_field "$text" host) || rec_host=""
    rec_epoch=$(_nexus_instance_lock_field "$text" epoch) || rec_epoch=""
    [[ -n "$rec_host" ]] || { echo corrupt; return 0; }
    if [[ "$rec_host" == "$cur_host" ]]; then echo same-host; return 0; fi
    [[ "$rec_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { echo corrupt; return 0; }
    local age=$(( now - rec_epoch ))
    if (( age < 0 )); then echo live-remote; return 0; fi   # future-dated → fresh
    if (( age <= window )); then echo live-remote; else echo stale-remote; fi
}

# _nexus_instance_fence_decision <hb_text> <cur_host> <cur_nonce> <now_epoch> <window>
#
# The per-loop SELF-FENCE decision for the RUNNING watcher (the one that holds
# the flock and refreshes the beacon each iteration). D4: the acquire/preflight
# guards check the beacon ONCE at start, then the loop UNCONDITIONALLY refreshes
# it. If this loop wedges (compose_emit stall history) past the staleness
# window, a starter on another host legitimately takes over and writes ITS
# beacon; when this loop un-wedges it would blindly overwrite the newer holder's
# beacon → two live cockpits ping-ponging one beacon. This decision closes that:
# before each refresh, classify the beacon currently on disk. Pure — all inputs
# injected, fully unit-testable. Echoes exactly one token:
#
#   refresh   keep owning the beacon — it is MINE, absent, stale (dead holder's
#             leftover, reclaim it), or unclassifiable (a corrupt beacon cannot
#             PROVE supersession, and the running watcher must never self-fence
#             on garbage — fail toward staying alive; the acquire-time guard,
#             not this one, is where a corrupt beacon fails closed).
#   fence     a DIFFERENT instance's beacon is present AND fresh (age <= window)
#             → this instance has been SUPERSEDED → stand down, do NOT overwrite.
#
# Identity ("mine" vs "different") and the backward-compatibility rule:
#   - When BOTH the beacon and this instance carry a nonce, identity is the
#     nonce: same nonce ⇒ mine; different nonce ⇒ a different instance (on ANY
#     host — this is what makes a SAME-HOST second instance fence).
#   - When the beacon has NO nonce (written by a watcher predating this field)
#     OR this instance has no pinned nonce, fall back to HOST identity: same
#     host ⇒ mine, different host ⇒ different. Rationale: an old-format beacon
#     on our own host is our own pre-upgrade leftover (the flock is the
#     authoritative same-host singleton, so no OTHER same-host cockpit can be
#     refreshing it) → treating it as mine avoids a spurious stand-down; an
#     old-format beacon from another fresh host is a genuine live remote peer →
#     fence. A missing nonce on EITHER side therefore never, by itself, forces
#     a fence.
_nexus_instance_fence_decision() {
    local text="$1" cur_host="$2" cur_nonce="$3" now="$4" window="$5"
    [[ -n "$text" ]] || { echo refresh; return 0; }   # absent/empty → ours to write
    local rec_host rec_nonce rec_epoch
    rec_host=$(_nexus_instance_lock_field "$text" host)  || rec_host=""
    rec_nonce=$(_nexus_instance_lock_field "$text" nonce) || rec_nonce=""
    rec_epoch=$(_nexus_instance_lock_field "$text" epoch) || rec_epoch=""
    # No host, or unparseable clock → cannot prove supersession → keep writing.
    [[ -n "$rec_host" ]] || { echo refresh; return 0; }
    [[ "$rec_epoch" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] || { echo refresh; return 0; }
    # Only a FRESH beacon can supersede us; a stale one is a dead holder's (or
    # our own) leftover → reclaim by refreshing. Future-dated (clock skew) is
    # treated as fresh, matching _nexus_instance_remote_verdict.
    local age=$(( now - rec_epoch ))
    if (( age >= 0 && age > window )); then echo refresh; return 0; fi
    # Fresh. Identity: nonce when both sides have one, else host (compat rule).
    if [[ -n "$rec_nonce" && -n "$cur_nonce" ]]; then
        [[ "$rec_nonce" == "$cur_nonce" ]] && { echo refresh; return 0; }
        echo fence; return 0
    fi
    if [[ "$rec_host" == "$cur_host" ]]; then echo refresh; else echo fence; fi
}

# _nexus_instance_beacon_loop_step <hbfile> <cur_host> <cur_nonce> <now_epoch> <window>
#
# The per-loop beacon step wired into main.sh's steady-state loop (the D4 fix
# site). Reads the beacon on disk, runs _nexus_instance_fence_decision, and:
#   - refresh → rewrites the beacon (via _nexus_instance_heartbeat_write, which
#               stamps a fresh epoch + our nonce) and returns 0. A best-effort
#               write failure is swallowed (returns 0): a momentarily-aged
#               beacon is harmless, and it must NOT be mistaken for a fence.
#   - fence   → does NOT touch the beacon (the newer holder owns it now) and
#               returns 2 so the caller stands down via its clean-shutdown path.
# This is the seam the loop-integration test drives: exercising it with a real
# beacon file reaches the exact refresh site the loop calls. host/nonce/now are
# injected so the test is hermetic; production passes the live values.
_nexus_instance_beacon_loop_step() {
    local hbfile="${1:?hbfile required}" cur_host="$2" cur_nonce="$3" now="$4" window="$5"
    local hb_text decision
    hb_text=$(cat "$hbfile" 2>/dev/null || true)
    decision=$(_nexus_instance_fence_decision "$hb_text" "$cur_host" "$cur_nonce" "$now" "$window")
    if [[ "$decision" == "fence" ]]; then
        return 2
    fi
    _nexus_instance_heartbeat_write "$hbfile" 2>/dev/null || true
    return 0
}

# _nexus_instance_guard_decision <flock_held> <lock_text> <hb_text> \
#                                <cur_host> <cur_pid_ns> <now> <window>
#
# The single whole-cockpit-start decision, combining the same-host flock
# state with the cross-host heartbeat. Pure — all inputs injected. <flock_held>
# is 1 when _nexus_instance_lock_live found a holder (same-host or NLM-visible
# peer), else 0. Echoes exactly one token:
#
#   free           no live instance → PROCEED (cold start, or stale takeover).
#   self           the holder is THIS cockpit (same host AND same pid
#                  namespace) → PROCEED (own recovery / re-entry — never a
#                  coexistence). This is what keeps a within-instance recovery
#                  (boot-recover, svc.sh up while our own watcher is alive)
#                  from self-refusing.
#   refuse-local   a DIFFERENT cockpit holds the flock (co-located sandbox in
#                  another pid ns, or an NLM-visible remote) → REFUSE.
#   refuse-remote  a live peer on another host (fresh heartbeat) → REFUSE.
#   refuse-corrupt lock/heartbeat present but unidentifiable → FAIL CLOSED.
_nexus_instance_guard_decision() {
    local flock_held="$1" lock_text="$2" hb_text="$3"
    local cur_host="$4" cur_pid_ns="$5" now="$6" window="$7"
    if [[ "$flock_held" == "1" ]]; then
        local rec_host rec_pid_ns
        rec_host=$(_nexus_instance_lock_field "$lock_text" host) || rec_host=""
        rec_pid_ns=$(_nexus_instance_lock_field "$lock_text" pid_ns) || rec_pid_ns=""
        [[ -n "$rec_host" ]] || { echo refuse-corrupt; return 0; }
        if [[ "$rec_host" == "$cur_host" && -n "$rec_pid_ns" && "$rec_pid_ns" == "$cur_pid_ns" ]]; then
            echo self; return 0
        fi
        echo refuse-local; return 0
    fi
    local v
    v=$(_nexus_instance_remote_verdict "$hb_text" "$cur_host" "$now" "$window")
    case "$v" in
        none|same-host|stale-remote) echo free ;;
        live-remote)                 echo refuse-remote ;;
        *)                           echo refuse-corrupt ;;
    esac
}

# _nexus_instance_preflight <state_dir> <nexus_root>
#
# The whole-cockpit-start gate for entry.sh + bootstrap-recover.sh, run
# BEFORE spawning the watcher/orchestrator/services. Reads the live
# host/pid_ns/clock, probes the flock, reads the heartbeat, and decides via
# _nexus_instance_guard_decision. On a refuse-* verdict it prints an
# actionable block to stderr and returns 1; on free/self it returns 0. It
# fails OPEN only if the state dir path itself is unusable (returns 0 with a
# warning) — a bug in the gate must never deadlock a legitimate start, and
# the watcher's own acquire_instance_lock remains the same-host backstop.
_nexus_instance_preflight() {
    local state_dir="${1:?state_dir required}" nexus_root="${2:-${NEXUS_ROOT:-unknown}}"
    local lockfile hbfile cur_host cur_pid_ns now window flock_held lock_text hb_text decision
    lockfile="$state_dir/nexus-instance.lock"
    hbfile=$(_nexus_instance_heartbeat_path "$state_dir")
    cur_host=$(hostname 2>/dev/null || echo unknown)
    cur_pid_ns=$(readlink /proc/self/ns/pid 2>/dev/null || echo unknown)
    now=$(date +%s 2>/dev/null || echo 0)
    window=$(_nexus_instance_staleness_window)
    if lock_text=$(_nexus_instance_lock_live "$lockfile"); then flock_held=1; else flock_held=0; fi
    hb_text=$(cat "$hbfile" 2>/dev/null || true)
    decision=$(_nexus_instance_guard_decision "$flock_held" "$lock_text" "$hb_text" \
                   "$cur_host" "$cur_pid_ns" "$now" "$window")
    case "$decision" in
        free|self) return 0 ;;
    esac
    {
        echo "REFUSING to start a nexus cockpit — another instance owns this NEXUS_ROOT (verdict: $decision)."
        echo "  NEXUS_ROOT = $nexus_root"
        case "$decision" in
            refuse-local)
                echo "  A live cockpit holds the same-host instance flock:"
                _nexus_instance_lock_refusal "$lock_text" "$lockfile" "$nexus_root"
                ;;
            refuse-remote)
                local rh rts
                rh=$(_nexus_instance_lock_field "$hb_text" host) || rh="?"
                rts=$(_nexus_instance_lock_field "$hb_text" ts) || rts="?"
                echo "  A live nexus is running on host ${rh} (heartbeat as of ${rts}); you are on ${cur_host}."
                echo "  monitor/.state is shared over NFS — two cockpits would race it (double GitHub writes,"
                echo "  emit races, double service supervision). Use the instance on ${rh}, or stop it there,"
                echo "  before starting one here."
                echo "  Beacon: $hbfile"
                echo "  If ${rh} is DOWN/gone, the beacon ages out after ${window}s and this host takes over"
                echo "  automatically. To force it now, VERIFY ${rh} is dead, then: rm $hbfile"
                ;;
            refuse-corrupt)
                echo "  The instance lock and/or heartbeat is present but UNPARSEABLE — failing closed rather"
                echo "  than risk a second instance racing the shared state dir."
                echo "    lock:      $lockfile"
                echo "    heartbeat: $hbfile"
                echo "  Inspect (monitor/watcher/launcher.sh --instance-status shows the flock holder). Once"
                echo "  SURE no live peer exists, clear the stale file(s) above and retry."
                ;;
        esac
    } >&2
    return 1
}

# ---------------------------------------------------------------------------
# Liveness vs. progress (nexus-code#491)
#
# The heartbeat used to be bumped ONLY at the end of a complete compose
# cycle (#236), which made it a WORKLOAD signal: the cycle's duration
# scales with worker count while every liveness threshold was a
# constant, so at >=12 workers a perfectly healthy watcher was
# GUARANTEED to be reported DOWN — and every remedy keyed on that
# verdict killed it mid-loop (the 2026-07-09 restart storm). The
# signals are now decoupled:
#
#   watcher-heartbeat  LIVENESS. Bumped by a background ticker inside
#                      the watcher process at a fixed cadence
#                      (monitor.watcher.heartbeat_tick_seconds) that is
#                      workload-independent BY CONSTRUCTION. Fresh =
#                      the process exists and is being scheduled.
#   watcher-progress   FORWARD PROGRESS. Bumped by the main scheduler
#                      loop every iteration and at startup-sweep /
#                      compose stage boundaries. Stalls when the loop
#                      is genuinely wedged (deadlock, hang).
#   watcher-cycle      FUNCTIONAL PROOF. Bumped at the end of each
#                      complete compose cycle (the old heartbeat
#                      semantics), carrying the MEASURED loop period
#                      (period_s + ema_s). Stalls when the loop runs
#                      but the emit path never completes (the
#                      2026-06-18 class).
#
# Old watchers (pre-#491) write none of the new files; every probe
# below degrades to the historical heartbeat-age semantics when the
# new signals are absent, and additionally accepts watcher.log /
# watcher-scheduler.jsonl mtime advance as progress so a live pre-fix
# watcher under load reads BUSY, never DOWN.

# _watcher_progress_age <state_dir> [<pgid>]
# Seconds since the watcher last demonstrated forward progress: the
# freshest of watcher-progress, watcher-cycle, the scheduler telemetry
# JSONL, watcher.log — and, when a pgid is supplied, the youngest
# member fork in the watcher's process group ("forking children" is a
# stronger liveness signal than either the heartbeat or the log,
# nexus-code#491: the live watcher observed at 17:45 had no log line
# for ~350s yet forked fresh tac/jq continuously). Prints a very
# large number when no progress signal exists at all.
_watcher_progress_age() {
    local sd="${1:?state_dir required}" pgid="${2:-}" now best=-1 f m a
    now=$(date +%s)
    for f in "$sd/watcher-progress" "$sd/watcher-cycle" \
             "${MONITOR_SCHEDULER_LOG:-$sd/watcher-scheduler.jsonl}" \
             "$sd/watcher.log"; do
        [[ -f "$f" ]] || continue
        m=$(date +%s -r "$f" 2>/dev/null) || continue
        [[ "$m" =~ ^[0-9]+$ ]] || continue
        a=$(( now - m )); (( a < 0 )) && a=0
        (( best < 0 || a < best )) && best=$a
    done
    if [[ "$pgid" =~ ^[0-9]+$ ]]; then
        a=$(_watcher_youngest_member_age "$pgid")
        (( a < 999999999 )) && (( best < 0 || a < best )) && best=$a
    fi
    (( best < 0 )) && best=999999999
    printf '%d' "$best"
}

# _watcher_cycle_period <state_dir>
# The measured compose-cycle period (smoothed ema_s, falling back to
# the last raw period_s) from watcher-cycle. Prints 0 when unknown.
_watcher_cycle_period() {
    local sd="${1:?state_dir required}" f="$1/watcher-cycle" p
    p=$(_watcher_heartbeat_field "$f" ema_s)
    [[ "$p" =~ ^[0-9]+$ ]] || p=$(_watcher_heartbeat_field "$f" period_s)
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    printf '%d' "$p"
}

# _watcher_wedge_cutoff <interval> [<period>]
# Progress-stall threshold: a GENEROUS multiple of the measured loop
# period (so the threshold scales with load instead of being a
# constant the workload can silently exceed), floored so a fresh boot
# with no period yet is never trigger-happy.
#   max(MONITOR_WATCHER_WEDGE_MULTIPLIER x max(period, interval),
#       MONITOR_WATCHER_WEDGE_FLOOR_SECONDS)          (defaults 4x / 900)
_watcher_wedge_cutoff() {
    local interval="${1:-60}" period="${2:-0}"
    local mult="${MONITOR_WATCHER_WEDGE_MULTIPLIER:-4}"
    local floor="${MONITOR_WATCHER_WEDGE_FLOOR_SECONDS:-900}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=60
    [[ "$period" =~ ^[0-9]+$ ]] || period=0
    [[ "$mult" =~ ^[0-9]+$ ]] || mult=4
    [[ "$floor" =~ ^[0-9]+$ ]] || floor=900
    local base=$interval
    (( period > base )) && base=$period
    local cutoff=$(( mult * base ))
    (( cutoff < floor )) && cutoff=$floor
    printf '%d' "$cutoff"
}

# _watcher_cycle_cutoff <interval> [<period>]
# Functional-stall threshold for the cycle signal — even more generous
# than the wedge cutoff (the compose watchdog may kill + re-arm slow
# cycles several times under load before one completes), but bounded:
# a loop that ticks forever without EVER completing a cycle is the
# invisible 2026-06-18 wedge and must still be caught.
#   max(MONITOR_WATCHER_CYCLE_STALL_MULTIPLIER x max(period, interval),
#       MONITOR_WATCHER_CYCLE_STALL_FLOOR_SECONDS)    (defaults 6x / 1800)
_watcher_cycle_cutoff() {
    local interval="${1:-60}" period="${2:-0}"
    local mult="${MONITOR_WATCHER_CYCLE_STALL_MULTIPLIER:-6}"
    local floor="${MONITOR_WATCHER_CYCLE_STALL_FLOOR_SECONDS:-1800}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=60
    [[ "$period" =~ ^[0-9]+$ ]] || period=0
    [[ "$mult" =~ ^[0-9]+$ ]] || mult=6
    [[ "$floor" =~ ^[0-9]+$ ]] || floor=1800
    local base=$interval
    (( period > base )) && base=$period
    local cutoff=$(( mult * base ))
    (( cutoff < floor )) && cutoff=$floor
    printf '%d' "$cutoff"
}

# _watcher_wedged <state_dir> <interval>
# Return 0 iff the watcher process should be considered WEDGED: a
# progress signal exists but has stalled past the wedge cutoff, or a
# cycle record exists but no cycle has completed within the cycle
# cutoff. Callers must have already established the process is alive —
# this predicate only judges advancement. Return 1 = advancing (or no
# signal to judge — old watcher: never claim a state that was not
# established).
_watcher_wedged() {
    local sd="${1:?state_dir required}" interval="${2:-60}"
    local period page cutoff pgid
    period=$(_watcher_cycle_period "$sd")
    # The heartbeat pid is the group leader (setsid) — fold the
    # group's fork-freshness into the progress signal.
    pgid=$(_watcher_heartbeat_field "$sd/watcher-heartbeat" pid)
    page=$(_watcher_progress_age "$sd" "$pgid")
    cutoff=$(_watcher_wedge_cutoff "$interval" "$period")
    if (( page < 999999999 )) && (( page > cutoff )); then
        return 0
    fi
    if [[ -f "$sd/watcher-cycle" ]]; then
        local cage ccutoff
        cage=$(_watcher_heartbeat_age "$sd/watcher-cycle")
        ccutoff=$(_watcher_cycle_cutoff "$interval" "$period")
        (( cage > ccutoff )) && return 0
    fi
    return 1
}

# _watcher_alive <state_dir> <interval_seconds> [<dead_cutoff_seconds>]
#
# Liveness bucket for the watcher. Checks, in priority order:
#   1. Heartbeat file present?              no  -> return 3
#   2. pid from heartbeat still alive?      no  -> return 2
#   3. heartbeat mtime age vs interval:
#        age <= 2*interval + 15            -> return 0  (fresh)
#        age <= max(5*interval, dead_cutoff) -> return 1  (stale-but-alive)
#        otherwise                         -> return 2  (very stale / DEAD)
#   4. alive (bucket 0/1) but progress/cycle stalled past the measured-
#      period-derived cutoffs (_watcher_wedged)      -> return 4 (WEDGED)
#
# Bucket 4 (nexus-code#491) means: the process exists and its liveness
# ticker beats, but NOTHING has advanced for a generous multiple of the
# observed loop period — the genuinely-wedged case. It is distinct from
# DEAD (2) so callers can report it honestly; recovery paths treat it
# as restart-worthy. A merely SLOW loop (progress advancing, cycle
# completing late) stays in bucket 0/1 — see _watcher_liveness_verdict
# for the operator-facing UP/BUSY/WEDGED/DOWN rendering.
#
# The optional 3rd arg RAISES the DEAD threshold above 5*interval (it never
# lowers it); see the body for why the continuous supervisor passes a cutoff
# above the async hang-watchdog floor. (Replaces the old, never-passed
# <watcher_window> slot — all callers pass 2 args; a stray non-numeric 3rd
# arg is ignored, preserving the 5*interval default.)
#
# The watcher runs HEADLESS (setsid, no tmux window) since the
# services-model migration, so there is no window-presence check any
# more — pid identity + heartbeat age are the whole story. The third
# parameter is retained (and ignored) so older callers that pass a
# window name keep working; drop it after the deprecation window.
#
# Prints nothing. The exit code IS the answer. See CLAUDE.md's
# "Mutual-liveness contract" for how the buckets are used.
_watcher_alive() {
    local state_dir="${1:?state_dir required}"
    local interval="${2:-60}"
    # Optional DEAD-threshold override (nexus-code#236). The default DEAD
    # bucket is 5×interval, but now the heartbeat is bumped per compose cycle
    # a continuous supervisor must give the watcher's OWN async hang-watchdog
    # (floor max(4×interval, async_timeout_floor) — typically 300s) time to
    # kill + re-arm a stalled cycle before declaring DOWN, or it races the
    # self-recovery and restarts a watcher that was about to heal itself. The
    # supervise-tick passes a cutoff ABOVE that floor; other callers omit it
    # and keep the 5×interval default. Only RAISES the threshold, never lowers.
    local dead_cutoff="${3:-}"
    local hb="$state_dir/watcher-heartbeat"
    [[ -f "$hb" ]] || return 3

    local pid
    pid=$(_watcher_heartbeat_field "$hb" pid)
    # Stricter than `kill -0`: a heartbeat pid recycled to an unrelated
    # process after a restart must read as dead, not alive, so the
    # orchestrator's bootstrap respawns instead of trusting a stale
    # heartbeat (see _watcher_pid_is_live_watcher).
    if [[ -n "$pid" ]] && ! _watcher_pid_is_live_watcher "$pid"; then
        # The pid-identity check is namespace-LOCAL: it reads
        # /proc/<pid>/cmdline (or `ps`), so a genuinely-live watcher in a
        # DIFFERENT pid namespace — the split topology of
        # your-org/nexus-code#350 (host-side watcher + sandboxed
        # orchestrator, or vice versa) — is invisible here and
        # false-reads as dead. Before declaring DEAD, consult the one
        # primitive that crosses pid-ns + host boundaries: the instance
        # flock. If a live holder owns this NEXUS_ROOT's state dir, a
        # watcher IS alive — fall through to the heartbeat-age buckets
        # below. If the flock is FREE, it is genuinely dead (the
        # recycled-pid stale-heartbeat case: the prior watcher died and
        # the kernel auto-released its flock), so preserve the strict
        # DEAD verdict that protects recovery from a stale heartbeat.
        if ! _nexus_watcher_lock_held "$state_dir"; then
            return 2
        fi
    fi

    local age fresh_cutoff very_cutoff
    age=$(_watcher_heartbeat_age "$hb")
    fresh_cutoff=$(( interval * 2 + 15 ))
    very_cutoff=$(( interval * 5 ))
    if [[ "$dead_cutoff" =~ ^[0-9]+$ ]] && (( dead_cutoff > very_cutoff )); then
        very_cutoff=$dead_cutoff
    fi
    local bucket
    if (( age <= fresh_cutoff )); then
        bucket=0
    elif (( age <= very_cutoff )); then
        bucket=1
    else
        return 2
    fi
    # Alive per pid + heartbeat — but is anything ADVANCING? A stalled
    # progress/cycle signal past the measured-period-derived cutoffs is
    # the genuinely-wedged case (nexus-code#491): the liveness ticker
    # beats for a loop that no longer moves. Distinct bucket so callers
    # never conflate it with DEAD or with merely-slow.
    if _watcher_wedged "$state_dir" "$interval"; then
        return 4
    fi
    return $bucket
}

# NOTE (nexus-code#491, revising #236): the heartbeat is now a PURE
# liveness signal (background ticker, workload-independent cadence).
# The functional "a full cycle completed recently" proof lives in
# watcher-cycle; the loop-is-moving proof lives in watcher-progress.
# `_watcher_alive` folds a stalled progress/cycle signal into bucket 4
# (WEDGED) so the silent-stall class #236 targeted is still caught —
# without the workload-as-liveness conflation that guaranteed false
# DOWN verdicts at >=12 workers.

# _watcher_liveness_verdict <state_dir> <interval_seconds> [<dead_cutoff_seconds>]
#
# THE operator-facing trichotomy (nexus-code#491), single-sourced so
# svc.sh, watcher-supervise-tick.sh, revive-watcher.sh, and ng render
# identical semantics. Prints key=value lines:
#
#   state=UP|BUSY|WEDGED|DOWN   the verdict word
#   rc=<n>                      the underlying _watcher_alive bucket
#   pid=<n>                     heartbeat pid ('' if none)
#   hb_age=<s> progress_age=<s> cycle_age=<s>
#   period_s=<s>                measured loop period (0 = unknown)
#   wedge_cutoff=<s>            active progress-stall threshold
#   reason=<text>               one-line human phrasing
#
# Verdict rules:
#   DOWN    process gone / no heartbeat / heartbeat dead-stale
#           (buckets 2,3). Reserved for ESTABLISHED facts.
#   WEDGED  alive but nothing advanced past the cutoffs (bucket 4).
#   BUSY    alive + advancing, but slower than nominal: heartbeat aging
#           (bucket 1) or the last completed cycle is older than the
#           fresh window or the measured period exceeds 2x interval.
#           A BUSY watcher is HEALTHY under load — do not restart it.
#   UP      alive, advancing, cycle cadence nominal.
#
# Exit code mirrors the verdict: 0=UP 1=BUSY 4=WEDGED 2=DOWN.
_watcher_liveness_verdict() {
    local state_dir="${1:?state_dir required}" interval="${2:-60}" dead_cutoff="${3:-}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=60
    local rc=0
    _watcher_alive "$state_dir" "$interval" "$dead_cutoff" || rc=$?
    local hb="$state_dir/watcher-heartbeat"
    local hb_age page cage period cutoff pid state reason
    hb_age=$(_watcher_heartbeat_age "$hb")
    pid=$(_watcher_heartbeat_field "$hb" pid)
    page=$(_watcher_progress_age "$state_dir" "$pid")
    cage=$(_watcher_heartbeat_age "$state_dir/watcher-cycle")
    period=$(_watcher_cycle_period "$state_dir")
    cutoff=$(_watcher_wedge_cutoff "$interval" "$period")
    local fresh_cutoff=$(( interval * 2 + 15 ))
    case "$rc" in
        2|3)
            # The bucket says DOWN — but DOWN is reserved for ESTABLISHED
            # facts. A live watcher pid that is demonstrably ADVANCING
            # (progress/log/fork within the wedge cutoff) with a stale or
            # missing heartbeat is a ticker-degraded or pre-#491 watcher
            # under load — BUSY, not DOWN (the 2026-07-09 live system:
            # `DOWN pid:18665 heartbeat stale (age=326s)` while forking
            # children continuously; both claims false).
            if [[ -n "$pid" ]] && _watcher_pid_is_live_watcher "$pid" \
               && (( page <= cutoff )); then
                state=BUSY
                reason="heartbeat degraded (age ${hb_age}s) but pid=${pid} alive + advancing (progress ${page}s ago) — BUSY, not down"
            else
                state=DOWN
                reason=$(_watcher_reason "$state_dir" 2>/dev/null || echo 'not alive')
            fi
            ;;
        4)
            state=WEDGED
            reason="alive (pid=${pid:-?}) but nothing advanced: progress ${page}s / cycle ${cage}s (cutoff ${cutoff}s, measured period ${period}s)"
            ;;
        *)
            local busy=0
            (( rc == 1 )) && busy=1
            [[ -f "$state_dir/watcher-cycle" ]] && (( cage > fresh_cutoff )) && busy=1
            (( period > interval * 2 )) && busy=1
            if (( busy )); then
                state=BUSY
                reason="alive + advancing (progress ${page}s ago), loop period ~${period}s (cycle ${cage}s ago) — slow under load, NOT down"
            else
                state=UP
                reason="healthy (hb ${hb_age}s, cycle ${cage}s, period ~${period}s)"
            fi
            ;;
    esac
    printf 'state=%s\nrc=%d\npid=%s\nhb_age=%s\nprogress_age=%s\ncycle_age=%s\nperiod_s=%s\nwedge_cutoff=%s\nreason=%s\n' \
        "$state" "$rc" "$pid" "$hb_age" "$page" "$cage" "$period" "$cutoff" "$reason"
    case "$state" in
        UP) return 0 ;; BUSY) return 1 ;; WEDGED) return 4 ;; *) return 2 ;;
    esac
}

# _watcher_verdict_field <verdict_text> <key>
# Extract one key=value field from _watcher_liveness_verdict output.
_watcher_verdict_field() {
    local text="$1" key="$2"
    awk -F= -v k="$key" '$1==k {sub("^"k"=",""); print; exit}' <<<"$text" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Process-shape truth for the singleton guarantee (nexus-code#491)
#
# Two field-measured facts shape these helpers:
#
#   1. DECAPITATION: main.sh forks a subshell chain (scheduler async
#      tasks, _run_bounded children). Killing — or losing — the group
#      LEADER pid leaves that chain running the loop, reparented to
#      init, argv unchanged (observed live 2026-07-09 17:45: leader
#      30063 dead 6 minutes while its orphans kept forking tac/jq).
#      So `ppid==1` is a FALSE top-level test, a leader-pid wait is a
#      FALSE death test, and any singleton count must count process
#      GROUPS, not pids.
#   2. FD INHERITANCE: flock binds to the open file description, which
#      every fork() inherits — 17 processes were observed holding the
#      instance lock. A lock every descendant holds neither releases
#      on leader death nor distinguishes one tree from two (the
#      #451/#468/#471 fd-leak class, here load-bearing). The fork
#      chokepoints therefore close the lock fds (main.sh
#      _close_inherited_locks); these helpers never treat the flock
#      as a duplicate detector.
#
# A "watcher group" = a process group containing >=1 live process
# whose argv PROGRAM SLOT (argv[0]/argv[1] — same identity rule as
# _watcher_pid_is_live_watcher, immune to argv-quoting workers) is
# <nexus_root>/monitor/watcher/main.sh. The launcher setsid-spawns
# main.sh, so a healthy watcher is one group whose leader (pgid) is
# alive; a leaderless group is a decapitated orphan loop that must be
# reaped, never adopted.
#
# /proc-only (Linux); on hosts without /proc these print nothing —
# callers must treat empty as "no information", not "no watcher"
# (they all keep the pidfile checks).

# _watcher_list_live_groups <nexus_root>
# One line per live watcher group: "<pgid>\t<live|dead>\t<n>" where
# the middle column is the LEADER's state and <n> the number of
# argv-matching members observed.
_watcher_list_live_groups() {
    local nexus_root="${1:?nexus_root required}"
    local main_path="$nexus_root/monitor/watcher/main.sh"
    [[ -d /proc ]] || return 0
    local d pid arg stat rest pgrp
    local -A group_n=()
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [[ -r "$d/cmdline" ]] || continue
        local -a argv=()
        while IFS= read -r -d '' arg; do
            argv+=("$arg")
            (( ${#argv[@]} >= 2 )) && break
        done < "$d/cmdline" 2>/dev/null
        case "${argv[0]:-}" in
            "$main_path") : ;;
            *) [[ "${argv[1]:-}" == "$main_path" ]] || continue ;;
        esac
        # pgrp = field 5 of /proc/<pid>/stat — 3rd after the
        # parenthesised comm (which may contain spaces/parens; strip
        # through the LAST ')').
        stat=$(cat "$d/stat" 2>/dev/null) || continue
        [[ -n "$stat" ]] || continue
        rest="${stat##*) }"
        read -r _ _ pgrp _ <<<"$rest"
        [[ "$pgrp" =~ ^[0-9]+$ ]] || continue
        group_n[$pgrp]=$(( ${group_n[$pgrp]:-0} + 1 ))
    done
    local g leader
    for g in "${!group_n[@]}"; do
        if kill -0 "$g" 2>/dev/null; then leader=live; else leader=dead; fi
        printf '%s\t%s\t%s\n' "$g" "$leader" "${group_n[$g]}"
    done
    return 0
}

# _watcher_list_live_pids <nexus_root>
# Leaders of live-LEADER watcher groups, one pid per line. Decapitated
# (leaderless) groups are deliberately excluded — they are defunct
# loops to reap, not watchers to protect.
_watcher_list_live_pids() {
    local nexus_root="${1:?nexus_root required}"
    local line pgid leader n
    while IFS=$'\t' read -r pgid leader n; do
        [[ "$leader" == live ]] && printf '%s\n' "$pgid"
    done < <(_watcher_list_live_groups "$nexus_root")
    return 0
}

# _watcher_group_alive <pgid>
# Return 0 iff the process GROUP has at least one live member (signal
# 0 to -pgid). This — not a leader-pid kill -0 — is the death test.
_watcher_group_alive() {
    local pgid="${1:?pgid required}"
    [[ "$pgid" =~ ^[0-9]+$ ]] && (( pgid > 1 )) || return 1
    kill -0 -- "-$pgid" 2>/dev/null
}

# _watcher_reap_group <pgid> [<term_wait_s>] [<nexus_root>]
#
# Kill an entire watcher process group BY PGID (never a pattern kill)
# and verify it is EMPTY afterwards: TERM the group, wait up to
# <term_wait_s> (default 10) for every member to exit, escalate to
# KILL, wait again (5s), then assert emptiness. Return 0 = group
# empty; 1 = members survived (caller must fail loud and must NOT
# spawn alongside them); 2 = REFUSED, nothing signalled (identity not
# established). Refuses pgid<=1.
#
# SELF-GUARDING (skeptic finding on PR#503): a group kill is the most
# destructive primitive in this repo, and the pid is NOT the identity
# — a recorded pid recycled to any setsid leader (a worker pane, a
# registry service, another agent's job) names an innocent group.
# When <nexus_root> is supplied, the group is signalled ONLY if it
# still contains an argv-verified watcher member for that root (per
# _watcher_list_live_groups); otherwise the reap REFUSES with rc 2
# and touches nothing. Every production caller passes the root; only
# fixtures that own their pgid may omit it.
_watcher_reap_group() {
    local pgid="${1:?pgid required}" term_wait="${2:-10}" nexus_root="${3:-}"
    [[ "$pgid" =~ ^[0-9]+$ ]] && (( pgid > 1 )) || return 1
    [[ "$term_wait" =~ ^[0-9]+$ ]] || term_wait=10
    _watcher_group_alive "$pgid" || return 0
    if [[ -n "$nexus_root" ]]; then
        if ! _watcher_list_live_groups "$nexus_root" \
             | awk -F'\t' -v g="$pgid" '$1==g{found=1} END{exit !found}'; then
            return 2
        fi
    fi
    kill -TERM -- "-$pgid" 2>/dev/null || true
    local i
    for (( i = 0; i < term_wait * 2; i++ )); do
        _watcher_group_alive "$pgid" || return 0
        sleep 0.5
    done
    kill -KILL -- "-$pgid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        _watcher_group_alive "$pgid" || return 0
        sleep 0.5
    done
    return 1
}

# _close_inherited_locks
#
# Close lock fds a forked subshell must NOT inherit (nexus-code#491,
# the #451/#468/#471 fd-leak class made load-bearing): flock binds to
# the open file description, so every fork() that keeps the fd holds
# the instance lock — 17 holders were observed live, which (a) kept
# the lock pinned after the leader died and (b) made it useless for
# duplicate detection. Called first thing inside the long-lived fork
# chokepoints (scheduler async fires via _scheduler_subshell_init,
# _run_bounded children, async respawns, the orchestrator fresh-spawn
# fork). Lives HERE — not in main.sh — so tests exercise the
# PRODUCTION text instead of a fixture re-definition (skeptic M4).
# Reads the caller's INSTANCE_LOCK_FD; a fork inherits shell vars, so
# no export is needed. No-op when unset.
_close_inherited_locks() {
    if [[ -n "${INSTANCE_LOCK_FD:-}" ]]; then
        eval "exec ${INSTANCE_LOCK_FD}>&-" 2>/dev/null || true
    fi
    return 0
}

# _watcher_youngest_member_age <pgid>
# Seconds since the YOUNGEST member of the group was forked — the
# "forking children" liveness signal (nexus-code#491): a loop that is
# mid-multi-minute stage still forks helpers continuously, while a
# genuinely wedged loop stops forking. Sweeps /proc for pgrp members
# and converts starttime (clock ticks since boot) via btime + CLK_TCK.
# Prints a very large number when the group is empty or /proc is
# unavailable. NOTE: the heartbeat ticker runs OUTSIDE the watcher's
# group (setsid, see main.sh) precisely so its own sleep/date forks
# can never pollute this signal.
_watcher_youngest_member_age() {
    local pgid="${1:?pgid required}"
    [[ "$pgid" =~ ^[0-9]+$ ]] && [[ -r /proc/stat ]] || { printf '999999999'; return 0; }
    local btime hz now d stat rest best=-1
    btime=$(awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null)
    [[ "$btime" =~ ^[0-9]+$ ]] || { printf '999999999'; return 0; }
    hz=$(getconf CLK_TCK 2>/dev/null)
    [[ "$hz" =~ ^[0-9]+$ ]] && (( hz > 0 )) || hz=100
    now=$(date +%s)
    for d in /proc/[0-9]*; do
        stat=$(cat "$d/stat" 2>/dev/null) || continue
        [[ -n "$stat" ]] || continue
        rest="${stat##*) }"
        # rest fields: 1=state 2=ppid 3=pgrp 4=session ... 20=starttime
        # shellcheck disable=SC2086
        set -- $rest
        [[ "${3:-}" == "$pgid" ]] || continue
        [[ "${20:-}" =~ ^[0-9]+$ ]] || continue
        local age=$(( now - (btime + ${20} / hz) ))
        (( age < 0 )) && age=0
        (( best < 0 || age < best )) && best=$age
    done
    (( best < 0 )) && best=999999999
    printf '%d' "$best"
}

# _watcher_heartbeat_ticker_loop <hb_file> <watch_pid> <tick_seconds> [<target>]
#
# The LIVENESS ticker body (nexus-code#491). Beats the heartbeat file
# every <tick_seconds> for as long as <watch_pid> (the main watcher)
# is alive, then exits — a fresh heartbeat can never outlive the
# process it vouches for by more than one tick, and _watcher_alive's
# pid-identity check trumps age anyway. Cadence is a CONSTANT: the
# whole point is that no amount of loop workload can starve it.
# Atomic tmp+mv writes; every failure is swallowed (a liveness ticker
# must never kill its host on a transient write error).
#
# Run backgrounded from main.sh AFTER the instance lock is held (a
# doomed second watcher must never beat the real one's heartbeat).
# Unit-testable standalone: the fixture passes any sleeping pid.
_watcher_heartbeat_ticker_loop() {
    local hb="${1:?heartbeat file required}" watch_pid="${2:?watch pid required}"
    local tick="${3:-20}" target="${4:-}"
    [[ "$tick" =~ ^[0-9]+$ ]] && (( tick >= 1 )) || tick=20
    local tmp="$hb.tick.$BASHPID"
    while kill -0 "$watch_pid" 2>/dev/null; do
        printf 'pid=%d\nts=%s\ntarget=%s\n' "$watch_pid" "$(date -Is)" "$target" \
            > "$tmp" 2>/dev/null && mv -f "$tmp" "$hb" 2>/dev/null || true
        sleep "$tick"
    done
    rm -f "$tmp" 2>/dev/null
    return 0
}

# _supervisor_monitor_command [nexus_root]
#
# THE single source of truth for the exact persistent-`Monitor` command
# the orchestrator arms (and re-arms) to supervise the watcher. Emitted
# verbatim by all three recovery surfaces — the `--- arm watcher
# supervisor ---` reminder (_supervisor_arm_emit_section), the
# supervise-tick DOWN message (_supervisor_down_recovery_message), and
# revive-watcher.sh's re-arm hint — so the command string can never
# drift between them. Prints the one-liner; always returns 0.
_supervisor_monitor_command() {
    local nexus_root="${1:-${NEXUS_ROOT:-}}"
    printf 'Monitor({command: "until ! %smonitor/watcher-supervise-tick.sh; do sleep 15; done"})' \
        "${nexus_root:+$nexus_root/}"
}

# _supervisor_down_recovery_message <reason> [nexus_root]
#
# The DOWN-path counterpart to the arm-emit GOLD STANDARD: the message
# the supervise tick prints to stderr — which lands in the orchestrator-
# armed Monitor's exit report when `until ! tick` exits on a dead
# watcher. Symmetric with _supervisor_arm_emit_section, it spells out the
# FULL recovery so a naive orchestrator reading ONLY this block recovers
# without prior knowledge: the exact revive invocation AND the re-arm
# Monitor command (shared via _supervisor_monitor_command), plus the
# skills/nexus.service-recovery pointer. Multi-line on stdout; the caller
# redirects to stderr. Always returns 0.
_supervisor_down_recovery_message() {
    local reason="${1:-not alive}" nexus_root="${2:-${NEXUS_ROOT:-}}"
    local p="${nexus_root:+$nexus_root/}"
    printf 'watcher DOWN: %s — the mutual-liveness supervisor must recover it now.\n' "$reason"
    printf 'Recover (mutual-liveness contract; see skills/nexus.service-recovery):\n'
    printf '  1. Revive — converges to EXACTLY ONE live watcher (idempotent; safe if already up): %smonitor/revive-watcher.sh\n' "$p"
    printf '  2. Re-arm the supervisor Monitor: %s\n' "$(_supervisor_monitor_command "$nexus_root")"
}

# _nexus_dir_writable <dir>
#
# Ground-truth writability probe: 0 if <dir> accepts a new file right now,
# 1 if NOT — read-only mount (EROFS), EACCES, or ENOSPC alike. Errno-
# agnostic: the condition we guard is "cannot write watcher state",
# whatever the cause.
#
# The implementation now lives in ONE place, monitor/_fs_probe.sh, shared
# with svc.sh, write-probe.sh and the launcher. The property that matters
# — a FRESH open() on every call, never a cached fd — is subtle enough
# that three independent copies of it would eventually drift, and a probe
# that drifts to a held fd reports HEALTHY during a total outage. See that
# file's header, and test-fs-guard.sh T2 which pins the property.
#
# Guards the rofs incidents (2026-06-29, 2026-07-09): the project's
# writable bind vanished from the sandbox mount namespace, so monitor/.state
# went read-only while the operator's out-of-namespace shell stayed
# writable. The incumbent watcher, holding its log fd, kept running; the
# successor died in a fresh open() of the same log.
if [[ -z "${_NEXUS_FS_PROBE_SOURCED:-}" ]] \
   && [[ -r "${BASH_SOURCE[0]%/*}/../_fs_probe.sh" ]]; then
    # shellcheck source=monitor/_fs_probe.sh
    source "${BASH_SOURCE[0]%/*}/../_fs_probe.sh"
    _NEXUS_FS_PROBE_SOURCED=1
fi

# Fallback for a partial tree (some test fixtures copy _lib.sh without the
# rest of monitor/). It must define the WHOLE probe API, not just
# _nexus_dir_writable: svc.sh calls nexus_path_writable, and an undefined
# function there would return 127 and be read as "filesystem is read-only" —
# a false alarm produced by the alarm system itself. Same semantics, same
# fresh open().
if ! declare -F nexus_dir_writable >/dev/null 2>&1; then
    nexus_dir_writable() {
        local dir="${1:?dir required}"
        [[ -d "$dir" ]] || return 1
        _NEXUS_FS_PROBE_SEQ=$(( ${_NEXUS_FS_PROBE_SEQ:-0} + 1 ))
        local t="$dir/.nexus-state-probe.$$.${RANDOM:-0}.${_NEXUS_FS_PROBE_SEQ}"
        if ( : > "$t" ) 2>/dev/null; then
            rm -f "$t" 2>/dev/null
            return 0
        fi
        return 1
    }
    nexus_nearest_existing_dir() {
        local p="${1:?path required}"
        while [[ -n "$p" && "$p" != "/" && ! -e "$p" ]]; do
            p="${p%/*}"; [[ -z "$p" ]] && p="/"
        done
        if [[ -e "$p" && ! -d "$p" ]]; then p="${p%/*}"; [[ -z "$p" ]] && p="/"; fi
        printf '%s' "$p"
    }
    nexus_path_writable() {
        nexus_dir_writable "$(nexus_nearest_existing_dir "${1:?path required}")"
    }
fi

# Historical name, kept for every existing caller. ONE implementation.
_nexus_dir_writable() { nexus_dir_writable "$@"; }

# _nexus_fs_evidence <path> [project_dir]
#
# Gather the observable facts that distinguish "the sandbox lost its
# read-write bind" from "the filer is down". READ-ONLY by construction:
# it reads /proc/self/mountinfo and runs df — both succeed on a read-only
# mount, which is the whole point, since this runs during the outage.
#
# Prints `key=value` lines (never fails, never writes):
#   mount_point / mount_opts / super_opts   the mount covering <path>
#   rw_bind                                 present | ABSENT
#   fs_avail / fs_source                    filer capacity + export
#
# The discriminating signature of both incidents: the covering mount is
# `ro` while its SUPERBLOCK is `rw` (the filer is exporting read-write and
# is perfectly healthy), and the read-write bind for the project dir has
# vanished from this namespace. A genuine filer outage looks nothing like
# this — there the superblock goes `ro` too, or the mount disappears
# entirely and df hangs or errors.
_nexus_fs_evidence() {
    local path="${1:-/}" project="${2:-${SANDBOX_PROJECT_DIR:-}}"
    local mi=/proc/self/mountinfo
    local best='' best_len=0 best_opts='' best_super=''
    local id parent devno root mp opts rest fstype super line

    if [[ -r "$mi" ]]; then
        while IFS= read -r line; do
            # mountinfo: id parent maj:min root mountpoint opts [tags...] - fstype source super
            read -r id parent devno root mp opts rest <<<"$line" || continue
            [[ -n "$mp" ]] || continue
            # Longest mountpoint that is a prefix of <path> covers it.
            if [[ "$path" == "$mp" || "$path" == "$mp"/* || "$mp" == "/" ]]; then
                if (( ${#mp} >= best_len )); then
                    best_len=${#mp}; best="$mp"; best_opts="$opts"
                    super="${line##* }"; best_super="$super"
                fi
            fi
        done < "$mi"
    fi

    printf 'mount_point=%s\n' "${best:-unknown}"
    printf 'mount_opts=%s\n'  "${best_opts:-unknown}"
    printf 'super_opts=%s\n'  "${best_super:-unknown}"

    # The read-write bind for the project dir: present as its own mount?
    local rw_bind='unknown'
    if [[ -n "$project" && -r "$mi" ]]; then
        rw_bind=ABSENT
        # NOTE: no `IFS=` prefix here — this read must split into fields.
        while read -r id parent devno root mp opts rest; do
            if [[ "$mp" == "$project" ]]; then
                case ",$opts," in
                    *,rw,*) rw_bind=present ;;
                    *)      rw_bind="present-but-$( printf '%s' "$opts" | cut -d, -f1 )" ;;
                esac
                break
            fi
        done < "$mi"
    fi
    printf 'rw_bind=%s\n' "$rw_bind"
    printf 'project_dir=%s\n' "${project:-unset}"

    # Filer capacity — proves this is not an ENOSPC / storage outage.
    local dfline
    if dfline=$(df -Ph "$path" 2>/dev/null | tail -1); then
        printf 'fs_source=%s\n' "$(printf '%s' "$dfline" | awk '{print $1}')"
        printf 'fs_avail=%s\n'  "$(printf '%s' "$dfline" | awk '{print $4" avail of "$2" ("$5" used)"}')"
    else
        printf 'fs_source=unknown\nfs_avail=unknown\n'
    fi
}

# _nexus_fs_evidence_field <evidence> <key> — pluck one value.
_nexus_fs_evidence_field() {
    local ev="${1:-}" key="${2:?key required}"
    printf '%s\n' "$ev" | sed -n "s/^${key}=//p" | head -1
}

# _nexus_rofs_signature_matches <mount_opts> <rw_bind>
#
# Does the observed evidence match the DETACHED-BIND signature of the two
# known incidents — the covering mount `ro` while its superblock is `rw`,
# and/or the project's read-write bind gone from this namespace?
#
# This gate exists because the probe is deliberately errno-agnostic: EROFS,
# EACCES (a chmod accident) and ENOSPC (a genuinely full filer) all trip it.
# Only the detached-bind case justifies "the storage is fine, do not page
# storage-support". Asserting that diagnosis for the other classes would be the very
# thing this whole change exists to prevent — a confident statement that
# happens to be false. When the evidence does not match, we say so and hand
# the reader the table instead of a conclusion.
#
# Returns 0 on a match, 1 otherwise (including unknown/unreadable evidence).
_nexus_rofs_signature_matches() {
    local mount_opts="${1:-}" rw_bind="${2:-}"
    [[ "$rw_bind" == "ABSENT" ]] && return 0
    [[ "${mount_opts%%,*}" == "ro" ]] && return 0
    return 1
}

# _nexus_critical_alarm <key> <throttle_s> <message...>
#
# Out-of-band, throttled operator alarm for a CRITICAL infra condition
# that CANNOT be self-recovered from inside the sandbox — chiefly a
# read-only project filesystem, where every write to monitor/.state
# fails so neither the watcher nor revive-watcher can record, retry, or
# even log to disk. The alarm path therefore MUST NOT touch the project
# FS: it rings sandbox-notify (tmux + the chaperon FIFO on /tmp or
# /loc/scratch — independent of the read-only project mount) and prints
# to stderr (which lands in the orchestrator Monitor's exit report).
# Throttle state lives in ${TMPDIR:-/tmp} (a tmpfs/bind that stays
# writable when the project is read-only), keyed by <key>, so a
# persistently-down watcher RE-alarms at most once per <throttle_s>
# rather than spamming every tick — and never falls silent. Fails OPEN:
# if even the throttle marker cannot be written it still rings (better to
# over-alarm a real outage than miss it). Returns 0 if it rang, 1 if
# throttled. Callers SHOULD share one <key> for the same condition so the
# 15s supervise-tick and the per-DOWN revive do not double-ring.
_nexus_critical_alarm() {
    local key="${1:?key required}" throttle="${2:-120}"
    shift 2 2>/dev/null || true
    local msg="$*"
    [[ "$throttle" =~ ^[0-9]+$ ]] || throttle=120
    local marker="${TMPDIR:-/tmp}/.nexus-critical-alarm.${key//[^A-Za-z0-9._-]/_}"
    local now last age
    now=$(date +%s 2>/dev/null || echo 0)
    if [[ -f "$marker" ]]; then
        last=$(cat "$marker" 2>/dev/null)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        age=$(( now - last ))
        if (( last > 0 && age >= 0 && age < throttle )); then
            return 1   # throttled — already alarmed within the window
        fi
    fi
    printf '%s\n' "$now" > "$marker" 2>/dev/null || true
    printf 'CRITICAL nexus alarm: %s\n' "$msg" >&2
    command -v sandbox-notify >/dev/null 2>&1 && \
        sandbox-notify "CRITICAL: $msg" >/dev/null 2>&1 || true
    return 0
}

# _nexus_fs_incident_record <state_dir> <onset_epoch> <onset_bound_epoch> \
#                           <recovered_epoch> <channels> <context>
#
# Leave a DURABLE trace once the filesystem comes back. The 2026-06-29
# incident went unrecorded in `reports/` for ten days and the 2026-07-09
# recurrence was diagnosed from scratch, because nothing that observed the
# outage outlived it: the alarm was in memory, the escalation was on the
# network, and the process died with the incident.
#
# Called on the recovery edge (probe fails -> probe succeeds), when writes
# work again. Appends ONE json line to <state_dir>/fs-incidents.jsonl.
# Best-effort: a failed append never propagates (we may be racing a second
# outage), but it is logged by the caller.
#
#   onset_epoch        first cycle whose probe FAILED (upper bound on onset)
#   onset_bound_epoch  last cycle whose probe SUCCEEDED (lower bound)
#   recovered_epoch    first cycle whose probe succeeded again
#   channels           comma-separated escalation channels actually used
_nexus_fs_incident_record() {
    local state_dir="${1:?}" onset="${2:-0}" bound="${3:-0}" recovered="${4:-0}"
    local channels="${5:-none}" context="${6:-watcher}"
    local dur=$(( recovered - onset ))
    (( dur < 0 )) && dur=0
    local f="$state_dir/fs-incidents.jsonl"
    local iso_on iso_rec
    iso_on=$(date -Is -d "@$onset" 2>/dev/null || echo unknown)
    iso_rec=$(date -Is -d "@$recovered" 2>/dev/null || echo unknown)
    printf '{"event":"fs-readonly-incident","context":"%s","onset_after":%s,"onset_before":%s,"onset_iso":"%s","recovered":%s,"recovered_iso":"%s","duration_seconds":%s,"escalation_channels":"%s","host":"%s"}\n' \
        "$context" "$bound" "$onset" "$iso_on" "$recovered" "$iso_rec" "$dur" \
        "$channels" "$(hostname 2>/dev/null || echo unknown)" \
        >> "$f" 2>/dev/null || return 1
    return 0
}

# _nexus_fs_incident_close_comment <nexus_root> <duration_s> <channels> <context>
#
# Close the loop on the OPEN incident issue once the FS is back: post a
# recovery comment so the durable GitHub record states the outage ended,
# how long it lasted, and how the operator heard about it. Best-effort and
# network-only; no side effects on failure. Returns 0 if a comment landed.
_nexus_fs_incident_close_comment() {
    local nexus_root="${1:?}" dur="${2:-0}" channels="${3:-none}" context="${4:-watcher}"
    local cfg="$nexus_root/config/load.sh" repo tok mint num
    repo="${MONITOR_REPO:-}"
    [[ -n "$repo" || ! -x "$cfg" ]] || repo=$("$cfg" github.repo 2>/dev/null)
    [[ -n "$repo" ]] || return 1
    command -v gh >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    mint="${NEXUS_MINT_TOKEN_BIN:-$nexus_root/monitor/mint-token.sh}"
    [[ -e "$mint" ]] || return 1
    tok=$(NEXUS_ROOT="$nexus_root" bash "$mint" 2>/dev/null) || return 1
    [[ -n "$tok" ]] || return 1
    num=$(GH_TOKEN="$tok" gh api "/repos/$repo/issues?state=open&per_page=100" 2>/dev/null \
        | jq -r '[.[] | select(.pull_request == null)
                      | select((.title // "") | startswith("cc-incident: watcher down"))
                      | .number] | first // empty' 2>/dev/null)
    [[ -n "$num" ]] || return 1
    GH_TOKEN="$tok" gh api -X POST "/repos/$repo/issues/$num/comments" \
        -f "body=✅ **Recovered.** The project filesystem is writable again after **${dur}s**; \`$context\` resumed normal operation and the incident is recorded durably in \`monitor/.state/fs-incidents.jsonl\`. Escalation reached the operator via: \`$channels\`. Closing this issue is safe once the restart has been confirmed." \
        >/dev/null 2>&1 || return 1
    return 0
}

# _nexus_rofs_alarm_text <state_dir> [context]
#
# The canonical ONE-LINE operator alarm for a read-only project FS, used
# for sandbox-notify and stderr. Leads with the REMEDY (an alarm read at a
# glance, on a phone, must say what to do before it says what happened),
# names the condition, and pre-empts the two wrong reactions: "my data is
# gone" and "the filer is down, page storage-support". Contains the literal token
# READ-ONLY, which callers and tests key on.
_nexus_rofs_alarm_text() {
    local state_dir="${1:-?}" context="${2:-watcher}"
    # Same honesty gate as the issue body: only claim "the filer is healthy"
    # when the evidence actually shows the detached-bind signature. An
    # ENOSPC or a permissions accident trips the same probe, and telling an
    # operator not to page storage-support would then be exactly wrong.
    local ev mount_opts rw_bind verdict
    ev=$(_nexus_fs_evidence "$state_dir" "${SANDBOX_PROJECT_DIR:-}" 2>/dev/null || true)
    mount_opts=$(_nexus_fs_evidence_field "$ev" mount_opts)
    rw_bind=$(_nexus_fs_evidence_field "$ev" rw_bind)
    if _nexus_rofs_signature_matches "$mount_opts" "$rw_bind"; then
        verdict='No data is lost and the filer is healthy; do not page storage-support.'
    else
        verdict='No data is lost. The evidence does NOT match the usual detached-bind signature — check free space and the superblock before ruling out a real storage problem.'
    fi
    printf 'RESTART THE SANDBOX from outside — the nexus project FS is READ-ONLY (cannot write %s). Nothing running inside can repair it. %s Detected by %s. See skills/nexus.service-recovery.' \
        "$state_dir" "$verdict" "$context"
}

# _nexus_incident_issue_body <operator_login> <nexus_root> <context> <state_dir> <reason>
#
# Compose the INLINE Markdown body for the watcher-down-on-read-only-FS
# GitHub incident issue. Inline (not an uploaded asset) BY DESIGN: the
# escalation fires precisely when the project FS is read-only, so we can
# neither write a local file nor `ng upload` one — the whole diagnostic
# must live in the request body.
#
# Audience-first (operator ask, #377 comment 4837922865): many operators
# are biologists with only basic compute knowledge, so the body LEADS with
# a plain-language explanation + a step-by-step recovery runbook a
# non-technical operator can follow, and pushes the technical diagnostic
# DOWN into a collapsed <details> block. Opens with the operator @-ping so
# the GitHub notification reaches them out-of-band. Prints to stdout;
# always rc 0.
#
# Recovery mechanics (verified against agent-sandbox 0.13.x in-sandbox):
# the INNER sandbox tmux uses prefix Ctrl-a and shows `[sandbox]` in its
# status bar (the OUTER/meta tmux uses the default Ctrl-b). Detaching the
# inner client (Ctrl-a then d) ends the sandbox's foreground command, which
# tears down the stale read-only mount namespace; relaunching with
# `agent-sandbox tmux new-session ./watcher --continue` (monitor/watcher/
# entry.sh) brings up a FRESH sandbox with the writable bind restored and
# resumes the pinned orchestrator session.
_nexus_incident_issue_body() {
    local login="${1:?operator login required}" nexus_root="${2:-<nexus-root>}"
    local context="${3:-watcher supervisor}" state_dir="${4:-?}" reason="${5:-watcher down}"
    local ts host ev mount_opts super_opts rw_bind fs_avail fs_source mount_point
    ts=$(date -Is 2>/dev/null || echo unknown)
    host=$(hostname 2>/dev/null || echo unknown)

    # Read-only evidence gathering — safe on a read-only mount by design.
    ev=$(_nexus_fs_evidence "$state_dir" "${SANDBOX_PROJECT_DIR:-$nexus_root}" 2>/dev/null || true)
    mount_point=$(_nexus_fs_evidence_field "$ev" mount_point); : "${mount_point:=unknown}"
    mount_opts=$(_nexus_fs_evidence_field "$ev" mount_opts);   : "${mount_opts:=unknown}"
    super_opts=$(_nexus_fs_evidence_field "$ev" super_opts);   : "${super_opts:=unknown}"
    rw_bind=$(_nexus_fs_evidence_field "$ev" rw_bind);         : "${rw_bind:=unknown}"
    fs_avail=$(_nexus_fs_evidence_field "$ev" fs_avail);       : "${fs_avail:=unknown}"
    fs_source=$(_nexus_fs_evidence_field "$ev" fs_source);     : "${fs_source:=unknown}"
    # Only the leading flag of the super options matters for the headline.
    local super_head="${super_opts%%,*}"
    local mount_head="${mount_opts%%,*}"

    # Interpret the evidence ONLY when it matches the known signature. The
    # probe trips on EROFS, EACCES and ENOSPC alike; "the storage is fine"
    # is true for exactly one of those. See _nexus_rofs_signature_matches.
    local diagnosis storage_section
    if _nexus_rofs_signature_matches "$mount_opts" "$rw_bind"; then
        diagnosis="That combination means the *mount* was taken away from us; the *storage* is fine."
        storage_section=$(cat <<STORAGE
### This is NOT a storage outage — please do not page storage-support

The filer is healthy and is still exporting this filesystem read-write:

| check | observed |
|---|---|
| superblock | \`$super_opts\` |
| capacity | $fs_avail |
| export | \`$fs_source\` |

A real filer problem looks different: the superblock itself goes read-only, or the mount disappears and \`df\` hangs. Neither is happening here.
STORAGE
)
    else
        diagnosis="**This does not match the known signature.** In the two recorded incidents the covering mount was \`ro\` over an \`rw\` superblock with the read-write bind gone. That is not what is observed here, so do **not** assume a detached bind — read the table below before concluding anything."
        storage_section=$(cat <<STORAGE
### This may or may not be a storage problem — check before concluding

The write failed, but the evidence does **not** show the detached-bind signature. The probe is deliberately errno-agnostic: a read-only mount, a permissions accident, and a **full filesystem** all trip it. Read these values before deciding whom to call:

| check | observed |
|---|---|
| superblock | \`$super_opts\` |
| capacity | $fs_avail |
| export | \`$fs_source\` |

If the **capacity** is exhausted, or the **superblock** itself is \`ro\`, this *is* a storage problem and storage-support should be contacted. If both look healthy, suspect permissions on the path itself. A sandbox restart may not help.
STORAGE
)
    fi

    cat <<EOF
@$login — ⚠️ **The workspace's storage has gone read-only. It has to be restarted from OUTSIDE the sandbox; nothing running inside can repair it.** This is safe to fix, it takes about a minute, and no technical knowledge required.

### Do this

1. **Find the workspace terminal.** Look at the bottom status bar. If it reads **\`[sandbox]\`**, you are in the right (inner) window.
2. **Close that inner sandbox window:** press and hold **\`Ctrl\`**, tap **\`a\`**, let go — then tap **\`d\`**.
   - That detaches and closes the inner sandbox, discarding its stuck mount namespace.
   - ⚠️ Do **NOT** use **\`Ctrl\`+\`b\`** then **\`d\`** — that is the *outer* terminal and will not fix anything.
3. **Restart the workspace.** You are now back at the outer shell. Paste this one line and press **Enter**:
   \`\`\`
   cd $nexus_root && agent-sandbox tmux new-session ./watcher --continue
   \`\`\`
   (\`--continue\` resumes your previous session where it left off.)

The workspace comes back on its own within about a minute.

### The evidence, in one line

\`$mount_point\` is mounted **\`$mount_head\`** while its superblock is **\`$super_head\`**, and the read-write bind for \`${SANDBOX_PROJECT_DIR:-$nexus_root}\` is **$rw_bind** from this mount namespace.

$diagnosis

### Nothing is lost or corrupted

- Every byte on \`/fh\` is intact. The filesystem is read-only, not damaged — no write ever half-landed.
- The git repo, the \`work/\` clones, \`reports/\` and \`monitor/.state/\` all survive the restart untouched.
- \`~/.claude\` and \`/tmp\` are on different mounts and are still writable, which is how this message reached you.

$storage_section

### What the restart will cost

- **Running agent (worker) sessions are ephemeral** and will not survive; so are the prompt files under the scratchpad. Work already committed, pushed, or written to \`reports/\` is safe.
- The durable record of this incident is **this issue** — it is written to GitHub precisely because nothing could be written to disk.

---

<details>
<summary>Technical detail (for the record / on-call)</summary>

| field | value |
|---|---|
| detected by | $context |
| timestamp | $ts |
| host | \`$host\` |
| unwritable path | \`$state_dir\` |
| covering mount | \`$mount_point\` |
| mount options | \`$mount_opts\` |
| superblock options | \`$super_opts\` |
| project rw bind | $rw_bind |
| watcher state | $reason |

A read-only project FS is **unrecoverable in-namespace**: every write to \`monitor/.state\` fails (EROFS), so the watcher cannot record, retry, or log to disk, and \`revive-watcher.sh\` exits 4 rather than looping on a futile \`svc.sh restart\`. The terminal \`sandbox-notify\` alarm has also fired (throttled).

**Why a restart is the only remedy:** the sandbox's mount namespace is kernel-enforced and cannot be repaired from inside it — by design. Detaching the inner sandbox discards that namespace; relaunching builds a fresh one with the read-write bind in place. Do not attempt to remount, re-bind, or \`unshare\` your way out of this: it is not possible from inside, and it is not something to work around.

**Root cause: NOT established.** What is known: an already-open file descriptor keeps working after its mount is detached, so the *incumbent* watcher logs normally straight through the outage while any *successor* — which must resolve paths afresh — dies instantly. Both observed incidents (2026-06-29, 2026-07-09) began within seconds of a \`launcher.sh --replace\` self-restart. That association is strong, but its direction is unproven; do not treat it as a diagnosis. See \`skills/nexus.service-recovery\`.

</details>

<sub>Auto-filed by the EROFS escalation path — RO-FS-safe (network-only; no project-FS write, no \`ng\`, no local marker). One open issue per outage; while this issue stays open the condition may be ongoing.</sub>
EOF
}

# _nexus_github_incident_escalate <nexus_root> <state_dir> <context> <reason>
#
# OUT-OF-BAND escalation of a CRITICAL watcher-down-on-read-only-FS event
# to GitHub, so the operator hears about it even when their terminal /
# tmux is unattended (the #377 operator ask: "will the alarm escalate to
# a github issue and the nexus issue with a user ping?"). It (1) files —
# or locates — a single OPEN incident issue on the nexus asset/issue repo
# with an inline diagnostic + an operator @-ping, and (2) comments on the
# nexus overview issue with the same @-ping + a link to the incident.
#
# THE CRUX — this runs precisely WHEN the project FS is read-only, so it
# MUST NOT write to the project FS. It is network-only:
#   - mints the BOT token via mint-token.sh (writes only its cache under
#     $HOME/.claude — a DIFFERENT mount that stays writable; never the
#     read-only project bind) and calls `gh api` directly;
#   - does NOT use any `ng` verb (those write monitor/.state, which is the
#     read-only mount), writes NO local throttle/marker file, and uploads
#     NO local asset (impossible on a read-only FS) — the diagnostic is
#     bundled INLINE in the issue body;
#   - reads config only (config/load.sh reads nexus.yml — reads succeed on
#     a read-only mount).
#
# IDEMPOTENT over the NETWORK (no FS marker): before creating it queries
# the repo's OPEN issues (the REST list endpoint — immediately consistent,
# unlike the search index) for an existing incident by a stable title
# convention. If one is open it is a NO-OP (returns 0) — a sustained
# outage raises exactly ONE issue, never a flood, and never re-pings.
# Callers further gate invocation behind the shared `watcher-rofs`
# critical-alarm throttle (MONITOR_ROFS_ALARM_THROTTLE_SECONDS) so the
# network attempt itself fires at most once per window.
#
# FAIL-SOFT: any missing dependency, empty token, or failed API call
# returns non-zero WITHOUT side effects beyond best-effort network calls;
# callers `|| true` it so the supervisor never crashes — the existing
# sandbox-notify + stderr alarm remains the floor.
#
# Gated by monitor.rofs_alarm.github_escalation_enabled (default true; the
# catastrophic watcher-down case is the whole point) / env override
# MONITOR_ROFS_GITHUB_ESCALATION_ENABLED. Test env overrides:
# MONITOR_REPO, MONITOR_USER_LOGIN, MONITOR_OVERVIEW_NUMBER (load.sh-native
# where they exist), NEXUS_MINT_TOKEN_BIN, GH_OPEN_ISSUES_JSON (via a
# stubbed `gh`). Returns: 0 escalated or idempotent no-op; 1 fail-soft
# (dep/token/API failure); 2 disabled by config.
_nexus_github_incident_escalate() {
    local nexus_root="${1:-${NEXUS_ROOT:-}}" state_dir="${2:-?}"
    local context="${3:-watcher supervisor}" reason="${4:-watcher down}"
    local cfg="$nexus_root/config/load.sh"

    # Gate (default on). Env override wins; else config; else true.
    local enabled="${MONITOR_ROFS_GITHUB_ESCALATION_ENABLED:-}"
    if [[ -z "$enabled" && -x "$cfg" ]]; then
        enabled=$("$cfg" monitor.rofs_alarm.github_escalation_enabled true 2>/dev/null)
    fi
    [[ "${enabled:-true}" == "true" ]] || return 2

    command -v gh >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1

    # Identity: repo + operator login. Env overrides (load.sh-native) win
    # so a read-only config is never required under test; production reads
    # them from nexus.yml (a read succeeds on a read-only mount).
    local repo login
    repo="${MONITOR_REPO:-}"
    [[ -n "$repo" || ! -x "$cfg" ]] || repo=$("$cfg" github.repo 2>/dev/null)
    login="${MONITOR_USER_LOGIN:-}"
    [[ -n "$login" || ! -x "$cfg" ]] || login=$("$cfg" github.user_login 2>/dev/null)
    [[ -n "$repo" && -n "$login" ]] || return 1

    # BOT token (network identity). mint-token.sh writes ONLY its $HOME
    # cache, never the project FS. Empty/failed mint ⇒ fail-soft.
    local mint tok
    mint="${NEXUS_MINT_TOKEN_BIN:-$nexus_root/monitor/mint-token.sh}"
    [[ -x "$mint" || -f "$mint" ]] || return 1
    tok=$(NEXUS_ROOT="$nexus_root" bash "$mint" 2>/dev/null) || return 1
    [[ -n "$tok" ]] || return 1

    # Idempotency: is an incident issue already OPEN? Use the REST list
    # endpoint (immediately consistent) and match a stable title prefix —
    # NOT the search index (which lags minutes and would double-file). Walk
    # ALL pages: a repo with >100 open issues would hide an existing
    # incident past page 1 and the dedup would file a duplicate every
    # window. A page with <per_page items is the last; a hard 50-page cap
    # (5000 issues) backstops a runaway.
    local title_marker="cc-incident: watcher down"
    local existing="" page=1 per_page=100 page_json found count
    while (( page <= 50 )); do
        page_json=$(GH_TOKEN="$tok" gh api \
            "/repos/$repo/issues?state=open&per_page=$per_page&page=$page" 2>/dev/null) || return 1
        found=$(printf '%s' "$page_json" | jq -r --arg m "$title_marker" \
            '[.[] | select(.pull_request == null)
                  | select((.title // "") | startswith($m)) | .number] | first // empty' \
            2>/dev/null)
        if [[ -n "$found" ]]; then existing="$found"; break; fi
        count=$(printf '%s' "$page_json" | jq -r 'length' 2>/dev/null)
        [[ "$count" =~ ^[0-9]+$ ]] || break    # malformed ⇒ stop walking
        (( count < per_page )) && break          # short page ⇒ last page
        (( page++ ))
    done
    if [[ -n "$existing" ]]; then
        # Already escalated and still open — NO-OP (no duplicate, no re-ping).
        return 0
    fi

    # File the incident issue with the inline diagnostic + operator ping.
    local title="cc-incident: watcher down (read-only project FS)"
    local body resp num
    body=$(_nexus_incident_issue_body "$login" "$nexus_root" "$context" "$state_dir" "$reason")
    resp=$(GH_TOKEN="$tok" gh api -X POST "/repos/$repo/issues" \
        -f "title=$title" -f "body=$body" 2>/dev/null) || return 1
    num=$(printf '%s' "$resp" | jq -r '.number // empty' 2>/dev/null)
    [[ -n "$num" ]] || return 1

    # Ping the operator on the nexus overview too, linking the incident.
    # (`#$num` auto-links to the incident issue in the same repo — DESIRED.)
    local overview
    overview="${MONITOR_OVERVIEW_NUMBER:-}"
    if [[ -z "$overview" && -x "$cfg" ]]; then
        overview=$("$cfg" github.overview_issue_number "" 2>/dev/null)
    fi
    if [[ -z "$overview" ]]; then
        overview=$(GH_TOKEN="$tok" gh api \
            "/repos/$repo/issues?labels=nexus:overview&state=open&per_page=5" 2>/dev/null \
            | jq -r '.[0].number // empty' 2>/dev/null)
    fi
    if [[ -n "$overview" ]]; then
        GH_TOKEN="$tok" gh api -X POST "/repos/$repo/issues/$overview/comments" \
            -f "body=@$login watcher DOWN on a READ-ONLY project FS — incident filed at #$num. Restart the sandbox to restore the writable bind. (auto-filed, RO-FS-safe escalation; see skills/nexus.service-recovery)" \
            >/dev/null 2>&1 || true
    fi
    return 0
}

# _supervisor_arm_emit_section <heartbeat_file> <stale_seconds> [nexus_root]
#
# Emit body for the `--- arm watcher supervisor ---` reminder (your-org/
# your-nexus watcher-supervision, mutual-liveness design). The
# orchestrator arms a persistent Monitor that revives a crashed watcher
# and TOUCHES the supervisor heartbeat each tick. If that heartbeat is
# stale/absent the supervisor is NOT armed → the watcher nudges the
# (possibly freshly-restarted) orchestrator to (re)arm it. A STANDING
# condition, not a one-shot: it reflects the live heartbeat freshness on
# every emit, so it self-clears the instant the Monitor is armed (no
# re-nag guard — the emit content-hash dedup collapses repeats). Empty +
# rc1 when armed (fresh heartbeat) or disabled (MONITOR_WATCHER_
# SUPERVISOR_ENABLED != true). Lives here (not main.sh) so it is
# sourceable + unit-testable, mirroring the other emit-section helpers.
_supervisor_arm_emit_section() {
    [[ "${MONITOR_WATCHER_SUPERVISOR_ENABLED:-true}" == "true" ]] || return 1
    local hb="${1:?heartbeat required}" stale="${2:-90}" nexus_root="${3:-${NEXUS_ROOT:-}}"
    [[ "$stale" =~ ^[0-9]+$ ]] || stale=90
    local age
    age=$(_watcher_heartbeat_age "$hb")    # very large if absent
    [[ "$age" =~ ^[0-9]+$ ]] || age=999999
    (( age <= stale )) && return 1         # armed — nothing to nag
    # Body is intentionally STABLE (no live age number) so the emit
    # content-hash dedup collapses repeats — the reminder surfaces once
    # per genuine emit while unarmed, never spamming a quiet workspace.
    printf 'No fresh watcher-supervisor heartbeat (%s) — the supervisor Monitor is NOT armed.\n' \
        "$hb"
    printf 'Without it a watcher CRASH has no turn-independent revival. (Re)arm it now (mutual-liveness contract):\n'
    printf '  %s\n' "$(_supervisor_monitor_command "$nexus_root")"
    printf '  On exit (watcher down) run %smonitor/revive-watcher.sh, then re-arm. See skills/nexus.service-recovery.\n' \
        "${nexus_root:+$nexus_root/}"
    return 0
}

# _machine_input_stamp <window> <src>
#
# The single watcher-side chokepoint for the machine-input ledger
# (`machine-input.tsv`, append-only rows `<window>\t<epoch>\t<src>`).
# Every watcher-initiated pane injection into a worker stamps here
# BEFORE pasting, so the idle-probe's operator-attribution rule (see
# the "operator-engaged marks" section of _idle_probe.sh and
# retire-preflight.sh's `up_epoch <= machine_epoch + slack` check)
# attributes the resulting UserPromptSubmit to the machine, not the
# operator. An unstamped worker wake leaves machine_epoch stale → the
# submit reads as a fresh operator submit → false operator-engaged
# mark → stall-nag suppressed and retire held until staleness.
#
# `<src>` is the injector-identity hint (orchestrator-followup,
# skeptic-nudge, unstick-permission, unstick-api-error,
# unstick-ratelimit, over-limit-wake, …). Consumers key on columns
# 1–2 only and ignore the src token, so it is purely additive
# audit/debug provenance.
#
# Path precedence: MACHINE_INPUT_TSV global (set by main.sh) →
# ACTION_LOG-sibling fallback → STATE_DIR-sibling fallback (matching
# _idle_probe.sh's `_machine_input_path`). Silent no-op when none is
# available (standalone harnesses that don't care). Never flips the
# caller's exit code — a failed stamp must not abort a recovery paste.
_machine_input_stamp() {
    local window="$1" src="${2:-machine}"
    [[ -n "$window" ]] || return 0
    local path="${MACHINE_INPUT_TSV:-}"
    if [[ -z "$path" && -n "${ACTION_LOG:-}" ]]; then
        path="$(dirname "$ACTION_LOG")/machine-input.tsv"
    fi
    if [[ -z "$path" && -n "${STATE_DIR:-}" ]]; then
        path="${STATE_DIR}/machine-input.tsv"
    fi
    [[ -n "$path" ]] || return 0
    mkdir -p "$(dirname "$path")" 2>/dev/null || return 0
    printf '%s\t%s\t%s\n' "$window" "$(date +%s)" "$src" >> "$path" 2>/dev/null || true
}

# _classify_diff <diff_file>
#
# Classify a `diff -u baseline current` body (the output of
# snapshot_local, truncated to ~120 lines by main.sh) as signal-carrying
# or pure-noise. The noise kinds that waste the monitor's attention:
#
#   - All `--- git ---` section changes: clean ↔ dirty flips, SHA
#     bumps on clean-clean (post-push, post-merge, external push),
#     mid-dirty hash bumps, project add (worker just cloned), project
#     remove (worker tore down a worktree). None of these are
#     actionable for the orchestrator. The actionable triggers are
#     bells (window events), report-file changes, and the GitHub
#     eligible-comments section — the git status snapshot is bookkeeping.
#   (interim reports no longer need special-casing here: the change-detection
#   snapshot now excludes `*-interim*.md` UPSTREAM at the `find`, and lists
#   final-report BASENAMES with no mtime — so a report rewrite produces no diff
#   at all and only a genuine add/remove of a final report reaches this
#   classifier. nexus-code#236.)
#
# Everything else is signal and should paste:
#   - `--- tmux ---` changes (window add/remove, bell flag flip)
#   - final `reports/*.md` add/remove/rename
#   - unknown sections or malformed lines (fail open toward signal)
#
# stdout: one-line noise summary (e.g. `2 git-section update(s)`). Empty when
#         no noise found.
# exit:   0 → at least one signal line → caller should EMIT.
#         1 → diff is entirely noise → caller should SUPPRESS.
#
# The classifier is intentionally permissive: anything it doesn't
# understand (dashboard header changes, new section names, parse
# failures) is treated as signal, on the principle that losing a
# real emit is worse than pasting a borderline one. The git-section
# blanket-suppression is the one exception, justified because no
# git-section transition in isolation is something the orchestrator
# can act on.
_classify_diff() {
    local diff_file="$1"
    [[ -f "$diff_file" ]] || return 0
    awk '
        BEGIN { section=""; signal=0; git_noise=0 }

        # Unified-diff file/hunk headers — skip.
        /^---[[:space:]]/    { next }
        /^\+\+\+[[:space:]]/ { next }
        /^@@/                { next }
        /^diff /             { next }
        /^index /            { next }

        # Section markers appear as context lines (leading space).
        /^ --- reports ---$/ { section = "reports"; next }
        /^ --- tmux ---$/    { section = "tmux";    next }
        /^ --- git ---$/     { section = "git";     next }

        # Other context — ignore.
        /^ / { next }

        # Change lines: +<content> or -<content>.
        #
        # We infer the section from the line SHAPE, not only the last
        # seen section marker — `diff -u` default context (3 lines)
        # plus the main.sh `head -120` truncation routinely drops the
        # `--- git ---` / `--- reports ---` header out of the hunk
        # when only one line in the section changed, which used to
        # cause every git-row update to fall through the
        # "anything else: signal" catchall.
        #
        # Shape probes:
        #   git  line: `<project> <hex-sha-or-none> <clean|dirty>` (3 fields)
        #   reports  : `<basename>.md` — a final-report basename, NO mtime
        #              (nexus-code#236: the change-detection snapshot lists
        #              basenames only; interim reports are excluded UPSTREAM at
        #              the `find`, so no interim special-case is needed here).
        #              A trailing timestamp is tolerated for any legacy baseline.
        #   tmux     : `<window> bell=<n>`                         (2 fields)
        /^[+-]/ {
            line = substr($0, 2)

            # Git-row shape: project hexsha-or-none clean|dirty.
            # Every git-section line is noise — the watcher emits on
            # bells, report changes, and GitHub comments instead.
            if (line ~ /^[^ ]+ ([0-9a-fA-F]+|none) (clean|dirty)$/) {
                git_noise++; next
            }

            # Reports-row shape: a final-report basename ending in .md (add/
            # remove = a worker finished / was retired = signal).
            if (line ~ /\.md( [0-9.]+)?$/) {
                signal = 1; next
            }

            # Tmux-row shape: <window> bell=<n>
            if (line ~ /^[^ ]+ bell=[0-9]+$/) {
                signal = 1; next
            }

            # Fall back to the section-marker hint if shape did not
            # match. A line under the git section that does not match
            # the standard 3-field shape is still git-section
            # bookkeeping and is suppressed.
            if (section == "git") {
                git_noise++; next
            }
            if (section == "reports") {
                signal = 1; next
            }

            # Unknown shape + unknown section: signal, fail open.
            signal = 1
        }

        END {
            summary = ""
            if (git_noise > 0) summary = git_noise " git-section update(s)"
            print summary
            exit (signal == 1 ? 0 : 1)
        }
    ' "$diff_file"
}

# _target_window_present <target>
#
# Classify the watcher's paste target by tmux window presence. Lifted
# out of main.sh so the fast-respawn vs slow-respawn branching logic
# can be unit-tested without spinning up the whole poll loop. Three
# buckets, by exit code:
#
#   0  target window is present in the current tmux server
#   1  CAN'T CLASSIFY — tmux is not installed/not on PATH, OR the
#      `tmux list-windows` query itself failed (no server running, or
#      a client/server protocol-version mismatch). The window's
#      presence is genuinely unknown.
#   2  tmux query SUCCEEDED and the target window is absent from it
#
# The two failure modes the watcher cares about map to different
# treatments in main.sh:
#
#   rc=2 — window absent. User killed it, agent exited cleanly, tmux
#          server crashed. Nothing to wait for. Fast-respawn fires
#          after AGENT_MISSING_RESPAWN_DELAY confirming polls
#          (default 3 = four consecutive absent observations) plus a
#          pre-launch re-verification (_respawn_verify_target_absent).
#   rc=0 but the agent inside is silent — paste API works, agent isn't
#          acknowledging. Slow-path territory: the agent may be
#          mid-streaming, mid-tool-use, or processing a large pasted
#          message. AGENT_DEAD_THRESHOLD (default 3) gates that path,
#          but a detector for "present-but-silent" is not yet wired
#          into main.sh — the env knob is reserved for when one is.
#
# FAIL CLOSED on a tmux command failure (rc=1, NOT rc=2). The earlier
# implementation piped `tmux list-windows 2>/dev/null | grep -qxF`,
# which masked tmux's own exit status behind grep's: when the query
# FAILED — most insidiously on a `protocol version mismatch` between
# a stale client and a newer server, whose error text the `2>/dev/null`
# swallowed — the pipeline produced empty stdout, grep returned 1, and
# the function reported rc=2 "absent". main.sh then counted that toward
# the fast-respawn streak and spun up a duplicate orchestrator on the
# same jsonl (the U1 respawn-storm cited across operators). A failed
# query means the window's state is UNKNOWN, and respawning needs a
# working tmux anyway, so the safe verdict is "can't classify, hold"
# (rc=1) — never "absent" (rc=2). We therefore capture tmux's rc
# separately from grep's and only fall through to the absent verdict
# when the query genuinely succeeded.
#
# Prints nothing. Exit code IS the answer.
_target_window_present() {
    local target="${1:?target required}"
    command -v tmux >/dev/null 2>&1 || return 1
    local windows tmux_rc
    windows=$(tmux list-windows -F '#{window_name}' 2>/dev/null)
    tmux_rc=$?
    (( tmux_rc == 0 )) || return 1
    grep -qxF "$target" <<<"$windows" && return 0
    return 2
}

# _respawn_loop_check <history_file> <window_seconds> <limit>
#
# Crash-loop guard for `respawn_agent`. Decides whether to allow the
# next orchestrator respawn based on how many respawns have happened
# in the recent past, then records the new respawn iff allowed. The
# history file is a plain text log — one line per allowed respawn,
# format `<epoch_seconds> <free-form-tag>`. Old entries are not
# pruned by this function; callers reset by deleting / truncating
# the file when the orchestrator looks healthy again
# (`_respawn_loop_reset`).
#
# The asymmetric "record only if allowed" semantics matter: it means
# a wedged orchestrator can't keep adding entries that push earlier
# entries out of the sliding window. Once the limit is hit, the
# count stays pinned at the limit until reset.
#
# Prints a human-readable reason on stdout when the guard fires
# (rc=1). Empty stdout when allowed (rc=0). Always succeeds at
# bookkeeping.
#
# Exit codes:
#   0  respawn allowed; entry appended
#   1  guard fires; no entry appended; reason printed to stdout
_respawn_loop_check() {
    local history="${1:?history file required}"
    local window="${2:-120}"
    local limit="${3:-3}"
    local tag="${4:-respawn}"
    local now cutoff count
    now=$(date +%s)
    cutoff=$(( now - window ))
    count=0
    if [[ -f "$history" ]]; then
        count=$(awk -v cutoff="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= cutoff {n++} END {print n+0}' "$history")
    fi
    if (( count >= limit )); then
        printf 'crash-loop guard: %d respawns within %ds (limit=%d)\n' \
               "$count" "$window" "$limit"
        return 1
    fi
    mkdir -p "$(dirname "$history")"
    printf '%s %s\n' "$now" "$tag" >> "$history"
    return 0
}

# _respawn_loop_reset <history_file>
#
# Clear the respawn history. Called when the orchestrator looks
# healthy (a paste-to-target succeeded with content-level
# verification, i.e. main.sh's paste_with_retry returned 0). Gives
# us a "fresh start" counter — three respawns in two minutes only
# trips the guard if NONE of them produced a healthy orchestrator.
_respawn_loop_reset() {
    local history="${1:?history file required}"
    [[ -f "$history" ]] || return 0
    : > "$history"
}

# _respawn_consec_record_failure <counter_file>
#
# Asymmetric counterpart to `_respawn_loop_check`. The sliding-window
# guard above blocks N respawns in a tight window; this counter blocks
# N CONSECUTIVE FAILED respawns regardless of cadence — the slow-grind
# axis (issue #77). A 1-per-60 s drip of failed respawns slides under
# the burst limit indefinitely; this counter catches it.
#
# Storage shape: two lines, `count=<int>` + `last_failure_ts=<epoch>`.
# Keeping the schema parseable by both shell and awk lets ng / tests
# inspect it without ad-hoc regex on a single-line format.
#
# Always succeeds (any I/O hiccup is non-fatal — losing one bookkeeping
# write must not crash the watcher loop). Prints nothing.
_respawn_consec_record_failure() {
    local counter="${1:?counter file required}"
    local now count
    now=$(date +%s)
    count=$(_respawn_consec_get_count "$counter")
    count=$(( count + 1 ))
    mkdir -p "$(dirname "$counter")" 2>/dev/null || true
    {
        printf 'count=%d\n' "$count"
        printf 'last_failure_ts=%d\n' "$now"
    } > "$counter" 2>/dev/null || true
    return 0
}

# _respawn_consec_reset <counter_file>
#
# Clear the consecutive-failure counter. Called on any sign the
# orchestrator is reachable again: a successful `tmux new-window`
# (the failure mode this counter targets) AND a successful
# paste-to-target (the broader "orchestrator looks healthy" signal,
# same trigger as `_respawn_loop_reset`). Removing the file rather
# than truncating keeps `_respawn_consec_get_count` cheap (no parse
# on the common no-failures path).
_respawn_consec_reset() {
    local counter="${1:?counter file required}"
    [[ -f "$counter" ]] || return 0
    rm -f "$counter" 2>/dev/null || true
}

# _respawn_consec_get_count <counter_file>
#
# Print the current consecutive-failure count (0 if the file is
# missing or malformed). Exit code is always 0. Centralised so the
# guard check, the record helper, and the test suite agree on the
# parse rules.
_respawn_consec_get_count() {
    local counter="$1"
    [[ -f "$counter" ]] || { echo 0; return 0; }
    local count
    count=$(awk -F= '$1=="count" {print $2; exit}' "$counter" 2>/dev/null)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    echo "$count"
}

# _respawn_consec_check <counter_file> <limit>
#
# Guard probe: does the current count meet or exceed `limit`? Exits
# 0 (tripped) when yes, 1 when not. Prints a human-readable reason
# on stdout when tripped, empty otherwise — same vocabulary shape as
# `_respawn_loop_check` so callers' log lines stay symmetric.
#
# Does NOT mutate the counter; callers do that via
# `_respawn_consec_record_failure`. Splitting record + check lets the
# main loop record on every failure but only sandbox-notify once at
# the ok → tripped transition.
_respawn_consec_check() {
    local counter="${1:?counter file required}"
    local limit="${2:-5}"
    local count
    count=$(_respawn_consec_get_count "$counter")
    if (( count >= limit )); then
        printf 'slow-grind guard: %d consecutive failed respawns (limit=%d)\n' \
               "$count" "$limit"
        return 0
    fi
    return 1
}

# _watcher_reason <state_dir> [<watcher_window>]
#
# Human-readable reason string matching whatever _watcher_alive
# would have returned. Intended for log lines and incident reports —
# compute once, print multiple places. Prints a one-liner on stdout
# and always returns 0.
_watcher_reason() {
    # $2 (watcher_window) retained-and-ignored: the watcher is
    # headless now, so window absence is no longer a failure mode.
    local state_dir="$1"
    local hb="$state_dir/watcher-heartbeat" age pid
    if [[ ! -f "$hb" ]]; then
        echo "no heartbeat file"
        return 0
    fi
    age=$(_watcher_heartbeat_age "$hb")
    pid=$(_watcher_heartbeat_field "$hb" pid)
    if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        echo "watcher pid=${pid} DEAD (heartbeat age=${age}s)"
        return 0
    fi
    # Alive pid + stale-ish heartbeat: say what the PROGRESS signals say
    # before anyone reads "stale" as "dead" (nexus-code#491). A wedge and
    # a busy loop are different states and must read differently.
    local page
    page=$(_watcher_progress_age "$state_dir" "$pid")
    if _watcher_wedged "$state_dir" "${MONITOR_INTERVAL:-60}"; then
        echo "watcher pid=${pid:-?} alive but WEDGED: no forward progress for ${page}s (heartbeat age=${age}s)"
        return 0
    fi
    if (( page < 999999999 )); then
        echo "heartbeat stale (age=${age}s) but progress ${page}s ago — likely BUSY/ticker-degraded, not dead"
        return 0
    fi
    echo "heartbeat stale (age=${age}s)"
}

# _orchestrator_pin_age <pin_file> <watcher_start_ts>
#
# Print the effective "seconds since the orchestrator was last
# observed healthy" — the spread between `now` and
# `max(pin_file_mtime, watcher_start_ts)`. The watcher-start anchor
# guarantees a fresh install (pin file absent) doesn't appear
# infinitely stale; we only start counting from when the watcher
# itself came up.
#
# Always prints a non-negative integer on stdout and returns 0.
_orchestrator_pin_age() {
    local pin_file="${1:?pin file required}"
    local watcher_start_ts="${2:-0}"
    local now pin_mtime healthy
    now=$(date +%s)
    pin_mtime=0
    if [[ -f "$pin_file" ]]; then
        pin_mtime=$(date +%s -r "$pin_file" 2>/dev/null || echo 0)
        [[ "$pin_mtime" =~ ^[0-9]+$ ]] || pin_mtime=0
    fi
    healthy=$pin_mtime
    if (( healthy < watcher_start_ts )); then
        healthy=$watcher_start_ts
    fi
    local age=$(( now - healthy ))
    (( age < 0 )) && age=0
    printf '%d' "$age"
}

# _orchestrator_unresponsive <last_paste_file> <pin_file> <nexus_root> \
#                            <threshold_s> [<home_dir>]
#
# Paste-driven liveness rule for the orchestrator. Returns 0
# (unresponsive ⇒ caller should respawn) iff ALL hold:
#
#   1. The last-paste timestamp file exists with a parseable epoch
#      (positive evidence: there IS a paste the orch ought to have
#      reacted to). Without a paste to react to, idleness is alive —
#      the previous jsonl-mtime-only signal mistook quiet workspaces
#      for dead orchestrators.
#
#   2. The orch has NOT advanced its jsonl past the paste timestamp.
#      Jsonl mtime is resolved via the pinned session-id; any write
#      to the session log post-paste (a tool call, a turn body, a
#      reply) demonstrates the orch is processing. If the pinned
#      jsonl mtime > last_paste_ts, the orch reacted — alive.
#
#   3. `now - last_paste_ts > threshold_s`. The grace window absorbs
#      legitimately long turns (multi-step tool use, slow tool
#      latency) so a real wedge has to be substantively unresponsive,
#      not just slow.
#
# Returns 1 (alive / no signal) on every other axis: no paste file
# yet (first watcher cycle), unparseable timestamp, jsonl mtime past
# the paste (orch demonstrably responded), or within the grace
# window. Prints a one-liner reason on rc=0; empty on rc=1.
#
# Pure decision — no side effects. Defaults to threshold_s=120 to
# match the documented config default `monitor.orchestrator_
# unresponsive_threshold_seconds`.
_orchestrator_unresponsive() {
    local last_paste_file="${1:?last paste file required}"
    local pin_file="${2:?pin file required}"
    local nexus_root="${3:?nexus_root required}"
    local threshold_s="${4:-120}"
    local home_dir="${5:-$HOME}"

    # Edge case 1: no paste yet this watcher lifetime. There is no
    # signal to act on; orch idleness is alive.
    [[ -f "$last_paste_file" ]] || return 1
    local last_paste_ts
    last_paste_ts=$(head -n 1 "$last_paste_file" 2>/dev/null | tr -d '[:space:]')
    [[ "$last_paste_ts" =~ ^[0-9]+$ ]] || return 1
    (( last_paste_ts > 0 )) || return 1

    local now unresp_age
    now=$(date +%s)
    unresp_age=$(( now - last_paste_ts ))

    # Edge case 2: paste landed within the grace window. Even a real
    # wedge wouldn't have had time to manifest as "unresponsive";
    # don't false-fire on a multi-step turn that's still cooking.
    (( unresp_age > threshold_s )) || return 1

    # Edge case 3: orch reacted post-paste. Pinned jsonl's mtime is
    # the per-poll evidence of "Claude Code is actively writing this
    # session". Resolve via the existing pin → jsonl mapping (see
    # `_orchestrator_jsonl_fresh` for the slug rule). Missing or
    # unparseable pin / jsonl ⇒ fall through to "unresponsive" — at
    # this point we KNOW a paste landed > threshold ago AND we have
    # no evidence the orch processed it.
    local sid slug jsonl jsonl_mtime
    if [[ -s "$pin_file" ]]; then
        sid=$(head -n 1 "$pin_file" 2>/dev/null | tr -d '[:space:]')
    fi
    if [[ -n "${sid:-}" ]] \
       && [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        slug=$(printf '%s' "$nexus_root" | sed 's|[^a-zA-Z0-9]|-|g')
        jsonl="$home_dir/.claude/projects/$slug/$sid.jsonl"
        if [[ -f "$jsonl" ]]; then
            jsonl_mtime=$(date +%s -r "$jsonl" 2>/dev/null || echo 0)
            if [[ "$jsonl_mtime" =~ ^[0-9]+$ ]] && (( jsonl_mtime > last_paste_ts )); then
                return 1
            fi
        fi
    fi

    printf 'unresponsive_age=%ds threshold=%ds last_paste_ts=%d' \
        "$unresp_age" "$threshold_s" "$last_paste_ts"
    return 0
}

# _orchestrator_should_fresh_spawn <pin_file> <cooldown_file> \
#                                  <last_paste_file> <unresponsive_threshold_s> \
#                                  <cooldown_s> <nexus_root> [<home_dir>]
#
# Decide whether to fresh-spawn the orchestrator THIS cycle. Returns
# 0 (fire) when BOTH hold:
#   - `_orchestrator_unresponsive` returns 0 (positive evidence the
#     orch is not reacting to a paste delivered more than the
#     unresponsive-threshold ago), AND
#   - the cooldown marker is absent OR its mtime is older than
#     `cooldown_s`.
# Returns 1 otherwise. Prints a one-liner reason on stdout on rc=0;
# empty on rc=1.
#
# History: pre-PR for issue #157 this function used a jsonl-mtime-
# only signal (alive iff pin_age < threshold). That signal mistook
# quiet workspaces for dead orchestrators — an idle orch writes
# nothing, so its jsonl mtime aged out and the probe fired every
# cooldown. The paste-driven rule is the operator's directive: idle
# is alive; only unresponse to a real paste is death.
#
# The function makes NO side effects — pure decision. The caller is
# responsible for writing the cooldown marker (spawn-fresh-
# orchestrator.sh does so unconditionally as part of its event log).
_orchestrator_should_fresh_spawn() {
    local pin_file="${1:?pin file required}"
    local cooldown_file="${2:?cooldown file required}"
    local last_paste_file="${3:?last paste file required}"
    local unresponsive_threshold_s="${4:-120}"
    local cooldown_s="${5:-1800}"
    local nexus_root="${6:?nexus_root required}"
    local home_dir="${7:-$HOME}"

    local reason
    reason=$(_orchestrator_unresponsive \
                "$last_paste_file" "$pin_file" "$nexus_root" \
                "$unresponsive_threshold_s" "$home_dir") || return 1

    local cooldown_mtime now
    cooldown_mtime=0
    if [[ -f "$cooldown_file" ]]; then
        cooldown_mtime=$(date +%s -r "$cooldown_file" 2>/dev/null || echo 0)
        [[ "$cooldown_mtime" =~ ^[0-9]+$ ]] || cooldown_mtime=0
    fi
    now=$(date +%s)
    if (( cooldown_mtime > 0 )) && (( now - cooldown_mtime < cooldown_s )); then
        return 1
    fi
    printf '%s cooldown_age=%ds/%ds\n' \
        "$reason" \
        "$(( cooldown_mtime > 0 ? now - cooldown_mtime : 0 ))" \
        "$cooldown_s"
    return 0
}

# _orchestrator_record_paste <last_paste_file>
#
# Stamp the orchestrator-last-paste timestamp atomically. Called by
# main.sh's `paste_to_target` after every successful paste to the
# orchestrator window. The file's contents (epoch on line 1) drive
# the paste-driven liveness signal in `_orchestrator_unresponsive`.
#
# Atomic write via tmp + mv so a half-written file can never confuse
# the reader. Always returns 0 — a stamp write failure must not crash
# the watcher loop (worst case the probe sees a missing/stale file
# and treats it as "no signal" until the next paste).
_orchestrator_record_paste() {
    local last_paste_file="${1:?last paste file required}"
    local now
    now=$(date +%s)
    mkdir -p "$(dirname "$last_paste_file")" 2>/dev/null || true
    printf '%d\n' "$now" > "${last_paste_file}.tmp" 2>/dev/null \
        && mv "${last_paste_file}.tmp" "$last_paste_file" 2>/dev/null || true
    return 0
}

# _orchestrator_refresh_pin <pin_file>
#
# Touch the pin file's mtime to "now" iff it already exists and is
# non-empty. Called by the watcher's `paste_to_target` after every
# successful paste-buffer round-trip — the freshly-touched mtime is
# the orchestrator-liveness probe's "this orch is reachable RIGHT NOW"
# signal (issue #150).
#
# Anchoring on paste-success rather than the watcher's own heartbeat
# preserves the probe's purpose: a watcher pasting into a dead pane
# returns rc!=0, the pin is left stale, and the probe still fires as
# designed. Anchoring on the UserPromptSubmit hook (PR #147) was the
# previous wiring; it false-fires on quiet workspaces (no paste, no
# hook) AND on busy orchestrators (paste queued mid-tool-call by
# Claude Code is delivered as a follow-up message rather than a fresh
# UserPromptSubmit, so the hook never fires).
#
# Strict no-op on missing or empty pin file. The probe's
# `max(pin_mtime, WATCHER_START_TS)` anchor already covers the
# launcher-grace case (orch was started without `--settings`, no pin
# yet); creating a phantom pin here would mask a genuinely-missing
# orchestrator-settings install.
#
# Returns 0 always (touch failures are non-fatal — worst case, the
# probe fires one cycle early and respawns; that path is well-tested).
_orchestrator_refresh_pin() {
    local pin_file="${1:?pin file required}"
    if [[ -s "$pin_file" ]]; then
        touch -c "$pin_file" 2>/dev/null || true
    fi
    return 0
}

# _orchestrator_jsonl_fresh <session_id> <freshness_s> <nexus_root> [home_dir]
#
# Returns 0 (fresh) when ~/.claude/projects/<slug>/<session_id>.jsonl
# exists and has been written within `freshness_s`. Returns 1 (stale,
# missing, or unreadable) otherwise.
#
# `<slug>` is the Claude-Code project-slug encoding of `<nexus_root>`:
# leading slash kept as '-', every non-alphanumeric (including '_'
# and '.') replaced with '-'. This matches `ng report-init`'s slug
# rule (test-ng-report-init.sh Test 8) and the actual on-disk layout
# under `~/.claude/projects/`.
#
# `<home_dir>` defaults to `$HOME` so tests can plant a fake tree at
# `$FAKE_HOME/.claude/projects/<slug>/<sid>.jsonl`.
#
# Failure modes (all → return 1, no side effects):
#   - empty session_id (argument unset) — caller must filter.
#   - jsonl absent.
#   - jsonl mtime older than `freshness_s` (stale orchestrator
#     session, or wrong-session-resume left the pinned-sid's log
#     dormant while a different session writes to a sibling jsonl).
#
# This pairs with `_orchestrator_poll_refresh_pin` below: a fresh
# jsonl is the per-poll evidence that the *pinned* session is the
# one Claude Code is actually writing to, even when no
# `paste_to_target` round-trip happened this cycle. Empirical
# limitation: on a truly idle orchestrator (no internal tool calls,
# no watcher-driven pastes) the jsonl mtime can drift past
# `freshness_s`. See PR notes for follow-up tuning.
_orchestrator_jsonl_fresh() {
    local sid="${1:-}"
    local freshness_s="${2:-300}"
    local nexus_root="${3:?nexus_root required}"
    local home_dir="${4:-$HOME}"
    [[ -n "$sid" ]] || return 1
    # UUID-shape guard mirrors orchestrator-session-pin.sh — protects
    # against a torn pin write seeding a path like .../.jsonl.
    [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 1
    local slug jsonl mtime now
    slug=$(printf '%s' "$nexus_root" | sed 's|[^a-zA-Z0-9]|-|g')
    jsonl="$home_dir/.claude/projects/$slug/$sid.jsonl"
    [[ -f "$jsonl" ]] || return 1
    mtime=$(date +%s -r "$jsonl" 2>/dev/null || echo 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    (( mtime > 0 )) || return 1
    now=$(date +%s)
    (( now - mtime <= freshness_s ))
}

# _orchestrator_poll_refresh_pin <pin_file> <freshness_s> <nexus_root>
#
# Poll-cycle pin refresh anchored on the orchestrator's session-log
# liveness (issue #150 follow-up to PR #151). PR #151 anchored the
# pin refresh on `paste_to_target` rc=0; that only fires when the
# watcher emits a state-change diff, so quiet workspaces saw the pin
# go stale and the liveness probe fresh-spawn fired every cooldown
# (~30 min cadence). This helper widens the refresh signal: any
# poll cycle where the *pinned* session's jsonl was written within
# `freshness_s` is evidence that Claude Code is actively servicing
# that session and the pin should reflect "alive this poll".
#
# Decision matrix:
#   - empty/missing pin file → no-op (launcher grace; the probe's
#     `max(pin_mtime, WATCHER_START_TS)` anchor covers this case
#     without any phantom pin write).
#   - pin sid + jsonl fresh → touch pin to now.
#   - pin sid + jsonl stale/absent → no-op (probe stays armed for
#     wrong-session-resume + truly-dead-session detection).
#
# Always rc=0. Callers don't branch on this; the pin's mtime is
# the consumed signal.
_orchestrator_poll_refresh_pin() {
    local pin_file="${1:?pin file required}"
    local freshness_s="${2:-300}"
    local nexus_root="${3:?nexus_root required}"
    [[ -s "$pin_file" ]] || return 0
    local sid
    sid=$(head -n 1 "$pin_file" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$sid" ]] || return 0
    if _orchestrator_jsonl_fresh "$sid" "$freshness_s" "$nexus_root"; then
        touch -c "$pin_file" 2>/dev/null || true
    fi
    return 0
}

# --- wrong-launch guards (issue #203 follow-up: 2026-06-11 incident) -------
#
# Shared predicates for the cockpit (svc.sh), the watcher (main.sh),
# and entry.sh to detect that they were launched WRONG — into the
# orchestrator's window, or next to an already-running peer — and
# self-close with an informative message instead of squatting. The
# 2026-06-11 incident class: a service cockpit occupying (or being
# renamed into) the window named `monitor.target_window` masks the
# orchestrator's absence from the watcher's name-based probe, so no
# recovery ever fires.
#
# Design rules (all guards are CONSERVATIVE — fail-open):
#   - Any indeterminate probe (no tmux, stubbed tmux returning
#     nothing, unreadable /proc) answers "not wrong" so a legitimate
#     first cockpit / the real headless watcher is never refused.
#   - Window-name checks require that the pane named by $TMUX_PANE
#     actually HOSTS the calling process (pane_pid is the process or
#     one of its ancestors). $TMUX_PANE is inherited through env —
#     e.g. the setsid-detached headless watcher spawned from the
#     orchestrator's Bash tool carries the ORCHESTRATOR's pane id —
#     so trusting it without the ancestry check would self-close the
#     legitimate watcher.

# _nexus_pid_is_ancestor <ancestor_pid> <pid>
#
# Return 0 iff <ancestor_pid> equals <pid> or appears in <pid>'s
# parent chain (bounded at 25 hops). Uses `ps -o ppid=` per hop —
# portable, and a setsid'd orphan terminates the walk at pid 1.
_nexus_pid_is_ancestor() {
    local anc="${1:-}" pid="${2:-}" hops=0
    [[ "$anc" =~ ^[0-9]+$ && "$pid" =~ ^[0-9]+$ ]] || return 1
    while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 && hops < 25 )); do
        (( pid == anc )) && return 0
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        hops=$(( hops + 1 ))
    done
    return 1
}

# _nexus_self_pane_window
#
# If $TMUX_PANE names a live pane whose pane_pid hosts THIS process
# (is the process itself or an ancestor), print
# "<window_id>\t<window_name>" and return 0. Return 1 otherwise —
# including the inherited-TMUX_PANE case (headless watcher, Bash-tool
# grandchildren of another window's claude are still "hosted": claude
# IS an ancestor — callers wanting to exclude that combine this with
# their own context, see the watcher guard's WATCHER_WINDOW check).
_nexus_self_pane_window() {
    [[ -n "${TMUX_PANE:-}" ]] || return 1
    command -v tmux >/dev/null 2>&1 || return 1
    local pane_pid
    pane_pid=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null)
    [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
    _nexus_pid_is_ancestor "$pane_pid" "$$" || return 1
    local info
    info=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}'$'\t''#{window_name}' 2>/dev/null)
    [[ -n "$info" ]] || return 1
    printf '%s\n' "$info"
    return 0
}

# _nexus_pid_tree_has_env_marker <pid> <NAME=value> [<max_depth>]
#
# Return 0 iff <pid> or any descendant (bounded BFS, default depth 3)
# carries the exact environment line <NAME=value>. Linux-only
# (/proc/<pid>/environ); unreadable /proc returns 1 and callers
# degrade. Child discovery via `pgrep -P` — PID-scoped, per the
# no-mass-kill rule. Mirrors _respawn_pid_tree_is_orchestrator
# (_respawn.sh) generically so svc.sh / entry.sh need not source the
# respawn module.
_nexus_pid_tree_has_env_marker() {
    local pid="$1" marker="$2" depth="${3:-3}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -r "/proc/$pid/environ" ]] \
       && tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
          | grep -qxF "$marker"; then
        return 0
    fi
    (( depth <= 0 )) && return 1
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do
        if _nexus_pid_tree_has_env_marker "$child" "$marker" $(( depth - 1 )); then
            return 0
        fi
    done
    return 1
}

# _nexus_window_has_orchestrator <window_id_or_name>
#
# Return 0 iff any pane of the given window hosts a process tree
# carrying NEXUS_IS_ORCHESTRATOR=1 (every orchestrator spawn path
# exports it; see _respawn_compose_launcher). Used by the self-close
# guards to decide whether renaming a wrongly-occupied target window
# OFF the target name is safe: with a live orchestrator sharing the
# window the rename would yank the name from under it (the watcher's
# re-verify heal renames it back, but the churn is avoidable).
_nexus_window_has_orchestrator() {
    local win="${1:?window required}" pid
    command -v tmux >/dev/null 2>&1 || return 1
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        _nexus_pid_tree_has_env_marker "$pid" 'NEXUS_IS_ORCHESTRATOR=1' && return 0
    done < <(tmux list-panes -t "$win" -F '#{pane_pid}' 2>/dev/null)
    return 1
}

# _nexus_pid_is_cockpit <pid>
#
# Return 0 iff <pid> is a no-arg (dashboard-mode) svc.sh invocation.
# Identity via the program slot, mirroring _watcher_pid_is_live_watcher:
# argv is ["bash", ".../svc.sh"] (shebang launch) or [".../svc.sh"]
# (direct exec) — i.e. the LAST argv element ends in svc.sh AND argc
# <= 2. Verb invocations (`svc.sh status`, `svc.sh restart watcher`)
# carry more arguments and never match; a claude whose PROMPT quotes
# svc.sh has argc >> 2 and never matches either.
_nexus_pid_is_cockpit() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    local -a argv=()
    local arg
    while IFS= read -r -d '' arg; do argv+=("$arg"); done \
        < "/proc/$pid/cmdline" 2>/dev/null
    (( ${#argv[@]} >= 1 && ${#argv[@]} <= 2 )) || return 1
    case "${argv[${#argv[@]}-1]}" in
        */svc.sh|svc.sh) return 0 ;;
    esac
    return 1
}

# _nexus_find_live_cockpit_pane [<exclude_pane_id>]
#
# Scan every tmux pane for a live dashboard-mode cockpit (the pane's
# root process or one of its direct children passing
# _nexus_pid_is_cockpit). Print "<pid>\t<window_id>\t<window_name>"
# for the first hit and return 0; return 1 when none. Pass the
# caller's own $TMUX_PANE as <exclude_pane_id> so a cockpit never
# detects itself. Pane-scan (not a pidfile) so cockpits started
# before this guard existed are still detected.
_nexus_find_live_cockpit_pane() {
    local exclude="${1:-}"
    command -v tmux >/dev/null 2>&1 || return 1
    local pane_id pane_pid win_id win_name child
    while IFS='|' read -r pane_id pane_pid win_id win_name; do
        [[ "$pane_pid" =~ ^[0-9]+$ ]] || continue
        [[ -n "$exclude" && "$pane_id" == "$exclude" ]] && continue
        if _nexus_pid_is_cockpit "$pane_pid"; then
            printf '%s\t%s\t%s\n' "$pane_pid" "$win_id" "$win_name"
            return 0
        fi
        for child in $(pgrep -P "$pane_pid" 2>/dev/null); do
            if _nexus_pid_is_cockpit "$child"; then
                printf '%s\t%s\t%s\n' "$child" "$win_id" "$win_name"
                return 0
            fi
        done
    done < <(tmux list-panes -a -F '#{pane_id}|#{pane_pid}|#{window_id}|#{window_name}' 2>/dev/null)
    return 1
}
