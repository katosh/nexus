#!/usr/bin/env bash
# Tests for the stamp-on-paste delivery discipline of the request inbox
# (your-org/nexus-code#483): the re-emit cooldown is a DELIVERY record,
# committed only on the watcher's successful-paste path, and
# request-bearing emit bodies bypass the content-hash dedup suppress the
# way eligible github comments already do.
#
# The incident class under test (live occurrence 2026-07-02T01:44:10,
# recurred 2026-07-09 with a `reply: required` remote request):
# `requests_render` stamped the anti-spam cooldown at RENDER time while
# delivery was gated three steps downstream (emit-dedup suppress →
# over-limit pause → paste_with_retry), so a request could be recorded
# as surfaced and never reach the orchestrator, then age silently
# inside its own cooldown while the remote client waited on a reply no
# one had been told to write.
#
# Covers:
#   1. render-without-delivery: a rendered request leaves NO cooldown
#      stamp and re-emits on the next poll (the failed/suppressed-paste
#      path — on pre-#483 code the render itself stamped, so this FAILS
#      there)
#   2. requests_commit_emitted: stamps exactly the ids inside the pasted
#      body's `--- requests ---` section — at delivery time, holding the
#      cooldown afterwards; `request=` text in OTHER sections is ignored
#   3. dedup bypass: an emit body carrying a `request=` row is NEVER
#      hash-suppressed, even as an identical-hash repeat within the
#      quiet window (two byte-identical request bodies both surface —
#      FAILS on pre-#483 code, where the second was suppressed); the
#      bypass is bounded at the source (delivered ids leave the due set
#      for a full cooldown, so a pasted body silences its own re-render)
#   4. no-regression guard: a NON-request body is still hash-suppressed
#      within the quiet window (passes before and after #483 — pinned so
#      the bypass can never widen to everything)
#
# Run: bash monitor/watcher/test-requests-delivery-stamp.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_monitor_dir=$(cd "$_test_dir/.." && pwd)
RC="$_monitor_dir/request-channel.sh"

PASS=0; FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}
assert_rc() {
    local label="$1" want_rc="$2" got_rc="$3"
    if [[ "$got_rc" == "$want_rc" ]]; then printf '  PASS: %s (rc=%s)\n' "$label" "$got_rc"; PASS=$((PASS+1))
    else printf '  FAIL: %s — got rc=%s want rc=%s\n' "$label" "$got_rc" "$want_rc" >&2; FAIL=$((FAIL+1)); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — missing %q\n    in: <<%s>>\n' "$label" "$needle" "$hay" >&2; FAIL=$((FAIL+1)); fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2; FAIL=$((FAIL+1))
    else printf '  PASS: %s\n' "$label"; PASS=$((PASS+1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/state"
export STATE_DIR="$NEXUS_STATE_DIR"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
mkdir -p "$NEXUS_STATE_DIR"
REQ="$NEXUS_STATE_DIR/requests"
STATE_TSV="$NEXUS_STATE_DIR/requests-emit-state.tsv"

# The dedup gate's caller globals (normally set by main.sh).
export EMIT_DEDUP_HASH_FILE="$STATE_DIR/last-emit-stable-hash"
export EMIT_DEDUP_TS_FILE="$STATE_DIR/last-emit-stable-ts"
export EMIT_DEDUP_RING_FILE="$STATE_DIR/last-emit-stable-hash.ring"
LOGFILE="$WORK/watcher.log"
log() { printf '%s\n' "$*" >> "$LOGFILE"; }

# shellcheck source=_requests.sh
source "$_test_dir/_requests.sh"
# shellcheck source=_emit_dedup.sh
source "$_test_dir/_emit_dedup.sh"

export MONITOR_REQUESTS_ENABLED=true
export MONITOR_REQUESTS_MAX_PER_EMIT=10 MONITOR_REQUESTS_FAIRNESS=true
export MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS=300
export MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS=86400

_file() { "$RC" file "$@"; }

# Wrap a render output exactly as compose_report does before pasting.
_as_pasted_body() {
    local rendered="$1" out_file="$2"
    {
        printf -- '=== nexus state changed at 2026-07-09T00:00:00Z (poll-requests) ===\n'
        printf -- '--- requests ---\n'
        printf '%s' "$rendered"
        printf -- '--- nexus-emit-sig 2026-07-09T00:00:00Z abc123 ---\n'
    } > "$out_file"
}

echo "== 1. render without delivery: no stamp, re-emits next poll =="
id=$(_file --origin remote-cli --kind question --slug ask1 --reply required --message "please answer")
out=$(requests_poll_emit)
assert_contains "request renders" "$out" "request=$id"
# THE defect: on pre-#483 code the render wrote a cooldown row here even
# though nothing was pasted (dedup-suppressed / over-limit / paste-fail
# all live downstream of render).
if [[ -s "$STATE_TSV" ]] && grep -q "^$id" "$STATE_TSV"; then
    printf '  FAIL: cooldown stamped at render time (delivery never happened)\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: no cooldown stamp without a delivered paste\n'; PASS=$((PASS+1))
fi
out2=$(requests_poll_emit)
assert_contains "undelivered request re-emits on the next poll" "$out2" "request=$id"

echo "== 2. commit-on-paste stamps exactly the delivered ids =="
body="$WORK/body1"
_as_pasted_body "$out2" "$body"
requests_commit_emitted "$body"
if grep -q "^$id" "$STATE_TSV" 2>/dev/null; then
    printf '  PASS: delivered id stamped by requests_commit_emitted\n'; PASS=$((PASS+1))
else
    printf '  FAIL: delivered id missing from the emit-state TSV\n' >&2; FAIL=$((FAIL+1))
fi
out3=$(requests_poll_emit)
assert_not_contains "delivered → cooldown holds on the next poll" "$out3" "request=$id"
# `request=` text OUTSIDE the `--- requests ---` section must not stamp.
decoy="$WORK/body-decoy"
{
    printf -- '=== nexus state changed at 2026-07-09T00:00:00Z (poll) ===\n'
    printf -- '--- workspace snapshot ---\n'
    printf 'request=20990101T000000Z-x-decoy origin=x kind=question priority=\n'
    printf -- '--- nexus-emit-sig 2026-07-09T00:00:00Z def456 ---\n'
} > "$decoy"
requests_commit_emitted "$decoy"
if grep -q "decoy" "$STATE_TSV" 2>/dev/null; then
    printf '  FAIL: request= text outside the requests section was stamped\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: request= text outside the requests section is ignored\n'; PASS=$((PASS+1))
fi

echo "== 3. dedup bypass: identical request bodies BOTH surface =="
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE"
rc=0; _compose_emit_should_suppress "$body" poll-requests || rc=$?
assert_rc "first request body: not suppressed" 1 "$rc"
_compose_emit_record_emit "$body"
# The SAME body again, inside the quiet window — the 2026-07-02 incident
# shape. Pre-#483: suppressed (rc=0), i.e. recorded-surfaced-never-
# delivered. Post: the request row bypasses the hash gate.
rc=0; _compose_emit_should_suppress "$body" poll-requests || rc=$?
assert_rc "identical request body within quiet window: NOT suppressed (bypass)" 1 "$rc"
# Boundedness of the bypass: delivery stamped the id (step 2), so the
# SOURCE stops re-rendering it for a full cooldown — the bypass cannot
# fire again until the request is due again. (The gate stays open only
# for bodies the source actually re-issues.)
out4=$(requests_poll_emit)
assert_eq "bypass is source-bounded: nothing due within cooldown → empty render" "$out4" ""

echo "== 4. guard: non-request bodies are still hash-suppressed =="
plain="$WORK/body-plain"
{
    printf -- '=== nexus state changed at 2026-07-09T00:00:00Z (poll) ===\n'
    printf -- '--- workspace snapshot ---\n'
    printf 'windows: 3 workers idle\n'
    printf -- '--- nexus-emit-sig 2026-07-09T00:00:00Z aaa111 ---\n'
} > "$plain"
rc=0; _compose_emit_should_suppress "$plain" poll || rc=$?
assert_rc "first plain body: not suppressed" 1 "$rc"
_compose_emit_record_emit "$plain"
rc=0; _compose_emit_should_suppress "$plain" poll || rc=$?
assert_rc "identical plain body within quiet window: suppressed" 0 "$rc"

echo "== 5. THE incident class: stage-overwrite race (skeptic on #483) =="
# The true mechanism of the 2026-07-09 `reply: required` loss (52 min
# blind, skeptic attack 2b): requests_poll fires every 10s and
# unconditionally overwrites its stage file; compose_emit reads it every
# 60s. Pre-#483, fire 1 rendered AND stamped, so fire 2 (≤10s later)
# rendered EMPTY and overwrote the stage — the request was visible to
# compose for one ~10s window per 300s cooldown (~30 min mean time to
# surface). Under stamp-on-paste the due set re-renders every fire until
# a paste succeeds, so the stage stays non-empty and the request appears
# in the very next compose body. This test emulates the exact scheduler
# sequence: poll fire → poll fire → compose read.
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
stage="$WORK/requests_poll.out"
rid=$(_file --origin remote-cli --kind question --slug raced --reply required --message "filed between fires")
requests_poll_emit > "$stage"          # poll fire 1 (claims + renders)
requests_poll_emit > "$stage"          # poll fire 2, ≤10s later — the overwrite
compose_view=$(cat "$stage")           # compose_emit's read (main.sh:3553)
assert_contains "request survives the next poll's stage overwrite → visible to compose" \
    "$compose_view" "request=$rid"

echo "== 6. re-nag budget: backoff doubles per DELIVERED emit, capped =="
assert_eq "count 0 (never delivered) → base"  "$(_requests_effective_cooldown 300 0)"  "300"
assert_eq "count 1 → base"                    "$(_requests_effective_cooldown 300 1)"  "300"
assert_eq "count 2 → 2x"                      "$(_requests_effective_cooldown 300 2)"  "600"
assert_eq "count 3 → 4x"                      "$(_requests_effective_cooldown 300 3)"  "1200"
assert_eq "count 10 → capped at backoff max"  "$(_requests_effective_cooldown 300 10)" "3600"
assert_eq "cap never below base"              "$(_requests_effective_cooldown 7200 5)" "7200"
# End-to-end: deliver twice → effective cooldown 600s; a 400s-old stamp
# (past base, short of 2x) must NOT be due; a 700s-old one must be.
bid=$(_file --origin w --kind question --slug backoff --message "stalls unacked")
out=$(requests_poll_emit)
_as_pasted_body "$out" "$body"; requests_commit_emitted "$body"   # delivery 1
awk 'BEGIN{FS=OFS="\t"} {$2=$2-400} {print}' "$STATE_TSV" > "$STATE_TSV.t" && mv "$STATE_TSV.t" "$STATE_TSV"
out=$(requests_poll_emit)
assert_contains "delivery 1 + 400s → due (base 300s)" "$out" "request=$bid"
_as_pasted_body "$out" "$body"; requests_commit_emitted "$body"   # delivery 2
awk 'BEGIN{FS=OFS="\t"} {$2=$2-400} {print}' "$STATE_TSV" > "$STATE_TSV.t" && mv "$STATE_TSV.t" "$STATE_TSV"
out=$(requests_poll_emit)
assert_not_contains "delivery 2 + 400s → NOT due (backoff 600s)" "$out" "request=$bid"
awk 'BEGIN{FS=OFS="\t"} {$2=$2-300} {print}' "$STATE_TSV" > "$STATE_TSV.t" && mv "$STATE_TSV.t" "$STATE_TSV"
out=$(requests_poll_emit)
assert_contains "delivery 2 + 700s → due again" "$out" "request=$bid"

echo "== 7. legacy 2-column TSV rows migrate (count defaults to 1) =="
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
lid=$(_file --origin w --kind question --slug legacy --message "pre-#483 stamp")
requests_poll_emit >/dev/null      # claim
old=$(( $(date +%s) - 600 ))
printf '%s\t%s\n' "$lid" "$old" > "$STATE_TSV"    # legacy 2-col row, 600s old
out=$(requests_poll_emit)
assert_contains "legacy row past base cooldown → due (no parse error)" "$out" "request=$lid"
_as_pasted_body "$out" "$body"; requests_commit_emitted "$body"
if awk -F'\t' -v id="$lid" '$1==id && $3==2 {found=1} END{exit !found}' "$STATE_TSV"; then
    printf '  PASS: legacy row upgraded to 3 columns (count=2 after this delivery)\n'; PASS=$((PASS+1))
else
    printf '  FAIL: legacy row not upgraded — TSV: %s\n' "$(cat "$STATE_TSV")" >&2; FAIL=$((FAIL+1))
fi

echo "== 8. empty-field defense: no TSV column collapse (skeptic attack 6) =="
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$REQ"
# Hand-planted direct-write: NO `## Request` heading (summary renders
# empty) and NO origin. Tab is IFS whitespace, so pre-fix the empty
# fields collapsed and shifted every column right: `summary:` showed the
# file path and `file=` rendered blank.
eid="20260709T000000Z-x-emptyfields"
printf -- '---\nrequest: %s\nkind: question\npriority: normal\nstate: claimed\n---\n\nno heading here\n' "$eid" \
    > "$REQ/$eid.claimed.md"
out=$(requests_poll_emit)
assert_contains "id lands in the request= slot (no shift)" "$out" "request=$eid"
assert_contains "empty origin placeholders (no shift)"     "$out" "origin=unknown"
assert_contains "file= carries the real path"              "$out" "file=$REQ/$eid.claimed.md"
assert_not_contains "summary slot does not swallow the path" "$out" "summary: $REQ"

echo "== 9. rescue re-paste stamps deliveries; failed rescue does not (skeptic C1) =="
# The orchestrator-liveness one-shot re-paste delivers the newest emit
# archive — possibly a body the dedup gate suppressed, making the rescue
# that body's FIRST delivery. Its success branch must stamp; its failure
# branch must not. Collaborators are stubbed exactly as production
# resolves them (call-time, from the sourcing shell).
# shellcheck source=_orchestrator_liveness.sh
source "$_test_dir/_orchestrator_liveness.sh"
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
DIFFS="$WORK/diffs"; mkdir -p "$DIFFS"
rrid=$(_file --origin w --kind question --slug rescue --reply required --message "rescue me")
out=$(requests_poll_emit)
_as_pasted_body "$out" "$DIFFS/archive.md"
_newest_emit_archive() { printf '%s' "$DIFFS/archive.md"; }
paste_with_retry() { return 0; }   # rescue paste SUCCEEDS
_orch_resubmit_rescue orch "$DIFFS" "$WORK/resubmit-marker" "resubmit(test)"
if grep -q "^$rrid" "$STATE_TSV" 2>/dev/null; then
    printf '  PASS: successful rescue paste delivery-stamps the request\n'; PASS=$((PASS+1))
else
    printf '  FAIL: successful rescue paste left no delivery stamp\n' >&2; FAIL=$((FAIL+1))
fi
out=$(requests_poll_emit)
assert_not_contains "post-rescue cooldown holds" "$out" "request=$rrid"
# Delivered-id set is exactly the archived body's request rows — no
# extra rows minted, count = 1 after one rescue.
assert_eq "delivered-id set after rescue 1 is exactly {id} with count 1" \
    "$(cat "$STATE_TSV")" "$rrid	$(awk -F'\t' -v id="$rrid" '$1==id{print $2}' "$STATE_TSV")	1"
# A SECOND rescue re-pastes the same archive (that is its job) but must
# not mint new delivered ids — same single row, count advances to 2,
# and the request still does not re-render (backoff extends).
_orch_resubmit_rescue orch "$DIFFS" "$WORK/resubmit-marker" "resubmit(test-2)"
n_rows=$(grep -c . "$STATE_TSV" 2>/dev/null)
assert_eq "second rescue: still exactly one delivered id" "$n_rows" "1"
if awk -F'\t' -v id="$rrid" '$1==id && $3==2 {found=1} END{exit !found}' "$STATE_TSV"; then
    printf '  PASS: second rescue advances the delivered count to 2\n'; PASS=$((PASS+1))
else
    printf '  FAIL: second rescue count wrong — TSV: %s\n' "$(cat "$STATE_TSV")" >&2; FAIL=$((FAIL+1))
fi
out=$(requests_poll_emit)
assert_not_contains "second rescue does not re-deliver via the render path" "$out" "request=$rrid"
# Failure branch: a fresh request whose rescue paste FAILS must stay due.
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
frid=$(_file --origin w --kind question --slug rescue-fail --message "paste dies")
out=$(requests_poll_emit)
_as_pasted_body "$out" "$DIFFS/archive.md"
paste_with_retry() { return 4; }   # rescue paste FAILS
_orch_resubmit_rescue orch "$DIFFS" "$WORK/resubmit-marker" "resubmit(test)"
if grep -q "^$frid" "$STATE_TSV" 2>/dev/null; then
    printf '  FAIL: failed rescue paste wrote a delivery stamp\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: failed rescue paste leaves no stamp\n'; PASS=$((PASS+1))
fi
out=$(requests_poll_emit)
assert_contains "request still due after failed rescue" "$out" "request=$frid"

echo "== 10. respawn resets delivery state: fresh orchestrator sees the live set (skeptic C2) =="
# A delivery stamp records a paste into a SPECIFIC session. After that
# session is replaced, a stamped-but-unread reply-required request must
# not sit invisible inside its (backed-off) cooldown — the respawn paths
# call requests_reset_delivery_state, making everything claimed due now.
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
prid=$(_file --origin w --kind question --slug pre-respawn --reply required --message "unread at death")
out=$(requests_poll_emit)
_as_pasted_body "$out" "$body"; requests_commit_emitted "$body"   # delivered to the doomed session
out=$(requests_poll_emit)
assert_not_contains "delivered → suppressed for the old session" "$out" "request=$prid"
requests_reset_delivery_state                                     # what respawn_agent / fresh-spawn run
out=$(requests_poll_emit)
assert_contains "after respawn reset → immediately due for the fresh session" "$out" "request=$prid"

echo
if (( FAIL == 0 )); then echo "ALL TESTS PASSED ($PASS)"; exit 0
else echo "SOME TESTS FAILED ($FAIL failed, $PASS passed)" >&2; exit 1; fi
