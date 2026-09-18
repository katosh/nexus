#!/usr/bin/env bash
# test-request-reply-skeptic-ledger.sh — answering a spawn-skeptic request must
# leave the REQUEST record and the SKEPTIC LEDGER agreeing about what the answer
# MEANT.
#
# THE HOLE THIS FILLS (your-org/nexus-code#1293). `ng request reply` on a
# spawn-skeptic DECLINE wrote nothing to the skeptic ledger. The request moved
# to `.replied.md`, the verb returned 0, the requesting agent read the decline
# and reasonably reported it as recorded — and `retire-window` later refused
# with "a cleared marker is not clearance", because from the ledger's side no
# verdict and no resolution existed. Measured three times in one session; each
# was fixed by re-issuing the SAME decision through `ng skeptic resolve`, so
# the decision was never in doubt, only its record. It also produced re-filing
# loops (one window filed the same request four times), because answering
# resolves the REQUEST without changing anything the requester's wrap-up reads.
#
# A DECLINE THAT IS NOT RECORDED IS INDISTINGUISHABLE FROM A REVIEW THAT NEVER
# HAPPENED — the ambiguity of #961 and #1199.
#
# WHAT THIS ASSERTS, driving the REAL request-channel.sh and the REAL
# skeptic-channel.sh against a hermetic NEXUS_STATE_DIR:
#
#   1  an unrecognised --status is REFUSED, not recorded as a label. `status`
#      now SELECTS (it decides whether the gate is discharged), and a value
#      that selects must not be a free string (#1050).
#   2  `--status answered` on a spawn-skeptic request is REFUSED as ambiguous.
#      This is the exact shape of all three incidents: the reply could not say
#      whether a reviewer was coming, so the population on disk was
#      unclassifiable after the fact.
#   3  `--status spawned` without --worker is REFUSED — an unnamed spawn
#      discharges nothing.
#   4  `--status spawned --worker W` succeeds and LEAVES THE MARKER ARMED. The
#      reviewer's own verdict discharges it later; that is the correct
#      no-op-here case, and asserting it stops arm 7 from being satisfied by a
#      fix that just clears the gate on every reply.
#   5  a DECLINE with a too-short rationale is REFUSED rather than PADDED. A
#      manufactured audit rationale is worse than no verb.
#   6  a DECLINE whose ledger write FAILS refuses the WHOLE reply and leaves the
#      request unmoved. ORDER IS THE GUARANTEE (#665): resolve-then-reply fails
#      LOUD; reply-then-resolve fails SILENT, and the silent one IS the bug.
#   7  a DECLINE with an armed marker resolves the ledger AND replies — one act,
#      marker cleared, rationale on disk naming the request id.
#   8  `--status deferred` replies and DELIBERATELY LEAVES THE MARKER ARMED.
#      This is the member that makes the vocabulary worth having: "not now" is
#      not "no review needed".
#   9  a NON-spawn-skeptic request is completely unaffected (no regression).
#  10  the CALLER COUPLING: `ng:_wrapup_deliver_channel_reply` used to pin
#      `--status answered`, which arm 2 now refuses. Making a field select is a
#      behavioural change that must teach every WRITER in the same commit
#      (#1050), so that coupling is executable here rather than remembered.
#
# ANTI-VACUITY. Every refusal arm asserts BOTH the exit code AND that the
# request did not move — a refusal that consumed the request would be a
# different, worse bug. Every success arm asserts the recorded status. Fixture
# construction is itself asserted. The assertion total is pinned, so an arm that
# silently stopped running is a failure rather than a smaller number nobody reads.
#
# Run: bash monitor/watcher/test-request-reply-skeptic-ledger.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
CHAN="$SRC_ROOT/monitor/request-channel.sh"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[ -x "$CHAN" ] || { echo "missing $CHAN" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/reqsk.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
cleanup(){ [ -n "${WORK:-}" ] && rm -rf -- "$WORK"; }
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"
mkdir -p "$NEXUS_STATE_DIR"
# `resolve` is orchestrator-only and refuses when this is set. The suite drives
# the ORCHESTRATOR side of the channel, so it must be unset — and unsetting it
# explicitly stops an inherited value from turning arm 7 into a false refusal
# that looks exactly like the fail-closed behaviour arm 6 asserts.
unset NEXUS_WORKER_WINDOW

# mkreq <origin> <kind> <slug> -> echoes the request id, left in `claimed`.
# The watcher normally performs new->claimed; the fixture does it directly
# because the verb under test is `reply`, not the claim path.
mkreq(){
  local origin=$1 kind=$2 slug=$3 id
  id=$(bash "$CHAN" file --origin "$origin" --kind "$kind" --slug "$slug" \
        --reply required --message "fixture request body" 2>/dev/null) || return 1
  [ -n "$id" ] || return 1
  mv "$NEXUS_STATE_DIR/requests/$id.new.md" "$NEXUS_STATE_DIR/requests/$id.claimed.md" || return 1
  sed -i 's/^state: new/state: claimed/' "$NEXUS_STATE_DIR/requests/$id.claimed.md" || return 1
  printf '%s' "$id"
}

# state_of <id> -> new|claimed|replied|... or "absent"
state_of(){
  local f
  f=$(find "$NEXUS_STATE_DIR/requests" -maxdepth 1 -name "$1.*.md" 2>/dev/null | head -1)
  [ -n "$f" ] || { printf 'absent'; return; }
  f=${f##*/}; f=${f%.md}; printf '%s' "${f##*.}"
}

# reply_status <id> -> the nested `reply: status:` value from the replied file
reply_status(){
  awk '/^reply:[[:space:]]*$/{r=1;next}
       r==1 && /^  status:[[:space:]]/{sub(/^  status:[[:space:]]*/,"");print;exit}
       r==1 && /^[^[:space:]]/{exit}' \
    "$NEXUS_STATE_DIR/requests/$1.replied.md" 2>/dev/null
}

arm(){ ROUT=$(bash "$CHAN" reply "$@" 2>&1); ARC=$?; return 0; }

marker_for(){ printf '%s/skeptic/pending/%s' "$NEXUS_STATE_DIR" "$1"; }
arm_marker(){ mkdir -p "$NEXUS_STATE_DIR/skeptic/pending"; printf 'armed\n' > "$(marker_for "$1")"; }

# ------------------------------------------------------------------ 1 ------
if id=$(mkreq w1 spawn-skeptic s1); then
  pass "fixture: a spawn-skeptic request was filed and is claimed ($(state_of "$id"))"
  arm "$id" --status maybe --message "a body long enough to be substantive"
  if [ "$ARC" -eq 2 ] && [ "$(state_of "$id")" = "claimed" ]; then
    pass "1: an unrecognised --status is REFUSED (rc 2) and the request is not consumed"
  else
    fail "1: rc=$ARC state=$(state_of "$id") (want rc 2 / claimed). Out: $ROUT"
  fi
else
  fail "fixture 1 could not be built"; fail "1: skipped (fixture)"
fi

# ------------------------------------------------------------------ 2 ------
if id=$(mkreq w2 spawn-skeptic s2); then
  arm "$id" --message "yes that is fine, go ahead with it"
  if [ "$ARC" -eq 6 ] && [ "$(state_of "$id")" = "claimed" ]; then
    pass "2: default 'answered' on a spawn-skeptic request is REFUSED as ambiguous, request unmoved"
  else
    fail "2: rc=$ARC state=$(state_of "$id") (want rc 6 / claimed). Out: $ROUT"
  fi
  case "$ROUT" in
    *"--status declined"*|*"--status spawned"*)
      pass "2: the refusal NAMES the explicit forms, so the caller is not left guessing" ;;
    *) fail "2: refusal does not name the explicit forms: $ROUT" ;;
  esac
else
  fail "fixture 2 could not be built"; fail "2: skipped (fixture)"
fi

# ------------------------------------------------------------------ 3 ------
if id=$(mkreq w3 spawn-skeptic s3); then
  arm "$id" --status spawned --message "a reviewer will be along shortly"
  if [ "$ARC" -eq 6 ] && [ "$(state_of "$id")" = "claimed" ]; then
    pass "3: --status spawned without --worker is REFUSED, request unmoved"
  else
    fail "3: rc=$ARC state=$(state_of "$id") (want rc 6 / claimed). Out: $ROUT"
  fi
else
  fail "fixture 3 could not be built"
fi

# ------------------------------------------------------------------ 4 ------
# The correct DO-NOTHING-HERE case. Asserting the marker SURVIVES is what stops
# arm 7 being satisfied by a fix that clears the gate on every reply.
if id=$(mkreq w4 spawn-skeptic s4); then
  arm_marker w4
  arm "$id" --status spawned --worker w4-sk --message "spawned a reviewer for this delta"
  if [ "$ARC" -eq 0 ] && [ "$(state_of "$id")" = "replied" ] && [ "$(reply_status "$id")" = "spawned" ]; then
    pass "4: a named spawn replies (rc 0) and records status=spawned"
  else
    fail "4: rc=$ARC state=$(state_of "$id") status=$(reply_status "$id") (want 0/replied/spawned). Out: $ROUT"
  fi
  if [ -e "$(marker_for w4)" ]; then
    pass "4: the marker is STILL ARMED — the reviewer's verdict discharges it, not this reply"
  else
    fail "4: the marker was cleared by a SPAWN reply — the gate is being released without a review"
  fi
else
  fail "fixture 4 could not be built"; fail "4: skipped (fixture)"
fi

# ------------------------------------------------------------------ 5 ------
if id=$(mkreq w5 spawn-skeptic s5); then
  arm_marker w5
  arm "$id" --status declined --message "no"
  if [ "$ARC" -eq 6 ] && [ "$(state_of "$id")" = "claimed" ] && [ -e "$(marker_for w5)" ]; then
    pass "5: a DECLINE with a too-short rationale is REFUSED — not padded, nothing consumed"
  else
    fail "5: rc=$ARC state=$(state_of "$id") marker=$([ -e "$(marker_for w5)" ] && echo armed || echo gone) (want 6/claimed/armed). Out: $ROUT"
  fi
else
  fail "fixture 5 could not be built"
fi

# ------------------------------------------------------------------ 6 ------
# ORDERING. No marker => `resolve` fails => the reply must refuse ENTIRELY.
# If this arm ever passes with state=replied, the write order has been inverted
# back to reply-then-resolve and the original defect is live again.
if id=$(mkreq w6 spawn-skeptic s6); then
  arm "$id" --status declined --message "declining: this change is comment-only and carries no behavioural risk"
  if [ "$ARC" -ne 0 ] && [ "$(state_of "$id")" = "claimed" ]; then
    pass "6: a DECLINE whose ledger write fails REFUSES the reply and leaves the request unmoved"
  else
    fail "6: rc=$ARC state=$(state_of "$id") (want nonzero / claimed) — the request was consumed despite an unrecorded decision. Out: $ROUT"
  fi
  case "$ROUT" in
    *"NOT resolved"*|*"Nothing was written"*)
      pass "6: the refusal says the gate was not resolved and that nothing was written" ;;
    *) fail "6: refusal text does not say the ledger write failed: $ROUT" ;;
  esac
else
  fail "fixture 6 could not be built"; fail "6: skipped (fixture)"
fi

# ------------------------------------------------------------------ 7 ------
if id=$(mkreq w7 spawn-skeptic s7); then
  arm_marker w7
  if [ -e "$(marker_for w7)" ]; then
    pass "fixture 7: the skeptic marker is armed before the decline"
  else
    fail "fixture 7: marker could not be armed — arm 7 would prove nothing"
  fi
  arm "$id" --status declined --message "declining: the delta is comment-only and carries no behavioural risk"
  if [ "$ARC" -eq 0 ] && [ "$(state_of "$id")" = "replied" ] && [ "$(reply_status "$id")" = "declined" ]; then
    pass "7: a DECLINE with an armed gate replies (rc 0) and records status=declined"
  else
    fail "7: rc=$ARC state=$(state_of "$id") status=$(reply_status "$id") (want 0/replied/declined). Out: $ROUT"
  fi
  if [ ! -e "$(marker_for w7)" ]; then
    pass "7: the marker was CLEARED — the decision and its record are one act"
  else
    fail "7: the marker survived a DECLINE — retire-window will still refuse as if no review happened"
  fi
  _rat=$(find "$NEXUS_STATE_DIR/skeptic/pending" -name '*w7*cleared-rationale*' 2>/dev/null | head -1)
  if [ -n "$_rat" ] && grep -q -- "$id" "$_rat" 2>/dev/null; then
    pass "7: the audit rationale on the ledger NAMES the request id — the two records agree"
  else
    fail "7: no rationale naming $id was written beside the marker"
  fi
else
  fail "fixture 7 could not be built"; fail "7: skipped"; fail "7: skipped"; fail "7: skipped"
fi

# ------------------------------------------------------------------ 8 ------
if id=$(mkreq w8 spawn-skeptic s8); then
  arm_marker w8
  arm "$id" --status deferred --message "not now: revisit after the base branch settles"
  if [ "$ARC" -eq 0 ] && [ "$(state_of "$id")" = "replied" ] && [ "$(reply_status "$id")" = "deferred" ]; then
    pass "8: --status deferred replies (rc 0) and records status=deferred"
  else
    fail "8: rc=$ARC state=$(state_of "$id") status=$(reply_status "$id") (want 0/replied/deferred). Out: $ROUT"
  fi
  if [ -e "$(marker_for w8)" ]; then
    pass "8: deferred leaves the marker ARMED — 'not now' is not 'no review needed'"
  else
    fail "8: deferred cleared the gate — the distinction the vocabulary exists for is gone"
  fi
else
  fail "fixture 8 could not be built"; fail "8: skipped (fixture)"
fi

# ------------------------------------------------------------------ 9 ------
if id=$(mkreq w9 question s9); then
  arm "$id" --message "the plan is to proceed as written"
  if [ "$ARC" -eq 0 ] && [ "$(state_of "$id")" = "replied" ] && [ "$(reply_status "$id")" = "answered" ]; then
    pass "9: an ordinary (non spawn-skeptic) request replies exactly as before — no regression"
  else
    fail "9: rc=$ARC state=$(state_of "$id") status=$(reply_status "$id") (want 0/replied/answered). Out: $ROUT"
  fi
else
  fail "fixture 9 could not be built"
fi

# ----------------------------------------------------------------- 10 ------
# THE CALLER COUPLING. `monitor/ng:_wrapup_deliver_channel_reply` shells out to
# this verb and used to PIN `--status answered` — which arm 2 now refuses on a
# spawn-skeptic request. Making a field SELECT is a behavioural change that must
# teach every WRITER in the same commit (#1050); this arm is that coupling made
# executable, so the two cannot drift apart silently.
#
# It drives the exact argument vector that function builds for a spawn-skeptic
# request (--file, --status spawned, --worker), and it asserts the `reqfile`
# verb the kind lookup depends on actually resolves.
if id=$(mkreq w10 spawn-skeptic s10); then
  _rf=$(bash "$CHAN" reqfile "$id" 2>/dev/null)
  if [ -n "$_rf" ] && [ -f "$_rf" ]; then
    pass "10: \`reqfile\` resolves the request path — the kind lookup in ng has something to read"
  else
    fail "10: reqfile did not resolve a readable path for $id (got '$_rf')"
  fi
  _k=$(awk -F': *' '/^kind:[[:space:]]/{print $2; exit}' "$_rf" 2>/dev/null)
  if [ "$_k" = "spawn-skeptic" ]; then
    pass "10: the kind is readable from the request frontmatter exactly as ng reads it"
  else
    fail "10: kind read as '$_k' (want spawn-skeptic) — ng's lookup would mis-classify"
  fi
  _bf=$(mktemp "${TMPDIR:-/tmp}/wrapbody.XXXXXX")
  printf 'the reviewer wrapped up and this is its answer\n' > "$_bf"
  arm "$id" --file "$_bf" --status spawned --worker w10
  rm -f "$_bf"
  if [ "$ARC" -eq 0 ] && [ "$(reply_status "$id")" = "spawned" ]; then
    pass "10: the wrap-up caller's spawn-skeptic vector is ACCEPTED by the channel"
  else
    fail "10: the wrap-up caller's vector was rejected (rc=$ARC status=$(reply_status "$id")) — ng wrap-up would fail the requester. Out: $ROUT"
  fi
else
  fail "fixture 10 could not be built"; fail "10: skipped"; fail "10: skipped"
fi

# --- assertion-count guard ------------------------------------------------
#
# This suite exists because a verb returned 0 for work it had not recorded. A
# suite that silently stopped running arms would do the same thing one level up.
# 2+2+1+2+1+2+4+2+1+3 = 20, + this one = 21.
EXPECTED_ASSERTIONS=21
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} + 1 ))
if (( TOTAL_ASSERTIONS == EXPECTED_ASSERTIONS )); then
    pass "assertion total is exactly $EXPECTED_ASSERTIONS — no arm was silently skipped"
else
    fail "assertion total $TOTAL_ASSERTIONS != expected $EXPECTED_ASSERTIONS — an arm ran short or was skipped"
fi

th_summary_and_exit
