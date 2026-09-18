#!/usr/bin/env bash
# test-tee-reopen-lint.sh — both-directions coverage for
# monitor/watcher/tee-reopen-lint.sh (your-org/nexus-code#1490).
#
# A lint is only worth its maintenance if BOTH its directions are checked. A
# lint that flags nothing passes a clean tree and a broken one identically; a
# lint that flags everything gets muted within a week. So every case plants a
# fixture and states which direction it pins:
#
#   POSITIVE — a construct MEASURED to truncate. Each MUST be flagged, or the
#              lint's green is a claim about its regex rather than the tree.
#   NEGATIVE — the safe forms, and the near-misses that share the defect's
#              silhouette. Each MUST NOT be flagged.
#
# THE AXIS WAS MEASURED, NOT REASONED. Every POSITIVE below was run against a
# seeded 40-line log opened `>>log 2>&1`; the ones that came back as 1 line are
# positives, the ones that came back as 41 are negatives. `>&2` is the control.
#
# Run: bash monitor/watcher/test-tee-reopen-lint.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LINT="$_test_dir/tee-reopen-lint.sh"

# ---------------------------------------------------------------------------
# POPULATION DECLARATION (your-org/nexus-code#1301 item 2, #1494).
#
# Placed HERE, above the first thing this suite prints, because `gp_handle`
# EXITS when it handles the flag: anything printed before it lands in the
# probe's stdout and is read as a population row.
#
# It calls the lint's OWN enumerator (`--files`) rather than a copy. A copy is
# a second implementation of the population, and a second implementation
# drifts — at which point the index reports, with total confidence, that this
# guard does not read a file it does read.
#
# This matters beyond tidiness: #1494 measured that the guards INVISIBLE to
# `guards-for-diff` were precisely the ones that caught real defects, so a new
# repo-wide construct lint that declared nothing would be born into the blind
# spot it was written to shrink.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    bash "$LINT" --files "$REPO_ROOT"
    printf '%s\n' 'monitor/shell-files.sh' 'monitor/watcher/_shell_quotes.awk'
}
gp_handle "$@"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The fixture tree needs the lint's dependencies present, because a MISSING
# `_shell_quotes.awk` makes `shf_strip_comments` REFUSE — and the first draft
# of this lint swallowed that refusal into `2>/dev/null` and reported a clean
# sweep over a tree with two known violations. That silent zero is pinned by
# its own case below.
_mktree() {
    rm -rf "$WORK/tree"
    mkdir -p "$WORK/tree/monitor/watcher"
    cp "$REPO_ROOT/monitor/shell-files.sh"        "$WORK/tree/monitor/"
    cp "$REPO_ROOT/monitor/watcher/_shell_quotes.awk" "$WORK/tree/monitor/watcher/"
}

# _plant <line…> — one shell file under monitor/, rebuilt from scratch each
# time so a fixture cannot leak into the next case and answer through a path
# it was never written to reach.
_plant() {
    _mktree
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$WORK/tree/monitor/a.sh"
}
_hits() { bash "$LINT" "$WORK/tree" 2>/dev/null | grep -c . ; }
_rc()   { bash "$LINT" "$WORK/tree" >/dev/null 2>&1; printf '%s' "$?"; }

# The fixture bodies assemble the flagged token from `$_T` rather than writing
# it literally: the lint scans every shell file under the root it is given, and
# THIS FILE is under `monitor/`, so a literal `tee /dev/stderr` here would make
# the lint flag its own test — one hit, forever, in the tree it certifies
# clean. The alternative is an allowlist exempting this path, and a lint with
# an exemption for the file most likely to contain the pattern is a lint with a
# hole shaped like its own author.
_T='/dev/std''err'
_O='/dev/std''out'
_F='/dev/f''d/2'
_P='/proc/self/f''d/2'

echo '=== POSITIVE: the three MEASURED truncating forms are flagged ==='

_plant "printf 'x\\n' | tee $_T >/dev/null"
assert_eq "tee <fd-path> is flagged"                    "$(_hits)" "1"
assert_eq "…and the lint exits 1"                       "$(_rc)"   "1"

_plant "printf 'x\\n' > $_T"
assert_eq "a TRUNCATING redirect to an fd path is flagged (not just tee)" \
    "$(_hits)" "1"

_plant "printf 'x\\n' | tee $_F >/dev/null"
assert_eq "tee /dev/fd/N is flagged — same open, different spelling" \
    "$(_hits)" "1"

_plant "printf 'x\\n' | tee $_P >/dev/null"
assert_eq "tee /proc/self/fd/N is flagged"              "$(_hits)" "1"

# THE SITE THE FIRST DRAFT MISSED. Shell punctuation rides on the last token of
# a command, so `tee /dev/stderr; return 3` splits to `/dev/stderr;`, which
# equals no fd path. The miss was invisible because the file's OTHER site
# matched — a SHORT COUNT, not a zero, and a short count is the more dangerous
# of the two because nothing about it looks wrong.
_plant "{ printf 'x\\n' | tee $_T; return 3; }"
assert_eq "trailing shell punctuation does not hide the site" "$(_hits)" "1"

_plant "printf 'x\\n' | tee $_O >/dev/null"
assert_eq "the stdout spelling is flagged too"          "$(_hits)" "1"

echo '=== NEGATIVE: the safe forms and the near-misses are NOT flagged ==='

_plant "printf 'x\\n' >&2"
assert_eq "the REMEDY — >&2 DUPs the fd and opens nothing — is clean" "$(_hits)" "0"
assert_eq "…and the lint exits 0"                                    "$(_rc)"   "0"

_plant "printf 'x\\n' >> $_T"
assert_eq "an APPEND redirect does not truncate, so it is clean"      "$(_hits)" "0"

_plant "printf 'x\\n' | tee -a $_T >/dev/null"
assert_eq "tee -a is clean"                                           "$(_hits)" "0"

_plant "printf 'x\\n' | tee --append $_T >/dev/null"
assert_eq "tee --append is clean"                                     "$(_hits)" "0"

_plant "printf 'x\\n' | tee \"\$LOGFILE\" >/dev/null"
assert_eq "tee to an ordinary file is not this defect"                "$(_hits)" "0"

_plant "# a comment explaining why not to write tee $_T here"
assert_eq "a COMMENT naming the construct is not a site"              "$(_hits)" "0"

_mktree
cat > "$WORK/tree/monitor/a.sh" <<'PLANT'
#!/usr/bin/env bash
cat <<'DOC'
never write:  cmd | tee /dev/stderr
DOC
PLANT
assert_eq "a HEREDOC BODY naming the construct is not a site"         "$(_hits)" "0"

_plant "exec 2>&1"
assert_eq "exec 2>&1 is not a path open"                              "$(_hits)" "0"

echo '=== REFUSAL: a population it cannot read is not a population it can certify ==='
# The silent zero this lint shipped with, pinned so it cannot come back. With
# `_shell_quotes.awk` absent, `shf_strip_comments` REFUSES — loudly, non-zero —
# and the first draft routed that refusal into `2>/dev/null`, took the empty
# stripped text as the file's code, and reported a CLEAN SWEEP over a tree it
# had not read. The refusal was never lost; it was merely off the path that
# produced the answer, which is all a silent zero needs.
_plant "printf 'x\\n' | tee $_T >/dev/null"
rm -f "$WORK/tree/monitor/watcher/_shell_quotes.awk"
assert_eq "a missing stripper dependency REFUSES (exit 3), never reports clean" \
    "$(_rc)" "3"

echo '=== the repo itself is clean, and that green is non-vacuous ==='
# Asserted TOGETHER with the positives above: "the tree is clean" means
# something only because the cases above proved this lint can go red.
bash "$LINT" "$REPO_ROOT" >/dev/null 2>&1
assert_eq "no shell file in this repo reopens a standard stream by path" "$?" "0"

# NON-VACUITY of the real-tree run: a population floor, so an enumerator broken
# into finding nothing cannot pass as a clean sweep.
_n_pop=$(bash "$LINT" --files "$REPO_ROOT" | grep -c .)
assert_eq "the real-tree population clears a broken-enumerator floor (got $_n_pop)" \
    "$(( _n_pop >= 300 ? 1 : 0 ))" "1"

# ---- assertion-count guard -----------------------------------------------
#
# `ledger=yes` (via th_summary_and_exit) certifies that SOMETHING was asserted
# and that no FAIL was swallowed by a subshell. It certifies NOTHING about HOW
# MUCH was asserted, and the two are different protections —
# `summary-honesty.manifest` exists because conflating them was wrong in a way
# that mattered. An exact count is what makes a VANISHED assertion redden: a
# missing helper is rc 127, counted by nothing, and the suite still prints ALL
# TESTS PASSED with a quietly smaller total.
#
# Compared with `!=`, not a floor: a floor catches a collapse and passes a
# suite that clears it while under-asserting by one.
EXPECTED_ASSERTIONS=19
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
assert_eq "assertion TOTAL matches the EXPECTED total — no assertion silently dropped or added" \
    "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
