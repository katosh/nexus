# nexus agent ZDOTDIR — .zshrc proxy. Sourced only by INTERACTIVE zsh shells
# an agent might spawn. Transparent: re-source the operator's real ~/.zshrc so
# aliases/functions/options are not lost. The `gh` shim is already installed
# by .zshenv (sourced first). See monitor/gh-shim.sh.
[ -r "$HOME/.zshrc" ] && . "$HOME/.zshrc"
