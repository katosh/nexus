#!/usr/bin/env bash
# Tests for monitor/write-probe.sh — the deliverable-write-path
# probe that fails fast (with the EXTRA_WRITABLE_PATHS grant recipe)
# when a target is read-only inside the sandbox, BEFORE a worker
# commits compute to it. Addresses B2 of your-org/your-nexus#236.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_dir/../write-probe.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- writable existing directory ---------------------------------
out=$("$PROBE" "$WORK" 2>&1); rc=$?
assert_eq        "writable dir: rc 0"           "$rc" "0"
assert_contains  "writable dir: prints OK"      "$out" "OK"

# --- not-yet-created target under a writable ancestor ------------
out=$("$PROBE" "$WORK/a/b/c/deliverable.bw" 2>&1); rc=$?
assert_eq        "uncreated-under-writable: rc 0" "$rc" "0"

# --- read-only target, IN-SANDBOX: grant recipe emitted ----------
# A 0555 directory is a hermetic RO fixture (no dependence on a real
# mount). The sandbox markers (SANDBOX_ACTIVE=1 + SANDBOX_PROJECT_DIR)
# are set EXPLICITLY here so the assertion does not depend on whether
# the suite itself happens to run inside the live sandbox — the canonical
# signal write-probe.sh / bootstrap-install.sh / watcher/entry.sh gate on.
ro_root="$WORK/ro"
mkdir -p "$ro_root"
chmod 0555 "$ro_root"
# Only meaningful when we are NOT root (root ignores the mode bits).
if [[ "$(id -u)" != "0" ]] && ! ( : > "$ro_root/.probe" ) 2>/dev/null; then
    out=$(SANDBOX_ACTIVE=1 SANDBOX_PROJECT_DIR="$WORK" "$PROBE" "$ro_root/out.dat" 2>&1); rc=$?
    assert_eq       "ro in-sandbox: rc 3"               "$rc" "3"
    assert_contains "ro in-sandbox: says NOT WRITABLE"  "$out" "NOT WRITABLE"
    assert_contains "ro in-sandbox: prints grant var"   "$out" "EXTRA_WRITABLE_PATHS"
    assert_contains "ro in-sandbox: names sandbox.conf" "$out" "sandbox.conf"
    assert_contains "ro in-sandbox: probes nearest existing ancestor" "$out" "$ro_root"

    # --- same RO target, OUT-OF-SANDBOX: NO grant recipe -----------
    # Clear BOTH markers so write-probe sees a non-sandbox run. It must
    # still fail (a genuinely RO dir is a real error) but degrade to a
    # generic message — the EXTRA_WRITABLE_PATHS / sandbox.conf grant
    # recipe would be wrong/confusing where no such mechanism exists.
    out=$(env -u SANDBOX_ACTIVE -u SANDBOX_PROJECT_DIR "$PROBE" "$ro_root/out.dat" 2>&1); rc=$?
    assert_eq           "ro out-of-sandbox: rc 3"                 "$rc" "3"
    assert_contains     "ro out-of-sandbox: says NOT WRITABLE"    "$out" "NOT WRITABLE"
    assert_not_contains "ro out-of-sandbox: NO grant var"         "$out" "EXTRA_WRITABLE_PATHS"
    assert_not_contains "ro out-of-sandbox: NO sandbox.conf"      "$out" "sandbox.conf"

    # SANDBOX_ACTIVE set but PROJECT_DIR empty is NOT in-sandbox (the
    # canonical signal requires BOTH) — must use the generic message.
    out=$(SANDBOX_ACTIVE=1 env -u SANDBOX_PROJECT_DIR "$PROBE" "$ro_root/out.dat" 2>&1); rc=$?
    assert_not_contains "ro partial-marker: NO grant var (needs both markers)" "$out" "EXTRA_WRITABLE_PATHS"
else
    echo "  SKIP: ro-mode fixture not enforceable (running as root?)"
fi
chmod 0755 "$ro_root"  # let trap clean up

# --- writable target, OUT-OF-SANDBOX: silent success, no friction --
# A normal non-sandbox run against a writable target must pass cleanly
# with no spurious failure and no sandbox-grant noise.
out=$(env -u SANDBOX_ACTIVE -u SANDBOX_PROJECT_DIR "$PROBE" "$WORK" 2>&1); rc=$?
assert_eq           "writable out-of-sandbox: rc 0"          "$rc" "0"
assert_contains     "writable out-of-sandbox: prints OK"     "$out" "OK"
assert_not_contains "writable out-of-sandbox: no grant var"  "$out" "EXTRA_WRITABLE_PATHS"

# --- mixed: one writable + one read-only → overall failure ------
if [[ "$(id -u)" != "0" ]]; then
    ro2="$WORK/ro2"; mkdir -p "$ro2"; chmod 0555 "$ro2"
    if ! ( : > "$ro2/.probe" ) 2>/dev/null; then
        out=$("$PROBE" "$WORK" "$ro2/x" 2>&1); rc=$?
        assert_eq       "mixed targets: rc 3 if any RO" "$rc" "3"
        assert_contains "mixed targets: still reports the writable one" "$out" "OK"
    fi
    chmod 0755 "$ro2"
fi

# --- usage error: no targets ------------------------------------
out=$("$PROBE" 2>&1); rc=$?
assert_eq        "no args: rc 2"                "$rc" "2"
assert_contains  "no args: prints usage"        "$out" "usage:"

# --- --quiet suppresses OK lines but not failures ----------------
out=$("$PROBE" --quiet "$WORK" 2>&1); rc=$?
assert_eq        "quiet writable: rc 0"         "$rc" "0"
assert_not_contains "quiet writable: no OK line" "$out" "OK"

th_summary_and_exit
