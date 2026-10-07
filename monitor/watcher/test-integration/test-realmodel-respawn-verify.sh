#!/usr/bin/env bash
# test-realmodel-respawn-verify.sh — the ORCHESTRATOR-RESPAWN verify stage
# against the REAL Claude Code binary (your-org/nexus-code#1622).
#
# WHY. `_respawn_orchestrator`'s post-paste verify is the path where NOTHING
# supervises the Enter: the orchestrator is the thing being respawned. #1596
# rewrote its retry (`_respawn_box_is_brief`) so an Enter is pressed only on
# `state=user-typing input=typed` AND a box that IS the pasted brief — plus ONE
# Enter on an INDETERMINATE reading (`empty`, `unknown`, "") — and it shipped
# with hermetic coverage only (test-respawn.sh's R96-* rows over a stub). The
# central claim is a claim about the binary; this scenario is where it is
# measured. It drives production `_respawn_orchestrator` END TO END — compose
# the launcher, kill + new-window, readiness probe, bracketed paste, Enter,
# verify — against a real pane, with `--force-replace --resume-sid`, which is
# the shape spawn-fresh-orchestrator.sh uses.
#
# THREE POINTS, one per arm (issue #1622 "What a scenario here would need"):
#   ctl    no fault. RECORDS what production pane-state.sh reads after the
#          readiness probe and in the verify window, and ASSERTS (in every
#          arm) that the verify window read nothing outside the observed set
#          {idle, busy, user-typing} — so if a release starts presenting
#          `empty`/`unknown` there this goes red and the INDETERMINATE arm of
#          `_respawn_box_is_brief` has become load-bearing. Also: exactly one
#          request, one record, one Enter.
#   drop   the paste's own Enter is DROPPED (rig fault injection, below). The
#          brief sits in the box; the verify stage must recover it with its
#          retry Enter: rc 0, exactly ONE request, ONE record — submitted
#          once, not twice.
#   draft  NEGATIVE ARM (#1596's other half). The paste is replaced by an
#          OPERATOR DRAFT typed into the freshly respawned window, and the
#          paste's Enter is dropped. The verify stage must NOT submit it:
#          rc 4 (UNDELIVERED), NO request, NO record, the subject pressed no
#          Enter beyond the dropped one, and the draft is still in the box.
#          It is also the instrument's negative control: the request/record
#          counters are shown able to say NO.
#   load   (your-org/nexus-code#1674) no rig fault: the session transcript is
#          inflated so the RESUME is still loading when the paste and its Enter
#          arrive. The Enter is lost, the pane reads `empty`, and the brief
#          later shows in the box. ONE record (rc and requests are NOTES; see the arm), and the
#          verify stage must be seen WAITING on the indeterminate reading.
#
# THE FAULT IS INJECTED AT THE TRANSPORT, NOT IN THE SUBJECT. A PATH-front
# `tmux` shim (rig-owned, $CCH_DIR/.bin-rv) sits ahead of the harness's
# socket-pinned tmux ONLY inside the driving subshell. It counts every
# `send-keys … Enter` the subject makes, swallows the first N (N from the
# arm's fault file), and in the `draft` arm replaces the `paste-buffer` with
# a literal `send-keys -l` of the draft. Everything else passes through. The
# subject code is never edited, so a CCH_SUBJECT_MON tree is driven unmodified.
#
# RIG SEAMS, stated (none is the subject):
#   * CLAUDE_BIN is a wrapper that `env -i`s the mock-backend environment and
#     execs the real binary — the launcher `exec`s $CLAUDE_BIN from a pane on
#     the harness server, whose environment is not the mock's. Every arm reads
#     `--version` THROUGH THAT WRAPPER — the binary the launcher invokes — and
#     prints it (the #1622 rule: never infer the version from behaviour).
#   * NEXUS_ROOT is the harness workdir (so `--resume` finds the session: the
#     project dir is keyed on cwd, and the launcher runs in NEXUS_ROOT). It
#     carries `monitor/_claude-bin.sh` (a symlink into the subject tree) and a
#     STUB `assert-shims-wrapped.sh`: the launcher's shim guard checks the
#     operator's PATH-front shims, which a hermetic pane does not have and
#     which this scenario does not test. No orchestrator-settings.json, so no
#     `--settings` (the harness's user settings — vim mode — apply).
#   * MONITOR_LONGJOB_ENABLED=0: no `--plugin-dir`; plugin monitors never arm
#     under the mock anyway, and #1611 is its own scenario's business.
#   * PANE_STATE_BIN is a reader that asks production pane-state.sh about THIS
#     harness window through `cch_pane_state` (the one place the socket pins
#     live) and appends each reading to the arm's trace.
#   * The mock DRIPS its reply (~3 s) so a submitted turn is visible as `busy`:
#     `_respawn_wait_for_submit_evidence` polls every 0.5 s and its own comment
#     states that a turn finishing inside one poll gap reads UNDELIVERED.
#
# Drives production monitor/watcher/_respawn.sh (`_respawn_orchestrator`,
# `_respawn_box_is_brief`) and monitor/_paste-deliver.sh. Asserts pane-state
# `idle`, `busy` and `user-typing` on real harness bytes.
#
# Gated on RUN_CC_HARNESS=1; self-skips otherwise. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"
# CCH_SUBJECT_MON points the DRIVEN code at another tree's monitor/ — the
# potency seam: aimed at a tree whose verify never sends the recovery Enter,
# the `drop` arm goes RED. The rig (harness, helpers, pane reader) stays this
# tree's.
MON="${CCH_SUBJECT_MON:-$(cd "$_self_dir/../.." && pwd)}"

cch_skip_if_disabled
cch_setup

echo "=== real-binary harness: the orchestrator-respawn verify stage (#1622) ==="
echo "    subject: $MON/watcher/_respawn.sh"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"

nreq() { local n; n=$(command grep -c '  REQ ' "$CCH_LOG" 2>/dev/null); echo "${n:-0}"; }
# Loops over the glob, never `cat <glob>`: under an ambient `nullglob` an
# unmatched glob VANISHES and a bare `cat` reads STDIN (nullglob-bare-form).
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

# ---- the binary the launcher execs ------------------------------------------
RV_CLAUDE="$CCH_DIR/.bin/claude-rv"
{
    printf '#!/usr/bin/env bash\n'
    printf '# cc-harness: the mock-backend environment around the real binary (#1622 rig seam)\n'
    printf 'exec env -i HOME=%q PATH=%q CLAUDE_CONFIG_DIR=%q TMUX_TMPDIR=%q ANTHROPIC_BASE_URL=%q ANTHROPIC_AUTH_TOKEN=mock-token CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1 DISABLE_BUG_COMMAND=1 TERM=%q %q "$@"\n' \
        "$CCH_CFG" "$PATH" "$CCH_CFG" "$CCH_TMUX_TMPDIR" "http://127.0.0.1:$CCH_MOCK_PORT" \
        "${TERM:-xterm-256color}" "$CLAUDE_BIN"
} > "$RV_CLAUDE"
chmod +x "$RV_CLAUDE"

# ---- the synthetic nexus root -----------------------------------------------
mkdir -p "$CCH_WORKDIR/monitor"
ln -sfn "$MON/_claude-bin.sh" "$CCH_WORKDIR/monitor/_claude-bin.sh"
printf '#!/usr/bin/env bash\n# cc-harness stub: a hermetic pane has no operator shims; not under test (#1622)\nexit 0\n' \
    > "$CCH_WORKDIR/monitor/assert-shims-wrapped.sh"
chmod +x "$CCH_WORKDIR/monitor/assert-shims-wrapped.sh"

# ---- the pane reader --------------------------------------------------------
# $1 is the window INDEX `_respawn_probe_raw` resolved; every reading is
# appended to the arm's trace as `PS <line>`.
cat > "$CCH_DIR/.bin/rv-pane-state" <<EOF
#!/usr/bin/env bash
. $(printf '%q' "$_self_dir/../../cc-harness/_lib.sh") || exit 1
out=\$(cch_pane_state "\$1"); rc=\$?
printf 'PS %s\n' "\$out" >> "\$(cat $(printf '%q' "$CCH_DIR/cur-trace"))"
printf '%s\n' "\$out"
exit \$rc
EOF
chmod +x "$CCH_DIR/.bin/rv-pane-state"

# ---- the transport fault shim -----------------------------------------------
# Fault file: `<enters-to-drop> <mode>`, mode `none` | `draft`.
mkdir -p "$CCH_DIR/.bin-rv"
cat > "$CCH_DIR/.bin-rv/tmux" <<EOF
#!/usr/bin/env bash
# cc-harness fault shim (#1622) — never "the real tmux".
T=\$(cat $(printf '%q' "$CCH_DIR/cur-trace")); F=$(printf '%q' "$CCH_DIR/fault")
REAL=$(printf '%q' "$CCH_DIR/.bin/tmux")
read -r drop mode < "\$F" 2>/dev/null || { drop=0; mode=none; }
if [[ "\$1" == send-keys && "\${!#}" == Enter ]]; then
    if (( drop > 0 )); then
        printf '%s %s\n' "\$(( drop - 1 ))" "\$mode" > "\$F"
        echo "ENTER dropped" >> "\$T"; exit 0
    fi
    echo "ENTER sent" >> "\$T"
fi
if [[ "\$1" == paste-buffer && "\$mode" == draft ]]; then
    tgt="" buf=""; shift
    while (( \$# )); do case "\$1" in -t) tgt="\$2"; shift 2 ;; -b) buf="\$2"; shift 2 ;; *) shift ;; esac; done
    "\$REAL" delete-buffer -b "\$buf" 2>/dev/null
    echo "PASTE replaced-by-draft" >> "\$T"
    exec "\$REAL" send-keys -t "\$tgt" -l "operator draft: hold the release until I confirm"
fi
exec "\$REAL" "\$@"
EOF
chmod +x "$CCH_DIR/.bin-rv/tmux"

rv_brief() {   # rv_brief <file> <marker> — a recovery-brief-shaped body (collapses to a placeholder)
    local i
    {
        printf '=== orchestrator recovery brief (%s) ===\n' "$2"
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
            printf -- '- item %02d: you were respawned by the watcher; resume the open work listed in the dashboard and re-read the reports\n' "$i"
        done
        printf -- '--- end of brief %06x ---\n' "$RANDOM"
    } > "$1"
}

# Runs INSIDE cch_with_tmux_env's subshell. Production _respawn.sh is SOURCED
# (it is side-effect-free at source time by contract) from the subject tree.
_drive() {   # _drive <sid> <prompt-file>
    set +u
    export PATH="$CCH_DIR/.bin-rv:$PATH"
    export NEXUS_ROOT="$CCH_WORKDIR" NEXUS_STATE_DIR="$CCH_STATE_DIR" CLAUDE_BIN="$RV_CLAUDE"
    export PANE_STATE_BIN="$CCH_DIR/.bin/rv-pane-state" MONITOR_LONGJOB_ENABLED=0
    export RESPAWN_TMPDIR="$CCH_DIR"
    rv_log() { printf 'LOG %s\n' "$*" >> "$(cat "$CCH_DIR/cur-trace")"; }
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
    # A reply that lasts ~3 s, so the submitted brief is visible as `busy`.
    cch_control '{"mode":"text","text":"brief acknowledged one two three four five six","drip_ms":500}'
}
cur_win() { cch_tmux list-windows -t "$CCH_SESSION" -F '#{window_name} #{window_index}' | awk '$1=="orchestrator"{print $2; exit}'; }
close_orch() { local w; w=$(cur_win); [[ -n "$w" ]] && cch_tmux kill-window -t "$CCH_SESSION:$w" 2>/dev/null; sleep 1; }

# Per-arm readout of the trace. `verify` = every reading after the readiness
# probe logged its verdict (the verify window + the box checks).
states_after_ready() {
    awk '/^LOG input-ready probe/{on=1; next} on && /^PS /{ for(i=2;i<=NF;i++) if($i ~ /^state=/){ sub(/^state=/,"",$i); print ($i==""?"<empty-token>":$i) } }' "$1"
}
states_ready() {
    awk '/^LOG input-ready probe/{exit} /^PS /{ for(i=2;i<=NF;i++) if($i ~ /^state=/){ sub(/^state=/,"",$i); print $i } }' "$1"
}
rle() { uniq -c | awk '{printf "%s%s×%s", (NR>1?" → ":""), $2, $1} END{print ""}'; }
# The verify window's OBSERVED vocabulary on 2.1.280, measured over 3 runs x 3
# arms (27 readings): only `idle`, `busy`, `user-typing` — `idle` appearing
# as a one-poll transient between a recovery Enter and `busy`. Everything else
# counts as outside, INDETERMINATE (`empty`, `unknown`, no `state=` at all —
# `_respawn_box_is_brief` arm 2) first among them: a release that starts
# presenting it here makes that arm load-bearing, and this goes red.
n_outside() {
    awk '/^LOG input-ready probe/{on=1; next}
         on && /^PS /{ s=""; for(i=2;i<=NF;i++) if($i ~ /^state=/){ s=substr($i,7) }
                       if (s!="idle" && s!="busy" && s!="user-typing") c++ }
         END{print c+0}' "$1"
}
arm_version() {   # the binary THIS arm's launcher execs, read through the same wrapper
    local v; v=$("$RV_CLAUDE" --version 2>/dev/null) || v="?"
    echo "  NOTE: $1: claude = $CLAUDE_BIN via $RV_CLAUDE → ${v%%$'\n'*}"
}
report_arm() {   # report_arm <arm> <trace>
    echo "  NOTE: $1: readiness readings: $(states_ready "$2" | rle)"
    echo "  NOTE: $1: verify-window readings: $(states_after_ready "$2" | rle)"
    echo "  NOTE: $1: subject log:"; command grep -F 'LOG ' "$2" | sed 's/^LOG /           /'
}

# ---- ctl: no fault ----------------------------------------------------------
arm_version ctl
boot_orch ctl
rv_brief "$CCH_DIR/b-ctl" ctl
echo "0 none" > "$CCH_DIR/fault"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive "$SID" "$CCH_DIR/b-ctl"; rc=$?
wait_for "ctl: the respawned pane returns to idle" 40 -- cch_state_is "$(cur_win)" idle
sleep 1
TR="$CCH_DIR/trace-ctl"
report_arm ctl "$TR"
assert_eq "ctl: _respawn_orchestrator reports delivered (rc 0)" "$rc" "0"
assert_eq "ctl: exactly ONE request reached the backend" "$(grew_by "$(nreq)" "$r0")" "1"
assert_eq "ctl: exactly ONE submission was recorded" "$(grew_by "$(nrec)" "$s0")" "1"
assert_eq "ctl: the subject pressed exactly one Enter (the paste's own)" "$(command grep -cx 'ENTER sent' "$TR")" "1"
assert_contains "ctl: the verify window SAW the turn run (busy)" "$(states_after_ready "$TR" | sort -u | tr '\n' ' ')" "busy"
# POINT 2 of #1622: the INDETERMINATE arm's reachability, on this binary.
assert_eq "ctl: NO reading outside {idle,busy,user-typing} in the verify window — none INDETERMINATE (empty/unknown/none)" "$(n_outside "$TR")" "0"
close_orch

# ---- drop: the paste's Enter is lost ----------------------------------------
arm_version drop
boot_orch drop
rv_brief "$CCH_DIR/b-drop" drop
echo "1 none" > "$CCH_DIR/fault"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive "$SID" "$CCH_DIR/b-drop"; rc=$?
wait_for "drop: the respawned pane returns to idle" 40 -- cch_state_is "$(cur_win)" idle
sleep 1
TR="$CCH_DIR/trace-drop"
report_arm drop "$TR"
assert_eq "drop: the rig DID drop the paste's Enter (or this arm tests nothing)" "$(command grep -cx 'ENTER dropped' "$TR")" "1"
assert_contains "drop: with the Enter lost, the box read user-typing (the brief, unsubmitted)" "$(states_after_ready "$TR" | sort -u | tr '\n' ' ')" "user-typing"
assert_eq "drop: _respawn_orchestrator reports delivered (rc 0)" "$rc" "0"
assert_eq "drop: exactly ONE request — the brief was submitted once, not twice" "$(grew_by "$(nreq)" "$r0")" "1"
assert_eq "drop: exactly ONE submission was recorded" "$(grew_by "$(nrec)" "$s0")" "1"
assert_eq "drop: the verify stage pressed exactly one recovery Enter" "$(command grep -cx 'ENTER sent' "$TR")" "1"
assert_contains "drop: the recovery Enter was earned by the brief in the box" "$(cat "$TR")" "the brief is IN the input box"
assert_eq "drop: NO reading outside {idle,busy,user-typing} in the verify window — none INDETERMINATE (empty/unknown/none)" "$(n_outside "$TR")" "0"
close_orch

# ---- draft: an operator draft in the same window is NOT submitted -----------
arm_version draft
boot_orch draft
rv_brief "$CCH_DIR/b-draft" draft
echo "1 draft" > "$CCH_DIR/fault"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive "$SID" "$CCH_DIR/b-draft"; rc=$?
sleep 5
TR="$CCH_DIR/trace-draft"
report_arm draft "$TR"
assert_eq "draft: the rig DID replace the paste with a draft (or this arm tests nothing)" "$(command grep -cx 'PASTE replaced-by-draft' "$TR")" "1"
assert_eq "draft: _respawn_orchestrator reports UNDELIVERED (rc 4)" "$rc" "4"
assert_eq "NEGATIVE: NO request reached the backend — the draft was not submitted" "$(grew_by "$(nreq)" "$r0")" "0"
assert_eq "NEGATIVE: …and NO submission was recorded" "$(grew_by "$(nrec)" "$s0")" "0"
assert_eq "draft: the verify stage pressed NO Enter of its own" "$(command grep -cx 'ENTER sent' "$TR")" "0"
assert_contains "draft: the refusal names its reason" "$(cat "$TR")" "not shown to be the brief"
assert_eq "draft: NO reading outside {idle,busy,user-typing} in the verify window — none INDETERMINATE (empty/unknown/none)" "$(n_outside "$TR")" "0"
wait_for "draft: the draft is still in the box (user-typing)" 15 -- cch_state_is "$(cur_win)" user-typing
close_orch

# ---- load: the RESUME itself is the fault (your-org/nexus-code#1674) --------
# No rig fault. The session's transcript is inflated before the respawn, so the
# `--resume` is still loading when the paste and its Enter arrive. MEASURED on
# 2.1.284: an Enter sent then is LOST, the pasted bytes show up in the box as
# typed text once it renders, and the pane reads `empty`/`unknown` meanwhile.
# Production (2026-09-29 13:15:00) read that `empty` in the strict typed-retry
# loop and gave up; the operator pressed Enter by hand 29 s later.
#
# WHAT THIS ARM CAN AND CANNOT ASSERT, measured while building it:
#   * the load must outlast the paste, its Enter AND the one indeterminate retry,
#     or the strict loop is never reached. 800 MB did not (the retry submitted);
#     neither did 2.4 GB ending on a compact boundary (the binary loads that fast).
#     2.4 GB of plain history does: 8 `empty` readings in the verify window.
#   * but a history that large goes out as the REQUEST, and in one of two head
#     runs the turn died before the mock saw it: the pane never read `busy`, and
#     `_respawn_orchestrator` said rc 4 on a brief that WAS submitted (the other
#     run: rc 0, one request). So rc and the request count are NOTES here; the
#     discriminator is the TRANSCRIPT: exactly one submission recorded. Measured
#     at 2.4 GB: head 1, pre-fix base 0 (it gives up on `empty` with the brief
#     in the box, logging production's 13:15:00 line verbatim).
# RIG SEAMS, both standing in for a longer production load: readiness budget 0
# (production's probe TIMED OUT and pasted anyway; a 30 s or even 2 s budget
# waits the load out here, since each pane-state read takes seconds on a loaded
# host), and a 1 s verify window. RV_LOAD_MB default 2400, CHOSEN from the above.
rv_inflate() {   # rv_inflate <sid> <mb> — append valid chained user/assistant pairs
    local f
    # First match WITHOUT an early-exit reader (early-exit-readers.manifest, #622):
    # awk reads its whole input, so nothing closes the pipe on the writer.
    f=$(_transcripts | awk -v w="/$1.jsonl" 'index($0, w) && !f { print; f = 1 }')
    [[ -n "$f" ]] || return 1
    python3 - "$f" "$2" <<'PY'
import json, sys, uuid
f, mb = sys.argv[1], int(sys.argv[2])
recs = [json.loads(l) for l in open(f) if l.strip()]
u = [r for r in recs if r.get("type") == "user" and isinstance(r.get("message", {}).get("content"), str)][-1]
a = [r for r in recs if r.get("type") == "assistant"][-1]
parent = next(r["uuid"] for r in reversed(recs) if r.get("uuid"))
pad = "lorem ipsum dolor sit amet " * 180
size, n = 0, 0
with open(f, "a") as out:
    while size < mb * 1024 * 1024:
        n += 1
        uu = dict(u, uuid=str(uuid.uuid4()), parentUuid=parent, promptId=str(uuid.uuid4()))
        uu["message"] = dict(u["message"], content="filler turn %d %s" % (n, pad))
        s = json.dumps(uu); out.write(s + "\n"); size += len(s)
        aa = dict(a, uuid=str(uuid.uuid4()), parentUuid=uu["uuid"])
        aa["message"] = dict(a["message"], id="msg_" + uuid.uuid4().hex, content=[{"type": "text", "text": "ack %d %s" % (n, pad)}])
        s = json.dumps(aa); out.write(s + "\n"); size += len(s); parent = aa["uuid"]
PY
}
arm_version load
boot_orch load
_lt=$(_transcripts | awk -v w="/$SID.jsonl" 'index($0, w) && !f { print; f = 1 }')
echo "  NOTE: load: transcript ${_lt:-<none found for $SID>} = $(stat -c %s "$_lt" 2>/dev/null || echo '?') bytes before inflation"
rv_inflate "$SID" "${RV_LOAD_MB:-2400}"; _li=$?
echo "  NOTE: load: rv_inflate rc=$_li; transcript now $(stat -c %s "$_lt" 2>/dev/null || echo '?') bytes"
rv_brief "$CCH_DIR/b-load" load
echo "0 none" > "$CCH_DIR/fault"
r0=$(nreq); s0=$(nrec)
FRESH_SPAWN_READINESS_BUDGET_SECONDS=0 FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1 cch_with_tmux_env _drive "$SID" "$CCH_DIR/b-load"; rc=$?
wait_for "load: the respawned pane returns to idle" 90 -- cch_state_is "$(cur_win)" idle
sleep 1
TR="$CCH_DIR/trace-load"
report_arm load "$TR"
assert_eq "load: the resume presented an INDETERMINATE reading after the paste (or this arm tests nothing)" "$(( $(n_outside "$TR") > 0 ))" "1"
echo "  NOTE: load: _respawn_orchestrator rc=$rc, requests +$(grew_by "$(nreq)" "$r0") (not asserted: an oversized history can kill the turn before the mock — see above)"
assert_eq "load: exactly ONE submission was recorded — the brief left the box once, not zero times, not twice" "$(grew_by "$(nrec)" "$s0")" "1"
assert_contains "load: the verify stage WAITED on the indeterminate reading instead of giving up" "$(cat "$TR")" "waiting for the box to read as the brief"
close_orch

# ---- assertion-count guard (count=exact, summary-honesty) -------------------
# Every assertion runs whether it passes or fails (a failed wait_for is
# COUNTED, not skipped), so the total is a constant: 3 arms × boot_orch's two
# waits = 6; ctl 1 wait + 6; drop 1 wait + 8; draft 8 (incl. its wait).
# MEASURED at 30 on 2.1.280, not arithmetic alone. The `load` arm (#1674) adds
# boot_orch's 2 waits + 1 wait + 3 = 6, so 36.
EXPECTED_ASSERTIONS=36
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
# ONE physical line, deliberately (the summary-honesty classifier reads it so).
assert_eq "assertion TOTAL matches EXPECTED_ASSERTIONS — no assertion silently dropped or added" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
