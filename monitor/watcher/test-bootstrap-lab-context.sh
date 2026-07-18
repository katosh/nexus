#!/usr/bin/env bash
# Integration test for monitor/bootstrap-install.sh's prompt-composition
# block: verify the three new lab-context signals (HPC host, hpc-skills
# installed, labsh installed) are propagated into the install-prompt
# context that gets `exec`'d as the claude argv.
#
# Strategy: build a minimal fake nexus-clone tree (just enough markers
# to satisfy bootstrap-install.sh's self-checks), then drive it under a
# stub CLAUDE_BIN that writes its $1 (the composed prompt text) to a
# tmpfile and exits 0. The test then greps the captured prompt for the
# new context lines.
#
# We also drive the _lab-context.sh overrides (_NEXUS_HPC_MOUNT,
# _NEXUS_HPC_HOST_PREFIXES, _NEXUS_HOSTNAME, HOME, SANDBOX_PROJECT_DIR)
# so the captured prompt's yes/no values are deterministic and we can
# assert both shapes.
#
# Run: bash monitor/watcher/test-bootstrap-lab-context.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)

PASS=0
FAIL=0
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — needle %q not in haystack\n' "$label" "$needle" >&2
        printf '    haystack head: %s\n' "${haystack:0:400}" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}

WORK=$(mktemp -d -t nexus-bootstrap-lab-ctx-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- build a hermetic nexus clone shape --------------------------------
# Self-check markers bootstrap-install.sh requires:
#   monitor/ng, config/nexus.example.yml, watcher (load-bearing files
#   per the for-loop at bootstrap-install.sh:105). monitor/install-
#   prompt.md and the new monitor/_lab-context.sh are also needed.
NEXUS="$WORK/nexus"
mkdir -p "$NEXUS/monitor" "$NEXUS/config"
touch "$NEXUS/monitor/ng" "$NEXUS/config/nexus.example.yml" "$NEXUS/watcher"
cp "$SRC_ROOT/monitor/bootstrap-install.sh" "$NEXUS/monitor/"
cp "$SRC_ROOT/monitor/install-prompt.md"    "$NEXUS/monitor/"
cp "$SRC_ROOT/monitor/_claude-bin.sh"       "$NEXUS/monitor/"
# _lab-context.sh is the new file under test; copy it if it exists yet.
# (Before Layer 1 lands, this test fails with "file not found" — that's
# the TDD-red signal.)
if [[ -f "$SRC_ROOT/monitor/_lab-context.sh" ]]; then
    cp "$SRC_ROOT/monitor/_lab-context.sh" "$NEXUS/monitor/"
fi
chmod +x "$NEXUS/monitor/bootstrap-install.sh"

# Stub claude: writes its last argv (the prompt body) to a captured
# file, then exits 0. The bootstrap calls `exec "$CLAUDE_BIN"
# --dangerously-skip-permissions "$prompt_text"`, so $3 is the prompt.
CAPTURE="$WORK/captured-prompt.txt"
STUB_CLAUDE="$WORK/stub-claude.sh"
cat > "$STUB_CLAUDE" <<STUB
#!/usr/bin/env bash
# args: \$1=--dangerously-skip-permissions, \$2=<prompt text>
printf '%s' "\${2-}" > "$CAPTURE"
exit 0
STUB
chmod +x "$STUB_CLAUDE"

# Fixtures that drive the probes deterministically.
FH_FAST="$WORK/shared"
mkdir -p "$FH_FAST"
HOME_NO_SKILLS="$WORK/home-no-skills"
mkdir -p "$HOME_NO_SKILLS/.claude/skills"
HOME_WITH_SKILLS="$WORK/home-with-skills"
mkdir -p "$HOME_WITH_SKILLS/.claude/skills/hpc-skills"
SBX_NO_LABSH="$WORK/sbx-no-labsh"
mkdir -p "$SBX_NO_LABSH/work"
SBX_WITH_LABSH="$WORK/sbx-with-labsh"
mkdir -p "$SBX_WITH_LABSH/work/labsh"

run_bootstrap() {
    local home="$1" hostname="$2" fh_fast="$3" sandbox="$4"
    : > "$CAPTURE"
    env -i \
        PATH="/usr/bin:/bin" \
        TMUX="fake-tmux-socket,1234,0" \
        SANDBOX_ACTIVE=1 \
        SANDBOX_PROJECT_DIR="$sandbox" \
        HOME="$home" \
        USER="testuser" \
        CLAUDE_BIN="$STUB_CLAUDE" \
        _NEXUS_HPC_MOUNT="$fh_fast" \
        _NEXUS_HPC_HOST_PREFIXES="login|gpu|compute" \
        _NEXUS_HOSTNAME="$hostname" \
        bash "$NEXUS/monitor/bootstrap-install.sh" 2>"$WORK/boot.err"
    LAST_RC=$?
    LAST_PROMPT=$(cat "$CAPTURE" 2>/dev/null || true)
    LAST_STDERR=$(cat "$WORK/boot.err" 2>/dev/null || true)
}

# --- Case A: HPC + skills installed + labsh installed → all "yes" ------

echo '=== context block: HPC yes, hpc-skills yes, labsh yes ==='
run_bootstrap "$HOME_WITH_SKILLS" "login01" "$FH_FAST" "$SBX_WITH_LABSH"
assert_eq "bootstrap exit code is 0" "$LAST_RC" "0"
assert_contains "prompt mentions HPC host (your-institution)" "$LAST_PROMPT" "HPC host (your-institution):"
assert_contains "prompt shows HPC: yes"                     "$LAST_PROMPT" "HPC host (your-institution):       yes"
assert_contains "prompt mentions hpc-skills installed"      "$LAST_PROMPT" "hpc-skills installed:"
assert_contains "prompt shows hpc-skills: yes"              "$LAST_PROMPT" "hpc-skills installed:     yes"
assert_contains "prompt mentions labsh installed"           "$LAST_PROMPT" "labsh installed:"
assert_contains "prompt shows labsh: yes"                   "$LAST_PROMPT" "labsh installed:             yes"

# --- Case B: not HPC + neither addon → all "no" ------------------------

echo '=== context block: HPC no, hpc-skills no, labsh no ==='
run_bootstrap "$HOME_NO_SKILLS" "laptop-1234" "$WORK/no-such-mount" "$SBX_NO_LABSH"
assert_eq "bootstrap exit code is 0" "$LAST_RC" "0"
assert_contains "prompt shows HPC: no"                      "$LAST_PROMPT" "HPC host (your-institution):       no"
assert_contains "prompt shows hpc-skills: no"               "$LAST_PROMPT" "hpc-skills installed:     no"
assert_contains "prompt shows labsh: no"                    "$LAST_PROMPT" "labsh installed:             no"

# --- Case C: existing baseline context lines are preserved -------------

echo '=== existing baseline context (nexus root, USER, sandbox dir) is preserved ==='
assert_contains "prompt still shows Nexus root"             "$LAST_PROMPT" "Nexus root:"
assert_contains "prompt still shows Operator shell user"    "$LAST_PROMPT" "Operator shell user:"
assert_contains "prompt still shows Sandbox project dir"    "$LAST_PROMPT" "Sandbox project dir:"
assert_contains "prompt still shows config/nexus.yml exists" "$LAST_PROMPT" "config/nexus.yml exists:"

# --- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
