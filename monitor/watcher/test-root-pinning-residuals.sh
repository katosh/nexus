#!/usr/bin/env bash
# Unit tests for the two residual #577 root-pinning defects
# (your-org/nexus-code#1084): `watcher-supervise-tick.sh` ignoring $NEXUS_ROOT
# while WRITING state, and `lit.sh` honouring it but not DE-NESTING it.
#
# Run: bash monitor/watcher/test-root-pinning-residuals.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE HARM IS NOT DESTRUCTION, IT IS INVISIBILITY. Neither of these uses the
# mis-rooted path as a `git -C` target, so neither can do what #1077 did. Both
# do the #577 harm: state written where nothing reads it. That failure is
# SILENT and it is shaped exactly like a supervisor with nothing to report or a
# reference library with nothing in it — which is why it needs a test rather
# than a reading.
#
# KEYED ON THE PROPERTY: WHERE DID THE BYTES LAND. Nothing here asserts that a
# particular resolver function was called, or that a given line matches a
# pattern. The question is whether the state a secondary clone writes is
# readable from the PRIMARY, and it is answered by looking for the file.
#
# The fixture is a real nested `<primary>/work/<clone>` layout, because the
# de-nesting rule is structural — it keys on being under some ancestor's
# `work/` with that ancestor looking like a nexus root. A flat fixture cannot
# exhibit the defect at all.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
_repo_root=$(cd "$_test_dir/../.." && pwd)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build `<primary>/work/<clone>`, both looking like nexus roots. Only the files
# the two scripts actually reach at run time are copied; a full 44M tree would
# make the suite slow without making it stronger.
PRIMARY="$WORK/primary"
CLONE="$PRIMARY/work/nc-secondary"
for d in "$PRIMARY" "$CLONE"; do
    mkdir -p "$d/monitor/watcher" "$d/config"
    # nexus_primary_root's ancestor test requires monitor/, an EXECUTABLE
    # monitor/ng, and config/. Without the +x the ancestor is not recognised,
    # the de-nesting silently does not happen, and every assertion below would
    # compare a clone path against a clone path and pass.
    : > "$d/monitor/ng"; chmod +x "$d/monitor/ng"
    for f in _nexus-root.sh _fs_probe.sh watcher-supervise-tick.sh lit.sh; do
        [ -r "$_repo_root/monitor/$f" ] && cp "$_repo_root/monitor/$f" "$d/monitor/$f"
    done
    cp "$_repo_root/monitor/watcher/_lib.sh" "$d/monitor/watcher/_lib.sh"
done

assert_file_exists "fixture: the clone has its own supervise-tick" \
    "$CLONE/monitor/watcher-supervise-tick.sh"

# POSITIVE CONTROL ON THE FIXTURE ITSELF. If de-nesting does not resolve to the
# primary here, every "landed in the primary" assertion below is vacuous.
denested=$(bash -c ". '$CLONE/monitor/_nexus-root.sh'; nexus_primary_root '$CLONE'")
assert_eq "fixture: the clone de-nests to the primary" "$denested" "$PRIMARY"
# ...and the primary must de-nest to ITSELF, or the resolver is simply
# returning its argument's parent and would "pass" for the wrong reason.
denested_p=$(bash -c ". '$PRIMARY/monitor/_nexus-root.sh'; nexus_primary_root '$PRIMARY'")
assert_eq "fixture: the primary de-nests to itself" "$denested_p" "$PRIMARY"

PRIMARY_STATE="$PRIMARY/monitor/.state"
CLONE_STATE="$CLONE/monitor/.state"
HB=watcher-supervisor-heartbeat

# ═══════════════════════════════════════════════════════════════════════════
echo "== #1084 (1): watcher-supervise-tick.sh writes state to the PRIMARY =="

rm -rf "$PRIMARY_STATE" "$CLONE_STATE"
# NEXUS_STATE_DIR is deliberately UNSET: it is the override this script already
# honoured, so setting it would test the path that was never broken.
( cd "$CLONE" && env -u NEXUS_STATE_DIR NEXUS_ROOT="$CLONE" \
    timeout 60 bash "$CLONE/monitor/watcher-supervise-tick.sh" ) >/dev/null 2>&1
tick_rc=$?

# The tick REPORTS liveness by exit code and there is no watcher in the
# fixture, so a non-zero rc is the expected, correct outcome. What is under
# test is where the heartbeat landed, not the verdict.
assert_eq "the tick ran to a verdict rather than dying early" \
    "$( [ "$tick_rc" -ne 124 ] && echo ran || echo timed-out )" "ran"

assert_file_exists "supervision heartbeat lands in the PRIMARY" "$PRIMARY_STATE/$HB"
assert_no_file     "supervision heartbeat does NOT land in the clone" "$CLONE_STATE/$HB"

# Same script, invoked from the PRIMARY: must still be the primary. A fix that
# merely redirected everything one level up would break this.
rm -rf "$PRIMARY_STATE" "$CLONE_STATE"
( cd "$PRIMARY" && env -u NEXUS_STATE_DIR NEXUS_ROOT="$PRIMARY" \
    timeout 60 bash "$PRIMARY/monitor/watcher-supervise-tick.sh" ) >/dev/null 2>&1
assert_file_exists "from the primary, state still lands in the primary" "$PRIMARY_STATE/$HB"

# NEXUS_ROOT UNSET is the other axis, and it is the one #1084 names first:
# `grep -c NEXUS_ROOT` was 0, so the script rooted at its own location. Run from
# the clone with no env at all, the state must STILL reach the primary, because
# the clone is structurally nested under it.
rm -rf "$PRIMARY_STATE" "$CLONE_STATE"
( cd "$CLONE" && env -u NEXUS_STATE_DIR -u NEXUS_ROOT \
    timeout 60 bash "$CLONE/monitor/watcher-supervise-tick.sh" ) >/dev/null 2>&1
assert_file_exists "NEXUS_ROOT unset: state still lands in the primary" "$PRIMARY_STATE/$HB"
assert_no_file     "NEXUS_ROOT unset: nothing lands in the clone" "$CLONE_STATE/$HB"

# The override this script already honoured must keep working — a fix that
# de-nested $NEXUS_STATE_DIR too would break every test fixture in the repo.
EXPLICIT="$WORK/explicit-state"
rm -rf "$PRIMARY_STATE" "$CLONE_STATE" "$EXPLICIT"
( cd "$CLONE" && NEXUS_STATE_DIR="$EXPLICIT" NEXUS_ROOT="$CLONE" \
    timeout 60 bash "$CLONE/monitor/watcher-supervise-tick.sh" ) >/dev/null 2>&1
assert_file_exists "an explicit NEXUS_STATE_DIR is still obeyed verbatim" "$EXPLICIT/$HB"
assert_no_file     "an explicit NEXUS_STATE_DIR is not de-nested to the primary" \
    "$PRIMARY_STATE/$HB"

# ═══════════════════════════════════════════════════════════════════════════
echo "== #1084 (2): lit.sh de-nests \$NEXUS_ROOT rather than taking it verbatim =="

# lit.sh dies at load time without jq/curl, and running the whole CLI would test
# the network. Extract the resolver from the REAL file, exactly as the
# spawn-worker suite does, so this cannot drift from what it certifies.
LITFN="$WORK/litfn.sh"
awk '/^_nexus_root\(\) \{/,/^}$/' "$CLONE/monitor/lit.sh" > "$LITFN"
assert_eq "extractor found lit.sh's _nexus_root" \
    "$(grep -c '^_nexus_root() {' "$LITFN")" "1"

got=$(NEXUS_ROOT="$CLONE" bash -c '
    _script_dir="'"$CLONE"'/monitor"; _cfg="'"$WORK"'/nocfg"
    . "$_script_dir/_nexus-root.sh"; . "'"$LITFN"'"; _nexus_root' 2>/dev/null)
assert_eq "NEXUS_ROOT pointing at the clone resolves to the PRIMARY" "$got" "$PRIMARY"

got=$(NEXUS_ROOT="$PRIMARY" bash -c '
    _script_dir="'"$PRIMARY"'/monitor"; _cfg="'"$WORK"'/nocfg"
    . "$_script_dir/_nexus-root.sh"; . "'"$LITFN"'"; _nexus_root' 2>/dev/null)
assert_eq "NEXUS_ROOT pointing at the primary is unchanged" "$got" "$PRIMARY"

# A $NEXUS_ROOT that is not a directory must not vanish. nexus_primary_root
# returns 1 and prints NOTHING for a non-directory; a naive
# `printf '%s' "$(nexus_primary_root "$NEXUS_ROOT")"` would then resolve the
# reference library to the EMPTY STRING, which is worse than the defect.
got=$(NEXUS_ROOT="$WORK/no-such-dir" bash -c '
    _script_dir="'"$CLONE"'/monitor"; _cfg="'"$WORK"'/nocfg"
    . "$_script_dir/_nexus-root.sh"; . "'"$LITFN"'"; _nexus_root' 2>/dev/null)
assert_eq "an unresolvable NEXUS_ROOT falls back to the value, never to empty" \
    "$got" "$WORK/no-such-dir"

th_summary_and_exit
