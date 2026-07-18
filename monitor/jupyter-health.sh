#!/usr/bin/env bash
# jupyter-health.sh — cheap authenticated healthcheck for a project-local
# labsh JupyterLab service.
#
# Usage: jupyter-health.sh [PROJECT_DIR]      (default: $PWD)
# Exit 0  iff the project's JupyterLab answers /api/status with the
#         project's current auth token.
#
# This is the registry healthcheck command for jupyter-* services AND the
# probe labsh-supervised.sh runs between restarts — one implementation,
# so the supervisor and the recovery sweep can never disagree on
# "healthy". It is deliberately discriminating: an unauthenticated 200
# (e.g. another user's Jupyter squatting the port, or a login page) does
# NOT pass, because /api/status returns 403 without the right token.
#
# Reads (both written under <project>/.jupyter/):
#   labsh-service.env  PORT= / SCHEME= persisted by labsh-supervised.sh
#                      after each successful start (tracks labsh's port
#                      auto-increment). Absent -> unhealthy (the service
#                      has never been brought up here).
#   token              labsh's stable auth token (re-read every probe, so
#                      a rotate-then-restart converges on healthy).
#
# Env: LABSH_HEALTH_TIMEOUT — curl --max-time, seconds (default 3).

set -uo pipefail

# Every failure path says WHY, on stderr (your-org/your-nexus#273). Exit codes
# and the pass/fail verdict are UNCHANGED — this only adds a diagnosis to a
# probe that used to fail mute. During the 2026-07-13 outage the probe printed
# nothing at all, so "unhealthy" was indistinguishable between "no server yet",
# "cold build still materialising", "port refused" and "wrong token" — and
# guessing wrong is what escalated a slow bring-up into a 40-minute outage.
# Callers that don't want the noise already redirect (the supervisor and the
# watcher both probe with >/dev/null 2>&1), so this costs them nothing.
die() { echo "jupyter-health: $*" >&2; exit 1; }

# If a cold uvx build is in flight, say so — that is the single most
# misread state. Best-effort and purely advisory: it never changes the
# verdict, it only explains it.
_build_note() {
    local jdir="$1/.jupyter" bglog pid
    bglog="$jdir/labsh.bg.log"
    [[ -f "$bglog" ]] || return 0
    grep -qE 'is running at|https?://[0-9A-Za-z._-]+:[0-9]+/' "$bglog" 2>/dev/null && return 0
    pid=$(cat "$jdir/labsh.bg.pid" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 0
    local age; age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [[ "$age" =~ ^[0-9]+$ ]] || return 0
    echo "jupyter-health: NOTE — a labsh cold build (pid $pid) has been running $(( age / 60 ))m and has not bound a URL yet;" >&2
    echo "jupyter-health:        a cold uvx bring-up takes ~19 min on this NFS cache. Do NOT restart it — that discards the build." >&2
}

dir="${1:-$PWD}"
cd "$dir" 2>/dev/null || die "project dir not readable: ${1:-$PWD}"

env_file=".jupyter/labsh-service.env"
[[ -f "$env_file" ]] || { _build_note "$PWD"; die "no $env_file under $PWD — the service has never been brought up here"; }

# Parse, don't source: the env file lives in the (possibly foreign)
# project tree and must not be able to run code in the health probe.
port=$(sed -n 's/^PORT=//p' "$env_file" 2>/dev/null | head -1)
scheme=$(sed -n 's/^SCHEME=//p' "$env_file" 2>/dev/null | head -1)
[[ "$port" =~ ^[0-9]+$ ]] || die "no valid PORT= in $env_file (got '${port:-<empty>}')"
case "$scheme" in http|https) ;; *) scheme=http ;; esac

token=$(cat .jupyter/token 2>/dev/null)
[[ -n "$token" ]] || die "no auth token at $PWD/.jupyter/token — cannot probe $scheme://127.0.0.1:$port authenticated"

# -k: labsh --https uses a self-signed cert under .jupyter/ssl/.
# 127.0.0.1: both the default 0.0.0.0 bind and --ip 127.0.0.1 answer on
# loopback; a service bound to a single external interface would not,
# but jupyter-up.sh never produces that configuration.
#
# Not exec'd any more: a non-zero curl must still get to explain itself.
curl -fsSk -o /dev/null --max-time "${LABSH_HEALTH_TIMEOUT:-3}" \
    -H "Authorization: token $token" \
    "$scheme://127.0.0.1:$port/api/status" && exit 0

rc=$?
case "$rc" in
    7)  echo "jupyter-health: nothing listening on $scheme://127.0.0.1:$port (connection refused)" >&2 ;;
    22) echo "jupyter-health: $scheme://127.0.0.1:$port answered but REJECTED our token (/api/status 4xx) — token rotated, or another server owns this port" >&2 ;;
    28) echo "jupyter-health: $scheme://127.0.0.1:$port timed out after ${LABSH_HEALTH_TIMEOUT:-3}s — server may be alive but loaded (raise LABSH_HEALTH_TIMEOUT to distinguish)" >&2 ;;
    *)  echo "jupyter-health: curl exit $rc probing $scheme://127.0.0.1:$port/api/status" >&2 ;;
esac
_build_note "$PWD"
exit "$rc"
