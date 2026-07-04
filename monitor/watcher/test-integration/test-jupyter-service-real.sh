#!/usr/bin/env bash
# Integration tests for JupyterLab-as-a-service with the REAL labsh:
# real venvs, real JupyterLab servers, real kernels — in throwaway
# /tmp projects on auto-selected high ports (9700-9949), against a
# fixture-local registry/state dir. The operator's live registry and
# live service ports are never touched.
#
# Matrix (operator request, your-org/your-nexus issue 184):
#   fresh project → auto-kernel + server + URL reachable
#   exec state persists across separate invocations ("agent turns")
#   kernel inspect / find resolve
#   idempotent re-activation (no second server)
#   human + agent on the same kernel (UI + sessions API while exec'ing)
#   watchdog bounces a killed server
#   token rotation self-heals; exec works after
#   dead supervisor + dead server → bootstrap-recover revives
#   --down leaves no orphan server/kernels and deregisters
#   ephemeral /tmp helper venv deleted (reboot sim) → recreated
#   pre-existing ./.venv reused (not recreated)
#   port collision (squatted preferred port) → auto-increment + env follow
#   --venv DIR registration (external venv) + --https + two services at once
#
# Root-mode matrix (operator request, your-org/your-nexus issue 185):
#   --root activation → jupyterlab service, URL reachable
#   crawl registers ≥3 project venvs as distinct proj-* kernelspecs
#   kernel exec per project runs in the CORRECT per-project venv
#   project-dir agent reaches the root server via labsh-root.sh
#   crawl discovers a fresh project; re-crawl idempotent
#   removed project → stale kernelspec pruned
#   coexists with per-project services; auth token enforced
#   --down: no orphan server/kernels, deregistered, kernelspecs kept
#
# Run: RUN_INTEGRATION=1 bash monitor/watcher/test-integration/test-jupyter-service-real.sh
# Requires: labsh + uv + python3 + curl on PATH. Takes a few minutes
# (venv creation dominates; uv cache warms it considerably).

set -uo pipefail

if [[ "${RUN_INTEGRATION:-0}" != "1" ]]; then
    echo "SKIP: integration scenario (set RUN_INTEGRATION=1 to run)"
    exit 0
fi
for bin in labsh uv python3 curl; do
    command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: $bin not on PATH"; exit 0; }
done

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$_test_dir/_test_helpers.sh"

MON_DIR=$(cd "$_test_dir/.." && pwd)
UP="$MON_DIR/jupyter-up.sh"
HEALTH="$MON_DIR/jupyter-health.sh"
RECOVER="$MON_DIR/bootstrap-recover.sh"

WORK=$(mktemp -d "/tmp/jupyter-svc-itest-$(id -u)-XXXXXX")
PROJA="$WORK/projA-fresh"
PROJB="$WORK/projB-prevenv"
PROJC="$WORK/projC-extvenv"
RWS="$WORK/rootws"
mkdir -p "$PROJA" "$PROJB" "$PROJC" "$RWS" "$WORK/state"

export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
export LABSH_SVC_INTERVAL=2
export LABSH_SVC_FAILS=2
export LABSH_UP_TIMEOUT=300

SQUAT_PID=''
cleanup() {
    # Tear down everything we may have started, strictly by recorded
    # pid (never by pattern — self-kill hazard).
    local pf pid d jf
    for pf in "$WORK"/state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; }
    done
    sleep 1
    for d in "$PROJA" "$PROJB" "$PROJC" "$RWS"; do
        for jf in "$d"/.jupyter/share/jupyter/runtime/jpserver-*.json; do
            [[ -e "$jf" ]] || continue
            pid=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('pid',''))" "$jf" 2>/dev/null)
            [[ "$pid" =~ ^[0-9]+$ ]] && kill -KILL "$pid" 2>/dev/null
        done
        # The per-project /tmp helper venv (path-hashed name, ours alone).
        local link="$d/.jupyter/.labshvenv" tgt
        tgt=$(readlink -f "$link" 2>/dev/null)
        [[ -n "$tgt" && "$tgt" == /tmp/labsh-venv-* ]] && rm -rf "$tgt"
    done
    [[ -n "$SQUAT_PID" ]] && kill "$SQUAT_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

wait_for() {  # wait_for <label> <deadline-s> -- cmd...
    local label="$1" deadline="$2"; shift 3
    local t=0
    while (( t < deadline * 2 )); do
        "$@" >/dev/null 2>&1 && { printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); return 0; }
        sleep 0.5; t=$(( t + 1 ))
    done
    printf '  FAIL: %s (deadline %ss)\n' "$label" "$deadline" >&2; FAIL=$(( FAIL + 1 )); return 1
}

server_pid_of() {  # live jupyter server pid for a project ('' if none)
    local d="$1" jf pid
    for jf in "$d"/.jupyter/share/jupyter/runtime/jpserver-*.json; do
        [[ -e "$jf" ]] || continue
        pid=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('pid',''))" "$jf" 2>/dev/null)
        [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && { printf '%s' "$pid"; return 0; }
    done
    return 1
}
base_url_of() {  # scheme://127.0.0.1:port from the service env file
    local d="$1" port scheme
    port=$(sed -n 's/^PORT=//p' "$d/.jupyter/labsh-service.env" 2>/dev/null | head -1)
    scheme=$(sed -n 's/^SCHEME=//p' "$d/.jupyter/labsh-service.env" 2>/dev/null | head -1)
    printf '%s://127.0.0.1:%s' "${scheme:-http}" "$port"
}
auth_curl() { curl -fsSk --max-time 5 -H "Authorization: token $(cat "$1/.jupyter/token")" "${@:2}"; }
free_port() { python3 -c '
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

# =========================================================================
echo '=== [1] fresh project: activation auto-registers kernel + URL reachable ==='
out=$("$UP" "$PROJA" 2>&1); rc=$?
assert_eq "activation exits 0" "$rc" "0"
assert_contains "kernel was auto-added"   "$out" "labsh kernel add"
assert_contains "registry row written"    "$(cat "$NEXUS_SERVICES_REGISTRY")" "jupyter-projA-fresh	$PROJA"
assert_file_exists "kernelspec registered" "$(compgen -G "$PROJA/.jupyter/share/jupyter/kernels/*/kernel.json" | head -1)"
url=$(cd "$PROJA" && labsh url)
http_rc=$(curl -fsSk -o /dev/null --max-time 5 "$url"; echo $?)
assert_eq "tokenized URL reachable" "$http_rc" "0"
assert_eq "health probe green" "$("$HEALTH" "$PROJA" >/dev/null 2>&1; echo $?)" "0"
porta=$(sed -n 's/^PORT=//p' "$PROJA/.jupyter/labsh-service.env")
if (( porta >= 9700 && porta <= 9949 )); then
    printf '  PASS: port %s in deterministic range\n' "$porta"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: port %s outside 9700-9949\n' "$porta" >&2; FAIL=$(( FAIL + 1 ))
fi

echo '=== [2] kernel exec: state persists across separate invocations ==='
( cd "$PROJA" && labsh notebook attach analysis.ipynb ) >/dev/null 2>&1
assert_eq "attach succeeded" "$?" "0"
( cd "$PROJA" && labsh kernel exec -n analysis.ipynb 'x = 41' ) >/dev/null 2>&1
got=$(cd "$PROJA" && labsh kernel exec -n analysis.ipynb 'x += 1; print(x)' 2>/dev/null)
assert_contains "x survived between invocations" "$got" "42"

echo '=== [3] kernel inspect / find resolve ==='
got=$(cd "$PROJA" && labsh kernel inspect -n analysis.ipynb 2>/dev/null)
assert_contains "inspect lists x" "$got" "x"
got=$(cd "$PROJA" && labsh kernel find analysis 2>&1)
assert_contains "find resolves the notebook" "$got" "analysis.ipynb"

echo '=== [4] idempotent re-activation ==='
srv_before=$(server_pid_of "$PROJA")
out=$("$UP" "$PROJA" 2>&1); rc=$?
assert_eq "re-activation exits 0" "$rc" "0"
assert_eq "same server pid (no second server)" "$(server_pid_of "$PROJA")" "$srv_before"
assert_eq "registry still has exactly 1 projA row" \
    "$(awk -F'\t' -v w="$PROJA" '$2 == w' "$NEXUS_SERVICES_REGISTRY" | wc -l)" "1"
got=$(cd "$PROJA" && labsh kernel exec -n analysis.ipynb 'print(x)' 2>/dev/null)
assert_contains "kernel state untouched by re-activation" "$got" "42"

echo '=== [5] human + agent share the server/kernel ==='
ui_rc=$(auth_curl "$PROJA" -o /dev/null "$(base_url_of "$PROJA")/lab"; echo $?)
assert_eq "browser UI endpoint serves (human side)" "$ui_rc" "0"
sessions=$(auth_curl "$PROJA" "$(base_url_of "$PROJA")/api/sessions" 2>/dev/null)
assert_contains "sessions API shows the shared notebook session" "$sessions" "analysis.ipynb"
got=$(cd "$PROJA" && labsh kernel exec -n analysis.ipynb 'print(x + 1)' 2>/dev/null)
assert_contains "agent exec works alongside UI traffic" "$got" "43"

echo '=== [6] watchdog bounces a killed server ==='
kill -KILL "$srv_before" 2>/dev/null
wait_for "health green again after server kill" 90 -- "$HEALTH" "$PROJA"
srv_after=$(server_pid_of "$PROJA")
assert_eq "a NEW server is up" "$(( srv_after != srv_before ))" "1"

echo '=== [7] token rotation self-heals; exec works after ==='
( cd "$PROJA" && labsh token --rotate ) >/dev/null 2>&1
wait_for "health green with rotated token" 90 -- "$HEALTH" "$PROJA"
( cd "$PROJA" && labsh notebook attach analysis.ipynb ) >/dev/null 2>&1
got=$(cd "$PROJA" && labsh kernel exec -n analysis.ipynb 'print("post-rotate-ok")' 2>/dev/null)
assert_contains "exec against post-rotation server" "$got" "post-rotate-ok"

echo '=== [8] dead supervisor + dead server → bootstrap-recover revives ==='
sup=$(cat "$NEXUS_STATE_DIR/services/jupyter-projA-fresh.pid")
kill -KILL "$sup" 2>/dev/null
srv=$(server_pid_of "$PROJA") && kill -KILL "$srv" 2>/dev/null
sleep 1
out=$("$RECOVER" --services-only 2>&1)
assert_contains "recover relaunched jupyter-projA-fresh" "$out" "service 'jupyter-projA-fresh': relaunched"
wait_for "healthy after recovery" 120 -- "$HEALTH" "$PROJA"

echo '=== [9] --down: no orphans, deregistered ==='
srv=$(server_pid_of "$PROJA")
sup=$(cat "$NEXUS_STATE_DIR/services/jupyter-projA-fresh.pid")
out=$("$UP" "$PROJA" --down 2>&1); rc=$?
assert_eq "down exits 0" "$rc" "0"
sleep 2
assert_eq "supervisor dead"     "$(kill -0 "$sup" 2>/dev/null; echo $?)" "1"
assert_eq "jupyter server dead" "$(kill -0 "$srv" 2>/dev/null; echo $?)" "1"
assert_empty "no projA row left" "$(awk -F'\t' -v w="$PROJA" '$2 == w' "$NEXUS_SERVICES_REGISTRY")"
# Scope to the fixture (kernel ps NOTEBOOK paths): 'ipykernel' never
# appears in kernel ps output, and a user-wide pattern could match
# live kernels of unrelated sessions on a shared node.
kcount=$(cd "$PROJA" && labsh kernel ps 2>/dev/null | grep -c "$PROJA")
assert_eq "no orphan kernels" "$kcount" "0"

echo '=== [10] ephemeral /tmp helper venv deleted (reboot sim) → recreated ==='
tgt=$(readlink -f "$PROJA/.jupyter/.labshvenv")
if [[ -n "$tgt" && "$tgt" == /tmp/labsh-venv-* ]]; then
    rm -rf "$tgt"
    printf '  PASS: helper venv removed (%s)\n' "$tgt"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: unexpected helper venv target: %q\n' "$tgt" >&2; FAIL=$(( FAIL + 1 ))
fi
out=$("$UP" "$PROJA" 2>&1); rc=$?
assert_eq "re-activation after venv loss exits 0" "$rc" "0"
assert_eq "healthy after venv recreation" "$("$HEALTH" "$PROJA" >/dev/null 2>&1; echo $?)" "0"
"$UP" "$PROJA" --down >/dev/null 2>&1

echo '=== [11] pre-existing ./.venv is reused, not replaced ==='
( cd "$PROJB" && uv venv .venv ) >/dev/null 2>&1
marker="$PROJB/.venv/MARKER-$$"
touch "$marker"
out=$("$UP" "$PROJB" --no-start 2>&1); rc=$?
assert_eq "activation with pre-existing venv exits 0" "$rc" "0"
assert_file_exists "pre-existing venv survived (marker intact)" "$marker"
spec=$(compgen -G "$PROJB/.jupyter/share/jupyter/kernels/*/kernel.json" | head -1)
assert_contains "kernelspec points at the pre-existing venv" "$(cat "$spec")" "$PROJB/.venv"

echo '=== [12] squatted preferred port → auto-increment, env follows ==='
squat=$(free_port)
python3 -m http.server "$squat" --bind 127.0.0.1 >/dev/null 2>&1 &
SQUAT_PID=$!
out=$("$UP" "$PROJB" --port "$squat" 2>&1); rc=$?
assert_eq "activation with squatted port exits 0" "$rc" "0"
portb=$(sed -n 's/^PORT=//p' "$PROJB/.jupyter/labsh-service.env")
assert_eq "server moved off the squatted port" "$(( portb != squat ))" "1"
assert_eq "healthcheck follows the real port" "$("$HEALTH" "$PROJB" >/dev/null 2>&1; echo $?)" "0"
kill "$SQUAT_PID" 2>/dev/null; wait "$SQUAT_PID" 2>/dev/null; SQUAT_PID=''

echo '=== [13] stale .jupyter (dead-pid jpserver + bogus bg.pid) is ignored ==='
sleep 0.1 & deadpid=$!; wait "$deadpid" 2>/dev/null
mkdir -p "$PROJC/.jupyter/share/jupyter/runtime"
echo "$deadpid" > "$PROJC/.jupyter/labsh.bg.pid"
printf '{"pid": %s, "url": "http://127.0.0.1:1/", "token": "stale"}\n' "$deadpid" \
    > "$PROJC/.jupyter/share/jupyter/runtime/jpserver-$deadpid.json"

echo '=== [14] --venv external + --https; two services coexist ==='
command -v openssl >/dev/null 2>&1 || echo "  (openssl missing — https leg would fail)"
out=$("$UP" "$PROJC" --venv "$PROJB" --https 2>&1); rc=$?
assert_eq "external-venv https activation exits 0 (stale files ignored)" "$rc" "0"
spec=$(compgen -G "$PROJC/.jupyter/share/jupyter/kernels/*/kernel.json" | head -1)
assert_contains "projC kernelspec uses projB's venv" "$(cat "$spec")" "$PROJB/.venv"
assert_eq "projC scheme is https" "$(sed -n 's/^SCHEME=//p' "$PROJC/.jupyter/labsh-service.env")" "https"
assert_eq "projB still healthy alongside projC" "$("$HEALTH" "$PROJB" >/dev/null 2>&1; echo $?)" "0"
assert_eq "projC healthy" "$("$HEALTH" "$PROJC" >/dev/null 2>&1; echo $?)" "0"
portc=$(sed -n 's/^PORT=//p' "$PROJC/.jupyter/labsh-service.env")
assert_eq "distinct ports" "$(( portb != portc ))" "1"
assert_eq "two registry rows" "$(grep -c . "$NEXUS_SERVICES_REGISTRY")" "2"

# =========================================================================
# Root mode: one server at the work root, all project kernels (issue 185)
# =========================================================================
CRAWL="$MON_DIR/jupyter-kernel-crawl.sh"
LROOT="$MON_DIR/labsh-root.sh"
KDIR="$RWS/.jupyter/share/jupyter/kernels"

# Three real project venvs, each with a unique marker module so an exec
# can PROVE which venv its kernel runs in.
make_proj() {  # make_proj <name>
    local d="$RWS/$1" sp
    mkdir -p "$d"
    ( cd "$d" && uv venv .venv ) >/dev/null 2>&1 || return 1
    sp=$(compgen -G "$d/.venv/lib/python*/site-packages" | head -1) || return 1
    printf 'NAME = %s\n' "'$1'" > "$sp/projmarker.py"
}
for p in pa pb pc; do
    make_proj "$p" || { echo "FATAL: fixture venv for $p failed" >&2; exit 1; }
done

# A manual crawl can lose the non-blocking flock to the supervisor's
# periodic one; retry until a real sweep (it prints a summary line).
crawl_now() {
    local i out
    for i in $(seq 1 10); do
        out=$("$CRAWL" "$RWS" 2>&1)
        [[ "$out" == *"registered="* ]] && { printf '%s' "$out"; return 0; }
        sleep 1
    done
    printf '%s' "$out"; return 1
}

echo '=== [15] --root activation: jupyterlab service, URL reachable ==='
out=$("$UP" --root "$RWS" 2>&1); rc=$?
assert_eq "root activation exits 0" "$rc" "0"
assert_contains "registry row is jupyterlab" "$(cat "$NEXUS_SERVICES_REGISTRY")" "jupyterlab	$RWS"
url=$(cd "$RWS" && labsh url)
assert_eq "root tokenized URL reachable" "$(curl -fsSk -o /dev/null --max-time 5 "$url"; echo $?)" "0"
assert_eq "root health probe green" "$("$HEALTH" "$RWS" >/dev/null 2>&1; echo $?)" "0"

echo '=== [16] crawl registers 3 project venvs as distinct kernelspecs ==='
for p in pa pb pc; do
    wait_for "kernelspec proj-$p registered" 240 -- test -f "$KDIR/proj-$p/kernel.json"
done
assert_eq "exactly 3 proj-* kernelspecs" "$(compgen -G "$KDIR/proj-*/kernel.json" | wc -l)" "3"

echo '=== [17] kernel exec per project runs in the CORRECT venv (isolation) ==='
for p in pa pb pc; do
    ( cd "$RWS" && labsh notebook attach "$p/nb-$p.ipynb" --kernel-name "proj-$p" ) >/dev/null 2>&1
    got=$(cd "$RWS" && labsh kernel exec -n "$p/nb-$p.ipynb" \
        'import sys, projmarker; print(projmarker.NAME, sys.executable)' 2>/dev/null)
    assert_contains "proj-$p kernel sees its own marker"      "$got" "$p "
    assert_contains "proj-$p kernel runs $p's venv python"    "$got" "$RWS/$p/.venv"
done

echo '=== [18] project-dir agent reaches the root server via labsh-root.sh ==='
got=$(cd "$RWS/pa" && NEXUS_WORKROOT="$RWS" "$LROOT" kernel exec -n nb-pa.ipynb \
    'print("agent-sees-root:", projmarker.NAME)' 2>/dev/null)
assert_contains "exec from inside the project dir works" "$got" "agent-sees-root: pa"
( cd "$RWS/pa" && NEXUS_WORKROOT="$RWS" "$LROOT" notebook attach agent-nb.ipynb --kernel-name proj-pa ) >/dev/null 2>&1
assert_eq "attach of a NEW notebook from the project dir succeeds" "$?" "0"
got=$(cd "$RWS/pa" && NEXUS_WORKROOT="$RWS" "$LROOT" kernel exec -n agent-nb.ipynb \
    'import sys; print(sys.executable)' 2>/dev/null)
assert_contains "agent-attached kernel runs pa's venv" "$got" "$RWS/pa/.venv"
url_root=$(cd "$RWS" && labsh url)
url_proj=$(cd "$RWS/pa" && NEXUS_WORKROOT="$RWS" "$LROOT" url)
assert_eq "labsh-root url from the project dir is the root URL" "$url_proj" "$url_root"

echo '=== [19] crawl discovers a fresh project; re-crawl idempotent ==='
make_proj pd || { echo "FATAL: fixture venv for pd failed" >&2; exit 1; }
# The supervisor's periodic crawl may win the race for any individual
# registration/prune, so assert OUTCOMES here; the exact summary counts
# (registered=/pruned=) are pinned in the hermetic suite.
out=$(crawl_now); rc=$?
assert_eq "crawl exits 0" "$rc" "0"
assert_file_exists "proj-pd kernelspec present" "$KDIR/proj-pd/kernel.json"
out=$(crawl_now)
assert_contains "re-crawl registers nothing" "$out" "registered=0"
assert_eq "still exactly 4 proj-* kernelspecs (no dupes)" "$(compgen -G "$KDIR/proj-*/kernel.json" | wc -l)" "4"

echo '=== [20] removed project → stale kernelspec pruned ==='
rm -rf "$RWS/pd"
crawl_now >/dev/null
assert_no_file "proj-pd kernelspec gone" "$KDIR/proj-pd/kernel.json"

echo '=== [21] coexists with per-project services; auth enforced ==='
assert_eq "projB per-project service still healthy" "$("$HEALTH" "$PROJB" >/dev/null 2>&1; echo $?)" "0"
portroot=$(sed -n 's/^PORT=//p' "$RWS/.jupyter/labsh-service.env")
portb2=$(sed -n 's/^PORT=//p' "$PROJB/.jupyter/labsh-service.env")
assert_eq "root and projB on distinct ports" "$(( portroot != portb2 ))" "1"
bad_rc=$(curl -fsSk -o /dev/null --max-time 5 -H 'Authorization: token WRONG' \
    "$(base_url_of "$RWS")/api/status"; echo $?)
assert_eq "wrong token rejected by root server" "$(( bad_rc != 0 ))" "1"

echo '=== [22] root --down: no orphans, deregistered, kernelspecs kept ==='
srv=$(server_pid_of "$RWS")
sup=$(cat "$NEXUS_STATE_DIR/services/jupyterlab.pid")
out=$("$UP" --root "$RWS" --down 2>&1); rc=$?
assert_eq "root down exits 0" "$rc" "0"
sleep 2
assert_eq "root supervisor dead" "$(kill -0 "$sup" 2>/dev/null; echo $?)" "1"
assert_eq "root server dead"     "$(kill -0 "$srv" 2>/dev/null; echo $?)" "1"
assert_empty "no root row left" "$(awk -F'\t' '$1 == "jupyterlab"' "$NEXUS_SERVICES_REGISTRY")"
# Scope to the fixture: a user-wide pattern could match live kernels
# of unrelated sessions on a shared node.
kcount=$(cd "$RWS" && labsh kernel ps 2>/dev/null | grep -c "$RWS")
assert_eq "no orphan root kernels" "$kcount" "0"
assert_file_exists "kernelspecs survive --down (inert files, by design)" "$KDIR/proj-pa/kernel.json"

echo '=== teardown: --down both ==='
"$UP" "$PROJB" --down >/dev/null 2>&1
"$UP" "$PROJC" --down >/dev/null 2>&1
assert_eq "registry empty at the end" "$(grep -c . "$NEXUS_SERVICES_REGISTRY" || true)" "0"

th_summary_and_exit
