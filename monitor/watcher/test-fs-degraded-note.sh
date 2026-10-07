#!/usr/bin/env bash
# test-fs-degraded-note.sh — the watcher keeps TALKING while the project tree
# is read-only, through the normal paste path, and never types over an
# operator draft (your-org/nexus-code#1724).
#
#   N1  the note's backoff: first after BASE, then doubling, capped — never
#       silent while the condition holds, never every cycle.
#   N2  a due note names the failing path and its errno (EROFS here, via the
#       probe's writer seam), goes through the paste function with STATE_DIR
#       pointed at the private run dir (NOT the read-only tree) in
#       no-liveness-stamp mode, and the status file records it.
#   N3  THE REFUSAL, through the REAL paste_to_target (main.sh) + pd_deliver
#       (_paste-deliver.sh): an operator draft in the box (input=typed, and
#       input=? undecidable) means NO keystrokes reach tmux, and the refusal is
#       in the log and the status file. N3c is the positive control: a clear
#       box IS pasted into, so N3a/b's silence is the refusal, not a dead rig.
#   N4  the one-shot escalation's last-resort pane notice takes the same path:
#       with every out-of-band channel down and a draft in the box, it types
#       NOTHING (it used to `send-keys -l` the alarm and press Enter).
#   N5  `ng degraded status` (degraded-status.sh) reports the watcher's last
#       word and a live probe, exits 1 while the watcher says degraded, and
#       creates nothing when there is no status file.
#
# Run: bash monitor/watcher/test-fs-degraded-note.sh

set -uo pipefail
if [[ -z "${_FSNOTE_TEST_REEXEC:-}" ]]; then
    export _FSNOTE_TEST_REEXEC=1
    exec env -u NEXUS_ROOT -u NEXUS_LOCALS -u NEXUS_STATE_DIR -u TMUX -u NEXUS_DEGRADED_RUNDIR \
        bash "${BASH_SOURCE[0]}" "$@"
fi

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_dir/.." && pwd)

WORK=$(mktemp -d)
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
if [[ "$(id -u)" == "0" ]]; then
    th_skip "read-only fixtures" "running as root: a 0555 dir is still writable"
    th_summary_and_exit
fi

export NEXUS_DEGRADED_RUNDIR="$WORK/run"   # never the operator's /tmp run dir
LOG="$WORK/watcher.log"; : > "$LOG"
log() { printf '%s\n' "$*" >> "$LOG"; }

# tmux on PATH (a PROGRAM, not a function: pd_pane_verdict refuses to trust a
# function-shadowed tmux). Logs every call; answers list-windows with the target.
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_CALLS:-/dev/null}"
case "$1" in
    list-windows) printf 'orchestrator\n' ;;
    display-message|display) printf '0\n' ;;
esac
exit 0
EOF
# A pane-state stand-in for PD_PANE_STATE_BIN: answers whatever $PS_LINE says.
cat > "$STUB/pane-state" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${PS_LINE:-state=idle active=0 input=blank}"
EOF
chmod +x "$STUB/tmux" "$STUB/pane-state"
export PATH="$STUB:$PATH"
export PD_PANE_STATE_BIN="$STUB/pane-state"

source "$_dir/_lib.sh"
source "$_dir/_fs_guard.sh"

reset_note() { FS_DEGRADED=1; FS_ONSET=$1; FS_NOTE_NEXT=0; FS_NOTE_GAP=0; FS_NOTE_COUNT=0; }

echo '=== N1: backoff — first after BASE, doubling, capped, never silent ==='
export MONITOR_FS_DEGRADED_NOTE_BASE_SECONDS=300 MONITOR_FS_DEGRADED_NOTE_MAX_SECONDS=1200
reset_note 1000
seq_out=""
for t in 1000 1299 1300 1301 1899 1900 3099 3100 4299 4300; do
    if _fs_note_due "$t"; then seq_out+="$t:Y "; else seq_out+="$t:n "; fi
done
assert_eq "N1 due exactly at onset+300, +600, then every 1200 (cap)" "$seq_out" \
    "1000:n 1299:n 1300:Y 1301:n 1899:n 1900:Y 3099:n 3100:Y 4299:n 4300:Y "
reset_note 0; n=0
for (( t = 0; t <= 18 * 3600; t += 15 )); do _fs_note_due "$t" && n=$((n + 1)); done
# 300, 900, 2100, then every 1200 s up to 64800: 3 + floor((64800-2100)/1200) = 55.
assert_eq "N1 an 18 h incident gets 55 notes at 15 s cycles (not 1, not 4320)" "$n" "55"

echo '=== N2: a due note names path + errno and pastes with a PRIVATE STATE_DIR ==='
RO_STATE="$WORK/nexus/monitor/.state"; mkdir -p "$RO_STATE"; chmod 0555 "$RO_STATE"
cat > "$WORK/erofs-writer" <<'EOF'
#!/usr/bin/env bash
echo "bash: $1: Read-only file system" >&2; exit 1
EOF
chmod +x "$WORK/erofs-writer"
stub_paste() {
    printf 'target=%s state_dir=%s mode=%s\n' "$1" "$STATE_DIR" "${3:-}" > "$WORK/paste.args"
    cp "$2" "$WORK/paste.body"
    return "${STUB_PASTE_RC:-0}"
}
reset_note 1000
STATE_DIR="$RO_STATE" TARGET=orchestrator FS_NOTE_PASTE_FN=stub_paste \
    NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_degraded_note_tick 1300
body=$(cat "$WORK/paste.body" 2>/dev/null)
assert_contains "N2 the note names the failing path" "$body" "$RO_STATE"
assert_contains "N2 …and its errno" "$body" "EROFS"
assert_contains "N2 …and where the detail lives" "$body" "ng degraded status"
assert_contains "N2 …and carries an emit signature (receipt-checkable)" "$body" "nexus-emit-sig "
args=$(cat "$WORK/paste.args" 2>/dev/null)
assert_contains "N2 pasted to the target" "$args" "target=orchestrator"
assert_contains "N2 with STATE_DIR = the private run dir, never the read-only tree" "$args" "state_dir=$WORK/run/paste-state"
assert_contains "N2 in no-liveness-stamp mode" "$args" "mode=no-liveness-stamp"
sf=$(_fs_status_path "$RO_STATE")
assert_contains "N2 status file: mode" "$(cat "$sf" 2>/dev/null)" "mode=degraded"
assert_contains "N2 status file: verdict" "$(cat "$sf" 2>/dev/null)" "verdict=EROFS"
assert_contains "N2 status file: delivery" "$(cat "$sf" 2>/dev/null)" "delivery=delivered"
assert_contains "N2 the log line says it went out" "$(cat "$LOG")" "DEGRADED note #1 (EROFS) — delivered"

echo '=== N3: the REAL paste path refuses an operator draft — nothing typed ==='
# main.sh runs its loop at source time, so extract the two functions (the
# test-paste-dead-pane-guard.sh device).
eval "$(sed -n '/^paste_to_target() {/,/^}/p;/^_paste_to_target_unlocked() {/,/^}/p' "$_dir/main.sh")"
declare -F paste_to_target >/dev/null && declare -F _paste_to_target_unlocked >/dev/null \
    && ok=yes || ok=no
assert_eq "N3 fixture: main.sh's paste_to_target was extracted" "$ok" "yes"
# A live pane (the dead-pane guard is not under test here) and no @id lookup.
_tmux_pane_is_dead() { NEXUS_PANE_LIVE_VERDICT=live; return 1; }
resolve_window_id() { return 1; }
source "$MON/_paste-deliver.sh"
export PD_SUBMIT_TIMEOUT_MS=300 PD_ENTER_RETRY_MAX=0

draft_case() {   # <label> <pane-state line>
    reset_note 1000; : > "$LOG"
    export TMUX_CALLS="$WORK/tmux-$1.log"; : > "$TMUX_CALLS"
    PS_LINE="$2" STATE_DIR="$RO_STATE" TARGET=orchestrator \
        NEXUS_DEGRADED_PROBE_WRITER="$WORK/erofs-writer" _fs_degraded_note_tick 1300
}
for c in "a|state=user-typing active=1 input=typed" "b|state=user-typing active=1 input=?" "d|state=busy active=1 input=typed"; do
    lbl="${c%%|*}"; line="${c#*|}"
    draft_case "$lbl" "$line"
    typed=$(grep -cE '^(send-keys|paste-buffer|load-buffer|set-buffer)' "$TMUX_CALLS")
    assert_eq "N3$lbl ($line): NO keystroke or buffer reached tmux" "$typed" "0"
    assert_contains "N3$lbl the refusal is logged" "$(cat "$LOG")" "refused"
    assert_contains "N3$lbl …and recorded for ng degraded status" "$(cat "$(_fs_status_path "$RO_STATE")")" "delivery=refused"
done
# N3c: positive control — a clear box IS pasted into, through the same rig.
draft_case c "state=idle active=0 input=blank"
pasted=$(grep -cE '^(paste-buffer|load-buffer)' "$TMUX_CALLS")
assert_eq "N3c control: a CLEAR box is pasted into (the rig can type)" "$([[ $pasted -ge 1 ]] && echo yes || echo "no ($pasted)")" "yes"
assert_not_contains "N3c …and is not reported refused" "$(cat "$LOG")" "refused"

echo '=== N4: the escalation last resort types NOTHING over a draft ==='
_reset() { FS_DEGRADED=0; FS_ESCALATED=0; FS_CHANNELS=''; FS_DEGRADED_CYCLES=0; FS_ONSET=0; }
_reset; : > "$LOG"
export TMUX_CALLS="$WORK/tmux-n4.log"; : > "$TMUX_CALLS"
# Every out-of-band channel down: no sandbox-notify on PATH, GitHub refused.
_nexus_critical_alarm() { return 1; }
_nexus_github_incident_escalate() { return 1; }
PS_LINE="state=user-typing active=1 input=typed" STATE_DIR="$RO_STATE" \
    NEXUS_ROOT="$WORK/nexus" TARGET=orchestrator _fs_escalate_once
typed=$(grep -cE '^(send-keys|paste-buffer|load-buffer)' "$TMUX_CALLS")
assert_eq "N4 no send-keys/paste reached tmux over an operator draft" "$typed" "0"
assert_contains "N4 the last-resort refusal is logged" "$(cat "$LOG")" "last-resort pane notice — refused"
assert_not_contains "N4 the refused notice is not credited as a channel" "$FS_CHANNELS" "tmux-paste"

echo '=== N5: ng degraded status ==='
chmod 0755 "$RO_STATE"
FR="$WORK/nexus"; mkdir -p "$FR/monitor/.state/skeptic/pending" "$FR/monitor/.state/longjob" \
    "$FR/monitor/.state/requests" "$FR/reports" "$FR/work"
out=$(NEXUS_ROOT="$FR" NEXUS_STATE_DIR="$RO_STATE" bash "$MON/degraded-status.sh" 2>&1); rc=$?
assert_eq "N5 the watcher's last word is DEGRADED ⇒ rc 1 even though the probe is OK now" "$rc" "1"
assert_contains "N5 shows the watcher's status file" "$out" "mode=degraded"
assert_contains "N5 shows the live probe" "$out" "summary:"
assert_contains "N5 says the two disagree" "$out" "last word is DEGRADED but every surface probes OK"
STATE_DIR="$RO_STATE" _fs_status_write mode=ok "state_dir=$RO_STATE"
out=$(NEXUS_ROOT="$FR" NEXUS_STATE_DIR="$RO_STATE" bash "$MON/degraded-status.sh" 2>&1); rc=$?
assert_eq "N5 watcher ok + probe OK ⇒ rc 0" "$rc" "0"
out=$(NEXUS_DEGRADED_RUNDIR="$WORK/never" NEXUS_ROOT="$FR" NEXUS_STATE_DIR="$RO_STATE" \
      bash "$MON/degraded-status.sh" 2>&1); rc=$?
assert_eq "N5 no status file ⇒ rc 0 (probe OK)" "$rc" "0"
assert_eq "N5 …and the run dir was NOT created (status writes nothing)" "$([[ -e "$WORK/never" ]] && echo created || echo absent)" "absent"
out=$(bash "$MON/ng" degraded status --help 2>&1); rc=$?
assert_eq "N5 ng routes 'degraded status' (usage rc 2, not 'not implemented')" "$rc" "2"

# EXPECTED-COUNT GUARD (test-summary-honesty-manifest.sh, count=exact): a
# dropped or added assertion is a FAIL, never a quieter green.
#   N1 2 | N2 11 | N3 fixture 1 + 3 drafts x 3 + N3c 2 | N4 3 | N5 8. The root path
#   exits at its th_skip before any assertion, so it never reaches this guard.
EXPECTED=$(( 2 + 11 + 12 + 3 + 8 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected.\n' "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
