#!/usr/bin/env bash
# Tier 2 — integration test for monitor/bootstrap-install.sh's claude
# invocation: argv shape, prompt-body composition, tmpfile cleanup,
# and (when a real tmux server is reachable) the bootstrap window
# rename to `bootstrap`.
#
# Complements test-bootstrap-lab-context.sh (which exercises the same
# stub-claude path to verify the per-launch lab-context probes flow
# into the composed prompt). This file focuses on:
#
#   - argv structure: claude was invoked with
#     `--dangerously-skip-permissions` and the composed prompt as $2.
#   - baseline context lines (nexus root, operator, sandbox dir,
#     config-exists state) appear in the prompt.
#   - install-prompt.md body is concatenated verbatim into the prompt
#     (assert several non-trivial anchor strings).
#   - the bootstrap-composed tmpfile (`/tmp/nexus-bootstrap-prompt-*.md`)
#     is removed before exec'ing claude (no leftover artefact after the
#     process exits).
#   - real-tmux integration: the window the bootstrap runs in is
#     renamed to `bootstrap`. Gated on `tmux` being on PATH and the
#     test running outside an existing nested tmux that would
#     reject `new-session`.
#
# Run: bash monitor/watcher/test-bootstrap-stub-claude.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
STUB_DIR="$_test_dir/fixtures/stubs"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — needle %q absent\n' "$label" "$needle" >&2
        printf '    haystack head: %s\n' "${haystack:0:400}" >&2
        FAIL=$(( FAIL + 1 )); fi
}
skip() {
    printf '  SKIP: %s\n' "$*"
}

WORK=$(mktemp -d -t nexus-bootstrap-stub-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Fake nexus-clone shape — the script's pre-flight markers + helpers.
NEXUS="$WORK/nexus"
mkdir -p "$NEXUS/monitor" "$NEXUS/config"
touch "$NEXUS/monitor/ng" "$NEXUS/config/nexus.example.yml" "$NEXUS/watcher"
cp "$SRC_ROOT/monitor/bootstrap-install.sh" "$NEXUS/monitor/"
cp "$SRC_ROOT/monitor/install-prompt.md"    "$NEXUS/monitor/"
cp "$SRC_ROOT/monitor/_lab-context.sh"      "$NEXUS/monitor/"
cp "$SRC_ROOT/monitor/_claude-bin.sh"       "$NEXUS/monitor/"
chmod +x "$NEXUS/monitor/bootstrap-install.sh"

# Pre-flight lab-context fixtures (deterministic; not the focus here).
HOME_DIR="$WORK/home"
SANDBOX_DIR="$WORK/sandbox"
mkdir -p "$HOME_DIR/.claude/skills" "$SANDBOX_DIR/work"

RECORD="$WORK/claude-record.txt"
# Per-test private tmp dir for the bootstrap prompt tmpfile. Passed to
# bootstrap-install.sh via TMPDIR (it honours TMPDIR, falling back to
# /tmp) so Case D's leftover check globs ONLY this invocation's file —
# never a sibling bootstrap test's in-flight tmpfile. Globbing global
# /tmp made Case D fail under `run-tests.sh --jobs N` whenever a
# concurrent test-bootstrap-* run had a tmpfile alive in the
# mktemp→exec window (your-org/your-nexus#180, item R3).
PROMPT_TMPDIR="$WORK/prompt-tmp"
mkdir -p "$PROMPT_TMPDIR"
PROMPT_GLOB="$PROMPT_TMPDIR/nexus-bootstrap-prompt-*.md"

# --- Cases A–D: stub-claude unit (no real tmux) ------------------------

echo '=== run bootstrap under stub claude (fake TMUX env) ==='

# Sentinel just before invocation to scope the leftover-tmpfile check.
sentinel="$WORK/start-sentinel"
touch "$sentinel"
sleep 0.1   # ensure mtime resolution catches subsequently-created tmpfiles

env -i \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    TMPDIR="$PROMPT_TMPDIR" \
    TMUX="$WORK/fake-tmux.sock,1234,0" \
    SANDBOX_ACTIVE=1 \
    SANDBOX_PROJECT_DIR="$SANDBOX_DIR" \
    HOME="$HOME_DIR" \
    USER="opcode-tester" \
    CLAUDE_BIN="$STUB_DIR/claude-stub.sh" \
    CLAUDE_STUB_RECORD_FILE="$RECORD" \
    bash "$NEXUS/monitor/bootstrap-install.sh" \
    >"$WORK/boot.out" 2>"$WORK/boot.err"
rc=$?

assert_eq "bootstrap exits 0 under stub claude" "$rc" "0"

# --- Case A: argv structure --------------------------------------------

record=$(cat "$RECORD" 2>/dev/null || true)
assert_contains "stub recorded an invocation (file non-empty)" "$record" "argc="
assert_contains "argc reports 2 args (flag + prompt)" "$record" "argc=2"
assert_contains "argv[1] is --dangerously-skip-permissions" \
    "$record" "argv[1]=--dangerously-skip-permissions"
assert_contains "argv[2] (prompt) carries the header banner" \
    "$record" "argv[2]=# Nexus install bootstrap (this session)"

# --- Case B: baseline context lines in the prompt ----------------------

# bootstrap-install.sh's per-launch HEADER block contributes these
# anchor lines BEFORE the install-prompt body is concatenated.
assert_contains "prompt contains Nexus root: line"     "$record" "Nexus root:"
assert_contains "prompt contains Nexus root path"      "$record" "Nexus root:               $NEXUS"
assert_contains "prompt contains Operator shell user"  "$record" "Operator shell user:      opcode-tester"
assert_contains "prompt contains Sandbox project dir"  "$record" "Sandbox project dir:      $SANDBOX_DIR"
assert_contains "prompt contains config/nexus.yml line" "$record" "config/nexus.yml exists:"
assert_contains "prompt notes fresh install (no force)" "$record" "no — fresh install"

# --- Case C: install-prompt.md body is concatenated verbatim -----------
#
# Pick anchor strings from non-trivial positions throughout the prompt
# (Phase 0/2/4/5/6/7 + a recovery section). If any phase header drifts
# or the file is silently truncated, one of these breaks.
assert_contains "install-prompt body present: agent brief title" \
    "$record" "# Nexus install bootstrap — agent brief"
assert_contains "install-prompt body present: Phase 0 header" \
    "$record" "## Phase 0 — sanity + introductions"
assert_contains "install-prompt body present: Phase 2 GitHub App header" \
    "$record" "## Phase 2 — create the GitHub App"
assert_contains "install-prompt body present: Phase 4 smoke tests header" \
    "$record" "## Phase 4 — smoke tests"
assert_contains "install-prompt body present: Phase 5 overview seed header" \
    "$record" "## Phase 5 — seed the overview issue"
assert_contains "install-prompt body present: Phase 6 Lab-specific addons" \
    "$record" "## Phase 6 — Lab-specific addons"
assert_contains "install-prompt body present: Phase 7 hand-off header" \
    "$record" "## Phase 7 — hand off to the watcher"
assert_contains "install-prompt body present: Recovery routines section" \
    "$record" "## Recovery routines"
assert_contains "install-prompt body present: What you must NOT do" \
    "$record" "## What you must NOT do"
assert_contains "install-prompt body present: final Phase 0 begin marker" \
    "$record" "Begin with **Phase 0**."

# --- Case D: tmpfile cleanup -------------------------------------------
#
# bootstrap-install.sh `rm -f`'s the tmpfile before exec'ing claude.
# After the process exits, no `nexus-bootstrap-prompt-*.md` newer than
# $sentinel should remain in the private $PROMPT_TMPDIR. Scoping to that
# dir (not global /tmp) makes the check immune to a sibling
# test-bootstrap-* run's concurrent tmpfile (item R3).
leftover=$(find "$PROMPT_TMPDIR" -maxdepth 1 -name 'nexus-bootstrap-prompt-*.md' \
    -newer "$sentinel" -print 2>/dev/null | head -5)
if [[ -z "$leftover" ]]; then
    printf '  PASS: %s\n' "no leftover /tmp/nexus-bootstrap-prompt-*.md after exit"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s — leftover files:\n%s\n' \
        "no leftover /tmp/nexus-bootstrap-prompt-*.md after exit" "$leftover" >&2
    FAIL=$(( FAIL + 1 ))
fi

# --- Case E: real-tmux window rename -----------------------------------
#
# The bootstrap script issues `tmux rename-window bootstrap 2>/dev/null
# || true`. To verify the rename actually takes effect, we need a real
# tmux server: spawn a session on a unique socket with a known initial
# window name, send the bootstrap command into that pane, wait for the
# stub-claude record file to appear (proxy for the bootstrap reaching
# the exec), then read the window name back.
#
# Gated on `tmux` being on PATH; CI's ubuntu-latest installs it via
# the workflow's `install runtime deps (jq + tmux)` step.

echo '=== Case E: real-tmux window rename ==='

if ! command -v tmux >/dev/null 2>&1; then
    skip "tmux not on PATH; window-rename assertion skipped"
else
    TMX_SOCK="$WORK/tmux.sock"
    SESS="nexus-bootstrap-test"
    INITIAL_NAME="initial"
    # Clean tmux server state to keep test repeatable on a worktree
    # where prior runs may have left a server behind.
    tmux -S "$TMX_SOCK" kill-server >/dev/null 2>&1 || true

    # Fresh record file for this case so a leftover from Cases A–D
    # doesn't satisfy the polling loop instantly.
    RENAME_RECORD="$WORK/claude-record-rename.txt"
    : > "$RENAME_RECORD"

    # Spawn a detached session. -d keeps the session detached (no
    # controlling terminal needed). Explicit `bash --norc --noprofile`
    # makes the pane's shell deterministic: without it tmux uses
    # $SHELL which on some images (busybox-ish CI shims, locked-down
    # sandboxes) drops to a non-interactive shell that ignores
    # send-keys.
    tmux -S "$TMX_SOCK" new-session -d -s "$SESS" -n "$INITIAL_NAME" \
        -x 200 -y 50 bash --norc --noprofile 2>"$WORK/tmux-spawn.err"
    tmux_rc=$?

    if (( tmux_rc != 0 )); then
        skip "tmux new-session failed (rc=$tmux_rc): $(cat "$WORK/tmux-spawn.err")"
    else
        # Confirm initial name before we run anything.
        before=$(tmux -S "$TMX_SOCK" list-windows -t "$SESS" -F '#W' | head -1)
        assert_eq "tmux window starts as 'initial'" "$before" "$INITIAL_NAME"

        # Build a one-liner. Critical: forward $TMUX (and $TMUX_PANE)
        # via "$TMUX" — bash inside the pane expands them at command-
        # execution time, so the bootstrap's `[[ -z $TMUX ]]` guard
        # sees the real tmux server. `env -i` is replaced with an
        # explicit env list here so we don't accidentally strip the
        # tmux env tmux itself injects.
        cmd='env -i'
        cmd+=' TMUX="$TMUX"'
        cmd+=' TMUX_PANE="$TMUX_PANE"'
        cmd+=" PATH='$STUB_DIR:/usr/bin:/bin'"
        cmd+=" SANDBOX_ACTIVE=1"
        cmd+=" SANDBOX_PROJECT_DIR='$SANDBOX_DIR'"
        cmd+=" HOME='$HOME_DIR'"
        cmd+=" USER='opcode-tester'"
        cmd+=" CLAUDE_BIN='$STUB_DIR/claude-stub.sh'"
        cmd+=" CLAUDE_STUB_RECORD_FILE='$RENAME_RECORD'"
        cmd+=" bash '$NEXUS/monitor/bootstrap-install.sh'"

        # Target by session name only — tmux picks the active window
        # (the sole one we just created). Avoids `$SESS:0` vs `$SESS:1`
        # base-index config drift across tmux versions.
        tmux -S "$TMX_SOCK" send-keys -t "$SESS" "$cmd" C-m

        # Wait for stub record file to be populated (proxy for
        # bootstrap reaching exec). Cap the wait at 15s to avoid
        # hanging the suite if something regresses upstream.
        deadline=$(( $(date +%s) + 15 ))
        while (( $(date +%s) < deadline )); do
            if [[ -s "$RENAME_RECORD" ]]; then break; fi
            sleep 0.2
        done

        if [[ ! -s "$RENAME_RECORD" ]]; then
            printf '  FAIL: bootstrap did not invoke stub claude within 15s\n' >&2
            FAIL=$(( FAIL + 1 ))
        else
            # The bootstrap exec'd the stub which exits 0; the tmux
            # window then drops to a fresh shell prompt. Window name
            # remains whatever bootstrap-install.sh renamed it to.
            after=$(tmux -S "$TMX_SOCK" list-windows -t "$SESS" -F '#W' 2>/dev/null | head -1)
            assert_eq "tmux window renamed to 'bootstrap'" "$after" "bootstrap"
        fi

        tmux -S "$TMX_SOCK" kill-server >/dev/null 2>&1 || true
    fi
fi

# --- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
