#!/usr/bin/env bash
# WHAT THE RUNNER DISPATCHED, WHAT IT RECORDED, AND WHAT IT PRINTED MUST AGREE.
# (your-org/nexus-code#877, #863)
#
# Three channels named on purpose, rather than "the accounting and the verdict
# must not be able to disagree". That earlier phrasing was a universal claim
# about a runner with more than two channels, and it was false as written: the
# `#887` skeptic reproduced `#877`'s symptom on the fixed runner through a
# channel the reconcile did not cover. Naming the three that ARE reconciled says
# what is guaranteed and, just as importantly, bounds it.
#
# WHY THIS FILE EXISTS. `run-tests.sh` computes its verdict from per-job
# sidecars under `$run_dir`, and prints its per-test rows from `run_one`
# directly. Those are two INDEPENDENT channels, and the one that produces the
# EXIT CODE is the one that can silently lose its input. When it does, the
# runner reports `0 failed` and exits 0 — for a run in which tests failed, or
# in which no test executed at all.
#
# Measured on `dev` before this change, `--jobs 2` with `mktemp -p` failing:
#
#     === suite total: 0.04s across 2 tests; 0 failed (0 of those TIMEOUT) ===
#     rc=0
#
# Zero tests ran. That is the whole defect: an UNMEASURED run is not a passing
# run, and absence of a count must never render as `0`.
#
# THIS IS A CLASS, NOT A TRIGGER. `#877` was filed against one cause (a failed
# `mktemp`), but the shape is general — the runner's RECORD of what happened
# diverges from what it DISPATCHED, and the verdict is computed from the
# record. Three triggers are exercised below, and they do NOT all reach the
# same guard, which is why both guards exist:
#
#   trigger                          accounting   dispatch-status
#   ------------------------------   ----------   ---------------
#   T1  `mktemp -p` refused             fires        fires (123)
#   T2  run dir destroyed mid-run       -            fires (123)
#   T3  child killed by a signal        fires        fires (125)
#
# T2 is the reason the dispatch status is not redundant: when the run dir is
# annihilated the sidecars go with it, so the reconcile has nothing left to
# reconcile, and only `xargs`'s own exit status still carries the fact.
#
# THE NEGATIVE CONTROLS ARE THE POINT. A guard that fires on a broken run
# proves nothing unless the SAME fixture, unbroken, produces an ordinary
# verdict — otherwise the guard might simply always fire. Every probe below is
# paired.
#
# #863 IS THE SAME DEFECT ONE LEVEL DOWN: the fork-bomb guard used a bare
# `ulimit -u`, which lowers the HARD limit irreversibly, so a NESTED runner
# could not probe its own fork floor, skipped its guard, and said nothing —
# the harness's own bounding silently invalidating a measurement.
#
# Run: bash monitor/watcher/test-run-tests-accounting-verdict.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
RUNNER="$_test_dir/run-tests.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$RUNNER"; }
gp_handle "$@"

[[ -r "$RUNNER" ]] || { echo "missing runner: $RUNNER" >&2; exit 2; }

WORK=$(mktemp -d) || { echo "FAIL: mktemp for the fixture"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/suite" "$WORK/cwd"

# ── fixtures ────────────────────────────────────────────────────────────
# Quoted heredocs throughout: these fixtures WRITE shell idioms that this
# repo's source lints look for, and an unquoted heredoc would both expand them
# here and present them to the lint as if this file used them.
cat >"$WORK/suite/test-ok.sh" <<'OK'
#!/usr/bin/env bash
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
exit 0
OK
cat >"$WORK/suite/test-red.sh" <<'RED'
#!/usr/bin/env bash
echo "=== summary: 0 passed, 1 failed ==="
exit 1
RED
cat >"$WORK/suite/test-skip.sh" <<'SK'
#!/usr/bin/env bash
echo "SKIP: precondition absent in this fixture"
exit 77
SK
# T3: kill the run_one shell that dispatched us, so no record is ever written.
# A faithful stand-in for the OOM killer, which is the realistic instance.
#
# SCOPED BY VERIFICATION, NOT BY ASSUMPTION. The signal goes to a single PID we
# have positively identified as our own dispatcher — never a pattern match, and
# never a bare `$PPID` taken on trust. Run directly from a shell instead of
# under the runner, a bare `kill -9 "$PPID"` would kill THAT shell; this refuses
# instead. A pattern-matched kill has already taken down four production
# services in this workspace, so a fixture that kills anything must be able to
# say why the target is its own.
#
# NOT the witness your-org/nexus-code#860 dropped, and the difference is the
# whole reason this one is sound. That one SEARCHED —
# `grep -l -F "$root" /proc/[0-9]*/cmdline` — which self-matches (the grep's own
# argv contains the pattern, 100/100 measured) and cannot tell a process living
# in the fixture from a SIBLING that merely mentions it. This reads ONE pid that
# is already known to be ours by the PARENT RELATION: `$PPID` is our parent
# because it exec'd us, not because a search said so. Ownership is established
# by that relation; the argv check only refuses the case where this fixture is
# run directly from a shell instead of under the runner. Identify by
# relationship, corroborate by argv, never search.
cat >"$WORK/suite/test-signalled.sh" <<'SIG'
#!/usr/bin/env bash
target=$PPID
[[ "$target" =~ ^[0-9]+$ ]] && (( target > 1 )) || {
    echo "refusing: implausible parent pid ${target:-<unset>}" >&2; exit 3; }
# The dispatcher is a `bash -c` that has run_one in its command line. Anything
# else — an interactive shell, a CI wrapper, PID 1 — is not ours to signal.
parent_cmd=$(tr '\0' ' ' < "/proc/$target/cmdline" 2>/dev/null)
case "$parent_cmd" in
    *run_one*) : ;;
    *) echo "refusing: parent $target is not a run_one dispatcher: $parent_cmd" >&2; exit 3 ;;
esac
kill -9 "$target" 2>/dev/null
sleep 5
echo "ALL TESTS PASSED"
exit 0
SIG
# The fix's OWN behaviour, not merely the mechanism it addresses (this gap was
# found by mutation M4: reverting `-Su` to a bare `-u` reddened the two source
# assertions and NEITHER behavioural one, because those simulate the outer cap
# with a raw ulimit and so never exercise the runner's own choice). This fixture
# reports the limits the runner actually handed its children.
cat >"$WORK/suite/test-limits.sh" <<'LIM'
#!/usr/bin/env bash
printf 'soft=%s hard=%s\n' "$(ulimit -Su)" "$(ulimit -Hu)" > "$LIMOUT"
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
exit 0
LIM
# SELECTIVE loss of an OUTCOME sidecar, deterministically (#887 skeptic F1).
# Deletes the `.failed` rows of tests that have ALREADY FINISHED, so under
# `--jobs 1` with a genuine red scheduled first this is a fixed ordering, not a
# race — the skeptic's own reproduction polled for its own sidecar and landed on
# one of two attempts. `exec 3>&1` first: `readlink /proc/self/fd/1` reports the
# COMMAND SUBSTITUTION's pipe, never the real stdout, so resolving the run dir
# that way is a confident wrong answer with no error.
cat >"$WORK/suite/test-eater.sh" <<'EAT'
#!/usr/bin/env bash
exec 3>&1
base=$(readlink "/proc/self/fd/3" 2>/dev/null)
rd=$(dirname "${base:-/}")
case "$rd" in
    */nexus-test-runner-*) rm -f "$rd"/*.failed ;;
    *) echo "refusing: not a runner run-dir: $rd" >&2; exit 3 ;;
esac
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
exit 0
EAT
chmod +x "$WORK/suite"/*.sh

# The `mktemp -p` shim (T1). Scoped to `-p` ONLY: the runner also `mktemp -d`s
# its own run dir at startup, and a shim that failed everything would abort
# before reaching the code under test, so every probe below would pass for a
# reason unrelated to the fix.
REAL_MKTEMP=$(command -v mktemp) \
    || { echo "FAIL: cannot resolve a real mktemp to shim" >&2; exit 1; }
{
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do'
    echo '    if [[ "$a" == "-p" ]]; then'
    echo '        echo "mktemp: (fixture) refusing -p" >&2'
    echo '        exit 1'
    echo '    fi'
    echo 'done'
    printf 'exec %q "$@"\n' "$REAL_MKTEMP"
} >"$WORK/bin/mktemp"
chmod +x "$WORK/bin/mktemp"

# Control the shim before trusting anything that depends on it.
( cd "$WORK" && PATH="$WORK/bin:$PATH" mktemp -p "$WORK" out-XXXXXX >/dev/null 2>&1 )
assert_eq "CONTROL: the shim makes 'mktemp -p' fail" "$?" "1"
( cd "$WORK" && PATH="$WORK/bin:$PATH" mktemp -d >/dev/null 2>&1 )
assert_eq "CONTROL: …and leaves 'mktemp -d' working, so the runner still starts" "$?" "0"

# ── probe helper ────────────────────────────────────────────────────────
# Echoes "<rc>" and leaves the run's output in $OUT. Runs from a dedicated
# empty cwd so a regression cannot scribble into the tree under test.
#
# KEEP_LOGS_DIR= ON EVERY NESTED INVOCATION. The outer runner EXPORTS it
# (`run-tests.sh`, the --keep-logs block) and CI's MATRIX arms pass
# `--keep-logs`. Inherited, it moves a nested run's `log_base` out of its own
# run dir to `$KEEP_LOGS_DIR/<parent>__<name>`, so a fixture that resolves its
# sidecar directory from its own stdout lands in the OUTER band's log directory
# and refuses. That is exactly how this suite reddened on the three CI arms that
# pass `--keep-logs` while passing on every serial arm and locally — not a
# parallelism bug, an environment bleed only those arms exposed. Set on ALL five
# nested call sites rather than the one that broke: enumerating variables after
# each failure is how the next one gets missed.
#
# NEXUS_TEST_NPROC_GUARD=off for the ACCOUNTING probes, deliberately. Those
# probes are about whether the tally matches what was dispatched; the fork-bomb
# guard is irrelevant to them, and leaving it on costs a binary-search fork
# probe per invocation whose duration tracks host load. That is not merely
# slow — it is the very self-interference shape `#863` is about, and it would
# make THIS suite a contributor to the band flake it was written to help close.
# The `#863` block below turns the guard back ON, because there it is the
# subject rather than a tax.
#
# SETS TWO GLOBALS, `OUT` and `RC`, and is CALLED DIRECTLY — never as
# `rc=$(run_probe …)`. Command substitution runs the function in a SUBSHELL, so
# an `OUT=` inside it is discarded the instant the substitution closes; the
# caller then asserts against an empty string, and `assert_contains` reports a
# perfectly ordinary-looking failure that says nothing about the cause. Written
# that way first, and six assertions failed with an empty haystack. Worth
# recording precisely because it is this file's own subject one level up: the
# probe reported a result it had not actually obtained.
OUT=""
RC=0
run_probe() {   # <shim:0|1> <jobs> <test…>
    local shim="$1" jobs="$2"; shift 2
    if (( shim )); then
        OUT=$( cd "$WORK/cwd" && PATH="$WORK/bin:$PATH" NEXUS_TEST_NPROC_GUARD=off \
                 KEEP_LOGS_DIR= timeout 120 bash "$RUNNER" --jobs "$jobs" "$@" 2>&1 ); RC=$?
    else
        OUT=$( cd "$WORK/cwd" && NEXUS_TEST_NPROC_GUARD=off \
                 KEEP_LOGS_DIR= timeout 120 bash "$RUNNER" --jobs "$jobs" "$@" 2>&1 ); RC=$?
    fi
}

# ── T1: mktemp refused, parallel arm — the arm CI takes ─────────────────
run_probe 1 2 "$WORK/suite/test-ok.sh" "$WORK/suite/test-red.sh"; rc=$RC
assert_eq "T1 broken accounting on --jobs 2 does NOT exit 0" \
    "$( (( rc != 0 )) && echo nonzero || echo zero )" "nonzero"
assert_contains "T1 the tally line qualifies ITSELF, where the number is" \
    "$OUT" "WERE MEASURED"
assert_contains "T1 the accounting reconcile names the shortfall" \
    "$OUT" "ACCOUNTING INCOMPLETE"
assert_contains "T1 the dispatch status is propagated, not discarded" \
    "$OUT" "DISPATCH FAILED"

# ── T1 NEGATIVE CONTROL: same fixture, no shim ──────────────────────────
# Non-vacuous by construction: identical tests, identical jobs, and the ONLY
# difference is whether the accounting can be written. A red must still read as
# an ordinary red — one failure, counted — and none of the guards may fire.
run_probe 0 2 "$WORK/suite/test-ok.sh" "$WORK/suite/test-red.sh"; rc=$RC
assert_eq "CONTROL a genuine failure still exits 1 (not the accounting path)" "$rc" "1"
assert_contains "CONTROL the genuine red is COUNTED: '1 failed'" "$OUT" "1 failed"
assert_not_contains "CONTROL no accounting error on a sound run" "$OUT" "ACCOUNTING INCOMPLETE"
assert_not_contains "CONTROL nor a verdict/record disagreement on a sound run" \
    "$OUT" "VERDICT DISAGREES"
assert_not_contains "CONTROL no dispatch error on a sound run" "$OUT" "DISPATCH FAILED"
assert_not_contains "CONTROL the tally does NOT self-qualify on a sound run" "$OUT" "WERE MEASURED"

# ── the designed false positive: an all-SKIP run ────────────────────────
# `exit 77` writes NO outcome sidecar on this path, so a naive "no sidecars
# means refuse" rule would redden a legitimately all-skipped run. This is the
# assertion that forced the terminal record to be its own file rather than a
# quantity derived from the outcome sidecars.
run_probe 0 2 "$WORK/suite/test-skip.sh" "$WORK/suite/test-skip.sh"; rc=$RC
assert_eq "an ALL-SKIP run stays green — skips are accounted, not missing" "$rc" "0"
assert_not_contains "…and does not trip the reconcile" "$OUT" "ACCOUNTING INCOMPLETE"

# ── ordinary green, both arms ───────────────────────────────────────────
for j in 1 2; do
    run_probe 0 "$j" "$WORK/suite/test-ok.sh"; rc=$RC
    assert_eq "a sound green run on --jobs $j still exits 0" "$rc" "0"
done

# ── T3: a child killed by a signal ──────────────────────────────────────
# Dispatched, partially ran, never recorded — and `xargs` reports 125 rather
# than 123, so this also exercises a different arm of the status decoding.
run_probe 0 2 "$WORK/suite/test-signalled.sh" "$WORK/suite/test-ok.sh"; rc=$RC
assert_eq "T3 a signalled child does NOT leave the run green" \
    "$( (( rc != 0 )) && echo nonzero || echo zero )" "nonzero"
assert_contains "T3 the reconcile catches the missing verdict" "$OUT" "ACCOUNTING INCOMPLETE"

# ── the VERDICT channel vs the PRINTED ROWS (#887 skeptic F1) ───────────
# The reconcile above compares the RECORD against DISPATCH, and is blind to a
# SELECTIVE loss of an outcome sidecar: the record still reconciles, the
# dispatcher still exits 0, and a run that PRINTED a `FAIL` row reports
# `0 failed` and exits 0 — `#877`'s symptom surviving the fix for `#877`.
# Serial and ordered, so the eater always runs after the red has recorded.
run_probe 0 1 "$WORK/suite/test-red.sh" "$WORK/suite/test-eater.sh"
assert_eq "a LOST outcome sidecar does not leave a printed FAIL reported as 0 failed" \
    "$( (( RC != 0 )) && echo nonzero || echo zero )" "nonzero"
assert_contains "…and the runner names the disagreement rather than picking a side" \
    "$OUT" "VERDICT DISAGREES WITH THE RECORD"

# ── BROKEN BEATS INCOMPLETE: the exit-code precedence clause ────────────
# Under a `--state` ledger a lost verdict ALSO shows up as `n_unrecorded > 0`,
# so without the precedence clause the runner takes the exit-3 arm — whose
# contract is "budget stopped this invocation, resume with the same command".
# Resuming does not repair a refused `mktemp`, and `tests-slow-integration.yml`
# acts on rc 3. So the distinction is rc 1 (broken, do not merge) vs rc 3
# (incomplete, resume), and it is the ONLY thing this probe is about.
#
# WHY THIS EXISTS AT ALL: the clause was defended at length in a commit message
# and pinned by nothing — removing it left this suite 27/27 green while flipping
# rc 1 → 3 (your-org/nexus-code#887 skeptic F2). Argued-for-at-length and
# unguarded is a recognisable pair, and by this suite's own standard three
# commits earlier, "a guard that cannot fail when the thing it guards is removed
# is not evidence."
#
# Reaches the clause via the one shape that sets `_accounting_broken` on the
# LEDGER path: `--state` with `--jobs 2`, so `dispatch_rc` is captured. No
# workflow runs that shape today; this is latent insurance, deliberately.
run_probe 1 2 --state "$WORK/precedence.tsv" "$WORK/suite/test-ok.sh" "$WORK/suite/test-red.sh"
assert_eq "the ledger path reports a BROKEN run as red (1), not resumable (3)" "$RC" "1"
assert_contains "…and says which, rather than advising a futile resume" \
    "$OUT" "DISPATCH FAILED"
assert_not_contains "…and does NOT tell the caller to resume" \
    "$OUT" "Resume with the SAME command"

# ── #863: the cap must be SOFT-ONLY ─────────────────────────────────────
# Source-level first, because it is the invariant that cannot drift: a bare
# `ulimit -u` for the cap lowers HARD too, and that is irreversible.
assert_eq "#863 the nproc cap is applied with -Su (soft only)" \
    "$(grep -c 'ulimit -Su "\$_nproc_cap"' "$RUNNER")" "1"
assert_eq "#863 …and never with a bare 'ulimit -u' for that cap" \
    "$(grep -c 'ulimit -u "\$_nproc_cap"' "$RUNNER")" "0"

# Assertions outside the host-dependent blocks below. Declared BEFORE the first
# of them, because those only ever ADD to it — and `set -u` caught the ordering
# the one time it was wrong, which is the argument for `set -u`.
EXPECTED=28

# THE FIX ITSELF, behaviourally: after the runner applies its cap, the HARD
# limit its children inherit must be UNCHANGED. This is the assertion mutation
# M4 should have reddened and did not, so it is the one that actually pins
# `-Su`. Cheap, and it needs no nested runner: what a child inherits is exactly
# what a nested runner would have to work within.
_parent_hard=$(ulimit -Hu 2>/dev/null || echo unlimited)
_lim_out=$(LIMOUT="$WORK/limits.txt" KEEP_LOGS_DIR= \
             timeout 120 bash "$RUNNER" "$WORK/suite/test-limits.sh" 2>&1)
_child_hard=$(sed -n 's/.*hard=\([0-9a-z]*\).*/\1/p' "$WORK/limits.txt" 2>/dev/null)
_child_soft=$(sed -n 's/.*soft=\([0-9a-z]*\).*/\1/p' "$WORK/limits.txt" 2>/dev/null)
# The cap the guard ANNOUNCED, read from its own banner. `awk` rather than
# `… | head -1` for the early-exit-reader reason given below.
_ann_cap=$(printf '%s\n' "$_lim_out" | awk '
    /RLIMIT_NPROC capped at/ {
        if (!c && match($0, /capped at [0-9]+/))
            c = substr($0, RSTART + 10, RLENGTH - 10)
    }
    END { print c }')
# NON-VACUITY IS "DID THE GUARD ENGAGE", NOT "DID SOFT GO DOWN". The first
# spelling asserted `child_soft < parent_soft`, which is false on a host whose
# ambient soft limit is already BELOW the computed cap — `ulimit -Su` then does
# not lower anything, and the arm reddened on every CI runner while passing
# locally. That is an environment difference, not a defect, and an assertion
# that cannot tell the two apart is worse than none. The banner states engagement
# directly, so gate on it and SKIP when the guard legitimately declined.
# THE PRECONDITION THAT MAKES THE PAIR DISCRIMINATING, checked rather than
# assumed. If the host's `parent_hard` happened to EQUAL the announced cap, then
# a runner that wrongly lowered HARD would set it to that same number, and
# `child_hard == parent_hard` would hold under BOTH the fixed and the broken
# code — the arm would pass while detecting nothing. That is a narrow window
# (the cap is `probed_floor + headroom`, so equality is a coincidence), but
# "narrow" is not "checked", and the previous version of this control was lost
# to exactly the habit of assuming an ambient property instead of testing it.
# Where the window is open, SKIP and say so; never assert into it.
if [[ "$_ann_cap" =~ ^[0-9]+$ && -n "$_child_hard" && "$_parent_hard" != "$_ann_cap" ]]; then
    EXPECTED=$(( EXPECTED + 2 ))
    assert_eq "#863 the runner leaves the HARD limit its children inherit UNCHANGED" \
        "$_child_hard" "$_parent_hard"
    # Pins SOFT to the exact number the guard ANNOUNCED. Both sides of this
    # comparison are produced by the run under test — what the guard SAID it did
    # against what its child ACTUALLY got — so it references no ambient property
    # of the host at all. That is the whole difference from the control it
    # replaced, which compared an output against the machine's own soft limit
    # and so could only be as portable as the machine.
    assert_eq "#863 CONTROL …while SOFT is exactly the cap the guard announced" \
        "$_child_soft" "$_ann_cap"
elif [[ "$_ann_cap" =~ ^[0-9]+$ && "$_parent_hard" == "$_ann_cap" ]]; then
    printf '  SKIP: #863 inherited-limit arm — parent HARD (%s) equals the announced cap, so this arm could not tell a soft-only cap from a soft+hard one here\n' \
        "$_parent_hard"
else
    printf '  SKIP: #863 inherited-limit arm — guard did not engage here (cap=%q child_hard=%q)\n' \
        "${_ann_cap:-<none>}" "${_child_hard:-<none>}"
fi

# Behavioural arm. Probe the fork floor the way the guard does, then run the
# runner NESTED under two outer caps that differ in EXACTLY ONE axis — the
# hard limit — with soft held identical. That isolation is the whole argument:
# if soft differed too, a banner difference would prove nothing.
FLOOR=$(bash -c '
  probe(){ ( ulimit -Su "$1" 2>/dev/null || exit 1; p=$(/bin/echo ok) || exit 1; [ "$p" = ok ] ) 2>/dev/null; }
  cur=$(ps -eLo pid= 2>/dev/null | grep -c .); lo=0; hi=""
  case "$cur" in ""|*[!0-9]*) cur=64 ;; esac
  cand=$(( cur > 64 ? cur : 64 ))
  for i in 1 2 3 4 5 6 7 8; do if probe "$cand"; then hi=$cand; break; fi; lo=$cand; cand=$((cand*2)); done
  [ -n "$hi" ] || exit 1
  while (( hi - lo > 32 )); do mid=$(((lo+hi)/2)); if probe "$mid"; then hi=$mid; else lo=$mid; fi; done
  echo "$hi"' 2>/dev/null)

if [[ "$FLOOR" =~ ^[0-9]+$ ]] && (( FLOOR > 0 )); then
    # TWO CONSTANTS THAT MUST NOT COLLIDE, and getting them wrong is silent.
    #   _tight   how much room the outer cap leaves ABOVE the fork floor. It has
    #            to be generous enough that the inner runner can actually fork —
    #            at floor+8 the inner run died in `bash: fork: Resource
    #            temporarily unavailable`, which reddens the arm for a reason
    #            that has nothing to do with the hard/soft distinction.
    #   _inner   the inner guard's requested headroom. It must EXCEED _tight, or
    #            the inner cap would fit under the inherited hard limit and the
    #            old behaviour would engage after all — a discriminator that
    #            does not discriminate, passing for the wrong reason.
    _tight=$(( FLOOR + 512 ))
    _inner=4096
    # OLD behaviour: soft AND hard lowered. The inner guard cannot engage.
    _old=$(bash -c "ulimit -u $_tight 2>/dev/null || exit 9
                    NEXUS_TEST_NPROC_HEADROOM=$_inner KEEP_LOGS_DIR= timeout 120 bash '$RUNNER' '$WORK/suite/test-ok.sh' 2>&1" )
    # NEW behaviour: soft only. Hard survives, so the inner guard can engage.
    _new=$(bash -c "ulimit -Su $_tight 2>/dev/null || exit 9
                    NEXUS_TEST_NPROC_HEADROOM=$_inner KEEP_LOGS_DIR= timeout 120 bash '$RUNNER' '$WORK/suite/test-ok.sh' 2>&1" )
    if [[ "$_old" == *"RLIMIT_NPROC capped at"* ]] || [[ "$_new" != *"RLIMIT_NPROC capped at"* ]]; then
        # Either the discriminator did not discriminate, or the host refused
        # the fixture's own ulimit calls. Say which rather than assert into it:
        # an environment-dependent probe that asserts anyway is how a red that
        # means "this host is unusual" gets read as "the code is broken".
        printf '  SKIP: #863 nested arm — host did not produce the two-arm contrast (floor=%s tight=%s)\n' \
            "$FLOOR" "$_tight"
    else
        EXPECTED=$(( EXPECTED + 2 ))
        assert_contains "#863 under a soft-only outer cap the NESTED guard engages" \
            "$_new" "RLIMIT_NPROC capped at"
        assert_not_contains "#863 …and under the old soft+hard cap it could not" \
            "$_old" "RLIMIT_NPROC capped at"
    fi
    # Whichever arm ran, a guard that declines to engage must SAY SO. Silence
    # is the #863 defect itself: T6a reported `banner absent or wrong` with no
    # way to tell whether the guard skipped or the runner never started.
    # GUARDED ON HAVING OUTPUT TO READ AT ALL. The SKIP branch above exists for
    # the case where this host refused the fixture's own `ulimit` calls — and if
    # it did, `$_old` is EMPTY, so asserting here reddens on an empty haystack:
    # a claim about the RUNNER failing because of the HOST, which is precisely
    # the class the previous commit exists to remove, one arm down. Counted
    # conditionally like the two assertions above it, so the total still cannot
    # drift (your-org/nexus-code#887 skeptic F3).
    if [[ -n "$_old" ]]; then
        EXPECTED=$(( EXPECTED + 1 ))
        assert_contains "#863 a guard that does not engage announces it" \
            "$_old" "nproc guard:"
    else
        printf '  SKIP: #863 announce-on-decline — the host refused the fixture ulimit calls, so there is no runner output to read\n'
    fi
else
    printf '  SKIP: #863 nested arm — could not probe a fork floor on this host\n'
fi

# ── the guard's own predicate, applied to the guard ─────────────────────
# `#877` is about a runner that reports a verdict it did not earn. The same
# question has to be asked of the fix: can the reconcile pass for a reason
# other than the run being sound? Its numerator is a file it writes itself, so
# the failure mode to exclude is the record being written somewhere the count
# cannot see — i.e. per-ARM rather than once. Pin it structurally: the record
# is written ABOVE the outcome `case`, so a future outcome cannot be added
# without it.
# ONE PASS, NO EARLY EXIT. The obvious spelling is `grep -n … | head -1`, and
# `head` (like `grep -m`, `sed …q`, `awk …exit`) is an early-exit reader that
# `early-exit-readers.manifest` requires a declaration for. Rather than claim a
# manifest row — in a file another open PR is also editing — this asks the
# question directly: read to EOF, remember the first line of each pattern,
# compare at END. Both patterns are unique in the runner, so `if (!x)` is
# belt-and-braces rather than disambiguation.
_order=$(awk '
    /out_file\.accounted/        { if (!a) a = NR }
    /^    case "\$status" in/    { if (!c) c = NR }
    END { print (a && c && a < c) ? "above" : "below" }
' "$RUNNER")
assert_eq "the terminal record is written ABOVE the outcome case (not per-arm)" \
    "$_order" "above"
assert_eq "…and exactly once, so the count cannot be inflated by a second write" \
    "$(grep -c 'printf .*>> "\$out_file.accounted"' "$RUNNER")" "1"

# ── the tree this suite is about ────────────────────────────────────────
repo_stray=0
for s in .assertions .caseskipped .err .failed .nocount .out .timedout .zerocount .accounted; do
    [[ -e "$REPO_ROOT/$s" ]] && repo_stray=$(( repo_stray + 1 ))
done
assert_eq "the repo root carries none of the nine sidecar names" "$repo_stray" "0"

# THE SUITE'S OWN COUNT, checked rather than assumed — the same rule this file
# exists to enforce on the runner. A suite that silently ran fewer assertions
# than it contains is a green that covers less than it appears to.
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
