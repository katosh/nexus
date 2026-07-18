#!/usr/bin/env bash
# monitor/cc-harness/gate.sh — pre-update gate for Claude Code version
# bumps. Runs the real-binary harness scenarios against a CANDIDATE
# claude version installed in a throwaway prefix, returning a clean
# green/red exit BEFORE the version pin is promoted in the live clone.
#
# The scenarios drive the candidate binary against the auth-free mock
# (no Anthropic creds, no network egress) and assert that
# monitor/pane-state.sh still classifies the live panes correctly —
# i.e. that the new release didn't drift the TUI bytes the watcher
# depends on (chevron, spinner token-counter, empty-box cursor,
# AskUserQuestion chip-bar, dead-pane frame). This is exactly the class
# of breakage that has historically only surfaced in production.
#
# Usage:
#   monitor/cc-harness/gate.sh --version <npm-version>   # install + gate
#   monitor/cc-harness/gate.sh --claude-bin <path>       # gate an existing build
#   monitor/cc-harness/gate.sh                           # gate the project-local install
#
# Exit: 0 = green (safe to promote), non-zero = red (do NOT promote).
#
# Bump -> gate -> promote flow (see monitor/cc-harness/README.md):
#   1. Pick the target version (cc publishes ~daily; target latest-at-time).
#   2. gate.sh --version <ver>      # green/red against the candidate
#   3. If green: bump package.json's @anthropic-ai/claude-code pin + run
#      monitor/install-claude-local.sh in the live clone (use `npm install`,
#      NOT `npm ci`, on the NFS clone — see README), commit the pin.
#   4. Restart the watcher to load the new binary.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../.." && pwd)

# Shared node bootstrap (Lmod/Tcl-module HPC hosts where node lives behind
# `module load nodejs`). Both the candidate `npm install` and the
# real-binary scenarios consume node; without this the gate would skip on
# a module-based host with node off the default PATH — and a skipped
# scenario must never read as a pass (see the fail-on-skip logic below).
NEXUS_ROOT="$REPO_ROOT"
# shellcheck source=../_node-bootstrap.sh
. "$REPO_ROOT/monitor/_node-bootstrap.sh"

# trash_path: rename-aside instead of unlink, so tearing down a throwaway
# prefix never trips on a held-open inode (`.nfs`/EBUSY over NFS).
# shellcheck source=../_trash.sh
. "$REPO_ROOT/monitor/_trash.sh"

version=""
claude_bin="${CLAUDE_BIN:-}"
while (( $# > 0 )); do
    case "$1" in
        --version)    version="$2"; shift 2;;
        --claude-bin) claude_bin="$2"; shift 2;;
        -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
        *) echo "gate.sh: unknown arg: $1" >&2; exit 2;;
    esac
done

cleanup_prefix=""
cleanup_npm_cache=""
# Move the throwaway prefix aside (rename) rather than rm — a scenario's
# claude may still be releasing files on NFS, where unlink would `.nfs`-lock
# and rm would fail. trash_path always succeeds via same-fs rename; the
# entry is reaped later by `_trash.sh --clear`. Fall back to rm if trashing
# is somehow unavailable. A throwaway npm cache we created (see below) is
# also reaped here so a gate run leaves no temp-dir litter behind.
cleanup() {
    if [[ -n "$cleanup_prefix" && -d "$cleanup_prefix" ]]; then
        trash_path "$cleanup_prefix" >/dev/null 2>&1 || rm -rf "$cleanup_prefix" 2>/dev/null || true
    fi
    if [[ -n "$cleanup_npm_cache" && -d "$cleanup_npm_cache" ]]; then
        rm -rf "$cleanup_npm_cache" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Safety pre-flight: refuse to gate (or run any scenario) if harness code
# contains a cmdline-pattern process kill. Such a kill matches the shared
# project-local claude binary across the whole sandbox PID namespace and
# wipes every agent at once (crash postmortem 2026-05-29). Fail red before
# touching a candidate binary.
echo "=== safety lint: no cmdline-pattern process kills in harness ==="
if ! "$_self_dir/lint-no-mass-kill.sh"; then
    echo "gate.sh: harness safety lint failed — refusing to gate." >&2
    exit 1
fi

# Bring node onto PATH up front (module bootstrap on Lmod/Tcl hosts) so
# both the candidate install and the scenarios can run. Best-effort; the
# per-path checks below stay the hard gate.
nexus_ensure_node || true

# Writable npm cache for the candidate `npm install` below. npm defaults its
# cache (and, on npm 10/Node 20, its _logs) to $HOME/.npm — READ-ONLY on
# sandboxed/HPC hosts (agent-sandbox, ro-home compute nodes), where the
# install then aborts with `EROFS: read-only file system` at the first cacache
# write, before a single package is fetched (your-org/nexus-code#325; the same
# failure install-claude-local.sh already guards). Honor an operator-set
# npm_config_cache / NPM_CONFIG_CACHE; otherwise default to a throwaway cache
# under TMPDIR that the EXIT trap reaps. Unlike install-claude-local.sh's
# persistent project-local cache, the gate is a throwaway harness — a
# per-run temp cache keeps the tree clean and never collides with a parallel
# run (the `-$$` suffix is PID-unique).
if [[ -z "${npm_config_cache:-}" && -z "${NPM_CONFIG_CACHE:-}" ]]; then
    export npm_config_cache="${TMPDIR:-/tmp}/cc-gate-npm-cache-$$"
    cleanup_npm_cache="$npm_config_cache"
else
    export npm_config_cache="${npm_config_cache:-$NPM_CONFIG_CACHE}"
fi
mkdir -p "$npm_config_cache" 2>/dev/null \
    || { echo "gate.sh: cannot create npm cache dir: $npm_config_cache (set npm_config_cache/NPM_CONFIG_CACHE to a writable path)" >&2; exit 1; }

if [[ -n "$version" ]]; then
    command -v npm >/dev/null 2>&1 || { echo "gate.sh: npm not on PATH" >&2; exit 1; }
    cleanup_prefix=$(mktemp -d -t cc-gate-prefix-XXXXXX)
    echo "=== installing @anthropic-ai/claude-code@$version into throwaway prefix ==="
    echo "    $cleanup_prefix"
    # --prefix keeps it fully out of the live tree; the live pin is
    # untouched until you choose to promote.
    if ! npm install --prefix "$cleanup_prefix" "@anthropic-ai/claude-code@$version" --loglevel=http; then
        echo "gate.sh: candidate install failed" >&2
        exit 1
    fi
    claude_bin="$cleanup_prefix/node_modules/.bin/claude"
fi

if [[ -z "$claude_bin" ]]; then
    claude_bin="$REPO_ROOT/node_modules/.bin/claude"
fi
[[ -x "$claude_bin" ]] || { echo "gate.sh: no executable claude at $claude_bin" >&2; exit 1; }

echo "=== gating candidate ==="
echo "    binary:  $claude_bin"
echo "    version: $("$claude_bin" --version 2>/dev/null || echo '?')"

# The real-binary scenarios. Add new ones here as the suite grows.
# Overridable via CCH_GATE_SCENARIOS (space-separated paths) for
# the gate's own classification test (monitor/watcher/test-cc-gate.sh);
# production runs never set it.
if [[ -n "${CCH_GATE_SCENARIOS:-}" ]]; then
    read -r -a scenarios <<< "$CCH_GATE_SCENARIOS"
else
    scenarios=(
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-idle-busy.sh"
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-blocked-question.sh"
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-autosuggest.sh"
        # Over-limit status + reset-time detection (2026-07-14 incident):
        # pins the StopFailure payload shape (error="rate_limit" string +
        # last_assistant_message) and the notice-text detection a CC bump
        # can silently break — both broke unnoticed before this gate entry.
        "$REPO_ROOT/monitor/watcher/test-integration/test-realmodel-overlimit.sh"
    )
fi

# CCH_GATE=1 makes a scenario's self-skip exit 77 (the SKIP sentinel)
# instead of 0, so the gate can tell "validated and passed" apart from
# "could not validate". Under the gate a skip is a RED outcome: a skipped
# scenario means the candidate was NOT exercised, which is exactly the
# green-via-skip failure this gate exists to prevent (a prior gate printed
# GREEN with every scenario skipped for lack of node — your-org/your-nexus#236).
passed=0; failed=0; skipped=0
failed_names=(); skipped_names=()
for s in "${scenarios[@]}"; do
    echo
    echo "--- $(basename "$s") ---"
    CLAUDE_BIN="$claude_bin" RUN_CC_HARNESS=1 CCH_GATE=1 bash "$s"
    scen_rc=$?
    case "$scen_rc" in
        0)  passed=$((passed+1)) ;;
        77) echo "  >> SKIPPED: $(basename "$s") (candidate not exercised)" >&2
            skipped=$((skipped+1)); skipped_names+=("$(basename "$s")") ;;
        *)  echo "  >> FAILED: $(basename "$s") (rc=$scen_rc)" >&2
            failed=$((failed+1)); failed_names+=("$(basename "$s")") ;;
    esac
done

# RED on any failure OR any skip — a skip cannot count toward a green
# verdict (that was the bug).
rc=0
(( failed > 0 || skipped > 0 )) && rc=1

echo
echo "=== tally: ${passed} passed / ${failed} failed / ${skipped} skipped (of ${#scenarios[@]}) ==="
(( failed  > 0 )) && echo "    failed:  ${failed_names[*]}" >&2
(( skipped > 0 )) && echo "    skipped: ${skipped_names[*]} — a skip is RED (candidate not validated)" >&2
if (( rc == 0 )); then
    echo "=== GATE GREEN (${passed}/${#scenarios[@]} passed) — candidate is safe to promote ==="
else
    echo "=== GATE RED (${passed} passed / ${failed} failed / ${skipped} skipped) — do NOT promote this version ==="
fi
exit $rc
