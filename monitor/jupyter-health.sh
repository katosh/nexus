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

dir="${1:-$PWD}"
cd "$dir" 2>/dev/null || exit 1

env_file=".jupyter/labsh-service.env"
[[ -f "$env_file" ]] || exit 1

# Parse, don't source: the env file lives in the (possibly foreign)
# project tree and must not be able to run code in the health probe.
port=$(sed -n 's/^PORT=//p' "$env_file" 2>/dev/null | head -1)
scheme=$(sed -n 's/^SCHEME=//p' "$env_file" 2>/dev/null | head -1)
[[ "$port" =~ ^[0-9]+$ ]] || exit 1
case "$scheme" in http|https) ;; *) scheme=http ;; esac

token=$(cat .jupyter/token 2>/dev/null)
[[ -n "$token" ]] || exit 1

# -k: labsh --https uses a self-signed cert under .jupyter/ssl/.
# 127.0.0.1: both the default 0.0.0.0 bind and --ip 127.0.0.1 answer on
# loopback; a service bound to a single external interface would not,
# but jupyter-up.sh never produces that configuration.
exec curl -fsSk -o /dev/null --max-time "${LABSH_HEALTH_TIMEOUT:-3}" \
    -H "Authorization: token $token" \
    "$scheme://127.0.0.1:$port/api/status"
