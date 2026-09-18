#!/usr/bin/env bash
# monitor/watcher/test-async-run.sh — tests for monitor/async-run.sh, the
# status-preserving background launcher (your-org/nexus-code#1071).
#
# The property under test is ONE property, and everything else here serves it:
# **after the job is gone, can the worker still tell HOW it ended?** A bare
# `nohup … &` cannot, because the shell that would reap the status dies with
# the Bash tool call; six workers in one session were left unable to answer it
# for their own producers, one of which was at 28 GB RSS against a 92.6 GB
# archive on a shared node, so an OOM-kill was live and unfalsifiable.
#
# So the suite is built around the THREE-WAY verdict, and in particular around
# the third arm — `died` — which is the one a bare `nohup` fuses into
# "absent, presumed fine".
#
# Coverage:
#   - terminal, carrying the ACTUAL rc (0 and a non-zero)
#   - running, while the job is genuinely in flight
#   - died: SIGKILLed before it could write a status, reported as truncated
#   - pid IDENTITY, not merely pid liveness: a recycled pid must not read
#     `running` (asserted by planting a mismatched start-time)
#   - the wait is registered with declare-wait.sh as a RESOLVABLE asyncrun:<id>
#   - argv fidelity: an argument containing spaces survives the round trip
#   - stdout/stderr are captured separately
#   - `--cwd` is honoured
#   - unknown token → `unknown`, never `terminal`
#   - refusal paths: missing window env, bad --cwd
#
# Run: bash monitor/watcher/test-async-run.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
AR="$_repo_root/monitor/async-run.sh"
[[ -x "$AR" ]] || { echo "not executable: $AR" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

if ! command -v setsid >/dev/null 2>&1; then
    th_skip "setsid unavailable — async-run.sh cannot detach on this host"
    th_summary_and_exit
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_ROOT="$_repo_root"
export NEXUS_STATE_DIR="$WORK/.state"
export NEXUS_WORKER_WINDOW="arw"

. "$_repo_root/monitor/_bookkeeping.sh" 2>/dev/null || true
ROOT="$WORK/.state/async-run/$(wk_encode arw)"

launch() { "$AR" "$@" | sed -n 's/^  token   //p'; }

# await_status <token> — poll for the status file, BOUNDED. Never an unbounded
# wait: a hung poll in a test file is the same defect class the subject fixes.
await_status() {
    local t="$1" i
    for i in $(seq 1 60); do
        [[ -s "$ROOT/$1/status" ]] && return 0
        sleep 0.2
    done
    return 1
}
verdict() { "$AR" --status-line "$1"; }

echo '=== terminal: the rc is RETAINED and reported ==='
t_ok=$(launch --desc "ok job" -- bash -c 'echo out-line; echo err-line >&2; exit 0')
t_rc=$(launch -- bash -c 'exit 42')
await_status "$t_ok" || th_abort "status file never appeared for $t_ok"
await_status "$t_rc" || th_abort "status file never appeared for $t_rc"
v=$(verdict "$t_ok")
assert_eq "rc=0 job → terminal"        "${v%%|*}" "terminal"
assert_contains "…carrying rc=0"       "$v" "rc=0"
v=$(verdict "$t_rc")
assert_eq "rc=42 job → terminal"       "${v%%|*}" "terminal"
assert_contains "…carrying the ACTUAL rc, not a generic success" "$v" "rc=42"

echo '=== streams are captured, and captured SEPARATELY ==='
assert_eq "stdout captured" "$(cat "$ROOT/$t_ok/out")" "out-line"
assert_eq "stderr captured separately, not merged into stdout" \
    "$(cat "$ROOT/$t_ok/err")" "err-line"

echo '=== #1201: the verdict says whether it holds any EVIDENCE ==='
# THE DEFECT, AS AN ASSERTION. The detail used to be composed from `rc` and
# `elapsed` ALONE, so a job that captured 11 bytes and a job that captured
# NOTHING produced the BYTE-IDENTICAL string `terminal|rc=0 elapsed=0s`. A
# worker resumed with that cannot tell a clean run from a run whose results are
# somewhere this surface never looked — which is how a 23-minute sweep that had
# left SIX suites red was read as a success (your-org/nexus-code#1201).
#
# The fix does NOT guess whether the job succeeded; the rc is already the best
# answer available to that. It reports the one thing this surface can establish
# on its own: whether the rc arrives CORROBORATED or bare.
t_ev=$(launch --desc "no output at all" -- bash -c 'exit 0')
await_status "$t_ev" || th_abort "status never appeared for $t_ev"
v_ev=$(verdict "$t_ev")
v_ok=$(verdict "$t_ok")     # from the block above: 6B out, 5B err, rc=0
assert_contains     "an empty-stream job is MARKED"      "$v_ev" "NO-OUTPUT-CAPTURED"
assert_contains     "…and carries the byte census"       "$v_ev" "out=0B err=0B"
assert_not_contains "a job WITH output is NOT marked"    "$v_ok" "NO-OUTPUT-CAPTURED"
# 9B each: the payload above is `echo out-line` / `echo err-line >&2`, and
# `echo` adds the newline. A concrete count is deliberate — asserting merely
# "nonzero" would pass on a census that reported the WRONG stream.
assert_contains     "…and carries ITS byte census"       "$v_ok" "out=9B err=9B"
# The regression proper. Same verdict class, same rc, same elapsed — and the
# strings must now DIFFER, because the evidence differs. An equality assertion
# here would pass on the defect; only the inequality catches it.
if [[ "${v_ev%%|*}" == terminal && "${v_ok%%|*}" == terminal && "$v_ev" != "$v_ok" ]]; then
    printf '  PASS: rc=0-with-output and rc=0-with-NOTHING are DISTINGUISHABLE\n'; _th_pass
else
    printf '  FAIL: rc=0 with output and rc=0 with NOTHING are indistinguishable (#1201)\n'
    printf '        with-output: %s\n           nothing: %s\n' "$v_ok" "$v_ev"; _th_fail
fi

echo '=== the wait is registered as a RESOLVABLE asyncrun:<token> ==='
# Resolvable is the whole difference from `nohup:syn-…`: an id the watcher can
# look up, rather than a token with no job behind it.
waits=$("$_repo_root/monitor/declare-wait.sh" --list)
assert_contains "declare-wait registered the launch" "$waits" "\"kind\":\"asyncrun\""
assert_contains "…keyed on the token"                "$waits" "$t_ok"
assert_contains "…carrying the --desc"               "$waits" "ok job"
assert_not_contains "…and it is NOT a syn- token"    "$waits" "asyncrun\",\"id\":\"syn-"

echo '=== argv fidelity: an argument with spaces survives the round trip ==='
# The argv is written NUL-separated and read back by the child, so nothing is
# re-quoted by the parent. A naive `bash -c "$*"` would split this.
t_sp=$(launch -- bash -c 'printf "%s\n" "$1"' _ 'two  words')
await_status "$t_sp" || th_abort "status never appeared for $t_sp"
assert_eq "an argument containing spaces is passed intact" \
    "$(cat "$ROOT/$t_sp/out")" "two  words"

echo '=== --cwd is honoured ==='
mkdir -p "$WORK/elsewhere"
t_cd=$(launch --cwd "$WORK/elsewhere" -- bash -c 'pwd')
await_status "$t_cd" || th_abort "status never appeared for $t_cd"
assert_eq "--cwd sets the job's working directory" \
    "$(cd "$WORK/elsewhere" && pwd)" "$(cat "$ROOT/$t_cd/out")"

echo '=== running: an in-flight job reads `running`, not `died` ==='
t_run=$(launch -- bash -c 'exec sleep 45')
sleep 1
assert_eq "an in-flight job reads running" "$(verdict "$t_run" | cut -d'|' -f1)" "running"
# A live job that has not written anything YET is not a job with no evidence.
# Marking it would be a false alarm, and a guard that cries wolf on the normal
# case is how the real marker stops being read.
assert_not_contains "…and an as-yet-silent LIVE job is NOT marked no-output" \
    "$(verdict "$t_run")" "NO-OUTPUT-CAPTURED"

echo '=== died: KILLED before it could report — the verdict `nohup` cannot give ==='
# THE LOAD-BEARING ASSERTION. `died` must be distinguishable from BOTH
# `terminal` (finished, rc known) and `unresolvable` (nothing recorded). Fusing
# it into either is what let a truncated intermediate pass for a clean one.
pid=$(cat "$ROOT/$t_run/pid")
kill -9 -- -"$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
for _ in $(seq 1 40); do [[ -d "/proc/$pid" ]] || break; sleep 0.2; done
v=$(verdict "$t_run")
assert_eq "a SIGKILLed job reads died"                 "${v%%|*}" "died"
assert_not_contains "…and is NOT reported terminal"    "${v%%|*}" "terminal"
assert_eq "…and no status file was written"            "$([[ -s "$ROOT/$t_run/status" ]] && echo yes || echo no)" "no"
assert_contains "…and the detail says TRUNCATED, not empty" "$v" "TRUNCATED"
# THE PRODUCTION FAILURE THIS TEXT EXISTS FOR (your-org/nexus-code#1235): a
# worker wrapped such a token in `until [ -s "$T/status" ]; do sleep 60; done`
# and was still looping 28 hours later at 1.46s of CPU. The verdict has to say
# a waiter cannot be satisfied, because the waiter's own predicate cannot
# express `died`.
#
# BUT THE FIRST VERSION OF THIS SAID IT ABSOLUTELY AND THEN GAVE AN IMPERATIVE
# ("THIS STATUS FILE WILL NEVER APPEAR … Stop the waiter"), AND THAT WAS
# FALSIFIED — see the case below. `died` is a classification over the RECORDED
# PID, and the recorded pid is not necessarily the runner. An absolute claim
# plus an imperative tells a reader to stop waiting on a job that then
# succeeds: a manufactured WRONG INSTRUCTION, on the surface built to stop
# manufactured answers. So these assertions pin the CONDITIONAL form and the
# named escape hatch, and would redden if the absolute form came back.
assert_contains "…scoped as a CLASSIFICATION, not a fact about the work" \
    "$v" "NOT A FACT ABOUT THE WORK"
assert_not_contains "…and does NOT assert the file will never appear, full stop" \
    "$v" "WILL NEVER APPEAR"
# F9. THE FIRST REPAIR SCOPED THE CLAIM AND KEPT THE IMPERATIVE — "RE-READ THIS
# VERDICT before acting, and stop a waiter only once it still says died" — which
# READS as a safeguard and is not one. Re-reading returns `died` in BOTH
# branches (false `died` over a live runner, and true `died`), so the gate is
# satisfied in exactly the case it exists to catch. Measured across one job's
# life: `died` at +0s/+1s/+2s/+9s/+19s, `terminal|rc=0` at +22s.
#
# HEDGING A CLAIM DOES NOT FIX AN IMPERATIVE THAT RESTS ON IT. A reader acts on
# the VERB, not the epistemics. No sound discriminator is available here (the
# absence of a status file cannot separate a dead runner from a live one, and
# argv matching is barred by #1073), so the imperative is REMOVED rather than
# re-gated, and the verdict names its own failed gate so it is not re-added.
assert_not_contains "…and issues NO imperative to stop a waiter (F9)" "$v" "stop a waiter"
assert_not_contains "…nor the re-read gate that could not discriminate" \
    "$v" "RE-READ THIS VERDICT"
assert_contains "…names its OWN failed gate, so it is not re-added" \
    "$v" "DOES NOT DISCRIMINATE"
assert_contains "…and states the ASYMMETRY instead of an instruction" "$v" "ASYMMETRIC"
assert_contains "…offering only the SAFE-direction action, timeout = UNDECIDED" \
    "$v" "UNDECIDED"

echo '=== died is a CLASSIFICATION: a CORPSE recorded pid with a LIVE runner ==='
# THE FALSIFICATION, AS A TEST. A recorded pid that names a dead process while
# the real work is still running reads `died` — and then goes `terminal`. The
# mechanism is in this script's own header: the parent records the setsid
# WRAPPER as `$!` and the runner OVERWRITES it with its own `$$`, so there is a
# window in which the recorded pid is not the runner. Reproduced here by
# planting a corpse pid over a genuinely running job, which is the same
# observable state.
t_cls=$(launch --desc "corpse pid, live runner" -- bash -c 'sleep 6; echo done')
sleep 1
_real_pid=$(cat "$ROOT/$t_cls/pid")
# A pid that is certainly gone, with a start-time that cannot match.
printf '999999\n' > "$ROOT/$t_cls/pid"
printf '1\n'      > "$ROOT/$t_cls/pidstart"
v_cls=$(verdict "$t_cls")
assert_eq "a corpse recorded pid reads died…" "${v_cls%%|*}" "died"
# …AND THE WORK WAS NEVER DEAD. This is the assertion that makes the wording
# above load-bearing rather than stylistic.
if [[ -d "/proc/$_real_pid" ]]; then
    printf '  PASS: …while the REAL runner (%s) is still alive — so died CAN be wrong about the work\n' "$_real_pid"; _th_pass
else
    printf '  FAIL: the real runner had already exited; this case proves nothing about a live runner\n' >&2; _th_fail
fi
# Restore the true identity and let it finish: it must reach terminal.
printf '%s\n' "$_real_pid" > "$ROOT/$t_cls/pid"
_pst=$(awk '{r=$0; sub(/^.*\) /,"",r); print r}' "/proc/$_real_pid/stat" 2>/dev/null | awk '{print $20}')
printf '%s\n' "${_pst:-}" > "$ROOT/$t_cls/pidstart"
await_status "$t_cls" || th_abort "the job never reached terminal for $t_cls"
assert_eq "…and the same token then reads terminal" \
    "$(verdict "$t_cls" | cut -d'|' -f1)" "terminal"

echo '=== pid IDENTITY, not pid liveness: a recycled pid must not read running ==='
# `kill -0 $pid` answers "is SOME process alive there". Pids recycle, and a
# recycled pid would turn a `died` into a confident `running` — a silent wrong
# answer of exactly the shape this workspace files most often. Plant a
# start-time that cannot match the live process at that pid.
t_id=$(launch -- bash -c 'exec sleep 45')
sleep 1
assert_eq "control: it reads running with the real start-time" \
    "$(verdict "$t_id" | cut -d'|' -f1)" "running"
printf '999999999999\n' > "$ROOT/$t_id/pidstart"
v=$(verdict "$t_id")
assert_eq "with a MISMATCHED start-time the same live pid reads died" "${v%%|*}" "died"
kill -9 -- -"$(cat "$ROOT/$t_id/pid")" 2>/dev/null || true

echo '=== F3/F4 post-conditions (declared NON-discriminating — read the note) ==='
# HONEST LABELLING, because a test that passes for the wrong reason is worse
# than no test. These assert the POST-CONDITIONS of the skeptic F3 and F4 fixes.
# Neither DISCRIMINATES pre-fix from post-fix on this host, and both were
# measured passing against the unfixed tree — so they are regression guards,
# not evidence the fixes work. Why, precisely:
#
#   F3 (re-read the status file when the pid reads gone). The bug is a RACE: a
#   job that writes its status and exits BETWEEN the status check and the pid
#   check reads `died`. Any fixture that plants the END STATE (status present,
#   pid gone) is answered by the FIRST check, pre-fix and post-fix alike. The
#   skeptic demonstrated it by widening the window with an inserted `sleep 3`;
#   reproducing that in a suite needs a test-only branch in production code,
#   which is its own hazard and was declined. The window is microseconds and
#   the direction is a false ALARM, never a false all-clear.
#
#   F4 (the runner writes its own pid over the parent's `$!` guess). Measured
#   on this host: `setsid` EXECs rather than forks when not already a group
#   leader, so `$!` ALREADY named the runner and the guess was correct. The
#   failing condition needs job control ON inside async-run.sh's own shell, and
#   job control is not inherited by a non-interactive child script — so it is
#   not reachable by invoking this script normally. An earlier draft asserted a
#   `set -m` case; it passed against the unfixed tree, i.e. it never reproduced
#   the condition, and it was removed rather than left looking like coverage.
#
# What these DO pin: the fixes did not break the end states they touch.
t_race=$(launch -- bash -c 'exit 5')
await_status "$t_race" || th_abort "status never appeared for $t_race"
printf '999999\n' > "$ROOT/$t_race/pid"          # a pid that is certainly gone
printf '1\n'      > "$ROOT/$t_race/pidstart"
v=$(verdict "$t_race")
assert_eq "a GONE pid with a status file reads terminal, not died" "${v%%|*}" "terminal"
assert_contains "…carrying its real rc"  "$v" "rc=5"
# The complement must still hold, or the F3 re-read would have erased `died`.
rm -f "$ROOT/$t_race/status"
assert_eq "…and with the status file removed it reads died again" \
    "$(verdict "$t_race" | cut -d'|' -f1)" "died"

t_own=$(launch -- bash -c 'exec sleep 30')
sleep 1
_rec=$(cat "$ROOT/$t_own/pid")
assert_eq "the recorded pid is alive" \
    "$([[ -d "/proc/$_rec" ]] && echo alive || echo gone)" "alive"
# The post-condition F4 actually guarantees: the recorded pid is the RUNNER,
# not some ancestor — checkable by its argv, which names run.sh.
assert_contains "…and it is the runner process itself (argv names run.sh)" \
    "$(tr '\0' ' ' < "/proc/$_rec/cmdline" 2>/dev/null)" "run.sh"
assert_eq "…and the recorded start-time matches that pid" \
    "$(cat "$ROOT/$t_own/pidstart")" \
    "$(awk '{r=$0; sub(/^.*\) /,"",r); print r}' "/proc/$_rec/stat" 2>/dev/null | awk '{print $20}')"
kill -9 -- -"$_rec" 2>/dev/null || true

echo '=== unknown token → `unknown`, never `terminal` ==='
# The fail-safe direction: the expensive error is telling a worker its data is
# good on no evidence.
v=$(verdict "ar-nosuchtokenatall")
assert_eq "unknown token → unknown"                "${v%%|*}" "unknown"
assert_not_contains "…and NOT terminal"            "${v%%|*}" "terminal"

echo '=== refusals are LOUD, and refuse without launching ==='
out=$(env -u NEXUS_WORKER_WINDOW -u NEXUS_ASYNC_RUN_WINDOW NEXUS_STATE_DIR="$WORK/.state" \
      NEXUS_ROOT="$_repo_root" bash "$AR" -- true 2>&1); rc=$?
assert_eq "missing NEXUS_WORKER_WINDOW exits 2"    "$rc" "2"
assert_contains "…and says why"                    "$out" "NEXUS_WORKER_WINDOW"
out=$("$AR" --cwd "$WORK/no-such-dir" -- true 2>&1); rc=$?
assert_eq "a bad --cwd exits 2"                    "$rc" "2"
assert_contains "…and names the directory"         "$out" "no-such-dir"
_before=$(ls "$ROOT" | wc -l)
"$AR" 2>/dev/null; rc=$?
assert_eq "no arguments → usage, exit 2"           "$rc" "2"
assert_eq "…and a refusal launches nothing"        "$(ls "$ROOT" | wc -l)" "$_before"

echo '=== --list reports every token with its verdict ==='
lst=$("$AR" --list)
assert_contains "--list names a terminal token"  "$lst" "$t_ok"
assert_contains "--list carries the verdict"     "$lst" "terminal|"

# ---- assertion-count guard ------------------------------------------------
# The summary reports assertions that RAN; one that never ran is invisible to
# it. Bump deliberately when adding a case; a DROP means a case stopped running.
# ── your-org/nexus-code#1440: --help needs no context, and is separable from a refusal
# CONTENT is asserted, not only status: the status is exactly what used to fail
# to discriminate (usage and the window-unset refusal both exited 2).
_h1440=$(env -u NEXUS_WORKER_WINDOW -u NEXUS_ASYNC_RUN_WINDOW bash "$_test_dir/../async-run.sh" --help 2>&1); _h1440_rc=$?
assert_contains "#1440 --help outside a worker prints the USAGE" "$_h1440" "usage: async-run.sh"
assert_not_contains "#1440 …and not the window-unset refusal" "$_h1440" "NEXUS_WORKER_WINDOW unset"
assert_eq "#1440 …at exit 0, distinct from the refusal" "$_h1440_rc" "0"
_r1440=$(env -u NEXUS_WORKER_WINDOW -u NEXUS_ASYNC_RUN_WINDOW bash "$_test_dir/../async-run.sh" --status nope 2>&1); _r1440_rc=$?
assert_eq "#1440 CONTROL: a context-needing verb outside a worker is still refused at 2" "$_r1440_rc/$(grep -c 'NEXUS_WORKER_WINDOW unset' <<<"$_r1440" || true)" "2/1"
_h1440=$(env -u NEXUS_WORKER_WINDOW bash "$_test_dir/../async-run.sh" -h 2>&1); assert_eq "#1440 -h behaves like --help" "$?/$(grep -c 'usage: async-run.sh' <<<"$_h1440" || true)" "0/1"

# ── your-org/nexus-code#1389: duplicate-launch guard + the handle comes FIRST ──
# Three concurrent copies of a mutation driver raced in one clone because the
# token scrolled out of a `| head -3` view and the launch was retried. Twice.
echo "=== #1389 duplicate launch is REFUSED with the existing token ==="
_dup1=$("$AR" --desc "dup A" -- bash -c 'exec sleep 40' 2>&1); _dup1_rc=$?
assert_eq "#1389 the FIRST line is the handle alone" "$(sed -n 1p <<<"$_dup1" | sed 's/=ar-[0-9a-f]*$/=<t>/')" "async-run: launched token=<t>"
_t_dup=$(sed -n 's/^  token   //p' <<<"$_dup1")
_dup2=$("$AR" --desc "dup B (retry)" -- bash -c 'exec sleep 40' 2>&1); _dup2_rc=$?
assert_eq "#1389 a byte-identical argv while the first RUNS → rc 9" "$_dup2_rc" "9"
assert_eq "#1389 …and the refusal names the EXISTING token" "$(grep -c "token   $_t_dup" <<<"$_dup2")" "1"
assert_eq "#1389 …and no second job was created" "$("$AR" --list | grep -c 'exec sleep 40')" "1"
_dup3=$("$AR" --desc "dup C" --allow-concurrent -- bash -c 'exec sleep 40' 2>&1); _dup3_rc=$?
assert_eq "#1389 --allow-concurrent is the explicit opt-in → launched" "$_dup3_rc/$(sed -n 1p <<<"$_dup3" | grep -c '^async-run: launched token=')" "0/1"
# a DIFFERENT argv is never a duplicate, and a FINISHED twin is not one either
_dup4=$("$AR" --desc "dup D" -- bash -c 'exec sleep 41' 2>&1); _dup4_rc=$?
assert_eq "#1389 a different argv is not a duplicate" "$_dup4_rc" "0"
_t_fin=$(launch --desc "fin" -- bash -c 'exit 0'); sleep 1
_dup5=$("$AR" --desc "fin again" -- bash -c 'exit 0' 2>&1); _dup5_rc=$?
assert_eq "#1389 a twin that has FINISHED does not block a relaunch" "$_dup5_rc" "0"
for _t in $_t_dup $(sed -n 's/^  token   //p' <<<"$_dup3") $(sed -n 's/^  token   //p' <<<"$_dup4"); do "$AR" --cancel "$_t" >/dev/null 2>&1 || true; done

EXPECTED_ASSERTIONS=63   # +7: #1389 duplicate-launch guard (6) and the token-first line (1)   # +16 since 35: census (5), running non-alarm (1), F1 died wording (2), F1 falsification (3), F9 imperative removal (5)
_ran=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _ran == EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
