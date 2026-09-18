#!/usr/bin/env bash
# monitor/locals-env.sh — join the NEXUS-WIDE project-local toolchain.
#
# SOURCE this (do not execute). It puts the shared `locals/bin` on PATH so
# nexus tools (uv, and anything provisioned there) are callable BY NAME, and
# points all of uv's state at the nexus-wide `locals/` tree so nothing lands
# in $HOME. It is the single source of truth for that env: the spawn-worker
# launcher, the watcher launcher, and the orchestrator respawn launcher all
# source it, and `bootstrap-venv.sh` sources it too.
#
# Pure env, NO side effects (no mkdir, no network, no writes) — safe to source
# unconditionally from any shell, idempotently. The actual toolchain under
# `locals/` is provisioned lazily by `monitor/bootstrap-venv.sh`.
#
# Self-locating: resolves the nexus root from this file's location
# (monitor/..), so it works regardless of cwd and from any clone/worktree.
# Honours a pre-set $NEXUS_ROOT (the spawn launcher exports it).

_le_src="${BASH_SOURCE[0]:-$0}"
_le_root="${NEXUS_ROOT:-$(cd "$(dirname "$_le_src")/.." 2>/dev/null && pwd)}"
if [ -z "$_le_root" ]; then
    # Could not resolve — degrade to a no-op rather than poison the shell.
    unset _le_src _le_root 2>/dev/null
    return 0 2>/dev/null || exit 0
fi
_le_locals="${NEXUS_LOCALS:-$_le_root/locals}"

export NEXUS_LOCALS="$_le_locals"

# Prepend locals/bin to PATH, but only once (idempotent re-source).
case ":${PATH:-}:" in
    *":$_le_locals/bin:"*) : ;;                       # already present
    *) export PATH="$_le_locals/bin:${PATH:-}" ;;
esac

# PATH-ONLY mode (NEXUS_LOCALS_PATH_ONLY set) — for a user's GLOBAL
# interactive shell, sourced by the manual-tmux-window rc hook
# (monitor/install-shell-hook.sh, your-org/nexus-code#307 item 3). It puts
# nexus tools (claude, ng, uv, …) on PATH by name but STOPS HERE: it does
# NOT redirect uv's state into the nexus tree, because hijacking a user's
# uv cache / tool store / managed interpreters for their OWN non-nexus work
# would be surprising and would bloat the nexus tree with their artifacts.
# Workers + the watcher/orchestrator launchers source WITHOUT this flag and
# get the full redirect below (they are nexus-scoped by design).
if [ -n "${NEXUS_LOCALS_PATH_ONLY:-}" ]; then
    unset _le_src _le_root _le_locals 2>/dev/null
    return 0 2>/dev/null || exit 0
fi

# MOVE-TO-FRONT, not prepend-if-absent (your-org/nexus-code#578 repair).
#
# The blocks below used to guard each prepend on `case ":$PATH:" in *":$dir:"*)`
# — i.e. "already present, skip". That tests PRESENCE and ignores POSITION, so a
# wrapper dir sitting ANYWHERE in PATH — including buried behind linuxbrew —
# made this file decline to re-front it. That is the whole #578 failure:
#
#   1. `tmux new-window` hands the worker's login zsh an environment that ALREADY
#      carries the front block (tmux's own env was captured from a shell that had
#      sourced this file), at positions 1-4.
#   2. That login zsh runs ~/.zshrc -> ~/.localrc, which re-prepends linuxbrew +
#      ~/Projects/utilities, BURYING the block to position ~13.
#   3. The launcher (`/bin/bash /tmp/spawn-launcher-*.sh`) sources this file. The
#      presence guard sees ghwrap in PATH and skips -> the block stays buried.
#   4. `claude` inherits that PATH, and Claude Code FREEZES it verbatim into
#      shell-snapshots/snapshot-zsh-*.sh as the final `export PATH=` line.
#   5. Every Bash-tool command runs `zsh -c "source <snapshot> && <cmd>"`. Our
#      ZDOTDIR .zshenv re-fronts correctly, and then the snapshot's `export PATH=`
#      CLOBBERS it. So the per-command re-front (front-path.zsh) can never repair
#      a bad snapshot — the launcher's PATH is the only one that matters.
#
# Whether step 1 happened at all is what made this look like a "race that flips":
# if the ancestor env did NOT already carry the block, the presence guard missed
# and the prepend landed at position 1 (the pre-2026-07-30 "good" snapshots).
#
# So: strip every existing copy of $1, then prepend it. Idempotent, corrects a
# buried entry, and cannot accumulate duplicates. POSIX shell only (no bashisms,
# no subprocess) — this file is sourced by bash AND zsh. Empty PATH elements are
# preserved verbatim: an empty element means "cwd", and silently dropping it
# would change resolution semantics for whoever set it.
_le_front_dir() {
    [ -n "${1:-}" ] || return 0
    if [ -z "${PATH:-}" ]; then
        export PATH="$1"
        return 0
    fi
    _le_fd_dir="$1"
    _le_fd_out=""
    _le_fd_empty=1          # 1 until the first surviving element is collected
    _le_fd_rest="$PATH"
    while :; do
        case "$_le_fd_rest" in
            *:*) _le_fd_head="${_le_fd_rest%%:*}"; _le_fd_rest="${_le_fd_rest#*:}"; _le_fd_more=1 ;;
            *)   _le_fd_head="$_le_fd_rest";       _le_fd_rest="";                  _le_fd_more=0 ;;
        esac
        if [ "$_le_fd_head" != "$_le_fd_dir" ]; then
            if [ "$_le_fd_empty" = 1 ]; then
                _le_fd_out="$_le_fd_head"; _le_fd_empty=0
            else
                _le_fd_out="$_le_fd_out:$_le_fd_head"
            fi
        fi
        [ "$_le_fd_more" = 1 ] || break
    done
    if [ "$_le_fd_empty" = 1 ]; then
        export PATH="$_le_fd_dir"
    else
        export PATH="$_le_fd_dir:$_le_fd_out"
    fi
    unset _le_fd_dir _le_fd_out _le_fd_empty _le_fd_rest _le_fd_head _le_fd_more 2>/dev/null
    return 0
}

# Re-front locals/bin. The prepend-if-absent above (shared with PATH-ONLY mode,
# whose operator-interactive semantics are deliberately left alone) is not enough
# in full mode for the same reason the wrapper dirs were not: it can be buried.
[ -d "$_le_locals/bin" ] && _le_front_dir "$_le_locals/bin"

# Redirect ALL of uv's $HOME/XDG-derived state into the nexus-wide tree.
export UV_PYTHON_INSTALL_DIR="$_le_locals/uv/python"
export UV_CACHE_DIR="$_le_locals/uv/cache"
export UV_TOOL_DIR="$_le_locals/uv/tools"

# Instantiate uv environments by HARD-LINKING cached files, not the default
# reflink (CoW clone). The nexus locals/ tree is NFS-backed and does NOT
# support reflink (fails EOPNOTSUPP / "os error 95"); uv then falls back to a
# full byte-for-byte COPY of every file into the target env. For the labsh
# jupyterlab tool env (~96 packages / thousands of small files) that is a
# multi-minute copy over NFS on every ephemeral `uvx` build, which never
# finishes inside the supervisor's start grace — the flap in incident
# your-org/other-nexus#33. The unpacked cache (uv/cache/archive-v0) and the
# env being built (uv/cache/builds-v0) live on the SAME mount, so hardlinks are
# valid and cheap (metadata only, no data copy). Non-degrading: if a target
# ever spans a different filesystem, uv auto-falls-back to copy with a warning
# — correctness is unaffected, only speed. Reversible: drop this line.
export UV_LINK_MODE="${UV_LINK_MODE:-hardlink}"

# Bot-default `gh` — PATH-FRONT wrapper (your-org/nexus-code PR #349, operator
# request: comment 4795415597). Prepend the wrapper dir (monitor/ghwrap) so a
# bare `gh` resolves to the bot-default wrapper for the agent PROCESS and every
# child it spawns (zsh, bash, `python subprocess`, Makefiles) — not just
# zsh-direct calls, the gap the earlier zsh-function shim left. The wrapper
# auto-injects the bot token on WRITE verbs, passes reads / preset-GH_TOKEN /
# WATCHER_WINDOW through, and offers the loud GH_IMPERSONATE opt-in (all the
# policy lives in monitor/gh-shim.sh, which the wrapper sources). Idempotent.
# Full mode only — the operator's interactive shells use the PATH-ONLY mode
# above (returned before this point) so they never get the wrapper. Guarded on
# the dir existing (older checkouts / forks degrade to a no-op).
#
# Watcher-safe: the watcher sources this file too and so gets the wrapper on
# PATH, but it runs with WATCHER_WINDOW=headless and presets GH_TOKEN inline,
# so the wrapper short-circuits to the real gh (gh-shim.sh branches 0/1).
# Engagement-gated `sandbox-notify` — PATH-FRONT wrapper (monitor/notifywrap),
# same mechanism as ghwrap. Shadows the agent-sandbox `sandbox-notify` so the
# agent-sandbox global Notification hook (`sandbox-notify 'Needs attention'`,
# merged into every session's read-only config-dir settings) rings only for
# user-engaged events: it suppresses the routine idle/permission bell for
# background spawned workers/skeptics (NEXUS_WORKER_WINDOW set) while passing the
# orchestrator's bells and explicit worker done/ready/blocker calls through. See
# monitor/notifywrap/sandbox-notify. Idempotent; full mode only; guarded on the
# dir existing (older checkouts / forks degrade to a no-op). Prepended BEFORE
# ghwrap so ghwrap stays at the very front of PATH (the established invariant).
# Fork-storm pip guard — PATH-FRONT `pip`/`pip3` shim (monitor/pipwrap),
# same mechanism as ghwrap. Refuses the hazardous sandbox /app/bin/pip
# (which re-execs itself without bound and exhausted pid_max on
# 2026-07-09 — fork-storm class, your-org/nexus-code#487) and points at
# `uv pip`; any NON-hazardous pip (an activated venv's own bin/pip, a
# system pip elsewhere) passes through untouched, as do WATCHER_WINDOW
# environments and the loud PIP_UNWRAPPED=1 opt-in. Full mode only — the
# operator's interactive shells (PATH-ONLY mode, returned above) never
# see it. Prepended BEFORE notifywrap/ghwrap so those keep the very-front
# slots (established invariant: ghwrap leads).
# Board-lethal tmux-kill guard — PATH-FRONT `tmux` shim (monitor/tmuxwrap),
# same mechanism as ghwrap (your-org/nexus-code#892; remedy for the session
# surface named in #889). Ending the tmux server ends the session bwrap holds
# open under --die-with-parent, so it tears down the ENTIRE SANDBOX — watcher,
# every worker, every service (2026-08-09; and five times in 33 minutes on
# 2026-07-30, #644). The corpus lint cannot see a command an agent TYPES, or one
# nested in a script it writes at runtime; a real executable covers every child.
#
# NOTE THE INVERTED POLARITY versus ghwrap, and do not "fix" it: this shim's
# default arm is PASS-THROUGH. monitor/ issues 46 kill-window calls and ~200
# tmux window operations, so a shim that refused when confused would wedge the
# control surface — the very outage it prevents. It refuses ONLY on
# positively-identified lethality against the BOARD socket, and it is inert on
# the hot path (`list-windows`/`display-message` exec straight through after a
# pure argv walk — no subprocess, no server query).
#
# Full mode only — the operator's interactive shells (PATH-ONLY mode, returned
# above) never see it. Prepended BEFORE pipwrap/notifywrap/ghwrap so those keep
# the very-front slots (established invariant: ghwrap leads).
# Fronted in reverse of the desired final order, so the LAST call wins the
# very-front slot. Final order:
#   ghwrap : notifywrap : pipwrap : tmuxwrap : locals/bin : …
# (established invariant: ghwrap leads). Same order as front-path.zsh and
# bash_env.sh, both of which already move-to-front correctly.
# your-org/nexus-code#1188 - PER-WRAPPER fixture opt-out. Semantics, the
# no-blanket rule and the reason a typo is silent here: see the block comment
# in monitor/shellenv/bash_env.sh. Honoured HERE as well as there because this
# file is sourced by ng, by every launcher and by the wrappers themselves, so a
# marker honoured only in bash_env.sh is re-armed by the first descendant that
# sources this one (measured: patching bash_env.sh alone still returned
# monitor/tmuxwrap/tmux from the grandchild).
#
# COVERAGE BOUNDARY, STATED SO NOBODY ASSUMES OTHERWISE: this marker does NOT
# cover the `$_le_locals/bin` front earlier in this file. That is the
# `claude`-stub surface of #746, guarded on the test side by
# th_require_stub_claude, and putting it under the same marker has a strictly
# larger blast radius (it is the whole nexus toolchain, not one wrapper). It is
# deliberately out of scope and wants its own decision.
_le_front_off() {
    case " ${NEXUS_PATH_FRONT_OFF:-} " in *" $1 "*) return 0 ;; esac
    return 1
}
[ -d "$_le_root/monitor/tmuxwrap" ]   && ! _le_front_off tmuxwrap && _le_front_dir "$_le_root/monitor/tmuxwrap"
[ -d "$_le_root/monitor/pipwrap" ]    && ! _le_front_off pipwrap && _le_front_dir "$_le_root/monitor/pipwrap"
[ -d "$_le_root/monitor/notifywrap" ] && ! _le_front_off notifywrap && _le_front_dir "$_le_root/monitor/notifywrap"
[ -d "$_le_root/monitor/ghwrap" ]     && ! _le_front_off ghwrap && _le_front_dir "$_le_root/monitor/ghwrap"

# The BOARD's tmux socket, recorded from the launcher's own $TMUX so the shim
# above can still identify it inside an `env -u TMUX` child — the one shape that
# defeats every other route to the answer. Full mode only, so the operator's own
# shells are unaffected. Harmless when unset (the shim falls back to $TMUX, then
# to the compiled default socket for this uid).
if [ -n "${TMUX:-}" ] && [ -z "${NEXUS_TMUX_SOCKET:-}" ]; then
    NEXUS_TMUX_SOCKET="${TMUX%%,*}"
    export NEXUS_TMUX_SOCKET
fi

# Fail-CLOSED bot identity. The PATH-front wrapper above is a SHADOW, not a
# boundary. Any shell rc that re-prepends its own bin dir (linuxbrew, /app/bin)
# wins the race for that process; `gh` then resolves to a REAL gh, which
# authenticates as the OPERATOR from the ambient credential store — silently,
# with no error, and with no way for the caller to notice. Shadowing the binary
# cannot close that hole. Removing the credential can.
#
# Point every gh binary — the wrapper's, linuxbrew's, /app/bin's, and any gh
# reached by any child process — at a credential-free config dir. gh-shim.sh
# then re-supplies identity EXPLICITLY: the bot token on WRITE verbs, and the
# operator's own config dir on reads, `gh auth …`, and the audited
# GH_IMPERSONATE path. A bare `gh issue create` that bypasses the wrapper now
# fails with "not logged in" instead of posting as the operator.
#
# The scoped dir need not exist: a missing GH_CONFIG_DIR already yields an
# unauthenticated gh, which is the safe direction on a read-only filesystem.
# Idempotent, and skipped in PATH-ONLY mode (returned above), so the operator's
# own interactive shells keep their credentials.
#
# This file must not name a home path in executable code — the nexus toolchain
# is home-independent by contract (monitor/watcher/test-bootstrap-venv.sh
# check 12; the venv must survive a wiped $HOME). So record ONLY what is
# explicitly set here. When neither GH_CONFIG_DIR nor XDG_CONFIG_HOME is set,
# NEXUS_OPERATOR_GH_CONFIG_DIR stays unset and gh-shim.sh resolves gh's own
# default lazily — which is the correct place for it, because that is the
# location gh itself consults.
if [ -z "${NEXUS_GH_CONFIG_SCOPED:-}" ]; then
    if [ -n "${GH_CONFIG_DIR:-}" ]; then
        export NEXUS_OPERATOR_GH_CONFIG_DIR="$GH_CONFIG_DIR"
    elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
        export NEXUS_OPERATOR_GH_CONFIG_DIR="$XDG_CONFIG_HOME/gh"
    fi
    export GH_CONFIG_DIR="$_le_root/monitor/.state/gh-config"
    export NEXUS_GH_CONFIG_SCOPED=1
fi

# Route agent (worker/orchestrator) shells through the nexus per-command PATH
# re-assertion, so the WHOLE nexus toolchain (locals/bin + the gh wrapper dir)
# stays at the FRONT of PATH even after a shell rc re-prepends linuxbrew/system
# paths on every invocation — the per-command race the launch-time prepend above
# cannot win on its own. Two shell-specific hooks, because bash and zsh have
# different always-sourced files (operator request: cover BOTH, PR #349 comment
# 4799289032 — "not all users use zsh; bash is more common"):
#
#   zsh  — ZDOTDIR=$NEXUS_ROOT/monitor/shellenv. zsh sources $ZDOTDIR/.zshenv on
#          EVERY invocation; our .zshenv re-sources the operator's real ~/.zshenv
#          then force-fronts locals/bin + ghwrap.
#   bash — BASH_ENV=$NEXUS_ROOT/monitor/shellenv/bash_env.sh. bash sources
#          $BASH_ENV at the start of every NON-interactive shell (`bash -c`, the
#          Bash-tool surface); our bash_env.sh chains to the operator's prior
#          BASH_ENV (e.g. Lmod init) then force-fronts the same dirs.
#
# Both are AGENT-SPAWN-SCOPED: they take effect only because THIS file (full
# mode) exports ZDOTDIR/BASH_ENV for the agent process and its children. The
# operator's bare interactive shell never sources either (PATH-only mode above
# returns before this point), so their interactive PATH — homebrew shadowing
# nexus tools is deliberately fine there — is untouched. Guarded on the files
# existing (older checkouts / forks degrade to a no-op).
if [ -d "$_le_root/monitor/shellenv" ]; then
    export ZDOTDIR="$_le_root/monitor/shellenv"
fi
# BASH_ENV: chain, don't clobber. Stash the operator's prior value (Lmod init,
# …) for bash_env.sh to re-source, then point BASH_ENV at our file. Idempotent:
# the != guard stops a re-source from stashing our OWN file as "prior" (which
# would make bash_env.sh source itself in a loop).
if [ -f "$_le_root/monitor/shellenv/bash_env.sh" ] \
   && [ "${BASH_ENV:-}" != "$_le_root/monitor/shellenv/bash_env.sh" ]; then
    export NEXUS_PREV_BASH_ENV="${BASH_ENV:-}"
    export BASH_ENV="$_le_root/monitor/shellenv/bash_env.sh"
fi

# Do not leak the helper into the sourcing shell (it is an implementation
# detail of this file, and agents' interactive shells source it).
unset -f _le_front_dir 2>/dev/null || :
unset _le_src _le_root _le_locals 2>/dev/null
