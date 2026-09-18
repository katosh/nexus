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
cat >"$WORK/suite/test-stdin.sh" <<'STDIN'
#!/usr/bin/env bash
# Stands in for ANY callee that reads stdin — monitor/send.sh:504 is the live
# one (your-org/nexus-code#1152). Its verdict must be a property of the RUNNER,
# never of whoever invoked the runner.
out=$(timeout 5 cat); rc=$?
if (( rc == 0 )); then echo "=== summary: 1 passed, 0 failed ==="; exit 0
else echo "FAIL: callee blocked on an inherited stdin"; echo "=== summary: 0 passed, 1 failed ==="; exit 1; fi
STDIN
cat >"$WORK/suite/test-vacuous.sh" <<'VAC'
#!/usr/bin/env bash
# Asserts NOTHING and prints NO footer this runner can read: the shape #1185 is
# about, one step to the left of #1145's readable zero.
echo "doing nothing at all"
exit 0
VAC
cat >"$WORK/suite/test-unread-footer.sh" <<'UNR'
#!/usr/bin/env bash
# Normalisation DEBT, not vacuity: a footer spelling the runner cannot read, but
# real per-assertion lines. Must stay GREEN — the control that stops the #1185
# gate reddening on the wrong defect.
echo "PASS: alpha holds"
echo "PASS: beta holds"
echo "~~~ tally :: two green, nought red ~~~"
exit 0
UNR
cat >"$WORK/suite/test-slowish.sh" <<'SLO'
#!/usr/bin/env bash
sleep 6
echo "=== summary: 1 passed, 0 failed ==="
exit 0
SLO
chmod +x "$WORK/suite"/*.sh

# ── #992 / #1031 / #997 fixtures ────────────────────────────────────────
# Quoted heredocs, as above and for a sharper reason here: `test-echoes.sh`
# EMITS a specimen footer line, which is the exact idiom #997 is about. An
# unquoted heredoc would expand it here and, worse, would present a live
# footer-shaped line to this file's own stdout — where the runner reading THIS
# suite would score it on the fixture. That is #997 reproduced inside the test
# for #997.
cat >"$WORK/suite/test-slow2.sh" <<'SLOW'
#!/usr/bin/env bash
sleep 2
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
SLOW
cat >"$WORK/suite/test-hangs.sh" <<'HANG'
#!/usr/bin/env bash
sleep 6
echo "=== summary: 1 passed, 0 failed ==="
HANG
cat >"$WORK/suite/test-skipper.sh" <<'SKP'
#!/usr/bin/env bash
echo "  SKIP: precondition absent"
echo "=== summary: 9 passed, 0 failed, 1 SKIPPED (precondition absent — NOT covered) ==="
echo "ALL TESTS PASSED (1 case(s) SKIPPED — NOT covered)"
SKP
cat >"$WORK/suite/test-echoes.sh" <<'ECH'
#!/usr/bin/env bash
echo "  PASS: capture: === summary: 41 passed, 0 failed, 2 SKIPPED (precond"
echo "=== summary: 63 passed, 0 failed ==="
echo "ALL TESTS PASSED"
ECH
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

# ── A SUITE'S VERDICT IS NOT A PROPERTY OF WHO INVOKED IT (#1152) ───────
# The runner dispatches every test through `run_one`; if that exec does not
# redirect stdin, the test inherits the INVOKER'S — so the same suite, same
# tree, same commit returns a different verdict under CI, under a terminal, and
# under an agent's Bash tool (where stdin is a socket: neither a TTY nor at
# EOF, which is the hanging case). Measured before the fix: PASS in 0.02s under
# `</dev/null`, FAIL in 5.01s under an open pipe that never writes.
#
# KEYED ON THE PROPERTY, NOT THE REDIRECT. This varies the one input that must
# not matter — the invoker's stdin — and asserts the verdict does not move. It
# does not grep run_one for `</dev/null`, because a guard keyed on the fix's
# SHAPE passes on any rewrite that keeps the token and loses the behaviour, and
# fails on any correct fix spelled differently.
#
# BOTH ARMS, because they dispatch differently — and MEASURED, they are NOT
# equally exposed. #1152 states "neither dispatch arm redirects stdin" and
# prescribes a redirect on both. Measured here, GNU findutils xargs 4.7.0 opens
# `/dev/null` as its CHILD'S stdin (`readlink /proc/self/fd/0` -> `/dev/null`),
# so the PARALLEL arm was already protected and only the SERIAL arm could hang:
# under the pre-fix runner this loop failed at `--jobs 1` and PASSED at
# `--jobs 2`. That is why CI never saw it — CI runs parallel — and why it
# surfaced under agents and humans, who run serially.
#
# The redirect stays anyway, and in run_one rather than on either arm: relying
# on xargs to supply `/dev/null` is an undeclared dependency on one
# implementation's behaviour, and the serial arm has no such benefactor. The
# `--jobs 2` rows below therefore assert a property that holds for a DIFFERENT
# reason than the `--jobs 1` rows — recorded because a reader who assumes both
# rows detect the same regression would be wrong.
for j in 1 2; do
    run_probe 0 "$j" "$WORK/suite/test-stdin.sh" </dev/null; _sv_null=$RC
    # An open pipe that never writes: the shape that hangs a stdin-reading
    # callee. PROCESS SUBSTITUTION, not `{ sleep 25; } | run_probe` — piping
    # INTO a function runs it in a SUBSHELL, so its `RC=` assignment would be
    # discarded and this would silently compare a STALE value against itself,
    # passing whether or not the runner was fixed. A guard that cannot fail is
    # the thing this file exists to prevent.
    run_probe 0 "$j" "$WORK/suite/test-stdin.sh" < <(sleep 25); _sv_pipe=$RC
    assert_eq "stdin-invariance --jobs $j: verdict identical under /dev/null and an open pipe" \
        "$_sv_null" "$_sv_pipe"
    assert_eq "stdin-invariance --jobs $j: and that shared verdict is GREEN, not a shared red" \
        "$_sv_null" "0"
done

# ── `?` IS NOT "FINE" (your-org/nexus-code#1185) ────────────────────────
# #1145's ratchet reds the READABLE zero, so the escape from it was to be LESS
# legible: a suite asserting nothing whose footer the runner cannot read printed
# `assertions ?` and the run stayed green. The gate is CONJUNCTIVE — footer
# unreadable AND no per-assertion line — and THE PAIR IS THE TEST. A gate that
# only fires is not evidence; what makes it safe to enable is that the
# normalisation-debt case beside it stays green.
run_probe 0 1 "$WORK/suite/test-vacuous.sh"
assert_contains "a suite that asserts nothing AND prints no readable footer is NAMED" \
    "$OUT" "unverifiable pass"
# A CENSUS, NOT A RED — measured, not cautious. Built as a refusal (what #1185
# asks for) and run over the whole corpus, it reddens NOTHING real: all 390
# suites declare a machine-readable count. Its only observed effect was on
# PLANTED FIXTURES, and reddening those contradicts the deliberate floor in
# test-assertion-accounting.sh section 7 ("2 footerless fixtures below the floor
# stay GREEN — no false red"). The missing half was OBSERVABILITY, and that is
# what shipped.
assert_eq "…but does NOT redden the run — see #1185, and section 7's floor" "$RC" "0"
run_probe 0 1 "$WORK/suite/test-unread-footer.sh"
assert_eq "an UNREADABLE FOOTER with real assertion lines stays GREEN" "$RC" "0"
assert_contains "…and is reported as normalisation debt only" "$OUT" "assertions ?:"
assert_not_contains "…never as an unverifiable pass" "$OUT" "unverifiable pass"

# ── A CEILING IS A PROPERTY OF THE SUITE (your-org/nexus-code#992) ──────
# A suite whose wall sits just under the ceiling FLAPS rather than fails, and a
# flap carries no diagnostic content. ceiling-overrides.tsv raises the ceiling
# for a named suite. Both directions asserted, because the dangerous one is the
# LOWER: a row that could shorten a ceiling would convert real passes into
# timeouts — a false red, which trains readers to distrust the census.
_ov="$WORK/ceil.tsv"; _slow="$WORK/suite/test-slowish.sh"
_run_ceil() {  # <override-file> <run-timeout> [jobs]
    OUT=$( cd "$WORK/cwd" && NEXUS_TEST_NPROC_GUARD=off KEEP_LOGS_DIR= \
             _RT_CEILING_FILE="$1" timeout 120 bash "$RUNNER" --jobs "${3:-1}" \
             --timeout "$2" "$_slow" </dev/null 2>&1 ); RC=$?
}
# KEYED ON THE VERDICT ROW, NOT THE WORD. `assert_contains "$OUT" "TIMEOUT"` is
# VACUOUS here: the runner's own footer reads `(0 of those TIMEOUT)` on an
# ALL-PASS run, so that assertion passes whether or not any ceiling applied.
# Measured — it survived a mutant that removed `export -f _rt_ceiling_for` and
# disabled the per-test ceiling outright. The row is the evidence:
#     TIMEOUT  test-slowish.sh    3.02s  (ceiling 3s +15s KILL grace; rc=124 …)
_run_ceil /nonexistent 3
assert_contains "NEGATIVE CONTROL: with no override the 6s fixture TIMEOUTs at a 3s ceiling" \
    "$OUT" "TIMEOUT  test-slowish.sh"
printf 'test-slowish.sh\t60\t6.0\tfixture\n' > "$_ov"
_run_ceil "$_ov" 3
assert_eq "a measured override RAISES the ceiling and the same fixture passes" "$RC" "0"
printf 'test-slowish.sh\t3\t6.0\tfixture\n' > "$_ov"
_run_ceil "$_ov" 60
assert_eq "an override BELOW the run ceiling never lowers it" "$RC" "0"
printf 'test-slowish.sh\tNOTANUMBER\t6.0\tfixture\n' > "$_ov"
_run_ceil "$_ov" 3
assert_contains "a malformed row is ignored — shape validated, not emptiness" \
    "$OUT" "TIMEOUT  test-slowish.sh"

# THE PARALLEL ARM, and this row is not redundant with the ones above. `xargs …
# bash -c` gives each child a FRESH shell, so a helper `run_one` calls must be
# `export -f`'d or it is `command not found` there. `_rt_ceiling_for` was NOT
# exported in the first cut of #992, and the failure is toward PERMISSIVENESS:
# PER_TEST_TIMEOUT resolved EMPTY in every parallel child, so #499's hard
# per-test bound was silently DISABLED for the arm CI actually runs. Nothing at
# --jobs 1 can see it, which is why this asserts the ceiling in the arm the
# helper has to travel to.
_run_ceil /nonexistent 3 2
assert_contains "the ceiling still applies in the PARALLEL arm (helpers are export -f'd)" \
    "$OUT" "TIMEOUT  test-slowish.sh"
assert_not_contains "…and no run_one callee is missing from the parallel children" \
    "$OUT" "command not found"

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
# _occurrences <pattern> <file> — OCCURRENCES, not lines (your-org/nexus-code
# `#1026`). `grep -c` counts matching LINES, so two constructs sharing one line
# read as 1 and an `== N` assertion stays green with the construct duplicated.
# `-F` because every caller passes a LITERAL. On no match grep prints nothing
# and exits 1, yielding 0 — a replacement, never an appended second value, so
# no `|| echo 0` belongs here (your-org/nexus-code#725).
_occurrences() { grep -oF -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
# …and the REGEX sibling. Kept distinct on purpose: passing a pattern carrying
# `.*` to the `-F` form matches nothing and returns 0, which an `== 1`
# assertion reports as a defect in the SUBJECT rather than in the probe.
_occurrences_re() { grep -oE -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }

assert_eq "#863 the nproc cap is applied with -Su (soft only)" \
    "$(_occurrences 'ulimit -Su "$_nproc_cap"' "$RUNNER")" "1"
assert_eq "#863 …and never with a bare 'ulimit -u' for that cap" \
    "$(grep -c 'ulimit -u "\$_nproc_cap"' "$RUNNER")" "0"

# Assertions outside the host-dependent blocks below. Declared BEFORE the first
# of them, because those only ever ADD to it — and `set -u` caught the ordering
# the one time it was wrong, which is the argument for `set -u`.
# The BASE, i.e. the UNCONDITIONAL assertions only. Three host-dependent #863
# arms bump it by +2/+2/+1 as they run, so a base read off a run's "N ran"
# figure double-counts every arm that fired — 74 ran, 79 expected, and the
# mismatch guard is the only thing that says so. Set it from the run's actual
# total MINUS the bumps that fired, never from the total itself.
EXPECTED=96   # +11: the #1481 short-private-root arm, its contract, sweep, parallel identity

# ── #1481: the per-suite private root is SHORT, /tmp-rooted, serves BOTH ─────
# TMPDIR and TMUX_TMPDIR, and is reaped when the suite exits. The first cut
# rooted it under the log directory (~90 bytes on CI) and six bands went red:
# tmux fixtures blew sun_path, one suite asserted its fixture is under /tmp,
# one capped a diagnostic at 300 B. Planted suite prints what it was handed.
cat >"$WORK/suite/test-tmproot.sh" <<'TR'
#!/usr/bin/env bash
printf 'TMPDIR=%s\nTMUX_TMPDIR=%s\n' "${TMPDIR:-<unset>}" "${TMUX_TMPDIR:-<unset>}" > "${TMPROOT_REPORT:?}"
echo "=== summary: 1 passed, 0 failed ==="
exit 0
TR
chmod +x "$WORK/suite/test-tmproot.sh"
TMPROOT_REPORT="$WORK/tmproot.txt" bash "$RUNNER" -- "$WORK/suite/test-tmproot.sh" >/dev/null 2>&1 || true
_tr_tmp=$(sed -n 's/^TMPDIR=//p' "$WORK/tmproot.txt" 2>/dev/null)
_tr_tt=$(sed -n 's/^TMUX_TMPDIR=//p' "$WORK/tmproot.txt" 2>/dev/null)
assert_eq "#1481 the suite's TMPDIR is a private /tmp/nxt-* root" "$( [[ "$_tr_tmp" == /tmp/nxt-* ]] && echo yes || echo "NO ($_tr_tmp)" )" "yes"
assert_eq "#1481 …and SHORT (< 40 bytes; sun_path is 108 and a socket name needs room)" "$( (( ${#_tr_tmp} < 40 )) && echo yes || echo "NO (${#_tr_tmp})" )" "yes"
assert_eq "#1481 TMUX_TMPDIR is the SAME short root (one root, two variables — nothing derives a socket path from a long TMPDIR)" "$_tr_tt" "$_tr_tmp"
assert_eq "#1481 …and it is REAPED when the suite exits" "$( [[ -n "$_tr_tmp" && ! -e "$_tr_tmp" ]] && echo gone || echo "STILL THERE" )" "gone"
assert_eq "#1481 CONTRACT: no path element of the root is spelled like a suite file" \
    "$(tr '/' '\n' <<<"$_tr_tmp" | grep -cE '^test-.*\.sh')" "0"
# THE CONTRACT ASSERTION FIRES (its positive control): point the root base at a
# long directory and the runner must REFUSE with the reason, before dispatch.
_long_base="$WORK/$(printf 'long-%.0s' $(seq 1 10) | tr ' ' '-')"; mkdir -p "$_long_base"
_cv_out=$(NEXUS_TEST_PRIVATE_ROOT_BASE="$_long_base" bash "$RUNNER" -- "$WORK/suite/test-ok.sh" 2>&1); _cv_rc=$?
assert_eq "#1481 CONTRACT fires: a root base that makes the root too long is REFUSED (2), not handed out" "$_cv_rc" "2"
assert_contains "#1481 …naming the violated clause" "$_cv_out" "violates the harness contract"
# THE SWEEP SURVIVES A SIGKILL: a trap EXIT dies with a cancelled band. Plant
# three roots under a private base — a DEAD pid and old (reaped), a live
# process whose argv IS a run-tests.sh (kept), a dead pid but YOUNG (kept: the
# age floor) — and run the runner once.
_sw_base="$WORK/swb"; mkdir -p "$_sw_base"; _uid=$(id -u)
mkdir -p "$_sw_base/nxt-$_uid-99999999-dead" && touch -d '2000-01-01' "$_sw_base/nxt-$_uid-99999999-dead"
sleep 300 & _live_pid=$!
mkdir -p "$_sw_base/nxt-$_uid-$_live_pid-live" && touch -d '2000-01-01' "$_sw_base/nxt-$_uid-$_live_pid-live"
mkdir -p "$_sw_base/nxt-$_uid-99999998-young"
NEXUS_TEST_PRIVATE_ROOT_BASE="$_sw_base" bash "$RUNNER" -- "$WORK/suite/test-ok.sh" >/dev/null 2>&1 || true
assert_eq "#1481 SWEEP: a stale root whose pid is GONE and older than the floor is reaped at runner start" \
    "$( [[ -e "$_sw_base/nxt-$_uid-99999999-dead" ]] && echo "STILL THERE" || echo reaped )" "reaped"
assert_eq "#1481 SWEEP: a root whose pid is ALIVE — a plain sleep, nothing in its cmdline says runner — is KEPT however old (liveness, not a name, decides; #851's shape otherwise)" \
    "$( [[ -d "$_sw_base/nxt-$_uid-$_live_pid-live" ]] && echo kept || echo "REAPED" )" "kept"
assert_eq "#1481 SWEEP: a dead-pid root YOUNGER than the floor is KEPT (liveness plus an age floor, never age alone)" \
    "$( [[ -d "$_sw_base/nxt-$_uid-99999998-young" ]] && echo kept || echo "REAPED" )" "kept"
kill "$_live_pid" 2>/dev/null; wait "$_live_pid" 2>/dev/null || true
# THE PARALLEL ARM NAMES ROOTS BY THE RUNNER'S PID, NOT THE xargs CHILD'S: two
# planted suites under --jobs 2 must report roots sharing ONE pid component —
# the identity a sibling's sweep can attribute to this live run.
cat >"$WORK/suite/test-tmproot2.sh" <<'TR2'
#!/usr/bin/env bash
printf '%s\n' "${TMPDIR:-<unset>}" >> "${TMPROOT_REPORT2:?}"
echo "=== summary: 1 passed, 0 failed ==="
exit 0
TR2
cp "$WORK/suite/test-tmproot2.sh" "$WORK/suite/test-tmproot3.sh"; chmod +x "$WORK/suite/test-tmproot2.sh" "$WORK/suite/test-tmproot3.sh"
: > "$WORK/tmproot2.txt"
TMPROOT_REPORT2="$WORK/tmproot2.txt" bash "$RUNNER" --jobs 2 -- "$WORK/suite/test-tmproot2.sh" "$WORK/suite/test-tmproot3.sh" >/dev/null 2>&1 || true
_pids=$(sed -nE 's#^/tmp/nxt-[0-9]+-([0-9]+)-[0-9]+$#\1#p' "$WORK/tmproot2.txt" | sort -u | grep -c .)
assert_eq "#1481 PARALLEL: two suites under --jobs 2 carry the SAME pid in their roots (the runner's, not each xargs child's)" "$_pids" "1"

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

# ── #992: the flap band — a verdict whose reproducibility is now visible ──
#
# A suite finishing just under its ceiling does not fail, it FLAPS: measured,
# test-run-tests-bounded.sh TIMEOUTs at 600.01s against a 600s ceiling and
# PASSes at 570.21s against a 650s one, on identical code at host load 35/36.
# The runner was already honest about the outcome (rc=124 is TIMEOUT, never a
# pass, #499); what it never printed was the MARGIN that decides whether the
# verdict reproduces. So `PASS` was a label whose definition, for these suites,
# was "passed this time" — the same label-vs-definition gap as #1031 and #997,
# one step over from a count to a verdict.
#
# THESE PROBES ARE LOAD-MONOTONE IN THE SAFE DIRECTION, which matters more here
# than anywhere else in this file: a test for a timing defect that is itself
# timing-flaky would be the defect. `sleep 2` under a 3s ceiling is >=67% used,
# and load can only push that UP, never down — so the threshold is pinned at 50
# and cannot go green by accident. The negative control below uses a 60s ceiling
# on a fixture that does no work: it would need 30 seconds of stolen wall to
# false-positive.
#
# THE THRESHOLD IS PINNED EXPLICITLY, not inherited. Written first without it,
# this probe ran at the 80 default against a 67% fixture and produced no band —
# four assertions red for a reason that had nothing to do with the runner. The
# lesson is the file's own subject: a probe that does not state the parameter
# its expectation depends on is measuring something it has not named.
NEXUS_CEILING_ADJACENT_PCT=50 run_probe 0 1 --timeout 3 "$WORK/suite/test-slow2.sh"
assert_contains "#992 a ceiling-adjacent suite says so ON ITS ROW" \
    "$OUT" "CEILING-ADJACENT"
assert_contains "#992 …naming the wall, the ceiling and the margin, so the verdict is re-derivable" \
    "$OUT" "of the 3s per-test ceiling"
assert_contains "#992 …and a footer BAND collects them (derived per run, so it cannot decay)" \
    "$OUT" "CEILING-ADJACENT (completed, but used"
assert_contains "#992 …and says plainly what a green re-run would and would not mean" \
    "$OUT" "re-rolled the dice"
_pct=$(printf '%s\n' "$OUT" | sed -n 's/.*ceiling (\([0-9][0-9]*\)% used.*/\1/p' | tail -1)
assert_eq "#992 the reported %-used is >= the floor 2s-of-3s implies (load can only raise it)" \
    "$( [[ "${_pct:-x}" =~ ^[0-9]+$ ]] && (( _pct >= 66 )) && echo ok || echo "got=${_pct:-<none>}" )" "ok"
# The threshold is what selected this row, so say which one — a band whose
# threshold is not in the output is a number a reader cannot re-derive.
# The CEILING moved from the header to the ROW when ceiling-overrides.tsv made it
# a per-SUITE property (your-org/nexus-code#992): a header naming one ceiling
# would contradict rows judged against another, and a caption that contradicts
# its data is worse than no caption. So each half is asserted where it now lives
# — the PERCENTAGE threshold in the header, the SECONDS in the row. The old form
# pinned "of the 3s per-test ceiling" in the header, a claim the runner is no
# longer entitled to make about every row.
assert_contains "#992 the band names the PERCENTAGE threshold that selected its members" \
    "$OUT" "used >=50% of ITS OWN per-test ceiling"
assert_contains "#992 …and each ROW names the ceiling it was actually judged against" \
    "$OUT" "of 3s ("

# NEGATIVE CONTROL. Without it, every assertion above would also pass on a
# runner that printed the band unconditionally — which is a different behaviour,
# and a much worse one: a warning that fires on everything is #997's second-order
# cost (a channel readers learn to skim) rebuilt on purpose.
run_probe 0 1 --timeout 60 "$WORK/suite/test-ok.sh"
assert_eq "#992 NEGATIVE CONTROL: a suite with real headroom is NOT annotated" \
    "$(printf '%s\n' "$OUT" | grep -c 'CEILING-ADJACENT')" "0"

# The TIMEOUT exclusion is DEFINITIONAL, not an enumeration: a suite that did
# not complete has no margin to report, and its row already names the ceiling.
# Asserted because the alternative — annotating it 100%-used — reads as a
# measurement when it is an artefact of where the runner cut the suite off.
run_probe 0 1 --timeout 2 "$WORK/suite/test-hangs.sh"
assert_contains "#992 a TIMEOUT still reports as TIMEOUT" "$OUT" "TIMEOUT"
assert_eq "#992 …and is NOT reported as ceiling-adjacent (it has no margin, it has a cut-off)" \
    "$(printf '%s\n' "$OUT" | grep -c 'CEILING-ADJACENT')" "0"

# The threshold is a named knob, so a band that is too noisy or too quiet is
# tunable rather than a source edit.
# The CONTRAST that makes the pinning above a real knob and not decoration: the
# SAME fixture at the SAME ceiling, seen at 50 and unseen at 99.
NEXUS_CEILING_ADJACENT_PCT=99 run_probe 0 1 --timeout 3 "$WORK/suite/test-slow2.sh"
assert_eq "#992 NEXUS_CEILING_ADJACENT_PCT raises the bar (99% silences the same 67% suite)" \
    "$(printf '%s\n' "$OUT" | grep -c 'CEILING-ADJACENT')" "0"

# ── #1031 / #997 through the runner, on the surface they were filed against ──
run_probe 0 1 "$WORK/suite/test-skipper.sh" "$WORK/suite/test-echoes.sh"
assert_contains "#1031 the row reports the ASSERTION count, not the skip count" \
    "$OUT" "9 assertions"
assert_eq "#1031 …and never the skip count in its place (1 assertions was the defect)" \
    "$(printf '%s\n' "$OUT" | grep -c '1 assertions')" "0"
assert_contains "#1031 the skip annotation survives, from the same line" \
    "$OUT" "(1 CASE(S) SKIPPED"
assert_contains "#1031/#997 a qualified row prints the footer both numbers came from" \
    "$OUT" "footer: === summary: 9 passed, 0 failed, 1 SKIPPED"
assert_contains "#997 a suite that ECHOES a specimen footer is read on its OWN footer" \
    "$OUT" "63 assertions"
assert_eq "#997 …and is not annotated with the echoed fixture's skip count" \
    "$(printf '%s\n' "$OUT" | grep -c '(2 CASE(S) SKIPPED')" "0"

# ── the count and its own evidence must describe ONE population ─────────
#
# Found sweeping the class rather than filed. On the ledger path the counted
# line (`=== N CASE(S) SKIPPED across M passing file(s) ===`) was computed from
# the LEDGER — the whole sweep — while the list at the foot of the run
# (`PASSED but with SKIPPED CASES:`) was built from THIS INVOCATION's sidecars.
# Under --resume a resumed suite is in the count and absent from the list, so
# the run states a number and then names fewer files than it just claimed.
_LG="$WORK/ledger-cs.tsv"
run_probe 0 1 --state "$_LG" "$WORK/suite/test-skipper.sh"
assert_contains "CONTROL: the skip-bearing suite is recorded in the ledger" \
    "$(cat "$_LG")" "test-skipper.sh"
run_probe 0 1 --state "$_LG" --resume "$WORK/suite/test-skipper.sh" "$WORK/suite/test-ok.sh"
assert_contains "the resumed run still COUNTS the case skip" \
    "$OUT" "CASE(S) SKIPPED across 1 passing file(s)"
assert_eq "…and NAMES it — count and evidence over one population, not two" \
    "$(printf '%s\n' "$OUT" | sed -n '/PASSED but with SKIPPED CASES/,/\^ each row/p' \
        | grep -c 'test-skipper\.sh')" "1"

# ── swept, not filed: three more labels whose definitions had drifted ────
#
# Enumerated from the HAZARD ("what else does this runner print whose
# definition might not match its label?") rather than from the shape of the
# three filed instances. Two independent sweeps over the same file found all
# three; they are here because each is the same mechanism, not because the
# sweep produced a list worth clearing.

# (a) THE HARDCODED ZERO. `--max-seconds` does not require `--state` (only
# `--resume` does), and on that path the argument to the incompleteness line
# was the literal `0`. So the line whose entire job is reporting incompleteness
# reported none. Measured on `dev` at 5de291f: four fixtures, one executed,
# `0 test(s) unaccounted`.
run_probe 0 1 --max-seconds 1 "$WORK/suite/test-slow2.sh" "$WORK/suite/test-ok.sh" \
                              "$WORK/suite/test-limits.sh"
assert_eq "a budget-stopped run without --state still exits 3" \
    "$RC" "3"
assert_eq "…and reports a NON-ZERO unaccounted count (was a hardcoded 0)" \
    "$(printf '%s\n' "$OUT" | grep -c 'INCOMPLETE:.*with 0 test(s) unaccounted')" "0"
_unacc=$(printf '%s\n' "$OUT" | sed -n 's/.*with \([0-9][0-9]*\) test(s) unaccounted.*/\1/p' | tail -1)
_rows=$(printf '%s\n' "$OUT" | grep -cE '^  (PASS|FAIL|SKIP|TIMEOUT) ')
assert_eq "…and the count RECONCILES against the rows printed (3 dispatched)" \
    "${_unacc:-<none>}" "$(( 3 - _rows ))"
# NEGATIVE CONTROL: the ledger path was already correct and must stay so.
run_probe 0 1 --state "$WORK/ledger-budget.tsv" --max-seconds 1 \
              "$WORK/suite/test-slow2.sh" "$WORK/suite/test-ok.sh"
assert_eq "the --state path still computes its own remainder (unchanged)" \
    "$( [[ "$RC" == 3 || "$RC" == 0 ]] && echo ok || echo "rc=$RC" )" "ok"

# (b) A HEADING WITH NO BODY. `--profile` printed
# `=== per-file wall-time (sorted desc) ===` and then nothing — its body was a
# comment reading "Skip". The next thing on screen was `=== suite total: …`,
# which a reader is invited to take as the table.
run_probe 0 1 --profile --timeout 30 "$WORK/suite/test-slow2.sh" "$WORK/suite/test-ok.sh"
assert_contains "--profile prints the heading it always printed" \
    "$OUT" "per-file wall-time (sorted desc)"
_prof_rows=$(printf '%s\n' "$OUT" \
    | sed -n '/per-file wall-time/,/^=== suite total/p' | grep -cE '^ +[0-9.]+s +(PASS|FAIL|SKIP|TIMEOUT)')
assert_eq "…and now a ROW PER TEST under it, which is what the heading promised" \
    "$_prof_rows" "2"
assert_contains "…carrying the ceiling share, so the #992 margin is visible here too" \
    "$OUT" "% of ceiling"
# The table is DERIVED FROM `.accounted`, the same record the #877 reconcile
# reads — so profile and tally cannot describe different populations. Asserted
# by reconciling the two counts rather than by reading the source.
assert_eq "…and its row count equals the tally's test count (one record, two views)" \
    "$_prof_rows" "$(printf '%s\n' "$OUT" | sed -n 's/.*suite total:.*across \([0-9][0-9]*\) tests.*/\1/p' | tail -1)"

# (c) `--help` WAS `sed -n '2,19p'` INTO A BLOCK THAT NOW RUNS TO LINE 65, so it
# ended mid-sentence and omitted the entire exit-code contract — the part a
# caller most needs. Asserted on CONTENT at the far end of the block, not on
# length: a length check passes on any truncation that happens to be long.
_help=$( cd "$WORK/cwd" && timeout 60 bash "$RUNNER" --help 2>&1 )
assert_contains "--help reaches the EXIT-CODE contract (the block's far end)" \
    "$_help" "Exit codes:"
assert_contains "--help reaches the STATUSES paragraph" "$_help" "STATUSES: PASS"
assert_contains "--help reaches the state-file location, the last line of the block" \
    "$_help" "NEXUS_TEST_STATE_DIR"
assert_eq "…and stops AT the block, not into the code below it" \
    "$(printf '%s\n' "$_help" | grep -c 'shellcheck\|^set -')" "0"


# ── the EAGAIN attribution is RECONCILED, not asserted ──────────────────
#
# The highest-stakes member of the swept class, because it is not a count that
# reads wrong — it is a verdict that tells the reader to DISMISS A RED. It fired
# on a bare substring match over both streams, so a suite that merely QUOTED
# the strerror in its own diagnostic had its genuine failure blamed on the
# machine. Reproduced on `dev` at 5de291f, and the damning part is that the
# runner had ALREADY computed the refutation and printed it two lines above:
# `fork-headroom=7068 is HEALTHY, so this is NOT #655 exhaustion` immediately
# followed by `EAGAIN in this run — RLIMIT_NPROC exhaustion, NOT a test defect`.
#
# Driven with a STUBBED `ps`, because the branch is selected by fork-headroom
# and headroom is `soft - ntasks`. Lowering the real `ulimit -Su` to reach the
# exhausted arm would starve this suite's own children on a shared box — the
# harness invalidating its own measurement, which is #863's shape. Stubbing the
# input is the same evidence at none of the risk.
_rn_probe() {   # _rn_probe <ntasks> ; echoes the note, using a fake ps
    local ntasks="$1" d
    d=$(mktemp -d)
    { echo '#!/usr/bin/env bash'
      echo 'case "$*" in'
      printf '  *-Lu*) seq 1 %s ;;\n' "$ntasks"
      echo '  *) seq 1 10 ;;'
      echo 'esac'
    } > "$d/ps"
    chmod +x "$d/ps"
    printf 'bash: fork: retry: Resource temporarily unavailable\n' > "$d/log.err"
    : > "$d/log.out"
    PATH="$d:$PATH" bash -c '
        . <(sed -n "/^_rt_resource_note() {/,/^}/p" "$1")
        _rt_resource_note "$2"' _ "$RUNNER" "$d/log" 2>&1
    rm -rf "$d"
}
# CONTROL first: the stub must actually move the number the branch keys on.
_rn_hi=$(_rn_probe 10)
_rn_lo=$(_rn_probe "$(( $(ulimit -Su 2>/dev/null || echo 8192) - 50 ))")
# Both controls read the SAME field the branch keys on — the headroom on the
# `resources` line — and compare it NUMERICALLY. Counting matching lines was the
# first form and it was wrong: the note text itself repeats `fork-headroom=`, so
# the control was measuring its own output's verbosity rather than the input.
# `tail -1`, NOT `head -1`, and that is not arbitrary. `head` closes the pipe
# EARLY, which under this file's `set -o pipefail` makes the writer's EPIPE the
# pipeline's status — the #622 shape — and it enrols this file in
# `early-exit-readers.manifest`, a repo-wide ratchet. There is exactly ONE
# `resources (sampled after exit)` line per note, so `tail -1` returns the same
# byte and drains the writer. Cheaper than joining a population and then
# arguing, in the manifest, that joining it was safe.
_rn_hd() { printf '%s\n' "$1" | sed -n 's/.*resources (sampled after exit).*fork-headroom=\([0-9?]*\).*/\1/p' | tail -1; }
assert_eq "CONTROL: the stubbed ps produces a HEALTHY headroom" \
    "$(_rn_hd "$_rn_hi" | awk '{ print ($1 ~ /^[0-9]+$/ && $1 >= 500) ? "healthy" : "got(" $1 ")" }')" "healthy"
assert_eq "CONTROL: …and an EXHAUSTED one, so both arms are reachable" \
    "$(_rn_hd "$_rn_lo" | awk '{ print ($1 ~ /^[0-9]+$/ && $1 < 500) ? "low" : "got(" $1 ")" }')" "low"

assert_eq "a quoted strerror with HEALTHY headroom is NOT published as exhaustion" \
    "$(printf '%s\n' "$_rn_hi" | grep -c 'RLIMIT_NPROC exhaustion, NOT a test defect')" "0"
assert_contains "…it says the run own numbers do not support that reading" \
    "$_rn_hi" "is NOT supported by"
assert_contains "…and refuses the dismissal explicitly, since that is the harm" \
    "$_rn_hi" "Do NOT dismiss this red"
assert_contains "…while still printing the match, so a reader can judge it" \
    "$_rn_hi" "matched:"
# THE NEGATIVE CONTROL IS THE WHOLE POINT: #655 is real, and a narrowed note
# that never fires would be a worse defect than the one being fixed.
assert_contains "a REAL exhaustion still gets the confident attribution" \
    "$_rn_lo" "RLIMIT_NPROC exhaustion, NOT a test defect"
assert_contains "…and now carries the headroom that justifies it" \
    "$_rn_lo" "fork-headroom="
assert_contains "…and still says to re-run before reading it as a red" \
    "$_rn_lo" "re-run before reading this as a red"
# THE TWO NOTES MUST NOT CONTRADICT EACH OTHER. This is the assertion the
# defect would have failed: `HEALTHY, so this is NOT #655 exhaustion` and
# `RLIMIT_NPROC exhaustion` were printed adjacently, from one function, on one
# sample.
assert_eq "the healthy-headroom note and the EAGAIN note never both claim exhaustion" \
    "$(printf '%s\n' "$_rn_hi" \
       | grep -c 'is HEALTHY, so this is NOT #655 exhaustion.*\|RLIMIT_NPROC exhaustion, NOT a test defect' \
       | awk '{ print ($1 > 1) ? "contradicts" : "consistent" }')" "consistent"


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
# The label says "the count cannot be inflated by a second write" — and a LINE
# count is exactly what a second write on the SAME line inflates without being
# seen (your-org/nexus-code#1026). The assertion stated the property it failed
# to check; occurrences is the unit that checks it.
assert_eq "…and exactly once, so the count cannot be inflated by a second write" \
    "$(_occurrences_re 'printf .*>> "\$out_file.accounted"' "$RUNNER")" "1"

# ── the tree this suite is about ────────────────────────────────────────
repo_stray=0
for s in .assertions .caseskipped .ceilingadj .err .failed .nocount .out .timedout .zerocount .accounted; do
    [[ -e "$REPO_ROOT/$s" ]] && repo_stray=$(( repo_stray + 1 ))
done
assert_eq "the repo root carries none of the runner's sidecar names" "$repo_stray" "0"

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
