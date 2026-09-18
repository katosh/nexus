#!/usr/bin/env bash
# The orphan-async row's TERMINATING CONDITION, the authoritative wait list,
# and the reap of reported waits (your-org/nexus-code#1101 + companion).
#
# Run: bash monitor/watcher/test-orphan-async-terminate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# NO TMUX. Every pane observation is a stub; this suite cannot reach a tmux
# server, let alone the operator's.
#
# THREE PROPERTIES, AND THE NEGATIVES ARE THE POINT.
#
# 1. A row terminates when the pane is POSITIVELY GONE **and** every declared
#    wait REPORTED. `T1` proves it terminates; `T2*` prove each conjunct is
#    load-bearing by removing exactly one and requiring the row to SURVIVE. A
#    fix that cleared on pane-absence alone would pass T1 and reintroduce the
#    failure the hold exists to prevent, so T2/T3 are what make T1 mean
#    anything.
#
# 2. The wait list comes from the HEARTBEAT, not from the row's 80-char capped
#    display string. T5 is the `procmatch` reproduction — 8 waits, a row
#    holding 3 and a fragment — and T6 is the safety half: a RUNNING wait past
#    the cap must suppress the wake, which it cannot do while it is invisible.
#
# 3. Reported waits are reaped AFTER the worker is told, and only `terminal`
#    ones. R2/R3 pin the two ways that could go wrong: reaping a `died` wait
#    (laundering a truncated output into a green light) and reaping when the
#    paste FAILED (clearing the signal without delivering the message).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HELPER="$_test_dir/_orphan_async.sh"

. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0
ck()  { assert_eq "$1" "$2" "$3"; }
ckc() { assert_contains "$1" "$2" "$3"; }
ckn() { assert_not_contains "$1" "$2" "$3"; }

command -v jq >/dev/null 2>&1 || th_abort "jq is required: the authoritative wait list is read from the heartbeat with it"

WORK=$(mktemp -d -t nexus-1101-terminate-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR/heartbeat"

# shellcheck source=monitor/watcher/_orphan_async.sh
. "$HELPER"

NOW=$(date +%s)

# ---- recording seams ----------------------------------------------------
LOGF="$WORK/log";       : > "$LOGF"
PASTES="$WORK/pastes";  : > "$PASTES"
EVENTS="$WORK/events";  : > "$EVENTS"
REAPS="$WORK/reaps";    : > "$REAPS"

_rec_log()   { printf '%s\n' "$1" >> "$LOGF"; }
_rec_paste() { printf '%s\n' "$1" >> "$PASTES"; return 0; }
_fail_paste(){ printf '%s\n' "$1" >> "$PASTES"; return 1; }
_rec_event() { printf '%s\n' "$*" >> "$EVENTS"; }
_rec_reap()  { printf '%s %s %s\n' "$1" "$2" "$3" >> "$REAPS"; return 0; }
_fail_reap() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$REAPS"; return 1; }

_ORPHAN_ASYNC_LOG_FN=_rec_log
_ORPHAN_ASYNC_PASTE_FN=_rec_paste
_ORPHAN_ASYNC_LOGEVENT_FN=_rec_event
_ORPHAN_ASYNC_REAP_FN=_rec_reap

# Pane stub. MOCK_PANE_RC is what `pane-state.sh` would exit, RETURNED as this
# seam's exit status exactly as the real probe does — a global cannot carry it
# across the caller's command substitution, and the first draft of both sides
# used one, which is why this comment exists. MOCK_PANE is `<window>|<line>`
# rows; an absent row means no line.
_probe_stub() {
    printf '%s\n' "${MOCK_PANE:-}" | awk -F'|' -v k="$1" '$1 == k {print $2; exit}'
    return "${MOCK_PANE_RC:-0}"
}
_ORPHAN_ASYNC_PROBE_FN=_probe_stub

# Resolver stub. MOCK_RESOLVE is `<kind>:<id>|<class>|<detail>` rows.
_resolve_stub() {
    local w="$1:$2" out
    out=$(printf '%s\n' "${MOCK_RESOLVE:-}" | awk -F'|' -v k="$w" '$1 == k {printf "%s|%s", $2, $3; exit}')
    [[ -n "$out" ]] || out="unresolvable|no mock"
    printf '%s' "$out"
}
_ORPHAN_ASYNC_RESOLVE_FN=_resolve_stub

reset() {
    rm -f "$(_orphan_async_state_path)"
    rm -rf "$STATE_DIR/orphan-async-woken"
    : > "$LOGF"; : > "$PASTES"; : > "$EVENTS"; : > "$REAPS"
    MOCK_PANE=""; MOCK_PANE_RC=0; MOCK_RESOLVE=""
    _ORPHAN_ASYNC_PASTE_FN=_rec_paste
    _ORPHAN_ASYNC_REAP_FN=_rec_reap
}
row_exists() {   # <window> -> yes|no
    [[ -n "$(_orphan_async_load "$1")" ]] && echo yes || echo no
}
# A row already past its next-attempt gate and inside the ceiling.
seed_row() {   # <window> <waits-csv>
    _orphan_async_write_row "$1" "$2" "$(( NOW - 600 ))" "$(( NOW - 60 ))" 0
}
write_hb() {   # <window> <kind:id,…>
    local w="$1" csv="$2" arr
    arr=$(printf '%s' "$csv" | jq -R 'split(",") | map(select(length>0)) | map(split(":") | {kind: .[0], id: .[1], desc: ""})')
    jq -n --arg w "$w" --argjson a "$arr" \
        '{window: $w, last_activity: 0, external_waits: $a, dismissed_waits: []}' \
        > "$STATE_DIR/heartbeat/$w.json"
}

# ════════════════════════════════════════════════════════════════════════════
echo '=== T1: pane POSITIVELY gone + every wait terminal -> row CLOSED ==='
# ════════════════════════════════════════════════════════════════════════════
reset
W=gonewin
write_hb "$W" 'asyncrun:ar-1,asyncrun:ar-2'
MOCK_RESOLVE=$'asyncrun:ar-1|terminal|rc=0\nasyncrun:ar-2|terminal|rc=1'
MOCK_PANE=""; MOCK_PANE_RC=3          # pane-state.sh: no such tmux window
seed_row "$W" 'asyncrun:ar-1,asyncrun:ar-2'
_orphan_async_process_wakes ""
ck  "T1 the row is dropped"                 "$(row_exists "$W")" "no"
ckc "T1 the log names the inference"        "$(cat "$LOGF")" "is GONE from tmux and every declared wait REPORTED"
ckc "T1 a synthetic window-close is logged" "$(cat "$EVENTS")" "window-close"
ckc "T1 …with an explicit reason"           "$(cat "$EVENTS")" "reason=pane-vanished-unlogged"
ckc "T1 …naming the window"                 "$(cat "$EVENTS")" "window=$W"
ck  "T1 nothing was pasted into a dead pane" "$(wc -l < "$PASTES" | tr -d ' ')" "0"
# The window is gone; its heartbeat is the durable record of what it was
# waiting on. Tidying state nobody reads is not worth destroying evidence.
ck  "T1 the vanished window's waits are NOT reaped" "$(wc -l < "$REAPS" | tr -d ' ')" "0"

# ════════════════════════════════════════════════════════════════════════════
echo '=== T2: EACH CONJUNCT REMOVED -> the row must SURVIVE ==='
# ════════════════════════════════════════════════════════════════════════════
# THE LOAD-BEARING NEGATIVES. Pane-absence alone must never clear a row, or the
# hold this preserves has been deleted rather than terminated.
reset
W=gone-running
write_hb "$W" 'asyncrun:ar-1,asyncrun:ar-2'
MOCK_RESOLVE=$'asyncrun:ar-1|terminal|rc=0\nasyncrun:ar-2|running|pid 4242 alive'
MOCK_PANE=""; MOCK_PANE_RC=3
seed_row "$W" 'asyncrun:ar-1,asyncrun:ar-2'
_orphan_async_process_wakes ""
ck  "T2a pane GONE but a wait is RUNNING -> row SURVIVES" "$(row_exists "$W")" "yes"
ckn "T2a no synthetic close was logged"      "$(cat "$EVENTS")" "window-close"

reset
W=gone-died
write_hb "$W" 'asyncrun:ar-1'
# `died` = the pid is gone and NO status was written. The output is presumed
# TRUNCATED; this is exactly when a worker must be told, so it is NOT terminal.
MOCK_RESOLVE=$'asyncrun:ar-1|died|pid vanished, no status file'
MOCK_PANE=""; MOCK_PANE_RC=3
seed_row "$W" 'asyncrun:ar-1'
_orphan_async_process_wakes ""
ck  "T2b pane GONE but a wait DIED -> row SURVIVES (died is not terminal)" "$(row_exists "$W")" "yes"
ckc "T2b the hold says which conjunct failed" "$(cat "$LOGF")" "not every declared wait REPORTED"

reset
W=gone-unres
write_hb "$W" 'nohup:syn-abc'
MOCK_RESOLVE=$'nohup:syn-abc|unresolvable|synthetic id — no handle retained'
MOCK_PANE=""; MOCK_PANE_RC=3
seed_row "$W" 'nohup:syn-abc'
_orphan_async_process_wakes ""
ck  "T2c pane GONE but a wait UNRESOLVABLE -> row SURVIVES" "$(row_exists "$W")" "yes"

# ════════════════════════════════════════════════════════════════════════════
echo '=== T3: the pane could not be LOOKED AT -> row SURVIVES (rc != 3) ==='
# ════════════════════════════════════════════════════════════════════════════
# The other conjunct. Every non-3 rc means "we could not look", which is the
# original hold and must be untouched.
for _rc in 1 2 127; do
    reset
    W="blind$_rc"
    write_hb "$W" 'asyncrun:ar-1'
    MOCK_RESOLVE=$'asyncrun:ar-1|terminal|rc=0'
    MOCK_PANE=""; MOCK_PANE_RC="$_rc"
    seed_row "$W" 'asyncrun:ar-1'
    _orphan_async_process_wakes ""
    ck  "T3 probe rc=$_rc (could not look) + all terminal -> row SURVIVES" "$(row_exists "$W")" "yes"
    ckc "T3 rc=$_rc keeps the original wording" "$(cat "$LOGF")" "an unobserved pane is not a stalled one"
done

# ════════════════════════════════════════════════════════════════════════════
echo '=== T4: a TRUNCATED wait list can never satisfy an ALL-waits claim ==='
# ════════════════════════════════════════════════════════════════════════════
reset
W=truncwin
# No heartbeat at all, so the row's capped display string is all there is.
MOCK_RESOLVE=$'asyncrun:ar-1|terminal|rc=0\nasyncrun:ar-2|terminal|rc=0'
MOCK_PANE=""; MOCK_PANE_RC=3
seed_row "$W" 'asyncrun:ar-1,asyncrun:ar-2,asyn…'
_orphan_async_process_wakes ""
ck  "T4 pane GONE, visible waits terminal, list TRUNCATED -> row SURVIVES" "$(row_exists "$W")" "yes"
ckc "T4 the hold names truncation as the reason" "$(cat "$LOGF")" "TRUNCATED"

# ════════════════════════════════════════════════════════════════════════════
echo '=== T5: THE procmatch REPRODUCTION — the heartbeat is authoritative ==='
# ════════════════════════════════════════════════════════════════════════════
# Measured shape: eight declared asyncrun waits (199 chars), a row holding
# `asyncrun:ar-6e6d568dd44c,asyncrun:ar-800ece7b2cfe,asyncrun:ar-7c45a259b99a,asyn…`
# — three tokens and a fragment, capped at 80 by pane-state.sh's emit. Reading
# the row would leave T4's verdict forever; reading the heartbeat terminates.
reset
W=procmatch
IDS='ar-6e6d568dd44c ar-800ece7b2cfe ar-7c45a259b99a ar-73ee8619ec61 ar-23aab4a1bcc1 ar-0e5a9cf436a8 ar-3f27b7db7b7c ar-37f74b968990'
FULL=""; MOCK_RESOLVE=""
for _id in $IDS; do
    FULL="${FULL:+$FULL,}asyncrun:$_id"
    MOCK_RESOLVE="${MOCK_RESOLVE}asyncrun:$_id|terminal|rc=0"$'\n'
done
write_hb "$W" "$FULL"
CAPPED="${FULL:0:79}…"
ck  "T5 the fixture row really is the 80-char capped form" "${#CAPPED}" "80"
ckn "T5 …and the capped form is missing the last id" "$CAPPED" "ar-37f74b968990"
MOCK_PANE=""; MOCK_PANE_RC=3
seed_row "$W" "$CAPPED"
_orphan_async_process_wakes ""
ck  "T5 the row CLOSES once the full list is read from the heartbeat" "$(row_exists "$W")" "no"
ckc "T5 the close names all eight waits"  "$(cat "$LOGF")" "ar-37f74b968990"

# ════════════════════════════════════════════════════════════════════════════
echo '=== T5b: the HEARTBEAT as the ONLY variable — the retire-window boundary ==='
# ════════════════════════════════════════════════════════════════════════════
# `ng retire-window` DELETES `heartbeat/{w}.json` (it is in BK_RETIRE_SURFACES),
# which is where this loop now reads its authoritative wait list from. Same
# fixture as T5, heartbeat removed and nothing else changed:
#
#   heartbeat present -> row DROPPED, window-close reason=pane-vanished-unlogged
#   heartbeat deleted -> row HELD, "the declared wait list is TRUNCATED"
#
# The HELD verdict is CORRECT — a list we cannot vouch for must not satisfy a
# claim about all of its members — so this is a documented boundary, not a bug
# in this file. The fix lives one layer up: `orphan-async-state.tsv` and
# `orphan-async-woken/{s}` are now IN `BK_RETIRE_SURFACES`, so a window retired
# through the canonical verb has no row left for this path to evaluate.
# Asserted here so the two halves cannot drift apart silently.
reset
W=procmatch
write_hb "$W" "$FULL"
MOCK_RESOLVE=""
for _id in $IDS; do MOCK_RESOLVE="${MOCK_RESOLVE}asyncrun:$_id|terminal|rc=0"$'\n'; done
MOCK_PANE=""; MOCK_PANE_RC=3
rm -f "$STATE_DIR/heartbeat/$W.json"          # <- the ONLY variable
seed_row "$W" "$CAPPED"
_orphan_async_process_wakes ""
ck  "T5b heartbeat gone -> row HELD (fail-closed, not a silent clear)" "$(row_exists "$W")" "yes"
ckc "T5b …and the hold names truncation, not absence" "$(cat "$LOGF")" "TRUNCATED"
ckn "T5b …and NO synthetic window-close was logged"   "$(cat "$EVENTS")" "window-close"

# ════════════════════════════════════════════════════════════════════════════
echo '=== T6: THE SAFETY HALF — a RUNNING wait past the cap suppresses the wake ==='
# ════════════════════════════════════════════════════════════════════════════
# "A single `running` verdict suppresses the wake entirely" is this file's
# stated negative control, and a wait the cap removed cannot contribute one. So
# the truncation was a FAIL-OPEN in a fail-closed design: without the heartbeat
# read, this case wakes a worker whose job is still running.
reset
W=procmatch2
write_hb "$W" "$FULL"
MOCK_RESOLVE=""
_n=0
for _id in $IDS; do
    _n=$(( _n + 1 ))
    if (( _n == 8 )); then
        MOCK_RESOLVE="${MOCK_RESOLVE}asyncrun:$_id|running|pid 9999 alive"$'\n'
    else
        MOCK_RESOLVE="${MOCK_RESOLVE}asyncrun:$_id|terminal|rc=0"$'\n'
    fi
done
MOCK_PANE="$W|state=idle-orphan-async active=0 window=4 name=$W"
MOCK_PANE_RC=0
seed_row "$W" "$CAPPED"
_orphan_async_process_wakes ""
ck  "T6 no wake is delivered while wait 8 of 8 is RUNNING" "$(wc -l < "$PASTES" | tr -d ' ')" "0"
ckc "T6 the negative control names the running wait"       "$(cat "$LOGF")" "STILL RUNNING; not waking"
# The potency control for T6: the SAME fixture with wait 8 terminal MUST wake,
# or "no paste" would be true of an implementation that never wakes at all.
reset
W=procmatch2
write_hb "$W" "$FULL"
MOCK_RESOLVE=""
for _id in $IDS; do MOCK_RESOLVE="${MOCK_RESOLVE}asyncrun:$_id|terminal|rc=0"$'\n'; done
MOCK_PANE="$W|state=idle-orphan-async active=0 window=4 name=$W"
MOCK_PANE_RC=0
seed_row "$W" "$CAPPED"
_orphan_async_process_wakes ""
ck  "T6b CONTROL same fixture, wait 8 terminal -> the wake DOES fire" "$(wc -l < "$PASTES" | tr -d ' ')" "1"

# ════════════════════════════════════════════════════════════════════════════
echo '=== R1-R3: reported waits are reaped AFTER the wake, and only those ==='
# ════════════════════════════════════════════════════════════════════════════
reset
W=reapwin
write_hb "$W" 'asyncrun:ar-t1,asyncrun:ar-t2,asyncrun:ar-d1'
MOCK_RESOLVE=$'asyncrun:ar-t1|terminal|rc=0\nasyncrun:ar-t2|terminal|rc=2\nasyncrun:ar-d1|died|no status file'
MOCK_PANE="$W|state=idle-orphan-async active=0 window=5 name=$W"
MOCK_PANE_RC=0
seed_row "$W" 'asyncrun:ar-t1,asyncrun:ar-t2,asyncrun:ar-d1'
_orphan_async_process_wakes ""
ck  "R1 the worker was woken first"          "$(wc -l < "$PASTES" | tr -d ' ')" "1"
ckc "R1 the terminal wait ar-t1 was reaped"  "$(cat "$REAPS")" "$W asyncrun ar-t1"
ckc "R1 the terminal wait ar-t2 was reaped"  "$(cat "$REAPS")" "$W asyncrun ar-t2"
ckn "R2 the DIED wait was NOT reaped"        "$(cat "$REAPS")" "ar-d1"
ck  "R2 exactly two waits were reaped"       "$(wc -l < "$REAPS" | tr -d ' ')" "2"

reset
W=reapfail
write_hb "$W" 'asyncrun:ar-t1'
MOCK_RESOLVE=$'asyncrun:ar-t1|terminal|rc=0'
MOCK_PANE="$W|state=idle-orphan-async active=0 window=6 name=$W"
MOCK_PANE_RC=0
_ORPHAN_ASYNC_PASTE_FN=_fail_paste
seed_row "$W" 'asyncrun:ar-t1'
_orphan_async_process_wakes ""
ck  "R3 a FAILED paste reaps nothing (the worker was never told)" "$(wc -l < "$REAPS" | tr -d ' ')" "0"
ck  "R3 …and the row survives for the retry"                     "$(row_exists "$W")" "yes"

reset
W=reaperr
write_hb "$W" 'asyncrun:ar-t1'
MOCK_RESOLVE=$'asyncrun:ar-t1|terminal|rc=0'
MOCK_PANE="$W|state=idle-orphan-async active=0 window=7 name=$W"
MOCK_PANE_RC=0
_ORPHAN_ASYNC_REAP_FN=_fail_reap
seed_row "$W" 'asyncrun:ar-t1'
_orphan_async_process_wakes ""
ckc "R4 a reap that FAILS says so, with the hand remedy" "$(cat "$LOGF")" "declare-wait.sh --remove asyncrun ar-t1"

# ════════════════════════════════════════════════════════════════════════════
echo '=== M1-M3: MUTANT POTENCY — each mutant asserted applied, in a live copy ==='
# ════════════════════════════════════════════════════════════════════════════
# Three ways a verdict here could be meaningless, all checked: the sed matched
# nothing (asserted), the copy could not run at all (M0), and the mutant was
# never reached. M0 is the control an earlier suite in this bundle needed and
# did not have.
MUT="$WORK/mut"; mkdir -p "$MUT"
mut_run() {   # <name> <sed-expr|""> <driver-fn>
    local name="$1"
    local expr="$2"
    local driver="$3"
    local dst="$MUT/_orphan_async-$name.sh"
    cp "$HELPER" "$dst"
    if [[ -n "$expr" ]]; then
        sed -i "$expr" "$dst"
        if cmp -s "$HELPER" "$dst"; then
            assert_eq "mutant $name APPLIED (an inert mutant makes its verdict meaningless)" "inert" "applied"
            return 1
        fi
        assert_eq "mutant $name APPLIED" "applied" "applied"
    fi
    # Run the driver in a SUBSHELL sourcing the mutant, so the mutated
    # definitions cannot leak into the rest of this suite.
    ( . "$dst"
      _ORPHAN_ASYNC_LOG_FN=_rec_log
      _ORPHAN_ASYNC_PASTE_FN=_rec_paste
      _ORPHAN_ASYNC_LOGEVENT_FN=_rec_event
      _ORPHAN_ASYNC_REAP_FN=_rec_reap
      _ORPHAN_ASYNC_PROBE_FN=_probe_stub
      _ORPHAN_ASYNC_RESOLVE_FN=_resolve_stub
      "$driver" )
}
# The shared T1 fixture, re-seeded per mutant.
drive_t1() {
    MOCK_RESOLVE=$'asyncrun:ar-1|terminal|rc=0\nasyncrun:ar-2|terminal|rc=0'
    MOCK_PANE=""; MOCK_PANE_RC=3
    _orphan_async_process_wakes ""
}
setup_t1() { reset; W=mutwin; write_hb "$W" 'asyncrun:ar-1,asyncrun:ar-2'; seed_row "$W" 'asyncrun:ar-1,asyncrun:ar-2'; }

setup_t1; mut_run control "" drive_t1
ck "M0 CONTROL an unmutated copy still closes the row" "$(row_exists mutwin)" "no"

# M1 — ignore the probe rc. The row must stop terminating.
setup_t1
if mut_run rcblind 's/if (( probe_rc == 3 )) \&\& (( truncated == 0 )) \\/if false \&\& (( truncated == 0 )) \\/' drive_t1; then
    ck "M1 killed: probe rc ignored -> the row is held again" "$(row_exists mutwin)" "yes"
fi

# M2 — accept ANY non-running class as "reported". T2b (a DIED wait) must then
# wrongly close, which is the laundering this predicate exists to prevent.
drive_t2b() {
    MOCK_RESOLVE=$'asyncrun:ar-1|died|no status file'
    MOCK_PANE=""; MOCK_PANE_RC=3
    _orphan_async_process_wakes ""
}
reset; W=mutwin; write_hb "$W" 'asyncrun:ar-1'; seed_row "$W" 'asyncrun:ar-1'
if mut_run anyclass 's/\[\[ "$cls" == "terminal" \]\] || other=$(( other + 1 ))/[[ "$cls" != "running" ]] || other=$(( other + 1 ))/' drive_t2b; then
    ck "M2 killed: 'not running' as the predicate -> a DIED wait wrongly closes the row" \
       "$(row_exists mutwin)" "no"
fi

# M3 — do not read the heartbeat. T5 must revert to the truncated row.
drive_t5() {
    MOCK_RESOLVE=""
    for _id in $IDS; do MOCK_RESOLVE="${MOCK_RESOLVE}asyncrun:$_id|terminal|rc=0"$'\n'; done
    MOCK_PANE=""; MOCK_PANE_RC=3
    _orphan_async_process_wakes ""
}
reset; W=procmatch; write_hb "$W" "$FULL"; seed_row "$W" "$CAPPED"
if mut_run rowonly 's/    if full=$(_orphan_async_declared_waits "$window"); then/    if false; then/' drive_t5; then
    ck "M3 killed: heartbeat not read -> the truncated row holds forever again" \
       "$(row_exists procmatch)" "yes"
fi

# ---- the assertion COUNT, compared EXACTLY (#821 axis B) -----------------
# A suite can lose assertions silently: an arm that stops running still reports
# a clean green, and a FLOOR cannot catch that. Update this number DELIBERATELY
# when adding an arm; a mismatch is a red, not a warning.
EXPECTED_ASSERTIONS=45
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
