#!/usr/bin/env bash
# Tests for monitor/watcher/_requests.sh — the WATCHER side of the request
# inbox (agent-channel RFC Part B §2.4, §2.6).
#
# Covers:
#   1.  disabled (default): requests_poll_emit is a strict no-op — no
#       claim, no emit (a fresh clone ships inert)
#   2.  claim: enabled → .new → .claimed (atomic); emit line shape
#       (request=/origin/kind/priority + summary + file=.claimed.md)
#   3.  malformed (no `request:` frontmatter) → .failed, not claimed
#   4.  re-emit cooldown is a DELIVERY property (stamp-on-paste,
#       your-org/nexus-code#483): an UNDELIVERED render leaves no stamp
#       and the request re-emits next poll; after a simulated successful
#       paste (requests_commit_emitted) the cooldown holds; once it
#       elapses the request re-emits (resurface-until-ack)
#   5.  ack self-clears: a claimed file the orchestrator renamed to .done
#       no longer emits (no double-processing) — emission stops next poll
#   6.  per-emit cap: more claimed than the cap → only `cap` emit; after
#       each DELIVERY the next poll surfaces the next leftovers — none
#       lost, drained at the cap-per-delivered-paste rate
#   7.  fairness: round-robin across origins (one chatty origin can't starve)
#   8.  max-age: a .claimed older than max_age → .failed (+ stops emitting)
#   9.  GC: terminal .done/.failed past retention → removed, with the
#       per-request reply dir and .ids marker; .replied is terminal too
#       and GC'd on its OWN retention knob
#       (MONITOR_REQUESTS_REPLIED_RETENTION_SECONDS, default = general
#       retention) — within it a .replied is retained while a same-age
#       .done is collected
#   10. backlog: no request is lost or double-processed across many polls
#
# Run: bash monitor/watcher/test-requests-inbox.sh
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
assert_file() {
    local label="$1" f="$2"
    if [[ -f "$f" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — no file %q\n' "$label" "$f" >&2; FAIL=$((FAIL+1)); fi
}
assert_no_file() {
    local label="$1" f="$2"
    if [[ ! -e "$f" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — file still present %q\n' "$label" "$f" >&2; FAIL=$((FAIL+1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export NEXUS_STATE_DIR="$WORK/state"
export STATE_DIR="$NEXUS_STATE_DIR"
# Pin the services registry to a hermetic path (absent by default) so the
# remote-channel coupling in _requests_enabled cannot read a developer's real
# registry and flip the disabled-path tests. Tests that exercise the coupling
# write this file explicitly.
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
mkdir -p "$NEXUS_STATE_DIR"
REQ="$NEXUS_STATE_DIR/requests"

# Source the watcher module under test (defines requests_poll_emit etc.).
# shellcheck source=_requests.sh
source "$_test_dir/_requests.sh"

_file() { "$RC" file "$@"; }   # producer side

# Simulate the watcher's SUCCESSFUL-PASTE path for a render output: wrap
# it in the `--- requests ---` section header exactly as compose_report
# does, then commit the delivery stamps (what main.sh runs right after
# paste_with_retry succeeds). Renders that are never "pasted" through
# this helper must leave no cooldown stamp (stamp-on-paste, `#483`).
_deliver() {
    local rendered="$1" body="$WORK/pasted-body.$$"
    printf -- '--- requests ---\n%s--- nexus-emit-sig 2026 x ---\n' "$rendered" > "$body"
    requests_commit_emitted "$body"
    rm -f "$body"
}

echo "== 1. disabled is a strict no-op =="
export MONITOR_REQUESTS_ENABLED=false
id=$(_file --origin w --kind question --slug off --message "while disabled")
out=$(requests_poll_emit)
assert_eq   "disabled → empty emit" "$out" ""
assert_file "disabled → file stays .new" "$REQ/$id.new.md"

echo "== 2. claim + emit line shape =="
export MONITOR_REQUESTS_ENABLED=true
export MONITOR_REQUESTS_MAX_PER_EMIT=10 MONITOR_REQUESTS_FAIRNESS=true
out=$(requests_poll_emit)
assert_file     "claimed: .new → .claimed" "$REQ/$id.claimed.md"
assert_no_file  "claimed: .new gone"        "$REQ/$id.new.md"
assert_contains "emit: request= id"   "$out" "request=$id"
assert_contains "emit: origin"        "$out" "origin=w"
assert_contains "emit: summary"       "$out" "summary: while disabled"
assert_contains "emit: cites .claimed file" "$out" "$REQ/$id.claimed.md"

echo "== 3. malformed → .failed, not claimed =="
printf 'not even frontmatter\n' > "$REQ/20260629T000000Z-w-bad.new.md"
requests_poll_emit >/dev/null
assert_file    "malformed → .failed.md" "$REQ/20260629T000000Z-w-bad.failed.md"
assert_no_file "malformed not claimed"  "$REQ/20260629T000000Z-w-bad.claimed.md"

echo "== 4. re-emit cooldown is a delivery property (stamp-on-paste) =="
export MONITOR_REQUESTS_REEMIT_COOLDOWN_SECONDS=300
state="$NEXUS_STATE_DIR/requests-emit-state.tsv"
# id was RENDERED in step 2 but never delivered. Render must not have
# stamped it (the stamp is a delivery record, `#483`), so it is still due.
if [[ -s "$state" ]] && grep -q "^$id" "$state"; then
    printf '  FAIL: render stamped the cooldown before any delivery\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: undelivered render leaves no cooldown stamp\n'; PASS=$((PASS+1))
fi
out=$(requests_poll_emit)
assert_contains "undelivered → re-emits on the very next poll" "$out" "request=$id"
# Deliver it (simulated successful paste) → the cooldown now holds.
_deliver "$out"
out=$(requests_poll_emit)
assert_not_contains "delivered → within cooldown no re-emit" "$out" "request=$id"
# Simulate the cooldown elapsing: backdate its stamp in the TSV.
now=$(date +%s); old=$((now - 600))
awk -v id="$id" -v old="$old" 'BEGIN{FS=OFS="\t"} $1==id{$2=old} {print}' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
out=$(requests_poll_emit)
assert_contains "after cooldown → re-emits" "$out" "request=$id"

echo "== 5. ack self-clears (no double-process) =="
"$RC" ack "$id" >/dev/null
assert_file "acked → .done.md" "$REQ/$id.done.md"
out=$(requests_poll_emit)
assert_not_contains "acked request no longer emits" "$out" "request=$id"

echo "== 6. per-emit cap + leftovers surface next poll (none lost) =="
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
export MONITOR_REQUESTS_MAX_PER_EMIT=2 MONITOR_REQUESTS_FAIRNESS=false
declare -A want_ids=()
for i in 1 2 3 4 5; do
    cid=$(CHAN_TS_OVERRIDE=$(printf '20260629T0000%02dZ' "$i") _file --origin solo --kind question --slug "c$i" --message "ask $i")
    want_ids["$cid"]=1
done
# poll 1: claim all 5, emit 2. An UNDELIVERED cap set must stay due (the
# same 2 re-render until a paste lands — nothing was delivered, so
# nothing rotates).
out1=$(requests_poll_emit)
n1=$(grep -c '^request=' <<<"$out1")
assert_eq "poll1 emits exactly cap (2)" "$n1" "2"
out1b=$(requests_poll_emit)
assert_eq "undelivered cap set re-renders identically" "$out1b" "$out1"
# Deliver poll 1 → poll 2 rotates to the next 2 leftovers.
_deliver "$out1"
out2=$(requests_poll_emit)
n2=$(grep -c '^request=' <<<"$out2")
assert_eq "poll2 (after delivery) emits next 2 leftovers" "$n2" "2"
_deliver "$out2"
out3=$(requests_poll_emit)
n3=$(grep -c '^request=' <<<"$out3")
assert_eq "poll3 (after delivery) emits final leftover (1)" "$n3" "1"
_deliver "$out3"
# union of all emitted ids == all filed ids (none lost, none duplicated)
emitted=$(printf '%s\n%s\n%s\n' "$out1" "$out2" "$out3" | sed -n 's/^request=\([^ ]*\).*/\1/p' | sort)
uniq_n=$(printf '%s\n' "$emitted" | sort -u | wc -l)
total_n=$(printf '%s\n' "$emitted" | wc -l)
assert_eq "no duplicates across polls" "$uniq_n" "$total_n"
assert_eq "all 5 surfaced exactly once" "$uniq_n" "5"

echo "== 7. fairness round-robin across origins =="
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
export MONITOR_REQUESTS_MAX_PER_EMIT=2 MONITOR_REQUESTS_FAIRNESS=true
# alice files 3 (older ts), bob files 1 (newer ts). Strict-FIFO would emit
# 2 alice; fairness must interleave → 1 alice + 1 bob in the cap-2 emit.
for i in 1 2 3; do CHAN_TS_OVERRIDE=$(printf '20260629T0000%02dZ' "$i") _file --origin alice --kind question --slug "a$i" --message "alice $i" >/dev/null; done
CHAN_TS_OVERRIDE=20260629T000010Z _file --origin bob --kind question --slug b1 --message "bob 1" >/dev/null
out=$(requests_poll_emit)
na=$(grep -c 'origin=alice' <<<"$out"); nb=$(grep -c 'origin=bob' <<<"$out")
assert_eq "fairness: 1 alice in cap-2 emit" "$na" "1"
assert_eq "fairness: 1 bob in cap-2 emit"   "$nb" "1"

echo "== 8. max-age → .failed =="
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
export MONITOR_REQUESTS_MAX_PER_EMIT=10 MONITOR_REQUESTS_MAX_AGE_SECONDS=60
mid=$(_file --origin w --kind question --slug stale --message "old")
mv "$REQ/$mid.new.md" "$REQ/$mid.claimed.md"
touch -d '10 minutes ago' "$REQ/$mid.claimed.md"
requests_poll_emit >/dev/null
assert_file    "max-age → .failed.md" "$REQ/$mid.failed.md"
assert_no_file "max-age: .claimed gone" "$REQ/$mid.claimed.md"

echo "== 9. GC terminal files + reply dir + .ids marker =="
export MONITOR_REQUESTS_RETENTION_SECONDS=60
gid=$(_file --origin w --kind question --slug gc --message "to gc")
mv "$REQ/$gid.new.md" "$REQ/$gid.done.md"
touch -d '10 minutes ago' "$REQ/$gid.done.md"
[[ -d "$REQ/.ids/$gid" ]] && { echo "  PASS: pre-GC: .ids marker exists"; PASS=$((PASS+1)); } || { echo "  FAIL: pre-GC: .ids marker missing" >&2; FAIL=$((FAIL+1)); }
requests_poll_emit >/dev/null
assert_no_file "GC: .done removed"      "$REQ/$gid.done.md"
assert_no_file "GC: reply dir removed"  "$REQ/replies/$gid"
assert_no_file "GC: .ids marker removed" "$REQ/.ids/$gid"

# 9a. .replied past retention → removed with reply dir + .ids marker (the
# terminal-state accretion gap: replied requests used to pile up forever).
# The knob is UNSET here, so this also pins its default (= general
# retention, still 60s from above).
rid=$(_file --origin w --kind question --slug gc-replied --message "replied, old")
mv "$REQ/$rid.new.md" "$REQ/$rid.replied.md"
mkdir -p "$REQ/replies/$rid"
printf 'the reply\n' > "$REQ/replies/$rid/results.md"
printf 'progress\n'  > "$REQ/replies/$rid/progress.md"
touch -d '10 minutes ago' "$REQ/$rid.replied.md"
requests_poll_emit >/dev/null
assert_no_file "replied-GC: .replied removed (default = general retention)" "$REQ/$rid.replied.md"
assert_no_file "replied-GC: reply dir removed"   "$REQ/replies/$rid"
assert_no_file "replied-GC: .ids marker removed" "$REQ/.ids/$rid"

# 9b. the separate knob: a .replied WITHIN its own (longer) retention is
# RETAINED — reply content intact for a slow-fetching client — while a
# same-age .done is collected on the general retention in the same pass.
export MONITOR_REQUESTS_REPLIED_RETENTION_SECONDS=3600
kid=$(_file --origin w --kind question --slug keep-replied --message "replied, kept")
mv "$REQ/$kid.new.md" "$REQ/$kid.replied.md"
mkdir -p "$REQ/replies/$kid"
printf 'kept reply\n' > "$REQ/replies/$kid/results.md"
touch -d '10 minutes ago' "$REQ/$kid.replied.md"
did=$(_file --origin w --kind question --slug gone-done --message "done, old")
mv "$REQ/$did.new.md" "$REQ/$did.done.md"
touch -d '10 minutes ago' "$REQ/$did.done.md"
requests_poll_emit >/dev/null
assert_file    "replied-GC: .replied within its own retention retained" "$REQ/$kid.replied.md"
assert_file    "replied-GC: retained reply content intact" "$REQ/replies/$kid/results.md"
assert_no_file "replied-GC: same-age .done still GC'd on the general retention" "$REQ/$did.done.md"
unset MONITOR_REQUESTS_REPLIED_RETENTION_SECONDS

echo "== 10. TSV field-injection hardening (skeptic #378 nit) =="
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$REQ"
export MONITOR_REQUESTS_MAX_PER_EMIT=10 MONITOR_REQUESTS_FAIRNESS=false
# A hand-planted .claimed.md with a literal TAB in `origin` must not shift
# the TSV columns / scramble the request= attribution (it is sanitized to
# a space). Unreachable via the validated `ng request file` verb, but a
# direct-write / future producer is hardened against.
inj_id="20260629T000000Z-inj-tabtest"
printf -- '---\nrequest: %s\norigin: a\tb\nkind: question\npriority: normal\nstate: claimed\n---\n\n## Request\n\nsummary line\n' "$inj_id" \
    > "$REQ/$inj_id.claimed.md"
out=$(requests_poll_emit)
assert_contains "injected origin still emits the right id" "$out" "request=$inj_id"
assert_contains "tab in origin sanitized to space (no column shift)" "$out" "origin=a b kind=question"

echo "== 11. remote-channel coupling: registered channel enables the inbox =="
# The bug: remote-up.sh enables the SSH transport but NOT this inbox, so a
# remote client's requests rot as .new (the master switch defaults off).
# _requests_enabled must treat a registered `nexus-remote-ssh` row as an
# enable signal — so the inbox drains even with MONITOR_REQUESTS_ENABLED
# unset/false. (Verified live: 4 client requests stuck .new until replied by
# hand.)
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
export MONITOR_REQUESTS_MAX_PER_EMIT=10 MONITOR_REQUESTS_FAIRNESS=true
unset MONITOR_REQUESTS_ENABLED   # explicit flag OFF (fresh-clone default)
# No registry yet → still inert.
rm -f "$NEXUS_SERVICES_REGISTRY"
rid=$(_file --origin remote-operator --kind question --slug coupled --message "from a remote client")
out=$(requests_poll_emit)
assert_eq   "flag off + no channel → still inert" "$out" ""
assert_file "flag off + no channel → stays .new"  "$REQ/$rid.new.md"
# Register the remote channel → the inbox must now claim + emit.
printf 'nexus-remote-ssh\t/n\tlaunch\thealth\tlog\temit-only\n' > "$NEXUS_SERVICES_REGISTRY"
out=$(requests_poll_emit)
assert_file     "channel registered → .new claimed" "$REQ/$rid.claimed.md"
assert_contains "channel registered → emits the request" "$out" "request=$rid"
assert_contains "coupled emit carries the remote origin" "$out" "origin=remote-operator"
# A registry WITHOUT the remote row does not enable it (only the right row).
rm -rf "$NEXUS_STATE_DIR"; mkdir -p "$NEXUS_STATE_DIR"
printf 'some-other-service\t/n\tlaunch\thealth\tlog\temit-only\n' > "$NEXUS_SERVICES_REGISTRY"
oid=$(_file --origin remote-x --kind question --slug other --message "still off")
out=$(requests_poll_emit)
assert_eq   "unrelated registry row → still inert" "$out" ""
assert_file "unrelated registry row → stays .new"  "$REQ/$oid.new.md"

echo
if (( FAIL == 0 )); then echo "ALL TESTS PASSED ($PASS)"; exit 0
else echo "SOME TESTS FAILED ($FAIL failed, $PASS passed)" >&2; exit 1; fi
