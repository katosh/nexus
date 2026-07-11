#!/usr/bin/env bash
# Unit tests for monitor/install-labsh.sh — the bootstrap-side installer
# for operator/labsh.
#
# Sandbox-correct path:
#   target = $SANDBOX_PROJECT_DIR/work/labsh
#
# Covers the reliability contract: fresh install, idempotent re-run (no
# re-clone), crash recovery (leftover temp clone; partial non-repo dir),
# concurrency (two simultaneous installs), --check, fail-loud on git failure,
# and fail-loud when SANDBOX_PROJECT_DIR is unset.
#
# `git` is stubbed via PATH (same scheme as test-install-hpc-skills.sh): GOOD
# stub does a real init + remote in the cloned tree; NOCLONE stub marks+fails
# any clone but delegates other subcommands to real git; FAIL stub fails clone.
#
# Run: bash monitor/watcher/test-install-labsh.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL="$_test_dir/../install-labsh.sh"
REAL_GIT=$(command -v git) || { echo "FATAL: real git not found"; exit 1; }

# th_hermetic_path only (fork-bomb precondition guard, #479); inline
# assert helpers below shadow the helper-file versions.
. "$_test_dir/_test_helpers.sh"

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
    else printf '  FAIL: %s — needle %q not in %q\n' "$label" "$needle" "$haystack" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_ok() { local l="$1"; shift; if "$@"; then printf '  PASS: %s\n' "$l"; PASS=$(( PASS+1 )); else printf '  FAIL: %s\n' "$l" >&2; FAIL=$(( FAIL+1 )); fi; }
assert_no() { local l="$1"; shift; if "$@"; then printf '  FAIL: %s\n' "$l" >&2; FAIL=$(( FAIL+1 )); else printf '  PASS: %s\n' "$l"; PASS=$(( PASS+1 )); fi; }

WORK=$(mktemp -d -t nexus-install-labsh-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
LOCKDIR="$WORK/locks"

STUBS="$WORK/stub-bin"; mkdir -p "$STUBS"
cat > "$STUBS/git" <<STUB
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
if [[ "\${1-}" == "clone" ]]; then
    target=""; for arg in "\$@"; do target="\$arg"; done
    mkdir -p "\$target"
    echo "STUB-CLONE" > "\$target/README.md"
    "\$REAL_GIT" -C "\$target" init -q
    "\$REAL_GIT" -C "\$target" remote add origin https://github.com/operator/labsh.git
    exit 0
fi
exec "\$REAL_GIT" "\$@"
STUB
chmod +x "$STUBS/git"

NOCLONE="$WORK/stub-bin-noclone"; mkdir -p "$NOCLONE"
cat > "$NOCLONE/git" <<STUB
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
if [[ "\${1-}" == "clone" ]]; then echo CLONE >> "$WORK/clone-attempts"; exit 17; fi
exec "\$REAL_GIT" "\$@"
STUB
chmod +x "$NOCLONE/git"

FAIL_STUBS="$WORK/stub-bin-fail"; mkdir -p "$FAIL_STUBS"
cat > "$FAIL_STUBS/git" <<STUB
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
if [[ "\${1-}" == "clone" ]]; then echo "fatal: stub-git refused for test" >&2; exit 128; fi
exec "\$REAL_GIT" "\$@"
STUB
chmod +x "$FAIL_STUBS/git"

run_install() {
    local sandbox="${1-__unset__}" bin="$2"; shift 2
    # Synthetic PATH goes through th_hermetic_path so it can never drop
    # command_not_found.py (fork-bomb precondition, #479 / #457).
    local safe_path; safe_path=$(th_hermetic_path "$bin:/usr/bin:/bin" "$WORK")
    if [[ "$sandbox" == "__unset__" ]]; then
        LAST_STDOUT=$(env -u SANDBOX_PROJECT_DIR NEXUS_INSTALL_LOCK_DIR="$LOCKDIR" \
            PATH="$safe_path" bash "$INSTALL" "$@" 2>"$WORK/last.err")
    else
        LAST_STDOUT=$(SANDBOX_PROJECT_DIR="$sandbox" NEXUS_INSTALL_LOCK_DIR="$LOCKDIR" \
            PATH="$safe_path" bash "$INSTALL" "$@" 2>"$WORK/last.err")
    fi
    LAST_RC=$?
    LAST_STDERR=$(cat "$WORK/last.err")
}

# --- Test 1: fresh install ---------------------------------------------
echo '=== fresh install → clones to $SANDBOX_PROJECT_DIR/work/labsh ==='
SBX1="$WORK/sandbox-1"; mkdir -p "$SBX1"
run_install "$SBX1" "$STUBS"
assert_eq "exit 0" "$LAST_RC" "0"
assert_ok "clone landed (.git present)" test -d "$SBX1/work/labsh/.git"
assert_contains "stdout mentions operator/labsh#3 caveat" "$LAST_STDOUT" "operator/labsh#3"
run_install "$SBX1" "$NOCLONE" --check
assert_eq "--check passes on complete install" "$LAST_RC" "0"

# --- Test 2: idempotent re-run (no re-clone) ---------------------------
echo '=== re-run with clone present → exit 0, git clone NOT called ==='
rm -f "$WORK/clone-attempts"
run_install "$SBX1" "$NOCLONE"
assert_eq "idempotent exit 0" "$LAST_RC" "0"
assert_contains "stdout says already cloned" "$LAST_STDOUT" "already cloned"
assert_no "no clone attempted on re-run" test -f "$WORK/clone-attempts"

# --- Test 3: crash recovery — leftover temp clone + missing repo --------
echo '=== crash: leftover temp clone cleared + re-clone ==='
SBX3="$WORK/sandbox-3"; mkdir -p "$SBX3"
run_install "$SBX3" "$STUBS"
rm -rf "$SBX3/work/labsh"
mkdir -p "$SBX3/work/labsh.clone-tmp.999"; echo j > "$SBX3/work/labsh.clone-tmp.999/x"
run_install "$SBX3" "$STUBS"
assert_eq "exit 0" "$LAST_RC" "0"
assert_no "leftover temp removed" bash -c 'ls -d "$1".clone-tmp.* >/dev/null 2>&1' _ "$SBX3/work/labsh"
assert_ok "repo re-cloned healthy" test -d "$SBX3/work/labsh/.git"

# --- Test 3b: crash recovery — partial non-repo dir moved aside ---------
echo '=== crash: partial non-repo dir moved aside + re-clone ==='
SBX3b="$WORK/sandbox-3b"; mkdir -p "$SBX3b"
run_install "$SBX3b" "$STUBS"
rm -rf "$SBX3b/work/labsh/.git"
run_install "$SBX3b" "$STUBS"
assert_eq "exit 0" "$LAST_RC" "0"
assert_ok "partial moved aside (.broken.*)" bash -c 'ls -d "$1".broken.* >/dev/null 2>&1' _ "$SBX3b/work/labsh"
assert_ok "repo healthy again" test -d "$SBX3b/work/labsh/.git"

# --- Test 4: concurrency — two simultaneous installs --------------------
echo '=== concurrency: two simultaneous installs → one clone, both exit 0 ==='
SBX4="$WORK/sandbox-4"; mkdir -p "$SBX4"
( run_install "$SBX4" "$STUBS"; echo $? > "$WORK/c1.rc" ) &
p1=$!
( SANDBOX_PROJECT_DIR="$SBX4" NEXUS_INSTALL_LOCK_DIR="$LOCKDIR" PATH="$(th_hermetic_path "$STUBS:/usr/bin:/bin" "$WORK")" bash "$INSTALL" >/dev/null 2>&1; echo $? > "$WORK/c2.rc" ) &
p2=$!
wait $p1; wait $p2
assert_eq "both exit 0" "$(cat "$WORK/c1.rc")/$(cat "$WORK/c2.rc")" "0/0"
assert_ok "repo healthy" test -d "$SBX4/work/labsh/.git"
assert_no "no leftover temp" bash -c 'ls -d "$1".clone-tmp.* >/dev/null 2>&1' _ "$SBX4/work/labsh"

# --- Test 5: git clone fails → fail loud, nothing left behind -----------
echo '=== git clone fails → non-zero, no populated clone ==='
SBX5="$WORK/sandbox-5"; mkdir -p "$SBX5"
run_install "$SBX5" "$FAIL_STUBS"
assert_ok "non-zero exit on git failure" test "$LAST_RC" -ne 0
assert_no "no clone dir left behind" test -d "$SBX5/work/labsh"

# --- Test 6: unset SANDBOX_PROJECT_DIR → fail loud ----------------------
echo '=== unset $SANDBOX_PROJECT_DIR → installer refuses ==='
run_install "__unset__" "$STUBS"
assert_ok "non-zero exit when SANDBOX_PROJECT_DIR unset" test "$LAST_RC" -ne 0
assert_contains "stderr names SANDBOX_PROJECT_DIR" "$LAST_STDERR" "SANDBOX_PROJECT_DIR"

# --- Test 7: --check on empty env → non-zero ----------------------------
echo '=== --check on empty env → non-zero ==='
SBX7="$WORK/sandbox-7"; mkdir -p "$SBX7"
run_install "$SBX7" "$NOCLONE" --check
assert_ok "--check non-zero on empty env" test "$LAST_RC" -ne 0

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
