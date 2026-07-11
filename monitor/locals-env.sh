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
if [ -d "$_le_root/monitor/pipwrap" ]; then
    case ":${PATH:-}:" in
        *":$_le_root/monitor/pipwrap:"*) : ;;           # already present
        *) export PATH="$_le_root/monitor/pipwrap:${PATH:-}" ;;
    esac
fi

if [ -d "$_le_root/monitor/notifywrap" ]; then
    case ":${PATH:-}:" in
        *":$_le_root/monitor/notifywrap:"*) : ;;        # already present
        *) export PATH="$_le_root/monitor/notifywrap:${PATH:-}" ;;
    esac
fi

if [ -d "$_le_root/monitor/ghwrap" ]; then
    case ":${PATH:-}:" in
        *":$_le_root/monitor/ghwrap:"*) : ;;            # already present
        *) export PATH="$_le_root/monitor/ghwrap:${PATH:-}" ;;
    esac
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

unset _le_src _le_root _le_locals 2>/dev/null
