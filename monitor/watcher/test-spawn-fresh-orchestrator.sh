#!/usr/bin/env bash
# Unit tests for monitor/watcher/spawn-fresh-orchestrator.sh — the
# watcher-driven last-ditch orchestrator recovery helper.
#
# Strategy: build a fake NEXUS_ROOT containing the files the script
# inspects (orchestrator-settings.json, reports/, monitor/.state/),
# stub `tmux` in PATH to record every invocation, and run the
# helper. Assert on:
#   1. The generated /tmp launcher script contains
#      `exec claude --dangerously-skip-permissions --continue ... --settings <path>`
#      by default and switches to no-`--continue` under `--fresh`.
#   2. The pasted situation-report file (kept on disk at
#      $STATE_DIR/orchestrator-fresh-spawn.last-report.md) carries
#      all required snapshot sections and adapts wording per mode.
#   3. The cooldown marker is written at
#      $STATE_DIR/orchestrator-fresh-spawn.last.
#   4. tmux invocation log shows the load-buffer + paste-buffer +
#      send-keys Enter sequence into the target window.
#   5. When orchestrator-settings.json is missing, the launcher
#      omits --settings (graceful degradation for older forks).
#   6. The readiness probe (pane-state.sh) gates the paste step: the
#      paste is attempted after at least one probe returns
#      `state=empty` or `state=idle`.
#   7. The post-paste verify path retries Enter once when the first
#      pane-state probe still reports `state=empty`.
#
# Run directly: bash monitor/watcher/test-spawn-fresh-orchestrator.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
SCRIPT="$_test_dir/spawn-fresh-orchestrator.sh"

PASS=0
FAIL=0

pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "$label — got %q want %q" "$got" "$want"
    fi
}

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        pass "$label"
    else
        fail "$label — missing literal: $needle"
    fi
}

assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        fail "$label — unexpectedly found: $needle"
    else
        pass "$label"
    fi
}

# --- harness -------------------------------------------------------------

WORK=$(mktemp -d -t nexus-fresh-orch-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Isolate launcher temp files into our own $WORK dir so the parallel
# CI runner (run-tests.sh --jobs 2) can't race another test that
# also globs `nexus-respawn-launch-*` (e.g. test-respawn.sh). The
# shared helper in monitor/watcher/_respawn.sh honours
# $RESPAWN_TMPDIR; production defaults to /tmp (single watcher
# process, no contention).
export RESPAWN_TMPDIR="$WORK/launchers"
mkdir -p "$RESPAWN_TMPDIR"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor/.state" \
         "$FAKE_NEXUS/monitor/watcher" \
         "$FAKE_NEXUS/node_modules/.bin" \
         "$FAKE_NEXUS/reports"

STATE_DIR="$FAKE_NEXUS/monitor/.state"

# Stage the orchestrator session-id pin + its jsonl so the default
# (non-fresh) recovery path resolves to a deterministic
# `--resume <pinned-sid>` (issue #176) instead of the old `--continue`
# fallback. HOME is redirected to a per-test dir so the Claude-Code
# slug lookup inside `_respawn_choose_resume_mode` is hermetic. Tests
# that exercise the pin-MISSING cold degradation (issue #200) remove
# this file for the duration of their own run.
export HOME="$WORK/home"
PIN_SID="abcdef01-2345-6789-abcd-ef0123456789"
PIN_FILE="$STATE_DIR/orchestrator-session-id"
printf '%s\n' "$PIN_SID" > "$PIN_FILE"
_slug="${FAKE_NEXUS//[^a-zA-Z0-9-]/-}"
PROJ_DIR="$HOME/.claude/projects/$_slug"
mkdir -p "$PROJ_DIR"
touch "$PROJ_DIR/$PIN_SID.jsonl"

# spawn-fresh-orchestrator.sh sources monitor/_claude-bin.sh.
cp "$_test_dir/../_claude-bin.sh" "$FAKE_NEXUS/monitor/_claude-bin.sh"
cat > "$FAKE_NEXUS/node_modules/.bin/claude" <<'CLAUDE_STUB'
#!/bin/bash
echo "stub-claude: $*"
CLAUDE_STUB
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"

# Seed a couple of reports so the situation-report's "Recent reports"
# section has content to render.
cat > "$FAKE_NEXUS/reports/nexus_2026-05-19_120000_seed-a.md" <<'EOF'
# First-line of report A — seed-a summary

## Summary
Body
EOF
cat > "$FAKE_NEXUS/reports/nexus_2026-05-20_080000_seed-b.md" <<'EOF'
# First-line of report B — seed-b summary

## Summary
Body
EOF

# Seed a last-snapshot.txt so the situation report has a "latest
# watcher emit signature" to surface.
cat > "$STATE_DIR/last-snapshot.txt" <<'EOF'
--- reports ---
nexus_2026-05-20_080000_seed-b.md 1747728000
--- tmux ---
orchestrator bell=0
watcher bell=0
worker-foo bell=0
--- git ---
nexus 0xCAFEBABE clean
EOF

# Stub tmux: record every invocation, behave reasonably for the
# verbs the script uses. Default list-windows answers "orchestrator
# present" so the kill-window branch fires; we run a second test
# below with the absence path. list-windows -F '#{window_index}|#{window_name}'
# is what _resolve_target_index uses — must return at least one row
# matching the target name so the readiness probe can be dispatched
# against a real index.
TMUX_STUB_BIN="$WORK/stub-bin"
mkdir -p "$TMUX_STUB_BIN"
TMUX_LOG="$WORK/tmux-calls.log"
: > "$TMUX_LOG"

cat > "$TMUX_STUB_BIN/tmux" <<STUB
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$TMUX_LOG"
case "\$1" in
    list-windows)
        fmt="\$3"
        if [[ -f "$WORK/tmux-orchestrator-absent" ]]; then
            names=("watcher" "worker-foo")
        else
            names=("watcher" "orchestrator" "worker-foo")
        fi
        idx=0
        for n in "\${names[@]}"; do
            case "\$fmt" in
                '#{window_name}'|'')                 printf '%s\n' "\$n" ;;
                '#I #W')                             printf '%d %s\n' "\$idx" "\$n" ;;
                '#{window_index}|#{window_name}')    printf '%d|%s\n' "\$idx" "\$n" ;;
                *)                                   printf '%s\n' "\$n" ;;
            esac
            idx=\$(( idx + 1 ))
        done
        ;;
    kill-window|new-window|set-window-option|send-keys|load-buffer|paste-buffer|delete-buffer)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$TMUX_STUB_BIN/tmux"

# Stub pane-state.sh at the location the helper looks for it
# ($_monitor_dir/pane-state.sh). A small "scripted responses" file
# under $WORK gates what state is reported on consecutive calls; the
# stub pops one entry per invocation. When the file is missing or
# empty, the stub answers `state=idle` so the readiness probe passes
# instantly and the post-paste verify also passes — keeps unrelated
# tests below from needing to seed the file explicitly.
PANE_STATE_STUB="$FAKE_NEXUS/monitor/pane-state.sh"
PANE_STATE_LOG="$WORK/pane-state-calls.log"
PANE_STATE_SCRIPT="$WORK/pane-state-script.txt"
: > "$PANE_STATE_LOG"
cat > "$PANE_STATE_STUB" <<PSTUB
#!/bin/bash
printf '%s\n' "pane-state \$*" >> "$PANE_STATE_LOG"
if [[ -s "$PANE_STATE_SCRIPT" ]]; then
    next=\$(head -n1 "$PANE_STATE_SCRIPT")
    tail -n +2 "$PANE_STATE_SCRIPT" > "$PANE_STATE_SCRIPT.tmp" && mv "$PANE_STATE_SCRIPT.tmp" "$PANE_STATE_SCRIPT"
    printf 'state=%s active=1 window=\$1 name=orchestrator\n' "\$next"
else
    printf 'state=idle active=1 window=\$1 name=orchestrator\n'
fi
PSTUB
chmod +x "$PANE_STATE_STUB"

# --- Test 1: happy path with orchestrator-settings.json present ----------

echo '=== happy path: settings present, orchestrator window alive, kill+spawn+paste (resume mode via valid pin) ==='

cat > "$FAKE_NEXUS/monitor/orchestrator-settings.json" <<'EOF'
{
  "skipDangerousModePermissionPrompt": true,
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "/dev/null" } ] }
    ]
  }
}
EOF

# Snapshot of /tmp launcher files BEFORE the run so we can pick out
# the one this run produced.
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

# Default-mode (continue) run.
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: synthetic stale pin" \
                   --previous-sid "abcdef01-2345-6789-abcd-ef0123456789" \
                   2>"$WORK/stderr-1.log"
rc=$?
assert_eq "exit 0 on happy path (continue default)" "$rc" "0"

# Pick the launcher script generated by this run. The script
# `rm -f`'s the file inside its heredoc body — but our stub for
# tmux DOES NOT actually run the launcher (new-window is a no-op),
# so the file stays on disk until our `trap` cleans up at the end.
launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    pass "launcher tempfile created at $new_launcher"
    launcher_body=$(cat "$new_launcher")
    # `$CLAUDE_BIN` resolves to the project-local install at script-eval
    # time, so the exec line is now
    # `exec "/abs/path/.../node_modules/.bin/claude" --dangerously...`.
    if [[ "$launcher_body" =~ exec\ \"?[^\ ]*claude\"?\ --dangerously-skip-permissions ]]; then
        printf '  PASS: launcher carries exec <CLAUDE_BIN> --dangerously-skip-permissions\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: launcher missing exec <CLAUDE_BIN> --dangerously-skip-permissions in body=%q\n' "$launcher_body" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    assert_contains "launcher carries --resume <pinned-sid> (issue #176)" \
                    "$launcher_body" "--resume $PIN_SID"
    assert_not_contains "launcher does NOT carry --continue when pin is valid" \
                    "$launcher_body" "--continue"
    assert_contains "launcher carries --settings flag pointing at orchestrator-settings.json" \
                    "$launcher_body" "--settings $FAKE_NEXUS/monitor/orchestrator-settings.json"
    assert_contains "launcher exports NEXUS_ROOT" \
                    "$launcher_body" "export NEXUS_ROOT=\"$FAKE_NEXUS\""
    assert_contains "launcher exports NEXUS_IS_ORCHESTRATOR marker" \
                    "$launcher_body" "export NEXUS_IS_ORCHESTRATOR=1"
else
    fail "no new launcher tempfile produced under $RESPAWN_TMPDIR/nexus-respawn-launch-*"
fi

# Situation report assertions — continue-mode wording.
REPORT="$STATE_DIR/orchestrator-fresh-spawn.last-report.md"
if [[ -f "$REPORT" ]]; then
    pass "situation-report file present at $REPORT"
    body=$(cat "$REPORT")
    assert_contains "report uses resume-mode preamble naming --resume"  "$body" "resumed via \`claude --resume"
    assert_contains "report mentions reason"        "$body" "test: synthetic stale pin"
    assert_contains "report cites previous SID"     "$body" "abcdef01-2345-6789-abcd-ef0123456789"
    assert_contains "report has Current tmux windows section" "$body" "## Current tmux windows"
    assert_contains "report has Recent reports section"        "$body" "## Recent reports"
    assert_contains "report lists a seeded report file"        "$body" "seed-b.md"
    assert_contains "report has Latest watcher emit signature" "$body" "## Latest watcher emit signature"
    assert_contains "report inlines a snippet of last-snapshot"  "$body" "nexus 0xCAFEBABE clean"
    assert_contains "report has resume-mode Suggested first checks" \
                    "$body" "## Suggested first checks"
    assert_contains "report tags mode as resume"  "$body" "- Mode: resume"
else
    fail "situation-report file missing at $REPORT"
fi

# Cooldown marker.
COOLDOWN="$STATE_DIR/orchestrator-fresh-spawn.last"
if [[ -f "$COOLDOWN" ]]; then
    pass "cooldown marker file written at $COOLDOWN"
    cd_value=$(cat "$COOLDOWN")
    if [[ "$cd_value" =~ ^[0-9]+$ ]]; then
        pass "cooldown marker is a valid epoch integer"
    else
        fail "cooldown marker contents not numeric: $cd_value"
    fi
else
    fail "cooldown marker missing at $COOLDOWN"
fi

# tmux call log: must include kill-window, new-window, load-buffer,
# paste-buffer, send-keys Enter.
tmux_log=$(cat "$TMUX_LOG")
assert_contains "tmux kill-window invoked on target"  "$tmux_log" "tmux kill-window -t orchestrator"
assert_contains "tmux new-window invoked for target"  "$tmux_log" "tmux new-window -d -n orchestrator"
assert_contains "tmux set-window-option remain-on-exit on" "$tmux_log" \
                "set-window-option -t orchestrator remain-on-exit on"
assert_contains "tmux load-buffer received the report file" "$tmux_log" \
                "tmux load-buffer -b nexus-respawn"
assert_contains "tmux paste-buffer targeted the new window" "$tmux_log" \
                "paste-buffer -b nexus-respawn"
assert_contains "tmux send-keys submitted with Enter"  "$tmux_log" "send-keys -t orchestrator Enter"

# Pane-state probe was actually used to gate the paste.
pane_state_log=$(cat "$PANE_STATE_LOG")
if [[ -n "$pane_state_log" ]]; then
    pass "pane-state.sh probe was invoked at least once"
else
    fail "pane-state.sh probe was NOT invoked — readiness gate didn't run"
fi

# --- Test 1b: pin MISSING → cold spawn, NOT --continue (issue #200) ------
#
# The 2026-05-29 mass-kill recovery degraded to `--continue` because
# the pin was absent (`previous_sid=none`), and `--continue` grabbed a
# transient recovery session as the freshest jsonl. The safe
# degradation is a COLD spawn: launcher carries neither --resume nor
# --continue, and the report uses the unrecoverable/re-onboard wording.

echo '=== pin missing: helper degrades to a COLD spawn, never --continue (issue #200) ==='
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
rm -f "$REPORT" "$COOLDOWN"
# Remove the pin for the duration of this test, then restore it.
mv "$PIN_FILE" "$WORK/pin-backup"

launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: pin missing cold degrade" \
                   2>"$WORK/stderr-1b.log"
rc=$?
assert_eq "exit 0 on pin-missing cold path" "$rc" "0"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    launcher_body=$(cat "$new_launcher")
    assert_not_contains "pin-missing launcher OMITS --continue (issue #200)" \
                        "$launcher_body" "--continue"
    assert_not_contains "pin-missing launcher OMITS --resume (nothing to resume)" \
                        "$launcher_body" "--resume"
else
    fail "no launcher tempfile produced on pin-missing cold path"
fi
body=$(cat "$REPORT")
assert_contains "pin-missing report uses cold/no-resume wording" \
                "$body" "NO resumed conversation context"
assert_contains "pin-missing report has First actions section" \
                "$body" "## First actions"
assert_contains "pin-missing report tags mode as fresh" \
                "$body" "- Mode: fresh"

# Restore the pin so the remaining tests see the deterministic default.
mv "$WORK/pin-backup" "$PIN_FILE"

# --- Test 2: --fresh flag → launcher omits --continue --------------------

echo '=== --fresh flag: launcher omits --continue, report uses fresh-mode wording ==='
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
rm -f "$REPORT" "$COOLDOWN"

launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator \
                   --fresh \
                   --reason "test: jsonl corrupt — fresh boot" \
                   2>"$WORK/stderr-2.log"
rc=$?
assert_eq "exit 0 on --fresh path" "$rc" "0"
launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    launcher_body=$(cat "$new_launcher")
    assert_not_contains "fresh-mode launcher OMITS --continue" \
                        "$launcher_body" "--continue"
    assert_contains "fresh-mode launcher still has --settings" \
                    "$launcher_body" "--settings $FAKE_NEXUS/monitor/orchestrator-settings.json"
    # Issue #203: even an emergency --fresh boot gets a deterministic
    # generated --session-id and pins it at spawn.
    assert_contains "fresh-mode launcher carries a generated --session-id" \
                    "$launcher_body" "--session-id "
else
    fail "no launcher tempfile produced on --fresh path"
fi
body=$(cat "$REPORT")
assert_contains "fresh-mode report uses unrecoverable wording" \
                "$body" "unrecoverable"
assert_contains "fresh-mode report has First actions section" \
                "$body" "## First actions"
assert_contains "fresh-mode report tags mode as fresh" \
                "$body" "- Mode: fresh"
# Issue #203: the --fresh boot wrote a valid-UUID pin at spawn.
if [[ -f "$PIN_FILE" ]]; then
    pinned_after_fresh=$(<"$PIN_FILE"); pinned_after_fresh="${pinned_after_fresh//[[:space:]]/}"
    if [[ "$pinned_after_fresh" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        pass "fresh boot wrote a valid UUID pin at spawn ($pinned_after_fresh)"
    else
        fail "fresh boot pin is not a valid UUID: '$pinned_after_fresh'"
    fi
else
    fail "fresh boot did not write a session-id pin"
fi

# --- Test 3: settings file ABSENT → launcher omits --settings -----------

echo '=== settings-absent path: launcher composed without --settings ==='
rm -f "$FAKE_NEXUS/monitor/orchestrator-settings.json"
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
rm -f "$REPORT" "$COOLDOWN"
# Re-stage the canonical pin + jsonl: the --fresh boot above
# (correctly, per #203) overwrote $PIN_FILE with its generated
# session-id, so restore the resume-path fixture this test asserts on.
printf '%s\n' "$PIN_SID" > "$PIN_FILE"
touch "$PROJ_DIR/$PIN_SID.jsonl"

launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: settings missing" 2>>"$WORK/stderr-3.log"
rc=$?
assert_eq "exit 0 even when settings file absent" "$rc" "0"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    launcher_body=$(cat "$new_launcher")
    assert_not_contains "launcher omits --settings when file absent" \
                        "$launcher_body" "--settings"
    if [[ "$launcher_body" =~ exec\ \"?[^\ ]*claude\"?\ --dangerously-skip-permissions ]]; then
        printf '  PASS: launcher still carries exec <CLAUDE_BIN>\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: launcher missing exec <CLAUDE_BIN> in body=%q\n' "$launcher_body" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    assert_contains "launcher still carries --resume <sid> (pin valid)" \
                    "$launcher_body" "--resume $PIN_SID"
    assert_not_contains "settings-absent launcher does NOT carry --continue" \
                        "$launcher_body" "--continue"
else
    fail "no launcher tempfile produced on settings-absent path"
fi
# Restore the settings file for subsequent tests that depend on it.
cat > "$FAKE_NEXUS/monitor/orchestrator-settings.json" <<'EOF'
{
  "hooks": {}
}
EOF

# --- Test 4: target window already absent → kill-window is skipped ------

echo '=== target absent: helper still spawns + pastes, kill-window skipped ==='
touch "$WORK/tmux-orchestrator-absent"
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
rm -f "$REPORT" "$COOLDOWN"

NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: target already absent" 2>>"$WORK/stderr-4.log"
rc=$?
assert_eq "exit 0 when target already absent" "$rc" "0"

tmux_log=$(cat "$TMUX_LOG")
assert_not_contains "kill-window NOT invoked when target absent" \
                    "$tmux_log" "kill-window -t orchestrator"
assert_contains "new-window still invoked"  "$tmux_log" "new-window -d -n orchestrator"
rm -f "$WORK/tmux-orchestrator-absent"

# --- Test 5: missing NEXUS_ROOT / --target → bad usage ------------------

echo '=== usage errors return non-zero ==='
rc=0
PATH="$TMUX_STUB_BIN:$PATH" bash "$SCRIPT" 2>/dev/null || rc=$?
if (( rc != 0 )); then
    pass "missing --target produces non-zero exit (rc=$rc)"
else
    fail "missing --target unexpectedly succeeded"
fi

rc=0
NEXUS_ROOT="$WORK/does-not-exist" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator 2>/dev/null || rc=$?
if (( rc != 0 )); then
    pass "bad NEXUS_ROOT produces non-zero exit (rc=$rc)"
else
    fail "bad NEXUS_ROOT unexpectedly succeeded"
fi

# --- Test 6: readiness probe waits for state=idle/empty -----------------
#
# Seed the pane-state script so the first probe returns busy (TUI not
# wired yet), the second returns empty (input box live). The helper
# must consume both before issuing the paste — guards against a
# regression that paste-fires on the first probe regardless.

echo '=== readiness probe consumes multiple probes until state=empty/idle ==='
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
rm -f "$REPORT" "$COOLDOWN"
cat > "$PANE_STATE_SCRIPT" <<'EOF'
busy
busy
empty
busy
EOF

NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=10 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=2 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: readiness probe" \
                   2>"$WORK/stderr-6.log"
rc=$?
assert_eq "exit 0 with multi-probe readiness wait" "$rc" "0"

# At least 3 probes happened — two busy + one empty/idle, then the
# post-paste verify probes too. Just check >= 3.
pane_state_log=$(cat "$PANE_STATE_LOG")
probe_count=$(grep -c "pane-state" <<<"$pane_state_log" || true)
if (( probe_count >= 3 )); then
    pass "readiness probe was polled >=3 times (saw ${probe_count})"
else
    fail "readiness probe polled only ${probe_count} times (expected >=3)"
fi
assert_contains "logfile records readiness probe completion" \
                "$(cat "$WORK/stderr-6.log")" "input-ready probe:"

# --- Test 7: post-paste verify retries Enter once when state=empty ------
#
# Seed: readiness probe returns idle (paste happens), post-paste
# verify returns empty (Enter dropped), retry-verify returns busy
# (the retried Enter worked). Helper must invoke send-keys Enter
# twice in this case — once during the initial paste, once during
# the retry path.

echo '=== post-paste verify: when state stays empty, retry Enter once ==='
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
rm -f "$REPORT" "$COOLDOWN"
# Sequence: readiness probe pops `idle` → paste fires; post-paste
# verify pops `empty` twice (budget=1 s + 0.5 s polls ⇒ 2 probes) and
# exits with timeout; retry Enter fires; verify-after-retry pops
# `busy` and confirms.
cat > "$PANE_STATE_SCRIPT" <<'EOF'
idle
empty
empty
busy
EOF

NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: enter retry" \
                   2>"$WORK/stderr-7.log"
rc=$?
assert_eq "exit 0 when Enter-retry succeeds" "$rc" "0"

tmux_log=$(cat "$TMUX_LOG")
# Count Enter invocations: the paste path always sends one Enter; the
# retry path sends a second. Two is the expected total.
enter_count=$(grep -c "send-keys -t orchestrator Enter" <<<"$tmux_log" || true)
if (( enter_count == 2 )); then
    pass "send-keys Enter invoked exactly 2x (initial + 1 retry)"
else
    fail "send-keys Enter invoked ${enter_count}x — expected exactly 2"
fi
assert_contains "logfile records the Enter retry" \
                "$(cat "$WORK/stderr-7.log")" "retrying Enter once"

# --- Test 8: readiness probe dismisses state=blocked (--continue summary
#              prompt / permission overlay / AskUQ chip-bar) -------------
#
# Real motivation: `claude --continue` sometimes presents a "Compact /
# Summarize prior conversation?" prompt at boot. pane-state.sh
# classifies that overlay as `state=blocked`. Without dismissal the
# situation-report paste would land *into the modal input* and never
# submit as a turn — silently consumed by the dialog. The readiness
# probe sends Escape (canonical dismissal verb across Claude Code
# modals) up to MAX_DISMISS_ATTEMPTS times, with the budget bounding
# overall.

echo '=== readiness probe Escapes state=blocked dialogs (--continue summary prompt) ==='
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
rm -f "$REPORT" "$COOLDOWN"
# Sequence: blocked, blocked, idle — two Escapes, then the dialog
# clears and the paste proceeds. Last entries cover the post-paste
# verify probes.
cat > "$PANE_STATE_SCRIPT" <<'EOF'
blocked
blocked
idle
busy
EOF

NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=10 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=2 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: continue summary prompt" \
                   2>"$WORK/stderr-8.log"
rc=$?
assert_eq "exit 0 when blocked-overlay is dismissed within budget" "$rc" "0"

tmux_log=$(cat "$TMUX_LOG")
# Two Escapes during the readiness wait (one per blocked observation).
escape_count=$(grep -c "send-keys -t orchestrator Escape" <<<"$tmux_log" || true)
if (( escape_count == 2 )); then
    pass "send-keys Escape invoked exactly 2x (one per blocked observation)"
else
    fail "send-keys Escape invoked ${escape_count}x — expected exactly 2"
fi
assert_contains "logfile records the dismiss attempts" \
                "$(cat "$WORK/stderr-8.log")" "sending Escape to dismiss"
# The paste still proceeded; check for the load-buffer + Enter pair.
assert_contains "paste still proceeded after dismissal" \
                "$tmux_log" "load-buffer -b nexus-respawn"
assert_contains "Enter still sent after dismissal" \
                "$tmux_log" "send-keys -t orchestrator Enter"

# Test 8b: a runaway dialog that regenerates each cycle should NOT
# turn the readiness wait into an Escape spammer beyond
# MAX_DISMISS_ATTEMPTS.

echo '=== readiness probe caps Escapes at MAX_DISMISS_ATTEMPTS ==='
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
rm -f "$REPORT" "$COOLDOWN"
# Sequence: 20 blocked entries; with the cap at 3, only 3 Escapes
# should fire, the rest stay in observe-mode.
{
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        echo blocked
    done
    # And a busy at the very end so post-paste verify can settle if
    # the budget happens to reach that far (it won't with these
    # numbers, but a defensive entry costs nothing).
    echo busy
} > "$PANE_STATE_SCRIPT"

NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
MAX_DISMISS_ATTEMPTS=3 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: runaway blocked" \
                   2>"$WORK/stderr-8b.log"
# The paste is still attempted on readiness timeout (legacy fallback);
# tmux send-keys etc. all return 0 from the stub so we still exit 0.
rc=$?
assert_eq "exit 0 even when readiness budget elapses on persistent blocked" "$rc" "0"

tmux_log=$(cat "$TMUX_LOG")
escape_count=$(grep -c "send-keys -t orchestrator Escape" <<<"$tmux_log" || true)
if (( escape_count <= 3 )); then
    pass "Escape attempts capped at MAX_DISMISS_ATTEMPTS=3 (saw ${escape_count})"
else
    fail "Escape attempts exceeded cap: ${escape_count} > 3"
fi

# --- Test 9: pinned-sid resume REFUSED for a non-coordinator target -----
#
# your-org/your-nexus#206: the pinned orchestrator session may only
# ever be resumed into the configured coordinator window
# (monitor.target_window, default `orchestrator` — this fixture has no
# config/load.sh, so the default applies). A valid pin + a mismatched
# --target must downgrade to a COLD spawn with a loud refusal, never
# `claude --resume <pinned-sid>` into the foreign window (that is the
# duplicate-orchestrator incident).

echo '=== non-coordinator --target: pinned-sid resume downgrades to COLD spawn (your-nexus#206) ==='
: > "$TMUX_LOG"
: > "$PANE_STATE_LOG"
: > "$PANE_STATE_SCRIPT"
rm -f "$REPORT" "$COOLDOWN"
printf '%s\n' "$PIN_SID" > "$PIN_FILE"   # pin valid again (and its jsonl still exists)

launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target worker-foo --reason "test: 206 non-coordinator target guard" \
                   2>"$WORK/stderr-9.log"
rc=$?
assert_eq "exit 0 — the cold spawn itself still proceeds" "$rc" "0"
stderr9=$(cat "$WORK/stderr-9.log")
assert_contains "stderr announces the refusal loudly" "$stderr9" \
                "REFUSING to resume the pinned orchestrator session"
assert_contains "stderr names the configured coordinator window" "$stderr9" \
                "configured coordinator: 'orchestrator'"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    launcher_body=$(cat "$new_launcher")
    assert_not_contains "launcher does NOT resume the pinned sid" \
                        "$launcher_body" "--resume $PIN_SID"
    assert_not_contains "launcher does NOT degrade to --continue" \
                        "$launcher_body" "--continue"
else
    fail "no new launcher tempfile produced for the non-coordinator-target run"
fi

if [[ -f "$REPORT" ]]; then
    body=$(cat "$REPORT")
    assert_contains "situation report tags mode as fresh (cold)" "$body" "- Mode: fresh"
    assert_contains "report uses the cold-spawn re-onboarding preamble" "$body" "recovery spawn"
else
    fail "situation-report file missing at $REPORT for the non-coordinator-target run"
fi

# --- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
