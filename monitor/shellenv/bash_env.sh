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

# (a0) RECORD THE PATH WE INHERITED, BEFORE ANY OF THE BELOW CHANGES IT
#      (your-org/nexus-code#652, #654).
#
#      This file re-fronts PATH at the start of EVERY non-interactive bash. That
#      is the fix working — and it is also why a bash-implemented guard cannot
#      see a CALLER whose PATH is buried: by the time the guard's first line
#      runs, step (b) below has already repaired the guard's own PATH, so it
#      reports clean about a shell that is not the one at risk.
#
#      That is exactly how `assert-shims-wrapped.sh` came to exit 0 in a worker
#      whose own `command -v pip` answered `/app/bin/pip` — the #487 fork-storm
#      binary. The guard was not careless; the surface it could reach had
#      genuinely been repaired. The one it needed was gone before it started.
#
#      `/proc/<pid>/environ` would answer this without cooperation, and it is
#      NOT available: measured on this host, `/proc/self/environ` yields ZERO
#      variables inside the sandbox. So the inherited value has to be recorded
#      by whoever still holds it, which is this prelude.
#
#      Unconditional and unguarded on purpose: every non-interactive bash gets
#      the PATH ITS OWN caller exported, so the value always describes the
#      immediate parent rather than some ancestor. A stale record would be worse
#      than none — it would let a guard vouch for a shell that is not its
#      caller.
#      ONE HOP UP, KEYED ON PID IDENTITY (your-org/nexus-code#1383). The
#      record above describes the IMMEDIATE caller — correct, and structurally
#      blind to burial inherited from any shell ABOVE the last bash in the
#      chain: in the spawn path a bash launcher runs the prelude (records the
#      buried zsh PATH, re-fronts), then runs the bash guard, whose OWN prelude
#      re-records from the launcher's already-repaired PATH. Measured: the
#      launcher holds the buried value, the guard reads clean and reports it.
#      So when the value we are about to overwrite was written by OUR OWN
#      PARENT (its pid stamp equals $PPID), that value is carried forward as
#      the UPSTREAM record: what the caller itself inherited, one hop up. It
#      is carried ONE hop only (a grandparent's record is not re-carried), it
#      never replaces the immediate record, and a consumer treats it as a
#      scoped WARNING rather than a refusal. `timeout bash …`, `env … bash …`
#      and any other exec-interposer breaks the pid chain and simply yields no
#      upstream — the stated residual, not a false record.
if [ -n "${NEXUS_INHERITED_PATH_PID:-}" ] && [ "${NEXUS_INHERITED_PATH_PID}" = "$PPID" ]; then
    export NEXUS_INHERITED_PATH_UPSTREAM="${NEXUS_INHERITED_PATH:-}"
    export NEXUS_INHERITED_PATH_UPSTREAM_PID="$PPID"
else
    unset NEXUS_INHERITED_PATH_UPSTREAM NEXUS_INHERITED_PATH_UPSTREAM_PID
fi
export NEXUS_INHERITED_PATH="${PATH:-}"
export NEXUS_INHERITED_PATH_PID="$$"

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
    # your-org/nexus-code#1188 - PER-WRAPPER fixture opt-out.
    #
    # NEXUS_PATH_FRONT_OFF is a SPACE-SEPARATED list of wrapper DIRECTORY names:
    # tmuxwrap, ghwrap, pipwrap, notifywrap. Each named wrapper declines to
    # front; every other wrapper fronts exactly as before.
    #
    # THERE IS DELIBERATELY NO BLANKET SPELLING. `all`, `*` and a bare `off`
    # are ordinary unrecognised tokens and disable nothing. A value that
    # disables ghwrap must NAME ghwrap, so the hazard is visible at the call
    # site and greppable across the corpus: an UNWRAPPED `gh` write is #497 —
    # it SUCCEEDS, GitHub mutes the operator's own notification, and the thread
    # goes dark. This variable is EXPORTED, so a blanket spelling would disarm
    # the bot-identity backstop for a fixture's entire process subtree.
    #
    # WHY A MARKER AND NOT THE `BASH_ENV=` PIN fixtures use today: the pin is
    # defeated ONE GENERATION DOWN. locals-env.sh re-exports BASH_ENV=<this
    # file> whenever it is sourced and BASH_ENV is not already that value — and
    # an EMPTY pin satisfies that `!=`. Measured:
    #   env BASH_ENV= bash -c '. locals-env.sh; command -v tmux'
    #        -> monitor/tmuxwrap/tmux                              BELT DEFEATED
    #   env NEXUS_PATH_FRONT_OFF=tmuxwrap bash -c '. locals-env.sh; command -v tmux'
    #        -> <the fixture stub>                                 MARKER HOLDS
    # locals-env rewrites BASH_ENV; it never clears NEXUS_PATH_FRONT_OFF.
    #
    # THE MARKER DECLINES TO FRONT; IT CANNOT UN-FRONT. Measured on BOTH
    # fronting paths with PATH deliberately built so the wrapper sits AHEAD of
    # a fixture's stub: NEXUS_PATH_FRONT_OFF=tmuxwrap still resolved `tmux` to
    # monitor/tmuxwrap/tmux, under bash (this file) and zsh (front-path.zsh)
    # alike. These sites only ever decline to PREPEND; neither removes an entry
    # an ancestor already placed.
    #
    # So a fixture that sets the marker in a child whose INHERITED PATH already
    # fronts the wrapper is NOT isolated, and nothing says so -- which is
    # #1188's own false-PASS direction arriving inside #1188's remedy. A
    # fixture must BUILD its child's PATH rather than inherit it, AND assert
    # the result with `th_assert_stub_reached`, which observes WHICH BINARY THE
    # CHILD REACHED. The marker is NECESSARY BUT INSUFFICIENT; the alarm is
    # what survives this limit, because it cannot be satisfied by the marker
    # merely being set.
    #
    # EXACT-TOKEN, never substring: the padded-space match means `notghwrap`
    # does NOT match `ghwrap` (measured).
    #
    # AN UNRECOGNISED NAME IS INERT AND SILENT HERE, ON PURPOSE. This file runs
    # at the start of EVERY non-interactive bash, so it must not write to any
    # stream. A typo'd `tmuxwarp` therefore fronts normally — a fixture that
    # believes it opted out and did not. That residual is covered on the TEST
    # side, by th_assert_stub_reached, which OBSERVES which binary the child
    # actually reached and so fires on a typo exactly as it fires on a missing
    # opt-out (measured). Do not add a diagnostic here.
    _nb_front_off() {
        case " ${NEXUS_PATH_FRONT_OFF:-} " in *" $1 "*) return 0 ;; esac
        return 1
    }
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
    # Front in REVERSE of the desired final order, so the LAST call wins the
    # very-front slot. Final order:
    #   ghwrap : notifywrap : pipwrap : tmuxwrap : locals/bin : <rest>
    # — matching front-path.zsh and locals-env.sh (invariant: ghwrap leads).
    [ -d "$_nb_locals/bin" ] && _nb_front_dir "$_nb_locals/bin"
    # Board-lethal tmux-kill guard (monitor/tmuxwrap) — bash analog of the
    # .zshenv force-front (your-org/nexus-code#892). This surface is the reason
    # the guard is an executable rather than a hook: a kill nested inside a
    # script an agent writes at runtime reaches the shim through here. Refuses
    # ONLY a positively-lethal kill against the board socket; fronted before
    # pipwrap/notifywrap/ghwrap so those keep the very-front slots.
    [ -x "$NEXUS_ROOT/monitor/tmuxwrap/tmux" ] && ! _nb_front_off tmuxwrap && _nb_front_dir "$NEXUS_ROOT/monitor/tmuxwrap"
    # Fork-storm pip guard (monitor/pipwrap) — refuses the self-re-exec'ing
    # sandbox /app/bin/pip (your-org/nexus-code#487); fronted before
    # notifywrap/ghwrap so those keep the very-front slots, matching .zshenv.
    [ -x "$NEXUS_ROOT/monitor/pipwrap/pip" ] && ! _nb_front_off pipwrap && _nb_front_dir "$NEXUS_ROOT/monitor/pipwrap"
    # Engagement-gated sandbox-notify wrapper (monitor/notifywrap) — bash analog
    # of the .zshenv force-front; see monitor/notifywrap/sandbox-notify. Fronted
    # BEFORE ghwrap so ghwrap remains the very-front entry.
    [ -x "$NEXUS_ROOT/monitor/notifywrap/sandbox-notify" ] && ! _nb_front_off notifywrap && _nb_front_dir "$NEXUS_ROOT/monitor/notifywrap"
    [ -x "$NEXUS_ROOT/monitor/ghwrap/gh" ] && ! _nb_front_off ghwrap && _nb_front_dir "$NEXUS_ROOT/monitor/ghwrap"
    export PATH
    unset -f _nb_front_dir _nb_front_off
    unset _nb_locals
fi
