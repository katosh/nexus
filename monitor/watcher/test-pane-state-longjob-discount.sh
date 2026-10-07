#!/usr/bin/env bash
# monitor/watcher/test-pane-state-longjob-discount.sh — the always-armed
# longjob-watch dispatcher must not freeze window cleanup board-wide
# (your-org/nexus-code#1535), and the launch hook must auto-arm a watch.
#
# THE HAZARD, measured: with the dispatcher plugin armed, every idle session's
# footer reads `· 1 monitor ·`, and pane-state.sh classifies any Monitor handle
# as `working-background` — NEVER aged out, never kill-authorised. Left alone,
# no worker would ever be retired again. The fixture is the REAL capture of
# that state (2.1.272, hermetic control C0), read here under FOUR ledger
# conditions that vary ONE axis each:
#
#   bare (no heartbeat)                       → working-background   (manifest row)
#   fresh ledger, active=0                    → idle                 (THE discount)
#   fresh ledger, active=1                    → working-background   (parked on a watch)
#   STALE ledger (last_poll old), active=0    → working-background   (a stopped
#                                                dispatcher is not one with nothing to say)
#   fresh ledger, active=0, footer `2 monitor`→ working-background   (the discount is ≤ 1)
#
# The heartbeat's session_id keys the ledger (sid-<id>); a window-keyed
# fallback (win-<name>) is asserted too. POTENCY: the fresh/active=0 row is the
# positive control for the reader; the stale row differs from it by ONE field.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
PS="$REPO_ROOT/monitor/pane-state.sh"
FIX="$_test_dir/fixtures/idle-longjob-dispatcher-armed-realmodel-272.ansi"
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
WORK=$(mktemp -d -t lj-disc-XXXXXX); trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/state"; mkdir -p "$NEXUS_STATE_DIR/heartbeat"
[[ -f "$FIX" ]] || { echo "  FAIL: fixture missing: $FIX" >&2; exit 1; }
grep -q '1 monitor' "$FIX" && ok "fixture carries the '1 monitor' footer (the capture is the case under test)" || bad "fixture has no monitor footer"

NOW=1789600000
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
HB="$NEXUS_STATE_DIR/heartbeat/ljw.json"
jq -n --arg s "$SID" --argjson now "$NOW" '{window:"ljw", session_id:$s, state:"idle", last_activity:$now, external_waits:[]}' > "$HB"
MYST=$(awk '{print $22}' /proc/$$/stat)
ledger() {   # <key> <last_poll> <active> [<pid> <pid_start> <window> <service> <muted>]
    # Defaults to THIS suite's own live pid + kernel start-time, so the liveness
    # gate (skeptic F2) is satisfied by a real process, never by a planted number.
    mkdir -p "$NEXUS_STATE_DIR/longjob/$1"
    jq -n --argjson lp "$2" --argjson a "$3" --argjson pid "${4:-$$}" --arg ps "${5:-$MYST}" --arg w "${6:-ljw}" --arg svc "${7:-polling}" --argjson mu "${8:-0}" \
        '{version:2, pid:$pid, pid_start:$ps, last_poll:$lp, poll_seconds:20, service:$svc, active:$a, muted:$mu, window:$w}' > "$NEXUS_STATE_DIR/longjob/$1/dispatcher.json"
    rm -rf "$NEXUS_STATE_DIR/longjob/$1/watches"; mkdir -p "$NEXUS_STATE_DIR/longjob/$1/watches"
}
spec() {   # <key> <id> <retired:true|false> — a watch spec in the spool, the honest source of `active`
    jq -n --arg id "$2" --argjson r "$3" '{id:$id, kind:"cmd", target:"exit 1", retired:$r, state:"running"}' > "$NEXUS_STATE_DIR/longjob/$1/watches/$2.json"
}
state_of() { "$PS" --fixture "$FIX" --name ljw --heartbeat-file "$HB" --now "$NOW" --heartbeat-staleness 100000 --heartbeat-turn-end-staleness 100000 --heartbeat-async-staleness 100000 "$@" 2>/dev/null | sed -n 's/^state=\([^ ]*\).*/\1/p' | head -1; }

echo "=== bare: no ledger at all → the handle is real ==="
[[ "$(state_of)" == working-background ]] && ok "no ledger → working-background (fail-safe: keep the handle)" || bad "no ledger: $(state_of)"

echo "=== fresh ledger, active=0 → idle (THE discount) ==="
ledger "sid-$SID" $(( NOW - 10 )) 0
[[ "$(state_of)" == idle ]] && ok "fresh ledger, 0 active watches → idle (the dispatcher's own handle discounted)" || bad "discount: $(state_of)"

echo "=== fresh ledger, a LIVE watch in the spool → working-background (parked on a watch) ==="
ledger "sid-$SID" $(( NOW - 10 )) 1; spec "sid-$SID" j1 false
[[ "$(state_of)" == working-background ]] && ok "1 live watch → working-background (a self-waking wait; never retire it)" || bad "active=1: $(state_of)"
echo "=== C2: the ledger's CACHED active=0 with a live watch in the spool must NOT discount ==="
ledger "sid-$SID" $(( NOW - 10 )) 0; spec "sid-$SID" j1 false
[[ "$(state_of)" == working-background ]] && ok "C2: ledger says active=0 (published by the last pass) but the spool holds a live watch → working-background (the verb counts the spool)" || bad "C2: $(state_of)"
ledger "sid-$SID" $(( NOW - 10 )) 0; spec "sid-$SID" j1 true
[[ "$(state_of)" == idle ]] && ok "C2 control: the same spool with the watch RETIRED → idle" || bad "C2 control: $(state_of)"
echo "=== C1: a fresh, live, NOT-SERVING ledger (kill switch) must NOT discount ==="
ledger "sid-$SID" $(( NOW - 10 )) 0 $$ "$MYST" ljw disabled
[[ "$(state_of)" == working-background ]] && ok "C1: service=disabled → NOT discounted (a handle the dispatcher is not accounting for stays a handle)" || bad "C1: $(state_of)"

echo "=== #1638: a MUTED dispatcher with ZERO live watches holds nothing → idle ==="
# `muted` is reached only after the live/owned/fresh/serving tests pass, so a
# muted dispatcher is an armed one whose event cap is spent. Pre-fix only the
# literal `armed` was discounted, so this pane read working-background for ever
# and retire-window refused a finished worker (16 h, nichecompass).
# PREDICTED FLIP for "discount only `armed`": the first row goes
# working-background; the two controls below it do not move.
ledger "sid-$SID" $(( NOW - 10 )) 0 $$ "$MYST" ljw polling 1
[[ "$(state_of)" == idle ]] && ok "#1638: muted, 0 active watches → idle (same as armed, 0 active)" || bad "#1638 muted/0: $(state_of)"
ledger "sid-$SID" $(( NOW - 10 )) 1 $$ "$MYST" ljw polling 1; spec "sid-$SID" j1 false
[[ "$(state_of)" == working-background ]] && ok "#1638 control: muted WITH a live watch → working-background (not discounted; a muted watch wakes nobody, so it is not the armed self-waking hold either)" || bad "#1638 muted/1: $(state_of)"
ledger "sid-$SID" $(( NOW - 10000 )) 0 $$ "$MYST" ljw polling 1
[[ "$(state_of)" == working-background ]] && ok "#1638 control: a STALE ledger with muted=1 reads stale, not muted → NOT discounted" || bad "#1638 muted stale: $(state_of)"

echo "=== stale ledger, active=0 → working-background (a stopped dispatcher is not silence) ==="
ledger "sid-$SID" $(( NOW - 10000 )) 0
[[ "$(state_of)" == working-background ]] && ok "stale ledger (10 000 s) → NOT discounted" || bad "stale: $(state_of)"
ledger "sid-$SID" $(( NOW - 91 )) 0
[[ "$(state_of)" == working-background ]] && ok "ledger 91 s old (> 3×20+30) → NOT discounted (the boundary)" || bad "boundary 91: $(state_of)"
ledger "sid-$SID" $(( NOW - 89 )) 0
[[ "$(state_of)" == idle ]] && ok "ledger 89 s old (≤ 90) → discounted (the boundary's other side)" || bad "boundary 89: $(state_of)"

echo "=== F2: a FRESH ledger whose pid is DEAD must NOT discount (kill-decision input) ==="
ledger "sid-$SID" $(( NOW - 10 )) 0 999999 "1"
[[ "$(state_of)" == working-background ]] && ok "F2: fresh ledger, dead pid → working-background (status would say dead; the discount agrees)" || bad "F2 dead pid: $(state_of)"
ledger "sid-$SID" $(( NOW - 10 )) 0 $$ "424242"
[[ "$(state_of)" == working-background ]] && ok "F2: live pid with a MISMATCHED start-time (recycled) → NOT discounted" || bad "F2 recycled: $(state_of)"
ledger "sid-$SID" $(( NOW - 10 )) 0
[[ "$(state_of)" == idle ]] && ok "F2 control: the same ledger with the live pid + real start-time → idle" || bad "F2 control: $(state_of)"

echo "=== window-keyed fallback when the heartbeat carries no session_id ==="
rm -rf "$NEXUS_STATE_DIR/longjob/sid-$SID"
jq -n --argjson now "$NOW" '{window:"ljw", state:"idle", last_activity:$now, external_waits:[]}' > "$HB"
ledger "win-ljw" $(( NOW - 10 )) 0
[[ "$(state_of)" == idle ]] && ok "no session_id in the heartbeat → win-<name> ledger consulted → idle" || bad "win fallback: $(state_of)"
ledger "win-ljw" $(( NOW - 10 )) 0 $$ "$MYST" "other-window"
[[ "$(state_of)" == working-background ]] && ok "F2: a win- ledger naming ANOTHER window (a foreign dispatcher's file) → NOT discounted" || bad "F2 foreign: $(state_of)"
ledger "win-ljw" $(( NOW - 10 )) 0

echo "=== #1542: the win- key is ENCODED by its writer, so the reader must encode it too ==="
# longjob-watch.sh writes the spool under `win-$(_wk_encode "$win")`; pane-state
# read `win-$win` RAW. For a name inside [A-Za-z0-9_-] the two agree, which is
# why every case above passed and why it never fired on the board. PREDICTED FLIP
# for "revert the reader to the raw key": the first row goes working-background;
# the two controls do not move.
jq -n --argjson now "$NOW" '{window:"lj.w", state:"idle", last_activity:$now, external_waits:[]}' > "$HB"
rm -rf "$NEXUS_STATE_DIR/longjob"
ledger "win-lj%2Ew" $(( NOW - 10 )) 0 $$ "$MYST" "lj.w"
[[ "$(state_of)" == idle ]] && ok "#1542: window 'lj.w', no session_id → the ledger under the ENCODED key win-lj%2Ew is found → idle" || bad "#1542 encoded key: $(state_of)"
rm -rf "$NEXUS_STATE_DIR/longjob"
ledger "win-lj.w" $(( NOW - 10 )) 0 $$ "$MYST" "lj.w"
[[ "$(state_of)" == working-background ]] && ok "#1542 control: a ledger under the RAW spelling is one no writer produces → NOT discounted (one spelling, the writer's)" || bad "#1542 raw key: $(state_of)"
rm -rf "$NEXUS_STATE_DIR/longjob"
ledger "win-lj%2Ew" $(( NOW - 10 )) 0 $$ "$MYST" "other"
[[ "$(state_of)" == working-background ]] && ok "#1542 control: the encoded key still must NAME this window (a foreign dispatcher's file is not ours)" || bad "#1542 foreign under encoded key: $(state_of)"
rm -rf "$NEXUS_STATE_DIR/longjob"
jq -n --argjson now "$NOW" '{window:"ljw", state:"idle", last_activity:$now, external_waits:[]}' > "$HB"
ledger "win-ljw" $(( NOW - 10 )) 0

echo "=== the discount is at most ONE handle ==="
sed 's/1 monitor/2 monitor/g' "$FIX" > "$WORK/two.ansi"
out=$("$PS" --fixture "$WORK/two.ansi" --name ljw --heartbeat-file "$HB" --now "$NOW" --heartbeat-staleness 100000 --heartbeat-turn-end-staleness 100000 --heartbeat-async-staleness 100000 2>/dev/null | sed -n 's/^state=\([^ ]*\).*/\1/p' | head -1)
[[ "$out" == working-background ]] && ok "'2 monitor' with an idle dispatcher → working-background (one real handle remains)" || bad "two handles: $out"

echo "=== an unreadable ledger is not a discount ==="
printf 'not json' > "$NEXUS_STATE_DIR/longjob/win-ljw/dispatcher.json"
[[ "$(state_of)" == working-background ]] && ok "corrupt ledger → NOT discounted" || bad "corrupt: $(state_of)"

echo "=== the PROCESS-TREE channel: the dispatcher's root is EXCLUDED from the census (bundle-2609 S3; sk2 F1, F2) ==="
# THE HAZARD THE FIXTURE COULD NOT SEE: the fixture is a pane CAPTURE, so every
# case above exercised the FOOTER channel only. Live, the host launches the
# plugin monitor as `zsh -c … bash dispatch.sh` — a real shell child of claude —
# and the process tree is AUTHORITATIVE over the footer, so an idle pane read
# `working-background bg_shells=1 bg_reliable=1` with the footer discount in
# place (bundle-2609 live soak). The first repair subtracted ONE from the count
# and left the root in the census, so every other bg_* field described the
# dispatcher (sk2 F1: idle-probe case b0 lost, cc-update quiescence lost, the
# #1460 wedge detector blinded by a churning member set). The census now
# leaves the dispatcher's root subtree out at the source.
#
# THE TREES ARE REAL AND CARRY THE PRODUCTION SHAPE (sk2): a copy of bash named
# `claude` → a WRAPPER shell → the dispatcher bash (the ledger's pid, a
# GRANDCHILD) → a `sleep` it re-forks every second, so membership churns the
# way a polling dispatcher's does. Every case states what it predicts; the
# potency run against the pre-fix pane-state.sh is recorded in the commit.
jq -n --arg s "$SID" --argjson now "$NOW" '{window:"ljw", session_id:$s, state:"idle", last_activity:$now, external_waits:[]}' > "$HB"
rm -rf "$NEXUS_STATE_DIR/longjob"
_pt_ok=0; _pt_h_dir="$WORK/hbin"; mkdir -p "$_pt_h_dir"; _PT_ROOTS=()
# BOTTOM-UP: a parent killed first reparents its children to init, out of reach —
# and out of reach for good: a foreground tool call is its own session, so what
# it orphans is refused by proc-kill-authorized as not-owned (your-org/nexus-code#1543).
# FROZEN FIRST, top-down: a poll loop that is merely killed bottom-up re-forks a
# child between the walk and its own kill (the real dispatcher below forks a
# `sleep` per poll); a STOPPED process cannot fork, so the second walk is
# complete. SIGKILL, because a stopped process does not act on SIGTERM.
_pt_tree() { local p="$1" k; printf '%s\n' "$p"; for k in $(pgrep -P "$p" 2>/dev/null); do _pt_tree "$k"; done; }
_pt_killtree() {
    local p
    for p in $(_pt_tree "$1"); do kill -STOP "$p" 2>/dev/null; done
    for p in $(_pt_tree "$1" | tac); do kill -KILL "$p" 2>/dev/null; done
    wait "$1" 2>/dev/null
}
_pt_cleanup() { local p; for p in "${_PT_ROOTS[@]:-}"; do [[ -n "$p" ]] && _pt_killtree "$p"; done; }
trap 'declare -F _pt_cleanup >/dev/null && _pt_cleanup; rm -rf "$WORK"' EXIT
_pt_st() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
_pt_field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$1"; }
_PT_DISP='bash -c "bash -c \"while :; do sleep 1; done\" ; true"'
_pt_spawn() {   # <script for the fake claude> → sets _pt_claude
    "$_pt_h_dir/claude" -c "$1" >/dev/null 2>&1 &
    _pt_claude=$!; _PT_ROOTS+=("$_pt_claude")
}
# EXTENDING THIS FILE? Read a /proc file INSIDE A BRACE GROUP that carries the suppression:
#     $( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null )
# Redirections run left to right, so in the obvious spelling (the `<` first, `2>/dev/null` last) a pid
# that vanished mid-walk prints the very `No such file` diagnostic the suppression was meant to catch
# (your-org/nexus-code#1305). The grouped form is this repo's standard because it is ORDER-INDEPENDENT:
# "put 2>/dev/null first" is a rule somebody can get backwards, a brace group cannot be written in the
# wrong order. This file grew four leaking sites BY IMITATION — two from the bundle that created it, two
# from the next author copying them — and `test-proc-redirect-order.sh` is a ratchet on the construct:
# it counts instances and cannot tell you what to write. This note can.
_pt_find_disp() {   # <claude pid> → the INNER dispatcher bash: a grandchild, under a wrapper shell
    local w d i
    for i in $(seq 1 80); do
        for w in $(pgrep -P "$1" -x bash 2>/dev/null); do
            for d in $(pgrep -P "$w" -x bash 2>/dev/null); do
                [[ "$( { tr '\0' ' ' < "/proc/$d/cmdline"; } 2>/dev/null )" == *"sleep 1;"* ]] && { printf '%s' "$d"; return 0; }
            done
        done
        sleep 0.25
    done
    return 1
}
_pt_run() {   # <pane pid> [extra pane-state args…]
    local pp="$1"; shift
    "$PS" --fixture "${_PT_FIX:-$FIX}" --name ljw --heartbeat-file "$HB" --now "$NOW" --heartbeat-staleness 100000 --heartbeat-turn-end-staleness 100000 --heartbeat-async-staleness 100000 --pane-pid "$pp" "$@" 2>&1
}
if command -v pgrep >/dev/null 2>&1 && [[ -r /proc/$$/stat ]] && cp "$(command -v bash)" "$_pt_h_dir/claude" 2>/dev/null; then
    _pt_spawn "$_PT_DISP & sleep 240"; _pt_c1="$_pt_claude"
    _pt_d1=$(_pt_find_disp "$_pt_c1") && _pt_ok=1
fi
if (( _pt_ok == 1 )); then
    _pt_s1=$(_pt_st "$_pt_d1")
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=working-background* && "$out" == *"bg_shells=1"* && "$out" == *"bg_reliable=1"* && "$out" == *"bg_longjob=0"* ]] \
        && ok "K0 control: no ledger → working-background bg_shells=1 bg_reliable=1 bg_longjob=0 (the tree is authoritative; the wrapper is a real counted root)" \
        || bad "K0 control: $out"
    ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d1" "$_pt_s1"
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=idle* ]] && ok "K1 PRODUCTION SHAPE: the ledger names the GRANDCHILD dispatcher (pid + start ticks), armed, 0 active → idle" || bad "K1: $out"
    # #1546 (sk3 N1): THE VERDICT MUST NOT DESTROY THE EVIDENCE THAT PRODUCED IT.
    # This `idle` exists BECAUSE a root was excluded, and the line said nothing.
    [[ "$out" == state=idle* && "$out" == *" bg_longjob=1"* && "$out" != *"bg_shells="* && "$out" != *"bg_cpu="* ]] \
        && ok "#1546: the idle line the exclusion DECIDED carries bg_longjob=1 — and no bg_shells=/bg_cpu= (nothing for a reader keyed on those to select)" \
        || bad "#1546 idle record: $out"
    ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d1" "$_pt_s1" ljw polling 1
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=idle* && "$out" == *" bg_longjob=1"* ]] \
        && ok "#1638 PRODUCTION SHAPE: the same grandchild dispatcher MUTED with 0 active → its root excluded from the census → idle bg_longjob=1" \
        || bad "#1638 tree muted/0: $out"
    ledger "sid-$SID" $(( NOW - 10 )) 0 "$$" "$MYST"
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=working-background* && "$out" == *"bg_shells=1"* && "$out" == *"bg_longjob=0"* ]] \
        && ok "identity: a LIVE, armed dispatcher that is NOT in this pane's tree → nothing excluded → working-background bg_shells=1 bg_longjob=0" \
        || bad "identity (outside): $out"
    ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d1" "$(( _pt_s1 + 1 ))"
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=working-background* && "$out" == *"bg_longjob=0"* ]] && ok "identity: the right pid with the WRONG start ticks (recycled) → nothing excluded → working-background" || bad "identity (ticks): $out"
    ledger "sid-$SID" $(( NOW - 10000 )) 0 "$_pt_d1" "$_pt_s1"
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=working-background* && "$out" == *"bg_shells=1"* && "$out" == *"bg_longjob=0"* ]] \
        && ok "a STALE ledger (dispatcher stopped polling) → NOT excluded: a stopped dispatcher stays a counted shell" \
        || bad "stale not excluded: $out"
    echo "--- a LIVE watch: held as a self-waking Monitor-style wait, never as a grace-capped shell ---"
    ledger "sid-$SID" $(( NOW - 10 )) 1 "$_pt_d1" "$_pt_s1"; spec "sid-$SID" j1 false
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=working-background* && "$out" != *"bg_shells="* && "$out" != *"bg_cpu="* ]] \
        && ok "active>0: working-background with NO bg_shells/bg_cpu on the line — the idle probe never ages a Monitor-style wait out (pre-fix: bg_shells=1 bg_cpu=…, the shell grace cap)" \
        || bad "active>0 semantics: $out"
    [[ "$out" == *" bg_longjob=1"* && "$out" == *" bg_longjob_watches=1"* ]] \
        && ok "#1546: the Monitor-held line records the excluded root AND the live-watch count holding it (bg_longjob=1 bg_longjob_watches=1)" \
        || bad "#1546 monitor-held record: $out"
    # The READER AUDIT for this line is executed further down, inside rig 2, where
    # both production readers are ALREADY lifted by name — a second lift here would
    # add two process-substitution `source` tokens that
    # test-ambient-shell-option-scope.sh cannot resolve, and its manifest is a ratchet.
    _1546_mon_line="$out"
    sed 's/1 monitor//g' "$FIX" > "$WORK/nofoot.ansi"
    out=$(_PT_FIX="$WORK/nofoot.ansi" _pt_run "$_pt_c1")
    [[ "$out" == state=working-background* && "$out" != *"bg_shells="* ]] \
        && ok "active>0 with the footer UNREADABLE: the armed ledger holds the pane on its own (the footer is the fragile channel)" \
        || bad "active>0, no footer: $out"
    rm -rf "$NEXUS_STATE_DIR/longjob/sid-$SID/watches"; mkdir -p "$NEXUS_STATE_DIR/longjob/sid-$SID/watches"
    ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d1" "$_pt_s1"
    out=$(_PT_FIX="$WORK/nofoot.ansi" _pt_run "$_pt_c1")
    [[ "$out" == state=idle* ]] && ok "control: the same no-footer pane with 0 active → idle (the hold is the watch, not the dispatcher)" || bad "no footer, 0 active: $out"

    echo "--- K2: the exclusion never removes a REAL root ---"
    _pt_spawn "$_PT_DISP & bash -c 'while :; do sleep 30; done' & sleep 240"; _pt_c2="$_pt_claude"
    _pt_d2=$(_pt_find_disp "$_pt_c2"); ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d2" "$(_pt_st "$_pt_d2")"
    out=$(_pt_run "$_pt_c2")
    [[ "$out" == state=working-background* && "$out" == *"bg_shells=1 "* && "$out" == *"bg_longjob=1"* && "$(_pt_field "$out" bg_cmd)" == *sleep_30* ]] \
        && ok "K2: dispatcher + ONE real shell → working-background bg_shells=1 (the real one) bg_longjob=1, and bg_cmd NAMES the real shell" \
        || bad "K2: $out"
    [[ "$out" == state=working-background* && "$out" != *"bg_longjob_kept="* ]] \
        && ok "#1627 control: the real shell kept beside an EXCLUDED dispatcher is not a dispatcher → no bg_longjob_kept" \
        || bad "#1627 K2 control: $out"

    echo "--- K3: a STATIC real shell beside the churning dispatcher reads STATIC (#1460) ---"
    mkfifo "$WORK/fifo"
    _pt_spawn "$_PT_DISP & bash -c 'read x < $WORK/fifo; true' & sleep 240"; _pt_c3="$_pt_claude"
    _pt_d3=$(_pt_find_disp "$_pt_c3"); ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d3" "$(_pt_st "$_pt_d3")"
    a=$(_pt_run "$_pt_c3"); sleep 2.5; b=$(_pt_run "$_pt_c3")
    # The digest is per-run, so it rides on a note, never in the label (#1574:
    # a label that changes between runs re-pairs cases in mutation-gate).
    printf '  note: K3 bg_members digest %s\n' "$(_pt_field "$a" bg_members)"
    [[ "$a" == *"bg_shells=1 "* && -n "$(_pt_field "$a" bg_members)" && "$(_pt_field "$a" bg_members)" == "$(_pt_field "$b" bg_members)" ]] \
        && ok "K3: bg_members identical across two samples 2.5 s apart — the dispatcher's per-poll sleep is not a member (pre-fix: CHANGED every sample)" \
        || bad "K3 members: '$(_pt_field "$a" bg_members)' vs '$(_pt_field "$b" bg_members)' | $a"
    [[ "$(_pt_field "$a" bg_cmd)" == *read_x* ]] && ok "K3: bg_cmd names the blocked shell, not the dispatcher" || bad "K3 bg_cmd: $(_pt_field "$a" bg_cmd)"

    echo "--- rig 2: a parked protocol await + the idle dispatcher, and the two consumers lifted BY NAME ---"
    # The fake await sleeps 60 s, as a real one polls: two samples 2.5 s apart must not straddle a re-fork.
    mkdir -p "$WORK/monitor"; printf '#!/usr/bin/env bash\nwhile :; do sleep 60; done\n' > "$WORK/monitor/skeptic-channel.sh"; chmod +x "$WORK/monitor/skeptic-channel.sh"
    _PT_AWAIT="bash -c \"source /dev/null && eval '$WORK/monitor/skeptic-channel.sh await ljw' < /dev/null && pwd\""
    _pt_spawn "$_PT_DISP & $_PT_AWAIT & sleep 240"; _pt_c4="$_pt_claude"
    _pt_d4=$(_pt_find_disp "$_pt_c4"); ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d4" "$(_pt_st "$_pt_d4")"
    sleep 1; a=$(_pt_run "$_pt_c4"); sleep 2.5; b=$(_pt_run "$_pt_c4")
    [[ "$a" == state=working-background* && "$a" == *"bg_shells=1 "* && "$a" == *"bg_infra=1 "* && "$a" == *"bg_quiesce=1"* && "$a" == *"bg_longjob=1"* ]] \
        && ok "rig 2: await + idle dispatcher → bg_shells=1 bg_infra=1 bg_quiesce=1 bg_longjob=1 (pre-fix: bg_shells=2)" \
        || bad "rig 2 line: $a"
    # The label is TRUNCATED to a fixed width, so no substring of the await's PATH survives every
    # $WORK length (sk3 F2: two attempts at one each failed — under run-tests.sh's TMPDIR, then under a
    # 152-byte scratch TMPDIR). Assert what the case is ABOUT instead: the label is present, is not the
    # dispatcher's loop, and EQUALS the label of a no-dispatcher CONTROL — the same await, same $WORK,
    # taken in this rig — so whatever the cut leaves, it is the await's.
    _pt_spawn "$_PT_AWAIT & sleep 240"; _pt_c4c="$_pt_claude"
    for _i in $(seq 1 40); do ctl=$(_pt_run "$_pt_c4c"); [[ "$ctl" == *"bg_infra=1 "* ]] && break; sleep 0.25; done
    _cmd_a=$(_pt_field "$a" bg_cmd); _cmd_c=$(_pt_field "$ctl" bg_cmd)
    [[ -n "$_cmd_a" && "$_cmd_a" != "-" && "$_cmd_a" != *sleep_1* && "$_cmd_a" == "$_cmd_c" ]] \
        && ok "rig 2: bg_cmd is the AWAIT's label (equal to the no-dispatcher control's), not the dispatcher's loop" \
        || bad "rig 2 bg_cmd: subject='$_cmd_a' control='$_cmd_c'"
    [[ -n "$(_pt_field "$a" bg_members)" && "$(_pt_field "$a" bg_members)" == "$(_pt_field "$b" bg_members)" ]] && ok "rig 2: membership STATIC across two samples" || bad "rig 2 members: $(_pt_field "$a" bg_members) vs $(_pt_field "$b" bg_members)"
    # shellcheck disable=SC1090
    source <(sed -n '/^_restart_line_field() {/,/^}/p;/^_restart_bg_all_quiescent() {/,/^}/p' "$REPO_ROOT/monitor/cc-auto-update-apply.sh")
    # shellcheck disable=SC1090
    source <(sed -n '/^_idle_pane_line_field() {/,/^}/p' "$REPO_ROOT/monitor/watcher/_idle_probe.sh")
    if declare -F _restart_bg_all_quiescent >/dev/null && declare -F _idle_pane_line_field >/dev/null; then
        rc=0; _restart_bg_all_quiescent "$a" || rc=$?
        (( rc == 0 )) && ok "rig 2: cc-update's _restart_bg_all_quiescent (lifted by name) → rc 0, restart-eligible (pre-fix: rc 1)" || bad "rig 2 quiescent rc=$rc"
        _sh=$(_idle_pane_line_field "$a" bg_shells); _inf=$(_idle_pane_line_field "$a" bg_infra)
        [[ "$_sh" =~ ^[0-9]+$ && "$_inf" =~ ^[0-9]+$ ]] && (( _sh - _inf <= 0 )) && (( _inf >= 1 )) \
            && ok "rig 2: the idle probe's case (b0) predicate holds — task_shells = $_sh − $_inf ≤ 0 with infra ≥ 1, read through its own _idle_pane_line_field" \
            || bad "rig 2 b0: bg_shells=$_sh bg_infra=$_inf"
        # #1546 READER AUDIT, EXECUTED on the Monitor-held line captured above:
        # cc-update separates the Monitor flavour from the shell flavour by the
        # PRESENCE of `bg_cpu=`, and both readers take `active=` — one of them
        # unanchored and greedy, so a field ENDING in `active=` would silently
        # become the window-active flag.
        [[ "$(_restart_line_field "$_1546_mon_line" active)" == 0 && "$(_idle_pane_line_field "$_1546_mon_line" active)" == 0 ]] \
            && ok "#1546: both production readers still read the WINDOW's active=0 off the Monitor-held line (the new field does not end in 'active=')" \
            || bad "#1546 active= reader: restart='$(_restart_line_field "$_1546_mon_line" active)' idle-probe='$(_idle_pane_line_field "$_1546_mon_line" active)' | $_1546_mon_line"
        [[ -z "$(_idle_pane_line_field "$_1546_mon_line" bg_shells)" && -z "$(_restart_line_field "$_1546_mon_line" bg_cpu)" ]] \
            && ok "#1546: …and neither reads a bg_shells or a bg_cpu off it" \
            || bad "#1546 bg readers: $_1546_mon_line"
    else
        bad "rig 2: a consumer function could not be lifted by name (renamed?) — the two assertions above it AND the #1546 reader audit did not run"
    fi

    echo "--- K4 (sk2 F2): the root must be a shell BELOW claude; a launcher shell ABOVE claude vouches for nothing ---"
    bash -c "bash -c '$_pt_h_dir/claude -c \"sleep 300 & bash -c \\\"while :; do sleep 30; done\\\" & sleep 240\" & wait' & wait" >/dev/null 2>&1 &
    _pt_p4=$!; _PT_ROOTS+=("$_pt_p4"); _pt_l4=""; _pt_c5=""; _pt_s4=""
    for _i in $(seq 1 80); do
        _pt_l4=$(pgrep -n -P "$_pt_p4" 2>/dev/null); [[ -n "$_pt_l4" ]] && _pt_c5=$(pgrep -n -P "$_pt_l4" -x claude 2>/dev/null)
        if [[ -n "$_pt_c5" ]]; then
            for _k in $(pgrep -P "$_pt_c5" -x sleep 2>/dev/null); do [[ "$( { tr '\0' ' ' < "/proc/$_k/cmdline"; } 2>/dev/null )" == "sleep 300 " ]] && _pt_s4="$_k"; done
        fi
        [[ -n "$_pt_s4" ]] && break; sleep 0.25
    done
    if [[ -n "$_pt_s4" ]]; then
        ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_s4" "$(_pt_st "$_pt_s4")"
        out=$(_pt_run "$_pt_p4")
        [[ "$out" == state=working-background* && "$out" == *"bg_shells=1"* && "$out" == *"bg_longjob=0"* ]] \
            && ok "K4: a NON-shell 'dispatcher' directly under claude, a launcher shell above claude, a real shell beside it → working-background bg_shells=1 (pre-fix: idle over the real shell)" \
            || bad "K4: $out"
    else
        bad "K4: the rig did not come up (pane=$_pt_p4 launcher=$_pt_l4 claude=$_pt_c5) — the F2 case is unmeasured"
    fi
    echo "--- #1547 (sk3 D3): hop 1 is the DISPATCHER, and the dispatcher is a SHELL ---"
    # A ledger pid that is not a shell — what a dispatcher that EXEC'd into
    # something else would look like (pid and ticks kept). PREDICTED FLIP for
    # "delete the hop-1 shell check": this row goes `idle`; nothing else moves.
    _pt_spawn "bash -c 'sleep 300; true' & sleep 240"; _pt_c6="$_pt_claude"; _pt_x6=""
    for _i in $(seq 1 80); do
        for _w in $(pgrep -P "$_pt_c6" -x bash 2>/dev/null); do
            for _k in $(pgrep -P "$_w" -x sleep 2>/dev/null); do [[ "$( { tr '\0' ' ' < "/proc/$_k/cmdline"; } 2>/dev/null )" == "sleep 300 " ]] && _pt_x6="$_k"; done
        done
        [[ -n "$_pt_x6" ]] && break; sleep 0.25
    done
    if [[ -n "$_pt_x6" ]]; then
        ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_x6" "$(_pt_st "$_pt_x6")"
        out=$(_pt_run "$_pt_c6")
        [[ "$out" == state=working-background* && "$out" == *"bg_shells=1 "* && "$out" == *"bg_longjob=0"* ]] \
            && ok "#1547 D3: the ledger names a live NON-shell (comm sleep) under a wrapper shell → nothing excluded → working-background bg_shells=1 (pre-fix: idle)" \
            || bad "#1547 D3: $out"
    else
        bad "#1547 D3: the rig did not come up — the case is unmeasured"
    fi

    echo "--- #1544 (sk3 F1, rig 4) KILL DIRECTION: a root that holds a CO-TENANT is never excluded ---"
    # A tool shell that runs a dispatcher AND real work: `… dispatch & sleep 600`.
    # The ledger names that dispatcher. Excluding its root WHOLE removed the
    # `sleep 600` with it: `idle` over live work. PREDICTED FLIP for "delete the
    # co-tenant loop": both rows go `idle`; K1 (a wrapper with no co-tenant)
    # stays `idle` either way, which is what makes it the control.
    _pt_spawn "bash -c 'bash -c \"while :; do sleep 1; done\" & sleep 600; true' & sleep 240"; _pt_c7="$_pt_claude"
    if _pt_d7=$(_pt_find_disp "$_pt_c7"); then
        ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d7" "$(_pt_st "$_pt_d7")"
        out=$(_pt_run "$_pt_c7")
        [[ "$out" == state=working-background* && "$out" == *"bg_shells=1 "* && "$out" == *"bg_longjob=0"* && "$(_pt_field "$out" bg_cmd)" != "-" ]] \
            && ok "#1544 rig 4: dispatcher + 'sleep 600' in ONE tool shell, ledger armed, 0 active → working-background bg_shells=1 bg_longjob=0 (pre-fix: idle over the live job)" \
            || bad "#1544 rig 4: $out"
    else
        bad "#1544 rig 4: the rig did not come up — the KILL-DIRECTION case is unmeasured"
    fi
    # The co-tenant one level ABOVE the dispatcher's parent: every chain node up
    # to the root is examined, not only the first.
    _pt_spawn "bash -c 'bash -c \"bash -c \\\"while :; do sleep 1; done\\\"; true\" & sleep 600; true' & sleep 240"; _pt_c8="$_pt_claude"; _pt_d8=""
    for _i in $(seq 1 80); do
        for _w in $(pgrep -P "$_pt_c8" -x bash 2>/dev/null); do for _m in $(pgrep -P "$_w" -x bash 2>/dev/null); do for _k in $(pgrep -P "$_m" -x bash 2>/dev/null); do
            [[ "$( { tr '\0' ' ' < "/proc/$_k/cmdline"; } 2>/dev/null )" == *"sleep 1;"* ]] && _pt_d8="$_k"
        done; done; done
        [[ -n "$_pt_d8" ]] && break; sleep 0.25
    done
    if [[ -n "$_pt_d8" ]]; then
        ledger "sid-$SID" $(( NOW - 10 )) 0 "$_pt_d8" "$(_pt_st "$_pt_d8")"
        out=$(_pt_run "$_pt_c8")
        [[ "$out" == state=working-background* && "$out" == *"bg_shells=1 "* && "$out" == *"bg_longjob=0"* ]] \
            && ok "#1544: the co-tenant sits TWO levels above the dispatcher (at the root, not at its parent) → still working-background" \
            || bad "#1544 deep co-tenant: $out"
    else
        bad "#1544 deep co-tenant: the rig did not come up — unmeasured"
    fi

    echo "--- #1565 KILL DIRECTION: work forked UNDER a dispatcher that exec's — the REAL \`dispatch\`, the \`exec\` spelling ---"
    # `sleep 600 & exec bash longjob-watch.sh dispatch`: `exec` keeps the pid, so
    # the `sleep 600` becomes the DISPATCHER'S OWN CHILD. The dispatcher is then
    # the root, there is no chain above it for the #1544 co-tenant loop to walk,
    # and the pane read `idle` — kill-authorised — over the live job (measured at
    # 02406fec with this rig's shape: idle, bk_pane_kill_authorized rc 0, 3 reads).
    # The REAL script is used because the fix has two halves and a planted ledger
    # tests only the reader: `cmd_dispatch` must RECORD `born_ticks`, and
    # `_pane_longjob_root` must refuse a root whose dispatcher has a child at or
    # before it.
    #
    # PREDICTED FLIP SET for "delete the born_ticks loop from _pane_longjob_root":
    # E1 and E1b and S-old go `idle`. MUST NOT FLIP: E2 (an exec'd dispatcher
    # with NO pre-exec child stays `idle`), S-old control, S-young, S-legacy, and K1 above (a
    # ledger with no `born_ticks` at all is read as it always was).
    _LJ="$REPO_ROOT/monitor/longjob-watch.sh"
    _lj_case() {   # <sid> <payload> → sets _lj_claude, _lj_hb, _lj_now; rc 1 when the dispatcher never armed
        local sid="$1" payload="$2" led i
        _lj_hb="$NEXUS_STATE_DIR/heartbeat/lj-$sid.json"; _lj_now=$(date -u +%s)
        jq -n --arg s "$sid" --argjson now "$_lj_now" '{window:"ljw", session_id:$s, state:"idle", last_activity:$now, external_waits:[]}' > "$_lj_hb"
        env -u NEXUS_WORKER_WINDOW -u NEXUS_ORCHESTRATOR_WINDOW -u NEXUS_LONGJOB_KEY -u NEXUS_LONGJOB_SESSION_ID \
            NEXUS_ROOT="$REPO_ROOT" CLAUDE_CODE_SESSION_ID="$sid" NEXUS_LONGJOB_WINDOW=ljw \
            MONITOR_LONGJOB_POLL_SECONDS=5 MONITOR_LONGJOB_ENABLED=true _LJ="$_LJ" \
            "$_pt_h_dir/claude" -c "$payload & sleep 240" >/dev/null 2>&1 &
        _lj_claude=$!; _PT_ROOTS+=("$_lj_claude")
        led="$NEXUS_STATE_DIR/longjob/sid-$sid/dispatcher.json"
        for i in $(seq 1 160); do
            [[ "$(jq -r '.service // ""' "$led" 2>/dev/null)" == polling ]] && { sleep 1; return 0; }
            sleep 0.25
        done
        return 1
    }
    _lj_read() { _pt_run "$_lj_claude" --heartbeat-file "$_lj_hb" --now "$(date -u +%s)"; }
    if _lj_case "e1e1e1e1-0000-4000-8000-000000001565" "bash -c 'sleep 600 & exec bash \$_LJ dispatch'"; then
        _e1_led="$NEXUS_STATE_DIR/longjob/sid-e1e1e1e1-0000-4000-8000-000000001565/dispatcher.json"
        _e1_bt=$(jq -r '.born_ticks // ""' "$_e1_led"); _e1_ps=$(jq -r '.pid_start // ""' "$_e1_led")
        printf '  note: #1565 born_ticks %s pid_start %s\n' "$_e1_bt" "$_e1_ps"   # per-run: a note, not the label (#1574)
        [[ "$_e1_bt" =~ ^[0-9]+$ && "$_e1_ps" =~ ^[0-9]+$ ]] && (( _e1_bt > _e1_ps )) \
            && ok "#1565: the real dispatcher RECORDS born_ticks, and it is LATER than pid_start — exec kept the start ticks, which is why pid_start cannot date a pre-exec child" \
            || bad "#1565 born_ticks: born_ticks='$_e1_bt' pid_start='$_e1_ps'"
        out=$(_lj_read)
        [[ "$out" == state=working-background* && "$out" == *"bg_shells=1 "* && "$out" == *"bg_longjob=0"* ]] \
            && ok "#1565 E1: 'sleep 600 & exec … dispatch', armed, 0 active → working-background bg_shells=1 bg_longjob=0 (pre-fix: idle over the live job)" \
            || bad "#1565 E1: $out"
    else
        bad "#1565 E1: the real dispatcher never armed — the KILL-DIRECTION case is unmeasured"
    fi
    if _lj_case "e1b1e1b1-0000-4000-8000-000000001565" "bash -c '(while :; do sleep 2; done) & exec bash \$_LJ dispatch'"; then
        out=$(_lj_read)
        [[ "$out" == state=working-background* && "$out" == *"bg_longjob=0"* ]] \
            && ok "#1565 E1b: the pre-exec child is a SUBSHELL LOOP whose own children churn → still working-background (the child is dated, not named)" \
            || bad "#1565 E1b: $out"
    else
        bad "#1565 E1b: the real dispatcher never armed — unmeasured"
    fi
    if _lj_case "e2e2e2e2-0000-4000-8000-000000001565" "bash -c 'exec bash \$_LJ dispatch'"; then
        out=$(_lj_read); sleep 6; out2=$(_lj_read)
        [[ "$out" == state=idle* && "$out" == *" bg_longjob=1"* && "$out2" == state=idle* ]] \
            && ok "#1565 E2 MUST-NOT-FLIP: an exec'd dispatcher with NO pre-exec child → idle bg_longjob=1, on two reads 6 s apart (its per-poll sleep is YOUNGER than born_ticks across a re-fork)" \
            || bad "#1565 E2: '$out' then '$out2'"
        [[ "$out" == state=idle* && "$out" != *"bg_longjob_kept="* ]] \
            && ok "#1627 MUST-NOT-FLIP: the ONE excluded dispatcher is not also recorded as kept" \
            || bad "#1627 E2 kept: $out"
    else
        bad "#1565 E2: the real dispatcher never armed — the must-not-flip control is unmeasured"
    fi

    echo "--- #1627: a SECOND real dispatcher under the SAME live claude (refused by #1544) ---"
    # The ledger names the first; the second waits, alive and polling nothing,
    # for as long as the first lives — so its root stays a counted shell and the
    # pane reads working-background for the life of the session, with nothing
    # on the line to say why. THE VERDICT IS DELIBERATELY UNCHANGED (a verdict
    # change keyed on argv would be the #1544 kill-direction hazard again); the
    # line now RECORDS the cause. PREDICTED FLIP for "delete the kept-root
    # bookkeeping": the kept row goes red; the verdict row and the E2/K2
    # controls do not move.
    if _lj_case "d2d2d2d2-0000-4000-8000-000000001627" "bash -c 'bash \$_LJ dispatch' & sleep 3; bash -c 'bash \$_LJ dispatch'"; then
        _d2_ev="$NEXUS_STATE_DIR/longjob/sid-d2d2d2d2-0000-4000-8000-000000001627/events.log"
        for _i in $(seq 1 80); do grep -q $'\trefused\t' "$_d2_ev" 2>/dev/null && break; sleep 0.25; done
        out=$(_lj_read)
        if grep -q $'\trefused\t' "$_d2_ev" 2>/dev/null; then
            [[ "$out" == state=working-background* && "$out" == *"bg_shells=1 "* && "$out" == *" bg_longjob=1"* ]] \
                && ok "#1627: the refused second dispatcher stays a counted shell → working-background bg_shells=1 bg_longjob=1 (verdict unchanged: never idle over an unidentified process)" \
                || bad "#1627 verdict: $out"
            [[ "$out" == *" bg_longjob_kept=1"* ]] \
                && ok "#1627: …and the line RECORDS why: bg_longjob_kept=1 (one counted root holds a dispatcher the exclusion did not remove)" \
                || bad "#1627 kept record: $out"
        else
            bad "#1627: the second dispatcher never logged its refusal — the case is unmeasured"
        fi
    else
        bad "#1627: the first real dispatcher never armed — the case is unmeasured"
    fi
    # The READER alone, with a PLANTED born_ticks: independent of the real
    # script's timing, and the only way to stage "older" deterministically.
    jq -n --arg s "$SID" --argjson now "$NOW" '{window:"ljw", session_id:$s, state:"idle", last_activity:$now, external_waits:[]}' > "$HB"
    _lj_plant() {   # <born_ticks> [<dispatcher pid> <its start ticks>] — default: the K1 dispatcher
        ledger "sid-$SID" $(( NOW - 10 )) 0 "${2:-$_pt_d1}" "${3:-$_pt_s1}"
        jq --arg bt "$1" '.born_ticks=$bt' "$NEXUS_STATE_DIR/longjob/sid-$SID/dispatcher.json" > "$WORK/l.tmp" && mv "$WORK/l.tmp" "$NEXUS_STATE_DIR/longjob/sid-$SID/dispatcher.json"
    }
    # S-old NEEDS A CHILD THAT EXISTS AT THE READ (#1703). On the K1 tree the
    # dispatcher's only child is the `sleep 1` it re-forks, and between one
    # sleep's reap and the next fork it has NO child: the born_ticks loop has
    # nothing to refuse on, the root is excluded, and the read is `idle` —
    # correctly, for that instant. Measured on the K1 tree with S-old's plant:
    # 1 `idle` in 47 reads on an unloaded host; once in CI (zsh, jobs 4). So
    # S-old reads a tree whose dispatcher ALSO holds a persistent `sleep 300`,
    # forked by the dispatcher itself, and the control below it plants
    # born_ticks one tick BEFORE that child's start — the same tree reads idle,
    # so the S-old row's verdict is the born_ticks comparison, not the tree.
    _PT_DISP_HELD='bash -c "bash -c \"sleep 300 & while :; do sleep 1; done\" ; true"'
    _pt_spawn "$_PT_DISP_HELD & sleep 240"; _pt_c9="$_pt_claude"; _pt_h9=""
    if _pt_d9=$(_pt_find_disp "$_pt_c9"); then
        for _i in $(seq 1 80); do
            for _k in $(pgrep -P "$_pt_d9" -x sleep 2>/dev/null); do [[ "$( { tr '\0' ' ' < "/proc/$_k/cmdline"; } 2>/dev/null )" == "sleep 300 " ]] && _pt_h9="$_k"; done
            [[ -n "$_pt_h9" ]] && break; sleep 0.25
        done
    fi
    if [[ -n "$_pt_h9" ]]; then
        _lj_plant 4611686018427387904 "$_pt_d9" "$(_pt_st "$_pt_d9")"
        out=$(_pt_run "$_pt_c9")
        [[ "$out" == state=working-background* && "$out" == *"bg_longjob=0"* ]] \
            && ok "#1565 S-old: born_ticks LATER than every child's start (each child predates the dispatcher's birth) → nothing excluded → working-background" \
            || bad "#1565 S-old: $out"
        _lj_plant "$(( $(_pt_st "$_pt_h9") - 1 ))" "$_pt_d9" "$(_pt_st "$_pt_d9")"
        out=$(_pt_run "$_pt_c9")
        [[ "$out" == state=idle* && "$out" == *" bg_longjob=1"* ]] \
            && ok "#1565 S-old control: the SAME tree, born_ticks one tick before the held child's start → every child younger → idle (the S-old verdict is the comparison)" \
            || bad "#1565 S-old control: $out"
    else
        bad "#1565 S-old: the held-child rig did not come up — the case is unmeasured"
    fi
    _lj_plant "$_pt_s1"
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=idle* && "$out" == *" bg_longjob=1"* ]] \
        && ok "#1565 S-young MUST-NOT-FLIP: born_ticks = the dispatcher's own start, every child younger → idle (the per-poll sleep is not a co-tenant)" \
        || bad "#1565 S-young: $out"
    _lj_plant "not-a-number"
    out=$(_pt_run "$_pt_c1")
    [[ "$out" == state=idle* ]] \
        && ok "#1565 S-legacy MUST-NOT-FLIP: a born_ticks that is not a number is read as a ledger that predates the field → idle, as before (stated error direction: no board-wide freeze)" \
        || bad "#1565 S-legacy: $out"
    _pt_cleanup
else
    printf '  SKIP: no pgrep or no /proc — the process-tree cases are unmeasured here\n'
fi
echo "=== the seam form (--bg-shells is the census AFTER the exclusion; --bg-longjob is only the record) ==="
rm -rf "$NEXUS_STATE_DIR/longjob"; ledger "sid-$SID" $(( NOW - 10 )) 0
[[ "$(state_of --bg-shells 0 --bg-longjob 1)" == idle ]] && ok "seam: 0 shells after the exclusion, armed, 0 active → idle" || bad "seam idle: $(state_of --bg-shells 0 --bg-longjob 1)"
[[ "$(state_of --bg-shells 1 --bg-longjob 1)" == working-background* ]] && ok "seam: 1 real shell remains beside the excluded root → working-background" || bad "seam one: $(state_of --bg-shells 1 --bg-longjob 1)"
[[ "$(state_of --bg-shells 1 --bg-longjob 0)" == working-background* ]] && ok "seam: the record alone changes no verdict (bg_longjob=0, 1 shell) → working-background" || bad "seam record: $(state_of --bg-shells 1 --bg-longjob 0)"
ledger "sid-$SID" $(( NOW - 10 )) 1; spec "sid-$SID" j1 false
[[ "$(state_of --bg-shells 0 --bg-longjob 1)" == working-background* ]] && ok "seam: 0 shells, a LIVE watch → working-background (held by the watch)" || bad "seam active: $(state_of --bg-shells 0 --bg-longjob 1)"

echo "=== the launch hook auto-arms a slurm watch (no second command) ==="
HOOK="$REPO_ROOT/monitor/hooks/async-launch-detect.sh"
export NEXUS_ROOT="$REPO_ROOT" NEXUS_WORKER_WINDOW="ljw"
# The session id is supplied the way production supplies it — in the PostToolUse
# PAYLOAD (`session_id`) — and deliberately NOT exported here: a suite that
# exports the key itself cannot test the hook's SELECTION of it (skeptic).
unset NEXUS_LONGJOB_KEY CLAUDE_CODE_SESSION_ID NEXUS_LONGJOB_SESSION_ID 2>/dev/null || true
jq -n --arg s "$SID" '{window:"ljw", session_id:$s, state:"busy", external_waits:[], dismissed_waits:[]}' > "$HB"
printf '{"hook_event_name":"PostToolUse","session_id":"%s","tool_name":"Bash","tool_input":{"command":"sbatch run.sh"},"tool_response":{"stdout":"Submitted batch job 4242\\n"}}' "$SID" \
    | MONITOR_LONGJOB_AUTO_WATCH=true bash "$HOOK" >/dev/null 2>&1; rc=$?
(( rc == 0 )) && ok "hook exits 0" || bad "hook rc=$rc"
[[ "$(jq -r '.external_waits[] | select(.kind=="slurm") | .id' "$HB")" == 4242 ]] && ok "hook still declares its own slurm:4242 wait" || bad "hook wait missing: $(cat "$HB")"
SPEC="$NEXUS_STATE_DIR/longjob/sid-$SID/watches/auto-slurm-4242.json"
[[ -f "$SPEC" ]] && ok "hook auto-added watch auto-slurm-4242 into the spool keyed on the PAYLOAD's session_id (no CLAUDE_CODE_SESSION_ID in this env)" || bad "no auto watch: $(ls -R "$NEXUS_STATE_DIR/longjob" 2>&1)"
[[ "$(jq -r '.kind + ":" + .target' "$SPEC" 2>/dev/null)" == "slurm:4242" ]] && ok "auto watch subject slurm:4242" || bad "auto watch subject"
[[ -z "$(jq -r '.external_waits[] | select(.kind=="longjob") | .id' "$HB")" ]] && ok "no duplicate longjob wait (--no-declare honoured)" || bad "duplicate wait declared"
# dismissed job → no watch
jq -n --arg s "$SID" '{window:"ljw", session_id:$s, state:"busy", external_waits:[], dismissed_waits:[{kind:"slurm",id:"4343"}]}' > "$HB"
printf '{"hook_event_name":"PostToolUse","session_id":"%s","tool_name":"Bash","tool_input":{"command":"sbatch run.sh"},"tool_response":{"stdout":"Submitted batch job 4343\\n"}}' "$SID" \
    | MONITOR_LONGJOB_AUTO_WATCH=true bash "$HOOK" >/dev/null 2>&1
[[ ! -f "$NEXUS_STATE_DIR/longjob/sid-$SID/watches/auto-slurm-4343.json" ]] && ok "a DISMISSED job (declare-no-wait) gets no auto watch" || bad "dismissed job was watched"
# knob off → no watch
printf '{"hook_event_name":"PostToolUse","session_id":"%s","tool_name":"Bash","tool_input":{"command":"sbatch run.sh"},"tool_response":{"stdout":"Submitted batch job 4444\\n"}}' "$SID" \
    | MONITOR_LONGJOB_AUTO_WATCH=false bash "$HOOK" >/dev/null 2>&1
[[ ! -f "$NEXUS_STATE_DIR/longjob/sid-$SID/watches/auto-slurm-4444.json" ]] && ok "MONITOR_LONGJOB_AUTO_WATCH=false → no auto watch (the knob selects)" || bad "knob off still watched"
[[ "$(jq -r '.external_waits[] | select(.id=="4444") | .kind' "$HB")" == slurm ]] && ok "…while the hook's own wait is still declared (the knob is the watch's, not the hook's)" || bad "hook wait lost when knob off"

echo "=== #1727: job id 0 is never armed, and an unarmed launch is NEVER SILENT ==="
# `jid=$(sbatch --parsable j.sh); echo $?` printed `0`; the `--parsable` row's
# id field took it as the job id, the hook armed `auto-slurm-0`, and
# `sacct -j 0` answered about unrelated jobs for ~9.5 h. And when no id was
# parsed the hook said nothing at all. Every case below runs against an ARMED
# ledger (fresh poll, this suite's own live pid), so `add` itself returns 0 for
# a legitimate id — the control that makes "stdout empty" mean "armed".
_h1727() {   # <cmd> <stdout> [dismissed-id] → H_OUT (hook stdout), H_RC
    jq -n --arg s "$SID" --arg d "${3:-}" '{window:"ljw", session_id:$s, state:"busy", external_waits:[],
        dismissed_waits:(if $d == "" then [] else [{kind:"slurm", id:$d}] end)}' > "$HB"
    H_OUT=$(jq -nc --arg s "$SID" --arg c "$1" --arg o "$2" \
        '{hook_event_name:"PostToolUse",session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{stdout:$o}}' \
        | MONITOR_LONGJOB_AUTO_WATCH=true bash "$HOOK" 2>/dev/null); H_RC=$?
}
_na_ctx() { jq -r 'select(.hookSpecificOutput.hookEventName == "PostToolUse") | .hookSpecificOutput.additionalContext' <<<"$H_OUT" 2>/dev/null; }
W1727="$NEXUS_STATE_DIR/longjob/sid-$SID/watches"
ledger "sid-$SID" "$(date +%s)" 0
_h1727 'sbatch j.sh' 'Submitted batch job 123456'
[[ -f "$W1727/auto-slurm-123456.json" && $H_RC -eq 0 ]] && ok "#1727 CONTROL: a legit id (123456) is still armed as auto-slurm-123456" || bad "#1727 control: legit id not armed (rc=$H_RC): $(ls "$W1727" 2>&1)"
[[ -z "$H_OUT" ]] && ok "#1727 CONTROL: the ARMED case prints nothing" || bad "#1727 control: armed case printed: $H_OUT"

ledger "sid-$SID" "$(date +%s)" 0
_h1727 'J=$(sbatch --parsable j.sh); echo $?' '0'
(( H_RC == 0 )) && ok "#1727 the hook exits 0 on the \$(…) + echo \$? call (never blocks the sbatch)" || bad "#1727 rc=$H_RC"
[[ ! -e "$W1727/auto-slurm-0.json" ]] && ok "#1727 \`J=\$(sbatch --parsable j.sh); echo \$?\` → NO auto-slurm-0 watch" || bad "#1727 auto-slurm-0 was armed"
[[ -z "$(jq -r '.external_waits[] | select(.kind=="slurm" and .id=="0") | .id' "$HB")" ]] && ok "#1727 …and no slurm:0 wait is recorded for the orphan-async resolver either" || bad "#1727 slurm:0 wait recorded: $(cat "$HB")"
_c=$(_na_ctx)
[[ "$_c" == "longjob NOT ARMED"*"ng longjob add slurm:<id>"*"ARMED"* ]] && ok "#1727 …and the hook prints a PostToolUse additionalContext: longjob NOT ARMED + the arming command" || bad "#1727 no NOT ARMED notice: '$H_OUT'"

ledger "sid-$SID" "$(date +%s)" 0
_h1727 'J=$(sbatch --parsable j.sh); echo $J' '123457'
[[ ! -e "$W1727/auto-slurm-123457.json" && "$(_na_ctx)" == *"inside \$(…)"* ]] && ok "#1727 a bare number inside a \$(…) submission is not trusted even when it looks real — NOT ARMED names why (declared cost)" || bad "#1727 subst distrust: $(ls "$W1727" 2>&1) out=$H_OUT"

ledger "sid-$SID" "$(date +%s)" 0
_h1727 'sbatch --parsable j.sh' '0'
[[ ! -e "$W1727/auto-slurm-0.json" && "$(_na_ctx)" == *"refused job id(s) 0"* ]] && ok "#1727 a bare \`0\` from a NON-substituted --parsable call is refused by the job-id predicate and named" || bad "#1727 predicate: $(ls "$W1727" 2>&1) out=$H_OUT"

ledger "sid-$SID" "$(date +%s)" 0
_h1727 'sbatch --parsable j.sh' ''
[[ "$(_na_ctx)" == "longjob NOT ARMED"*"no job id could be read"* ]] && ok "#1727 empty stdout (no id parsed) → NOT ARMED, not silence" || bad "#1727 empty stdout silent: '$H_OUT'"

ledger "sid-$SID" "$(date +%s)" 0
_h1727 'sbatch run.sh' 'Submitted batch job 123458' 123458
[[ -z "$H_OUT" && ! -e "$W1727/auto-slurm-123458.json" ]] && ok "#1727 a DISMISSED job stays silent (declare-no-wait is deliberate)" || bad "#1727 dismissed: out=$H_OUT"

ledger "sid-$SID" "$(date +%s)" 0
_h1727 $'sbatch a.sh; sbatch b.sh\nsbatch c.sh | tee sub.log' $'Submitted batch job 123460\nSubmitted batch job 123461\nSubmitted batch job 123462'
[[ -f "$W1727/auto-slurm-123460.json" && -f "$W1727/auto-slurm-123461.json" && -f "$W1727/auto-slurm-123462.json" && -z "$H_OUT" ]] \
    && ok "#1727 CONTROL: a multi-sbatch call (incl. \`sbatch … | tee\`) arms every id and prints nothing" || bad "#1727 multi: $(ls "$W1727" 2>&1) out=$H_OUT"

ledger "sid-$SID" "$(( $(date +%s) - 100000 ))" 0
_h1727 'sbatch j.sh' 'Submitted batch job 123459'
[[ "$(_na_ctx)" == *"job(s) 123459: "*"rc=3"*"NOT ARMED"* ]] && ok "#1727 a recorded watch whose dispatcher is NOT ARMED (stale ledger, add rc 3) is reported, not swallowed" || bad "#1727 add rc 3 silent: '$H_OUT'"

# ONLY THE ID SBATCH ITSELF PRINTS MAY ARM (#1727 core). The proj-overlay2
# shape: a NON-substituted `sbatch --parsable` beside `grep -c` lines whose bare
# `1`s were read as the job id (slurm:1).
ledger "sid-$SID" "$(date +%s)" 0
_h1727 'sbatch --parsable j.sh; grep -c a f; grep -c b f' $'123470\n1\n1'
[[ ! -e "$W1727/auto-slurm-1.json" && ! -e "$W1727/auto-slurm-123470.json" ]] && ok "#1727 core: sbatch --parsable beside two grep -c lines arms NOTHING (no slurm:1)" || bad "#1727 core: armed from a count: $(ls "$W1727" 2>&1)"
[[ "$(_na_ctx)" == *"other commands beside sbatch --parsable"* ]] && ok "#1727 core: …and NOT ARMED names why (other commands may have printed the number)" || bad "#1727 core: notice: '$H_OUT'"
ledger "sid-$SID" "$(date +%s)" 0
_h1727 'sbatch --parsable j.sh; grep -c x f' '1'
[[ ! -e "$W1727/auto-slurm-1.json" ]] && ok "#1727 core: a FAILED sbatch beside one grep -c (stdout just '1') arms nothing" || bad "#1727 core: slurm:1 armed from a lone count"
ledger "sid-$SID" "$(date +%s)" 0
_h1727 'cd /x && sbatch --parsable j.sh | tee sub.log' '123471'
[[ -f "$W1727/auto-slurm-123471.json" && -z "$H_OUT" ]] && ok "#1727 core CONTROL: cd && sbatch --parsable | tee still arms its id silently" || bad "#1727 core control tee: $(ls "$W1727" 2>&1) out=$H_OUT"
ledger "sid-$SID" "$(date +%s)" 0
_h1727 'for f in a b; do sbatch --parsable "$f"; done' $'123472\n123473'
[[ -f "$W1727/auto-slurm-123472.json" && -f "$W1727/auto-slurm-123473.json" && -z "$H_OUT" ]] && ok "#1727 core CONTROL: a for-loop of --parsable submissions arms every id" || bad "#1727 core control loop: $(ls "$W1727" 2>&1) out=$H_OUT"

# FD REDIRECTIONS AND env ASSIGNMENTS ARE NOT COMMANDS (ncbundle17-sk, PR 1745):
# the `&` in `2>&1` once split off a segment `1`, and `env A=1` left `A=1`.
ledger "sid-$SID" "$(date +%s)" 0
_h1727 'sbatch --parsable j.sh 2>&1' '123480'
[[ -f "$W1727/auto-slurm-123480.json" && -z "$H_OUT" ]] && ok "#1727 core CONTROL: sbatch --parsable … 2>&1 still arms" || bad "#1727 core 2>&1: $(ls "$W1727" 2>&1) out=$H_OUT"
ledger "sid-$SID" "$(date +%s)" 0
_h1727 'sbatch --parsable j.sh 2>&1 | tee sub.log' '123481'
[[ -f "$W1727/auto-slurm-123481.json" && -z "$H_OUT" ]] && ok "#1727 core CONTROL: … 2>&1 | tee still arms" || bad "#1727 core 2>&1|tee: $(ls "$W1727" 2>&1) out=$H_OUT"
ledger "sid-$SID" "$(date +%s)" 0
_h1727 'env A=1 sbatch --parsable j.sh' '123482'
[[ -f "$W1727/auto-slurm-123482.json" && -z "$H_OUT" ]] && ok "#1727 core CONTROL: env A=1 sbatch --parsable still arms" || bad "#1727 core env A=1: $(ls "$W1727" 2>&1) out=$H_OUT"

echo; echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }; exit 1
