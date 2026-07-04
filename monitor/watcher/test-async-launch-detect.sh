#!/usr/bin/env bash
# Tests for monitor/hooks/async-launch-detect.sh — the PostToolUse
# Bash hook that auto-detects async-launch commands (sbatch, srun
# --no-block, nohup &) and writes a (kind, id, desc) entry to the
# worker heartbeat's `external_waits` array. Part of issue #183.
#
# Run: bash monitor/watcher/test-async-launch-detect.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HOOK="$_repo_root/monitor/hooks/async-launch-detect.sh"
PATTERNS_DEFAULT="$_repo_root/monitor/async-launch-patterns.conf"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[[ -x "$HOOK" ]] || { echo "missing hook: $HOOK" >&2; exit 1; }
[[ -f "$PATTERNS_DEFAULT" ]] || { echo "missing default patterns: $PATTERNS_DEFAULT" >&2; exit 1; }

hb_file="$WORK/.state/heartbeat/testw.json"

reset_hb() { rm -f "$hb_file"; rm -rf "$WORK/.state/heartbeat"; }

# Fire the hook with a synthesised PostToolUse payload and the
# default patterns file. Reads the resulting external_waits.
fire_hook() {
    local cmd="$1" stdout="$2"
    jq -nc \
        --arg cmd "$cmd" --arg out "$stdout" \
        '{hook_event_name:"PostToolUse",tool_name:"Bash",tool_input:{command:$cmd},tool_response:{stdout:$out}}' \
      | env -u NEXUS_WORKER_WINDOW \
          NEXUS_STATE_DIR="$WORK/.state" \
          NEXUS_WORKER_WINDOW=testw \
          NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" \
          bash "$HOOK"
}

read_waits() {
    if [[ -f "$hb_file" ]]; then
        jq -c '.external_waits // []' "$hb_file" 2>/dev/null
    else
        echo "[]"
    fi
}

echo "=== default pattern set: sbatch / srun --no-block / nohup ==="

# (1) sbatch with id in stdout.
reset_hb
fire_hook "sbatch run.sh" "Submitted batch job 52527284"
got=$(read_waits)
if jq -e '. == [{kind:"slurm",id:"52527284",desc:"sbatch"}]' <<<"$got" >/dev/null; then
    ok "sbatch run.sh → kind=slurm id=52527284"
else
    bad "sbatch basic" "got=$got"
fi

# (2) sbatch --array with array job id.
reset_hb
fire_hook "sbatch --array=1-10 --wrap='echo hi'" "Submitted batch job 52527285_1"
got=$(read_waits)
id=$(jq -r '.[0].id' <<<"$got")
if [[ "$id" == "52527285_1" ]]; then
    ok "sbatch --array → array id captured"
else
    bad "sbatch array" "got=$got"
fi

# (3) Repeat same sbatch — idempotent on (kind, id).
reset_hb
fire_hook "sbatch run.sh" "Submitted batch job 52527284"
fire_hook "sbatch run.sh" "Submitted batch job 52527284"
got=$(read_waits)
count=$(jq 'length' <<<"$got")
if [[ "$count" == "1" ]]; then
    ok "repeat sbatch with same id → single entry"
else
    bad "repeat sbatch idempotent" "count=$count"
fi

# (4) Non-launch command does not write the heartbeat.
reset_hb
fire_hook "ls -la /tmp" "file1\nfile2"
if [[ ! -f "$hb_file" ]]; then
    ok "ls -la does not create heartbeat"
else
    bad "ls leaked file" "exists: $(cat "$hb_file")"
fi

# (5) Comment in command does not false-match (echo "sbatch run.sh" must not match).
reset_hb
fire_hook 'echo "sbatch run.sh"' "sbatch run.sh"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "echo \"sbatch run.sh\" does not false-match"
else
    bad "echo false-match" "got=$got"
fi

# (6) sbatchX (no word boundary) does not match.
reset_hb
fire_hook "sbatchx --foo" "garbage"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "sbatchx → no match (word-boundary anchor)"
else
    bad "sbatchx false-match" "got=$got"
fi

# (7) nohup with trailing & → synthetic id, kind=nohup.
reset_hb
fire_hook "nohup ./long_job.sh > out.log &" ""
got=$(read_waits)
kind=$(jq -r '.[0].kind' <<<"$got")
id=$(jq -r '.[0].id' <<<"$got")
if [[ "$kind" == "nohup" ]] && [[ "$id" == syn-* ]]; then
    ok "nohup & → kind=nohup synthetic id"
else
    bad "nohup" "got=$got"
fi

# (8) nohup without backgrounding (no trailing &) → no match.
reset_hb
fire_hook "nohup echo hi" "hi"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "nohup foreground → no match"
else
    bad "nohup foreground" "got=$got"
fi

# (9) srun --no-block with id in stdout.
reset_hb
fire_hook "srun --no-block --partition=campus-new -n 1 ./script.sh" \
          "Submitted job 52527299"
got=$(read_waits)
kind=$(jq -r '.[0].kind' <<<"$got")
id=$(jq -r '.[0].id' <<<"$got")
if [[ "$kind" == "slurm-srun-async" ]] && [[ "$id" == "52527299" ]]; then
    ok "srun --no-block → kind=slurm-srun-async id captured"
else
    bad "srun --no-block" "got=$got"
fi

# (10) plain srun (no --no-block) → no match. Hooks should not
#      add a wait for synchronous srun calls.
reset_hb
fire_hook "srun --partition=campus-new -n 1 ./script.sh" \
          "Submitted job 52527311"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "srun without --no-block → no match"
else
    bad "srun no --no-block" "got=$got"
fi

echo
echo "=== dismissed_waits filter ==="

# (11) After dismissal, re-detected (kind, id) is NOT re-added.
reset_hb
fire_hook "sbatch run.sh" "Submitted batch job 99"
# Manually inject a dismissal (mimics declare-no-wait.sh effect).
jq -c '.external_waits = [] | .dismissed_waits = [{kind:"slurm",id:"99"}]' \
    "$hb_file" > "$hb_file.tmp" && mv "$hb_file.tmp" "$hb_file"
fire_hook "sbatch run.sh" "Submitted batch job 99"
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "dismissed (slurm,99) → hook skips re-add"
else
    bad "dismissed filter" "got=$got"
fi

echo
echo "=== degraded modes ==="

# Cases 12-14 exercise the hook's EARLY-EXIT paths, which by design
# (hot-path discipline) exit before reading stdin. Feed the payload
# via herestring, not a pipe: a pipe's writer races the reader's
# early exit, and under CPU load the echo can be scheduled after the
# hook is gone — SIGPIPE on the writer, which `set -o pipefail`
# surfaces as rc=141 despite the hook itself exiting 0 (reproduced in
# the R3-tail proof campaign at load ~40). A herestring is fully
# materialized by the shell before the hook runs, so no race exists.

# (12) Non-Bash tool — hook no-ops.
reset_hb
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
    NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" \
    bash "$HOOK" \
    <<<'{"hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"/tmp/x"},"tool_response":{}}'
if [[ ! -f "$hb_file" ]]; then
    ok "non-Bash tool → hook no-ops"
else
    bad "non-Bash leaked" "$(cat "$hb_file")"
fi

# (13) Missing NEXUS_WORKER_WINDOW → silent no-op (hook hot-path
#      discipline; never block claude's turn).
reset_hb
out_err=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" \
        NEXUS_ASYNC_PATTERNS="$PATTERNS_DEFAULT" \
        bash "$HOOK" 2>&1 \
        <<<'{"tool_name":"Bash","tool_input":{"command":"sbatch run.sh"},"tool_response":{"stdout":"Submitted batch job 1"}}')
rc=$?
if (( rc == 0 )) && [[ -z "$out_err" ]] && [[ ! -f "$hb_file" ]]; then
    ok "missing NEXUS_WORKER_WINDOW → silent no-op (exit 0)"
else
    bad "missing window" "rc=$rc out=$out_err"
fi

# (14) Missing patterns file → silent no-op.
reset_hb
out_err=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        NEXUS_ASYNC_PATTERNS="/no/such/file" \
        bash "$HOOK" 2>&1 \
        <<<'{"tool_name":"Bash","tool_input":{"command":"sbatch run.sh"},"tool_response":{"stdout":"Submitted batch job 1"}}')
rc=$?
if (( rc == 0 )) && [[ -z "$out_err" ]] && [[ ! -f "$hb_file" ]]; then
    ok "missing patterns file → silent no-op"
else
    bad "missing patterns" "rc=$rc out=$out_err"
fi

echo
echo "=== adding a new pattern is data-only ==="

# (15) Custom pattern via NEXUS_ASYNC_PATTERNS override.
custom="$WORK/custom-patterns.conf"
cat > "$custom" <<'EOF'
# Custom kind for testing.
mykind|^[[:space:]]*launchmybatch\b|My job ID ([A-Z0-9]+)|mybatch launcher
EOF
reset_hb
echo '{"tool_name":"Bash","tool_input":{"command":"launchmybatch --opt x"},"tool_response":{"stdout":"My job ID ABC123 queued"}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        NEXUS_ASYNC_PATTERNS="$custom" \
        bash "$HOOK"
got=$(read_waits)
if jq -e '. == [{kind:"mykind",id:"ABC123",desc:"mybatch launcher"}]' <<<"$got" >/dev/null; then
    ok "custom pattern → data-only extensibility"
else
    bad "custom pattern" "got=$got"
fi

# (16) Empty id_regex with custom kind synthesizes an id.
custom2="$WORK/custom2.conf"
cat > "$custom2" <<'EOF'
fireforget|\bfireforget\b||fireforget launcher
EOF
reset_hb
echo '{"tool_name":"Bash","tool_input":{"command":"fireforget some args"},"tool_response":{"stdout":""}}' \
  | env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        NEXUS_ASYNC_PATTERNS="$custom2" \
        bash "$HOOK"
got=$(read_waits)
kind=$(jq -r '.[0].kind' <<<"$got")
id=$(jq -r '.[0].id' <<<"$got")
if [[ "$kind" == "fireforget" ]] && [[ "$id" == syn-* ]]; then
    ok "empty id_regex → synthetic id"
else
    bad "empty id_regex" "got=$got"
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
