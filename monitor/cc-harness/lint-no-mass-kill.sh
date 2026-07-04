#!/usr/bin/env bash
# monitor/cc-harness/lint-no-mass-kill.sh — safety lint for the cc-harness.
#
# Forbids cmdline-pattern process kills in harness code. Every nexus agent
# (orchestrator, every worker, the mock-lab) runs the SAME project-local
# claude binary inside ONE shared sandbox PID namespace. A `pkill -f
# <pattern>` whose pattern matches that binary's command line therefore
# SIGTERMs EVERY agent at once — a full control-plane wipe. That exact line,
# `pkill -f "node_modules/.bin/claude"`, run from the harness absent-state
# test, killed all five live agents on 2026-05-29; see
# reports/nexus_2026-05-29_142117_crash-postmortem-pkill-mass-kill.md.
#
# Rule: harness process kills MUST be PID-scoped — `kill <pid>`, `pkill -P
# <ppid>`, or the recursive descendant-tree walk in cch_kill_claude(). Kills
# that select by command line (`pkill -f` / `pkill --full`, `pgrep -f`,
# `killall`) are banned outright; the harness has no legitimate use for them.
#
# This file excludes ITSELF from the scan, so the patterns named above in its
# own comments/regex do not self-trip the lint.
#
# Usage:  lint-no-mass-kill.sh [target-dir]   (default: this script's dir)
# Exit:   0 = clean, 1 = a banned pattern was found (offending lines on stderr).
set -uo pipefail

self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
self_base=$(basename "${BASH_SOURCE[0]}")
target="${1:-$self_dir}"

# Banned: pkill/pgrep carrying a command-line-match flag (-f / --full), or
# any `killall`. PID-scoped `pkill -P` / `pgrep -P` are deliberately allowed.
banned_re='(pkill|pgrep)([[:space:]]+[^|&;#]*)?[[:space:]](-f|--full)([[:space:]]|$)|(^|[^[:alnum:]_])killall([[:space:]]|$)'

hits=$(
  find "$target" -type f \( -name '*.sh' -o -name '*.py' \) ! -name "$self_base" -print0 \
    | while IFS= read -r -d '' f; do
        # Drop full-line comments (leading-whitespace then #) before matching
        # so the ban fires only on real command usage, not documentation.
        grep -nE "$banned_re" "$f" 2>/dev/null \
          | grep -vE '^[0-9]+:[[:space:]]*#' \
          | sed "s|^|$f:|"
      done
)

if [[ -n "$hits" ]]; then
    {
        echo "LINT FAIL — cmdline-pattern process kill in harness code."
        echo "  This can mass-kill every agent in the shared PID namespace"
        echo "  (crash postmortem 2026-05-29). Use a PID-scoped kill instead:"
        echo "  kill <pid> / pkill -P <ppid> / cch_kill_claude()."
        echo "  Offending lines:"
        echo "$hits"
    } >&2
    exit 1
fi
echo "lint-no-mass-kill: clean ($target)"
