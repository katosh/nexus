#!/usr/bin/env bash
# test-public-mirror-overlay-drift.sh — make public-mirror OVERLAY drift LOUD
# in source, instead of waiting for the mirror's CI to notice.
#
# THE HOLE THIS FILLS (your-org/nexus-code#979 defect 1). An overlay block is a
# FORK of a source block: `monitor/public-mirror/overlay/manifest.tsv` names a
# region of a source file and `build.sh` swaps in authored public content before
# the identifier scrub runs. Anything in source that reads that region by
# literal string is now coupled to a file it never mentions — and the coupling
# is invisible to every check we had:
#
#   - the leak gate is indifferent (a renamed heading leaks nothing);
#   - the source-side suites are green, because they run on the UNBUILT tree;
#   - build.sh is green, because its anchors still match.
#
# So `overlay/install-prompt.phase6.md` renamed a heading, collapsed a decision
# matrix and dropped a qualifier off a context-signal label while three source
# consumers still expected the pre-overlay strings, and the whole toolchain
# stayed green until the mirror's CI ran. Two of those consumers are test
# suites that SHIP to the mirror; the third is an emitter that cannot be
# overlaid at all.
#
# WHAT THIS ASSERTS. Build the overlaid + scrubbed tree exactly as the sync
# recipe does, then run the suites the manifest DECLARES as consumers of each
# overlay target against that built tree. A drift that would have turned the
# mirror red turns this red instead, one commit earlier.
#
# WHY DECLARED AND NOT DERIVED. Selecting consumers by "suite mentions the
# target's basename" was measured on this tree: `install-prompt.md` yields 8
# suites (right), `README.md` yields 16 (almost all incidental, including
# real-model integration suites that would manufacture false reds). There is no
# machine-readable link between a suite and the block it depends on, so the
# manifest carries one — and this guard FAILS when a `block` target has no
# `consumer` line, so the question cannot be left unanswered. `-` is the way to
# answer "nothing reads this"; silence is not.
#
# ANTI-VACUITY. Every step that could reduce this suite to asserting nothing is
# itself an assertion: the manifest must declare at least one block; build.sh
# must report applying exactly as many overlays as there are blocks; every
# overlay target's built content must actually DIFFER from source (an overlay
# that silently no-ops is the failure mode, so a surviving fixture is proved
# mutated, cf. #938); and the runnable consumer set must be non-empty.
#
# Run: bash monitor/watcher/test-public-mirror-overlay-drift.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Exit 77 = declined to run.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
PM="$SRC_ROOT/monitor/public-mirror"
MANIFEST="$PM/overlay/manifest.tsv"
MAPPING="$PM/mapping.tsv"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

# --- decline-to-run preconditions ---------------------------------------
#
# Exit 77 (run-tests.sh tallies SKIP, your-org/nexus-code#568 A6), never 0 — a
# guard that could not look must not read as a guard that looked and approved.
decline(){ printf 'DECLINED (exit 77): %s\n' "$1" >&2; exit 77; }

[ -r "$MANIFEST" ] || decline "no overlay manifest at $MANIFEST (fresh operator: nothing to drift)"
[ -r "$MAPPING" ]  || decline "no mapping at $MAPPING (fresh operator: build.sh cannot run)"
[ -x "$PM/build.sh" ] || [ -r "$PM/build.sh" ] || decline "no build.sh at $PM"
command -v git >/dev/null 2>&1 || decline "git not on PATH"
git -C "$SRC_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || decline "$SRC_ROOT is not a git work tree; build.sh needs one"
command -v perl >/dev/null 2>&1 || decline "perl not on PATH (scrub.pl needs it)"

# TMUX_TMPDIR/TMPDIR must be SHORT: a consumer suite spawns a real tmux server,
# UNIX sockets cap sun_path at 108 bytes, and a long temp path makes such a
# suite report FAIL rather than SKIP (your-org/nexus-code#991). /tmp/tt-$$, never
# a scratchpad subdirectory.
SHORTTMP="/tmp/tt-$$"
mkdir -p "$SHORTTMP" || decline "cannot create short temp dir $SHORTTMP"
WORK=$(mktemp -d "$SHORTTMP/overlaydrift.XXXXXX") || decline "mktemp failed under $SHORTTMP"
cleanup(){ rm -rf "$WORK" "$SHORTTMP"; }
trap cleanup EXIT

TREE="$WORK/tree"

# --- 1. the manifest declares blocks ------------------------------------

_rows(){ awk -F'\t' -v k="$1" '!/^[[:space:]]*#/ && $1==k' "$MANIFEST"; }

blocks=()
while IFS= read -r t; do [ -n "$t" ] && blocks+=("$t"); done \
    < <(_rows block | awk -F'\t' '{print $2}')

if (( ${#blocks[@]} > 0 )); then
    pass "overlay manifest declares ${#blocks[@]} block target(s)"
else
    fail "overlay manifest declares NO block targets — this guard would assert nothing"
fi

# --- 2. every block target declares its consumers ------------------------
#
# The load-bearing assertion. An overlay whose readers are undeclared is
# exactly the state that shipped #979 defect 1.

declared_targets=$(_rows consumer | awk -F'\t' '{print $2}' | sort -u)
undeclared=0
for t in "${blocks[@]}"; do
    if grep -qxF -- "$t" <<<"$declared_targets"; then
        pass "block target declares its consumers: $t"
    else
        fail "block target has NO 'consumer' line: $t — declare its readers, or '-' for none"
        undeclared=$((undeclared+1))
    fi
done

# Runnable consumer suites (drop the explicit '-' none-markers).
suites=()
while IFS= read -r s; do
    [ -n "$s" ] && [ "$s" != "-" ] && suites+=("$s")
done < <(_rows consumer | awk -F'\t' '{print $3}' | sort -u)

if (( ${#suites[@]} > 0 )); then
    pass "manifest declares ${#suites[@]} runnable consumer suite(s)"
else
    fail "no runnable consumer suites declared — nothing would be executed against the built tree"
fi

# Declared suites must exist in source, or the run below is silently empty.
missing=0
for s in "${suites[@]}"; do
    [ -r "$SRC_ROOT/$s" ] || { fail "declared consumer suite does not exist: $s"; missing=$((missing+1)); }
done
(( missing == 0 )) && pass "every declared consumer suite exists in source"

# …and must be TRACKED. build.sh iterates `git ls-files`, so an untracked suite
# is not part of the tree the mirror ships and cannot run there — it would sit
# in this manifest looking like coverage while asserting nothing downstream.
# Measured the hard way: this very guard was untracked on its first run and
# silently absent from the built tree.
untracked=0
for s in "${suites[@]}"; do
    git -C "$SRC_ROOT" ls-files --error-unmatch -- "$s" >/dev/null 2>&1 \
        || { fail "declared consumer suite is UNTRACKED (never reaches the mirror): $s"; untracked=$((untracked+1)); }
done
(( untracked == 0 )) && pass "every declared consumer suite is tracked in git"

# --- 3. build the overlaid + scrubbed tree -------------------------------
#
# --no-hardlinks: a `--local` clone hardlinks the object store, and this repo's
# checkouts routinely straddle filesystems (a cross-device link fails the clone
# outright). build.sh rewrites its checkout IN PLACE, so it gets a throwaway.

if ! git clone -q --no-hardlinks "$SRC_ROOT" "$TREE" 2>"$WORK/clone.err"; then
    fail "could not clone $SRC_ROOT into a throwaway tree: $(head -3 "$WORK/clone.err" | tr '\n' ' ')"
    th_summary_and_exit
fi
pass "throwaway clone of the source tree created"

# Carry the working tree's uncommitted state, so the guard judges what the
# author is about to push and not merely what is already committed.
if ! git -C "$SRC_ROOT" diff HEAD --binary > "$WORK/wt.patch" 2>/dev/null; then
    : # no diff is fine
fi
if [ -s "$WORK/wt.patch" ]; then
    if git -C "$TREE" apply "$WORK/wt.patch" 2>"$WORK/apply.err"; then
        pass "uncommitted working-tree changes carried into the built tree"
    else
        fail "could not apply the working-tree diff to the throwaway clone: $(head -3 "$WORK/apply.err" | tr '\n' ' ')"
    fi
else
    pass "working tree is clean; built tree matches HEAD"
fi

# Snapshot the pre-build content of each overlay target, to prove the mutation.
for t in "${blocks[@]}"; do
    safe=${t//\//__}
    [ -f "$TREE/$t" ] && cp "$TREE/$t" "$WORK/pre-$safe"
done

# --allow-dirty: the throwaway clone carries the author's UNSTAGED working-tree
# diff on purpose (applied above), so it is dirty whenever the source is
# (your-org/nexus-code#1001).
build_out=$( cd "$TREE" && bash monitor/public-mirror/build.sh --yes --allow-dirty 2>&1 ); build_rc=$?
if (( build_rc == 0 )); then
    pass "build.sh exits 0 on the throwaway tree"
else
    fail "build.sh exit $build_rc: $(tail -5 <<<"$build_out" | tr '\n' ' ')"
fi

# --- 4. prove the overlay actually applied -------------------------------
#
# A no-op overlay leaves every consumer passing for the wrong reason. Two
# independent witnesses: build.sh's own count, and a content diff per target.

applied=$(grep -c '^build\.sh: overlay applied to ' <<<"$build_out")
if (( applied == ${#blocks[@]} )); then
    pass "build.sh applied exactly ${#blocks[@]} overlay block(s)"
else
    fail "build.sh reported $applied overlay application(s); manifest declares ${#blocks[@]}"
fi

unmutated=0
for t in "${blocks[@]}"; do
    safe=${t//\//__}
    if [ ! -f "$WORK/pre-$safe" ]; then
        fail "overlay target absent from the source tree: $t"
        unmutated=$((unmutated+1))
    elif [ ! -f "$TREE/$t" ]; then
        fail "overlay target vanished from the built tree: $t"
        unmutated=$((unmutated+1))
    elif cmp -s "$WORK/pre-$safe" "$TREE/$t"; then
        fail "overlay target is byte-identical after the build: $t (overlay silently no-op'd)"
        unmutated=$((unmutated+1))
    fi
done
(( unmutated == 0 )) && pass "every overlay target's content changed in the built tree (mutation proved)"

# --- 5. run the declared consumers against the built tree ----------------
#
# This is the assertion the mirror's CI used to be the first to make.

if (( ${#suites[@]} == 0 )); then
    fail "consumer run skipped: no suites declared (see above)"
else
    for s in "${suites[@]}"; do
        if [ ! -r "$TREE/$s" ]; then
            fail "declared consumer suite missing from the BUILT tree: $s"
            continue
        fi
        out=$( cd "$TREE" && TMPDIR="$SHORTTMP" TMUX_TMPDIR="$SHORTTMP" \
                 timeout 300 bash "$s" 2>&1 ); rc=$?
        case "$rc" in
        0)  pass "consumer suite green on the built tree: $s" ;;
        77) pass "consumer suite declined to run on the built tree (SKIP): $s" ;;
        124) fail "consumer suite TIMED OUT on the built tree: $s" ;;
        *)  fail "consumer suite rc=$rc on the built tree: $s"
            # Prefix every forwarded line: run-tests.sh scrapes case counts out
            # of suite output, and an unprefixed inner summary is read as this
            # suite's own (your-org/nexus-code#997).
            grep -E 'FAIL|failed|summary' <<<"$out" | tail -8 \
                | sed 's/^/         [inner] /' >&2 ;;
        esac
    done
fi

# --- assertion-count guard ------------------------------------------------
#
# A VERDICT IS NOT A COUNT. Every branch above is data-driven — the block list
# and the suite list both come out of the manifest — so a broken derivation
# would quietly run fewer assertions and still print a green banner. Pin the
# total against what the manifest DECLARES, so "fewer ran than should have" is
# itself a failure rather than a smaller number nobody reads.
#
# Nine fixed assertions + one per block target + one per runnable suite + this
# one. On a red run the offending loops emit one FAIL per offender rather than
# one summary PASS, so the total moves too — an already-red suite gaining a
# count mismatch is expected and is not a second, independent defect.
EXPECTED_ASSERTIONS=$(( 9 + ${#blocks[@]} + ${#suites[@]} + 1 ))
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} + 1 ))
if (( TOTAL_ASSERTIONS == EXPECTED_ASSERTIONS )); then
    pass "assertion total is exactly $EXPECTED_ASSERTIONS (9 fixed + ${#blocks[@]} block + ${#suites[@]} suite + 1)"
else
    fail "assertion total $TOTAL_ASSERTIONS != expected $EXPECTED_ASSERTIONS — a derivation ran short or a branch was skipped"
fi

# --- summary -------------------------------------------------------------

th_summary_and_exit
