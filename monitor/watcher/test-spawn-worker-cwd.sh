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
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
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

# Canonicalised with `pwd -P`, not left as bare `mktemp -d`. spawn-worker.sh
# now resolves -c through `cd … && pwd -P` (your-org/nexus-code#642), so the
# path it bakes into the launcher is PHYSICAL. If $TMPDIR contained a symlink
# component (macOS /tmp → /private/tmp is the standard example) the fixture's
# logical path and the launcher's physical one would differ, and every
# `cd "$WORKDIR"` assertion below would fail for a reason that has nothing to
# do with the property under test. Normalising the fixture to the same form
# the code uses removes the divergence rather than asserting around it.
WORK=$(cd "$(mktemp -d)" && pwd -P)
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
# `ng` sources monitor/_bookkeeping.sh and REFUSES TO START without
# it (your-org/nexus-code#601/#605: degrading to the silent-coercion
# behaviour it replaces is worse than refusing). Copy it alongside.
cp "$(dirname "$NG_REAL")/_bookkeeping.sh" "$FAKE_NEXUS/monitor/_bookkeeping.sh"
# your-org/nexus-code#1077: `ng` also refuses without the primary-root resolver.
cp "$(dirname "$NG_REAL")/_nexus-root.sh" "$FAKE_NEXUS/monitor/_nexus-root.sh"
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
# The shim precondition guard (your-org/nexus-code#589). Since this fixture
# copies spawn-worker.sh INTO the fake tree, both roots the launcher searches
# — $NEXUS_ROOT and $NEXUS_SPAWN_CODE_ROOT — are this tree, so a guard absent
# here means absent everywhere and the launcher REFUSES (exit 78) rather than
# skipping the check. That refusal is the fix for `#589`, not a test problem:
# the same convention as worker-settings.json below, where the script's hard
# dependencies are supplied rather than worked around.
#
# The real helper is copied, not stubbed, and it takes its `exit 79`
# (NOT CHECKED) path immediately — this fake tree has no monitor/*wrap shim
# dirs, so it returns before probing any shell. That makes Test 2 a live check
# that 79 warns loudly and still lets the spawn proceed.
#
# BOTH names are installed, and the successor is the one that matters:
# guard-block.sh.in searches assert-shims-wrapped.sh FIRST, so a fixture
# carrying only the deprecated forwarder exercises the forwarder's
# successor-missing branch instead of the guard the spawn path actually runs —
# a fixture that tests a different code path than production takes, which is
# the same "verified a subset" shape this branch is about
# (your-org/nexus-code#612).
cp "$_test_dir/../assert-shims-wrapped.sh" "$FAKE_NEXUS/monitor/assert-shims-wrapped.sh"
chmod +x "$FAKE_NEXUS/monitor/assert-shims-wrapped.sh"
cp "$_test_dir/../assert-gh-wrapped.sh" "$FAKE_NEXUS/monitor/assert-gh-wrapped.sh"
chmod +x "$FAKE_NEXUS/monitor/assert-gh-wrapped.sh"
# …and the guard-block TEMPLATE it is emitted from (your-org/nexus-code#589).
# spawn-worker.sh REFUSES rather than emitting an empty guard block, so this
# is a hard dependency exactly like worker-settings.json above.
cp "$_test_dir/../guard-block.sh.in" "$FAKE_NEXUS/monitor/guard-block.sh.in"

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

# The launcher lives at ${TMPDIR:-/tmp}/spawn-launcher-…: the stub's pattern
# follows TMPDIR too (`*/spawn-launcher-*`), because run-tests.sh hands every
# suite a PRIVATE TMPDIR and a `/tmp/spawn-launcher-*` literal missed it —
# this suite was one of six bands' worth of red on your-org/nexus-code#1481.
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
                */spawn-launcher-*) printf '%s' "\$arg" > "$LAUNCHER_CAPTURE"; exit 0 ;;
            esac
        done
        exit 0 ;;
    *) exit 0 ;;
esac
TMUX_STUB
chmod +x "$STUB_BIN/tmux"

# ---- Test 1: launcher captures the cd "$WORKDIR" line ------------------

echo '=== spawn-worker generates a launcher that cd'\''s into WORKDIR ==='
# NEXUS_ROOT is PINNED to the fake tree, and the pin is load-bearing — do not
# drop it as redundant. `#577` makes spawn-worker.sh honour an INHERITED
# NEXUS_ROOT over its own script-relative root, so a run from an agent shell
# that exports NEXUS_ROOT=<the operator's primary> re-roots this spawn onto
# that primary: the launcher then runs the PRIMARY's guard against the
# PRIMARY's real monitor/*wrap dirs and the operator's real login shell, and
# Test 2 asserts on whatever that host happens to be. It passes under CI (where
# NEXUS_ROOT is unset) and fails in a worker — the config-inheritance class CI
# structurally cannot see. The fake tree is this fixture's nexus; say so.
out=$( cd "$WORK" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
       NEXUS_ROOT="$FAKE_NEXUS" \
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
launcher_err=$( cd "$WORK" && PATH="$STUB_BIN:$PATH" bash "$LAUNCHER_PATH" 2>&1 >/dev/null )
captured_pwd=$(<"$PWD_LOG")
assert_eq "claude invoked with cwd=WORKDIR" "$captured_pwd" "$WORKDIR"

# The shim guard ran here and could NOT adjudicate (no monitor/ghwrap in this
# fake tree), so this is the live end-to-end check of the `#589` third
# outcome: exit 79 must be LOUD and must NOT halt the spawn. Both halves
# matter — a silent 79 is the defect, a blocking 79 would brick every spawn on
# a partial checkout.
assert_contains "guard's NOT CHECKED state reaches the launcher's stderr" \
                "$launcher_err" "NOT CHECKED"
assert_contains "…and is explicitly denied the status of a pass" \
                "$launcher_err" "This is not a pass"

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
                */spawn-launcher-*) printf '%s' "\$arg" > "$LAUNCHER_CAPTURE_LOOP"; exit 0 ;;
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
    CLAUDE_BIN="$STUB_BIN/claude" NEXUS_ROOT="$FAKE_NEXUS" \
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

# ---- Test 8: a RELATIVE -c must still reach the agent -------------------
#
# your-org/nexus-code#642. `spawn-worker.sh` validated -c with `[ -d ]`
# against ITS OWN cwd, then wrote the string verbatim into the generated
# /tmp/spawn-launcher-*.sh, which runs with a DIFFERENT cwd. A relative -c
# therefore passed the guard and still died on the launcher's `cd`, while the
# parent had already printed `spawned:` and exited 0 — no agent, exit 0, a
# named window, and a session-id. Two live skeptic spawns were lost to this in
# eight minutes.
#
# The property under test is NOT "the launcher holds an absolute string" —
# that is the mechanism. It is "a relative -c still results in claude being
# executed, in the right directory, from a cwd where the relative path does
# not resolve". So the decisive assertion is the pwd the stubbed claude
# records after the launcher is run from a cwd where `work/cwd-leak-slug`
# does not exist. The string assertions are corroborating detail.

echo '=== relative -c: launcher still reaches claude from an unrelated cwd (#642) ==='
REL_WINDOW="cwd-rel-test-$$"
LAUNCHER_CAPTURE_REL="$WORK/captured-rel-launcher.path"
cat > "$STUB_BIN/tmux" <<TMUX_STUB3
#!/bin/bash
case "\$1" in
    info|list-windows|set-window-option) exit 0 ;;
    new-window) echo '@9'; exit 0 ;;
    send-keys)
        for arg in "\$@"; do
            case "\$arg" in
                */spawn-launcher-*) printf '%s' "\$arg" > "$LAUNCHER_CAPTURE_REL"; exit 0 ;;
            esac
        done
        exit 0 ;;
    *) exit 0 ;;
esac
TMUX_STUB3
chmod +x "$STUB_BIN/tmux"

# The relative form of $WORKDIR as seen from $FAKE_NEXUS. Spawning from
# $FAKE_NEXUS makes it resolve; running the launcher from $WORK makes it NOT
# resolve ($WORK/work does not exist). That asymmetry IS the bug.
REL_ARG="work/cwd-leak-slug"
[[ -d "$FAKE_NEXUS/$REL_ARG" ]] || {
    printf '  FAIL: fixture broken — %s/%s missing\n' "$FAKE_NEXUS" "$REL_ARG" >&2
    FAIL=$(( FAIL + 1 )); echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1
}
[[ ! -e "$WORK/$REL_ARG" ]] || {
    printf '  FAIL: fixture broken — %s/%s must NOT exist, or the test cannot fail\n' "$WORK" "$REL_ARG" >&2
    FAIL=$(( FAIL + 1 )); echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1
}

# Clear the pwd log FIRST. Test 2 wrote $WORKDIR into it, which is exactly the
# value this test asserts — a stale file would make the decisive assertion
# pass without claude ever running. Pre-fix the launcher dies at `cd` and
# never execs the stub, so "no file" is the failure signal and it must be
# unambiguous.
rm -f "$PWD_LOG"

rel_out=$( cd "$FAKE_NEXUS" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
           NEXUS_ROOT="$FAKE_NEXUS" \
           "$FAKE_NEXUS/monitor/spawn-worker.sh" \
               -n "$REL_WINDOW" -c "$REL_ARG" -p "$PROMPT_FILE" 2>&1 )
rel_rc=$?
assert_eq "relative -c spawn exits 0" "$rel_rc" "0"

REL_LAUNCHER=$(<"$LAUNCHER_CAPTURE_REL")
rel_launcher_body=$(cat "$REL_LAUNCHER")
assert_contains "launcher cd's to the ABSOLUTE workdir" \
                "$rel_launcher_body" "cd \"$WORKDIR\""
assert_not_contains "launcher does NOT carry the raw relative -c" \
                    "$rel_launcher_body" "cd \"$REL_ARG\""
# The `spawned:` line is what an orchestrator reads back; #642's was truthful
# about the launcher and misleading about the agent. It should now echo the
# resolved path.
assert_contains "spawned: line reports the resolved absolute workdir" \
                "$rel_out" "workdir=$WORKDIR"

# The decisive one: run the launcher from a cwd where $REL_ARG does not
# resolve. Pre-fix this dies at `cd … || exit 1` and $PWD_LOG is never
# created; post-fix claude runs with cwd=$WORKDIR.
rel_launcher_err=$( cd "$WORK" && PATH="$STUB_BIN:$PATH" bash "$REL_LAUNCHER" 2>&1 >/dev/null )
if [[ -f "$PWD_LOG" ]]; then
    assert_eq "claude actually ran, with cwd=WORKDIR, from an unrelated cwd" \
              "$(<"$PWD_LOG")" "$WORKDIR"
else
    printf '  FAIL: claude never ran — launcher died before exec (stderr: %s)\n' \
           "$rel_launcher_err" >&2
    FAIL=$(( FAIL + 1 ))
fi

rm -f "$REL_LAUNCHER" /tmp/spawn-prompt-${REL_WINDOW}.*.txt /tmp/spawn-hooks-${REL_WINDOW}.*.json

# ---- Test 9: a genuinely missing -c must still be REFUSED ---------------
#
# Negative control for Test 8. Canonicalising with `cd && pwd -P` replaced the
# `[ -d ]` guard outright, so the guard's own behaviour has to be re-proved:
# if the rewrite had swallowed the failure (e.g. by dropping the `||` arm),
# Test 8 would pass and spawn-worker would have stopped refusing bad input
# altogether. Exit 6 and the message text are both part of the contract.

echo '=== a nonexistent -c is still refused with exit 6 ==='
miss_out=$( cd "$FAKE_NEXUS" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
            NEXUS_ROOT="$FAKE_NEXUS" \
            "$FAKE_NEXUS/monitor/spawn-worker.sh" \
                -n "miss-$$" -c "work/definitely-not-here" -p "$PROMPT_FILE" 2>&1 )
miss_rc=$?
assert_eq "missing workdir exits 6" "$miss_rc" "6"
assert_contains "…and says so, naming the path AS THE OPERATOR TYPED IT" \
                "$miss_out" "workdir not a directory: work/definitely-not-here"

# ---- Test 10: BOTH guards must NAME the path they refused ---------------
#
# your-org/nexus-code#648 review, findings F1 and F2. The original suite mutated
# only the FRESH-SPAWN arm, so the guard added to the RESUME arm — the one the
# PR description calls "the `||` arm it never had" — had ZERO coverage. Deleting
# it left the suite at 24/24 ALL TESTS PASSED: an assertion placed where it
# could not fail. It also shipped a real defect that no assertion could see.
#
# THE FIXTURE IS THE WHOLE TRICK. A NONEXISTENT directory cannot reach either
# `||` arm: `[ -d ]` rejects it first (resume), and the fresh-spawn arm reports
# it from the saved argument. What reaches the arm is a directory that EXISTS
# but cannot be ENTERED — mode 000 satisfies `[ -d ]` and fails `cd` with
# EACCES. That is the only input that exercises the failed-assignment path.
#
# And on that input the resume arm printed:
#
#     spawn-worker: workdir not a directory:            <-- nothing after the colon
#
# because `WORKDIR=$(...)` clobbers WORKDIR to the empty string BEFORE the `||`
# arm reads it. A PR whose entire subject is that a bad workdir must be reported
# legibly shipped a refusal that does not say what it refused — the class it
# closes, re-instantiated inside the fix. Hence: assert the path is NAMED, on
# BOTH arms, not merely that the exit code is 6.

echo '=== an unenterable -c is refused, and the path is NAMED (both arms) ==='
NOENTER="$WORK/noenter-646"
mkdir -p "$NOENTER"
chmod 000 "$NOENTER"
# Restore the mode no matter how this test exits, or the EXIT trap's `rm -rf`
# cannot descend and the fixture leaks.
trap 'chmod 755 "$NOENTER" 2>/dev/null; rm -rf "$WORK"; rm -f /tmp/spawn-launcher-${WINDOW_NAME}.*.sh /tmp/spawn-prompt-${WINDOW_NAME}.*.txt /tmp/spawn-hooks-${WINDOW_NAME}.*.json' EXIT

if [[ -d "$NOENTER" ]] && ! ( cd "$NOENTER" ) 2>/dev/null; then
    # -- fresh-spawn arm --
    fresh_out=$( cd "$WORK" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
                 NEXUS_ROOT="$FAKE_NEXUS" \
                 "$FAKE_NEXUS/monitor/spawn-worker.sh" \
                     -n "noenter-fresh-$$" -c "$NOENTER" -p "$PROMPT_FILE" 2>&1 )
    fresh_rc=$?
    assert_eq "fresh-spawn: unenterable workdir exits 6" "$fresh_rc" "6"
    assert_contains "fresh-spawn: refusal NAMES the path" "$fresh_out" "not a directory: $NOENTER"

    # -- resume arm -- the coverage that did not exist.
    # `--resume` reaches the workdir guard before session-id resolution and
    # before the `tmux info` check, so no tmux fixture is needed for it to fire.
    res_out=$( cd "$WORK" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
               NEXUS_ROOT="$FAKE_NEXUS" \
               "$FAKE_NEXUS/monitor/spawn-worker.sh" \
                   --resume "noenter-resume-$$" -c "$NOENTER" 2>&1 )
    res_rc=$?
    assert_eq "resume: unenterable workdir exits 6" "$res_rc" "6"
    assert_contains "resume: refusal NAMES the path (not an empty string)" \
                    "$res_out" "not a directory: $NOENTER"
    # Pin the EMPTY-PATH SHAPE directly, as a line ending right after the
    # colon. `assert_contains` above already catches the defect, but this states
    # WHY it is wrong so a future reader does not "simplify" it into something
    # that passes on an empty path. It must be an END-ANCHORED regex, not a
    # substring: `grep -F "not a directory: "` matches the CORRECT message too,
    # since that string is a prefix of "not a directory: /some/path". (I got
    # this wrong on the first attempt and the suite caught it.)
    if grep -Eq 'not a directory:[[:space:]]*$' <<<"$res_out"; then
        printf '  FAIL: %s\n' "resume: refusal must not end at the colon (empty path)" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "resume: refusal must not end at the colon (empty path)"
        PASS=$(( PASS + 1 ))
    fi
else
    # REFUSE to self-certify. The first version of this branch incremented PASS
    # by 5 so the expected-count guard would still reconcile — i.e. it reported
    # five assertions as passing that never ran, for a property it could not
    # check. That is the exact defect class this block was added to close
    # (your-org/nexus-code#648 review F1: an assertion placed where it cannot
    # fail), reproduced inside the fix for it, one commit later.
    #
    # Root can enter a mode-000 directory, so the fixture is genuinely
    # unbuildable there. The honest outcome is then "this suite could not verify
    # its property", which is a FAILURE to report, not a pass to assume. CI runs
    # as an unprivileged user and reaches the real assertions (verified: all five
    # unit cells green on 3ce711d), so this arm is unreachable in practice —
    # which is precisely how a silent self-certification survives unnoticed.
    printf '  FAIL: cannot build an unenterable dir at %s (running as root?)\n' "$NOENTER" >&2
    printf '        This suite CANNOT verify the #648 F1/F2 property in this environment.\n' >&2
    printf '        Counting these 5 as PASS would be exit-0-for-work-not-done. Refusing.\n' >&2
    FAIL=$(( FAIL + 5 ))
fi
chmod 755 "$NOENTER" 2>/dev/null

# ---- summary ------------------------------------------------------------

echo
# Expected-assertion-count guard. your-org/nexus-code#648 review F1: a guard was
# added to the resume arm and NOTHING exercised it — deleting it left this suite
# at "ALL TESTS PASSED". A green suite is only evidence if the assertions it
# claims to run actually ran; an assert_* that never executes is counted by
# nothing and reads identically to a pass.
EXPECTED=29
echo "=== summary: $PASS passed, $FAIL failed ($(( PASS + FAIL )) assertions; expected $EXPECTED) ==="
if (( PASS + FAIL != EXPECTED )); then
    echo "ASSERTION COUNT MISMATCH — $(( PASS + FAIL )) ran, $EXPECTED expected. Some assertion did not execute." >&2
    exit 1
fi
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
