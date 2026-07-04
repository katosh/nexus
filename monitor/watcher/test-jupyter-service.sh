#!/usr/bin/env bash
# Unit tests for the JupyterLab-as-a-service layer:
#   monitor/jupyter-up.sh        (activation / --down / --status / --no-start)
#   monitor/labsh-supervised.sh  (watchdog: bounce, port-follow, adoption)
#   monitor/jupyter-health.sh    (authenticated probe)
#
# Hermetic: labsh is a PATH-shadow stub whose `start` spawns a real
# token-checking HTTP server (python3) on a free port with labsh's
# auto-increment semantics, so health/bounce/port-follow are exercised
# against real sockets without uv, venvs, or JupyterLab. Registry and
# state are fixture-local (NEXUS_SERVICES_REGISTRY / NEXUS_STATE_DIR) —
# the operator's live registry is never touched.
#
# Run: bash monitor/watcher/test-jupyter-service.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

MON_DIR=$(cd "$_test_dir/.." && pwd)
UP="$MON_DIR/jupyter-up.sh"
HEALTH="$MON_DIR/jupyter-health.sh"
SUP="$MON_DIR/labsh-supervised.sh"
RECOVER="$MON_DIR/bootstrap-recover.sh"

WORK=$(mktemp -d -t nexus-jupyter-svc-XXXXXX)
# Kill any supervisors/stub servers the fixtures leave behind, by
# recorded pidfile/pid — never by pattern (self-kill hazard).
cleanup() {
    local pf pid
    for pf in "$WORK"/state/services/*.pid "$WORK"/proj*/.jupyter/stub.pid "$WORK"/elsewhere/proj1/.jupyter/stub.pid "$WORK"/rootws/.jupyter/stub.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null; }
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
# Fast watchdog so bounce tests finish in seconds.
export LABSH_SVC_INTERVAL=1
export LABSH_SVC_FAILS=2
export LABSH_UP_TIMEOUT=30
# Fast periodic hook so the root-mode re-crawl test finishes in seconds.
export LABSH_SVC_PERIODIC_EVERY=3

mkdir -p "$WORK/state" "$WORK/proj1" "$WORK/proj2" "$WORK/elsewhere/proj1"

# --- stub labsh + stub uv ----------------------------------------------------
STUBS="$WORK/stub-bin"
mkdir -p "$STUBS"

# Token-checking HTTP server: 200 on /api/status with the token given
# AT START (argv — mirrors real jupyter holding JUPYTER_TOKEN from
# launch, which is what makes rotate-then-bounce testable), 403 else.
cat > "$STUBS/stub-server.py" <<'PY'
import http.server, sys, os
PORT, TOKEN = int(sys.argv[1]), sys.argv[2]
# Optional warmup gate: while this file EXISTS, /api/status answers 403 even
# with the right token — models a server that has bound the port (so the URL
# resolves) but is still importing extensions and not yet serving the API.
# Used to exercise start_server's post-start health grace.
GATE = sys.argv[3] if len(sys.argv) > 3 else None
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        warming = GATE is not None and os.path.exists(GATE)
        ok = (not warming) and self.path == '/api/status' and \
             self.headers.get('Authorization') == 'token ' + TOKEN
        self.send_response(200 if ok else 403)
        self.end_headers()
        self.wfile.write(b'{}' if ok else b'forbidden')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY

cat > "$STUBS/labsh" <<STUB
#!/usr/bin/env bash
# Stub labsh: project-local state under \$PWD/.jupyter, same contract
# as the real one for the surface the service layer touches — including
# the JUPYTER_CONFIG_DIR override labsh honours (what labsh-root.sh
# relies on to target the root session from a project dir).
set -uo pipefail
J="\${JUPYTER_CONFIG_DIR:-\$PWD/.jupyter}"
SERVER_PY="$STUBS/stub-server.py"
alive() { [[ -f "\$J/stub.pid" ]] && kill -0 "\$(cat "\$J/stub.pid")" 2>/dev/null; }
case "\${1:-}" in
  start)
    shift
    if alive; then echo "labsh-stub: server is already running" >&2; exit 1; fi
    port=8888
    while (( \$# > 0 )); do case "\$1" in --port) port="\$2"; shift 2 ;; *) echo "\$1" >> "\$J/stub-start-args"; shift ;; esac; done
    mkdir -p "\$J"
    [[ -f "\$J/token" ]] || printf 'stubtok-%s' "\$RANDOM" > "\$J/token"
    # labsh auto-increment: first free port in [port, port+9]
    port=\$(python3 - "\$port" <<'EOF'
import socket, sys
p = int(sys.argv[1])
for q in range(p, p + 10):
    s = socket.socket()
    try: s.bind(('127.0.0.1', q)); s.close(); print(q); break
    except OSError: s.close()
EOF
)
    [[ -n "\$port" ]] || { echo "labsh-stub: no free port" >&2; exit 1; }
    python3 "\$SERVER_PY" "\$port" "\$(cat "\$J/token")" "\$J/.warming" >/dev/null 2>&1 &
    echo \$! > "\$J/stub.pid"; echo "\$port" > "\$J/stub.port"
    echo \$(( \$(cat "\$J/stub-start-count" 2>/dev/null || echo 0) + 1 )) > "\$J/stub-start-count"
    for i in \$(seq 1 20); do curl -fs -o /dev/null "http://127.0.0.1:\$port/x" 2>/dev/null && break; sleep 0.1; done
    echo "labsh-stub: running at http://127.0.0.1:\$port/" >&2
    ;;
  url)
    alive || { echo "labsh-stub: no running server" >&2; exit 1; }
    echo "http://127.0.0.1:\$(cat "\$J/stub.port")/lab?token=\$(cat "\$J/token")"
    ;;
  stop)
    if [[ -f "\$J/stub.pid" ]]; then kill "\$(cat "\$J/stub.pid")" 2>/dev/null; rm -f "\$J/stub.pid"; fi
    ;;
  status) alive && echo "server up" || echo "no server" ;;
  token)  cat "\$J/token" 2>/dev/null ;;
  kernel)
    shift
    sub="\${1:-}"; shift || true
    mkdir -p "\$J"
    echo "\$sub \$*" >> "\$J/stub-kernel-calls"
    case "\$sub" in
      add)      mkdir -p "\$PWD/.venv" "\$J/share/jupyter/kernels/stub"; echo '{}' > "\$J/share/jupyter/kernels/stub/kernel.json" ;;
      register)
        # Same argv contract as real ipykernel install: argv[0] is the
        # project venv's python (what the crawl's skip/prune logic parses).
        proj='' name='' ldarg='__NONE__'
        while (( \$# > 0 )); do case "\$1" in
          --project)         proj="\${2%/}"; shift 2 ;;
          --name)            name="\$2"; shift 2 ;;
          --ld-library-path) ldarg="\$2"; shift 2 ;;
          *)                 shift ;;
        esac; done
        [[ -n "\$name" ]] || name="\$(basename "\${proj:-reg}")"
        mkdir -p "\$J/share/jupyter/kernels/\$name"
        printf '{"argv": ["%s/.venv/bin/python", "-m", "ipykernel_launcher", "-f", "{connection_file}"]}\n' \
            "\$proj" > "\$J/share/jupyter/kernels/\$name/kernel.json"
        # Record the --ld-library-path arg and the env the crawl invoked
        # register UNDER, so the Lmod-path tests can assert the module LD was
        # passed and PYTHONPATH cleared.
        printf 'name=%s ld_arg=%s ld_env=%s pythonpath=%s\n' \
            "\$name" "\$ldarg" "\${LD_LIBRARY_PATH:-__EMPTY__}" "\${PYTHONPATH-__UNSET__}" \
            >> "\$J/stub-register-env"
        ;;
      list)     ls "\$J/share/jupyter/kernels" 2>/dev/null ;;
    esac
    ;;
  *) echo "labsh-stub: unhandled verb: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$STUBS/labsh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBS/uv"; chmod +x "$STUBS/uv"
export PATH="$STUBS:$PATH"

wait_for() {  # wait_for <label> <deadline-s> -- cmd...
    local label="$1" deadline="$2"; shift 3
    local t=0
    while (( t < deadline * 4 )); do
        "$@" >/dev/null 2>&1 && { printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); return 0; }
        sleep 0.25; t=$(( t + 1 ))
    done
    printf '  FAIL: %s (deadline %ss)\n' "$label" "$deadline" >&2; FAIL=$(( FAIL + 1 )); return 1
}

reg_rows() { grep -c . "$NEXUS_SERVICES_REGISTRY" 2>/dev/null || echo 0; }
sup_pid()  { cat "$NEXUS_STATE_DIR/services/$1.pid" 2>/dev/null; }

# wait_gone <label> <deadline-s> <pid> — event-anchored process-death wait
# (replaces fixed sleeps before liveness assertions: under CI load a kill
# can take longer than a guessed sleep to land, and a too-long sleep just
# wastes wall time on every run).
wait_gone() {
    local label="$1" deadline="$2" pid="$3" t=0
    # An empty/garbage pid must FAIL, not vacuously pass: `kill -0 ""` is rc 1,
    # which would read as "gone" and silently green the assertion if a future
    # change stopped writing the pidfile this pid came from.
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        printf '  FAIL: %s (no pid to watch: %q)\n' "$label" "$pid" >&2
        FAIL=$(( FAIL + 1 )); return 1
    fi
    local cmdline cwd
    while (( t < deadline * 4 )); do
        kill -0 "$pid" 2>/dev/null || { printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); return 0; }
        # Alive — but still OURS? pid_max wraps fast under parallel-suite load
        # (see _test_helpers.sh's identity-verified kills); a recycled pid
        # would read "still alive" for the whole deadline → false FAIL. Same
        # /proc identity test as th_kill_fixture_pid: every fixture path is
        # unique, so a stranger can't match. A process that exits between the
        # kill -0 and the /proc reads yields empty cmdline+cwd → gone, correct.
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || cmdline=""
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=""
        if [[ "$cmdline" != *"$WORK"* && "$cwd" != "$WORK"* ]]; then
            printf '  PASS: %s (pid %s recycled to a non-fixture owner)\n' "$label" "$pid"
            PASS=$(( PASS + 1 )); return 0
        fi
        sleep 0.25; t=$(( t + 1 ))
    done
    printf '  FAIL: %s (pid %s still alive after %ss)\n' "$label" "$pid" "$deadline" >&2
    FAIL=$(( FAIL + 1 )); return 1
}

# --- fail-loud when labsh is missing ----------------------------------------
echo '=== labsh missing → fail loud ==='
out=$(PATH="/usr/bin:/bin" NEXUS_STATE_DIR="$NEXUS_STATE_DIR" "$UP" "$WORK/proj1" 2>&1); rc=$?
assert_eq      "missing labsh exits nonzero" "$(( rc != 0 ))" "1"
assert_contains "stderr names labsh"          "$out" "labsh"

# --- first activation ---------------------------------------------------------
echo '=== first activation: kernel + registry row + healthy server ==='
out=$("$UP" "$WORK/proj1" 2>&1); rc=$?
assert_eq "activation exits 0" "$rc" "0"
assert_contains "prints the URL"   "$out" "lab?token="
assert_contains "row is jupyter-proj1" "$(cat "$NEXUS_SERVICES_REGISTRY")" "jupyter-proj1	$WORK/proj1"
assert_eq "registry has 1 row"     "$(reg_rows)" "1"
assert_eq "kernel add called once" "$(grep -c '^add' "$WORK/proj1/.jupyter/stub-kernel-calls")" "1"
assert_eq "one server started"     "$(cat "$WORK/proj1/.jupyter/stub-start-count")" "1"
assert_file_exists "supervisor pidfile" "$NEXUS_STATE_DIR/services/jupyter-proj1.pid"
assert_eq "health probe passes"    "$("$HEALTH" "$WORK/proj1" >/dev/null 2>&1; echo $?)" "0"
assert_eq "env PORT matches stub port" \
    "$(sed -n 's/^PORT=//p' "$WORK/proj1/.jupyter/labsh-service.env")" \
    "$(cat "$WORK/proj1/.jupyter/stub.port")"
sup1=$(sup_pid jupyter-proj1)

# --- idempotent re-activation -------------------------------------------------
echo '=== re-activation is a no-op ==='
out=$("$UP" "$WORK/proj1" 2>&1); rc=$?
assert_eq "re-activation exits 0"        "$rc" "0"
assert_eq "still 1 registry row"         "$(reg_rows)" "1"
assert_eq "still 1 server start"         "$(cat "$WORK/proj1/.jupyter/stub-start-count")" "1"
assert_eq "kernel add not re-run"        "$(grep -c '^add' "$WORK/proj1/.jupyter/stub-kernel-calls")" "1"
assert_eq "supervisor pid unchanged"     "$(sup_pid jupyter-proj1)" "$sup1"

# --- status verb ---------------------------------------------------------------
echo '=== --status ==='
out=$("$UP" "$WORK/proj1" --status 2>&1); rc=$?
assert_eq      "status exits 0 when healthy" "$rc" "0"
assert_contains "status says healthy"        "$out" "healthy"

# --- basename collision ---------------------------------------------------------
echo '=== basename collision → hashed name, --no-start registers only ==='
out=$("$UP" "$WORK/elsewhere/proj1" --no-start 2>&1); rc=$?
assert_eq "collision activation exits 0" "$rc" "0"
hashed=$(awk -F'\t' -v w="$WORK/elsewhere/proj1" '$2 == w {print $1}' "$NEXUS_SERVICES_REGISTRY")
assert_contains "second row name is hash-suffixed" "$hashed" "jupyter-proj1-"
assert_eq "registry has 2 rows" "$(reg_rows)" "2"
assert_no_file "no supervisor pidfile for --no-start" "$NEXUS_STATE_DIR/services/$hashed.pid"

# --- health probe edge cases -----------------------------------------------------
echo '=== jupyter-health edge cases ==='
assert_eq "no env file → unhealthy" "$("$HEALTH" "$WORK/proj2" >/dev/null 2>&1; echo $?)" "1"
real_tok=$(cat "$WORK/proj1/.jupyter/token")
printf 'WRONG' > "$WORK/proj1/.jupyter/token"
out=$("$HEALTH" "$WORK/proj1" >/dev/null 2>&1; echo $?)
printf '%s' "$real_tok" > "$WORK/proj1/.jupyter/token"
assert_eq "wrong token → unhealthy (squatter cannot pass)" "$(( out != 0 ))" "1"

# --- watchdog: server death → bounce ----------------------------------------------
echo '=== watchdog bounces a dead server ==='
kill "$(cat "$WORK/proj1/.jupyter/stub.pid")" 2>/dev/null
wait_for "server restarted by watchdog" 20 -- "$HEALTH" "$WORK/proj1"
assert_eq "start-count incremented" "$(cat "$WORK/proj1/.jupyter/stub-start-count")" "2"

# --- watchdog: port stolen while down → auto-increment + env follow ----------------
echo '=== preferred port stolen → server moves, env file follows ==='
old_port=$(cat "$WORK/proj1/.jupyter/stub.port")
kill "$(cat "$WORK/proj1/.jupyter/stub.pid")" 2>/dev/null
python3 "$STUBS/stub-server.py" "$old_port" SQUATTER >/dev/null 2>&1 &
SQUAT_PID=$!
wait_for "server back on a new port" 20 -- "$HEALTH" "$WORK/proj1"
new_port=$(sed -n 's/^PORT=//p' "$WORK/proj1/.jupyter/labsh-service.env")
assert_eq "env port moved past the squatter" "$(( new_port != old_port ))" "1"
kill "$SQUAT_PID" 2>/dev/null
wait "$SQUAT_PID" 2>/dev/null   # reap quietly (no job-control noise)

# --- token rotation self-heals ------------------------------------------------------
echo '=== token rotation → bounce → healthy with new token ==='
starts_before=$(cat "$WORK/proj1/.jupyter/stub-start-count")
printf 'rotated-%s' "$RANDOM" > "$WORK/proj1/.jupyter/token"
wait_for "healthy again after rotation" 20 -- "$HEALTH" "$WORK/proj1"
assert_eq "rotation forced exactly one restart" \
    "$(cat "$WORK/proj1/.jupyter/stub-start-count")" "$(( starts_before + 1 ))"

# --- post-start health grace: a warming server is waited out, not bounced ----------
# Regression for the restart-flap (jupyterlab svc went unhealthy after a
# sandbox restart and churned through repeated restarts before settling).
# start_server must gate success on a PASSING healthcheck, not merely on
# `labsh url` resolving: a server that has bound the port (URL resolves) but
# answers /api/status with 403 while still importing extensions must be waited
# out for up to START_GRACE, never bounced into a fresh cold start. The OLD
# code returned success on URL-present and immediately armed the steady-state
# 3-strike bounce against the still-warming server. The `.warming` gate file
# makes the stub return 403 on /api/status until removed.
echo '=== post-start grace: a warming server is waited out, not bounced ==='
P3="$WORK/proj3"; mkdir -p "$P3/.jupyter"
: > "$P3/.jupyter/.warming"          # gate on: /api/status returns 403 until removed
SUP3LOG="$P3/.jupyter/sup.log"
# START_GRACE=60, not 25: grace only has to OUTLIVE the gated period, and the
# probe passes the moment `.warming` is removed, so a large value costs no
# wall time. At 25 a loaded runner could burn most of the grace just reaching
# serving-at + the bounce-watch window; grace then expired while still gated,
# the supervisor bounced the warming server, and the "exactly one start"
# assertions below redded — a timing flake, not a code bug. The assertion's
# falsifiability is anchored at serving-at + INTERVAL*FAILS (=2s), which the
# old URL-is-success code trips regardless of the grace value.
LABSH_SVC_START_GRACE=60 "$SUP" "$P3" >"$SUP3LOG" 2>&1 &
SUP3=$!
# Anchor the timing on the "serving at" marker (the URL-persist point), NOT on
# wall-clock from test start: that marker is the EXACT fork where the old code
# returns success and arms its bounce while the new code begins health-gating.
# Anchoring here is what makes the assertion falsifiable — measuring from test
# start raced the stub's variable ~start latency and let the assertion fire
# before the old code's bounce, so the test passed on base dev too (no guard).
wait_for "supervisor reached serving-at (URL present)" 20 -- grep -q 'serving at' "$SUP3LOG"
# Watch PAST the steady-state bounce window (serving-at + INTERVAL*FAILS =
# +2s) while STILL gated, with 3x margin. OLD code (success on URL) bounces
# in this window: start-count climbs past 1 and the log shows "restarting
# labsh server". NEW code stays parked in start_server's health gate:
# start-count stays 1, no restart line. Poll instead of a blind sleep so a
# regression FAILS THE MOMENT the bounce fires (with the exact evidence)
# rather than being sampled once at the end; start-count is monotonic, so a
# clean window-end poll proves it never exceeded 1 at any point inside it.
bounce_watch=0; bounced=""
while (( bounce_watch < 24 )); do          # 24 * 0.25s = 6s window
    if [[ "$(cat "$P3/.jupyter/stub-start-count" 2>/dev/null)" != "1" ]] \
       || grep -q 'restarting labsh server' "$SUP3LOG" 2>/dev/null; then
        bounced=yes; break
    fi
    sleep 0.25; bounce_watch=$(( bounce_watch + 1 ))
done
if [[ -z "$bounced" ]]; then
    printf '  PASS: no bounce while warming (exactly one start, watched %ss)\n' 6; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bounced while warming at +%ss (start-count=%s, log tail: %s)\n' \
        "$(( bounce_watch / 4 ))" "$(cat "$P3/.jupyter/stub-start-count" 2>/dev/null)" \
        "$(grep 'restarting labsh server' "$SUP3LOG" 2>/dev/null | head -1)" >&2
    FAIL=$(( FAIL + 1 ))
fi
gated_rc=$("$HEALTH" "$P3" >/dev/null 2>&1; echo $?)
assert_eq "still unhealthy while gated" "$(( gated_rc != 0 ))" "1"
rm -f "$P3/.jupyter/.warming"        # warmup done: /api/status now 200
wait_for "healthy once warmup completes" 25 -- "$HEALTH" "$P3"
assert_eq "exactly one start through warmup→healthy (no flap)" \
    "$(cat "$P3/.jupyter/stub-start-count")" "1"
kill -KILL "$SUP3" 2>/dev/null
wait "$SUP3" 2>/dev/null   # reap our own child: no zombie, no exit-status noise later
[[ -f "$P3/.jupyter/stub.pid" ]] && kill "$(cat "$P3/.jupyter/stub.pid")" 2>/dev/null

# --- supervisor death → bootstrap-recover relaunches --------------------------------
echo '=== dead supervisor (stale pidfile) → bootstrap-recover revives ==='
sup=$(sup_pid jupyter-proj1)
kill -KILL "$sup" 2>/dev/null
kill "$(cat "$WORK/proj1/.jupyter/stub.pid")" 2>/dev/null   # server too: simulate crash/reboot
# NOT our shell child (jupyter-up.sh spawned it), so it cannot be `wait`ed;
# poll for actual death instead of guessing a sleep — recover must observe a
# DEAD pid or the "stale pidfile" branch under test is not the one exercised.
wait_gone "KILLed supervisor is gone before recover runs" 10 "$sup"
out=$("$RECOVER" --services-only 2>&1)
assert_contains "recover relaunched the service" "$out" "service 'jupyter-proj1': relaunched"
wait_for "healthy after recovery" 20 -- "$HEALTH" "$WORK/proj1"
assert_eq "new supervisor pid recorded" "$(( $(sup_pid jupyter-proj1) != sup ))" "1"

# --- adoption: hand-started server, supervisor comes later ---------------------------
echo '=== hand-started server is adopted, not duplicated ==='
mkdir -p "$WORK/proj2"
( cd "$WORK/proj2" && labsh kernel add proj2 && labsh start --port 9601 ) >/dev/null 2>&1
out=$("$UP" "$WORK/proj2" 2>&1); rc=$?
assert_eq "activation over live server exits 0" "$rc" "0"
assert_eq "no second server started" "$(cat "$WORK/proj2/.jupyter/stub-start-count")" "1"
assert_eq "adopted server healthy" "$("$HEALTH" "$WORK/proj2" >/dev/null 2>&1; echo $?)" "0"

# --- deactivation ----------------------------------------------------------------------
echo '=== --down stops everything and removes the row ==='
srv1=$(cat "$WORK/proj1/.jupyter/stub.pid")
# Read the CURRENT supervisor pid BEFORE --down (which removes the pidfile).
# The old assertion probed $sup1 — the FIRST supervisor, already KILLed and
# replaced in the bootstrap-recover stanza above — so it was vacuously true
# whether or not --down stopped anything.
sup1_now=$(sup_pid jupyter-proj1)
out=$("$UP" "$WORK/proj1" --down 2>&1); rc=$?
assert_eq "down exits 0" "$rc" "0"
# Event-anchored: a fixed sleep both wastes a second on every green run and
# flakes on a loaded runner where teardown takes longer than the guess.
wait_gone "supervisor gone after --down"  10 "$sup1_now"
wait_gone "stub server stopped by --down" 10 "$srv1"
assert_not_contains "row removed" "$(cat "$NEXUS_SERVICES_REGISTRY")" "jupyter-proj1	$WORK/proj1"
out=$("$RECOVER" --services-only --dry-run 2>&1)
assert_not_contains "recovery no longer touches proj1" "$out" "jupyter-proj1'"

# =============================================================================
# Root mode: one server at the work root, all project venvs as kernelspecs
# =============================================================================
CRAWL="$MON_DIR/jupyter-kernel-crawl.sh"
LROOT="$MON_DIR/labsh-root.sh"
ROOTWS="$WORK/rootws"
KDIR="$ROOTWS/.jupyter/share/jupyter/kernels"
fake_venv() { mkdir -p "$1/.venv/bin"; printf '#!/bin/bash\n' > "$1/.venv/bin/python"; chmod +x "$1/.venv/bin/python"; }
mkdir -p "$ROOTWS/gamma-novenv" "$ROOTWS/.hidden"
fake_venv "$ROOTWS/alpha"; fake_venv "$ROOTWS/beta"; fake_venv "$ROOTWS/.hidden"
spec_python() { python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("argv") or [""])[0])' "$1" 2>/dev/null; }
# A manual crawl can lose the non-blocking flock to the supervisor's
# periodic one; retry until we get a real sweep (it prints a summary).
crawl_now() {
    local i out
    for i in 1 2 3 4 5 6 7 8; do
        out=$("$CRAWL" "$ROOTWS" 2>&1)
        [[ "$out" == *"registered="* ]] && { printf '%s' "$out"; return 0; }
        sleep 0.5
    done
    printf '%s' "$out"; return 1
}

echo '=== root mode: activation registers jupyterlab + crawls kernels ==='
out=$("$UP" --root "$ROOTWS" 2>&1); rc=$?
assert_eq "root activation exits 0" "$rc" "0"
assert_contains "row is jupyterlab" "$(cat "$NEXUS_SERVICES_REGISTRY")" "jupyterlab	$ROOTWS"
assert_eq "health probe passes at the work root" "$("$HEALTH" "$ROOTWS" >/dev/null 2>&1; echo $?)" "0"
assert_file_exists "periodic hook persisted" "$ROOTWS/.jupyter/labsh-service.periodic"
assert_contains "periodic hook invokes the crawl" "$(cat "$ROOTWS/.jupyter/labsh-service.periodic")" "jupyter-kernel-crawl.sh"
wait_for "crawl registered proj-alpha" 15 -- test -f "$KDIR/proj-alpha/kernel.json"
wait_for "crawl registered proj-beta"  15 -- test -f "$KDIR/proj-beta/kernel.json"
assert_contains "proj-alpha kernelspec points at alpha's venv" \
    "$(spec_python "$KDIR/proj-alpha/kernel.json")" "$ROOTWS/alpha/.venv/bin/python"
assert_no_file "venv-less dir got no kernelspec" "$KDIR/proj-gamma-novenv/kernel.json"
assert_no_file "hidden dir skipped by shallow glob" "$KDIR/proj-.hidden/kernel.json"

echo '=== root mode: re-crawl is idempotent (no dupes, no re-register) ==='
regs_before=$(grep -c '^register' "$ROOTWS/.jupyter/stub-kernel-calls")
out=$(crawl_now); rc=$?
assert_eq "manual re-crawl exits 0" "$rc" "0"
assert_contains "re-crawl registered nothing" "$out" "registered=0"
assert_eq "no new labsh register calls" "$(grep -c '^register' "$ROOTWS/.jupyter/stub-kernel-calls")" "$regs_before"

echo '=== root mode: supervisor periodic re-crawl discovers a new project ==='
fake_venv "$ROOTWS/delta"
wait_for "proj-delta appears without re-activation" 20 -- test -f "$KDIR/proj-delta/kernel.json"

echo '=== root mode: removed project → stale kernelspec pruned ==='
# Deterministic prune: the supervisor's periodic crawl (every ~3 s at
# this test's LABSH_SVC_PERIODIC_EVERY) races the manual crawl below —
# whichever sweeps first does the prune and the loser reports pruned=0
# (the CI flake that blocked nexus-code PRs 253/254). Disable the hook
# so no NEW periodic crawl can launch, then remove the project while
# HOLDING the crawl lock: an in-flight crawl either finishes before our
# flock acquires (it saw delta intact) or hits its non-blocking flock
# while we hold it and exits without sweeping. Either way the manual
# crawl_now is the sole pruner. Hook restored below for the remaining
# subtests.
cp "$ROOTWS/.jupyter/labsh-service.periodic" "$WORK/periodic.hook.bak"
rm "$ROOTWS/.jupyter/labsh-service.periodic"
flock "$ROOTWS/.jupyter/.crawl.lock" rm -rf -- "$ROOTWS/delta"
out=$(crawl_now)
assert_contains "crawl reports the prune" "$out" "pruned=1"
assert_no_file "proj-delta kernelspec gone" "$KDIR/proj-delta/kernel.json"
# Restore atomically (write-then-mv) so the supervisor can never read a
# half-written hook.
cp "$WORK/periodic.hook.bak" "$ROOTWS/.jupyter/.periodic.tmp"
mv "$ROOTWS/.jupyter/.periodic.tmp" "$ROOTWS/.jupyter/labsh-service.periodic"

echo '=== root mode: sanitized-name collision is refused, not clobbered ==='
fake_venv "$ROOTWS/Beta"            # sanitizes to 'beta' → collides with proj-beta
out=$(crawl_now)
assert_contains "collision logged" "$out" "COLLISION"
assert_contains "existing kernelspec untouched" \
    "$(spec_python "$KDIR/proj-beta/kernel.json")" "$ROOTWS/beta/.venv/bin/python"
rm -rf "$ROOTWS/Beta"

echo '=== root mode: Lmod-module-python venv → full module LD + cleared PYTHONPATH ==='
# Strip any inherited real Lmod `module` function so the crawl child can't
# short-circuit past our fake init (real Lmod exports `module` to children).
unset -f module ml 2>/dev/null || true
# Fake Lmod init: defines `module` as a shell FUNCTION (real Lmod is a
# function precisely because `module load` must eval env mutations into the
# caller's shell — an executable on PATH cannot).
cat > "$WORK/fake-lmod-init.sh" <<'MLI'
module() {
    case "${1:-}" in
        purge) unset LD_LIBRARY_PATH ;;
        load)  export LD_LIBRARY_PATH="/opt/sw/${2}/lib:/opt/sw/SQLite/lib:/opt/sw/OpenSSL/lib"
               export PYTHONPATH="/opt/sw/${2}/lib/python/site-packages" ;;  # the shadow Lmod injects
    esac
}
MLI
# Disable the periodic hook for this subtest: a background periodic crawl has
# no NEXUS_LMOD_INIT and would race our init-equipped manual crawl (same
# rationale as the prune subtest above).
cp "$ROOTWS/.jupyter/labsh-service.periodic" "$WORK/periodic.hook.bak2"
rm "$ROOTWS/.jupyter/labsh-service.periodic"
# An Lmod venv (classified by pyvenv.cfg home=; the interpreter itself needn't
# be a real module python) plus a plain venv registered in the SAME sweep —
# the plain one proves PYTHONPATH is cleared ONLY on the Lmod path.
fake_venv "$ROOTWS/lmodproj"
printf 'home = /app/software/Python/3.12.3-GCCcore-13.3.0/bin\n' > "$ROOTWS/lmodproj/.venv/pyvenv.cfg"
fake_venv "$ROOTWS/plainproj"
: > "$ROOTWS/.jupyter/stub-register-env"
export NEXUS_LMOD_INIT="$WORK/fake-lmod-init.sh" PYTHONPATH="/caller/pp"
out=$(crawl_now); rc=$?
unset NEXUS_LMOD_INIT PYTHONPATH
assert_eq "lmod-path crawl exits 0" "$rc" "0"
lmrow=$(grep '^name=proj-lmodproj ' "$ROOTWS/.jupyter/stub-register-env" | tail -1)
plrow=$(grep '^name=proj-plainproj ' "$ROOTWS/.jupyter/stub-register-env" | tail -1)
assert_contains "lmod register got the module's full LD via --ld-library-path" \
    "$lmrow" "ld_arg=/opt/sw/Python/3.12.3-GCCcore-13.3.0/lib:/opt/sw/SQLite/lib:/opt/sw/OpenSSL/lib"
assert_contains "lmod register ran WITH that LD in its env" \
    "$lmrow" "ld_env=/opt/sw/Python/3.12.3-GCCcore-13.3.0/lib"
assert_contains "lmod register cleared PYTHONPATH (env -u)" "$lmrow" "pythonpath=__UNSET__"
assert_file_exists "lmod kernelspec written" "$KDIR/proj-lmodproj/kernel.json"
assert_contains "non-module register kept the caller PYTHONPATH (no regression)" \
    "$plrow" "pythonpath=/caller/pp"
assert_contains "non-module register passed NO --ld-library-path" "$plrow" "ld_arg=__NONE__"

echo '=== root mode: Lmod venv with Lmod UNAVAILABLE → skipped, not failed ==='
rm -rf "$KDIR/proj-lmodproj"        # unregister so this sweep re-attempts it
: > "$ROOTWS/.jupyter/stub-register-env"
# NEXUS_LMOD_INIT points at a nonexistent init AND overrides the standard
# locations, so `module` never materialises regardless of the host's real
# Lmod — the degrade path is exercised hermetically.
export NEXUS_LMOD_INIT="$WORK/nonexistent-lmod-init.sh"
out=$(crawl_now); rc=$?
unset NEXUS_LMOD_INIT
assert_eq "degrade crawl still exits 0" "$rc" "0"
assert_contains "degrade logs a SKIP for the lmod venv" "$out" "SKIP lmodproj"
assert_contains "degrade names the reason (needs Lmod)" "$out" "needs Lmod"
assert_not_contains "degrade does NOT hard-fail the venv" "$out" "FAILED to register lmodproj"
assert_no_file "degrade wrote no kernelspec" "$KDIR/proj-lmodproj/kernel.json"
assert_not_contains "degrade attempted no register for the lmod venv" \
    "$(cat "$ROOTWS/.jupyter/stub-register-env")" "name=proj-lmodproj "
# Restore the periodic hook (atomic write-then-mv, as the prune subtest does)
# and remove the extra fixtures so later subtests' counts are unaffected.
cp "$WORK/periodic.hook.bak2" "$ROOTWS/.jupyter/.periodic.tmp2"
mv "$ROOTWS/.jupyter/.periodic.tmp2" "$ROOTWS/.jupyter/labsh-service.periodic"
rm -rf "$ROOTWS/lmodproj" "$ROOTWS/plainproj"

echo '=== labsh-root.sh: project agent reaches the root server ==='
url_root=$(cd "$ROOTWS" && labsh url)
url_proj=$(cd "$ROOTWS/alpha" && NEXUS_WORKROOT="$ROOTWS" "$LROOT" url)
assert_eq "labsh-root from inside a project sees the root server" "$url_proj" "$url_root"
out=$(cd "$ROOTWS/alpha" && NEXUS_WORKROOT="$WORK/nonexistent" "$LROOT" url 2>&1); rc=$?
assert_eq      "labsh-root fails loud without a root session" "$(( rc != 0 ))" "1"
assert_contains "failure names the activation command"        "$out" "jupyter-up.sh --root"

echo '=== root mode: coexists with a per-project service ==='
assert_eq "proj2 service still healthy alongside root" "$("$HEALTH" "$WORK/proj2" >/dev/null 2>&1; echo $?)" "0"

echo '=== root mode: --down deregisters, stops, keeps kernelspecs ==='
sup_root=$(sup_pid jupyterlab)
srv_root=$(cat "$ROOTWS/.jupyter/stub.pid")
out=$("$UP" --root "$ROOTWS" --down 2>&1); rc=$?
assert_eq "root --down exits 0" "$rc" "0"
sleep 1
assert_eq "root supervisor gone" "$(kill -0 "$sup_root" 2>/dev/null; echo $?)" "1"
assert_eq "root stub server gone" "$(kill -0 "$srv_root" 2>/dev/null; echo $?)" "1"
# Name-field match, not substring: the checkout path itself may contain
# "jupyterlab" (e.g. a work/your-nexus-jupyterlab-* clone) and every
# row carries that path in its launch/health columns.
assert_empty "root row removed" "$(awk -F'\t' '$1 == "jupyterlab"' "$NEXUS_SERVICES_REGISTRY")"
assert_file_exists "kernelspecs survive --down (inert files, by design)" "$KDIR/proj-alpha/kernel.json"

echo '=== root mode: stale legacy jupyter-workroot row is migrated, never fatal ==='
# A registry written by pre-rename code: legacy row for the same
# workdir plus a stale supervisor pidfile. --root activation must
# absorb it (drop row + pidfile) and register under the new name.
printf 'jupyter-workroot\t%s\t%s\t%s\t%s\n' \
    "$ROOTWS" "$MON_DIR/labsh-supervised.sh" "$HEALTH" \
    "$ROOTWS/.jupyter/labsh-service.log" >> "$NEXUS_SERVICES_REGISTRY"
echo 99999999 > "$NEXUS_STATE_DIR/services/jupyter-workroot.pid"
out=$("$UP" --root "$ROOTWS" 2>&1); rc=$?
assert_eq "activation over a legacy row exits 0" "$rc" "0"
assert_contains "migration announced" "$out" "migrating legacy 'jupyter-workroot'"
assert_not_contains "legacy row gone" "$(cat "$NEXUS_SERVICES_REGISTRY")" "jupyter-workroot"
assert_contains "row re-registered as jupyterlab" "$(cat "$NEXUS_SERVICES_REGISTRY")" "jupyterlab	$ROOTWS"
assert_no_file "stale legacy pidfile removed" "$NEXUS_STATE_DIR/services/jupyter-workroot.pid"
assert_eq "healthy after migration" "$("$HEALTH" "$ROOTWS" >/dev/null 2>&1; echo $?)" "0"
"$UP" --root "$ROOTWS" --down >/dev/null 2>&1   # leave the fixture clean

th_summary_and_exit
