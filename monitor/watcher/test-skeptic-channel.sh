#!/usr/bin/env bash
# Tests for the nexus skeptic protocol (skills/nexus.skeptic), PR #285:
#   - monitor/skeptic-channel.sh — the worker↔skeptic comms channel:
#     the WORKER-run await→ack→answer→re-await loop, the DONE sentinel
#     terminal exit (10), atomic-rename race safety, the skeptic-side
#     await-answer / reconcile / close, and the nudge guards (rate-limit,
#     pane-state skip, name→index fail-safe).
#   - monitor/ng `_wrapup_skeptic_step` — wrap-up enforcement: require
#     emits + sets pending; auto presents/records a decision; deny
#     skips; the skeptic role path logs a verdict and applies the
#     bounded-recursion decision (second-pass / escalate / terminate).
#
# The PostToolUse autodetect hook was removed in PR #285 (it only fired
# while the worker issued tool calls, but a worker is idle exactly when a
# skeptic probes its result — the worker-run await loop replaces it).
#
# Run: bash monitor/watcher/test-skeptic-channel.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Hermetic: NEXUS_STATE_DIR points every component at a temp dir; the
# nudge's paste + pane-state helpers are injected via SKEPTIC_PASTE_BIN
# / SKEPTIC_PANESTATE_BIN stubs, so no tmux and no real Claude pane.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
CHAN="$_repo_root/monitor/skeptic-channel.sh"
NG="$_repo_root/monitor/ng"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }
assert_contains() { [[ -n "$3" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2; [[ -n "$3" ]] && grep -qF -- "$3" <<<"$2" && ok "$1" || bad "$1" "missing [$3] in <<$2>>"; }
assert_not_contains() { grep -qF -- "$3" <<<"$2" && bad "$1" "unexpected [$3] in <<$2>>" || ok "$1"; }
assert_file()    { [[ -f "$2" ]] && ok "$1" || bad "$1" "missing file $2"; }
assert_nofile()  { [[ ! -e "$2" ]] && ok "$1" || bad "$1" "unexpected file $2"; }

[[ -x "$CHAN" ]] || { echo "missing $CHAN" >&2; exit 1; }
[[ -x "$NG" ]]   || { echo "missing $NG" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/.state"

# ============================================================
echo '=== channel: worker await → ack → answer → re-await lifecycle ==='
# ============================================================
TASK=worker-alpha
"$CHAN" init "$TASK" >/dev/null
p1=$("$CHAN" ask "$TASK" why-lr --message "Why lr=1e-4 when spec says 5e-5?")
assert_contains "ask writes req-001 .open.md" "$p1" "req-001-why-lr.open.md"
assert_file "req-001 file exists" "$p1"
p2=$("$CHAN" ask "$TASK" repro --message "Repro the 0% baseline on a known case.")
assert_contains "ask auto-increments to req-002" "$p2" "req-002-repro.open.md"
assert_eq "status: 2 open" "$("$CHAN" status "$TASK")" "open=2 ack=0 answered=0 total=2 done=0"

# Atomic publish: ask builds a temp then renames; no temp ever matches
# the *.open.md glob the worker acts on (partial-write race guard).
assert_eq "ask leaves no temp visible to the open glob" \
    "$(cd "$(dirname "$p1")" && ls .req-* 2>/dev/null | wc -l | tr -d ' ')" "0"

# WORKER await: acks every open request (rename .open.md → .ack.md),
# prints the ack paths, exits 0. --once = single poll, no blocking.
awk_out=$("$CHAN" await "$TASK" --once); rc=$?
assert_eq "worker await acks open reqs -> exit 0" "$rc" "0"
assert_contains "await acked req-001 (→ .ack.md)" "$awk_out" "req-001-why-lr.ack.md"
assert_contains "await acked req-002 (→ .ack.md)" "$awk_out" "req-002-repro.ack.md"
assert_nofile "open file gone after ack (the rename IS the signal)" "$p1"
assert_eq "status: 2 ack after await" "$("$CHAN" status "$TASK")" "open=0 ack=2 answered=0 total=2 done=0"

# Bug 1: the worker acking via await stamps the machine-input ledger so a
# UserPromptSubmit around the exchange is attributed to the protocol, not
# misread as a fresh operator submit (retire-preflight check 2). The window
# column is the RAW task-id (matches retire-preflight's `$1 == w` lookup).
MI="$NEXUS_STATE_DIR/machine-input.tsv"
assert_contains "await ack stamps machine-input (skeptic-await-ack)" \
    "$(grep -F "$TASK" "$MI" 2>/dev/null)" $'\tskeptic-await-ack'
assert_contains "await ack stamp keyed on the raw task-id window" \
    "$(awk -F'\t' '$1=="'"$TASK"'" && $3=="skeptic-await-ack"' "$MI" 2>/dev/null)" "$TASK"

# Worker answers req 1 by bare number: ack → answered (the rename signal).
ans=$("$CHAN" answer "$TASK" 1 --message "Confirmed config drift; fixed to 5e-5.")
assert_contains "answer renames .ack.md → .answered.md" "$ans" "req-001-why-lr.answered.md"
assert_file "answered file present" "$ans"
assert_contains "answered file carries response" "$(cat "$ans")" "Confirmed config drift"
assert_contains "answered file flips state" "$(cat "$ans")" "state: answered"
assert_eq "status after one answer" "$("$CHAN" status "$TASK")" "open=0 ack=1 answered=1 total=2 done=0"
# Bug 1: answering also stamps the ledger (src skeptic-answer).
assert_contains "answer stamps machine-input (skeptic-answer)" \
    "$(grep -F "$TASK" "$MI" 2>/dev/null)" $'\tskeptic-answer'

# Double-answer is refused (one answer per request).
if "$CHAN" answer "$TASK" 1 --message "again" >/dev/null 2>&1; then
    bad "double-answer refused" "answer of an already-answered req succeeded"
else
    ok "double-answer refused"
fi

# A direct answer of a still-acked req also works (worker answers req-002).
ans2=$("$CHAN" answer "$TASK" 2 --message "Repro confirmed on the toy case.")
assert_contains "answer req-002 → answered" "$ans2" "req-002-repro.answered.md"
assert_eq "status all answered" "$("$CHAN" status "$TASK")" "open=0 ack=0 answered=2 total=2 done=0"

# Skeptic await-answer returns immediately for an already-answered request.
aw=$("$CHAN" await-answer "$TASK" 1 --timeout 2 --interval 1)
assert_contains "await-answer resolves answered req" "$aw" "req-001-why-lr.answered.md"

# --- DONE sentinel: worker await exits with the distinct terminal code 10 ---
"$CHAN" close "$TASK" >/dev/null
assert_file "close drops DONE sentinel" "$NEXUS_STATE_DIR/skeptic/$TASK/DONE"
done_out=$("$CHAN" await "$TASK" --once); rc=$?
assert_eq "await sees DONE -> exit 10 (terminal)" "$rc" "10"
assert_contains "await prints DONE" "$done_out" "DONE"
assert_eq "status reports done=1" "$("$CHAN" status "$TASK")" "open=0 ack=0 answered=2 total=2 done=1"

# --- await re-entry: a fresh open request after a prior ack is picked up ---
DTASK=worker-delta
"$CHAN" ask "$DTASK" later --message "follow-up after the worker re-entered" >/dev/null
"$CHAN" await "$DTASK" --once >/dev/null
assert_eq "re-await acks the new request" "$("$CHAN" status "$DTASK")" "open=0 ack=1 answered=0 total=1 done=0"
# await with NO request and NO DONE times out (exit 4) so the worker re-enters.
ETASK=worker-empty
"$CHAN" init "$ETASK" >/dev/null
"$CHAN" await "$ETASK" --timeout 1 --interval 1 >/dev/null 2>&1
assert_eq "await with nothing pending -> exit 4 (re-enter)" "$?" "4"

# poll on a never-initialised task is silent + rc 0 (no channel yet).
empty=$("$CHAN" poll task-never-seen); rc=$?
assert_eq "poll missing channel -> rc 0" "$rc" "0"
assert_eq "poll missing channel -> empty" "$empty" ""

# ============================================================
echo '=== Bug 2: close clears the skeptic-pending marker (worker idle) ==='
# ============================================================
# When the skeptic closes the channel its verdict exists, so the
# require-gate is satisfied. Marker clearance must NOT depend on the
# worker still being live in its await loop: a stalled/idled worker (no
# await running here — we never call `await`) would otherwise keep the
# marker forever and show `parked-awaiting-skeptic` indefinitely, even
# after its PR merged. close must remove it unconditionally.
CTASK=worker-closemark
CPEND="$NEXUS_STATE_DIR/skeptic/pending/$CTASK"
mkdir -p "$NEXUS_STATE_DIR/skeptic/pending"
echo 1 > "$CPEND"                      # ng wrap-up's require gate set this
assert_file "close: pending marker present before close" "$CPEND"
"$CHAN" close "$CTASK" >/dev/null      # worker is NOT in an await loop
assert_file "close still drops DONE sentinel" "$NEXUS_STATE_DIR/skeptic/$CTASK/DONE"
assert_nofile "close clears the pending marker (worker idle)" "$CPEND"
# Idempotent: closing again with no marker is harmless.
"$CHAN" close "$CTASK" >/dev/null
assert_nofile "second close keeps marker cleared" "$CPEND"

# your-org/nexus-code#961 — CLOSE MUST RELEASE BOTH RECORDS OF THE OBLIGATION.
#
# Operator-reported 2026-08-28 from a retiring pair: a window that ran `close`
# was still refused by `retire-preflight`, and the diagnosis offered was "two
# window-keyed records of one obligation, two verbs, and the one named `close`
# leaves the gating one untouched".
#
# Measured: `close` DOES remove the marker (the arm above proves it). The
# residual gate was the LEDGER, which #961 made authoritative for what a window
# owes BY TASK — so `close` cleared one record and left the other owing, and
# `retire-preflight` refused forever with nothing left to clear it. That is a
# BRICK, and a brick teaches the `rm` bypass. It was introduced by #961's own
# fix and caught by driving the reported symptom rather than by reading the
# code, which had said `rm -f "$(_pending_marker …)"` all along.
CTASK2=worker-closeledger
CPEND2="$NEXUS_STATE_DIR/skeptic/pending/$CTASK2"
CLEDGER2="$NEXUS_STATE_DIR/skeptic/pending/.$CTASK2.ledger"
_CL_SHA=$(printf 'e%.0s' {1..64})
echo 1 > "$CPEND2"
printf 'armed	%s	2026-08-28T01:00:00	961	/r/a.md
' "$_CL_SHA" > "$CLEDGER2"
"$CHAN" close "$CTASK2" >/dev/null
assert_nofile "#961 close clears the marker (unchanged)" "$CPEND2"
assert_contains "#961 THE PROPERTY: …and RELEASES the ledger, so the two records agree" \
    "$(cat "$CLEDGER2")" "resolved"
# The release names ITSELF, so an auditor can tell a reviewer's end-of-pairing
# from an orchestrator's adjudication from a verdict. Three different acts.
assert_contains "#961 …naming which verb released it, not just that something did" \
    "$(cat "$CLEDGER2")" "close"

# ============================================================
echo '=== skeptic reconcile: ack gate + bounded fail-loud ==='
# ============================================================
# All requests acked/answered → reconcile returns 0 promptly.
RTASK=worker-recon
"$CHAN" ask "$RTASK" q1 --message "q1" >/dev/null
"$CHAN" await "$RTASK" --once >/dev/null         # acks q1
"$CHAN" reconcile "$RTASK" --interval 1 --max-iter 2 --no-nudge >/dev/null 2>&1
assert_eq "reconcile all-acked -> rc 0" "$?" "0"
# A still-open (never-acked) request → reconcile fails loud (exit 6).
"$CHAN" ask "$RTASK" q2 --message "q2 never acked" >/dev/null
recon_err=$("$CHAN" reconcile "$RTASK" --interval 1 --max-iter 2 --no-nudge 2>&1); rc=$?
assert_eq "reconcile un-acked -> rc 6 (fail loud)" "$rc" "6"
assert_contains "reconcile names the un-acked request" "$recon_err" "req-002-q2.open.md"

# ============================================================
echo '=== nudge: guards (no-open / rate-limit / busy / paste) ==='
# ============================================================
# Stub paste + pane-state.
PASTE_LOG="$WORK/paste.log"
PANEARG_LOG="$WORK/panearg.log"
cat > "$WORK/paste-stub.sh" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$PASTE_LOG"
exit 0
STUB
chmod +x "$WORK/paste-stub.sh"
# The pane-state stub ENFORCES the F1 contract: cmd_nudge must hand it a
# window INDEX (digits, or session:idx) — never the window NAME, because
# pane-state.sh is index-keyed and a name leaking through silently
# disables the busy/user-typing guard. The stub logs the token it
# received and, when handed a non-index (the pre-fix bug), emits a
# `name-leaked` sentinel state matching NO skip case — so the busy-skip
# assertions below go RED on a revert of the name→index fix (the
# mutation the skeptic required a test to catch).
mk_panestate() { # $1 = state value to emit when the arg IS index-shaped
    cat > "$WORK/panestate-stub.sh" <<STUB
#!/usr/bin/env bash
arg="\$1"
printf '%s\n' "\$arg" >> "$PANEARG_LOG"
if [[ ! "\$arg" =~ ^([0-9]+|[^:]+:[0-9]+)\$ ]]; then
    echo "state=name-leaked active=0"
    exit 0
fi
echo "state=$1 active=0"
exit 0
STUB
    chmod +x "$WORK/panestate-stub.sh"
}
export SKEPTIC_PASTE_BIN="$WORK/paste-stub.sh"
export SKEPTIC_PANESTATE_BIN="$WORK/panestate-stub.sh"
# Test seam: inject the name→index resolution (the hermetic suite has no
# live tmux window matching the synthetic task name).
export SKEPTIC_WINDOW_INDEX=7

# No open requests → nudge is a no-op (rc 0), no paste.
NTASK=worker-nudge
"$CHAN" init "$NTASK" >/dev/null
: > "$PASTE_LOG"
"$CHAN" nudge "$NTASK" >/dev/null 2>&1
assert_eq "nudge with no open reqs -> rc 0" "$?" "0"
assert_eq "nudge with no open reqs -> no paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"

"$CHAN" ask "$NTASK" challenge --message "defend this claim" >/dev/null
# Busy pane → skip (rc 5), no paste. Doubles as the F1 mutation catcher:
# revert the name→index fix and the stub sees the NAME → `name-leaked` →
# no skip → these two go red.
mk_panestate busy
: > "$PASTE_LOG"; : > "$PANEARG_LOG"
"$CHAN" nudge "$NTASK" >/dev/null 2>&1
assert_eq "nudge to busy pane -> rc 5 (skip)" "$?" "5"
assert_eq "nudge to busy pane -> no paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"
# The guard handed pane-state.sh an INDEX, not the window name (F1).
assert_eq "nudge passes an index to pane-state (F1 contract)" \
    "$(tail -1 "$PANEARG_LOG")" "7"
# Bug A: a busy-skipped nudge STAMPS machine-input so the worker's
# protocol pane-churn (under load) is machine-attributed, not mis-seeded
# as a false operator-engaged mark. Delivery is deferred, attribution is
# not.
assert_contains "busy-skip nudge stamps machine-input (skeptic-nudge-busy-skip)" \
    "$(grep -F "$NTASK" "$NEXUS_STATE_DIR/machine-input.tsv" 2>/dev/null)" \
    $'\tskeptic-nudge-busy-skip'

# Bug A guard: a USER-TYPING pane is the OPERATOR — skip WITHOUT a stamp
# (a stamp here would mask the operator's own submit → false NEGATIVE).
UTTASK=worker-usertyping
"$CHAN" init "$UTTASK" >/dev/null
"$CHAN" ask "$UTTASK" q --message "open q" >/dev/null
mk_panestate user-typing
: > "$PASTE_LOG"
"$CHAN" nudge "$UTTASK" >/dev/null 2>&1
assert_eq "user-typing pane -> rc 5 (skip)" "$?" "5"
assert_eq "user-typing pane -> no paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"
assert_not_contains "user-typing pane -> NO machine-input stamp (operator must register)" \
    "$(grep -F "$UTTASK" "$NEXUS_STATE_DIR/machine-input.tsv" 2>/dev/null)" \
    "$UTTASK"

# Idle pane → paste fires (rc 0).
mk_panestate idle
: > "$PASTE_LOG"; : > "$PANEARG_LOG"
out=$("$CHAN" nudge "$NTASK" 2>&1); rc=$?
assert_eq "nudge to idle pane -> rc 0" "$rc" "0"
assert_eq "nudge to idle pane -> one paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "1"
assert_contains "paste carries await instruction" "$(cat "$PASTE_LOG")" "skeptic-channel.sh await"

# Immediately again → rate-limited (rc 5), no second paste.
"$CHAN" nudge "$NTASK" >/dev/null 2>&1
assert_eq "second nudge within interval -> rc 5 (rate-limited)" "$?" "5"
assert_eq "rate-limited nudge -> still one paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "1"

# --force overrides the rate-limit (and bypasses the pane-state guard).
"$CHAN" nudge "$NTASK" --force >/dev/null 2>&1
assert_eq "forced nudge -> rc 0" "$?" "0"
assert_eq "forced nudge -> second paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "2"

# Fail-safe: when the window index can't be resolved (no seam, no live
# tmux window of that name) the guard SKIPS rather than pasting blind.
unset SKEPTIC_WINDOW_INDEX
URTASK="unresolvable-nudge-$$"
"$CHAN" init "$URTASK" >/dev/null
"$CHAN" ask "$URTASK" q --message "open q" >/dev/null
mk_panestate idle
: > "$PASTE_LOG"
"$CHAN" nudge "$URTASK" >/dev/null 2>&1
assert_eq "unresolvable window -> rc 5 (fail-safe skip)" "$?" "5"
assert_eq "unresolvable window -> no paste" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"

# ============================================================
echo '=== reconcile drives the nudge (guards honoured) ==='
# ============================================================
# reconcile nudges a worker that left a request un-acked. It reuses
# cmd_nudge, so the SAME guards apply: a busy/user-typing pane is never
# steamrolled; an idle pane is woken.
export SKEPTIC_WINDOW_INDEX=7
RNTASK=worker-recon-nudge
"$CHAN" init "$RNTASK" >/dev/null
"$CHAN" ask "$RNTASK" still-open --message "never acked" >/dev/null

# Busy pane → reconcile's nudge is skipped (no paste), and reconcile
# still fails loud (exit 6) since the request stays un-acked.
mk_panestate busy
: > "$PASTE_LOG"
"$CHAN" reconcile "$RNTASK" --grace 0 --interval 1 --max-iter 1 >/dev/null 2>&1
assert_eq "reconcile: busy pane NOT steamrolled (no paste)" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"

# Idle pane → reconcile's nudge fires a paste (worker woken). Fresh
# RNTASK2 so the per-window rate-limit stamp from earlier doesn't apply.
mk_panestate idle
RNTASK2=worker-recon-nudge2
"$CHAN" init "$RNTASK2" >/dev/null
"$CHAN" ask "$RNTASK2" still-open --message "never acked" >/dev/null
: > "$PASTE_LOG"
"$CHAN" reconcile "$RNTASK2" --grace 0 --interval 1 --max-iter 1 >/dev/null 2>&1
assert_eq "reconcile: idle pane nudged (one paste)" "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "1"

unset SKEPTIC_WINDOW_INDEX SKEPTIC_PASTE_BIN SKEPTIC_PANESTATE_BIN

# ============================================================
echo '=== wrap-up skeptic step: require / auto / deny / role ==='
# ============================================================
# The operator-context waive (F3) must run with NO NEXUS_WORKER_WINDOW —
# a worker cannot self-waive. Unset any inherited value (this suite may
# run inside a worker session whose window name is exported) so the
# operator-context assertions exercise the operator path, not the
# worker-refusal path.
unset NEXUS_WORKER_WINDOW
# Source ng (guarded main) to exercise the internal helper directly.
# shellcheck disable=SC1090
source "$NG"
PEND="$NEXUS_STATE_DIR/skeptic/pending"

# your-org/nexus-code#1095 — A COMPLIANT WORKER REPORT FOR PRODUCER-PATH CALLS.
#
# `_wrapup_skeptic_step`'s require arm now REFUSES a wrap-up whose report
# states no readable frontmatter `disposition:`, because the spawn-skeptic
# request it would otherwise file derives its whole recommendation from that
# absence. Most producer-path calls in this suite pass no report at all
# (`_SK_REPORT_PATH` unset), which the refusal correctly treats as "states
# nothing" — measured, 22 of this suite's 273 assertions go red without this.
#
# In production `cmd_wrap_up` ALWAYS sets `_SK_REPORT_PATH` from a required
# positional, so "a require wrap-up with no report" is not a reachable
# production state; these calls were modelling the function's signature, not
# a real hand-off. Giving them a compliant report restores the shape they
# were always standing in for.
#
# NOT set as a suite-wide default, deliberately: the role-path cases below
# read the same global, and a stated disposition changes which arm they take
# (`_sk_author_asked`, honoured-vs-derived). Those cases pass unchanged and
# must keep reading exactly what they read before.
_wrep() {   # $1 = a label -> path to a compliant worker report
    local p="$WORK/wrep-$1.md"
    printf -- '---
project: p
date: 2026-08-14
disposition: second-pass
---

## Summary
A compliant worker report: it states its own disposition.
' > "$p"
    printf '%s' "$p"
}

# Helper to write a provenance record for a window.
mk_prov() { # window mode depth role target [orig]
    local d="$NEXUS_STATE_DIR/windows"; mkdir -p "$d"
    jq -n --arg w "$1" --arg m "$2" --argjson dp "$3" \
          --argjson r "$4" --arg t "$5" --arg o "${6:-}" \
        '{window:$w, skeptic_mode:$m, skeptic_depth:$dp, skeptic_role:$r, skeptic_target:$t, skeptic_orig:$o}' \
        > "$d/${1//[^a-zA-Z0-9_-]/_}.json"
}

# --- require: emits SKEPTIC REQUIRED + sets pending marker ---
mk_prov w-req require 0 false ""
_SK_REPORT_PATH=$(_wrep w-req)   # #1095: a require wrap-up needs a report that states a disposition
out=$(_wrapup_skeptic_step 42 w-req your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
unset _SK_REPORT_PATH   # #1095: scope it — this global is read by the role-path cases below
assert_eq "require -> rc 0" "$rc" "0"
assert_contains "require -> emits SKEPTIC REQUIRED" "$out" "SKEPTIC REQUIRED"
assert_contains "require -> CONSEQUENCE line" "$out" "CONSEQUENCE: a skeptic MUST validate"
assert_contains "require -> emits spawn cmd at depth 1" "$out" "--skeptic-depth 1"
assert_not_contains "require -> first skeptic spawn cmd is non-recursive (no --skeptic-orig)" "$out" "--skeptic-orig"
assert_file "require -> pending marker set" "$PEND/w-req"

# --- require + --skeptic-decision deny is REFUSED ---
_wrapup_skeptic_step 42 w-req your-org/your-nexus 0 deny "trivial" "" "" "" "" "" >/dev/null 2>&1
assert_eq "require + decision deny -> rc 1 (refused)" "$?" "1"

# --- require waived by operator clears the marker ---
out=$(_wrapup_skeptic_step 42 w-req your-org/your-nexus 0 "" "" "operator says fine" "" "" "" ""); rc=$?
assert_eq "waive -> rc 0" "$rc" "0"
assert_contains "waive -> WAIVED block" "$out" "WAIVED"
assert_nofile "waive -> pending marker cleared" "$PEND/w-req"

# --- F3: waive is REFUSED from a worker context (operator-only) ---
# A spawned worker runs with NEXUS_WORKER_WINDOW exported; the operator
# session does not. The waive must be refused in worker context and the
# pending marker must survive — a worker cannot self-waive.
mk_prov w-req2 require 0 false ""
_SK_REPORT_PATH=$(_wrep w-req2)  # #1095
_wrapup_skeptic_step 42 w-req2 your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1  # set the marker
unset _SK_REPORT_PATH   # #1095
assert_file "F3 setup -> pending marker set" "$PEND/w-req2"
NEXUS_WORKER_WINDOW=w-req2 _wrapup_skeptic_step 42 w-req2 your-org/your-nexus 0 "" "" "worker self-waive" "" "" "" "" >/dev/null 2>&1
assert_eq "F3 waive from worker context -> rc 1 (refused)" "$?" "1"
assert_file "F3 waive refused -> pending marker survives" "$PEND/w-req2"
# The SAME waive from operator context (no NEXUS_WORKER_WINDOW) succeeds.
out=$(_wrapup_skeptic_step 42 w-req2 your-org/your-nexus 0 "" "" "operator override" "" "" "" ""); rc=$?
assert_eq "F3 waive from operator context -> rc 0" "$rc" "0"
assert_nofile "F3 operator waive -> pending marker cleared" "$PEND/w-req2"

# --- deny at spawn: skips, no marker ---
mk_prov w-deny deny 0 false ""
out=$(_wrapup_skeptic_step 7 w-deny your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "deny -> rc 0" "$rc" "0"
# Banner reworded by your-org/nexus-code#1205: "DENIED" asserted a JUDGEMENT
# about the work; "DISABLED AT SPAWN" states the flag, which is the only fact
# this arm has. The CONSEQUENCE line dropped "skeptic was waived at spawn"
# (same overclaim) and keeps the part that is checkable — no marker, retires
# normally.
assert_contains "deny -> DISABLED AT SPAWN" "$out" "DISABLED AT SPAWN"
assert_contains "deny -> CONSEQUENCE line" "$out" "CONSEQUENCE: no pending marker"
assert_nofile "deny -> no pending marker" "$PEND/w-deny"

# --- auto, no decision: ENFORCED BY DEFAULT (rc 1), prints heuristic +
#     consequence. enforce_auto_decision now defaults true, so an
#     undecided auto wrap-up FAILS. Revert the code default to false and
#     this goes red (config does not define the key, so the code default
#     is authoritative here). ---
mk_prov w-auto auto 0 false ""
out=$(_wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "auto undecided (default enforce on) -> rc 1" "$rc" "1"
assert_contains "auto undecided -> DECISION REQUIRED" "$out" "SKEPTIC DECISION REQUIRED"
assert_contains "auto undecided -> CONSEQUENCE line" "$out" "CONSEQUENCE: you must record a skeptic decision"
assert_contains "auto undecided -> shows heuristic" "$out" "blast radius"

# --- auto, enforce explicitly OFF via env: advisory (rc 0). The env
#     override must win over the (now true) default. ---
_SK_REPORT_PATH=$(_wrep w-auto)  # #1095
out=$(MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=0 _wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
unset _SK_REPORT_PATH   # #1095
assert_eq "auto undecided + enforce off (env) -> rc 0 (advisory)" "$rc" "0"

# --- auto, enforce explicitly on via env: rc 1 ---
out=$(MONITOR_SKEPTIC_ENFORCE_AUTO_DECISION=1 _wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 "" "" "" "" "" "" ""); rc=$?
assert_eq "auto undecided + enforce on (env) -> rc 1" "$rc" "1"

# --- auto + decision require but NO rationale: rc 1 ---
_wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 require "" "" "" "" "" "" >/dev/null 2>&1
assert_eq "auto require w/o rationale -> rc 1" "$?" "1"

# --- auto + decision require WITH rationale: sets marker ---
_SK_REPORT_PATH=$(_wrep w-auto-req)   # #1095: an explicit require needs a stated disposition
out=$(_wrapup_skeptic_step 9 w-auto your-org/your-nexus 0 require "touched shared infra" "" "" "" "" ""); rc=$?
unset _SK_REPORT_PATH   # #1095
assert_eq "auto require w/ rationale -> rc 0" "$rc" "0"
assert_contains "auto require -> SKEPTIC REQUIRED" "$out" "SKEPTIC REQUIRED"
assert_file "auto require -> pending marker" "$PEND/w-auto"

# --- auto + decision deny WITH rationale: skips ---
mk_prov w-auto2 auto 0 false ""
out=$(_wrapup_skeptic_step 9 w-auto2 your-org/your-nexus 0 deny "one-line doc typo" "" "" "" "" ""); rc=$?
assert_eq "auto deny w/ rationale -> rc 0" "$rc" "0"
assert_contains "auto deny -> NOT WARRANTED" "$out" "NOT WARRANTED"
assert_nofile "auto deny -> no marker" "$PEND/w-auto2"

# ============================================================
echo '=== wrap-up role path: verdict + bounded recursion ==='
# ============================================================
# Pre-set a pending marker for the reviewed window; the skeptic's
# verdict should clear it.
mkdir -p "$PEND"; echo 1 > "$PEND/orig-task"

# clean verdict (credible, 0 findings) at depth 1 -> terminates, clears marker.
out=$(_wrapup_skeptic_step 50 sk-w1 your-org/your-nexus 1 "" "" "" credible orig-task 1 0); rc=$?
assert_eq "role credible -> rc 0" "$rc" "0"
assert_contains "role credible -> TERMINATES" "$out" "TERMINATES"
assert_nofile "role verdict clears reviewed marker" "$PEND/orig-task"

# suspect verdict at depth 1 -> second pass recommended at depth 2.
out=$(_wrapup_skeptic_step 50 sk-w2 your-org/your-nexus 1 "" "" "" suspect orig-task 1 0); rc=$?
assert_eq "role suspect depth1 -> rc 0" "$rc" "0"
assert_contains "role suspect -> SECOND-PASS" "$out" "SECOND-PASS SKEPTIC RECOMMENDED"
assert_contains "role suspect -> next depth 2" "$out" "--skeptic-depth 2"

# suspect verdict AT the cap -> escalate, no further spawn. Pin the cap
# explicitly (cap=2 via env) so the at-cap behaviour is asserted
# generically, independent of the default value.
out=$(MONITOR_SKEPTIC_MAX_DEPTH=2 _wrapup_skeptic_step 50 sk-w3 your-org/your-nexus 1 "" "" "" suspect orig-task 2 3); rc=$?
assert_eq "role suspect at cap (cap=2) -> rc 0" "$rc" "0"
assert_contains "role suspect at cap -> ESCALATE" "$out" "MAX SKEPTIC DEPTH REACHED"

# (c) DEFAULT CAP IS NOW 3. A suspect at depth 2 is BELOW the cap, so it
# recommends a second pass at depth 3 (NOT escalate). Revert max_depth to
# 2 and this goes red — depth 2 would hit the cap and escalate. Config
# does not define the key, so the code default is authoritative here.
out=$(_wrapup_skeptic_step 50 sk-w3b your-org/your-nexus 1 "" "" "" suspect orig-task 2 0); rc=$?
assert_contains "default cap 3: suspect depth2 -> SECOND-PASS (not escalate)" "$out" "SECOND-PASS SKEPTIC RECOMMENDED"
assert_contains "default cap 3: suspect depth2 -> next depth 3" "$out" "--skeptic-depth 3"
# And AT the new default cap (depth 3) the chain terminates by escalating
# — the termination guarantee holds generically at the configured max.
out=$(_wrapup_skeptic_step 50 sk-w3c your-org/your-nexus 1 "" "" "" suspect orig-task 3 0); rc=$?
assert_contains "default cap 3: suspect depth3 (at cap) -> ESCALATE" "$out" "MAX SKEPTIC DEPTH REACHED"

# credible but many findings (>= threshold) -> still a second pass.
out=$(_wrapup_skeptic_step 50 sk-w4 your-org/your-nexus 1 "" "" "" credible orig-task 0 3); rc=$?
assert_contains "role credible w/ findings -> SECOND-PASS" "$out" "SECOND-PASS SKEPTIC RECOMMENDED"

# --- F4: a 0-threshold is floored to 1 — a clean 0-findings credible
#     pass TERMINATES (does not recommend a second pass). Without the
#     floor, findings(0) >= thresh(0) would be true and recurse.
out=$(MONITOR_SKEPTIC_FINDINGS_THRESHOLD=0 _wrapup_skeptic_step 50 sk-w6 your-org/your-nexus 1 "" "" "" credible orig-task 1 0); rc=$?
assert_eq "F4 thresh=0 clean pass -> rc 0" "$rc" "0"
assert_contains "F4 thresh=0 clean pass -> TERMINATES (floored)" "$out" "TERMINATES"

# role without verdict -> rc 1.
_wrapup_skeptic_step 50 sk-w5 your-org/your-nexus 1 "" "" "" "" orig-task 1 0 >/dev/null 2>&1
assert_eq "role without verdict -> rc 1" "$?" "1"

# ============================================================
echo '=== Change 2: recursive skeptic sees the WHOLE chain + breaks ties ==='
# ============================================================
# A RECURSIVE (second-or-later) skeptic reviewing the prior skeptic
# `sk-w1` with chain-root `orig-task`. Markers: both reviewed (sk-w1)
# and original (orig-task) live before the verdict; self is sk-w2.
#
# A returned verdict satisfies the require-gate, so the verdict path now
# clears ALL chain markers (reviewed + orig + self) regardless of whether a
# second pass is RECOMMENDED. The block for a genuinely-spawned second pass
# is RE-established by spawn-worker.sh at that spawn — never speculatively
# here (that speculative re-assertion was the marker LEAK: a declined
# recommendation stranded the markers and wedged retire-preflight forever).
mkdir -p "$PEND"; echo 1 > "$PEND/sk-w1"; echo 1 > "$PEND/orig-task"
out=$(_wrapup_skeptic_step 50 sk-w2 your-org/your-nexus 1 "" "" "" suspect sk-w1 2 0 orig-task); rc=$?
assert_eq        "recursive suspect depth2 -> rc 0"                 "$rc" "0"
assert_contains  "recursive -> SECOND-PASS at depth 3"             "$out" "--skeptic-depth 3"
assert_contains  "recursive -> spawn cmd threads --skeptic-orig"   "$out" "--skeptic-orig orig-task"
assert_contains  "recursive -> reviews the WHOLE chain"            "$out" "WHOLE chain"
assert_contains  "recursive -> names the original worker"          "$out" "original worker \`orig-task\`"
assert_contains  "recursive -> ADJUDICATE / break the tie"         "$out" "ADJUDICATE"
assert_contains  "recursive -> prior skeptic enters await on self" "$out" "await sk-w2"
assert_contains  "recursive -> do NOT close the original channel"  "$out" "do NOT close the original worker"
assert_nofile    "recursive -> self (sk-w2) marker cleared on verdict (no leak)" "$PEND/sk-w2"
assert_nofile    "recursive -> ORIGINAL worker marker cleared on verdict (no leak)" "$PEND/orig-task"
assert_nofile    "recursive -> reviewed prior skeptic released"    "$PEND/sk-w1"

# First skeptic recommending a second pass: it reviewed orig-task2
# directly (reviewed == orig == orig-task2), but the NEXT skeptic's target
# is THIS skeptic (sk-first) — distinct from the original — so the emitted
# spawn cmd is recursive and threads --skeptic-orig orig-task2. Both the
# original's and the skeptic's own markers are CLEARED on the verdict (the
# recommendation alone leaves nothing parked; spawn-worker.sh re-stamps the
# block iff the orchestrator actually spawns the next skeptic).
mkdir -p "$PEND"; echo 1 > "$PEND/orig-task2"
out=$(_wrapup_skeptic_step 50 sk-first your-org/your-nexus 1 "" "" "" suspect orig-task2 1 0); rc=$?
assert_eq        "first-skeptic suspect -> rc 0"                   "$rc" "0"
assert_contains  "first-skeptic -> SECOND-PASS at depth 2"         "$out" "--skeptic-depth 2"
assert_contains  "first-skeptic -> threads original as --skeptic-orig" "$out" "--skeptic-orig orig-task2"
assert_nofile    "first-skeptic -> original marker cleared on verdict (no leak)" "$PEND/orig-task2"
assert_nofile    "first-skeptic -> self marker cleared on verdict (no leak)" "$PEND/sk-first"

# Chain TERMINATION (clean verdict) releases BOTH the reviewed window and
# the original worker.
mkdir -p "$PEND"; echo 1 > "$PEND/sk-w1b"; echo 1 > "$PEND/orig-taskb"
out=$(_wrapup_skeptic_step 50 sk-w2b your-org/your-nexus 1 "" "" "" credible sk-w1b 2 0 orig-taskb); rc=$?
assert_contains  "termination -> TERMINATES"                       "$out" "TERMINATES"
assert_nofile    "termination -> reviewed released"                "$PEND/sk-w1b"
assert_nofile    "termination -> ORIGINAL worker released"         "$PEND/orig-taskb"

# Escalation AT the cap also releases the original worker (chain over).
mkdir -p "$PEND"; echo 1 > "$PEND/orig-taskc"
out=$(MONITOR_SKEPTIC_MAX_DEPTH=2 _wrapup_skeptic_step 50 sk-w2c your-org/your-nexus 1 "" "" "" suspect sk-w1c 2 3 orig-taskc); rc=$?
assert_contains  "escalate-at-cap -> MAX DEPTH"                    "$out" "MAX SKEPTIC DEPTH REACHED"
assert_nofile    "escalate-at-cap -> ORIGINAL worker released"     "$PEND/orig-taskc"

# ============================================================
echo '=== LEAK regression: substantive-minor verdict + close → NO manual rm ==='
# ============================================================
# The bug: a `check`/substantive-but-minor verdict (findings>=1) RECOMMENDS
# a second pass. The OLD verdict path then speculatively parked the skeptic's
# OWN marker AND re-asserted the target's. When the orchestrator declined the
# (merely recommended) second pass, nothing cleared them → retire-preflight
# reported safe=0 on a DONE skeptic and its target forever, until a hand `rm`.
#
# Three cases, end-to-end, with NO manual rm anywhere:
#   (a) require gate sets the target marker (preflight WOULD block — safe=0).
#   (b) skeptic returns a `check` verdict (findings>=1, second pass merely
#       RECOMMENDED) → BOTH the target's and the skeptic's OWN markers are
#       gone, and a follow-up `close` is idempotent (no resurrection).
#   (c) a genuinely-pending skeptic (require set, NO verdict yet) keeps the
#       target marker live — the safety still has teeth.

# (a) require gate writes the target marker (the block that retire-preflight
#     check 1b honours; see test-retire-preflight.sh 9b for the safe=0 read).
mk_prov leak-target require 0 false ""
_SK_REPORT_PATH=$(_wrep leak-target)   # #1095
_wrapup_skeptic_step 70 leak-target your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null
unset _SK_REPORT_PATH   # #1095
assert_file   "(a) require gate -> target marker live (would block retire)" "$PEND/leak-target"

# Simulate the orchestrator spawning the skeptic: it (re-)stamps the target
# marker (spawn-worker.sh does this in production — covered by
# test-spawn-worker.sh). The skeptic's OWN window is leak-target-skeptic.
echo 0 > "$PEND/leak-target"            # spawn re-stamp (idempotent here)

# (b) the skeptic returns a `check` verdict with findings=2 (substantive →
#     a second pass is RECOMMENDED) at depth 0. Verdict path must clear BOTH
#     the reviewed target AND the skeptic's own marker — no leak, no rm.
out=$(_wrapup_skeptic_step 70 leak-target-skeptic your-org/your-nexus 1 "" "" "" check leak-target 0 2); rc=$?
assert_eq     "(b) check verdict -> rc 0"                          "$rc" "0"
assert_contains "(b) check w/ findings -> SECOND-PASS recommended" "$out" "SECOND-PASS SKEPTIC RECOMMENDED"
assert_nofile "(b) check verdict clears the TARGET marker (no rm)" "$PEND/leak-target"
assert_nofile "(b) check verdict clears the SKEPTIC's OWN marker (no rm)" "$PEND/leak-target-skeptic"

# (b cont.) the orchestrator declines the second pass and closes the chain;
# close is idempotent and must not resurrect either marker.
"$CHAN" close leak-target >/dev/null
assert_nofile "(b) close after verdict keeps TARGET marker cleared"     "$PEND/leak-target"
assert_nofile "(b) close after verdict keeps SKEPTIC's OWN marker cleared" "$PEND/leak-target-skeptic"

# (c) NEGATIVE CONTROL: a still-pending skeptic (require set, verdict NOT yet
#     returned) MUST keep the marker live — over-clearing would break the
#     gate. No verdict call here, so the marker persists.
mk_prov leak-pending require 0 false ""
_SK_REPORT_PATH=$(_wrep leak-pending)  # #1095
_wrapup_skeptic_step 71 leak-pending your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null
unset _SK_REPORT_PATH   # #1095
assert_file   "(c) still-pending skeptic -> target marker stays live (gate has teeth)" "$PEND/leak-pending"

# ============================================================
echo '=== provenance reader: defaults + parse ==='
# ============================================================
prov=$(_skeptic_provenance ""); assert_eq "empty window -> default prov" "$prov" $'auto\t0\tfalse\t\t'
mk_prov w-pp require 2 false ""
prov=$(_skeptic_provenance w-pp); assert_eq "reads mode+depth" "$prov" $'require\t2\tfalse\t\t'
# orig field threads through provenance (Change 2): a recursive skeptic
# records the chain root so its wrap-up can target the whole chain.
mk_prov w-pp2 require 2 true sk-prior orig-task
prov=$(_skeptic_provenance w-pp2); assert_eq "reads orig (chain root)" "$prov" $'require\t2\ttrue\tsk-prior\torig-task'

# ============================================================
echo '=== await heartbeat: touch -c, never CREATES an absent pending marker ==='
# ============================================================
# Regression for the TOCTOU the heartbeat would otherwise lose: the
# verdict's `rm -f` of the skeptic-pending marker can land while the worker
# is still in `await` (the skeptic's close/DONE comes only AFTER the rm).
# A plain `touch` would recreate the just-cleared marker, and since
# retire-preflight check 1b tests existence (not mtime) that would strand
# the worker un-retireable. `touch -c` makes the heartbeat a no-op on an
# absent marker. Validated through the public `await --once` path, which
# calls _await_heartbeat exactly once per poll.
HBTASK="hb-nocreate-$$"
hb_marker="$NEXUS_STATE_DIR/skeptic/pending/$HBTASK"
rm -f "$hb_marker"
"$CHAN" await "$HBTASK" --once >/dev/null 2>&1
assert_nofile "await heartbeat does NOT create an absent pending marker (touch -c)" "$hb_marker"
# Positive: an EXISTING marker survives the heartbeat — the parked worker
# stays gated (the heartbeat refreshes, never removes).
mkdir -p "$(dirname "$hb_marker")"; printf '1' > "$hb_marker"
"$CHAN" await "$HBTASK" --once >/dev/null 2>&1
assert_file "await heartbeat preserves an existing pending marker" "$hb_marker"
rm -f "$hb_marker"

# ============================================================
echo '=== #469: skeptic gate must not fail OPEN on a re-wrap (stale DONE) ==='
# ============================================================
# A channel is reused across rounds. Round 1's `close` leaves a DONE
# sentinel; a later `ng wrap-up --skeptic-decision require` opens round 2
# by writing a fresh pending marker. If the stale DONE survives, the
# worker's next `await` returns exit 10 instantly and it retires believing
# an independent skeptic validated it — when none ever spawned.
#
# BOTH DIRECTIONS. Every assertion below FAILS on pre-fix source:
#   - guard 2 (await): pre-fix returns 10 on a stale DONE.
#   - guard 1 (wrap-up): pre-fix leaves the stale DONE in place.
# Reproduce the pre-fix failures with:
#   git stash push monitor/skeptic-channel.sh monitor/ng \
#     && bash monitor/watcher/test-skeptic-channel.sh; git stash pop

# Helpers: age a file into the past so the mtime ordering is unambiguous
# regardless of the filesystem's timestamp granularity.
age_file() { touch -d "@$(( $(date +%s) - ${2:-60} ))" "$1"; }

STASK="w469-restale"
sdir="$NEXUS_STATE_DIR/skeptic/$STASK"
smark="$NEXUS_STATE_DIR/skeptic/pending/$STASK"
mkdir -p "$sdir" "$NEXUS_STATE_DIR/skeptic/pending"

# --- guard 2: await refuses a DONE older than the pending marker ---
# Round 1 closed 60s ago; round 2's require-gate marker is fresh.
#
# The marker is written DIRECTLY here, not through `ng wrap-up`. That is
# deliberate: it is the exact shape spawn-worker.sh (~:1457) produces when
# the orchestrator spawns a skeptic itself — a fresh pending marker, no
# wrap-up, no DONE reset. Guard 1 cannot see that path. This section is
# therefore the ONLY coverage of it, and it is why guard 2 is not
# redundant with guard 1.
printf 'round-1 verdict\n' > "$sdir/DONE"; age_file "$sdir/DONE" 60
printf '1' > "$smark"                                   # fresh: mtime = now
out=$("$CHAN" await "$STASK" --once 2>&1); rc=$?
[[ "$rc" != 10 ]] && ok "stale DONE + newer marker -> await does NOT exit 10 (gate stays closed)" \
                  || bad "stale DONE + newer marker -> await does NOT exit 10 (gate stays closed)" \
                         "got rc=10: pre-fix behaviour, the worker would retire unvalidated"
assert_eq "stale DONE -> await returns 4 (re-enter, nothing pending)" "$rc" "4"
assert_contains "stale DONE -> await says so on stderr" "$out" "older than its pending marker"

# The blocking (non---once) path must also refuse it, not exit 10 at once.
out=$("$CHAN" await "$STASK" --timeout 1 --interval 1 2>&1); rc=$?
assert_eq "stale DONE -> blocking await times out (4), never 10" "$rc" "4"

# The marker must survive: the worker is still gated for retire-preflight.
assert_file "stale DONE -> pending marker survives await" "$smark"

# --- guard 2, other direction: a GENUINE round-2 close does release ---
# `close` writes a fresh DONE and removes the marker; await must exit 10.
"$CHAN" close "$STASK" >/dev/null
assert_nofile "round-2 close clears the pending marker" "$smark"
out=$("$CHAN" await "$STASK" --once); rc=$?
assert_eq "round-2 close -> await exits 10 (terminal)" "$rc" "10"
assert_contains "round-2 close -> await prints DONE" "$out" "DONE"

# --- no regression: first-round DONE with NO marker is still terminal ---
# `-nt` is true when the sentinel exists and the marker does not, so the
# ordinary single-round path is untouched.
NTASK="w469-firstround"
mkdir -p "$NEXUS_STATE_DIR/skeptic/$NTASK"
"$CHAN" close "$NTASK" >/dev/null
rm -f "$NEXUS_STATE_DIR/skeptic/pending/$NTASK"
"$CHAN" await "$NTASK" --once >/dev/null; rc=$?
assert_eq "first-round DONE, no marker -> await still exits 10" "$rc" "10"

# --- and a DONE NEWER than a leftover marker is terminal (fail-safe) ---
# If close published DONE but its marker unlink lost, the round is still
# over. Terminal, not a hang.
LTASK="w469-leftover"
mkdir -p "$NEXUS_STATE_DIR/skeptic/$LTASK"
"$CHAN" close "$LTASK" >/dev/null                       # DONE = now, unlinks marker
printf '1' > "$NEXUS_STATE_DIR/skeptic/pending/$LTASK"  # simulate a lost unlink
age_file "$NEXUS_STATE_DIR/skeptic/pending/$LTASK" 60   # ...predating the close
"$CHAN" await "$LTASK" --once >/dev/null; rc=$?
assert_eq "DONE newer than a leftover marker -> terminal (10), not a hang" "$rc" "10"

# --- guard 1: wrap-up --skeptic-decision require CLEARS a prior DONE ---
# `_wrapup_skeptic_step` is sourced from ng above. A require decision opens
# a new round, so the previous round's sentinel must not survive it.
RTASK=w469-rewrap
mk_prov "$RTASK" require 0 false ""
mkdir -p "$NEXUS_STATE_DIR/skeptic/$RTASK"
printf 'round-1 verdict\n' > "$NEXUS_STATE_DIR/skeptic/$RTASK/DONE"
age_file "$NEXUS_STATE_DIR/skeptic/$RTASK/DONE" 60
_SK_REPORT_PATH=$(_wrep rtask)   # #1095
_wrapup_skeptic_step 469 "$RTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
unset _SK_REPORT_PATH   # #1095
assert_nofile "wrap-up require -> clears the prior round's DONE" "$NEXUS_STATE_DIR/skeptic/$RTASK/DONE"
assert_file   "wrap-up require -> writes a fresh pending marker" "$PEND/$RTASK"
# End-to-end: after the re-wrap the worker's await must BLOCK, not retire.
"$CHAN" await "$RTASK" --once >/dev/null 2>&1; rc=$?
assert_eq "re-wrap -> await no longer terminal (gate held)" "$rc" "4"

# --- no regression: a first-round require on a virgin channel still works ---
VTASK=w469-virgin
mk_prov "$VTASK" require 0 false ""
_SK_REPORT_PATH=$(_wrep vtask)   # #1095
_wrapup_skeptic_step 469 "$VTASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
unset _SK_REPORT_PATH   # #1095
assert_file   "first-round require -> pending marker set" "$PEND/$VTASK"
assert_nofile "first-round require -> no DONE conjured" "$NEXUS_STATE_DIR/skeptic/$VTASK/DONE"

# ============================================================
echo
echo '=== #511: reset ARCHIVES stale sentinels (not bare-rm), incl. verdicts ==='
# ============================================================
# The archive-instead-of-rm upgrade of guard 1. A completed round leaves a
# DONE close-marker AND a req-NNN-*.answered.md verdict; `reset` must sweep
# BOTH into skeptic/.archive/<task>.reset-<ts>/ (OUTSIDE the channel, #1434) so the next `require` round is
# clean and the forensic trail survives.
XTASK=w511-reset
XDIR="$NEXUS_STATE_DIR/skeptic/$XTASK"
mkdir -p "$XDIR"
printf 'closed by prior fire\n'  > "$XDIR/DONE"
printf 'verdict: credible\n'     > "$XDIR/req-001-verdict.answered.md"
printf 'a still-open request\n'  > "$XDIR/req-002-open.open.md"   # current round — must survive
out=$("$CHAN" reset "$XTASK"); rc=$?
assert_eq "reset exits 0" "$rc" "0"
assert_nofile "reset moved DONE out of the channel root"            "$XDIR/DONE"
assert_nofile "reset moved the .answered.md verdict out"           "$XDIR/req-001-verdict.answered.md"
assert_file   "reset LEFT the current round's open request"        "$XDIR/req-002-open.open.md"
arch=$(find "$NEXUS_STATE_DIR/skeptic/.archive" -maxdepth 1 -name "$XTASK.reset-*" 2>/dev/null | head -1)
assert_file   "archived DONE lives under skeptic/.archive/<task>.reset-*" "$arch/DONE"
assert_file   "archived verdict lives under skeptic/.archive/<task>.reset-*" "$arch/req-001-verdict.answered.md"
assert_contains "reset reports what it archived" "$out" "archived 2 stale sentinel(s)"

# reset on a channel with nothing stale is an idempotent no-op (rc 0).
"$CHAN" reset "$XTASK" >/dev/null 2>&1; rc=$?
assert_eq "reset is idempotent (no-op rc 0 when nothing stale)" "$rc" "0"
# reset on a never-seen channel is also a clean no-op (no dir conjured).
"$CHAN" reset w511-never-seen >/dev/null 2>&1; rc=$?
assert_eq "reset on an absent channel -> no-op rc 0" "$rc" "0"
assert_nofile "reset does not conjure an absent channel dir" "$NEXUS_STATE_DIR/skeptic/w511-never-seen"

# End-to-end: wrap-up require now ARCHIVES the prior DONE (guard 1 upgraded
# from bare rm) — the DONE is gone from the channel root AND recoverable.
ATASK=w511-wrapup-archive
mk_prov "$ATASK" require 0 false ""
mkdir -p "$NEXUS_STATE_DIR/skeptic/$ATASK"
printf 'round-1 verdict\n' > "$NEXUS_STATE_DIR/skeptic/$ATASK/DONE"
printf 'verdict: credible\n' > "$NEXUS_STATE_DIR/skeptic/$ATASK/req-001-v.answered.md"
age_file "$NEXUS_STATE_DIR/skeptic/$ATASK/DONE" 60
_SK_REPORT_PATH=$(_wrep atask)   # #1095
_wrapup_skeptic_step 511 "$ATASK" your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
unset _SK_REPORT_PATH   # #1095
assert_nofile "wrap-up require -> prior DONE gone from channel root" "$NEXUS_STATE_DIR/skeptic/$ATASK/DONE"
aarch=$(find "$NEXUS_STATE_DIR/skeptic/.archive" -maxdepth 1 -name "$ATASK.reset-*" 2>/dev/null | head -1)
assert_file "wrap-up require -> prior DONE ARCHIVED (recoverable)" "$aarch/DONE"
assert_file "wrap-up require -> fresh pending marker set" "$PEND/$ATASK"

# ============================================================
echo '=== #881: an unstated count is carried to the ORCHESTRATOR as absence ==='
# ============================================================
#
# The terminal text is for the skeptic; the filed spawn-skeptic request is
# what the ORCHESTRATOR adjudicates from. Both must say the same true
# thing, or the fix stops at the surface nobody acts on. The request
# carries a `findings-not-stated` reason token — orthogonal to the
# disposition-derived label, because every combination occurs and folding
# them into one label space would make the corpus unqueryable on either.
W881REP="$WORK/r881.md"
printf -- '---\nproject: p\ndate: 2026-08-14\n---\n\n## Summary\nNo disposition line anywhere in this report.\n' > "$W881REP"
mk_prov w881 auto 1 true w881-target
_SK_REPORT_PATH="$W881REP"
# Redirected to a FILE, not captured with `$(...)`: command substitution
# runs the function in a SUBSHELL, so the `_SK_SPAWN_*` globals it sets
# die with it and every assertion below would read an empty string and
# "pass" or "fail" for the wrong reason. Same subshell hazard the suite
# header warns about, in the READING direction.
# your-org/nexus-code#1095 SUPERSEDES #881's REMEDY HERE, NOT ITS PROPERTY.
# #881 escalated this case to the ORCHESTRATOR; #1095 measured that an
# escalation derived from ABSENCE is unfalsifiable — a finished
# `no-further-pass` and an abandoned review produce the identical
# recommendation — and that it lands on the one person who then has to open the
# report anyway. It is now REFUSED to the author, at wrap-up, in #881's own
# words. #881's property (this must never read as a clean pass, and the two
# one-line remedies must be spelled out) is preserved and strengthened: the
# case cannot reach the record at all.
_sk1095_rc=0
_wrapup_skeptic_step 881 w881 your-org/your-nexus 1 "" "" "" credible w881-target 1 "" \
    > "$WORK/o881" 2>&1 || _sk1095_rc=$?
out=$(cat "$WORK/o881")
assert_eq "#1095 an unstated count + no disposition REFUSES (was: escalated, #881)" \
    "$_sk1095_rc" "1"
assert_contains "#1095 …naming the absence as the cause, in #881's own words" \
    "$out" "STATED NEITHER A COUNT NOR A DISPOSITION"
assert_contains "#1095 …and spelling out both one-line remedies, unchanged from #881" \
    "$out" "--skeptic-findings 0"
# THE PROPERTY, and the reason the refusal had to move ahead of every side
# effect: no spawn-skeptic request may be filed for a wrap-up that refused.
# A refusal that still files one is the escalation it claims not to be.
assert_eq "#1095 THE PROPERTY: NO spawn-skeptic request is signalled by a refusal" \
    "${_SK_SPAWN_REQ:-0}" "0"
assert_not_contains "#1095 …and no absence-derived reason token is composed" \
    "${_SK_SPAWN_REASONS:-}" "second-pass-no-disposition-stated"
# CONTROL — a stated count must NOT carry the token, or it means nothing.
# Guarded the same way: an empty `_SK_SPAWN_REASONS` would satisfy this
# assertion vacuously, so assert the request was FILED before asserting
# what it does not say.
_wrapup_skeptic_step 881 w881 your-org/your-nexus 1 "" "" "" credible w881-target 1 3 \
    > "$WORK/o881b" 2>&1
assert_eq "#881 CONTROL: the stated-count run still files a request" \
    "${_SK_SPAWN_REQ:-0}" "1"
assert_contains "#881 CONTROL: …with a non-empty reason label" \
    "$_SK_SPAWN_REASONS" "second-pass"
assert_not_contains "#881 CONTROL: …and NO absence token" \
    "$_SK_SPAWN_REASONS" "findings-not-stated"
unset _SK_REPORT_PATH

# ============================================================
echo '=== #879: a skeptic-stamped window doing WORKER work ==='
# ============================================================
#
# The role is derived from PROVENANCE, not the command line, and a window
# is stamped for its lifetime rather than for one task. So a retained
# skeptic that later authors a patch was forced to supply a
# `--skeptic-verdict` for work it wrote itself — a self-review, written
# against another window's markers and indistinguishable downstream from
# an independent clearance. The alternative was to skip wrap-up (losing
# report-check, the link comment and the action-log event the
# window-cleanup loop reads), so the window looked un-wrapped.
#
# The property under test: it must be impossible to complete this
# hand-off by asserting something untrue, AND impossible to skip the
# bookkeeping silently.

# The DEFECT, still refused — a stamped window with no verdict cannot
# just proceed. That half was never wrong and must not regress.
mk_prov w879 auto 1 true w879-target
out=$(_wrapup_skeptic_step 879 w879 your-org/your-nexus 0 "" "" "" "" "" "" "" 2>&1); rc=$?
assert_eq "#879 a provenance-stamped skeptic with no verdict is still refused" "$rc" "1"
# …but the refusal must NAME THE ESCAPE HATCH. A refusal whose only open
# path is the false one is what manufactured the fabricated verdicts.
assert_contains "#879 …and the refusal names the honest way out" \
    "$out" "--not-a-skeptic-verdict"
assert_contains "#879 …and says explicitly not to invent a verdict" \
    "$out" "do NOT invent a verdict"

# THE FIX — declaring it is not a verdict takes the ORDINARY producer
# path. Spawn mode here is `require`, so the producer path is reached and
# observable by its own banner.
mk_prov w879b require 1 true w879b-target
_SK_REPORT_PATH=$(_wrep w879b)   # #1095: it falls through to the producer REQUIRE path
out=$(_wrapup_skeptic_step 879 w879b your-org/your-nexus 0 "" "" "" "" "" "" "" "" "" "" \
        "authored the #862 patch in this window; this wrap-up is that work"); rc=$?
unset _SK_REPORT_PATH   # #1095
assert_eq "#879 --not-a-skeptic-verdict completes the hand-off (rc 0)" "$rc" "0"
assert_contains "#879 …and says the role was NOT asserted" \
    "$out" "SKEPTIC ROLE NOT ASSERTED"
assert_contains "#879 …and echoes the recorded reason" \
    "$out" "authored the #862 patch"
# It took the producer path, i.e. the window's OWN work now gets the
# skeptic decision. Without this the flag would just be a way out of the
# gate rather than a route to the correct one.
assert_contains "#879 …and runs the ORDINARY worker wrap-up from there" \
    "$out" "SKEPTIC REQUIRED"
# NO verdict is recorded. This is the whole point: the artefact the
# protocol rests on must not be manufactured.
assert_not_contains "#879 …and records NO verdict" "$out" "SKEPTIC VERDICT"
avlog="$NEXUS_STATE_DIR/action-log.jsonl"
assert_eq "#879 …and writes no skeptic-verdict event for this window" \
    "$(jq -r 'select(.event=="skeptic-verdict" and .window=="w879b")|.window' "$avlog" 2>/dev/null | wc -l | tr -d ' ')" "0"
# It IS on the record, though — the bookkeeping must not be skippable
# silently, which is the other half of the property.
assert_eq "#879 …and DOES log the opt-out, with its reason" \
    "$(jq -r 'select(.event=="skeptic-role-not-asserted" and .window=="w879b")|.reason' "$avlog" 2>/dev/null)" \
    "authored the #862 patch in this window; this wrap-up is that work"

# The opt-out DISCHARGES NOTHING. A window that owes a verdict still owes
# it, and its target stays blocked — otherwise the flag becomes a way to
# retire a target without ever validating it.
mkdir -p "$PEND"; printf '1' > "$PEND/w879c-target"
mk_prov w879c require 1 true w879c-target
_wrapup_skeptic_step 879 w879c your-org/your-nexus 0 "" "" "" "" "" "" "" "" "" "" \
    "did unrelated worker work in this window while retained as a skeptic" >/dev/null 2>&1
assert_file "#879 the opt-out clears NO skeptic marker on the stamped target" \
    "$PEND/w879c-target"

# --- #879 F1: ...INCLUDING THE OPTING-OUT WINDOW'S **OWN** MARKER ----------
#
# The assertion above tested the wrong axis and the wrong mode. It checked
# the STAMPED TARGET's marker under `require` — the one producer branch
# that WRITES a marker rather than clearing one — so it could not fail.
#
# The opt-out falls through to the producer path, and three producer
# branches `rm -f "$pending_dir/${sw_safe}"`: `denied-spawn` (mode deny),
# `denied-auto` (auto + --skeptic-decision deny) and the operator waive.
# `sw_safe` is the OPTING-OUT WINDOW ITSELF. So a window that owed a
# verdict — its own marker seeded when a depth-2 skeptic was spawned
# against it — could DISCHARGE that obligation by declaring "this wrap-up
# is not a verdict", and `retire-preflight.sh` flips safe=0 -> safe=1.
#
# That is strictly worse than the bug #879 fixed: it converts a FORCED
# FALSE VERDICT, which is visible, into a SILENT ABSENT one. And the verb,
# monitor/README.md and skills/nexus.skeptic/SKILL.md all state that no
# skeptic marker is cleared — three documents asserting the opposite of
# the code. The DOCUMENTED behaviour is the correct one: an opt-out is a
# statement about THIS HAND-OFF, not a release of a PENDING OBLIGATION.
_f1_optout() {   # $1 = window, $2 = spawn mode, rest = extra positionals 5..7
    local w="$1" m="$2"; shift 2
    mkdir -p "$PEND"; printf '2' > "$PEND/$w"
    mk_prov "$w" "$m" 1 true "${w}-target"
    _wrapup_skeptic_step 879 "$w" your-org/your-nexus 0 "${1:-}" "${2:-}" "${3:-}" \
        "" "" "" "" "" "" "" \
        "authored the patch in this window while retained as a skeptic" \
        >/dev/null 2>&1
}
# deny at spawn
_f1_optout w879f1a deny
assert_file "#879 F1 opt-out + spawn mode deny keeps the window's OWN marker" \
    "$PEND/w879f1a"
# auto + an explicit deny decision
_f1_optout w879f1b auto deny "one-line doc typo, no skeptic warranted"
assert_file "#879 F1 opt-out + auto/--skeptic-decision deny keeps its OWN marker" \
    "$PEND/w879f1b"
# operator waive (guarded too: the contract says NO marker is cleared)
_f1_optout w879f1c auto "" "" "operator says this worker work is fine"
assert_file "#879 F1 opt-out + --skeptic-waive keeps its OWN marker" \
    "$PEND/w879f1c"
# …and it SAYS it kept it, rather than leaving the operator to infer it.
mkdir -p "$PEND"; printf '2' > "$PEND/w879f1d"
mk_prov w879f1d deny 1 true w879f1d-target
_f1out=$(_wrapup_skeptic_step 879 w879f1d your-org/your-nexus 0 "" "" "" \
    "" "" "" "" "" "" "" \
    "authored the patch in this window while retained as a skeptic" 2>&1)
assert_contains "#879 F1 …and says the marker was KEPT, loudly" \
    "$_f1out" "SKEPTIC MARKER KEPT"

# ── #914 RESIDUAL: it said KEPT and then claimed RELEASE anyway ─────────────
# `_sk_keep_own_marker` has four callers and EVERY one used to follow it with
# an unconditional claim of release — printed AFTER the true "MARKER KEPT"
# block, so the FALSE sentence was the last thing on screen. The marker
# assertions above passed throughout, because they guard the MARKER and
# nothing guarded the CLAIM.
assert_not_contains "#914 …and does NOT also claim this window can retire" \
    "$_f1out" "can retire normally"

# The WAIVE site is the sharpest: its own `_sk_waive_had` guard tests
# PRESENCE-BEFORE, which is exactly the condition under which the keep fires,
# so it took the wrong branch EVERY time the opt-out was in play.
# --skeptic-waive and --not-a-skeptic-verdict are NOT mutually exclusive.
mkdir -p "$PEND"; printf '2' > "$PEND/w914wv"
mk_prov w914wv auto 1 true w914wv-target
_f914wv=$(_wrapup_skeptic_step 914 w914wv your-org/your-nexus 0 "" "" \
    "operator says this worker work is fine" \
    "" "" "" "" "" "" "" \
    "authored the patch in this window while retained as a skeptic" 2>&1)
assert_file        "#914 WAIVE + opt-out still KEEPS the marker" "$PEND/w914wv"
assert_not_contains "#914 WAIVE + opt-out does NOT claim the marker is cleared" \
    "$_f914wv" "is cleared, so THAT window can retire"

# CONTROL — a waive WITHOUT the opt-out must still say it cleared, and must
# really have cleared. Without this, the assertion above is satisfiable by
# deleting the sentence outright.
mkdir -p "$PEND"; printf '2' > "$PEND/w914wc"
mk_prov w914wc auto 0 false ""
_f914wc=$(_wrapup_skeptic_step 914 w914wc your-org/your-nexus 0 "" "" \
    "operator says this worker work is fine" "" "" "" "" 2>&1)
assert_nofile   "#914 CONTROL: waive without the opt-out really clears the marker" \
    "$PEND/w914wc"
assert_contains "#914 CONTROL: …and still says so" \
    "$_f914wc" "is cleared, so THAT window can retire"

# CONTROL — without the opt-out, a deny decision MUST still clear the
# window's own marker. The guard must not turn every deny into a leak;
# that would block retirement across the board.
mkdir -p "$PEND"; printf '2' > "$PEND/w879f1e"
mk_prov w879f1e deny 0 false ""
_wrapup_skeptic_step 879 w879f1e your-org/your-nexus 0 "" "" "" "" "" "" "" >/dev/null 2>&1
assert_nofile "#879 F1 CONTROL: an ordinary spawn-deny still clears the marker" \
    "$PEND/w879f1e"
mkdir -p "$PEND"; printf '2' > "$PEND/w879f1f"
mk_prov w879f1f auto 0 false ""
_wrapup_skeptic_step 879 w879f1f your-org/your-nexus 0 deny "trivial typo fix" "" \
    "" "" "" "" >/dev/null 2>&1
assert_nofile "#879 F1 CONTROL: an ordinary auto-deny still clears the marker" \
    "$PEND/w879f1f"

# A substantive reason is REQUIRED. Without it the flag is a one-word
# dodge, which is the failure mode the reason exists to price in (the
# GH_IMPERSONATE_REASON shape).
mk_prov w879d require 1 true w879d-target
out=$(_wrapup_skeptic_step 879 w879d your-org/your-nexus 0 "" "" "" "" "" "" "" "" "" "" "oops" 2>&1); rc=$?
assert_eq "#879 a token reason is REFUSED" "$rc" "1"
assert_contains "#879 …naming the substantive-reason requirement" \
    "$out" "substantive reason"

# INERT ON A NON-SKEPTIC WINDOW — refused rather than accepted-and-ignored,
# so a mistaken belief about this window's role fails at the caller (#605's
# rule: a verb that ignores a supplied argument must fail loudly).
mk_prov w879e auto 0 false ""
out=$(_wrapup_skeptic_step 879 w879e your-org/your-nexus 0 "" "" "" "" "" "" "" "" "" "" \
        "this window was never stamped as a skeptic at all, so this is inert" 2>&1); rc=$?
assert_eq "#879 the flag is REFUSED on a window that is not stamped" "$rc" "1"
assert_contains "#879 …saying why (not stamped), not a generic usage dump" \
    "$out" "stamped as a skeptic (provenance says skeptic_role: false)"

# The contradiction is refused at the FUNCTION too, not only in the CLI
# arg parser. The unit suites drive this helper directly, so a guard that
# lives only in `cmd_wrap_up` is a guard the tested surface does not have.
mk_prov w879g require 1 true w879g-target
out=$(_wrapup_skeptic_step 879 w879g your-org/your-nexus 1 "" "" "" "" "" "" "" "" "" "" \
        "claiming both a role and not-a-verdict at once, which cannot be true" 2>&1); rc=$?
assert_eq "#879 --not-a-skeptic-verdict + an asserted role is REFUSED in the helper" "$rc" "1"
assert_contains "#879 …naming the contradiction" "$out" "contradicts an asserted skeptic role/verdict"
out=$(_wrapup_skeptic_step 879 w879g your-org/your-nexus 0 "" "" "" credible w879g-target 1 0 "" "" "" \
        "claiming both a verdict and not-a-verdict at once, which cannot be true" 2>&1); rc=$?
assert_eq "#879 …and likewise alongside a supplied verdict" "$rc" "1"

# --- #879 F2: the recommendation line must name the derivation it USED ---
#
# `recommendation:` is the orchestrator-facing field on the filed
# spawn-skeptic request — the sentence adjudication is made from. The #881
# fix taught it not to claim "derived from a findings COUNT" when no count
# was stated, but applied that only to the ROLE path. The arm is reached
# from BOTH, and on the PRODUCER path there is no count in the derivation
# at all: `derived` is `require`, from the window's spawn mode. So a
# first-pass require request told the orchestrator it came from a count.
_f2_rec() {   # $1 = window, $2 = mode  -> echoes the recommendation line
    local w="$1" m="$2"
    mk_prov "$w" "$m" 0 false ""
    local rp="$WORK/${w}-report.md"
    printf -- '---\nproject: p\ndate: 2026-08-14\n---\n\n## Summary\nNo disposition stated anywhere.\n' > "$rp"
    # your-org/nexus-code#1095 — THE TWO CALLS NOW TAKE DIFFERENT REPORTS,
    # and separating them is what keeps this case testing what it names.
    #
    # This case is about the COMPOSER's wording — which derivation
    # `recommendation:` claims — for a report that states nothing. Since
    # #1095 the RESOLVER (`_wrapup_skeptic_step`) refuses such a report on
    # the require path, so driving both halves off `$rp` would leave
    # `_SK_SPAWN_REQ=0` and the composer would print `skipped (no require)`.
    # The assertions below would then read an empty recommendation and this
    # case would silently stop exercising the arm it exists for.
    #
    # So: the RESOLVER gets a compliant report, purely to reach the require
    # resolution and set the `_SK_SPAWN_*` globals; the COMPOSER is still
    # handed `$rp`, the report that states nothing, which is the input under
    # test. `_wrapup_file_spawn_skeptic_request` reads its report from its
    # own `$2`, not from the global, which is what makes the split legal.
    _SK_REPORT_PATH=$(_wrep "$w")
    _wrapup_skeptic_step 879 "$w" your-org/your-nexus 0 "" "" "" "" "" "" "" \
        > /dev/null 2>&1
    unset _SK_REPORT_PATH
    _wrapup_file_spawn_skeptic_request 879 "$rp" "" "" "" your-org/your-nexus >/dev/null 2>&1
    # NO PIPES. `... | head -1` is an early-exit reader, and this suite runs
    # under `pipefail`: the writer takes SIGPIPE and can colour a status the
    # caller consumes (#622/#682, and the early-exit-reader manifest guard
    # caught exactly these two lines). Request filenames are timestamped
    # `YYYYMMDDTHHMMSSZ-...`, so a lexical glob sort IS chronological and the
    # last element is the newest — no `ls -t`, no pipe.
    local -a _rqs=()
    shopt -s nullglob
    _rqs=("$NEXUS_STATE_DIR"/requests/*"${w}"*.md)
    shopt -u nullglob
    (( ${#_rqs[@]} )) || return 0
    local rq="${_rqs[${#_rqs[@]}-1]}" rec
    # awk reads a FILE, so there is no upstream writer to SIGPIPE, and it
    # DRAINS rather than exiting early — both halves of the hazard removed.
    rec=$(awk '/^recommendation: /{sub(/^recommendation: */,""); print}' "$rq")
    printf '%s' "${rec%%$'\n'*}"
}
# ── #1346: a DEFAULTED repo is not an assertion about where an issue lives ──
#
# `cmd_wrap_up` resolves its repo via `_resolve_repo write "$repo_arg"`, which
# falls back to the configured `github.repo` when `--repo` is omitted. Stamping
# that into `issue: <repo>#<n>` publishes a repo-QUALIFIED pointer the caller
# never made. Measured live: `issue: your-org/your-nexus#1134`, where `#1134`
# is a nexus-code issue absent from your-nexus. It 404s in the SKEPTIC's
# window minutes later and reads as a deleted issue.
#
# THE VERDICT IS LOCAL AND DETERMINISTIC — "an issue was named AND the repo was
# defaulted" — never a live `gh` answer. An earlier draft refused on a network
# not-found, which made this suite pass offline and fail online; a guard whose
# answer depends on reachability is worse than either answer.
# The composer short-circuits with `skipped (no require)` unless the RESOLVER
# has set the `_SK_SPAWN_*` globals, so drive it first — the same split
# `_f2_rec` documents, and for the same reason: without it these assertions
# would read an empty string and silently stop exercising the arm.
_c1346_setup() {   # $1 = window
    mk_prov "$1" require 0 false ""
    _SK_REPORT_PATH=$(_wrep "$1")
    _wrapup_skeptic_step 1134 "$1" your-org/your-nexus 0 "" "" "" "" "" "" "" \
        > /dev/null 2>&1
    unset _SK_REPORT_PATH
}
_c1346_n() {   # $1 = window -> number of request files naming it
    bash -c 'shopt -s nullglob; a=("$1"/requests/*"$2"*.md); echo "${#a[@]}"' _ "$NEXUS_STATE_DIR" "$1"
}

_c1346_setup w1346
_c1346_before=$(_c1346_n w1346)
# NON-VACUITY: the resolver really did reach a require, or the refusal below
# would be indistinguishable from the `skipped (no require)` short-circuit.
assert_eq "#1346 FIXTURE: the resolver reached a require" "${_SK_SPAWN_REQ:-0}" "1"
_c1346_out=$(_wrapup_file_spawn_skeptic_request 1134 "$(_wrep w1346)" "" "" "" \
    your-org/your-nexus "" 0 2>&1)
_c1346_after=$(_c1346_n w1346)
assert_contains "#1346 a DEFAULTED repo REFUSES the filing" \
    "$_c1346_out" "REFUSING to file the spawn-skeptic request"
assert_contains "#1346 …naming the remedy rather than only the complaint" \
    "$_c1346_out" "--repo <owner>/<name>"
assert_contains "#1346 …and saying nothing is lost, so the refusal is actionable" \
    "$_c1346_out" "pending marker still holds the retire gate shut"
assert_eq "#1346 …and NO request file is written" "$_c1346_after" "$_c1346_before"

# NEG CONTROL — an EXPLICIT repo must still file. Without this, everything above
# is satisfied by a function that refuses unconditionally, which is the other
# way to be wrong.
_c1346_setup w1346x
_c1346x_before=$(_c1346_n w1346x)
_wrapup_file_spawn_skeptic_request 1134 "$(_wrep w1346x)" "" "" "" \
    your-org/your-nexus "" 1 >/dev/null 2>&1
_c1346x_after=$(_c1346_n w1346x)
assert_eq "#1346 NEG CONTROL: an EXPLICIT repo still files normally" \
    "$(( _c1346x_after > _c1346x_before ? 1 : 0 ))" "1"

_f2out=$(_f2_rec w879f2 require)
assert_contains "#879 F2 a producer-path require names the SPAWN MODE as its source" \
    "$_f2out" "spawn mode"
assert_not_contains "#879 F2 …and does NOT claim a findings count it never consulted" \
    "$_f2out" "derived from a findings COUNT"

# CONTROL — a REAL verdict still works unchanged. The fix must not make
# the honest path harder; wrap-up is on every agent's exit path.
mk_prov w879f auto 1 true w879f-target
out=$(_wrapup_skeptic_step 879 w879f your-org/your-nexus 0 "" "" "" credible w879f-target 1 0); rc=$?
assert_eq "#879 CONTROL: a genuine verdict still completes" "$rc" "0"
assert_contains "#879 CONTROL: …and still records the verdict" "$out" "SKEPTIC VERDICT"

# ---- assertion-count floor ---------------------------------------------
#
# A missing assert_* helper exits rc 127 and is counted by NOTHING: the
# file runs, prints nothing alarming, and reports success for checks that
# never ran. Asserting the COUNT is what makes green mean "they ran".
MIN_ASSERTIONS=198
if (( PASS + FAIL < MIN_ASSERTIONS )); then
    echo "FAIL: only $((PASS + FAIL)) assertions executed; expected >= $MIN_ASSERTIONS." >&2
    echo "      A green run with too few assertions means checks were SKIPPED," >&2
    echo "      not that they passed (a missing assert_* helper exits 127 silently)." >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================
echo '=== #845: the obligation wiring inside wrap-up ==='
# ============================================================
# The ledger itself is covered by monitor/test-obligations.sh. What is
# covered HERE is the WIRING — that `ng wrap-up` actually opens and settles
# edges — because a ledger nobody writes to is a gate that never fires, and
# that failure is invisible from either side.
OBLIG="$_repo_root/monitor/obligations.sh"

# --- A. a filed verdict RECORDS a round and does NOT end the pairing ------
# This asserted the opposite until sk926 replayed the recorded timeline: a
# verdict discharges one ROUND, and treating it as ending the PAIRING closed
# the edge at 09:19:36 for a reviewer retired at 09:21:21 whose target was
# still being worked at 10:55. See monitor/test-obligations.sh §8.
"$OBLIG" open --debtor sk-obl --creditor tgt-obl --round 1 \
    --by "test fixture" --detail "round 1" >/dev/null
mk_prov sk-obl "" 1 true tgt-obl
_wrapup_skeptic_step 50 sk-obl your-org/your-nexus 1 "" "" "" credible tgt-obl 1 0 >/dev/null 2>&1
OBL_ST=$(OBL_TMUX_WINDOWS=$'sk-obl\ntgt-obl' "$OBLIG" state sk-obl__tgt-obl__skeptic-verdict)
assert_contains "#845 a filed verdict does NOT end the pairing" \
    "$OBL_ST" "state=live"
assert_not_contains "#845 …specifically it does not settle it" \
    "$OBL_ST" "state=settled"
OBL_SHOW=$("$OBLIG" show sk-obl__tgt-obl__skeptic-verdict 2>&1)
assert_contains "#845 …but the delivered round IS recorded on the edge" \
    "$OBL_SHOW" "verdict 'credible' filed for tgt-obl"
assert_contains "#845 …and says explicitly that the pairing continues" \
    "$OBL_SHOW" "pairing NOT ended"
# …and the protocol's own end-of-pairing signal DOES end it.
env NEXUS_STATE_DIR="$NEXUS_STATE_DIR" "$CHAN" close tgt-obl >/dev/null 2>&1
OBL_ST=$(OBL_TMUX_WINDOWS=$'sk-obl\ntgt-obl' "$OBLIG" state sk-obl__tgt-obl__skeptic-verdict)
# BACKTICKS ESCAPED (your-org/nexus-code#1157). Unescaped inside a double-quoted
# label these COMMAND-SUBSTITUTE: measured on this host the label actually RAN
# `ng skeptic close`, printed `skeptic-channel: usage: close <task-id>` to
# stderr, and the label silently became "#845 CONTROL  ends it" — note the
# double space where the word was. On a contended runner the same site fails the
# other way, `ng: command not found` at rc 127, which is the noise that sent a
# reviewer into #1178's exit-code logic tonight. A label must be TEXT.
assert_contains "#845 CONTROL \`ng skeptic close\` ends it" "$OBL_ST" "state=void-pairing-closed"

# --- B. the re-arm notifier, one case per arm ----------------------------
# `_wrapup_notify_pinned_skeptic` is driven directly with `_live_skeptic_window`
# stubbed, because the real lookup needs a live tmux board and the arm taken
# is what matters. Each arm is asserted separately: the DANGEROUS one is
# `unknown` silently behaving like `no`, which is #771's defect and would
# leave a pinned reviewer unrouted with nothing said.
_lsw_saved=$(declare -f _live_skeptic_window)

# B1 — no live skeptic: silent, and no edge invented.
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=no; _LIVE_SKEPTIC_NAME=""; printf 'no (…)'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b1 2 50 2>&1)
assert_eq "#845 B1 no live skeptic -> says nothing" "$out" ""
[[ -e "$NEXUS_STATE_DIR/obligations/sk-b1__tgt-b1__skeptic-verdict.rec" ]] \
    && bad "#845 B1 no edge invented" "record exists" || ok "#845 B1 no edge invented"

# B2 — could NOT look: must SAY so. A blind lookup that reads as "none" is
# exactly how a pinned reviewer goes unrouted for hours.
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=unknown; _LIVE_SKEPTIC_NAME=""; printf 'unknown (…)'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b2 2 50 2>&1)
assert_contains "#845 B2 a BLIND lookup is reported, not swallowed" "$out" "could not establish"
assert_contains "#845 B2 …and names the manual route"               "$out" "notify-delta"

# B3 — a live pinned skeptic: the edge is opened AND the reviewer is woken.
# The paste/pane-state seams were unset after the nudge block; `notify-delta`
# runs as a SUBPROCESS of the notifier, so they must be exported again or the
# real paste-followup.sh is what runs (and refuses, since these window names
# have no tmux window).
export SKEPTIC_PASTE_BIN="$WORK/paste-stub.sh"
export SKEPTIC_PANESTATE_BIN="$WORK/panestate-stub.sh"
export SKEPTIC_WINDOW_INDEX=7
mk_panestate idle
: > "$PASTE_LOG"
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=yes; _LIVE_SKEPTIC_NAME="sk-b3"; printf 'yes: `sk-b3`'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b3 2 50 2>&1)
assert_contains "#845 B3 the reviewer is named"        "$out" "reviewer  : sk-b3"
assert_contains "#845 B3 the obligation is recorded"   "$out" "sk-b3 owes tgt-b3"
# `"delivered"` alone is NOT a sound needle — "NOT delivered (rc 5)" contains
# it, so the loose form passed while zero pastes had landed. Anchor on the
# whole field.
assert_contains "#845 B3 delivery is reported"         "$out" "delivery  : delivered"
assert_not_contains "#845 B3 …and specifically NOT as a failure" "$out" "NOT delivered"
assert_file "#845 B3 the edge exists on disk" \
    "$NEXUS_STATE_DIR/obligations/sk-b3__tgt-b3__skeptic-verdict.rec"
assert_eq "#845 B3 exactly one paste reached the reviewer" \
    "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "1"
assert_contains "#845 B3 the paste names the target that re-armed" \
    "$(cat "$PASTE_LOG")" "tgt-b3"

# B4 — delivery FAILS (busy pane): the edge is recorded anyway. Ordering the
# other way would leave the gate open on exactly the runs where the wake
# did not land, which is the case that most needs it.
mk_panestate busy
: > "$PASTE_LOG"
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=yes; _LIVE_SKEPTIC_NAME="sk-b4"; printf 'yes: `sk-b4`'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b4 2 50 2>&1)
assert_contains "#845 B4 a failed delivery is reported as such" "$out" "delivery  : NOT delivered"
assert_file "#845 B4 …and the edge is recorded regardless" \
    "$NEXUS_STATE_DIR/obligations/sk-b4__tgt-b4__skeptic-verdict.rec"
assert_eq "#845 B4 …with no paste having landed" \
    "$(wc -l <"$PASTE_LOG" | tr -d ' ')" "0"

# --- B5/B6/B7 — THE NOTICE MUST SAY WHY IT FIRED (your-org/nexus-code#984) -
#
# Reported live, 2026-08-26: a pinned reviewer received the identical
# `SKEPTIC DELTA` notice TWICE, the first time with the branch and `dev`
# BYTE-IDENTICAL — nothing whatsoever to review — and burned a full review
# cycle establishing that. The notice could not distinguish "the target filed
# a NEW round" from "the target's marker was RE-ARMED", so the only way to
# tell was to diff the refs, and EVERY recipient had to re-derive the same
# fact.
#
# The arm's subject record answers it: compare the sha just armed against the
# sha of the last recorded discharge. Three arms, and the third is the one
# that matters most — a notice that GUESSES costs a review pass, a notice
# that says "I could not tell" costs one diff.
SHA_OLD=$(printf 'a%.0s' {1..64}); SHA_NEW=$(printf 'b%.0s' {1..64})
mkdir -p "$PEND"
mk_panestate idle

# B5 — the artefact CHANGED: there really is a delta.
: > "$PASTE_LOG"
# ONE ledger, in EVENT ORDER — the discharge of the OLD artefact precedes the
# arm of the new one, which is exactly what "the report changed since your last
# verdict" means. Written in that order rather than compared by timestamp.
{ printf 'discharged\t%s\t2026-08-26T00:00:00\tcredible\t984\tsk-b5\tattributed\n' "$SHA_OLD"
  printf 'armed\t%s\t2026-08-26T01:00:00\t984\t/r/new.md\n' "$SHA_NEW"
} > "$PEND/.tgt-b5.ledger"
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=yes; _LIVE_SKEPTIC_NAME="sk-b5"; printf 'yes: `sk-b5`'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b5 2 984 2>&1)
assert_contains "#984 B5 the notice states WHY it fired" "$out" "WHY THIS FIRED"
assert_contains "#984 B5 …that the artefact CHANGED"     "$out" "report CHANGED"
assert_contains "#984 B5 …naming both shas so it is checkable" \
    "$out" "${SHA_OLD:0:12}… -> ${SHA_NEW:0:12}…"
assert_contains "#984 B5 …and the reason reaches the REVIEWER, not only stdout" \
    "$(cat "$PASTE_LOG")" "report CHANGED"

# B6 — BYTE-IDENTICAL: the live instance. The reviewer must be told there is
# nothing in the report to re-derive.
: > "$PASTE_LOG"
{ printf 'discharged\t%s\t2026-08-26T00:00:00\tno-further-pass\t984\tsk-b6\tattributed\n' "$SHA_OLD"
  printf 'armed\t%s\t2026-08-26T01:00:00\t984\t/r/same.md\n' "$SHA_OLD"
} > "$PEND/.tgt-b6.ledger"
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=yes; _LIVE_SKEPTIC_NAME="sk-b6"; printf 'yes: `sk-b6`'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b6 2 984 2>&1)
assert_contains "#984 B6 an identical artefact is named as such" "$out" "BYTE-IDENTICAL"
assert_contains "#984 B6 …and identified as a deliberate re-arm, not new work" \
    "$out" "DELIBERATE RE-ARM"
assert_contains "#984 B6 …telling the reviewer not to re-derive a delta that is not there" \
    "$out" "there is none in the report"
assert_not_contains "#984 B6 …and does NOT claim the report changed" "$out" "report CHANGED"
assert_contains "#984 B6 …carried to the reviewer in the paste" \
    "$(cat "$PASTE_LOG")" "BYTE-IDENTICAL"

# B7 — NO RECORD EITHER SIDE. The arm predates the record, or the report
# could not be hashed. The notice must say it CANNOT ESTABLISH this, never
# pick the comfortable half — that is the confident-negative class this whole
# batch is about, and it would arrive here through the fix for it.
: > "$PASTE_LOG"
rm -f "$PEND/.tgt-b7.ledger"
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=yes; _LIVE_SKEPTIC_NAME="sk-b7"; printf 'yes: `sk-b7`'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b7 2 984 2>&1)
assert_contains "#984 B7 no record -> the notice says so plainly" \
    "$out" "CANNOT BE ESTABLISHED FROM STATE"
assert_contains "#984 B7 …and tells the reviewer to diff the refs itself" \
    "$out" "Diff the refs yourself"
assert_not_contains "#984 B7 …never guessing 'changed'"   "$out" "report CHANGED"
assert_not_contains "#984 B7 …and never guessing 'identical'" "$out" "BYTE-IDENTICAL"

# --- B8 — AN AMBIGUOUS DISCHARGE MUST NOT BE SKIPPED (#1069) -------------
#
# `_skeptic_last_discharged_sha` selected the last discharge CARRYING A 64-HEX
# SHA. That predicate SKIPS an ambiguous (`-`) discharge and silently returns
# the previous ATTRIBUTED one — so with `arm A -> discharge A -> arm B -> arm C
# -> discharge ambiguous`, the notice told the reviewer "the report CHANGED
# since your last recorded verdict (A -> C)". A is not the last verdict, and the
# last discharge attributed nothing at all.
#
# It authorises nothing: the suppression path matches an exact sha, and a `-`
# can never match a 64-hex lookup. But this is the notice whose ENTIRE PURPOSE
# is to stop a reviewer re-deriving something, and a confidently-wrong reason is
# a worse failure there than no reason, because the reviewer has no cue to
# check. The B5/B6/B7 arms above cover changed / byte-identical / no-record;
# none plants an ambiguous discharge, which only became reachable when #1067
# added it. A residue introduced by a fix and covered by none of that fix's
# tests is exactly what this arm exists to stop being rediscovered.
SHA_C=$(printf 'c%.0s' {1..64})
: > "$PASTE_LOG"
{ printf 'armed\t%s\t2026-08-26T00:00:00\t984\t/r/a.md\n' "$SHA_OLD"
  printf 'discharged\t%s\t2026-08-26T00:30:00\tcredible\t984\tsk-b8\tattributed\n' "$SHA_OLD"
  printf 'armed\t%s\t2026-08-26T01:00:00\t984\t/r/b.md\n' "$SHA_NEW"
  printf 'armed\t%s\t2026-08-26T02:00:00\t984\t/r/c.md\n' "$SHA_C"
  printf 'discharged\t-\t2026-08-26T03:00:00\tcredible\t984\tsk-b8\tambiguous-2-arms-outstanding\n'
} > "$PEND/.tgt-b8.ledger"
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=yes; _LIVE_SKEPTIC_NAME="sk-b8"; printf 'yes: `sk-b8`'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b8 2 984 2>&1)
assert_contains "#1069 B8 an ambiguous last discharge is stated as IGNORANCE" \
    "$out" "CANNOT BE ESTABLISHED FROM STATE"
assert_contains "#1069 B8 …naming WHY it cannot be established" \
    "$out" "attributed no artefact"
assert_contains "#1069 B8 …and telling the reviewer to diff the refs itself" \
    "$out" "Diff the refs yourself"
# THE PROPERTY. The old predicate reached PAST the ambiguous line to A and
# announced a change from it. A is not the reviewer's last verdict.
assert_not_contains "#1069 B8 THE PROPERTY: it does NOT claim the report changed" \
    "$out" "report CHANGED"
assert_not_contains "#1069 B8 …and does not cite the skipped-over attributed sha" \
    "$out" "${SHA_OLD:0:12}"

# --- B9 — THE NOTICE'S CLASSIFICATION REACHES THE LOG (#1062) -------------
#
# Two skeptics, two different workers, six hours apart, were each notified
# TWICE with a byte-identical record: same `round` (it does not increment on a
# re-arm) and the same paste note both times — while the underlying states were
# "nothing to review" and "a genuine delta". The prose already distinguished
# them for a human; nothing distinguished them for the LOG or for the note, so
# the fraction of spurious notices stayed invisible. A signal that fires when
# nothing happened teaches its reader to discount it, and the discounted firing
# is eventually the real one.
: > "$PASTE_LOG"
{ printf 'discharged\t%s\t2026-08-26T00:00:00\tno-further-pass\t984\tsk-b9\tattributed\n' "$SHA_OLD"
  printf 'armed\t%s\t2026-08-26T01:00:00\t984\t/r/same.md\n' "$SHA_OLD"
} > "$PEND/.tgt-b9.ledger"
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=yes; _LIVE_SKEPTIC_NAME="sk-b9"; printf 'yes: `sk-b9`'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b9 1 984 2>&1)
# Only the `--note` is compared, never the whole argv: the stub logs `$@`, so
# the reviewer's own name is in there and would make any two firings differ for
# a reason that has nothing to do with the classification.
_b9_note_of() { sed 's/.*--note //' <<<"$(cat "$PASTE_LOG")"; }
_b9_note=$(_b9_note_of)
assert_contains "#1062 B9 a re-arm over unchanged bytes is CLASSIFIED in the note" \
    "$_b9_note" "why=unchanged-rearm"
assert_contains "#1062 B9 …and the note carries the subject sha, so it is checkable" \
    "$_b9_note" "${SHA_OLD:0:12}"
# THE PROPERTY, and the one the log could not answer: the SAME target at the
# SAME round with CHANGED bytes must produce a DIFFERENT note. Under the old
# note (`<target> re-armed round N`) these two are byte-identical.
: > "$PASTE_LOG"
{ printf 'discharged\t%s\t2026-08-26T00:00:00\tcredible\t984\tsk-b9\tattributed\n' "$SHA_OLD"
  printf 'armed\t%s\t2026-08-26T01:00:00\t984\t/r/new.md\n' "$SHA_NEW"
} > "$PEND/.tgt-b9.ledger"
# A DIFFERENT pinned reviewer, deliberately: `_wake_gate` throttles a re-fire
# to the SAME skeptic inside 120s, and the two firings #1062 measured were 6
# and 17 minutes apart. The note carries no reviewer name, so the comparison
# below is still same-target, same-round.
_live_skeptic_window() { _LIVE_SKEPTIC_VERDICT=yes; _LIVE_SKEPTIC_NAME="sk-b9b"; printf 'yes: `sk-b9b`'; }
out=$(_wrapup_notify_pinned_skeptic tgt-b9 1 984 2>&1)
_b9_note2=$(_b9_note_of)
assert_contains "#1062 B9 …a genuine delta classifies differently" \
    "$_b9_note2" "why=changed"
_b9_cmp=different
[[ "$_b9_note" == "$_b9_note2" ]] && _b9_cmp="IDENTICAL: $_b9_note"
assert_eq "#1062 B9 THE PROPERTY: same target, same round — the two notes DIFFER" \
    "$_b9_cmp" "different"

eval "$_lsw_saved"
unset SKEPTIC_WINDOW_INDEX SKEPTIC_PASTE_BIN SKEPTIC_PANESTATE_BIN

# ==========================================================================
# your-org/nexus-code#961 — THE TASK KEY IS VALIDATED AT THE MINT
# ==========================================================================
#
# Measured on the operator's live state dir, 2026-08-28: of 578 task
# directories, four are not window names — `--help` (a DIRECTORY created
# 2026-08-07, carrying a live `.await-heartbeat`), the bare integer `272`, and
# two stray `.await.log` / `.await.out` FILES at task-dir level. Someone ran a
# skeptic verb with `--help` and the parser passed the FLAG through as a
# task-id, which minted a state directory AND started a heartbeat in it.
#
# WHY THIS IS #961 AND NOT TIDINESS. A key minted from whatever argv happened
# to contain forks a task's state into a directory nothing will ever read, and
# its ABSENCE from the real key is indistinguishable from "no obligation
# exists". No amount of correct re-keying repairs that while the key is
# unvalidated — so the fix must be at the MINT, not at the read.
echo '=== #961: a task-id that is not window-shaped is REFUSED, not stored ==='
KEYSD="$WORK/keysd"
mkdir -p "$KEYSD"
_key_try() {   # _key_try <task-id>
    env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$KEYSD" \
        bash "$_test_dir/../skeptic-channel.sh" init "$1" >/dev/null 2>&1
    printf '%s' "$?"
}
# NOT `_key_try -- '--help'`: that passes `--` as the task-id, so the arm tests
# a different string entirely and the on-disk assertion below then passes
# VACUOUSLY (measured — it passed against dev, which does mint `skeptic/--help`).
# Caught by running these guards against dev and noticing which ones did NOT go
# red. A guard never seen fail is not evidence.
assert_eq "#961 a FLAG in the task-id slot is refused (the live \`--help\` dir)" \
    "$(_key_try '--help')" "1"
assert_eq "#961 …any flag, not just --help"          "$(_key_try '--target')" "1"
assert_eq "#961 a leading dot collides with the reserved sidecars — refused" \
    "$(_key_try '.hidden')" "1"
assert_eq "#961 a path fragment is refused"          "$(_key_try 'a/b')" "1"
# `pending` is the sharpest and is NOT in the issue: PENDING_DIR IS
# $SKEPTIC_ROOT/pending, so this task's channel dir lands ON the marker store
# and its DONE sentinel is then read as the live obligation of a window
# called `DONE`.
assert_eq "#961 \`pending\` IS the marker store — refused" "$(_key_try 'pending')" "1"
# THE PROPERTY: refused means NOT STORED. A verb that complains and creates the
# directory anyway has changed nothing about the corpus.
assert_nofile "#961 THE PROPERTY: the refused flag minted NO directory" \
    "$KEYSD/skeptic/--help"
# `init` creates the DIRECTORY and nothing else, so that is what must be
# absent. Asserting on a `DONE` sentinel inside it would pass vacuously on the
# pre-fix code, which mints the directory but no sentinel.
assert_nofile "#961 …and \`pending\` was not minted over the marker store" \
    "$KEYSD/skeptic/pending"
# POSITIVE CONTROL — this must refuse malformed keys, not legitimate ones.
# Window names in this workspace contain spaces and dots; `wk_encode` handles
# them and they must keep working.
assert_eq "#961 CONTROL: an ordinary window name still works" "$(_key_try 'panelive-sk')" "0"
assert_eq "#961 CONTROL: …including spaces and dots"          "$(_key_try 'has spaces.and.dots')" "0"
# COVERAGE BOUNDARY, stated as an assertion rather than a comment: an
# ALL-NUMERIC key is deliberately ADMITTED. `272` is an issue number in the
# wrong slot, but a tmux window may legitimately be named `272` and bytes
# cannot separate the two. This grammar stops keys that are not window-SHAPED;
# it does not stop the wrong window.
assert_eq "#961 BOUNDARY: an all-numeric key is deliberately still admitted" \
    "$(_key_try '272')" "0"

# ============================================================
echo '=== #984 operator report: `resolve` must LOOK before saying "nothing to resolve" ==='
# ============================================================
#
# Reported live, 2026-08-26: an orchestrator holding an obligation armed by a
# report's `disposition: second-pass` frontmatter ran `ng skeptic resolve
# <task>` and was told, as the FIRST and loudest line,
#
#     no skeptic-pending marker for task <task> (…) — nothing to resolve.
#
# The correct invocation (`--disposition`) was named two lines below, but the
# headline had already answered the question. "Nothing to resolve" is a
# NEGATIVE CLAIM ABOUT AN OBLIGATION made having checked one of the two things
# that can arm one — this workspace's dominant defect class, inside the verb
# whose entire purpose is to replace an unaudited `rm`.
#
# Hermetic corpus via NEXUS_ROOT: `_report_reports_dir` resolves the corpus
# from it, so the disposition probe scans the fixture rather than the ~1,700
# reports in the operator's real tree. The scripts under test are the REAL
# ones — only the corpus and the state dir are fixtures.
RES_ROOT="$WORK/resolve-root"
mkdir -p "$RES_ROOT/reports" "$RES_ROOT/state/skeptic/pending"
cat > "$RES_ROOT/reports/nexus_2026-08-26_100000_armed.md" <<'RPT'
---
project: nexus
window: dispwin
disposition: second-pass
---
# armed by the report, not by a marker
RPT
res() {  # res <task> [extra flags…]
    local t="$1"; shift
    env -u NEXUS_WORKER_WINDOW NEXUS_ROOT="$RES_ROOT" \
        NEXUS_STATE_DIR="$RES_ROOT/state" \
        "$CHAN" resolve "$t" \
        --reason "declining the second pass; the finding was already addressed upstream" \
        "$@" 2>&1
}

out=$(res dispwin); rc=$?
assert_eq "#984 resolve on a report-armed gate still exits non-zero" "$rc" "1"
assert_not_contains "#984 …and no longer HEADLINES a false negative" \
    "$out" "nothing to resolve"
assert_contains "#984 …it says the marker gate is only ONE of the two" \
    "$out" "ONE of the two gates"
assert_contains "#984 …and reports what the OTHER gate actually reads" \
    "$out" "state=second-pass"
assert_contains "#984 …and names the flag that would work" "$out" "--disposition"
assert_contains "#984 …and says this run changed nothing" "$out" "recorded NOTHING"

# NEGATIVE CONTROL. When neither gate is armed, "nothing to resolve" IS the
# accurate answer and must survive — otherwise the fix would have replaced a
# false negative with a false positive, and `--disposition` would become a
# reflex incantation on windows that need no release.
out=$(res nogatewin); rc=$?
assert_eq "#984 CONTROL: neither gate armed still exits non-zero" "$rc" "1"
assert_contains "#984 CONTROL: …and the accurate headline SURVIVES" \
    "$out" "nothing to resolve"
assert_contains "#984 CONTROL: …now stating that the report gate was checked too" \
    "$out" "state=no-report"

# The release itself must still work on the armed case — a gate with no
# release is a brick, and the whole point of naming `--disposition` is that
# following the advice succeeds.
out=$(res dispwin --disposition); rc=$?
assert_eq "#984 --disposition on the armed case succeeds" "$rc" "0"
assert_contains "#984 …recording a disposition-only resolution" \
    "$out" "disposition-only resolution"
assert_file "#984 …with a rationale record on disk" \
    "$RES_ROOT/state/skeptic/pending/.dispwin.cleared-rationale"

# DOUBT MUST NOT MANUFACTURE THE REASSURING ANSWER — the arm that decides
# whether this fix is a fix or a new way to be told what you want to hear.
#
# The probe is made genuinely UNABLE TO RUN, by running a copy of the script
# from a directory that has no `ng` beside it. That is the real "could not
# look" state, not a simulation of it, and it must land on the SAME arm as
# `second-pass` — "a gate MAY be armed, pass --disposition" — never on
# "nothing to resolve". A probe that could not look establishes nothing; this
# is the #813/#618/#802 polarity applied to an operator verb.
BLIND="$WORK/blind-monitor"
mkdir -p "$BLIND" "$WORK/blind-state/skeptic/pending"
for _d in skeptic-channel.sh _bookkeeping.sh _channel_lib.sh _fm_lib.sh _window_key.sh _proc_argv.sh; do
    [[ -f "$_repo_root/monitor/$_d" ]] && cp "$_repo_root/monitor/$_d" "$BLIND/$_d"
done
chmod +x "$BLIND/skeptic-channel.sh"
assert_nofile "#984 DOUBT fixture: the probe binary really is absent" "$BLIND/ng"
out=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/blind-state" \
        "$BLIND/skeptic-channel.sh" resolve blindwin \
        --reason "declining the second pass; the finding was already addressed upstream" 2>&1)
assert_not_contains "#984 DOUBT: a probe that could not run does NOT say 'nothing to resolve'" \
    "$out" "nothing to resolve"
assert_contains "#984 DOUBT: …it says the probe could not answer" \
    "$out" "probe did not run"
assert_contains "#984 DOUBT: …names that as doubt, not as absence" \
    "$out" 'doubt, not "no gate"'
assert_contains "#984 DOUBT: …and still points at the release that would work" \
    "$out" "--disposition"

# ============================================================
echo

# ═══ #1161 — THE `;`-LIST FLATTENS THE CODE THE LOOP BRANCHES ON ═══════════
#
# `await` returns 0 (acked: re-enter), 4 (timed out: re-enter), 10 (DONE:
# stop) and 11 (COUNTERPART-FINISHED: do NOT re-enter). Measured on this
# board's transcripts: of 369 backgrounded `await` invocations, ELEVEN ended
# in `exit $rc`. The other 97% reported 0 whatever happened — and 11 read as
# 0 is "re-enter a channel nothing can ever arrive on", i.e. an infinite loop.
#
# THE TITLE OF #1161 MIS-ATTRIBUTES THE CAUSE and the assertions below are
# built to say so: backgrounding does NOT flatten (`& wait $!` preserves 11).
# The mechanism is that a `;`-list reports its LAST statement's status.
# Backgrounding is only the forcing function — the await budget is 900s
# against a 600s tool ceiling, so the timeout path cannot run in foreground.
_f1161="$WORK/f1161"; mkdir -p "$_f1161"
printf '#!/usr/bin/env bash\nexit 11\n' > "$_f1161/await"; chmod +x "$_f1161/await"
_rc1161() { "$1" -c "$2" >/dev/null 2>&1; printf '%s' "$?"; }
_A="$_f1161/await"
for _sh in bash zsh; do
    command -v "$_sh" >/dev/null 2>&1 || continue
    # POSITIVE CONTROL: the stub really does return 11 through this shell.
    # Without it every "flattened to 0" below is a claim about a broken stub.
    assert_eq "#1161 [$_sh] POSITIVE CONTROL: the bare call returns 11" \
        "$(_rc1161 "$_sh" "$_A")" "11"
    assert_eq "#1161 [$_sh] a trailing \`echo\` flattens 11 to 0" \
        "$(_rc1161 "$_sh" "$_A; echo \"RC=\$?\"")" "0"
    # THE CORRECTION THAT MATTERS: capturing is NOT the fix.
    assert_eq "#1161 [$_sh] a bare trailing \`rc=\$?\` ALSO flattens it to 0" \
        "$(_rc1161 "$_sh" "$_A; rc=\$?")" "0"
    assert_eq "#1161 [$_sh] THE PRESCRIBED FORM preserves it" \
        "$(_rc1161 "$_sh" "$_A; rc=\$?; echo x; exit \$rc")" "11"
    # THE TITLE'S CLAIM, REFUTED: backgrounding is not the mechanism.
    assert_eq "#1161 [$_sh] backgrounding does NOT flatten — \`& wait \$!\` preserves 11" \
        "$(_rc1161 "$_sh" "$_A & wait \$!")" "11"
done
# …and the guidance an agent actually reads must spell the prescribed form.
assert_contains "#1161 the nudge paste spells the form that preserves the code" \
    "$(sed -n '/Re-enter the await loop/,+4p' "$CHAN")" 'exit \$rc'

# ═══ #1523 — THE RE-ENTRY MUST NAME ITS WAKE ═══════════════════════════════
#
# rc fidelity (#1161 above) and an ARMED WAKE are different properties, and
# the contract's care about the first read as coverage of the second. Measured
# on w237sk, 2026-09-12: `await` launched through `monitor/async-run.sh` — the
# floor's prescribed launcher for background work — expired correctly
# (`asyncrun:… terminal rc=4 elapsed=902s`), async-run RETAINED the rc, and the
# agent sat idle 809 s until the watcher's orphan-async backstop pasted. Nothing
# re-invoked it: async-run keeps a status, it is not a parking mechanism. So
# every surface that prescribes the loop must name the launch that DOES
# re-invoke the agent — the Bash tool's `run_in_background` — and name the one
# that does not. Two surfaces are pinned: the nudge paste (what an idle agent
# is handed) and the timeout message (the dying process's last words).
_nudge1523=$(sed -n '/Re-enter the await loop/,/proceed to retire/p' "$CHAN")
assert_contains "#1523 the nudge paste names the wake (run_in_background)" \
    "$_nudge1523" 'run_in_background'
assert_contains "#1523 …and names the launcher that does NOT wake (async-run.sh)" \
    "$_nudge1523" 'async-run.sh'
# The #1161 pin above reads a fixed +4 window; the wake sentence must not have
# pushed `exit $rc` out of it (it sits on the command line itself, but say so).
assert_contains "#1523 the #1161 window still carries the rc-preserving form" \
    "$(sed -n '/Re-enter the await loop/,+4p' "$CHAN")" 'exit \$rc'
_t1523="$WORK/t1523"; rm -rf "$_t1523"; mkdir -p "$_t1523"
NEXUS_STATE_DIR="$_t1523/state" bash "$CHAN" init to1523 >/dev/null 2>&1
_err1523=$(NEXUS_STATE_DIR="$_t1523/state" bash "$CHAN" await to1523 --timeout 1 --interval 1 2>&1 >/dev/null); _rc1523=$?
assert_eq "#1523 POSITIVE CONTROL: the timeout path was reached (rc 4)" "$_rc1523" "4"
assert_contains "#1523 the timeout message names the wake" "$_err1523" 'run_in_background'
assert_contains "#1523 the timeout message still says re-enter" "$_err1523" 're-enter await'
# POTENCY: the assertion can fail — a copy with the wake stripped is caught.
_stripped1523=$(sed 's/run_in_background//g' <<<"$_nudge1523")
assert_eq "#1523 POTENCY: with the wake sentence stripped, the needle is absent" \
    "$(grep -cF -- 'run_in_background' <<<"$_stripped1523")" "0"



# ═══ #1178 — A DISPLACED WAITER MUST BE TOLD, IN A DOCUMENTED CODE ══════════
#
# `#615`'s one-live-waiter lock reaps the incumbent with an untrapped
# `kill -TERM`. The victim therefore died at exit 143 — a code the await
# contract does not list — with an EMPTY output file, the explanation landing
# only in the SURVIVOR's stderr, read up to `--timeout` (default 900s) later.
# Measured at 989b888: victim rc=143, 0 bytes, nothing on its side of the
# channel at all.
#
# THE DISPLACEMENT ITSELF IS CORRECT and is not changed: the incumbent is an
# orphan of a prior turn whose stdout nobody will read, so "refuse rather than
# displace" would leave the NEW await with no listener the agent can hear.
# What was wrong is the silence and the undocumented code.
_w1178="$WORK/w1178"; rm -rf "$_w1178"; mkdir -p "$_w1178"
# NOTE: the background job MUST be started in THIS shell, not inside a `$( )`
# helper — a job backgrounded in a command substitution belongs to the
# subshell, so `wait` here cannot see it and returns 127. That 127 is not a
# failure of the code under test; it is the harness failing to look, and it
# would read as a defect. Hence the assignment idiom below rather than a
# pid-echoing function.
NEXUS_STATE_DIR="$_w1178/state" bash "$CHAN" init d1178 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1178/state" bash "$CHAN" await d1178 --timeout 45 --interval 1 \
    > "$_w1178/d1178.out" 2>&1 &
_v1178=$!; sleep 4
NEXUS_STATE_DIR="$_w1178/state" bash "$CHAN" await d1178 --timeout 3 --interval 1 >/dev/null 2>&1
_d1178_rc=$?
wait "$_v1178" 2>/dev/null; _v1178_rc=$?
# POSITIVE CONTROL: the displacer really ran and really timed out, so the
# victim's fate below is a displacement and not some other failure.
assert_eq "#1178 POSITIVE CONTROL: the displacing await ran and timed out (4)" "$_d1178_rc" "4"
assert_eq "#1178 a DISPLACED waiter exits 12, not the undocumented 143" "$_v1178_rc" "12"
assert_contains "#1178 …and says so on ITS OWN stderr, naming the displacer" \
    "$(cat "$_w1178/d1178.out" 2>/dev/null)" "DISPLACED"
assert_contains "#1178 …and tells it not to re-arm, which would displace the live one" \
    "$(cat "$_w1178/d1178.out" 2>/dev/null)" "do NOT re-arm"
# A DURABLE artefact on the channel, so the displacement survives the session
# that observed it.
assert_contains "#1178 …and the reaper leaves a line naming victim and displacer" \
    "$(cat "$_w1178"/state/skeptic/channel/*/.await-displaced 2>/dev/null || \
       find "$_w1178/state" -name '.await-displaced' -exec cat {} \; 2>/dev/null)" \
    "displacer="
# THE DISCRIMINATING CONTROL. A TERM that is NOT a displacement — an operator
# kill, a `timeout` wrapper — must be UNCHANGED. Without this the fix could
# simply be "always exit 12", which would hide every other TERM.
NEXUS_STATE_DIR="$_w1178/state" bash "$CHAN" init e1178 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1178/state" bash "$CHAN" await e1178 --timeout 45 --interval 1 \
    > "$_w1178/e1178.out" 2>&1 &
_o1178=$!; sleep 3
kill -TERM "$_o1178" 2>/dev/null; wait "$_o1178" 2>/dev/null; _o1178_rc=$?
assert_eq "#1178 CONTROL: a NON-displacement TERM still exits 143, unchanged" "$_o1178_rc" "143"
# …and the documented codes either side are untouched.
NEXUS_STATE_DIR="$_w1178/state" bash "$CHAN" init f1178 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1178/state" bash "$CHAN" await f1178 --timeout 2 --interval 1 >/dev/null 2>&1
assert_eq "#1178 CONTROL: an ordinary timeout is still 4" "$?" "4"
# The contract must LIST the code the code emits — the whole point of the issue.
assert_contains "#1178 the exit-code contract documents 12" \
    "$(sed -n '/^# Exit codes:/,/^# State dir resolution/p' "$CHAN")" "12"



# ═══ #1205 — THE DENY ARM MAY STATE ONLY WHAT IT KNOWS ══════════════════════
#
# A window spawned `--skeptic deny` that then DOES skeptic work can never
# register a verdict, and the arm that fires said three things it has no
# evidence for: that the work was "trivial / low-impact", that there was "No
# skeptic pass", and "Recorded." The only fact in evidence is that the SPAWN
# carried a flag. `Recorded.` is the word that stops anyone checking.
#
# It is NOT the inverse of #879 in the way that issue's remedy would suggest.
# Measured: the role path WORKS from a deny-stamped window — a verdict offered
# there is accepted and recorded. So "refuse loudly" would be a REGRESSION,
# breaking the one working hatch, and there is nothing legitimate to refuse: a
# deny-mode worker wrapping up is normal. What was missing is a DIAGNOSTIC at
# the one moment the author is still present.
_w1205="$WORK/w1205"; rm -rf "$_w1205"
mkdir -p "$_w1205/state/skeptic/pending" "$_w1205/state/windows" "$_w1205/reports"
_mk1205() {   # _mk1205 <disposition-line> -> stdout of the deny arm
    rm -rf "$_w1205/state/windows"; mkdir -p "$_w1205/state/windows"
    { printf -- '---\nproject: g1205\n%s\n---\n# r\n## Summary\nx\n' "$1"; } > "$_w1205/reports/r.md"
    NEXUS_STATE_DIR="$_w1205/state" bash -c '
        source "$1" >/dev/null 2>&1
        STATE_DIR="$2/state"
        mkdir -p "$STATE_DIR/windows"
        printf "{\"skeptic_mode\":\"deny\",\"skeptic_role\":false}\n" \
            > "$STATE_DIR/windows/$(wk_encode g1205).json"
        _SK_REPORT_PATH="$2/reports/r.md"
        _wrapup_skeptic_step 101 g1205 owner/repo 0 "" "" "" "" "" "" ""
    ' _ "$NG" "$_w1205" 2>&1
}
_o1205=$(_mk1205 'disposition: second-pass')
# POSITIVE CONTROL: the deny arm was actually reached. Every assertion below is
# a false pass on some other arm's output without it.
assert_contains "#1205 POSITIVE CONTROL: the deny arm ran" "$_o1205" "DISABLED AT SPAWN"
# THE PROPERTY — it may not assert what it cannot know.
assert_not_contains "#1205 it does NOT claim the work was trivial / low-impact" \
    "$_o1205" "trivial / low-impact"
assert_not_contains "#1205 …and does not say \`Recorded.\`, the word that stops anyone checking" \
    "$_o1205" "Recorded."
assert_contains "#1205 …it names the SPAWN FLAG as the sole fact in evidence" \
    "$_o1205" 'The SPAWN carried'
assert_contains "#1205 …and says plainly that no verdict was recorded" \
    "$_o1205" "NO verdict is recorded"
# …and it READS the report it is handing off, at the one moment the author is present.
assert_contains "#1205 a report stating a disposition is SURFACED" \
    "$_o1205" "THIS REPORT STATES A SKEPTIC DISPOSITION: second-pass"
assert_contains "#1205 …naming the re-run that WOULD register it" \
    "$_o1205" "--skeptic-role --skeptic-target"
assert_contains "#1205 …and saying it is a diagnostic, not a gate" \
    "$_o1205" "diagnostic, not a gate"
# NEGATIVE CONTROL: a report with no disposition must NOT trip the block, or the
# diagnostic becomes noise and gets ignored — which is how a real one is missed.
_n1205=$(_mk1205 'note: nothing')
assert_contains "#1205 NEG CTL: the arm still runs without a disposition" \
    "$_n1205" "DISABLED AT SPAWN"
assert_not_contains "#1205 NEG CTL: …and says NOTHING about a disposition" \
    "$_n1205" "THIS REPORT STATES A SKEPTIC DISPOSITION"



# ═══ #1182 — DO NOT ASK FOR THE ROUTING ACTION THIS WRAP-UP ALREADY DID ═════
#
# `_wrapup_skeptic_step` calls `_wrapup_notify_pinned_skeptic` TEN LINES before
# it sets `_SK_SPAWN_REQ=1`. That call locates the pinned reviewer, reopens the
# obligation edge and delivers the delta notice — and then the filer emits a
# request whose body says `live-skeptic-window: yes … RE-PIN it`. One wrap-up
# performs the re-pin and then asks the orchestrator to perform the re-pin.
# Measured on this board: 12 of 12 CONFIRMED deliveries since 2026-08-30 were
# followed 9-20s later by exactly such a request. Zero exceptions.
#
# THE PROBE WAS NEVER THE PROBLEM AND IS NOT THE FIX. `_live_skeptic_window`
# reports through globals, and the filer calls it inside `$( )` — a subshell —
# so even those globals are discarded; its answer only ever reached the request
# BODY. Suppressing on the mere EXISTENCE of a reviewer would be wrong too: a
# live skeptic makes the answer "re-pin", not "no skeptic needed". What
# suppresses here is a DELIVERY RECEIPT, set only on rc 0 from the notify path.
_r1182="$WORK/r1182"; rm -rf "$_r1182"; mkdir -p "$_r1182/state/requests" "$_r1182/reports"
printf 'body\n' > "$_r1182/reports/r.md"
_f1182() {   # _f1182 <notified> <deliberate> -> the filer's status token
    rm -f "$_r1182"/state/requests/*.md 2>/dev/null || true
    # `set -u` because PRODUCTION runs under it and this harness did not: an
    # out-of-scope `pending_dir` in the filer expanded to empty here and
    # passed, while the real `ng` aborted the line with `unbound variable`. A
    # harness more permissive than production cannot see that class at all.
    bash -c '
        set -uo pipefail
        source "$1" >/dev/null 2>&1
        STATE_DIR="$2/state"
        _SK_SPAWN_REQ=1; _SK_SPAWN_TARGET=tgt1182; _SK_SPAWN_DEPTH=1; _SK_SPAWN_ORIG=tgt1182
        _SK_SPAWN_DELIBERATE="$4"; _SK_PINNED_NOTIFIED="$3"; _SK_PINNED_WHY=changed
        _wrapup_file_spawn_skeptic_request 101 "$2/reports/r.md" "" "" "" owner/repo
    ' _ "$NG" "$_r1182" "$1" "$2" 2>&1
}
# POSITIVE CONTROL FIRST: with no receipt the filer still FILES. Without this,
# "skipped" below could mean the harness never reached the filer at all.
_p1182=$(_f1182 "" 0)
assert_contains "#1182 POSITIVE CONTROL: with no receipt the request is still FILED" \
    "$_p1182" "filed"
# THE PROPERTY.
_s1182=$(_f1182 "fig4sk" 0)
assert_contains "#1182 a CONFIRMED delivery suppresses the duplicate request" \
    "$_s1182" "skipped"
assert_contains "#1182 …naming the reviewer, so the suppression is auditable" \
    "$_s1182" 'fig4sk'
assert_contains "#1182 …and saying WHY, not just that it skipped" \
    "$_s1182" "RE-PIN that already happened"
# NEGATIVE CONTROL: a DELIBERATE request must still file. The receipt answers
# "the routing action already happened", which is not a reason to drop a
# request someone asked for on purpose.
assert_contains "#1182 NEG CTL: a DELIBERATE request still files despite the receipt" \
    "$(_f1182 "fig4sk" 1)" "filed"

# ── #1209's `ledger-evidence:` MUST CARRY THE REAL CLASS, NOT ALWAYS `?` ────
# The row exists so three materially different states stop rendering
# identically. It is computed in the FILER, which does NOT have
# `_wrapup_skeptic_step`'s `pending_dir` in scope — referencing it there was an
# unbound variable under `set -u`, and the code FAILS SOFT to the `?` string, so
# every assertion about filing still passed while the field said "no readable
# ledger" for every request ever filed. Asserting the field's CONTENT against a
# ledger that demonstrably IS readable is the only thing that sees it.
_e1209="$WORK/e1209"; rm -rf "$_e1209"
mkdir -p "$_e1209/state/skeptic/pending" "$_e1209/state/requests" "$_e1209/reports"
printf 'body
' > "$_e1209/reports/r.md"
_h1209=$(printf 'body
' | sha256sum | awk '{print $1}')
_k1209=$(bash -c 'source "$1" >/dev/null 2>&1; wk_encode tgt1209' _ "$NG")
{ printf 'armed	%s	2026-09-01T01:00:00	1209	%s
' "$_h1209" "$_e1209/reports/r.md"
  printf 'discharged	%s	2026-09-01T01:30:00	credible	1209	sk	attributed
' "$_h1209"
} > "$_e1209/state/skeptic/pending/.${_k1209}.ledger"
# POSITIVE CONTROL: the ledger really is readable, read independently.
assert_contains "#1209 POSITIVE CONTROL: this ledger IS readable and classifies"     "$(NEXUS_STATE_DIR="$_e1209/state" "$NG" skeptic-evidence tgt1209 --state-dir "$_e1209/state" 2>/dev/null | sed -n 1p)"     "evidence=attributed"
# `NEXUS_STATE_DIR` is EXPORTED, not just `STATE_DIR` set. `request-channel.sh`
# is a SEPARATE PROCESS that resolves its own state dir from the ENV; setting
# `ng`'s internal shell variable does nothing for it. Getting this wrong writes
# fixture rows into the PRODUCTION request inbox, where the orchestrator's job
# is to spawn a real agent against them.
_b1209=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$_e1209/state" bash -c '
    set -uo pipefail
    source "$1" >/dev/null 2>&1
    STATE_DIR="$2/state"
    _SK_SPAWN_REQ=1; _SK_SPAWN_TARGET=tgt1209; _SK_SPAWN_DEPTH=1; _SK_SPAWN_ORIG=tgt1209
    _SK_SPAWN_DELIBERATE=0; _SK_PINNED_NOTIFIED=""; _SK_PINNED_WHY=""
    _wrapup_file_spawn_skeptic_request 1209 "$2/reports/r.md" "" "" "" owner/repo >/dev/null 2>&1
    find "$2/state/requests" -name "*.md" -exec cat {} + 2>/dev/null
' _ "$NG" "$_e1209" 2>/dev/null)
assert_contains "#1209 the filed request carries a ledger-evidence row" "$_b1209" "ledger-evidence:"
assert_eq "#1209 …and it is the REAL class, not the could-not-look fallback"     "$( grep -q 'ledger-evidence: .*no readable ledger' <<<"$_b1209" && echo FALLBACK || echo real)" "real"
assert_contains "#1209 …naming the class the ledger actually has" "$_b1209" "evidence=attributed"



# ═══ #1209 — A DEBTOR MAY NOT REOPEN AN OBLIGATION ITS CREDITOR SETTLED ═════
#
# A `close` is the CREDITOR's terminal act; a wrap-up is the DEBTOR's. The
# existing `resolved` arm already enforces this for `ng skeptic resolve` — but
# it keys on `.cleared-rationale`, a file `close` does NOT write. `close`
# records its settlement as a `resolved` LEDGER ROW plus a DONE sentinel, and
# the arm path read neither, so a wrap-up re-armed a CLOSED obligation against
# a RETIRED creditor and destroyed the DONE on the way.
#
# Measured at base: marker WRITTEN, DONE GONE. The three states the issue
# describes rendered byte-identical request bodies — same md5, differing only
# in the request id and the created timestamp, both functions of wall clock.
_c1209() {   # _c1209 <mode> -> "marker=<y/n> DONE=<y/n>"
    local mode="$1" w="$WORK/w1209-$1"
    rm -rf "$w"; mkdir -p "$w/state/skeptic/pending" "$w/state/requests" "$w/reports"
    bash -c '
        set -uo pipefail
        NG="$1"; W="$2"; mode="$3"
        export NEXUS_STATE_DIR="$W/state"
        source "$NG" >/dev/null 2>&1
        STATE_DIR="$W/state"; P="$STATE_DIR/skeptic/pending"; K=$(wk_encode c1209t)
        # FRONTMATTER WITH A REAL `disposition:` — required since #1095'"'"'s
        # worker-path refusal landed on this arm. That deny runs BEFORE this
        # suppression by design (a `return 0` ahead of a deny is #1121'"'"'s
        # arm-order defect), so a fixture stating no disposition is refused
        # and never reaches the code under test. Without this the guard reds
        # for a reason that has nothing to do with #1209.
        printf -- "---\nproject: c1209t\ndisposition: no-further-pass\n---\nthe report\n" > "$W/reports/r.md"
        H=$(sha256sum < "$W/reports/r.md" | awk "{print \$1}")
        {   printf "armed\t%s\t2026-09-01T01:00:00\t1209\t%s\n" "$H" "$W/reports/r.md"
            printf "discharged\t%s\t2026-09-01T01:30:00\tcredible\t1209\tsk2\tattributed\n" "$H"
            printf "resolved\t-\t2026-09-01T01:40:00\tskeptic-channel.sh close\tclosed by the reviewer\n"
            if [ "$mode" = armafter ]; then
                printf "armed\t%s\t2026-09-01T02:00:00\t1209\t%s\n" \
                    "$(printf x | sha256sum | awk "{print \$1}")" "$W/reports/r.md"
            fi
        } > "$P/.$K.ledger"
        mkdir -p "$STATE_DIR/skeptic/c1209t"; : > "$STATE_DIR/skeptic/c1209t/DONE"
        # THE #1209 SHAPE: the report is AMENDED after the close, so the sha
        # differs and suppression 1 (#984, byte-identical) cannot fire. Without
        # this the fixture never reaches the arm under test.
        printf -- "---\nproject: c1209t\ndisposition: no-further-pass\n---\nthe report\nplus a later edit\n" > "$W/reports/r.md"
        _SK_REPORT_PATH="$W/reports/r.md"
        rearm=""; [ "$mode" = rearm ] && rearm="the base moved under the review"
        out=$(_wrapup_skeptic_step 1209 c1209t owner/repo 0 require "why" "" "" "" "" "" "" "" "$rearm" 2>&1)
        printf "marker=%s DONE=%s reqs=%s BANNER=%s\n" \
            "$([ -e "$P/$K" ] && echo y || echo n)" \
            "$([ -e "$STATE_DIR/skeptic/c1209t/DONE" ] && echo y || echo n)" \
            "$(find "$STATE_DIR/requests" -name "*.md" 2>/dev/null | wc -l | tr -d " ")" \
            "$(printf "%s" "$out" | grep -c "RECORDED AS SETTLED" || true)"
    ' _ "$NG" "$w" "$mode" 2>/dev/null
}
_s1209=$(_c1209 settled)
# POSITIVE CONTROL: the harness reached the arm at all. Every "no marker" below
# is a false pass if the step errored out before arming anything.
assert_contains "#1209 POSITIVE CONTROL: the settled case reached the suppression" \
    "$_s1209" "BANNER=1"
assert_contains "#1209 a SETTLED obligation is not re-armed" "$_s1209" "marker=n"
assert_contains "#1209 …and the creditor's DONE sentinel SURVIVES" "$_s1209" "DONE=y"
assert_contains "#1209 …and no duplicate spawn-skeptic request is filed" "$_s1209" "reqs=0"
# NEGATIVE CONTROL 1 — the load-bearing narrowing. An `armed` row AFTER the
# settlement re-opens it normally, and `spawn-worker.sh` writes one via
# `ng skeptic-arm` whenever the orchestrator appoints a reviewer. So re-opening
# stays fully available to the party ENTITLED to do it; only the debtor's
# silent self-re-arm is stopped.
_a1209=$(_c1209 armafter)
assert_contains "#1209 NEG CTL: an arm AFTER the settlement still arms normally" \
    "$_a1209" "marker=y"
assert_contains "#1209 NEG CTL: …and the suppression does NOT fire there" \
    "$_a1209" "BANNER=0"
# NEGATIVE CONTROL 2 — the deliberate, on-the-record override.
_r1209=$(_c1209 rearm)
assert_contains "#1209 NEG CTL: --skeptic-rearm overrides the suppression" \
    "$_r1209" "marker=y"

# ---------------------------------------------------------------------------
echo '=== #1371: the task-key refusal GATES, in the main shell ==='
# `_channel_dir`'s die runs inside `$( )`, so before the hoist a refused key was
# byte-identical to an empty channel at rc 0: `status .hidden` printed
# `open=0 … done=0`. Paired control: the refused key must exit non-zero with NO
# status line, and a valid key must still answer.
G1371="$WORK/g1371"; mkdir -p "$G1371"
_g1371() { env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$G1371" bash "$_test_dir/../skeptic-channel.sh" "$@"; }
_g1371 init good >/dev/null 2>&1
_o=$(_g1371 status .hidden 2>/dev/null); _rc=$?
assert_eq "#1371 status on a refused key exits non-zero (was rc 0)" "$_rc" "1"
assert_eq "#1371 …and prints NO status line (was open=0 … done=0)" "$_o" ""
_o=$(_g1371 status good 2>/dev/null); _rc=$?
assert_eq "#1371 CONTROL: status on a valid key still answers, rc 0" "$_rc/$_o" "0/open=0 ack=0 answered=0 total=0 done=0"
_o=$(_g1371 close .hidden 2>/dev/null); _rc=$?
assert_eq "#1371 a WRITE verb (close) on a refused key exits non-zero" "$_rc" "1"
assert_eq "#1371 …and mints nothing on disk under the refused key" "$(ls -A "$G1371/skeptic" 2>/dev/null | grep -c '^\.hidden$' || true)" "0"
_skc_src="$_test_dir/../skeptic-channel.sh"
_skc_caps=$(grep -v '^[[:space:]]*#' "$_skc_src" | grep -c '\$(_channel_dir "\$\|\$(_pending_marker "\$')
_skc_gated=$(grep -v '^[[:space:]]*#' "$_skc_src" | grep -B1 '\$(_channel_dir "\$\|\$(_pending_marker "\$' | grep -c '_require_valid_task_key "\$')
assert_eq "#1371 every \$(_channel_dir)/\$(_pending_marker) capture is preceded by the main-shell gate (all but _done_sentinel)" \
    "$_skc_caps/$_skc_gated" "$_skc_caps/$(( _skc_caps - 1 ))"
assert_eq "#1371 …and that census is non-vacuous (>= 15 captures)" "$(( _skc_caps >= 15 ))" "1"
# (the -1 is `_done_sentinel`, a helper whose callers have already passed the gate)

echo '=== #1411: a <req> containing / or .. is refused BEFORE it is joined to the channel dir ==='
G1411="$WORK/g1411"; mkdir -p "$G1411"
_g1411() { env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$G1411" bash "$_test_dir/../skeptic-channel.sh" "$@"; }
for _t in t1 t2; do _g1411 init "$_t" >/dev/null 2>&1; _g1411 ask "$_t" q1 --message 'hello?' >/dev/null 2>&1; done
_g1411 answer t1 ../t2/req-001-q1.open.md --message 'reply' >/dev/null 2>&1; _rc=$?
assert_eq "#1411 answer <task> ../<other>/req is refused (rc 1)" "$_rc" "1"
assert_eq "#1411 …and the OTHER channel's request is untouched (still .open.md)" "$(ls "$G1411/skeptic/t2")" "req-001-q1.open.md"
_g1411 reqfile t1 ../t2/req-001-q1.open.md >/dev/null 2>&1; _rc=$?
assert_eq "#1411 reqfile <task> ../<other>/req is refused too" "$_rc" "1"
_g1411 answer t1 1 --message 'reply' >/dev/null 2>&1; _rc=$?
assert_eq "#1411 CONTROL: a bare request number still answers" "$_rc/$(ls "$G1411/skeptic/t1" | grep -c answered)" "0/1"

echo '=== #1410: a window NAME containing a space resolves to ITS index, not to its first word'"'"'s ==='
# A stub tmux honouring `list-windows -F <fmt>` with windows `foo`(1),
# `foo bar`(2), `other`(3). Under default awk splitting "foo bar" compared only
# `foo` against $2 and matched NOTHING (rc 1 — nudge skipped); a name whose
# first word is another window's whole name is the paste-into-the-wrong-window
# direction. Tab-separated on both sides now.
G1410="$WORK/g1410"; mkdir -p "$G1410"
cat > "$G1410/tmux" <<'EOF'
#!/usr/bin/env bash
fmt="$3"; for w in "1|foo" "2|foo bar" "3|other"; do i=${w%%|*}; n=${w#*|}; f=${fmt//\#\{window_index\}/$i}; f=${f//\#\{window_name\}/$n}; printf '%b\n' "$f"; done
EOF
chmod +x "$G1410/tmux"
_r1410=$(PATH="$G1410:$PATH" bash -c 'eval "$(sed -n "/^_resolve_window_index()/,/^}/p" "$1")"; printf "%s/%s/%s" "$(_resolve_window_index foo)" "$(_resolve_window_index "foo bar")" "$(_resolve_window_index other)"' _ "$_test_dir/../skeptic-channel.sh")
assert_eq "#1410 foo→1, 'foo bar'→2, other→3 (was foo→1, 'foo bar'→<none>)" "$_r1410" "1/2/3"

# ---------------------------------------------------------------------------
echo '=== #1360: the TERM handler reads the DURABLE displacement record; the displacer need not still be alive ==='
# The #1178 fixture's displacer is `--timeout 3`, so it may have EXITED by the
# time the victim's handler runs; a liveness-gated handler then took the 143
# fallback with an empty stderr — 3 in 40 CI bands, always the same trio.
# Plant the record the displacer writes (owner = a pid that does not exist,
# a .await-displaced row naming this victim) and TERM the victim.
_w1360="$WORK/w1360"; mkdir -p "$_w1360"
NEXUS_STATE_DIR="$_w1360/state" bash "$CHAN" init d1360 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1360/state" bash "$CHAN" await d1360 --timeout 45 --interval 1 > "$_w1360/v.out" 2>&1 &
_v1360=$!; sleep 3
_c1360=$(NEXUS_STATE_DIR="$_w1360/state" bash "$CHAN" dir d1360)
echo 999999 > "$_c1360/.await-owner"
printf 'ts=%s victim=%s displacer=%s task=%s\n' "$(date +%s)" "$_v1360" 999999 d1360 >> "$_c1360/.await-displaced"
kill -TERM "$_v1360" 2>/dev/null; wait "$_v1360" 2>/dev/null; _v1360_rc=$?
assert_eq "#1360 a DEAD displacer with its durable record present → 12, not 143" "$_v1360_rc" "12"
assert_contains "#1360 …and the victim still names the displacer on its own stderr" "$(cat "$_w1360/v.out")" "pid 999999"
# DISCRIMINATING CONTROL: an owner record naming another pid WITHOUT a
# displaced row for THIS victim is not a displacement (a stale owner file from
# a prior round, an operator TERM) — still 143.
NEXUS_STATE_DIR="$_w1360/state" bash "$CHAN" init e1360 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1360/state" bash "$CHAN" await e1360 --timeout 45 --interval 1 > "$_w1360/e.out" 2>&1 &
_e1360=$!; sleep 3
echo 999999 > "$(NEXUS_STATE_DIR="$_w1360/state" bash "$CHAN" dir e1360)/.await-owner"
kill -TERM "$_e1360" 2>/dev/null; wait "$_e1360" 2>/dev/null; _e1360_rc=$?
assert_eq "#1360 CONTROL: a foreign owner pid with NO displaced row for this victim is still 143" "$_e1360_rc" "143"

echo '=== #845 claim H: defer releases THIS wait (exit 13) while the requirement STANDS ==='
_w845="$WORK/w845h"; mkdir -p "$_w845/state/skeptic/pending"
NEXUS_STATE_DIR="$_w845/state" bash "$CHAN" init h845 >/dev/null 2>&1
echo 1 > "$_w845/state/skeptic/pending/h845"
NEXUS_STATE_DIR="$_w845/state" bash "$CHAN" await h845 --timeout 45 --interval 1 > "$_w845/h.out" 2> "$_w845/h.err" &
_h845=$!; sleep 2
NEXUS_STATE_DIR="$_w845/state" bash "$CHAN" defer h845 --reason 'run the band on the merged tree first' --until 'a green band is linked' >/dev/null 2>&1; _d845_rc=$?
wait "$_h845" 2>/dev/null; _h845_rc=$?
assert_eq "#845H defer exits 0" "$_d845_rc" "0"
assert_eq "#845H the parked await exits 13 (DEFERRED) — not 10, not 11" "$_h845_rc" "13"
assert_contains "#845H …printing the reason verbatim" "$(cat "$_w845/h.err")" "reason=run the band on the merged tree first"
assert_contains "#845H …and the condition" "$(cat "$_w845/h.err")" "until=a green band is linked"
assert_eq "#845H THE POINT: the pending marker is UNTOUCHED (retire-preflight keeps gating)" "$([[ -e "$_w845/state/skeptic/pending/h845" ]] && echo present || echo absent)" "present"
assert_eq "#845H the record is CONSUMED, so one defer releases one wait" "$([[ -e "$(NEXUS_STATE_DIR="$_w845/state" bash "$CHAN" dir h845)/.await-deferred" ]] && echo present || echo absent)" "absent"
NEXUS_STATE_DIR="$_w845/state" bash "$CHAN" defer h845 >/dev/null 2>&1; assert_eq "#845H defer without --reason is refused (rc 1)" "$?" "1"
# 11 still requires the MARKER to go — a re-entered await is not released by the consumed defer
NEXUS_STATE_DIR="$_w845/state" bash "$CHAN" await h845 --timeout 45 --interval 1 > "$_w845/h2.out" 2>&1 &
_h845b=$!; sleep 2; rm -f "$_w845/state/skeptic/pending/h845"; wait "$_h845b" 2>/dev/null
assert_eq "#845H CONTROL: after re-entry, removing the marker is still what yields 11" "$?" "11"
assert_contains "#845H the exit-code contract documents 13" "$(sed -n '/^# Exit codes:/,/^# State dir resolution/p' "$CHAN")" "13"

echo '=== #1434: reset archives OUTSIDE the channel (a retirement no longer destroys it) ==='
_w1434="$WORK/w1434"; mkdir -p "$_w1434"
NEXUS_STATE_DIR="$_w1434/state" bash "$CHAN" init r1434 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1434/state" bash "$CHAN" close r1434 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1434/state" bash "$CHAN" reset r1434 >/dev/null 2>&1
assert_eq "#1434 reset's archive lives under skeptic/.archive/, not inside the channel" \
    "$(find "$_w1434/state/skeptic/.archive" -maxdepth 1 -name 'r1434.reset-*' 2>/dev/null | grep -c .)/$(find "$_w1434/state/skeptic/r1434" -maxdepth 1 -name '.stale-archive-*' 2>/dev/null | grep -c .)" "1/0"
assert_eq "#1434 …and the archived DONE is readable there" "$(find "$_w1434/state/skeptic/.archive" -path '*/r1434.reset-*/DONE' 2>/dev/null | grep -c .)" "1"
assert_contains "#1434 list SAYS the tree is pruned at retirement (remedy 1)" \
    "$(NEXUS_STATE_DIR="$_w1434/state" bash "$CHAN" list r1434 2>/dev/null)" "survey of survivors"

# ---------------------------------------------------------------------------
echo '=== #1426: the await lock authorises a kill by argv POSITION, never by substring ==='
# A `claude` process's argv IS its prompt: any agent briefed about this await
# carried "skeptic-channel.sh", " await " and " <task>" somewhere in argv and
# satisfied the old three-substring predicate — the one `_await_claim_singleton`
# sends `kill -TERM` to. Real processes, planted, and the SHARED parser asked.
_w1426="$WORK/w1426"; mkdir -p "$_w1426/state"
# shellcheck source=/dev/null
. "$_test_dir/../_proc_argv.sh"
NEXUS_STATE_DIR="$_w1426/state" bash "$CHAN" init d1426 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1426/state" bash "$CHAN" await d1426 --timeout 40 --interval 1 >/dev/null 2>&1 &
_real1426=$!
# The mention rides in a POSITIONAL argument and the -c list ends in a builtin:
# bash 5.2 (CI's pin) EXECS a trailing external command in place, so with
# `…; sleep 40` the mention had LEFT argv before the check ran and the control
# read `no` in all five CI bands while bash 4.4 here kept it (W2-20, #1378).
bash -c 'sleep 40; :' _ 'brief: run skeptic-channel.sh await d1426 when ready' >/dev/null 2>&1 &
_mention1426=$!
NEXUS_STATE_DIR="$_w1426/state" bash "$CHAN" init other1426 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1426/state" bash "$CHAN" await other1426 --timeout 40 --interval 1 >/dev/null 2>&1 &
_other1426=$!
sleep 2
assert_eq "#1426 POSITIVE: a real await for the task is ours" \
    "$(proc_pid_is_skeptic_await "$_real1426" d1426 && echo yes || echo no)" "yes"
assert_eq "#1426 a process whose ARGV merely MENTIONS the await is NOT ours (old predicate: yes)" \
    "$(proc_pid_is_skeptic_await "$_mention1426" d1426 && echo yes || echo no)" "no"
assert_eq "#1426 a real await for a DIFFERENT task is not ours" \
    "$(proc_pid_is_skeptic_await "$_other1426" d1426 && echo yes || echo no)" "no"
assert_eq "#1426 a dead pid is not ours" "$(proc_pid_is_skeptic_await 999999 d1426 && echo yes || echo no)" "no"
# the old predicate, reconstructed, accepts the mention — so this is a change in
# the AUTHORISATION, shown rather than asserted
_old1426() { local c; c=$(tr '\0' ' ' < "/proc/$1/cmdline"); [[ "$c" == *"skeptic-channel.sh"* && "$c" == *" await "* && "$c" == *" $2"* ]]; }
assert_eq "#1426 CONTROL: the substring predicate this replaces DID accept the mention" \
    "$(_old1426 "$_mention1426" d1426 && echo yes || echo no)" "yes"
kill "$_real1426" "$_mention1426" "$_other1426" 2>/dev/null; wait "$_real1426" "$_mention1426" "$_other1426" 2>/dev/null

echo '=== #1426 residuals: IDENTITY, not a name — start-time in .await-owner, heredoc bodies are data ==='
# (1b) The record carries `<pid> <starttime>`; the ownership question is asked
# of pid AND start-time AND argv position. A recycled pid, or a record with
# no start-time, is refused outright.
_w1426b="$WORK/w1426b"; mkdir -p "$_w1426b/state"
NEXUS_STATE_DIR="$_w1426b/state" bash "$CHAN" init i1426 >/dev/null 2>&1
NEXUS_STATE_DIR="$_w1426b/state" bash "$CHAN" await i1426 --timeout 40 --interval 1 >/dev/null 2>&1 &
_ident1426=$!
sleep 2
_owner1426="$(NEXUS_STATE_DIR="$_w1426b/state" bash "$CHAN" dir i1426)/.await-owner"
read -r _opid1426 _ost1426 < "$_owner1426"
assert_eq "#1426 .await-owner records TWO fields: pid and start-time" \
    "$([[ "$_opid1426" =~ ^[0-9]+$ && "$_ost1426" =~ ^[0-9]+$ ]] && echo yes || echo no)" "yes"
assert_eq "#1426 …and the start-time is the kernel's for that pid" \
    "$_ost1426" "$(proc_pid_starttime "$_opid1426")"
assert_eq "#1426 POSITIVE: pid + its OWN start-time → ours" \
    "$(proc_pid_is_skeptic_await_identity "$_opid1426" i1426 "$_ost1426" && echo yes || echo no)" "yes"
assert_eq "#1426 the same pid with a DIFFERENT start-time (a recycled pid) → NOT ours" \
    "$(proc_pid_is_skeptic_await_identity "$_opid1426" i1426 "$(( _ost1426 + 1 ))" && echo yes || echo no)" "no"
assert_eq "#1426 an EMPTY start-time (pre-#1426 record) → NOT ours: a pid alone is a name" \
    "$(proc_pid_is_skeptic_await_identity "$_opid1426" i1426 "" && echo yes || echo no)" "no"
# CONTROL: the name-only predicate ACCEPTS the recycled-pid shape — so the
# identity check is a change in authorisation, shown rather than asserted.
assert_eq "#1426 CONTROL: the pid-only predicate cannot see a recycled pid (says ours)" \
    "$(proc_pid_is_skeptic_await "$_opid1426" i1426 && echo yes || echo no)" "yes"
# (3) a DISPLACEMENT goes through: the second await reaps the first by
# identity and the durable row carries the start-time and the
# proc-kill-authorized verdict.
NEXUS_STATE_DIR="$_w1426b/state" bash "$CHAN" await i1426 --timeout 40 --interval 1 >/dev/null 2>&1 &
_ident1426b=$!
sleep 2
wait "$_ident1426" 2>/dev/null; _ident_rc=$?
assert_eq "#1426 the displaced await exits 12 (DISPLACED), reaped by identity" "$_ident_rc" "12"
_disp1426=$(cat "$(NEXUS_STATE_DIR="$_w1426b/state" bash "$CHAN" dir i1426)/.await-displaced" 2>/dev/null | tail -1)
assert_eq "#1426 the .await-displaced row carries victim-start= and the proc-kill-authorized verdict" \
    "$(grep -c "victim=$_opid1426 .*victim-start=$_ost1426 authority=await-owner-record pka=" <<<"$_disp1426")" "1"
kill "$_ident1426b" 2>/dev/null; wait "$_ident1426b" 2>/dev/null
# The W2-20 skeptic's plant: a `zsh -c` list whose HEREDOC body carries the
# await at line start. Before: the positional parser split at the newline and
# read the body line as a command → MATCH. After: heredoc bodies are masked.
_plant1426=$(mktemp "$WORK/plant.XXXXXX")
printf 'zsh\0-c\0cat > brief.md <<'"'"'EOF'"'"'\nrun `monitor/skeptic-channel.sh await h1426 --timeout 900` when ready\nEOF\necho done\0' > "$_plant1426"
assert_eq "#1426 a heredoc BODY mentioning the await (the skeptic plant) is NOT an await" \
    "$(proc_argv_skeptic_await_task "$_plant1426" && echo yes || echo no)" "no"
printf 'zsh\0-c\0cat > brief.md <<EOF\nnothing\nEOF\nmonitor/skeptic-channel.sh await h1426 --timeout 900\0' > "$_plant1426"
assert_eq "#1426 CONTROL: the same list with the await OUTSIDE the heredoc IS an await" \
    "$(proc_argv_skeptic_await_task "$_plant1426")" "h1426"
printf 'zsh\0-c\0cat > brief.md <<EOF\nmonitor/skeptic-channel.sh await h1426\0' > "$_plant1426"
assert_eq "#1426 an UNTERMINATED heredoc masks to the end of the list" \
    "$(proc_argv_skeptic_await_task "$_plant1426" && echo yes || echo no)" "no"
rm -f "$_plant1426"
# #1450 — TWO SPELLINGS THAT CONTAIN `<<` AND ARE NOT HEREDOCS. A herestring
# (`<<<"$x"`) and an arithmetic left shift (`$((a<<b))`) each used to open a
# "body" no delimiter ever closed, so a REAL await positioned after either in
# the same -c list was masked away: not reaped (safe direction), not counted.
printf 'zsh\0-c\0echo <<<"x"; monitor/skeptic-channel.sh await hs1450\0' > "$_plant1426"
assert_eq "#1450 a HERESTRING (<<<) before a real await does not mask it" \
    "$(proc_argv_skeptic_await_task "$_plant1426")" "hs1450"
printf 'zsh\0-c\0n=$((a<<b)); monitor/skeptic-channel.sh await sh1450\0' > "$_plant1426"
assert_eq "#1450 an ARITHMETIC SHIFT (\$((a<<b))) before a real await does not mask it" \
    "$(proc_argv_skeptic_await_task "$_plant1426")" "sh1450"
printf 'zsh\0-c\0echo <<<"x"; cat <<EOF\nmonitor/skeptic-channel.sh await hb1450\nEOF\n\0' > "$_plant1426"
assert_eq "#1450 CONTROL: a herestring does not UNMASK a real heredoc body after it" \
    "$(proc_argv_skeptic_await_task "$_plant1426" || printf 'not-an-await')" "not-an-await"


if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
