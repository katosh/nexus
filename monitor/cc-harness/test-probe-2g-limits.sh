#!/usr/bin/env bash
# test-probe-2g-limits.sh — probe-2g-limits.py re-reads the plugin-monitor
# OUTPUT LIMITS (GUIDE §2g) by STRUCTURE, and fails CLOSED (rc 3, UNRESOLVED)
# whenever a step does not match (your-org/nexus-code#1734).
#
# The defect: the GUIDE told the evaluator to re-read the limits from one
# build's minified identifiers (`dce=`, `Ate=`, `bVe=`). They were absent on
# every later build, so the check produced an EMPTY extraction that read as
# "nothing to report". The fix is a probe that matches the code's SHAPE, plus a
# GUIDE pointer to it. This suite pins both, on SYNTHETIC fixtures only: it
# never reads a real claude binary, so it runs (and means the same) on a CI
# runner without one.
#
# Every negative control doctors ONE structural fact of an otherwise-valid
# fixture and asserts the probe names THAT step as UNRESOLVED, so a red here
# cannot be produced by an unrelated mismatch.
#
# Run: bash monitor/cc-harness/test-probe-2g-limits.sh
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/../watcher/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
PROBE="$_test_dir/probe-2g-limits.py"
GUIDE="$REPO_ROOT/skills/nexus.cc-update/GUIDE.md"
WORK=$(mktemp -d -t nxp2g-XXXXXX)
th_trap_exit 'rm -rf "$WORK"'

# The fixture: the minified structure the probe matches, with filler between
# the pieces so the probe's distance windows (400 B after the wiring, 6 KB
# before the batcher) are exercised rather than trivially satisfied.
# $1 = output path; $2.. = sed expressions applied to the assembled text
# (each doctors exactly one fact for a negative control).
build_fixture() {
    local out="$1"; shift
    local pad; pad=$(printf 'x%.0s' $(seq 1 2000))
    {
        printf '%s' '"use strict";/*head*/'"$pad"
        printf '%s' 'var Q=10,R=2000;function P(m,n,t=Date.now){let e=m,o=t();return e}'
        printf '%s' "/*mid1*/$pad"
        printf '%s' 'var b=500,E=3000,J=200,L=1048576;function H(){return L}'"/*gap*/${pad}"
        printf '%s' 'function G(e,t=(n)=>{let o=setTimeout(n,J);return()=>clearTimeout(o)}){let a=[],c="";'
        printf '%s' 'if(c.length>b)c=c.slice(0,b);if(a.length>E)a=a.slice(0,E);e(a)}'
        printf '%s' "/*mid2*/$pad"
        printf '%s' 'var S;if(S=P(Q,R)){let z=0;function y(){if(z===0)return;'
        printf '%s' 'log(`[plugin monitor "x" suppressed ${z} events]`)}}'
        printf '%s' "/*mid3*/$pad"
        printf '%s' 'function arm(x){return G(x.onBatch)}/*tail*/'
    } >"$out.raw"
    if (( $# )); then
        local args=() e
        for e in "$@"; do args+=(-e "$e"); done
        sed "${args[@]}" "$out.raw" >"$out"
    else
        cp "$out.raw" "$out"
    fi
    rm -f "$out.raw"
}

run_probe() {   # run_probe <file> <label> — sets OUT, ERR, RC
    OUT=$(python3 "$PROBE" "$@" 2>"$WORK/err"); RC=$?
    ERR=$(cat "$WORK/err")
}

echo '=== the probe ships, and runs on this host python3 ==='
assert_eq "probe-2g-limits.py exists" "$([[ -f "$PROBE" ]] && echo yes || echo no)" "yes"
assert_eq "probe-2g-limits.py is executable" "$([[ -x "$PROBE" ]] && echo yes || echo no)" "yes"

echo '=== positive: the synthetic fixture resolves all five, rc 0 ==='
build_fixture "$WORK/good.js"
# Fixture self-check: the doctoring below must bite on text that IS there.
assert_contains "fixture carries the line-cut use" "$(cat "$WORK/good.js")" 'c.length>b'
run_probe "$WORK/good.js" fx
assert_rc "#1734 a well-formed fixture resolves (rc 0)" "$RC" "0"
assert_contains "#1734 …to exactly the five fixture values" "$OUT" \
    "RESULT [fx] bucket_capacity=10 bucket_refill_ms=2000 line_cut=500 batch_cut=3000 batch_interval_ms=200"
assert_not_contains "#1734 …with no UNRESOLVED step" "$OUT" "UNRESOLVED"

echo '=== positive: a non-monitor consumer of the bucket EARLIER in the bundle is skipped ==='
build_fixture "$WORK/decoy.js" 's#/\*mid1\*/#var D=P(Q,R)){let k=0;function j(){if(k===0)return;noop()}}/*mid1*/#'
run_probe "$WORK/decoy.js" decoy
assert_rc "a decoy bucket wiring not feeding the monitor does not shadow the real one" "$RC" "0"

echo '=== negative: /bin/ls holds none of it -> UNRESOLVED, rc 3 ==='
run_probe /bin/ls ls
assert_rc "#1734 /bin/ls is UNRESOLVED (rc 3), never a guessed value" "$RC" "3"
assert_contains "#1734 …and the RESULT line says UNRESOLVED" "$OUT" "RESULT [ls] UNRESOLVED"
assert_not_contains "#1734 …with no value printed" "$OUT" "line_cut="

echo '=== negative: the line-cut USE doctored -> rc 3 ==='
build_fixture "$WORK/noline.js" 's/c\.length>b/c.length>9999/'
run_probe "$WORK/noline.js" noline
assert_rc "#1734 a declared line cut the batcher does not use is UNRESOLVED (rc 3)" "$RC" "3"
assert_contains "#1734 …naming the batcher-constants step" "$OUT" \
    "UNRESOLVED: the declared constants are not the ones the batcher cuts with"
assert_not_contains "#1734 …and no line_cut value is reported" "$OUT" "line_cut="

echo '=== negative: the monitor wiring points at OTHER constants -> rc 3 ==='
build_fixture "$WORK/rewired.js" 's/S=P(Q,R)/S=P(X,Y)/'
run_probe "$WORK/rewired.js" rewired
assert_rc "#1734 a monitor wired to undeclared constants is UNRESOLVED (rc 3)" "$RC" "3"
assert_contains "#1734 …naming the wiring mismatch" "$OUT" \
    "UNRESOLVED: monitor wiring uses P(X,Y), not the declared Q,R"
assert_not_contains "#1734 …and no bucket value is reported" "$OUT" "bucket_capacity="

echo '=== negative: two DISAGREEING monitor wirings -> rc 3 (no basis to pick one) ==='
build_fixture "$WORK/twowire.js" \
    's#/\*mid3\*/#var T=P(U,V)){let w=0;function q(){if(w===0)return;log(`[plugin monitor "y" suppressed ${w} events]`)}}/*mid3*/#'
run_probe "$WORK/twowire.js" twowire
assert_rc "two distinct plugin-monitor wirings are UNRESOLVED (rc 3)" "$RC" "3"

echo '=== negative: no G(<x>.onBatch) arming -> rc 3 ==='
build_fixture "$WORK/noarm.js" 's/G(x\.onBatch)/G(x.other)/'
run_probe "$WORK/noarm.js" noarm
assert_rc "a batcher the monitor never arms is UNRESOLVED (rc 3)" "$RC" "3"

echo '=== negative: an EMPTY file is read, holds nothing -> rc 3 ==='
: >"$WORK/empty"
run_probe "$WORK/empty" empty
assert_rc "an empty file is UNRESOLVED (rc 3), not a crash" "$RC" "3"

echo '=== usage: bad invocation / unreadable file -> rc 2, never 0 or 3 ==='
run_probe
assert_rc "no arguments is a usage error (rc 2)" "$RC" "2"
assert_contains "…printing the probe's own usage line" "$ERR" "usage: probe-2g-limits.py <claude-binary> <label>"
run_probe "$WORK/good.js"
assert_rc "a missing <label> is a usage error (rc 2)" "$RC" "2"
run_probe "$WORK/does-not-exist" x
assert_rc "an unreadable binary path is rc 2 (no measurement made)" "$RC" "2"
assert_contains "…naming the read failure" "$ERR" "ERROR: cannot read"

echo '=== GUIDE §2g points at the probe, not at minified names ==='
bullet=$(awk '/^- \*\*The host.s per-monitor OUTPUT LIMITS\*\*/{on=1; print; next} on && /^- \*\*/{exit} on{print}' "$GUIDE")
assert_contains "the OUTPUT LIMITS bullet was found" "$bullet" "OUTPUT LIMITS"
assert_contains "#1734 the bullet names monitor/cc-harness/probe-2g-limits.py" "$bullet" \
    "monitor/cc-harness/probe-2g-limits.py <claude.exe> <label>"
assert_contains "#1734 …and says rc 3 is UNRESOLVED, recorded as unverified" "$bullet" "rc 3 means UNRESOLVED"
for n in 'dce=' 'Ate=' 'bVe='; do
    assert_not_contains "#1734 the bullet no longer names the minified \`$n\`" "$bullet" "$n"
done

echo
EXPECTED=30
if (( PASS + FAIL != EXPECTED )); then printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$(( PASS + FAIL ))" "$EXPECTED" >&2; _th_fail; fi
th_summary_and_exit
