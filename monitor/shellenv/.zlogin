# nexus agent ZDOTDIR — .zlogin proxy. Sourced only by LOGIN zsh shells
# (after .zshrc). Transparent: re-source the operator's real ~/.zlogin.
[ -r "$HOME/.zlogin" ] && . "$HOME/.zlogin"
# RE-FRONT the nexus toolchain AFTER ~/.zlogin (your-org/nexus-code#578).
# Shared snippet; .zlogin runs after .zshrc so this is the last word for a
# login+interactive shell — the exact shape Claude Code snapshots.
[ -r "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh" ] && . "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh"
