#!/usr/bin/env bash
# The three-arm table for the skeptic-liveness probe
# (jacob-greene/nexus#31), made executable.
#
# THE DEFECT: `_idle_skeptic_live_window` inferred liveness from an EMPTY
# tmux window list and threw tmux's exit status away with `2>/dev/null`,
# so "I asked and no skeptic is live" and "I could not ask" were the same
# rc 1. They point opposite ways at the retire gate.
#
# THE TEST: hold the ON-DISK state IDENTICAL across three arms — fresh
# skeptic-pending marker, a `skeptic-spawn` event naming a skeptic window
# that is GENUINELY ALIVE, and a request timestamp past the orphan grace
# — and vary ONLY whether tmux answers:
#
#     arm                     probe rc   derived state    gate
#     tmux answers            0          live             GATED
#     tmux absent (rc 127)    2          unknown          GATED   <- was orphaned
#     tmux exits 1 (no srv)   2          unknown          GATED   <- was orphaned
#
# Before the fix the bottom two rows read `orphaned`, the ONE
# marker-present state retire-preflight.sh check 1b does not block on —
# so a tmux misread retired a worker whose reviewer was alive.
#
# Every arm calls the predicates with an EMPTY live-window list, which is
# exactly how retire-preflight.sh and `ng` call them (they pass no window
# snapshot, so the probe must query tmux itself). The watcher's own
# per-cycle snapshot path is covered by arm 4.
#
# Run: bash monitor/watcher/test-skeptic-liveness-tristate.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STATE_DIR="$WORK/.state"
mkdir -p "$STATE_DIR/skeptic/pending"
export STATE_DIR
# No config/load.sh reachable → hang 600, orphan grace 600 (defaults).
unset NEXUS_ROOT MONITOR_SKEPTIC_AWAIT_HANG_SECONDS \
      MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS 2>/dev/null || true

ORIG_PATH="$PATH"

# ---- arm machinery -------------------------------------------------------
# Three PATHs that differ ONLY in `tmux`. Each is a farm of the utilities
# this code path uses (grep/sed/awk/date), so the arms are otherwise
# identical environments; the ABSENT arm is simply the farm with no tmux
# in it, so the shell's own PATH lookup fails with rc 127 — the real
# absence mechanism, not a stub pretending to be one.
farm() {
    local d="$1" t p; mkdir -p "$d"
    for t in grep sed awk date cat touch rm mkdir env bash dirname; do
        p=$(PATH="$ORIG_PATH" command -v "$t" 2>/dev/null) || continue
        ln -sf "$p" "$d/$t"
    done
}

NOTMUX_DIR="$WORK/bin-notmux"; farm "$NOTMUX_DIR"

STUB_DIR="$WORK/bin-answers"; farm "$STUB_DIR"
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    list-windows) printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    *) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

FAIL_DIR="$WORK/bin-exit1"; farm "$FAIL_DIR"
# `tmux list-windows` with no server: nothing on stdout, a diagnosis on
# stderr, exit 1. Verified against the tmux on this host.
cat > "$FAIL_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
printf 'no server running on /tmp/tmux-0/default\n' >&2
exit 1
STUB
chmod +x "$FAIL_DIR/tmux"

# shellcheck source=_idle_probe.sh
source "$PROBE"

ACTION_LOG="$STATE_DIR/action-log.jsonl"
NOW=$(date +%s)

iso() { date -d "@$1" -Is 2>/dev/null || date -Is; }
mk_marker() { local f="$STATE_DIR/skeptic/pending/${1//[^a-zA-Z0-9_-]/_}"; : > "$f"; touch -d "@$2" "$f"; }
log_request() { printf '{"ts":"%s","agent":"monitor","event":"skeptic-request","target-window":"%s","depth":"1"}\n' "$(iso "$2")" "$1" >> "$ACTION_LOG"; }
log_spawn()   { printf '{"ts":"%s","agent":"monitor","event":"skeptic-spawn","window":"%s","target-window":"%s","orig-window":"%s","depth":"1"}\n' "$(iso "$3")" "$2" "$1" "$1" >> "$ACTION_LOG"; }

# ---- THE on-disk state. Identical for every arm. -------------------------
WIN=wkr
mk_marker   "$WIN" "$NOW"                              # marker FRESH
log_request "$WIN" "$(( NOW - 1200 ))"                 # required 20 min ago (> 600 grace)
log_spawn   "$WIN" "$WIN-skeptic" "$(( NOW - 1100 ))"  # a real skeptic WAS spawned
# ...and that skeptic window is genuinely alive whenever tmux can say so.
export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr\nwkr-skeptic'

# ---- the arm table -------------------------------------------------------
# run_arm <path-dir> <label> <expected-probe-rc> <expected-orphaned:yes|no>
run_arm() {
    local dir="$1" label="$2" want_rc="$3" want_orphan="$4"
    local rc
    (
        PATH="$dir"
        # Self-check: the arm must actually be the arm it claims to be.
        case "$label" in
            *absent*) command -v tmux >/dev/null 2>&1 && exit 90 ;;
            *)        command -v tmux >/dev/null 2>&1 || exit 91 ;;
        esac
        _idle_skeptic_live_window "$WIN" ""
        exit $?
    )
    rc=$?
    case "$rc" in
        90) bad "$label: arm setup broken — tmux is reachable in the ABSENT arm"; return ;;
        91) bad "$label: arm setup broken — no tmux in the arm's PATH"; return ;;
    esac
    if [[ "$rc" == "$want_rc" ]]; then
        ok "$label: _idle_skeptic_live_window rc $rc (want $want_rc)"
    else
        bad "$label: _idle_skeptic_live_window rc $rc, want $want_rc"
    fi

    # Same arm, now through the two predicates the gate consumers use.
    local orph parked
    ( PATH="$dir"; _idle_skeptic_orphaned "$WIN" "$NOW" "" ); orph=$?
    ( PATH="$dir"; _idle_skeptic_parked   "$WIN" "$NOW" "" ); parked=$?
    if [[ "$want_orphan" == yes ]]; then
        (( orph == 0 )) && ok "$label: orphaned (marker does NOT block the kill)" \
                        || bad "$label: expected ORPHANED, got rc $orph"
    else
        (( orph != 0 )) && ok "$label: NOT orphaned → marker still GATES the kill" \
                        || bad "$label: expected NOT orphaned (gate must hold), got orphaned"
    fi
    printf '       (parked rc=%s)\n' "$parked"
}

echo "=== arm 1: tmux ANSWERS — reviewer visible → live, GATED ==="
run_arm "$STUB_DIR"   "arm1/tmux-answers" 0 no

echo "=== arm 2: tmux ABSENT (rc 127) — nothing established → GATED ==="
run_arm "$NOTMUX_DIR" "arm2/tmux-absent"  2 no

echo "=== arm 3: tmux EXITS 1 (no server) — nothing established → GATED ==="
run_arm "$FAIL_DIR"   "arm3/tmux-exit1"   2 no

# ---- arm 4: the CONTROL. rc 1 must still mean rc 1. ----------------------
# Fail-closed is only correct if it is NARROW: an answering tmux that
# genuinely shows no skeptic must still produce rc 1 and `orphaned`, or
# the fix has simply disabled the orphan class.
echo "=== arm 4 (control): tmux answers, skeptic window GONE → rc 1, orphaned ==="
(
    PATH="$STUB_DIR"
    export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr'   # skeptic really died
    _idle_skeptic_live_window "$WIN" ""
    exit $?
)
rc4=$?
(( rc4 == 1 )) && ok "control: asked, none alive → rc 1 (not folded into 2)" \
               || bad "control: expected rc 1, got $rc4"
(
    PATH="$STUB_DIR"
    export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr'
    _idle_skeptic_orphaned "$WIN" "$NOW" ""
)
orph4=$?
(( orph4 == 0 )) && ok "control: dead skeptic past grace → still ORPHANED" \
                 || bad "control: expected orphaned, got rc $orph4"

# ---- arm 5: a caller-supplied window list never consults tmux -----------
# The watcher passes its per-cycle snapshot as $3. That list IS an answer
# tmux already gave, so the probe must trust it even where tmux itself is
# unreachable — otherwise the whole poll degrades to `unknown`.
echo "=== arm 5: caller-supplied snapshot, tmux ABSENT → still decides ==="
(
    PATH="$NOTMUX_DIR"
    _idle_skeptic_live_window "$WIN" $'orchestrator\nwkr\nwkr-skeptic'
)
rc5=$?
(( rc5 == 0 )) && ok "supplied snapshot naming the skeptic → rc 0 (live), no tmux call" \
               || bad "supplied snapshot: expected rc 0, got $rc5"
(
    PATH="$NOTMUX_DIR"
    _idle_skeptic_live_window "$WIN" $'orchestrator\nwkr'
)
rc5b=$?
(( rc5b == 1 )) && ok "supplied snapshot without the skeptic → rc 1 (asked, none alive)" \
                || bad "supplied snapshot: expected rc 1, got $rc5b"

# ---- arm 6: the predicates must not kill a `set -e` caller -------------
# rc 1 — "asked tmux, no skeptic alive" — is the ORDINARY answer on this
# path, not a failure. A bare `_idle_skeptic_live_window …; case $?` would
# make it one: a simple command returning non-zero terminates a `set -e`
# caller outright, so the predicate would die BEFORE computing grace /
# orphaned, and every caller downstream of it would never run. The `if`
# and `&&` forms this tri-state rewrite replaced were errexit-exempt by
# construction; the replacement has to keep that property.
#
# BEHAVIOURAL, not textual: each arm runs the predicate as a BARE simple
# command inside a genuinely errexit-armed shell (an `if`/`&&` wrapper
# here would suppress errexit for the predicate's whole dynamic extent
# and the test would pass on the broken code), drives the rc-1 path, and
# checks that execution REACHED the line after the call.
echo "=== arm 6 (regression): rc 1 must not abort a set -e caller ==="

GRACE_WIN=wkr-in-grace
mk_marker   "$GRACE_WIN" "$NOW"                  # fresh marker
log_request "$GRACE_WIN" "$(( NOW - 60 ))"       # required 1 min ago → INSIDE grace
# No skeptic-spawn event, and tmux lists no `-skeptic` window, so the
# liveness probe answers rc 1 and the grace ladder decides.

# The tree under test is resolved from THIS FILE's location and from
# nothing else. Every nexus agent runs with an ambient NEXUS_ROOT pointing
# at the primary clone, and the libs below prefer `$NEXUS_ROOT/monitor/…`
# over their own directory when they resolve each other — so a suite that
# does not pin the root can green up against a tree it never edited. The
# driver re-sources from $OWN_TREE explicitly, re-exports NEXUS_ROOT to
# match, and pins the two tunables the ladder reads so no tree's
# config/load.sh can move the grace boundary underneath the fixture.
OWN_TREE=$(cd "$_test_dir/../.." && pwd)

# Rewrite <src> to <dst> with the errexit-safe status capture UNDONE —
# the shape this fix replaced: a bare `_idle_skeptic_live_window …`
# followed by `case $? in`. Keyed on the OPERATION (a guarded call whose
# status is captured into a variable, and the `case` that reads it), not
# on that variable's spelling. Writes its edit count to <cntfile> so an
# inert transform is caught instead of silently producing a decoy that is
# identical to the real thing.
revert_fix() {
    awk -v cnt="$3" '
        {
            line = $0
            if (line ~ /_idle_skeptic_live_window/ &&
                match(line, /[ \t]*\|\|[ \t]*[A-Za-z_][A-Za-z0-9_]*=\$\?[ \t]*$/)) {
                var = substr(line, RSTART, RLENGTH)
                sub(/^[ \t]*\|\|[ \t]*/, "", var); sub(/=\$\?[ \t]*$/, "", var)
                line = substr(line, 1, RSTART - 1)
                captured[var] = 1
                n++
            } else if (match(line, /^[ \t]*case[ \t]+\$[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]*$/)) {
                v = line
                sub(/^[ \t]*case[ \t]+\$/, "", v); sub(/[ \t]+in[ \t]*$/, "", v)
                if (v in captured) { sub(/\$[A-Za-z_][A-Za-z0-9_]*/, "$?", line); n++ }
            }
            print line
        }
        END { print n + 0 > cnt }
    ' "$1" > "$2"
}

DECOY="$WORK/decoy-tree"
mkdir -p "$DECOY/monitor/watcher"
# `_idle_probe.sh` loads its window-key encoder from `../_bookkeeping.sh`
# and refuses to load without it, so the decoy carries that sibling too.
cp "$OWN_TREE/monitor/_bookkeeping.sh" "$DECOY/monitor/_bookkeeping.sh"
revert_fix "$OWN_TREE/monitor/watcher/_idle_probe.sh" \
           "$DECOY/monitor/watcher/_idle_probe.sh" "$WORK/decoy.count"
DECOY_EDITS=$(cat "$WORK/decoy.count")

# Run <fn> <args…> as a BARE simple command under `set -euo pipefail`,
# against the libs in <tree>. Echoes "reached <rc>" iff control returned
# from the call; nothing if errexit killed the shell mid-predicate.
under_errexit_in() {
    local tree="$1"; shift
    (
        set -uo pipefail
        PATH="$STUB_DIR"
        export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr\nwkr-in-grace'
        export NEXUS_ROOT="$tree"
        export MONITOR_SKEPTIC_AWAIT_HANG_SECONDS=600
        export MONITOR_SKEPTIC_ORPHAN_GRACE_SECONDS=600
        # shellcheck disable=SC1090
        source "$tree/monitor/watcher/_idle_probe.sh" >/dev/null 2>&1
        set -euo pipefail
        "$@" >/dev/null            # <- bare. errexit is live on this line.
        printf 'reached %s\n' "$?"
    ) 2>/dev/null
}

# 6a CONTROL — proves errexit is actually armed in the driver. A window
# with NO marker returns rc 1 from the marker check, a path that never
# reaches the liveness call. That bare rc 1 MUST kill the subshell. If
# this reports "reached", the harness tests nothing and every assertion
# below is vacuous.
ctl=$(under_errexit_in "$OWN_TREE" _idle_skeptic_parked no-such-window "$NOW" "")
[[ -z "$ctl" ]] \
    && ok "control: errexit IS armed (a bare rc 1 kills the caller)" \
    || bad "control: harness is not errexit-armed — got '$ctl'; every arm-6 assertion is vacuous"

# 6b `_idle_skeptic_parked` on the rc-1 path, inside the grace window:
# must return 0 (parked) and leave the caller alive.
got=$(under_errexit_in "$OWN_TREE" _idle_skeptic_parked "$GRACE_WIN" "$NOW" "")
[[ "$got" == "reached 0" ]] \
    && ok "_idle_skeptic_parked: rc-1 liveness → grace, caller survives" \
    || bad "_idle_skeptic_parked: caller did not survive the rc-1 path (got '${got:-<killed>}', want 'reached 0')"

# 6c `_idle_skeptic_orphaned` on the rc-1 path, past the grace: must
# return 0 (orphaned) and leave the caller alive.
got=$(under_errexit_in "$OWN_TREE" _idle_skeptic_orphaned "$WIN" "$NOW" "")
[[ "$got" == "reached 0" ]] \
    && ok "_idle_skeptic_orphaned: rc-1 liveness → orphaned, caller survives" \
    || bad "_idle_skeptic_orphaned: caller did not survive the rc-1 path (got '${got:-<killed>}', want 'reached 0')"

# ---- 6d the NEGATIVE arm: the same assertions must FAIL on a tree
# without the fix. Without this, 6b/6c pass on any tree whose libs merely
# load — including the primary clone's — and the arm certifies nothing
# about the file in THIS working tree.
(( DECOY_EDITS >= 4 )) \
    && ok "decoy fixture: reverted $DECOY_EDITS guarded-capture sites" \
    || bad "decoy fixture is INERT ($DECOY_EDITS edits, want >= 4) — 6d proves nothing; the transform no longer matches the code"

# The decoy must still be a WORKING lib, or 6d would pass for the wrong
# reason (a syntax error aborts just as an errexit trip does).
bash -n "$DECOY/monitor/watcher/_idle_probe.sh" 2>/dev/null \
    && ok "decoy fixture: still parses" \
    || bad "decoy fixture: does not parse — 6d cannot distinguish errexit from a broken copy"
decoy_live=$(
    PATH="$STUB_DIR"; export MOCK_TMUX_WINDOWS=$'orchestrator\nwkr\nwkr-in-grace'
    bash -c 'source "$1" >/dev/null 2>&1; _idle_skeptic_live_window wkr-in-grace ""; echo $?' \
        _ "$DECOY/monitor/watcher/_idle_probe.sh" 2>/dev/null
)
[[ "$decoy_live" == 1 ]] \
    && ok "decoy fixture: liveness primitive still answers rc 1 (only the capture was undone)" \
    || bad "decoy fixture: liveness rc '$decoy_live', want 1 — the decoy differs by more than the fix"

got=$(under_errexit_in "$DECOY" _idle_skeptic_parked "$GRACE_WIN" "$NOW" "")
[[ -z "$got" ]] \
    && ok "NEGATIVE: same arm against a tree WITHOUT the fix → caller killed (guard discriminates)" \
    || bad "NEGATIVE: unfixed tree survived (got '$got') — this guard passes regardless of the code it reads"

got=$(under_errexit_in "$DECOY" _idle_skeptic_orphaned "$WIN" "$NOW" "")
[[ -z "$got" ]] \
    && ok "NEGATIVE: _idle_skeptic_orphaned against the unfixed tree → caller killed" \
    || bad "NEGATIVE: unfixed tree survived (got '$got') — this guard passes regardless of the code it reads"

PATH="$ORIG_PATH"

printf '\n%s\n' "-------------------------------------------"
printf 'PASS: %d   FAIL: %d\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "SOME TESTS FAILED" >&2
exit 1
