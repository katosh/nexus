#!/usr/bin/env bash
# test-uv-builds-gc.sh — the orphaned uv build-dir reaper (your-org/nexus-code#1686).
#
# Hermetic: a fixture uv cache under mktemp, never the real one (the suite
# refuses to run if its cache path is not inside its own WORK dir). Live
# "holders" are processes THIS suite starts, identified by `$!` only.
#
# Pinned down:
#   dry run   is the default and deletes NOTHING (tree listing byte-identical);
#   --yes     deletes exactly the qualifying dirs, and leaves the rest;
#   kept      a young dir; a dir with an fd open in it; a dir that is a live
#             process's cwd; an environments-v2 symlink target; a symlink
#             named .tmp*; a dir newer than a live builder (a copied bash
#             named `uv`) or than a holder of the cache lock (a locker, and a
#             holder whose locker has exited);
#   freed     counts only link-count-1 files: a file hardlinked into a fake
#             archive-v0 is NOT counted, and survives the reap;
#   refused   no cache / not a uv cache ⇒ rc 3; bad --min-age ⇒ rc 2.
#
# Run: bash monitor/watcher/test-uv-builds-gc.sh

set -uo pipefail
_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_mon=$(cd "$_here/.." && pwd)
# THE SUBJECTS — called by both the population declaration and the body.
_subjects() { printf '%s\n' monitor/uv-builds-gc.sh monitor/_labsh_build_evidence.sh; }
# shellcheck disable=SC1091
. "$_mon/_guard_population.sh"
gp_population() { _subjects; }
gp_handle "$@"
# HERMETIC AGAINST THE HOST'S PROCESSES (#1703): the tool refuses (rc 3) while
# ANY live process of ours has unreadable /proc handles, and a GitHub runner
# carries one (a non-dumpable process of uid 1001), so every scan there
# refused. Run in a session of our own and scope the tool's scan to it with
# its test seam; every holder below is our descendant, and a session survives
# reparenting (the orphaned `uv run` child keeps it). `setsid` without a fork
# keeps our pid, so the runner's timeout still reaches us; -w covers the fork
# when we are a group leader (an interactive run).
if [[ "${_UVGC_TEST_IN_SESSION:-}" != 1 ]] && command -v setsid >/dev/null 2>&1; then
    export _UVGC_TEST_IN_SESSION=1
    exec setsid -w "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"
fi
# shellcheck source=_test_helpers.sh
. "$_here/_test_helpers.sh"

GC="$_mon/$(_subjects | sed -n 1p | sed 's|^monitor/||')"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/uv-builds-gc-test.XXXXXX") || exit 1
HOLDERS=()
cleanup() {
    local p
    for p in "${HOLDERS[@]+"${HOLDERS[@]}"}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
    chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT
# Out of the runner's process group now, so its timeout cannot reap the
# holders for us: clean up on a signal too.
trap 'exit 143' TERM HUP; trap 'exit 130' INT
SID=$(awk '{ sub(/^.*\) /, ""); print $4; exit }' "/proc/$$/stat" 2>/dev/null)
# The nexus BASH_ENV prelude must not re-front anything in the tool's shell;
# and nothing here may ever reach the real cache.
unset BASH_ENV ZDOTDIR NEXUS_PREV_BASH_ENV
C="$WORK/cache"
export UV_CACHE_DIR="$C" UV_OFFLINE=1 UV_BUILDS_GC_TEST_SID="$SID"
B="$C/builds-v0"
case "$(readlink -f "$C" 2>/dev/null || echo "$C")" in
    "$(readlink -f "$WORK")"/*) ;;
    *) echo "FIXTURE-BROKEN: the fixture cache is not inside WORK — refusing to run" >&2; exit 97 ;;
esac

old() { touch -d '30 days ago' "$1"; }
mkdir -p "$B" "$C/archive-v0/A" "$C/environments-v2/env1"
: > "$C/.lock"

# .tmpOLD — qualifies. One own file (100 bytes) + one file hardlinked from a
# fake archive (1000 bytes, NOT freed).
mkdir -p "$B/.tmpOLD/lib"
head -c 100 /dev/zero > "$B/.tmpOLD/lib/own"
head -c 1000 /dev/zero > "$C/archive-v0/A/shared"
ln "$C/archive-v0/A/shared" "$B/.tmpOLD/lib/shared"
old "$B/.tmpOLD"
# .tmpRO — qualifies; a read-only subdirectory (rm needs the chmod fallback).
mkdir -p "$B/.tmpRO/ro"; : > "$B/.tmpRO/ro/f"; chmod a-w "$B/.tmpRO/ro"; old "$B/.tmpRO"
# .tmpYOUNG — too young for the suite's --min-age (14 d), yet OLDER than any
# live builder (12 d), so --min-age is the ONLY rule that keeps it. Created
# "now" it would also be newer than any live uv on the host, and a disabled age
# rule would go unseen on the delete path (measured: a mutant did exactly that).
MINAGE=1209600
mkdir -p "$B/.tmpYOUNG"; touch -d '12 days ago' "$B/.tmpYOUNG"
# .tmpFD — an fd held open inside it by a live process.
mkdir -p "$B/.tmpFD"; : > "$B/.tmpFD/held"; old "$B/.tmpFD"
( exec 7<"$B/.tmpFD/held"; exec sleep 300 ) & HOLDERS+=("$!"); FD_PID=$!
# .tmpCWD — a live process's working directory.
mkdir -p "$B/.tmpCWD"; old "$B/.tmpCWD"
( cd "$B/.tmpCWD" && exec sleep 300 ) & HOLDERS+=("$!"); CWD_PID=$!
# .tmpENV — an environments-v2 symlink resolves into it.
mkdir -p "$B/.tmpENV"; ln -s "$B/.tmpENV" "$C/environments-v2/env1/abc"; old "$B/.tmpENV"
# .tmpVENV — no handle in it at all, but a live process's VIRTUAL_ENV names
# it: the shape of a `uv run --with` child whose uv parent is gone (#1701 F1).
mkdir -p "$B/.tmpVENV"; old "$B/.tmpVENV"
( cd "$WORK" && exec env VIRTUAL_ENV="$B/.tmpVENV" sleep 300 ) & HOLDERS+=("$!")
# .tmpLINK — a SYMLINK named .tmp*, pointing at a real dir outside builds-v0.
mkdir -p "$WORK/elsewhere"; : > "$WORK/elsewhere/keepme"; ln -s "$WORK/elsewhere" "$B/.tmpLINK"
sleep 0.5   # let the holders reach their exec

listing() { find "$WORK" -printf '%p %y %n\n' | LC_ALL=C sort; }
assert_eq "fixture precondition: the suite leads its own session (setsid present)" "$SID" "$$"
assert_eq "fixture precondition: the fd holder has the file open" \
    "$(find "/proc/$FD_PID/fd" -type l -printf '%l\n' 2>/dev/null | grep -cxF "$B/.tmpFD/held")" "1"
assert_eq "fixture precondition: the cwd holder sits in .tmpCWD" \
    "$(readlink "/proc/$CWD_PID/cwd" 2>/dev/null)" "$(readlink -f "$B/.tmpCWD")"

echo "## refusals"
"$GC" --cache "" >/dev/null 2>&1; assert_eq "no cache ⇒ rc 3 REFUSED" "$?" "3"
"$GC" --cache "$WORK/elsewhere" >/dev/null 2>&1; assert_eq "a dir with no builds-v0 ⇒ rc 3 REFUSED" "$?" "3"
"$GC" --cache "$C" --min-age soon >/dev/null 2>&1; assert_eq "a non-integer --min-age ⇒ rc 2" "$?" "2"

echo "## an unreadable live process: refused in scope, ignored out of scope (#1703)"
# A NON-DUMPABLE process of ours: /proc/<pid>/cwd, fd and environ become
# root-owned, so its handles cannot be read — the GitHub runner's shape.
# One line: test-empty-needle-vacuous-helpers' definition parser cannot
# confirm a function whose body spans lines inside a quoted string.
nondumpable() { exec python3 -c 'import ctypes, time; ctypes.CDLL(None).prctl(4, 0, 0, 0, 0); time.sleep(300)'; }   # 4 = PR_SET_DUMPABLE
( nondumpable ) & HOLDERS+=("$!"); ND_IN=$!
setsid bash -c "$(declare -f nondumpable); nondumpable" & HOLDERS+=("$!"); ND_OUT=$!
sleep 1
assert_eq "fixture precondition: both planted processes have unreadable cwds" \
    "$(readlink "/proc/$ND_IN/cwd" >/dev/null 2>&1 || readlink "/proc/$ND_OUT/cwd" >/dev/null 2>&1 || echo unreadable)" "unreadable"
out=$("$GC" --cache "$C" --min-age "$MINAGE" --no-sizes 2>&1); rc=$?
assert_eq "an unreadable live process IN scope ⇒ rc 3 REFUSED, fail-closed (planted)" "$rc" "3"
assert_contains "the refusal names the unreadable pid" "$out" "unreadable /proc handles (pid $ND_IN "
kill "$ND_IN" 2>/dev/null; wait "$ND_IN" 2>/dev/null
out=$("$GC" --cache "$C" --min-age "$MINAGE" --no-sizes 2>&1); rc=$?
assert_eq "the same shape OUTSIDE the scanned session does not refuse (planted)" "$rc" "0"
assert_contains "the header names the test seam" "$out" "scan-scope=TEST-SEAM-session:$SID"
kill "$ND_OUT" 2>/dev/null; wait "$ND_OUT" 2>/dev/null

echo "## dry run (the default) deletes nothing and names exactly the qualifying dirs"
before=$(listing)
out=$("$GC" --cache "$C" --min-age "$MINAGE"); rc=$?
after=$(listing)
assert_eq "dry run rc 0" "$rc" "0"
assert_eq "dry run: the tree is byte-identical afterwards" "$after" "$before"
assert_contains "header says DRY-RUN" "$out" "DRY-RUN"
line() { printf '%s\n' "$out" | awk -F'\t' -v p="$B/$1" '$2 == p'; }
assert_contains ".tmpOLD would be reaped" "$(line .tmpOLD)" "would-reap"
assert_contains ".tmpOLD freed counts only the link-count-1 file (100 bytes, not the shared 1000)" "$(line .tmpOLD)" "freed=100"
assert_contains ".tmpRO would be reaped" "$(line .tmpRO)" "would-reap"
assert_contains ".tmpYOUNG kept: too young" "$(line .tmpYOUNG)" "younger than --min-age"
assert_contains ".tmpFD kept: an fd is open in it (planted)" "$(line .tmpFD)" "held open by a live process"
assert_contains ".tmpCWD kept: a live cwd (planted)" "$(line .tmpCWD)" "held open by a live process"
assert_contains ".tmpVENV kept: a live process's VIRTUAL_ENV is inside it (planted)" "$(line .tmpVENV)" "held open by a live process"
assert_contains ".tmpENV kept: an environments-v2 target" "$(line .tmpENV)" "environments-v2 symlink"
assert_contains ".tmpLINK kept: not a real directory" "$(line .tmpLINK)" "not a real directory"
assert_contains "total: 8 dirs, 2 qualifying" "$out" "8 dirs, 2 qualifying, 0 reaped"
assert_contains "total states du as the UPPER bound" "$out" "UPPER bound"

echo "## the builder gate: a dir newer than a live uv builder or cache-lock holder is kept"
cp "$(command -v bash)" "$WORK/uv"
( cd "$WORK" && exec "$WORK/uv" -c 'while :; do sleep 1; done' ) & HOLDERS+=("$!"); UV_PID=$!
# Two lock holders. A process that TOOK the lock and holds it (/proc/locks
# names it), and one that holds the lock through an fd whose locker — the
# `flock` utility — has already exited, so /proc/locks names a DEAD pid and
# only the handle scan can find the holder.
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_SH); time.sleep(300)' "$C/.lock" & HOLDERS+=("$!"); LOCK_PID=$!
( exec 8>>"$C/.lock"; flock -s 8 && exec sleep 300 ) & HOLDERS+=("$!"); LOCKFD_PID=$!
sleep 1
assert_eq "fixture precondition: the fake builder's exe is 'uv'" "$(basename "$(readlink "/proc/$UV_PID/exe" 2>/dev/null)")" "uv"
mkdir -p "$B/.tmpNEW"   # created AFTER the builders started
out=$("$GC" --cache "$C" --min-age 0 --no-sizes); rc=$?
assert_eq "builder-gate dry run rc 0" "$rc" "0"
hdr=$(printf '%s\n' "$out" | sed -n 1p)
assert_contains "the copied-bash 'uv' is counted as a builder (exe, never argv)" ",$(printf '%s' "$hdr" | sed -n 's/.* builders=\([^ ]*\) .*/\1/p')," ",$UV_PID,"
builders=",$(printf '%s' "$hdr" | sed -n 's/.* builders=\([^ ]*\) .*/\1/p'),"
assert_contains "a process holding the cache lock is counted as a builder" "$builders" ",$LOCK_PID,"
assert_contains "a holder whose LOCKER has exited is counted too (fd on .lock, planted)" "$builders" ",$LOCKFD_PID,"
assert_contains ".tmpNEW kept: not older than a live builder (planted)" "$(line .tmpNEW)" "not older than a live builder"
rm -rf "$B/.tmpNEW"

echo "## --yes REFUSES while the cache is in use (uv's own exclusive lock)"
before=$(listing)
out=$("$GC" --cache "$C" --min-age "$MINAGE" --yes 2>&1); rc=$?
assert_eq "--yes with a shared lock held on .lock ⇒ rc 3 REFUSED (planted)" "$rc" "3"
assert_contains "the refusal says the cache is in use" "$out" "IN USE"
assert_eq "a refused --yes deletes nothing" "$(listing)" "$before"
# Release the cache lock for the reap below; the fake `uv` builder stays.
kill "$LOCK_PID" "$LOCKFD_PID" 2>/dev/null; wait "$LOCK_PID" "$LOCKFD_PID" 2>/dev/null

# ── #1701 F1, the skeptic's repro with a REAL uv: a `uv run --with` child whose
# uv parent was SIGKILLed keeps running from builds-v0/.tmp*, holding no cwd,
# fd or map there, and no lock. RED at e8619848 (reaped at rc 0, then the child
# hit FileNotFoundError); it must be KEPT. Needs `uv` on PATH; offline, with a
# hand-built wheel, against the fixture cache only.
UVRUN=0
if command -v uv >/dev/null 2>&1; then
    WH="$WORK/wheel"; mkdir -p "$WH/src/tinypkg" "$WH/src/tinypkg-0.1.dist-info"
    echo 'X = 1' > "$WH/src/tinypkg/__init__.py"
    printf 'Metadata-Version: 2.1\nName: tinypkg\nVersion: 0.1\n' > "$WH/src/tinypkg-0.1.dist-info/METADATA"
    printf 'Wheel-Version: 1.0\nGenerator: test\nRoot-Is-Purelib: true\nTag: py3-none-any\n' > "$WH/src/tinypkg-0.1.dist-info/WHEEL"
    printf 'tinypkg/__init__.py,,\ntinypkg-0.1.dist-info/METADATA,,\ntinypkg-0.1.dist-info/WHEEL,,\ntinypkg-0.1.dist-info/RECORD,,\n' > "$WH/src/tinypkg-0.1.dist-info/RECORD"
    python3 -c 'import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w") as z:
    for r, _, fs in os.walk(src):
        for f in fs:
            p = os.path.join(r, f); z.write(p, os.path.relpath(p, src))' "$WH/src" "$WH/tinypkg-0.1-py3-none-any.whl"
    ( cd "$WORK" && exec uv run --no-project --offline --find-links "$WH" --with tinypkg python -c 'import os, sys, time
print(os.getpid(), os.getppid(), sys.prefix, flush=True)
for _ in range(600):
    open(os.path.join(sys.prefix, "pyvenv.cfg")).read(); time.sleep(0.5)' ) > "$WORK/uvrun.out" 2> "$WORK/uvrun.err" &
    HOLDERS+=("$!")
    for _ in $(seq 1 60); do [[ -s "$WORK/uvrun.out" ]] && break; sleep 0.5; done
    read -r UVC_PID UVP_PID UVC_PREFIX < "$WORK/uvrun.out" 2>/dev/null
    if [[ "$UVC_PREFIX" == "$B/.tmp"* && -d "$UVC_PREFIX" && "$UVC_PID" =~ ^[0-9]+$ ]]; then
        UVRUN=1; HOLDERS+=("$UVC_PID")
        kill -9 "$UVP_PID" 2>/dev/null; sleep 0.5
        old "$UVC_PREFIX"
        assert_eq "fixture precondition: the uv parent is gone and the child lives" \
            "$([[ ! -d /proc/$UVP_PID && -d /proc/$UVC_PID ]] && echo yes)" "yes"
        assert_eq "fixture precondition: the child holds NO cwd/fd/map in its env" \
            "$( { readlink "/proc/$UVC_PID/cwd"; find "/proc/$UVC_PID/fd" -type l -printf '%l\n'; awk '{print $6}' "/proc/$UVC_PID/maps"; } 2>/dev/null | grep -cF "$UVC_PREFIX")" "0"
    else
        echo "  SKIP: uv run fixture did not start — the real-uv F1 case is UNMEASURED here. Its stderr:" >&2
        sed 's/^/        | /' "$WORK/uvrun.err" >&2
    fi
else
    echo "  SKIP: no uv on PATH — the real-uv F1 case is UNMEASURED here" >&2
fi

echo "## --yes deletes exactly the qualifying dirs"
out=$("$GC" --cache "$C" --min-age "$MINAGE" --yes); rc=$?
assert_eq "--yes rc 0" "$rc" "0"
assert_contains "header says REAP" "$out" "REAP"
assert_contains ".tmpOLD reaped" "$(line .tmpOLD)" "reaped"
assert_contains ".tmpRO reaped (read-only subdir handled)" "$(line .tmpRO)" "reaped"
assert_eq ".tmpOLD is gone" "$([[ -e "$B/.tmpOLD" ]] && echo present || echo gone)" "gone"
assert_eq ".tmpRO is gone" "$([[ -e "$B/.tmpRO" ]] && echo present || echo gone)" "gone"
for k in .tmpYOUNG .tmpFD .tmpCWD .tmpENV .tmpVENV; do
    assert_eq "$k survives --yes" "$([[ -d "$B/$k" ]] && echo present || echo gone)" "present"
done
assert_eq ".tmpLINK (a symlink) survives, and so does what it points at" \
    "$([[ -L "$B/.tmpLINK" && -e "$WORK/elsewhere/keepme" ]] && echo present || echo gone)" "present"
assert_eq "the archive's hardlinked file survives the reap" "$(cat "$C/archive-v0/A/shared" | wc -c | tr -d ' ')" "1000"
assert_contains "total: 2 reaped, 0 failed" "$out" "2 reaped, 0 failed"
if (( UVRUN )); then
    assert_eq "#1701 F1: the orphaned uv-run child's env survives --yes" "$([[ -d "$UVC_PREFIX" ]] && echo present || echo gone)" "present"
    sleep 1
    assert_eq "#1701 F1: …and the child is still running from it" "$([[ -d /proc/$UVC_PID ]] && echo alive || echo dead)" "alive"
    assert_eq "#1701 F1: the child never hit a missing env" "$(grep -c FileNotFoundError "$WORK/uvrun.err")" "0"
fi

echo "## a second --yes run is a no-op"
out=$("$GC" --cache "$C" --min-age "$MINAGE" --yes); rc=$?
assert_eq "second run rc 0" "$rc" "0"
assert_contains "nothing left to reap" "$out" "0 qualifying, 0 reaped"

# EXACT assertion total: an assertion lost to a subshell or early exit is RED.
_EXPECTED_ASSERTIONS=$(( 50 + 5 * UVRUN ))
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2; _th_fail
fi
th_summary_and_exit
