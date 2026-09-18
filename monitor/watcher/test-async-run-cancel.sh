#!/usr/bin/env bash
# monitor/watcher/test-async-run-cancel.sh — tests for `async-run.sh --cancel`,
# the record-authorised stop verb (your-org/nexus-code#1308 §3).
#
# THE PROBLEM. Three runaway `guards-for-diff --run` jobs could not be stopped
# by the agent that launched them. `async-run.sh` had no cancel verb, and
# `proc-kill-authorized` REFUSES a setsid-detached job — correctly: a setsid
# process is its own session leader, so a session-ownership SCAN of live
# processes cannot attribute it to anyone, and its default-deny arm fires. The
# launcher of a job it owns therefore had no sanctioned way to stop it.
#
# WHAT IS UNDER TEST is therefore NOT "can it kill a process". It is whether
# the AUTHORIZATION is sound, because a cancel verb that authorises too widely
# is a general kill facility wearing a safe name — and the guard it would be
# routing around (`proc-kill-authorized`'s default-deny) is one this repo
# depends on. So the suite is weighted toward the REFUSALS:
#
#   - a token owned by ANOTHER session               -> DENIED   (6)
#   - a token with NO recorded owner (a pre-fix one) -> REFUSED  (7)
#   - a caller with no session id of its own         -> REFUSED  (7)
#   - a cross-window READ override in play           -> REFUSED  (7)
#   - a recorded pid whose identity is unverifiable  -> REFUSED  (8)
#
# and in particular on 6 BEING DISTINCT FROM 7. "Not yours" and "I could not
# tell" are different facts; merging them is how a default-deny arm rots into
# a default-allow one, which is the failure this verb exists not to have.
#
# The positive path is tested too, including that a cancelled job reports
# `cancelled` and NOT `died` — collapsing those would re-create, inside the
# fix, the very fusion async-run.sh exists to prevent.
#
# Run: bash monitor/watcher/test-async-run-cancel.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
AR="$_repo_root/monitor/async-run.sh"
[[ -x "$AR" ]] || { echo "not executable: $AR" >&2; exit 1; }

. "$_test_dir/_test_helpers.sh"

if ! command -v setsid >/dev/null 2>&1; then
    th_skip "setsid unavailable — async-run.sh cannot detach on this host"
    th_summary_and_exit
fi

WORK=$(mktemp -d)
cleanup() {
    # Reap anything the fixture launched before the temp tree goes away.
    th_reap_fixture_root "$WORK" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

export NEXUS_ROOT="$_repo_root"
export NEXUS_STATE_DIR="$WORK/.state"
export NEXUS_WORKER_WINDOW="arc"
SESS_A="aaaaaaaa-1111-2222-3333-444444444444"
SESS_B="bbbbbbbb-5555-6666-7777-888888888888"

. "$_repo_root/monitor/_bookkeeping.sh" 2>/dev/null || true
ROOT="$WORK/.state/async-run/$(wk_encode arc)"

launch_as() {  # launch_as <session> -- <cmd…>
    local sess="$1"; shift; [[ "$1" == "--" ]] && shift
    # `--allow-concurrent`: this suite launches byte-identical `sleep 60` jobs
    # on purpose (one per ownership scenario); the #1389 duplicate-launch guard
    # would otherwise refuse every launch after the first and hand `--cancel`
    # an empty token (measured: 10 reds at rc 2 the day the guard landed).
    CLAUDE_CODE_SESSION_ID="$sess" "$AR" --desc t --allow-concurrent -- "$@" | sed -n 's/^  token   //p'
}
verdict() { CLAUDE_CODE_SESSION_ID="$SESS_A" "$AR" --status-line "$1"; }
cancel_as() { local sess="$1" tok="$2"; CLAUDE_CODE_SESSION_ID="$sess" "$AR" --cancel "$tok" 2>&1; }
cancel_rc() { local sess="$1" tok="$2"
    CLAUDE_CODE_SESSION_ID="$sess" "$AR" --cancel "$tok" >/dev/null 2>&1; printf '%s' "$?"; }

# wait_gone <pid> — BOUNDED. An unbounded poll in a test is the defect class
# the subject fixes; a deadline that expires is reported, never treated as
# confirmation.
wait_gone() {
    local p="$1" i=0
    while (( i < 40 )); do
        kill -0 "$p" 2>/dev/null || return 0
        sleep 0.25; i=$(( i + 1 ))
    done
    return 1
}

echo "== async-run.sh --cancel =="

# ---------------------------------------------------------- t_record -------
# The owning session must be RECORDED at launch. Everything below rests on it,
# and #1308's three tokens were uncancellable precisely because nothing wrote
# it down.
t_rec=$(launch_as "$SESS_A" -- sleep 60)
assert_file_exists "launch records an owning session" "$ROOT/$t_rec/session"
assert_eq "…and it is the launching session"          "$(cat "$ROOT/$t_rec/session")" "$SESS_A"
assert_eq "…and the owning window too"                "$(cat "$ROOT/$t_rec/window")"  "arc"

# ---------------------------------------------------------- t_denied -------
# A DIFFERENT session must be DENIED, with the code that means "not yours".
out=$(cancel_as "$SESS_B" "$t_rec"); rc=$?
assert_rc       "a token owned by another session → DENIED (6)" "$rc" 6
assert_contains "…naming both sessions"                          "$out" "$SESS_A"
assert_contains "…and it says DENIED, not REFUSED"               "$out" "DENIED"
assert_eq       "…and the job is UNTOUCHED by a denied cancel"   "$(verdict "$t_rec" | cut -d'|' -f1)" "running"
assert_no_file  "…and no cancellation marker was written"        "$ROOT/$t_rec/cancelled"

# ---------------------------------------------------------- t_owner --------
# The OWNER may cancel, and the result must read `cancelled`, never `died`.
pid=$(cat "$ROOT/$t_rec/pid")
out=$(cancel_as "$SESS_A" "$t_rec"); rc=$?
assert_rc       "the owning session may cancel (rc 0)"  "$rc" 0
assert_file_exists "…a cancellation marker is recorded" "$ROOT/$t_rec/cancelled"
if wait_gone "$pid"; then
    v=$(verdict "$t_rec")
    assert_eq       "a cancelled job reads 'cancelled'"                      "${v%%|*}" "cancelled"
    assert_not_contains "…and NOT 'died' — a deliberate stop is not a mystery death" "${v%%|*}" "died"
    assert_contains "…naming the session that cancelled it"                  "$v" "$SESS_A"
else
    th_skip "cancelled pid $pid did not exit within 10s — cannot assert the terminal verdict"
fi

# -------------------------------------------------------- t_no_owner ------
# THE #1308 TOKENS THEMSELVES: a record with no session. Must REFUSE (7), and
# must NOT fall back to any weaker ownership test.
t_old=$(launch_as "$SESS_A" -- sleep 60)
rm -f "$ROOT/$t_old/session"
out=$(cancel_as "$SESS_A" "$t_old"); rc=$?
assert_rc       "a token with NO recorded owner → REFUSED (7), not cancelled" "$rc" 7
assert_contains "…and it says REFUSED"                                        "$out" "REFUSED"
assert_eq       "…and the job is UNTOUCHED"        "$(verdict "$t_old" | cut -d'|' -f1)" "running"
assert_no_file  "…and no marker was written"                                  "$ROOT/$t_old/cancelled"

# An EMPTY session file is the same case as a missing one — a present-but-blank
# record is not evidence of ownership.
printf '\n' > "$ROOT/$t_old/session"
assert_rc "an EMPTY owner record → REFUSED (7), same as missing" "$(cancel_rc "$SESS_A" "$t_old")" 7

# ------------------------------------------------------- t_no_caller_id ---
# "I do not know who I am" is not "I am the owner".
printf '%s\n' "$SESS_A" > "$ROOT/$t_old/session"
rc=$(CLAUDE_CODE_SESSION_ID= "$AR" --cancel "$t_old" >/dev/null 2>&1; printf '%s' "$?")
assert_rc "a caller with no session id of its own → REFUSED (7)" "$rc" 7
assert_eq "…and the job is UNTOUCHED" "$(verdict "$t_old" | cut -d'|' -f1)" "running"

# ------------------------------------------------------- t_cross_window ---
# NEXUS_ASYNC_RUN_WINDOW is a READ-ONLY resolver. It must not be able to select
# the target of a signal, or a read override becomes a write capability over
# every window.
rc=$(NEXUS_ASYNC_RUN_WINDOW=arc CLAUDE_CODE_SESSION_ID="$SESS_A" \
     "$AR" --cancel "$t_old" >/dev/null 2>&1; printf '%s' "$?")
assert_rc "a cross-window READ override may not target a cancel → REFUSED (7)" "$rc" 7
assert_eq "…and the job is UNTOUCHED" "$(verdict "$t_old" | cut -d'|' -f1)" "running"

# --------------------------------------------------------- t_pid_ident ----
# PID IDENTITY, NOT LIVENESS — and the two failure modes are NOT the same,
# which is why they get separate cases. `_pid_alive` returns:
#   2  the pid exists but its identity is UNVERIFIABLE (no recorded
#      start-time). We must NOT signal: the number may belong to anything.
#   1  the pid exists and its start-time MISMATCHES, i.e. the number was
#      RECYCLED into an unrelated process — so OUR process is gone. Also must
#      not signal, but for the opposite reason, and the right response is to
#      record the cancellation so the token does not read `died`.
# Testing only one of these would leave the other's arm unpinned.

# --- 2: unverifiable identity -> REFUSED (8), nothing touched
t_ident=$(launch_as "$SESS_A" -- sleep 60)
: > "$ROOT/$t_ident/pidstart"          # unreadable/absent start-time
out=$(cancel_as "$SESS_A" "$t_ident"); rc=$?
assert_rc       "a recorded pid whose identity is UNVERIFIABLE → REFUSED (8)" "$rc" 8
assert_contains "…and it explains that pids recycle"                          "$out" "recycle"
assert_no_file  "…and nothing was signalled or marked"                        "$ROOT/$t_ident/cancelled"
assert_eq       "…and the job is UNTOUCHED"  "$(verdict "$t_ident" | cut -d'|' -f1)" "unknown"

# --- 1: recycled pid -> our process is GONE; record, do NOT signal
t_recyc=$(launch_as "$SESS_A" -- sleep 60)
_rpid=$(cat "$ROOT/$t_recyc/pid")
printf '%s\n' "99999999999" > "$ROOT/$t_recyc/pidstart"
out=$(cancel_as "$SESS_A" "$t_recyc"); rc=$?
assert_rc       "a RECYCLED pid → rc 0, and explicitly NOT signalled" "$rc" 0
assert_contains "…saying nothing was signalled"                       "$out" "Nothing was signalled"
assert_file_exists "…but the cancellation IS recorded, so it cannot read 'died'" \
                "$ROOT/$t_recyc/cancelled"
assert_eq       "…and the marker records that no signal was sent" \
                "$(sed -n 's/^signalled=//p' "$ROOT/$t_recyc/cancelled")" "no"
# POSITIVE CONTROL ON THE REFUSAL: the real process must be UNHARMED — a cancel
# that refuses to signal and kills anyway would pass every assertion above.
assert_eq "…and the REAL process is still alive (the refusal did not signal it)" \
          "$(kill -0 "$_rpid" 2>/dev/null && echo alive || echo gone)" "alive"
kill -TERM "$_rpid" 2>/dev/null || true

# ---------------------------------------------------------- t_no_token ----
assert_rc "an unknown token → 5, distinct from every ownership code" \
          "$(cancel_rc "$SESS_A" "ar-nosuchtoken")" 5

# THE CODES MUST BE DISTINCT. If two of these collapse, the caller cannot tell
# a refusal from a denial, which is the whole point.
codes=$(printf '%s\n' 5 6 7 8 | sort -u | wc -l)
assert_eq "the four refusal codes are four distinct values" "$codes" "4"

# ------------------------------------------------------ t_already_done ----
t_done=$(launch_as "$SESS_A" -- true)
i=0; while (( i < 40 )) && [[ ! -s "$ROOT/$t_done/status" ]]; do sleep 0.25; i=$(( i + 1 )); done
if [[ -s "$ROOT/$t_done/status" ]]; then
    out=$(cancel_as "$SESS_A" "$t_done"); rc=$?
    assert_rc       "cancelling an already-finished job is not an error (rc 0)" "$rc" 0
    assert_contains "…and it says there was nothing to cancel"                  "$out" "nothing to cancel"
    assert_eq       "…and the real rc is preserved" "$(verdict "$t_done" | cut -d'|' -f1)" "terminal"
else
    th_skip "the trivial job never wrote a status within 10s"
fi

# --------------------------------------------------- t_status_wins -------
# ARM ORDER: a real rc beats a cancel marker. A job that finished anyway must
# report its ACTUAL outcome, with the cancellation annotated rather than
# allowed to discard it.
t_race=$(launch_as "$SESS_A" -- true)
i=0; while (( i < 40 )) && [[ ! -s "$ROOT/$t_race/status" ]]; do sleep 0.25; i=$(( i + 1 )); done
printf 'by=%s\nat=1\nsignalled=yes\n' "$SESS_A" > "$ROOT/$t_race/cancelled"
v=$(verdict "$t_race")
assert_eq       "a status file beats a cancel marker → terminal" "${v%%|*}" "terminal"
assert_contains "…carrying the REAL rc"                          "$v" "rc=0"
assert_contains "…and the cancellation is annotated, not dropped" "$v" "cancellation was requested"

# ------------------------------------------------- t_cancel_requested ----
# MARKER BEFORE SIGNAL. With a marker present and the pid still alive, the
# verdict must say so — that is the OBSERVABLE failure direction the ordering
# is chosen for. If it reported plain `cancelled` here it would be claiming an
# outcome that has not happened.
t_live=$(launch_as "$SESS_A" -- sleep 60)
printf 'by=%s\nat=1\nsignalled=yes\n' "$SESS_A" > "$ROOT/$t_live/cancelled"
v=$(verdict "$t_live")
assert_eq       "marker present + pid ALIVE → cancel-requested, not cancelled" "${v%%|*}" "cancel-requested"
assert_contains "…and it says the process is still alive"                      "$v" "STILL ALIVE"
CLAUDE_CODE_SESSION_ID="$SESS_A" "$AR" --cancel "$t_live" >/dev/null 2>&1 || true

# COUNT GUARD (your-org/nexus-code#821 / #1308). The ledger proves no assertion
# was LOST in a subshell; it cannot prove one was never REACHED. A suite whose
# arms stop running still prints a green summary of whatever did run, so the
# count is declared here and compared EXACTLY. Bump it deliberately when adding
# an arm; a mismatch is a red, not a warning.
EXPECTED_ASSERTIONS=41
_run_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
