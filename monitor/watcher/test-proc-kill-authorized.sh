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
# NOT the session-leader arm, and the label used to claim it was. From THIS
# process the session leader is an ANCESTOR, so `_verdict`s ancestor arm fires
# FIRST and `session-leader` below it is SHADOWED (#1121's arm-order shape);
# line coverage measured the condition taken on every call and its body never.
# T13 reaches that arm for real, from an orphan whose walk cannot see the
# leader. What THIS asserts is the shadowing itself, which is worth pinning:
# the leader is refused, and refused as `self`.
assert_kind "the session leader, as seen from a DESCENDANT (shadowed by the ancestor arm — see T13)" "$MY_SID" self 1

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
echo '=== T11: the not-owned refusal DISTINGUISHES yours-but-detached from a sibling ==='
# your-org/nexus-code#1235. "not yours" reads IDENTICALLY whichever explanation
# is true, and an orphan survived TWELVE HOURS because its own launcher hit
# this refusal, took the sibling reading the message offers, and moved on.
#
# THE LOAD-BEARING PAIR IS (diagnostic fires) AND (verdict unchanged). A hint
# that came with a permission would be a regression dressed as a fix, so the
# kind and the rc are asserted right beside it.
t11_leader=""
# NOT in a subshell. A `( setsid … & )` subshell EXITS immediately, the leader
# reparents to init, and the very signature this case tests (parent alive, in
# our session) is destroyed — measured: ppid 1, sid 0, fixture red. The test
# process itself must stay the parent.
setsid sleep 30 & _t11_seed=$!
sleep 0.5
# `setsid` EXECs when it is not already a group leader, so the seed pid usually
# IS the new leader; check its children too rather than assuming which.
for _c in $_t11_seed $(cat "/proc/$_t11_seed/task/$_t11_seed/children" 2>/dev/null); do
    [[ -n "$_c" && -d "/proc/$_c" ]] || continue
    _csid=$(ps -o sid= -p "$_c" 2>/dev/null | tr -d ' ')
    [[ "$_csid" == "$_c" ]] && t11_leader="$_c"
done
_kids="$_kids $_t11_seed $t11_leader"
if [[ -n "$t11_leader" ]]; then
    _lppid=$(ps -o ppid= -p "$t11_leader" 2>/dev/null | tr -d ' ')
    _lppid_sid=$(ps -o sid= -p "${_lppid:-1}" 2>/dev/null | tr -d ' ')
    if [[ "$_lppid_sid" == "$MY_SID" ]]; then
        pass "fixture: a session leader ($t11_leader) whose parent ($_lppid) is in OUR session"
    else
        fail "fixture did not produce the signature (ppid $_lppid sid=$_lppid_sid != $MY_SID); T11 proves nothing"
    fi
    _t11_out=$("$HELPER" "$t11_leader" 2>&1)
    if [[ "$_t11_out" == *NOT-A-SIBLING* ]]; then
        pass "…and the refusal says NOT-A-SIBLING"
    else
        fail "the refusal did NOT distinguish it (out: $_t11_out)"
    fi
    # The permission must NOT have moved. This is the assertion that stops the
    # diagnostic becoming a widening.
    assert_kind "…and it is STILL refused" "$t11_leader" not-owned 1
    if [[ "$_t11_out" == *TaskStop* ]]; then
        pass "…and names the harness-native stop (TaskStop)"
    else
        fail "the hint does not name TaskStop, so it routes nobody anywhere"
    fi
    if [[ "$_t11_out" == *svc.sh* ]]; then
        pass "…and names svc.sh, because a setsid-detached service has the SAME signature"
    else
        fail "the hint names only one of the two causes it cannot tell apart"
    fi
else
    fail "could not plant a session leader; T11 proves nothing"
    fail "  (four dependent assertions did not run)"
    fail "  (…)"
    fail "  (…)"
    fail "  (…)"
fi

# THE NEGATIVE CONTROL, and it is the one that matters: a genuine sibling must
# NOT be told it is yours. A hint that fired on everything would restore the
# exact ambiguity #1235 is about, in the opposite direction.
if [[ -n "${sib:-}" ]]; then
    _sib_out=$("$HELPER" "$sib" 2>&1)
    if [[ "$_sib_out" != *NOT-A-SIBLING* ]]; then
        pass "a genuine foreign-session pid ($sib) is NOT claimed as ours"
    else
        fail "the hint fired on a foreign pid ($sib) — it claims everything (out: $_sib_out)"
    fi
else
    fail "no foreign-session pid available; the negative control did not run"
fi

echo
echo '=== T12: the HARNESS topology — parent in a GRANDPARENT session (#1235) ==='
# T11 above plants `setsid sleep &` FROM THIS TEST PROCESS, so the planted
# leader's parent is in the test's OWN session — the one topology where the
# first fix's single arm fires. That is the FIX's shape, not the DEFECT's.
#
# The defect's shape, measured on this host: every Bash tool call is its own
# session leader, so a harness-backgrounded call's leader has the SHARED
# `claude` process as its parent, and that process sits in a GRANDPARENT
# session. A shell script cannot ask the harness to background anything, so
# the topology is CONSTRUCTED here instead — three levels, which is the whole
# point:
#
#   S  session LEADER          (the tmux pane shell stand-in)
#   C  child of S, NOT a leader (the `claude` process stand-in)
#   L  setsid child of C        <- the orphan. Its parent C is a GRANDPARENT session.
#   M  setsid child of S        <- ANOTHER pane's shell. Parent S IS a leader.
#   P  setsid child of C        <- a LATER tool call: the prober
#
# M IS THE ASSERTION THAT KEEPS THIS FROM BEING A WIDENING, and it is not
# hypothetical. This issue's own text proposes comparing session(ppid) against
# the prober's ANCESTORS' sessions; the tmux server is an ancestor of every
# agent on this host, and ELEVEN live sibling pane shells were measured as
# session leaders parented by it — so that form claims all eleven as "yours",
# restoring #1235's ambiguity in the opposite direction. M is that shape.
t12_ok=0
T12W="$WORK/t12"
mkdir -p "$T12W"

cat > "$T12W/P.sh" <<'T12P'
#!/usr/bin/env bash
# The PROBER. A later tool call: its own session, parented by C.
HELPER="$1"; W="$2"; L="$3"; M="$4"
mysid=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
# Is C (our ppid) an ANCESTOR of ours? Trivially yes; record the walk anyway so
# the assertion below rests on a measurement, not on the fixture's intent.
myppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')
{
  echo "P_PID=$$"
  echo "P_SID=$mysid"
  echo "P_PPID=$myppid"
} > "$W/P.meta"
"$HELPER" "$L" > "$W/probe_L.out" 2>&1; echo $? > "$W/probe_L.rc"
"$HELPER" "$M" > "$W/probe_M.out" 2>&1; echo $? > "$W/probe_M.rc"
T12P
chmod +x "$T12W/P.sh"

cat > "$T12W/C.sh" <<'T12C'
#!/usr/bin/env bash
# The `claude` stand-in: a child of S, in S's session, NOT a session leader.
HELPER="$1"; W="$2"; M="$3"
csid=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
{ echo "C_PID=$$"; echo "C_SID=$csid"; } > "$W/C.meta"
setsid sleep 45 & lseed=$!
sleep 0.5
L=""
for c in $lseed $(cat "/proc/$lseed/task/$lseed/children" 2>/dev/null); do
    [[ -n "$c" && -d "/proc/$c" ]] || continue
    [[ "$(ps -o sid= -p "$c" 2>/dev/null | tr -d ' ')" == "$c" ]] && L="$c"
done
printf '%s\n%s\n' "$L" "$lseed" > "$W/L.pid"
[[ -n "$L" ]] || { echo "no-L" > "$W/fixture.err"; exit 9; }
setsid "$W/P.sh" "$HELPER" "$W" "$L" "$M"
echo done > "$W/C.done"
T12C
chmod +x "$T12W/C.sh"

cat > "$T12W/S.sh" <<'T12S'
#!/usr/bin/env bash
# The pane-shell stand-in: a session LEADER that spawns session leaders.
HELPER="$1"; W="$2"
ssid=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')
{ echo "S_PID=$$"; echo "S_SID=$ssid"; } > "$W/S.meta"
setsid sleep 45 & mseed=$!
sleep 0.5
M=""
for c in $mseed $(cat "/proc/$mseed/task/$mseed/children" 2>/dev/null); do
    [[ -n "$c" && -d "/proc/$c" ]] || continue
    [[ "$(ps -o sid= -p "$c" 2>/dev/null | tr -d ' ')" == "$c" ]] && M="$c"
done
printf '%s\n%s\n' "$M" "$mseed" > "$W/M.pid"
[[ -n "$M" ]] || { echo "no-M" > "$W/fixture.err"; exit 9; }
"$W/C.sh" "$HELPER" "$W" "$M"
echo done > "$W/S.done"
T12S
chmod +x "$T12W/S.sh"

setsid "$T12W/S.sh" "$HELPER" "$T12W" & _t12_seed=$!
_kids="$_kids $_t12_seed"
# BOUNDED wait — never an open-ended poll.
for _i in $(seq 1 80); do
    [[ -f "$T12W/C.done" || -f "$T12W/fixture.err" ]] && break
    sleep 0.25
done
t12_L=$(head -1 "$T12W/L.pid" 2>/dev/null)
t12_M=$(head -1 "$T12W/M.pid" 2>/dev/null)
_kids="$_kids $t12_L $t12_M"
# shellcheck disable=SC1090
[[ -f "$T12W/C.meta" ]] && . "$T12W/C.meta"
[[ -f "$T12W/S.meta" ]] && . "$T12W/S.meta"
[[ -f "$T12W/P.meta" ]] && . "$T12W/P.meta"
t12_Lout=$(cat "$T12W/probe_L.out" 2>/dev/null)
t12_Lrc=$(cat "$T12W/probe_L.rc" 2>/dev/null)
t12_Mout=$(cat "$T12W/probe_M.out" 2>/dev/null)
t12_Mrc=$(cat "$T12W/probe_M.rc" 2>/dev/null)

if [[ -n "$t12_L" && -n "$t12_M" && -n "${C_PID:-}" && -n "${P_PID:-}" && -n "$t12_Lout" ]]; then
    t12_ok=1
fi

if (( t12_ok )); then
    # PRECONDITION 1 — the GRANDPARENT-session signature. Without this the
    # four assertions below prove nothing: they would be T11 again.
    if [[ "${C_PID:-}" != "${C_SID:-x}" && "${C_SID:-}" != "${P_SID:-x}" && "${P_PPID:-}" == "${C_PID:-x}" ]]; then
        pass "fixture: L's parent C (${C_PID:-?}) is NOT a session leader and sits in session ${C_SID:-?}, a GRANDPARENT of the prober's ${P_SID:-?}"
    else
        fail "fixture did NOT produce the harness signature (C_PID=${C_PID:-?} C_SID=${C_SID:-?} P_SID=${P_SID:-?} P_PPID=${P_PPID:-?}); T12 proves nothing"
    fi
    # PRECONDITION 2 — the multiplexer control really is a multiplexer child.
    if [[ -n "${S_PID:-}" && "${S_PID:-}" == "${S_SID:-x}" ]]; then
        pass "fixture: M's parent S (${S_PID:-?}) IS a session leader — the tmux-server shape"
    else
        fail "fixture: S (${S_PID:-?}) is not a session leader (sid=${S_SID:-?}); the negative control is not the shape it claims"
    fi
    # THE DEFECT ITSELF. At the parent commit this printed the sibling text.
    if [[ "$t12_Lout" == *NOT-A-SIBLING* ]]; then
        pass "…and the refusal SEEN BY THE PROBER says NOT-A-SIBLING"
    else
        fail "the harness topology was NOT distinguished (out: $t12_Lout)"
    fi
    # NO WIDENING. Asserted on the PROBER's own rc and kind, not on a re-probe
    # from this process — a re-probe would ask a different question.
    t12_kind=$(printf '%s' "$t12_Lout" | sed -n 's/.*kind=\([a-z-]*\).*/\1/p')
    if [[ "$t12_kind" == "not-owned" ]] && [[ "$t12_Lrc" == "1" ]]; then
        pass "…and it is STILL refused -> kind=$t12_kind rc=$t12_Lrc"
    else
        fail "the hint moved the VERDICT: kind=${t12_kind:-<none>} rc=${t12_Lrc:-<none>}, want not-owned/1"
    fi
    if [[ "$t12_Lout" == *TaskStop* ]]; then
        pass "…and names the harness-native stop (TaskStop)"
    else
        fail "the hint does not name TaskStop, so it routes nobody anywhere"
    fi
    # THE NEGATIVE CONTROL THAT KEEPS THIS HONEST. A session leader whose
    # parent is a session-leader ANCESTOR is another agent's pane shell.
    if [[ "$t12_Mout" != *NOT-A-SIBLING* ]]; then
        pass "a multiplexer's other child ($t12_M) is NOT claimed as ours (the 11-pane-shell false positive)"
    else
        fail "the hint claimed a multiplexer's child ($t12_M) — it would claim every sibling agent's pane shell (out: $t12_Mout)"
    fi
    t12_mkind=$(printf '%s' "$t12_Mout" | sed -n 's/.*kind=\([a-z-]*\).*/\1/p')
    if [[ "$t12_mkind" == "not-owned" ]] && [[ "$t12_Mrc" == "1" ]]; then
        pass "…and it too is still refused -> kind=$t12_mkind rc=$t12_Mrc"
    else
        fail "the multiplexer child's verdict moved: kind=${t12_mkind:-<none>} rc=${t12_Mrc:-<none>}"
    fi
else
    fail "could not build the harness topology; T12 proves nothing (L=${t12_L:-} M=${t12_M:-} C=${C_PID:-} P=${P_PID:-} err=$(cat "$T12W/fixture.err" 2>/dev/null))"
    fail "  (six dependent assertions did not run)"
    fail "  (…)"
    fail "  (…)"
    fail "  (…)"
    fail "  (…)"
    fail "  (…)"
fi

echo
echo '=== T13: the SESSION-LEADER arm, reached IN SITU (your-org/nexus-code#1278) ==='
# T2 above probes $MY_SID and asserts kind=`self`, and that is CORRECT: the
# session leader is normally an ANCESTOR of the caller, so `_verdict`'s ancestor
# arm fires FIRST and the session-leader arm below it is SHADOWED (#1121's
# arm-order shape). Line-coverage at 5bd6d400 measured the condition executed on
# every call and the BODY never once taken — the arm existed only on paper.
#
# The case it was written for has a different topology, and it is the one that
# matters in production: an ORPHAN reparented to init, whose ancestor walk
# (ppid -> 1 -> stop) no longer reaches the still-live session leader. Then the
# leader is in our session, is NOT in our ancestor set, and IS $MY_SESSION —
# and killing it takes the whole session down.
#
#   S   setsid'd script            <- session LEADER, stays alive
#   I   child of S                 <- forks P and EXITS, so P reparents
#   P   grandchild, ppid becomes 1 <- the prober. Probes S.
t13_ok=0
T13W="$WORK/t13"; mkdir -p "$T13W"

cat > "$T13W/P.sh" <<'T13P'
#!/usr/bin/env bash
# The PROBER: reparented to init, still inside S's session.
HELPER="$1"; W="$2"
# BOUNDED wait for the reparent — never an open-ended poll, and never a fixed
# sleep standing in for the condition.
for _i in $(seq 1 40); do
    [[ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" == "1" ]] && break
    sleep 0.25
done
S=$(sed -n 's/^S_PID=//p' "$W/S.meta")
{ echo "P_PID=$$"
  echo "P_SID=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')"
  echo "P_PPID=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')"
} > "$W/P.meta"
"$HELPER" "$S" > "$W/probe_S.out" 2>&1; echo $? > "$W/probe_S.rc"
echo done > "$W/P.done"
T13P

cat > "$T13W/I.sh" <<'T13I'
#!/usr/bin/env bash
# The INTERMEDIATE. Its only job is to exit, orphaning P.
"$2/P.sh" "$1" "$2" &
exit 0
T13I

cat > "$T13W/S.sh" <<'T13S'
#!/usr/bin/env bash
# The session LEADER. It must OUTLIVE the probe: a dead leader would be
# `absent`, which is a different arm and would prove nothing.
HELPER="$1"; W="$2"
{ echo "S_PID=$$"; echo "S_SID=$(ps -o sid= -p $$ 2>/dev/null | tr -d ' ')"; } > "$W/S.meta"
"$W/I.sh" "$HELPER" "$W"
for _i in $(seq 1 80); do [[ -f "$W/P.done" ]] && break; sleep 0.25; done
echo done > "$W/S.done"
T13S
chmod +x "$T13W/P.sh" "$T13W/I.sh" "$T13W/S.sh"

setsid "$T13W/S.sh" "$HELPER" "$T13W" & _t13_seed=$!
_kids="$_kids $_t13_seed"
for _i in $(seq 1 80); do [[ -f "$T13W/P.done" ]] && break; sleep 0.25; done
# shellcheck disable=SC1090
[[ -f "$T13W/S.meta" ]] && . "$T13W/S.meta"
# shellcheck disable=SC1090
[[ -f "$T13W/P.meta" ]] && . "$T13W/P.meta"
_kids="$_kids ${S_PID:-} ${P_PID:-}"
t13_out=$(cat "$T13W/probe_S.out" 2>/dev/null)
t13_rc=$(cat "$T13W/probe_S.rc" 2>/dev/null)
[[ -n "${S_PID:-}" && -n "${P_PID:-}" && -n "$t13_out" ]] && t13_ok=1

if (( t13_ok )); then
    # PRECONDITION 1 — S really is a session leader.
    if [[ "${S_PID:-}" == "${S_SID:-x}" ]]; then
        pass "fixture: S (${S_PID:-?}) IS its own session leader"
    else
        fail "fixture: S (${S_PID:-?}) is not a session leader (sid=${S_SID:-?}); T13 proves nothing"
    fi
    # PRECONDITION 2 — the prober really was orphaned. Without this the walk
    # still reaches S and the `self` arm fires, which is T2 again.
    if [[ "${P_PPID:-}" == "1" ]]; then
        pass "fixture: the prober (${P_PID:-?}) really did reparent (ppid=1)"
    else
        fail "fixture: prober ppid=${P_PPID:-?}, not 1 — the ancestor walk still reaches S; T13 proves nothing"
    fi
    # PRECONDITION 3 — and it is still INSIDE S's session, or the answer would
    # be `not-owned` and this would be T3.
    if [[ "${P_SID:-}" == "${S_PID:-x}" ]]; then
        pass "fixture: …and its sid SURVIVED the reparent (${P_SID:-?} == S)"
    else
        fail "fixture: prober sid=${P_SID:-?} != S ${S_PID:-?}; T13 proves nothing"
    fi
    t13_kind=$(printf '%s' "$t13_out" | sed -n 's/.*kind=\([a-z-]*\).*/\1/p')
    if [[ "$t13_kind" == "session-leader" ]] && [[ "$t13_rc" == "1" ]]; then
        pass "the SESSION-LEADER arm fires in situ -> kind=$t13_kind rc=$t13_rc"
    else
        fail "the session-leader arm did NOT fire: kind=${t13_kind:-<none>} rc=${t13_rc:-<none>} (out: $t13_out)"
    fi
    # NAMED, not merely refused. `self` would also be a refusal at rc 1, and it
    # is the WRONG one: it would mean the arm is still shadowed.
    if [[ "$t13_out" == *takes-down-this-session* ]]; then
        pass "…and says WHY (killing it takes down the session), not just 'no'"
    else
        fail "the refusal did not name the consequence (out: $t13_out)"
    fi
else
    fail "could not build the orphan-prober topology; T13 proves nothing (S=${S_PID:-} P=${P_PID:-} out=${t13_out:-})"
    fail "  (four dependent assertions did not run)"
    fail "  (…)"
    fail "  (…)"
    fail "  (…)"
fi

echo
echo '=== T14: a verdict that could NOT BE OBTAINED is a REFUSAL, never a permit ==='
# your-org/nexus-code#1278, found while building T15 below. `out=$(_verdict …)`
# is a command substitution; one that cannot be CREATED — no descriptor for the
# pipe (EMFILE), no slot for the fork — leaves `out` empty and sets `$?` to 0.
# The pre-fix helper read that 0 as `authorized` and PRINTED THE PID on the
# stdout that `kill $(… --filter)` consumes. Measured on the unmodified helper
# with `ulimit -n` as the ONLY variable: n=4 -> rc 0, --filter emitted 999999.
#
# The sweep is the assertion, not one magic limit: which n trips it depends on
# how many descriptors bash has already spent (BASH_ENV, the script fd), which
# is a property of the HOST, not of this guard. So the property asserted is the
# one that must hold at EVERY n — a pid that does not exist is never permitted.
t14_authorized_at=""
t14_emitted_at=""
t14_seen_unavailable=""
t14_seen_session_unknown=""
for _n in 3 4 5 6 7 8 10 12; do
    _o=$(bash -c "ulimit -n $_n 2>/dev/null; exec '$HELPER' 999999" 2>/dev/null); _r=$?
    (( _r == 0 )) && t14_authorized_at="$t14_authorized_at $_n"
    [[ "$_o" == *authorized=1* ]] && t14_authorized_at="$t14_authorized_at $_n"
    _k=$(printf '%s' "$_o" | sed -n 's/.*kind=\([a-z-]*\).*/\1/p')
    [[ "$_k" == "verdict-unavailable"    ]] && t14_seen_unavailable="$t14_seen_unavailable $_n"
    [[ "$_k" == "caller-session-unknown" ]] && t14_seen_session_unknown="$t14_seen_session_unknown $_n"
    _f=$(bash -c "ulimit -n $_n 2>/dev/null; exec '$HELPER' --filter 999999" 2>/dev/null)
    [[ "$_f" == *999999* ]] && t14_emitted_at="$t14_emitted_at $_n"
done
if [[ -z "$t14_authorized_at" ]]; then
    pass "a nonexistent pid is NEVER authorized, at any descriptor limit tried"
else
    fail "FALSE PERMIT: pid 999999 was authorized at ulimit -n$t14_authorized_at"
fi
if [[ -z "$t14_emitted_at" ]]; then
    pass "…and --filter never emits it onto the stdout \`kill\` consumes"
else
    fail "FALSE PERMIT via --filter: 999999 emitted at ulimit -n$t14_emitted_at"
fi
# POTENCY. The two assertions above are satisfied by a guard that simply never
# runs, so they need a leg proving the offending condition was actually REACHED
# and the guard REACTED to it. Both arms below are the fail-closed paths this
# case exists for, and both are reached with the SHIPPED file — no injection.
if [[ -n "$t14_seen_unavailable" ]]; then
    pass "potency: the descriptor-starved path was really reached — kind=verdict-unavailable at ulimit -n$t14_seen_unavailable"
else
    th_skip "fd-starved-verdict" "no tried ulimit -n produced verdict-unavailable on this host; the two assertions above are then only a NEGATIVE result"
fi
# A SKIP HERE MUST NOT BE FREE. `caller-session-unknown` was one of the four
# arms #1278 found unexercised, and the first draft of this leg skipped rather
# than failed when it did not fire — so a mutant that made the arm PERMIT
# (return 0 instead of 1) left the suite GREEN with one skip. A skip that hides
# a killed arm is the very shape this case exists to close. So the skip is
# conditioned on evidence that the REGIME itself was unreachable: if descriptor
# starvation was demonstrably reached and this arm still never fired, that is a
# failure, not a host limitation.
if [[ -n "$t14_seen_session_unknown" ]]; then
    pass "…and the CALLER-SESSION-UNKNOWN arm fires in situ at ulimit -n$t14_seen_session_unknown"
elif [[ -z "$t14_seen_unavailable" ]]; then
    th_skip "caller-session-unknown" "descriptor starvation was not reachable at any tried ulimit -n on this host, so neither fail-closed arm could be driven"
else
    fail "descriptor starvation WAS reached (verdict-unavailable at ulimit -n$t14_seen_unavailable) yet caller-session-unknown NEVER fired — the arm is gone, renamed, or no longer refuses"
fi

echo
echo '=== T15: the two `unreadable` arms — FAULT-INJECTED, and labelled as such ==='
# HONEST SCOPE, because this is the one place in this file where the assertion
# is NOT against the shipped binary path. `_verdict`s two `unreadable` arms are
# driven by `_session_of`s return code, and on a host without privileged mounts
# there is no way to make /proc/<pid>/stat unreadable while /proc/<pid> remains
# a directory: measured on this host, 0 of 303 live pids have an unreadable
# stat, and `unshare -rm` cannot mount (EPERM). Rather than fake coverage, the
# fault is INJECTED into `_session_of` and the arms are exercised with
# `_verdict` BYTE-IDENTICAL to the shipped one — which is asserted, not assumed.
# The fault is conditioned on `$1 != $$` so `_resolve_self` still reads the
# helper's OWN session truthfully. A blanket `return <rc>` would have made
# `caller-session-unknown` fire FIRST and the arm under test would never be
# reached — which is exactly the arm-shadowing shape this whole issue is about,
# and it happened on the first draft of this case.
_inject() {   # <rc> <outfile> — fault _session_of for every pid but the helper's own
    awk -v code="$1" '
        /^_session_of\(\) \{/ { print; print "    [[ \"$1\" != \"$$\" ]] && return " code; next }
        { print }
    ' "$HELPER" > "$2"
    chmod +x "$2"
}
_fn_body()  { sed -n "/^$2() {/,/^}/p" "$1"; }
# Everything EXCEPT the named function, so "changed inside" and "unchanged
# outside" can be asserted as two independent facts rather than inferred from
# one diff.
_fn_strip() { awk -v fn="$2" '$0 == fn "() {" {sk=1} sk {if ($0 == "}") sk=0; next} {print}' "$1"; }

for _rc in 4 7; do
    _inj="$WORK/inject-$_rc"
    _inject "$_rc" "$_inj"
    # PROOF THE INJECTION LANDED ON THE REGION, not merely on the file — both
    # directions. An awk that silently matches nothing is how a mutation
    # control reports green while testing nothing (your-org/nexus-code#825);
    # an awk that matches too much would mean the arm exercised below is not
    # the shipped arm.
    if [[ "$(_fn_body "$HELPER" _session_of)" != "$(_fn_body "$_inj" _session_of)" ]]; then
        pass "injection rc=$_rc CHANGED _session_of (the fault really applied)"
    else
        fail "injection rc=$_rc left _session_of untouched — it proves nothing"
    fi
    if [[ "$(_fn_strip "$HELPER" _session_of)" == "$(_fn_strip "$_inj" _session_of)" ]]; then
        pass "…and changed NOTHING outside it, so _verdict is the shipped one byte for byte"
    else
        fail "injection rc=$_rc changed bytes outside _session_of; the arm exercised is not the shipped arm"
    fi
done
# `$$` here is the TEST's pid, which is never the HELPER's, so the fault fires
# on the probe while the helper's own session still resolves.
_u4=$("$WORK/inject-4" "$$" 2>&1); _u4rc=$?
_u7=$("$WORK/inject-7" "$$" 2>&1); _u7rc=$?
if [[ "$_u4" == *kind=unreadable* ]] && (( _u4rc == 1 )) && [[ "$_u4" == *not-readable-or-not-numeric* ]]; then
    pass "rc 3 vs rc 4 are DISTINCT: rc 4 refuses as unreadable/not-readable-or-not-numeric"
else
    fail "an rc-4 probe did not produce the unreadable arm (rc=$_u4rc out: $_u4)"
fi
if [[ "$_u7" == *kind=unreadable* ]] && (( _u7rc == 1 )) && [[ "$_u7" == *probe-returned-7* ]]; then
    pass "…and an UNENUMERATED probe rc lands on the default-DENY arm, naming it (probe-returned-7)"
else
    fail "an unenumerated probe rc did not land on the default-deny arm (rc=$_u7rc out: $_u7)"
fi
# THE CODOMAIN, asserted against the SHIPPED file — this is what makes the
# `probe-returned-N` arm honestly describable as unreachable-by-construction
# rather than merely untested. A fifth return value added to `_session_of`
# turns this red on the very commit that adds it.
_sof_codomain=$(_fn_body "$HELPER" _session_of | grep -o 'return [0-9]*' | awk '{print $2}' | sort -u | tr '\n' ' ')
if [[ "$_sof_codomain" == "0 3 4 " ]]; then
    pass "_session_of's return codomain is exactly {0,3,4} — so probe-returned-N is a DEFENSIVE terminal arm, not a live path"
else
    fail "_session_of's codomain drifted to {${_sof_codomain% }} — re-derive which _verdict arms are reachable in situ"
fi

echo
# COUNT GUARD. Several cases here are CONDITIONAL (T3 needs a foreign-session
# pid to exist; the mutant control needs the substitution to apply), so a case
# that silently stops running shows up as a smaller green rather than a red.
# Pinning the total makes a truncated run a failure. `+ 1` counts this
# assertion itself.
# T14's last two legs are `pass`-or-`th_skip` (a host may not be able to
# starve the helper of descriptors), so SKIP joins the sum: each contributes
# exactly 1 either way, which keeps ONE expected total rather than a
# disjunction over several (your-org/nexus-code#1278).
_EXPECTED_ASSERTIONS=51
_ran=$(( PASS + FAIL + SKIP + 1 ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    pass "every declared assertion executed ($_EXPECTED_ASSERTIONS)"
else
    fail "assertion count drifted — ran $_ran, expected $_EXPECTED_ASSERTIONS"
fi

th_summary_and_exit
