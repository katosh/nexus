#!/usr/bin/env bash
# Unit + scenario tests for the full-state identity-check suppression
# added in issue #104. Covers the canonical-form construction (prelude
# + per-window snapshot, idle-seconds stripped), the dry-run-prelude
# stamp invariant, and the cache-file gate that drives the
# suppress / emit / safety-floor decision in main.sh.
#
# Strategy: shadow `tmux` and `pane-state.sh` on PATH so we can script
# per-window state without a real tmux server; source _idle_probe.sh
# directly and reproduce main.sh's canonical-construction inline
# (the few lines that build `full_state_canonical`). The suppression
# decision is a pure function of (canonical, cached canonical, mtime,
# safety floor) — we exercise it as a plain bash conditional with
# `touch -d` for synthetic mtimes.
#
# Run: bash monitor/watcher/test-full-state-suppression.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

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
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR"
export STATE_DIR

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    *)            : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

cat > "$STUB_DIR/pane-state.sh" <<'STUB'
#!/usr/bin/env bash
win="${1:-}"
while [[ "$win" == --* ]]; do
    shift 2 2>/dev/null || break
    win="${1:-}"
done
key="MOCK_PANE_STATE_${win//[^a-zA-Z0-9_]/_}"
reset_key="MOCK_PANE_RESET_AT_${win//[^a-zA-Z0-9_]/_}"
state="${!key:-busy}"
reset_at="${!reset_key:-}"
if [[ -n "$reset_at" ]]; then
    printf 'state=%s reset_at=%s\n' "$state" "$reset_at"
else
    printf 'state=%s\n' "$state"
fi
exit 0
STUB
chmod +x "$STUB_DIR/pane-state.sh"

mkdir -p "$WORK/monitor"
cp "$STUB_DIR/pane-state.sh" "$WORK/monitor/pane-state.sh"
NEXUS_ROOT="$WORK"
export NEXUS_ROOT

# Build the canonical form exactly as main.sh does post-#104 (and
# post-emit-gate-recover): prelude in DRY_RUN mode (no stamp
# advance), full snapshot, volatile tokens collapsed via the SHARED
# `_emit_volatile_strip` from _emit_dedup.sh — the same filter the
# production call site pipes through. Captured here so the test
# reads identically to the production call site.
build_canonical() {
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        export STATE_DIR NEXUS_ROOT
        source '$_test_dir/_emit_dedup.sh'
        source '$PROBE'
        prelude=\$(MONITOR_PRELUDE_DRY_RUN=1 render_idle_prelude 2>/dev/null || true)
        lines=\$(render_full_state_snapshot 2>/dev/null || true)
        printf '%s\n---snapshot---\n%s' \"\$prelude\" \"\$lines\" \
            | _emit_volatile_strip
    " 2>/dev/null
}

# Render a real (non-dry-run) prelude, advancing the stamp. Used to
# verify the stamp-invariant assertion.
render_prelude_for_real() {
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        export STATE_DIR NEXUS_ROOT
        source '$PROBE'
        render_idle_prelude 2>/dev/null
    "
}

# Local handle on the shared strip for direct assertions.
source "$_test_dir/_emit_dedup.sh"
_strip_for_test() { _emit_volatile_strip; }

NOW=$(date +%s)
OLD_TS=$(( NOW - 600 ))

seed_engagement_log() {
    local elog="$STATE_DIR/engagement-log.tsv"
    : > "$elog"
    [[ -n "${MOCK_TMUX_WINDOWS:-}" ]] || return 0
    printf '%s\n' "$MOCK_TMUX_WINDOWS" \
        | awk -F'|' 'NF>=2 {printf "%s\t%s\n", $1, $2}' \
        > "$elog"
}

reset_state() {
    rm -f "$STATE_DIR"/idle-state.tsv \
          "$STATE_DIR"/engagement-log.tsv \
          "$STATE_DIR"/idle-probe-previous-windows.txt \
          "$STATE_DIR"/worker-notifications.jsonl \
          "$STATE_DIR"/last-prelude.ts \
          "$STATE_DIR"/last-full-state-canonical.txt
}

# ---- Fixture A: two identical canonicals back-to-back -------------------
#
# Per-window state stable, no notifications. Second canonical must be
# byte-identical to the first → suppression gate hits.

echo '=== Fixture A: identical canonicals back-to-back ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'alpha|%s\nbeta|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log
export MOCK_PANE_STATE_alpha=idle
export MOCK_PANE_STATE_beta=idle

c1=$(build_canonical)
c2=$(build_canonical)

assert_eq        "canonical non-empty"                "$(printf '%s' "$c1" | wc -c | tr -d ' ' | awk '{print ($1>0)?"yes":"no"}')" "yes"
assert_eq        "two identical-state renders match"  "$c1"   "$c2"
assert_contains  "canonical includes prelude header"  "$c1"   "busy | "
assert_contains  "canonical includes alpha row"       "$c1"   "alpha"
assert_contains  "canonical includes beta row"        "$c1"   "beta"

# ---- Fixture B: per-window state changes between cycles ----------------
#
# One worker flips idle→busy. Canonicals must differ → emit fires.

echo '=== Fixture B: per-window state change drives canonical delta ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'alpha|%s\nbeta|%s' "$OLD_TS" "$OLD_TS")"
seed_engagement_log
export MOCK_PANE_STATE_alpha=idle
export MOCK_PANE_STATE_beta=idle
c_before=$(build_canonical)

export MOCK_PANE_STATE_beta=busy
c_after=$(build_canonical)

assert_ne        "canonical changes when beta flips idle→busy" "$c_before" "$c_after"
assert_contains  "after-state shows beta active"               "$c_after"  "beta (active"

# ---- Fixture C: only idle-seconds tick up between cycles ---------------
#
# Same state pair, but engagement-log epoch slides back so the rendered
# `idle Ns` differs across renders. With the sed strip those rows
# canonicalize to the same string → suppression holds.

echo '=== Fixture C: idle-seconds drift collapses under canonical ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'gamma|%s' "$OLD_TS")"
seed_engagement_log
export MOCK_PANE_STATE_gamma=idle
# Manually anchor engagement to a fixed point first (idle=600s in the
# render), then bump backward (idle=1200s) — render_full_state_snapshot
# computes age from now - engagement, so we move the engagement epoch.
printf '%s\t%s\n' gamma $(( NOW - 600 )) > "$STATE_DIR/engagement-log.tsv"
c_short=$(build_canonical)
printf '%s\t%s\n' gamma $(( NOW - 1200 )) > "$STATE_DIR/engagement-log.tsv"
c_long=$(build_canonical)

# Both should contain "gamma" with `idle` token, but the seconds
# number must NOT survive into the canonical (sed strips it).
assert_eq        "idle-seconds-only delta canonicalizes to same string" "$c_short" "$c_long"
assert_contains  "canonical retains stripped idle token"                "$c_short" "idle (state="
case "$c_short" in
    *"idle "[0-9]*"s"*) printf '  FAIL: canonical leaked raw idle-seconds: %q\n' "$c_short" >&2; FAIL=$(( FAIL + 1 )) ;;
    *)                  printf '  PASS: canonical does not leak raw idle-seconds\n'; PASS=$(( PASS + 1 )) ;;
esac

# ---- Fixture D: safety-floor mtime override emits despite identity ---
#
# main.sh's suppression gate: identical canonical AND
# (now - cache_mtime) < safety_floor → suppress. If the cache file's
# mtime is older than the floor, the gate falls through to emit even
# though the canonicals match. Verify the comparison logic directly.

echo '=== Fixture D: safety-floor breach forces emit-despite-identity ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'alpha|%s' "$OLD_TS")"
seed_engagement_log
export MOCK_PANE_STATE_alpha=idle
canon_now=$(build_canonical)

cache="$STATE_DIR/last-full-state-canonical.txt"
printf '%s' "$canon_now" > "$cache"
# Backdate mtime to 1 hour ago. With a 4h safety floor: suppress.
# With a 30-minute floor: emit.
touch -d "1 hour ago" "$cache"
now_check=$(date +%s)
cache_mtime=$(date +%s -r "$cache")
delta=$(( now_check - cache_mtime ))
test "$delta" -ge 3500 -a "$delta" -le 3700 \
    && { printf '  PASS: cache backdated ~1h (delta=%ds)\n' "$delta"; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: cache backdating off (delta=%ds, want ~3600)\n' "$delta" >&2; FAIL=$(( FAIL + 1 )); }

# Suppression decision under default 4h floor (14400s).
SAFETY_4H=14400
if (( delta < SAFETY_4H )); then
    decision="suppress"
else
    decision="emit"
fi
assert_eq "1h delta, 4h floor → suppress decision" "$decision" "suppress"

# Suppression decision under tight 30-minute floor (1800s).
SAFETY_30M=1800
if (( delta < SAFETY_30M )); then
    decision="suppress"
else
    decision="emit"
fi
assert_eq "1h delta, 30m floor → emit decision" "$decision" "emit"

# ---- Fixture E: first emit after fresh state dir -----------------------
#
# Cache file absent → suppression gate falls through to emit. After
# the emit, cache is written and contains the canonical we just sent.

echo '=== Fixture E: first emit after fresh STATE_DIR seeds the cache ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'alpha|%s' "$OLD_TS")"
seed_engagement_log
export MOCK_PANE_STATE_alpha=idle
canon_first=$(build_canonical)

cache="$STATE_DIR/last-full-state-canonical.txt"
[[ -f "$cache" ]] && { printf '  FAIL: cache file should be absent on fresh state\n' >&2; FAIL=$(( FAIL + 1 )); } \
                  || { printf '  PASS: cache absent before first emit\n'; PASS=$(( PASS + 1 )); }

# Simulate the post-emit seed (atomic tmp+rename as in main.sh).
printf '%s' "$canon_first" > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
[[ -f "$cache" ]] && { printf '  PASS: cache present after seed\n'; PASS=$(( PASS + 1 )); } \
                  || { printf '  FAIL: cache missing after seed\n' >&2; FAIL=$(( FAIL + 1 )); }

cached=$(cat "$cache")
assert_eq "cached canonical matches what was emitted" "$cached" "$canon_first"

# Subsequent canonical with same state matches cached → suppression.
canon_next=$(build_canonical)
assert_eq "follow-up canonical matches seeded cache" "$canon_next" "$cached"

# ---- DRY_RUN invariant: render_idle_prelude with MONITOR_PRELUDE_DRY_RUN=1
#       must NOT advance the awaiting-input stamp ------------------------

echo '=== DRY_RUN: prelude does not advance the awaiting-input stamp ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'quietworker|%s' "$OLD_TS")"
seed_engagement_log
export MOCK_PANE_STATE_quietworker=busy

# A normal (non-dry-run) render writes the stamp. Cache its mtime.
render_prelude_for_real >/dev/null
stamp="$STATE_DIR/last-prelude.ts"
[[ -f "$stamp" ]] || { printf '  FAIL: stamp not created by real render\n' >&2; FAIL=$(( FAIL + 1 )); }
stamp_before=$(cat "$stamp" 2>/dev/null || echo missing)

# Dry-run render does NOT touch the stamp.
sleep 1
build_canonical >/dev/null
stamp_after=$(cat "$stamp" 2>/dev/null || echo missing)

assert_eq "stamp content unchanged by dry-run prelude" "$stamp_after" "$stamp_before"

# A subsequent real render advances the stamp (the invariant only
# holds for DRY_RUN — the production stamp-update path is intact).
sleep 1
render_prelude_for_real >/dev/null
stamp_after_real=$(cat "$stamp" 2>/dev/null || echo missing)
assert_ne "stamp content advanced by non-dry-run real render" "$stamp_after_real" "$stamp_before"

# ---- DRY_RUN: awaiting-input count preserved across suppression ---------
#
# If we render dry-run twice with new notifications in between, the
# second dry-run must still see those notifications (because the stamp
# hasn't been advanced). The cycle-2 "emit" path renders normally and
# advances the stamp, draining the count.

echo '=== DRY_RUN: awaiting-input counter preserved across suppression cycles ==='
reset_state
export MOCK_TMUX_WINDOWS="$(printf 'alpha|%s' "$OLD_TS")"
seed_engagement_log
export MOCK_PANE_STATE_alpha=busy

NLOG="$STATE_DIR/worker-notifications.jsonl"
PRE_TS=$(( NOW - 100 ))
cat > "$NLOG" <<EOF
{"event":"Notification","notification":{"type":"permission_prompt"},"window":"alpha","ts":$PRE_TS}
EOF

# Seed the stamp 200s ago — that puts the PRE_TS notification in scope.
printf '%s' "$(( NOW - 200 ))" > "$STATE_DIR/last-prelude.ts"

# The shared volatile strip normalizes `N awaiting-input` out of the
# CANONICAL (post-#152 the count is shadowed by pending-decision
# rows and must not defeat the identity check), so the stamp
# invariant is asserted on the RAW dry-run prelude instead.
raw_dry_prelude() {
    PATH="$STUB_DIR:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$STATE_DIR'
        NEXUS_ROOT='$NEXUS_ROOT'
        export STATE_DIR NEXUS_ROOT
        source '$PROBE'
        MONITOR_PRELUDE_DRY_RUN=1 render_idle_prelude 2>/dev/null
    " 2>/dev/null
}
p_dry1=$(raw_dry_prelude)
p_dry2=$(raw_dry_prelude)

# Both dry-runs see the same notification (stamp didn't move).
assert_contains "first dry-run sees 1 awaiting-input"  "$p_dry1" "1 awaiting-input"
assert_contains "second dry-run still sees 1 awaiting-input (stamp not advanced)" \
                "$p_dry2" "1 awaiting-input"

# Once we actually emit (real render), the stamp advances and the
# count drains on subsequent renders.
render_prelude_for_real >/dev/null
p_after_emit=$(raw_dry_prelude)
assert_contains "after real render, dry-run sees 0 awaiting-input (drained)" \
                "$p_after_emit" "0 awaiting-input"

# And the CANONICAL is awaiting-input-stable by construction: the
# count toggling 1->0 must NOT change the canonical form (a
# notification arrival is surfaced by its pending-decision row, not
# by a full-state re-paste).
assert_eq "canonical form invariant under awaiting-input toggle" \
    "$(printf '%s' "$p_dry1" | _strip_for_test)" \
    "$(printf '%s' "$p_after_emit" | _strip_for_test)"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
