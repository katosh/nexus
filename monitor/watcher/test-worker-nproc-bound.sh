#!/usr/bin/env bash
# Tests for the worker RLIMIT_NPROC ceiling (fork-storm class,
# your-org/nexus-code#487).
#
# Two PID-exhaustion node-downs in two days (Lmod's
# command_not_found_handle, #457; the sandbox /app/bin/pip wrapper,
# 2026-07-09) shared one shape: an unbounded self-re-exec loop inside a
# single worker, in an environment where nothing bounded it. The fix
# under test:
#   1. spawn-worker.sh's generated launchers set a SOFT RLIMIT_NPROC
#      ceiling (default 8192; NEXUS_WORKER_NPROC_LIMIT overrides,
#      0 disables) so a runaway chain hits fork:EAGAIN at the ceiling
#      and degrades that worker, not the node;
#   2. the watcher launcher (monitor/watcher/launcher.sh) and the
#      service launch path (monitor/bootstrap-recover.sh) restore
#      soft=hard at their own entry, so long-lived infrastructure never
#      inherits a worker's ceiling regardless of who (re)starts it —
#      possible precisely because the worker ceiling is SOFT-only.
#
# The functional subtests use a bounded chain (N background sleeps
# under a probed floor+headroom cap, hard timeout, recorded-pid
# cleanup) — never an unbounded storm.
#
# Run: bash monitor/watcher/test-worker-nproc-bound.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_REAL="$_test_dir/../spawn-worker.sh"
LAUNCHER_REAL="$_test_dir/launcher.sh"
RECOVER_REAL="$_test_dir/../bootstrap-recover.sh"

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
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

# ---- harness (mirrors test-spawn-worker.sh) ------------------------------

WORK=$(mktemp -d -t nexus-nproc-XXXXXX)
SLEEPER_PIDS=()
cleanup() {
    local p
    for p in "${SLEEPER_PIDS[@]:-}"; do
        [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

SPAWN_TMP="$WORK/spawn-tmp"
mkdir -p "$SPAWN_TMP"
export TMPDIR="$SPAWN_TMP"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" \
         "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports" \
         "$FAKE_NEXUS/node_modules/.bin"
cp "$SCRIPT_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
cp "$_test_dir/../_claude-bin.sh"  "$FAKE_NEXUS/monitor/_claude-bin.sh"
cp "$_test_dir/../_tmux-window.sh" "$FAKE_NEXUS/monitor/_tmux-window.sh"
cp "$_test_dir/../_fm_lib.sh"      "$FAKE_NEXUS/monitor/_fm_lib.sh"
chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh"
SCRIPT="$FAKE_NEXUS/monitor/spawn-worker.sh"

printf '#!/bin/bash\necho "stub-claude: $*"\n' > "$FAKE_NEXUS/node_modules/.bin/claude"
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"

cat > "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
---
description: stub
---

# nexus.worker-defaults

## Worker floor

- Floor body stub.
EOF

cat > "$FAKE_NEXUS/monitor/worker-settings.json" <<'EOF'
{ "hooks": {} }
EOF

WORKDIR="$FAKE_NEXUS"
PROMPT_FILE="$WORK/task-prompt.txt"
printf 'Do the thing.\n' > "$PROMPT_FILE"

STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'STUB'
#!/bin/bash
case "$1" in
    new-window) echo '@7'; exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/tmux"
printf '#!/bin/bash\nexit 0\n' > "$FAKE_NEXUS/monitor/ng"
chmod +x "$FAKE_NEXUS/monitor/ng"

# The stub tmux never runs the generated launcher, so the self-deleting
# tempfile persists under $TMPDIR for inspection.
run_spawn() {  # run_spawn <window-name> [env VAR=val ...]
    local win="$1"; shift
    env "$@" PATH="$STUB_BIN:$PATH" "$SCRIPT" -n "$win" -c "$WORKDIR" -p "$PROMPT_FILE" >/dev/null 2>&1
}
launcher_body() {  # launcher_body <window-name>
    cat "$SPAWN_TMP/spawn-launcher-$1".*.sh 2>/dev/null
}

# ---- Test 1: generated launcher carries the soft nproc ceiling -----------

echo '=== generated worker launcher sets the soft RLIMIT_NPROC ceiling ==='
run_spawn nproc-default
body=$(launcher_body nproc-default)
assert_contains "launcher sets soft ceiling (default 8192)" "$body" "ulimit -Su 8192 2>/dev/null || true"
assert_contains "ceiling cites the class issue" "$body" "your-org/nexus-code#487"

echo '=== NEXUS_WORKER_NPROC_LIMIT overrides the ceiling ==='
run_spawn nproc-override NEXUS_WORKER_NPROC_LIMIT=4096
body=$(launcher_body nproc-override)
assert_contains "launcher honours the override" "$body" "ulimit -Su 4096 2>/dev/null || true"

echo '=== NEXUS_WORKER_NPROC_LIMIT=0 disables the ceiling ==='
run_spawn nproc-off NEXUS_WORKER_NPROC_LIMIT=0
body=$(launcher_body nproc-off)
assert_not_contains "no ulimit line when disabled" "$body" "ulimit -Su"

# ---- Test 2: watcher/service launchers restore soft=hard -----------------

echo '=== watcher + service launch paths restore soft=hard (never inherit) ==='
assert_contains "launcher.sh restores the soft limit" \
    "$(cat "$LAUNCHER_REAL")" 'ulimit -Su "$(ulimit -Hu)"'
assert_contains "bootstrap-recover service inner restores the soft limit" \
    "$(cat "$RECOVER_REAL")" 'ulimit -Su "$(ulimit -Hu)"'

# RLIMIT_NPROC is checked against the real uid's TOTAL process count
# (invisible from inside the sandbox's pid namespace), so every
# functional fixture below calibrates its ceiling against a PROBED
# floor: the lowest soft cap at which a fork currently succeeds,
# binary-searched to ±32. A hardcoded ceiling under the ambient count
# would make even the fixture's own forks fail.
probe_cap() { ( ulimit -Su "$1" 2>/dev/null; /bin/true ) 2>/dev/null; }
probe_floor() {
    local lo=0 hi="" cap mid
    for cap in 400 800 1600 3200 6400 12800 25600; do
        if probe_cap "$cap"; then hi=$cap; break; else lo=$cap; fi
    done
    [[ -n "$hi" ]] || return 1
    while (( hi - lo > 32 )); do
        mid=$(( (lo + hi) / 2 ))
        if probe_cap "$mid"; then hi=$mid; else lo=$mid; fi
    done
    printf '%s' "$hi"
}

# Functional: a soft-only ceiling in the parent is raisable back to hard
# by a child — the exact mechanism the two restore lines rely on. The
# ceiling sits floor+2000 (far above ambient, so the inner bash can
# fork) and far below the hard limit (so "restored != ceiling" is
# meaningful).
restored="" ceiling=""
for attempt in 1 2 3; do
    floor=$(probe_floor) || continue
    ceiling=$(( floor + 2000 ))
    restored=$(bash -c 'ulimit -Su '"$ceiling"' 2>/dev/null; bash -c "ulimit -Su \$(ulimit -Hu) 2>/dev/null || true; ulimit -Su"' 2>/dev/null)
    [[ -n "$restored" ]] && break
done
if [[ -n "$restored" && "$restored" != "$ceiling" ]]; then
    printf '  PASS: child under a %s soft ceiling restored soft to hard (%s)\n' "$ceiling" "$restored"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: soft-limit restore did not raise past the ceiling (ceiling=%s got %q)\n' "$ceiling" "$restored" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 3: the ceiling actually stops a bounded fork chain -------------
#
# ceiling = probed floor (±32) + HEADROOM, then attempt SPAWN background
# sleeps with SPAWN >> HEADROOM: the chain must hit the ceiling (a fork
# fails) while the parent shell survives to report. The loop STOPS at
# the first refused fork — one refusal proves the ceiling, and each
# refusal costs bash a full EAGAIN retry cycle (~15-30 s of backoff), so
# collecting many would only burn wall-clock. Ambient churn can only
# shift the failure point, not eliminate it, unless the user-wide count
# instantly drops by more than SPAWN - HEADROOM - 32 (implausible); the
# retry loop absorbs probe races. Leaked sleepers self-expire (sleep 60)
# if the inner timeout fires between spawn and cleanup.

echo '=== bounded chain: forks past the ceiling fail, parent survives ==='
# The forker is python3, not bash: bash retries a refused fork with
# exponential backoff and usually succeeds once ambient churn dips, so
# a `&`-spawn loop almost never REPORTS failure — it just crawls.
# os.fork() surfaces the EAGAIN immediately and deterministically.
cat > "$WORK/forker.py" <<'PY'
import os, signal, sys
n, ok, fail, pids = int(sys.argv[1]), 0, 0, []
for _ in range(n):
    try:
        pid = os.fork()
        if pid == 0:
            os.execv('/bin/sleep', ['sleep', '60'])
        pids.append(pid); ok += 1
    except OSError:
        fail = 1
        break
print(f"OK={ok} FAIL={fail} PARENT=alive", flush=True)
for p in pids:
    try: os.kill(p, signal.SIGKILL)
    except OSError: pass
for p in pids:
    try: os.waitpid(p, 0)
    except OSError: pass
PY
HEADROOM=40
SPAWN=140
attempt_ok=0
for attempt in 1 2 3; do
    floor=$(probe_floor) || continue
    result=$(timeout 60 bash -c '
        ulimit -Su '"$(( floor + HEADROOM ))"' 2>/dev/null || exit 90
        exec python3 '"$WORK/forker.py"' '"$SPAWN"'
    ' 2>/dev/null)
    ok_n=$(sed -n 's/.*OK=\([0-9]*\).*/\1/p' <<<"$result")
    fail_n=$(sed -n 's/.*FAIL=\([0-9]*\).*/\1/p' <<<"$result")
    if [[ "$result" == *PARENT=alive* && "$fail_n" == "1" ]]; then
        printf '  PASS: ceiling held — fork refused after %s spawns (cap=floor+%s), parent survived\n' \
            "$ok_n" "$HEADROOM"
        PASS=$(( PASS + 1 )); attempt_ok=1; break
    fi
done
if (( ! attempt_ok )); then
    printf '  FAIL: no attempt produced a refused fork under the ceiling (last: %q)\n' "${result:-}" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary --------------------------------------------------------------

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
