#!/usr/bin/env bash
# test-guards-for-diff.sh — the reverse index and the `--population` protocol
# it is built on (your-org/nexus-code#803).
#
# WHAT IS BEING GUARDED. "Which guards scan what I just changed?" is answered
# by asking each guard, so every way that question can be answered WRONGLY is a
# way this index quietly under-covers a push:
#
#   * a guard whose enumerator returns nothing reads downstream as "does not
#     read your diff" — the silent-zero class, which has produced three
#     confident wrong answers in this workspace already (`mapfile` in zsh,
#     `grep -r` over `reports/`, `git ls-tree` with a glob pathspec);
#   * a guard the index could not ASK looks exactly like a guard that answered
#     "no";
#   * an empty SELECTION reads as "nothing to run" when it may mean "the index
#     did not run".
#
# So the assertions below are about REFUSALS at least as much as about hits,
# and the two selection cases are planted BOTH ways: a diff touching a
# known-scanned file must select that guard, and a diff touching nothing
# scanned must report zero WITH a non-empty considered list.
#
# EVERY ASSERTION MATCHES THE MESSAGE OR THE SET, NOT MERELY THE EXIT CODE. An
# exit code says a guard fired; only the message says it fired for the reason
# claimed.
#
# Run: bash monitor/watcher/test-guards-for-diff.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
INDEX="$REPO_ROOT/monitor/guards-for-diff.sh"
PROTO="$REPO_ROOT/monitor/_guard_population.sh"
MANIFEST="$_test_dir/guard-populations.manifest"

. "$_test_dir/_test_helpers.sh"

# The operator's interactive `grep` is a ugrep wrapper honouring .gitignore
# (your-org/nexus-code#618); bind the real binary so no scan below can return a
# confident zero.
REAL_GREP=$(type -P grep 2>/dev/null) || REAL_GREP=/bin/grep

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- this suite is ITSELF a declaring guard (your-org/nexus-code#803) -------
#
# Not a formality. It reads the index, the protocol library, the manifest and
# every guard the manifest names — it RUNS each of their `--population` probes —
# so an edit to any of them can change this suite's verdict, which is exactly
# the definition of its population.
#
# It is also the honest resolution of a real discovery ambiguity. Section 5
# below PLANTS a protocol fixture, so this file's text carries both discovery
# tokens whether or not it implements the protocol, and no text predicate can
# tell quoting from implementing without a parse. Rather than exempt the file by
# name — an exemption that would silently cover whatever else got named that way
# — it implements the protocol for real and declares a row like any other guard.
. "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() {
    printf '%s\n' "$INDEX" "$PROTO" "$MANIFEST"
    # Every guard this suite probes. Read from the manifest rather than listed,
    # so enrolling a seventh guard extends this population without an edit here.
    "$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$' | cut -f1
}
gp_handle "$@"

for f in "$INDEX" "$PROTO" "$MANIFEST"; do
    [[ -r "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }
done

# ===========================================================================
# 1. THE MANIFEST IS THE BOUNDARY: the declaring set is EXACTLY these rows.
#
#    Set equality in BOTH directions, and that is the whole mechanism. A guard
#    newly taught the protocol lands here RED and undeclared rather than
#    silently widening what the index covers; a guard that stops declaring
#    lands red rather than silently narrowing it. A one-directional check
#    (every row is real) would pass while the index grew a guard nobody
#    reviewed.
# ===========================================================================
echo "=== 1. the declaring set equals the manifest ==="

# Discovery, re-derived here rather than imported from the index, so the two
# can disagree. The predicate is the protocol CALL — the implementation itself,
# not a name or a comment that could drift away from it.
DECL='gp_handle "$@"'
DECL2='gp_population()'
discovered=$(
    cd "$REPO_ROOT" || exit 1
    git ls-files -- '*test-*.sh' 2>/dev/null | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        "$REAL_GREP" -qF -- "$DECL" "$f" 2>/dev/null || continue
        "$REAL_GREP" -qF -- "$DECL2" "$f" 2>/dev/null && printf '%s\n' "$f"
    done | sort
)
recorded=$("$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$' \
           | cut -f1 | sort)

assert_eq "the guards that DECLARE a population are exactly the manifest's rows" \
    "$discovered" "$recorded"

n_declaring=$(printf '%s\n' "$recorded" | "$REAL_GREP" -c . || true)
# NON-VACUITY of this suite's own enumeration. If `git ls-files` came back
# empty the equality above would compare "" with "" on a corrupted manifest and
# pass — the exact shape being guarded against, inside the guard.
if (( n_declaring >= 3 )); then
    printf '  PASS: %s\n' "the manifest is non-empty ($n_declaring guards) — the equality above is not a comparison of two nothings"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "manifest has $n_declaring rows; the set equality would be vacuous" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ===========================================================================
# 2. EVERY DECLARED POPULATION IS REAL: above its floor, and every path exists.
#
#    The floor is the non-vacuity ratchet. The existence check is
#    about ROT: a population naming a deleted file no longer describes what the
#    guard reads, and it is the kind of staleness nothing else in the repo
#    would notice.
# ===========================================================================
echo "=== 2. each declared population is above its floor, and every path is real ==="
while IFS=$'\t' read -r suite floor kind _reason; do
    [[ -n "$suite" ]] || continue
    pop="$WORK/pop.$(basename "$suite")"
    if ! ( cd "$REPO_ROOT" && timeout 300 bash "$suite" --population ) > "$pop" 2>"$pop.err"; then
        printf '  FAIL: %s --population failed\n' "$suite" >&2
        sed 's/^/      /' "$pop.err" >&2
        FAIL=$(( FAIL + 1 ))
        continue
    fi
    n=$(wc -l < "$pop" | tr -d ' ')
    if (( n >= floor )); then
        printf '  PASS: %s\n' "$suite declares $n files (floor $floor, $kind)"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s declares %d files, below its floor of %s — an enumerator that went blind reads as "does not scan your diff"\n' \
            "$suite" "$n" "$floor" >&2
        FAIL=$(( FAIL + 1 ))
    fi

    missing=""
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ -e "$REPO_ROOT/$p" ]] || missing+="$p "
    done < "$pop"
    assert_eq "$suite's declared population names only paths that exist" \
        "$missing" ""
done < <("$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$')

# ===========================================================================
# 3. SELECTION, PLANTED BOTH WAYS.
#
#    3a is the #803 occurrence-1 shape reduced to one line: `monitor/ng` is in
#    the ambient-shell-option guard's population and in no directory a worker
#    editing `ng` would think to look. 3b is the case that matters more for
#    honesty — an empty selection must be a SENTENCE with the considered list
#    attached, never a silent success.
# ===========================================================================
echo "=== 3. selection: a scanned file selects, an unscanned one says so out loud ==="

printf 'monitor/ng\n' > "$WORK/changed-ng.txt"
out=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-ng.txt" 2>&1); rc=$?
assert_rc "a diff touching monitor/ng selects at least one guard (rc 0)" "$rc" 0
assert_contains "…and it is the guard whose population monitor/ng is in (#803 occurrence 1)" \
    "$out" "test-ambient-shell-option-scope.sh"
assert_contains "…with the REASON named, not just the suite" \
    "$out" "because it reads: monitor/ng"

# A path no guard's enumerator can produce: not tracked, not shell, not under
# monitor/. It must survive the `--changed-files` route unchanged.
printf 'docs/nothing-any-guard-reads.txt\n' > "$WORK/changed-none.txt"
out=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-none.txt" 2>&1); rc=$?
assert_rc "an unscanned diff exits 3 — its own code, distinct from a selection" "$rc" 3
assert_contains "…and SAYS the selection is empty rather than printing nothing" \
    "$out" "SELECTED: NONE."
assert_contains "…and states how many guards were CONSIDERED" \
    "$out" "guards were CONSIDERED"
# The load-bearing half: the considered list must be NON-EMPTY. "0 selected"
# with an empty considered list is indistinguishable from an index that never
# ran, which is the defect class this whole file is about.
considered=$(printf '%s\n' "$out" | sed -n '/^CONSIDERED AND EXCLUDED/,/^$/p' \
             | "$REAL_GREP" -c 'population [0-9]* files' || true)
if (( considered >= 3 )); then
    printf '  PASS: %s\n' "the empty selection ships a NON-EMPTY considered list ($considered guards, each with its population size)"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "empty selection listed only $considered considered guards — a silent zero wearing a report's clothes" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ===========================================================================
# 4. THE RESIDUAL IS PRINTED, AND IT IS THE REAL NUMBER.
#
#    The index's honesty rests on this line: it names the guards it knows and
#    then says how many suites it does NOT know. A hard-coded or stale number
#    there would be a coverage claim nobody checked.
# ===========================================================================
echo "=== 4. the invisible residual is stated, and matches the live count ==="
n_suites=$(cd "$REPO_ROOT" && git ls-files -- '*test-*.sh' | "$REAL_GREP" -c . || true)
want_residual=$(( n_suites - n_declaring ))
assert_contains "the report states the residual as <not-declaring> of <all suites>" \
    "$out" "$want_residual of $n_suites tracked test suites"
assert_contains "…and says plainly that it is not a substitute for the full suite" \
    "$out" "not a substitute for the full suite"

# 4b. The UNTRACKED warning. Several enrolled guards enumerate via
#     `git ls-files`, which cannot see a file that has not been `git add`ed —
#     so the index under-selects for the change most likely to ENTER a
#     population, namely adding one. Silence there would be an exclusion the
#     reader has no way to distrust.
printf 'monitor/definitely-not-added-yet.sh\n' > "$WORK/changed-untracked.txt"
uout=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-untracked.txt" 2>&1)
assert_contains "an untracked changed file is NAMED as untracked, not silently excluded" \
    "$uout" "monitor/definitely-not-added-yet.sh"
assert_contains "…with the reason and the remedy" \
    "$uout" "CANNOT SEE these"
# The control: a TRACKED file must NOT raise the warning, or it would fire on
# every run and mean nothing.
assert_not_contains "a tracked-only diff raises no untracked warning (the control)" \
    "$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-ng.txt" 2>&1)" \
    "UNTRACKED ("

# ===========================================================================
# 5. FAIL-CLOSED: a guard the index cannot ASK is a REFUSAL, never a silent
#    exclusion. This is the assertion that separates this index from one that
#    quietly under-covers: a broken guard and an inapplicable guard produce the
#    same "not selected" line, and only one of them is an answer.
# ===========================================================================
echo "=== 5. a guard whose probe fails makes the whole index REFUSE ==="
mkdir -p "$WORK/plant"
cat > "$WORK/plant/test-broken-guard.sh" <<'EOF'
#!/usr/bin/env bash
# A guard that DECLARES the protocol — both discovery tokens present — and
# cannot answer it: it never sources the library, so `gp_handle` is not a
# command and the probe dies rc 127. The realistic shape of a half-enrolment.
gp_population() { printf 'monitor/ng
'; }
gp_handle "$@"
EOF
printf '%s\n' "$WORK/plant/test-broken-guard.sh" > "$WORK/suites-broken.txt"
out=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-ng.txt" \
        --suites-from "$WORK/suites-broken.txt" 2>&1); rc=$?
assert_rc "an unanswerable guard is exit 2 REFUSED, not a quiet exclusion" "$rc" 2
assert_contains "…and the refusal names the guard it could not ask" \
    "$out" "test-broken-guard.sh"
assert_contains "…and says why silence would be worse than refusing" \
    "$out" "looks exactly like a guard that"
# The rc in that diagnostic must be the PROBE's, not the negated condition's.
# `$?` read inside an `if ! cmd; then` block is 0 or 1 whatever the command
# did — and 124 (timeout) is precisely the case where the number IS the
# diagnosis. The plant dies rc 127 (`gp_handle` is not a command).
assert_contains "…and reports the probe's REAL exit code, not the negated condition's" \
    "$out" "failed (rc 127)"

# The control for 5: the SAME seam with a working guard must select normally.
# Without it, the refusal above could be the seam being broken rather than the
# probe.
printf '%s\n' "monitor/watcher/test-ambient-shell-option-scope.sh" > "$WORK/suites-ok.txt"
out=$(cd "$REPO_ROOT" && bash "$INDEX" --changed-files "$WORK/changed-ng.txt" \
        --suites-from "$WORK/suites-ok.txt" 2>&1); rc=$?
assert_rc "the same seam with a WORKING guard selects (rc 0) — the refusal above is the probe, not the seam" \
    "$rc" 0

# ===========================================================================
# 6. THE PROTOCOL'S OWN REFUSALS, tested at the library rather than through
#    the index. Each of these is a way a guard can answer WRONGLY while looking
#    like it answered, and each one, unfixed, produces a confident exclusion.
# ===========================================================================
echo "=== 6. the protocol refuses an empty, an absent and an unimplemented population ==="
_gp_case() {   # <body> -> sets GPOUT / GPRC
    cat > "$WORK/case.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
GP_REPO_ROOT="$REPO_ROOT"
# Explicitly EMPTY: this fixture lives outside the repo, and what is under test
# is the guard's own declaration, not the self-path convenience.
GP_SELF=
. "$PROTO"
$1
gp_handle "\$@"
echo "SUITE-BODY-RAN"
EOF
    GPOUT=$(bash "$WORK/case.sh" --population 2>&1); GPRC=$?
}

_gp_case 'gp_population() { printf "monitor/ng\n"; }'
assert_rc "a valid declaration answers rc 0" "$GPRC" 0
assert_contains "…and emits the path" "$GPOUT" "monitor/ng"
assert_not_contains "…and the suite body does NOT run — a probe is not a test run" \
    "$GPOUT" "SUITE-BODY-RAN"

_gp_case 'gp_population() { :; }'
assert_rc "an EMPTY population is refused (rc 3), never reported as 'reads nothing of yours'" \
    "$GPRC" 3
assert_contains "…and the refusal says the two are indistinguishable downstream" \
    "$GPOUT" "is EMPTY"

_gp_case 'gp_population() { printf "monitor/no-such-file-anywhere.sh\n"; }'
assert_rc "a population naming a path that does not exist is refused (rc 3)" "$GPRC" 3
assert_contains "…and names the rotted path" "$GPOUT" "no-such-file-anywhere.sh"

_gp_case 'gp_population() { return 7; }'
assert_rc "an enumerator that FAILS is refused, not read as an empty answer" "$GPRC" 3
assert_contains "…and reports the enumerator's own rc" "$GPOUT" "rc 7"

_gp_case ':'
assert_rc "declaring the protocol without implementing it is refused (rc 3)" "$GPRC" 3
assert_contains "…and says which half is missing" "$GPOUT" "implements no gp_population"

# The no-flag control: sourcing the protocol must not change what a suite does
# when it is run normally. If it did, enrolling a guard would be a behaviour
# change and nobody would enrol one.
_gp_case 'gp_population() { printf "monitor/ng\n"; }'
GPOUT=$(bash "$WORK/case.sh" 2>&1); GPRC=$?
assert_rc "without --population the suite runs normally (rc 0)" "$GPRC" 0
assert_contains "…and its body DOES run — gp_handle is inert off the flag" \
    "$GPOUT" "SUITE-BODY-RAN"

th_summary_and_exit
