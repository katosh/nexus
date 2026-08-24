#!/usr/bin/env bash
# Tests for monitor/proc-kill-authorized — the process-ownership allowlist
# with a default-DENY arm (your-org/nexus-code#851).
#
# The incident: a worker stopping its own oversized test run built a kill
# list by filtering `ps` with a DENYLIST (`grep -v` on sibling clone names)
# and killed everything else matching `run-tests`. Sibling agents' legs died
# EXIT=143 mid-run. Name matching CANNOT work — the siblings were invoked
# cwd-relative, so their argv was byte-identical to the caller's.
#
# What these tests are for, in order of what they would actually catch:
#
#   1. THE DEFAULT ARM. Every not-known outcome must refuse. A test that
#      only proves "my own child is authorised" would pass against a
#      `return 0` stub. So each refusal case asserts its OWN kind, not just
#      a non-zero rc: a guard that refuses everything for the wrong reason
#      is not the guard we wrote.
#   2. THE REPARENTED CASE, which is why session id was chosen over the
#      ancestry walk `#851` proposed. A child whose parent exits is
#      reparented to init — `ppid` becomes 1 and the walk dies, while `sid`
#      survives. This is measured against a REAL reparented process, not a
#      simulated one, because it is the case that decided the design.
#   3. THE /proc PARSE. `comm` sits in parentheses in `/proc/<pid>/stat` and
#      may contain spaces and parens, so a field-index parse returns
#      garbage. Driven with a real binary named `x) 1 2 3 (y`.
#   4. THE FILTER'S SILENCE. `--filter` emitting nothing must be loud —
#      "printed nothing" reading as "nothing to do" is this workspace's
#      dominant defect class, and it would be absurd inside the guard
#      against it.
#
# Run: bash monitor/watcher/test-proc-kill-authorized.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$_test_dir/../proc-kill-authorized"

# The SHARED assertion ledger (your-org/nexus-code#805). The in-memory
# counters die in a subshell; the ledger is a file and survives, so a FAILING
# assertion counted inside `( … )` or `$( … )` still reddens the suite. This
# file's own `pass`/`fail` keep their signatures and delegate, so every call
# site below is unchanged.
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$*" >&2; _th_fail; }

# assert_kind <label> <pid> <want-kind> <want-rc>
# Asserts BOTH the refusal kind and the rc. Asserting rc alone would pass
# against a guard that refuses for a reason we did not intend.
assert_kind() {
    local label="$1" pid="$2" want_kind="$3" want_rc="$4" out rc got
    out=$("$HELPER" "$pid" 2>&1); rc=$?
    got=$(printf '%s' "$out" | sed -n 's/.*kind=\([a-z-]*\).*/\1/p')
    if [[ "$got" == "$want_kind" ]] && (( rc == want_rc )); then
        pass "$label -> kind=$got rc=$rc"
    else
        fail "$label -> got kind=${got:-<none>} rc=$rc, want kind=$want_kind rc=$want_rc (out: $out)"
    fi
}

WORK=$(mktemp -d -t nexus-pka-XXXXXX)
cleanup() {
    [[ -n "${_kids:-}" ]] && kill $_kids 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
_kids=""

[[ -x "$HELPER" ]] || { echo "FATAL: helper not executable: $HELPER" >&2; exit 1; }

MY_SID=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
[[ -n "$MY_SID" ]] || { echo "FATAL: could not read own sid" >&2; exit 1; }

echo "=== T1: a process I own is AUTHORIZED (the control that must pass) ==="
sleep 30 & mine=$!; _kids="$_kids $mine"
assert_kind "my own child" "$mine" authorized 0

echo
echo '=== T2: myself and my ancestors are REFUSED (kill-the-killer) ==='
assert_kind "this process" "$$" self 1
assert_kind "the session leader" "$MY_SID" self 1

echo
echo '=== T3: a pid in ANOTHER session is REFUSED as not-owned ==='
# The sibling-agent case. Pick any live pid whose sid differs from ours.
# Drained, NOT `… {print $1; exit}`: an early-exiting reader gives `ps` EPIPE,
# and this repo tracks every such site because under `pipefail` a consumed
# pipeline status can invert the verdict (#622). The first line is taken in the
# shell instead, which costs nothing and keeps the file out of that population.
sib=$(ps -eo pid=,sid= 2>/dev/null | awk -v s="$MY_SID" '$2!=s && $1>1 {print $1}')
sib=${sib%%$'\n'*}
if [[ -n "$sib" ]]; then
    assert_kind "a foreign-session pid ($sib)" "$sib" not-owned 1
else
    fail "no foreign-session pid available to test against"
fi

echo
echo '=== T4: REPARENTED-TO-INIT — the case that chose sid over the ppid walk ==='
# A grandchild whose parent exits: ppid becomes 1, sid survives. `#851`
# proposed walking ppid to the caller's driver pid; that walk terminates at
# 1 here and can NEVER authorise this pid, though we plainly own it.
setsid_free_orphan="$WORK/orphan.sh"
cat > "$setsid_free_orphan" <<'EOS'
#!/usr/bin/env bash
sleep 30 &
echo "$!" > "$1"
exit 0
EOS
chmod +x "$setsid_free_orphan"
"$setsid_free_orphan" "$WORK/orphan.pid"
sleep 0.5
orphan=$(cat "$WORK/orphan.pid" 2>/dev/null)
_kids="$_kids $orphan"
orphan_ppid=$(ps -o ppid= -p "$orphan" 2>/dev/null | tr -d ' ')
orphan_sid=$(ps -o sid= -p "$orphan" 2>/dev/null | tr -d ' ')
if [[ "$orphan_ppid" == "1" ]]; then
    pass "the fixture really did reparent (ppid=1) — the precondition holds"
else
    fail "fixture did NOT reparent (ppid=$orphan_ppid); T4 below proves nothing"
fi
if [[ "$orphan_sid" == "$MY_SID" ]]; then
    pass "…and its sid SURVIVED the reparent (sid=$orphan_sid == ours)"
else
    fail "orphan sid=$orphan_sid != ours $MY_SID"
fi
assert_kind "a reparented process we own" "$orphan" authorized 0

echo
echo '=== T5: an ABSENT pid is refused, never treated as "already dead, fine" ==='
# A stale kill list is lethal precisely because the pid may have been
# REUSED. `absent` must not be a permit and must not be silent.
assert_kind "a pid that does not exist" 999999 absent 1

echo
echo '=== T6: non-pids and init are refused ==='
assert_kind "not an integer" "notapid" not-a-pid 1
assert_kind "pid 1 (namespace init)" 1 not-a-pid 1
assert_kind "pid 0" 0 not-a-pid 1
assert_kind "negative" "-5" not-a-pid 1

echo
echo '=== T7: /proc/<pid>/stat is NOT parsed by field index (comm-parens trap) ==='
# comm may contain spaces and parentheses. A field-index parse returns
# garbage for a process whose FILENAME contains ") ". Reproduced with a
# real binary, not a mock.
evil="$WORK/x) 1 2 3 (y"
if cp "$(command -v sleep)" "$evil" 2>/dev/null; then
    "$evil" 30 & evilpid=$!; _kids="$_kids $evilpid"
    sleep 0.3
    rawstat=$(cat "/proc/$evilpid/stat" 2>/dev/null)
    naive=$(printf '%s' "$rawstat" | awk '{print $6}')
    if [[ ! "$naive" =~ ^[0-9]+$ ]]; then
        pass "precondition: a field-index parse really is garbage here ('$naive')"
    else
        fail "precondition FAILED: field-index parse gave '$naive'; T7 proves nothing"
    fi
    assert_kind "adversarially-named process we own" "$evilpid" authorized 0
else
    fail "could not create the adversarially-named fixture"
fi

echo
echo '=== T8: --filter emits ONLY authorised pids, and refusals go to stderr ==='
sleep 30 & mine2=$!; _kids="$_kids $mine2"
fout="$WORK/f.out"; ferr="$WORK/f.err"
printf '%s\n%s\n%s\n' "$mine2" "${sib:-2}" 999999 | "$HELPER" --filter >"$fout" 2>"$ferr"
frc=$?
if [[ "$(cat "$fout")" == "$mine2" ]]; then
    pass "--filter stdout carries exactly the owned pid"
else
    fail "--filter stdout was '$(cat "$fout")', want '$mine2'"
fi
if (( frc == 1 )); then
    pass "--filter exits 1 when it dropped something (silence is not success)"
else
    fail "--filter rc=$frc, want 1"
fi
if grep -q 'REFUSED' "$ferr"; then
    pass "--filter names each refusal on stderr"
else
    fail "--filter stderr carried no REFUSED line"
fi

echo
echo '=== T9: a filter that authorises NOTHING says so loudly ==='
nout="$WORK/n.out"; nerr="$WORK/n.err"
printf '%s\n' 999999 | "$HELPER" --filter >"$nout" 2>"$nerr"
nrc=$?
if [[ ! -s "$nout" ]] && (( nrc == 1 )); then
    pass "empty authorised set -> empty stdout, rc 1"
else
    fail "empty set: stdout='$(cat "$nout")' rc=$nrc"
fi
if grep -q 'NOTHING authorized' "$nerr"; then
    pass "…and it is announced, not silent (the #618 class inside its own guard)"
else
    fail "empty authorised set was SILENT on stderr"
fi

echo
echo '=== T10: MUTANT CONTROL — a permissive default arm must break these ==='
# The guard is not evidence until it has been watched failing. Replace the
# verdict function with the shape the incident had (permit unless positively
# excluded) and assert the suite's own cases go red.
mutant="$WORK/mutant"
# Anchor on a substring unique to the not-owned arm. Verified to have
# applied below — a sed that silently matches nothing is how M1 in
# your-org/nexus-code#825 reported green while testing nothing.
sed 's|printf .not-owned session[^;]*; return 1|printf "authorized MUTANT"; return 0|' \
    "$HELPER" > "$mutant"
chmod +x "$mutant"
if ! cmp -s "$HELPER" "$mutant"; then
    pass "mutant differs from the helper (the substitution actually applied)"
else
    fail "MUTANT IS INERT — substitution did not apply; T10 proves nothing"
fi
mout=$("$mutant" "${sib:-2}" 2>&1); mrc=$?
if (( mrc == 0 )) && [[ "$mout" == *authorized=1* ]]; then
    pass "mutant permits a foreign-session pid (so T3 has real teeth)"
else
    fail "mutant did not permit the foreign pid (out: $mout rc=$mrc) — T3 may be vacuous"
fi

echo
# COUNT GUARD. Several cases here are CONDITIONAL (T3 needs a foreign-session
# pid to exist; the mutant control needs the substitution to apply), so a case
# that silently stops running shows up as a smaller green rather than a red.
# Pinning the total makes a truncated run a failure. `+ 1` counts this
# assertion itself.
_EXPECTED_ASSERTIONS=22
_ran=$(( PASS + FAIL + 1 ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    pass "every declared assertion executed ($_EXPECTED_ASSERTIONS)"
else
    fail "assertion count drifted — ran $_ran, expected $_EXPECTED_ASSERTIONS"
fi

th_summary_and_exit
