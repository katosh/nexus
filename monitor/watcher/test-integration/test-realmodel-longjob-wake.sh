#!/usr/bin/env bash
# monitor/watcher/test-integration/test-realmodel-longjob-wake.sh — the REAL
# Claude Code binary, booted with the longjob-watch dispatcher plugin against
# the auth-free mock backend, is WOKEN by each event the dispatcher emits —
# several in succession, with NO re-arming (your-org/nexus-code#1535).
#
# WHAT "WOKEN" MEANS HERE, measurably: a wake is an API request to the mock
# whose LAST message carries the dispatcher's event line (the harness logs
# `REQ … last=<last message>` per request). A session that merely renders a
# notification but never calls the model was not woken; a session that calls
# the model without the event in its last message was woken by something
# else. The count of such requests IS the count of wakes, and it is read from
# the mock's log, not from the pane.
#
# ARMS:
#   A  --plugin-dir monitor/longjob-plugin, three file watches completed one
#      after another → THREE wakes, one per event, in order; the dispatcher
#      still alive and the footer still `1 monitor` afterwards; no Monitor
#      tool call was ever made (the mock never returns tool_use, and the
#      plugin monitor is host-armed once at boot — there is nothing to re-arm).
#   NC the SAME rig booted WITHOUT --plugin-dir: `add` reports NOT ARMED
#      (rc 3), the file completes, and ZERO wakes arrive — the negative
#      control that proves arm A's wakes came from the plugin and that the
#      counter can read zero.
#
# Gated on RUN_CC_HARNESS=1 like every realmodel scenario. Hermetic: the
# harness's own tmux socket, CLAUDE_CONFIG_DIR and state dir; the plugin is
# the SHIPPED one (monitor/longjob-plugin), so this also proves the manifest
# the launchers pass is loadable by the pinned binary.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../_test_helpers.sh
. "$_self_dir/../_test_helpers.sh"
# shellcheck source=../../cc-harness/_lib.sh
. "$_self_dir/../../cc-harness/_lib.sh"
cch_skip_if_disabled
command -v jq >/dev/null 2>&1 || { echo "skipped: $(basename "$0") (jq not on PATH)"; [[ "${CCH_GATE:-0}" == "1" ]] && exit 77; exit 0; }
cch_setup
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

REPO_ROOT="$CCH_REPO_ROOT"
LJ="$REPO_ROOT/monitor/longjob-watch.sh"
PLUGIN="$REPO_ROOT/monitor/longjob-plugin"
# The dispatcher's state dir IS the harness state dir pane-state.sh reads, and
# the spool key is `win-<window>` — the window-keyed fallback pane-state's
# discount consults when a heartbeat carries no session_id (no hooks are
# wired here, so the heartbeat below is written by the scenario itself).
LJ_STATE="$CCH_STATE_DIR"; mkdir -p "$LJ_STATE/heartbeat"
FILES="$CCH_DIR/ljfiles"; mkdir -p "$FILES"
POLL=5

echo "=== real binary + longjob-watch plugin: one wake per event, no re-arm (#1535) ==="
echo "    claude:  $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>/dev/null || echo '?'))"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT   log: $CCH_LOG"

# Every wake is answered with one cheap canned line so the turn ends at once.
cch_control '{"mode":"text","text":"ack"}'

# The dispatcher runs INSIDE the booted claude's env (env -i), so the spool
# location, key and cadence go through CCH_EXTRA_ENV; the same values are
# exported here so `add`/`status` from this shell hit the same spool.
lj_env() {   # <window>  → the K=v string for CCH_EXTRA_ENV and for our own calls
    printf 'NEXUS_ROOT=%q NEXUS_STATE_DIR=%q NEXUS_LONGJOB_KEY=%q NEXUS_WORKER_WINDOW=%q MONITOR_LONGJOB_POLL_SECONDS=%q MONITOR_LONGJOB_ENABLED=true' \
        "$REPO_ROOT" "$LJ_STATE" "win-$1" "$1" "$POLL"
}
write_hb() {   # <window> — a minimal heartbeat so pane-state can key the discount on the window
    jq -n --arg w "$1" --argjson now "$(date +%s)" '{window:$w, state:"idle", last_activity:$now, external_waits:[]}' > "$LJ_STATE/heartbeat/$1.json"
}
wakes() {   # count API requests whose LAST message carries the event line
    local n; n=$(grep -c 'REQ .*last=.*longjob-watch: DONE' "$CCH_LOG" 2>/dev/null || true)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"
}
wait_wakes() {   # <n> <timeout-s>
    local i; for i in $(seq 1 $(( $2 * 2 ))); do (( $(wakes) >= $1 )) && return 0; sleep 0.5; done; return 1
}
footer_mon() {   # <idx> → monitor count in the footer (0 when absent)
    local plain; plain=$(cch_capture "$1" 2>/dev/null | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
    if [[ "$plain" =~ ([0-9]+)[[:space:]]+monitor ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf 0; fi
}

echo
echo "--- ARM A: plugin armed at boot ---"
IDX_A=$(CCH_EXTRA_ENV="$(lj_env lj-a)" CCH_CLAUDE_ARGS="--plugin-dir $(printf '%q' "$PLUGIN")" cch_boot_worker lj-a)
[[ -n "$IDX_A" ]] || { echo "FATAL: arm A window never appeared" >&2; exit 1; }
# Boot: wait for an idle REPL, then for the dispatcher's ledger (armed with NO turn).
for i in $(seq 1 120); do [[ "$(cch_state "$IDX_A")" == idle ]] && break; sleep 0.5; done
[[ "$(cch_state "$IDX_A")" == idle ]] && ok "A: real binary booted to idle with --plugin-dir" || bad "A: never idle: $(cch_state "$IDX_A")"
for i in $(seq 1 60); do env $(lj_env lj-a) "$LJ" status >/dev/null 2>&1 && break; sleep 0.5; done
st=$(env $(lj_env lj-a) "$LJ" status 2>&1); rc=$?
if (( rc != 0 )) && [[ "$st" == *"dispatcher=absent"* ]] && (( $(footer_mon "$IDX_A") == 0 )); then
    # MEASURED BOUNDARY (2026-09-15, 2.1.272): the host arms plugin monitors only
    # when GrowthBook serves tengu_amber_sentinel=true (default false). Under the
    # mock backend the binary is a "third-party provider", GrowthBook is OFF,
    # the disk cache is not consulted, and the flag is the default — so the
    # dispatcher cannot arm here whatever this scenario does. Say so and skip;
    # the arming/delivery claims are measured by the hermetic REAL-AUTH probes
    # on your-org/nexus-code#1535 and the recipe in skills/nexus.cc-update/GUIDE.md 2g.
    echo "skipped: $(basename "$0") — plugin monitor NOT armed under the mock backend (GrowthBook off → tengu_amber_sentinel default false); the real-binary wake is measured by the real-auth probes on your-org/nexus-code#1535"
    cch_teardown
    [[ "${CCH_GATE:-0}" == "1" ]] && exit 77
    exit 0
fi
(( rc == 0 )) && [[ "$st" == *"dispatcher=armed"* ]] && ok "A: dispatcher ledger ARMED with zero model turns ($(wakes) requests carrying an event so far)" || bad "A: status rc=$rc: $st"
(( $(footer_mon "$IDX_A") >= 1 )) && ok "A: footer shows the host-armed monitor ($(footer_mon "$IDX_A") monitor)" || bad "A: footer shows no monitor"
# Three watches, completed one after another; each must produce its own wake.
for k in 1 2 3; do env $(lj_env lj-a) "$LJ" add "file:$FILES/a$k" --id "a$k" --interval "$POLL" --desc "arm A file $k" >/dev/null 2>&1 || bad "A: add a$k failed"; done
W0=$(wakes)
for k in 1 2 3; do
    touch "$FILES/a$k"
    if wait_wakes $(( W0 + k )) 60; then ok "A: event $k → wake $k (API request whose last message carries 'longjob-watch: DONE a$k'): $(grep -c "last=.*DONE a$k " "$CCH_LOG") request(s) name it" \
    ; else bad "A: no wake for event $k within 60 s (wakes=$(wakes))"; fi
    # let the ack turn finish before the next event so the count is one-per-event
    for i in $(seq 1 40); do [[ "$(cch_state "$IDX_A")" == idle ]] && break; sleep 0.5; done
done
sleep 3
(( $(wakes) - W0 == 3 )) && ok "A: exactly 3 wakes for 3 events (no duplicates, no missing)" || bad "A: wakes delta $(( $(wakes) - W0 )) (want 3)"
grep -q 'last=.*DONE a1 ' "$CCH_LOG" && grep -q 'last=.*DONE a2 ' "$CCH_LOG" && grep -q 'last=.*DONE a3 ' "$CCH_LOG" && ok "A: each of the three event lines was delivered (a1, a2, a3)" || bad "A: an event line is missing from the request log"
o1=$(grep -n 'last=.*DONE a1 ' "$CCH_LOG" | head -1 | cut -d: -f1); o3=$(grep -n 'last=.*DONE a3 ' "$CCH_LOG" | head -1 | cut -d: -f1)
[[ -n "$o1" && -n "$o3" ]] && (( o1 < o3 )) && ok "A: delivered in emission order" || bad "A: order a1@$o1 a3@$o3"
st=$(env $(lj_env lj-a) "$LJ" status 2>&1); [[ "$st" == *"dispatcher=armed"* && "$st" == *"active_watches=0"* ]] && ok "A: dispatcher still ARMED after every watch retired — nothing was re-armed, nothing exited" || bad "A: post status: $st"
(( $(footer_mon "$IDX_A") >= 1 )) && ok "A: footer still shows the monitor after three events" || bad "A: monitor gone from footer"
! grep -q 'mode=tool_use' "$CCH_LOG" && ok "A: no tool_use turn was ever served — no Monitor tool call, no re-arm by the model" || bad "A: a tool_use turn appeared"
# The #1535 discount on REAL bytes, with its potency control: the same pane
# and the same heartbeat, read with the dispatcher ledger present (idle) and
# moved aside (working-background — the pre-#1535 verdict that would have
# frozen window cleanup board-wide).
write_hb lj-a
LEDGER="$LJ_STATE/longjob/win-lj-a/dispatcher.json"
[[ "$(cch_state "$IDX_A")" == idle ]] && ok "A: pane reads idle with the idle dispatcher discounted (pane-state.sh's #1535 discount on real bytes)" || bad "A: final pane state $(cch_state "$IDX_A")"
mv "$LEDGER" "$LEDGER.aside"
[[ "$(cch_state "$IDX_A")" == working-background ]] && ok "A: POTENCY — with the ledger moved aside the same bytes read working-background (the discount is what makes the difference)" || bad "A: ledger aside → $(cch_state "$IDX_A")"
mv "$LEDGER.aside" "$LEDGER"

echo
echo "--- NC: same rig, NO --plugin-dir → NOT ARMED, zero wakes ---"
IDX_N=$(CCH_EXTRA_ENV="$(lj_env lj-nc)" CCH_CLAUDE_ARGS="" cch_boot_worker lj-nc)
[[ -n "$IDX_N" ]] || { echo "FATAL: NC window never appeared" >&2; exit 1; }
for i in $(seq 1 120); do [[ "$(cch_state "$IDX_N")" == idle ]] && break; sleep 0.5; done
[[ "$(cch_state "$IDX_N")" == idle ]] && ok "NC: booted to idle without the plugin" || bad "NC: never idle"
(( $(footer_mon "$IDX_N") == 0 )) && ok "NC: footer shows NO monitor" || bad "NC: footer monitor count $(footer_mon "$IDX_N")"
out=$(env $(lj_env lj-nc) "$LJ" add "file:$FILES/n1" --id n1 --interval "$POLL" 2>&1); rc=$?
(( rc == 3 )) && [[ "$out" == *"NOT ARMED"* ]] && ok "NC: add says NOT ARMED at rc 3 — the watch will not wake this session" || bad "NC: add rc=$rc: $out"
W1=$(wakes); touch "$FILES/n1"; sleep $(( POLL * 3 + 5 ))
(( $(wakes) == W1 )) && ok "NC: zero wakes after the file completed (the counter reads zero when nothing is armed)" || bad "NC: wakes rose by $(( $(wakes) - W1 )) without a plugin"
! grep -q 'last=.*DONE n1 ' "$CCH_LOG" && ok "NC: the n1 event line never reached the model" || bad "NC: n1 delivered without a dispatcher"

cch_teardown
echo; echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }; exit 1
