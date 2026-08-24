#!/usr/bin/env bash
# `th_strip_heredocs` ASSERTED DIRECTLY, NOT THROUGH ITS CONSUMERS.
# (your-org/nexus-code#822)
#
# WHY THIS FILE EXISTS. `#806` added `th_strip_heredocs` to `_test_helpers.sh`
# and gave it THREE consumers and NO suite of its own. The `#819` skeptic
# measured what that indirection was worth: with the stripper disabled
# outright, **two of its three consumers stayed green** —
# `test-diagnostics-outlive-their-paths.sh` (the file `#806` was actually filed
# about) and `test-assertion-ledger.sh`. Only `test-fixture-port-lint.sh`
# reddened.
#
# So the marquee `#806` property was pinned by one file, and not the one anybody
# would look at. A guard whose removal is invisible to most of what depends on
# it means those consumers' greens were never evidence about it.
#
# Worse, the ARITHMETIC LEFT-SHIFT GUARD — the one stopping
# `$(( budget << streak ))` in `monitor/watcher/_scheduler.sh:574` being read as
# a heredoc opener — reddened NOTHING when broken. Not because it does not
# matter, but because the unterminated-at-EOF fail-safe silently absorbed it:
# the file was emitted unstripped, the fail-safe population moved 1 → 2, and no
# assertion was looking at that number. The fail-safe made the regression
# HARMLESS but also INVISIBLE, and those are different properties.
#
# This suite asserts the helper's behaviour directly, so each property fails on
# its own terms:
#
#   §1  heredoc bodies are blanked and code is preserved
#   §2  LINE NUMBERS survive (bodies blanked, never deleted) — load bearing,
#       every consumer reports `file:line`
#   §3  what is NOT a heredoc: `<<<` herestrings, and `<<` in arithmetic
#   §4  the unterminated-at-EOF fail-safe emits the file UNCHANGED *and* is loud
#   §5  the corpus: line-count preservation over every tracked shell file, and
#       the fail-safe population pinned as an EXACT SET
#
# ── THE TRAP THIS FILE IS ITSELF EXPOSED TO ─────────────────────────────
# A source-text lint is tripped by fixtures that legitimately WRITE the idiom
# being linted, and this file writes heredocs — including deliberately malformed
# ones — as its fixtures. Quoted heredocs are the mechanism that keeps that text
# out of the corpus lints' population, and they are used here throughout.
#
# There is NO exemption entry for this file anywhere, by filename or otherwise,
# and that is deliberate. A self-exemption would hide this guard's own logic
# from its own rule — the file best able to conceal a violation would be the one
# nobody scans. Where an exemption is genuinely needed elsewhere it is carried
# by MARKER with a stated reason (`fixture-port-lint:` is the worked example),
# never by path.
#
# Run: bash monitor/watcher/test-strip-heredocs.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MANIFEST="$_test_dir/strip-heredocs-failsafe.manifest"

[[ -r "$MANIFEST" ]] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }

WORK=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# strip <file> -> stripped text on stdout (stderr discarded)
strip() { th_strip_heredocs "$1" 2>/dev/null; }
# strip_err <file> -> stderr only
strip_err() { th_strip_heredocs "$1" 2>&1 >/dev/null; }

# ── §1 BODIES BLANKED, CODE PRESERVED ───────────────────────────────────
# The fixture is written with an OUTER quoted heredoc, so the inner heredoc it
# contains is data here and code there. That nesting is the whole reason this
# helper exists.
cat >"$WORK/basic.sh" <<'FIXTURE'
#!/usr/bin/env bash
BEFORE=1
cat > /tmp/x <<'INNER'
WORK=$(mktemp -d)
this text is DATA, not code
INNER
AFTER=2
FIXTURE
got=$(strip "$WORK/basic.sh")

assert_contains "code BEFORE a heredoc survives"  "$got" "BEFORE=1"
assert_contains "code AFTER a heredoc survives"   "$got" "AFTER=2"
assert_contains "the heredoc OPENER line survives (it is code)" "$got" "cat > /tmp/x"
assert_not_contains "the heredoc BODY is blanked" "$got" "this text is DATA"
# The specific thing #806 was filed about: a `mktemp -d` assignment written as
# fixture text must not be harvested as if the file ran it.
assert_not_contains "a mktemp -d assignment inside a heredoc is not code" \
    "$got" 'WORK=$(mktemp -d)'

# The unquoted and tab-stripped spellings are heredocs too. `<<-` matters
# because its terminator may be indented, and a scanner that misses the
# terminator blanks everything after it.
printf '%s\n' '#!/usr/bin/env bash' 'A=1' 'cat <<EOF' 'interpolating body' 'EOF' 'B=2' > "$WORK/unquoted.sh"
got=$(strip "$WORK/unquoted.sh")
assert_not_contains "an UNQUOTED heredoc body is blanked too" "$got" "interpolating body"
assert_contains     "…and code after it survives"             "$got" "B=2"

printf '%s\n' '#!/usr/bin/env bash' 'A=1' $'\tcat <<-EOF' $'\tdash body' $'\tEOF' 'B=2' > "$WORK/dash.sh"
got=$(strip "$WORK/dash.sh")
assert_not_contains "a <<- heredoc body is blanked" "$got" "dash body"
assert_contains     "…and its TAB-INDENTED terminator is recognised, so code after survives" \
    "$got" "B=2"

# Two heredocs opened on ONE line: the second delimiter must be queued, or the
# scanner resynchronises on the wrong terminator and blanks live code.
printf '%s\n' '#!/usr/bin/env bash' 'A=1' 'diff <(cat <<ONE' 'body one' 'ONE' ') <(cat <<TWO' 'body two' 'TWO' ')' 'B=2' > "$WORK/two.sh"
got=$(strip "$WORK/two.sh")
assert_not_contains "first of two heredocs on a line is blanked"  "$got" "body one"
assert_not_contains "second of two heredocs on a line is blanked" "$got" "body two"
assert_contains     "…and code after both survives"               "$got" "B=2"

# ── §2 LINE NUMBERS SURVIVE ─────────────────────────────────────────────
# Bodies are BLANKED, never deleted. Every consumer reports `file:line`, so a
# renumbered view is worse than no view — it points confidently at the wrong
# line. This is the property most likely to be broken by a "tidier" rewrite.
n_in=$(wc -l < "$WORK/basic.sh")
n_out=$(strip "$WORK/basic.sh" | wc -l)
assert_eq "the stripped view has the SAME line count as the source" "$n_out" "$n_in"
assert_eq "…and 'AFTER=2' is still on its original line" \
    "$(strip "$WORK/basic.sh" | grep -n 'AFTER=2' | cut -d: -f1)" \
    "$(grep -n 'AFTER=2' "$WORK/basic.sh" | cut -d: -f1)"

# ── §3 WHAT IS NOT A HEREDOC ────────────────────────────────────────────
# A herestring shares the `<<` prefix and is not a heredoc.
printf '%s\n' '#!/usr/bin/env bash' 'grep -q x <<<"$haystack"' 'AFTER_HERESTRING=1' > "$WORK/herestring.sh"
assert_contains "a <<< herestring does not open a heredoc" \
    "$(strip "$WORK/herestring.sh")" "AFTER_HERESTRING=1"

# THE ARITHMETIC LEFT SHIFT. This is the case `#822` found pinned by nothing.
# `$(( budget << streak ))` at monitor/watcher/_scheduler.sh:574 parses as a
# heredoc opened with the delimiter `streak`, which never recurs — so a stripper
# without this guard blanks that file from line 574 to EOF.
#
# Asserting it HERE rather than relying on a consumer is the point of this
# suite: with only the fail-safe watching, removing the guard produced no red
# anywhere, because the fail-safe quietly absorbed it.
printf '%s\n' '#!/usr/bin/env bash' 'BUDGET=1; STREAK=2' \
    'printf "%s\\n" $(( BUDGET << STREAK ))' 'AFTER_SHIFT=1' 'MORE_CODE=2' > "$WORK/shift.sh"
got=$(strip "$WORK/shift.sh")
assert_contains "a << LEFT SHIFT in arithmetic does not open a heredoc" "$got" "AFTER_SHIFT=1"
assert_contains "…so code after it is not blanked to EOF"               "$got" "MORE_CODE=2"
assert_empty    "…and no fail-safe fires, because nothing was mis-parsed" \
    "$(strip_err "$WORK/shift.sh")"

# The numeric-delimiter form of the same trap: `(o1 << 24)` in
# monitor/_remote_lib.sh:356. Rejected by the letter-initial delimiter rule
# rather than by arithmetic tracking, so it is a separate case.
printf '%s\n' '#!/usr/bin/env bash' 'X=$(( (o1 << 24) | o2 ))' 'AFTER_NUMERIC=1' > "$WORK/numshift.sh"
assert_contains "a numeric << shift does not open a heredoc either" \
    "$(strip "$WORK/numshift.sh")" "AFTER_NUMERIC=1"

# `<<` inside a QUOTED STRING is an argument, not a redirection — the case that
# fired on monitor/test-conflict-marker-lint.sh:158.
printf '%s\n' '#!/usr/bin/env bash' "_expect_no_match 'cat <<EOF'" 'AFTER_QUOTED=1' > "$WORK/quoted.sh"
assert_contains "a << inside a single-quoted argument does not open a heredoc" \
    "$(strip "$WORK/quoted.sh")" "AFTER_QUOTED=1"

# A comment cannot open a heredoc.
printf '%s\n' '#!/usr/bin/env bash' '# see the cat <<EOF idiom' 'AFTER_COMMENT=1' > "$WORK/comment.sh"
assert_contains "a << in a COMMENT does not open a heredoc" \
    "$(strip "$WORK/comment.sh")" "AFTER_COMMENT=1"

# ── §4 THE UNTERMINATED-AT-EOF FAIL-SAFE ────────────────────────────────
# Stripping can only REMOVE lines from a lint's population, so a stripper bug
# hides real violations. When the parse is provably wrong the helper must fall
# back to raw source — over-reporting, never under-reporting — AND say so.
printf '%s\n' '#!/usr/bin/env bash' 'cat <<NEVERCLOSED' 'body that runs to EOF' 'STILL_BODY=1' > "$WORK/unterm.sh"
got=$(strip "$WORK/unterm.sh")
err=$(strip_err "$WORK/unterm.sh")

assert_contains "fail-safe: an unterminated heredoc yields the file UNSTRIPPED" \
    "$got" "body that runs to EOF"
assert_eq "…byte-identical to the source, not a partial strip" \
    "$(printf '%s\n' "$got" | cksum)" "$(cksum < "$WORK/unterm.sh")"
# LOUD is half the contract. A silent fallback would make a stripper regression
# invisible, which is precisely the #822 finding.
assert_contains "…and it is LOUD on stderr, naming the delimiter" "$err" "NEVERCLOSED"
assert_contains "…and says what it did"                            "$err" "UNSTRIPPED"
# A well-formed file must NOT trip it: a fail-safe that fires on everything
# would "pass" this section while disabling stripping entirely.
assert_empty "a well-formed file does not trip the fail-safe" \
    "$(strip_err "$WORK/basic.sh")"

# ── §5 THE CORPUS ───────────────────────────────────────────────────────
# `git ls-files`, NOT `git ls-tree` (whose pathspecs are path prefixes, and
# which returns a confident zero for this query — your-org/nexus-code#770).
# Enumerated by SHEBANG rather than a `*.sh` glob: the shell population here is
# larger than the glob (`monitor/ng`, `monitor/ghwrap/gh`, `nexus`, `watcher`, …).
cd "$REPO_ROOT" || { echo "FAIL: cd repo root"; exit 1; }
n_files=0 n_mismatch=0 failsafe=""
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # Herestring, never `head … | grep -q`. `grep -q` exits at the first match
    # without draining, so the writer takes EPIPE and under `pipefail` the
    # pipeline reports failure exactly when the test is TRUE — silently dropping
    # matching files from this enumeration, which is the population every
    # assertion below rests on. Caught by test-sigpipe-assertion-lint.sh, in a
    # file whose whole subject is guards that cannot see themselves fail
    # (your-org/nexus-code#622).
    grep -qE '^#!.*(bash|sh|zsh)' <<<"$(head -1 "$f" 2>/dev/null)" || continue
    n_files=$(( n_files + 1 ))
    if [[ "$(strip "$f" | wc -l)" != "$(wc -l < "$f")" ]]; then
        n_mismatch=$(( n_mismatch + 1 ))
        printf '         line-count mismatch: %s\n' "$f" >&2
    fi
    [[ -n "$(strip_err "$f")" ]] && failsafe+="$f"$'\n'
done < <(git ls-files)

# A population this scan could not have enumerated makes every result below
# meaningless — the silent-zero class this repo keeps re-learning. 300 is a
# deliberate floor well under the ~446 shell files tracked today.
if (( n_files >= 300 )); then
    _th_pass
    printf '  PASS: the shell corpus was actually enumerated (%d files by shebang)\n' "$n_files"
else
    printf '  FAIL: enumeration returned %d shell files (expected >=300) — the scan is blind\n' "$n_files" >&2
    _th_fail
fi

if (( n_mismatch == 0 )); then
    _th_pass
    printf '  PASS: line numbers preserved across all %d shell files\n' "$n_files"
else
    printf '  FAIL: %d file(s) changed line count under the stripper — every consumer\n' "$n_mismatch" >&2
    printf '        reports file:line, so a renumbered view points confidently at the wrong line\n' >&2
    _th_fail
fi

# THE FAIL-SAFE POPULATION, AS AN EXACT SET. This is the assertion that would
# have caught mutant E: breaking the arithmetic guard moves this set from 1 to 2
# members, and without this nothing looks at that number.
expected=$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | cut -d: -f1 | sort -u)
actual=$(printf '%s' "$failsafe" | grep -v '^$' | sort -u || true)

new_fs=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
if [[ -z "$new_fs" ]]; then
    _th_pass
    printf '  PASS: no NEW unparseable file (%d on record)\n' "$(printf '%s\n' "$expected" | grep -c .)"
else
    _th_fail
    printf '  FAIL: file(s) th_strip_heredocs can no longer parse:\n' >&2
    printf '%s\n' "$new_fs" | sed 's/^/         /' >&2
    printf '        A guard stopped working. The fail-safe absorbed it — the consumers fall\n' >&2
    printf '        back to raw source and stay green — which is exactly why this set is\n' >&2
    printf '        pinned. Find which guard, do not add a line.\n' >&2
fi

gone_fs=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
if [[ -z "$gone_fs" ]]; then
    _th_pass
    echo "  PASS: no stale fail-safe entries"
else
    _th_fail
    printf '  FAIL: recorded file(s) now parse cleanly — delete these lines:\n' >&2
    printf '%s\n' "$gone_fs" | sed 's/^/         /' >&2
fi

# EXPECTED-COUNT GUARD (your-org/nexus-code#807). Every assertion above is
# unconditional, so this is a constant. It is what makes a vanished assertion
# loud rather than invisible.
EXPECTED=30
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
