#!/usr/bin/env bash
# Unit + fixture-tick tests for the continuous service-health watch
# (`monitor/watcher/_service_health.sh` + the `ng service-incident`
# generator, service-health-watch).
#
# Everything runs against a throwaway fixture tree under mktemp — the live
# watcher, live state dir, live registry, and live services are never
# touched. svc.sh (the restart surface) is a CAPTURE STUB that records its
# invocations and, when a flag file says so, simulates a successful
# restart by making the fixture service healthy again. The healthcheck is
# a flag-file probe (`test -f <ok>`) so a test flips health by touch/rm.
#
# Properties pinned down:
#   detection    healthy ⇒ no incident, no emit; unhealthy ⇒ incident
#                opened keyed on the REGISTRY healthcheck (not tmux).
#   grace        a freshly-unhealthy service is FIRST given a self-heal
#                grace window — NO restart on the first detection. A
#                service that recovers within grace (its supervisor healed
#                it) is NEVER restarted by the watcher — breadcrumb only.
#   restart      still unhealthy AFTER grace (policy auto-restart) ⇒
#                `svc.sh restart <name>` issued, recorded with outcome.
#   policy       `emit-only` ⇒ watcher NEVER auto-restarts; after grace it
#                escalates to the orchestrator instead.
#   recovery     a restart that holds ⇒ `recovered` breadcrumb surfaced
#                ONCE, then the incident is closed (state file removed).
#   flap ceiling N attempts within one incident ⇒ stop thrashing, escalate
#                `flapping`; no further restart calls.
#   emit         re-nag guarded (identical status:attempts suppressed);
#                ALWAYS reports the policy + full current state (grace /
#                restart attempt + outcome / escalation).
#   generator    `ng service-incident` emits all five required sections
#                from the recorded state + the verbatim event timeline,
#                including the restart policy.
#
# Run: bash monitor/watcher/test-service-health.sh

set -uo pipefail

_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_real_monitor=$(cd "$_real_dir/.." && pwd)

# shellcheck source=_test_helpers.sh
. "$_real_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-service-health-XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---- fixture tree ---------------------------------------------------------
ROOT="$WORK/nexus"
STATE="$ROOT/monitor/.state"
SHDIR="$STATE/service-health"
WD="$WORK/wd"                       # the fake service's workdir
mkdir -p "$STATE" "$SHDIR" "$WD" "$ROOT/monitor"

# Health flag: present ⇒ healthy. The healthcheck runs in $WD.
OKFLAG="$WD/ok"
# When this exists, the svc stub "fixes" the service (touches the flag) —
# i.e. the restart holds. Absent ⇒ the restart does NOT recover it.
FIXFLAG="$WORK/restart-fixes"
SVC_CALLS="$WORK/svc-calls.log"
SVC_FORCE_CALLS="$WORK/svc-force-calls.log"
: > "$SVC_CALLS"

# Capture stub for svc.sh: log the verb+name, optionally fix the service.
SVC_STUB="$WORK/svc-stub.sh"
cat > "$SVC_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SVC_CALLS"
# Record the cold-build-guard override we were (or were not) handed. svc.sh's
# guard counts a build's age from the BUILD PROCESS; this module counts from
# FIRST_UNHEALTHY. The build starts after the service is already unhealthy, so
# the guard's clock always reads younger and would veto our first post-ceiling
# restart unless we force it. Capturing SVC_FORCE is what makes that divergence
# assertable (your-org/your-nexus#273, round-2 skeptic).
echo "\${1:-}:\${2:-} SVC_FORCE=\${SVC_FORCE:-<unset>}" >> "$SVC_FORCE_CALLS"
# Mirror svc.sh's restart-attribution marker (_record_restart_marker): the
# recovery path reads it as EVIDENCE of who restored the service.
if [[ "\${1:-}" == restart && -n "\${2:-}" ]]; then
    { echo "actor=\${SVC_RESTART_ACTOR:-operator}"
      echo "at=\$(date +%s)"
      echo "iso=\$(date -Is)"; } > "$SHDIR/\${2}.restart"
fi
# Simulate a successful restart only when the test armed FIXFLAG.
[[ -f "$FIXFLAG" ]] && touch "$OKFLAG"
exit 0
EOF
chmod +x "$SVC_STUB"

# Registry: one service. Fields are TAB-separated. The optional 6th column
# is the restart policy; `set_policy` rewrites the row.
REGISTRY="$ROOT/monitor/services.registry"
set_policy() {  # $1 = policy column ("" for none → default)
    if [[ -n "${1:-}" ]]; then
        printf 'myservice\t%s\t./launch.sh\ttest -f ok\t%s/serve.log\t%s\n' "$WD" "$WD" "$1" > "$REGISTRY"
    else
        printf 'myservice\t%s\t./launch.sh\ttest -f ok\t%s/serve.log\n' "$WD" "$WD" > "$REGISTRY"
    fi
}
set_policy ""
echo "fixture service log" > "$WD/serve.log"

# Point the module + its helpers at the fixture.
export NEXUS_ROOT="$ROOT"
export STATE_DIR="$STATE"
export SERVICE_HEALTH_STATE_DIR="$SHDIR"
export NEXUS_SERVICES_REGISTRY="$REGISTRY"
export SERVICE_HEALTH_SVC_BIN="$SVC_STUB"

# Deterministic knob baseline for the tests (overridden per case).
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=30
export MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS=300
export MONITOR_SERVICE_HEALTH_FLAP_CEILING=3
export MONITOR_SERVICE_HEALTH_DEFAULT_POLICY=auto-restart

# shellcheck source=_service_health.sh
. "$_real_dir/_service_health.sh"

reset_state() {
    rm -rf "$SHDIR"; mkdir -p "$SHDIR"
    : > "$SVC_CALLS"
    rm -f "$FIXFLAG"
    set_policy ""
    export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=30
    export MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS=300
    export MONITOR_SERVICE_HEALTH_FLAP_CEILING=3
    export MONITOR_SERVICE_HEALTH_DEFAULT_POLICY=auto-restart
}

# ===========================================================================
echo "## healthy service ⇒ no incident, no emit"
reset_state
touch "$OKFLAG"
NEXUS_TEST_NOW=1000 _service_health_check_tick
assert_no_file "no .state file for a healthy service" "$SHDIR/myservice.state"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_empty   "emit section empty when all healthy" "$emit"
assert_eq      "emit rc=1 (nothing to surface)" "$erc" "1"
assert_eq      "no svc.sh restart called" "$(wc -l < "$SVC_CALLS")" "0"

# ===========================================================================
echo
echo "## registry policy parsing: 6th column + default fallback"
reset_state
set_policy ""
rec=$(_sh_parse_registry)
assert_eq      "default row resolves to auto-restart" "$(printf '%s' "$rec" | awk -F'\t' '{print $6}')" "auto-restart"
set_policy "emit-only"
rec=$(_sh_parse_registry)
assert_eq      "explicit emit-only honored" "$(printf '%s' "$rec" | awk -F'\t' '{print $6}')" "emit-only"
set_policy "bogus-policy"
rec=$(_sh_parse_registry 2>/dev/null)
assert_eq      "unknown policy falls back to default" "$(printf '%s' "$rec" | awk -F'\t' '{print $6}')" "auto-restart"
set_policy ""

# ===========================================================================
echo
echo "## fresh failure ⇒ GRACE window, no restart yet"
reset_state
rm -f "$OKFLAG"                       # service is down
NEXUS_TEST_NOW=2000 _service_health_check_tick
assert_file_exists "incident .state created" "$SHDIR/myservice.state"
status=$(_sh_field "$SHDIR/myservice.state" status)
assert_eq      "status=grace on first detection" "$status" "grace"
assert_eq      "no svc.sh restart during grace" "$(grep -c 'restart myservice' "$SVC_CALLS")" "0"
events=$(cat "$SHDIR/myservice.events")
assert_contains "events: detected-unhealthy" "$events" "detected-unhealthy"
assert_contains "events: grace-started"      "$events" "grace-started"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq      "grace emit rc=0 (informational surfaced)" "$erc" "0"
assert_contains "grace emit names the service" "$emit" "service 'myservice'"
assert_contains "grace emit says grace window" "$emit" "grace window"
assert_contains "grace emit reports policy"    "$emit" "policy: auto-restart"
assert_contains "grace emit is no-action"      "$emit" "No action needed yet"
# A grace emit must NOT claim a restart is happening.
if printf '%s' "$emit" | grep -q "auto-restart in progress"; then
    assert_eq "grace emit does not claim restart-in-progress" "leaked" "clean"
else
    assert_eq "grace emit does not claim restart-in-progress" "clean" "clean"
fi

# ===========================================================================
echo
echo "## self-heal WITHIN grace ⇒ no restart ever, breadcrumb only"
reset_state
rm -f "$OKFLAG"
NEXUS_TEST_NOW=3000 _service_health_check_tick          # grace, no restart
touch "$OKFLAG"                                          # supervisor healed it
NEXUS_TEST_NOW=3010 _service_health_check_tick          # +10s, still < grace(30)
assert_eq      "svc.sh NEVER called for a within-grace self-heal" "$(grep -c 'restart myservice' "$SVC_CALLS")" "0"
status=$(_sh_field "$SHDIR/myservice.state" status)
assert_eq      "status=recovered after self-heal" "$status" "recovered"
recovered_via=$(_sh_field "$SHDIR/myservice.state" recovered_via)
assert_contains "recovered_via marks within-grace self-heal" "$recovered_via" "self-healed within grace"
events=$(cat "$SHDIR/myservice.events")
if printf '%s' "$events" | grep -q "restart-issued"; then
    assert_eq "no restart-issued event for a self-heal" "leaked" "clean"
else
    assert_eq "no restart-issued event for a self-heal" "clean" "clean"
fi
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq      "recovered emit rc=0" "$erc" "0"
assert_contains "breadcrumb says RECOVERED"  "$emit" "RECOVERED"
assert_contains "breadcrumb says self-healed" "$emit" "self-healed"
assert_no_file "incident state CLOSED after breadcrumb" "$SHDIR/myservice.state"
assert_file_exists "events history retained for the generator" "$SHDIR/myservice.events"

# ===========================================================================
echo
echo "## still down AFTER grace (auto-restart) ⇒ restarted + emit reports outcome"
reset_state
rm -f "$OKFLAG"
NEXUS_TEST_NOW=4000 _service_health_check_tick          # grace, no restart
assert_eq      "no restart during grace" "$(grep -c 'restart myservice' "$SVC_CALLS")" "0"
NEXUS_TEST_NOW=4040 _service_health_check_tick          # +40s > grace(30) → act
status=$(_sh_field "$SHDIR/myservice.state" status)
attempts=$(_sh_field "$SHDIR/myservice.state" restart_attempts)
assert_eq      "status=recovering after grace-elapsed restart" "$status" "recovering"
assert_eq      "restart_attempts=1" "$attempts" "1"
assert_eq      "svc.sh restart issued exactly once" "$(grep -c 'restart myservice' "$SVC_CALLS")" "1"
assert_contains "events: restart-issued" "$(cat "$SHDIR/myservice.events")" "restart-issued"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq      "emit rc=0 (surfaced)" "$erc" "0"
assert_contains "emit shows restart in progress" "$emit" "auto-restart in progress"
assert_contains "emit shows the failing check"   "$emit" "test -f ok"
assert_contains "emit reports the policy"         "$emit" "policy: auto-restart"
assert_contains "emit reports attempt outcome"    "$emit" "attempt 1/3"
assert_contains "emit points at ng service-incident" "$emit" "ng service-incident myservice"
echo "   re-nag guard: identical state suppressed on the next emit"
emit2=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc2=$?
assert_empty   "second emit empty (re-nag guarded)" "$emit2"
assert_eq      "second emit rc=1" "$erc2" "1"

# ===========================================================================
echo
echo "## emit-only policy ⇒ NEVER auto-restarts, escalates after grace"
reset_state
set_policy "emit-only"
rm -f "$OKFLAG"
NEXUS_TEST_NOW=4500 _service_health_check_tick          # grace, no restart
status=$(_sh_field "$SHDIR/myservice.state" status)
assert_eq      "emit-only: status=grace during grace" "$status" "grace"
NEXUS_TEST_NOW=4560 _service_health_check_tick          # +60s > grace → escalate
status=$(_sh_field "$SHDIR/myservice.state" status)
assert_eq      "emit-only: status=emit-only after grace" "$status" "emit-only"
assert_eq      "emit-only: svc.sh NEVER called" "$(grep -c 'restart myservice' "$SVC_CALLS")" "0"
assert_contains "events: escalate-emit-only" "$(cat "$SHDIR/myservice.events")" "escalate-emit-only"
# extra ticks must still never restart
NEXUS_TEST_NOW=4900 _service_health_check_tick
NEXUS_TEST_NOW=5300 _service_health_check_tick
assert_eq      "emit-only: still zero restarts after more ticks" "$(grep -c 'restart myservice' "$SVC_CALLS")" "0"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq      "emit-only emit rc=0" "$erc" "0"
assert_contains "emit-only emit says NOT auto-restart" "$emit" "will NOT auto-restart"
assert_contains "emit-only emit asks for judgment"     "$emit" "needs your judgment"
assert_contains "emit-only emit reports policy"        "$emit" "policy: emit-only"
set_policy ""

# ===========================================================================
echo
echo "## a restart that holds ⇒ recovered breadcrumb once, then closed"
reset_state
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=0           # act on first detection
rm -f "$OKFLAG"
NEXUS_TEST_NOW=6000 _service_health_check_tick          # grace=0 → restart issued
assert_eq      "restart issued with grace=0" "$(grep -c 'restart myservice' "$SVC_CALLS")" "1"
touch "$OKFLAG"                                          # restart "took"
NEXUS_TEST_NOW=6100 _service_health_check_tick
status=$(_sh_field "$SHDIR/myservice.state" status)
assert_eq      "status=recovered after health returns" "$status" "recovered"
recovered_via=$(_sh_field "$SHDIR/myservice.state" recovered_via)
assert_contains "recovered_via marks a held restart" "$recovered_via" "held after"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq      "recovered emit rc=0" "$erc" "0"
assert_contains "recovered breadcrumb surfaced" "$emit" "RECOVERED"
assert_contains "recovered breadcrumb says auto-restart held" "$emit" "auto-restart held"
assert_no_file "incident state CLOSED after breadcrumb" "$SHDIR/myservice.state"
emit2=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_empty   "no re-emit after the incident closed" "$emit2"

# ===========================================================================
echo
echo "## flap ceiling stops the thrash + escalates"
reset_state
rm -f "$OKFLAG"
# grace 0 + cooldown 0 so back-to-back ticks act; ceiling 2.
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=0
export MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS=0
export MONITOR_SERVICE_HEALTH_FLAP_CEILING=2
NEXUS_TEST_NOW=7000 _service_health_check_tick   # attempt 1
NEXUS_TEST_NOW=7001 _service_health_check_tick   # attempt 2
NEXUS_TEST_NOW=7002 _service_health_check_tick   # ceiling hit → no restart
status=$(_sh_field "$SHDIR/myservice.state" status)
attempts=$(_sh_field "$SHDIR/myservice.state" restart_attempts)
assert_eq      "status=flapping at the ceiling" "$status" "flapping"
assert_eq      "restart_attempts capped at ceiling (2)" "$attempts" "2"
assert_eq      "svc.sh restart called exactly twice (thrash stopped)" "$(grep -c 'restart myservice' "$SVC_CALLS")" "2"
assert_contains "events: flap-ceiling-reached" "$(cat "$SHDIR/myservice.events")" "flap-ceiling-reached"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains "flapping emit says FLAPPING" "$emit" "FLAPPING"
assert_contains "flapping emit gives the manual restart recipe" "$emit" "svc.sh restart myservice"

# ===========================================================================
echo
echo "## per-service cooldown blocks a second restart within the window"
reset_state
rm -f "$OKFLAG"
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=0
export MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS=300
NEXUS_TEST_NOW=8000 _service_health_check_tick   # attempt 1 @ t=8000
NEXUS_TEST_NOW=8100 _service_health_check_tick   # +100s < cooldown ⇒ no restart
assert_eq      "only one restart within the cooldown window" "$(grep -c 'restart myservice' "$SVC_CALLS")" "1"
attempts=$(_sh_field "$SHDIR/myservice.state" restart_attempts)
assert_eq      "restart_attempts still 1 inside cooldown" "$attempts" "1"

# ===========================================================================
echo
echo "## ng service-incident assembles all required sections from state"
# Build a deterministic flapping incident fixture and run the REAL ng.
reset_state
cat > "$SHDIR/myservice.state" <<EOF
service=myservice
status=flapping
policy=auto-restart
first_unhealthy=6000
first_unhealthy_iso=2026-06-15T01:00:00+00:00
recovered_at_iso=—
restart_attempts=3
last_restart=6400
last_check_iso=2026-06-15T01:10:00+00:00
grace_seconds=30
health_cmd=curl -fsS -o /dev/null --max-time 3 http://localhost:8765/
workdir=$WD
logfile=$WD/serve.log
note=auto-restart ceiling (3) reached
EOF
{
    printf '2026-06-15T01:00:00+00:00\tdetected-unhealthy\thealthcheck failed\n'
    printf '2026-06-15T01:00:00+00:00\tgrace-started\tdeferring 30s to supervisor\n'
    printf '2026-06-15T01:02:00+00:00\trestart-issued\tattempt 1/3\n'
    printf '2026-06-15T01:10:00+00:00\tflap-ceiling-reached\t3 attempts did not hold\n'
} > "$SHDIR/myservice.events"

report=$(bash "$_real_monitor/ng" service-incident myservice --state-dir "$SHDIR" 2>/dev/null)
assert_contains "report: Failure report section"   "$report" "## Failure report"
assert_contains "report: Immediate response section" "$report" "## Immediate response"
assert_contains "report: Root-cause fix section"    "$report" "## Root-cause fix"
assert_contains "report: how-to-undo instruction"   "$report" "How to undo"
assert_contains "report: References section"        "$report" "## References"
assert_contains "report: Worker report section"     "$report" "## Worker report"
assert_contains "report: restart policy surfaced"   "$report" "Restart policy"
assert_contains "report: failing healthcheck verbatim" "$report" "http://localhost:8765/"
assert_contains "report: verbatim event timeline"   "$report" "flap-ceiling-reached"
assert_contains "report: NOT RECOVERED outcome"     "$report" "NOT RECOVERED"

# --- operator-friendly opening (plain-language TL;DR + agent-sandbox recovery)
# Many operators are biologists with only basic compute knowledge: the report
# must LEAD with a non-technical summary + a copy-pasteable recovery runbook
# before any machine facts.
assert_contains "report: plain-language TL;DR lead"   "$report" "In plain terms (no compute expertise needed)"
assert_contains "report: states which service stopped" "$report" '**`myservice`**'
assert_contains "report: gives a clear next action"   "$report" "What you should do:"
assert_contains "report: flapping ⇒ restart action"   "$report" "**Restart the workspace** using the steps below."
# agent-sandbox detach + watcher --continue recovery (mirrors _lib.sh body)
assert_contains "report: detach nested sandbox (Ctrl-a then d)" "$report" "press and hold **\`Ctrl\`**, tap **\`a\`**, let go — then tap **\`d\`**"
assert_contains "report: warns against the OUTER/meta key" "$report" "Do **NOT** use **\`Ctrl\`+\`b\`** then **\`d\`**"
assert_contains "report: watcher --continue restart command" "$report" "agent-sandbox tmux new-session ./watcher --continue"
assert_contains "report: gates the sandbox steps"     "$report" "If you are in the agent sandbox"
# non-sandbox case stays correct
assert_contains "report: non-sandbox fallback"        "$report" "If you are NOT in the agent sandbox"
assert_contains "report: non-sandbox svc.sh restart"  "$report" "monitor/svc.sh restart myservice"
# lead-with-human ordering: the TL;DR precedes the machine Failure report
tldr_line=$(printf '%s\n' "$report" | grep -n "In plain terms" | head -1 | cut -d: -f1)
fail_line=$(printf '%s\n' "$report" | grep -n "## Failure report" | head -1 | cut -d: -f1)
assert_eq "operator TL;DR comes BEFORE the machine Failure report" \
    "$([[ -n "$tldr_line" && -n "$fail_line" && "$tldr_line" -lt "$fail_line" ]] && echo ok || echo no)" "ok"

# recovered (closed-and-came-back) incident ⇒ TL;DR says no action required,
# not an alarmist restart instruction.
cat > "$SHDIR/recsvc.state" <<EOF
service=recsvc
status=recovered
policy=auto-restart
first_unhealthy=6000
first_unhealthy_iso=2026-06-15T03:00:00+00:00
recovered_at_iso=2026-06-15T03:02:00+00:00
recovered_via=self-healed within grace
restart_attempts=0
grace_seconds=30
health_cmd=curl -fsS -o /dev/null --max-time 3 http://localhost:8765/
workdir=$WD
logfile=$WD/serve.log
EOF
printf '2026-06-15T03:00:00+00:00\tdetected-unhealthy\thealthcheck failed\n2026-06-15T03:02:00+00:00\trecovered\tself-healed within grace\n' > "$SHDIR/recsvc.events"
recreport=$(bash "$_real_monitor/ng" service-incident recsvc --state-dir "$SHDIR" 2>/dev/null)
assert_contains "recovered TL;DR: came back on its own"  "$recreport" "already came back on its own"
assert_contains "recovered TL;DR: nothing required"      "$recreport" "Nothing is required of you"

# emit-only incident ⇒ report states the no-auto-restart-by-policy outcome
cat > "$SHDIR/eosvc.state" <<EOF
service=eosvc
status=emit-only
policy=emit-only
first_unhealthy=6000
first_unhealthy_iso=2026-06-15T02:00:00+00:00
recovered_at_iso=—
restart_attempts=0
grace_seconds=30
health_cmd=test -f /tmp/eosvc.ok
workdir=$WD
logfile=$WD/serve.log
note=policy emit-only — watcher will NOT auto-restart
EOF
printf '2026-06-15T02:00:00+00:00\tescalate-emit-only\tpolicy emit-only\n' > "$SHDIR/eosvc.events"
eoreport=$(bash "$_real_monitor/ng" service-incident eosvc --state-dir "$SHDIR" 2>/dev/null)
assert_contains "emit-only report: policy surfaced"        "$eoreport" "emit-only"
assert_contains "emit-only report: no-auto-restart outcome" "$eoreport" "did NOT auto-restart by policy"

# unknown service ⇒ loud failure, not a silent empty report
if bash "$_real_monitor/ng" service-incident nosuchsvc --state-dir "$SHDIR" >/dev/null 2>&1; then
    assert_eq "ng service-incident on unknown service fails loud" "ok" "should-have-failed"
else
    assert_eq "ng service-incident on unknown service fails loud" "ok" "ok"
fi

# ===========================================================================
# Supervisor/health INCONSISTENCY: a green healthcheck beside a dead
# supervisor record. This is the shape that let `nexus-remote-ssh` sit at
# `UP stale` in the cockpit for days with no emit — the health gate is
# healthcheck-only, so a daemon that outlives its wrapper never trips it.
SVCPIDDIR="$STATE/services"
mkdir -p "$SVCPIDDIR"
PIDFILE="$SVCPIDDIR/myservice.pid"
# A stand-in supervisor whose cmdline matches the registry launch cmd
# (`./launch.sh` ⇒ token `launch.sh`), so _sh_supervisor_state says alive.
# Short inner sleeps (not one long `sleep 300`): killing the wrapper must not
# leave an orphan child holding this script's stdout — a long-sleeping
# grandchild keeps the test's output pipe open and hangs the runner.
cat > "$WD/launch.sh" <<'EOF'
#!/usr/bin/env bash
while :; do sleep 0.2; done
EOF
chmod +x "$WD/launch.sh"
SUP_PID=""
start_supervisor() { bash "$WD/launch.sh" >/dev/null 2>&1 & SUP_PID=$!; echo "$SUP_PID" > "$PIDFILE"
    local d=$(( SECONDS + 15 ))
    until [[ "$(tr '\0' ' ' < "/proc/$SUP_PID/cmdline" 2>/dev/null)" == *launch.sh* ]]; do
        (( SECONDS >= d )) && break; sleep 0.05
    done; }
stop_supervisor() { [[ -n "$SUP_PID" ]] && { kill "$SUP_PID" 2>/dev/null; wait "$SUP_PID" 2>/dev/null; }; SUP_PID=""; }
# A PID that is provably not a live supervisor: spawned, exited, reaped. Even
# in the pathological case where the kernel recycles it, the cmdline guard in
# _sh_supervisor_state still reports `stale` — nothing in this fixture but
# start_supervisor ever execs launch.sh.
dead_pid() { local p; bash -c 'exit 0' & p=$!; wait "$p" 2>/dev/null; printf '%s' "$p"; }
trap 'stop_supervisor; cleanup' EXIT
reset_incon() { reset_state; rm -f "$PIDFILE"; export MONITOR_SERVICE_HEALTH_INCONSISTENT_POLLS=3; }

echo
echo "## healthy + NO pidfile ⇒ never 'inconsistent' (unmanaged services)"
reset_incon
touch "$OKFLAG"
NEXUS_TEST_NOW=2000 _service_health_check_tick
NEXUS_TEST_NOW=2001 _service_health_check_tick
NEXUS_TEST_NOW=2002 _service_health_check_tick
assert_no_file "absent pidfile is not an inconsistency" "$SHDIR/myservice.state"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq "no emit for a healthy unmanaged service" "$erc" "1"

echo
echo "## healthy + LIVE supervisor ⇒ no incident"
reset_incon
touch "$OKFLAG"; start_supervisor
NEXUS_TEST_NOW=2100 _service_health_check_tick
NEXUS_TEST_NOW=2101 _service_health_check_tick
NEXUS_TEST_NOW=2102 _service_health_check_tick
assert_no_file "live supervisor + healthy ⇒ no .state" "$SHDIR/myservice.state"
stop_supervisor

echo
echo "## healthy + DEAD pid record ⇒ debounced, then surfaced ONCE"
reset_incon
touch "$OKFLAG"
dead_pid > "$PIDFILE"             # a record whose process is gone
NEXUS_TEST_NOW=2200 _service_health_check_tick
assert_no_file "poll 1/3: below threshold ⇒ no incident yet" "$SHDIR/myservice.state"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq "poll 1/3: nothing surfaced (no flap on a relaunch race)" "$erc" "1"
NEXUS_TEST_NOW=2201 _service_health_check_tick
assert_no_file "poll 2/3: still below threshold" "$SHDIR/myservice.state"
NEXUS_TEST_NOW=2202 _service_health_check_tick
assert_file_exists "poll 3/3: incident opened" "$SHDIR/myservice.state"
assert_eq "status=inconsistent" "$(_sh_field "$SHDIR/myservice.state" status)" "inconsistent"
assert_eq "the watcher NEVER restarts a healthy service" \
    "$(grep -c 'restart myservice' "$SVC_CALLS")" "0"
events=$(cat "$SHDIR/myservice.events" 2>/dev/null)
assert_contains "events: detected-inconsistent" "$events" "detected-inconsistent"

emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq       "inconsistency emit rc=0 (surfaced)" "$erc" "0"
assert_contains "emit names the service"     "$emit" "service 'myservice'"
assert_contains "emit says INCONSISTENT"     "$emit" "INCONSISTENT"
assert_contains "emit says the daemon is unsupervised" "$emit" "UNSUPERVISED"
assert_contains "emit states the healthcheck PASSES"   "$emit" "healthcheck PASSES"
assert_contains "emit offers the reconcile action"     "$emit" "svc.sh restart myservice"
assert_not_contains "emit never claims the service is DOWN" "$emit" "DOWN since"

# Re-nag guard: the same inconsistency must not spam every loop.
NEXUS_TEST_NOW=2203 _service_health_check_tick
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq    "persisting inconsistency is NOT re-surfaced" "$erc" "1"
assert_empty "persisting inconsistency emits nothing"      "$emit"

echo
echo "## reconcile ⇒ one-shot breadcrumb, then the incident closes"
start_supervisor                   # a real supervisor is recorded again
NEXUS_TEST_NOW=2300 _service_health_check_tick
assert_eq "status=reconciled" "$(_sh_field "$SHDIR/myservice.state" status)" "reconciled"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq       "reconcile emit rc=0" "$erc" "0"
assert_contains "reconcile emit says RECONCILED" "$emit" "RECONCILED"
assert_no_file  "incident state closed after the breadcrumb" "$SHDIR/myservice.state"
events=$(cat "$SHDIR/myservice.events" 2>/dev/null)
assert_contains "events: inconsistent-cleared" "$events" "inconsistent-cleared"
NEXUS_TEST_NOW=2301 _service_health_check_tick
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq "reconciled state does not re-surface" "$erc" "1"
stop_supervisor

echo
echo "## a DOWN service with a dead pid record is an ordinary outage, not 'inconsistent'"
reset_incon
rm -f "$OKFLAG"                    # unhealthy
dead_pid > "$PIDFILE"              # …and its supervisor record is dead too
NEXUS_TEST_NOW=2400 _service_health_check_tick
NEXUS_TEST_NOW=2401 _service_health_check_tick
NEXUS_TEST_NOW=2402 _service_health_check_tick
assert_eq "status=grace (the health incident owns it)" \
    "$(_sh_field "$SHDIR/myservice.state" status)" "grace"
assert_no_file "no stray inconsistency counter while DOWN" "$SHDIR/myservice.inconsistent"

echo
echo "## recovered-within-grace no longer CLAIMS a supervisor that is dead"
reset_incon
rm -f "$OKFLAG"; dead_pid > "$PIDFILE"
NEXUS_TEST_NOW=2500 _service_health_check_tick        # → grace
touch "$OKFLAG"                                       # heals inside grace
NEXUS_TEST_NOW=2510 _service_health_check_tick        # → recovered
via=$(_sh_field "$SHDIR/myservice.state" recovered_via)
assert_contains "recovered_via reports NO live supervisor" "$via" "NO live supervisor"
assert_not_contains "recovered_via does not assert a supervisor healed it" \
    "$via" "supervisor pid"

reset_incon
rm -f "$OKFLAG"; start_supervisor
NEXUS_TEST_NOW=2600 _service_health_check_tick        # → grace
touch "$OKFLAG"
NEXUS_TEST_NOW=2610 _service_health_check_tick        # → recovered
via=$(_sh_field "$SHDIR/myservice.state" recovered_via)
assert_contains "with a live supervisor it IS credited by pid" "$via" "supervisor pid $SUP_PID"
stop_supervisor

# ===========================================================================
# RECOVERY ATTRIBUTION. "Green, and I didn't restart it" does NOT imply a
# self-heal: an orchestrator running `svc.sh restart` satisfies the same
# predicate. Inferring by elimination logged a 19h outage that the operator
# personally fixed as a "transient blip, no action needed"
# (your-org/your-nexus#265). Attribution must come from the marker svc.sh drops.
echo
echo "## an OPERATOR restore is attributed as intervention, never a self-heal"
reset_incon
rm -f "$OKFLAG"
set_policy "emit-only"      # nexus-remote-ssh's policy: the watcher never restarts
NEXUS_TEST_NOW=3000 _service_health_check_tick        # → grace
NEXUS_TEST_NOW=3100 _service_health_check_tick        # grace elapsed → emit-only escalation
# The operator restores it out-of-band, exactly as `svc.sh restart` would.
printf 'actor=operator\nat=3150\niso=2026-07-09T10:53:00-07:00\n' > "$SHDIR/myservice.restart"
touch "$OKFLAG"
NEXUS_TEST_NOW=3200 _service_health_check_tick        # → recovered
assert_eq "recovered_by=operator (from the marker, not by elimination)" \
    "$(_sh_field "$SHDIR/myservice.state" recovered_by)" "operator"
via=$(_sh_field "$SHDIR/myservice.state" recovered_via)
assert_contains "recovered_via names the intervention" "$via" "RESTORED by operator"
assert_not_contains "an operator restore is NEVER called a self-heal" "$via" "self-healed"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains     "emit says RECOVERED BY INTERVENTION" "$emit" "RECOVERED BY INTERVENTION"
assert_not_contains "emit never calls a rescued outage a transient blip" "$emit" "Transient blip"
assert_contains     "emit states action was warranted" "$emit" "NOT a transient blip"
assert_no_file "restart marker consumed on incident close" "$SHDIR/myservice.restart"

echo
echo "## a WATCHER auto-restart is still attributed to the watcher"
reset_incon
rm -f "$OKFLAG"; touch "$FIXFLAG"          # the stub's restart will hold
NEXUS_TEST_NOW=3300 _service_health_check_tick        # → grace
NEXUS_TEST_NOW=3400 _service_health_check_tick        # grace elapsed → restart
NEXUS_TEST_NOW=3500 _service_health_check_tick        # → recovered
assert_eq "recovered_by=watcher" "$(_sh_field "$SHDIR/myservice.state" recovered_by)" "watcher"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains     "emit says auto-restart held" "$emit" "auto-restart held"
assert_not_contains "a watcher restart is not a transient blip" "$emit" "Transient blip"

echo
echo "## green again with a DEAD supervisor and no restart ⇒ cause UNKNOWN"
reset_incon
rm -f "$OKFLAG"; dead_pid > "$PIDFILE"
NEXUS_TEST_NOW=3600 _service_health_check_tick        # → grace
touch "$OKFLAG"
NEXUS_TEST_NOW=3610 _service_health_check_tick        # → recovered, unattributable
assert_eq "recovered_by=unknown" "$(_sh_field "$SHDIR/myservice.state" recovered_by)" "unknown"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains     "emit admits the cause is unknown" "$emit" "CAUSE UNKNOWN"
assert_not_contains "an unattributed recovery is never a blip" "$emit" "Transient blip"

echo
echo "## a sub-grace self-heal IS still a blip (no false alarm)"
reset_incon
rm -f "$OKFLAG"
NEXUS_TEST_NOW=3700 _service_health_check_tick        # → grace
touch "$OKFLAG"
NEXUS_TEST_NOW=3710 _service_health_check_tick        # heals inside grace
assert_eq "escalated=0 for a sub-grace flicker" \
    "$(_sh_field "$SHDIR/myservice.state" escalated || echo 0)" "0"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains "a true blip still reads as a blip" "$emit" "Transient blip"

echo
echo "## an incident that LEFT grace is never a blip, even if it self-heals"
reset_incon
rm -f "$OKFLAG"; set_policy "emit-only"     # escalates, never auto-restarts
NEXUS_TEST_NOW=3800 _service_health_check_tick        # → grace
NEXUS_TEST_NOW=3900 _service_health_check_tick        # → emit-only (escalated)
assert_eq "escalated=1 once past grace" "$(_sh_field "$SHDIR/myservice.state" escalated)" "1"
touch "$OKFLAG"
NEXUS_TEST_NOW=3910 _service_health_check_tick        # → recovered
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_not_contains "an escalated incident is never a transient blip" "$emit" "Transient blip"
assert_contains     "it demands a record instead" "$emit" "NOT a transient blip"

echo
echo "## a PERSISTING inconsistency re-nags once per window (never silently retired)"
reset_incon
touch "$OKFLAG"; dead_pid > "$PIDFILE"
export MONITOR_SERVICE_HEALTH_INCONSISTENT_RENAG_SECONDS=100
NEXUS_TEST_NOW=4000 _service_health_check_tick
NEXUS_TEST_NOW=4001 _service_health_check_tick
NEXUS_TEST_NOW=4002 _service_health_check_tick        # threshold reached
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq "first sighting surfaces" "$erc" "0"
NEXUS_TEST_NOW=4050 _service_health_check_tick        # same window
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq "same window does NOT re-nag" "$erc" "1"
NEXUS_TEST_NOW=4150 _service_health_check_tick        # next re-nag window
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq       "next window re-nags (persistent != suppressed)" "$erc" "0"
assert_contains "the re-nag still says INCONSISTENT" "$emit" "INCONSISTENT"
unset MONITOR_SERVICE_HEALTH_INCONSISTENT_RENAG_SECONDS

# ===========================================================================
# SKEPTIC REGRESSION A (svc-skeptic, PR #460): a restart CAUSES the downtime
# that follows it. svc.sh stamps the marker at the top of cmd_restart, BEFORE
# it stops the service, so the marker is always earlier than the
# `first_unhealthy` the watcher later observes. A `mk_at >= first_unhealthy`
# guard therefore discarded the marker in exactly the workflow the
# inconsistency emit prescribes ("reconcile: svc.sh restart <name>"), and
# credited the operator's rescue to a supervisor that healed nothing.
echo
echo "## an operator restart stamped BEFORE the outage it causes is still attributed"
reset_incon
export MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS=120
rm -f "$OKFLAG"; set_policy "emit-only"
# Marker at t=1000; the watcher only observes the downtime at t=1004.
printf 'actor=operator\nat=1000\niso=2026-07-09T10:53:00-07:00\n' > "$SHDIR/myservice.restart"
NEXUS_TEST_NOW=1004 _service_health_check_tick        # → grace (first_unhealthy=1004)
start_supervisor                                      # the restart brought a real one up
touch "$OKFLAG"
NEXUS_TEST_NOW=1010 _service_health_check_tick        # → recovered
assert_eq "marker stamped before first_unhealthy still attributes to operator" \
    "$(_sh_field "$SHDIR/myservice.state" recovered_by)" "operator"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_not_contains "the prescribed reconcile is NEVER a transient blip" "$emit" "Transient blip"
assert_contains     "it reads as an intervention" "$emit" "RECOVERED BY INTERVENTION"
stop_supervisor

echo
echo "## a marker far older than the incident is NOT resurrected as evidence"
reset_incon
export MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS=120
rm -f "$OKFLAG"
printf 'actor=operator\nat=1000\niso=old\n' > "$SHDIR/myservice.restart"
NEXUS_TEST_NOW=9000 _service_health_check_tick        # incident far in the future
touch "$OKFLAG"
NEXUS_TEST_NOW=9010 _service_health_check_tick
assert_not_contains "a long-stale marker cannot attribute a later incident" \
    "$(_sh_field "$SHDIR/myservice.state" recovered_by)" "operator"
unset MONITOR_SERVICE_HEALTH_INTERVAL_SECONDS

# ===========================================================================
# SKEPTIC REGRESSION B: `svc.sh stop` on an orphan deletes the stale pidfile
# and leaves the daemon running. `absent` proves NOTHING about supervision, so
# treating that transition as `reconciled` ("healthy and supervised again")
# was a fresh false all-clear that silenced the alarm forever.
echo
echo "## a pid record that VANISHES under a live daemon is NOT a reconcile"
reset_incon
touch "$OKFLAG"; dead_pid > "$PIDFILE"
NEXUS_TEST_NOW=5000 _service_health_check_tick
NEXUS_TEST_NOW=5001 _service_health_check_tick
NEXUS_TEST_NOW=5002 _service_health_check_tick        # → inconsistent
assert_eq "orphan detected" "$(_sh_field "$SHDIR/myservice.state" status)" "inconsistent"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)   # surface once
rm -f "$PIDFILE"                                      # `svc.sh stop` on the orphan
NEXUS_TEST_NOW=5003 _service_health_check_tick
assert_eq "status stays inconsistent (never 'reconciled')" \
    "$(_sh_field "$SHDIR/myservice.state" status)" "inconsistent"
assert_eq "the kind becomes 'vanished'" \
    "$(_sh_field "$SHDIR/myservice.state" supervisor_kind)" "vanished"
events=$(cat "$SHDIR/myservice.events" 2>/dev/null)
assert_contains "events: supervisor-record-vanished" "$events" "supervisor-record-vanished"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq       "the vanish re-surfaces (new fact, not silence)" "$erc" "0"
assert_not_contains "it NEVER says RECONCILED" "$emit" "RECONCILED"
assert_contains "it says the record was removed, still unsupervised" "$emit" "still unsupervised, NOT reconciled"
assert_file_exists "the alarm stays open" "$SHDIR/myservice.state"

echo
echo "## only a LIVE supervisor pid closes the inconsistency"
start_supervisor
NEXUS_TEST_NOW=5100 _service_health_check_tick
assert_eq "a live record reconciles" "$(_sh_field "$SHDIR/myservice.state" status)" "reconciled"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains "reconcile breadcrumb surfaced" "$emit" "RECONCILED"
assert_no_file  "incident closed" "$SHDIR/myservice.state"
stop_supervisor

# ===========================================================================
# labsh COLD-BUILD awareness (your-org/nexus-code#326 follow-up). A
# jupyter/labsh service's healthcheck fails for the ENTIRE ~10-min cold `uvx`
# build; #326 taught the SUPERVISOR to wait for it, but the watcher's
# service-health-watch — a separate later layer — fired a `svc.sh restart` at
# its 30s grace and KILLED the in-progress build (live incident 2026-07-09,
# jupyter-scecho-dev-mem). The watch is now cold-build-aware: while a build is
# materialising it defers to the (patient) supervisor and never restarts; a
# genuinely-dead labsh service (no live build) is STILL restarted after grace.
#
# Fixture: a jupyter/labsh registry row (launch is labsh-supervised.sh, so
# `_sh_is_labsh_service` matches; the healthcheck stays the flag-file probe so
# the test controls health). A "build in progress" = a live process whose
# cmdline carries `jupyter-lab`, recorded in <wd>/.jupyter/labsh.bg.pid, plus a
# labsh.bg.log with NO server URL yet.
JWD="$WORK/jwd"
JDIR="$JWD/.jupyter"
mkdir -p "$JDIR"
JOK="$JWD/ok"                       # health flag for the jupyter fixture
JREG_LAUNCH="$WORK/fake-monitor/labsh-supervised.sh"   # string only; never executed
# A stand-in cold `uvx jupyter-lab` build.
#
# It used to be a bash script whose PATH merely carried the string
# `jupyter-lab`, because the old predicate matched on argv. It passed for that
# reason alone. `_sh_labsh_build_in_progress` now demands IDENTITY
# (nexus-code#467): /proc/<pid>/exe basename in {uv,uvx}, cwd == the service's
# workdir, a jupyterlab marker in argv, and the recorded bg.pid or this
# service's --port. So the fixture must be a real stand-in for a build, not a
# process that resembles one — which is the entire point of the change.
#
# `exe` is controlled by COPYING a real bash binary to the name we want it to
# report. `-c 'while ...; done'` is a compound command, so bash does not
# exec-replace itself with the inner `sleep` (which would make exe=`sleep`).
# Short inner sleeps so killing it can't orphan a long-sleeper holding the
# runner's output pipe open.
BUILD_BIN="$JWD/uv"                       # /proc/<pid>/exe basename → uv
cp "$(command -v bash)" "$BUILD_BIN"
JPORT=$(( 49152 + (RANDOM % 16000) ))     # ephemeral; never a labsh port
printf 'PORT=%s\n' "$JPORT" > "$JDIR/labsh-service.env"
BUILD_PID=""
start_build() {   # simulate labsh's backgrounded cold uvx build (no URL yet)
    : > "$JDIR/labsh.bg.log"       # build log with NO "running at" URL line
    # cwd MUST be the service workdir — that is the identity signal.
    ( cd "$JWD" && exec "$BUILD_BIN" -c 'while :; do sleep 0.2; done' \
        tool uvx --from jupyterlab jupyter-lab --port "$JPORT" --no-browser ) >/dev/null 2>&1 &
    BUILD_PID=$!
    echo "$BUILD_PID" > "$JDIR/labsh.bg.pid"
    local d=$(( SECONDS + 15 ))
    until [[ "$(tr '\0' ' ' < "/proc/$BUILD_PID/cmdline" 2>/dev/null)" == *jupyter-lab* ]]; do
        (( SECONDS >= d )) && break; sleep 0.05
    done
    # Refuse to proceed on a fixture that does not satisfy the contract under
    # test — a silently-wrong fixture asserts nothing.
    local _exe; _exe=$(basename "$(readlink -f "/proc/$BUILD_PID/exe" 2>/dev/null)" 2>/dev/null)
    [[ "$_exe" == uv ]] || { echo "cold-build fixture broken: exe=$_exe (want uv)" >&2; exit 1; }
}
stop_build() { [[ -n "$BUILD_PID" ]] && { kill "$BUILD_PID" 2>/dev/null; wait "$BUILD_PID" 2>/dev/null; }; BUILD_PID=""; }

# An IMPOSTOR: argv byte-identical to a real cold build (`jupyter-lab`, this
# service's `--port`), but it is not one — its cwd is not the service workdir
# and its exe is not `uv`. This is the 2026-07-09 shape: a test fixture whose
# command line resembled a build silenced the watchdog while the real service
# was down. The predicate must not be fooled, and the watcher must restart.
IMPOSTOR_BIN="$JWD/zsh"
cp "$(command -v bash)" "$IMPOSTOR_BIN"
IMPOSTOR_PID=""
start_impostor() {
    : > "$JDIR/labsh.bg.log"
    rm -f "$JDIR/labsh.bg.pid"       # nothing recorded: it is not our build
    ( cd "$WORK" && exec "$IMPOSTOR_BIN" -c 'while :; do sleep 0.2; done' \
        tool uvx --from jupyterlab jupyter-lab --port "$JPORT" --no-browser ) >/dev/null 2>&1 &
    IMPOSTOR_PID=$!
    local d=$(( SECONDS + 15 ))
    until [[ "$(tr '\0' ' ' < "/proc/$IMPOSTOR_PID/cmdline" 2>/dev/null)" == *jupyter-lab* ]]; do
        (( SECONDS >= d )) && break; sleep 0.05
    done
}
stop_impostor() { [[ -n "$IMPOSTOR_PID" ]] && { kill "$IMPOSTOR_PID" 2>/dev/null; wait "$IMPOSTOR_PID" 2>/dev/null; }; IMPOSTOR_PID=""; }
trap 'stop_build; stop_impostor; stop_supervisor; cleanup' EXIT
jreg() {   # write a jupyter/labsh registry row (health = flag-file probe)
    printf 'jupyter-fix\t%s\t%s\ttest -f ok\t%s/.jupyter/labsh-service.log\n' \
        "$JWD" "$JREG_LAUNCH" "$JWD" > "$REGISTRY"
}
reset_jup() {
    rm -rf "$SHDIR"; mkdir -p "$SHDIR"
    : > "$SVC_CALLS"; rm -f "$FIXFLAG" "$JOK" "$JDIR/labsh.bg.pid"
    jreg
    export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=30
    export MONITOR_SERVICE_HEALTH_RESTART_COOLDOWN_SECONDS=300
    export MONITOR_SERVICE_HEALTH_FLAP_CEILING=3
    export MONITOR_SERVICE_HEALTH_DEFAULT_POLICY=auto-restart
    export MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=1800
}

echo
echo "## the module classifies a labsh service by its launch/health command"
if _sh_is_labsh_service "$JREG_LAUNCH" "test -f ok"; then r=yes; else r=no; fi
assert_eq "labsh-supervised.sh launch ⇒ labsh service" "$r" "yes"
if _sh_is_labsh_service "./launch.sh" "$_real_monitor/jupyter-health.sh"; then r=yes; else r=no; fi
assert_eq "jupyter-health.sh healthcheck ⇒ labsh service" "$r" "yes"
if _sh_is_labsh_service "./launch.sh" "test -f ok"; then r=yes; else r=no; fi
assert_eq "an ordinary service is NOT a labsh service" "$r" "no"

echo
echo "## an IMPOSTOR must NOT silence the watchdog (nexus-code#467: fail closed)"
# The predicate used to be `pgrep -f jupyter-lab` + an argv `--port` match, so
# ANY process resembling a build suspended auto-restart while the service was
# down. With identity gating, an impostor is not our build, so the ordinary
# grace/restart machinery must proceed exactly as if no build existed.
reset_jup
rm -f "$JOK"                       # service is DOWN
start_impostor                     # ...and something merely LOOKS like a build
if _sh_labsh_build_in_progress "$JWD"; then r=yes; else r=no; fi
assert_eq "impostor is NOT reported as a cold build in progress" "$r" "no"
NEXUS_TEST_NOW=20000 _service_health_check_tick
assert_eq "impostor does not yield status=cold-build" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" status)" "grace"
NEXUS_TEST_NOW=20040 _service_health_check_tick     # past the 30s grace
NEXUS_TEST_NOW=20200 _service_health_check_tick
restarts=$(grep -c 'restart jupyter-fix' "$SVC_CALLS")
# >=1 restart means recovery proceeded. Compare on the boolean, not the count,
# so a change in retry cadence cannot silently turn this green or red.
assert_eq "recovery is NOT suspended for an impostor (a restart is issued)" \
    "$([[ "$restarts" -ge 1 ]] && echo yes || echo no)" "yes"
stop_impostor

# Positive control: the SAME argv, launched from the service workdir with
# exe=uv and recorded in bg.pid, IS our build and DOES defer the restart.
# Without this, the assertion above could pass because nothing ever defers.
echo
echo "## COLD BUILD in progress ⇒ watcher DEFERS, never restarts (the fix)"
reset_jup
rm -f "$JOK"                       # healthcheck fails during the build
start_build                        # a live uvx/jupyter-lab build, no URL yet
NEXUS_TEST_NOW=10000 _service_health_check_tick        # fresh detection
assert_eq "status=cold-build on first detection" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" status)" "cold-build"
assert_eq "cold build is NOT escalated (legitimate bring-up)" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" escalated)" "0"
assert_contains "events: cold-build-in-progress" \
    "$(cat "$SHDIR/jupyter-fix.events")" "cold-build-in-progress"
# Past the 30s grace — the exact point the old code fired the killing restart.
NEXUS_TEST_NOW=10040 _service_health_check_tick
assert_eq "still cold-build after grace elapses" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" status)" "cold-build"
NEXUS_TEST_NOW=10200 _service_health_check_tick        # minutes in — still building
assert_eq "the build is NEVER restarted while in progress" \
    "$(grep -c 'restart jupyter-fix' "$SVC_CALLS")" "0"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_eq       "cold-build emit rc=0 (informational surfaced)" "$erc" "0"
assert_contains "emit says COLD BUILD in progress" "$emit" "COLD BUILD is in progress"
assert_contains "emit says the watcher will NOT restart" "$emit" "will NOT restart"
assert_contains "emit is no-action"                "$emit" "No action needed"
# A cold-build emit must NOT claim a restart is happening.
assert_not_contains "cold-build emit never claims restart-in-progress" \
    "$emit" "auto-restart in progress"

echo
echo "## the build completes ⇒ 'came up after a cold build', attributed, closed"
touch "$JOK"                       # build bound + healthcheck passes
start_supervisor_jup() { :; }      # (supervisor liveness is optional here)
NEXUS_TEST_NOW=10300 _service_health_check_tick
assert_eq "status=recovered once the build binds" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" status)" "recovered"
assert_eq "recovered_by=cold-build (not 'unknown')" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" recovered_by)" "cold-build"
assert_eq "no restart was ever issued across the whole build" \
    "$(grep -c 'restart jupyter-fix' "$SVC_CALLS")" "0"
emit=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains "recovered emit says came up after a COLD BUILD" "$emit" "came up after a labsh COLD BUILD"
assert_not_contains "a completed cold build is NEVER an unknown-cause recovery" "$emit" "CAUSE UNKNOWN"
assert_not_contains "a completed cold build is NEVER a rescued outage" "$emit" "RECOVERED BY INTERVENTION"
assert_no_file "incident closed after the breadcrumb" "$SHDIR/jupyter-fix.state"
stop_build

echo
echo "## a genuinely-DEAD labsh service (no live build) is STILL restarted"
reset_jup
rm -f "$JOK"                       # unhealthy
rm -f "$JDIR/labsh.bg.pid"         # NO build pid on file
: > "$JDIR/labsh.bg.log"           # …and no URL / no live build process
# (BUILD_PID is not running: stop_build was called; nothing matches pgrep.)
NEXUS_TEST_NOW=11000 _service_health_check_tick        # fresh → grace (no build)
assert_eq "no live build ⇒ ordinary grace, not cold-build" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" status)" "grace"
assert_eq "no restart during grace" "$(grep -c 'restart jupyter-fix' "$SVC_CALLS")" "0"
NEXUS_TEST_NOW=11040 _service_health_check_tick        # past grace → act
assert_eq "status=recovering after the grace-elapsed restart" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" status)" "recovering"
assert_eq "a dead labsh service IS restarted (recovery NOT weakened)" \
    "$(grep -c 'restart jupyter-fix' "$SVC_CALLS")" "1"
assert_contains "events: restart-issued for the dead service" \
    "$(cat "$SHDIR/jupyter-fix.events")" "restart-issued"

echo
echo "## a URL already in the build log ⇒ NOT a cold build (bound server recovers normally)"
reset_jup
rm -f "$JOK"                       # unhealthy (bound but wedged)
start_build                        # a live jupyter-lab process …
printf '[I ServerApp] Jupyter Server is running at:\n    http://127.0.0.1:9922/lab?token=x\n' \
    > "$JDIR/labsh.bg.log"         # …but the URL has already appeared
NEXUS_TEST_NOW=12000 _service_health_check_tick
assert_eq "URL present ⇒ ordinary grace, not cold-build" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" status)" "grace"
NEXUS_TEST_NOW=12040 _service_health_check_tick        # past grace → act
assert_eq "a bound-but-wedged server is still restarted after grace" \
    "$(grep -c 'restart jupyter-fix' "$SVC_CALLS")" "1"
stop_build

echo
echo "## cold-build ceiling ⇒ a pathological never-binding build is eventually restarted"
reset_jup
: > "$SVC_FORCE_CALLS"             # scope the SVC_FORCE assertions to THIS case
export MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=1800
rm -f "$JOK"; start_build          # a build that never binds a URL
NEXUS_TEST_NOW=20000 _service_health_check_tick        # cold-build
assert_eq "still cold-build within the ceiling" \
    "$(_sh_field "$SHDIR/jupyter-fix.state" status)" "cold-build"
assert_eq "no restart within the ceiling" "$(grep -c 'restart jupyter-fix' "$SVC_CALLS")" "0"
NEXUS_TEST_NOW=21801 _service_health_check_tick        # >1800s in → ceiling passed
assert_eq "past the ceiling the watcher restarts even a still-'building' service" \
    "$(grep -c 'restart jupyter-fix' "$SVC_CALLS")" "1"

# ── CLOCK ORIGIN: the ceiling must actually GET THROUGH svc.sh's guard ───────
# The assertion above only proves we CALLED svc.sh. It passed all through round
# 1 while the call was being REFUSED: svc.sh's cold-build guard ages the build
# from the BUILD PROCESS (etimes), this module ages the incident from
# FIRST_UNHEALTHY, and a build can only start after the service is already
# unhealthy — so at our ceiling the build is always younger than the guard's cap
# and the guard vetoed us. One wasted restart attempt out of three, every time;
# permanent `flapping` (recovery dead) once that offset exceeds the restart
# budget. Two clocks, same 1800s duration, different origins.
#
# We resolve it by deciding ONCE, here, on OUR clock, and telling svc.sh:
# SVC_FORCE=1. These assertions FAIL if that coupling is ever broken.
assert_eq "past the ceiling the watcher FORCES through svc.sh's cold-build guard (clock-origin fix)" \
    "$(grep -c 'restart:jupyter-fix SVC_FORCE=1' "$SVC_FORCE_CALLS")" "1"
assert_eq "the forced restart is the one issued at the ceiling (no un-forced restart of a live build)" \
    "$(grep -c 'restart:jupyter-fix SVC_FORCE=0' "$SVC_FORCE_CALLS")" "0"
stop_build

# A restart with NO live build must NOT be forced: forcing unconditionally would
# silently re-arm the original footgun (an operator/watcher discarding a build
# that is legitimately materialising) if the defer branch above ever regressed.
echo "## a restart with no cold build in flight is NOT forced (the guard stays armed)"
reset_jup
: > "$SVC_FORCE_CALLS"
rm -f "$JOK"                       # unhealthy, but no build process at all
NEXUS_TEST_NOW=30000 _service_health_check_tick        # fresh detection
NEXUS_TEST_NOW=30100 _service_health_check_tick        # past grace → restart
assert_eq "no live build ⇒ watcher does NOT set SVC_FORCE" \
    "$(grep -c 'restart:jupyter-fix SVC_FORCE=0' "$SVC_FORCE_CALLS")" "1"
assert_eq "no live build ⇒ nothing was force-restarted" \
    "$(grep -c 'restart:jupyter-fix SVC_FORCE=1' "$SVC_FORCE_CALLS")" "0"

th_summary_and_exit
