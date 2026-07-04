#!/usr/bin/env bash
# Unit tests for monitor/spawn-worker.sh prompt composition.
#
# Run: bash monitor/watcher/test-spawn-worker.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build a fake NEXUS_ROOT containing only the files
# spawn-worker.sh needs (the worker-defaults SKILL.md with a
# `## Worker floor` section), then invoke the helper with
# `--print-prompt` to compose the prompt without touching tmux.
# Assert on the emitted prompt body.

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

# Scope spawn-worker.sh's launcher/prompt tempfiles (it honours
# TMPDIR) to a per-test dir: the launcher-body assertions below glob
# for spawn-launcher-<window>.*.sh, and against global /tmp a
# concurrent suite run's identically-named files satisfy the glob —
# then either run's `rm -f` deletes the other's file mid-assertion
# ("launcher tempfile not created", reproduced under 3 parallel
# suites). Exported so every $SCRIPT invocation inherits it.
SPAWN_TMP="$WORK/spawn-tmp"
mkdir -p "$SPAWN_TMP"
export TMPDIR="$SPAWN_TMP"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" \
         "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports"
# spawn-worker.sh resolves NEXUS_ROOT from its own location
# (`$(dirname "$0")/..`), so we drop a copy of the real script into
# the fake nexus.
cp "$SCRIPT_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh"
SCRIPT="$FAKE_NEXUS/monitor/spawn-worker.sh"

# spawn-worker.sh sources monitor/_claude-bin.sh to resolve $CLAUDE_BIN.
# Drop a copy + a stub claude under node_modules/.bin/ so the resolver
# finds the project-local path (mirrors the post-install layout).
cp "$_test_dir/../_claude-bin.sh" "$FAKE_NEXUS/monitor/_claude-bin.sh"
# spawn-worker.sh also sources monitor/_tmux-window.sh for robust
# window-id targeting (issue #323); the fake nexus needs it too.
cp "$_test_dir/../_tmux-window.sh" "$FAKE_NEXUS/monitor/_tmux-window.sh"
# And the shared frontmatter reader (#405 P2) for report resolution.
cp "$_test_dir/../_fm_lib.sh" "$FAKE_NEXUS/monitor/_fm_lib.sh"
mkdir -p "$FAKE_NEXUS/node_modules/.bin"
cat > "$FAKE_NEXUS/node_modules/.bin/claude" <<'CLAUDE_STUB'
#!/bin/bash
echo "stub-claude: $*"
CLAUDE_STUB
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"

# Minimal worker-defaults SKILL.md with a recognisable floor body.
cat > "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
---
description: stub
---

# nexus.worker-defaults

## Preamble (not the floor — should not be injected)

This should not appear in the composed prompt.

## Worker floor

- Always greet the bot.
- Never push --no-verify.
- FLOOR_MARKER_TOKEN_a78b21

## After-floor section (should not be injected)

Trailing content; the awk extractor stops at the next `## ` H2.
EOF

WORKDIR="$FAKE_NEXUS"
PROMPT_FILE="$WORK/task-prompt.txt"
cat > "$PROMPT_FILE" <<'EOF'
TASK_PROMPT_TOKEN_44ee0a

Do the thing.
EOF

# Minimal worker-settings.json that spawn-worker.sh requires (exit 10
# without it). Tests that exercise the spawn path inherit this file;
# the "missing-file → exit 10" regression test removes it explicitly.
cat > "$FAKE_NEXUS/monitor/worker-settings.json" <<'EOF'
{
  "skipDangerousModePermissionPrompt": true,
  "hooks": {}
}
EOF

# ---- Test 1: --print-prompt happy path (no -r) ------------------------

echo '=== --print-prompt without -r emits floor + task only ==='
out=$("$SCRIPT" -n test-win -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 on happy path"           "$rc" "0"
assert_contains  "prompt has Worker environment"  "$out" "## Worker environment"
assert_contains  "prompt has Workdir line"        "$out" "- Workdir: $WORKDIR"
assert_contains  "prompt has Reports dir line"    "$out" "- Reports dir: $FAKE_NEXUS/reports"
assert_contains  "prompt embeds the floor body"   "$out" "FLOOR_MARKER_TOKEN_a78b21"
assert_contains  "prompt embeds the task prompt"  "$out" "TASK_PROMPT_TOKEN_44ee0a"
assert_not_contains "prompt skips the after-floor section" "$out" "Trailing content"
assert_not_contains "prompt has no Prior-context section"  "$out" "## Prior context"

# ---- Test 2: -r <absolute report path> injects Prior context ----------

REPORT="$FAKE_NEXUS/reports/prior-report.md"
cat > "$REPORT" <<'EOF'
---
project: nexus
date: 2026-05-12
---

# Prior worker's report

## Summary

PRIOR_REPORT_BODY_TOKEN_9c12f3

## How to Resume

Continue from commit 0xCAFEBABE.
EOF

echo '=== -r <absolute path> injects Prior context section ==='
out=$("$SCRIPT" -n test-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        -r "$REPORT" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -r absolute path"   "$rc" "0"
assert_contains  "prompt has Prior context header" "$out" "## Prior context"
assert_contains  "prompt embeds the prior body"    "$out" "PRIOR_REPORT_BODY_TOKEN_9c12f3"
assert_contains  "prompt cites the report path"    "$out" "Path: $REPORT"
assert_contains  "prompt still has the floor"      "$out" "FLOOR_MARKER_TOKEN_a78b21"
assert_contains  "prompt still has the task"       "$out" "TASK_PROMPT_TOKEN_44ee0a"

# Order: env → prior → floor → task. Verify Prior context appears
# between Workdir and the floor marker.
env_line=$(grep -n '## Worker environment' <<<"$out" | head -1 | cut -d: -f1)
prior_line=$(grep -n '## Prior context' <<<"$out" | head -1 | cut -d: -f1)
floor_line=$(grep -n 'FLOOR_MARKER_TOKEN_a78b21' <<<"$out" | head -1 | cut -d: -f1)
task_line=$(grep -n 'TASK_PROMPT_TOKEN_44ee0a' <<<"$out" | head -1 | cut -d: -f1)
if [[ -n "$env_line" && -n "$prior_line" && -n "$floor_line" && -n "$task_line" ]] \
   && (( env_line < prior_line && prior_line < floor_line && floor_line < task_line )); then
    printf '  PASS: section ordering env<prior<floor<task\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: section ordering wrong (env=%s prior=%s floor=%s task=%s)\n' \
        "$env_line" "$prior_line" "$floor_line" "$task_line" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 3: -r <relative-to-NEXUS_ROOT> resolves ---------------------

echo '=== -r <relative path> resolves against NEXUS_ROOT ==='
out=$("$SCRIPT" -n test-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        -r "reports/prior-report.md" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -r relative path"      "$rc" "0"
assert_contains  "prompt embeds the prior body"      "$out" "PRIOR_REPORT_BODY_TOKEN_9c12f3"

# ---- Test 4: -r missing path → exit 9 ---------------------------------

echo '=== -r <missing path> → exit 9 ==='
out=$("$SCRIPT" -n test-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        -r "$WORK/nope-report.md" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 9 on missing prior-report"    "$rc" "9"
assert_contains  "stderr names the missing report"   "$out" \
                 "prior-report not readable"

# ---- Test 5: spawn issues set-window-option remain-on-exit + seeds anchors
#
# Issue #72 retain-persistence + lifecycle-anchor changes. We stub tmux
# AND ng so the spawn-worker.sh execution path is exercised end-to-end
# without actually touching tmux or the file system's action log. The
# stub records every invocation to a log file; we then assert the
# expected calls appear.

echo '=== spawn issues tmux set-window-option remain-on-exit on ==='

STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
STUB_LOG="$WORK/tmux-calls.log"
: > "$STUB_LOG"

cat > "$STUB_BIN/tmux" <<STUB
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$STUB_LOG"
case "\$1" in
    info) exit 0 ;;
    list-windows) exit 0 ;;  # no windows → collision check passes
    # spawn-worker captures the window id from new-window -P and targets
    # every later op by that @id (#323). Emit a deterministic fake id so
    # the assertions below can match the -t @7 form. (No backticks in
    # this comment: the heredoc is unquoted, so they would run as a
    # command substitution at stub-creation time.)
    new-window) echo '@7'; exit 0 ;;
    set-window-option) exit 0 ;;
    send-keys) exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/tmux"

# Stub ng so the spawn-time `log-action spawn` call doesn't blow up
# on missing nexus.yml in the fake nexus root.
mkdir -p "$FAKE_NEXUS/monitor"
cat > "$FAKE_NEXUS/monitor/ng" <<NGSTUB
#!/bin/bash
printf '%s\n' "ng \$*" >> "$STUB_LOG"
exit 0
NGSTUB
chmod +x "$FAKE_NEXUS/monitor/ng"

# Invoke the real spawn-worker.sh with stubs on PATH.
out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n integ-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq        "spawn exits 0"                                   "$rc" "0"
log_contents=$(cat "$STUB_LOG")
assert_contains "tmux new-window invoked"                "$log_contents" "tmux new-window"
assert_contains "remain-on-exit set on new window"       "$log_contents" \
                 "set-window-option -t @7 remain-on-exit on"
# Phantom-•bell fix: spawn must disable tmux auto-rename + OSC-driven
# rename on the new window so dead worker panes don't get retitled
# (to `•bell`, `bash`, etc.) and pollute the watcher's tmux snapshot.
# Both knobs are required: automatic-rename governs tmux's own
# pane_current_command + dead-state rename, allow-rename governs
# whether the inner pane is permitted to set the title via OSC.
assert_contains "automatic-rename disabled on new window" "$log_contents" \
                 "set-window-option -t @7 automatic-rename off"
assert_contains "allow-rename disabled on new window"     "$log_contents" \
                 "set-window-option -t @7 allow-rename off"
assert_contains "ng log-action spawn fired"              "$log_contents" \
                 "ng log-action monitor --event spawn"
# Engagement-log row should have been seeded directly.
ELOG="$FAKE_NEXUS/monitor/.state/engagement-log.tsv"
if [[ -f "$ELOG" ]] && grep -qF $'integ-win\t' "$ELOG"; then
    printf '  PASS: engagement-log row seeded\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: engagement-log row missing for integ-win\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# Spawn-prompt cache should have been written (PR #131 follow-up,
# tier-3/4 subject-issue discovery fallback). Composition includes
# the worker floor + task body, so the cached file content should
# contain both a Worker environment header and the task prompt.
SPAWN_CACHE="$FAKE_NEXUS/monitor/.state/spawn-prompts/integ-win.txt"
if [[ -f "$SPAWN_CACHE" ]]; then
    printf '  PASS: spawn-prompt cache file written (%s)\n' "$SPAWN_CACHE"; PASS=$(( PASS + 1 ))
    cache_body=$(<"$SPAWN_CACHE")
    assert_contains "cache carries Worker environment header"     "$cache_body" "## Worker environment"
    assert_contains "cache carries task prompt body"               "$cache_body" "TASK_PROMPT_TOKEN_44ee0a"
else
    printf '  FAIL: spawn-prompt cache missing at %s\n' "$SPAWN_CACHE" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Change 1: ordinary worker is NOT pre-warned of a skeptic ----------
# The env-header must carry NO `- Skeptic mode:` / `- Skeptic role:` line
# for an ordinary worker, even one spawned with --skeptic require — the
# worker learns of the skeptic only at wrap-up. Asserted on the env
# header specifically (the floor's role-pointer bullet legitimately names
# `Skeptic role:`, so scope the check to the lines before the first `---`).
echo '=== Change 1: ordinary worker env header carries no skeptic line ==='
ord_out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n ord-win -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic require --print-prompt 2>/dev/null)
ord_env=$(printf '%s\n' "$ord_out" | sed -n '1,/^---$/p')
assert_not_contains "ordinary env header has no '- Skeptic mode:' line" "$ord_env" "- Skeptic mode:"
assert_not_contains "ordinary env header has no '- Skeptic role:' line" "$ord_env" "- Skeptic role:"

# ---- Change 1/2: a --skeptic-role spawn DOES carry the role line + the
#      skeptic_orig provenance (defaults to target) -----------------------
echo '=== role spawn: env header role line + skeptic_orig provenance ==='
role_out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n role-win -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic-role --skeptic-target orig-task --print-prompt 2>/dev/null)
role_env=$(printf '%s\n' "$role_out" | sed -n '1,/^---$/p')
assert_contains "role spawn env header carries 'Skeptic role: YES'" "$role_env" "Skeptic role: YES"

# Full spawn (with stubs) writes provenance; skeptic_orig defaults to the
# target when --skeptic-orig is omitted, and is the threaded root when set.
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n role-prov -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic-role --skeptic-target orig-task >/dev/null 2>&1
ROLE_PROV="$FAKE_NEXUS/monitor/.state/windows/role-prov.json"
if [[ -f "$ROLE_PROV" ]]; then
    assert_eq "skeptic_orig defaults to target" \
        "$(jq -r '.skeptic_orig' "$ROLE_PROV")" "orig-task"
else
    printf '  FAIL: role-prov provenance record missing at %s\n' "$ROLE_PROV" >&2
    FAIL=$(( FAIL + 1 ))
fi
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n role-prov2 -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic-role --skeptic-target sk-prior --skeptic-orig orig-task >/dev/null 2>&1
ROLE_PROV2="$FAKE_NEXUS/monitor/.state/windows/role-prov2.json"
if [[ -f "$ROLE_PROV2" ]]; then
    assert_eq "skeptic_orig threads the explicit chain root" \
        "$(jq -r '.skeptic_orig' "$ROLE_PROV2")" "orig-task"
else
    printf '  FAIL: role-prov2 provenance record missing at %s\n' "$ROLE_PROV2" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- skeptic-pending marker (RE-)established at skeptic spawn -----------
# A --skeptic-role spawn must (re-)create the skeptic-pending markers for
# the windows it reviews. This is what restores the retire-block + the
# parked-awaiting-skeptic exemption for a genuinely-spawned second pass
# (ng wrap-up's verdict path no longer re-asserts them speculatively — that
# was the marker leak). A FIRST-pass spawn writes pending/<target>; a
# RECURSIVE spawn (--skeptic-orig != target) writes BOTH pending/<target>
# and pending/<orig>.
echo '=== skeptic-role spawn (re-)establishes skeptic-pending markers ==='
SKPEND="$FAKE_NEXUS/monitor/.state/skeptic/pending"
if [[ -f "$SKPEND/orig-task" ]]; then
    printf '  PASS: first-pass spawn creates pending/<target>\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: first-pass spawn did NOT create %s\n' "$SKPEND/orig-task" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -f "$SKPEND/sk-prior" ]]; then
    printf '  PASS: recursive spawn creates pending/<target>\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: recursive spawn did NOT create %s\n' "$SKPEND/sk-prior" >&2
    FAIL=$(( FAIL + 1 ))
fi
# role-prov2 carried --skeptic-orig orig-task, so the orig marker exists too
# (role-prov's earlier spawn already created pending/orig-task; assert the
# recursive path keeps the chain root parked).
if [[ -f "$SKPEND/orig-task" ]]; then
    printf '  PASS: recursive spawn keeps pending/<orig> (chain root) parked\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: recursive spawn did NOT keep %s\n' "$SKPEND/orig-task" >&2
    FAIL=$(( FAIL + 1 ))
fi
# An ordinary (non-role) worker spawn must NOT create a skeptic-pending
# marker — the marker means "a skeptic is required or actively reviewing",
# not "a worker exists". (require-mode markers are written by ng wrap-up,
# not by the spawn.)
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n plain-no-mark -c "$WORKDIR" -p "$PROMPT_FILE" >/dev/null 2>&1
if [[ ! -f "$SKPEND/plain-no-mark" ]]; then
    printf '  PASS: ordinary spawn writes no skeptic-pending marker\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: ordinary spawn unexpectedly wrote %s\n' "$SKPEND/plain-no-mark" >&2
    FAIL=$(( FAIL + 1 ))
fi

# --print-prompt mode MUST NOT write the cache (it skips the spawn
# path entirely, by design — no window, no cache).
PRINT_CACHE_NAME="print-only-win"
PRINT_CACHE="$FAKE_NEXUS/monitor/.state/spawn-prompts/$PRINT_CACHE_NAME.txt"
rm -f "$PRINT_CACHE"
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n "$PRINT_CACHE_NAME" -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt >/dev/null 2>&1
if [[ ! -f "$PRINT_CACHE" ]]; then
    printf '  PASS: --print-prompt does NOT write spawn-prompt cache\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: --print-prompt unexpectedly wrote %s\n' "$PRINT_CACHE" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 6: launcher carries --settings <worker-settings.json> --------

echo '=== launcher invokes claude --settings $NEXUS_ROOT/monitor/worker-settings.json ==='
: > "$STUB_LOG"
out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n settings-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq "spawn exits 0 with settings file present" "$rc" "0"
assert_contains "spawn stderr advertises settings path" "$out" \
                "settings=$FAKE_NEXUS/monitor/worker-settings.json"
launcher_files=( "$SPAWN_TMP"/spawn-launcher-settings-win.*.sh )
if [[ -e "${launcher_files[0]}" ]]; then
    launcher_body=$(cat "${launcher_files[@]}")
    assert_contains "launcher carries --settings flag with the repo path" \
                    "$launcher_body" "--settings $FAKE_NEXUS/monitor/worker-settings.json"
    # Belt-and-braces: no tempfile name should leak through.
    if grep -qE -- "--settings /tmp/spawn-hooks-" <<<"$launcher_body"; then
        printf '  FAIL: launcher references a tempfile settings path (should be the repo file)\n' >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: launcher does NOT reference a tempfile settings path\n'
        PASS=$(( PASS + 1 ))
    fi
    rm -f "${launcher_files[@]}"
else
    printf '  FAIL: launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 7: missing worker-settings.json → exit 10 --------------------

echo '=== missing monitor/worker-settings.json → exit 10 ==='
# Move the settings file aside so the existence check fails. Restore
# it after the test so subsequent tests (loop-wrapper, default-shape)
# see a present file again.
mv "$FAKE_NEXUS/monitor/worker-settings.json" "$FAKE_NEXUS/monitor/worker-settings.json.bak"
out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n missing-settings-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq      "exit 10 when worker-settings.json absent"  "$rc" "10"
assert_contains "stderr names the missing settings file"  "$out" \
                "worker-settings.json missing"
mv "$FAKE_NEXUS/monitor/worker-settings.json.bak" "$FAKE_NEXUS/monitor/worker-settings.json"

# ---- Test 7b: shipped monitor/worker-settings.json carries the bypass flag ----

echo '=== shipped monitor/worker-settings.json sets skipDangerousModePermissionPrompt: true ==='
# Verifies the real file (not the test stub) carries the key that
# suppresses the bypass-permissions startup dialog. If a future edit
# drops the flag, fresh-worker-dir spawns regress to wedging on the
# dialog and case-D in _unstick.sh would have to come back.
REAL_SETTINGS="$_test_dir/../worker-settings.json"
if [[ -f "$REAL_SETTINGS" ]]; then
    if python3 -c "import json,sys; sys.exit(0 if json.load(open('$REAL_SETTINGS')).get('skipDangerousModePermissionPrompt') is True else 1)"; then
        printf '  PASS: shipped worker-settings.json sets skipDangerousModePermissionPrompt=true\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: shipped worker-settings.json missing skipDangerousModePermissionPrompt=true\n' >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # And it must be valid JSON top-to-bottom.
    if python3 -c "import json; json.load(open('$REAL_SETTINGS'))" 2>/dev/null; then
        printf '  PASS: shipped worker-settings.json parses as valid JSON\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: shipped worker-settings.json is not valid JSON\n' >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: shipped worker-settings.json not found at %s\n' "$REAL_SETTINGS" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 7c: the scancel + multi-push rules ride the JIT footgun hook ----
#
# B13 (your-org/your-nexus#236) required these two safety-grade rules to
# reach every worker. The worker-floor redesign moves them OUT of the
# always-injected prompt (where they diluted the task) and INTO the
# just-in-time footgun hook, which injects the reminder at the exact
# `git push` / `scancel --name` tool call. The rules still reach the
# worker — via `bash-footgun-patterns.conf` + `bash-footgun-guard.sh`,
# not the prompt. Assert their new home so a regression that drops them
# entirely still fails.

echo '=== scancel + multi-push safety rules live in the footgun conf/hook ==='
FOOTGUN_CONF="$_test_dir/../../monitor/bash-footgun-patterns.conf"
FOOTGUN_HOOK="$_test_dir/../../monitor/hooks/bash-footgun-guard.sh"
REAL_FLOOR_SKILL="$_test_dir/../../skills/nexus.worker-defaults/SKILL.md"
if [[ -f "$FOOTGUN_CONF" ]]; then
    conf_body=$(cat "$FOOTGUN_CONF")
    assert_contains "footgun conf pins each git push to its clone (git -C)" \
                    "$conf_body" "git -C <clone> push"
    assert_contains "footgun conf mandates scancel by job-id, not --name" \
                    "$conf_body" "scancel <jobid>"
    assert_contains "footgun conf matches the scancel --name over-match" \
                    "$conf_body" "scancel\b[^0-9]*--name"
else
    printf '  FAIL: bash-footgun-patterns.conf not found at %s\n' "$FOOTGUN_CONF" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -x "$FOOTGUN_HOOK" ]]; then
    printf '  PASS: bash-footgun-guard.sh present and executable\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bash-footgun-guard.sh missing or not executable at %s\n' "$FOOTGUN_HOOK" >&2
    FAIL=$(( FAIL + 1 ))
fi
# The redesign REMOVED these from the always-injected floor body — assert
# the slimming actually happened (guards against a silent revert that
# re-bloats the prompt).
if [[ -f "$REAL_FLOOR_SKILL" ]]; then
    floor_body=$(awk '/^## Worker floor$/{f=1;next} /^## /{f=0} f' "$REAL_FLOOR_SKILL")
    assert_not_contains "slim floor no longer inlines the git -C push rule" \
                    "$floor_body" "git -C <clone> push"
    assert_not_contains "slim floor no longer inlines the scancel rule" \
                    "$floor_body" "scancel <jobid>"
fi

# ---- Test 8: loop-wrapper opt-in switches the launcher shape -----------
#
# Issue #75. When MONITOR_RETAIN_USE_LOOP_WRAPPER=1, the launcher
# generated by spawn-worker.sh should `exec monitor/claude-loop.sh`
# instead of invoking claude directly. We don't run it (the test
# stubs tmux so nothing actually executes), only inspect the file.

echo '=== MONITOR_RETAIN_USE_LOOP_WRAPPER=1 ⇒ launcher invokes claude-loop.sh ==='

# Drop a stub claude-loop.sh next to the spawn-worker so its NEXUS_ROOT
# resolves to a real file. Content doesn't matter — the launcher just
# needs the path to exist for inspection assertions.
cat > "$FAKE_NEXUS/monitor/claude-loop.sh" <<'LOOPSTUB'
#!/usr/bin/env bash
echo "claude-loop-stub: $*"
LOOPSTUB
chmod +x "$FAKE_NEXUS/monitor/claude-loop.sh"

: > "$STUB_LOG"
out=$(MONITOR_RETAIN_USE_LOOP_WRAPPER=1 \
      PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n loop-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq      "spawn-with-loop exits 0"               "$rc"           "0"
assert_contains "spawn stderr advertises loop=on"       "$out"          "loop=on"
loop_launcher_files=( "$SPAWN_TMP"/spawn-launcher-loop-win.*.sh )
if [[ -e "${loop_launcher_files[0]}" ]]; then
    launcher_body=$(cat "${loop_launcher_files[@]}")
    assert_contains "launcher exec's claude-loop.sh"   "$launcher_body" "exec \"\$NEXUS_ROOT/monitor/claude-loop.sh\""
    assert_contains "launcher passes --window"         "$launcher_body" "--window \"loop-win\""
    assert_contains "launcher passes --prompt-file"    "$launcher_body" "--prompt-file"
    # remain-on-exit is still set (orthogonal): the loop wrapper does
    # respawns, but if it ever exits we still want pane history.
    loop_log_contents=$(cat "$STUB_LOG")
    assert_contains "remain-on-exit set on loop window" "$loop_log_contents" \
                    "set-window-option -t @7 remain-on-exit on"
    assert_contains "automatic-rename disabled on loop window" "$loop_log_contents" \
                    "set-window-option -t @7 automatic-rename off"
    assert_contains "allow-rename disabled on loop window"     "$loop_log_contents" \
                    "set-window-option -t @7 allow-rename off"
    rm -f "${loop_launcher_files[@]}"
else
    printf '  FAIL: loop launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# Default (no env, no config knob) should still emit the direct
# `claude --dangerously-skip-permissions` shape — back-compat.
echo '=== default (no opt-in) keeps the direct claude launcher shape ==='
: > "$STUB_LOG"
out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n direct-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq      "spawn-default exits 0"                 "$rc"           "0"
if [[ "$out" == *"loop=on"* ]]; then
    printf '  FAIL: default spawn announced loop=on (should be off)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: default spawn stderr does NOT advertise loop=on\n'
    PASS=$(( PASS + 1 ))
fi
direct_launcher_files=( "$SPAWN_TMP"/spawn-launcher-direct-win.*.sh )
if [[ -e "${direct_launcher_files[0]}" ]]; then
    launcher_body=$(cat "${direct_launcher_files[@]}")
    if grep -qF "claude-loop.sh" <<<"$launcher_body"; then
        printf '  FAIL: default launcher unexpectedly references claude-loop.sh\n' >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: default launcher invokes claude directly\n'
        PASS=$(( PASS + 1 ))
    fi
    # `$CLAUDE_BIN` resolves to the project-local install at write time,
    # so the launcher contains `"/abs/.../claude" --dangerously...`.
    if [[ "$launcher_body" =~ \"?[^\ ]*claude\"?\ --dangerously-skip-permissions ]]; then
        printf '  PASS: default launcher carries <CLAUDE_BIN> --dangerously-skip-permissions\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: default launcher missing <CLAUDE_BIN> --dangerously-skip-permissions in body=%q\n' "$launcher_body" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    rm -f "${direct_launcher_files[@]}"
else
    printf '  FAIL: direct launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 8b: --model threads into BOTH launcher shapes (issue #433) ----
#
# Opt-in per-worker model pin. With --model <id> the generated launcher
# must carry `--model "<id>"` — appended to the claude-loop.sh args in
# the loop shape, and to the direct claude invocation otherwise. With
# the flag omitted the launcher must carry NO --model token at all
# (default-off; the byte-identical guarantee is asserted on the
# invocation line here, full-file byte-diff was done at review time).

echo '=== --model <id> lands in the loop-shape launcher (value form) ==='
: > "$STUB_LOG"
out=$(MONITOR_RETAIN_USE_LOOP_WRAPPER=1 \
      PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n model-loop-win -c "$WORKDIR" -p "$PROMPT_FILE" \
      --model claude-fable-5 2>&1)
rc=$?
assert_eq       "spawn --model (loop shape) exits 0"     "$rc" "0"
model_loop_files=( "$SPAWN_TMP"/spawn-launcher-model-loop-win.*.sh )
if [[ -e "${model_loop_files[0]}" ]]; then
    launcher_body=$(cat "${model_loop_files[@]}")
    assert_contains "loop launcher execs claude-loop.sh"  "$launcher_body" \
                    "exec \"\$NEXUS_ROOT/monitor/claude-loop.sh\""
    assert_contains "loop launcher carries quoted --model" "$launcher_body" \
                    "--model \"claude-fable-5\""
    rm -f "${model_loop_files[@]}"
else
    printf '  FAIL: model loop launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== --model=<id> lands in the direct-shape launcher (= form) ==='
: > "$STUB_LOG"
out=$(PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n model-direct-win -c "$WORKDIR" -p "$PROMPT_FILE" \
      --model=claude-fable-5 2>&1)
rc=$?
assert_eq       "spawn --model= (direct shape) exits 0"  "$rc" "0"
model_direct_files=( "$SPAWN_TMP"/spawn-launcher-model-direct-win.*.sh )
if [[ -e "${model_direct_files[0]}" ]]; then
    launcher_body=$(cat "${model_direct_files[@]}")
    assert_contains "direct launcher carries quoted --model" "$launcher_body" \
                    "--dangerously-skip-permissions --model \"claude-fable-5\""
    rm -f "${model_direct_files[@]}"
else
    printf '  FAIL: model direct launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== no --model ⇒ launcher carries NO --model token (default-off) ==='
: > "$STUB_LOG"
out=$(PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n nomodel-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq       "spawn without --model exits 0"          "$rc" "0"
nomodel_files=( "$SPAWN_TMP"/spawn-launcher-nomodel-win.*.sh )
if [[ -e "${nomodel_files[0]}" ]]; then
    launcher_body=$(cat "${nomodel_files[@]}")
    assert_not_contains "default launcher has no --model" "$launcher_body" "--model"
    rm -f "${nomodel_files[@]}"
else
    printf '  FAIL: nomodel launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== bare --model (no value) ⇒ usage error, no silent default ==='
out=$(PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n bare-model-win -c "$WORKDIR" -p "$PROMPT_FILE" --model 2>&1)
rc=$?
assert_eq       "bare --model exits 5 (usage)"           "$rc" "5"
assert_contains "stderr names the missing model value"   "$out" \
                "--model requires a value"

# ---- Test 9: -c $NEXUS_ROOT emits root-cwd warning ---------------------
#
# Layered on top of the spawn safety floor: when the orchestrator
# passes the primary clone as the worker's cwd, spawn-worker.sh
# should warn on stderr AND inject a one-line note into the
# composed prompt. Subdirectories of NEXUS_ROOT (work/<project>,
# work/<project>-<task>) stay silent — the check is exact-equality
# only.

echo '=== -c $NEXUS_ROOT → root-cwd warning fires on stderr + in prompt ==='

# Symmetric harness: build a tmp worktree dir at $FAKE_NEXUS/work/
# foo so the negative case (warning silent on a worktree path) has
# an actual sibling-of-NEXUS_ROOT directory to point at.
mkdir -p "$FAKE_NEXUS/work/foo"

# (a) Warning fires when -c equals NEXUS_ROOT exactly.
out=$("$SCRIPT" -n root-cwd-win -c "$FAKE_NEXUS" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -c \$NEXUS_ROOT"            "$rc" "0"
assert_contains  "stderr carries root-cwd warning header" "$out" \
                 "spawn-worker.sh: warn: -c resolves to nexus primary clone"
assert_contains  "warning references the nexus primary clone path" "$out" "($FAKE_NEXUS)"
assert_contains  "warning points at skills/nexus.tmux-spawn"  "$out" \
                 "skills/nexus.tmux-spawn/SKILL.md \"secondary clones\""
assert_contains  "prompt injects the cwd nudge"            "$out" \
                 "Note: your cwd is the nexus primary clone"
assert_contains  "nudge mentions worktree command form"    "$out" \
                 "git worktree add"

# (b) Warning silent when -c is a subdirectory (worktree convention).
out=$("$SCRIPT" -n worktree-cwd-win -c "$FAKE_NEXUS/work/foo" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -c subdirectory"            "$rc" "0"
assert_not_contains "no root-cwd warning on a subdirectory" "$out" \
                 "spawn-worker.sh: warn: -c resolves to nexus primary clone"
assert_not_contains "no nudge injected into prompt on subdirectory" "$out" \
                 "Note: your cwd is the nexus primary clone"

# (c) Warning silent when -c is a symlink that resolves to a
# subdirectory of NEXUS_ROOT (defensive: cd "$WORKDIR" && pwd
# resolves symlinks, so symlink-to-worktree is fine).
ln -sfn "$FAKE_NEXUS/work/foo" "$WORK/foo-link"
out=$("$SCRIPT" -n symlink-cwd-win -c "$WORK/foo-link" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -c symlink-to-subdir"       "$rc" "0"
assert_not_contains "no root-cwd warning on symlink-to-subdir" "$out" \
                 "resolves to nexus primary clone"

# ---- Test 10: the shell-trap callouts ride the JIT footgun hook --------
#
# B9 of your-org/your-nexus#236 (U9) required the floor to warn about pipe
# block-buffering, foreground `sleep` blocked → Monitor, and `ml`-into-pipe
# eval-loss. The worker-floor redesign moves these OUT of the always-injected
# prompt and INTO the footgun hook: foreground-sleep is a conf row; the two
# PIPE-triggered traps (python…|tail, ml…|pipe) can't live in the |-delimited
# conf, so they are matched in-code in bash-footgun-guard.sh. Assert the
# guidance still reaches the worker from its new home.

echo '=== shell-trap callouts live in the footgun conf/hook ==='
FOOTGUN_CONF="$_test_dir/../../monitor/bash-footgun-patterns.conf"
FOOTGUN_HOOK="$_test_dir/../../monitor/hooks/bash-footgun-guard.sh"
if [[ -f "$FOOTGUN_CONF" ]]; then
    conf_body=$(cat "$FOOTGUN_CONF")
    assert_contains "footgun conf warns foreground sleep blocked → Monitor" \
                    "$conf_body" "Foreground \`sleep\` is blocked"
else
    printf '  FAIL: bash-footgun-patterns.conf not found at %s\n' "$FOOTGUN_CONF" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -f "$FOOTGUN_HOOK" ]]; then
    hook_body=$(cat "$FOOTGUN_HOOK")
    assert_contains "footgun hook matches python…|tail block-buffering" \
                    "$hook_body" "python -u"
    assert_contains "footgun hook matches ml/module-into-pipe eval-loss" \
                    "$hook_body" "ml-pipe"
else
    printf '  FAIL: bash-footgun-guard.sh not found at %s\n' "$FOOTGUN_HOOK" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- summary ----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
