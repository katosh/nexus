# nexus agent ZDOTDIR — .zprofile proxy. Sourced only by LOGIN zsh shells.
# Transparent: re-source the operator's real ~/.zprofile.
[ -r "$HOME/.zprofile" ] && . "$HOME/.zprofile"
# RE-FRONT the nexus toolchain AFTER ~/.zprofile, in case it re-prepends
# linuxbrew like ~/.zshrc does (your-org/nexus-code#578). Shared snippet.
[ -r "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh" ] && . "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh"
