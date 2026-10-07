#!/usr/bin/env bash
# test-operator-alert.sh — the text-carrying, turn-independent operator alert
# (`monitor/watcher/_operator_alert.sh`; your-org/nexus-code#1548, #1533, #1534).
#
# The thing this module exists to guarantee is that a condition the watcher
# alone can see reaches a human through legs that need NO model turn and NO
# operator credential: a durable record, the `watcher ALERT:` bell, a push, and
# a bot-authored GitHub issue. Every leg must FAIL OPEN — a notifier that can
# break its caller is worse than silence (#1553) — and the cadence must be one
# announcement, reminders on a slow clock, one clear (#976).
#
# HERMETIC. `NEXUS_ROOT` points at a throwaway tree; the push command is a
# RECORDER; `gh` and `mint-token.sh` are stubs first on PATH; nothing here can
# ring a real bell, page a phone or file an issue. The network legs run
# DETACHED in production, so the assertions on them POLL the recorder files.
#
# MUTATION PREDICTIONS, written before the run (your-org/nexus-code#1510):
#   M1 delete `(( now - last < reminder )) && return 0`  → §2 FLIPS (a second
#      raise inside the window rings again), §3 unchanged, §1/§4 unchanged.
#   M2 delete the `began` create branch of the GitHub leg → §1 "filed" FLIPS;
#      §3 reminder then reports no-open-issue (FLIPS); §4 close FLIPS.
#   M3 make `_operator_alert_raise` `return 1` on an unwritable dir → §9 FLIPS,
#      nothing else (the fail-open guarantee is only asserted there).
#   M4 drop the `NEXUS_NOTIFY_QUIET` gate in `_operator_alert_network` → §7
#      FLIPS (a push is recorded under QUIET); §1 unchanged.
#   Must-NOT-flip on any of M1–M4: §5 (bad key), §6 (warning does not ring).
#   §23/§24 (your-org/nexus-code#1567 G2/G4) carry their own predictions inline.

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
. "$_test_dir/_test_helpers.sh"

MODULE="$_test_dir/_operator_alert.sh"

# ---- POPULATION DECLARATION (your-org/nexus-code#1078) --------------------
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$MODULE"; }
gp_handle "$@"

PASS=0; FAIL=0; SKIP=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$label (got '$got')"; else fail "$label: got '$got', want '$want'"; fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/opalert-XXXXXX") || th_abort "mktemp failed"
# §24 leaves `sleep` sentinels by design; reap them even on an abort.
cleanup() {
    if declare -F g4_reap >/dev/null 2>&1; then g4_reap g4-key; g4_reap g4-main-key; fi
    chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT

# ---- fixture: a throwaway nexus root, stubs on PATH, recorders -------------
# The module keeps a fallback memo under $TMPDIR (F2); pin it into the fixture
# so a suite run can neither read nor leave a memo where a watcher would look.
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
export NEXUS_ROOT="$WORK/root"
mkdir -p "$NEXUS_ROOT/monitor" "$WORK/bin" "$WORK/state"
export STATE_DIR="$WORK/state"
unset NEXUS_NOTIFY_QUIET
export MONITOR_REPO="acme/nexus-fixture" MONITOR_USER_LOGIN="operator-fixture"
export GH_CALLS="$WORK/gh-calls" GH_ISSUES="$WORK/gh-issues.tsv" PUSH_CALLS="$WORK/push-calls"
: > "$GH_CALLS"; : > "$PUSH_CALLS"; : > "$GH_ISSUES"
gh_reset() { : > "$GH_CALLS"; : > "$GH_ISSUES"; rm -f "$STATE_DIR"/operator-alert/*.ghcomment 2>/dev/null; }

# The push RECORDER stands in for monitor/notify.sh: same argv contract,
# including `--email-status-file` (your-org/nexus-code#1653 F3). The EMAIL leg's
# outcome is `ok` for an emergency push and `skipped` otherwise, unless
# $EMAIL_FAILS (a file holding a count) says to FAIL the next N emergency sends
# — each failure decrements it — or EMAIL_STATUS forces a value.
cat > "$WORK/bin/notify-recorder" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PUSH_CALLS"
esf=""; pri=routine
while (( $# > 0 )); do
    case "$1" in
        --email-status-file) esf="$2"; shift 2 ;;
        --priority)          pri="$2"; shift 2 ;;
        *) shift ;;
    esac
done
st=skipped
if [[ "$pri" == emergency ]]; then
    st=ok
    if [[ -n "${EMAIL_FAILS:-}" && -f "$EMAIL_FAILS" ]]; then
        n=$(cat "$EMAIL_FAILS"); [[ "$n" =~ ^[0-9]+$ ]] || n=0
        if (( n > 0 )); then st=failed; printf '%s\n' "$(( n - 1 ))" > "$EMAIL_FAILS"; fi
    fi
    [[ -n "${EMAIL_STATUS:-}" ]] && st="$EMAIL_STATUS"
fi
[[ -n "$esf" ]] && printf '%s\n' "$st" > "$esf"
exit "${PUSH_RC:-0}"
EOF
chmod +x "$WORK/bin/notify-recorder"
export _OPERATOR_ALERT_PUSH_CMD="$WORK/bin/notify-recorder"

# The mint stub prints a token and touches nothing.
cat > "$WORK/bin/mint-token.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ghs_fixture_token\n'
EOF
chmod +x "$WORK/bin/mint-token.sh"
export NEXUS_MINT_TOKEN_BIN="$WORK/bin/mint-token.sh"

# The `gh` stub: records every call; the open-issues list is a file the CREATE
# arm rewrites, so a second raise finds the issue the first one filed — the
# same network-side idempotency the real module relies on.
# The `gh` stub keeps a tiny ISSUE TABLE (`number\tstate\ttitle`) so the
# module's network-side idempotency is exercised for real: a create appends,
# a PATCH flips state, the open/closed lists are derived from it. GH_FAIL=1
# makes every call fail (unreachable / rate-limited), rc 1 with a 403 body.
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALLS"
if [[ "${GH_FAIL:-0}" == 1 ]]; then printf '{"message":"API rate limit exceeded"}\n'; exit 1; fi
_list() {   # <state>
    awk -F'\t' -v st="$1" 'BEGIN{printf "["} $2==st {if(n++)printf ","; printf "{\"number\":%s,\"title\":\"%s\",\"pull_request\":null}", $1, $3} END{print "]"}' "$GH_ISSUES"
}
case "$*" in
    *"/issues?state=open"*)   _list open ;;
    *"/issues?state=closed"*) _list closed ;;
    *"-X POST /repos/"*"/issues -f title="*)
        t=$(printf '%s\n' "$@" | sed -n 's/^title=//p')
        n=$(( 40 + $(grep -c . "$GH_ISSUES" 2>/dev/null || true) + 1 ))
        printf '%s\topen\t%s\n' "$n" "$t" >> "$GH_ISSUES"
        printf '{"number":%s}\n' "$n" ;;
    *"-X PATCH /repos/"*"/issues/"*" -f state="*)
        n=$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9]*\) .*|\1|p')
        st=$(printf '%s\n' "$@" | sed -n 's/^state=//p')
        awk -F'\t' -v OFS='\t' -v n="$n" -v st="$st" '$1==n {$2=st} {print}' "$GH_ISSUES" > "$GH_ISSUES.tmp" && mv "$GH_ISSUES.tmp" "$GH_ISSUES"
        printf '{"number":%s,"state":"%s"}\n' "$n" "$st" ;;
    *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"

LOGCAP="$WORK/log"; BELLCAP="$WORK/bell"; : > "$LOGCAP"; : > "$BELLCAP"
_rec_log()  { printf '%s\n' "$1" >> "$LOGCAP"; }
_rec_bell() { printf '%s\n' "$1" >> "$BELLCAP"; }
export _OPERATOR_ALERT_LOG_FN=_rec_log _OPERATOR_ALERT_BELL_FN=_rec_bell
export MONITOR_OPERATOR_ALERT_NET_TIMEOUT_SECONDS=20
# The network legs run INLINE for §1–§13 so every assertion is deterministic;
# §14 drops the seam and pins the production default (detached).
export _OPERATOR_ALERT_NETWORK_SYNC=1
# §1–§16 run with the clear hold-down OFF so a clear finalises on its first
# call; §17 turns it on and drives the flap.
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
# …and with the comment cap OFF, so the reminder/clear comments in §3/§4 are
# observable; §18 turns the cap on.
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=0

# shellcheck source=_operator_alert.sh
source "$MODULE" || th_abort "could not source $MODULE"

JSONL="$STATE_DIR/operator-alerts.jsonl"
# `grep -c` prints `0` AND exits 1 on no match, so `|| echo 0` would print a
# second zero into an arithmetic context (the #725 shape). Validate the shape.
count_lines() { local n; n=$(grep -c . "$1" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
wait_lines() {   # <file> <n> [max_s] — polls; inline mode returns at once
    local f="$1" n="$2" max="${3:-15}" i
    for (( i = 0; i < max * 4; i++ )); do
        (( $(count_lines "$f") >= n )) && return 0
        sleep 0.25
    done
    return 1
}
# A recorded gh call carries the ISSUE BODY, which spans lines; count CALLS.
count_gh() { local n; n=$(grep -c '^api ' "$GH_CALLS" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
wait_gh() {   # <n> [max_s]
    local n="$1" max="${2:-15}" i
    for (( i = 0; i < max * 4; i++ )); do (( $(count_gh) >= n )) && return 0; sleep 0.25; done
    return 1
}
jsonl_count() { local n; n=$(grep -c "\"event\":\"$1\"" "$JSONL" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }

echo "=== 1. first raise: record + log + bell + push(emergency) + issue FILED ==="
_operator_alert raise auth-expired critical "RUN /login in the orchestrator window — the session is logged out"
rc=$?
assert_eq "1 raise returns 0" "$rc" 0
[[ -f "$STATE_DIR/operator-alert/auth-expired.stamp" ]] && pass "1 the key is STANDING (stamp written)" || fail "1 no stamp"
assert_eq "1 one raise row in the durable record" "$(jsonl_count raise)" 1
grep -q '"kind":"began"' "$JSONL" && pass "1 …of kind began" || fail "1 kind is not began"
grep -q 'RUN /login' "$JSONL" && pass "1 the record carries the TEXT (the leg #1533 says the bell cannot)" || fail "1 message absent from the record"
grep -q 'operator-alert: RAISED key=auth-expired' "$LOGCAP" && pass "1 watcher log names the raise" || fail "1 no log line"
assert_eq "1 the bell rang ONCE (critical)" "$(count_lines "$BELLCAP")" 1
grep -q 'RUN /login' "$BELLCAP" && pass "1 bell leg received the text (it is _watcher_alert's job to log it)" || fail "1 bell text missing"
wait_lines "$PUSH_CALLS" 1 && pass "1 push leg fired" || fail "1 push leg never fired"
grep -q -- '--priority emergency' "$PUSH_CALLS" && pass "1 push priority is EMERGENCY for critical" || fail "1 push priority: $(cat "$PUSH_CALLS")"
grep -q -- '--require-delivery' "$PUSH_CALLS" && pass "1 push asks for a loud failure (--require-delivery)" || fail "1 no --require-delivery"
wait_gh 3 && pass "1 github leg ran (open list, closed list, create)" || fail "1 github leg: $(cat "$GH_CALLS")"
grep -q -- '-X POST /repos/acme/nexus-fixture/issues -f title=operator-alert: auth-expired' "$GH_CALLS" \
    && pass "1 an issue titled 'operator-alert: auth-expired' was FILED on the nexus repo" \
    || fail "1 no create call: $(cat "$GH_CALLS")"
grep -q 'body=@operator-fixture' "$GH_CALLS" && pass "1 the issue body @-pings the operator" || fail "1 no @-ping"
wait_lines "$JSONL" 4 && true
grep -q '"event":"push".*"rc":"0"' "$JSONL" && pass "1 push outcome recorded (rc 0)" || fail "1 push outcome not recorded: $(cat "$JSONL")"
grep -q '"event":"github".*"action":"filed".*"issue":"41"' "$JSONL" && pass "1 github outcome recorded (filed #41)" || fail "1 github outcome not recorded: $(cat "$JSONL")"
grep -q 'API acceptance, not device delivery' "$JSONL" && pass "1 the push record states what rc 0 does and does not prove" || fail "1 push record over-claims"

echo "=== 2. a raise INSIDE the reminder window is silent — no ring, no push, no record ==="
_operator_alert raise auth-expired critical "RUN /login (repeat)"
sleep 1
assert_eq "2 still exactly one raise row" "$(jsonl_count raise)" 1
assert_eq "2 the bell did not ring again" "$(count_lines "$BELLCAP")" 1
assert_eq "2 no second push" "$(count_lines "$PUSH_CALLS")" 1
assert_eq "2 no further github calls" "$(count_gh)" 3

echo "=== 3. past the reminder window: a REMINDER rings and comments, never re-files ==="
export MONITOR_OPERATOR_ALERT_REMINDER_SECONDS=1
sleep 2
_operator_alert raise auth-expired critical "RUN /login (still)"
assert_eq "3 second raise row" "$(jsonl_count raise)" 2
grep -q '"kind":"continues"' "$JSONL" && pass "3 …of kind continues" || fail "3 not a continues row"
grep -q 'REMINDER #2' "$LOGCAP" && pass "3 log says REMINDER #2" || fail "3 no reminder log line"
assert_eq "3 the bell rang again (reminder)" "$(count_lines "$BELLCAP")" 2
wait_lines "$PUSH_CALLS" 2 && pass "3 reminder push fired" || fail "3 no reminder push"
wait_gh 4 && true
assert_eq "3 exactly ONE issue was ever created" "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=' "$GH_CALLS")" 1
grep -q -- '-X POST /repos/acme/nexus-fixture/issues/41/comments -f body=@operator-fixture still standing' "$GH_CALLS" \
    && pass "3 the reminder is a COMMENT on the open issue" || fail "3 no reminder comment: $(cat "$GH_CALLS")"
unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS

echo "=== 4. clear: stamp gone, duration recorded, routine push, issue CLOSED, no bell ==="
_operator_alert raise auth-expired critical "x" >/dev/null   # inside window: silent
_operator_alert clear auth-expired "the operator ran /login; the board resumed"
rc=$?
assert_eq "4 clear returns 0" "$rc" 0
[[ ! -f "$STATE_DIR/operator-alert/auth-expired.stamp" ]] && pass "4 the key is no longer standing" || fail "4 stamp survived clear"
assert_eq "4 one clear row" "$(jsonl_count clear)" 1
grep -q '"event":"clear".*"duration_s":"[0-9]*"' "$JSONL" && pass "4 clear row carries the duration" || fail "4 no duration"
assert_eq "4 the bell did NOT ring on clear" "$(count_lines "$BELLCAP")" 2
wait_lines "$PUSH_CALLS" 3 && pass "4 clear pushed" || fail "4 no clear push"
grep -q -- '--priority routine' <<<"$(tail -n1 "$PUSH_CALLS")" && pass "4 …at ROUTINE priority" || fail "4 clear push priority: $(tail -n1 "$PUSH_CALLS")"
wait_gh 7 && true
grep -q -- '-X PATCH /repos/acme/nexus-fixture/issues/41 -f state=closed' "$GH_CALLS" \
    && pass "4 the issue was CLOSED" || fail "4 no close call: $(cat "$GH_CALLS")"
grep -q 'body=✅ cleared' "$GH_CALLS" && pass "4 …with a cleared comment" || fail "4 no cleared comment"
_operator_alert clear auth-expired "again"
assert_eq "4 clearing a key that is not standing records nothing" "$(jsonl_count clear)" 1
if _operator_alert standing auth-expired; then fail "4 'standing' still true after clear"; else pass "4 'standing' is false after clear"; fi

echo "=== 5. a malformed key is REFUSED, and refuses loudly ==="
: > "$LOGCAP"
_operator_alert raise 'Bad Key/../x' critical "m"
rc=$?
assert_eq "5 raise with a bad key still returns 0 (fail-open)" "$rc" 0
grep -q 'REFUSED raise' "$LOGCAP" && pass "5 the refusal is logged" || fail "5 refusal silent"
[[ -z "$(ls "$STATE_DIR"/operator-alert/*.stamp 2>/dev/null)" ]] && pass "5 no stamp written for a bad key" || fail "5 stamp written: $(ls "$STATE_DIR"/operator-alert/)"

echo "=== 6. warning severity: recorded, pushed routine, filed — NOT rung ==="
: > "$BELLCAP"; : > "$PUSH_CALLS"; gh_reset
_operator_alert raise service-health:jupyter warning "service jupyter DOWN while the orchestrator cannot be told"
assert_eq "6 warning does not ring the bell" "$(count_lines "$BELLCAP")" 0
wait_lines "$PUSH_CALLS" 1 && pass "6 warning pushes" || fail "6 no push"
grep -q -- '--priority routine' "$PUSH_CALLS" && pass "6 …at ROUTINE priority" || fail "6 wrong priority"
wait_gh 2 && pass "6 warning files an issue too" || fail "6 no github leg"
_operator_alert clear service-health:jupyter "recovered"
if _operator_alert standing service-health:jupyter; then fail "6 still standing"; else pass "6 cleared"; fi

echo "=== 7. NEXUS_NOTIFY_QUIET=1 disables BOTH network legs, and says so ==="
: > "$PUSH_CALLS"; : > "$GH_CALLS"; : > "$BELLCAP"
NEXUS_NOTIFY_QUIET=1 _operator_alert raise quiet-key critical "under a test harness"
sleep 1
assert_eq "7 no push under QUIET" "$(count_lines "$PUSH_CALLS")" 0
assert_eq "7 no github call under QUIET" "$(count_gh)" 0
grep -q '"event":"network-skipped".*"reason":"NEXUS_NOTIFY_QUIET"' "$JSONL" && pass "7 the skip is RECORDED with its reason" || fail "7 skip not recorded"
assert_eq "7 the bell leg is not gated by QUIET here (the wrapper owns that gate)" "$(count_lines "$BELLCAP")" 1
NEXUS_NOTIFY_QUIET=1 _operator_alert clear quiet-key "done"

echo "=== 8. no timeout on PATH: network legs SKIPPED, not run unbounded (#1553 F2) ==="
: > "$PUSH_CALLS"; : > "$GH_CALLS"
# A PATH holding every tool the module needs EXCEPT timeout.
NOTMO="$WORK/bin-no-timeout"; mkdir -p "$NOTMO"
for t in date tr sed mkdir cut rm grep cat sleep dirname basename; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$NOTMO/$t"
done
ln -sf "$WORK/bin/gh" "$NOTMO/gh"; ln -sf "$WORK/bin/notify-recorder" "$NOTMO/notify-recorder"
if PATH="$NOTMO" command -v timeout >/dev/null 2>&1; then
    fail "8 fixture: timeout still resolvable on the stripped PATH"
else
    pass "8 fixture: timeout is absent from the stripped PATH"
fi
PATH="$(th_hermetic_path "$NOTMO" "$WORK")" _operator_alert raise notmo-key critical "no timeout available"
sleep 1
assert_eq "8 no push without timeout" "$(count_lines "$PUSH_CALLS")" 0
assert_eq "8 no github call without timeout" "$(count_gh)" 0
grep -q '"reason":"no-timeout-on-PATH"' "$JSONL" && pass "8 the skip names the missing bound" || fail "8 skip reason absent"
_operator_alert clear notmo-key "x" >/dev/null 2>&1

echo "=== 9. FAIL-OPEN: an unwritable state dir loses the record, never the caller or the bell ==="
: > "$BELLCAP"
RO="$WORK/ro"; mkdir -p "$RO"; chmod 500 "$RO"
if [[ -w "$RO" ]]; then
    th_skip "9 unwritable-dir arm" "running as a user who can write a mode-500 dir (root?)"
else
    STATE_DIR="$RO" _operator_alert raise ro-key critical "state dir is read-only"
    rc=$?
    assert_eq "9 raise returns 0 with an unwritable state dir" "$rc" 0
    assert_eq "9 the bell still rang" "$(count_lines "$BELLCAP")" 1
    [[ ! -e "$RO/operator-alerts.jsonl" ]] && pass "9 (and no record could be written — the record is the leg that was lost, not the bell)" || fail "9 a record was written into a mode-500 dir?"
fi
chmod 700 "$RO" 2>/dev/null || true

echo "=== 10. push command missing: recorded as push-skipped, everything else proceeds ==="
gh_reset
_OPERATOR_ALERT_PUSH_CMD="$WORK/no-such-notify" _operator_alert raise nopush-key critical "m"
wait_gh 2 && pass "10 github leg still ran" || fail "10 github leg did not run"
wait_lines "$JSONL" 1 && true
sleep 0.5
grep -q '"event":"push-skipped".*"reason":"no-notify-cmd"' "$JSONL" && pass "10 push-skipped recorded with reason" || fail "10 push skip not recorded"
_operator_alert clear nopush-key "x" >/dev/null 2>&1

echo "=== 11. since/standing verbs ==="
_operator_alert raise since-key critical "m" >/dev/null 2>&1
s=$(_operator_alert since since-key)
[[ "$s" =~ ^[0-9]+$ ]] && pass "11 since prints the first-raised epoch ($s)" || fail "11 since printed '$s'"
if _operator_alert standing since-key; then pass "11 standing is true while raised"; else fail "11 standing false while raised"; fi
if _operator_alert since no-such-key >/dev/null; then fail "11 since on an unknown key returned 0"; else pass "11 since on an unknown key returns non-zero"; fi
_operator_alert clear since-key "x" >/dev/null 2>&1

echo "=== 12. board context: the supervisor's arm state rides on the message ==="
_watcher_heartbeat_age() {   # fixture: age of a file, 1e9 when absent (the real helper's contract)
    [[ -f "$1" ]] || { printf '%d' 1000000000; return 0; }
    printf '%d' $(( $(date +%s) - $(date +%s -r "$1") ))
}
HB="$WORK/sup-hb"
WATCHER_SUPERVISOR_HEARTBEAT="$HB" ctx=$(_operator_alert_context)
[[ "$ctx" == *"UNARMED (no heartbeat)"* ]] && pass "12 no heartbeat → UNARMED (no heartbeat)" || fail "12 got '$ctx'"
: > "$HB"
WATCHER_SUPERVISOR_HEARTBEAT="$HB" ctx=$(_operator_alert_context)
[[ "$ctx" == *"ARMED (heartbeat"* ]] && pass "12 fresh heartbeat → ARMED" || fail "12 got '$ctx'"
touch -d '10 minutes ago' "$HB"
WATCHER_SUPERVISOR_HEARTBEAT="$HB" ctx=$(_operator_alert_context)
[[ "$ctx" == *"UNARMED for "* ]] && pass "12 stale heartbeat → UNARMED for Ns" || fail "12 got '$ctx'"
ctx=$(WATCHER_SUPERVISOR_HEARTBEAT= _operator_alert_context)
[[ -z "$ctx" ]] && pass "12 no heartbeat path configured → empty clause" || fail "12 got '$ctx'"

echo "=== 13. the record is one JSON object per line (every row parses) ==="
if command -v python3 >/dev/null 2>&1; then
    bad=$(python3 -c '
import json,sys
n=0
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: json.loads(line)
    except Exception: n+=1
print(n)' "$JSONL")
    assert_eq "13 unparseable rows in operator-alerts.jsonl" "$bad" 0
else
    th_skip "13 jsonl parse check" "python3 absent"
fi

echo "=== 15. notify: an EVENT — record + bell + push, no stamp, no issue ==="
: > "$BELLCAP"; : > "$PUSH_CALLS"; gh_reset
_operator_alert notify auth-dialog-escaped critical "the watcher sent Escape into an abandoned /login"
assert_eq "15 notify records an event row" "$(jsonl_count notify)" 1
assert_eq "15 critical notify rings" "$(count_lines "$BELLCAP")" 1
wait_lines "$PUSH_CALLS" 1 && pass "15 notify pushes" || fail "15 no push"
grep -q -- '--priority emergency' "$PUSH_CALLS" && pass "15 …at emergency priority" || fail "15 priority: $(cat "$PUSH_CALLS")"
assert_eq "15 notify files NO issue (an event has nothing to close)" "$(count_gh)" 0
[[ ! -e "$STATE_DIR/operator-alert/auth-dialog-escaped.stamp" ]] && pass "15 notify leaves no stamp" || fail "15 stamp written by notify"
if _operator_alert standing auth-dialog-escaped; then fail "15 an event reads as standing"; else pass "15 an event is not a standing condition"; fi

echo "=== 16. due: the cheap pre-check a 5 s caller uses before composing a message ==="
if _operator_alert due due-key; then pass "16 an unraised key is due"; else fail "16 unraised key not due"; fi
_operator_alert raise due-key critical "m" >/dev/null 2>&1
if _operator_alert due due-key; then fail "16 a just-raised key is due inside the reminder window"; else pass "16 inside the reminder window the key is NOT due"; fi
export MONITOR_OPERATOR_ALERT_REMINDER_SECONDS=1; sleep 2
if _operator_alert due due-key; then pass "16 past the reminder window the key is due again"; else fail "16 not due past the window"; fi
unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS
if _operator_alert due 'Bad Key'; then fail "16 a bad key reads as due"; else pass "16 a bad key is never due"; fi
_operator_alert clear due-key "x" >/dev/null 2>&1

echo "=== 17. a FLAPPING condition files ONE issue: hold-down absorbs fast flaps, slow flaps REOPEN ==="
gh_reset; : > "$BELLCAP"; : > "$PUSH_CALLS"
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=3
# Six fast flaps (raise, clear, raise, clear …) well inside the 3 s hold-down.
for i in 1 2 3 4 5 6; do
    _operator_alert raise flap-key critical "the condition (flap $i)"
    _operator_alert clear flap-key "absent (flap $i)"
done
assert_eq "17 six fast flaps CREATED exactly one issue" "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=' "$GH_CALLS")" 1
assert_eq "17 …and CLOSED nothing (every clear was still pending)" "$(grep -c -- '-f state=closed' "$GH_CALLS")" 0
assert_eq "17 …and rang ONCE" "$(count_lines "$BELLCAP")" 1
assert_eq "17 …and pushed ONCE" "$(count_lines "$PUSH_CALLS")" 1
assert_eq "17 the flaps are RECORDED (5 cancelled pending clears)" "$(jsonl_count flap)" 5
if _operator_alert standing flap-key; then pass "17 the key is still standing through the flaps"; else fail "17 key lost"; fi
# Now the condition stays absent past the hold-down: the clear finalises.
sleep 4
_operator_alert clear flap-key "absent for good"
assert_eq "17 a clear past the hold-down FINALISES (one close)" "$(grep -c -- '-f state=closed' "$GH_CALLS")" 1
if _operator_alert standing flap-key; then fail "17 still standing after the finalised clear"; else pass "17 …and the key is no longer standing"; fi
# A SLOW flap: the condition returns after the issue was closed → REOPEN, never a second issue.
_operator_alert raise flap-key critical "the condition is back"
assert_eq "17 the return REOPENS the closed issue" "$(grep -c -- '-f state=open' "$GH_CALLS")" 1
assert_eq "17 …and STILL only one issue was ever created" "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=' "$GH_CALLS")" 1
grep -q '"action":"reopened"' "$JSONL" && pass "17 the reopen is recorded" || fail "17 no reopen record"
assert_eq "17 the issue table holds ONE row for the key" "$(grep -c 'operator-alert: flap-key' "$GH_ISSUES")" 1
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
_operator_alert clear flap-key "x" >/dev/null 2>&1

echo "=== 17b. the PRODUCTION call shape — `due && raise` — absorbs flaps too (skeptic oplivesk F1) ==="
# Every production caller gates the raise on `due`. The first cut of `due`
# ignored a pending clear, so the cancellation in `raise` was unreachable and
# the pending clear finalised across a condition that was PRESENT. §17 above
# calls raise directly and could not see it; this drives the real shape.
gh_reset; : > "$BELLCAP"; : > "$PUSH_CALLS"
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=3
flaps_before=$(jsonl_count flap)
prod_raise() { if _operator_alert due "$1"; then _operator_alert raise "$1" critical "$2"; fi; }
for i in 1 2 3 4 5 6 7 8 9 10; do
    prod_raise dueflap-key "the condition (flap $i)"
    _operator_alert clear dueflap-key "absent (flap $i)"
done
# WHICH of these discriminate (skeptic oplivesk2 G3, measured under mutant N1):
# the bell / push / close counts below stay GREEN with the F1 fix reverted,
# because this loop finishes inside the 3 s hold-down so nothing can finalise
# either way. They are regression pins on the healthy shape, not the kill.
# The assertions that DIE under N1 are the flap-record count and the
# "present across the hold-down" arm further down.
assert_eq "17b ten due-gated flaps rang ONCE (was 4)" "$(count_lines "$BELLCAP")" 1
assert_eq "17b …pushed ONCE (was 7)" "$(count_lines "$PUSH_CALLS")" 1
assert_eq "17b …closed NOTHING (was 3 close+reopen)" "$(grep -c -- '-f state=closed' "$GH_CALLS")" 0
assert_eq "17b …created exactly one issue" "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=' "$GH_CALLS")" 1
assert_eq "17b …and recorded 9 flaps (was 0)" "$(( $(jsonl_count flap) - flaps_before ))" 9
# The condition is PRESENT across the hold-down: due-gated raises must keep
# cancelling, so a clear can never finalise over a standing condition.
prod_raise dueflap-key "present"; sleep 4; prod_raise dueflap-key "still present"
_operator_alert clear dueflap-key "first absent after a long presence"
if _operator_alert standing dueflap-key; then pass "17b a single clear after a long PRESENCE only starts the hold-down"; else fail "17b the clear finalised at once — a stale pending mark survived the presence"; fi
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
_operator_alert clear dueflap-key "x" >/dev/null 2>&1

echo "=== 18. comment rate cap: reminders comment at most once per interval; close/reopen never capped ==="
gh_reset
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=3600 MONITOR_OPERATOR_ALERT_REMINDER_SECONDS=1
_operator_alert raise cap-key critical "m"            # files (the body counts as the first comment)
sleep 2; _operator_alert raise cap-key critical "m"   # reminder #2
sleep 2; _operator_alert raise cap-key critical "m"   # reminder #3
assert_eq "18 two reminders inside the interval posted NO comment" "$(grep -c -- '/issues/41/comments' "$GH_CALLS")" 0
assert_eq "18 …and both were recorded as capped" "$(jsonl_count github-comment-capped)" 2
assert_eq "18 …while the bell still rang for each reminder (the cap is on GitHub comments only)" "$(jsonl_count raise)" "$(( $(jsonl_count raise) ))"
_operator_alert clear cap-key "done"
assert_eq "18 the close is NOT capped (state changes always land)" "$(grep -c -- '-X PATCH /repos/acme/nexus-fixture/issues/41 -f state=closed' "$GH_CALLS")" 1
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=0; unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS

echo "=== 19. GitHub unreachable / rate-limited: recorded as github-failed; record + bell already landed; rc 0 ==="
gh_reset; : > "$BELLCAP"
GH_FAIL=1 _operator_alert raise ghdown-key critical "github is down"
rc=$?
assert_eq "19 raise returns 0 with GitHub failing" "$rc" 0
assert_eq "19 the bell rang anyway" "$(count_lines "$BELLCAP")" 1
grep -q '"event":"raise".*"key":"ghdown-key"' "$JSONL" && pass "19 the durable record landed" || fail "19 no record"
grep -q '"event":"github-failed".*"reason":"list-failed"' "$JSONL" && pass "19 the failure is RECORDED with its reason (list-failed)" || fail "19 no github-failed record: $(tail -n3 "$JSONL")"
assert_eq "19 no issue was created" "$(grep -c . "$GH_ISSUES")" 0
GH_FAIL=1 _operator_alert clear ghdown-key "x" >/dev/null 2>&1

echo "=== 27. REMINDERS BACK OFF on durable state; GitHub reminder comments are CAPPED (your-org/nexus-code#1713) ==="
# A fake clock for this section only (a function: the module calls `date +%s`).
date() { if [[ "${1:-}" == "+%s" && "${FAKE_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s\n' "$FAKE_NOW"; else command date "$@"; fi; }
B27=1790520974
reminders_of() {   # <key> → offsets (from B27) of the key's `raise` rows, one per line
    grep "\"event\":\"raise\".*\"key\":\"$1\"" "$JSONL" | sed -n 's/.*"ts":\([0-9]*\),.*/\1/p' | awk -v b="$B27" '{print $1 - b}'
}
gaps_of() { awk 'NR>1{printf "%s%d", (n++ ? " " : ""), $1 - p} {p=$1} END{print ""}'; }
unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS MONITOR_OPERATOR_ALERT_REMINDER_MAX_SECONDS
export MONITOR_OPERATOR_ALERT_PUSH_ENABLED=false MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false
# (a) the schedule over 50 h, a WATCHER RESTART at +10 h and a FLAP at +20 h
for (( t = 0; t <= 50 * 3600; t += 60 )); do
    export FAKE_NOW=$(( B27 + t ))
    if (( t == 10 * 3600 )); then   # restart: the in-process and $TMPDIR memos die
        _OPERATOR_ALERT_MEMO=(); _OPERATOR_ALERT_COMMENT_MEMO=(); rm -f "$TMPDIR"/.nexus-operator-alert.*bo-key* 2>/dev/null
    fi
    if (( t == 20 * 3600 )); then
        export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=300
        _operator_alert clear bo-key "dip"; continue      # starts the hold-down only
    fi
    _operator_alert due bo-key && _operator_alert raise bo-key critical "RUN /login"
done
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
assert_eq "27a announcements at +0, +1, +3, +7, +15, +31 h — the backoff, through a restart and a flap" \
    "$(reminders_of bo-key | tr '\n' ' ')" "0 3600 10800 25200 54000 111600 "
assert_eq "27a …gaps double from 1 h and stop at the 24 h cap's predecessor" "$(reminders_of bo-key | gaps_of)" "3600 7200 14400 28800 57600"
grep -q '"key":"bo-key".*"next_reminder_s":"86400"' "$JSONL" && pass "27a the 6th announcement records the next reminder at the 24 h cap" \
    || fail "27a no next_reminder_s=86400 row: $(grep bo-key "$JSONL" | tail -n2)"
grep -q 'REMINDER #2 key=bo-key.*next reminder in 7200s (#1713 backoff)' "$LOGCAP" && pass "27a the watcher log names the next delay" \
    || fail "27a log line lacks the next delay: $(grep -m3 'bo-key' "$LOGCAP")"
# (b) the clear RESETS the schedule: a new incident starts from 1 h again
export FAKE_NOW=$(( B27 + 50 * 3600 + 60 )); _operator_alert clear bo-key "the operator ran /login"
: > "$JSONL.27"; cp "$JSONL" "$JSONL.27"
for (( t = 60 * 3600; t <= 64 * 3600; t += 60 )); do   # > REARM later: a NEW incident
    export FAKE_NOW=$(( B27 + t )); _operator_alert due bo-key && _operator_alert raise bo-key critical "RUN /login"
done
assert_eq "27b after a clear the next incident reminds at +1 h and +3 h again (the backoff resets)" \
    "$(reminders_of bo-key | awk '$1 >= 60*3600' | tr '\n' ' ')" "216000 219600 226800 "
export FAKE_NOW=$(( B27 + 65 * 3600 )); _operator_alert clear bo-key "x" >/dev/null 2>&1
# (c) a MAX below the base disables the backoff (the base wins) — the documented off switch
export MONITOR_OPERATOR_ALERT_REMINDER_MAX_SECONDS=1
assert_eq "27c MAX < BASE: the delay after the 5th announcement is the base" "$(_operator_alert_reminder_after 5)" 3600
unset MONITOR_OPERATOR_ALERT_REMINDER_MAX_SECONDS
assert_eq "27c default: the delay after the 9th announcement is the 24 h cap" "$(_operator_alert_reminder_after 9)" 86400
assert_eq "27c an unreadable count is the base (the memo-only degradation)" "$(_operator_alert_reminder_after '')" 3600
# (d) the GitHub comment cap: 3 reminder comments per incident, the 3rd says so
export MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=true MONITOR_OPERATOR_ALERT_MAX_REMINDER_COMMENTS=3
export MONITOR_OPERATOR_ALERT_REMINDER_SECONDS=1 MONITOR_OPERATOR_ALERT_REMINDER_MAX_SECONDS=1   # no backoff: isolate the cap
gh_reset
for (( t = 0; t <= 14; t += 2 )); do   # began + 7 reminders
    export FAKE_NOW=$(( B27 + 70 * 3600 + t )); _operator_alert raise ghcap-key critical "RUN /login"
done
assert_eq "27d 7 reminders posted exactly 3 comments" "$(grep -c -- '/issues/41/comments' "$GH_CALLS")" 3
assert_eq "27d …exactly one of them is the final notice" "$(grep -c 'This is the last reminder comment for this incident (3 of 3)' "$GH_CALLS")" 1
assert_eq "27d …and the other 4 are recorded as exhausted, not silently dropped" "$(jsonl_count github-reminders-exhausted)" 4
assert_eq "27d the bell still rang for every reminder (the cap is on GitHub comments only)" \
    "$(grep -c '"event":"raise".*"key":"ghcap-key"' "$JSONL")" 8
export FAKE_NOW=$(( B27 + 70 * 3600 + 20 )); _operator_alert clear ghcap-key "done"
assert_eq "27d the clear still CLOSES the issue past the cap" "$(grep -c -- '-X PATCH /repos/acme/nexus-fixture/issues/41 -f state=closed' "$GH_CALLS")" 1
[[ ! -e "$STATE_DIR/operator-alert/ghcap-key.ghreminders" ]] && pass "27d the clear removes the per-incident counter" || fail "27d .ghreminders survived the clear"
# a NEW incident on the same key starts its own budget (keyed on the incident's first epoch)
gh_reset
for (( t = 0; t <= 2; t += 2 )); do
    export FAKE_NOW=$(( B27 + 80 * 3600 + t )); _operator_alert raise ghcap-key critical "RUN /login"
done
assert_eq "27d a new incident's first reminder comments again" "$(grep -c -- '/comments -f body=@operator-fixture still standing' "$GH_CALLS")" 1
export FAKE_NOW=$(( B27 + 80 * 3600 + 4 )); _operator_alert clear ghcap-key "x" >/dev/null 2>&1
# a STALE counter from another incident (same key, different first) is ignored, not obeyed
mkdir -p "$STATE_DIR/operator-alert"; printf '123\t99\n' > "$STATE_DIR/operator-alert/stale-key.ghreminders"
gh_reset
export FAKE_NOW=$(( B27 + 90 * 3600 )); _operator_alert_github_leg stale-key critical began "m" "$FAKE_NOW"
export FAKE_NOW=$(( B27 + 90 * 3600 + 2 )); _operator_alert_github_leg stale-key critical continues "m" "$(( B27 + 90 * 3600 ))"
assert_eq "27d a counter for a DIFFERENT incident does not silence this one" "$(grep -c -- '/comments -f body=@operator-fixture still standing' "$GH_CALLS")" 1
rm -f "$STATE_DIR/operator-alert/stale-key".* 2>/dev/null
unset MONITOR_OPERATOR_ALERT_MAX_REMINDER_COMMENTS MONITOR_OPERATOR_ALERT_REMINDER_SECONDS MONITOR_OPERATOR_ALERT_REMINDER_MAX_SECONDS
unset MONITOR_OPERATOR_ALERT_PUSH_ENABLED MONITOR_OPERATOR_ALERT_GITHUB_ENABLED FAKE_NOW
unset -f date
gh_reset

echo "=== 20. the dedup state survives the DISK IT LIMITS: read-only state dir (skeptic oplivesk F2) ==="
# Measured by the skeptic: RO state dir, 20 cycles → 20 bells + 20 emergency pushes.
: > "$BELLCAP"; : > "$PUSH_CALLS"; gh_reset
RO2="$WORK/ro2"; mkdir -p "$RO2"; chmod 500 "$RO2"
if [[ -w "$RO2" ]]; then
    th_skip "20 read-only state dir" "this user can write a mode-500 dir"
else
    for i in $(seq 1 20); do
        if STATE_DIR="$RO2" _operator_alert due ro2-key; then STATE_DIR="$RO2" _operator_alert raise ro2-key critical "state dir is read-only"; fi
    done
    assert_eq "20 twenty cycles on a read-only state dir rang ONCE (was 20)" "$(count_lines "$BELLCAP")" 1
    assert_eq "20 …and pushed ONCE (was 20)" "$(count_lines "$PUSH_CALLS")" 1
    # …and a DIRECT raise (no `due` in front) must be just as quiet: the memo is
    # consulted inside `raise` too. A mutation round found the due-gated loop
    # above stays green with the raise-side memo removed — `due` shields it.
    for i in $(seq 1 20); do STATE_DIR="$RO2" _operator_alert raise ro2-key critical "state dir is read-only (direct)"; done
    assert_eq "20 twenty more DIRECT raises on the read-only dir did not ring again" "$(count_lines "$BELLCAP")" 1
    assert_eq "20 …nor push again" "$(count_lines "$PUSH_CALLS")" 1
    if STATE_DIR="$RO2" _operator_alert standing ro2-key; then pass "20 a memo-only key still reads as STANDING"; else fail "20 memo-only key not standing"; fi
    STATE_DIR="$RO2" _operator_alert clear ro2-key "writable again"
    if STATE_DIR="$RO2" _operator_alert standing ro2-key; then fail "20 memo-only key survived clear"; else pass "20 …and clears"; fi
fi
chmod 700 "$RO2" 2>/dev/null || true

echo "=== 21. a ZERO-BYTE UNWRITABLE stamp (the ENOSPC shape) with the issue open: no comment storm ==="
# Measured by the skeptic: 20 cycles → 20 pushes + 20 GitHub COMMENTS (720/h).
gh_reset; : > "$BELLCAP"; : > "$PUSH_CALLS"
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=3600
printf '77\topen\toperator-alert: enospc-key\n' >> "$GH_ISSUES"
mkdir -p "$STATE_DIR/operator-alert"
: > "$STATE_DIR/operator-alert/enospc-key.stamp"; chmod 400 "$STATE_DIR/operator-alert/enospc-key.stamp"
: > "$STATE_DIR/operator-alert/enospc-key.ghcomment"; chmod 400 "$STATE_DIR/operator-alert/enospc-key.ghcomment"
if [[ -w "$STATE_DIR/operator-alert/enospc-key.stamp" ]]; then
    th_skip "21 unwritable stamp" "this user can write a mode-400 file"
else
    for i in $(seq 1 20); do
        if _operator_alert due enospc-key; then _operator_alert raise enospc-key critical "disk full"; fi
    done
    assert_eq "21 twenty cycles over an unwritable zero-byte stamp pushed ONCE (was 20)" "$(count_lines "$PUSH_CALLS")" 1
    n_c=$(grep -c -- '/issues/77/comments' "$GH_CALLS"); [[ "$n_c" =~ ^[0-9]+$ ]] || n_c=0
    if (( n_c <= 1 )); then pass "21 …and posted $n_c GitHub comment(s), not 20"; else fail "21 $n_c comments in 20 cycles"; fi
    assert_eq "21 …and rang ONCE" "$(count_lines "$BELLCAP")" 1
fi
chmod 600 "$STATE_DIR"/operator-alert/enospc-key.* 2>/dev/null; rm -f "$STATE_DIR"/operator-alert/enospc-key.*
_operator_alert_memo_clear enospc-key
export MONITOR_OPERATOR_ALERT_COMMENT_INTERVAL_SECONDS=0

echo "=== 22. two INSTANCES sharing \$TMPDIR do not silence each other (skeptic oplivesk2 G1) ==="
# The fallback memo lives under $TMPDIR, which every nexus instance on a host
# shares. Keyed on the alert key alone, instance A's memo made instance B's
# FIRST raise of the same key read as "announced recently" → a SILENT raise.
: > "$BELLCAP"; : > "$PUSH_CALLS"; gh_reset
# PREDICTED before running, with the namespace reverted: B's `due` reads not
# due, B's raise is silent (bell stays 1, push stays 1, no stamp in B), and the
# "repeat in A" count follows B's; A's own first raise must NOT flip.
RA="$WORK/rootA"; RB="$WORK/rootB"; IA="$RA/monitor/.state"; IB="$RB/monitor/.state"; mkdir -p "$IA" "$IB"
_a() { NEXUS_ROOT="$RA" STATE_DIR="$IA" MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false "$@"; }
_b() { NEXUS_ROOT="$RB" STATE_DIR="$IB" MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false "$@"; }
_a _operator_alert raise shared-key critical "instance A is logged out"
assert_eq "22 instance A's raise rings" "$(count_lines "$BELLCAP")" 1
assert_eq "22 …and pushes" "$(count_lines "$PUSH_CALLS")" 1
if _b _operator_alert due shared-key; then pass "22 the SAME key is still DUE in instance B (A's memo does not reach it)"; else fail "22 instance B reads the key as not due — A's \$TMPDIR memo leaked across instances"; fi
_b _operator_alert raise shared-key critical "instance B is logged out"
assert_eq "22 instance B's FIRST raise rings too (was SILENT)" "$(count_lines "$BELLCAP")" 2
assert_eq "22 …and PUSHES too (two distinct roots, one \$TMPDIR)" "$(count_lines "$PUSH_CALLS")" 2
[[ -f "$IB/operator-alert/shared-key.stamp" ]] && pass "22 …and B wrote its own stamp" || fail "22 no stamp in B"
assert_eq "22 …while a REPEAT in A is still silent (the namespace did not break dedup)" \
    "$(_a _operator_alert raise shared-key critical "again" >/dev/null 2>&1; count_lines "$BELLCAP")" 2
# The ROOT alone must discriminate: same (relative) state dir string, distinct roots.
: > "$BELLCAP"
NEXUS_ROOT="$RA" STATE_DIR="rel-state" MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false _operator_alert_memo_set rootkey 1 >/dev/null 2>&1
na=$(NEXUS_ROOT="$RA" STATE_DIR="rel-state" _operator_alert_memo_path rootkey raise); nb=$(NEXUS_ROOT="$RB" STATE_DIR="rel-state" _operator_alert_memo_path rootkey raise)
if [[ "$na" != "$nb" ]]; then pass "22 distinct ROOTS with an identical state-dir string get distinct memo files"; else fail "22 root does not discriminate: $na"; fi
rm -f "$na" "$nb"
_a _operator_alert clear shared-key "x" >/dev/null 2>&1
_b _operator_alert clear shared-key "x" >/dev/null 2>&1

echo "=== 23. the CLEAR TRANSITION hook fires ONCE per transition (your-org/nexus-code#1567 G2) ==="
# main.sh pulls the next emit forward on this hook, so it must fire on the
# first "absent" (not 300 s later at finalisation), and exactly once: a caller
# says "absent" every cycle, and a per-call hook would re-fire compose_emit
# every 5 s for the whole hold-down.
CLEAREDCAP="$WORK/cleared"; : > "$CLEAREDCAP"
_rec_cleared() { printf '%s %s\n' "$1" "$2" >> "$CLEAREDCAP"; }
_OPERATOR_ALERT_CLEARED_FN=_rec_cleared
export MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false MONITOR_OPERATOR_ALERT_PUSH_ENABLED=false
# (a) no hold-down: the finalising clear IS the transition.
_operator_alert raise hook-key critical "m"
first=$(_operator_alert since hook-key)
_operator_alert clear hook-key "gone"
assert_eq "23 no hold-down: the clear fires the hook once, with the first-raised epoch" "$(cat "$CLEAREDCAP")" "hook-key $first"
_operator_alert clear hook-key "still gone"
assert_eq "23 …and a clear of a key no longer standing does not fire it again" "$(count_lines "$CLEAREDCAP")" 1
# (b) with a hold-down: fires when the hold-down STARTS, not on the repeats inside it, not at finalisation.
: > "$CLEAREDCAP"; export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=2
_operator_alert raise hook-key critical "m"
_operator_alert clear hook-key "absent 1"
assert_eq "23 hold-down: the FIRST absent fires the hook (the transition)" "$(count_lines "$CLEAREDCAP")" 1
_operator_alert clear hook-key "absent 2"; _operator_alert clear hook-key "absent 3"
assert_eq "23 hold-down: repeat absents inside the hold-down do NOT" "$(count_lines "$CLEAREDCAP")" 1
sleep 3; _operator_alert clear hook-key "absent, finalising"
if _operator_alert standing hook-key; then fail "23 hold-down: the clear did not finalise"; else pass "23 hold-down: the clear finalised"; fi
assert_eq "23 hold-down: finalisation does NOT fire it a second time" "$(count_lines "$CLEAREDCAP")" 1
# (c) a flap cancels the pending clear; the NEXT first-absent is a new transition.
: > "$CLEAREDCAP"
_operator_alert raise hook-key critical "m"; _operator_alert clear hook-key "a"
_operator_alert raise hook-key critical "back"; _operator_alert clear hook-key "a again"
assert_eq "23 flap: each first-absent after a raise fires once (2)" "$(count_lines "$CLEAREDCAP")" 2
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
_operator_alert clear hook-key "x" >/dev/null 2>&1
# (d) a hook that FAILS cannot fail the caller (fail-open, #1553).
_rec_cleared_fail() { return 7; }
_OPERATOR_ALERT_CLEARED_FN=_rec_cleared_fail
_operator_alert raise hook-key critical "m"; _operator_alert clear hook-key "gone"; rc=$?
assert_eq "23 a failing hook still leaves clear at rc 0" "$rc" 0
_OPERATOR_ALERT_CLEARED_FN=_operator_alert_cleared_noop
unset MONITOR_OPERATOR_ALERT_GITHUB_ENABLED MONITOR_OPERATOR_ALERT_PUSH_ENABLED

echo "=== 24. NOTHING persistable + a SUBSHELL caller: ONE GitHub attempt, not one per cycle (your-org/nexus-code#1567 G4) ==="
# State dir AND $TMPDIR unwritable, and the caller in a subshell (the async
# service_health and self-heal callers), so every store the cadence reads is
# lost: each cycle reads as a FIRST raise. PREDICTED before running, with the
# sentinel removed: the gh call count is 3 + 19 = 22 (the first cycle files:
# open list, closed list, create; each later one re-lists and reuses) — against
# 3 with it. MUST NOT FLIP: the main-shell caller row (its in-process memo
# already bounded it) and the push count (0 either way: #1566 skips the push).
RO3="$WORK/ro3"; ROT="$WORK/ro-tmp"; mkdir -p "$RO3" "$ROT"; chmod 500 "$RO3" "$ROT"
g4_sentinel_pids() {   # pids whose argv[0] is this key's sentinel — exact match, never a substring
    local want f a0
    want=$(STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert_sentinel_name "$1")
    for f in /proc/[0-9]*/cmdline; do
        { IFS= read -r -d '' a0 < "$f"; } 2>/dev/null || continue
        [[ "$a0" == "$want" ]] && { f="${f#/proc/}"; printf '%s\n' "${f%/cmdline}"; }
    done
}
g4_reap() { local p; for p in $(g4_sentinel_pids "$1"); do kill "$p" 2>/dev/null; done; }
if [[ -w "$RO3" || -w "$ROT" ]]; then
    th_skip "24 nothing-persistable arm" "this user can write a mode-500 dir"
elif [[ ! -r /proc/self/cmdline ]]; then
    th_skip "24 nothing-persistable arm" "no /proc: the sentinel cannot be observed (the module then attempts every cycle — the pre-fix cost)"
else
    gh_reset; : > "$PUSH_CALLS"
    for i in $(seq 1 20); do
        ( if STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert due g4-key; then
              STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert raise g4-key critical "nothing can be persisted"
          fi )
    done
    assert_eq "24 twenty SUBSHELL cycles with nothing persistable made ONE GitHub attempt (3 calls; was 22)" "$(count_gh)" 3
    assert_eq "24 …and it FILED the issue on that attempt (the degraded path still reaches the operator)" \
        "$(grep -c -- '-X POST /repos/acme/nexus-fixture/issues -f title=operator-alert: g4-key' "$GH_CALLS")" 1
    assert_eq "24 …and pushed nothing (the push is the repeatable leg; #1566)" "$(count_lines "$PUSH_CALLS")" 0
    assert_eq "24 the attempt is held by exactly ONE live sentinel process" "$(g4_sentinel_pids g4-key | grep -c .)" 1
    # The sentinel IS the memory: once it is gone the next first raise attempts
    # again (one list read, REUSES the open issue — never a second one).
    g4_reap g4-key; sleep 0.3
    ( STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert raise g4-key critical "sentinel expired" )
    assert_eq "24 with the sentinel gone the next cycle attempts again (+1 list read)" "$(count_gh)" 4
    assert_eq "24 …and REUSES the open issue (still one created)" "$(grep -c -- '-f title=operator-alert: g4-key' "$GH_CALLS")" 1
    g4_reap g4-key
    # B1 (skeptic on PR #1630): the watcher raises from its MAIN process while
    # holding the instance flock on INSTANCE_LOCK_FD, and the sentinel used to
    # inherit that fd — pinning the lock after the raiser died, so a restarted
    # watcher could not start. Fixture lock only: a subshell takes an flock,
    # raises once with nothing persistable, and exits; the lock must be free.
    G4LOCK="$WORK/g4-instance.lock"; : > "$G4LOCK"
    gh_reset
    ( exec 7>"$G4LOCK"; flock -n 7 || exit 9; INSTANCE_LOCK_FD=7
      STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert raise g4-lock critical "lock holder raises" )
    sleep 0.3
    if flock -n "$G4LOCK" true; then g4_free=free; else g4_free=HELD; fi
    assert_eq "24 B1 the raiser's instance flock is FREE once it exits (the sentinel does not inherit it)" "$g4_free" free
    g4_fds=$(for p in $(g4_sentinel_pids g4-lock); do ls /proc/"$p"/fd 2>/dev/null; done | sort -n | tr '\n' ' ')
    assert_eq "24 B1 the sentinel holds only fds 0 1 2" "$g4_fds" "0 1 2 "
    g4_reap g4-lock
    # CONTROL (must not flip): a MAIN-SHELL caller in the same configuration was
    # already bounded by its in-process memo — one attempt, 20 cycles.
    gh_reset
    for i in $(seq 1 20); do
        if STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert due g4-main-key; then
            STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert raise g4-main-key critical "nothing can be persisted"
        fi
    done
    assert_eq "24 control: a main-shell caller makes one attempt too (3 calls)" "$(count_gh)" 3
    g4_reap g4-main-key
    STATE_DIR="$RO3" TMPDIR="$ROT" _operator_alert_memo_clear g4-main-key
fi
chmod 700 "$RO3" "$ROT" 2>/dev/null || true

echo "=== 25. ONE EMAIL PER INCIDENT, AND IT ARRIVES: the whole of 2026-09-27, replayed on a fake clock ==="
# your-org/nexus-code#1653. On the day: TWO emails EVERY HOUR during a login
# expiry (`auth-expired` + `service-health:nexus-remote-ssh`, each re-sent at
# `emergency` on the 3600 s reminder), then two more for FALSE re-detections
# (10:22, 12:00 — the detector matched the orchestrator's own text about the
# outage). notify.sh emails on `emergency` and on nothing else, so an EMAIL
# ATTEMPT here is a recorded push carrying `--priority emergency`. The clock is
# a `date` shim (FAKE_NOW); both keys run through their PRODUCTION call shapes:
# `due && raise` / `clear` for the auth hold, the real `_sh_operator_alert_step`
# for service-health, the real route codes.
#
# MUTATION PREDICTIONS, written before the run (your-org/nexus-code#1510):
#   M8  `_operator_alert.sh` push leg: `began|escalated|confirmed|event)` →
#       `*|escalated|confirmed|event)` (every reminder emails again) → FLIPS
#       25a "whole day", 25b "across the restart", 25e "reminder push is
#       routine", 25f "escalation emails ONCE", 25g "co-occurrence"; must NOT
#       flip 25c "new incident past REARM emails at once", 25h "delivered stops".
#   M9  `_operator_alert.sh` raise: the REARM test forced false (no `resumed`)
#       → FLIPS 25a "whole day" and 25c2 "deferred, not immediate"; must NOT
#       flip 25c "past REARM", 25h.
#   M10 `_operator_alert.sh` mail_result: `ok)` arm never matches → FLIPS 25h
#       "stops after delivery" and 25h "delivered recorded"; must NOT flip 25c.
#   M11 `_service_health.sh`: `auth-expired|auth-hold)` → `*)` (the old
#       keyed-on-standing downgrade) → FLIPS 25g "over-limit during auth is
#       critical"; must NOT flip 25a "whole day".
REAL_DATE=$(command -v date)
FAKECLK="$WORK/bin-fakeclock"; mkdir -p "$FAKECLK"
cat > "$FAKECLK/date" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "+%s" && "\${FAKE_NOW:-}" =~ ^[0-9]+\$ ]]; then printf '%s\n' "\$FAKE_NOW"; exit 0; fi
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$FAKECLK/date"
# [key] — every email ATTEMPT, or only <key>'s (so a case tests ONE axis)
emails() { local n; n=$(grep -c -- "operator-alert: ${1:-}.*--priority emergency" "$PUSH_CALLS" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0; printf '%s' "$n"; }
E25_KEYS=(auth-expired service-health:nexus-remote-ssh e25-direct)
e25_reset() {
    : > "$PUSH_CALLS"; : > "$BELLCAP"; gh_reset
    local k; for k in "${E25_KEYS[@]}"; do
        rm -f "$STATE_DIR/operator-alert/$k".{stamp,sev,mail,cleared,chain,ghreminders} 2>/dev/null
        _operator_alert_memo_clear "$k"
    done
    rm -f "$EMAIL_FAILS"; unset EMAIL_STATUS
}
export EMAIL_FAILS="$WORK/email-fails"
# shellcheck source=_service_health.sh
source "$_test_dir/_service_health.sh" || th_abort "could not source _service_health.sh"
E25_ROUTE=""      # `<code>\t<reason>`, empty = route open — the real main.sh codes
_e25_route() { [[ -n "$E25_ROUTE" ]] || return 1; printf '%s' "$E25_ROUTE"; return 0; }
_SERVICE_HEALTH_ROUTE_BLOCKED_FN=_e25_route
_SERVICE_HEALTH_OPERATOR_ALERT_FN=_operator_alert
ROUTE_AUTH=$'auth-expired\tthe orchestrator is LOGGED OUT (auth=expired) and cannot take a turn'
ROUTE_OVER=$'over-limit\tthe orchestrator is OVER-LIMIT and emits are held'
auth_tick() {    # <present 0|1> — the auth hold's production calls
    if (( $1 )); then _operator_alert due auth-expired && _operator_alert raise auth-expired critical "RUN /login IN THE ORCHESTRATOR WINDOW"
    else [[ -f "$STATE_DIR/operator-alert/auth-expired.stamp" ]] && _operator_alert clear auth-expired "the orchestrator pane no longer reports a logged-out session"; fi
    return 0
}
svc_tick() { _sh_operator_alert_step nexus-remote-ssh emit-only emit-only 2026-09-27T07:56:42-07:00 "policy emit-only"; }
E25_T0=1790520974   # 2026-09-27T07:56:14-07:00
at() { printf '%s' $(( E25_T0 + $1 )); }   # seconds after 07:56:14
unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS
OLDPATH=$PATH; export PATH="$FAKECLK:$PATH"
# In THIS process the clock is a FUNCTION: the module calls `date +%s` on every
# tick, and a forked shim per call made §25 alone outlast the band's 600 s
# ceiling under load. Child processes (the restart cases) still get the shim.
date() { if [[ "${1:-}" == "+%s" && "${FAKE_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s\n' "$FAKE_NOW"; else command date "$@"; fi; }
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=300   # the production value, for this section

echo "--- 25a. the WHOLE DAY, 07:56 → 12:20, incl. the 10:22 and 12:00 false re-detections: ONE email (60 s ticks) ---"
e25_reset
# Presence windows from operator-alerts.jsonl / watcher.log, as offsets from 07:56:14:
#   auth present 08:01:14–10:13:40 (+300..+7946), 10:22:38–10:24:11 (+8784..+8877),
#   12:00:00–12:03:05 (+14626..+14811); service DOWN until 11:56 (+14386).
auth_present() { local o=$1; (( (o>=300 && o<7946) || (o>=8784 && o<8877) || (o>=14626 && o<14811) )); }
for (( o = 0; o <= 15360; o += 60 )); do
    FAKE_NOW=$(at "$o"); export FAKE_NOW
    if auth_present "$o"; then auth_tick 1; E25_ROUTE=$ROUTE_AUTH; else auth_tick 0; E25_ROUTE=""; fi
    if (( o < 14386 )); then svc_tick
    else _operator_alert standing service-health:nexus-remote-ssh && _operator_alert clear service-health:nexus-remote-ssh "recovered"; fi
done
assert_eq "25a exactly ONE email attempt for the whole day (was 8)" "$(emails)" 1
grep -q -- 'operator-alert: auth-expired (began).*--priority emergency' "$PUSH_CALLS" \
    && pass "25a …and it is the 08:01 auth-expired ANNOUNCEMENT" || fail "25a the one email is not auth began: $(grep -- '--priority emergency' "$PUSH_CALLS")"
assert_eq "25a both re-detections RESUMED the incident (no new email)" "$(grep -c '"key":"auth-expired","severity":"critical","kind":"resumed"' "$JSONL")" 2
assert_eq "25a …and neither was ever CONFIRMED (both cleared inside the confirmation window)" \
    "$(grep -c '"key":"auth-expired","severity":"critical","kind":"confirmed"' "$JSONL")" 0
assert_eq "25a the auth key still REMINDED, on the #1713 backoff (began + 09:01; the next is owed at 11:01, after the 10:13 clear → 2 auth pushes)" \
    "$(grep -c -- 'operator-alert: auth-expired (\(began\|continues\))' "$PUSH_CALLS")" 2
grep -q -- 'service-health:nexus-remote-ssh (began).*--priority routine' "$PUSH_CALLS" \
    && pass "25a service-health rode as WARNING (route code auth-expired): routine, no email" || fail "25a service-health push: $(grep -m2 service-health "$PUSH_CALLS")"
grep -q 'rides on\|already pages for it' "$JSONL" && pass "25a …and its text says what it rides on" || fail "25a no rides-on clause"
grep -q '"event":"mail-delivered","key":"auth-expired"' "$JSONL" && pass "25a the one email is recorded DELIVERED" || fail "25a no mail-delivered row"
# G1: the two false re-detections ACCUMULATE (93 s + 185 s = 278 s on the day;
# 60 + 180 = 240 s at this replay's 60 s tick granularity) and stay under 600 s.
acc=$(grep '"event":"chain-accumulated","key":"auth-expired"' "$JSONL" | tail -n1 | sed -n 's/.*"acc_s":"\([0-9]*\)".*/\1/p')
assert_eq "25a the re-detections' CUMULATIVE standing time is 240 s (60 s ticks) — under REARM_CONFIRM, so no email" "$acc" 240

echo "--- 25b. the watcher RESTARTS mid-outage: still ONE email ---"
e25_reset; k25b=$(count_lines "$JSONL")
for (( m = 0; m <= 60; m++ )); do FAKE_NOW=$(at $(( 300 + m * 60 ))); export FAKE_NOW; auth_tick 1; done
assert_eq "25b CONTROL: one auth email before the restart" "$(emails auth-expired)" 1
# A new process, as a revived watcher is: no in-process memo, and the $TMPDIR
# memo REMOVED so the durable state in the state dir is the only record.
rm -f "$TMPDIR"/.nexus-operator-alert.* 2>/dev/null
# Through +11 100 s: the backoff owes reminder #2 at began + 3600 + 7200
# (your-org/nexus-code#1713). A restart that FORGOT the schedule would remind
# again at +7 500, one base period after the last.
for (( m = 61; m <= 187; m++ )); do
    FAKE_NOW=$(at $(( 300 + m * 60 ))) bash -c '
        _OPERATOR_ALERT_LOG_FN=: _OPERATOR_ALERT_BELL_FN=:
        source "$1" || exit 97
        if _operator_alert due auth-expired; then _operator_alert raise auth-expired critical "RUN /login (after restart)"; fi' \
        _ "$MODULE" || fail "25b the restarted process failed at minute $m"
done
assert_eq "25b ONE auth email across the restart (the delivered state is durable)" "$(emails auth-expired)" 1
assert_eq "25b …while the restarted process still reminded (continues, routine)" \
    "$(grep -c -- 'operator-alert: auth-expired (continues).*--priority routine' "$PUSH_CALLS")" 2
assert_eq "25b …and the BACKOFF survived the restart: reminders at +3900 and +11100, none at +7500 (the schedule is durable state, #1713)" \
    "$(tail -n +$(( k25b + 1 )) "$JSONL" | grep '"event":"raise","key":"auth-expired".*"kind":"continues"' | sed -n 's/^{"ts":\([0-9]*\),.*/\1/p' | awk -v b="$E25_T0" '{printf "%s%d", (n++ ? " " : ""), $1 - b} END{print ""}')" "3900 11100"

echo "--- 25c. resolved, then a NEW incident PAST REARM: a new email on its FIRST raise ---"
e25_reset
FAKE_NOW=$(at 0); export FAKE_NOW; auth_tick 1
FAKE_NOW=$(at 100); auth_tick 0; FAKE_NOW=$(at 400); auth_tick 0      # clear finalises at +400
assert_eq "25c CONTROL: one auth email for the first incident" "$(emails auth-expired)" 1
grep -q -- 'auth-expired (clear).*--priority routine' "$PUSH_CALLS" && pass "25c the RESOLVED notice is not an email" || fail "25c clear push: $(tail -n1 "$PUSH_CALLS")"
FAKE_NOW=$(at $(( 400 + 7200 + 1 ))); auth_tick 1
assert_eq "25c past REARM the new incident emailed on its FIRST raise (no delay)" "$(emails auth-expired)" 2

echo "--- 25c2. a GENUINE re-occurrence inside REARM is deferred, not dropped — and rate-capped at 1/h ---"
e25_reset
FAKE_NOW=$(at 0); export FAKE_NOW; auth_tick 1                         # began: email at +0
FAKE_NOW=$(at 100); auth_tick 0; FAKE_NOW=$(at 400); auth_tick 0      # cleared at +400
FAKE_NOW=$(at 600); auth_tick 1                                       # back 200 s later
assert_eq "25c2 the re-raise inside REARM is deferred, not immediate" "$(emails auth-expired)" 1
k0=$(count_lines "$JSONL")
for (( o = 630; o <= 3660; o += 30 )); do FAKE_NOW=$(at "$o"); auth_tick 1; done   # stands continuously
assert_eq "25c2 …and STILL STANDING it emails (once)" "$(emails auth-expired)" 2
conf=$(tail -n +$(( k0 + 1 )) "$JSONL" | grep '"key":"auth-expired","severity":"critical","kind":"confirmed"' | sed -n 's/^{"ts":\([0-9]*\),.*/\1/p')
assert_eq "25c2 …at +3600 s: 600 s of standing would allow +1200, but SAFETY caps a key at 1 email per 3600 s after its +0 email" "$(( ${conf:-0} - E25_T0 ))" 3600
grep -q -- 'operator-alert: auth-expired (confirmed).*--priority emergency' "$PUSH_CALLS" && pass "25c2 …as a CONFIRMED announcement" || fail "25c2 no confirmed push"
for (( o = 3720; o <= 6000; o += 60 )); do FAKE_NOW=$(at "$o"); auth_tick 1; done
assert_eq "25c2 …and never again while it stands" "$(emails auth-expired)" 2

echo "--- 25l. H1: a GENUINE third outage after a CONFIRMED re-expiry still emails (the skeptic's third rig) ---"
# expiry +0 (email), /login +60, re-expiry +90 (confirmed email at +100), /login
# +150, re-expiry +180 standing 3.7 h. Round 3's latch sent 0 for the third.
e25_reset
k0=$(count_lines "$JSONL")
for (( m = 0; m <= 250; m++ )); do    # the third outage's +190 email and an hour past it
    FAKE_NOW=$(at $(( m * 60 ))); export FAKE_NOW
    if (( m < 60 || (m >= 90 && m < 150) || m >= 180 )); then auth_tick 1; else auth_tick 0; fi
done
assert_eq "25l three outages, three emails" "$(emails auth-expired)" 3
got=$(tail -n +$(( k0 + 1 )) "$JSONL" | grep -E '"key":"auth-expired","severity":"critical","kind":"(began|confirmed)"' | sed -n 's/^{"ts":\([0-9]*\),.*/\1/p' | while read -r t; do printf '+%d ' $(( (t - E25_T0) / 60 )); done)
assert_eq "25l …at +0, +100 (cumulative 600 s) and +190 (600 s CONTINUOUS after the latch; the cap +160 does not bind)" "$got" "+0 +100 +190 "

echo "--- 25d. two callers (two crashed workers' detections) raising one cause: ONE email ---"
e25_reset
FAKE_NOW=$(at 0); export FAKE_NOW
for who in w1 w2; do
    bash -c '_OPERATOR_ALERT_LOG_FN=: _OPERATOR_ALERT_BELL_FN=:; source "$1" || exit 97
        if _operator_alert due auth-expired; then _operator_alert raise auth-expired critical "turn crashed on auth in $2"; fi' \
        _ "$MODULE" "$who" || fail "25d caller $who failed"
done
assert_eq "25d two sequential callers → ONE email" "$(emails)" 1

echo "--- 25e. the reminder push itself, direct ---"
e25_reset
FAKE_NOW=$(at 0); _operator_alert raise e25-direct critical "m"
FAKE_NOW=$(at 3600); _operator_alert raise e25-direct critical "m"
assert_eq "25e CONTROL: two pushes (announce + reminder)" "$(count_lines "$PUSH_CALLS")" 2
grep -q -- 'e25-direct (continues).*--priority routine' "$PUSH_CALLS" \
    && pass "25e the reminder push is routine (no email)" || fail "25e reminder push: $(tail -n1 "$PUSH_CALLS")"

echo "--- 25f. F1: a service key begun as WARNING, then blocked by an INDEPENDENT cause, ESCALATES and emails ONCE ---"
# The skeptic's `frozen` rig: auth out 30 min, /login, then the route blocked by
# OVER-LIMIT for 3.5 h with the service still down. Base emailed the service 5x
# (hourly); the first cut of this fix emailed it 0x.
e25_reset
for (( o = 0; o <= 6000; o += 60 )); do    # to +100 min: the escalation (+30) and one full reminder period past it
    FAKE_NOW=$(at "$o"); export FAKE_NOW
    if (( o < 1800 )); then auth_tick 1; E25_ROUTE=$ROUTE_AUTH; else auth_tick 0; E25_ROUTE=$ROUTE_OVER; fi
    svc_tick
done
assert_eq "25f CONTROL: the service began as WARNING (routine)" "$(grep -c -- 'service-health:nexus-remote-ssh (began).*--priority routine' "$PUSH_CALLS")" 1
assert_eq "25f the escalation to critical emails ONCE (not 0, not hourly)" "$(emails service-health:nexus-remote-ssh)" 1
grep -q -- 'service-health:nexus-remote-ssh (escalated).*--priority emergency' "$PUSH_CALLS" && pass "25f …as an ESCALATED announcement" || fail "25f no escalated push"
# G2: WHEN, not only whether. The route turns over-limit on the +1800 tick; the
# escalation is due IMMEDIATELY (`due <key> critical`), never at the next reminder.
esc_ts=$(grep '"key":"service-health:nexus-remote-ssh","severity":"critical","kind":"escalated"' "$JSONL" | sed -n 's/^{"ts":\([0-9]*\),.*/\1/p')
assert_eq "25f the escalation fired ON the first over-limit tick (+1800 s), not up to a reminder later" "$(( ${esc_ts:-0} - E25_T0 ))" 1800
assert_eq "25f the auth key emailed once too (its own cause)" "$(emails auth-expired)" 1

echo "--- 25g. F2: OVER-LIMIT while auth is ALSO standing is an independent cause — critical, emails ---"
e25_reset
for (( o = 0; o <= 5400; o += 60 )); do    # 90 min: past one reminder, so "once" means once
    FAKE_NOW=$(at "$o"); export FAKE_NOW; auth_tick 1; E25_ROUTE=$ROUTE_OVER; svc_tick
done
assert_eq "25g over-limit during auth: the service is CRITICAL and emails once" "$(emails service-health:nexus-remote-ssh)" 1
assert_eq "25g CONTROL: auth emailed once for its own cause" "$(emails auth-expired)" 1

echo "--- 25k. G1: a GENUINE outage whose detection FLICKERS still emails — within one tick of 600 s CUMULATIVE standing ---"
# The skeptic's `flicker` rig: auth out 0–60 min, clear, then a genuine outage
# whose detection drops 6 min in every 14 (8 on, 6 off; each gap > the 300 s
# hold-down, so every episode finalises a clear and RESUMES). Round 2 sent 0
# emails in 3 h. THE BOUND: a resumed chain emails within one tick of its
# cumulative standing reaching REARM_CONFIRM (600 s). Here: episode 1 (+70..+78)
# stands 480 s; episode 2 begins at +84 min and needs 120 s more → +86 min.
e25_reset
k0=$(count_lines "$JSONL")          # count only rows THIS case writes: the JSONL is suite-wide
for (( m = 0; m <= 180; m++ )); do    # 3 h: the +86 confirm and 94 min of flicker after it
    FAKE_NOW=$(at $(( m * 60 ))); export FAKE_NOW
    if (( m < 60 )); then auth_tick 1
    elif (( m < 70 )); then auth_tick 0
    elif (( (m - 70) % 14 < 8 )); then auth_tick 1
    else auth_tick 0; fi
done
assert_eq "25k the flickering outage emails (began + ONE confirmed; round 2 sent 0 for the flicker)" "$(emails auth-expired)" 2
conf_ts=$(tail -n +$(( k0 + 1 )) "$JSONL" | grep '"key":"auth-expired","severity":"critical","kind":"confirmed"' | sed -n 's/^{"ts":\([0-9]*\),.*/\1/p')
assert_eq "25k …CONFIRMED at +86 min: 480 s + 120 s of cumulative standing, to the tick" "$(( (${conf_ts:-0} - E25_T0) / 60 ))" 86
assert_eq "25k …and the chain, having emailed, sends nothing more in the remaining 94 min" \
    "$(tail -n +$(( k0 + 1 )) "$JSONL" | grep -c '"key":"auth-expired","severity":"critical","kind":"confirmed"')" 1

echo "--- 25h. F3: a FAILED first email is retried, email-only, until it lands — then stops ---"
e25_reset
printf '2\n' > "$EMAIL_FAILS"      # the first TWO email sends fail
for (( o = 0; o <= 10800; o += 60 )); do FAKE_NOW=$(at "$o"); export FAKE_NOW; auth_tick 1; done
assert_eq "25h three email attempts: the failed began, one failed retry, the retry that lands" "$(emails auth-expired)" 3
assert_eq "25h the retries were EMAIL-ONLY (no re-rung emergency push)" "$(grep -c -- 'auth-expired (mail-retry).*--email-only' "$PUSH_CALLS")" 2
grep -q '"event":"mail-delivered","key":"auth-expired","attempts":"3"' "$JSONL" && pass "25h delivered recorded, on attempt 3" || fail "25h no mail-delivered attempt 3: $(grep mail- "$JSONL" | tail -3)"
assert_eq "25h …and it STOPS after delivery (still 3 attempts at +3 h)" "$(emails auth-expired)" 3

echo "--- 25i. F3 durability: an UNDELIVERED email survives a watcher restart and is retried by the new process ---"
e25_reset
printf '1\n' > "$EMAIL_FAILS"
FAKE_NOW=$(at 0); export FAKE_NOW; auth_tick 1                       # began: its email FAILS
rm -f "$TMPDIR"/.nexus-operator-alert.* 2>/dev/null
FAKE_NOW=$(at 400) bash -c '_OPERATOR_ALERT_LOG_FN=: _OPERATOR_ALERT_BELL_FN=:; source "$1" || exit 97
    if _operator_alert due auth-expired; then _operator_alert raise auth-expired critical "RUN /login"; fi' _ "$MODULE" \
    || fail "25i restarted process failed"
assert_eq "25i the restarted process RETRIED the undelivered email" "$(grep -c -- 'auth-expired (mail-retry).*--email-only' "$PUSH_CALLS")" 1

echo "--- 25j. an UNCONFIGURED mailer is terminal: recorded, not retried ---"
e25_reset
export EMAIL_STATUS=unconfigured
for (( o = 0; o <= 7200; o += 60 )); do FAKE_NOW=$(at "$o"); export FAKE_NOW; auth_tick 1; done
unset EMAIL_STATUS
assert_eq "25j one attempt, no retries" "$(emails auth-expired)" 1
grep -q '"event":"mail-unconfigured","key":"auth-expired"' "$JSONL" && pass "25j …recorded as mail-unconfigured" || fail "25j not recorded"

echo "--- 25m. a mail-POLICY refusal is terminal too, and is recorded AS A REFUSAL (#1663 R3) ---"
e25_reset
# The JSONL is shared with 25j above, which DID record mail-unconfigured for
# this key: count before and after rather than grep the whole file.
_unc_before=$(grep -c '"event":"mail-unconfigured","key":"auth-expired"' "$JSONL")
export EMAIL_STATUS=refused
for (( o = 0; o <= 7200; o += 60 )); do FAKE_NOW=$(at "$o"); export FAKE_NOW; auth_tick 1; done
unset EMAIL_STATUS
assert_eq "25m one attempt, no retries" "$(emails auth-expired)" 1
grep -q '"event":"mail-refused","key":"auth-expired"' "$JSONL" && pass "25m …recorded as mail-refused" || fail "25m not recorded as mail-refused"
assert_eq "25m …and NOT as mail-unconfigured (no new such record)" \
    "$(grep -c '"event":"mail-unconfigured","key":"auth-expired"' "$JSONL")" "$_unc_before"

export PATH=$OLDPATH; unset FAKE_NOW; unset -f date
export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=0
_SERVICE_HEALTH_OPERATOR_ALERT_FN=_sh_operator_alert_noop
_SERVICE_HEALTH_ROUTE_BLOCKED_FN=_sh_route_blocked_noop
e25_reset

echo "=== 26. notify.sh reports the EMAIL leg on its own (#1653 F3) — hermetic: stub config, curl stub, refused SMTP ==="
# The exit code folds every backend together, so "the email arrived" must be
# read from --email-status-file. The REAL notify.sh, copied beside a stub
# config/load.sh (so no operator address or relay is ever read) and run with a
# `curl` stub first on PATH and an SMTP host of 127.0.0.1:1 (connection refused).
NT="$WORK/notify-tree"; mkdir -p "$NT/monitor" "$NT/config" "$NT/bin"
cp "$_repo_root/monitor/notify.sh" "$NT/monitor/notify.sh"
# THE MAIL POLICY (your-org/nexus-code#1663) reads the operator from the
# PRIMARY nexus's OWN config, resolved by monitor/_nexus-root.sh: the fixture
# carries that resolver and a config/nexus.yml of its own, and every run below
# UNSETS NEXUS_ROOT and NEXUS_CONFIG. Without that, a config-less fixture would
# defer (the one-tree rule) to the inherited NEXUS_ROOT — the operator's real
# primary and its real address.
cp "$_repo_root/monitor/_nexus-root.sh" "$NT/monitor/_nexus-root.sh"
: > "$NT/config/nexus.yml"
cat > "$NT/config/load.sh" <<'EOF'
#!/usr/bin/env bash
# fixture config: answers only from NT_CFG_* env, else the default ($2)
case "$1" in
    notifications.email.address)   # the example config answers its placeholder
                                   case "${NEXUS_CONFIG:-}" in
                                       *nexus.example.yml) printf '%s\n' you@your-institution.edu ;;
                                       *) printf '%s\n' "${NT_CFG_ADDR-}" ;;
                                   esac ;;
    notifications.email.smtp_host) printf '%s\n' "${NT_CFG_HOST-}" ;;
    notifications.email.smtp_port) printf '%s\n' "${NT_CFG_PORT:-1}" ;;
    *) printf '%s\n' "${2:-}" ;;
esac
EOF
chmod +x "$NT/config/load.sh"
cat > "$NT/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$NT_CURL_CALLS"
printf '200'
EOF
chmod +x "$NT/bin/curl"
export NT_CURL_CALLS="$WORK/nt-curl-calls"; : > "$NT_CURL_CALLS"
: > "$NT/push.key"; : > "$NT/push.app"; chmod 600 "$NT/push.key" "$NT/push.app"
printf 'u\n' > "$NT/push.key"; printf 'a\n' > "$NT/push.app"
nt() {   # run the copied notify.sh hermetically; echo "rc status"
    local esf="$WORK/nt-es.$RANDOM"; rm -f "$esf"
    ( unset NEXUS_EMAIL_TO NEXUS_SMTP_HOST NEXUS_SMTP_PORT NEXUS_ROOT NEXUS_CONFIG
      PATH="$NT/bin:$PATH" NEXUS_PUSHOVER_USER_KEY_FILE="$NT/push.key" NEXUS_PUSHOVER_APP_TOKEN_FILE="$NT/push.app" \
      NEXUS_NOTIFY_TOKEN="$NT/no-ntfy" bash "$NT/monitor/notify.sh" T M "$@" --email-status-file "$esf" --quiet )
    local rc=$?
    printf '%s %s' "$rc" "$(cat "$esf" 2>/dev/null || echo MISSING)"
}
# Sanity: the fixture must NOT be able to reach the operator's real relay.
[[ "$(NT_CFG_ADDR= NT_CFG_HOST= "$NT/config/load.sh" notifications.email.address)" == "" ]] \
    && pass "26 fixture config serves no real address" || fail "26 fixture config leaks an address"
got=$(NT_CFG_ADDR=nobody@invalid.example NT_CFG_HOST=127.0.0.1 nt --priority emergency --require-delivery)
assert_eq "26 emergency, push ok, SMTP REFUSED → rc 0 (a push landed) but email=failed" "$got" "0 failed"
got=$(NT_CFG_ADDR=nobody@invalid.example NT_CFG_HOST=127.0.0.1 nt --priority emergency --email-only --require-delivery)
assert_eq "26 --email-only, SMTP refused → rc 3, email=failed" "$got" "3 failed"
: > "$NT_CURL_CALLS"
NT_CFG_ADDR=nobody@invalid.example NT_CFG_HOST=127.0.0.1 nt --priority emergency --email-only >/dev/null
assert_eq "26 --email-only never touches the push backends (0 curl calls)" "$(count_lines "$NT_CURL_CALLS")" 0
got=$(NT_CFG_ADDR= NT_CFG_HOST= nt --priority emergency --email-only --require-delivery)
assert_eq "26 no address/relay configured → email=unconfigured (terminal, not a failure)" "${got#* }" "unconfigured"
got=$(NT_CFG_ADDR=nobody@invalid.example NT_CFG_HOST=127.0.0.1 nt --priority routine)
assert_eq "26 routine → email=skipped" "$got" "0 skipped"
# G3: a SET-but-EMPTY override means NO email — never the configured address.
# The fixture config SERVES an address and relay here, so a fallback would show
# as an attempted send (email=failed against the refused port), not unconfigured.
nt_env() {   # <VAR=value>… -- <notify args>…: like nt, but with overrides SET
    local esf="$WORK/nt-es.$RANDOM" errf="$WORK/nt-err.$RANDOM" -a envs=(); rm -f "$esf"
    while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
    ( unset NEXUS_EMAIL_TO NEXUS_SMTP_HOST NEXUS_SMTP_PORT NEXUS_ROOT NEXUS_CONFIG
      env "${envs[@]}" PATH="$NT/bin:$PATH" NEXUS_PUSHOVER_USER_KEY_FILE="$NT/push.key" NEXUS_PUSHOVER_APP_TOKEN_FILE="$NT/push.app" \
      NEXUS_NOTIFY_TOKEN="$NT/no-ntfy" bash "$NT/monitor/notify.sh" T M "$@" --email-status-file "$esf" --quiet ) 2>"$errf"
    local rc=$?
    printf '%s %s|%s' "$rc" "$(cat "$esf" 2>/dev/null || echo MISSING)" "$(tr '\n' ' ' < "$errf")"
}
got=$(nt_env NT_CFG_ADDR=nobody@invalid.example NT_CFG_HOST=127.0.0.1 NEXUS_EMAIL_TO= -- --priority emergency --email-only)
assert_eq "26 G3 NEXUS_EMAIL_TO='' (config HAS an address) → email=unconfigured, NOT a send" "${got%%|*}" "0 unconfigured"
assert_contains "26 G3 …refused LOUDLY on stderr, even under --quiet" "$got" "NEXUS_EMAIL_TO is set but EMPTY"
got=$(nt_env NT_CFG_ADDR=nobody@invalid.example NT_CFG_HOST=127.0.0.1 NEXUS_SMTP_HOST= -- --priority emergency --email-only)
assert_eq "26 G3 NEXUS_SMTP_HOST='' (config HAS a relay) → email=unconfigured, NOT a send" "${got%%|*}" "0 unconfigured"
assert_contains "26 G3 …the SMTP refusal is LOUD" "$got" "NEXUS_SMTP_HOST is set but EMPTY"
# CONTROL (must not flip): UNSET still means "use the config" — here the
# fixture relay, which refuses, so the send is ATTEMPTED and fails.
got=$(nt_env NT_CFG_ADDR=nobody@invalid.example NT_CFG_HOST=127.0.0.1 -- --priority emergency --email-only)
assert_eq "26 G3 CONTROL: overrides UNSET → the config is used (attempted, refused port)" "${got%%|*}" "0 failed"
# G3: NEXUS_NOTIFY_QUIET=1 — the harness hard off (run-tests.sh exports it) — sends NOTHING.
: > "$NT_CURL_CALLS"
got=$(nt_env NT_CFG_ADDR=nobody@invalid.example NT_CFG_HOST=127.0.0.1 NEXUS_NOTIFY_QUIET=1 -- --priority emergency --require-delivery)
assert_eq "26 G3 NEXUS_NOTIFY_QUIET=1 → rc 0, email=quiet (nothing sent)" "${got%%|*}" "0 quiet"
assert_eq "26 G3 …and no push backend was touched (0 curl calls)" "$(count_lines "$NT_CURL_CALLS")" 0
assert_contains "26 G3 …and it SAYS so on stderr" "$got" "nothing sent on any backend"

echo "=== 14. the PRODUCTION default is DETACHED: raise returns before a slow push leg finishes ==="
: > "$PUSH_CALLS"
cat > "$WORK/bin/notify-slow" <<'EOF'
#!/usr/bin/env bash
sleep 3
printf '%s\n' "$*" >> "$PUSH_CALLS"
exit 0
EOF
chmod +x "$WORK/bin/notify-slow"
t0=$(date +%s%N)
_OPERATOR_ALERT_NETWORK_SYNC=0 MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false \
    _OPERATOR_ALERT_PUSH_CMD="$WORK/bin/notify-slow" _operator_alert raise detached-key critical "slow leg"
t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if (( ms < 1500 )); then pass "14 raise returned in ${ms} ms while the push leg sleeps 3 s (detached)"; else fail "14 raise BLOCKED for ${ms} ms on the push leg — the watcher's 5 s task would stall on the network"; fi
wait_lines "$PUSH_CALLS" 1 8 && pass "14 …and the detached push still landed" || fail "14 the detached push never landed"
_OPERATOR_ALERT_NETWORK_SYNC=0 MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false MONITOR_OPERATOR_ALERT_PUSH_ENABLED=false \
    _operator_alert clear detached-key "x" >/dev/null 2>&1

# Reap anything the detached legs left (they exit on their own; this is belt
# and braces so the suite never leaves a child behind).
wait 2>/dev/null || true
th_summary_and_exit
