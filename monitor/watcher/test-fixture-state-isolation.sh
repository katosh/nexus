#!/usr/bin/env bash
# test-fixture-state-isolation.sh — a fixture `ng` must not be able to reach the
# INHERITED NEXUS_ROOT (your-org/nexus-code#833).
#
# THE DEFECT. Copying `ng` into a fixture does NOT sandbox it.
# `_resolve_state_dir` prefers `$NEXUS_STATE_DIR`, then the INHERITED
# `$NEXUS_ROOT`, and only then its own location. So a fixture `ng` started from
# an agent shell — where NEXUS_ROOT points at the operator's primary — appends
# to the OPERATOR'S canonical state while every assertion passes and the suite
# exits 0. Measured on this host: 103 rows across three suites landed in the
# primary's `ng-usage.jsonl`, one burst produced by the very run that was
# measuring the leak.
#
# WHY THIS SUITE ASSERTS UNREACHABILITY AND NOT REDIRECTION. "The suite wrote
# somewhere else this run" is a fact about one run and one environment;
# redirection that depends on an env var being set correctly is one careless
# `export` away from leaking again. What is asserted here is that with the
# hazardous variable EXPORTED — the agent's real environment, reproduced, not
# avoided — the inherited root is still not written. The negative control
# proves the assertion can fail: the same fixture WITHOUT the pin writes.
#
# WHY THE PROPERTY IS EXERCISED ON A MINIMAL FIXTURE. Running the three real
# suites here would cost ~10 minutes and would assert the property for exactly
# the three files somebody remembered. The population-level guarantee is
# `monitor/nexus-root-sensitivity.sh band`, whose decoy now carries an empty
# `monitor/.state` and can therefore SEE this class at all; this suite pins the
# MECHANISM so that gate's verdicts are interpretable.
#
# Run: bash monitor/watcher/test-fixture-state-isolation.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
NG_REAL="$REPO_ROOT/monitor/ng"

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The inherited root an agent shell would supply: a nexus-shaped tree that
# ALREADY HAS monitor/.state. The directory is not decoration — `ng`'s usage tap
# is `[[ -n "$verb" && -d "$STATE_DIR" ]] || return 0`, so a root without one
# makes every fixture look clean by not exercising the write path. That is the
# same omission that made `nexus-root-sensitivity`'s decoy blind to this class.
CANARY="$WORK/canary"
mkdir -p "$CANARY/monitor/.state"

# A minimal fixture `ng`, built the way the leaking suites built theirs.
build_fixture() {   # <dir>
    local d="$1"
    mkdir -p "$d/monitor" "$d/config"
    cp "$NG_REAL" "$d/monitor/ng"
    cp "$REPO_ROOT/monitor/_bookkeeping.sh" "$d/monitor/_bookkeeping.sh"
    cat > "$d/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)       printf 'default-org/default-repo' ;;
    github.user_login) printf 'test-user' ;;
    *) [[ $# -ge 2 ]] && { printf '%s' "$2"; exit 0; }; exit 2 ;;
esac
STUB
    chmod +x "$d/config/load.sh"
}

# `[[ -f ]]` first, NOT `wc -l < file 2>/dev/null`. The `2>/dev/null` binds to
# `wc`, but it is the SHELL that fails to open a missing file for redirection,
# so the diagnostic reaches this suite's stderr regardless — and run-tests.sh
# prints a failing suite's stderr tail as its verdict, so ambient stderr noise
# is how a real message gets buried.
canary_rows() {
    local f="$CANARY/monitor/.state/ng-usage.jsonl"
    if [[ -f "$f" ]]; then wc -l < "$f"; else printf '0'; fi
}

# ===========================================================================
# 1. NEGATIVE CONTROL FIRST. Without the pin, the fixture reaches the inherited
#    root — so the assertion in case 2 is capable of failing, and the mechanism
#    is this one and not something incidental about the fixture.
# ===========================================================================
echo "=== 1. negative control: an UNPINNED fixture ng writes into the inherited root ==="
: > "$CANARY/monitor/.state/ng-usage.jsonl"
build_fixture "$WORK/unpinned"
NEXUS_ROOT="$CANARY" "$WORK/unpinned/monitor/ng" verbs >/dev/null 2>&1 || true
before=$(canary_rows)
if (( before > 0 )); then
    printf '  PASS: %s\n' "an unpinned fixture ng appended $before row(s) to the INHERITED root — the #833 mechanism, reproduced"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "the unpinned control wrote NOTHING; this suite cannot distinguish a fix from a no-op" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ===========================================================================
# 2. THE PROPERTY. Same fixture, same exported NEXUS_ROOT, with the pin the
#    shared builder now applies. The inherited root must be untouched.
# ===========================================================================
echo "=== 2. a PINNED fixture cannot reach the inherited root, with it exported ==="
rm -f "$CANARY/monitor/.state/ng-usage.jsonl"
build_fixture "$WORK/pinned"
mkdir -p "$WORK/pinned/monitor/.state"
NEXUS_ROOT="$CANARY" NEXUS_STATE_DIR="$WORK/pinned/monitor/.state" \
    "$WORK/pinned/monitor/ng" verbs >/dev/null 2>&1 || true
assert_eq "the inherited root has NO usage rows after a pinned run" \
    "$(canary_rows)" "0"
assert_file_exists "…and the write did happen, into the fixture — the pin redirects, it does not disable" \
    "$WORK/pinned/monitor/.state/ng-usage.jsonl"

# ===========================================================================
# 3. THE PIN IS NOT ENOUGH ON ITS OWN: the fixture's state dir must EXIST.
#    A pin at a path with no directory silently disables the tap, so a suite
#    that "passes" may simply have stopped exercising the write path — a green
#    that proves nothing, and the exact omission that blinded the decoy.
# ===========================================================================
echo "=== 3. a pin at a NON-EXISTENT dir writes nowhere — a green that proves nothing ==="
rm -f "$CANARY/monitor/.state/ng-usage.jsonl"
build_fixture "$WORK/nodir"
NEXUS_ROOT="$CANARY" NEXUS_STATE_DIR="$WORK/nodir/monitor/.state-absent" \
    "$WORK/nodir/monitor/ng" verbs >/dev/null 2>&1 || true
assert_eq "the inherited root is still clean" "$(canary_rows)" "0"
assert_no_file "…and nothing was written to the pinned path either — the tap no-opped" \
    "$WORK/nodir/monitor/.state-absent/ng-usage.jsonl"

# ===========================================================================
# 4. THE SHARED BUILDER carries the property, so a suite that uses it inherits
#    the guarantee rather than having to remember it. This is the arm that
#    makes the fix structural instead of three edits.
# ===========================================================================
echo "=== 4. setup_fake_nexus pins and creates the state dir ==="
rm -f "$CANARY/monitor/.state/ng-usage.jsonl"
(
    export NEXUS_ROOT="$CANARY"
    setup_fake_nexus "$WORK/viahelper" >/dev/null 2>&1
    "$FAKE_NEXUS/monitor/ng" verbs >/dev/null 2>&1 || true
)
assert_eq "a fixture built by setup_fake_nexus leaves the inherited root clean" \
    "$(canary_rows)" "0"
assert_file_exists "…and its own state dir received the row" \
    "$WORK/viahelper/monitor/.state/ng-usage.jsonl"


# ---- assertion-count guard (your-org/nexus-code#805/#833) ------------------
# An exact expected total, not just the shared ledger. The ledger stops a
# ZERO-assertion run announcing a pass; it cannot see an assertion silently
# dropped from the middle of a suite, which is how a guard quietly narrows
# without anything going red. `test-summary-honesty-manifest.sh` requires this
# of every suite that claims a green.
EXPECTED_ASSERTIONS=7
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
