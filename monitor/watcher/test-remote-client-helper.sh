#!/usr/bin/env bash
# Tests for `ng remote client-helper` + the client-helper SET coupling.
#
# TWO DEFECTS, both found by a real remote client reporting its own setup state.
#
# DEFECT 1 — THE STALE DIGEST, AND BOTH SIDES AGREE ON IT. The helper delivery
# flow had the orchestrator recite a sha256 to the client BY HAND, out-of-band.
# A literal digest is correct when written and wrong from the next commit
# onward, and the failure is silent in both directions: the client verifies the
# copy it received against the stale value it was given, the two match, and the
# client confidently installs an old helper. Measured: a client reported
# matching a digest whose blob was FOUR revisions behind the shipped one, and
# reported the verification as successful. Nothing errored, on either side.
#
# The defect is the LITERAL, not the client — so the fix deletes literals. This
# verb hashes the files that exist right now, at call time. Test 8 is the
# regression guard that keeps the literals out of the docs.
#
# DEFECT 1b — WHAT A DIGEST ESTABLISHES. The client itself raised this: it
# treated the matching hash as proof of TRANSIT INTEGRITY ONLY, not of
# benignity, "since you supplied both the file and the hash". Correct, and the
# flow did not say so — a "verify the sha256" step reads as a safety check and
# is widely treated as one. Test 7 pins the honest wording into the verb's own
# output, where a client actually reads it.
#
# DEFECT 2 — THE HELPER IS A SET, DELIVERED AS "one file". nexus-request and
# nexus-reply-watch both `.`-source _nexus_watch_lib.sh from beside themselves
# (they converged on one watch-loop core); CLIENT.md described the delivery as
# "the one small POSIX-sh script". A client following that literally installs
# one file and gets a helper that cannot run.
#
#   The failure mode was checked BEFORE designing a fix, and the scope of the
#   claim follows what was measured: it is LOUD — it names the exact missing
#   path — so the defect is in the DELIVERY and the DOCS, not in the script's
#   behaviour. But measuring it turned up a second, real defect: the designed
#   `|| { …; exit 64; }` arm is DEAD CODE on the interpreter these scripts
#   declare. POSIX makes a `.` that cannot find its file abort a
#   non-interactive shell, so under `#!/bin/sh` (dash on this host) the shell
#   dies at the dot with rc 2 and the arm never runs; only bash reaches it.
#   Measured, same lonely install: bash rc=64, dash rc=2. Test 9 is the
#   interpreter matrix that keeps the designed exit code reachable on the
#   declared interpreter, with the whole-set negative control beside it.
#
#   1. the manifest names every member of the set
#   2. its digests equal an INDEPENDENTLY computed sha256 (cross-tool)
#   3. digests are computed AT CALL TIME (mutate a fixture → manifest moves),
#      with the mutation PROVEN applied before the conclusion is drawn
#   4. fail-closed: a missing member is rc 2, never a shorter manifest
#   5. --base64 round-trips into a real install
#   6. --verify catches divergence AND absence (rc 3), with an ok control
#   7. the manifest states what the digest does NOT establish
#   8. no shipped doc quotes a literal digest — probe potency proven first
#   9. the SET coupling: lonely install exits 64 on bash AND dash AND sh
#
# Run: bash monitor/watcher/test-remote-client-helper.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

REPO=$(cd "$_test_dir/../.." && pwd)
MON="$REPO/monitor"
HELPER="$MON/remote-client-helper.sh"
NG="$MON/ng"

[[ -x "$HELPER" ]] || th_abort "missing $HELPER"

WORK=$(mktemp -d "/tmp/tt-$$-clienthelper.XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
# HERMETIC (your-org/nexus-code#1336): the `ng remote client-helper` calls below
# resolve `ng`'s state dir through the INHERITED root, and its usage tap
# appended `monitor/.state/ng-usage.jsonl` there — measured on CI's exported
# band (two rows attributed to this suite by `src`, run 33861331066) and LEAK
# rc=0 under `nexus-root-sensitivity.sh probe` locally. The suite sat OUTSIDE
# the band's spelling-derived population, which is how it stayed green while
# writing into the operator's live state. Pinned, and verified to have taken.
th_pin_ng_state "$NG" "$WORK/ng-state"

MEMBERS=(nexus-request nexus-reply-watch _nexus_watch_lib.sh)

# ── 1. the manifest names every member ────────────────────────────────
echo "== 1. the manifest names every member of the set"
man=$("$HELPER" 2>&1); rc=$?
assert_eq "manifest exits 0" "$rc" "0"
for m in "${MEMBERS[@]}"; do
    assert_contains "manifest lists $m" "$man" "$m"
done
# The COUNT is asserted too: "lists the three I asked about" is satisfied by a
# manifest that also silently lists a fourth. The set handed to a remote client
# must be a decision, not a directory listing.
listed=$("$HELPER" --files | wc -l | tr -d ' ')
assert_eq "the set is exactly ${#MEMBERS[@]} files" "$listed" "${#MEMBERS[@]}"

# ── 2. digests equal an independently computed value ──────────────────
echo "== 2. manifest digests match an INDEPENDENTLY computed sha256"
# Cross-check against a different tool invocation than the one the script
# picked. Agreement here is meaningful because the two sides are computed by
# different code paths over the same bytes.
for m in "${MEMBERS[@]}"; do
    indep=$(sha256sum "$MON/client/$m" | awk '{print $1}')
    assert_contains "manifest carries the true digest of $m" "$man" "$indep"
done

# ── 3. digests are computed AT CALL TIME ──────────────────────────────
echo "== 3. digests are recomputed per call (the whole point of the verb)"
FIX="$WORK/fixture"
mkdir -p "$FIX/client"
cp "$HELPER" "$FIX/"
cp "$MON/client/"* "$FIX/client/"
# Field-exact extraction: the manifest ROW, not any prose line that happens to
# name the file (the row is `<name> <bytes> bytes sha256 <hex>`).
_digest_of() { awk -v n="$2" '$1==n && $4=="sha256" {print $5}' "$1"; }
"$FIX/remote-client-helper.sh" > "$WORK/man-before.txt"
before=$(_digest_of "$WORK/man-before.txt" nexus-reply-watch)
# PROVE THE MUTATION APPLIED before drawing any conclusion from what follows —
# a "the digest changed" test passes just as well if nothing was mutated and
# the two runs simply disagreed for another reason.
sz_before=$(wc -c < "$FIX/client/nexus-reply-watch")
printf '\n# fixture mutation\n' >> "$FIX/client/nexus-reply-watch"
sz_after=$(wc -c < "$FIX/client/nexus-reply-watch")
if (( sz_after > sz_before )); then
    _th_pass; echo "  PASS: mutation applied ($sz_before -> $sz_after bytes)"
else
    _th_fail; echo "  FAIL: mutation did NOT apply — test 3's conclusion would be vacuous"
fi
"$FIX/remote-client-helper.sh" > "$WORK/man-after.txt"
after=$(_digest_of "$WORK/man-after.txt" nexus-reply-watch)
if [[ "$before" =~ ^[0-9a-f]{64}$ && "$after" =~ ^[0-9a-f]{64}$ && "$before" != "$after" ]]; then
    _th_pass; echo "  PASS: digest tracked the mutated bytes"
else
    _th_fail; echo "  FAIL: digest did not move (before=$before after=$after)"
fi

# ── 4. fail-closed on a missing member ────────────────────────────────
echo "== 4. a missing member is REFUSED, never a shorter manifest"
rm -f "$FIX/client/_nexus_watch_lib.sh"
out=$("$FIX/remote-client-helper.sh" 2>&1); rc=$?
assert_eq "missing member → rc 2" "$rc" "2"
assert_contains "names the missing member" "$out" "_nexus_watch_lib.sh"
assert_contains "refuses a partial manifest" "$out" "partial manifest"
assert_not_contains "emits NO digest line" "$out" "sha256 "

# ── 5. --base64 round-trips into a real install ───────────────────────
echo "== 5. --base64 round-trips"
INST="$WORK/install"
mkdir -p "$INST"
"$HELPER" --base64 > "$INST/block.txt" 2>&1
sed -n '1,/^chmod 600/p' "$INST/block.txt" > "$INST/run.sh"
( cd "$INST" && sh run.sh >/dev/null 2>&1 )
for m in "${MEMBERS[@]}"; do
    assert_file_exists "round-trip produced $m" "$INST/nexus-helpers/$m"
done
# modes: the two scripts must land executable, or the client's first invocation
# fails for a reason that has nothing to do with the channel.
for m in nexus-request nexus-reply-watch; do
    if [[ -x "$INST/nexus-helpers/$m" ]]; then
        _th_pass; echo "  PASS: $m is executable after round-trip"
    else
        _th_fail; echo "  FAIL: $m NOT executable after round-trip"
    fi
done

# ── 6. --verify: divergence, absence, and an ok control ───────────────
echo "== 6. --verify catches divergence and absence"
out=$("$HELPER" --verify "$INST/nexus-helpers" 2>&1); rc=$?
assert_eq "a faithful install verifies clean (control)" "$rc" "0"
assert_contains "and says so per file" "$out" "ok"

printf '\n# drift\n' >> "$INST/nexus-helpers/nexus-request"
out=$("$HELPER" --verify "$INST/nexus-helpers" 2>&1); rc=$?
assert_eq "a diverged install → rc 3" "$rc" "3"
assert_contains "names the diverged file" "$out" "DIVERGED"

rm -f "$INST/nexus-helpers/_nexus_watch_lib.sh"
out=$("$HELPER" --verify "$INST/nexus-helpers" 2>&1); rc=$?
assert_eq "a missing file → rc 3" "$rc" "3"
assert_contains "names it MISSING" "$out" "MISSING"

# ── 7. the honesty paragraph ──────────────────────────────────────────
echo "== 7. the manifest says what the digest does NOT establish"
assert_contains "states it is not an authentication" "$man" "NOT an authentication"
assert_contains "states transit-only"                "$man" "SURVIVED TRANSIT"
assert_contains "states nothing about benignity"     "$man" "benign"
assert_contains "puts review on the client"          "$man" "YOUR job"

# ── 8. no shipped doc quotes a literal digest ─────────────────────────
echo "== 8. the docs quote NO literal digest (the defect was the literal)"
DOCS=(
    "$REPO/docs/operating/remote-access-quickstart.md"
    "$REPO/skills/nexus.remote-access/SKILL.md"
    "$REPO/skills/nexus.remote-access/CLIENT.md"
    "$REPO/skills/nexus.remote-access/RUNBOOK.md"
)
# PROVE THE PROBE IS POTENT FIRST. A grep that finds nothing is indistinguishable
# from a grep that cannot see — this repo's dominant defect class. Plant a
# literal and confirm the probe fires on it before believing any zero.
plant="$WORK/planted.md"
printf 'the helper sha256 is %s\n' \
    "9c5dacdb319d0000000000000000000000000000000000000000000000000000" > "$plant"
if grep -qE '[0-9a-f]{64}' "$plant"; then
    _th_pass; echo "  PASS: probe is potent (fires on a planted literal)"
else
    _th_fail; echo "  FAIL: probe is BLIND — every zero below would be meaningless"
fi
for d in "${DOCS[@]}"; do
    [[ -r "$d" ]] || { _th_fail_missing; echo "  FAIL: unreadable doc $d"; continue; }
    hits=$(grep -oE '[0-9a-f]{64}' "$d" | wc -l | tr -d ' ')
    assert_eq "no literal digest in $(basename "$d")" "$hits" "0"
done

# ── 9. the SET coupling, across interpreters ──────────────────────────
echo "== 9. a lonely install fails with the DESIGNED code on every interpreter"
LONE="$WORK/lonely"; FULL="$WORK/full"
mkdir -p "$LONE" "$FULL"
cp "$MON/client/nexus-request" "$MON/client/nexus-reply-watch" "$LONE/"
cp "$MON/client/"* "$FULL/"
chmod +x "$LONE"/nexus-re* "$FULL"/nexus-re*
ran=0
for shell in bash dash sh; do
    command -v "$shell" >/dev/null 2>&1 || { th_skip "$shell absent"; continue; }
    ran=$((ran+1))
    for m in nexus-request nexus-reply-watch; do
        out=$("$shell" "$LONE/$m" --help 2>&1); rc=$?
        # 64 is the DESIGNED usage/config exit. Before the fix, dash gave 2 —
        # loud, but not the designed signal, and the designed message never
        # printed at all.
        assert_eq "$shell $m alone → rc 64" "$rc" "64"
        assert_contains "$shell $m alone → designed message" "$out" "cannot load _nexus_watch_lib.sh"
        assert_contains "$shell $m alone → points at the set" "$out" "SET"
        # NEGATIVE CONTROL. Without this, every assertion above passes just as
        # well if the scripts refused unconditionally.
        out=$("$shell" "$FULL/$m" --help 2>&1); rc=$?
        assert_eq "$shell $m WITH the set → rc 0" "$rc" "0"
    done
done
if (( ran == 0 )); then
    _th_fail; echo "  FAIL: no interpreter was exercised — test 9 proved nothing"
fi

# ── 10. ng routes the verb, and does not break the others ─────────────
echo "== 10. ng dispatch"
if [[ -x "$NG" ]]; then
    out=$("$NG" remote client-helper --files 2>&1); rc=$?
    assert_eq "ng remote client-helper --files → rc 0" "$rc" "0"
    assert_contains "routes to the helper" "$out" "_nexus_watch_lib.sh"
    out=$("$NG" remote client-helper --bogus 2>&1); rc=$?
    assert_eq "an unknown flag is refused" "$rc" "1"
else
    th_skip "monitor/ng not executable"
fi

# ── EXACT COUNT GUARD (summary-honesty.manifest contract) ─────────────
# `th_summary_and_exit` certifies that SOMETHING was asserted and that no FAIL
# was swallowed by a subshell. It certifies NOTHING about HOW MUCH ran — so a
# whole section lost to an early `return`, a `continue`, or a skipped loop
# prints a clean green. Pin the total: a VANISHED assertion reddens.
#
# Counted from the LEDGER, not the counters: the ledger survives the subshell
# the counters die in, so it is the honest total. Update this number
# deliberately when you add or remove an assertion — that edit IS the review.
EXPECTED_ASSERTIONS=61
_ran=$(( $(_th_ledger_count P) + $(_th_ledger_count F) + $(_th_ledger_count S) ))
if [[ "$_ran" != "$EXPECTED_ASSERTIONS" ]]; then
    printf '  FAIL: ran %s assertions, expected exactly %s.\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    printf '        A count that DROPS means assertions vanished (an early exit, a\n' >&2
    printf '        loop that did not iterate); a count that RISES means this number\n' >&2
    printf '        was not updated with the suite. Either way the green is not honest.\n' >&2
    FAIL=$(( ${FAIL:-0} + 1 ))
fi

th_summary_and_exit
