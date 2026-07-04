#!/usr/bin/env bash
# Cross-host nexus-instance heartbeat + combined-guard tests
# (single-nexus-instance hardening).
#
# The flock on nexus-instance.lock (test-instance-lock.sh) is the
# AUTHORITATIVE same-host singleton guard, but two gaps let a second nexus
# come up in one shared directory:
#   1. SCOPE — the flock gated only the WATCHER. bootstrap-recover/entry.sh
#      still spawned a second orchestrator + services alongside a refused
#      watcher. The combined preflight closes this (refuses a foreign
#      co-located cockpit before ANY bring-up; exempts our OWN recovery).
#   2. CROSS-HOST — flock over NFSv3 does not reliably arbitrate between
#      clients, so a cockpit on another host sees the flock as free. The
#      heartbeat beacon (refreshed every loop; read by starters) refuses a
#      FRESH remote peer and takes over only a STALE one.
#
# These tests pin the pure decision helpers (fully injectable), the atomic
# beacon writer, and the preflight/launcher refusal surfaces against real
# background flock holders. Hermetic: own tmpdirs + stubs, shares nothing
# with the live monitor/.state.
#
# Run: bash monitor/watcher/test-instance-heartbeat.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }
# eq <got> <want> <label>
eq() { if [[ "$1" == "$2" ]]; then pass "$3 → $1"; else fail "$3: got [$1] want [$2]"; fi; }

# shellcheck source=_test_helpers.sh
. "$_real_test_dir/_test_helpers.sh"
# shellcheck source=_lib.sh
. "$_real_test_dir/_lib.sh"

NOW=1000000
WIN=600

# Background flock holder: holds an exclusive flock on <lockfile>, writes
# <meta> into it (dirty-readable metadata), holds until <sentinel> removed.
# Sets HOLDER_PID. Models a live peer/own watcher holding the instance lock.
start_holder() {
    local lockfile="$1" sentinel="$2" meta="$3"
    (
        exec {fd}<>"$lockfile" || exit 1
        flock -n "$fd" || exit 1
        printf '%s' "$meta" >&"$fd"
        while [[ -e "$sentinel" ]]; do sleep 0.1; done
    ) &
    HOLDER_PID=$!
    sleep 0.4
}

# ============================================================================
echo '=== A. _nexus_instance_remote_verdict (pure) ==='
eq "$(_nexus_instance_remote_verdict "" hostA $NOW $WIN)"                          none         "empty beacon"
eq "$(_nexus_instance_remote_verdict $'host: hostA\nepoch: 999900\n' hostA $NOW $WIN)" same-host  "same-host beacon"
eq "$(_nexus_instance_remote_verdict $'host: hostB\nepoch: 999900\n' hostA $NOW $WIN)" live-remote "remote fresh (age 100 ≤ 600)"
eq "$(_nexus_instance_remote_verdict $'host: hostB\nepoch: 999000\n' hostA $NOW $WIN)" stale-remote "remote stale (age 1000 > 600)"
eq "$(_nexus_instance_remote_verdict $'host: hostB\nepoch: 1000500\n' hostA $NOW $WIN)" live-remote "remote future-dated (clock skew → treat as fresh)"
eq "$(_nexus_instance_remote_verdict $'pid: 5\nepoch: 999900\n' hostA $NOW $WIN)"     corrupt      "beacon missing host"
eq "$(_nexus_instance_remote_verdict $'host: hostB\nepoch: xyz\n' hostA $NOW $WIN)"   corrupt      "remote beacon non-integer epoch"
# exact boundary: age == window is still fresh (<=)
eq "$(_nexus_instance_remote_verdict $'host: hostB\nepoch: 999400\n' hostA $NOW $WIN)" live-remote "remote at exact window (age 600 == 600 → fresh)"
eq "$(_nexus_instance_remote_verdict $'host: hostB\nepoch: 999399\n' hostA $NOW $WIN)" stale-remote "remote just past window (age 601 → stale)"

# ============================================================================
echo '=== B. _nexus_instance_guard_decision (pure) ==='
MYNS=NS1
eq "$(_nexus_instance_guard_decision 1 $'host: hostA\npid_ns: NS1\n' "" hostA $MYNS $NOW $WIN)" self          "flock held by self (host+pid_ns match)"
eq "$(_nexus_instance_guard_decision 1 $'host: hostA\npid_ns: NS2\n' "" hostA $MYNS $NOW $WIN)" refuse-local  "flock held, same host, DIFFERENT pid_ns (co-located sandbox)"
eq "$(_nexus_instance_guard_decision 1 $'host: hostB\npid_ns: NS9\n' "" hostA $MYNS $NOW $WIN)" refuse-local  "flock held, different host (NLM-visible peer)"
eq "$(_nexus_instance_guard_decision 1 $'pid: 5\n' "" hostA $MYNS $NOW $WIN)"                   refuse-corrupt "flock held, metadata missing host (unidentifiable)"
eq "$(_nexus_instance_guard_decision 1 $'host: hostA\n' "" hostA $MYNS $NOW $WIN)"              refuse-local  "flock held, same host, pid_ns absent (not provably self → refuse)"
eq "$(_nexus_instance_guard_decision 0 "" "" hostA $MYNS $NOW $WIN)"                            free          "flock free, no heartbeat (cold start)"
eq "$(_nexus_instance_guard_decision 0 "" $'host: hostA\nepoch: 999900\n' hostA $MYNS $NOW $WIN)" free        "flock free, same-host heartbeat (dead local holder)"
eq "$(_nexus_instance_guard_decision 0 "" $'host: hostB\nepoch: 999900\n' hostA $MYNS $NOW $WIN)" refuse-remote "flock free, FRESH remote heartbeat"
eq "$(_nexus_instance_guard_decision 0 "" $'host: hostB\nepoch: 999000\n' hostA $MYNS $NOW $WIN)" free         "flock free, STALE remote heartbeat (takeover)"
eq "$(_nexus_instance_guard_decision 0 "" $'host: hostB\nepoch: xyz\n' hostA $MYNS $NOW $WIN)"    refuse-corrupt "flock free, corrupt remote heartbeat (fail closed)"

# ============================================================================
echo '=== C. _nexus_instance_staleness_window ==='
( unset NEXUS_INSTANCE_HEARTBEAT_STALENESS; eq "$(_nexus_instance_staleness_window)" 600 "default window" )
( NEXUS_INSTANCE_HEARTBEAT_STALENESS=42; eq "$(_nexus_instance_staleness_window)" 42 "env override honoured" )
( NEXUS_INSTANCE_HEARTBEAT_STALENESS=garbage; eq "$(_nexus_instance_staleness_window)" 600 "non-integer env → default" )

# ============================================================================
echo '=== D. _nexus_instance_heartbeat_write (atomic) ==='
TD=$(mktemp -d -t nexus-hb-write-XXXXXX)
HB="$TD/nexus-instance.heartbeat"
eq "$(_nexus_instance_heartbeat_path "$TD")" "$HB" "heartbeat path"
NEXUS_ROOT="$TD" _nexus_instance_heartbeat_write "$HB" && pass "write returned 0" || fail "write returned non-zero"
MH=$(hostname 2>/dev/null || echo unknown)
[[ "$(_nexus_instance_lock_field "$(cat "$HB")" host)" == "$MH" ]] && pass "beacon records this host" || fail "beacon host wrong"
[[ "$(_nexus_instance_lock_field "$(cat "$HB")" epoch)" =~ ^[0-9]+$ ]] && pass "beacon epoch is integer" || fail "beacon epoch not integer"
[[ "$(_nexus_instance_lock_field "$(cat "$HB")" pid_ns)" == "$(readlink /proc/self/ns/pid)" ]] && pass "beacon records our pid_ns" || fail "beacon pid_ns wrong"
# no stray tmp left behind
if compgen -G "$HB.tmp.*" >/dev/null 2>&1; then fail "left a .tmp file behind"; else pass "no stray tmp file"; fi
# refresh advances epoch and file stays complete
e1=$(_nexus_instance_lock_field "$(cat "$HB")" epoch)
sleep 1.1
NEXUS_ROOT="$TD" _nexus_instance_heartbeat_write "$HB"
e2=$(_nexus_instance_lock_field "$(cat "$HB")" epoch)
(( e2 >= e1 )) && pass "refresh does not regress epoch ($e1 → $e2)" || fail "epoch regressed ($e1 → $e2)"
rm -rf "$TD"

# ============================================================================
echo '=== E. _nexus_instance_preflight (integration, real flock) ==='
MYHOST=$(hostname 2>/dev/null || echo unknown)
MYPIDNS=$(readlink /proc/self/ns/pid 2>/dev/null || echo unknown)

# E1: free state dir → proceed
SD=$(mktemp -d -t nexus-pf-free-XXXXXX)
_nexus_instance_preflight "$SD" /root >/dev/null 2>&1 && pass "E1 free → proceed (rc0)" || fail "E1 free refused"
rm -rf "$SD"

# E2: foreign co-located holder (flock held + foreign pid_ns metadata) → refuse-local
SD=$(mktemp -d -t nexus-pf-foreign-XXXXXX)
SENT="$SD/hold"; : > "$SENT"
start_holder "$SD/nexus-instance.lock" "$SENT" "$(printf 'host: %s\npid_ns: pid:[9999999]\npid: 42\n' "$MYHOST")"
if _nexus_instance_preflight "$SD" /root >"$SD/out" 2>&1; then fail "E2 foreign holder → PROCEEDED (leak)"; else
    pass "E2 foreign co-located holder → refuse (rc1)"
    grep -q "same-host instance flock" "$SD/out" && pass "E2 message names the flock holder" || fail "E2 message lacked holder detail"
fi
rm -f "$SENT"; wait "$HOLDER_PID" 2>/dev/null || true; rm -rf "$SD"

# E3: OWN holder (flock held + our host + our pid_ns) → proceed (within-instance recovery)
SD=$(mktemp -d -t nexus-pf-self-XXXXXX)
SENT="$SD/hold"; : > "$SENT"
start_holder "$SD/nexus-instance.lock" "$SENT" "$(printf 'host: %s\npid_ns: %s\npid: 42\n' "$MYHOST" "$MYPIDNS")"
_nexus_instance_preflight "$SD" /root >/dev/null 2>&1 && pass "E3 own holder → proceed (recovery not self-blocked)" || fail "E3 own recovery REFUSED (self-block!)"
rm -f "$SENT"; wait "$HOLDER_PID" 2>/dev/null || true; rm -rf "$SD"

# E4: fresh REMOTE heartbeat, no flock holder → refuse-remote
SD=$(mktemp -d -t nexus-pf-remote-XXXXXX)
printf 'host: farhost\nepoch: %s\nts: 2026-07-01T00:00:00Z\n' "$(date +%s)" > "$SD/nexus-instance.heartbeat"
if _nexus_instance_preflight "$SD" /root >"$SD/out" 2>&1; then fail "E4 fresh remote → PROCEEDED (cross-host leak)"; else
    pass "E4 fresh remote heartbeat → refuse (rc1)"
    grep -q "running on host farhost" "$SD/out" && pass "E4 message names the remote host" || fail "E4 message lacked remote host"
fi
rm -rf "$SD"

# E5: STALE remote heartbeat, no flock → proceed (takeover)
SD=$(mktemp -d -t nexus-pf-stale-XXXXXX)
printf 'host: farhost\nepoch: %s\nts: old\n' "$(( $(date +%s) - 100000 ))" > "$SD/nexus-instance.heartbeat"
_nexus_instance_preflight "$SD" /root >/dev/null 2>&1 && pass "E5 stale remote → proceed (takeover)" || fail "E5 stale remote REFUSED"
rm -rf "$SD"

# E6: corrupt heartbeat (remote host, non-integer epoch) → refuse-corrupt (fail closed)
SD=$(mktemp -d -t nexus-pf-corrupt-XXXXXX)
printf 'host: farhost\nepoch: NOT-A-NUMBER\n' > "$SD/nexus-instance.heartbeat"
if _nexus_instance_preflight "$SD" /root >"$SD/out" 2>&1; then fail "E6 corrupt → PROCEEDED (should fail closed)"; else
    pass "E6 corrupt heartbeat → refuse (fail closed, rc1)"
    grep -q "UNPARSEABLE" "$SD/out" && pass "E6 message flags the unparseable state" || fail "E6 message lacked corrupt guidance"
fi
rm -rf "$SD"

# ============================================================================
echo '=== F. launcher.sh — fresh remote heartbeat → REFUSE (rc 4), no spawn ==='
REAL_LAUNCHER="$_real_test_dir/launcher.sh"
WORK=$(mktemp -d -t nexus-hb-launch-XXXXXX)
mkdir -p "$WORK/monitor/watcher" "$WORK/monitor/.state" "$WORK/bin" "$WORK/config" "$WORK/node_modules/.bin"
cp "$REAL_LAUNCHER" "$WORK/monitor/watcher/launcher.sh"
cp "$_real_test_dir/_lib.sh" "$WORK/monitor/watcher/_lib.sh"
cp "$_real_test_dir/_respawn_async.sh" "$WORK/monitor/watcher/_respawn_async.sh"
chmod +x "$WORK/monitor/watcher/launcher.sh"
cat > "$WORK/monitor/watcher/main.sh" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$WORK/monitor/.state/watcher.pid"
sleep 60
EOF
chmod +x "$WORK/monitor/watcher/main.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/node_modules/.bin/claude"; chmod +x "$WORK/node_modules/.bin/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/tmux"; chmod +x "$WORK/bin/tmux"
printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$WORK/config/load.sh"; chmod +x "$WORK/config/load.sh"
# Plant a FRESH remote heartbeat (different host) with no flock holder.
printf 'host: farhost\nepoch: %s\nts: now\n' "$(date +%s)" > "$WORK/monitor/.state/nexus-instance.heartbeat"
PATH="$WORK/bin:$PATH" "$WORK/monitor/watcher/launcher.sh" >"$WORK/out" 2>"$WORK/err"; RC=$?
if (( RC == 4 )); then pass "F launcher refused a fresh remote heartbeat (rc 4)"; else fail "F launcher rc=$RC (want 4); err: $(cat "$WORK/err")"; fi
grep -q "cross-host heartbeat" "$WORK/err" && pass "F refusal names the cross-host heartbeat" || fail "F refusal lacked cross-host message"
if [[ -f "$WORK/monitor/.state/watcher.pid" ]]; then fail "F launcher spawned a watcher despite fresh remote heartbeat"; else pass "F launcher did NOT spawn a watcher"; fi
# Contrast: STALE remote heartbeat → launcher proceeds (spawns).
printf 'host: farhost\nepoch: %s\nts: old\n' "$(( $(date +%s) - 100000 ))" > "$WORK/monitor/.state/nexus-instance.heartbeat"
PATH="$WORK/bin:$PATH" "$WORK/monitor/watcher/launcher.sh" >"$WORK/out2" 2>"$WORK/err2"; RC=$?
if (( RC == 0 )); then pass "F launcher proceeds past a STALE remote heartbeat (rc 0)"; else fail "F launcher rc=$RC on stale remote; err: $(cat "$WORK/err2")"; fi
_lp=''; [[ -f "$WORK/monitor/.state/watcher.pid" ]] && read -r _lp < "$WORK/monitor/.state/watcher.pid" 2>/dev/null
[[ "$_lp" =~ ^[0-9]+$ ]] && th_kill_fixture_pid "$_lp" "$WORK"
rm -rf "$WORK"

# ============================================================================
echo '=== G. _nexus_instance_gen_nonce + beacon nonce field ==='
_n1=$(_nexus_instance_gen_nonce); _n2=$(_nexus_instance_gen_nonce)
[[ -n "$_n1" ]] && pass "gen_nonce non-empty" || fail "gen_nonce empty"
[[ "$_n1" != "$_n2" ]] && pass "gen_nonce distinct across calls" || fail "gen_nonce collided ($_n1)"
TDN=$(mktemp -d -t nexus-hb-nonce-XXXXXX); HBN="$TDN/nexus-instance.heartbeat"
NEXUS_ROOT="$TDN" NEXUS_INSTANCE_NONCE=nonce-XYZ _nexus_instance_heartbeat_write "$HBN"
eq "$(_nexus_instance_lock_field "$(cat "$HBN")" nonce)" nonce-XYZ "beacon records the pinned nonce"
( NEXUS_ROOT="$TDN"; unset NEXUS_INSTANCE_NONCE; _nexus_instance_heartbeat_write "$HBN" )
eq "$(_nexus_instance_lock_field "$(cat "$HBN")" nonce)" "" "unset nonce → empty field (old-format compatible)"
rm -rf "$TDN"

# ============================================================================
echo '=== H. _nexus_instance_fence_decision (pure per-loop self-fence) ==='
MYNONCE=nonce-mine
eq "$(_nexus_instance_fence_decision "" hostA $MYNONCE $NOW $WIN)"                                              refresh "empty beacon → refresh (ours to write)"
eq "$(_nexus_instance_fence_decision $'host: hostA\nnonce: nonce-mine\nepoch: 999900\n' hostA $MYNONCE $NOW $WIN)"  refresh "own nonce, fresh → refresh"
eq "$(_nexus_instance_fence_decision $'host: hostB\nnonce: nonce-other\nepoch: 999900\n' hostA $MYNONCE $NOW $WIN)" fence   "foreign nonce, remote host, fresh → fence"
eq "$(_nexus_instance_fence_decision $'host: hostA\nnonce: nonce-other\nepoch: 999900\n' hostA $MYNONCE $NOW $WIN)" fence   "foreign nonce, SAME host, fresh → fence (same-host 2nd instance)"
eq "$(_nexus_instance_fence_decision $'host: hostB\nnonce: nonce-other\nepoch: 999000\n' hostA $MYNONCE $NOW $WIN)" refresh "foreign nonce but STALE (age 1000>600) → refresh (reclaim dead holder)"
eq "$(_nexus_instance_fence_decision $'host: hostA\nepoch: 999900\n' hostA $MYNONCE $NOW $WIN)"                     refresh "old-format (no nonce) same host fresh → refresh (no spurious fence)"
eq "$(_nexus_instance_fence_decision $'host: hostB\nepoch: 999900\n' hostA $MYNONCE $NOW $WIN)"                     fence   "old-format (no nonce) remote host fresh → fence (live remote old peer)"
eq "$(_nexus_instance_fence_decision $'pid: 5\nnonce: x\nepoch: 999900\n' hostA $MYNONCE $NOW $WIN)"                refresh "beacon missing host → refresh (never self-fence on corrupt)"
eq "$(_nexus_instance_fence_decision $'host: hostB\nnonce: nonce-other\nepoch: xyz\n' hostA $MYNONCE $NOW $WIN)"    refresh "non-integer epoch → refresh (cannot prove supersession)"
eq "$(_nexus_instance_fence_decision $'host: hostB\nnonce: nonce-other\nepoch: 1000500\n' hostA $MYNONCE $NOW $WIN)" fence  "foreign future-dated (skew) → fence (treated fresh)"
eq "$(_nexus_instance_fence_decision $'host: hostB\nnonce: nonce-other\nepoch: 999400\n' hostA $MYNONCE $NOW $WIN)" fence   "foreign at exact window (age 600==600 → fresh → fence)"
eq "$(_nexus_instance_fence_decision $'host: hostB\nnonce: nonce-other\nepoch: 999399\n' hostA $MYNONCE $NOW $WIN)" refresh "foreign just past window (age 601 → stale → refresh)"
eq "$(_nexus_instance_fence_decision $'host: hostA\nnonce: nonce-other\nepoch: 999900\n' hostA "" $NOW $WIN)"       refresh "beacon has nonce but MY nonce empty, same host → host fallback → refresh"
eq "$(_nexus_instance_fence_decision $'host: hostB\nnonce: nonce-other\nepoch: 999900\n' hostA "" $NOW $WIN)"       fence   "beacon has nonce but MY nonce empty, remote host → host fallback → fence"

# ============================================================================
echo '=== I. _nexus_instance_beacon_loop_step (loop seam: refresh writes, fence stands down) ==='
TDL=$(mktemp -d -t nexus-fence-step-XXXXXX); HBL="$TDL/nexus-instance.heartbeat"
MH=$(hostname 2>/dev/null || echo unknown)
export NEXUS_INSTANCE_NONCE=nonce-mine
NOWL=$(date +%s)

# (b) own beacon, fresh → refresh (rc0), beacon rewritten with a fresh epoch + our nonce
printf 'host: %s\nnonce: nonce-mine\nepoch: %s\nts: old\n' "$MH" "$(( NOWL - 5 ))" > "$HBL"
NEXUS_ROOT="$TDL" _nexus_instance_beacon_loop_step "$HBL" "$MH" nonce-mine "$NOWL" "$WIN"; _rc=$?
eq "$_rc" 0 "I(b) own fresh beacon → step rc0 (refresh)"
[[ "$(_nexus_instance_lock_field "$(cat "$HBL")" nonce)" == "nonce-mine" ]] && pass "I(b) rewritten beacon carries our nonce" || fail "I(b) nonce wrong"
[[ "$(_nexus_instance_lock_field "$(cat "$HBL")" epoch)" -ge "$NOWL" ]] && pass "I(b) refresh advanced the epoch" || fail "I(b) epoch not advanced"

# (a) foreign, fresh → fence (rc2), successor beacon NOT overwritten
printf 'host: farhost\nnonce: nonce-winner\nepoch: %s\nts: winner-ts\n' "$NOWL" > "$HBL"
BEFORE=$(cat "$HBL")
NEXUS_ROOT="$TDL" _nexus_instance_beacon_loop_step "$HBL" "$MH" nonce-mine "$NOWL" "$WIN"; _rc=$?
eq "$_rc" 2 "I(a) foreign fresh beacon → step rc2 (stand-down)"
[[ "$(cat "$HBL")" == "$BEFORE" ]] && pass "I(a) successor beacon left byte-for-byte intact" || fail "I(a) successor beacon was overwritten"
[[ "$(_nexus_instance_lock_field "$(cat "$HBL")" host)" == "farhost" ]] && pass "I(a) beacon still names the successor host" || fail "I(a) beacon host changed"

# (c) foreign, STALE → refresh (rc0), beacon reclaimed to us (no false fence)
printf 'host: farhost\nnonce: nonce-dead\nepoch: %s\nts: dead\n' "$(( NOWL - 100000 ))" > "$HBL"
NEXUS_ROOT="$TDL" _nexus_instance_beacon_loop_step "$HBL" "$MH" nonce-mine "$NOWL" "$WIN"; _rc=$?
eq "$_rc" 0 "I(c) foreign STALE beacon → step rc0 (reclaim, no false fence)"
[[ "$(_nexus_instance_lock_field "$(cat "$HBL")" host)" == "$MH" ]] && pass "I(c) reclaimed beacon now names us" || fail "I(c) beacon not reclaimed"
unset NEXUS_INSTANCE_NONCE
rm -rf "$TDL"

# ============================================================================
echo '=== J. main.sh wiring — the D4 fix is actually called + its stand-down honored ==='
MAIN="$_real_test_dir/main.sh"
grep -q '_nexus_instance_beacon_loop_step "\$INSTANCE_HEARTBEAT_FILE"' "$MAIN" && pass "J loop invokes _nexus_instance_beacon_loop_step at the refresh site" || fail "J loop does not invoke the fence step"
grep -q 'INSTANCE_SUPERSEDED=1' "$MAIN" && pass "J loop sets INSTANCE_SUPERSEDED on a fence verdict" || fail "J loop never sets INSTANCE_SUPERSEDED"
grep -q 'SELF-FENCE' "$MAIN" && pass "J stand-down is logged loudly (SELF-FENCE)" || fail "J no SELF-FENCE log line"
grep -q 'NEXUS_INSTANCE_NONCE="\$(_nexus_instance_gen_nonce)"' "$MAIN" && pass "J main.sh pins a per-instance nonce" || fail "J main.sh does not pin NEXUS_INSTANCE_NONCE"
sed -n '/^release_instance_lock()/,/^}/p' "$MAIN" | grep -q 'INSTANCE_SUPERSEDED' && pass "J release_instance_lock spares the successor beacon when superseded" || fail "J release_instance_lock does not guard the beacon rm"

# ============================================================================
echo '=== K. release_instance_lock — behavioral: superseded stand-down spares the beacon ==='
# Static grep (section J) proves the guard is PRESENT but not that its SENSE is
# right — a logically-inverted guard (== "0") would still grep-match. Execute
# the real function to kill that hazard: extract its body from main.sh and eval
# it into this shell (the section-J extraction approach, but EXECUTED), stub the
# `log` it calls, and drive both branches against a real fd + beacon fixture.
# Run in the MAIN shell (section K is last) so pass/fail tally normally, and so
# the eval'd function persists for the assertions. Stub the `log` it calls.
log() { :; }
MAINK="$_real_test_dir/main.sh"
_fnK=$(sed -n '/^release_instance_lock()/,/^}/p' "$MAINK")
[[ -n "$_fnK" ]] && pass "K extracted release_instance_lock from main.sh" || fail "K could not extract the function"
eval "$_fnK"

TDK=$(mktemp -d -t nexus-relguard-XXXXXX)
HBK="$TDK/nexus-instance.heartbeat"
LCK="$TDK/nexus-instance.lock"
INSTANCE_HEARTBEAT_FILE="$HBK"

# (i) superseded → return 0, beacon LEFT BYTE-INTACT (it is the successor's now)
printf 'host: farhost\nnonce: winner\nepoch: 123\nts: winner-ts\n' > "$HBK"
_WANTK=$(cat "$HBK")
exec {INSTANCE_LOCK_FD}<>"$LCK" || fail "K(i) could not open lock fd"
INSTANCE_SUPERSEDED=1
release_instance_lock; _rck=$?
eq "$_rck" 0 "K(i) superseded → release returns 0"
[[ -f "$HBK" ]] && pass "K(i) successor beacon NOT removed" || fail "K(i) beacon was removed under supersession"
[[ "$(cat "$HBK" 2>/dev/null)" == "$_WANTK" ]] && pass "K(i) successor beacon byte-intact" || fail "K(i) beacon content changed"

# (ii) NOT superseded → normal clean shutdown REMOVES our own beacon
printf 'host: %s\nnonce: mine\nepoch: 456\n' "$(hostname 2>/dev/null || echo unknown)" > "$HBK"
exec {INSTANCE_LOCK_FD}<>"$LCK" || fail "K(ii) could not reopen lock fd"
INSTANCE_SUPERSEDED=0
release_instance_lock; _rck=$?
eq "$_rck" 0 "K(ii) not-superseded → release returns 0"
[[ -f "$HBK" ]] && fail "K(ii) beacon should have been removed on clean shutdown" || pass "K(ii) own beacon removed on clean shutdown"
rm -rf "$TDK"

echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    exit 1
fi
