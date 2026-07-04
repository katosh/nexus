#!/usr/bin/env bash
# Unit tests for monitor/spawn-worker.sh --resume (the canonical
# respawn mode, your-org/your-nexus issue 197).
#
# Run: bash monitor/watcher/test-spawn-worker-resume.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: fake NEXUS_ROOT + fake $HOME/.claude/projects, stub tmux/ng
# on PATH. Resolution tests use --dry-run (no tmux mutation); the
# spawn-path tests inspect the stub-call log + the generated launcher.
# The env-export assertions are the load-bearing ones: the whole point
# of --resume is that a respawned worker gets NEXUS_ROOT +
# NEXUS_WORKER_WINDOW so the worker-settings hooks keep firing.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_REAL="$_test_dir/../spawn-worker.sh"

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

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Scope launcher tempfiles per-test (spawn-worker.sh honours TMPDIR).
SPAWN_TMP="$WORK/spawn-tmp"
mkdir -p "$SPAWN_TMP"
export TMPDIR="$SPAWN_TMP"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor/.state/spawn-prompts" \
         "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports"
cp "$SCRIPT_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh"
SCRIPT="$FAKE_NEXUS/monitor/spawn-worker.sh"
cp "$_test_dir/../_claude-bin.sh" "$FAKE_NEXUS/monitor/_claude-bin.sh"
# Also sourced by spawn-worker.sh for window-id targeting (#323).
cp "$_test_dir/../_tmux-window.sh" "$FAKE_NEXUS/monitor/_tmux-window.sh"
# And the shared frontmatter reader (#405 P2) for report resolution.
cp "$_test_dir/../_fm_lib.sh" "$FAKE_NEXUS/monitor/_fm_lib.sh"
mkdir -p "$FAKE_NEXUS/node_modules/.bin"
cat > "$FAKE_NEXUS/node_modules/.bin/claude" <<'CLAUDE_STUB'
#!/bin/bash
echo "stub-claude: $*"
CLAUDE_STUB
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"

cat > "$FAKE_NEXUS/monitor/worker-settings.json" <<'EOF'
{ "skipDangerousModePermissionPrompt": true, "hooks": {} }
EOF

# Floor file: resume mode never reads it, but a fresh-mode control
# test below does.
cat > "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
## Worker floor

- FLOOR_MARKER

## End
EOF

# Workdir with an underscore so the slug rule (every non-alphanumeric →
# '-', INCLUDING '_') is actually exercised: group-style paths were
# the documented manual-resume trap.
WORKDIR="$FAKE_NEXUS/work/group-proj"
mkdir -p "$WORKDIR"
SLUG=$(printf '%s' "$WORKDIR" | sed 's|[^a-zA-Z0-9]|-|g')

# Fake Claude Code project dir + transcripts.
export HOME="$WORK/home"
PROJ_DIR="$HOME/.claude/projects/$SLUG"
mkdir -p "$PROJ_DIR"

UUID_REPORT="11111111-1111-1111-1111-111111111111"
UUID_OLD="22222222-2222-2222-2222-222222222222"
UUID_CLOSE="33333333-3333-3333-3333-333333333333"
UUID_FRESH="44444444-4444-4444-4444-444444444444"
# Backdate all transcripts so test 4 can make UUID_FRESH the
# unambiguously newest one (ls -t keys off mtime).
for u in "$UUID_REPORT" "$UUID_OLD" "$UUID_CLOSE" "$UUID_FRESH"; do
    echo '{}' > "$PROJ_DIR/$u.jsonl"
    touch -d "2026-06-01 09:00" "$PROJ_DIR/$u.jsonl"
done

# Stub tmux + ng. Behaviour driven by STUB_TMUX_* env vars so each
# test shapes window-exists / pane-dead / pane-path without rewriting
# the stub. The resume resolver consults tmux first for the workdir;
# resolution-only tests set STUB_TMUX_INFO_RC=1 so file-based sources
# are what's actually under test.
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
STUB_LOG="$WORK/stub-calls.log"
: > "$STUB_LOG"

cat > "$STUB_BIN/tmux" <<STUB
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$STUB_LOG"
case "\$1" in
    info) exit "\${STUB_TMUX_INFO_RC:-0}" ;;
    list-windows)
        # Two callers, distinguished by the -F format (#323):
        #   collision check  -> '#W' / '#{window_name}'  : emit names
        #   resolve_window_id -> '#{window_id}\t#{window_name}': emit @id<TAB>name
        fmt=""; prev=""
        for a in "\$@"; do [ "\$prev" = "-F" ] && fmt="\$a"; prev="\$a"; done
        if [ -n "\${STUB_TMUX_WINDOWS:-}" ]; then
            case "\$fmt" in
                *window_id*) for w in \${STUB_TMUX_WINDOWS}; do printf '@9\t%s\n' "\$w"; done ;;
                *)           printf '%s\n' \${STUB_TMUX_WINDOWS} ;;
            esac
        fi
        exit 0 ;;
    new-window)
        # spawn-worker captures the window id from new-window -P and
        # targets later ops by @id (#323). Emit a deterministic fake id.
        # (No backticks: unquoted heredoc would run them as commands.)
        echo '@9'; exit 0 ;;
    display-message)
        fmt=""
        for a in "\$@"; do fmt="\$a"; done
        case "\$fmt" in
            *pane_dead*)         printf '%s\n' "\${STUB_TMUX_PANE_DEAD:-0}" ;;
            *pane_current_path*) printf '%s\n' "\${STUB_TMUX_PANE_PATH:-}" ;;
        esac
        exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/tmux"

cat > "$FAKE_NEXUS/monitor/ng" <<NGSTUB
#!/bin/bash
printf '%s\n' "ng \$*" >> "$STUB_LOG"
exit 0
NGSTUB
chmod +x "$FAKE_NEXUS/monitor/ng"

export PATH="$STUB_BIN:$PATH"

mkreport() {  # mkreport <filename> <window> <session-id> <mtime>
    local f="$FAKE_NEXUS/reports/$1" window="$2" sid="$3" mtime="$4"
    cat > "$f" <<EOF
---
project: proj
date: 2026-06-10
session-id: $sid
window: $window
status: done
---

# body
EOF
    touch -d "$mtime" "$f"
}

WIN=res-win
CACHE="$FAKE_NEXUS/monitor/.state/spawn-prompts/$WIN.txt"

# ---- Test 1: session-id + workdir resolve from report frontmatter + cache

echo '=== window-name resolution: report frontmatter sid + cache workdir ==='
mkreport "proj_2026-06-09_olddata_x.md"  "$WIN" "$UUID_OLD"    "2026-06-09 10:00"
mkreport "proj_2026-06-10_newdata_x.md"  "$WIN" "$UUID_REPORT" "2026-06-10 10:00"
mkreport "proj_2026-06-10_otherwin_x.md" "other-win" "$UUID_FRESH" "2026-06-10 12:00"
printf -- '- Workdir: %s\n' "$WORKDIR" > "$CACHE"

out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" --dry-run 2>&1)
rc=$?
assert_eq       "dry-run exits 0"                       "$rc" "0"
assert_contains "newest matching report's sid wins"     "$out" "session=$UUID_REPORT"
assert_not_contains "older report's sid not picked"     "$out" "session=$UUID_OLD"
assert_not_contains "other window's report not picked"  "$out" "session=$UUID_FRESH"
assert_contains "workdir resolves from spawn-prompt cache" "$out" "workdir=$WORKDIR"
assert_contains "transcript path resolved under the slugged project dir" \
                "$out" "jsonl=$PROJ_DIR/$UUID_REPORT.jsonl"

# ---- Test 2: `session-id: unknown` reports are skipped ------------------

echo '=== reports with session-id: unknown fall through ==='
mkreport "proj_2026-06-10_unknown_x.md" "$WIN" "unknown" "2026-06-10 14:00"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" --dry-run 2>&1)
rc=$?
assert_eq       "dry-run exits 0"                          "$rc" "0"
assert_contains "skips unknown, picks next matching report" "$out" "session=$UUID_REPORT"
rm -f "$FAKE_NEXUS/reports/proj_2026-06-10_unknown_x.md"

# ---- Test 2b: report read rides the shared frontmatter reader -----------
# The resolver reads report frontmatter via _fm_lib.sh:_fm_get (#405 P2
# follow-up), which accepts a fence line with trailing whitespace
# (`^---[[:space:]]*$`). The hand-rolled awk it replaced required an
# EXACT `---` and silently skipped such a report. ng report-init always
# writes bare fences, so this only surfaces on hand-edited reports —
# but the acceptance is the intended unification with every other
# frontmatter consumer, so pin it.

echo '=== lenient fence (trailing ws) resolves via the shared reader ==='
UUID_LENIENT="66666666-6666-6666-6666-666666666666"
echo '{}' > "$PROJ_DIR/$UUID_LENIENT.jsonl"
touch -d "2026-06-01 09:00" "$PROJ_DIR/$UUID_LENIENT.jsonl"
{
    printf -- '---   \n'   # opening fence with trailing spaces
    printf 'project: proj\ndate: 2026-06-10\nsession-id: %s\nwindow: %s\nstatus: done\n' "$UUID_LENIENT" "$WIN"
    printf -- '---\n\n# body\n'
} > "$FAKE_NEXUS/reports/proj_2026-06-10_lenient_x.md"
touch -d "2026-06-10 16:00" "$FAKE_NEXUS/reports/proj_2026-06-10_lenient_x.md"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" --dry-run 2>&1)
rc=$?
assert_eq       "dry-run exits 0"                              "$rc" "0"
assert_contains "lenient-fence report resolves (shared reader)" "$out" "session=$UUID_LENIENT"
rm -f "$FAKE_NEXUS/reports/proj_2026-06-10_lenient_x.md" "$PROJ_DIR/$UUID_LENIENT.jsonl"

# ---- Test 3: window-close action-log event ------------------------------

echo '=== window-close action-log event resolves sid + workdir ==='
rm -f "$FAKE_NEXUS"/reports/*.md "$CACHE"
ALOG="$FAKE_NEXUS/monitor/.state/action-log.jsonl"
cat > "$ALOG" <<EOF
{"ts":"2026-06-09T10:00:00-07:00","agent":"monitor","event":"window-close","window":"other-win","workdir":"/nope","session-id":"$UUID_FRESH"}
{"ts":"2026-06-10T10:00:00-07:00","agent":"monitor","event":"window-close","window":"$WIN","workdir":"$WORKDIR","session-id":"$UUID_CLOSE"}
EOF
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" --dry-run 2>&1)
rc=$?
assert_eq       "dry-run exits 0"                     "$rc" "0"
assert_contains "sid from window-close event"         "$out" "session=$UUID_CLOSE"
assert_contains "workdir from window-close event"     "$out" "workdir=$WORKDIR"

# ---- Test 4: spawn event workdir + freshest-jsonl sid fallback ----------

echo '=== spawn-event workdir + freshest project-dir jsonl as last resort ==='
cat > "$ALOG" <<EOF
{"ts":"2026-06-10T09:00:00-07:00","agent":"monitor","event":"spawn","window":"$WIN","workdir":"$WORKDIR"}
EOF
touch "$PROJ_DIR/$UUID_FRESH.jsonl"   # newest transcript in the project dir
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" --dry-run 2>&1)
rc=$?
assert_eq       "dry-run exits 0"                  "$rc" "0"
assert_contains "workdir from spawn event"         "$out" "workdir=$WORKDIR"
assert_contains "sid from freshest project jsonl"  "$out" "session=$UUID_FRESH"

# ---- Test 5: live-pane workdir resolution -------------------------------

echo '=== live pane #{pane_current_path} outranks file sources ==='
out=$(STUB_TMUX_PANE_PATH="$WORKDIR" "$SCRIPT" --resume "$WIN" --dry-run 2>&1)
rc=$?
assert_eq       "dry-run exits 0"             "$rc" "0"
assert_contains "workdir from live pane path" "$out" "workdir=$WORKDIR"

# ---- Test 6: explicit session-id override -------------------------------

echo '=== explicit UUID override ==='
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$UUID_REPORT" -n "$WIN" -c "$WORKDIR" --dry-run 2>&1)
rc=$?
assert_eq       "dry-run exits 0"            "$rc" "0"
assert_contains "explicit sid honoured"      "$out" "session=$UUID_REPORT"
assert_contains "explicit -c honoured"       "$out" "workdir=$WORKDIR"

echo '=== explicit UUID without -n fails loud ==='
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$UUID_REPORT" --dry-run 2>&1)
rc=$?
assert_eq       "exit 5 on UUID without -n"  "$rc" "5"
assert_contains "stderr explains -n is required" "$out" "needs -n <window-name>"

# ---- Test 7: fail-loud paths --------------------------------------------

echo '=== unresolvable workdir → exit 12 ==='
rm -f "$ALOG" "$CACHE"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" --dry-run 2>&1)
rc=$?
assert_eq       "exit 12 when no workdir source"  "$rc" "12"
assert_contains "stderr names the sources tried"  "$out" "cannot resolve a workdir"
assert_contains "stderr suggests -c"              "$out" "Pass -c <workdir> explicitly"

echo '=== unresolvable session-id → exit 11 ==='
EMPTY_WORKDIR="$FAKE_NEXUS/work/empty-proj"
mkdir -p "$EMPTY_WORKDIR"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" -c "$EMPTY_WORKDIR" --dry-run 2>&1)
rc=$?
assert_eq       "exit 11 when no session source"   "$rc" "11"
assert_contains "stderr names the sources tried"   "$out" "cannot resolve a session-id"
assert_contains "stderr suggests explicit override" "$out" "Pass an explicit session-id"

echo '=== resolved sid whose transcript vanished → exit 11 ==='
mkreport "proj_2026-06-10_gone_x.md" "$WIN" "99999999-9999-9999-9999-999999999999" "2026-06-10 16:00"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" -c "$WORKDIR" --dry-run 2>&1)
rc=$?
assert_eq       "exit 11 on missing transcript"   "$rc" "11"
assert_contains "stderr names the expected jsonl" "$out" "session transcript not found"
rm -f "$FAKE_NEXUS/reports/proj_2026-06-10_gone_x.md"

echo '=== transcript under a different project slug → warn + continue ==='
OTHER_PROJ="$HOME/.claude/projects/-some-other-dir"
mkdir -p "$OTHER_PROJ"
UUID_DRIFT="55555555-5555-5555-5555-555555555555"
echo '{}' > "$OTHER_PROJ/$UUID_DRIFT.jsonl"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$UUID_DRIFT" -n "$WIN" -c "$WORKDIR" --dry-run 2>&1)
rc=$?
assert_eq       "exit 0 on slug drift"            "$rc" "0"
assert_contains "stderr warns about the mismatch" "$out" "workdir/session mismatch"
assert_contains "dry-run reports the found jsonl" "$out" "jsonl=$OTHER_PROJ/$UUID_DRIFT.jsonl"

echo '=== -p with --resume is refused ==='
echo task > "$WORK/p.txt"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" -p "$WORK/p.txt" --dry-run 2>&1)
rc=$?
assert_eq       "exit 5 on -p with --resume"  "$rc" "5"
assert_contains "stderr explains -p invalid"  "$out" "-p is not valid with --resume"

echo '=== --resume without a value is refused ==='
out=$("$SCRIPT" --resume 2>&1)
rc=$?
assert_eq       "exit 5 on bare --resume"     "$rc" "5"
assert_contains "stderr asks for a value"     "$out" "--resume requires a value"

# ---- Test 8: full resume spawn — launcher wiring + tmux options + anchors

echo '=== full resume: launcher env exports, settings, tmux options, anchors ==='
mkreport "proj_2026-06-10_full_x.md" "$WIN" "$UUID_REPORT" "2026-06-10 17:00"
printf -- '- Workdir: %s\n' "$WORKDIR" > "$CACHE"
: > "$STUB_LOG"
rm -f "$FAKE_NEXUS/monitor/.state/engagement-log.tsv"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" 2>&1)
rc=$?
# STUB_TMUX_INFO_RC=1 makes the resolver skip the pane-path source but
# also fails the server pre-flight → exit 8. Re-run with tmux "up" and
# a no-window list to exercise the spawn path.
assert_eq "tmux-down resume exits 8" "$rc" "8"
assert_contains "stderr names the tmux precondition" "$out" "no tmux server running"

: > "$STUB_LOG"
out=$("$SCRIPT" --resume "$WIN" -c "$WORKDIR" 2>&1)
rc=$?
assert_eq       "resume exits 0"                      "$rc" "0"
assert_contains "stderr advertises the resume"        "$out" "resumed: window=$WIN session=$UUID_REPORT workdir=$WORKDIR"
assert_contains "stderr advertises the settings file" "$out" "settings=$FAKE_NEXUS/monitor/worker-settings.json"

log_contents=$(cat "$STUB_LOG")
assert_contains "tmux new-window captures @id with -c workdir" "$log_contents" "tmux new-window -P -F #{window_id} -d -n $WIN -c $WORKDIR"
assert_contains "remain-on-exit set on @id"   "$log_contents" "set-window-option -t @9 remain-on-exit on"
assert_contains "automatic-rename off on @id" "$log_contents" "set-window-option -t @9 automatic-rename off"
assert_contains "allow-rename off on @id"     "$log_contents" "set-window-option -t @9 allow-rename off"
assert_contains "launcher sent to the @id pane" "$log_contents" "send-keys -t @9"
assert_contains "lifecycle spawn event logged with mode=resume" "$log_contents" \
                "ng log-action monitor --event spawn --extra window=$WIN --extra workdir=$WORKDIR --extra mode=resume --extra session-id=$UUID_REPORT"

ELOG="$FAKE_NEXUS/monitor/.state/engagement-log.tsv"
if [[ -f "$ELOG" ]] && grep -qF $'res-win\t' "$ELOG"; then
    printf '  PASS: engagement-log row seeded on resume\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: engagement-log row missing for %s\n' "$WIN" >&2
    FAIL=$(( FAIL + 1 ))
fi

launcher_files=( "$SPAWN_TMP"/spawn-launcher-$WIN.*.sh )
if [[ -e "${launcher_files[0]}" ]]; then
    launcher_body=$(cat "${launcher_files[@]}")
    # THE bug this mode exists to fix: a hand-rolled resume lost these
    # two exports and every worker-settings hook failed with
    # "/monitor/worker-heartbeat.sh: not found".
    assert_contains "launcher exports NEXUS_ROOT"          "$launcher_body" "export NEXUS_ROOT=\"$FAKE_NEXUS\""
    assert_contains "launcher exports NEXUS_WORKER_WINDOW" "$launcher_body" "export NEXUS_WORKER_WINDOW=\"$WIN\""
    assert_contains "launcher pins cwd"                    "$launcher_body" "cd \"$WORKDIR\" || exit 1"
    assert_contains "launcher passes --settings"           "$launcher_body" "--settings $FAKE_NEXUS/monitor/worker-settings.json"
    assert_contains "launcher passes --dangerously-skip-permissions" "$launcher_body" "--dangerously-skip-permissions"
    assert_contains "launcher resumes the resolved session" "$launcher_body" "--resume \"$UUID_REPORT\""
    assert_contains "launcher suppresses the resume picker (minutes)" "$launcher_body" "CLAUDE_CODE_RESUME_THRESHOLD_MINUTES"
    assert_contains "launcher suppresses the resume picker (tokens)"  "$launcher_body" "CLAUDE_CODE_RESUME_TOKEN_THRESHOLD"
    assert_contains "launcher uses the resolved CLAUDE_BIN" "$launcher_body" "$FAKE_NEXUS/node_modules/.bin/claude"
    assert_not_contains "launcher has no composed prompt"   "$launcher_body" "FLOOR_MARKER"
    rm -f "${launcher_files[@]}"
else
    printf '  FAIL: resume launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 9: same-name window handling ----------------------------------

echo '=== existing window with DEAD pane is killed + recreated ==='
: > "$STUB_LOG"
out=$(STUB_TMUX_WINDOWS="$WIN" STUB_TMUX_PANE_DEAD=1 STUB_TMUX_PANE_PATH="$WORKDIR" \
      "$SCRIPT" --resume "$WIN" 2>&1)
rc=$?
assert_eq       "resume over dead pane exits 0"  "$rc" "0"
log_contents=$(cat "$STUB_LOG")
assert_contains "dead window killed first (by @id)" "$log_contents" "tmux kill-window -t @9"
assert_contains "window recreated"           "$log_contents" "tmux new-window -P -F #{window_id} -d -n $WIN"
rm -f "$SPAWN_TMP"/spawn-launcher-$WIN.*.sh

echo '=== existing window with LIVE pane is refused without --replace ==='
: > "$STUB_LOG"
out=$(STUB_TMUX_WINDOWS="$WIN" STUB_TMUX_PANE_DEAD=0 STUB_TMUX_PANE_PATH="$WORKDIR" \
      "$SCRIPT" --resume "$WIN" 2>&1)
rc=$?
assert_eq       "exit 13 on live pane"            "$rc" "13"
assert_contains "stderr suggests paste-or-replace" "$out" "pass --replace"
log_contents=$(cat "$STUB_LOG")
assert_not_contains "live window NOT killed"  "$log_contents" "tmux kill-window"

echo '=== --replace kills the live pane and recreates ==='
: > "$STUB_LOG"
out=$(STUB_TMUX_WINDOWS="$WIN" STUB_TMUX_PANE_DEAD=0 STUB_TMUX_PANE_PATH="$WORKDIR" \
      "$SCRIPT" --resume "$WIN" --replace 2>&1)
rc=$?
assert_eq       "resume --replace exits 0"  "$rc" "0"
log_contents=$(cat "$STUB_LOG")
assert_contains "live window killed under --replace (by @id)" "$log_contents" "tmux kill-window -t @9"
assert_contains "window recreated"                   "$log_contents" "tmux new-window -P -F #{window_id} -d -n $WIN"
rm -f "$SPAWN_TMP"/spawn-launcher-$WIN.*.sh

# ---- Test 10: continuation nudge (busy-at-death workers) ----------------
#
# `claude --resume` does NOT restart an interrupted turn. When the
# window's last heartbeat says the worker was mid-turn (busy /
# user_prompt) or a pending-tool record survives, the launcher must
# pass a continuation prompt as claude's trailing arg; idle workers
# must NOT get one (it would inject a phantom user turn).

NUDGE_MARKER="interrupted mid-task"
HB_DIR="$FAKE_NEXUS/monitor/.state/heartbeat"
PT_DIR="$FAKE_NEXUS/monitor/.state/pending-tool"
mkdir -p "$HB_DIR" "$PT_DIR"

_resume_launcher_body() {  # spawn, capture launcher body, clean up
    : > "$STUB_LOG"
    "$SCRIPT" --resume "$WIN" -c "$WORKDIR" "$@" >/dev/null 2>&1
    local files=( "$SPAWN_TMP"/spawn-launcher-$WIN.*.sh )
    [[ -e "${files[0]}" ]] || { echo "NO-LAUNCHER"; return; }
    cat "${files[@]}"
    rm -f "${files[@]}"
}

echo '=== heartbeat busy → continuation nudge in the launcher ==='
printf '{"state":"busy","last_activity":1765400000,"window":"%s"}\n' "$WIN" > "$HB_DIR/$WIN.json"
body=$(_resume_launcher_body)
assert_contains "busy heartbeat adds the nudge"      "$body" "$NUDGE_MARKER"
assert_contains "nudge rides after --resume <sid>"   "$body" "--resume \"$UUID_REPORT\" \""

echo '=== heartbeat idle_prompt → no nudge ==='
printf '{"state":"idle_prompt","last_activity":1765400000,"last_turn_end":1765400000,"window":"%s"}\n' "$WIN" > "$HB_DIR/$WIN.json"
body=$(_resume_launcher_body)
assert_not_contains "idle heartbeat adds no nudge"   "$body" "$NUDGE_MARKER"

echo '=== pending-tool record → nudge even with idle heartbeat ==='
printf '{"tool":"Bash","ts":1765400000}\n' > "$PT_DIR/$WIN.json"
body=$(_resume_launcher_body)
assert_contains "pending-tool record adds the nudge" "$body" "$NUDGE_MARKER"
rm -f "$PT_DIR/$WIN.json"

echo '=== --no-nudge suppresses a busy nudge; --nudge forces an idle one ==='
printf '{"state":"busy","last_activity":1765400000,"window":"%s"}\n' "$WIN" > "$HB_DIR/$WIN.json"
body=$(_resume_launcher_body --no-nudge)
assert_not_contains "--no-nudge overrides busy"      "$body" "$NUDGE_MARKER"
printf '{"state":"idle_prompt","last_activity":1765400000,"window":"%s"}\n' "$HB_DIR/$WIN.json" > "$HB_DIR/$WIN.json"
body=$(_resume_launcher_body --nudge)
assert_contains "--nudge forces on idle"             "$body" "$NUDGE_MARKER"

echo '=== dry-run reports the nudge decision ==='
printf '{"state":"busy","last_activity":1765400000,"window":"%s"}\n' "$WIN" > "$HB_DIR/$WIN.json"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" -c "$WORKDIR" --dry-run 2>&1)
assert_contains "dry-run shows nudge=on for busy"    "$out" "nudge=on (heartbeat-busy)"
rm -f "$HB_DIR/$WIN.json"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$WIN" -c "$WORKDIR" --dry-run 2>&1)
assert_contains "dry-run shows nudge=off when no heartbeat" "$out" "nudge=off (heartbeat-absent)"

# ---- Test 11: fresh-spawn mode is unaffected ----------------------------

echo '=== fresh mode still works (control) ==='
out=$("$SCRIPT" -n control-win -c "$WORKDIR" -p "$WORK/p.txt" --print-prompt 2>&1)
rc=$?
assert_eq       "fresh --print-prompt exits 0"  "$rc" "0"
assert_contains "fresh prompt carries the floor" "$out" "FLOOR_MARKER"

# ---- Test 12: coordinator-exclusion rule (your-org/your-nexus#206) -----
#
# Incident class: a worker spawned with -c <nexus-root> shares the
# coordinator's Claude project slug, and the freshest-jsonl fallback
# resolved its window to the ORCHESTRATOR's pinned session — the
# recovery then ran `claude --resume <orchestrator-sid>` into a worker
# window, i.e. a duplicate orchestrator. The resolver must (a) never
# return the pinned sid for a non-coordinator window from ANY source,
# (b) refuse freshest-jsonl recency outright under the shared slug,
# (c) resolve via per-window records (heartbeat / spawn-event stamp)
# instead, and (d) leave the coordinator window's own resolution
# untouched.

echo '=== your-nexus#206: shared-slug recency REFUSED for a worker window ==='
unset MONITOR_TARGET 2>/dev/null || true
UUID_ORCH="aaaaaaa1-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
UUID_WKR="bbbbbbb1-bbbb-4bbb-8bbb-bbbbbbbbbbb1"
UUID_WKR2="ccccccc1-cccc-4ccc-8ccc-ccccccccccc1"
ROOT_SLUG=$(printf '%s' "$FAKE_NEXUS" | sed 's|[^a-zA-Z0-9]|-|g')
ROOT_PROJ="$HOME/.claude/projects/$ROOT_SLUG"
PIN_FILE="$FAKE_NEXUS/monitor/.state/orchestrator-session-id"
mkdir -p "$ROOT_PROJ"
for u in "$UUID_WKR" "$UUID_WKR2"; do
    echo '{}' > "$ROOT_PROJ/$u.jsonl"
    touch -d "2026-06-01 09:00" "$ROOT_PROJ/$u.jsonl"
done
echo '{}' > "$ROOT_PROJ/$UUID_ORCH.jsonl"   # freshest jsonl = the orchestrator's
printf '%s\n' "$UUID_ORCH" > "$PIN_FILE"
rm -f "$ALOG"

out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume wkr-root -c "$FAKE_NEXUS" --dry-run 2>&1)
rc=$?
assert_eq           "exit 11 — recency under the shared slug refused" "$rc" "11"
assert_contains     "stderr explains the shared-slug refusal"  "$out" "shares the coordinator's project slug"
assert_not_contains "the orchestrator sid is never resolved"   "$out" "session=$UUID_ORCH"

echo '=== your-nexus#206: shared-slug refusal holds even with NO pin ==='
rm -f "$PIN_FILE"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume wkr-root -c "$FAKE_NEXUS" --dry-run 2>&1)
rc=$?
assert_eq       "exit 11 without a pin too"                "$rc" "11"
assert_contains "stderr still names the shared-slug rule"  "$out" "shares the coordinator's project slug"
printf '%s\n' "$UUID_ORCH" > "$PIN_FILE"

echo '=== your-nexus#206: heartbeat session_id resolves a shared-slug worker ==='
printf '{"state":"busy","last_activity":1765400000,"session_id":"%s","window":"wkr-root"}\n' \
    "$UUID_WKR" > "$HB_DIR/wkr-root.json"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume wkr-root -c "$FAKE_NEXUS" --dry-run 2>&1)
rc=$?
assert_eq       "exit 0 via the heartbeat source"        "$rc" "0"
assert_contains "worker resolves to ITS OWN session"     "$out" "session=$UUID_WKR"
rm -f "$HB_DIR/wkr-root.json"

echo '=== your-nexus#206: spawn-event session-id stamp resolves a shared-slug worker ==='
cat > "$ALOG" <<EOF
{"ts":"2026-06-11T10:00:00-07:00","agent":"monitor","event":"spawn","window":"wkr-root","workdir":"$FAKE_NEXUS","session-id":"$UUID_WKR2"}
EOF
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume wkr-root -c "$FAKE_NEXUS" --dry-run 2>&1)
rc=$?
assert_eq       "exit 0 via the spawn-event stamp"       "$rc" "0"
assert_contains "worker resolves to its stamped session" "$out" "session=$UUID_WKR2"
rm -f "$ALOG"

echo '=== your-nexus#206: report frontmatter carrying the PINNED sid is skipped ==='
mkreport "proj_2026-06-11_leak_x.md" "wleak" "$UUID_ORCH" "2026-06-11 10:00"
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume wleak -c "$WORKDIR" --dry-run 2>&1)
rc=$?
assert_eq           "exit 0 — falls through past the leaked report" "$rc" "0"
assert_contains     "stderr flags the skipped source"    "$out" "names the pinned ORCHESTRATOR session"
assert_contains     "falls through to the private-slug freshest jsonl" "$out" "session=$UUID_FRESH"
assert_not_contains "never the orchestrator sid"         "$out" "session=$UUID_ORCH"
rm -f "$FAKE_NEXUS/reports/proj_2026-06-11_leak_x.md"

echo '=== your-nexus#206: the coordinator window itself still resolves to the pin ==='
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume orchestrator -c "$FAKE_NEXUS" --dry-run 2>&1)
rc=$?
assert_eq       "exit 0 for the coordinator target"           "$rc" "0"
assert_contains "coordinator resolves to the pinned session"  "$out" "session=$UUID_ORCH"

echo '=== your-nexus#206: explicit pinned-sid override into a worker window → exit 14 ==='
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$UUID_ORCH" -n wkr-root -c "$FAKE_NEXUS" --dry-run 2>&1)
rc=$?
assert_eq       "exit 14 on the duplicate-orchestrator guard" "$rc" "14"
assert_contains "stderr names the hazard"                     "$out" "duplicate orchestrator"

echo '=== your-nexus#206: explicit pinned-sid override into the coordinator window is allowed ==='
out=$(STUB_TMUX_INFO_RC=1 "$SCRIPT" --resume "$UUID_ORCH" -n orchestrator -c "$FAKE_NEXUS" --dry-run 2>&1)
rc=$?
assert_eq       "exit 0 — coordinator override allowed"  "$rc" "0"
assert_contains "explicit sid honoured for coordinator"  "$out" "session=$UUID_ORCH"
rm -f "$PIN_FILE"

# ---- Test 13: fresh spawns stamp a deterministic --session-id -----------
#
# your-nexus#206 follow-through: a fresh worker records a generated
# session-id BOTH as claude's `--session-id` flag and as a
# `session-id=` extra on the spawn action-log event, so the resolver's
# spawn-event source can key on it from birth — no recency guessing.

echo '=== fresh spawn: --session-id flag + spawn-event stamp agree ==='
: > "$STUB_LOG"
echo task > "$WORK/p.txt"
out=$("$SCRIPT" -n stamp-win -c "$WORKDIR" -p "$WORK/p.txt" 2>&1)
rc=$?
assert_eq       "fresh spawn exits 0"                  "$rc" "0"
assert_contains "stderr advertises the session-id"     "$out" "session-id="
stamp_launchers=( "$SPAWN_TMP"/spawn-launcher-stamp-win.*.sh )
if [[ -e "${stamp_launchers[0]}" ]]; then
    stamp_body=$(cat "${stamp_launchers[@]}")
    assert_contains "launcher passes --session-id to claude" "$stamp_body" "--session-id "
    l_sid=$(sed -n 's/.*--session-id \([0-9a-f-]\{36\}\).*/\1/p' <<<"$stamp_body" | head -1)
    g_sid=$(sed -n 's/.*--extra session-id=\([0-9a-f-]\{36\}\).*/\1/p' "$STUB_LOG" | head -1)
    if [[ -n "$l_sid" && "$l_sid" == "$g_sid" ]]; then
        printf '  PASS: launcher flag and spawn-event stamp carry the same uuid (%s)\n' "$l_sid"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: launcher sid (%s) != spawn-event stamp (%s)\n' "$l_sid" "$g_sid" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    rm -f "${stamp_launchers[@]}"
else
    printf '  FAIL: fresh-spawn launcher tempfile not created for stamp-win\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
log_contents=$(cat "$STUB_LOG")
assert_contains "spawn action-log event carries the session-id extra" \
                "$log_contents" "--extra session-id="

# ---- summary ----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
