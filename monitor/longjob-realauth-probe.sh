#!/usr/bin/env bash
# monitor/longjob-realauth-probe.sh — the BY-HAND, REAL-AUTH measurement of
# the plugin-monitor mechanism the longjob-watch dispatcher rests on
# (your-org/nexus-code#1535; cc-update GUIDE surface 2g).
#
# NOT a test suite (deliberately not `test-*.sh`): it boots the REAL binary
# with REAL auth in hermetic tmux sessions and each case takes one or two
# model turns, so it costs quota (≈ $0.5 for the full set at 2.1.272). It
# exists because the cc-harness CANNOT measure this: under the mock backend
# the binary is a "third-party provider", GrowthBook is off, and the arming
# gate `tengu_amber_sentinel` is its default (false) — measured 2026-09-15.
#
# Cases (predictions in RESULTS.md are written BEFORE each run):
#   c0   control: the SHIPPED plugin, a trivial prompt → session starts, takes
#        a turn, footer `1 monitor`, ledger ARMED with zero turns, env inherited
#   c1   --plugin-dir /nonexistent            → starts, takes a turn, 0 monitor
#   c2   malformed manifest                   → same
#   c3   manifest command does not exist      → same, plus the "script failed"
#        exit notice and what the model did with it (the cost of a crash)
#   c4   command exits 3 at once              → same
#   c7   mid-turn delivery: one event at T0+45 s during a 100 s foreground
#        python sleep → surfaced inside that turn, before the model's reply
#   c8   three successive events, no re-arm → three deliveries, footer still
#        `1 monitor`, ledger still armed
#
# Usage:  CLAUDE_BIN=<binary> monitor/longjob-realauth-probe.sh [--only c0,c7] [--keep]
# Output: $OUT/RESULTS.md (+ per-case pane scrollback and side files), where
#         OUT defaults to $TMPDIR/longjob-realauth-<epoch>. Private tmux socket
#         `-L ljp` under TMUX_TMPDIR=/tmp/c71780 (fits sun_path); sessions are
#         killed at the end unless --keep.
set -uo pipefail
_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NEXUS_ROOT="${NEXUS_ROOT:-$(cd "$_dir/.." && pwd)}"
ONLY="c0,c1,c2,c3,c4,c7,c8"; KEEP=0
while (( $# )); do case "$1" in --only) ONLY="$2"; shift 2 ;; --keep) KEEP=1; shift ;; *) echo "usage: $0 [--only c0,c7,…] [--keep]" >&2; exit 2 ;; esac; done
# shellcheck disable=SC1091
. "$NEXUS_ROOT/monitor/_claude-bin.sh"
[[ -x "${CLAUDE_BIN:-}" ]] || { echo "no CLAUDE_BIN" >&2; exit 2; }
OUT="${OUT:-${TMPDIR:-/tmp}/longjob-realauth-$(date +%s)}"; mkdir -p "$OUT"
export TMUX_TMPDIR=/tmp/c71780; mkdir -p "$TMUX_TMPDIR"
unset TMUX   # never let the invoking pane's socket leak into a probe session
"$NEXUS_ROOT/monitor/tmux-socket-fits.sh" --socket ljp --tmpdir "$TMUX_TMPDIR" --quiet || { echo "socket path too long" >&2; exit 3; }
T() { tmux -L ljp "$@"; }
R="$OUT/RESULTS.md"
say() { printf '%s\n' "$*" | tee -a "$R"; }
want() { grep -qF ",$1," <<<",$ONLY,"; }
# The plugin and the tool come from THIS script's tree, never from NEXUS_ROOT:
# an inherited NEXUS_ROOT is the PRIMARY (state) root, which need not carry
# the code under test — measured: the first run of this probe armed nothing
# because the primary had no monitor/longjob-plugin yet.
PLUGIN="$_dir/longjob-plugin"
OK_PROMPT='Reply with exactly the word OK and nothing else.'

say "# longjob real-auth probe — $(date -u +%FT%TZ) — $("$CLAUDE_BIN" --version 2>/dev/null) — $CLAUDE_BIN"
say ""
mkplug() {   # <dir> <name> <command>
    mkdir -p "$1/.claude-plugin"
    printf '{ "name": "%s", "version": "0.0.1", "description": "probe %s", "author": {"name": "nexus probe"},\n  "experimental": { "monitors": [ { "name": "probe", "description": "probe %s", "command": "%s" } ] } }\n' "$2" "$2" "$2" "$3" > "$1/.claude-plugin/plugin.json"
}
launch() {   # <case> <plugin-dir-arg> <prompt> [<extra-env>]
    local c="$1" pd="$2" prompt="$3" env="${4:-}" wd="$OUT/$1/wd"; mkdir -p "$wd"
    T kill-session -t "$c" 2>/dev/null || true
    T new-session -d -s "$c" -x 180 -y 50 -c "$wd" \
        "cd '$wd' && $env NEXUS_ROOT='$NEXUS_ROOT' NEXUS_STATE_DIR='$OUT/$c/state' NEXUS_LONGJOB_KEY='win-$c' NEXUS_WORKER_WINDOW='$c' MONITOR_LONGJOB_POLL_SECONDS=5 LJ_PROBE_VAR=lj-$c CLAUDE_CODE_SANDBOXED=1 '$CLAUDE_BIN' --dangerously-skip-permissions --plugin-dir '$pd' '$prompt'; echo CLAUDE-EXITED rc=\$?; sleep 3600"
}
pane() { T capture-pane -p -S -"${2:-60}" -t "$1" 2>/dev/null; }
wait_for() {   # <case> <needle> <timeout-s>
    local i; for i in $(seq 1 $(( $3 * 2 ))); do grep -qF -- "$2" <<<"$(pane "$1")" && return 0; sleep 0.5; done; return 1
}
mon() { pane "$1" 20 | grep -oE '[0-9]+ monitor' | tail -1; }
lj() { NEXUS_STATE_DIR="$OUT/$1/state" NEXUS_LONGJOB_KEY="win-$1" NEXUS_WORKER_WINDOW="$1" "$_dir/longjob-watch.sh" "${@:2}"; }
finish() { local c="$1"; pane "$c" 200 > "$OUT/$c/scrollback.txt"; (( KEEP )) || T kill-session -t "$c" 2>/dev/null || true; }

if want c0; then
    say "## c0 — control (shipped plugin). PREDICTION: starts, OK, footer 1 monitor, ledger armed with 0 turns, env inherited."
    launch c0 "$PLUGIN" "$OK_PROMPT"
    wait_for c0 "OK" 180 && say "- took a turn: yes" || say "- took a turn: NO"
    for i in $(seq 1 120); do lj c0 status >/dev/null 2>&1 && break; sleep 0.5; done
    say "- footer: $(mon c0 || echo none)"; say "- ledger: $(lj c0 status 2>&1 | sed -n 2p)"
    say "- arm latency: $(( $(jq -r .armed_at "$OUT/c0/state/longjob/win-c0/dispatcher.json" 2>/dev/null || echo 0) - $(stat -c %Y "$OUT/c0/wd") )) s after launch (ledger armed_at − workdir mtime)"
    finish c0
fi
mkdir -p "$OUT/c2/plug/.claude-plugin"; printf '{ "name": ' > "$OUT/c2/plug/.claude-plugin/plugin.json"
mkplug "$OUT/c3/plug" lj-c3 "/nonexistent/bin/lj-no-such-binary"
mkplug "$OUT/c4/plug" lj-c4 "bash -c 'exit 3'"
for c in c1 c2 c3 c4; do
    want "$c" || continue
    case "$c" in c1) pd=/nonexistent/lj-plugin-dir ;; *) pd="$OUT/$c/plug" ;; esac
    say "## $c — arming failure ($pd). PREDICTION: starts, OK, footer shows NO monitor; c3/c4 additionally deliver a 'script failed' notice that costs a turn."
    launch "$c" "$pd" "$OK_PROMPT"
    wait_for "$c" "OK" 180 && say "- took a turn: yes" || say "- took a turn: NO"
    sleep 25
    say "- footer: $(mon "$c" || echo none)"
    grep -q 'script failed' <<<"$(pane "$c" 80)" && say "- exit notice delivered: yes — $(pane "$c" 80 | grep -oE 'Brewed for [0-9ms ]+|Cooked for [0-9ms ]+' | tail -1)" || say "- exit notice delivered: no"
    finish "$c"
done
if want c7; then
    say "## c7 — mid-turn delivery. PREDICTION: the event (T0+45 s, during a 100 s foreground tool call) appears in the scrollback BEFORE the model's DONE reply."
    mkdir -p "$OUT/c7/plug/.claude-plugin"
    cat > "$OUT/c7/emit.sh" <<EOF
#!/usr/bin/env bash
echo "T0 \$(date -u +%s) \$(date -u +%T)" >> "$OUT/c7/emit.log"; sleep 45
echo "LJ-MIDTURN-EVENT emitted-at \$(date -u +%T)"; echo "EMITTED \$(date -u +%s) \$(date -u +%T)" >> "$OUT/c7/emit.log"
while :; do sleep 60; done
EOF
    chmod +x "$OUT/c7/emit.sh"; mkplug "$OUT/c7/plug" lj-c7 "$OUT/c7/emit.sh"
    launch c7 "$OUT/c7/plug" 'This is a synchronous step. Use the Bash tool ONCE, in the FOREGROUND (run_in_background must be false), with the tool timeout parameter set to 200000, to run exactly: python3 -c "import time; time.sleep(100); print(\"end\")"  . Wait for it to return. Then reply with exactly: DONE'
    wait_for c7 "DONE" 300 && say "- turn completed: yes" || say "- turn completed: NO"
    sleep 3
    ev=$(pane c7 120 | grep -n 'Monitor event' | sed -n 1p | cut -d: -f1); dn=$(pane c7 120 | grep -n '^● DONE' | sed -n 1p | cut -d: -f1)
    say "- scrollback rows: Monitor event=$ev  DONE=$dn  → $([[ -n "$ev" && -n "$dn" ]] && (( ev < dn )) && echo 'delivered INSIDE the turn' || echo 'NOT inside the turn (or not delivered)')"
    say "- emit.log: $(tr '\n' ' ' < "$OUT/c7/emit.log")"
    finish c7
fi
if want c8; then
    say "## c8 — three successive events, no re-arm. PREDICTION: three 'Monitor event' deliveries, one per event, footer still 1 monitor, ledger still armed."
    launch c8 "$PLUGIN" 'Reply with exactly the word OK and nothing else. For any later notification, reply with exactly the word ACK and nothing else.'
    wait_for c8 "OK" 180 || say "- first turn: NO"
    sleep 10
    for k in 1 2 3; do lj c8 add "file:$OUT/c8/f$k" --id "e$k" --interval 5 >/dev/null 2>&1; done
    # The pane renders a delivery as `● Monitor event: "<description>"`, not
    # the line itself, so count deliveries rather than grep for the payload.
    nev() { pane c8 200 | grep -c 'Monitor event'; }
    for k in 1 2 3; do
        touch "$OUT/c8/f$k"
        for i in $(seq 1 180); do (( $(nev) >= k )) && break; sleep 0.5; done
        (( $(nev) >= k )) && say "- event $k delivered ($(nev) deliveries so far)" || say "- event $k NOT delivered in 90 s"
        sleep 20
    done
    say "- deliveries in scrollback: $(nev); events.log: $(lj c8 events 5 2>/dev/null | grep -c $'\tdone\t1\t') printed"
    say "- footer: $(mon c8 || echo none)"; say "- ledger: $(lj c8 status 2>&1 | sed -n 2p)"
    finish c8
fi
say ""; say "Results: $R"
(( KEEP )) || tmux -L ljp kill-server 2>/dev/null || true
