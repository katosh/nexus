# nexus agent ZDOTDIR — .zshenv (sourced on EVERY zsh invocation).
#
# The nexus launchers export ZDOTDIR=$NEXUS_ROOT/monitor/shellenv for agent
# (worker + orchestrator) processes (see monitor/locals-env.sh, full mode).
# Every `zsh -c` the Claude Code Bash tool runs sources this file. We keep it
# TRANSPARENT — source the operator's real ~/.zshenv first so nothing is lost
# — then FORCE the WHOLE nexus toolchain to the FRONT of PATH: the bot-default
# `gh` wrapper dir (monitor/ghwrap) AND the nexus-provisioned `locals/bin`
# (uv, python, ng, claude, …).
#
# WHY force-front HERE (and not only in locals-env). ~/.zshenv, sourced on the
# line just below, re-prepends linuxbrew/system paths on EVERY zsh invocation —
# burying the process-wide prepend locals-env did at launch. This per-command
# re-assertion runs AFTER that late modification, so the nexus copies win. It
# started as a `gh`-only fix (the PATH race the old function shim worked around;
# operator request your-org/nexus-code PR #349 comment 4795415597), then
# generalized to ALL of locals/bin — `uv`/`claude`/`ng`/… were still resolving
# to linuxbrew/system copies in a live agent shell, a latent reproducibility gap
# (operator request PR #349 comment 4799289032; this is the follow-up PR).
# `typeset -U path` de-dups, keeping our front copies and dropping the buried
# ones. Order: ghwrap leads (so a bare `gh` hits the bot-default wrapper even if
# a real `gh` ever lands in locals/bin), locals/bin directly behind it.
#
# zsh sources .zshenv before .zshrc/.zprofile/.zlogin, so the front-of-PATH
# entries are in scope for interactive and login agent shells too. The sibling
# proxy rc files (.zshrc/.zprofile/.zlogin) re-source the operator's real ones
# so those shells are not stripped of their config.
#
# Agent-spawn-scoped ONLY: this file is reached solely because the nexus
# launchers export ZDOTDIR for agent processes. The operator's bare interactive
# shell sources their real ~/.zshenv (not this one), so their PATH — where
# homebrew shadowing nexus tools is deliberately fine — is untouched.
[ -r "$HOME/.zshenv" ] && . "$HOME/.zshenv"
if [ -n "${NEXUS_ROOT:-}" ]; then
    # Front locals/bin first, then ghwrap, so the final order is
    # ghwrap : locals/bin : <rest>. NEXUS_LOCALS is exported by locals-env
    # (full mode); fall back to $NEXUS_ROOT/locals defensively.
    _nx_locals="${NEXUS_LOCALS:-$NEXUS_ROOT/locals}"
    [ -d "$_nx_locals/bin" ] && path=("$_nx_locals/bin" $path)
    # Fork-storm pip guard (monitor/pipwrap) — refuses the self-re-exec'ing
    # sandbox /app/bin/pip (your-org/nexus-code#487); same force-front
    # rationale as ghwrap. Fronted before notifywrap/ghwrap so those keep
    # the very-front slots.
    [ -x "$NEXUS_ROOT/monitor/pipwrap/pip" ] && path=("$NEXUS_ROOT/monitor/pipwrap" $path)
    # Engagement-gated sandbox-notify wrapper (monitor/notifywrap) — same
    # force-front rationale as ghwrap; keeps the bell gate on PATH front after
    # ~/.zshenv re-prepends linuxbrew. See monitor/notifywrap/sandbox-notify.
    # Fronted BEFORE ghwrap so ghwrap remains the very-front entry.
    [ -x "$NEXUS_ROOT/monitor/notifywrap/sandbox-notify" ] && path=("$NEXUS_ROOT/monitor/notifywrap" $path)
    [ -x "$NEXUS_ROOT/monitor/ghwrap/gh" ] && path=("$NEXUS_ROOT/monitor/ghwrap" $path)
    typeset -U path
    unset _nx_locals
fi
