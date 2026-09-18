#!/usr/bin/env bash
# Tests for monitor/nexus-root-sensitivity.sh (your-org/nexus-code#655).
#
# The tool under test is a DETECTOR, and the failure mode this whole issue
# chain is named for is a detector whose zeros nobody validated. So these tests
# are mostly about the instrument's RESPONSE CURVE rather than its plumbing:
# it must fire on a known positive, stay quiet on a known negative, and — the
# part that took a real false negative to learn — refuse to report "hermetic"
# when it could not actually have observed a leak.
#
# Everything here uses SYNTHETIC probe targets so the suite belongs in the fast
# band. The expensive validation against the real known positive
# (test-worker-nproc-bound.sh with its scrub reverted, ~5.5 min at loadavg 30)
# lives in `nexus-root-sensitivity.sh self-test` and is exercised by the
# inherited-root CI job, not here.
#
# Run: bash monitor/watcher/test-nexus-root-sensitivity.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

# HERMETIC ENV (your-org/nexus-code#655). This suite builds a fixture and runs
# a real monitor/ script against it; spawn-worker.sh honours an INHERITED
# NEXUS_ROOT over its own script-relative root (#577), so an agent shell that
# exports NEXUS_ROOT would re-root the run under test onto the operator's
# primary tree. The tool under test is the one that detects exactly this, and
# a detector that leaks the thing it detects is not a joke worth shipping.
unset NEXUS_ROOT

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOOL="$_test_dir/../nexus-root-sensitivity.sh"
REPO="$(cd "$_test_dir/../.." && pwd)"

PASS=0
FAIL=0
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
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

[ -x "$TOOL" ] || { echo "missing or non-executable $TOOL" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nrs-test-XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"

# PRE-RUN SWEEP (your-org/nexus-code#1511). Until #1511 the attribution block
# below planted its `test-zz-attr-*.sh` fixtures INTO THE LIVE CHECKOUT at
# $REPO/monitor/watcher/ and removed them from an EXIT trap — which does not
# survive SIGKILL, and the band is SIGKILLed routinely (88 ceiling kills in one
# week, #1511). A leftover plant is an executable `test-*.sh` inside CI's and
# run-tests.sh's discovery glob: it does not merely confuse a population probe,
# it JOINS the suite population. The plants now live under $WORK (via the
# tool's NRS_SUITE_ROOT seam), so nothing this run does can leave one; this
# sweep is for residue from a killed PRE-#1511 run, and it is LOUD when it
# removes anything — a stray is reported, never silently reaped.
for _stray in "$REPO"/monitor/watcher/test-zz-attr-*.sh; do
    [ -e "$_stray" ] || continue
    printf '  SWEEP: removing leftover plant %s (residue of a killed run; your-org/nexus-code#1511)\n' "$_stray" >&2
    rm -f "$_stray"
done

mk_target() {   # mk_target <name> <body...>
    local name="$1"; shift
    local f="$WORK/$name.sh"
    { echo '#!/usr/bin/env bash'; echo 'set -uo pipefail'; printf '%s\n' "$@"; } > "$f"
    chmod +x "$f"
    printf '%s\n' "$f"
}

# ---------------------------------------------------------------------------
echo "=== the detector fires on a GREEN suite that writes into the root ==="
# The whole reason this tool exists: a PASS/FAIL diff cannot see this case, so
# if the detector needs a red to notice, it is the same blindness in a new place.
leaky=$(mk_target leaky \
    'mkdir -p "$NEXUS_ROOT/monitor/.state"' \
    'echo leak >> "$NEXUS_ROOT/monitor/.state/action-log.jsonl"' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$("$TOOL" probe "$leaky" 2>&1); rc=$?
assert_contains "green-but-leaking is reported LEAK" "$out" "verdict=LEAK"
assert_contains "the report says rc=0 (the suite passed)" "$out" "rc=0"
assert_contains "the sensitive-but-green case is called out by name" "$out" "SENSITIVE BUT GREEN"
assert_contains "the leaked path is named" "$out" "monitor/.state/action-log.jsonl"
assert_eq "a leak exits 1" "$rc" "1"

# ---------------------------------------------------------------------------
echo "=== a suite that re-roots itself past the decoy is LEAK-AT-SOURCE, not hermetic (#1431) ==="
# `export NEXUS_ROOT="$_repo_root"` from BASH_SOURCE overrides the probe's
# NEXUS_ROOT before any child runs, so the write lands in the SOURCE checkout:
# nothing in the decoy, nothing in the output, and the verdict read HERMETIC
# while the checkout's live monitor/.state grew a heartbeat file. The source
# root is planted via NRS_SOURCE_ROOT so the test never touches this repo's own
# state directory; the plant writes there through a value it computes itself
# (as a BASH_SOURCE re-root does), not through the probe's NEXUS_ROOT.
srcroot="$WORK/srcroot"; mkdir -p "$srcroot/monitor/.state" "$srcroot/reports"
rerooter=$(mk_target rerooter \
    'export NEXUS_ROOT="'"$srcroot"'"' \
    'mkdir -p "$NEXUS_ROOT/monitor/.state/heartbeat"' \
    'echo "{}" > "$NEXUS_ROOT/monitor/.state/heartbeat/w1.json"' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$(NRS_SOURCE_ROOT="$srcroot" "$TOOL" probe "$rerooter" 2>&1); rc=$?
assert_contains "a re-rooted write into the SOURCE tree is LEAK-AT-SOURCE" "$out" "verdict=LEAK-AT-SOURCE"
assert_contains "…and the new source path is named" "$out" "monitor/.state/heartbeat/w1.json"
assert_not_contains "…and it is NOT reported hermetic" "$out" "verdict=hermetic"
assert_eq "LEAK-AT-SOURCE GATES BY DEFAULT: exit 1 like LEAK (a detector that reports and never blocks is the #1400 shape)" "$rc" "1"
assert_contains "…and it is listed under its own heading with the remedy" "$out" "WROTE INTO THE SOURCE CHECKOUT, not the decoy"
# The ONLY exemption is the per-suite, reason-required marker — the same
# mechanism the decoy arm proves out. Exempted, still PRINTED and counted.
rm -rf "$srcroot/monitor/.state/heartbeat"   # the plant must be NEW again, or the arm has nothing to gate
marked=$(mk_target marked \
    '# nexus-root-sensitivity: allow-source-leak — known BASH_SOURCE re-root, tracked as #1451' \
    'export NEXUS_ROOT="'"$srcroot"'"' \
    'mkdir -p "$NEXUS_ROOT/monitor/.state/heartbeat"' \
    'echo "{}" > "$NEXUS_ROOT/monitor/.state/heartbeat/w1.json"' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$(NRS_SOURCE_ROOT="$srcroot" "$TOOL" probe "$marked" 2>&1); rc=$?
assert_contains "a per-suite allow-source-leak marker WITH a reason → ALLOWED-AT-SOURCE" "$out" "verdict=ALLOWED-AT-SOURCE"
assert_contains "…the reason is printed (the leak stays VISIBLE and attributed)" "$out" "reason: known BASH_SOURCE re-root, tracked as #1451"
assert_eq "…and an allowed-at-source suite does not fail the probe" "$rc" "0"
rm -rf "$srcroot/monitor/.state/heartbeat"
bareled=$(mk_target bareled \
    '# nexus-root-sensitivity: allow-source-leak' \
    'export NEXUS_ROOT="'"$srcroot"'"' \
    'mkdir -p "$NEXUS_ROOT/monitor/.state/heartbeat"' \
    'echo "{}" > "$NEXUS_ROOT/monitor/.state/heartbeat/w1.json"' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$(NRS_SOURCE_ROOT="$srcroot" "$TOOL" probe "$bareled" 2>&1); rc=$?
assert_contains "POTENCY: a marker WITHOUT a reason does not exempt — still LEAK-AT-SOURCE" "$out" "verdict=LEAK-AT-SOURCE"
assert_contains "…and the rejection says why" "$out" "marker REJECTED"
assert_eq "…and it still exits 1" "$rc" "1"
rm -rf "$srcroot/monitor/.state/heartbeat"
# CONTROL: a pre-existing source-tree file that merely CHANGES is the watcher's
# noise on a primary, not this suite's write — only NEW paths count.
printf 'old\n' > "$srcroot/monitor/.state/action-log.jsonl"
appender=$(mk_target appender \
    'echo "{\"event\":\"x\"}" >> "'"$srcroot"'/monitor/.state/action-log.jsonl"' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$(NRS_SOURCE_ROOT="$srcroot" "$TOOL" probe "$appender" 2>&1)
assert_not_contains "CONTROL: an append to an EXISTING source file is not LEAK-AT-SOURCE (primary noise)" "$out" "verdict=LEAK-AT-SOURCE"

# ---------------------------------------------------------------------------
echo "=== a QUOTED marker is fixture DATA, not a declaration (#1454) ==="
# The parser used to be an unanchored `grep -m1 -F` over the whole file, so a
# suite that merely QUOTED the marker — in a mk_target argument, a heredoc, a
# comment about the marker — was read as declaring it, and the "reason" it
# extracted still carried the trailing `' \` of the shell literal. THIS suite
# plants both markers as fixture data (the `marked`/`withmk` targets above),
# so under the old parser the gate's own unit suite, a band member, was
# self-exempt on BOTH arms: a real leak from it would have read ALLOWED.
#
# A fixture that contains the construct it tests is indistinguishable from the
# construct itself to any predicate that does not anchor. So: the marker is a
# COMMENT AT LINE START, or it is not a marker.
rm -rf "$srcroot/monitor/.state/heartbeat"
quoted_src=$(mk_target quoted_src \
    "fixture_line='# nexus-root-sensitivity: allow-source-leak — this is fixture DATA, not a declaration'" \
    'export NEXUS_ROOT="'"$srcroot"'"' \
    'mkdir -p "$NEXUS_ROOT/monitor/.state/heartbeat"' \
    'echo "{}" > "$NEXUS_ROOT/monitor/.state/heartbeat/w1.json"' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$(NRS_SOURCE_ROOT="$srcroot" "$TOOL" probe "$quoted_src" 2>&1); rc=$?
assert_contains "a QUOTED allow-source-leak literal does not exempt — still LEAK-AT-SOURCE" "$out" "verdict=LEAK-AT-SOURCE"
assert_not_contains "…and is never reported ALLOWED-AT-SOURCE" "$out" "verdict=ALLOWED-AT-SOURCE"
assert_eq "…exiting 1" "$rc" "1"
rm -rf "$srcroot/monitor/.state/heartbeat"
quoted_dec=$(mk_target quoted_dec \
    "note='# nexus-root-sensitivity: allow-inherited-root — fixture DATA, not a declaration'" \
    'mkdir -p "$NEXUS_ROOT/monitor/.state"' \
    'echo leak >> "$NEXUS_ROOT/monitor/.state/action-log.jsonl"' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$("$TOOL" probe "$quoted_dec" 2>&1); rc=$?
assert_contains "a QUOTED allow-inherited-root literal does not exempt — still LEAK" "$out" "verdict=LEAK"
assert_not_contains "…and is never reported ALLOWED" "$out" "verdict=ALLOWED"
assert_eq "…exiting 1" "$rc" "1"
# THE SELF-EXEMPTION CONTROL: this very file plants both markers as data and
# must declare NEITHER. Asked of the parser directly (the `marker-reason`
# seam), because probing this suite from inside itself is recursion, not a
# control. The positive control beside it is what makes the two zeros mean
# something: the same parser, over a file that DOES declare, returns the reason.
"$TOOL" marker-reason "${BASH_SOURCE[0]}" allow-source-leak >/dev/null 2>&1; rc=$?
assert_eq "SELF-EXEMPTION CONTROL: this suite does NOT declare allow-source-leak (rc 1)" "$rc" "1"
"$TOOL" marker-reason "${BASH_SOURCE[0]}" allow-inherited-root >/dev/null 2>&1; rc=$?
assert_eq "SELF-EXEMPTION CONTROL: this suite does NOT declare allow-inherited-root (rc 1)" "$rc" "1"
r=$("$TOOL" marker-reason "$marked" allow-source-leak 2>&1); rc=$?
assert_eq "POSITIVE CONTROL: the marked fixture DOES declare (rc 0)" "$rc" "0"
assert_eq "…with exactly its reason, no separator and no trailing syntax" "$r" "known BASH_SOURCE re-root, tracked as #1451"
# The separator is a TOKEN, not a byte class: under a C locale `[—-]` stripped
# two of an en dash's three bytes and left one as a "non-empty" reason.
endash=$(mk_target endash '# nexus-root-sensitivity: allow-inherited-root – deliberate en dash, see #1454' 'exit 0')
r=$("$TOOL" marker-reason "$endash" allow-inherited-root 2>&1); rc=$?
assert_eq "an EN-DASH separator is stripped whole (rc 0)" "$rc" "0"
assert_eq "…leaving exactly the reason" "$r" "deliberate en dash, see #1454"
indented=$(mk_target indented '    #  nexus-root-sensitivity: allow-inherited-root: indented, colon-separated' 'exit 0')
r=$("$TOOL" marker-reason "$indented" allow-inherited-root 2>&1); rc=$?
assert_eq "an INDENTED comment marker still declares (rc 0)" "$rc" "0"
assert_eq "…with a colon separator stripped" "$r" "indented, colon-separated"
bare=$(mk_target bare '# nexus-root-sensitivity: allow-inherited-root' 'exit 0')
"$TOOL" marker-reason "$bare" allow-inherited-root >/dev/null 2>&1; rc=$?
assert_eq "a marker with NO reason is rc 2 (present, invalid) — not 0, not 1" "$rc" "2"
prefixed=$(mk_target prefixed '# nexus-root-sensitivity: allow-inherited-rootless — a DIFFERENT token' 'exit 0')
"$TOOL" marker-reason "$prefixed" allow-inherited-root >/dev/null 2>&1; rc=$?
assert_eq "a marker name that is only a PREFIX of the line's token does not match (rc 1)" "$rc" "1"

# ---------------------------------------------------------------------------
echo "=== attribute: the RUN-DERIVED population, gated on src (#1336) ==="
# The exported band runs EVERY suite; whatever they wrote into the checkout's
# monitor/.state is the population, and `ng`'s usage tap names the producer
# (#720). No predicate selects it, so no spelling can walk past it. Driven
# against a PLANTED root; the marker is read from the suite tree at
# monitor/<src>. That tree is NRS_SUITE_ROOT — a fixture under $WORK — so each
# case plants its `watcher/test-zz-attr-*.sh` file THERE, never into this
# checkout (your-org/nexus-code#1511: a plant in the live tree is an executable
# inside the discovery glob, and the EXIT trap that removed it does not survive
# the SIGKILL this band routinely gets). The assertion right after the first
# plant is the pin: the live checkout must hold NO such file while this block
# runs. It goes RED against the pre-#1511 tool, which ignored the seam here
# and looked the planted suite up in the live tree.
AROOT="$WORK/aroot"; mkdir -p "$AROOT/monitor/.state"
SUITEROOT="$WORK/suiteroot"; mkdir -p "$SUITEROOT/monitor/watcher"
_plant_suite() { printf '#!/usr/bin/env bash\n%s\nexit 0\n' "$2" > "$SUITEROOT/monitor/watcher/$1"; chmod +x "$SUITEROOT/monitor/watcher/$1"; }
_row() { printf '{"ts":"2026-09-04T10:30:13+0000","verb":"log-action","sub":"","origin":"agent","win":"","src":"%s","pid":1}\n' "$1"; }
_live_plants() { local n=0 f; for f in "$REPO"/monitor/watcher/test-zz-attr-*.sh; do [ -e "$f" ] && n=$(( n + 1 )); done; printf '%s\n' "$n"; }
# absent file -> 0
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "no ng-usage.jsonl in the root -> exit 0 (no attributable write)" "$rc" "0"
assert_contains "…and says so" "$out" "no attributable write"
# attributed, unmarked -> 1
_plant_suite test-zz-attr-leaker.sh ': leaks through ng'
assert_eq "the plant lives under \$WORK — the live checkout holds NO test-zz-attr-*.sh (#1511)" "$(_live_plants)" "0"
[ -x "$SUITEROOT/monitor/watcher/test-zz-attr-leaker.sh" ] || printf '  FAIL: the fixture plant is missing from NRS_SUITE_ROOT — the assertion above passed vacuously\n' >&2
{ _row watcher/test-zz-attr-leaker.sh; _row watcher/test-zz-attr-leaker.sh; } > "$AROOT/monitor/.state/ng-usage.jsonl"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "a row whose src names an UNMARKED suite -> exit 1" "$rc" "1"
assert_contains "…the suite is named as LEAK with its row count" "$out" "LEAK              2 row(s)  watcher/test-zz-attr-leaker.sh"
assert_contains "…and the remedy names th_pin_ng_state" "$out" "th_pin_ng_state"
# attributed + anchored marker -> 0, ALLOWED, reason printed
_plant_suite test-zz-attr-marked.sh '# nexus-root-sensitivity: allow-inherited-root — deliberate, attribution fixture #1336'
_row watcher/test-zz-attr-marked.sh > "$AROOT/monitor/.state/ng-usage.jsonl"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "a named suite carrying the anchored marker -> exit 0" "$rc" "0"
assert_contains "…reported ALLOWED with its reason (visible, counted, not failing)" "$out" "ALLOWED           1 row(s)  watcher/test-zz-attr-marked.sh   marker reason: deliberate, attribution fixture #1336"
# a QUOTED marker is not a declaration here either (#1454, same parser)
_plant_suite test-zz-attr-quoted.sh "x='# nexus-root-sensitivity: allow-inherited-root — fixture data'"
_row watcher/test-zz-attr-quoted.sh > "$AROOT/monitor/.state/ng-usage.jsonl"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "a QUOTED marker does not exempt an attributed suite (exit 1)" "$rc" "1"
# empty src -> UNATTRIBUTED, rc 0
printf '{"ts":"2026-09-04T10:30:13+0000","verb":"usage","sub":"","origin":"agent","win":"","src":"","pid":2}\n' > "$AROOT/monitor/.state/ng-usage.jsonl"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "a row with EMPTY src is UNATTRIBUTED and does not gate (exit 0)" "$rc" "0"
assert_contains "…and is printed as such with the limit stated" "$out" "UNATTRIBUTED      1 row(s) with no src"
# a non-tap file is listed, never gated
: > "$AROOT/monitor/.state/tmux-refused.log"
rm -f "$AROOT/monitor/.state/ng-usage.jsonl"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "a file the tap does not write (tmux-refused.log) is listed, exit 0" "$rc" "0"
assert_contains "…under the UNATTRIBUTED files heading" "$out" "> tmux-refused.log"
# mixed: one marked, one not -> 1, both printed
_row watcher/test-zz-attr-marked.sh > "$AROOT/monitor/.state/ng-usage.jsonl"
_row watcher/test-zz-attr-leaker.sh >> "$AROOT/monitor/.state/ng-usage.jsonl"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "one marked + one unmarked -> exit 1 (the unmarked one gates)" "$rc" "1"
assert_contains "…summary counts one leaking and one allowed" "$out" "leaking suites 1   allowed-by-marker 1"
# A src naming a suite ABSENT from the suite tree is attributed by name, and
# the tree it was looked up in is the one the seam selected — not this checkout.
_row watcher/test-zz-attr-nowhere.sh > "$AROOT/monitor/.state/ng-usage.jsonl"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "a src naming a suite present in NEITHER tree -> exit 1 (attributed by name)" "$rc" "1"
assert_contains "…and the lookup tree named in the diagnostic is the seam's, not the checkout" "$out" "not present under $SUITEROOT/monitor"
assert_eq "after the block, the live checkout still holds NO test-zz-attr-*.sh (#1511)" "$(_live_plants)" "0"
# The longjob launcher's arming.log carries the same producer field (column
# 5, from NEXUS_TEST_SUITE) and is gated the same way. Added after the
# bundle-2609 soak measured 17 fixture rows in the operator's LIVE arming.log
# that this gate printed as UNATTRIBUTED and did not flip on.
_arow() { printf '1789600000\torchestrator\tskipped\tbinary does not advertise --plugin-dir\t%s\n' "$1"; }
rm -f "$AROOT/monitor/.state/ng-usage.jsonl"; mkdir -p "$AROOT/monitor/.state/longjob"
_arow watcher/test-zz-attr-leaker.sh > "$AROOT/monitor/.state/longjob/arming.log"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "an arming.log row whose column 5 names an UNMARKED suite -> exit 1 (no ng row at all)" "$rc" "1"
assert_contains "…the LEAK line names the suite and the file" "$out" "LEAK              1 row(s)  watcher/test-zz-attr-leaker.sh   in longjob/arming.log"
assert_not_contains "…and arming.log is no longer listed as an unattributed FILE" "$out" "    > longjob/arming.log"
_arow watcher/test-zz-attr-marked.sh > "$AROOT/monitor/.state/longjob/arming.log"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "an arming.log row naming a suite with the anchored marker -> exit 0" "$rc" "0"
assert_contains "…reported ALLOWED" "$out" "ALLOWED           1 row(s)  watcher/test-zz-attr-marked.sh"
_arow '' > "$AROOT/monitor/.state/longjob/arming.log"
out=$(NRS_SUITE_ROOT="$SUITEROOT" "$TOOL" attribute "$AROOT" 2>&1); rc=$?
assert_eq "an arming.log row with an EMPTY column 5 (a real launch) -> exit 0, not gated" "$rc" "0"
assert_contains "…printed as UNATTRIBUTED in that file" "$out" "UNATTRIBUTED      1 row(s) with no src in longjob/arming.log"
rm -rf "$AROOT/monitor/.state/longjob"

# ---------------------------------------------------------------------------
echo "=== the detector stays quiet on a suite that touches nothing ==="
# Without this, "fires on the positive" is satisfied by a detector that fires
# on everything, whose positives carry no information.
clean=$(mk_target clean \
    'unset NEXUS_ROOT' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$("$TOOL" probe "$clean" 2>&1); rc=$?
assert_contains "a hermetic suite is reported hermetic" "$out" "verdict=hermetic"
assert_not_contains "a hermetic suite is not reported as a leak" "$out" "verdict=LEAK"
assert_eq "no leak exits 0" "$rc" "0"

# ---------------------------------------------------------------------------
echo "=== a suite that pins NEXUS_ROOT passes, without scrubbing it ==="
# The PROPERTY is "the suite controls NEXUS_ROOT for its spawns", and pinning
# satisfies it. #655 round 12 enumerated the class with `grep 'unset
# NEXUS_ROOT'` — a spelling test — and inflated the candidate set 2.3x (28
# reported, 12 real) because 16 suites pin instead. A gate that only accepts
# one spelling would redden every one of those.
pinned=$(mk_target pinned \
    'FAKE="$(mktemp -d)"; mkdir -p "$FAKE/monitor/.state"' \
    'env NEXUS_ROOT="$FAKE" sh -c '"'"'echo x >> "$NEXUS_ROOT/monitor/.state/action-log.jsonl"'"'"'' \
    'rm -rf "$FAKE"' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$("$TOOL" probe "$pinned" 2>&1)
assert_contains "pinning (not scrubbing) is accepted as hermetic" "$out" "verdict=hermetic"

# ---------------------------------------------------------------------------
echo "=== a STATE-class suite 'fixed' by env -u NEXUS_ROOT is reported LEAK, not hermetic ==="
# your-org/nexus-code#1349. `ng`'s state resolver is FOUR arms; scrubbing
# NEXUS_ROOT advances it to arm 3 (config nexus.root), which on an operator's
# primary IS the primary. A tracked-files decoy had no config/nexus.yml, so
# arm 3 answered the example placeholder, `ng` wrote nowhere, and this probe
# reported the scrub-"fixed" suite hermetic — the false negative produced by
# following the gate's own remediation text. The decoy now names itself.
scrub=$(mk_target scrub \
    'root="$NEXUS_ROOT"' \
    'env -u NEXUS_ROOT -u NEXUS_LOCALS -u NEXUS_STATE_DIR "$root/monitor/ng" log-action probe --event scrub-leak >/dev/null 2>&1' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$("$TOOL" probe "$scrub" 2>&1); rc=$?
assert_contains "env -u NEXUS_ROOT on a STATE-class writer is LEAK (arm 3 lands in the decoy)" "$out" "verdict=LEAK"
assert_contains "…and the leaked path is the decoy's action log" "$out" "monitor/.state/action-log.jsonl"
assert_eq "…exiting 1" "$rc" "1"
assert_not_contains "…with no warning that the decoy could not name itself" "$out" "does not resolve nexus.root to the decoy"

# The complement (#1386): an AMBIENT NEXUS_STATE_DIR in the caller's shell —
# the very pin #1349 prescribes for ad-hoc tooling — must not blind the
# probe. Arm 1 is unconditional, so without the scrub every `ng` write in
# every probed suite would land in the pin and every suite would read
# hermetic. The target must write THROUGH `ng` — a direct `echo >>` into
# the root cannot be redirected by any pin and would pass here vacuously.
ngwriter=$(mk_target ngwriter \
    '"$NEXUS_ROOT/monitor/ng" log-action probe --event pin-blind >/dev/null 2>&1' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
_pin=$(mktemp -d "$WORK/ambient-pin-XXXXXX")
out=$(NEXUS_STATE_DIR="$_pin" "$TOOL" probe "$ngwriter" 2>&1)
assert_contains "an ambient NEXUS_STATE_DIR does not blind the probe (an ng-writing suite is still LEAK)" "$out" "verdict=LEAK"
assert_eq "…and nothing was routed into the ambient pin" "$(find "$_pin" -type f | wc -l)" "0"

# ---------------------------------------------------------------------------
echo "=== a probe that could not have observed a leak is VACUOUS, not clean ==="
# The false negative that shipped in this tool's own first self-test: a decoy
# missing skills/ made spawn-worker abort at rc=2 BEFORE writing state, and the
# known positive came back `hermetic`. "Nothing leaked" and "nothing could have
# leaked" must never render as the same verdict.
vacuous=$(mk_target vacuous \
    'echo "spawn-worker: floor file missing: $NEXUS_ROOT/skills/nexus.worker-defaults/SKILL.md" >&2' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$("$TOOL" probe "$vacuous" 2>&1); rc=$?
assert_contains "an incomplete decoy is reported VACUOUS" "$out" "verdict=VACUOUS"
assert_not_contains "VACUOUS is NOT downgraded to hermetic" "$out" "verdict=hermetic"
assert_contains "the run is declared not-a-clean-bill" "$out" "NOT a clean bill of health"
# A LONE vacuous probe measured nothing at all, so it is 77 (NOT MEASURED),
# not 3 (partially measured). Both are non-zero; the distinction is the point.
assert_eq "a lone vacuous probe exits 77 (measured nothing), never 0" "$rc" "77"

# ---------------------------------------------------------------------------
echo "=== a run that MEASURED NOTHING is not a run that measured clean ==="
# The tool's own defect class, found inside the tool built to retire it:
# `probe /nonexistent/x.sh` printed `leaked: 0 ... hermetic: 0` and returned 0
# — a clean bill of health issued from zero measurements. Exit 77 now, and the
# accounting names the suite rather than dropping it from the denominator.
out=$("$TOOL" probe /nonexistent/definitely-not-here.sh 2>&1); rc=$?
assert_eq "a probe of a missing path exits 77, never 0" "$rc" "77"
assert_contains "the unmeasured suite is named, not silently dropped" "$out" "NOT MEASURED"
assert_contains "the summary states how many were actually MEASURED" "$out" "MEASURED: 0"
# ...and the count is a denominator, so a mixed run is distinguishable again.
clean2=$(mk_target clean2 'unset NEXUS_ROOT' 'echo "=== summary: 1 passed, 0 failed ==="' 'exit 0')
out=$("$TOOL" probe "$clean2" /nonexistent/nope.sh 2>&1); rc=$?
assert_eq "measured-some + unmeasured-some exits 3 (incomplete)" "$rc" "3"
assert_contains "the mixed run reports one measured" "$out" "MEASURED: 1"

# ---------------------------------------------------------------------------
echo "=== the advertised marker is read by the GATE, and needs a reason ==="
# Round 12's property is `scrub OR pin OR explicit marker`. The third disjunct
# shipped ADVERTISED BUT UNREAD for four commits: `probe`'s remediation text
# told the author to add the marker while only `spellings` looked at it, and
# the PR is emphatic that `spellings` is never the gate. A remediation
# instruction that does not work is worse than none.
mk_leaky() {
    local name="$1" marker="$2"
    mk_target "$name" "$marker" \
        'mkdir -p "$NEXUS_ROOT/monitor/.state"' \
        'echo leak >> "$NEXUS_ROOT/monitor/.state/action-log.jsonl"' \
        'echo "=== summary: 1 passed, 0 failed ==="' \
        'exit 0'
}
nomk=$(mk_leaky nomk ':')
out=$("$TOOL" probe "$nomk" 2>&1); rc=$?
assert_eq "an unmarked leak still fails" "$rc" "1"

withmk=$(mk_leaky withmk '# nexus-root-sensitivity: allow-inherited-root — deliberate, see #655')
out=$("$TOOL" probe "$withmk" 2>&1); rc=$?
assert_eq "a marked leak is exempted by the GATE (exit 0)" "$rc" "0"
assert_contains "the exemption is reported, not hidden" "$out" "ALLOWED"
assert_contains "the marker's reason is echoed back" "$out" "deliberate, see #655"

badmk=$(mk_leaky badmk '# nexus-root-sensitivity: allow-inherited-root')
out=$("$TOOL" probe "$badmk" 2>&1); rc=$?
assert_eq "a marker with NO reason does not exempt" "$rc" "1"
assert_contains "the reasonless marker is called out" "$out" "marker REJECTED"

# ---------------------------------------------------------------------------
echo "=== a suite that declines to run yields NO EVIDENCE, not a pass ==="
# your-org/nexus-code#568 A6: before SKIP existed, rc==0 meant PASS and every
# self-skipping suite counted as coverage it never provided.
skipper=$(mk_target skipper 'exit 77')
out=$("$TOOL" probe "$skipper" 2>&1); rc=$?
assert_contains "exit 77 is reported SKIP" "$out" "verdict=SKIP"
assert_contains "SKIP is spelled out as no evidence" "$out" "NO EVIDENCE"
assert_eq "a lone skip exits 77 (measured nothing), never 0" "$rc" "77"

# ENVSKIP — the SAME claim for the OTHER decline (your-org/nexus-code#1283).
# A suite that RAN, asserted, then found the machine unable exits 69. Before
# this arm existed it matched no case here and fell to `else verdict=hermetic`
# — a CLEAN BILL OF HEALTH for a suite that produced no evidence, issued by the
# tool whose exit-code note says a run that measured nothing must never be 0.
#
# The asymmetry worth remembering: run-tests.sh's terminal arm is
# `rc != 0 -> FAIL`, so an unknown code fails CLOSED there; this classifier's
# terminal arm is PERMISSIVE, so the same code was absorbed as a pass. One new
# exit code, opposite directions in two consumers.
envskipper=$(mk_target envskipper 'exit 69')
out=$("$TOOL" probe "$envskipper" 2>&1); rc=$?
assert_contains "exit 69 is reported ENVSKIP, NOT hermetic" "$out" "verdict=ENVSKIP"
assert_not_contains "…and is never called hermetic" "$out" "verdict=hermetic"
assert_contains "ENVSKIP is spelled out as no evidence" "$out" "NO EVIDENCE"
assert_eq "a lone env-decline exits 77 (measured nothing), never 0" "$rc" "77"

# ---------------------------------------------------------------------------
echo "=== the decoy is a plausible AND sufficient nexus root ==="
# Two distinct requirements, and the second is the one that bit. The predicate
# spawn-worker.sh:598 checks (`-x monitor/spawn-worker.sh`, `-d config`) is
# NECESSARY — without it the re-root never fires and every probe is vacuous.
# It is not SUFFICIENT: the spawn proceeds past it and then dies on the worker
# floor under skills/. Both are asserted from the decoy the tool actually built.
spy=$(mk_target spy \
    'echo "DECOY=$NEXUS_ROOT"' \
    'for p in monitor/spawn-worker.sh config skills/nexus.worker-defaults/SKILL.md; do' \
    '  [ -e "$NEXUS_ROOT/$p" ] && echo "HAVE $p" || echo "LACK $p"' \
    'done' \
    'echo "=== summary: 1 passed, 0 failed ==="' \
    'exit 0')
out=$("$TOOL" probe --keep-decoy "$spy" 2>&1)
# The probe prints the target's own stdout only on a leak, so re-run the spy
# against a decoy we can inspect directly by reading the retained work dir.
decoy_dir=$(sed -n 's/.*decoy retained at \(.*\)$/\1/p' <<<"$out" | head -1)
if [ -n "$decoy_dir" ] && [ -d "$decoy_dir/decoy" ]; then
    d="$decoy_dir/decoy"
    [ -x "$d/monitor/spawn-worker.sh" ] \
        && { echo "  PASS: decoy has an executable monitor/spawn-worker.sh"; PASS=$((PASS+1)); } \
        || { echo "  FAIL: decoy lacks executable monitor/spawn-worker.sh" >&2; FAIL=$((FAIL+1)); }
    [ -d "$d/config" ] \
        && { echo "  PASS: decoy has config/ (completes _sw_root_is_nexus)"; PASS=$((PASS+1)); } \
        || { echo "  FAIL: decoy lacks config/" >&2; FAIL=$((FAIL+1)); }
    # The regression guard for the false negative found on 2026-08-05.
    [ -f "$d/skills/nexus.worker-defaults/SKILL.md" ] \
        && { echo "  PASS: decoy carries the worker floor — spawns reach the write"; PASS=$((PASS+1)); } \
        || { echo "  FAIL: decoy lacks skills/nexus.worker-defaults/SKILL.md — probes will be VACUOUS" >&2; FAIL=$((FAIL+1)); }
    rm -rf "$decoy_dir"
else
    echo "  FAIL: --keep-decoy did not retain a decoy to inspect" >&2; FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------------------
echo "=== audit maps PID-suffixed fixture windows, and never drops one ==="
# A fixture window carrying a $$ suffix evaded #655 round 12's first mapping
# pass, and the suite it came from was missed as a result — hence the stem
# fallback. A name that maps to nothing must be REPORTED, not discarded: a
# silently dropped row under-counts the class, which is the error this tool
# exists to stop making.
#
# THE WINDOW LITERALS BELOW ARE ASSEMBLED FROM PIECES ON PURPOSE. The mapper
# attributes a window to any suite whose text contains the name, and this file
# would otherwise contain every name it tests — so it would be attributed to
# itself and appear in the audit as a member. Splitting the strings keeps the
# contiguous bytes out of the file, including out of THIS comment. (Writing one
# of them in prose is exactly how the first draft of this test failed.)
pid_win="cwd-leak-""test-2250"          # -> monitor/watcher/test-spawn-worker-cwd.sh
lit_win="nproc-""default"               # -> monitor/watcher/test-worker-nproc-bound.sh
orphan_win="qqzz-nrs-""unmappable-000"  # -> nothing, anywhere
synthlog="$WORK/action-log.jsonl"
{
  printf '{"event":"spawn","window":"%s","workdir":"/tmp/x/nexus/work/s","rerooted-from":"/tmp/x/nexus","ts":"2026-07-30T12:53:23-07:00"}\n' "$pid_win"
  printf '{"event":"spawn","window":"%s","workdir":"/tmp/y/nexus/work/s","rerooted-from":"/tmp/y/nexus","ts":"2026-07-30T13:06:23-07:00"}\n' "$lit_win"
  printf '{"event":"spawn","window":"%s","workdir":"/tmp/z/nexus/work/s","rerooted-from":"/tmp/z/nexus","ts":"2026-07-30T13:10:00-07:00"}\n' "$orphan_win"
  printf '{"event":"spawn","window":"real-worker","workdir":"/shared/real/work/x","ts":"2026-07-30T13:11:00-07:00"}\n'
} > "$synthlog"
out=$("$TOOL" audit --no-verify --log "$synthlog" 2>&1)
assert_contains "PID-suffixed window maps via the stem fallback" "$out" "test-spawn-worker-cwd.sh"
assert_contains "literal window name maps directly" "$out" "test-worker-nproc-bound.sh"
assert_contains "an unmappable window is reported UNMAPPED" "$out" "UNMAPPED"
assert_contains "only fixture rows are counted (3 of 4)" "$out" "rerooted-from: 3"

# ---------------------------------------------------------------------------
echo "=== a suite that only RECORDS a window is not called its producer ==="
# Controlled fixtures via NRS_SUITE_ROOT. Asserting this against the real tree
# is unfalsifiable from inside the repo — the earlier attempt passed with the
# exclusion deleted, because the only recording file (this one) had been made
# non-self-referential. Two planted suites, identical but for HOW they mention
# the window: one records it in an action-log line, one assigns it. Only the
# assigner is a producer, and the mutant that removes the exclusion now reddens
# this instead of sailing through.
FAKEROOT="$WORK/fakeroot"
mkdir -p "$FAKEROOT/monitor/watcher"
recorder="$FAKEROOT/monitor/watcher/test-zz-recorder.sh"
producer="$FAKEROOT/monitor/watcher/test-zz-producer.sh"
tgt="planted-""win-777"
printf '#!/usr/bin/env bash\n# fixture: RECORDS the window in a log line\necho %s{"event":"spawn","window":"%s","workdir":"/tmp/q"}%s\n' \
       "'" "$tgt" "'" > "$recorder"
printf '#!/usr/bin/env bash\n# fixture: PRODUCES the window\nWINDOW_NAME="%s"\n' "$tgt" > "$producer"
plantlog="$WORK/planted-log.jsonl"
printf '{"event":"spawn","window":"%s","workdir":"/tmp/q/nexus/w","rerooted-from":"/tmp/q/nexus","ts":"2026-08-05T00:00:00-07:00"}\n' "$tgt" > "$plantlog"
out=$(NRS_SUITE_ROOT="$FAKEROOT" "$TOOL" audit --no-verify --log "$plantlog" 2>&1)
assert_contains "the assigning suite IS attributed" "$out" "test-zz-producer.sh"
assert_not_contains "the recording suite is NOT attributed" "$out" "test-zz-recorder.sh"

# ---------------------------------------------------------------------------
echo "=== an empty audit says lower-bound, not all-clear ==="
# A retrospective instrument reports on suites that HAVE RUN under an exported
# root. Zero rows is silence, and this chain's dominant defect is silence read
# as absence.
empty="$WORK/empty-log.jsonl"
echo '{"event":"spawn","window":"w","workdir":"/shared/real/work/x"}' > "$empty"
out=$("$TOOL" audit --log "$empty" 2>&1)
assert_contains "an empty audit refuses to read as a clearance" "$out" "not a clearance"

# ---------------------------------------------------------------------------
echo "=== the static spelling view is labelled a diagnostic, not a gate ==="
# #703/#704: this repo has already shipped a spelling-enumerating lint inside a
# PR whose own headline said to check the range instead. The static view is
# kept for comparison, and its own output has to say what it is.
out=$("$TOOL" spellings 2>&1 | head -2)
assert_contains "spellings output declares itself DIAGNOSTIC ONLY" "$out" "DIAGNOSTIC ONLY"

# ---- summary --------------------------------------------------------------

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
