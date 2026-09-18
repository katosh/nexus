#!/usr/bin/env bash
# monitor/watcher/test-orphan-async.sh — tests for the watcher-owned
# `idle-orphan-async` wake loop (your-org/nexus-code#1071).
#
# THE ASSERTIONS THAT MATTER MOST ARE THE NEGATIVE ONES. A self-healing loop
# that wakes a worker whose job is still running, or that pastes into a pane
# with input already queued, is strictly WORSE than the stall it replaces —
# the first reaps live work, the second is `#1065`'s duplicate-delivery
# hazard. So every gate is asserted in BOTH arms: it fires when it should, and
# — separately, with the same fixture and one variable changed — it does not
# fire when it should not.
#
# Coverage:
#   - resolver: `syn-` id → unresolvable (checked BEFORE the per-kind arms)
#   - resolver: Slurm running / terminal-good / terminal-bad / aged-out /
#               unrecognised state
#   - resolver: asyncrun running / terminal / died  (through the REAL
#               monitor/async-run.sh, not a stub — the three-way verdict is
#               the point of the whole change)
#   - resolver: unknown kind → unresolvable, NOT terminal and NOT running
#   - NEGATIVE CONTROL: one running wait among many suppresses the wake
#   - NEGATIVE CONTROL: queued=1 suppresses the wake and KEEPS the row
#   - NEGATIVE CONTROL: state no longer idle-orphan-async → drop, no paste
#   - probe returned nothing ("could not look") → hold, no paste
#   - grace: a fresh stall is not woken before the grace elapses
#   - cooldown: a woken window is not re-woken inside the cooldown
#   - ceiling: an ancient row is dropped, never fail-open pasted
#   - the wake path pastes, marks woken, and drops the row
#   - brief: resume-first ordering; names `declare-no-wait` only as the
#     exception; truncation warning present iff a wait is unresolvable/died
#   - scan: records, preserves first_seen, refreshes waits, drops on recovery
#
# Run: bash monitor/watcher/test-orphan-async.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_test_dir/_orphan_async.sh"
[[ -f "$HELPER" ]] || { echo "helper not found: $HELPER" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
export STATE_DIR
export NEXUS_ROOT="$_repo_root"
# PIN the state dir under the name the CHILDREN read (your-org/nexus-code#1349).
# `NEXUS_ROOT` above is needed so the helper finds `ng` / `declare-wait.sh` /
# `async-run.sh`, but it is also arm 2 of every child's state resolver, so
# with `NEXUS_STATE_DIR` unset the fixture's `declare-wait.sh` calls wrote
# `heartbeat/w1.json` into the CHECKOUT's own `monitor/.state` — on the
# primary, the operator's live state (measured: the directory did not exist
# before a run and held nothing but that file after). Removing a variable
# never scopes anything; it only chooses a later arm. The only safe
# direction is to SET arm 1. The asyncrun block below re-pins it to its own
# dir and then restores THIS pin — never `unset`.
export NEXUS_STATE_DIR="$STATE_DIR"
# STRAY-WRITE TRIPWIRE: the checkout's own state must be untouched by this run.
# Recorded now, asserted at the end. `absent` is a value like any other, so a
# file that appears during the run is a red, and one that pre-existed (a real
# window named w1, on an operator's primary) is a red only if its mtime moved.
_stray_hb="$_repo_root/monitor/.state/heartbeat/w1.json"
_stray_before=$(stat -c %Y "$_stray_hb" 2>/dev/null || echo absent)

# Fast knobs so the suite never sleeps.
export MONITOR_ORPHAN_ASYNC_GRACE_SECONDS=300
export MONITOR_ORPHAN_ASYNC_RETRY_SECONDS=120
export MONITOR_ORPHAN_ASYNC_COOLDOWN_SECONDS=1800
export MONITOR_ORPHAN_ASYNC_MAX_HOLD_SECONDS=86400

# shellcheck source=monitor/_bookkeeping.sh
. "$_repo_root/monitor/_bookkeeping.sh" 2>/dev/null || true
# shellcheck source=monitor/watcher/_orphan_async.sh
. "$HELPER"

# The wake loop reads the wall clock itself (unlike _over_limit_evaluate_row,
# which takes `now` as an argument), so the fixture clock MUST be real: a
# pinned constant in the past silently trips the absolute ceiling and every
# later case then asserts against a dropped row. Cost one debugging round.
NOW=$(date +%s)

# ---- recording seams ------------------------------------------------------

LOGF="$WORK/log"; : > "$LOGF"
PASTES="$WORK/pastes"; : > "$PASTES"
_orphan_async_log_rec()   { printf '%s\n' "$1" >> "$LOGF"; }
_orphan_async_paste_rec() { printf '%s\n' "$1" >> "$PASTES"; cp "$2" "$WORK/last-body"; return 0; }
_orphan_async_paste_fail(){ printf '%s\n' "$1" >> "$PASTES"; return 1; }
_ORPHAN_ASYNC_LOG_FN=_orphan_async_log_rec
_ORPHAN_ASYNC_PASTE_FN=_orphan_async_paste_rec

# Stub probe: MOCK_PANE is `<window>|<pane-state line>` rows.
_orphan_async_probe_stub() {
    local key="$1"
    printf '%s\n' "${MOCK_PANE:-}" | awk -F'|' -v k="$key" '$1 == k {print $2; exit}'
}
_ORPHAN_ASYNC_PROBE_FN=_orphan_async_probe_stub

# Stub resolver: MOCK_RESOLVE is `<kind>:<id>|<class>|<detail>` rows.
_orphan_async_resolve_stub() {
    local w="$1:$2" out
    out=$(printf '%s\n' "${MOCK_RESOLVE:-}" | awk -F'|' -v k="$w" '$1 == k {printf "%s|%s", $2, $3; exit}')
    [[ -n "$out" ]] || out="unresolvable|no mock"
    printf '%s' "$out"
}

reset_state() { rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; : > "$LOGF"; : > "$PASTES"; }
# `grep -c . f || echo 0` is WRONG on an empty file: grep -c prints `0` and
# exits 1, so the `||` arm fires and the caller gets TWO lines ("0\n0"), which
# compares unequal to "0" and reds every negative-control assertion at once.
pastes_n()    { wc -l < "$PASTES" | tr -d " "; }

# ════════════════════════════════════════════════════════════════════════════
echo '=== resolver: a `syn-` id is UNRESOLVABLE, and is checked BEFORE the kind ==='
# This ordering is load-bearing. `slurm:syn-…` is a real token (a submission
# LOOP tokenised per CALL), and if it reached the sacct arm, `sacct -j syn-…`
# would answer empty and be read as "aged out of accounting" — a different and
# much more reassuring story than "nothing was ever recorded".
v=$(_orphan_async_resolve nohup "syn-4119b85dddbe" w1)
assert_eq "nohup:syn- → unresolvable" "${v%%|*}" "unresolvable"
assert_contains "…and says the launcher retained no handle" "$v" "retained no handle"
v=$(_orphan_async_resolve slurm "syn-0878d118e68c" w1)
assert_eq "slurm:syn- → unresolvable, not routed to sacct" "${v%%|*}" "unresolvable"
assert_not_contains "…and is not reported as aged out of accounting" "$v" "aged out"
# PIN THE MESSAGE, NOT JUST THE CLASS. Mutation-testing this file found that
# moving the `syn-` check below the per-kind arms leaves the CLASS unchanged
# (the numeric-id guard catches it independently) while silently degrading the
# detail to "not a Slurm job id" — which tells the worker its id was malformed
# rather than that its launcher recorded nothing. The detail is what the brief
# prints, so the ordering is only actually pinned by asserting it.
assert_contains "…and says the launcher retained no handle, not that the id was malformed" \
    "$v" "retained no handle"

echo '=== resolver: unknown kind fails to `unresolvable`, not `terminal`/`running` ==='
# The default arm's DIRECTION is the assertion. `terminal` would tell a worker
# its data is good on no evidence; `running` would suppress the wake forever
# and silently recreate the stall this file closes.
v=$(_orphan_async_resolve someNewKind abc123 w1)
assert_eq "unknown kind → unresolvable" "${v%%|*}" "unresolvable"
assert_not_contains "unknown kind is NOT reported terminal" "${v%%|*}" "terminal"
assert_not_contains "unknown kind is NOT reported running"  "${v%%|*}" "running"

echo '=== resolver: Slurm state mapping ==='
_orphan_async_sacct() { printf '%s' "${MOCK_SACCT:-}"; }
MOCK_SACCT="RUNNING|0:0";        assert_eq "RUNNING → running"   "$(_orphan_async_resolve slurm 2219913 w1)" "running|RUNNING"
MOCK_SACCT="PENDING|0:0";        assert_eq "PENDING → running"   "$(_orphan_async_resolve slurm 2219913 w1)" "running|PENDING"
MOCK_SACCT="COMPLETED|0:0";      assert_eq "COMPLETED → terminal" "$(_orphan_async_resolve slurm 2219913 w1)" "terminal|COMPLETED 0:0"
MOCK_SACCT="OUT_OF_MEMORY|0:125"
v=$(_orphan_async_resolve slurm 2219913 w1)
assert_eq "OUT_OF_MEMORY → terminal (Slurm RETAINED the status)" "${v%%|*}" "terminal"
assert_contains "…and the state is carried verbatim" "$v" "OUT_OF_MEMORY 0:125"
MOCK_SACCT="CANCELLED by 1234|0:15"
assert_eq "a state with a trailing reason still classifies" \
    "$(_orphan_async_resolve slurm 2219913 w1)" "terminal|CANCELLED by 1234 0:15"
MOCK_SACCT=""
v=$(_orphan_async_resolve slurm 2219913 w1)
assert_eq "empty sacct → unresolvable, NOT completed" "${v%%|*}" "unresolvable"
MOCK_SACCT="WEIRD_NEW_STATE|0:0"
assert_eq "unrecognised Slurm state → unresolvable" \
    "$(_orphan_async_resolve slurm 2219913 w1 | cut -d'|' -f1)" "unresolvable"
v=$(_orphan_async_resolve slurm "not-a-jobid" w1)
assert_eq "non-numeric slurm id → unresolvable" "${v%%|*}" "unresolvable"

echo '=== resolver: asyncrun three-way, through the REAL launcher ==='
# Not a stub: the whole justification for `monitor/async-run.sh` is that it can
# tell `died` from `terminal`, and a stub would assert the test's own opinion.
if command -v setsid >/dev/null 2>&1; then
    export NEXUS_STATE_DIR="$WORK/ar-state"
    AR="$_repo_root/monitor/async-run.sh"
    tok_ok=$(NEXUS_WORKER_WINDOW=arw "$AR" -- bash -c 'exit 0'  | sed -n 's/^  token   //p')
    tok_rc=$(NEXUS_WORKER_WINDOW=arw "$AR" -- bash -c 'exit 42' | sed -n 's/^  token   //p')
    tok_run=$(NEXUS_WORKER_WINDOW=arw "$AR" -- bash -c 'exec sleep 45' | sed -n 's/^  token   //p')
    # Wait for the two short jobs to land their status files, bounded.
    for _ in $(seq 1 50); do
        [[ -s "$WORK/ar-state/async-run/$(wk_encode arw)/$tok_ok/status" \
        && -s "$WORK/ar-state/async-run/$(wk_encode arw)/$tok_rc/status" ]] && break
        sleep 0.2
    done
    assert_eq "asyncrun rc=0  → terminal" "$(_orphan_async_resolve asyncrun "$tok_ok" arw | cut -d'|' -f1)" "terminal"
    v=$(_orphan_async_resolve asyncrun "$tok_rc" arw)
    assert_eq "asyncrun rc=42 → terminal"       "${v%%|*}" "terminal"
    assert_contains "…carrying the actual rc"   "$v" "rc=42"
    assert_eq "asyncrun in flight → running" "$(_orphan_async_resolve asyncrun "$tok_run" arw | cut -d'|' -f1)" "running"
    # THE VERDICT A BARE `nohup` CANNOT PRODUCE: kill the job's whole session
    # before it can write a status, and confirm it reads `died` — distinct
    # from both `terminal` and `unresolvable`.
    arpid=$(cat "$WORK/ar-state/async-run/$(wk_encode arw)/$tok_run/pid")
    kill -9 -- -"$arpid" 2>/dev/null || kill -9 "$arpid" 2>/dev/null || true
    for _ in $(seq 1 25); do [[ -d "/proc/$arpid" ]] || break; sleep 0.2; done
    v=$(_orphan_async_resolve asyncrun "$tok_run" arw)
    assert_eq "asyncrun KILLED before reporting → died" "${v%%|*}" "died"
    assert_contains "…and says the output is TRUNCATED, not empty" "$v" "TRUNCATED"
    assert_eq "asyncrun unknown token → unresolvable" \
        "$(_orphan_async_resolve asyncrun ar-nosuchtoken arw | cut -d'|' -f1)" "unresolvable"
    # Restore the suite's pin — NOT `unset`, which would advance every later
    # `ng`/`declare-wait.sh` child to arm 2 (`$NEXUS_ROOT/monitor/.state`, the
    # checkout's live state; your-org/nexus-code#1349).
    export NEXUS_STATE_DIR="$STATE_DIR"
    AR_ASSERTS=8
else
    th_skip "setsid unavailable — asyncrun three-way not exercised"
    AR_ASSERTS=0
fi

# From here on the resolver is stubbed: the wake state machine is what is
# under test, and it must not depend on a live scheduler.
_ORPHAN_ASYNC_RESOLVE_FN=_orphan_async_resolve_stub

# ════════════════════════════════════════════════════════════════════════════
echo '=== NEGATIVE CONTROL: one RUNNING wait suppresses the wake entirely ==='
# Same fixture twice; the ONLY variable is whether slurm:222 is running.
reset_state
MOCK_PANE='w1|state=idle-orphan-async orphan_kinds=slurm:111,slurm:222'
MOCK_RESOLVE=$'slurm:111|terminal|COMPLETED 0:0\nslurm:222|running|RUNNING'
_orphan_async_write_row w1 "slurm:111,slurm:222" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
_orphan_async_process_wakes t
assert_eq "a still-RUNNING job means NO paste" "$(pastes_n)" "0"
assert_contains "…and the reason is logged" "$(cat "$LOGF")" "STILL RUNNING"
assert_contains "…and the row is KEPT so it is re-checked" "$(_orphan_async_load w1)" "slurm:111,slurm:222"

reset_state
MOCK_RESOLVE=$'slurm:111|terminal|COMPLETED 0:0\nslurm:222|terminal|COMPLETED 0:0'
_orphan_async_write_row w1 "slurm:111,slurm:222" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
_orphan_async_process_wakes t
assert_eq "…and with that ONE variable flipped, the wake DOES fire" "$(pastes_n)" "1"
assert_eq "…the woken window is the right one" "$(cat "$PASTES")" "w1"
assert_eq "…and the row is dropped after delivery" "$(_orphan_async_load w1)" ""

echo '=== NEGATIVE CONTROL: queued=1 refuses delivery and KEEPS the row ==='
# #1065: pasting into a pane that already has input waiting behind a running
# turn stacks a second copy. Dropping the row here would be worse than not
# waking at all — the stall would then be invisible to the next scan.
reset_state
MOCK_PANE='w1|state=busy queued=1'
MOCK_RESOLVE='slurm:111|terminal|COMPLETED 0:0'
_orphan_async_write_row w1 "slurm:111" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
_orphan_async_process_wakes t
assert_eq "queued=1 → no paste" "$(pastes_n)" "0"
assert_contains "…logged as a refusal to deliver" "$(cat "$LOGF")" "queued"
assert_contains "…and the row is RETAINED, not dropped" "$(_orphan_async_load w1)" "slurm:111"

echo '=== NEGATIVE CONTROL: pane recovered on its own → drop, and DO NOT paste ==='
reset_state
MOCK_PANE='w1|state=busy'
_orphan_async_write_row w1 "slurm:111" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
_orphan_async_process_wakes t
assert_eq "recovered pane → no paste" "$(pastes_n)" "0"
assert_eq "…and the row is dropped"   "$(_orphan_async_load w1)" ""

echo '=== "could not look" is not "fine": an empty probe HOLDS the row ==='
reset_state
MOCK_PANE=''
_orphan_async_write_row w1 "slurm:111" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
_orphan_async_process_wakes t
assert_eq "unprobeable pane → no paste" "$(pastes_n)" "0"
assert_contains "…and the row is held, not dropped" "$(_orphan_async_load w1)" "slurm:111"
assert_contains "…logged as could-not-probe" "$(cat "$LOGF")" "could NOT probe"

echo '=== grace: a FRESH stall is not woken before the grace elapses ==='
reset_state
MOCK_PANE='w1|state=idle-orphan-async orphan_kinds=slurm:111'
_orphan_async_write_row w1 "slurm:111" "$NOW" "$(( $(date +%s) + 3600 ))" 0
_orphan_async_process_wakes t
assert_eq "not yet due → no paste" "$(pastes_n)" "0"
assert_contains "…row untouched" "$(_orphan_async_load w1)" "slurm:111"

echo '=== cooldown: a just-woken window is not woken again ==='
reset_state
MOCK_PANE='w1|state=idle-orphan-async orphan_kinds=slurm:111'
_orphan_async_mark_woken w1 "$(date +%s)"
_orphan_async_write_row w1 "slurm:111" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
_orphan_async_process_wakes t
assert_eq "inside cooldown → no paste" "$(pastes_n)" "0"
assert_contains "…logged as cooldown" "$(cat "$LOGF")" "cooldown"
# …and outside it, the same fixture wakes.
_orphan_async_mark_woken w1 "$(( $(date +%s) - 99999 ))"
_orphan_async_write_row w1 "slurm:111" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
_orphan_async_process_wakes t
assert_eq "outside cooldown → wakes" "$(pastes_n)" "1"

echo '=== ceiling: an ancient row is DROPPED, never fail-open pasted ==='
# Deliberately unlike _over_limit.sh, whose ceiling fails OPEN with a paste.
# There a held row suppresses the operator channel; here it suppresses
# nothing, so a paste would be an unprovoked wake.
reset_state
MOCK_PANE='w1|state=idle-orphan-async orphan_kinds=slurm:111'
_orphan_async_write_row w1 "slurm:111" "$(( $(date +%s) - 999999 ))" "0" 0
_orphan_async_process_wakes t
assert_eq "ceiling → no paste"      "$(pastes_n)" "0"
assert_eq "ceiling → row dropped"   "$(_orphan_async_load w1)" ""
assert_contains "…logged as the ceiling" "$(cat "$LOGF")" "absolute ceiling"

echo '=== a failed paste retries and does NOT mark the window woken ==='
reset_state
_ORPHAN_ASYNC_PASTE_FN=_orphan_async_paste_fail
MOCK_PANE='w1|state=idle-orphan-async orphan_kinds=slurm:111'
MOCK_RESOLVE='slurm:111|terminal|COMPLETED 0:0'
_orphan_async_write_row w1 "slurm:111" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
_orphan_async_process_wakes t
assert_contains "failed paste keeps the row" "$(_orphan_async_load w1)" "slurm:111"
assert_eq "failed paste does not enter cooldown" \
    "$(_orphan_async_in_cooldown w1 "$(date +%s)" && echo suppressed || echo open)" "open"
_ORPHAN_ASYNC_PASTE_FN=_orphan_async_paste_rec

# ════════════════════════════════════════════════════════════════════════════
echo '=== the brief puts RESUME first and `declare-no-wait` last, as the exception ==='
reset_state
R="$WORK/resolved"
printf 'slurm:111\tterminal\tCOMPLETED 0:0\n' > "$R"
b=$(_orphan_async_compose_brief w1 900 "$R")
assert_contains "brief tells the worker to resume"        "$b" "RESUME YOUR TASK NOW"
assert_contains "brief states the waits were NOT cleared" "$b" "have NOT been cleared"
assert_contains "brief names declare-no-wait as the EXCEPTION" "$b" "the EXCEPTION"
assert_contains "brief warns clearing a running job loses the record" "$b" "destroys the only record"
# ORDERING, asserted rather than assumed: an emit that offers clearing as a
# co-equal first option is the hazard `#1071` names in the current emit text.
_r=$(grep -n 'RESUME YOUR TASK NOW' <<<"$b" | cut -d: -f1)
_c=$(grep -n 'declare-no-wait'      <<<"$b" | cut -d: -f1)
if [[ -n "$_r" && -n "$_c" ]] && (( _r < _c )); then
    printf '  PASS: resume appears BEFORE the clearing option (%s < %s)\n' "$_r" "$_c"; _th_pass
else
    printf '  FAIL: clearing is offered at or before resume (resume=%s clear=%s)\n' "$_r" "$_c" >&2; _th_fail
fi
assert_not_contains "an all-terminal brief carries NO truncation warning" "$b" "TRUNCATED"
# An ALL-TERMINAL brief is entitled to the strong claim, and must keep it —
# hedging every brief would be its own defect (a worker learns to ignore it).
assert_contains "an all-terminal brief DOES claim nothing is running" "$b" "NONE of them is still running"

printf 'nohup:syn-abc\tunresolvable\tthe launcher retained no handle\n' >> "$R"
b=$(_orphan_async_compose_brief w1 900 "$R")
assert_contains "an unresolvable wait DOES warn about truncation" "$b" "TRUNCATED, PLAUSIBLE"
assert_contains "…and says an absent process is not a completed job" "$b" "AN ABSENT PROCESS IS NOT A COMPLETED JOB"
assert_contains "…and names the status-preserving launcher" "$b" "async-run.sh"
assert_contains "…and refuses non-emptiness as a check" "$b" "Non-emptiness is not"

echo '=== F1: the header must NOT assert what the resolver could not establish ==='
# Skeptic F1 on your-org/nexus-code#1071, CONFIRMED and reproduced end-to-end
# against a producer shown ALIVE at the moment of delivery. The header read
# `NONE of them is still running` unconditionally, including when every wait
# resolved `unresolvable` — the ordinary case for the `syn-` waits this issue is
# about. Neither `unresolvable` (nothing was retained; state UNKNOWN) nor `died`
# (no status written; the skeptic measured a SIGKILLed runner whose grandchild
# was still alive) entails "not running". The wake fires when nothing resolved
# `running`, which is NOT the claim that nothing IS running — and that gap is
# this change's own thesis inverted in the one artefact a worker reads.
# `$b` is the two-wait brief composed above: one terminal, one unresolvable.
_hdr=$(printf '%s' "$b" | grep -c 'NONE of them is still running')
assert_eq "a brief with an unresolvable wait does NOT claim nothing is running" "$_hdr" "0"
assert_contains "…it says they MAY STILL BE RUNNING"        "$b" "MAY STILL BE RUNNING"
assert_contains "…and names how many could not be resolved" "$b" "1 of them"
assert_contains "…and distinguishes observed-running from is-running" \
    "$b" "NOT the same"
# The imperative is deliberately untouched: resuming is correct in EVERY case,
# and hedging the status claim must not weaken it or the stall comes back.
assert_contains "…while RESUME YOUR TASK NOW survives the hedge" "$b" "RESUME YOUR TASK NOW"
# A `died`-only brief is the second unknown-state case and must hedge too.
printf 'asyncrun:ar-x\tdied\tpid gone, no status\n' > "$R"
_bd=$(_orphan_async_compose_brief w1 900 "$R")
_hdrd=$(printf '%s' "$_bd" | grep -c 'NONE of them is still running')
assert_eq "a died-only brief also refuses the strong claim" "$_hdrd" "0"
assert_contains "…and hedges the same way" "$_bd" "MAY STILL BE RUNNING"

echo '=== F5: the field parser takes the FIRST exact key on a REAL boundary ==='
# Skeptic F5, CONFIRMED. The old regex allowed a ZERO-WIDTH boundary and `.*`
# is greedy, so a token merely ENDING in the field name shadowed the real one
# and the LAST match won. Reachable through a tmux window name containing a
# space plus `state=`; the harmful direction (pasting into a busy pane) is
# exactly what this loop must not do.
_shadow='state=idle-orphan-async active=0 name=w refined_state=busy'
assert_eq "a token ENDING in the key does not shadow the real field" \
    "$(_orphan_async_field "$_shadow" state)" "idle-orphan-async"
assert_eq "…same for queued (tqueued=0 must not win)" \
    "$(_orphan_async_field 'state=busy queued=1 tqueued=0' queued)" "1"
assert_eq "…and an absent key is still empty" \
    "$(_orphan_async_field 'state=idle' queued)" ""

# ════════════════════════════════════════════════════════════════════════════
echo '=== scan: records, preserves first_seen, refreshes waits, drops on recovery ==='
reset_state
_idle_list_worker_windows() { printf '%s\n' "${MOCK_WORKERS:-}"; }
MOCK_WORKERS=$'w1\t0\t7'
MOCK_PANE='7|state=idle-orphan-async orphan_kinds=slurm:111'
_orphan_async_scan_panes t
row=$(_orphan_async_load w1)
assert_contains "scan records the stalled window" "$row" "slurm:111"
fs=$(awk -F'\t' '{print $3}' <<<"$row")
# Re-scan with a LARGER wait set: the waits must update, first_seen must not.
MOCK_PANE='7|state=idle-orphan-async orphan_kinds=slurm:111,nohup:syn-z'
_orphan_async_scan_panes t
row=$(_orphan_async_load w1)
assert_eq "re-observation preserves first_seen" "$(awk -F'\t' '{print $3}' <<<"$row")" "$fs"
assert_contains "…and refreshes the wait set"   "$row" "nohup:syn-z"
# Recovery drops the row, and delivers nothing.
MOCK_PANE='7|state=idle'
_orphan_async_scan_panes t
assert_eq "scan drops the row when the pane recovers" "$(_orphan_async_load w1)" ""
assert_eq "scan never pastes" "$(pastes_n)" "0"
# An unprobeable pane neither records nor drops.
MOCK_PANE='7|state=idle-orphan-async orphan_kinds=slurm:111'
_orphan_async_scan_panes t
MOCK_PANE=''
_orphan_async_scan_panes t
assert_contains "an unprobeable pane does NOT drop an existing row" "$(_orphan_async_load w1)" "slurm:111"

echo '=== the loop is disable-able, and disabled means fully inert ==='
reset_state
MOCK_PANE='w1|state=idle-orphan-async orphan_kinds=slurm:111'
MOCK_RESOLVE='slurm:111|terminal|COMPLETED 0:0'
_orphan_async_write_row w1 "slurm:111" "$(( NOW - 1000 ))" "$(( NOW - 1 ))" 0
MONITOR_ORPHAN_ASYNC_ENABLED=0 _orphan_async_process_wakes t
assert_eq "disabled → no paste" "$(pastes_n)" "0"
assert_contains "disabled → row untouched" "$(_orphan_async_load w1)" "slurm:111"

echo '=== the field parser is checked against a REAL pane-state emit, not a stub ==='
# NON-VACUITY. Every case above feeds `_orphan_async_field` a line THIS FILE
# wrote, so together they prove only that the parser agrees with the test
# author. If the real `pane-state.sh` emit shape differs in any way — field
# order, a `queued=1` that is not a bare token, an `orphan_kinds` that is
# quoted — every gate above passes while the loop silently reads empty strings
# in production and either never wakes or wakes into a queued pane. So drive
# the REAL script, with its own committed fixture, and parse THAT.
_fix="$_repo_root/monitor/watcher/fixtures/idle-empty-synthetic.ansi"
_qfix="$_repo_root/monitor/watcher/fixtures/busy-dialog-quoted-queued-synthetic.ansi"
if [[ -r "$_fix" && -r "$_qfix" ]] && command -v jq >/dev/null 2>&1; then
    _now=$(date +%s)
    _hb="$WORK/real-hb.json"
    jq -nc --argjson n "$_now" '{window:"test",state:"idle_prompt",last_activity:($n-5),
        external_waits:[{kind:"slurm",id:"2219913",desc:"a"},{kind:"nohup",id:"syn-abc",desc:"b"}],
        dismissed_waits:[]}' > "$_hb"
    _real=$("$_repo_root/monitor/pane-state.sh" --fixture "$_fix" \
                --window 9 --name test --active 0 --heartbeat-file "$_hb" --now "$_now" 2>&1)
    # Guard the guard: if pane-state did not classify it, the parse assertions
    # below would be asserting against the wrong line and would pass vacuously.
    assert_contains "control: the real pane-state DOES emit idle-orphan-async here" \
        "$_real" "state=idle-orphan-async"
    assert_eq "…and the parser reads its state"        "$(_orphan_async_field "$_real" state)" "idle-orphan-async"
    assert_eq "…and its orphan_kinds, verbatim"        "$(_orphan_async_field "$_real" orphan_kinds)" "slurm:2219913,nohup:syn-abc"
    assert_eq "…and reads NO queued on a pane with none" "$(_orphan_async_field "$_real" queued)" ""
    _realq=$("$_repo_root/monitor/pane-state.sh" --fixture "$_qfix" \
                 --window 9 --name test --active 1 --now "$_now" 2>&1)
    assert_contains "control: the real pane-state DOES emit queued=1 here" "$_realq" "queued=1"
    assert_eq "…and the parser reads queued=1 off it" "$(_orphan_async_field "$_realq" queued)" "1"
    REAL_ASSERTS=6
else
    th_skip "pane-state fixtures or jq unavailable — real-emit parse not exercised"
    REAL_ASSERTS=0
fi

# ---- assertion-count guard ------------------------------------------------
# The summary reports assertions that RAN; one that never ran is invisible to
# it (a typo'd helper is `command not found`, tallied nowhere). Bump this
# deliberately when adding a case — a DROP means a case stopped running.
# The asyncrun block is conditional on `setsid` and the real-emit block on
# the pane-state fixtures, so their assertions are added via AR_ASSERTS /
# REAL_ASSERTS rather than baked into the constant.
# ---- stray-write tripwire (your-org/nexus-code#1349) -----------------------
# Compare, never delete: on an operator's primary this path is live state.
_stray_after=$(stat -c %Y "$_stray_hb" 2>/dev/null || echo absent)
assert_eq "the checkout's own monitor/.state/heartbeat/w1.json was NOT written by this run (before=$_stray_before)" \
    "$_stray_after" "$_stray_before"

EXPECTED_ASSERTIONS=$(( 70 + AR_ASSERTS + REAL_ASSERTS ))
_ran=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _ran == EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
