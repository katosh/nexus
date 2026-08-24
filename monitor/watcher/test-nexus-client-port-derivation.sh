#!/usr/bin/env bash
# Cross-implementation AGREEMENT guard for the per-operator port derivation
# (your-org/nexus-code#893, skeptic finding F1).
#
# THE FORMULA EXISTS TWICE, AND IT HAS TO:
#   server  monitor/_remote_lib.sh          _remote_derived_port   (bash)
#   client  monitor/client/_nexus_watch_lib.sh  _nexus_derived_port  (POSIX sh)
# The client file is SHIPPED TO THE CLIENT'S MACHINE and must stand alone — it
# cannot source the operator-side lib. So the duplication is forced, and THIS
# FILE is the mitigation: if the two ever disagree on any identity, the client
# connects to a port the server is not on.
#
# That is not hypothetical. `#893` moved the SERVER off the shared constant
# 22022 and left the CLIENT default at 22022, so the two halves of one fix
# disagreed and a client on the default reached another operator's endpoint —
# `#893`'s own failure mode arriving from the other side. This guard is what
# makes the next such drift fail a suite instead of a connection.
#
# It compares the two implementations DIRECTLY, on the same inputs, rather than
# checking each against a hardcoded table — a table would have to be edited in
# lockstep with the formula and would then agree with a wrong change.
#
# Run: bash monitor/watcher/test-nexus-client-port-derivation.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
SRV_LIB="$MON_DIR/_remote_lib.sh"
CLI_LIB="$MON_DIR/client/_nexus_watch_lib.sh"

[[ -r "$SRV_LIB" ]] || th_abort "server lib not readable: $SRV_LIB"
[[ -r "$CLI_LIB" ]] || th_abort "client lib not readable: $CLI_LIB"

WORK=$(mktemp -d -t nexus-portderiv-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# The client lib is POSIX sh and is meant to run under the CLIENT's /bin/sh,
# on a machine with no nexus config at all. Exercise it that way — under `sh`,
# with the whole MONITOR_REMOTE_*/NEXUS_* environment stripped — rather than
# under the bash that happens to run this suite. A helper that silently needed
# bash, or needed the operator's config, would pass a bash-only probe and fail
# on the client where it actually runs.
client_port() {
    env -u NEXUS_ROOT -u NEXUS_CONFIG -u MONITOR_REMOTE_PORT \
        -u MONITOR_REMOTE_BIND_ADDRESS -u MONITOR_REMOTE_OPERATOR_IDENTITY \
        sh -c ". '$CLI_LIB' >/dev/null 2>&1 || exit 9; _nexus_derived_port \"\$1\"" _ "$1"
}
server_port() {
    MONITOR_REMOTE_OPERATOR_IDENTITY="$1" \
        bash -c "source '$SRV_LIB'; _remote_derived_port"
}

# ===========================================================================
echo "== 1. the two implementations agree, identity by identity =="
# A spread of shapes: ordinary logins, the two identities actually on this host,
# single characters, digits, a long name, punctuation that a unix account can
# legally carry, and the band-edge case that motivated the base (cksum%900==0).
IDS=( operator operator alice bob carol dave erin frank grace heidi
      your-org a z 0 9 ab ba aa zz
      averyverylongoperatorloginname user-with-dash user_with_underscore
      user.with.dot User Mixed123 x1 x2 x3 )
disagree=0
for id in "${IDS[@]}"; do
    s=$(server_port "$id"); c=$(client_port "$id")
    if [[ "$s" != "$c" ]]; then
        printf '        DISAGREE id=%q server=%q client=%q\n' "$id" "$s" "$c" >&2
        disagree=$(( disagree + 1 ))
    fi
done
assert_eq "all ${#IDS[@]} identities derive identically on both sides" "$disagree" "0"

# NON-VACUITY. Without this the loop above passes if BOTH sides return empty —
# e.g. the client helper failed to load under sh (rc 9) and the server function
# was renamed. An agreement test that agrees on nothing is the emptiness trap
# this repo keeps re-learning, and it belongs here more than most.
sample=$(client_port operator)
assert_eq "the client helper actually PRODUCED a port under POSIX sh (not empty/rc9)" \
    "$([[ "$sample" =~ ^[0-9]+$ ]] && echo numeric || echo "NOT-NUMERIC:$sample")" "numeric"
# NOTE (public mirror): the identity above is the scrubbed placeholder, so the
# derived value differs from the source tree's. 22100 + cksum(operator) % 900
# = 22909; the band base 22100 below is unrelated and unchanged.
assert_eq "…and it is the known value for this operator's account" "$sample" "22909"
assert_eq "…the server agrees on that same known value" "$(server_port operator)" "22909"

# The band, asserted on the CLIENT side too — the client is where a wrong band
# would send a connection to a stranger.
inband=yes
for id in "${IDS[@]}"; do
    p=$(client_port "$id")
    [[ "$p" =~ ^[0-9]+$ ]] || { inband="non-numeric:$id:$p"; break; }
    (( p >= 22100 && p < 23000 )) || { inband="out-of-band:$id:$p"; break; }
    (( p == 22022 || p == 22080 )) && { inband="hit-known-occupied:$id:$p"; break; }
done
assert_eq "client-derived ports all land in [22100,23000), never 22022/22080" "$inband" "yes"

# ===========================================================================
echo "== 2. the client NEVER falls back to a constant =="
# The defect F1 records: a HOST with no PORT silently became 22022, which on a
# shared node is another operator's endpoint. The rule now is derive-or-refuse.
resolve() {  # <env assignments…> → "<rc>|<SSH_ID>"
    env -u NEXUS_ROOT -u NEXUS_CONFIG "$@" \
        sh -c ". '$CLI_LIB' >/dev/null 2>&1 || exit 9
               PROG=t ssh_alias=the-alias
               if resolve_ssh_id 2>/dev/null; then printf '0|%s' \"\$SSH_ID\"; else printf '%s|%s' \"\$?\" \"\${SSH_ID:-}\"; fi"
}

out=$(resolve NEXUS_REMOTE_SSH_HOST=example.invalid NEXUS_REMOTE_SSH_USER=operator)
assert_eq       "HOST+USER, no PORT ⇒ resolves (rc 0)" "${out%%|*}" "0"
assert_contains "…at the DERIVED port, not a constant" "$out" "-p 22909"
assert_not_contains "…and never at the old shared constant" "$out" "-p 22022"

out=$(resolve NEXUS_REMOTE_SSH_HOST=example.invalid NEXUS_REMOTE_SSH_USER=alice)
assert_contains "a DIFFERENT operator derives a different client port" "$out" "-p 22532"

# THE FAIL-LOUD ARM: no USER ⇒ the port cannot be derived ⇒ refuse. Guessing
# here is a connection attempt against whoever holds the guessed port.
out=$(resolve NEXUS_REMOTE_SSH_HOST=example.invalid)
assert_eq       "HOST, no PORT, no USER ⇒ REFUSES (non-zero)" \
    "$([[ "${out%%|*}" != "0" ]] && echo refused || echo "ACCEPTED:$out")" "refused"
assert_not_contains "…and emits NO connection args at all" "$out" "-p "

# An explicit port is always honoured verbatim — derivation is a DEFAULT, and
# an operator who moved off the derived port (a residual collision, #637) must
# still be reachable.
out=$(resolve NEXUS_REMOTE_SSH_HOST=example.invalid NEXUS_REMOTE_SSH_USER=operator NEXUS_REMOTE_SSH_PORT=41234)
assert_contains "an explicit PORT still wins over derivation" "$out" "-p 41234"
out=$(resolve NEXUS_REMOTE_SSH_HOST=example.invalid NEXUS_REMOTE_SSH_PORT=41234)
assert_contains "…even with no USER (explicit beats derivable)" "$out" "-p 41234"

# The ssh-alias path is untouched: no HOST ⇒ the alias, no port logic at all.
out=$(resolve)
assert_eq "no HOST ⇒ the ssh-config alias path, unchanged" "$out" "0|the-alias"

# ===========================================================================
# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
#   5  section 1 (agreement, non-vacuity x3, band)
# + 9  section 2 (derive x3, different-operator, refuse x2, explicit x2, alias)
EXPECTED=$(( 5 + 9 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
