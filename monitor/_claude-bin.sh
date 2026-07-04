#!/bin/bash
# monitor/_claude-bin.sh — shared $CLAUDE_BIN resolver for spawn surfaces.
#
# Sourced by every script that spawns a `claude` process. Resolves the
# binary path in this order:
#   1. CLAUDE_BIN env var (operator override).
#   2. $NEXUS_ROOT/node_modules/.bin/claude — project-local install,
#      managed by monitor/install-claude-local.sh.
#   3. `claude` on PATH (legacy system install).
# Fails loud with exit 1 if none are found.
#
# Why a shared helper: keeping the resolver in one file means future
# changes (e.g. a third lookup path, version-floor check) land in one
# place instead of drifting across spawn-worker.sh, entry.sh, main.sh,
# spawn-fresh-orchestrator.sh, bootstrap-install.sh, and claude-loop.sh.
#
# Why baked into heredocs at write time: every spawn surface writes a
# /tmp launcher script and tmux-spawns it. The launcher's heredoc is
# unquoted, so $CLAUDE_BIN interpolates at write time and the launcher
# contains the absolute path verbatim. This avoids re-resolving inside
# the launcher's shell (which may not have NEXUS_ROOT set yet).
#
# Caller contract: $NEXUS_ROOT must be set before sourcing. The helper
# is destructive on failure (calls `exit 1`) — that's intentional, a
# spawn surface that can't find claude has no recovery path.

if [[ -z "${NEXUS_ROOT:-}" ]]; then
    echo "_claude-bin.sh: NEXUS_ROOT must be set before sourcing" >&2
    exit 1
fi

if [[ -z "${CLAUDE_BIN:-}" ]]; then
    if [[ -x "$NEXUS_ROOT/node_modules/.bin/claude" ]]; then
        CLAUDE_BIN="$NEXUS_ROOT/node_modules/.bin/claude"
    elif command -v claude >/dev/null 2>&1; then
        CLAUDE_BIN="$(command -v claude)"
    else
        echo "_claude-bin.sh: no claude binary found" >&2
        echo "  Looked for: $NEXUS_ROOT/node_modules/.bin/claude" >&2
        echo "              claude on PATH" >&2
        echo "  Run: $NEXUS_ROOT/monitor/install-claude-local.sh" >&2
        exit 1
    fi
fi
export CLAUDE_BIN
