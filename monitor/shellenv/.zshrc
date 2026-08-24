# nexus agent ZDOTDIR — .zshrc proxy. Sourced only by INTERACTIVE zsh shells
# an agent might spawn. Transparent: re-source the operator's real ~/.zshrc so
# aliases/functions/options are not lost.
[ -r "$HOME/.zshrc" ] && . "$HOME/.zshrc"
# RE-FRONT the nexus toolchain AFTER ~/.zshrc (your-org/nexus-code#578). .zshenv
# fronted it already, but ~/.zshrc's linuxbrew re-prepend just buried it — and
# THIS is the shell Claude Code snapshots for its Bash-tool PATH, so a stale
# front here is exactly what put linuxbrew's `gh` ahead of monitor/ghwrap. Same
# shared snippet the other proxies use ($ZDOTDIR = this file's own directory).
[ -r "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh" ] && . "${ZDOTDIR:-$NEXUS_ROOT/monitor/shellenv}/front-path.zsh"
