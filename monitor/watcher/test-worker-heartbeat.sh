#!/usr/bin/env bash
# Tests for monitor/worker-heartbeat.sh — the hook helper that
# writes the per-window heartbeat consumed by pane-state.sh.
#
# Covers: state-token mapping, Notification message refinement,
# atomic write, env-var precedence (NEXUS_STATE_DIR > NEXUS_ROOT),
# missing-window short-circuit, fallback when jq is unavailable.
#
# Run: bash monitor/watcher/test-worker-heartbeat.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/worker-heartbeat.sh"

PASS=0
FAIL=0

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ok()   { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -x "$HELPER" ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }

run_helper() {
    # Args: <token> <window> <state-dir-env-var-name> <payload-json>
    local token="$1" window="$2" envvar="$3" payload="$4"
    local state_dir="$WORK/$envvar"
    mkdir -p "$state_dir"
    if [[ "$envvar" == "NEXUS_STATE_DIR" ]]; then
        env -i PATH="$PATH" \
            NEXUS_STATE_DIR="$state_dir" NEXUS_WORKER_WINDOW="$window" \
            bash "$HELPER" "$token" <<<"$payload"
    else
        env -i PATH="$PATH" \
            NEXUS_ROOT="$state_dir" NEXUS_WORKER_WINDOW="$window" \
            bash "$HELPER" "$token" <<<"$payload"
    fi
}

read_state() {
    local file="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r '.state // empty' "$file" 2>/dev/null
    else
        grep -oE '"state"[[:space:]]*:[[:space:]]*"[^"]+"' "$file" \
            | sed -E 's/.*"([^"]+)"$/\1/' | head -1
    fi
}

echo "=== state-token mapping ==="

run_helper busy w1 NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w1.json"
if [[ -f "$f" ]] && [[ "$(read_state "$f")" == "busy" ]]; then
    ok "busy token → state=busy via NEXUS_STATE_DIR"
else
    bad "busy token → state=busy" "got: $(cat "$f" 2>/dev/null)"
fi

run_helper user_prompt w2 NEXUS_STATE_DIR '{"hook_event_name":"UserPromptSubmit"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w2.json"
if [[ -f "$f" ]] && [[ "$(read_state "$f")" == "user_prompt" ]]; then
    ok "user_prompt token → state=user_prompt"
else
    bad "user_prompt token → state=user_prompt" "got: $(cat "$f" 2>/dev/null)"
fi

echo
echo "=== user_prompt durable stamp (operator-engagement trigger, issues #196/#201) ==="

# user_prompt MUST also write the per-window stamp file the watcher's
# engagement attribution reads — `<state-dir>/user-prompt/<window>`
# with `<epoch>\t<session-id>`. The heartbeat JSON is transient
# (next PostToolUse overwrites it); the stamp is the contract.
run_helper user_prompt w_up NEXUS_STATE_DIR \
    '{"hook_event_name":"UserPromptSubmit","session_id":"sess-up"}'
sf="$WORK/NEXUS_STATE_DIR/user-prompt/w_up"
now=$(date +%s)
if [[ -f "$sf" ]]; then
    se=$(awk -F'\t' 'NR==1 { print $1 }' "$sf")
    ss=$(awk -F'\t' 'NR==1 { print $2 }' "$sf")
    if [[ "$se" =~ ^[0-9]+$ ]] && (( se <= now )) && (( now - se <= 3 )); then
        ok "user_prompt → stamp epoch ≈ now (got $se)"
    else
        bad "user_prompt stamp epoch" "got=$se now=$now"
    fi
    if [[ "$ss" == "sess-up" ]]; then
        ok "user_prompt → stamp carries session_id"
    else
        bad "user_prompt stamp session_id" "got=$ss"
    fi
else
    bad "user_prompt → stamp file written" "no file at $sf"
fi

# The stamp survives subsequent non-user_prompt heartbeats — a busy
# tick must not clobber it (it lives outside heartbeat/).
run_helper busy w_up NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
if [[ -f "$sf" ]] && [[ "$(awk -F'\t' 'NR==1 { print $1 }' "$sf")" == "$se" ]]; then
    ok "stamp survives a subsequent busy heartbeat"
else
    bad "stamp survival" "got: $(cat "$sf" 2>/dev/null)"
fi

# A newer submit overwrites the stamp (last-submit-wins).
sleep 1
run_helper user_prompt w_up NEXUS_STATE_DIR \
    '{"hook_event_name":"UserPromptSubmit","session_id":"sess-up"}'
se2=$(awk -F'\t' 'NR==1 { print $1 }' "$sf")
if [[ "$se2" =~ ^[0-9]+$ ]] && (( se2 > se )); then
    ok "newer submit advances the stamp ($se → $se2)"
else
    bad "stamp advance" "se=$se se2=$se2"
fi

# Non-user_prompt tokens never create a stamp.
run_helper busy w_nostamp NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse"}'
run_helper turn_end w_nostamp NEXUS_STATE_DIR '{"hook_event_name":"Stop"}'
if [[ ! -f "$WORK/NEXUS_STATE_DIR/user-prompt/w_nostamp" ]]; then
    ok "busy / turn_end tokens write no user-prompt stamp"
else
    bad "non-user_prompt stamp leak" "unexpected file"
fi

echo
echo "=== Notification message refinement ==="

run_helper notify w3 NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w3.json"
state=$(read_state "$f")
if [[ "$state" == "permission_prompt" ]]; then
    ok "notify + permission message → permission_prompt"
else
    bad "notify + permission message" "got state=$state"
fi

run_helper notify w4 NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w4.json"
state=$(read_state "$f")
if [[ "$state" == "idle_prompt" ]]; then
    ok "notify + waiting message → idle_prompt"
else
    bad "notify + waiting message" "got state=$state"
fi

run_helper notify w5 NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","message":"some unrecognised banner"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w5.json"
state=$(read_state "$f")
if [[ "$state" == "notify" ]]; then
    ok "notify + unknown message → raw notify token"
else
    bad "notify + unknown message" "got state=$state"
fi

echo
echo "=== Notification structured-field dispatch (notification_type) ==="

# Empirical payload shape captured in PR #132 — `.notification_type`
# is a top-level field. When present, it MUST win over message
# text-match (i18n-stable, won't drift with banner copy changes).
run_helper notify w_nt_perm NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"completely unrelated banner copy"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_nt_perm.json"
state=$(read_state "$f")
if [[ "$state" == "permission_prompt" ]]; then
    ok "notification_type=permission_prompt (text-match-disagreeing message) → permission_prompt"
else
    bad "notification_type=permission_prompt overrides message" "got state=$state"
fi

run_helper notify w_nt_idle NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"unrelated"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_nt_idle.json"
state=$(read_state "$f")
if [[ "$state" == "idle_prompt" ]]; then
    ok "notification_type=idle_prompt → idle_prompt"
else
    bad "notification_type=idle_prompt → idle_prompt" "got state=$state"
fi

# Unknown structured value (e.g. auth_success / elicitation_*) →
# raw notify token; consumer falls through to renderer path.
run_helper notify w_nt_other NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","notification_type":"auth_success"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_nt_other.json"
state=$(read_state "$f")
if [[ "$state" == "notify" ]]; then
    ok "notification_type=auth_success (unmapped) → raw notify token"
else
    bad "notification_type=auth_success → notify" "got state=$state"
fi

# Backward-compat: when notification_type is absent (older Claude
# Code, malformed payload, jq missing branch), the message text-match
# path remains in force. Mirrors w3/w4 above but is now load-bearing.
run_helper notify w_compat_perm NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_compat_perm.json"
state=$(read_state "$f")
if [[ "$state" == "permission_prompt" ]]; then
    ok "no notification_type + permission message → falls back to text-match (permission_prompt)"
else
    bad "text-match fallback for permission" "got state=$state"
fi

run_helper notify w_compat_idle NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","message":"Claude is waiting for your input"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_compat_idle.json"
state=$(read_state "$f")
if [[ "$state" == "idle_prompt" ]]; then
    ok "no notification_type + waiting message → falls back to text-match (idle_prompt)"
else
    bad "text-match fallback for idle" "got state=$state"
fi

# Empty string vs absent. jq `.notification_type // empty` yields ""
# for both a missing key and an explicit null; this guard ensures the
# text-match fallback engages in the second case too.
run_helper notify w_compat_null NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","notification_type":null,"message":"Claude needs your permission"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_compat_null.json"
state=$(read_state "$f")
if [[ "$state" == "permission_prompt" ]]; then
    ok "notification_type:null + permission message → falls back to text-match"
else
    bad "notification_type:null falls back to text-match" "got state=$state"
fi

echo
echo "=== env-var precedence (NEXUS_STATE_DIR wins over NEXUS_ROOT) ==="

# Set both: only NEXUS_STATE_DIR's path should receive the heartbeat.
sd="$WORK/precedence-state-dir"
rd="$WORK/precedence-root-dir"
mkdir -p "$sd" "$rd"
env -i PATH="$PATH" \
    NEXUS_STATE_DIR="$sd" NEXUS_ROOT="$rd" NEXUS_WORKER_WINDOW=w6 \
    bash "$HELPER" busy <<<'{"hook_event_name":"PostToolUse","tool_name":"Edit"}'
if [[ -f "$sd/heartbeat/w6.json" ]] && [[ ! -f "$rd/monitor/.state/heartbeat/w6.json" ]]; then
    ok "NEXUS_STATE_DIR takes precedence over NEXUS_ROOT"
else
    bad "precedence" "state-dir-file=$([[ -f $sd/heartbeat/w6.json ]] && echo Y || echo N) root-dir-file=$([[ -f $rd/monitor/.state/heartbeat/w6.json ]] && echo Y || echo N)"
fi

echo
echo "=== NEXUS_ROOT fallback ==="

env -i PATH="$PATH" \
    NEXUS_ROOT="$rd" NEXUS_WORKER_WINDOW=w7 \
    bash "$HELPER" busy <<<'{"hook_event_name":"PostToolUse"}'
if [[ -f "$rd/monitor/.state/heartbeat/w7.json" ]]; then
    ok "NEXUS_ROOT path: heartbeat lands at <root>/monitor/.state/heartbeat/"
else
    bad "NEXUS_ROOT fallback" "expected file missing"
fi

echo
echo "=== missing-window short-circuit ==="

# Without NEXUS_WORKER_WINDOW set, the helper must exit 0 silently
# and write nothing. A worker not spawned by us isn't part of the
# watcher's tracked surface; writing a window-less heartbeat would
# either clobber another worker's file or pile up garbage.
before_count=$(find "$WORK" -type f | wc -l)
env -i PATH="$PATH" NEXUS_STATE_DIR="$WORK/no-window" \
    bash "$HELPER" busy <<<'{}'
rc=$?
after_count=$(find "$WORK" -type f | wc -l)
if (( rc == 0 )) && (( before_count == after_count )); then
    ok "missing NEXUS_WORKER_WINDOW → exit 0, no file written"
else
    bad "missing window" "rc=$rc before=$before_count after=$after_count"
fi

echo
echo "=== empty state token short-circuit ==="

env -i PATH="$PATH" NEXUS_STATE_DIR="$WORK/empty-token" \
    NEXUS_WORKER_WINDOW=w8 \
    bash "$HELPER" <<<'{}'
rc=$?
if (( rc == 0 )) && [[ ! -f "$WORK/empty-token/heartbeat/w8.json" ]]; then
    ok "missing state token → exit 0, no file written"
else
    bad "missing state token" "rc=$rc file-exists=$([[ -f $WORK/empty-token/heartbeat/w8.json ]] && echo Y || echo N)"
fi

echo
echo "=== Stop-hook turn_end token (issue #129 item 3) ==="

# turn_end → state=idle_prompt AND last_turn_end stamp.
run_helper turn_end w_te NEXUS_STATE_DIR \
    '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"sess-te"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_te.json"
if [[ -f "$f" ]]; then
    state=$(read_state "$f")
    if [[ "$state" == "idle_prompt" ]]; then
        ok "turn_end token → state=idle_prompt"
    else
        bad "turn_end → idle_prompt" "got state=$state"
    fi
    lte=$(jq -r '.last_turn_end // empty' "$f" 2>/dev/null)
    if [[ -n "$lte" ]] && [[ "$lte" =~ ^[0-9]+$ ]]; then
        ok "turn_end token → last_turn_end stamped (got $lte)"
    else
        bad "turn_end → last_turn_end stamped" "got: $(cat "$f")"
    fi
    la=$(jq -r '.last_activity // empty' "$f" 2>/dev/null)
    if [[ "$la" == "$lte" ]]; then
        ok "turn_end token → last_activity == last_turn_end (both stamped at \$now)"
    else
        bad "turn_end → la == lte" "la=$la lte=$lte"
    fi
else
    bad "turn_end → heartbeat file written" "no file at $f"
fi

# Non-turn_end tokens MUST NOT emit last_turn_end (otherwise the
# longer staleness threshold would apply incorrectly to busy/notify).
run_helper busy w_no_lte NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_no_lte.json"
lte=$(jq -r '.last_turn_end // empty' "$f" 2>/dev/null)
if [[ -z "$lte" ]]; then
    ok "busy token → NO last_turn_end field (only turn_end stamps it)"
else
    bad "busy unexpectedly stamped last_turn_end" "got lte=$lte"
fi

# notify → idle_prompt path (the existing Notification idle case)
# also MUST NOT carry last_turn_end. Distinguishes a 60s-of-waiting
# notification from an actual turn-end stop event — different signal,
# different staleness rules.
run_helper notify w_nt_no_lte NEXUS_STATE_DIR \
    '{"hook_event_name":"Notification","notification_type":"idle_prompt"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w_nt_no_lte.json"
lte=$(jq -r '.last_turn_end // empty' "$f" 2>/dev/null)
if [[ -z "$lte" ]]; then
    ok "Notification idle_prompt → NO last_turn_end field"
else
    bad "Notification idle_prompt unexpectedly stamped last_turn_end" "got lte=$lte"
fi

echo
echo "=== last_activity is monotonically non-decreasing within a second ==="

# Two consecutive writes in quick succession should both produce
# valid heartbeats with last_activity >= the first one (epoch
# seconds resolution; we just check they parse and write).
run_helper busy w9 NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse"}'
sleep 1
run_helper busy w9 NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse"}'
f="$WORK/NEXUS_STATE_DIR/heartbeat/w9.json"
la=$(jq -r '.last_activity' "$f" 2>/dev/null || grep -oE '"last_activity"[[:space:]]*:[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+')
now=$(date +%s)
if [[ "$la" =~ ^[0-9]+$ ]] && (( la <= now )) && (( now - la <= 3 )); then
    ok "last_activity within 3 s of now (got $la, now $now)"
else
    bad "last_activity sanity" "got=$la now=$now"
fi

echo
echo "=== async-signal field preservation (issue #183) ==="

# (i) external_waits + dismissed_waits seeded by another writer
# (e.g. declare-wait.sh) are PRESERVED across PostToolUse fires.
hb="$WORK/NEXUS_STATE_DIR/heartbeat/w_pres.json"
mkdir -p "$WORK/NEXUS_STATE_DIR/heartbeat"
jq -nc '{
    state:"idle_prompt",
    last_activity:1,
    window:"w_pres",
    external_waits:[{kind:"slurm",id:"123",desc:"X"}],
    dismissed_waits:[{kind:"slurm",id:"999"}]
}' > "$hb"
run_helper busy w_pres NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
waits=$(jq -c '.external_waits' "$hb" 2>/dev/null)
dismissed=$(jq -c '.dismissed_waits' "$hb" 2>/dev/null)
if [[ "$waits" == '[{"kind":"slurm","id":"123","desc":"X"}]' ]]; then
    ok "PostToolUse preserves external_waits"
else
    bad "external_waits preserve" "got=$waits"
fi
if [[ "$dismissed" == '[{"kind":"slurm","id":"999"}]' ]]; then
    ok "PostToolUse preserves dismissed_waits"
else
    bad "dismissed_waits preserve" "got=$dismissed"
fi

# (ii) ScheduleWakeup PostToolUse stamps scheduled_wakeup_at =
# now + delaySeconds.
hb="$WORK/NEXUS_STATE_DIR/heartbeat/w_swa.json"
rm -f "$hb"
run_helper busy w_swa NEXUS_STATE_DIR \
    '{"hook_event_name":"PostToolUse","tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":270,"reason":"x","prompt":"y"}}'
now=$(date +%s)
swa=$(jq -r '.scheduled_wakeup_at // empty' "$hb" 2>/dev/null)
if [[ "$swa" =~ ^[0-9]+$ ]] && (( swa >= now + 260 )) && (( swa <= now + 280 )); then
    ok "ScheduleWakeup delaySeconds=270 → scheduled_wakeup_at ≈ now+270"
else
    bad "scheduled_wakeup_at" "got=$swa now=$now"
fi

# (iii) Subsequent non-ScheduleWakeup PostToolUse carries the
# wakeup forward (until it expires or a new wakeup overwrites it).
run_helper busy w_swa NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
swa2=$(jq -r '.scheduled_wakeup_at // empty' "$hb" 2>/dev/null)
if [[ "$swa2" == "$swa" ]]; then
    ok "non-ScheduleWakeup PostToolUse carries scheduled_wakeup_at forward"
else
    bad "swa carry-forward" "swa=$swa swa2=$swa2"
fi

# (iv) New ScheduleWakeup overwrites the prior wakeup.
sleep 1
run_helper busy w_swa NEXUS_STATE_DIR \
    '{"hook_event_name":"PostToolUse","tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":60}}'
swa3=$(jq -r '.scheduled_wakeup_at // empty' "$hb" 2>/dev/null)
now=$(date +%s)
if [[ "$swa3" =~ ^[0-9]+$ ]] && (( swa3 >= now + 55 )) && (( swa3 <= now + 70 )); then
    ok "new ScheduleWakeup overwrites prior wakeup"
else
    bad "swa overwrite" "got=$swa3 now=$now"
fi

# (v) external_waits is preserved across a ScheduleWakeup PostToolUse.
hb="$WORK/NEXUS_STATE_DIR/heartbeat/w_ews.json"
rm -f "$hb"
mkdir -p "$WORK/NEXUS_STATE_DIR/heartbeat"
jq -nc '{
    state:"idle_prompt",
    last_activity:1,
    window:"w_ews",
    external_waits:[{kind:"slurm",id:"5",desc:""}]
}' > "$hb"
run_helper busy w_ews NEXUS_STATE_DIR \
    '{"hook_event_name":"PostToolUse","tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":30}}'
waits=$(jq -c '.external_waits' "$hb" 2>/dev/null)
if [[ "$waits" == '[{"kind":"slurm","id":"5","desc":""}]' ]]; then
    ok "external_waits preserved across ScheduleWakeup PostToolUse"
else
    bad "ScheduleWakeup external_waits preserve" "got=$waits"
fi

# (vi) Fresh heartbeat without prior external_waits emits
# `external_waits: []` (consistent classifier contract — the field
# always exists once a hook has fired).
hb="$WORK/NEXUS_STATE_DIR/heartbeat/w_init.json"
rm -f "$hb"
run_helper busy w_init NEXUS_STATE_DIR '{"hook_event_name":"PostToolUse","tool_name":"Bash"}'
waits=$(jq -c '.external_waits' "$hb" 2>/dev/null)
if [[ "$waits" == "[]" ]]; then
    ok "fresh heartbeat emits external_waits: []"
else
    bad "fresh external_waits" "got=$waits"
fi

echo
echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
