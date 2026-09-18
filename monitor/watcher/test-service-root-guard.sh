#!/usr/bin/env bash
# Tests for `svcroot_guard` (monitor/_service_root.sh) and its wiring into
# monitor/remote-up.sh — your-org/nexus-code#1034 recommendation 3, "refuse at
# the source": a supervised-service ACTIVATION helper must decline to enable a
# service from a tree that is not $NEXUS_ROOT, or from an ephemeral directory.
#
#   1. POSITIVE CONTROL — a primary-shaped tree is ALLOWED (rc 0). This is the
#      load-bearing one: the live `nexus-remote-ssh` service is brought up by
#      exactly this call, so an over-refusing guard breaks production.
#   1b. POSITIVE CONTROL — the operator's REAL primary path pair is allowed.
#      A fixture proves the shape; only the real paths prove the real call.
#   2. MODE B (clone launcher, primary NEXUS_ROOT) → REFUSED, R1 IDENTITY.
#      The mode a first draft of the guard let through: it used a CONTAINMENT
#      test, and a secondary clone at `<primary>/work/<clone>` IS contained in
#      the primary. Measured, then fixed to an equality test.
#   3. MODE A (clone is its own NEXUS_ROOT) → REFUSED, R2 PRIMACY. Satisfies
#      R1 by construction, so R1 alone cannot see it.
#   4. EPHEMERAL root that is NOT a clone → REFUSED, R3 DURABILITY. Isolates
#      R3 from R1/R2 (a /tmp tree with no `/work/` ancestor).
#   5. Unresolvable NEXUS_ROOT → rc 3, "could not determine" — fail-closed, and
#      distinct from rc 2 so a caller can tell a violation from a blind spot.
#   6. NEXUS_ALLOW_SECONDARY_ROOT=1 → rc 0, AND the refusal is still PRINTED.
#      Both halves are asserted: an override that silences its own diagnosis is
#      the CLAUDE.md allowlist-doctrine defect (a SAFE arm returning before the
#      DENY arms, whose text is the only thing the operator can act on).
#   7. INTEGRATION — the real monitor/remote-up.sh, EXECUTED, against a
#      NEXUS_ROOT it must refuse: refuses at the ROOT guard specifically (not
#      at a later gate), and writes NO registry row. Runs against a SCRATCH
#      registry AND a principals_dir that the NEXT, independent gate would also
#      refuse — a test that is only safe when the code under test is correct is
#      not a safe test.
#   8. `--down` is NOT gated: retirement must keep working from anywhere, or
#      the guard strands the state it exists to prevent.
#   9. An EXPLICIT $NEXUS_SERVICES_REGISTRY takes the guard out of scope — the
#      hermetic-harness convention — announced rather than silent, and asserted
#      as a PAIR with the same paths minus the variable, so the exemption is
#      shown to be NARROW and not a general bypass.
#
# Starts no daemon and signals no process.
#
# Run: bash monitor/watcher/test-service-root-guard.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
REPO_ROOT=$(cd "$MON_DIR/.." && pwd)
LIB="$MON_DIR/_service_root.sh"
UP="$MON_DIR/remote-up.sh"

[[ -f "$LIB" ]] || { echo "FATAL: $LIB missing"; exit 1; }

# TWO fixture roots, and the split is the R3 test rather than a convenience.
# $DWORK must be DURABLE: a fixture under /tmp is itself ephemeral, so building
# the POSITIVE CONTROL there makes R3 fire on it and the control fails for a
# reason that has nothing to do with the property under test. (It did — the
# first version of this suite put every fixture under `mktemp -t` and case 1
# went red.) $HOME/.claude is the workspace's durable, owner-only scratch, the
# same directory the remote suites pin their credential fixtures to.
DWORK=$(mktemp -d "$HOME/.claude/svcroot-fixture-XXXXXX") || { echo "FATAL: mktemp (durable)"; exit 1; }
EWORK=$(mktemp -d -t nexus-svcroot-XXXXXX)                || { echo "FATAL: mktemp (ephemeral)"; exit 1; }
trap 'rm -rf "$DWORK" "$EWORK"' EXIT

# Assert the split is real before any conclusion rests on it: if $DWORK were
# somehow under /tmp, case 1 and case 4 would be testing the same thing and the
# suite would be green for the wrong reason.
case "$DWORK" in /tmp/*|/var/tmp/*) echo "FATAL: durable fixture landed under /tmp: $DWORK"; exit 1 ;; esac
case "$EWORK" in /tmp/*|/var/tmp/*) ;; *) echo "FATAL: ephemeral fixture is not under /tmp: $EWORK"; exit 1 ;; esac

# A tree that `_svcroot_is_nexus` accepts: executable monitor/spawn-worker.sh
# plus a config/ dir. Nothing else about a nexus is needed by the predicate,
# and the predicate is shared verbatim with spawn-worker.sh's `_sw_root_is_nexus`.
mk_nexus() {
    local d="$1"
    mkdir -p "$d/monitor" "$d/config"
    printf '#!/bin/sh\nexit 0\n' > "$d/monitor/spawn-worker.sh"
    chmod +x "$d/monitor/spawn-worker.sh"
}

# Sourced ONCE here, at the top level, with a statically resolvable path.
# The first version sourced it inside `bash -c 'source "$1" …'`, which reads
# identically at runtime and is opaque to the static source graph — it added
# `watcher/test-service-root-guard.sh\t$1` to
# `test-ambient-shell-option-scope`'s unresolved-token set and turned that lint
# red. Sourcing here needs no manifest entry, which is the better outcome: a
# manifest line records a blind spot, and not having one is preferable to
# recording one.
. "$LIB"

# Run the guard in a SUBSHELL, capturing stdout+stderr and the rc separately.
# A subshell is enough — `svcroot_guard` only ever `return`s — and it contains
# the per-case env overrides so they cannot leak into the next case.
# `out=$(...)` then `rc=$?` on the NEXT line: never `"$(cmd)" "$?"` in one
# argument list, which destroys the status before it is read (CLAUDE.md
# PRINTF-STATUS-CLOBBER).
guard() {  # guard <script-dir> <root> [VAR=value ...]
    local sd="$1" rt="$2"; shift 2
    GUARD_OUT=$(
        local kv
        # Cases 1-6 test the INFERRED-registry rules, so the explicit-registry
        # scope exemption must be OFF unless a case turns it on. Inheriting one
        # from the caller's environment would exempt every case and turn this
        # whole suite green for a reason none of it is about.
        unset NEXUS_SERVICES_REGISTRY
        for kv in "$@"; do export "${kv?}"; done
        SVCROOT_TAG=remote-up SVCROOT_VERB=remote-up.sh svcroot_guard "$sd" "$rt" 2>&1
    )
    GUARD_RC=$?
    return 0
}

# ── fixtures ─────────────────────────────────────────────────────────────
PRIMARY="$DWORK/primary"          # durable: the positive control
mk_nexus "$PRIMARY"
CLONE="$PRIMARY/work/nc-clone"    # durable: isolates R1/R2 from R3
mk_nexus "$CLONE"
LONE="$EWORK/standalone"          # ephemeral, and no `/work/` ancestor: isolates R3
mk_nexus "$LONE"

echo "== 1. POSITIVE CONTROL: a primary-shaped tree is ALLOWED =="
guard "$PRIMARY/monitor" "$PRIMARY"
assert_eq "primary tree → rc 0" "$GUARD_RC" "0"
assert_eq "primary tree → silent" "$GUARD_OUT" ""

echo "== 1b. POSITIVE CONTROL: the operator's REAL primary paths are ALLOWED =="
# Derive the primary from THIS checkout rather than hard-coding it: this suite
# runs in clones and worktrees, and a hard-coded operator path is a count
# without a ref. If this checkout IS the primary, that is the pair under test;
# if it is a clone, walk to the primary the same way the guard does.
REAL_PRIMARY="$REPO_ROOT"
case "$REPO_ROOT" in
    */work/*)
        _cand="${REPO_ROOT%/work/*}"
        [[ -x "$_cand/monitor/spawn-worker.sh" && -d "$_cand/config" ]] && REAL_PRIMARY="$_cand"
        ;;
esac
# THE ENVIRONMENT IS DETECTED AND NAMED, NOT ASSERTED PAST (your-org/nexus-code#1445).
# Case 4 below asserts that the guard REFUSES an EPHEMERAL root — a tree under
# /tmp — because a supervisor launched from one outlives its own directory.
# That rule is correct, and it makes this positive control unsatisfiable by
# construction whenever THIS CHECKOUT is itself under /tmp: a scratch worktree
# (the prescribed way to run a suite against another ref) is exactly such a
# tree, so `real primary -> rc 0` read `got 2 want 0` on every local band run
# from one and was filed as an inherited red. A red that means "wrong
# environment" is not honest; a SKIP that says why is.
if [[ "$REAL_PRIMARY" == /tmp/* || "$REAL_PRIMARY" == /var/tmp/* ]]; then
    th_skip "real primary → rc 0" "this checkout ($REAL_PRIMARY) is under /tmp — an EPHEMERAL root, which the guard refuses by design (case 4); run this control from a durable checkout"
elif [[ -x "$REAL_PRIMARY/monitor/spawn-worker.sh" && -d "$REAL_PRIMARY/config" ]]; then
    guard "$REAL_PRIMARY/monitor" "$REAL_PRIMARY"
    assert_eq "real primary ($REAL_PRIMARY) → rc 0" "$GUARD_RC" "0"
else
    # th_skip, not a bare echo: a skip must still COUNT, or the declared-count
    # guard at the foot of this file would read one number on a host where this
    # arm runs and another where it does not.
    th_skip "real primary → rc 0" "no primary-shaped tree derivable from $REPO_ROOT"
fi

echo "== 2. MODE B: clone launcher + PRIMARY NEXUS_ROOT is REFUSED (R1 IDENTITY) =="
guard "$CLONE/monitor" "$PRIMARY"
assert_eq "mode B → rc 2" "$GUARD_RC" "2"
assert_contains "mode B names R1 IDENTITY" "$GUARD_OUT" "R1 IDENTITY"
assert_contains "mode B names the primary's copy to run" "$GUARD_OUT" "$PRIMARY/monitor/remote-up.sh"
# R2 must NOT fire here: NEXUS_ROOT is the primary. A rule that fires on
# everything diagnoses nothing.
case "$GUARD_OUT" in *"R2 PRIMACY"*) assert_eq "mode B must not trip R2" "tripped" "not-tripped" ;;
                     *) assert_eq "mode B does not trip R2" "not-tripped" "not-tripped" ;; esac

echo "== 3. MODE A: clone is its OWN NEXUS_ROOT is REFUSED (R2 PRIMACY) =="
guard "$CLONE/monitor" "$CLONE"
assert_eq "mode A → rc 2" "$GUARD_RC" "2"
assert_contains "mode A names R2 PRIMACY" "$GUARD_OUT" "R2 PRIMACY"
assert_contains "mode A names the primary" "$GUARD_OUT" "$PRIMARY"
# R1 must NOT fire: launcher tree and root are the same clone. This is exactly
# why R1 alone cannot see mode A.
case "$GUARD_OUT" in *"R1 IDENTITY"*) assert_eq "mode A must not trip R1" "tripped" "not-tripped" ;;
                     *) assert_eq "mode A does not trip R1" "not-tripped" "not-tripped" ;; esac

echo "== 4. EPHEMERAL root (not a clone) is REFUSED (R3 DURABILITY) =="
# $EWORK is under /tmp (mktemp -t), and $LONE has no `/work/` ancestor, so R1
# and R2 both pass and R3 is the only rule that can fire.
guard "$LONE/monitor" "$LONE"
assert_eq "ephemeral root → rc 2" "$GUARD_RC" "2"
assert_contains "ephemeral names R3 DURABILITY" "$GUARD_OUT" "R3 DURABILITY"
assert_contains "ephemeral points at svc.sh orphans" "$GUARD_OUT" "svc.sh orphans"

echo "== 5. an unresolvable NEXUS_ROOT is rc 3 (could not determine), not rc 2 =="
guard "$PRIMARY/monitor" "$EWORK/no-such-root-anywhere"
assert_eq "unresolvable → rc 3" "$GUARD_RC" "3"
assert_contains "unresolvable says so" "$GUARD_OUT" "could not resolve a physical path"

echo "== 6. the override allows — and still PRINTS what it overrode =="
guard "$CLONE/monitor" "$CLONE" NEXUS_ALLOW_SECONDARY_ROOT=1
assert_eq "override → rc 0" "$GUARD_RC" "0"
assert_contains "override still prints the rule it bypassed" "$GUARD_OUT" "R2 PRIMACY"
assert_contains "override announces itself" "$GUARD_OUT" "OVERRIDDEN by NEXUS_ALLOW_SECONDARY_ROOT=1"

echo "== 7. INTEGRATION: the real remote-up.sh cmd_up refuses from a clone =="
# The guard is the FIRST executable statement in cmd_up, so a refusal proves no
# later step — port selection, host-key generation, registration, supervisor
# launch — ran.
# NO NEXUS_SERVICES_REGISTRY here — case 9 shows that variable takes the guard
# out of scope, so setting it would make this case exercise the exemption
# instead of the guard. It did: an earlier version set it, and the refusal came
# from the principals gate two lines further down. The blast radius is bounded
# WITHOUT it: NEXUS_ROOT is an ephemeral fixture, so the registry the script
# would infer is `$LONE/monitor/services.registry` — inside the fixture, never
# the operator's — and MONITOR_REMOTE_PRINCIPALS_DIR points outside
# $HOME/.claude, which `_remote_principals_guard` (the NEXT, independent gate in
# cmd_up) refuses. A test that is only safe when the code under test is correct
# is not a safe test.
INFERRED_REG="$LONE/monitor/services.registry"
rm -f "$INFERRED_REG"
INT_OUT=$(env -u NEXUS_SERVICES_REGISTRY \
          NEXUS_ROOT="$LONE" \
          MONITOR_REMOTE_PRINCIPALS_DIR="$EWORK/not-under-dot-claude" \
          bash "$UP" 2>&1)
INT_RC=$?
case "$INT_RC" in 0) assert_eq "integration: cmd_up must NOT succeed from a foreign root" "rc=0" "rc!=0" ;;
                  *) assert_eq "integration: cmd_up refused (rc=$INT_RC)" "rc!=0" "rc!=0" ;; esac
assert_contains "integration: the refusal came from the ROOT guard, not a later one" "$INT_OUT" "R1 IDENTITY"
assert_contains "integration: it names the service it declined to enable" "$INT_OUT" "refusing to enable"
assert_no_file "integration: NO registry row was written" "$INFERRED_REG"

echo "== 8. --down is NOT gated (retirement must work from anywhere) =="
# Static: cmd_down's body must not call svcroot_guard. Gating retirement would
# strand exactly the orphan this guard exists to prevent.
DOWN_BODY=$(awk '/^cmd_down\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UP")
# A body of zero bytes would make the "not gated" assertion below vacuously
# true — the awk extraction is asserted before anything is concluded from it.
case "$(printf '%s' "$DOWN_BODY" | wc -c | tr -d ' ')" in
    0) assert_eq "cmd_down body extracted" "empty" "non-empty" ;;
    *) assert_eq "cmd_down body extracted" "non-empty" "non-empty" ;; esac
case "$DOWN_BODY" in *svcroot_guard*) assert_eq "cmd_down must not gate" "gated" "ungated" ;;
                     *) assert_eq "cmd_down is ungated" "ungated" "ungated" ;; esac
# …and cmd_up MUST call it, or every case above tests a function nothing uses.
UP_BODY=$(awk '/^cmd_up\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$UP")
assert_contains "cmd_up calls svcroot_guard" "$UP_BODY" "svcroot_guard"

echo "== 9. an EXPLICIT NEXUS_SERVICES_REGISTRY takes the guard out of scope =="
# The hermetic-harness convention: name the registry, use a temp root. Both
# rules that would otherwise fire here (R2 PRIMACY on the clone root, R3 on an
# ephemeral one) are about an INFERRED registry, so an explicit one is out of
# scope — and it is ANNOUNCED, never silent. Without this exemption seven
# `test-remote-*` suites go red; `test-remote-service.sh` was measured at 59/6.
guard "$CLONE/monitor" "$CLONE" NEXUS_SERVICES_REGISTRY="$EWORK/explicit.registry"
assert_eq "explicit registry → rc 0" "$GUARD_RC" "0"
assert_contains "the exemption is announced, not silent" "$GUARD_OUT" "NEXUS_SERVICES_REGISTRY is set explicitly"
# …and it must NOT be a general bypass: with the SAME paths and no explicit
# registry, the refusal stands. Asserted as a PAIR, because an exemption tested
# only in its permissive direction cannot be shown to be narrow.
guard "$CLONE/monitor" "$CLONE"
assert_eq "same paths WITHOUT the explicit registry → still rc 2" "$GUARD_RC" "2"

# COUNT GUARD (your-org/nexus-code#821 / #1308). The per-assertion ledger proves
# no assertion was LOST in a subshell; it cannot prove one was never REACHED. A
# suite whose arms stop running still prints a green summary of whatever DID
# run — and that is the exact failure this file's own subject matter is about,
# so it would be poor form to omit it here. Declared exactly; a mismatch is red.
EXPECTED_ASSERTIONS=29
_run_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
