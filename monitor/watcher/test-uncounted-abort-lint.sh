#!/usr/bin/env bash
# test-uncounted-abort-lint.sh — both-directions coverage for
# monitor/watcher/uncounted-abort-lint.sh (your-org/nexus-code#783).
#
# A lint is only worth its maintenance if BOTH its directions are checked. A
# lint that flags nothing passes a clean tree and a broken one identically; a
# lint that flags everything gets muted within a week. So every case below
# plants a fixture and states which direction it pins:
#
#   POSITIVE — the defect, in each spelling seen live on `dev`. Each MUST be
#              flagged, or the lint's green is a claim about its regex rather
#              than about the tree.
#   NEGATIVE — the CORRECT forms, plus the near-misses that share the defect's
#              silhouette. Each MUST NOT be flagged.
#
# THE NEGATIVES ARE THE LOAD-BEARING HALF here, more than usual, because two
# of them killed an earlier formulation of this lint outright:
#
#   * N5 (long diagnostic, THEN a bump) is why the lint cannot be "an
#     announcement must be counted within N lines". `th_require_stub_claude`
#     prints a 14-line remedy before it exits and
#     `test-early-exit-reader-manifest.sh` prints an 11-line regeneration
#     recipe before it bumps — both SOUND, both false-positived by any window
#     narrow enough to still detect the real defect. The lint therefore uses
#     FIRST-DISPOSITION-WINS, where only the ORDER of the two terminators
#     matters and the window can be generous.
#   * N1 (the `test-realmodel-*.sh` `exit 1` form, 8 live sites) is why `exit`
#     is an accepted disposition. `#783` recorded the realmodel carve-out as
#     "every bare-`FAIL` echo *does* bump the counter"; re-derived, that is
#     FALSE — 10 of 41 realmodel `FAIL:` echoes bump nothing, 8 of them sound
#     via `exit 1`. A lint demanding a bump would flag all 8 and force a
#     pointless conversion.
#   * N8 (`"${AUDIT_SKIP:-…}"`) is a parameter whose NAME ends in a marker.
#     It matched before the word boundary went in, and only the disposition
#     scan happened to spare it — luck, not design.
#
# Run: bash monitor/watcher/test-uncounted-abort-lint.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Hermetic — no tmux, no
# network, no nexus state; every fixture is composed at RUNTIME.

set -uo pipefail

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

PASS=0; FAIL=0; SKIP=0

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LINT="$_dir/uncounted-abort-lint.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The markers and the summary symbol are ASSEMBLED, never written literally.
# Not cosmetic: the lint scans all of `monitor/`, and this file lives there and
# ends — as every suite does — in a call to the summary. A literal
# announcement anywhere in the last 200 lines would therefore be
# indistinguishable from a real site and would make the lint flag its own test:
# one hit, forever, in the tree it certifies clean. The alternative is an
# allowlist exempting this path, and a lint with an exemption for the file most
# likely to contain the pattern is a lint with a hole shaped like its own
# author. Keeping the literals out of the source keeps the scan uniform and
# needs no exception.
_FM="FAIL"; _SM="SKIP"; _SUMC="th_summary""_and_exit"

# _plant <relative-path> <line…> — build a fixture tree rooted at $WORK/tree.
# DECLARED per case, never mutated incrementally: each case rebuilds the tree
# from scratch, so a fixture cannot leak into the next case and answer through
# a path it was never written to reach.
_plant() {
    rm -rf "$WORK/tree"; mkdir -p "$WORK/tree/monitor/watcher"
    local rel="$1"; shift
    mkdir -p "$WORK/tree/$(dirname "$rel")"
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$WORK/tree/$rel"
}

# _lint_hits → number of rows the lint printed (0 when clean).
_lint_hits() {
    local out
    out=$(bash "$LINT" "$WORK/tree" 2>/dev/null)
    # `grep -c` prints 0 on no match and exits 1; `|| echo 0` would APPEND a
    # second value (your-org/nexus-code#725) — this suite committing the
    # defect a sibling lint exists to catch.
    [[ -z "$out" ]] && { printf '0\n'; return; }
    printf '%s\n' "$out" | grep -c . || true
}

_lint_rc() {
    bash "$LINT" "$WORK/tree" >/dev/null 2>&1
    printf '%s\n' "$?"
}

# A long diagnostic body, used by P4 and N5 so the two differ ONLY in their
# terminator. That is the whole point of the pair: same shape, opposite verdict.
_diag=(
    "    printf '        A reader that can close a pipe EARLY was added.\\n'"
    "    printf '        Regenerating the manifest is NOT the fix.\\n'"
    "    printf '        Decide which it is:\\n'"
    "    printf '          + a NEW site: is the pipeline status consumed?\\n'"
    "    printf '          - a REMOVED site: good. Regenerate and say so.\\n'"
    "    printf '        Regenerate with:\\n'"
    "    printf '          bash monitor/watcher/early-exit-readers.sh\\n'"
    "    printf '        Diff (recorded vs live):\\n'"
)

echo '=== POSITIVE — each of these MUST be flagged ==='

# P1 — the canonical #783 form, measured live on dev@16728e7 in five scenarios.
_plant monitor/watcher/a.sh \
    '[[ "$win" =~ ^[0-9]+$ ]] || {' \
    "    echo \"  ${_FM}: spawn returned non-numeric window index: \$win\" >&2" \
    "    $_SUMC" \
    '}'
assert_eq "P1 the #783 abort form is flagged"            "$(_lint_hits)" "1"
assert_eq "P1 flagging exits 1"                          "$(_lint_rc)"   "1"

# P2 — the same hole one counter over: an uncounted SKIP reaches the summary
# and downgrades nothing, so `ALL TESTS PASSED` covers a case that never ran.
# Four live sites (test-fs-guard, test-remote-{self-enroll,carrier-authline,
# principals-guard}).
_plant monitor/watcher/a.sh \
    'if (( ! _can_test_ro )); then' \
    "    echo \"${_SM}: running as root — 0555 cannot model a read-only mount\" >&2" \
    "    $_SUMC" \
    'fi'
assert_eq "P2 an uncounted SKIP reaching the summary is flagged" "$(_lint_hits)" "1"

# P3 — printf is the other spelling; three of the four live SKIP sites use it.
_plant monitor/watcher/a.sh \
    "printf '  ${_SM}: ssh-keygen absent — redeem path not exercised\\n'" \
    "$_SUMC"
assert_eq "P3 the printf spelling is flagged"            "$(_lint_hits)" "1"

# P4 — a long diagnostic that still ends at the summary uncounted. Pairs with
# N5: identical body, opposite terminator.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: the population changed.\\n'" \
    "${_diag[@]}" \
    "$_SUMC"
assert_eq "P4 a long diagnostic ending uncounted at the summary is flagged" \
    "$(_lint_hits)" "1"

# P5 — two independent sites in one file are counted separately, so a partial
# conversion cannot read as a clean file.
_plant monitor/watcher/a.sh \
    "echo \"  ${_FM}: phase-1 spawn returned non-numeric index\" >&2" \
    "$_SUMC" \
    'true' \
    "echo \"  ${_FM}: phase-3 respawn returned non-numeric index\" >&2" \
    "$_SUMC"
assert_eq "P5 two sites in one file are two hits"        "$(_lint_hits)" "2"

# P6 — the extensionless executables this repo ships are on the axis too.
_plant monitor/ng \
    "echo \"  ${_FM}: precondition broke\" >&2" \
    "$_SUMC"
assert_eq "P6 an extensionless shipped executable is on the axis" "$(_lint_hits)" "1"

echo
echo '=== NEGATIVE — each of these MUST NOT be flagged ==='

# N1 — the test-realmodel-*.sh form, 8 live sites. Never reaches the summary:
# `exit 1` is already non-zero and prints no banner.
_plant monitor/watcher/a.sh \
    "[[ -n \"\$win\" ]] || { echo \"${_FM}: worker window never appeared\" >&2; exit 1; }" \
    "$_SUMC"
assert_eq "N1 the realmodel \`exit 1\` form is sound"    "$(_lint_hits)" "0"
assert_eq "N1 a clean tree exits 0"                      "$(_lint_rc)"   "0"

# N2 — announced AND counted on the following line. The form the converted
# sites had to become.
_plant monitor/watcher/a.sh \
    "echo \"  ${_FM}: spawn returned non-numeric index\" >&2" \
    "${_FM}=\$(( ${_FM} + 1 ))" \
    "$_SUMC"
assert_eq "N2 announced then counted is sound"           "$(_lint_hits)" "0"

# N3 — the remedy this issue introduces.
_plant monitor/watcher/a.sh \
    '[[ "$win" =~ ^[0-9]+$ ]] || th_abort "spawn returned non-numeric index: $win"' \
    "$_SUMC"
assert_eq "N3 th_abort is sound"                         "$(_lint_hits)" "0"

# N4 — the absent-precondition counterpart.
_plant monitor/watcher/a.sh \
    'th_skip "read-only fixtures" "running as root"' \
    "$_SUMC"
assert_eq "N4 th_skip is sound"                          "$(_lint_hits)" "0"

# N5 — THE WINDOW-KILLER. Same body as P4, terminated by a bump instead of the
# summary. Any "must count within N lines" rule false-positives this; it is
# why the lint is first-disposition-wins.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: the population changed.\\n'" \
    "${_diag[@]}" \
    "    ${_FM}=\$(( ${_FM} + 1 ))" \
    "$_SUMC"
assert_eq "N5 a long diagnostic terminated by a bump is sound" "$(_lint_hits)" "0"

# ── NAMING A SYMBOL IS NOT CALLING IT (your-org/nexus-code#838) ────────────
# Both dispositions are tested against the line with QUOTED SPANS REMOVED, so a
# symbol inside a string literal is text the program PRINTS, not code it RUNS.
# One bug with two faces; both are pinned here, in both directions, because a
# fix verified in only one direction is untested in the one that matters.

# N11 — THE FILED FACE. A diagnostic whose advice NAMES the summary function,
# then counts. Sound: the count is right there. Before the fix this reddened,
# and the remedy in circulation was a workaround comment at every call site.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: the manifest is out of date\\n' >&2" \
    "    printf '        Route the suite through \`${_SUMC}\`, which refuses to\\n' >&2" \
    "    _th_fail"
assert_eq "N11 a diagnostic that NAMES the summary function is sound" "$(_lint_hits)" "0"

# P7 — THE MIRROR, and the more dangerous face. A GENUINE uncounted abort whose
# advice text mentions `_th_fail`. Before the fix the mention satisfied the
# clean-side matcher and this real defect passed SILENTLY — a false negative,
# measured on `dev` at 493bd2d before the change. It must stay a hit.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: the fixture did not start\\n' >&2" \
    "    printf '        Count it with _th_fail, or abort with th_abort.\\n' >&2" \
    "$_SUMC"
assert_eq "P7 prose naming a COUNTING call does not hide a real uncounted abort" \
    "$(_lint_hits)" "1"

# P8 — the fix must not blind the lint by excluding output LINES wholesale. A
# real call can share a line with output, and stripping quoted spans (rather
# than dropping printf/echo lines) is what keeps this a hit.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: precondition broken\\n' >&2" \
    "    echo done; $_SUMC"
assert_eq "P8 a real summary call sharing a line with output is still flagged" \
    "$(_lint_hits)" "1"

# N12 — the counterpart on the same-line disposition: an announcement whose own
# line merely MENTIONS a counting call in its text is not counted by it.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: use _th_fail to count this\\n' >&2" \
    "$_SUMC"
assert_eq "N12 a same-line MENTION of a counting call does not clear the site" \
    "$(_lint_hits)" "1"

# P9 — THE APOSTROPHE CASE. The one the four cases above did NOT exercise, and
# the one a character-level matcher gets wrong: two apostrophes inside
# DOUBLE-quoted prose pair with each other, so `sed "s/'"'"'[^'"'"']*'"'"'//g"` deletes
# everything between them — including a real call:
#
#     echo "don[']t stop"; th_summary_and_exit; echo "that[']s all"   ->   echo
#
# Direction 2 fails: a GENUINE uncounted abort stops reddening. That is the
# direction that ships silently, because a lint exists to catch something rare.
# Shipped in the commit whose header says "match the mechanism, not the
# characters"; caught by the `#842` skeptic; fixed by sharing
# `_shell_quotes.awk` with th_strip_heredocs instead of writing a second
# state machine.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: the fixture did not start\\n' >&2" \
    "    echo \"don't stop\"; $_SUMC; echo \"that's all\""
assert_eq "P9 an apostrophe in double-quoted prose does not hide a real call" \
    "$(_lint_hits)" "1"

# N13 — the same shape, but the call is genuinely absent: the symbol appears
# only inside the quoted prose. Pairs with P9 so neither can pass by the
# matcher collapsing to a constant.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: the fixture did not start\\n' >&2" \
    "    echo \"don't call $_SUMC here, that's advice\"" \
    "    _th_fail"
assert_eq "N13 the symbol ONLY inside apostrophe-bearing prose is not a call" \
    "$(_lint_hits)" "0"

# N14 — AN ESCAPED QUOTE DOES NOT END THE SPAN. Inside double quotes `\\"` is a
# literal quote, so the whole string is ONE span and a symbol within it is text.
# A matcher that treats the escaped quote as a terminator splits the span and
# exposes the symbol as code — a false positive. This branch of the shared
# machine had no test until a mutant (disabling the backslash arm) reddened
# nothing; that silence is what this case removes.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: the fixture did not start\\n' >&2" \
    "    echo \"see \\\"$_SUMC\\\" in the docs\"" \
    "    _th_fail"
assert_eq "N14 an escaped quote does not split a double-quoted span" \
    "$(_lint_hits)" "0"

# P10 — THE SCANNER MUST HAVE RUN. `awk -f lib.awk '{prog}' file` is invalid:
# with `-f`, the next argument is a DATA file, so awk reads the program string
# as input and emits nothing. That happened here, and every disposition then
# compared against an empty line: the lint reported ZERO sites on a tree with a
# planted defect. A confident zero from a scanner that never ran is this repo's
# dominant defect class, so a known-positive plant guards it.
_plant monitor/watcher/a.sh \
    "    printf '  ${_FM}: canary — this MUST be detected\\n' >&2" \
    "$_SUMC"
assert_eq "P10 CANARY: the scanner runs at all (a known defect is still found)" \
    "$(_lint_hits)" "1"

# N5b — the same shape terminated by an exit, which is th_require_stub_claude's.
_plant monitor/watcher/a.sh \
    "    echo \"ENV-${_FM}: CLAUDE_BIN resolves to the WRONG binary\" >&2" \
    "${_diag[@]}" \
    '    exit 2' \
    "$_SUMC"
assert_eq "N5b a long diagnostic terminated by exit is sound" "$(_lint_hits)" "0"

# N6 — a commented-out instance is not code.
_plant monitor/watcher/a.sh \
    "#     echo \"  ${_FM}: spawn returned non-numeric index\" >&2" \
    "#     $_SUMC" \
    "$_SUMC"
assert_eq "N6 a commented-out instance is not flagged"   "$(_lint_hits)" "0"

# N7 — a mid-run note followed by real assertions. The suite goes on
# asserting, so this is not a TERMINAL uncounted outcome.
_plant monitor/watcher/a.sh \
    "printf '  ${_SM}: optional fixture missing\\n'" \
    'assert_eq "something else entirely" "$got" "$want"' \
    "$_SUMC"
assert_eq "N7 an announcement followed by a counted assertion is sound" \
    "$(_lint_hits)" "0"

# N8 — a PARAMETER whose name merely ends in a marker. Matched before the word
# boundary went in (`ci-head-attempts.sh`).
_plant monitor/watcher/a.sh \
    "printf 'audit did NOT run (%s)\\n' \"\${AUDIT_${_SM}:-not requested}\"" \
    "$_SUMC"
assert_eq "N8 a parameter name ending in a marker is not an announcement" \
    "$(_lint_hits)" "0"

# N9 — non-shell files are off-axis.
_plant monitor/watcher/notes.md \
    "echo \"  ${_FM}: spawn returned non-numeric index\" >&2" \
    "$_SUMC"
assert_eq "N9 non-shell files are off-axis"              "$(_lint_hits)" "0"

# N10 — a tree with no announcement at all must lint clean rather than error.
_plant monitor/watcher/a.sh 'assert_eq "ordinary" "$got" "$want"' "$_SUMC"
assert_eq "N10 an ordinary suite is clean"               "$(_lint_rc)"   "0"

echo
echo '=== the lint refuses a tree it cannot scan ==='
# A caller who points this at the wrong root must get a LOUD refusal, not a
# clean bill. rc 2 is "could not examine", distinct from rc 0 "examined, clean"
# — the distinction `#612` exists to preserve.
rm -rf "$WORK/tree"; mkdir -p "$WORK/tree"
assert_eq "a root with no monitor/ exits 2, not 0"       "$(_lint_rc)"   "2"

echo
echo '=== MANIFEST: the realmodel carve-out, as DATA rather than prose ==='
# `#783` justified a small change over a sweep with an emptiness claim:
# "every `test-realmodel-*.sh` bare-`FAIL` echo *does* bump the counter, so
# cc-harness's reporting is sound."
#
# Re-derived here, the CONCLUSION survives and the stated MECHANISM does not.
# The census below is the reason the distinction matters: 8 of the 41
# announcements bump NOTHING and are sound because they `exit 1`, never
# reaching the summary at all. A lint built from the issue's wording — demand
# a counter bump — would have flagged all 8 sound sites and forced a pointless
# conversion of the very band the carve-out was protecting.
#
# Pinned as DATA because prose cannot be made to fail. If a realmodel abort is
# ever added that neither exits nor counts, `neither` goes non-zero here and the
# lint flags it above.
#
# THESE ARE NOT TWO INDEPENDENT CONFIRMATIONS OF ONE DEFECT, and this text used
# to claim they were. The `#795` skeptic planted a SOUND site — `echo "FAIL: …"`
# with `exit 1` on the NEXT line, the same shape as the 8 live ones just split
# across two lines — and measured the two instruments DISAGREEING: the lint
# correctly passed it (rc 0) while this census went `41→42` and `neither 0→1`.
# The census's `exit` detection was same-line-only.
#
# Fixed below by making the census FIRST-DISPOSITION-WINS, exactly as the lint
# is, so the two classify by the same rule. Re-measured against the skeptic's
# own fixture after the fix: the planted sound site now lands in `byexit`
# (8→9), `neither` stays **0**, and the lint still returns rc 0 — the two now
# AGREE on soundness. The totals do still move (41→42), and that is the
# manifest doing its job: any added announcement changes the recorded
# population and a human decides whether it should have.
#
# The honest version of the claim, which is what the two instruments actually
# give you: the LINT decides soundness, and this census is a CHANGE-DETECTOR
# whose failure direction is loud and safe — it can force a re-derivation, it
# can never let a real defect through. "Two independent instruments" is a claim
# that needs a disagreement test, and the original one failed it.
_census() {
    local tot=0 byexit=0 bycount=0 neither=0 f ln line fwd disp
    for f in "$_dir"/test-integration/test-realmodel-*.sh; do
        [[ -e "$f" ]] || continue
        while IFS=: read -r ln _; do
            line=$(sed -n "${ln}p" "$f")
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            # Herestrings, NOT `printf … | grep -q`. Under `pipefail` the pipe
            # form is a FALSE FAILURE: `grep -q` exits at the first match, the
            # producer takes SIGPIPE, and the pipeline reports rc 141 on a
            # string that DID match — which here would silently miscount the
            # very census this section publishes. The first draft of this file
            # used the pipe form at all three sites and
            # `test-sigpipe-assertion-lint.sh` caught it, in the same commit
            # that added a lint about announcing-without-counting.
            grep -qE '(echo|printf)' <<<"$line" || continue
            tot=$(( tot + 1 ))
            # FIRST DISPOSITION WINS, scanned forward from the announcement
            # line itself — same rule as the lint. Taking `exit` from the
            # announcement line ONLY (the original) misclassifies a sound site
            # whose `exit` sits on the next line.
            disp="neither"
            while IFS= read -r ahead; do
                [[ "$ahead" =~ ^[[:space:]]*# ]] && continue
                if grep -qE '(^|[^A-Za-z0-9_])exit([[:space:]]|$)' <<<"$ahead"; then
                    disp="exit"; break
                fi
                # `_th_fail` is the canonical counting call since #805; the
                # census must recognise it or it will report converted sites as
                # "neither" and the manifest numbers below become fiction.
                if grep -qE "${_FM}=|\(\([[:space:]]*${_FM}|_th_fail|_th_pass|_th_skip" <<<"$ahead"; then
                    disp="count"; break
                fi
            done < <(sed -n "${ln},$(( ln + 8 ))p" "$f")
            case "$disp" in
                exit)  byexit=$((  byexit  + 1 )) ;;
                count) bycount=$(( bycount + 1 )) ;;
                *)     neither=$(( neither + 1 )) ;;
            esac
        done < <(grep -nE "(^|[^A-Za-z0-9_])${_FM}:" "$f")
    done
    printf '%d %d %d %d\n' "$tot" "$byexit" "$bycount" "$neither"
}
_c=$(_census)
# Sanity-check the denominator against a known total before trusting any of
# the parts — a silent zero from a broken enumeration would otherwise read as
# "the population is empty" (CLAUDE.md; your-org/nexus-code#721, #770).
_nfiles=$(find "$_dir/test-integration" -name 'test-realmodel-*.sh' -type f | wc -l)
# 8 → 9 files, 41 → 45 announcements, 8 → 11 by-exit, 33 → 34 by-count:
# your-org/nexus-code#896 added `test-realmodel-trust-dialog.sh`. Re-derived
# rather than merely bumped, which is what the manifest is for. Its four
# announcements are three preconditions (`jq` absent; either window never
# appearing) disposed by `exit 1` — the same shape the other eight sound sites
# use, copied from `test-realmodel-blocked-question.sh` — and one non-vacuity
# check on a comparison that CANNOT abort, because the assertions after it are
# the point of the file; that one calls `_th_fail`, the canonical counter since
# `#805`. `neither` stayed **0**, which is the assertion that actually decides
# soundness; these four moved the population, not the conclusion.
#
# 45 -> 46 / 34 -> 35 on a SECOND pass: the expected-count guard that
# `your-org/nexus-code#872` requires of a `ledger=yes` suite adds a fifth
# announcement to that same scenario, disposed by `_th_fail`. Re-derived, not
# bumped; `neither` is still 0. Recorded because this census going red TWICE
# for one PR is the manifest working as designed — it forced a human to look
# at each new announcement instead of letting the band drift.
#
# 9 -> 10 files, 46 -> 51 announcements, 11 -> 15 by-exit, 35 -> 36 by-count:
# your-org/nexus-code#1334 added `test-realmodel-trust-sandboxed-env.sh`, the
# canary for the undocumented `CLAUDE_CODE_SANDBOXED` trust-gate bypass the
# worker launchers now set. Re-derived: four preconditions disposed by
# `exit 1` (worker-settings.json unreadable; `jq` absent; either window never
# appearing) and one expected-count guard disposed by `_th_fail`. `neither`
# is still 0.
#
# 10 -> 11 files, 51 -> 52 announcements, 15 by-exit unchanged, 36 -> 37
# by-count: your-org/nexus-code#1535 added `test-realmodel-longjob-wake.sh`
# (the longjob dispatcher against the real binary). Re-derived on the
# bundle-2609 tree by this suite's own census (this block, run on the merged
# tree: `11`, `52 15 37 0`): one new announcement, disposed by a counter
# bump. `neither` is still 0.
assert_eq "manifest: 11 realmodel files are enumerated"  "$_nfiles"          "11"
assert_eq "manifest: 52 realmodel FAIL announcements"    "$(echo "$_c" | cut -d' ' -f1)" "52"
assert_eq "manifest: 15 are disposed by \`exit\`, NOT by a counter" \
    "$(echo "$_c" | cut -d' ' -f2)" "15"
assert_eq "manifest: 37 are disposed by a counter bump"  "$(echo "$_c" | cut -d' ' -f3)" "37"
# The load-bearing one: the carve-out's CONCLUSION.
assert_eq "manifest: ZERO realmodel aborts neither exit nor count" \
    "$(echo "$_c" | cut -d' ' -f4)" "0"

echo
echo '=== the repo itself is clean, and that green is non-vacuous ==='
# Asserted TOGETHER with the positives above: "the tree is clean" means
# something only because P1-P6 proved this lint can go red.
_repo_root=$(cd "$_dir/../.." && pwd)
bash "$LINT" "$_repo_root" >/dev/null 2>&1
assert_eq "monitor/ carries no announced-but-uncounted outcome" "$?" "0"

# EXPECTED-ASSERTION-COUNT GUARD (your-org/nexus-code#807/#821). Added with the
# #838 cases: this suite gained four assertions and had nothing pinning how many
# ran, so a vanished one would have read as a clean green. The total is captured
# BEFORE the guard counts its own failure — reporting it after overstates the
# run by one and sends the next reader hunting for an assertion that never was.
#
# Note this message may now name `th_summary_and_exit` freely: that it could not
# before, without the lint reading the mention as a call, is exactly the defect
# #838 fixed.
EXPECTED=34
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
