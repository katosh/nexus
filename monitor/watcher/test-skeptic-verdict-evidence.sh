#!/usr/bin/env bash
# A DELIVERED SKEPTIC VERDICT THE MACHINERY CANNOT SEE — that the refusal now
# says WHICH of the two it is (your-org/nexus-code#1156, #1153, #1146, #1148, #1132).
#
# Run: bash monitor/watcher/test-skeptic-verdict-evidence.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# ── THE DEFECT ──────────────────────────────────────────────────────────────
#
# On one afternoon four windows could not retire on a "missing" skeptic verdict
# that had in fact been DELIVERED, by four different mechanisms, and all four
# printed the same refusal. The ledger ROWS already differed; only the reader
# did not. Measured cost on that board: three duplicate `spawn-skeptic`
# requests (one for a PR that had already merged) and two orchestrator pushes
# at reviewers that had already discharged.
#
# "A verdict exists and could not be matched to an arm" and "no verdict exists"
# are OPPOSITE INSTRUCTIONS — repair the record, versus get a review. This
# suite plants the four mechanisms verbatim from the observed ledgers and
# asserts the emit distinguishes them, from each other and from a genuinely
# absent verdict.
#
#   evfix-amended     5x `asserted-not-armed`   the report was AMENDED after
#                                               arming, so the content hash
#                                               moved off the armed one
#   evfix-ambig       `ambiguous-3-arms-…`      3 wrap-ups armed 3 rounds
#                                               against ONE report path; one
#                                               discharge cannot close three
#   evfix-rearm       discharge+resolve, then   a wrap-up RE-ARMED a chain that
#                     a LATER `armed`           had already closed
#   evfix-attributed  matching hash, verdict    the HAPPY path in this ledger —
#                     recorded, nothing open    and the window still could not
#                                               retire, because a SECOND ledger
#                                               (`$STATE_DIR/obligations`)
#                                               records the same dependency and
#                                               was never settled
#
# ── THE PROPERTY UNDER TEST IS THE SAFE DIRECTION ───────────────────────────
#
# The dangerous error is claiming a verdict EXISTS when none does: that invites
# an operator to release a gate on a pass that never happened, which is
# strictly worse than the old behaviour, which erred toward refusing. So the
# controls below are weighted that way:
#
#   CONTROL A (negative)  `evfix-noverdict` — an arm and NOTHING else. Its
#       ledger is asserted to contain ZERO `discharged` rows, so the fixture is
#       known verdict-free BY CONSTRUCTION rather than by the classifier's own
#       say-so, and the class must be `none`.
#   CONTROL B (doubt)     `evfix-malformed` — an unparseable row. Must classify
#       `?`, and the refusal must then carry NO `evidence=` claim at all,
#       falling back to the wording the gate used before this existed. Doubt
#       prints nothing; it does not print a guess.
#   CONTROL C (absence)   `evfix-noledger` — no ledger file. Must not become a
#       verdict claim by way of an empty parse.
#   CONTROL D (vacuity)   the five refusal reasons are asserted PAIRWISE
#       DISTINCT. Without it, "each reason contains its tag" is satisfied by a
#       clause that is a substring of every reason.
#   CONTROL E (verdict unchanged)  every refusal above is still `safe=0`. This
#       change is allowed to alter WORDS and nothing else, and that is what
#       makes a misclassification survivable: a refusal stays a refusal.
#
# ── ASSERTIONS THAT FAIL IF THE FIX REGRESSES, WITH THEIR KILLING MUTATION ──
#
#   "each mechanism classifies distinctly"
#       kill: collapse the `rearm-after-close` arm into `ambiguous-arms`
#             -> got ambiguous-arms want rearm-after-close
#   "the five refusal reasons are pairwise distinct"
#       kill: make `_sk_ev_clause` print one constant  -> got 1 want 5
#   "a malformed ledger yields NO evidence= claim"
#       kill: drop the `[[ "$_SK_EV_CLASS" == "?" ]] && _SK_EV_CLASS=""` fold
#             -> reason gains `evidence=`
#   "an arm-only ledger classifies `none`"
#       kill: default the END arm to `unmatched-other` -> got unmatched-other
#   "the two-ledger desync is named on the obligation edge"
#       kill: drop the creditor probe                  -> missing TWO-LEDGER DESYNC
#   "…and is NOT named when the creditor holds no verdict"
#       kill: widen the `case` arm to `*)`             -> tag appears wrongly
#   "a TRUNCATED discharge row is ? — never a verdict claim"
#       kill: relax the row-width test back to `NF < 3`
#             -> got unmatched-other want ?
#   "a LATER verdict after a matched one -> superseded-verdict"
#       kill: drop the `superseded > 0` arm from the precedence chain
#             -> got unmatched-subject want superseded-verdict
#   "an asserted row counts as MATCHED, not unmatched"
#       kill: remove `asserted` from the matched-detail test
#             -> got matched=0, and the supersession silently collapses
#   "the supersession is STILL named, not hidden by precedence"
#       kill: move the SUPERSEDED clause inside the `case` instead of after it
#             -> missing SUPERSEDED:
#   "every orphan-emit remedy sends the reader to ng skeptic-evidence"
#       kill: restore "spawn the skeptic or clear the marker" at any of the
#             three sites                                -> got 1 want 0
#   "every refusal is still safe=0"
#       kill: any polarity change on those emits       -> got safe=1

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
NG="$REPO_ROOT/monitor/ng"
PREFLIGHT="$REPO_ROOT/monitor/retire-preflight.sh"

[[ -x "$NG" ]]        || th_abort "monitor/ng not executable at $NG"
[[ -r "$PREFLIGHT" ]] || th_abort "monitor/retire-preflight.sh not readable at $PREFLIGHT"

WORK=$(mktemp -d -t nexus-skev-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/.state"
PEND="$STATE/skeptic/pending"
mkdir -p "$PEND"

# ESTABLISH THIS SUITE'S STATE DIRECTORY, AND FAIL CLOSED IF THE PIN DOES NOT
# TAKE (your-org/nexus-code#1306). Every `--state-dir` below pins the LEDGER
# and nothing else: `ng` resolves its process-level `STATE_DIR` at startup from
# the INHERITED `$NEXUS_ROOT`, and its usage tap fires before dispatch — so in
# an agent shell this suite appended to the operator's canonical
# `monitor/.state/`, at rc 0, with every assertion green. Exported rather than
# passed per call, because the leak is a property of every `ng` this file
# starts including ones a future case adds. See th_pin_ng_state for the
# measurement and for what the check does NOT cover.
th_pin_ng_state "$NG" "$STATE"

# Distinguishable 64-hex subjects. Real shas would work and would make a
# failure unreadable; these are the same SHAPE, which is all the code inspects.
SHA_A=aaaaaaaa11111111111111111111111111111111111111111111111111111111
SHA_B=bbbbbbbb22222222222222222222222222222222222222222222222222222222
SHA_C=cccccccc33333333333333333333333333333333333333333333333333333333
SHA_D=dddddddd44444444444444444444444444444444444444444444444444444444

_arm()  { printf 'armed\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" >> "$PEND/.$1.ledger"; }
_disc() { printf 'discharged\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" >> "$PEND/.$1.ledger"; }
_res()  { printf 'resolved\t-\t%s\t%s\t%s\n' "$2" "$3" "$4" >> "$PEND/.$1.ledger"; }

# 1 — the report was AMENDED after arming (annzfix)
_arm  evfix-amended "$SHA_A" 2026-08-28T14:08:49-07:00 339 reports/amended.md
for t in 14:51:38 14:53:07 14:53:37 14:54:27 15:00:53; do
    _disc evfix-amended "$SHA_B" "2026-08-28T${t}-07:00" check 339 evfix-amended-sk asserted-not-armed
done
# 2 — three rounds armed against ONE report path (annzpr11)
_arm  evfix-ambig "$SHA_A" 2026-08-28T15:46:04-07:00 339 reports/pr11.md
_arm  evfix-ambig "$SHA_B" 2026-08-28T15:59:23-07:00 339 reports/pr11.md
_arm  evfix-ambig "$SHA_C" 2026-08-28T16:17:59-07:00 339 reports/pr11.md
_disc evfix-ambig - 2026-08-28T16:25:24-07:00 check 339 evfix-ambig-sk ambiguous-3-arms-outstanding
# 3 — a wrap-up RE-ARMED a closed chain (devred)
_arm  evfix-rearm "$SHA_A" 2026-08-27T23:18:16-07:00 1094 reports/devred.md
_disc evfix-rearm "$SHA_A" 2026-08-27T23:52:33-07:00 check 1094 evfix-rearm-sk attributed
_res  evfix-rearm 2026-08-28T16:23:48-07:00 "skeptic-channel.sh close" "channel closed by the reviewer"
_arm  evfix-rearm "$SHA_D" 2026-08-28T16:43:31-07:00 1138 reports/devred.md
# 4 — the HAPPY path in this ledger (overlaycontent / annzmerge)
_arm  evfix-attributed "$SHA_A" 2026-08-28T15:54:10-07:00 338 reports/overlay.md
_disc evfix-attributed "$SHA_A" 2026-08-28T16:35:22-07:00 check 338 evfix-attributed-sk attributed
# CONTROL A — an arm and nothing else
_arm  evfix-noverdict "$SHA_A" 2026-08-28T15:54:10-07:00 338 reports/none.md
# CONTROL B — an unparseable row
_arm  evfix-malformed "$SHA_A" 2026-08-28T15:54:10-07:00 338 reports/bad.md
printf 'this row is not a ledger row\n' >> "$PEND/.evfix-malformed.ledger"
# 5 — TWO REAL VERDICTS, the later one unable to attach (`clmd`, planted from
# the live ledger). The reviewer re-derived its findings against a head that
# moved MID-REVIEW and amended its report to publish that, which moved the
# content hash off the arm. Arming happened once, against the original report.
_arm  evfix-superseded "$SHA_A" 2026-08-28T18:19:58-07:00 1158 reports/clmd.md
_disc evfix-superseded "$SHA_A" 2026-08-28T18:40:00-07:00 check    1158 evfix-superseded-sk asserted
_disc evfix-superseded "$SHA_B" 2026-08-28T19:12:12-07:00 credible 1158 evfix-superseded-sk asserted-not-armed
# CONTROL G — the HEALTHY two-round sequence: two arms, two verdicts, BOTH
# cleanly matched. Nothing is superseded here, and calling it so would flag the
# ordinary multi-round case as an anomaly.
_arm  evfix-tworound "$SHA_A" 2026-08-28T10:00:00-07:00 1158 reports/two.md
_disc evfix-tworound "$SHA_A" 2026-08-28T10:30:00-07:00 check    1158 evfix-tworound-sk attributed
_arm  evfix-tworound "$SHA_B" 2026-08-28T11:00:00-07:00 1158 reports/two.md
_disc evfix-tworound "$SHA_B" 2026-08-28T11:30:00-07:00 credible 1158 evfix-tworound-sk asserted
# CONTROL H — TWO VERDICTS ON DIFFERENT ISSUES. Unrelated TASKS: neither
# supersedes the other, and an instruction to "take the later one" would DISCARD
# A VALID VERDICT. Deciding this from line order alone is window-keyed
# newest-wins — the container error #1156 exists to fix and #962 forbids —
# re-entering through the PROSE rather than through the gate.
_arm  evfix-diffissue "$SHA_A" 2026-08-28T10:00:00-07:00 1156 reports/d.md
_disc evfix-diffissue "$SHA_A" 2026-08-28T10:30:00-07:00 credible 1156 sk-a asserted
_disc evfix-diffissue "$SHA_B" 2026-08-28T11:00:00-07:00 suspect  1200 sk-b asserted-not-armed
# CONTROL I — the SAME verdict recorded twice. A re-record, not a supersession:
# nothing is weaker or stronger about two identical strings. This shape was
# live on THREE of the five superseded ledgers on the board.
_arm  evfix-rerecord "$SHA_A" 2026-08-28T10:00:00-07:00 1156 reports/r.md
_disc evfix-rerecord "$SHA_A" 2026-08-28T10:30:00-07:00 credible 1156 sk-a asserted
_disc evfix-rerecord "$SHA_B" 2026-08-28T11:00:00-07:00 credible 1156 sk-a asserted-not-armed
# CONTROL J — a LATER verdict with NO issue field on either row. #1146 says this
# is the common case. Supersession cannot be ESTABLISHED, and the honest output
# is that it cannot — not a guess in the interesting direction.
_arm  evfix-noissue "$SHA_A" 2026-08-28T10:00:00-07:00 - reports/n.md
_disc evfix-noissue "$SHA_A" 2026-08-28T10:30:00-07:00 credible - sk-a asserted
_disc evfix-noissue "$SHA_B" 2026-08-28T11:00:00-07:00 suspect  - sk-b asserted-not-armed
# CONTROL C — evfix-noledger: no file is written at all, deliberately.
# CONTROL F — a TRUNCATED `discharged` row. All 69 rows in this nexus live
# corpus carry exactly 7 fields, so a short one is truncation, not an older
# schema; reading it as "a verdict exists" is the one wrong claim that is worse
# than the behaviour this replaces.
_arm  evfix-truncated "$SHA_A" 2026-08-28T15:54:10-07:00 338 reports/trunc.md
printf 'discharged\t%s\t2026-08-28T16:00:00-07:00\tcheck\n' "$SHA_B" \
    >> "$PEND/.evfix-truncated.ledger"

_evidence_of() { "$NG" skeptic-evidence "$1" --state-dir "$STATE" 2>/dev/null | sed -n '1p'; }
_class_of()    { _evidence_of "$1" | sed -n 's/.*[[:space:]]evidence=\([^[:space:]][^[:space:]]*\).*/\1/p'; }

echo '=== Each observed mechanism classifies as ITSELF ==='
assert_eq "amended report after arming -> unmatched-subject" \
    "$(_class_of evfix-amended)"    "unmatched-subject"
assert_eq "three arms, one discharge  -> ambiguous-arms" \
    "$(_class_of evfix-ambig)"      "ambiguous-arms"
assert_eq "re-armed a closed chain    -> rearm-after-close" \
    "$(_class_of evfix-rearm)"      "rearm-after-close"
assert_eq "matching hash, nothing open -> attributed" \
    "$(_class_of evfix-attributed)" "attributed"
# The FIFTH mechanism, and the one the machinery got WRONG rather than missed.
assert_eq "a LATER verdict after a matched one -> superseded-verdict" \
    "$(_class_of evfix-superseded)" "superseded-verdict"
_ev_sup=$(_evidence_of evfix-superseded)
assert_contains "…and the STANDING verdict is the LATER one" "$_ev_sup" "standing_verdict=credible"
assert_contains "…while the cleanly-attributed row is the SUPERSEDED one" \
    "$_ev_sup" "attributed_verdict=check"
assert_contains "…flagged on its own field, so no class precedence can hide it" \
    "$_ev_sup" "superseded=1"
# `asserted` is a CLEAN match, not an unrecognised detail. Counting it as
# unmatched reported a defect in a row that matched perfectly — a claim in the
# WRONG direction, and the live `clmd` ledger is what caught it.
assert_contains "an asserted row counts as MATCHED, not unmatched" "$_ev_sup" "matched=1"
assert_contains "…and only the genuinely unattached row is unmatched" "$_ev_sup" "unmatched=1"
# CONTROL G — the healthy multi-round case must NOT be called superseded.
assert_eq "CONTROL G: two arms, two MATCHED verdicts -> not superseded" \
    "$(_class_of evfix-tworound)" "attributed"
assert_contains "CONTROL G: …and superseded=0 explicitly" \
    "$(_evidence_of evfix-tworound)" "superseded=0"
# CONTROL H — the FORBIDDEN RULE, arriving as prose rather than as a gate.
_ev_diff=$(_evidence_of evfix-diffissue)
assert_contains "CONTROL H: two verdicts on DIFFERENT issues are NOT superseded" \
    "$_ev_diff" "superseded=0"
assert_contains "CONTROL H: …and the reason names the relation, checkably" \
    "$_ev_diff" "superseded_why=different-issues-unrelated-tasks"
assert_eq "CONTROL H: …so the class is not superseded-verdict" \
    "$(_class_of evfix-diffissue)" "unmatched-subject"
# CONTROL I — identical verdicts are a RE-RECORD, not a supersession.
_ev_rr=$(_evidence_of evfix-rerecord)
assert_contains "CONTROL I: the SAME verdict twice is NOT superseded" \
    "$_ev_rr" "superseded=0"
assert_contains "CONTROL I: …and says why" \
    "$_ev_rr" "superseded_why=same-verdict-re-recorded-not-superseded"
# CONTROL J — no issue field: it CANNOT be established, and says so.
_ev_ni=$(_evidence_of evfix-noissue)
assert_contains "CONTROL J: an absent issue field yields superseded=?" \
    "$_ev_ni" "superseded=?"
# The CLASS is the DEFINITE one — `unmatched-subject` — because
# `later-verdict-undetermined` now ranks BELOW the definite matching classes.
# An admission of ignorance about the SUPERSESSION question must not mask a
# class that answers the MATCHING question. The undetermined relation is not
# lost: it rides `superseded=?`, asserted just above, and its own clause.
assert_eq "CONTROL J: the DEFINITE class wins; \`cannot tell\` does not mask it" \
    "$(_class_of evfix-noissue)" "unmatched-subject"
# There is NO class for it, deliberately — see the ng comment. Assert the
# absence, so nobody re-adds an unreachable enum value.
assert_not_contains "CONTROL J: no unreachable 'undetermined' CLASS was left behind" \
    "$(_evidence_of evfix-noissue)" "evidence=later-verdict-undetermined"
# The issue fields are PRINTED, so a reader can check the relation themselves.
assert_contains "the standing and attributed ISSUES are both printed" \
    "$(_evidence_of evfix-superseded)" "standing_issue=1158"

echo
echo '=== CONTROL A/B/C — the SAFE direction: no verdict is ever invented ==='
# The fixture is verdict-free BY CONSTRUCTION, not by the classifier's say-so.
assert_eq "CONTROL A: evfix-noverdict ledger holds ZERO discharged rows" \
    "$(grep -c '^discharged' "$PEND/.evfix-noverdict.ledger" || true)" "0"
assert_eq "CONTROL A: an arm-only ledger classifies none — a verdict is ABSENT" \
    "$(_class_of evfix-noverdict)"  "none"
assert_eq "CONTROL B: malformed ledger holds ZERO discharged rows" \
    "$(grep -c '^discharged' "$PEND/.evfix-malformed.ledger" || true)" "0"
assert_eq "CONTROL B: an unparseable ledger classifies ? — asserts NOTHING" \
    "$(_class_of evfix-malformed)"  "?"
assert_no_file "CONTROL C: evfix-noledger genuinely has no ledger file" \
    "$PEND/.evfix-noledger.ledger"
assert_eq "CONTROL C: an absent ledger classifies none, not a verdict claim" \
    "$(_class_of evfix-noledger)"   "none"
assert_contains "CONTROL C: and says so — ledger=absent" \
    "$(_evidence_of evfix-noledger)" "ledger=absent"
assert_contains "a present ledger says ledger=present" \
    "$(_evidence_of evfix-attributed)" "ledger=present"
# The generic statement of the safe direction, over every verdict-free fixture.
_unsafe=0
for w in evfix-noverdict evfix-malformed evfix-noledger evfix-truncated; do
    case "$(_class_of "$w")" in
        unmatched-subject|ambiguous-arms|rearm-after-close|unmatched-other|attributed|prior-verdict-other-artefact|superseded-verdict)
            _unsafe=$(( _unsafe + 1 )) ;;
    esac
done
assert_eq "NO fixture without a WELL-FORMED verdict row yields a verdict-exists class" \
    "$_unsafe" "0"
assert_eq "CONTROL F: a TRUNCATED discharge row is ? — never a verdict claim" \
    "$(_class_of evfix-truncated)" "?"
assert_eq "CONTROL F: …and the fixture really is short (4 fields, not 7)" \
    "$(awk -F'\t' '$1=="discharged"{print NF}' "$PEND/.evfix-truncated.ledger")" "4"
# And the rows are exposed for audit rather than only summarised.
assert_contains "the verdict ROWS are printed, not just the class" \
    "$("$NG" skeptic-evidence evfix-amended --state-dir "$STATE" 2>/dev/null)" \
    "verdict at=2026-08-28T14:51:38-07:00 verdict=check issue=339 by=evfix-amended-sk detail=asserted-not-armed"

echo
echo '=== The MARKER gate (check 1b) now says WHICH it is ==='
# Every fixture gets a live pending marker: that is the gate that fired in all
# four observed windows, and its old wording — "required skeptic has not
# returned a verdict" — was the claim that was FALSE in every one of them.
_reasons=""
for w in evfix-amended evfix-ambig evfix-rearm evfix-attributed evfix-noverdict; do
    echo 1 > "$PEND/$w"
done
_reason_of() {
    bash "$PREFLIGHT" "$1" --pane-state idle --state-dir "$STATE" 2>/dev/null | sed -n '1p'
}
declare -A _want=(
    [evfix-amended]='evidence=unmatched-subject'
    [evfix-ambig]='evidence=ambiguous-arms'
    [evfix-rearm]='evidence=rearm-after-close'
    [evfix-attributed]='evidence=attributed'
    [evfix-noverdict]='evidence=none'
)
for w in evfix-amended evfix-ambig evfix-rearm evfix-attributed evfix-noverdict; do
    _r=$(_reason_of "$w")
    assert_contains "1b refusal for $w carries ${_want[$w]}" "$_r" "${_want[$w]}"
    assert_contains "CONTROL E: $w is still REFUSED (safe=0)" "$_r" "safe=0"
    _reasons+="${_r#*reason=}"$'\n'
done
# CONTROL D — vacuity. "each contains its tag" is satisfied by one constant
# clause if the clauses are not actually different.
assert_eq "CONTROL D: the five refusal reasons are PAIRWISE DISTINCT" \
    "$(printf '%s' "$_reasons" | sort -u | grep -c .)" "5"
# The fifth mechanism through the 1b gate, and the ORDERING clause.
echo 1 > "$PEND/evfix-superseded"
_r_sup=$(_reason_of evfix-superseded)
assert_contains "1b refusal carries evidence=superseded-verdict" "$_r_sup" "evidence=superseded-verdict"
assert_contains "…and names the STANDING verdict" "$_r_sup" 'STANDING verdict is `credible`'
assert_contains "…and the SUPERSEDED one it must not be confused with" "$_r_sup" 'attributed row says `check`'
assert_contains "CONTROL E: it is still REFUSED" "$_r_sup" "safe=0"
# THE PRECEDENCE CONTROL. `rearm-after-close` outranks `superseded-verdict`, so
# a ledger carrying BOTH must still surface the supersession — it rides its own
# clause precisely so a class winner cannot hide it.
_arm  evfix-both "$SHA_A" 2026-08-28T10:00:00-07:00 1158 reports/both.md
_disc evfix-both "$SHA_A" 2026-08-28T10:30:00-07:00 check    1158 evfix-both-sk asserted
_disc evfix-both "$SHA_B" 2026-08-28T11:00:00-07:00 credible 1158 evfix-both-sk asserted-not-armed
_res  evfix-both 2026-08-28T11:30:00-07:00 "skeptic-channel.sh close" "end of pairing"
_arm  evfix-both "$SHA_C" 2026-08-28T12:00:00-07:00 1158 reports/both.md
echo 1 > "$PEND/evfix-both"
assert_eq "a ledger with BOTH states classifies rearm-after-close (it explains the refusal)" \
    "$(_class_of evfix-both)" "rearm-after-close"
_r_both=$(_reason_of evfix-both)
assert_contains "…and the supersession is STILL named, not hidden by precedence" \
    "$_r_both" "SUPERSEDED (same issue"

# The three relations through the 1b gate. `Take the LATER one` is an
# instruction that DISCARDS a verdict; it may appear only where supersession was
# positively established.
for w in evfix-diffissue evfix-rerecord evfix-noissue; do echo 1 > "$PEND/$w"; done
_r_diff=$(_reason_of evfix-diffissue)
_r_rr=$(_reason_of evfix-rerecord)
_r_ni=$(_reason_of evfix-noissue)
assert_not_contains "CONTROL H: different issues -> the refusal does NOT say take the later one" \
    "$_r_diff" "Take the LATER one"
assert_not_contains "CONTROL I: identical verdicts -> no SUPERSEDED clause at all" \
    "$_r_rr" "SUPERSEDED"
assert_not_contains "CONTROL J: unestablished -> still does NOT say take the later one" \
    "$_r_ni" "Take the LATER one"
assert_contains "CONTROL J: …it says the relation CANNOT BE ESTABLISHED" \
    "$_r_ni" "CANNOT BE ESTABLISHED"
assert_contains "…and the established case still names the issue it matched on" \
    "$_r_sup" 'SUPERSEDED (same issue `1158`)'

# A marker with NO LEDGER AT ALL must still say `none`. retire-preflight skips
# the probe there for cost, and the skip must carry the finding rather than
# leaving the class empty — an empty class selects the DOUBT wording, which
# would make "nobody ever armed this window" indistinguishable from "could not
# look": this change's own defect, reintroduced by its own optimisation.
echo 1 > "$PEND/evfix-noledger"
assert_contains "a marker with NO ledger still classifies the absence as evidence=none" \
    "$(_reason_of evfix-noledger)" "evidence=none"

# CONTROL B, second half: doubt prints NOTHING rather than a guess.
echo 1 > "$PEND/evfix-malformed"
_r_bad=$(_reason_of evfix-malformed)
assert_contains "CONTROL B: an unparseable ledger still REFUSES" "$_r_bad" "safe=0"
assert_not_contains "CONTROL B: …and makes NO evidence= claim" "$_r_bad" "evidence="
# `superseded=?` HAS TWO PRODUCERS, and only one is a finding: rows parsed with
# an absent issue field, versus a ledger not parsed at all (the `ev == "?"`
# doubt-fold sets every count to `?` including this one). Folding only the CLASS
# let the second reach the `?` clause, which then asserted "A LATER verdict row
# exists after the attributed one" for a ledger where NOTHING was read — a claim
# where nothing was established, inside the change whose thesis is that a
# refusal's words must be true. The fold keys on `superseded_why` for that
# reason: `-` for the doubt-fold, a named relation for a real finding.
assert_not_contains "CONTROL B: …and makes NO supersession claim either" \
    "$_r_bad" "LATER verdict row exists"
# THE DOUBT PATH MUST STILL NAME A WAY OUT. The clause is empty here by design;
# if the remedy lived only in the clause, the `?` case would name none at all —
# a gate with no exit, which trains its own bypass.
assert_contains "CONTROL B: …but still names the sanctioned remedy" \
    "$_r_bad" "ng skeptic resolve"
# And the audit rows may not contradict the class: a ledger classified `?`
# BECAUSE of a truncated row must not display that row as a verdict.
_dump_trunc=$("$NG" skeptic-evidence evfix-truncated --state-dir "$STATE" 2>/dev/null)
assert_contains "a truncated row is dumped as TRUNCATED" "$_dump_trunc" "verdict-row TRUNCATED"
assert_not_contains "…and NOT as a verdict the summary refused to count" \
    "$_dump_trunc" "verdict=check"

echo
echo '=== The PER-TASK gate (check 1be) distinguishes them too ==='
# Same ledgers, no marker: the refusal now comes from the obligation-arms gate.
for w in evfix-amended evfix-noverdict; do rm -f "$PEND/$w"; done
_r_1be_bad=$(_reason_of evfix-amended)
_r_1be_none=$(_reason_of evfix-noverdict)
assert_contains "1be refusal names the DELIVERED-but-unmatched verdict" \
    "$_r_1be_bad" "evidence=unmatched-subject"
assert_contains "1be refusal names a genuinely absent verdict as absent" \
    "$_r_1be_none" "evidence=none"
assert_contains "CONTROL E: 1be still refuses on the unmatched verdict" "$_r_1be_bad" "safe=0"
assert_eq "the two 1be reasons DIFFER" \
    "$( [[ "$_r_1be_bad" != "$_r_1be_none" ]] && echo yes || echo no )" "yes"

echo
echo '=== The TWO-LEDGER desync is named on the obligation edge (#845 gate) ==='
# `annzmerge` / `overlaycontent`: the skeptic ledger is fully settled — matching
# hash, `attributed` — while `$STATE_DIR/obligations` still holds a live edge.
# The old refusal said "discharge with a verdict", i.e. redo work already done.
if [[ -r "$REPO_ROOT/monitor/_obligations.sh" ]]; then
    # shellcheck source=monitor/_obligations.sh
    . "$REPO_ROOT/monitor/_obligations.sh"
    obl_open "$STATE" evfix-debtor  evfix-attributed skeptic-verdict test "paired reviewer" >/dev/null 2>&1
    obl_open "$STATE" evfix-debtor2 evfix-noverdict  skeptic-verdict test "paired reviewer" >/dev/null 2>&1
    # `OBL_TMUX_WINDOWS` is `_obligations.sh`'s own documented test seam: the
    # creditor-absent release keys on tmux window existence, and injecting the
    # list exercises that LOGIC without a real server — which also keeps this
    # suite off the 107-byte socket-path trap (#991) entirely.
    assert_eq "the obligation edge was actually opened" \
        "$( [[ -e "$STATE/obligations/evfix-debtor__evfix-attributed__skeptic-verdict.rec" ]] \
            && echo yes || echo no )" "yes"
    _live_wins=$'evfix-attributed\nevfix-noverdict\nevfix-debtor\nevfix-debtor2'
    _reason_of_paired() {
        OBL_TMUX_WINDOWS="$_live_wins" \
            bash "$PREFLIGHT" "$1" --pane-state idle --state-dir "$STATE" 2>/dev/null | sed -n '1p'
    }
    _r_desync=$(_reason_of_paired evfix-debtor)
    _r_plain=$(_reason_of_paired evfix-debtor2)
    assert_contains "the desync case names TWO-LEDGER DESYNC" "$_r_desync" "TWO-LEDGER DESYNC"
    assert_contains "CONTROL E: it is still refused" "$_r_desync" "safe=0"
    assert_not_contains "a creditor with NO verdict is NOT called a desync" \
        "$_r_plain" "TWO-LEDGER DESYNC"
else
    th_abort "monitor/_obligations.sh not readable — cannot exercise the #845 gate"
fi

echo
echo '=== The ORPHAN advice sites, found by MEANING rather than by wording (#1153) ==='
# `orphaned-skeptic-pending` used to say "spawn the skeptic or clear the
# marker". BOTH arms are wrong when the verdict was DELIVERED and the record
# could not match it: spawning manufactures work against a reviewer that has
# already discharged, and clearing the marker ALSO voids a live obligation
# derivedly (#961). So every site emitting that advice must send the reader to
# `ng skeptic-evidence` first.
#
# ── WHY THIS LINT WAS REBUILT, WHICH IS THE MORE IMPORTANT HALF ────────────
#
# The first version pinned a population of 3 by counting lines carrying BOTH
# the class name AND a remedy phrase. `_idle_probe.sh` sets
# `bg_child_class="orphaned-skeptic-pending"` on one line and its advice string
# on the NEXT, so a fourth site was invisible to it — a guard keyed on
# CO-OCCURRENCE WITHIN A LINE, defeated by a line break, certifying a population
# it never checked. Two independent narrowings, both fixed here:
#
#   1. ANCHOR ON MEANING, NOT ON THE WORDING BEING REPLACED. The population is
#      every line emitting the claim "no live skeptic". A lint keyed on the
#      remedy phrasing goes QUIET the moment it succeeds — nothing says
#      "spawn or clear" any more — and cannot see a new site written with
#      different words. Measured: the wording-keyed predicate matches ONE line
#      on this tree; the meaning-keyed one matches five.
#   2. WINDOW THE CHECK ACROSS LINES, because the emission itself spans them.
#
# Scope is the whole PRODUCTION tree, not one file: widening it is what found
# the FIFTH site, in `retire-preflight.sh` — the orphan fall-through, and the
# one path that ALLOWS the kill.
IDLE_PROBE="$REPO_ROOT/monitor/watcher/_idle_probe.sh"
assert_file_exists "the idle probe is readable" "$IDLE_PROBE"
# EXEMPTIONS, DECLARED AS DATA WITH A REASON, and keyed on a DISTINCTIVE
# SUBSTRING OF THE LINE rather than on a path. Path-scoped exemptions excused
# the whole of `monitor/ng` and the whole of `monitor/skeptic-channel.sh` — 6 of
# the 12 sites — while each stated reason was about ONE construct
# (skledgsk2 round 3). Each key is asserted to still MATCH A POPULATION MEMBER,
# so editing an exempted line back into advice reds rather than staying excused.
_ORPH_EXEMPT="awk '/^# skeptic-pending marker resolved/|an awk PARSER reading the marker-resolved comment out of a rationale file; emits no advice
printf '# skeptic-pending marker resolved via|WRITES that comment INTO the rationale file; a record, not operator-facing advice
printf 'resolved skeptic-pending marker for %s|a success CONFIRMATION after the fact, not advice about what to do next"

# ── NO WINDOW, NO ROUTER INDIRECTION ──────────────────────────────────────
#
# The verb must appear on the anchor's OWN logical line. Both relaxations that
# used to exist were laundering channels, and each was the same defect one
# generation on — this lint has now been defeated at the line, at the 8-line
# window, and at the router name:
#
#   PROXIMITY.  A bad advice line was cleared by an unrelated NEIGHBOUR that
#               happened to mention the verb within the budget.
#   ROUTER.     A call to a same-file helper whose body names the verb counted.
#               The membership scan never reset `cur` at a closing brace, so
#               "the body of F" was really "every line from F's header to the
#               NEXT header" — top-level code included. Measured at 23c2f18,
#               `emit` (the function EVERY verdict line in retire-preflight.sh
#               calls) was attributed a body it does not have; combined with a
#               bare-substring test, any advice line containing the four letters
#               `emit` — `emitted`, `emits` — was auto-cleared.
#
# Rather than a fourth generation of cleverness, the mechanism is REMOVED. It
# cost four sites, each of which now names the verb in its own message — which
# is better for the operator reading it anyway, since the command is in the text
# rather than one indirection away.
_orph_lint() {
    awk -v F="$1" '
        { raw[NR] = $0; iscomment[NR] = ($0 ~ /^[[:space:]]*#/) }
        END {
            for (i = 1; i <= NR; i++) {
                if (iscomment[i]) continue
                logical = raw[i]; last = i
                while (logical ~ /\\$/ && last < NR) { last++; sub(/\\$/, " ", logical); logical = logical raw[last] }
                L = tolower(logical)
                isA = (L ~ /no live skeptic/)                                             # the CLAIM
                isB = (L ~ /skeptic-pending marker/) && (L ~ /spawn|clear|waive|resolve/)  # the REMEDY
                if (!isA && !isB) continue
                printf "%s:%d %s %s\n", F, i, (logical ~ /skeptic-evidence/ ? "OK" : "BAD"), \
                    (isA && isB ? "A+B" : (isA ? "A" : "B"))
            }
        }' "$1"
}
_orph_all=""
while IFS= read -r _f; do
    [[ -n "$_f" && -r "$REPO_ROOT/$_f" ]] || continue
    _orph_all+="$(_orph_lint "$REPO_ROOT/$_f")"$'\n'
done < <(git -C "$REPO_ROOT" ls-files -- ':(glob)monitor/*.sh' ':(glob)monitor/watcher/*.sh' monitor/ng \
         | grep -v '/test-')
_orph_n=$(grep -c ' \(OK\|BAD\) ' <<<"$_orph_all" || true)
# Drop the DECLARED exemptions, then require zero violations of what remains.
_orph_bad_list=$(grep ' BAD ' <<<"$_orph_all" || true)
_orph_bad="$_orph_bad_list"
while IFS='|' read -r _xkey _xwhy; do
    [[ -n "$_xkey" ]] || continue
    [[ -n "$_xwhy" ]] || bad "exemption carries a reason" "none for: $_xkey"
    # The key must still identify a line that IS in the population — otherwise a
    # stale exemption silently excuses nothing while looking like coverage.
    # First line WITHOUT a pipe: `| head -1` is an early-exit reader, and adding
    # one would enrol this suite in `early-exit-readers.manifest` — a population
    # whose whole point is that a closing reader can invert a writer's status
    # under pipefail. Parameter expansion takes the first line and closes nothing.
    _xline=$(grep -nF -- "$_xkey" "$REPO_ROOT/monitor/ng" "$REPO_ROOT/monitor/skeptic-channel.sh" 2>/dev/null)
    _xline="${_xline%%$'\n'*}"
    assert_eq "exemption key still matches a real line: ${_xkey:0:34}" \
        "$( [[ -n "$_xline" ]] && echo yes || echo no )" "yes"
    _xf="${_xline%%:*}"; _xn="${_xline#*:}"; _xn="${_xn%%:*}"
    _orph_bad=$(grep -v "${_xf##*/}:${_xn} BAD" <<<"$_orph_bad" || true)
done <<<"$_ORPH_EXEMPT"
_orph_bad=$(grep -c . <<<"$(grep ' BAD ' <<<"$_orph_bad" || true)" || true)
[[ "$_orph_bad" == "0" ]] || printf '  offenders:\n%s\n' "$_orph_bad_list" >&2
assert_eq "every non-exempt site routes to ng skeptic-evidence" "$_orph_bad" "0"
# KEYED ON CONTENT, NOT ON A LINE NUMBER (your-org/nexus-code#1171 review).
#
# This assertion pinned `_idle_probe.sh:3551` literally. There are 3551 lines
# above that site, so ANY change inserting a line into ANY of them renumbers it
# and reddens this suite — while both branches are green ALONE. Measured against
# `#1171`: `dev` @ `3bba40a` 98/0, the MERGE RESULT 97/1, `git merge-tree`
# reporting ZERO conflicts. **A clean textual merge is not a correct merge**, and
# building the merge result is the only thing that showed it (CLAUDE.md `#1163`).
#
# PATCHING THE NUMBER WOULD BE THE SECOND-WORST OUTCOME AFTER NOT NOTICING: it
# goes green and expires at the next PR to touch this file.
#
# AND THE ARITHMETIC IS NOT THE TRAP — THE AMBIGUITY OF "THE SITE" IS. `3551 + 24
# = 3575` reconciles exactly: 24 lines entered `_idle_probe.sh` on that merge and
# the escaped site does land at 3575. What is easy to get wrong is WHICH line the
# site is. The `bg_child_class` line sits immediately above at 3550 (3574 after
# the merge) and is NOT in the population — the lint is about where the ADVICE
# lives, so only the `bg_child_detail` string is a site. Keying on the class line
# was tried first here and passed its existence check while failing the
# population check, which is exactly how it was caught. Two adjacent lines, one
# of them a site, no way to tell from a number.
#
# The suite already contained the right idiom: the exemption machinery above keys
# on `$_xkey` CONTENT via `grep -nF` and DERIVES the line. This was the one place
# that did not use it. `grep -nF` with the first line taken by parameter
# expansion, never `| head -1` — that would enrol this suite in
# `early-exit-readers.manifest`, for the reason stated there.
#
# Measured, not assumed: the population contains `_idle_probe.sh:3551 OK` and no
# row for 3550.
#
# UNIQUENESS IS ASSERTED, not assumed. The obvious shorter key
# (`run \`ng skeptic-evidence $name\` FIRST`) appears TWICE — at 3551 and at the
# `_idle_probe.sh` summary emitter — and "first match wins" would have silently
# pinned whichever moved first. An ambiguous key is a line number with extra
# steps.
_esc_key='bg_child_detail="skeptic-pending marker but no live skeptic past grace'
_esc_hits=$(grep -nF -- "$_esc_key" "$REPO_ROOT/monitor/watcher/_idle_probe.sh" 2>/dev/null)
_esc_count=$(grep -c . <<<"$_esc_hits" || true)
_esc_n="${_esc_hits%%$'\n'*}"; _esc_n="${_esc_n%%:*}"
# Non-vacuity, load-bearing in the DANGEROUS direction: an unresolved key leaves
# `$_esc_n` empty, and `assert_contains … "_idle_probe.sh:"` would then match ANY
# `_idle_probe.sh` row in the population and pass while asserting nothing.
assert_eq "the ESCAPED site's content key resolves to EXACTLY ONE line (not zero, not two)" \
    "$_esc_count" "1"
assert_contains "…and the site that ESCAPED the first lint is in the population" \
    "$_orph_all" "_idle_probe.sh:$_esc_n"
assert_contains "…as is the fifth, in retire-preflight (the path that ALLOWS the kill)" \
    "$_orph_all" "retire-preflight.sh:"
# NON-VACUITY: the lint must FAIL on the exact shape that defeated its
# predecessor — class and advice split across two lines, no `skeptic-evidence`.
cat > "$WORK/planted.sh" <<'PLANT'
#!/usr/bin/env bash
emit_it() {
    local cls detail
    cls="orphaned-skeptic-pending"
    detail="skeptic-pending marker but no live skeptic past grace — spawn the skeptic or clear the marker"
    printf '%s %s\n' "$cls" "$detail"
}
PLANT
assert_contains "NON-VACUITY: the split-across-lines shape is caught, not missed" \
    "$(_orph_lint "$WORK/planted.sh")" "BAD"
# NON-VACUITY 2 — THE ROUTER ESCAPE, verbatim from skledgsk2's demonstration.
# `helper` has ZERO hits in its real body; the top-level printf AFTER its closing
# brace was mis-attributed to it, because the membership scan never reset at `}`.
# The advice below routes NOWHERE and must be flagged: it was cleared purely by
# naming a function that is not a router. With the router mechanism removed this
# cannot happen, and this control is what says so.
cat > "$WORK/router-escape.sh" <<'ESCAPE'
#!/usr/bin/env bash
helper() { printf 'nothing to do here\n'; }
printf 'see ng skeptic-evidence for the rows\n'
advise() {
    printf 'skeptic-pending marker but no live skeptic past grace — spawn the skeptic or clear the marker (see helper)\n'
}
ESCAPE
assert_contains "NON-VACUITY: the ROUTER-ESCAPE shape is caught, not laundered" \
    "$(_orph_lint "$WORK/router-escape.sh")" "BAD"
# …and the same file with the verb ACTUALLY on the advice line passes, so the
# control discriminates rather than always failing.
sed 's/(see helper)/(run `ng skeptic-evidence`)/' \
    "$WORK/router-escape.sh" > "$WORK/router-fixed.sh"
assert_not_contains "…while naming the verb ON the line does pass (it discriminates)" \
    "$(_orph_lint "$WORK/router-fixed.sh")" "BAD"
# NON-VACUITY 3 — PROXIMITY LAUNDERING, the other channel (skledgsk2 round 1
# finding 4, still alive at round 3). A bad advice line cleared by an UNRELATED
# NEIGHBOUR that merely mentions the verb. I claimed one fix covers both
# channels; this is the assertion that says so rather than my saying so.
cat > "$WORK/proximity.sh" <<'PROX'
#!/usr/bin/env bash
advise() {
    printf 'skeptic-pending marker but no live skeptic past grace — spawn the skeptic or clear the marker\n'
    printf 'unrelated: see ng skeptic-evidence for something else entirely\n'
}
PROX
assert_contains "NON-VACUITY: a NEIGHBOUR mentioning the verb does not launder the line" \
    "$(_orph_lint "$WORK/proximity.sh")" "BAD"
# ── THE ADVICE MUST BE ACCURATE, NOT MERELY ROUTED (skledgsk2 Q3) ─────────
#
# The lint above guards ROUTING — every advice site sends the reader to
# `ng skeptic-evidence`. It says nothing about whether what the advice then
# CLAIMS is true, and finding (3) on #1168 was exactly an inaccurate claim:
# "ANY other class means a verdict was DELIVERED", false for four of twelve
# classes. Routing a reader accurately to a verb and then mis-describing its
# output is the same defect one step later.
#
# So the class vocabulary is COUPLED. `ng` is the authority — the classes are
# its `ev = "..."` assignments — and every one must be named in the operator
# advice. Add a class to `ng` without teaching the advice about it and this
# reddens, which is the only thing that keeps an enumeration honest as it grows.
# EXTRACTION (skledgsk2 B3). `ev = "` requires the literal spelling WITH spaces.
# A 13th class written `ev="drifted-class"` — an ordinary awk spelling — evaded
# it, the count stayed 12, the pin stayed satisfied, and the class was never
# required to be documented. Measured: old form 11, `ev *= *"` form 12 on the
# same mutant. Note the DIRECTION: a pin is a non-vacuity control against
# returning TOO FEW; it cannot see an extraction that returns the right COUNT
# while MISSING A MEMBER (#946 F1's shape).
_advice_line=$(grep 'orphaned-skeptic-pending (idle' "$IDLE_PROBE")
assert_eq "the operator advice line was found" \
    "$( [[ -n "$_advice_line" ]] && echo yes || echo no )" "yes"
_ng_classes=$(grep -oE 'ev *= *"[a-z?][a-z-]*"' "$NG" | sed 's/ev *= *"//; s/"//' | sort -u)
_ng_n=$(grep -c . <<<"$_ng_classes")
assert_eq "ng declares 13 evidence classes" "$_ng_n" "13"

# SIDES, from the ONE authority in ng, checked as SET EQUALITY PER GROUP.
# The previous four assertions were labelled "advice puts <c> on the
# cannot-establish side" while their code was assert_contains over the WHOLE
# line — already implied by the naming loop above them, so they could not fail
# independently (skledgsk2 B1: moving `discharge-without-verdict` to the
# delivered side left the suite green). And the needle for `?` was ONE
# CHARACTER, satisfied by any question mark anywhere on the line (B2).
# Executed, not re-parsed — the authority's own code produces this, so there is
# no second implementation to drift. Piped into `bash` rather than sourced from
# a process substitution: `. <(…)` adds a source token the shell-option graph
# cannot statically resolve, and `test-ambient-shell-option-scope` reds on a new
# unresolvable shape. Avoiding the construct beats enrolling it in that manifest.
_sides=$( { sed -n '/^_skeptic_evidence_sides()/,/^}/p' "$NG"; echo '_skeptic_evidence_sides'; } | bash )
assert_eq "the side authority declares 3 groups" "$(grep -c . <<<"$_sides")" "3"
# 1. every class ng can emit is on exactly one side — catches a class added to
#    the classifier and never filed.
_side_tokens=$(cut -f2 <<<"$_sides" | tr '|' '\n' | tr -d ' ' | grep -c .)
assert_eq "the sides account for all 13 classes, no more and no less" \
    "$_side_tokens" "$_ng_n"
_unfiled=""
while IFS= read -r _c; do
    [[ -n "$_c" ]] || continue
    grep -qE "(^|[|[:space:]])${_c//\?/\\?}([|[:space:]]|$)" <<<"$(cut -f2 <<<"$_sides")" || _unfiled+="$_c "
done <<<"$_ng_classes"
assert_eq "every class ng emits is FILED on a side" "$_unfiled" ""
# 2. the advice carries each group's token list VERBATIM — set equality per
#    segment, which substring-anywhere is not, and which a stray `?` cannot fake.
_adv_missing=""
while IFS=$'\t' read -r _name _tokens; do
    [[ -n "$_tokens" ]] || continue
    grep -qF -- "[$_tokens]" <<<"$_advice_line" || _adv_missing+="$_name "
done <<<"$_sides"
[[ -z "$_adv_missing" ]] || printf '  advice groups not carried verbatim: %s\n' "$_adv_missing" >&2
assert_eq "the advice carries every side group VERBATIM, in order" "$_adv_missing" ""

# And the emitted DETAIL an orchestrator reads names the live-obligation hazard.
# Comment lines also say "past grace", and taking the first two picked up two of
# THOSE — the same read-the-wrong-population shape this section is about. Only
# the EMITTED assignments count, and THE ONE that exists must name the hazard.
_orph_detail=$(grep -n 'bg_child_detail=' "$REPO_ROOT/monitor/watcher/_idle_probe.sh" \
    | grep 'past grace' || true)
# OCCURRENCES, NOT LINES (your-org/nexus-code#1016 R1). Chosen by measurement,
# not by mechanically applying the lint's remedy — the lint offers two, and a
# comment saying "lines are genuinely the unit" would have been the wrong one.
#
# The subject of this assertion is an ASSIGNMENT. `grep -c` counts matching
# LINES, so two `bg_child_detail=…past grace…` assignments squeezed onto one
# physical line read as ONE and the pin stays satisfied — exactly the `foo; foo`
# defeat R1 names. Measured against that mutant on this tree:
#
#   line-unit   `grep -c .`                          -> 2
#   occurrence  `grep -o 'bg_child_detail=' | wc -l` -> 3
#
# Both forms answer 1 on the clean tree, which is why the divergence has to be
# provoked to be seen. `grep -o … | wc -l` is the lint's own remedy and is
# explicitly never flagged by it.
#
# The bound is unchanged and worth restating: a census pins MEMBERSHIP, never
# PLACEMENT — moving the single assignment into another branch still counts 1.
assert_eq "exactly 1 emitted orphan DETAIL assignment" \
    "$(grep -o 'bg_child_detail=' <<<"$_orph_detail" | wc -l)" "1"
assert_contains "…and it names the live-obligation hazard" "$_orph_detail" "voids a LIVE obligation"

echo
echo '=== This suite does not itself carry a live #1157 substitution ==='
# A LIVE BACKTICK SUBSTITUTION INSIDE AN ASSERTION LABEL (your-org/nexus-code#1157).
# This delta introduced one: `assert_eq "… wins; \`cannot tell\` does not mask it"`
# evaluated to "… wins;  does not mask it" with `bash: cannot: command not found`
# on stderr — the token DELETED, the 127 landing on an argument nobody tests, and
# the corrupted label still reading as grammatical prose. It was found in a real
# FAIL line, not by grepping, which is the whole #1157 lesson.
#
# SCOPE, stated because it is narrow: this checks THIS FILE, over the
# label-taking helpers it actually uses — `assert_*`, and `bad`/`ok`, which the
# exemption-reason check calls. It is not a repo-wide #1157 lint — no
# suite in this tree references #1157 at all — and detecting "inside a
# double-quoted string" reliably across shell + embedded awk is not something a
# grep can promise. Two neighbours that LOOK like instances are not:
# `monitor/ng` escapes its backticks, and `_idle_probe.sh` sits inside a
# single-quoted awk program the shell never expands.
# THE PROBE MATCHED ITS OWN DEFINITION — the self-recognition class the
# workspace documents for `monitor/tmuxwrap/tmux`, where a wrapper scanning
# candidates for its own PATH classified a legitimate CALLER as a copy of
# itself. The prescribed remedy there is an OWNED MARKER the thing writes into
# lines it owns, and that is what `# bt-scan-self` is. A corpus this small and
# this repo-controlled is exactly where an owned marker is the right answer.
#
# A REGEX CANNOT TRACK SHELL QUOTE STATE, and my first attempt proved it: it
# flagged four lines whose backticks sit inside SINGLE quotes, where the shell
# never expands them. A predicate keyed on a property it cannot determine is the
# same class as everything else this suite is about, so this WALKS the line and
# tracks the state instead — a backtick counts only when it is inside a
# double-quoted region and not backslash-escaped.
_bt_scan() {
    awk '
        { raw[NR] = $0 }
        END {
            for (n = 1; n <= NR; n++) {
                if (raw[n] ~ /^[[:space:]]*#/) continue
                if (raw[n] ~ /bt-scan-self/) continue
                # JOIN CONTINUATIONS FIRST. A per-line walker sees a backtick on
                # line ONE of a split label regardless of the split, so a control
                # that plants it there passes without touching the hazard — the
                # hazard is the backtick on line TWO. `_orph_lint`, one function
                # away in this file, already joins; this did not.
                line = raw[n]; last = n
                while (line ~ /\\$/ && last < NR) { last++; sub(/\\$/, " ", line); line = line raw[last] }
                if (line ~ /bt-scan-self/) { n = last; continue }
                # LABEL-TAKING HELPERS, in command position. Requiring the literal
                # `assert_` dropped every `bad "…"` / `ok "…"` call out of scope —
                # a regression, and this file has one at the exemption-reason
                # check. The scope sentence claimed "every label is an assert_*
                # argument", which was false here by one line.
                if (match(line, /(^|[;&|]|[[:space:]])(assert_[a-z_]*|bad|ok)[[:space:]]/) == 0) { n = last; continue }
                rest = substr(line, RSTART + RLENGTH)
                q = index(rest, "\"")
                if (q == 0) { n = last; continue }
                lbl = ""; esc = 0
                for (i = q + 1; i <= length(rest); i++) {
                    c = substr(rest, i, 1)
                    # An ESCAPED character cannot start a substitution, so it
                    # becomes a neutral placeholder rather than being copied.
                    # Copying it made this flag the escaped form it prescribes.
                    if (esc)            { esc = 0; lbl = lbl "_"; continue }
                    if (c == "\\")      { esc = 1; continue }
                    if (c == "\"")      break
                    lbl = lbl c
                }
                if (lbl ~ /`/ || lbl ~ /\$\(/) { print FILENAME ":" n }   # bt-scan-self
                n = last
            }
        }' "$1"
}
_bt_live=$(_bt_scan "$0" | grep -c . || true)
assert_eq "no unescaped backtick survives inside a quoted label in this suite" \
    "$_bt_live" "0"
# POSITIVE-CONTROL BATTERY, VARYING THE SPELLING RATHER THAN REPEATING THE PLANT.
# A lint that only sees the spelling it was built from is #1170's class, and this
# PR has already produced three instances of it. So the control does not re-plant
# the one instance that motivated the guard — it varies the axis the DEFECT
# varies on. Measured: the first version of this walker knew only backticks and
# MISSED `$(…)`, which is the same defect in the other spelling.
_bt_case() {   # <name> <expected-hits> <line…>
    local _name="$1" _want="$2"; shift 2
    printf '%s\n' "$@" > "$WORK/bt-$_name.sh"
    assert_eq "#1157 probe — $_name" \
        "$(_bt_scan "$WORK/bt-$_name.sh" | grep -c . || true)" "$_want"
}
_bt_case as-built  1 'assert_eq "planted: `cannot tell` here" "$a" "$b"'   # bt-scan-self
_bt_case moved     1 'assert_eq "trailing tail `oops`" "$a" "$b"'   # bt-scan-self
_bt_case dollar    1 'assert_eq "planted: $(cannot tell) here" "$a" "$b"'   # bt-scan-self
_bt_case split     1 'assert_eq "split label continues \' '  with `cannot tell` on line TWO" "$a" "$b"'   # bt-scan-self
# NEGATIVE CONTROLS — without these the probe could pass by flagging everything.
_bt_case singleq   0 "assert_contains \"label\" \"\$out\" 'verdict is \`credible\`'"   # bt-scan-self
# THE GUARD MUST NOT RED ON ITS OWN PRESCRIBED FIX. It did: the label extractor
# copied escaped characters into the string it tests, so the escaped form — the
# very one the diagnostic tells you to use — was flagged. A lint that reds on
# its own remedy trains its own bypass.
_bt_case escaped   0 'assert_eq "escaped \`is fine\` here" "$a" "$b"'   # bt-scan-self
# A `bad`-labelled call is in scope too: requiring the literal `assert_` dropped
# every one of them, and this file makes such a call itself.
_bt_case bad-label 1 'if [[ -z "$x" ]]; then bad "a `cannot tell` label" "detail"; fi'   # bt-scan-self
_bt_case value-sub 0 'assert_eq "legit value use" "$(_class_of x)" "attributed"'   # bt-scan-self


# EXPECTED-COUNT GUARD (your-org/nexus-code#807; required by
# test-summary-honesty-manifest.sh at the `ledger=yes` protection level).
# Every assertion is unconditional — the one conditional arm aborts rather than
# skipping — so this is a literal constant, DERIVED PER SECTION rather than
# observed. (It has already earned its keep twice on this branch by catching my
# own arithmetic, so the derivation is stated to be checkable, not trusted.)
#
#   20  classification: 5 mechanisms + the supersession fields + CONTROLS G/H/I/J
#                       (the four verdict-RELATION controls) + the printed issues
#   12  CONTROLS A/B/C/F: verdict-free by construction, `?`, absent, truncated,
#                         ledger=present, and the generic safe-direction sweep
#   27  the 1b marker gate: 8 fixtures x (class tag + safe=0), the pairwise-
#                           distinct control, the three relation refusals, the
#                           precedence control, the doubt path's remedy and its
#                           non-contradicting audit rows
#    1  a marker with no ledger at all still reports `none`, not doubt
#       (and the doubt path makes no supersession claim: counted in the 27)
#    4  the 1be per-task gate
#    4  the #845 two-ledger gate
#   21  the #1153 orphan-advice lint (9): 12-site population unioning the CLAIM
#       and the REMEDY enumerations, zero non-exempt violations, two declared
#       exemptions each asserted to still exist, both previously-invisible sites,
#       the split-line control, the ROUTER-ESCAPE control and its discriminating
#       twin, and the emitted DETAIL hazard clause;
#       PLUS the vocabulary + SIDE coupling (12): the advice line is found, 11
#       classes extracted with a spelling-tolerant pattern (B3), 3 side groups
#       from the one authority in ng, the sides account for every class and no
#       more, every class is filed, and each group is carried VERBATIM by the
#       advice — set equality per segment, which substring-anywhere is not (B1/B2): population pinned at 5, zero
#       violations, both previously-invisible sites named, the split-line
#       non-vacuity control, the emitted DETAIL's hazard clause; PLUS the
#       vocabulary coupling (6): 12 classes pinned, all named in the advice,
#       and the four cannot-establish classes present

echo
echo '=== #1191 — THE TERMINAL VERDICT WAS THE ONE THAT COULD NOT LAND ==='
#
# `_skeptic_record_discharge` used to `return 0` having written NOTHING when the
# outstanding set was EMPTY. A chain whose last round was cleanly attributed has
# no open arm left, so the verdict that CONCLUDES it arrives against an empty set
# and was dropped — every intermediate verdict re-arms and lands, and the one
# that says "this is done" had nothing to attach to.
#
# Measured on the live `.olimit2.ledger` before the fix: two `check` rounds both
# `attributed`, `open=0`, and then THREE `credible` verdicts filed by the
# documented verb which left the file BYTE-IDENTICAL. `your-org/nexus-code#1171`
# merged on the third of them while `ng skeptic-evidence olimit2` reported
# `standing_verdict=check`.
#
# THE WRITER IS DRIVEN, NOT A PLANTED ROW. A fixture carrying a `no-open-arm`
# row tests only the reader, and the reader was never the defect — it is the one
# component that already did the right thing with a row it never received. So
# these assertions call `_skeptic_record_discharge` and compare the ledger before
# and after; pre-fix the count does not move.
#
#   "a verdict with nothing outstanding is RECORDED"
#       kill: restore the `no-arm-on-record` early return -> got 2 want 3
#   "CONTROL: a key with NO ledger still records nothing"
#       kill: drop the `[[ -e "$ledger" ]]` guard -> the file appears
#   "the recovered row closes nothing"
#       kill: emit the last-armed sha instead of `-` -> the arm is suppressed
#   "the olimit2 shape reports the DELIVERED verdict as standing"
#       kill: any of the above -> standing_verdict=check, the shipped-on answer
_SK_A=aaaaaaaa11111111111111111111111111111111111111111111111111111111
_SK_B=bbbbbbbb22222222222222222222222222222222222222222222222222222222
_SK_D=dddddddd55555555555555555555555555555555555555555555555555555555

# The live olimit2 shape, verbatim: two rounds, both cleanly attributed, nothing
# outstanding at the moment the terminal verdict arrives.
_arm  ev1191-final "$_SK_A" 2026-08-28T20:58:19-07:00 1155 reports/olimit2.md
_disc ev1191-final "$_SK_A" 2026-08-28T21:44:30-07:00 check 1155 olimit2sk attributed
_arm  ev1191-final "$_SK_B" 2026-08-28T22:50:31-07:00 1155 reports/olimit2.md
_disc ev1191-final "$_SK_B" 2026-08-28T23:01:50-07:00 check 1155 olimit2sk attributed

# NON-VACUITY: the fixture really is a closed chain. Without this the writer
# assertion below could pass on a fixture that never triggered the condition.
assert_eq "#1191 fixture: the chain is CLOSED before the terminal verdict" \
    "$(grep -c . "$PEND/.ev1191-final.ledger")" "4"
# Run one ng library function in a SUBSHELL, so sourcing cannot disturb this
# file's own state. Deliberately NOT `bash -c '. "$1" …' _ "$NG"`: a POSITIONAL
# PARAMETER is a source token the ambient-scope graph cannot statically resolve,
# and that form added a row to `aso-unresolved-sources.manifest` — a real red,
# correctly caught by `ng guards-for-diff --run`. `$NG` is a variable assigned
# in this file, which the resolver DOES follow (its gap-5 case), so the edge
# stays analysable instead of being recorded as a new blind spot. Widening a
# resolver's residue to buy a test helper is the wrong trade.
_sk_drive() {
    ( . "$NG" >/dev/null 2>&1 || true; "$@" )
}
assert_empty "#1191 fixture: nothing is outstanding, which is the trigger" \
    "$(_sk_drive _skeptic_open_arms "$PEND" ev1191-final)"

_sk_before=$(grep -c . "$PEND/.ev1191-final.ledger")
_sk_drive _skeptic_record_discharge "$PEND" ev1191-final credible 1155 olimit2sk "" || true
_sk_after=$(grep -c . "$PEND/.ev1191-final.ledger")
assert_eq "#1191 a verdict arriving with NOTHING OUTSTANDING is RECORDED" \
    "$_sk_after" "$(( _sk_before + 1 ))"
_sk_row=$(tail -1 "$PEND/.ev1191-final.ledger")
assert_eq "…and its detail NAMES the reason, so the reader is not guessing" \
    "$(cut -f7 <<<"$_sk_row")" "no-open-arm"
assert_eq "…and it names NO artefact, so it can close nothing" \
    "$(cut -f2 <<<"$_sk_row")" "-"
assert_eq "…and it carries the verdict that was actually delivered" \
    "$(cut -f4 <<<"$_sk_row")" "credible"

# INERTNESS. The recovered row must be a RECORD and nothing else: it authorises
# no suppression. `_skeptic_artefact_discharged` requires 64-hex, so a `-` row
# can never answer for an artefact — asserted rather than assumed.
_sk_drive _skeptic_artefact_discharged "$PEND" ev1191-final "$_SK_D" >/dev/null 2>&1
assert_rc "the recovered row does NOT discharge an unrelated artefact" "$?" "1"

# ── A KEY WITH NO LEDGER IS NOW RECORDED TOO, AND THIS REVERSES A CONTROL
#    THAT WAS DELIBERATELY PINNED HERE (your-org/nexus-code#1207) ─────────────
#
# This block previously asserted the opposite — `assert_no_file`, "a key with NO
# ledger records nothing, exactly as before" — on the stated grounds that
# "`spawn-worker.sh` re-establishes markers without a subject, and a `-` row on a
# key nothing ever armed would assert a verdict about a window with no history".
# It is flagged this loudly because reversing another implementation's
# intentional control is not a detail, and a reviewer should adjudicate it rather
# than inherit it.
#
# Two reasons it no longer holds.
#
# FIRST, ITS FACTUAL PREMISE IS GONE. The premise is precisely the `#1207`
# mechanism: `spawn-worker.sh` established the armed state without recording a
# subject, and for every second-or-later pass it was the ONLY writer that did so.
# That is now fixed at the source — it records the arm it establishes, against
# the report the reviewer is pointed at. So a key reaching a verdict does have
# history, and the residual no-ledger population is markers predating the ledger
# feature (`8a2f36e`, 2026-08-26); two were live when this was written.
#
# SECOND, THE ROW ASSERTS SOMETHING NARROWER THAN THE PREMISE ALLOWS. It does not
# claim the key was ARMED; it claims A VERDICT WAS DELIVERED, which is true —
# `_skeptic_record_discharge` is reached only from the wrap-up verdict path, and
# this file's own header says "the row IS the verdict". The dangerous claim named
# there is *a verdict exists when none does*. Dropping the row commits the mirror
# error, and it is not the safe one: the key reports `evidence=none`, documented
# as "a POSITIVE claim (nothing has ever settled this key)", whose instruction to
# the operator is *get a review* — for work a reviewer already finished.
#
# And the INERTNESS argument twenty lines above is the argument for recording it:
# a `-` subject can never satisfy `_skeptic_artefact_discharged`, so the row
# authorises nothing either way. That property is asserted for the `no-open-arm`
# row and holds identically here, so the two rows differ only in whether the
# truth is written down.
assert_no_file "ev1191-noledger starts with no ledger" \
    "$PEND/.ev1191-noledger.ledger"
_sk_drive _skeptic_record_discharge "$PEND" ev1191-noledger credible 1155 someskeptic "" || true
assert_file_exists "a key with NO ledger now RECORDS the verdict rather than dropping it" \
    "$PEND/.ev1191-noledger.ledger"
assert_eq "…with detail no-arm-on-record, distinct from no-open-arm" \
    "$(cut -f7 <<<"$(tail -1 "$PEND/.ev1191-noledger.ledger")")" "no-arm-on-record"
assert_eq "…naming NO artefact, so it can close nothing" \
    "$(cut -f2 <<<"$(tail -1 "$PEND/.ev1191-noledger.ledger")")" "-"
assert_eq "…and the operator is told verdict-without-arm, NOT none" \
    "$(_class_of ev1191-noledger)" "verdict-without-arm"

# THE READER, on the recovered row. Nothing below is new behaviour — the
# classifier already handled a later unmatched verdict correctly. It never got
# the chance, which is the whole shape of #1191.
_ev_1191=$(_evidence_of ev1191-final)
assert_eq "the olimit2 shape now classifies superseded-verdict, not attributed" \
    "$(_class_of ev1191-final)" "superseded-verdict"
assert_contains "…and the STANDING verdict is the credible one that shipped" \
    "$_ev_1191" "standing_verdict=credible"
assert_contains "…carrying the detail that explains why it matched nothing" \
    "$_ev_1191" "standing_detail=no-open-arm"
assert_contains "…while the attributed row is still the superseded check" \
    "$_ev_1191" "attributed_verdict=check"
assert_contains "…and the verdict count moved, which is the recovered row" \
    "$_ev_1191" "verdicts=3"

# The class in ISOLATION — a terminal verdict with no earlier matched round to
# be superseded by. Without its own class this fell to unmatched-other, whose
# clause says the detail is one the gate does not recognise. That sentence would
# be FALSE about a detail this codebase writes, and a refusal whose words are not
# true is the defect this whole cluster is made of.
_arm  ev1191-alone "$_SK_A" 2026-08-29T10:00:00-07:00 1191 reports/alone.md
_res  ev1191-alone 2026-08-29T10:30:00-07:00 "operator" "arms released by hand"
_sk_drive _skeptic_record_discharge "$PEND" ev1191-alone credible 1191 alonesk "" || true
assert_eq "a terminal verdict with no prior match classifies no-open-arm" \
    "$(_class_of ev1191-alone)" "no-open-arm"
assert_contains "…and COUNTS as a verdict, so it can never read as none" \
    "$(_evidence_of ev1191-alone)" "verdicts=1"
assert_contains "…and is counted UNMATCHED, because it matched nothing" \
    "$(_evidence_of ev1191-alone)" "unmatched=1"

# The side authority must file it as DELIVERED. On the no-verdict side it would
# instruct the reader to go and get a review that already happened.
assert_contains "no-open-arm is filed on the DELIVERED side of the one authority" \
    "$(cut -f2 <<<"$(grep '^delivered' <<<"$_sides")")" "no-open-arm"

# AND THE GATE'S WORDS. The marker is live, exactly as in every observed
# instance, so this is the refusal an operator actually reads.
echo 1 > "$PEND/ev1191-alone"
_r_1191=$(_reason_of ev1191-alone)
assert_contains "the refusal names the class rather than asserting absence" \
    "$_r_1191" "evidence=no-open-arm"
assert_contains "…and tells the operator the pass was DELIVERED" \
    "$_r_1191" "DELIVERED"
assert_contains "…and not to re-spawn a reviewer that already reported" \
    "$_r_1191" "Do NOT re-spawn a skeptic"
assert_not_contains "…and never says the verdict is GENUINELY ABSENT" \
    "$_r_1191" "GENUINELY ABSENT"
# CONTROL E, extended: this change alters WORDS, never a verdict.
assert_contains "…and the refusal is still a refusal" "$_r_1191" "safe=0"


echo
echo '=== #1199 — A RE-PINNED ROUND THAT COMPLETED AND WROTE NOTHING ==='
#
# A retained reviewer re-pinned to a corrected artefact can run a second round,
# report it, have it acted on — and write NOTHING here, because a verdict is
# recorded on a wrap-up path a re-pin does not traverse. The ledger then reports
# itself fully consistent (`superseded=0 unmatched=0 verdicts=1`) with its
# standing verdict pinned to the PRE-correction artefact, and a merge gate keyed
# on `standing_at` can never clear while the answer sits in the report.
#
# Both parties read that state CORRECTLY and reach opposite conclusions, which
# is why neither can detect it alone: the worker sees a verdict on bytes that
# predate its own fixes; the reviewer knows it cleared the work.
#
# THE FIXTURE IS THE LIVE `.olayfacts.ledger`, TRANSCRIBED. Round 1 armed
# `ac8744e` and discharged it `attributed`; the report was then corrected and
# re-armed as `34f3cb0` AGAINST THE SAME PATH; round 2 ran 11:17-11:40 and left
# no row. The comparison that exposes it was already in the file.
#
#   "a later arm with a DIFFERENT sha marks the standing verdict stale"
#       kill: drop the armnr/armsha capture -> got ? want 1
#   "CONTROL: a chain with no later arm is NOT stale"
#       kill: default `stale` to 1 -> the healthy multi-round case reds
#   "CONTROL: a re-arm with the SAME sha is NOT stale"
#       kill: compare line numbers only, not shas -> a no-op re-wrap reads stale
#   "the axis is a FIELD, not a class"
#       kill: add a `standing-stale` arm to the precedence chain -> class moves
_SK_R1=ac8744e105497b4ad91cab31e17a7723e087bf80187f8725a343c4ada936128d
_SK_R2=34f3cb0808cee3b5f0b0f1c7d771e84ddc342d5c6567c7b6c68d3476508f56ed
_arm  ev1199-repin "$_SK_R1" 2026-08-29T10:49:57-07:00 348 reports/olayfacts.md
_disc ev1199-repin "$_SK_R1" 2026-08-29T11:03:53-07:00 check 348 olayfactssk attributed
_arm  ev1199-repin "$_SK_R2" 2026-08-29T11:42:42-07:00 348 reports/olayfacts.md
_ev_1199=$(_evidence_of ev1199-repin)
assert_contains "#1199 a later arm with a DIFFERENT sha marks the standing verdict STALE" \
    "$_ev_1199" "standing_stale=1"
assert_contains "…naming the relation, so a reader can check it rather than believe it" \
    "$_ev_1199" "standing_stale_why=artefact-re-armed-with-a-different-sha-after-the-standing-verdict"
# NON-VACUITY: the ledger really does look consistent by every OTHER measure.
# Without this the field could be firing on a ledger that was already flagged,
# and #1199's whole point is that nothing else notices.
assert_contains "#1199 …while the ledger still reports itself unsuperseded" \
    "$_ev_1199" "superseded=0"
assert_contains "#1199 …and fully matched, which is why nothing else notices" \
    "$_ev_1199" "unmatched=0"
assert_contains "#1199 …with the standing verdict still pinned to round 1" \
    "$_ev_1199" "standing_at=2026-08-29T11:03:53-07:00"
# IT IS A FIELD, NOT A CLASS. A property orthogonal to the matching question
# must not enter the precedence chain — that is the arm-order hazard #1121 is
# about, and the reason `superseded` rides its own field too.
assert_eq "#1199 the axis does NOT perturb the class" \
    "$(_class_of ev1199-repin)" "rearm-after-close"

# ── NO ARM AFTER THE VERDICT IS `?`, AND THIS ASSERTION USED TO PIN IT AT `0` ─
#
# WHAT THIS SAID BEFORE, VERBATIM, AND WHY IT WAS THE DEFECT RATHER THAN A
# CONTROL FOR IT:
#
#   assert_contains "#1199 CONTROL: no arm after the verdict -> NOT stale" \
#       "$(_evidence_of evfix-attributed)" "standing_stale=0"
#
# `standing_stale` is LEDGER-INTERNAL by deliberate design, so it needs a later
# `armed` row to see anything — and the mechanism #1199 is ABOUT writes no such
# row. The report is amended IN PLACE at the same path and the reviewer is
# re-pinned by `ng send`, which records neither an arm nor a discharge. So the
# ledger of #1199s own scenario is shaped exactly like `evfix-attributed`.
# Measured at 989b888, driving `ng skeptic-evidence` on the two ledgers:
#
#   HEALTHY  (round 1 reviewed, report never touched again)
#   RE-PIN   (report amended in place, round 2 ran, `ng send` wrote nothing)
#     -> BOTH: standing_stale=0 standing_stale_why=no-arm-after-the-standing-verdict
#
# One line, two opposite realities. The assertion above therefore did not
# CONTROL for the undetected case — it ASSERTED IT CORRECT, on a ledger of
# exactly its shape, and no mutation to the detector could ever have reddened
# it. A guard that pins a defect as health can only ever protect the defect.
#
# The `?` vocabulary was already in the file for this exact reason: the arm-only
# control below says in its own words that "a 0 here would read as 'checked, and
# current'". This is a case that cannot be established and was receiving a
# definite 0, which is the fixs own doctrine applied unevenly.
#
# INVERTED, not deleted: the honest value is `?` — unestablished — and the why
# now names WHICH examination did not happen, so a reader can tell "nothing
# re-armed, and I did not look at the bytes" from "I looked and it is current".
#
#   "no arm after the verdict is ?"
#       kill: restore `stale = 0` at the branch head -> got 0 want ?
#   "…and the why names the examination that did not happen"
#       kill: keep the old why string -> the field says nothing about the bytes
#   "the healthy and re-pinned ledgers are INDISTINGUISHABLE"
#       kill: make either side answer a definite value -> the two lines diverge,
#             which would be a claim the ledger cannot support
assert_contains "#1199 no arm after the verdict cannot establish currency -> ?" \
    "$(_evidence_of evfix-attributed)" "standing_stale=?"
assert_not_contains "#1199 …and NEVER a definite 0, which reads as checked-and-current" \
    "$(_evidence_of evfix-attributed)" "standing_stale=0"
assert_contains "#1199 …naming the examination that did not happen, checkably" \
    "$(_evidence_of evfix-attributed)" \
    "standing_stale_why=no-arm-after-the-standing-verdict-artefact-bytes-not-re-examined"

# NON-VACUITY / THE PROPERTY ITSELF — #1199s own re-pin ledger and the healthy
# one must answer IDENTICALLY on this axis, because the ledger genuinely cannot
# tell them apart. Asserting the `?` on `evfix-attributed` alone would be
# satisfied by a detector that had simply gone blind; this pins that the two
# shapes really are the same shape, so the `?` is the honest answer rather than
# a shrug. The rows below are `evfix-attributed`s, with round 2 having run,
# been reported, and written nothing — which is the whole issue.
_arm  ev1199-inplace "$SHA_A" 2026-08-28T15:54:10-07:00 338 reports/inplace.md
_disc ev1199-inplace "$SHA_A" 2026-08-28T16:35:22-07:00 check 338 ev1199-inplace-sk attributed
assert_eq "#1199 the amended-in-place case is INDISTINGUISHABLE from the healthy one" \
    "$(_evidence_of ev1199-inplace | sed -n 's/.*[[:space:]]\(standing_stale=[^[:space:]]*[[:space:]]standing_stale_why=[^[:space:]]*\).*/\1/p')" \
    "$(_evidence_of evfix-attributed | sed -n 's/.*[[:space:]]\(standing_stale=[^[:space:]]*[[:space:]]standing_stale_why=[^[:space:]]*\).*/\1/p')"
assert_contains "#1199 …and it too refuses to claim currency" \
    "$(_evidence_of ev1199-inplace)" "standing_stale=?"

# CONTROL — a re-arm with the SAME sha. A wrap-up re-run against unchanged bytes
# re-arms without the artefact moving; calling that stale would flag the #984
# re-arm family as a #1199, and they need different actions.
_arm  ev1199-samesha "$_SK_R1" 2026-08-29T10:00:00-07:00 348 reports/same.md
_disc ev1199-samesha "$_SK_R1" 2026-08-29T10:30:00-07:00 check 348 sk asserted
_arm  ev1199-samesha "$_SK_R1" 2026-08-29T11:00:00-07:00 348 reports/same.md
assert_contains "#1199 CONTROL: a re-arm with the SAME sha is NOT stale" \
    "$(_evidence_of ev1199-samesha)" "standing_stale=0"
assert_contains "#1199 CONTROL: …and distinguishes itself from the no-arm case" \
    "$(_evidence_of ev1199-samesha)" "standing_stale_why=re-armed-with-the-SAME-sha-artefact-unchanged"

# CONTROL — doubt. No verdict at all: there is nothing to compare, and the
# honest answer is `?`, never 0. A 0 here would read as "checked, and current".
assert_contains "#1199 CONTROL: an arm-only ledger cannot compare -> ?" \
    "$(_evidence_of evfix-noverdict)" "standing_stale=?"
assert_contains "#1199 CONTROL: …and says it has no verdict to compare against" \
    "$(_evidence_of evfix-noverdict)" "standing_stale_why=no-standing-verdict-to-compare"
# CONTROL — an unparseable ledger asserts NOTHING on this axis either. The
# doubt-fold must cover every count on the line, not only the ones it was
# written for.
assert_contains "#1199 CONTROL: a malformed ledger yields standing_stale=?" \
    "$(_evidence_of evfix-malformed)" "standing_stale=?"
# CONTROL — a verdict that named no artefact cannot be compared to a later arm.
assert_contains "#1199 CONTROL: an unattributed standing verdict cannot compare" \
    "$(_evidence_of evfix-ambig)" "standing_stale_why=standing-verdict-names-no-artefact-cannot-compare"

# AND THE GATE'S WORDS.
echo 1 > "$PEND/ev1199-repin"
_r_1199=$(_reason_of ev1199-repin)
assert_contains "#1199 the refusal warns the verdict predates the artefact" \
    "$_r_1199" "STANDING VERDICT PREDATES THE CURRENT ARTEFACT"
assert_contains "#1199 …and sends the reader to the REPORT, not to a re-spawn" \
    "$_r_1199" "Read the REPORT alongside the ledger"
# The ambiguity is NAMED rather than resolved: a completed-but-unrecorded round
# and a round that never ran are indistinguishable from this side and need
# opposite actions. Printing a guess as a fact is the defect, not the fix.
assert_contains "#1199 …and names the ambiguity instead of guessing past it" \
    "$_r_1199" "look identical from this side"
assert_contains "#1199 …and the refusal is still a refusal" "$_r_1199" "safe=0"


echo
echo '=== COMPOSITION: #1191 and #1199 on ONE ledger (skeptic F1) ==='
#
# TWO FIXES THAT ARE INDIVIDUALLY CORRECT AND JOINTLY BLIND. #1191 recovers a
# terminal verdict as a row carrying `sha=-`. That row is then the STANDING
# verdict — and #1199's staleness axis keyed on the standing row's subject, so
# it refused the comparison and fell from a definite `1` to `?` on the exact
# history it exists to expose.
#
# Honest (it never claimed a false 0) but a COVERAGE regression, and invisible
# because nothing in the suite put both fixes on one ledger. Each section
# planted the history its own fix was about. This section is the permanent
# guard against that shape, which is the durable half of the finding: the
# repair is one line, the missing composition is the defect.
#
#   "the composed history is still STALE"
#       kill: key the comparison on standsubj instead of refsha -> got ? want 1
#   "…and the reason names WHICH row was compared"
#       kill: collapse the two why-strings into one -> a reader checking the
#             standing row cannot reproduce the answer
#   "…and #1191's own recovery is undisturbed"
#       kill: skip `sha=-` rows when choosing the standing verdict -> the
#             terminal credible stops being standing and #1191 regresses
_arm  evcompose "$SHA_A" 2026-08-29T10:49:57-07:00 348 reports/compose.md
_disc evcompose "$SHA_A" 2026-08-29T11:03:53-07:00 check 348 sk attributed
_arm  evcompose "$SHA_B" 2026-08-29T11:42:42-07:00 348 reports/compose.md
# NON-VACUITY: before #1191's row lands, the axis must already read 1. Without
# this the assertion below could pass on a fixture that was never blinded.
assert_contains "COMPOSITION: the #1199 history alone reads STALE" \
    "$(_evidence_of evcompose)" "standing_stale=1"
# …now #1191 recovers the terminal verdict, exactly as the writer does.
_disc evcompose - 2026-08-29T12:00:00-07:00 credible 348 sk no-open-arm
_ev_comp=$(_evidence_of evcompose)
assert_contains "COMPOSITION: it is STILL stale once #1191 recovers the verdict" \
    "$_ev_comp" "standing_stale=1"
assert_contains "COMPOSITION: …and names the row it actually compared against" \
    "$_ev_comp" "standing_stale_why=artefact-re-armed-with-a-different-sha-after-the-last-ATTRIBUTING-verdict-the-standing-row-names-none"
assert_contains "COMPOSITION: …while #1191's recovery is undisturbed" \
    "$_ev_comp" "standing_verdict=credible"
assert_contains "COMPOSITION: …and the recovered row still names no artefact" \
    "$_ev_comp" "standing_detail=no-open-arm"
# CONTROL — the two why-strings are DISTINCT, so the field discriminates which
# row was compared rather than printing one constant.
_w_plain=$(_evidence_of ev1199-repin | sed -n 's/.*standing_stale_why=\([^ ]*\).*/\1/p')
_w_comp=$(printf '%s' "$_ev_comp" | sed -n 's/.*standing_stale_why=\([^ ]*\).*/\1/p')
assert_eq "COMPOSITION CONTROL: the two reference cases report DIFFERENT reasons" \
    "$([[ "$_w_plain" != "$_w_comp" ]] && echo distinct || echo same)" "distinct"

EXPECTED=152   # 146 +3: the #1207 reversal of the no-ledger control (record, detail, class)
               #     +3: #1199 — the no-arm control INVERTED from a pinned `0` to `?`,
               #         plus the never-a-0 assertion and the indistinguishability pair
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
