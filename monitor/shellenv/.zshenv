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
# Force the nexus toolchain to the FRONT of PATH after ~/.zshenv's linuxbrew
# re-prepend. Shared with the .zshrc/.zprofile/.zlogin proxies via one snippet
# so the four cannot drift (your-org/nexus-code#578). $ZDOTDIR is this file's
# own directory — reliable in a startup file, where ${0} is the shell name,
# not the file path (so ${0:A:h} would resolve to the zsh binary's dir).
[ -r "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh" ] && . "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh"
