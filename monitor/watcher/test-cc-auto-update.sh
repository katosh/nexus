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
    # green gate evidence mentioning the candidate
    printf 'gating %s\n=== GATE GREEN — candidate is safe to promote ===\n' "$candidate" \
        > "$root/gate.log"
}

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
        CC_AUTO_INVARIANT_TRIES=1 \
        CC_AUTO_IDLE_WAIT_SECONDS=2 CC_AUTO_IDLE_POLL_SECONDS=1 \
        CC_AUTO_ARM_WAIT_SECONDS=2 CC_AUTO_ARM_POLL_SECONDS=1
}

# 12. full safe run, INLINE detach (synchronous, deterministic). The
#     idle pane → clean restart; CC_AUTO_RESTART_INLINE=1 runs the
#     hand-off in-process so the whole chain is observable in one shot.
ROOT="$WORK/a12"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
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
t0=$(date +%s)
env $(apply_env "$ROOT") CC_AUTO_IDLE_WAIT_SECONDS=4 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    > "$ROOT/out.log" 2>&1
rc=$?; elapsed=$(( $(date +%s) - t0 ))
fg_ok=0
(( rc == 0 )) && (( elapsed < 3 )) \
    && grep -q $'\tsafe-bumped-restart-handoff\t' "$auto/decisions.tsv" 2>/dev/null \
    && fg_ok=1
# Poll up to ~16s for the detached child to wait out the cap + force-kill.
killed=0
for _ in $(seq 1 80); do
    if grep -q "kill-window -t orchestrator" "$ROOT/calls.log" 2>/dev/null \
       && grep -q $'\tsafe-bumped-restart-forced\t' "$auto/decisions.tsv" 2>/dev/null; then
        killed=1; break
    fi
    sleep 0.2
done
if (( fg_ok == 1 && killed == 1 )); then
    pass "safe detaches (rc 0 + handoff in ${elapsed}s ≪ 4s wait); child force-restarts on its own"
else
    fail "detach path wrong (rc=$rc elapsed=${elapsed}s fg_ok=$fg_ok killed=$killed): $(tail -2 "$ROOT/out.log")"
fi

# 13. refusals: no attestation / no evidence / red gate
ROOT="$WORK/a13"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "refused without --surfaces-clear (pin untouched)" \
    || fail "missing attestation not refused"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --surfaces-clear >/dev/null 2>&1
(( $? == 3 )) && pass "refused without gate evidence" || fail "missing evidence not refused"
printf 'gating 2.1.160\n=== GATE RED — do NOT promote this version ===\n' > "$ROOT/gate.log"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "refused on a RED gate log" || fail "red gate not refused"

# 14. stale gate evidence
ROOT="$WORK/a14"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
touch -d '8 hours ago' "$ROOT/gate.log"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
(( $? == 3 )) && pass "refused on stale gate evidence" || fail "stale evidence not refused"

# 15. install failure → rollback, no watcher restart, no kill
ROOT="$WORK/a15"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") INSTALL_RC=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
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
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
(( $? == 5 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "verify mismatch → rc 5, pin rolled back" \
    || fail "verify mismatch mishandled"

# 17. already-pinned → no-op
ROOT="$WORK/a17"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '2.1.160\n' > "$ROOT/monitor/.state/cc-version-local"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
(( $? == 0 )) && ! grep -q "install" "$ROOT/calls.log" \
    && pass "already-pinned → rc 0 no-op" || fail "already-pinned re-ran the bump"

# 18. stale session pin → bump stands, NO kill, rc 21
ROOT="$WORK/a18"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
rm -f "$ROOT/monitor/.state/orchestrator-session-id"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
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
printf '#!/usr/bin/env bash\necho "usage: pane-state.sh <window-index>" >&2\nexit 2\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
t0=$(date +%s)
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?; elapsed=$(( $(date +%s) - t0 ))
if (( rc == 23 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && (( elapsed < 2 )) \
   && grep -q $'\tsafe-bumped-restart-aborted\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "unreadable pane-state → fail-loud (rc 23, no kill, no wait)"
else
    fail "unreadable-pane-state handling wrong (rc=$rc, elapsed=${elapsed}s)"
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

# ===== deployment gate (nexus-code#512) ====================================

echo "== deployment gate =="

# G1. an open PR touching the watcher restart path DEFERS the apply:
#     rc 30, NOTHING mutated (no pin, no install), outcome safe-deferred
#     with the PR pinned in the detail.
ROOT="$WORK/g1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nprintf "503\\tmonitor/watcher/launcher.sh\\n503\\tmonitor/README.md\\n"\n' > "$ROOT/gate-prs"
chmod +x "$ROOT/gate-prs"
env $(apply_env "$ROOT") CC_AUTO_GATE_PR_CMD="$ROOT/gate-prs" bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
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
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
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
    bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
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
    bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
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
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear >/dev/null 2>&1
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
printf '%s' "$out" | grep -q 'autonomous daily cc-update routine is ENABLED' \
    && pass "emit NOTE present when routine enabled" \
    || fail "emit NOTE missing when enabled"
rm -f "$SD/cc-update-surfaced"
out=$(MONITOR_CC_AUTO_UPDATE_ENABLED=false _cc_update_emit_section "$SD")
printf '%s' "$out" | grep -q 'autonomous daily' \
    && fail "emit NOTE leaked when disabled" \
    || pass "emit NOTE absent when routine disabled"

# ---- summary --------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
