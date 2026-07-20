#!/usr/bin/env bash
# Tests for the public-template disable switch (monitor/_public-guard.sh).
#
# Closes the coverage gap in nexus-code#520: after #519 unlocked the guard for
# the hermetic unit suite (NEXUS_PUBLIC_ENABLED=1), NOTHING asserted the guard's
# *refusal* path — that with the unlock variable UNSET the guarded operation is
# refused (the disable switch fires). A guard whose refusal path is untested can
# be silently defeated by a future edit with no test catching it.
#
# DUAL-TREE by design. `monitor/_public-guard.sh` is bootstrap state that ships
# ONLY in the public mirror (it is not produced by the scrub toolkit and does
# not exist in the source repo). So:
#   - source tree (no guard file present): the test SKIPS and exits 0, keeping
#     the source CI green (there is no shipped guard to exercise here).
#   - public mirror (guard file present): the test exercises the REAL shipped
#     guard — refusal when the unlock is unset/empty/non-1, allow when it is 1.
# This is the mirror-side assertion nexus-code#520 asks for, authored on the
# source side so it flows to the mirror through the normal scrub + sync and runs
# under the mirror's `tests.yml` unit suite.
#
# Hermetic: derives every path from this script's own location, uses no network,
# and depends on NO ambient env (it explicitly unsets/sets the unlock variable
# per case), so it passes on a bare $NEXUS_ROOT too (reference_sandbox_env_masks_ci).
#
# Run: bash monitor/watcher/test-public-guard-refusal.sh
# Expected: ALL TESTS PASSED on stdout (or SKIPPED on a source tree), exit 0.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_root=$(cd "$_test_dir/../.." && pwd)
GUARD="$_root/monitor/_public-guard.sh"

# Source-tree skip: the guard ships only in the public mirror.
if [[ ! -r "$GUARD" ]]; then
    echo "SKIP: monitor/_public-guard.sh absent — guard ships only in the public"
    echo "      mirror (bootstrap state, not produced by the scrub toolkit). The"
    echo "      refusal assertion runs against the real shipped guard on the mirror."
    echo
    echo "ALL TESTS PASSED (0 checks — skipped on source tree)"
    exit 0
fi

pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# Invoke the guard in a clean subshell with the unlock variable in a chosen
# state. `env -u`/`env NAME=` fully control the variable regardless of what the
# ambient CI env (e.g. _test_helpers.sh exporting =1) has set — the whole point
# is to prove the refusal path independent of any inherited unlock.
run_guard(){ # $1 = env spec: 'unset' | '' | '0' | '1' | 'yes'
    local spec="$1"
    if [[ "$spec" == unset ]]; then
        env -u NEXUS_PUBLIC_ENABLED bash -c 'source "$1"; nexus_public_guard' _ "$GUARD" 2>&1
    else
        env "NEXUS_PUBLIC_ENABLED=$spec" bash -c 'source "$1"; nexus_public_guard' _ "$GUARD" 2>&1
    fi
}
rc_of(){ run_guard "$1" >/dev/null 2>&1; echo $?; }

# --- refusal path: the load-bearing nexus-code#520 assertion --------------
# 1. unlock UNSET -> refuse (non-zero) with the disable message on stderr.
out=$(run_guard unset); rc=$?
[[ $rc -ne 0 ]] && ok "refuses (exit $rc) when NEXUS_PUBLIC_ENABLED is unset" \
                || no "did NOT refuse with the unlock unset (exit 0) — guard defeated"
printf '%s' "$out" | grep -qi 'nexus is disabled' \
    && ok "prints the 'nexus is disabled' refusal message on stderr" \
    || no "refusal message missing/changed: $out"

# 2. unlock present but NOT exactly '1' -> still refuse (the guard tests ==1).
[[ "$(rc_of '')"    -ne 0 ]] && ok "refuses on empty NEXUS_PUBLIC_ENABLED="      || no "empty unlock did not refuse"
[[ "$(rc_of '0')"   -ne 0 ]] && ok "refuses on NEXUS_PUBLIC_ENABLED=0"           || no "unlock=0 did not refuse"
[[ "$(rc_of 'yes')" -ne 0 ]] && ok "refuses on a non-1 truthy-looking value"     || no "unlock=yes did not refuse"

# --- allow path: the complement, so both directions are covered -----------
# 3. unlock == '1' -> allow (exit 0), no refusal message.
out1=$(run_guard '1'); rc1=$?
[[ $rc1 -eq 0 ]] && ok "allows (exit 0) when NEXUS_PUBLIC_ENABLED=1" \
                 || no "refused even with the unlock set to 1 (exit $rc1): $out1"
printf '%s' "$out1" | grep -qi 'nexus is disabled' \
    && no "emitted the refusal message on the allow path: $out1" \
    || ok "no refusal message on the allow path"

# 4. sourcing is side-effect-free (only defines the function; does not fire).
src=$(env -u NEXUS_PUBLIC_ENABLED bash -c 'source "$1"; echo SOURCED_OK' _ "$GUARD" 2>&1); src_rc=$?
[[ $src_rc -eq 0 && "$src" == *SOURCED_OK* ]] \
    && ok "sourcing the guard is side-effect-free (does not exit on load)" \
    || no "sourcing the guard had a side effect (rc=$src_rc): $src"

echo
if [[ $fail -eq 0 ]]; then
    echo "ALL TESTS PASSED ($pass checks)"
    exit 0
else
    echo "FAILED ($fail of $((pass+fail)) checks)"
    exit 1
fi
