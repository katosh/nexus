#!/usr/bin/env bash
# Tests for the over-limit RESET-HORIZON clock arithmetic
# (your-org/nexus-code#581) — the defect that left an orchestrator and three
# workers suspended overnight on 2026-07-28 and required a human to revive
# them at 09:50 the next morning.
#
# Why a separate file from test-over-limit.sh: that file asserts only that a
# token "resolves to a future epoch within 26h" because the parser consulted
# the real wall clock and could not be pinned. That looseness is precisely
# what let the ratchet ship. Everything here is pinned to an exact instant.
#
# Covered:
#   - the pure parser at EVENING-LOCAL instants that fall on the following
#     UTC day (17:05 / 21:48 / 23:59 PDT), plus just-after-midnight and
#     just-after-the-reset, so neither a day-late nor a day-early answer
#     passes
#   - the RATCHET: refreshing an unchanged hold must not move its horizon
#   - backoff progress surviving a refresh
#   - the absolute max-hold ceiling firing on a row parked in the far future
#   - DST correctness across the LA spring-forward boundary
#   - `midnight_UTC` — a documented token shape that never resolved
#   - NEGATIVE CONTROL: the pre-fix implementations, embedded verbatim, run
#     through the SAME assertions and must FAIL them, reproducing the exact
#     epoch observed in production (1785405600)
#
# Run: bash monitor/watcher/test-over-limit-reset-clock.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/watcher/_over_limit.sh"
[[ -f "$HELPER" ]] || { echo "helper not found: $HELPER" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
export STATE_DIR

# ---- pinned clock ---------------------------------------------------------
#
# A shell function shadows the `date` BUILTIN-less external for every caller
# in this process and its command-substitution subshells, which is what the
# helper uses. Two behaviours:
#
#   `date +%s`            → FAKE_NOW verbatim (pins _over_limit_record)
#   `date -d "<x> today"` → resolves "today" against FAKE_NOW in the ACTIVE
#                           zone, exactly as the real `date` would at that
#                           instant. Only the legacy implementation below
#                           uses this form; the fixed parser anchors
#                           explicitly and needs no rewriting.
#
# Everything else passes through untouched.
date() {
    if [[ -n "${FAKE_NOW:-}" ]]; then
        if [[ "$1" == "+%s" && $# -eq 1 ]]; then
            printf '%s\n' "$FAKE_NOW"
            return 0
        fi
        if [[ "$1" == "-d" && "$2" == *" today" ]]; then
            local anchor spec
            anchor=$(command date -d "@$FAKE_NOW" +%F) || return 1
            spec="${2% today} $anchor"
            command date -d "$spec" "${@:3}"
            return $?
        fi
    fi
    command date "$@"
}

# Epoch of a wall-clock instant in a named zone — the test's own arithmetic,
# deliberately independent of the code under test.
at() {   # <zone> <"YYYY-MM-DD HH:MM:SS">
    command date -d "TZ=\"$1\" $2" +%s
}
show() {  # <zone> <epoch>
    TZ="$1" command date -d "@$2" '+%F %T %Z'
}

# shellcheck disable=SC1090
source "$HELPER"

LA=America/Los_Angeles
TOKEN="3am_${LA}"

# ---- the production incident, to the second -------------------------------
# Stamped 2026-07-28 21:48:38 PDT; the state file recorded 1785405600 as the
# reset (2026-07-30 03:00 PDT) with attempts=0 — a wake that was never due.
INCIDENT_STAMP=1785300518          # 2026-07-28 21:48:38 PDT
INCIDENT_CORRECT=1785319200        # 2026-07-29 03:00:00 PDT — the next 3am
INCIDENT_OBSERVED=1785405600       # 2026-07-30 03:00:00 PDT — a day late

echo '=== fixture sanity: the incident epochs are what we think they are ==='
assert_eq "stamp is 2026-07-28 21:48:38 PDT" \
    "$(show "$LA" "$INCIDENT_STAMP")" "2026-07-28 21:48:38 PDT"
assert_eq "correct reset is 2026-07-29 03:00 PDT" \
    "$(show "$LA" "$INCIDENT_CORRECT")" "2026-07-29 03:00:00 PDT"
assert_eq "observed reset is 2026-07-30 03:00 PDT (a day late)" \
    "$(show "$LA" "$INCIDENT_OBSERVED")" "2026-07-30 03:00:00 PDT"
# The stamp sits past midnight UTC while still being the 28th locally — the
# UTC/local skew that made this look like a timezone bug.
assert_eq "stamp is already the NEXT day in UTC" \
    "$(TZ=UTC command date -d "@$INCIDENT_STAMP" +%F)" "2026-07-29"

# ---- boundary table -------------------------------------------------------
#
# `<pinned local instant>|<expected reset instant>`. The first three are the
# evening window in which a long session actually exhausts its budget, and
# all three fall on the following UTC day. The fourth is just after local
# midnight — today's 3am is still AHEAD, so answering "tomorrow" would wake a
# day early. The fifth is just after the reset, where tomorrow is genuinely
# the right answer.
CASES=(
    "2026-07-28 17:05:00|2026-07-29 03:00:00"
    "2026-07-28 21:48:38|2026-07-29 03:00:00"
    "2026-07-28 23:59:00|2026-07-29 03:00:00"
    "2026-07-29 00:05:00|2026-07-29 03:00:00"
    "2026-07-29 03:05:00|2026-07-30 03:00:00"
    "2026-07-29 02:59:59|2026-07-29 03:00:00"
    # LA spring-forward: the pre-fix `+86400` lands on 4am PDT.
    "2026-03-07 21:00:00|2026-03-08 03:00:00"
    # LA fall-back (skeptic suggestion). 2026-11-01 is a 25-HOUR local day, so
    # this delta is 89999s — the case that fixes the parser's upper band at
    # 90000 rather than something tidier like 86400+ε. A tighter bound would
    # reject a legitimate horizon twice a year and silently take the 6h
    # fallback. Pinning it here stops anyone "simplifying" 90000 to 86400.
    "2026-10-31 03:00:01|2026-11-01 03:00:00"
)

# Runs the whole table against a named parser implementation. Prints one
# `FAIL <case>` line per mismatch on stdout and returns the failure count, so
# the negative control can assert on the failures instead of the passes.
run_case_table() {   # <parser-fn>
    local parser="$1" case_spec pin_wall want_wall pin want got fails=0
    for case_spec in "${CASES[@]}"; do
        pin_wall="${case_spec%%|*}"
        want_wall="${case_spec##*|}"
        pin=$(at "$LA" "$pin_wall")
        want=$(at "$LA" "$want_wall")
        got=$(FAKE_NOW="$pin" "$parser" "$TOKEN" "$pin")
        if [[ "$got" != "$want" ]]; then
            printf 'FAIL %s -> %s (want %s)\n' \
                "$pin_wall" "$(show "$LA" "$got")" "$want_wall"
            fails=$(( fails + 1 ))
        fi
    done
    return "$fails"
}

echo '=== parser: next local 3am, pinned at evening/boundary instants ==='
table_out=$(run_case_table _over_limit_reset_at_to_epoch)
table_fails=$?
if (( table_fails == 0 )); then
    printf '  PASS: all %d pinned boundary cases resolve to the next local 3am\n' \
        "${#CASES[@]}"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %d/%d boundary cases wrong:\n%s\n' \
        "$table_fails" "${#CASES[@]}" "$table_out" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== parser: the incident instant resolves to the SAME-day 3am ==='
got=$(FAKE_NOW="$INCIDENT_STAMP" \
    _over_limit_reset_at_to_epoch "$TOKEN" "$INCIDENT_STAMP")
assert_eq "21:48 PDT stamp → next 3am is 2026-07-29, not 07-30" \
    "$got" "$INCIDENT_CORRECT"
if [[ "$got" == "$INCIDENT_OBSERVED" ]]; then
    printf '  FAIL: parser reproduces the production day-late epoch\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: parser does not reproduce the day-late epoch\n'
    PASS=$(( PASS + 1 ))
fi

echo '=== parser: result is always in (now, now+25h] ==='
band_bad=0
for case_spec in "${CASES[@]}"; do
    pin=$(at "$LA" "${case_spec%%|*}")
    got=$(FAKE_NOW="$pin" _over_limit_reset_at_to_epoch "$TOKEN" "$pin")
    (( got > pin && got <= pin + 90000 )) || band_bad=$(( band_bad + 1 ))
done
assert_eq "no case escapes the 25h band" "$band_bad" "0"

echo '=== parser: purity — the answer does not depend on the wall clock ==='
# Same (token, now), two different real wall clocks. The old parser read the
# real clock for "today", so these differed; they must not now.
a=$(FAKE_NOW=$(( INCIDENT_STAMP + 400000 )) \
    _over_limit_reset_at_to_epoch "$TOKEN" "$INCIDENT_STAMP")
b=$(_over_limit_reset_at_to_epoch "$TOKEN" "$INCIDENT_STAMP")
assert_eq "pinned and unpinned agree for an explicit now" "$a" "$b"
assert_eq "and both are the correct answer"               "$a" "$INCIDENT_CORRECT"

echo '=== parser: DST — next 3am across LA spring-forward ==='
# 2026-03-08 is the spring-forward day. Adding a flat 86400s to 3am PST lands
# on 4am PDT; the correct answer is 3am PDT on the next calendar day.
dst_pin=$(at "$LA" "2026-03-07 21:00:00")
dst_want=$(at "$LA" "2026-03-08 03:00:00")
got=$(FAKE_NOW="$dst_pin" _over_limit_reset_at_to_epoch "$TOKEN" "$dst_pin")
assert_eq "3am stays 3am across the DST boundary" \
    "$(show "$LA" "$got")" "$(show "$LA" "$dst_want")"

echo '=== parser: documented token shapes resolve (no silent fallback) ==='
pin=$(at UTC "2026-07-28 21:00:00")
fallback=$(( pin + 21600 ))
got=$(FAKE_NOW="$pin" _over_limit_reset_at_to_epoch "midnight_UTC" "$pin")
assert_eq "midnight_UTC → next UTC midnight, not the 6h fallback" \
    "$got" "$(at UTC "2026-07-29 00:00:00")"
if [[ "$got" == "$fallback" ]]; then
    printf '  FAIL: midnight_UTC still takes the safety fallback\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: midnight_UTC no longer takes the safety fallback\n'
    PASS=$(( PASS + 1 ))
fi
got=$(FAKE_NOW="$pin" _over_limit_reset_at_to_epoch "11pm_UTC" "$pin")
assert_eq "11pm_UTC → 23:00 the same UTC day" \
    "$got" "$(at UTC "2026-07-28 23:00:00")"

# ---- the ratchet, at the record level -------------------------------------

reset_rows() { rm -f "$STATE_DIR/over-limit-state.tsv"; }
row_field() { awk -F'\t' -v n="$2" '{print $n}' <<<"$(_over_limit_load "$1")"; }

echo '=== RATCHET: refreshing an unchanged hold must not move the horizon ==='
reset_rows
FAKE_NOW="$INCIDENT_STAMP" _over_limit_record \
    "_orchestrator" "orchestrator" "orchestrator" "$TOKEN"
first_reset=$(row_field _orchestrator 5)
first_next=$(row_field _orchestrator 7)
assert_eq "initial horizon is the next local 3am" "$first_reset" "$INCIDENT_CORRECT"

# Now replay the scan loop across the reset instant. `_over_limit_scan_panes`
# re-records every 60s for as long as the pane reads over-limit, and it keeps
# reading over-limit because the banner never repaints on its own.
for offset in -600 -120 -1 0 30 300 3600; do
    FAKE_NOW=$(( INCIDENT_CORRECT + offset )) _over_limit_record \
        "_orchestrator" "orchestrator" "orchestrator" "$TOKEN"
done
after_reset=$(row_field _orchestrator 5)
after_next=$(row_field _orchestrator 7)
assert_eq "horizon survives refreshes across the reset instant" \
    "$after_reset" "$INCIDENT_CORRECT"
assert_eq "next_attempt survives too"  "$after_next"  "$first_next"
if [[ "$after_reset" == "$INCIDENT_OBSERVED" ]]; then
    printf '  FAIL: refresh reproduced the production day-late horizon\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: refresh does not ratchet to the following day\n'
    PASS=$(( PASS + 1 ))
fi
# The wake must actually become due — the whole point.
if (( after_next <= INCIDENT_CORRECT + 3600 )); then
    printf '  PASS: wake is due within an hour of the reset\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: wake parked at %s, %ss past the reset\n' \
        "$(show "$LA" "$after_next")" "$(( after_next - INCIDENT_CORRECT ))" >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== refresh preserves backoff progress ==='
reset_rows
FAKE_NOW="$INCIDENT_STAMP" _over_limit_record \
    "worker-a" "worker-a" "worker" "$TOKEN"
# The wake loop backs off by rewriting next_attempt directly; a refresh a
# moment later must not undo it.
_over_limit_apply_backoff "worker-a" "worker-a" "worker" "$TOKEN" \
    "$INCIDENT_CORRECT" "$INCIDENT_STAMP" 2 "$INCIDENT_CORRECT"
backed_off=$(row_field worker-a 7)
FAKE_NOW=$(( INCIDENT_CORRECT + 30 )) _over_limit_record \
    "worker-a" "worker-a" "worker" "$TOKEN"
assert_eq "backoff next_attempt survives a scan refresh" \
    "$(row_field worker-a 7)" "$backed_off"

echo '=== a CHANGED token still moves the horizon ==='
reset_rows
FAKE_NOW="$INCIDENT_STAMP" _over_limit_record \
    "worker-b" "worker-b" "worker" "$TOKEN"
FAKE_NOW=$(( INCIDENT_STAMP + 60 )) _over_limit_record \
    "worker-b" "worker-b" "worker" "5am_${LA}"
assert_eq "renderer stating a new reset time is honoured" \
    "$(row_field worker-b 5)" "$(at "$LA" "2026-07-29 05:00:00")"

echo '=== SELF-HEAL: an already-ratcheted row is repaired, not carried forward ==='
# The four rows the production state file held, verbatim. On upgrade the
# token is unchanged, so the preserve-on-refresh rule would keep the bad
# horizon and the stall would survive the fix. A horizon >25h past first_seen
# is impossible for a date-less token, so it is re-derived from first_seen.
reset_rows
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "_orchestrator" "orchestrator" "orchestrator" "$TOKEN" \
    "$INCIDENT_OBSERVED" "$INCIDENT_STAMP" "1785405900" 0 \
    > "$STATE_DIR/over-limit-state.tsv"
_OVER_LIMIT_LOG_FN=noop_log
noop_log() { :; }
# Refresh the morning after, while the pane still reads over-limit.
heal_now=$(at "$LA" "2026-07-29 09:50:00")
FAKE_NOW="$heal_now" _over_limit_record \
    "_orchestrator" "orchestrator" "orchestrator" "$TOKEN"
assert_eq "ratcheted horizon re-derived to the reset it should have had" \
    "$(row_field _orchestrator 5)" "$INCIDENT_CORRECT"
assert_eq "first_seen is not disturbed by the repair" \
    "$(row_field _orchestrator 6)" "$INCIDENT_STAMP"
healed_next=$(row_field _orchestrator 7)
if (( healed_next <= heal_now + 300 )); then
    printf '  PASS: healed row wakes promptly (next_attempt within 5min)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: healed row still parked at %s\n' "$(show "$LA" "$healed_next")" >&2
    FAIL=$(( FAIL + 1 ))
fi
# And re-deriving must NOT be done at `now` — that reproduces the ratchet.
if [[ "$(row_field _orchestrator 5)" == "$INCIDENT_OBSERVED" ]]; then
    printf '  FAIL: repair re-derived at now and reproduced the ratchet\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: repair anchored at first_seen, not now\n'
    PASS=$(( PASS + 1 ))
fi

echo '=== SELF-HEAL: the OVERLAP row a threshold could not catch (finding B) ==='
# Skeptic finding B on #582: the old `> first_seen + 90000` threshold missed a
# row stamped less than an hour before its reset. Legitimate horizons occupy
# (first, first+90000] and ratcheted ones (first+86400, first+176400] — they
# OVERLAP, so no threshold discriminates. The exact re-derivation does.
reset_rows
gap_first=$(at "$LA" "2026-07-29 02:30:00")     # 30 min before the reset
gap_correct=$(at "$LA" "2026-07-29 03:00:00")
gap_ratcheted=$(at "$LA" "2026-07-30 03:00:00") # what the old code stored
assert_eq "precondition: this row sits INSIDE the old threshold's blind spot" \
    "$(( gap_ratcheted - gap_first <= 90000 ))" "1"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "worker-gap" "worker-gap" "worker" "$TOKEN" \
    "$gap_ratcheted" "$gap_first" "$(( gap_ratcheted + 300 ))" 0 \
    > "$STATE_DIR/over-limit-state.tsv"
_over_limit_observation_set "worker-gap" "$gap_first"
FAKE_NOW=$(( gap_correct + 3600 )) _over_limit_record \
    "worker-gap" "worker-gap" "worker" "$TOKEN"
assert_eq "overlap-region ratcheted row IS healed" \
    "$(row_field worker-gap 5)" "$gap_correct"

echo '=== SELF-HEAL does not fire on a legitimate horizon ==='
reset_rows
FAKE_NOW="$INCIDENT_STAMP" _over_limit_record \
    "worker-c" "worker-c" "worker" "$TOKEN"
_over_limit_apply_backoff "worker-c" "worker-c" "worker" "$TOKEN" \
    "$INCIDENT_CORRECT" "$INCIDENT_STAMP" 2 "$INCIDENT_STAMP"
legit_next=$(row_field worker-c 7)
FAKE_NOW=$(( INCIDENT_STAMP + 120 )) _over_limit_record \
    "worker-c" "worker-c" "worker" "$TOKEN"
assert_eq "a plausible horizon is preserved untouched" \
    "$(row_field worker-c 5)" "$INCIDENT_CORRECT"
assert_eq "…and so is its backoff" "$(row_field worker-c 7)" "$legit_next"

echo '=== max-hold ceiling fires on a row parked in the far future ==='
# Fix 3: the ceiling used to sit BEHIND the not-due guard, so a row whose
# next_attempt had been pushed a day out could never reach it. That is why
# the 25h ceiling did not end the 2026-07-28 hold.
reset_rows
PASTED="$WORK/paste.log"; : > "$PASTED"
_OVER_LIMIT_LOG_FN=noop_log
_OVER_LIMIT_PASTE_FN=capture_paste
noop_log() { :; }
capture_paste() { printf '%s\n' "$1" >> "$PASTED"; return 0; }
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "_orchestrator" "orchestrator" "orchestrator" "$TOKEN" \
    "$INCIDENT_OBSERVED" "$INCIDENT_STAMP" "$(( INCIDENT_OBSERVED + 300 ))" 0 \
    > "$STATE_DIR/over-limit-state.tsv"
_over_limit_observation_set "_orchestrator" "$INCIDENT_STAMP"
# 26h after first_seen — past the 25h ceiling, but still long before the
# parked next_attempt.
_over_limit_evaluate_row \
    "$(cat "$STATE_DIR/over-limit-state.tsv")" "$(( INCIDENT_STAMP + 93600 ))"
assert_contains "ceiling pasted the resume brief" "$(cat "$PASTED")" "orchestrator"
assert_no_file  "ceiling dropped the row"         "$STATE_DIR/over-limit-state.tsv"

# ---- suppression must clear on OBSERVED liveness (#592) -------------------
#
# The 2026-07-29 blackout: for >15h the watcher composed an emit every ~50s,
# archived it, then refused to paste, because `_over_limit_orchestrator_paused`
# trusted row EXISTENCE. An operator comment and four spawn-skeptic requests
# were silently withheld while the orchestrator heartbeat was current to the
# second. That is a strictly worse failure than the late wake, and it needs its
# own guarantee: a computed instant may gate the NUDGE, never the SUPPRESSION.

echo '=== gate: a row observed recently DOES suppress ==='
reset_rows
_OVER_LIMIT_LOG_FN=noop_log
noop_log() { :; }
gate_now=$(at "$LA" "2026-07-29 09:50:00")
write_row() {   # <observed-epoch> [next_attempt]
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "_orchestrator" "orchestrator" "orchestrator" "$TOKEN" \
        "$INCIDENT_OBSERVED" "$INCIDENT_STAMP" "${2:-1785405900}" 0 \
        > "$STATE_DIR/over-limit-state.tsv"
    rm -f "$STATE_DIR/over-limit-observed.tsv"
    _over_limit_observation_set "_orchestrator" "$1"
}
write_row "$(( gate_now - 30 ))"
if FAKE_NOW="$gate_now" _over_limit_orchestrator_paused; then
    printf '  PASS: fresh observation (30s ago) keeps the gate closed\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: gate opened despite a fresh over-limit observation\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== gate: THE BLACKOUT — a stale observation must NOT suppress ==='
# Exactly the production row: observed at 21:48 the previous evening, parked at
# 2026-07-30 03:05, evaluated the next morning. Pre-#592 this suppressed.
write_row "$INCIDENT_STAMP"
if FAKE_NOW="$gate_now" _over_limit_orchestrator_paused; then
    printf '  FAIL: 12h-stale row still suppresses the operator channel (BLACKOUT)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: 12h-stale observation opens the gate\n'
    PASS=$(( PASS + 1 ))
fi

echo '=== gate: a pre-#592 state dir (no sidecar at all) must NOT suppress ==='
# Upgrade path. Absent evidence is not evidence of suspension; fail OPEN.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "_orchestrator" "orchestrator" "orchestrator" "$TOKEN" \
    "$INCIDENT_OBSERVED" "$INCIDENT_STAMP" "1785405900" 0 \
    > "$STATE_DIR/over-limit-state.tsv"
rm -f "$STATE_DIR/over-limit-observed.tsv"
if FAKE_NOW="$gate_now" _over_limit_orchestrator_paused; then
    printf '  FAIL: sidecar-less state dir suppresses (upgrade carries the blackout)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: legacy 8-field row opens the gate\n'
    PASS=$(( PASS + 1 ))
fi

echo '=== gate: staleness boundary is the configured window ==='
write_row "$(( gate_now - 599 ))"
FAKE_NOW="$gate_now" _over_limit_orchestrator_paused \
    && { printf '  PASS: 599s < 600s window still suppresses\n'; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: 599s wrongly opened the gate\n' >&2; FAIL=$(( FAIL + 1 )); }
write_row "$(( gate_now - 601 ))"
FAKE_NOW="$gate_now" _over_limit_orchestrator_paused \
    && { printf '  FAIL: 601s > 600s window still suppresses\n' >&2; FAIL=$(( FAIL + 1 )); } \
    || { printf '  PASS: 601s past the window opens the gate\n'; PASS=$(( PASS + 1 )); }
write_row "$(( gate_now - 1200 ))"
MONITOR_OVER_LIMIT_OBSERVATION_STALENESS_SECONDS=3600 FAKE_NOW="$gate_now" \
    _over_limit_orchestrator_paused \
    && { printf '  PASS: the window is configurable\n'; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: staleness knob ignored\n' >&2; FAIL=$(( FAIL + 1 )); }

echo '=== gate: a genuine multi-hour hold is NOT opened by backoff churn ==='
# Regression guard on the polarity: backing off must carry last_seen forward,
# never blank it (which would flap the gate open mid-retry on a real hold).
reset_rows
FAKE_NOW="$INCIDENT_STAMP" _over_limit_record \
    "_orchestrator" "orchestrator" "orchestrator" "$TOKEN"
_over_limit_apply_backoff "_orchestrator" "orchestrator" "orchestrator" "$TOKEN" \
    "$INCIDENT_CORRECT" "$INCIDENT_STAMP" 2 "$INCIDENT_STAMP"
assert_eq "backoff cannot touch the observation (it writes only the row file)" \
    "$(_over_limit_observation_get _orchestrator)" "$INCIDENT_STAMP"
if FAKE_NOW=$(( INCIDENT_STAMP + 60 )) _over_limit_orchestrator_paused; then
    printf '  PASS: real hold still suppresses right after a backoff\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: backoff flapped the gate open on a live hold\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== reconcile: an alive pane expedites its parked wake ==='
# The scan sees liveness every 60s. Pre-#592 it discarded that unless the pane
# read over-limit, so a row parked a day out sat there while the pane was
# demonstrably alive. Now it pulls the wake to now.
reset_rows
write_row "$INCIDENT_STAMP"
parked_before=$(row_field _orchestrator 7)
assert_eq "precondition: wake is parked a day out" "$parked_before" "1785405900"
FAKE_NOW="$gate_now" _over_limit_reconcile_alive "_orchestrator" "empty"
assert_eq "reconcile pulled the wake to now" \
    "$(row_field _orchestrator 7)" "$gate_now"
assert_eq "reconcile left first_seen alone" \
    "$(row_field _orchestrator 6)" "$INCIDENT_STAMP"
assert_eq "reconcile did NOT forge an observation" \
    "$(_over_limit_observation_get _orchestrator)" "$INCIDENT_STAMP"

echo '=== reconcile: an already-due row is left for the wake loop ==='
reset_rows
write_row "$INCIDENT_STAMP" "$(( gate_now - 5 ))"
FAKE_NOW="$gate_now" _over_limit_reconcile_alive "_orchestrator" "idle"
assert_eq "already-due row untouched (no file churn)" \
    "$(row_field _orchestrator 7)" "$(( gate_now - 5 ))"

echo '=== reconcile: no row → no-op ==='
reset_rows
FAKE_NOW="$gate_now" _over_limit_reconcile_alive "worker-nonexistent" "idle"
assert_no_file "reconcile on a missing row creates nothing" \
    "$STATE_DIR/over-limit-state.tsv"

echo '=== suppression is VISIBLE: a long hold escalates out-of-band ==='
# The blackout was recorded only in watcher.log — a file no human reads — which
# is why 15 hours passed unnoticed. A condition that mutes the operator's
# channel must announce itself on the channel-independent surface.
reset_rows
ALERTS="$WORK/alerts.log"; : > "$ALERTS"
_OVER_LIMIT_ALERT_FN=capture_alert
capture_alert() { printf '%s\n' "$1" >> "$ALERTS"; }
rm -f "$STATE_DIR/over-limit-alert.stamp"
hold_start=$(at "$LA" "2026-07-28 21:48:38")
write_row_key() {   # <observed-epoch>
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "_orchestrator" "orchestrator" "orchestrator" "$TOKEN" \
        "$INCIDENT_CORRECT" "$hold_start" "1785405900" 0 \
        > "$STATE_DIR/over-limit-state.tsv"
    _over_limit_observation_set "_orchestrator" "$1"
}
write_row_key "$hold_start"
# Two minutes in: under the 900s announcement delay, stay quiet.
FAKE_NOW=$(( hold_start + 120 )) _over_limit_record_held "a1.md" "full-state"
assert_eq "short hold does not alert" "$(wc -l < "$ALERTS" | tr -d ' ')" "0"
# Twenty minutes in: announce, once.
FAKE_NOW=$(( hold_start + 1200 )) _over_limit_record_held "a2.md" "full-state"
assert_eq "hold past the delay announces once" \
    "$(wc -l < "$ALERTS" | tr -d ' ')" "1"
assert_contains "announcement is marked as the start of a hold" \
    "$(cat "$ALERTS")" "hold began"
assert_contains "…names the muted channel"   "$(cat "$ALERTS")" "emit channel"
assert_contains "…reports the duration"      "$(cat "$ALERTS")" "20 min"
assert_contains "…points at the held-emit log" "$(cat "$ALERTS")" "over-limit-held.log"

# THE TEXT MUST NOT ASSERT A FALSE CAUSE. Since #592 the gate only suppresses
# on a FRESH observation, so at alert time the stamp cannot be stale — telling
# the operator to go hunting for one trains the wrong reflex for the first
# occurrence that is real.
assert_contains "text states what obtains: a live hold" \
    "$(cat "$ALERTS")" "live hold, not a stale stamp"
assert_contains "…backed by when it was last observed" \
    "$(cat "$ALERTS")" "last observed"
assert_not_contains "text does NOT send them hunting for a stale stamp" \
    "$(cat "$ALERTS")" "the stamp is stale"

# The ~50s emit cadence must not become a notification storm.
for _i in 1 2 3 4 5; do
    FAKE_NOW=$(( hold_start + 1200 + _i * 50 )) \
        _over_limit_record_held "b$_i.md" "full-state"
done
assert_eq "rate-limited: five more held emits add no alerts" \
    "$(wc -l < "$ALERTS" | tr -d ' ')" "1"
# Still inside the 3600s reminder cadence.
FAKE_NOW=$(( hold_start + 1200 + 950 )) _over_limit_record_held "c.md" "full-state"
assert_eq "no reminder inside the reminder interval" \
    "$(wc -l < "$ALERTS" | tr -d ' ')" "1"
# …but it does keep reminding while the condition persists.
FAKE_NOW=$(( hold_start + 1200 + 3700 )) _over_limit_record_held "d.md" "full-state"
assert_eq "reminder fires after the reminder interval" \
    "$(wc -l < "$ALERTS" | tr -d ' ')" "2"
assert_contains "reminder is marked as a continuation, not a new hold" \
    "$(tail -1 "$ALERTS")" "hold continues"

echo '=== alert VOLUME: a legitimate 5-hour hold must not spam ==='
# The skeptic measured 20 critical-class bells for a 5h hold when the
# announcement and reminder shared one 15-min interval. That is how an operator
# learns to ignore the announcement — which destroys the very property #592
# adds. Expected now: 1 announcement + 4 hourly reminders.
: > "$ALERTS"
rm -f "$STATE_DIR/over-limit-alert.stamp"
write_row_key "$hold_start"
_t=0
while (( _t <= 5 * 3600 )); do
    FAKE_NOW=$(( hold_start + _t )) _over_limit_record_held "v.md" "full-state"
    _t=$(( _t + 50 ))
done
_bells=$(wc -l < "$ALERTS" | tr -d ' ')
if (( _bells >= 1 && _bells <= 6 )); then
    printf '  PASS: 5h hold fires %s alerts (was 20; 1 announcement + hourly reminders)\n' "$_bells"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: 5h hold fired %s alerts — expected 1..6\n' "$_bells" >&2
    FAIL=$(( FAIL + 1 ))
fi
assert_eq "exactly one of them is the announcement" \
    "$(grep -c 'hold began' "$ALERTS")" "1"

echo '=== ROLLBACK SAFETY: the row file stays parseable by OLDER code ==='
# The state file survives restarts and version skew (_version_restart.sh exists
# because the watcher can be mid-transition). A 9th column broke this: an older
# watcher reads with `IFS=$'\t' read -r ... attempts`, the trailing variable
# absorbs the remainder, and the wake loop's $(( attempts + 1 )) dies with
# "bad math expression" — turning a routine rollback into an outage of the wake
# path itself. Hence the observation lives in a sidecar old code never opens.
reset_rows
rm -f "$STATE_DIR/over-limit-observed.tsv"
FAKE_NOW="$INCIDENT_STAMP" _over_limit_record \
    "_orchestrator" "orchestrator" "orchestrator" "$TOKEN"
_row=$(_over_limit_load "_orchestrator")
assert_eq "row has exactly 8 tab-separated fields" \
    "$(awk -F'\t' '{print NF}' <<<"$_row")" "8"
# Replay the OLD reader verbatim, then the arithmetic that used to explode.
IFS=$'	' read -r _k _w _r _tok _re _fs _na _at <<<"$_row"
if [[ "$_at" =~ ^[0-9]+$ ]]; then
    printf '  PASS: old 8-var read yields a numeric attempts field\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: old reader got attempts=%q — rollback would break\n' "$_at" >&2
    FAIL=$(( FAIL + 1 ))
fi
if ( _n=$(( _at + 1 )) ) 2>/dev/null; then
    printf '  PASS: old wake-loop arithmetic still evaluates\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: old wake-loop arithmetic errors on this row\n' >&2
    FAIL=$(( FAIL + 1 ))
fi
assert_file_exists "the observation went to the sidecar instead" \
    "$STATE_DIR/over-limit-observed.tsv"
assert_eq "sidecar carries the observation" \
    "$(_over_limit_observation_get _orchestrator)" "$INCIDENT_STAMP"

echo '=== sidecar is dropped alongside its row ==='
_over_limit_drop "_orchestrator"
assert_empty "observation removed with the row" \
    "$(_over_limit_observation_get _orchestrator)"

_OVER_LIMIT_ALERT_FN=_over_limit_alert_noop

# ---- NEGATIVE CONTROL -----------------------------------------------------
#
# The pre-fix implementations, transcribed verbatim from 5a16070 (the
# revision running in production during the incident). They exist so the
# assertions above are demonstrably load-bearing: run the SAME boundary table
# and the SAME ratchet replay against them and they must fail, reproducing
# the exact epoch the production state file recorded.

_legacy_reset_at_to_epoch() {
    local token="$1" now="${2:-$(date +%s)}"
    local fallback=$(( now + 21600 ))
    [[ -n "$token" && "$token" != "unknown" ]] || { printf '%d' "$fallback"; return 0; }
    local time_part tz_part epoch=""
    if [[ "$token" == *_* ]]; then
        time_part="${token%%_*}"
        tz_part="${token#*_}"
    else
        time_part="$token"
        tz_part=""
    fi
    if [[ -n "$tz_part" ]]; then
        epoch=$(TZ="$tz_part" date -d "$time_part today" +%s 2>/dev/null)
    else
        epoch=$(date -d "$time_part today" +%s 2>/dev/null)
    fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || { printf '%d' "$fallback"; return 0; }
    if (( epoch <= now )); then
        epoch=$(( epoch + 86400 ))
    fi
    printf '%d' "$epoch"
}

echo '=== NEGATIVE CONTROL: the pre-fix parser ==='

# The evening-local cases the day-late hypothesis predicted would break do
# NOT break: `TZ=<zone> date -d "3am today"` resolves "today" in <zone>, so
# the 21:48 PDT stamp already answered 2026-07-29 03:00. Assert that
# explicitly — it is the reason the fix is the refresh, not the parse.
legacy_at_stamp=$(FAKE_NOW="$INCIDENT_STAMP" \
    _legacy_reset_at_to_epoch "$TOKEN" "$INCIDENT_STAMP")
assert_eq "pre-fix parser was already CORRECT at the evening stamp" \
    "$legacy_at_stamp" "$INCIDENT_CORRECT"

# Where it does break: one second either side of the stated time. This is the
# memorylessness the refresh loop turned into a day-long stall.
legacy_before=$(FAKE_NOW=$(( INCIDENT_CORRECT - 1 )) \
    _legacy_reset_at_to_epoch "$TOKEN" "$(( INCIDENT_CORRECT - 1 ))")
legacy_after=$(FAKE_NOW="$INCIDENT_CORRECT" \
    _legacy_reset_at_to_epoch "$TOKEN" "$INCIDENT_CORRECT")
assert_eq "pre-fix: one second BEFORE the reset → today's 3am" \
    "$legacy_before" "$INCIDENT_CORRECT"
assert_eq "pre-fix: AT the reset → jumps to the production day-late epoch" \
    "$legacy_after" "$INCIDENT_OBSERVED"

# The boundary table against the pre-fix parser. It fails EXACTLY ONE case —
# the DST one. That number is asserted rather than merely being >0, because
# it is the finding: the five reset-boundary cases PASS on unfixed code, so
# the parse was never the day-late defect. Had the investigation stopped at
# the "evening stamp resolves against the UTC date" hypothesis, the fix would
# have been aimed at a function that was already correct and the orchestrator
# would still be stalling every night. The load-bearing negative control for
# the actual defect is the refresh replay below.
legacy_out=$(run_case_table _legacy_reset_at_to_epoch)
legacy_fails=$?
assert_eq "pre-fix parser fails exactly the two DST cases, nothing else" \
    "$legacy_fails" "2"
assert_contains "…spring-forward is one (lands an hour late)" \
    "$legacy_out" "2026-03-07 21:00:00"
assert_contains "…fall-back is the other (lands an hour early)" \
    "$legacy_out" "2026-10-31 03:00:01"
# The five reset-boundary cases are absent from that list — the point.
assert_not_contains "pre-fix parser does NOT fail the 21:48 evening stamp" \
    "$legacy_out" "2026-07-28 21:48:38"
assert_eq "pre-fix: DST +86400 lands an hour late (4am PDT)" \
    "$(show "$LA" "$(FAKE_NOW="$dst_pin" _legacy_reset_at_to_epoch "$TOKEN" "$dst_pin")")" \
    "2026-03-08 04:00:00 PDT"

# The ratchet replay against a legacy record path: recompute unconditionally
# on every refresh, exactly as _over_limit_record did.
_legacy_refresh_horizon() {   # <reset_epoch> <now> → new reset_epoch
    FAKE_NOW="$2" _legacy_reset_at_to_epoch "$TOKEN" "$2"
}
echo '=== NEGATIVE CONTROL: the pre-fix refresh reproduces the incident ==='
legacy_reset=$(FAKE_NOW="$INCIDENT_STAMP" \
    _legacy_reset_at_to_epoch "$TOKEN" "$INCIDENT_STAMP")
for offset in -600 -120 -1 0 30 300 3600; do
    legacy_reset=$(_legacy_refresh_horizon "$legacy_reset" \
        "$(( INCIDENT_CORRECT + offset ))")
done
assert_eq "pre-fix refresh lands on the exact epoch the state file recorded" \
    "$legacy_reset" "$INCIDENT_OBSERVED"
legacy_next=$(( legacy_reset + 300 ))
assert_eq "…and parks next_attempt at the value observed in production" \
    "$legacy_next" "1785405900"

th_summary_and_exit
