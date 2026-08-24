#!/usr/bin/env bash
# test-realmodel-pretooluse-hook.sh — real-binary scenario pinning the
# **PreToolUse hook contract** the nexus control surface rides on.
#
# WHY THIS EXISTS (your-org/other-nexus, cc-update rigor fix)
#
# GUIDE surface 2d is "hooks + settings schema". Until this file, the gate
# could not cover it: `cch_boot_worker` passed no `--settings` at all, so
# three of the four gate scenarios booted hook-free, and the only hook
# wiring anywhere in the suite was test-realmodel-overlimit.sh's
# `StopFailure → over-limit-emit.sh` + `Stop → clear`. So when a changelog
# entry touched **PreToolUse** (2.1.222: "Fixed PreToolUse auto-allow hooks
# bypassing tool restrictions in background agent tasks (summaries,
# compaction, renames)"), the evaluation credited "partial gate coverage"
# for a DIFFERENT hook event, and 2d was in truth cleared by source
# inspection — every round, for six rounds running.
#
# This scenario closes that gap by driving the REAL binary through a REAL
# Bash tool call with a REAL `--settings`-wired PreToolUse hook, and
# asserting the exact payload fields the production nexus guards parse:
#
#   monitor/hooks/gh-write-guard.sh:41-45
#       .tool_name  == "Bash"      → else exit 0
#       .tool_input.command        → else exit 0
#   monitor/hooks/bash-footgun-guard.sh
#       same two fields, plus hookSpecificOutput/additionalContext
#
# A rename of the event, a reshaped payload, or a dropped `tool_input`
# silently disables BOTH guards — the class of breakage that shows up in
# production as "the footgun guard stopped firing" with no error anywhere.
#
# ── The rigor contract: this test must be able to go RED ────────────────
#
# A gate assertion that cannot fail is worse than no assertion — it
# launders a reachability claim into "I tested it", which is the exact
# defect this whole file was written to stop. So the scenario ships TWO
# negative controls and asserts them inline:
#
#   NC-1 (behaviour stripped) — boot a second worker with NO `--settings`,
#        drive the IDENTICAL tool call, and require that the marker is
#        NOT written. This proves the marker's presence in the positive
#        arm is caused by the hook wiring, not by the harness, the mock,
#        or the act of running a tool. It is the differential control the
#        2.1.222 VI probe lacked.
#   NC-2 (assertion broken) — run the SAME field extractor against a
#        doctored payload with `tool_name` deleted, and require it to come
#        back empty. This proves the extractor reads the real field rather
#        than always succeeding (the 2.1.218 failure mode: a turn-counter
#        regex that never matched anything, yet reported PASS).
#
# If you ever weaken the positive arm, weaken these in the same commit or
# the gate goes back to being decorative.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips cleanly (exit 77 under CCH_GATE=1 — a skip is RED for the
# gate, never a silent pass). See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled

# jq is how both production guards parse the payload; without it this
# scenario cannot assert the contract at all. Treat as a skip (RED under
# the gate), never a pass.
if ! command -v jq >/dev/null 2>&1; then
    echo "skipped: $(basename "$0") (jq not on PATH — needed to parse the hook payload)"
    [[ "${CCH_GATE:-0}" == "1" ]] && exit 77
    exit 0
fi

cch_setup

PASS=0; FAIL=0

PROBE_CMD="echo NEXUS_PRETOOLUSE_PROBE"
MARK_DIR="$CCH_DIR/hookmarks"
mkdir -p "$MARK_DIR"

echo "=== real-binary PreToolUse: hook fires, payload shape intact (GUIDE 2d) ==="
echo "    claude:  $CLAUDE_BIN"
echo "    version: $("$CLAUDE_BIN" --version 2>/dev/null || echo '?')"
echo "    mock:    127.0.0.1:$CCH_MOCK_PORT"

# ---- the hook: capture stdin verbatim, then disarm the tool loop ----------
# The hook writes the payload it was handed and rewrites the mock's control
# file to plain text, so the follow-up model call after the tool result ends
# the turn instead of requesting another Bash call forever. It always
# exits 0 — this scenario pins the payload CONTRACT, not a decision.
write_hook_script() {
    local path="$1" marker="$2"
    cat > "$path" <<EOF
#!/usr/bin/env bash
# harness-only PreToolUse probe hook (cc-harness scenario)
payload=\$(cat)
printf '%s' "\$payload" > $(printf '%q' "$marker")
printf '{"mode":"text","text":"probe done"}\n' > $(printf '%q' "$CCH_CONTROL")
exit 0
EOF
    chmod +x "$path"
}

write_settings() {
    local path="$1" hook="$2"
    jq -n --arg h "$hook" '{hooks: {
        PreToolUse: [ { matcher: "Bash", hooks: [ {type:"command", command:$h} ] } ]
    }}' > "$path"
}

# Send a prompt and poll a predicate, retrying the prompt once (a first
# prompt can be swallowed by REPL boot). Mirrors drive_until in
# test-realmodel-overlimit.sh.
drive_until() {
    local idx="$1" prompt="$2"; shift 2
    local attempt i
    for attempt in 1 2; do
        cch_send "$idx" "$prompt"
        for i in $(seq 1 60); do
            "$@" && return 0
            sleep 0.5
        done
        echo "    (attempt $attempt: predicate not yet true; retrying the prompt)"
    done
    "$@"
}

arm_tool_call() {
    cch_control "$(jq -nc --arg c "$PROBE_CMD" \
        '{mode:"tool_use", tool:{name:"Bash", input:{command:$c}}}')"
}

# ---- ARM A (positive): hooks wired → PreToolUse fires --------------------
echo
echo "--- ARM A: --settings-wired PreToolUse hook on a real Bash tool call ---"

MARK_A="$MARK_DIR/pretooluse-armA.json"
HOOK_A="$CCH_DIR/pretooluse-hook-armA.sh"
SET_A="$CCH_DIR/settings-armA.json"
write_hook_script "$HOOK_A" "$MARK_A"
write_settings "$SET_A" "$HOOK_A"

IDX_A=$(CCH_SETTINGS="$SET_A" cch_boot_worker ptu-armA)
[[ -n "$IDX_A" ]] || { echo "FATAL: ARM A worker window never appeared" >&2; exit 1; }

# Pre-condition: the marker is NOT pre-seeded. Without this, "the file
# exists" would prove nothing about the hook.
if [[ ! -e "$MARK_A" ]]; then
    echo "  PASS: marker absent before the tool call (not pre-seeded)"; PASS=$((PASS+1))
else
    echo "  FAIL: marker existed before the tool call — the arm is vacuous" >&2; FAIL=$((FAIL+1))
fi

arm_tool_call
marked_a() { [[ -s "$MARK_A" ]]; }
if drive_until "$IDX_A" "run the probe command please" marked_a; then
    echo "  PASS: PreToolUse hook FIRED on the candidate"; PASS=$((PASS+1))
else
    echo "  FAIL: PreToolUse hook never fired — 2d contract broken on this candidate" >&2
    FAIL=$((FAIL+1))
fi

# ---- the payload fields the production guards parse ----------------------
# Extractor kept as a function so NC-2 can run the IDENTICAL code against a
# doctored payload — that is what makes NC-2 a control on the extractor
# rather than a second hand-written grep.
extract_field() {
    local file="$1" filter="$2"
    jq -r "$filter // empty" "$file" 2>/dev/null
}

# assert_eq's signature is `label got want` — ACTUAL first. Equality is
# symmetric so pass/fail is right either way, but the argument order is what
# makes the RED diagnostic (`got X want Y`) readable in the one moment it
# matters. Keep the observed value first.
if [[ -s "$MARK_A" ]]; then
    got_event=$(extract_field "$MARK_A" '.hook_event_name')
    got_tool=$(extract_field  "$MARK_A" '.tool_name')
    got_cmd=$(extract_field   "$MARK_A" '.tool_input.command')
    echo "        payload: hook_event_name=${got_event:-<none>} tool_name=${got_tool:-<none>} command=${got_cmd:-<none>}"

    assert_eq "payload carries hook_event_name=PreToolUse" "$got_event" "PreToolUse"
    assert_eq "payload carries tool_name=Bash (gh-write-guard.sh:41-42)" "$got_tool" "Bash"
    assert_eq "payload carries an intact .tool_input.command (gh-write-guard.sh:44-45)" \
        "$got_cmd" "$PROBE_CMD"
else
    echo "  FAIL: no payload captured — cannot assert the field contract" >&2
    FAIL=$((FAIL+1))
fi

# ---- NC-1 (differential control): hooks stripped → hook must NOT fire ----
# The control the 2.1.222 VI probe was missing. Same binary, same mock,
# same tool call, ONLY the --settings wiring removed.
echo
echo "--- NC-1: identical tool call with NO --settings (behaviour stripped) ---"

MARK_N="$MARK_DIR/pretooluse-nc1.json"
HOOK_N="$CCH_DIR/pretooluse-hook-nc1.sh"
write_hook_script "$HOOK_N" "$MARK_N"     # written, but never wired to anything

IDX_N=$(CCH_SETTINGS="" cch_boot_worker ptu-nc1)
[[ -n "$IDX_N" ]] || { echo "FATAL: NC-1 worker window never appeared" >&2; exit 1; }

# Count the tool_use turns the mock has ALREADY served (ARM A served one),
# so the predicate below waits for a NEW one rather than re-reading ARM A's
# — a whole-file count, never a tail slice.
_tool_use_turns() {
    local n
    n=$(grep -c 'mode=tool_use' "$CCH_LOG" 2>/dev/null || true)
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
TU_BEFORE=$(_tool_use_turns)
echo "        tool_use turns served before NC-1: $TU_BEFORE"

arm_tool_call
# Drive a REAL turn (not a sleep): require the mock to serve a NEW tool_use
# response, i.e. the binary genuinely reached the tool-call path with the
# hook wiring absent.
turn_ran() { (( $(_tool_use_turns) > TU_BEFORE )); }
drive_until "$IDX_N" "run the probe command please" turn_ran >/dev/null
echo "        tool_use turns served after NC-1:  $(_tool_use_turns)"
# Disarm so the tool loop cannot spin: the in-flight tool call still
# executes (that is what we are observing), the NEXT model call ends the turn.
cch_control '{"mode":"text","text":"nc1 done"}'
# Give the (absent) hook a budget comparable to the positive arm's.
sleep 5
if [[ ! -e "$MARK_N" ]]; then
    echo "  PASS: no --settings → PreToolUse marker NOT written (probe discriminates)"
    PASS=$((PASS+1))
else
    echo "  FAIL: marker appeared WITHOUT --settings — ARM A proves nothing about hooks" >&2
    FAIL=$((FAIL+1))
fi

# ---- NC-2 (broken-assertion control): the extractor is not vacuous -------
echo
echo "--- NC-2: same extractor on a doctored payload (assertion can go red) ---"
if [[ -s "$MARK_A" ]]; then
    DOCTORED="$CCH_DIR/pretooluse-doctored.json"
    jq 'del(.tool_name) | del(.tool_input.command)' "$MARK_A" > "$DOCTORED" 2>/dev/null
    d_tool=$(extract_field "$DOCTORED" '.tool_name')
    d_cmd=$(extract_field  "$DOCTORED" '.tool_input.command')
    if [[ -z "$d_tool" && -z "$d_cmd" ]]; then
        echo "  PASS: extractor returns empty when the fields are removed (not vacuous)"
        PASS=$((PASS+1))
    else
        echo "  FAIL: extractor still returned tool_name='$d_tool' command='$d_cmd' from a doctored payload" >&2
        FAIL=$((FAIL+1))
    fi
else
    echo "  FAIL: no ARM A payload to doctor — NC-2 could not run" >&2
    FAIL=$((FAIL+1))
fi

th_summary_and_exit
