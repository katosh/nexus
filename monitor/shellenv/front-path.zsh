# nexus agent ZDOTDIR — SHARED force-front snippet (zsh).
#
# Force the WHOLE nexus toolchain to the FRONT of PATH, AFTER any rc has had its
# say. Sourced by ALL four proxy files:
#   .zshenv  — every zsh invocation (incl. `zsh -c`), after re-sourcing ~/.zshenv
#   .zshrc   — interactive shells,   after re-sourcing ~/.zshrc
#   .zprofile/.zlogin — login shells, after re-sourcing ~/.zprofile / ~/.zlogin
#
# WHY it must run in EVERY proxy, not only .zshenv (your-org/nexus-code#578).
# zsh sources .zshenv FIRST, then .zprofile/.zshrc/.zlogin for login/interactive
# shells. Each of those re-sources the operator's real rc, and ~/.zshrc
# re-prepends linuxbrew on every interactive shell — BURYING the front that
# .zshenv established moments earlier. A `.zshenv`-only front therefore loses in
# exactly the shell Claude Code uses to capture its Bash-tool PATH SNAPSHOT: a
# LOGIN+INTERACTIVE shell. The snapshot then records linuxbrew ahead of the
# bot-default `gh` wrapper (monitor/ghwrap), and every Bash-tool command sources
# that snapshot — so a bare `gh` at the top level of a tool shell resolves to
# linuxbrew's gh, not the wrapper. Re-fronting in each proxy AFTER its rc source
# closes the race for interactive/login/snapshot shells, mirroring what .zshenv
# already does for the per-command `zsh -c` surface.
#
# Idempotent: `typeset -U path` de-dups, keeping our front copies and dropping
# any buried ones. Order: ghwrap must end up the very-front entry (so a bare
# `gh` hits the bot-default wrapper even if a real `gh` ever lands in
# locals/bin), so it is prepended LAST. Guarded on NEXUS_ROOT and on each
# wrapper existing, so older checkouts / forks degrade to a no-op.
#
# Pure env, no side effects, safe to source repeatedly.
# your-org/nexus-code#1188 - PER-WRAPPER fixture opt-out (NEXUS_PATH_FRONT_OFF).
# Same semantics and the same NO-BLANKET rule as monitor/shellenv/bash_env.sh,
# whose block comment carries the rationale. Present here because a fixture that
# drives its subject through a zsh child would otherwise be re-fronted by this
# file, and #1188 measured that guarding fewer than all three fronting sites
# leaves the opt-out defeatable one generation down.
#
# PROVEN IN ZSH (was 'unproven by symmetry'). Clean `zsh -f`, stub fronted,
# this file sourced explicitly: OFF=tmuxwrap -> tmux resolves to the STUB while
# gh still resolves to monitor/ghwrap/gh; no marker -> tmux resolves to the
# wrapper; OFF=notghwrap leaves ghwrap armed (substring safe); OFF=all and
# OFF=off disable NOTHING (the no-blanket rule).
#
# NOT measurable from a SECONDARY clone through a real `zsh -c`: ZDOTDIR points
# at the PRIMARY nexus's monitor/shellenv, so .zshenv sources the PRIMARY's copy
# of this file and a clone's edit is invisible to that path until it lands.
#
# THE MARKER DECLINES TO FRONT; IT CANNOT UN-FRONT. Measured on BOTH fronting
# paths with PATH deliberately built so the wrapper sits AHEAD of a fixture's
# stub: `NEXUS_PATH_FRONT_OFF=tmuxwrap` still resolved `tmux` to
# monitor/tmuxwrap/tmux, under zsh (front-path.zsh) and bash (bash_env.sh)
# alike. These sites only ever decline to PREPEND; neither removes an entry an
# ancestor already placed.
#
# So a fixture that sets the marker in a child whose INHERITED PATH already
# fronts the wrapper is NOT isolated, and nothing says so -- which is #1188's
# own false-PASS direction arriving inside #1188's remedy. A fixture must build
# its child's PATH rather than inherit it, AND assert the result with
# `th_assert_stub_reached`, which observes WHICH BINARY THE CHILD REACHED. The
# marker is the mechanism and is NECESSARY BUT INSUFFICIENT; the alarm is what
# survives this limit, because it cannot be satisfied by the marker being set.
_nx_front_off() {
    case " ${NEXUS_PATH_FRONT_OFF:-} " in *" $1 "*) return 0 ;; esac
    return 1
}
if [ -n "${NEXUS_ROOT:-}" ]; then
    # NEXUS_LOCALS is exported by locals-env (full mode); fall back defensively.
    _nx_locals="${NEXUS_LOCALS:-$NEXUS_ROOT/locals}"
    # Prepend in reverse of the desired final order, so the LAST prepend wins the
    # very-front slot. Final order:
    #   ghwrap : notifywrap : pipwrap : tmuxwrap : locals/bin : …
    [ -d "$_nx_locals/bin" ] && path=("$_nx_locals/bin" $path)
    # Board-lethal tmux-kill guard (monitor/tmuxwrap) — your-org/nexus-code#892.
    # Refuses ONLY a positively-lethal kill against the board socket; every other
    # tmux call, including the hot `list-windows`/`display-message` path, passes
    # straight through. Fronted BEFORE pipwrap/notifywrap/ghwrap so those keep
    # the very-front slots.
    [ -x "$NEXUS_ROOT/monitor/tmuxwrap/tmux" ] && ! _nx_front_off tmuxwrap && path=("$NEXUS_ROOT/monitor/tmuxwrap" $path)
    [ -x "$NEXUS_ROOT/monitor/pipwrap/pip" ] && ! _nx_front_off pipwrap && path=("$NEXUS_ROOT/monitor/pipwrap" $path)
    [ -x "$NEXUS_ROOT/monitor/notifywrap/sandbox-notify" ] && ! _nx_front_off notifywrap && path=("$NEXUS_ROOT/monitor/notifywrap" $path)
    [ -x "$NEXUS_ROOT/monitor/ghwrap/gh" ] && ! _nx_front_off ghwrap && path=("$NEXUS_ROOT/monitor/ghwrap" $path)
    typeset -U path
    unset _nx_locals
    unset -f _nx_front_off
fi
