#!/usr/bin/env bash
# Tests for the FOLLOW-UP arm of bootstrap-recover.sh's worker-inclusion
# predicate: a window whose latest lifecycle event is a wrap-up is still
# resumed when its follow-up work is live.
#
# The incident (2026-09-28 17:05): the nexus restarted with `--continue` and
# recovery resumed only `mailguard`. `authmail` (round 5 of a skeptic loop on a
# PR) and `authmailsk` (its paired skeptic, waiting for the delta) had both run
# `ng wrap-up` on EARLIER rounds, so both read as done and were dropped. Every
# multi-round skeptic loop has this shape.
#
# Strategy: source the REAL bootstrap-recover.sh (sourcing runs no main) with
# NEXUS_STATE_DIR pointed at a per-case fixture, seed the action log, snapshot,
# machine-input ledger, skeptic state and request inbox, then call the same
# entry points recovery does — `_recover_capture_followup_inputs` followed by
# `_recover_snapshot_workers` — and assert on the emitted `<name>\t<why>` rows
# and the logged reasons. Hermetic: no tmux, no network, no real state dir.
# The end-to-end path (plan brief column, capture before the watcher relaunch)
# is exercised in test-bootstrap-recover.sh cases 39-40.
#
# Cases:
#   F1.  Today's replay: authmail (dispatched after wrap) and authmailsk
#        (dispatched + held after wrap) resumed, mailguard resumed as active,
#        ccpolicy / recoverymsg / ncbundle7 / ncbundle7sk (closed) NOT — and at
#        the moment BEFORE the 08:22 dispatch, authmailsk is skipped.
#   F2.  Wrapped, then dispatched → resumed (follow-up:dispatched).
#   F3.  Wrapped and idle → skipped; a paste BEFORE the wrap does not count;
#        a re-wrap after the dispatch ends it.
#   F4.  Wrapped, then held (non-wrap-up window-retain) → resumed.
#   F5.  Open skeptic pairing: target with a live require-marker, and the
#        skeptic of such a target, both resumed; the skeptic whose target has
#        NO marker is skipped.
#   F6.  Closed pairing: a skeptic dispatched after its wrap whose channel was
#        then closed (DONE newer) is skipped; with DONE OLDER than the dispatch
#        it is resumed (the control).
#   F7.  Retired (window-close) is never resurrected, even with a dispatch, a
#        hold, a live marker, a machine-input stamp and an open request.
#   F8.  machine-input `paste-followup` stamp after the wrap → resumed
#        (delivered); before the wrap, or another kind → skipped.
#   F9.  An open spawn-skeptic request naming the window → resumed; a `.done`
#        one → skipped.
#   F10. Fail direction: an unreadable machine-input ledger or skeptic state →
#        resumed with `unknown:<source>`, the walk completes, a warning is
#        logged. An ABSENT source is not unreadable.
#   F11. An active window keeps `active` (a paste to an UNWRAPPED window
#        changes nothing). The engaged why is covered end-to-end by
#        test-bootstrap-recover.sh case 23.
#
# Run: bash monitor/watcher/test-bootstrap-recover-followup.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_real_test_dir/_test_helpers.sh"
REAL_RECOVER="$_real_test_dir/../bootstrap-recover.sh"

# ── this suite DECLARES its own population (the --population protocol) ──────
. "$_real_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' \
        monitor/bootstrap-recover.sh \
        monitor/_autocontinue_plan.sh \
        monitor/_bookkeeping.sh \
        monitor/watcher/_idle_probe.sh \
        monitor/watcher/_test_helpers.sh
}
gp_handle "$@"

# `PASS: <label>` / `FAIL: <label> — <detail>`, the _test_helpers.sh shape, so
# monitor/mutation-gate.sh can name which case a mutant flipped. Counted
# through the helpers' durable ledger (_th_pass/_th_fail), which is what
# th_summary_and_exit reconciles.
fail() { echo "  FAIL: $*"; _th_fail; }
pass() { echo "  PASS: $*"; _th_pass; }

[[ -r "$REAL_RECOVER" ]] || th_abort "cannot read $REAL_RECOVER"

# A running as root would make every chmod-000 case vacuous.
if [[ "$(id -u)" == 0 ]]; then
    th_abort "run as a non-root user (the unreadable-source cases need a real EACCES)"
fi

new_case() {
    CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/recover-fu-$1-XXXXXX") || th_abort "mktemp failed"
    SD="$CASE_ROOT/state"
    mkdir -p "$SD" "$CASE_ROOT/config"
    # config/load.sh stub: every key resolves to its default.
    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$CASE_ROOT/config/load.sh"
    chmod +x "$CASE_ROOT/config/load.sh"
    : > "$SD/action-log.jsonl"
}

end_case() {
    chmod -R u+rwX "$CASE_ROOT" 2>/dev/null
    rm -rf "$CASE_ROOT"
}

# ev <ts> <event> <window> [extra-json]
ev() {
    printf '{"ts":"%s","agent":"monitor","event":"%s","window":"%s"%s}\n' \
        "$1" "$2" "$3" "${4:-}" >> "$SD/action-log.jsonl"
}

snapshot() {
    {
        echo '--- reports ---'
        echo '--- tmux ---'
        local w
        for w in "$@"; do echo "$w bell=0"; done
        echo '--- github ---'
    } > "$SD/last-snapshot.txt"
}

# mi <window> <iso-ts> [kind] — one machine-input row, epoch in microseconds.
mi() {
    local e
    e=$(date -d "$2" +%s)
    printf '%s\t%s000000\t%s\t\n' "$1" "$e" "${3:-paste-followup}" >> "$SD/machine-input.tsv"
}

marker() { mkdir -p "$SD/skeptic/pending"; : > "$SD/skeptic/pending/$1"; }

# request <state> <target-window> [kind]
request() {
    mkdir -p "$SD/requests"
    cat > "$SD/requests/20260928T000000Z-$2-skeptic-d1.$1.md" <<EOF
---
request: 20260928T000000Z-$2-skeptic-d1
origin: $2
kind: ${3:-spawn-skeptic}
state: new
---

## Request

spawn-skeptic: validate \`$2\`

window: $2
target-window: $2
EOF
}

# Run recovery's candidate resolution against the fixture. OUT = stdout
# (`name<TAB>why` rows), ERR = the `[recover]` log, RC = exit status.
resolve() {
    OUT=$(NEXUS_ROOT="$CASE_ROOT" NEXUS_STATE_DIR="$SD" \
          NEXUS_SERVICES_REGISTRY="$CASE_ROOT/no-registry" \
          bash -c 'source "$1" || exit 90
                   _recover_capture_engaged_windows
                   _recover_capture_followup_inputs
                   _recover_snapshot_workers' _ "$REAL_RECOVER" 2>"$CASE_ROOT/err")
    RC=$?
    ERR=$(cat "$CASE_ROOT/err")
}

# why_of <window> — the why recovery emitted for it, or NONE.
why_of() {
    local w="$1" line
    line=$(awk -F'\t' -v w="$w" '$1 == w { print $2; exit }' <<<"$OUT")
    printf '%s' "${line:-NONE}"
}

expect_why() {
    local w="$1" want="$2" label="$3: $1 → $2" got
    got=$(why_of "$w")
    if [[ "$got" == "$want" ]]; then
        pass "$label"
    else
        fail "$label — got [$got]; err: $(tr '\n' '|' <<<"$ERR")"
    fi
}

expect_log() {
    # An EMPTY needle matches every haystack (your-org/nexus-code#1038): refuse it.
    if [[ -z "$1" ]]; then
        fail "$2 — EMPTY needle: this assertion would pass vacuously"
    elif grep -qF -- "$1" <<<"$ERR"; then
        pass "$2"
    else
        fail "$2 — missing log line [$1]; err: $(tr '\n' '|' <<<"$ERR")"
    fi
}

# --- F1: today's replay ------------------------------------------------------
# The lifecycle-relevant events of 2026-09-27/28 for every window named in the
# incident, at their REAL timestamps, from the live action log. Only the
# fields the predicate reads are kept (the real rows also carry report paths
# and asset URLs). The snapshot is the set of windows that could have been in
# tmux at 17:05.
seed_replay() {
    # authmail: spawned, four rounds each ending in a wrap-up, round 5
    # dispatched at 08:22 and still running at 17:05.
    ev 2026-09-27T10:22:33-07:00 spawn authmail ',"kind":"task","skeptic-mode":"require"'
    ev 2026-09-27T11:50:47-07:00 spawn authmail ',"mode":"resume"'
    ev 2026-09-27T11:51:43-07:00 paste-followup authmail ',"outcome":"submitted","rc":"0"'
    ev 2026-09-27T12:21:19-07:00 wrap-up authmail ',"issue":"1653"'
    ev 2026-09-27T12:21:19-07:00 window-retain authmail ',"reason":"wrap-up-2026-09-27","issue":"1653"'
    ev 2026-09-27T12:22:08-07:00 spawn authmailsk ',"kind":"task","skeptic-mode":"auto"'
    ev 2026-09-27T12:22:09-07:00 skeptic-spawn authmailsk ',"target-window":"authmail","orig-window":"authmail","depth":"0"'
    ev 2026-09-27T13:15:37-07:00 skeptic-verdict authmailsk ',"target-window":"authmail","verdict":"check"'
    ev 2026-09-27T13:15:49-07:00 wrap-up authmailsk ',"issue":"1653"'
    ev 2026-09-27T13:15:49-07:00 window-retain authmailsk ',"reason":"wrap-up-2026-09-27","issue":"1653"'
    ev 2026-09-27T13:16:26-07:00 paste-followup authmail ',"outcome":"submitted (queued behind a running turn)","rc":"0"'
    ev 2026-09-27T13:16:36-07:00 paste-followup authmailsk ',"outcome":"submitted","rc":"0"'
    ev 2026-09-27T13:19:10-07:00 window-retain authmailsk ',"reason":"paired skeptic waiting for authmail round-2 delta"'
    ev 2026-09-27T15:47:17-07:00 wrap-up authmail ',"issue":"1653"'
    ev 2026-09-27T15:47:17-07:00 window-retain authmail ',"reason":"wrap-up-2026-09-27","issue":"1653"'
    ev 2026-09-27T16:08:53-07:00 wrap-up authmailsk ',"issue":"1653"'
    ev 2026-09-27T16:08:53-07:00 window-retain authmailsk ',"reason":"wrap-up-2026-09-27","issue":"1653"'
    ev 2026-09-27T16:09:17-07:00 paste-followup authmail ',"outcome":"submitted (queued behind a running turn)","rc":"0"'
    ev 2026-09-27T16:10:18-07:00 window-retain authmailsk ',"reason":"paired skeptic waiting for authmail round-3 delta"'
    ev 2026-09-27T18:02:18-07:00 wrap-up authmail ',"issue":"1653"'
    ev 2026-09-27T18:02:18-07:00 window-retain authmail ',"reason":"wrap-up-2026-09-28","issue":"1653"'
    ev 2026-09-27T18:08:29-07:00 wrap-up authmailsk ',"issue":"1653"'
    ev 2026-09-27T18:08:29-07:00 window-retain authmailsk ',"reason":"wrap-up-2026-09-28","issue":"1653"'
    ev 2026-09-27T18:08:58-07:00 paste-followup authmail ',"outcome":"submitted (queued behind a running turn)","rc":"0"'
    ev 2026-09-27T18:09:02-07:00 paste-followup authmailsk ',"outcome":"submitted","rc":"0"'
    ev 2026-09-27T18:20:01-07:00 window-retain authmailsk ',"reason":"paired skeptic waiting for authmail round-4 delta"'
    ev 2026-09-28T05:59:08-07:00 wrap-up authmail ',"issue":"1653"'
    ev 2026-09-28T05:59:09-07:00 window-retain authmail ',"reason":"wrap-up-2026-09-28","issue":"1653"'
    ev 2026-09-28T08:21:23-07:00 skeptic-verdict authmailsk ',"target-window":"authmail","verdict":"check"'
    ev 2026-09-28T08:21:42-07:00 wrap-up authmailsk ',"issue":"1653"'
    ev 2026-09-28T08:21:42-07:00 window-retain authmailsk ',"reason":"wrap-up-2026-09-28","issue":"1653"'
    ev 2026-09-28T08:22:28-07:00 paste-followup authmail ',"outcome":"submitted (queued behind a running turn)","rc":"0"'
    ev 2026-09-28T08:22:44-07:00 paste-followup authmailsk ',"outcome":"submitted","rc":"0"'
    ev 2026-09-28T08:22:44-07:00 window-retain authmailsk ',"reason":"paired skeptic waiting for authmail round 5 (dev merge + I1) on PR 1656"'
    ev 2026-09-28T08:43:01-07:00 window-retain authmailsk ',"reason":"paired skeptic waiting for authmail round 5 (dev merge + I1) on PR 1656"'
    # ccpolicy: wrapped, dispatched, re-wrapped, then CLOSED.
    ev 2026-09-27T12:30:35-07:00 spawn ccpolicy ',"kind":"task"'
    ev 2026-09-27T19:32:28-07:00 wrap-up ccpolicy ',"issue":"1657"'
    ev 2026-09-27T19:32:28-07:00 window-retain ccpolicy ',"reason":"wrap-up-2026-09-28","issue":"1657"'
    ev 2026-09-27T20:16:06-07:00 paste-followup ccpolicy ',"outcome":"submitted","rc":"0"'
    ev 2026-09-27T20:48:43-07:00 wrap-up ccpolicy ',"issue":"1657"'
    ev 2026-09-27T20:50:05-07:00 window-close ccpolicy ',"reason":"retire-window"'
    # recoverymsg: wrapped, dispatched, held for its skeptic, then CLOSED.
    ev 2026-09-27T12:13:02-07:00 spawn recoverymsg ',"kind":"task"'
    ev 2026-09-27T14:58:33-07:00 wrap-up recoverymsg ',"issue":"1654"'
    ev 2026-09-27T16:10:07-07:00 paste-followup recoverymsg ',"outcome":"submitted","rc":"0"'
    ev 2026-09-27T17:33:09-07:00 window-retain recoverymsg ',"reason":"waiting for recoverymsgsk delta verdict on PR 1660"'
    ev 2026-09-27T18:27:15-07:00 window-close recoverymsg ',"reason":"retire-window"'
    # ncbundle7 / ncbundle7sk: resumed at the 09-27 restart, dispatched, CLOSED.
    ev 2026-09-27T11:50:56-07:00 spawn ncbundle7 ',"mode":"resume"'
    ev 2026-09-27T12:46:09-07:00 paste-followup ncbundle7 ',"outcome":"submitted","rc":"0"'
    ev 2026-09-27T12:59:07-07:00 window-close ncbundle7 ',"reason":"retire-window"'
    ev 2026-09-27T11:51:00-07:00 spawn ncbundle7sk ',"mode":"resume"'
    ev 2026-09-27T12:44:44-07:00 paste-followup ncbundle7sk ',"outcome":"submitted","rc":"0"'
    ev 2026-09-27T12:45:59-07:00 window-close ncbundle7sk ',"reason":"retire-window"'
    # mailguard: spawned 14:15, never wrapped — the one recovery DID resume.
    ev 2026-09-28T14:15:16-07:00 spawn mailguard ',"kind":"task","skeptic-mode":"require"'
    ev 2026-09-28T16:37:34-07:00 paste-followup mailguard ',"outcome":"submitted","rc":"0"'
    # The skeptic state and inbox as they stood: authmailsk's depth-1
    # spawn-skeptic request had been ACKED (.done) and an unrelated stale
    # marker sat in pending/.
    request done authmailsk
    marker audit337
    snapshot orchestrator authmail authmailsk mailguard ccpolicy recoverymsg ncbundle7 ncbundle7sk
}

echo '=== F1: the 2026-09-28 17:05 replay ==='
new_case f1
seed_replay
resolve
expect_why authmail   'follow-up:dispatched+owes-delta'                'F1 replay'
expect_why authmailsk 'follow-up:dispatched+held+skeptic-awaiting-fix' 'F1 replay'
expect_why mailguard  'active'                    'F1 replay'
for w in ccpolicy recoverymsg ncbundle7 ncbundle7sk; do
    expect_why "$w" NONE 'F1 replay (closed, never resurrected)'
done
if [[ "$(wc -l <<<"$OUT")" == 3 ]]; then
    pass "F1 replay: exactly three candidates"
else
    fail "F1 replay: exactly three candidates — got [$(tr '\n' ' ' <<<"$OUT")]"
fi
expect_log "worker 'authmail': wrapped BUT follow-up live (dispatched+owes-delta) — resuming" "F1: authmail logged with its signal"
expect_log "worker 'ccpolicy': already wrapped/closed per action log (window-close: never resurrected)" "F1: ccpolicy logged as terminal"
# The same ledger cut just after authmailsk's 08:21:42 wrap-up and BEFORE the
# 08:22 dispatches — the uncovered gap of skeptic F1 on #1666. Neither window
# had been pasted or held yet, but the round was open: authmailsk's round-4
# verdict at 08:21:23 was `check`, so authmail owed the fix (the verdict came
# after its 05:59 wrap-up) and authmailsk owed the re-review. Both resume on
# that signal alone. Round 1 of this PR dropped both here.
# Every replay ts carries the same -07:00 offset, so a string compare orders them.
awk -F'"' '$4 < "2026-09-28T08:22:00-07:00"' "$SD/action-log.jsonl" > "$SD/cut" \
    && mv "$SD/cut" "$SD/action-log.jsonl"
resolve
expect_why authmailsk 'follow-up:skeptic-awaiting-fix' 'F1 replay at 08:22:00 (before the round-5 dispatch)'
expect_why authmail   'follow-up:owes-delta' 'F1 replay at 08:22:00 (before the round-5 dispatch)'
expect_why mailguard  NONE 'F1 replay at 08:22:00 (not spawned until 14:15)'
end_case

# --- F2 / F3: dispatched vs idle ---------------------------------------------
echo '=== F2/F3: wrapped-then-dispatched resumed; wrapped-and-idle skipped ==='
new_case f2
ev 2026-06-10T10:00:00-07:00 spawn w-disp
ev 2026-06-10T11:00:00-07:00 wrap-up w-disp
ev 2026-06-10T12:00:00-07:00 paste-followup w-disp ',"rc":"0"'
ev 2026-06-10T10:00:00-07:00 spawn w-idle
ev 2026-06-10T11:00:00-07:00 wrap-up w-idle
ev 2026-06-10T10:00:00-07:00 spawn w-pre
ev 2026-06-10T10:30:00-07:00 paste-followup w-pre ',"rc":"0"'
ev 2026-06-10T11:00:00-07:00 wrap-up w-pre
ev 2026-06-10T10:00:00-07:00 spawn w-rewrap
ev 2026-06-10T11:00:00-07:00 wrap-up w-rewrap
ev 2026-06-10T11:30:00-07:00 paste-followup w-rewrap ',"rc":"0"'
ev 2026-06-10T12:00:00-07:00 window-retain w-rewrap ',"reason":"wrap-up-2026-06-10"'
snapshot w-disp w-idle w-pre w-rewrap
resolve
expect_why w-disp   'follow-up:dispatched' 'F2 wrapped-then-dispatched'
expect_why w-idle   NONE 'F3 wrapped-and-idle'
expect_why w-pre    NONE 'F3 paste BEFORE the wrap-up'
expect_why w-rewrap NONE 'F3 dispatched then re-wrapped (companion retain)'
expect_log "worker 'w-idle': already wrapped/closed per action log — skipping" "F3: idle skip logged"
end_case

# --- F4: held ----------------------------------------------------------------
echo '=== F4: wrapped, then held by the orchestrator ==='
new_case f4
ev 2026-06-10T10:00:00-07:00 spawn w-held
ev 2026-06-10T11:00:00-07:00 wrap-up w-held
ev 2026-06-10T12:00:00-07:00 window-retain w-held ',"reason":"paired skeptic waiting for round 3"'
snapshot w-held
resolve
expect_why w-held 'follow-up:held' 'F4 wrapped-then-held'
end_case

# --- F5: open skeptic pairing ------------------------------------------------
echo '=== F5: open skeptic pairing resumes target and skeptic ==='
new_case f5
ev 2026-06-10T10:00:00-07:00 spawn w-tgt
ev 2026-06-10T11:00:00-07:00 wrap-up w-tgt
ev 2026-06-10T11:01:00-07:00 spawn w-tgt-sk
ev 2026-06-10T11:01:01-07:00 skeptic-spawn w-tgt-sk ',"target-window":"w-tgt","orig-window":"w-tgt","depth":"0"'
ev 2026-06-10T11:30:00-07:00 wrap-up w-tgt-sk
ev 2026-06-10T10:00:00-07:00 spawn w-free
ev 2026-06-10T11:00:00-07:00 wrap-up w-free
ev 2026-06-10T11:01:00-07:00 spawn w-free-sk
ev 2026-06-10T11:01:01-07:00 skeptic-spawn w-free-sk ',"target-window":"w-free","orig-window":"w-free","depth":"0"'
ev 2026-06-10T11:30:00-07:00 wrap-up w-free-sk
marker w-tgt
snapshot w-tgt w-tgt-sk w-free w-free-sk
resolve
expect_why w-tgt     'follow-up:skeptic-pending' 'F5 target with a live require-marker'
expect_why w-tgt-sk  'follow-up:skeptic-owed'    'F5 skeptic of a target with a live marker'
expect_why w-free    NONE 'F5 target with no marker'
expect_why w-free-sk NONE 'F5 skeptic whose target has no marker'
end_case

# --- F6: closed pairing ends the follow-up -----------------------------------
echo '=== F6: a skeptic whose pairing was closed is skipped; DONE older is not a close ==='
new_case f6
ev 2026-06-10T10:00:00-07:00 spawn w-t
ev 2026-06-10T10:00:00-07:00 wrap-up w-t
ev 2026-06-10T10:01:00-07:00 spawn w-t-sk
ev 2026-06-10T10:01:01-07:00 skeptic-spawn w-t-sk ',"target-window":"w-t","orig-window":"w-t","depth":"0"'
ev 2026-06-10T11:00:00-07:00 wrap-up w-t-sk
ev 2026-06-10T12:00:00-07:00 paste-followup w-t-sk ',"rc":"0"'
snapshot w-t-sk
mkdir -p "$SD/skeptic/w-t"
# DONE written AFTER the 12:00 dispatch (touch -d pins it, not wall-clock).
: > "$SD/skeptic/w-t/DONE"; touch -d '2026-06-10T13:00:00-07:00' "$SD/skeptic/w-t/DONE"
resolve
expect_why w-t-sk NONE 'F6 skeptic dispatched, then pairing closed'
expect_log "worker 'w-t-sk': follow-up (dispatched) ENDED — the skeptic pairing on 'w-t' was closed" "F6: the close is logged as the reason"
# Control: the same DONE, OLDER than the dispatch — a previous round's close.
touch -d '2026-06-10T11:30:00-07:00' "$SD/skeptic/w-t/DONE"
resolve
expect_why w-t-sk 'follow-up:dispatched' 'F6 control: DONE older than the dispatch'
end_case

# --- F7: retired is never resurrected ----------------------------------------
echo '=== F7: window-close is terminal ==='
new_case f7
ev 2026-06-10T10:00:00-07:00 spawn w-ret
ev 2026-06-10T11:00:00-07:00 wrap-up w-ret
ev 2026-06-10T11:10:00-07:00 paste-followup w-ret ',"rc":"0"'
ev 2026-06-10T11:20:00-07:00 window-retain w-ret ',"reason":"hold"'
ev 2026-06-10T12:00:00-07:00 window-close w-ret ',"reason":"retire-window"'
ev 2026-06-10T10:00:00-07:00 spawn w-ret-active
ev 2026-06-10T12:00:00-07:00 window-close w-ret-active ',"reason":"retire-window"'
marker w-ret
mi w-ret 2026-06-10T12:30:00-07:00
request new w-ret
snapshot w-ret w-ret-active
resolve
expect_why w-ret        NONE 'F7 closed with every follow-up signal live'
expect_why w-ret-active NONE 'F7 closed straight from active'
# Re-spawned after a close: the new spawn is the latest lifecycle event.
ev 2026-06-10T13:00:00-07:00 spawn w-ret
resolve
expect_why w-ret active 'F7 re-spawned after close (the name is reusable)'
end_case

# --- F8: machine-input delivery ----------------------------------------------
echo '=== F8: a machine-input paste-followup stamp after the wrap-up ==='
new_case f8
ev 2026-06-10T10:00:00-07:00 spawn w-mi
ev 2026-06-10T11:00:00-07:00 wrap-up w-mi
ev 2026-06-10T10:00:00-07:00 spawn w-mi-old
ev 2026-06-10T11:00:00-07:00 wrap-up w-mi-old
ev 2026-06-10T10:00:00-07:00 spawn w-mi-kind
ev 2026-06-10T11:00:00-07:00 wrap-up w-mi-kind
mi w-mi      2026-06-10T12:00:00-07:00
mi w-mi-old  2026-06-10T10:30:00-07:00
mi w-mi-kind 2026-06-10T12:00:00-07:00 unstick-api-error
snapshot w-mi w-mi-old w-mi-kind
resolve
expect_why w-mi      'follow-up:delivered' 'F8 stamp after the wrap-up (e.g. ng send --stamp-only)'
expect_why w-mi-old  NONE 'F8 stamp before the wrap-up'
expect_why w-mi-kind NONE 'F8 a watcher wake is not a dispatch'
end_case

# --- F9: open spawn-skeptic request ------------------------------------------
echo '=== F9: an open spawn-skeptic request keeps its target ==='
new_case f9
ev 2026-06-10T10:00:00-07:00 spawn w-req
ev 2026-06-10T11:00:00-07:00 wrap-up w-req
ev 2026-06-10T10:00:00-07:00 spawn w-req-done
ev 2026-06-10T11:00:00-07:00 wrap-up w-req-done
ev 2026-06-10T10:00:00-07:00 spawn w-req-kind
ev 2026-06-10T11:00:00-07:00 wrap-up w-req-kind
request new  w-req
request done w-req-done
request new  w-req-kind question
snapshot w-req w-req-done w-req-kind
resolve
expect_why w-req      'follow-up:skeptic-requested' 'F9 open spawn-skeptic request'
expect_why w-req-done NONE 'F9 acked (.done) request'
expect_why w-req-kind NONE 'F9 open request of another kind'
end_case

# --- F10: fail direction -----------------------------------------------------
echo '=== F10: an unreadable source resumes; an absent one does not ==='
new_case f10
ev 2026-06-10T10:00:00-07:00 spawn w-u
ev 2026-06-10T11:00:00-07:00 wrap-up w-u
ev 2026-06-10T10:00:00-07:00 spawn w-act
snapshot w-u w-act
# Absent everything: skipped, no warning.
resolve
expect_why w-u NONE 'F10 absent machine-input / skeptic / requests'
if grep -q 'could not be read' <<<"$ERR"; then
    fail "F10: absent is not unreadable (no warning) — $(tr '\n' '|' <<<"$ERR")"
else
    pass "F10: absent is not unreadable (no warning)"
fi
mi w-other 2026-06-10T12:00:00-07:00
chmod 000 "$SD/machine-input.tsv"
resolve
expect_why w-u   'follow-up:unknown:machine-input' 'F10 unreadable machine-input'
expect_why w-act 'active' 'F10 the walk continued past the unreadable source'
expect_log 'machine-input ledger' 'F10: the unreadable ledger is logged loudly'
if (( RC == 0 )); then pass "F10: resolution exit 0"; else fail "F10: resolution exit 0 — rc=$RC"; fi
chmod 600 "$SD/machine-input.tsv"
mkdir -p "$SD/skeptic/pending"
chmod 000 "$SD/skeptic/pending"
resolve
expect_why w-u 'follow-up:unknown:skeptic-state' 'F10 unreadable skeptic state'
chmod 700 "$SD/skeptic/pending"
end_case

# --- F12: a non-terminal verdict whose round is still open -------------------
echo '=== F12: a check verdict keeps skeptic AND target until the round ends ==='
new_case f12
# pair <n> [verdict] — target w-t<n>, skeptic w-t<n>-sk, a verdict, both wrapped.
pair() {
    local t="w-t$1" sk="w-t$1-sk" v="${2:-check}"
    ev 2026-06-10T09:00:00-07:00 spawn "$t"
    ev 2026-06-10T10:00:00-07:00 wrap-up "$t"
    ev 2026-06-10T10:01:00-07:00 spawn "$sk"
    ev 2026-06-10T10:01:01-07:00 skeptic-spawn "$sk" ",\"target-window\":\"$t\",\"orig-window\":\"$t\",\"depth\":\"0\""
    ev 2026-06-10T11:00:00-07:00 skeptic-verdict "$sk" ",\"target-window\":\"$t\",\"orig-window\":\"$t\",\"verdict\":\"$v\""
    ev 2026-06-10T11:00:05-07:00 wrap-up "$sk"
}
pair 1                                                  # open: nothing else happened
pair 2; mkdir -p "$SD/skeptic/w-t2"; : > "$SD/skeptic/w-t2/DONE"
touch -d '2026-06-10T11:30:00-07:00' "$SD/skeptic/w-t2/DONE"   # ng skeptic close AFTER the verdict
pair 3 credible                                         # terminal verdict
# 4 and 5: the orchestrator clearing a MARKER is not the round ending. Measured:
# w215esk (2026-09-02) — resolve at 14:08, the next round dispatched at 16:13.
pair 4; ev 2026-06-10T11:30:00-07:00 skeptic-resolve w-x ',"task":"w-t4","scope":"marker"'
pair 5; ev 2026-06-10T11:30:00-07:00 skeptic-decision w-t5 ',"decision":"satisfied"'
pair 6; ev 2026-06-10T12:00:00-07:00 wrap-up w-t6       # the target DELIVERED its fix
pair 7; mkdir -p "$SD/skeptic/w-t7"; : > "$SD/skeptic/w-t7/DONE"
touch -d '2026-06-10T10:30:00-07:00' "$SD/skeptic/w-t7/DONE"   # a PREVIOUS round's close
pair 8 refuted
snapshot w-t1 w-t1-sk w-t2 w-t2-sk w-t3 w-t3-sk w-t4 w-t4-sk w-t5 w-t5-sk w-t6 w-t6-sk w-t7 w-t7-sk w-t8 w-t8-sk
resolve
expect_why w-t1-sk 'follow-up:skeptic-awaiting-fix' 'F12 open round: the skeptic owes the re-review'
expect_why w-t1    'follow-up:owes-delta'           'F12 open round: the target owes the fix'
expect_why w-t2-sk NONE 'F12 ng skeptic close after the verdict ends it (skeptic)'
expect_why w-t2    NONE 'F12 ng skeptic close after the verdict ends it (target)'
expect_why w-t3-sk NONE 'F12 a credible verdict is terminal (skeptic)'
expect_why w-t3    NONE 'F12 a credible verdict is terminal (target)'
expect_why w-t4-sk 'follow-up:skeptic-awaiting-fix' 'F12 ng skeptic resolve does NOT end the round (skeptic)'
expect_why w-t4    'follow-up:owes-delta' 'F12 ng skeptic resolve does NOT end the round (target)'
expect_why w-t5-sk 'follow-up:skeptic-awaiting-fix' 'F12 a satisfied decision does NOT end the round (skeptic)'
expect_why w-t5    'follow-up:owes-delta' 'F12 a satisfied decision does NOT end the round (target)'
expect_why w-t6    NONE 'F12 a wrap-up after the verdict is the delta delivered (target)'
expect_why w-t6-sk 'follow-up:skeptic-awaiting-fix' 'F12 …and the skeptic still owes the re-review'
expect_why w-t7-sk 'follow-up:skeptic-awaiting-fix' 'F12 control: a DONE older than the verdict is a previous round'
expect_why w-t8    'follow-up:owes-delta' 'F12 refuted is non-terminal too'
end_case

# --- F13: wrapped with no spawn record (skeptic F2 on #1666) ------------------
echo '=== F13: a wrap-up without a spawn record is no-record ==='
new_case f13
ev 2026-06-10T11:00:00-07:00 wrap-up w-nospawn
ev 2026-06-10T12:00:00-07:00 paste-followup w-nospawn ',"rc":"0"'
snapshot w-nospawn
resolve
expect_why w-nospawn NONE 'F13 wrapped + dispatched but never spawned'
expect_log "worker 'w-nospawn': no spawn record in action log" 'F13: logged as no-record'
end_case

# --- F14: names that extend one another (skeptic F3 on #1666) ------------------
echo '=== F14: a request or marker for w-pre-sk does not mark w-pre ==='
new_case f14
ev 2026-06-10T10:00:00-07:00 spawn w-pre
ev 2026-06-10T11:00:00-07:00 wrap-up w-pre
ev 2026-06-10T10:00:00-07:00 spawn w-pre-sk
ev 2026-06-10T11:00:00-07:00 wrap-up w-pre-sk
request new w-pre-sk
marker w-pre-skx
snapshot w-pre w-pre-sk
resolve
expect_why w-pre    NONE 'F14 a request naming a longer name does not mark the prefix'
expect_why w-pre-sk 'follow-up:skeptic-requested' 'F14 …while it does mark its own window'
end_case

# --- F15: the LATEST verdict wins; a longer target name is not the target ----
# Skeptic F4/F5 on #1666 round 2: every F12 pair had exactly one verdict, and no
# verdict targeted a name extending another's (the real ledger has 100 such
# prefix-colliding pairs among 695 verdict targets, e.g. bundler/bundler2).
echo '=== F15: check-then-credible ends the round; w-x is not w-xsk ==='
new_case f15
ev 2026-06-10T09:00:00-07:00 spawn w-cc
ev 2026-06-10T10:00:00-07:00 wrap-up w-cc
ev 2026-06-10T10:01:00-07:00 spawn w-cc-sk
ev 2026-06-10T10:01:01-07:00 skeptic-spawn w-cc-sk ',"target-window":"w-cc","orig-window":"w-cc","depth":"0"'
ev 2026-06-10T11:00:00-07:00 skeptic-verdict w-cc-sk ',"target-window":"w-cc","orig-window":"w-cc","verdict":"check"'
ev 2026-06-10T12:00:00-07:00 skeptic-verdict w-cc-sk ',"target-window":"w-cc","orig-window":"w-cc","verdict":"credible"'
ev 2026-06-10T12:00:05-07:00 wrap-up w-cc-sk
ev 2026-06-10T09:00:00-07:00 spawn w-x
ev 2026-06-10T10:00:00-07:00 wrap-up w-x
ev 2026-06-10T09:00:00-07:00 spawn w-xsk
ev 2026-06-10T10:00:00-07:00 wrap-up w-xsk
ev 2026-06-10T11:00:00-07:00 skeptic-verdict w-other-sk ',"target-window":"w-xsk","orig-window":"w-xsk","verdict":"check"'
snapshot w-cc w-cc-sk w-x w-xsk
resolve
expect_why w-cc-sk NONE 'F15 check then credible: the LATEST verdict ends the round (skeptic)'
expect_why w-cc    NONE 'F15 check then credible: the LATEST verdict ends the round (target)'
expect_why w-x     NONE 'F15 a verdict targeting w-xsk does not make w-x owe a delta'
expect_why w-xsk   'follow-up:owes-delta' 'F15 …while w-xsk itself does owe it'
end_case

# --- F11: active and engaged keep their own why ------------------------------
echo '=== F11: an active window keeps its why ==='
new_case f11
ev 2026-06-10T10:00:00-07:00 spawn w-a
ev 2026-06-10T11:00:00-07:00 paste-followup w-a ',"rc":"0"'
snapshot w-a
resolve
expect_why w-a active 'F11 active (a paste to an unwrapped window changes nothing)'
end_case

# EXACT: every case above runs unconditionally, so a lost or skipped assertion
# is a defect in the suite, not a variation.
EXPECTED_ASSERTIONS=65
if (( PASS + FAIL != EXPECTED_ASSERTIONS )); then
    fail "assertion total — ran $(( PASS + FAIL )), EXPECTED_ASSERTIONS=$EXPECTED_ASSERTIONS"
fi
th_summary_and_exit
