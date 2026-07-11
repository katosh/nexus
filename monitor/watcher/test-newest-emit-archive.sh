#!/usr/bin/env bash
# Tests for _newest_emit_archive in main.sh — the stat-free "newest emit
# archive by NAME" lookup used by the orchestrator-liveness resubmit rescue
# (your-org/nexus-code#<this>, sibling of #402/#403).
#
# Background: the old resubmit path did
#     find "$DIFF_DIR" -printf '%T@ %p\n' | sort -rn | head -n1
# which stat()s EVERY file just to pick ONE. At the ~17k-file 7-day plateau
# that took ~9-14 min on the NFS state dir, and — because orchestrator_liveness
# runs in the SYNC scheduler phase every 5 s (no --async) — it stalled the
# heartbeat into a supervisor false-positive "watcher DOWN" (the 2026-07-07
# outage). The fix selects the newest archive by its sortable-ts FILENAME
# (`%Y-%m-%d_%H-%M-%S_<id>[_tag].md`) via one bash readdir — no per-file stat,
# no external `find`/`sort`.
#
# Strategy: awk-pluck _newest_emit_archive out of main.sh (it has no
# source-only guard; this mirrors how the pre-extraction emit-dedup test
# loaded main.sh functions) and exercise it directly.
#
# Each assertion is falsifiable against the OLD `-printf | sort -rn` impl:
#   S1  name order and mtime order DISAGREE (old files touched recent, new
#       files touched old) → a NAME-based pick returns the name-max; the old
#       MTIME-based pick returns the recently-touched name-min. Proves
#       name-based selection (== stat-free).
#   S2  hard proof of "no external scan": shadow find/sort/ls/stat with stubs
#       that fail loudly; the function must STILL return the correct newest,
#       so it can be using none of them.
#   S3  tag-suffix edge case: a later-timestamped `_full-state` / `_resurface`
#       archive is a valid newest emit body and is returned.
#   S4  scale + boundaries: 5000-file dir returns the correct max; empty dir,
#       absent dir, and single file behave.
#
# Run: bash monitor/watcher/test-newest-emit-archive.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_main_sh="$_test_dir/main.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$*"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$(( FAIL + 1 )); }

# ---- pluck the function under test out of main.sh ----------------------
# From `_newest_emit_archive() {` to the first column-0 `}`. All the
# function's own braces are indented, so `^}` is the terminator.
_fn_src=$(awk '/^_newest_emit_archive\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$_main_sh")
if [[ -z "$_fn_src" ]]; then
    echo "FAIL: could not extract _newest_emit_archive from $_main_sh" >&2
    exit 1
fi
eval "$_fn_src"
if ! declare -F _newest_emit_archive >/dev/null; then
    echo "FAIL: _newest_emit_archive not defined after eval" >&2
    exit 1
fi

WORK=$(mktemp -d -t nexus-newest-archive-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- Scenario 1: name-based, NOT mtime-based --------------------------
echo '=== newest-archive: selects by filename, not mtime ==='
D1="$WORK/s1"; mkdir -p "$D1"
# Older-DATED files, but touched with a RECENT mtime (newest on disk).
for i in 00 01 02; do : > "$D1/2020-01-01_12-00-${i}_aaaaaa.md"; done
# Newer-DATED files, touched with an OLD mtime.
: > "$D1/2099-12-31_23-59-59_zzzzzz.md"
touch -d '2000-01-01' "$D1/2099-12-31_23-59-59_zzzzzz.md"
touch -d 'now'        "$D1"/2020-01-01_*.md

got1=$(_newest_emit_archive "$D1"); got1_base="${got1##*/}"
[[ "$got1_base" == "2099-12-31_23-59-59_zzzzzz.md" ]] \
    && pass "returns the name-max (2099…), not the recently-touched mtime-max (would fail old -printf|sort)" \
    || fail "returned '$got1_base' — expected the name-max 2099-12-31_23-59-59_zzzzzz.md"
# Absolute path, real file.
[[ "$got1" == /* && -f "$got1" ]] \
    && pass "returns an absolute path to a real .md" \
    || fail "did not return an absolute path to a real file: '$got1'"

# ---- Scenario 2: NO external scan (find/sort/ls/stat all shadowed) -----
echo '=== newest-archive: uses no find/sort/ls/stat (pure readdir) ==='
D2="$WORK/s2"; mkdir -p "$D2"
for ts in 2026-07-07_18-33-05 2026-07-07_18-33-06 2026-07-07_18-33-07; do
    : > "$D2/${ts}_$(printf '%06d' $((RANDOM%1000000))).md"
done
newest_name=$(printf '%s\n' "$D2"/*.md | LC_ALL=C sort | tail -1); newest_name="${newest_name##*/}"
stubdir="$WORK/stubs"; mkdir -p "$stubdir"
for tool in find sort ls stat; do
    cat > "$stubdir/$tool" <<STUB
#!/bin/bash
echo "SCAN-STUB: $tool invoked — _newest_emit_archive must not shell out" >&2
touch "$WORK/scan_sentinel"
exit 3
STUB
    chmod +x "$stubdir/$tool"
done
rm -f "$WORK/scan_sentinel"
got2=$(PATH="$stubdir:$PATH" _newest_emit_archive "$D2"); got2_base="${got2##*/}"
if [[ -e "$WORK/scan_sentinel" ]]; then
    fail "_newest_emit_archive shelled out to a scan tool (sentinel present) — not stat-free"
else
    pass "no find/sort/ls/stat invoked (pure bash readdir)"
fi
[[ "$got2_base" == "$newest_name" ]] \
    && pass "still returns the correct newest ($newest_name) with scan tools shadowed" \
    || fail "returned '$got2_base' with scans shadowed — expected '$newest_name'"

# ---- Scenario 3: tag-suffix archives are valid newest bodies ----------
echo '=== newest-archive: a later-ts tagged archive is returned ==='
D3="$WORK/s3"; mkdir -p "$D3"
: > "$D3/2026-07-07_10-00-00_ab12cd.md"                 # bare, earlier
: > "$D3/2026-07-07_11-00-00_ef34gh_full-state.md"      # tagged, LATER
got3=$(_newest_emit_archive "$D3"); got3_base="${got3##*/}"
[[ "$got3_base" == "2026-07-07_11-00-00_ef34gh_full-state.md" ]] \
    && pass "later-ts _full-state archive returned (valid emit body)" \
    || fail "returned '$got3_base' — expected the later 11-00-00 full-state archive"

# ---- Scenario 4: scale + boundary conditions --------------------------
echo '=== newest-archive: scale + empty/absent/single ==='
D4="$WORK/s4"; mkdir -p "$D4"
for (( i = 0; i < 5000; i++ )); do
    printf -v nm '2026-06-%02d_%02d-%02d-%02d_%06d.md' \
        $(( (i%28)+1 )) $(( (i/60)%24 )) $(( i%60 )) $(( (i*7)%60 )) "$i"
    : > "$D4/$nm"
done
: > "$D4/2026-12-31_23-59-59_ffffff.md"    # unambiguous max
got4=$(_newest_emit_archive "$D4"); got4_base="${got4##*/}"
[[ "$got4_base" == "2026-12-31_23-59-59_ffffff.md" ]] \
    && pass "5000-file dir returns the correct name-max" \
    || fail "5000-file dir returned '$got4_base' — expected 2026-12-31_23-59-59_ffffff.md"

D5="$WORK/s5-empty"; mkdir -p "$D5"
got5=$(_newest_emit_archive "$D5")
[[ -z "$got5" ]] && pass "empty dir → empty output" || fail "empty dir returned '$got5'"

got6=$(_newest_emit_archive "$WORK/does-not-exist")
[[ -z "$got6" ]] && pass "absent dir → empty output" || fail "absent dir returned '$got6'"

D7="$WORK/s7-one"; mkdir -p "$D7"
: > "$D7/2026-07-07_09-09-09_0f0f0f.md"
got7=$(_newest_emit_archive "$D7"); got7_base="${got7##*/}"
[[ "$got7_base" == "2026-07-07_09-09-09_0f0f0f.md" ]] \
    && pass "single-file dir returns that file" \
    || fail "single-file dir returned '$got7_base'"

# ---- summary -----------------------------------------------------------
echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
