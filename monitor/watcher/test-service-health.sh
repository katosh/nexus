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
: > "$SVC_CALLS"

# Capture stub for svc.sh: log the verb+name, optionally fix the service.
SVC_STUB="$WORK/svc-stub.sh"
cat > "$SVC_STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SVC_CALLS"
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

th_summary_and_exit
