#!/usr/bin/env bash
# test-codex-run-real.sh — monitor/codex-run.sh driving the REAL codex binary
# against the mock Responses backend (your-org/nexus-code#1640, layer 1).
#
# The other half of test-codex-run.sh. That suite's stub encodes the event
# vocabulary as measured; this one asks the installed binary whether it still
# emits it, end to end: a real tool call executed by codex, the exact diff,
# a real API error surfaced as turn-failed, a hung backend bounded as a
# timeout, and `--resume` continuing the SAME thread with its history.
#
# NO OPENAI CALL, NO REAL KEY. codex is pointed at
# monitor/codex-harness/mock-responses.py through a custom model provider
# (`--config model_provider=…`); OPENAI_API_KEY/CODEX_API_KEY are unset and
# a dummy CODEX_API_KEY is supplied. Measured: the custom provider declares no
# env_key, so codex sends no Authorization header to the mock at all. CODEX_HOME is a scratch dir.
#
# SKIPS (exit 77) when the pinned binary is not installed
# (monitor/install-codex-local.sh) — CI does not install it, so there this
# suite is a declared SKIP, never a pass.
#
# Model: `gpt-5.5`, CHOSEN for the mock, not for production. Measured on
# 0.156.1: the gpt-6 catalogue entries route shell through a JavaScript
# code-mode tool (`exec`), gpt-5.5 exposes the plain `exec_command` function
# the mock can script. The model id only selects the tool surface here; the
# mock serves every model.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Population (skeptic F5, #1640): the helper, its resolver library and the
# mock backend it drives the real binary against.
# shellcheck disable=SC1091
. "$_self_dir/../_guard_population.sh"
gp_population() { printf '%s\n' monitor/codex-run.sh monitor/_codex.sh monitor/codex-harness/mock-responses.py; }
gp_handle "$@"
# shellcheck source=_test_helpers.sh
. "$_self_dir/_test_helpers.sh"

MON=$(cd "$_self_dir/.." && pwd)
RUN="$MON/codex-run.sh"
MOCK="$MON/codex-harness/mock-responses.py"
BIN="${CODEX_BIN:-$MON/../codex-cli/node_modules/.bin/codex}"
if [[ ! -x "$BIN" ]]; then
    printf '  SKIP: real codex binary not installed at %s — run monitor/install-codex-local.sh (a SKIP is not a pass)\n' "$BIN" >&2
    exit 77
fi
[[ -r "$MOCK" ]] || th_abort "mock backend missing: $MOCK"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/codexreal.XXXXXX") || th_abort "mktemp failed"
MOCK_PID=""
_cleanup() {
    [[ -n "$MOCK_PID" ]] && th_kill_own_child "$MOCK_PID" TERM
    rm -rf "$WORK"
}
trap _cleanup EXIT

mkdir -p "$WORK/mock" "$WORK/codexhome"
MOCK_DIR="$WORK/mock" MOCK_LOG_BODY=1 python3 "$MOCK" >"$WORK/mock.out" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 50); do [[ -s "$WORK/mock/port" ]] && break; sleep 0.1; done
PORT=$(cat "$WORK/mock/port" 2>/dev/null)
[[ "$PORT" =~ ^[0-9]+$ ]] || th_abort "mock backend did not publish a port (see $WORK/mock.out)"

REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q . || th_abort "git init"
th_require_fixture_repo "$REPO" "codex-run-real fixture repo"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init || th_abort "fixture commit"
echo "create the file new.txt" > "$WORK/task.txt"

_ctl() { printf '%s\n' "$1" > "$WORK/mock/control.json"; }
# _run <tag> [args…] ; sets RC OUT OUT_DIR
_run() {
    local o="$WORK/out-$1"; shift
    RC=0
    OUT=$(env -u OPENAI_API_KEY CODEX_API_KEY=mock-dummy-not-a-key \
              CODEX_HOME="$WORK/codexhome" CODEX_BIN="$BIN" \
              bash "$RUN" --cd "$REPO" --prompt-file "$WORK/task.txt" --out "$o" --model gpt-5.5 \
                   --config model_provider=nexusmock \
                   --config "model_providers.nexusmock={name=\"nexusmock\",base_url=\"http://127.0.0.1:$PORT/v1\",wire_api=\"responses\"}" \
                   "$@" </dev/null 2>"$o.stderr") || RC=$?
    OUT_DIR="$o"
}

echo "=== 1. a real tool call, an exact diff ==="
_ctl '{"steps":[{"mode":"shell","command":"echo hello-from-real-codex > new.txt"},{"mode":"text","text":"wrote new.txt"}]}'
_run shell --timeout 120
assert_rc       "completed -> rc 0" "$RC" "0"
assert_eq       "codex EXECUTED the command (commands=1, failed=0)" \
                "$(awk -F= '$1=="commands"||$1=="commands_failed"{printf "%s=%s ",$1,$2}' "$OUT_DIR/status")" "commands=1 commands_failed=0 "
assert_contains "diff.patch holds the file codex's command wrote" "$(cat "$OUT_DIR/diff.patch" 2>/dev/null)" "+hello-from-real-codex"
assert_eq       "final message captured" "$(cat "$OUT_DIR/last-message.txt" 2>/dev/null)" "wrote new.txt"
assert_eq       "caller's index untouched" "$(git -C "$REPO" diff --cached --name-only)" ""
# Measured: a custom provider with no env_key gets NO Authorization header at
# all, so the only correct set is {""}; any key, real or dummy, would show
# here as a "Bearer …" prefix.
assert_eq       "the mock received NO Authorization header (no key of any kind)" \
                "$(python3 -c 'import json,sys; print(sorted({json.loads(l).get("auth_prefix","") for l in open(sys.argv[1]) if l.strip() and json.loads(l).get("method")=="POST"}))' "$WORK/mock/requests.jsonl")" \
                "['']"
rm -f "$REPO/new.txt"

echo "=== 2. a backend error is turn-failed, typed ==="
_ctl '{"mode":"error","status":429,"error_text":"Quota exceeded. Check your plan and billing details."}'
_run err --timeout 180
assert_rc       "429 -> rc 3 turn-failed" "$RC" "3"
assert_contains "verdict line names turn-failed" "$OUT" "verdict=turn-failed"

echo "=== 3. a hung backend is a timeout, not a hang ==="
_ctl '{"mode":"hang"}'
t0=$(date +%s)
_run hang --timeout 6
t1=$(date +%s)
assert_rc "hang -> rc 4 timeout" "$RC" "4"
if (( t1 - t0 <= 40 )); then assert_eq "bounded: returned within 40 s of a 6 s bound" "ok" "ok"
else assert_eq "bounded: returned within 40 s of a 6 s bound" "$(( t1 - t0 ))s" "<=40s"; fi

echo "=== 4. --resume continues the SAME thread, with its history ==="
_ctl '{"mode":"text","text":"FIRST-TURN-ANSWER"}'
_run r1 --timeout 120
assert_rc "first turn -> rc 0" "$RC" "0"
T1=$(awk -F= '$1=="thread_id"{print $2}' "$OUT_DIR/status")
[[ "$T1" =~ ^[0-9a-f-]{36}$ ]] || th_abort "first turn recorded no thread id (got '$T1')"
_ctl '{"mode":"text","text":"SECOND-TURN-ANSWER"}'
_run r2 --timeout 120 --resume "$T1"
assert_rc "resumed turn -> rc 0" "$RC" "0"
assert_eq "resumed turn reports the SAME thread id" "$(awk -F= '$1=="thread_id"{print $2}' "$OUT_DIR/status")" "$T1"
assert_contains "the resumed request CARRIED turn 1's answer (history, not a fresh thread)" \
                "$(tail -n1 "$WORK/mock/requests.jsonl")" "FIRST-TURN-ANSWER"

EXPECTED_ASSERTIONS=14
TOTAL_ASSERTIONS=$(( PASS + FAIL + ${SKIP:-0} ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
