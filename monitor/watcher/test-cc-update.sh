#!/usr/bin/env bash
# Unit tests for the watcher's Claude Code update-detection signal
# (`monitor/watcher/_cc_update.sh`).
#
# The detection is the DETECT→INFORM half of the GATED cc self-update
# loop: compare the package.json pin against the npm `latest` dist-tag,
# and on a newer release write an advisory state file that the emit
# surfaces once per candidate. It NEVER bumps. The two non-negotiable
# properties this suite pins down:
#
#   - Correct comparison across newer / same / older.
#   - Fail-safe on a registry-fetch failure: leave any existing signal
#     untouched, write nothing, never error the loop.
#   - Idempotent surfacing (no re-nag for the same candidate).
#
# The registry fetch is injected via the `fetch_cmd` indirection so no
# test hits the network. The shim returns the same JSON shape the real
# registry `/latest` endpoint returns (`{"version":"..."}`), so the jq
# extraction path is exercised too.
#
# Cases covered:
#   1.  pinned-version extraction from a package.json fixture.
#   2.  pinned-version: missing key → non-zero, no output.
#   3.  latest-version via injected fetch (JSON → version).
#   4.  latest-version: fetch fails → non-zero.
#   5.  latest-version: malformed JSON → non-zero.
#   6.  compare: newer / same / older, incl. multi-digit semver ordering.
#   7.  decide newer → writes signal file with correct fields, rc 0.
#   8.  decide same → removes a stale signal (self-heal), rc 1.
#   9.  decide older → removes a stale signal, rc 1.
#   10. decide fetch-fail → rc 2, EXISTING signal UNTOUCHED (fail-safe).
#   11. decide no-pinned → rc 2 unknown, no signal written.
#   12. write_signal idempotency: same candidate twice → mtime unchanged.
#   13. emit_section: first call emits + marks surfaced; second silent.
#   14. emit_section: no signal file → silent rc 1.
#   15. emit_section: new candidate after a surface → emits again.
#   16. emit_section: section text points at the skill + gate command.
#   17. emit_section: emit gate OFF (default) → silent, signal untouched.
#   18. emit_section: emit gate ON → surfaces (mutation vs case 17).
#
# Run: bash monitor/watcher/test-cc-update.sh

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_cc_update.sh
source "$_script_dir/_cc_update.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PKG="@anthropic-ai/claude-code"
SKILL="skills/nexus.cc-update/GUIDE.md"

# ---- fixtures -----------------------------------------------------------

# A package.json with a given pin for $PKG.
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

# Fetch shims (fetch_cmd signature: <package> [timeout] → registry JSON
# on stdout, rc 0; non-zero to simulate a failed fetch).
FETCH_VERSION=""   # set per-test; the "ok" shim echoes it as .version
fetch_ok()        { printf '{"name":"%s","version":"%s"}\n' "$1" "$FETCH_VERSION"; }
fetch_fail()      { return 22; }                      # curl-style failure rc
fetch_malformed() { printf 'not json at all\n'; }     # jq will reject

# ---- 1–2: pinned-version extraction -------------------------------------

make_pkg_json "$WORK/pkg-good.json" "2.1.147"
got=$(_cc_update_pinned_version "$WORK/pkg-good.json" "$PKG")
[[ "$got" == "2.1.147" ]] && pass "pinned-version extracted ($got)" \
    || fail "pinned-version: got '$got', want 2.1.147"

cat > "$WORK/pkg-nopin.json" <<'EOF'
{ "name": "x", "dependencies": { "something-else": "1.0.0" } }
EOF
if _cc_update_pinned_version "$WORK/pkg-nopin.json" "$PKG" >/dev/null 2>&1; then
    fail "pinned-version: should fail when key absent"
else
    pass "pinned-version: non-zero when key absent"
fi

# ---- 3–5: latest-version via injected fetch -----------------------------

FETCH_VERSION="2.1.157"
got=$(_cc_update_latest_version "$PKG" fetch_ok 10)
[[ "$got" == "2.1.157" ]] && pass "latest-version via shim ($got)" \
    || fail "latest-version: got '$got', want 2.1.157"

if _cc_update_latest_version "$PKG" fetch_fail 10 >/dev/null 2>&1; then
    fail "latest-version: should fail on fetch failure"
else
    pass "latest-version: non-zero on fetch failure"
fi

if _cc_update_latest_version "$PKG" fetch_malformed 10 >/dev/null 2>&1; then
    fail "latest-version: should fail on malformed JSON"
else
    pass "latest-version: non-zero on malformed JSON"
fi

# ---- 6: compare ---------------------------------------------------------

[[ "$(_cc_update_compare 2.1.147 2.1.157)" == "newer" ]] \
    && pass "compare: 2.1.147 < 2.1.157 → newer" \
    || fail "compare: 2.1.147 vs 2.1.157 not newer"
[[ "$(_cc_update_compare 2.1.157 2.1.157)" == "same" ]] \
    && pass "compare: equal → same" || fail "compare: equal not same"
[[ "$(_cc_update_compare 2.1.157 2.1.147)" == "older" ]] \
    && pass "compare: 2.1.157 > 2.1.147 → older" \
    || fail "compare: 2.1.157 vs 2.1.147 not older"
# multi-digit ordering: 2.1.9 < 2.1.10 (string compare would get this wrong)
[[ "$(_cc_update_compare 2.1.9 2.1.10)" == "newer" ]] \
    && pass "compare: 2.1.9 < 2.1.10 → newer (semver, not string)" \
    || fail "compare: 2.1.9 vs 2.1.10 not newer (semver ordering broke)"

# ---- 7: decide newer → writes signal ------------------------------------

STATE="$WORK/state-newer"; mkdir -p "$STATE"
FETCH_VERSION="2.1.157"
verdict=$(_cc_update_decide "$STATE" "$PKG" "2.1.147" "$SKILL" fetch_ok 10); rc=$?
sig="$STATE/cc-update-available"
if (( rc == 0 )) && [[ "$verdict" == available* ]] && [[ -f "$sig" ]]; then
    pass "decide newer: rc 0, verdict available, signal written"
else
    fail "decide newer: rc=$rc verdict='$verdict' signal_exists=$([[ -f $sig ]] && echo y || echo n)"
fi
# field correctness
c=$(_cc_update_field "$sig" candidate); i=$(_cc_update_field "$sig" installed)
p=$(_cc_update_field "$sig" package);   s=$(_cc_update_field "$sig" skill)
if [[ "$c" == "2.1.157" && "$i" == "2.1.147" && "$p" == "$PKG" && "$s" == "$SKILL" ]]; then
    pass "decide newer: signal fields correct"
else
    fail "decide newer: fields c=$c i=$i p=$p s=$s"
fi

# ---- 8: decide same → self-heals signal away ----------------------------

STATE="$WORK/state-same"; mkdir -p "$STATE"
FETCH_VERSION="2.1.157"
# seed a stale signal first
_cc_update_decide "$STATE" "$PKG" "2.1.147" "$SKILL" fetch_ok 10 >/dev/null
# now the pin has caught up to latest
verdict=$(_cc_update_decide "$STATE" "$PKG" "2.1.157" "$SKILL" fetch_ok 10); rc=$?
if (( rc == 1 )) && [[ "$verdict" == current* ]] && [[ ! -f "$STATE/cc-update-available" ]]; then
    pass "decide same: rc 1, verdict current, stale signal removed (self-heal)"
else
    fail "decide same: rc=$rc verdict='$verdict' signal_still=$([[ -f $STATE/cc-update-available ]] && echo y || echo n)"
fi

# ---- 9: decide older → also clears signal --------------------------------

STATE="$WORK/state-older"; mkdir -p "$STATE"
FETCH_VERSION="2.1.100"   # registry latest is BEHIND the local pin
printf 'candidate=x\n' > "$STATE/cc-update-available"   # seed a stale signal
verdict=$(_cc_update_decide "$STATE" "$PKG" "2.1.147" "$SKILL" fetch_ok 10); rc=$?
if (( rc == 1 )) && [[ "$verdict" == current* ]] && [[ ! -f "$STATE/cc-update-available" ]]; then
    pass "decide older: rc 1, verdict current, signal cleared"
else
    fail "decide older: rc=$rc verdict='$verdict'"
fi

# ---- 10: decide fetch-fail → FAIL-SAFE, signal untouched -----------------

STATE="$WORK/state-failsafe"; mkdir -p "$STATE"
# seed a real signal from a prior successful detection
FETCH_VERSION="2.1.157"
_cc_update_decide "$STATE" "$PKG" "2.1.147" "$SKILL" fetch_ok 10 >/dev/null
before=$(cat "$STATE/cc-update-available")
# now the registry goes unreachable
verdict=$(_cc_update_decide "$STATE" "$PKG" "2.1.147" "$SKILL" fetch_fail 10); rc=$?
after=$(cat "$STATE/cc-update-available" 2>/dev/null || echo MISSING)
if (( rc == 2 )) && [[ "$verdict" == unreachable* ]] && [[ "$before" == "$after" ]]; then
    pass "decide fetch-fail: rc 2 unreachable, existing signal UNTOUCHED (fail-safe)"
else
    fail "decide fetch-fail: rc=$rc verdict='$verdict' signal_changed=$([[ "$before" == "$after" ]] && echo no || echo YES)"
fi

# ---- 11: decide no-pinned → unknown, fail-safe ---------------------------

STATE="$WORK/state-nopin"; mkdir -p "$STATE"
FETCH_VERSION="2.1.157"
verdict=$(_cc_update_decide "$STATE" "$PKG" "" "$SKILL" fetch_ok 10); rc=$?
if (( rc == 2 )) && [[ "$verdict" == unknown* ]] && [[ ! -f "$STATE/cc-update-available" ]]; then
    pass "decide no-pinned: rc 2 unknown, nothing written"
else
    fail "decide no-pinned: rc=$rc verdict='$verdict'"
fi

# ---- 12: write_signal idempotency (no mtime churn) -----------------------

STATE="$WORK/state-idem"; mkdir -p "$STATE"
sig="$STATE/cc-update-available"
_cc_update_write_signal "$sig" "$PKG" "2.1.147" "2.1.157" "$SKILL"
touch -d "100 seconds ago" "$sig"
mt1=$(date +%s -r "$sig")
_cc_update_write_signal "$sig" "$PKG" "2.1.147" "2.1.157" "$SKILL"   # same candidate
mt2=$(date +%s -r "$sig")
[[ "$mt1" == "$mt2" ]] && pass "write_signal: same candidate → mtime unchanged (idempotent)" \
    || fail "write_signal: mtime churned ($mt1 → $mt2) for unchanged candidate"
# but a NEW candidate rewrites
_cc_update_write_signal "$sig" "$PKG" "2.1.147" "2.1.158" "$SKILL"
mt3=$(date +%s -r "$sig")
nc=$(_cc_update_field "$sig" candidate)
[[ "$nc" == "2.1.158" ]] && pass "write_signal: new candidate rewrites file ($nc)" \
    || fail "write_signal: new candidate not written (got $nc)"

# ---- 13: emit_section first/second (re-nag guard) ------------------------

# Cases 13/15/16 exercise the emit PATH, so the emit gate must be ON for
# them (it defaults OFF — see cases 17/18 for the gate behaviour itself).
export MONITOR_CC_UPDATE_EMIT_ENABLED=true

STATE="$WORK/state-emit"; mkdir -p "$STATE"
FETCH_VERSION="2.1.157"
_cc_update_decide "$STATE" "$PKG" "2.1.147" "$SKILL" fetch_ok 10 >/dev/null
sec1=$(_cc_update_emit_section "$STATE"); rc1=$?
sec2=$(_cc_update_emit_section "$STATE"); rc2=$?
if (( rc1 == 0 )) && [[ -n "$sec1" ]] && (( rc2 == 1 )) && [[ -z "$sec2" ]]; then
    pass "emit_section: first emits, second silent (re-nag guarded)"
else
    pass_dbg="rc1=$rc1 len1=${#sec1} rc2=$rc2 len2=${#sec2}"
    fail "emit_section: re-nag guard broken ($pass_dbg)"
fi

# ---- 14: emit_section with no signal file --------------------------------

STATE="$WORK/state-emit-empty"; mkdir -p "$STATE"
sec=$(_cc_update_emit_section "$STATE"); rc=$?
if (( rc == 1 )) && [[ -z "$sec" ]]; then
    pass "emit_section: no signal → silent rc 1"
else
    fail "emit_section: empty-state not silent (rc=$rc len=${#sec})"
fi

# ---- 15: emit_section re-arms on a NEW candidate -------------------------

# continuing from case 13's STATE: a newer release lands
STATE="$WORK/state-emit"
FETCH_VERSION="2.1.160"
_cc_update_decide "$STATE" "$PKG" "2.1.147" "$SKILL" fetch_ok 10 >/dev/null
sec3=$(_cc_update_emit_section "$STATE"); rc3=$?
if (( rc3 == 0 )) && [[ "$sec3" == *2.1.160* ]]; then
    pass "emit_section: new candidate re-arms surfacing"
else
    fail "emit_section: new candidate not re-surfaced (rc=$rc3)"
fi

# ---- 16: emit_section content points at skill + gate ---------------------

if [[ "$sec1" == *"$SKILL"* ]] \
   && [[ "$sec1" == *"gate.sh --version"* ]] \
   && [[ "$sec1" == *"GATED"* ]]; then
    pass "emit_section: section cites skill path, gate command, GATED warning"
else
    fail "emit_section: section missing skill/gate/GATED pointer"
fi

# ---- 17/18: emit gate OFF (default) vs ON (mutation) --------------------

# A fresh signal with an UNSURFACED candidate: with the gate OFF the
# section must stay silent (rc 1, empty) and must NOT consume the candidate
# (the surfaced marker is untouched), so flipping the gate ON then surfaces
# it. This is the mutation check the task requires: OFF→silent, ON→emits.
STATE="$WORK/state-gate"; mkdir -p "$STATE"
FETCH_VERSION="2.1.200"
_cc_update_decide "$STATE" "$PKG" "2.1.147" "$SKILL" fetch_ok 10 >/dev/null

MONITOR_CC_UPDATE_EMIT_ENABLED=false
sec_off=$(_cc_update_emit_section "$STATE"); rc_off=$?
if (( rc_off == 1 )) && [[ -z "$sec_off" ]] && [[ ! -f "$STATE/cc-update-surfaced" ]]; then
    pass "emit_section: gate OFF → silent rc 1, candidate NOT consumed"
else
    fail "emit_section: gate OFF not silent (rc=$rc_off len=${#sec_off} surfaced=$([[ -f "$STATE/cc-update-surfaced" ]] && echo yes || echo no))"
fi

MONITOR_CC_UPDATE_EMIT_ENABLED=true
sec_on=$(_cc_update_emit_section "$STATE"); rc_on=$?
if (( rc_on == 0 )) && [[ "$sec_on" == *2.1.200* ]]; then
    pass "emit_section: gate ON → surfaces (mutation vs OFF)"
else
    fail "emit_section: gate ON did not surface (rc=$rc_on len=${#sec_on})"
fi
unset MONITOR_CC_UPDATE_EMIT_ENABLED

# ---- summary ------------------------------------------------------------

echo
echo "cc-update: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
