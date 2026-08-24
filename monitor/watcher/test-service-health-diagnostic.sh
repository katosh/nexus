#!/usr/bin/env bash
# Tests for the service-health DIAGNOSTIC capture (your-org/nexus-code#637):
# _service_health.sh must carry a FAILING healthcheck's stderr verdict into the
# orchestrator emit, so the emit can DISTINGUISH failure causes a bare "unhealthy"
# hides. The motivating case is nexus-remote-ssh: remote-ssh-health.sh already
# classifies "OUR daemon is DOWN" vs "the port is held by a FOREIGN listener" (the
# #609 identity gate) and writes that verdict to stderr — but the watcher used to
# discard stderr, so the emit could not tell the operator which one it was.
#
# The negative control is the whole point: a FOREIGN-reason healthcheck and a
# DOWN-reason healthcheck must produce DIFFERENT emits (one says foreign, one
# says down), and a SILENT healthcheck must produce NO fabricated diagnostic.
#
# Hermetic: the module is aimed at a throwaway fixture tree; the healthcheck is a
# stub whose stderr we control. No sshd, no network, deterministic clock.
#
# Run: bash monitor/watcher/test-service-health-diagnostic.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_real_monitor=$(cd "$_real_dir/.." && pwd)
. "$_real_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-sh-diag-XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

ROOT="$WORK/nexus"
STATE="$ROOT/monitor/.state"
SHDIR="$STATE/service-health"
WD="$WORK/wd"
mkdir -p "$STATE" "$SHDIR" "$WD" "$ROOT/monitor"
REGISTRY="$WORK/services.registry"
echo "fixture service log" > "$WD/serve.log"

# Healthcheck stub whose behaviour we drive via files:
#   $WORK/healthy present ⇒ exit 0 (silent, passing)
#   else                  ⇒ cat $WORK/reason (may be empty) to STDERR, exit 1
HSTUB="$WORK/health-stub.sh"
cat > "$HSTUB" <<EOF
#!/usr/bin/env bash
if [[ -f "$WORK/healthy" ]]; then exit 0; fi
[[ -s "$WORK/reason" ]] && cat "$WORK/reason" >&2
exit 1
EOF
chmod +x "$HSTUB"

# emit-only, so the failing path escalates rather than shelling out to a restart.
printf 'remotelike\t%s\tbash ./launch.sh\tbash %s\t%s/serve.log\temit-only\n' \
    "$WD" "$HSTUB" "$WD" > "$REGISTRY"

export NEXUS_ROOT="$ROOT"
export STATE_DIR="$STATE"
export SERVICE_HEALTH_STATE_DIR="$SHDIR"
export NEXUS_SERVICES_REGISTRY="$REGISTRY"
export MONITOR_SERVICE_HEALTH_DEFAULT_POLICY=emit-only

# shellcheck source=_service_health.sh
. "$_real_dir/_service_health.sh"

reset_state() { rm -rf "$SHDIR"; mkdir -p "$SHDIR"; rm -f "$WORK/healthy"; : > "$WORK/reason"; }
SF="$SHDIR/remotelike.state"

# MULTI-LINE, mimicking the REAL remote-ssh-health.sh: the verdict is on the
# FIRST line and indented detail (the socket attribution) follows on the LAST —
# so a positional `tail -n1` capture would grab the attribution and DROP the
# foreign-vs-down verdict. This is the #637 skeptic finding; the fixture must be
# multi-line or the test cannot catch it.
FOREIGN='remote-ssh-health: UNHEALTHY — a FOREIGN sshd holds 127.0.0.1:22022 — it presents SHA256:aaaa, ours is SHA256:bbbb
remote-ssh-health:   OUR channel is DOWN; the endpoint is being served by something else.
remote-ssh-health:   socket owner uid:65534 with NO pid attribution — outside this namespace. Do NOT signal it.'
DOWN='remote-ssh-health: UNHEALTHY — no listener on 127.0.0.1:22022
remote-ssh-health:   something IS answering, so that listener is not ours.'

# ===========================================================================
echo "## A. FOREIGN-holds-port reason is CAPTURED and reaches the emit (grace=0 ⇒ emit-only)"
reset_state
printf '%s\n' "$FOREIGN" > "$WORK/reason"
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=0
NEXUS_TEST_NOW=1000 _service_health_check_tick
assert_file_exists "incident .state created" "$SF"
assert_eq       "status=emit-only (grace=0)" "$(_sh_field "$SF" status)" "emit-only"
detail=$(_sh_field "$SF" health_detail 2>/dev/null || echo '')
assert_contains "state file captures the VERDICT line (first), not the attribution (last)" "$detail" "FOREIGN sshd holds"
assert_not_contains "…the capture is NOT the last (attribution) line — the tail-n1 bug" "$detail" "socket owner uid:65534"
emitA=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains "emit surfaces a diagnostic line" "$emitA" "diagnostic:"
assert_contains "…naming the FOREIGN-listener cause (not just 'unhealthy')" "$emitA" "FOREIGN sshd holds"

# ===========================================================================
echo
echo "## B. DOWN reason is DISTINGUISHABLE from foreign (the negative control)"
reset_state
printf '%s\n' "$DOWN" > "$WORK/reason"
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=0
NEXUS_TEST_NOW=2000 _service_health_check_tick
emitB=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains     "emit surfaces the DOWN diagnostic" "$emitB" "no listener on"
assert_not_contains "…and it is NOT the foreign message (the two are distinguishable)" "$emitB" "FOREIGN sshd holds"

# ===========================================================================
echo
echo "## C. a SILENT failing healthcheck ⇒ NO fabricated diagnostic line"
reset_state
: > "$WORK/reason"                       # healthcheck exits 1 with NO stderr
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=0
NEXUS_TEST_NOW=3000 _service_health_check_tick
emitC=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains     "still reports the service DOWN" "$emitC" "DOWN since"
assert_not_contains "no diagnostic line when the healthcheck is silent" "$emitC" "diagnostic:"

# ===========================================================================
echo
echo "## D. the GRACE emit also carries the diagnostic (surfaced before escalation)"
reset_state
printf '%s\n' "$FOREIGN" > "$WORK/reason"
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=30
NEXUS_TEST_NOW=4000 _service_health_check_tick          # elapsed 0 < grace ⇒ grace
assert_eq       "status=grace" "$(_sh_field "$SF" status)" "grace"
emitD=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null)
assert_contains "grace emit carries the diagnostic too" "$emitD" "diagnostic:"
assert_contains "…still naming the foreign cause" "$emitD" "FOREIGN sshd holds"

# ===========================================================================
echo
echo "## E. a HEALTHY service leaves no diagnostic (no detail leak, no incident)"
reset_state
touch "$WORK/healthy"
export MONITOR_SERVICE_HEALTH_GRACE_SECONDS=0
NEXUS_TEST_NOW=5000 _service_health_check_tick
assert_no_file "healthy ⇒ no incident .state" "$SF"
emitE=$(_service_health_emit_section "$SHDIR" "$ROOT" 2>/dev/null); erc=$?
assert_empty   "healthy ⇒ empty emit" "$emitE"

th_summary_and_exit
