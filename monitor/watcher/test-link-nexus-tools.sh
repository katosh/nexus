#!/usr/bin/env bash
# Tests for monitor/link-nexus-tools.sh — the provisioner of stable
# locals/bin symlinks for the nexus toolchain (claude, ng, nexus, watcher).
# Part of your-org/nexus-code#307 item 4.
#
# Run: bash monitor/watcher/test-link-nexus-tools.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Fully hermetic (no network,
# no $HOME writes — every fixture lives under a mktemp -d sandbox that is a
# stand-in NEXUS_ROOT).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
LINKER="$_repo_root/monitor/link-nexus-tools.sh"
TRASH="$_repo_root/monitor/_trash.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -x "$LINKER" ]] || { echo "missing/non-exec linker: $LINKER" >&2; exit 1; }

# Build a minimal fake nexus tree under a sandbox: the in-repo tools the
# linker expects (monitor/ng, monitor/watcher/entry.sh) + an optional
# project-local claude install (node_modules/.bin/claude -> a relative
# package stub, mirroring npm's real layout).
make_fake_nexus() {
    local root="$1" with_claude="${2:-1}"
    mkdir -p "$root/monitor/watcher" "$root/node_modules/.bin" \
             "$root/node_modules/@anthropic-ai/claude-code/bin"
    printf '#!/bin/sh\necho ng-stub\n'    > "$root/monitor/ng"
    printf '#!/bin/sh\necho entry-stub\n' > "$root/monitor/watcher/entry.sh"
    chmod +x "$root/monitor/ng" "$root/monitor/watcher/entry.sh"
    if [[ "$with_claude" == 1 ]]; then
        printf '#!/bin/sh\necho claude-stub %s\n' "\"\$@\"" \
            > "$root/node_modules/@anthropic-ai/claude-code/bin/claude.js"
        chmod +x "$root/node_modules/@anthropic-ai/claude-code/bin/claude.js"
        # npm's .bin/claude is a RELATIVE symlink into the package.
        ln -s ../@anthropic-ai/claude-code/bin/claude.js "$root/node_modules/.bin/claude"
    fi
}

run_linker() { NEXUS_ROOT="$1" NEXUS_LOCALS="$1/locals" "$LINKER" --quiet >/dev/null 2>&1; }

echo "=== provisions relative symlinks resolving to the right targets ==="
sb=$(mktemp -d)
make_fake_nexus "$sb" 1
run_linker "$sb"

# claude link: exists, is a symlink, RELATIVE target, resolves + executes.
clink="$sb/locals/bin/claude"
if [[ -L "$clink" ]]; then
    tgt=$(readlink "$clink")
    if [[ "$tgt" == "../../node_modules/.bin/claude" ]]; then
        ok "claude is a RELATIVE symlink (../../node_modules/.bin/claude)"
    else
        bad "claude relative" "got target: $tgt"
    fi
else
    bad "claude link" "not a symlink at $clink"
fi
if [[ -x "$clink" ]] && out=$("$clink" hi 2>/dev/null) && [[ "$out" == "claude-stub hi" ]]; then
    ok "claude link resolves + executes the project-local install"
else
    bad "claude resolves" "exec via link failed (out=${out:-})"
fi

# ng + entrypoints linked too.
for n in ng nexus watcher; do
    if [[ -L "$sb/locals/bin/$n" && -x "$sb/locals/bin/$n" ]]; then
        ok "$n linked into locals/bin"
    else
        bad "$n link" "missing or not executable"
    fi
done
# nexus + watcher both point at entry.sh.
if [[ "$(readlink "$sb/locals/bin/nexus")" == "../../monitor/watcher/entry.sh" \
   && "$(readlink "$sb/locals/bin/watcher")" == "../../monitor/watcher/entry.sh" ]]; then
    ok "nexus + watcher both alias the entry.sh entrypoint"
else
    bad "entrypoint aliases" "unexpected targets"
fi
rm -rf "$sb"

echo "=== idempotent: re-run yields identical links, no dupes/errors ==="
sb=$(mktemp -d); make_fake_nexus "$sb" 1
run_linker "$sb"; before=$(readlink "$sb/locals/bin/claude")
if run_linker "$sb" && run_linker "$sb"; then
    after=$(readlink "$sb/locals/bin/claude")
    # locals/bin must hold exactly the 4 expected names, no .bin/claude nesting.
    n=$(find "$sb/locals/bin" -maxdepth 1 -type l | wc -l | tr -d ' ')
    if [[ "$before" == "$after" && "$n" == "4" ]]; then
        ok "triple-run is idempotent (4 links, target stable)"
    else
        bad "idempotency" "before=$before after=$after links=$n"
    fi
else
    bad "idempotency" "re-run returned non-zero"
fi
rm -rf "$sb"

echo "=== SURVIVES the trash-aside reinstall (#310/#312/#315) ==="
# Link once, then simulate install-claude-local's swap: trash the old
# node_modules/.bin/claude (locals link now dangles) and write a FRESH one
# at the same path (npm reinstall). The locals/bin/claude link must resolve
# again WITHOUT re-running the linker — proving the indirection survives.
sb=$(mktemp -d); make_fake_nexus "$sb" 1
run_linker "$sb"
clink="$sb/locals/bin/claude"
"$TRASH" trash "$sb/node_modules/.bin/claude" >/dev/null 2>&1   # rename aside
if [[ ! -e "$clink" ]]; then
    ok "during reinstall window the link dangles (target trashed)"
else
    bad "trash window" "link unexpectedly still resolves after trashing target"
fi
# npm writes a fresh .bin/claude (same relative target).
ln -s ../@anthropic-ai/claude-code/bin/claude.js "$sb/node_modules/.bin/claude"
if [[ -x "$clink" ]] && out=$("$clink" back 2>/dev/null) && [[ "$out" == "claude-stub back" ]]; then
    ok "link resolves again after fresh install — NO re-link needed"
else
    bad "post-reinstall" "link did not recover (out=${out:-})"
fi
rm -rf "$sb"

echo "=== relocatable: relative links survive moving the whole tree ==="
parent=$(mktemp -d); sb="$parent/nexusA"
make_fake_nexus "$sb" 1; run_linker "$sb"
mv "$sb" "$parent/nexusB"
moved="$parent/nexusB/locals/bin/claude"
if [[ -x "$moved" ]] && out=$("$moved" m 2>/dev/null) && [[ "$out" == "claude-stub m" ]]; then
    ok "relative claude link still resolves after the tree is moved"
else
    bad "relocatable" "link broke after move (out=${out:-})"
fi
rm -rf "$parent"

echo "=== claude absent: links ng/entrypoints, skips claude (no dangle) ==="
sb=$(mktemp -d); make_fake_nexus "$sb" 0   # no node_modules claude
run_linker "$sb"
if [[ ! -e "$sb/locals/bin/claude" && ! -L "$sb/locals/bin/claude" ]]; then
    ok "claude link NOT created when install absent (no permanent dangle)"
else
    bad "claude-absent" "a claude link was created without an install"
fi
if [[ -x "$sb/locals/bin/ng" ]]; then
    ok "ng still linked even when claude install absent"
else
    bad "ng-without-claude" "ng link missing"
fi
rm -rf "$sb"

echo "=== --check reports status without mutating ==="
sb=$(mktemp -d); make_fake_nexus "$sb" 1
# Before provisioning: --check is non-zero and creates nothing.
if NEXUS_ROOT="$sb" NEXUS_LOCALS="$sb/locals" "$LINKER" --check >/dev/null 2>&1; then
    bad "check-pre" "--check returned 0 before links exist"
else
    if [[ ! -d "$sb/locals/bin" ]]; then
        ok "--check makes no changes (no locals/bin created)"
    else
        bad "check-mutation" "--check created locals/bin"
    fi
fi
run_linker "$sb"
if NEXUS_ROOT="$sb" NEXUS_LOCALS="$sb/locals" "$LINKER" --check >/dev/null 2>&1; then
    ok "--check returns 0 once all links are healthy"
else
    bad "check-post" "--check non-zero after provisioning"
fi
rm -rf "$sb"

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
