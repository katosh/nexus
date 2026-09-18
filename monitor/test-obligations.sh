#!/usr/bin/env bash
# Tests for the obligation ledger — monitor/_obligations.sh,
# monitor/obligations.sh, and retire-preflight check 1d
# (your-org/nexus-code#845).
#
# Run: bash monitor/test-obligations.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE CONTRACT UNDER TEST, in both directions — a deadlock detector that
# fires on healthy pairs gets disabled by whoever is under time pressure,
# which removes it entirely:
#
#   BLOCKS a retirement (the #845 instance-2 harm — destroying a reviewer
#   somebody is still waiting on):
#     * an open edge whose creditor still holds its blocking condition;
#     * an edge whose state could not be established at all (`unknown`),
#       including the wrong-state-dir signature;
#     * an edge of a kind this library has never heard of.
#
#   STAYS SILENT (the healthy cases, and each one has to be positively
#   asserted or the gate is unusable):
#     * a window that owes nothing;
#     * an edge explicitly settled by its debtor's verdict;
#     * an edge whose creditor's pending marker has been cleared by ANY
#       path — the derived release that needs no bookkeeping;
#     * an edge whose creditor window is gone from tmux;
#     * the CREDITOR's own retirement (it is owed, it does not owe).
#
# HERMETIC. Every case builds its own STATE_DIR and injects the tmux window
# list through OBL_TMUX_WINDOWS, so nothing here reads the live board and
# nothing here writes to the operator's canonical state (the #833 leak).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OBLIG="$_test_dir/obligations.sh"
PREFLIGHT="$_test_dir/retire-preflight.sh"

# THE SHARED HARNESS, not hand-rolled counters. Two properties this suite
# cannot get on its own and must not go without:
#
#   * the ledger is SUBSHELL-DURABLE. Case 4e drives `obl_blocks_retirement`
#     inside `( … )` so that sourcing the library cannot leak into the rest
#     of the run; with in-memory counters a FAIL there would be discarded
#     with the subshell and the suite would announce a pass over it
#     (your-org/nexus-code#805).
#   * a MISSING assert_* helper is counted as a failure rather than exiting
#     127 into nothing. That is not hypothetical: `assert_not_contains` did
#     not exist in test-retire-preflight.sh, its one call vanished at rc 127,
#     and the suite reported ALL TESTS PASSED for years of runs. This file
#     was written with the same hand-rolled shape and would have inherited
#     the same hole.
. "$_test_dir/watcher/_test_helpers.sh"

# ---- harness -------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"
REPORTS_DIR="$WORK/reports"
export NEXUS_STATE_DIR="$STATE_DIR"

reset_state() {
    rm -rf "$STATE_DIR" "$REPORTS_DIR"
    mkdir -p "$STATE_DIR/skeptic/pending" "$STATE_DIR/user-prompt" \
             "$STATE_DIR/pane-change" "$REPORTS_DIR"
}

obl() { env NEXUS_STATE_DIR="$STATE_DIR" bash "$OBLIG" "$@"; }

# Run `obligations.sh gate <window>`; capture stdout+stderr and rc.
run_gate() {
    local _out_var="$1" _rc_var="$2" window="$3"
    local _o _r
    _o=$(env NEXUS_STATE_DIR="$STATE_DIR" bash "$OBLIG" gate "$window" 2>&1); _r=$?
    printf -v "$_out_var" '%s' "$_o"
    printf -v "$_rc_var"  '%s' "$_r"
}

# Run retire-preflight with an injected pane state (hermetic — no tmux pane).
run_preflight() {
    local _out_var="$1" _rc_var="$2" window="$3"; shift 3
    local _o _r
    _o=$(env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE_DIR" \
            bash "$PREFLIGHT" "$window" --state-dir "$STATE_DIR" \
            --reports-dir "$REPORTS_DIR" --pane-state idle "$@" 2>&1); _r=$?
    printf -v "$_out_var" '%s' "$_o"
    printf -v "$_rc_var"  '%s' "$_r"
}

echo "=== obligation ledger (your-org/nexus-code#845) ==="

# ── 1. the record: open, read back, and the id is STABLE ──────────────────
# A stable id is what stops a round-2 reopen creating a SECOND live record
# whose settlement leaves round 1 blocking forever.
echo "## 1. open + stable id"
reset_state
ID1=$(obl open --debtor sk911 --creditor papercuts --round 1 --detail "round 1")
ID2=$(obl open --debtor sk911 --creditor papercuts --round 2 --detail "round 2")
assert_eq "reopening the same triple yields the SAME id" "$ID1" "$ID2"
COUNT=$(find "$STATE_DIR/obligations" -maxdepth 1 -type f -name '*.rec' | wc -l)
assert_eq "…and exactly ONE record file exists" "$COUNT" "1"
OUT=$(obl show "$ID1")
assert_contains "the record reports the LAST round (append-only, last wins)" "$OUT" "round    : 2"
assert_contains "…and round 1 survives beneath it as audit trail"            "$OUT" "round	1"

# A self-edge would block a window on itself with no counterpart able to
# settle it — a brick with only the manual override as an exit.
OUT=$(obl open --debtor w1 --creditor w1 2>&1); RC=$?
assert_eq       "a SELF-obligation is refused"        "$RC" "1"
assert_contains "…naming why"                          "$OUT" "self-obligation"

# ── 2. LIVE: the creditor still holds its blocking condition ──────────────
echo "## 2. live edge BLOCKS"
reset_state
ID=$(obl open --debtor sk911 --creditor papercuts --round 1)
: > "$STATE_DIR/skeptic/pending/papercuts"
export OBL_TMUX_WINDOWS=$'papercuts\nsk911\norchestrator'
OUT=$(obl state "$ID")
assert_contains "state=live while the creditor's marker stands" "$OUT" "state=live"
run_gate OUT RC sk911
assert_eq       "gate on the DEBTOR exits 1"          "$RC"  "1"
assert_contains "…reporting blocked"                   "$OUT" "gate=blocked"
assert_contains "…and naming the creditor"             "$OUT" "owes=papercuts"

# THE CREDITOR IS NOT BLOCKED BY ITS OWN EDGE. It is owed, it does not owe;
# check 1b is what protects it. Getting this backwards would make every
# parked target un-retirable forever.
run_gate OUT RC papercuts
assert_eq       "gate on the CREDITOR is clear"       "$RC"  "0"
assert_contains "…saying so"                           "$OUT" "gate=clear"

# ── 3. the releases — each must be POSITIVE evidence ──────────────────────
echo "## 3. releases"
# 3a. THE CORRECTION (sk926). A cleared creditor marker must NOT release the
# edge. The marker is cleared by the FIRST verdict, so keying a release on it
# closed the pairing at the exact instant the hazard begins — see §8's replay
# of the recorded sk911 timeline. This assertion is the inverse of the one
# that used to live here, and it is the regression guard for the whole fix.
rm -f "$STATE_DIR/skeptic/pending/papercuts"
OUT=$(obl state "$ID")
assert_contains "a cleared creditor marker does NOT release the pairing" "$OUT" "state=live"
run_gate OUT RC sk911
assert_eq "…and the gate STILL blocks" "$RC" "1"

# 3a'. the pairing's own end signal does release it.
env NEXUS_STATE_DIR="$STATE_DIR" bash "$_test_dir/skeptic-channel.sh" close papercuts >/dev/null 2>&1
OUT=$(obl state "$ID")
assert_contains '`ng skeptic close` on the creditor ends the pairing' "$OUT" "state=void-pairing-closed"
run_gate OUT RC sk911
assert_eq "…and the gate is clear" "$RC" "0"
# …but a DONE that PREDATES a re-armed round must not release it (#469).
obl open --debtor sk911 --creditor papercuts --round 2 >/dev/null
OUT=$(obl state "$ID")
assert_contains "a STALE DONE does not release a re-armed pairing" "$OUT" "state=live"
assert_contains "…and says the sentinel predates the round"        "$OUT" "PREDATES"
rm -f "$STATE_DIR/skeptic/papercuts/DONE"

# 3a''. THE ENCODER BOUNDARY — the cross-store read must use the SKEPTIC
# store's encoder (your-org/nexus-code#941, missed site).
#
# WHY 3a' CANNOT SEE THIS. `papercuts` is already inside `[A-Za-z0-9_-]`, where
# `obl_safe` (lossy `_` substitution) and `wk_encode` (injective
# percent-encoding) return the SAME string. So that assertion passes under
# either encoder and is blind to which one the code uses. A DOTTED name is the
# discriminator, and dotted window names are not exotic — `_tmux-window.sh`'s
# entire header is about `cc-update-2.1.183` (`#323`).
#
# THE FAILURE THIS PINS IS SILENT AND STICKY: `skeptic-channel.sh close` creates
# `skeptic/cc-upd-2%2E1%2E183/DONE`; an obligation reading
# `skeptic/cc-upd-2_1_183/DONE` finds nothing, `_obl_done_identity` returns
# `none`, and "release 2: the reviewer CLOSED the pairing" can NEVER fire. The
# edge is held open forever and the retirement gate stays shut on a window whose
# review genuinely finished — with no error at any step.
# NO `reset_state` and NO exported env here: this section is threaded between
# 3a' and 3b, which both depend on the `sk911`/`papercuts` fixture and on the
# ambient OBL_TMUX_WINDOWS. A fresh debtor/creditor pair keeps it independent,
# and the tmux override is scoped to the one call that needs it.
DOTW='cc-upd-2.1.183'
DOTID=$(obl open --debtor sk941 --creditor "$DOTW" --round 1)
env NEXUS_STATE_DIR="$STATE_DIR" bash "$_test_dir/skeptic-channel.sh" close "$DOTW" >/dev/null 2>&1
# POSITIVE CONTROL FIRST: the close must actually have created a channel dir,
# or "released" below would be vacuous — an absence proving nothing.
# A BARE GLOB, NOT `find … | head -1` (your-org/nexus-code#622 family). Under
# `pipefail` a closing `head` kills the producer with SIGPIPE and the PIPELINE
# reports that rc — an early-exit reader, and `test-early-exit-reader-manifest`
# catches it. This needs no pipeline at all. Correct under nullglob either way:
# unset, an unmatched pattern stays literal and `[[ -d ]]` rejects it; set, the
# loop simply does not run. Both leave DOTDIR empty, which the control below
# then reports.
DOTDIR=""
for _dd in "$STATE_DIR"/skeptic/*2*1*183*; do
    [[ -d "$_dd" ]] && { DOTDIR="$_dd"; break; }
done
assert_contains 'control: `ng skeptic close` created a channel dir for the dotted name' \
                "${DOTDIR:-NONE}" "cc-upd-2"
assert_eq       "control: …and it holds a DONE sentinel" \
                "$( [[ -n "$DOTDIR" && -e "$DOTDIR/DONE" ]] && echo yes || echo no )" "yes"
OUT=$(OBL_TMUX_WINDOWS=$'sk941\ncc-upd-2.1.183\norchestrator' obl state "$DOTID")
assert_contains "a DOTTED creditor's close RELEASES the pairing (encoder boundary)" \
                "$OUT" "state=void-pairing-closed"

# 3b. the creditor window is positively gone from tmux.
: > "$STATE_DIR/skeptic/pending/papercuts"
OBL_TMUX_WINDOWS=$'sk911\norchestrator' obl state "$ID" > "$WORK/o" 2>&1
assert_contains "a creditor absent from tmux voids the edge" "$(cat "$WORK/o")" \
                "state=void-creditor-absent"

# 3c. an explicit settlement.
OUT=$(obl settle "$ID" --reason "verdict filed on the round-1 report, see PR comment" 2>&1)
assert_contains "settle reports the id"          "$OUT" "settled sk911__papercuts"
OUT=$(obl state "$ID")
assert_contains "…and the edge reads settled"    "$OUT" "state=settled"
assert_contains "…carrying the recorded reason"  "$OUT" "verdict filed on the round-1 report"
run_gate OUT RC sk911
assert_eq "…and the gate is clear" "$RC" "0"

# The release valve on a gate that refuses irreversible kills must be
# EXPLAINED, or it is the `rm` the gate exists to replace wearing a verb.
OUT=$(obl settle "$ID" --reason "done" 2>&1); RC=$?
assert_eq       "a token reason is REFUSED"      "$RC"  "1"
assert_contains "…naming the substantive floor"  "$OUT" ">=20 chars"

# ── 4. the doubt arms — every one of them must BLOCK ──────────────────────
# This is the half that decides whether the gate is worth having. `#845`
# instance 2 happened because a gate answered a question it could establish
# and stayed silent about the one it could not.
echo "## 4. doubt BLOCKS (default-deny)"
reset_state
ID=$(obl open --debtor skX --creditor tgtX --round 1)
: > "$STATE_DIR/skeptic/pending/tgtX"
export OBL_TMUX_WINDOWS=$'tgtX\nskX'

# 4a. a MISSING skeptic state tree — the wrong-state-dir signature (#577).
# Under the corrected model this needs no special arm and that is the point:
# every release is now POSITIVE evidence (a DONE file, a later edge, an
# absent window, a settlement), so a state dir with nothing in it produces
# none of them and the edge simply stands. The hazard the old `unknown` arm
# guarded against — an absence being read as a release — cannot arise when
# absence is never a release.
mv "$STATE_DIR/skeptic/pending" "$STATE_DIR/skeptic/pending.away"
OUT=$(obl state "$ID")
assert_contains "an empty skeptic state tree yields NO release" "$OUT" "state=live"
run_gate OUT RC skX
assert_eq       "…and it BLOCKS (fail-closed by construction)"  "$RC"  "1"
mv "$STATE_DIR/skeptic/pending.away" "$STATE_DIR/skeptic/pending"

# 4b. the record itself is unreadable.
rm -f "$STATE_DIR/obligations/$ID.rec"
OUT=$(obl state "$ID")
assert_contains "an unreadable record is unknown" "$OUT" "state=unknown"

# 4c. a kind nobody here enumerated gets NO derived release. The vocabulary
# is deliberately open; the release rules are not.
reset_state
export OBL_TMUX_WINDOWS=$'tgtY\nskY'
IDK=$(obl open --debtor skY --creditor tgtY --kind some-future-kind --round 1)
OUT=$(obl state "$IDK")
assert_contains "an UNKNOWN kind stays live with no marker at all" "$OUT" "state=live"
assert_contains "…and says the kind has no release of its own"     "$OUT" "no kind-specific release"
run_gate OUT RC skY
assert_eq "…and it BLOCKS" "$RC" "1"

# 4d. tmux could not be listed. Not a release — but not doubt about whether
# anyone is WAITING either, since the marker already answered that.
reset_state
ID=$(obl open --debtor skZ --creditor tgtZ --round 1)
: > "$STATE_DIR/skeptic/pending/tgtZ"
OUT=$(OBL_TMUX_WINDOWS=" " obl state "$ID")
assert_contains "an unlistable tmux does not manufacture an absence" "$OUT" "state=live"
assert_not_contains "…and specifically not void-creditor-absent"     "$OUT" "void-creditor-absent"

# 4e. THE DEFAULT ARM ITSELF, driven directly. Every case above reaches
# `obl_blocks_retirement` through a state this file produces today, so none
# of them exercises the arm that catches a state a FUTURE revision adds —
# and that arm is the entire reason the predicate is an allowlist. A
# denylist with a permissive `*)` is what killed a live worker on
# 2026-06-15 and what permitted `over-limit` for months.
echo "## 4e. the allowlist's default arm"
( # subshell: sourcing the lib must not leak into the rest of the suite
  # shellcheck source=monitor/_obligations.sh
  source "$_test_dir/_obligations.sh"
  for st in settled void-pairing-closed void-superseded void-creditor-absent; do
      obl_blocks_retirement "$st" && exit 71
  done
  for st in live unknown some-state-invented-in-2027 "" "VOID-PAIRING-CLOSED" \
            void-creditor-clear; do
      # `void-creditor-clear` is listed among the BLOCKING names on purpose:
      # it is the retired state whose release was the sk926 defect, so if a
      # revert reintroduces the name it must not silently regain its power.
      obl_blocks_retirement "$st" || exit 72
  done
  # An EMPTY vocabulary must fail LOUD, not block-everything-quietly — that
  # is how a refactor that deleted this array survived a run.
  _OBL_RELEASING_STATES=()
  obl_blocks_retirement settled >/dev/null 2>&1 || exit 73
  exit 0
); RC=$?
assert_eq "the four releasing states release, and NOTHING else does" "$RC" "0"

# ── 5. retire-preflight check 1d — the gate that #845 instance 2 needed ───
echo "## 5. retire-preflight check 1d"
reset_state
export OBL_TMUX_WINDOWS=$'papercuts\nsk911'
obl open --debtor sk911 --creditor papercuts --round 1 \
    --detail "delta re-run owed after the round-1 findings" >/dev/null
: > "$STATE_DIR/skeptic/pending/papercuts"

# THE REGRESSION. Every gate that existed before #845 is satisfied here:
# the pane is idle, no operator submit, no engagement mark, sk911 holds no
# pending marker of its own and filed no `disposition: second-pass`. This
# case returned safe=1 on 2026-08-14 and the retirement stranded two
# windows.
run_preflight OUT RC sk911
assert_eq       "a window that OWES is refused"          "$RC"  "1"
assert_contains "…safe=0"                                 "$OUT" "safe=0"
assert_contains "…naming the obligation, not the pane"    "$OUT" "OWES"
assert_contains "…and naming the creditor"                "$OUT" "papercuts"
assert_contains "…and citing the issue"                   "$OUT" "845"
assert_contains "…and naming the SANCTIONED release"      "$OUT" "ng obligation settle"

# CONTROL 1 — the CREDITOR side is untouched by 1d. (It is refused here by
# check 1b, on its own live pending marker, which is the correct gate for
# a window that is owed something. The point is that 1d did not fire.)
run_preflight OUT RC papercuts
assert_not_contains "the creditor is NOT refused for OWING anything" "$OUT" "OWES"

# CONTROL 2 — a window with no edges at all still retires. A gate that
# refuses everybody is a gate that gets bypassed.
run_preflight OUT RC unrelated-worker
assert_eq       "an unrelated window still retires"  "$RC"  "0"
assert_contains "…safe=1"                             "$OUT" "safe=1"

# CONTROL 3 — the audited release. An orchestrator that has adjudicated the
# pairing as over says so on the record, and the window frees immediately.
obl settle --debtor sk911 \
    --reason "papercuts confirmed no further review needed; adjudicated on the issue" >/dev/null
run_preflight OUT RC sk911
assert_eq       "a SETTLED reviewer retires"         "$RC"  "0"
assert_contains "…safe=1"                             "$OUT" "safe=1"

# CONTROL 4 — the protocol-native ending, end to end through the preflight.
# Reopen the pairing, confirm it blocks, then close the channel — which is
# what the skeptic protocol already tells the final reviewer to do, and
# which also releases the target's own `await` loop with exit 10.
obl open --debtor sk911 --creditor papercuts --round 2 >/dev/null
run_preflight OUT RC sk911
assert_eq "a REOPENED round blocks again" "$RC" "1"
# …and clearing the creditor's MARKER is explicitly NOT enough (the sk926
# regression, asserted at the preflight layer as well as the library layer).
rm -f "$STATE_DIR/skeptic/pending/papercuts"
run_preflight OUT RC sk911
assert_eq "clearing the marker alone does NOT release it" "$RC" "1"
env NEXUS_STATE_DIR="$STATE_DIR" bash "$_test_dir/skeptic-channel.sh" close papercuts >/dev/null 2>&1
run_preflight OUT RC sk911
assert_eq       "…closing the pairing does"                        "$RC"  "0"
assert_contains "…safe=1"                                           "$OUT" "safe=1"

# ── 6. the library is a PRECONDITION, not an optional nicety ──────────────
# The script's contract is doubt → no-go, and "I could not load the ledger"
# is doubt about an IRREVERSIBLE act.
echo "## 6. a missing ledger library refuses"
reset_state
SANDBOX="$WORK/sandbox"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"
# `_nexus-root.sh` rides along with `ng` for the same reason `_bookkeeping.sh`
# does: `ng` refuses to start without it (your-org/nexus-code#1077). This case
# varies exactly ONE thing — the ABSENT `_obligations.sh` — so an unrelated
# missing dependency must not be allowed to supply the refusal instead.
cp "$PREFLIGHT" "$_test_dir/_bookkeeping.sh" "$_test_dir/_nexus-root.sh" \
   "$_test_dir/ng" "$SANDBOX/" 2>/dev/null
OUT=$(env -u NEXUS_ROOT NEXUS_STATE_DIR="$STATE_DIR" \
        bash "$SANDBOX/retire-preflight.sh" someone --state-dir "$STATE_DIR" \
        --reports-dir "$REPORTS_DIR" --pane-state idle 2>&1); RC=$?
assert_eq       "no _obligations.sh ⇒ refuse"     "$RC"  "1"
assert_contains "…safe=0"                          "$OUT" "safe=0"
assert_contains "…naming the missing ledger"       "$OUT" "_obligations.sh"

# ── 7. `pairs` — the who-waits-on-whom surface ────────────────────────────
echo "## 7. pairs"
reset_state
export OBL_TMUX_WINDOWS=$'a\nb\nc\nd'
obl open --debtor b --creditor a --round 1 >/dev/null
obl open --debtor d --creditor c --round 1 >/dev/null
env NEXUS_STATE_DIR="$STATE_DIR" bash "$_test_dir/skeptic-channel.sh" close c >/dev/null 2>&1
OUT=$(obl pairs)
assert_contains "a live pair is listed"                 "$OUT" "b "
assert_contains "…with its creditor"                     "$OUT" "a "
assert_not_contains "a CLOSED pairing is not listed as live" "$OUT" "d "
OUT=$(obl list)
assert_contains "list shows the closed edge too, with its state" "$OUT" "void-pairing-closed"

# ── 8. REPLAY OF THE RECORDED INCIDENTS (your-org/nexus-code#845) ────────
#
# Everything above plants a fixture. That is how the FIRST version of this
# suite was written, it passed, and it was wrong: the fixture encoded the
# author's MODEL of the incident (an obligation outstanding at the moment of
# retirement) rather than the incident's actual STATE. The real `sk911`
# retirement happened AFTER its first verdict, when both release paths had
# already fired — a state the planted fixture never reached, so it confirmed
# the model instead of testing it.
#
# THE REMEDY IS NOT MORE CARE, IT IS A DIFFERENT SOURCE OF TRUTH. This
# section replays the RECORDED action-log timelines
# (monitor/watcher/fixtures/incident-845-timelines.jsonl, transcribed
# verbatim — see its README) through PRODUCTION code paths, and asks the
# shipped `retire-preflight.sh` the question the orchestrator asked at the
# moment it actually asked it.
#
# The replay drives real verbs, never a summary of what they do:
#   skeptic-spawn   -> obligations.sh open  + the pending marker spawn seeds
#   skeptic-verdict -> ng's REAL `_wrapup_skeptic_step --skeptic-role`
#   window-retain   -> the moment to run retire-preflight and assert
# so a change in what a verdict does to the ledger changes this test's
# answer without anybody editing this test.
echo "## 8. replay: the recorded sk911/papercuts and sk897/tmuxwrap timelines"
reset_state
FIXTURE="$_test_dir/watcher/fixtures/incident-845-timelines.jsonl"
assert_file_exists "the recorded timelines are present" "$FIXTURE"

# `ng` is sourced (guarded main) so the verdict path under test is the real
# one — this is the same technique watcher/test-skeptic-channel.sh uses.
NG_SRC="$_test_dir/ng"
# shellcheck disable=SC1090
source "$NG_SRC"

# Replay one window-pair's timeline up to (and not including) the named
# window's `window-retain`, then answer the retirement question.
#
# NOTE the deliberate omission: nothing here writes an obligation on the
# author's say-so. Every edge in the replayed state got there because a
# RECORDED `skeptic-spawn` ran the production open, and every closure got
# there because a RECORDED `skeptic-verdict` ran the production verdict path.
replay_until_retain() {   # <window-to-retire>
    local stop_win="$1" ts ev win tw ov depth at
    reset_state
    export OBL_TMUX_WINDOWS=$'tmuxwrap\nsk897\npapercuts\nsk900\nsk911\nsk911b'
    while IFS=$'\t' read -r ts ev win tw ov depth; do
        # THE RECORDED TIME, not the replay's own clock. Supersession is an
        # ORDERING question ("which reviewer is current"), and collapsing a
        # 1h41m handover into one second answers a different question —
        # measured: without this, sk900 and sk911 tie and neither supersedes.
        at=$(date -d "$ts" +%s 2>/dev/null) || at=""
        case "$ev" in
            skeptic-spawn)
                [[ -n "$tw" && "$tw" != "null" ]] || continue
                # what spawn-worker.sh --skeptic-role does, in its own words
                # An ARRAY, not `${at:+--at "$at"}`. That form is a single
                # word under zsh (which does not word-split unquoted
                # parameters), so the flag arrives as one argument and the
                # verb refuses it — measured while auditing the live board
                # with the same idiom. This suite runs under bash, where the
                # form works, which is exactly what makes it a trap worth
                # not leaving lying around.
                local -a _at_arg=()
                [[ -n "$at" ]] && _at_arg=(--at "$at")
                env NEXUS_STATE_DIR="$STATE_DIR" bash "$OBLIG" open \
                    --debtor "$win" --creditor "$tw" --kind skeptic-verdict \
                    --round "${depth:-1}" --by "replay: recorded skeptic-spawn $ts" \
                    "${_at_arg[@]}" \
                    >/dev/null 2>&1 || true
                printf '%s' "${depth:-1}" > "$STATE_DIR/skeptic/pending/${tw//[^a-zA-Z0-9_-]/_}"
                mkdir -p "$STATE_DIR/skeptic/${tw//[^a-zA-Z0-9_-]/_}"
                ;;
            skeptic-request)
                [[ -n "$tw" && "$tw" != "null" ]] || continue
                # a target re-arming its require gate
                printf '%s' "${depth:-1}" > "$STATE_DIR/skeptic/pending/${tw//[^a-zA-Z0-9_-]/_}"
                ;;
            skeptic-verdict)
                [[ -n "$tw" && "$tw" != "null" ]] || continue
                # THE REAL VERDICT PATH, provenance and all.
                local d="$STATE_DIR/windows"; mkdir -p "$d"
                jq -n --arg w "$win" --argjson dp "${depth:-1}" --arg t "$tw" \
                    '{window:$w, skeptic_mode:"", skeptic_depth:$dp, skeptic_role:true,
                      skeptic_target:$t, skeptic_orig:$t}' \
                    > "$d/${win//[^a-zA-Z0-9_-]/_}.json" 2>/dev/null || true
                _wrapup_skeptic_step 845 "$win" your-org/nexus-code "${depth:-1}" \
                    "" "" "" "check" "$tw" "${depth:-1}" 0 >/dev/null 2>&1 || true
                ;;
            window-retain)
                [[ "$win" == "$stop_win" ]] && return 0
                ;;
        esac
    done < <(jq -r '[.ts, .event, (.window // ""), (.target_window // ""),
                     (.orig_window // ""), (.depth // "")] | @tsv' "$FIXTURE")
    return 0
}

# --- 8a. THE REGRESSION: sk911 at the moment it was actually retired ------
# Recorded: spawn 08:58:04 -> verdict 09:19:36 -> window-retain 09:21:21.
# `papercuts` is still being worked at 10:55, and a THIRD reviewer (sk911b)
# had to be spawned at 10:41:37 because this one was gone.
replay_until_retain sk911
run_preflight OUT RC sk911
assert_eq       "#845 REPLAY sk911 is REFUSED at the recorded retirement" "$RC" "1"
assert_contains "#845 REPLAY …safe=0"                                     "$OUT" "safe=0"
assert_contains "#845 REPLAY …because it still owes papercuts"            "$OUT" "papercuts"

# --- 8b. sk897 in the gap between its verdict and its target's re-arm -----
# Recorded: spawn 05:17:25 -> verdict 05:42:48 -> tmuxwrap re-arms 07:25:03.
# sk897 was alive throughout (pastes at 08:11 and 10:33). Any retirement in
# that 1h42m window strands tmuxwrap exactly as sk911's stranded papercuts.
replay_until_retain sk897
run_preflight OUT RC sk897
assert_eq       "#845 REPLAY sk897 is REFUSED in the post-verdict gap" "$RC" "1"
assert_contains "#845 REPLAY …naming tmuxwrap"                         "$OUT" "tmuxwrap"

# --- 8c. CONTROL: the pairing ENDS and the reviewer retires ---------------
# Not an afterthought — without this the fix is "refuse everything", which
# gets switched off by whoever is under time pressure. `skeptic-channel.sh
# close` is the protocol's OWN end-of-pairing signal ("the skeptic closed
# the channel; the worker can retire"), so it must release.
replay_until_retain sk911
env NEXUS_STATE_DIR="$STATE_DIR" bash "$_test_dir/skeptic-channel.sh" close papercuts >/dev/null 2>&1
run_preflight OUT RC sk911
assert_eq       "#845 REPLAY CONTROL a CLOSED pairing releases the reviewer" "$RC" "0"
assert_contains "#845 REPLAY CONTROL …safe=1"                                "$OUT" "safe=1"

# --- 8d. CONTROL: a superseded reviewer retires --------------------------
# sk900 held papercuts before sk911 did. Once a later reviewer is pinned to
# the same target, the earlier pairing is over and its window must be free —
# otherwise every skeptic a target ever had accumulates as un-retirable.
replay_until_retain sk911
run_preflight OUT RC sk900
assert_eq       "#845 REPLAY CONTROL a SUPERSEDED reviewer is free to retire" "$RC" "0"
assert_contains "#845 REPLAY CONTROL …safe=1"                                 "$OUT" "safe=1"

# ── 9. D2: the two subtlest mechanisms, each guarded (nexus-code#926) ─────
#
# sk926 mutated BOTH of these and the suite stayed 67/0 — so the fix was
# protecting the board against the OLD bug and not against ITSELF. They fail
# in OPPOSITE dangerous directions, which is why each needs its own case:
#
#   DONE identity   getting it wrong BRICKS a reviewer forever (a stale
#                   sentinel never releases, or a real close never registers).
#   supersession    getting it wrong makes TWO LIVE REVIEWERS retirable at
#                   once (a tie supersedes in both directions).
#
# These are the two arms I flagged at hand-off as the ones I was least sure
# of. That is where the coverage was missing, which is not a coincidence:
# uncertainty and untestedness have the same source.
echo "## 9. DONE identity + supersession tie-break"

# --- 9a/9b. DONE identity: a DISCRIMINATING set, not a plausible one ------
#
# The identity carries CONTENT and INODE. Three mutants are possible —
# mtime-based, inode-only, content-only — and each fails in a different
# direction, so ONE case cannot pin all three. Each case below is the minimal
# input that separates the real predicate from exactly one mutant.
#
# THIS SET IS THE SECOND VERSION. The first used a bare `touch`, which is
# inert: the sentinel was written, the edge opened and the touch applied
# inside the SAME SECOND, so mtime never moved and the mtime mutant passed.
# The mutation applied; the assertion simply could not see it. sk926's own
# retraction makes the rule — a negative control has to be shown potent
# before its zero means anything — and it applies to a test's discriminating
# power exactly as it does to a mutant's.
reset_state
export OBL_TMUX_WINDOWS=$'tgt9\nsk9'
mkdir -p "$STATE_DIR/skeptic/tgt9"
printf 'round 1 done\n' > "$STATE_DIR/skeptic/tgt9/DONE"     # a PRIOR round's sentinel
ID9=$(obl open --debtor sk9 --creditor tgt9 --round 2)        # re-armed AFTER it
OUT=$(obl state "$ID9")
assert_contains "9a a pre-existing DONE does not release a re-armed pairing" "$OUT" "state=live"
assert_contains "9a …and says the sentinel predates the edge"                "$OUT" "PREDATES"

# (i) MTIME MOVES, content and inode do not -> must NOT release.
# `-d @…` forces a mtime far from now, so this is deterministic rather than
# dependent on which second the test ran in. A bare touch is not exotic (a
# `find -exec touch`, a restore, a filesystem migration), and treating it as
# a close retires a live reviewer on the PREVIOUS round's sentinel (#469).
touch -d '@1900000000' "$STATE_DIR/skeptic/tgt9/DONE"
OUT=$(obl state "$ID9")
assert_contains "9a(i) a changed MTIME alone does NOT release" "$OUT" "state=live"

# (ii) CONTENT changes IN PLACE, inode does not -> MUST release.
# Kills an inode-only identity. Written with `>>` precisely so the inode
# survives; `close` normally republishes, but a gate that only notices
# republishing would miss any in-place close a future revision writes.
printf 'round 2 closed\n' >> "$STATE_DIR/skeptic/tgt9/DONE"
OUT=$(obl state "$ID9")
assert_contains "9a(ii) a CONTENT change at the same inode DOES release" \
                "$OUT" "state=void-pairing-closed"

# (iii) INODE changes, content IDENTICAL -> MUST release.
# Kills a content-only identity. This is the real shape of two closes inside
# one second: `_now_iso` is second-resolution, so the republished sentinel can
# be byte-identical while the inode is new.
reset_state
export OBL_TMUX_WINDOWS=$'tgt9\nsk9'
mkdir -p "$STATE_DIR/skeptic/tgt9"
printf 'identical bytes\n' > "$STATE_DIR/skeptic/tgt9/DONE"
ID9=$(obl open --debtor sk9 --creditor tgt9 --round 2)
cp -p "$STATE_DIR/skeptic/tgt9/DONE" "$STATE_DIR/skeptic/tgt9/.DONE.new"
touch -r "$STATE_DIR/skeptic/tgt9/DONE" "$STATE_DIR/skeptic/tgt9/.DONE.new"
mv -f "$STATE_DIR/skeptic/tgt9/.DONE.new" "$STATE_DIR/skeptic/tgt9/DONE"
OUT=$(obl state "$ID9")
assert_contains "9a(iii) a NEW INODE with identical bytes and mtime DOES release" \
                "$OUT" "state=void-pairing-closed"
run_gate OUT RC sk9
assert_eq "9a(iii) …and the gate clears" "$RC" "0"

# The real verb must produce that discriminator, or (iii) tests a property
# production does not have. Asserted rather than assumed.
reset_state
export OBL_TMUX_WINDOWS=$'tgtC\nskC'
env NEXUS_STATE_DIR="$STATE_DIR" bash "$_test_dir/skeptic-channel.sh" close tgtC >/dev/null 2>&1
INO1=$(stat -c %i "$STATE_DIR/skeptic/tgtC/DONE" 2>/dev/null)
env NEXUS_STATE_DIR="$STATE_DIR" bash "$_test_dir/skeptic-channel.sh" close tgtC >/dev/null 2>&1
INO2=$(stat -c %i "$STATE_DIR/skeptic/tgtC/DONE" 2>/dev/null)
assert_eq "9b \`skeptic-channel.sh close\` really does change the inode" \
    "$( [[ -n "$INO1" && -n "$INO2" && "$INO1" != "$INO2" ]] && echo differs || echo "same:$INO1/$INO2" )" \
    "differs"

# --- 9c. supersession: a TIE supersedes in NEITHER direction --------------
# The mutation this kills: `>=` (or `!=`) instead of `>`. A tie answers
# nothing about which reviewer is current, and a symmetric release makes BOTH
# retirable at once — two live reviewers destroyed on one ambiguous second.
# Same-second spawns are not exotic: `spawn-worker.sh` opens the target edge
# and the chain-root edge back to back.
reset_state
export OBL_TMUX_WINDOWS=$'tgtT\nskA\nskB'
obl open --debtor skA --creditor tgtT --round 1 --at 1700000000 >/dev/null
obl open --debtor skB --creditor tgtT --round 1 --at 1700000000 >/dev/null
OUT=$(obl state skA__tgtT__skeptic-verdict)
assert_contains "9c a TIE does not supersede (A)" "$OUT" "state=live"
OUT=$(obl state skB__tgtT__skeptic-verdict)
assert_contains "9c …nor in the other direction (B)" "$OUT" "state=live"
run_gate OUT RC skA; assert_eq "9c …and A still blocks" "$RC" "1"
run_gate OUT RC skB; assert_eq "9c …and B still blocks" "$RC" "1"

# --- 9d. supersession: STRICTLY later DOES supersede ----------------------
# The potency control for 9c. Without it, `if false` passes 9c trivially —
# the negative-control lesson from sk926's own retracted N1: a mutation that
# does not mutate proves nothing, and neither does an assertion that a
# disabled mechanism satisfies.
obl open --debtor skB --creditor tgtT --round 2 --at 1700000001 >/dev/null
OUT=$(obl state skA__tgtT__skeptic-verdict)
assert_contains "9d a STRICTLY later reviewer supersedes the earlier one" \
                "$OUT" "state=void-superseded"
run_gate OUT RC skA; assert_eq "9d …and the earlier one clears" "$RC" "0"
run_gate OUT RC skB; assert_eq "9d …while the later one still blocks" "$RC" "1"

# ── 10. D1: the gate's cost must not grow with the ledger ─────────────────
# `retire-preflight` check 1d is SYNCHRONOUS and pre-kill: every retirement
# on this board pays it. Measured on a ledger rebuilt from this workspace's
# own history (629 edges): 16-18s, and 7.1s even for a window that owes
# NOTHING. A safety gate people route around is worse than one that is merely
# slow, so the GROWTH is what is guarded here, not a constant.
#
# The property, not a stopwatch: the work is bounded by the edges that NAME
# the window, not by the ledger. A wall-clock assertion would be flaky on a
# shared cluster; this is deterministic.
echo "## 10. the pre-kill gate's cost is bounded by the window, not the ledger"
reset_state
export OBL_TMUX_WINDOWS=$'bulkT\nbulkD'
mkdir -p "$STATE_DIR/obligations"
for i in $(seq 1 200); do
    printf 'id\tnoise%s__noiseT%s__skeptic-verdict\ndebtor\tnoise%s\ncreditor\tnoiseT%s\nkind\tskeptic-verdict\nround\t1\nopened_at\t1700000000\nsettled_at\t\n' \
        "$i" "$i" "$i" "$i" > "$STATE_DIR/obligations/noise${i}__noiseT${i}__skeptic-verdict.rec" 2>/dev/null
done
obl open --debtor bulkD --creditor bulkT --round 1 >/dev/null
TOTAL=$(find "$STATE_DIR/obligations" -maxdepth 1 -name '*.rec' | wc -l | tr -d ' ')
assert_eq "the ledger really is large (potency control)" "$TOTAL" "201"
CAND=$( ( source "$_test_dir/_obligations.sh"; _obl_ids_matching "$STATE_DIR" "bulkD__*.rec" ) | wc -l | tr -d ' ')
assert_eq "…yet only the window's OWN edges are candidates" "$CAND" "1"
# LOSSLESSNESS is what makes that narrowing legitimate: the prefilter must
# never drop a record whose debtor field matches. Checked against a FULL scan
# — a prefilter that feeds a kill gate may narrow only where narrowing is
# provably safe, and "it looked right" is how a confident zero gets shipped.
FULL=$( ( source "$_test_dir/_obligations.sh"
          while IFS= read -r id; do
              [[ "$(obl_get "$STATE_DIR" "$id" debtor)" == "bulkD" ]] && printf '%s\n' "$id"
          done < <(obl_ids "$STATE_DIR") ) | sort)
PRE=$( ( source "$_test_dir/_obligations.sh"
         while IFS= read -r id; do
             [[ "$(obl_get "$STATE_DIR" "$id" debtor)" == "bulkD" ]] && printf '%s\n' "$id"
         done < <(_obl_ids_matching "$STATE_DIR" "bulkD__*.rec") ) | sort)
assert_eq "the prefilter is LOSSLESS against a full scan" "$PRE" "$FULL"
# And a window that owes nothing must not pay for the ledger at all — the
# 7.1s floor every retirement used to pay.
CAND0=$( ( source "$_test_dir/_obligations.sh"; _obl_ids_matching "$STATE_DIR" "owes-nothing__*.rec" ) | wc -l | tr -d ' ')
assert_eq "a window that owes nothing reads NO records" "$CAND0" "0"

# ── 11. F5: an orchestrator RESOLVE ends the pairing (nexus-code#926) ─────
# `void-creditor-clear` used to void a stale edge promptly; removing it (the
# #845 correction) widened F5's exposure — a target whose gate an orchestrator
# had resolved would leave its reviewer blocked with nothing left to signal.
#
# `ng skeptic resolve <window>` is an ORCHESTRATOR saying on the record that
# this window's validation is done. That is a statement about the PAIRING, so
# it now settles every reviewer of that window. The release stays POSITIVE —
# an audited decision, never an inference from an absent file — which is the
# property the whole correction rests on.
echo "## 11. resolve ends the pairing, on the record"
reset_state
export OBL_TMUX_WINDOWS=$'tgtR\nskR'
obl open --debtor skR --creditor tgtR --round 1 >/dev/null
mkdir -p "$STATE_DIR/skeptic/pending"; echo 1 > "$STATE_DIR/skeptic/pending/tgtR"
run_gate OUT RC skR
assert_eq "11 CONTROL the reviewer blocks before the resolve" "$RC" "1"
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE_DIR" \
    bash "$_test_dir/skeptic-channel.sh" resolve tgtR \
    --reason "verdict landed on the PR thread; no further pass warranted" >/dev/null 2>&1
OUT=$(obl state skR__tgtR__skeptic-verdict)
assert_contains "11 the resolve settles the reviewer's edge" "$OUT" "state=settled"
assert_contains "11 …carrying the operator's reason verbatim" "$OUT" "no further pass warranted"
run_gate OUT RC skR
assert_eq "11 …and the reviewer can retire" "$RC" "0"

# POTENCY CONTROL, in sk926's own words: a mutation that does not mutate
# proves nothing, and neither does a release that was going to happen anyway.
# An UNRELATED window's resolve must leave this pairing alone.
reset_state
export OBL_TMUX_WINDOWS=$'tgtR2\nskR2\nother'
obl open --debtor skR2 --creditor tgtR2 --round 1 >/dev/null
mkdir -p "$STATE_DIR/skeptic/pending"; echo 1 > "$STATE_DIR/skeptic/pending/other"
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE_DIR" \
    bash "$_test_dir/skeptic-channel.sh" resolve other \
    --reason "a different window entirely, resolved for unrelated reasons" >/dev/null 2>&1
OUT=$(obl state skR2__tgtR2__skeptic-verdict)
assert_contains "11 CONTROL another window's resolve settles nothing here" "$OUT" "state=live"

# ── 12. #1270 residual A: a PRUNE must not revoke a release ───────────────
# `void-pairing-closed` is DERIVED on every read from the creditor's DONE
# sentinel, and `dir:skeptic/{s}` is in BK_RETIRE_SURFACES — so `ng
# retire-window` `rm -rf`s the channel that holds it. Measured at 0b82ffb2:
# the moment the sentinel goes, `_obl_done_identity` answers `none`, `none`
# matches the baseline captured at open, and the edge silently reverts to
# `live` — stranding a DEBTOR that is a DIFFERENT window and did nothing.
#
# THE MUTATION PROOF IS CASE 12a's OWN FIRST HALF. Delete the
# `preserve-closures` call and 12a's post-prune assertions go RED with the
# edge back at `live`; that is the defect, reproduced, not a hypothetical.
echo "## 12. #1270 a prune must not revoke a release"
reset_state
export OBL_TMUX_WINDOWS=$'tgtP\nskP'
obl open --debtor skP --creditor tgtP --round 1 >/dev/null
run_gate OUT RC skP
assert_eq "12 CONTROL the debtor blocks before any close" "$RC" "1"
env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$STATE_DIR" \
    bash "$_test_dir/skeptic-channel.sh" close tgtP >/dev/null 2>&1
OUT=$(obl state skP__tgtP__skeptic-verdict)
assert_contains "12 the close releases the edge" "$OUT" "state=void-pairing-closed"
# NON-VACUITY: the sentinel must really be there, or the prune below removes
# nothing and the whole case passes while asserting no mechanism at all.
assert_eq "12 fixture: the DONE sentinel really exists" \
    "$( [[ -e "$STATE_DIR/skeptic/tgtP/DONE" ]] && echo yes || echo no )" "yes"
obl preserve-closures --creditor tgtP --by retire-window >/dev/null
bash -c 'source "$1/_bookkeeping.sh"; bk_prune_window_state "$2" tgtP' _ "$_test_dir" "$STATE_DIR"
assert_eq "12 fixture: the prune really destroyed the sentinel" \
    "$( [[ -e "$STATE_DIR/skeptic/tgtP/DONE" ]] && echo yes || echo no )" "no"
OUT=$(obl state skP__tgtP__skeptic-verdict)
assert_contains "12 the release SURVIVES the prune, durably in the ledger" "$OUT" "state=settled"
run_gate OUT RC skP
assert_eq "12 …and the debtor can still retire" "$RC" "0"

# NEGATIVE CONTROL — no close, so no sentinel and nothing is releasing.
# `preserve-closures` must settle NOTHING. A version that settled every edge
# of the creditor would pass 12a and launder a LIVE pairing into a release,
# which is strictly worse than the defect: it retires a window somebody is
# still waiting on.
reset_state
export OBL_TMUX_WINDOWS=$'tgtQ\nskQ'
obl open --debtor skQ --creditor tgtQ --round 1 >/dev/null
OUT=$(obl preserve-closures --creditor tgtQ --by retire-window)
assert_eq "12 CONTROL with no DONE, preserve-closures settles nothing" "$OUT" ""
OUT=$(obl state skQ__tgtQ__skeptic-verdict)
assert_contains "12 CONTROL …and the live edge is untouched" "$OUT" "state=live"
run_gate OUT RC skQ
assert_eq "12 CONTROL …so the debtor still BLOCKS" "$RC" "1"

# ---- summary -------------------------------------------------------------
#
# EXACT count guard. The ledger certifies that SOMETHING was asserted and
# that no FAIL was swallowed; it certifies NOTHING about HOW MUCH. A
# vanished assertion — an early `return`, a `continue` past a block, a case
# behind an env var nobody set — leaves the suite green and quieter. The two
# axes are independent and this suite carries both
# (monitor/watcher/summary-honesty.manifest).
#
# The comparison runs BEFORE it is itself counted, so the expected total is
# the number of cases above and does not include this line.
#
# ONE LINE, deliberately. `_count_axis` in test-summary-honesty-manifest.sh
# classifies by filtering to lines that carry BOTH an `EXPECTED…` operand and
# a count-ish name, then asking whether any of them is an assertion call. A
# backslash continuation splits those two facts across two lines and the
# guard reads as `count=none` — a suite under-crediting its own protection,
# which is the declared limit that file records about itself.
EXPECTED_ASSERTIONS=101
assert_eq "assertion-count guard: every assertion above actually ran" "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
