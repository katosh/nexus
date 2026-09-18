#!/usr/bin/env bash
# A DIAGNOSTIC MAY ONLY NAME A PATH THAT OUTLIVES THE PROCESS PRINTING IT.
# (your-org/nexus-code#794)
#
# WHY THIS FILE EXISTS. `test-remote-identity-health.sh` answered "why did the
# fixture not start?" with `see $WORK/forge-<port>.log` — a file its own
# unconditional `trap cleanup EXIT` deletes at suite exit, i.e. before
# run-tests.sh records the failure and long before CI's `collect failure
# artifacts` step runs. Confirmed empirically, not inferred: all four artifacts
# of a real failing run were downloaded, and the forge log is in none of them.
# The collector's re-run cannot recover it either, because it calls `mktemp -d`
# afresh.
#
# The citation READ AS HELPFUL AND WAS INERT. That is the cost: for months
# your-org/nexus-code#769 accumulated occurrences while every single one of them
# destroyed the one artefact that would have named its mechanism. The mechanism
# was named within minutes of this rule being applied (a seized port, errno 98).
# A diagnostic that points at a corpse is worse than no diagnostic, because it
# stops the reader looking further.
#
# WHY IT IS A MANIFEST TEST AND NOT A COMMENT. The boundary has to be pinned on
# the axis the MECHANISM varies on — "is this path alive when a human reads
# this line?" — and prose cannot be made to fail. The manifest below is the
# claim; this scan is what makes the claim checkable, and it fails when the
# population changes in either direction (a new violation, or a stale
# exemption).
#
# Run: bash monitor/watcher/test-diagnostics-outlive-their-paths.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# ── THE MANIFEST ────────────────────────────────────────────────────────
# Diagnostics that cite a trap-doomed path AND are nonetheless allowed to.
# One `<file>::<reason>` per line. EMPTY is the strongest possible statement
# and is the current state: every such citation in the corpus has been
# converted to emit CONTENTS instead.
#
# Adding an entry here is a deliberate, reviewable act. Do not add one to make
# this test pass — fix the diagnostic, which is nearly always a one-line change
# from "print the path" to "print what is at the path".
MANIFEST=$(cat <<'MANIFEST_END'
MANIFEST_END
)

# ── THE DETECTOR ────────────────────────────────────────────────────────
# For one shell file, print `<path>:<line>` for each stderr diagnostic that
# CITES a path inside a directory the file's own EXIT trap removes.
#
# TWO narrowings, both learned by getting it wrong first:
#
#  * Match only the DIAGNOSTIC SPAN — from `printf`/`echo` to its `>&2` — not
#    the whole source line. The first draft matched the line and reported five
#    violations, every one of them false: a doomed path in a test CONDITION
#    (`if [[ -s "$WORK/svc-calls.log" ]]; then printf ' FAIL: …' >&2`) or passed
#    as an ARGUMENT to python3 is not a citation. A guard whose hits are mostly
#    noise gets a blanket exemption entry and stops guarding. The span starts at
#    the LEFTMOST `printf`/`echo`, which is what excludes all five: in each, the
#    doomed path sits BEFORE the diagnostic begins.
#  * The span may contain ANYTHING up to `>&2` — it must NOT stop at `;` or `|`.
#    A `[^;|]*` span was the second draft, and it could not see the very defect
#    this file exists for: your-org/nexus-code#794's line is
#    `printf '        (python3 is present; see %s)\n' "$WORK/forge-…" >&2`,
#    whose format string contains a semicolon. Measured against the pre-fix tree
#    at `16728e7`, that draft returned ONE hit and missed its own founding case.
#    A guard that cannot detect the bug it was written for is the "check that
#    cannot fail" shape one level up.
#  * Strip `$( … )` BEFORE matching, because `$(cat "$WORK/err")` is the
#    CORRECT pattern — it emits the contents. Without this the rule would forbid
#    its own remedy and every fix would look like a fresh defect
#    (`test-remote-bind-guard.sh:146` is the live example).
#
# Known limitation, stated rather than hidden: a diagnostic split across a `\`
# line continuation is not matched. Single-line citations are every one in the
# corpus today, and were the shape of the your-org/nexus-code#794 defect itself.
#
# HEREDOC-AWARE SINCE your-org/nexus-code#806. Every grep below reads a source
# VIEW with heredoc bodies blanked (`th_strip_heredocs`), not the raw file. A
# line-based scan cannot otherwise tell code a file RUNS from fixture text a
# file WRITES, so any suite that plants a violation to prove its own detector
# works gets flagged by that detector — which is exactly what happened to
# `#797` the moment its file became tracked, reddening five CI bands.
#
# `#797` dodged it by ASSEMBLING its plants from a placeholder so the literal
# never appears in source. That trick still works and the plants below still
# use it, but it protected only the author who remembered to use it; the next
# person to write a literal quoted-heredoc plant self-tripped. The stripped
# view fixes the class, so the plants no longer NEED assembling — they keep it
# only because a plant that also proves the stripper is doing its job is worth
# more than one that depends on it.
#
# Line numbers survive the strip (bodies are BLANKED, not deleted), which is
# load bearing: this scanner reports `file:line`.
# scan_file <file> [<pre-stripped-source>]
#
# The stripped view costs one awk process per file, and the corpus loop below
# needs the same view for its own denominator — so it strips ONCE and hands the
# text in. The positive/negative controls call the one-argument form, which
# strips for itself; both paths must stay working, which is why the parameter
# is optional rather than required.
scan_file() {
    local f="$1" vars v n body span src
    if (( $# > 1 )); then
        src="$2"
    else
        src=$(th_strip_heredocs "$f" 2>/dev/null) || return 0
    fi
    grep -qE '^[[:space:]]*[A-Za-z_]+=\$\(mktemp -d' <<<"$src" || return 0
    grep -q 'trap .*EXIT' <<<"$src" || return 0
    vars=$(grep -oE '^[[:space:]]*[A-Za-z_]+=\$\(mktemp -d' <<<"$src" \
           | grep -oE '[A-Za-z_]+=' | tr -d '=' | sort -u)
    for v in $vars; do
        # …and the file really does delete it on the way out.
        grep -qE "rm -rf[^#]*\\\$[{]?$v" <<<"$src" || continue
        while IFS= read -r line; do
            n="${line%%:*}"; body="${line#*:}"
            span=$(printf '%s\n' "$body" | grep -oE '(printf|echo).*>&2' \
                   | sed 's/\$([^)]*)//g')
            [[ -n "$span" ]] || continue
            # Herestring, never `printf … | grep -q`: `grep -q` exits on first
            # match without draining, so under `pipefail` the writer's EPIPE
            # becomes the pipeline's status exactly when the test is TRUE
            # (your-org/nexus-code#622). This file's first draft used the pipe
            # form and `test-sigpipe-assertion-lint.sh` caught it — a guard
            # written against silent inversions, tripped by its own author.
            grep -qE "\\\$[{]?$v([}]?/|[}]?\")" <<<"$span" \
                && printf '%s:%s\n' "${f#"$REPO_ROOT"/}" "$n"
        done < <(grep -nE '(printf|echo).*>&2' <<<"$src")
    done
}

# ── POSITIVE CONTROL, FIRST ─────────────────────────────────────────────
# A scan that finds nothing is indistinguishable from a scan that CANNOT find
# anything, and this repo's dominant defect class is exactly that confusion.
# So prove the detector fires on a planted violation before trusting its zero.
PLANT=$(mktemp -d) || { echo "FAIL: mktemp for the plant"; exit 1; }
trap 'rm -rf "$PLANT"' EXIT
# The plants are ASSEMBLED from a placeholder, not written literally. A literal
# `WORK=$(mktemp -d …)` plus a citing diagnostic in THIS file makes the scanner
# flag its own source — which it did, the moment this file became tracked. The
# alternative was a self-exemption in MANIFEST, and that is strictly worse: an
# exemption on the scanner's own file is a blind spot in the one file best able
# to hide one. Assembling keeps the corpus scan honest with zero exemptions.
_MKD='$(mktemp -d -t planted-XXXXXX)'
cat >"$PLANT/test-planted-violation.sh" <<PLANTED
#!/usr/bin/env bash
WORK=$_MKD
cleanup() { rm -rf "\$WORK"; }
trap cleanup EXIT
if ! some_fixture_start; then
    printf '  FAIL: it broke (python3 is present; see %s)\n' "\$WORK/detail.log" >&2
fi
PLANTED
plant_hits=$(scan_file "$PLANT/test-planted-violation.sh" | wc -l)
# The plant deliberately carries a SEMICOLON inside its format string, because
# that is what your-org/nexus-code#794's real line looked like and what an
# earlier draft of this detector could not see.
assert_eq "POSITIVE CONTROL: the detector finds a planted doomed-path citation" \
    "$plant_hits" "1"

# Negative control for the detector: emitting the CONTENTS must NOT be flagged,
# or the rule would forbid its own remedy and every fix would look like a defect.
cat >"$PLANT/test-planted-remedy.sh" <<PLANTED2
#!/usr/bin/env bash
WORK=$_MKD
cleanup() { rm -rf "\$WORK"; }
trap cleanup EXIT
if ! some_fixture_start; then
    printf '  FAIL: it broke — detail follows: %s\n' "\$(cat "\$WORK/detail.log")" >&2
fi
PLANTED2
remedy_hits=$(scan_file "$PLANT/test-planted-remedy.sh" | wc -l)
assert_eq "NEGATIVE CONTROL: emitting the CONTENTS is not flagged" \
    "$remedy_hits" "0"

# ── THE HEREDOC-DEPENDENCE CONTROL (your-org/nexus-code#822) ────────────
# This file is a CONSUMER of `th_strip_heredocs`, and until now its green was
# not evidence about it: with the stripper disabled outright, this suite — the
# file `#806` was actually filed about — stayed green, because every plant above
# is ASSEMBLED from a placeholder so the literal never appears in source.
#
# Assembly is still the right belt-and-braces for the plants. But it meant the
# stripper could be removed entirely and the file best placed to notice said
# nothing. So this section makes the dependence real: it writes the forbidden
# idiom LITERALLY, inside a quoted heredoc, and then asserts BOTH halves.
#
# BOTH halves, because either alone is vacuous:
#   (a) the literal really is present in this file's raw source — otherwise
#       "scanning finds nothing" is true for the boring reason;
#   (b) scanning this file nonetheless yields zero hits — which can only be
#       true if heredoc bodies are being excluded.
#
# Disable the stripper and (b) fails. That is the property #822 asked for.
#
# There is deliberately NO exemption for this file — not by filename, not by
# marker. The quoted heredoc IS the mechanism; an exemption would hide this
# scanner's own logic from its own rule.
_SELF="$REPO_ROOT/monitor/watcher/test-diagnostics-outlive-their-paths.sh"
cat >"$PLANT/literal-idiom.txt" <<'LITERAL_PLANT'
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
printf '  FAIL: it broke (see %s)\n' "$WORK/detail.log" >&2
LITERAL_PLANT

# (a) the raw source of THIS file really does carry all three parts of a
#     violation — the doomed assignment, the cleanup, and a citing diagnostic.
_raw_parts=0
grep -qE '^[[:space:]]*WORK=\$\(mktemp -d' "$_SELF" && _raw_parts=$(( _raw_parts + 1 ))
grep -q "rm -rf \"\$WORK\"" "$_SELF"                 && _raw_parts=$(( _raw_parts + 1 ))
grep -qE '(printf|echo).*\$WORK/.*>&2' "$_SELF"      && _raw_parts=$(( _raw_parts + 1 ))
assert_eq "NON-VACUITY: this file's RAW source carries a literal violation (3 parts)" \
    "$_raw_parts" "3"

# (b) …and the scanner still reports nothing for it, because those parts live
#     inside a quoted heredoc. Only heredoc-awareness can make both true.
assert_eq "…yet scanning this file yields ZERO hits (heredoc-awareness is load bearing)" \
    "$(scan_file "$_SELF" | wc -l)" "0"

# ── THE CORPUS ──────────────────────────────────────────────────────────
# Enumerated with `git ls-files` and a GLOB pathspec. NOT `git ls-tree`, whose
# pathspecs are path prefixes rather than globs and which returns a confident
# zero for exactly this query (your-org/nexus-code#770). The count is then
# sanity-checked against a floor, because a silent zero here would render this
# whole file a check that cannot fail.
cd "$REPO_ROOT" || { echo "FAIL: cd repo root"; exit 1; }
n_files=0; n_doomed=0
hits=""
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    n_files=$(( n_files + 1 ))
    # Same stripped view scan_file uses, so the "how many files are even
    # exposed" figure and the hit list are computed over the SAME population.
    # Counting doomed-dir files from raw source while scanning from the
    # stripped view would make the denominator and the numerator disagree.
    _src=$(th_strip_heredocs "$f" 2>/dev/null)
    if grep -qE '^[[:space:]]*[A-Za-z_]+=\$\(mktemp -d' <<<"$_src" \
       && grep -q 'trap .*EXIT' <<<"$_src"; then
        n_doomed=$(( n_doomed + 1 ))
    fi
    found=$(scan_file "$f" "$_src")
    [[ -n "$found" ]] && hits+="$found"$'\n'
# THE WIDE PATHSPEC HERE IS DELIBERATE (your-org/nexus-code#1111). git matches
# pathspecs with `fnmatch` WITHOUT `FNM_PATHNAME`, so this `*` CROSSES `/` and
# the enumeration also picks up `monitor/watcher/test-integration/_harness.sh`
# and `.../stub-claude.sh`, which are a shared library and a `claude` shim
# rather than suites. `#1111` narrowed the SUITE-COUNT sites to
# `:(glob)**/test-*.sh` because their label says "tracked test suites" and
# their number is quoted as a measurement. This site is NOT one of those: it
# enumerates a corpus TO LINT, and `_harness.sh` is 510 lines carrying exactly
# the constructs scanned for here. Narrowing it would DELETE COVERAGE from the
# one file most worth scanning, dressed up as a consistency fix. Leave it wide.
done < <(git ls-files -- '*test-*.sh')

# A population this scan could not have enumerated makes every result below
# meaningless. 200 is a deliberate floor well under the ~285 tracked today:
# it catches "the enumeration returned nothing" without breaking on ordinary
# growth or pruning of the corpus.
# The scanner MUST be inside the population it scans. Without this, a future
# "fix" that quietly drops this file from the enumeration would look identical
# to a clean sweep.
assert_eq "the scanner's own file is inside the scanned corpus" \
    "$(git ls-files -- '*test-*.sh' | grep -cxF 'monitor/watcher/test-diagnostics-outlive-their-paths.sh')" "1"
# "paths matching *test-*.sh", not "test files": git's pathspec `*` crosses `/`
# so this corpus also holds test-integration/_harness.sh and stub-claude.sh.
# Scanning them is correct (see the note at the enumeration below); the label is
# the half that was over-claiming. your-org/nexus-code#1111.
assert_eq "the corpus was actually enumerated (>=200 paths matching *test-*.sh)" \
    "$([[ "$n_files" -ge 200 ]] && echo yes || echo "no ($n_files)")" "yes"
assert_eq "…and files with a trap-doomed mktemp dir were found (>=150)" \
    "$([[ "$n_doomed" -ge 150 ]] && echo yes || echo "no ($n_doomed)")" "yes"

# ── THE CLAIM ───────────────────────────────────────────────────────────
found_set=$(printf '%s' "$hits" | grep -v '^$' | cut -d: -f1 | sort -u)
allowed_set=$(printf '%s' "$MANIFEST" | grep -v '^[[:space:]]*$' \
              | sed 's/::.*//' | sort -u)

new_violations=$(comm -23 <(printf '%s\n' "$found_set" | grep -v '^$') \
                          <(printf '%s\n' "$allowed_set" | grep -v '^$'))
stale_exemptions=$(comm -13 <(printf '%s\n' "$found_set" | grep -v '^$') \
                            <(printf '%s\n' "$allowed_set" | grep -v '^$'))

if [[ -n "$new_violations" ]]; then
    printf '  FAIL: %d file(s) cite a path their own EXIT trap deletes:\n' \
        "$(printf '%s\n' "$new_violations" | grep -c .)" >&2
    printf '%s\n' "$hits" | grep -v '^$' | sed 's/^/          | /' >&2
    printf '        Print the CONTENTS, not the path. The reader of this diagnostic is\n' >&2
    printf '        holding a CI log for a temp dir that was removed at suite exit.\n' >&2
    printf '        If a citation is genuinely justified, add it to MANIFEST above\n' >&2
    printf '        with a reason (your-org/nexus-code#794).\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: no test file cites a path its own EXIT trap deletes (%d scanned)\n' "$n_files"
    PASS=$(( PASS + 1 ))
fi

if [[ -n "$stale_exemptions" ]]; then
    printf '  FAIL: MANIFEST exempts file(s) that no longer violate the rule:\n' >&2
    printf '%s\n' "$stale_exemptions" | sed 's/^/          | /' >&2
    printf '        Remove them — a stale exemption silently re-permits the defect.\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: MANIFEST carries no stale exemptions\n'
    PASS=$(( PASS + 1 ))
fi

th_summary_and_exit
