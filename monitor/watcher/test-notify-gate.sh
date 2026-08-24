#!/usr/bin/env bash
# test-notify-gate.sh — severity + cooldown gate for the terminal bell
# (monitor/notifywrap/sandbox-notify).
#
# Both-directions suite. The cases that pin the REGRESSION — T2 (infra class),
# T7 (test-harness ancestry) and T8 (NEXUS_NOTIFY_QUIET) — all FAIL against the
# v1 wrapper on `dev`, which gated solely on `NEXUS_WORKER_WINDOW` +
# the literal string "Needs attention" and therefore passed every
# `cc-auto-update: …` alert straight through. That is the gap that produced the
# measured ~3.4 bells/second flood on 2026-07-24.
#
# HERMETIC. The real `sandbox-notify` is replaced by an OBSERVER on PATH that
# appends to a log instead of ringing; cooldown/decision state is redirected to
# a temp dir via NEXUS_NOTIFY_STATE_DIR. Nothing rings the operator's tmux and
# nothing outside $WORK is written.
#
# your-org/nexus-code#256 guard: re-exec with NEXUS_ROOT unset so the fixtures
# cannot be silently served by the operator's real tree.

set -uo pipefail

if [[ -z "${_NOTIFY_GATE_TEST_REEXEC:-}" ]]; then
    export _NOTIFY_GATE_TEST_REEXEC=1
    exec env -u NEXUS_ROOT -u NEXUS_LOCALS -u NEXUS_STATE_DIR \
        -u NEXUS_WORKER_WINDOW -u NEXUS_ORCHESTRATOR_WINDOW \
        -u NEXUS_NOTIFY_QUIET \
        bash "${BASH_SOURCE[0]}" "$@"
fi

. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_dir/../.." && pwd)
GATE="$REPO_ROOT/monitor/notifywrap/sandbox-notify"
PERM_HOOK="$REPO_ROOT/monitor/hooks/notify-permission.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

OBS="$WORK/obs"; mkdir -p "$OBS"
HITS="$WORK/hits.log"
cat > "$OBS/sandbox-notify" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HITS"
EOF
chmod +x "$OBS/sandbox-notify"

# Fresh state dir per case ⇒ cooldowns start cold unless a case wants otherwise.
_fresh_state() {
    STATE="$WORK/state-$1"
    rm -rf "$STATE"; mkdir -p "$STATE"
}

# ring <label> <msg> [env assignments…] → echoes "RANG" or "silent"
# Incident-window coalescing (round 2) is OFF by default here so the per-class
# cooldown cases below test class independence in isolation; the cascade cases
# (T-CASCADE) set NEXUS_NOTIFY_INCIDENT_WINDOW explicitly.
_ring() {
    local before after
    before=$(wc -l < "$HITS" 2>/dev/null || echo 0)
    env PATH="$OBS:$PATH" \
        NEXUS_NOTIFY_STATE_DIR="$STATE" \
        NEXUS_NOTIFY_ANCESTRY_SCAN="${ANCESTRY:-0}" \
        NEXUS_NOTIFY_INCIDENT_WINDOW="${INCIDENT:-0}" \
        "${@:2}" \
        bash "$GATE" "$1" >/dev/null 2>&1
    after=$(wc -l < "$HITS" 2>/dev/null || echo 0)
    if (( after > before )); then echo "RANG"; else echo "silent"; fi
}

# Last real bell text (for digest-content assertions).
_last_bell() { tail -1 "$HITS" 2>/dev/null || true; }

_verdicts() { cat "$STATE/notify-decisions.jsonl" 2>/dev/null || true; }

: > "$HITS"

# ─── T1: the agent-sandbox hook default is class-suppressed for EVERY agent ──
# v1 suppressed this only when NEXUS_WORKER_WINDOW was set, leaving the
# orchestrator ringing on every turn-end. Both must now be silent.
_fresh_state t1
assert_eq "T1: worker idle default is suppressed" \
    "$(_ring 'Needs attention' NEXUS_WORKER_WINDOW=w1)" "silent"
assert_eq "T1: ORCHESTRATOR idle default is suppressed too" \
    "$(_ring 'Needs attention' NEXUS_ORCHESTRATOR_WINDOW=orchestrator)" "silent"
assert_contains "T1: recorded as a class suppression" \
    "$(_verdicts)" '"class":"agent-default","verdict":"suppress-class"'

# ─── T2: infra chatter rings ONCE, then is cooled down ───────────────────────
# THE REGRESSION CASE. Every one of these passed v1's gate unconditionally.
_fresh_state t2
# NB: plain "applied"/"released"/"functional check stale" stay `infra`; a
# "restart aborted" is now `failure` (round-2 promotion, tested in T2h), so it
# is deliberately not used here as an infra probe.
assert_eq "T2: first cc-auto-update alert rings" \
    "$(_ring 'cc-auto-update: 2.1.160 applied')" "RANG"
assert_eq "T2: second is cooled down" \
    "$(_ring 'cc-auto-update: 2.1.161 applied')" "silent"
assert_eq "T2: third is cooled down" \
    "$(_ring 'cc-auto-update: restart-hold released')" "silent"
assert_eq "T2: a watcher: alert shares the infra cooldown" \
    "$(_ring 'watcher: functional check stale (x)')" "silent"
assert_contains "T2: cooldown suppressions are recorded" \
    "$(_verdicts)" '"class":"infra","verdict":"suppress-cooldown"'

# ─── T2b: a routine infra ping must NOT mask a one-shot serious failure ──────
# THE SKEPTIC FINDING on PR #560 (inverted-risk false-negative). Before the
# `failure` class existed, the serious cc-auto-update / watcher outcomes shared
# the 1800 s `infra` bucket with routine chatter, so a "reconciling" ping
# emitted seconds earlier in the same update cycle silenced the FAILED/
# version-split/VIOLATED outcome for 30 min — and those branches `exit`
# immediately, so the masked bell was LOST, never re-emitted.
_fresh_state t2b
# Round 2: the routine "reconciling" ping is DIGEST-ONLY — it never fires its own
# bell (it is captured to the batch), so it cannot even compete with the failure.
assert_eq "T2b: a routine reconciling ping does NOT ring (digest-only)" \
    "$(_ring 'cc-auto-update: on old binary — reconciling')" "silent"
assert_contains "T2b: …it was captured as routine, not dropped" \
    "$(_verdicts)" '"class":"routine","verdict":"batch-routine"'
assert_eq "T2b: a one-shot FAILED in the SAME cycle rings (never masked)" \
    "$(_ring 'cc-auto-update: watcher restart FAILED — manual: svc.sh restart')" "RANG"
assert_contains "T2b: it was classed as failure" \
    "$(_verdicts)" '"class":"failure","verdict":"ring"'
# version-split / VIOLATED / rolled-back / needs-attention all reach `failure`.
_fresh_state t2c
assert_eq "T2c: version-split rings"  "$(_ring 'cc-auto-update: workspace is version-split')" "RANG"
_fresh_state t2d
assert_eq "T2d: VIOLATED-pin rings"   "$(_ring 'cc-auto-update: restart VIOLATED the pin')" "RANG"
_fresh_state t2e
assert_eq "T2e: rolled-back rings"    "$(_ring 'cc-auto-update: install FAILED; pin rolled back')" "RANG"
# …but a genuine BURST of the SAME failure still collapses to one bell.
_fresh_state t2f
assert_eq "T2f: first failure rings"  "$(_ring 'cc-auto-update: A FAILED')" "RANG"
assert_eq "T2f: a second failure seconds later is cooled down" \
    "$(_ring 'cc-auto-update: B FAILED')" "silent"

# ─── T2g: a worker BLOCKER is not collapsed behind an unrelated "done" ───────
# The secondary instance of the same defect: `blocker` used to share the `task`
# bucket with `done`/`ready`, so a blocker landing within 300 s of an unrelated
# worker's routine "done" was swallowed. It is now promoted to `failure`.
_fresh_state t2g
assert_eq "T2g: an unrelated worker 'done' rings (task)" \
    "$(_ring 'nexus-a: task complete, PR ready' NEXUS_WORKER_WINDOW=a)" "RANG"
assert_eq "T2g: a worker BLOCKED in the same window still rings (failure, not task)" \
    "$(_ring 'nexus-b: BLOCKED — need operator decision' NEXUS_WORKER_WINDOW=b)" "RANG"
assert_contains "T2g: the blocker was classed as failure" \
    "$(_verdicts)" '"class":"failure"'

# ─── T3: critical class rings, on its own (shorter) cooldown ─────────────────
_fresh_state t3
assert_eq "T3: CRITICAL rings" "$(_ring 'CRITICAL: filesystem read-only')" "RANG"
assert_eq "T3: watcher ALERT shares the critical cooldown" \
    "$(_ring 'watcher ALERT: down')" "silent"
# A cold infra cooldown is independent of a hot critical one.
assert_eq "T3: infra cooldown is INDEPENDENT of critical" \
    "$(_ring 'cc-auto-update: something')" "RANG"
# Critical has its own interval: setting it to 0s re-opens immediately.
assert_eq "T3: critical re-rings once its interval elapses" \
    "$(_ring 'CRITICAL: again' NEXUS_NOTIFY_CD_CRITICAL=0)" "RANG"

# ─── T4: the operator's "major task done" channel — N workers ⇒ ONE bell ─────
# This is the operator's stated requirement: ten workers wrapping up at once
# must produce one bell, not ten.
_fresh_state t4
declare -a results=()
for w in w1 w2 w3 w4 w5 w6 w7 w8 w9 w10; do
    results+=("$(_ring "worker $w: done" NEXUS_WORKER_WINDOW="$w")")
done
rang=0; for r in "${results[@]}"; do [[ "$r" == "RANG" ]] && (( rang++ )); done
assert_eq "T4: ten workers finishing produce exactly ONE bell" "$rang" "1"

# ─── T5: unknown messages FAIL OPEN (but rate-limited) ───────────────────────
# Deliberate: a new upstream alert string must stay audible, not silently die.
_fresh_state t5
assert_eq "T5: an unrecognised message rings (fail-open)" \
    "$(_ring 'some brand new alert nobody classified')" "RANG"
assert_eq "T5: …but is rate-limited, not a flood" \
    "$(_ring 'another brand new alert')" "silent"

# ─── T6: permission prompts survive the agent-default suppression ────────────
# The safety valve. Suppressing "Needs attention" wholesale would otherwise
# swallow a genuine block; notify-permission.sh re-emits it classified.
_fresh_state t6
assert_eq "T6: permission-needed rings" \
    "$(_ring 'permission needed: w1 is blocked awaiting approval')" "RANG"
assert_eq "T6: a second block within the window is cooled down" \
    "$(_ring 'permission needed: w2 is blocked awaiting approval')" "silent"
# End-to-end through the hook: idle is silent, permission rings.
_fresh_state t6b
: > "$HITS"
echo '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"w"}' \
  | env PATH="$OBS:$PATH" NEXUS_NOTIFY_STATE_DIR="$STATE" \
        NEXUS_NOTIFY_ANCESTRY_SCAN=0 NEXUS_WORKER_WINDOW=w1 \
        bash "$PERM_HOOK" >/dev/null 2>&1
assert_eq "T6: hook stays silent on idle_prompt" "$(wc -l < "$HITS")" "0"
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"a"}' \
  | env PATH="$OBS:$PATH" NEXUS_NOTIFY_STATE_DIR="$STATE" \
        NEXUS_NOTIFY_ANCESTRY_SCAN=0 NEXUS_WORKER_WINDOW=w1 \
        bash "$PERM_HOOK" >/dev/null 2>&1
assert_eq "T6: hook rings on permission_prompt" "$(wc -l < "$HITS")" "1"
assert_contains "T6: the bell names the blocked window" "$(cat "$HITS")" "w1 is blocked"

# ─── T7: a TEST HARNESS never rings — ancestry probe ─────────────────────────
# The actual root cause: `bash monitor/watcher/test-cc-auto-update.sh` invoked
# directly, driving the real alert paths. Simulated by invoking the gate from a
# script whose name matches the harness pattern, with the ancestry probe ON.
_fresh_state t7
: > "$HITS"
cat > "$WORK/test-fake-suite.sh" <<EOF
#!/usr/bin/env bash
exec bash "$GATE" "cc-auto-update: pretend this is a test case"
EOF
chmod +x "$WORK/test-fake-suite.sh"
env PATH="$OBS:$PATH" NEXUS_NOTIFY_STATE_DIR="$STATE" \
    NEXUS_NOTIFY_ANCESTRY_SCAN=1 \
    bash "$WORK/test-fake-suite.sh" >/dev/null 2>&1
assert_eq "T7: a bell from under a test-*.sh ancestor is suppressed" \
    "$(wc -l < "$HITS")" "0"
assert_contains "T7: recorded as a test-harness suppression" \
    "$(_verdicts)" '"verdict":"suppress-test-harness"'
# …and the probe must NOT deafen a normal caller.
_fresh_state t7b
assert_eq "T7: a normal (non-test) caller still rings with the probe on" \
    "$(_ring 'CRITICAL: real one' ANCESTRY_UNUSED=1)" "RANG"

# ─── T7c: the ancestry probe must not be fooled by an agent's PROMPT ─────────
# A Claude Code process carries its entire prompt in argv. If the probe scanned
# the whole cmdline, a worker whose prompt merely MENTIONS "test-foo.sh" would
# go silently deaf for its entire session — the exact inverted failure this
# gate must never have. The probe reads only the first 3 argv tokens and stops
# at the claude binary. Simulated with a fake `claude` whose argv carries a
# prompt naming a test file.
_fresh_state t7c
: > "$HITS"
mkdir -p "$WORK/fakebin"
# NOTE: no `exec` — the real claude persists as the gate's ancestor (the hook
# runs as a child of claude). exec would drop the claude frame and let the
# probe walk into the test harness itself.
cat > "$WORK/fakebin/claude" <<EOF
#!/usr/bin/env bash
bash "$GATE" "CRITICAL: worker needs the operator"
EOF
chmod +x "$WORK/fakebin/claude"
env PATH="$OBS:$PATH" NEXUS_NOTIFY_STATE_DIR="$STATE" \
    NEXUS_NOTIFY_ANCESTRY_SCAN=1 \
    "$WORK/fakebin/claude" --dangerously-skip-permissions \
    "please fix monitor/watcher/test-cc-auto-update.sh" >/dev/null 2>&1
assert_eq "T7c: a prompt mentioning test-*.sh does NOT deafen the agent" \
    "$(wc -l < "$HITS")" "1"

# ─── T8: NEXUS_NOTIFY_QUIET is a hard off-switch ─────────────────────────────
_fresh_state t8
assert_eq "T8: QUIET=1 suppresses even a CRITICAL" \
    "$(_ring 'CRITICAL: disk' NEXUS_NOTIFY_QUIET=1)" "silent"
assert_contains "T8: recorded as a quiet suppression" \
    "$(_verdicts)" '"verdict":"suppress-quiet"'

# ─── T9: NEXUS_NOTIFY_FORCE is a hard ON switch (emergency override) ─────────
_fresh_state t9
assert_eq "T9: FORCE=1 rings the agent-sandbox default" \
    "$(_ring 'Needs attention' NEXUS_NOTIFY_FORCE=1)" "RANG"
assert_eq "T9: FORCE=1 bypasses a hot cooldown" \
    "$(_ring 'CRITICAL: one')" "RANG"
assert_eq "T9: …proving the cooldown was hot" \
    "$(_ring 'CRITICAL: two')" "silent"
assert_eq "T9: FORCE=1 rings anyway" \
    "$(_ring 'CRITICAL: three' NEXUS_NOTIFY_FORCE=1)" "RANG"

# ─── T10: TWO CALLERS RACING share one bell ──────────────────────────────────
# The cross-window rate limit is only real if it is concurrency-safe. Fire N
# callers simultaneously against a cold cooldown; exactly one may ring.
_fresh_state t10
: > "$HITS"
for i in $(seq 1 12); do
    env PATH="$OBS:$PATH" NEXUS_NOTIFY_STATE_DIR="$STATE" \
        NEXUS_NOTIFY_ANCESTRY_SCAN=0 NEXUS_WORKER_WINDOW="racer$i" \
        bash "$GATE" "worker racer$i: done" >/dev/null 2>&1 &
done
wait
assert_eq "T10: 12 concurrent callers produce exactly ONE bell" \
    "$(wc -l < "$HITS")" "1"

# ─── T11: a STALE LOCK self-heals — a wedged cooldown must never deafen ──────
# A killed caller can leave the lock dir behind. If that permanently silenced
# the class, the fix would be worse than the flood.
_fresh_state t11
mkdir -p "$STATE/notify-cooldown/.lock.critical"
# Backdate it well past the 10s staleness threshold.
touch -d '2020-01-01' "$STATE/notify-cooldown/.lock.critical" 2>/dev/null \
    || touch -t 202001010000 "$STATE/notify-cooldown/.lock.critical"
assert_eq "T11: a stale lock is reclaimed and the bell still rings" \
    "$(_ring 'CRITICAL: stale lock present')" "RANG"
assert_no_file "T11: the stale lock was cleaned up" \
    "$STATE/notify-cooldown/.lock.critical"

# ─── T12: an UNWRITABLE state dir rings rather than deafens ──────────────────
# Fail-safe direction: losing the rate limit is acceptable, losing the bell is
# not. (Skipped as root, which ignores mode bits.)
if [[ "$(id -u)" != "0" ]]; then
    _fresh_state t12
    chmod 0555 "$STATE"
    assert_eq "T12: unwritable state dir ⇒ ring (never deafen)" \
        "$(_ring 'CRITICAL: cannot write state')" "RANG"
    chmod 0755 "$STATE"
else
    echo "SKIP: T12 needs non-root (0555 fixture models an unwritable dir)" >&2
fi

# ─── T13: recursion guard — resolving by NAME must not re-invoke the wrapper ─
# The wrapper is first on PATH; a bare-name resolution that found itself would
# loop forever. Hostile fixture: a SECOND PATH dir whose sandbox-notify is a
# symlink back to the wrapper.
_fresh_state t13
: > "$HITS"
# Both PATH-front entries are the SAME wrapper (via symlink), exactly as in
# production where there is one wrapper. A bare-name resolution finds the
# wrapper first; the realpath guard must skip BOTH wrapper instances and reach
# the real (observer) binary, not ping-pong between them.
mkdir -p "$WORK/front" "$WORK/decoy"
ln -sf "$GATE" "$WORK/front/sandbox-notify"
ln -sf "$GATE" "$WORK/decoy/sandbox-notify"
out=$(env PATH="$WORK/front:$WORK/decoy:$OBS:$PATH" \
      NEXUS_NOTIFY_STATE_DIR="$STATE" NEXUS_NOTIFY_ANCESTRY_SCAN=0 \
      timeout 20 sandbox-notify 'CRITICAL: recursion probe' 2>&1; echo "rc=$?")
assert_contains "T13: bare-name invocation terminates (no recursion)" "$out" "rc=0"
assert_eq "T13: it reached the real binary exactly once" "$(wc -l < "$HITS")" "1"

# ─── T14: no real sandbox-notify on PATH ⇒ fail silent, exit 0 ───────────────
# A notification hook must never spew or fail the agent's turn.
_fresh_state t14
# A clean PATH with the coreutils/bash the wrapper needs, but NO sandbox-notify
# anywhere on it (the real one lives under linuxbrew's Cellar, not /usr/bin).
mkdir -p "$WORK/binonly"
out=$(env PATH="$WORK/binonly:/usr/bin:/bin" NEXUS_NOTIFY_STATE_DIR="$STATE" \
      NEXUS_NOTIFY_ANCESTRY_SCAN=0 \
      bash "$GATE" 'CRITICAL: nothing to ring' 2>&1; echo "rc=$?")
assert_contains "T14: exits 0 when no real binary exists" "$out" "rc=0"
assert_not_contains "T14: emits nothing on stdout/stderr" "$out" "not found"

# ─── T15: every decision is countable after the fact ─────────────────────────
# v1 shipped with no such record, which is why this investigation had to be
# re-run from scratch. Each row must carry ts / class / verdict / window.
_fresh_state t15
_ring 'CRITICAL: observability' NEXUS_WORKER_WINDOW=obs-w >/dev/null
row=$(_verdicts | tail -1)
assert_contains "T15: decision row carries a timestamp" "$row" '"ts":'
assert_contains "T15: decision row carries the class"   "$row" '"class":"critical"'
assert_contains "T15: decision row carries the verdict" "$row" '"verdict":"ring"'
assert_contains "T15: decision row carries the window"  "$row" '"window":"obs-w"'

# ═══════════════════════════════════════════════════════════════════════════
# ROUND 2 — aggregate + batch on release, digest-only routine, cascade de-dup.
# The inverted bar (skeptic): a suppressed one-shot must be DELIVERED in a
# batch (not lost); cascade de-dup must not swallow a distinct second event;
# the flush must not wedge.
# ═══════════════════════════════════════════════════════════════════════════

# Emit one message through the gate with an explicit state dir + env, no ring
# counting (used where we assert on batch files / flush output directly).
_emit() { env PATH="$OBS:$PATH" NEXUS_NOTIFY_STATE_DIR="$STATE" \
    NEXUS_NOTIFY_ANCESTRY_SCAN=0 NEXUS_NOTIFY_INCIDENT_WINDOW="${INCIDENT:-0}" \
    "${@:2}" bash "$GATE" "$1" >/dev/null 2>&1; }
# Run the flush pass (watcher-tick side) against $STATE.
_flush() { env PATH="$OBS:$PATH" NEXUS_NOTIFY_STATE_DIR="$STATE" \
    NEXUS_NOTIFY_ANCESTRY_SCAN=0 NEXUS_NOTIFY_FLUSH=1 "$@" \
    bash "$GATE" >/dev/null 2>&1; }
_batch() { cat "$STATE/notify-cooldown/$1.batch" 2>/dev/null || true; }

# ─── T16: a cooldown-suppressed message is CAPTURED, not dropped ─────────────
# The batch is APPEND-ONLY (round-2 concurrency fix — no read-rewrite-mv that a
# concurrent writer could clobber); identical messages are collapsed with a
# count at DRAIN, not at add. So the on-disk spool has two lines here and the
# DIGEST shows "2× …".
_fresh_state t16; : > "$HITS"
_emit 'cc-auto-update: X applied'      # infra, cold → rings
_emit 'cc-auto-update: Y applied'      # infra, hot  → captured to batch
_emit 'cc-auto-update: Y applied'      # identical  → captured again (append-only)
assert_eq "T16: only the first infra message rang" "$(wc -l < "$HITS")" "1"
assert_contains "T16: the suppressed message was captured to the batch" \
    "$(_batch infra)" "cc-auto-update: Y applied"
: > "$HITS"
_flush NEXUS_NOTIFY_CD_INFRA=0
assert_contains "T16: identical captured messages collapse with a count in the digest" \
    "$(_last_bell)" "2× cc-auto-update: Y applied"

# ─── T17: a later real bell DRAINS the batch into its digest (delivered) ─────
_fresh_state t17; : > "$HITS"
_emit 'cc-auto-update: routine one applied'   # infra cold → rings
_emit 'cc-auto-update: routine two applied'   # infra hot  → batched
INCIDENT=0 _emit 'CRITICAL: unrelated real emergency'   # critical → rings, drains infra
assert_contains "T17: the critical bell carries the drained infra digest" \
    "$(_last_bell)" "batched"
assert_contains "T17: …naming the captured message" \
    "$(_last_bell)" "cc-auto-update: routine two applied"
assert_eq "T17: the batch is now empty (drained, not left to rot)" \
    "$(_batch infra)" ""

# ─── T18: THE ONE THAT MATTERS — a masked one-shot FAILED is delivered ───────
# A routine ping burns the cycle, the terminal apply.sh FAILED lands within the
# same window and (if it collapsed) must still reach the operator via a batch.
# Here the failure RINGS directly (its own class) AND, if a prior failure had
# burned the 120s window, it is captured and flushed. Prove BOTH: the second
# same-class failure is captured, then a flush DELIVERS it.
_fresh_state t18; : > "$HITS"
_emit 'cc-auto-update: install FAILED; pin rolled back'      # failure cold → rings
_emit 'cc-auto-update: post-install verify FAILED; rolled back'  # failure hot → captured
assert_eq "T18: the first terminal failure rang immediately" "$(wc -l < "$HITS")" "1"
assert_contains "T18: the masked second failure was CAPTURED, not lost" \
    "$(_batch failure)" "post-install verify FAILED"
: > "$HITS"
_flush NEXUS_NOTIFY_CD_FAILURE=0        # window elapsed → flush must deliver it
assert_eq "T18: the flush DELIVERS the captured failure as a digest bell" \
    "$(wc -l < "$HITS")" "1"
assert_contains "T18: the digest names the once-masked failure" \
    "$(_last_bell)" "post-install verify FAILED"
assert_eq "T18: the batch is cleared after delivery" "$(_batch failure)" ""

# ─── T19: the digest-only `routine` class never fires its OWN bell ──────────
_fresh_state t19; : > "$HITS"
_emit 'cc-auto-update: on old binary — reconciling restart under watchdog'
_emit 'cc-auto-update: clone is 3 commits behind origin/main'
_emit 'cc-auto-update: 2.1.9 applied; orchestrator restart handed off to watchdog'
assert_eq "T19: three routine pings ring ZERO bells" "$(wc -l < "$HITS")" "0"
assert_contains "T19: …but all are captured (nothing vanishes)" \
    "$(_verdicts)" '"class":"routine","verdict":"batch-routine"'
: > "$HITS"
_flush NEXUS_NOTIFY_CD_ROUTINE=0
assert_eq "T19: they surface as ONE digest bell on release" "$(wc -l < "$HITS")" "1"
assert_contains "T19: the digest names a routine ping" \
    "$(_last_bell)" "reconciling"
# A progress note that mentions 'version-split' must be routine, NOT failure.
_fresh_state t19b; : > "$HITS"
_emit 'cc-auto-update: 2.1.9 applied; restart handed off (workspace version-split until it restarts)'
assert_eq "T19b: 'handed off … version-split' is routine (digest-only), not a failure bell" \
    "$(wc -l < "$HITS")" "0"
assert_contains "T19b: …classed routine" "$(_verdicts)" '"class":"routine"'

# ─── T20: CASCADE de-dup — a 4-layer fan-out collapses to ONE bell ──────────
_fresh_state t20; : > "$HITS"
INCIDENT=6 _emit 'cc-auto-update: watcher restart FAILED — manual: svc.sh restart'  # rings, opens incident
INCIDENT=6 _emit 'cc-update self-restart FAILED: orchestrator on old'               # coalesced
INCIDENT=6 _emit 'watcher: functional check stale (x)'                              # coalesced
INCIDENT=6 _emit 'revive-watcher: guard tripped — watcher down, needs attention'    # coalesced
assert_eq "T20: the 4-layer cascade rings exactly ONE bell" "$(wc -l < "$HITS")" "1"
assert_contains "T20: the coalesced layers are captured, not lost (critical)" \
    "$(_batch critical)" "self-restart FAILED"
assert_contains "T20: the coalesced layers are captured, not lost (infra)" \
    "$(_batch infra)" "functional check stale"
assert_contains "T20: the incident coalescing is recorded" \
    "$(_verdicts)" '"verdict":"suppress-incident"'

# ─── T21: cascade de-dup must NOT swallow a DISTINCT later event ─────────────
# After the incident window elapses, a genuinely new event rings on its own.
_fresh_state t21; : > "$HITS"
INCIDENT=6 _emit 'CRITICAL: incident one'                 # rings, opens incident
INCIDENT=6 _emit 'CRITICAL: same-incident fanout'         # coalesced
# age the incident stamp past the window:
touch -d '2 minutes ago' "$STATE/notify-cooldown/.incident" 2>/dev/null \
    || touch -t 200001010000 "$STATE/notify-cooldown/.incident"
: > "$HITS"
INCIDENT=6 _emit 'CRITICAL: a DISTINCT later emergency' NEXUS_NOTIFY_CD_CRITICAL=0
assert_eq "T21: a distinct event after the window rings (not swallowed)" \
    "$(wc -l < "$HITS")" "1"
assert_contains "T21: and it delivers the earlier coalesced layer in its digest" \
    "$(_last_bell)" "same-incident fanout"

# ─── T22: the flush cannot WEDGE — a stale flush lock is reclaimed ───────────
_fresh_state t22; : > "$HITS"
_emit 'cc-auto-update: P applied'; _emit 'cc-auto-update: Q applied'   # Q batched
mkdir -p "$STATE/notify-cooldown/.lock.batch.infra"
touch -d '1 minute ago' "$STATE/notify-cooldown/.lock.batch.infra" 2>/dev/null \
    || touch -t 200001010000 "$STATE/notify-cooldown/.lock.batch.infra"
: > "$HITS"
_flush NEXUS_NOTIFY_CD_INFRA=0
assert_eq "T22: flush reclaims the stale batch lock and still delivers" \
    "$(wc -l < "$HITS")" "1"
assert_no_file "T22: the stale lock was cleaned up" \
    "$STATE/notify-cooldown/.lock.batch.infra"

# ─── T23: flush is a no-op when nothing is pending (no spurious bell) ────────
_fresh_state t23; : > "$HITS"
_flush
assert_eq "T23: flush with empty batches rings nothing" "$(wc -l < "$HITS")" "0"

# ─── T24: FORCE still bypasses batching/incident and rings ──────────────────
_fresh_state t24; : > "$HITS"
INCIDENT=6 _emit 'CRITICAL: opens incident'
assert_eq "T24: FORCE rings even inside an active incident window" \
    "$(_ring 'cc-auto-update: reconciling under FORCE' NEXUS_NOTIFY_FORCE=1 INCIDENT=6)" "RANG"

# ─── T2h: a terminal "restart aborted" is `failure`; a "will retry" is routine ─
# Round-2 skeptic judgment call: watchdog restart-aborts (template missing /
# spawn failed / never armed) are genuine aborts, promoted out of infra.
_fresh_state t2h; : > "$HITS"
_emit 'cc-auto-update: orchestrator restart aborted — watchdog template missing'
assert_contains "T2h: a terminal restart-abort is classed failure" \
    "$(_verdicts)" '"class":"failure"'
_fresh_state t2h2; : > "$HITS"
_emit 'cc-auto-update: orchestrator restart aborted — pane not resolved; will retry'
assert_contains "T2h: a 'will retry' restart-abort stays routine (non-terminal)" \
    "$(_verdicts)" '"class":"routine"'

# ─── T25: the batch FAILS OPEN — a suppressed message is never dropped for ───
# want of a lock (skeptic round-2 caveat). Even with the batch lock HELD by a
# stale-but-not-yet-reclaimable holder, an add must still capture (via the
# per-writer overflow spool), and a later drain must deliver it.
_fresh_state t25; : > "$HITS"
_emit 'cc-auto-update: seed FAILED'            # burn the failure cooldown
mkdir -p "$STATE/notify-cooldown/.lock.batch.failure"   # hold the lock (fresh, not stale)
_emit 'cc-auto-update: lock-contended distinct FAILED'  # cannot lock → overflow spool
assert_contains "T25: a message that could not lock is still captured (fail-open)" \
    "$(cat "$STATE"/notify-cooldown/failure.batch* 2>/dev/null)" "lock-contended distinct FAILED"
rmdir "$STATE/notify-cooldown/.lock.batch.failure" 2>/dev/null
: > "$HITS"
_flush NEXUS_NOTIFY_CD_FAILURE=0
assert_contains "T25: …and it is DELIVERED in the digest, not lost" \
    "$(_last_bell)" "lock-contended distinct FAILED"

# ─── T26: high-concurrency distinct failures — none silently lost ───────────
# The exact regime the skeptic measured a drop in (≥30 concurrent distinct).
# Append-only capture + per-writer overflow must keep ALL of them.
#
# MEASUREMENT NOTE (your-org/nexus-code#572). This used to count only the
# on-disk spool, which UNDER-counts: a message carried off by a concurrent
# ring's drain and rendered into that bell has been DELIVERED, not lost, and
# legitimately no longer sits in the spool. Counting spool ∪ delivered-bells is
# a CORRECTION of the measurement, not a loosening of the assertion — the
# invariant "0 of 40 lost" is still asserted exactly, and a genuinely dropped
# message is in neither place and still fails. (The real defect the old count
# was tripping over is pinned deterministically by T27 below; that is the test
# to look at first if this one goes red.)
_fresh_state t26; : > "$HITS"
_emit 'cc-auto-update: cc seed FAILED'         # burn cooldown
for i in $(seq 1 40); do
    _emit "cc-auto-update: conc-$i FAILED" &
done
wait
captured=$( { cat "$STATE"/notify-cooldown/failure.batch* 2>/dev/null | cut -f2
              cat "$HITS" 2>/dev/null; } | grep -o 'conc-[0-9]\{1,\}' | sort -u | grep -c 'conc-')
assert_eq "T26: all 40 concurrent distinct failures were accounted for (0 lost)" \
    "$captured" "40"

# ─── T27: the drain's render cap DEFERS the remainder, it does not DROP it ───
# Regression for your-org/nexus-code#572, and the load-independent core of it:
# this needs NO concurrency at all. 20 distinct pending failures + ONE ring used
# to destroy 14 message identities outright — the bell rendered 6 and appended
# "(+14 more)", then the claim file was deleted. The TALLY survived; the
# identities did not, in neither the bell nor on disk. A count is not a
# coverage claim (`#568`'s own defect class).
#
# T26 above only *exhibits* this under load; T27 *pins* it deterministically,
# so a regression cannot hide behind "timing flake on a busy runner".
_fresh_state t27; : > "$HITS"
mkdir -p "$STATE/notify-cooldown"
for i in $(seq 1 20); do
    printf '1\tdistinct-%02d FAILED\n' "$i" >> "$STATE/notify-cooldown/failure.batch"
done
_emit 'cc-auto-update: trigger FAILED'         # cold cooldown ⇒ rings ⇒ drains
t27_lost=""
for i in $(seq 1 20); do
    _m=$(printf 'distinct-%02d FAILED' "$i")
    if ! grep -qF "$_m" "$HITS" 2>/dev/null \
       && ! grep -qF "$_m" <<<"$(cat "$STATE"/notify-cooldown/failure.batch* 2>/dev/null)"; then
        t27_lost="$t27_lost $i"
    fi
done
assert_eq "T27: one ring's drain loses none of 20 pending (cap defers, never drops)" \
    "${t27_lost:-none}" "none"
# The bell itself must stay BOUNDED — deferral exists so the cap can hold.
assert_contains "T27: the bell renders the cap and names the remainder deferred" \
    "$(_last_bell)" "(+14 deferred)"
# …and the deferred remainder must CONVERGE to delivery, not strand on disk.
: > "$HITS"
for _p in 1 2 3 4; do _flush NEXUS_NOTIFY_CD_FAILURE=0; done
t27_rem=$(cat "$STATE"/notify-cooldown/failure.batch* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "T27: successive digests drain the deferred remainder to empty" \
    "$t27_rem" "0"
t27_undeliv=""
for i in $(seq 7 20); do
    _m=$(printf 'distinct-%02d FAILED' "$i")
    grep -qF "$_m" "$HITS" 2>/dev/null || t27_undeliv="$t27_undeliv $i"
done
assert_eq "T27: every deferred message reached a bell across those digests" \
    "${t27_undeliv:-none}" "none"

# ─── T28: the FIRST use of a class spool must be silent AND deliver (#723) ───
#
# `_nw_batch_add` sized the spool with `wc -l < "$_nwb_file" 2>/dev/null`,
# and `<class>.batch` does not exist until the first suppressed message of
# that class. A redirection failure is reported by the SHELL, not by the
# command, so that `2>/dev/null` — which redirects `wc`'s stderr — could not
# suppress it. Every class printed one
#   sandbox-notify: line NNN: …/<class>.batch: No such file or directory
# on first use, once, and then never again.
#
# WHY IT NEEDED A TEST AT ALL, given severity ~nil: two agents independently
# read that line as "the operator alert path is dead" and investigated —
# one of them the orchestrator. The notification had in fact landed both
# times (`routine.batch` held 133 bytes written during the very apply one
# agent believed had failed). A diagnostic that cries wolf on the ALERT
# MECHANISM costs an investigation per sighting.
#
# Nothing caught it because `_ring` above discards stderr — reasonably, since
# every other case is about whether a bell RANG. So this case runs the gate
# directly and keeps the two streams apart.
#
# BOTH DIRECTIONS, deliberately. Asserting only "stderr is empty" would be
# satisfied by a fix that silenced the path by breaking it — so the spool
# CONTENT is asserted too. Silence is necessary; delivery is the point.
echo '=== T28: first use of a class spool is silent and still captures (#723) ==='
_fresh_state 723
t28_err="$WORK/t28.err"; : > "$t28_err"; : > "$HITS"
_t28_ring() {   # like _ring, but stderr is EVIDENCE rather than noise
    env -u NEXUS_ROOT -u NEXUS_LOCALS -u NEXUS_STATE_DIR \
        -u NEXUS_WORKER_WINDOW -u NEXUS_ORCHESTRATOR_WINDOW \
        PATH="$OBS:$PATH" \
        NEXUS_NOTIFY_STATE_DIR="$STATE" \
        NEXUS_NOTIFY_ANCESTRY_SCAN=0 \
        NEXUS_NOTIFY_INCIDENT_WINDOW=0 \
        bash "$GATE" "$1" >/dev/null 2>>"$t28_err"
}
# First ring passes the cold cooldown and rings; rings 2 and 3 are suppressed
# and are therefore the FIRST writers of `infra.batch` — the first-use path.
_t28_ring 'cc-auto-update: candidate 9.9.9 available'
_t28_ring 'cc-auto-update: candidate 9.9.8 available'
_t28_ring 'cc-auto-update: candidate 9.9.7 available'

assert_eq "T28: first use of a class spool writes NOTHING to stderr" \
    "$(cat "$t28_err")" ""
# Delivery, measured — not inferred from the silence above.
t28_spool="$STATE/notify-cooldown/infra.batch"
assert_eq "T28: the class spool was created" \
    "$([[ -f "$t28_spool" ]] && echo yes || echo no)" "yes"
assert_contains "T28: the first suppressed message was captured, not dropped" \
    "$(cat "$t28_spool" 2>/dev/null)" "candidate 9.9.8 available"
assert_contains "T28: the second suppressed message was captured too" \
    "$(cat "$t28_spool" 2>/dev/null)" "candidate 9.9.7 available"
# And the un-suppressed one still reached the operator.
assert_contains "T28: the first (un-suppressed) message still rang" \
    "$(cat "$HITS")" "candidate 9.9.9 available"

# ─── T29: sustained newer load must not STARVE the oldest deferred message ───
# your-org/nexus-code#572 follow-up. #572 made the render cap DEFER instead of
# DROP (T27). But the drain assembled the claim MAIN-SPOOL-FIRST, then the
# ".of.*" overflow (which is where the carried remainder lives) — so the 6
# render slots went to whatever arrived FIRST, i.e. the freshest messages. The
# carried OLDEST messages sat at the back of the claim and were re-deferred
# every drain. Nothing is ever lost (they stay on disk, counted), but under a
# sustained regime of ≥6 NEW distinct failures per drain the oldest deferred
# identity can be re-deferred INDEFINITELY — the age of a pending message is
# unbounded, which is backwards (oldest should drain first).
#
# The fix drains the CARRY first, so the cap's slots go to the oldest pending
# identities and each deferred message advances toward a slot every drain,
# bounding its wait to ceil(backlog/6) drains regardless of new arrivals — with
# NO change to what is claimed (zero new loss; T26/T27 still hold).
#
# This test starves WITHOUT the fix: 20 olds are deferred to 14, then five
# intervals each inject 6 fresh distinct failures and drain. Main-first leaves
# every one of old-07…old-20 unrung after all five intervals; carry-first
# drains them all within three.
_fresh_state t29; : > "$HITS"
mkdir -p "$STATE/notify-cooldown"
for i in $(seq 1 20); do
    printf '1\told-%02d FAILED\n' "$i" >> "$STATE/notify-cooldown/failure.batch"
done
_flush NEXUS_NOTIFY_CD_FAILURE=0                 # renders 6, defers old-07…20
for k in $(seq 1 5); do
    for j in $(seq 1 6); do
        printf '1\tnew-%d-%d FAILED\n' "$k" "$j" >> "$STATE/notify-cooldown/failure.batch"
    done
    _flush NEXUS_NOTIFY_CD_FAILURE=0             # 6 fresh distinct each interval
done
t29_starved=""
for i in $(seq 7 20); do
    _m=$(printf 'old-%02d FAILED' "$i")
    grep -qF "$_m" "$HITS" 2>/dev/null || t29_starved="$t29_starved $i"
done
assert_eq "T29: sustained newer load starves none of the 14 initially-deferred olds" \
    "${t29_starved:-none}" "none"
# And the backlog still fully converges to delivery (no message stranded).
t29_rem=$(cat "$STATE"/notify-cooldown/failure.batch* 2>/dev/null | grep -c 'old-') || t29_rem=0
assert_eq "T29: every initially-deferred old has drained off disk" "$t29_rem" "0"

th_summary_and_exit
