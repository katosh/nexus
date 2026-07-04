#!/usr/bin/env bash
# Tests for monitor/install-shell-hook.sh — the idempotent PATH-only rc
# drop-in that makes the nexus toolchain resolve BY NAME in MANUALLY-spawned
# tmux windows / new shells. Part of your-org/nexus-code#307 item 3.
#
# Run: bash monitor/watcher/test-install-shell-hook.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Fully hermetic — every
# fixture uses a mktemp -d sandbox for both HOME and NEXUS_ROOT; the real
# user's rc files are NEVER touched.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HOOK="$_repo_root/monitor/install-shell-hook.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -x "$HOOK" ]] || { echo "missing/non-exec hook: $HOOK" >&2; exit 1; }

BEGIN='# >>> nexus locals/bin (managed by monitor/install-shell-hook.sh) >>>'

# A fake nexus root that carries the REAL locals-env.sh (the block sources
# it) plus a fake locals/bin/claude so we can prove `claude` resolves.
make_fake_nexus() {
    local root="$1"
    mkdir -p "$root/monitor" "$root/locals/bin"
    cp "$_repo_root/monitor/locals-env.sh" "$root/monitor/locals-env.sh"
    printf '#!/bin/sh\necho local-claude\n' > "$root/locals/bin/claude"
    chmod +x "$root/locals/bin/claude"
}

run_hook() { HOME="$1" NEXUS_ROOT="$2" "$HOOK" "${@:3}" >/dev/null 2>&1; }

echo "=== installs a marked block into .bashrc + .zshrc ==="
home=$(mktemp -d); nx=$(mktemp -d); make_fake_nexus "$nx"
printf 'export EXISTING=1\n' > "$home/.bashrc"   # pre-existing content
run_hook "$home" "$nx"
got_bashrc=0; got_zshrc=0; kept_existing=0
grep -qF "$BEGIN" "$home/.bashrc" 2>/dev/null && got_bashrc=1
grep -qF "$BEGIN" "$home/.zshrc"  2>/dev/null && got_zshrc=1
grep -qF "export EXISTING=1" "$home/.bashrc" 2>/dev/null && kept_existing=1
[[ $got_bashrc == 1 ]] && ok "block added to .bashrc" || bad ".bashrc" "no block"
[[ $got_zshrc  == 1 ]] && ok "block added to .zshrc (created if absent)" || bad ".zshrc" "no block"
[[ $kept_existing == 1 ]] && ok "pre-existing rc content preserved" || bad "preserve" "existing line lost"
rm -rf "$home" "$nx"

echo "=== END-TO-END: a fresh shell sourcing rc resolves claude -> locals/bin ==="
# THE core item-3 guarantee: simulate a manually-opened window. Start a
# clean shell whose PATH lacks locals/bin, source the rc the hook wrote,
# then `command -v claude` must point into the nexus locals/bin.
home=$(mktemp -d); nx=$(mktemp -d); make_fake_nexus "$nx"
run_hook "$home" "$nx"
resolved=$(
    env -i HOME="$home" PATH="/usr/bin:/bin" bash --noprofile -c '
        . "$HOME/.bashrc" >/dev/null 2>&1
        command -v claude
    ' 2>/dev/null
)
if [[ "$resolved" == "$nx/locals/bin/claude" ]]; then
    ok "manual-window shell resolves \`claude\` to the nexus locals/bin install"
else
    bad "manual-window resolve" "claude resolved to: ${resolved:-<none>} (want $nx/locals/bin/claude)"
fi

echo "=== PATH-only: the hook does NOT redirect the user's uv state ==="
uvstate=$(
    env -i HOME="$home" PATH="/usr/bin:/bin" bash --noprofile -c '
        . "$HOME/.bashrc" >/dev/null 2>&1
        printf "UV_CACHE_DIR=%s\n" "${UV_CACHE_DIR:-<unset>}"
        printf "UV_PYTHON_INSTALL_DIR=%s\n" "${UV_PYTHON_INSTALL_DIR:-<unset>}"
    ' 2>/dev/null
)
if grep -qx 'UV_CACHE_DIR=<unset>' <<<"$uvstate" \
   && grep -qx 'UV_PYTHON_INSTALL_DIR=<unset>' <<<"$uvstate"; then
    ok "UV_* NOT exported (global shell's uv state left alone)"
else
    bad "PATH-only" "uv state was hijacked: $uvstate"
fi
rm -rf "$home" "$nx"

echo "=== zsh: the block is valid + PATH-only under zsh too ==="
# The hook writes ~/.zshrc; zsh's prefix-assignment + `.` semantics differ
# from bash, so prove the block actually resolves claude AND keeps UV_*
# unset when sourced by a real zsh. Self-skips when zsh is absent.
if command -v zsh >/dev/null 2>&1; then
    home=$(mktemp -d); nx=$(mktemp -d); make_fake_nexus "$nx"
    run_hook "$home" "$nx" --target "$home/.zshrc"
    zout=$(
        env -i HOME="$home" PATH="/usr/bin:/bin" zsh -f -c '
            source "$HOME/.zshrc" >/dev/null 2>&1
            printf "claude=%s\n" "$(command -v claude)"
            printf "UV_CACHE_DIR=%s\n" "${UV_CACHE_DIR:-<unset>}"
        ' 2>/dev/null
    )
    if grep -qx "claude=$nx/locals/bin/claude" <<<"$zout" \
       && grep -qx 'UV_CACHE_DIR=<unset>' <<<"$zout"; then
        ok "zsh resolves claude -> locals/bin AND leaves UV_* unset"
    else
        bad "zsh end-to-end" "got: $zout"
    fi
    rm -rf "$home" "$nx"
else
    ok "zsh end-to-end (skipped: no zsh on host)"
fi

echo "=== idempotent: re-run does not duplicate the block ==="
home=$(mktemp -d); nx=$(mktemp -d); make_fake_nexus "$nx"
run_hook "$home" "$nx"; run_hook "$home" "$nx"; run_hook "$home" "$nx"
count=$(grep -cF "$BEGIN" "$home/.bashrc")
[[ "$count" == "1" ]] && ok "triple-install yields exactly one block" \
    || bad "idempotency" "block appears $count times"
rm -rf "$home" "$nx"

echo "=== moved nexus root: re-install replaces the stale path ==="
home=$(mktemp -d); nxA=$(mktemp -d); nxB=$(mktemp -d)
make_fake_nexus "$nxA"; make_fake_nexus "$nxB"
run_hook "$home" "$nxA"
run_hook "$home" "$nxB"   # operator moved the nexus / fresh clone elsewhere
if grep -qF "$nxB/monitor/locals-env.sh" "$home/.bashrc" \
   && ! grep -qF "$nxA/monitor/locals-env.sh" "$home/.bashrc"; then
    ok "re-install rewrites the block to the new nexus root (no stale dup)"
else
    bad "moved-root" "stale path not replaced"
fi
rm -rf "$home" "$nxA" "$nxB"

echo "=== --uninstall removes the block, leaves other content intact ==="
home=$(mktemp -d); nx=$(mktemp -d); make_fake_nexus "$nx"
printf 'export KEEP_ME=1\n' > "$home/.bashrc"
run_hook "$home" "$nx"
run_hook "$home" "$nx" --uninstall
if ! grep -qF "$BEGIN" "$home/.bashrc" && grep -qF "export KEEP_ME=1" "$home/.bashrc"; then
    ok "--uninstall strips the block, preserves the rest"
else
    bad "uninstall" "block remained or other content lost"
fi
rm -rf "$home" "$nx"

echo "=== read-only HOME: never fails, prints manual block ==="
home=$(mktemp -d); nx=$(mktemp -d); make_fake_nexus "$nx"
printf 'orig\n' > "$home/.bashrc"
chmod 0444 "$home/.bashrc"            # rc not writable
chmod 0555 "$home"                    # dir not writable (can't create .zshrc)
out=$(HOME="$home" NEXUS_ROOT="$nx" "$HOOK" 2>&1); rc=$?
chmod 0755 "$home"; chmod 0644 "$home/.bashrc"   # restore for cleanup
if [[ $rc -eq 0 ]] && grep -qF "$BEGIN" <<<"$out"; then
    ok "read-only HOME: exit 0 + manual block printed (bootstrap-safe)"
else
    bad "read-only" "rc=$rc, did not print fallback block"
fi
# And the unwritable rc was genuinely left untouched.
if [[ "$(cat "$home/.bashrc")" == "orig" ]]; then
    ok "unwritable rc left byte-for-byte untouched"
else
    bad "read-only-untouched" "rc was modified despite being read-only"
fi
rm -rf "$home" "$nx"

echo "=== --print emits the block, changes nothing ==="
home=$(mktemp -d); nx=$(mktemp -d); make_fake_nexus "$nx"
out=$(HOME="$home" NEXUS_ROOT="$nx" "$HOOK" --print 2>/dev/null)
if grep -qF "$BEGIN" <<<"$out" && [[ ! -e "$home/.bashrc" ]]; then
    ok "--print outputs block without writing any rc"
else
    bad "print" "wrote rc or omitted block"
fi
rm -rf "$home" "$nx"

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
