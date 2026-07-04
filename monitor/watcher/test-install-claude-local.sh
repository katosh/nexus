#!/usr/bin/env bash
# Tests for monitor/install-claude-local.sh — the project-local Claude
# Code installer the launcher runs when node_modules/.bin/claude is
# absent.
#
# THE INVARIANT under test: a pin bump (or any install run) must NEVER
# end with the script reporting success while the tree lacks a working,
# correctly-versioned binary. Two consecutive real auto-updates
# (2.1.158 via `npm ci` wiping node_modules, 2.1.159 via an NFS EBUSY
# unlink) each left the binary missing yet the operator only learned via
# downstream breakage. These tests pin the hardened behavior:
#   - default installer is `npm install` (never `npm ci`), so a failed
#     install leaves the prior binary standing;
#   - a failed install exits NON-ZERO (no false success);
#   - success but missing/mismatched binary still exits NON-ZERO;
#   - a transient EBUSY/.nfs failure is retried once and can recover;
#   - stale @anthropic-ai/.claude-code-* staging dirs are pre-cleaned;
#   - the idempotency fast-path exits 0 without invoking npm.
#
# Fully hermetic: node + npm are PATH-shadow stubs, so the suite needs
# no network and no real Claude Code package.
#
# Run: bash monitor/watcher/test-install-claude-local.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
INSTALLER_SRC="$_repo_root/monitor/install-claude-local.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -f "$INSTALLER_SRC" ]] || { echo "missing: $INSTALLER_SRC" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PIN="9.9.9"

# ---------------------------------------------------------------------
# Fixture: build a fake nexus tree at $WORK/nexus with a copy of the
# real installer, a package.json pinning $PIN, and a PATH-shadow bin/
# holding `node` + `npm` stubs whose behavior is driven by env knobs.
# Returns with $NEXUS / $STUB_BIN / $NPM_LOG / $NPM_COUNTER set.
# ---------------------------------------------------------------------
new_fixture() {
    NEXUS="$WORK/nexus.$RANDOM$RANDOM"
    STUB_BIN="$NEXUS/.stubbin"
    NPM_LOG="$NEXUS/.npm-argv.log"
    NPM_COUNTER="$NEXUS/.npm-counter"
    mkdir -p "$NEXUS/monitor" "$STUB_BIN"

    cp "$INSTALLER_SRC" "$NEXUS/monitor/install-claude-local.sh"
    chmod +x "$NEXUS/monitor/install-claude-local.sh"
    # The installer sources three sibling libs — stage all alongside: the
    # effective-version resolver (floor-plus-local-pin, #226), the shared
    # node-bootstrap lib (B12), and the move-aside-before-install helper
    # (#310/#312).
    cp "$(dirname "$INSTALLER_SRC")/_cc-version.sh" "$NEXUS/monitor/_cc-version.sh"
    cp "$(dirname "$INSTALLER_SRC")/_node-bootstrap.sh" "$NEXUS/monitor/_node-bootstrap.sh"
    cp "$(dirname "$INSTALLER_SRC")/_trash.sh" "$NEXUS/monitor/_trash.sh"

    cat > "$NEXUS/package.json" <<EOF
{
  "dependencies": {
    "@anthropic-ai/claude-code": "$PIN"
  }
}
EOF

    # node stub: always reports a modern version; other calls no-op.
    cat > "$STUB_BIN/node" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "v20.11.0" ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$STUB_BIN/node"

    # npm stub: `npm --version` answers cheaply; `npm install` / `npm ci`
    # records argv then acts per $NPM_STUB_MODE.
    cat > "$STUB_BIN/npm" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "11.0.0"; exit 0
fi

printf '%s\n' "$*" >> "$NPM_STUB_LOG"

count=1
if [[ -n "${NPM_STUB_COUNTER:-}" ]]; then
    count=$(( $(cat "$NPM_STUB_COUNTER" 2>/dev/null || echo 0) + 1 ))
    echo "$count" > "$NPM_STUB_COUNTER"
fi

make_binary() {  # $1 = version; faithful npm layout: pkg cli.js + RELATIVE symlink
    mkdir -p "$PWD/node_modules/.bin" "$PWD/node_modules/@anthropic-ai/claude-code"
    cat > "$PWD/node_modules/@anthropic-ai/claude-code/cli.js" <<INNER
#!/usr/bin/env bash
echo "$1 (Claude Code)"
INNER
    chmod +x "$PWD/node_modules/@anthropic-ai/claude-code/cli.js"
    # npm links .bin/claude as a RELATIVE symlink into the package dir —
    # reproduce that so the restore-on-failure path is tested faithfully
    # (a relative symlink dangles once moved into the trash dir).
    ln -sf ../@anthropic-ai/claude-code/cli.js "$PWD/node_modules/.bin/claude"
}

case "${NPM_STUB_MODE:-success}" in
    success)
        make_binary "${NPM_STUB_VERSION:?}"; exit 0 ;;
    fail-no-binary)
        echo "npm error generic install failure" >&2; exit 1 ;;
    success-no-binary)
        # Reports success but never produces the binary — the exact
        # false-success the verification step must catch.
        exit 0 ;;
    wrong-version)
        make_binary "${NPM_STUB_WRONG:?}"; exit 0 ;;
    ebusy-then-success)
        if (( count == 1 )); then
            echo "npm error code EBUSY" >&2
            echo "npm error EBUSY: resource busy or locked, unlink '$PWD/node_modules/@anthropic-ai/.claude-code-abc/bin/.nfs0000000000abcdef'" >&2
            exit 1
        fi
        make_binary "${NPM_STUB_VERSION:?}"; exit 0 ;;
    ci-wipes-then-fail)
        # Emulate `npm ci`: wipe node_modules first, then fail — the
        # 2.1.158 no-binary regression.
        rm -rf "$PWD/node_modules"
        echo "npm error ci reinstall failed" >&2; exit 1 ;;
    *)
        echo "npm stub: unknown NPM_STUB_MODE=${NPM_STUB_MODE:-}" >&2; exit 99 ;;
esac
EOF
    chmod +x "$STUB_BIN/npm"
}

# Run the installer in the fixture with the stub bin shadowing PATH.
# All NPM_STUB_* knobs pass through the environment.
run_installer() {
    env PATH="$STUB_BIN:$PATH" \
        NPM_STUB_LOG="$NPM_LOG" \
        NPM_STUB_COUNTER="$NPM_COUNTER" \
        "$@" \
        bash "$NEXUS/monitor/install-claude-local.sh"
}

seed_existing_binary() {  # $1 = version the pre-existing binary reports
    # Faithful npm layout: the executable lives in the package dir and
    # .bin/claude is a RELATIVE symlink into it (matches the live clone:
    # .bin/claude -> ../@anthropic-ai/claude-code/...). This is what makes
    # the restore-on-failure path a real test — a relative symlink dangles
    # once trash_path moves it into monitor/.state/.trash/.
    mkdir -p "$NEXUS/node_modules/.bin" "$NEXUS/node_modules/@anthropic-ai/claude-code"
    cat > "$NEXUS/node_modules/@anthropic-ai/claude-code/cli.js" <<EOF
#!/usr/bin/env bash
echo "$1 (Claude Code)"
EOF
    chmod +x "$NEXUS/node_modules/@anthropic-ai/claude-code/cli.js"
    ln -sf ../@anthropic-ai/claude-code/cli.js "$NEXUS/node_modules/.bin/claude"
}

binary_version() {
    [[ -x "$NEXUS/node_modules/.bin/claude" ]] || { echo "<none>"; return; }
    "$NEXUS/node_modules/.bin/claude" --version 2>/dev/null | awk '{print $1}'
}

echo "=== happy path ==="

# (1) npm install succeeds, binary matches pin → exit 0, binary present.
new_fixture
out=$(run_installer NPM_STUB_MODE=success NPM_STUB_VERSION="$PIN" 2>&1)
rc=$?
if (( rc == 0 )) && [[ "$(binary_version)" == "$PIN" ]]; then
    ok "success install → exit 0 with pinned binary"
else
    bad "success install" "rc=$rc binary=$(binary_version) out=$out"
fi

# (2) Default installer is `npm install`, never `npm ci`, even with a
# package-lock.json present (the 2.1.158 footgun).
new_fixture
: > "$NEXUS/package-lock.json"
run_installer NPM_STUB_MODE=success NPM_STUB_VERSION="$PIN" >/dev/null 2>&1
logged=$(cat "$NPM_LOG" 2>/dev/null)
if grep -q '^install' <<<"$logged" && ! grep -q '^ci' <<<"$logged"; then
    ok "default uses 'npm install' (not 'npm ci') with lockfile present"
else
    bad "default installer" "npm argv log: $logged"
fi

# (3) CLAUDE_INSTALL_USE_CI=1 opts into `npm ci` when a lockfile exists.
new_fixture
: > "$NEXUS/package-lock.json"
run_installer CLAUDE_INSTALL_USE_CI=1 NPM_STUB_MODE=success \
    NPM_STUB_VERSION="$PIN" >/dev/null 2>&1
logged=$(cat "$NPM_LOG" 2>/dev/null)
if grep -q '^ci' <<<"$logged"; then
    ok "CLAUDE_INSTALL_USE_CI=1 → opts into 'npm ci'"
else
    bad "ci opt-in" "npm argv log: $logged"
fi

echo
echo "=== floor vs operator-local pin (#226) ==="

# Write the operator-local pin into the fixture's state dir.
seed_local_pin() {  # $1 = version to pin locally
    mkdir -p "$NEXUS/monitor/.state"
    printf '%s\n' "$1" > "$NEXUS/monitor/.state/cc-version-local"
}
LOCALPIN="9.9.10"   # ahead of the floor PIN=9.9.9

# (F1) No local pin → installs the FLOOR via bare `npm install`, and the
# success line reports source=floor.
new_fixture
out=$(run_installer NPM_STUB_MODE=success NPM_STUB_VERSION="$PIN" 2>&1)
rc=$?
logged=$(cat "$NPM_LOG" 2>/dev/null)
if (( rc == 0 )) && [[ "$(binary_version)" == "$PIN" ]] \
   && grep -q 'source=floor' <<<"$out" \
   && ! grep -q -- '--no-save' <<<"$logged"; then
    ok "no local pin → installs floor via bare 'npm install' (source=floor)"
else
    bad "floor path" "rc=$rc binary=$(binary_version) out=$out | npm: $logged"
fi

# (F2) Local pin present (ahead of floor) → installs that EXACT version
# with 'npm install --no-save <pkg>@<localpin>', NEVER the floor, and the
# success line reports source=local-pin.
new_fixture
seed_local_pin "$LOCALPIN"
out=$(run_installer NPM_STUB_MODE=success NPM_STUB_VERSION="$LOCALPIN" 2>&1)
rc=$?
logged=$(cat "$NPM_LOG" 2>/dev/null)
if (( rc == 0 )) && [[ "$(binary_version)" == "$LOCALPIN" ]] \
   && grep -q -- '--no-save' <<<"$logged" \
   && grep -q "@anthropic-ai/claude-code@$LOCALPIN" <<<"$logged" \
   && grep -q 'source=local-pin' <<<"$out"; then
    ok "local pin → 'npm install --no-save pkg@<localpin>', floor untouched"
else
    bad "local-pin install" "rc=$rc binary=$(binary_version) out=$out | npm: $logged"
fi

# (F3) Local pin present + shared package.json (the floor) is NEVER
# rewritten — the whole point of --no-save. The stub never touches
# package.json, so assert it still pins the floor verbatim.
if grep -q "\"@anthropic-ai/claude-code\": \"$PIN\"" "$NEXUS/package.json"; then
    ok "local-pin install leaves shared package.json floor ($PIN) intact"
else
    bad "floor untouched" "package.json: $(cat "$NEXUS/package.json")"
fi

# (F4) Idempotency under a local pin: binary already at the local pin →
# fast-path exit 0, NO npm call at all.
new_fixture
seed_local_pin "$LOCALPIN"
seed_existing_binary "$LOCALPIN"
out=$(run_installer NPM_STUB_MODE=success NPM_STUB_VERSION="$LOCALPIN" 2>&1)
rc=$?
calls=$(grep -c '^install' "$NPM_LOG" 2>/dev/null || echo 0)
if (( rc == 0 )) && (( calls == 0 )) && grep -q 'already at' <<<"$out"; then
    ok "local pin + matching binary → idempotent fast-path, no npm call"
else
    bad "local-pin idempotency" "rc=$rc npm_calls=$calls out=$out"
fi

# (F5) Local pin present but the install yields the WRONG version →
# fail-loud mismatch citing the effective (local-pin) source.
new_fixture
seed_local_pin "$LOCALPIN"
out=$(run_installer NPM_STUB_MODE=wrong-version NPM_STUB_WRONG="1.2.3" 2>&1)
rc=$?
if (( rc != 0 )) && grep -qi 'version mismatch' <<<"$out" \
   && grep -q 'source=local-pin' <<<"$out"; then
    ok "local pin + wrong installed version → fail-loud mismatch (source=local-pin)"
else
    bad "local-pin mismatch guard" "rc=$rc out=$out"
fi

echo
echo "=== the invariant: never a false success ==="

# (4) Install fails outright, no binary → exit NON-ZERO (the core
# regression: must not report success with no binary).
new_fixture
out=$(run_installer NPM_STUB_MODE=fail-no-binary 2>&1)
rc=$?
if (( rc != 0 )) && [[ "$(binary_version)" == "<none>" ]]; then
    ok "failed install, no binary → exit non-zero"
else
    bad "failed install exit code" "rc=$rc binary=$(binary_version) out=$out"
fi

# (5) `npm install` exits 0 but produced NO binary → verification must
# still fail loud (non-zero), not exit 0.
new_fixture
out=$(run_installer NPM_STUB_MODE=success-no-binary 2>&1)
rc=$?
if (( rc != 0 )) && grep -qi 'missing or not executable' <<<"$out"; then
    ok "npm exit 0 but no binary → fail-loud non-zero"
else
    bad "false-success missing binary" "rc=$rc out=$out"
fi

# (6) Binary present but reports the WRONG version → non-zero mismatch.
new_fixture
out=$(run_installer NPM_STUB_MODE=wrong-version NPM_STUB_WRONG="1.2.3" 2>&1)
rc=$?
if (( rc != 0 )) && grep -qi 'version mismatch' <<<"$out"; then
    ok "binary version != pin → exit non-zero (mismatch)"
else
    bad "version mismatch guard" "rc=$rc out=$out"
fi

# (7) A failed `npm ci` that wiped node_modules → non-zero, no false
# success. (Opt-in path; this is exactly why ci is not the default.)
new_fixture
: > "$NEXUS/package-lock.json"
out=$(run_installer CLAUDE_INSTALL_USE_CI=1 NPM_STUB_MODE=ci-wipes-then-fail 2>&1)
rc=$?
if (( rc != 0 )) && [[ "$(binary_version)" == "<none>" ]]; then
    ok "npm ci wipes then fails → exit non-zero (no false success)"
else
    bad "ci-wipe failure" "rc=$rc binary=$(binary_version) out=$out"
fi

# (8) A prior good binary survives a failed `npm install` (install does
# not wipe node_modules). Proves the 'prefer npm install' safety net.
new_fixture
seed_existing_binary "8.0.0"   # stale version, forces a real install run
out=$(run_installer NPM_STUB_MODE=fail-no-binary 2>&1)
rc=$?
if (( rc != 0 )) && [[ "$(binary_version)" == "8.0.0" ]]; then
    ok "failed npm install leaves the prior binary in place"
else
    bad "prior binary survival" "rc=$rc binary=$(binary_version) out=$out"
fi

echo
echo "=== transient EBUSY/.nfs retry ==="

# (9) First attempt fails with EBUSY/.nfs, retry succeeds → exit 0 and
# the binary lands. npm called exactly twice.
new_fixture
out=$(run_installer NPM_STUB_MODE=ebusy-then-success NPM_STUB_VERSION="$PIN" 2>&1)
rc=$?
calls=$(grep -c '^install' "$NPM_LOG" 2>/dev/null || echo 0)
if (( rc == 0 )) && [[ "$(binary_version)" == "$PIN" ]] && (( calls == 2 )); then
    ok "EBUSY then success → retried once, exit 0, binary present"
else
    bad "ebusy retry" "rc=$rc binary=$(binary_version) npm_calls=$calls out=$out"
fi

# (10) A NON-EBUSY failure is NOT retried (single npm call, fail fast).
new_fixture
run_installer NPM_STUB_MODE=fail-no-binary >/dev/null 2>&1
calls=$(grep -c '^install' "$NPM_LOG" 2>/dev/null || echo 0)
if (( calls == 1 )); then
    ok "non-EBUSY failure → no retry (single npm call)"
else
    bad "no-retry on generic failure" "npm_calls=$calls"
fi

echo
echo "=== pre-clean + idempotency ==="

# (11) Stale @anthropic-ai/.claude-code-* staging dir is removed before
# install.
new_fixture
mkdir -p "$NEXUS/node_modules/@anthropic-ai/.claude-code-deadbeef"
echo x > "$NEXUS/node_modules/@anthropic-ai/.claude-code-deadbeef/junk"
run_installer NPM_STUB_MODE=success NPM_STUB_VERSION="$PIN" >/dev/null 2>&1
if [[ ! -e "$NEXUS/node_modules/@anthropic-ai/.claude-code-deadbeef" ]]; then
    ok "stale .claude-code-* staging dir pre-cleaned"
else
    bad "pre-clean staging" "stale dir still present"
fi

# (12) Idempotency fast-path: binary already at pin → exit 0 WITHOUT
# invoking npm install/ci at all.
new_fixture
seed_existing_binary "$PIN"
out=$(run_installer NPM_STUB_MODE=fail-no-binary 2>&1)   # would fail if npm ran
rc=$?
ran_install=$(grep -cE '^(install|ci)' "$NPM_LOG" 2>/dev/null || echo 0)
if (( rc == 0 )) && (( ran_install == 0 )) && grep -qi "already at $PIN" <<<"$out"; then
    ok "already-at-pin → exit 0, npm install never invoked"
else
    bad "idempotency fast-path" "rc=$rc ran_install=$ran_install out=$out"
fi

echo
echo "=== Lmod / environment-module node bootstrap ==="
#
# On Lmod-based HPC node lives behind `module load nodejs`, not on the
# default PATH (your-org/other-nexus#41). The installer must bootstrap
# node from the module system before the npm install. These tests are
# fully hermetic and host-independent: each writes a fake module-init
# script (pointed to via NEXUS_MODULE_INIT) that defines a stand-in
# `module` function, and runs the installer under `env -i` — a clean
# environment with NO real `module` function, NO node on PATH, and no
# leakage of the host's real module system. On load, the fake `module`
# prepends a stub node+npm dir, so the real npm install runs against the
# stubs (no network, no real Claude Code package).

# A fake module-init script defining `module()` with the given body.
# $1 = path to write; remaining lines are read from stdin as the body.
write_fake_module_init() {  # $1 = init path, body on stdin
    local path="$1"
    { echo 'module() {'; cat; echo '}'; } > "$path"
}

# (13) Bare `module load nodejs` puts node on PATH → install proceeds.
new_fixture
MODNODE="$NEXUS/.modnode"; mkdir -p "$MODNODE"
cp "$STUB_BIN/node" "$MODNODE/node"; cp "$STUB_BIN/npm" "$MODNODE/npm"
INIT="$NEXUS/.fake-module-init.sh"
write_fake_module_init "$INIT" <<EOF
    if [[ "\${1:-}" == "load" && "\${2:-}" == nodejs* ]]; then
        export PATH="$MODNODE:\$PATH"
    fi
    return 0
EOF
out=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" \
    NEXUS_MODULE_INIT="$INIT" \
    NPM_STUB_LOG="$NPM_LOG" NPM_STUB_COUNTER="$NPM_COUNTER" \
    NPM_STUB_MODE=success NPM_STUB_VERSION="$PIN" \
    bash "$NEXUS/monitor/install-claude-local.sh" 2>&1)
rc=$?
if (( rc == 0 )) && [[ "$(binary_version)" == "$PIN" ]] \
    && grep -qi 'node provided by module nodejs' <<<"$out"; then
    ok "node off PATH + 'module load nodejs' → bootstrap installs pinned binary"
else
    bad "lmod bare-load bootstrap" "rc=$rc binary=$(binary_version) out=$out"
fi

# (14) No site default for `nodejs` (bare load is a no-op): the installer
# must DISCOVER the highest >=18 versioned module from `module -t avail`
# and load it explicitly.
new_fixture
MODNODE="$NEXUS/.modnode"; mkdir -p "$MODNODE"
cp "$STUB_BIN/node" "$MODNODE/node"; cp "$STUB_BIN/npm" "$MODNODE/npm"
INIT="$NEXUS/.fake-module-init.sh"
write_fake_module_init "$INIT" <<EOF
    if [[ "\${1:-}" == "-t" && "\${2:-}" == "avail" ]]; then
        # terse avail listing (script reads it via 2>&1); intentionally
        # unsorted + includes a <18 entry to prove the selector.
        printf '%s\\n' "/fake/modules:" "nodejs/16.20.0-x" \\
            "nodejs/20.13.1-x" "nodejs/18.20.0-x" >&2
        return 0
    fi
    if [[ "\${1:-}" == "load" && "\${2:-}" == "nodejs/20.13.1-x" ]]; then
        export PATH="$MODNODE:\$PATH"   # only the highest >=18 works
    fi
    return 0
EOF
out=$(env -i HOME="$HOME" PATH="/usr/bin:/bin" \
    NEXUS_MODULE_INIT="$INIT" \
    NPM_STUB_LOG="$NPM_LOG" NPM_STUB_COUNTER="$NPM_COUNTER" \
    NPM_STUB_MODE=success NPM_STUB_VERSION="$PIN" \
    bash "$NEXUS/monitor/install-claude-local.sh" 2>&1)
rc=$?
if (( rc == 0 )) && [[ "$(binary_version)" == "$PIN" ]] \
    && grep -qi 'loading discovered nodejs/20.13.1-x' <<<"$out"; then
    ok "no default → discovers highest >=18 (20.13.1 over 18.20.0/16.20.0)"
else
    bad "lmod discovery fallback" "rc=$rc binary=$(binary_version) out=$out"
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
