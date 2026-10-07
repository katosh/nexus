#!/usr/bin/env bash
# test-degraded-probe.sh — monitor/degraded-probe.sh and `ng degraded probe`
# (your-org/nexus-code#1724).
#
# What must hold, and why each case is here:
#   - every verdict is reachable and named: OK, EACCES and MISSING from the real
#     filesystem; EROFS, ENOSPC and HANG through the writer SEAM, because a
#     suite cannot detach a mount. The seam replaces only the child that does
#     the create, never the classification or the surface walk.
#   - THE SEAM CANNOT TEST SURFACE SELECTION (#1724's own constraint), so one
#     case enumerates the DEFAULT surfaces with the REAL writer against a fake
#     root and asserts the names and the resolved paths, including the
#     NEXUS_STATE_DIR override monitor/ng honours.
#   - it can never be aimed at the sandbox root: `/`, empty and relative paths
#     are refused at rc 2 before anything is written.
#   - an OK leaves nothing behind in the surface it probed.
#   - `ng degraded` reaches the script for `probe` and REFUSES the subcommands
#     that are not built, rather than ignoring them.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_dir/../degraded-probe.sh"
NG="$_dir/../ng"

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

echo '=== real filesystem: OK, MISSING, EACCES ==='
mkdir -p "$WORK/ok"
out=$("$PROBE" --surface ok="$WORK/ok" 2>&1); rc=$?
assert_eq        "writable dir: rc 0"                     "$rc" "0"
assert_contains  "writable dir: verdict OK"               "$out" "surface=ok verdict=OK path=$WORK/ok"
assert_eq        "an OK leaves nothing behind"            "$(ls -A "$WORK/ok")" ""

out=$("$PROBE" --surface gone="$WORK/nope" 2>&1); rc=$?
assert_eq        "missing dir: rc 1"                      "$rc" "1"
assert_contains  "missing dir: verdict MISSING"           "$out" "surface=gone verdict=MISSING"
assert_no_file   "missing dir: NOT created by the probe"  "$WORK/nope"

_EACCES_RAN=0
mkdir -p "$WORK/ro"; chmod 0555 "$WORK/ro"
if [[ "$(id -u)" != 0 ]] && ! ( : > "$WORK/ro/.x" ) 2>/dev/null; then
    out=$("$PROBE" --surface ro="$WORK/ro" 2>&1); rc=$?
    assert_eq       "unwritable dir: rc 1"                "$rc" "1"
    assert_contains "unwritable dir: verdict EACCES"      "$out" "surface=ro verdict=EACCES"
    assert_contains "unwritable dir: the errno text is the detail" "$out" "Permission denied"
    _EACCES_RAN=3
else
    th_skip "unwritable dir: the mode bits do not bind for this uid"
fi

echo '=== writer seam: EROFS, ENOSPC, HANG, ERROR ==='
mkdir -p "$WORK/s"
mkw() {   # <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$WORK/w-$1"; chmod +x "$WORK/w-$1"
    printf '%s' "$WORK/w-$1"
}
w=$(mkw erofs 'echo "bash: $1: Read-only file system" >&2; exit 1')
out=$(NEXUS_DEGRADED_PROBE_WRITER="$w" "$PROBE" --surface s="$WORK/s" 2>&1); rc=$?
assert_eq       "EROFS: rc 1"                 "$rc" "1"
assert_contains "EROFS: verdict EROFS"        "$out" "verdict=EROFS"
w=$(mkw enospc 'echo "bash: $1: No space left on device" >&2; exit 1')
out=$(NEXUS_DEGRADED_PROBE_WRITER="$w" "$PROBE" --surface s="$WORK/s" 2>&1); rc=$?
assert_contains "ENOSPC: verdict ENOSPC"      "$out" "verdict=ENOSPC"
w=$(mkw hang 'sleep 30')
t0=$SECONDS
out=$(NEXUS_DEGRADED_PROBE_WRITER="$w" "$PROBE" --timeout 1 --surface s="$WORK/s" 2>&1); rc=$?
assert_eq       "HANG: rc 1"                  "$rc" "1"
assert_contains "HANG: verdict HANG"          "$out" "verdict=HANG"
assert_eq       "HANG: bounded (returned well before the writer's 30 s)" "$(( SECONDS - t0 < 15 ))" "1"
w=$(mkw weird 'echo "something unforeseen" >&2; exit 5')
out=$(NEXUS_DEGRADED_PROBE_WRITER="$w" "$PROBE" --surface s="$WORK/s" 2>&1); rc=$?
assert_contains "unknown failure: verdict ERROR, never OK" "$out" "verdict=ERROR"
assert_contains "…with the child's stderr as detail"      "$out" "something unforeseen"

echo '=== refused paths: never the root, never empty, never relative ==='
for bad in "/" "//" "" "relative/dir"; do
    out=$("$PROBE" --surface x="$bad" 2>&1); rc=$?
    assert_eq       "surface path '${bad}': REFUSED rc 2" "$rc" "2"
    assert_contains "surface path '${bad}': says REFUSED" "$out" "REFUSED"
done

echo '=== default surfaces: selection with the REAL writer (the seam cannot test this) ==='
R="$WORK/root"
mkdir -p "$R/monitor/.state/requests" "$R/monitor/.state/skeptic/pending" \
         "$R/monitor/.state/longjob" "$R/reports" "$R/work"
out=$(env -u NEXUS_STATE_DIR NEXUS_ROOT="$R" "$PROBE" 2>&1); rc=$?
assert_eq "defaults: rc 0 on a fully writable fake root" "$rc" "0"
for pair in "state=$R/monitor/.state" "requests=$R/monitor/.state/requests" \
            "skeptic=$R/monitor/.state/skeptic/pending" "longjob=$R/monitor/.state/longjob" \
            "reports=$R/reports" "work=$R/work"; do
    assert_contains "defaults: probes ${pair%%=*} at ${pair#*=}" "$out" "surface=${pair%%=*} verdict=OK path=${pair#*=}"
done
assert_contains "defaults: six surfaces" "$out" "summary: 6 surface(s), 0 not OK"
S2="$WORK/elsewhere"; mkdir -p "$S2"
out=$(NEXUS_STATE_DIR="$S2" NEXUS_ROOT="$R" "$PROBE" 2>&1); rc=$?
assert_contains "NEXUS_STATE_DIR override: state resolves there" "$out" "surface=state verdict=OK path=$S2"
assert_contains "…and its sub-surfaces follow it (absent here → MISSING, not created)" "$out" "surface=requests verdict=MISSING path=$S2/requests"
assert_eq       "…which is not OK: rc 1" "$rc" "1"

echo '=== ng degraded ==='
out=$(NEXUS_STATE_DIR="$S2" "$NG" degraded probe --surface ok="$WORK/ok" 2>&1); rc=$?
assert_eq       "ng degraded probe: rc 0"        "$rc" "0"
assert_contains "ng degraded probe: reaches the script" "$out" "surface=ok verdict=OK"
out=$("$NG" degraded enter 2>&1); rc=$?
assert_eq       "ng degraded enter: REFUSED, not ignored (rc != 0)" "$(( rc != 0 ))" "1"
assert_contains "ng degraded enter: says it is not implemented" "$out" "not implemented"

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact): a
# dropped or added assertion is a FAIL, never a quieter green.
#   real fs 6 (+3 EACCES where the mode bits bind) | seam 8 (EROFS 2, ENOSPC 1, HANG 3, ERROR 2) | refused 8
#   defaults 1+6+1, override 3 | ng 4
EXPECTED=$(( 6 + _EACCES_RAN + 8 + 8 + 8 + 3 + 4 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
