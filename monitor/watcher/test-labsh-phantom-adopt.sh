#!/usr/bin/env bash
# Regression test for the labsh "phantom-adopt" outage (jupyterlab service
# went DOWN 2026-07-01 ~18:59 and did NOT auto-recover through three watcher
# restarts). Exercises monitor/labsh-supervised.sh's phantom-adopt self-heal.
#
# The outage mechanism: labsh's start-guard scans
#   $JUPYTER_DATA_DIR/runtime/jpserver-*.json
# and, finding a STALE record for a since-dead server, declared "server is
# already running (pid …)" and returned rc=1. The supervisor adopted the
# phantom and logged "serving" — but nothing was listening, so the healthcheck
# failed forever and every restart re-adopted the same phantom. (labsh's guard
# only `kill -0`s the recorded pid, which cannot tell a live JupyterLab from a
# dead server's record whose pid was recycled to another process or is a
# zombie — exactly the incident's pid 6105.)
#
# The fix under test, in labsh-supervised.sh:
#   1. prune_dead_runtime_records — before every start, drop records whose pid
#      is VERIFIABLY DEAD (kill -0). Conservative: a live pid is never touched.
#   2. phantom-adopt detection — if `labsh start` returns rc=1 (adopted a
#      record) but no healthy server appears within START_GRACE, prune the
#      NON-SERVING record(s) (a record that answers /api/status is a real live
#      server and is kept) and retry the start ONCE (guarded, cannot spin).
#
# Hermetic: labsh is a PATH-shadow stub whose `start` refuses (rc=1, "already
# running") whenever a jpserver-*.json record is present — faithfully modelling
# incident-time labsh — and otherwise launches a real token-checking HTTP
# server (python3) and writes a fresh jpserver record. No uv, venv, or
# JupyterLab. Every server/supervisor is killed by recorded pid on exit.
#
# Run: bash monitor/watcher/test-labsh-phantom-adopt.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Falsifiability (verified by the author, documented in the PR): checking out
# monitor/labsh-supervised.sh at pre-fix dev and re-running REDs both the
# dead-pid and pid-reuse subtests (no healthy server ever comes up), and the
# fix GREENs them.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

MON_DIR=$(cd "$_test_dir/.." && pwd)
HEALTH="$MON_DIR/jupyter-health.sh"
SUP="$MON_DIR/labsh-supervised.sh"

WORK=$(mktemp -d -t nexus-phantom-XXXXXX)

# Track every pid we spawn (supervisors, stub servers, sleepers) so cleanup
# never has to pattern-match (self-kill hazard). Identity-verified kills only.
SPAWNED_PIDS=()
cleanup() {
    local pid pf
    for pid in "${SPAWNED_PIDS[@]:-}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done
    # Stub servers record their own pid under each project's .jupyter/stub.pid.
    for pf in "$WORK"/t*/.jupyter/stub.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Fast health timeout so record_is_serving probes against a dead port fail
# quickly (default 3s each would make the phantom subtest crawl).
export LABSH_HEALTH_TIMEOUT=1

# --- stubs ------------------------------------------------------------------
STUBS="$WORK/stub-bin"
mkdir -p "$STUBS"

# Token-checking HTTP server: 200 on /api/status with the token given at start,
# 403 otherwise. Mirrors real jupyter holding JUPYTER_TOKEN from launch.
cat > "$STUBS/stub-server.py" <<'PY'
import http.server, sys
PORT, TOKEN = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == '/api/status' and \
             self.headers.get('Authorization') == 'token ' + TOKEN
        self.send_response(200 if ok else 403)
        self.end_headers()
        self.wfile.write(b'{}' if ok else b'forbidden')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY

# Stub labsh. Contract for the surface the supervisor touches, PLUS the
# jpserver-*.json runtime-record scan that drove the incident.
cat > "$STUBS/labsh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
J="\${JUPYTER_CONFIG_DIR:-\$PWD/.jupyter}"
RT="\$PWD/.jupyter/share/jupyter/runtime"     # == labsh's default JUPYTER_DATA_DIR/runtime
SERVER_PY="$STUBS/stub-server.py"
alive() { [[ -f "\$J/stub.pid" ]] && kill -0 "\$(cat "\$J/stub.pid" 2>/dev/null)" 2>/dev/null; }
first_record() { local f; for f in "\$RT"/jpserver-*.json; do [[ -e "\$f" ]] && { printf '%s' "\$f"; return 0; }; done; return 1; }
case "\${1:-}" in
  start)
    shift
    # Incident-time start-guard: refuse if ANY jpserver record is present. The
    # real labsh only kill-0s the recorded pid, but a recycled/zombie pid makes
    # that guard fire on a stale record all the same — which is exactly what
    # the supervisor must survive. So the stub refuses on record-present.
    if rec=\$(first_record); then
        pid=\$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('pid',''))" "\$rec" 2>/dev/null)
        url=\$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('url',''))" "\$rec" 2>/dev/null)
        echo "labsh: server is already running (pid \${pid:-?}, \${url:-?})" >&2
        exit 1
    fi
    port=8888
    while (( \$# > 0 )); do case "\$1" in --port) port="\$2"; shift 2 ;; *) shift ;; esac; done
    mkdir -p "\$J" "\$RT"
    [[ -f "\$J/token" ]] || printf 'stubtok-%s' "\$RANDOM" > "\$J/token"
    tok=\$(cat "\$J/token")
    # labsh auto-increment: first free port in [port, port+9].
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
    python3 "\$SERVER_PY" "\$port" "\$tok" >/dev/null 2>&1 &
    spid=\$!
    echo "\$spid" > "\$J/stub.pid"; echo "\$port" > "\$J/stub.port"
    echo \$(( \$(cat "\$J/stub-start-count" 2>/dev/null || echo 0) + 1 )) > "\$J/stub-start-count"
    printf '{"pid": %s, "url": "http://127.0.0.1:%s/", "port": %s, "token": "%s", "secure": false}\n' \
        "\$spid" "\$port" "\$port" "\$tok" > "\$RT/jpserver-\$spid.json"
    for i in \$(seq 1 20); do curl -fs -o /dev/null "http://127.0.0.1:\$port/x" 2>/dev/null && break; sleep 0.1; done
    echo "labsh-stub: running at http://127.0.0.1:\$port/" >&2
    ;;
  url)
    if alive; then
        echo "http://127.0.0.1:\$(cat "\$J/stub.port")/lab?token=\$(cat "\$J/token")"; exit 0
    fi
    # Phantom: no live stub, but a record resolves a (stale) URL — mirrors labsh
    # reading jpserver-*.json, which is how a phantom exposes a URL at all.
    if rec=\$(first_record); then
        python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('url','')+'lab?token='+d.get('token',''))" "\$rec" 2>/dev/null
        exit 0
    fi
    echo "labsh-stub: no running server" >&2; exit 1
    ;;
  stop)
    # Faithful to real labsh: stop signals the LIVE server it started and that
    # server removes its OWN record on shutdown. A phantom record (a dead
    # server's, not ours) is left untouched — which is exactly why the
    # incident's bounce loop (stop+start) never cleared the stale record.
    if [[ -f "\$J/stub.pid" ]]; then
        spid=\$(cat "\$J/stub.pid")
        kill "\$spid" 2>/dev/null
        rm -f "\$RT/jpserver-\$spid.json" "\$J/stub.pid"
    fi
    ;;
  status) alive && echo "server up" || echo "no server" ;;
  token)  cat "\$J/token" 2>/dev/null ;;
  kernel) shift; mkdir -p "\$J"; echo "\$*" >> "\$J/stub-kernel-calls" ;;
  *) echo "labsh-stub: unhandled verb: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$STUBS/labsh"
export PATH="$STUBS:$PATH"

# --- helpers ----------------------------------------------------------------
wait_for() {  # wait_for <label> <deadline-s> -- cmd...
    local label="$1" deadline="$2"; shift 3
    local t=0
    while (( t < deadline * 4 )); do
        "$@" >/dev/null 2>&1 && { printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); return 0; }
        sleep 0.25; t=$(( t + 1 ))
    done
    printf '  FAIL: %s (deadline %ss)\n' "$label" "$deadline" >&2; FAIL=$(( FAIL + 1 )); return 1
}

seed_record() {  # seed_record <project> <pid> <port> [<token>]
    local p="$1" pid="$2" port="$3" tok="${4:-seedtok}"
    local rt="$p/.jupyter/share/jupyter/runtime"
    mkdir -p "$rt"
    printf '{"pid": %s, "url": "http://127.0.0.1:%s/", "port": %s, "token": "%s", "secure": false}\n' \
        "$pid" "$port" "$port" "$tok" > "$rt/jpserver-$pid.json"
    printf '%s' "$tok" > "$p/.jupyter/token"          # so a phantom's health probe uses a real token
}

dead_pid() {  # print a pid that is guaranteed dead (spawned then reaped)
    bash -c 'exit 0' & local d=$!
    wait "$d" 2>/dev/null
    printf '%s' "$d"
}

# Fast start grace so the phantom-adopt window closes in a few seconds.
export LABSH_SVC_INTERVAL=1 LABSH_SVC_FAILS=2 LABSH_SVC_START_GRACE=4

# ============================================================================
echo '=== T1: stale DEAD-pid record is pruned before start → real healthy server ==='
# The steady-state case: a crashed server left a record whose pid is now dead.
# prune_dead_runtime_records (kill -0) removes it before start; labsh then
# launches a fresh server. Pre-fix (no prune) the stub refuses on the record
# and the phantom is adopted — nothing healthy ever comes up.
T1="$WORK/t1"; mkdir -p "$T1/.jupyter"
DPID=$(dead_pid)
seed_record "$T1" "$DPID" 9731
assert_eq "seeded pid is verifiably dead" "$(kill -0 "$DPID" 2>/dev/null; echo $?)" "1"
"$SUP" "$T1" >"$T1/sup.log" 2>&1 &
T1SUP=$!; SPAWNED_PIDS+=("$T1SUP")
wait_for "T1 server becomes healthy" 20 -- "$HEALTH" "$T1"
assert_no_file "T1 dead-pid record pruned" "$T1/.jupyter/share/jupyter/runtime/jpserver-$DPID.json"
assert_eq "T1 exactly one real start" "$(cat "$T1/.jupyter/stub-start-count" 2>/dev/null)" "1"
assert_contains "T1 log records the prune" "$(cat "$T1/sup.log")" "pruned stale runtime record for dead pid $DPID"
kill -KILL "$T1SUP" 2>/dev/null

# ============================================================================
echo '=== T2: pid-reuse phantom (alive non-server pid) → detect, prune, retry, heal ==='
# The actual incident: the recorded pid is ALIVE (recycled to an unrelated
# process / zombie) so kill -0 passes and the conservative pre-start prune
# correctly leaves it. labsh adopts it (rc=1) but nothing serves. The
# phantom-adopt detector must, after START_GRACE of unhealth, prune the
# non-serving record and retry the start once.
T2="$WORK/t2"; mkdir -p "$T2/.jupyter"
sleep 300 & ALIVEPID=$!; SPAWNED_PIDS+=("$ALIVEPID")   # alive, but not a server
# Point the record at a definitely-dead port so record_is_serving fails fast.
seed_record "$T2" "$ALIVEPID" 9799
assert_eq "T2 seeded pid is alive (kill -0 passes)" "$(kill -0 "$ALIVEPID" 2>/dev/null; echo $?)" "0"
"$SUP" "$T2" >"$T2/sup.log" 2>&1 &
T2SUP=$!; SPAWNED_PIDS+=("$T2SUP")
wait_for "T2 server becomes healthy after phantom self-heal" 30 -- "$HEALTH" "$T2"
assert_no_file "T2 phantom record pruned" "$T2/.jupyter/share/jupyter/runtime/jpserver-$ALIVEPID.json"
assert_eq "T2 alive non-server process was NOT killed (only its record removed)" \
    "$(kill -0 "$ALIVEPID" 2>/dev/null; echo $?)" "0"
assert_contains "T2 log shows phantom-adopt heal" "$(cat "$T2/sup.log")" "phantom-adopt:"
assert_contains "T2 log shows the retry" "$(cat "$T2/sup.log")" "retrying start once"
assert_eq "T2 phantom retry happened AT MOST once (loop guard)" \
    "$(grep -c 'retrying start once' "$T2/sup.log")" "1"
kill -KILL "$T2SUP" 2>/dev/null
kill -KILL "$ALIVEPID" 2>/dev/null

# ============================================================================
echo '=== T3: non-degrading — a genuinely healthy already-running server is adopted, record kept ==='
# A real server is serving with a valid env file + record. The supervisor must
# adopt it on the first probe (start_server never runs), so nothing is started
# and the live server's record is NEVER pruned.
T3="$WORK/t3"; mkdir -p "$T3/.jupyter" "$T3/.jupyter/share/jupyter/runtime"
T3TOK="livetok-$RANDOM"
T3PORT=$(python3 - <<'EOF'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
EOF
)
printf '%s' "$T3TOK" > "$T3/.jupyter/token"
printf 'PORT=%s\nSCHEME=http\n' "$T3PORT" > "$T3/.jupyter/labsh-service.env"
python3 "$STUBS/stub-server.py" "$T3PORT" "$T3TOK" >/dev/null 2>&1 &
T3SRV=$!; SPAWNED_PIDS+=("$T3SRV")
printf '{"pid": %s, "url": "http://127.0.0.1:%s/", "port": %s, "token": "%s", "secure": false}\n' \
    "$T3SRV" "$T3PORT" "$T3PORT" "$T3TOK" > "$T3/.jupyter/share/jupyter/runtime/jpserver-$T3SRV.json"
wait_for "T3 pre-existing server is healthy" 10 -- "$HEALTH" "$T3"
"$SUP" "$T3" >"$T3/sup.log" 2>&1 &
T3SUP=$!; SPAWNED_PIDS+=("$T3SUP")
sleep 3   # give the supervisor time to (not) start anything
assert_no_file "T3 no labsh start was issued (healthy server adopted)" "$T3/.jupyter/stub-start-count"
assert_file_exists "T3 live server's record left untouched" \
    "$T3/.jupyter/share/jupyter/runtime/jpserver-$T3SRV.json"
assert_not_contains "T3 nothing was pruned" "$(cat "$T3/sup.log")" "pruned"
assert_eq "T3 server still healthy alongside supervisor" "$("$HEALTH" "$T3" >/dev/null 2>&1; echo $?)" "0"
kill -KILL "$T3SUP" 2>/dev/null
kill -KILL "$T3SRV" 2>/dev/null

th_summary_and_exit
