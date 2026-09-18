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
        # fail() prints ONLY "$1", so passing printf ARGS to it drops both values
        # and emits the literal "%q want %q" — the diagnostic naming the mismatch
        # is exactly what a failing assertion exists to supply. Format HERE and
        # hand fail() one finished string; this is the form the rest of the
        # corpus already uses (test-fork-headroom-guard.sh, test-paste-*.sh).
        fail "$(printf '%s — got %q want %q' "$label" "$got" "$want")"
    fi
}

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
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
        # The absence marker models a MISSING target; once this stub has
        # logged a new-window the target exists again, or the helper could
        # never resolve an index for the post-paste probe and every absence
        # arm would read rc 4 for a reason unrelated to what it tests
        # (your-org/nexus-code#1470 -- the same fixture shape test-respawn.sh
        # had to repair).
        if [[ -f "$WORK/tmux-orchestrator-absent" ]] && ! grep -q 'new-window' "$TMUX_LOG"; then
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
    new-window)
        # -P -F '#{window_id}' makes tmux print the id of the window it just
        # created, and _respawn_spawn_window keys its rc=3 contract on that
        # handle rather than on a presence-by-NAME probe (your-org/nexus-code
        # #1327). A stub answering with ZERO BYTES models "created nothing",
        # so the arm has to speak the handle or every spawn reads as a
        # failure. Most stubs in this corpus already do -- spawn-worker.sh
        # has used the same discriminator since #323; the respawn family
        # was the outlier, in the code and in its fixtures alike.
        # NO BACKTICKS IN THIS HEREDOC: it is UNQUOTED (<<STUB), so a
        # backticked word in a COMMENT is command-substituted when the fixture
        # is written (your-org/nexus-code#1157).
        printf '@7\n'
        exit 0
        ;;
    kill-window|set-window-option|send-keys|load-buffer|paste-buffer|delete-buffer)
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
# stub pops one entry per invocation. When the file is missing or empty
# the stub's DEFAULT answer is CAUSED by the paste, not scripted: `idle`
# until an Enter appears in the tmux stub's log, `busy` after it
# (your-org/nexus-code#1470). This comment used to say the static `idle`
# default made "the post-paste verify also pass" -- it did, and that was
# the #1470 defect certified by its own fixture: readiness accepts
# `empty|idle`, submit-evidence accepts `busy` (then `busy|user-typing`), the sets are
# DISJOINT, so a static answer can satisfy at most one of them, and the
# helper reported rc 0 on an exhausted verification. When the helper began
# reporting honestly (rc 4), all eleven arms here went red for that reason
# alone. The log the default reads is one every arm already truncates.
#
# SECOND CAUSED RULE, a table keyed on HOW MANY Enters the tmux log holds:
# "$WORK/pane-state-by-enters" carries three states -- for zero, one, and two
# or more Enters -- and while it exists the default answers from it instead of
# the idle/busy pair. Two arms need it, and both used to SCRIPT a fixed
# sequence that assumed a particular PROBE COUNT: Test 7's `idle, empty,
# empty, busy` assumed exactly two probes fit its 1 s verify window, and the
# runaway-blocked arm's twenty `blocked` entries assumed they would all be
# consumed inside a 2 s readiness budget. On a loaded CI runner one probe fits
# the window and few fit the budget; the scripts then hand the WRONG state to
# the post-paste verify, and the helper honestly reports rc 4 -- which is how
# PR 1473's NEXUS_ROOT-unset band went red on Test 7 at minute 39 of 40, and
# how the runaway arm reds under PSTUB_SLOW_S=0.7 (measured here; CI simply had
# not been slow enough on that arm yet). A state CAUSED by the Enter count is
# true at any probe rate. PSTUB_SLOW_S=<seconds> sleeps that long per probe to
# reproduce the loaded-runner regime on demand.
PANE_STATE_STUB="$FAKE_NEXUS/monitor/pane-state.sh"
PANE_STATE_LOG="$WORK/pane-state-calls.log"
PANE_STATE_SCRIPT="$WORK/pane-state-script.txt"
: > "$PANE_STATE_LOG"
cat > "$PANE_STATE_STUB" <<PSTUB
#!/bin/bash
printf '%s\n' "pane-state \$*" >> "$PANE_STATE_LOG"
[[ -n "\${PSTUB_SLOW_S:-}" ]] && sleep "\$PSTUB_SLOW_S"
if [[ -s "$PANE_STATE_SCRIPT" ]]; then
    next=\$(head -n1 "$PANE_STATE_SCRIPT")
    tail -n +2 "$PANE_STATE_SCRIPT" > "$PANE_STATE_SCRIPT.tmp" && mv "$PANE_STATE_SCRIPT.tmp" "$PANE_STATE_SCRIPT"
    printf 'state=%s active=1 window=\$1 name=orchestrator\n' "\$next"
elif [[ -s "$WORK/pane-state-by-enters" ]]; then
    read -r s0 s1 s2 < "$WORK/pane-state-by-enters"
    n=\$(grep -c 'send-keys .* Enter' "$TMUX_LOG" 2>/dev/null); n=\${n:-0}
    if (( n >= 2 )); then st=\$s2; elif (( n == 1 )); then st=\$s1; else st=\$s0; fi
    printf 'state=%s active=1 window=\$1 name=orchestrator\n' "\$st"
elif grep -qs 'send-keys .* Enter' "$TMUX_LOG"; then
    printf 'state=busy active=1 window=\$1 name=orchestrator\n'
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
                "paste-buffer -p -b nexus-respawn"
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
# CAUSED, not scripted: `idle` before any Enter (readiness passes), `empty`
# after the first Enter (the paste's Enter "dropped" -- verify times out,
# however many probes fit in its 1 s window), `busy` from the second Enter on
# (the retry took). The former fixed sequence `idle, empty, empty, busy`
# assumed exactly two probes in the window and went red on a loaded CI runner
# where one fits (see the stub's second rule).
: > "$PANE_STATE_SCRIPT"
printf 'idle empty busy\n' > "$WORK/pane-state-by-enters"

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
rm -f "$WORK/pane-state-by-enters"
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
# CAUSED, not scripted: `blocked` for as long as no Enter has been sent --
# the whole readiness budget, however many probes fit in it -- so the cap
# of 3 Escapes is what bounds the Escapes, not the length of a script; then
# `busy` from the paste's Enter on, so the post-paste verify settles. The
# former script of twenty `blocked` entries plus a trailing `busy` assumed
# the budget would consume all twenty; under PSTUB_SLOW_S=0.7 it did not, the
# verify popped `blocked`, and the arm read rc 4 (see the stub's second rule).
: > "$PANE_STATE_SCRIPT"
printf 'blocked busy busy\n' > "$WORK/pane-state-by-enters"

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
rm -f "$WORK/pane-state-by-enters"
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

# --- Test 10: cold-boot dropped-worker manifest lands in the report ------
#
# your-org/nexus-code#651. A cold boot (`./watcher` without `--continue`)
# resurrects no workers and leaves a manifest of what it dropped. This
# report IS the incoming orchestrator's first turn, so it is the primary
# delivery surface — and delivery must be once-only, or a wedge respawn
# next week re-opens a settled question with a list of workers that have
# been irrelevant for days.

echo '=== cold-boot dropped-worker manifest: inlined verbatim into the situation report, exactly once ==='

# Guard the guard: the helpers are sourced from monitor/_dropped_manifest.sh,
# and a source that silently fails would leave the `if` below calling an
# undefined function — which is rc 127, which reads as "nothing pending",
# which is indistinguishable from a working no-op. Assert they EXIST
# before asserting on what they do.
if bash -c 'source "'"$_test_dir"'/../_dropped_manifest.sh" \
            && declare -F _dropped_manifest_pending >/dev/null \
            && declare -F _dropped_manifest_mark_delivered >/dev/null'; then
    pass "manifest helpers are really sourceable (not a silently-degraded rc-127 no-op)"
else
    fail "monitor/_dropped_manifest.sh did not define the delivery helpers"
fi

MANIFEST="$STATE_DIR/cold-boot-dropped-workers.md"
MANIFEST_MARKER="$STATE_DIR/cold-boot-dropped-workers.delivered"
rm -f "$MANIFEST_MARKER"
cat > "$MANIFEST" <<'EOF'
# Cold boot dropped 1 worker agent(s)

### `worker-foo`
- session-id: `feedface-0000-1111-2222-333344445555`
- workdir: `/fake/work/worker-foo`
- re-spawn with: `monitor/spawn-worker.sh --resume worker-foo`
EOF

NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: cold-boot manifest" \
                   2>"$WORK/stderr-10.log"
report_10=$(cat "$REPORT" 2>/dev/null)
assert_contains "report inlines the manifest heading" \
                "$report_10" "Cold boot dropped 1 worker agent(s)"
assert_contains "report inlines the dropped worker's session-id (actionable, not a pointer to a file)" \
                "$report_10" "feedface-0000-1111-2222-333344445555"
assert_contains "report inlines the exact re-spawn command" \
                "$report_10" "monitor/spawn-worker.sh --resume worker-foo"
if [[ -f "$MANIFEST_MARKER" ]]; then
    pass "delivery marker written after inlining"
else
    fail "no delivery marker at $MANIFEST_MARKER"
fi
if [[ -s "$MANIFEST" ]]; then
    pass "manifest itself survives delivery (audit record, not consumed)"
else
    fail "manifest deleted by delivery"
fi

# Second spawn, same manifest: already delivered → must NOT reappear.
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: manifest already delivered" \
                   2>"$WORK/stderr-10b.log"
assert_not_contains "a later respawn does NOT re-deliver an already-delivered manifest" \
                    "$(cat "$REPORT" 2>/dev/null)" "Cold boot dropped 1 worker agent(s)"

# …and with no manifest at all the report is unchanged (the common case
# must stay silent — every non-cold-boot respawn goes through here).
rm -f "$MANIFEST" "$MANIFEST_MARKER"
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: no manifest" \
                   2>"$WORK/stderr-10c.log"
report_10c=$(cat "$REPORT" 2>/dev/null)
assert_not_contains "no manifest → report carries no drop section" \
                    "$report_10c" "Cold boot dropped"
assert_contains "no manifest → the report is otherwise intact" \
                "$report_10c" "## Recent reports (top 5 by mtime)"

# --- Test 11: a FAILED spawn must not consume the manifest ---------------
#
# your-org/nexus-code#651 skeptic, finding 2 — blocking. Marking the manifest
# delivered during report COMPOSITION meant a single failed `tmux new-window`
# (rc 3) consumed it anyway: both documented surfaces went dead, and the retry
# that the cooldown machinery exists to make — which succeeds — handed the new
# orchestrator a situation report with no manifest at all. Composing a report
# is not delivering one. Consumption is now gated on the respawn helper
# returning 0.

echo '=== failed spawn must leave the manifest PENDING for the retry / the bootstrap.sh backstop ==='

rm -f "$MANIFEST_MARKER"
cat > "$MANIFEST" <<'EOF'
# Cold boot dropped 1 worker agent(s)

### `worker-swallowed`
- session-id: `deadbeef-1111-2222-3333-444455556666`
EOF

# Force `tmux new-window` to fail (rc 1) → the respawn helper returns 3.
FAILING_TMUX_BIN="$WORK/failing-tmux-bin"
mkdir -p "$FAILING_TMUX_BIN"
# The base stub's `new-window` arm now emits a `@id` and exits 0 (#1327), so
# an arm INSERTED BELOW it would be unreachable — a fixture that silently
# stopped being a fixture, which is the failure this suite's own Test 11
# guards against one layer up. Anchor on `new-window` itself and put the
# failing arm FIRST; the potency check below (`spawn_rc != 0`) is what proves
# it took.
sed 's|^    new-window)|    new-window) exit 1 ;;\n    new-window)|' \
    "$TMUX_STUB_BIN/tmux" > "$FAILING_TMUX_BIN/tmux"
chmod +x "$FAILING_TMUX_BIN/tmux"

NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$FAILING_TMUX_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: spawn fails with a pending manifest" \
                   2>"$WORK/stderr-11.log"
spawn_rc=$?

if (( spawn_rc != 0 )); then
    pass "fixture is real: the spawn genuinely failed (rc=$spawn_rc)"
else
    fail "spawn unexpectedly succeeded — the failing-tmux fixture did not take effect"
fi
if [[ ! -f "$MANIFEST_MARKER" ]]; then
    pass "failed spawn did NOT mark the manifest delivered (consumption is gated on confirmed delivery, not on attempt)"
else
    fail "manifest consumed by a failed spawn — swallowed exactly as before"
fi

# The decisive assertion: the RETRY, which succeeds, must still carry it.
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$TMUX_STUB_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: retry after a failed spawn" \
                   2>"$WORK/stderr-11b.log"
assert_contains "the successful RETRY still delivers the manifest (nothing was permanently lost)" \
                "$(cat "$REPORT" 2>/dev/null)" "worker-swallowed"
if [[ -f "$MANIFEST_MARKER" ]]; then
    pass "the retry — which actually reached the agent — is what marks it delivered"
else
    fail "successful retry did not mark delivery"
fi
rm -f "$MANIFEST" "$MANIFEST_MARKER"

# --- Test 12: option-arm-only failure is NOT a spawn failure -------------
#
# The other half of the rc=3 contract, and the one Test 11 CANNOT see.
#
# `_respawn_spawn_window` arms `remain-on-exit` in ONE chained tmux command
# list, so one status covers two commands, and it disambiguates by asking
# whether the target window is present afterwards. Test 11 pins the direction
# where that probe must NOT be believed: its stub reports the target present
# unconditionally, so a `new-window` that failed is indistinguishable from one
# that worked, and the helper must fail CLOSED (rc 3).
#
# But the stub is STATIC, so Test 11 alone is also satisfied by a helper that
# samples presence BEFORE the kill instead of after it — measured: hoisting the
# survival re-check above `tmux kill-window` leaves Test 11 fully green. That
# mutant is a real regression of your-org/nexus-code#1102's intent: with a real
# tmux the kill takes, every replace-spawn then looks like a surviving stale
# window, and an option-arm-only failure gets counted as a spawn failure toward
# the slow-grind consecutive-failure guard.
#
# So this case supplies what the static stub cannot: a tmux whose kill ACTUALLY
# TAKES. The window list is state, held in a file. kill-window removes the
# target; the chained new-window re-adds it and then exits 1 (the option arm
# failing after a successful creation). Correct attribution is rc 0 — the
# window exists because THIS call made it.

echo '=== an option-arm-only failure is not a spawn failure (kill took; window is newly created) ==='

STATEFUL_TMUX_BIN="$WORK/stateful-tmux-bin"
mkdir -p "$STATEFUL_TMUX_BIN"
WIN_STATE="$WORK/stateful-windows.txt"
printf '%s\n' watcher orchestrator worker-foo > "$WIN_STATE"

cat > "$STATEFUL_TMUX_BIN/tmux" <<STATEFUL
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$TMUX_LOG"
case "\$1" in
    list-windows)
        fmt="\$3"
        idx=0
        while IFS= read -r n; do
            [[ -n "\$n" ]] || continue
            case "\$fmt" in
                '#{window_name}'|'')                 printf '%s\n' "\$n" ;;
                '#I #W')                             printf '%d %s\n' "\$idx" "\$n" ;;
                '#{window_index}|#{window_name}')    printf '%d|%s\n' "\$idx" "\$n" ;;
                *)                                   printf '%s\n' "\$n" ;;
            esac
            idx=\$(( idx + 1 ))
        done < "$WIN_STATE"
        ;;
    kill-window)
        # The kill genuinely TAKES — this is the whole point of the fixture.
        grep -vxF orchestrator "$WIN_STATE" > "$WIN_STATE.tmp" || true
        mv "$WIN_STATE.tmp" "$WIN_STATE"
        exit 0
        ;;
    new-window)
        # Creation SUCCEEDS — the window list gains the name, AND the handle is
        # emitted on stdout, which is what _respawn_spawn_window now reads
        # (your-org/nexus-code#1327). Writing only to the state file would model
        # a tmux that created a window without saying so, which no tmux does.
        printf '%s\n' orchestrator >> "$WIN_STATE"
        printf '@%d\n' 12
        # …and the chained set-window-option arm is what fails.
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
STATEFUL
chmod +x "$STATEFUL_TMUX_BIN/tmux"

rm -f "$MANIFEST" "$MANIFEST_MARKER"
# TRUNCATE the shared call log. It is APPEND-ONLY across every test above, so
# the potency controls below would otherwise be satisfied by test 1's calls and
# would assert nothing about this fixture at all.
: > "$TMUX_LOG"
rc12=0
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$STATEFUL_TMUX_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: option arm fails, creation succeeded" \
                   2>"$WORK/stderr-12.log" || rc12=$?

# POTENCY CONTROL, run before the verdict is read: the fixture is worthless
# unless the kill really removed the target and `new-window` really put it
# back. Both are observable in the stub's own state file and call log.
assert_contains "fixture is real: the kill was actually dispatched" \
                "$(cat "$TMUX_LOG" 2>/dev/null)" "tmux kill-window -t orchestrator"
assert_contains "fixture is real: the chained creation was dispatched" \
                "$(cat "$TMUX_LOG" 2>/dev/null)" "tmux new-window -d -n orchestrator"
assert_contains "fixture is real: the window exists only because this call created it" \
                "$(cat "$WIN_STATE" 2>/dev/null)" "orchestrator"

assert_eq "option-arm-only failure attributed correctly — NOT a spawn failure (rc 0, not 3)" \
          "$rc12" "0"

rm -f "$MANIFEST" "$MANIFEST_MARKER"

# --- Test 13: a CONCURRENT CREATOR must not manufacture a spawn success ---
#
# The route `#1324` left open, and the reason `#1327` exists. Test 11 covers
# "the kill did not take"; Test 12 covers "only the option arm failed". This
# is the third arrangement, and until the handle landed it was the one no
# fixture modelled:
#
#     the kill TAKES  +  `new-window` creates NOTHING  +  something else
#     refills the slot with a window of the same NAME
#
# A presence-by-NAME probe answers `present` and the helper reports a spawn
# that never happened. The window is real; it is simply not this call's. tmux
# permits duplicate window names, and the concurrent creators are named in
# `_respawn_spawn_window`'s own comment — rename heal, operator relaunch, a
# successor watcher's respawn — so the precondition was documented one line
# from the defect.
#
# The cost is not a log line. `spawn-fresh-orchestrator.sh` marks the
# cold-boot dropped-worker manifest DELIVERED on helper rc 0, so a
# manufactured success permanently swallows the record of everything the cold
# boot dropped — the `#651` finding-2 catastrophe, which is exactly what Test
# 11 was written to prevent through the other door.
#
# ASSERTED AS A PROPERTY, NOT AS A CALL SEQUENCE. The original defect needed a
# refill landing between two specific probes; the fix removes both probes, so
# an ordering-keyed fixture would go vacuous the moment it passed — green
# because there is nothing left to race, which reads identically to green
# because the defect is fixed. What this asserts instead is the invariant that
# survives any implementation: with `new-window` having created nothing, a
# same-named window being present at the end must NOT be read as success.
CONCURRENT_TMUX_BIN="$WORK/concurrent-tmux-bin"
mkdir -p "$CONCURRENT_TMUX_BIN"
CWIN_STATE="$WORK/concurrent-windows.txt"
printf '%s\n' watcher orchestrator worker-foo > "$CWIN_STATE"

cat > "$CONCURRENT_TMUX_BIN/tmux" <<CONCURRENT
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$TMUX_LOG"
case "\$1" in
    list-windows)
        fmt="\$3"
        idx=0
        while IFS= read -r n; do
            [[ -n "\$n" ]] || continue
            case "\$fmt" in
                '#{window_name}'|'')                 printf '%s\n' "\$n" ;;
                '#I #W')                             printf '%d %s\n' "\$idx" "\$n" ;;
                '#{window_index}|#{window_name}')    printf '%d|%s\n' "\$idx" "\$n" ;;
                *)                                   printf '%s\n' "\$n" ;;
            esac
            idx=\$(( idx + 1 ))
        done < "$CWIN_STATE"
        ;;
    kill-window)
        # The kill genuinely TAKES. This is what sets the arrangement apart
        # from Test 11 and what made \`#1324\`'s _stale_survived guard inert here.
        grep -vxF orchestrator "$CWIN_STATE" > "$CWIN_STATE.tmp" || true
        mv "$CWIN_STATE.tmp" "$CWIN_STATE"
        exit 0
        ;;
    new-window)
        # Creation FAILS and emits NO handle — nothing was created by this
        # call. A CONCURRENT CREATOR then refills the slot with a window of
        # the same name, which is the whole fixture: the name is back, the
        # window is somebody else's.
        printf '%s\n' orchestrator >> "$CWIN_STATE"
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
CONCURRENT
chmod +x "$CONCURRENT_TMUX_BIN/tmux"

cat > "$MANIFEST" <<'EOF'
# Cold boot dropped 1 worker agent(s)

### `worker-concurrent`
- session-id: `deadbeef-9999-8888-7777-666655554444`
EOF
rm -f "$MANIFEST_MARKER"
: > "$TMUX_LOG"

rc13=0
NEXUS_ROOT="$FAKE_NEXUS" \
STATE_DIR="$STATE_DIR" \
FRESH_SPAWN_CLAUDE_WAIT_SECONDS=0 \
FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 \
FRESH_SPAWN_READINESS_POLL_SECONDS=0 \
FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 \
PANE_STATE_BIN="$PANE_STATE_STUB" \
PATH="$CONCURRENT_TMUX_BIN:$PATH" \
    bash "$SCRIPT" --target orchestrator --reason "test: concurrent creator refills the slot" \
                   2>"$WORK/stderr-13.log" || rc13=$?

# POTENCY CONTROLS, read before the verdict. Without these the assertion below
# is satisfied by any fixture that fails for any reason at all — including one
# where the kill was never dispatched, which is Test 11's arrangement wearing
# this test's name.
assert_contains "fixture is real: the kill was actually dispatched" \
                "$(cat "$TMUX_LOG" 2>/dev/null)" "tmux kill-window -t orchestrator"
assert_contains "fixture is real: the chained creation was dispatched" \
                "$(cat "$TMUX_LOG" 2>/dev/null)" "tmux new-window -d -n orchestrator"
assert_contains "fixture is real: a same-named window IS present afterwards — the name probe would have said SUCCESS" \
                "$(cat "$CWIN_STATE" 2>/dev/null)" "orchestrator"

assert_eq "a concurrent creator does NOT manufacture a spawn success (rc 3, not 0)" \
          "$rc13" "3"
if [[ ! -f "$MANIFEST_MARKER" ]]; then
    pass "the dropped-worker manifest survives: not marked delivered by a spawn that never happened"
else
    fail "manifest consumed by a spawn that never happened — your-org/nexus-code#651 finding 2, through #1327's door"
fi
rm -f "$MANIFEST" "$MANIFEST_MARKER"

# --- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
