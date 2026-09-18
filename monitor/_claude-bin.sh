#!/bin/bash
# monitor/_claude-bin.sh — shared $CLAUDE_BIN resolver for spawn surfaces.
#
# Sourced by every script that spawns a `claude` process. Resolves the
# binary path in this order:
#   1. CLAUDE_BIN env var (operator override).
#   2. $NEXUS_ROOT/node_modules/.bin/claude — project-local install,
#      managed by monitor/install-claude-local.sh.
#   3. `claude` on PATH (legacy system install).
# Fails loud with exit 1 if none are found.
#
# Why a shared helper: keeping the resolver in one file means future
# changes (e.g. a third lookup path, version-floor check) land in one
# place instead of drifting across spawn-worker.sh, entry.sh, main.sh,
# spawn-fresh-orchestrator.sh, bootstrap-install.sh, and claude-loop.sh.
#
# Why baked into heredocs at write time: every spawn surface writes a
# /tmp launcher script and tmux-spawns it. The launcher's heredoc is
# unquoted, so $CLAUDE_BIN interpolates at write time and the launcher
# contains the absolute path verbatim. This avoids re-resolving inside
# the launcher's shell (which may not have NEXUS_ROOT set yet).
#
# Caller contract: $NEXUS_ROOT must be set before sourcing. The helper
# is destructive on failure (calls `exit 1`) — that's intentional, a
# spawn surface that can't find claude has no recovery path.

if [[ -z "${NEXUS_ROOT:-}" ]]; then
    echo "_claude-bin.sh: NEXUS_ROOT must be set before sourcing" >&2
    exit 1
fi

if [[ -z "${CLAUDE_BIN:-}" ]]; then
    if [[ -x "$NEXUS_ROOT/node_modules/.bin/claude" ]]; then
        CLAUDE_BIN="$NEXUS_ROOT/node_modules/.bin/claude"
    elif command -v claude >/dev/null 2>&1; then
        CLAUDE_BIN="$(command -v claude)"
    else
        echo "_claude-bin.sh: no claude binary found" >&2
        echo "  Looked for: $NEXUS_ROOT/node_modules/.bin/claude" >&2
        echo "              claude on PATH" >&2
        echo "  Run: $NEXUS_ROOT/monitor/install-claude-local.sh" >&2
        exit 1
    fi
fi
export CLAUDE_BIN

# ---------------------------------------------------------------------------
# THE CAPABILITY PROBE'S BOUND (your-org/nexus-code#1289)
# ---------------------------------------------------------------------------
# `claude_supports_name_flag` runs `"$CLAUDE_BIN" --help`. That call sits on
# the watcher's ORCHESTRATOR-RESPAWN path — `_respawn.sh:716-717`, inside
# `_respawn_compose_launcher`, called at `:1173` immediately before
# `_respawn_spawn_window` at `:1176` — and the whole compose+spawn dance runs
# under the async in-flight guard (`_target_absent.sh:159-162`). So for as
# long as `--help` takes, the guard holds, the orchestrator does not exist,
# and every watcher poll logs the benign-sounding `respawn-agent (async):
# launch deferred (in flight)`. The failure mode is not a crash; it is a
# live-looking watcher repeating a reassuring line while the board has no
# control surface.
#
# THE VALUE IS FITTED, NOT GUESSED. Measured on this host, project-local
# install, 6 warm runs: 331/381/401/331/356/386 ms (mean 370 ms), 16890 bytes,
# rc 0. 10 s is ~27x the warm mean. COVERAGE BOUNDARY, stated because it is
# the case the bound exists for: a COLD read of the binary off shared storage
# was NOT measured and could be materially slower — 10 s is a generous ceiling
# rather than a fitted p99. Override with $NEXUS_CLAUDE_HELP_TIMEOUT;
# $NEXUS_CLAUDE_HELP_TIMEOUT_BIN is a test seam for the `timeout`-ABSENT path
# (never set in production).
#
# WHAT A BOUND CANNOT DO. `timeout` bounds a SLOW probe, not an
# UNINTERRUPTIBLE one: a process wedged in uninterruptible sleep on a stalled
# NFS mount ignores TERM and KILL alike, so `timeout` itself would wait. `-k`
# narrows this (a TERM-ignoring child is KILLed) but cannot close it. This
# change converts the unbounded-hang class into a bounded one; it does not
# claim to make the probe non-blocking.
: "${NEXUS_CLAUDE_HELP_TIMEOUT:=10}"
# DO NOT ADD `--foreground`. Measured on this host, against a stub whose
# `--help` spawns a child `sleep 30`:
#
#   timeout -k 2 1 stub --help              -> rc 124 in  1005 ms
#   timeout --foreground -k 2 1 stub --help -> rc 124 in 30014 ms
#
# `timeout` signals the whole process GROUP by default; `--foreground` signals
# only the direct child, and the orphaned grandchild keeps the command
# substitution's pipe open — so `$( … )` blocks for the child's full lifetime
# and the bound becomes decorative WHILE STILL REPORTING rc 124. A remedy that
# reinstates the defect it was added to fix, and reports success at doing so,
# is worse than no remedy.
#
# Resolved ONCE, here, rather than per call: an absent `timeout` must be
# reported as a real degradation (the wedge is back), not silently tolerated.
# $NEXUS_CLAUDE_HELP_TIMEOUT_BIN is a TEST SEAM (never set in production) and
# is honoured even when set to the EMPTY string — that is how the unbounded
# path is exercised at all. `${VAR+set}` distinguishes "unset" from
# "deliberately empty"; `${VAR:-}` cannot.
if [[ -n "${NEXUS_CLAUDE_HELP_TIMEOUT_BIN+set}" ]]; then
    _CLAUDE_TIMEOUT_BIN="$NEXUS_CLAUDE_HELP_TIMEOUT_BIN"
elif command -v timeout >/dev/null 2>&1; then
    _CLAUDE_TIMEOUT_BIN=$(command -v timeout)
elif [[ -x /usr/bin/timeout ]]; then
    _CLAUDE_TIMEOUT_BIN=/usr/bin/timeout
else
    _CLAUDE_TIMEOUT_BIN=""
fi

# claude_supports_name_flag
#
# Capability probe for `-n/--name <name>` ("Set a display name for this
# session"), the flag that pins a session's MESSAGING name — the string
# cross-session SendMessage uses as the address (your-org/nexus-code#1047).
#
# By CAPABILITY, never by version string — the same rule monitor/gh-capable.sh
# applies to `gh`. Operators pin and bump Claude Code deliberately
# (skills/nexus.cc-update), so a spawn surface must not assume the flag exists.
#
# Why this is a REFUSAL to add the flag rather than a refusal to spawn: an
# unsupported flag is FATAL, not ignored — measured on this host,
# `claude --nosuchflag-xyz` exits 1 with "error: unknown option". Baking the
# flag in unconditionally would therefore kill every worker spawn AND every
# orchestrator respawn on an older pin, taking out the watcher's own recovery
# path to fix a naming nicety. Degrading to the derived name is strictly better
# than a dead orchestrator.
#
# It warns on stderr when it degrades, because a silently-omitted flag is this
# workspace's dominant defect class: the address quietly reverts to the derived
# name and escalation fails later, far from the cause.
#
# Returns 0 if the flag is supported, 1 otherwise. NEVER blocks without a
# bound when a `timeout` binary exists: see $NEXUS_CLAUDE_HELP_TIMEOUT above
# (your-org/nexus-code#1289). A timeout is reported as a TIMEOUT, distinctly
# from "the binary answered and said no" and from "the binary failed to run" —
# the three have different remedies and #1248 is the reason the injected 124
# must not pass for the callee's own status.
#
# CACHE LIFETIME: the answer is memoised in $_CLAUDE_NAME_FLAG_CACHED for the
# life of THIS shell process only, and it is keyed on nothing — not on
# $CLAUDE_BIN. That is correct for every caller here, because each spawn
# surface resolves $CLAUDE_BIN once and then invokes the probe one or more
# times for that same binary, and the warning is emitted once rather than per
# call site. It is NOT safe for a caller that changes $CLAUDE_BIN and re-asks
# in the same shell: it would get the previous binary's answer. Nothing does
# that in production; test-session-name-from-window.sh probes several different
# binaries, and gets a fresh answer each time because every probe runs in its
# own `( … )` subshell rather than by clearing the cache. A caller that must
# re-ask in ONE shell has to unset $_CLAUDE_NAME_FLAG_CACHED itself.
# The cache is not exported, so a child process re-probes (one `--help` per
# spawned launcher, which is the intended cost).
claude_supports_name_flag() {
    if [[ -n "${_CLAUDE_NAME_FLAG_CACHED:-}" ]]; then
        [[ "$_CLAUDE_NAME_FLAG_CACHED" == "yes" ]] && return 0
        return 1
    fi
    local help_out='' _rc=0 _bounded=0
    # Capture BEFORE testing: `cmd | grep` would report grep's status, not
    # claude's, and a claude that failed to run would read as "no such flag"
    # (CLAUDE.md, pipeline-status entry). `local` is declared SEPARATELY from
    # the assignment for the same family of reason: `local x=$(cmd)` returns
    # `local`'s status, not the command's, and $_rc is read on the very next
    # line because anything executing in between is a write to $?.
    if [[ -n "$_CLAUDE_TIMEOUT_BIN" ]]; then
        _bounded=1
        help_out=$("$_CLAUDE_TIMEOUT_BIN" -k 2 "$NEXUS_CLAUDE_HELP_TIMEOUT" "${CLAUDE_BIN}" --help 2>/dev/null)
        _rc=$?
    else
        # No `timeout` on this host: the #1289 wedge is UNBOUNDED again. Say so
        # rather than degrade in silence — a missing bound is exactly the
        # condition whose whole symptom is that nothing appears to be wrong.
        echo "_claude-bin: no 'timeout' binary found — probing '${CLAUDE_BIN} --help' UNBOUNDED. On the watcher respawn path a hang here holds the in-flight guard and the orchestrator stays dead (your-org/nexus-code#1289)." >&2
        help_out=$("${CLAUDE_BIN}" --help 2>/dev/null)
        _rc=$?
    fi

    # A TIMEOUT IS NOT "THE BINARY SAID NO" — and it is not even in the
    # callee's vocabulary (your-org/nexus-code#1248). `timeout` INJECTS 124
    # (TERM fired) or, with -k, 137 (KILL after the grace). Measured on this
    # host, GNU coreutils 8.28. Both are indistinguishable from a claude exit
    # code unless they are named here, so they are checked FIRST and BEFORE
    # any look at content: a probe that had to be killed already cost the
    # respawn lock, and whatever partial bytes it flushed are not an answer.
    # The `_bounded` gate matters — without it, an UNBOUNDED claude that
    # happened to exit 124 would be mislabelled a timeout.
    if (( _bounded )) && { (( _rc == 124 )) || (( _rc == 137 )); }; then
        _CLAUDE_NAME_FLAG_CACHED=no
        echo "_claude-bin: '${CLAUDE_BIN} --help' TIMED OUT after ${NEXUS_CLAUDE_HELP_TIMEOUT}s (killed, rc ${_rc}) — NOT passing --name; this session will self-name from its cwd basename and will not be addressable by its tmux window name (your-org/nexus-code#1047, bound per #1289). A --help this slow is a degraded binary or a stalled filesystem, not an answer about the flag." >&2
        return 1
    fi
    if [[ -z "$help_out" ]]; then
        # Could not ask. Fail CLOSED on the FLAG (omit it), loudly — an
        # unreadable --help is not evidence the flag is absent, and guessing
        # "supported" here is the branch that kills the spawn.
        _CLAUDE_NAME_FLAG_CACHED=no
        echo "_claude-bin: could not read '${CLAUDE_BIN} --help' (rc ${_rc}) — NOT passing --name; this session will self-name from its cwd basename and will not be addressable by its tmux window name (your-org/nexus-code#1047)." >&2
        return 1
    fi
    case "$help_out" in
        *"--name <name>"*) _CLAUDE_NAME_FLAG_CACHED=yes; return 0 ;;
    esac
    _CLAUDE_NAME_FLAG_CACHED=no
    echo "_claude-bin: this claude does not support '--name' — NOT passing it; this session will self-name from its cwd basename and will not be addressable by its tmux window name (your-org/nexus-code#1047)." >&2
    return 1
}

# claude_supports_plugin_dir_flag
#
# Capability probe for `--plugin-dir <path>` ("Load a plugin from a directory
# or .zip for this session only"), the flag that arms the longjob-watch
# dispatcher's plugin monitor at session start (your-org/nexus-code#1535).
# Same contract, same reasons and the SAME failure discipline as
# claude_supports_name_flag above: by capability, never by version; a timeout
# is reported as a TIMEOUT and read as "not supported" (the flag is omitted,
# the spawn proceeds); an unreadable --help is "not supported"; and every
# degrade is said on stderr once, because a silently-omitted flag here means a
# session that can never be woken by a long job and looks exactly like one
# that has nothing to wait for. Memoised in $_CLAUDE_PLUGIN_DIR_FLAG_CACHED
# with the cache-lifetime caveat documented above.
#
# Returns 0 if the flag is supported, 1 otherwise.
claude_supports_plugin_dir_flag() {
    if [[ -n "${_CLAUDE_PLUGIN_DIR_FLAG_CACHED:-}" ]]; then
        [[ "$_CLAUDE_PLUGIN_DIR_FLAG_CACHED" == "yes" ]] && return 0
        return 1
    fi
    local help_out='' _rc=0 _bounded=0
    if [[ -n "$_CLAUDE_TIMEOUT_BIN" ]]; then
        _bounded=1
        help_out=$("$_CLAUDE_TIMEOUT_BIN" -k 2 "$NEXUS_CLAUDE_HELP_TIMEOUT" "${CLAUDE_BIN}" --help 2>/dev/null)
        _rc=$?
    else
        help_out=$("${CLAUDE_BIN}" --help 2>/dev/null)
        _rc=$?
    fi
    if (( _bounded )) && { (( _rc == 124 )) || (( _rc == 137 )); }; then
        _CLAUDE_PLUGIN_DIR_FLAG_CACHED=no
        echo "_claude-bin: '${CLAUDE_BIN} --help' TIMED OUT after ${NEXUS_CLAUDE_HELP_TIMEOUT}s (killed, rc ${_rc}) — NOT passing --plugin-dir; this session will have NO longjob-watch dispatcher and cannot be woken by a long job (your-org/nexus-code#1535)." >&2
        return 1
    fi
    if [[ -z "$help_out" ]]; then
        _CLAUDE_PLUGIN_DIR_FLAG_CACHED=no
        echo "_claude-bin: could not read '${CLAUDE_BIN} --help' (rc ${_rc}) — NOT passing --plugin-dir; this session will have NO longjob-watch dispatcher (your-org/nexus-code#1535)." >&2
        return 1
    fi
    case "$help_out" in
        *"--plugin-dir <path>"*) _CLAUDE_PLUGIN_DIR_FLAG_CACHED=yes; return 0 ;;
    esac
    _CLAUDE_PLUGIN_DIR_FLAG_CACHED=no
    echo "_claude-bin: this claude does not support '--plugin-dir' — NOT passing it; this session will have NO longjob-watch dispatcher and cannot be woken by a long job (your-org/nexus-code#1535)." >&2
    return 1
}
