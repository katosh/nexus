#!/usr/bin/env bash
# test-codex-busy-phases.sh — a REAL Codex worker through every busy phase the
# skeptic probed (your-org/nexus-code#1640, skeptic F1/F2), as a regression
# suite. Derived from the skeptic's sk-probe-busy-phases.sh / sk-probe-bgterm.sh
# (report reports/codexharnesssk_2026-09-26_133401_codex-harness-skeptic.md).
#
# THE PROPERTY, per phase: while Codex is WORKING no sample may be
# kill-authorised (bk_pane_kill_authorized — the allowlist retire uses), and
# once the turn has really ENDED the pane must reach idle (not wedge busy):
#
#   S1 a slow STREAMED final answer — no `Working` line (F1)
#   S2 a long tool call
#   S6 a command outliving its yield: the turn ends, the job runs on in a
#      Codex background terminal (F2) — must read never-kill until it exits
#   S3 429 on every request — retries, then a failed turn: must END idle
#   S4 a hang, then Esc — must END idle (Esc never fires Stop)
#
# The real monitor/spawn-worker.sh --harness codex launches the REAL codex TUI
# in a window of a PRIVATE tmux server, pointed at the mock Responses backend
# (monitor/codex-harness/mock-responses.py) — no OpenAI call, no key. The
# isolation below is test-codex-worker-e2e.sh's, pin for pin.
#
# Gated like every test-integration/ scenario: runs only with
# RUN_INTEGRATION=1, and SKIPs (77) when the pinned codex is not installed.
#
# ISOLATION — every pin, and why each is needed (all measured building this):
#   * a PRIVATE server (`-L cxp` under a SHORT TMUX_TMPDIR in /tmp: sun_path
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/codexphase.XXXXXX") || th_abort "mktemp failed"
SOCKDIR=$(mktemp -d /tmp/cxp.XXXX) || th_abort "mktemp socket dir failed"
SOCK="$SOCKDIR/tmux-$(id -u)/cxp"
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
        KEPT=$(mktemp -d "${TMPDIR:-/tmp}/codexphase-kept.XXXXXX") && cp -a "$WORK/." "$KEPT/" \
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
model_providers.nexusmock={name="nexusmock",base_url="http://127.0.0.1:$PORT/v1",wire_api="responses",stream_max_retries=2,request_max_retries=2}
notice.model_migrations={"gpt-5.5"="gpt-6-sol"}
EOF

# ---- private tmux -------------------------------------------------------------
# The private TMUX_TMPDIR is EXPORTED in a subshell rather than prefixed onto
# the call (your-org/nexus-code#1643): the tmux-socket lint reads a
# `TMUX_TMPDIR=… <word containing tmux>` line as a tmux invocation scoped only
# by TMUX_TMPDIR (rule2, unexemptable by design), and it refused the whole
# cc-harness gate. The shim written is byte-identical either way (measured:
# `env -u TMUX TMUX_TMPDIR=<dir> <real tmux> -L cxp`), and the subshell keeps
# the suite's own environment unchanged.
# #1646 taught rule2 this subshell shape too, so the line now carries the
# COUNTED `# tmux-shim-writer:` pragma, which exempts nx_write_tmux_shim alone.
( export TMUX_TMPDIR="$SOCKDIR"; nx_write_tmux_shim "$WORK/bin" "$REAL_TMUX" cxp ) || th_abort "could not write the private tmux shim"   # tmux-shim-writer: writes `env -u TMUX … -L cxp`, not a tmux call
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

# shellcheck source=../../_bookkeeping.sh
. "$MON/_bookkeeping.sh" || th_abort "cannot source _bookkeeping.sh"
_type() { "$PTMUX" send-keys -t 0:cxw -l "$1"; sleep 0.5; "$PTMUX" send-keys -t 0:cxw Enter; }
# _phase <label> <seconds> <until-cmd> : sample every 2 s; record every state;
# stop early when <until-cmd> succeeds. Sets SEEN (all states) and KILLOK
# (the kill-authorised ones).
_phase() {
    local label="$1" dur="$2" until="$3" t0 s
    SEEN=""; KILLOK=""; t0=$(date +%s)
    while (( $(date +%s) - t0 < dur )); do
        s=$(_pstate cxw); SEEN+="${s:-?} "
        bk_pane_kill_authorized "$s" && KILLOK+="$s@$(( $(date +%s) - t0 ))s "
        eval "$until" && break
        sleep 2
    done
    printf '    %s: %s\n' "$label" "$SEEN" >&2
}
_idle() { [[ "$(_pstate cxw)" == idle ]]; }

_ctl '{"mode":"text","text":"ready"}'
RC=0; "${PIN[@]}" bash "$MON/spawn-worker.sh" -n cxw -c "$WD" -p "$WORK/task.txt" \
         --harness codex --model gpt-5.5 --skeptic deny >"$WORK/spawn.out" 2>&1 || RC=$?
assert_rc "spawn-worker.sh --harness codex -> rc 0" "$RC" "0"
_phase boot 60 _idle
assert_eq "boot settles idle" "$(_pstate cxw)" "idle"

echo "=== S1: a slow streamed final answer (F1) ==="
_ctl "{\"mode\":\"text\",\"drip_ms\":1000,\"text\":\"$(for i in $(seq 1 40); do printf 'w%d ' "$i"; done | sed 's/ $//')\"}"
_type "S1 stream please"
_phase S1-stream 30 false
assert_eq "no kill-authorised sample while the answer streams" "$KILLOK" ""
_phase S1-after 60 _idle
assert_eq "…and idle once it is done (no wedge)" "$(_pstate cxw)" "idle"

echo "=== S2: a long tool call ==="
_ctl '{"steps":[{"mode":"shell","command":"sleep 25; echo S2"},{"mode":"text","text":"S2-DONE"}]}'
_type "S2 long command"
_phase S2-tool 20 false
assert_eq "no kill-authorised sample during a long tool call" "$KILLOK" ""
_phase S2-after 60 _idle

echo "=== S6: the turn ends, a background terminal runs on (F2) ==="
_ctl '{"steps":[{"mode":"shell","command":"sleep 75; echo BGDONE > bg.txt"},{"mode":"text","text":"S6 turn over, command still running"}]}'
_type "S6 start a long command"
_phase S6-job 60 '[[ -f "$WD/bg.txt" ]]'
assert_contains "the background job was seen as working-background" "$SEEN" "working-background"
assert_eq "no kill-authorised sample while the background job lives" "$KILLOK" ""
_phase S6-after 60 '[[ -f "$WD/bg.txt" ]] && _idle'
assert_eq "the job finished on its own (retire would have killed it)" "$(cat "$WD/bg.txt" 2>/dev/null)" "BGDONE"

echo "=== S3: 429 on every request — a FAILED turn must end idle ==="
_ctl '{"mode":"error","status":429,"error_text":"Rate limit reached"}'
_type "S3 rate limited"
_phase S3-429 150 _idle
assert_eq "a failed turn (no Stop fires) still ends idle — no wedge" "$(_pstate cxw)" "idle"

echo "=== S4: a hang, then Esc ==="
_ctl '{"mode":"hang"}'
_type "S4 hang"
_phase S4-hang 12 false
assert_eq "no kill-authorised sample while hung in a turn" "$KILLOK" ""
"$PTMUX" send-keys -t 0:cxw Escape
_phase S4-esc 90 _idle
assert_eq "after Esc (no Stop fires) the pane ends idle — no wedge" "$(_pstate cxw)" "idle"

EXPECTED_ASSERTIONS=11
TOTAL_ASSERTIONS=$(( PASS + FAIL + ${SKIP:-0} ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
