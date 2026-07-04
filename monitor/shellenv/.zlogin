# nexus agent ZDOTDIR — .zlogin proxy. Sourced only by LOGIN zsh shells
# (after .zshrc). Transparent: re-source the operator's real ~/.zlogin. The
# `gh` shim is installed by .zshenv (sourced first). See monitor/gh-shim.sh.
[ -r "$HOME/.zlogin" ] && . "$HOME/.zlogin"
