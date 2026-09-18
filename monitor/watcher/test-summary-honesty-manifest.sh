#!/usr/bin/env bash
# WHAT EACH SUITE'S GREEN DOES NOT CERTIFY, PINNED AS DATA ON BOTH AXES.
# (your-org/nexus-code#805 boundary, corrected by #821)
#
# WHY THIS FILE EXISTS. `#805` stopped `th_summary_and_exit` announcing a pass
# over zero assertions and made it recover a FAIL lost in a subshell. That fix
# reaches exactly the suites that CALL it, so the residue had to be recorded
# rather than described — prose cannot be made to fail.
#
# WHY IT WAS REBUILT. The first version recorded ONE bucket and treated
# everything else as protected. The `#819` skeptic found that "count-guarded"
# was doing work it could not do, and measuring the correction found the
# classifier was wrong more widely than reported:
#
#   * THE TWO MECHANISMS PROTECT DIFFERENT THINGS. The ledger certifies that
#     *something* was asserted and that no FAIL was swallowed. It certifies
#     nothing about *how much*. An exact count guard is the opposite. Reporting
#     one axis as though it covered both is how "60 protected" was published
#     when the number protected on both axes is **6 of 253**.
#
#   * FIVE FILES WERE EXCLUDED ON A SUBSTRING. The old classifier asked whether
#     the word `EXPECTED` appeared anywhere. It matched `EXPECTED_TARGET` (a
#     config value), `EXPECTED_SLUG` (a path), and — in
#     `test-deliveries-split.sh` — the string `UNEXPECTEDLY` inside a printf.
#     Those five files have no count guard at all and were counted as protected.
#
#   * ONE USED A FLOOR. `test-lit-probe-order-dependence.sh` compares with
#     `-lt`. A suite can clear a floor and still under-assert, so "no longer
#     reports a pass at zero assertions" must never be read as "asserts enough".
#
# So the classifier here detects a MECHANISM — a comparison between an
# assertion total and an expected total — never a word. §1 pins that
# distinction with the `UNEXPECTEDLY` case as an explicit regression control,
# because a classifier that silently reverts to substring matching would
# repopulate the "protected" bucket with files that are not.
#
# Run: bash monitor/watcher/test-summary-honesty-manifest.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MANIFEST="$_test_dir/summary-honesty.manifest"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# The corpus this suite classifies, declared by the SAME `git ls-files` glob
# the scan below uses (and for the same reason: `git ls-tree` with a glob
# pathspec is a confident zero, #770). A test file classified `skip` today —
# it prints no banner — is exactly the file that acquires one, so the declared
# population is the enumeration, never the unguarded subset the manifest lists.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    ( cd "$REPO_ROOT" && git ls-files -- '*test-*.sh' )
    printf '%s\n' "$MANIFEST"
}
gp_handle "$@"

[[ -r "$MANIFEST" ]] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }

# ── THE CLASSIFIERS ─────────────────────────────────────────────────────
# AXIS A — does this file's green certify that anything was asserted at all,
# and that no FAIL was lost to a subshell? Only the ledger provides that.
#
# A LINE-ANCHORED CALL, NOT A MENTION (your-org/nexus-code#915 FINDING 2).
# This was a bare `grep -q 'th_summary_and_exit'` over the raw file, so a suite
# that merely NAMED the helper was credited with calling it: in a heredoc
# fixture it WRITES for some other suite, or in a `# TODO:` comment. That is
# over-crediting — the one direction this file promises it never goes.
#
# Same treatment `_count_axis` already has and for the same reason (#806):
# fixture text a suite writes is not a guard it has. The extra requirement is
# the ANCHOR — the helper must appear as a CALL at the start of a line, not as
# an argument, a string, or a word in prose. `#915` noted that stripping
# heredocs alone is insufficient, because fixtures here are also planted with
# `printf '%s\n' … 'th_summary_and_exit' > f`, which no heredoc strip removes;
# the anchor is what covers that shape.
#
# MEASURED NO-OP ON TODAY'S CORPUS, which is the point rather than a caveat.
# Over all 390 tracked suites at 859d9bee: the raw grep credits 185 and this
# form credits 185, membership identical, zero divergence. `#915` measured the
# same thing at 26bdd64 (111 of 111) and called it "latent, and cheap to close
# now". It is still latent and it is still cheap; closing a mechanism while it
# has no instances is the only time the change is free of argument about
# whether some existing row was right.
#
# THE HERESTRING IS NOT A STYLE CHOICE. `producer | grep -q` lets grep exit at
# the first match and SIGPIPE the producer, and under this file's `set -o
# pipefail` that 141 becomes the pipeline's status — inverting the verdict at
# the exact moment the thing being tested is TRUE. Measured while writing this:
# the piped form returned 141 for a file that DOES call the helper, and would
# have reported 16 suites as over-credited when the true number is 0. That is
# `monitor/watcher/test-sigpipe-assertion-lint.sh`'s whole subject, reproduced
# in the probe written to measure this axis.
_ledger_axis() {
    local view
    view=$(th_strip_heredocs "$1" 2>/dev/null | grep -vE '^[[:space:]]*#' || true)
    if grep -qE '^[[:space:]]*th_summary_and_exit([[:space:]]|$|\))' <<<"$view"
    then printf 'yes'; else printf 'no'; fi
}

# AXIS B — does it certify that ENOUGH was asserted? Only an EXACT comparison
# between an assertion total and an expected total does.
#
# Structural on purpose: a line that carries an expectation-ish operand, a
# count-ish operand, and a comparison. Reads the heredoc-stripped view (#806)
# so fixture text a suite WRITES is never read as a guard it HAS, and drops
# comments so prose about counting is not mistaken for counting.
#
# TWO EXCLUSIONS, BOTH LEARNED THE SAME WAY — by a mutant, not by foresight:
#
#   `UNEXPECTED` is the exact string that put `test-deliveries-split.sh` in the
#   protected bucket.
#
#   OUTPUT LINES are dropped, because a guard is CONTROL FLOW, not a banner.
#   The first draft of this very classifier — written to replace substring
#   matching with mechanism matching — accepted
#   `echo "=== summary: … expected $EXPECTED) ==="` as an exact guard, because
#   the decorative `===` satisfies its `==` test. Weakening a real file's exact
#   guard to a floor therefore changed nothing and the manifest stayed green.
#   The correction is the same one this file is about: match the mechanism, not
#   the characters. Mutant H in test-summary-honesty-manifest's verification is
#   what fails if this line is removed.
_count_axis() {
    local f="$1" lines
    lines=$(th_strip_heredocs "$f" 2>/dev/null \
            | grep -vE '^[[:space:]]*#' \
            | grep -vE '^[[:space:]]*(echo|printf)[[:space:]]' \
            | grep -E '(EXPECTED|EXPECT_|expected_)' \
            | grep -vE 'UNEXPECTED' \
            | grep -E '(\bPASS\b|\bFAIL\b|\bTOTAL\b|\bRUN\b|_total|ASSERTION|assertion)')
    [[ -n "$lines" ]] || { printf 'none'; return; }
    # your-org/nexus-code#1365 — computed FIRST because the assertion-CALL arm
    # below returns before any operand is examined, and the instance
    # (`assert_eq "F: … $EXPECTED_SURVIVAL_ASSERTIONS …"`) is a call. See the
    # subset block below for the rule; `_credit` applies it to both arms.
    local _quals _totals
    _quals=$(grep -oE 'EXPECTED_[A-Z0-9]+_(ASSERTIONS?|TOTAL|COUNT|RUN)' <<<"$lines" | grep -vE 'EXPECTED_(MIN|MAX)_' | sort -u)
    _totals=$(grep -oE '(^|[^A-Za-z0-9_])_?EXPECTED_(ASSERTIONS?|TOTAL[A-Z_]*|COUNT)\b|TOTAL_ASSERTIONS|expected_total' <<<"$lines" | sort -u)
    _credit() { if [[ -n "$_quals" && -z "$_totals" ]]; then printf 'subset'; else printf 'exact'; fi; }
    # An assertion CALL comparing a count to an expectation is exact even
    # though it carries no operator — `test-gh-capable.sh` spells it that way.
    grep -qE '^[[:space:]]*(assert_eq|assert_rc|eq)[[:space:]]' <<<"$lines" && { _credit; return; }
    # THE OPERATOR MUST BE THE COMPARISON'S, AND THE EXPECTATION MUST BE ITS
    # OPERAND (your-org/nexus-code#1167). The arms below used to ask only
    # whether SOME comparison operator appeared anywhere on a candidate line.
    # That is co-occurrence, not comparison, and one ordinary line satisfies it
    # while guarding nothing:
    #
    #     [[ "$HAVE_ZSH" == "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 12 ))
    #
    # `EXPECTED` ✓ `ASSERTION` ✓ `==` ✓ -> `exact`, from a line that compares a
    # CONFIGURATION FLAG to a string and then adds to a variable. So a PROTECTED
    # suite's real guard could be weakened to a floor — or deleted outright —
    # and this classifier still credited it `exact`. Over-reporting protection,
    # which this file's own header names as the dangerous direction.
    #
    # #1167 PRESCRIBED "require the operator and the assertion-TOTAL operand on
    # the same PHYSICAL LINE". That remedy does not survive measurement, and the
    # measurement is one grep: on the bump line above, `==` and
    # `EXPECTED_ASSERTIONS` ARE already on the same physical line. Implemented
    # literally it leaves the mutant SURVIVING — and #1167 itself states that a
    # fix which does not flip that mutant to KILLED has not fixed this.
    #
    # What separates the two shapes is ROLE: in the real guard the expectation
    # IS an operand of the comparison; in the bump it is the target of an
    # ASSIGNMENT that happens to share a line with an unrelated test.
    #
    # WHAT THIS KEYS ON IS ADJACENCY, WHICH IS A PROXY FOR THAT ROLE — stated
    # plainly, because a comment claiming to test role while testing adjacency
    # would be this file's own subject matter. The operator and the expectation
    # token must sit next to each other, with nothing between them but quoting,
    # sigils and the rest of the identifier. Adjacency implies the assignment
    # case is excluded, which is the whole of #1167; it does NOT imply the
    # comparison is between a COUNT and an EXPECTATION.
    #
    # THE RESIDUAL, MEASURED RATHER THAN REASONED. Two shapes still earn a false
    # `exact`, both verified against this classifier:
    #
    #   [[ "$mode" == "$EXPECTED_MODE" ]] && RUN=1
    #       adjacency holds, `\bRUN\b` makes the line a candidate, and the
    #       comparison is between two things that are not counts.
    #   assert_eq "the RUN used the EXPECTED profile" "$a" "$b"
    #       the assertion-CALL arm above returns before any operand is examined.
    #
    # LIVE INSTANCES TODAY: ZERO, across all 390 tracked suites at d3b45c19 —
    # and that zero is vouched by a positive control run in the same scan (a real
    # `(( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS ))` guard is still classified
    # `exact`), so it is a measured none rather than a scan that saw nothing.
    # Closing the residual means examining the comparison's operands, not merely
    # their position, and that is a wider change than #1167 asked for.
    #
    # `[A-Za-z0-9_]*` before the token is load-bearing and was found by the
    # corpus diff below, not by foresight: `(( _ran == _EXPECTED_ASSERTIONS ))`
    # is the single most common real spelling in this repo (11 suites), and a
    # lead-in that admits only quotes and sigils demotes every one of them.
    #
    # RE-ENUMERATED UNDER BOTH KEYS AND SET-DIFFED, per this repo's rule that a
    # key change silently re-scopes a population. Over all 390 tracked suites at
    # 989b8880, `git ls-files -- ':(glob)**/test-*.sh'`, nothing staged: the old
    # key and this one disagree on exactly ONE file,
    # `monitor/watcher/test-assertion-accounting.sh`, exact -> none. That credit
    # was nominal: its only operator was the substring `-eq` inside the FIXTURE
    # NAME `pass-eq-caps`. Its real guard is
    # `assert_eq … "${got_total:-<none>}" "$want_total"`, invisible here for two
    # independent documented reasons — the `\`-continuation, and operands
    # outside the recognised vocabulary. `none` is therefore the honest answer
    # in the under-crediting direction this classifier promises.
    local _exp='(EXPECTED|EXPECT_|expected_)'
    local _lead='["'"'"'$\{]*[A-Za-z0-9_]*'      # quoting, sigils, identifier prefix
    local _tail='[A-Za-z0-9_]*["'"'"'\}]*'
    # A SUBSET CENSUS IS NOT A TOTAL CENSUS (your-org/nexus-code#1365). An exact
    # comparison against `EXPECTED_SURVIVAL_ASSERTIONS=4` is a real guard over
    # a NAMED SUBSET of a suite's assertions — four of fifty-eight — and it used
    # to earn `exact`, which a manifest reader takes as "a vanished assertion
    # reddens this suite" for all fifty-eight. So: if every expectation
    # identifier the exact arms would credit is QUALIFIED (`EXPECTED_<WORD>_…`,
    # a subset by its own name) and no unqualified TOTAL expectation
    # (`EXPECTED_ASSERTIONS`, `_EXPECTED_ASSERTIONS`, `EXPECTED_TOTAL…`) is
    # compared anywhere in the candidate set, the honest class is `subset` —
    # under-crediting, which is this file's promised direction. `MIN`/`MAX`
    # qualifiers name a floor, not a subset, and fall through to the floor
    # arms as before.
    local _exact=0
    grep -qE "(!=|==|-ne|-eq)[[:space:]]*${_lead}${_exp}" <<<"$lines" && _exact=1
    grep -qE "${_exp}${_tail}[[:space:]]+(!=|==|-ne|-eq)"  <<<"$lines" && _exact=1
    if (( _exact == 1 )); then _credit; return; fi
    grep -qE "(-lt|-le|-gt|-ge)[[:space:]]*${_lead}${_exp}" <<<"$lines" && { printf 'floor'; return; }
    grep -qE "${_exp}${_tail}[[:space:]]+(-lt|-le|-gt|-ge)"  <<<"$lines" && { printf 'floor'; return; }
    printf 'none'
}

# THE DECLARED LIMIT OF AXIS B, and it is a real one. `_count_axis` recognises a
# VOCABULARY of count-ish operand names (`PASS`, `FAIL`, `TOTAL`, `RUN`,
# `_total`, `assertion`). A suite whose exact guard compares an operand named
# something else reads as `count=none` — under-crediting itself.
#
# Found the honest way: renaming this file's own guard operand from `_total` to
# `_ran` silently moved THIS FILE into the unprotected bucket, and the ratchet
# caught it. The fix was to use the documented vocabulary, not to widen the
# pattern until nothing escapes — widening is what produced the `EXPECTED_TARGET`
# and `UNEXPECTEDLY` false positives in the first place.
#
# The bias is deliberate and one-directional: an unrecognised spelling makes a
# suite look LESS protected than it is, never more. A manifest that
# over-reported protection would be the dangerous failure; this one
# over-reports exposure. The control below pins that direction so it cannot
# silently invert.

# ── §1 CLASSIFIER CONTROLS ──────────────────────────────────────────────
# A classifier nobody tested is how the first version shipped its error.
PLANT=$(mktemp -d) || { echo "FAIL: mktemp for the plants"; exit 1; }
trap 'rm -rf "$PLANT"' EXIT

printf '%s\n' '#!/usr/bin/env bash' 'th_summary_and_exit' > "$PLANT/a-yes.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "ALL TESTS PASSED"' > "$PLANT/a-no.sh"
assert_eq "AXIS A: a th_summary_and_exit suite is ledger=yes" "$(_ledger_axis "$PLANT/a-yes.sh")" "yes"
assert_eq "AXIS A: a hand-rolled summary is ledger=no"        "$(_ledger_axis "$PLANT/a-no.sh")"  "no"

# ── AXIS A OVER-CREDITING CONTROLS (your-org/nexus-code#915 FINDING 2) ──────
# A MENTION is not a CALL. Each plant below names the helper without invoking
# it, and each was credited `ledger=yes` by the bare grep this axis used to be.
# Latent rather than live — 185 of 185 suites agree under both forms at
# 859d9bee — so these pin the mechanism before it acquires an instance.
cat >"$PLANT/a-heredoc.sh" <<'HD'
#!/usr/bin/env bash
cat > /tmp/fixture <<'INNER'
th_summary_and_exit
INNER
HD
assert_eq "AXIS A: the helper inside a HEREDOC fixture is not a call" \
    "$(_ledger_axis "$PLANT/a-heredoc.sh")" "no"

printf '%s\n' '#!/usr/bin/env bash' '# TODO: adopt th_summary_and_exit here' \
    > "$PLANT/a-comment.sh"
assert_eq "AXIS A: the helper in a COMMENT is not a call" \
    "$(_ledger_axis "$PLANT/a-comment.sh")" "no"

# The shape #915 names as the one no heredoc strip removes: a fixture PLANTED
# with printf. The line anchor is what covers it.
printf '%s\n' '#!/usr/bin/env bash' \
    "printf '%s\\n' 'th_summary_and_exit' > \"\$f\"" > "$PLANT/a-printf.sh"
assert_eq "AXIS A: the helper as a printf ARGUMENT is not a call" \
    "$(_ledger_axis "$PLANT/a-printf.sh")" "no"

# POTENCY: the three above must not be satisfied by an axis that has gone
# blind. A real call INDENTED inside a function still reads yes — which is how
# every real suite in this repo spells it.
printf '%s\n' '#!/usr/bin/env bash' '_finish() {' '    th_summary_and_exit' '}' \
    > "$PLANT/a-indented.sh"
assert_eq "POTENCY: an indented real call still reads ledger=yes" \
    "$(_ledger_axis "$PLANT/a-indented.sh")" "yes"

printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED=3' '(( PASS + FAIL != EXPECTED )) && exit 1' > "$PLANT/b-exact.sh"
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_MIN=3' '[[ $_total -lt $EXPECTED_MIN ]] && exit 1' > "$PLANT/b-floor.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo hi' > "$PLANT/b-none.sh"
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_ASSERTIONS=56' 'eq "$RUN" "$EXPECTED_ASSERTIONS" "assertion count"' > "$PLANT/b-call.sh"
# your-org/nexus-code#1365: a census over a NAMED SUBSET is `subset`, not exact;
# the same qualified census beside a TOTAL guard stays exact.
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_SURVIVAL_ASSERTIONS=4' \
    '(( _sv_ran + _sv_skipped != EXPECTED_SURVIVAL_ASSERTIONS )) && { echo "survival ASSERTION census drifted"; exit 1; }' > "$PLANT/b-subset.sh"
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_SURVIVAL_ASSERTIONS=4' 'EXPECTED_ASSERTIONS=58' \
    '(( _sv_ran + _sv_skipped != EXPECTED_SURVIVAL_ASSERTIONS )) && { echo "survival ASSERTION census drifted"; exit 1; }' \
    '(( PASS + FAIL != EXPECTED_ASSERTIONS )) && exit 1' > "$PLANT/b-subset-and-total.sh"

assert_eq "AXIS B: an exact != comparison is count=exact" "$(_count_axis "$PLANT/b-exact.sh")" "exact"
assert_eq "AXIS B: a -lt comparison is count=FLOOR, not exact" "$(_count_axis "$PLANT/b-floor.sh")" "floor"
assert_eq "AXIS B: no guard at all is count=none" "$(_count_axis "$PLANT/b-none.sh")" "none"
assert_eq "AXIS B (#1365): an exact census over a NAMED SUBSET is count=subset" "$(_count_axis "$PLANT/b-subset.sh")" "subset"
assert_eq "AXIS B (#1365): the same subset census beside a TOTAL guard is count=exact" "$(_count_axis "$PLANT/b-subset-and-total.sh")" "exact"
# The instance: test-paste-dead-pane-guard.sh's only exact census is the
# 4-assertion survival subset (#1365) — the real file, not a plant.
assert_eq "AXIS B (#1365): test-paste-dead-pane-guard.sh classifies subset, not exact" \
    "$(_count_axis "$_test_dir/test-paste-dead-pane-guard.sh")" "subset"
assert_eq "AXIS B: an assertion CALL comparing counts is exact (no operator)" \
    "$(_count_axis "$PLANT/b-call.sh")" "exact"

# THE REGRESSION CONTROL FOR THE ORIGINAL DEFECT. Each of these carries the
# WORD but no mechanism, and each put a real file in the protected bucket.
printf '%s\n' '#!/usr/bin/env bash' "printf '  FAIL: %s UNEXPECTEDLY present\\n' \"\$l\" >&2" > "$PLANT/b-word1.sh"
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_TARGET=orchestrator' 'echo "$EXPECTED_TARGET"' > "$PLANT/b-word2.sh"
printf '%s\n' '#!/usr/bin/env bash' '# T2. EMPTY, WITH BANDS EXPECTED — the outage shape' 'PASS=1' > "$PLANT/b-word3.sh"
assert_eq "the word UNEXPECTEDLY in a printf is NOT a count guard" "$(_count_axis "$PLANT/b-word1.sh")" "none"
assert_eq "an EXPECTED_TARGET config value is NOT a count guard"   "$(_count_axis "$PLANT/b-word2.sh")" "none"
assert_eq "the word EXPECTED in a COMMENT is NOT a count guard"    "$(_count_axis "$PLANT/b-word3.sh")" "none"

# THE VOCABULARY LIMIT, pinned as data rather than left as prose. An exact
# comparison whose operand is named outside the recognised set reads as `none`.
# This assertion documents the blind spot AND its direction: under-crediting,
# never over-crediting.
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED=3' '(( _ran != EXPECTED )) && exit 1' > "$PLANT/b-vocab.sh"
assert_eq "KNOWN LIMIT: an exact guard on an unrecognised operand name reads as none" \
    "$(_count_axis "$PLANT/b-vocab.sh")" "none"

# A guard written as FIXTURE TEXT is not a guard the file has (#806).
cat >"$PLANT/b-heredoc.sh" <<'HD'
#!/usr/bin/env bash
cat > /tmp/fixture <<'INNER'
EXPECTED=3
(( PASS + FAIL != EXPECTED )) && exit 1
INNER
HD
assert_eq "a count guard written as HEREDOC fixture text does not count" \
    "$(_count_axis "$PLANT/b-heredoc.sh")" "none"

# ── THE ARITHMETIC-BUMP CONTROLS (your-org/nexus-code#1167) ─────────────
# The defect these pin: an `EXPECTED_ASSERTIONS` arithmetic bump carries an
# expectation token, a count token AND a comparison operator all on one line,
# so the pre-#1167 classifier read `exact` off a line that guards nothing —
# and a PROTECTED suite's real guard could then be deleted with the manifest
# staying green. #1167's N2/N3 are ready-made regression controls and are
# reproduced here as plants so the property is pinned rather than the incident.
#
# b-bump: the bump ALONE, no guard of any kind. Pre-fix this returned `exact`.
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_ASSERTIONS=7' \
    '[[ "$HAVE_ZSH" == "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 12 ))' \
    > "$PLANT/b-bump.sh"
assert_eq "AXIS B: an EXPECTED_ASSERTIONS arithmetic bump is NOT a count guard" \
    "$(_count_axis "$PLANT/b-bump.sh")" "none"

# b-bump-floor: the bump PLUS a real FLOOR. The honest level is `floor`; pre-fix
# the bump's `==` promoted it to `exact`, which is the over-credit that let a
# weakened guard pass unrecorded.
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_ASSERTIONS=7' \
    '[[ "$HAVE_ZSH" == "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 12 ))' \
    'TOTAL_ASSERTIONS=$(( PASS + FAIL ))' \
    '[[ "$TOTAL_ASSERTIONS" -ge "$EXPECTED_ASSERTIONS" ]] || exit 1' \
    > "$PLANT/b-bump-floor.sh"
assert_eq "AXIS B: a bump beside a FLOOR does not promote it to exact" \
    "$(_count_axis "$PLANT/b-bump-floor.sh")" "floor"

# THE `=`/`==` PAIR — #1167's N3, the load-bearing row: same file, same mutant,
# opposite verdict, with that one character as the only varied input. #1165
# worked around the defect by writing its entrant's bump with a single `=`.
# Post-fix BOTH spellings must read the same, because neither is a guard — so
# this pair also retires the reason that workaround existed.
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_ASSERTIONS=7' \
    '[[ "$HAVE_ZSH" = yes ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 12 ))' \
    > "$PLANT/b-bump-single.sh"
assert_eq "AXIS B: the =/== spelling of a bump no longer changes the verdict" \
    "$(_count_axis "$PLANT/b-bump-single.sh")" "$(_count_axis "$PLANT/b-bump.sh")"

# POTENCY, so the four assertions above cannot be satisfied by a classifier that
# has simply gone blind. A real exact guard sharing a file WITH a bump must
# still read `exact` — the bump is inert, not poisonous.
printf '%s\n' '#!/usr/bin/env bash' 'EXPECTED_ASSERTIONS=7' \
    '[[ "$HAVE_ZSH" == "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 12 ))' \
    'TOTAL_ASSERTIONS=$(( PASS + FAIL ))' \
    '(( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )) && exit 1' \
    > "$PLANT/b-bump-exact.sh"
assert_eq "POTENCY: a real exact guard beside a bump still reads exact" \
    "$(_count_axis "$PLANT/b-bump-exact.sh")" "exact"

# AND THE SPELLING THE CORPUS ACTUALLY USES, pinned because the corpus diff for
# #1167 showed a too-tight operand lead-in demotes all 11 suites that write it.
printf '%s\n' '#!/usr/bin/env bash' '_EXPECTED_ASSERTIONS=24' \
    'if (( _ran == _EXPECTED_ASSERTIONS )); then :; fi' > "$PLANT/b-underscore.sh"
assert_eq "AXIS B: (( _ran == _EXPECTED_ASSERTIONS )) is exact (leading underscore)" \
    "$(_count_axis "$PLANT/b-underscore.sh")" "exact"

# ── §2 THE CORPUS ───────────────────────────────────────────────────────
# `git ls-files` with a GLOB pathspec — NOT `git ls-tree`, whose pathspecs are
# path prefixes and which returns a confident zero here (#770).
# ── NO PROXY: EVERY TRACKED SUITE IS IN, NON-SUITES ARE DECLARED (#915) ──
# TWO PREVIOUS REVISIONS BOTH SELECTED BY A PROXY, and each proxy hid the
# suites that spelled their footer differently:
#
#     grep -q 'ALL TESTS PASSED' "$f" || continue          # one string
#     _announces_pass: banner OR th_summary_and_exit       # two strings
#
# `#864` widened one string to two and named the result `_announces_pass`,
# with the docstring "rc 0 if this file announces a pass". That was FALSE for
# 17 tracked suites whose footer reads `passed=$PASS failed=$FAIL` — every one
# of them `ledger=no count=none`, the worst protection level and the exact
# class this manifest exists to record. Their invisibility was not reasoned
# about; it was MEASURED (`#915`): a real subshell-lost FAIL injected into
# `test-hosting-migration.sh` printed `FAIL: MUTANT…`, then `passed=12
# failed=0`, exited 0 — and THIS GUARD then printed `no new or weakened
# unprotected suite` and exited 0. A real suite told a real lie and the
# honesty machinery certified the board.
#
# WIDENING ONE STRING TO TWO IS HOW THIS RECURS AT THREE. A third arm for the
# hand-rolled footer shape would hide the fourth spelling. So the proxy is
# GONE, not extended:
#
#   EVERY tracked `*test-*.sh` IS IN THE POPULATION. A file leaves only by
#   being DECLARED a non-suite here, by name, with a reason.
#
# That inverts the default from opt-in to opt-out, which is the whole point:
# a new suite is covered the moment it is added, whatever its footer says,
# and the only way to escape is an edit to this list that a reviewer sees.
# The residue is now ENUMERATED rather than counted — `19 outside` is a
# completeness claim a bare number cannot support, and it is precisely the
# kind of figure that ages into folklore.
declare -a _NON_SUITE_PATHS=(
    'monitor/watcher/test-integration/_harness.sh'
    'monitor/watcher/test-integration/stub-claude.sh'
)
declare -a _NON_SUITE_WHY=(
    'sourced library — builds the integration fixture; runs no assertions of its own'
    'a stub `claude` binary the integration scenarios exec; not a test'
)
_is_non_suite() {   # <path> -> rc 0 if DECLARED a non-suite above
    local p="$1" d
    for d in "${_NON_SUITE_PATHS[@]}"; do [[ "$p" == "$d" ]] && return 0; done
    return 1
}
# The predicate, as text, so the guard STATES the boundary it selected by.
_SELECTOR_DESC='every tracked *test-*.sh EXCEPT the non-suites declared by name in this file'
_CANDIDATE_DESC='tracked *test-*.sh'

# ── PROTECTED: THE FULLY-PROTECTED SUITES, AS CHECKED-IN DATA (#839) ────
# ONE ENTRANT at the your-org/nexus-code#1358 seam:
# `test-request-state-field.sh` enters fully protected (ledger=yes via
# `th_summary_and_exit`, count=exact via EXPECTED). It was written with a local
# `assert_eq` and a hand-rolled summary, which this guard classified
# `ledger=no count=none` — recorded here because the correct response to that
# red was to RAISE the suite to the protected form rather than to record it as
# unprotected, and a suite that asserts other readers' honesty has no business
# being the weaker kind.
# Every corpus file is on exactly one of two lists: the manifest (what a
# suite's green does NOT certify) or this one (nothing withheld — ledger=yes
# AND count=exact). Together they are a PIN: |PROTECTED| + |manifest| is the
# corpus size, recorded as literals that do not move when the scan does.
#
# WHY A LITERAL LIST AND NOT A FLOOR. This file used to check its own
# population with `n_files >= 200` and `n_full >= 1 && n_files - n_full >= 100`
# — in the file whose §4 exists to prove, live, that a floor is not protection,
# and which demands count=exact of 272 other suites. It was exempt from the
# class it polices. Measured on `e256d4a` before this change: deleting 29 of
# the 30 fully-protected suites left the guard reporting `21 passed, 0 failed`,
# rc 0, while PRINTING its own reduced numbers — corpus 302 -> 273, protected
# 30 -> 1. A floor of 1 was satisfied by the one suite left: this one.
#
# THE THIRD SOURCE IS THE POINT. Two enumerators agreeing is not verification
# when both read the same tree: measured, `git grep -l` returns 273 on that
# same reduced tree, agreeing with the loop and confirming nothing. Only data
# that does NOT move with the scan can arbitrate a shrinking population.
#
# FIVE ENTRANTS RECORDED at the your-org/nexus-code#989 merge seam. `#989`
# brings five new suites into the corpus, so the now-exact `#986` ratchet
# reddened `CORPUS SURPLUS: 348 enumerated, 343 pinned` — the ratchet WORKING,
# not a regression, and it named all five. All five classify `ledger=yes
# count=exact`, so they belong here rather than in the manifest; the guard's
# `_prot_extra` arm said so independently, in the same run.
#
#     monitor/test-obligations.sh
#     monitor/watcher/test-argloop-progress-guard.sh
#     monitor/watcher/test-helper-honesty.sh
#     monitor/watcher/test-ng-flag-order.sh
#     monitor/watcher/test-ng-usage-flag-coverage.sh
#
# ONE ENTRANT at the your-org/nexus-code#1513 seam (w239 D10):
# `test-trap-bare-return-lint.sh` is a NEW suite and enters fully protected
# (ledger=yes via `th_summary_and_exit`, count=exact via EXPECTED_ASSERTIONS),
# written in the protected form from the start. Mutation-tested per the rule
# below on both axes in a real worktree; measurements in the w239 report.
#
# ONE ENTRANT at the your-org/nexus-code#1490 seam:
# `test-tee-reopen-lint.sh` is a NEW suite and enters fully protected
# (ledger=yes via `th_summary_and_exit`, count=exact via EXPECTED_ASSERTIONS).
# It was written ledger-only and this guard classified it `count=none`;
# the correct response to that red was to RAISE the suite to the protected
# form rather than record it as unprotected — a lint whose own green cannot
# say how much it asserted is the shape its sibling manifest exists to name.
#
# EACH APPEND IS MUTATION-TESTED, because a row added to a pin is a claim that
# the pin would notice its loss, and an untested row is a claim nobody checked.
# Ten mutants, two per entrant, one per protection axis — axis A renames every
# `th_summary_and_exit` (ledger=yes -> no), axis B weakens the exact count
# comparison (count=exact -> floor, or -> none where the suite spells its guard
# `assert_eq`). Every one was proven APPLIED (`git diff --numstat` non-empty),
# proven to PARSE (`bash -n` clean, so no kill is a syntax error), and proven to
# MOVE THE AXIS (classifier driven directly before and after). All ten killed,
# and the kill text is the PROPERTY, never a count:
#
#     FAIL: PROTECTED suite(s) no longer classify ledger=yes count=exact …
#             monitor/test-obligations.sh
#     FAIL: suite(s) whose green is unrecorded at its current protection level:
#             monitor/test-obligations.sh::ledger=yes::count=none
#
# TWO ENTRANTS RECORDED at your-org/nexus-code#1071. Both are new suites for the
# `idle-orphan-async` wake loop and its status-preserving launcher; both were
# written `ledger=yes count=exact` from the start, so they belong here rather
# than in the manifest, and the guard's `_prot_extra` arm named them
# independently in the same run that reddened `CORPUS SURPLUS: 355 enumerated,
# 353 pinned`.
#
#     monitor/watcher/test-async-run.sh
#     monitor/watcher/test-orphan-async.sh
#
# Both appends were mutation-tested per the rule above — four mutants, two per
# entrant, one per protection axis. Axis A removes `th_summary_and_exit`
# (ledger=yes -> no); axis B weakens the exact `(( _ran == EXPECTED_ASSERTIONS ))`
# comparison to `>=` (count=exact -> floor). Each was proven APPLIED
# (`git diff --numstat` non-empty), proven to PARSE (`bash -n` clean, so no kill
# is a syntax error), and all four killed with the PROPERTY named:
#
#     FAIL: PROTECTED suite(s) no longer classify ledger=yes count=exact …
#             monitor/watcher/test-orphan-async.sh
#
# A FIFTH AND SIXTH MUTANT DID NOT KILL, recorded because they are the obvious
# way to write axis A and they are WRONG. Renaming the call to
# `th_summary_and_exit_RENAMED` — applied, parsing, diff non-empty — left BOTH
# suites classified `ledger=yes` and the guard green. `_ledger_axis` is a bare
# `grep -q th_summary_and_exit`, so a rename that keeps the string as a PREFIX
# does not move the axis at all: the mutant was a no-op on the property, not a
# survivor of it. The killing form removes the substring outright
# (`th_finish_and_exit`), which is what `substring 1->0` above is evidence of.
# This is the same lesson the `EXPECTED_ASSERTIONS` non-kill below records, hit
# from the other axis: a mutation that changes the FILE is not automatically a
# mutation that changes the PROPERTY, and only the second kind tests anything.
# Two mutations that did NOT kill are recorded because they are the ones a
# reader would otherwise write. Renaming `EXPECTED_ASSERTIONS` in
# `test-obligations.sh` moves nothing — `_count_axis` reads `exact` off the
# `assert_eq` PREFIX, not off the operand — so it is a NO-OP on the property
# and was reported as such rather than counted as a kill. And a first cut ran
# the whole battery in a TAR COPY of the tree: the guard enumerates the corpus
# with `git ls-files`, which answers nothing outside a repository, so the
# UNMUTATED baseline was already `27 passed, 4 failed` and every "kill" was the
# missing `.git`. The mutant tree must be a real worktree; measured 31/0 there.
# ONE ENTRANT RECORDED at your-org/nexus-code#1077. A new suite for the
# asset-upload root pinning and its terminal same-repo guard, written
# `ledger=yes count=exact` from the start, so it belongs here rather than in the
# manifest; the guard's `_prot_extra` arm named it independently in the same run
# that reddened `CORPUS SURPLUS: 357 enumerated, 356 pinned`.
#
#     monitor/watcher/test-upload-asset-root-pinning.sh
#
# Mutation-tested per the rule above — two mutants, one per protection axis, in
# a real worktree (not a tar copy: the guard enumerates with `git ls-files`).
# Axis A DELETES the `th_summary_and_exit` substring outright rather than
# renaming it, because `_ledger_axis` is a bare `grep -q` and a prefix-preserving
# rename is a no-op on the property, not a survivor of it. Axis B weakens the
# exact `(( _ran != EXPECTED_ASSERTIONS ))` comparison to `<`. Both proven
# APPLIED (`git diff --numstat` non-empty) and PARSING (`bash -n` clean), and
# both killed with the PROPERTY named. Measurements are in the #1077 report.
# ONE ENTRANT RECORDED at your-org/nexus-code#1085. A new suite pinning the
# provenance descriptor's `harness` field against a record the REAL producer
# wrote, on BOTH of `_write_provenance_record`'s writer arms. Written
# `ledger=yes count=exact` from the start, so it belongs here rather than in the
# manifest; the guard's `_prot_extra` arm named it independently in the same run
# that reddened `CORPUS SURPLUS: 360 enumerated, 359 pinned`.
#
#     monitor/watcher/test-provenance-harness-field.sh
#
# Mutation-tested per the rule above — two mutants, one per protection axis, in
# a real worktree at `4299e7e` (baseline there: 31 passed, 0 failed). Axis A
# REMOVES the `th_summary_and_exit` substring (`th_finish_and_exit`) rather than
# renaming it, per the prefix no-op lesson recorded above. Axis B weakens the
# exact `assert_eq … "$_run_total" "$EXPECTED_ASSERTIONS"` to a `-ge` floor.
# Both proven APPLIED (`git diff --numstat` = `1 1`) and PARSING (`bash -n`
# clean), and both killed with the PROPERTY named — axis B reported the level it
# fell to:
#
#     FAIL: suite(s) whose green is unrecorded at its current protection level:
#             monitor/watcher/test-provenance-harness-field.sh::ledger=yes::count=floor
#
# A THIRD NON-KILL IS RECORDED because it is how this suite's count guard was
# FIRST written and it silently opted the suite out. `_count_axis` classifies
# from PHYSICAL lines, so splitting the guard across a `\`-continuation —
#
#     assert_eq "assertion count is …" \
#         "$_run_total" "$EXPECTED_ASSERTIONS"
#
# — puts the `assert_eq` prefix on one line and `EXPECTED` on the next, and the
# suite reads `count=none` while looking exactly like every protected sibling.
# That is not a mutant that fails to kill; it is a formatting choice that
# removes the protection, which makes it the more dangerous of the two. The fix
# is the documented one-line shape, not a widened classifier.
# THREE ENTRANTS RECORDED at your-org/nexus-code#1158, #1150, #1157. Three new
# CLAUDE.md block-executing suites, written `ledger=yes count=exact` from the
# start, so they belong here rather than in the manifest:
#
#     monitor/watcher/test-claude-md-grep-bre-dialect.sh
#     monitor/watcher/test-claude-md-worktree-blind-spot.sh
#     monitor/watcher/test-claude-md-backtick-substitution.sh
#
# Mutation-tested per the rule above, and NOT only on the two protection axes:
# each suite's DOCUMENTED CLAUDE.md command was mutated too (9 mutants: repair
# the wrong form, delete a form, drop `command`, aim the positive control at a
# ghost, drop `--ignored`, weaken `comm -3` to `comm -12`, unquote the safe
# heredoc delimiter, make the `--file` remedy expand, remove the mode-2
# substitution). All 9 killed, and all 6 axis mutants killed. Baselines green.
#
# ONE SURVIVOR IS RECORDED BECAUSE IT IS A HOLE IN THIS FILE'S CLASSIFIER, NOT
# IN THE ENTRANT. Axis B initially SURVIVED against
# test-claude-md-backtick-substitution.sh: `_count_axis` collects every line
# carrying an expectation-ish and a count-ish token, and
#
#     [[ "$HAVE_ZSH" == "yes" ]] && EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS + 10 ))
#
# carries `EXPECTED`, `ASSERTION` *and* `==`. That is an ARITHMETIC BUMP, not a
# comparison of a total to an expectation — so the classifier returns `exact`
# from a line that guards nothing, and weakening the real guard to a floor
# leaves the manifest green over an unprotected suite. Same family as the
# `UNEXPECTEDLY` false positive this classifier was rebuilt to remove, on a
# different string, and it OVER-reports protection, which the header above
# names as the dangerous direction.
#
# The entrant was written with `=` instead of `==` (with a comment saying why,
# so nobody normalises it back) and the mutant then killed. The classifier
# itself is NOT changed here — widening or narrowing it is the change that
# produced the original false positives, and it needs its own issue.
#
# THAT ISSUE WAS your-org/nexus-code#1167 AND IT IS NOW FIXED ABOVE, by keying
# the operator arms on the comparison's OPERANDS rather than on co-occurrence.
# Both nominal credits named in the paragraphs above are now real:
# test-claude-md-zsh-path-tie.sh keeps `count=exact` off its actual
# `assert_eq … "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"`, and the axis-B
# mutant against it now KILLS. The `=`/`==` workaround #1165 adopted is no
# longer load-bearing — a §1 control now pins that the two spellings agree.
#
# ONE PROTECTED ENTRY LOST ITS CREDIT TO THE FIX, and it is recorded rather
# than patched around. `monitor/watcher/test-assertion-accounting.sh` was
# `count=exact` on the strength of the substring `-eq` inside the FIXTURE NAME
# `pass-eq-caps` — a second live instance of this class, of a different
# sub-shape, and one #1167 did not name (it audited none of the other PROTECTED
# entries and said so). Its REAL guard exists —
# `assert_eq … "${got_total:-<none>}" "$want_total"` — and is invisible to this
# classifier for two independent reasons BOTH already documented above: it is
# split across a `\`-continuation, and its operands are outside the recognised
# vocabulary. So `count=none` is the honest reading in the under-crediting
# direction this file promises, and the row now says so.
#
# This is NOT the "delete it from PROTECTED to go green" motion the failure
# message forbids. That prohibition is about recording a real LOSS as progress.
# Nothing was lost here: the suite's protection is exactly what it was
# yesterday, and what changed is that this file stopped mis-stating it. The
# remedy is the documented one-liner IN THAT SUITE — put the guard on one
# physical line and name its operands from the vocabulary — which is
# deliberately NOT taken here because that file is outside this bundle's scope
# and a parallel branch may own it. Reported instead, exactly as the scope rule
# requires, and the closing ratchet will demand the row's removal the moment
# the suite is fixed.
#
# THE SAME HOLE IS PRE-EXISTING AND LIVE IN THIS LIST. Measured on this branch:
# applying the identical axis-B mutant to monitor/watcher/test-claude-md-zsh-path-tie.sh
# — already PROTECTED, and carrying the identical `==` line — leaves this suite
# at rc 0. Its `count=exact` credit is therefore NOMINAL. Reported rather than
# silently patched, because a one-character fix to another entry's suite inside
# this PR would be exactly the unrecorded scope creep this file exists to catch.
# ONE ENTRANT RECORDED at your-org/nexus-code#1305. A new guard for the
# REDIRECTION-ORDER class — a `/proc/<expansion>` target read before the
# `2>/dev/null` meant to silence it. Written `ledger=yes count=exact` from the
# start rather than appended to the manifest, because this file's own header
# says appending is opting your new code out of the standard, and a guard whose
# green is unbacked would be its own subject matter.
#
#     monitor/watcher/test-proc-redirect-order.sh
#
# Mutation-tested per the rule above, two mutants, one per axis, both proven
# APPLIED and PARSING (`bash -n` clean, so no kill is a syntax error) and both
# proven to MOVE THE AXIS by driving the classifier directly:
#   axis A — `th_summary_and_exit` DELETED (not renamed: `_ledger_axis` is a
#            bare `grep -q`, so a prefix-preserving rename is a no-op on the
#            property rather than a survivor of it). Classifier moved
#            `ledger=yes` -> `ledger=no`; KILLED, naming the property:
#              FAIL: suite(s) whose green is unrecorded at its current
#                    protection level:
#                      monitor/watcher/test-proc-redirect-order.sh::ledger=no::count=exact
#   axis B — the exact `(( _ran == _EXPECTED_ASSERTIONS ))` weakened to `>=`.
#            Classifier moved `count=exact` -> `count=floor`; KILLED on the
#            same arm, naming `::ledger=yes::count=floor`.
# ONE ENTRANT RECORDED at your-org/nexus-code#1319. A new suite asserting that
# `_tmux-fixture.sh`'s answers are a property of the CODE and not of the
# invoking SHELL — the existing gate3 Part C assertion is single-interpreter,
# so it was green throughout the whole life of the defect. Written
# `ledger=yes count=exact` from the start.
#
#     monitor/watcher/test-tmux-fixture-shell-parity.sh
#
# Mutation-tested per the rule above, two mutants, one per axis, both proven
# APPLIED and PARSING, and both proven to MOVE THE AXIS:
#   axis A — `th_summary_and_exit` DELETED; `ledger=yes` -> `ledger=no`; KILLED
#            on the unrecorded-protection arm, naming
#            `::ledger=no::count=exact`.
#   axis B — the exact `==` count comparison weakened to `>=`;
#            `count=exact` -> `count=floor`; KILLED on the same arm.
#
# NOTE ON ITS SKIP ARM, because it bears on what the row claims. This suite
# exits 77 SKIP on a host with no zsh — the parity claim is not checkable with
# one shell, and a PASS there would be a green that measured nothing. A SKIP is
# not a green, so the row asserts the protection MECHANISMS are present, which
# is what this file classifies; it does not assert the suite runs everywhere.
# ONE ENTRANT RECORDED at your-org/nexus-code#1476. A new suite that DERIVES
# the "code default off, shipped template on" phrase from the two live values
# and requires it in five docs. Written `ledger=yes count=exact` from the start:
#
#     monitor/watcher/test-cc-auto-update-default-docs.sh
#
# Mutation-tested per the rule above, two mutants, one per axis, both proven
# APPLIED and PARSING, and both proven to MOVE THE AXIS on a copy of the tree:
#   axis A — `th_summary_and_exit` DELETED; `ledger=yes` -> `ledger=no`; KILLED
#            on the unrecorded-protection arm, naming `::ledger=no::count=exact`.
#   axis B — the exact `==` count comparison weakened to `>=`; the classifier
#            moved `count=exact` -> `count=none` (measured — NOT the
#            `count=floor` the entrants above report for this mutant); KILLED
#            on the same arm, naming `::ledger=yes::count=none`.
# ONE ENTRANT RECORDED at your-org/nexus-code#1512. A new suite pinning the
# report schema's `disposition:` annotation to `ng wrap-up`'s refusal, with a
# positive control on the tool. Written `ledger=yes count=exact` from the start:
#
#     monitor/watcher/test-report-schema-disposition-doc.sh
#
# Mutation-tested per the rule above, two mutants, one per axis, both proven
# APPLIED and PARSING, and both proven to MOVE THE AXIS on a copy of the tree:
#   axis A — `th_summary_and_exit` DELETED; `ledger=yes` -> `ledger=no`; KILLED
#            on the unrecorded-protection arm, naming `::ledger=no::count=exact`.
#   axis B — the exact `==` count comparison weakened to `>=`; the classifier
#            moved `count=exact` -> `count=none` (measured — NOT the
#            `count=floor` the entrants above report for this mutant); KILLED
#            on the same arm, naming `::ledger=yes::count=none`.
# ONE ENTRANT RECORDED at the w234 restart-boundary change (your-org/nexus-code
# #1513). A new suite for `bg_quiesce` and the cc-update restart's turn-boundary
# gate, written `ledger=yes count=exact` from the start, so it belongs here
# rather than in the manifest; the guard reddened `CORPUS SURPLUS: 471
# enumerated, 470 pinned` and named it on the unrecorded-protection arm as
# `::ledger=yes::count=none` before the census was added.
#
#     monitor/watcher/test-pane-state-restart-quiescence.sh
#
# Mutation-tested per the rule above: two mutants, one per axis, in a real
# worktree at `ead36327` (baseline there: 43 passed, 0 failed). Both were proven
# APPLIED (`git diff --numstat` = `1 1`) and PARSING (`bash -n` clean), and both
# were killed with the PROPERTY named:
#   axis A — the trailing `th_summary_and_exit` REPLACED by `exit 0`;
#            KILLED, 41 passed 2 failed, naming `::ledger=no::count=exact`.
#   axis B — the exact `==` census comparison weakened to `-ge`;
#            KILLED, 41 passed 2 failed, naming `::ledger=yes::count=floor`.
PROTECTED='monitor/cc-harness/test-cc-harness-gate-coverage-trackedness.sh
monitor/test-obligations.sh
monitor/test-window-key.sh
monitor/watcher/test-absent-evidence-precedence.sh
monitor/watcher/test-agent-delivery-latency-envelope.sh
monitor/watcher/test-agent-delivery.sh
monitor/watcher/test-argloop-progress-guard.sh
monitor/watcher/test-assert-bot-author-generic-optin.sh
monitor/watcher/test-assertion-ledger.sh
monitor/watcher/test-async-launch-detect.sh
monitor/watcher/test-async-run-await.sh
monitor/watcher/test-async-run-cancel.sh
monitor/watcher/test-async-run.sh
monitor/watcher/test-auth-hold.sh
monitor/watcher/test-awk-v-escape-lint.sh
monitor/watcher/test-backtick-label-lint.sh
monitor/watcher/test-cc-auto-update-default-docs.sh
monitor/watcher/test-cc-harness-gate-population.sh
monitor/watcher/test-cc-harness-socket-isolation.sh
monitor/watcher/test-cc-surface-dedup.sh
monitor/watcher/test-cc-update-no-remote-code.sh
monitor/watcher/test-changelog-merge-union.sh
monitor/watcher/test-ci-band-coverage.sh
monitor/watcher/test-claude-md-ancestor-timeline.sh
monitor/watcher/test-claude-md-arm-order-shadowing.sh
monitor/watcher/test-claude-md-backtick-substitution.sh
monitor/watcher/test-claude-md-count-provenance.sh
monitor/watcher/test-claude-md-count-vs-list.sh
monitor/watcher/test-claude-md-dash-pattern-option.sh
monitor/watcher/test-claude-md-entry-budget.sh
monitor/watcher/test-claude-md-fromisoformat.sh
monitor/watcher/test-claude-md-grep-bre-dialect.sh
monitor/watcher/test-claude-md-grep-h-order.sh
monitor/watcher/test-claude-md-guards-for-diff.sh
monitor/watcher/test-claude-md-marker-ownership.sh
monitor/watcher/test-claude-md-merge-enumeration.sh
monitor/watcher/test-claude-md-nullcmd-redirect.sh
monitor/watcher/test-claude-md-pane-state-vocabulary.sh
monitor/watcher/test-claude-md-pathspec-glob-depth.sh
monitor/watcher/test-claude-md-pipeline-status.sh
monitor/watcher/test-claude-md-population-enrolment.sh
monitor/watcher/test-claude-md-printf-status-clobber.sh
monitor/watcher/test-claude-md-procmatch-argv.sh
monitor/watcher/test-claude-md-python-backref-escape.sh
monitor/watcher/test-claude-md-repo-walkup.sh
monitor/watcher/test-claude-md-shell-wrapped-coreutil.sh
monitor/watcher/test-claude-md-shopt-dynamic-scope.sh
monitor/watcher/test-claude-md-worktree-blind-spot.sh
monitor/watcher/test-claude-md-zsh-path-tie.sh
monitor/watcher/test-declare-no-wait.sh
monitor/watcher/test-delivery-resolvers-primary-root.sh
monitor/watcher/test-early-exit-pipefail-axis.sh
monitor/watcher/test-emit-partial-honesty.sh
monitor/watcher/test-empty-needle-local-copies.sh
monitor/watcher/test-empty-needle-production.sh
monitor/watcher/test-empty-needle-vacuous-helpers.sh
monitor/watcher/test-ensure-workdir-trusted-backfill.sh
monitor/watcher/test-errexit-assignment-status.sh
monitor/watcher/test-fixture-port-lint.sh
monitor/watcher/test-fixture-reap-ownership.sh
monitor/watcher/test-fixture-state-isolation.sh
monitor/watcher/test-force-push-check-credential-redaction.sh
monitor/watcher/test-force-push-check.sh
monitor/watcher/test-force-push-over-report-caveat.sh
monitor/watcher/test-fs-evidence-df-status.sh
monitor/watcher/test-gh-stub-contract.sh
monitor/watcher/test-gh-write-guard.sh
monitor/watcher/test-grep-delegation-arms.sh
monitor/watcher/test-guard-positive-controls.sh
monitor/watcher/test-helper-honesty.sh
monitor/watcher/test-hook-matcher-body-coherence.sh
monitor/watcher/test-idle-wrapup-scan-scope.sh
monitor/watcher/test-input-box-chrome.sh
monitor/watcher/test-integration/test-realmodel-trust-dialog.sh
monitor/watcher/test-integration/test-realmodel-trust-sandboxed-env.sh
monitor/watcher/test-issue-ref.sh
monitor/watcher/test-knob-default-agrees.sh
monitor/watcher/test-merge-ref-base.sh
monitor/watcher/test-mutation-gate-bounds.sh
monitor/watcher/test-mutation-gate-did-not-run.sh
monitor/watcher/test-nexus-client-port-derivation.sh
monitor/watcher/test-ng-flag-order.sh
monitor/watcher/test-ng-identity-dashboard-sync.sh
monitor/watcher/test-ng-reply-arg-binding.sh
monitor/watcher/test-ng-skeptic-orphans.sh
monitor/watcher/test-ng-usage-flag-coverage.sh
monitor/watcher/test-nrs-population.sh
monitor/watcher/test-nullglob-bare-form-manifest.sh
monitor/watcher/test-operator-path-literals-manifest.sh
monitor/watcher/test-orphan-async-resolve-vocabulary.sh
monitor/watcher/test-orphan-async-terminate.sh
monitor/watcher/test-orphan-async.sh
monitor/watcher/test-over-limit-config-bridge.sh
monitor/watcher/test-over-limit-orchestrator-activity.sh
monitor/watcher/test-over-limit-stale-stamp.sh
monitor/watcher/test-pane-state-asyncrun-liveness.sh
monitor/watcher/test-pane-state-claude-identity.sh
monitor/watcher/test-pane-state-resolver-precondition.sh
monitor/watcher/test-pane-state-restart-quiescence.sh
monitor/watcher/test-pane-state-wrapped-idle.sh
monitor/watcher/test-paste-dead-pane-guard-arms.sh
monitor/watcher/test-paste-followup-receipt-and-usage.sh
monitor/watcher/test-proc-exists-authorized.sh
monitor/watcher/test-proc-kill-authorized.sh
monitor/watcher/test-proc-redirect-order.sh
monitor/watcher/test-provenance-harness-field.sh
monitor/watcher/test-public-mirror-build-entry-guard.sh
monitor/watcher/test-public-mirror-dictionary-coverage.sh
monitor/watcher/test-public-mirror-overlay-drift.sh
monitor/watcher/test-public-mirror-symlink-target.sh
monitor/watcher/test-public-mirror-sync-base.sh
monitor/watcher/test-recover-pidfile-sync.sh
monitor/watcher/test-registry-unreadable-refusal.sh
monitor/watcher/test-remote-client-helper.sh
monitor/watcher/test-remote-from-pin-runtime.sh
monitor/watcher/test-remote-instrument-potency.sh
monitor/watcher/test-remote-permanent-failure.sh
monitor/watcher/test-remote-port-collision-toctou.sh
monitor/watcher/test-remote-posture-change.sh
monitor/watcher/test-repo-root-provenance.sh
monitor/watcher/test-report-schema-disposition-doc.sh
monitor/watcher/test-report-window-key.sh
monitor/watcher/test-request-filed-by.sh
monitor/watcher/test-request-reply-skeptic-ledger.sh
monitor/watcher/test-request-state-field.sh
monitor/watcher/test-requests-emit-handling.sh
monitor/watcher/test-retire-preflight-audit-scope.sh
monitor/watcher/test-run-tests-accounting-verdict.sh
monitor/watcher/test-run-tests-empty-outfile.sh
monitor/watcher/test-run-tests-false-pass.sh
monitor/watcher/test-run-tests-header-ref.sh
monitor/watcher/test-self-fix-tracker-search.sh
monitor/watcher/test-send-check-last.sh
monitor/watcher/test-send-check-queued-receipt.sh
monitor/watcher/test-send-ledger-primary.sh
monitor/watcher/test-service-health-selfmatch.sh
monitor/watcher/test-service-root-guard.sh
monitor/watcher/test-session-name-from-window.sh
monitor/watcher/test-skeptic-answer-body-fidelity.sh
monitor/watcher/test-skeptic-arm-recording.sh
monitor/watcher/test-skeptic-evidence-class-agreement.sh
monitor/watcher/test-skeptic-self-spawn.sh
monitor/watcher/test-skeptic-spawn-origin-key.sh
monitor/watcher/test-skeptic-verdict-evidence.sh
monitor/watcher/test-skills-catalog.sh
monitor/watcher/test-slow-band-envskip.sh
monitor/watcher/test-spawn-guard-fail-closed.sh
monitor/watcher/test-spawn-worker-state-dir.sh
monitor/watcher/test-spawn-worker-trust-verify.sh
monitor/watcher/test-stamp-clear-splitbrain.sh
monitor/watcher/test-state-dir-propagation.sh
monitor/watcher/test-strip-heredocs.sh
monitor/watcher/test-stub-claude-classifier-sigpipe.sh
monitor/watcher/test-subshell-exit-guards.sh
monitor/watcher/test-suite-declaration-census.sh
monitor/watcher/test-summary-honesty-manifest.sh
monitor/watcher/test-svc-orphans.sh
monitor/watcher/test-tee-reopen-lint.sh
monitor/watcher/test-th-require-fixture-repo.sh
monitor/watcher/test-tmpfs-guard.sh
monitor/watcher/test-tmux-fixture-shell-parity.sh
monitor/watcher/test-tmux-selection-restore.sh
monitor/watcher/test-tmux-shim-gate3-safety.sh
monitor/watcher/test-tmux-shim.sh
monitor/watcher/test-tmux-socket-ceiling.sh
monitor/watcher/test-tmuxwrap-lint-conformance.sh
monitor/watcher/test-trap-bare-return-lint.sh
monitor/watcher/test-trust-config-clobber-mechanism.sh
monitor/watcher/test-uncounted-abort-lint.sh
monitor/watcher/test-upload-asset-positional.sh
monitor/watcher/test-upload-asset-root-pinning.sh
monitor/watcher/test-v2-task-rc-propagation.sh
monitor/watcher/test-verify-worker-started.sh'

_corpus_verdict() {   # <scanned> <indep> <pinned> -> rc 0 sound, rc 1 + reason
    local scanned="$1" indep="$2" pinned="$3"
    if (( scanned != indep )); then
        printf 'ENUMERATOR DISAGREEMENT: this scan read %d file(s); an independent\n' "$scanned"
        printf '  enumerator saw %d. One of the two is blind, so every classification\n' "$indep"
        printf '  below describes a population that was never fully read.\n'
        return 1
    fi
    if (( scanned < pinned )); then
        printf 'CORPUS DEFICIT: %d file(s) enumerated, %d pinned on record (%d missing).\n' \
            "$scanned" "$pinned" "$(( pinned - scanned ))"
        printf '  This is a BLIND SCAN, not a smaller corpus. Do NOT delete manifest\n'
        printf '  lines or PROTECTED entries to make the ratchet green again — that\n'
        printf '  records the blindness as progress, which is your-org/nexus-code#839.\n'
        return 1
    fi
    if (( scanned > pinned )); then
        printf 'CORPUS SURPLUS: %d file(s) enumerated, %d pinned on record. %d suite(s)\n' \
            "$scanned" "$pinned" "$(( scanned - pinned ))"
        printf '  entered the corpus without being recorded on either list. Classify\n'
        printf '  each and record it deliberately; the ratchet below names them.\n'
        return 1
    fi
    return 0
}

# ── §1c SELECTOR PREDICATE CONTROLS (your-org/nexus-code#864, #915) ─────
# `_SELECTOR_DESC` is PROSE describing the predicate, and prose cannot be made
# to fail — the two can drift, and a boundary sentence that no longer
# describes the code is worse than none, because it is believed. `#915` is
# what that costs: the sentence was honest, but the FUNCTION NAME asserted a
# property the code did not test, and a reader trusts an author who described
# the boundary so precisely.
#
# So the predicate is driven directly, in both directions. Note what these
# controls can now express that the previous ones could not: a file whose
# footer is a HAND-ROLLED TALLY is IN. Under `#864` it was silently out, and
# no assertion here said so.
printf '%s\n' '#!/usr/bin/env bash' 'echo "ALL TESTS PASSED"'          > "$PLANT/s-literal.sh"
printf '%s\n' '#!/usr/bin/env bash' 'th_summary_and_exit'              > "$PLANT/s-helper.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "passed=$P failed=$F"'       > "$PLANT/s-tally.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo hi'                          > "$PLANT/s-neither.sh"

_is_non_suite "$PLANT/s-literal.sh"; _sel_rc=$?
assert_eq "SELECTOR: a banner suite is IN the population" "$_sel_rc" "1"
_is_non_suite "$PLANT/s-helper.sh"; _sel_rc=$?
assert_eq "SELECTOR: a th_summary_and_exit suite is IN the population (#864)" "$_sel_rc" "1"
_is_non_suite "$PLANT/s-tally.sh"; _sel_rc=$?
assert_eq "SELECTOR: a HAND-ROLLED TALLY suite is IN the population (#915)" "$_sel_rc" "1"
_is_non_suite "$PLANT/s-neither.sh"; _sel_rc=$?
assert_eq "SELECTOR: a file announcing nothing is still IN — only a DECLARED non-suite is out (#915)" "$_sel_rc" "1"
_is_non_suite 'monitor/watcher/test-integration/_harness.sh'; _sel_rc=$?
assert_eq "SELECTOR: a DECLARED non-suite is the only way out" "$_sel_rc" "0"

# The declaration list must describe the tree. A stale entry is a suite
# silently exempted — the same escape the proxy used to grant by accident.
_ns_missing=""
for _p in "${_NON_SUITE_PATHS[@]}"; do
    [[ -f "$REPO_ROOT/$_p" ]] || _ns_missing+="$_p "
done
assert_eq "SELECTOR: every declared non-suite still exists (no stale exemption)" "${_ns_missing:-none}" "none"
assert_eq "SELECTOR: every declared non-suite carries a reason" \
    "${#_NON_SUITE_PATHS[@]}" "${#_NON_SUITE_WHY[@]}"

# ── §1d _corpus_verdict FAILING-ARM CONTROLS (your-org/nexus-code#839) ──
# The verdict function is what replaced two floors, so every arm of it is
# driven here with planted counts. A guard whose failing arms are never
# executed is a guard that has only been shown to say yes.
_cv() { _corpus_verdict "$1" "$2" "$3" >/dev/null 2>&1; printf '%s' "$?"; }
assert_eq "CORPUS: scan == indep == pinned is sound" "$(_cv 302 302 302)" "0"
assert_eq "CORPUS: a DEFICIT (blind scan) is refused" "$(_cv 273 273 302)" "1"
assert_eq "CORPUS: a SURPLUS (unrecorded entrant) is refused" "$(_cv 303 303 302)" "1"
assert_eq "CORPUS: enumerators DISAGREEING is refused" "$(_cv 273 302 302)" "1"
assert_contains "CORPUS: the deficit reason names the missing count" \
    "$(_corpus_verdict 273 273 302 2>&1)" "29 missing"

cd "$REPO_ROOT" || { echo "FAIL: cd repo root"; exit 1; }

n_cand=0 n_files=0 n_full=0
actual=""
full_actual=""
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    n_cand=$(( n_cand + 1 ))
    _is_non_suite "$f" && continue
    n_files=$(( n_files + 1 ))
    a=$(_ledger_axis "$f"); b=$(_count_axis "$f")
    if [[ "$a" == yes && "$b" == exact ]]; then
        n_full=$(( n_full + 1 ))
        full_actual+="$f"$'\n'
    else
        actual+="$f::ledger=$a::count=$b"$'\n'
    fi
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

# ── THE SELECTOR DECLARES ITS OWN BOUNDARY (#864) ───────────────────────
# A coverage number that names only what it MATCHED is unfalsifiable: 258 and
# 283 read identically when you cannot see the denominator. So report the
# candidate set, the predicate that narrowed it, and what fell outside.
#
# "EXAMINED NOTHING" AND "SELECTED NOTHING" ARE DIFFERENT FAILURES and a
# single count cannot tell them apart — one means the enumerator broke, the
# other means the predicate stopped matching, and they are repaired in
# opposite places. Both are fatal here. A GUARD THAT EXAMINED NOTHING MUST NOT
# EXIT 0; this is checked BEFORE any population comparison below, because with
# an empty scan every downstream set comparison is vacuously satisfiable.
if (( n_cand == 0 )); then
    _th_fail
    printf '  FAIL: SELECTOR EXAMINED NOTHING — 0 candidate files (%s).\n' "$_CANDIDATE_DESC" >&2
    printf '        The ENUMERATOR is blind, not the predicate. Nothing below\n' >&2
    printf '        describes this repository. See #770 (ls-tree glob) and #618.\n' >&2
elif (( n_files == 0 )); then
    _th_fail
    printf '  FAIL: SELECTOR MATCHED NOTHING — %d candidate(s) examined, 0 in population.\n' "$n_cand" >&2
    printf '        The PREDICATE excluded everything, not the enumerator — i.e. the\n' >&2
    printf '        non-suite declaration list has swallowed the corpus. Predicate:\n' >&2
    printf '        %s\n' "$_SELECTOR_DESC" >&2
else
    _th_pass
    printf '  PASS: selector boundary declared — %d candidate(s) examined (%s), %d in population, %d declared non-suite(s)\n' \
        "$n_cand" "$_CANDIDATE_DESC" "$n_files" "$(( n_cand - n_files ))"
    printf '        predicate: %s\n' "$_SELECTOR_DESC"
    # ITEMISE THE RESIDUE (#915). A count with no identification is a
    # completeness claim it cannot support: `19 outside` reads as "19 things
    # that did not need examining" when 17 of them were unguarded suites.
    # Naming them makes the exemption reviewable and keeps the number from
    # ageing into folklore.
    _i=0
    while (( _i < ${#_NON_SUITE_PATHS[@]} )); do
        printf '        NOT A SUITE: %s — %s\n' "${_NON_SUITE_PATHS[$_i]}" "${_NON_SUITE_WHY[$_i]}"
        _i=$(( _i + 1 ))
    done
fi

# A population this scan could not have enumerated makes every result below
# meaningless — the silent-zero class this repo keeps re-learning. This used to
# be a FLOOR (`n_files >= 200`); it is now an EXACT comparison against pinned
# data, because a floor cannot tell a smaller corpus from a blind scan.
#
# BUNDLE SEAM (#839 + #915). `#839` introduced this independent enumerator as
#
#     git grep -l -e 'ALL TESTS PASSED' -e 'th_summary_and_exit' -- '*test-*.sh'
#
# — i.e. it counted the population USING THE VERY TWO-STRING PROXY `#915`
# abolishes. Merged naively the two are not merely redundant, they CONTRADICT:
# measured on this tree the scan reads 319 and that proxy reads 302, and the
# guard reddens with `ENUMERATOR DISAGREEMENT` on a repository where nothing is
# wrong. Re-pinning `#839`'s comparison to the proxy's answer would have been
# the tempting green, and it would have reinstated `#915`'s defect inside
# `#839`'s check: the 17 hand-rolled-tally suites would be back outside the
# only number the corpus verdict compares.
#
# So the independent enumerator now selects by `#915`'s PROPERTY — every
# tracked `*test-*.sh` that is not a DECLARED non-suite — while staying a
# genuinely different MECHANISM from the scan above. The scan trusts git's
# pathspec engine to narrow the index; this enumerates the index UNNARROWED and
# applies the name test in the shell. That is deliberately aimed at the failure
# §2 already cites as its reason for preferring `ls-files` over `ls-tree`: a
# glob pathspec returning a confident zero (#770). A pathspec that silently
# stopped matching moves the scan and leaves this count where it was.
#
# What it is NOT is the arbiter of a SHRINKING corpus — both figures read the
# same tree and move together, exactly as the PROTECTED comment above says.
# `n_pinned` is the third source, and it is the one that does not move.
n_indep=0
while IFS= read -r _if; do
    [[ "$_if" == *test-*.sh ]] || continue
    _is_non_suite "$_if" && continue
    n_indep=$(( n_indep + 1 ))
done < <(git ls-files | sort -u)
n_protected_pinned=$(printf '%s\n' "$PROTECTED" | grep -c .)
n_manifest_pinned=$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | awk -F'::' '{print $1}' | sort -u | grep -c .)
n_pinned=$(( n_protected_pinned + n_manifest_pinned ))
if _corpus_reason=$(_corpus_verdict "$n_files" "$n_indep" "$n_pinned"); then
    _th_pass
    printf '  PASS: corpus sound — scan %d, independent %d, pinned %d (%d protected + %d manifest)\n' \
        "$n_files" "$n_indep" "$n_pinned" "$n_protected_pinned" "$n_manifest_pinned"
else
    _th_fail
    printf '  FAIL: %s' "$_corpus_reason" >&2
fi

# The fully-protected set is pinned BOTH WAYS by name. The old check here was
# `n_full >= 1 && n_files - n_full >= 100` — satisfied by ONE surviving suite,
# which on this file is itself. Names, not counts: a count cannot say WHICH
# suite stopped being protected, and that is the sentence a reader needs.
_prot_expected=$(printf '%s\n' "$PROTECTED" | grep . | sort -u)
_prot_actual=$(printf '%s' "$full_actual" | grep . | sort -u || true)
_prot_missing=$(comm -23 <(printf '%s\n' "$_prot_expected") <(printf '%s\n' "$_prot_actual"))
_prot_extra=$(comm -13 <(printf '%s\n' "$_prot_expected") <(printf '%s\n' "$_prot_actual"))
if [[ -z "$_prot_missing" ]]; then
    _th_pass
    printf '  PASS: every PROTECTED suite still classifies ledger=yes count=exact (%d)\n' "$n_protected_pinned"
else
    _th_fail
    printf '  FAIL: PROTECTED suite(s) no longer classify ledger=yes count=exact, or are GONE:\n' >&2
    printf '%s\n' "$_prot_missing" | sed 's/^/          /' >&2
    printf '        Do NOT delete them from PROTECTED to go green — that records the\n' >&2
    printf '        loss as progress, which is your-org/nexus-code#839 itself.\n' >&2
fi
if [[ -z "$_prot_extra" ]]; then
    _th_pass
    printf '  PASS: no suite became fully protected without being recorded\n'
else
    _th_fail
    printf '  FAIL: suite(s) are fully protected but absent from PROTECTED — record them:\n' >&2
    printf '%s\n' "$_prot_extra" | sed 's/^/          /' >&2
fi

expected=$(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | sort -u)
actual=$(printf '%s' "$actual" | grep -v '^$' | sort -u || true)

# ── §3 THE RATCHET ──────────────────────────────────────────────────────
# Forward: a banner-printing file that is not fully protected and not recorded.
# This catches both a NEW unguarded suite and a file whose protection WEAKENED
# (its old record no longer matches, so the new state reads as unrecorded).
new=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
if [[ -z "$new" ]]; then
    _th_pass
    printf '  PASS: no new or weakened unprotected suite (%d on record)\n' \
        "$(printf '%s\n' "$expected" | grep -c .)"
else
    _th_fail
    printf '  FAIL: suite(s) whose green is unrecorded at its current protection level:\n' >&2
    printf '%s\n' "$new" | sed 's/^/         /' >&2
    printf '        `ledger=yes` needs `th_summary_and_exit`; `count=exact` needs a\n' >&2
    printf '        comparison of the assertion total against an expected total. A suite\n' >&2
    printf '        built on DELIBERATE failing assertions can adopt the ledger with\n' >&2
    printf '        th_expect_fail (see its header) instead of staying opted out.\n' >&2
    printf '        If YOU are adding the suite: do NOT append a line — that opts your own\n' >&2
    printf '        new code out of the standard. If it ARRIVED BY MERGE from another\n' >&2
    printf '        change: record it, note where it came from, and let its author raise it.\n' >&2
fi

# Closing: a file that gained protection, or was deleted, must leave the list.
gone=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
if [[ -z "$gone" ]]; then
    _th_pass
    echo "  PASS: no stale manifest entries"
else
    _th_fail
    printf '  FAIL: recorded state no longer matches the tree — delete these lines:\n' >&2
    printf '%s\n' "$gone" | sed 's/^/         /' >&2
    printf '        (a suite improved, or was removed. Good — but the list must shrink\n' >&2
    printf '        with it, or it stops measuring anything.)\n' >&2
fi

# ── §4 THE FLOOR IS NOT PROTECTION ──────────────────────────────────────
# The `#819` skeptic proved this synthetically and it is the reason the `floor`
# bucket exists rather than being folded into `exact`. Proved again here, live,
# so the claim is not carried by prose: a suite that clears its floor while
# LOSING a failing assertion in a subshell still announces a pass.
cat >"$PLANT/floor-blind.sh" <<'FLOORCTL'
#!/usr/bin/env bash
PASS=0; FAIL=0
assert_eq() { if [[ "$2" == "$3" ]]; then PASS=$(( PASS + 1 )); else FAIL=$(( FAIL + 1 )); fi; }
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do assert_eq "ok$i" 1 1; done
_lost=$(assert_eq "a REAL failure, in a subshell" 1 2)
_total=$(( PASS + FAIL ))
EXPECTED_MIN=10
[[ $_total -lt $EXPECTED_MIN ]] && { echo "FLOOR NOT MET" >&2; exit 1; }
(( FAIL == 0 )) && { echo "ALL TESTS PASSED ($_total assertions)"; exit 0; }
exit 1
FLOORCTL
floor_out=$(bash "$PLANT/floor-blind.sh" 2>&1); floor_rc=$?
assert_eq "a FLOOR-guarded suite exits 0 despite a subshell-lost FAILURE" "$floor_rc" "0"
assert_contains "…announcing a pass, floor cleared, failure invisible" \
    "$floor_out" "ALL TESTS PASSED"

# EXPECTED-COUNT GUARD (#807) — this suite practises what it records.
# The total is captured BEFORE the guard counts its own failure. Reporting
# `$(( PASS + FAIL ))` after `_th_fail` overstates the run by one and sends the
# next reader hunting for an assertion that never existed — which is how the
# first draft of this guard reported "17 ran" for a 16-assertion suite.
# BUNDLE SEAM (#839 + #915): the two sides raised this independently and their
# additions are DISJOINT — `#839` added 6 (the five `CORPUS:` controls plus the
# verdict call that replaced two floors with one comparison), `#915` added 4
# (three SELECTOR controls became seven). 21 + 6 + 4 = 31, predicted before the
# merged suite was run and then confirmed by it — not read off the run.
EXPECTED=43   # +3: #1365 count=subset (two plants, one real-file instance)
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    # ANNOUNCE, THEN COUNT — the order `uncounted-abort-lint.sh` requires, since
    # it scans FORWARD from an announcement for a counting disposition.
    #
    # The second half of this comment used to say "and keep the summary
    # function's name out of the message", because naming it made the lint read
    # this path as reaching the summary uncounted. That was a false positive,
    # fixed in your-org/nexus-code#838 — the lint now distinguishes NAMING a
    # symbol from CALLING it. The workaround is gone rather than left in place:
    # a stale workaround comment is how a false positive becomes folklore, with
    # the next author copying it without knowing why.
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
