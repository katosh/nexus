#!/usr/bin/env bash
# Unit tests for the EFFECTIVE Claude Code version resolver
# (`monitor/_cc-version.sh`) — the floor-plus-local-pin scheme from
# your-org/nexus-code#226.
#
# The contract this suite pins down:
#
#   - effective = operator-local pin (if present + non-empty) ELSE the
#     shared package.json FLOOR. The local pin ALWAYS wins when present,
#     even if it is numerically lower than the floor (the gated routine
#     only ever writes an advance, but the resolver itself is a plain
#     prefer-local rule, not a max()).
#   - the local pin file is whitespace-tolerant (a trailing newline, the
#     natural shape of `printf '%s\n' > file`, must read back clean).
#   - a blank / whitespace-only pin file reads as "no pin" (→ floor), so
#     an accidental empty write can never strand the resolver.
#   - the pin path honours $NEXUS_CC_LOCAL_PIN and $NEXUS_STATE_DIR.
#   - write_local_pin is atomic and round-trips through the resolver.
#
# Run: bash monitor/watcher/test-cc-version.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../_cc-version.sh
source "$_script_dir/../_cc-version.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PKG="@anthropic-ai/claude-code"

make_pkg_json() {
    local path="$1" version="$2"
    cat > "$path" <<EOF
{
  "name": "nexus-code-tooling",
  "private": true,
  "dependencies": {
    "@anthropic-ai/claude-code": "$version"
  }
}
EOF
}

# A fake nexus root with package.json (floor) + monitor/.state layout.
ROOT="$WORK/root"
mkdir -p "$ROOT/monitor/.state"
make_pkg_json "$ROOT/package.json" "2.1.147"
PJ="$ROOT/package.json"
PIN="$ROOT/monitor/.state/cc-version-local"

# ---- 1: floor extraction -------------------------------------------------

got=$(cc_version_floor "$PJ" "$PKG")
[[ "$got" == "2.1.147" ]] && pass "floor extracted ($got)" \
    || fail "floor: got '$got', want 2.1.147"

cat > "$WORK/pkg-nopin.json" <<'EOF'
{ "name": "x", "dependencies": { "something-else": "1.0.0" } }
EOF
if cc_version_floor "$WORK/pkg-nopin.json" "$PKG" >/dev/null 2>&1; then
    fail "floor: should fail when key absent"
else
    pass "floor: non-zero when key absent"
fi

# ---- 2: local-pin path resolution ---------------------------------------

# Default: <root>/monitor/.state/cc-version-local
got=$(NEXUS_STATE_DIR="" NEXUS_CC_LOCAL_PIN="" cc_version_local_pin_path "$ROOT")
[[ "$got" == "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "pin path: default = root/monitor/.state/cc-version-local" \
    || fail "pin path default: got '$got'"

# NEXUS_STATE_DIR override
got=$(NEXUS_STATE_DIR="$WORK/altstate" cc_version_local_pin_path "$ROOT")
[[ "$got" == "$WORK/altstate/cc-version-local" ]] \
    && pass "pin path: honours NEXUS_STATE_DIR" \
    || fail "pin path NEXUS_STATE_DIR: got '$got'"

# NEXUS_CC_LOCAL_PIN wins over everything
got=$(NEXUS_STATE_DIR="$WORK/altstate" NEXUS_CC_LOCAL_PIN="$WORK/explicit-pin" \
    cc_version_local_pin_path "$ROOT")
[[ "$got" == "$WORK/explicit-pin" ]] \
    && pass "pin path: NEXUS_CC_LOCAL_PIN overrides NEXUS_STATE_DIR" \
    || fail "pin path override: got '$got'"

# ---- 3: read_local_pin --------------------------------------------------

rm -f "$PIN"
if cc_version_read_local_pin "$ROOT" >/dev/null 2>&1; then
    fail "read_local_pin: should be non-zero when file absent"
else
    pass "read_local_pin: non-zero when absent (→ floor)"
fi

# A pin written the natural way (trailing newline) reads back trimmed.
printf '%s\n' "2.1.161" > "$PIN"
got=$(cc_version_read_local_pin "$ROOT")
[[ "$got" == "2.1.161" ]] && pass "read_local_pin: trims trailing newline ($got)" \
    || fail "read_local_pin: got '$got' want 2.1.161 (whitespace not trimmed?)"

# Surrounding whitespace is also trimmed.
printf '   2.1.162  \n' > "$PIN"
got=$(cc_version_read_local_pin "$ROOT")
[[ "$got" == "2.1.162" ]] && pass "read_local_pin: trims surrounding whitespace ($got)" \
    || fail "read_local_pin: got '$got' want 2.1.162"

# A blank / whitespace-only file reads as "no pin".
printf '   \n' > "$PIN"
if cc_version_read_local_pin "$ROOT" >/dev/null 2>&1; then
    fail "read_local_pin: blank file should read as no-pin"
else
    pass "read_local_pin: blank/whitespace-only → non-zero (→ floor)"
fi
rm -f "$PIN"

# ---- 4: effective resolution --------------------------------------------

# No local pin → floor.
got=$(cc_version_effective "$PJ" "$PKG" "$ROOT")
[[ "$got" == "2.1.147" ]] && pass "effective: no local pin → floor ($got)" \
    || fail "effective floor: got '$got' want 2.1.147"
src=$(cc_version_effective_source "$PJ" "$PKG" "$ROOT")
[[ "$src" == "floor" ]] && pass "effective_source: no pin → 'floor'" \
    || fail "effective_source: got '$src' want floor"

# Local pin present (HIGHER than floor) → pin wins.
printf '%s\n' "2.1.161" > "$PIN"
got=$(cc_version_effective "$PJ" "$PKG" "$ROOT")
[[ "$got" == "2.1.161" ]] && pass "effective: local pin (>floor) wins ($got)" \
    || fail "effective pin-high: got '$got' want 2.1.161"
src=$(cc_version_effective_source "$PJ" "$PKG" "$ROOT")
[[ "$src" == "local-pin" ]] && pass "effective_source: pin present → 'local-pin'" \
    || fail "effective_source: got '$src' want local-pin"

# Local pin present but LOWER than floor → STILL wins (prefer-local, not max).
printf '%s\n' "2.1.100" > "$PIN"
got=$(cc_version_effective "$PJ" "$PKG" "$ROOT")
[[ "$got" == "2.1.100" ]] \
    && pass "effective: local pin (<floor) still wins — prefer-local, not max ($got)" \
    || fail "effective pin-low: got '$got' want 2.1.100"
rm -f "$PIN"

# ---- 5: write_local_pin round-trip + atomicity --------------------------

# State dir auto-created when missing.
ROOT2="$WORK/root2"
mkdir -p "$ROOT2"
make_pkg_json "$ROOT2/package.json" "2.1.147"
if cc_version_write_local_pin "2.1.158" "$ROOT2"; then
    pass "write_local_pin: rc 0 (creates state dir)"
else
    fail "write_local_pin: non-zero on a fresh root"
fi
got=$(cc_version_read_local_pin "$ROOT2")
[[ "$got" == "2.1.158" ]] && pass "write_local_pin: round-trips through read ($got)" \
    || fail "write_local_pin: read back '$got' want 2.1.158"
# Effective now resolves to the written pin.
got=$(cc_version_effective "$ROOT2/package.json" "$PKG" "$ROOT2")
[[ "$got" == "2.1.158" ]] && pass "write_local_pin: effective tracks the written pin" \
    || fail "write_local_pin: effective '$got' want 2.1.158"
# Overwrite advances it; no leftover temp file.
cc_version_write_local_pin "2.1.159" "$ROOT2"
got=$(cc_version_read_local_pin "$ROOT2")
leftover=$(find "$ROOT2/monitor/.state" -name 'cc-version-local.tmp.*' 2>/dev/null)
if [[ "$got" == "2.1.159" && -z "$leftover" ]]; then
    pass "write_local_pin: overwrite advances, no temp residue"
else
    fail "write_local_pin: got '$got' leftover='$leftover'"
fi

# ---- 6: gate-baseline wiring (the load-bearing change) ------------------
#
# _v2_task_cc_version_check feeds `cc_version_effective` into
# `_cc_update_decide` as the comparison baseline. This mirrors that exact
# composition to prove the gate fires against the EFFECTIVE version, not
# the (lagging) floor. The registry fetch is the injectable shim from the
# cc-update suite — no network.
source "$_script_dir/_cc_update.sh"
FETCH_VERSION=""
fetch_ok() { printf '{"name":"%s","version":"%s"}\n' "$1" "$FETCH_VERSION"; }

GROOT="$WORK/gate-root"
mkdir -p "$GROOT/monitor/.state"
make_pkg_json "$GROOT/package.json" "2.1.147"   # floor lags by design
GPJ="$GROOT/package.json"
GPIN="$GROOT/monitor/.state/cc-version-local"
SKILL="skills/nexus.cc-update/GUIDE.md"

# Scenario A — no local pin, registry ahead of the floor → gate FIRES
# against the floor (a fresh operator still on the floor must be told).
rm -f "$GPIN"
FETCH_VERSION="2.1.161"
base=$(cc_version_effective "$GPJ" "$PKG" "$GROOT")
verdict=$(_cc_update_decide "$GROOT/monitor/.state" "$PKG" "$base" "$SKILL" fetch_ok 10); rc=$?
if [[ "$base" == "2.1.147" ]] && (( rc == 0 )) && [[ "$verdict" == available* ]]; then
    pass "gate: no local pin → baseline=floor, fires when registry ahead"
else
    fail "gate no-pin: base=$base rc=$rc verdict='$verdict'"
fi

# Scenario B — local pin == registry latest, floor STILL lagging → gate
# is SILENT. THE decoupling property: the operator is current via their
# local pin even though the shared floor never moved.
printf '%s\n' "2.1.161" > "$GPIN"
FETCH_VERSION="2.1.161"
base=$(cc_version_effective "$GPJ" "$PKG" "$GROOT")
verdict=$(_cc_update_decide "$GROOT/monitor/.state" "$PKG" "$base" "$SKILL" fetch_ok 10); rc=$?
if [[ "$base" == "2.1.161" ]] && (( rc == 1 )) && [[ "$verdict" == current* ]] \
   && [[ ! -f "$GROOT/monitor/.state/cc-update-available" ]]; then
    pass "gate: local pin == latest (floor lags) → SILENT (decoupled from floor)"
else
    fail "gate pin==latest: base=$base rc=$rc verdict='$verdict'"
fi

# Scenario C — local pin ahead of floor but a NEWER release exists → gate
# fires against the local pin, candidate = the new release.
printf '%s\n' "2.1.161" > "$GPIN"
FETCH_VERSION="2.1.165"
base=$(cc_version_effective "$GPJ" "$PKG" "$GROOT")
verdict=$(_cc_update_decide "$GROOT/monitor/.state" "$PKG" "$base" "$SKILL" fetch_ok 10); rc=$?
if [[ "$base" == "2.1.161" ]] && (( rc == 0 )) && [[ "$verdict" == *candidate=2.1.165* ]] \
   && [[ "$verdict" == *installed=2.1.161* ]]; then
    pass "gate: local pin ahead of floor, newer release → fires vs the pin"
else
    fail "gate pin-ahead: base=$base rc=$rc verdict='$verdict'"
fi

# ---- pin-writer portability (nexus-code#513 aside) -----------------------
# Sourced from a zsh agent shell, `dirname` resolved to command-not-found
# and cc_version_write_local_pin silently no-op'd — leaving the
# load-bearing pin unwritten while returning a printed error nobody read.
# The writer now derives the directory by parameter expansion; pin that
# by shadowing dirname with a hard failure and writing anyway.
dirname() { echo "dirname MUST NOT be called" >&2; return 127; }
DROOT="$WORK/dirless"; mkdir -p "$DROOT"
if cc_version_write_local_pin "9.9.9" "$DROOT" 2>"$WORK/dirless.err" \
   && [[ "$(cc_version_read_local_pin "$DROOT")" == "9.9.9" ]] \
   && [[ ! -s "$WORK/dirless.err" ]]; then
    pass "pin writer succeeds with dirname unavailable (no external dep on the write path)"
else
    fail "pin writer still depends on dirname: $(cat "$WORK/dirless.err" 2>/dev/null)"
fi
unset -f dirname

# ---- summary ------------------------------------------------------------

echo
echo "cc-version: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
