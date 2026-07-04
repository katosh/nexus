# nexus agent ZDOTDIR — .zprofile proxy. Sourced only by LOGIN zsh shells.
# Transparent: re-source the operator's real ~/.zprofile. The `gh` shim is
# installed by .zshenv (sourced first). See monitor/gh-shim.sh.
[ -r "$HOME/.zprofile" ] && . "$HOME/.zprofile"
