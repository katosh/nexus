#!/usr/bin/env bash
# Tests for the self-install gate in monitor/watcher/launcher.sh — the
# block that decides whether to run monitor/install-claude-local.sh.
#
# Run: bash monitor/watcher/test-launcher-claude-install-gate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Hermetic: no network, no
# $HOME writes, no tmux, no watcher process. Every fixture is a mktemp -d
# stand-in nexus root.
#
# THE BUG this pins. The gate used to ask:
#
#     if [[ ! -x "$_nexus_root/node_modules/.bin/claude" ]]; then
#         ... run install-claude-local.sh
#
# On a nexus pinned to a NATIVE Claude Code install (config
# `nexus.claude_bin`) there is no npm tree by design, so that test was
# true on EVERY launcher start. Each watcher launch re-created the npm
# install the operator had just removed — and because node_modules
# outranks PATH in monitor/_claude-bin.sh, the workspace silently went
# back to the npm binary. The operator's switch undid itself at the first
# restart, with no error anywhere.
#
# THE FIX: ask the resolver "can we start claude at all?" instead of
# testing one particular path.
#
# Case 5 is the control that gives the other cases meaning: it runs the
# PRE-FIX gate against the same fixture and asserts it DOES install. A
# test that only exercises the fixed code cannot tell you it would have
# caught the bug.
#
# Method: the gate block is EXTRACTED from the real launcher.sh between
# two comment anchors and run in a harness. Extracting (rather than
# re-typing) means the test pins the shipped source — edit the block and
# this test follows it. The same technique as the #428-era control loop
# in test-cc-restart-watchdog-loop.sh.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
LAUNCHER="$_test_dir/launcher.sh"
RESOLVER="$_repo_root/monitor/_claude-bin.sh"
LOADER="$_repo_root/config/load.sh"

PASS=0
FAIL=0
SKIP=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
skip() { printf '  SKIP: %s — %s\n' "$1" "$2"; SKIP=$(( SKIP + 1 )); }

[[ -f "$LAUNCHER" ]] || { echo "missing launcher: $LAUNCHER" >&2; exit 1; }

# A PATH with no claude on it. /usr/bin also carries the pyyaml-capable
# python3 that config/load.sh needs for the config cases.
BARE_PATH=/usr/bin:/bin

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- extract the gate block from the shipped launcher --------------------
GATE="$WORK/gate-block.sh"
awk '/^# Self-install Claude Code if NO binary resolves at all/,/^# Provision the stable locals\/bin tool links/' \
    "$LAUNCHER" | sed '$d' > "$GATE"
if ! grep -q 'install-claude-local.sh' "$GATE"; then
    echo "extraction failed: the gate block anchors moved in launcher.sh" >&2
    echo "  update the awk anchors in this test" >&2
    exit 1
fi

# The PRE-FIX gate: same block, but the probe replaced by the old direct
# path test. Built by MUTATING the extracted block, so it stays honest.
GATE_PREFIX="$WORK/gate-block-prefix.sh"
{
    printf 'if [[ ! -x "$_nexus_root/node_modules/.bin/claude" ]]; then\n'
    # everything from the installer echo onward, minus the new probe/branch
    awk '/running monitor\/install-claude-local.sh/,0' "$GATE"
} > "$GATE_PREFIX"

# ---- fixture -------------------------------------------------------------
# <root>/monitor/_claude-bin.sh   the REAL resolver
# <root>/monitor/install-claude-local.sh   stub that logs each invocation
new_fixture() {
    local root="$WORK/nexus.$RANDOM$RANDOM"
    mkdir -p "$root/monitor"
    cp "$RESOLVER" "$root/monitor/_claude-bin.sh"
    cat > "$root/monitor/install-claude-local.sh" <<EOF
#!/usr/bin/env bash
echo invoked >> "$root/.install-invocations.log"
mkdir -p "$root/node_modules/.bin"
printf '#!/bin/sh\necho npm-claude\n' > "$root/node_modules/.bin/claude"
chmod +x "$root/node_modules/.bin/claude"
exit 0
EOF
    chmod +x "$root/monitor/install-claude-local.sh"
    printf '%s' "$root"
}

add_npm_claude() {
    mkdir -p "$1/node_modules/.bin"
    printf '#!/bin/sh\necho npm-claude\n' > "$1/node_modules/.bin/claude"
    chmod +x "$1/node_modules/.bin/claude"
}

add_config() {   # <root> <claude_bin value, or empty for no key>
    mkdir -p "$1/config"
    cp "$LOADER" "$1/config/load.sh"; chmod +x "$1/config/load.sh"
    : > "$1/config/nexus.example.yml"
    if [[ -n "$2" ]]; then
        printf 'nexus:\n  claude_bin: %s\n' "$2" > "$1/config/nexus.yml"
    else
        printf 'nexus:\n  root: %s\n' "$1" > "$1/config/nexus.yml"
    fi
}

add_native_claude() {   # <path>
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho native-claude\n' > "$1"
    chmod +x "$1"
}

run_gate() {   # <gate-file> <root>
    env -u CLAUDE_BIN -u BASH_ENV PATH="$BARE_PATH" bash -c '
        set -uo pipefail
        _nexus_root="$1"
        . "$2"
    ' _ "$2" "$1" >/dev/null 2>&1
}

installs_ran() { [[ -f "$1/.install-invocations.log" ]] && wc -l < "$1/.install-invocations.log" || echo 0; }

# Does this host have a pyyaml-capable python3 on BARE_PATH? The config
# cases need one; without it the resolver is designed to fall through.
loader_works=0
_probe=$(new_fixture); add_config "$_probe" /bin/true
if env -u BASH_ENV PATH="$BARE_PATH" NEXUS_ROOT="$_probe" \
        "$_probe/config/load.sh" nexus.claude_bin "" >/dev/null 2>&1; then
    loader_works=1
fi

echo "=== 1. npm install present → installer NOT run ==="
r=$(new_fixture); add_npm_claude "$r"
run_gate "$GATE" "$r"
if [[ "$(installs_ran "$r")" == 0 ]]; then
    ok "an existing npm install is left alone"
else
    bad "case 1" "the installer ran with a usable npm install present"
fi

echo "=== 2. nothing resolvable anywhere → installer RUN ==="
r=$(new_fixture)
run_gate "$GATE" "$r"
if [[ "$(installs_ran "$r")" == 1 ]]; then
    ok "a host with no claude at all still self-installs"
else
    bad "case 2" "the installer did NOT run on a host with no claude"
fi

echo "=== 3. THE REGRESSION: native pin, no npm tree → installer NOT run ==="
if (( loader_works )); then
    r=$(new_fixture)
    native="$WORK/native$RANDOM/claude"
    add_native_claude "$native"
    add_config "$r" "$native"
    run_gate "$GATE" "$r"
    if [[ "$(installs_ran "$r")" == 0 ]]; then
        ok "a native-pinned nexus is NOT re-npm-installed"
    else
        bad "case 3" "the installer ran and re-created the npm tree under a native pin"
    fi
    if [[ ! -e "$r/node_modules" ]]; then
        ok "no node_modules tree was created"
    else
        bad "case 3 tree" "node_modules re-appeared at $r/node_modules"
    fi

    echo "=== 4. pin set but broken → installer NOT run, flag written ==="
    r=$(new_fixture)
    add_config "$r" "$WORK/does/not/exist"
    run_gate "$GATE" "$r"
    if [[ "$(installs_ran "$r")" == 0 ]]; then
        ok "a broken pin is not answered by installing over it"
    else
        bad "case 4" "the installer ran over a broken operator pin"
    fi
    flag=""
    for f in "$r"/monitor/.state/local-claude-install-failed.*; do
        [[ -e "$f" ]] && { flag=$f; break; }
    done
    if [[ -n "$flag" ]] && grep -q 'nexus.claude_bin' "$flag"; then
        ok "a failure flag naming nexus.claude_bin is left for the orchestrator"
    else
        bad "case 4 flag" "no flag naming the key (${flag:-none written})"
    fi

    echo "=== 5. CONTROL: the pre-fix gate DOES re-install under a native pin ==="
    r=$(new_fixture)
    add_config "$r" "$native"
    run_gate "$GATE_PREFIX" "$r"
    if [[ "$(installs_ran "$r")" == 1 ]]; then
        ok "the pre-fix gate reproduces the bug (so cases 3-4 are meaningful)"
    else
        bad "case 5" "the pre-fix gate did NOT install — the control proves nothing"
    fi
else
    skip "cases 3-5" "config/load.sh cannot read yaml on this host"
fi

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d passed, %d skipped)\n' "$PASS" "$SKIP"
    exit 0
else
    printf '%d PASSED, %d FAILED, %d SKIPPED\n' "$PASS" "$FAIL" "$SKIP" >&2
    exit 1
fi
