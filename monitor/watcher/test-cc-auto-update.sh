#!/usr/bin/env bash
# Unit tests for the autonomous daily Claude Code update routine:
# the watcher trigger (`monitor/watcher/_cc_auto_update.sh`) and the
# decision-branch executor (`monitor/cc-auto-update-apply.sh`).
#
# Nothing here touches the live workspace: time is injected via
# NEXUS_TEST_NOW, the registry fetch via the fetch_cmd indirection,
# tmux via a function override, and every external mechanism of the
# apply script (install, watcher restart, spawn, pane-state, claude
# binary, gh, mint) via its CC_AUTO_* command-override env vars. No
# live bump, no live restart, no network.
#
# …with ONE historical exception, now closed. `notify()` in
# cc-auto-update-apply.sh was NOT among the overridden mechanisms, so every
# decision branch exercised below rang a REAL terminal bell in the operator's
# live tmux. Measured 2026-07-24: ~3.4 bells/second, ~250 transient `•bell`
# windows per 73 seconds — the dominant residual source of the bell flood.
# NEXUS_NOTIFY_QUIET=1 is the hard off-switch honoured by
# monitor/notifywrap/sandbox-notify; run-tests.sh exports it suite-wide, and
# the export below covers a DIRECT `bash monitor/watcher/test-cc-auto-update.sh`.
#
# Cases:
#   trigger / scheduling
#     1.  fire-epoch math: 04:00 resolves to today's 04:00 local.
#     2.  due: before fire time → not due.
#     3.  due: after fire time, no stamp → due.
#     4.  due: stamped today → not due; stamped yesterday → due.
#     5.  tick before fire time → no fetch, no spawn.
#     6.  tick due + registry says current → stamps day, no spawn.
#     7.  tick due + registry unreachable → NO stamp (retries), no spawn.
#     8.  tick due + newer → renders prompt (candidate substituted),
#         spawns evaluator, stamps day, audit row `spawned`, marks the
#         candidate surfaced (orchestrator-nag consumed).
#     9.  tick twice same day → second is a no-op (idempotency).
#    10.  evaluator window alive → no spawn, day consumed, audit row.
#    11.  awaiting-operator guard: same candidate with last-eval
#         decision=block → skip; NEWER candidate → spawns.
#   restart-pending reconciliation (runs on EVERY tick, independent of
#   the registry decide AND the daily-due gate)
#    R1.  running binary OLDER than installed (valid pin) → FIRES the
#         detached watchdog-mediated restart-orchestrator hand-off with
#         --candidate = the installed/effective version; audit row.
#    R2.  running == installed → does NOT fire (no needless kill).
#    R3.  running AHEAD of installed (operator prerelease) → no fire.
#    R4.  no valid session pin → no fire (a kill would cold-spawn).
#    R5.  unreadable running version (no "version" stamp) → no fire.
#    R6.  single-flight: armed watchdog marker present → no fire.
#    R7.  single-flight: a live detached restart pid → no fire.
#    R8.  cooldown: a second immediate call does NOT re-fire (no loop on
#         a failed attempt).
#    R9.  WIRING: a NOT-due tick (before fire time) still reconciles —
#         proving it runs ahead of the daily-due gate.
#   apply: safe branch (the restart is now DETACHED — `safe` bumps then
#   hands the idle-wait → kill off to the `restart-orchestrator` verb)
#    12.  full safe run, INLINE detach (CC_AUTO_RESTART_INLINE=1): pin
#         written, install + verify + watcher restart + watchdog spawn +
#         armed-wait + orchestrator kill in order; safe records
#         safe-bumped-restart-handoff, the (idle) restart records
#         safe-bumped-restarted; rc 0.
#    12b. real DETACHED restart (setsid re-exec, no inline): safe returns
#         rc 0 + handoff promptly (does NOT block on the idle-wait); the
#         disowned child then arms + kills + records safe-bumped-restarted.
#    13.  refused without --surfaces-clear / without gate evidence /
#         with a red gate log → rc 3, pin untouched.
#    14.  stale gate evidence (older than max age) → rc 3.
#    15.  install fails → pin rolled back, no watcher restart, no kill,
#         rc 4.
#    16.  binary verify mismatch → pin rolled back, rc 5.
#    17.  already-pinned candidate → no-op rc 0 (no install).
#    18.  safe foreground pre-flight: stale/absent session pin → bump
#         stands, restart NOT even detached, NO kill, rc 21.
#   apply: restart-orchestrator verb (the detached second half, tested
#   directly + synchronously)
#    19.  watchdog never arms → NO kill, rc 22.
#    20.  orchestrator busy past the idle cap → FORCE-restart: kill
#         issued, outcome safe-bumped-restart-forced, rc 0 (the operator
#         decision — replaces the old rc-20 defer).
#    20b. pane-state UNREADABLE (empty stdout + exit 2 — the 2026-06-16
#         Step-5b bug repro) → fail loud, NO kill, NO wait, rc 23.
#    20c. target window unresolvable to a tmux index → fail loud before
#         any pane-state poll, NO kill, rc 23.
#    20d. `state=empty` valid transient verdict → keeps WAITING (not
#         abort-23 mid-wait), but an ALL-empty wait never positively
#         resolved the pane, so the cap REFUSES the force and aborts
#         loud (rc 23, no kill) — nexus-code#514 item 3.
#    20d2. busy once then empty → resolved_seen latched → cap forces
#         (rc 0), the operator decision preserved for resolved panes.
#    E1.  Monitor-handle working-background (no bg_cpu=) is a TURN
#         BOUNDARY → clean, non-forced restart (nexus-code#514: a
#         Monitor-holding orchestrator can never emit literal `idle`).
#    E2.  shell-driven working-background (bg_cpu= present) is NOT
#         eligible (live fire-and-forget child) → waits, forces at cap.
#   restart hold (nexus-code#513)
#    H1.  active hold suppresses the reconcile; audit row once per hold.
#    H2.  TTL-expired hold no longer suppresses.
#    H3.  until_version holds its candidate; newer effective re-arms.
#    H4.  hold / hold-status / unhold verb round-trip, audited.
#    H5.  detached restart honours a pre-existing hold (rc 25, no kill).
#    H6.  SIGTERM'd detached restart WRITES the hold (abort stays aborted).
#   deployment gate (nexus-code#512)
#    G1.  open restart-path PR → defer (rc 30, nothing mutated).
#    G2.  PR probe failure → defer (fail-safe), distinct detail.
#    G3.  live agent windows > max → defer; infra windows exempt.
#    G3b. windows ≤ max → proceeds, count recorded in the apply record.
#    G4.  duplicate watcher groups post-restart → invariant rc 31, no 5b.
#    20e. INDEX re-resolved every poll (not cached): orchestrator moves
#         3→2 mid-wait, probe follows the new index then kills (rc 0) —
#         the renumber-windows hardening.
#    20f. orchestrator already respawned onto the candidate on its own
#         (candidate-stamped transcript record) → re-validate NO-OP, NO
#         kill, rc 24.
#    20g. session pin goes stale before the detached kill → abort, NO
#         kill, rc 21 (the fire-time re-validation).
#   apply: compat-pr branch
#    21.  auto with exactly one open cc-compat PR → comments on it,
#         outcome compat-pr-commented, rc 0.
#    22.  auto with none → rc 10, no comment.
#    23.  auto with several → rc 11, no comment.
#   apply: block branch
#    24.  block records outcome + reason, rc 0, pin untouched; the
#         daily guard then skips that candidate (ties 11 and 24).
#
# Run: bash monitor/watcher/test-cc-auto-update.sh

set -uo pipefail

# No real terminal bell from a test run — see the header note. Covers a direct
# `bash monitor/watcher/test-cc-auto-update.sh`; run-tests.sh exports it too.
export NEXUS_NOTIFY_QUIET=1

# HERMETIC ENV (your-org/nexus-code#655) — the FIFTH member of the class, and
# the first found by monitor/nexus-root-sensitivity.sh rather than by a human
# diffing the band.
#
# NEXUS_NOTIFY_QUIET=1 silences the BELL but does NOT silence the STATE WRITE:
# monitor/notifywrap/sandbox-notify takes its `(0) Hard off` branch and still
# calls `_nw_record "quiet" "suppress-quiet"`, which appends to
# ${NEXUS_NOTIFY_STATE_DIR:-$NEXUS_ROOT/monitor/.state}/notify-decisions.jsonl.
# cc-auto-update-apply.sh's notify() (:229) reaches that wrapper because
# locals-env.sh / bash_env.sh PATH-front $NEXUS_ROOT/monitor/notifywrap — so the
# R1 reconcile branch wrote five records into whatever root was inherited, with
# every one of the 82 assertions passing and rc=0. Measured twice, 2026-08-05,
# against a DECOY root.
#
# DESTINATION, stated precisely because the first write-up of this got it wrong:
# the five records landed in the DECOY, which is where the measurement pointed
# NEXUS_ROOT. An earlier version of this comment said "straight into the
# OPERATOR'S PRIMARY .state" — that was an inference, not an observation, and it
# is FALSE: the primary's notify-decisions.jsonl is unrotated back to
# 2026-07-24 and holds ZERO `quiet`-class records for 2026-08-05. No primary
# contamination occurred and nothing needs cleaning. The MECHANISM and the LEAK
# are real; only the claimed destination was not.
#
# That shape is invisible to both existing detectors: the assertions never
# move, so the `inherited-root` CI job stays green, and no `spawn` row is
# emitted, so the retrospective action-log audit cannot see it either.
#
# The suite pins NEXUS_ROOT at each of its six explicit spawn call sites and
# depends on the ambient value nowhere, so scrubbing is safe and is the same
# one-line remedy the other four members carry.
unset NEXUS_ROOT

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MONITOR_DIR=$(cd "$_script_dir/.." && pwd)
# shellcheck source=_cc_update.sh
source "$_script_dir/_cc_update.sh"
# shellcheck source=../_cc-version.sh
source "$MONITOR_DIR/_cc-version.sh"
# shellcheck source=_cc_auto_update.sh
source "$_script_dir/_cc_auto_update.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PKG="@anthropic-ai/claude-code"

# Deterministic local times for the due-check tests, independent of the
# host clock: build epochs from a fixed day via date -d.
DAY="2026-06-12"
epoch_at() { date -d "$DAY $1" +%s; }   # epoch_at 03:59

# ---- fixtures -----------------------------------------------------------

make_root() {
    # A miniature nexus root: package.json floor + the prompt template.
    local root="$1" floor="$2"
    mkdir -p "$root/monitor/.state"
    cat > "$root/package.json" <<EOF
{ "dependencies": { "@anthropic-ai/claude-code": "$floor" } }
EOF
    cp "$MONITOR_DIR/cc-auto-update-prompt.md" "$root/monitor/cc-auto-update-prompt.md"
    # The fire path resolves monitor.cc_auto_update.tracking_issue through this
    # (your-org/nexus-code#866); a real root always has it.
    cp "$MONITOR_DIR/issue-ref.sh" "$root/monitor/issue-ref.sh"
    cp "$MONITOR_DIR/cc-auto-update-watchdog-prompt.md" "$root/monitor/cc-auto-update-watchdog-prompt.md"
}

FETCH_VERSION=""
fetch_ok()   { printf '{"name":"%s","version":"%s"}\n' "$1" "$FETCH_VERSION"; }
fetch_fail() { return 22; }

# Spawn recorder stub: logs argv, simulates success.
make_spawn_stub() {
    local path="$1" log="$2"
    cat > "$path" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exit 0
EOF
    chmod +x "$path"
}

# Window-alive override default: nothing alive. Individual tests flip
# _WINDOW_ALIVE=1.
_WINDOW_ALIVE=0
_cc_auto_window_alive() { (( _WINDOW_ALIVE == 1 )); }
# tmux is only reached for dead-window cleanup; stub it out entirely.
tmux() { return 1; }

run_tick() {
    # run_tick <root> <fetch> — wraps the standard arg shape.
    _cc_auto_update_tick "$1" "$1/monitor/.state" "$PKG" "04:00" "$2" 5
}

# ===== trigger / scheduling ================================================

echo "== trigger / scheduling =="

# 1. fire-epoch math
got=$(_cc_auto_fire_epoch "$(epoch_at 12:00)" "04:00")
[[ "$got" == "$(epoch_at 04:00)" ]] \
    && pass "fire-epoch resolves to today's 04:00" \
    || fail "fire-epoch: got $got want $(epoch_at 04:00)"
_cc_auto_fire_epoch "$(epoch_at 12:00)" "25:99" >/dev/null 2>&1 \
    && fail "fire-epoch accepted malformed time" \
    || pass "fire-epoch rejects malformed time"

# 2-4. due-check
stamp="$WORK/stamp"
_cc_auto_due "$(epoch_at 03:59)" "04:00" "$stamp" \
    && fail "due before fire time" || pass "not due before fire time"
_cc_auto_due "$(epoch_at 04:00)" "04:00" "$stamp" \
    && pass "due at fire time with no stamp" || fail "not due at fire time"
_cc_auto_stamp "$stamp" "$(epoch_at 04:10)"
_cc_auto_due "$(epoch_at 12:00)" "04:00" "$stamp" \
    && fail "due despite today's stamp" || pass "stamped today → not due"
printf '2026-06-11\n' > "$stamp"
_cc_auto_due "$(epoch_at 12:00)" "04:00" "$stamp" \
    && pass "stamped yesterday → due (anacron catch-up)" \
    || fail "yesterday's stamp blocked the fire"

# 5. tick before fire time: no fetch, no spawn
ROOT="$WORK/r5"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
export CC_AUTO_SPAWN_CMD="$ROOT/spawn"
FETCH_CALLED="$ROOT/fetch-called"
fetch_recording() { touch "$FETCH_CALLED"; fetch_ok "$@"; }
NEXUS_TEST_NOW=$(epoch_at 03:00) run_tick "$ROOT" fetch_recording
[[ ! -e "$FETCH_CALLED" && ! -e "$SPAWN_LOG" ]] \
    && pass "tick before fire time touches nothing" \
    || fail "tick before fire time fetched or spawned"

# 6. due + current → stamp, no spawn
ROOT="$WORK/r6"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
FETCH_VERSION="2.1.150"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
day=$(cat "$ROOT/monitor/.state/cc-auto-update/last-fire-date" 2>/dev/null || true)
[[ "$day" == "$DAY" && ! -e "$SPAWN_LOG" ]] \
    && pass "current → day consumed, no spawn" \
    || fail "current: stamp=$day spawn=$( [[ -e $SPAWN_LOG ]] && echo yes || echo no )"

# 7. due + unreachable → NO stamp, no spawn
ROOT="$WORK/r7"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_fail
[[ ! -e "$ROOT/monitor/.state/cc-auto-update/last-fire-date" && ! -e "$SPAWN_LOG" ]] \
    && pass "unreachable → fail-safe retry (no stamp, no spawn)" \
    || fail "unreachable consumed the day or spawned"

# 8. due + newer → spawn with rendered prompt + stamp + audit + surfaced
ROOT="$WORK/r8"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
FETCH_VERSION="2.1.160"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
auto="$ROOT/monitor/.state/cc-auto-update"
if [[ -e "$SPAWN_LOG" ]] && grep -q -- "-n cc-auto-update" "$SPAWN_LOG"; then
    pass "newer → evaluator spawned"
else
    fail "newer → no spawn recorded"
fi
prompt="$auto/eval-prompt-$DAY.md"
if [[ -f "$prompt" ]] && grep -q "2\.1\.160" "$prompt" && ! grep -q '{{CANDIDATE}}' "$prompt"; then
    pass "prompt rendered with candidate substituted"
else
    fail "prompt missing or placeholders unrendered"
fi
# Routing invariant (your-org/your-nexus#242): the rendered prompt must
# pin surfacing to the implementation repo and leave no SURFACE_REPO
# placeholder unrendered. Any cc-update issue/PR goes to nexus-code, never
# the operator's asset repo.
if [[ -f "$prompt" ]] && grep -q "your-org/nexus-code" "$prompt" \
   && ! grep -q '{{SURFACE_REPO}}' "$prompt"; then
    pass "prompt pins surfacing to your-org/nexus-code (no asset-repo leak)"
else
    fail "prompt missing SURFACE_REPO routing or placeholder unrendered"
fi
grep -q "spawned" "$auto/decisions.tsv" 2>/dev/null \
    && pass "audit row 'spawned' written" || fail "no audit row"
[[ "$(cat "$ROOT/monitor/.state/cc-update-surfaced" 2>/dev/null)" == "2.1.160" ]] \
    && pass "candidate marked surfaced (manual-flow nag consumed)" \
    || fail "cc-update-surfaced not written"

# 9. second tick same day → no second spawn
NEXUS_TEST_NOW=$(epoch_at 06:00) run_tick "$ROOT" fetch_ok
[[ "$(wc -l < "$SPAWN_LOG")" == "1" ]] \
    && pass "same-day re-tick is a no-op" \
    || fail "spawned twice in one day"

# 10. evaluator window alive → no spawn, day consumed
ROOT="$WORK/r10"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
_WINDOW_ALIVE=1
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
_WINDOW_ALIVE=0
auto="$ROOT/monitor/.state/cc-auto-update"
if [[ ! -e "$SPAWN_LOG" ]] && grep -q "skipped-window-alive" "$auto/decisions.tsv" 2>/dev/null \
   && [[ -f "$auto/last-fire-date" ]]; then
    pass "live evaluator window blocks a second spawn"
else
    fail "window-alive guard failed"
fi

# 11. awaiting-operator guard
ROOT="$WORK/r11"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
printf 'candidate=2.1.160\ndecision=block\ndate=x\ndetail=red gate\n' > "$auto/last-eval"
FETCH_VERSION="2.1.160"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
[[ ! -e "$SPAWN_LOG" ]] && grep -q "skipped-awaiting-operator" "$auto/decisions.tsv" 2>/dev/null \
    && pass "blocked candidate not re-evaluated daily" \
    || fail "awaiting-operator guard failed"
# a NEWER candidate re-arms
rm -f "$auto/last-fire-date"
FETCH_VERSION="2.1.161"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
[[ -e "$SPAWN_LOG" ]] && grep -q "2\.1\.161" "$auto/eval-prompt-$DAY.md" \
    && pass "newer candidate re-arms past a blocked one" \
    || fail "newer candidate did not re-arm"

# ===== restart-pending reconciliation ======================================

echo "== restart-pending reconciliation =="

# make_reconcile_root <root> <floor> <local_pin|-> <running_version|->
# Mini root with a pinned session + transcript whose last "version" stamp
# is <running_version>, plus an apply stub that records the verb+args it
# is handed (so a test can assert the reconciliation handed off correctly
# WITHOUT running the real restart machinery).
RSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
make_reconcile_root() {
    local root="$1" floor="$2" pin="$3" running="$4"
    make_root "$root" "$floor"
    printf '%s\n' "$RSID" > "$root/monitor/.state/orchestrator-session-id"
    [[ "$pin" != "-" ]] && printf '%s\n' "$pin" > "$root/monitor/.state/cc-version-local"
    local slug proj
    slug=$(printf '%s' "$root" | sed 's|[^a-zA-Z0-9]|-|g')
    proj="$root/projects/$slug"
    mkdir -p "$proj"
    if [[ "$running" != "-" ]]; then
        printf '{"type":"assistant","version":"%s"}\n' "$running" > "$proj/$RSID.jsonl"
    else
        printf '{"type":"assistant"}\n' > "$proj/$RSID.jsonl"
    fi
    cat > "$root/apply" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$root/apply.log"
exit 0
EOF
    chmod +x "$root/apply"
}

# reconcile <root> — invoke the function in-process with the apply stub
# wired and the hand-off run INLINE (synchronous, deterministic).
reconcile() {
    local root="$1"
    CC_AUTO_PROJECTS_DIR="$root/projects" \
    CC_AUTO_APPLY_CMD="$root/apply" \
    CC_AUTO_RECONCILE_INLINE=1 \
        _cc_auto_reconcile_pending_restart "$root" "$root/monitor/.state" "$PKG"
}

# R1. running OLDER than installed (valid pin) → FIRES the hand-off.
ROOT="$WORK/rec1"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
reconcile "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
if [[ -f "$ROOT/apply.log" ]] \
   && grep -q "restart-orchestrator --candidate 2.1.195 --sid $RSID" "$ROOT/apply.log" \
   && grep -q $'\treconcile-fired\t' "$auto/decisions.tsv" 2>/dev/null; then
    pass "version-split (running<installed, valid pin) → fires restart-orchestrator hand-off"
else
    fail "reconcile did not fire on a genuine split: $(cat "$ROOT/apply.log" 2>/dev/null)"
fi

# R2. running == installed → no fire.
ROOT="$WORK/rec2"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.195"
reconcile "$ROOT"
[[ ! -e "$ROOT/apply.log" ]] \
    && pass "already on installed binary → no fire (no needless kill)" \
    || fail "reconcile fired when already current: $(cat "$ROOT/apply.log")"

# R3. running AHEAD of installed (operator prerelease) → no fire.
ROOT="$WORK/rec3"; make_reconcile_root "$ROOT" "2.1.195" "-" "2.1.200"
reconcile "$ROOT"
[[ ! -e "$ROOT/apply.log" ]] \
    && pass "orchestrator ahead of pin (older verdict) → no fire" \
    || fail "reconcile fired when running ahead of installed"

# R4. no valid session pin → no fire (a kill would cold-spawn).
ROOT="$WORK/rec4"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
rm -f "$ROOT/monitor/.state/orchestrator-session-id"
reconcile "$ROOT"
[[ ! -e "$ROOT/apply.log" ]] \
    && pass "no valid session pin → abort (no fire)" \
    || fail "reconcile fired without a valid pin"

# R5. unreadable running version (no "version" stamp) → no fire.
ROOT="$WORK/rec5"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "-"
reconcile "$ROOT"
[[ ! -e "$ROOT/apply.log" ]] \
    && pass "running version unreadable → no fire (never kill blind)" \
    || fail "reconcile fired with no readable running version"

# R6. single-flight: armed watchdog marker present → no fire.
ROOT="$WORK/rec6"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
touch "$ROOT/monitor/.state/restart-watchdog-armed"
reconcile "$ROOT"
[[ ! -e "$ROOT/apply.log" ]] \
    && pass "single-flight: armed watchdog marker blocks a second hand-off" \
    || fail "reconcile stacked a hand-off while one was armed"

# R7. single-flight: a live detached restart pid → no fire.
ROOT="$WORK/rec7"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
printf '%s\n' "$$" > "$ROOT/monitor/.state/restart-orchestrator.pid"   # this test shell — alive
reconcile "$ROOT"
[[ ! -e "$ROOT/apply.log" ]] \
    && pass "single-flight: a live detached restart pid blocks a second hand-off" \
    || fail "reconcile stacked a hand-off while a restart pid was live"

# R8. cooldown: a second immediate call does NOT re-fire.
ROOT="$WORK/rec8"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
reconcile "$ROOT"            # first fires
reconcile "$ROOT"            # second must be cooled down
if [[ -f "$ROOT/apply.log" ]] && (( $(wc -l < "$ROOT/apply.log") == 1 )); then
    pass "cooldown: a failed/in-flight attempt does not re-fire every tick"
else
    fail "cooldown did not gate the second attempt ($(wc -l < "$ROOT/apply.log" 2>/dev/null) hand-offs)"
fi

# R9. WIRING: a tick BEFORE fire time (not due) still reconciles — the
#     reconciliation must run ahead of the daily-due gate, not behind it.
ROOT="$WORK/rec9"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_PROJECTS_DIR="$ROOT/projects" CC_AUTO_APPLY_CMD="$ROOT/apply" \
CC_AUTO_RECONCILE_INLINE=1 CC_AUTO_SPAWN_CMD="$ROOT/spawn" \
    NEXUS_TEST_NOW=$(epoch_at 03:00) run_tick "$ROOT" fetch_ok
if [[ -f "$ROOT/apply.log" ]] \
   && grep -q "restart-orchestrator --candidate 2.1.195" "$ROOT/apply.log" \
   && [[ ! -e "$SPAWN_LOG" ]]; then
    pass "reconciliation runs ahead of the daily-due gate (fires on a not-due tick; evaluator not spawned)"
else
    fail "reconcile not wired ahead of the due gate: apply=$(cat "$ROOT/apply.log" 2>/dev/null) spawn=$( [[ -e $SPAWN_LOG ]] && echo yes || echo no )"
fi

# ===== apply: safe branch ==================================================

echo "== apply: safe =="

APPLY="$MONITOR_DIR/cc-auto-update-apply.sh"

# A full mock harness for the apply script. Builds a root with every
# CC_AUTO_* surface stubbed to record invocations into $root/calls.log.
make_apply_root() {
    local root="$1" floor="$2" candidate="$3"
    make_root "$root" "$floor"
    local calls="$root/calls.log"
    : > "$calls"
    # install stub
    cat > "$root/install" <<EOF
#!/usr/bin/env bash
echo "install" >> "$calls"
exit \${INSTALL_RC:-0}
EOF
    # watcher-restart stub
    cat > "$root/watcher-restart" <<EOF
#!/usr/bin/env bash
echo "watcher-restart" >> "$calls"
exit 0
EOF
    # spawn stub: records, then arms the watchdog marker (simulating
    # the watchdog reaching step 2 of its loop).
    cat > "$root/spawn" <<EOF
#!/usr/bin/env bash
echo "spawn \$*" >> "$calls"
date -Is > "$root/monitor/.state/restart-watchdog-armed"
exit 0
EOF
    # pane-state stub: idle orchestrator. Records the arg it receives so
    # tests can assert it is queried by INDEX (2), not by NAME — the
    # Step-5b bug was querying pane-state.sh (index-keyed) with the
    # window name, which returned empty stdout → 900s silent defer.
    cat > "$root/pane-state" <<EOF
#!/usr/bin/env bash
echo "pane-state \$*" >> "$calls"
echo "state=idle active=1 window=2 name=orchestrator"
EOF
    # claude stub: reports the candidate post-install
    cat > "$root/claude" <<EOF
#!/usr/bin/env bash
echo "$candidate (Claude Code)"
EOF
    # tmux stub: records calls. For the name→index resolver's format
    # (`#{window_name}|#{window_index}`) it maps orchestrator → index 2;
    # for the watchdog-existence probe (`#W`) it prints nothing (so the
    # stale-watchdog cleanup is skipped). kill-window etc. are no-ops.
    cat > "$root/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$calls"
case "\$1" in
  list-windows)
    case "\$*" in
      *'#{window_name}|#{window_index}'*) echo "orchestrator|2" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
    chmod +x "$root/install" "$root/watcher-restart" "$root/spawn" \
             "$root/pane-state" "$root/claude" "$root/tmux"
    # session pin + transcript
    local sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    printf '%s\n' "$sid" > "$root/monitor/.state/orchestrator-session-id"
    local slug projects
    slug=$(printf '%s' "$root" | sed 's|[^a-zA-Z0-9]|-|g')
    projects="$root/projects"
    mkdir -p "$projects/$slug"
    printf '{"version":"%s"}\n' "$floor" > "$projects/$slug/$sid.jsonl"
    # Green gate evidence mentioning the candidate. The scenario lines are
    # part of the fixture on purpose: apply.sh cross-checks a
    # `--surface-evidence <s>=gate` claim against the scenario names in
    # THIS file, so a bare "GATE GREEN" would (correctly) refuse them.
    {
        printf 'gating %s\n' "$candidate"
        printf -- '--- test-realmodel-idle-busy.sh ---\n'
        printf -- '--- test-realmodel-blocked-question.sh ---\n'
        printf -- '--- test-realmodel-autosuggest.sh ---\n'
        printf -- '--- test-realmodel-overlimit.sh ---\n'
        printf -- '--- test-realmodel-pretooluse-hook.sh ---\n'
        printf '=== GATE GREEN — candidate is safe to promote ===\n'
    } > "$root/gate.log"

    # Changelog evidence + ledger for the completeness rule. The fixture
    # is deliberately a TWO-release delta with a THIRD section at (not
    # above) the installed floor: the derived release set must be
    # {2.1.155, 2.1.160} — the installed release's own entries are not in
    # the delta and must not be demanded. Entry counts: .160 → 2,
    # .155 → 1, .150 → 1 (excluded).
    {
        printf '# Changelog\n\n'
        printf '## %s\n\n' "$candidate"
        printf -- '- Fixed the token counter wording on the spinner row\n'
        printf -- '- Added a new --teleport flag nobody here uses\n\n'
        printf '## 2.1.155\n\n'
        printf -- '- Changed the permission dialog chevron styling\n\n'
        printf '## %s\n\n' "$floor"
        printf -- '- Fixed something that predates this delta entirely\n'
    } > "$root/changelog.md"
    {
        printf -- '- Fixed the token counter wording on the spinner row | 2a, gate: counter unchanged\n'
        printf -- '- Added a new --teleport flag nobody here uses | no nexus surface\n'
        printf -- '- Changed the permission dialog chevron styling | 2b, gate: Case A literals intact\n'
    } > "$root/ledger.md"

    # UPSTREAM. apply.sh re-fetches the changelog itself rather than
    # trusting --changelog-evidence (a skeptic truncated a release from 19
    # entries to 5 in the supplied copy and was accepted at rc 0). The
    # fetch is stubbed here; by default it serves a byte-identical copy,
    # so the supplied-vs-upstream cross-check passes. Cases that need a
    # divergence edit ONE side.
    cp "$root/changelog.md" "$root/upstream-changelog.md"
    cat > "$root/fetch-changelog" <<EOF
#!/usr/bin/env bash
[[ -n "\${FETCH_RC:-}" ]] && exit "\$FETCH_RC"
cat "$root/upstream-changelog.md"
EOF
    chmod +x "$root/fetch-changelog"
}

# Changelog-completeness flags for the fixture above (GAP 2 of the
# cc-update rigor fix): every release in the derived delta carries an
# explicit dispositioned count, and the counts are cross-checked against
# the entries this script parses out of changelog.md.
cl_ok() {
    printf -- '--changelog-evidence %s/changelog.md --changelog-ledger %s/ledger.md --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2' \
        "$ROOT" "$ROOT"
}

# Per-surface evidence classes for apply.sh's labelling rule (the
# cc-update rigor fix). `--surfaces-clear` is no longer a bare
# attestation: every GUIDE surface 2a-2e needs an explicit evidence
# class, `empirical` additionally needs a stated negative control, and a
# `gate` claim is cross-checked against the scenario names in the gate
# log. This set is the well-formed baseline the non-refusal cases use.
#
# NOTE 2c is SPLIT into 2c-paste / 2c-vi: the paste-delivery path and the
# VI-insert guard are separate sub-claims, and the aggregate key `2c` is
# refused, so a driven half can no longer pay for an inert one.
SURF_OK="--surface-evidence 2a=gate --surface-evidence 2b=gate \
--surface-evidence 2c-paste=reachability --surface-evidence 2c-vi=reachability \
--surface-evidence 2d=gate --surface-evidence 2e=source-inspection"

# Common env for an apply invocation rooted at $1.
# CC_AUTO_GATE_PR_CMD=true → the deployment gate's PR probe (nexus-code
# #512) reports "no open restart-path PRs" (rc 0, no output); the gate's
# own behaviours are exercised explicitly in the G-cases below.
# CC_AUTO_INVARIANT_TRIES=1 bounds the post-restart invariant's settle
# loop so a fixture never waits out the production 5×2s window.
apply_env() {
    local root="$1"
    echo NEXUS_ROOT="$root" \
        CC_AUTO_INSTALL_CMD="$root/install" \
        CC_AUTO_WATCHER_RESTART_CMD="$root/watcher-restart" \
        CC_AUTO_SPAWN_CMD="$root/spawn" \
        CC_AUTO_PANE_STATE_CMD="$root/pane-state" \
        CC_AUTO_CLAUDE_BIN="$root/claude" \
        CC_AUTO_TMUX="$root/tmux" \
        CC_AUTO_PROJECTS_DIR="$root/projects" \
        CC_AUTO_GATE_PR_CMD=true \
        CC_AUTO_CHANGELOG_FETCH_CMD="$root/fetch-changelog" \
        CC_AUTO_INVARIANT_TRIES=1 \
        CC_AUTO_IDLE_WAIT_SECONDS=2 CC_AUTO_IDLE_POLL_SECONDS=1 \
        CC_AUTO_ARM_WAIT_SECONDS=2 CC_AUTO_ARM_POLL_SECONDS=1
}

# 12. full safe run, INLINE detach (synchronous, deterministic). The
#     idle pane → clean restart; CC_AUTO_RESTART_INLINE=1 runs the
#     hand-off in-process so the whole chain is observable in one shot.
ROOT="$WORK/a12"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) \
    > "$ROOT/out.log" 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )); then pass "safe run exits 0"; else fail "safe run rc=$rc: $(tail -3 "$ROOT/out.log")"; fi
[[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "local pin written to candidate" || fail "local pin wrong/missing"
seq=$(grep -v '^pane-state\|^tmux list-windows' "$ROOT/calls.log" | tr '\n' '|')
case "$seq" in
    "install|watcher-restart|spawn -n cc-restart-watchdog"*"|tmux kill-window -t orchestrator|")
        pass "safe ordering: install → watcher-restart → watchdog spawn → kill" ;;
    *)  fail "safe ordering wrong: $seq" ;;
esac
grep -q $'\tsafe-bumped-restart-handoff\t' "$auto/decisions.tsv" 2>/dev/null \
    && pass "safe records the restart hand-off" || fail "handoff outcome row missing"
grep -q $'\tsafe-bumped-restarted\t' "$auto/decisions.tsv" 2>/dev/null \
    && pass "idle restart records safe-bumped-restarted" || fail "restart outcome row missing"
# Regression guard for the 2026-06-16 Step-5b bug: pane-state.sh is
# index-keyed, so the idle probe MUST be invoked with the resolved
# INDEX (2), never the window NAME ("orchestrator").
if grep -q '^pane-state 2$' "$ROOT/calls.log" \
   && ! grep -q '^pane-state orchestrator' "$ROOT/calls.log"; then
    pass "idle probe queries pane-state by INDEX (2), not by name"
else
    fail "idle probe arg wrong: $(grep '^pane-state' "$ROOT/calls.log" | tr '\n' ',')"
fi

# 12b. REAL detached restart (setsid re-exec, no inline). The decoupling
#      from the evaluator's 600s ceiling is the whole point: with a BUSY
#      pane and a 4s idle-wait, safe must RETURN (rc 0 + handoff) in well
#      under that wait — proving it does NOT block on the idle-wait — while
#      the disowned child waits out the cap and FORCE-restarts on its own
#      (kill + safe-bumped-restart-forced).
ROOT="$WORK/a12b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
printf '#!/usr/bin/env bash\necho "state=busy active=1"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
# "Did not block on the idle-wait" is asserted as a HAPPENS-BEFORE, not as
# a wall-clock ceiling (the your-org/nexus-code#557 class). The old form
# required `elapsed < 3` against a 4 s wait; measured at CI fidelity
# (2 vCPU, 6-way oversubscription) this call took 0-2 s, i.e. it came
# within 1 s of failing on a run that was working perfectly. The ordering
# below carries the same claim with no timing margin at all: if `safe` had
# blocked through the wait, the kill would ALREADY be in calls.log by the
# time it returned. Observing the kill still absent at return, and only
# afterwards seeing it appear, is exactly what "detached" means.
#
# The wait is widened 4 s → 12 s purely to separate the two events. 12 s is
# sized on measurement, not taste: under the harshest contention reproduced
# for this class (1 vCPU, 8-way oversubscription) this foreground call took
# at most 3 s, so 12 s is a 4x runway. The old 4 s wait left only a 1 s gap
# against a 3 s worst case — which is exactly why the assertion went red on
# 7 of 16 such runs.
env $(apply_env "$ROOT") CC_AUTO_IDLE_WAIT_SECONDS=12 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) \
    > "$ROOT/out.log" 2>&1
rc=$?
# Sample the kill evidence AT the instant of return — before any polling.
kill_at_return=0
grep -q "kill-window -t orchestrator" "$ROOT/calls.log" 2>/dev/null && kill_at_return=1
fg_ok=0
(( rc == 0 )) && (( kill_at_return == 0 )) \
    && grep -q $'\tsafe-bumped-restart-handoff\t' "$auto/decisions.tsv" 2>/dev/null \
    && fg_ok=1
# Now let the detached child wait out the 12 s cap and force-kill on its
# own. 60 s of polling is 5x the runway; it breaks the instant the kill
# lands, so the margin is free on every green run. (This file deliberately
# does not source _test_helpers.sh — that would export
# NEXUS_PUBLIC_ENABLED=1 into the code under test — so it does not use
# th_deadline; a polled wait this generous does not need scaling.)
killed=0
for _ in $(seq 1 300); do
    if grep -q "kill-window -t orchestrator" "$ROOT/calls.log" 2>/dev/null \
       && grep -q $'\tsafe-bumped-restart-forced\t' "$auto/decisions.tsv" 2>/dev/null; then
        killed=1; break
    fi
    sleep 0.2
done
if (( fg_ok == 1 && killed == 1 )); then
    pass "safe detaches (rc 0 + handoff, kill not yet issued at return); child force-restarts on its own"
else
    fail "detach path wrong (rc=$rc kill_at_return=$kill_at_return fg_ok=$fg_ok killed=$killed): $(tail -2 "$ROOT/out.log")"
fi

# 13. refusals: no attestation / no evidence / red gate
ROOT="$WORK/a13"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "refused without --surfaces-clear (pin untouched)" \
    || fail "missing attestation not refused"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && pass "refused without gate evidence" || fail "missing evidence not refused"
printf 'gating 2.1.160\n=== GATE RED — do NOT promote this version ===\n' > "$ROOT/gate.log"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "refused on a RED gate log" || fail "red gate not refused"

# 13b. the labelling rule (cc-update rigor fix): --surfaces-clear alone is
#      no longer sufficient. These are the refusals that make the flag
#      mean something — five of six evaluation rounds passed a bare
#      attestation over a probe that could not distinguish pass from fail.
ROOT="$WORK/a13b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
pin_untouched() { [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]]; }

# (a) attestation with NO per-surface evidence at all → refused.
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    >/dev/null 2>&1
(( $? == 3 )) && pin_untouched \
    && pass "refused: --surfaces-clear with no --surface-evidence" \
    || fail "bare attestation still accepted"

# (b) partial coverage (2e missing) → refused. Every surface must be
#     labelled; silence about one is how a surface goes unexamined.
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=reachability --surface-evidence 2c-vi=reachability \
    --surface-evidence 2d=gate \
    >/dev/null 2>&1
(( $? == 3 )) && pin_untouched && pass "refused: a surface with no evidence class" \
    || fail "partial surface coverage accepted"

# (c) `empirical` WITHOUT a negative control → refused. THE headline
#     rule: the 2.1.216 and 2.1.222 rounds both labelled a reachability-
#     only VI probe `empirical`.
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=empirical --surface-evidence 2c-vi=reachability \
    --surface-evidence 2d=gate --surface-evidence 2e=source-inspection \
    >/dev/null 2>&1
(( $? == 3 )) && pin_untouched \
    && pass "refused: 'empirical' without a --negative-control" \
    || fail "unsubstantiated 'empirical' label accepted"

# (d) `empirical` WITH a negative control → accepted (rc 0). The rule
#     must not be a blanket ban on the label; it must be payable.
#     This is also the 2.1.224 shape done HONESTLY: the paste half is
#     driven with a control, the VI half is `reachability`, and the
#     audit row must derive the parent 2c as the WEAKER of the two.
ROOT="$WORK/a13d"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=empirical --surface-evidence 2c-vi=reachability \
    --surface-evidence 2d=gate --surface-evidence 2e=source-inspection \
    --negative-control '2c-paste=broke the delivery grep; probe went red' \
    $(cl_ok) >/dev/null 2>&1
rc=$?
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "accepted: 'empirical' backed by a stated negative control" \
    || fail "substantiated 'empirical' wrongly refused (rc=$rc)"
DEC="$ROOT/monitor/.state/cc-auto-update/decisions.tsv"
grep -q $'\tsurface-evidence\t' "$DEC" 2>/dev/null \
    && pass "surface-evidence labels recorded in the audit trail" \
    || fail "surface-evidence audit row missing"
# The composite's derived label is the WEAKEST sub-claim: 2c-paste is
# `empirical`, 2c-vi is `reachability`, so 2c reads `reachability`. A
# summary that let the driven half speak for the pair is the 2.1.224
# defect verbatim.
grep -q 'surface-evidence.*2c=reachability(weakest-of-subclaims)' "$DEC" 2>/dev/null \
    && pass "composite 2c recorded as the weakest of its sub-claims" \
    || fail "weakest-of-subclaims label missing: $(grep 'surface-evidence' "$DEC" | sed -n 1p)"

# (e) `gate` claimed for a surface the gate log does not cover → refused.
#     2d=gate is only payable when the PreToolUse scenario actually ran;
#     crediting the over-limit scenario (Stop/StopFailure — a DIFFERENT
#     hook event) for a PreToolUse changelog entry was the 2.1.222 error.
ROOT="$WORK/a13e"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
grep -v 'pretooluse' "$ROOT/gate.log" > "$ROOT/gate-nohook.log"
touch "$ROOT/gate-nohook.log"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate-nohook.log" --surfaces-clear \
    $SURF_OK $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "refused: 2d=gate without the PreToolUse scenario in the gate log" \
    || fail "unsubstantiated 'gate' claim accepted"

# (f) `gate` claimed for a surface NO scenario can cover (2e CLI flags)
#     → refused, with a pointer to the honest classes.
ROOT="$WORK/a13f"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=reachability --surface-evidence 2c-vi=reachability \
    --surface-evidence 2d=gate \
    --surface-evidence 2e=gate >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "refused: 'gate' for a surface no scenario covers" \
    || fail "uncoverable 'gate' claim accepted"

# (g) unknown class → refused (typo / invented vocabulary).
ROOT="$WORK/a13g"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=reachability --surface-evidence 2c-vi=probably-fine \
    --surface-evidence 2d=gate \
    --surface-evidence 2e=source-inspection >/dev/null 2>&1
(( $? == 3 )) && pass "refused: unknown evidence class" || fail "unknown class accepted"

# ---- 13b2. COMPOSITE surfaces (GAP 1 of the 2.1.224 skeptic verdict) -----
# Surface 2c covers two mechanisms — the paste-delivery path (driven every
# round) and the VI-insert guard (inert: the harness boots panes in
# default mode, so the `i BSpace` prefix is a no-op, re-proven by
# differential control on both 2.1.222 and 2.1.224). The per-surface
# vocabulary could not express "half empirical, half reachability", so
# the whole of 2c was labelled `empirical` — six times in seven rounds.

# (h) the AGGREGATE key `2c` → refused, naming the two halves. This is
#     the call the routine reaches for out of habit, so the refusal has
#     to be the thing that teaches the split.
#
#     DISCRIMINATION: the sub-claims are ALSO supplied, correctly and
#     completely, so `2c=` is the ONLY thing wrong with this invocation.
#     The first version of this case passed `2c=empirical` INSTEAD of the
#     halves, so it refused via the missing-2c-paste rule and survived
#     deleting the key check outright — an assertion that never tested
#     what it named (skeptic F4). Delete `_surface_key_check` now and
#     this run is ACCEPTED at rc 0, because an unknown key is simply
#     ignored by the per-surface loop.
ROOT="$WORK/a13h"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    $SURF_OK --surface-evidence 2c=reachability \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q '2c-paste 2c-vi' "$ROOT/out.log" \
    && pass "refused: composite surface 2c labelled as a whole (halves named)" \
    || fail "aggregate 2c label accepted (rc=$rc)"

# (i) the exact 2.1.224 claim, restated per-half: the VI half calling
#     itself `empirical` on the paste half's control → refused. A control
#     is per sub-claim; the driven half cannot pay for the inert one.
ROOT="$WORK/a13i"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=empirical --surface-evidence 2c-vi=empirical \
    --surface-evidence 2d=gate --surface-evidence 2e=source-inspection \
    --negative-control '2c-paste=broke the delivery grep; probe went red' \
    $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "refused: the inert 2c-vi half riding on 2c-paste's control" \
    || fail "2c-vi=empirical accepted without its own control"

# (j) a --negative-control attached to the composite parent satisfies
#     NEITHER half → refused at the key, not silently ignored.
ROOT="$WORK/a13j"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=empirical --surface-evidence 2c-vi=reachability \
    --surface-evidence 2d=gate --surface-evidence 2e=source-inspection \
    --negative-control '2c=stripped the i BSpace prefix' \
    $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && pass "refused: --negative-control on the composite parent key" \
    || fail "parent-keyed negative control silently accepted"

# (k) a surface key that names nothing → refused (was silently ignored,
#     then resurfaced as the far less obvious "no evidence for 2e").
ROOT="$WORK/a13k"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    $SURF_OK --surface-evidence 2z=gate $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && pass "refused: unknown surface key" || fail "unknown surface key ignored"

# ---- 13c. CHANGELOG COMPLETENESS (GAP 2 of the 2.1.224 skeptic verdict) --
# The 2.1.224 report asserted "both releases read in full" and then
# tabulated 41 of 50 entries. The nine it dropped included the
# `bypassPermissions` vs org-disable-policy fix (the flag every nexus
# spawn rides), the workflow-sandbox dynamic-`import()` escape, and
# `sandbox.filesystem.denyWrite` covering the working directory — three
# of them pre-flagged BY NAME in the spawn brief. "No impact" was the
# default, not a claim. Same defect as 2.1.217's unread footer entry.
#
# The fixture's delta is TWO releases (2.1.155, 2.1.160) with a third
# section at the installed floor that must NOT be demanded.
CL_SURF="$SURF_OK"

# (a) no --changelog-evidence at all → refused (the flags are mandatory
#     on the safe path, exactly like gate evidence).
ROOT="$WORK/a13c1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    $CL_SURF >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "refused: no --changelog-evidence" || fail "missing changelog evidence accepted"

# (b) a release IN THE DELTA with no disposition at all → refused. This
#     is the two-release jump the 2.1.224 round half-read: dispositioning
#     only the candidate's own changelog is not accounting for the delta.
ROOT="$WORK/a13c2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger.md" \
    --changelog-dispositioned 2.1.160=2 > "$ROOT/out.log" 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q 'release 2.1.155 is in the delta' "$ROOT/out.log" \
    && pass "refused: a release in the delta carries no disposition" \
    || fail "undispositioned intermediate release accepted"

# (c) N != M → refused, with both numbers. M is COUNTED from the
#     changelog here; the caller cannot assert it.
ROOT="$WORK/a13c3"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=1 \
    > "$ROOT/out.log" 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q 'dispositioned 1 of 2 entries' "$ROOT/out.log" \
    && pass "refused: N != M for a release (M derived, not asserted)" \
    || fail "undercount accepted"

# (d) N == M but an entry is ABSENT from the ledger → refused. This is
#     the check that makes N honest: an evaluator who believes they read
#     everything would otherwise pass the count while the entry was
#     never written down anywhere.
ROOT="$WORK/a13c4"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
grep -v 'teleport' "$ROOT/ledger.md" > "$ROOT/ledger-short.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-short.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2 \
    > "$ROOT/out.log" 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q 'do not appear verbatim in the ledger' "$ROOT/out.log" \
    && pass "refused: a counted entry missing from the ledger" \
    || fail "bluffed count accepted"

# (e) a PARAPHRASED entry does not count as dispositioned — the GUIDE's
#     verbatim rule, now mechanical.
ROOT="$WORK/a13c5"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
sed 's/Fixed the token counter wording on the spinner row/Fixed some counter stuff/' \
    "$ROOT/ledger.md" > "$ROOT/ledger-para.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-para.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2 \
    >/dev/null 2>&1
(( $? == 3 )) && pass "refused: a paraphrased entry is not a disposition" \
    || fail "paraphrase accepted as verbatim"

# (f) stale changelog evidence → refused (re-fetch from source, do not
#     reuse a prior round's copy or summarise from memory).
ROOT="$WORK/a13c6"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
touch -d '8 hours ago' "$ROOT/changelog.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && pass "refused: stale changelog evidence" || fail "stale changelog accepted"

# (g) the SUPPLIED changelog has no section for the candidate → refused:
#     you read something other than the candidate's changelog, which no
#     amount of correct counting would catch.
#
#     DISCRIMINATION — and this took three tries, so the reasoning is
#     recorded. The check is normally SUBSUMED by the upstream-vs-supplied
#     diff: a supplied file missing the candidate's heading also has zero
#     entries for it, so the diff refuses first and the assertion reds for
#     a neighbouring reason. Round 3 passed `2.1.160=2` and refused via
#     "release outside the delta"; round 4's fix passed only `2.1.155=1`
#     and refused via the diff (measured rc 3, not the rc 0 that commit
#     claimed).
#
#     The one shape where this check is the ONLY thing standing: an
#     upstream candidate section with NO entries. Then supplied-vs-upstream
#     for 2.1.160 is empty-vs-empty — the diff passes — N=0=M=0 passes,
#     and the ledger has nothing to demand. Neutering the check therefore
#     reaches rc 0 and COMPLETES THE BUMP, which is what a discriminating
#     assertion has to be able to say.
ROOT="$WORK/a13c7"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
# upstream: candidate section present but EMPTY; .155 unchanged
{
    printf '# Changelog\n\n'
    printf '## 2.1.160\n\n'
    printf '## 2.1.155\n\n'
    printf -- '- Changed the permission dialog chevron styling\n\n'
    printf '## 2.1.150\n\n'
    printf -- '- Fixed something that predates this delta entirely\n'
} > "$ROOT/upstream-changelog.md"
# supplied: byte-identical EXCEPT the candidate heading is absent
grep -v '^## 2.1.160$' "$ROOT/upstream-changelog.md" > "$ROOT/changelog-nocand.md"
printf -- '- Changed the permission dialog chevron styling | 2b, gate\n' > "$ROOT/ledger-155.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog-nocand.md" --changelog-ledger "$ROOT/ledger-155.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=0 \
    > "$ROOT/out.log" 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q 'your --changelog-evidence has no' "$ROOT/out.log" \
    && pass "refused: supplied changelog has no section for the candidate" \
    || fail "wrong changelog accepted: $(tail -1 "$ROOT/out.log")"

# (g2) THE SPOOF. The supplied changelog is TRUNCATED — a release cut
#      down to fewer entries — and N is declared to match the truncation.
#      Every check that reads the supplied file agrees with itself, so
#      this was ACCEPTED at rc 0 before apply.sh fetched upstream: a
#      skeptic cut 2.1.223 from 19 bullets to 5, passed `2.1.223=5`, and
#      got "dispositioned 36 of 36". Freshness is no obstacle — a
#      hand-edited copy has a fresh mtime by construction.
ROOT="$WORK/a13c7b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
# drop one of the candidate's two entries from the SUPPLIED copy only
grep -v 'teleport' "$ROOT/changelog.md" > "$ROOT/changelog-cut.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog-cut.md" --changelog-ledger "$ROOT/ledger.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=1 \
    > "$ROOT/out.log" 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q 'does not match the changelog this run fetched, for release 2.1.160' "$ROOT/out.log" \
    && pass "refused: supplied changelog truncated, N matched to the truncation" \
    || fail "the truncation spoof was not refused BY THE UPSTREAM DIFF (N!=M also catches this shape, so a refusal alone is not enough): $(tail -1 "$ROOT/out.log")"

# (g3) the upstream fetch FAILS → refused, never silently falling back to
#      the supplied copy (which is the very thing being verified).
ROOT="$WORK/a13c7c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") FETCH_RC=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q 'could not fetch' "$ROOT/out.log" \
    && pass "refused: upstream changelog fetch failed (no fallback to the supplied file)" \
    || fail "fetch failure did not refuse"

# (g4) NESTED BULLETS COUNT. An indented sub-bullet used to be invisible
#      to the parser: not counted into M, never demanded in the ledger,
#      and the run accepted — a sub-entry describing a behaviour change
#      would pass entirely unread. Upstream is flat today, so this is
#      prospective; it is also the half of the parser that failed OPEN.
ROOT="$WORK/a13c9b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
# add an indented sub-bullet under the candidate's first entry, both sides
for f in "$ROOT/changelog.md" "$ROOT/upstream-changelog.md"; do
    sed -i 's|^- Added a new --teleport flag nobody here uses$|- Added a new --teleport flag nobody here uses\n  - and it quietly changes how the status line renders|' "$f"
done
# ledger still lists only the 3 top-level entries, and N claims 2 for the
# candidate — i.e. exactly what a round that never saw the sub-bullet
# would pass.
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q 'dispositioned 2 of 3 entries' "$ROOT/out.log" \
    && pass "refused: an indented sub-bullet counts as an entry (was silently skipped)" \
    || fail "nested bullet not counted: $(tail -1 "$ROOT/out.log")"

# and it is payable — disposition the sub-bullet and the run is accepted
printf -- '- and it quietly changes how the status line renders | 2a, checked\n' >> "$ROOT/ledger.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=3 \
    > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 0 )) && grep -q 'dispositioned 4 of 4 entries' "$ROOT/out.log" \
    && pass "accepted: sub-bullet dispositioned (4 of 4, sub-bullet included)" \
    || fail "nested-bullet accounting wrongly refused (rc=$rc): $(tail -1 "$ROOT/out.log")"

# (g5) THE ACCEPTANCE LINE CLAIMS NO PROVENANCE — because none was
#      established, and three rounds of trying produced three false
#      assurances instead. `M` is not spoofable by FILE (the fetch
#      overrides it), but the fetch is a SUBPROCESS: round 3 was defeated
#      by a hand-edited file, round 4 by CC_AUTO_CHANGELOG_FETCH_CMD,
#      round 5 by a fake `gh` earlier in PATH — that last one printing
#      "M from a live upstream anthropics/claude-code fetch" with no
#      warning at all, because PATH is not something the previous fix's
#      four-variable enumeration could see.
#
#      A caller who controls the environment controls subprocess
#      resolution, and that set cannot be enumerated. So the claim is
#      dropped rather than defended, and THIS asserts the drop: the
#      summary must state the counts and say `provenance NOT
#      established`, and must NOT name a source — no "live upstream", no
#      "OVERRIDDEN", either of which would be an origin claim this run
#      cannot back.
#
#      Driven here through the env seam (the suite has no network), but
#      the assertion is deliberately indifferent to HOW the source was
#      redirected — that indifference is the point.
ROOT="$WORK/a13c10"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
DEC="$ROOT/monitor/.state/cc-auto-update/decisions.tsv"
if (( rc == 0 )) \
   && grep -q 'provenance NOT established' "$ROOT/out.log" \
   && ! grep -qi 'live upstream\|OVERRIDDEN' "$ROOT/out.log" \
   && grep -q 'changelog-completeness.*provenance NOT established' "$DEC" 2>/dev/null; then
    pass "acceptance line states the counts and claims no provenance"
else
    fail "the acceptance line asserts an origin it did not establish (rc=$rc): $(grep -o 'M [a-z].*' "$ROOT/out.log" | tail -1)"
fi

# (h) a disposition for a release OUTSIDE the delta → refused, with the
#     derived release set named. (2.1.150 is the installed floor: its
#     entries are not part of this bump.)
ROOT="$WORK/a13c8"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) --changelog-dispositioned 2.1.150=1 >/dev/null 2>&1
(( $? == 3 )) && pass "refused: a disposition for a release outside the delta" \
    || fail "out-of-delta disposition accepted"

# (i) complete accounting → accepted, and the counts land in the audit
#     trail so a reviewer sees "N of M" without re-reading the report.
ROOT="$WORK/a13c9"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "accepted: every entry of every release in the delta dispositioned" \
    || fail "complete changelog accounting wrongly refused (rc=$rc): $(tail -3 "$ROOT/out.log")"
grep -q $'\tchangelog-completeness\t.*dispositioned 3 of 3 entries across 2 release' \
    "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" 2>/dev/null \
    && pass "changelog counts recorded in the audit trail (3 of 3, 2 releases)" \
    || fail "changelog-completeness audit row missing/wrong: $(grep changelog "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" | sed -n 1p)"

# 14. stale gate evidence
ROOT="$WORK/a14"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
touch -d '8 hours ago' "$ROOT/gate.log"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && pass "refused on stale gate evidence" || fail "stale evidence not refused"

# 15. install failure → rollback, no watcher restart, no kill
ROOT="$WORK/a15"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") INSTALL_RC=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
if (( rc == 4 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
   && ! grep -q "watcher-restart" "$ROOT/calls.log" \
   && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log"; then
    pass "install failure → rc 4, pin rolled back, nothing restarted"
else
    fail "install-failure handling wrong (rc=$rc)"
fi

# 16. verify mismatch → rollback
ROOT="$WORK/a16"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "2.1.150 (Claude Code)"\n' > "$ROOT/claude"
chmod +x "$ROOT/claude"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
(( $? == 5 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "verify mismatch → rc 5, pin rolled back" \
    || fail "verify mismatch mishandled"

# 17. already-pinned → no-op
ROOT="$WORK/a17"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '2.1.160\n' > "$ROOT/monitor/.state/cc-version-local"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
(( $? == 0 )) && ! grep -q "install" "$ROOT/calls.log" \
    && pass "already-pinned → rc 0 no-op" || fail "already-pinned re-ran the bump"

# 18. stale session pin → bump stands, NO kill, rc 21
ROOT="$WORK/a18"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
rm -f "$ROOT/monitor/.state/orchestrator-session-id"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
if (( rc == 21 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local")" == "2.1.160" ]] \
   && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log"; then
    pass "stale pin → bump stands, restart aborted (rc 21, no kill)"
else
    fail "stale-pin handling wrong (rc=$rc)"
fi

echo "== apply: restart-orchestrator (detached second half) =="

# The restart behaviours are exercised by invoking the `restart-orchestrator`
# verb DIRECTLY (synchronously) — the same verb cmd_safe re-exec's disowned.
# pin_of <root> reads the fixture's pinned sid.
pin_of() { cat "$1/monitor/.state/orchestrator-session-id"; }

# 19. watchdog never arms → NO kill, rc 22
ROOT="$WORK/a19"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "spawn $*" >> "%s"\nexit 0\n' "$ROOT/calls.log" > "$ROOT/spawn"
chmod +x "$ROOT/spawn"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
(( rc == 22 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
    && pass "watchdog never armed → no kill (rc 22)" \
    || fail "unarmed-watchdog handling wrong (rc=$rc)"

# 20. orchestrator BUSY past the idle cap → FORCE-restart (the operator
#     decision): kill issued, outcome safe-bumped-restart-forced, rc 0.
#     Replaces the old rc-20 defer — a busy orchestrator no longer blocks
#     the bump from completing the restart.
ROOT="$WORK/a20"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "state=busy active=1"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q $'\tsafe-bumped-restart-forced\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "busy past idle cap → FORCE-restart (rc 0, kill issued, outcome forced)"
else
    fail "force-restart-on-cap wrong (rc=$rc)"
fi

# 20b. pane-state UNREADABLE (empty stdout + exit 2 — the literal
#      2026-06-16 bug repro: pane-state.sh handed a window NAME prints
#      usage to stderr and exits 2 with no stdout). The loop must FAIL
#      LOUD (rc 23, no kill) — NOT force-kill against an unknown pane.
ROOT="$WORK/a20b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "pane-state $*" >> "%s"\necho "usage: pane-state.sh <window-index>" >&2\nexit 2\n' \
    "$ROOT/calls.log" > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
# "no wait" is asserted as an INVOCATION COUNT, not a wall-clock ceiling
# (your-org/nexus-code#557). The old form timed the run and required
# `elapsed < 2` on an operation measured at 0.76-0.96 s — a ~1 s margin
# that a CPU-starved runner erases, flaking ~29% at CI fidelity while
# rc=23 was correct every time. The count is what the timer was really
# proxying for: an unreadable probe must fail loud on the FIRST read, so
# pane-state is queried exactly once. A regression that misread empty
# stdout as "busy" would poll until the cap (3 queries at the fixture's
# IDLE_WAIT=2/POLL=1) — discriminated by count with no timing margin at
# all, and strictly more precise than the clock ever was.
ps_calls=$(grep -c '^pane-state ' "$ROOT/calls.log" 2>/dev/null) || ps_calls=0
if (( rc == 23 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && (( ps_calls == 1 )) \
   && grep -q $'\tsafe-bumped-restart-aborted\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "unreadable pane-state → fail-loud (rc 23, no kill, probed once — no poll loop)"
else
    fail "unreadable-pane-state handling wrong (rc=$rc, pane-state queries=$ps_calls, want 1)"
fi

# 20c. target window does NOT resolve to a tmux index (list-windows has
#      no orchestrator mapping) → fail loud (rc 23, no kill) BEFORE any
#      pane-state poll. Guards the name→index resolver's own failure.
ROOT="$WORK/a20c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
case "\$1" in list-windows) exit 0 ;; esac
exit 0
EOF
chmod +x "$ROOT/tmux"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 23 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && ! grep -q '^pane-state' "$ROOT/calls.log"; then
    pass "unresolvable target window → fail-loud (rc 23, no kill, no poll)"
else
    fail "unresolvable-window handling wrong (rc=$rc)"
fi

# 20d. `state=empty` is a VALID not-idle verdict (renderer transient,
#      claude alive — "re-poll next cycle"), distinct from an UNREADABLE
#      probe — it keeps WAITING, never aborts mid-wait. But a wait that
#      saw NOTHING but empty never positively resolved the pane (no
#      busy, no turn boundary), so the cap REFUSES to force-kill and
#      aborts loud instead (rc 23, no kill) — nexus-code#514 item 3
#      (pre-#514 this force-killed: 7/7 recorded fires, all
#      "last state=empty"). The reconcile retries after its cooldown.
ROOT="$WORK/a20d"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "state=empty active=1 window=2 name=orchestrator"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 23 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q "never-resolved-empty-at-cap" "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "ALL-empty wait → cap refuses the force (rc 23, no kill) — never-resolved guard"
else
    fail "all-empty cap handling wrong (rc=$rc, want 23 + no kill)"
fi

# 20d2. empty is still a plain WAIT verdict when the pane resolved at
#       least once: busy on the first poll, empty ever after → the cap
#       force-fires (rc 0, kill, outcome forced) exactly as for a
#       busy-forever pane. Pins the resolved_seen latch.
ROOT="$WORK/a20d2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
cat > "$ROOT/pane-state" <<EOF
#!/usr/bin/env bash
ctr="$ROOT/probe.ctr"
n=\$(cat "\$ctr" 2>/dev/null || echo 0); echo \$(( n + 1 )) > "\$ctr"
if (( n == 0 )); then echo "state=busy active=1 window=2 name=orchestrator"
else echo "state=empty active=1 window=2 name=orchestrator"; fi
EOF
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q $'\tsafe-bumped-restart-forced\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "busy-once-then-empty → resolved_seen latched, cap force-fires (rc 0)"
else
    fail "resolved_seen latch wrong (rc=$rc, want forced rc 0)"
fi

# E1 (nexus-code#514). Monitor-handle `working-background` (no bg_cpu=
#     field) IS a turn boundary: the orchestrator permanently holds the
#     watcher-supervisor Monitor handle, so pane-state can NEVER emit a
#     literal `idle` for it — this is the state every clean restart must
#     key on. Expect a CLEAN (non-forced) restart on the FIRST poll.
ROOT="$WORK/ae1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "state=working-background active=1 window=2 name=orchestrator"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q $'\tsafe-bumped-restarted\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" \
   && ! grep -q $'\tsafe-bumped-restart-forced\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "Monitor-handle working-background → turn boundary, CLEAN restart (rc 0, not forced)"
else
    fail "Monitor-handle eligibility wrong (rc=$rc)"
fi

# E2 (nexus-code#514). SHELL-driven `working-background` (bg_cpu= on the
#     emit line) has a live fire-and-forget child the kill would destroy
#     → NOT eligible; waits to the cap, then forces (positively resolved).
ROOT="$WORK/ae2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "state=working-background active=1 window=2 name=orchestrator bg_shells=1 bg_reliable=1 bg_cpu=42 bg_oldest_start=1"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q $'\tsafe-bumped-restart-forced\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "shell-driven working-background (bg_cpu=) → NOT eligible, waits, forces at cap"
else
    fail "shell-driven working-background handling wrong (rc=$rc)"
fi

# 20e. INDEX is re-resolved every poll, not cached. Skeptic edge: with
#      tmux `renumber-windows` on, a window closing mid-wait shifts the
#      orchestrator's index — a cached index would then poll (or kill
#      the name of) the WRONG window. Stateful mock: the orchestrator
#      sits at index 3 (busy) on the first poll, then moves to index 2
#      (idle) on the next. The probe must FOLLOW the new index (query
#      both 3 then 2) and proceed to the kill — proving re-resolution.
ROOT="$WORK/a20e"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
ctr="$ROOT/resolve.ctr"
case "\$1" in
  list-windows)
    case "\$*" in
      *'#{window_name}|#{window_index}'*)
        n=\$(cat "\$ctr" 2>/dev/null || echo 0); echo \$(( n + 1 )) > "\$ctr"
        if (( n == 0 )); then echo "orchestrator|3"; else echo "orchestrator|2"; fi ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
cat > "$ROOT/pane-state" <<EOF
#!/usr/bin/env bash
echo "pane-state \$*" >> "$ROOT/calls.log"
case "\$1" in
  3) echo "state=busy active=1 window=3 name=orchestrator" ;;
  2) echo "state=idle active=1 window=2 name=orchestrator" ;;
  *) echo "state=empty active=0 window=\$1 name=orchestrator" ;;
esac
EOF
chmod +x "$ROOT/tmux" "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q '^pane-state 3$' "$ROOT/calls.log" \
   && grep -q '^pane-state 2$' "$ROOT/calls.log" \
   && grep -q "kill-window -t orchestrator" "$ROOT/calls.log"; then
    pass "index re-resolved per poll → follows orchestrator 3→2, then kills (rc 0)"
else
    fail "index re-resolution wrong (rc=$rc, probes: $(grep '^pane-state' "$ROOT/calls.log" | tr '\n' ','))"
fi

# 20f. re-validate-before-kill NO-OP: the orchestrator already respawned
#      onto the candidate on its own (the pinned transcript carries a
#      candidate-stamped record). A kill would be needless → rc 24, NO
#      kill. Guards against killing a workspace that already healed.
ROOT="$WORK/a20f"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
slug=$(printf '%s' "$ROOT" | sed 's|[^a-zA-Z0-9]|-|g')
printf '{"version":"2.1.160"}\n' >> "$ROOT/projects/$slug/$(pin_of "$ROOT").jsonl"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 24 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q $'\tsafe-bumped-restart-noop\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "already-on-candidate (self-respawned) → no-op (rc 24, no kill)"
else
    fail "re-validate no-op handling wrong (rc=$rc)"
fi

# 20g. the detached verb's OWN pin re-validation: the session pin goes
#      stale (removed) before the restart runs → abort, NO kill, rc 21.
#      Complements case 18 (safe's foreground pre-flight) — a kill after
#      the pin moved would cold-spawn a different session.
ROOT="$WORK/a20g"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
SID="$(pin_of "$ROOT")"
rm -f "$ROOT/monitor/.state/orchestrator-session-id"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$SID" >/dev/null 2>&1
rc=$?
(( rc == 21 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
    && pass "detached verb: pin went stale → abort (rc 21, no kill)" \
    || fail "detached stale-pin handling wrong (rc=$rc)"

# 20h. FIRE-TIME (post-wait) pin re-validation TRIGGERS: the pin is valid
#      at the start-of-run check but goes stale DURING the idle-wait. The
#      post-wait re-check (after the loop, before arming) must catch it
#      and abort with NO kill — the most safety-critical branch (a kill
#      after the pin moved would cold-spawn a different session). The
#      pane-state stub stays busy AND removes the pin on its first call
#      (inside the loop, so the start-of-run check has already passed),
#      so only the fire-time branch can fire. The `pin-stale-at-fire`
#      detail (vs `pin-stale-pre-wait`) proves which branch aborted.
ROOT="$WORK/a20h"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
cat > "$ROOT/pane-state" <<EOF
#!/usr/bin/env bash
rm -f "$ROOT/monitor/.state/orchestrator-session-id"
echo "state=busy active=1"
EOF
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 21 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q "pin-stale-at-fire" "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "pin goes stale DURING the wait → fire-time re-check aborts (rc 21, no kill)"
else
    fail "fire-time pin re-validation wrong (rc=$rc): $(grep safe-bumped-restart-aborted "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" | tail -1)"
fi

# ===== restart hold (nexus-code#513) =======================================

echo "== restart hold =="

# H1. an active hold suppresses the reconcile fire — and the audit row is
#     written ONCE per hold, not per tick (the ack-stamp dedup).
ROOT="$WORK/h1"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
_cc_auto_write_restart_hold "$auto" "operator says no" "" ""
reconcile "$ROOT"
reconcile "$ROOT"
held_rows=$(grep -c $'\treconcile-held\t' "$auto/decisions.tsv" 2>/dev/null || true)
if [[ ! -e "$ROOT/apply.log" ]] && (( held_rows == 1 )); then
    pass "active hold suppresses the reconcile; 'reconcile-held' logged once, not per tick"
else
    fail "hold suppression wrong (apply=$( [[ -e $ROOT/apply.log ]] && echo fired || echo no ), held_rows=$held_rows)"
fi
# ... and a REWRITTEN hold re-logs once (fresh mtime beats the ack).
sleep 1
_cc_auto_write_restart_hold "$auto" "operator says no again" "" ""
reconcile "$ROOT"
held_rows=$(grep -c $'\treconcile-held\t' "$auto/decisions.tsv" 2>/dev/null || true)
(( held_rows == 2 )) \
    && pass "a rewritten hold re-logs exactly once" \
    || fail "rewritten-hold logging wrong (held_rows=$held_rows)"

# H2. an EXPIRED (TTL lapsed) hold does not suppress — the fire proceeds.
ROOT="$WORK/h2"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
_cc_auto_write_restart_hold "$auto" "stale hold" "$(( $(date +%s) - 10 ))" ""
reconcile "$ROOT"
[[ -f "$ROOT/apply.log" ]] && grep -q "restart-orchestrator --candidate 2.1.195" "$ROOT/apply.log" \
    && pass "TTL-expired hold no longer suppresses (fire proceeds)" \
    || fail "expired hold still suppressed the reconcile"

# H3. until_version semantics: holds candidates <= the named version; a
#     NEWER effective re-arms (mirrors the daily awaiting-operator model).
ROOT="$WORK/h3"; make_reconcile_root "$ROOT" "2.1.186" "2.1.195" "2.1.186"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
_cc_auto_write_restart_hold "$auto" "hold this candidate" "" "2.1.195"
reconcile "$ROOT"
h3a_ok=0; [[ ! -e "$ROOT/apply.log" ]] && h3a_ok=1
printf '%s\n' "2.1.196" > "$ROOT/monitor/.state/cc-version-local"   # newer candidate arrives
rm -f "$auto/reconcile.last"                                         # clear the cooldown, isolate the hold
reconcile "$ROOT"
if (( h3a_ok )) && [[ -f "$ROOT/apply.log" ]] \
   && grep -q "restart-orchestrator --candidate 2.1.196" "$ROOT/apply.log"; then
    pass "until_version holds its candidate; a newer effective re-arms"
else
    fail "until_version semantics wrong (held=$h3a_ok, apply=$(cat "$ROOT/apply.log" 2>/dev/null))"
fi

# H4. hold / hold-status / unhold verbs round-trip.
ROOT="$WORK/h4"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env NEXUS_ROOT="$ROOT" bash "$APPLY" hold --reason "operator pause" --until-version 2.1.160 >/dev/null 2>&1
hs_rc=0; env NEXUS_ROOT="$ROOT" bash "$APPLY" hold-status >/dev/null 2>&1 || hs_rc=$?
env NEXUS_ROOT="$ROOT" bash "$APPLY" unhold >/dev/null 2>&1
hs2_rc=0; env NEXUS_ROOT="$ROOT" bash "$APPLY" hold-status >/dev/null 2>&1 || hs2_rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( hs_rc == 0 )) && (( hs2_rc == 1 )) && [[ ! -f "$auto/restart-hold" ]] \
   && grep -q $'\trestart-hold-set\t' "$auto/decisions.tsv" \
   && grep -q $'\trestart-hold-released\t' "$auto/decisions.tsv"; then
    pass "hold → active (rc 0), unhold → released (rc 1), both audited"
else
    fail "hold-verb round-trip wrong (active_rc=$hs_rc after_unhold_rc=$hs2_rc)"
fi

# H5. the detached restart honours an existing hold: no wait, no kill,
#     rc 25, outcome safe-bumped-restart-held.
ROOT="$WORK/h5"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
_cc_auto_write_restart_hold "$auto" "do not restart" "" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 25 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q $'\tsafe-bumped-restart-held\t' "$auto/decisions.tsv"; then
    pass "detached restart honours the hold (rc 25, no kill)"
else
    fail "hold pre-flight wrong (rc=$rc)"
fi

# H6. SIGTERMing the detached restart WRITES the hold (abort-on-purpose
#     must stay aborted — pre-#513 the dead pid re-armed the reconcile's
#     single-flight guard and the abort CAUSED the refire).
ROOT="$WORK/h6"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
printf '#!/usr/bin/env bash\necho "state=busy active=1 window=2 name=orchestrator"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") CC_AUTO_IDLE_WAIT_SECONDS=60 bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1 &
h6_pid=$!
sleep 2
kill -TERM "$h6_pid" 2>/dev/null
wait "$h6_pid" 2>/dev/null; rc=$?
if (( rc == 25 )) && [[ -f "$auto/restart-hold" ]] \
   && grep -q '^until_version=2\.1\.160$' "$auto/restart-hold" \
   && grep -q "sigterm-hold-written" "$auto/decisions.tsv" \
   && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log"; then
    pass "SIGTERM'd detached restart writes the hold (until_version=candidate, rc 25, no kill)"
else
    fail "SIGTERM-hold wrong (rc=$rc, hold=$( [[ -f $auto/restart-hold ]] && echo yes || echo no ))"
fi

# ===== restart-outcome marker + abort-streak escalation (nexus-code#511) ====

echo "== restart-outcome marker + abort escalation =="

# A non-resolving tmux stub (no orchestrator→index mapping) reproduces the
# target-window-unresolved abort (rc 23) this issue tracks. Same shape as
# case 20c, factored so the streak tests can reuse it.
_nonresolving_tmux() {
    cat > "$1/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$1/calls.log"
case "\$1" in list-windows) exit 0 ;; esac
exit 0
EOF
    chmod +x "$1/tmux"
}

# M1. abort writes the single-latest restart-outcome marker (outcome/code/
#     cause/abort_streak), and the FIRST same-cause abort is streak=1.
ROOT="$WORK/m1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
_nonresolving_tmux "$ROOT"
env $(apply_env "$ROOT") CC_AUTO_RESTART_ABORT_ESCALATE=3 bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 23 )) && [[ -f "$auto/restart-outcome" ]] \
   && grep -q '^outcome=safe-bumped-restart-aborted$' "$auto/restart-outcome" \
   && grep -q '^code=23$' "$auto/restart-outcome" \
   && grep -q '^cause=target-window-unresolved=orchestrator$' "$auto/restart-outcome" \
   && grep -q '^abort_streak=1$' "$auto/restart-outcome"; then
    pass "abort writes restart-outcome marker (outcome/code/cause/streak=1)"
else
    fail "restart-outcome marker wrong after first abort (rc=$rc): $(cat "$auto/restart-outcome" 2>/dev/null | tr '\n' ' ')"
fi
# Streak 1 (< threshold 3): NO escalation row yet.
grep -q $'\trestart-abort-escalation\t' "$auto/decisions.tsv" \
    && fail "escalated at streak 1 (should not)" \
    || pass "no escalation below threshold (streak 1)"

# M2. consecutive same-cause aborts INCREMENT the streak; crossing the
#     threshold shouts exactly once (a restart-abort-escalation audit row).
env $(apply_env "$ROOT") CC_AUTO_RESTART_ABORT_ESCALATE=3 bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1   # streak 2
grep -q '^abort_streak=2$' "$auto/restart-outcome" \
    && pass "second same-cause abort → streak 2" || fail "streak did not reach 2"
env $(apply_env "$ROOT") CC_AUTO_RESTART_ABORT_ESCALATE=3 bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1   # streak 3 → escalate
if grep -q '^abort_streak=3$' "$auto/restart-outcome" \
   && grep -q $'\trestart-abort-escalation\t' "$auto/decisions.tsv" \
   && [[ "$(grep -c $'\trestart-abort-escalation\t' "$auto/decisions.tsv")" == "1" ]]; then
    pass "streak reaches threshold (3) → escalates exactly once"
else
    fail "escalation-at-threshold wrong (streak=$(grep '^abort_streak' "$auto/restart-outcome"), escalations=$(grep -c $'\trestart-abort-escalation\t' "$auto/decisions.tsv"))"
fi

# M3. a SUCCESS resets the streak — escalation does not persist after the
#     restart finally lands. Restore a resolving tmux (make_apply_root's
#     default idle pane then drives a clean restart).
cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
case "\$1" in
  list-windows)
    case "\$*" in *'#{window_name}|#{window_index}'*) echo "orchestrator|2" ;; esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$ROOT/tmux"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q '^outcome=safe-bumped-restarted$' "$auto/restart-outcome" \
   && grep -q '^abort_streak=0$' "$auto/restart-outcome"; then
    pass "success resets the abort streak to 0 (outcome=restarted)"
else
    fail "streak not reset on success (rc=$rc): $(cat "$auto/restart-outcome" 2>/dev/null | tr '\n' ' ')"
fi

# M4. a DIFFERENT-cause abort does NOT continue a prior cause's streak — it
#     restarts at 1 (only a genuinely-repeating failure escalates).
ROOT="$WORK/m4"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
_nonresolving_tmux "$ROOT"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1   # target-window, streak 1
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1   # target-window, streak 2
grep -q '^abort_streak=2$' "$auto/restart-outcome" || fail "M4 setup: streak != 2"
# Now a resolving tmux but an UNREADABLE pane-state → a different abort cause.
cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
case "\$1" in
  list-windows)
    case "\$*" in *'#{window_name}|#{window_index}'*) echo "orchestrator|2" ;; esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$ROOT/tmux"
printf '#!/usr/bin/env bash\necho "usage: pane-state.sh <window-index>" >&2\nexit 2\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
if grep -q '^cause=pane-state-unreadable$' "$auto/restart-outcome" \
   && grep -q '^abort_streak=1$' "$auto/restart-outcome"; then
    pass "a different abort cause resets the streak to 1 (no false escalation)"
else
    fail "different-cause streak-reset wrong: $(cat "$auto/restart-outcome" 2>/dev/null | tr '\n' ' ')"
fi

# M5. the INLINE seam makes a Step-5b abort DISTINGUISHABLE to a caller:
#     `safe` (CC_AUTO_RESTART_INLINE=1) applies the bump AND propagates the
#     restart's non-zero abort code — an evaluator can no longer read a
#     restart-aborted fire as a clean success.
ROOT="$WORK/m5"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
_nonresolving_tmux "$ROOT"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
if (( rc == 23 )) \
   && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
   && grep -q $'\tsafe-bumped-restart-handoff\t' "$auto/decisions.tsv" \
   && grep -q $'\tsafe-bumped-restart-aborted\t' "$auto/decisions.tsv" \
   && grep -q '^outcome=safe-bumped-restart-aborted$' "$auto/restart-outcome"; then
    pass "inline safe: bump applied but restart abort PROPAGATED (rc 23, not 0)"
else
    fail "inline abort-propagation wrong (rc=$rc, pin=$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null))"
fi

# M6. REGRESSION: the DETACHED (production) path still exits 0 at hand-off —
#     the async abort is a future event there, surfaced via the marker, not
#     the exit code (proven green by case 12b's rc-0 + handoff assertion;
#     re-pinned here for the exit-code contract specifically).
ROOT="$WORK/m6"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
_nonresolving_tmux "$ROOT"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
(( rc == 0 )) && pass "detached safe still exits 0 at hand-off (abort is a future event)" \
    || fail "detached safe exit-code regressed (rc=$rc, want 0)"

# ===== deployment gate (nexus-code#512) ====================================

echo "== deployment gate =="

# G1. an open PR touching the watcher restart path DEFERS the apply:
#     rc 30, NOTHING mutated (no pin, no install), outcome safe-deferred
#     with the PR pinned in the detail.
ROOT="$WORK/g1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nprintf "503\\tmonitor/watcher/launcher.sh\\n503\\tmonitor/README.md\\n"\n' > "$ROOT/gate-prs"
chmod +x "$ROOT/gate-prs"
env $(apply_env "$ROOT") CC_AUTO_GATE_PR_CMD="$ROOT/gate-prs" bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 30 )) && [[ ! -f "$ROOT/monitor/.state/cc-version-local" ]] \
   && ! grep -q '^install$' "$ROOT/calls.log" \
   && grep -q "deferred-pending-PR503" "$auto/decisions.tsv"; then
    pass "open restart-path PR → apply deferred (rc 30, nothing mutated, PR recorded)"
else
    fail "PR-gate defer wrong (rc=$rc): $(grep safe-deferred "$auto/decisions.tsv" 2>/dev/null | tail -1)"
fi

# G2. the PR probe FAILING is not a pass — cannot establish the restart
#     path is unclaimed → defer (fail-safe), distinct detail.
ROOT="$WORK/g2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") CC_AUTO_GATE_PR_CMD=false bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 30 )) && [[ ! -f "$ROOT/monitor/.state/cc-version-local" ]] \
   && grep -q "restart-path-pr-query-failed" "$auto/decisions.tsv"; then
    pass "PR probe failure → defer, never treated as 'no PRs' (fail-safe)"
else
    fail "PR-probe-failure handling wrong (rc=$rc)"
fi

# G3 + G3b. live-window gate: 3 agent windows (infra names exempted)
#     defer at max=2 and pass at max=3; the count lands in the audit row.
make_gate_tmux() {  # $1=root — tmux stub serving BOTH list-windows formats
    cat > "$1/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$1/calls.log"
case "\$1" in
  list-windows)
    case "\$*" in
      *'#{window_name}|#{window_index}'*) echo "orchestrator|2" ;;
      *'#{window_name}'*)
        printf '%s\n' orchestrator services cc-auto-update cc-restart-watchdog w1 w2 w3 ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
    chmod +x "$1/tmux"
}
ROOT="$WORK/g3"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
env $(apply_env "$ROOT") CC_AUTO_TMUX="$ROOT/tmux" CC_AUTO_MAX_LIVE_WINDOWS=2 \
    bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 30 )) && [[ ! -f "$ROOT/monitor/.state/cc-version-local" ]] \
   && grep -q "live-windows=3>max=2" "$auto/decisions.tsv"; then
    pass "window gate: 3 agents > max 2 → defer (infra windows exempted from the count)"
else
    fail "window-gate defer wrong (rc=$rc): $(grep safe-deferred "$auto/decisions.tsv" 2>/dev/null | tail -1)"
fi
ROOT="$WORK/g3b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
env $(apply_env "$ROOT") CC_AUTO_TMUX="$ROOT/tmux" CC_AUTO_MAX_LIVE_WINDOWS=3 \
    CC_AUTO_RESTART_INLINE=1 \
    bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )) && grep -q "live_windows=3" "$auto/decisions.tsv" \
   && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]]; then
    pass "window gate: 3 agents ≤ max 3 → proceeds; count recorded in the apply record"
else
    fail "window-gate pass wrong (rc=$rc)"
fi

# G4. post-restart invariant: TWO live watcher groups for this root after
#     the restart → rc 31, orchestrator restart NOT handed off (no kill).
ROOT="$WORK/g4"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
mkdir -p "$ROOT/monitor/watcher"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$ROOT/monitor/watcher/main.sh"
chmod +x "$ROOT/monitor/watcher/main.sh"
setsid bash "$ROOT/monitor/watcher/main.sh" & g4_p1=$!
setsid bash "$ROOT/monitor/watcher/main.sh" & g4_p2=$!
sleep 1
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
kill "$g4_p1" "$g4_p2" 2>/dev/null; wait "$g4_p1" "$g4_p2" 2>/dev/null
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 31 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q $'\tsafe-bumped-restart-invariant-violated\t' "$auto/decisions.tsv"; then
    pass "duplicate watcher groups post-restart → invariant violation (rc 31, no Step 5b)"
else
    fail "post-restart invariant wrong (rc=$rc)"
fi

# ===== apply: compat-pr branch =============================================

echo "== apply: compat-pr =="

# gh stub factory: $1=root $2=list-json. `pr list` prints the JSON;
# `pr comment` records argv.
make_gh_stub() {
    local root="$1" json="$2"
    printf '%s' "$json" > "$root/prlist.json"
    cat > "$root/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
    "pr list")    cat "$root/prlist.json" ;;
    "pr comment") echo "comment \$*" >> "$root/calls.log" ;;
    *) exit 1 ;;
esac
EOF
    printf '#!/usr/bin/env bash\necho tok-test\n' > "$root/mint"
    chmod +x "$root/gh" "$root/mint"
}

compat_env() {
    local root="$1"
    echo NEXUS_ROOT="$root" CC_AUTO_GH="$root/gh" CC_AUTO_MINT_CMD="$root/mint"
}

# 21. exactly one open compat PR → comment
ROOT="$WORK/c21"; make_root "$ROOT" "2.1.150"; : > "$ROOT/calls.log"
make_gh_stub "$ROOT" '[{"number":42,"title":"cc-compat 2.1.160: fix _detect_busy","url":"https://github.com/your-org/nexus-code/pull/42"}]'
printf 'findings\n' > "$ROOT/findings.md"
env $(compat_env "$ROOT") bash "$APPLY" compat-pr auto \
    --candidate 2.1.160 --findings "$ROOT/findings.md" > "$ROOT/out" 2>&1
rc=$?
if (( rc == 0 )) && grep -q "comment pr comment 42" "$ROOT/calls.log" \
   && grep -q "compat-pr-commented" "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "existing compat PR → commented, outcome recorded"
else
    fail "compat-pr existing-PR path wrong (rc=$rc)"
fi

# 22. none → rc 10
ROOT="$WORK/c22"; make_root "$ROOT" "2.1.150"; : > "$ROOT/calls.log"
make_gh_stub "$ROOT" '[]'
printf 'findings\n' > "$ROOT/findings.md"
env $(compat_env "$ROOT") bash "$APPLY" compat-pr auto \
    --candidate 2.1.160 --findings "$ROOT/findings.md" > "$ROOT/out" 2>&1
rc=$?
(( rc == 10 )) && ! grep -q "comment" "$ROOT/calls.log" && grep -q "none-found" "$ROOT/out" \
    && pass "no compat PR → rc 10 (caller opens one)" \
    || fail "compat-pr none-found path wrong (rc=$rc)"

# 23. several → rc 11
ROOT="$WORK/c23"; make_root "$ROOT" "2.1.150"; : > "$ROOT/calls.log"
make_gh_stub "$ROOT" '[{"number":1,"title":"cc-compat a","url":"u1"},{"number":2,"title":"cc-compat b","url":"u2"}]'
printf 'findings\n' > "$ROOT/findings.md"
env $(compat_env "$ROOT") bash "$APPLY" compat-pr auto \
    --candidate 2.1.160 --findings "$ROOT/findings.md" >/dev/null 2>&1
rc=$?
(( rc == 11 )) && ! grep -q "comment" "$ROOT/calls.log" \
    && pass "multiple compat PRs → rc 11 (caller judges)" \
    || fail "compat-pr ambiguity path wrong (rc=$rc)"

# ===== apply: block branch =================================================

echo "== apply: block =="

# 24. block records + the daily guard then skips
ROOT="$WORK/b24"; make_root "$ROOT" "2.1.150"
env NEXUS_ROOT="$ROOT" bash "$APPLY" block \
    --candidate 2.1.160 --reason "gate RED: test-realmodel-idle-busy" >/dev/null 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )) && grep -q $'\tblock\t' "$auto/decisions.tsv" \
   && [[ "$(_cc_update_field "$auto/last-eval" decision)" == "block" ]] \
   && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]]; then
    pass "block → recorded, pin untouched"
else
    fail "block path wrong (rc=$rc)"
fi
_cc_auto_last_eval_skip "$auto" "2.1.160" \
    && pass "daily guard skips the blocked candidate" \
    || fail "guard does not skip after block"
_cc_auto_last_eval_skip "$auto" "2.1.161" \
    && fail "guard wrongly skips a newer candidate" \
    || pass "guard re-arms on a newer candidate"

# ===== emit-section NOTE (orchestrator dedup) ==============================

echo "== emit-section NOTE =="

# 25. _cc_update_emit_section carries the do-not-spawn-manually NOTE
#     iff the autonomous routine is enabled (unset/false → unchanged
#     manual instruction, pinned by test-cc-update.sh case 16).
SD="$WORK/emit-state"; mkdir -p "$SD"
printf 'candidate=9.9.9\ninstalled=9.9.8\npackage=p\ndetected=t\nskill=s\n' \
    > "$SD/cc-update-available"
# The emit gate defaults OFF (see test-cc-update.sh cases 17/18); these
# cases probe the emit CONTENT, so force the gate ON for both.
export MONITOR_CC_UPDATE_EMIT_ENABLED=true
out=$(MONITOR_CC_AUTO_UPDATE_ENABLED=true _cc_update_emit_section "$SD")
grep -q 'autonomous daily cc-update routine is ENABLED' <<<"$out" \
    && pass "emit NOTE present when routine enabled" \
    || fail "emit NOTE missing when enabled"
rm -f "$SD/cc-update-surfaced"
out=$(MONITOR_CC_AUTO_UPDATE_ENABLED=false _cc_update_emit_section "$SD")
grep -q 'autonomous daily' <<<"$out" \
    && fail "emit NOTE leaked when disabled" \
    || pass "emit NOTE absent when routine disabled"

# ===== deployment-gate staleness: the INTEGRATION branch (nexus-code#754) ===
#
# The gate used to measure `HEAD..origin/main` while PRs merge to the
# integration branch, so it under-reported the quantity it exists to report.
# EVERY case below is written to fail against that old code — a test that
# only asserted "some number is emitted" would have passed it, which is the
# same proxy-instead-of-property defect one level up.

echo "== deployment gate: staleness measures the integration branch (#754) =="

# A real git clone whose HEAD sits on `main` while `dev` has advanced.
# The working tree is NOT touched (no reset/checkout): the apply fixture's
# package.json and monitor/ must survive, so HEAD is moved by writing the
# ref directly.
#   $1=root  $2=commits dev is ahead of main
make_gate_clone() {
    # NOT one `local` statement: `local` is a builtin, so ALL its arguments
    # are expanded before it runs — `rem="$root/…"` would read `$root` from
    # the enclosing scope, which is unset, and `set -u` aborts the suite.
    local root="$1" ahead="$2" i
    local rem="$root/.gitremote"
    rm -rf "$rem"; mkdir -p "$rem"
    (
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
               GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git init -q "$rem" && cd "$rem" || exit 1
        git symbolic-ref HEAD refs/heads/main
        echo base > f && git add -A && git commit -qm base
        git checkout -qb dev
        for ((i=1; i<=ahead; i++)); do echo "$i" >> f; git commit -qam "dev $i"; done
        git checkout -q main
    ) >/dev/null 2>&1 || return 1
    git -C "$root" init -q                                            || return 1
    git -C "$root" remote add origin "$rem"                           || return 1
    git -C "$root" fetch -q origin 'refs/heads/*:refs/remotes/origin/*' || return 1
    git -C "$root" update-ref refs/heads/main \
        "$(git -C "$rem" rev-parse main)"                             || return 1
    git -C "$root" symbolic-ref HEAD refs/heads/main                  || return 1
}

# A `git` shim that fails ONLY on `fetch` and is otherwise the real thing.
# Lets a case prove the gate's answer does not depend on the fetch landing.
make_nofetch_git() {
    local root="$1" real; real=$(command -v git)
    mkdir -p "$root/bin"
    cat > "$root/bin/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == fetch ]] && exit 1; done
exec "$real" "\$@"
EOF
    chmod +x "$root/bin/git"
}

# G5a. THE PROPERTY. HEAD is level with `main` and 5 behind `dev`. The old
#      code measured `main` and reported 0 — "up to date" about a clone
#      missing five merged commits. Asserting 5 (and explicitly NOT 0) is
#      what makes this a property test rather than a smoke test.
ROOT="$WORK/g5a"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
if make_gate_clone "$ROOT" 5; then
    out=$(env $(apply_env "$ROOT") MONITOR_CLONE_DRIFT_BRANCH=dev \
              CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
              --gate-evidence "$ROOT/gate.log" --surfaces-clear \
              $SURF_OK $(cl_ok) 2>&1)
    auto="$ROOT/monitor/.state/cc-auto-update"
    row=$(grep 'deployment-gate' "$auto/decisions.tsv" 2>/dev/null | tail -1)
    if [[ "$row" == *"behind_integration=5"* ]] \
       && [[ "$row" == *"integration_branch=dev"* ]] \
       && [[ "$row" != *"behind_integration=0"* ]]; then
        pass "staleness measured against dev: 5 behind (main-based code said 0)"
    else
        fail "#754 staleness not measured against dev; row=$row"
    fi
    # The remediation must name the ref it measured — following the old
    # `pull --ff-only origin main` landed the operator on a tree that still
    # lacked the fix the WARN was about.
    if grep -q 'commits behind origin/dev' <<<"$out" \
       && grep -q 'pull --ff-only origin dev' <<<"$out" \
       && ! grep -q 'origin/main' <<<"$out"; then
        pass "WARN + remediation name origin/dev, the ref actually measured"
    else
        # `grep -m2`, NOT `grep … | head -2`: the latter is a new early-exit
        # reader (#622/#682) and would move the checked population in
        # early-exit-readers.manifest. That site would have been benign — the
        # pipeline sits in a command substitution used as a string argument,
        # so its status is consumed by nothing, the suite runs `set -uo
        # pipefail` without `-e`, and it executes only on an already-failed
        # assertion — but a permanent row on a checked boundary is a poor
        # price for truncating a diagnostic. `-m2` needs no second process.
        fail "#754 WARN/remediation still names the wrong ref: $(grep -im2 'behind' <<<"$out")"
    fi
else
    fail "#754 fixture: could not build the gate git clone (G5a skipped)"
fi

# G5b. STALE REMOTE-TRACKING REF. Objects for the live tip are present
#      locally, but `origin/dev` is rewound to the old tip and the fetch is
#      made to fail. The old code answered 5 from the stale ref — a
#      CONFIDENT WRONG NUMBER, not an `unknown`. The probe takes its tip
#      from a live `ls-remote`, so the correct answer is 11.
ROOT="$WORK/g5b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
if make_gate_clone "$ROOT" 5; then
    stale=$(git -C "$ROOT" rev-parse origin/dev)
    (
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
               GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        cd "$ROOT/.gitremote" && git checkout -q dev
        for i in 6 7 8 9 10 11; do echo "$i" >> f; git commit -qam "dev $i"; done
        git checkout -q main
    ) >/dev/null 2>&1
    # Objects local, tracking ref deliberately left in the past.
    git -C "$ROOT" fetch -q origin 'refs/heads/*:refs/remotes/origin/*' >/dev/null 2>&1
    git -C "$ROOT" update-ref refs/remotes/origin/dev "$stale"
    make_nofetch_git "$ROOT"
    out=$(env $(apply_env "$ROOT") MONITOR_CLONE_DRIFT_BRANCH=dev \
              PATH="$ROOT/bin:$PATH" CC_AUTO_RESTART_INLINE=1 \
              bash "$APPLY" safe --candidate 2.1.160 \
              --gate-evidence "$ROOT/gate.log" --surfaces-clear \
              $SURF_OK $(cl_ok) 2>&1)
    auto="$ROOT/monitor/.state/cc-auto-update"
    row=$(grep 'deployment-gate' "$auto/decisions.tsv" 2>/dev/null | tail -1)
    if [[ "$row" == *"behind_integration=11"* ]] \
       && [[ "$row" != *"behind_integration=5"* ]]; then
        pass "stale tracking ref ignored: 11 from the live tip, not 5 from the past"
    else
        fail "#754 gate answered from a stale remote-tracking ref; row=$row"
    fi
else
    fail "#754 fixture: could not build the gate git clone (G5b skipped)"
fi

# G5c. `unknown` IS LOUD. When the root is not a clone the margin cannot be
#      established. The old code left `behind=unknown`, which failed the
#      `^[0-9]+$` guard on the WARN and so emitted NOTHING — "could not
#      look" rendered exactly like "up to date". That is #740's thesis
#      inside #754's gate, and it is the reason this case exists.
ROOT="$WORK/g5c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
out=$(env $(apply_env "$ROOT") MONITOR_CLONE_DRIFT_BRANCH=dev \
          CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
          --gate-evidence "$ROOT/gate.log" --surfaces-clear \
          $SURF_OK $(cl_ok) 2>&1)
auto="$ROOT/monitor/.state/cc-auto-update"
row=$(grep 'deployment-gate' "$auto/decisions.tsv" 2>/dev/null | tail -1)
if grep -q 'COULD NOT DETERMINE whether this clone is behind' <<<"$out" \
   && grep -q "'Could not look' is NOT 'up to date'" <<<"$out" \
   && [[ "$row" == *"drift=unknown"* ]]; then
    pass "unmeasurable staleness WARNs loudly and records drift=unknown"
else
    fail "#754 unknown staleness is still silent; row=$row"
fi

# G5e. THE FOURTH STATE — "behind by an UNMEASURED margin". HEAD provably
#      differs from the live tip, but the margin cannot be counted (the tip
#      object is not local and no API fallback is reachable). This is NOT
#      `unknown`: staleness is PROVEN, only its size is not. Until this case
#      existed the fourth arm was an assertion placed where it could not
#      fail — the report claimed a distinct state that no test pinned.
ROOT="$WORK/g5e"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
if make_gate_clone "$ROOT" 5; then
    # Drop the tip object locally: re-clone the remote's refs without the
    # dev objects, so ls-remote still resolves a tip that `cat-file -e`
    # cannot find. Simplest faithful form: point origin at a remote whose
    # dev has advanced, and forbid fetching.
    (
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
               GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        cd "$ROOT/.gitremote" && git checkout -q dev
        for i in 6 7 8; do echo "$i" >> f; git commit -qam "dev $i"; done
        git checkout -q main
    ) >/dev/null 2>&1
    # A shim that fails `fetch` AND reports a GitHub-shaped origin URL while
    # every other call stays real. Both halves are needed: `ls-remote` must
    # SUCCEED (so a tip is resolved and HEAD != tip is proven) while the tip
    # OBJECT stays absent locally, and the origin URL must PARSE as a slug —
    # a bare local path returns `no_origin_slug`, which lands in `unknown`
    # and would silently test the wrong arm.
    _real_git=$(command -v git)
    mkdir -p "$ROOT/bin"
    cat > "$ROOT/bin/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == fetch ]] && exit 1; done
case "\$*" in *"remote get-url"*) echo "git@github.com:fake/fake.git"; exit 0 ;; esac
exec "$_real_git" "\$@"
EOF
    chmod +x "$ROOT/bin/git"
    # `gh` absent → the compare-API fallback cannot run → margin unmeasurable.
    out=$(env $(apply_env "$ROOT") MONITOR_CLONE_DRIFT_BRANCH=dev \
              PATH="$ROOT/bin:$PATH" _CLONE_DRIFT_GH_BIN=/nonexistent-gh \
              CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
              --gate-evidence "$ROOT/gate.log" --surfaces-clear \
              $SURF_OK $(cl_ok) 2>&1)
    auto="$ROOT/monitor/.state/cc-auto-update"
    row=$(grep 'deployment-gate' "$auto/decisions.tsv" 2>/dev/null | tail -1)
    if [[ "$row" == *"drift=behind"* ]] \
       && [[ "$row" == *"behind_integration=unknown"* ]] \
       && grep -q 'margin could not be measured' <<<"$out"; then
        pass "proven-stale but unmeasured margin is its own state, not 'unknown'"
    else
        fail "#754 fourth state (behind, margin unknown) not distinct; row=$row"
    fi
else
    fail "#754 fixture: could not build the gate git clone (G5e skipped)"
fi

# make_branch_config <root> <key> <value> — a config/load.sh faithful to
# the real loader's EXIT CODES, which is the whole mechanism #763 turns
# on: rc 0 = present, rc 2 = absent, and NO default is echoed for an
# unknown key. The previous stub answered `echo "${2:-}"` (rc 0, empty)
# for every unknown key, which cannot exhibit an absent-key fall-through
# at all — it would pass for a resolver that never fell through.
make_branch_config() {
    local root="$1" key="$2" value="$3"
    mkdir -p "$root/config"
    cat > "$root/config/load.sh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "$key" ]]; then printf '%s' "$value"; exit 0; fi
if (( \$# >= 2 )); then printf '%s' "\$2"; exit 0; fi
exit 2
EOF
    chmod +x "$root/config/load.sh"
}

# gate_branch_case <label> <suffix> <config-key> — build a clone whose
# integration branch is `release`, record it under <config-key>, and
# assert the gate measured `release`.
gate_branch_case() {
    local label="$1" suffix="$2" key="$3"
    local ROOT="$WORK/$suffix"
    make_apply_root "$ROOT" "2.1.150" "2.1.160"
    if ! make_gate_clone "$ROOT" 5; then
        fail "#763 fixture: could not build the gate git clone ($suffix skipped)"
        return
    fi
    git -C "$ROOT" update-ref refs/remotes/origin/release "$(git -C "$ROOT" rev-parse origin/dev)"
    ( cd "$ROOT/.gitremote" && git branch -f release dev ) >/dev/null 2>&1
    make_branch_config "$ROOT" "$key" release
    local out row auto
    out=$(env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 \
              bash "$APPLY" safe --candidate 2.1.160 \
              --gate-evidence "$ROOT/gate.log" --surfaces-clear \
              $SURF_OK $(cl_ok) 2>&1)
    auto="$ROOT/monitor/.state/cc-auto-update"
    row=$(grep 'deployment-gate' "$auto/decisions.tsv" 2>/dev/null | tail -1)
    if [[ "$row" == *"integration_branch=release"* ]] \
       && grep -q 'pull --ff-only origin release' <<<"$out"; then
        pass "$label"
    else
        fail "$label — row=$row"
    fi
}

# G5d. THE BRANCH IS NOT HARDCODED. Swapping `dev` for a literal would be
#      the same proxy one branch over, so the resolver is exercised against
#      a non-default branch read from config — not from the environment,
#      which would leave the config path untested.
gate_branch_case "integration branch resolved from config, not hardcoded (release)" \
                 g5d monitor.integration_branch

# G5f. THE MIGRATION, AT THE CONSUMER (your-org/nexus-code#763). Identical
#      fixture, but the value lives under the DEPRECATED
#      `monitor.clone_drift.branch` — the state every existing operator
#      clone is in, since `config/nexus.yml` is per-operator and not
#      tracked here. A bare rename answers `dev` for this config, and does
#      it silently, on the exact surface #754 had just finished making
#      trustworthy. This is the gate-level twin of test-config-integration-branch.sh's
#      M1; that suite proves the resolver, this one proves the consumer
#      actually reaches it.
gate_branch_case "deprecated key still measured at the GATE, not silently 'dev' (#763)" \
                 g5f monitor.clone_drift.branch

# ---- #866: an UNQUALIFIED tracking_issue must REFUSE to fire ----------------
#
# The defect: a bare number in monitor.cc_auto_update.tracking_issue was
# interpolated into the prompt, where the template paired it with SURFACE_REPO.
# A reference written for one repo was consumed against another, and every
# evaluation posted successfully to an unrelated closed PR for a month.
#
# The fix must REFUSE, not correct: declining to fire is visible on the next
# fire, whereas a misrouted evaluation is invisible forever. So the assertions
# are about the NEGATIVE — no spawn, no prompt — plus an audit row that names
# the reason, and a positive control that the same rig DOES fire when the
# reference is qualified (otherwise "no spawn" proves nothing).

ROOT="$WORK/r866a"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
FETCH_VERSION="2.1.160"
MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE=229 \
    NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
auto="$ROOT/monitor/.state/cc-auto-update"
[[ ! -e "$SPAWN_LOG" ]] \
    && pass "#866 bare tracking_issue → evaluator NOT spawned" \
    || fail "#866 bare tracking_issue spawned anyway"
[[ ! -f "$auto/eval-prompt-$DAY.md" ]] \
    && pass "#866 …and no prompt was rendered with a guessed repo" \
    || fail "#866 prompt rendered despite an unqualified reference"
if grep -q 'refused-unqualified-tracking-issue' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#866 …and the refusal is recorded in decisions.tsv"
else
    fail "#866 no audit row for the refusal: $(cat "$auto/decisions.tsv" 2>/dev/null)"
fi

# POSITIVE CONTROL: identical rig, QUALIFIED reference → fires, and the prompt
# carries the reference's OWN repo rather than the surface repo.
ROOT="$WORK/r866b"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
FETCH_VERSION="2.1.160"
MONITOR_CC_AUTO_UPDATE_TRACKING_ISSUE="your-org/your-nexus#229" \
    NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
auto="$ROOT/monitor/.state/cc-auto-update"
prompt="$auto/eval-prompt-$DAY.md"
[[ -e "$SPAWN_LOG" ]] \
    && pass "#866 CONTROL: qualified reference → evaluator DOES spawn" \
    || fail "#866 CONTROL: qualified reference did not spawn (the negative above proves nothing)"
if [[ -f "$prompt" ]] && grep -q 'your-org/your-nexus' "$prompt"; then
    pass "#866 …and the prompt carries the reference's OWN repo"
else
    fail "#866 prompt lost the reference's repo"
fi
if [[ -f "$prompt" ]] && ! grep -q '{{TRACKING_REPO}}' "$prompt"; then
    pass "#866 …and TRACKING_REPO is substituted, not left as a placeholder"
else
    fail "#866 TRACKING_REPO placeholder survived into the prompt"
fi
# The number alone must not be paired with the surface repo anywhere.
if [[ -f "$prompt" ]] && ! grep -qE 'issue comment 229 --repo your-org/nexus-code' "$prompt"; then
    pass "#866 …and 229 is never paired with the surface repo"
else
    fail "#866 the reference number got paired with SURFACE_REPO"
fi

# ---- summary --------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
