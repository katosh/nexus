#!/usr/bin/env bash
# Unit tests for monitor/claude-loop.sh (issue #75).
#
# Run: bash monitor/watcher/test-claude-loop.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: stub `claude` with a tiny bash script that records each
# invocation (counter + argv snapshot) and exits with a controlled
# rc. Build a temp state-dir that holds a synthetic action-log so
# the retain-event lookup resolves to a known epoch. Drive
# claude-loop.sh with small TTLs / max-restarts / backoff so every
# stop condition fires within a couple seconds.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOOP_SCRIPT_REAL="$_test_dir/../claude-loop.sh"

[[ -x "$LOOP_SCRIPT_REAL" ]] || {
    echo "test-claude-loop: $LOOP_SCRIPT_REAL not executable" >&2
    exit 2
}

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_ge() {
    local label="$1" got="$2" want="$3"
    if (( got >= want )); then
        printf '  PASS: %s (got=%s, ≥ %s)\n' "$label" "$got" "$want"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %s, want ≥ %s\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/state"
ACTION_LOG="$STATE_DIR/action-log.jsonl"
SENTINEL_DIR="$STATE_DIR/loop-stop"
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STATE_DIR" "$SENTINEL_DIR" "$STUB_BIN"

# Stub `claude`: increments a counter file and exits 0. Captures
# its argv so we can assert --continue is used on respawns.
CLAUDE_COUNTER="$WORK/claude-calls.txt"
CLAUDE_ARGS_LOG="$WORK/claude-args.log"
: > "$CLAUDE_COUNTER"
: > "$CLAUDE_ARGS_LOG"

cat > "$STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
# Append one byte per call so wc -c is the call count.
printf '.' >> "$CLAUDE_COUNTER"
# Record argv (one line per call).
printf '%s\n' "\$*" >> "$CLAUDE_ARGS_LOG"
exit 0
STUB
chmod +x "$STUB_BIN/claude"

# Helper: write a window-retain event with epoch=$1 (offset from
# 'now' in seconds; negative for past). Returns the iso ts on stdout.
seed_retain() {
    local offset_s="$1" window="$2"
    local ts
    ts=$(date -d "@$(( $(date +%s) + offset_s ))" -Is)
    printf '{"ts":"%s","agent":"monitor","event":"window-retain","window":"%s","reason":"test"}\n' \
        "$ts" "$window" >> "$ACTION_LOG"
    printf '%s\n' "$ts"
}

# Helper: invoke claude-loop with shared defaults; caller supplies
# any extra flags (--max-restarts, --retain-ttl-seconds, etc).
WIN_DEFAULT="loop-test"
PROMPT_FILE="$WORK/prompt.txt"
printf 'INITIAL_PROMPT_TOKEN_5d4e\n' > "$PROMPT_FILE"

run_loop() {
    # CLAUDE_BIN env override pins the loop to the stub regardless of
    # whether $NEXUS_ROOT/node_modules/.bin/claude exists; without it,
    # claude-loop.sh's _claude-bin.sh resolver would prefer the real
    # project-local install and bypass the stub entirely.
    PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" timeout 30s \
        "$LOOP_SCRIPT_REAL" \
        --window "$WIN_DEFAULT" \
        --prompt-file "$PROMPT_FILE" \
        --state-dir "$STATE_DIR" \
        --backoff-base 1 \
        "$@"
}

reset_state() {
    : > "$CLAUDE_COUNTER"
    : > "$CLAUDE_ARGS_LOG"
    : > "$ACTION_LOG"
    rm -f "$SENTINEL_DIR/${WIN_DEFAULT}.flag"
    # Re-create prompt file (consumed by --no-cleanup-prompt absent)
    printf 'INITIAL_PROMPT_TOKEN_5d4e\n' > "$PROMPT_FILE"
}

calls() { wc -c <"$CLAUDE_COUNTER" | tr -d ' '; }

# ---- Test 1: no retain event → exits after one run, code 10 ------------
echo '=== no window-retain event ⇒ stops after first run with code 10 ==='
reset_state
out=$(run_loop --max-restarts 5 --retain-ttl-seconds 60 2>&1)
rc=$?
assert_eq      "exit 10 (no-retain-event)"             "$rc"           "10"
assert_eq      "claude invoked exactly once"           "$(calls)"      "1"
assert_contains "first call had no --continue"         "$(head -1 $CLAUDE_ARGS_LOG)" "INITIAL_PROMPT_TOKEN_5d4e"

# ---- Test 2: retain event recent + max-restarts=3 → 4 runs, code 11 ----
echo '=== recent retain + max-restarts=3 ⇒ 4 runs (1 first + 3 respawns), code 11 ==='
reset_state
seed_retain -5 "$WIN_DEFAULT" >/dev/null
out=$(run_loop --max-restarts 3 --retain-ttl-seconds 3600 2>&1)
rc=$?
assert_eq      "exit 11 (max-restarts)"                "$rc"           "11"
assert_eq      "claude invoked 4 times"                "$(calls)"      "4"
# Respawns must use --continue (first call did not).
respawn_lines=$(tail -n +2 "$CLAUDE_ARGS_LOG")
if grep -qF -- "--continue" <<<"$respawn_lines"; then
    printf '  PASS: respawn invocations include --continue\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: respawn invocations missing --continue (got:\n%s\n)\n' "$respawn_lines" >&2
    FAIL=$(( FAIL + 1 ))
fi
# First call must NOT include --continue.
first_call=$(head -1 "$CLAUDE_ARGS_LOG")
if grep -qF -- "--continue" <<<"$first_call"; then
    printf '  FAIL: first call unexpectedly includes --continue (%s)\n' "$first_call" >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: first call does NOT include --continue\n'; PASS=$(( PASS + 1 ))
fi

# ---- Test 3: retain TTL expired (event 1h old, TTL=10s) → code 10 ------
echo '=== retain event older than TTL ⇒ stops after first run, code 10 ==='
reset_state
seed_retain -3600 "$WIN_DEFAULT" >/dev/null
out=$(run_loop --max-restarts 5 --retain-ttl-seconds 10 2>&1)
rc=$?
assert_eq      "exit 10 (retain-ttl-expired)"          "$rc"           "10"
assert_eq      "claude invoked exactly once"           "$(calls)"      "1"

# ---- Test 4: pre-start sentinel → 0 runs, code 0 -----------------------
echo '=== pre-start sentinel ⇒ no claude invocation, code 0 ==='
reset_state
seed_retain -5 "$WIN_DEFAULT" >/dev/null
touch "$SENTINEL_DIR/${WIN_DEFAULT}.flag"
out=$(run_loop --max-restarts 5 --retain-ttl-seconds 3600 2>&1)
rc=$?
assert_eq      "exit 0 on pre-start sentinel"          "$rc"           "0"
assert_eq      "claude not invoked"                    "$(calls)"      "0"
if [[ -e "$SENTINEL_DIR/${WIN_DEFAULT}.flag" ]]; then
    printf '  FAIL: sentinel not consumed on stop\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: sentinel consumed on stop\n'; PASS=$(( PASS + 1 ))
fi

# ---- Test 5: sentinel mid-loop → stops cleanly, code 0 -----------------
#
# Strategy: replace the stub claude with one that touches the
# sentinel on its FIRST call. That way the first run runs claude
# normally, the loop checks the sentinel between runs, sees it,
# and stops with code 0.
echo '=== mid-loop sentinel ⇒ first run completes then loop stops, code 0 ==='
reset_state
seed_retain -5 "$WIN_DEFAULT" >/dev/null

cat > "$STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
printf '.' >> "$CLAUDE_COUNTER"
printf '%s\n' "\$*" >> "$CLAUDE_ARGS_LOG"
# Drop a sentinel after we've run once so the loop terminates.
touch "$SENTINEL_DIR/${WIN_DEFAULT}.flag"
exit 0
STUB
chmod +x "$STUB_BIN/claude"

out=$(run_loop --max-restarts 5 --retain-ttl-seconds 3600 2>&1)
rc=$?
assert_eq      "exit 0 on mid-loop sentinel"           "$rc"           "0"
# Should have run claude exactly once: sentinel set during first
# run, loop sees it before the respawn.
assert_eq      "claude invoked exactly once"           "$(calls)"      "1"
if [[ -e "$SENTINEL_DIR/${WIN_DEFAULT}.flag" ]]; then
    printf '  FAIL: sentinel not consumed on stop\n' >&2; FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: sentinel consumed on stop\n'; PASS=$(( PASS + 1 ))
fi

# ---- Test 6: --settings flag forwarded to claude -----------------------
echo '=== --settings <path> forwarded to claude invocations ==='
# Restore the simple-counter stub for this test.
cat > "$STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
printf '.' >> "$CLAUDE_COUNTER"
printf '%s\n' "\$*" >> "$CLAUDE_ARGS_LOG"
exit 0
STUB
chmod +x "$STUB_BIN/claude"

reset_state
SETTINGS_PATH="$WORK/fake-hooks.json"
printf '{}\n' > "$SETTINGS_PATH"
out=$(run_loop --max-restarts 0 --retain-ttl-seconds 3600 --settings "$SETTINGS_PATH" 2>&1)
rc=$?
# With max-restarts=0 and no retain event, the loop runs once then
# stops on no-retain-event (code 10). Argv of first call should
# carry --settings <path>.
assert_eq      "exit 10 (no retain seeded)"            "$rc"           "10"
first_call=$(head -1 "$CLAUDE_ARGS_LOG")
assert_contains "first call carries --settings"        "$first_call"   "--settings $SETTINGS_PATH"

# ---- Test 7: env override MONITOR_RETAIN_TTL_SECONDS honoured ----------
echo '=== MONITOR_RETAIN_TTL_SECONDS env override honoured ==='
reset_state
seed_retain -200 "$WIN_DEFAULT" >/dev/null
# Retain event is 200s old. Env TTL=60 → expired. Without flag.
out=$(
    PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
        MONITOR_RETAIN_TTL_SECONDS=60 timeout 30s \
        "$LOOP_SCRIPT_REAL" \
        --window "$WIN_DEFAULT" \
        --prompt-file "$PROMPT_FILE" \
        --state-dir "$STATE_DIR" \
        --backoff-base 1 \
        --max-restarts 5 \
        2>&1
)
rc=$?
assert_eq      "exit 10 (env TTL=60 expires retain)"   "$rc"           "10"
assert_eq      "claude invoked exactly once"           "$(calls)"      "1"

# ---- Test 9: resume-prompt env vars exported to claude -----------------
#
# Regression for the stale-large-session resume dialog: Claude Code
# blocks `--continue` on an interactive picker ("Resume from summary
# / Resume full session as-is / Don't ask me again") when the prior
# session crosses age+token thresholds. The watcher needs the full
# transcript to load, not a lossy summary, so claude-loop.sh pushes
# both CLAUDE_CODE_RESUME_* env vars beyond any plausible session.
# Without these exports, the picker stalls every post-outage worker
# resume.
echo '=== claude-loop sets CLAUDE_CODE_RESUME_* env vars on every invocation ==='
# Stub claude that captures its env (in addition to argv).
CLAUDE_ENV_LOG="$WORK/claude-env.log"
: > "$CLAUDE_ENV_LOG"
cat > "$STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
printf '.' >> "$CLAUDE_COUNTER"
printf '%s\n' "\$*" >> "$CLAUDE_ARGS_LOG"
# Record one '<key>=<value>' line per resume-related env var, then a
# blank-line delimiter so the test can grep per-call without parsing
# the full environment.
printf 'CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=%s\n' "\${CLAUDE_CODE_RESUME_THRESHOLD_MINUTES:-unset}" >> "$CLAUDE_ENV_LOG"
printf 'CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=%s\n' "\${CLAUDE_CODE_RESUME_TOKEN_THRESHOLD:-unset}" >> "$CLAUDE_ENV_LOG"
printf -- '---\n' >> "$CLAUDE_ENV_LOG"
exit 0
STUB
chmod +x "$STUB_BIN/claude"

reset_state
seed_retain -5 "$WIN_DEFAULT" >/dev/null
out=$(run_loop --max-restarts 2 --retain-ttl-seconds 3600 2>&1)
rc=$?
assert_eq      "exit 11 (max-restarts)"                "$rc"           "11"
assert_eq      "claude invoked 3 times"                "$(calls)"      "3"
# Every call must carry both env vars at the suppression value. We
# don't pin the exact integer (the source-of-truth lives in
# claude-loop.sh) but we require BOTH be set to something other
# than 'unset' or empty on every call.
env_log=$(<"$CLAUDE_ENV_LOG")
min_calls=3
threshold_calls=$(grep -c '^CLAUDE_CODE_RESUME_THRESHOLD_MINUTES=[0-9]\{6,\}' <<<"$env_log")
token_calls=$(grep -c '^CLAUDE_CODE_RESUME_TOKEN_THRESHOLD=[0-9]\{6,\}' <<<"$env_log")
assert_eq      "CLAUDE_CODE_RESUME_THRESHOLD_MINUTES set on every call" "$threshold_calls" "$min_calls"
assert_eq      "CLAUDE_CODE_RESUME_TOKEN_THRESHOLD set on every call"   "$token_calls"     "$min_calls"
# Conversely, the parent shell must NOT have inherited the env vars.
# claude-loop.sh's inline form (`VAR=value claude ...`) sets them
# only for the child process; the parent stays clean so any sibling
# tooling under the same loop isn't affected.
if [[ -n "${CLAUDE_CODE_RESUME_THRESHOLD_MINUTES:-}" || -n "${CLAUDE_CODE_RESUME_TOKEN_THRESHOLD:-}" ]]; then
    printf '  FAIL: parent shell unexpectedly inherited CLAUDE_CODE_RESUME_* vars\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: parent shell did not inherit CLAUDE_CODE_RESUME_* vars\n'
    PASS=$(( PASS + 1 ))
fi

# Restore the simple stub for any downstream tests.
cat > "$STUB_BIN/claude" <<STUB
#!/usr/bin/env bash
printf '.' >> "$CLAUDE_COUNTER"
printf '%s\n' "\$*" >> "$CLAUDE_ARGS_LOG"
exit 0
STUB
chmod +x "$STUB_BIN/claude"

# ---- Test 8: missing prompt-file → exit 2 ------------------------------
echo '=== missing --prompt-file ⇒ exit 2 with diagnostic ==='
out=$(
    PATH="$STUB_BIN:$PATH" \
        "$LOOP_SCRIPT_REAL" \
        --window "$WIN_DEFAULT" \
        --prompt-file "$WORK/nope.txt" \
        --state-dir "$STATE_DIR" \
        2>&1
)
rc=$?
assert_eq      "exit 2 on missing prompt"              "$rc"           "2"
assert_contains "stderr names the missing file"        "$out"          "prompt-file unreadable"

# ---- Test 9: --model forwarded to first call AND every respawn ---------
#
# Issue #433 per-worker model pin. Mirrors Test 6 (--settings threading)
# plus Test 2 (respawn counting): the pin must ride the FIRST invocation
# and every `--continue` respawn, otherwise a restarted worker silently
# falls back to the ambient default model.
echo '=== --model <id> forwarded to first call AND every --continue respawn ==='
reset_state
seed_retain -5 "$WIN_DEFAULT" >/dev/null
out=$(run_loop --max-restarts 2 --retain-ttl-seconds 3600 --model claude-fable-5 2>&1)
rc=$?
assert_eq      "exit 11 (max-restarts) with --model"           "$rc"        "11"
assert_eq      "claude invoked 3 times (1 first + 2 respawns)" "$(calls)"   "3"
assert_eq      "all 3 calls carry --model claude-fable-5" \
               "$(grep -cF -- '--model claude-fable-5' "$CLAUDE_ARGS_LOG")" "3"
assert_eq      "2 respawns carry --continue" \
               "$(tail -n +2 "$CLAUDE_ARGS_LOG" | grep -cF -- '--continue')" "2"
assert_eq      "2 respawns ALSO carry --model (pin survives restart)" \
               "$(tail -n +2 "$CLAUDE_ARGS_LOG" | grep -F -- '--continue' | grep -cF -- '--model claude-fable-5')" "2"

# ---- Test 10: default-off — no --model ⇒ no --model in ANY invocation --
echo '=== no --model flag ⇒ claude invocations carry NO --model (default-off) ==='
reset_state
seed_retain -5 "$WIN_DEFAULT" >/dev/null
out=$(run_loop --max-restarts 1 --retain-ttl-seconds 3600 2>&1)
rc=$?
assert_eq      "exit 11 (max-restarts) without --model"        "$rc"        "11"
assert_ge      "claude invoked at least twice"                 "$(calls)"   "2"
assert_eq      "no --model in any invocation when flag omitted" \
               "$(grep -cF -- '--model' "$CLAUDE_ARGS_LOG")" "0"

# ---- summary ----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
