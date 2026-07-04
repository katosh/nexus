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

# (a) Chain to the operator's prior BASH_ENV (Lmod init, etc.). locals-env
#     stashed it here before re-pointing BASH_ENV at this file; guard against
#     self-reference so a misconfiguration can't recurse.
if [ -n "${NEXUS_PREV_BASH_ENV:-}" ] \
   && [ "${NEXUS_PREV_BASH_ENV}" != "${BASH_SOURCE[0]:-}" ] \
   && [ -r "${NEXUS_PREV_BASH_ENV}" ]; then
    # shellcheck disable=SC1090
    . "${NEXUS_PREV_BASH_ENV}"
fi

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
    # Engagement-gated sandbox-notify wrapper (monitor/notifywrap) — bash analog
    # of the .zshenv force-front; see monitor/notifywrap/sandbox-notify. Fronted
    # BEFORE ghwrap so ghwrap remains the very-front entry.
    [ -x "$NEXUS_ROOT/monitor/notifywrap/sandbox-notify" ] && _nb_front_dir "$NEXUS_ROOT/monitor/notifywrap"
    [ -x "$NEXUS_ROOT/monitor/ghwrap/gh" ] && _nb_front_dir "$NEXUS_ROOT/monitor/ghwrap"
    export PATH
    unset -f _nb_front_dir
    unset _nb_locals
fi
