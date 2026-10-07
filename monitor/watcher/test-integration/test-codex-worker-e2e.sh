#!/usr/bin/env bash
# test-codex-worker-e2e.sh — a REAL Codex worker, end to end
# (your-org/nexus-code#1640, layer 2).
#
# The real monitor/spawn-worker.sh --harness codex launches the REAL codex TUI
# in a window of a PRIVATE tmux server, pointed at the mock Responses backend
# (monitor/codex-harness/mock-responses.py) — no OpenAI call, no key. Then:
#
#   1. the worker runs its task: codex executes a real tool call;
#   2. pane-state follows it through busy to idle and NEVER reads `absent`
#      (before #1640 a Codex pane root read absent — kill-authorised);
#   3. the Codex hooks keep the nexus heartbeat and submit-stamp current, and
#      SessionStart records the thread id in the window's descriptor;
#   4. `ng send` delivers a follow-up and `ng send --check` confirms it on the
#      submit-stamp receipt;
#   5. `spawn-worker.sh --resume` brings the window back as `codex resume`,
#      carrying the thread's history.
#
# Gated like every test-integration/ scenario: runs only with
# RUN_INTEGRATION=1, and SKIPs (77) when the pinned codex is not installed.
#
# ISOLATION — every pin, and why each is needed (all measured building this):
#   * a PRIVATE server (`-L cxe` under a SHORT TMUX_TMPDIR in /tmp: sun_path
#     is 107 usable bytes; the dir holds the socket and nothing else), reached
#     through the standard shim nx_write_tmux_shim writes
#     (monitor/watcher/_tmux-fixture.sh) — provably a real binary, no marker,
#     so monitor/tmuxwrap, which spawn-worker.sh re-fronts through $BASH_ENV,
#     treats it as the real tmux and execs it;
#   * NEXUS_TMUX_SOCKET = that socket, so the re-fronted tmuxwrap pins to it;
#   * a real CLIENT attached to the private server (`script` gives it a pty):
#     spawn-worker's server check is `tmux info`, which on tmux 2.6 needs a
#     current client — a headless server has none and answers "no current
#     client" (exit 8), which is why no suite drove the real spawn-worker.sh
#     on a real server before this one;
#   * the session is named `0`: pane-state.sh resolves a window NAME to
#     `0:<index>`, the board's session name.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_self_dir/../.." && pwd)
REPO=$(cd "$MON/.." && pwd)
# Population (skeptic F5, #1640), declared BEFORE the RUN_INTEGRATION gate so
# the index can ask even where the scenario would SKIP: the whole Codex
# worker path this scenario drives for real.
# shellcheck disable=SC1091
. "$MON/_guard_population.sh"
gp_population() {
    printf '%s\n' monitor/spawn-worker.sh monitor/_spawn-codex.sh monitor/codex-hook.sh \
        monitor/_pane-state-codex.sh monitor/pane-state.sh monitor/harness/codex.sh
}
gp_handle "$@"
# shellcheck source=../_test_helpers.sh
. "$MON/watcher/_test_helpers.sh"

if [[ "${RUN_INTEGRATION:-0}" != "1" ]]; then
    printf '  SKIP: set RUN_INTEGRATION=1 to run this real-binary scenario (a SKIP is not a pass)\n' >&2
    exit 77
fi
BIN="${CODEX_BIN:-$REPO/codex-cli/node_modules/.bin/codex}"
if [[ ! -x "$BIN" ]]; then
    printf '  SKIP: real codex binary not installed at %s — run monitor/install-codex-local.sh\n' "$BIN" >&2
    exit 77
fi
. "$MON/watcher/_tmux-fixture.sh"
REAL_TMUX=$(nx_real_tmux_bin) || { printf '  SKIP: no real tmux BINARY on PATH (only wrappers)\n' >&2; exit 77; }
command -v script >/dev/null 2>&1 || { printf '  SKIP: no `script` to give the private server a client pty\n' >&2; exit 77; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/codexe2e.XXXXXX") || th_abort "mktemp failed"
SOCKDIR=$(mktemp -d /tmp/cxe.XXXX) || th_abort "mktemp socket dir failed"
SOCK="$SOCKDIR/tmux-$(id -u)/cxe"
PTMUX="$WORK/bin/tmux"
MOCK_PID=""
_cleanup() {
    if [[ -x "$PTMUX" ]]; then
        [[ -n "${CODEX_E2E_KEEP:-}" ]] && "$PTMUX" capture-pane -p -t 0:cxw > "$WORK/final-pane.txt" 2>/dev/null
        "$PTMUX" kill-server 2>/dev/null   # tmux-scoped: PTMUX is nx_write_tmux_shim's -L-pinned private shim
    fi
    [[ -n "$MOCK_PID" ]] && th_kill_own_child "$MOCK_PID" TERM
    rm -rf "$SOCKDIR"
    # CODEX_E2E_KEEP=1 COPIES the artefacts (mock request log, state, the
    # workdir, the final pane) to a directory this trap never removes, and
    # cites THAT — never a path the trap is about to delete (#794).
    if [[ -n "${CODEX_E2E_KEEP:-}" ]]; then
        KEPT=$(mktemp -d "${TMPDIR:-/tmp}/codexe2e-kept.XXXXXX") && cp -a "$WORK/." "$KEPT/" \
            && printf '  kept: %s\n' "$KEPT" >&2
    fi
    rm -rf "$WORK"
}
trap _cleanup EXIT

# ---- mock backend -----------------------------------------------------------
mkdir -p "$WORK/mock"
MOCK_DIR="$WORK/mock" MOCK_LOG_BODY=1 python3 "$MON/codex-harness/mock-responses.py" >"$WORK/mock.out" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do [[ -s "$WORK/mock/port" ]] && break; sleep 0.1; done
PORT=$(cat "$WORK/mock/port" 2>/dev/null)
[[ "$PORT" =~ ^[0-9]+$ ]] || th_abort "mock backend did not publish a port"
_ctl() { printf '%s\n' "$1" > "$WORK/mock/control.json"; }
cat > "$WORK/mock.cfg" <<EOF
model_provider=nexusmock
model_providers.nexusmock={name="nexusmock",base_url="http://127.0.0.1:$PORT/v1",wire_api="responses"}
notice.model_migrations={"gpt-5.5"="gpt-6-sol"}
EOF

# ---- private tmux -------------------------------------------------------------
# The private TMUX_TMPDIR is EXPORTED in a subshell rather than prefixed onto
# the call (your-org/nexus-code#1643): the tmux-socket lint reads a
# `TMUX_TMPDIR=… <word containing tmux>` line as a tmux invocation scoped only
# by TMUX_TMPDIR (rule2, unexemptable by design), and it refused the whole
# cc-harness gate. The shim written is byte-identical either way (measured:
# `env -u TMUX TMUX_TMPDIR=<dir> <real tmux> -L cxe`), and the subshell keeps
# the suite's own environment unchanged.
# #1646 taught rule2 this subshell shape too, so the line now carries the
# COUNTED `# tmux-shim-writer:` pragma, which exempts nx_write_tmux_shim alone.
( export TMUX_TMPDIR="$SOCKDIR"; nx_write_tmux_shim "$WORK/bin" "$REAL_TMUX" cxe ) || th_abort "could not write the private tmux shim"   # tmux-shim-writer: writes `env -u TMUX … -L cxe`, not a tmux call
th_tmux_fixture_conf "$WORK/tmux.conf"
"$PTMUX" -f "$WORK/tmux.conf" new-session -d -s 0 -x 170 -y 50 'sleep 36000' \
    || th_abort "could not start the private tmux server"
[[ -S "$SOCK" ]] || th_abort "private socket not at $SOCK"
# The client `tmux info` needs (header). It exits with the server.
( script -qfc "$PTMUX attach -t 0" /dev/null </dev/null >/dev/null 2>&1 & )
for _ in $(seq 1 40); do [[ -n "$("$PTMUX" list-clients 2>/dev/null)" ]] && break; sleep 0.25; done
[[ -n "$("$PTMUX" list-clients 2>/dev/null)" ]] || th_abort "no client attached to the private server"

WD="$WORK/wd"; mkdir -p "$WD"
git -C "$WD" init -q . && git -C "$WD" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    || th_abort "workdir repo"
th_require_fixture_repo "$WD" "codex e2e workdir"
echo "Create done.txt. This is an end-to-end harness test." > "$WORK/task.txt"
STATE="$WORK/state"; CH="$WORK/codexhome"; mkdir -p "$STATE" "$CH"

PIN=(env -u OPENAI_API_KEY -u CODEX_API_KEY -u MONITOR_RETAIN_USE_LOOP_WRAPPER -u TMUX
     TMUX_TMPDIR="$SOCKDIR" NEXUS_TMUX_SOCKET="$SOCK" PATH="$WORK/bin:$PATH"
     NEXUS_ALLOW_SECONDARY_ROOT=1 NEXUS_ROOT="$REPO" NEXUS_STATE_DIR="$STATE"
     CODEX_HOME="$CH" CODEX_BIN="$BIN" NEXUS_CODEX_EXTRA_CONFIG_FILE="$WORK/mock.cfg")
_pstate() { "${PIN[@]}" bash "$MON/pane-state.sh" "$1" 2>/dev/null | sed -n 's/^state=\([^ ]*\).*/\1/p'; }

echo "=== 1-2. spawn; the worker runs its task; pane-state follows it ==="
_ctl '{"steps":[{"mode":"shell","command":"sleep 5; echo worked > done.txt"},{"mode":"text","text":"TASK-DONE"}]}'
RC=0; OUT=$("${PIN[@]}" bash "$MON/spawn-worker.sh" -n cxw -c "$WD" -p "$WORK/task.txt" \
             --harness codex --model gpt-5.5 --skeptic deny 2>&1) || RC=$?
assert_rc "spawn-worker.sh --harness codex -> rc 0" "$RC" "0"
seen=""; t0=$(date +%s)
while (( $(date +%s) - t0 < 90 )); do
    s=$(_pstate cxw); seen+="${s:-?} "
    [[ "$s" == idle && -f "$WD/done.txt" ]] && break
    sleep 1
done
assert_contains     "the pane was seen BUSY during the turn" "$seen" "busy"
assert_not_contains "and NEVER absent (a Codex pane is a live agent)" "$seen" "absent"
assert_eq           "…and settles idle" "$(_pstate cxw)" "idle"
assert_eq           "codex executed the task's tool call" "$(cat "$WD/done.txt" 2>/dev/null)" "worked"

echo "=== 3. hooks: heartbeat, submit-stamp, descriptor thread id ==="
HB="$STATE/heartbeat/cxw.json"
assert_eq "heartbeat idle_prompt after Stop" "$(jq -r .state "$HB" 2>/dev/null)" "idle_prompt"
SID=$(jq -r '.session_id // ""' "$HB" 2>/dev/null)
[[ "$SID" =~ ^[0-9a-f-]{36}$ ]] || th_abort "heartbeat carries no thread id (got '$SID')"
assert_eq "SessionStart recorded that thread id in the descriptor" "$(jq -r .session_id "$STATE/windows/cxw.json")" "$SID"
assert_eq "the submit-stamp carries the same thread id" "$(cut -f2 "$STATE/user-prompt/cxw" 2>/dev/null)" "$SID"

echo "=== 4. ng send: delivered, confirmed on the submit-stamp ==="
_ctl '{"mode":"text","text":"FOLLOWUP-RECEIVED"}'
printf 'FOLLOWUP-SENTINEL-6620: please acknowledge.\n' > "$WORK/msg.txt"
"${PIN[@]}" timeout 120 bash "$MON/ng" send cxw --file "$WORK/msg.txt" >"$WORK/send.out" 2>&1
t0=$(date +%s)
while (( $(date +%s) - t0 < 60 )); do
    grep -qF 'FOLLOWUP-SENTINEL-6620' "$WORK/mock/requests.jsonl" 2>/dev/null && [[ "$(_pstate cxw)" == idle ]] && break
    sleep 1
done
assert_contains "the follow-up reached the model (the mock saw its bytes)" \
    "$(cat "$WORK/mock/requests.jsonl" 2>/dev/null)" "FOLLOWUP-SENTINEL-6620"
RC=0; "${PIN[@]}" bash "$MON/ng" send cxw --check --last >"$WORK/check.out" 2>&1 || RC=$?
assert_rc       "ng send --check -> delivered (rc 0)" "$RC" "0"
assert_contains "…on the submit-stamp receipt" "$(cat "$WORK/check.out")" "receipt=submit-stamp"

echo "=== 5. --resume comes back as \`codex resume\`, with the thread's history ==="
_ctl '{"mode":"text","text":"RESUMED-OK"}'
RC=0; "${PIN[@]}" bash "$MON/spawn-worker.sh" --resume cxw --replace --nudge >"$WORK/resume.out" 2>&1 || RC=$?
assert_rc       "spawn-worker.sh --resume cxw --replace -> rc 0" "$RC" "0"
assert_contains "…resolved to the recorded thread, as a Codex resume" "$(grep -F 'harness=codex' "$WORK/resume.out")" "session=$SID"
# Wait for the RESUMED turn: the request carrying the nudge. Measured: on
# resume codex first runs a CONTEXT COMPACTION request, and its side requests
# (title generation) QUOTE the nudge too — so neither "the last request" nor
# "the last request mentioning the nudge" is the turn. The turn is the
# nudge-bearing request with the LONGEST input (the whole thread).
_resumed_req() {
    python3 - "$WORK/mock/requests.jsonl" <<'PYSEL' 2>/dev/null
import json, sys
best = None
try:
    lines = open(sys.argv[1]).read().splitlines()
except Exception:
    lines = []
for ln in lines:
    try:
        r = json.loads(ln)
    except Exception:
        continue
    if 'interrupted mid-task' not in ln:
        continue
    n = len((r.get('body') or {}).get('input') or [])
    if best is None or n > best[0]:
        best = (n, ln)
if best:
    print(best[1])
PYSEL
}
t0=$(date +%s)
while (( $(date +%s) - t0 < 90 )); do
    [[ -n "$(_resumed_req)" ]] && break
    sleep 1
done
RREQ=$(_resumed_req)
assert_contains "the resumed turn reached the model carrying the resume nudge" "$RREQ" "interrupted mid-task"
assert_contains "…and the thread's HISTORY (the earlier turn's message survives compaction)" "$RREQ" "FOLLOWUP-SENTINEL-6620"

EXPECTED_ASSERTIONS=15
TOTAL_ASSERTIONS=$(( PASS + FAIL + ${SKIP:-0} ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
