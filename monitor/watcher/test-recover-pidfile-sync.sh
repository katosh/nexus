#!/usr/bin/env bash
# Tests for the relaunch->probe synchronisation in
# `monitor/bootstrap-recover.sh:_recover_launch_service` (your-org/nexus-code#918).
#
# THE DEFECT. The supervisor pidfile is written by the CHILD:
#
#     setsid bash -c "$inner" </dev/null >>"$lf" 2>&1 &   # $inner writes $pf
#     … return 0                                          # parent does not wait
#
# Every caller reads that record immediately after this returns —
# `svc.sh:_svc_reconcile_orphan` most consequentially. Under load the read won
# the race and a service that had restarted CORRECTLY was reported
# `CANNOT RECONCILE — relaunched, but no live supervisor record exists`, exit
# non-zero. Not a test bug: a production defect in service recovery, and on this
# board the difference between self-healing and an operator incident.
#
# TWO SIGNATURES, ONE RACE, which is why it read as a flake rather than a bug:
#   * `absent`          — the pidfile does not exist yet;
#   * `malformed-record`— read between `>` truncating the file and the `printf`
#                         landing, i.e. a torn read of an empty file.
#
# WHY THIS SUITE INJECTS LATENCY. Measured in the field the race fires at 4.2%
# (5 in 120 runs; `#918` reported ~35%, which is not what the data says). A 4.2%
# discriminator cannot distinguish "fixed" from "lucky" at any run count this
# suite can afford — a clean 6-run arm proves nothing at p=0.958^6=0.77. So the
# child's write is DELAYED, which turns the same race into a 100% reproduction.
# Potency is then demonstrable rather than hoped for, and each arm asserts a
# deterministic verdict.
#
# THIS FILE ADDS TWO UNRESOLVABLE `source` TOKENS, DELIBERATELY, and they are
# recorded in `aso-unresolved-sources.manifest` (two `$br` entries). The shape is
# `source "$br"` where `br` is a FUNCTION PARAMETER holding the path to a variant
# this suite GENERATES at run time under $WORK. It is genuinely shell-dependent,
# not a statically-resolvable path hiding behind a principled-sounding sentence
# (which is the failure `test-ambient-shell-option-scope` guards against, twice
# — your-org/nexus-code#770, #778 F1): the file does not exist in the repo at
# all, so no static resolver could follow the edge even in principle.
#
# HOW THE SEAM WORKS, AND WHY IT IS NOT A PRODUCTION TEST HOOK. The suite copies
# `bootstrap-recover.sh` and rewrites ONE line in the copy. Production carries no
# test-only code. The copy step ASSERTS its anchor is present and that the edit
# actually changed the text, so a future rewrite of that line fails this suite
# LOUDLY instead of silently testing nothing — an inert edit and a passing test
# are otherwise the same observable.
#
# Run: bash monitor/watcher/test-recover-pidfile-sync.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
SRC="$REPO_ROOT/monitor/bootstrap-recover.sh"
[[ -r "$SRC" ]] || { echo "FAIL: missing $SRC" >&2; echo FAILED; exit 1; }

# Shared harness: subshell-durable ledger, and it counts a MISSING assert_*
# helper (rc 127) that would otherwise pass silently.
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-pidfile-sync-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/wd"

# The launch command. It must NOT `exec` away: an exec replaces the cmdline and
# `_recover_supervisor_probe`'s cmdline check would then fail for a FIXTURE
# reason, masking the very race under test. It is also SHORT-LIVED, so this
# suite never creates a setsid child that outlives it — `proc-kill-authorized`
# refuses setsid session leaders by design, so a harness that needs to reap them
# has no sanctioned path and should not create them.
cat > "$WORK/wd/serve-supervised.sh" <<'S'
#!/usr/bin/env bash
for _ in 1 2 3 4 5 6; do sleep 0.5; done
S
chmod +x "$WORK/wd/serve-supervised.sh"

ANCHOR='printf -v inner '\''ulimit -Su "$(ulimit -Hu)" 2>/dev/null || true; _tf=%q.tmp.$$; { %s; } > "$_tf" && mv -f "$_tf" %q; cd %q && exec %s'\'' "$pf" "$idrec" "$pf" "$workdir" "$launch"'

# make_variant <outfile> <sed-style old> <new> — copy the real file with ONE
# line rewritten, and PROVE the rewrite happened.
make_variant() {
    local out="$1" old="$2" new="$3"
    python3 - "$SRC" "$out" "$old" "$new" <<'PY'
import sys
src, out, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s:
    sys.stderr.write("ANCHOR ABSENT\n"); sys.exit(3)
m = s.replace(old, new, 1)
if m == s:
    sys.stderr.write("EDIT INERT\n"); sys.exit(3)
open(out, "w").write(m)
PY
}

# run_probe <recover-file> <probe-delay> — launch, then probe exactly the way
# `_svc_reconcile_orphan` does. Prints "<state>|<reason>".
run_probe() {
    local br="$1" delay="${2:-0}"
    # A PER-RUN state dir is load-bearing: with a shared one, a previous run's
    # latency-delayed child writes its pidfile into the next run's freshly
    # cleaned dir and manufactures a valid record — contaminating toward a FALSE
    # GREEN, the dangerous direction.
    local run; run=$(mktemp -d "$WORK/run.XXXXXX")
    (
        export NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$run/state"
        mkdir -p "$run/state/services"
        # shellcheck disable=SC1090
        source "$br" >/dev/null 2>&1 || true
        _recover_launch_service svcA "$WORK/wd" "$WORK/wd/serve-supervised.sh" "$WORK/wd/a.log" >/dev/null 2>&1
        [[ "$delay" != 0 ]] && sleep "$delay"
        _recover_supervisor_probe svcA "$WORK/wd/serve-supervised.sh"
        printf '%s|%s\n' "${_RECOVER_SUP_STATE%%:*}" "${_RECOVER_STALE_REASON:-}"
    )
    rm -rf "$run"
}

verdicts() {   # <recover-file> <delay> <n> -> unique sorted verdicts, comma-joined
    local br="$1" delay="$2" n="$3" i out=''
    for ((i = 0; i < n; i++)); do out+="$(run_probe "$br" "$delay")"$'\n'; done
    printf '%s' "$out" | grep -v '^$' | sort -u | paste -sd, -
}

N=6   # each arm is deterministic, so a small N is a real check, not a sample

echo "=== the fix, against a child whose write is DELAYED ==="
# ABSENT arm: the record appears late, so an unsynchronised parent sees nothing.
make_variant "$WORK/late.sh" "$ANCHOR" "${ANCHOR/|| true; _tf=/|| true; sleep 1.5; _tf=}" \
    && assert_eq "the 'record appears late' variant was really built" ok ok \
    || assert_eq "the 'record appears late' variant was really built" BUILD-FAILED ok
assert_eq "a late-writing child still yields a live record (was: absent)" \
    "$(verdicts "$WORK/late.sh" 0 $N)" "alive|"

# TORN arm: `>` truncates on open and the content lands later, so a reader
# between the two sees an EMPTY file.
make_variant "$WORK/torn.sh" "$ANCHOR" "${ANCHOR/\{ %s; \} > \"\$_tf\"/\{ sleep 1.5; %s; \} > \"\$_tf\"}" \
    && assert_eq "the 'torn write' variant was really built" ok ok \
    || assert_eq "the 'torn write' variant was really built" BUILD-FAILED ok
assert_eq "a torn write is never observed as a record (was: malformed-record)" \
    "$(verdicts "$WORK/torn.sh" 0.5 $N)" "alive|"

echo "=== the unpatched shape must FAIL — this is the potency check ==="
# Without these, a variant that silently stopped injecting latency would let
# both arms above pass while testing nothing.
make_variant "$WORK/nowait.sh" 'if ! _recover_wait_pidfile "$pf"; then' 'if false; then' \
    && assert_eq "the 'no wait' variant was really built" ok ok \
    || assert_eq "the 'no wait' variant was really built" BUILD-FAILED ok
NOWAIT_LATE="$WORK/nowait-late.sh"
python3 - "$WORK/nowait.sh" "$NOWAIT_LATE" "$ANCHOR" "${ANCHOR/|| true; _tf=/|| true; sleep 1.5; _tf=}" <<'PY'
import sys
src, out, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s: sys.stderr.write("ANCHOR ABSENT\n"); sys.exit(3)
m = s.replace(old, new, 1)
if m == s: sys.stderr.write("EDIT INERT\n"); sys.exit(3)
open(out, "w").write(m)
PY
assert_eq "REMOVING the wait reproduces the original 'absent' failure" \
    "$(verdicts "$NOWAIT_LATE" 0 $N)" "absent|"

echo "=== an unsynchronised reader — why the write is atomic ==="
# The wait fixes the LAUNCH path only. Eight other sites read this pidfile with
# no wait at all (svc.sh x2, jupyter-up.sh x3, remote-up.sh x2, and the probe
# itself), at moments they do not control. Measured: with a non-atomic write
# such a reader sees a torn record every time; with the atomic write, never.
# So atomicity is justified by THOSE readers, not by the launch path — the
# launch path is already covered by the wait.
NONATOMIC="$WORK/nonatomic.sh"
make_variant "$NONATOMIC" "$ANCHOR" \
  'printf -v inner '\''ulimit -Su "$(ulimit -Hu)" 2>/dev/null || true; { sleep 1.5; %s; } > %q; cd %q && exec %s'\'' "$idrec" "$pf" "$workdir" "$launch"' \
    && assert_eq "the 'non-atomic write' variant was really built" ok ok \
    || assert_eq "the 'non-atomic write' variant was really built" BUILD-FAILED ok

race_reader() {   # <recover-file> -> ok | TORN
    local br="$1" run; run=$(mktemp -d "$WORK/run.XXXXXX")
    (
        export NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$run/state"
        mkdir -p "$run/state/services"
        local pf="$run/state/services/svcA.pid" worst=ok l
        # shellcheck disable=SC1090
        source "$br" >/dev/null 2>&1 || true
        ( _recover_launch_service svcA "$WORK/wd" "$WORK/wd/serve-supervised.sh" "$WORK/wd/a.log" >/dev/null 2>&1 ) &
        local lp=$!
        for _ in $(seq 60); do
            if [[ -f "$pf" ]]; then
                read -r l < "$pf" 2>/dev/null || l=''
                [[ "$l" =~ ^[0-9]+$ ]] || worst=TORN
            fi
            sleep 0.02
        done
        wait $lp 2>/dev/null
        printf '%s\n' "$worst"
    )
    rm -rf "$run"
}
r_bad=''; r_good=''
for _ in 1 2 3; do r_bad+="$(race_reader "$NONATOMIC")"$'\n'; done
for _ in 1 2 3; do r_good+="$(race_reader "$SRC")"$'\n'; done
assert_eq "a NON-atomic write is seen torn by an unsynchronised reader" \
    "$(printf '%s' "$r_bad" | grep -v '^$' | sort -u | paste -sd, -)" "TORN"
assert_eq "the atomic write never is" \
    "$(printf '%s' "$r_good" | grep -v '^$' | sort -u | paste -sd, -)" "ok"

echo "=== the child never writes: LOUD failure, never a silent 'absent' ==="
make_variant "$WORK/never.sh" "$ANCHOR" "${ANCHOR/|| true; _tf=/|| true; sleep 30; _tf=}" \
    && assert_eq "the 'never writes' variant was really built" ok ok \
    || assert_eq "the 'never writes' variant was really built" BUILD-FAILED ok
never_out=$(
    run=$(mktemp -d "$WORK/run.XXXXXX")
    export NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$run/state" NEXUS_RECOVER_PIDFILE_TIMEOUT=1
    mkdir -p "$run/state/services"
    # shellcheck disable=SC1090
    source "$WORK/never.sh" >/dev/null 2>&1 || true
    _recover_launch_service svcA "$WORK/wd" "$WORK/wd/serve-supervised.sh" "$WORK/wd/a.log" 2>&1
    printf 'RC=%s\n' "$?"
    rm -rf "$run"
)
assert_contains "a child that never writes is reported as a FAILED launch" \
    "$never_out" "did not write its pid record"
assert_contains "…and the caller sees non-zero" "$never_out" "RC=1"

# WHAT HAPPENS TO A PRE-EXISTING RECORD WHEN THE LAUNCH FAILS (sk890).
# The clear-before-launch step is UNCONDITIONAL and runs BEFORE the child, so
# with `rm -f` a failed launch destroyed the prior record — on exactly the path
# where an operator most needs it, since a failed relaunch is when that file is
# the only trace of which supervisor died. `#606` built a deliberate culture
# around `Pid record PRESERVED (evidence)`. Nothing asserted this, so nothing
# would have caught its removal; the `never writes` fixture above is already the
# scenario, so witnessing it costs one more run.
evidence_out=$(
    run=$(mktemp -d "$WORK/run.XXXXXX")
    export NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$run/state" NEXUS_RECOVER_PIDFILE_TIMEOUT=1
    mkdir -p "$run/state/services"
    pf="$run/state/services/svcA.pid"
    printf '4242\nns=x\nstart=1\n' > "$pf"          # the PRIOR supervisor's record
    # shellcheck disable=SC1090
    source "$WORK/never.sh" >/dev/null 2>&1 || true
    _recover_launch_service svcA "$WORK/wd" "$WORK/wd/serve-supervised.sh" "$WORK/wd/a.log" >/dev/null 2>&1
    printf 'RC=%s\n' "$?"
    # the LIVE record must be gone (the wait must not be satisfied by a stale
    # file — that is the whole point of clearing it) …
    [[ -f "$pf" ]] && printf 'LIVE_RECORD=present\n' || printf 'LIVE_RECORD=cleared\n'
    # … but the EVIDENCE must survive, and still name the dead supervisor.
    if [[ -f "$pf.superseded" ]]; then
        read -r sup < "$pf.superseded" 2>/dev/null || sup=''
        printf 'EVIDENCE=%s\n' "${sup:-empty}"
    else
        printf 'EVIDENCE=DESTROYED\n'
    fi
    rm -rf "$run"
)
assert_contains "a FAILED launch still reports failure" "$evidence_out" "RC=1"
assert_contains "…the stale record is cleared, so the wait cannot be satisfied by it" \
    "$evidence_out" "LIVE_RECORD=cleared"
assert_contains "…and the prior supervisor's record SURVIVES as evidence (#606)" \
    "$evidence_out" "EVIDENCE=4242"

echo "=== the ordinary path is unaffected ==="
ok_out=$(
    run=$(mktemp -d "$WORK/run.XXXXXX")
    export NEXUS_ROOT="$REPO_ROOT" NEXUS_STATE_DIR="$run/state" NEXUS_RECOVER_PIDFILE_TIMEOUT=10
    mkdir -p "$run/state/services"
    # shellcheck disable=SC1090
    source "$SRC" >/dev/null 2>&1 || true
    _recover_launch_service svcA "$WORK/wd" "$WORK/wd/serve-supervised.sh" "$WORK/wd/a.log" >/dev/null 2>&1
    printf 'RC=%s\n' "$?"
    read -r first < "$run/state/services/svcA.pid" 2>/dev/null || first=''
    printf 'PID_NUMERIC=%s\n' "$([[ "$first" =~ ^[0-9]+$ ]] && echo yes || echo no)"
    grep -qc '^ns=' "$run/state/services/svcA.pid" >/dev/null 2>&1 && printf 'HAS_NS=yes\n' || printf 'HAS_NS=no\n'
    grep -q '^start=' "$run/state/services/svcA.pid" 2>/dev/null && printf 'HAS_START=yes\n' || printf 'HAS_START=no\n'
    rm -rf "$run"
)
assert_contains "a normal launch still returns 0" "$ok_out" "RC=0"
assert_contains "…and the record's first line is the pid (legacy readers)" "$ok_out" "PID_NUMERIC=yes"
assert_contains "…and it carries ns= identity" "$ok_out" "HAS_NS=yes"
assert_contains "…and start= identity" "$ok_out" "HAS_START=yes"

# Pinned total: a count that silently shrinks is a suite quietly covering less
# than it claims.
EXPECTED=19
if (( PASS + FAIL != EXPECTED )); then
    echo "ASSERTION COUNT MISMATCH — $(( PASS + FAIL )) ran, $EXPECTED expected" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
