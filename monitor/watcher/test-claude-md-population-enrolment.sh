#!/usr/bin/env bash
# EVERY SUITE THAT READS CLAUDE.md MUST DECLARE A POPULATION.
# your-org/nexus-code#1219.
#
# ---------------------------------------------------------------------------
# THE DEFECT
# ---------------------------------------------------------------------------
#
# A family of suites exists to keep CLAUDE.md's fenced blocks from rotting.
# Each block ends with some variant of "executed against a planted fixture by
# test-claude-md-<x>.sh, so this block is checked, not asserted" — and that
# sentence is the reason a reader trusts the block. The suites do execute the
# blocks. What did not work was the GATE: `guards-for-diff` could not name any
# of them for an edit to CLAUDE.md, because they declared no population, and a
# suite that declares no population is INVISIBLE to the index rather than
# excluded by it (#1078). It appears in neither SELECTED nor CONSIDERED AND
# EXCLUDED, so its absence is indistinguishable from a considered exclusion.
#
# Measured at 5bd6d400, nothing staged: 22 suites named test-claude-md-*.sh,
# of which 2 declared. The issue was filed against 15/1. Enrolment gained one
# while the population gained seven — so this is a WIDENING defect, and a
# one-time enrolment buys a number that is wrong again in a week.
#
# ---------------------------------------------------------------------------
# WHY A RATCHET RATHER THAN THE ENROLMENT ALONE
# ---------------------------------------------------------------------------
#
# Nothing in the authoring path REQUIRES enrolment. `test-guards-for-diff.sh`
# §1 asserts that the set of suites which DECLARE equals the manifest's rows —
# a set equality that catches a suite which BEGINS declaring without a row, and
# a suite that STOPS declaring. It cannot catch a suite that NEVER declared:
# such a suite is in neither derivation, the two sets agree, and every signal
# reads clean while telling the truth. That is the exact residual this file
# closes, and it closes it on the only axis that can: MEMBERSHIP of an
# APPLICABILITY set, computed from the tree.
#
# ---------------------------------------------------------------------------
# APPLICABILITY, NEVER CONFORMANCE (your-org/nexus-code#1197, #1224)
# ---------------------------------------------------------------------------
#
# The single most likely way this file is wrong is a predicate that asks "does
# this suite already declare?" — conformance — instead of "is this suite
# SUBJECT to the rule?" — applicability. A conformance predicate is
# self-referential: satisfying it is what puts a file in the population, so
# VIOLATING it removes the file, and the violation is precisely what this guard
# exists to catch. The predicate would delete its own evidence.
#
# So the population key is `_cme_reads_doc`: does this file NAME CLAUDE.md as a
# PATH. A suite's name and its reference to the document do not change when it
# stops declaring, so a violating suite stays in the population and stays
# selectable by the edit that creates the violation.
#
# THE KEY IS NOT THE FILENAME GLOB, and that choice is measured rather than
# stylistic. `test-claude-md-*.sh` is the obvious family key and it is a
# CONVENTION — evadable by naming a new CLAUDE.md-pinning suite anything else,
# and the evasion is silent. Keying on the document reference instead returns
# 24 files at 5bd6d400 where the glob returns 22: the two extra are
# `test-grep-delegation-arms.sh` (already enrolled) and
# `test-pane-state-claude-identity.sh` (not enrolled, and recorded below). The
# glob would have found neither.
#
# ---------------------------------------------------------------------------
# WHAT THIS CANNOT CATCH — stated rather than implied
# ---------------------------------------------------------------------------
#
#   * A suite that reads CLAUDE.md WITHOUT naming it as a path — through a
#     variable assigned elsewhere, or by a `git grep` over the whole tree. The
#     predicate is over SOURCE TEXT standing in for a runtime property, so it
#     UNDER-counts, and that is the direction it errs in (#1214).
#   * An UNTRACKED new suite. The enumeration is `git ls-files`, so a suite
#     written and not yet `git add`ed is in neither the population nor the
#     assertion. That is #1054's boundary and the reason CLAUDE.md tells you to
#     `git add` before trusting `guards-for-diff`; `--run` reports such a green
#     as UNVERIFIED at exit 4. The moment the file is staged — which it must be
#     to be committed — both halves see it.
#   * WHETHER a declared population is CORRECT. This file asserts that a
#     population is declared and recorded, never that it names the right files.
#     `guard-populations.manifest`'s floors and sentinels carry that.
#
# Run: bash monitor/watcher/test-claude-md-population-enrolment.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MANIFEST="$_test_dir/guard-populations.manifest"

# The grep the `#618` ugrep wrapper cannot shadow. Same derivation as
# test-guards-for-diff.sh, for the same reason: this file's answers are
# set memberships, and a wrapper that rejects an argument returns a silent zero
# shaped exactly like a true negative.
REAL_GREP=$(type -P grep 2>/dev/null) || REAL_GREP=/bin/grep

# The protocol CALL, both halves — the implementation itself, not a name, a
# directory, or a comment that could drift away from it. Spelled the same way
# `test-guards-for-diff.sh` spells it, and re-derived here rather than imported,
# deliberately, so the two CAN disagree and something can notice.
DECL='gp_handle "$@"'
DECL2='gp_population()'

# ── the two per-file predicates ─────────────────────────────────────────────
# Factored as functions taking a PATH, not written inline into the enumerator,
# because the controls below have to run them against PLANTED files. A control
# that exercised a second copy of the predicate would prove nothing about this
# one.

# APPLICABILITY. Does this file name CLAUDE.md as a PATH? `-e` declares the
# next argument a pattern and `--` ends option parsing, per CLAUDE.md's
# DASH-PATTERN-OPTION entry — belt and braces here rather than a habit that
# fails the day the pattern grows a leading dash.
_cme_reads_doc() {   # <file> -> rc 0 if it names CLAUDE.md as a path
    "$REAL_GREP" -qE -e 'CLAUDE_MD=|/CLAUDE\.md' -- "$1" 2>/dev/null
}

# CONFORMANCE — used only INSIDE assertions, never to build the population.
_cme_declares() {    # <file> -> rc 0 if it implements the --population protocol
    "$REAL_GREP" -qF -e "$DECL"  -- "$1" 2>/dev/null || return 1
    "$REAL_GREP" -qF -e "$DECL2" -- "$1" 2>/dev/null || return 1
    return 0
}

# ── the enumerator ──────────────────────────────────────────────────────────
# `:(glob)` is load-bearing (#954, #1111): git matches pathspecs with `fnmatch`
# WITHOUT `FNM_PATHNAME`, so a bare `*` crosses `/` and `'*test-*.sh'` would
# also match this repo's `test-integration/` directory COMPONENT.
#
# Per-file rather than `git grep -l`, so the population and the controls share
# one predicate. ~400 files, one grep each; measured under a second.
_cme_applicable() {
    (
        cd "$REPO_ROOT" || exit 1
        git ls-files -- ':(glob)**/test-*.sh' 2>/dev/null | while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            _cme_reads_doc "$f" && printf '%s\n' "$f"
        done
        # AN ENUMERATOR'S EXIT STATUS MUST DESCRIBE THE ENUMERATION, NOT ITS
        # LAST CANDIDATE. A `while` loop's rc is its final iteration's, so this
        # returns 1 whenever the alphabetically-last suite is not applicable —
        # the ordinary case — and `pipefail` above then carries that 1 out of
        # `gp_population`, where `gp_render` reads it as "the enumerator FAILED"
        # and REFUSES (rc 3), taking the whole index to exit 2 on a healthy
        # tree. Same idiom, same reason, as `_tgfd_discovered`.
        true
    ) | sort
}

# ── this suite DECLARES its own population ──────────────────────────────────
# SELF-COMPLETING, and that is the whole point of the shape (#1170 applied one
# level down). This guard's population IS the applicability set, so the single
# edit that can make the assertion below fail — adding or renaming a suite that
# reads CLAUDE.md — puts that file into this guard's population on the very
# commit that creates the defect. Derived from the manifest alone, this guard's
# population would be the artefact it checks, and it would be truthfully
# excluded by exactly the change it exists to catch.
#
# CLAUDE.md is deliberately NOT declared. This guard's verdict does not depend
# on one byte of that document — it depends on which suites reference it. The
# job of making a CLAUDE.md edit select the suites that pin it belongs to those
# suites' own populations, not to this one; over-declaring here would buy a
# false selection and blur which mechanism does which job.
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    _cme_applicable
    printf '%s\n' \
        monitor/watcher/guard-populations.manifest \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"

# ── RECORDED EXEMPTIONS ─────────────────────────────────────────────────────
# Suites that READ CLAUDE.md and do NOT declare a population. This list is a
# RATCHET, asserted by SET EQUALITY in both directions: a new unenrolled reader
# reds, and an exemption that gets fixed ALSO reds until its line is deleted.
# It may only ever SHRINK.
#
# YOU ARE ADDING A SUITE: give it a `gp_population` and a
# `guard-populations.manifest` row. Do NOT append a line here — appending is
# opting your own new code out of the standard this file exists to hold, which
# is the failure `summary-honesty.manifest`'s header names in the same words.
#
# THE ONE MEMBER, and why it is here rather than fixed:
#   test-pane-state-claude-identity.sh reads CLAUDE.md's bytes to assert the
#   document no longer carries a sentence the code contradicts
#   (`assert_not_contains … "$(cat "$REPO_ROOT/CLAUDE.md")" …`). It is a real
#   instance of this defect found while fixing it, and it is outside the
#   #1219 change surface. Recorded rather than silently excluded, because a
#   silence and a considered exclusion look identical (#1078) — which is the
#   entire subject of this file.
CME_EXEMPT=(
    monitor/watcher/test-pane-state-claude-identity.sh
)

WORK=$(mktemp -d) || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- assertion-count guard (your-org/nexus-code#946 F6) --------------------
#   1 precondition + 3 classifier controls + 4 enumerator controls
#   + 2 ratchet + 2 manifest = 12. The guard's OWN assert_eq is NOT included:
#   it reads PASS+FAIL before incrementing them, so counting itself would make
#   the expected total unreachable by exactly one.
_th_count_guard() {
    local EXPECTED_ASSERTIONS=12
    local TOTAL_ASSERTIONS=$(( PASS + FAIL ))
    assert_eq "assertion TOTAL matches the EXPECTED total" \
              "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"
    th_summary_and_exit
}

echo '=== 0. preconditions ==='
assert_file_exists "guard-populations.manifest is readable" "$MANIFEST"

echo
echo '=== 1. the CLASSIFIER can see a presence AND an absence ==='
# No absence below is believed until this section proves the instrument that
# reports it can report the opposite. Run against PLANTED files, so the control
# is over the predicate rather than over the tree it happens to be pointed at.
cat > "$WORK/declaring.sh" <<'PLANT'
#!/usr/bin/env bash
. "$(dirname "$0")/../_guard_population.sh"
gp_population() { printf '%s\n' CLAUDE.md; }
gp_handle "$@"
PLANT
cat > "$WORK/bare.sh" <<'PLANT'
#!/usr/bin/env bash
DOC="$REPO_ROOT/CLAUDE.md"
PLANT
# THE HALF-DECLARATION IS THE CORNER THAT MATTERS. A file carrying only the
# definition and not the CALL does not participate in the protocol at all —
# `guards-for-diff` never asks it anything — so classifying it as declaring
# would record a guard the index cannot see as covered.
cat > "$WORK/half.sh" <<'PLANT'
#!/usr/bin/env bash
gp_population() { printf '%s\n' CLAUDE.md; }
PLANT
assert_eq "a file carrying BOTH protocol tokens is classified DECLARES" \
          "$( _cme_declares "$WORK/declaring.sh" && echo yes || echo no )" "yes"
assert_eq "a file carrying NEITHER is classified BARE" \
          "$( _cme_declares "$WORK/bare.sh" && echo yes || echo no )" "no"
assert_eq "a file carrying only gp_population() and no CALL is classified BARE" \
          "$( _cme_declares "$WORK/half.sh" && echo yes || echo no )" "no"

echo
echo '=== 2. the ENUMERATOR keys on APPLICABILITY, not on conformance ==='
APPLICABLE=$(_cme_applicable)
n_applicable=$(printf '%s\n' "$APPLICABLE" | "$REAL_GREP" -c . || true)

# NON-VACUITY. A collapsed enumeration would make every set comparison below a
# comparison of two nothings — the silent-zero shape, inside the guard against
# it. The floor is well under the live count so ordinary growth never trips it.
assert_eq "the applicability enumeration is non-vacuous (>= 15 suites)" \
          "$( (( n_applicable >= 15 )) && echo ok || echo "TOO_FEW:$n_applicable" )" "ok"

_cme_has() {   # <newline-list> <path> -> yes|no, EXACT line membership
      # HERESTRING, NOT A PIPE (your-org/nexus-code#622). `grep -q` exits at the
      # FIRST match without draining, the upstream `printf` takes SIGPIPE, and
      # under `set -o pipefail` a row that DOES match returns 141 — a FALSE
      # FAILURE on exactly the input the check exists to accept. Measured on an
      # isolated worktree: 3 of 6 whole-suite runs RED, each naming a DIFFERENT
      # innocent suite; 51 false failures in 2040 row-pairs, every non-zero rc
      # exactly 141. With this form: 0 in 2040.
      if "$REAL_GREP" -qxF -- "$2" <<<"$1"; then printf 'yes'; else printf 'no'; fi
}

# POSITIVE CONTROL — a suite that plainly reads the document is IN.
assert_eq "POSITIVE CONTROL: a plain fenced-block suite is in the population" \
          "$(_cme_has "$APPLICABLE" "monitor/watcher/test-claude-md-lstree-pathspec.sh")" "yes"

# THE CONFORMANCE CONTROL, and it is the load-bearing one. An ALREADY-DECLARING
# applicable suite must stay in the population. A predicate rewritten to key on
# "does not yet declare" — the natural and wrong way to enumerate work
# remaining — would drop exactly this file, and would then be unable to notice
# the day it stopped declaring.
assert_eq "CONFORMANCE CONTROL: an already-declaring reader is still in the population" \
          "$(_cme_has "$APPLICABLE" "monitor/watcher/test-grep-delegation-arms.sh")" "yes"

# NEGATIVE CONTROL — and it is what separates "reads the document" from
# "mentions it". test-pane-state.sh carries the string CLAUDE.md in prose and
# never opens the file; it must be OUT. Without this, a predicate matching the
# bare word would pass every assertion above and quietly demand a population
# from 45 suites instead of 24.
assert_eq "NEGATIVE CONTROL: a suite that only MENTIONS CLAUDE.md is out" \
          "$(_cme_has "$APPLICABLE" "monitor/watcher/test-pane-state.sh")" "no"

echo
echo '=== 3. THE RATCHET: every applicable suite declares, or is recorded ==='
undeclared=''
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    _cme_declares "$REPO_ROOT/$f" || undeclared+="$f"$'\n'
done <<<"$APPLICABLE"
undeclared=$(printf '%s' "$undeclared" | "$REAL_GREP" -v '^$' | sort || true)
recorded=$(printf '%s\n' ${CME_EXEMPT[@]+"${CME_EXEMPT[@]}"} | "$REAL_GREP" -v '^$' | sort || true)

# NON-VACUITY of the comparison: at least some applicable suites DO declare, so
# a total collapse of `_cme_declares` cannot pass this section by making both
# sides equal to the full list.
n_declaring=$(( n_applicable - $(printf '%s\n' "$undeclared" | "$REAL_GREP" -c . || true) ))
assert_eq "the declaring side is non-empty (>= 10) — the equality below is not vacuous" \
          "$( (( n_declaring >= 10 )) && echo ok || echo "TOO_FEW:$n_declaring" )" "ok"

assert_eq "the suites that READ CLAUDE.md and do NOT declare are EXACTLY the recorded exemptions" \
          "$undeclared" "$recorded"

# REPORT THE DISAGREEMENT, NOT THE TOTALS. Two totals can match while
# membership differs by one each way, and a number that reconciles because its
# errors cancel is not verified (#946 F1, #931). `comm` names the sides and
# labels each with the direction it means.
if [[ "$undeclared" != "$recorded" ]]; then
    _add=$(comm -23 <(printf '%s\n' "$undeclared") <(printf '%s\n' "$recorded") | "$REAL_GREP" -v '^$' || true)
    _del=$(comm -13 <(printf '%s\n' "$undeclared") <(printf '%s\n' "$recorded") | "$REAL_GREP" -v '^$' || true)
    if [[ -n "$_add" ]]; then
        printf '  DISAGREEMENT — READS CLAUDE.md and declares NO population (your-org/nexus-code#1219):\n' >&2
        printf '%s\n' "$_add" | sed 's/^/      + /' >&2
        printf '      Each `+` is a suite an edit to CLAUDE.md CANNOT select. Fix by adding a\n' >&2
        printf '      `gp_population` + `gp_handle "$@"` to it AND a guard-populations.manifest\n' >&2
        printf '      row. Do NOT add it to CME_EXEMPT — that opts your own new code out of the\n' >&2
        printf '      standard this guard exists to hold.\n' >&2
    fi
    if [[ -n "$_del" ]]; then
        printf '  DISAGREEMENT — recorded as exempt but now DECLARES (or no longer exists):\n' >&2
        printf '%s\n' "$_del" | sed 's/^/      - /' >&2
        printf '      Good news, and it is still a red: DELETE the line from CME_EXEMPT so the\n' >&2
        printf '      list keeps describing the tree. The ratchet may only ever SHRINK.\n' >&2
    fi
fi

echo
echo '=== 4. a declaring applicable suite is also RECORDED in the manifest ==='
# The declaration and the manifest row are two different acts, and
# test-guards-for-diff.sh §1 already couples them repo-wide. Asserted again
# here, scoped to this family, because the two messages differ: §1 says "the
# declaring set is not the manifest", this says "the suite you just enrolled is
# not recorded" — and the second is the one an author of a CLAUDE.md pin needs.
manifest_rows=$("$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" -v '^[[:space:]]*$' | cut -f1 | sort)
n_rows=$(printf '%s\n' "$manifest_rows" | "$REAL_GREP" -c . || true)
assert_eq "the manifest is non-empty (>= 3 rows) — the inclusion below is not vacuous" \
          "$( (( n_rows >= 3 )) && echo ok || echo "TOO_FEW:$n_rows" )" "ok"

missing=''
while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    _cme_declares "$REPO_ROOT/$f" || continue
      # Same #622 hazard, same remedy. Here the false 141 lands on the `||`, so a
      # row that IS in the manifest gets appended to `missing` — a PHANTOM
      # omission, which reads as the very defect this ratchet exists to report.
      "$REAL_GREP" -qxF -- "$f" <<<"$manifest_rows" || missing+="$f"$'\n'
done <<<"$APPLICABLE"
missing=$(printf '%s' "$missing" | "$REAL_GREP" -v '^$' || true)
assert_eq "every declaring CLAUDE.md reader has a guard-populations.manifest row" \
          "$missing" ""
if [[ -n "$missing" ]]; then
    printf '  These suites DECLARE a population and are recorded nowhere:\n' >&2
    printf '%s\n' "$missing" | sed 's/^/      + /' >&2
fi

echo
_th_count_guard
