#!/usr/bin/env bash
# monitor/watcher/test-svc-orphans.sh — tests for `svc.sh orphans`, the
# READ-ONLY enumeration of unregistered supervisors (your-org/nexus-code#1034).
#
# WHAT IS UNDER TEST, and why it is not "does it find orphans".
#
# #1034 reported three `remote-sshd-supervised.sh` processes, exactly one of
# them registered; one of the other two held a LIVE sshd on a port nobody
# tracked, whose AuthorizedKeysFile pointed into a deleted directory. Its
# recommendation 1 was "enumeration first: today nobody can even LIST the
# problem". So the property is: CAN THIS VERB TELL A REGISTERED SUPERVISOR
# FROM AN UNREGISTERED ONE — in BOTH directions, and does it REFUSE rather
# than guess when it cannot.
#
# The false-negative direction (missing an orphan) leaves a live rogue daemon
# unlisted. The false-POSITIVE direction is worse in practice: this verb's
# output is what an operator reads before deciding what to retire, and a
# healthy production service named "orphan" is a nudge toward an outage. The
# first live run of this verb produced EIGHT false positives on this nexus —
# every one a healthy registered service — because the registry composes
# `$NEXUS_ROOT/work/x` + `./serve.sh` into `/work/x/./serve.sh` while the
# running process carries `/work/x/serve.sh`. Same file, three characters
# apart, string-compared. `t_norm_*` below pins that.
#
# NO LIVE PROCESSES ARE SPAWNED. A ppid-1 detector would need `setsid` to be
# tested against real processes, which is both a footgun inside a test and
# unreapable if the suite dies mid-run. Instead the suite plants a SYNTHETIC
# procfs (`SVC_PROCFS`) — the same classification code, no processes at all.
# The seam is production-inert: nothing but this suite ever sets it.
#
# Run: bash monitor/watcher/test-svc-orphans.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SVC="$_repo_root/monitor/svc.sh"
[[ -r "$SVC" ]] || { echo "not readable: $SVC" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- fixture builders -----------------------------------------------------

# plant_proc <procfs> <pid> <ppid> <cwd> <argv...>
plant_proc() {
    local pfs="$1" pid="$2" ppid="$3" cwd="$4"; shift 4
    local d="$pfs/$pid" a
    mkdir -p "$d"
    : > "$d/cmdline"
    for a in "$@"; do printf '%s\0' "$a" >> "$d/cmdline"; done
    printf 'Name:\tbash\nPid:\t%s\nPPid:\t%s\n' "$pid" "$ppid" > "$d/status"
    mkdir -p "$cwd"
    ln -sfn "$cwd" "$d/cwd"
}

# CONTROL A is "the walk saw MY OWN pid", and the pid that matters is the one
# running svc.sh — not this test shell. So the runner below plants its own $$
# and then `exec`s svc.sh, which PRESERVES the pid. Satisfying control A
# legitimately is part of the fixture; stubbing it out would disarm the very
# guard that makes a zero from this verb mean anything.
plant_self() { :; }

# new_case <name> -> exports CASE_ROOT / CASE_PROCFS / CASE_REG
new_case() {
    CASE_ROOT="$WORK/$1/root"
    CASE_PROCFS="$WORK/$1/proc"
    CASE_REG="$CASE_ROOT/monitor/services.registry"
    mkdir -p "$CASE_ROOT/monitor" "$CASE_PROCFS"
    : > "$CASE_REG"
    plant_self "$CASE_PROCFS"
}

reg_row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$CASE_REG"; }

run_orphans() {
    NEXUS_ROOT="$CASE_ROOT" \
    NEXUS_SERVICES_REGISTRY="$CASE_REG" \
    SVC_PROCFS="$CASE_PROCFS" \
    NEXUS_STATE_DIR="$CASE_ROOT/monitor/.state" \
    _PFS="$CASE_PROCFS" _SVC="$SVC" _SKIP_SELF="${SKIP_SELF:-0}" \
      bash -c '
        if [[ "$_SKIP_SELF" != 1 ]]; then
            mkdir -p "$_PFS/$$"
            printf "bash\0self\0"                  > "$_PFS/$$/cmdline"
            printf "Name:\tbash\nPPid:\t1\n"      > "$_PFS/$$/status"
            ln -sfn "$_PFS" "$_PFS/$$/cwd"
        fi
        exec bash "$_SVC" orphans' 2>&1
}
run_orphans_rc() { run_orphans >/dev/null 2>&1; printf '%s' "$?"; }

echo "== svc.sh orphans =="

# ---------------------------------------------------------------- t_finds ---
# An unregistered supervisor from a path OUTSIDE the nexus root — #1034's
# ephemeral-scratchpad orphan — must be FOUND, at rc 1, and named.
new_case finds
mkdir -p "$CASE_ROOT/work/svc-a"
printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-a/serve-supervised.sh"
reg_row svc-a '$NEXUS_ROOT/work/svc-a' ./serve-supervised.sh 'true'
plant_proc "$CASE_PROCFS" 4001 1 "$CASE_ROOT/work/svc-a" \
    bash "$CASE_ROOT/work/svc-a/serve-supervised.sh"
# the orphan: same script NAME, foreign path, ppid 1
mkdir -p "$WORK/ephemeral/monitor"
plant_proc "$CASE_PROCFS" 4002 1 "$WORK/ephemeral" \
    bash "$WORK/ephemeral/monitor/serve-supervised.sh"

out=$(run_orphans); rc=$?
assert_rc      "an unregistered ppid-1 supervisor → rc 1"        "$rc" 1
assert_contains "…the orphan pid is named"                       "$out" "pid      4002"
assert_contains "…with its source path"                          "$out" "$WORK/ephemeral/monitor/serve-supervised.sh"
assert_contains "…and it is called out as OUTSIDE the nexus root" "$out" "OUTSIDE NEXUS_ROOT"
assert_not_contains "the REGISTERED supervisor is NOT flagged"    "$out" "pid      4001"
assert_contains "a vanished script file is reported as GONE"      "$out" "the script file is GONE"

# ------------------------------------------------------------- t_norm_dot ---
# THE REGRESSION FOR THE 8-FALSE-POSITIVE BUG. Registry says
# `$NEXUS_ROOT/work/svc-b` + `./serve-supervised.sh`; the live process carries
# the ABSOLUTE path. These are one file and must compare equal.
new_case normdot
mkdir -p "$CASE_ROOT/work/svc-b"
printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-b/serve-supervised.sh"
reg_row svc-b '$NEXUS_ROOT/work/svc-b' ./serve-supervised.sh 'true'
plant_proc "$CASE_PROCFS" 4101 1 "$CASE_ROOT/work/svc-b" \
    bash "$CASE_ROOT/work/svc-b/serve-supervised.sh"
out=$(run_orphans); rc=$?
assert_rc       "registry './x' vs live absolute path → NOT an orphan (rc 0)" "$rc" 0
assert_contains "…and it says so"                                            "$out" "none found"
assert_not_contains "…the healthy registered service is not named"           "$out" "pid      4101"

# A `..` in the registry workdir must normalise too.
new_case normdotdot
mkdir -p "$CASE_ROOT/work/svc-c"
printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-c/serve-supervised.sh"
reg_row svc-c '$NEXUS_ROOT/work/nowhere/../svc-c' ./serve-supervised.sh 'true'
plant_proc "$CASE_PROCFS" 4201 1 "$CASE_ROOT/work/svc-c" \
    bash "$CASE_ROOT/work/svc-c/serve-supervised.sh"
assert_rc "a '..' segment in the registry workdir normalises → rc 0" "$(run_orphans_rc)" 0

# ------------------------------------------------------- t_shape_undercount --
# The registry-basename rule must catch a launch script whose name does NOT
# match the `*-supervised.sh` shape. This nexus really has one
# (`run-supervised-xiulan.sh`), which is why the population is a UNION.
new_case shape
mkdir -p "$CASE_ROOT/work/svc-x"
printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-x/run-odd-name.sh"
reg_row svc-x '$NEXUS_ROOT/work/svc-x' ./run-odd-name.sh 'true'
plant_proc "$CASE_PROCFS" 4301 1 "$CASE_ROOT/work/svc-x" \
    bash "$CASE_ROOT/work/svc-x/run-odd-name.sh"
mkdir -p "$WORK/foreign2"
plant_proc "$CASE_PROCFS" 4302 1 "$WORK/foreign2" \
    bash "$WORK/foreign2/run-odd-name.sh"
out=$(run_orphans)
assert_contains     "a NON-shape launch name is still matched via the registry basename" "$out" "pid      4302"
assert_not_contains "…and its registered twin is not flagged"                            "$out" "pid      4301"

# ------------------------------------------------------------ t_ppid_guard ---
# ppid != 1 is somebody's child — being managed — and must not be flagged.
new_case ppid
mkdir -p "$CASE_ROOT/work/svc-d"
printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-d/serve-supervised.sh"
reg_row svc-d '$NEXUS_ROOT/work/svc-d' ./serve-supervised.sh 'true'
plant_proc "$CASE_PROCFS" 4401 1 "$CASE_ROOT/work/svc-d" \
    bash "$CASE_ROOT/work/svc-d/serve-supervised.sh"
mkdir -p "$WORK/child"
plant_proc "$CASE_PROCFS" 4402 4401 "$WORK/child" \
    bash "$WORK/child/serve-supervised.sh"
out=$(run_orphans); rc=$?
assert_rc           "an unregistered supervisor with a LIVE parent is not an orphan" "$rc" 0
assert_not_contains "…and is not named"                                              "$out" "pid      4402"

# ------------------------------------------------------------ t_refuse_reg ---
# An EMPTY registry means everything would read unregistered. That is an
# artefact of the registry, not a finding: REFUSE (3), never report orphans.
new_case emptyreg
mkdir -p "$WORK/e1"
plant_proc "$CASE_PROCFS" 4501 1 "$WORK/e1" bash "$WORK/e1/serve-supervised.sh"
out=$(run_orphans); rc=$?
assert_rc       "an empty registry → REFUSED (3), not a finding"    "$rc" 3
assert_contains "…and says why"                                     "$out" "REFUSED"
assert_not_contains "…and does NOT report the candidate as an orphan" "$out" "unregistered supervisor(s) with ppid 1"

# ---------------------------------------------------------- t_refuse_ctlA ---
# CONTROL A: if the walk cannot see the calling process, no absence it reports
# means anything.
new_case ctla
# The fixture deliberately makes control B PASS (a registered supervisor is
# visible), so rc 3 here can come from control A and nothing else. Without
# this, a disarmed control A still produced rc 3 via control B and the rc
# assertion passed FOR THE WRONG REASON — the mutant was caught only by the
# message needle. A test that is green for a reason you did not intend is one
# whose guard you have not actually pinned.
mkdir -p "$CASE_ROOT/work/svc-e"
printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-e/serve-supervised.sh"
reg_row svc-e '$NEXUS_ROOT/work/svc-e' ./serve-supervised.sh 'true'
plant_proc "$CASE_PROCFS" 4801 1 "$CASE_ROOT/work/svc-e" \
    bash "$CASE_ROOT/work/svc-e/serve-supervised.sh"
out=$(SKIP_SELF=1 run_orphans); rc=$?
assert_rc       "a procfs the walk cannot find this process in → REFUSED (3)" "$rc" 3
assert_contains "…naming CONTROL A specifically, not some other refusal"      "$out" "CONTROL A FAILED"
assert_contains "…and saying no scan is possible"                            "$out" "no scan is possible"
# Same fixture, control A SATISFIED: must NOT refuse. Proves the refusal above
# is caused by control A rather than by anything else in this fixture.
assert_rc       "…and with control A satisfied the SAME fixture does not refuse" \
                "$(run_orphans_rc)" 0

# ---------------------------------------------------------- t_refuse_ctlB ---
# CONTROL B: the predicate matched no REGISTERED supervisor, so it has not been
# shown able to match one. A zero from it is unvouched → REFUSED, not "none".
new_case ctlb
reg_row svc-f '$NEXUS_ROOT/work/svc-f' ./serve-supervised.sh 'true'
out=$(run_orphans); rc=$?
assert_rc       "no registered supervisor running → REFUSED (3), NOT 'none found'" "$rc" 3
assert_contains "…naming control B"                                                "$out" "CONTROL B FAILED"
# The needle is the EMITTED LINE, not the phrase: control B's refusal text
# legitimately QUOTES "none found" while explaining why it will not say it, so
# a bare phrase match flags the explanation for containing the word it warns
# about — the assertion would fail on correct behaviour.
assert_not_contains "…and it must not EMIT the none-found line"                     "$out" "orphans: none found"

# THE DIRECTION THAT MATTERS: a control-B refusal must still PRINT a positive
# finding. The refusal is about the ZERO; a found orphan needs no control.
new_case ctlb_pos
reg_row svc-g '$NEXUS_ROOT/work/svc-g' ./serve-supervised.sh 'true'
mkdir -p "$WORK/g1"
plant_proc "$CASE_PROCFS" 4601 1 "$WORK/g1" bash "$WORK/g1/serve-supervised.sh"
out=$(run_orphans); rc=$?
assert_rc       "control-B refusal with a candidate present is still rc 3" "$rc" 3
assert_contains "…but the candidate IS printed, not swallowed"             "$out" "pid      4601"

# ---------------------------------------------------------- t_refuse_ctlC ---
# CONTROL C: an INDEPENDENT instrument (the name→pidfile probe) resolving a
# registered service to a pid this scan called an orphan means the two
# disagree. This is the control that would have caught the 8-false-positive
# bug; A and B both passed while it was live.
new_case ctlc
mkdir -p "$CASE_ROOT/work/svc-h" "$CASE_ROOT/work/svc-h-elsewhere" \
         "$CASE_ROOT/work/svc-k" "$CASE_ROOT/monitor/.state/services"
printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-h/serve-supervised.sh"
printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-k/serve-supervised.sh"
# A REAL child is required and cannot be faked: `_recover_supervisor_probe`
# reads the TRUE /proc cmdline and demands it mention the launch basename, so a
# `sleep` stand-in resolves `stale` and the control is never staged.
# Streams are detached because `$(run_orphans)` waits on the PIPE, not on the
# command — a fixture child holding inherited stdout hangs the substitution for
# its whole lifetime (measured: the suite ran to the 120s tool timeout).
cat > "$CASE_ROOT/work/svc-h-elsewhere/serve-supervised.sh" <<'FIXTURE'
#!/usr/bin/env bash
sleep 120
FIXTURE
chmod +x "$CASE_ROOT/work/svc-h-elsewhere/serve-supervised.sh"

# svc-k exists ONLY to satisfy control B, so that the refusal under test is
# unambiguously control C and not B firing first.
reg_row svc-k '$NEXUS_ROOT/work/svc-k' ./serve-supervised.sh 'true'
plant_proc "$CASE_PROCFS" 4702 1 "$CASE_ROOT/work/svc-k" \
    bash "$CASE_ROOT/work/svc-k/serve-supervised.sh"

# svc-h is REGISTERED at the -elsewhere path. Its pidfile will name the live
# child. But the synthetic procfs shows that same pid running from
# work/svc-h — a path NO registry row names — so the /proc scan classifies it
# as an orphan while the pidfile probe calls it a live registered supervisor.
# Two instruments, one pid, opposite verdicts: that is control C.
reg_row svc-h '$NEXUS_ROOT/work/svc-h-elsewhere' ./serve-supervised.sh 'true'
bash "$CASE_ROOT/work/svc-h-elsewhere/serve-supervised.sh" </dev/null >/dev/null 2>&1 &
_live=$!
plant_proc "$CASE_PROCFS" "$_live" 1 "$CASE_ROOT/work/svc-h" \
    bash "$CASE_ROOT/work/svc-h/serve-supervised.sh"
printf '%s\n' "$_live" > "$CASE_ROOT/monitor/.state/services/svc-h.pid"

_probe=$(NEXUS_ROOT="$CASE_ROOT" NEXUS_STATE_DIR="$CASE_ROOT/monitor/.state" \
  bash -c '. "$1" >/dev/null 2>&1
           _recover_supervisor_state svc-h "$2"' _ \
           "$_repo_root/monitor/bootstrap-recover.sh" \
           "$CASE_ROOT/work/svc-h-elsewhere/serve-supervised.sh" 2>/dev/null)
out=$(run_orphans); rc=$?
th_kill_own_child "$_live" >/dev/null 2>&1
wait "$_live" 2>/dev/null

# POSITIVE CONTROL ON THE FIXTURE: if the independent probe did not resolve
# `alive`, the disagreement was never staged and a green below would be
# vacuous. Assert the precondition BEFORE the effect.
assert_contains "fixture staged: the independent probe resolves svc-h alive" "$_probe" "alive:"
assert_rc       "two instruments disagreeing on a registered service → REFUSED (3)" "$rc" 3
assert_contains "…naming control C"                                                 "$out" "CONTROL C FAILED"
assert_contains "…and naming the contested pid"                                     "$out" "$_live"

# ------------------------------------------------------------- t_readonly ---
# STRICTLY READ-ONLY. Not a promise in a comment — assert the region carries no
# signalling verb at all.
region_raw=$(awk '/^# --- orphans: READ-ONLY enumeration/,/^usage\(\) \{/' "$SVC")
assert_contains "the orphans region was located for scanning" "$region_raw" "cmd_orphans()"
assert_not_contains "…and the retire-orphan verb (which DOES signal) sits OUTSIDE it" "$region_raw" "cmd_retire_orphan()"
# COMMENTS ARE STRIPPED BEFORE SCANNING. The region's prose necessarily
# DISCUSSES killing — it exists to explain why this verb does not do it — so a
# raw text scan flags the documentation for saying what it promises. Scan the
# CODE. (Full-line comments only: a trailing `#` inside a quoted string is not
# safely strippable with a regex, and over-stripping would create a place to
# hide a real call.)
region=$(grep -v '^[[:space:]]*#' <<<"$region_raw")
assert_not_contains "…and stripping comments left actual code" "$(printf '%s' "${region:0:0}x")" "y"
for verb in 'kill ' 'kill -' 'pkill' 'killall' 'setsid ' 'recover_service ' 'rm -'; do
    if grep -qF -- "$verb" <<<"$region"; then
        printf '  FAIL: orphans region contains a mutating verb: %q\n' "$verb" >&2
        _th_fail
    else
        printf '  PASS: orphans region is free of %q\n' "$verb"
        _th_pass
    fi
done

# ------------------------------------------------------------- t_noargs ----
new_case noargs
reg_row svc-i '$NEXUS_ROOT/work/svc-i' ./serve-supervised.sh 'true'
rc=$(NEXUS_ROOT="$CASE_ROOT" NEXUS_SERVICES_REGISTRY="$CASE_REG" SVC_PROCFS="$CASE_PROCFS" \
     bash "$SVC" orphans extra-arg >/dev/null 2>&1; printf '%s' "$?")
assert_rc "orphans takes no arguments — a stray argument is refused" "$rc" 1

# ================================================================ retire ====
# `svc.sh retire-orphan` (your-org/nexus-code#1034 recommendation 2): the
# SANCTIONED retirement path for exactly the set `orphans` prints. Its
# authorisation is the scan's classification plus an explicit --yes, never
# session ownership (proc-kill-authorized correctly refuses these). Driven
# against the SAME planted procfs, with the kill routed through the
# NEXUS_SVC_KILL_CMD seam into a RECORDER: no live process is ever signalled.
echo
echo "== svc.sh retire-orphan =="

RECORD="$WORK/kill.record"
# The recorder logs the exact `kill` argv it received. `REC_REAP=1` makes it
# also REMOVE the planted procfs entries of the pids it was aimed at — the
# fixture's way of saying "the signal landed", so the verb's liveness poll
# (which reads the procfs seam) sees them gone.
cat > "$WORK/recorder.sh" <<'REC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RECORD"
if [[ "${REC_REAP:-0}" == 1 ]]; then
    tgt="$3"
    if [[ "$tgt" == -* ]]; then
        # a process-GROUP target: reap the leader and everything whose PPid
        # chain leads to it, TRANSITIVELY (a grandchild's parent is reaped in
        # the first pass and then has no entry to read, so loop to a fixpoint)
        lead="${tgt#-}"
        rm -rf "$SVC_PROCFS/$lead"
        changed=1
        while (( changed )); do
            changed=0
            for d in "$SVC_PROCFS"/[0-9]*; do
                [[ -d "$d" ]] || continue
                pp=$(awk '/^PPid:/{print $2}' "$d/status" 2>/dev/null)
                [[ -n "$pp" ]] || continue
                if [[ "$pp" == "$lead" ]] || { [[ "$pp" != 1 ]] && [[ ! -d "$SVC_PROCFS/$pp" ]] && [[ "$pp" != "$$" ]]; }; then
                    rm -rf "$d"; changed=1
                fi
            done
        done
    else
        rm -rf "$SVC_PROCFS/$tgt"
    fi
fi
exit 0
REC
chmod +x "$WORK/recorder.sh"

run_retire() {   # run_retire <svc-path> <args...>  (same self-plant as run_orphans)
    local svc="$1"; shift
    NEXUS_ROOT="$CASE_ROOT" \
    NEXUS_SERVICES_REGISTRY="$CASE_REG" \
    SVC_PROCFS="$CASE_PROCFS" \
    NEXUS_STATE_DIR="$CASE_ROOT/monitor/.state" \
    NEXUS_SVC_KILL_CMD="$WORK/recorder.sh" RECORD="$RECORD" REC_REAP="${REC_REAP:-0}" \
    NEXUS_SVC_RETIRE_GRACE=1 \
    _PFS="$CASE_PROCFS" _SVC="$svc" \
      bash -c '
        mkdir -p "$_PFS/$$"
        printf "bash\0self\0"                  > "$_PFS/$$/cmdline"
        printf "Name:\tbash\nPPid:\t1\n"      > "$_PFS/$$/status"
        ln -sfn "$_PFS" "$_PFS/$$/cwd"
        exec bash "$_SVC" retire-orphan "$@"' _ "$@" 2>&1
}

# One fixture for every arm: a registered supervisor (5001), an orphan (5002)
# with a child sshd (5003) and a grandchild (5004), and a non-supervisor
# process (5005) that is nobody's business.
build_retire_case() {
    new_case "$1"
    mkdir -p "$CASE_ROOT/work/svc-r" "$CASE_ROOT/monitor/.state"
    printf '#!/bin/sh\n' > "$CASE_ROOT/work/svc-r/serve-supervised.sh"
    reg_row svc-r '$NEXUS_ROOT/work/svc-r' ./serve-supervised.sh 'true'
    plant_proc "$CASE_PROCFS" 5001 1 "$CASE_ROOT/work/svc-r" \
        bash "$CASE_ROOT/work/svc-r/serve-supervised.sh"
    mkdir -p "$WORK/$1-scratch/monitor"
    plant_proc "$CASE_PROCFS" 5002 1    "$WORK/$1-scratch" bash "$WORK/$1-scratch/monitor/serve-supervised.sh"
    plant_proc "$CASE_PROCFS" 5003 5002 "$WORK/$1-scratch" /usr/sbin/sshd -D -f /dev/null
    plant_proc "$CASE_PROCFS" 5004 5003 "$WORK/$1-scratch" sshd-session
    plant_proc "$CASE_PROCFS" 5005 1    "$WORK/$1-scratch" sleep 30
    : > "$RECORD"
}

# --- arguments ---
build_retire_case r_args
out=$(run_retire "$SVC"); rc=$?
assert_rc       "no pid → rc 2 (usage), nothing signalled" "$rc" 2
out=$(run_retire "$SVC" notapid --yes); rc=$?
assert_rc       "a non-numeric pid → rc 2" "$rc" 2
assert_eq       "…and the recorder was never called" "$(wc -l < "$RECORD" | tr -d ' ')" "0"

# --- PLAN ONLY: no --yes ---
build_retire_case r_plan
out=$(run_retire "$SVC" 5002); rc=$?
assert_rc       "an orphan pid WITHOUT --yes → rc 4 (plan printed, nothing done)" "$rc" 4
assert_contains "…the plan names the kill set: supervisor + its descendants by recorded PPid" "$out" "kill set (supervisor + descendants by recorded PPid): 5002 5003 5004"
assert_not_contains "…and the unrelated process is NOT in the set" "$out" " 5005"
assert_contains "…and says it is PLAN ONLY" "$out" "PLAN ONLY"
assert_eq       "…and the recorder was never called" "$(wc -l < "$RECORD" | tr -d ' ')" "0"
assert_eq       "…and no retirement was logged" "$([[ -e "$CASE_ROOT/monitor/.state/svc-retire.log" ]] && echo present || echo absent)" "absent"

# --- REFUSAL: a REGISTERED supervisor, by pid, even with --yes ---
build_retire_case r_registered
out=$(run_retire "$SVC" 5001 --yes); rc=$?
assert_rc       "a REGISTERED supervisor's pid with --yes → REFUSED (rc 2)" "$rc" 2
assert_contains "…naming the reason: not in the scan's orphan set" "$out" "NOT in the scan's orphan set"
assert_contains "…and listing what the scan DID classify" "$out" "pid 5002"
assert_eq       "…and the recorder was never called (a registered service is never signalled here)" "$(wc -l < "$RECORD" | tr -d ' ')" "0"

# --- REFUSAL: a non-supervisor with ppid 1 ---
build_retire_case r_nonsup
out=$(run_retire "$SVC" 5005 --yes); rc=$?
assert_rc       "a ppid-1 process that is not a supervisor → REFUSED (rc 2)" "$rc" 2
assert_eq       "…recorder untouched" "$(wc -l < "$RECORD" | tr -d ' ')" "0"

# --- REFUSAL: the scan itself refused (empty registry → control refusal) ---
new_case r_scanrefused
mkdir -p "$WORK/r_scanrefused-scratch/monitor" "$CASE_ROOT/monitor/.state"
plant_proc "$CASE_PROCFS" 5102 1 "$WORK/r_scanrefused-scratch" bash "$WORK/r_scanrefused-scratch/monitor/serve-supervised.sh"
: > "$RECORD"
out=$(run_retire "$SVC" 5102 --yes); rc=$?
assert_rc       "when the scan REFUSES (empty registry), retire-orphan refuses too (rc 2)" "$rc" 2
assert_contains "…and says the scan refused" "$out" "the orphans scan itself REFUSED"
assert_eq       "…recorder untouched" "$(wc -l < "$RECORD" | tr -d ' ')" "0"

# --- RETIRE: --yes, signals land (the recorder reaps the planted entries) ---
build_retire_case r_yes
out=$(REC_REAP=1 run_retire "$SVC" 5002 --yes); rc=$?
assert_rc       "an orphan with --yes → retired (rc 0)" "$rc" 0
assert_contains "the FIRST signal is TERM to the process GROUP (a setsid leader: pid == pgid)" "$(head -1 "$RECORD")" "-TERM -- -5002"
assert_eq       "…and, the group having reaped, no KILL escalation was needed" "$(grep -c 'KILL' "$RECORD")" "0"
assert_contains "…the verb reports the retirement" "$out" "retired pid 5002 (3 process(es))"
_rlog="$CASE_ROOT/monitor/.state/svc-retire.log"
assert_eq       "a retirement row was appended to monitor/.state/svc-retire.log" "$([[ -s "$_rlog" ]] && echo present || echo absent)" "present"
assert_contains "…carrying the pid" "$(cat "$_rlog")" "pid=5002"
assert_contains "…the source path" "$(cat "$_rlog")" "src=$WORK/r_yes-scratch/monitor/serve-supervised.sh"
assert_contains "…the whole kill set" "$(cat "$_rlog")" "kill_set=5002 5003 5004"
assert_contains "…and who" "$(cat "$_rlog")" "user="

# --- RETIRE: --yes, signals do NOT land → KILL escalation, rc 1 ---
build_retire_case r_stuck
out=$(REC_REAP=0 run_retire "$SVC" 5002 --yes); rc=$?
assert_rc       "if the set survives TERM + grace AND KILL, the verb says so with rc 1" "$rc" 1
assert_contains "…escalation to KILL is recorded" "$(cat "$RECORD")" "-KILL -- -5002"
assert_contains "…and the survivors are named" "$out" "still present after KILL: 5002 5003 5004"
assert_eq       "…the log row exists even though the signals did not land (stamp-then-act)" "$([[ -s "$CASE_ROOT/monitor/.state/svc-retire.log" ]] && echo present || echo absent)" "present"

# --- MUTANT: drop the not-in-orphan-set refusal → a registered pid gets signalled ---
# The assertion this proves has teeth: "a registered supervisor is never
# signalled here" must go RED when the refusal is gone.
# svc.sh sources its siblings relative to its OWN location, so the mutant is
# staged in a shadow monitor/ made of symlinks to the real files — every file
# but svc.sh itself — and nothing is written into the tree.
MUTDIR="$WORK/mut/monitor"; mkdir -p "$MUTDIR"
for _f in "$_repo_root"/monitor/* "$_repo_root"/monitor/.[!.]*; do
    [[ -e "$_f" ]] || continue
    [[ "${_f##*/}" == svc.sh ]] && continue
    ln -s "$_f" "$MUTDIR/${_f##*/}"
done
MUT="$MUTDIR/svc.sh"
sed 's/^    if \[\[ -z "\$row" \]\]; then$/    if false; then/' "$SVC" > "$MUT"
assert_eq "MUTANT applied: the not-in-set refusal is disarmed in the copy" "$(grep -c '^    if false; then$' "$MUT")" "1"
build_retire_case r_mutant
out=$(REC_REAP=1 run_retire "$MUT" 5001 --yes); rc=$?
assert_contains "MUTANT: with the refusal gone, the REGISTERED pid IS signalled — the guard above is load-bearing" "$(cat "$RECORD")" "-TERM -- -5001"
rm -rf "$WORK/mut"

# --- the read-only scan is unchanged by the TSV seam ---
build_retire_case r_tsv
out=$(SVC_ORPHANS_TSV=1 run_orphans); rc=$?
assert_rc       "orphans with SVC_ORPHANS_TSV=1 still exits 1 on a finding" "$rc" 1
assert_contains "…and emits the machine-readable row with the descendants" "$out" "$(printf 'ORPHAN\t5002\t%s/r_tsv-scratch/monitor/serve-supervised.sh\t5003 5004' "$WORK")"
out=$(run_orphans)
assert_not_contains "…while the default report carries no ORPHAN row" "$out" $'ORPHAN\t5002'

# COUNT GUARD (your-org/nexus-code#821 / #1308). The ledger proves no assertion
# was LOST in a subshell; it cannot prove one was never REACHED. A suite whose
# arms stop running still prints a green summary of whatever did run, so the
# count is declared here and compared EXACTLY. Bump it deliberately when adding
# an arm; a mismatch is a red, not a warning.
EXPECTED_ASSERTIONS=77
_run_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
