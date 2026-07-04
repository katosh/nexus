#!/usr/bin/env bash
# Unit tests for monitor/install-hpc-skills.sh — the bootstrap-side
# installer for your-org/hpc-skills.
#
# Sandbox-correct paths:
#   target  = $HOME/.claude/hpc-skills           (clone target; writable in sandbox)
#   symlink = $HOME/.claude/skills/hpc-skills     (umbrella discovery point)
#   per-sub-skill links: $HOME/.claude/skills/<name> -> target/skills/<name>
#
# Covers the reliability contract: fresh install, idempotent re-run,
# self-heal (umbrella-only → recreate per-sub-skill links), crash recovery
# (leftover temp clone; partial non-repo dir), corrupt-clone repair, wrong &
# dangling symlink repair/prune, foreign-link preservation, concurrency
# (two simultaneous installs + a held-lock wait proof), --check, fail-loud.
#
# `git` is stubbed via PATH. The GOOD stub does a REAL `git init` + remote in
# the cloned tree (so the installer's health checks — rev-parse/config —
# work) and delegates all non-clone subcommands to the real git. The NOCLONE
# stub fails+marks any clone attempt (delegating everything else to real git)
# so idempotency tests can prove no re-clone happened. The FAIL stub fails
# clones outright.
#
# Run: bash monitor/watcher/test-install-hpc-skills.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL="$_test_dir/../install-hpc-skills.sh"
REAL_GIT=$(command -v git) || { echo "FATAL: real git not found"; exit 1; }

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
assert_ok()  { local l="$1"; shift; if "$@"; then printf '  PASS: %s\n' "$l"; PASS=$(( PASS+1 )); else printf '  FAIL: %s\n' "$l" >&2; FAIL=$(( FAIL+1 )); fi; }
assert_no()  { local l="$1"; shift; if "$@"; then printf '  FAIL: %s\n' "$l" >&2; FAIL=$(( FAIL+1 )); else printf '  PASS: %s\n' "$l"; PASS=$(( PASS+1 )); fi; }

WORK=$(mktemp -d -t nexus-install-hpc-skills-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
LOCKDIR="$WORK/locks"

# GOOD stub: real init + remote + seeded skills/ tree; delegates others.
STUBS="$WORK/stub-bin"; mkdir -p "$STUBS"
cat > "$STUBS/git" <<STUB
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
if [[ "\${1-}" == "clone" ]]; then
    target=""; for arg in "\$@"; do target="\$arg"; done
    mkdir -p "\$target/skills/hpc.cluster-overview" "\$target/skills/hpc.slurm"
    echo "# skill" > "\$target/skills/hpc.cluster-overview/SKILL.md"
    "\$REAL_GIT" -C "\$target" init -q
    "\$REAL_GIT" -C "\$target" remote add origin "https://github.com/your-org/hpc-skills.git"
    exit 0
fi
exec "\$REAL_GIT" "\$@"
STUB
chmod +x "$STUBS/git"

# NOCLONE stub: marks + fails any clone; delegates everything else to real git.
NOCLONE="$WORK/stub-bin-noclone"; mkdir -p "$NOCLONE"
cat > "$NOCLONE/git" <<STUB
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
if [[ "\${1-}" == "clone" ]]; then echo CLONE >> "$WORK/clone-attempts"; exit 17; fi
exec "\$REAL_GIT" "\$@"
STUB
chmod +x "$NOCLONE/git"

# FAIL stub: clone fails outright; delegates others.
FAIL_STUBS="$WORK/stub-bin-fail"; mkdir -p "$FAIL_STUBS"
cat > "$FAIL_STUBS/git" <<STUB
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
if [[ "\${1-}" == "clone" ]]; then echo "fatal: stub-git clone refused for test" >&2; exit 128; fi
exec "\$REAL_GIT" "\$@"
STUB
chmod +x "$FAIL_STUBS/git"

run_install() {
    local home="$1" bin="$2"; shift 2
    LAST_STDOUT=$(HOME="$home" NEXUS_INSTALL_LOCK_DIR="$LOCKDIR" PATH="$bin:/usr/bin:/bin" \
        bash "$INSTALL" "$@" 2>"$WORK/last.err")
    LAST_RC=$?
    LAST_STDERR=$(cat "$WORK/last.err")
}

# --- Test 1: fresh install ---------------------------------------------
echo '=== fresh install → clone + umbrella + per-sub-skill links ==='
HOME1="$WORK/home1"; mkdir -p "$HOME1"
run_install "$HOME1" "$STUBS"
assert_eq "exit 0" "$LAST_RC" "0"
assert_ok "clone landed (.git present)" test -d "$HOME1/.claude/hpc-skills/.git"
assert_ok "umbrella symlink present" test -L "$HOME1/.claude/skills/hpc-skills"
assert_ok "per-sub-skill link hpc.cluster-overview valid dir" test -d "$HOME1/.claude/skills/hpc.cluster-overview"
sublink=$(readlink "$HOME1/.claude/skills/hpc.cluster-overview" 2>/dev/null || echo missing)
assert_contains "sub-skill link resolves into clone skills/" "$sublink" "hpc-skills/skills/hpc.cluster-overview"
assert_no "no leftover temp clone" bash -c 'ls -d "$1".clone-tmp.* >/dev/null 2>&1' _ "$HOME1/.claude/hpc-skills"
run_install "$HOME1" "$NOCLONE" --check
assert_eq "--check passes on complete install" "$LAST_RC" "0"

# --- Test 2: idempotent re-run (no re-clone) ---------------------------
echo '=== idempotent re-run → exit 0, git clone NOT called ==='
rm -f "$WORK/clone-attempts"
before=$(ls -la "$HOME1/.claude/skills" | sort)
run_install "$HOME1" "$NOCLONE"
after=$(ls -la "$HOME1/.claude/skills" | sort)
assert_eq "idempotent exit 0" "$LAST_RC" "0"
assert_no "no clone attempted on re-run" test -f "$WORK/clone-attempts"
assert_eq "symlink set unchanged" "$before" "$after"

# --- Test 2b: self-heal umbrella-only → recreate per-sub-skill links ----
echo '=== self-heal: missing per-sub-skill link recreated without re-clone ==='
rm -f "$WORK/clone-attempts"
rm -f "$HOME1/.claude/skills/hpc.slurm"
run_install "$HOME1" "$NOCLONE"
assert_eq "self-heal exit 0" "$LAST_RC" "0"
assert_ok "hpc.slurm link recreated" test -d "$HOME1/.claude/skills/hpc.slurm"
assert_no "self-heal did not re-clone" test -f "$WORK/clone-attempts"

# --- Test 3: crash recovery — leftover temp clone + missing repo --------
echo '=== crash: leftover temp clone cleared + re-clone ==='
HOME3="$WORK/home3"; mkdir -p "$HOME3"
run_install "$HOME3" "$STUBS"
rm -rf "$HOME3/.claude/hpc-skills"
mkdir -p "$HOME3/.claude/hpc-skills.clone-tmp.999"; echo j > "$HOME3/.claude/hpc-skills.clone-tmp.999/x"
run_install "$HOME3" "$STUBS"
assert_eq "exit 0" "$LAST_RC" "0"
assert_no "leftover temp removed" bash -c 'ls -d "$1".clone-tmp.* >/dev/null 2>&1' _ "$HOME3/.claude/hpc-skills"
assert_ok "repo re-cloned healthy" test -d "$HOME3/.claude/hpc-skills/.git"

# --- Test 3b: crash recovery — partial non-repo dir at target -----------
echo '=== crash: partial non-repo dir moved aside + re-clone ==='
HOME3b="$WORK/home3b"; mkdir -p "$HOME3b"
run_install "$HOME3b" "$STUBS"
rm -rf "$HOME3b/.claude/hpc-skills/.git"   # leaves a non-git dir = partial
run_install "$HOME3b" "$STUBS"
assert_eq "exit 0" "$LAST_RC" "0"
assert_ok "partial moved aside (.broken.*)" bash -c 'ls -d "$1".broken.* >/dev/null 2>&1' _ "$HOME3b/.claude/hpc-skills"
assert_ok "repo healthy again" test -d "$HOME3b/.claude/hpc-skills/.git"

# --- Test 4: symlink repair / prune / foreign preservation --------------
echo '=== repair wrong link, prune dangling, preserve foreign ==='
HOME4="$WORK/home4"; mkdir -p "$HOME4"
run_install "$HOME4" "$STUBS"
ln -snf /nonexistent/wrong "$HOME4/.claude/skills/hpc.cluster-overview"             # wrong target
ln -snf "$HOME4/.claude/hpc-skills/skills/hpc.removed" "$HOME4/.claude/skills/hpc.removed"  # dangling, into our repo
ln -snf /etc/hostname "$HOME4/.claude/skills/my.custom"                            # foreign link
run_install "$HOME4" "$NOCLONE"
assert_eq "exit 0" "$LAST_RC" "0"
fixed=$(readlink "$HOME4/.claude/skills/hpc.cluster-overview" 2>/dev/null || echo missing)
assert_contains "wrong link repaired" "$fixed" "hpc-skills/skills/hpc.cluster-overview"
assert_no "dangling link pruned" test -L "$HOME4/.claude/skills/hpc.removed"
assert_ok "foreign link preserved" test -L "$HOME4/.claude/skills/my.custom"
assert_eq "foreign link untouched" "$(readlink "$HOME4/.claude/skills/my.custom")" "/etc/hostname"

# --- Test 5: concurrency — two simultaneous installs --------------------
echo '=== concurrency: two simultaneous installs → one clone, both exit 0 ==='
HOME5="$WORK/home5"; mkdir -p "$HOME5"
( run_install "$HOME5" "$STUBS"; echo $? > "$WORK/c1.rc" ) &
p1=$!
( HOME="$HOME5" NEXUS_INSTALL_LOCK_DIR="$LOCKDIR" PATH="$STUBS:/usr/bin:/bin" bash "$INSTALL" >/dev/null 2>&1; echo $? > "$WORK/c2.rc" ) &
p2=$!
wait $p1; wait $p2
assert_eq "both exit 0" "$(cat "$WORK/c1.rc")/$(cat "$WORK/c2.rc")" "0/0"
assert_ok "repo healthy" test -d "$HOME5/.claude/hpc-skills/.git"
assert_no "no leftover temp" bash -c 'ls -d "$1".clone-tmp.* >/dev/null 2>&1' _ "$HOME5/.claude/hpc-skills"
assert_no "no broken-aside dirs" bash -c 'ls -d "$1".broken.* >/dev/null 2>&1' _ "$HOME5/.claude/hpc-skills"

# --- Test 5b: held lock makes an install wait ---------------------------
echo '=== lock genuinely blocks: held lock makes install wait ==='
HOME5b="$WORK/home5b"; mkdir -p "$HOME5b"
run_install "$HOME5b" "$STUBS"   # establish healthy install (re-run will be quick no-op)
LOCKF="$LOCKDIR/nexus-install-hpc-skills.$(id -u).lock"
mkdir -p "$LOCKDIR"
( exec 9>"$LOCKF"; flock 9; sleep 2 ) &
holder=$!
sleep 0.3
t0=$(date +%s); run_install "$HOME5b" "$NOCLONE"; t1=$(date +%s)
wait $holder
assert_eq "blocked-then-succeeded exit 0" "$LAST_RC" "0"
assert_ok "waited for held lock (>=1s)" test "$(( t1 - t0 ))" -ge 1

# --- Test 6: fail-loud on clone failure ---------------------------------
echo '=== git clone fails → non-zero, no half-built symlink ==='
HOME6="$WORK/home6"; mkdir -p "$HOME6"
run_install "$HOME6" "$FAIL_STUBS"
assert_ok "non-zero exit on clone failure" test "$LAST_RC" -ne 0
assert_no "no umbrella symlink left behind" test -L "$HOME6/.claude/skills/hpc-skills"

# --- Test 7: --check fails on incomplete env ----------------------------
echo '=== --check on empty env → non-zero ==='
HOME7="$WORK/home7"; mkdir -p "$HOME7"
run_install "$HOME7" "$NOCLONE" --check
assert_ok "--check non-zero on empty env" test "$LAST_RC" -ne 0

# --- Test 8: never writes outside ~/.claude/ ----------------------------
echo '=== installer never writes outside ~/.claude/ ==='
HOME8="$WORK/home8"; mkdir -p "$HOME8"
run_install "$HOME8" "$STUBS"
strays=$(find "$HOME8" -mindepth 1 -maxdepth 1 ! -name '.claude' -print | wc -l)
assert_eq "no stray entries outside ~/.claude/" "$strays" "0"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
