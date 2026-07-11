#!/usr/bin/env bash
# Unit + fixture-tick tests for the version-aware component restart
# (`monitor/watcher/_version_restart.sh`, your-org/your-nexus#186).
#
# Everything runs against a throwaway fixture tree under mktemp — the
# live watcher, live state dir, and live registry are never touched.
# The launcher and svc.sh are capture stubs; the tmux window probe is
# overridden with a flag-file check.
#
# Properties pinned down:
#
#   hashing        deterministic; content-sensitive; missing file ⇒ rc 1
#                  (the torn-pull signal).
#   source sets    watcher set parsed from main.sh's `source` lines
#                  (incl. ../-relative); service script resolved from
#                  the launch command's first file-backed token.
#   state machine  adopt → unchanged → pending → drift; torn never
#                  mutates state; drift requires a STABLE candidate.
#   guards         per-component cooldown; watcher self-restart loop
#                  guard (trip + advisory + window re-arm).
#   tick           per-component isolation (only the changed component
#                  acts), idempotent no-change cycles, restart-once for
#                  services, launcher --replace exactly once for self,
#                  cockpit drift ⇒ ask record and NEVER a direct action,
#                  advise-fallback when a channel is disabled, silent
#                  re-baseline when nothing runs old code.
#   emit section   once per candidate hash (re-nag guard), re-arms on a
#                  new candidate, text carries the actionable commands.
#
# Run: bash monitor/watcher/test-version-restart.sh

set -uo pipefail

_real_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=_test_helpers.sh
. "$_real_dir/_test_helpers.sh"

WORK=$(mktemp -d -t nexus-version-restart-XXXXXX)
SVC_PID=""
cleanup() {
    [[ -n "$SVC_PID" ]] && th_kill_fixture_pid "$SVC_PID" "$WORK" KILL
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---- fixture tree ---------------------------------------------------------
#
# <WORK>/nexus/monitor/{svc.sh? -> stub, bootstrap-recover.sh (real),
#   watcher/{main.sh (fixture), _lib.sh (real), _version_restart.sh
#   (real), _mod_a.sh, _mod_b.sh}}, config/load.sh stub, registry with
# one trackable service, and a live faux service supervisor.
ROOT="$WORK/nexus"
MON="$ROOT/monitor"
WD="$MON/watcher"
STATE="$ROOT/monitor/.state"
VDIR="$STATE/version"
mkdir -p "$WD" "$STATE/services" "$VDIR" "$ROOT/config" "$ROOT/work/svc"

cp "$_real_dir/_version_restart.sh" "$WD/_version_restart.sh"
cp "$_real_dir/_lib.sh"             "$WD/_lib.sh"
cp "$_real_dir/../bootstrap-recover.sh" "$MON/bootstrap-recover.sh"
# _version_restart.sh sources ../_log-mode.sh (nexus-code#509).
cp "$_real_dir/../_log-mode.sh"     "$MON/_log-mode.sh"
chmod +x "$MON/bootstrap-recover.sh"

# Fixture main.sh — two sourced modules plus a ../-relative one, all
# via the canonical `source "$_script_dir/<rel>"` pattern the parser
# keys on. Content is inert; only bytes matter.
cat > "$WD/main.sh" <<'EOF'
#!/usr/bin/env bash
_script_dir=x
source "$_script_dir/_mod_a.sh"
source "$_script_dir/_mod_b.sh"
source "$_script_dir/../_shared.sh"
echo watcher-fixture v1
EOF
printf '#!/usr/bin/env bash\n# mod a v1\n' > "$WD/_mod_a.sh"
printf '#!/usr/bin/env bash\n# mod b v1\n' > "$WD/_mod_b.sh"
printf '#!/usr/bin/env bash\n# shared v1\n' > "$MON/_shared.sh"

# Cockpit source set members the module hashes: svc.sh +
# bootstrap-recover.sh + watcher/_lib.sh + watcher/_version_restart.sh.
# svc.sh here is the ACTION stub too (the tick invokes it for service
# restarts); it records argv and exits 0.
SVC_CAPTURE="$WORK/svc-calls.txt"
cat > "$MON/svc.sh" <<EOF
#!/usr/bin/env bash
# cockpit fixture v1
printf '%s\n' "\$*" >> "$SVC_CAPTURE"
exit 0
EOF
chmod +x "$MON/svc.sh"

# Launcher capture stub (self-restart path).
LAUNCH_CAPTURE="$WORK/launcher-calls.txt"
cat > "$WORK/launcher-stub.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAUNCH_CAPTURE"
exit 0
EOF
chmod +x "$WORK/launcher-stub.sh"

cat > "$ROOT/config/load.sh" <<'EOF'
#!/usr/bin/env bash
echo "${2:-}"
EOF
chmod +x "$ROOT/config/load.sh"

# One trackable service: launch `./serve.sh` in work/svc, healthcheck
# inert. TAB-separated registry row.
# Short sleep slices so a killed wrapper's orphaned child dies within
# ~1 s instead of lingering for the whole suite timeout.
cat > "$ROOT/work/svc/serve.sh" <<'EOF'
#!/usr/bin/env bash
# serve v1
while :; do sleep 1; done
EOF
chmod +x "$ROOT/work/svc/serve.sh"
REGISTRY="$MON/services.registry"
printf 'svcA\t%s\t./serve.sh --port 1\ttrue\t%s\n' \
    "$ROOT/work/svc" "$ROOT/work/svc/serve.log" > "$REGISTRY"

# A live faux supervisor whose cmdline carries `serve.sh` (what
# _recover_service_running matches) and whose pidfile sits where
# bootstrap-recover expects it. I/O fully detached — an inherited
# stdout pipe would hold any `test.sh | tail` runner open until the
# inner `sleep` dies, long after the suite finished.
bash "$ROOT/work/svc/serve.sh" </dev/null >/dev/null 2>&1 &
SVC_PID=$!
echo "$SVC_PID" > "$STATE/services/svcA.pid"
sleep 0.2

# Source the FIXTURE module copy (the real file, fixture location — so
# _VERSION_MODULE_DIR resolves inside the fixture tree).
# shellcheck source=_version_restart.sh
source "$WD/_version_restart.sh"

# tmux probe override: window "present" iff the flag file exists.
COCKPIT_FLAG="$WORK/cockpit-window-present"
_version_window_exists() { [[ -f "$COCKPIT_FLAG" ]]; }
# Window-ID resolver stubbed alongside (never touch the live tmux
# server from a fixture): present window resolves to a fixed id.
_version_window_id() { [[ -f "$COCKPIT_FLAG" ]] && printf '@77'; }

# Tick invocation helper: pins every global the tick consumes to the
# fixture, with per-call overrides via leading VAR=val args.
run_tick() {
    local -a overrides=()
    while (( $# > 0 )); do
        case "$1" in
            *=*) overrides+=("$1"); shift ;;
            *) break ;;
        esac
    done
    local kv
    for kv in \
        "VERSION_STATE_DIR=$VDIR" \
        "NEXUS_ROOT=$ROOT" \
        "NEXUS_SERVICES_REGISTRY=$REGISTRY" \
        "TARGET=orch-test" \
        "LOGFILE=$WORK/watcher-fixture.log" \
        "MONITOR_VERSION_SETTLE_SECONDS=0" \
        "MONITOR_VERSION_RESTART_COOLDOWN_SECONDS=600" \
        "MONITOR_VERSION_SELF_RESTART=true" \
        "MONITOR_VERSION_SERVICE_RESTART=true" \
        "MONITOR_VERSION_SELF_LOOP_LIMIT=3" \
        "MONITOR_VERSION_SELF_LOOP_WINDOW_SECONDS=3600" \
        "MONITOR_COCKPIT_WINDOW=services" \
        "_VERSION_LAUNCHER_BIN=$WORK/launcher-stub.sh" \
        "_VERSION_SVC_BIN=$MON/svc.sh" \
        "${overrides[@]}"; do
        export "${kv?}"
    done
    _version_check_tick 2>>"$WORK/tick.log"
}

count_lines() { [[ -f "$1" ]] && wc -l < "$1" | tr -d ' ' || echo 0; }

# =====================================================================
echo '=== hashing primitives ==='

f1="$WORK/h1"; f2="$WORK/h2"
printf 'alpha\n' > "$f1"; printf 'beta\n' > "$f2"
h_a=$(_version_hash_files "$f1" "$f2")
h_b=$(_version_hash_files "$f1" "$f2")
assert_eq "hash is deterministic" "$h_a" "$h_b"
printf 'alpha CHANGED\n' > "$f1"
h_c=$(_version_hash_files "$f1" "$f2")
[[ "$h_c" != "$h_a" ]] \
    && { printf '  PASS: hash changes with content\n'; PASS=$((PASS+1)); } \
    || { printf '  FAIL: hash unchanged after edit\n' >&2; FAIL=$((FAIL+1)); }
out=$(_version_hash_files "$f1" "$WORK/does-not-exist" 2>/dev/null); rc=$?
assert_eq "missing file => rc 1 (torn)" "$rc" "1"
assert_empty "missing file => no output" "$out"

echo '=== watcher source set ==='
set_out=$(_version_watcher_source_set "$WD/main.sh")
assert_contains "set includes main.sh"   "$set_out" "$WD/main.sh"
assert_contains "set includes _mod_a.sh" "$set_out" "$WD/_mod_a.sh"
assert_contains "set includes _mod_b.sh" "$set_out" "$WD/_mod_b.sh"
assert_contains "set includes ../-relative module" "$set_out" "$WD/../_shared.sh"
assert_eq "set has exactly 4 entries" "$(printf '%s\n' "$set_out" | wc -l | tr -d ' ')" "4"

echo '=== service script resolver ==='
got=$(_version_service_script "$ROOT/work/svc" "./serve.sh --port 1")
assert_eq "./serve.sh resolves under workdir" "$got" "$ROOT/work/svc/./serve.sh"
got=$(_version_service_script "$ROOT/work/svc" "bash serve.sh")
assert_eq "interpreter-prefixed launch resolves the script" "$got" "$ROOT/work/svc/serve.sh"
got=$(_version_service_script "$ROOT/work/svc" "FOO=1 ./serve.sh")
assert_eq "leading env assignment is skipped" "$got" "$ROOT/work/svc/./serve.sh"
if _version_service_script "$ROOT/work/svc" "python -m http.server" >/dev/null 2>&1; then
    printf '  FAIL: file-less launch should be untrackable (rc 1)\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: file-less launch => rc 1 (not version-managed)\n'; PASS=$((PASS+1))
fi

echo '=== drift state machine ==='
SM="$WORK/sm-state"; mkdir -p "$SM"
v=$(_version_check_component "$SM" demo AAAA 10 1000)
assert_eq "first sight adopts" "$v" "adopted"
assert_eq "adopt recorded running hash" "$(_version_field "$SM/demo.running" hash)" "AAAA"
v=$(_version_check_component "$SM" demo AAAA 10 1001)
assert_eq "same hash => unchanged" "$v" "unchanged"
v=$(_version_check_component "$SM" demo BBBB 10 1002)
assert_eq "new hash => pending (not yet stable)" "$v" "pending"
v=$(_version_check_component "$SM" demo BBBB 10 1005)
assert_eq "still inside settle window => pending" "$v" "pending"
v=$(_version_check_component "$SM" demo BBBB 10 1012)
assert_eq "stable past settle => drift" "$v" "drift"
v=$(_version_check_component "$SM" demo CCCC 10 1013)
assert_eq "candidate moved again => pending restarts" "$v" "pending"
assert_eq "pending tracks the new candidate" "$(_version_field "$SM/demo.pending" hash)" "CCCC"
before=$(cat "$SM/demo.pending")
v=$(_version_check_component "$SM" demo TORN 10 1014)
assert_eq "torn verdict" "$v" "torn"
assert_eq "torn leaves pending untouched" "$(cat "$SM/demo.pending")" "$before"
assert_eq "torn leaves running untouched" "$(_version_field "$SM/demo.running" hash)" "AAAA"
# convergence clears pending + a stale drift record
printf 'component=demo\nnew=CCCC\n' > "$SM/drift-demo"
printf 'CCCC\n' > "$SM/drift-demo-surfaced"
v=$(_version_check_component "$SM" demo AAAA 10 1015)
assert_eq "back to running hash => unchanged" "$v" "unchanged"
assert_no_file "convergence clears pending" "$SM/demo.pending"
assert_no_file "convergence clears stale drift record" "$SM/drift-demo"
assert_no_file "convergence clears surfaced marker" "$SM/drift-demo-surfaced"
# adopt-at-ask shape: a record whose candidate EQUALS running must
# SURVIVE unchanged ticks (cleared only by orchestrator ack / newer
# candidate) — it represents an un-acted ask, not a converged one.
printf 'component=demo\nnew=AAAA\n' > "$SM/drift-demo"
v=$(_version_check_component "$SM" demo AAAA 10 1016)
assert_eq "unchanged with matching record" "$v" "unchanged"
assert_file_exists "adopt-at-ask record survives unchanged ticks" "$SM/drift-demo"
rm -f "$SM/drift-demo"

echo '=== cooldown ==='
CD="$WORK/cd-state"; mkdir -p "$CD"
_version_cooldown_ok "$CD" comp 600 "$(date +%s)" \
    && { printf '  PASS: no stamp => action allowed\n'; PASS=$((PASS+1)); } \
    || { printf '  FAIL: no stamp blocked action\n' >&2; FAIL=$((FAIL+1)); }
_version_stamp_cooldown "$CD" comp
if _version_cooldown_ok "$CD" comp 600 "$(date +%s)"; then
    printf '  FAIL: fresh stamp should block\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: fresh stamp blocks inside window\n'; PASS=$((PASS+1))
fi
touch -d '20 minutes ago' "$CD/comp.restart.last"
_version_cooldown_ok "$CD" comp 600 "$(date +%s)" \
    && { printf '  PASS: aged stamp re-allows\n'; PASS=$((PASS+1)); } \
    || { printf '  FAIL: aged stamp still blocks\n' >&2; FAIL=$((FAIL+1)); }

echo '=== self-restart loop guard ==='
LG="$WORK/lg-state"; mkdir -p "$LG"
now=$(date +%s)
_version_self_guard_ok "$LG" 3 3600 "$now" \
    && { printf '  PASS: empty history => allowed\n'; PASS=$((PASS+1)); } \
    || { printf '  FAIL: empty history blocked\n' >&2; FAIL=$((FAIL+1)); }
printf '%s\n%s\n%s\n' "$((now-100))" "$((now-50))" "$((now-10))" \
    > "$LG/self-restart-history.txt"
if _version_self_guard_ok "$LG" 3 3600 "$now" 2>/dev/null; then
    printf '  FAIL: 3 restarts in window should trip\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: limit reached => guard trips\n'; PASS=$((PASS+1))
fi
assert_file_exists "trip writes tripped stamp" "$LG/self-restart-tripped"
assert_file_exists "trip writes drift-watcher advisory" "$LG/drift-watcher"
assert_contains "advisory names the trip" "$(cat "$LG/drift-watcher")" "guard tripped"
if _version_self_guard_ok "$LG" 3 3600 "$now" 2>/dev/null; then
    printf '  FAIL: tripped guard should keep blocking\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: tripped guard keeps blocking inside window\n'; PASS=$((PASS+1))
fi
touch -d '2 hours ago' "$LG/self-restart-tripped"
_version_self_guard_ok "$LG" 3 3600 "$now" 2>/dev/null \
    && { printf '  PASS: quiet full window re-arms the guard\n'; PASS=$((PASS+1)); } \
    || { printf '  FAIL: aged trip did not re-arm\n' >&2; FAIL=$((FAIL+1)); }
assert_no_file "re-arm clears tripped stamp" "$LG/self-restart-tripped"

echo '=== launch-time service version stamp ==='
LS="$WORK/ls-state"; mkdir -p "$LS"
_version_record_service_running "$LS" svcA "$ROOT/work/svc" "./serve.sh --port 1"
want=$(_version_hash_files "$ROOT/work/svc/./serve.sh")
assert_eq "launch stamp matches script hash" \
    "$(_version_field "$LS/service-svcA.running" hash)" "$want"
_version_record_service_running "$LS" svcB "$ROOT/work/svc" "python -m nothing" \
    && { printf '  PASS: untrackable launch is a benign no-op\n'; PASS=$((PASS+1)); } \
    || { printf '  FAIL: untrackable launch errored\n' >&2; FAIL=$((FAIL+1)); }
assert_no_file "untrackable launch writes nothing" "$LS/service-svcB.running"

echo '=== emit section (re-nag guard) ==='
EM="$WORK/em-state"; mkdir -p "$EM"
_version_write_drift_record "$EM" cockpit OLDHASH NEWHASH "cockpit running old code" services
sec1=$(_version_emit_section "$EM" "$ROOT"); rc1=$?
sec2=$(_version_emit_section "$EM" "$ROOT"); rc2=$?
assert_eq "first emit rc 0" "$rc1" "0"
assert_contains "section names the cockpit window" "$sec1" "'services'"
assert_contains "section states the no-kill contract" "$sec1" "will NOT touch"
assert_contains "section carries the restart command" "$sec1" "monitor/svc.sh"
assert_contains "section carries the ack path" "$sec1" "rm $EM/drift-cockpit"
assert_eq "second emit silent (re-nag guarded)" "$rc2" "1"
assert_empty "second emit body empty" "$sec2"
# No window_id recorded (pre-feature record / resolver failed): the
# recipe falls back to the name — never breaks on old drift files.
assert_contains "id-less record: kill targets the window name" "$sec1" "tmux kill-window -t services"
# ID-targeted recipe (2026-06-11 incident: a name/index-aimed kill from
# the orchestrator destroyed the orchestrator's own window): with a
# window_id recorded, the surfaced kill targets the immutable @id.
EM_ID="$WORK/em-id-state"; mkdir -p "$EM_ID"
_version_write_drift_record "$EM_ID" cockpit OLDHASH NEWHASH "cockpit running old code" services '@42'
sec_id=$(_version_emit_section "$EM_ID" "$ROOT")
assert_contains "id record: kill targets the window ID" "$sec_id" "tmux kill-window -t @42"
assert_contains "id record: new-window still uses the name" "$sec_id" "new-window -dn services"
assert_contains "id record: recipe explains the ID targeting" "$sec_id" "window ID of 'services'"
_version_write_drift_record "$EM" cockpit OLDHASH NEWERHASH "cockpit running old code" services
sec3=$(_version_emit_section "$EM" "$ROOT")
assert_contains "new candidate re-arms surfacing" "$sec3" "NEWERHASH"
_version_write_drift_record "$EM" watcher "" "guard-tripped-1" "self-restart guard tripped: 3 auto-restarts within 3600s"
sec4=$(_version_emit_section "$EM" "$ROOT")
assert_contains "watcher advisory points at svc.sh restart watcher" "$sec4" "svc.sh restart watcher"
_version_write_drift_record "$EM" service-svcA AA BB "auto service restart disabled (monitor.version_restart.services=false)"
sec5=$(_version_emit_section "$EM" "$ROOT")
assert_contains "service advisory names the service" "$sec5" "'svcA'"
assert_contains "service advisory carries restart verb" "$sec5" "svc.sh restart svcA"

# =====================================================================
echo '=== tick: adoption + idempotent no-change cycles ==='

run_tick
assert_eq "adopt tick: watcher running recorded" \
    "$(_version_field "$VDIR/watcher.running" hash)" \
    "$(_version_hash_files $(_version_watcher_source_set "$WD/main.sh"))"
assert_file_exists "adopt tick: cockpit running recorded" "$VDIR/cockpit.running"
assert_file_exists "adopt tick: service running recorded" "$VDIR/service-svcA.running"
run_tick
run_tick
assert_eq "no-change cycles: launcher never invoked" "$(count_lines "$LAUNCH_CAPTURE")" "0"
assert_eq "no-change cycles: svc.sh never invoked" "$(count_lines "$SVC_CAPTURE")" "0"
assert_no_file "no-change cycles: no watcher pending" "$VDIR/watcher.pending"
assert_no_file "no-change cycles: no drift records" "$VDIR/drift-cockpit"

echo '=== tick: torn watcher source set => no action, no pending ==='
mv "$WD/_mod_b.sh" "$WD/_mod_b.sh.away"
run_tick
run_tick
assert_eq "torn: launcher never invoked" "$(count_lines "$LAUNCH_CAPTURE")" "0"
assert_no_file "torn: no pending state created" "$VDIR/watcher.pending"
mv "$WD/_mod_b.sh.away" "$WD/_mod_b.sh"
run_tick
assert_eq "restored set: still no launcher call" "$(count_lines "$LAUNCH_CAPTURE")" "0"

echo '=== tick: service drift => svc.sh restart exactly once; others untouched ==='
printf '#!/usr/bin/env bash\n# serve v2\nsleep 300\n' > "$ROOT/work/svc/serve.sh"
run_tick   # observes change -> pending
assert_eq "service pending after first observation" \
    "$(count_lines "$SVC_CAPTURE")" "0"
run_tick   # stable -> drift -> restart
assert_eq "service restart fired exactly once" "$(count_lines "$SVC_CAPTURE")" "1"
assert_contains "restart used the svc.sh verb" "$(cat "$SVC_CAPTURE")" "restart svcA"
assert_eq "watcher channel untouched by service drift" "$(count_lines "$LAUNCH_CAPTURE")" "0"
assert_no_file "no cockpit ask from service drift" "$VDIR/drift-cockpit"
run_tick
assert_eq "post-restart cycles do not re-fire" "$(count_lines "$SVC_CAPTURE")" "1"

echo '=== tick: cockpit drift => ask record, no kill, no other channel ==='
touch "$COCKPIT_FLAG"
printf '#!/usr/bin/env bash\n# cockpit fixture v2\nprintf "%%s\\n" "$*" >> %q\nexit 0\n' \
    "$SVC_CAPTURE" > "$MON/svc.sh"
run_tick   # pending
run_tick   # drift -> ask
assert_file_exists "cockpit ask record written" "$VDIR/drift-cockpit"
assert_contains "ask names the cockpit window" "$(cat "$VDIR/drift-cockpit")" "window=services"
assert_contains "ask records the resolved window ID" "$(cat "$VDIR/drift-cockpit")" "window_id=@77"
assert_eq "cockpit drift never invokes the launcher" "$(count_lines "$LAUNCH_CAPTURE")" "0"
assert_eq "cockpit drift never invokes svc.sh" "$(count_lines "$SVC_CAPTURE")" "1"
assert_eq "cockpit baseline advanced to candidate" \
    "$(_version_field "$VDIR/cockpit.running" hash)" \
    "$(_version_hash_files $(_version_cockpit_source_set "$MON"))"
run_tick
assert_eq "cockpit ask is one-shot (no churn)" \
    "$(_version_field "$VDIR/drift-cockpit" new)" \
    "$(_version_hash_files $(_version_cockpit_source_set "$MON"))"

echo '=== tick: cockpit drift with NO window => silent re-baseline ==='
rm -f "$COCKPIT_FLAG" "$VDIR/drift-cockpit" "$VDIR/drift-cockpit-surfaced" \
      "$VDIR/cockpit.restart.last"
printf '#!/usr/bin/env bash\n# cockpit fixture v3\nprintf "%%s\\n" "$*" >> %q\nexit 0\n' \
    "$SVC_CAPTURE" > "$MON/svc.sh"
run_tick; run_tick
assert_no_file "no window => no ask record" "$VDIR/drift-cockpit"
assert_eq "no window => baseline still advanced" \
    "$(_version_field "$VDIR/cockpit.running" hash)" \
    "$(_version_hash_files $(_version_cockpit_source_set "$MON"))"

echo '=== tick: watcher drift => launcher --replace once; cooldown gates retry ==='
printf '#!/usr/bin/env bash\n# mod a v2\n' > "$WD/_mod_a.sh"
run_tick   # pending
assert_eq "watcher pending after first observation" "$(count_lines "$LAUNCH_CAPTURE")" "0"
run_tick   # drift -> self-restart
assert_eq "self-restart launched exactly once" "$(count_lines "$LAUNCH_CAPTURE")" "1"
assert_contains "launcher invoked with --replace + target" \
    "$(cat "$LAUNCH_CAPTURE")" "--replace --target orch-test"
assert_eq "service channel untouched by watcher drift" "$(count_lines "$SVC_CAPTURE")" "1"
assert_file_exists "self-restart recorded in history" "$VDIR/self-restart-history.txt"
assert_file_exists "self-restart stamped cooldown" "$VDIR/watcher.restart.last"
# The stub launcher did NOT actually replace us, so the drift persists:
# the cooldown must hold the retry rate down (no thrash).
run_tick; run_tick
assert_eq "persistent drift inside cooldown does NOT re-fire" \
    "$(count_lines "$LAUNCH_CAPTURE")" "1"
touch -d '20 minutes ago' "$VDIR/watcher.restart.last"
run_tick
assert_eq "after cooldown the retry fires once more" "$(count_lines "$LAUNCH_CAPTURE")" "2"

echo '=== tick: loop guard suspends self-restart ==='
now=$(date +%s)
printf '%s\n%s\n%s\n' "$((now-300))" "$((now-200))" "$((now-100))" \
    > "$VDIR/self-restart-history.txt"
touch -d '20 minutes ago' "$VDIR/watcher.restart.last"
rm -f "$VDIR/drift-watcher" "$VDIR/drift-watcher-surfaced"
run_tick
assert_eq "tripped guard blocks the launcher" "$(count_lines "$LAUNCH_CAPTURE")" "2"
assert_file_exists "guard trip leaves the advisory record" "$VDIR/drift-watcher"
assert_file_exists "guard trip stamps tripped" "$VDIR/self-restart-tripped"

echo '=== tick: disabled channels degrade to advisories ==='
# self disabled: converge state first (clear guard + adopt current).
rm -f "$VDIR/self-restart-tripped" "$VDIR/drift-watcher" "$VDIR/drift-watcher-surfaced"
: > "$VDIR/self-restart-history.txt"
printf '#!/usr/bin/env bash\n# mod a v3\n' > "$WD/_mod_a.sh"
touch -d '20 minutes ago' "$VDIR/watcher.restart.last"
run_tick   # pending on v3
run_tick MONITOR_VERSION_SELF_RESTART=false
assert_eq "self disabled: launcher not invoked" "$(count_lines "$LAUNCH_CAPTURE")" "2"
assert_file_exists "self disabled: advisory written" "$VDIR/drift-watcher"
assert_contains "self disabled: advisory says why" \
    "$(cat "$VDIR/drift-watcher")" "monitor.version_restart.self=false"
assert_eq "self disabled: candidate adopted (advise once)" \
    "$(_version_field "$VDIR/watcher.running" hash)" \
    "$(_version_hash_files $(_version_watcher_source_set "$WD/main.sh"))"
# services disabled
printf '#!/usr/bin/env bash\n# serve v3\nsleep 300\n' > "$ROOT/work/svc/serve.sh"
touch -d '20 minutes ago' "$VDIR/service-svcA.restart.last"
run_tick MONITOR_VERSION_SERVICE_RESTART=false   # pending
run_tick MONITOR_VERSION_SERVICE_RESTART=false   # drift -> advisory
assert_eq "services disabled: svc.sh not invoked" "$(count_lines "$SVC_CAPTURE")" "1"
assert_file_exists "services disabled: advisory written" "$VDIR/drift-service-svcA"
assert_contains "services disabled: advisory says why" \
    "$(cat "$VDIR/drift-service-svcA" 2>/dev/null || echo MISSING)" \
    "monitor.version_restart.services=false"

echo '=== tick: dead supervisor => silent re-baseline, no restart ==='
th_kill_own_child "$SVC_PID" KILL || true
wait "$SVC_PID" 2>/dev/null || true
SVC_PID=""
printf '#!/usr/bin/env bash\n# serve v4\nsleep 300\n' > "$ROOT/work/svc/serve.sh"
rm -f "$VDIR/drift-service-svcA" "$VDIR/drift-service-svcA-surfaced"
run_tick; run_tick
assert_eq "dead supervisor: svc.sh not invoked" "$(count_lines "$SVC_CAPTURE")" "1"
assert_eq "dead supervisor: baseline adopted silently" \
    "$(_version_field "$VDIR/service-svcA.running" hash)" \
    "$(_version_hash_files "$ROOT/work/svc/./serve.sh")"
assert_no_file "dead supervisor: no ask record" "$VDIR/drift-service-svcA"

th_summary_and_exit
