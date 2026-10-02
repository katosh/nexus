#!/usr/bin/env bash
# Tests for monitor/_claude-bin.sh — the shared $CLAUDE_BIN resolver every
# spawn surface sources.
#
# Run: bash monitor/watcher/test-claude-bin-resolver.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Hermetic: no network, no
# $HOME writes; every fixture lives under a mktemp -d stand-in NEXUS_ROOT,
# and PATH is pinned per case so the host's real claude never leaks in.
#
# The resolver's contract under test:
#   rank 1  CLAUDE_BIN env var
#   rank 2  config `nexus.claude_bin`   (operator-local native-install pin)
#   rank 3  $NEXUS_ROOT/node_modules/.bin/claude
#   rank 4  `claude` on PATH
#   exit 1  nothing resolved          (recoverable: bootstrap installs)
#   exit 2  rank-2 set but unusable   (NOT recoverable: callers refuse)
#
# The rank-2-beats-rank-3 case and the exit-2 case are the load-bearing
# ones. Rank 2 must outrank the npm tree or a re-appearing node_modules
# silently moves the workspace off the operator's pin; and a broken pin
# must never degrade into "quietly ran a different claude than you asked
# for", which is exactly what a fall-through to rank 3 would be.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
RESOLVER="$_repo_root/monitor/_claude-bin.sh"
LOADER="$_repo_root/config/load.sh"

PASS=0
FAIL=0
SKIP=0
ok()   { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
skip() { printf '  SKIP: %s — %s\n' "$1" "$2"; SKIP=$(( SKIP + 1 )); }

[[ -f "$RESOLVER" ]] || { echo "missing resolver: $RESOLVER" >&2; exit 1; }

# A PATH with NO claude on it, so rank 4 is empty unless a case adds one.
# /usr/bin + /bin only: the resolver needs `command -v` and nothing else.
BARE_PATH=/usr/bin:/bin

# make_root <dir> <with_node_modules 0|1>
# Minimal stand-in nexus: the real resolver, plus optionally an npm-shaped
# node_modules/.bin/claude stub that identifies itself when run.
make_root() {
    local root="$1" with_nm="${2:-1}"
    mkdir -p "$root/monitor"
    cp "$RESOLVER" "$root/monitor/_claude-bin.sh"
    if [[ "$with_nm" == 1 ]]; then
        mkdir -p "$root/node_modules/.bin"
        printf '#!/bin/sh\necho npm-claude\n' > "$root/node_modules/.bin/claude"
        chmod +x "$root/node_modules/.bin/claude"
    fi
}

# add_config <root> <value>
# Give the stand-in root a working config/load.sh + a nexus.yml carrying
# `nexus.claude_bin: <value>`. An EMPTY value writes no key at all.
add_config() {
    local root="$1" value="$2"
    mkdir -p "$root/config"
    cp "$LOADER" "$root/config/load.sh"
    chmod +x "$root/config/load.sh"
    : > "$root/config/nexus.example.yml"
    if [[ -n "$value" ]]; then
        printf 'nexus:\n  claude_bin: %s\n' "$value" > "$root/config/nexus.yml"
    else
        printf 'nexus:\n  root: %s\n' "$root" > "$root/config/nexus.yml"
    fi
}

# stub_bin <path> <marker> — an executable that prints <marker>.
stub_bin() {
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\necho %s\n' "$2" > "$1"
    chmod +x "$1"
}

# resolve <root> [extra env assignments...]
# Source the resolver exactly as a spawn surface does and print the
# resolved path. Exit status is the resolver's, so a case can assert 1 vs 2.
resolve() {
    local root="$1"; shift
    env -u CLAUDE_BIN -u BASH_ENV PATH="$BARE_PATH" NEXUS_ROOT="$root" "$@" \
        bash -c '. "$NEXUS_ROOT/monitor/_claude-bin.sh"; printf "%s" "$CLAUDE_BIN"'
}

# Does the repo's own loader work on this host? The rank-2 cases need
# python3 + pyyaml; without them the resolver is DESIGNED to fall through,
# which the "loader unavailable" case below asserts instead.
loader_works=0
if [[ -x "$LOADER" ]]; then
    _probe=$(mktemp -d); add_config "$_probe" /bin/true
    if env -u BASH_ENV PATH="$BARE_PATH" NEXUS_ROOT="$_probe" \
            "$_probe/config/load.sh" nexus.claude_bin "" >/dev/null 2>&1; then
        loader_works=1
    fi
    rm -rf "$_probe"
fi

echo "=== rank 3: node_modules used when nothing outranks it ==="
sb=$(mktemp -d); make_root "$sb" 1
got=$(resolve "$sb"); rc=$?
if (( rc == 0 )) && [[ "$got" == "$sb/node_modules/.bin/claude" ]]; then
    ok "resolves to the npm install (rc=0)"
else
    bad "rank 3" "rc=$rc got=$got"
fi
rm -rf "$sb"

echo "=== rank 1: CLAUDE_BIN env beats node_modules ==="
sb=$(mktemp -d); make_root "$sb" 1
stub_bin "$sb/elsewhere/claude" env-claude
got=$(resolve "$sb" CLAUDE_BIN="$sb/elsewhere/claude"); rc=$?
if (( rc == 0 )) && [[ "$got" == "$sb/elsewhere/claude" ]]; then
    ok "env override wins over the npm install"
else
    bad "rank 1" "rc=$rc got=$got"
fi
rm -rf "$sb"

echo "=== rank 4: PATH fallback when no npm install ==="
sb=$(mktemp -d); make_root "$sb" 0
stub_bin "$sb/pathdir/claude" path-claude
got=$(env -u CLAUDE_BIN -u BASH_ENV PATH="$sb/pathdir:$BARE_PATH" NEXUS_ROOT="$sb" \
        bash -c '. "$NEXUS_ROOT/monitor/_claude-bin.sh"; printf "%s" "$CLAUDE_BIN"'); rc=$?
if (( rc == 0 )) && [[ "$got" == "$sb/pathdir/claude" ]]; then
    ok "falls back to claude on PATH"
else
    bad "rank 4" "rc=$rc got=$got"
fi
rm -rf "$sb"

echo "=== exit 1: nothing resolvable anywhere ==="
sb=$(mktemp -d); make_root "$sb" 0
got=$(resolve "$sb" 2>/dev/null); rc=$?
if (( rc == 1 )) && [[ -z "$got" ]]; then
    ok "exits 1 (recoverable: the bootstrap answers this by installing)"
else
    bad "exit 1" "rc=$rc got=$got"
fi
rm -rf "$sb"

echo "=== rank 2: config nexus.claude_bin OUTRANKS node_modules ==="
if (( loader_works )); then
    sb=$(mktemp -d); make_root "$sb" 1          # npm install PRESENT
    stub_bin "$sb/native/claude" native-claude
    add_config "$sb" "$sb/native/claude"
    got=$(resolve "$sb"); rc=$?
    if (( rc == 0 )) && [[ "$got" == "$sb/native/claude" ]]; then
        ok "config pin wins even with node_modules present"
    else
        bad "rank 2 precedence" "rc=$rc got=$got (npm stub was at $sb/node_modules/.bin/claude)"
    fi
    # And the resolved binary is really the native one, not the npm stub.
    if [[ "$("$got" 2>/dev/null)" == "native-claude" ]]; then
        ok "resolved path executes the native stub, not the npm one"
    else
        bad "rank 2 identity" "executing $got did not print native-claude"
    fi
    rm -rf "$sb"

    echo "=== rank 1 still beats rank 2 ==="
    sb=$(mktemp -d); make_root "$sb" 1
    stub_bin "$sb/native/claude" native-claude
    stub_bin "$sb/elsewhere/claude" env-claude
    add_config "$sb" "$sb/native/claude"
    got=$(resolve "$sb" CLAUDE_BIN="$sb/elsewhere/claude"); rc=$?
    if (( rc == 0 )) && [[ "$got" == "$sb/elsewhere/claude" ]]; then
        ok "env override still outranks the config pin"
    else
        bad "rank 1 over rank 2" "rc=$rc got=$got"
    fi
    rm -rf "$sb"

    echo "=== exit 2: pin set but NOT executable — refuses, no fall-through ==="
    sb=$(mktemp -d); make_root "$sb" 1          # npm install PRESENT
    add_config "$sb" "$sb/does/not/exist"
    err=$(resolve "$sb" 2>&1 >/dev/null); rc=$?
    got=$(resolve "$sb" 2>/dev/null)
    if (( rc == 2 )); then
        ok "exits 2 on a broken pin (distinct from the exit-1 nothing-found case)"
    else
        bad "exit 2 code" "rc=$rc"
    fi
    if [[ "$got" != *"node_modules"* ]]; then
        ok "does NOT fall through to node_modules on a broken pin"
    else
        bad "exit 2 fall-through" "resolved $got — the npm tree silently took over"
    fi
    if [[ "$err" == *"nexus.claude_bin"* ]]; then
        ok "names nexus.claude_bin in the error"
    else
        bad "exit 2 message" "stderr did not name the key: $err"
    fi
    rm -rf "$sb"

    echo "=== empty/absent pin is inert (npm install still used) ==="
    sb=$(mktemp -d); make_root "$sb" 1
    add_config "$sb" ""                          # config present, key absent
    got=$(resolve "$sb"); rc=$?
    if (( rc == 0 )) && [[ "$got" == "$sb/node_modules/.bin/claude" ]]; then
        ok "an absent key changes nothing — npm install still resolves"
    else
        bad "inert pin" "rc=$rc got=$got"
    fi
    rm -rf "$sb"
else
    skip "rank-2 config cases" "config/load.sh cannot run here (needs python3 + pyyaml)"
fi

echo "=== loader unavailable: degrades to the pre-change behaviour ==="
# No config/load.sh in the tree at all — the rank-2 lookup is SOFT, so the
# resolver must carry on to rank 3 rather than dying. This is the fresh-
# clone / no-pyyaml host path.
sb=$(mktemp -d); make_root "$sb" 1               # no config/ dir written
got=$(resolve "$sb"); rc=$?
if (( rc == 0 )) && [[ "$got" == "$sb/node_modules/.bin/claude" ]]; then
    ok "missing loader is soft — resolution continues to node_modules"
else
    bad "soft loader" "rc=$rc got=$got"
fi
rm -rf "$sb"

echo "=== CLAUDE_BIN_NO_PATH suppresses the PATH lookup ==="
# The flag exists for monitor/link-nexus-tools.sh, which WRITES
# locals/bin/claude while locals/bin leads PATH. Without suppression the
# resolver would hand it the link it is about to rewrite — a self-link.
sb=$(mktemp -d); make_root "$sb" 0
stub_bin "$sb/pathdir/claude" path-claude
got=$(env -u CLAUDE_BIN -u BASH_ENV PATH="$sb/pathdir:$BARE_PATH" NEXUS_ROOT="$sb" \
        CLAUDE_BIN_NO_PATH=1 \
        bash -c '. "$NEXUS_ROOT/monitor/_claude-bin.sh"; printf "%s" "$CLAUDE_BIN"' 2>/dev/null); rc=$?
if (( rc == 1 )) && [[ -z "$got" ]]; then
    ok "PATH lookup suppressed — resolver reports nothing found"
else
    bad "CLAUDE_BIN_NO_PATH" "rc=$rc got=$got (PATH claude leaked through)"
fi
# It must suppress ONLY rank 4: ranks 1-3 still resolve under the flag.
sb2=$(mktemp -d); make_root "$sb2" 1
got=$(env -u CLAUDE_BIN -u BASH_ENV PATH="$BARE_PATH" NEXUS_ROOT="$sb2" \
        CLAUDE_BIN_NO_PATH=1 \
        bash -c '. "$NEXUS_ROOT/monitor/_claude-bin.sh"; printf "%s" "$CLAUDE_BIN"'); rc=$?
if (( rc == 0 )) && [[ "$got" == "$sb2/node_modules/.bin/claude" ]]; then
    ok "the flag suppresses rank 4 only — node_modules still resolves"
else
    bad "CLAUDE_BIN_NO_PATH scope" "rc=$rc got=$got"
fi
rm -rf "$sb" "$sb2"

echo "=== NEXUS_ROOT unset is still a hard error ==="
if out=$(env -u CLAUDE_BIN -u NEXUS_ROOT -u BASH_ENV PATH="$BARE_PATH" \
            bash -c ". '$RESOLVER'" 2>&1); then
    bad "NEXUS_ROOT guard" "resolver returned 0 with NEXUS_ROOT unset"
else
    if [[ "$out" == *"NEXUS_ROOT"* ]]; then
        ok "refuses loudly when NEXUS_ROOT is unset"
    else
        bad "NEXUS_ROOT guard" "wrong message: $out"
    fi
fi

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d passed, %d skipped)\n' "$PASS" "$SKIP"
    exit 0
else
    printf '%d PASSED, %d FAILED, %d SKIPPED\n' "$PASS" "$FAIL" "$SKIP" >&2
    exit 1
fi
