#!/usr/bin/env bash
# Tests for monitor/evidence-freeze.sh — the durable-evidence freeze guard.
#
# Run: bash monitor/test-evidence-freeze.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE CONTRACT UNDER TEST. A freeze exists to prove afterwards that
# nothing was lost. The hand-rolled form it replaces —
#
#     cp -p <artefact> "$EV/<name>"
#     cd "$EV" && md5sum *.ipynb > MANIFEST.md5 && md5sum -c MANIFEST.md5
#
# — destroys the baseline and regenerates the checksum that would have
# caught it, in one command, so `md5sum -c` reports OK on the wrong
# bytes. Section "the incident, replayed" below runs exactly that
# sequence against the guard and asserts the baseline survives.
#
# Every assertion here was watched fail against a mutated script before
# it was trusted (see the mutation table in the PR body). Forty-six
# mutations are on record and every one turns at least one case RED,
# plus 47 more from an independent skeptic sweep in round 5.
#
# A SUITE WITH NO SURVIVING MUTANT IS A CLAIM, NOT A FACT, and on this
# file the claim has failed three times. Read that before adding a case.
#
#   Round 1. The first version claimed no survivors. A skeptic found
#   three: the evidence directory's mode, the failed-copy path, and the
#   append-failure path. Cases 12, 13 and 14 exist because of that.
#
#   Round 2. The second version claimed it again, over thirteen
#   mutations. A skeptic found four more: both places that read the GNU
#   binary name form `<hash> *name`, the dotfile case, and the
#   "no name is exempt" rule. Cases 17 and 18 exist because of that.
#
#   Round 3. Case 19 was added for path-qualified manifest rows, and
#   its basename fallback then MASKED an existing mutation: deleting the
#   `./` normalisation from `_manifest_records` no longer turned case 10
#   RED, because the fallback quietly covered for it. A new assertion
#   can subtract coverage. Cases 11b and 11c pin the two paths apart.
#
#   Round 4. Option B was built: the out-of-band freeze log. The first
#   version of cases 20 to 28 claimed no survivors over eighteen new
#   mutations. Four survived. Every one of the four was a FALSE CLEAN —
#   a directory reported clean whose bytes had changed — which is the
#   one failure mode this whole check exists to remove:
#
#     * `_json_escape` losing its backslash branch. Cases 20 to 29 all
#       used paths with no backslash in them. Case 30.
#     * `_abs_dir` returning its argument unchanged. Every case handed
#       the SAME absolute path to both sides, so the two agreed by
#       accident. Case 32.
#     * the `--verify` shared lock, which nothing sequential can see.
#       Case 31 blocks the lock and times the wait.
#     * the JSON extractor's key-boundary rule. The first attempt at
#       case 29 could not kill it, because this script escapes every
#       value it writes, so no line it writes can hold the decoy. The
#       rule guards a HAND-EDITED row, and case 29b is that row.
#
#   Round 5. A depth-1 skeptic ran an INDEPENDENT sweep of 47 mutations
#   against round 4's suite and found seven survivors. Five are closed by
#   cases 33 and 34, and they fall into two groups.
#
#   Three sat on the freeze log's WRITE side. Exit 8 documents two
#   meanings, and only one of them was pinned: "the record and the
#   directory disagree" had eight assertions, "a freeze could not be
#   recorded out of band" had none. Exit 7 on the log's own mode had none
#   either. The asymmetry should have been visible from this file alone —
#   cases 15 and 16 already force a chmod failure for the frozen copy and
#   for MANIFEST.md5, and nothing did the same for the log.
#
#   Survivor 6 was the sharpest of the seven, and it is the same shape a
#   third time. Case 9 checked that `--as sub/dir.txt` exits 2. It could
#   not fail: with `$W/ev/sub` absent, a script with the path-separator
#   guard DELETED falls through to `cp`, the copy fails because the
#   directory is not there, and it exits 2 as well. Same code, wrong
#   reason. With the sub-directory PRESENT the guardless script SUCCEEDS,
#   and the result is the worst false clean this suite knows: the freeze
#   lands below `--verify`'s maxdepth-1 horizon, so the coverage
#   denominator is zero and the verdict reads `covers 0 of 0`. Zero of
#   zero cannot warn anybody. Case 9 now asserts the MESSAGE and repeats
#   the call with the sub-directory present.
#
#   Survivor 7 was fixture breadth, and the skeptic calibrated it before
#   reporting it: exempting `README` survived, exempting the fixture's own
#   `README-NOTES.md` was killed. Case 18 pinned one string, not the rule.
#   It now loops over five note names.
#
#   Two more were round 4's own lesson, repeated in the file that
#   records it. `window` had no assertion. `src` HAD one, in case 20, and
#   it could not fail: that fixture's source path is already absolute and
#   canonical, so `readlink -f` is a no-op on it. An assertion that cannot
#   distinguish is not coverage. Case 34 freezes through a symlink and by
#   a relative path, and builds its expected value with `pwd -P` so it
#   does not restate the call under test.
#
# Round 4 also cost the script a real bug that no mutation found, but
# that writing case 30 did: `awk -v want="$path"` runs the value through
# awk's escape processing, so an evidence directory whose path held a
# backslash never joined to its own log rows. It reported "0 of 1
# recorded out of band" on a file it had just frozen. All three `awk`
# readers now take the value through `ENVIRON` instead.
#
# The pattern in the first two rounds is the same. Each author wrote the
# mutations that matched what they had just been thinking about, then
# read a green suite as coverage. The four in round 2 all sat on
# behaviour the script header states as a PROMISE, and none of the
# promises had an assertion behind them.
#
# Three rules follow. Round 3 is why the second one is here, round 4 the
# third:
#
#   1. If you add a promise to the script header, add the case that
#      fails when it stops being true.
#   2. If you add a fallback, re-run the WHOLE mutation set, not just
#      the mutations for the code you added. A fallback that makes a
#      failing path succeed also makes a deleted check invisible.
#   3. Vary the FIXTURE, not only the code. Three of round 4's four
#      survivors lived in code that every case executed. They survived
#      because every case fed that code the same SHAPE of input: an
#      absolute path, holding no backslash, read by one process at a
#      time. Ask what all your fixtures have in common, then write the
#      case that does not. Round 5 broke this rule again, in this very
#      file: `src` had an assertion that could not fail, because its
#      fixture path was already canonical.
#   4. Cover every meaning of an exit code, not just the interesting
#      one. Exit 8 documents two, and round 4 pinned one. When you add a
#      meaning to a code, grep this file for the OTHER meanings and
#      check each has a case. Round 5's three write-side survivors were
#      all one unpinned meaning.
#
# Hermetic: everything happens under a fresh mktemp -d. No tmux, no
# network, no state outside the temp dir.
#
# Root note: three cases assert that the KERNEL refuses a write to a
# mode-0440 file. Root bypasses that check, so those cases self-skip
# under EUID 0 rather than reporting a false PASS. Cases 15 and 16 skip
# under root for the same reason.
#
# Two cases need a write to fail. `ulimit -f 0` lets a file be created
# and then fails the first byte written, which is how cases 13 and 14
# reach the failure paths. RLIMIT_FSIZE is not enforced on every
# filesystem, so those cases self-skip rather than pass when the limit
# does not bite.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FREEZE_BIN="${FREEZE_BIN:-$_test_dir/evidence-freeze.sh}"

PASS=0
FAIL=0
SKIP=0

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
    local label="$1" haystack="$2" needle="$3"
    # An empty needle matches everything, so it could only pass vacuously.
    if [[ -n "$needle" && "$haystack" == *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — %q not found in %q\n' "$label" "$needle" "$haystack" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

assert_not_contains() {
    local label="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — %q was present in %q\n' "$label" "$needle" "$haystack" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

skip() {
    printf '  SKIP: %s\n' "$1"; SKIP=$(( SKIP + 1 ))
}

TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# The out-of-band freeze log MUST be inside the temp dir, or the suite
# writes rows into the live `monitor/.state/` on every run. Most cases
# pass `--dir` with no `NEXUS_STATE_DIR`, and the script's state-dir
# fallback is its OWN directory, so without this export the suite is
# not hermetic. One log for the whole suite is also the realistic
# shape: one shared record, many evidence directories.
export NEXUS_FREEZE_LOG="$TMP/freeze-log.jsonl"

md5of() { md5sum < "$1" | cut -d' ' -f1; }

# Rows in the freeze log for one evidence directory, resolved the same
# way the script resolves it.
# `grep -c` prints 0 AND exits 1 on no match, so an `|| echo 0` fallback
# emits TWO zeroes. Count the lines instead.
freeze_log_rows() {
    local d; d=$(cd "$1" && pwd -P)
    command grep "\"dir\":\"$d\"" "$NEXUS_FREEZE_LOG" 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
echo "=== 1. a first freeze writes a read-only copy and an append-only manifest"
# ---------------------------------------------------------------------------
W="$TMP/w1"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")

out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1); rc=$?
assert_eq "first freeze exits 0" "$rc" "0"
assert_eq "frozen bytes match the source" "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
assert_eq "frozen copy is mode 0440" "$(stat -c '%a' "$W/ev/nb.PRE.txt")" "440"
assert_eq "manifest is mode 0440" "$(stat -c '%a' "$W/ev/MANIFEST.md5")" "440"
assert_eq "manifest has exactly one row" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"
assert_contains "manifest records the source hash" \
    "$(cat "$W/ev/MANIFEST.md5")" "$BASE_MD5  nb.PRE.txt"
assert_contains "stdout names the mode" "$out" "0440"

# ---------------------------------------------------------------------------
echo "=== 2. the copy is NOT cp -p: the frozen mtime is the freeze time"
# ---------------------------------------------------------------------------
# `cp -p` carried the SOURCE mtime, so a substituted freeze did not even
# look freshly written. The freeze time must be readable off the file.
W="$TMP/w2"; mkdir -p "$W/code"
printf 'OLD\n' > "$W/code/nb.txt"
touch -d '2001-02-03 04:05:06' "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
src_mtime=$(stat -c '%Y' "$W/code/nb.txt")
frz_mtime=$(stat -c '%Y' "$W/ev/nb.PRE.txt")
if (( frz_mtime > src_mtime )); then
    assert_eq "frozen mtime is later than the source mtime" "later" "later"
else
    assert_eq "frozen mtime is later than the source mtime" "src=$src_mtime frz=$frz_mtime" "later"
fi

# ---------------------------------------------------------------------------
echo "=== 3. a second freeze under the same name is REFUSED, not an overwrite"
# ---------------------------------------------------------------------------
W="$TMP/w3"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'REPLACEMENT\n' > "$W/code/nb.txt"

out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1); rc=$?
assert_eq "clobbering freeze exits 3" "$rc" "3"
assert_contains "refusal names the file" "$out" "nb.PRE.txt already exists"
assert_contains "refusal prints the existing hash" "$out" "$BASE_MD5"
assert_eq "baseline bytes are untouched" "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
assert_eq "manifest still has one row" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"

# ---------------------------------------------------------------------------
echo "=== 4. the incident, replayed: cp -p + manifest regeneration"
# ---------------------------------------------------------------------------
# The exact two-line sequence that destroyed fb2c326b on 2026-09-09,
# run against a freeze this script wrote. Both halves must fail.
W="$TMP/w4"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'REPLACEMENT\n' > "$W/code/nb.txt"

if (( EUID == 0 )); then
    skip "raw cp over a freeze fails (root bypasses mode 0440)"
    skip "manifest regeneration fails (root bypasses mode 0440)"
    skip "md5sum -c still reports the baseline (root)"
else
    cp_err=$(cp -p "$W/code/nb.txt" "$W/ev/nb.PRE.txt" 2>&1); cp_rc=$?
    assert_eq "raw cp -p over a freeze fails" "$cp_rc" "1"
    assert_contains "cp failure names permission" "$cp_err" "Permission denied"

    regen_rc=0
    ( cd "$W/ev" && md5sum ./*.txt > MANIFEST.md5 ) 2>/dev/null || regen_rc=$?
    if (( regen_rc != 0 )); then
        assert_eq "manifest regeneration fails" "failed" "failed"
    else
        assert_eq "manifest regeneration fails" "succeeded" "failed"
    fi

    assert_eq "baseline survives the replayed incident" \
        "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
    ( cd "$W/ev" && md5sum -c MANIFEST.md5 >/dev/null 2>&1 ); chk_rc=$?
    assert_eq "md5sum -c still passes on the true baseline" "$chk_rc" "0"
fi

# ---------------------------------------------------------------------------
echo "=== 5. a second, differently-named freeze APPENDS; the first row survives"
# ---------------------------------------------------------------------------
W="$TMP/w5"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
first_row=$(head -1 "$W/ev/MANIFEST.md5")
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.POST.txt 2>&1); rc=$?
assert_eq "second freeze under a new name exits 0" "$rc" "0"
assert_eq "manifest now has two rows" "$(wc -l < "$W/ev/MANIFEST.md5")" "2"
assert_eq "the first row is byte-identical" "$(head -1 "$W/ev/MANIFEST.md5")" "$first_row"
assert_eq "manifest is read-only again after the append" \
    "$(stat -c '%a' "$W/ev/MANIFEST.md5")" "440"

# ---------------------------------------------------------------------------
echo "=== 6. a manifest entry whose file was removed still blocks the name"
# ---------------------------------------------------------------------------
W="$TMP/w6"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
chmod u+w "$W/ev/nb.PRE.txt"; rm -f "$W/ev/nb.PRE.txt"
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1); rc=$?
assert_eq "re-using a recorded name exits 4" "$rc" "4"
assert_contains "refusal names the manifest" "$out" "MANIFEST.md5 already records"
assert_eq "manifest still has one row" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"

# A name that merely CONTAINS a recorded name must still be freezable.
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt.bak 2>&1); rc=$?
assert_eq "a superstring name is not blocked" "$rc" "0"

# ---------------------------------------------------------------------------
echo "=== 7. --verify reports the three invariants"
# ---------------------------------------------------------------------------
W="$TMP/w7"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of a clean dir exits 0" "$rc" "0"
assert_contains "verify says clean" "$out" "verified clean"

# (a) content substituted behind the guard's back → checksum mismatch
chmod u+w "$W/ev/nb.PRE.txt"
printf 'SUBSTITUTED\n' > "$W/ev/nb.PRE.txt"
chmod 0440 "$W/ev/nb.PRE.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of substituted content exits 5" "$rc" "5"
assert_contains "verify names the mismatch" "$out" "CHECKSUM MISMATCH"

# (b) a writable freeze is reported even when its checksum matches
W="$TMP/w7b"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
chmod u+w "$W/ev/nb.PRE.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of a writable freeze exits 5" "$rc" "5"
assert_contains "verify names the writable file" "$out" "WRITABLE freeze: nb.PRE.txt"

# (c) a writable manifest is reported on its own
W="$TMP/w7c"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
chmod u+w "$W/ev/MANIFEST.md5"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of a writable manifest exits 5" "$rc" "5"
assert_contains "verify names the writable manifest" "$out" "WRITABLE MANIFEST.md5"

# ---------------------------------------------------------------------------
echo "=== 8. --task resolves under the state dir"
# ---------------------------------------------------------------------------
W="$TMP/w8"; mkdir -p "$W/code" "$W/state"
printf 'BASELINE\n' > "$W/code/nb.txt"
out=$(NEXUS_STATE_DIR="$W/state" "$FREEZE_BIN" "$W/code/nb.txt" --task issue70 --as nb.PRE.txt 2>&1); rc=$?
assert_eq "--task freeze exits 0" "$rc" "0"
assert_eq "--task wrote under \$NEXUS_STATE_DIR/evidence/<slug>" \
    "$(stat -c '%a' "$W/state/evidence/issue70/nb.PRE.txt" 2>/dev/null)" "440"

# ---------------------------------------------------------------------------
echo "=== 9. usage errors are loud and write nothing"
# ---------------------------------------------------------------------------
W="$TMP/w9"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"

"$FREEZE_BIN" --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "no source exits 2" "$rc" "2"

"$FREEZE_BIN" "$W/code/missing.txt" --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "unreadable source exits 2" "$rc" "2"

# --as with a path separator. The exit code ALONE cannot pin this, and for
# a long time that is all this case checked. With `$W/ev/sub` absent, a
# script missing the guard falls through to `cp`, the copy fails because
# the directory does not exist, and it exits 2 as well — same code, wrong
# reason. So assert the MESSAGE, and run the case again below with the
# sub-directory PRESENT, where a missing guard cannot fail by accident.
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as sub/dir.txt 2>&1); rc=$?
assert_eq "--as with a path separator exits 2" "$rc" "2"
assert_contains "--as refusal names the reason, not just the code" \
    "$out" "takes a bare file name, not a path"

# The same call where the sub-directory EXISTS. Without the guard this
# SUCCEEDS, and the result is the worst false clean this suite knows: the
# freeze lands at `ev/sub/dir.txt`, the manifest records the name
# `sub/dir.txt`, and `--verify` walks top-level files only — so the frozen
# file sits below its horizon, the coverage denominator is 0, and the
# verdict reads `verified clean (freeze-log covers 0 of 0)`. Zero of zero
# is the one shape that cannot warn anybody.
W="$TMP/w9b"; mkdir -p "$W/code" "$W/ev/sub"
printf 'BASELINE\n' > "$W/code/nb.txt"
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as sub/dir.txt 2>&1); rc=$?
assert_eq "--as with a path separator exits 2 even when the sub-dir exists" "$rc" "2"
assert_contains "and names the reason there too" "$out" "takes a bare file name, not a path"
assert_eq "nothing was written anywhere under the evidence dir" \
    "$(find "$W/ev" -type f | wc -l)" "0"
assert_eq "and no row was recorded out of band" "$(freeze_log_rows "$W/ev")" "0"
W="$TMP/w9"

"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as MANIFEST.md5 >/dev/null 2>&1; rc=$?
assert_eq "--as MANIFEST.md5 exits 2" "$rc" "2"

"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --task t >/dev/null 2>&1; rc=$?
assert_eq "--task with --dir exits 2" "$rc" "2"

"$FREEZE_BIN" --verify --dir "$TMP/does-not-exist" >/dev/null 2>&1; rc=$?
assert_eq "verify of a missing dir exits 2" "$rc" "2"

mkdir -p "$W/empty"
"$FREEZE_BIN" --verify --dir "$W/empty" >/dev/null 2>&1; rc=$?
assert_eq "verify of a dir with no manifest exits 5" "$rc" "5"

# ---------------------------------------------------------------------------
echo "=== 10. remove-and-recreate is DETECTED, out of band (option B)"
# ---------------------------------------------------------------------------
# This case used to pin remove-and-recreate as WORKING. Option B is now
# built, so it pins the same sequence as DETECTED. It was written to
# turn RED exactly when the guard was hardened, and it did.
#
# Read the two halves apart, because the difference is the whole claim
# of option B:
#
#   PREVENTION — unchanged. Mode 0440 stops a WRITE, not an UNLINK. The
#   evidence directory is still mode 0770, the `rm` still succeeds, and
#   the substituted bytes really are what is stored afterwards. Nothing
#   in option B stops any of that, and the assertions below say so.
#
#   DETECTION — new. The rebuilt directory is INTERNALLY CONSISTENT: a
#   bare `md5sum -c` inside it passes, because the manifest was
#   regenerated over the new bytes. Every check that reads only this
#   directory is satisfied. `--verify` fails anyway, with exit 8,
#   because the hash recorded OUTSIDE the directory is the baseline's.
W="$TMP/w10"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
REPL_MD5=$(md5of "$W/code/nb.txt")

rm -f "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"; rm_rc=$?
assert_eq "rm of a mode-0440 freeze still succeeds (dir is writable)" "$rm_rc" "0"
cp -p "$W/code/nb.txt" "$W/ev/nb.PRE.txt"
( cd "$W/ev" && md5sum ./*.txt > MANIFEST.md5 )  # nb.PRE.txt: cp -p above
chmod 0440 "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"

# The rebuilt directory passes every check that reads only itself.
( cd "$W/ev" && md5sum -c MANIFEST.md5 >/dev/null 2>&1 ); chk_rc=$?
assert_eq "the rebuilt directory is internally consistent" "$chk_rc" "0"

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify of a remove-and-recreate exits 8" "$rc" "8"
assert_contains "verify names the freeze-log mismatch" "$out" "FREEZE-LOG MISMATCH: nb.PRE.txt"
assert_contains "verify prints the hash recorded out of band" "$out" "$BASE_MD5"
assert_contains "verify prints the hash now on disk" "$out" "$REPL_MD5"

# Detection, not prevention. The bytes really were replaced.
assert_eq "the substituted bytes are still what is stored" \
    "$(md5of "$W/ev/nb.PRE.txt")" "$REPL_MD5"

# ---------------------------------------------------------------------------
echo "=== 11. --verify refuses a file the manifest does not record"
# ---------------------------------------------------------------------------
# `md5sum -c` walks the manifest, so it is blind in the other direction:
# bytes present under an unrecorded name passed every check. Top-level
# regular files only, and no name is exempt.
W="$TMP/w11"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1

printf 'NOBODY RECORDED ME\n' > "$W/ev/rogue.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify with an unrecorded file exits 6" "$rc" "6"
assert_contains "verify names the unrecorded file" "$out" "UNRECORDED file: rogue.txt"
assert_contains "verify does not call the dir clean" "$out" "unrecorded file(s)"

# Freezing it records it, and the directory is clean again.
"$FREEZE_BIN" "$W/ev/rogue.txt" --dir "$W/ev" --as rogue.FROZEN.txt >/dev/null 2>&1
rm -f "$W/ev/rogue.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "verify is clean once every file is recorded" "$rc" "0"

# A sub-directory is NOT walked: a bare name in a manifest cannot
# address one, so it could not be recorded even in principle.
mkdir -p "$W/ev/notes" && printf 'a note\n' > "$W/ev/notes/README.md"
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "a file inside a sub-directory does not trip exit 6" "$rc" "0"

# Exit 5 wins over exit 6: a broken invariant is the graver finding.
chmod u+w "$W/ev/MANIFEST.md5"
printf 'ROGUE AGAIN\n' > "$W/ev/rogue2.txt"
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "a broken invariant outranks an unrecorded file" "$rc" "5"

# A manifest written by hand as `md5sum ./*.txt` records `./nb.txt`.
# That is the same file, so it must not read as unrecorded.
W="$TMP/w11b"; mkdir -p "$W/ev"
printf 'BASELINE\n' > "$W/ev/nb.txt"
( cd "$W/ev" && md5sum ./*.txt > MANIFEST.md5 )  # nb.txt: printf above
chmod 0440 "$W/ev/nb.txt" "$W/ev/MANIFEST.md5"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a ./-prefixed manifest name counts as recorded" "$rc" "0"

# `./name` is a BARE name, so `_manifest_records` must read it directly.
# Without these two, the basename fallback added for path-qualified rows
# silently covers for it and the `./` normalisation can be deleted with
# the suite still green. Both assertions distinguish the two paths.
assert_not_contains "a ./ name is read as bare, not as path-qualified" \
    "$out" "path-qualified"

W="$TMP/w11c"; mkdir -p "$W/code" "$W/ev"
printf 'BASELINE\n' > "$W/code/nb.txt"
cp "$W/code/nb.txt" "$W/ev/nb.txt"
( cd "$W/ev" && md5sum ./*.txt > MANIFEST.md5 )  # nb.txt: cp above
rm -f "$W/ev/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.txt >/dev/null 2>&1; rc=$?
assert_eq "a ./-recorded name still blocks a re-freeze with exit 4" "$rc" "4"

# ---------------------------------------------------------------------------
echo "=== 12. the evidence directory is created mode 0770, whatever the umask"
# ---------------------------------------------------------------------------
# The bypass in case 10 walks through the DIRECTORY's mode, and nothing
# asserted it. `mkdir -m` also makes the mode independent of the
# caller's umask, so this is a fact about the script, not the caller.
W="$TMP/w12"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
( umask 000; "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1 )
assert_eq "a created evidence dir is mode 0770 under umask 000" \
    "$(stat -c '%a' "$W/ev")" "770"

W="$TMP/w12b"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
( umask 022; "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1 )
assert_eq "a created evidence dir is mode 0770 under umask 022" \
    "$(stat -c '%a' "$W/ev")" "770"

# An EXISTING directory keeps its own mode: `mkdir -m` applies only to
# directories it creates. Freezing must not re-permission a live dir.
W="$TMP/w12c"; mkdir -p "$W/code"; mkdir -m 0700 "$W/ev"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
assert_eq "an existing evidence dir keeps its mode" "$(stat -c '%a' "$W/ev")" "700"

# ---------------------------------------------------------------------------
echo "=== 13. a failed copy leaves nothing behind"
# ---------------------------------------------------------------------------
# `ulimit -f 0` lets cp CREATE the target and then fail on the first
# byte written. Without the rollback, that empty file survives,
# unrecorded, and then blocks its own name with exit 3 forever.
W="$TMP/w13"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
out=$( ( ulimit -f 0; "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt ) 2>&1 ); rc=$?
if (( rc == 2 )); then
    assert_eq "a failed copy exits 2" "$rc" "2"
    assert_contains "the failure names the copy" "$out" "copy failed"
    if [[ -e "$W/ev/nb.PRE.txt" ]]; then
        assert_eq "a failed copy leaves no partial target" "left behind" "removed"
    else
        assert_eq "a failed copy leaves no partial target" "removed" "removed"
    fi
    # The name is free afterwards, because nothing was written.
    "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1; rc=$?
    assert_eq "the name is still freezable after a failed copy" "$rc" "0"
else
    # RLIMIT_FSIZE is not enforced everywhere. Skip rather than pass.
    skip "a failed copy leaves no partial target (RLIMIT_FSIZE not enforced here)"
    skip "the name is still freezable after a failed copy (same)"
    skip "a failed copy exits 2 (same)"
fi

# ---------------------------------------------------------------------------
echo "=== 14. a failed manifest append leaves the manifest read-only"
# ---------------------------------------------------------------------------
# An EMPTY source copies fine under `ulimit -f 0` — cp writes no bytes —
# so the first write to fail is the manifest append. That path must
# still restore mode 0440, or the manifest stays writable for good.
W="$TMP/w14"; mkdir -p "$W/code"
: > "$W/code/empty.txt"
out=$( ( ulimit -f 0; "$FREEZE_BIN" "$W/code/empty.txt" --dir "$W/ev" --as nb.PRE.txt ) 2>&1 ); rc=$?
if (( rc == 4 )); then
    assert_eq "a failed append exits 4" "$rc" "4"
    assert_contains "the failure says the freeze is NOT recorded" "$out" "NOT recorded"
    assert_eq "the manifest is left mode 0440 after a failed append" \
        "$(stat -c '%a' "$W/ev/MANIFEST.md5")" "440"
    assert_eq "the frozen copy is still mode 0440" \
        "$(stat -c '%a' "$W/ev/nb.PRE.txt")" "440"
else
    skip "a failed append exits 4 (RLIMIT_FSIZE not enforced here)"
    skip "the manifest is left mode 0440 after a failed append (same)"
    skip "the frozen copy is still mode 0440 (same)"
fi

# ---------------------------------------------------------------------------
echo "=== 15. a chmod that fails silently is caught, not printed over"
# ---------------------------------------------------------------------------
# The script used to run `chmod 0440 … || true` and then print
# `mode 0440 (read-only)` unconditionally. On a filesystem that ignores
# chmod, that is a success message standing in for an unrun check — the
# exact shape of the incident the guard exists to prevent.
#
# A PATH-front `chmod` stub that exits 0 and changes nothing simulates
# that filesystem. It is the only portable way to reach the branch;
# every real filesystem here honours chmod.
W="$TMP/w15"; mkdir -p "$W/code" "$W/stub"
printf 'BASELINE\n' > "$W/code/nb.txt"
printf '#!/bin/sh\nexit 0\n' > "$W/stub/chmod"
chmod +x "$W/stub/chmod"

if (( EUID == 0 )); then
    skip "a silently-failing chmod exits 7 (root: mode 0440 is not enforced anyway)"
    skip "a silently-failing chmod removes the copy (root)"
    skip "a silently-failing chmod records nothing (root)"
else
    out=$( PATH="$W/stub:$PATH" "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1 ); rc=$?
    assert_eq "a silently-failing chmod exits 7" "$rc" "7"
    assert_contains "the failure names the mode it could not set" "$out" "FAILED to set mode 0440"
    if [[ -e "$W/ev/nb.PRE.txt" ]]; then
        assert_eq "a silently-failing chmod removes the copy" "left behind" "removed"
    else
        assert_eq "a silently-failing chmod removes the copy" "removed" "removed"
    fi
    if [[ -e "$W/ev/MANIFEST.md5" ]]; then
        assert_eq "a silently-failing chmod records nothing" "recorded" "not recorded"
    else
        assert_eq "a silently-failing chmod records nothing" "not recorded" "not recorded"
    fi
    assert_not_contains "output never claims the mode it did not set" \
        "$out" "mode   0440 (read-only)"
fi

# ---------------------------------------------------------------------------
echo "=== 16. an unprotected manifest is reported, and the freeze is kept"
# ---------------------------------------------------------------------------
# The manifest chmod runs AFTER the append, so the freeze is already
# recorded. Undoing it would be wrong. The script must keep it, say
# plainly that the manifest is unprotected, and still exit non-zero.
#
# The stub passes every chmod through EXCEPT the one on the manifest,
# so the frozen copy really is 0440 and only the manifest branch fires.
W="$TMP/w16"; mkdir -p "$W/code" "$W/stub"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
real_chmod=$(command -v chmod)
{
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do case "$a" in *MANIFEST.md5) exit 0 ;; esac; done\n'
    printf 'exec %s "$@"\n' "$real_chmod"
} > "$W/stub/chmod"
"$real_chmod" +x "$W/stub/chmod"

if (( EUID == 0 )); then
    skip "an unprotected manifest exits 7 (root: mode 0440 is not enforced anyway)"
    skip "an unprotected manifest is named (root)"
    skip "the freeze is kept when only the manifest chmod fails (root)"
    skip "the manifest still records the freeze (root)"
else
    out=$( PATH="$W/stub:$PATH" "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1 ); rc=$?
    assert_eq "an unprotected manifest exits 7" "$rc" "7"
    assert_contains "the failure names the manifest" "$out" "FAILED to set mode 0440"
    assert_eq "the freeze is kept when only the manifest chmod fails" \
        "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
    assert_eq "the manifest still records the freeze" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"
    assert_not_contains "output never claims the manifest is append-only" \
        "$out" "is append-only"
fi

# ---------------------------------------------------------------------------
echo "=== 17. the GNU binary name form is read in BOTH places that handle it"
# ---------------------------------------------------------------------------
# `md5sum -b` writes `<hash> *name`, one space and a star, not two
# spaces. The script claims to read that form, and it does — but the
# claim went untested in both places until a skeptic mutated them and
# the suite stayed green.
#
# The two places fail differently, and the second one is the dangerous
# one. `_manifest_records` failing on this form gives a FALSE POSITIVE:
# exit 6 on a file that is recorded, which is loud. Invariant 2 failing
# on it gives a FALSE NEGATIVE: a writable freeze reported clean.
W="$TMP/w17"; mkdir -p "$W/ev"
printf 'BASELINE\n' > "$W/ev/nb.txt"
( cd "$W/ev" && md5sum -b nb.txt > MANIFEST.md5 )
assert_contains "the fixture really is in binary form" \
    "$(cat "$W/ev/MANIFEST.md5")" " *nb.txt"
chmod 0440 "$W/ev/nb.txt" "$W/ev/MANIFEST.md5"

"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "a binary-form manifest verifies clean" "$rc" "0"

# Invariant 2 must still see a writable freeze through the `*`.
chmod u+w "$W/ev/nb.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a writable freeze in binary form exits 5" "$rc" "5"
assert_contains "the writable freeze is named" "$out" "WRITABLE freeze: nb.txt"
chmod 0440 "$W/ev/nb.txt"

# _manifest_records must also see through the `*`, or a recorded name
# would read as free and a second freeze would clobber nothing but
# would double the manifest row.
W="$TMP/w17b"; mkdir -p "$W/code" "$W/ev"
printf 'BASELINE\n' > "$W/code/nb.txt"
cp "$W/code/nb.txt" "$W/ev/nb.txt"
( cd "$W/ev" && md5sum -b nb.txt > MANIFEST.md5 )
chmod u+w "$W/ev/nb.txt" && rm -f "$W/ev/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.txt >/dev/null 2>&1; rc=$?
assert_eq "a binary-form recorded name still exits 4" "$rc" "4"

# ---------------------------------------------------------------------------
echo "=== 18. exit 6 is name-blind, as the header says it is"
# ---------------------------------------------------------------------------
# The header records "Is any name exempt? No" as a deliberate decision.
# A decision with no assertion behind it is a comment: a skeptic added a
# README exemption and the suite stayed green. These two cases are that
# decision, written where it can fail.
W="$TMP/w18"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1

# Several note names, not one. A skeptic exempted the bare name `README`
# and this case stayed green, because its only fixture was
# `README-NOTES.md`; exempting THAT name is caught. The rule is name-blind,
# so the fixture has to be name-plural or it only pins one string.
for note in README-NOTES.md README README.md NOTES.txt readme; do
    printf 'a note nobody recorded\n' > "$W/ev/$note"
    out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
    assert_eq "an unrecorded '$note' trips exit 6" "$rc" "6"
    assert_contains "'$note' is named" "$out" "UNRECORDED file: $note"
    rm -f "$W/ev/$note"
done

# A dotfile is a regular file too, and `find` must not skip it.
printf 'hidden and unrecorded\n' > "$W/ev/.hidden.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "an unrecorded dotfile trips exit 6" "$rc" "6"
assert_contains "the dotfile is named" "$out" "UNRECORDED file: .hidden.txt"
rm -f "$W/ev/.hidden.txt"

"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "the dir is clean again once both are gone" "$rc" "0"

# ---------------------------------------------------------------------------
echo "=== 19. a path-qualified manifest row still accounts for the file"
# ---------------------------------------------------------------------------
# Real manifests here predate this script and record
# `monitor/.state/evidence/<task>/<name>`, not a bare name. Exit 6 once
# called those files unrecorded: on the live store its only three
# findings were all files the manifest DID name, and the remedy it
# printed — freeze the file — is refused with exit 3.
#
# The rule is basename AND hash, never either alone.
W="$TMP/w19"; mkdir -p "$W/ev"
printf 'a note\n' > "$W/ev/EVIDENCE.md"
( cd "$W" && md5sum ev/EVIDENCE.md > ev/MANIFEST.md5 )
assert_contains "the fixture really is path-qualified" \
    "$(cat "$W/ev/MANIFEST.md5")" " ev/EVIDENCE.md"

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_not_contains "a path-qualified row is not called unrecorded" \
    "$out" "UNRECORDED file: EVIDENCE.md"
assert_contains "the name form is reported as a note" \
    "$out" "NOTE: EVIDENCE.md is recorded under a path-qualified name"
if (( rc == 6 )); then
    assert_eq "a path-qualified row does not trip exit 6" "6" "not 6"
else
    assert_eq "a path-qualified row does not trip exit 6" "not 6" "not 6"
fi

# The remedy the header prints must be reachable for the case it names.
# Freezing a file that is already there is refused with exit 3, which is
# why the note must NOT tell the reader to freeze it.
"$FREEZE_BIN" "$W/ev/EVIDENCE.md" --dir "$W/ev" --as EVIDENCE.md >/dev/null 2>&1; rc=$?
assert_eq "freezing an already-present file is refused" "$rc" "3"
assert_not_contains "the note does not prescribe the refused remedy" \
    "$out" "freeze them, or they are not evidence"

# Basename matches, hash does not: the bytes changed under a recorded
# name. That is exit 5, and md5sum -c cannot reach it, because the
# path-qualified row does not resolve from inside the directory.
W="$TMP/w19b"; mkdir -p "$W/ev"
printf 'original\n' > "$W/ev/EVIDENCE.md"
( cd "$W" && md5sum ev/EVIDENCE.md > ev/MANIFEST.md5 )
printf 'SUBSTITUTED\n' > "$W/ev/EVIDENCE.md"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a path-qualified row with changed bytes exits 5" "$rc" "5"
assert_contains "the content mismatch is named" \
    "$out" "CONTENT MISMATCH: EVIDENCE.md"
assert_not_contains "changed bytes are not reported as unrecorded" \
    "$out" "UNRECORDED file: EVIDENCE.md"

# A genuinely unrecorded file alongside a path-qualified one must still
# trip exit 6. The looser read must not swallow the real case.
W="$TMP/w19c"; mkdir -p "$W/ev"
printf 'a note\n' > "$W/ev/EVIDENCE.md"
( cd "$W" && md5sum ev/EVIDENCE.md > ev/MANIFEST.md5 )
printf 'nobody recorded me\n' > "$W/ev/rogue.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_contains "a truly unrecorded file is still named" \
    "$out" "UNRECORDED file: rogue.txt"
assert_not_contains "the path-qualified file is still not named" \
    "$out" "UNRECORDED file: EVIDENCE.md"

# A basename match must be a real match, not a substring or a suffix.
W="$TMP/w19d"; mkdir -p "$W/ev"
printf 'a note\n' > "$W/ev/EVIDENCE.md"
printf 'x  sub/dir/NOT-EVIDENCE.md\n' > "$W/ev/MANIFEST.md5"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_contains "a different basename does not account for the file" \
    "$out" "UNRECORDED file: EVIDENCE.md"

# ---------------------------------------------------------------------------
echo "=== 20. the freeze log records the fields the header names"
# ---------------------------------------------------------------------------
# The header documents a schema, and a schema with no assertion behind
# it is a comment. Every field the cross-check or a reader depends on is
# checked here, by name.
W="$TMP/w20"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1)
assert_contains "stdout names the freeze log" "$out" "logged $NEXUS_FREEZE_LOG"
assert_eq "exactly one row was appended for this dir" "$(freeze_log_rows "$W/ev")" "1"

EVABS=$(cd "$W/ev" && pwd -P)
row=$(command grep "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG" | head -1)
assert_contains "the row carries a schema version" "$row" '{"v":1,'
assert_contains "the row carries the event type"   "$row" '"event":"freeze"'
assert_contains "the row carries the frozen name"  "$row" '"name":"nb.PRE.txt"'
assert_contains "the row carries the md5"          "$row" "\"md5\":\"$BASE_MD5\""
assert_contains "the row carries the byte count"   "$row" '"bytes":9'
assert_contains "the row carries the source path"  "$row" "\"src\":\"$W/code/nb.txt\""
assert_contains "the row carries a timestamp"      "$row" '"ts":"20'

# The log is held read-only between appends, exactly like the manifest.
assert_eq "the freeze log is mode 0440 between appends" \
    "$(stat -c '%a' "$NEXUS_FREEZE_LOG")" "440"

# ---------------------------------------------------------------------------
echo "=== 21. THE LIMIT THAT REMAINS: a consistent edit in two places passes"
# ---------------------------------------------------------------------------
# Option B does not make tampering impossible. It makes tampering need a
# consistent edit in TWO places, one of them shared. This case runs that
# edit and pins it as PASSING, so the suite is never read as proof of
# impossibility — the job case 10 used to do.
W="$TMP/w21"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
REPL_MD5=$(md5of "$W/code/nb.txt")
EVABS=$(cd "$W/ev" && pwd -P)

# Place one: the evidence directory.
rm -f "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
cp "$W/code/nb.txt" "$W/ev/nb.PRE.txt"
( cd "$W/ev" && md5sum nb.PRE.txt > MANIFEST.md5 )
chmod 0440 "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"

# Detected, before the second edit.
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "one-place edit alone is detected" "$rc" "8"

# Place two: the shared freeze log. Same uid, so this is one sed away.
chmod u+w "$NEXUS_FREEZE_LOG"
sed -i "s|\(\"dir\":\"$EVABS\".*\)$BASE_MD5|\1$REPL_MD5|" "$NEXUS_FREEZE_LOG"
chmod 0440 "$NEXUS_FREEZE_LOG"
assert_contains "the log now records the substituted hash" \
    "$(command grep "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG")" "$REPL_MD5"

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a CONSISTENT two-place edit is NOT detected — the limit" "$rc" "0"
assert_contains "and it is still reported as covered" "$out" "covers 1 of 1"

# The cheaper second edit: delete the row instead of rewriting it. The
# file then has no out-of-band record, which PASSES — but never
# silently. The uncovered notice is the whole of decision 4.
W="$TMP/w21b"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
EVABS=$(cd "$W/ev" && pwd -P)
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
rm -f "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
cp "$W/code/nb.txt" "$W/ev/nb.PRE.txt"
( cd "$W/ev" && md5sum nb.PRE.txt > MANIFEST.md5 )
chmod 0440 "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
chmod u+w "$NEXUS_FREEZE_LOG"
command grep -v "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG" > "$TMP/fl.tmp"
cat "$TMP/fl.tmp" > "$NEXUS_FREEZE_LOG"
chmod 0440 "$NEXUS_FREEZE_LOG"
assert_eq "the row is gone" "$(freeze_log_rows "$W/ev")" "0"

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a deleted row leaves the file uncovered, and that PASSES" "$rc" "0"
assert_contains "the uncovered file is counted" "$out" "0 of 1 top-level file(s) recorded out of band"
assert_contains "the uncovered file is explained" "$out" "this check cannot cover them"
assert_contains "the clean verdict itself carries the coverage" "$out" "verified clean (freeze-log covers 0 of 1)"

# ---------------------------------------------------------------------------
echo "=== 22. a logged freeze that is simply GONE is reported"
# ---------------------------------------------------------------------------
# The bypass has a lazier form: remove the freeze and do not recreate
# it, then regenerate the manifest over what is left. Nothing inside the
# directory then names the missing file, so md5sum -c passes and exit 6
# never fires. Only the out-of-band record still knows it existed.
W="$TMP/w22"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'OTHER\n' > "$W/code/other.txt"
"$FREEZE_BIN" "$W/code/other.txt" --dir "$W/ev" --as other.txt >/dev/null 2>&1

rm -f "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
( cd "$W/ev" && md5sum other.txt > MANIFEST.md5 )
chmod 0440 "$W/ev/MANIFEST.md5"
( cd "$W/ev" && md5sum -c MANIFEST.md5 >/dev/null 2>&1 ); chk_rc=$?
assert_eq "the pruned directory is internally consistent" "$chk_rc" "0"

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a logged freeze that is gone exits 8" "$rc" "8"
assert_contains "the missing freeze is named" "$out" "LOGGED FREEZE MISSING: nb.PRE.txt"
assert_contains "its recorded hash is printed" "$out" "$BASE_MD5"

# ---------------------------------------------------------------------------
echo "=== 23. two log rows for one name are the bypass run THROUGH the script"
# ---------------------------------------------------------------------------
# This script cannot write two rows for one name: the target refuses to
# be clobbered and the manifest refuses the name. So a second row means
# the directory was emptied and re-frozen — the same bypass, using the
# tool instead of working around it.
W="$TMP/w23"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
rm -f "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1; rc=$?
assert_eq "re-freezing into an emptied dir succeeds (nothing local forbids it)" "$rc" "0"
assert_eq "the log now holds two rows for this dir" "$(freeze_log_rows "$W/ev")" "2"

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a duplicate log row exits 8" "$rc" "8"
assert_contains "the duplicate is named" "$out" "DUPLICATE freeze-log entry for nb.PRE.txt"

# ---------------------------------------------------------------------------
echo "=== 24. the record outlives the evidence directory"
# ---------------------------------------------------------------------------
# The point of putting the record OUT of the directory: removing the
# directory must not remove the evidence that it existed.
W="$TMP/w24"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
EVABS=$(cd "$W/ev" && pwd -P)

# The log is not in the evidence directory, so it never trips exit 6.
if [[ -e "$W/ev/$(basename "$NEXUS_FREEZE_LOG")" ]]; then
    assert_eq "the freeze log is NOT inside the evidence dir" "inside" "outside"
else
    assert_eq "the freeze log is NOT inside the evidence dir" "outside" "outside"
fi
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "a freshly frozen dir verifies clean" "$rc" "0"

chmod -R u+w "$W/ev"; rm -rf "$W/ev"
if [[ -d "$W/ev" ]]; then
    assert_eq "the evidence dir is gone" "present" "gone"
else
    assert_eq "the evidence dir is gone" "gone" "gone"
fi
assert_eq "the record of the freeze survives it" \
    "$(command grep -c "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG")" "1"
assert_contains "and it still carries the frozen hash" \
    "$(command grep "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG")" "$BASE_MD5"

# ---------------------------------------------------------------------------
echo "=== 25. a writable freeze log is a broken invariant"
# ---------------------------------------------------------------------------
# Same rule as MANIFEST.md5, and the stakes are higher: one stray `>`
# would drop the records for EVERY evidence directory, not just one.
W="$TMP/w25"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
if (( EUID == 0 )); then
    skip "a writable freeze log exits 5 (root: -w is true whatever the mode)"
    skip "the writable freeze log is named (root)"
else
    chmod u+w "$NEXUS_FREEZE_LOG"
    out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
    assert_eq "a writable freeze log exits 5" "$rc" "5"
    assert_contains "the writable freeze log is named" "$out" "WRITABLE freeze-log.jsonl"
    chmod 0440 "$NEXUS_FREEZE_LOG"
fi

# ---------------------------------------------------------------------------
echo "=== 26. exit 5 outranks exit 8, and exit 8 outranks exit 6"
# ---------------------------------------------------------------------------
# Three findings can fire at once, and the header states the order. An
# order with no assertion behind it is a comment.
W="$TMP/w26"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1

# 8 alone: the logged bytes were replaced, and a rogue file is present.
printf 'REPLACEMENT\n' > "$W/code/nb.txt"
rm -f "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
cp "$W/code/nb.txt" "$W/ev/nb.PRE.txt"
( cd "$W/ev" && md5sum nb.PRE.txt > MANIFEST.md5 )
chmod 0440 "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
printf 'NOBODY RECORDED ME\n' > "$W/ev/rogue.txt"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a log mismatch outranks an unrecorded file" "$rc" "8"
assert_contains "the unrecorded file is still reported" "$out" "UNRECORDED file: rogue.txt"

# 5 as well: now the manifest is writable too.
chmod u+w "$W/ev/MANIFEST.md5"
if (( EUID == 0 )); then
    skip "a broken invariant outranks a log mismatch (root bypasses mode 0440)"
else
    out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
    assert_eq "a broken invariant outranks a log mismatch" "$rc" "5"
    assert_contains "the log mismatch is still reported" "$out" "FREEZE-LOG MISMATCH"
fi

# ---------------------------------------------------------------------------
echo "=== 27. concurrent freezes do not interleave in the log"
# ---------------------------------------------------------------------------
# Several agents freeze at once and the state dir is on NFS, where an
# O_APPEND write is not guaranteed atomic. Each append takes an
# exclusive flock. N parallel freezes must leave exactly N well-formed
# rows — never a half line, never two lines spliced into one.
#
# N is fixed and the loop waits for every child, so this cannot grow an
# unbounded process tree.
W="$TMP/w27"; mkdir -p "$W/code" "$W/ev"
N=12
for i in $(seq 1 "$N"); do printf 'PAYLOAD %s\n' "$i" > "$W/code/nb$i.txt"; done
for i in $(seq 1 "$N"); do
    "$FREEZE_BIN" "$W/code/nb$i.txt" --dir "$W/ev" --as "nb$i.txt" >/dev/null 2>&1 &
done
wait
assert_eq "every concurrent freeze landed one row" "$(freeze_log_rows "$W/ev")" "$N"
assert_eq "every concurrent freeze landed one file" \
    "$(find "$W/ev" -maxdepth 1 -type f -name 'nb*.txt' | wc -l)" "$N"

# A spliced line would be a row that is not exactly one JSON object.
EVABS=$(cd "$W/ev" && pwd -P)
malformed=0
while IFS= read -r line; do
    [[ "$line" == '{"v":1,'*'}' ]] || { malformed=$(( malformed + 1 )); continue; }
    # One object per line: no `}{` splice, and exactly one md5 field.
    [[ "$line" == *'}{'* ]] && malformed=$(( malformed + 1 ))
    [[ "$(command grep -o '"md5":' <<< "$line" | wc -l)" == "1" ]] || malformed=$(( malformed + 1 ))
done < <(command grep "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG")
assert_eq "no row is spliced or truncated" "$malformed" "0"

# The manifest took the same N appends, and verify agrees with the log.
assert_eq "the manifest took every concurrent append" \
    "$(wc -l < "$W/ev/MANIFEST.md5")" "$N"
"$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
assert_eq "the concurrently-built dir verifies clean" "$rc" "0"

# ---------------------------------------------------------------------------
echo "=== 28. an UNSERIALISED append is announced, never silent"
# ---------------------------------------------------------------------------
# The lock can fail to be taken. The append still happens, because
# losing the record is worse than an unserialised one — but the caller
# has to be told which kind of append it got. A silent unlocked append
# would be a success message standing in for a check nobody ran.
#
# A PATH-front `flock` stub that always fails is the portable way to
# reach that branch.
W="$TMP/w28"; mkdir -p "$W/code" "$W/stub"
printf 'BASELINE\n' > "$W/code/nb.txt"
printf '#!/bin/sh\nexit 1\n' > "$W/stub/flock"
chmod +x "$W/stub/flock"
out=$( PATH="$W/stub:$PATH" "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1 ); rc=$?
assert_eq "an unlockable append still records the freeze" "$rc" "0"
assert_contains "the unserialised append is announced" "$out" "WITHOUT a lock"
assert_contains "and the risk is named" "$out" "could interleave"
assert_eq "the row landed anyway" "$(freeze_log_rows "$W/ev")" "1"

# The normal path says nothing of the kind.
W="$TMP/w28b"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
out=$("$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1)
assert_not_contains "a locked append prints no warning" "$out" "WITHOUT a lock"

# ---------------------------------------------------------------------------
echo "=== 29. a field name inside a VALUE is not read as the field"
# ---------------------------------------------------------------------------
# The freeze log is read by a hand-written JSON extractor, because this
# script may not assume a JSON parser is installed. The extractor
# requires a key to START a field (`{"k":"` or `,"k":"`), and the header
# says so. That rule had no assertion behind it: a skeptic-style
# mutation that dropped the boundary left the whole suite green.
#
# The fixture is a frozen name that CONTAINS `"md5":"0`. If the
# extractor matched the key anywhere, it would read `0` as the recorded
# hash, and a clean directory would report a mismatch.
W="$TMP/w29"; mkdir -p "$W/code"
DECOY='nb"md5":"0.txt'
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as "$DECOY" >/dev/null 2>&1; rc=$?
assert_eq "a name holding a decoy field freezes" "$rc" "0"

EVABS=$(cd "$W/ev" && pwd -P)
row=$(command grep "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG" | head -1)
assert_contains "the quotes in the name are escaped" "$row" '"name":"nb\"md5\":\"0.txt"'
assert_contains "the real md5 field is still present" "$row" "\"md5\":\"$BASE_MD5\""

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "the decoy is not read as the recorded hash" "$rc" "0"
assert_contains "and the file counts as covered" "$out" "covers 1 of 1"

# It really is being compared, not skipped: change the bytes and the
# cross-check must fire.
chmod u+w "$W/ev/$DECOY" "$W/ev/MANIFEST.md5"
printf 'SUBSTITUTED\n' > "$W/ev/$DECOY"
( cd "$W/ev" && md5sum -- "$DECOY" > MANIFEST.md5 )
chmod 0440 "$W/ev/$DECOY" "$W/ev/MANIFEST.md5"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "substituted bytes under a decoy name still exit 8" "$rc" "8"
assert_contains "the real recorded hash is the one printed" "$out" "$BASE_MD5"

# The escaping above means this script can never WRITE a line whose raw
# text holds a stray `"md5":"`. The key-boundary rule therefore guards a
# row that this script did not write — and the freeze log is a shared,
# hand-editable file, so that row is exactly the adversary. The fixture
# below is DELIBERATELY malformed: `xx"md5":"<zeros>` sits ahead of the
# real field. An extractor that matched the key anywhere would read the
# zeros and report a mismatch on a clean directory.
W="$TMP/w29b"; mkdir -p "$W/ev"
printf 'BASELINE\n' > "$W/ev/nb.txt"
BASE_MD5=$(md5of "$W/ev/nb.txt")
( cd "$W/ev" && md5sum nb.txt > MANIFEST.md5 )
chmod 0440 "$W/ev/nb.txt" "$W/ev/MANIFEST.md5"
EVABS=$(cd "$W/ev" && pwd -P)
ZEROS=00000000000000000000000000000000
chmod u+w "$NEXUS_FREEZE_LOG"
printf '{"v":1,"ts":"2026-01-01T00:00:00-0000","event":"freeze","dir":"%s","name":"nb.txt","xx"md5":"%s,"md5":"%s","bytes":9,"src":"x","window":""}\n' \
    "$EVABS" "$ZEROS" "$BASE_MD5" >> "$NEXUS_FREEZE_LOG"
chmod 0440 "$NEXUS_FREEZE_LOG"

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a decoy key ahead of the real field is not read as the field" "$rc" "0"
assert_not_contains "the zeros are never taken for the recorded hash" "$out" "$ZEROS"
assert_contains "the crafted row still counts as coverage" "$out" "covers 1 of 1"

# ---------------------------------------------------------------------------
echo "=== 30. a backslash in the evidence path still joins to its own rows"
# ---------------------------------------------------------------------------
# Two mechanisms have to agree for this to work, and neither had a case
# behind it. `_json_escape` must escape the backslash on the way in, and
# the reader must pass the wanted path to awk through ENVIRON rather
# than `awk -v`, which runs the value through awk's escape processing.
#
# The failure this pins is a FALSE CLEAN, not a loud error. Measured
# with `awk -v` in place: a directory named `ev\dir` reported "0 of 1
# recorded out of band" for a file it had just frozen.
W="$TMP/w30"; mkdir -p "$W/code"
BSDIR='ev\dir'
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/$BSDIR" --as nb.PRE.txt >/dev/null 2>&1; rc=$?
assert_eq "a backslashed evidence dir freezes" "$rc" "0"

row=$(tail -1 "$NEXUS_FREEZE_LOG")
assert_contains "the backslash is escaped in the row" "$row" 'ev\\dir'

out=$("$FREEZE_BIN" --verify --dir "$W/$BSDIR" 2>&1); rc=$?
assert_eq "a backslashed evidence dir verifies clean" "$rc" "0"
assert_contains "its own row joins to it" "$out" "covers 1 of 1"

# And the cross-check really runs there: substitute the bytes.
chmod u+w "$W/$BSDIR/nb.PRE.txt" "$W/$BSDIR/MANIFEST.md5"
printf 'SUBSTITUTED\n' > "$W/$BSDIR/nb.PRE.txt"
( cd "$W/$BSDIR" && md5sum nb.PRE.txt > MANIFEST.md5 )
chmod 0440 "$W/$BSDIR/nb.PRE.txt" "$W/$BSDIR/MANIFEST.md5"
out=$("$FREEZE_BIN" --verify --dir "$W/$BSDIR" 2>&1); rc=$?
assert_eq "substituted bytes in a backslashed dir exit 8" "$rc" "8"
assert_contains "the recorded hash is printed" "$out" "$BASE_MD5"

# ---------------------------------------------------------------------------
echo "=== 31. --verify WAITS for an in-flight freeze instead of reading past it"
# ---------------------------------------------------------------------------
# `--verify` takes a SHARED lock before it reads the log. Without it, a
# read that lands mid-append sees a torn last line, which parses as no
# row at all — so the file it named drops silently to "uncovered" and
# the directory reports clean. That is a false CLEAN again.
#
# The assertion is that `--verify` BLOCKS while an exclusive holder has
# the lock. A holder sleeps 2 s; `--verify` must not return before 1 s.
# The 1 s floor is half the hold, so ordinary scheduling jitter cannot
# reach it.
W="$TMP/w31"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
"$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1

if ! command -v flock >/dev/null 2>&1; then
    skip "--verify waits for an in-flight freeze (no flock on this host)"
    skip "--verify still reports the directory clean afterwards (same)"
else
    ( flock -x 9; sleep 2 ) 9>>"$NEXUS_FREEZE_LOG.lock" &
    holder=$!
    sleep 0.5                      # let the holder take the lock
    t0=$(date +%s%N)
    "$FREEZE_BIN" --verify --dir "$W/ev" >/dev/null 2>&1; rc=$?
    t1=$(date +%s%N)
    wait "$holder" 2>/dev/null
    elapsed_ms=$(( (t1 - t0) / 1000000 ))
    if (( elapsed_ms >= 1000 )); then
        assert_eq "--verify waits for an in-flight freeze" "waited" "waited"
    else
        assert_eq "--verify waits for an in-flight freeze" "returned in ${elapsed_ms}ms" "waited"
    fi
    assert_eq "--verify still reports the directory clean afterwards" "$rc" "0"
fi

# ---------------------------------------------------------------------------
echo "=== 32. a relative --dir joins to the same rows as an absolute one"
# ---------------------------------------------------------------------------
# `dir` is the join key, so the freeze side and the verify side must
# resolve a directory to the SAME string. `_abs_dir` is that one
# function. Every other case passes an absolute path to both sides, so
# a mutation that made `_abs_dir` return its argument unchanged left the
# whole suite green — the two sides still agreed, by accident.
#
# Freeze with a RELATIVE `--dir` and verify with an absolute one. The
# failure is a FALSE CLEAN: the row exists, but under a key nothing
# looks up.
W="$TMP/w32"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
( cd "$W" && "$FREEZE_BIN" code/nb.txt --dir ev --as nb.PRE.txt >/dev/null 2>&1 ); rc=$?
assert_eq "a relative --dir freezes" "$rc" "0"
assert_eq "the row is keyed by the ABSOLUTE dir" "$(freeze_log_rows "$W/ev")" "1"

out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "an absolute --verify of it is clean" "$rc" "0"
assert_contains "and it joins to its own row" "$out" "covers 1 of 1"

# The cross-check really runs across the two spellings.
chmod u+w "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
printf 'SUBSTITUTED\n' > "$W/ev/nb.PRE.txt"
( cd "$W/ev" && md5sum nb.PRE.txt > MANIFEST.md5 )
chmod 0440 "$W/ev/nb.PRE.txt" "$W/ev/MANIFEST.md5"
out=$("$FREEZE_BIN" --verify --dir "$W/ev" 2>&1); rc=$?
assert_eq "a relative-frozen dir is still cross-checked" "$rc" "8"
assert_contains "the recorded hash is printed" "$out" "$BASE_MD5"

# ---------------------------------------------------------------------------
echo "=== 33. the freeze-log WRITE side fails loudly, and keeps the freeze"
# ---------------------------------------------------------------------------
# Exit 8 carries TWO meanings. "The record and the directory disagree" had
# eight assertions. "A freeze could not be recorded out of band" had NONE,
# and neither did exit 7 on the log's own mode. A depth-1 skeptic found
# three surviving mutants sitting in that gap: dropping `|| rc=1` from the
# append, deleting the exit-8 branch, and deleting the exit-7 mode guard
# all left the suite fully green.
#
# The asymmetry is the tell. This suite already forces a chmod failure for
# the frozen copy (case 15) and for MANIFEST.md5 (case 16). It did not
# force one for the freeze log. That was an oversight, not a decision.
#
# The rule in both branches is the same as case 16's: the freeze is
# already copied, read-only and in the manifest, so throwing it away to
# report a bookkeeping failure would destroy evidence. Keep it, name the
# promise that went unmet, exit non-zero.

# (a) the append itself cannot land. A read-only log DIRECTORY with no log
#     in it yet is the portable way to reach that: the create fails.
W="$TMP/w33"; mkdir -p "$W/code" "$W/logdir"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
chmod 0555 "$W/logdir"

if (( EUID == 0 )); then
    skip "an unrecordable freeze exits 8 (root writes a 0555 directory anyway)"
    skip "the failure names the log (root)"
    skip "the freeze is KEPT when the log cannot be written (root)"
    skip "and MANIFEST.md5 still records it (root)"
    skip "the lock failure is announced too (root)"
else
    out=$( NEXUS_FREEZE_LOG="$W/logdir/freeze-log.jsonl" \
           "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1 ); rc=$?
    assert_eq "an unrecordable freeze exits 8" "$rc" "8"
    assert_contains "the failure names the log" "$out" "FAILED to record this freeze"
    assert_contains "the failure says what --verify can no longer do" \
        "$out" "would not be detected"
    # Detection is lost; the EVIDENCE is not. Keeping it is the whole rule.
    assert_eq "the freeze is KEPT when the log cannot be written" \
        "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
    assert_eq "and MANIFEST.md5 still records it" "$(wc -l < "$W/ev/MANIFEST.md5")" "1"
    # The lock file cannot be created in that directory either, and that
    # is announced rather than swallowed.
    assert_contains "the lock failure is announced too" "$out" "WITHOUT a lock"
fi
chmod u+w "$W/logdir" 2>/dev/null

# (b) the append lands, but the log's mode cannot be set. The stub passes
#     every chmod through EXCEPT the one on the freeze log, so only that
#     branch fires. The log path is FRESH for this case: against the
#     suite-wide log, already mode 0440, the stubbed `chmod u+w` would
#     make the APPEND fail instead, which is branch (a), not this one.
#     It must also be NAMED `freeze-log.jsonl`: the stub matches on the
#     name, and a differently-named fixture makes the stub inert and the
#     case a tautology. That happened on the first run of this case.
W="$TMP/w33b"; mkdir -p "$W/code" "$W/stub" "$W/logs"
printf 'BASELINE\n' > "$W/code/nb.txt"
BASE_MD5=$(md5of "$W/code/nb.txt")
real_chmod=$(command -v chmod)
{
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do case "$a" in *freeze-log.jsonl) exit 0 ;; esac; done\n'
    printf 'exec %s "$@"\n' "$real_chmod"
} > "$W/stub/chmod"
"$real_chmod" +x "$W/stub/chmod"

if (( EUID == 0 )); then
    skip "an unprotected freeze log exits 7 (root: mode 0440 is not enforced anyway)"
    skip "the failure names the freeze log (root)"
    skip "the freeze is kept and recorded (root)"
    skip "output never claims a mode it did not set (root)"
else
    out=$( PATH="$W/stub:$PATH" NEXUS_FREEZE_LOG="$W/logs/freeze-log.jsonl" \
           "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt 2>&1 ); rc=$?
    assert_eq "an unprotected freeze log exits 7" "$rc" "7"
    assert_contains "the failure names the freeze log" "$out" "FAILED to set mode 0440"
    assert_contains "the failure says the log holds every directory's records" \
        "$out" "every evidence directory"
    assert_eq "the freeze is kept and recorded" \
        "$(md5of "$W/ev/nb.PRE.txt")" "$BASE_MD5"
    assert_eq "the row landed before the chmod failed" \
        "$(wc -l < "$W/logs/freeze-log.jsonl")" "1"
    assert_not_contains "output never claims a mode it did not set" \
        "$out" "mode   0440 (read-only)"
fi

# ---------------------------------------------------------------------------
echo "=== 34. the row's window and src are the values the script EMITS"
# ---------------------------------------------------------------------------
# Case 20 checks the schema against a fixture whose source path is ALREADY
# absolute and canonical. That makes `readlink -f` a no-op, so dropping it
# left the suite green, and `window` had no assertion at all. Both are the
# round-4 fixture trap again, in the file that records the round-4 lesson:
# the code ran, the input shape could not tell the difference.

# (a) window. It is the join key back into the action log's spawn and
#     wrap-up trace, so an empty one costs a reader that link.
W="$TMP/w34"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
NEXUS_WORKER_WINDOW=w34-probe-window \
    "$FREEZE_BIN" "$W/code/nb.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1
EVABS=$(cd "$W/ev" && pwd -P)
row=$(command grep "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG" | head -1)
assert_contains "the row carries the worker window" "$row" '"window":"w34-probe-window"'

# (b) src through a SYMLINK. The expected value is built with `pwd -P`,
#     not with `readlink -f`, so the assertion does not simply restate the
#     call it is checking.
W="$TMP/w34b"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/real.txt"
ln -s real.txt "$W/code/link.txt"
CODEABS=$(cd "$W/code" && pwd -P)
"$FREEZE_BIN" "$W/code/link.txt" --dir "$W/ev" --as nb.PRE.txt >/dev/null 2>&1; rc=$?
assert_eq "freezing through a symlink works" "$rc" "0"
EVABS=$(cd "$W/ev" && pwd -P)
row=$(command grep "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG" | head -1)
assert_contains "src records the RESOLVED source, not the symlink" \
    "$row" "\"src\":\"$CODEABS/real.txt\""
assert_not_contains "src is not the symlink path" "$row" "link.txt"

# (c) src given RELATIVELY. Provenance that only resolves from the
#     caller's old working directory is not provenance.
W="$TMP/w34c"; mkdir -p "$W/code"
printf 'BASELINE\n' > "$W/code/nb.txt"
CODEABS=$(cd "$W/code" && pwd -P)
( cd "$W" && "$FREEZE_BIN" code/nb.txt --dir ev --as nb.PRE.txt >/dev/null 2>&1 )
EVABS=$(cd "$W/ev" && pwd -P)
row=$(command grep "\"dir\":\"$EVABS\"" "$NEXUS_FREEZE_LOG" | head -1)
assert_contains "a relative source is recorded absolutely" \
    "$row" "\"src\":\"$CODEABS/nb.txt\""

echo
printf 'PASS=%d FAIL=%d SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "TESTS FAILED" >&2
exit 1
