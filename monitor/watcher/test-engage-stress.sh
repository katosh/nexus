#!/usr/bin/env bash
# Seeded-pseudorandom stress iterations over the operator-engaged
# seed / attribution / corroboration logic (your-org/your-nexus#205,
# PR your-org/nexus-code#270).
#
# Run: SLOW_TESTS=1 bash monitor/watcher/test-engage-stress.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
# Gated behind SLOW_TESTS=1 (~90s wall-clock: ~630 _openg_observe
# calls across the seeded runs + determinism replays + a real-time
# expiry churn loop — fork-bound, slower on loaded shared hosts).
#
# Complements test-engage-long-exchange.sh (scripted scenario) with
# RANDOMIZED event interleavings: for each seed in a FIXED list (never
# wall-clock — reruns are reproducible), bash's seeded $RANDOM draws a
# 40-cycle × 3-window schedule of events — static frames, answer
# renders, hashless busy fast-paths, operator submits, machine-stamped
# submits, garbled-redraw distortion, input-row-noise distortion — and
# the whole schedule is driven through the REAL `_openg_observe` with
# virtual time. After every observation these fail-closed invariants
# must hold, whatever the ordering:
#
#   I1 no fabrication — a mark (since>0) exists only for a window that
#      received at least one OPERATOR submit event earlier in its life.
#      Distortion, machine pastes, busy streams, and content churn in
#      any combination must never conjure one.
#   I2 prompt_seen is monotonic — attribution never un-consumes a
#      submit stamp.
#   I3 marked rows carry a hook-trigger src (submit / submit-after-wrap)
#      — no pane-transition-era seed can resurface.
#
# Plus: same-seed DETERMINISM (an identical schedule replayed into a
# fresh state dir produces byte-identical state files — no hidden
# wall-clock or ordering sensitivity in the bookkeeping), a positive
# control (the operator-driven window does get marked in at least one
# seed, so the invariants are not vacuously green), and a repeated
# seed→expire→re-engage churn loop against the real `_openg_marked`
# clock (state-file residue across episodes would surface here).
#
# Note: bash's $RANDOM sequence is stable for a given bash version but
# may differ across versions — the SCHEDULES can vary between machines,
# the INVARIANTS are universal, and the determinism check replays the
# same materialized schedule file, so the test is sound everywhere.
# (Replay runs on a two-seed subset purely for wall-clock economy.)

set -uo pipefail

if [ "${SLOW_TESTS:-0}" != "1" ]; then
    echo "skipped: $(basename "$0") (set SLOW_TESTS=1 to enable; ~30s wall-clock)"
    exit 0
fi

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBE="$_test_dir/_idle_probe.sh"

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
assert_rc() {
    local label="$1" got="$2" want="$3"
    assert_eq "$label" "rc=$got" "rc=$want"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# No-op tmux shadow: nothing in the exercised probe paths consults
# tmux, but a stray helper call must never reach the LIVE server.
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/tmux"
chmod +x "$WORK/bin/tmux"

SEEDS=(7 23 91 1205 20260612)
REPLAY_SEEDS=" 7 20260612 "   # determinism replay subset (space-delimited)
CYCLES=30
WINDOWS=(wmix wmach wquiet)   # operator-driven / machine-pastes-only / no-submits

# Draw a full schedule for one seed: `<cycle>\t<window>\t<event>` rows.
# Per-window event tables differ so each window exercises its regime:
#   wmix   — everything, incl. operator submits (the only markable one)
#   wmach  — submits arrive but every one is machine-stamped
#   wquiet — no submits at all, distortion-heavy (pure bystander)
gen_schedule() {
    local seed="$1" out="$2" cyc w r ev
    RANDOM="$seed"
    : > "$out"
    for (( cyc = 0; cyc < CYCLES; cyc++ )); do
        for w in "${WINDOWS[@]}"; do
            r=$(( RANDOM % 15 ))
            case "$w" in
                wmix)
                    case "$r" in
                        [0-2]) ev=static ;;  [3-5]) ev=answer ;;
                        [6-7]) ev=busy ;;    [8-9]) ev=opsub ;;
                        10)    ev=msub ;;    1[1-2]) ev=garble ;;
                        *)     ev=noise ;;
                    esac ;;
                wmach)
                    case "$r" in
                        [0-3]) ev=static ;;  [4-6]) ev=answer ;;
                        [7-8]) ev=busy ;;    9|10)  ev=msub ;;
                        1[1-2]) ev=garble ;; *)     ev=noise ;;
                    esac ;;
                wquiet)
                    case "$r" in
                        [0-3]) ev=static ;;  [4-5]) ev=answer ;;
                        [6-7]) ev=busy ;;    [8-9]|1[0-2]) ev=garble ;;
                        *)     ev=noise ;;
                    esac ;;
            esac
            printf '%s\t%s\t%s\n' "$cyc" "$w" "$ev" >> "$out"
        done
    done
}

# The per-seed driver: replays a schedule through the real
# _openg_observe under virtual time, checking I1–I3 after every
# observation. Runs in its own bash so each seed gets a pristine
# sourced probe; prints VIOLATION lines (none expected), then
# CYCLES_DONE= and WMIX_EVER_MARKED= sentinels.
cat > "$WORK/run-seed.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
STATE_DIR="$1"; SCHEDULE="$2"; PROBE="$3"
export STATE_DIR
mkdir -p "$STATE_DIR/user-prompt"
: > "$STATE_DIR/action-log.jsonl"
source "$PROBE"

BASE=1750000000   # fixed virtual epoch — determinism needs no wall-clock
declare -A cur_hash prev_ps ever_op
for w in wmix wmach wquiet; do
    cur_hash[$w]="init-$w"; prev_ps[$w]=0; ever_op[$w]=0
done
viol=0 n=0 wmix_marked=0

while IFS=$'\t' read -r cyc w ev; do
    vnow=$(( BASE + cyc * 60 ))
    state=idle hash="${cur_hash[$w]}"
    case "$ev" in
        static) ;;                            # same frame, hash frozen
        answer) cur_hash[$w]="ans-$cyc-$w"; hash="${cur_hash[$w]}" ;;
        busy)   state=busy; hash="" ;;        # heartbeat fast path: no capture
        opsub)  printf '%s\t%s\n' "$vnow" sess > "$STATE_DIR/user-prompt/$w"
                ever_op[$w]=1 ;;
        msub)   printf '%s\t%s\t%s\n' "$w" "$vnow" paste >> "$STATE_DIR/machine-input.tsv"
                printf '%s\t%s\n' "$vnow" sess > "$STATE_DIR/user-prompt/$w" ;;
        garble) cur_hash[$w]="garb-$cyc-$w"; hash="${cur_hash[$w]}" ;;
        noise)  state=autosuggest-only ;;     # ghost churn, hash frozen
    esac
    _openg_observe "$w" "$state" "$hash" "$vnow" 1800
    n=$(( n + 1 ))

    row=$(awk -F'\t' -v w="$w" '$1 == w { print; exit }' \
        "$STATE_DIR/operator-engaged.tsv" 2>/dev/null)
    if [[ -n "$row" ]]; then
        IFS=$'\t' read -r _w since _last ps src _rem <<<"$row"
        [[ "$since" =~ ^[0-9]+$ ]] || since=0
        [[ "$ps"    =~ ^[0-9]+$ ]] || ps=0
        if (( since > 0 )) && (( ever_op[$w] == 0 )); then
            echo "VIOLATION I1-fabrication cyc=$cyc w=$w ev=$ev row=[$row]"; viol=1
        fi
        if (( ps < prev_ps[$w] )); then
            echo "VIOLATION I2-prompt_seen-regression cyc=$cyc w=$w $ps < ${prev_ps[$w]}"; viol=1
        fi
        prev_ps[$w]=$ps
        if (( since > 0 )) && [[ "$src" != submit && "$src" != submit-after-wrap ]]; then
            echo "VIOLATION I3-src cyc=$cyc w=$w src=$src"; viol=1
        fi
        [[ "$_w" == wmix ]] && (( since > 0 )) && wmix_marked=1
    fi
done < "$SCHEDULE"

echo "CYCLES_DONE=$n"
echo "WMIX_EVER_MARKED=$wmix_marked"
exit $viol
DRIVER
chmod +x "$WORK/run-seed.sh"

echo "=== seeded schedules: invariants hold under ${#SEEDS[@]} × $CYCLES-cycle random interleavings ==="
total_marked=0
for seed in "${SEEDS[@]}"; do
    sched="$WORK/schedule-$seed.tsv"
    gen_schedule "$seed" "$sched"

    out=$(PATH="$WORK/bin:$PATH" bash "$WORK/run-seed.sh" \
        "$WORK/seed$seed-run1" "$sched" "$PROBE" 2>&1)
    rc=$?
    assert_rc "seed $seed: no invariant violations" "$rc" 0
    if grep -q 'VIOLATION' <<<"$out"; then
        grep 'VIOLATION' <<<"$out" | sed 's/^/         /' >&2
    fi
    assert_eq "seed $seed: every scheduled cycle observed" \
        "$(sed -n 's/^CYCLES_DONE=//p' <<<"$out")" "$(( CYCLES * ${#WINDOWS[@]} ))"
    marked=$(sed -n 's/^WMIX_EVER_MARKED=//p' <<<"$out")
    total_marked=$(( total_marked + ${marked:-0} ))

    # Same-seed determinism: replay the identical schedule into a fresh
    # state dir; every state file must come out byte-identical (no
    # wall-clock leakage, no ordering sensitivity in the bookkeeping).
    if [[ "$REPLAY_SEEDS" == *" $seed "* ]]; then
        PATH="$WORK/bin:$PATH" bash "$WORK/run-seed.sh" \
            "$WORK/seed$seed-run2" "$sched" "$PROBE" >/dev/null 2>&1
        if diff -r "$WORK/seed$seed-run1" "$WORK/seed$seed-run2" >/dev/null 2>&1; then
            printf '  PASS: seed %s: replay is byte-identical\n' "$seed"; PASS=$(( PASS + 1 ))
        else
            printf '  FAIL: seed %s: replay diverged:\n' "$seed" >&2
            diff -r "$WORK/seed$seed-run1" "$WORK/seed$seed-run2" 2>&1 | head -10 | sed 's/^/         /' >&2
            FAIL=$(( FAIL + 1 ))
        fi
    fi
done

# Positive control: with 5 seeds × ~5 operator submits each, at least
# one corroborated wmix mark must have formed — otherwise the I1/I3
# checks above never exercised the marked branch and the suite would
# be green by vacuity.
if (( total_marked >= 1 )); then
    printf '  PASS: positive control — wmix marked in %d/%d seeds\n' \
        "$total_marked" "${#SEEDS[@]}"; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: positive control — no seed ever marked wmix; invariants vacuous\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- repeated seed→expire→re-engage churn (real clock) ---------------------
#
# Five back-to-back engagement episodes on ONE window against the real
# `_openg_marked` wall-clock: each round submits (corroborated by a
# fresh answer hash), must classify marked, then must LAPSE once the
# pane sits static past a 1 s change TTL. Residue from a prior episode
# (stale change stamp, unconsumed prompt, lingering since/last) would
# break a later round.

echo '=== churn: 5 × (engage → expire) rounds on one window ==='
CHURN_DIR="$WORK/churn-state"
mkdir -p "$CHURN_DIR/user-prompt"
: > "$CHURN_DIR/action-log.jsonl"

churn_call() {  # run a probe expression against CHURN_DIR; rc in CHURN_RC
    PATH="$WORK/bin:$PATH" bash -c "
        set -uo pipefail
        STATE_DIR='$CHURN_DIR'
        export STATE_DIR
        source '$PROBE'
        $*
    " >/dev/null 2>&1
    CHURN_RC=$?
}

for round in 1 2 3 4 5; do
    now=$(date +%s)
    printf '%s\t%s\n' "$now" sess > "$CHURN_DIR/user-prompt/churn"
    churn_call "_openg_observe churn idle round-$round-hash $now 1800"
    churn_call "_openg_marked churn"
    assert_rc "churn round $round: engaged after corroborated submit" "$CHURN_RC" 0
    sleep 2
    churn_call "MONITOR_OPERATOR_ENGAGED_CHANGE_TTL_SECONDS=1 _openg_marked churn"
    assert_rc "churn round $round: lapsed once static past TTL" "$CHURN_RC" 1
done

# ---- summary ----------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
