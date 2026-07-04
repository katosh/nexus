#!/usr/bin/env bash
# Tier 1 — unit tests for monitor/bootstrap-install.sh.
#
# Covers: argument parsing, environment preconditions, clone-shape
# marker checks, --force handling. These exercise the pre-flight
# gates that fire BEFORE the script ever tries to exec claude. The
# script's lab-context probes + prompt composition + exec are
# covered by test-bootstrap-lab-context.sh and the Tier 2 test
# (test-bootstrap-stub-claude.sh); we deliberately keep this file
# focused on the deterministic, no-stub portions.
#
# Strategy: per case, build a minimal fake nexus-clone tree under
# $WORK with just the markers the script self-checks for, then drive
# bootstrap-install.sh under an `env -i` shell that controls TMUX /
# SANDBOX_ACTIVE / SANDBOX_PROJECT_DIR / HOME / USER / PATH. The
# bootstrap-install.sh under $NEXUS is a COPY of the live script —
# not a symlink — so the script's `$_nexus_root` derives from the
# fixture, not from this checkout.
#
# Run: bash monitor/watcher/test-bootstrap-install.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
STUB_DIR="$_test_dir/fixtures/stubs"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — needle %q not in haystack\n' "$label" "$needle" >&2
        printf '    haystack head: %s\n' "${haystack:0:400}" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — needle %q WAS in haystack\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

WORK=$(mktemp -d -t nexus-bootstrap-install-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# --- fixture builder ----------------------------------------------------
#
# Build a fake nexus-code clone under $WORK/<name> that satisfies the
# bootstrap's clone-shape checks. Returns path via stdout.
#
# Usage:
#   build_clone <name> [--no-ng] [--no-example-yml] [--no-watcher]
#                      [--no-install-prompt]
build_clone() {
    local name="$1"; shift
    local root="$WORK/$name"
    local with_ng=1 with_yml=1 with_watcher=1 with_prompt=1
    while (( $# > 0 )); do
        case "$1" in
            --no-ng)              with_ng=0 ;;
            --no-example-yml)     with_yml=0 ;;
            --no-watcher)         with_watcher=0 ;;
            --no-install-prompt)  with_prompt=0 ;;
            *) echo "build_clone: unknown opt $1" >&2; return 2 ;;
        esac
        shift
    done

    mkdir -p "$root/monitor" "$root/config"
    cp "$SRC_ROOT/monitor/bootstrap-install.sh" "$root/monitor/"
    chmod +x "$root/monitor/bootstrap-install.sh"
    # Sourced helpers — copy unconditionally; the script needs them
    # past the pre-flight gates only.
    cp "$SRC_ROOT/monitor/_lab-context.sh" "$root/monitor/"
    cp "$SRC_ROOT/monitor/_claude-bin.sh"  "$root/monitor/"
    (( with_ng ))     && touch "$root/monitor/ng"
    (( with_yml ))    && touch "$root/config/nexus.example.yml"
    (( with_watcher )) && touch "$root/watcher"
    (( with_prompt )) && cp "$SRC_ROOT/monitor/install-prompt.md" "$root/monitor/"
    printf '%s' "$root"
}

# Run bootstrap-install.sh under hermetic env. Globals set:
#   LAST_RC      exit code
#   LAST_STDERR  stderr capture
#   LAST_STDOUT  stdout capture
#
# Usage:
#   run_bootstrap <clone-path> [--no-tmux] [--no-sandbox-active]
#                              [--no-sandbox-dir] [--force]
#                              [--unknown-flag] [--help]
run_bootstrap() {
    local clone="$1"; shift
    local tmux=1 sandbox_active=1 sandbox_dir=1
    local args=()
    while (( $# > 0 )); do
        case "$1" in
            --no-tmux)            tmux=0 ;;
            --no-sandbox-active)  sandbox_active=0 ;;
            --no-sandbox-dir)     sandbox_dir=0 ;;
            --force)              args+=(--force) ;;
            --unknown-flag)       args+=(--bogus-not-real) ;;
            --help)               args+=(--help) ;;
            *) echo "run_bootstrap: unknown opt $1" >&2; return 2 ;;
        esac
        shift
    done

    local env_args=(env -i
        PATH="$STUB_DIR:/usr/bin:/bin"
        HOME="$WORK/home"
        USER="testuser"
        CLAUDE_BIN="$STUB_DIR/claude-stub.sh"
        CLAUDE_STUB_RECORD_FILE="$WORK/claude-record.txt"
    )
    (( tmux ))           && env_args+=(TMUX="fake-tmux-socket,1234,0")
    (( sandbox_active )) && env_args+=(SANDBOX_ACTIVE=1)
    (( sandbox_dir ))    && env_args+=(SANDBOX_PROJECT_DIR="$WORK/sandbox")

    mkdir -p "$WORK/home" "$WORK/sandbox"
    : > "$WORK/claude-record.txt"

    "${env_args[@]}" bash "$clone/monitor/bootstrap-install.sh" "${args[@]}" \
        >"$WORK/boot.out" 2>"$WORK/boot.err"
    LAST_RC=$?
    LAST_STDOUT=$(cat "$WORK/boot.out" 2>/dev/null || true)
    LAST_STDERR=$(cat "$WORK/boot.err" 2>/dev/null || true)
}

# --- Case 1: --help prints header lines, exits 0 -----------------------

echo '=== case 1: --help prints header (lines 2..50), exits 0 ==='
CLONE_OK=$(build_clone case1)
run_bootstrap "$CLONE_OK" --help
assert_eq "--help exits 0" "$LAST_RC" "0"
assert_contains "--help prints the script title" \
    "$LAST_STDOUT" "Nexus install bootstrap"
assert_contains "--help prints the Flags section" \
    "$LAST_STDOUT" "Flags:"
assert_contains "--help mentions --force" \
    "$LAST_STDOUT" "--force"
assert_contains "--help mentions -h / --help" \
    "$LAST_STDOUT" "-h / --help"

# --- Case 2: unknown flag errors loudly, exits 1 -----------------------

echo '=== case 2: unknown flag errors, exits 1 ==='
run_bootstrap "$CLONE_OK" --unknown-flag
assert_eq "unknown flag exits 1" "$LAST_RC" "1"
assert_contains "unknown flag prints diagnostic" \
    "$LAST_STDERR" "bootstrap-install: unknown flag:"

# --- Case 3: --force parses cleanly past flag-parsing block ------------
#
# We can't assert success here because --force still needs the rest of
# pre-flight to pass; we assert that the flag DOES NOT trigger the
# "unknown flag" branch (i.e. exit code isn't 1 and stderr doesn't
# mention "unknown flag"). With a clean clone + pre-flight env it'll
# reach the lab-context block; with no TMUX it would exit 2 before
# we even get to --force handling. We test both: no-env and full-env.

echo '=== case 3: --force is a recognised flag ==='
run_bootstrap "$CLONE_OK" --force --no-tmux
# --no-tmux makes the script exit 2 (env check fires before flag-loop
# is exhausted? no — flag-loop happens first). So with --force +
# --no-tmux we expect exit 2 (TMUX check, not flag rejection).
assert_eq "--force + no-tmux exits 2 (tmux gate, not flag rejection)" \
    "$LAST_RC" "2"
assert_not_contains "--force is not reported as unknown flag" \
    "$LAST_STDERR" "unknown flag: --force"

# --- Case 4: missing TMUX exits 2 with documented error ----------------

echo '=== case 4: missing TMUX exits 2 with tmux-error block ==='
run_bootstrap "$CLONE_OK" --no-tmux
assert_eq "no-TMUX exits 2" "$LAST_RC" "2"
assert_contains "no-TMUX stderr names the failure mode" \
    "$LAST_STDERR" "not running inside a tmux session"
assert_contains "no-TMUX stderr cites the Fix incantation" \
    "$LAST_STDERR" "agent-sandbox tmux new-session"

# --- Case 5: SANDBOX_ACTIVE unset exits 2 ------------------------------

echo '=== case 5: SANDBOX_ACTIVE missing exits 2 ==='
run_bootstrap "$CLONE_OK" --no-sandbox-active
assert_eq "no-SANDBOX_ACTIVE exits 2" "$LAST_RC" "2"
assert_contains "no-SANDBOX_ACTIVE stderr names the failure mode" \
    "$LAST_STDERR" "not running inside agent-sandbox"

# --- Case 6: SANDBOX_PROJECT_DIR unset exits 2 -------------------------

echo '=== case 6: SANDBOX_PROJECT_DIR missing exits 2 ==='
run_bootstrap "$CLONE_OK" --no-sandbox-dir
assert_eq "no-SANDBOX_PROJECT_DIR exits 2" "$LAST_RC" "2"
assert_contains "no-SANDBOX_PROJECT_DIR stderr names sandbox failure mode" \
    "$LAST_STDERR" "not running inside agent-sandbox"

# --- Case 7: missing monitor/ng marker exits 2 -------------------------

echo '=== case 7: missing monitor/ng marker exits 2 ==='
CLONE_NO_NG=$(build_clone case7 --no-ng)
run_bootstrap "$CLONE_NO_NG"
assert_eq "missing ng exits 2" "$LAST_RC" "2"
assert_contains "missing ng stderr cites the clone-shape failure" \
    "$LAST_STDERR" "does not look like a nexus-code clone"
assert_contains "missing ng stderr names the missing artefact" \
    "$LAST_STDERR" "Missing: monitor/ng"

# --- Case 8: missing config/nexus.example.yml exits 2 ------------------

echo '=== case 8: missing config/nexus.example.yml exits 2 ==='
CLONE_NO_YML=$(build_clone case8 --no-example-yml)
run_bootstrap "$CLONE_NO_YML"
assert_eq "missing example yml exits 2" "$LAST_RC" "2"
assert_contains "missing yml stderr names the missing artefact" \
    "$LAST_STDERR" "Missing: config/nexus.example.yml"

# --- Case 9: missing watcher marker exits 2 ----------------------------

echo '=== case 9: missing watcher marker exits 2 ==='
CLONE_NO_WATCHER=$(build_clone case9 --no-watcher)
run_bootstrap "$CLONE_NO_WATCHER"
assert_eq "missing watcher exits 2" "$LAST_RC" "2"
assert_contains "missing watcher stderr names the missing artefact" \
    "$LAST_STDERR" "Missing: watcher"

# --- Case 10: missing install-prompt.md exits 2 ------------------------

echo '=== case 10: missing monitor/install-prompt.md exits 2 ==='
CLONE_NO_PROMPT=$(build_clone case10 --no-install-prompt)
run_bootstrap "$CLONE_NO_PROMPT"
assert_eq "missing install-prompt exits 2" "$LAST_RC" "2"
assert_contains "missing install-prompt stderr names the failure" \
    "$LAST_STDERR" "install prompt missing"

# --- Case 11: existing config/nexus.yml without --force exits 3 --------

echo '=== case 11: pre-existing config/nexus.yml without --force exits 3 ==='
CLONE_EXISTING=$(build_clone case11)
cp "$CLONE_EXISTING/config/nexus.example.yml" "$CLONE_EXISTING/config/nexus.yml"
run_bootstrap "$CLONE_EXISTING"
assert_eq "existing config exits 3 without --force" "$LAST_RC" "3"
assert_contains "existing-config stderr names the file" \
    "$LAST_STDERR" "config/nexus.yml already exists"
assert_contains "existing-config stderr suggests --force" \
    "$LAST_STDERR" "--force"

# --- Case 12: existing config + --force proceeds past pre-flight -------
#
# With --force, the script proceeds through pre-flight, runs the
# lab-context probes, composes the prompt, and execs $CLAUDE_BIN
# (our stub). Exit code is the stub's exit (0).
echo '=== case 12: pre-existing config/nexus.yml WITH --force proceeds ==='
CLONE_EXISTING_F=$(build_clone case12)
cp "$CLONE_EXISTING_F/config/nexus.example.yml" "$CLONE_EXISTING_F/config/nexus.yml"
run_bootstrap "$CLONE_EXISTING_F" --force
assert_eq "existing config + --force exits 0 (stub success)" "$LAST_RC" "0"
# The stub records argv; verify the script DID get past pre-flight by
# checking the record file exists with content. (rc=0 from the script
# could in theory be from the stub being misconfigured; the record
# file proves the script actually reached the exec.)
assert_eq "claude stub was invoked" \
    "$([[ -s "$WORK/claude-record.txt" ]] && echo yes || echo no)" \
    "yes"
# And bonus: the recorded prompt should carry the "passed --force"
# marker from the bootstrap's CONFIG_EXISTS branch.
record=$(cat "$WORK/claude-record.txt")
assert_contains "prompt records --force was used" \
    "$record" "operator passed --force"

# --- summary -----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
