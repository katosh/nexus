# labsh-uvx-shim/bash_env.sh — BASH_ENV for the `labsh start` process tree
# (your-org/nexus-code#1676). NOT executable, never on its own: sourced by
# bash at the start of every non-interactive shell under labsh-supervised.sh's
# `labsh_start_pinned`.
#
# The nexus prelude (monitor/shellenv/bash_env.sh) force-fronts locals/bin in
# every non-interactive bash, and labsh is a bash script, so labsh's bare `uvx`
# would resolve to locals/bin/uvx and never reach the pin shim. Rather than
# drop the prelude, CHAIN it — every PATH shim it fronts (ghwrap, pipwrap, …)
# and whatever it chains in turn stay exactly as they were — and then front ONE
# more directory, this one, which holds nothing but `uvx`. `uv`, the helper-venv
# install's tool, still resolves where it did.
if [ -n "${LABSH_SHIM_BASH_ENV:-}" ] && [ -r "${LABSH_SHIM_BASH_ENV}" ] \
   && [ "${LABSH_SHIM_BASH_ENV}" != "${BASH_SOURCE[0]:-}" ]; then
    . "${LABSH_SHIM_BASH_ENV}"
fi
_lsb_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
if [ -n "$_lsb_dir" ] && [ -x "$_lsb_dir/uvx" ]; then
    _lsb_p=":${PATH}:"
    _lsb_p="${_lsb_p//:$_lsb_dir:/:}"
    _lsb_p="${_lsb_p#:}"; _lsb_p="${_lsb_p%:}"
    PATH="$_lsb_dir${_lsb_p:+:$_lsb_p}"
    export PATH
fi
unset _lsb_dir _lsb_p
