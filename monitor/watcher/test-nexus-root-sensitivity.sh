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
    if grep -qF -- "$needle" <<<"$hay"; then
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
  printf '{"event":"spawn","window":"real-worker","workdir":"/fh/real/work/x","ts":"2026-07-30T13:11:00-07:00"}\n'
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
echo '{"event":"spawn","window":"w","workdir":"/fh/real/work/x"}' > "$empty"
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
