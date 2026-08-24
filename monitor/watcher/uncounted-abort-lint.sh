#!/usr/bin/env bash
# uncounted-abort-lint.sh — flag an outcome that is ANNOUNCED but not COUNTED
# before the summary reads the counters (your-org/nexus-code#783).
#
# Usage:  bash monitor/watcher/uncounted-abort-lint.sh [<repo-root>]
#   prints one `<file>:<line>\t<text>` row per site; exit 1 if any, 0 if none.
#
# ---------------------------------------------------------------------------
# THE DEFECT
#
# `th_summary_and_exit` prints PASS/FAIL **from the counters** and exits 0 when
# `FAIL` is 0. So an abort path that ECHOES a failure without INCREMENTING it:
#
#     [[ "$win" =~ ^[0-9]+$ ]] || {
#         echo "  FAIL: spawn returned non-numeric window index: $win" >&2
#         th_summary_and_exit
#     }
#
# emits its `FAIL:` line, then `=== summary: 4 passed, 0 failed ===`, then
# `ALL TESTS PASSED`, and exits **0**. A scenario that aborted half-way
# announces an unqualified pass.
#
# Measured on `dev`@`16728e7`, before the fix — 4 passing assertions, an
# echoed abort, rc 0:
#
#     FAIL: phase B spawn returned non-numeric window index:
#     === summary: 4 passed, 0 failed ===
#     ALL TESTS PASSED                                    RC=0
#
# Not hypothetical. `test-graceful-exit-relaunch.sh` phase B was entirely dead
# AND GREEN for as long as the harness lacked `monitor/_claude-bin.sh` (#764):
# the launcher died at its `source` line, the window never materialised,
# `list-windows` returned empty, and this path announced a pass over six
# assertions that never ran. Assertions there go 4 → 10 once it really runs.
#
# The same hole exists one counter over: a hand-rolled `echo "SKIP: …"` that
# bumps nothing reaches the summary with PASS=FAIL=SKIP=0 and prints an
# unqualified `ALL TESTS PASSED` over a suite that asserted NOTHING. That is
# `test-fs-guard.sh`'s running-as-root path, which this lint also flags.
#
# THE REMEDY
#
#     [[ "$win" =~ ^[0-9]+$ ]] || th_abort "spawn returned non-numeric index: $win"
#
# `th_abort` increments `FAIL` and *then* summarises, so the abort exits 1 and
# never prints `ALL TESTS PASSED`. For an absent precondition rather than a
# broken one, `th_skip` is the counterpart — it bumps `SKIP`, which downgrades
# the banner to `ALL TESTS PASSED (n case(s) SKIPPED — NOT covered)`.
#
# ---------------------------------------------------------------------------
# THE AXIS, STATED SO IT CAN BE DISAGREED WITH
#
#   1. FILES — under `monitor/`, and shell: a `*.sh` name, or `ng`, or
#      `sandbox-notify`. Not scoped to `test-*.sh`: the defect is keyed on
#      reaching `th_summary_and_exit`, and any file that calls it is a suite
#      regardless of what it is named. Scoping by name would have made the
#      boundary the SEARCH's axis rather than the MECHANISM's — which is
#      exactly how `#783`'s own filed population came to list 7 sites in
#      `test-integration/` while a genuine eighth sat in `test-fs-guard.sh`.
#   2. ANNOUNCEMENT — an `echo`/`printf` whose text carries a `FAIL:` or
#      `SKIP:` outcome marker. Comment lines are excluded.
#   3. REACHABILITY — `th_summary_and_exit` appears within the next
#      $WINDOW lines (6) of that announcement.
#   4. DISPOSITION — and NO counted disposition appears in between:
#        * a counter bump (`PASS=`, `FAIL=`, `SKIP=` in any assignment or
#          arithmetic spelling), or
#        * a call to `th_abort` / `th_skip` / `assert_*` / `wait_for` /
#          `hold_false` (all of which count), or
#        * an `exit` (see the NEGATIVES below).
#      A site is flagged only when the announcement reaches the summary with
#      none of these intervening.
#
# NOT ON THE AXIS — the load-bearing NEGATIVES, each a form that shares the
# defect's silhouette and is SOUND:
#
#   * `[[ -n "$win" ]] || { echo "FAIL: … " >&2; exit 1; }` — the
#     `test-realmodel-*.sh` form, 8 sites. It never reaches the summary at
#     all: `exit 1` is already non-zero and prints no banner. `#783` recorded
#     the realmodel carve-out as "every bare-`FAIL` echo *does* bump the
#     counter"; re-derived here, that is FALSE — 10 of 41 realmodel `FAIL:`
#     echoes bump nothing. Eight are sound via `exit 1` and two
#     (`test-realmodel-vimode.sh:169,202`) bump 4 lines later, past a
#     2-line window. The carve-out's CONCLUSION survives; its stated
#     MECHANISM does not. A lint that demanded a counter bump would flag all
#     eight sound sites and force a pointless conversion — which is why
#     `exit` is an accepted disposition rather than an exemption.
#   * A `FAIL:` echo whose bump is several lines below a multi-line
#     diagnostic (the vimode pair). The $WINDOW must exceed that gap or the
#     lint manufactures false positives; 6 covers the widest live instance (4).
#   * `assert_*` helper DEFINITIONS in `_test_helpers.sh`, which print `FAIL:`
#     and bump on the following line. Clean by rule 4, not by exemption.
#   * An uncounted failure that reaches the summary more than $WINDOW lines
#     later, or through a function call the line-scanner cannot follow.
#     Declared, not closed: this is a line-window scanner, not a call graph.
#
# "No member found" is a claim about THIS SEARCH, not about the population.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
[[ -d "$ROOT/monitor" ]] || {
    printf 'uncounted-abort-lint: no monitor/ under %s\n' "$ROOT" >&2; exit 2; }

# How far forward to look for whichever terminator comes first. Generous by
# design: under first-disposition-wins (see the scan below) a larger window
# cannot manufacture a false positive — it can only let the scan reach the
# terminator that was already going to decide the verdict. 200 covers the
# longest announcement-to-terminator distance in this tree with room to spare.
WINDOW="${UNCOUNTED_ABORT_LINT_WINDOW:-200}"

# The outcome markers and the summary symbol are assembled rather than written
# literally, for the reason `count-fallback-lint.sh` documents: this lint scans
# all of `monitor/`, so a literal announcement here would be indistinguishable
# from a real site and would make the lint flag its own source — one hit,
# forever, in the tree it certifies clean. An allowlist exempting this path
# would be a lint with a hole shaped like its own author.
_F="FAIL"; _S="SKIP"; _SUM="th_summary""_and_exit"
# The marker must not be preceded by a word character or `_`, so a PARAMETER
# whose name merely ends in the marker is not read as an announcement:
# `"${AUDIT_SKIP:-not requested}"` in `ci-head-attempts.sh` is an expansion
# with a default, not a skip being declared. Without the boundary it matched,
# and only the disposition scan happened to spare it — luck, not design.
_MARK="(^|[^A-Za-z0-9_])(${_F}|${_S}):"
_PRINTS="(echo|printf)"
# A disposition that COUNTS the outcome, or disposes of it without the summary.
#
# `_th_pass|_th_fail|_th_skip` are the CANONICAL counting calls since
# your-org/nexus-code#805 centralised twenty raw `PASS=$(( PASS + 1 ))` sites
# behind them for the durable ledger. They are listed here because that
# refactor invented a new spelling for "counted" that this lint could not see:
# every converted site announced an outcome and then counted it in a way the
# pattern did not recognise, so the lint reported them as uncounted. A lint
# whose notion of "counted" drifts away from the codebase's is worse than no
# lint — it trains readers to ignore it. Note `_th_skip` already matched by
# accident, as a substring of `th_skip`; the other two did not, which is the
# kind of asymmetry that makes this sort of gap hard to notice.
_COUNTED="(PASS=|${_F}=|${_S}=|\(\([[:space:]]*(PASS|${_F}|${_S})|_th_pass|_th_fail|_th_skip|th_abort|th_skip|assert_|wait_for|hold_false|[[:space:]]exit[[:space:]]|^[[:space:]]*exit[[:space:]]|;[[:space:]]*exit[[:space:]])"

# ── NAMING A SYMBOL IS NOT CALLING IT (your-org/nexus-code#838) ────────────
#
# Both dispositions below used to be tested against the RAW line, so the lint
# could not tell an invocation from prose that merely mentions one. That is one
# bug with two faces, and the second is the dangerous one:
#
#   FALSE POSITIVE — a diagnostic whose advice names `th_summary_and_exit`
#   ("Route the suite through `th_summary_and_exit`") read as this path REACHING
#   the summary, so sound code reddened. That is the face `#838` was filed for,
#   and the one that was being paid for with a workaround comment at every call
#   site that needed it. A guard needing a documented workaround per call site
#   has a false-positive problem, not a documentation gap — and a lint that
#   reddens sound code stops being read.
#
#   FALSE NEGATIVE — the same flaw on the clean side, MEASURED here before the
#   fix: a genuine uncounted abort whose advice text mentions `_th_fail`
#   ("Count it with _th_fail") was read as ALREADY COUNTED and passed silently.
#   Fixing only the reported face would have left this one, which hides real
#   defects rather than merely annoying people.
#
# THE FIX IS TO MATCH THE MECHANISM, NOT THE CHARACTERS — the same correction
# `#821` had to make when a decorative `===` in a summary banner satisfied its
# `==` test. A symbol inside a string literal is text the program PRINTS; a
# symbol outside one is code the program RUNS. Balanced quoted spans are removed
# before either disposition is tested.
#
# DELIBERATELY NOT APPLIED to the ANNOUNCEMENT test. `_MARK` looks for `FAIL:` /
# `SKIP:` which live INSIDE the printf string by construction — stripping there
# would blind the lint to every announcement it exists to find.
#
# THE UNBALANCED CASE ERRS TOWARD DETECTION. A line with an unterminated quote
# (a multi-line diagnostic) has no balanced span to remove, so the symbol
# survives and the line is read as code. For a defect detector that is the safe
# direction: a spurious red is visible and arguable, a silent green is neither.
# THE STATE MACHINE LIVES IN ONE PLACE (`_shell_quotes.awk`), and this used to
# be a second, wrong one. The first draft did it with two `sed` substitutions —
# `s/'[^']*'//g` pairs ANY two apostrophes, so two inside double-quoted prose
# formed a span and ate everything between them, INCLUDING a real call:
#
#     echo "don't stop"; th_summary_and_exit; echo "that's all"   ->   echo
#
# A genuine uncounted abort therefore stopped reddening — direction 2, the one
# that ships silently. Writing a character-level matcher in the fix whose whole
# subject is "match the mechanism, not the characters" is the defect this lint
# now detects, committed by the commit that added the detection.
#
# The corpus is scanned ONCE PER FILE, not once per line: one awk process per
# file rather than thousands, and the same shape `th_strip_heredocs` already
# uses. `_CODE[<lineno>]` holds the code-only view; the RAW line is still what
# the announcement test reads, because `FAIL:`/`SKIP:` live inside the string
# by construction.
_QUOTES_AWK="$(dirname "${BASH_SOURCE[0]}")/_shell_quotes.awk"
[[ -r "$_QUOTES_AWK" ]] || {
    printf 'uncounted-abort-lint: missing %s — refusing to run rather than\n' "$_QUOTES_AWK" >&2
    printf '  fall back to a matcher that cannot tell a call from a mention.\n' >&2
    exit 2
}
# The library is CONCATENATED into the program text, not passed with a second
# `-f`. `awk -f lib.awk '{prog}' file` does not work: with `-f`, the next
# argument is a DATA FILE, so awk silently reads the program string as input and
# emits nothing — which made every disposition test compare against an empty
# line and the lint reported zero sites on a tree with a planted defect. A
# scanner that returns a confident zero because its scanner never ran is this
# repo's dominant defect class, so the empty-output case is asserted below.
_QUOTES_SRC="$(cat "$_QUOTES_AWK")"

hits=0
while IFS= read -r -d '' f; do
    case "$f" in
        */.git/*) continue ;;
    esac
    case "${f##*/}" in
        *.sh|ng|sandbox-notify) ;;
        *) continue ;;
    esac
    total=$(wc -l < "$f")
    # Both views of this file, read once. `_RAW` for the announcement test and
    # the comment check; `_CODE` for every disposition test.
    _RAW=(); _CODE=()
    _i=0
    while IFS= read -r _l || [[ -n "$_l" ]]; do _i=$(( _i + 1 )); _RAW[$_i]="$_l"; done < "$f"
    _i=0
    while IFS= read -r _l || [[ -n "$_l" ]]; do _i=$(( _i + 1 )); _CODE[$_i]="$_l"; done \
        < <(awk "$_QUOTES_SRC"' { print code_only($0) }' "$f" 2>/dev/null)
    ln=0
    while IFS= read -r line; do
        ln=$(( ln + 1 ))
        # Comments are not code.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # (2) an announcement?
        [[ "$line" =~ $_PRINTS ]] || continue
        [[ "$line" =~ $_MARK ]]   || continue
        # Does THIS line already dispose of it (same-line bump or exit)?
        # Code only: a printf that MENTIONS `_th_fail` in its advice text is not
        # a bump (your-org/nexus-code#838).
        [[ "${_CODE[$ln]:-}" =~ $_COUNTED ]] && continue
        # (3)+(4) FIRST DISPOSITION WINS. Scan forward and let whichever
        # comes first decide: a counted disposition ⇒ clean, the summary ⇒
        # flagged. This is the only formulation that survives multi-line
        # diagnostics. A fixed N-line "must count within N" window does not:
        # `th_require_stub_claude` prints a 14-line remedy before it exits,
        # and `test-early-exit-reader-manifest.sh` prints an 11-line
        # regeneration recipe before it bumps — both are SOUND and both are
        # false-positived by any window narrow enough to still detect
        # anything. Widening a "must count within N" window weakens
        # detection; widening THIS one does not, because the summary and the
        # bump are both terminators and only their ORDER matters.
        stop=$(( ln + WINDOW )); (( stop > total )) && stop=$total
        (( stop > ln )) || continue
        verdict=""
        for (( a = ln + 1; a <= stop; a++ )); do
            ahead_raw="${_RAW[$a]:-}"
            [[ "$ahead_raw" =~ ^[[:space:]]*# ]] && continue
            ahead_code="${_CODE[$a]:-}"
            if [[ "$ahead_code" =~ $_COUNTED ]]; then verdict="clean"; break; fi
            if [[ "$ahead_code" == *"$_SUM"* ]];  then verdict="hit";   break; fi
        done
        if [[ "$verdict" == "hit" ]]; then
            printf '%s:%s\t%s\n' "$f" "$ln" "$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
            hits=$(( hits + 1 ))
        fi
    done < "$f"
done < <(find "$ROOT/monitor" -type f -print0)

if (( hits > 0 )); then
    printf '\nuncounted-abort-lint: %d site(s). An outcome is ANNOUNCED but never COUNTED,\n' "$hits" >&2
    printf '  and the summary prints from the COUNTERS — so this path exits 0 announcing\n' >&2
    printf '  ALL TESTS PASSED over a scenario that aborted.\n' >&2
    printf '  Fix a broken precondition with `th_abort "<reason>"` (counts a FAIL, then\n' >&2
    printf '  summarises); an ABSENT one with `th_skip "<label>" "<reason>"`.\n' >&2
    printf '  A bare `exit 1` is also sound — it never reaches the summary.\n' >&2
    printf '  your-org/nexus-code#783\n' >&2
    exit 1
fi
exit 0
