#!/usr/bin/env bash
# test-known-local-red.sh — the LOCAL known-red set is DATA the runner reads
# (your-org/nexus-code#1445).
#
# Two halves. (1) THE MANIFEST IS WELL-FORMED: every row names a suite that
# exists, a class from the closed vocabulary, and an issue that expires it —
# a row without an issue is a dismissal, and this suite refuses it. (2) THE
# RUNNER PARTITIONS THE FAILING SET AGAINST IT: driven against a PLANTED
# manifest and two planted red fixtures, one listed and one not, so the
# assertions are about the mechanism and never about which suites happen to
# be red on this host today. The verdict must be UNCHANGED by a row (still
# exit 1) — the manifest changes what is printed, never whether a run is red.
#
# Run: bash monitor/watcher/test-known-local-red.sh
# Expected: ALL TESTS PASSED, exit 0. No tmux. Section 1b makes ONE
# read-only `gh api` call per manifest row plus one control (#1468); with no
# network it SKIPS loudly and counted, and never passes silently.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO=$(cd "$_test_dir/../.." && pwd)
RT="$REPO/monitor/watcher/run-tests.sh"
MANIFEST="$REPO/monitor/watcher/known-local-red.tsv"
[[ -x "$RT" ]] || th_abort "missing runner $RT"
[[ -r "$MANIFEST" ]] || th_abort "missing manifest $MANIFEST"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/klr-XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT
# The runner keeps state under NEXUS_TEST_STATE_DIR; pin it so this suite never
# touches the operator's last-failures file. NEXUS_STATE_DIR is deliberately
# NOT set: the runner now WARNS on an ambient one (#1386) and that warning is
# asserted below on its own.
export NEXUS_TEST_STATE_DIR="$WORK/rt-state"

echo "== 1. the tracked manifest is well-formed"
n_rows=0; n_bad=0
while IFS=$'\t' read -r suite cls issue reason; do
    [[ "$suite" =~ ^[[:space:]]*(#|$) ]] && continue
    n_rows=$(( n_rows + 1 ))
    ok=1
    [[ -f "$REPO/monitor/$suite" ]] || { echo "  FAIL: row names a suite that does not exist: monitor/$suite" >&2; ok=0; }
    case "$cls" in load|live-tmux|host) ;; *) echo "  FAIL: row for $suite has class '$cls' (not load|live-tmux|host)" >&2; ok=0 ;; esac
    [[ "$issue" =~ ^#[0-9]+$ ]] || { echo "  FAIL: row for $suite names no issue ('$issue') — a row with no tracker is a dismissal" >&2; ok=0; }
    [[ -n "$reason" ]] || { echo "  FAIL: row for $suite carries no reason" >&2; ok=0; }
    (( ok )) || n_bad=$(( n_bad + 1 ))
done < "$MANIFEST"
assert_eq "every manifest row is well-formed (bad rows: $n_bad of $n_rows)" "$n_bad" "0"
# A manifest with ZERO rows is a legitimate state (nothing inherited), so the
# count is reported, not asserted — but the parser must have SEEN the file.
[[ "$n_rows" =~ ^[0-9]+$ ]] && assert_eq "the manifest parsed ($n_rows row(s))" "0" "0"

echo "== 1b. every row's ISSUE IS ALIVE, not merely well-shaped (#1468)"
#
# Section 1 validates `^#[0-9]+$` -- the SHAPE of the field. The manifest's
# own header promises more than that: "a row with no LIVE issue is a
# dismissal". A closed issue, a deleted issue and a number that never existed
# are all indistinguishable from a live tracker under a shape check, so the
# field was a proxy for the property and the two diverged silently the moment
# somebody closed an issue -- a routine, correct act performed by an agent
# with no reason to look at this table. It has already fired: closing #1445
# orphaned the row for test-proc-kill-authorized.sh and nothing went red,
# because nothing looked.
#
# THE PREDICATE IS SEPARATED FROM THE LOOKUP ON PURPOSE. Classification is
# pure and hermetic, so it is driven unconditionally below on every host,
# network or not; only the lookup needs GitHub. That split is what stops
# "nobody could look" from scoring as "nothing is wrong" -- which would be a
# silent zero of its own, inside the check written to prevent one.

klr_issue_verdict() {
    case "${1:-}" in
        open)   printf 'alive'   ;;
        closed) printf 'orphan'  ;;
        *)      printf 'unknown' ;;
    esac
}

# POTENCY, hermetic and unconditional: three DIFFERENT answers, or every
# verdict below is unfalsifiable. `unknown` is deliberately NOT `alive` --
# CLAUDE.md singles that state out as the worst one to resolve permissively.
assert_eq "predicate: an OPEN tracker is alive"          "$(klr_issue_verdict open)"        "alive"
assert_eq "predicate: a CLOSED tracker is an ORPHAN"     "$(klr_issue_verdict closed)"      "orphan"
assert_eq "predicate: NO answer is unknown, never alive" "$(klr_issue_verdict '')"          "unknown"
assert_eq "predicate: an unparseable answer likewise"    "$(klr_issue_verdict 'Not Found')" "unknown"

# The repo is DERIVED, never hardcoded. This file ships to every clone, and a
# hardcoded owner would ask somebody else's fork about our issue numbers
# (your-org/nexus-code#568 C7).
klr_repo=$(git -C "$REPO" remote get-url origin 2>/dev/null \
           | sed -n 's#.*github\.com[:/]\([^/]*\)/\([^/][^/]*\)$#\1/\2#p' \
           | sed 's/\.git$//')

klr_state() {
    local n="${1#\#}" out rc
    [[ -n "$klr_repo" ]] || { printf ''; return 0; }
    out=$(timeout 30 gh api "repos/$klr_repo/issues/$n" --jq .state 2>/dev/null)
    rc=$?
    # ANY non-zero is "could not look", including timeout's injected 124 --
    # a value in no callee's vocabulary (#1248). The safe direction is
    # `unknown`; resolving an unreadable answer as `alive` is the exact
    # permissive default this section exists to remove.
    (( rc == 0 )) || { printf ''; return 0; }
    printf '%s' "$out"
}

# END-TO-END DRIVE, on the real condition rather than a mock: #1445 is the
# tracker whose closure orphaned a live row, so it is a tracker this repo
# knows to be closed. If the lookup is unavailable the whole live half SKIPS
# loudly -- counted, never a pass -- because an exemption nobody could verify
# must not read as an exemption somebody checked.
klr_probe=$(klr_state 1445)
if [[ -z "$klr_probe" ]]; then
    th_skip "live tracker lookup" \
            "could not reach ${klr_repo:-<no origin remote>} via 'gh api' (offline, unauthenticated or rate-limited) — the $n_rows manifest row(s) are UNVERIFIED, not vouched for"
else
    assert_eq "end-to-end: a row naming a CLOSED tracker (#1445) is an ORPHAN" \
              "$(klr_issue_verdict "$klr_probe")" "orphan"

    n_orphan=0; n_unknown=0; n_alive=0
    while IFS=$'\t' read -r suite cls issue reason; do
        [[ "$suite" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$issue" =~ ^#[0-9]+$ ]] || continue      # shape already failed above
        case "$(klr_issue_verdict "$(klr_state "$issue")")" in
            alive)  n_alive=$((   n_alive   + 1 )) ;;
            orphan) n_orphan=$((  n_orphan  + 1 ))
                    echo "  FAIL: row for $suite names $issue, which is CLOSED — its exemption is a dismissal now and still suppresses the suite in the pre-push gate; re-derive the row or drop it" >&2 ;;
            *)      n_unknown=$(( n_unknown + 1 ))
                    th_skip "liveness of $issue (row: $suite)" "lookup returned no state" ;;
        esac
    done < "$MANIFEST"

    assert_eq "no row names a CLOSED tracker (orphans: $n_orphan of $n_rows)" "$n_orphan" "0"
    # Reported, not asserted: an EMPTY manifest is a legitimate state, and a
    # green here would otherwise be a claim about a population of zero.
    echo "  note: $n_rows row(s) — alive=$n_alive orphan=$n_orphan unverified=$n_unknown"
fi

echo "== 2. the runner PARTITIONS the failing set against a planted manifest"
FIX="$WORK/fixtures/watcher"; mkdir -p "$FIX"
mk() { printf '#!/usr/bin/env bash\necho "=== summary: 0 passed, 1 failed ==="\nexit 1\n' > "$FIX/$1"; chmod +x "$FIX/$1"; }
mkgreen() { printf '#!/usr/bin/env bash\necho "  PASS: fine"\necho "=== summary: 1 passed, 0 failed ==="\necho "ALL TESTS PASSED"\nexit 0\n' > "$FIX/$1"; chmod +x "$FIX/$1"; }
mk test-zz-known-red.sh; mk test-zz-unknown-red.sh; mkgreen test-zz-green.sh
PLANT="$WORK/known.tsv"
printf '# planted\nwatcher/test-zz-known-red.sh\tload\t#9999\tplanted: reds under load\n' > "$PLANT"

out=$(NEXUS_KNOWN_LOCAL_RED="$PLANT" bash "$RT" "$FIX/test-zz-known-red.sh" "$FIX/test-zz-unknown-red.sh" "$FIX/test-zz-green.sh" 2>&1 < /dev/null); rc=$?
assert_eq "a run with a red still exits 1 — a manifest row never changes the verdict" "$rc" "1"
assert_contains "the listed red is printed under KNOWN-LOCAL-RED with its class" "$out" "test-zz-known-red.sh"
assert_contains "…the KNOWN block names the count and the manifest" "$out" "KNOWN-LOCAL-RED (1 of 2 failures"
assert_contains "…and the row's issue and reason travel with it" "$out" "#9999"
assert_contains "the unlisted red is printed under UNEXPLAINED" "$out" "UNEXPLAINED (1 of 2 failures"
assert_contains "…and the local gate is BLOCKED" "$out" "LOCAL GATE: BLOCKED"
# The set line, not the count line: the UNEXPLAINED block must contain exactly
# the unlisted suite and not the listed one.
unexp=$(sed -n '/^UNEXPLAINED/,/^LOCAL GATE/p' <<<"$out")
assert_contains "the UNEXPLAINED block names the unlisted suite" "$unexp" "test-zz-unknown-red.sh"
assert_not_contains "…and NOT the listed one" "$unexp" "test-zz-known-red.sh"
assert_contains "the suite-total line carries the load beside the count (#1445)" "$out" "loadavg"

echo "== 3. failing set ⊆ known set -> the gate reads CLEAR, and the run is STILL red"
out=$(NEXUS_KNOWN_LOCAL_RED="$PLANT" bash "$RT" "$FIX/test-zz-known-red.sh" "$FIX/test-zz-green.sh" 2>&1 < /dev/null); rc=$?
assert_eq "exit 1 even when every failure is a known row" "$rc" "1"
assert_contains "the gate line reads CLEAR" "$out" "LOCAL GATE: failing set ⊆ known-local-red set (1 of 1)"
assert_not_contains "no UNEXPLAINED block when the set is covered" "$out" "UNEXPLAINED ("

echo "== 4. POTENCY: an EMPTY manifest classifies the same red as UNEXPLAINED"
: > "$WORK/empty.tsv"
out=$(NEXUS_KNOWN_LOCAL_RED="$WORK/empty.tsv" bash "$RT" "$FIX/test-zz-known-red.sh" 2>&1 < /dev/null); rc=$?
assert_eq "still exit 1" "$rc" "1"
assert_contains "the same suite is UNEXPLAINED when no row names it" "$out" "UNEXPLAINED (1 of 1 failures"
assert_not_contains "…and no KNOWN block is printed" "$out" "KNOWN-LOCAL-RED ("

echo "== 5. a QUOTED or COMMENTED mention is not a row — the match is on column 1 of a data line"
printf '# watcher/test-zz-known-red.sh\tload\t#1\tcommented out\n' > "$WORK/commented.tsv"
out=$(NEXUS_KNOWN_LOCAL_RED="$WORK/commented.tsv" bash "$RT" "$FIX/test-zz-known-red.sh" 2>&1 < /dev/null)
assert_contains "a commented-out row does not classify" "$out" "UNEXPLAINED (1 of 1 failures"

echo "== 6. a green run prints NO partition (nothing to partition)"
out=$(NEXUS_KNOWN_LOCAL_RED="$PLANT" bash "$RT" "$FIX/test-zz-green.sh" 2>&1 < /dev/null); rc=$?
assert_eq "green run exits 0" "$rc" "0"
assert_not_contains "no KNOWN block on a green run" "$out" "KNOWN-LOCAL-RED ("
assert_not_contains "no gate line on a green run" "$out" "LOCAL GATE"

echo "== 7. an AMBIENT NEXUS_STATE_DIR is WARNED about up front (#1386), and is not a refusal"
out=$(NEXUS_STATE_DIR="$WORK/ambient" NEXUS_KNOWN_LOCAL_RED="$PLANT" bash "$RT" "$FIX/test-zz-green.sh" 2>&1 < /dev/null); rc=$?
assert_eq "the run still executes (exit 0 on a green fixture)" "$rc" "0"
assert_contains "…and the warning names the variable and the issue" "$out" "NEXUS_STATE_DIR=$WORK/ambient is set in the AMBIENT environment (your-org/nexus-code#1386)"
out=$(env -u NEXUS_STATE_DIR NEXUS_KNOWN_LOCAL_RED="$PLANT" bash "$RT" "$FIX/test-zz-green.sh" 2>&1 < /dev/null)
assert_not_contains "CONTROL: no warning without the ambient pin" "$out" "AMBIENT environment"

th_summary_and_exit
