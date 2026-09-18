#!/usr/bin/env bash
# test-idle-wrapup-scan-scope.sh — the wrap-up scan must not pay a `date -d`
# fork for entries belonging to OTHER windows (your-org/nexus-code#1063).
#
# WHAT IS BEING GUARDED. `_idle_window_wrap_up_entry` walks every `wrap-up`
# event in the action log, newest-first, looking for this window's latest one.
# Two predicates decide each entry: does it BELONG to this window (pure bash),
# and is it within the current spawn's LIFECYCLE (a `date -d` fork, via
# `_idle_iso_to_epoch`). They are independent, so their order cannot change the
# answer — but it changes the cost by the whole size of the log, because the
# scope check used to run FIRST and therefore ran for entries that were about
# to be discarded for belonging to somebody else.
#
# The cost term is the action log's LIFETIME wrap-up count, which only ever
# grows. Measured on the live log 2026-08-26 (2,599 `"event":"wrap-up"`
# entries, 5 worker windows): 7,805 of 7,815 `date -d` forks per
# `list_really_idle_workers` came from this one loop — ~11 s per window, 33 s
# for the sweep, 44 s for `render_idle_prelude` against compose_report's 20 s
# bound. Every emit for hours carried `workspace: UNAVAILABLE`, and the
# workspace prelude is the only per-emit surface on which `idle-too-long`,
# `pane-absent` and `over-limit` are visible at all.
#
# WHY A FORK COUNT AND NOT A STOPWATCH. A wall-clock threshold on a shared node
# is a flake generator. The fork count is the mechanism itself and is exact.
#
# THE FIXTURE MUST BE PROVEN LIVE FIRST. A fork count of zero is produced just
# as readily by a fixture the production `grep '"event":"wrap-up"'` cannot see —
# and that is not hypothetical: the first draft of this fixture was written with
# `json.dumps` defaults, which emit `{"event": "wrap-up"` WITH A SPACE, matched
# nothing, and made every arm pass vacuously. So F0 below asserts the planted
# log is visible to the production predicate and that a positive-control lookup
# really finds something, BEFORE any bound is trusted.
#
# Run: bash monitor/watcher/test-idle-wrapup-scan-scope.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

STATE_DIR=$(mktemp -d); export STATE_DIR
trap 'rm -rf "$STATE_DIR"' EXIT

# shellcheck source=_idle_probe.sh
source "$_test_dir/_idle_probe.sh" 2>/dev/null

NOISE=200            # foreign wrap-ups planted on EACH side of the anchor
LOG="$STATE_DIR/action-log.jsonl"
LOG_B="$STATE_DIR/action-log-B.jsonl"
LOG_C="$STATE_DIR/action-log-C.jsonl"
LOG_D="$STATE_DIR/action-log-D.jsonl"

# Compact JSON, written by hand so the production grep pattern is literally
# what appears on disk. See the header on why this is not a style choice.
_plant() {
    local out="$1" i
    : > "$out"
    for (( i=0; i<NOISE; i++ )); do
        printf '{"event":"wrap-up","ts":"2026-08-20T10:%02d:00-07:00","window":"other%d","report":"other%d_2026-08-20_100000_x.md"}\n' \
            "$(( i % 60 ))" "$i" "$i" >> "$out"
    done
    # pre-#109 entry (no `window` field) whose BASENAME matches target, BEFORE
    # the spawn anchor — must stay out of scope once an anchor exists.
    printf '{"event":"wrap-up","ts":"2026-08-19T09:00:00-07:00","report":"target_2026-08-19_090000_legacy.md"}\n' >> "$out"
    printf '{"event":"spawn","ts":"2026-08-20T12:00:00-07:00","window":"target"}\n' >> "$out"
    # target's own wrap-up, recorded BEFORE the spawn: a previous life.
    printf '{"event":"wrap-up","ts":"2026-08-20T11:00:00-07:00","window":"target","report":"target_2026-08-20_110000_stale.md"}\n' >> "$out"
    for (( i=NOISE; i<NOISE*2; i++ )); do
        printf '{"event":"wrap-up","ts":"2026-08-21T10:%02d:00-07:00","window":"other%d","report":"other%d_2026-08-21_100000_x.md"}\n' \
            "$(( i % 60 ))" "$i" "$i" >> "$out"
    done
}
_plant "$LOG"
cp "$LOG" "$LOG_B"
printf '{"event":"wrap-up","ts":"2026-08-22T08:00:00-07:00","window":"target","report":"target_2026-08-22_080000_good.md"}\n' >> "$LOG_B"
grep -v '"event":"spawn"' "$LOG" > "$LOG_C"          # legacy window: no anchor
cp "$LOG" "$LOG_D"
printf '{"event":"wrap-up","ts":"2026-08-23T08:00:00-07:00","report":"target_2026-08-23_080000_legacy2.md"}\n' >> "$LOG_D"

echo "=== F0. the fixture is VISIBLE to the production predicate ==="
# Without this, every arm below is satisfied by a log nothing can read.
_visible=$(grep -c '"event":"wrap-up"' "$LOG")
assert_eq "the planted log is matched by the production grep, in full" \
    "$_visible" "$(( NOISE * 2 + 2 ))"
_probe=$(_idle_window_wrap_up_entry other7 "$LOG"); _prc=$?
assert_eq "…and a positive-control lookup RESOLVES (rc 0)" "$_prc" "0"
assert_contains "…returning that window's own report" "$_probe" "other7_2026-08-20_100000_x.md"

echo "=== F1. lookups return the same answers the scan always did ==="
out=$(_idle_window_wrap_up_entry target "$LOG"); rc=$?
assert_eq "a wrap-up from a PREVIOUS life is out of scope (rc 1)" "$rc" "1"
assert_empty "…and nothing is printed" "$out"

out=$(_idle_window_wrap_up_entry target "$LOG_B"); rc=$?
assert_eq "an in-scope post-#109 wrap-up resolves" "$rc" "0"
assert_contains "…and it is the newest one" "$out" "target_2026-08-22_080000_good.md"

out=$(_idle_window_wrap_up_entry target "$LOG_C"); rc=$?
assert_eq "with NO spawn anchor the scope check is bypassed (legacy)" "$rc" "0"
assert_contains "…so the pre-anchor entry is served, as before" "$out" "target_2026-08-20_110000_stale.md"

out=$(_idle_window_wrap_up_entry target "$LOG_D"); rc=$?
assert_eq "a pre-#109 basename match INSIDE the lifecycle still resolves" "$rc" "0"
assert_contains "…via the basename heuristic, not the window field" "$out" "target_2026-08-23_080000_legacy2.md"

out=$(_idle_window_wrap_up_entry nosuchwindow "$LOG"); rc=$?
assert_eq "an unknown window finds nothing (rc 1)" "$rc" "1"

echo "=== F2. THE GUARD: foreign entries cost no date fork ==="
# `target` is the potent case: it HAS a spawn anchor, so the scope check is
# armed, and it has NO in-scope match, so the walk runs to exhaustion. Every
# one of the 400 foreign entries is an opportunity to fork.
_shim=$(mktemp -d)
_calls="$_shim/calls"
printf '#!/usr/bin/env bash\nprintf x >> %q\nexec /bin/date "$@"\n' "$_calls" > "$_shim/date"
chmod +x "$_shim/date"

_count_forks() {   # <window> <log> -> forks
    : > "$_calls"
    PATH="$_shim:$PATH" _idle_window_wrap_up_entry "$1" "$2" >/dev/null 2>&1
    local n; n=$(wc -c < "$_calls"); printf '%s' "${n:-0}"
}

# Sanity: the shim is on PATH and is what `date` resolves to. A shim that is
# never reached reports 0 forks and would pass the bound for the wrong reason.
: > "$_calls"
PATH="$_shim:$PATH" _idle_iso_to_epoch "2026-08-20T12:00:00-07:00" >/dev/null 2>&1
assert_eq "the counting shim intercepts _idle_iso_to_epoch" "$(wc -c < "$_calls")" "1"

forks=$(_count_forks target "$LOG")
printf '  (walk over %d foreign wrap-ups cost %s date fork(s))\n' "$(( NOISE * 2 ))" "$forks"
# The scan legitimately forks a small constant: the spawn anchor, plus at most
# the entries that actually belong to this window. It must NOT scale with the
# foreign population. Before the fix this was 403 for NOISE=200.
if (( forks <= 10 )); then
    printf '  PASS: the walk is O(this window), not O(the whole log)\n'; _th_pass
else
    printf '  FAIL: %s date forks over %d foreign entries — the scope check is running BEFORE the candidacy check again (your-org/nexus-code#1063)\n' \
        "$forks" "$(( NOISE * 2 ))" >&2; _th_fail
fi

echo "=== F3. MUST-STILL-FIRE: the scope check is still armed, not deleted ==="
# The cheap way to pass F2 is to stop checking scope at all. That would make
# F1's first arm resolve a stale wrap-up, so the two arms pin each other — but
# assert the fork directly too, so the intent is legible.
forks=$(_count_forks target "$LOG_B")
if (( forks >= 2 )); then
    printf '  PASS: an in-scope candidate IS still date-converted (%s forks)\n' "$forks"; _th_pass
else
    printf '  FAIL: only %s date fork(s) — the lifecycle-scope check appears to be gone\n' "$forks" >&2; _th_fail
fi
rm -rf "$_shim"

echo "=== F4. THE SECOND GUARD: foreign entries are not DELIVERED to bash at all ==="
# `#1063` removed the per-entry FORK and left the per-entry WALK
# (your-org/nexus-code#1329). Candidacy-first made each foreign entry cheap; it
# did not stop the entry reaching bash's `read`, which consumes a pipe a byte at
# a time. So the residual cost term was still O(this window x ALL historical
# wrap-ups) — the same growth axis F2 closed, in a different resource.
#
# Measured at 0b82ffb2 against the live action log (7,746,636 bytes, 3,309
# `"event":"wrap-up"` entries): `_idle_window_wrap_up_entry` 2490-2930 ms,
# `_idle_window_retain_event` 1510-1714 ms, `_idle_window_spawn_ts` 60-83 ms.
# Same file, same grep, same tac, same jq, comparable row counts — the only
# difference is WHERE the window predicate runs. `_idle_window_spawn_ts` was
# already filtering in jq, which is why it is the cheap one; it is the positive
# control this fix copies.
#
# WHY ROWS AND NOT A STOPWATCH — F2's reason, unchanged. The row count is the
# mechanism and is exact; a wall-clock threshold on a shared node is a flake
# generator.
_jshim=$(mktemp -d)
_rows="$_jshim/rows"
# The walks consume jq through `done < <(… | jq …)` and `return` on the first
# hit, and bash does NOT wait for a process substitution's producer — so the
# shim's `tee` can still be writing when the counter reads the file. That is a
# race the counter used to lose only under contention (CI bash 4.4 band,
# 2026-09-07: PSI runqueue stall 78 %, 0 rows for a window that HAS an event —
# the honest FAIL, not a defect; your-org/nexus-code#1481). So every shim run
# records a START before jq and a DONE after its pipeline, `_count_rows` waits
# until starts == dones (a walk may run jq more than once — the spawn-anchor
# lookup and the walk itself — so ONE marker would fire early), and `tee -p`
# keeps appending after the reader has gone (EPIPE on stdout must not lose the
# row from the file). A row the reader received came from tee, which runs after
# the START marker, so by the time a walk returns every producer that fed it
# has registered a start.
printf '#!/usr/bin/env bash\necho >> %q; /usr/bin/jq "$@" | tee -p -a %q; echo >> %q\n' "$_rows.started" "$_rows" "$_rows.done" > "$_jshim/jq"
chmod +x "$_jshim/jq"
# Wait for every started shim to finish. The bound is a SAFETY NET whose expiry
# is reported (rc 1, "-1"), never a pass: a producer that has not finished in
# 20 s is a finding, not a zero.
_await_shim_done() {
    local i a b
    for (( i=0; i<1000; i++ )); do
        a=$(wc -l < "$_rows.started" 2>/dev/null || echo 0); b=$(wc -l < "$_rows.done" 2>/dev/null || echo 0)
        (( a >= 1 && a == b )) && return 0
        sleep 0.02
    done
    printf '  WARN: %s jq shim run(s) started, %s finished within 20 s — the row count below is NOT a measurement\n' "$a" "$b" >&2
    # `_count_rows` runs inside `$(…)`, so a FAIL counted HERE would be lost with
    # the subshell; record the expiry durably and let the terminal assertion
    # below turn it red. A "-1" alone would PASS every `rows <= N` bound.
    printf '%s/%s\n' "$a" "$b" >> "$_rows.expired"
    return 1
}

_count_rows() {   # <fn> <window> <log> -> rows handed to the bash read loop; -1 if a producer never finished
    : > "$_rows"; : > "$_rows.started"; : > "$_rows.done"
    PATH="$_jshim:$PATH" "$1" "$2" "$3" >/dev/null 2>&1
    _await_shim_done || { printf '%s' "-1"; return 1; }
    local n; n=$(wc -l < "$_rows"); printf '%s' "${n:-0}"
}

# Sanity FIRST: a shim that is never reached reports 0 rows and would pass the
# bound for the wrong reason — the same trap F0 exists for, one layer down.
_shim_rows=$(_count_rows _idle_window_wrap_up_entry other7 "$LOG")
if (( _shim_rows >= 1 )); then
    printf '  PASS: the counting jq shim is on PATH and is reached (%s row(s))\n' "$_shim_rows"; _th_pass
else
    printf '  FAIL: the jq shim produced 0 rows — it was never reached, so every bound below is vacuous\n' >&2; _th_fail
fi

rows=$(_count_rows _idle_window_wrap_up_entry target "$LOG")
printf '  (walk over %d foreign wrap-ups delivered %s row(s) to bash)\n' "$(( NOISE * 2 ))" "$rows"
# Legitimate rows: the spawn-anchor lookup (already jq-filtered) plus this
# window's own entries plus the pre-#109 no-window entries the basename
# heuristic still has to see. It must NOT scale with the foreign population.
# Before the fix this was 403 for NOISE=200.
if (( rows <= 20 )); then
    printf '  PASS: the wrap-up walk delivers O(this window) rows, not O(the whole log)\n'; _th_pass
else
    printf '  FAIL: %s rows over %d foreign entries — the window predicate is running in BASH again, not in the jq producer (your-org/nexus-code#1329)\n' \
        "$rows" "$(( NOISE * 2 ))" >&2; _th_fail
fi

echo "=== F4b. the PRE-#109 arm is prefiltered too — legacy rows of OTHER windows never reach bash (#1406) ==="
# The producer used to pass EVERY no-window row through (`$ew == "_NULL_"` was
# a blanket accept) and run the basename test in bash, per row, per window.
# Profiled against the live log: that was the whole log-size term of
# render_idle_prelude. The four basename disjuncts now run in jq; the bash arm
# re-tests for free. Plant NOISE legacy rows for other windows plus ONE that
# matches by basename, and require the walk to deliver O(1) rows AND still
# resolve the legacy match — a prefilter that dropped the match would be the
# fail-open direction, and the row bound alone cannot see it.
LOG_L="$STATE_DIR/action-log-L.jsonl"
: > "$LOG_L"
for (( i=0; i<NOISE*2; i++ )); do
    printf '{"event":"wrap-up","ts":"2026-08-20T10:%02d:00-07:00","report":"other%d_2026-08-20_100000_legacy.md"}\n' \
        "$(( i % 60 ))" "$i" >> "$LOG_L"
done
printf '{"event":"wrap-up","ts":"2026-08-22T09:00:00-07:00","report":"target_2026-08-22_090000_legacy3.md"}\n' >> "$LOG_L"
out=$(_idle_window_wrap_up_entry target "$LOG_L"); rc=$?
assert_eq "the legacy basename match STILL resolves through the jq prefilter (rc 0)" "$rc" "0"
assert_contains "…and it is the matching row" "$out" "target_2026-08-22_090000_legacy3.md"
rows=$(_count_rows _idle_window_wrap_up_entry target "$LOG_L")
printf '  (walk over %d foreign LEGACY wrap-ups delivered %s row(s) to bash)\n' "$(( NOISE * 2 ))" "$rows"
if (( rows <= 3 )); then
    printf '  PASS: legacy rows of other windows are dropped in jq, not in a bash continue\n'; _th_pass
else
    printf '  FAIL: %s rows over %d foreign legacy entries — the basename heuristic is back in bash (your-org/nexus-code#1406)\n' \
        "$rows" "$(( NOISE * 2 ))" >&2; _th_fail
fi

echo "=== F5. the SAME defect in the window-retain walk, same guard ==="
# `_idle_window_retain_event` had the identical shape and the identical cost.
# PREMISE CORRECTED (skeptic item 6b): `window-retain` does NOT always carry a
# `window` extra — measured, 31 of 3,346 live entries are `"window":null`. Both
# walks therefore have an absent-field arm; the difference is what it DOES. The
# wrap-up arm PRESERVES a null-window row (it can still be this window's); the
# retain arm DISCARDS it via `(.window // "")`, matching the bash test it
# replaced, whose `sed` also leaves the field empty on a null.
LOG_R="$STATE_DIR/action-log-R.jsonl"
: > "$LOG_R"
for (( i=0; i<NOISE*2; i++ )); do
    printf '{"event":"window-retain","ts":"2026-08-20T10:%02d:00-07:00","window":"other%d","reason":"noise"}\n' \
        "$(( i % 60 ))" "$i" >> "$LOG_R"
done
printf '{"event":"window-retain","ts":"2026-08-22T09:00:00-07:00","window":"target","reason":"held-for-review"}\n' >> "$LOG_R"
out=$(_idle_window_retain_event target "$LOG_R"); rc=$?
assert_eq "a retain event for this window resolves (rc 0)" "$rc" "0"
assert_contains "…carrying its reason" "$out" "held-for-review"
out=$(_idle_window_retain_event nosuchwindow "$LOG_R"); rc=$?
assert_eq "an unknown window finds no retain event (rc 1)" "$rc" "1"

# Reachability FIRST, in THIS path: a bound of 0 rows is produced just as
# readily by a shim the retain walk never reaches. The positive-control lookup
# above proves the filter works; this proves the counter sees it.
_r_hit=$(_count_rows _idle_window_retain_event target "$LOG_R")
if (( _r_hit >= 1 )); then
    printf '  PASS: the jq shim is reached by the RETAIN walk too (%s row(s))\n' "$_r_hit"; _th_pass
else
    printf '  FAIL: the retain walk delivered 0 rows for a window that HAS a retain event — the shim was not reached, so the bound below is vacuous\n' >&2; _th_fail
fi

rows=$(_count_rows _idle_window_retain_event nosuchwindow "$LOG_R")
printf '  (retain walk over %d foreign events delivered %s row(s) to bash)\n' "$(( NOISE * 2 ))" "$rows"
if (( rows <= 20 )); then
    printf '  PASS: the retain walk delivers O(this window) rows\n'; _th_pass
else
    printf '  FAIL: %s rows over %d foreign retain events — the window predicate is running in BASH again (your-org/nexus-code#1329)\n' \
        "$rows" "$(( NOISE * 2 ))" >&2; _th_fail
fi
rm -rf "$_jshim"

# ---- assertion-count guard -------------------------------------------------
# An assertion that never runs is invisible to the summary: a typo'd helper is
# `command not found` at rc 127, tallied by nothing, and the footer still says
# ALL TESTS PASSED with a quieter number. No conditional cases here, so the
# count is exact. Bump deliberately when adding a case; a DROP means a case
# stopped running.
# Every `_count_rows` above must have seen its producers FINISH; an expiry is a
# red here, not a "-1" that slid under a bound.
if [[ -s "$_rows.expired" ]]; then
    printf '  FAIL: %s _count_rows call(s) expired waiting for the jq shim (started/finished: %s) — those counts were not measurements\n' \
        "$(wc -l < "$_rows.expired")" "$(tr '\n' ' ' < "$_rows.expired")" >&2; _th_fail
else
    printf '  PASS: every _count_rows call saw its jq producers finish (no expiry recorded)\n'; _th_pass
fi

_EXPECTED_ASSERTIONS=26
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' \
        "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
