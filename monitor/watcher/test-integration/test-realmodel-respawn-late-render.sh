#!/usr/bin/env bash
# test-realmodel-respawn-late-render.sh — the orchestrator-respawn brief whose
# paste RENDERS LATE, against the REAL Claude Code binary
# (your-org/nexus-code#1715).
#
# THE INCIDENT. A resumed orchestrator took the paste + Enter while it was
# still loading. The post-paste verify (3 s) never saw `busy`; the one box
# check after it read a POSITIVE non-typed state (`working-background
# input=blank`) and `_respawn_box_is_brief` arm 4 answered "nothing of ours is
# positively in the input box" → rc 4 UNDELIVERED. Seconds later the TUI drew
# the paste as `[Pasted text #N +K lines]`, which pane-state reads as
# `user-typing input=typed`, and from then on every emit was refused by the
# #1674 draft gate (`occupied-before-paste`, rc 7) — the watcher's own brief
# withholding the watcher's own emits, with nothing to submit it.
#
# THE SHAPE UNDER TEST is "the box reads blank at the verify verdict, and OUR
# paste lands in it afterwards". The #1674 `load` arm of
# test-realmodel-respawn-verify.sh covers the INDETERMINATE half (`empty` →
# strict loop waits); this suite covers the POSITIVE-blank half, which the
# first, NON-strict box check turns into a final verdict.
#
# THE LATENCY IS A RIG SEAM, STATED. Reproducing it by load needs a
# multi-GB transcript (the #1674 arm: 2.4 GB, and even then the reading is
# `empty`, not `idle input=blank`), and production's `working-background`
# comes from the heartbeat route + a live supervisor Monitor, which the mock
# backend cannot arm (plugin monitors are GrowthBook-gated). So the fault is
# injected at the TRANSPORT: a PATH-front `tmux` shim DEFERS the subject's one
# `paste-buffer` by RV_LATE_S seconds (default 9) and lets everything else —
# the `i BSpace`, the paste's own Enter, every probe — through untouched. The
# real binary then does what the resumed TUI did: an Enter on an empty box is
# ignored, the box reads `idle input=blank`, and the paste arrives later and is
# drawn as a placeholder chip. COVERAGE BOUNDARY: this proves the subject's
# handling of "blank at verdict, ours later"; it does not prove that a real
# resume produces that ordering (watcher.log 2026-10-01 09:00:38-56 is the
# evidence for that), nor the `working-background` token specifically — arm 4
# treats `idle`, `working-background` and `autosuggest-only` identically.
#
# ARMS
#   late   our brief lands late. MUST be submitted exactly once (one transcript
#          record) and the subject must not report UNDELIVERED. RED at
#          648f38f3: rc 4, zero records, the brief stranded in the box.
#   draft  NEGATIVE (#1674's invariant). An OPERATOR DRAFT lands late instead
#          of our paste. MUST NOT be submitted: rc 4, no record, no Enter of
#          the subject's beyond the paste's own, and the draft still in the box.
#          Green at base too — it is the guard a fix must keep green.
#
# SURFACES DRIVEN (gate-coverage.tsv): monitor/watcher/_respawn.sh, and through
# it monitor/_paste-deliver.sh (pd_paste_file pastes the brief, pd_box_is_ours
# is the equality behind every Enter) and monitor/pane-state.sh (every reading,
# via cch_pane_state).
#
# Gated on RUN_CC_HARNESS=1; self-skips (77) otherwise.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"
# CCH_SUBJECT_MON: drive another tree's monitor/ (potency seam), rig stays ours.
MON="${CCH_SUBJECT_MON:-$(cd "$_self_dir/../.." && pwd)}"
LATE_S="${RV_LATE_S:-9}"
[[ "$LATE_S" =~ ^[0-9]+$ ]] || LATE_S=9

cch_skip_if_disabled
cch_setup

echo "=== real-binary harness: respawn brief rendered LATE (#1715) ==="
echo "    subject: $MON/watcher/_respawn.sh  (git: $(git -C "$MON" rev-parse --short HEAD 2>/dev/null || echo '?'))"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT   late-paste delay: ${LATE_S}s"

nreq() { local n; n=$(command grep -c '  REQ ' "$CCH_LOG" 2>/dev/null); echo "${n:-0}"; }
_transcripts() { local f; for f in "$CCH_CFG"/projects/*/*.jsonl; do [[ -f "$f" ]] && printf '%s\n' "$f"; done; }
nrec() {
    _transcripts | while IFS= read -r _t; do cat -- "$_t"; done | jq -c '
        select((.type=="user" and has("promptSource") and .promptSource!="system" and .promptSource!="sdk")
               or (.type=="queue-operation" and .operation=="enqueue")) | 1' 2>/dev/null | wc -l | tr -d ' '
}
newest_sid() {
    local f newest=""
    while IFS= read -r f; do [[ -z "$newest" || "$f" -nt "$newest" ]] && newest="$f"; done < <(_transcripts)
    newest="${newest##*/}"; printf '%s' "${newest%.jsonl}"
}
grew_by() { echo $(( $1 - $2 )); }

# ---- the binary the launcher execs (same rig seam as #1622's suite) ---------
RV_CLAUDE="$CCH_DIR/.bin/claude-rv"
{
    printf '#!/usr/bin/env bash\n'
    printf 'exec env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q TMUX_TMPDIR=%q ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 TERM=%q %q "$@"\n' \
        "$CCH_CFG" "$PATH" "$CCH_CFG" "$CCH_TMUX_TMPDIR" "http://127.0.0.1:$CCH_MOCK_PORT" \
        "${TERM:-xterm-256color}" "$CLAUDE_BIN"
} > "$RV_CLAUDE"
chmod +x "$RV_CLAUDE"

mkdir -p "$CCH_WORKDIR/monitor"
ln -sfn "$MON/_claude-bin.sh" "$CCH_WORKDIR/monitor/_claude-bin.sh"
printf '#!/usr/bin/env bash\n# cc-harness stub: a hermetic pane has no operator shims; not under test\nexit 0\n' \
    > "$CCH_WORKDIR/monitor/assert-shims-wrapped.sh"
chmod +x "$CCH_WORKDIR/monitor/assert-shims-wrapped.sh"

# ---- the pane reader: production pane-state.sh, every reading traced --------
cat > "$CCH_DIR/.bin/rv-pane-state" <<EOF
#!/usr/bin/env bash
. $(printf '%q' "$_self_dir/../../cc-harness/_lib.sh") || exit 1
out=\$(cch_pane_state "\$1"); rc=\$?
printf '%s PS %s\n' "\$(date +%s.%N)" "\$out" >> "\$(cat $(printf '%q' "$CCH_DIR/cur-trace"))"
printf '%s\n' "\$out"
exit \$rc
EOF
chmod +x "$CCH_DIR/.bin/rv-pane-state"

# ---- the transport fault shim -----------------------------------------------
# Fault file: `<mode> <delay-s>`, mode `late` | `draft` | `none`.
#   late   the paste-buffer is performed <delay> s later, in the background.
#   draft  the paste-buffer is REPLACED by an operator draft typed <delay> s later.
mkdir -p "$CCH_DIR/.bin-rv"
cat > "$CCH_DIR/.bin-rv/tmux" <<EOF
#!/usr/bin/env bash
# cc-harness fault shim (#1715) — never "the real tmux".
T=\$(cat $(printf '%q' "$CCH_DIR/cur-trace")); F=$(printf '%q' "$CCH_DIR/fault")
REAL=$(printf '%q' "$CCH_DIR/.bin/tmux")
read -r mode delay < "\$F" 2>/dev/null || { mode=none; delay=0; }
ts() { date +%s.%N; }
if [[ "\$1" == send-keys && "\${!#}" == Enter ]]; then
    echo "\$(ts) ENTER sent" >> "\$T"
fi
if [[ "\$1" == paste-buffer && ( "\$mode" == late || "\$mode" == draft ) ]]; then
    args=("\$@"); tgt="" buf=""; shift
    while (( \$# )); do case "\$1" in -t) tgt="\$2"; shift 2 ;; -b) buf="\$2"; shift 2 ;; *) shift ;; esac; done
    echo "\$(ts) PASTE deferred mode=\$mode delay=\${delay}s" >> "\$T"
    (
        exec </dev/null >/dev/null 2>&1
        sleep "\$delay"
        if [[ "\$mode" == late ]]; then
            "\$REAL" "\${args[@]}"; echo "\$(ts) PASTE landed rc=\$?" >> "\$T"
        else
            "\$REAL" delete-buffer -b "\$buf"
            "\$REAL" send-keys -t "\$tgt" -l "operator draft: hold the release until I confirm"
            echo "\$(ts) DRAFT landed rc=\$?" >> "\$T"
        fi
    ) &
    exit 0
fi
exec "\$REAL" "\$@"
EOF
chmod +x "$CCH_DIR/.bin-rv/tmux"

rv_brief() {   # a recovery-brief-shaped body: 14 lines, collapses to a chip
    local i
    # RV_BRIEF_FILE: drive the arms with a REAL payload instead (diagnosis seam,
    # e.g. the 101-line situation report of #1715's second instance).
    if [[ -n "${RV_BRIEF_FILE:-}" ]]; then cp -- "$RV_BRIEF_FILE" "$1"; return; fi
    {
        printf '=== orchestrator recovery brief (%s) ===\n' "$2"
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
            printf -- '- item %02d: you were respawned by the watcher; resume the open work listed in the dashboard and re-read the reports\n' "$i"
        done
        printf -- '--- end of brief %06x ---\n' "$RANDOM"
    } > "$1"
}

_drive() {   # _drive <sid> <prompt-file> — inside cch_with_tmux_env's subshell
    set +u
    export PATH="$CCH_DIR/.bin-rv:$PATH"
    export NEXUS_ROOT="$CCH_WORKDIR" NEXUS_STATE_DIR="$CCH_STATE_DIR" STATE_DIR="$CCH_STATE_DIR" CLAUDE_BIN="$RV_CLAUDE"
    export PANE_STATE_BIN="$CCH_DIR/.bin/rv-pane-state" MONITOR_LONGJOB_ENABLED=0
    export RESPAWN_TMPDIR="$CCH_DIR"
    rv_log() { printf '%s LOG %s\n' "$(date +%s.%N)" "$*" >> "$(cat "$CCH_DIR/cur-trace")"; }
    . "$MON/watcher/_respawn.sh"
    _respawn_orchestrator orchestrator --force-replace --resume-sid "$1" --prompt-file "$2" --log-fn rv_log
}

WIN=""
boot_orch() {   # boot_orch <arm>
    printf '%s' "$CCH_DIR/trace-$1" > "$CCH_DIR/cur-trace"; : > "$CCH_DIR/trace-$1"
    cch_control '{"mode":"text","text":"MOCK_OK_HELLO"}'
    WIN=$(cch_boot_worker orchestrator)
    [[ -n "$WIN" ]] || { echo "FAIL: orchestrator window never appeared" >&2; exit 1; }
    wait_for "$1: boots to idle" 40 -- cch_state_is "$WIN" idle
    cch_send "$WIN" "warm up turn"
    sleep 2
    wait_for "$1: idle after the warm-up turn" 40 -- cch_state_is "$WIN" idle
    sleep 1
    SID=$(newest_sid)
    cch_control '{"mode":"text","text":"brief acknowledged one two three four five six","drip_ms":500}'
}
cur_win() { cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' | awk '$1=="orchestrator"{print $2; exit}'; }
close_orch() { local w; w=$(cur_win); [[ -n "$w" ]] && cch_tmux kill-window -t "$CCH_SESSION:$w" 2>/dev/null; sleep 1; }
arm_version() { local v; v=$("$RV_CLAUDE" --version 2>/dev/null) || v="?"; echo "  NOTE: $1: claude → ${v%%$'\n'*}"; }

# PRECONDITION, per arm: some reading AFTER the readiness verdict and BEFORE the
# late bytes landed said `input=blank` — i.e. the subject really did look at an
# empty box first. Without it the arm did not reproduce #1715 and tests nothing.
blank_before_landing() {   # <trace> <landed-tag>
    awk -v tag="$2" '/ LOG input-ready probe/{on=1; next}
         $0 ~ (" " tag " landed") {exit}
         on && / PS / && /input=blank/ {n++}
         END{print n+0}' "$1"
}
report_arm() { echo "  NOTE: $1: trace:"; sed 's/^[0-9.]* /           /' "$2" | cut -c1-230; }

# ---- late: OUR brief lands after the verify window ---------------------------
arm_version late
boot_orch late
rv_brief "$CCH_DIR/b-late" late
echo "late $LATE_S" > "$CCH_DIR/fault"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive "$SID" "$CCH_DIR/b-late"; rc=$?
# Let the late paste land and whatever the subject (or nothing) does settle.
sleep $(( LATE_S + 6 ))
settled() { cch_state_is "$1" idle || cch_state_is "$1" user-typing; }
wait_for "late: the pane settles (idle = submitted+answered; user-typing = stranded)" 60 -- settled "$(cur_win)"
TR="$CCH_DIR/trace-late"
report_arm late "$TR"
echo "  NOTE: late: final pane-state: $(cch_pane_state "$(cur_win)" 2>/dev/null)"
echo "  NOTE: late: final input row:  $(cch_tmux capture-pane -p -t "$CCH_SESSION:$(cur_win)" -S -40 2>/dev/null | LC_ALL=C awk 'index($0, "\342\235\257") == 1 { r = $0 } END { print r }')"
assert_eq "late: the rig DEFERRED our paste (or this arm tests nothing)" "$(command grep -c ' PASTE deferred mode=late' "$TR")" "1"
assert_eq "late: the deferred paste DID land" "$(command grep -c ' PASTE landed rc=0' "$TR")" "1"
assert_eq "late: PRECONDITION — the subject read a BLANK box before our paste landed" "$(( $(blank_before_landing "$TR" PASTE) > 0 ))" "1"
assert_eq "late: _respawn_orchestrator does NOT report UNDELIVERED (rc 0)" "$rc" "0"
assert_eq "late: exactly ONE submission recorded — the late-rendered brief was submitted once" "$(grew_by "$(nrec)" "$s0")" "1"
assert_eq "late: exactly ONE request reached the backend" "$(grew_by "$(nreq)" "$r0")" "1"
assert_not_contains "late: the subject did not give up on a blank box" "$(cat "$TR")" "nothing of ours is positively in the input box"
close_orch

# ---- draft: an OPERATOR draft lands instead (#1674 must hold) ----------------
arm_version draft
boot_orch draft
rv_brief "$CCH_DIR/b-draft" draft
echo "draft $LATE_S" > "$CCH_DIR/fault"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive "$SID" "$CCH_DIR/b-draft"; rc=$?
sleep $(( LATE_S + 6 ))
TR="$CCH_DIR/trace-draft"
report_arm draft "$TR"
assert_eq "draft: the rig typed the draft late (or this arm tests nothing)" "$(command grep -c ' DRAFT landed rc=0' "$TR")" "1"
assert_eq "draft: _respawn_orchestrator reports UNDELIVERED (rc 4)" "$rc" "4"
assert_eq "NEGATIVE: NO submission recorded — the operator draft was not sent" "$(grew_by "$(nrec)" "$s0")" "0"
assert_eq "NEGATIVE: NO request reached the backend" "$(grew_by "$(nreq)" "$r0")" "0"
assert_eq "draft: the subject pressed NO Enter beyond the paste's own" "$(command grep -c ' ENTER sent' "$TR")" "1"
wait_for "draft: the draft is still in the box (user-typing)" 20 -- cch_state_is "$(cur_win)" user-typing
close_orch

# ---- assertion-count guard ----------------------------------------------------
# 2 arms × boot_orch's 2 waits = 4; late 1 wait + 7 = 8; draft 5 + 1 wait = 6.
EXPECTED_ASSERTIONS=18
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
assert_eq "assertion TOTAL matches EXPECTED_ASSERTIONS — no assertion silently dropped or added" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
