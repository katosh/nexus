#!/usr/bin/env bash
# Tests for the ORPHANED-DAEMON reconcile path (your-org/nexus-code#606).
#
# The state under test: a service whose healthcheck PASSES while its
# supervisor record is stale or absent — the daemon outlived the supervisor
# that was tracking it. Before this change `svc.sh restart` on that state
# (a) deleted the pid record without stopping anything, (b) short-circuited
# `start` on the daemon's own passing healthcheck, so the promised bounce
# never happened, and (c) reported `healthy` while advising the operator to
# run the very command that had just failed. Reachable by every emit-only
# service after a container restart, because the state dir survives on
# shared storage while every pid in it refers to a dead pid namespace.
#
# Cases:
#   1.  pid identity: record minted in a FOREIGN pid namespace reads stale
#       (reason foreign-namespace) even though the pid is live AND its
#       cmdline matches the wrapper — the pre-#606 false-`alive`.
#   1n. NEGATIVE CONTROL for case 1: the SAME live pid and wrapper with the
#       CURRENT namespace recorded reads `alive`. Without this, case 1
#       passes just as well if the guard fires unconditionally.
#   2.  pid identity: recorded start-time != the live pid's start-time reads
#       stale (reason pid-recycled) — the recycled-pid case the cmdline
#       guard cannot catch when several services share one wrapper.
#   2n. NEGATIVE CONTROL for case 2: matching start-time reads `alive`.
#   3.  Legacy bare-pid record (no ns=/start= keys) still reads `alive` —
#       records written before this change must not all turn stale.
#   4.  recover_service: healthy + STALE record → `healthy-unsupervised`
#       (not `healthy`), and it does NOT relaunch onto the live daemon.
#   4n. NEGATIVE CONTROL for case 4: healthy + ABSENT record → plain
#       `healthy`. The stale-vs-absent asymmetry is deliberate; a service
#       that never had a record contradicts nothing.
#   5.  `stop` on an orphan REFUSES to delete the record, exits non-zero,
#       and does not claim the service stopped.
#   5n. NEGATIVE CONTROL for case 5: stale record + FAILING healthcheck is
#       consistent litter → record removed, exit 0. Proves the refusal is
#       conditioned on the healthcheck, not on staleness alone.
#   6.  `restart` on an orphan whose daemon IS locatable: the daemon is
#       really bounced (old pid gone, wrapper re-run) and a fresh VALID
#       record exists. Exit 0.
#   7.  `restart` on an orphan whose daemon is NOT locatable: exits
#       non-zero, prints CANNOT RECONCILE with the reason, PRESERVES the
#       record, and never prints a bare `healthy` verdict.
#   8.  `restart` where the located daemon dies but the healthcheck STILL
#       passes (a foreign listener on the same endpoint — the live
#       2026-07-29 nexus-remote-ssh incident): CANNOT RECONCILE, non-zero.
#   9.  `start` on an orphan fails loudly instead of reporting success.
#   10. BLAST RADIUS: a daemon sharing the wrapper BASENAME but living in a
#       different workdir is NOT killed. Frozen from a real outage — an
#       earlier draft of this very fix matched on basename alone and TERMed
#       four live production supervisors that share `serve-supervised.sh`.
#   11. AMBIGUOUS discovery (two live candidates matching launch AND workdir)
#       signals NOTHING and refuses. "Kill every match" is how a targeted
#       bounce becomes an outage.
#
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REAL_SVC="$_real_test_dir/../svc.sh"
REAL_RECOVER="$_real_test_dir/../bootstrap-recover.sh"
REAL_LIB="$_real_test_dir/_lib.sh"
REAL_FS_PROBE="$_real_test_dir/../_fs_probe.sh"
REAL_LOG_MODE="$_real_test_dir/../_log-mode.sh"
REAL_DROPPED="$_real_test_dir/../_dropped_manifest.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# th_kill_fixture_pid / th_kill_own_child (PID-recycling-safe cleanup).
# shellcheck source=_test_helpers.sh
. "$_real_test_dir/_test_helpers.sh"

# Every fixture root this run creates, recorded so the end-of-run leak check
# can look for survivors under ALL of them. Lives outside any case root so it
# outlives each `rm -rf`.
ROOT_LEDGER=$(mktemp -t nexus-orphan-roots-XXXXXX)

build_case() {
    local label="$1"
    ROOT=$(mktemp -d -t "nexus-orphan-${label}-XXXXXX")
    printf '%s\n' "$ROOT" >> "$ROOT_LEDGER"
    mkdir -p "$ROOT/monitor/watcher" "$ROOT/monitor/.state/services" \
             "$ROOT/config" "$ROOT/bin" "$ROOT/wd"
    cp "$REAL_SVC" "$ROOT/monitor/svc.sh"
    cp "$REAL_RECOVER" "$ROOT/monitor/bootstrap-recover.sh"
    cp "$REAL_LIB" "$ROOT/monitor/watcher/_lib.sh"
    cp "$REAL_FS_PROBE" "$ROOT/monitor/_fs_probe.sh"
    cp "$REAL_LOG_MODE" "$ROOT/monitor/_log-mode.sh"
    # bootstrap-recover.sh has sourced this unconditionally since `#651`
    # (a9fcb69); the fixture never copied it, so every run printed
    # "_dropped_manifest.sh: No such file or directory" and `restart`
    # intermittently returned non-zero — case 6 measured FLAKY at 1 failure in
    # 3 runs, on this branch and on `dev` alike. It is documented
    # side-effect-free on source, so copying it makes the fixture faithful
    # without changing what the case exercises.
    cp "$REAL_DROPPED" "$ROOT/monitor/_dropped_manifest.sh" 2>/dev/null || true
    cp "$_real_test_dir/_idle_probe.sh" "$ROOT/monitor/watcher/_idle_probe.sh" 2>/dev/null || true
    cp "$_real_test_dir/_version_restart.sh" "$ROOT/monitor/watcher/_version_restart.sh" 2>/dev/null || true
    chmod +x "$ROOT/monitor/svc.sh" "$ROOT/monitor/bootstrap-recover.sh"
    SVC="$ROOT/monitor/svc.sh"
    RECOVER="$ROOT/monitor/bootstrap-recover.sh"
    REG="$ROOT/monitor/services.registry"
    BIN="$ROOT/bin"
    WINDOWS="$ROOT/windows"; : > "$WINDOWS"
    # Health verdict is a file the fixture flips: `test -f $ROOT/healthy`.
    HEALTH_FLAG="$ROOT/healthy"

    # Spawned-sleeper ledger. A FILE, not a variable, and that is the whole
    # of your-org/nexus-code#860's first cause: `start_sleeper` is called as
    # `SP=$(start_sleeper …)`, and a command substitution runs its body in a
    # SUBSHELL, so `SLEEPERS="$SLEEPERS $!"` was discarded on every return.
    # Measured: the variable was empty on every run, so `cleanup_case`'s reap
    # loop iterated ZERO times while the suite reported ALL TESTS PASSED.
    SLEEPER_LEDGER="$ROOT/.sleepers"
    : > "$SLEEPER_LEDGER"

    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$ROOT/config/load.sh"
    chmod +x "$ROOT/config/load.sh"
    printf '#!/usr/bin/env bash\n:\n' > "$ROOT/monitor/watcher/launcher.sh"
    chmod +x "$ROOT/monitor/watcher/launcher.sh"

    cat > "$BIN/tmux" <<TM
#!/usr/bin/env bash
case "\$1" in
  list-windows) cat "$WINDOWS" 2>/dev/null ;;
  has-session)  exit 0 ;;
  *)            : ;;
esac
exit 0
TM
    chmod +x "$BIN/tmux"
}

# Reap everything this case spawned, then remove the fixture tree.
#
# THE ORDER MATTERS AND IT USED TO BE WRONG. `rm -rf "$ROOT"` ran while
# supervisors were still alive, which is how the survivors ended up holding a
# DELETED working directory — the state that makes them unattributable to
# anything except a /proc sweep. Reap first, verify the reap, then remove.
#
# Ownership here is established by FIXTURE ROOT, never by ppid. Every process
# worth reaping at this point has already been reparented to init (see
# th_reap_fixture_root's header), so `th_kill_own_child`'s `ppid == $$`
# requirement — correct as a recycling guard — refuses exactly the pids that
# leak. That refusal was silent, and it is your-org/nexus-code#860.
cleanup_case() {
    local pf p
    [[ -n "${ROOT:-}" ]] || return 0
    # 1. The sleepers this case recorded. Signalled through the fixture-root
    #    identity guard, which works on a reparented pid where the own-child
    #    guard cannot.
    if [[ -n "${SLEEPER_LEDGER:-}" && -f "$SLEEPER_LEDGER" ]]; then
        while read -r p; do
            [[ "$p" =~ ^[0-9]+$ ]] && th_kill_fixture_pid "$p" "$ROOT" KILL
        done < "$SLEEPER_LEDGER"
    fi
    # 2. Supervisors svc.sh itself recorded during the case.
    for pf in "$ROOT"/monitor/.state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r p < "$pf" 2>/dev/null
        [[ "$p" =~ ^[0-9]+$ ]] && th_kill_fixture_pid "$p" "$ROOT" KILL --group
    done
    # 3. BACKSTOP: a fixed-point /proc sweep scoped to this case's root. The
    #    wrapper forks (`bash <wrapper>` runs `sleep` children), and svc.sh
    #    relaunches supervisors, so neither list above is complete by
    #    construction. This catches what they miss and, unlike the lists, it
    #    can tell you it FAILED.
    th_reap_fixture_root "$ROOT" KILL 4 >/dev/null || \
        echo "WARN: fixture root $ROOT still had live processes after the sweep" >&2
    rm -rf "$ROOT"
    unset ROOT SVC RECOVER REG BIN WINDOWS HEALTH_FLAG SLEEPER_LEDGER
}

# An interrupted run (^C, or the TERM run-tests.sh sends on a timeout) used to
# skip cleanup entirely — the file carried no trap at all. Idempotent: every
# step above is guarded on $ROOT still being set.
trap 'cleanup_case' EXIT INT TERM HUP

# A wrapper that marks its own pid and idles — stands in for a supervised
# daemon. Re-runs append to $marker, so a genuine bounce is visible as a 2nd
# line; $pidmark always names the CURRENT daemon, which lets a healthcheck
# track the daemon's liveness instead of a static flag file.
make_wrapper() {
    local path="$1" marker="$2" pidmark="${3:-}"
    cat > "$path" <<EOF
#!/usr/bin/env bash
echo "up \$\$" >> "$marker"
${pidmark:+echo \$\$ > "$pidmark"}
while true; do sleep 1; done
EOF
    chmod +x "$path"
}

# A healthcheck that passes iff the pid in $pidmark is alive — i.e. iff a
# daemon really is serving. A static `test -f` flag cannot distinguish "the
# daemon is up" from "the flag exists", which is the very conflation under
# test.
health_tracks_daemon() { printf 'p=$(cat %q 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null' "$1"; }

# Start a live process whose argv contains the wrapper path AND whose cwd is
# the service workdir — both halves of the discovery predicate. Echoes its pid.
#
# The pid is recorded to a FILE. Every caller uses `X=$(start_sleeper …)`, and
# a command substitution body runs in a subshell whose variable writes are
# discarded on return — so the previous `SLEEPERS="$SLEEPERS $p"` never
# reached the parent shell and the reap list was empty on every run
# (your-org/nexus-code#860). A file crosses the subshell boundary; a variable
# cannot.
start_sleeper() {
    local wrapper="$1" workdir="${2:-$ROOT/wd}"
    ( cd "$workdir" && exec bash "$wrapper" >/dev/null 2>&1 ) &
    local p=$!
    printf '%s\n' "$p" >> "$SLEEPER_LEDGER"
    sleep 0.4
    printf '%s' "$p"
}

# /proc/<pid>/stat field 22 — same extraction the code under test uses.
starttime_of() {
    local sr; sr=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    sr=${sr#*") "}
    # shellcheck disable=SC2086
    set -- $sr
    printf '%s' "${20:-}"
}

write_record() {   # write_record <name> <pid> [ns] [start]
    local pf="$ROOT/monitor/.state/services/$1.pid"
    { printf '%s\n' "$2"
      [[ -n "${3:-}" ]] && printf 'ns=%s\n' "$3"
      [[ -n "${4:-}" ]] && printf 'start=%s\n' "$4"
    } > "$pf"
}

reg_line5() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

run_svc() {
    PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
        bash "$SVC" "$@" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?
}

# ---------------------------------------------------------------------------
# Cases 1-4: the identity primitives, exercised as sourced units.
# ---------------------------------------------------------------------------
echo '=== cases 1-4: pid-record identity (ns / start-time) ==='
build_case units
export NEXUS_ROOT="$ROOT"
STATE_DIR="$ROOT/monitor/.state"
# shellcheck source=/dev/null
source "$RECOVER"          # BASH_SOURCE guard: functions only
STATE_DIR="$ROOT/monitor/.state"

WRAP="$ROOT/wd/serve-supervised.sh"
make_wrapper "$WRAP" "$ROOT/marker"
SP=$(start_sleeper "$WRAP")
CUR_NS=$(readlink "/proc/$$/ns/pid" 2>/dev/null)
SP_START=$(starttime_of "$SP")

# Case 1 — foreign namespace beats a live pid with a matching cmdline.
write_record svcA "$SP" 'pid:[4026500001]' "$SP_START"
_recover_supervisor_probe svcA "$WRAP"
[[ "$_RECOVER_SUP_STATE" == stale:* && "$_RECOVER_STALE_REASON" == foreign-namespace ]] \
    && pass "1: foreign-namespace record reads stale (live pid, matching cmdline)" \
    || fail "1: expected stale/foreign-namespace, got [$_RECOVER_SUP_STATE/$_RECOVER_STALE_REASON]"

# Case 1n — NEGATIVE CONTROL: identical record, current namespace.
write_record svcA "$SP" "$CUR_NS" "$SP_START"
_recover_supervisor_probe svcA "$WRAP"
[[ "$_RECOVER_SUP_STATE" == "alive:$SP" ]] \
    && pass "1n: control — same pid with the CURRENT namespace reads alive (guard is discriminating)" \
    || fail "1n: expected alive:$SP, got [$_RECOVER_SUP_STATE/$_RECOVER_STALE_REASON]"

# Case 2 — start-time mismatch = the pid was recycled.
write_record svcA "$SP" "$CUR_NS" "$(( SP_START + 5000 ))"
_recover_supervisor_probe svcA "$WRAP"
[[ "$_RECOVER_SUP_STATE" == stale:* && "$_RECOVER_STALE_REASON" == pid-recycled ]] \
    && pass "2: start-time mismatch reads stale (reason pid-recycled)" \
    || fail "2: expected stale/pid-recycled, got [$_RECOVER_SUP_STATE/$_RECOVER_STALE_REASON]"

# Case 2n — NEGATIVE CONTROL: matching start-time.
write_record svcA "$SP" "$CUR_NS" "$SP_START"
_recover_supervisor_probe svcA "$WRAP"
[[ "$_RECOVER_SUP_STATE" == "alive:$SP" ]] \
    && pass "2n: control — matching start-time reads alive" \
    || fail "2n: expected alive:$SP, got [$_RECOVER_SUP_STATE]"

# Case 3 — legacy bare-pid record keeps working.
write_record svcA "$SP"
_recover_supervisor_probe svcA "$WRAP"
[[ "$_RECOVER_SUP_STATE" == "alive:$SP" ]] \
    && pass "3: legacy bare-pid record (no ns=/start=) still reads alive" \
    || fail "3: legacy record regressed to [$_RECOVER_SUP_STATE/$_RECOVER_STALE_REASON]"

# Case 4 — recover_service must not call an unsupervised daemon `healthy`.
# Dead-but-recorded pid + passing healthcheck = the orphan signature.
#
# THE PID MUST REALLY BE DEAD, and it was not. `th_kill_own_child` requires
# `ppid == $$`; `start_sleeper` is called through `$( )`, whose subshell has
# already exited, so this sleeper's ppid is 1 and the kill was REFUSED (rc 1,
# silently). The case still passed — but on the start-time mismatch below,
# never on the dead-pid premise it names. Measured on `a74805b`: rc 1, and
# `kill -0` confirmed the "DEAD" process still running (your-org/nexus-code#860).
DEAD=$(start_sleeper "$WRAP")
th_kill_fixture_pid "$DEAD" "$ROOT" KILL
for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$DEAD" 2>/dev/null || break; sleep 0.1; done
kill -0 "$DEAD" 2>/dev/null \
    && fail "4: PRECONDITION — the 'dead' pid $DEAD is still alive; the case cannot test what it claims" \
    || pass "4: precondition — the recorded pid really is dead"
write_record svcB "$DEAD" "$CUR_NS" '12345'
out=$(recover_service svcB "$ROOT/wd" "$WRAP" 'true' "$ROOT/wd/b.log" 2>/dev/null)
[[ "$out" == healthy-unsupervised ]] \
    && pass "4: healthy + stale record → healthy-unsupervised (not 'healthy')" \
    || fail "4: expected healthy-unsupervised, got [$out]"
[[ ! -s "$ROOT/marker-b" ]] \
    && pass "4: did not relaunch onto the live daemon" \
    || fail "4: relaunched despite a serving daemon"

# Case 4n — NEGATIVE CONTROL: no record at all is not an inconsistency.
rm -f "$ROOT/monitor/.state/services/svcC.pid"
out=$(recover_service svcC "$ROOT/wd" "$WRAP" 'true' "$ROOT/wd/c.log" 2>/dev/null)
[[ "$out" == healthy ]] \
    && pass "4n: control — healthy + ABSENT record stays plain 'healthy'" \
    || fail "4n: expected healthy, got [$out]"
cleanup_case

# ---------------------------------------------------------------------------
# Cases 5-9: the svc.sh CLI verbs on an orphaned service.
# ---------------------------------------------------------------------------
echo '=== cases 5-9: svc.sh stop/restart/start on an orphan ==='

# Case 5 — `stop` must not destroy the record of a serving daemon.
build_case stop-orphan
WRAP="$ROOT/wd/serve-supervised.sh"
make_wrapper "$WRAP" "$ROOT/marker"
touch "$HEALTH_FLAG"
reg_line5 svcA "$ROOT/wd" "$WRAP" "test -f $HEALTH_FLAG" "$ROOT/wd/a.log" > "$REG"
write_record svcA 999999 "$(readlink /proc/$$/ns/pid)" '1'
run_svc stop svcA
(( RC != 0 )) \
    && pass "5: stop on an orphan exits non-zero" \
    || fail "5: stop exited 0 on an orphan"
[[ -f "$ROOT/monitor/.state/services/svcA.pid" ]] \
    && pass "5: stop PRESERVED the pid record" \
    || fail "5: stop deleted the pid record"
grep -q 'REFUSING to drop the pid record' "$ROOT/err" \
    && pass "5: stop explains the refusal" \
    || fail "5: no refusal message: $(cat "$ROOT/err")"
grep -q 'removed stale pidfile' "$ROOT/err" \
    && fail "5: still claims it removed the pidfile" \
    || pass "5: no misleading 'removed stale pidfile' claim"
cleanup_case

# Case 5n — NEGATIVE CONTROL: stale record + DOWN service → cleaned, exit 0.
build_case stop-consistent
WRAP="$ROOT/wd/serve-supervised.sh"
make_wrapper "$WRAP" "$ROOT/marker"
reg_line5 svcA "$ROOT/wd" "$WRAP" "test -f $HEALTH_FLAG" "$ROOT/wd/a.log" > "$REG"
write_record svcA 999999 "$(readlink /proc/$$/ns/pid)" '1'
run_svc stop svcA          # HEALTH_FLAG absent ⇒ unhealthy
(( RC == 0 )) \
    && pass "5n: control — stale record + failing healthcheck exits 0" \
    || fail "5n: expected rc 0, got $RC: $(cat "$ROOT/err")"
[[ ! -f "$ROOT/monitor/.state/services/svcA.pid" ]] \
    && pass "5n: control — consistent litter IS removed" \
    || fail "5n: stale record kept although the service is down"
cleanup_case

# Case 6 — `restart` genuinely bounces a locatable orphan. The healthcheck
# tracks the DAEMON here, so "reconciled" cannot be faked by a static flag.
build_case restart-locatable
WRAP="$ROOT/wd/serve-supervised.sh"
PIDMARK="$ROOT/wd/pidmark"
make_wrapper "$WRAP" "$ROOT/marker" "$PIDMARK"
reg_line5 svcA "$ROOT/wd" "$WRAP" "$(health_tracks_daemon "$PIDMARK")" "$ROOT/wd/a.log" > "$REG"
ORPHAN=$(start_sleeper "$WRAP")
# Record a DEAD pid: the supervisor is gone, the daemon keeps serving.
write_record svcA 999999 "$(readlink /proc/$$/ns/pid)" '1'
run_svc restart svcA
(( RC == 0 )) \
    && pass "6: restart on a locatable orphan exits 0" \
    || fail "6: restart rc=$RC: $(cat "$ROOT/err")"
kill -0 "$ORPHAN" 2>/dev/null \
    && fail "6: the orphaned daemon was NOT bounced (pid $ORPHAN still alive)" \
    || pass "6: the orphaned daemon was really bounced"
NEWPID=''
[[ -f "$ROOT/monitor/.state/services/svcA.pid" ]] && read -r NEWPID < "$ROOT/monitor/.state/services/svcA.pid"
if [[ "$NEWPID" =~ ^[0-9]+$ ]] && kill -0 "$NEWPID" 2>/dev/null && [[ "$NEWPID" != 999999 ]]; then
    pass "6: a fresh record naming a LIVE supervisor was written"
else
    pass_ns=$(grep -c '^ns=' "$ROOT/monitor/.state/services/svcA.pid" 2>/dev/null) || pass_ns=0
    fail "6: no valid fresh record (pid=[$NEWPID] ns-lines=$pass_ns)"
fi
grep -q '^ns=' "$ROOT/monitor/.state/services/svcA.pid" 2>/dev/null \
    && pass "6: the fresh record carries namespace identity" \
    || fail "6: fresh record lacks ns= identity"
cleanup_case

# Case 7 — `restart` cannot locate the daemon: fail loudly, keep evidence.
# The healthcheck passes but NOTHING runs the wrapper, so discovery is empty
# (the live nexus-remote-ssh case: the listener lived in another namespace).
build_case restart-unlocatable
WRAP="$ROOT/wd/serve-supervised.sh"
make_wrapper "$WRAP" "$ROOT/marker"
touch "$HEALTH_FLAG"
reg_line5 svcA "$ROOT/wd" "$WRAP" "test -f $HEALTH_FLAG" "$ROOT/wd/a.log" > "$REG"
write_record svcA 999999 "$(readlink /proc/$$/ns/pid)" '1'
run_svc restart svcA
(( RC != 0 )) \
    && pass "7: restart exits NON-ZERO when the daemon is unresolvable" \
    || fail "7: restart exited 0 without reconciling"
grep -q 'CANNOT RECONCILE' "$ROOT/err" \
    && pass "7: prints CANNOT RECONCILE with a reason" \
    || fail "7: no CANNOT RECONCILE: $(cat "$ROOT/err")"
[[ -f "$ROOT/monitor/.state/services/svcA.pid" ]] \
    && pass "7: pid record PRESERVED as evidence" \
    || fail "7: pid record destroyed on a failed reconcile"
grep -qE '^\[svc\] svcA: healthy$' "$ROOT/err" \
    && fail "7: still reports a bare 'healthy' verdict" \
    || pass "7: never reports 'healthy' for an unreconciled orphan"
# The self-referential advice loop is gone: a FAILING restart must not tell
# the operator to run restart.
grep -q "svc.sh restart svcA" "$ROOT/err" \
    && fail "7: advice loop — a failed restart still points at restart" \
    || pass "7: no self-referential 'run restart' advice"
cleanup_case

# Case 8 — the daemon we found dies, yet the endpoint still answers: a
# DIFFERENT process serves it. Conflating that with success is the whole bug.
build_case restart-foreign-listener
WRAP="$ROOT/wd/serve-supervised.sh"
make_wrapper "$WRAP" "$ROOT/marker"
touch "$HEALTH_FLAG"     # never cleared ⇒ health passes even after the kill
reg_line5 svcA "$ROOT/wd" "$WRAP" "test -f $HEALTH_FLAG" "$ROOT/wd/a.log" > "$REG"
ORPHAN=$(start_sleeper "$WRAP")
write_record svcA 999999 "$(readlink /proc/$$/ns/pid)" '1'
run_svc restart svcA
(( RC != 0 )) \
    && pass "8: restart exits non-zero when health survives the bounce" \
    || fail "8: reported success though a foreign listener still serves"
grep -q 'DIFFERENT process is serving' "$ROOT/err" \
    && pass "8: names the foreign-listener diagnosis" \
    || fail "8: no foreign-listener diagnosis: $(cat "$ROOT/err")"
cleanup_case

# Case 10 — BLAST-RADIUS REGRESSION. Discovery must not match a process
# running a DIFFERENT service that merely shares the wrapper BASENAME. An
# earlier draft of this fix matched on basename alone and TERMed four live
# production supervisors that share `serve-supervised.sh`; this case is that
# outage, frozen. The orphan's own daemon is absent, so a correct predicate
# finds nothing and the sibling must be left untouched.
build_case discovery-scope
mkdir -p "$ROOT/other"
WRAP="$ROOT/wd/serve-supervised.sh"
OTHER_WRAP="$ROOT/other/serve-supervised.sh"     # SAME basename, other row
make_wrapper "$WRAP" "$ROOT/marker"
make_wrapper "$OTHER_WRAP" "$ROOT/marker-other"
touch "$HEALTH_FLAG"
reg_line5 svcA "$ROOT/wd" "$WRAP" "test -f $HEALTH_FLAG" "$ROOT/wd/a.log" > "$REG"
SIBLING=$(start_sleeper "$OTHER_WRAP" "$ROOT/other")
write_record svcA 999999 "$(readlink /proc/$$/ns/pid)" '1'
run_svc restart svcA
kill -0 "$SIBLING" 2>/dev/null \
    && pass "10: a same-basename daemon in ANOTHER workdir was NOT killed" \
    || fail "10: killed an unrelated service sharing the wrapper basename (pid $SIBLING)"
(( RC != 0 )) \
    && pass "10: restart still fails loudly rather than killing a bystander" \
    || fail "10: restart claimed success after matching nothing of its own"
grep -q 'CANNOT RECONCILE' "$ROOT/err" \
    && pass "10: reports CANNOT RECONCILE instead of a wrong-target bounce" \
    || fail "10: no CANNOT RECONCILE: $(cat "$ROOT/err")"
cleanup_case

# Case 11 — AMBIGUOUS discovery kills nothing. Two live processes match the
# same launch token AND the same workdir, so the predicate has not
# identified the supervisor. "Kill them all" is how a bounce becomes an
# outage; the guard must refuse, having signalled nothing.
build_case discovery-ambiguous
WRAP="$ROOT/wd/serve-supervised.sh"
make_wrapper "$WRAP" "$ROOT/marker"
touch "$HEALTH_FLAG"
reg_line5 svcA "$ROOT/wd" "$WRAP" "test -f $HEALTH_FLAG" "$ROOT/wd/a.log" > "$REG"
TWIN1=$(start_sleeper "$WRAP")
TWIN2=$(start_sleeper "$WRAP")
write_record svcA 999999 "$(readlink /proc/$$/ns/pid)" '1'
run_svc restart svcA
(( RC != 0 )) \
    && pass "11: ambiguous discovery exits non-zero" \
    || fail "11: reported success on ambiguous discovery"
grep -q 'AMBIGUOUS' "$ROOT/err" \
    && pass "11: names the ambiguity" \
    || fail "11: no ambiguity diagnosis: $(cat "$ROOT/err")"
if kill -0 "$TWIN1" 2>/dev/null && kill -0 "$TWIN2" 2>/dev/null; then
    pass "11: NOTHING was signalled — both candidates still alive"
else
    fail "11: killed a candidate despite ambiguous discovery"
fi
cleanup_case

# Case 9 — `start` on an orphan must not report success.
build_case start-orphan
WRAP="$ROOT/wd/serve-supervised.sh"
make_wrapper "$WRAP" "$ROOT/marker"
touch "$HEALTH_FLAG"
reg_line5 svcA "$ROOT/wd" "$WRAP" "test -f $HEALTH_FLAG" "$ROOT/wd/a.log" > "$REG"
write_record svcA 999999 "$(readlink /proc/$$/ns/pid)" '1'
run_svc start svcA
(( RC != 0 )) \
    && pass "9: start on an orphan exits non-zero" \
    || fail "9: start reported success on an orphan"
grep -q 'healthy-unsupervised' "$ROOT/err" \
    && pass "9: start names the unsupervised state" \
    || fail "9: start did not name the state: $(cat "$ROOT/err")"
cleanup_case

# ---------------------------------------------------------------------------
# LEAK CHECK — the property, not the reap's return code
# (your-org/nexus-code#860).
#
# THIS IS THE ASSERTION THE OLD SUITE COULD NOT MAKE. Its reap was a silent
# no-op — `th_kill_own_child` refusing every reparented pid — and a reap that
# does nothing returns success exactly as happily as one that worked. So the
# only honest check is on the WORLD: are the supervised processes actually
# gone? Measured on `a74805b`, this run left THREE `serve-supervised.sh`
# processes alive per invocation, each holding a deleted working directory,
# while the suite printed ALL TESTS PASSED.
#
# Ownership is established from each candidate's OWN /proc entry against this
# run's unique mktemp roots — never by basename (`serve-supervised.sh` is worn
# by a class, and a read-only `pgrep` on it once matched four live production
# services, `#608`), never by ppid (reparenting destroys it), never by age (a
# real supervisor is SUPPOSED to be old).
#
# ONE /proc pass for ALL roots, not one per root. The per-pid form costs a
# fork per process per witness — 10 s per pass on this host — and there are
# eleven roots, which would add ~110 s to a ~60 s suite.
leak_survivors=''
if [[ -s "$ROOT_LEDGER" ]]; then
    _roots=()
    while read -r _r; do
        [[ -n "$_r" && "$_r" == /* && "$_r" != "/" ]] && _roots+=( "$_r" )
    done < "$ROOT_LEDGER"
    while IFS= read -r _line; do
        [[ "$_line" =~ /proc/([0-9]+)/cwd\ -\>\ (.*)$ ]] || continue
        _p="${BASH_REMATCH[1]}"
        _cw="${BASH_REMATCH[2]}"
        _cw="${_cw% (deleted)}"
        (( _p == $$ )) && continue
        for _r in "${_roots[@]}"; do
            if [[ "$_cw" == "$_r" || "$_cw" == "$_r"/* ]]; then
                leak_survivors+="  pid $_p cwd=$_cw"$'\n'
                break
            fi
        done
    done < <(ls -l /proc/[0-9]*/cwd 2>/dev/null)
fi
rm -f "$ROOT_LEDGER"
if [[ -z "$leak_survivors" ]]; then
    pass "LEAK: no supervised process outlived this run"
else
    fail "LEAK: processes survived the suite (your-org/nexus-code#860):"$'\n'"$leak_survivors"
fi

# --- summary ---------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
if (( FAIL == 0 )); then
    echo 'ALL TESTS PASSED'
    exit 0
else
    echo 'TESTS FAILED'
    exit 1
fi
