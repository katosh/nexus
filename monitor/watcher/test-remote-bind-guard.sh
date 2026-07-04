#!/usr/bin/env bash
# Tests for the LAN-direct bind-exposure hardening of the confined remote
# channel: the fail-closed `_remote_bind_guard` (monitor/_remote_lib.sh) and
# the strong-crypto allowlist in the supervised sshd (monitor/remote-sshd-
# supervised.sh). The sandbox shares the host netns and CAN bind a routable
# LAN address (off-host clients connect directly, no host-side carrier) — so
# this SENSITIVE endpoint is guarded: loopback is always fine; a routable IP
# needs a from_cidr pin (which may be as broad as the any-source 0.0.0.0/0 — a
# conscious opt-in — but must be a well-formed, non-EMPTY CIDR); a wildcard
# BIND (0.0.0.0/::) is refused outright (a different axis from from_cidr).
#
#   1. loopback binds pass with no from_cidr (on-host only)
#   2. a routable IP WITHOUT from_cidr is REFUSED (fail-closed) — load-bearing
#   3. a routable IP WITH from_cidr passes (narrow /32, subnet /16, /8)
#   4. a wildcard BIND (0.0.0.0 / ::) is REFUSED even with from_cidr
#   4b. every IPv6 all-zeros spelling (::0, 0:0:…:0, 0000:…, [::]) is ALSO
#       refused, while a specific IPv6 (::1, 2001:db8::1) is not over-refused
#   5. the refusal prints an actionable remediation (from_cidr / loopback)
#   6. an EXPLICIT any-source from_cidr (0.0.0.0/0, ::/0) is now ACCEPTED on a
#      routable bind (conscious opt-in), while EMPTY still fails closed
#   7. a MALFORMED from_cidr is REFUSED (a typo must not degrade to no-pin)
#   8. the committed sshd strong-crypto allowlist parses on the live sshd
#      (skips cleanly if no sshd) — no algorithm unsupported on the 7.6 floor
#
# Run: bash monitor/watcher/test-remote-bind-guard.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
SUP="$MON_DIR/remote-sshd-supervised.sh"

# ── hermetic config isolation ────────────────────────────────────────────
# The guard resolves from_cidr via config/load.sh, whose precedence is
# $NEXUS_CONFIG → $NEXUS_ROOT/config/nexus.yml → nexus.example.yml. On a live
# operator host $NEXUS_ROOT points at a clone with a REAL nexus.yml (a routable
# bind + a /32 pin), which would leak into the "empty from_cidr" cases below and
# mask the fail-closed assertion. Pin every knob to a throwaway fixture with an
# EMPTY remote block so an unset/empty env var resolves to "" (not the live pin)
# — env overrides still win per-case (env is checked before the file).
WORK=$(mktemp -d -t nexus-bindguard-XXXXXX); trap 'rm -rf "$WORK"' EXIT
HERMETIC_CFG="$WORK/nexus.yml"
cat >"$HERMETIC_CFG" <<'YML'
monitor:
  remote:
    bind_address: 127.0.0.1
    from_cidr: ""
YML
export NEXUS_CONFIG="$HERMETIC_CFG"

# Run _remote_bind_guard with a given (bind, cidr); echo PASS|REFUSE.
guard() {
    local bind="$1" cidr="$2"
    MONITOR_REMOTE_BIND_ADDRESS="$bind" MONITOR_REMOTE_FROM_CIDR="$cidr" \
        bash -c "source '$LIB'; _remote_bind_guard" >/dev/null 2>&1 \
        && echo PASS || echo REFUSE
}

echo "== 1. loopback binds pass without from_cidr =="
assert_eq "127.0.0.1 no cidr → PASS" "$(guard 127.0.0.1 '')" "PASS"
assert_eq "::1 no cidr → PASS"       "$(guard ::1 '')"       "PASS"

echo "== 2. routable IP without from_cidr is REFUSED (fail-closed) =="
assert_eq "140.107.222.134 no cidr → REFUSE" "$(guard 140.107.222.134 '')" "REFUSE"

echo "== 3. routable IP with from_cidr passes =="
assert_eq "routable + /32 pin → PASS" "$(guard 140.107.222.134 '10.0.0.5/32')" "PASS"
assert_eq "routable + range pin → PASS" "$(guard 10.1.2.3 '10.1.0.0/16')" "PASS"

echo "== 4. wildcard bind is REFUSED even with from_cidr =="
assert_eq "0.0.0.0 + cidr → REFUSE" "$(guard 0.0.0.0 '10.0.0.0/8')" "REFUSE"
assert_eq ":: + cidr → REFUSE"       "$(guard :: '10.0.0.0/8')"      "REFUSE"

echo "== 4b. IPv6 all-zeros wildcard forms (any spelling) are REFUSED even with from_cidr =="
# The 'never bind ALL interfaces' invariant must hold regardless of how the
# any-address is written. Before this hardening only ::/[::] were caught; the
# compressed (::0, 0::) and expanded (0:0:…:0, 0000:…) IPv6 zero forms, and
# bracketed variants, slipped past → with a from_cidr set they would have bound
# every IPv6 interface. Each must fail closed.
assert_eq "::0 + cidr → REFUSE"                 "$(guard '::0' '10.0.0.0/8')"                                   "REFUSE"
assert_eq "0:: + cidr → REFUSE"                 "$(guard '0::' '10.0.0.0/8')"                                   "REFUSE"
assert_eq "0:0:0:0:0:0:0:0 + cidr → REFUSE"     "$(guard '0:0:0:0:0:0:0:0' '10.0.0.0/8')"                       "REFUSE"
assert_eq "expanded 0000:… + cidr → REFUSE"     "$(guard '0000:0000:0000:0000:0000:0000:0000:0000' '10.0.0.0/8')" "REFUSE"
assert_eq "[::] bracketed + cidr → REFUSE"      "$(guard '[::]' '10.0.0.0/8')"                                  "REFUSE"
assert_eq "[0:0:…] bracketed + cidr → REFUSE"   "$(guard '[0:0:0:0:0:0:0:0]' '10.0.0.0/8')"                     "REFUSE"
# Guardrail against over-refusal: a SPECIFIC IPv6 (any nonzero hextet) is NOT a
# wildcard — loopback ::1 passes with no pin; a routable IPv6 passes WITH a pin.
assert_eq "::1 loopback still PASS (not wildcard)" "$(guard '::1' '')"                                          "PASS"
assert_eq "specific IPv6 + cidr → PASS"         "$(guard '2001:db8::1' 'fe80::/10')"                            "PASS"

echo "== 5. refusal message is actionable =="
msg=$(MONITOR_REMOTE_BIND_ADDRESS="140.107.222.134" bash -c "source '$LIB'; _remote_bind_guard" 2>&1)
assert_contains "names from_cidr as the fix" "$msg" "from_cidr"
assert_contains "offers the loopback fallback" "$msg" "loopback"
wmsg=$(MONITOR_REMOTE_BIND_ADDRESS="0.0.0.0" bash -c "source '$LIB'; _remote_bind_guard" 2>&1)
assert_contains "wildcard refusal names all interfaces" "$wmsg" "ALL interfaces"

echo "== 6. explicit any-source from_cidr is ACCEPTED on a routable bind =="
assert_eq "routable + 0.0.0.0/0 → PASS" "$(guard 140.107.222.134 '0.0.0.0/0')" "PASS"
assert_eq "routable + ::/0 → PASS"       "$(guard 140.107.222.134 '::/0')"       "PASS"
assert_eq "routable + broad subnet /16 → PASS" "$(guard 140.107.222.134 '140.107.0.0/16')" "PASS"
assert_eq "routable + /8 → PASS" "$(guard 10.1.2.3 '10.0.0.0/8')" "PASS"
# EMPTY still fails closed even though /0 is now allowed — the two are distinct.
assert_eq "routable + EMPTY still → REFUSE" "$(guard 140.107.222.134 '')" "REFUSE"

echo "== 7. a malformed from_cidr is REFUSED (typo must not degrade to no-pin) =="
assert_eq "routable + garbage → REFUSE"        "$(guard 140.107.222.134 'not-a-cidr')" "REFUSE"
assert_eq "routable + bare IP no prefix → REFUSE" "$(guard 140.107.222.134 '10.0.0.5')" "REFUSE"
assert_eq "routable + octet>255 → REFUSE"      "$(guard 140.107.222.134 '999.1.1.1/8')" "REFUSE"
assert_eq "routable + prefix>32 → REFUSE"      "$(guard 140.107.222.134 '10.0.0.0/33')" "REFUSE"
# A malformed pin is rejected even on a loopback bind (defence-in-depth).
assert_eq "loopback + garbage → REFUSE"        "$(guard 127.0.0.1 'not-a-cidr')" "REFUSE"

echo "== 8. committed sshd strong-crypto allowlist parses on the live sshd =="
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
if [[ ! -x "$SSHD" ]] || ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "  SKIP: no sshd/ssh-keygen on this runner"
    PASS=$((PASS+1))
else
    # Reuse the $WORK dir + EXIT trap set up for the hermetic fixture above.
    ssh-keygen -t ed25519 -f "$WORK/hk" -N '' >/dev/null 2>&1
    # Extract the exact Kex/Ciphers/MACs/PubkeyAcceptedKeyTypes lines the
    # supervisor commits, and feed them to `sshd -t` — validates the REAL set.
    mapfile -t crypto < <(grep -oE '"(KexAlgorithms|Ciphers|MACs|PubkeyAcceptedKeyTypes)=[^"]*"' "$SUP" | tr -d '"')
    assert_eq "found all 4 crypto directives in the supervisor" "${#crypto[@]}" "4"
    args=(-t -f /dev/null -h "$WORK/hk")
    for c in "${crypto[@]}"; do args+=(-o "$c"); done
    if "$SSHD" "${args[@]}" 2>"$WORK/err"; then
        printf '  PASS: committed strong-crypto allowlist parses on the live sshd\n'; PASS=$((PASS+1))
    else
        printf '  FAIL: committed crypto rejected: %s\n' "$(tr '\n' ' ' < "$WORK/err")" >&2; FAIL=$((FAIL+1))
    fi
fi

th_summary_and_exit
