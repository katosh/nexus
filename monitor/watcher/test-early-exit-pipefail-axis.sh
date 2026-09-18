#!/usr/bin/env bash
# THE PIPEFAIL AXIS IS DECIDED ON CODE, NOT ON TEXT.
# (your-org/nexus-code#1106)
#
# `early-exit-readers.sh` classifies a file as "runs under pipefail" and that
# axis feeds `test-early-exit-reader-manifest.sh`, a CHECKED boundary manifest.
# The predicate was a bare `grep` over the whole file, wrong in BOTH directions,
# and the two directions need DIFFERENT controls — which is the whole reason
# this file exists rather than one more assertion in the manifest suite:
#
#   FALSE POSITIVE  a COMMENT naming the option enrolled the file. The most
#                   natural comment there is, is the one explaining why a file
#                   deliberately does NOT set it — so the predicate was most
#                   likely to fire exactly where it was most wrong.
#   FALSE NEGATIVE  the alternation used a literal SPACE, required `pipefail`
#                   to sit immediately after the first `-o`, and did not allow
#                   the operand to be quoted.
#
# ── THE FIXTURE IDIOMS ARE SYNTHESIZED, NOT WRITTEN ─────────────────────
#
# This suite tests a TEXT SCANNER, so any idiom spelled literally here becomes
# a member of the corpus that scanner walks. Writing `set -o pipefail` and a
# `| head` in the same fixture heredoc would put THIS FILE on the axis and book
# it a phantom early-exit row — the guard tripping its own lint. The repo has
# hit that once already: `bash-footgun-guard.sh` carries a note that an
# alternation written `(tail|head|…)` contains the substring `|head` and
# "booked a phantom row in a CHECKED boundary manifest for a 'pipeline' that is
# a regex, not a pipe."
#
# A quoted heredoc does NOT help — quoting changes what the SHELL does, and the
# classifier never runs the shell; it reads bytes. So the fixture lines are
# assembled from pieces at run time, and section D asserts the outcome that
# actually matters: adding this file left the real classifier's row count
# unchanged.
#
# Run: bash monitor/watcher/test-early-exit-pipefail-axis.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

# Assembled, never spelled. `P` is the pipe, `PF` the option name.
P='|'
PF="pipe""fail"
READER="sed -n '1p;q'"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fix"
mkdir -p "$FIX/monitor/watcher"
cp "$REPO_ROOT/monitor/watcher/early-exit-readers.sh" "$FIX/monitor/watcher/"
cp "$REPO_ROOT/monitor/watcher/_shell_quotes.awk"     "$FIX/monitor/watcher/"
cp "$REPO_ROOT/monitor/shell-files.sh"                "$FIX/monitor/"
git -C "$FIX" init -q 2>/dev/null
git -C "$FIX" config user.email t@t; git -C "$FIX" config user.name t

# plant <name> <first-line-of-body>
# Every plant carries an early-exit reader site, so enrollment on the axis is
# the ONLY thing that decides whether it gets a row.
plant() {
    { printf '#!/usr/bin/env bash\n'
      printf '%s\n' "$2"
      printf 'cat /etc/hostname %s head -1 >/dev/null\n' "$P"
    } > "$FIX/monitor/$1"
    chmod +x "$FIX/monitor/$1"
}
rows_for() {   # rows_for <name> -> how many manifest rows the classifier books
    # TEST THE PRODUCER'S RC. This was
    #     ( cd "$FIX" && git add -A; bash …/early-exit-readers.sh 2>/dev/null | grep -cF … ) || true
    # and a pipeline's status is its LAST command's, with stderr discarded — so
    # a classifier that DIED returned `0` rows and every "must NOT be booked"
    # assertion passed vacuously. Measured with a hard `exit 9` injected into
    # `_pf_build_axis`: the suite still went red overall (sections A and E are
    # genuine potency), but 8 of 14 assertions individually passed on a
    # classifier that produced nothing, and any future must-be-0 assertion
    # would inherit that. `#1106`'s own defect class, in the suite that polices
    # it (your-org/nexus-code#1127 skeptic).
    local _out _rc
    ( cd "$FIX" && git add -A >/dev/null 2>&1 )
    _out=$( cd "$FIX" && bash monitor/watcher/early-exit-readers.sh 2>/dev/null ); _rc=$?
    if [ "$_rc" != 0 ]; then
        printf 'CLASSIFIER-FAILED-rc%s' "$_rc"      # never a number: every comparison fails LOUD
        return
    fi
    grep -cF "monitor/$1" <<<"$_out" || true
}

# SITE-level, for section E. `rows_for` counts (file,kind,scope) ROWS, which
# cannot distinguish "the file's own reader was booked" from "a reader inside a
# string was booked" — they collapse into one row. The scoping rule is exactly
# that distinction, so E asks for sites and for their LINE NUMBERS.
_sites_raw() {
    local _out _rc
    ( cd "$FIX" && git add -A >/dev/null 2>&1 )
    _out=$( cd "$FIX" && bash monitor/watcher/early-exit-readers.sh --sites 2>/dev/null ); _rc=$?
    if [ "$_rc" != 0 ]; then printf 'CLASSIFIER-FAILED-rc%s' "$_rc"; return 1; fi
    grep -F "monitor/$1:" <<<"$_out" || true
}
sites_for()      { local o; if ! o=$(_sites_raw "$1"); then printf '%s' "$o"; return; fi
                   printf '%s' "$(grep -c . <<<"$o")"; }
site_lines_for() { local o; if ! o=$(_sites_raw "$1"); then printf '%s' "$o"; return; fi
                   printf '%s' "$(cut -f1 <<<"$o" | cut -d: -f2 | sort -n | paste -sd, -)"; }

echo '=== A: the harness itself discriminates (positive + negative control) ==='
plant pos.sh   "set -o ${PF}"
plant neg.sh   "true   # this plant sets no shell options at all"
assert_eq "A: a plant that really sets the option IS booked"        "$(rows_for pos.sh)" "1"
assert_eq "A: a plant that sets nothing is NOT booked"              "$(rows_for neg.sh)" "0"

echo '=== B: FALSE POSITIVE — the option NAMED IN A COMMENT must not enrol ==='
plant fp1.sh "# NOTE: this file deliberately does not set -o ${PF}."
plant fp2.sh "#     set -o ${PF}    <- what we would write if we wanted it"
assert_eq "B: a comment naming the option does NOT put the file on the axis"  "$(rows_for fp1.sh)" "0"
assert_eq "B: …including an indented, code-shaped comment"                    "$(rows_for fp2.sh)" "0"
# The other half of the same primitive: a `#` INSIDE A STRING is not a comment,
# so stripping must not eat real code. `sed 's/#.*$//'` fails this.
plant fp3.sh "grep -qF \"#1106\" /dev/null; set -o ${PF}"
assert_eq "B: a '#' inside a STRING is not a comment — the code still counts"  "$(rows_for fp3.sh)" "1"

echo '=== C: FALSE NEGATIVE — three spellings that really do enable it ==='
# Each was verified by EXECUTION (`[[ -o pipefail ]]` -> ON) before being
# asserted here; a spelling that does not enable the option would make this
# section demand a wrong answer.
plant fn1.sh "$(printf 'set\t-o\t%s' "$PF")"
plant fn2.sh "set -o errexit -o ${PF}"
plant fn3.sh "set -o \"${PF}\""
# fn4 IS A REGRESSION CONTROL, not another spelling. The SHIPPED predicate saw
# `set -o errexit -o nounset -o pipefail` — but only BY ACCIDENT: it was
# unanchored, and `nounSET` ends in the literal `set`, so it matched the
# substring `set -o pipefail` sitting inside `...nounset -o pipefail`.
# Anchoring at a command position correctly killed that accident, and the first
# draft of the replacement put NOTHING in its place, because its intervening
# group was `?` (at most ONE `-o opt`) rather than `*`. A RIGHT ANSWER HELD FOR
# A WRONG REASON, LOST WHEN THE WRONG REASON WAS FIXED — which is a better
# description of the class than anything in `#1106`.
#
# It survived review because ONE intervening option works fine, so any casual
# test passes; only the TWO-option form fails. Found by `#1127`'s skeptic.
plant fn4.sh "set -o errexit -o nounset -o ${PF}"
# `shopt -o` IS the option, and unlike a runtime-built operand it is literal
# static text — so the declared residual ("not enabled by a literal
# `set`/`setopt` word in this file's own text") did NOT excuse it, and an arm
# was added rather than the sentence widened. `shopt -s pipefail` WITHOUT `-o`
# is `invalid shell option name` and must stay out: that is fn_neg below.
plant fn5.sh "shopt -so ${PF}"
plant fn6.sh "shopt -o -s ${PF}"
for _s in "fn1.sh	TAB-separated" "fn2.sh	pipefail after a SECOND -o" "fn3.sh	quoted operand" \
          "fn4.sh	pipefail after TWO intervening -o options (regression control)" \
          "fn5.sh	shopt -so" "fn6.sh	shopt -o -s (the o flag not last)"; do
    _f=${_s%%	*}; _d=${_s##*	}
    assert_eq "C: $_d enrols the file" "$(rows_for "$_f")" "1"
    # and it really does enable the option — the claim behind the assertion
    _on=$(printf '%s\n[[ -o %s ]] && echo ON || echo off\n' "$(sed -n 2p "$FIX/monitor/$_f")" "$PF" \
          | bash --noprofile --norc 2>/dev/null)
    assert_eq "C: …and that spelling genuinely turns the option ON" "$_on" "ON"
done

# The negative half of the shopt arm. `shopt -s pipefail` is
# `invalid shell option name` — bash leaves the option OFF — so enrolling on it
# would be a false positive in the arm just added.
plant fn_neg.sh "shopt -s ${PF}"
assert_eq "C: shopt WITHOUT -o is not the option, and does NOT enrol" "$(rows_for fn_neg.sh)" "0"
_neg_on=$(printf '%s\n[[ -o %s ]] && echo ON || echo off\n' "shopt -s ${PF}" "$PF" | bash --noprofile --norc 2>/dev/null)
assert_eq "C: …and bash really does leave it OFF for that spelling" "$_neg_on" "off"

echo '=== E: SCOPE — an executed command string is its OWN pipefail scope ==='
# The THIRD flavour, which neither `#1106` nor comment-stripping addresses: the
# option named inside a QUOTED DATA STRING. This was the only LIVE instance in
# the tree — `test-service-health-selfmatch.sh` sets only `set -u` and has zero
# sourcers, yet carried a row in the CHECKED manifest because a health-check
# string it hands to a runner contains `set -o pipefail`.
#
# `#1127` anchored the match at a command position and removed that row — but
# only because the string BEGAN with `set`; spelled `"foo; set -o pipefail"` the
# phantom row remained, and this suite ASSERTED that residual rather than
# closing it. `#1130` makes the scoping decision the residual was waiting on:
#
#   AN EXECUTED COMMAND STRING IS ITS OWN PIPEFAIL SCOPE.
#
# so a string never enrols the FILE, and a reader whose PIPE is inside a string
# is on the axis iff that same string enables the option. The plants below are
# the corners of that rule, and there are five rather than two because
# asserting only "a string does not enrol the file" is satisfied by a
# classifier that ignored strings entirely — which drops the TRUE positive.
plant sp1.sh "run_it \"set -o ${PF}; pgrep zz ${P} head -1\""
assert_eq "E: a string that enables the option AND carries a reader books ONE site" \
    "$(sites_for sp1.sh)" "1"
assert_eq "E: …and it is the STRING's line, not the file's own unguarded reader" \
    "$(site_lines_for sp1.sh)" "2"

plant sp2.sh "run_it \"foo; set -o ${PF}\""
assert_eq "E: a string enabling the option does NOT put the FILE on the axis (#1127's residual, now closed)" \
    "$(sites_for sp2.sh)" "0"

plant sp3.sh "run_it \"false ${P} head -1\""
assert_eq "E: a string with a reader but NO pipefail is not a site" \
    "$(sites_for sp3.sh)" "0"

# The complement, so "strings are not sites" cannot be satisfied by a
# classifier that stopped seeing the FILE either.
plant sp4.sh "set -o ${PF}; run_it \"false ${P} head -1\""
assert_eq "E: with the FILE on the axis its own reader books a site, and the string still does not" \
    "$(sites_for sp4.sh)" "1"
assert_eq "E: …and that site is the file's own reader line" \
    "$(site_lines_for sp4.sh)" "3"

# `$( … )` REOPENS CODE INSIDE A DOUBLE-QUOTED SPAN. Without it the mask calls
# `x="$(cmd | head -1)"` text and the site vanishes; measured on the real tree,
# NINE live sites were lost to exactly this shape before `_shell_quotes.awk`
# learned it (node-forensics.sh:133, toolchain-bash.sh:170, ng:6354, …).
plant sp5.sh "set -o ${PF}; x=\"\$(cat /etc/hostname ${P} head -1)\""
assert_eq "E: a reader inside \$( … ) inside double quotes is CODE, and is booked" \
    "$(site_lines_for sp5.sh)" "2,3"

echo '=== D: this suite did not enrol ITSELF (the self-inflicted direction) ==='
# The classifier reads the real tree, and this file is in it. If any fixture
# idiom above were spelled literally, this file would be on the axis and would
# book a phantom row for a "pipeline" that is a string.
# D IS VACUOUS IF THIS FILE IS UNTRACKED, so that precondition is asserted
# rather than assumed (your-org/nexus-code#1127 skeptic; #1054). The classifier
# enumerates `git ls-files`, so an untracked file CANNOT be booked and D would
# pass because the file is invisible, not because it did not enrol — and the
# moment a bad edit exists is precisely BEFORE `git add`. Same lesson as this
# PR's own mutant M4.
_tracked=0
git -C "$REPO_ROOT" ls-files --error-unmatch monitor/watcher/test-early-exit-pipefail-axis.sh >/dev/null 2>&1 && _tracked=1
assert_eq "D: this suite is TRACKED, so the row check below is not vacuous" "$_tracked" "1"
_self=$( cd "$REPO_ROOT" && bash monitor/watcher/early-exit-readers.sh 2>/dev/null \
         | grep -cF 'test-early-exit-pipefail-axis.sh' ) || true
assert_eq "D: the real classifier books NO row for this control suite" "$_self" "0"

EXPECTED=$(( 2 + 3 + 12 + 2 + 7 + 2 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi
th_summary_and_exit
