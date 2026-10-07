#!/usr/bin/env bash
# Unit tests for monitor/watcher/verify-stack.sh — the bootstrap-finish
# convergence check (your-org/nexus-code#313 item 4).
#
# The install (and `./watcher`) must END by starting the watcher AND
# observing the whole stack is running before declaring success, instead
# of stopping at "svc.sh up returned". verify-stack.sh polls the three
# components — watcher heartbeat fresh, orchestrator tmux window present,
# registry services healthy — and exits 0 only when all converge.
#
# Hermetic: the watcher heartbeat is a fixture file (freshness set via
# mtime), services are registry rows whose healthcheck is `test -f
# <marker>`, and tmux is a PATH-shadow stub whose `list-windows` prints a
# controlled window list. No real watcher, services, or tmux server.
#
# Run: bash monitor/watcher/test-verify-stack.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

VERIFY="$_test_dir/verify-stack.sh"

WORK=$(mktemp -d -t nexus-verify-stack-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/state" "$WORK/stub-bin"

# tmux stub: `list-windows -F …` prints the names in $WORK/windows (one
# per line); every other tmux call is a harmless no-op success. This lets
# _recover_window_exists resolve against a controlled window set with no
# tmux server.
cat > "$WORK/stub-bin/tmux" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
    if [[ "\$a" == "list-windows" ]]; then
        cat "$WORK/windows" 2>/dev/null
        exit 0
    fi
done
exit 0
SH
chmod +x "$WORK/stub-bin/tmux"

# Fresh, pid-less heartbeat: with no `pid=` field, _watcher_alive skips
# the live-watcher cmdline check and decides purely on mtime age.
HB="$WORK/state/watcher-heartbeat"
fresh_watcher() { printf 'ts=now\ntarget=orchestrator\n' > "$HB"; touch "$HB"; }
stale_watcher() { printf 'ts=old\ntarget=orchestrator\n' > "$HB"; touch -d '2 hours ago' "$HB"; }

orch_present() { printf 'services\norchestrator\n' > "$WORK/windows"; }
orch_absent()  { printf 'services\n'              > "$WORK/windows"; }

# Registry helpers. healthcheck = `test -f $WORK/svc-ok`; toggle the
# marker to make the single service healthy / unhealthy.
write_registry() {  # $1 = number of service rows (0 or 1)
    : > "$WORK/services.registry"
    if (( $1 >= 1 )); then
        printf 'demo\t%s\t%s\ttest -f %s/svc-ok\t%s/demo.log\n' \
            "$WORK" "$WORK/launch.sh" "$WORK" "$WORK" >> "$WORK/services.registry"
    fi
}
svc_healthy()   { : > "$WORK/svc-ok"; }
svc_unhealthy() { rm -f "$WORK/svc-ok"; }

run_verify() {  # extra args forwarded; short timeout so failures are fast
    PATH="$WORK/stub-bin:$PATH" \
    NEXUS_STATE_DIR="$WORK/state" \
    NEXUS_SERVICES_REGISTRY="$WORK/services.registry" \
    RECOVER_TARGET_WINDOW=orchestrator \
        bash "$VERIFY" --timeout 1 --poll 1 "$@" 2>&1
}

# --- Case 1: all three converged ⇒ rc 0 --------------------------------

echo '=== Case 1: watcher fresh + orchestrator up + service healthy ⇒ rc 0 ==='
fresh_watcher; orch_present; write_registry 1; svc_healthy
out=$(run_verify); rc=$?
assert_eq "rc 0 (converged)" "$rc" "0"
assert_contains "reports convergence" "$out" "converged"

# --- Case 2: watcher stale ⇒ rc 1 --------------------------------------

echo '=== Case 2: stale watcher heartbeat ⇒ rc 1 ==='
stale_watcher; orch_present; write_registry 1; svc_healthy
out=$(run_verify); rc=$?
assert_eq "rc 1 (watcher down)" "$rc" "1"
assert_contains "names the watcher as down" "$out" "watcher"

# --- Case 3: orchestrator window absent ⇒ rc 1 -------------------------

echo '=== Case 3: orchestrator window missing ⇒ rc 1 ==='
fresh_watcher; orch_absent; write_registry 1; svc_healthy
out=$(run_verify); rc=$?
assert_eq "rc 1 (orchestrator absent)" "$rc" "1"
assert_contains "names the orchestrator as down" "$out" "orchestrator"

# --- Case 4: a service unhealthy ⇒ rc 1 --------------------------------

echo '=== Case 4: registry service unhealthy ⇒ rc 1 ==='
fresh_watcher; orch_present; write_registry 1; svc_unhealthy
out=$(run_verify); rc=$?
assert_eq "rc 1 (service down)" "$rc" "1"
assert_contains "names the unhealthy service" "$out" "demo"

# --- Case 5: --no-orchestrator skips the window check ⇒ rc 0 -----------

echo '=== Case 5: --no-orchestrator ignores a missing window ⇒ rc 0 ==='
fresh_watcher; orch_absent; write_registry 1; svc_healthy
out=$(run_verify --no-orchestrator); rc=$?
assert_eq "rc 0 (orchestrator check skipped)" "$rc" "0"

# --- Case 6: empty registry is trivially satisfied ⇒ rc 0 --------------

echo '=== Case 6: no registry services + watcher + orchestrator ⇒ rc 0 ==='
fresh_watcher; orch_present; write_registry 0
out=$(run_verify); rc=$?
assert_eq "rc 0 (watcher-only deployment converges)" "$rc" "0"

# --- Case 7-13: the timeout is WALL CLOCK (your-org/nexus-code#1675) ------
#
# The deadline used to count only the `sleep "$POLL"` between rounds. With a
# healthcheck that takes 5 s, `--timeout 6 --poll 1` ran ~7 rounds (~6 s each)
# plus one more full round in the summary.
#
# Bounds are measured from OUTSIDE the script, so they hold its own claim to
# account rather than trusting its self-report. The setup that precedes the
# budget (sourcing + config reads) is NOT a fixed cost — it was measured from
# 2 s to 12 s across load 100-127 — so a fixed allowance for it is a guess
# that a loaded host defeats. Each timed case instead CALIBRATES first: it
# measures `--timeout 0` over an EMPTY registry (setup + one trivial round)
# under the same load, and asserts
#     elapsed <= BASE + <the header's stated bound for this case> + 4 s slack.
calibrate() {  # sets VS_BASE
    local t0=$SECONDS saved="$WORK/services.registry.cal"
    cp "$WORK/services.registry" "$saved" 2>/dev/null || : >"$saved"
    : > "$WORK/services.registry"
    run_verify --timeout 0 >/dev/null
    VS_BASE=$(( SECONDS - t0 ))
    mv "$saved" "$WORK/services.registry"
    echo "    calibration: setup + one empty round = ${VS_BASE}s"
}

# write_registry_rows <row>... — each row is "name<TAB>health"; workdir $WORK.
write_registry_rows() {
    : > "$WORK/services.registry"
    local r
    for r in "$@"; do
        printf '%s\t%s\t%s\t%s\t%s/%s.log\n' "${r%%$'\t'*}" "$WORK" "$WORK/launch.sh" \
            "${r#*$'\t'}" "$WORK" "${r%%$'\t'*}" >> "$WORK/services.registry"
    done
}

timed_verify() {  # sets T_RC, T_OUT, T_ELAPSED
    local t0=$SECONDS
    T_OUT=$(run_verify "$@"); T_RC=$?
    T_ELAPSED=$(( SECONDS - t0 ))
}

echo '=== Case 7: a 5 s healthcheck under --timeout 6 --poll 1 returns within the bound ==='
fresh_watcher; orch_present
write_registry_rows $'slow\tsleep 5; false'
calibrate
timed_verify --timeout 6 --poll 1
# Stated bound: max(first round, TIMEOUT + 3) = max(~5, 9) = 9 s of probing.
echo "    elapsed=${T_ELAPSED}s rc=$T_RC bound=$(( VS_BASE + 9 + 4 ))s"
assert_eq "rc 1 (slow service still down)" "$T_RC" "1"
assert_contains "names the slow service" "$T_OUT" "slow"
assert_eq "wall-clock bound: elapsed <= BASE + TIMEOUT + 3 + slack" "$(( T_ELAPSED <= VS_BASE + 9 + 4 ))" 1

echo '=== Case 8: a HANGING healthcheck is capped and its process group reaped ==='
leak_tag="vsleak-$$-$RANDOM"
fresh_watcher; orch_present
write_registry_rows $'hang\texec -a '"$leak_tag"' sleep 600'
calibrate
timed_verify --timeout 6 --poll 1 --check-timeout 8
# The first round's hang is capped at --check-timeout (8) + kill grace (2); the
# deadline (6) has passed by then, so no second round starts. Stated bound:
# max(first round = 10, TIMEOUT + 3 = 9) = 10 s of probing — against 600.
echo "    elapsed=${T_ELAPSED}s rc=$T_RC bound=$(( VS_BASE + 10 + 4 ))s"
assert_eq "rc 1 (hung service down)" "$T_RC" "1"
assert_contains "says the healthcheck timed out" "$T_OUT" "timed out"
assert_eq "hang capped at --check-timeout, never waited out" "$(( T_ELAPSED <= VS_BASE + 10 + 4 ))" 1
# Identity by argv[0] EQUALITY to a per-run random tag, which only this suite's
# own `exec -a` can produce — never a substring, never the rest of the argv
# (a sibling's cmdline may be its whole prompt).
leaked=0
for d in /proc/[0-9]*; do
    a0=$( { tr '\0' '\n' < "$d/cmdline" | sed -n 1p; } 2>/dev/null )
    [[ "$a0" == "$leak_tag" ]] && { leaked=1; kill "${d#/proc/}" 2>/dev/null; }
done
assert_eq "no healthcheck process outlives the run" "$leaked" "0"

echo '=== Case 8b: a hang in a LATER round is capped by the DEADLINE, not --check-timeout ==='
# Round 1 answers at once (and drops a marker); every later round hangs. With
# --check-timeout 60 only the deadline can stop round 2. Stated bound:
# max(first round ~0, TIMEOUT + 3 = 9) = 9 s of probing — against 60.
leak_tag2="vsleak2-$$-$RANDOM"
rm -f "$WORK/second-round"
fresh_watcher; orch_present
write_registry_rows $'late\tif [ -e '"$WORK"'/second-round ]; then exec -a '"$leak_tag2"' sleep 600; else : > '"$WORK"'/second-round; false; fi'
calibrate
timed_verify --timeout 6 --poll 1 --check-timeout 60
echo "    elapsed=${T_ELAPSED}s rc=$T_RC bound=$(( VS_BASE + 9 + 4 ))s"
assert_eq "fixture precondition: a second round reached the hanging arm" "$([[ -e "$WORK/second-round" ]] && echo yes)" "yes"
assert_eq "rc 1 (late-hanging service down)" "$T_RC" "1"
assert_eq "later-round hang capped by the deadline" "$(( T_ELAPSED <= VS_BASE + 9 + 4 ))" 1
leaked=0
for d in /proc/[0-9]*; do
    a0=$( { tr '\0' '\n' < "$d/cmdline" | sed -n 1p; } 2>/dev/null )
    [[ "$a0" == "$leak_tag2" ]] && { leaked=1; kill "${d#/proc/}" 2>/dev/null; }
done
assert_eq "no later-round healthcheck process outlives the run" "$leaked" "0"

echo '=== Case 9: the health string never reaches argv (#891 false-healthy) ==='
marker="vsmark$$x$RANDOM"
fresh_watcher; orch_present
write_registry_rows $'pg\tpgrep -f '"$marker"' >/dev/null'
timed_verify --timeout 1 --poll 1
assert_eq "rc 1 (nothing matching the marker runs)" "$T_RC" "1"
assert_contains "names the pgrep service" "$T_OUT" "pg"

# --- labsh cold build: BUILDING, never healthy -----------------------------
# Fixture per test-labsh-reap-stale-builds.sh: a copied `bash` named `uv`
# (exe basename is what the shared predicate checks), cwd = the service's
# workdir, argv naming jupyter-lab, pid recorded in .jupyter/labsh.bg.pid.
# The `while` loop keeps exe = uv (a lone simple command would be exec'd),
# and ties the decoy's life to this suite's pid with a 300 s ceiling. Its pid
# comes from `$!` — never from a process search.
BWD="$WORK/labsvc"; mkdir -p "$BWD/.jupyter"
cp "$(command -v bash)" "$WORK/uv"
( cd "$BWD" && exec "$WORK/uv" -c "while kill -0 $$ 2>/dev/null && (( \$SECONDS < 300 )); do sleep 1; done; true" jupyter-lab --port 9 ) >/dev/null 2>&1 &
BPID=$!
trap 'kill "$BPID" 2>/dev/null; rm -rf "$WORK"' EXIT
printf '%s\n' "$BPID" > "$BWD/.jupyter/labsh.bg.pid"
: > "$BWD/.jupyter/labsh.bg.log"
sleep 1
assert_eq "fixture precondition: the decoy's exe is 'uv'" "$(basename "$(readlink "/proc/$BPID/exe" 2>/dev/null)")" "uv"
# The jlab row is a LABSH row by the watcher's own `_sh_is_labsh_service`
# (its launch names labsh-supervised.sh; verify-stack never executes it).
write_build_registry() {  # extra rows appended after the labsh row
    printf 'jlab\t%s\t%s\tfalse\t%s/j.log\n' "$BWD" "$WORK/labsh-supervised.sh" "$WORK" > "$WORK/services.registry"
    local r
    for r in "$@"; do
        printf '%s\t%s\t%s\t%s\n' "${r%%$'\t'*}" "$WORK" "$WORK/launch.sh" "${r#*$'\t'}" >> "$WORK/services.registry"
    done
}

echo '=== Case 10: a labsh cold build in flight ⇒ rc 3 BUILDING, never healthy ==='
fresh_watcher; orch_present; write_build_registry
timed_verify --timeout 40 --poll 1
echo "    elapsed=${T_ELAPSED}s rc=$T_RC"
assert_eq "rc 3 (converged except BUILDING)" "$T_RC" "3"
assert_contains "says BUILDING" "$T_OUT" "BUILDING"
assert_contains "names the building service" "$T_OUT" "jlab"
assert_not_contains "never claims services healthy" "$T_OUT" "services healthy"
assert_not_contains "never claims convergence" "$T_OUT" "stack converged"
assert_eq "returned at the first round, not at the 40 s deadline" "$(( T_ELAPSED < 25 ))" 1

echo '=== Case 11: building + ANOTHER service down ⇒ rc 1, both named ==='
fresh_watcher; orch_present; write_build_registry $'broken\tfalse'
timed_verify --timeout 8 --poll 1
assert_eq "rc 1 (a real failure outranks BUILDING)" "$T_RC" "1"
assert_contains "names the broken service" "$T_OUT" "broken"
assert_contains "still lists the build as BUILDING" "$T_OUT" "BUILDING"

echo '=== Case 11b (#1743): a round CUT by the deadline keeps the last observed verdicts ==='
# The CI failure, made deterministic. On a stalled runner a round started just
# before the deadline reached every row after it and SKIPPED them, and the
# summary printed "not checked" for rows round 1 had really seen (jlab BUILDING,
# broken DOWN). Here a row placed BEFORE jlab answers at once in round 1 and
# hangs in every later round (Case 8b's marker), so round 2 is always cut
# mid-round with jlab still unvisited — independent of host speed.
leak_tag3="vsleak3-$$-$RANDOM"
rm -f "$WORK/third-round"
fresh_watcher; orch_present
printf 'late\t%s\t%s\t%s\n' "$WORK" "$WORK/launch.sh" \
    'if [ -e '"$WORK"'/third-round ]; then exec -a '"$leak_tag3"' sleep 600; else : > '"$WORK"'/third-round; false; fi' \
    > "$WORK/services.registry"
printf 'jlab\t%s\t%s\tfalse\t%s/j.log\n' "$BWD" "$WORK/labsh-supervised.sh" "$WORK" >> "$WORK/services.registry"
timed_verify --timeout 4 --poll 1 --check-timeout 60
assert_eq "fixture precondition: a second round reached the hanging row" "$([[ -e "$WORK/third-round" ]] && echo yes)" "yes"
assert_contains "fixture precondition: jlab was NOT re-checked in the cut round" "$T_OUT" "not re-checked"
assert_eq "rc 1 (the late row is down)" "$T_RC" "1"
assert_contains "names the late row" "$T_OUT" "late"
assert_contains "still lists the build as BUILDING from its last observation" "$T_OUT" "BUILDING"
assert_not_contains "never reports jlab as merely 'not checked'" "$T_OUT" "jlab (not checked"
assert_not_contains "a cut round never certifies convergence" "$T_OUT" "stack converged"
for d in /proc/[0-9]*; do
    a0=$( { tr '\0' '\n' < "$d/cmdline" | sed -n 1p; } 2>/dev/null )
    [[ "$a0" == "$leak_tag3" ]] && kill "${d#/proc/}" 2>/dev/null
done

echo '=== Case 12: build already BOUND a URL ⇒ not building ⇒ rc 1 (predicate fails closed) ==='
echo 'Jupyter Server is running at: http://127.0.0.1:9/lab' > "$BWD/.jupyter/labsh.bg.log"
fresh_watcher; orch_present; write_build_registry
timed_verify --timeout 2 --poll 1
assert_eq "rc 1 (bound-but-unhealthy is DOWN)" "$T_RC" "1"
assert_not_contains "not reported as BUILDING" "$T_OUT" "BUILDING"
: > "$BWD/.jupyter/labsh.bg.log"

echo '=== Case 13: cold-build ceiling 0 disables the classification ⇒ rc 1 ==='
fresh_watcher; orch_present; write_build_registry
T_OUT=$(MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=0 run_verify --timeout 2 --poll 1); T_RC=$?
assert_eq "rc 1 (ceiling 0 ⇒ build blocks)" "$T_RC" "1"
assert_not_contains "not reported as BUILDING" "$T_OUT" "BUILDING"
echo '=== Case 14: a NON-labsh row sharing the build workdir is DOWN, never BUILDING ==='
# The production shape (skeptic verdict on #1679): nexus-remote-ssh and
# tmpfs-guard run in $NEXUS_ROOT, which also holds the live labsh .jupyter.
# The build predicate keys on the WORKDIR, so without a row gate a DOWN guard
# row read BUILDING at rc 3 — "every other service healthy", falsely.
printf 'guard\t%s\t%s\tfalse\t%s/g.log\n' "$BWD" "$WORK/tmpfs-guard.sh" "$WORK" > "$WORK/services.registry"
fresh_watcher; orch_present
timed_verify --timeout 3 --poll 1
assert_eq "rc 1 (a non-labsh DOWN row is a failure)" "$T_RC" "1"
assert_contains "names the guard row" "$T_OUT" "guard"
assert_not_contains "never reported as BUILDING" "$T_OUT" "BUILDING"
assert_not_contains "never claims every other service healthy" "$T_OUT" "every other service healthy"
kill "$BPID" 2>/dev/null

# --- your-org/nexus-code#1690: BUILDING is the SHARED verdict, not an age test --
# Past the soft ceiling the watcher, svc.sh and the supervisor all decide via
# `labsh_build_release`: PROTECTED while the build PROGRESSES, released once it
# stalls for LABSH_BUILD_STALL_SECONDS or passes LABSH_COLD_BUILD_HARD_CAP.
# verify-stack used to test `age < ceiling` and call a progressing build DOWN.
# Build bodies are test-service-health.sh's BUILD_BODY_PROGRESSING (one byte
# per 0.2 s, so /proc/<pid>/io wchar GROWS) and BUILD_BODY_STALLED (bash blocks
# in wait(): no CPU, no bytes). Small knobs: ceiling 1 s, stall window 2 s.
# A first sight is never "stalled" (no baseline), so every case samples TWICE,
# more than the stall window apart; the second answer is the one asserted.
PWD2="$WORK/labsvc2"; mkdir -p "$PWD2/.jupyter"
BUILD_BODY_PROGRESSING="while kill -0 $$ 2>/dev/null && (( \$SECONDS < 300 )); do printf x >> '$PWD2/.prog'; sleep 0.2; done; true"
BUILD_BODY_STALLED='sleep 300; :'
PPID2=""
start_build2() {  # $1 = body; pid from $! only, never a process search
    : > "$PWD2/.jupyter/labsh.bg.log"
    rm -f "$PWD2/.jupyter/labsh.buildprogress"
    ( cd "$PWD2" && exec "$WORK/uv" -c "$1" jupyter-lab --port 9 ) >/dev/null 2>&1 &
    PPID2=$!
    printf '%s\n' "$PPID2" > "$PWD2/.jupyter/labsh.bg.pid"
    sleep 1.5          # age >= the 1 s ceiling, and bash's startup ticks settle
}
stop_build2() { [[ -n "$PPID2" ]] && { kill "$PPID2" 2>/dev/null; wait "$PPID2" 2>/dev/null; }; PPID2=""; }
trap 'stop_build2; kill "$BPID" 2>/dev/null; rm -rf "$WORK"' EXIT
write_build_registry2() {
    printf 'jlab2\t%s\t%s\tfalse\t%s/j2.log\n' "$PWD2" "$WORK/labsh-supervised.sh" "$WORK" > "$WORK/services.registry"
}
verify_build2() {  # two samples > the stall window apart; sets T_RC/T_OUT from the SECOND
    timed_verify --timeout 3 --poll 1 >/dev/null
    sleep 3
    timed_verify --timeout 3 --poll 1
}
export MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=1 LABSH_BUILD_STALL_SECONDS=2

echo '=== Case 15 (#1690): a PROGRESSING build past the ceiling ⇒ rc 3 BUILDING ==='
fresh_watcher; orch_present; write_build_registry2
start_build2 "$BUILD_BODY_PROGRESSING"
assert_eq "fixture precondition: the build's exe is 'uv'" "$(basename "$(readlink "/proc/$PPID2/exe" 2>/dev/null)")" "uv"
verify_build2
echo "    rc=$T_RC"
assert_eq "rc 3 (progressing past the ceiling is still BUILDING)" "$T_RC" "3"
assert_contains "names the progressing build as BUILDING" "$T_OUT" "jlab2 (labsh cold build pid $PPID2"
assert_contains "says WHY: the shared verdict's token" "$T_OUT" "progressing)"
assert_eq "the shared verdict was consulted (its progress sample exists)" "$([[ -s "$PWD2/.jupyter/labsh.buildprogress" ]] && echo yes)" "yes"
stop_build2

echo '=== Case 16 (#1690, negative): a STALLED build past the ceiling ⇒ rc 1, NOT BUILDING ==='
fresh_watcher; orch_present; write_build_registry2
start_build2 "$BUILD_BODY_STALLED"
assert_eq "fixture precondition: the build's exe is 'uv'" "$(basename "$(readlink "/proc/$PPID2/exe" 2>/dev/null)")" "uv"
verify_build2
echo "    rc=$T_RC"
assert_eq "rc 1 (a stalled build is blocking)" "$T_RC" "1"
assert_contains "names the stalled service as down" "$T_OUT" "jlab2"
assert_not_contains "not reported as BUILDING" "$T_OUT" "BUILDING"
stop_build2

echo '=== Case 17 (#1690): a progressing build past the HARD CAP ⇒ rc 1, NOT BUILDING ==='
fresh_watcher; orch_present; write_build_registry2
start_build2 "$BUILD_BODY_PROGRESSING"
T_OUT=$(LABSH_COLD_BUILD_HARD_CAP=1 run_verify --timeout 3 --poll 1); T_RC=$?
assert_eq "rc 1 (past the hard cap is blocking even while moving)" "$T_RC" "1"
assert_not_contains "not reported as BUILDING" "$T_OUT" "BUILDING"
stop_build2
unset MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS LABSH_BUILD_STALL_SECONDS

th_summary_and_exit
