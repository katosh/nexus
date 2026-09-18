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
#    11b. #1211: the record-outcome VERB writes last-eval and PRINTS the
#         row + content it wrote; a verb-written decision=block for the
#         current candidate suppresses the next fire, block-surfaced
#         (inverse control) does not.
#    11c. #1211: record-outcome context guard — NEXUS_WORKER_WINDOW set to
#         a non-evaluator window → rc 40, neither file touched;
#         --allow-context, unset, and the evaluator window all write;
#         keyed on CC_AUTO_WINDOW; a write that does not land → rc 41.
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
#    E3.  shell-driven working-background whose EVERY root is quiescent
#         (bg_reliable=1, bg_quiesce >= bg_shells) IS a turn boundary →
#         clean restart. The orchestrator between turns on current builds.
#    E4.  E3 + one root not quiescent (bg_shells=2 bg_quiesce=1) → forced.
#    E5.  E3 but bg_reliable=0 → forced.
#    E6.  E3 but no bg_quiesce field (an older pane-state) → forced.
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
#    G3.  live agent windows: the COUNT is RECORDED, never a veto (the
#         max_live_windows arm was removed 2026-09-12, operator decision —
#         see the deployment-gate knob block in apply.sh); infra exempt.
#    G3b. …and the count lands in the apply record on a clean apply.
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
# WHY SCRUBBING IS SAFE, stated as the PROPERTY rather than as a hand count
# (your-org/nexus-code#1343). This paragraph used to read "the suite pins
# NEXUS_ROOT at each of its six explicit spawn call sites" -- a hand-enumerated
# completeness claim, and measured at bbf8985b NOTHING here is six:
# `spawn-worker` references 0, CC_AUTO_SPAWN_CMD assignments 18, make_spawn_stub
# calls 17, run_tick sites 33, direct _cc_auto_update_tick calls 1, apply_env
# uses 88. The conclusion was right and the evidence was not evidence of it --
# which is this file's own #1343 shape, in the comment whose entire job is to
# justify the `unset` on the next line.
#
# The property that IS load-bearing, and unlike a site count it does not drift:
#   - EVERY ROOT REACHING PRODUCTION CODE IS A FUNCTION PARAMETER. run_tick
#     (:225-228) passes "$1" and "$1/monitor/.state" down, and the production
#     spawn default in monitor/watcher/_cc_auto_update.sh is
#     ${CC_AUTO_SPAWN_CMD:-$nexus_root/monitor/spawn-worker.sh} with $nexus_root
#     being that parameter -- so even a completely unstubbed spawn targets the
#     fixture, not the operator's primary.
#   - Zero bare $NEXUS_ROOT reads in executable code, here or in the three
#     sourced modules. With `set -u` never relaxed (:125) a bare ambient read
#     would ABORT the suite rather than leak.
#   - The only defaulted ambient reads are five ${N:-${NEXUS_ROOT:-}} sites in
#     monitor/_cc-version.sh, which fall back to the EMPTY STRING -- never to a
#     config lookup. That distinction is your-org/nexus-code#1349: unsetting
#     NEXUS_ROOT does not END a resolver's search, it ADVANCES it, and
#     monitor/ng:380-396 falls through to config `nexus.root` -- which resolves
#     to the operator's primary when read through the primary's own tooling.
#     Falling back to empty is the safe shape; falling back to a config lookup
#     is not.
#
# COROLLARY, measured (#1349): do NOT "isolate" this suite by pinning
# NEXUS_STATE_DIR. That is arm 1 and unconditional, so it overrides the
# per-fixture NEXUS_ROOT above and collapses every fixture into one directory:
# 196 passed/0 failed becomes 87 passed/119 failed. The isolation here IS the
# per-fixture root; pinning arm 1 defeats it.
unset NEXUS_ROOT

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MONITOR_DIR=$(cd "$_script_dir/.." && pwd)
# shellcheck source=_cc_update.sh
source "$_script_dir/_cc_update.sh"
# shellcheck source=../_cc-version.sh
source "$MONITOR_DIR/_cc-version.sh"
# shellcheck source=_cc_auto_update.sh
source "$_script_dir/_cc_auto_update.sh"
# For the #1492 predicate check (P3). apply.sh sources this too; the suite
# needs it in its OWN shell to call bk_is_transient_window_name directly.
# shellcheck source=../_bookkeeping.sh
source "$MONITOR_DIR/_bookkeeping.sh"

# ---------------------------------------------------------------------------
# POPULATION DECLARATION (your-org/nexus-code#1494, #1301 item 2)
# ---------------------------------------------------------------------------
#
# This suite carries the bulk of the assertions exercising
# `monitor/cc-auto-update-apply.sh`, and on PR #1493 — a diff whose subject WAS
# that file — it was INVISIBLE to `ng guards-for-diff`: absent from SELECTED
# and from CONSIDERED AND EXCLUDED alike, because it declared no population.
# The largest suite exercising the changed file was outside the index's field
# of view while 28 other guards were selected and green.
#
# The population is NAMED rather than swept: this guard reads a fixed set of
# files, so the honest declaration is that set. It is the four libraries it
# SOURCES (bash reads those bytes, and an edit to any can change the verdict),
# the script under test, the two prompt templates that script renders, and the
# two helpers it shells out to. Sourced libraries are the members a
# "what does this file scan" reading omits, and they are the ones most likely
# to change under it.
#
# PLACED HERE, above the first thing this suite prints: `gp_handle` EXITS when
# it handles the flag, and anything printed before it lands in the probe's
# stdout and is read as a population row.
. "$MONITOR_DIR/_guard_population.sh"
gp_population() {
    printf '%s\n' \
        "$MONITOR_DIR/cc-auto-update-apply.sh" \
        "$MONITOR_DIR/cc-auto-update-prompt.md" \
        "$MONITOR_DIR/cc-auto-update-watchdog-prompt.md" \
        "$MONITOR_DIR/_cc-version.sh" \
        "$MONITOR_DIR/_bookkeeping.sh" \
        "$MONITOR_DIR/issue-ref.sh" \
        "$MONITOR_DIR/pane-state.sh" \
        "$_script_dir/_cc_update.sh" \
        "$_script_dir/_cc_auto_update.sh"
}
gp_handle "$@"

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

# A claude stub that REPORTS WHAT THE PIN SAYS (local pin else the floor),
# rather than a hardcoded version — i.e. a CONSISTENT live tree, which is what
# every verb now asserts before recording a verdict (your-org/nexus-code#1002:
# `$CLAUDE_BIN --version` must equal `cc_version_effective`). Defined HERE,
# above every fixture that uses it, because it once lived below its first
# caller and the call was a silent command-not-found (see the RB cases).
#   $1=root  $2=floor  [$3=path, default $root/claude]
make_pin_following_claude() {
    local root="$1" floor="$2" path="${3:-$1/claude}"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
#!/usr/bin/env bash
v=\$(cat "$root/monitor/.state/cc-version-local" 2>/dev/null)
[[ -n "\$v" ]] || v="$floor"
echo "\$v (Claude Code)"
EOF
    chmod +x "$path"
}

make_root() {
    # A miniature nexus root: package.json floor + the prompt template.
    local root="$1" floor="$2"
    mkdir -p "$root/monitor/.state"
    # A consistent live tree at the DEFAULT CLAUDE_BIN path, for verbs
    # invoked without CC_AUTO_CLAUDE_BIN (block, compat-pr): the #1002
    # assertion reads it before recording any verdict.
    make_pin_following_claude "$root" "$floor" "$root/node_modules/.bin/claude"
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
# w241sk D2: the evaluator's window name is written where the PreToolUse hook
# reads its scope.
[[ "$(cat "$auto/evaluator-window" 2>/dev/null)" == "cc-auto-update" ]] \
    && pass "#1529 evaluator-window marker written for the hook's scope" \
    || fail "#1529 evaluator-window marker missing or wrong: $(cat "$auto/evaluator-window" 2>/dev/null)"
[[ "$(cat "$ROOT/monitor/.state/cc-update-surfaced" 2>/dev/null)" == "2.1.160" ]] \
    && pass "candidate marked surfaced (manual-flow nag consumed)" \
    || fail "cc-update-surfaced not written"

# 9. second tick same day → no second spawn
NEXUS_TEST_NOW=$(epoch_at 06:00) run_tick "$ROOT" fetch_ok
[[ "$(wc -l < "$SPAWN_LOG")" == "1" ]] \
    && pass "same-day re-tick is a no-op" \
    || fail "spawned twice in one day"

# 10. evaluator window alive → no spawn, and the day is DEFERRED not consumed
#     (your-org/nexus-code#968).
#
# This case used to assert `[[ -f last-fire-date ]]` — it pinned the defect.
# A crashed-but-alive evaluator satisfies `_cc_auto_window_alive`, so stamping
# here cancelled the round outright: measured on 2026-08-20/21, one crashed
# session cost the whole 08-21 fire and would have cost every one after it.
ROOT="$WORK/r10"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
_WINDOW_ALIVE=1
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
auto="$ROOT/monitor/.state/cc-auto-update"
[[ ! -e "$SPAWN_LOG" ]] \
    && pass "live evaluator window blocks the spawn" \
    || fail "window-alive guard did not block the spawn"
grep -q "skipped-window-alive" "$auto/decisions.tsv" 2>/dev/null \
    && pass "…and records why, once" \
    || fail "no skipped-window-alive audit row"
[[ ! -e "$auto/last-fire-date" ]] \
    && pass "#968: the skip path does NOT consume the day's fire" \
    || fail "#968: skip path stamped last-fire-date — the day is cancelled, not deferred"

# 10b. …and the retry that the un-consumed day makes possible actually fires
#      once the stale window clears. This is the property; 10 alone would pass
#      for an implementation that simply never fires again.
_WINDOW_ALIVE=0
NEXUS_TEST_NOW=$(epoch_at 05:05) run_tick "$ROOT" fetch_ok
[[ -e "$SPAWN_LOG" ]] \
    && pass "#968: the SAME day retries and spawns once the window clears" \
    || fail "#968: no retry after the window cleared — the day was still consumed"
[[ -f "$auto/last-fire-date" ]] \
    && pass "…and the successful fire is what stamps the day" \
    || fail "#968: a successful fire failed to stamp last-fire-date"

# 10c. the audit row stays once-per-day under the 300s retry cadence. Without
#      this the fix trades a silent cancellation for ~288 identical rows a day,
#      and a log that repeats is read as often as one that is silent.
ROOT="$WORK/r10c"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
_WINDOW_ALIVE=1
for t in 05:00 05:05 05:10 05:15; do
    NEXUS_TEST_NOW=$(epoch_at "$t") run_tick "$ROOT" fetch_ok
done
_WINDOW_ALIVE=0
auto="$ROOT/monitor/.state/cc-auto-update"
n_rows=$(grep -c "skipped-window-alive" "$auto/decisions.tsv" 2>/dev/null) || n_rows=0
[[ "$n_rows" == "1" ]] \
    && pass "#968: four skipped ticks in one day write ONE audit row" \
    || fail "#968: four skipped ticks wrote $n_rows audit rows, want 1"
[[ ! -e "$auto/last-fire-date" ]] \
    && pass "…and four skips still leave the day un-consumed" \
    || fail "#968: repeated skips consumed the day"

# ===== #968 part 2: LIVENESS, not mere window existence ====================
#
# Not stamping (10/10b/10c) turns a silent CANCELLATION into an unbounded
# silent DEFERRAL — the same round never running, differently spelled. The
# 2026-08-20 corpse satisfied `_cc_auto_window_alive` for as long as it
# existed, so the axis these cases pin is the one that ends the deferral:
# whether a pane is doing WORK, and the default-DENY arm that decides what
# happens when that cannot be established.

# Day offsets so the streak cases below cross real calendar days. `+N day`
# is NOT usable here: GNU date parses `+1` as a TIMEZONE offset (measured:
# `date -d "2026-06-12 05:00 +1 day"` → 21:00 the SAME day). `N days` is.
epoch_on() { date -d "$DAY $2 $1 days" +%s; }   # epoch_on 2 05:00

make_pane_stub() {   # $1=path  $2=verbatim pane-state stdout
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %q\n' "$2" > "$1"
    chmod +x "$1"
}

# 10d. an evaluator pane POSITIVELY stalled past the threshold is not a
#      live evaluator: the round reclaims its window and fires. This is
#      the 2026-08-20 corpse, and without it #968 stays half-fixed.
ROOT="$WORK/r10d"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
make_pane_stub "$ROOT/pane-state" "state=idle active=1 window=4 name=cc-auto-update"
CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
_WINDOW_ALIVE=1
auto="$ROOT/monitor/.state/cc-auto-update"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
[[ ! -e "$SPAWN_LOG" ]] && [[ -f "$auto/evaluator-stalled-since" ]] \
    && pass "#968: a first stalled reading starts the clock, it does not reclaim" \
    || fail "#968: a single stalled reading reclaimed the window (no dwell)"
NEXUS_TEST_NOW=$(epoch_at 05:20) run_tick "$ROOT" fetch_ok
[[ ! -e "$SPAWN_LOG" ]] \
    && pass "#968: 1200s of stall is still UNDER the 1800s dwell — no reclaim" \
    || fail "#968: reclaimed at 1200s, under the dwell — the age comparison is not against the threshold"
NEXUS_TEST_NOW=$(epoch_at 05:31) run_tick "$ROOT" fetch_ok
[[ -e "$SPAWN_LOG" ]] && grep -q "evaluator-window-reclaimed" "$auto/decisions.tsv" 2>/dev/null \
    && pass "#968: a pane stalled past the threshold is reclaimed and the round fires" \
    || fail "#968: a 31-min-stalled corpse still blocked the round"
grep -q 'stalled_for=1860s' "$auto/decisions.tsv" 2>/dev/null \
    && pass "…and the row carries the reading that produced the verdict" \
    || fail "reclaim row lacks the measured stall age: $(grep reclaimed "$auto/decisions.tsv" | tail -1)"

# 10e. POTENCY / the dangerous direction. A pane that is WORKING is never
#      reclaimed, however long the round has been waiting — the fire path
#      KILLS this window before spawning, so a wrong verdict here destroys
#      a live evaluator mid-run.
ROOT="$WORK/r10e"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
make_pane_stub "$ROOT/pane-state" "state=busy active=1 window=4 name=cc-auto-update"
CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
_WINDOW_ALIVE=1
auto="$ROOT/monitor/.state/cc-auto-update"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
NEXUS_TEST_NOW=$(epoch_at 09:00) run_tick "$ROOT" fetch_ok
[[ ! -e "$SPAWN_LOG" ]] && ! grep -q "evaluator-window-reclaimed" "$auto/decisions.tsv" 2>/dev/null \
    && pass "#968: a WORKING evaluator is never reclaimed, however long the wait" \
    || fail "#968: a busy evaluator was reclaimed — the fire path would have killed it"
grep -q 'class=working state=busy' "$auto/decisions.tsv" 2>/dev/null \
    && pass "…and the deferral row names the class and the state it read" \
    || fail "skip row lacks the class/state reading: $(grep skipped "$auto/decisions.tsv" | tail -1)"

# 10f. DEFAULT-DENY. An INDETERMINATE reading (`empty`, `unknown`, an
#      unreadable probe, a state this module has never heard of) never
#      reclaims — and never starts the clock either, so it cannot age into
#      a reclaim. "Could not look" is not "finished".
for st in "state=empty active=1" "state=unknown active=0" "state=wharrgarbl active=1" ""; do
    ROOT="$WORK/r10f-$RANDOM"; make_root "$ROOT" "2.1.150"
    SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
    CC_AUTO_SPAWN_CMD="$ROOT/spawn"
    make_pane_stub "$ROOT/pane-state" "$st"
    CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
    _WINDOW_ALIVE=1
    auto="$ROOT/monitor/.state/cc-auto-update"
    NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
    NEXUS_TEST_NOW=$(epoch_at 12:00) run_tick "$ROOT" fetch_ok
    [[ ! -e "$SPAWN_LOG" ]] && [[ ! -f "$auto/evaluator-stalled-since" ]] \
        && pass "#968 default-deny: '${st:-<no output>}' never reclaims and never accrues" \
        || fail "#968 default-deny breached for '${st:-<no output>}' (spawned=$([[ -e $SPAWN_LOG ]] && echo yes || echo no))"
done

# 10g. …but an indeterminate reading must not RESET an already-accrued
#      stall. `empty` is a documented transient; letting it clear the clock
#      would make a stall unaccruable and re-instate the unbounded deferral
#      through the back door. Only positive evidence of WORK clears it.
ROOT="$WORK/r10g"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
_WINDOW_ALIVE=1
auto="$ROOT/monitor/.state/cc-auto-update"
make_pane_stub "$ROOT/pane-state" "state=idle active=1"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
make_pane_stub "$ROOT/pane-state" "state=empty active=1"
NEXUS_TEST_NOW=$(epoch_at 05:15) run_tick "$ROOT" fetch_ok
make_pane_stub "$ROOT/pane-state" "state=idle active=1"
NEXUS_TEST_NOW=$(epoch_at 05:31) run_tick "$ROOT" fetch_ok
[[ -e "$SPAWN_LOG" ]] \
    && pass "#968: an 'empty' flicker does not reset an accrued stall" \
    || fail "#968: a transient 'empty' reset the stall clock — the stall is unaccruable"

# 10h. …and the mirror: a WORKING reading DOES reset it, so a stall that
#      was interrupted by real work has to accrue again from scratch.
ROOT="$WORK/r10h"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
_WINDOW_ALIVE=1
make_pane_stub "$ROOT/pane-state" "state=idle active=1"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
make_pane_stub "$ROOT/pane-state" "state=working-background active=1"
NEXUS_TEST_NOW=$(epoch_at 05:15) run_tick "$ROOT" fetch_ok
make_pane_stub "$ROOT/pane-state" "state=idle active=1"
NEXUS_TEST_NOW=$(epoch_at 05:31) run_tick "$ROOT" fetch_ok
[[ ! -e "$SPAWN_LOG" ]] \
    && pass "#968: real work in between resets the clock — the stall re-accrues" \
    || fail "#968: a working reading failed to reset the stall clock"

# 10i. queued input is work in flight whatever the base verdict says
#      (your-org/nexus-code#607): a turn already waiting behind the running
#      one must not be reclaimed as an idle corpse.
ROOT="$WORK/r10i"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
make_pane_stub "$ROOT/pane-state" "state=idle active=1 queued=1"
CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
_WINDOW_ALIVE=1
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
NEXUS_TEST_NOW=$(epoch_at 09:00) run_tick "$ROOT" fetch_ok
[[ ! -e "$SPAWN_LOG" ]] \
    && pass "#968: queued=1 is work in flight — never reclaimed" \
    || fail "#968: a pane with queued input was reclaimed as a corpse"

# 10j. THE VOCABULARY IS ASKED, NOT COPIED. CLAUDE.md's rule exists because
#      a hand-copied state list omitted `unknown` — the state meaning "could
#      not look at all" — and the omission fell into a permissive arm. Drive
#      the classifier with the LIVE vocabulary (`pane-state.sh --states`) and
#      require every member to land in exactly one class, with every member
#      NOT in the working/stalled allowlists landing in the DENY class.
if [[ -x "$MONITOR_DIR/pane-state.sh" ]]; then
    vocab_bad=0 vocab_n=0 vocab_deny=0
    while IFS= read -r st; do
        [[ -n "$st" ]] || continue
        vocab_n=$(( vocab_n + 1 ))
        ROOT="$WORK/r10j"; mkdir -p "$ROOT"
        make_pane_stub "$ROOT/pane-state" "state=$st active=1"
        CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
        cls=$(_cc_auto_evaluator_class dummy "$ROOT")
        case "$cls" in
            "working $st"|"stalled $st") ;;
            "indeterminate $st") vocab_deny=$(( vocab_deny + 1 )) ;;
            *) vocab_bad=$(( vocab_bad + 1 ))
               fail "#968 vocabulary: state '$st' classified as '$cls' — not a class, or the state was mangled" ;;
        esac
    done < <("$MONITOR_DIR/pane-state.sh" --states)
    (( vocab_n >= 10 && vocab_bad == 0 )) \
        && pass "#968: all $vocab_n live pane-state verdicts classify (deny arm caught $vocab_deny)" \
        || fail "#968 vocabulary sweep: n=$vocab_n bad=$vocab_bad (a zero n means the sweep never ran)"
    # DISJOINTNESS IS ASSERTED, NOT COMMENTED. The classifier tries
    # _CC_AUTO_WORKING_STATES first and _CC_AUTO_STALLED_STATES second, so the
    # source's claim that "no input matches two arms and no reordering changes
    # an answer" is load-bearing for #1121 — and the sweep above cannot see a
    # violation, because a state in BOTH lists still lands in exactly one class
    # (the first one tried). Measured: adding `blocked` to the WORKING list
    # leaves this suite at 195/0 while turning a blocked evaluator into a
    # permanently "working" one — #968's symptom, restored, silently.
    _ov=""
    for _w in "${_CC_AUTO_WORKING_STATES[@]}"; do
        for _s in "${_CC_AUTO_STALLED_STATES[@]}"; do
            [[ "$_w" == "$_s" ]] && _ov="$_ov $_w"
        done
    done
    if [[ -z "$_ov" ]]; then
        pass "#968: the working and stalled allowlists are DISJOINT, so arm order cannot decide a verdict (#1121)"
    else
        fail "#968: working/stalled allowlists OVERLAP on:$_ov — the first arm tried silently wins and the source's disjointness claim is false"
    fi

    make_pane_stub "$ROOT/pane-state" "state=unknown active=1"
    CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
    unk_cls=$(_cc_auto_evaluator_class dummy "$ROOT")
    grep -qx 'unknown' <("$MONITOR_DIR/pane-state.sh" --states) \
        && [[ "$unk_cls" == "indeterminate unknown" ]] \
        && pass "#968: unknown — the state that means could-not-look — lands in the DENY arm" \
        || fail "#968: unknown is not denied (the exact omission CLAUDE.md records)"
else
    fail "#968 vocabulary sweep SKIPPED: $MONITOR_DIR/pane-state.sh not executable — an unrun sweep is not a pass"
fi

# ===== #968 part 3: a round that has stopped running must SAY SO ==========
#
# The 2026-08-20 cancellation was invisible because `skipped-window-alive`
# is written and never read: no alert, no emit, no summary. A deferral that
# repeats is a stuck round, and it has to reach the operator.

# 10k. two consecutive DEFERRED days escalate; one does not.
ROOT="$WORK/r10k"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
make_pane_stub "$ROOT/pane-state" "state=busy active=1"
CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"
_WINDOW_ALIVE=1
auto="$ROOT/monitor/.state/cc-auto-update"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
! grep -q "skipped-window-alive-escalation" "$auto/decisions.tsv" 2>/dev/null \
    && pass "#968: ONE deferred day is routine — no escalation" \
    || fail "#968: escalated on day 1 (an alert that fires every time is not read)"
NEXUS_TEST_NOW=$(epoch_on 1 05:00) run_tick "$ROOT" fetch_ok
grep -q "skipped-window-alive-escalation" "$auto/decisions.tsv" 2>/dev/null \
    && grep -q "streak=2" "$auto/decisions.tsv" 2>/dev/null \
    && pass "#968: TWO consecutive deferred days escalate, with the streak in the row" \
    || fail "#968: a second silently-deferred day produced no escalation — the #968 blind spot"
n_esc=$(grep -c "skipped-window-alive-escalation" "$auto/decisions.tsv" 2>/dev/null) || n_esc=0
NEXUS_TEST_NOW=$(epoch_on 1 05:05) run_tick "$ROOT" fetch_ok
n_esc2=$(grep -c "skipped-window-alive-escalation" "$auto/decisions.tsv" 2>/dev/null) || n_esc2=0
[[ "$n_esc" == "$n_esc2" ]] \
    && pass "…and the escalation stays once-per-day under the 300s retry cadence" \
    || fail "#968: escalation fired $n_esc2 times in one day (was $n_esc) — a log that repeats is unread"

# 10l. …and the streak RESETS once a round actually gets past the guard, so
#      the alert is about NOW and not about an old grievance.
[[ -f "$auto/skip-streak" ]] && grep -q '^days=2$' "$auto/skip-streak" \
    && pass "…and the streak is a real counter on disk, not a coerced default" \
    || fail "#968: skip-streak missing or not at days=2 before the clearing fire: $(cat "$auto/skip-streak" 2>/dev/null | tr '\n' ' ')"
_WINDOW_ALIVE=0
NEXUS_TEST_NOW=$(epoch_on 1 05:10) run_tick "$ROOT" fetch_ok
[[ -e "$SPAWN_LOG" ]] && [[ ! -f "$auto/skip-streak" ]] \
    && pass "#968: a round that fires clears the deferral streak" \
    || fail "#968: streak survived a successful fire (spawned=$([[ -e $SPAWN_LOG ]] && echo yes || echo no))"

# 10m. your-org/nexus-code#1342 — the escalation has a RE-NAG guard, the same
#      idiom the restart-abort arm uses 283 lines up. Six consecutive deferred
#      days: landed `dev` wrote 0 1 2 3 4 5 escalation rows (one every day from
#      day 2); the guarded form writes 0 1 1 1 1 1 at the default repeat (7).
ROOT="$WORK/r10m"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
make_pane_stub "$ROOT/pane-state" "state=busy active=1"
CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"; _WINDOW_ALIVE=1
auto="$ROOT/monitor/.state/cc-auto-update"
_esc_series=""
for d in 0 1 2 3 4 5; do
    NEXUS_TEST_NOW=$(epoch_on "$d" 05:00) run_tick "$ROOT" fetch_ok
    _n=$(grep -c skipped-window-alive-escalation "$auto/decisions.tsv" 2>/dev/null); _esc_series="${_esc_series:+$_esc_series }${_n:-0}"
done
[[ "$_esc_series" == "0 1 1 1 1 1" ]] \
    && pass "#1342: six deferred days escalate ONCE at the default repeat (rows per day: $_esc_series)" \
    || fail "#1342: escalation re-nags daily — rows per day: $_esc_series (want 0 1 1 1 1 1; landed dev gave 0 1 2 3 4 5)"
# POTENCY: the repeat knob is read. At repeat=2 the series is 0 1 1 2 2 3.
ROOT="$WORK/r10m2"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
make_pane_stub "$ROOT/pane-state" "state=busy active=1"
CC_AUTO_PANE_STATE_CMD="$ROOT/pane-state"; _WINDOW_ALIVE=1
auto="$ROOT/monitor/.state/cc-auto-update"
_esc_series=""
for d in 0 1 2 3 4 5; do
    CC_AUTO_SKIP_STREAK_REPEAT=2 NEXUS_TEST_NOW=$(epoch_on "$d" 05:00) run_tick "$ROOT" fetch_ok
    _n=$(grep -c skipped-window-alive-escalation "$auto/decisions.tsv" 2>/dev/null); _esc_series="${_esc_series:+$_esc_series }${_n:-0}"
done
[[ "$_esc_series" == "0 1 1 2 2 3" ]] \
    && pass "#1342 POTENCY: repeat=2 re-nags every second deferred day ($_esc_series)" \
    || fail "#1342 POTENCY: repeat knob not honoured — $_esc_series (want 0 1 1 2 2 3)"
CC_AUTO_PANE_STATE_CMD=""
_WINDOW_ALIVE=0

# 10n. your-org/nexus-code#1400 — a safe-refused outcome NOTIFIES SOMEBODY.
#      last-eval says safe-refused: the tick logs it once per day and escalates
#      when the same reason repeats.
ROOT="$WORK/r10n"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
printf 'candidate=2.1.258\ndecision=safe-refused\ndate=x\ndetail=gate-evidence:gated-tree-dirty\n' > "$auto/last-eval"
printf '%s\t2.1.258\tsafe-refused\tgate-evidence:gated-tree-dirty\n' "2026-09-02T04:22:33-07:00" > "$auto/decisions.tsv"
FETCH_VERSION="2.1.258"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
[[ "$(grep -c 'safe-refused-unapplied' "$auto/decisions.tsv" 2>/dev/null)" == 1 ]] \
    && pass "#1400: a safe-refused last-eval is SURFACED by the tick (audit row + notify)" \
    || fail "#1400: safe-refused went dark — rows: $(grep -c safe-refused-unapplied "$auto/decisions.tsv" 2>/dev/null)"
NEXUS_TEST_NOW=$(epoch_at 05:30) run_tick "$ROOT" fetch_ok
[[ "$(grep -c 'safe-refused-unapplied' "$auto/decisions.tsv" 2>/dev/null)" == 1 ]] \
    && pass "#1400: …once per day, not once per tick" \
    || fail "#1400: re-nagged within the day"
# day 2: the SAME reason again (the evaluator re-refused byte-for-byte)
printf '%s\t2.1.259\tsafe-refused\tgate-evidence:gated-tree-dirty\n' "2026-09-03T04:13:25-07:00" >> "$auto/decisions.tsv"
printf 'candidate=2.1.259\ndecision=safe-refused\ndate=x\ndetail=gate-evidence:gated-tree-dirty\n' > "$auto/last-eval"
FETCH_VERSION="2.1.259"
NEXUS_TEST_NOW=$(epoch_on 1 05:00) run_tick "$ROOT" fetch_ok
grep -q 'safe-refused-repeat' "$auto/decisions.tsv" 2>/dev/null \
    && pass "#1400: the SAME reason twice running escalates as a standing defect (safe-refused-repeat)" \
    || fail "#1400: identical second refusal not escalated: $(tail -2 "$auto/decisions.tsv")"
# CONTROL: a block outcome is NOT surfaced by this arm (it has its own path)
ROOT="$WORK/r10n2"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
printf 'candidate=2.1.258\ndecision=block\ndate=x\ndetail=red gate\n' > "$auto/last-eval"
FETCH_VERSION="2.1.258"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
! grep -q 'safe-refused-unapplied' "$auto/decisions.tsv" 2>/dev/null \
    && pass "#1400 CONTROL: a block outcome does not fire the safe-refused arm" \
    || fail "#1400 CONTROL: block outcome mis-surfaced as safe-refused"

CC_AUTO_PANE_STATE_CMD=""
_WINDOW_ALIVE=0

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

# 11b. your-org/nexus-code#1211 — the WRITER end of the awaiting-operator
#      guard. Case 11 plants last-eval by hand; this case has the
#      `record-outcome` VERB write it, so the chain verb → last-eval → Guard 4
#      is asserted end to end: a `decision=block` for the CURRENT candidate
#      suppresses the next fire, `block-surfaced` (the legitimate terminal
#      decision of a block fire) does NOT. The verb runs in the evaluator's
#      context (NEXUS_WORKER_WINDOW=cc-auto-update, what spawn-worker.sh
#      exports into the window the watcher spawns) and PRINTS what it wrote —
#      the recorded incident was a re-run "purely to read the exit code"
#      because the verb was silent on success.
ROOT="$WORK/r11b"; make_root "$ROOT" "2.1.150"
SPAWN_LOG="$ROOT/spawned.log"; make_spawn_stub "$ROOT/spawn" "$SPAWN_LOG"
CC_AUTO_SPAWN_CMD="$ROOT/spawn"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
out=$(env NEXUS_ROOT="$ROOT" NEXUS_WORKER_WINDOW=cc-auto-update \
    bash "$MONITOR_DIR/cc-auto-update-apply.sh" record-outcome \
    --candidate 2.1.160 --decision block --detail "red gate" 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == *"record-outcome: wrote"* && "$out" == *"candidate=2.1.160"* \
        && "$out" == *"decision=block"* && "$out" == *"detail=red gate"* && "$out" == *"decisions.tsv"* ]]; then
    pass "#1211 record-outcome PRINTS the decisions.tsv row + last-eval it wrote (rc 0)"
else
    fail "#1211 record-outcome silent or refused in the evaluator context: rc=$rc out=[$out]"
fi
[[ "$(_cc_update_field "$auto/last-eval" decision 2>/dev/null)" == "block" \
    && "$(_cc_update_field "$auto/last-eval" candidate 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1211 …and the last-eval on disk says what the line claims (candidate=2.1.160 decision=block)" \
    || fail "#1211 last-eval on disk disagrees with the success line: $(tr '\n' ' ' < "$auto/last-eval" 2>/dev/null)"
[[ "$(awk -F'\t' '$2=="2.1.160" && $3=="block" && $4=="red gate"' "$auto/decisions.tsv" 2>/dev/null | wc -l)" == 1 ]] \
    && pass "#1211 …and exactly ONE decisions.tsv row was appended" \
    || fail "#1211 decisions.tsv row count wrong: $(cat "$auto/decisions.tsv" 2>/dev/null)"
# The verb-written block SUPPRESSES the next fire for the same candidate.
FETCH_VERSION="2.1.160"
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
if [[ ! -e "$SPAWN_LOG" ]] && grep -qF "skipped-awaiting-operator" "$auto/decisions.tsv" 2>/dev/null \
        && grep -qF "last-eval=block" <<<"$(grep -F "skipped-awaiting-operator" "$auto/decisions.tsv")"; then
    pass "#1211 a verb-written decision=block for the CURRENT candidate suppresses the next fire (skipped-awaiting-operator)"
else
    fail "#1211 verb-written block did not suppress: spawned=$([[ -e "$SPAWN_LOG" ]] && echo yes || echo no) rows=$(cut -f3,4 "$auto/decisions.tsv" 2>/dev/null | tr '\n' ' ')"
fi
# INVERSE CONTROL: block-surfaced for the SAME candidate does NOT suppress —
# that is the terminal decision the skip set deliberately excludes, and the
# one the 2026-08-30 stray call happened to pass (harmless by luck).
rm -f "$auto/last-fire-date"
out=$(env NEXUS_ROOT="$ROOT" NEXUS_WORKER_WINDOW=cc-auto-update \
    bash "$MONITOR_DIR/cc-auto-update-apply.sh" record-outcome \
    --candidate 2.1.160 --decision block-surfaced --detail "issue commented" 2>&1); rc=$?
(( rc == 0 )) && [[ "$out" == *"decision=block-surfaced"* ]] \
    && pass "#1211 CONTROL: record-outcome block-surfaced writes and says so" \
    || fail "#1211 CONTROL: block-surfaced rc=$rc out=[$out]"
_skips_before=$(grep -cF "skipped-awaiting-operator" "$auto/decisions.tsv" 2>/dev/null) || _skips_before=0
NEXUS_TEST_NOW=$(epoch_at 05:00) run_tick "$ROOT" fetch_ok
_skips_after=$(grep -cF "skipped-awaiting-operator" "$auto/decisions.tsv" 2>/dev/null) || _skips_after=0
if [[ -e "$SPAWN_LOG" ]] && (( _skips_after == _skips_before )); then
    pass "#1211 CONTROL: decision=block-surfaced for the same candidate does NOT suppress the fire (spawned, no skip row)"
else
    fail "#1211 CONTROL: block-surfaced suppressed the fire: spawned=$([[ -e "$SPAWN_LOG" ]] && echo yes || echo no) skips $_skips_before→$_skips_after"
fi

# 11c. your-org/nexus-code#1211 — the CONTEXT guard on the verb. It keys on
#      NEXUS_WORKER_WINDOW (exported by spawn-worker.sh into every agent
#      window): set to a window OTHER than the evaluator's → refuse (rc 40)
#      and touch NEITHER file; unset (no agent window at all) or the
#      evaluator window → write. `--allow-context` is the deliberate
#      override. This guard would NOT have caught the recorded incident,
#      which came FROM the evaluator; it is worth having against a
#      worker/orchestrator/skeptic hand-invocation, the class the issue names.
ROOT="$WORK/r11c"; make_root "$ROOT" "2.1.150"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
printf 'candidate=2.1.160\ndecision=block-surfaced\ndate=x\ndetail=planted\n' > "$auto/last-eval"
cp "$auto/last-eval" "$ROOT/last-eval.before"
out=$(env NEXUS_ROOT="$ROOT" NEXUS_WORKER_WINDOW=some-worker \
    bash "$MONITOR_DIR/cc-auto-update-apply.sh" record-outcome \
    --candidate 2.1.160 --decision block --detail "stray" 2>&1); rc=$?
if (( rc == 40 )) && cmp -s "$auto/last-eval" "$ROOT/last-eval.before" && [[ ! -e "$auto/decisions.tsv" ]]; then
    pass "#1211 context guard: NEXUS_WORKER_WINDOW=some-worker → rc 40, last-eval UNTOUCHED, no decisions.tsv row"
else
    fail "#1211 context guard: rc=$rc last-eval-changed=$(cmp -s "$auto/last-eval" "$ROOT/last-eval.before" && echo no || echo YES) tsv=$([[ -e "$auto/decisions.tsv" ]] && echo present || echo absent) out=[$out]"
fi
[[ "$out" == *"some-worker"* && "$out" == *"--allow-context"* && "$out" == *"cc-auto-update"* ]] \
    && pass "#1211 context guard: the refusal names the window, the evaluator window and the override" \
    || fail "#1211 context guard: refusal message incomplete: [$out]"
# the deliberate override writes
out=$(env NEXUS_ROOT="$ROOT" NEXUS_WORKER_WINDOW=some-worker \
    bash "$MONITOR_DIR/cc-auto-update-apply.sh" record-outcome --allow-context \
    --candidate 2.1.160 --decision block --detail "deliberate" 2>&1); rc=$?
(( rc == 0 )) && [[ "$(_cc_update_field "$auto/last-eval" decision 2>/dev/null)" == "block" ]] \
    && pass "#1211 context guard: --allow-context from a worker window writes (rc 0)" \
    || fail "#1211 context guard: --allow-context refused or did not write: rc=$rc out=[$out]"
# unset — the routine's own environment, no agent window — writes
rm -f "$auto/last-eval" "$auto/decisions.tsv"
out=$(env -u NEXUS_WORKER_WINDOW NEXUS_ROOT="$ROOT" \
    bash "$MONITOR_DIR/cc-auto-update-apply.sh" record-outcome \
    --candidate 2.1.160 --decision block --detail "unset ctx" 2>&1); rc=$?
(( rc == 0 )) && [[ "$(_cc_update_field "$auto/last-eval" decision 2>/dev/null)" == "block" ]] \
    && pass "#1211 context guard: NEXUS_WORKER_WINDOW unset writes (rc 0)" \
    || fail "#1211 context guard: unset context refused: rc=$rc out=[$out]"
# POTENCY: the guard keys on the CONFIGURED evaluator name (CC_AUTO_WINDOW,
# _cc_auto_update.sh's default cc-auto-update), not on a second literal —
# a renamed evaluator passes and the old literal is then refused.
rm -f "$auto/last-eval" "$auto/decisions.tsv"
out=$(env NEXUS_ROOT="$ROOT" CC_AUTO_WINDOW=my-eval NEXUS_WORKER_WINDOW=my-eval \
    bash "$MONITOR_DIR/cc-auto-update-apply.sh" record-outcome \
    --candidate 2.1.160 --decision block --detail "renamed evaluator" 2>&1); rc=$?
rc_renamed=$rc
out2=$(env NEXUS_ROOT="$ROOT" CC_AUTO_WINDOW=my-eval NEXUS_WORKER_WINDOW=cc-auto-update \
    bash "$MONITOR_DIR/cc-auto-update-apply.sh" record-outcome \
    --candidate 2.1.160 --decision block --detail "stale literal" 2>&1); rc2=$?
(( rc_renamed == 0 && rc2 == 40 )) \
    && pass "#1211 POTENCY: the guard follows CC_AUTO_WINDOW (renamed evaluator rc 0, old literal rc 40)" \
    || fail "#1211 POTENCY: guard not keyed on CC_AUTO_WINDOW: renamed rc=$rc_renamed literal rc=$rc2 out=[$out] out2=[$out2]"
# the write-did-not-land path: an unwritable state dir → rc 41, and the line
# says so instead of a manufactured success.
ROOT="$WORK/r11d"; make_root "$ROOT" "2.1.150"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"; chmod 500 "$auto"
out=$(env NEXUS_ROOT="$ROOT" NEXUS_WORKER_WINDOW=cc-auto-update \
    bash "$MONITOR_DIR/cc-auto-update-apply.sh" record-outcome \
    --candidate 2.1.160 --decision block --detail "cannot land" 2>&1); rc=$?
chmod 700 "$auto"
(( rc == 41 )) && [[ "$out" == *"NOT"* && ! -e "$auto/last-eval" ]] \
    && pass "#1211 record-outcome reports a write that did NOT land (rc 41), never a manufactured success" \
    || fail "#1211 unwritable state dir: rc=$rc out=[$out]"

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
# stamp_gate_log <root> [<log>] — (re)write the `=== gated-tree:` line in a
# fixture gate log so it names <root>'s CURRENT HEAD (your-org/nexus-code#1259).
#
# Idempotent: any existing stamp is dropped first, so a caller that repoints
# HEAD can simply re-stamp. `dirty=0` is asserted rather than measured — the
# fixture root is full of untracked stub scripts by design, and what the
# production check reads is the STAMP, not the root's live status.
stamp_gate_log() {
    local root="$1" log="${2:-$1/gate.log}" head
    head=$(git -C "$root" rev-parse HEAD 2>/dev/null)
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] \
        || fail "stamp_gate_log: no HEAD in $root — every gate-evidence case would refuse for the wrong reason"
    { grep -vE '^=== gated-(tree|tui): ' "$log" 2>/dev/null || true; } > "$log.tmp"
    printf '=== gated-tree: head=%s ref=fixture dirty=0 dirty_tracked=0 untracked=0 subject_path=monitor/pane-state.sh subject_blob=%s ===\n' \
        "$head" "0000000000000000000000000000000000000000" >> "$log.tmp"
    # The GEOMETRY stamp (your-org/nexus-code#1448) is required on the bump path
    # since this suite's own case for it; `binary-default/unresolved` is a valid,
    # honest stamp, so fixtures carry that rather than claiming fullscreen.
    [[ "${STAMP_NO_TUI:-0}" == 1 ]] || printf '=== gated-tui: mode=binary-default source=unresolved reason=fixture ===\n' >> "$log.tmp"
    mv -f "$log.tmp" "$log"
}

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
    # claude stub: FOLLOWS THE PIN (floor before the bump, candidate after
    # the pin is written), so the tree reads consistent before the bump and
    # the post-install verify sees the candidate after it. It used to echo
    # the CANDIDATE unconditionally — which is the #1002 drifted shape
    # (binary ahead of the pin), refused before any verdict since then.
    make_pin_following_claude "$root" "$floor"
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
      # The window-selection capture (your-org/nexus-code#1528) asks for the
      # whole board with `list-windows -a -F 'session_id|window_id|name|active'`;
      # one parseable row makes the capture WRITE its file, which H7 below
      # needs to watch being dropped. Ahead of the names-only arm, which would
      # otherwise match this format's `#{window_name}` and answer a bare name
      # (an unparseable row: the capture then writes nothing).
      *'#{session_id}|#{window_id}|#{window_name}|#{window_active}'*) printf '%s\n' '\$0|@1|orchestrator|1' ;;
      # The deployment gate enumerates the board with the plain name
      # format and REFUSES an empty answer (your-org/nexus-code#1113):
      # a tmux reporting no windows at all has malfunctioned, and this
      # script runs inside one. So the fixture must name a real board.
      *'#{window_name}'*) printf '%s\n' orchestrator ;;
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
    # The fixture root is a REAL git repository (your-org/nexus-code#1259).
    # `_check_gate_evidence` now cross-checks the tree the gate log names
    # against the HEAD of the clone whose pin would move, so a fixture with
    # no HEAD would refuse for a reason no case is about. An empty commit is
    # enough: nothing here reads the tree's CONTENT, only its identity.
    # `-c user.*` on the command, never a written ~/.gitconfig (#1244).
    git -C "$root" init -q 2>/dev/null
    git -C "$root" -c user.name=fixture -c user.email=fixture@invalid \
        commit -q --allow-empty -m "fixture base" 2>/dev/null
    {
        printf 'gating %s\n' "$candidate"
        printf -- '--- test-realmodel-idle-busy.sh ---\n'
        printf -- '--- test-realmodel-blocked-question.sh ---\n'
        printf -- '--- test-realmodel-autosuggest.sh ---\n'
        printf -- '--- test-realmodel-overlimit.sh ---\n'
        printf -- '--- test-realmodel-pretooluse-hook.sh ---\n'
        printf '=== GATE GREEN — candidate is safe to promote ===\n'
    } > "$root/gate.log"
    # The tree stamp a post-#1259 gate.sh writes, matching this root's
    # CURRENT head. Written through the helper rather than inline because
    # `make_gate_clone` REPOINTS HEAD afterwards, and a stamp naming the
    # pre-repoint head would refuse every such case with `tree-mismatch` —
    # a refusal about the fixture rather than about anything under test.
    stamp_gate_log "$root"

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

    # REGISTRY (your-org/nexus-code#1007). The delta's RELEASE SET is what
    # the npm registry PUBLISHES in (installed, candidate], never the
    # changelog's own `## <ver>` headers — a published release with no
    # section used to vanish from the set, and `dispositioned N of M` read
    # GREEN over it. Abbreviated-packument shape (`versions` keyed by
    # version string), listing the floor, the intermediate release and the
    # candidate, so the derived set is {2.1.155, <candidate>} exactly as
    # the header-derived one was. Cases that need an extra published
    # version edit this file; REGISTRY_RC fails the fetch.
    printf '{"name":"@anthropic-ai/claude-code","versions":{"%s":{},"2.1.155":{},"%s":{}}}\n' \
        "$floor" "$candidate" > "$root/registry.json"
    cat > "$root/fetch-registry" <<EOF
#!/usr/bin/env bash
[[ -n "\${REGISTRY_RC:-}" ]] && exit "\$REGISTRY_RC"
cat "$root/registry.json"
EOF
    chmod +x "$root/fetch-registry"
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
        CC_AUTO_GATE_PR_ACTIVITY_CMD=true \
        CC_AUTO_CHANGELOG_FETCH_CMD="$root/fetch-changelog" \
        CC_AUTO_REGISTRY_FETCH_CMD="$root/fetch-registry" \
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

# ---- (f2/f3/f4) #867: 2c-vi can now PAY for its own label ----------------
#
# `test-realmodel-vimode.sh` exists, is driven, is control-tested (three arms,
# two negative controls) and is already in gate.sh's hardcoded scenario list —
# but `_surface_gate_scenarios` returned empty for `2c-vi`, so
# `--surface-evidence 2c-vi=gate` was refused. Fail-CLOSED, so it blocked no
# bump; the cost was that on any host whose config selects VI mode
# `reachability` is not payable either (the surface IS reached), leaving
# `source-inspection` as the only label — a real driven probe passing every
# round while its surface recorded as argued-not-driven.
#
# (f2) with the vimode scenario in the gate log → ACCEPTED.
ROOT="$WORK/a13f2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
sed 's|--- test-realmodel-idle-busy.sh ---|--- test-realmodel-idle-busy.sh ---\n--- test-realmodel-vimode.sh ---|' \
    "$ROOT/gate.log" > "$ROOT/gate-vi.log"
grep -q 'test-realmodel-vimode' "$ROOT/gate-vi.log" \
    || fail "#867 fixture: the vimode scenario line was not planted (the case below proves nothing)"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate-vi.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=reachability --surface-evidence 2c-vi=gate \
    --surface-evidence 2d=gate --surface-evidence 2e=source-inspection \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#867: 2c-vi=gate is payable when test-realmodel-vimode ran" \
    || fail "#867: 2c-vi=gate refused despite the scenario (rc=$rc): $(grep -m1 'REFUSED' "$ROOT/out.log")"

# (f3) CONTROL: without the vimode scenario in the log, the SAME claim is
#      refused. Otherwise (f2) passes for a build that stopped cross-checking
#      gate claims at all, which is the property the whole surface map exists
#      to provide.
ROOT="$WORK/a13f3"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=reachability --surface-evidence 2c-vi=gate \
    --surface-evidence 2d=gate --surface-evidence 2e=source-inspection \
    $(cl_ok) >/dev/null 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "#867 CONTROL: 2c-vi=gate without the scenario in the log is refused" \
    || fail "#867: 2c-vi=gate accepted with no scenario evidence"

# (f4) THE OTHER HALF STAYS UNPAYABLE. 2c-paste has no scenario and must not
#      acquire one by association — the halves keep separate labels, which is
#      the entire point of splitting 2c. Adding 2c-paste to the map would be
#      the 2.1.222 mistake in the other direction.
ROOT="$WORK/a13f4"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
# THIS CASE WAS INERT (your-org/nexus-code#1131 residual 2). It passed
# `--gate-evidence "$ROOT/gate-vi.log"` while `gate-vi.log` was only ever
# created in the a13f2 root — `make_apply_root` writes `gate.log` and nothing
# else — so `_check_gate_evidence` refused with "gate evidence file missing"
# and the bare `(( $? == 3 ))` was satisfied by the MISSING FIXTURE, never by
# the 2c-paste policy it names. Proven by mutation at the time: giving
# 2c-paste a full gate scenario left the suite at 139 passed / 0 failed and
# still printed this PASS.
#
# Two fixes, and the second is the one that generalises. (1) plant the file.
# (2) stop asserting on the exit CODE ALONE: rc 3 is what EVERY refusal in
# this function returns, so it cannot distinguish the policy under test from
# any other refusal — an assertion on a shared code is an assertion on
# nothing in particular. Assert the REASON.
sed 's|--- test-realmodel-idle-busy.sh ---|--- test-realmodel-idle-busy.sh ---\n--- test-realmodel-vimode.sh ---|' \
    "$ROOT/gate.log" > "$ROOT/gate-vi.log"
[[ -s "$ROOT/gate-vi.log" ]] && grep -q 'test-realmodel-vimode' "$ROOT/gate-vi.log" \
    || fail "#1131 fixture: gate-vi.log absent/unplanted in a13f4 — the case below would pass on the missing file again"
out=$(env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate-vi.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=gate --surface-evidence 2c-vi=gate \
    --surface-evidence 2d=gate --surface-evidence 2e=source-inspection \
    $(cl_ok) 2>&1)
rc=$?
if (( rc == 3 )) && grep -q "surface 2c-paste cannot be cleared by 'gate'" <<<"$out"; then
    pass "#867/#1131: 2c-paste=gate is refused BY THE POLICY, and the reason says so"
else
    fail "#1131 (f4) still not exercising the 2c-paste policy: rc=$rc reason=$(grep -m1 REFUSED <<<"$out")"
fi
# NEGATIVE CONTROL on the repair: the file the case now depends on must be
# the thing that changed. With it removed, the refusal reverts to the
# missing-file one — i.e. the old, inert reason — and the assertion above
# would no longer hold.
mv "$ROOT/gate-vi.log" "$ROOT/gate-vi.log.hidden"
out=$(env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate-vi.log" --surfaces-clear \
    --surface-evidence 2a=gate --surface-evidence 2b=gate \
    --surface-evidence 2c-paste=gate --surface-evidence 2c-vi=gate \
    --surface-evidence 2d=gate --surface-evidence 2e=source-inspection \
    $(cl_ok) 2>&1)
rc=$?
if (( rc == 3 )) && grep -q 'gate evidence file missing' <<<"$out" \
   && ! grep -q "surface 2c-paste cannot be cleared by 'gate'" <<<"$out"; then
    pass "#1131 CONTROL: without the fixture the refusal is the INERT one — the two are distinguishable"
else
    fail "#1131 control: removing gate-vi.log did not revert the reason (rc=$rc) — the assertion above may still be inert"
fi
mv "$ROOT/gate-vi.log.hidden" "$ROOT/gate-vi.log"

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

# ---- (e2/e3/e4) #867: the verbatim probe vs MARKDOWN ESCAPES -------------
#
# The GUIDE says to quote each entry "verbatim". In markdown that means a
# backtick span, and an upstream entry that itself contains a backtick — which
# they routinely do, naming flags and settings keys in code spans — then needs
# `` \` ``. The escape broke byte-equality under `grep -qF`, and the refusal
# came out as a COMPLETENESS failure ("N of M entries do not appear verbatim"),
# i.e. "you did not disposition these", for a ledger where every entry HAD
# been dispositioned. Wrong problem, stated confidently, at apply time.
#
# A helper that rebuilds the fixture's changelog with a backtick-bearing entry
# on BOTH the supplied and upstream sides (they are cross-checked for
# byte-equality, so editing one alone refuses for an unrelated reason).
make_backtick_root() {   # <root>
    local root="$1"
    make_apply_root "$root" "2.1.150" "2.1.160"
    {
        printf '# Changelog\n\n'
        printf '## 2.1.160\n\n'
        printf -- '- Fixed the `--teleport` flag ignoring `settings.json` overrides\n'
        printf -- '- Added a new plain entry with no code spans at all\n\n'
        printf '## 2.1.155\n\n'
        printf -- '- Changed the `permissions.allow` dialog chevron styling\n\n'
        printf '## 2.1.150\n\n'
        printf -- '- Fixed something that predates this delta entirely\n'
    } > "$root/changelog.md"
    cp "$root/changelog.md" "$root/upstream-changelog.md"
}

# ---- #1131 residuals 1 + 3: the normalisation's BREADTH and its
#      MULTIPLICITY are now bounded ------------------------------------
#
# The six escape-half assertions above pin that A completeness check
# survives normalisation. They do NOT bound how much the normaliser eats,
# and they do not stop one ledger line answering for two entries. Both gaps
# were demonstrated by surviving mutants:
#
#   `_cl_unescape_md() { sed 's/[[:punct:]]//g'; }`   — strips ALL
#      punctuation, strictly weaker, and survived at 139 passed / 0 failed.
#   escape-only twins with one ledger line             — ACCEPTED at rc 0
#      with one entry appearing NOWHERE in the ledger in any form.
#
# A control is an input that MUST survive normalisation unchanged, asserted
# to survive. These two are that, expressed as behaviour through the real
# `safe` path rather than as a unit test of a nested function.

# make_punct_root <root> — one release whose entry carries UNESCAPED
# punctuation. The point is what the normaliser must LEAVE ALONE.
make_punct_root() {   # <root>
    local root="$1"
    make_apply_root "$root" "2.1.150" "2.1.160"
    {
        printf '# Changelog\n\n'
        printf '## 2.1.160\n\n'
        printf -- '- Added a --verbose flag to the pane inspector\n\n'
        printf '## 2.1.155\n\n'
        printf -- '- Changed the chevron styling\n\n'
        printf '## 2.1.150\n\n'
        printf -- '- Fixed something that predates this delta entirely\n'
    } > "$root/changelog.md"
    cp "$root/changelog.md" "$root/upstream-changelog.md"
}

# (b1) BREADTH CONTROL. The ledger entry differs from the changelog entry
#      ONLY in unescaped punctuation (`--verbose` vs `verbose`). Those are
#      DIFFERENT entries and the check must say so. Under an over-broad
#      normaliser both sides collapse to the same string and this is
#      ACCEPTED — which is exactly the mutant that survived.
ROOT="$WORK/a13pb"; make_punct_root "$ROOT"
{
    printf -- '- Added a verbose flag to the pane inspector | no nexus surface\n'
    printf -- '- Changed the chevron styling | 2b, gate\n'
} > "$ROOT/ledger-punct.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-punct.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=1 \
    > "$ROOT/out.log" 2>&1
rc=$?
if (( rc == 3 )) && grep -q 'do not appear verbatim' "$ROOT/out.log"; then
    pass "#1131(3) BREADTH: unescaped punctuation SURVIVES normalisation — a punctuation-only difference is still refused"
else
    fail "#1131(3) breadth unbounded: a punctuation-only difference was accepted (rc=$rc) — the normaliser is eating more than backslashes"
fi

# (b2) POSITIVE CONTROL for (b1): the SAME fixture with the entry copied
#      verbatim is ACCEPTED. Without this, (b1) is satisfied by any refusal
#      — including one caused by the fixture — and would be the same inert
#      shape as residual 2.
{
    printf -- '- Added a --verbose flag to the pane inspector | no nexus surface\n'
    printf -- '- Changed the chevron styling | 2b, gate\n'
} > "$ROOT/ledger-punct-ok.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-punct-ok.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=1 \
    > "$ROOT/out2.log" 2>&1
if (( $? == 0 )); then
    pass "#1131(3) CONTROL: the verbatim entry is still ACCEPTED (the check did not simply become stricter)"
else
    fail "#1131(3) control: the verbatim ledger was refused — (b1) proves nothing: $(grep -m1 REFUSED "$ROOT/out2.log")"
fi

# make_twin_root <root> — two entries in ONE release differing ONLY by
# markdown backslash escapes. They collapse to one probe by construction:
# that identification is #867's whole purpose and must not be undone.
make_twin_root() {   # <root>
    local root="$1"
    make_apply_root "$root" "2.1.150" "2.1.160"
    {
        printf '# Changelog\n\n'
        printf '## 2.1.160\n\n'
        printf -- '- Fixed the \\-\\-verbose flag when the pane is narrow\n'
        printf -- '- Fixed the --verbose flag when the pane is narrow\n\n'
        printf '## 2.1.155\n\n'
        printf -- '- Changed the chevron styling\n\n'
        printf '## 2.1.150\n\n'
        printf -- '- Fixed something that predates this delta entirely\n'
    } > "$root/changelog.md"
    cp "$root/changelog.md" "$root/upstream-changelog.md"
}

# (b3) MULTIPLICITY. Two entries collapse to one probe and the ledger holds
#      ONE line. Before the fix the existence test was satisfied for BOTH by
#      that single line, so an entry appearing nowhere in the ledger in any
#      form was accepted at rc 0 — a false ACCEPT on the only path that
#      writes the pin. K colliding entries now need K ledger lines.
ROOT="$WORK/a13tw"; make_twin_root "$ROOT"
# POTENCY: the twins really must collide, or (b3) is about something else.
if [[ $(sed 's/\\\([[:punct:]]\)/\1/g' <<'TWINEOF' | sort -u | wc -l
Fixed the \-\-verbose flag when the pane is narrow
Fixed the --verbose flag when the pane is narrow
TWINEOF
) == 1 ]]; then
    pass "#1131(1) POTENCY: the two entries really do collapse to one probe"
else
    fail "#1131(1) potency: the planted twins do not collide — (b3) below tests nothing"
fi
{
    printf -- '- Fixed the --verbose flag when the pane is narrow | no nexus surface\n'
    printf -- '- Changed the chevron styling | 2b, gate\n'
} > "$ROOT/ledger-onetwin.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-onetwin.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2 \
    > "$ROOT/out3.log" 2>&1
if (( $? == 3 )); then
    pass "#1131(1) MULTIPLICITY: one ledger line cannot answer for two colliding entries"
else
    fail "#1131(1) FALSE ACCEPT: an entry absent from the ledger in every form was accepted via its escape-only twin"
fi

# (b4) POSITIVE CONTROL for (b3): with a line for EACH twin it is ACCEPTED.
#      This is what stops the multiplicity check from being "refuse more" —
#      the #867 identification is preserved exactly, and the escaped and
#      unescaped forms still match each other.
{
    printf -- '- Fixed the --verbose flag when the pane is narrow | no nexus surface\n'
    printf -- '- Fixed the \\-\\-verbose flag when the pane is narrow | no nexus surface\n'
    printf -- '- Changed the chevron styling | 2b, gate\n'
} > "$ROOT/ledger-twotwins.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-twotwins.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2 \
    > "$ROOT/out4.log" 2>&1
if (( $? == 0 )); then
    pass "#1131(1) CONTROL: a ledger line per twin is ACCEPTED — #867's identification is intact"
else
    fail "#1131(1) control: dispositioning both twins was refused — the fix over-corrected: $(grep -m1 REFUSED "$ROOT/out4.log")"
fi

# (e2) THE CASE FROM THE ISSUE: a ledger written the way a markdown author
#      writes one — every entry inside a backtick span, inner backticks
#      escaped — must be ACCEPTED. All three entries are dispositioned; the
#      only difference from a passing ledger is the quoting.
ROOT="$WORK/a13c5b"; make_backtick_root "$ROOT"
{
    printf -- '- `- Fixed the \\`--teleport\\` flag ignoring \\`settings.json\\` overrides` | 2e, source-inspection\n'
    printf -- '- `- Added a new plain entry with no code spans at all` | no nexus surface\n'
    printf -- '- `- Changed the \\`permissions.allow\\` dialog chevron styling` | 2b, gate\n'
} > "$ROOT/ledger-escaped.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-escaped.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2 \
    > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 0 )) \
    && pass "#867: a markdown-escaped verbatim ledger is ACCEPTED" \
    || fail "#867: escaped-backtick ledger still refused (rc=$rc): $(grep -m1 'REFUSED' "$ROOT/out.log")"

# (e3) CONTROL for (e2), and the one that matters: the escape strip must not
#      have turned the check off. Same fixture, same escaped style, but one
#      entry genuinely dropped → still REFUSED, and named ABSENT rather than
#      divergent.
ROOT="$WORK/a13c5c"; make_backtick_root "$ROOT"
{
    printf -- '- `- Fixed the \\`--teleport\\` flag ignoring \\`settings.json\\` overrides` | 2e, source-inspection\n'
    printf -- '- `- Changed the \\`permissions.allow\\` dialog chevron styling` | 2b, gate\n'
} > "$ROOT/ledger-escaped-short.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-escaped-short.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2 \
    > "$ROOT/out.log" 2>&1
(( $? == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "#867 CONTROL: a genuinely missing entry is still refused" \
    || fail "#867: the escape strip disabled the completeness check"
grep -q 'ABSENT:' "$ROOT/out.log" \
    && pass "#867 …and it is diagnosed ABSENT" \
    || fail "#867: missing entry not diagnosed as ABSENT: $(grep -m1 'REFUSED' "$ROOT/out.log")"

# (e4) THE DIAGNOSTIC SPLIT. An entry that IS in the ledger but diverges past
#      the probe prefix must be named as such, not as "does not appear". The
#      two have different fixes — one entry went unconsidered, the other was
#      considered and then re-worded — and the undifferentiated message sent
#      evaluators hunting for entries they had already dispositioned.
ROOT="$WORK/a13c5d"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
sed 's/Fixed the token counter wording on the spinner row/Fixed the token counter wording, and some other stuff/' \
    "$ROOT/ledger.md" > "$ROOT/ledger-diverge.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-diverge.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2 \
    > "$ROOT/out.log" 2>&1
(( $? == 3 )) && pass "#867: a divergent entry is still refused" \
    || fail "#867: divergent entry accepted"
grep -q 'DIVERGES after' "$ROOT/out.log" \
    && pass "#867 …and is diagnosed DIVERGES, not 'does not appear'" \
    || fail "#867: divergent entry mis-diagnosed: $(grep -m1 'REFUSED' "$ROOT/out.log")"
grep -q 'PRESENT BUT NOT BYTE-IDENTICAL' "$ROOT/out.log" \
    && pass "#867 …and the refusal splits the two counts" \
    || fail "#867: refusal does not separate absent from divergent"

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

# ===== your-org/nexus-code#1007: the RELEASE SET comes from the REGISTRY ======
#
# `_check_changelog_completeness` derived the delta's release set from the
# fetched changelog's own `## <ver>` headers. A release that PUBLISHES NO
# SECTION was therefore never IN the set: not counted toward M, never owed
# a disposition, invisible to `dispositioned N of M` — which read GREEN. It
# fired on 2026-08-25: 2.1.242 is a published release inside that delta with
# no `## 2.1.242` section, and two independent fires read "406 of 406" over
# it. The check could not report the case it exists to detect.
#
# The set is now the registry's published versions in (installed, candidate],
# and a published release with no section REFUSES with its OWN exit code (8):
# an opaque release is an absence of EVIDENCE, not an absence of entries. The
# registry fetch gets the changelog fetch's treatment — refuse, never fall
# back to the headers, because the fallback is the blind spot itself.
#
# The fixture registry lists {floor, 2.1.155, candidate}; the header-derived
# and registry-derived sets agree on it, so every case above is unchanged.
reg_json() {   # reg_json <ver>... — an abbreviated packument listing exactly these
    local v sep=""
    printf '{"name":"@anthropic-ai/claude-code","versions":{'
    for v in "$@"; do printf '%s"%s":{}' "$sep" "$v"; sep=","; done
    printf '}}\n'
}
CL_DEC() { printf '%s/monitor/.state/cc-auto-update/decisions.tsv' "$1"; }

# (r1) PUBLISHED BUT SECTIONLESS → refused, rc 8, the release NAMED. The
#      2.1.242 shape: the registry publishes 2.1.158 inside the delta, the
#      changelog (both copies) has no `## 2.1.158`, and the dispositions
#      account for every section that IS there — the input the old
#      derivation accepted at rc 0 with "3 of 3 across 2 releases".
ROOT="$WORK/a1007r1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
reg_json 2.1.150 2.1.155 2.1.158 2.1.160 > "$ROOT/registry.json"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
if (( rc == 8 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
   && grep -qi 'opaque' "$ROOT/out.log" && grep -qF '2.1.158' "$ROOT/out.log"; then
    pass "#1007 (r1) refused rc 8: 2.1.158 is published inside the delta and has no section — named as opaque"
else
    fail "#1007 (r1) a published, sectionless release was not refused as opaque (rc=$rc, want 8): $(tail -1 "$ROOT/out.log")"
fi
grep -q $'\tsafe-refused\tchangelog-completeness:opaque-release=2.1.158' "$(CL_DEC "$ROOT")" 2>/dev/null \
    && pass "#1007 (r1) …recorded as safe-refused with the opaque release in the detail (the #1400 repeat-nag can key on it)" \
    || fail "#1007 (r1) outcome row missing/wrong: $(grep -F 'safe-refused' "$(CL_DEC "$ROOT")" 2>/dev/null | tail -1)"
! grep -q 'changelog completeness accepted' "$ROOT/out.log" \
    && pass "#1007 (r1) …and no acceptance line was printed" \
    || fail "#1007 (r1) the acceptance line printed on a refusal"

# (r1b) CONTROL for (r1), and spec item 3: the SAME registry with a section
#       for 2.1.158 in both copies and a disposition for it → ACCEPTED, and
#       the audit row's K is the REGISTRY-derived count (3 releases).
ROOT="$WORK/a1007r1b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
reg_json 2.1.150 2.1.155 2.1.158 2.1.160 > "$ROOT/registry.json"
for f in "$ROOT/changelog.md" "$ROOT/upstream-changelog.md"; do
    printf '\n## 2.1.158\n\n- Fixed a spinner glyph that rendered as tofu on some terminals\n' >> "$f"
done
printf -- '- Fixed a spinner glyph that rendered as tofu on some terminals | 2a, gate: glyph set unchanged\n' >> "$ROOT/ledger.md"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.158=1 \
    --changelog-dispositioned 2.1.160=2 > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1007 (r1b) CONTROL: the same published release WITH a section and a disposition is accepted" \
    || fail "#1007 (r1b) CONTROL wrongly refused (rc=$rc): $(tail -1 "$ROOT/out.log")"
grep -q $'\tchangelog-completeness\t.*dispositioned 4 of 4 entries across 3 release' "$(CL_DEC "$ROOT")" 2>/dev/null \
    && pass "#1007 (r1b) K equals the registry-derived release count (4 of 4 across 3 releases)" \
    || fail "#1007 (r1b) audit row K wrong: $(grep -F 'changelog-completeness' "$(CL_DEC "$ROOT")" 2>/dev/null | tail -1)"

# (r2) REGISTRY FETCH FAILS → refused (rc 3, the changelog-fetch-failure
#      treatment) and NOT fallen back to the header-derived set. The
#      discriminator: this changelog + these dispositions PASS under the
#      header derivation (case (i) above proves it), so an rc 0 here can
#      only come from the fallback.
ROOT="$WORK/a1007r2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") REGISTRY_RC=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
if (( rc == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
   && grep -q 'could not fetch' "$ROOT/out.log" && grep -qi 'registry' "$ROOT/out.log"; then
    pass "#1007 (r2) refused rc 3: registry fetch failed — a changelog that passes by its headers was NOT accepted (no fallback)"
else
    fail "#1007 (r2) registry fetch failure fell back to the header-derived set (rc=$rc, want 3): $(tail -1 "$ROOT/out.log")"
fi
! grep -q $'\tchangelog-completeness\tdispositioned' "$(CL_DEC "$ROOT")" 2>/dev/null \
    && grep -q $'\tsafe-refused\tchangelog-completeness:registry-fetch' "$(CL_DEC "$ROOT")" 2>/dev/null \
    && pass "#1007 (r2) …no acceptance row; the refusal row names the registry fetch" \
    || fail "#1007 (r2) audit rows wrong: $(cut -f3,4 "$(CL_DEC "$ROOT")" 2>/dev/null | tail -2 | tr '\n' ' ')"

# (r2b) the registry answers with PROSE (an unauthenticated CLI banner, a
#       captive portal) → not a packument → refused, same rule. rc 0 with an
#       empty version set would be the silent zero this file exists to stop.
ROOT="$WORK/a1007r2b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf 'Welcome to GitHub CLI! To authenticate, run: gh auth login\n' > "$ROOT/registry.json"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q $'\tsafe-refused\tchangelog-completeness:registry-unparseable' "$(CL_DEC "$ROOT")" 2>/dev/null \
    && pass "#1007 (r2b) refused rc 3: a non-JSON registry body is not a release set" \
    || fail "#1007 (r2b) non-JSON registry body accepted or misfiled (rc=$rc): $(tail -1 "$ROOT/out.log")"

# (r2c) valid JSON, EMPTY `versions` → refused. Zero published versions is
#       not a measurement of the delta; it is the registry saying nothing.
ROOT="$WORK/a1007r2c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
reg_json > "$ROOT/registry.json"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q $'\tsafe-refused\tchangelog-completeness:registry-unparseable' "$(CL_DEC "$ROOT")" 2>/dev/null \
    && pass "#1007 (r2c) refused rc 3: a packument listing no versions is refused, not read as an empty delta" \
    || fail "#1007 (r2c) empty version set accepted (rc=$rc): $(tail -1 "$ROOT/out.log")"

# (r2d) the registry does not list the CANDIDATE → refused. The candidate
#       came from the registry's `latest` in the first place, so its absence
#       means the copy this run read is stale or about something else — the
#       exact defect (a cache-served `npm view`) the issue thread measured.
ROOT="$WORK/a1007r2d"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
reg_json 2.1.150 2.1.155 > "$ROOT/registry.json"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -qF '2.1.160' "$ROOT/out.log" \
    && grep -q $'\tsafe-refused\tchangelog-completeness:registry-candidate-absent' "$(CL_DEC "$ROOT")" 2>/dev/null \
    && pass "#1007 (r2d) refused rc 3: a registry copy that does not list the candidate is stale, not authoritative" \
    || fail "#1007 (r2d) candidate absent from the registry was accepted (rc=$rc): $(tail -1 "$ROOT/out.log")"

# (r3) A HEADER FOR AN UNPUBLISHED VERSION DOES NOT INFLATE M — the stated
#      CHOICE (ignore; w233's recommendation). `## 2.1.157` with one entry
#      sits inside the delta in BOTH copies, the registry publishes no
#      2.1.157, and cl_ok carries no disposition for it: accepted, K stays 2,
#      M stays 3, and the drop is said out loud (a WARN naming the version).
#      The 2.1.244 case from the issue thread is the same shape one step
#      over: unpublished AND sectionless, correctly nothing.
ROOT="$WORK/a1007r3"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
for f in "$ROOT/changelog.md" "$ROOT/upstream-changelog.md"; do
    printf '\n## 2.1.157\n\n- Announced a release that never shipped\n' >> "$f"
done
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && grep -q $'\tchangelog-completeness\t.*dispositioned 3 of 3 entries across 2 release' "$(CL_DEC "$ROOT")" 2>/dev/null \
    && pass "#1007 (r3) CHOICE: a header for an unpublished version is dropped — accepted, still 3 of 3 across 2 releases" \
    || fail "#1007 (r3) unpublished header changed the verdict or the counts (rc=$rc): $(tail -1 "$ROOT/out.log")"
grep -q 'WARN.*2\.1\.157' "$ROOT/out.log" \
    && pass "#1007 (r3) …and the drop is announced (WARN names 2.1.157)" \
    || fail "#1007 (r3) the unpublished header was dropped silently"

# (r3b) CONTROL for (r3): the dropped header is OUT of the set, not merely
#       tolerated — dispositioning it is refused as outside the delta. A
#       FRESH root: (r3) wrote the pin, and a re-run against it would be the
#       idempotency no-op (rc 0) rather than a verdict on the release set.
ROOT="$WORK/a1007r3b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
for f in "$ROOT/changelog.md" "$ROOT/upstream-changelog.md"; do
    printf '\n## 2.1.157\n\n- Announced a release that never shipped\n' >> "$f"
done
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) --changelog-dispositioned 2.1.157=1 > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 3 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q 'outside the delta' "$ROOT/out.log" \
    && pass "#1007 (r3b) CONTROL: a disposition for the unpublished header is refused as outside the (registry-derived) delta" \
    || fail "#1007 (r3b) the unpublished header is still in the release set (rc=$rc): $(tail -1 "$ROOT/out.log")"

# (r4) ORDERING IS SEMVER, not lexical. 2.1.1000 is published and has no
#      section; lexically it sorts INSIDE (2.1.150, 2.1.160] and would be
#      refused as opaque; under semver it is above the candidate and out of
#      the delta. Must be accepted.
ROOT="$WORK/a1007r4"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
reg_json 2.1.150 2.1.155 2.1.160 2.1.1000 > "$ROOT/registry.json"
env $(apply_env "$ROOT") bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1007 (r4) delta membership is semver: published 2.1.1000 is above the candidate, not an opaque release inside it" \
    || fail "#1007 (r4) lexical ordering put 2.1.1000 inside the delta (rc=$rc): $(tail -1 "$ROOT/out.log")"

# ===== #1007 follow-up: exit 8 is BOUNDED — delay, then SURFACE ==============
#
# On its own the opaque-release refusal is terminal: a permanently sectionless
# release would pin the fleet forever, against the operator directive behind
# GATE_DEFER_STREAK_CAP ("a very busy board should only DELAY the update and
# not PREVENT it", 2026-09-10). So after CAP consecutive refusals on the same
# opaque set the operator is ESCALATED — notify + a comment on the cc-update
# tracking issue carrying the candidate, the version(s) and, verbatim,
# "upstream shipped no parseable sections; this needs a human disposition."
# — and the refusal CONTINUES: exit 8, outcome safe-refused, unchanged. Never
# auto-proceed, never delay-then-forget. The knob is REUSED, so its floor (2)
# and loud clamp apply, with one divergence: 0 disables the override bound
# but cannot disable the escalation — a refusal nobody is told about is the
# forbidden outcome — so 0 escalates at the floor.
OPAQUE_SENTENCE='upstream shipped no parseable sections; this needs a human disposition.'
make_opaque_root() {   # <root> — registry publishes 2.1.158, changelog has no section for it
    local root="$1"
    make_apply_root "$root" "2.1.150" "2.1.160"
    reg_json 2.1.150 2.1.155 2.1.158 2.1.160 > "$root/registry.json"
    # a plain registry for a NON-opaque fire in the middle of a streak
    reg_json 2.1.150 2.1.155 2.1.160 > "$root/registry-plain.json"
    printf '#!/usr/bin/env bash\ncat "%s/registry-plain.json"\n' "$root" > "$root/fetch-registry-plain"
    chmod +x "$root/fetch-registry-plain"
    # the tracking-issue COMMENT seam: records <repo> <issue>, then the body
    cat > "$root/comment-cmd" <<EOF
#!/usr/bin/env bash
[[ -n "\${COMMENT_RC:-}" ]] && exit "\$COMMENT_RC"
printf 'COMMENT %s %s\n' "\$1" "\$2" >> "$root/comments.log"
cat "\$3" >> "$root/comments.log"
echo "https://github.com/\$1/issues/\$2#issuecomment-99"
EOF
    chmod +x "$root/comment-cmd"
    # the CREATE/ADOPT seam (the defect filer's), for the no-tracking-issue path
    cat > "$root/issue-cmd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$root/filed.log"
echo "https://github.com/your-org/nexus-code/issues/4343"
EOF
    chmod +x "$root/issue-cmd"
}
# opaque_fire [ENV=val…] — one `safe` fire on $ROOT with the opaque registry,
# the tracking issue configured through the seam, both post seams stubbed.
# Extra env assignments go before the command. Output APPENDS to out.log.
opaque_fire() {
    env $(apply_env "$ROOT") CC_AUTO_TRACKING_ISSUE='your-org/nexus-code#1234' \
        CC_AUTO_ISSUE_COMMENT_CMD="$ROOT/comment-cmd" CC_AUTO_GATE_ISSUE_CMD="$ROOT/issue-cmd" "$@" \
        bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
        $(cl_ok) >> "$ROOT/out.log" 2>&1
}
# Both counters print 0 for a MISSING file: `grep -c` on a file that does not
# exist prints NOTHING (not 0) and exits 2, so a bare `|| true` would hand an
# EMPTY string to a `== 0` comparison and fail it — measured on (o6), where
# the failed post writes no comments.log. Assign, then validate the SHAPE
# (count-fallback-lint: never `|| echo 0` onto a grep -c that may have printed).
esc_rows() { local n; n=$(grep -c $'\tchangelog-opaque-escalation\t' "$(CL_DEC "$1")" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
comment_posts() { local n; n=$(grep -c '^COMMENT ' "$1/comments.log" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }

# (o1) N-1 consecutive opaque refusals (default cap 3 → two fires) → refused
#      both times, NOT escalated: no escalation row, no comment, no sentence.
ROOT="$WORK/a1007o1"; make_opaque_root "$ROOT"
opaque_fire; rc1=$?
opaque_fire; rc2=$?
if (( rc1 == 8 && rc2 == 8 )) && [[ "$(esc_rows "$ROOT")" == 0 ]] \
   && [[ ! -e "$ROOT/comments.log" && ! -e "$ROOT/filed.log" ]] \
   && ! grep -qF -- "$OPAQUE_SENTENCE" "$ROOT/out.log"; then
    pass "#1007 (o1) two consecutive opaque refusals under cap 3: both rc 8, NOT escalated (no row, no comment, no sentence)"
else
    fail "#1007 (o1) escalated early or wrong rc (rc1=$rc1 rc2=$rc2 rows=$(esc_rows "$ROOT") comments=$(comment_posts "$ROOT"))"
fi
grep -q 'opaque-release streak: 2 consecutive' "$ROOT/out.log" \
    && pass "#1007 (o1) …and the streak is counted in the log (2 consecutive)" \
    || fail "#1007 (o1) streak not counted: $(grep -F 'opaque-release streak' "$ROOT/out.log" | tail -1)"

# (o2) the Nth (third) → ESCALATED once: notify + tracking-issue comment
#      naming candidate + version + the verbatim sentence; exit still 8,
#      outcome row still safe-refused.
opaque_fire; rc3=$?
DEC="$(CL_DEC "$ROOT")"
if (( rc3 == 8 )) && [[ "$(esc_rows "$ROOT")" == 1 ]] && [[ "$(comment_posts "$ROOT")" == 1 ]] \
   && grep -q '^COMMENT your-org/nexus-code 1234$' "$ROOT/comments.log" \
   && grep -qF '2.1.160' "$ROOT/comments.log" && grep -qF '2.1.158' "$ROOT/comments.log" \
   && grep -qF -- "$OPAQUE_SENTENCE" "$ROOT/comments.log"; then
    pass "#1007 (o2) the 3rd consecutive refusal ESCALATES once: comment on your-org/nexus-code#1234 names 2.1.160, 2.1.158 and the verbatim sentence; rc still 8"
else
    fail "#1007 (o2) escalation wrong (rc=$rc3 rows=$(esc_rows "$ROOT") comments=$(comment_posts "$ROOT")): $(tail -2 "$ROOT/comments.log" 2>/dev/null | cut -c1-120)"
fi
[[ "$(tail -1 "$DEC" | cut -f3)" != "safe-bumped"* ]] \
    && [[ "$(awk -F'\t' '$3=="safe-refused"' "$DEC" | wc -l)" == 3 ]] \
    && grep -q '^decision=safe-refused$' "$ROOT/monitor/.state/cc-auto-update/last-eval" \
    && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "#1007 (o2) …outcome token unchanged (3 safe-refused rows, last-eval safe-refused), pin untouched — surfaced, never auto-proceeded" \
    || fail "#1007 (o2) the escalation changed the outcome: $(cut -f3,4 "$DEC" | tail -3 | tr '\n' ' ')"
grep -qF -- "$OPAQUE_SENTENCE" "$ROOT/out.log" && grep -q 'ESCALATION (opaque release' "$ROOT/out.log" \
    && pass "#1007 (o2) …and the notify text (with the sentence) is in the apply log" \
    || fail "#1007 (o2) the sentence is missing from the apply log"
grep -q $'\tchangelog-opaque-escalation\t.*streak=3 escalate_at=3 defer_cap=3 defer_cap_clamped=0' "$DEC" \
    && pass "#1007 (o2) …the escalation row carries streak, bound and the reused cap" \
    || fail "#1007 (o2) escalation row fields wrong: $(grep -F 'opaque-escalation' "$DEC" | tail -1)"

# (o2b) the 4th → still refused, notify/row again, but the issue post is NOT
#       repeated inside the cooldown (one comment per opaque set per week).
opaque_fire; rc4=$?
(( rc4 == 8 )) && [[ "$(esc_rows "$ROOT")" == 2 ]] && [[ "$(comment_posts "$ROOT")" == 1 ]] \
    && grep -q 'already posted' "$ROOT/out.log" \
    && grep -q 'count=2' "$ROOT/monitor/.state/cc-auto-update/opaque-escalations/2.1.158" \
    && pass "#1007 (o2b) the 4th refusal re-notifies (2 rows) but does NOT re-post the comment (cooldown; repeat counted 2)" \
    || fail "#1007 (o2b) repeat handling wrong (rc=$rc4 rows=$(esc_rows "$ROOT") comments=$(comment_posts "$ROOT"))"

# (o3) RESET: a non-opaque refusal in between breaks the streak. cap=2 (the
#      floor) so the difference is observable in two fires: opaque, then a
#      ledger-short refusal against the PLAIN registry (rc 3, detail
#      changelog-completeness), then opaque → streak 1, no escalation.
ROOT="$WORK/a1007o3"; make_opaque_root "$ROOT"
grep -v 'teleport' "$ROOT/ledger.md" > "$ROOT/ledger-short.md"
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=2
env $(apply_env "$ROOT") CC_AUTO_REGISTRY_FETCH_CMD="$ROOT/fetch-registry-plain" CC_AUTO_GATE_DEFER_STREAK_CAP=2 \
    CC_AUTO_TRACKING_ISSUE='your-org/nexus-code#1234' CC_AUTO_ISSUE_COMMENT_CMD="$ROOT/comment-cmd" \
    bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger-short.md" \
    --changelog-dispositioned 2.1.155=1 --changelog-dispositioned 2.1.160=2 >> "$ROOT/out.log" 2>&1
rcm=$?
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=2; rc3=$?
if (( rcm == 3 && rc3 == 8 )) && [[ "$(esc_rows "$ROOT")" == 0 ]] && [[ ! -e "$ROOT/comments.log" ]] \
   && grep -q 'opaque-release streak: 1 consecutive' "$ROOT/out.log"; then
    pass "#1007 (o3) a non-opaque refusal in between RESETS the streak (1, not 2) — no escalation at cap 2"
else
    fail "#1007 (o3) streak did not reset (rcm=$rcm rc3=$rc3 rows=$(esc_rows "$ROOT")): $(grep -F 'opaque-release streak' "$ROOT/out.log" | tail -1)"
fi
# (o3b) CONTROL: the same two opaque fires WITHOUT the interruption escalate.
ROOT="$WORK/a1007o3b"; make_opaque_root "$ROOT"
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=2
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=2
[[ "$(esc_rows "$ROOT")" == 1 ]] && [[ "$(comment_posts "$ROOT")" == 1 ]] \
    && pass "#1007 (o3b) CONTROL: two uninterrupted opaque refusals at cap 2 escalate (the reset in o3 is real)" \
    || fail "#1007 (o3b) CONTROL did not escalate (rows=$(esc_rows "$ROOT") comments=$(comment_posts "$ROOT"))"

# (o4) THE REUSED KNOB'S FLOOR AND CLAMP. cap=1 is clamped to the floor 2
#      (zero delay is not a bound): fire 1 no escalation, fire 2 escalates,
#      and the row says the cap was clamped. cap=0 disables the deployment
#      gate's OVERRIDE bound but cannot disable this surfacing: escalates
#      at the floor too.
ROOT="$WORK/a1007o4"; make_opaque_root "$ROOT"
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=1
r1=$(esc_rows "$ROOT")
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=1
[[ "$r1" == 0 ]] && [[ "$(esc_rows "$ROOT")" == 1 ]] \
    && grep -q $'\tchangelog-opaque-escalation\t.*escalate_at=2 defer_cap=2 defer_cap_clamped=1' "$(CL_DEC "$ROOT")" \
    && pass "#1007 (o4) cap=1 is CLAMPED to the floor 2: no escalation on the 1st, escalation on the 2nd, row says defer_cap_clamped=1" \
    || fail "#1007 (o4) clamp not honoured (r1=$r1 rows=$(esc_rows "$ROOT")): $(grep -F 'opaque-escalation' "$(CL_DEC "$ROOT")" | tail -1)"
ROOT="$WORK/a1007o4z"; make_opaque_root "$ROOT"
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=0
r1=$(esc_rows "$ROOT")
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=0
[[ "$r1" == 0 ]] && [[ "$(esc_rows "$ROOT")" == 1 ]] \
    && grep -q $'\tchangelog-opaque-escalation\t.*escalate_at=2 defer_cap=0' "$(CL_DEC "$ROOT")" \
    && pass "#1007 (o4) cap=0 cannot DISABLE the escalation: escalates at the floor (2) while the override bound stays off (defer_cap=0)" \
    || fail "#1007 (o4) cap=0 disabled the surfacing (r1=$r1 rows=$(esc_rows "$ROOT"))"

# (o5) NO tracking issue configured → the escalation files/adopts an issue on
#      the gate repo through the defect filer's seam, once, keyed on the set.
ROOT="$WORK/a1007o5"; make_opaque_root "$ROOT"
for _ in 1 2; do
    env $(apply_env "$ROOT") CC_AUTO_GATE_DEFER_STREAK_CAP=2 CC_AUTO_GATE_ISSUE_CMD="$ROOT/issue-cmd" \
        CC_AUTO_ISSUE_COMMENT_CMD="$ROOT/comment-cmd" \
        bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $CL_SURF \
        $(cl_ok) >> "$ROOT/out.log" 2>&1
done
filed=$(grep -c '^opaque-release-2.1.158$' "$ROOT/filed.log" 2>/dev/null) || filed=0
(( filed == 1 )) && [[ ! -e "$ROOT/comments.log" ]] && [[ "$(esc_rows "$ROOT")" == 1 ]] \
    && grep -q $'\tchangelog-opaque-escalation-posted\t.*where=your-org/nexus-code (new/adopted issue' "$(CL_DEC "$ROOT")" \
    && pass "#1007 (o5) no tracking issue → files/adopts ONE issue on the gate repo (key opaque-release-2.1.158), no comment attempted" \
    || fail "#1007 (o5) fallback filing wrong (filed=$filed comments=$(comment_posts "$ROOT") rows=$(esc_rows "$ROOT"))"

# (o6) THE POSTER'S OWN FAILURE IS VISIBLE AND RETRIED. The comment seam
#      fails → rc still 8, escalation row present, an UNPOSTED row names it,
#      no breadcrumb is written; the next fire (still past the bound) retries
#      and, on success, posts.
ROOT="$WORK/a1007o6"; make_opaque_root "$ROOT"
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=2
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=2 COMMENT_RC=1; rcf=$?
(( rcf == 8 )) && [[ "$(esc_rows "$ROOT")" == 1 ]] && [[ "$(comment_posts "$ROOT")" == 0 ]] \
    && grep -q $'\tchangelog-opaque-escalation-UNPOSTED\t' "$(CL_DEC "$ROOT")" \
    && [[ ! -e "$ROOT/monitor/.state/cc-auto-update/opaque-escalations/2.1.158" ]] \
    && pass "#1007 (o6) a failed post is recorded UNPOSTED, writes no breadcrumb, and does not change exit 8" \
    || fail "#1007 (o6) failed post mishandled (rc=$rcf rows=$(esc_rows "$ROOT") comments=$(comment_posts "$ROOT"))"
opaque_fire CC_AUTO_GATE_DEFER_STREAK_CAP=2
[[ "$(comment_posts "$ROOT")" == 1 ]] && [[ -f "$ROOT/monitor/.state/cc-auto-update/opaque-escalations/2.1.158" ]] \
    && pass "#1007 (o6) …and the next fire RETRIES the post and succeeds" \
    || fail "#1007 (o6) the failed post was not retried (comments=$(comment_posts "$ROOT"))"

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

# 19b. flock-fd hardening (class your-org/nexus-code#494; caught on PR #1425
#      by monitor/watcher/test-flock-fd-cloexec.sh, NOT by the author). The
#      single-flight lock this verb takes must NOT survive in the children it
#      spawns: flock(2) binds to the open file description and bash cannot
#      set FD_CLOEXEC, so an inherited fd 9 keeps the lock alive after the
#      verb exits — a stuck lock no living claimant owns, on the path that
#      restarts the orchestrator. Both stubs here background a child that
#      OUTLIVES the verb (pane-state.sh's own `sleep 30 &` shape); after the
#      verb exits the lock must be FREE. Mutation-sensitive: drop any one
#      `9>&-` in the locked region and the orphan holds it.
ROOT="$WORK/a19b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "spawn $*" >> "%s"\nsleep 20 >/dev/null 2>&1 &\nexit 0\n' \
    "$ROOT/calls.log" > "$ROOT/spawn"
chmod +x "$ROOT/spawn"
printf '#!/usr/bin/env bash\necho "state=idle active=1"\nsleep 20 >/dev/null 2>&1 &\nexit 0\n' \
    > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
RLOCK="$ROOT/monitor/.state/restart-orchestrator.lock"
if ! command -v flock >/dev/null 2>&1; then
    fail "flock(1) unavailable on this host — the flock-fd hardening is UNMEASURED here"
else
    # POSITIVE CONTROL for the detector, on a SEPARATE lock file — the exact
    # failure shape: an opener takes the lock, backgrounds a child, exits.
    # `flock -n` must then FAIL, or the assertion below could never go red.
    CTL_LOCK="$WORK/a19b-ctl.lock"; CTL_PID="$WORK/a19b-ctl.pid"
    bash -c 'exec 9>>"$1"; flock -n 9 || exit 9; sleep 20 >/dev/null 2>&1 & echo "$!" > "$2"' \
        _ "$CTL_LOCK" "$CTL_PID"
    if flock -n "$CTL_LOCK" true 2>/dev/null; then
        fail "positive control: an orphan holding an inherited flock fd was NOT detected — the assertion below proves nothing"
    else
        pass "positive control: an orphan's inherited flock fd holds the lock (detector can fire)"
    fi
    kill "$(cat "$CTL_PID" 2>/dev/null)" 2>/dev/null || true

    env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
        --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
    rc=$?
    # The verb must have TAKEN the lock (file exists, spawn + pane-state both
    # ran, never-armed rc 22 as in 19) — otherwise "free" is vacuous.
    if (( rc == 22 )) && [[ -f "$RLOCK" ]] \
       && grep -q '^spawn ' "$ROOT/calls.log"; then
        if flock -n "$RLOCK" true 2>/dev/null; then
            pass "flock-fd: lock is FREE after the verb exits despite orphaned children of spawn + pane-state (#494 close-at-spawn)"
        else
            fail "flock-fd: an orphaned child of the restart path still HOLDS $RLOCK after the verb exited — the single-flight lock leaked (#494)"
        fi
    else
        fail "flock-fd case did not reach the lock (rc=$rc lock_exists=$([[ -f "$RLOCK" ]] && echo yes || echo no)) — hardening unmeasured"
    fi
fi

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

# 20e. `auth=login` on an otherwise ELIGIBLE verdict (w239: #1518 x #1513).
#      A live /login frame reaches `state=idle` via the heartbeat route, and
#      idle is a turn boundary. Killing here destroys the operator's login in
#      progress and respawns a session that is still unauthenticated, so the
#      login WINS: the gate keeps waiting, and at the cap it ABORTS (rc 23,
#      no kill, reason `auth-login-at-cap`) instead of forcing — the reconcile
#      retries after its cooldown, and #1518's own escape clock (~1 h) bounds
#      how long a login can hold the pane.
ROOT="$WORK/a20e-auth"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "state=idle active=1 window=2 name=orchestrator overlay=login auth=login"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 23 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q "auth-login-at-cap" "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" \
   && grep -q $'\tsafe-bumped-restart-aborted\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "idle + auth=login for the whole wait → login wins: rc 23, no kill, auth-login-at-cap (not forced)"
else
    fail "auth=login interaction wrong (rc=$rc, want 23 + no kill + auth-login-at-cap)"
fi

# 20f. `auth=expired` on idle is STILL a boundary: the session is logged out
#      and idle, a resume-from-transcript restart loses nothing, and the
#      operator's board state waits in the transcript. Clean restart on the
#      first poll — the control for 20e, so the veto is shown to key on
#      `login` and not on the presence of an `auth=` field.
ROOT="$WORK/a20f-auth"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "state=idle active=1 window=2 name=orchestrator auth=expired"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && ! grep -q $'\tsafe-bumped-restart-forced\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "idle + auth=expired → still a boundary: clean (non-forced) restart, kill issued"
else
    fail "auth=expired control wrong (rc=$rc, want clean rc 0 + kill, not forced)"
fi

# 20g. auth=login with the AUTH HOLD DISABLED (w239sk F3): the abort's bound
#      is #1518's escape clock, which does not run when the hold is off, so
#      aborting there would be UNBOUNDED (every reconcile retry aborting
#      forever). With MONITOR_AUTH_HOLD_ENABLED=false the cap must FORCE as it
#      did before the veto — rc 0, kill issued, outcome forced.
ROOT="$WORK/a20g-auth-nohold"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "state=idle active=1 window=2 name=orchestrator overlay=login auth=login"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") MONITOR_AUTH_HOLD_ENABLED=false bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q $'\tsafe-bumped-restart-forced\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" \
   && ! grep -q "auth-login-at-cap" "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "idle + auth=login with the auth hold DISABLED → no clock bounds the login, so the cap FORCES (rc 0, kill) rather than aborting unbounded"
else
    fail "auth=login with hold disabled wrong (rc=$rc, want forced rc 0 + kill, no auth-login-at-cap)"
fi

# 20h. The knob's spellings must agree with the hold's own (w239sk delta
#      residual): MONITOR_AUTH_HOLD_ENABLED=1 is ON for _auth_hold_active, so
#      apply.sh must ABORT (not force) exactly as for `true`.
ROOT="$WORK/a20h-auth-hold-1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "state=idle active=1 window=2 name=orchestrator overlay=login auth=login"\n' > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
env $(apply_env "$ROOT") MONITOR_AUTH_HOLD_ENABLED=1 bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 23 )) && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q "auth-login-at-cap" "$ROOT/monitor/.state/cc-auto-update/decisions.tsv"; then
    pass "auth hold spelled '1' is ON for apply.sh too → abort (rc 23, no kill), agreeing with _auth_hold_active"
else
    fail "knob spelling disagreement: MONITOR_AUTH_HOLD_ENABLED=1 gave rc=$rc (want 23 abort, no kill)"
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

# E3-E6. The orchestrator's watcher-supervisor Monitor runs as a real zsh child
#     of claude on current Claude Code builds, so between turns it reads
#     shell-driven (bg_cpu= present) and E1's arm is unreachable for it. E3 is
#     that line, as measured on 2026-09-11 (2.1.268) with `bg_quiesce=1`
#     appended; E4-E6 each change ONE field of it and must still force.
restart_outcome() {   # restart_outcome <tag> <pane-line> → sets RO_RC, RO_CLEAN, RO_FORCED
    local root="$WORK/$1"
    make_apply_root "$root" "2.1.150" "2.1.160"
    printf '#!/usr/bin/env bash\necho "%s"\n' "$2" > "$root/pane-state"
    chmod +x "$root/pane-state"
    env $(apply_env "$root") bash "$APPLY" restart-orchestrator \
        --candidate 2.1.160 --sid "$(pin_of "$root")" >/dev/null 2>&1
    RO_RC=$?
    RO_CLEAN=0; RO_FORCED=0
    grep -q $'\tsafe-bumped-restarted\t' "$root/monitor/.state/cc-auto-update/decisions.tsv" && RO_CLEAN=1
    grep -q $'\tsafe-bumped-restart-forced\t' "$root/monitor/.state/cc-auto-update/decisions.tsv" && RO_FORCED=1
    grep -q "kill-window -t orchestrator" "$root/calls.log" || RO_RC="$RO_RC-nokill"
}
E3_LINE='state=working-background active=0 window=2 name=orchestrator input=ghost bg_shells=1 bg_reliable=1 bg_cpu=2 bg_oldest_start=1 bg_infra=0 bg_stale=0 bg_cmd=zsh:until_/x/monitor/watcher-supe bg_cpu_bp=0 bg_wedged=0 bg_members=1 bg_quiesce=1'
restart_outcome ae3 "$E3_LINE"
if [[ "$RO_RC" == 0 ]] && (( RO_CLEAN == 1 && RO_FORCED == 0 )); then
    pass "E3 every bg root quiescent (supervisor Monitor only) → turn boundary, CLEAN restart"
else
    fail "E3 quiescent shell-driven working-background not accepted (rc=$RO_RC clean=$RO_CLEAN forced=$RO_FORCED)"
fi
# E3b (w234sk F1). The watchdog prompt rendered for that restart carries ONE
# attempt nonce, identical in the loop command and in the --verify-only command,
# and no unrendered placeholder. The verifier holds the identity by
# construction and never searches the append-only log for it.
wdp="$WORK/ae3/monitor/.state/cc-auto-update/watchdog-prompt.md"
wd_env=$(sed -n "s/.*WATCHDOG_ATTEMPT='\([^']*\)'.*/\1/p" "$wdp" 2>/dev/null | sort -u)
wd_arg=$(sed -n "s/.*--attempt '\([^']*\)'.*/\1/p" "$wdp" 2>/dev/null | sort -u)
if [[ -n "$wd_env" && "$wd_env" == "$wd_arg" && "$wd_env" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] \
   && ! grep -q '{{' "$wdp"; then
    pass "E3b the rendered watchdog prompt carries one attempt nonce ($wd_env) in the loop AND the --verify-only command"
else
    fail "E3b watchdog prompt attempt wiring wrong: env=[$wd_env] arg=[$wd_arg] unrendered=$(grep -c '{{' "$wdp" 2>/dev/null)"
fi
restart_outcome ae4 "${E3_LINE/bg_shells=1/bg_shells=2}"
if [[ "$RO_RC" == 0 ]] && (( RO_CLEAN == 0 && RO_FORCED == 1 )); then
    pass "E4 a second, non-quiescent root (real work) → NOT eligible, forces at cap"
else
    fail "E4 a non-quiescent root was treated as a boundary (rc=$RO_RC clean=$RO_CLEAN forced=$RO_FORCED)"
fi
restart_outcome ae5 "${E3_LINE/bg_reliable=1/bg_reliable=0}"
if [[ "$RO_RC" == 0 ]] && (( RO_CLEAN == 0 && RO_FORCED == 1 )); then
    pass "E5 unreliable process-tree walk → NOT eligible, forces at cap"
else
    fail "E5 an unreliable walk was trusted (rc=$RO_RC clean=$RO_CLEAN forced=$RO_FORCED)"
fi
restart_outcome ae6 "${E3_LINE/ bg_quiesce=1/}"
if [[ "$RO_RC" == 0 ]] && (( RO_CLEAN == 0 && RO_FORCED == 1 )); then
    pass "E6 no bg_quiesce field (older pane-state) → NOT eligible, forces at cap"
else
    fail "E6 a line without bg_quiesce was treated as a boundary (rc=$RO_RC clean=$RO_CLEAN forced=$RO_FORCED)"
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

# H7. (your-org/nexus-code#1528, w240sk F1) A window-selection capture belongs
#     to a KILL. SIGTERM during the arm-wait — after the capture was written,
#     before the kill — exits 25 through the TERM trap, and the capture must
#     not survive it: a leftover is consumed by the next UNRELATED absent-target
#     respawn inside its 1800 s bound and moves an operator who chose another
#     window (measured by w240sk). Fails without the EXIT-trap drop.
ROOT="$WORK/h7"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
printf '#!/usr/bin/env bash\necho "spawn $*" >> "%s"\nexit 0\n' "$ROOT/calls.log" > "$ROOT/spawn"   # never arms
chmod +x "$ROOT/spawn"
h7_cap="$ROOT/monitor/.state/tmux-selection-capture"
env $(apply_env "$ROOT") CC_AUTO_ARM_WAIT_SECONDS=60 bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1 &
h7_pid=$!
h7_seen=0
for _i in $(seq 1 40); do [[ -f "$h7_cap" ]] && { h7_seen=1; break; }; sleep 0.25; done
# POSITIVE CONTROL first: the fixture must REACH the capture, or the absence
# below is a false zero.
if (( h7_seen == 1 )) && grep -q '^prior|\$0|@1|1$' "$h7_cap"; then
    pass "H7 control: the capture is written before the arm-wait (prior row present)"
else
    fail "H7 control: capture not written within 10 s (seen=$h7_seen) — the drop below is unmeasured"
fi
kill -TERM "$h7_pid" 2>/dev/null
wait "$h7_pid" 2>/dev/null; rc=$?
if (( rc == 25 )) && [[ ! -f "$h7_cap" ]] && ! grep -q "kill-window -t orchestrator" "$ROOT/calls.log"; then
    pass "H7 SIGTERM before the kill (rc 25) drops the selection capture (F1)"
else
    fail "H7 leftover capture after a TERMed restart (rc=$rc, capture=$([[ -f $h7_cap ]] && echo present || echo absent))"
fi
# H7b. …and a restart that REACHES the kill keeps it, with the post-kill row,
#      for the respawn to consume: the drop is keyed on the kill, not on exit.
ROOT="$WORK/h7b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
h7b_cap="$ROOT/monitor/.state/tmux-selection-capture"
env $(apply_env "$ROOT") bash "$APPLY" restart-orchestrator \
    --candidate 2.1.160 --sid "$(pin_of "$ROOT")" >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && grep -q "kill-window -t orchestrator" "$ROOT/calls.log" \
   && grep -q '^prior|\$0|@1|1$' "$h7b_cap" && grep -q '^post|\$0|@1$' "$h7b_cap"; then
    pass "H7b a restart that reached the kill leaves the capture (prior + post rows) for the respawn"
else
    fail "H7b capture after a completed restart wrong (rc=$rc, capture=$([[ -f $h7b_cap ]] && cat "$h7b_cap" | tr '\n' ' ' || echo absent))"
fi

# ===== restart-outcome marker + abort-streak escalation (nexus-code#511) ====

echo "== restart-outcome marker + abort escalation =="

# A non-resolving tmux stub (no orchestrator→index mapping) reproduces the
# target-window-unresolved abort (rc 23) this issue tracks. Same shape as
# case 20c, factored so the streak tests can reuse it.
_nonresolving_tmux() {
    # The NAME→INDEX resolution must come back EMPTY (that is what these
    # cases are about); the deployment gate's board enumeration must
    # still answer, or every one of them would defer at the gate for a
    # reason unrelated to what it is testing.
    cat > "$1/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$1/calls.log"
case "\$1" in
  list-windows)
    case "\$*" in
      *'#{window_name}|#{window_index}'*) exit 0 ;;
      *'#{window_name}'*) printf '%s\n' orchestrator ;;
    esac
    exit 0 ;;
esac
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

# G2. the PR probe FAILING is an INSTRUMENT FAILURE, not a verdict
#     (your-org/nexus-code#1492, operator directive). It measures a PROXY and
#     a stronger arm runs after it, so it degrades to UNMEASURED, files the
#     defect, and lets the board arms decide. PREVIOUS behaviour, stated
#     because this case asserted it until #1492: rc 30, deferred, and the
#     board arms below never ran at all.
ROOT="$WORK/g2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") CC_AUTO_GATE_PR_CMD=false bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
   && grep -q $'\tdeployment-gate-instrument-failed\t.*key=restart-path-pr-query' "$auto/decisions.tsv"; then
    pass "#1492 PR probe failure → UNMEASURED + filed defect, gate continues (was: rc 30 defer)"
else
    fail "#1492 PR-probe degrade wrong (rc=$rc): $(grep -c instrument-failed "$auto/decisions.tsv" 2>/dev/null)"
fi
# …and the AUDIT ROW must say UNMEASURED, never `none`. A confident zero
# standing in for "could not look" is this repo's dominant defect class, and
# the row is what a later reader reconstructs the decision from.
grep -q 'restart_path_prs=UNMEASURED' "$auto/decisions.tsv" \
    && pass "#1492 the deployment-gate row records restart_path_prs=UNMEASURED, not none" \
    || fail "#1492 the audit row claims a measurement that was never taken: $(grep deployment-gate "$auto/decisions.tsv" | tail -1)"

# G3 + G3b. live-window RECORD: 3 agent windows (infra names exempted) are
#     COUNTED and written to the audit row; the count never vetoes. Until
#     2026-09-12 G3 asserted the opposite (defer at max=2) — the operator
#     removed the arm: "a cc-update will not kill the worker, and if they, for
#     whatever reason, would crash, then the orchestrator can continue them
#     with no context lost." The flipped assertion FAILS on the pre-change
#     tree (rc 30 there), which is its RED-before evidence.
make_gate_tmux() {  # $1=root — tmux stub serving BOTH list-windows formats
    # Every window resolves to an index now: the board-quiet input
    # (your-org/nexus-code#1113) reads each agent window's pane state, and
    # a name that does not resolve is itself a deny arm — so a fixture
    # that only mapped `orchestrator` would exercise the refusal instead
    # of the case under test.
    cat > "$1/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$1/calls.log"
case "\$1" in
  list-windows)
    case "\$*" in
      *'#{window_name}|#{window_index}'*)
        printf '%s\n' 'orchestrator|2' 'services|3' 'cc-auto-update|4' \
                       'cc-restart-watchdog|5' 'w1|6' 'w2|7' 'w3|8' ;;
      *'#{window_name}'*)
        printf '%s\n' orchestrator services cc-auto-update cc-restart-watchdog w1 w2 w3 ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
    chmod +x "$1/tmux"
}
make_gate_pane_stub() {  # $1=root  $2=pane state reported for w1/w2/w3
    cat > "$1/pane-state" <<EOF
#!/usr/bin/env bash
echo "pane-state \$*" >> "$1/calls.log"
case "\$1" in
  6|7|8) printf 'state=%s active=1 window=%s name=w\n' "$2" "\$1" ;;
  *)     echo "state=idle active=1 window=2 name=orchestrator" ;;
esac
EOF
    chmod +x "$1/pane-state"
}
ROOT="$WORK/g3"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent
# CC_AUTO_MAX_LIVE_WINDOWS=2 is passed ON PURPOSE: it is the retired knob, and
# a value that would once have vetoed must now be inert.
env $(apply_env "$ROOT") CC_AUTO_TMUX="$ROOT/tmux" CC_AUTO_MAX_LIVE_WINDOWS=2 CC_AUTO_RESTART_INLINE=1 \
    bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
   && grep -q "live_windows=3" "$auto/decisions.tsv" \
   && ! grep -q "live-windows=3>max" "$auto/decisions.tsv"; then
    pass "D13 window record: 3 agents with a (retired) max of 2 → APPLIES; live_windows=3 recorded, no count veto (infra windows exempted from the count)"
else
    fail "D13 window record wrong (rc=$rc): $(grep -E 'safe-deferred|deployment-gate' "$auto/decisions.tsv" 2>/dev/null | tail -1)"
fi
ROOT="$WORK/g3b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent
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

# ===== #1113: the gate must key on IN-FLIGHT STATE, not on the path list ===
#
# `GATE_RESTART_PATHS` is a proxy sitting inside the gate whose whole job is
# deciding whether a restart is safe. Measured on the live board 2026-08-28
# ~04:20 PT during the 2.1.250 evaluation: six live agent windows, three open
# MERGEABLE PRs with a skeptic verifying a delta at that moment, ZERO
# restart-path hits, live windows 6 < max 8 — the gate would have CLEARED and
# restarted the watcher and the orchestrator under all of it. Every case below
# is that board, one input at a time.

gate_run() {   # $1=root, rest=extra env assignments; echoes rc
    local root="$1"; shift
    env $(apply_env "$root") CC_AUTO_TMUX="$root/tmux" "$@" \
        bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$root/gate.log" \
        --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
    echo $?
}
gate_unmutated() {  # $1=root — rc 0 iff nothing was bumped or installed
    [[ ! -f "$1/monitor/.state/cc-version-local" ]] \
        && ! grep -q '^install$' "$1/calls.log"
}
gate_applied() {    # $1=root — rc 0 iff the pin moved to the candidate AND install ran
    [[ "$(cat "$1/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
        && grep -q '^install$' "$1/calls.log"
}
gate_row() {        # $1=root — the newest deployment-gate audit row
    grep $'\tdeployment-gate\t' "$1/monitor/.state/cc-auto-update/decisions.tsv" 2>/dev/null | tail -1
}

# G2b. POTENCY CONTROL for G2 — THE ASSERTION THAT MAKES G2 MEAN ANYTHING.
#      Sits HERE rather than beside G2 because it needs make_gate_tmux /
#      gate_run / gate_unmutated, all defined below G2. Placed beside G2 it
#      ran with gate_run undefined, `rc` captured EMPTY, and the arithmetic
#      test on an empty string reported a failure that was about the
#      fixture — a potency control that could not itself be trusted.
#      Same broken probe, but a board that is NOT quiet. Until 2026-09-12
#      this asserted a DEFER on board-not-quiet; the operator removed the
#      board arms (D13), so the same fixture must now APPLY — and the busy
#      windows must still be RECORDED, which is what the fall-through now
#      reaches. FAILS on the pre-change tree (rc 30 there).
ROOT="$WORK/g2b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
make_gate_tmux "$ROOT"
printf '#!/usr/bin/env bash\necho "pane-state $*" >> "%s"\necho "state=busy active=1"\n' "$ROOT/calls.log" > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_CMD=false CC_AUTO_RESTART_INLINE=1)
auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 0 )) && gate_applied "$ROOT" && [[ "$(gate_row "$ROOT")" == *"w1=busy"* ]] \
    && pass "D13 (was #1492 potency): a degraded PR probe with a BUSY board APPLIES — the busy windows are RECORDED (unquiet_windows), not vetoed" \
    || fail "D13: degraded probe + busy board did not apply, or the record lost the busy windows (rc=$rc): $(gate_row "$ROOT")"


# Q1. THE #1113 BOARD, UNDER THE D13 DECISION. Three live agent windows, no
#     PR touching any restart path, panes not quiet. #1113 made this DEFER;
#     on 2026-09-12 the operator removed the board arms on a measured premise
#     (the restart path kills no worker; a crashed worker resumes via
#     spawn-worker.sh --resume), so this board now APPLIES — and the record
#     must still say which windows were live and what each read, because that
#     row is the post-hoc evidence. FAILS on the pre-change tree (rc 30).
ROOT="$WORK/q1113a"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" idle
rc=$(gate_run "$ROOT" CC_AUTO_RESTART_INLINE=1)
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )) && gate_applied "$ROOT" && ! grep -q "board-not-quiet=" "$auto/decisions.tsv"; then
    pass "D13: idle agent windows, zero restart-path PRs → APPLIES (no board-not-quiet deferral)"
else
    fail "D13: the #1113 board still defers or did not apply (rc=$rc): $(grep -E 'safe-deferred|deployment-gate' "$auto/decisions.tsv" 2>/dev/null | tail -1)"
fi
[[ "$(gate_row "$ROOT")" == *"w1=idle"* ]] \
    && pass "…and the deployment-gate row still names WHICH window and WHAT it read (w1=idle)" \
    || fail "the record lost the per-window states: $(gate_row "$ROOT")"

# Q2. …and `idle` is the state that matters, not an exotic one. An idle
#      SKEPTIC that has delivered one verdict and is waiting for the next
#      delta is the most re-pinnable window there is (nexus-code#771), and it
#      is exactly what `bk_pane_kill_authorized` would have called safe. This
#      case fails the moment the gate is rebuilt on the WRONG default-deny
#      dual, which is the likeliest way to reintroduce #1113.
ROOT="$WORK/q1113b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
# The summary verdict below is CONDITIONAL on this loop (your-org/nexus-code#1343).
# It used to be a bare `pass` executing unconditionally after the loop, so the
# line that NAMES the property reported success whatever the loop found — and
# the green went to stdout while the refutations went to stderr, which is the
# direction that survives a `2>/dev/null`.
#
# SCOPE, because #1343's framing overstates it and this comment's first draft
# inherited the overstatement -- which would have been this file's own defect
# shipping inside its own fix (skeptic `wstubsk`, verdict check):
#   - The PROPERTY was never unguarded. The per-state `fail` inside the loop
#     reddens the suite with or without this change; measured, BOTH arms of an
#     independent mutant exit rc 1. This closes a READABILITY hole -- the line
#     that names the property printed PASS on stdout while its own refutations
#     printed on stderr -- not a coverage hole.
#   - It was cited ONCE, not twice. The depth-1 skeptic on `wcc` cites it in S1
#     (a wrong pointer to a right fact; that verdict rests on three other legs).
#     `wcc`'s own report does not cite it for this argument at all.
# D13 (2026-09-12): the same nine states now APPLY, and the property pinned
# here moves from the VETO to the RECORD: every non-'absent' state must be
# written into the deployment-gate row as unquiet (`w1=<state>`), kill-
# authorised ones included (#771's dual, kept as the recorder's shape). A
# record that called any of these "quiet" would be the #1113 defect one level
# down. FAILS on the pre-change tree (every state rc 30 there).
_q1113b_bad=0
for st in idle autosuggest-only idle-orphan-async busy working-background blocked over-limit empty unknown; do
    make_gate_pane_stub "$ROOT" "$st"
    rm -f "$ROOT/monitor/.state/cc-version-local"; : > "$ROOT/calls.log"
    rc=$(gate_run "$ROOT" CC_AUTO_RESTART_INLINE=1)
    (( rc == 0 )) && gate_applied "$ROOT" && [[ "$(gate_row "$ROOT")" == *"w1=$st"* ]] \
        || { fail "D13: state '$st' did not apply, or was not recorded as unquiet (rc=$rc): $(gate_row "$ROOT")"
             _q1113b_bad=$(( _q1113b_bad + 1 )); }
done
(( _q1113b_bad == 0 )) \
    && pass "D13: every non-'absent' pane state APPLIES and is RECORDED as unquiet, kill-authorised ones included (#771's dual as the recorder)" \
    || fail "D13: $_q1113b_bad of 9 pane states failed to apply or to be recorded — see the per-state failures above"

# Q3. POTENCY CONTROL for G5b — the arm is not simply always-defer.
#      `absent` (renderer empty AND no live claude in the process tree) is
#      the one verdict that positively asserts a dead agent, and it clears.
ROOT="$WORK/q1113c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent
rc=$(gate_run "$ROOT" CC_AUTO_MAX_LIVE_WINDOWS=8 CC_AUTO_RESTART_INLINE=1)
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1113 potency: a board of provably-dead windows still clears the gate" \
    || fail "#1113: the quiet arm is unsatisfiable (rc=$rc) — a gate that never clears is a routine that stopped"

# Q4. 'Could not look' is RECORDED AS SUCH. An unreadable pane-state probe and
#     an unresolvable window name are readings that establish nothing; the
#     pre-#1113 gate counted them as agents-at-rest by never asking, #1113
#     deferred on them, and since D13 (2026-09-12) the bump APPLIES while the
#     record must still say `unreadable` — never `quiet`. FAILS on the
#     pre-change tree (rc 30).
ROOT="$WORK/q1113d"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
# Agent windows unreadable; the ORCHESTRATOR (index 2) stays readable, because
# under D13 the cleared gate is followed by the inline restart, which reads
# index 2 — a stub blind to it aborts the restart (rc 23) for a reason this
# case is not about.
cat > "$ROOT/pane-state" <<EOF
#!/usr/bin/env bash
case "\$1" in 2) echo "state=idle active=1 window=2 name=orchestrator" ;; *) exit 2 ;; esac
EOF
chmod +x "$ROOT/pane-state"
rc=$(gate_run "$ROOT" CC_AUTO_RESTART_INLINE=1)
auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 0 )) && gate_applied "$ROOT" && [[ "$(gate_row "$ROOT")" == *"w1=unreadable"* ]] \
    && pass "D13: an unreadable pane-state probe APPLIES and is recorded as unreadable, not as quiet" \
    || fail "D13: unreadable pane state did not apply or was not recorded (rc=$rc): $(gate_row "$ROOT")"

ROOT="$WORK/q1113e"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
# board names three agents; the name→index map knows only the orchestrator
cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
case "\$1" in
  list-windows)
    case "\$*" in
      *'#{window_name}|#{window_index}'*) echo "orchestrator|2" ;;
      *'#{window_name}'*) printf '%s\n' orchestrator w1 w2 w3 ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$ROOT/tmux"
rc=$(gate_run "$ROOT" CC_AUTO_RESTART_INLINE=1)
auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 0 )) && gate_applied "$ROOT" && [[ "$(gate_row "$ROOT")" == *"w1=unreadable"* ]] \
    && pass "D13: a window that does not resolve to an index APPLIES and is recorded unreadable (it is not written as 'quiet')" \
    || fail "D13: an unresolvable window did not apply or was recorded quiet (rc=$rc): $(gate_row "$ROOT")"

# Q6. THE SILENT ZERO IN THE ENUMERATOR ITSELF. `_gate_live_agent_windows`
#     used to be `|| return 0`, so a tmux that FAILED handed the gate an
#     empty list at rc 0 — "zero agents in flight" — and cleared it. Same for
#     a tmux that answers with nothing: this script runs inside a tmux
#     window, so a board of no windows is a malfunction, not a quiet nexus.
for mode in fail empty; do
    ROOT="$WORK/q1113f-$mode"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
    if [[ "$mode" == fail ]]; then
        cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
case "\$*" in *'#{window_name}|#{window_index}'*) echo "orchestrator|2"; exit 0 ;; esac
case "\$1" in list-windows) exit 1 ;; esac
exit 0
EOF
    else
        cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
case "\$*" in *'#{window_name}|#{window_index}'*) echo "orchestrator|2"; exit 0 ;; esac
case "\$1" in list-windows) printf '\n\n'; exit 0 ;; esac
exit 0
EOF
    fi
    chmod +x "$ROOT/tmux"
    rc=$(gate_run "$ROOT" CC_AUTO_RESTART_INLINE=1)
    auto="$ROOT/monitor/.state/cc-auto-update"
    # D13: the enumeration failure no longer vetoes (board arms removed
    # 2026-09-12) — but it is still never read as 'zero agents': the row
    # carries live_windows=UNMEASURED and a defect row is filed. FAILS on the
    # pre-change tree (rc 30 there).
    (( rc == 0 )) && gate_applied "$ROOT" && [[ "$(gate_row "$ROOT")" == *"live_windows=UNMEASURED"* ]] \
        && ! grep -q "live_windows=0" "$auto/decisions.tsv" \
        && grep -q $'\tdeployment-gate-instrument-failed\t.*key=board-enumeration' "$auto/decisions.tsv" \
        && pass "D13: tmux enumeration ($mode) → APPLIES with live_windows=UNMEASURED + a filed defect, never 'zero agents'" \
        || fail "D13: tmux enumeration $mode — wrong outcome or a confident zero (rc=$rc): $(gate_row "$ROOT")"
done

# G1b–G1d. your-org/nexus-code#1414 — the restart-path arm has a RECENCY BOUND
#          of its own. A stalled cosmetic PR on svc.sh (5.9 days untouched)
#          blocked a fully-evidenced bump forever while arm 3 aged it out.
ROOT="$WORK/g1b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nprintf "503\\tmonitor/svc.sh\\n"\n' > "$ROOT/gate-prs"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 503 "%s"\n' "$(date -Is -d '10 days ago')" > "$ROOT/gate-act"
chmod +x "$ROOT/gate-prs" "$ROOT/gate-act"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_CMD="$ROOT/gate-prs" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/gate-act" CC_AUTO_RESTART_INLINE=1)
auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
   && grep -q "stale-restart-path-pr=PR503" "$auto/decisions.tsv" \
   && grep -q "restart-path-pr-aged-out" "$auto/decisions.tsv" \
    && pass "#1414: a restart-path PR untouched for 10 days no longer blocks — and the exemption is RECORDED as its own audit row (the notify rides the same arm)" \
    || fail "#1414: stale restart-path PR still blocks (rc=$rc): $(grep -E 'safe-(deferred|applied)' "$auto/decisions.tsv" 2>/dev/null | tail -1)"
# G1c. POTENCY — the same PR touched a minute ago still defers.
ROOT="$WORK/g1c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nprintf "503\\tmonitor/svc.sh\\n"\n' > "$ROOT/gate-prs"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 503 "%s"\n' "$(date -Is -d '60 seconds ago')" > "$ROOT/gate-act"
chmod +x "$ROOT/gate-prs" "$ROOT/gate-act"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_CMD="$ROOT/gate-prs" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/gate-act")
auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 30 )) && gate_unmutated "$ROOT" && grep -q "deferred-pending-PR503" "$auto/decisions.tsv" \
    && pass "#1414 POTENCY: a LIVE restart-path PR still defers (the arm reads the timestamp)" \
    || fail "#1414: live restart-path PR cleared (rc=$rc)"
# G1d. FAIL-CLOSED — the activity probe failing leaves every hit LIVE.
ROOT="$WORK/g1d"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nprintf "503\\tmonitor/svc.sh\\n"\n' > "$ROOT/gate-prs"
chmod +x "$ROOT/gate-prs"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_CMD="$ROOT/gate-prs" CC_AUTO_GATE_PR_ACTIVITY_CMD=false)
auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 30 )) && gate_unmutated "$ROOT" && grep -q "deferred-pending-PR503" "$auto/decisions.tsv" \
    && pass "#1414: an unanswerable age is NOT 'stale' — the hit stays live (fail-closed)" \
    || fail "#1414: activity-probe failure exempted a restart-path PR (rc=$rc)"
# G1e. your-org/nexus-code#1400 (apply side): the SECOND identical safe-refused
#      is named a repeat in the audit row.
ROOT="$WORK/g1e"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" >/dev/null 2>&1
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" >/dev/null 2>&1
[[ "$(grep -c $'\tsafe-refused\t' "$auto/decisions.tsv" 2>/dev/null)" == 2 ]] \
   && [[ "$(grep -c 'safe-refused-repeat' "$auto/decisions.tsv" 2>/dev/null)" == 1 ]] \
    && pass "#1400: two identical safe-refused outcomes → the second is recorded as a REPEAT" \
    || fail "#1400: repeat not recorded: $(cat "$auto/decisions.tsv" 2>/dev/null | cut -f3,4 | tr '\n' ';')"

# Q7. AN INPUT ORTHOGONAL TO THE PATH LIST. A PR touching NOT ONE file on
#     GATE_RESTART_PATHS, updated a minute ago, defers — because whether a
#     review is in flight has nothing to do with which files it touches.
ROOT="$WORK/q1113g"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 README.md 991 docs/x.md\n' > "$ROOT/gate-prs"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "%s"\n' "$(date -Is -d '60 seconds ago')" > "$ROOT/gate-act"
chmod +x "$ROOT/gate-prs" "$ROOT/gate-act"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_CMD="$ROOT/gate-prs" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/gate-act")
auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 30 )) && gate_unmutated "$ROOT" && grep -q "pr-under-active-review=PR991" "$auto/decisions.tsv" \
    && pass "#1113: a PR under active review defers even at ZERO restart-path hits" \
    || fail "#1113: an actively-reviewed PR cleared the gate (rc=$rc): $(grep safe-deferred "$auto/decisions.tsv" 2>/dev/null | tail -1)"

# Q8. POTENCY CONTROL — the same PR, same zero path hits, updated ten days
#      ago, clears. Without this G8 would pass for an arm that always defers.
ROOT="$WORK/q1113h"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 README.md\n' > "$ROOT/gate-prs"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "%s"\n' "$(date -Is -d '10 days ago')" > "$ROOT/gate-act"
chmod +x "$ROOT/gate-prs" "$ROOT/gate-act"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_CMD="$ROOT/gate-prs" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/gate-act" CC_AUTO_RESTART_INLINE=1)
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1113 potency: a dormant PR does not defer — the arm reads the timestamp" \
    || fail "#1113: the active-review arm defers unconditionally (rc=$rc)"

# Q9. …and its two failure modes. A probe that FAILS, and a timestamp that
#     does not parse, are both "could not establish that nobody is
#     reviewing" — never "nobody is".
ROOT="$WORK/q1113i"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_ACTIVITY_CMD=false)
auto="$ROOT/monitor/.state/cc-auto-update"
# #1492 CHANGED THIS ARM'S VERDICT AND NOT ITS HONESTY. The activity probe is
# the WEAKER of the two proxies — the arm's own comment concedes it does not
# carry the property — so its instrument failure degrades to UNMEASURED and
# files a defect rather than deferring. What is unchanged, and is what #1113
# actually bought, is that "could not look" is never recorded as "nobody is
# reviewing": the row says UNMEASURED.
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && grep -q $'\tdeployment-gate-instrument-failed\t.*key=pr-activity-query' "$auto/decisions.tsv" \
    && pass "#1492: the activity probe failing → UNMEASURED + filed defect, gate continues (was: defer)" \
    || fail "#1492: activity-probe degrade wrong (rc=$rc)"
grep -q 'active_review_prs=UNMEASURED' "$auto/decisions.tsv" \
    && pass "#1492: …and the row says active_review_prs=UNMEASURED, never none" \
    || fail "#1492: the row claims an active-review measurement that was never taken"
# D13 (was the G2b-shaped potency control): a degraded activity probe with a
# BUSY board now APPLIES and RECORDS the busy windows. FAILS on the pre-change
# tree (rc 30 there).
ROOT="$WORK/q1113i2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
make_gate_tmux "$ROOT"
printf '#!/usr/bin/env bash\necho "pane-state $*" >> "%s"\necho "state=busy active=1"\n' "$ROOT/calls.log" > "$ROOT/pane-state"
chmod +x "$ROOT/pane-state"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_ACTIVITY_CMD=false CC_AUTO_RESTART_INLINE=1)
(( rc == 0 )) && gate_applied "$ROOT" && [[ "$(gate_row "$ROOT")" == *"w1=busy"* ]] \
    && pass "D13: a degraded activity probe with a BUSY board APPLIES; the busy windows are recorded" \
    || fail "D13: degraded activity probe + busy board did not apply or lost the record (rc=$rc): $(gate_row "$ROOT")"

# ===== #1492: instrument-defect FILING is deduplicated ======================
#
# This routine fires DAILY. A filer with no idempotency key opens a fresh issue
# every morning for one broken instrument — spam that trains the operator to
# ignore exactly the channel the directive created. So the assertion is not
# "an issue was filed" but "filed ONCE, and the repeat is COUNTED".
ROOT="$WORK/df1492"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
cat > "$ROOT/issue-cmd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$ROOT/filed.log"
echo "https://github.com/your-org/nexus-code/issues/4242"
EOF
chmod +x "$ROOT/issue-cmd"
auto="$ROOT/monitor/.state/cc-auto-update"
for pass in 1 2 3; do
    rm -f "$ROOT/monitor/.state/cc-version-local"   # the idempotency no-op sits ABOVE the gate
    env $(apply_env "$ROOT") CC_AUTO_GATE_PR_CMD=false \
        CC_AUTO_GATE_ISSUE_CMD="$ROOT/issue-cmd" CC_AUTO_RESTART_INLINE=1 \
        bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" \
        --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
done
# `grep -c` PRINTS 0 on no match and exits 1, so `|| echo 0` would append a
# SECOND value (count-fallback-lint, your-org/nexus-code#725). Assign, then
# default on the rc — which also covers the file being absent, where grep
# prints NOTHING rather than 0.
filed=$(grep -c 'restart-path-pr-query' "$ROOT/filed.log" 2>/dev/null) || filed=0
(( filed == 1 )) \
    && pass "#1492 the instrument defect is filed ONCE across three fires (not once per day)" \
    || fail "#1492 defect filing is not deduplicated: $filed filings in 3 fires"
bcf="$auto/gate-defects/restart-path-pr-query"
[[ -f "$bcf" ]] && grep -q 'issue=your-org/nexus-code#4242' "$bcf" \
    && pass "#1492 the breadcrumb records the filed issue number" \
    || fail "#1492 breadcrumb missing/wrong: $(cat "$bcf" 2>/dev/null)"
# THE COUNTER MUST ACTUALLY MOVE. The first cut of this re-emitted the whole
# breadcrumb line and APPENDED ` count=N`, so the parse read back `count=1`
# forever — a counter frozen at its first value while looking maintained. A
# `count=` present is not evidence; a count that INCREMENTS is.
n=$(awk -F'count=' 'NF>1{print $2+0; exit}' "$bcf" 2>/dev/null || echo 0)
(( n == 3 )) \
    && pass "#1492 the repeat count INCREMENTS across fires (3), it is not frozen at 1" \
    || fail "#1492 repeat count is $n after 3 fires (expected 3): $(cat "$bcf" 2>/dev/null)"
[[ "$(command grep -c 'count=' "$bcf")" == "1" ]] \
    && pass "#1492 …and exactly one count= field survives (no ' count=1 count=2' accretion)" \
    || fail "#1492 the breadcrumb accreted count fields: $(cat "$bcf" 2>/dev/null)"

# ===== #1492: the `rollback` VERB, and its POTENCY ==========================
#
# WHY THIS BLOCK IS SHAPED AS A BEFORE/AFTER AND NOT AS AN EXIT-CODE CHECK.
# The operator's risk calculus on #1492 rests on a rollback being available
# after the restart. Measured at 77181f33 it was not: `rollback_pin` was a
# function LOCAL to cmd_safe with both call sites BEFORE the watcher restart,
# and no verb exposed it — rc 6 / rc 22 / rc 21 all left the NEW pin standing.
#
# A RECOVERY PATH THAT HAS NEVER BEEN SHOWN TO FIRE IS WORSE THAN A
# KNOWN-ABSENT ONE, because it converts "we have no rollback" into "we believe
# we have rollback", and the second is the more dangerous state to make a gate
# decision under. So every case below asserts the pin was DEMONSTRABLY AT THE
# CANDIDATE FIRST. Without that, "the pin equals the prior version" passes
# trivially in a fixture where nothing ever moved it — the assertion would be
# satisfied by a verb that does nothing at all.

# `make_pin_following_claude` is defined with the fixtures at the top of this
# file (it is now make_apply_root's DEFAULT stub, your-org/nexus-code#1002);
# the calls below are kept so each RB case still states its own precondition.

# RB1. had_prior=1 — a local pin existed before the bump and must come back.
ROOT="$WORK/rb1"; make_apply_root "$ROOT" "2.1.140" "2.1.160"
printf '2.1.150\n' > "$ROOT/monitor/.state/cc-version-local"     # the PRIOR pin
make_pin_following_claude "$ROOT" "2.1.140"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) \
    > "$ROOT/bump.log" 2>&1
# NEGATIVE CONTROL / POTENCY PRECONDITION: the pin must be AT THE CANDIDATE
# before rollback runs. Everything below is meaningless without this line.
[[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1492 rollback POTENCY PRECONDITION: the bump moved the pin to 2.1.160" \
    || fail "#1492 the bump did not move the pin — every rollback assertion below would pass vacuously"
[[ -f "$ROOT/monitor/.state/cc-auto-update/rollback-state" ]] \
    && grep -q 'prior_pin=2.1.150' "$ROOT/monitor/.state/cc-auto-update/rollback-state" \
    && pass "#1492 the durable breadcrumb records prior_pin=2.1.150" \
    || fail "#1492 no usable rollback breadcrumb: $(cat "$ROOT/monitor/.state/cc-auto-update/rollback-state" 2>/dev/null)"
installs_before=$(grep -c '^install$' "$ROOT/calls.log")
env $(apply_env "$ROOT") bash "$APPLY" rollback --reason "potency proof" > "$ROOT/rb.log" 2>&1
rc=$?
installs_after=$(grep -c '^install$' "$ROOT/calls.log")
(( rc == 0 )) && pass "#1492 rollback exits 0" || fail "#1492 rollback rc=$rc: $(tail -3 "$ROOT/rb.log")"
[[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.150" ]] \
    && pass "#1492 rollback RESTORED the prior pin 2.1.150 (was 2.1.160)" \
    || fail "#1492 rollback did not restore the pin: $(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)"
# The REINSTALL is read from calls.log, not inferred from the exit code: a
# restored pin with a stale binary is the version-split this verb exists to
# close, and it would exit 0 just the same.
(( installs_after > installs_before )) \
    && pass "#1492 rollback RE-INVOKED the installer ($installs_before -> $installs_after)" \
    || fail "#1492 rollback restored the pin but never reinstalled — the binary is still 2.1.160"
grep -q $'\trolled-back\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" \
    && pass "#1492 rollback records a 'rolled-back' outcome row" || fail "#1492 no rolled-back audit row"
[[ -f "$ROOT/monitor/.state/cc-auto-update/restart-hold" ]] \
    && pass "#1492 rollback writes a restart-hold (the reconcile cannot silently re-apply)" \
    || fail "#1492 rollback left the reconcile free to re-fire toward 2.1.160"
[[ ! -f "$ROOT/monitor/.state/cc-auto-update/rollback-state" ]] \
    && pass "#1492 rollback CONSUMES the breadcrumb (a second run cannot replay a stale record)" \
    || fail "#1492 the breadcrumb survived the rollback"

# RB2. had_prior=0 — THE ARM MOST LIKELY TO BE SILENTLY WRONG. "Restore the
#      prior pin" when there was none means REMOVE the file so the shared
#      package.json floor resumes. A verb that writes the literal string
#      `<none>` into the pin file would pass an exit-code check and leave the
#      resolver reading a version that does not exist.
ROOT="$WORK/rb2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
make_pin_following_claude "$ROOT" "2.1.150"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
[[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1492 RB2 potency precondition: pin moved to 2.1.160 with no prior local pin" \
    || fail "#1492 RB2 the bump did not move the pin"
grep -q 'prior_pin=<none>' "$ROOT/monitor/.state/cc-auto-update/rollback-state" \
    && pass "#1492 RB2 the breadcrumb records prior_pin=<none>, not an empty value" \
    || fail "#1492 RB2 breadcrumb wrong: $(cat "$ROOT/monitor/.state/cc-auto-update/rollback-state" 2>/dev/null)"
env $(apply_env "$ROOT") bash "$APPLY" rollback > "$ROOT/rb.log" 2>&1
rc=$?
if (( rc == 0 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]]; then
    pass "#1492 RB2 rollback REMOVED the pin file — the floor resumes (not the literal '<none>')"
else
    fail "#1492 RB2 rollback left pin='$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)' (rc=$rc)"
fi

# RB3. REFUSALS. Each is a refusal, never a finding that the pin is fine.
ROOT="$WORK/rb3"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" rollback >/dev/null 2>&1
(( $? == 3 )) && pass "#1492 rollback with NO breadcrumb REFUSES (rc 3), never exits 0" \
    || fail "#1492 rollback without a breadcrumb did not refuse"
mkdir -p "$ROOT/monitor/.state/cc-auto-update"
printf 'candidate=2.1.160\nwritten=now\n' > "$ROOT/monitor/.state/cc-auto-update/rollback-state"
env $(apply_env "$ROOT") bash "$APPLY" rollback >/dev/null 2>&1
(( $? == 3 )) && pass "#1492 a TORN breadcrumb (no prior_pin) refuses — not read as '<none>'" \
    || fail "#1492 a torn breadcrumb was acted on"
printf 'prior_pin=garbage\ncandidate=2.1.160\n' > "$ROOT/monitor/.state/cc-auto-update/rollback-state"
env $(apply_env "$ROOT") bash "$APPLY" rollback >/dev/null 2>&1
(( $? == 3 )) && pass "#1492 a non-version prior_pin is REFUSED (shape validated, not just non-empty)" \
    || fail "#1492 rollback wrote a garbage pin"

# RB4. The post-rollback VERIFY is real. A binary that does not come back at
#      the restored version must fail LOUD, not report success — the
#      manufactured-success shape is the one that matters here, because every
#      other artefact would say the rollback worked.
ROOT="$WORK/rb4"; make_apply_root "$ROOT" "2.1.140" "2.1.160"
printf '2.1.150\n' > "$ROOT/monitor/.state/cc-version-local"
make_pin_following_claude "$ROOT" "2.1.140"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
# Freeze the stub at the NEW version: the reinstall "succeeds" but the binary
# never actually goes back.
printf '#!/usr/bin/env bash\necho "2.1.160 (Claude Code)"\n' > "$ROOT/claude"; chmod +x "$ROOT/claude"
env $(apply_env "$ROOT") bash "$APPLY" rollback >/dev/null 2>&1
(( $? == 5 )) && pass "#1492 RB4 a binary that stays at 2.1.160 fails the post-rollback verify (rc 5)" \
    || fail "#1492 RB4 rollback reported success while the binary was still 2.1.160"

# NOTE ON PLACEMENT — these live BELOW make_pin_following_claude on purpose.
# Placed above it (their first home) the helper was not yet defined, the
# call was a silent command-not-found, the fixture kept make_apply_root's
# claude stub hardcoded to the CANDIDATE, and RB6 failed with rc 5 — the
# verify working CORRECTLY on a mis-built fixture. That is the second
# helper-ordering miss in this file (see G2b); a linear suite that defines
# helpers between cases will keep producing it, and the failure reads as a
# defect in the code under test rather than in the fixture.
# RB5. THE VERIFY MUST BE ABLE TO FAIL WHEN THE EXPECTED VERSION IS
#      UNRESOLVABLE (w227 skeptic F1). The `prior_pin=<none>` arm removes the
#      local pin, so the expected version comes from the package.json FLOOR.
#      Destroy the floor and `cc_version_effective` cannot answer.
#
#      THE ORIGINAL GUARD WAS `[[ -z "$running" || ( -n "$want" && … ) ]]`, and
#      the `-n "$want"` made an unresolvable expectation DISABLE the comparison
#      — reducing the whole check to "did the binary answer at all" and exiting
#      0 with "binary verified" while the binary sat at the version it had
#      rolled away from. A verify that cannot fail is not a verify, and it is
#      worse than no rollback at all: it upgrades "we have no rollback" into
#      "we believe we have rollback".
#
#      This case is the potency proof for the verify ITSELF. RB4 proves the
#      comparison fires when `want` RESOLVES; this proves the verify refuses
#      when it does NOT. Both are needed — RB4 passed while this hole was open.
ROOT="$WORK/rb5"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
make_pin_following_claude "$ROOT" "2.1.150"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
[[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1492 RB5 potency precondition: pin moved to 2.1.160" \
    || fail "#1492 RB5 the bump did not move the pin"
# The binary STAYS at 2.1.160 — a genuinely bad rollback — while the expected
# version becomes unresolvable. A verify that cannot fail reports success here.
printf '#!/usr/bin/env bash\necho "2.1.160 (Claude Code)"\n' > "$ROOT/claude"; chmod +x "$ROOT/claude"
rm -f "$ROOT/package.json"
env $(apply_env "$ROOT") bash "$APPLY" rollback > "$ROOT/rb5.log" 2>&1
rc=$?
(( rc == 5 )) \
    && pass "#1492 RB5 an UNRESOLVABLE expected version FAILS the verify (rc 5), never passes vacuously" \
    || fail "#1492 RB5 the verify passed with no expectation to compare against (rc=$rc): $(tail -2 "$ROOT/rb5.log")"
grep -q 'could not RESOLVE' "$ROOT/rb5.log" \
    && pass "#1492 RB5 …and says it could not RESOLVE the expectation, not that the binary mismatched" \
    || fail "#1492 RB5 the diagnostic misattributes the failure: $(tail -2 "$ROOT/rb5.log")"
grep -q $'\trollback-failed\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" \
    && pass "#1492 RB5 …and the audit row records a FAILED rollback" \
    || fail "#1492 RB5 no rollback-failed row"

# RB6. THE SECOND INSTANCE OF F1'S SHAPE, found by sweeping for it rather than
#      by being told (w227 skeptic F1's sweep instruction).
#      `cc_version_read_local_pin` returns non-zero for TWO worlds — no pin
#      file, and a pin file that is present but EMPTY (a torn write). A bare
#      `|| now_pin="<none>"` collapsed them, and on the `prior=<none>` arm the
#      collapse compared EQUAL and exited 0 "nothing to restore", leaving the
#      torn file exactly where it was. "Could not read it" is not "it is not
#      there", and only one of those is safe to no-op on.
ROOT="$WORK/rb6"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
make_pin_following_claude "$ROOT" "2.1.150"
mkdir -p "$ROOT/monitor/.state/cc-auto-update"
printf 'prior_pin=<none>\ncandidate=2.1.160\n' > "$ROOT/monitor/.state/cc-auto-update/rollback-state"
printf '   \n' > "$ROOT/monitor/.state/cc-version-local"      # TORN: present, unusable
env $(apply_env "$ROOT") bash "$APPLY" rollback > "$ROOT/rb6.log" 2>&1
rc=$?
if (( rc == 0 )) && [[ ! -e "$ROOT/monitor/.state/cc-version-local" ]]; then
    pass "#1492 RB6 a TORN pin file is REMOVED, not mistaken for an absent one"
else
    fail "#1492 RB6 torn pin survived the rollback (rc=$rc, file $( [[ -e "$ROOT/monitor/.state/cc-version-local" ]] && echo present || echo gone ))"
fi
grep -q 'UNREADABLE, not as absent' "$ROOT/rb6.log" \
    && pass "#1492 RB6 …and it says so, rather than silently treating it as absent" \
    || fail "#1492 RB6 no unreadable diagnostic: $(tail -2 "$ROOT/rb6.log")"
# CONTROL: a genuinely ABSENT pin with prior=<none> IS a legitimate no-op.
# Without this, RB6 would pass for a verb that simply never no-ops.
ROOT="$WORK/rb6b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
mkdir -p "$ROOT/monitor/.state/cc-auto-update"
printf 'prior_pin=<none>\ncandidate=2.1.160\n' > "$ROOT/monitor/.state/cc-auto-update/rollback-state"
rm -f "$ROOT/monitor/.state/cc-version-local"
env $(apply_env "$ROOT") bash "$APPLY" rollback > "$ROOT/rb6b.log" 2>&1
rc=$?
(( rc == 0 )) && grep -q 'nothing to restore' "$ROOT/rb6b.log" \
    && pass "#1492 RB6 CONTROL: a genuinely ABSENT pin still no-ops (the fix did not just delete the no-op)" \
    || fail "#1492 RB6 control: absent pin no longer no-ops (rc=$rc)"

# ===== #1492 F2: the filer's OWN failure must be visible ====================
#
# THE DEPENDENCY SET IS THE DEFECT. The filer needs the mint AND gh; the probes
# whose failure triggers it need the mint and gh too. So in the dominant
# failure cause the arms degrade and the "file it" half CANNOT RUN — measured
# by the w227 skeptic: a natural mint failure degraded both proxies, applied at
# rc 0, and filed ZERO issues. A degrade that files nothing is the give-up the
# operator directive was aimed at, wearing better clothes.
ROOT="$WORK/f2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/mint"; chmod +x "$ROOT/mint"
auto="$ROOT/monitor/.state/cc-auto-update"
env $(apply_env "$ROOT") CC_AUTO_GATE_PR_CMD=false CC_AUTO_MINT_CMD="$ROOT/mint" \
    CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) > "$ROOT/f2.log" 2>&1
rc=$?
# The DEGRADE still happens — F2 must not re-introduce a blocking dependency.
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1492 F2 a filer that cannot file does NOT block the gate (still applies)" \
    || fail "#1492 F2 the unfiled path became a blocker (rc=$rc) — the defect one level up"
# …but the failure to file is now DURABLE, COUNTED and VISIBLE.
[[ -f "$auto/gate-defects/restart-path-pr-query.UNFILED" ]] \
    && pass "#1492 F2 an UNFILED marker is written when the mint is down" \
    || fail "#1492 F2 the filer failed silently — no UNFILED marker"
grep -q $'\tdeployment-gate-defect-UNFILED\t.*key=restart-path-pr-query' "$auto/decisions.tsv" \
    && pass "#1492 F2 …and the audit trail records it as UNFILED, not merely as degraded" \
    || fail "#1492 F2 no UNFILED audit row"
grep -q 'unfiled_defects=1' "$auto/decisions.tsv" \
    && pass "#1492 F2 …and the backlog count rides the deployment-gate row a reader already reads" \
    || fail "#1492 F2 unfiled_defects missing from the gate row: $(grep deployment-gate "$auto/decisions.tsv" | tail -1)"
# THE RETRY, and that a SUCCEEDING file clears the marker — otherwise the count
# would mean "ever failed" rather than "still unreported".
cat > "$ROOT/issue-cmd" <<EOF
#!/usr/bin/env bash
echo "https://github.com/your-org/nexus-code/issues/7777"
EOF
chmod +x "$ROOT/issue-cmd"
rm -f "$ROOT/monitor/.state/cc-version-local"
env $(apply_env "$ROOT") CC_AUTO_GATE_PR_CMD=false CC_AUTO_GATE_ISSUE_CMD="$ROOT/issue-cmd" \
    CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
if [[ ! -f "$auto/gate-defects/restart-path-pr-query.UNFILED" ]] \
   && grep -q 'issue=your-org/nexus-code#7777' "$auto/gate-defects/restart-path-pr-query" 2>/dev/null; then
    pass "#1492 F2 the next fire RETRIES and, on success, CLEARS the marker (backlog means still-unreported)"
else
    fail "#1492 F2 the unfiled marker survived a successful re-file"
fi

# ===== #1492: the transient `•bell` phantom =================================
#
# THE NATURAL TEST CERTIFIES NOTHING, and that is why this one is shaped the
# way it is. "A quiet board enumerates no phantom" passes identically with and
# without the filter, because a quiet board has no phantom on it. The
# assertion has to be that a PLANTED `•bell` is ABSENT from the enumeration
# WHILE A NORMALLY-NAMED WINDOW BESIDE IT IS PRESENT — a positive control in
# the same run, otherwise an empty enumeration reads as a pass.

# P1. The phantom is dropped, and the real busy window beside it is NOT.
ROOT="$WORK/p1492a"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
case "\$1" in
  list-windows)
    case "\$*" in
      *'#{window_name}|#{window_index}'*)
        printf '%s\n' 'orchestrator|2' 'w226|6' '•bell|9' ;;
      *'#{window_name}'*)
        printf '%s\n' orchestrator w226 '•bell' ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$ROOT/tmux"
# pane-state: the real worker is BUSY; the phantom index resolves to nothing
# readable, which is exactly how it read on the live board (`•bell=unreadable`).
cat > "$ROOT/pane-state" <<EOF
#!/usr/bin/env bash
echo "pane-state \$*" >> "$ROOT/calls.log"
case "\$1" in
  6) echo "state=busy active=1" ;;
  2) echo "state=idle active=1 window=2 name=orchestrator" ;;   # the orchestrator: readable, so the D13 inline restart can resolve it
  *) exit 2 ;;
esac
EOF
chmod +x "$ROOT/pane-state"
rc=$(gate_run "$ROOT" CC_AUTO_RESTART_INLINE=1)
auto="$ROOT/monitor/.state/cc-auto-update"
row=$(grep $'\tdeployment-gate\t' "$auto/decisions.tsv" 2>/dev/null | tail -1)
# POSITIVE CONTROL: the real window MUST be in the unquiet set. If it is not,
# the enumeration is empty for some unrelated reason and the phantom's absence
# below proves nothing.
case "$row" in
    *"w226=busy"*) pass "#1492 positive control: the real busy window IS enumerated and unquiet" ;;
    *) fail "#1492 positive control FAILED — w226 absent, so the phantom's absence is not evidence: $row" ;;
esac
# THE ASSERTION: the phantom is not in the population at all.
case "$row" in
    *"•bell"*) fail "#1492 the •bell phantom is STILL in the gate population: $row" ;;
    *) pass "#1492 the •bell phantom is dropped from _gate_live_agent_windows" ;;
esac
# …and the COUNT is right. The live board reported live_windows=2 for one
# agent, and that count also feeds GATE_MAX_LIVE_WINDOWS.
case "$row" in
    *"live_windows=1"*) pass "#1492 live_windows=1 — the phantom no longer inflates the count" ;;
    *) fail "#1492 live_windows is still counting the phantom: $row" ;;
esac
# D13: the real busy worker is RECORDED (asserted above) and the bump APPLIES —
# the phantom fix narrows the recorded population; the veto is gone since
# 2026-09-12. FAILS on the pre-change tree (rc 30 there).
(( rc == 0 )) && pass "D13 …and with the REAL busy worker recorded, the bump APPLIES (rc 0) — the population fix narrows the record, the veto is gone" \
    || fail "D13: a busy window still vetoes the bump (rc=$rc)"

# P2. NEGATIVE CONTROL — the same board with the phantom REPLACED by an
#     ordinary window of the same shape. It must be enumerated and RECORDED
#     as unreadable (D13: recorded, not vetoed), proving P1's drop is keyed on
#     the `•` prefix and not on the window being unreadable.
ROOT="$WORK/p1492b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
case "\$1" in
  list-windows)
    case "\$*" in
      *'#{window_name}|#{window_index}'*) printf '%s\n' 'orchestrator|2' 'bell|9' ;;
      *'#{window_name}'*)                 printf '%s\n' orchestrator bell ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$ROOT/tmux"
cat > "$ROOT/pane-state" <<EOF
#!/usr/bin/env bash
echo "pane-state \$*" >> "$ROOT/calls.log"
case "\$1" in 2) echo "state=idle active=1 window=2 name=orchestrator" ;; *) exit 2 ;; esac
EOF
chmod +x "$ROOT/pane-state"
rc=$(gate_run "$ROOT" CC_AUTO_RESTART_INLINE=1)
row=$(grep $'\tdeployment-gate\t' "$ROOT/monitor/.state/cc-auto-update/decisions.tsv" 2>/dev/null | tail -1)
if (( rc == 0 )) && [[ "$row" == *"bell=unreadable"* ]]; then
    pass "#1492 negative control (D13 shape): a window named 'bell' (no bullet) is STILL enumerated and recorded unreadable; the bump applies"
else
    fail "#1492 the filter is over-broad — it dropped a legitimate window, or the bump did not apply: rc=$rc row=$row"
fi

# P3. The shared predicate itself, at its boundaries. An UNANCHORED match
#     would drop any window whose name merely CONTAINS a bullet, which is a
#     permissive default arm pointing at the population the gate must not
#     silently shrink.
if bk_is_transient_window_name '•bell' \
   && bk_is_transient_window_name '•' \
   && ! bk_is_transient_window_name 'bell' \
   && ! bk_is_transient_window_name 'w•226' \
   && ! bk_is_transient_window_name '' ; then
    pass "#1492 bk_is_transient_window_name is PREFIX-anchored (drops '•bell', keeps 'w•226' and '')"
else
    fail "#1492 bk_is_transient_window_name matches the wrong set"
fi

# Q9c. THE FORMER ASYMMETRY, now uniform (D13, 2026-09-12). Until then the
#      board ENUMERATION failing was the one instrument failure that DEFERRED
#      (it measured the hazard directly, no fallback). With the board arms
#      removed every instrument failure degrades the same way — UNMEASURED
#      in the row, a defect filed, the gate continues. What this case still
#      catches is the confident zero: an unenumerable board must never be
#      written as live_windows=0. FAILS on the pre-change tree (rc 30).
ROOT="$WORK/q1492board"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
# A tmux mock that FAILS, written as a HEREDOC rather than via printf.
# test-tmux-shim-gate3-safety.sh (your-org/nexus-code#1105) must be able to
# PROVE a planted `tmux` is a mock; a printf-built body hides its redirect
# target behind a runtime `%s`, so the classifier cannot see that this shim
# never execs anything and defaults to DENY — correctly, because the failure
# it guards is a fixture shim reaching the OPERATOR'S REAL BOARD.
cat > "$ROOT/tmux" <<EOF
#!/usr/bin/env bash
echo "tmux \$*" >> "$ROOT/calls.log"
exit 1
EOF
chmod +x "$ROOT/tmux"
rc=$(gate_run "$ROOT" CC_AUTO_RESTART_INLINE=1)
auto="$ROOT/monitor/.state/cc-auto-update"
# rc is 23 here, not 0: this fixture's tmux FAILS EVERY CALL, so the inline
# restart that follows the cleared gate cannot resolve the orchestrator window
# and aborts — "Bump itself is complete". The property under test is the GATE:
# no deferral (rc != 30), pin moved, install ran, and the row says UNMEASURED.
(( rc != 30 )) && gate_applied "$ROOT" && [[ "$(gate_row "$ROOT")" == *"live_windows=UNMEASURED"* ]] \
    && ! grep -q $'\tsafe-deferred\t' "$auto/decisions.tsv" \
    && ! grep -q "live_windows=0" "$auto/decisions.tsv" \
    && pass "D13: board-enumeration failure does NOT defer — pin moved with live_windows=UNMEASURED (restart rc=$rc is the blind fixture tmux, not the gate)" \
    || fail "D13: board-enumeration failure did not apply, or wrote a confident count (rc=$rc): $(gate_row "$ROOT")"
grep -q $'\tdeployment-gate-instrument-failed\t.*key=board-enumeration' "$auto/decisions.tsv" \
    && pass "…and it is STILL filed as a defect — recording and filing are not alternatives" \
    || fail "D13: board-enumeration failure was not filed as a defect"
ROOT="$WORK/q1113j"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "not-a-timestamp"\n' > "$ROOT/gate-act"
chmod +x "$ROOT/gate-act"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/gate-act")
auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 30 )) && grep -q "unparseable-ts" "$auto/decisions.tsv" \
    && pass "#1113: an unparseable updated-at is not 'old' — it defers, and says so" \
    || fail "#1113: an unparseable timestamp was treated as dormant (rc=$rc)"

# Q10. A GATE THAT NEVER CLEARS IS A ROUTINE THAT SILENTLY STOPPED. The
#      tightening above makes that outcome more reachable, so consecutive
#      deferrals have to reach the operator — the same lesson as #968 part 3,
#      one script over.
#      D13 (2026-09-12): an idle board can no longer produce the deferrals this
#      case needs, so the streak is driven by a live RESTART-PATH PR — a proxy
#      arm — with the streak CAP disabled (0): at the default cap of 3 the
#      third fire would OVERRIDE rather than defer, and the escalation row
#      lives on the deferral branch.
ROOT="$WORK/q1113k"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" idle
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "monitor/watcher/main.sh"\n' > "$ROOT/q10-pr"
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "$(date -Is)"\n' > "$ROOT/q10-act"
chmod +x "$ROOT/q10-pr" "$ROOT/q10-act"
auto="$ROOT/monitor/.state/cc-auto-update"
for i in 1 2; do rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_CMD="$ROOT/q10-pr" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/q10-act" CC_AUTO_GATE_DEFER_STREAK_ALERT=3 CC_AUTO_GATE_DEFER_STREAK_CAP=0); done
! grep -q "deployment-gate-defer-escalation" "$auto/decisions.tsv" \
    && pass "#1113: two deferrals are routine — no escalation" \
    || fail "#1113: escalated below the threshold (an alert that always fires is not read)"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_PR_CMD="$ROOT/q10-pr" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/q10-act" CC_AUTO_GATE_DEFER_STREAK_ALERT=3 CC_AUTO_GATE_DEFER_STREAK_CAP=0)
grep -q "deployment-gate-defer-escalation" "$auto/decisions.tsv" && grep -q "streak=3" "$auto/decisions.tsv" \
    && pass "#1113: three deferrals in a row escalate, with the streak in the row" \
    || fail "#1113: a gate stuck shut for three fires said nothing"
# …and the streak resets on a clear, so the alert is about NOW. The PR arm is
# withdrawn (probe reports no PRs); the idle board is left in place because
# under D13 it is recorded, not gated on.
rm -f "$ROOT/monitor/.state/cc-version-local"
rc=$(gate_run "$ROOT" CC_AUTO_GATE_DEFER_STREAK_ALERT=3 CC_AUTO_RESTART_INLINE=1)
(( rc == 0 )) && [[ ! -f "$auto/gate-defer-streak" ]] \
    && pass "…and a cleared gate resets the streak (idle windows recorded, not vetoing)" \
    || fail "#1113: the defer streak survived a clear (rc=$rc)"

# ---------------------------------------------------------------------------
# O. BOUNDED DEFERRAL — "a very busy board should only DELAY the update and
#    not PREVENT it" (operator directive, your-org/nexus-code#1492 and the
#    2026-09-10 restatement).
#
#    WHY THESE CASES AND NOT A SINGLE HAPPY-PATH ONE. The override is the only
#    PERMISSIVE verdict in this gate, so what has to be pinned is not that it
#    fires — it is (O2) that firing continues into whatever arms remain and,
#    with the board arms gone since 2026-09-12 (D13), CLEARS while still
#    RECORDING the board; (O3) that a busy board alone never defers any more;
#    and (O5) that an unreadable age fails toward DEFER. A test that only
#    proves the hatch opens is a test of the half that is safe to get wrong.
#
#    A restart-path PR is the PROXY arm used to drive it: it is the arm that
#    produced 5 of this nexus's 10 recorded deferrals.
make_gate_restart_pr() {   # $1=root — one open PR touching a GATE_RESTART_PATHS file
    printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "monitor/watcher/main.sh"\n' > "$1/gate-pr"
    printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "$(date -Is)"\n' > "$1/gate-act"
    chmod +x "$1/gate-pr" "$1/gate-act"
}
gate_run_proxy() {   # $1=root, rest=env — drive the restart-path arm
    local root="$1"; shift
    gate_run "$root" CC_AUTO_GATE_PR_CMD="$root/gate-pr" \
             CC_AUTO_GATE_PR_ACTIVITY_CMD="$root/gate-act" "$@"
}

# SEED THE STREAK DIRECTLY instead of paying for gate runs whose only job is to
# increment a counter. The increment itself is pinned by O1 (four fires, each
# asserted); every case below that merely NEEDS a streak takes it as a
# PRECONDITION rather than re-deriving it. That is better test design — each
# case then exercises one thing — and it is also the cost fix: measured ABAB
# against dev, the O-block added 32.8 s to this suite, and `bash 4.4` is the
# longest job in the CI band, passing ~1 min inside its ceiling beside three
# jobs that die at theirs (your-org/nexus-code#1474). A test that buys no
# coverage is not free here.
#
# `-since` is deliberately NOT written: `_gate_defer_streak_bump` creates it on
# the next bump, so the AGE bound starts from now and cannot fire in cases that
# are exercising the STREAK cap. Cases testing the age bound (O4, O5) set it
# themselves.
gate_seed_streak() {   # $1=root  $2=streak value
    mkdir -p "$1/monitor/.state/cc-auto-update" 2>/dev/null || true
    printf '%s\n' "$2" > "$1/monitor/.state/cc-auto-update/gate-defer-streak"
}

# O1. Under the cap the proxy arm still vetoes — the bound is a bound, not an
#     off switch. Four fires at cap=5 must all defer and mutate nothing.
ROOT="$WORK/o1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
o1ok=1
for i in 1 2 3 4; do
    rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=5)
    (( rc == 30 )) && gate_unmutated "$ROOT" || o1ok=0
done
(( o1ok == 1 )) && ! grep -q "deployment-gate-defer-override" "$auto/decisions.tsv" \
    && pass "#1492 O1: under the cap a proxy arm still DEFERS (4 fires, nothing bumped, no override row)" \
    || fail "#1492 O1: the bound fired early or the gate mutated below the cap (rc=$rc)"

# O2. At the cap the proxy arm's veto expires. Until 2026-09-12 the DIRECT
#     board-not-quiet arm ran after it and still deferred (the load-bearing
#     "override is not proceed" case). D13 removed the board arms, so the
#     override is now followed by no arm and the gate CLEARS — while the busy
#     windows are still written to the record. The contract "override means
#     this arm's veto expired, evaluation continues" is unchanged; what
#     changed is that nothing remains to continue into. FAILS on the
#     pre-change tree (rc 30 there).
make_gate_pane_stub "$ROOT" busy
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=5 CC_AUTO_RESTART_INLINE=1)
(( rc == 0 )) && gate_applied "$ROOT" \
    && grep -q "deployment-gate-defer-override" "$auto/decisions.tsv" \
    && ! grep -q "board-not-quiet" "$auto/decisions.tsv" \
    && [[ "$(gate_row "$ROOT")" == *"w1=busy"* ]] \
    && pass "D13 O2: an expired PROXY veto CLEARS the gate (rc=0, pin moved) — the busy windows are RECORDED, no board arm defers" \
    || fail "D13 O2: expired proxy veto did not clear, or the record lost the busy windows (rc=$rc): $(gate_row "$ROOT")"

# O3. A busy board ALONE never defers (D13). Until 2026-09-12 this case pinned
#     the opposite — the direct arm was never overridable, so three fires at
#     cap=2 all deferred with no override row. Now three fires with no proxy
#     arm in play must all APPLY: no deferral row, no override row (nothing to
#     override), the busy windows recorded each time. FAILS on the pre-change
#     tree (rc 30 there). The pin is cleared between fires so each is a real
#     apply rather than the already-pinned no-op.
ROOT="$WORK/o3"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" busy
auto="$ROOT/monitor/.state/cc-auto-update"
o3ok=1
for i in 1 2 3; do
    rm -f "$ROOT/monitor/.state/cc-version-local"; : > "$ROOT/calls.log"
    rc=$(gate_run "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=2 CC_AUTO_RESTART_INLINE=1)
    (( rc == 0 )) && gate_applied "$ROOT" && [[ "$(gate_row "$ROOT")" == *"w1=busy"* ]] || o3ok=0
done
(( o3ok == 1 )) \
    && ! grep -q $'\tsafe-deferred\t' "$auto/decisions.tsv" \
    && ! grep -q "deployment-gate-defer-override" "$auto/decisions.tsv" \
    && pass "D13 O3: a busy board alone never defers — 3 fires, 3 applies, busy windows recorded, no deferral and no override row" \
    || fail "D13 O3: a busy board still deferred or the record is wrong (last rc=$rc): $(grep -E 'safe-deferred|defer-override' "$auto/decisions.tsv" | tail -1)"

# O4. The AGE bound trips independently of the streak — a slow fire cadence
#     must not make the bound unreachable. Streak cap disabled (0).
ROOT="$WORK/o4"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=0 CC_AUTO_GATE_DEFER_MAX_AGE_SECONDS=86400)
(( rc == 30 )) || fail "#1492 O4 setup: first fire should defer (rc=$rc)"
# Backdate the streak start past the age bound.
printf '%s\n' "$(( $(date +%s) - 90000 ))" > "$auto/gate-defer-streak-since"
rm -f "$ROOT/monitor/.state/cc-version-local"
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=0 CC_AUTO_GATE_DEFER_MAX_AGE_SECONDS=86400 CC_AUTO_RESTART_INLINE=1)
# THE ASSERTION IS THE OUTCOME, NOT THE ROW. An earlier draft of this case
# checked only that `deployment-gate-defer-override` appeared in decisions.tsv
# — and a mutant whose override RETURNED 1 still wrote that row, so the case
# passed while the veto had not expired at all. That is the same defect this
# worker flagged in #1498's case 13c (assert the property, not a proxy for
# it), committed here in the test written to demonstrate it. The property is
# that the gate CLEARED: rc 0 and the pin actually moved.
(( rc == 0 )) && [[ -f "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q "deployment-gate-defer-override" "$auto/decisions.tsv" \
    && pass "#1492 O4: the AGE bound expires a proxy veto with the streak cap disabled — the gate CLEARED (rc=0, pin moved)" \
    || fail "#1492 O4: a proxy arm held past its age bound (rc=$rc)"

# O5. AN UNREADABLE AGE MUST NOT TRIP THE OVERRIDE. "I could not tell how long
#     this has been blocked" is not "long enough" — the same rule this gate
#     already applies to an unparseable PR timestamp.
ROOT="$WORK/o5"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=0 CC_AUTO_GATE_DEFER_MAX_AGE_SECONDS=1)
printf 'not-an-epoch\n' > "$auto/gate-defer-streak-since"
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=0 CC_AUTO_GATE_DEFER_MAX_AGE_SECONDS=1)
(( rc == 30 )) && gate_unmutated "$ROOT" \
    && ! grep -q "deployment-gate-defer-override" "$auto/decisions.tsv" \
    && pass "#1492 O5: an unreadable streak age does NOT trip the override — it defers (rc=30)" \
    || fail "#1492 O5: 'could not tell' became 'long enough' and opened the hatch (rc=$rc)"

# O6. THE STREAK IS GLOBAL, NOT PER-ARM — pin the consequence, since it is the
#     one that surprises. A streak earned on the RESTART-PATH arm expires the
#     ACTIVE-REVIEW arm on that arm's FIRST EVER fire. Deliberate (the board
#     demonstrably hops between arms and a per-arm counter would never reach a
#     cap) but untested until the w231sk skeptic pass asked for it: a doctrine
#     that is per-arm and a counter that is global is exactly the kind of
#     mismatch that is obvious only once someone writes the cross-arm case.
ROOT="$WORK/o6"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
# Seed the streak to cap-1 as a PRECONDITION; O1 pins that real fires produce it.
gate_seed_streak "$ROOT" 2
o6_pre=$(tr -dc '0-9' < "$auto/gate-defer-streak" 2>/dev/null)
# Now retire that arm and present a DIFFERENT proxy arm (active-review) for the
# first time: no restart-path hit, one PR touched inside the activity window.
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "docs/unrelated.md"\n' > "$ROOT/gate-pr"
chmod +x "$ROOT/gate-pr"
rm -f "$ROOT/monitor/.state/cc-version-local"
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=3 CC_AUTO_RESTART_INLINE=1)
(( rc == 0 )) && [[ -f "$ROOT/monitor/.state/cc-version-local" ]] \
    && grep -q "deployment-gate-defer-override" "$auto/decisions.tsv" \
    && pass "#1492 O6: the streak is GLOBAL — 2 deferrals on the restart-path arm expire the active-review arm on its first fire (pre-streak=$o6_pre, rc=0, pin moved)" \
    || fail "#1492 O6: cross-arm streak behaviour is not what the doctrine says (pre-streak=$o6_pre rc=$rc)"

# O7. A PIN THAT MOVES ENDS THE STREAK, WHICHEVER PATH MOVED IT. `--no-restart`
#     SKIPS the gate, so it also skips _deployment_gate's own streak clear —
#     and since the streak is now the bound's CONTROL INPUT, a stale one makes
#     the NEXT genuine deferral start part-way to its cap and expire a proxy
#     veto early. Latent (0 recorded uses of the flag), which is when it is
#     cheap to close.
ROOT="$WORK/o7"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
gate_seed_streak "$ROOT" 2
[[ -f "$auto/gate-defer-streak" ]] \
    || fail "#1492 O7 setup: expected a streak on record before the --no-restart bump"
rm -f "$ROOT/monitor/.state/cc-version-local"
env $(apply_env "$ROOT") CC_AUTO_TMUX="$ROOT/tmux" bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --no-restart \
    --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
o7rc=$?
# THE ASSERTION IS DELIVERY, NOT THE SIDE EFFECT (w231sk round 2, R6 —
# instance THREE of this family, in the case written to close instance two).
# The first form asserted only `[[ ! -f gate-defer-streak ]]`: it captured
# `o7rc` and never tested it, and never checked the pin. It would have passed
# on a run that cleared the streak and delivered NOTHING — which is exactly the
# code defect R6 also found, the clear running before the pin write.
(( o7rc == 0 )) && [[ -f "$ROOT/monitor/.state/cc-version-local" ]] \
   && [[ ! -f "$auto/gate-defer-streak" ]] \
    && pass "#1492 O7: a --no-restart bump that DELIVERED (rc=0, pin written) clears the streak — the control input cannot go stale on a path that delivered" \
    || fail "#1492 O7: expected rc 0 + pin written + streak cleared; got rc=$o7rc pin=$([[ -f "$ROOT/monitor/.state/cc-version-local" ]] && echo yes || echo NO) streak=$(cat "$auto/gate-defer-streak" 2>/dev/null || echo cleared)"

# O7b. THE OTHER DIRECTION, which is the one the code got wrong: a --no-restart
#      run that FAILS to deliver must LEAVE the streak alone. Before R6 the
#      clear ran on intent, so an install failure wiped a streak representing
#      real consecutive deferrals — safe for the override (a lower streak only
#      delays it) and unsafe for observability, the half that matters here.
ROOT="$WORK/o7b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
gate_seed_streak "$ROOT" 2
o7b_pre=$(tr -dc '0-9' < "$auto/gate-defer-streak" 2>/dev/null)
rm -f "$ROOT/monitor/.state/cc-version-local"
env $(apply_env "$ROOT") CC_AUTO_TMUX="$ROOT/tmux" INSTALL_RC=1 bash "$APPLY" safe \
    --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --no-restart \
    --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
o7brc=$?
o7b_post=$(tr -dc '0-9' < "$auto/gate-defer-streak" 2>/dev/null)
(( o7brc != 0 )) && [[ "$o7b_post" == "$o7b_pre" ]] \
    && pass "#1492 O7b: a --no-restart run that FAILED to deliver (rc=$o7brc) leaves the streak intact ($o7b_pre) — cleared on delivery, not on intent" \
    || fail "#1492 O7b: a failed bump changed the streak ($o7b_pre -> ${o7b_post:-cleared}, rc=$o7brc) — the escalation counter reset having delivered nothing"

# O8. AN UNREACHABLE BOUND MUST BE VISIBLE FROM THE LEDGER ALONE. w231sk's F4
#     was that the cap shipped at a value the recorded streak distribution could
#     never reach, and finding that out required reading the code and the ledger
#     TOGETHER. Defaulting the cap to the alert threshold also means somebody
#     raising the alert to quieten notifications silently pushes the bound out —
#     the fix for "cannot fire" has a setting that makes it not fire. Defended
#     by observability, so the observability is what gets pinned: every deferral
#     row carries the bound's own parameters beside the streak, making
#     "cap unreachable" a one-line comparison in decisions.tsv.
ROOT="$WORK/o8"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=99 CC_AUTO_GATE_DEFER_MAX_AGE_SECONDS=99999)
o8row=$(grep 'safe-deferred' "$auto/decisions.tsv" 2>/dev/null | tail -1)
[[ "$o8row" == *"gate_defer_streak=1"* && "$o8row" == *"defer_cap=99"* \
   && "$o8row" == *"defer_max_age=99999s"* && "$o8row" == *"overridable=1"* ]] \
    && pass "#1492 O8: a deferral row carries the bound's own parameters (streak=1 vs defer_cap=99) — an unreachable cap is visible from decisions.tsv alone" \
    || fail "#1492 O8: the deferral row does not carry defer_cap/defer_max_age/overridable — an unreachable bound is only findable by reading the source. row: $o8row"

# O9. THE CAP'S OWN DEFAULT AND FLOOR — the headline change of two consecutive
#     rounds, and until now exercised by NO test (w231sk round 2, R2: a mutant
#     flipping the default to a literal 99 was noticed by 0 of 277 cases).
#     Both failed shapes are pinned so neither can return:
#       (a) DEFAULT: unset -> 3, calibrated, not a hunch;
#       (b) INDEPENDENCE: the NOTIFICATION threshold must not move the cap —
#           R1, where ALERT=1 collapsed the cap to 1 and expired every proxy
#           veto on its FIRST deferral, i.e. zero delay;
#       (c) FLOOR: a configured 1 is RAISED to 2 and SAYS SO in the row.
ROOT="$WORK/o9a"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
rc=$(gate_run_proxy "$ROOT")
o9row=$(grep 'safe-deferred' "$auto/decisions.tsv" 2>/dev/null | tail -1)
[[ "$o9row" == *"defer_cap=3"* ]] \
    && pass "#1492 O9a: with nothing configured the cap defaults to 3, calibrated against the recorded streak distribution" \
    || fail "#1492 O9a: the default cap is not 3. row: $o9row"

ROOT="$WORK/o9b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_ALERT=1)
o9brow=$(grep 'safe-deferred' "$auto/decisions.tsv" 2>/dev/null | tail -1)
(( rc == 30 )) && gate_unmutated "$ROOT" && [[ "$o9brow" == *"defer_cap=3"* ]] \
    && pass "#1492 O9b (R1): a NOTIFICATION threshold of 1 does NOT move the safety cap — still 3, and the first deferral still DEFERS (rc=30)" \
    || fail "#1492 O9b (R1): the alert threshold moved the cap — asking for more information disabled the veto (rc=$rc). row: $o9brow"

ROOT="$WORK/o9c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"
make_gate_pane_stub "$ROOT" absent; make_gate_restart_pr "$ROOT"
auto="$ROOT/monitor/.state/cc-auto-update"
rc=$(gate_run_proxy "$ROOT" CC_AUTO_GATE_DEFER_STREAK_CAP=1)
o9crow=$(grep 'safe-deferred' "$auto/decisions.tsv" 2>/dev/null | tail -1)
(( rc == 30 )) && [[ "$o9crow" == *"defer_cap=2"* && "$o9crow" == *"defer_cap_clamped=1"* ]] \
    && pass "#1492 O9c: a configured cap of 1 is RAISED to the floor of 2 and the clamp is RECORDED (defer_cap_clamped=1) — clamped loudly, not silently" \
    || fail "#1492 O9c: a cap of 1 was honoured or clamped silently — zero delay is not a bound. row: $o9crow"

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

# ===== live-tree drift assertion (your-org/nexus-code#1002) ===============
#
# THE PROPERTY: no verb records a VERDICT while the live binary disagrees
# with the effective pin. Cause-agnostic by construction — the check reads
# the OUTCOME (`$CLAUDE_BIN --version` against `cc_version_effective`), not
# the path by which the tree drifted. The 2026-08-25 fire reported `block`
# with a gate-RED 2.1.245 sitting in the live node_modules for ~25 s; this
# is the control that would have caught it, however it got there.
#
# FIXTURE NOTE. The default claude stubs are PIN-FOLLOWING (make_root plants
# one at the default CLAUDE_BIN path, make_apply_root at $root/claude), so a
# CONSISTENT tree is the fixture default and every case below BREAKS it
# deliberately. The pre-#1002 default stub was hardcoded to the CANDIDATE,
# which is precisely the drifted shape (binary ahead of the pin) — it would
# have refused every safe case in this file for a fixture reason.
echo "== apply: live-tree drift (#1002) =="

# D1. safe on a DRIFTED tree — the binary reports a version that is neither
#     the pin nor the floor → rc 9, pin untouched, install never ran,
#     last-eval=safe-refused with a live-tree-drift detail (an EXISTING
#     decision token: the #1400 daily surfacing keys on it, so the refusal
#     is nagged rather than silent).
ROOT="$WORK/d1"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "2.1.149 (Claude Code)"\n' > "$ROOT/claude"; chmod +x "$ROOT/claude"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?; auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 9 )) && pass "#1002 D1 safe on a drifted tree (binary 2.1.149, pin 2.1.150) → rc 9" \
    || fail "#1002 D1 rc=$rc: $(tail -2 "$ROOT/out.log")"
pin_untouched && ! grep -q '^install' "$ROOT/calls.log" \
    && pass "#1002 D1 …pin untouched, install never ran" \
    || fail "#1002 D1 the drifted tree was acted on: pin=$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null) calls=$(tr '\n' '|' < "$ROOT/calls.log")"
[[ "$(_cc_update_field "$auto/last-eval" decision 2>/dev/null)" == "safe-refused" ]] \
    && grep -q 'live-tree-drift' "$auto/last-eval" \
    && pass "#1002 D1 …last-eval=safe-refused naming live-tree-drift (the #1400 surfacing sees it)" \
    || fail "#1002 D1 last-eval: $(tr '\n' ' ' < "$auto/last-eval" 2>/dev/null)"
grep -q 'live=2.1.149' "$ROOT/out.log" && grep -q 'effective=2.1.150' "$ROOT/out.log" \
    && pass "#1002 D1 …the refusal names BOTH sides (live= and effective=)" \
    || fail "#1002 D1 diagnostic incomplete: $(grep -i 'drift' "$ROOT/out.log" | head -2)"

# D2. THE INCIDENT SHAPE: the binary is AHEAD of the pin — it already reports
#     the CANDIDATE while the pin still says the floor. A check that asked
#     "is the binary the candidate?" would PASS here; the assertion has to
#     compare against the PIN. This is exactly the polluted 2026-08-25 tree.
ROOT="$WORK/d2"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "2.1.160 (Claude Code)"\n' > "$ROOT/claude"; chmod +x "$ROOT/claude"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 9 )) && pin_untouched && ! grep -q '^install' "$ROOT/calls.log" \
    && pass "#1002 D2 INCIDENT SHAPE: binary already at the candidate, pin at the floor → rc 9, nothing applied" \
    || fail "#1002 D2 the polluted tree was accepted: rc=$rc calls=$(tr '\n' '|' < "$ROOT/calls.log")"

# D3. UNREADABLE binary (no version on stdout) → rc 9 with live=unreadable.
#     "Could not read it" is not "it matches"; the incident window had the
#     symlink ABSENT twice, which is this arm.
ROOT="$WORK/d3"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\nexit 1\n' > "$ROOT/claude"; chmod +x "$ROOT/claude"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 9 )) && grep -q 'live=unreadable' "$ROOT/out.log" \
    && pass "#1002 D3 an unreadable live binary → rc 9, named live=unreadable (never 'matches')" \
    || fail "#1002 D3 rc=$rc: $(grep -i drift "$ROOT/out.log" | head -1)"

# D4. block on a drifted tree → rc 9, NO `block` row, NO last-eval — so the
#     daily guard does NOT skip the candidate (its verdict was never recorded)
#     — and an audit-only `live-tree-drift` row so the refusal is on the record.
ROOT="$WORK/d4"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '#!/usr/bin/env bash\necho "2.1.160 (Claude Code)"\n' > "$ROOT/claude"; chmod +x "$ROOT/claude"
env $(apply_env "$ROOT") bash "$APPLY" block --candidate 2.1.160 --reason "gate RED: something" > "$ROOT/out.log" 2>&1
rc=$?; auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 9 )) && ! grep -q $'\tblock\t' "$auto/decisions.tsv" 2>/dev/null \
   && [[ ! -e "$auto/last-eval" ]] && grep -q $'\tlive-tree-drift\t' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1002 D4 block on a drifted tree → rc 9: no block row, no last-eval, an audit row live-tree-drift"
else
    fail "#1002 D4 rc=$rc rows=$(cut -f3 "$auto/decisions.tsv" 2>/dev/null | tr '\n' ',') last-eval=$([[ -e "$auto/last-eval" ]] && echo present || echo absent)"
fi
_cc_auto_last_eval_skip "$auto" "2.1.160" \
    && fail "#1002 D4 the daily guard skips a candidate whose verdict was never recorded" \
    || pass "#1002 D4 …and the daily guard does NOT skip it: the next fire re-evaluates"

# D5. CONTROL for D4: the identical block call on a CONSISTENT tree records
#     the block (rc 0). Proves D4's refusal is the drift, not the fixture.
ROOT="$WORK/d5"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" block --candidate 2.1.160 --reason "gate RED: something" > "$ROOT/out.log" 2>&1
rc=$?; auto="$ROOT/monitor/.state/cc-auto-update"
(( rc == 0 )) && grep -q $'\tblock\t' "$auto/decisions.tsv" 2>/dev/null \
    && [[ "$(_cc_update_field "$auto/last-eval" decision 2>/dev/null)" == "block" ]] \
    && pass "#1002 D5 CONTROL: the same block on a consistent tree records block (rc 0)" \
    || fail "#1002 D5 control: rc=$rc rows=$(cut -f3 "$auto/decisions.tsv" 2>/dev/null | tr '\n' ',')"

# D6. compat-pr auto on a drifted tree → rc 9, no PR comment posted, no
#     compat-pr-commented row. The fixture root here is make_root's, whose
#     stub sits at the DEFAULT CLAUDE_BIN path (no CC_AUTO_CLAUDE_BIN in
#     compat_env) — so this also proves the default resolution is exercised.
ROOT="$WORK/d6"; make_root "$ROOT" "2.1.150"; : > "$ROOT/calls.log"
make_gh_stub "$ROOT" '[{"number":42,"title":"cc-compat 2.1.160: fix _detect_busy","url":"https://github.com/your-org/nexus-code/pull/42"}]'
printf 'findings\n' > "$ROOT/findings.md"
printf '#!/usr/bin/env bash\necho "2.1.160 (Claude Code)"\n' > "$ROOT/node_modules/.bin/claude"; chmod +x "$ROOT/node_modules/.bin/claude"
env $(compat_env "$ROOT") bash "$APPLY" compat-pr auto --candidate 2.1.160 --findings "$ROOT/findings.md" > "$ROOT/out.log" 2>&1
rc=$?; auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 9 )) && ! grep -q 'comment' "$ROOT/calls.log" \
   && ! grep -q 'compat-pr-commented' "$auto/decisions.tsv" 2>/dev/null \
   && grep -q $'\tlive-tree-drift\t' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1002 D6 compat-pr auto on a drifted tree → rc 9, no PR comment, no compat-pr-commented row"
else
    fail "#1002 D6 rc=$rc calls=$(tr '\n' '|' < "$ROOT/calls.log") rows=$(cut -f3 "$auto/decisions.tsv" 2>/dev/null | tr '\n' ',')"
fi

# D7. THE COMPARISON IS AGAINST THE EFFECTIVE PIN, NOT THE FLOOR. A local pin
#     2.1.155 sits above the 2.1.150 floor; a binary that FOLLOWS the pin is a
#     consistent tree and the bump proceeds (rc 0, pin → 2.1.160); a binary
#     frozen at the FLOOR while the pin says 2.1.155 is a drifted tree (a torn
#     install) → rc 9. Same root shape, one variable.
ROOT="$WORK/d7a"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '2.1.155\n' > "$ROOT/monitor/.state/cc-version-local"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger.md" --changelog-dispositioned 2.1.160=2 > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
    && pass "#1002 D7a a binary matching the LOCAL pin (2.1.155 over floor 2.1.150) is consistent: the bump proceeds (rc 0, pin → 2.1.160)" \
    || fail "#1002 D7a a consistent local-pin tree was refused: rc=$rc $(grep -i drift "$ROOT/out.log" | head -1)"
ROOT="$WORK/d7b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
printf '2.1.155\n' > "$ROOT/monitor/.state/cc-version-local"
printf '#!/usr/bin/env bash\necho "2.1.150 (Claude Code)"\n' > "$ROOT/claude"; chmod +x "$ROOT/claude"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK \
    --changelog-evidence "$ROOT/changelog.md" --changelog-ledger "$ROOT/ledger.md" --changelog-dispositioned 2.1.160=2 > "$ROOT/out.log" 2>&1
rc=$?
(( rc == 9 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.155" ]] \
    && grep -q 'effective=2.1.155' "$ROOT/out.log" \
    && pass "#1002 D7b a binary at the FLOOR under a local pin of 2.1.155 is drift → rc 9, pin left at 2.1.155, effective= names the pin" \
    || fail "#1002 D7b rc=$rc pin=$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null) $(grep -i drift "$ROOT/out.log" | head -1)"

# D8. THE EXIT CODE IS IN THE HEADER'S VOCABULARY, beside the code the
#     evaluator prompt tells the reader to branch on. A code that exists in
#     the dispatch and not in the table is a code nobody can act on.
grep -qE '^#   9   refused: LIVE TREE DRIFT' "$APPLY" \
    && pass "#1002 D8 exit 9 is documented in apply.sh's exit-code table" \
    || fail "#1002 D8 exit 9 missing from the header vocabulary"
grep -qF 'Exit 9' "$MONITOR_DIR/cc-auto-update-prompt.md" \
    && pass "#1002 D8 …and the evaluator prompt tells the reader what an exit 9 means" \
    || fail "#1002 D8 the prompt template does not mention exit 9"

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
    # HEAD just moved off the empty commit make_apply_root created, so the
    # gate log's tree stamp is now stale. Re-stamp, or #1259's tree-mismatch
    # check refuses every case below for a fixture reason (measured: 6 of
    # them).
    stamp_gate_log "$root"
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
    # lacked the fix the WARN was about. Re-affirmed under your-org/nexus-code
    # #1529 (w241sk F3): measure and command name the SAME configured ref,
    # and the advisory names it as the operator's monitor.integration_branch.
    if grep -q 'commits behind origin/dev' <<<"$out" \
       && grep -q 'pull --ff-only origin dev' <<<"$out" \
       && grep -q 'monitor.integration_branch' <<<"$out" \
       && ! grep -q 'origin/main' <<<"$out"; then
        pass "WARN + remediation name origin/dev, the ref actually measured, as monitor.integration_branch"
    fi
    # w241sk D4: the fixture root is `git init` (master) while the measured
    # branch is dev, so the checked-out-branch mismatch NOTE must fire — and
    # it must prescribe alignment, never a checkout.
    _g5a_head=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ "$_g5a_head" != "dev" ]] \
       && grep -q "checked out on $_g5a_head, not dev" <<<"$out" \
       && grep -q 'align monitor.integration_branch' <<<"$out" \
       && ! grep -q 'git checkout' <<<"$out"; then
        pass "#1529 mismatch NOTE fires (HEAD=$_g5a_head, measured dev) and prescribes no checkout"
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
    # THE DIRECTIVE, PINNED (your-org/nexus-code#1475): five commits behind
    # the integration branch and the bump PROCEEDS. Staleness is recorded
    # beside the verdict, never a reason to defer or refuse — "the update
    # should not depend on nexus-code being the latest version". Asserted on
    # the outcome row, not on the absence of a defer: a run that died before
    # either would pass an absence check.
    if grep -q $'\tsafe-bumped' "$auto/decisions.tsv" 2>/dev/null \
       && ! grep -q $'\tsafe-deferred\t' "$auto/decisions.tsv" 2>/dev/null; then
        pass "#1475: 5 behind origin/dev and the bump PROCEEDED — clone freshness is recorded, never gated on"
    else
        fail "#1475: a stale clone deferred or refused the bump; rows: $(grep -E 'safe-(bumped|deferred|refused)' "$auto/decisions.tsv" 2>/dev/null | cut -f3 | tr '\n' ' ')"
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
    # The measured branch reaches the row, the WARN and the deploy command
    # alike (your-org/nexus-code#1529: the same ref, never a literal).
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

# ================= #1259: a verdict carries its subject =================
#
# A gate result is a property of (candidate x checkout). Every artefact the
# routine wrote attributed it to the candidate ALONE, so on 2026-09-01 a
# clone ninety minutes behind the #1214 detector fix produced a RED that was
# filed as "2.1.252 STILL omits the trust dialog's numbered option rows" —
# false, against a good release, with a five-minute margin. `decisions.tsv`,
# `last-eval` and the issue comment all carry the same shape of claim and
# none of them named a tree, so it is indistinguishable in the audit trail
# from the three genuine reds that preceded it.
#
# THE POSITIVE CONTROL FOR THIS WHOLE SECTION IS THE REST OF THE SUITE: every
# green `safe` case above now passes a gate log whose stamp matches its root,
# so "the tree check refuses everything" would redden ~20 cases, not zero.
echo "--- #1259 tree attribution ---"

_restamp() {   # <root> <head-or-UNATTRIBUTABLE|none>
    # Split, NOT `local root="$1" ... log="$root/gate.log"`: this suite runs
    # under `set -u` and the initializers of one `local` are expanded before
    # the names are created, so `$root` there reads the (unset) enclosing
    # scope and aborts. The same trap is documented at `make_gate_clone`.
    local root="$1"
    local what="$2"
    local log="$root/gate.log"
    { grep -v '^=== gated-tree: ' "$log" 2>/dev/null || true; } > "$log.t"
    case "$what" in
        none) : ;;
        UNATTRIBUTABLE)
            printf '=== gated-tree: UNATTRIBUTABLE reason=not_a_git_repo repo=%s ===\n' "$root" >> "$log.t" ;;
        *)  printf '=== gated-tree: head=%s ref=fixture dirty=0 dirty_tracked=0 untracked=0 subject_path=monitor/pane-state.sh subject_blob=%s ===\n' \
                "$what" "0000000000000000000000000000000000000000" >> "$log.t" ;;
    esac
    mv -f "$log.t" "$log"
}

# (t1) A GREEN measured in a DIFFERENT tree does not license this clone's
#      bump. This is the 2026-09-01 worktree GREEN, which the operator
#      declined by hand; here it is encoded.
ROOT="$WORK/t1259a"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
_restamp "$ROOT" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) \
    > "$ROOT/out.log" 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 3 )) && grep -q 'the gate measured tree' "$ROOT/out.log" \
   && grep -q 'gate-evidence:tree-mismatch' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259: a green about a DIFFERENT tree is refused, and the row names WHICH check"
else
    fail "#1259 tree-mismatch: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi
[[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "#1259 …and the pin was NOT written" \
    || fail "#1259: the pin moved on a green about another tree"

# (t1448) A gate log with a tree stamp but NO GEOMETRY stamp is refused on the
#      bump path (your-org/nexus-code#1448): for a 14-fire run the harness never
#      rendered production's `tui: fullscreen` and no log could say so. The
#      fixture's `binary-default/unresolved` stamp is a valid stamp (the
#      CONTROL: it bumps and the attribution names the mode).
ROOT="$WORK/t1448a"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
sed -i '/^=== gated-tui: /d' "$ROOT/gate.log"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) \
    > "$ROOT/out.log" 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 3 )) && grep -q 'gate-evidence:gated-tui-stamp-missing' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1448: gate evidence without a geometry stamp is REFUSED on the bump path"
else
    fail "#1448 tui-stamp-missing: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi
[[ ! -e "$ROOT/monitor/.state/cc-version-local" ]] \
    && pass "#1448 …and the pin was NOT written" \
    || fail "#1448: the pin moved on evidence of unknown geometry"
ROOT="$WORK/t1448b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) \
    > "$ROOT/out.log" 2>&1
rc=$?
if (( rc == 0 )) && grep -q 'tui=binary-default (source=unresolved' "$ROOT/out.log" "$ROOT/monitor/.state/cc-auto-update/apply.log" 2>/dev/null; then
    pass "#1448 CONTROL: a stamped log bumps, and the attribution records the geometry it measured"
else
    fail "#1448 control: rc=$rc; attribution line: $(grep -m1 'gate evidence attributed' "$ROOT/out.log" "$ROOT/monitor/.state/cc-auto-update/apply.log" 2>/dev/null | cut -c1-200)"
fi

# (t2) A gate log with NO tree stamp cannot be attributed at all. Fails
#      CLOSED: this is the only path that writes the pin.
ROOT="$WORK/t1259b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
_restamp "$ROOT" none
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) \
    > "$ROOT/out.log" 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 3 )) && grep -q 'gate-evidence:tree-stamp-missing' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259: an unstamped gate log is refused (it cannot be attributed to a checkout)"
else
    fail "#1259 tree-stamp-missing: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# (t3) THE THIRD OUTCOME on the bump path: the gate said it could not
#      establish which tree it gated. Distinct reason, distinct row.
ROOT="$WORK/t1259c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
_restamp "$ROOT" UNATTRIBUTABLE
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) \
    > "$ROOT/out.log" 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 3 )) && grep -q 'gate-evidence:tree-unattributable' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259: an UNATTRIBUTABLE gate is refused under its own reason, not folded into 'red'"
else
    fail "#1259 tree-unattributable: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# (t4) THE BLOCK PATH — the one that produced the false block. A block with
#      no gate log at all is still recorded, and is now ATTRIBUTABLE: the row
#      names the tree the verdict was formed on.
ROOT="$WORK/t1259d"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" block --candidate 2.1.160 \
    --reason "trust dialog rows still absent" > "$ROOT/out.log" 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
row=$(grep $'\tblock\t' "$auto/decisions.tsv" 2>/dev/null | tail -1)
if (( rc == 0 )) && [[ "$row" == *"live_head="* ]] \
   && grep -qE 'live_head=[0-9a-f]{40}' <<<"$row"; then
    pass "#1259: a block row now names the tree the verdict was formed on"
else
    fail "#1259 block attribution: rc=$rc row=$row"
fi
if [[ "$row" == *"drift="* && "$row" == *"integration_branch="* ]]; then
    pass "#1259 …and carries the staleness trichotomy + the branch measured"
else
    fail "#1259 block row lacks drift/branch: $row"
fi

# (t5) A BLOCK WHOSE GATE LOG CANNOT NAME ITS TREE IS NOT A CANDIDATE
#      VERDICT. Recorded under its OWN decision so no later reader — and no
#      next fire reading last-eval — can mistake it for one. rc 3, and
#      `block` must NOT appear.
ROOT="$WORK/t1259e"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
_restamp "$ROOT" UNATTRIBUTABLE
env $(apply_env "$ROOT") bash "$APPLY" block --candidate 2.1.160 \
    --reason "gate RED 6/7" --gate-evidence "$ROOT/gate.log" > "$ROOT/out.log" 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 3 )) && grep -q $'\tblock-unattributable\t' "$auto/decisions.tsv" 2>/dev/null \
   && ! grep -q $'\tblock\t' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259: an unattributable gate RED is NOT recorded as a candidate block"
else
    fail "#1259 block-unattributable: rc=$rc rows=$(cut -f3 "$auto/decisions.tsv" 2>/dev/null | tr '\n' ',')"
fi
if [[ "$(sed -n 's/^decision=//p' "$auto/last-eval" 2>/dev/null)" == "block-unattributable" ]]; then
    pass "#1259 …and last-eval — what the NEXT fire reads — says so too"
else
    fail "#1259 last-eval still claims a candidate verdict: $(cat "$auto/last-eval" 2>/dev/null | tr '\n' ' ')"
fi

# (t6) A BLOCK MEASURED IN THIS CLONE is labelled as such — the distinction
#      the false block had no way to express.
ROOT="$WORK/t1259f"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") bash "$APPLY" block --candidate 2.1.160 \
    --reason "gate RED 6/7" --gate-evidence "$ROOT/gate.log" > "$ROOT/out.log" 2>&1
rc=$?
auto="$ROOT/monitor/.state/cc-auto-update"
row=$(grep $'\tblock\t' "$auto/decisions.tsv" 2>/dev/null | tail -1)
if (( rc == 0 )) && [[ "$row" == *"attribution=gated-tree-is-live-clone"* ]]; then
    pass "#1259: a block gated IN this clone is recorded as gated-tree-is-live-clone"
else
    fail "#1259 block in-clone attribution: rc=$rc row=$row"
fi
# ...and the DIFFERING case is distinguishable from it. Same verb, same
# reason, only the gated tree varies — which is the variable the 2026-09-01
# audit trail could not express.
_restamp "$ROOT" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
env $(apply_env "$ROOT") bash "$APPLY" block --candidate 2.1.160 \
    --reason "gate RED 6/7" --gate-evidence "$ROOT/gate.log" > "$ROOT/out2.log" 2>&1
row2=$(grep $'\tblock\t' "$auto/decisions.tsv" 2>/dev/null | tail -1)
if [[ "$row2" == *"attribution=gated-tree-DIFFERS-from-live-clone"* ]] \
   && grep -q 'the drift figures above describe the LIVE CLONE' "$ROOT/out2.log"; then
    pass "#1259: a block gated in ANOTHER tree is distinguishable in the row, and says whose drift it reports"
else
    fail "#1259 block differing-tree attribution: row=$row2"
fi

# ---- REACHABILITY FROM THE PRODUCTION CALLER --------------------------
#
# Every case above passes --gate-evidence. THE PRODUCTION CALLER DOES NOT:
# monitor/cc-auto-update-prompt.md invokes
#
#     cc-auto-update-apply.sh block --candidate X --reason "..."
#
# and nothing else. So the first cut of this fix had every attribution arm
# UNREACHABLE IN PRODUCTION — measured, same unattributable log, the flag the
# only variable: production shape rc 0 recorded `block`; test shape rc 3
# recorded `block-unattributable`. A guard proven only under a flag nobody
# passes is proven in a world nobody runs, which is this repo's own dominant
# defect class one layer out from where it was looked for.
#
# These cases therefore use THE PRODUCTION SHAPE — no --gate-evidence — and
# are the only ones here that establish the fix does anything at all.

# _prod_block <root> <candidate> <reason> — the prompt's exact command.
_prod_block() {
    local r="$1"
    local c="$2"
    local why="$3"
    env $(apply_env "$r") bash "$APPLY" block --candidate "$c" --reason "$why" \
        > "$r/prod.log" 2>&1
}

# (t7) THE PRODUCTION SHAPE reaches the third outcome, via the conventional
#      gate-log path the SAME prompt tees to.
ROOT="$WORK/t1259g"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
mkdir -p "$auto"
{ printf 'gating 2.1.160\n'
  printf '=== gated-tree: UNATTRIBUTABLE reason=not_a_git_repo repo=%s ===\n' "$ROOT"
  printf '=== GATE RED (6 passed / 1 failed / 0 skipped) ===\n'
} > "$auto/gate-2.1.160.log"
_prod_block "$ROOT" 2.1.160 "2.1.160 STILL omits the trust dialog rows"
rc=$?
if (( rc == 3 )) && grep -q $'\tblock-unattributable\t' "$auto/decisions.tsv" 2>/dev/null \
   && ! grep -q $'\tblock\t' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259 PRODUCTION SHAPE: an unattributable gate reaches the third outcome with NO --gate-evidence"
else
    fail "#1259 production shape unreachable: rc=$rc rows=$(cut -f3 "$auto/decisions.tsv" 2>/dev/null | tr '\n' ',')"
fi
if grep -q 'gate_evidence=derived' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259 …and the row says the evidence was DERIVED, not supplied"
else
    fail "#1259 row does not record the evidence source: $(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# (t8) NEGATIVE CONTROL for (t7). Same command, same root, conventional log
#      REMOVED. It must fall back to an ordinary attributable block at rc 0 —
#      which proves (t7) fires because of the DERIVATION and not because the
#      production shape refuses everything. Without this, a cmd_block that
#      simply always exited 3 would satisfy (t7).
rm -f "$auto/gate-2.1.160.log" "$auto/decisions.tsv" "$auto/last-eval"
_prod_block "$ROOT" 2.1.160 "changelog surface unresolved, no gate involved"
rc=$?
if (( rc == 0 )) && grep -q $'\tblock\t' "$auto/decisions.tsv" 2>/dev/null \
   && grep -q 'gate_evidence=none' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259 CONTROL: with no gate log the production shape still records an ordinary block (rc 0)"
else
    fail "#1259 control: a gate-less block no longer works: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# (t9) A STALE conventional log is NOT this run's evidence. Attributing
#      today's block to yesterday's gate would be a fresh instance of the
#      defect being fixed, so "too old" is its own outcome and never
#      collapses into "there is none".
ROOT="$WORK/t1259h"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
mkdir -p "$auto"
{ printf 'gating 2.1.160\n'
  printf '=== gated-tree: UNATTRIBUTABLE reason=not_a_git_repo repo=%s ===\n' "$ROOT"
} > "$auto/gate-2.1.160.log"
touch -d '@1' "$auto/gate-2.1.160.log" 2>/dev/null || touch -t 197001020000 "$auto/gate-2.1.160.log"
_prod_block "$ROOT" 2.1.160 "some reason"
rc=$?
if (( rc == 0 )) && grep -q 'attribution=gate-log-stale' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259: a STALE conventional gate log is named as stale, not used and not silently ignored"
else
    fail "#1259 stale derived log: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# (t10) The derived path is CANDIDATE-KEYED — another version's gate log must
#       not be picked up. Same fixture, log named for a different candidate.
ROOT="$WORK/t1259i"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"
mkdir -p "$auto"
{ printf 'gating 2.1.999\n'
  printf '=== gated-tree: UNATTRIBUTABLE reason=not_a_git_repo repo=%s ===\n' "$ROOT"
} > "$auto/gate-2.1.999.log"
_prod_block "$ROOT" 2.1.160 "some reason"
rc=$?
if (( rc == 0 )) && grep -q 'gate_evidence=none' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1259: the derived gate log is candidate-keyed — another version's run is not adopted"
else
    fail "#1259 candidate-keying: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi


echo
echo "=== #1320: TRACKED dirtiness, not any dirtiness ==="

# THE DEFECT. `_gate_stamp_tree` computed one `dirty=` from a bare
# `git status --porcelain`, WHICH COUNTS UNTRACKED FILES, and this script
# refused any bump on it. A live primary clone is never free of untracked
# files, so the bump path was unreachable on the only tree this function
# accepts evidence from — measured on this nexus at `dev` 4ab4ed7a: 21
# untracked entries, 0 tracked modifications.

# (t20) FAIL CLOSED ON PRE-SPLIT EVIDENCE. A gate log written before the split
#       carries `dirty=0` and NO `dirty_tracked=`, so it never measured whether
#       the TRACKED tree matched head. Falling back to `dirty=` would re-import
#       the deadlock; reading an absent field as 0 would accept a stamp that
#       measured nothing. It REFUSES.
ROOT="$WORK/t1320legacy"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
stamp_gate_log "$ROOT"
sed -i 's/ dirty_tracked=0 untracked=0//' "$ROOT/gate.log"
grep -q 'dirty_tracked' "$ROOT/gate.log" \
    && fail "#1320 legacy fixture still carries dirty_tracked — the case below would prove nothing"
# CC_AUTO_RESTART_INLINE=1 here purely so this case and its potency control
# (t21) differ in EXACTLY ONE variable -- the dirty_tracked field (#1320
# skeptic Q4). Inert on a refusal path, which returns before any restart
# hand-off; t21 needs it to reach rc 0.
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
if (( rc == 3 )) && grep -q 'gate-evidence:gated-tree-dirty-field-missing' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1320 FAIL CLOSED: pre-split gate evidence (no dirty_tracked=) is REFUSED, not read as clean"
else
    fail "#1320 pre-split evidence must refuse: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# (t21) POTENCY for t20: the SAME fixture WITH the field clears this arm.
ROOT="$WORK/t1320ok"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
stamp_gate_log "$ROOT"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && ! grep -q 'gated-tree-dirty' "$auto/decisions.tsv" 2>/dev/null; then
    pass "POTENCY #1320: the same fixture WITH dirty_tracked=0 clears the arm (t20 isolated the field)"
else
    fail "#1320 potency: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# (t22) A TRACKED modification still refuses — the arm did not become inert.
#       "A gate observed only clearing is unproven", and the failure direction
#       here is PERMITS A BUMP, so this arm is the one that must be exercised.
ROOT="$WORK/t1320dirty"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
stamp_gate_log "$ROOT"
sed -i 's/ dirty_tracked=0 / dirty_tracked=1 /' "$ROOT/gate.log"
# MUTATION-APPLIED GUARD (#1320 skeptic Q2). t20 and t23 both assert their
# fixture landed; this arm did not -- and it is the arm whose failure
# direction is PERMITS A BUMP. A fixture that silently failed to apply
# would leave dirty_tracked=0 and this case would pass for the wrong reason.
grep -q ' dirty_tracked=1 ' "$ROOT/gate.log" \
    || fail "#1320 t22 fixture not applied -- the case below would prove nothing"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
# EXACT match, not a PREFIX (#1320 skeptic Q2): `gate-evidence:gated-tree-dirty`
# is a proper prefix of `gate-evidence:gated-tree-dirty-field-missing`, so the
# loose form was satisfied by EITHER refusal code.
if (( rc == 3 )) && grep -qE 'gate-evidence:gated-tree-dirty([^-]|$)' "$auto/decisions.tsv" 2>/dev/null; then
    pass "#1320 a TRACKED modification (dirty_tracked=1) still REFUSES the bump"
else
    fail "#1320 tracked-dirty must refuse: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# (t23) THE DEADLOCK CASE, end to end. `dirty=1 untracked=21 dirty_tracked=0`
#       — the live primary clone's exact shape — must PROCEED. Before #1320
#       this refused, always, on every live clone.
ROOT="$WORK/t1320untracked"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
auto="$ROOT/monitor/.state/cc-auto-update"; mkdir -p "$auto"
stamp_gate_log "$ROOT"
sed -i 's/ dirty=0 dirty_tracked=0 untracked=0 / dirty=1 dirty_tracked=0 untracked=21 /' "$ROOT/gate.log"
grep -q 'dirty=1 dirty_tracked=0 untracked=21' "$ROOT/gate.log" \
    || fail "#1320 untracked fixture not applied — the case below would prove nothing"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 \
    --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) >/dev/null 2>&1
rc=$?
if (( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]]; then
    pass "#1320 THE DEADLOCK: dirty=1 untracked=21 dirty_tracked=0 → the bump PROCEEDS (was unreachable)"
else
    fail "#1320 untracked-only tree still blocks the bump: rc=$rc row=$(tail -1 "$auto/decisions.tsv" 2>/dev/null)"
fi

# ===== your-org/nexus-code#1438: the safe-verb flags, honoured AROUND the verb too =====
echo "== #1438: --no-restart / --no-orchestrator-restart × gate × reconcile × pin =="
# (1) gate × --no-restart: a fixture that defers the bare verb at rc 30 must
#     land the pin under --no-restart, because nothing restarts and the gate is
#     skipped. The deferring input is a LIVE RESTART-PATH PR (the D13 change of
#     2026-09-12 removed the live-window count arm this case used to lean on —
#     3 agents > max 2 no longer defers anything, so it can no longer tell a
#     skipped gate from a cleared one).
h1438_pr_stubs() {   # $1=root — one open PR touching a GATE_RESTART_PATHS file, touched now
    printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "monitor/watcher/main.sh"\n' > "$1/h1438-pr"
    printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" 991 "$(date -Is)"\n' > "$1/h1438-act"
    chmod +x "$1/h1438-pr" "$1/h1438-act"
}
ROOT="$WORK/h1438a"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"; make_gate_pane_stub "$ROOT" absent
h1438_pr_stubs "$ROOT"
env $(apply_env "$ROOT") CC_AUTO_TMUX="$ROOT/tmux" CC_AUTO_GATE_PR_CMD="$ROOT/h1438-pr" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/h1438-act" \
    bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) --no-restart > "$ROOT/out.log" 2>&1
rc=$?; auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )) && [[ "$(cat "$ROOT/monitor/.state/cc-version-local" 2>/dev/null)" == "2.1.160" ]] \
   && grep -q "safe-bumped-no-restart" "$auto/decisions.tsv"; then
    pass "#1438 gate × --no-restart: a live restart-path PR no longer defers — pin written, outcome no-restart (the bare verb: rc 30, no pin)"
else
    fail "#1438 gate × --no-restart still deferred (rc=$rc): $(tail -2 "$ROOT/out.log")"
fi
# (2) reconcile × --no-restart: a hold is written, so the every-tick reconcile
#     will NOT re-fire the declined hand-off.
if [[ -f "$auto/restart-hold" ]] && grep -q '^until_version=2.1.160$' "$auto/restart-hold"; then
    pass "#1438 --no-restart writes restart-hold until_version=2.1.160"
else
    fail "#1438 --no-restart wrote no hold: $(cat "$auto/restart-hold" 2>/dev/null)"
fi
if _cc_auto_restart_hold_active "$auto" 2.1.160; then
    pass "#1438 …and the reconcile's own predicate reads it as ACTIVE for the candidate"
else
    fail "#1438 hold present but _cc_auto_restart_hold_active says inactive"
fi
grep -q 'restart-hold written' "$ROOT/out.log" && pass "#1438 …and the note says the reconcile is held (not merely 'agents keep their binary')" \
    || fail "#1438 note does not mention the hold: $(grep 'safe: --no-restart' "$ROOT/out.log" | cut -c1-160)"
grep -q 'watcher-restart' "$ROOT/calls.log" && fail "#1438 --no-restart restarted the watcher" || pass "#1438 --no-restart: no watcher restart ran"
# (3) gate × --no-orchestrator-restart: the watcher restart still runs, so the
#     gate STAYS — same live restart-path PR, still rc 30, no pin.
ROOT="$WORK/h1438b"; make_apply_root "$ROOT" "2.1.150" "2.1.160"; make_gate_tmux "$ROOT"; make_gate_pane_stub "$ROOT" absent
h1438_pr_stubs "$ROOT"
env $(apply_env "$ROOT") CC_AUTO_TMUX="$ROOT/tmux" CC_AUTO_GATE_PR_CMD="$ROOT/h1438-pr" CC_AUTO_GATE_PR_ACTIVITY_CMD="$ROOT/h1438-act" \
    bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) --no-orchestrator-restart > "$ROOT/out.log" 2>&1
rc=$?
if (( rc == 30 )) && [[ ! -f "$ROOT/monitor/.state/cc-version-local" ]]; then
    pass "#1438 gate × --no-orchestrator-restart: the gate STAYS (rc 30, no pin) — a watcher restart is still a restart"
else
    fail "#1438 gate × --no-orchestrator-restart wrong (rc=$rc)"
fi
# (4) pin-absent × --no-orchestrator-restart: the decision is taken ABOVE the
#     session-pin pre-flight, so a nexus with no orchestrator pin gets rc 0 and
#     an outcome saying the hand-off was DECLINED — not 21 'restart aborted'.
ROOT="$WORK/h1438c"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
rm -f "$ROOT/monitor/.state/orchestrator-session-id"
env $(apply_env "$ROOT") bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) --no-orchestrator-restart > "$ROOT/out.log" 2>&1
rc=$?; auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )) && grep -q "safe-bumped-no-orch-restart" "$auto/decisions.tsv" && ! grep -q "restart-aborted" "$auto/decisions.tsv"; then
    pass "#1438 pin-absent × --no-orchestrator-restart: rc 0, outcome 'declined' (was rc 21 'restart aborted stale-pin')"
else
    fail "#1438 pin-absent × --no-orchestrator-restart: rc=$rc rows=$(cut -f1-4 "$auto/decisions.tsv" 2>/dev/null | tail -2 | tr '\n' ' ')"
fi
grep -q 'watcher-restart' "$ROOT/calls.log" && pass "#1438 …and the watcher restart DID run first" || fail "#1438 --no-orchestrator-restart skipped the watcher restart"
[[ -f "$auto/restart-hold" ]] && grep -q '^until_version=2.1.160$' "$auto/restart-hold" \
    && pass "#1438 --no-orchestrator-restart writes the hold too" || fail "#1438 --no-orchestrator-restart wrote no hold"
# (5) CONTROL: the bare verb writes NO hold (its own restart is the release).
ROOT="$WORK/h1438d"; make_apply_root "$ROOT" "2.1.150" "2.1.160"
env $(apply_env "$ROOT") CC_AUTO_RESTART_INLINE=1 bash "$APPLY" safe --candidate 2.1.160 --gate-evidence "$ROOT/gate.log" --surfaces-clear $SURF_OK $(cl_ok) > "$ROOT/out.log" 2>&1
rc=$?; auto="$ROOT/monitor/.state/cc-auto-update"
if (( rc == 0 )) && [[ ! -f "$auto/restart-hold" ]]; then
    pass "#1438 CONTROL: the bare safe verb still restarts and writes NO hold"
else
    fail "#1438 CONTROL: bare safe rc=$rc hold=$([[ -f "$auto/restart-hold" ]] && echo present || echo absent)"
fi


printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
