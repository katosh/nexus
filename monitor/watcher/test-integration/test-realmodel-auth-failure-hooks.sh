#!/usr/bin/env bash
# test-realmodel-auth-failure-hooks.sh — which hooks fire on a turn that dies
# to an AUTH failure, measured on the real binary (your-org/nexus-code#1548 F1,
# #1517, #1520).
#
# THE QUESTION THIS SETTLES, BY PROBE AND NOT BY LOG READ
#
# #1548's skeptic (F1) could not establish, from the watcher log, whether
# `UserPromptSubmit` fires under an expired login — and it matters, because
# `_orchestrator_pasted_without_response` reads the `orchestrator-paste-received`
# file that hook touches as its SECOND signal, ahead of the session jsonl, so
# any fix keyed on the jsonl alone sits behind it. #1520 asserts that a failed
# turn fires `StopFailure` INSTEAD of `Stop`; #1517 never determined which
# signal produced each false `recovered`. Three claims, one scenario:
#
#   (1) UserPromptSubmit FIRES when the prompt is submitted, before the API
#       call — so a resubmit into a logged-out session DOES touch
#       `orchestrator-paste-received`, and the mtime family cannot see the
#       failure from that signal;
#   (2) StopFailure FIRES with a typed `error` token, and the REAL
#       `turn-failure-emit.sh` + `_cause_classify.sh` turn it into a
#       `turn-failure/<window>.json` marker with `recovery=operator`;
#   (3) Stop does NOT fire (no `Stop` clear, no heartbeat), so the marker
#       stands until a SUCCESSFUL turn — which is what makes it a gate.
#
# The mock answers 401 `authentication_error`. NOTE ON THE TOKEN: production's
# expired-OAuth payloads carry `error=authentication_failed` (40 of 40 captures
# in monitor/.state/stopfailure-raw-captures.jsonl); a bearer-token 401 through
# this harness may surface a DIFFERENT token. The scenario therefore RECORDS
# the token it observed and asserts on the CLASSIFIED marker (category=auth),
# which is what every consumer reads — and `test-cause-classify.sh` pins the
# production token separately. If the observed token ever classifies as
# anything but auth, this goes red and names the token.
#
# ── The rigor contract: this test must be able to go RED ────────────────
#
#   NC-1 (differential control): a SUCCESSFUL turn on the same binary with
#        the same hooks must fire Stop and NOT StopFailure — proving the
#        journal discriminates the events rather than logging whatever ran.
#   NC-2 (broken-assertion control): the field extractor run on a doctored
#        payload with `error` deleted returns empty.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary); self-skips
# with exit 77, whoever the caller is (#1574 G1). Hermetic tmux via cch_setup; every
# process this boots is reaped by cch_teardown.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../../.." && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled

if ! command -v jq >/dev/null 2>&1; then
    echo "skipped: $(basename "$0") (jq not on PATH — the real hook writer needs it)"
    # EXIT 77, UNCONDITIONALLY (your-org/nexus-code#1574 G1). This arm used to
    # `exit 0` unless CCH_GATE=1 — the form `cch_skip_if_disabled` retired under
    # #568 A6, which says `CCH_GATE` "no longer changes the exit code". It was a
    # straggler of that migration: a scenario that declined to run and reported
    # PASS, which `run-tests.sh --require-run` cannot see, because that flag
    # counts rc 77 and rc 69 and an rc 0 is in neither count.
    exit 77
fi

cch_setup
trap 'cch_teardown' EXIT

PASS=0; FAIL=0

echo "=== real-binary auth failure: which hooks fire (your-org/nexus-code#1548 F1, #1520) ==="
echo "    claude:  $CLAUDE_BIN"
echo "    version: $("$CLAUDE_BIN" --version 2>/dev/null || echo '?')"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"

JOURNAL_DIR="$CCH_DIR/journal"; mkdir -p "$JOURNAL_DIR"
TF_STATE="$CCH_DIR/tfstate"; mkdir -p "$TF_STATE"
WIN=auth-probe

# One journalling hook per event: appends `<event>\t<epoch.ns>` and keeps the
# raw payload of the LAST StopFailure for the field assertions.
write_journal_hook() {   # <path> <event>
    cat > "$1" <<EOF
#!/usr/bin/env bash
payload=\$(cat)
printf '%s\t%s\n' $(printf '%q' "$2") "\$(date +%s.%N)" >> $(printf '%q' "$JOURNAL_DIR/events.tsv")
[[ "$2" == StopFailure ]] && printf '%s' "\$payload" > $(printf '%q' "$JOURNAL_DIR/stopfailure.json")
exit 0
EOF
    chmod +x "$1"
}
HOOK_UPS="$CCH_DIR/hook-ups.sh";  write_journal_hook "$HOOK_UPS"  UserPromptSubmit
HOOK_STOP="$CCH_DIR/hook-stop.sh"; write_journal_hook "$HOOK_STOP" Stop
HOOK_SF="$CCH_DIR/hook-sf.sh";     write_journal_hook "$HOOK_SF"   StopFailure

# THE WRITER'S COMPLETION IS OBSERVED, NOT GUESSED (your-org/nexus-code#1688).
# The REAL turn-failure-emit.sh runs unmodified — same stdin, same env, same
# path, so its `_self_dir` resolution is production's — inside a pass-through
# that appends `TurnFailureEmitDone\t<end>\t<rc>\t<start>` to the journal
# AFTER the writer exits. The writer `mv`s its marker into place before it
# exits, so once that line exists the marker's presence is a VERDICT, not a
# sample: "done and no marker" is a writer defect, "not done yet" is a slow
# host. The two red gates on #1688 ran a tree that sampled the marker ONCE
# (pre-#1669); #1669's replacement, a FIXED 10 s poll, still could not tell
# the two apart, and a writer slower than 10 s (bash + 4 jq + 2 tr, on a host
# at load 40–60) would read "did not write" on a hook that works.
HOOK_TF="$CCH_DIR/hook-tf.sh"
cat > "$HOOK_TF" <<EOF
#!/usr/bin/env bash
t0=\$(date +%s.%N)
$(printf '%q' "$REPO_ROOT/monitor/hooks/turn-failure-emit.sh")
rc=\$?
printf 'TurnFailureEmitDone\t%s\t%s\t%s\n' "\$(date +%s.%N)" "\$rc" "\$t0" >> $(printf '%q' "$JOURNAL_DIR/events.tsv")
exit "\$rc"
EOF
chmod +x "$HOOK_TF"

# THE CLEAR'S COMPLETION IS OBSERVED TOO (your-org/nexus-code#1732). The REAL
# stamp-clear.sh is a SIBLING of the Stop journal hook exactly as the writer is
# of the StopFailure one, so NC-1 cannot know the clear has run from the Stop
# line alone. It used to sleep a FIXED 2 s and then read "marker survived a
# successful turn" as a defect in the clear: the mirror image of the late
# write #1669/#1688 fixed on the writer side, and the one sibling hook whose
# completion this scenario still guessed. (Every #1732-family red ran
# 9f0b719a, which predates both writer fixes; there that line was the LATE
# WRITE landing after the clear.) The same pass-through journals
# `StopClearDone` after the clear EXITS, so a surviving marker is a verdict
# only once it has.
HOOK_CLEAR="$CCH_DIR/hook-clear.sh"
cat > "$HOOK_CLEAR" <<EOF
#!/usr/bin/env bash
t0=\$(date +%s.%N)
$(printf '%q' "$REPO_ROOT/monitor/hooks/stamp-clear.sh") turn-failure
rc=\$?
printf 'StopClearDone\t%s\t%s\t%s\n' "\$(date +%s.%N)" "\$rc" "\$t0" >> $(printf '%q' "$JOURNAL_DIR/events.tsv")
exit "\$rc"
EOF
chmod +x "$HOOK_CLEAR"

# The REAL production writer runs beside the journal on StopFailure, and the
# REAL clear on Stop — exactly the pair orchestrator-settings.json wires (each
# through its completion journal above).
SETTINGS="$CCH_DIR/settings-auth.json"
jq -n --arg ups "$HOOK_UPS" --arg stop "$HOOK_STOP" --arg sf "$HOOK_SF" \
      --arg tf "$HOOK_TF" \
      --arg clear "$HOOK_CLEAR" '{hooks: {
    UserPromptSubmit: [ { hooks: [ {type:"command", command:$ups} ] } ],
    Stop:             [ { hooks: [ {type:"command", command:$stop}, {type:"command", command:$clear} ] } ],
    StopFailure:      [ { hooks: [ {type:"command", command:$sf},   {type:"command", command:$tf} ] } ]
}}' > "$SETTINGS"

# The hooks resolve the window through `stamp_window` (orchestrator env) and
# the state dir through NEXUS_STATE_DIR; CLAUDE_CODE_MAX_RETRIES=1 exhausts the
# soft-retry loop after one retry so StopFailure fires within seconds rather
# than the ~3-minute production budget (#1559).
IDX=$(CCH_SETTINGS="$SETTINGS" \
      CCH_EXTRA_ENV="NEXUS_STATE_DIR=$TF_STATE NEXUS_ORCHESTRATOR_WINDOW=$WIN NEXUS_ROOT=$CCH_DIR CLAUDE_CODE_MAX_RETRIES=1" \
      cch_boot_worker "$WIN")
[[ -n "$IDX" ]] || { echo "FATAL: worker window never appeared" >&2; exit 1; }
wait_for "REPL boots to idle" 60 -- cch_state_is "$IDX" idle

events() { cut -f1 "$JOURNAL_DIR/events.tsv" 2>/dev/null || true; }
count_ev() { local n; n=$(events | grep -c "^$1\$"); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }

# ---- ARM A: a turn that dies to 401 authentication_error -----------------
echo
echo "--- ARM A: mock 401/authentication_error → which hooks fire ---"
cch_control '{"mode":"error","status":401,"error_type":"authentication_error","error_text":"OAuth token has expired. Please obtain a new token or refresh your existing token."}'
MARKER="$TF_STATE/turn-failure/$WIN.json"
if [[ ! -e "$MARKER" ]]; then
    echo "  PASS: no turn-failure marker before the turn (not pre-seeded)"; PASS=$((PASS+1))
else
    echo "  FAIL: marker pre-existed — ARM A would be vacuous" >&2; FAIL=$((FAIL+1))
fi

# Drive one prompt; retry once if the REPL swallowed the first keystrokes.
sf_fired() { (( $(count_ev StopFailure) >= 1 )); }
for attempt in 1 2; do
    cch_send "$IDX" "hello, are you there?"
    for i in $(seq 1 90); do sf_fired && break; sleep 0.5; done
    sf_fired && break
    echo "    (attempt $attempt: StopFailure not yet journalled; retrying the prompt)"
done

# WAIT FOR THE WRITER, NOT FOR A GUESSED LATENCY (your-org/nexus-code#1669,
# #1688). The journal hook and the REAL turn-failure-emit.sh are SIBLINGS in
# one StopFailure group: they start together, and the writer lands its marker
# after the journal line — 0.31–1.21 s on a quiet host (n=12, #1669), later
# under load. #1669 replaced a single sample with a FIXED 10 s poll, unscaled
# and blind to whether the writer was still running (#1688). The poll now ends
# on the first of: a non-empty marker (the writer renames a temp file into
# place, so non-empty is complete), or the writer's own completion line
# (`tf_done`, journalled by $HOOK_TF after the writer EXITS). The ceiling is
# 60 s UNLOADED through `th_deadline` — CHOSEN, ~50× the slowest quiet-host
# landing, and a polled ceiling costs nothing on a green run. Reaching it
# with the writer still running is reported as NOT A VERDICT on the hook.
#
# Deterministic reproduction of #1688, no host load: prepend to PATH a `jq`
# shim that sleeps 4 s when NEXUS_ORCHESTRATOR_WINDOW=auth-probe (only the
# REPL's hooks carry it) and then execs the real jq. The writer then takes
# ~16 s; the fixed 10 s poll at 5dc308cf fails ARM A, this one passes.
tf_done() { (( $(count_ev TurnFailureEmitDone) >= 1 )); }
MARKER_WAIT_S=$(th_deadline 60)
marker_waited=0
if sf_fired; then
    _mw_t0=$SECONDS
    while :; do
        [[ -s "$MARKER" ]] && break
        tf_done && break
        marker_waited=$(( SECONDS - _mw_t0 ))
        (( marker_waited >= MARKER_WAIT_S )) && break
        sleep 0.25
    done
    marker_waited=$(( SECONDS - _mw_t0 ))
    tf_line=$(awk -F'\t' '$1=="TurnFailureEmitDone"{print; exit}' "$JOURNAL_DIR/events.tsv" 2>/dev/null)
    if [[ -n "$tf_line" ]]; then
        IFS=$'\t' read -r _ tf_end tf_rc tf_start <<<"$tf_line"
        echo "        writer: exited rc=$tf_rc after $(awk -v a="$tf_start" -v b="$tf_end" 'BEGIN{printf "%.2f", b-a}') s; marker wait ${marker_waited} s after the journal saw StopFailure (ceiling ${MARKER_WAIT_S} s)"
    else
        echo "        writer: NOT YET EXITED after ${marker_waited} s (ceiling ${MARKER_WAIT_S} s)"
    fi
fi

n_ups=$(count_ev UserPromptSubmit); n_stop=$(count_ev Stop); n_sf=$(count_ev StopFailure)
echo "        journal: UserPromptSubmit=$n_ups Stop=$n_stop StopFailure=$n_sf"

if (( n_sf >= 1 )); then
    echo "  PASS: StopFailure FIRED on the auth-failed turn"; PASS=$((PASS+1))
else
    echo "  FAIL: StopFailure never fired — the typed marker path (#1520) is unreachable on this candidate" >&2; FAIL=$((FAIL+1))
fi
if (( n_ups >= 1 )); then
    echo "  PASS: UserPromptSubmit FIRED under the failing login (#1548 F1: the paste-received mtime DOES advance on a doomed resubmit — the mtime family cannot see the failure from that signal)"; PASS=$((PASS+1))
else
    echo "  FAIL: UserPromptSubmit did NOT fire — #1548 F1's premise is wrong on this candidate; the liveness ordering argument needs re-deriving" >&2; FAIL=$((FAIL+1))
fi
if (( n_stop == 0 )); then
    echo "  PASS: Stop did NOT fire (StopFailure fires INSTEAD, so no heartbeat and no clear — the marker stands)"; PASS=$((PASS+1))
else
    echo "  FAIL: Stop fired $n_stop time(s) on a failed turn — the Stop clear would erase the marker the gate needs" >&2; FAIL=$((FAIL+1))
fi

# Order: UserPromptSubmit strictly before StopFailure.
first_ups=$(awk -F'\t' '$1=="UserPromptSubmit"{print $2; exit}' "$JOURNAL_DIR/events.tsv" 2>/dev/null)
first_sf=$(awk -F'\t' '$1=="StopFailure"{print $2; exit}' "$JOURNAL_DIR/events.tsv" 2>/dev/null)
if [[ -n "$first_ups" && -n "$first_sf" ]] && awk -v a="$first_ups" -v b="$first_sf" 'BEGIN{exit !(a<b)}'; then
    echo "  PASS: UserPromptSubmit preceded StopFailure (input landed, THEN the turn failed)"; PASS=$((PASS+1))
else
    echo "  FAIL: could not order the events (ups=$first_ups sf=$first_sf)" >&2; FAIL=$((FAIL+1))
fi

# ---- the payload the production writer parsed --------------------------
extract_field() { jq -r "$2 // empty" "$1" 2>/dev/null; }
if [[ -s "$JOURNAL_DIR/stopfailure.json" ]]; then
    got_event=$(extract_field "$JOURNAL_DIR/stopfailure.json" '.hook_event_name')
    got_err=$(extract_field   "$JOURNAL_DIR/stopfailure.json" '.error')
    got_msg=$(extract_field   "$JOURNAL_DIR/stopfailure.json" '.last_assistant_message')
    echo "        payload: hook_event_name=${got_event:-<none>} error=${got_err:-<none>}"
    echo "        last_assistant_message: ${got_msg:0:160}"
    echo "        OBSERVED TOKEN for a bearer-token 401 on this candidate: '${got_err:-<none>}' (production expired-OAuth token: authentication_failed)"
    assert_eq "payload carries hook_event_name=StopFailure" "$got_event" "StopFailure"
    if [[ -n "$got_err" ]]; then
        echo "  PASS: payload carries a non-empty typed error token"; PASS=$((PASS+1))
    else
        echo "  FAIL: payload has no error token — the classifier would fall to the message probe" >&2; FAIL=$((FAIL+1))
    fi
else
    echo "  FAIL: no StopFailure payload captured" >&2; FAIL=$((FAIL+1))
fi

# ---- the REAL writer + classifier produced an OPERATOR marker -----------
if [[ -s "$MARKER" ]]; then
    echo "  PASS: the REAL turn-failure-emit.sh wrote $MARKER for the orchestrator env"; PASS=$((PASS+1))
    m_cat=$(extract_field "$MARKER" '.category'); m_rec=$(extract_field "$MARKER" '.recovery'); m_win=$(extract_field "$MARKER" '.window')
    echo "        marker: category=$m_cat recovery=$m_rec window=$m_win"
    assert_eq "marker category=auth (the classifier recognised the observed token/message)" "$m_cat" "auth"
    assert_eq "marker recovery=operator (no in-band remedy)" "$m_rec" "operator"
    assert_eq "marker window is the orchestrator env (stamp_window)" "$m_win" "$WIN"
else
    if tf_done; then
        echo "  FAIL: no marker — turn-failure-emit.sh EXITED without writing for NEXUS_ORCHESTRATOR_WINDOW (a WRITER defect — window resolution, classifier or the write itself; see your-org/nexus-code#1520)" >&2; FAIL=$((FAIL+1))
    else
        echo "  FAIL: no marker — turn-failure-emit.sh had NOT EXITED after ${MARKER_WAIT_S} s (a slow host or a hung writer; NOT a verdict that it does not write, #1688)" >&2; FAIL=$((FAIL+1))
    fi
fi

# ---- NC-1: a SUCCESSFUL turn fires Stop, not StopFailure, and CLEARS -----
echo
echo "--- NC-1: mock recovers → Stop fires, StopFailure does not, the marker is cleared ---"
cch_control '{"mode":"text","text":"MOCK_RECOVERED_OK"}'
# The marker must EXIST before the recovering turn is driven (#1669): a late
# StopFailure write landing AFTER this turn's Stop clear would leave a marker
# the clear never saw, and "marker survived a successful turn" would then
# blame the clear for the writer's latency. ARM A already waited; this re-check
# is what makes the ordering explicit rather than inherited. If the marker
# never appeared, ARM A has FAILED on it, and the clear assertion below is
# then vacuous — say so rather than let its PASS read as evidence.
if [[ -s "$MARKER" ]]; then
    nc1_marker_present=1
else
    for i in $(seq 1 $(( MARKER_WAIT_S * 4 ))); do [[ -s "$MARKER" ]] && break; tf_done && break; sleep 0.25; done
    if [[ -s "$MARKER" ]]; then nc1_marker_present=1; else nc1_marker_present=0; fi
fi
(( nc1_marker_present )) \
    || echo "    (NC-1: no marker to clear — ARM A failed on it; the clear assertion below cannot discriminate)"
sf_before=$(count_ev StopFailure); stop_before=$(count_ev Stop); clear_before=$(count_ev StopClearDone)
stop_fired() { (( $(count_ev Stop) > stop_before )); }
for attempt in 1 2; do
    cch_send "$IDX" "and now?"
    for i in $(seq 1 90); do stop_fired && break; sleep 0.5; done
    stop_fired && break
    echo "    (attempt $attempt: Stop not yet journalled; retrying the prompt)"
done
if stop_fired; then
    echo "  PASS: Stop FIRED on the successful turn (the journal discriminates the events)"; PASS=$((PASS+1))
else
    echo "  FAIL: Stop never fired on a successful turn" >&2; FAIL=$((FAIL+1))
fi
sleep 2
assert_eq "no NEW StopFailure on the successful turn" "$(( $(count_ev StopFailure) - sf_before ))" "0"
# Wait for the clear's own completion line (#1732), on the same ceiling as the
# writer's: the marker read below is a verdict only once the clear has EXITED.
clear_done() { (( $(count_ev StopClearDone) > clear_before )); }
if stop_fired; then
    _cw_t0=$SECONDS
    until clear_done || (( SECONDS - _cw_t0 >= MARKER_WAIT_S )); do sleep 0.25; done
    cl_line=$(awk -F'\t' '$1=="StopClearDone"{l=$0} END{print l}' "$JOURNAL_DIR/events.tsv" 2>/dev/null)
    if clear_done && [[ -n "$cl_line" ]]; then
        IFS=$'\t' read -r _ cl_end cl_rc cl_start <<<"$cl_line"
        echo "        clear: exited rc=$cl_rc after $(awk -v a="$cl_start" -v b="$cl_end" 'BEGIN{printf "%.2f", b-a}') s; waited $(( SECONDS - _cw_t0 )) s past the 2 s settle (ceiling ${MARKER_WAIT_S} s)"
    else
        echo "        clear: NOT YET EXITED after ${MARKER_WAIT_S} s"
    fi
fi
if (( ! nc1_marker_present )); then
    echo "  FAIL: NC-1 clear not testable — no marker existed before the successful turn" >&2; FAIL=$((FAIL+1))
elif [[ ! -e "$MARKER" ]]; then
    echo "  PASS: the REAL Stop clear removed the marker (a successful turn ends the gate)"; PASS=$((PASS+1))
elif clear_done; then
    echo "  FAIL: marker survived a successful turn — the Stop clear EXITED and did not remove it (resolved a different path?)" >&2; FAIL=$((FAIL+1))
else
    echo "  FAIL: marker survived a successful turn — the Stop clear had NOT EXITED after ${MARKER_WAIT_S} s (a slow host or a hung clear; NOT a verdict on the clear, #1732)" >&2; FAIL=$((FAIL+1))
fi

# ---- NC-2: the extractor is not vacuous ---------------------------------
echo
echo "--- NC-2: same extractor on a doctored payload ---"
if [[ -s "$JOURNAL_DIR/stopfailure.json" ]]; then
    DOC="$CCH_DIR/doctored.json"
    jq 'del(.error) | del(.hook_event_name)' "$JOURNAL_DIR/stopfailure.json" > "$DOC" 2>/dev/null
    d_err=$(extract_field "$DOC" '.error'); d_ev=$(extract_field "$DOC" '.hook_event_name')
    if [[ -z "$d_err" && -z "$d_ev" ]]; then
        echo "  PASS: extractor returns empty when the fields are removed"; PASS=$((PASS+1))
    else
        echo "  FAIL: extractor returned error='$d_err' event='$d_ev' from a doctored payload" >&2; FAIL=$((FAIL+1))
    fi
else
    echo "  FAIL: no payload to doctor — NC-2 could not run" >&2; FAIL=$((FAIL+1))
fi

th_summary_and_exit
