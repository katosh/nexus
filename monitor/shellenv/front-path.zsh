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
if [ -n "${NEXUS_ROOT:-}" ]; then
    # NEXUS_LOCALS is exported by locals-env (full mode); fall back defensively.
    _nx_locals="${NEXUS_LOCALS:-$NEXUS_ROOT/locals}"
    # Prepend in reverse of the desired final order, so the LAST prepend wins the
    # very-front slot. Final order: ghwrap : notifywrap : pipwrap : locals/bin : …
    [ -d "$_nx_locals/bin" ] && path=("$_nx_locals/bin" $path)
    [ -x "$NEXUS_ROOT/monitor/pipwrap/pip" ] && path=("$NEXUS_ROOT/monitor/pipwrap" $path)
    [ -x "$NEXUS_ROOT/monitor/notifywrap/sandbox-notify" ] && path=("$NEXUS_ROOT/monitor/notifywrap" $path)
    [ -x "$NEXUS_ROOT/monitor/ghwrap/gh" ] && path=("$NEXUS_ROOT/monitor/ghwrap" $path)
    typeset -U path
    unset _nx_locals
fi
