#!/usr/bin/env bash
# Issue #95 regression: spawn-worker.sh's launcher must `cd "$WORKDIR"`
# before exec'ing claude, AND `_report_project_slug` must infer the
# project from NEXUS_WORKER_WINDOW when that var is set but cwd is
# outside `work/` (issue #236 B4 — superseding the old false-positive
# stderr warning). Without the cd, a worker whose ng resolvers key off
# pwd leaks the orchestrator's session-id / project=nexus into its report.
#
# Run: bash monitor/watcher/test-spawn-worker-cwd.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: spawn through the real spawn-worker.sh with a stubbed tmux
# that captures (but does NOT execute) the launcher path; then run the
# launcher directly with a stubbed claude that records its pwd. Verify
# the recorded pwd equals WORKDIR. Then drive `ng report-init` from
# both WORKDIR and the primary clone and assert frontmatter / warning
# behaviour.

set -uo pipefail

# Hermetic baseline. The test runs assertions keyed on
# NEXUS_WORKER_WINDOW (inference in Test 4, its absence in Test 5);
# inheriting it from a parent worker shell would taint Test 5's
# negative case.
unset NEXUS_WORKER_WINDOW

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SPAWN_REAL="$_test_dir/../spawn-worker.sh"
NG_REAL="$_test_dir/../ng"

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
        printf '  FAIL: %s\n           expected: %s\n' "$label" "$needle" >&2
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

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
WINDOW_NAME="cwd-leak-test-$$"
trap 'rm -rf "$WORK"; rm -f /tmp/spawn-launcher-${WINDOW_NAME}.*.sh /tmp/spawn-prompt-${WINDOW_NAME}.*.txt /tmp/spawn-hooks-${WINDOW_NAME}.*.json' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" \
         "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports" \
         "$FAKE_NEXUS/config" \
         "$FAKE_NEXUS/work/cwd-leak-slug"

cp "$SPAWN_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
cp "$NG_REAL"    "$FAKE_NEXUS/monitor/ng"
chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh" "$FAKE_NEXUS/monitor/ng"

# spawn-worker.sh sources monitor/_claude-bin.sh. We do NOT drop a
# stub under $FAKE_NEXUS/node_modules/.bin/claude because Test 2 needs
# the launcher to exec the $STUB_BIN/claude pwd-logging stub. Instead
# the spawn invocations below pass CLAUDE_BIN=$STUB_BIN/claude as an
# env override so the resolver bakes the stub's absolute path into
# the launcher heredoc.
cp "$_test_dir/../_claude-bin.sh" "$FAKE_NEXUS/monitor/_claude-bin.sh"
# Also sourced by spawn-worker.sh for window-id targeting (#323).
cp "$_test_dir/../_tmux-window.sh" "$FAKE_NEXUS/monitor/_tmux-window.sh"
# And the shared frontmatter reader (#405 P2) for report resolution.
cp "$_test_dir/../_fm_lib.sh" "$FAKE_NEXUS/monitor/_fm_lib.sh"

# worker-settings.json: spawn-worker.sh refuses to spawn without one
# (PR #128 made the file a hard dependency to suppress the bypass
# dialog at source). Tests don't exercise settings content — an empty
# JSON object satisfies the existence gate.
printf '{}' > "$FAKE_NEXUS/monitor/worker-settings.json"

cat > "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
---
description: stub
---

# nexus.worker-defaults

## Worker floor

- FLOOR_TOKEN
EOF

cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'org/repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

WORKDIR="$FAKE_NEXUS/work/cwd-leak-slug"

PROMPT_FILE="$WORK/task.txt"
echo "test prompt" > "$PROMPT_FILE"

# Stub bin: tmux captures the launcher path from `send-keys` instead
# of executing it; everything else no-ops. We'll exec the launcher
# ourselves below.
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
LAUNCHER_CAPTURE="$WORK/captured-launcher.path"
cat > "$STUB_BIN/tmux" <<TMUX_STUB
#!/bin/bash
case "\$1" in
    info|list-windows|set-window-option) exit 0 ;;
    new-window) echo '@9'; exit 0 ;;  # emit fake @id for new-window -P (#323)
    send-keys)
        # tmux send-keys -t <window> <command> [Enter] — first arg
        # matching /tmp/spawn-launcher-* is the launcher path the
        # generated launcher writes itself out to.
        for arg in "\$@"; do
            case "\$arg" in
                /tmp/spawn-launcher-*) printf '%s' "\$arg" > "$LAUNCHER_CAPTURE"; exit 0 ;;
            esac
        done
        exit 0 ;;
    *) exit 0 ;;
esac
TMUX_STUB
chmod +x "$STUB_BIN/tmux"

# ---- Test 1: launcher captures the cd "$WORKDIR" line ------------------

echo '=== spawn-worker generates a launcher that cd'\''s into WORKDIR ==='
out=$( cd "$WORK" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
       "$FAKE_NEXUS/monitor/spawn-worker.sh" \
           -n "$WINDOW_NAME" -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1 )
rc=$?
assert_eq "spawn exits 0" "$rc" "0"

[[ -f "$LAUNCHER_CAPTURE" ]] || {
    printf '  FAIL: tmux stub did not capture launcher path\n' >&2
    FAIL=$(( FAIL + 1 )); echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1
}
LAUNCHER_PATH=$(<"$LAUNCHER_CAPTURE")
[[ -f "$LAUNCHER_PATH" ]] || {
    printf '  FAIL: captured launcher path does not exist on disk: %s\n' "$LAUNCHER_PATH" >&2
    FAIL=$(( FAIL + 1 )); echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1
}
launcher_body=$(cat "$LAUNCHER_PATH")
assert_contains "launcher source contains cd \"\$WORKDIR\"" \
                "$launcher_body" "cd \"$WORKDIR\""

# ---- Test 2: executing the launcher puts claude in WORKDIR -------------

echo '=== launcher exec'\''s claude with pwd=WORKDIR ==='
PWD_LOG="$WORK/claude-pwd.log"
cat > "$STUB_BIN/claude" <<CLAUDE_STUB
#!/bin/bash
pwd > "$PWD_LOG"
exit 0
CLAUDE_STUB
chmod +x "$STUB_BIN/claude"

# Run the launcher from $WORK so its starting pwd differs from
# $WORKDIR. Without the fix the stubbed claude records $WORK; with
# the fix it records $WORKDIR.
( cd "$WORK" && PATH="$STUB_BIN:$PATH" bash "$LAUNCHER_PATH" )
captured_pwd=$(<"$PWD_LOG")
assert_eq "claude invoked with cwd=WORKDIR" "$captured_pwd" "$WORKDIR"

# ---- Test 3: ng report-init from WORKDIR resolves worker's identity -----

echo '=== ng report-init from WORKDIR resolves worker session-id + project ==='
FAKE_HOME="$WORK/home"
WORKER_SESSION="11111111-2222-3333-4444-555555555555"
WORKER_SLUG=$(printf '%s' "$WORKDIR" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$FAKE_HOME/.claude/projects/$WORKER_SLUG"
touch "$FAKE_HOME/.claude/projects/$WORKER_SLUG/$WORKER_SESSION.jsonl"

# Seed an orchestrator project dir with a different session UUID so
# any leak would be visible.
ORCH_SESSION="99999999-9999-9999-9999-999999999999"
ORCH_SLUG=$(printf '%s' "$FAKE_NEXUS" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$FAKE_HOME/.claude/projects/$ORCH_SLUG"
touch "$FAKE_HOME/.claude/projects/$ORCH_SLUG/$ORCH_SESSION.jsonl"

# Issue #203: a real worker runs report-init with CLAUDE_CODE_SESSION_ID
# set to ITS OWN session (Claude Code exports it into every Bash call).
# That env var is now the highest-priority source — the strongest
# guarantee against the orchestrator-session leak this test guards: the
# worker reports its own sid directly, not "whatever wrote most recently
# in the project dir". (The freshest-jsonl fallback used when the env
# var is absent is covered by test-ng-report-init.)
REPORT_PATH=$( cd "$WORKDIR" && \
    HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="$WORKER_SESSION" \
    NEXUS_ROOT="$FAKE_NEXUS" NEXUS_WORKER_WINDOW="$WINDOW_NAME" \
    "$FAKE_NEXUS/monitor/ng" report-init session-leak-fix \
        --reports-dir "$FAKE_NEXUS/reports" )
[[ -f "$REPORT_PATH" ]] || {
    printf '  FAIL: report not created at %s\n' "$REPORT_PATH" >&2
    FAIL=$(( FAIL + 1 )); echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1
}
report_body=$(<"$REPORT_PATH")
assert_contains "frontmatter has worker session-id (not orchestrator's)" \
                "$report_body" "session-id: $WORKER_SESSION"
assert_not_contains "frontmatter does NOT carry orchestrator session-id" \
                    "$report_body" "session-id: $ORCH_SESSION"
assert_contains "frontmatter project resolves to worker slug (cwd-leak-slug)" \
                "$report_body" "project: cwd-leak-slug"
assert_not_contains "frontmatter project is NOT 'nexus' default" \
                    "$report_body" "project: nexus"

# ---- Test 4: worker outside its worktree → project inferred from window ----
#
# Issue #236 B4: a worker that cd's away from its worktree but still has
# NEXUS_WORKER_WINDOW set no longer gets a generic project=nexus stub +
# a false-positive "did you mean..." warning. The window name becomes
# the project slug — worker-attributed, silent. (The old behaviour was
# warn-then-write-the-wrong-stub, the worst of both worlds.)

echo '=== ng report-init from primary clone with NEXUS_WORKER_WINDOW set infers project=<window> ==='
warn_err_tmp=$(mktemp)
warn_path=$( cd "$FAKE_NEXUS" && \
    HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="" \
    NEXUS_ROOT="$FAKE_NEXUS" NEXUS_WORKER_WINDOW="$WINDOW_NAME" \
    "$FAKE_NEXUS/monitor/ng" report-init from-primary-clone \
        --reports-dir "$FAKE_NEXUS/reports" 2>"$warn_err_tmp" )
warn_err=$(<"$warn_err_tmp"); rm -f "$warn_err_tmp"
[[ -f "$warn_path" ]] || {
    printf '  FAIL: report not created at %s\n' "$warn_path" >&2
    FAIL=$(( FAIL + 1 )); echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1
}
warn_body=$(<"$warn_path")
# WINDOW_NAME is already slug-safe (kebab + digits), so the sanitized
# project slug equals it verbatim.
assert_contains "project resolves to the window slug, not 'nexus'" \
                "$warn_body" "project: $WINDOW_NAME"
assert_not_contains "no project=nexus misattribution" \
                    "$warn_body" "project: nexus"
assert_not_contains "no false-positive 'did you mean' warning" \
                    "$warn_err" "did you mean to run"
assert_not_contains "stderr does not nag about NEXUS_WORKER_WINDOW" \
                    "$warn_err" "NEXUS_WORKER_WINDOW"

# ---- Test 5: warning is silent for orchestrator (no NEXUS_WORKER_WINDOW) ----

echo '=== ng report-init from primary clone WITHOUT worker env stays quiet ==='
quiet_err=$( cd "$FAKE_NEXUS" && \
    HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="" \
    NEXUS_ROOT="$FAKE_NEXUS" \
    "$FAKE_NEXUS/monitor/ng" report-init no-worker-env \
        --reports-dir "$FAKE_NEXUS/reports" 2>&1 >/dev/null )
assert_not_contains "orchestrator-level report-init does NOT emit the warning" \
                    "$quiet_err" "NEXUS_WORKER_WINDOW"

# ---- Test 6: warning is silent when worker IS in its worktree ---------

echo '=== ng report-init from worktree with NEXUS_WORKER_WINDOW set stays quiet ==='
worktree_err=$( cd "$WORKDIR" && \
    HOME="$FAKE_HOME" CLAUDE_PROJECT_DIR="" CLAUDE_CODE_SESSION_ID="$WORKER_SESSION" \
    NEXUS_ROOT="$FAKE_NEXUS" NEXUS_WORKER_WINDOW="$WINDOW_NAME" \
    "$FAKE_NEXUS/monitor/ng" report-init worker-in-worktree \
        --reports-dir "$FAKE_NEXUS/reports" 2>&1 >/dev/null )
assert_not_contains "in-worktree worker report-init does NOT emit the warning" \
                    "$worktree_err" "NEXUS_WORKER_WINDOW"

# ---- Test 7: loop-wrapped launcher also cd's ---------------------------

echo '=== loop-wrapped launcher (issue #75) also cd'\''s into WORKDIR ==='
LOOP_WINDOW="cwd-leak-loop-$$"
LAUNCHER_CAPTURE_LOOP="$WORK/captured-loop-launcher.path"
cat > "$STUB_BIN/tmux" <<TMUX_STUB2
#!/bin/bash
case "\$1" in
    info|list-windows|set-window-option) exit 0 ;;
    new-window) echo '@9'; exit 0 ;;  # emit fake @id for new-window -P (#323)
    send-keys)
        for arg in "\$@"; do
            case "\$arg" in
                /tmp/spawn-launcher-*) printf '%s' "\$arg" > "$LAUNCHER_CAPTURE_LOOP"; exit 0 ;;
            esac
        done
        exit 0 ;;
    *) exit 0 ;;
esac
TMUX_STUB2
chmod +x "$STUB_BIN/tmux"

# Stub claude-loop.sh so spawn-worker's NEXUS_ROOT path resolves.
cat > "$FAKE_NEXUS/monitor/claude-loop.sh" <<'LOOP_STUB'
#!/usr/bin/env bash
echo "loop-stub: $*"
LOOP_STUB
chmod +x "$FAKE_NEXUS/monitor/claude-loop.sh"

out=$( cd "$WORK" && \
    MONITOR_RETAIN_USE_LOOP_WRAPPER=1 PATH="$STUB_BIN:$PATH" \
    CLAUDE_BIN="$STUB_BIN/claude" \
    "$FAKE_NEXUS/monitor/spawn-worker.sh" \
        -n "$LOOP_WINDOW" -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1 )
rc=$?
assert_eq "loop-wrapped spawn exits 0" "$rc" "0"

LOOP_LAUNCHER=$(<"$LAUNCHER_CAPTURE_LOOP")
loop_launcher_body=$(cat "$LOOP_LAUNCHER")
assert_contains "loop launcher cd's into WORKDIR" \
                "$loop_launcher_body" "cd \"$WORKDIR\""

# Also clean up the loop launcher tempfile.
rm -f "$LOOP_LAUNCHER"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
