# nexus agent bash env — the BASH analog of monitor/shellenv/.zshenv.
#
# Sourced by EVERY non-interactive `bash -c` an agent runs, because the nexus
# launchers export BASH_ENV=$NEXUS_ROOT/monitor/shellenv/bash_env.sh for agent
# (worker + orchestrator) processes (see monitor/locals-env.sh, full mode).
# Bash reads $BASH_ENV at the start of every non-interactive shell — the same
# always-sourced hook zsh gives us via ~/.zshenv/ZDOTDIR. The Claude Code Bash
# tool invokes the user's $SHELL as `<shell> -c "<command>"`; for a bash user
# that is a non-interactive bash, so this file is THE per-command re-assertion
# point on bash, mirroring .zshenv on zsh.
#
# WHY this is needed (and the process-wide prepend in locals-env isn't enough).
# $BASH_ENV is frequently ALREADY set in the operator's environment — e.g. to
# Lmod's init (`/app/lmod/lmod/init/bash`) inside agent-sandbox — and that init
# re-prepends system paths on every shell, burying the launcher's front-prepend.
# We must therefore (a) CHAIN to the prior $BASH_ENV so nothing it set up is
# lost, then (b) FORCE-front the nexus toolchain AFTER it, so the nexus copies
# win the per-command race. This closes the same latent reproducibility gap on
# bash that .zshenv closes on zsh (operator request your-org/nexus-code PR #349
# comment 4799289032 — "bash is more common"; this is the follow-up PR).
#
# Agent-spawn-scoped ONLY: reached solely because the launcher exported BASH_ENV
# for the agent process. The operator's bare interactive shell is unaffected —
# interactive bash ignores $BASH_ENV (it reads ~/.bashrc / ~/.bash_profile,
# which we never touch), so the operator's PATH, where homebrew shadowing nexus
# tools is deliberately fine, is left exactly as they configured it.
#
# Pure env, idempotent, no side effects — safe to source on every bash -c.

# (a) Chain to the operator's prior BASH_ENV (Lmod init, etc.) — ONCE PER
#     PROCESS TREE. locals-env stashed it here before re-pointing BASH_ENV at
#     this file.
#
#     Why the once-per-tree guard (your-org/nexus-code#457). The prior BASH_ENV
#     is typically Lmod's init (`/app/lmod/lmod/init/bash`), and BASH_ENV is
#     sourced at the start of EVERY non-interactive bash. The watcher's poll
#     path fires ~100 `bash config/load.sh <key>` config reads per cycle, each
#     a fresh non-interactive bash that would re-source the ~6 KB Lmod init.
#
#     Sourcing that init does NOT itself spawn a bash — an earlier write-up said
#     it did, and that reading was falsified. What it does is arm a
#     `command_not_found_handle` (init/bash:185-201). Bash FORKS A CHILD before
#     invoking that handler, and the child inherits the parent's argv. The
#     handler unconditionally runs `command_not_found.py "$1"` — and when THAT
#     is itself unresolvable (a PATH without /app/bin), the handler re-fires
#     inside the forked child, which forks again: an unbounded parent→child
#     chain, each level blocked in wait(), argv copied down, until the node's
#     pid_max (36864) returned EAGAIN for every fork on the box. That is why the
#     forensics found thousands of `bash …/main.sh --once` processes: they were
#     forked CHILDREN of the bash that ran it, not re-invocations of it. The
#     trigger is HERE, not in the watcher's --once tick.
#
#     Guarding the re-source keeps the handler off every DESCENDANT bash (it is
#     not `export -f`'d — only module/ml are, init/bash:140-141 — so an exec'd
#     child cannot inherit it), while the chain's real effects (PATH, the
#     exported module/ml functions) still reach children through the
#     environment. Sourcing once is therefore sufficient. The marker is exported
#     BEFORE the source so a child bash the chained init itself spawns already
#     sees it and does not re-enter.
#
#     The self-reference guard stays: a misconfiguration pointing the prior env
#     back at this file must never source-loop.
if [ -z "${NEXUS_BASH_ENV_CHAINED:-}" ] \
   && [ -n "${NEXUS_PREV_BASH_ENV:-}" ] \
   && [ "${NEXUS_PREV_BASH_ENV}" != "${BASH_SOURCE[0]:-}" ] \
   && [ -r "${NEXUS_PREV_BASH_ENV}" ]; then
    export NEXUS_BASH_ENV_CHAINED=1
    # shellcheck disable=SC1090
    . "${NEXUS_PREV_BASH_ENV}"
fi

# (a2) Disarm the recursion primitive itself (your-org/nexus-code#480).
#
#      The guard in (a) is ancestry-dependent: it spares every DESCENDANT bash,
#      but the FIRST bash in a process tree still sources the chain and still
#      arms `command_not_found_handle`. Give that shell a PATH without
#      /app/bin and the fork chain of #457 returns in full.
#
#      So do not merely decline to re-arm the handler — remove it. Lmod does not
#      `export -f` it, nothing in a non-interactive agent shell depends on it
#      (its only job is the interactive "did you mean…" suggestion), and with it
#      gone an unresolvable command is what it should always have been: a plain
#      127. Ancestry stops mattering and a stripped PATH is harmless.
#
#      Unconditional and outside the (a) block on purpose: it must also cover a
#      shell that inherited the marker but had the handler armed some other way.
#      `|| :` because the caller may run under `set -e`.
unset -f command_not_found_handle 2>/dev/null || :

# (b) Force-front the nexus toolchain AFTER any re-prepend the chained env did.
if [ -n "${NEXUS_ROOT:-}" ]; then
    # Remove an exact PATH entry (all occurrences) then prepend it, via pure
    # bash parameter expansion — no subprocess, cheap enough to run per shell.
    _nb_front_dir() {
        [ -n "${1:-}" ] || return 0
        local d="$1" p=":${PATH}:"
        p="${p//:$d:/:}"          # strip existing copies (bash glob-free repl)
        p="${p#:}"; p="${p%:}"    # trim the sentinel colons
        PATH="$d${p:+:$p}"
    }
    _nb_locals="${NEXUS_LOCALS:-$NEXUS_ROOT/locals}"
    # Front locals/bin first, then ghwrap, so the final order is
    # ghwrap : locals/bin : <rest> — matching .zshenv.
    [ -d "$_nb_locals/bin" ] && _nb_front_dir "$_nb_locals/bin"
    # Fork-storm pip guard (monitor/pipwrap) — refuses the self-re-exec'ing
    # sandbox /app/bin/pip (your-org/nexus-code#487); fronted before
    # notifywrap/ghwrap so those keep the very-front slots, matching .zshenv.
    [ -x "$NEXUS_ROOT/monitor/pipwrap/pip" ] && _nb_front_dir "$NEXUS_ROOT/monitor/pipwrap"
    # Engagement-gated sandbox-notify wrapper (monitor/notifywrap) — bash analog
    # of the .zshenv force-front; see monitor/notifywrap/sandbox-notify. Fronted
    # BEFORE ghwrap so ghwrap remains the very-front entry.
    [ -x "$NEXUS_ROOT/monitor/notifywrap/sandbox-notify" ] && _nb_front_dir "$NEXUS_ROOT/monitor/notifywrap"
    [ -x "$NEXUS_ROOT/monitor/ghwrap/gh" ] && _nb_front_dir "$NEXUS_ROOT/monitor/ghwrap"
    export PATH
    unset -f _nb_front_dir
    unset _nb_locals
fi
