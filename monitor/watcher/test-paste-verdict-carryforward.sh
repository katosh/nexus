#!/usr/bin/env bash
# The SENDER's verdict must reach the watcher — your-org/nexus-code#665,
# the fourth false-positive shape that #668 deliberately left open.
#
# THE ASYMMETRY. `paste-followup.sh` polls the target's transcript at
# paste time, while the turn is fresh and the session-id is
# known-current, and reaches one of three verdicts:
#
#   rc 0  `submitted`               a submission record was OBSERVED
#   rc 3  `submission unconfirmed`  neither outcome established; the
#                                   text is plausibly QUEUED behind an
#                                   in-flight turn
#   rc 4  `pasted (NOT submitted)`  established negative — the #507
#                                   failure, the true positive
#
# That verdict then DIED WITH THE PROCESS. The watcher's
# `paste-unconfirmed` detector re-derived consumption from scratch
# minutes later, through `heartbeat/<window>.json`'s session-id — which
# can have rotated under a resume or a compaction — and told the
# operator "no submission found in the transcript" about pastes the
# sender had watched submit.
#
# Measured on the live action log, 2026-08-02: 20 pastes, 16 recorded
# rc 0, 4 recorded rc 3, and NOT ONE recorded rc 4. The detector fired
# 11 times that day with 0 true positives. Both fully documented
# decisive cases — a dashboard rewritten 10s after the paste, and a
# freshness stamp whose four specified corrections all landed — were
# pastes whose sender had recorded `submitted`.
#
# So: persist the verdict in a sidecar keyed by the SAME epoch stamped
# into machine-input.tsv, and let the detector consult it.
#
# THE DIRECTION THAT MATTERS. Only rc 0 suppresses. rc 3 must NOT — a
# paste genuinely lost during an in-flight turn has to stay catchable —
# and rc 4 must never suppress, because it IS the defect the detector
# exists for. Trading false positives for false negatives is the
# strictly worse direction: a lost paste is unrecoverable silence.
#
# Run: bash monitor/watcher/test-paste-verdict-carryforward.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SCRIPT="$_repo_root/monitor/paste-followup.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 (got '$2')"; else fail "$1 — got '$2' want '$3'"; fi; }
ck_has() {
    if grep -qF -- "$3" <<<"$2"; then pass "$1"
    else fail "$(printf '%s — %q not found in %q' "$1" "$3" "$2")"; fi
}
ck_not_has() {
    if grep -qF -- "$3" <<<"$2"; then
        fail "$(printf '%s — %q unexpectedly present in %q' "$1" "$3" "$2")"
    else pass "$1"; fi
}

WORK=$(mktemp -d -t nexus-665-verdict-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
# PART A — end-to-end: does paste-followup.sh actually WRITE the sidecar?
#
# Non-vacuity guard. Every assertion in Part B reads a sidecar; if the
# sender never writes one, or writes it under a name the detector does
# not look for, Part B would pass green against a file the production
# path never produces. So Part A runs the REAL script and asserts the
# real filename, then Part B consumes what Part A proved exists.
# ===========================================================================
echo "=== PART A: paste-followup.sh writes the verdict sidecar ==="

STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
ACTIONS="$WORK/actions.log"
CC_HOME="$WORK/cc"
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TRANSCRIPT="$CC_HOME/projects/-stub-slug/$SID.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
export MOCK_TRANSCRIPT="$TRANSCRIPT"

# Recorder tmux stub, byte-identical in behaviour to
# test-paste-followup.sh's: an accepted Enter appends a TUI-submission
# record; MOCK_NO_SUBMIT=1 swallows it, which is the #507 failure.
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "list-windows" ]]; then
    fmt=""; prev=""
    for a in "$@"; do [[ "$prev" == "-F" ]] && fmt="$a"; prev="$a"; done
    case "$fmt" in
        *window_id*)
            # Delimiter EXTRACTED from the requested format (your-org/nexus-code#699).
            d="${fmt#*'#{window_id}'}"; d="${d%%'#{window_name}'*}"
            for w in ${MOCK_TMUX_WINDOWS:-}; do printf '@3%s%s\n' "$d" "$w"; done ;;
        *)           printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    esac
    exit 0
fi
printf '%s\n' "$*" >> "$ACTIONS"
if [[ "$cmd" == "send-keys" && "${!#}" == "Enter" \
      && "${MOCK_NO_SUBMIT:-0}" != "1" && -n "${MOCK_TRANSCRIPT:-}" ]]; then
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the follow-up"}}\n' \
        >> "$MOCK_TRANSCRIPT"
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"
export ACTIONS
export PATH="$STUB_DIR:$PATH"

WIN=testwin
export MOCK_TMUX_WINDOWS="$WIN"
RUN_STATE="$WORK/state"
mkdir -p "$RUN_STATE/heartbeat"
export NEXUS_STATE_DIR="$RUN_STATE"
export NEXUS_CC_HOME="$CC_HOME"
export PASTE_NG_BIN="$STUB_DIR/ng-noop"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/ng-noop"; chmod +x "$STUB_DIR/ng-noop"
# Keep the confirm budget short so the rc-4 case does not stall the suite.
export PASTE_CONFIRM_TIMEOUT_SECONDS=2
export PASTE_CONFIRM_POLL_SECONDS=0.1

seed_session() {
    printf '{"state":"idle_prompt","last_activity":%s,"session_id":"%s","window":"%s"}\n' \
        "$(date +%s)" "$SID" "$WIN" > "$RUN_STATE/heartbeat/$WIN.json"
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the ORIGINAL spawn prompt"}}\n' \
        > "$TRANSCRIPT"
}

# Read the recorded rc, or print nothing when there is no readable
# sidecar. Split out so A1/A2 can assert EXISTENCE and CONTENT as two
# unconditional assertions: an `if … else fail` collapses two `ck`s
# into one on the failing arm, so a mutant that removes the sidecar
# drops the suite total 21 -> 20. A falling assertion count is exactly
# how a vacuous green hides (#676 skeptic F2), so the count is now
# invariant across every mutant rather than merely claimed to be.
verdict_rc_for() {
    local vf
    vf=$(verdict_file_for) || return 0
    [[ -n "$vf" && -r "$vf" ]] || return 0
    awk -F= '$1 == "rc" { print $2; exit }' "$vf" 2>/dev/null
}

verdict_file_for() {
    # The sidecar the sender wrote for the paste it just stamped. The
    # epoch is taken from machine-input.tsv, which is exactly how the
    # detector finds it — so a name mismatch fails here.
    local epoch
    epoch=$(awk -F'\t' -v w="$WIN" '$1 == w && $3 ~ /^paste-followup/ { e = $2 } END { print e }' \
            "$RUN_STATE/machine-input.tsv" 2>/dev/null)
    [[ -n "$epoch" ]] || return 1
    printf '%s/paste-verdicts/%s.%s' "$RUN_STATE" "$WIN" "$epoch"
}

# ---- A1: a confirmed submission records rc 0 -------------------------------
seed_session
rm -f "$RUN_STATE/machine-input.tsv"
MOCK_NO_SUBMIT=0 bash "$SCRIPT" "$WIN" --message "hello worker" >/dev/null 2>&1
a1_rc=$?
ck "A1 sender exit code is 0 (submitted)" "$a1_rc" 0
vf=$(verdict_file_for) || vf=""
if [[ -n "$vf" && -r "$vf" ]]; then
    pass "A1 sidecar exists at the epoch-keyed path the detector reads"
else
    fail "A1 NO sidecar at the epoch-keyed path — the detector would see 'unknown' forever, and Part B is vacuous"
fi
ck "A1 sidecar records rc=0" "$(verdict_rc_for)" 0

# ---- A2: an established non-submission records rc 4 ------------------------
# The true-positive path. If this recorded 0, the fix would MUTE the very
# defect the detector exists to catch.
seed_session
rm -f "$RUN_STATE/machine-input.tsv"
MOCK_NO_SUBMIT=1 bash "$SCRIPT" "$WIN" --message "lost paste" >/dev/null 2>&1
a2_rc=$?
ck "A2 sender exit code is 4 (established NOT submitted)" "$a2_rc" 4
ck "A2 sidecar records rc=4" "$(verdict_rc_for)" 4

# ---- A3: --no-enter makes no submission claim, so writes no verdict --------
seed_session
rm -f "$RUN_STATE/machine-input.tsv" "$RUN_STATE"/paste-verdicts/* 2>/dev/null
MOCK_NO_SUBMIT=0 bash "$SCRIPT" "$WIN" --no-enter --message "queued only" >/dev/null 2>&1
if vf=$(verdict_file_for) && [[ -r "$vf" ]]; then
    fail "A3 --no-enter wrote a verdict — it deliberately does not submit, so it must claim nothing"
else
    pass "A3 --no-enter writes no verdict (claims nothing)"
fi

unset NEXUS_STATE_DIR NEXUS_CC_HOME PASTE_NG_BIN MOCK_TMUX_WINDOWS
unset PASTE_CONFIRM_TIMEOUT_SECONDS PASTE_CONFIRM_POLL_SECONDS

# ===========================================================================
# PART B — the detector consults it, with the right polarity.
# ===========================================================================
printf '\n=== PART B: the detector consults the verdict ===\n'

STATE_DIR="$WORK/bstate"
mkdir -p "$STATE_DIR/heartbeat" "$STATE_DIR/paste-verdicts"
# shellcheck source=monitor/watcher/_idle_probe.sh
source "$_repo_root/monitor/watcher/_idle_probe.sh" \
    || { echo "cannot source _idle_probe.sh" >&2; exit 1; }

BWIN=bwin
NOW=2000000000
PRE=1999999000

printf '{"session_id":"deadbeef"}\n' > "$STATE_DIR/heartbeat/$BWIN.json"
_idle_window_spawn_ts()      { printf ''; }
_openg_user_prompt_epoch()   { printf '0'; }
_paste_confirm_grace_seconds() { printf '180'; }
_machine_input_path()        { printf '%s/machine-input.tsv' "$STATE_DIR"; }
# THE LIVE CONDITION. The transcript re-scan answers `no` — a stale
# session-id, exactly as diagnosed on #665. Every case below therefore
# tests the verdict path in isolation: without it the detector fires.
_idle_paste_consumed()       { printf 'no'; }

printf '%s\t%s\t%s\n' "$BWIN" "$PRE" paste-followup > "$STATE_DIR/machine-input.tsv"
set_verdict() { printf 'rc=%s\nwindow=%s\nepoch=%s\noutcome=stub\n' "$1" "$BWIN" "$PRE" \
                    > "$STATE_DIR/paste-verdicts/$BWIN.$PRE"; }
clear_verdict() { rm -f "$STATE_DIR/paste-verdicts/$BWIN".* ; }

# ---- B0: baseline — no verdict, transcript says no → FIRES ----------------
# Establishes that every suppression below is caused by the verdict and
# nothing else. Without this the suite could be green because the
# detector never fires at all.
clear_verdict
ck "B0 no verdict → fires (baseline: the suite can detect a change)" \
   "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" "$PRE"

# ---- B1: THE DEFECT — sender said `submitted`, so the flag is wrong -------
set_verdict 0
ck "B1 sender rc=0 → suppressed even though the re-scan says 'no'" \
   "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" 0

# ---- B2: rc 4 is the true positive and must STILL fire --------------------
set_verdict 4
ck "B2 sender rc=4 (established non-submission) → still fires" \
   "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" "$PRE"
# TENSE (#676 skeptic F1). Evidence of presence does not expire;
# evidence of ABSENCE does. rc=4 was established at paste time and is
# rendered ≥180s later, so the note must scope itself to when the
# sender looked and must not assert a present-tense non-delivery into
# an emit reworded precisely to stop doing that.
ck_has "B2 note scopes the observation to paste time" \
   "$(_idle_paste_verdict_note "$BWIN" "$PRE" "$NOW")" "when it pasted"
ck_has "B2 note states it has not been re-checked" \
   "$(_idle_paste_verdict_note "$BWIN" "$PRE" "$NOW")" "NOT re-checked since"
# OVER-REACH. rc=4 measures the TRANSCRIPT — no submission record, no
# growth, unchanged session-id. It never observed where the bytes are.
ck_not_has "B2 note does NOT claim to know where the text is" \
   "$(_idle_paste_verdict_note "$BWIN" "$PRE" "$NOW")" "input box"
ck_has "B2 note carries the age of the observation" \
   "$(_idle_paste_verdict_note "$BWIN" "$PRE" "$NOW")" "$(( NOW - PRE ))s ago"

# ---- B3: rc 3 must NOT suppress — a lost paste stays catchable ------------
set_verdict 3
ck "B3 sender rc=3 (could not establish either) → still fires" \
   "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" "$PRE"
ck_has "B3 note hedges rather than asserting non-delivery" \
   "$(_idle_paste_verdict_note "$BWIN" "$PRE" "$NOW")" "could not establish either outcome"
ck_has "B3 note states it has not been re-checked" \
   "$(_idle_paste_verdict_note "$BWIN" "$PRE" "$NOW")" "not re-checked since"
# The age suffix is optional: a caller with no clock must still get a
# usable note rather than a broken one.
ck_not_has "B3 note omits the age when no clock is supplied" \
   "$(_idle_paste_verdict_note "$BWIN" "$PRE")" "ago"

# ---- B4: a verdict for a DIFFERENT paste must not be borrowed ------------
# The epoch is the key. An older paste's `submitted` must never vouch for
# a newer one, or one good paste silences the window indefinitely.
clear_verdict
printf 'rc=0\n' > "$STATE_DIR/paste-verdicts/$BWIN.$(( PRE - 500 ))"
ck "B4 verdict keyed to another epoch is ignored → still fires" \
   "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" "$PRE"

# ---- B5: another window's verdict must not be borrowed -------------------
clear_verdict
printf 'rc=0\n' > "$STATE_DIR/paste-verdicts/otherwin.$PRE"
ck "B5 another window's verdict is ignored → still fires" \
   "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" "$PRE"
rm -f "$STATE_DIR/paste-verdicts/otherwin.$PRE"

# ---- B6: malformed sidecar degrades to unknown, never to 'consumed' ------
clear_verdict
printf 'garbage not a verdict\n' > "$STATE_DIR/paste-verdicts/$BWIN.$PRE"
ck "B6 malformed verdict → unknown, so the detector still fires" \
   "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" "$PRE"
ck "B6 malformed verdict reads as empty (not as 0)" \
   "$(_idle_paste_verdict "$BWIN" "$PRE")" ""

# ---- B7: an unreadable sidecar is unknown, not a suppression -------------
clear_verdict
set_verdict 0
chmod 000 "$STATE_DIR/paste-verdicts/$BWIN.$PRE" 2>/dev/null
if [[ -r "$STATE_DIR/paste-verdicts/$BWIN.$PRE" ]]; then
    pass "B7 skipped (running as a user who can read 000 — root?)"
else
    ck "B7 unreadable verdict → unknown, so the detector still fires" \
       "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" "$PRE"
fi
chmod 644 "$STATE_DIR/paste-verdicts/$BWIN.$PRE" 2>/dev/null

# ---- B8: the transcript surface still suppresses on its own ---------------
# The #607 path must survive: with no verdict at all, a transcript that
# says `yes` still clears the flag.
clear_verdict
_idle_paste_consumed() { printf 'yes'; }
ck "B8 no verdict + transcript says yes → suppressed (#607 path intact)" \
   "$(_idle_unconfirmed_paste_epoch "$BWIN" "$NOW")" 0
_idle_paste_consumed() { printf 'no'; }

# ---- B9: pruning drops the window's verdicts, keeps others ---------------
set_verdict 0
printf 'rc=0\n' > "$STATE_DIR/paste-verdicts/keepwin.$PRE"
_paste_verdict_drop "$BWIN"
if [[ -e "$STATE_DIR/paste-verdicts/$BWIN.$PRE" ]]; then
    fail "B9 prune left the disappeared window's verdict behind"
else
    pass "B9 prune drops the disappeared window's verdict"
fi
if [[ -e "$STATE_DIR/paste-verdicts/keepwin.$PRE" ]]; then
    pass "B9 prune leaves other windows' verdicts alone"
else
    fail "B9 prune deleted an unrelated window's verdict"
fi

# ---- B10: prune is safe when the directory does not exist ----------------
rm -rf "$STATE_DIR/paste-verdicts"
if _paste_verdict_drop "$BWIN" 2>/dev/null; then
    pass "B10 prune on a missing directory is a no-op, not an error"
else
    fail "B10 prune errored on a missing directory"
fi

# ---------------------------------------------------------------------------
printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
