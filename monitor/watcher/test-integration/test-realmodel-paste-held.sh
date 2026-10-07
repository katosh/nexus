#!/usr/bin/env bash
# test-realmodel-paste-held.sh — the watcher's EMIT PASTE against the REAL
# Claude Code binary: a reported delivery must BE a delivery
# (your-org/nexus-code#1591).
#
# WHY A REAL-BINARY SCENARIO. Claude Code 2.1.277 added a review step: a prompt
# carrying an invisible character (ZWSP, BOM, soft hyphen, LRM, a tag …) is
# CLEANED and HELD in the input box on the first Enter, and sent on the second.
# At 17f1f926 main.sh's `_paste_to_target_unlocked` pressed Enter once and then
# grepped the PANE for the emit trailer. Measured on 2.1.278, a SHORT held body
# renders that trailer in the input box, so it returned 0 for an emit nobody
# received; an EMIT-SHAPED held body collapses to a pasted-text placeholder, so
# it returned 4 and paste_with_retry re-pasted a second copy on top of the held
# one. Either way: no request, no transcript record, pane `user-typing
# input=typed`. The bodies below are emit-shaped, the production case. The cc-update
# evaluator found it with an ad-hoc probe because NO gated scenario pasted at
# all: the gate's delivery axis read `tmux-paste` 0/2. This scenario is that
# missing coverage, and it drives the production function, not a copy of its
# keystrokes.
#
# THE REVIEW STEP IS ARMED HERE WITHOUT FIRST-PARTY AUTH. It is gated by the
# feature flag `tengu_tranquil_cloud`, whose CLIENT DEFAULT is true; under the
# mock backend no flag payload is fetched, so the default applies. A server
# could turn it off for an account at any time, independently of the version
# pin — which is why nothing below asserts "this build holds". Every assertion
# is the VERSION- AND FLAG-AGNOSTIC property:
#
#     reported delivered (rc 0)  ==>  a request reached the backend
#                                     AND the transcript recorded a submission
#
# So it is green on 2.1.273 (no review step), green on 2.1.278 with the fix,
# and RED on 2.1.278 without it. HOW a held arm was recovered (second Enter, or
# normalised away before the paste) is reported as a NOTE, not asserted.
#
# ARMS — one fresh worker each, named `orchestrator` because the function is
# name-keyed, warmed up with one turn (a cold session's first request is the
# title request and would be miscounted):
#   ctl     an emit-shaped ASCII body: many lines, > 800 chars — the shape
#           Claude Code collapses to a `[Pasted text #N +k lines]` placeholder,
#           which is what a real emit looks like in the box
#   held    the same shape with a ZWSP on a line that ALSO carries a non-ASCII
#           letter, so the normaliser leaves it: confirm + second Enter alone
#   longline ONE line over 800 chars with a residual invisible: collapsed to the
#           COUNT-LESS placeholder `[Pasted text #N]`, which the retry equality
#           has to recognise as ours
#   tabline ONE line UNDER 800 chars by a raw count and OVER it once every TAB
#           is four spaces, which is how the REPL's paste handler measures it:
#           collapsed all the same, so the primitive must count as the binary
#           does or strand its own held paste (skeptic pastesk F13)
#   norm    invisibles on pure-ASCII lines: normalised away before the paste;
#           the transcript must record NO U+200B / U+00AD — on a build with no
#           review step that is only true if WE removed them
#   busy    `held`'s body pasted into a pane that is MID-TURN — the orchestrator's
#           normal condition when an emit arrives; it must end up QUEUED and the
#           request must arrive once the turn drains
#   negctl  NEGATIVE CONTROL: the same paste with the Enter WITHHELD. The
#           delivery instrument (requests grew / a submission was recorded) must
#           read NO — or every PASS above could be the instrument saying yes to
#           everything
#
# Drives the delivery transport `tmux-paste` through monitor/_paste-deliver.sh
# and monitor/watcher/main.sh. Asserts pane-state `idle`, `busy` and
# `user-typing` on real harness bytes.
#
# Gated on RUN_CC_HARNESS=1; self-skips otherwise. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"
# CCH_SUBJECT_MON points the DRIVEN code at another tree's monitor/ — the
# reproduction seam: aimed at the pre-fix base, the held / norm / busy arms go
# RED on a build with the review step, which is what shows this scenario can
# fail for the reason it exists. The rig (harness, helpers) stays this tree's.
MON="${CCH_SUBJECT_MON:-$(cd "$_self_dir/../.." && pwd)}"

cch_skip_if_disabled
cch_setup

echo "=== real-binary harness: the emit paste delivers, or says it did not (#1591) ==="
_cc_ver=$("$CLAUDE_BIN" --version 2>/dev/null) || _cc_ver="?"
echo "    claude:  $CLAUDE_BIN  (${_cc_ver%%$'\n'*})"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"

ZWSP=$'\xe2\x80\x8b'; SHY=$'\xc2\xad'
nreq() { local n; n=$(command grep -c '  REQ ' "$CCH_LOG" 2>/dev/null); echo "${n:-0}"; }
# TUI submissions + enqueues across every transcript of this harness home.
# Loops over the globs, never `cat <glob>` / `ls <glob>`: under an ambient
# `nullglob` an unmatched glob VANISHES, and a bare `cat` then reads STDIN while a
# bare `ls` lists the CWD (nullglob-bare-form manifest).
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

# The pane reader the primitive consults. pane-state.sh resolves a bare NAME
# against session `0`, and the harness session is not `0`, so the primitive is
# handed a reader that asks about THIS harness window. It goes through
# `cch_pane_state` — the ONE place the three socket pins live — and never calls
# pane-state.sh itself: a hand-rolled copy of those pins is how a harness read
# reached the PRODUCTION server (your-org/nexus-code#1042 A;
# test-cc-harness-socket-isolation.sh caught the first cut of this file doing
# exactly that). cch_setup EXPORTS every CCH_* it needs, so a child that sources
# the library can call it.
WIN=""
cat > "$CCH_DIR/.bin/pd-pane-state" <<EOF
#!/usr/bin/env bash
. $(printf '%q' "$_self_dir/../../cc-harness/_lib.sh") || exit 1
cch_pane_state "\$(cat $(printf '%q' "$CCH_DIR/cur-window"))"
EOF
chmod +x "$CCH_DIR/.bin/pd-pane-state"

emit_body() {   # emit_body <file> <marker> <special-line>
    local f="$1" m="$2" special="$3" i
    {
        printf '=== nexus watcher emit (%s) ===\n' "$m"
        printf '%s\n' "$special"
        for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
            printf -- '- row %02d: your-org/nexus-code issue comment relayed for the orchestrator, padded to a realistic emit width so the paste collapses\n' "$i"
        done
        printf -- '--- nexus-emit-sig 2026-09-19T00:00:00+00:00 %06x ---\n' "$RANDOM"
    } > "$f"
}

# Runs INSIDE cch_with_tmux_env's subshell: every bare `tmux` lands on the
# harness server. The function is eval'd straight out of production main.sh.
_drive() {   # _drive emit|emit-rawnorm|paste-only <body>
    set +u
    export NEXUS_CC_HOME="$CCH_CFG" PD_PANE_STATE_BIN="$CCH_DIR/.bin/pd-pane-state"
    STATE_DIR="$CCH_STATE_DIR"; TARGET=orchestrator
    ORCH_PIN_FILE="$CCH_STATE_DIR/orchestrator-session-id"; ORCH_LAST_PASTE_FILE="$CCH_STATE_DIR/last-paste"
    log() { printf '%s\n' "$*" >> "$CCH_DIR/emit.log"; }
    _orchestrator_refresh_pin() { :; }; _orchestrator_record_paste() { :; }
    . "$MON/_pane-live.sh"; . "$MON/_tmux-window.sh"; . "$MON/_submit_evidence.sh"
    [[ -r "$MON/_paste-deliver.sh" ]] && . "$MON/_paste-deliver.sh"   # absent in a pre-fix subject tree
    eval "$(sed -n '/^_respawn_read_pin_sid() {/,/^}/p' "$MON/watcher/_respawn.sh")"
    if [[ "$1" == paste-only ]]; then
        # The rig's OWN paste for the negative control — deliberately not the
        # subject's: it must work identically whatever tree is under test.
        local _b="negctl-$$-$RANDOM" _t; _t=$(resolve_window_id orchestrator)
        tmux send-keys -t "$_t" i BSpace && tmux load-buffer -b "$_b" "$2" \
            && tmux paste-buffer -p -d -b "$_b" -t "$_t"
    else
        # `emit-rawnorm` (your-org/nexus-code#1604): the normaliser's OWN fail-open
        # path — no tier tables, so the payload is pasted byte for byte and a
        # leading blank line survives. That is how the box gets misread since
        # #1597 closed the ordinary road; see the `inertbox` arm.
        [[ "$1" == emit-rawnorm ]] && unset _PD_TIER_U _PD_TIER_C
        eval "$(sed -n '/^_paste_to_target_unlocked() {/,/^}/p' "$MON/watcher/main.sh")"
        _paste_to_target_unlocked orchestrator "$2"
        local rc=$?
        printf '%s %s %s\n' "$PD_OUTCOME" "$PD_ENTER_RETRIES" "$PD_NORMALISED_BYTES" > "$CCH_DIR/pd.result"
        return $rc
    fi
}

boot_orch() {
    cch_control '{"mode":"text","text":"MOCK_OK_HELLO"}'
    WIN=$(cch_boot_worker orchestrator)
    [[ -n "$WIN" ]] || { echo "FAIL: orchestrator window never appeared" >&2; exit 1; }
    printf '%s' "$WIN" > "$CCH_DIR/cur-window"
    wait_for "boots to idle" 40 -- cch_state_is "$WIN" idle
    cch_send "$WIN" "warm up turn"
    sleep 2
    wait_for "idle after the warm-up turn" 40 -- cch_state_is "$WIN" idle
    sleep 1
    newest_sid > "$CCH_STATE_DIR/orchestrator-session-id"
    : > "$CCH_DIR/emit.log"; rm -f "$CCH_DIR/pd.result"
}
close_orch() { cch_tmux kill-window -t "$CCH_SESSION:$WIN" 2>/dev/null; sleep 1; }

grew() { (( $1 > $2 )) && echo yes || echo no; }
# THE PROPERTY, asserted per arm.
honest_arm() {   # honest_arm <label> <rc> <r0> <r1> <s0> <s1>
    local label="$1" rc="$2" outcome retries norm
    read -r outcome retries norm < "$CCH_DIR/pd.result" 2>/dev/null || { outcome="?"; retries="?"; norm="?"; }
    assert_eq "$label: the emit paste reports delivered (rc 0)" "$rc" "0"
    assert_eq "$label: …and a request REACHED the backend" "$(grew "$4" "$3")" "yes"
    assert_eq "$label: …and the transcript RECORDED the submission" "$(grew "$6" "$5")" "yes"
    echo "  NOTE: $label: outcome=$outcome enter_retries=$retries normalised_bytes=$norm requests $3->$4 records $5->$6"
}

# ---- ctl -------------------------------------------------------------------
boot_orch
emit_body "$CCH_DIR/b-ctl" ctl "plain ascii line"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-ctl"; rc=$?
sleep 3
honest_arm "ctl" "$rc" "$r0" "$(nreq)" "$s0" "$(nrec)"
wait_for "ctl: the pane returns to idle with an EMPTY box" 30 -- cch_state_is "$WIN" idle
close_orch

# ---- held (layer 1 alone) ---------------------------------------------------
boot_orch
emit_body "$CCH_DIR/b-held" held "naïve café a${ZWSP}b hy${SHY}phen"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-held"; rc=$?
sleep 3
honest_arm "held" "$rc" "$r0" "$(nreq)" "$s0" "$(nrec)"
wait_for "held: nothing is left sitting in the input box (not user-typing)" 30 -- cch_state_is "$WIN" idle
close_orch

# ---- longline: ONE line over 800 chars (skeptic pastesk F9) ------------------
# The binary collapses it to `[Pasted text #N]` with NO `+K lines`. The retry
# Enter is an EQUALITY on the input row, so on a build that holds this body the
# arm recovers ONLY if the primitive spells the count-less placeholder as the
# binary does; the first cut demanded `+K lines` and stranded it, while a fake
# REPL that printed `+0 lines` kept the hermetic suite green.
boot_orch
printf 'longline na\xc3\xafve a%sb %s end' "$ZWSP" "$(printf 'padding-%.0s' $(seq 1 110))" > "$CCH_DIR/b-long"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-long"; rc=$?
sleep 3
honest_arm "longline" "$rc" "$r0" "$(nreq)" "$s0" "$(nrec)"
wait_for "longline: nothing is left sitting in the input box" 30 -- cch_state_is "$WIN" idle
close_orch

# ---- tabline: collapses ONLY by its TABs (skeptic pastesk F13) ---------------
# 80 TABs in a line of under 700 bytes: over 900 once each TAB is four spaces,
# which is what the REPL's own paste handler compares with 800. Both hermetic
# rigs only MODEL that rule; this arm is where it is measured. Against the
# pre-F13 primitive, on a build that holds the body, this arm is stranded.
boot_orch
printf 'tabline na\xc3\xafve a%sb %s%s end' "$ZWSP" "$(printf 'col\t%.0s' $(seq 1 80))" "$(printf 'padding-%.0s' $(seq 1 40))" > "$CCH_DIR/b-tab"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-tab"; rc=$?
sleep 3
honest_arm "tabline" "$rc" "$r0" "$(nreq)" "$s0" "$(nrec)"
wait_for "tabline: nothing is left sitting in the input box" 30 -- cch_state_is "$WIN" idle
close_orch

# ---- blankfirst: a LEADING BLANK LINE (your-org/nexus-code#1597) -------------
# MEASURED on this binary before the fix existed: the REPL KEEPS a leading blank
# line, so the input row is the prompt glyph and NOTHING ELSE and the text sits
# on the next row — and production pane-state, which classifies the input from
# the glyph row alone, reads that box `state=idle input=blank`. The payload is
# therefore stranded one layer BEFORE the retry equality is ever asked: not
# `undecidable-box` but `clear`, which earns no Enter. The fix drops leading
# blank lines in pd_normalise_file, the one stated exception to "never
# over-strips" (2.1.278 RECORDS that newline; it carries no instruction content,
# and with it the payload cannot be seen at all). Against a pre-fix
# CCH_SUBJECT_MON on a build with the review step, this arm is stranded.
boot_orch
printf '\ncaf\xc3\xa9 a%sb blankfirst marker %06x' "$ZWSP" "$RANDOM" > "$CCH_DIR/b-blank"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-blank"; rc=$?
sleep 3
honest_arm "blankfirst" "$rc" "$r0" "$(nreq)" "$s0" "$(nrec)"
wait_for "blankfirst: nothing is left sitting in the input box" 30 -- cch_state_is "$WIN" idle
close_orch

# ---- cjkfirst: a first line with NO ASCII (your-org/nexus-code#1597) ---------
# The retry equality compared ASCII PROJECTIONS, and a first line of CJK projects
# to the empty string, which can never match: held, no Enter, stranded. The
# invisible sits on the SECOND line, beside a non-ASCII letter, so the normaliser
# leaves it (Tier C is removed only on a pure-ASCII line) and the binary holds
# the body — the same mechanism the `held` arm above proves. The fix compares
# VISIBLE projections, so the CJK row is readable as ours.
# Two lines, well under 800 chars: rendered as TEXT, not collapsed, which is what
# puts the first line on the input row where the equality reads it.
boot_orch
printf '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe3\x81\xae\xe6\x9c\x80\xe5\x88\x9d\xe3\x81\xae\xe8\xa1\x8c\nnaïve caf\xc3\xa9 a%sb cjkfirst %06x' "$ZWSP" "$RANDOM" > "$CCH_DIR/b-cjk"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-cjk"; rc=$?
sleep 3
honest_arm "cjkfirst" "$rc" "$r0" "$(nreq)" "$s0" "$(nrec)"
wait_for "cjkfirst: nothing is left sitting in the input box" 30 -- cch_state_is "$WIN" idle
close_orch

# ---- inertbox: INERT while the body sits in the box (your-org/nexus-code#1604) --
# #1597's measured body — a leading blank line, a residual invisible, NO emit
# trailer — pasted RAW, through the normaliser's own fail-open path (no tier
# tables), so the blank line survives and the box is misread exactly as it was
# before #1597: the glyph row is empty, pane-state reads `idle input=blank`, no
# retry Enter is owed, and a readable transcript that recorded nothing ends
# `inert`. main.sh then remapped inert to "unconfirmed", the rendering fallback
# had no trailer to look for, and the function returned 0: measured at d58bc49a
# as rc 0 with no request and no record. The property is the implication, not a
# code: reported delivered ⇒ a request AND a record. Against a pre-fix
# CCH_SUBJECT_MON on a build with the review step, this arm is RED.
boot_orch
printf '\ncaf\xc3\xa9 a%sb inertbox marker %06x' "$ZWSP" "$RANDOM" > "$CCH_DIR/b-inert"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit-rawnorm "$CCH_DIR/b-inert"; rc=$?
sleep 3
r1=$(nreq); s1=$(nrec)
read -r outcome retries norm < "$CCH_DIR/pd.result" 2>/dev/null || { outcome="?"; retries="?"; norm="?"; }
# POTENCY: had the normaliser run, the blank line would be gone and this arm
# would be `blankfirst` again, answering nothing about #1604.
assert_eq "inertbox: the payload went out RAW (normaliser bypassed) — or this arm tests nothing" "$norm" "0"
if [[ "$rc" == 0 && ( "$(grew "$r1" "$r0")" == no || "$(grew "$s1" "$s0")" == no ) ]]; then
    echo "  FAIL: inertbox: MANUFACTURED SUCCESS — reported delivered (rc 0) with requests $r0->$r1 records $s0->$s1" >&2
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: inertbox: reported delivered only if it WAS (rc=$rc requests $r0->$r1 records $s0->$s1)"; PASS=$(( PASS + 1 ))
fi
echo "  NOTE: inertbox: outcome=$outcome enter_retries=$retries rc=$rc"
close_orch

# ---- norm (layer 2) ---------------------------------------------------------
boot_orch
emit_body "$CCH_DIR/b-norm" norm "plain a${ZWSP}b hy${SHY}phen"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-norm"; rc=$?
sleep 3
honest_arm "norm" "$rc" "$r0" "$(nreq)" "$s0" "$(nrec)"
sid=$(cat "$CCH_STATE_DIR/orchestrator-session-id")
# The transcript is RESOLVED to a path first: a glob handed straight to jq would,
# under an ambient `nullglob`, vanish and leave jq reading STDIN.
sid_t=""
while IFS= read -r _t; do [[ "${_t##*/}" == "$sid.jsonl" ]] && sid_t="$_t"; done < <(_transcripts)
last=""
[[ -n "$sid_t" ]] && last=$(jq -r 'select(.type=="user" and has("promptSource")) | .message.content | if type=="string" then . else (map(.text? // "") | join("")) end' \
    "$sid_t" 2>/dev/null | tail -n 40)
assert_contains "norm: the recorded prompt is the emit we sent" "$last" "nexus watcher emit (norm)"
# A bash pattern test, not `printf … | grep -q` as the condition (#622).
if [[ "$last" == *"$ZWSP"* || "$last" == *"$SHY"* ]]; then
    echo "  FAIL: norm: the recorded prompt still carries a ZWSP / soft hyphen — the body was not normalised before the paste" >&2
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: norm: the recorded prompt carries no ZWSP / soft hyphen"; PASS=$(( PASS + 1 ))
fi
close_orch

# ---- busy ------------------------------------------------------------------
boot_orch
cch_control '{"mode":"text","text":"one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty","drip_ms":800}'
cch_send "$WIN" "long busy turn"
wait_for "busy: the pane is mid-turn before the paste" 20 -- cch_state_is "$WIN" busy
emit_body "$CCH_DIR/b-busy" busy "naïve café a${ZWSP}b"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-busy"; rc=$?
read -r outcome retries norm < "$CCH_DIR/pd.result" 2>/dev/null || outcome="?"
assert_eq "busy: the emit paste reports delivered (rc 0)" "$rc" "0"
assert_eq "busy: …and the transcript RECORDED it (an enqueue, or a submission)" "$(grew "$(nrec)" "$s0")" "yes"
echo "  NOTE: busy: outcome=$outcome enter_retries=$retries"
cch_control '{"mode":"text","text":"MOCK_OK_AFTER"}'
wait_for "busy: once the turn drains the queued emit is SENT and the pane goes idle" 90 -- cch_state_is "$WIN" idle
sleep 2
# The busy turn's own request predates r0, so growth here is the queued emit.
assert_eq "busy: …and its request reached the backend" "$(grew "$(nreq)" "$r0")" "yes"
close_orch

# ---- draft / busydraft: an OPERATOR DRAFT is in the box (your-org/nexus-code#1674)
# Measured on the live board 2026-09-29 13:16:02: the orchestrator was MID-TURN,
# the operator was typing, and the startup-sweep emit was pasted INTO the
# half-typed message; the first Enter sent it mid-word. The emit must paste
# NOTHING (rc 7) and press no Enter, idle or busy, and the draft must still be
# in the box afterwards. `busydraft` is the production shape: it rests on
# pane-state giving typed input precedence over `busy`, measured here rather than
# read off the classifier.
DRAFT_TEXT="when we restart the emit gets stuck until I enter it "
sig_of() { tail -1 "$1" | sed -n 's/.*\(nexus-emit-sig [^ ]* [^ ]*\).*/\1/p'; }
n_with() { _transcripts | while IFS= read -r _t; do command grep -cF -- "$1" "$_t"; done | awk '{s+=$1} END{print s+0}'; }
boot_orch
cch_tmux send-keys -t "$CCH_SESSION:$WIN" -l "$DRAFT_TEXT"
wait_for "draft: the operator draft reads user-typing before the emit" 15 -- cch_state_is "$WIN" user-typing
emit_body "$CCH_DIR/b-draft" draft "plain ascii line"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive emit "$CCH_DIR/b-draft"; rc=$?
sleep 4
assert_eq "draft: the emit is REFUSED before the paste (rc 7) — nothing merged into the draft" "$rc" "7"
assert_eq "draft: NO request reached the backend — the draft was not submitted" "$(grew "$(nreq)" "$r0")" "no"
assert_eq "draft: …and NO submission is recorded" "$(grew "$(nrec)" "$s0")" "no"
wait_for "draft: the draft is still in the box" 15 -- cch_state_is "$WIN" user-typing
close_orch

boot_orch
cch_control '{"mode":"text","text":"one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty","drip_ms":800}'
cch_send "$WIN" "long busy turn"
wait_for "busydraft: the pane is mid-turn" 20 -- cch_state_is "$WIN" busy
cch_tmux send-keys -t "$CCH_SESSION:$WIN" -l "$DRAFT_TEXT"
wait_for "busydraft: a draft typed DURING the turn reads user-typing (typed input outranks busy)" 15 -- cch_state_is "$WIN" user-typing
emit_body "$CCH_DIR/b-busydraft" busydraft "plain ascii line"
sig=$(sig_of "$CCH_DIR/b-busydraft")
cch_with_tmux_env _drive emit "$CCH_DIR/b-busydraft"; rc=$?
assert_eq "busydraft: the emit is REFUSED before the paste (rc 7)" "$rc" "7"
cch_control '{"mode":"text","text":"MOCK_OK_AFTER"}'
sleep 20
assert_eq "busydraft: the emit's signature is in NO record — it was never merged into the draft and sent" "$(n_with "$sig")" "0"
assert_eq "busydraft: …and the draft was not sent either (no record carries it)" "$(n_with "$DRAFT_TEXT")" "0"
close_orch

# ---- negctl: the instrument can say NO ---------------------------------------
boot_orch
emit_body "$CCH_DIR/b-neg" negctl "plain ascii line"
r0=$(nreq); s0=$(nrec)
cch_with_tmux_env _drive paste-only "$CCH_DIR/b-neg"; rc=$?
assert_eq "negctl: the paste itself succeeded (rc 0) — so what follows is about the ENTER" "$rc" "0"
sleep 6
assert_eq "NEGATIVE CONTROL: with the Enter withheld NO request reaches the backend" "$(grew "$(nreq)" "$r0")" "no"
assert_eq "NEGATIVE CONTROL: …and NO submission is recorded" "$(grew "$(nrec)" "$s0")" "no"
wait_for "NEGATIVE CONTROL: …and pane-state reads the unsent text as user-typing" 15 -- cch_state_is "$WIN" user-typing
close_orch

# WHAT THIS BUILD RECORDS FOR A PASTE — a NOTE, never an assertion. The
# primitive's needle-less fallback drops `promptSource:"queued"` (skeptic pastesk
# F1 on #1595), which is safe only while a paste into a BUSY pane writes an
# `enqueue` record first; this tally is the per-release measurement of that.
_kinds=$(_transcripts | while IFS= read -r _t; do cat -- "$_t"; done \
    | jq -r 'if .type == "queue-operation" then "queue-operation:" + (.operation // "?")
             elif (.type == "user" and has("promptSource")) then "promptSource:" + .promptSource else empty end' 2>/dev/null \
    | sort | uniq -c | tr -s ' ' | tr '\n' ';')
echo "  NOTE: records written across all arms:${_kinds}"

# ---- assertion-count guard (count=exact, summary-honesty) -------------------
# Every arm runs every one of its assertions whether it passes or fails (a
# failed wait_for is COUNTED, not skipped), so the total is a constant.
# 44 + 12 for the two your-org/nexus-code#1597 arms (6 each: the three honest_arm
# rows, the NOTE is not an assertion, plus the box-empty wait). MEASURED at 56,
# not arithmetic alone — the run that added the arms reported `56 passed`.
# + 4 for the your-org/nexus-code#1604 `inertbox` arm (boot_orch's two waits,
# the potency row, the implication row). MEASURED at 60 on 2.1.280 — the run
# that added the arm reported `60 passed` against an arithmetic 58 that forgot
# boot_orch's own two rows.
# + 14 for the your-org/nexus-code#1674 `draft` (2 boot + 5) and `busydraft`
# (2 boot + 5) arms.
EXPECTED_ASSERTIONS=74
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
# ONE physical line, deliberately (the summary-honesty classifier reads it so).
assert_eq "assertion TOTAL matches EXPECTED_ASSERTIONS — no assertion silently dropped or added" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
