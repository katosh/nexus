#!/usr/bin/env bash
# monitor/hooks/gh-write-guard.sh
#
# Claude Code PreToolUse hook for the `Bash` matcher. BACKSTOP only — the
# primary mechanism is the PATH-FRONT `gh` wrapper (monitor/ghwrap/gh), placed
# first on PATH for every agent process (monitor/locals-env.sh +
# monitor/shellenv/.zshenv). This hook catches the residual case the wrapper
# cannot: a `gh` WRITE that BYPASSES it — invoked as `command gh`, an
# absolute/relative path (`/…/gh`, `./gh`), or an escaped `\gh` — with neither
# a bot token (`GH_TOKEN=…`/`mint-token.sh`) nor the `GH_IMPERSONATE` opt-in in
# the command. Such a call would run as the OPERATOR and silently mute their
# notification.
#
# It WARNS, it does not block: bash command parsing is brittle (see the
# CLAUDE.md gotchas), so a hard block would false-positive. We append an
# advisory to monitor/.state/gh-bypass-warnings.log and print to stderr.
# Exit 0 always — a backstop must never wedge a turn.
#
# Inputs: PreToolUse payload JSON on stdin (.tool_input.command).
# Env: $NEXUS_ROOT (state-dir root), $NEXUS_STATE_DIR (test override).

set -u

command -v jq >/dev/null 2>&1 || exit 0

if [ -n "${NEXUS_STATE_DIR:-}" ]; then
    _state_dir="$NEXUS_STATE_DIR"
elif [ -n "${NEXUS_ROOT:-}" ]; then
    _state_dir="$NEXUS_ROOT/monitor/.state"
else
    exit 0
fi

_payload=$(head -c 65536 2>/dev/null || true)
[ -n "$_payload" ] || exit 0

_tool=$(printf '%s' "$_payload" | jq -r '.tool_name // empty' 2>/dev/null) || _tool=""
[ "$_tool" = "Bash" ] || exit 0

_cmd=$(printf '%s' "$_payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || _cmd=""
[ -n "$_cmd" ] || exit 0

# Only a BYPASS invocation: `command gh`, `*/gh`, `./gh`, or `\gh`. A bare
# `gh …` rides the function shim and is fine — not flagged.
case "$_cmd" in
    *"command gh "*|*"command gh"$'\t'*) : ;;
    *[\ \t=]/*/gh\ *|/*/gh\ *) : ;;
    *./gh\ *) : ;;
    *'\gh '*) : ;;
    *) exit 0 ;;
esac

# A bot token or an explicit impersonation opt-in in the command means the
# caller chose an identity on purpose — not a slip.
case "$_cmd" in
    *"GH_TOKEN="*|*"mint-token.sh"*|*"GH_IMPERSONATE"*) exit 0 ;;
esac

# Coarse write-verb match (advisory; err toward warning).
if printf '%s' "$_cmd" | grep -Eq 'gh ([^|;&]*\b)?(pr (create|edit|merge|comment|close|reopen|ready|review)|issue (create|edit|comment|close|reopen|lock|delete)|release (create|edit|delete|upload)|api [^|;&]*(graphql|--input|--field|--raw-field|-F |-f |(-X|--method)[= ]*(POST|PATCH|PUT|DELETE)))'; then
    mkdir -p "$_state_dir" 2>/dev/null || true
    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-ts)
    # Explicit mode at creation (your-org/nexus-code#484). An audit trail of
    # bot-identity bypasses that any group member can rewrite is not a trail.
    # Guarded source: a hook must never wedge claude's turn.
    # shellcheck source=../_log-mode.sh
    . "$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/_log-mode.sh" 2>/dev/null || true
    command -v _ensure_service_log >/dev/null 2>&1 \
        && _ensure_service_log "$_state_dir/gh-bypass-warnings.log" || true
    printf '%s\twindow=%s\tcmd=%s\n' "$_ts" \
        "${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-unknown}}" "$_cmd" \
        >> "$_state_dir/gh-bypass-warnings.log" 2>/dev/null || true
    printf 'gh-write-guard: WARNING — a `gh` WRITE appears to bypass the bot-default shim (raw/command/absolute-path gh) with no GH_TOKEN and no GH_IMPERSONATE. It will post as the OPERATOR and mute their notification. Use a bare `gh …` (rides the shim) or `GH_TOKEN=$(./monitor/mint-token.sh) gh …`; impersonate on purpose with `GH_IMPERSONATE=1 GH_IMPERSONATE_REASON="…" gh …`.\n' >&2
fi
exit 0
