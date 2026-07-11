#!/usr/bin/env bash
# Regression test for the BASH_ENV chain-source runaway (your-org/nexus-code#457).
#
# monitor/shellenv/bash_env.sh is exported as $BASH_ENV for agent bash
# processes, so bash sources it at the start of EVERY non-interactive shell.
# It chains to the operator's prior BASH_ENV ($NEXUS_PREV_BASH_ENV — typically
# Lmod's `/app/lmod/lmod/init/bash`). The watcher's poll path fires ~100
# `bash config/load.sh <key>` config reads per cycle, each a fresh
# non-interactive bash. Before the fix, EVERY one re-sourced the prior env.
#
# NOTE ON THE MECHANISM (your-org/nexus-code#480). An earlier version of this
# header said the prior env "itself spawns a bash", producing a re-source
# recursion. That reading was FALSIFIED: sourcing Lmod's init spawns no bash.
# What it does is arm a `command_not_found_handle`; bash forks a child before
# invoking that handler, and if the handler's own helper is unresolvable the
# handler re-fires in the child, forking again — the unbounded parent→child
# chain (each level blocked in wait(), argv inherited, which is why the
# forensics found runaway `bash …/main.sh --once` processes that never ran it).
#
# This test still covers what it always covered, and that is still worth
# pinning: the chain must be sourced ONCE PER PROCESS TREE, gated by an exported
# `NEXUS_BASH_ENV_CHAINED` marker set BEFORE the source so a child the chained
# init spawns already sees it and does not re-enter. It drives that with a fake
# prior-env that DOES spawn a bash — a synthetic shape chosen to make re-entry
# observable, not a claim about Lmod. The real fork-chain mechanism is covered
# by test-bash-env-cnf-handler.sh.
#
# This test drives that exact shape hermetically: a fake prior-env that spawns
# a child bash on every source. With the guard the chain sources a bounded
# number of times; without it, it climbs to a self-imposed safety cap (so the
# test can never actually fork-bomb the machine). We assert the bounded count
# AND that the marker is set after the first source.
#
# Run: bash monitor/watcher/test-bash-env-chain-guard.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Fully hermetic (no network,
# no real Lmod, self-limited process count).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
BASH_ENV_FILE="$_repo_root/monitor/shellenv/bash_env.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$BASH_ENV_FILE" ]] || { echo "missing: $BASH_ENV_FILE" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fake prior BASH_ENV. Every time it is sourced it (1) appends a line to a
# counter file and (2) spawns a child bash — the shape that recurses. The
# child inherits $BASH_ENV + $NEXUS_PREV_BASH_ENV, so absent the guard it
# re-sources bash_env.sh, which re-sources this file, which spawns another
# bash … the #457 recursion. The spawn is SELF-LIMITED to SAFETY_CAP: this
# file stops spawning once the counter reaches the cap, so a regression is
# bounded to SAFETY_CAP processes here — the test can never fork-bomb the
# machine, and correctness does not depend on a per-process ulimit (which
# false-fails on a loaded shared node). The cap is comfortably above the
# pass threshold so a regression is unambiguous.
COUNTER="$WORK/source-count"
SAFETY_CAP=25
: > "$COUNTER"
cat > "$WORK/prior-env.sh" <<PRIOR
printf 'x\n' >> "$COUNTER"
_n=\$(wc -l < "$COUNTER")
if [ "\$_n" -lt "$SAFETY_CAP" ]; then
    bash -c ':' 2>/dev/null || true
fi
PRIOR

# Drive one top-level non-interactive bash through the real bash_env.sh with
# our fake prior env. Ambient nexus exports (this suite runs from agent shells
# that already carry NEXUS_PREV_BASH_ENV / NEXUS_BASH_ENV_CHAINED / BASH_ENV)
# must not leak in — isolate them so the case tests only our fixture.
run_chain() {
    env -u NEXUS_BASH_ENV_CHAINED \
        NEXUS_ROOT="$WORK/nexus" \
        NEXUS_PREV_BASH_ENV="$WORK/prior-env.sh" \
        BASH_ENV="$BASH_ENV_FILE" \
        COUNTER="$COUNTER" \
        bash -c 'printf "MARKER=%s\n" "${NEXUS_BASH_ENV_CHAINED:-unset}"'
}

echo "=== bash_env.sh chain-source is bounded (no #457 runaway) ==="

marker_out=$(run_chain 2>/dev/null)
n_sourced=$(wc -l < "$COUNTER" | tr -d ' ')

# The guard must keep the prior-env source count SMALL. One top-level bash
# sources bash_env once (→ prior once). The prior spawns one child bash; with
# the guard that child sees NEXUS_BASH_ENV_CHAINED and does NOT re-source the
# prior. So a correct implementation yields exactly 1 source. We allow a little
# slack (≤ 3) for implementation latitude; a regression climbs to SAFETY_CAP.
if [ "$n_sourced" -ge 1 ] && [ "$n_sourced" -le 3 ]; then
    ok "prior BASH_ENV sourced a bounded number of times ($n_sourced)"
else
    bad "chain-source bounded" "prior env sourced $n_sourced times (cap $SAFETY_CAP) — recursion guard missing/ineffective"
fi

# The guard marker must be exported so child shells inherit it and skip the
# re-source. The top-level shell that ran the chain must carry it.
if grep -qx 'MARKER=1' <<<"$marker_out"; then
    ok "NEXUS_BASH_ENV_CHAINED marker exported after chaining"
else
    bad "marker exported" "got: ${marker_out:-<empty>}"
fi

# Sanity: with NO prior env, bash_env.sh must still source cleanly and set no
# spurious marker (the guard only arms when it actually chains).
noprior_out=$(
    NEXUS_ROOT="$WORK/nexus" \
    BASH_ENV="$BASH_ENV_FILE" \
    env -u NEXUS_PREV_BASH_ENV -u NEXUS_BASH_ENV_CHAINED \
        bash -c 'printf "MARKER=%s\n" "${NEXUS_BASH_ENV_CHAINED:-unset}"' 2>/dev/null
)
if grep -qx 'MARKER=unset' <<<"$noprior_out"; then
    ok "no prior env → clean source, marker not armed"
else
    bad "no-prior clean source" "got: ${noprior_out:-<empty>}"
fi

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "FAILED"
    exit 1
fi
