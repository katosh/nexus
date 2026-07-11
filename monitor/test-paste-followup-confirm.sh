#!/usr/bin/env bash
# Tests for monitor/paste-followup.sh's submission post-condition
# (your-org/nexus-code#507).
#
# Run: bash monitor/test-paste-followup-confirm.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE CONTRACT UNDER TEST. `tmux send-keys … Enter` returning 0 means
# tmux accepted a keystroke, not that Claude Code submitted the prompt.
# The script must therefore establish the post-condition — a TUI
# submission record in the target session's transcript, or an advanced
# UserPromptSubmit hook stamp — and its exit code must report only what
# it established:
#
#   0  submitted                    (evidence observed)
#   0  --no-enter                   (no submission was intended)
#   3  submission unconfirmed       (unverifiable, or a turn in flight)
#   4  pasted (NOT submitted)       (established negative: session inert)
#
# THE POINT OF THIS FILE, per the issue: *a confirmation path nobody has
# watched fail is not a confirmation path.* Every assertion here was run
# against the pre-fix script first, where `delivered` + exit 0 is printed
# unconditionally; cases 1, 5, 6 and 7 fail there and pass after. To
# re-watch them fail:
#
#     tmp=$(mktemp -d)
#     git show origin/dev:monitor/paste-followup.sh > "$tmp/paste-followup.sh"
#     git show origin/dev:monitor/_tmux-window.sh  > "$tmp/_tmux-window.sh"
#     PASTE_BIN="$tmp/paste-followup.sh" bash monitor/test-paste-followup-confirm.sh
#
# Hermetic: a stub `tmux` on PATH (no tmux server), a synthetic Claude
# Code home (NEXUS_CC_HOME), a synthetic state dir (NEXUS_STATE_DIR),
# and /bin/true for `ng` (PASTE_NG_BIN). The stub decides — per scenario
# — which Enter, if any, appends what kind of line to the transcript.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PASTE_BIN="${PASTE_BIN:-$_test_dir/paste-followup.sh}"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — missing %q\n  in: <<%s>>\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n  in: <<%s>>\n' "$label" "$needle" "$hay" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

command -v jq >/dev/null 2>&1 || { echo "skipped: jq not on PATH"; exit 0; }

# ---- harness -------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

WINDOW="worker-under-test"
SID="11111111-2222-3333-4444-555555555555"
STATE_DIR="$WORK/.state"
CC_HOME="$WORK/cc"
# The slug is deliberately NOT the real `/`+`_` → `-` transform of any
# path: the script must locate the transcript by session-id, never by
# reconstructing the slug.
PROJ_DIR="$CC_HOME/projects/-some-derived-slug"
TRANSCRIPT="$PROJ_DIR/$SID.jsonl"
BIN="$WORK/bin"
mkdir -p "$STATE_DIR/heartbeat" "$STATE_DIR/user-prompt" "$PROJ_DIR" "$BIN"

# A stub `tmux`. Scenario knobs (env, read at call time):
#   STUB_SUBMIT_ON_ENTER  which Enter appends the line (0 = never)
#   STUB_APPEND_KIND      typed | queued | system | sdk | sidechain | toolresult
#   STUB_NOISE_ON_ENTER   append a tool_result line on every Enter (busy turn)
#   STUB_STAMP_ON_ENTER   which Enter writes an advanced UserPromptSubmit stamp
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
counter="$STUB_ENTER_COUNT_FILE"

emit_line() {
    local kind="$1"
    case "$kind" in
      typed)   printf '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":"the follow-up"}}\n' ;;
      queued)  printf '{"type":"user","promptSource":"queued","message":{"role":"user","content":"the follow-up"}}\n' ;;
      system)  printf '{"type":"user","promptSource":"system","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>done</task-notification>"}}\n' ;;
      sdk)     printf '{"type":"user","promptSource":"sdk","message":{"role":"user","content":"subagent turn"}}\n' ;;
      sidechain) printf '{"type":"user","isSidechain":true,"message":{"role":"user","content":"sidechain prompt"}}\n' ;;
      toolresult) printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}\n' ;;
    esac
}

case "${1:-}" in
  list-windows)
      # -F <fmt>
      fmt=""
      while (( $# )); do [[ "$1" == "-F" ]] && { fmt="${2:-}"; break; }; shift; done
      if [[ "$fmt" == *window_id* ]]; then printf '@1\t%s\n' "$STUB_WINDOW"
      else printf '%s\n' "$STUB_WINDOW"; fi
      exit 0 ;;
  send-keys)
      # Only an Enter (the last arg) is interesting.
      last="${!#}"
      if [[ "$last" == "Enter" ]]; then
          n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
          printf '%s' "$n" > "$counter"
          [[ "${STUB_NOISE_ON_ENTER:-0}" == "1" ]] && emit_line toolresult >> "$STUB_TRANSCRIPT"
          if [[ "${STUB_SUBMIT_ON_ENTER:-0}" != "0" && "$n" == "${STUB_SUBMIT_ON_ENTER}" ]]; then
              emit_line "${STUB_APPEND_KIND:-typed}" >> "$STUB_TRANSCRIPT"
          fi
          if [[ "${STUB_STAMP_ON_ENTER:-0}" != "0" && "$n" == "${STUB_STAMP_ON_ENTER}" ]]; then
              printf '%s\t%s\n' "$(( $(date +%s) + 1 ))" "$STUB_SID" \
                  > "$STUB_STATE_DIR/user-prompt/$STUB_WINDOW"
          fi
      fi
      exit 0 ;;
  set-buffer|paste-buffer|delete-buffer) exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/tmux"

# A transcript that ALREADY contains a submitted prompt and some tool
# results. A correct implementation baselines and looks only at what is
# appended after the paste; a naive "does the transcript contain a typed
# prompt?" check would confirm on this pre-existing line alone.
seed_transcript() {
    : > "$TRANSCRIPT"
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the ORIGINAL spawn prompt"}}\n' >> "$TRANSCRIPT"
    printf '{"type":"assistant","message":{"role":"assistant","content":[]}}\n' >> "$TRANSCRIPT"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t0","content":"ok"}]}}\n' >> "$TRANSCRIPT"
}
seed_heartbeat() {
    local sid="${1:-$SID}"
    printf '{"state":"idle_prompt","last_activity":%s,"session_id":"%s","window":"%s"}\n' \
        "$(date +%s)" "$sid" "$WINDOW" > "$STATE_DIR/heartbeat/$WINDOW.json"
}
reset_case() {
    rm -f "$STATE_DIR/user-prompt/$WINDOW" "$STATE_DIR/heartbeat/$WINDOW.json" \
          "$STATE_DIR/machine-input.tsv" "$WORK/enters"
    printf '0' > "$WORK/enters"
    seed_transcript
    seed_heartbeat
}

# Run the script under test with the stubbed world.
run_paste() {
    local _out_var="$1" _rc_var="$2"; shift 2
    local _out _rc
    _out=$(
        PATH="$BIN:$PATH" \
        NEXUS_STATE_DIR="$STATE_DIR" \
        NEXUS_CC_HOME="$CC_HOME" \
        PASTE_NG_BIN=/bin/true \
        PASTE_CONFIRM_TIMEOUT_SECONDS="${TIMEOUT_S:-2}" \
        PASTE_CONFIRM_POLL_SECONDS=0.05 \
        STUB_WINDOW="$WINDOW" \
        STUB_SID="${STUB_SID:-$SID}" \
        STUB_TRANSCRIPT="$TRANSCRIPT" \
        STUB_STATE_DIR="$STATE_DIR" \
        STUB_ENTER_COUNT_FILE="$WORK/enters" \
        env -u NEXUS_ROOT -u NEXUS_LOCALS \
            bash "$PASTE_BIN" "$WINDOW" --message "a follow-up correction" 2>&1
    )
    _rc=$?
    printf -v "$_out_var" '%s' "$_out"
    printf -v "$_rc_var" '%s' "$_rc"
}

OUT=""; RC=""
enters() { cat "$WORK/enters" 2>/dev/null || echo 0; }

# ── 1. THE BUG: Enter accepted, prompt never submitted, session inert ─────
# The whole issue. Pre-fix this prints `delivered` and exits 0.
echo "## 1. Enter accepted but nothing submitted → exit 4, 'NOT submitted'"
reset_case
STUB_SUBMIT_ON_ENTER=0 run_paste OUT RC
assert_eq       "exit code is 4 (established negative)" "$RC" "4"
assert_contains "names the outcome"        "$OUT" "pasted (NOT submitted)"
assert_not_contains "never claims delivery" "$OUT" "delivered"
assert_not_contains "never claims submission" "$OUT" ": submitted"
assert_eq       "Enter was retried exactly once" "$(enters)" "2"

# ── 2. Happy path: the first Enter submits ───────────────────────────────
echo "## 2. first Enter submits → exit 0, 'submitted'"
reset_case
STUB_SUBMIT_ON_ENTER=1 STUB_APPEND_KIND=typed run_paste OUT RC
assert_eq       "exit code is 0"            "$RC" "0"
assert_contains "reports submitted"         "$OUT" "submitted"
assert_eq       "no Enter retry was needed" "$(enters)" "1"

# ── 3. Collapsed paste: only the SECOND Enter submits ────────────────────
# `[Pasted text #N +N lines]` — the mechanism #507 names. The retry is
# the fix; without it this window would hang on queued text forever.
echo "## 3. collapsed paste, second Enter submits → exit 0, retried once"
reset_case
STUB_SUBMIT_ON_ENTER=2 STUB_APPEND_KIND=typed run_paste OUT RC
assert_eq       "exit code is 0"                 "$RC" "0"
assert_contains "reports the retry"              "$OUT" "after one Enter retry"
assert_eq       "Enter sent twice"               "$(enters)" "2"

# ── 4. A `queued` submission (pasted into a busy pane, drained later) ────
echo "## 4. promptSource=queued counts as a submission → exit 0"
reset_case
STUB_SUBMIT_ON_ENTER=1 STUB_APPEND_KIND=queued run_paste OUT RC
assert_eq       "exit code is 0"    "$RC" "0"
assert_contains "reports submitted" "$OUT" "submitted"

# ── 5. FALSE-POSITIVE GUARD: a task-notification is not our prompt ───────
# `<task-notification>` injections are string-content `"type":"user"`
# lines. A "did a new user message appear?" test confirms on them and
# reports success for a paste that never submitted. It must not.
echo "## 5. task-notification (promptSource=system) must NOT confirm"
reset_case
STUB_SUBMIT_ON_ENTER=1 STUB_APPEND_KIND=system run_paste OUT RC
assert_eq           "exit code is non-zero"  "$([[ "$RC" != 0 ]] && echo yes || echo no)" "yes"
assert_not_contains "does not report submitted" "$OUT" ": submitted"
assert_not_contains "never claims delivery"     "$OUT" "delivered"

# ── 6. FALSE-POSITIVE GUARD: an SDK/sidechain turn is not our prompt ─────
echo "## 6. sdk turn must NOT confirm"
reset_case
STUB_SUBMIT_ON_ENTER=1 STUB_APPEND_KIND=sdk run_paste OUT RC
assert_eq           "exit code is non-zero"  "$([[ "$RC" != 0 ]] && echo yes || echo no)" "yes"
assert_not_contains "does not report submitted" "$OUT" ": submitted"

echo "## 6b. sidechain turn must NOT confirm"
reset_case
STUB_SUBMIT_ON_ENTER=1 STUB_APPEND_KIND=sidechain run_paste OUT RC
assert_eq           "exit code is non-zero"  "$([[ "$RC" != 0 ]] && echo yes || echo no)" "yes"
assert_not_contains "does not report submitted" "$OUT" ": submitted"

# ── 7. Unverifiable: no heartbeat ⇒ no session-id ⇒ nothing to poll ──────
# Honest exit 3. It must NOT silently succeed, and must NOT claim a
# negative it did not establish.
echo "## 7. no heartbeat → exit 3, 'unconfirmed', reason named"
reset_case
rm -f "$STATE_DIR/heartbeat/$WINDOW.json"
STUB_SUBMIT_ON_ENTER=0 run_paste OUT RC
assert_eq       "exit code is 3"        "$RC" "3"
assert_contains "says unconfirmed"      "$OUT" "submission unconfirmed"
assert_contains "names the reason"      "$OUT" "no session-id"
assert_not_contains "never claims delivery" "$OUT" "delivered"

# ── 8. Unverifiable: heartbeat points at a session with no transcript ────
echo "## 8. session-id with no transcript → exit 3"
reset_case
seed_heartbeat "99999999-9999-9999-9999-999999999999"
STUB_SUBMIT_ON_ENTER=0 run_paste OUT RC
assert_eq       "exit code is 3"   "$RC" "3"
assert_contains "names the reason" "$OUT" "no transcript for session"

# ── 9. A turn in flight: transcript grows, no submission ⇒ 3, not 4 ──────
# The text is plausibly queued behind the running turn. We did not
# establish a negative, so we must not assert one.
echo "## 9. turn in flight (tool_results appended, no submission) → exit 3"
reset_case
STUB_SUBMIT_ON_ENTER=0 STUB_NOISE_ON_ENTER=1 run_paste OUT RC
assert_eq       "exit code is 3"          "$RC" "3"
assert_contains "says a turn is in flight" "$OUT" "turn is in flight"
assert_not_contains "not an established negative" "$OUT" "pasted (NOT submitted) to"

# ── 10. The other evidence surface: the UserPromptSubmit hook stamp ──────
echo "## 10. hook stamp advances (transcript inert) → exit 0"
reset_case
STUB_SUBMIT_ON_ENTER=0 STUB_STAMP_ON_ENTER=1 run_paste OUT RC
assert_eq       "exit code is 0"    "$RC" "0"
assert_contains "reports submitted" "$OUT" "submitted"

# ── 11. Hook stamp for a DIFFERENT session must not confirm ──────────────
# Workers and skeptics share a clone; a stamp from the neighbouring
# session is not evidence about ours.
echo "## 11. hook stamp from another session must NOT confirm"
reset_case
STUB_SID="another-session-id" STUB_SUBMIT_ON_ENTER=0 STUB_STAMP_ON_ENTER=1 run_paste OUT RC
assert_eq           "exit code is 4"            "$RC" "4"
assert_not_contains "does not report submitted" "$OUT" ": submitted"

# ── 12. Session-id changed under us (window resumed mid-paste) → 3 ───────
echo "## 12. stale session-id, heartbeat rotates → exit 3, not a false negative"
reset_case
# The stub rotates the heartbeat to a new session on the first Enter.
cat > "$BIN/rotate-hb" <<ROT
#!/usr/bin/env bash
printf '{"state":"busy","last_activity":%s,"session_id":"%s","window":"%s"}\n' \
    "\$(date +%s)" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "$WINDOW" \
    > "$STATE_DIR/heartbeat/$WINDOW.json"
ROT
chmod +x "$BIN/rotate-hb"
( sleep 0.4; "$BIN/rotate-hb" ) &
_rot=$!
STUB_SUBMIT_ON_ENTER=0 run_paste OUT RC
wait "$_rot" 2>/dev/null || true
assert_eq       "exit code is 3"        "$RC" "3"
assert_contains "names the session churn" "$OUT" "session-id changed under us"

# ── 13. --no-enter: nothing was meant to submit; no claim, exit 0 ────────
echo "## 13. --no-enter → exit 0, explicitly NOT submitted, no Enter sent"
reset_case
OUT=$(
    PATH="$BIN:$PATH" NEXUS_STATE_DIR="$STATE_DIR" NEXUS_CC_HOME="$CC_HOME" \
    PASTE_NG_BIN=/bin/true PASTE_CONFIRM_POLL_SECONDS=0.05 \
    STUB_WINDOW="$WINDOW" STUB_SID="$SID" STUB_TRANSCRIPT="$TRANSCRIPT" \
    STUB_STATE_DIR="$STATE_DIR" STUB_ENTER_COUNT_FILE="$WORK/enters" \
    STUB_SUBMIT_ON_ENTER=0 \
    env -u NEXUS_ROOT -u NEXUS_LOCALS \
        bash "$PASTE_BIN" "$WINDOW" --message "queued text" --no-enter 2>&1
)
RC=$?
assert_eq       "exit code is 0"          "$RC" "0"
assert_contains "explicit about no submit" "$OUT" "NOT submitted, --no-enter"
assert_eq       "no Enter was sent"       "$(enters)" "0"

# ── 14. The paste stamp survives a failed confirmation ───────────────────
# The watcher's `paste-unconfirmed` detector reads machine-input.tsv. A
# paste that landed but did not submit must stay stamped, so the watcher
# agrees with us instead of misattributing the pane churn to the operator.
echo "## 14. machine-input stamp is retained on a NOT-submitted verdict"
reset_case
STUB_SUBMIT_ON_ENTER=0 run_paste OUT RC
assert_eq       "exit code is 4" "$RC" "4"
assert_contains "stamp was written" "$(cat "$STATE_DIR/machine-input.tsv" 2>/dev/null)" "$WINDOW"
assert_contains "stamp src is paste-followup" "$(cat "$STATE_DIR/machine-input.tsv" 2>/dev/null)" "paste-followup"

# ---- summary -------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
fi
printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
exit 1
