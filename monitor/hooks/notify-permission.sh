#!/usr/bin/env bash
# monitor/hooks/notify-permission.sh — the ONE bell the severity gate must not
# swallow: an agent genuinely blocked awaiting operator approval.
#
# WHY THIS EXISTS. monitor/notifywrap/sandbox-notify suppresses the
# agent-sandbox hook default ("Needs attention") for every agent, because that
# single fixed string covers BOTH `idle_prompt` (routine turn-end, ~99.6% of
# events) and `permission_prompt` (work is actually blocked). The wrapper is
# handed only the message text, so it cannot tell them apart — by the time the
# bell reaches it, the distinction is gone.
#
# A Claude Code `Notification` hook, however, receives the full event as JSON on
# stdin, including `notification_type`. So the nexus makes the distinction HERE,
# upstream of the gate, and re-emits a classified message that the gate
# recognises as its own `permission` class (cooled down, but never
# class-suppressed). Net effect: routine idle goes quiet, a genuine block still
# rings.
#
# Scope note: this is deliberately NOT a general "worker seems stuck" alarm.
# The watcher already reports parked / idle-without-wrap workers, and
# duplicating that here would re-create the flood from a second source. Both
# the orchestrator (monitor/watcher/_respawn.sh) and workers
# (monitor/spawn-worker.sh) launch with `--dangerously-skip-permissions`, so
# this path is rare by construction — 15 of 4008 notifications over 71 days.
#
# Best-effort throughout: a notification hook must never fail loudly or block
# the agent.

set -u

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

ntype=""
if command -v jq >/dev/null 2>&1; then
    ntype=$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null || true)
fi
# jq-free fallback so the hook still works on a stripped host.
if [ -z "$ntype" ]; then
    case "$payload" in
        *'"notification_type"'*'permission_prompt'*) ntype="permission_prompt" ;;
    esac
fi

[ "$ntype" = "permission_prompt" ] || exit 0

win="${NEXUS_WORKER_WINDOW:-${NEXUS_ORCHESTRATOR_WINDOW:-orchestrator}}"

# "permission needed" is the prefix monitor/notifywrap/sandbox-notify keys its
# `permission` class on. Keep the two in sync.
command -v sandbox-notify >/dev/null 2>&1 \
    && sandbox-notify "permission needed: $win is blocked awaiting approval" \
        >/dev/null 2>&1 || true

exit 0
