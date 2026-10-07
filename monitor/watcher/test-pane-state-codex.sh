#!/usr/bin/env bash
# test-pane-state-codex.sh — pane-state.sh on OpenAI Codex panes
# (your-org/nexus-code#1640, layer 2).
#
# test-pane-state.sh already asserts every REAL Codex capture through the
# fixture manifest. This suite covers what a manifest row cannot express:
#
#   1. THE KILL HAZARD THIS CHANGE CLOSES, as a differential pair. A process at
#      the pane root whose exe is `…/@openai/codex-linux-x64/…/bin/codex` must
#      be recognised as a live agent. Before the fix `_pid_runs_claude` knew
#      only claude, and such a pane read `state=absent` — on the kill
#      allowlist — while Codex was working. The pair holds the process tree
#      fixed and varies ONLY the binary's name (`codex` vs `codax`), so the
#      one thing that can flip the verdict is the identity arm.
#   2. A FRESH busy heartbeat (written by the codex hooks) outranks an
#      idle-looking screen; a STALE one does not.
#   3. An unrecognised Codex screen reads `unknown`, never idle.
#   4. NEGATIVE CONTROL over the whole existing corpus: no non-Codex fixture
#      is re-labelled harness=codex (the screen signature must not fire on a
#      Claude pane).
#   5. The kill allowlist agrees: only the idle Codex captures are
#      kill-authorised by bk_pane_kill_authorized; every busy, blocked and
#      typing capture is refused.
set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Population (skeptic F5, #1640): the Codex classifier and the ladder that
# routes to it, so an edit to either selects this suite.
# shellcheck disable=SC1091
. "$_self_dir/../_guard_population.sh"
gp_population() { printf '%s\n' monitor/_pane-state-codex.sh monitor/pane-state.sh; }
gp_handle "$@"
# shellcheck source=_test_helpers.sh
. "$_self_dir/_test_helpers.sh"

PS="$_self_dir/../pane-state.sh"
FX="$_self_dir/fixtures"
[[ -x "$PS" ]] || th_abort "pane-state.sh not executable at $PS"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pscodex.XXXXXX") || th_abort "mktemp failed"
PIDS=()
_cleanup() {
    local p
    for p in "${PIDS[@]}"; do th_kill_own_child "$p" KILL; done
    rm -rf "$WORK"
}
trap _cleanup EXIT

_state() { sed -n 's/^state=\([^ ]*\).*/\1/p' <<<"$1"; }
_ps() { bash "$PS" --window 9 --name codexwin --active 0 "$@" 2>/dev/null; }

echo "=== 1. process identity: a Codex pane root is a LIVE agent (differential pair) ==="
SLEEP_BIN=$(command -v sleep) || th_abort "no sleep binary"
# Launched in THIS shell, never inside $(…): a background child of a command
# substitution belongs to that subshell, not to us, and th_kill_own_child
# (ppid == $$) would then refuse to reap it.
mk_agent() {   # <name> -> sets AGENT_PID to a live process whose exe is …/bin/<name>
    local d="$WORK/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin"
    mkdir -p "$d"
    cp "$SLEEP_BIN" "$d/$1" || return 1
    "$d/$1" 120 </dev/null >/dev/null 2>&1 &
    AGENT_PID=$!
    disown "$AGENT_PID" 2>/dev/null || true   # keeps ppid (so th_kill_own_child still owns it); drops the "Killed" job notice
    PIDS+=("$AGENT_PID")
}
mk_agent codex || th_abort "could not stage the codex stand-in"; p_codex=$AGENT_PID
mk_agent codax || th_abort "could not stage the codax control"; p_codax=$AGENT_PID
sleep 0.3
[[ "$(readlink "/proc/$p_codex/exe")" == */bin/codex ]] || th_abort "stand-in exe is not …/bin/codex: $(readlink "/proc/$p_codex/exe")"
out_codex=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 _ps --fixture "$FX/codex-idle-real-api.ansi" --pane-pid "$p_codex")
out_codax=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 _ps --fixture "$FX/codex-idle-real-api.ansi" --pane-pid "$p_codax")
assert_eq       "exe …/bin/codex at the pane root: classified from the screen (idle), NOT absent" "$(_state "$out_codex")" "idle"
assert_contains "…and labelled harness=codex by the PROCESS walk" "$out_codex" "harness=codex"
assert_eq       "CONTROL, same tree, binary named codax: the gate still says absent (the identity arm is what flips it)" "$(_state "$out_codax")" "absent"
out_busy=$(NEXUS_PANE_BOOT_GRACE_SECONDS=0 _ps --fixture "$FX/codex-busy-working-real-api.ansi" --pane-pid "$p_codex")
assert_eq       "a working Codex pane root reads busy, never absent" "$(_state "$out_busy")" "busy"

echo "=== 2. heartbeat: fresh busy outranks an idle-looking screen; stale does not ==="
now=$(date +%s)
printf '{"state":"busy","last_activity":%s,"window":"codexwin"}\n' "$now" > "$WORK/hb-fresh.json"
# A CLOSED turn: the last hook was Stop (last_turn_end >= last_activity). Since
# skeptic F1 a busy/user_prompt heartbeat with NO Stop after it is an OPEN
# turn and holds busy (section 2b) — so "stale" is only meaningful for a
# turn that ended.
printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"window":"codexwin"}\n' "$(( now - 600 ))" "$(( now - 600 ))" > "$WORK/hb-stale.json"
printf '{"state":"idle_prompt","last_activity":%s,"window":"codexwin"}\n' "$now" > "$WORK/hb-idle.json"
assert_eq "fresh busy heartbeat + idle screen -> busy" \
    "$(_state "$(_ps --fixture "$FX/codex-idle-real-api.ansi" --heartbeat-file "$WORK/hb-fresh.json" --now "$now")")" "busy"
assert_eq "a CLOSED turn (Stop 600 s ago) + idle screen -> idle" \
    "$(_state "$(_ps --fixture "$FX/codex-idle-real-api.ansi" --heartbeat-file "$WORK/hb-stale.json" --now "$now")")" "idle"
assert_eq "fresh IDLE heartbeat cannot make a working screen idle -> busy" \
    "$(_state "$(_ps --fixture "$FX/codex-busy-working-real-api.ansi" --heartbeat-file "$WORK/hb-idle.json" --now "$now")")" "busy"
assert_eq "fresh busy heartbeat does not override a DIALOG -> blocked" \
    "$(_state "$(_ps --fixture "$FX/codex-blocked-folder-trust.ansi" --heartbeat-file "$WORK/hb-fresh.json" --now "$now")")" "blocked"

echo "=== 2b. skeptic F1/F2: the streaming phase and a surviving background job ==="
# F1's second signal in ISOLATION: the real streaming capture with its
# status-line spinner removed, so only the open-turn heartbeat can hold busy.
python3 - "$FX/codex-busy-streaming-answer.ansi" "$WORK/stream-nospin.ansi" "$WORK/stream-ended.ansi" <<'PYF'
import sys, re
b = open(sys.argv[1], 'rb').read()
nospin = re.sub(rb'\xc2\xb7 \xe2[\xa0-\xa3][\x80-\xbf]', b'', b)
open(sys.argv[2], 'wb').write(nospin)
# ...and the same screen with the turn ENDED by a `■` line after the answer.
open(sys.argv[3], 'wb').write(nospin.replace(b'\n\x1b[1m\xe2\x80\xba\x1b[0m', b'\n\xe2\x96\xa0 Conversation interrupted - tell the model what to do differently.\n\x1b[1m\xe2\x80\xba\x1b[0m', 1))
PYF
LC_ALL=C grep -qaE $'\xc2\xb7 \xe2[\xa0-\xa3]' "$WORK/stream-nospin.ansi" && th_abort "spinner not stripped"
grep -qaF $'\xe2\x96\xa0 Conversation interrupted' "$WORK/stream-ended.ansi" || th_abort "could not plant the terminal line"
printf '{"state":"user_prompt","last_activity":%s,"last_turn_end":null,"window":"codexwin"}\n' "$(( now - 300 ))" > "$WORK/hb-open.json"
assert_eq "F1: the REAL streaming capture reads busy on its own (status-line spinner)" \
    "$(_state "$(LC_ALL=C _ps --fixture "$FX/codex-busy-streaming-answer.ansi")")" "busy"
assert_eq "F1: spinner stripped + an OPEN turn (UserPromptSubmit 300 s ago, no Stop) -> busy" \
    "$(_state "$(_ps --fixture "$WORK/stream-nospin.ansi" --heartbeat-file "$WORK/hb-open.json" --now "$now")")" "busy"
assert_eq "CONTROL: the same screen with NO heartbeat -> idle (the open-turn arm is what holds it)" \
    "$(_state "$(_ps --fixture "$WORK/stream-nospin.ansi")")" "idle"
assert_eq "NO WEDGE: open turn but a \`■\` line after the answer (Esc / failed turn never fire Stop) -> idle" \
    "$(_state "$(_ps --fixture "$WORK/stream-ended.ansi" --heartbeat-file "$WORK/hb-open.json" --now "$now")")" "idle"
printf '{"state":"user_prompt","last_activity":%s,"last_turn_end":null,"window":"codexwin"}\n' "$(( now - 4000 ))" > "$WORK/hb-ancient.json"
assert_eq "BOUNDED: an open turn older than 1800 s no longer holds busy" \
    "$(_state "$(_ps --fixture "$WORK/stream-nospin.ansi" --heartbeat-file "$WORK/hb-ancient.json" --now "$now")")" "idle"
out=$(_ps --fixture "$FX/codex-working-background-after-turn.ansi")
assert_eq       "F2: a finished turn with a background terminal still running -> working-background" "$(_state "$out")" "working-background"
assert_contains "…naming the count" "$out" "bg=1"

echo "=== 3. unrecognised Codex chrome is unknown, never idle ==="
# The real banner (so the harness signature fires) with the composer and the
# spinner removed: a screen whose state this classifier cannot read.
grep -av $'\e\\[1m\xe2\x80\xba' "$FX/codex-idle-real-api.ansi" > "$WORK/no-composer.ansi"
grep -qF '>_ OpenAI Codex (v' <<<"$(sed $'s/\x1b\\[[0-9;]*m//g' "$WORK/no-composer.ansi")" \
    || th_abort "synthetic lost the banner"
grep -qaF $'\e[1m\xe2\x80\xba' "$WORK/no-composer.ansi" && th_abort "synthetic still carries a composer row"
# NO --harness: the BANNER alone must route this screen to the Codex
# classifier. (A raw-byte banner match was dead code; this is its guard.)
out=$(_ps --fixture "$WORK/no-composer.ansi")
assert_eq       "banner only (no --harness), no composer/spinner/dialog -> unknown" "$(_state "$out")" "unknown"
assert_contains "…with the reason named" "$out" "reason=codex-no-composer"
out=$(_ps --fixture "$FX/codex-idle-real-api.ansi" --harness codex --pane-pid 999999999)
assert_eq       "--harness codex does NOT bypass the liveness gate (dead pid -> gate answers)" \
                "$(case "$(_state "$out")" in absent|unknown) echo gate;; *) echo "$(_state "$out")";; esac)" "gate"

echo "=== 4. negative control: no Claude fixture is re-labelled codex ==="
relabelled=0; checked=0
while IFS= read -r -d '' f; do
    base=${f##*/}
    [[ "$base" == codex-* ]] && continue
    checked=$(( checked + 1 ))
    o=$(_ps --fixture "$f")
    if [[ "$o" == *"harness=codex"* ]]; then
        relabelled=$(( relabelled + 1 ))
        printf '    re-labelled: %s -> %s\n' "$base" "$o" >&2
    fi
done < <(find "$FX" -maxdepth 1 -name '*.ansi' -print0)
if (( checked >= 60 )); then assert_eq "corpus non-degenerate (>=60 non-codex fixtures, got $checked)" "ok" "ok"
else assert_eq "corpus non-degenerate (>=60 non-codex fixtures)" "$checked" ">=60"; fi
assert_eq "zero non-Codex fixtures carry harness=codex" "$relabelled" "0"

echo "=== 5. the kill allowlist agrees with the Codex verdicts ==="
# shellcheck source=../_bookkeeping.sh
. "$_self_dir/../_bookkeeping.sh" || th_abort "cannot source _bookkeeping.sh"
authorised=(); refused=()
for f in "$FX"/codex-*.ansi; do
    s=$(_state "$(_ps --fixture "$f")")
    if bk_pane_kill_authorized "$s"; then authorised+=("${f##*/}"); else refused+=("${f##*/}"); fi
done
assert_eq "exactly the five idle captures are kill-authorised" \
    "$(printf '%s\n' "${authorised[@]}" | sort | tr '\n' ' ')" \
    "codex-idle-after-esc-interrupt.ansi codex-idle-after-quota-error.ansi codex-idle-after-streamed-answer.ansi codex-idle-history-user-lines.ansi codex-idle-real-api.ansi "
assert_eq "the other fourteen (busy, blocked, typing, working-background) are all refused" "${#refused[@]}" "14"

EXPECTED_ASSERTIONS=22
TOTAL_ASSERTIONS=$(( PASS + FAIL + ${SKIP:-0} ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
