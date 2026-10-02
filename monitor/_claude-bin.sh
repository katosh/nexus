#!/bin/bash
# monitor/_claude-bin.sh — shared $CLAUDE_BIN resolver for spawn surfaces.
#
# Sourced by every script that spawns a `claude` process. Resolves the
# binary path in this order:
#   1. CLAUDE_BIN env var (operator override).
#   2. `nexus.claude_bin` in config/nexus.yml — operator-local pin to a
#      claude install OUTSIDE the repo (a native Claude Code install,
#      e.g. ~/.local/bin/claude). See "Why a config key" below.
#   3. $NEXUS_ROOT/node_modules/.bin/claude — project-local npm install,
#      managed by monitor/install-claude-local.sh.
#   4. `claude` on PATH (legacy system install). Suppressed when
#      CLAUDE_BIN_NO_PATH is set — see below.
# Fails loud if none are found; see "Exit codes" at the end.
#
# CLAUDE_BIN_NO_PATH exists for exactly one caller:
# monitor/link-nexus-tools.sh, which WRITES `locals/bin/claude` — and
# `locals/bin` is at the FRONT of every agent's PATH. Letting that
# caller consume lookup 4 is circular: `command -v claude` would find
# the very link it is about to rewrite, and the linker would point the
# link at itself. Any caller that is a PATH *producer* must set this.
#
# Why a config key for lookup 2 (jacob-greene/nexus#219, native-install
# switch). An operator who runs the NATIVE Claude Code install wants
# every spawn surface on it, and wants the npm tree gone. Three
# properties are needed and only a config key has all three:
#   - It must OUTRANK node_modules. Lookup 3 previously came first, so
#     a re-appearing node_modules (a stray `npm install`, a fresh
#     bootstrap) would silently take the workspace back to the npm
#     binary with no error anywhere.
#   - It must be OPERATOR-LOCAL. config/nexus.yml is gitignored; this
#     tracked file is shared by every operator, so an absolute path
#     like /home/<someone>/.local/bin/claude can never live in source.
#   - It must reach the surfaces $CLAUDE_BIN does not. An env export
#     only covers processes that inherit it; the cc-update scripts run
#     from the watcher and previously hard-coded the npm path.
# The lookup is SOFT on the loader (config/load.sh needs python3 +
# pyyaml): a loader failure degrades to lookups 3/4, exactly the
# pre-change behaviour. It is HARD on the value: a key that is set but
# does not resolve to an executable is a fatal error, never a silent
# fall-through to node_modules — the whole point is that the operator's
# choice cannot be quietly overridden.
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
# is destructive on failure (calls `exit`) — that's intentional, a
# spawn surface that can't find claude has no recovery path. Callers
# that need to survive a failure probe it in a subshell first (see
# monitor/watcher/_respawn.sh and monitor/bootstrap-install.sh).
#
# Exit codes (a subshell probe reads these):
#   0  resolved; $CLAUDE_BIN exported.
#   1  nothing found by any lookup. RECOVERABLE — bootstrap-install.sh
#      answers this by installing the project-local npm copy.
#   2  `nexus.claude_bin` is set but does not resolve to an executable.
#      NOT recoverable by installing: the operator named a binary and
#      it is wrong, so re-creating node_modules would override a
#      deliberate choice instead of honouring it. Callers must refuse.

if [[ -z "${NEXUS_ROOT:-}" ]]; then
    echo "_claude-bin.sh: NEXUS_ROOT must be set before sourcing" >&2
    exit 1
fi

if [[ -z "${CLAUDE_BIN:-}" ]]; then
    # Lookup 2 — operator-local config pin. Soft on the loader (a
    # missing python3/pyyaml prints nothing and yields ""), hard on a
    # set-but-broken value (die rather than fall back to npm).
    _cb_cfg=""
    _cb_rc=0
    if [[ -x "$NEXUS_ROOT/config/load.sh" ]]; then
        _cb_cfg=$("$NEXUS_ROOT/config/load.sh" nexus.claude_bin "" 2>/dev/null) || _cb_rc=$?
        # load.sh exit 3 = no pyyaml-capable python3. That is a broken
        # loader, not "the key is unset", and the difference is invisible
        # downstream: we would fall through to the npm tree and the
        # operator would never learn their pin was ignored. Warn, once per
        # resolution, and carry on — degrading is still better than
        # refusing to spawn over a missing python module.
        if (( _cb_rc == 3 )); then
            echo "_claude-bin.sh: WARNING config/load.sh cannot read yaml (no pyyaml)" >&2
            echo "  nexus.claude_bin, if set, is being IGNORED. Install pyyaml for the" >&2
            echo "  python3 on PATH, or set CLAUDE_BIN explicitly." >&2
        fi
        (( _cb_rc == 0 )) || _cb_cfg=""
    fi
    # Trim surrounding whitespace (a trailing newline survives $( ) only
    # if embedded, but a stray space in the yaml value would not).
    _cb_cfg="${_cb_cfg#"${_cb_cfg%%[![:space:]]*}"}"
    _cb_cfg="${_cb_cfg%"${_cb_cfg##*[![:space:]]}"}"

    if [[ -n "$_cb_cfg" ]]; then
        if [[ -x "$_cb_cfg" ]]; then
            CLAUDE_BIN="$_cb_cfg"
        else
            echo "_claude-bin.sh: nexus.claude_bin is set but not executable" >&2
            echo "  config/nexus.yml nexus.claude_bin = $_cb_cfg" >&2
            echo "  Fix the path or clear the key; refusing to silently fall" >&2
            echo "  back to $NEXUS_ROOT/node_modules/.bin/claude." >&2
            unset _cb_cfg _cb_rc
            exit 2
        fi
    elif [[ -x "$NEXUS_ROOT/node_modules/.bin/claude" ]]; then
        CLAUDE_BIN="$NEXUS_ROOT/node_modules/.bin/claude"
    elif [[ -z "${CLAUDE_BIN_NO_PATH:-}" ]] && command -v claude >/dev/null 2>&1; then
        CLAUDE_BIN="$(command -v claude)"
    else
        echo "_claude-bin.sh: no claude binary found" >&2
        echo "  Looked for: config/nexus.yml nexus.claude_bin (unset/empty)" >&2
        echo "              $NEXUS_ROOT/node_modules/.bin/claude" >&2
        if [[ -n "${CLAUDE_BIN_NO_PATH:-}" ]]; then
            echo "              (PATH lookup suppressed: CLAUDE_BIN_NO_PATH)" >&2
        else
            echo "              claude on PATH" >&2
        fi
        echo "  Either set nexus.claude_bin to a native install, or run:" >&2
        echo "  $NEXUS_ROOT/monitor/install-claude-local.sh" >&2
        unset _cb_cfg _cb_rc
        exit 1
    fi
    unset _cb_cfg _cb_rc
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
# Returns 0 = PASS the flag, 1 = do not. NEVER blocks without a bound when a
# `timeout` binary exists: see $NEXUS_CLAUDE_HELP_TIMEOUT above
# (your-org/nexus-code#1289). A timeout is reported as a TIMEOUT, distinctly
# from "the binary answered and said no" and from "the binary failed to run" —
# the three have different remedies and #1248 is the reason the injected 124
# must not pass for the callee's own status.
#
# rc 0 covers TWO answers, and only the second is new (skeptic pass on #1626,
# the #1611 defect in this probe):
#   YES      the probe COMPLETED and --help lists `--name <name>` (cached)
#   UNKNOWN  the probe did NOT complete — `timeout` killed it (124/125/137).
#            NEVER cached; the reason is left in
#            $_CLAUDE_NAME_FLAG_UNKNOWN_REASON and said on stderr.
# rc 1 is a COMPLETED probe that read the help text and found no flag (cached),
# or an EMPTY --help that was not a timeout — omitted, fail-closed as before,
# but no longer cached either (reason in the same variable).
#
# WHY UNKNOWN PASSES THE FLAG rather than omitting it. Before, an unknown was
# CACHED as `no`: one --help slowed by a loaded node made every later ask in
# that shell omit --name — every `--continue` respawn of a claude-loop.sh
# worker, for its life — and an omitted --name is the SILENT failure: the
# session self-names from its cwd, and cross-session addressing fails later,
# far from the cause. Every caller gates on `claude_supports_name_flag || …`
# with no note of its own (spawn-worker.sh `_spawn_name_arg`), so an unknown
# that returned non-zero would be swallowed exactly as silently. Passing the
# flag bets on the pinned binary, which lists it (skills/nexus.cc-update
# GUIDE); if the bet is wrong the launch dies AT ONCE with `error: unknown
# option` — LOUD, at the cause, and the next ask re-probes because nothing was
# cached. That is the same bet #1611 made for `--plugin-dir` on the same
# spawn and respawn paths. Boundary, stated: an OLDER pin (no --name) probed
# under load fails its launch instead of degrading; the "degrade rather than a
# dead orchestrator" rule above still holds for every COMPLETED probe.
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
    _CLAUDE_NAME_FLAG_UNKNOWN_REASON=''
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
    # The SET, as in claude_supports_plugin_dir_flag: 125 is `timeout` itself
    # failing, also not the callee's answer.
    if (( _bounded )) && { (( _rc == 124 )) || (( _rc == 125 )) || (( _rc == 137 )); }; then
        _CLAUDE_NAME_FLAG_UNKNOWN_REASON="--help probe TIMED OUT (rc ${_rc}, bound ${NEXUS_CLAUDE_HELP_TIMEOUT}s) — capability not established"
        echo "_claude-bin: '${CLAUDE_BIN} --help' TIMED OUT after ${NEXUS_CLAUDE_HELP_TIMEOUT}s (killed, rc ${_rc}) — --name support is UNKNOWN, not 'unsupported'; not cached, PASSING --name on the pinned binary's word. If this binary lacks it the launch fails at once with 'error: unknown option' (your-org/nexus-code#1047, #1611's rule; bound per #1289)." >&2
        return 0
    fi
    if [[ -z "$help_out" ]]; then
        # Could not ask, and NOT for want of time: the binary ran (or could not
        # be run) and printed nothing. Fail CLOSED on the FLAG (omit it),
        # loudly, as before — this is not the load case the TIMEOUT arm above
        # bets on, and test-session-name-from-window.sh section 4 pins it. But
        # NOT cached: it is no answer about the flag either, so the next ask
        # re-probes rather than inheriting it (skeptic pass on #1626).
        _CLAUDE_NAME_FLAG_UNKNOWN_REASON="--help produced no output (rc ${_rc}) — capability not established"
        echo "_claude-bin: could not read '${CLAUDE_BIN} --help' (rc ${_rc}) — NOT passing --name (not cached); this session will self-name from its cwd basename and will not be addressable by its tmux window name (your-org/nexus-code#1047)." >&2
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
# By capability, never by version, bounded exactly as claude_supports_name_flag
# above — but THREE-VALUED where that one is two-valued, and deliberately so
# (your-org/nexus-code#1611):
#
#   rc 0  YES      the probe COMPLETED and the help text carries the flag
#   rc 1  NO       the probe COMPLETED, the help text was read, no flag
#   rc 2  UNKNOWN  the probe did NOT complete: `timeout` killed it (124/137, or
#                  125 — `timeout` itself failed), or `--help` produced no
#                  bytes at all. Nothing was learned about the BINARY.
#
# WHY UNKNOWN HAS TO BE ITS OWN VALUE. Before #1611 all three paths returned 1
# and CACHED `no`, so a --help that was merely SLOW — every session in a mass
# resurrection, when the node is loaded — became a permanent "unsupported" for
# that launcher and the session came back with no longjob-watch dispatcher for
# its whole life, silently. Measured on the operator's live arming.log: `rtevsk`
# `armed` at 14:53:39 and `skipped` at 14:53:47, same binary, 8 s apart — a
# capability cannot change in 8 s. The branch below already KNEW the status was
# the wrapper's (`_bounded` is tested first; #1248: 124 is in no callee's
# vocabulary) and converted it into an answer about the callee anyway. Same
# class as monitor/repo-root.sh's `undetermined`, which exists because "'I could
# not tell' collapses into 'no'".
#
# UNKNOWN IS NEVER CACHED — only a COMPLETED probe is memoised in
# $_CLAUDE_PLUGIN_DIR_FLAG_CACHED (cache lifetime as documented above). A
# caller that asks again in the same shell re-probes, which is the point: the
# next ask may find an idle node. The reason is left in
# $_CLAUDE_PLUGIN_DIR_FLAG_UNKNOWN_REASON for the caller to log.
#
# WHAT THE CALLER DOES WITH UNKNOWN is policy and lives in
# monitor/_longjob-plugin.sh (it arms, logged `armed-unprobed`). This function
# says only what was established. Note the boundary it must respect: an
# unsupported flag is FATAL to `claude` (`error: unknown option`, exit 1 —
# measured, see claude_supports_name_flag's header), so UNKNOWN is not "safe to
# pass" in general; it is safe only where the binary is known to be the pinned
# one, and that argument is made at the call site, not here.
claude_supports_plugin_dir_flag() {
    _CLAUDE_PLUGIN_DIR_FLAG_UNKNOWN_REASON=''
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
    # The SET the wrapper can inject with `-k 2` and the default signal: 124
    # (TERM fired), 137 (KILL after the grace), 125 (`timeout` itself failed).
    # Tested as a set, never as `== 124` (CLAUDE.md TIMEOUT-STATUS-INJECTION).
    if (( _bounded )) && { (( _rc == 124 )) || (( _rc == 125 )) || (( _rc == 137 )); }; then
        _CLAUDE_PLUGIN_DIR_FLAG_UNKNOWN_REASON="--help probe TIMED OUT (rc ${_rc}, bound ${NEXUS_CLAUDE_HELP_TIMEOUT}s) — capability not established"
        echo "_claude-bin: '${CLAUDE_BIN} --help' TIMED OUT after ${NEXUS_CLAUDE_HELP_TIMEOUT}s (killed, rc ${_rc}) — --plugin-dir support is UNKNOWN, not 'unsupported'; not cached (your-org/nexus-code#1611)." >&2
        return 2
    fi
    if [[ -z "$help_out" ]]; then
        _CLAUDE_PLUGIN_DIR_FLAG_UNKNOWN_REASON="--help produced no output (rc ${_rc}) — capability not established"
        echo "_claude-bin: could not read '${CLAUDE_BIN} --help' (rc ${_rc}) — --plugin-dir support is UNKNOWN, not 'unsupported'; not cached (your-org/nexus-code#1611)." >&2
        return 2
    fi
    case "$help_out" in
        *"--plugin-dir <path>"*) _CLAUDE_PLUGIN_DIR_FLAG_CACHED=yes; return 0 ;;
    esac
    _CLAUDE_PLUGIN_DIR_FLAG_CACHED=no
    echo "_claude-bin: this claude does not support '--plugin-dir' (its --help was read and does not list it) — NOT passing it; this session will have NO longjob-watch dispatcher and cannot be woken by a long job (your-org/nexus-code#1535)." >&2
    return 1
}
