#!/usr/bin/env bash
# Hermetic unit tests for the silent-watcher hardening (nexus-code#236).
#
# Covers the four failure modes that let a heartbeating watcher go silently
# undetected on 2026-06-18, and the operator's reports/worktree confounder:
#
#   1. BOUNDED, NOISE-FREE snapshot — snapshot_local stays O(1)-ish under a
#      simulated 200-worktree / 2000-report load (git off by default), and a
#      report rewrite (mtime churn) does NOT change the change-detection
#      snapshot, while a NEW final report DOES (signal preserved). A budgeted
#      git scan that overruns degrades to a stable sentinel, never a stall.
#   2. LOUD + recovered paste delivery — _emit_delivery_fail tracks
#      consecutive failures, ignores rc=2 (target-missing = orchestrator path),
#      escalates LOUDLY, and self-heals past the limit. _emit_delivery_ok
#      resets.
#   3. EMIT-FUNCTIONAL liveness — _watcher_emit_functional flags a
#      heartbeat-fresh-but-emit-cycle-stale watcher as DEAD, and the real
#      watcher-supervise-tick.sh exits non-zero for it (end-to-end).
#   4. STORM-PROOF recovery — _watcher_self_heal_restart honours the master
#      switch, the restart cooldown, and the loop guard (never storms), and
#      the functional_check handler only self-heals on the WATCHER-FAULT
#      (delivery-stale) case, never the orchestrator-fault one.
#
# Hand-rolled harness (matches test-lib.sh): mock externals as bash
# functions, extract the main.sh functions under test by name, stub the
# version-restart guards so each branch is exercised deterministically.
#
# Run: bash monitor/watcher/test-watcher-robustness.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAIN_SH="$_test_dir/main.sh"
LIB_SH="$_test_dir/_lib.sh"
SUPERVISE_TICK="$_test_dir/../watcher-supervise-tick.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq()       { local v="${2:0:60}"; [[ "$2" == "$3" ]] && pass "$1 (=${v})" || fail "$1: got '${2:0:200}' want '${3:0:200}'"; }
assert_ne()       { [[ "$2" != "$3" ]] && pass "$1" || fail "$1: '$2' should differ from '$3'"; }
assert_contains() { [[ "$2" == *"$3"* ]] && pass "$1" || fail "$1: '$2' missing '$3'"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] && pass "$1" || fail "$1: '$2' should NOT contain '$3'"; }
assert_rc()       { assert_eq "$1" "$2" "$3"; }

# Extract a top-level shell function from a file by name (no `^}` may appear
# mid-body — verified for all functions under test).
_extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }

# ---------------------------------------------------------------------------
echo '=== mode #1: bounded, noise-free snapshot_local ==='

# Mock tmux: a fixed window list (the genuine local-state signal).
tmux() {
    case "$1 $2" in
        "list-windows -F")
            printf 'orchestrator bell=0\nworker-a bell=0\nworker-b bell=1\n' ;;
        *) return 0 ;;
    esac
}
export -f tmux 2>/dev/null || true

eval "$(_extract_fn "$MAIN_SH" snapshot_local)"
SNAPSHOT_LOCAL_FORMAT_TAG='# snapshot-format=v2 test'

ROOT=$(mktemp -d)
mkdir -p "$ROOT/reports" "$ROOT/work"
# 2000 reports (1900 final + 100 interim) + 200 git worktrees.
for i in $(seq 1 1900); do : > "$ROOT/reports/proj_2026-01-01_00-00-${i}_final.md"; done
for i in $(seq 1 100);  do : > "$ROOT/reports/proj_2026-01-01_00-00-${i}-interim.md"; done
for i in $(seq 1 200);  do mkdir -p "$ROOT/work/wt$i/.git"; done

export NEXUS_ROOT="$ROOT"
# Leave MONITOR_SNAPSHOT_GIT_ENABLED UNSET so the snapshot exercises the
# real `:-false` default (proves git is off WITHOUT an explicit override).
unset MONITOR_SNAPSHOT_GIT_ENABLED

_t0=$(date +%s)
snap=$(snapshot_local)
_t1=$(date +%s)
elapsed=$(( _t1 - _t0 ))

assert_contains "snapshot has format tag"        "$snap" "snapshot-format=v2"
assert_contains "snapshot has tmux section"      "$snap" "--- tmux ---"
assert_contains "snapshot has reports section"   "$snap" "--- reports ---"
assert_not_contains "git section OFF by default" "$snap" "--- git ---"
# No mtimes: reports lines are bare basenames, never '<name>.md <float>'.
if grep -qE '\.md [0-9]+\.[0-9]+$' <<<"$snap"; then
    fail "reports section must NOT embed mtimes"
else
    pass "reports section carries no mtimes (churn-proof)"
fi
assert_not_contains "interim reports excluded"   "$snap" "interim"
# Boundedness: 200 worktrees + 2000 reports must not take long with git off.
if (( elapsed <= 10 )); then pass "snapshot bounded under load (${elapsed}s <= 10s)"; \
    else fail "snapshot too slow under load: ${elapsed}s"; fi
# Reports section is a BOUNDED, deterministic summary, NOT a full dump:
#   * an exact total count of the 1900 FINAL reports (interim excluded), and
#   * at most N recent basenames (default 20) — never the 1900-line list
#     that flapped a giant per-poll diff at this corpus size (reportscan).
assert_contains "reports total count emitted" "$snap" "reports-total: 1900"
nlisted=$(printf '%s\n' "$snap" | grep -c '_final\.md$')
if (( nlisted >= 1 && nlisted <= 20 )); then \
    pass "reports listing bounded (${nlisted} basenames in [1,20], not the full 1900)"; \
    else fail "reports listing NOT bounded: ${nlisted} basenames emitted"; fi
# Stability: same file set -> byte-identical reports section across composes
# (deterministic LC_ALL=C sort + count). No flap == no spurious diff/emit.
snap2=$(snapshot_local)
assert_eq "snapshot deterministic across repeated composes (no flap)" "$snap" "$snap2"

echo '=== mode #1: confounder — report rewrite does NOT churn the snapshot ==='
base=$(snapshot_local)
sleep 1
# Rewrite an existing final report (mtime advances). Old behaviour embedded
# %T@, so this changed the snapshot -> a churn-only emit. New behaviour: no.
: > "$ROOT/reports/proj_2026-01-01_00-00-1_final.md"
after_rewrite=$(snapshot_local)
assert_eq "report rewrite leaves snapshot IDENTICAL (no churn emit)" \
    "$after_rewrite" "$base"
# A genuinely NEW final report IS a state transition -> snapshot changes.
: > "$ROOT/reports/proj_2026-01-01_00-00-NEW_final.md"
after_add=$(snapshot_local)
assert_ne "NEW final report DOES change snapshot (signal preserved)" \
    "$after_add" "$base"

echo '=== mode #1: git scan budget — overrun degrades to sentinel, no stall ==='
GITBIN=$(mktemp -d)
cat > "$GITBIN/git" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$GITBIN/git"
_t0=$(date +%s)
snap_g=$(PATH="$GITBIN:$PATH" MONITOR_SNAPSHOT_GIT_ENABLED=true \
    MONITOR_SNAPSHOT_GIT_TIMEOUT_SECONDS=1 snapshot_local 2>/dev/null)
_t1=$(date +%s); gelapsed=$(( _t1 - _t0 ))
assert_contains "git overrun emits stable sentinel" "$snap_g" "git listing unavailable"
if (( gelapsed <= 5 )); then pass "git scan bounded by budget (${gelapsed}s, loop NOT blocked)"; \
    else fail "git scan not bounded: ${gelapsed}s"; fi
rm -rf "$GITBIN" "$ROOT"
unset -f tmux

# ---------------------------------------------------------------------------
echo '=== mode #2: loud + recovered emit delivery ==='

STATE=$(mktemp -d)
export STATE_DIR="$STATE"
export TARGET="orchestrator"
export EMIT_LAST_DELIVERY_FILE="$STATE/watcher-last-emit-delivery.ts"
export EMIT_DELIVERY_FAIL_FILE="$STATE/watcher-emit-delivery-fail.count"
export MONITOR_EMIT_DELIVERY_FAIL_LIMIT=3

# Stubs: capture log + alert + self-heal invocations; no real restart.
LOGCAP="$STATE/log.txt"; : > "$LOGCAP"
log() { printf '%s\n' "$*" >> "$LOGCAP"; }
SELFHEAL_CALLS="$STATE/selfheal.txt"; : > "$SELFHEAL_CALLS"
_watcher_self_heal_restart() { printf '%s\n' "$1" >> "$SELFHEAL_CALLS"; }

eval "$(_extract_fn "$MAIN_SH" _watcher_alert)"
eval "$(_extract_fn "$MAIN_SH" _emit_delivery_ok)"
eval "$(_extract_fn "$MAIN_SH" _emit_delivery_fail)"

# rc=2 (target missing) is the orchestrator-respawn path — never a delivery fault.
_emit_delivery_fail 2
assert_no_count() { [[ ! -f "$EMIT_DELIVERY_FAIL_FILE" ]] && pass "$1" || fail "$1 (counter=$(cat "$EMIT_DELIVERY_FAIL_FILE"))"; }
assert_no_count "rc=2 does NOT count toward delivery failure"
assert_eq "rc=2 triggers no self-heal" "$(wc -l < "$SELFHEAL_CALLS")" "0"

# rc=3 failures: increment, alert loudly, self-heal AT the limit (not before).
_emit_delivery_fail 3
assert_eq "1st rc=3 failure counted"  "$(cat "$EMIT_DELIVERY_FAIL_FILE")" "1"
assert_eq "no self-heal before limit" "$(wc -l < "$SELFHEAL_CALLS")" "0"
_emit_delivery_fail 3
_emit_delivery_fail 3
assert_eq "3rd consecutive failure hits limit" "$(cat "$EMIT_DELIVERY_FAIL_FILE")" "3"
assert_eq "self-heal fired exactly once at limit" "$(wc -l < "$SELFHEAL_CALLS")" "1"
assert_contains "delivery failure alerted LOUDLY" "$(cat "$LOGCAP")" "ALERT"
assert_contains "alert names UNDELIVERED" "$(cat "$LOGCAP")" "UNDELIVERED"
# A success resets the counter and stamps the delivery clock.
_emit_delivery_ok
assert_no_count "success clears the failure counter"
[[ -f "$EMIT_LAST_DELIVERY_FILE" ]] && pass "success stamps delivery clock" || fail "delivery clock not stamped"
rm -rf "$STATE"
unset -f log _watcher_self_heal_restart _watcher_alert _emit_delivery_ok _emit_delivery_fail

# ---------------------------------------------------------------------------
echo '=== mode #3: HEARTBEAT is the proof-of-working-loop ==='
# Operator refinement (#317): the heartbeat is bumped ONLY at the end of a
# correct compose cycle — it doubles as the functional-liveness signal, and a
# deliberately-silent quiet workspace stays fresh (no emit-to-prove-liveness
# pressure). Verify the SHAPE of the implementation + the end-to-end behaviour.

# (a) No separate always-ticks heartbeat task (that's what masked the wedge).
if grep -qE '^_schedule_task[[:space:]]+heartbeat[[:space:]]' "$MAIN_SH"; then
    fail "a separate heartbeat task still exists (must be removed)"
else
    pass "no separate always-ticks heartbeat task"
fi
# (b) No leftover emit-functional machinery (folded into the heartbeat).
grep -q '_watcher_emit_functional' "$LIB_SH" \
    && fail "_watcher_emit_functional should be gone from _lib.sh" \
    || pass "_watcher_emit_functional removed (heartbeat IS the signal)"
grep -q 'watcher-last-emit-cycle' "$MAIN_SH" \
    && fail "stale watcher-last-emit-cycle reference remains" \
    || pass "no separate emit-cycle timestamp file"
# (c) compose_emit bumps the heartbeat at its cycle tail — AFTER the
#     emit-decision gate — so a QUIET (found-nothing) cycle, which falls
#     through that gate, still proves the loop works.
compose_body=$(_extract_fn "$MAIN_SH" _v2_task_compose_emit)
gate_ln=$(printf '%s\n' "$compose_body" | grep -nE 'local_diff.*\|\|.*gh_now' | head -1 | cut -d: -f1)
tail_bump_ln=$(printf '%s\n' "$compose_body" | grep -n 'bump_heartbeat' | tail -1 | cut -d: -f1)
if [[ -n "$gate_ln" && -n "$tail_bump_ln" ]] && (( tail_bump_ln > gate_ln )); then
    pass "compose_emit bumps heartbeat at cycle tail (quiet cycle still proves liveness)"
else
    fail "compose_emit must bump_heartbeat after the emit-decision gate (gate=$gate_ln bump=$tail_bump_ln)"
fi
# (d) The inline full-state / prelude renders inside compose_emit are
#     wall-clock bounded (skeptic #2c) — they probe O(workers) panes and run in
#     the heartbeat-bumping cycle, so an unbounded slow render could stale the
#     heartbeat and trip a false supervisor restart.
if grep -q '_run_bounded[^>]*render_full_state_snapshot' <<<"$compose_body" \
   && grep -q '_run_bounded[^>]*render_idle_prelude' <<<"$compose_body"; then
    pass "compose_emit inline renders are wall-clock bounded (can't stale the heartbeat)"
else
    fail "compose_emit inline render_full_state_snapshot/render_idle_prelude must be _run_bounded"
fi

echo '=== mode #3: DEAD-cutoff margin (skeptic #2 — no false restart on transient) ==='
SUPSD=$(mktemp -d)
# A real "live watcher" process whose argv0 ends in monitor/watcher/main.sh
# so _watcher_pid_is_live_watcher accepts it.
bash -c 'exec -a "/x/monitor/watcher/main.sh" sleep 90' &
FAKE_WATCHER=$!
sleep 0.3
write_hb() { printf 'pid=%d\nts=%s\ntarget=orchestrator\n' "$FAKE_WATCHER" "$1" > "$SUPSD/watcher-heartbeat"; }
run_tick() { NEXUS_STATE_DIR="$SUPSD" MONITOR_INTERVAL=60 bash "$SUPERVISE_TICK" 2>"$SUPSD/tick.err"; }

# (unit) _watcher_alive's DEAD-cutoff override: a heartbeat aged 350s — INSIDE
# the async-watchdog window (5×interval=300s < 350 < DEAD_CUTOFF≈420s) — must
# read stale-but-alive (rc 1) WITH the override, but DOWN (rc 2) at the default
# 300s cutoff. This is the zero-margin bug the skeptic caught, fixed.
. "$LIB_SH"
write_hb "x"; touch -d '350 seconds ago' "$SUPSD/watcher-heartbeat" 2>/dev/null || true
_watcher_alive "$SUPSD" 60;      assert_rc "350s @ default cutoff(300) => DOWN(2)" "$?" "2"
_watcher_alive "$SUPSD" 60 420;  assert_rc "350s @ override cutoff(420) => stale-but-alive(1)" "$?" "1"

# (e2e) Fresh heartbeat (loop completed a cycle recently) => alive. NO emit
# file needed — a quiet workspace that never emits is still ALIVE.
write_hb "$(date -Is)"; touch "$SUPSD/watcher-heartbeat"
run_tick; assert_rc "fresh heartbeat (quiet but working) => alive" "$?" "0"
# (e2e) Heartbeat aged INTO the watchdog margin (350s): the watcher's own
# watchdog heals a single transient stall before the supervisor restarts it.
write_hb "x"; touch -d '350 seconds ago' "$SUPSD/watcher-heartbeat" 2>/dev/null || true
run_tick; assert_rc "heartbeat in watchdog margin (350s) => still alive (no false restart)" "$?" "0"
# (e2e) Persistent wedge past DEAD_CUTOFF => DOWN. The 8-min-silence fix.
write_hb "old"; touch -d '1 hour ago' "$SUPSD/watcher-heartbeat" 2>/dev/null || true
run_tick; rc=$?
assert_rc "persistent wedge (1h) => DOWN" "$rc" "1"
assert_contains "DOWN message names the watcher" "$(cat "$SUPSD/tick.err")" "watcher DOWN"
kill "$FAKE_WATCHER" 2>/dev/null; wait "$FAKE_WATCHER" 2>/dev/null
rm -rf "$SUPSD"

# ---------------------------------------------------------------------------
echo '=== mode #4: storm-proof self-heal chokepoint ==='
HS=$(mktemp -d)
export STATE_DIR="$HS"
export VERSION_STATE_DIR="$HS/version"; mkdir -p "$VERSION_STATE_DIR"
export TARGET="orchestrator"
export LOGFILE="$HS/watcher.log"
export WATCHER_REVIVED_MARKER="$HS/watcher-revived"
_script_dir="$_test_dir"
export MONITOR_VERSION_RESTART_COOLDOWN_SECONDS=600

HSLOG="$HS/log.txt"; : > "$HSLOG"
log() { printf '%s\n' "$*" >> "$HSLOG"; }
command() { builtin command "$@"; }   # keep `command -v sandbox-notify` real (absent)
# Stub the version-restart guards so we drive each branch deterministically.
COOLDOWN_OK=0 GUARD_OK=0
_version_cooldown_ok() { return "$COOLDOWN_OK"; }
_version_self_guard_ok() { return "$GUARD_OK"; }
RESTART_CALLS="$HS/restart.txt"; : > "$RESTART_CALLS"
_version_restart_self() { printf 'restart %s\n' "$3" >> "$RESTART_CALLS"; return 0; }

eval "$(_extract_fn "$MAIN_SH" _watcher_alert)"
eval "$(_extract_fn "$MAIN_SH" _watcher_self_heal_restart)"

# (a) enabled + cooldown ok + guard ok => restart fires + revived marker.
COOLDOWN_OK=0; GUARD_OK=0
MONITOR_WATCHER_SELF_HEAL_ENABLED=true MONITOR_VERSION_SELF_RESTART=true \
    _watcher_self_heal_restart "test-fault"
assert_eq "self-heal restart fires when allowed" "$(wc -l < "$RESTART_CALLS")" "1"
[[ -f "$WATCHER_REVIVED_MARKER" ]] && pass "revived marker left for successor" || fail "no revived marker"

# (b) inside cooldown => suppressed (no storm).
: > "$RESTART_CALLS"
COOLDOWN_OK=1; GUARD_OK=0
MONITOR_WATCHER_SELF_HEAL_ENABLED=true MONITOR_VERSION_SELF_RESTART=true \
    _watcher_self_heal_restart "test-fault"
assert_eq "cooldown suppresses restart (no storm)" "$(wc -l < "$RESTART_CALLS")" "0"
assert_contains "cooldown suppression logged" "$(cat "$HSLOG")" "cooldown"

# (c) loop guard tripped => suppressed.
: > "$RESTART_CALLS"; : > "$HSLOG"
COOLDOWN_OK=0; GUARD_OK=1
MONITOR_WATCHER_SELF_HEAL_ENABLED=true MONITOR_VERSION_SELF_RESTART=true \
    _watcher_self_heal_restart "test-fault"
assert_eq "loop guard suppresses restart" "$(wc -l < "$RESTART_CALLS")" "0"
assert_contains "guard suppression logged" "$(cat "$HSLOG")" "guard"

# (d) master switch off => suppressed.
: > "$RESTART_CALLS"
COOLDOWN_OK=0; GUARD_OK=0
MONITOR_WATCHER_SELF_HEAL_ENABLED=false MONITOR_VERSION_SELF_RESTART=true \
    _watcher_self_heal_restart "test-fault"
assert_eq "self_heal_enabled=false suppresses restart" "$(wc -l < "$RESTART_CALLS")" "0"
unset -f command
rm -rf "$HS"

echo '=== mode #4: functional_check self-heals only on WATCHER-FAULT (loop-heartbeat re-aim) ==='
# Re-aimed (your-org/nexus-code quiet false-positive): a FIRED "stale"
# verdict only escalates to a watcher self-heal when there is POSITIVE
# evidence of a watcher fault — the loop-proof heartbeat is STALE
# (`_watcher_alive` >= 2) OR emits are generated-but-stuck (delivery-fail
# counter > 0). A merely STALE delivery clock on an otherwise-alive loop is
# a QUIET workspace, NOT a fault, and must NOT revive.
FC=$(mktemp -d)
export STATE_DIR="$FC"
export DIFF_DIR="$FC/diffs"; mkdir -p "$DIFF_DIR"
export REPO="owner/repo"; export BOT_LOGIN="bot"
export FUNCTIONAL_CHECK_STATE_FILE="$FC/fc.tsv"
export EMIT_LAST_DELIVERY_FILE="$FC/watcher-last-emit-delivery.ts"
export EMIT_DELIVERY_FAIL_FILE="$FC/watcher-emit-delivery-fail.count"
export INTERVAL=60
export MONITOR_FUNCTIONAL_SLA_SECONDS=600
export MONITOR_FUNCTIONAL_MAX_EMITS=5

FCLOG="$FC/log.txt"; : > "$FCLOG"
log() { printf '%s\n' "$*" >> "$FCLOG"; }
sandbox-notify() { :; }
# Force the decide step to report a stale verdict (the FIRED precondition).
_functional_check_decide() { echo "stale reason=all-emits-unprocessed-past-SLA n_emits=1 n_processed=0 n_stale=1 sla=600s"; return 0; }
# Shim the loop-liveness primitive — return the rc the scenario sets.
# 0=fresh(alive) 1=aging(alive) 2=DEAD 3=no-heartbeat.
FAKE_ALIVE_RC=0
_watcher_alive() { return "$FAKE_ALIVE_RC"; }
FCHEAL="$FC/heal.txt"; : > "$FCHEAL"
_watcher_self_heal_restart() { printf '%s\n' "$1" >> "$FCHEAL"; }

# The real (pure) classifier lives in _functional_check.sh — source it so
# `_v2_task_functional_check` exercises the REAL re-aimed decision.
# shellcheck source=_functional_check.sh
source "$_test_dir/_functional_check.sh"
# Re-stub decide AFTER sourcing (the source defines the real one).
_functional_check_decide() { echo "stale reason=all-emits-unprocessed-past-SLA n_emits=1 n_processed=0 n_stale=1 sla=600s"; return 0; }
eval "$(_extract_fn "$MAIN_SH" _v2_task_functional_check)"

reset_fc() { : > "$FCHEAL"; : > "$FCLOG"; rm -f "$EMIT_DELIVERY_FAIL_FILE"; FAKE_ALIVE_RC=0; }

# (A) Delivery FRESH, loop alive, no fails => orchestrator-fault => NO restart.
reset_fc
printf '%s\n' "$(date +%s)" > "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "A: fresh delivery (orch-fault) => NO self-heal" "$(wc -l < "$FCHEAL")" "0"
assert_contains "A: logged NOT a watcher fault" "$(cat "$FCLOG")" "NOT a watcher fault"

# (B) Delivery STALE, loop alive (fresh heartbeat), no fails => QUIET => NO
# restart. THIS is the false-positive the re-aim kills (was: self-heal).
reset_fc
printf '%s\n' "$(( $(date +%s) - 9999 ))" > "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "B: stale delivery + alive loop (QUIET) => NO self-heal" "$(wc -l < "$FCHEAL")" "0"
assert_contains "B: logged quiet (not watcher fault)" "$(cat "$FCLOG")" "quiet"

# (C) No delivery clock, loop alive, no fails => QUIET => NO restart
# (a never-emitted quiet workspace must not be read as a wedge).
reset_fc
rm -f "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "C: absent delivery clock + alive loop => NO self-heal" "$(wc -l < "$FCHEAL")" "0"

# (D) REAL WEDGE — loop-proof heartbeat DEAD (rc=2) => watcher-fault => restart,
# regardless of how the delivery clock looks.
reset_fc
FAKE_ALIVE_RC=2
printf '%s\n' "$(( $(date +%s) - 9999 ))" > "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "D: loop heartbeat DEAD (rc=2) => self-heal fires" "$(wc -l < "$FCHEAL")" "1"
assert_contains "D: logged WATCHER-FAULT" "$(cat "$FCLOG")" "WATCHER-FAULT"

# (E) REAL WEDGE — emits generated-but-stuck (delivery-fail counter > 0) =>
# watcher-fault => restart, even with a fresh-looking loop heartbeat.
reset_fc
FAKE_ALIVE_RC=0
printf '3\n' > "$EMIT_DELIVERY_FAIL_FILE"
printf '%s\n' "$(( $(date +%s) - 9999 ))" > "$EMIT_LAST_DELIVERY_FILE"
_v2_task_functional_check
assert_eq "E: emits-generated-but-stuck (fail>0) => self-heal fires" "$(wc -l < "$FCHEAL")" "1"
assert_contains "E: logged WATCHER-FAULT" "$(cat "$FCLOG")" "WATCHER-FAULT"

unset -f _watcher_alive _watcher_self_heal_restart log _functional_check_decide
rm -rf "$FC"

# ---------------------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
