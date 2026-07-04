#!/usr/bin/env bash
# Tests for the content-hash dedup gate that suppresses identical-state
# emit bodies at the watcher's compose_emit -> paste_to_target seam.
#
# Surfaces under test (extracted from main.sh):
#   1. _compose_emit_stable_hash <body_file>
#        Produces a sha256 hex digest of the emit body with timestamp
#        components stripped: the `=== nexus state changed at <iso>
#        (<reason>) ===` header collapses to `=== state (<reason>) ===`,
#        the dashboard `last updated: ...` row is dropped, per-window
#        `idle Ns` / `idle Nh NNm` / `idle-too-long` ages collapse,
#        the `N awaiting-input` prelude scalar collapses to
#        `awaiting-input` (issue #152 — the volatile delta that
#        toggles 1↔0 every cycle a worker re-pings), and the trailing
#        `--- nexus-emit-sig <iso> <nonce> ---` footer is dropped.
#   2. _compose_emit_should_bypass_dedup <body_file>
#        Returns 0 (bypass) ONLY if the body carries an eligible
#        github comment id under `--- eligible github comments ---`.
#        Pending-decisions and awaiting-input no longer bypass
#        (issue #152): they are carried into / normalized out of the
#        stable hash instead, so an identical re-fire suppresses while
#        a genuinely new decision still surfaces. Returns 1 otherwise.
#   3. _compose_emit_apply_dedup <body_file> [reason]
#        Reads MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS, computes
#        new_hash, compares with $STATE_DIR/last-emit-stable-hash
#        and the mtime-equivalent stamp at last-emit-stable-ts. On a
#        match within the quiet window, suppresses (rc=1) and logs.
#        Otherwise emits (rc=0) and atomically writes both state files.
#
# Run: bash monitor/watcher/test-emit-dedup.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         got:  %q\n' "$got" >&2
        printf '         want: %q\n' "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_ne() {
    local label="$1" a="$2" b="$3"
    if [[ "$a" != "$b" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — values unexpectedly equal: %q\n' "$label" "$a" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_rc() {
    local label="$1" want_rc="$2" got_rc="$3"
    if [[ "$got_rc" == "$want_rc" ]]; then
        printf '  PASS: %s (rc=%s)\n' "$label" "$got_rc"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got rc=%s want rc=%s\n' "$label" "$got_rc" "$want_rc" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
export STATE_DIR

LOGFILE="$WORK/watcher.log"
export LOGFILE

# main.sh defines these paths next to FULL_STATE_CANONICAL_CACHE; the
# helpers reference them by name. Mirror the same scheme here so we
# can use the real, unmodified function bodies.
EMIT_DEDUP_HASH_FILE="$STATE_DIR/last-emit-stable-hash"
EMIT_DEDUP_TS_FILE="$STATE_DIR/last-emit-stable-ts"
EMIT_DEDUP_RING_FILE="$STATE_DIR/last-emit-stable-hash.ring"
export EMIT_DEDUP_HASH_FILE EMIT_DEDUP_TS_FILE EMIT_DEDUP_RING_FILE

# main.sh's compose_report renders decision-file paths as
# "$NEXUS_ROOT/monitor/.state/decisions/...". The section-9 resurface
# fixtures embed that literal. Pin NEXUS_ROOT to a deterministic value
# so the fixtures render identically regardless of the outer
# environment: a bare `$NEXUS_ROOT` under the `set -u` at the top of
# this file aborts the heredoc on any host that does not export it
# (e.g. a clean GitHub Actions runner), silently truncating the
# section-9 bodies to empty — which collapses every stable hash to the
# empty-string digest and defeats the "real transition still emits"
# assertion. Default-if-unset keeps a real in-tree NEXUS_ROOT intact;
# the value itself is immaterial (it cancels across compared bodies).
NEXUS_ROOT="${NEXUS_ROOT:-/nexus}"
export NEXUS_ROOT

# Stub `log` — main.sh defines it, but extracting only the dedup
# helpers leaves it undefined here. main.sh's log() is stderr-only
# (the headless launcher redirect owns the logfile); this stub ALSO
# appends to LOGFILE, standing in for that redirect, so the
# suppression log assertion can read the file.
log() {
    local msg
    msg="[$(date -Is)] $*"
    printf '%s\n' "$msg" >&2
    printf '%s\n' "$msg" >> "$LOGFILE" 2>/dev/null || true
}
export -f log

# The four dedup-gate helpers live in _emit_dedup.sh (extracted from
# main.sh in the issue 180 S3 seam). The module is functions-only with
# no top-level state, so — unlike main.sh, which the pre-extraction
# version of this test had to awk-pluck functions out of — it can be
# sourced directly. The `log` stub above is in scope before any of
# them is called.
# shellcheck source=_emit_dedup.sh
. "$_test_dir/_emit_dedup.sh"

# The original test file talked to a single `_compose_emit_apply_dedup`
# that combined decide + record. The real call site splits them: the
# decision runs before paste_with_retry, the record runs only on
# paste success. The tests work the same way — we exercise the
# decision in isolation and call record ourselves to simulate a
# successful paste. This thin shim mirrors the production flow.
_compose_emit_apply_dedup() {
    local body_file="$1" reason="${2:-unknown}"
    if _compose_emit_should_suppress "$body_file" "$reason"; then
        return 1
    fi
    _compose_emit_record_emit "$body_file"
    return 0
}

# Body fixtures. Each writer takes a path and renders a realistic body.

write_body_quiet_full_state() {
    local path="$1" ts="$2" nonce="$3"
    cat > "$path" <<EOF
=== nexus state changed at ${ts} (poll-full-state) ===
*If unsure how to proceed: see CLAUDE.md.*
workspace: 0 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 awaiting-input
--- workspace snapshot ---
  - worker-alpha idle 1234s (state=idle)
  - worker-beta idle 5678s (state=idle)
(full snapshot; transitions only between snapshots)
--- dashboard ---
last updated: 2026-05-27T11:02:00-07:00
(> 2h old; refresh via \`monitor/ng dashboard put\`)
--- nexus-emit-sig ${ts} ${nonce} ---
EOF
}

write_body_with_eligible_comments() {
    local path="$1" ts="$2" nonce="$3" cid="$4"
    cat > "$path" <<EOF
=== nexus state changed at ${ts} (poll) ===
*If unsure how to proceed: see CLAUDE.md.*
workspace: 0 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 awaiting-input
--- eligible github comments ---
issue=42 id=${cid} author=operator
  body: please review
--- dashboard ---
last updated: 2026-05-27T11:02:00-07:00
--- nexus-emit-sig ${ts} ${nonce} ---
EOF
}

write_body_with_pending_decisions() {
    local path="$1" ts="$2" nonce="$3"
    cat > "$path" <<EOF
=== nexus state changed at ${ts} (poll) ===
workspace: 0 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 awaiting-input
--- pending decisions ---
  - worker-x fp=abc123 file=monitor/.state/decisions/worker-x.abc123.json
(read the cited file for full JSON; ack by removing it once answered)
--- dashboard ---
last updated: 2026-05-27T11:02:00-07:00
--- nexus-emit-sig ${ts} ${nonce} ---
EOF
}

write_body_with_awaiting_input() {
    local path="$1" ts="$2" nonce="$3" n="$4"
    cat > "$path" <<EOF
=== nexus state changed at ${ts} (poll) ===
workspace: 0 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | ${n} awaiting-input
--- dashboard ---
last updated: 2026-05-27T11:02:00-07:00
--- nexus-emit-sig ${ts} ${nonce} ---
EOF
}

# ---- 1. timestamp-strip correctness ----------------------------------------
#
# Two bodies with identical workspace state but different header
# timestamps, different per-window idle ages, different
# dashboard-updated timestamps, and different footer signatures
# should hash IDENTICALLY. This is the load-bearing invariant — if
# this fails, the whole gate fails.
echo '=== 1. timestamp-strip: identical state → identical stable hash ==='
body_a="$WORK/body-a.txt"
body_b="$WORK/body-b.txt"
write_body_quiet_full_state "$body_a" "2026-05-28T02:12:00-07:00" "aaaaaa"
# Vary the timestamp, footer nonce, and per-window idle ages —
# everything that the strip must collapse.
cat > "$body_b" <<EOF
=== nexus state changed at 2026-05-28T06:15:00-07:00 (poll-full-state) ===
*If unsure how to proceed: see CLAUDE.md.*
workspace: 0 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 awaiting-input
--- workspace snapshot ---
  - worker-alpha idle 15034s (state=idle)
  - worker-beta idle 19478s (state=idle)
(full snapshot; transitions only between snapshots)
--- dashboard ---
last updated: 2026-05-27T11:02:00-07:00
(> 2h old; refresh via \`monitor/ng dashboard put\`)
--- nexus-emit-sig 2026-05-28T06:15:00-07:00 bbbbbb ---
EOF
hash_a=$(_compose_emit_stable_hash "$body_a")
hash_b=$(_compose_emit_stable_hash "$body_b")
assert_eq "stable-hash collapses timestamps, idle ages, footer" "$hash_a" "$hash_b"

# ---- 2. identical sequential calls → second suppresses ---------------------
echo '=== 2. identical sequential apply → first emits, second suppresses ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE" "$LOGFILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS
_compose_emit_apply_dedup "$body_a" "poll-full-state"; rc1=$?
_compose_emit_apply_dedup "$body_b" "poll-full-state"; rc2=$?
assert_rc "first apply emits" 0 "$rc1"
assert_rc "second apply suppresses" 1 "$rc2"
if grep -q 'emit-dedup: suppressed identical-hash emit' "$LOGFILE"; then
    printf '  PASS: %s\n' "suppression logged"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: suppression log line missing from %q\n' "$LOGFILE" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- 3. quiet-cap expiry → emits again -------------------------------------
echo '=== 3. quiet-cap expiry: 24h+ since last emit → re-emit ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS
_compose_emit_apply_dedup "$body_a" "poll-full-state"; rc1=$?
# Force the recorded emit epochs back to (now - 86401), past the
# default 86400 cap — both the legacy ts file and the ring entries
# (the ring is what the decision half consults when present).
now=$(date +%s)
printf '%s\n' "$(( now - 86401 ))" > "$EMIT_DEDUP_TS_FILE"
awk -F'\t' -v ts="$(( now - 86401 ))" 'NF==2 { printf "%s\t%s\n", ts, $2 }' \
    "$EMIT_DEDUP_RING_FILE" > "${EMIT_DEDUP_RING_FILE}.aged" \
    && mv "${EMIT_DEDUP_RING_FILE}.aged" "$EMIT_DEDUP_RING_FILE"
_compose_emit_apply_dedup "$body_b" "poll-full-state"; rc2=$?
assert_rc "first apply emits" 0 "$rc1"
assert_rc "post-quiet-cap apply re-emits" 0 "$rc2"

# ---- 4. eligible-comments bypass -------------------------------------------
echo '=== 4. eligible-comments present → bypass dedup ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS
write_body_with_eligible_comments "$body_a" "2026-05-28T02:12:00-07:00" "aaaaaa" 9001
write_body_with_eligible_comments "$body_b" "2026-05-28T02:12:30-07:00" "bbbbbb" 9001
_compose_emit_apply_dedup "$body_a" "poll"; rc1=$?
_compose_emit_apply_dedup "$body_b" "poll"; rc2=$?
assert_rc "first apply emits (eligible-comments)" 0 "$rc1"
assert_rc "second apply emits — bypass kept open (eligible-comments)" 0 "$rc2"
# Also verify the helper itself returns 0 (bypass).
_compose_emit_should_bypass_dedup "$body_a"
assert_rc "helper says bypass on eligible-comments body" 0 "$?"

# ---- 5. pending-decisions: identical re-fire suppresses (issue #152) --------
# Pre-#152 this section asserted pending-decisions ALWAYS bypass. The
# unconditional bypass was the resurface-flood root cause: a parked
# worker re-firing the SAME decision (same fp) re-emitted a byte-
# identical body every poll. New contract: a pending-decision row is
# carried into the stable hash, so an identical decision (differing
# only in header/footer timestamps) suppresses on the second apply,
# while a genuinely CHANGED decision still emits.
echo '=== 5. pending decisions: identical re-fire suppresses, change emits ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE" "$LOGFILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS
write_body_with_pending_decisions "$body_a" "2026-05-28T02:12:00-07:00" "aaaaaa"
write_body_with_pending_decisions "$body_b" "2026-05-28T02:12:30-07:00" "bbbbbb"
_compose_emit_apply_dedup "$body_a" "poll-resurface"; rc1=$?
_compose_emit_apply_dedup "$body_b" "poll-resurface"; rc2=$?
assert_rc "first apply emits (pending decisions)" 0 "$rc1"
assert_rc "identical decision re-fire suppresses" 1 "$rc2"
_compose_emit_should_bypass_dedup "$body_a"
assert_rc "helper no longer bypasses on pending-decisions body" 1 "$?"

# A genuinely changed decision (different fp, flipped unresolved) must
# still emit — wake-on-change preserved.
cat > "$body_b" <<EOF
=== nexus state changed at 2026-05-28T02:13:00-07:00 (poll-resurface) ===
workspace: 0 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 awaiting-input
--- pending decisions ---
  - worker-x fp=def456 file=monitor/.state/decisions/worker-x.def456.json
(read the cited file for full JSON; ack by removing it once answered)
--- dashboard ---
last updated: 2026-05-27T11:02:00-07:00
--- nexus-emit-sig 2026-05-28T02:13:00-07:00 cccccc ---
EOF
_compose_emit_apply_dedup "$body_b" "poll-resurface"; rc3=$?
assert_rc "changed decision (new fp) still emits" 0 "$rc3"

# ---- 6. awaiting-input: volatile delta normalized out (issue #152) ---------
# The `N awaiting-input` prelude scalar is a since-last-render delta
# that toggles 1↔0 even when the underlying state is unchanged. It no
# longer bypasses; it is stripped from the stable hash, so two bodies
# differing ONLY in the awaiting-input count hash identically and the
# second suppresses.
echo '=== 6. awaiting-input: count toggle does not defeat the hash ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE" "$LOGFILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS
write_body_with_awaiting_input "$body_a" "2026-05-28T02:12:00-07:00" "aaaaaa" 1
write_body_with_awaiting_input "$body_b" "2026-05-28T02:12:30-07:00" "bbbbbb" 0
hash_a=$(_compose_emit_stable_hash "$body_a")
hash_b=$(_compose_emit_stable_hash "$body_b")
assert_eq "awaiting-input count stripped from stable hash" "$hash_a" "$hash_b"
_compose_emit_apply_dedup "$body_a" "poll-resurface"; rc1=$?
_compose_emit_apply_dedup "$body_b" "poll-resurface"; rc2=$?
assert_rc "first apply emits (awaiting-input=1)" 0 "$rc1"
assert_rc "awaiting-input toggle 1→0 suppresses (identical state)" 1 "$rc2"
_compose_emit_should_bypass_dedup "$body_a"
assert_rc "helper no longer bypasses on awaiting-input>0 body" 1 "$?"

# ---- 7. content-change → emits, hash advances ------------------------------
# Two flavours: bypass-path emit (eligible-comments present) and
# non-bypass-path emit (workspace counts changed). Both should emit
# AND advance the state hash — record-emit fires on every successful
# paste regardless of which decision branch the body took.
echo '=== 7. content change → emits, state advances ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS
write_body_quiet_full_state "$body_a" "2026-05-28T02:12:00-07:00" "aaaaaa"
_compose_emit_apply_dedup "$body_a" "poll-full-state"; rc1=$?
prev_hash=$(cat "$EMIT_DEDUP_HASH_FILE" 2>/dev/null || true)
write_body_with_eligible_comments "$body_b" "2026-05-28T02:13:00-07:00" "bbbbbb" 4242
_compose_emit_apply_dedup "$body_b" "poll"; rc2=$?
new_hash=$(cat "$EMIT_DEDUP_HASH_FILE" 2>/dev/null || true)
assert_rc "first emits" 0 "$rc1"
assert_rc "second (different body, eligible-comments) emits" 0 "$rc2"
assert_ne "bypass-path emit also advances hash" "$new_hash" "$prev_hash"

# Non-bypass content change: workspace prelude counts shift; second
# body differs from first in a way the strip preserves.
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS
write_body_quiet_full_state "$body_a" "2026-05-28T02:12:00-07:00" "aaaaaa"
_compose_emit_apply_dedup "$body_a" "poll-full-state" >/dev/null; rc1=$?
prev_hash=$(cat "$EMIT_DEDUP_HASH_FILE")
cat > "$body_b" <<EOF
=== nexus state changed at 2026-05-28T02:13:00-07:00 (poll-full-state) ===
*If unsure how to proceed: see CLAUDE.md.*
workspace: 1 busy | 0 idle | 0 retained | 0 idle-too-long | 0 pane-absent | 0 over-limit | 0 orphan-async | 0 awaiting-input
--- workspace snapshot ---
  - worker-alpha (active, state=busy)
(full snapshot; transitions only between snapshots)
--- dashboard ---
last updated: 2026-05-27T11:02:00-07:00
--- nexus-emit-sig 2026-05-28T02:13:00-07:00 bbbbbb ---
EOF
_compose_emit_apply_dedup "$body_b" "poll-full-state"; rc2=$?
new_hash=$(cat "$EMIT_DEDUP_HASH_FILE")
assert_rc "first apply emits" 0 "$rc1"
assert_rc "second (workspace-count changed) apply emits" 0 "$rc2"
assert_ne "hash advanced on content change" "$new_hash" "$prev_hash"

# ---- 8. knob=0 → opt out entirely ------------------------------------------
echo '=== 8. MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS=0 disables the gate ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE"
write_body_quiet_full_state "$body_a" "2026-05-28T02:12:00-07:00" "aaaaaa"
MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS=0 _compose_emit_apply_dedup "$body_a" "poll"; rc1=$?
MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS=0 _compose_emit_apply_dedup "$body_a" "poll"; rc2=$?
MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS=0 _compose_emit_apply_dedup "$body_a" "poll"; rc3=$?
assert_rc "knob=0: first emits"  0 "$rc1"
assert_rc "knob=0: second emits" 0 "$rc2"
assert_rc "knob=0: third emits"  0 "$rc3"
if [[ ! -e "$EMIT_DEDUP_HASH_FILE" ]]; then
    printf '  PASS: %s\n' "knob=0 short-circuits before state write"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: knob=0 left state file behind: %q\n' "$EMIT_DEDUP_HASH_FILE" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- 9. issue #152 resurface-flood regression (live-captured shape) --------
# Reconstructed from two consecutive `poll-resurface` bodies the live
# watcher archived 5s apart (2026-06-08 21:57:41 / 21:57:46). They are
# semantically identical — same parked worker, same unchanged
# `idle_prompt` decision (fp=62c547f9263c) — and differ ONLY in the
# header timestamp, the footer sig, and the `awaiting-input` count
# toggling 1→0. Pre-#152 BOTH emitted (pending-decisions bypass);
# the fix must suppress the second. Then a genuine transition (the
# pane-absent worker recovers: count 1→0) must still emit.
echo '=== 9. issue #152: identical resurface suppresses, real transition emits ==='
rm -f "$EMIT_DEDUP_HASH_FILE" "$EMIT_DEDUP_TS_FILE" "$EMIT_DEDUP_RING_FILE" "$LOGFILE"
unset MONITOR_EMIT_DEDUP_MAX_QUIET_SECONDS

write_resurface_body() {
    local path="$1" ts="$2" nonce="$3" awaiting="$4" pane_absent="${5:-1}"
    cat > "$path" <<EOF
=== nexus state changed at ${ts} (poll-resurface) ===
*If unsure how to proceed: see CLAUDE.md.*
workspace: 1 busy | 1 idle | 0 retained | 0 idle-too-long | ${pane_absent} pane-absent | 0 over-limit | 0 orphan-async | ${awaiting} awaiting-input
--- pending decisions ---
window=kompot-scaleup fp=62c547f9263c kind=idle_prompt unresolved=false
    prompt-excerpt=Claude is waiting for your input
    file=$NEXUS_ROOT/monitor/.state/decisions/kompot-scaleup.62c547f9263c.json
(read the cited file for full JSON; ack by removing it once answered)
--- dashboard ---
last updated: 2026-06-08T21:53:06-07:00
--- nexus-emit-sig ${ts} ${nonce} ---
EOF
}

# Body A: awaiting-input=1. Body B: awaiting-input=0, later ts/nonce.
write_resurface_body "$body_a" "2026-06-08T21:57:38-07:00" "629c1e" 1 1
write_resurface_body "$body_b" "2026-06-08T21:57:43-07:00" "e7bd4c" 0 1
hash_a=$(_compose_emit_stable_hash "$body_a")
hash_b=$(_compose_emit_stable_hash "$body_b")
assert_eq "live-shape resurface bodies hash identically" "$hash_a" "$hash_b"
_compose_emit_apply_dedup "$body_a" "poll-resurface"; rc1=$?
_compose_emit_apply_dedup "$body_b" "poll-resurface"; rc2=$?
assert_rc "first resurface emits" 0 "$rc1"
assert_rc "near-duplicate resurface (idle counter + awaiting toggle) suppresses" 1 "$rc2"
if grep -q 'emit-dedup: suppressed identical-hash emit' "$LOGFILE"; then
    printf '  PASS: %s\n' "flood suppression logged"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: flood suppression log line missing from %q\n' "$LOGFILE" >&2
    FAIL=$(( FAIL + 1 ))
fi
# Genuine transition: the pane-absent worker recovers (1→0). Real
# state change → distinct hash → must emit.
write_resurface_body "$body_a" "2026-06-08T21:58:00-07:00" "f767aa" 0 0
_compose_emit_apply_dedup "$body_a" "poll-resurface"; rc3=$?
assert_rc "real workspace transition (pane-absent 1→0) still emits" 0 "$rc3"

# ---- summary ---------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d/%d)\n' "$PASS" "$(( PASS + FAIL ))"
    exit 0
else
    printf 'TESTS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
    exit 1
fi
