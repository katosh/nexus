#!/usr/bin/env bash
# test-fixture-reap-ownership.sh — the fixture reap, and the ownership
# property it turns on (your-org/nexus-code#860).
#
# WHAT THIS SUITE IS FOR. `test-svc-orphan-reconcile.sh` leaked three
# supervised processes per run while printing ALL TESTS PASSED. The reap was
# not weak; it was a NO-OP, and a no-op reap returns success exactly as
# happily as one that worked. That is the shape this suite exists to pin:
#
#     assert on the PROPERTY (the process is gone), never on the reap's rc.
#
# The integration form of that assertion lives at the end of the orphan suite
# itself, where it can see that run's real fixture roots. This file is the
# FAST unit half: it builds the #860 process shape directly — a few seconds
# rather than the orphan suite's ~160 — so the primitive and its failure modes
# are exercised on every band run without paying for a second full suite.
#
# THE #860 SHAPE, reproduced deliberately. A leaked fixture supervisor is
# simultaneously:
#   * REPARENTED to init, because the `$( )` subshell that spawned it has
#     already exited — so `ppid` no longer proves anything;
#   * recorded NOWHERE, because `SLEEPERS="$SLEEPERS $!"` inside a command
#     substitution is discarded on return;
#   * holding a DELETED working directory, because `rm -rf "$ROOT"` ran while
#     it was still alive.
# Every one of those defeats a different ownership test, which is why the
# mechanism took three attempts to diagnose.
#
# ASSERTION SHAPE. Each refusal is paired with a POSITIVE twin on a
# byte-identical fixture, so the pair can only both pass if the predicate
# genuinely discriminates. A suite built only out of "nothing was killed"
# assertions is satisfied by a reap that kills nothing at all — which is
# precisely the bug.
#
# PROCESS SAFETY. Every process here is spawned by this file, inside fixture
# roots this file creates with mktemp, and is only ever signalled through a
# predicate keyed on those roots. No name matching, no `pgrep`, no `pkill`:
# `serve-supervised.sh` is a basename worn by live production supervisors on
# this host, and a read-only `pgrep` on it once TERMed four of them (`#608`).
#
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_self_dir/_test_helpers.sh"

TMP=$(mktemp -d -t reapown-XXXXXX)

# Teardown re-derives the survivor set independently of the code under test,
# so a broken primitive cannot also break its own cleanup.
teardown() {
    local d p cw r
    for r in "$TMP"/*; do
        [[ -d "$r" ]] || continue
        for d in /proc/[0-9]*; do
            p="${d##*/}"
            [[ "$p" =~ ^[0-9]+$ ]] || continue
            (( p == $$ )) && continue
            cw=$(readlink "/proc/$p/cwd" 2>/dev/null) || cw=""
            cw="${cw% (deleted)}"
            [[ "$cw" == "$r" || "$cw" == "$r"/* ]] || continue
            kill -KILL "$p" 2>/dev/null
        done
    done
    rm -rf "$TMP"
}
trap teardown EXIT INT TERM HUP

# make_idler <dir> — a wrapper that idles, standing in for a supervised
# daemon. It forks (`sleep` children), like the real one.
make_idler() {
    local dir="$1"
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n' > "$dir/serve-supervised.sh"
    chmod +x "$dir/serve-supervised.sh"
}

# spawn_orphaned <dir> — spawn through a command substitution, EXACTLY as the
# orphan fixture does, and return the pid. The subshell exits immediately, so
# the process is reparented to init before any cleanup can run.
spawn_orphaned() {
    local dir="$1" p
    p=$( ( cd "$dir" && exec bash "$dir/serve-supervised.sh" >/dev/null 2>&1 ) & printf '%s' $! )
    sleep 0.4
    printf '%s' "$p"
}

# live <pid> -> "alive" | "dead"
live() { kill -0 "$1" 2>/dev/null && printf alive || printf dead; }

echo "=== arm 0: the #860 shape reproduces (a fixture that lies makes every case vacuous) ==="

R1="$TMP/case1"; make_idler "$R1"
P1=$(spawn_orphaned "$R1")
assert_eq "the spawned supervisor is alive" "$(live "$P1")" alive
_ppid=$(2>/dev/null cat "/proc/$P1/stat"); _ppid=${_ppid##*") "}; _ppid=$(echo "$_ppid" | cut -d' ' -f2)
assert_eq "it is REPARENTED to init (ppid 1) before any cleanup runs" "$_ppid" 1
assert_eq "its cwd is the fixture root we gave it" "$(readlink "/proc/$P1/cwd" 2>/dev/null)" "$R1"

echo
echo "=== arm 1: the OLD reap is a silent no-op on exactly this shape ==="

# This is #860's mechanism, asserted rather than described. th_kill_own_child
# is CORRECT — a reaped pid is recyclable and ppid is the only thing still
# proving ownership — but its precondition is false for every leaked process.
th_kill_own_child "$P1" KILL
assert_rc "th_kill_own_child REFUSES the reparented supervisor" $? 1
sleep 0.3
assert_eq "…and the process is therefore still alive (the leak)" "$(live "$P1")" alive

# THE DECISIVE PAIR. Same helper, same signal, a child whose ppid is still $$.
sleep 300 & OWNED=$!
sleep 0.2
th_kill_own_child "$OWNED" KILL
assert_rc "…while it PERMITS a genuine own-child (predicate discriminates)" $? 0
sleep 0.3
assert_eq "…and that child really died" "$(live "$OWNED")" dead

echo
echo "=== arm 2: th_reap_fixture_root reaps by ROOT, which reparenting cannot destroy ==="

n=$(th_reap_fixture_root "$R1" KILL 4)
assert_rc "the sweep reports a fixed point" $? 0
sleep 0.4
# THE PROPERTY, not the return code. #860's whole lesson.
assert_eq "the orphaned supervisor is GONE" "$(live "$P1")" dead
assert_eq "…and the sweep says it signalled at least one process" \
    "$( (( n >= 1 )) && echo signalled || echo "none:$n" )" signalled

echo
echo "=== arm 3: a DELETED cwd still attributes — the #860 discriminator ==="

R2="$TMP/case2"; make_idler "$R2"
P2=$(spawn_orphaned "$R2")
assert_eq "second supervisor is up" "$(live "$P2")" alive
# Delete the fixture root out from under it, exactly as `rm -rf "$ROOT"` did.
rm -rf "$R2"
sleep 0.2
assert_contains "the kernel now reports its cwd as deleted" \
    "$(readlink "/proc/$P2/cwd" 2>/dev/null)" "(deleted)"
th_reap_fixture_root "$R2" KILL 4 >/dev/null
_rc=$?
# Self-diagnosing: on a contended runner this once returned 1 with the
# processes in fact gone, and "rc 1 want 0" alone could not distinguish a
# genuine survivor from a verdict taken on the wrong question.
assert_eq "the sweep still reaches a fixed point on a deleted root" \
    "$( (( _rc == 0 )) && echo clean || echo "rc=$_rc survivors: $(th_reap_fixture_survivors "$R2")" )" clean
sleep 0.4
assert_eq "a process holding a DELETED cwd is still reaped" "$(live "$P2")" dead

echo
echo "=== arm 4: default-DENY — the sweep never reaches outside its root ==="

R3="$TMP/case3"; R4="$TMP/case4"
make_idler "$R3"; make_idler "$R4"
P3=$(spawn_orphaned "$R3")
P4=$(spawn_orphaned "$R4")
assert_eq "bystander in a SIBLING root is up" "$(live "$P4")" alive
th_reap_fixture_root "$R3" KILL 4 >/dev/null
sleep 0.4
assert_eq "the targeted root's process is reaped (positive half)" "$(live "$P3")" dead
assert_eq "…and the sibling root's process is UNTOUCHED (negative twin)" "$(live "$P4")" alive

# A root that names nothing must sweep nothing and say so cleanly.
th_reap_fixture_root "$TMP/never-existed" KILL 2 >/dev/null
_rc=$?
assert_eq "an empty root sweeps cleanly" \
    "$( (( _rc == 0 )) && echo clean || echo "rc=$_rc survivors: $(th_reap_fixture_survivors "$TMP/never-existed")" )" clean
# Refusing dangerous roots outright is the default-deny arm.
th_reap_fixture_root "/" KILL 1 >/dev/null 2>&1
assert_rc "the sweep REFUSES / outright" $? 1
th_reap_fixture_root "relative/path" KILL 1 >/dev/null 2>&1
assert_rc "…and refuses a relative root" $? 1
th_reap_fixture_root "" KILL 1 >/dev/null 2>&1
assert_rc "…and refuses an empty root" $? 1
sleep 0.2
assert_eq "after all three refusals the bystander is STILL alive" "$(live "$P4")" alive

echo
echo "=== arm 5: the sweep reports FAILURE rather than claiming a clean run ==="

# A root whose processes cannot be killed must not read as a fixed point.
# Signal 0 delivers nothing, so the sweep can never converge — the honest
# answer is rc 1, not a cheerful zero. (`#860`'s second fix attempt returned a
# clean result exactly once and would have shipped on it.)
th_reap_fixture_root "$R4" CONT 2 >/dev/null
assert_rc "a sweep that cannot converge returns non-zero" $? 1
assert_eq "…and the bystander it could not reap is still alive" "$(live "$P4")" alive
th_reap_fixture_root "$R4" KILL 4 >/dev/null
sleep 0.4
assert_eq "…and a real signal then reaps it" "$(live "$P4")" dead

echo
echo "=== arm 6: MUTATION PROOFS — the guards, shown to fail ==="
#
# Each mutant is a COPY of _test_helpers.sh with exactly one check removed,
# and each assertion is POSITIVE on the mutant ("it does the wrong thing"), so
# a mutant that failed to build cannot masquerade as a pass. The build itself
# is asserted for the same reason: #869 shipped an inert mutant once and
# caught it only because it checked.

HELPERS="$_self_dir/_test_helpers.sh"

# M1 — restore the pre-#860 behaviour: make the root sweep a no-op. The suite
#      must then observe a SURVIVOR, which is the leak itself.
M1="$TMP/m1_helpers.sh"
sed 's/^th_reap_fixture_root() {/th_reap_fixture_root() { printf 0; return 0;/' "$HELPERS" > "$M1"
assert_eq "M1 mutant built and differs from the original" \
    "$( cmp -s "$M1" "$HELPERS" && echo identical || echo differs )" differs

R5="$TMP/case5"; make_idler "$R5"
P5=$(spawn_orphaned "$R5")
M1_RESULT=$(bash -c '
    . "$1" >/dev/null 2>&1 || exit 3
    th_reap_fixture_root "$2" KILL 4 >/dev/null 2>&1
    sleep 0.4
    kill -0 "$3" 2>/dev/null && echo leaked || echo reaped
' _ "$M1" "$R5" "$P5" 2>/dev/null)
assert_eq "M1 MUTANT: the no-op sweep LEAKS the supervisor" "$M1_RESULT" leaked
# Single-variable control: same fixture, same process, real helpers.
REAL_RESULT=$(bash -c '
    . "$1" >/dev/null 2>&1 || exit 3
    th_reap_fixture_root "$2" KILL 4 >/dev/null 2>&1
    sleep 0.4
    kill -0 "$3" 2>/dev/null && echo leaked || echo reaped
' _ "$HELPERS" "$R5" "$P5" 2>/dev/null)
assert_eq "REAL: the same fixture, same process, is reaped" "$REAL_RESULT" reaped

# M2 — make the sweep claim a fixed point after ONE pass, whether or not
#      anything survived. This is #860's second fix attempt exactly: a single
#      /proc pass that read 3, 0, 3, 1 across four runs, looked clean on the
#      first, and would have shipped on that one green control. The mutant
#      reports SUCCESS with the fixture still alive — a false negative in the
#      one direction that matters, since a caller then stops looking.
M2="$TMP/m2_helpers.sh"
sed 's/^        (( found == 0 )) && { printf/        (( 1 == 1 )) \&\& { printf/' "$HELPERS" > "$M2"
assert_eq "M2 mutant built and differs" \
    "$( cmp -s "$M2" "$HELPERS" && echo identical || echo differs )" differs
# A LIVE fixture is required: a root with nothing in it converges on round one
# for mutant and original alike, which would compare two vacuous zeroes.
R6="$TMP/case6"; make_idler "$R6"
P6=$(spawn_orphaned "$R6")
assert_eq "M2 fixture is live (otherwise the comparison is vacuous)" "$(live "$P6")" alive
M2_RC=$(bash -c '
    . "$1" >/dev/null 2>&1 || exit 3
    th_reap_fixture_root "$2" CONT 4 >/dev/null 2>&1; echo $?
' _ "$M2" "$R6" 2>/dev/null)
REAL_RC=$(bash -c '
    . "$1" >/dev/null 2>&1 || exit 3
    th_reap_fixture_root "$2" CONT 4 >/dev/null 2>&1; echo $?
' _ "$HELPERS" "$R6" 2>/dev/null)
assert_eq "M2 MUTANT: a single-pass sweep reports success it cannot vouch for" "$M2_RC" 0
assert_eq "REAL: the bounded loop reports the failure instead" "$REAL_RC" 1

# M3 — remove the dangerous-root guard, so `/` becomes sweepable. Asserted
#      STRUCTURALLY: actually running a sweep rooted at `/` on a shared host
#      is the harm this guard exists to prevent, and reproducing it to prove
#      it would be reproducing the incident.
M3="$TMP/m3_helpers.sh"
sed '/^    \[\[ -n "\$root" && "\$root" == \/\* && "\$root" != "\/" \]\] || return 1$/d' "$HELPERS" > "$M3"
assert_eq "M3 mutant built and differs" \
    "$( cmp -s "$M3" "$HELPERS" && echo identical || echo differs )" differs
assert_not_contains "M3 MUTANT: the dangerous-root guard is gone" \
    "$(bash -c '. "$1" >/dev/null 2>&1; declare -f th_reap_fixture_root' _ "$M3" 2>/dev/null)" \
    '!= "/"'
assert_contains "REAL: the dangerous-root guard is present" \
    "$(declare -f th_reap_fixture_root)" '!= "/"'

echo
echo "=== arm 7: the pid ledger must cross a command substitution ==="
#
# #860's FIRST cause, and the one the issue did not name: the orphan fixture
# recorded spawned pids into a VARIABLE from inside `X=$(start_sleeper …)`.
# A command substitution runs its body in a subshell, so the append never
# reached the parent and the reap list was empty on every run. Measured here
# rather than asserted, because it is the kind of claim that reads as obvious
# and is routinely got wrong.
LEDGER="$TMP/ledger"; : > "$LEDGER"
VAR_RESULT=$(bash -c '
    ACC=""
    emit_var() { ( sleep 30 ) & ACC="${ACC} $!"; printf "%s" "$!"; }
    P=$(emit_var)
    printf "captured=%s acc=[%s]" "$P" "$ACC"
    kill -TERM "$P" 2>/dev/null
')
assert_contains "a VARIABLE append inside \$( ) is lost — the ledger reads empty" "$VAR_RESULT" "acc=[]"
FILE_RESULT=$(bash -c '
    L="$1"
    emit_file() { ( sleep 30 ) & printf "%s\n" "$!" >> "$L"; printf "%s" "$!"; }
    P=$(emit_file)
    printf "captured=%s ledger=[%s]" "$P" "$(tr -d "\n" < "$L")"
    kill -TERM "$P" 2>/dev/null
' _ "$LEDGER")
assert_not_contains "…while a FILE append survives it (the fix)" "$FILE_RESULT" "ledger=[]"

echo
# COUNT GUARD. This suite spawns processes and deletes directories out from
# under them, so a case that dies early — a fixture that fails to spawn, a
# `th_abort` — would otherwise show up as a SMALLER green rather than a red.
# Pinning the total makes a truncated run a failure. `+ 1` counts this
# assertion itself.
EXPECTED_ASSERTIONS=38
_ran=$(( PASS + FAIL + 1 ))
assert_eq "assertion count is pinned at EXPECTED_ASSERTIONS (a truncated run must be a red, not a smaller green)" \
    "$_ran" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
