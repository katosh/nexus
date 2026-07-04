#!/usr/bin/env bash
# Tests for monitor/bootstrap-recover.sh — idempotent full-stack
# recovery after a restart (the 2026-06-07 incident: only the
# orchestrator came back; watcher + infra services stayed dead).
#
# Strategy: build an isolated fake nexus tree, copy the real
# bootstrap-recover.sh + _lib.sh in at the canonical depth, and stub
# the three things it touches — config/load.sh, watcher/launcher.sh
# (records its invocations), and tmux (a file-backed window list that
# also captures send-keys). Each case drives the decision via registry
# content, service healthchecks, tmux window state, and the watcher
# heartbeat, then asserts on the `[recover]` log lines and the
# side-effect files.
#
# Cases:
#   1.  _recover_parse_registry: comments/blanks skipped, malformed
#       skipped, valid records emitted, ~ / $NEXUS_ROOT expanded in
#       workdir AND the optional 5th <logfile> field (emitted as field 5,
#       never leaked into $health).
#   2.  Service healthy           → left alone (no launch).
#   3.  Service unhealthy + legacy tmux window present → left to it.
#   4.  Service unhealthy + no supervisor → relaunched HEADLESS: a
#       pidfile with a live pid, the wrapper really runs (marker), and
#       NO tmux window is created.
#   4b. Service unhealthy + live supervisor pidfile (matching cmdline) →
#       left alone, pidfile unchanged (no double-launch).
#   4c. Service unhealthy + stale (dead-pid) pidfile → relaunched.
#   4d. Service unhealthy + recycled pid (alive but non-matching cmdline)
#       → relaunched (the stale-PID guard, mirroring the watcher half).
#   5.  Service workdir missing    → skipped, not launched.
#   6.  --dry-run                  → decides but launches nothing.
#   7.  Watcher healthy            → launcher NOT called.
#   8.  Watcher dead               → launcher called.
#   9.  No registry                → watcher-only, exit 0.
#  10.  Recycled-PID heartbeat (live but non-watcher) reads as dead →
#       watcher relaunched (the incident's stale-lock half, via
#       _watcher_pid_is_live_watcher).
#  11.  --no-services + dead watcher + unhealthy registered service →
#       watcher relaunched, service NOT touched (core-only).
#  11b. --no-services + healthy watcher → complete no-op (idempotent).
#  12.  --services-only combined with --no-services / --watcher-only →
#       rejected (exit 1), nothing launched.
#  13.  Worker identification + inclusion criteria: only the snapshot
#       window whose latest action-log lifecycle event is `spawn` is
#       resumed; infra windows (orchestrator/services/watcher), a
#       registry-named legacy service window, wrapped / closed /
#       retain(wrap-up-*) workers, and a no-spawn-record window are
#       each skipped with a logged reason.
#  14.  Idempotency: an eligible worker whose window is already alive
#       is NOT double-spawned.
#  15.  --no-workers: services still recover, worker respawn skipped.
#  16.  Flag matrix: --no-services skips workers too (core-only);
#       --services-only still resumes workers (watcher skipped).
#  17.  Unresolvable session (spawn-worker exit 11) → loud skip,
#       overall exit 0.
#  18.  Sanity cap (RECOVER_MAX_WORKERS) → excess candidates skipped
#       with a logged notice.
#  19.  --dry-run emits the stable `would resume` marker and calls
#       nothing.
#  20.  Orchestrator-first (your-org/your-nexus#202): an absent
#       orchestrator is spawned via spawn-fresh-orchestrator BEFORE any
#       worker respawn (order.log proves ORCH < WORKER) and its window
#       is pinned to the canonical index (moved 4 → 2); the worker still
#       resumes.
#  21.  Idempotency: an already-alive orchestrator window is NEVER
#       killed/respawned (spawn-orch not called) — only re-pinned.
#  22.  Pin never clobbers: when the canonical index is held by a
#       DIFFERENT window, the orchestrator is left where it is and the
#       refusal is logged.
#  23.  Operator-engaged worker inclusion (#202): a wrapped-but-operator-
#       engaged window IS respawned (valid `_openg_marked` mark whose
#       `since` post-dates the wrap); a wrapped-and-abandoned window is
#       NOT (no resurrection of done work); the engaged set is captured
#       before the watcher relaunch.
#  24.  --no-orchestrator and --services-only both skip the orchestrator
#       step (the latter because the orchestrator is the per-turn
#       caller); workers still recover.
#
# Run: bash monitor/watcher/test-bootstrap-recover.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REAL_RECOVER="$_real_test_dir/../bootstrap-recover.sh"
REAL_LIB="$_real_test_dir/_lib.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# th_kill_fixture_pid / th_kill_own_child (PID-recycling-safe cleanup).
# shellcheck source=_test_helpers.sh
. "$_real_test_dir/_test_helpers.sh"

# Build an isolated <root>/monitor/{bootstrap-recover.sh,watcher/_lib.sh}
# tree with stubbed config, launcher, and tmux. Sets globals ROOT,
# RECOVER, REG, BIN, WINDOWS, SENDS, LAUNCHER_CALLS.
build_case() {
    local label="$1"
    ROOT=$(mktemp -d -t "nexus-recover-${label}-XXXXXX")
    mkdir -p "$ROOT/monitor/watcher" "$ROOT/monitor/.state" \
             "$ROOT/config" "$ROOT/bin"
    cp "$REAL_RECOVER" "$ROOT/monitor/bootstrap-recover.sh"
    chmod +x "$ROOT/monitor/bootstrap-recover.sh"
    cp "$REAL_LIB" "$ROOT/monitor/watcher/_lib.sh"
    # bootstrap-recover.sh sources watcher/_idle_probe.sh for the
    # operator-engagement predicate `_openg_marked` (your-org/operator-
    # nexus#202) — copy it so the engaged-capture is real, not the
    # degraded active-only fallback.
    cp "$_real_test_dir/_idle_probe.sh" "$ROOT/monitor/watcher/_idle_probe.sh"
    RECOVER="$ROOT/monitor/bootstrap-recover.sh"
    REG="$ROOT/monitor/services.registry"
    BIN="$ROOT/bin"
    WINDOWS="$ROOT/windows";    : > "$WINDOWS"
    SENDS="$ROOT/sends";        : > "$SENDS"
    LAUNCHER_CALLS="$ROOT/launcher.calls"

    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$ROOT/config/load.sh"
    chmod +x "$ROOT/config/load.sh"

    # launcher stub: just records that it was asked to run.
    printf '#!/usr/bin/env bash\necho called >> "%s"\n' "$LAUNCHER_CALLS" \
        > "$ROOT/monitor/watcher/launcher.sh"
    chmod +x "$ROOT/monitor/watcher/launcher.sh"

    # tmux stub: file-backed window list ($WINDOWS), capture send-keys.
    cat > "$BIN/tmux" <<TM
#!/usr/bin/env bash
case "\$1" in
  list-windows) cat "$WINDOWS" 2>/dev/null ;;
  has-session)  exit 0 ;;
  new-window)   shift
                while [ \$# -gt 0 ]; do
                  [ "\$1" = "-n" ] && echo "\$2" >> "$WINDOWS"
                  shift
                done ;;
  send-keys)    echo "\${@:2}" >> "$SENDS" ;;
  *)            : ;;
esac
exit 0
TM
    chmod +x "$BIN/tmux"

    # spawn-worker stub at the production default path
    # ($_script_dir/spawn-worker.sh): records its argv, exits with the
    # rc staged in $ROOT/spawn-worker.rc (default 0). Never touches
    # tmux — worker-respawn tests assert on the recorded calls.
    SPAWN_CALLS="$ROOT/spawn-worker.calls"
    cat > "$ROOT/monitor/spawn-worker.sh" <<SW
#!/usr/bin/env bash
echo "WORKER \$*" >> "$ROOT/order.log"
echo "\$*" >> "$SPAWN_CALLS"
rc=0
[ -f "$ROOT/spawn-worker.rc" ] && read -r rc < "$ROOT/spawn-worker.rc"
exit "\$rc"
SW
    chmod +x "$ROOT/monitor/spawn-worker.sh"

    # spawn-fresh-orchestrator stub at the production default path
    # ($_script_dir/watcher/spawn-fresh-orchestrator.sh): records its
    # argv to $ORCH_CALLS (with a monotonic ORDER marker so a test can
    # prove orchestrator-before-workers), exits with the rc staged in
    # $ROOT/spawn-orch.rc (default 0). By default it does NOT create a
    # window (the simple tmux stub has no index model); the
    # orchestrator/pin cases install their own richer stub.
    ORCH_CALLS="$ROOT/spawn-orch.calls"
    cat > "$ROOT/monitor/watcher/spawn-fresh-orchestrator.sh" <<SO
#!/usr/bin/env bash
echo "ORCH \$*" >> "$ROOT/order.log"
echo "\$*" >> "$ORCH_CALLS"
rc=0
[ -f "$ROOT/spawn-orch.rc" ] && read -r rc < "$ROOT/spawn-orch.rc"
exit "\$rc"
SO
    chmod +x "$ROOT/monitor/watcher/spawn-fresh-orchestrator.sh"
}

# Seed $STATE_DIR/last-snapshot.txt with the given tmux window names
# (one per arg), in the watcher's canonical three-section shape.
seed_snapshot() {
    {
        echo '--- reports ---'
        echo '--- tmux ---'
        local w
        for w in "$@"; do echo "$w bell=0"; done
        echo '--- git ---'
    } > "$ROOT/monitor/.state/last-snapshot.txt"
}

# Append one action-log event: log_event <event> <window> [extra-json].
log_event() {
    printf '{"ts":"2026-06-10T12:00:00-07:00","agent":"monitor","event":"%s","window":"%s"%s}\n' \
        "$1" "$2" "${3:-}" >> "$ROOT/monitor/.state/action-log.jsonl"
}

# Seed an operator-engaged.tsv row that `_openg_marked` accepts as VALID
# (your-org/your-nexus#202): `since`/`last` an hour AFTER the fixed
# 12:00:00 ts that log_event stamps on spawn/wrap-up — i.e. the operator
# RE-engaged after the window wrapped — so `since` > the wrap epoch and
# the spawn-lifecycle guard (spawn_epoch <= since) both pass. Row layout:
# <window>\t<since>\t<last>\t<prompt_seen>\t<src>\t<reminded>.
#
# The your-org/your-nexus#205 follow-up adds a self-expiry gate: a mark
# is VALID only while its pane changed within the change TTL (default
# 600 s). The gate reads real wall-clock `now`, so we stamp the
# pane-change clock at NOW (not the fixed fixture ts) to keep the mark
# live — modelling a window the operator is still actively driving.
seed_engaged() {
    local window="$1" base since now
    base=$(date -d '2026-06-10T12:00:00-07:00' +%s)
    since=$(( base + 3600 ))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$window" "$since" "$since" "$since" "submit-after-wrap" 0 \
        >> "$ROOT/monitor/.state/operator-engaged.tsv"
    now=$(date +%s)
    mkdir -p "$ROOT/monitor/.state/pane-change"
    printf 'h\t%s\n' "$now" > "$ROOT/monitor/.state/pane-change/$window"
}

# Replace the simple tmux stub with an INDEXED model (for the
# orchestrator-pin cases): windows live in $BIN/wins as `index<TAB>name`
# lines, single session `0`. Honours `list-windows -a/-t/-F`,
# `new-window -n`, `move-window -d -s 0:CUR -t 0:IDX` (fails if IDX held
# by a different window), and `kill-window -t NAME`. Seeds an empty
# fixture; the caller populates $BIN/wins.
install_indexed_tmux() {
    : > "$BIN/wins"
    cat > "$BIN/tmux" <<'TM'
#!/usr/bin/env bash
TW="$(dirname "$0")/wins"
cmd="${1:-}"; shift || true
emit_fmt() {
    local fmt="$1" idx name line
    while IFS=$'\t' read -r idx name; do
        [ -n "$idx" ] || continue
        line="$fmt"
        line="${line//'#{session_name}'/0}"
        line="${line//'#{window_index}'/$idx}"
        line="${line//'#{window_name}'/$name}"
        line="${line//'#{window_active}'/0}"
        line="${line//'#{window_bell_flag}'/0}"
        printf '%s\n' "$line"
    done < "$TW"
}
case "$cmd" in
  list-windows)
    fmt='#{window_name}'
    while [ $# -gt 0 ]; do
      case "$1" in
        -F) fmt="$2"; shift 2 ;;
        -t) shift 2 ;;
        -a|-d) shift ;;
        *)  shift ;;
      esac
    done
    emit_fmt "$fmt" ;;
  has-session) exit 0 ;;
  new-window)
    name=""
    while [ $# -gt 0 ]; do [ "$1" = "-n" ] && name="$2"; shift; done
    if [ -n "$name" ]; then
      maxi=0
      while IFS=$'\t' read -r i n; do [ -n "$i" ] && [ "$i" -gt "$maxi" ] && maxi="$i"; done < "$TW"
      printf '%s\t%s\n' "$((maxi+1))" "$name" >> "$TW"
    fi ;;
  move-window)
    src=""; dst=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) src="$2"; shift 2 ;;
        -t) dst="$2"; shift 2 ;;
        -d) shift ;;
        *)  shift ;;
      esac
    done
    sidx="${src##*:}"; didx="${dst##*:}"
    occ=$(awk -F'\t' -v d="$didx" '$1==d{print $2; exit}' "$TW")
    [ -n "$occ" ] && exit 1
    tmp="$TW.tmp"
    awk -F'\t' -v s="$sidx" -v d="$didx" 'BEGIN{OFS="\t"} $1==s{$1=d} {print}' "$TW" > "$tmp" && mv "$tmp" "$TW" ;;
  kill-window)
    nm=""
    while [ $# -gt 0 ]; do [ "$1" = "-t" ] && nm="$2"; shift; done
    tmp="$TW.tmp"; awk -F'\t' -v n="$nm" '$2!=n' "$TW" > "$tmp" && mv "$tmp" "$TW" ;;
  *) : ;;
esac
exit 0
TM
    chmod +x "$BIN/tmux"
}

cleanup_case() {
    # All kills identity-verified (th_kill_*): a pidfile can name a PID
    # that died mid-case, and after a PID-space wrap a blind kill would
    # signal whatever innocent process recycled the number (see the
    # helper header in _test_helpers.sh).
    # Reap any faux watcher we spawned for the heartbeat (its argv
    # carries the $ROOT-prefixed script path).
    [[ -n "${FAUX_PID:-}" ]] && th_kill_fixture_pid "$FAUX_PID" "$ROOT"
    # Reap any HEADLESS service the recovery path really launched (setsid'd
    # supervisors outlive the recovery subshell — kill them by pidfile;
    # their cwd is inside $ROOT).
    local pf p
    for pf in "$ROOT"/monitor/.state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r p < "$pf" 2>/dev/null
        [[ "$p" =~ ^[0-9]+$ ]] && th_kill_fixture_pid "$p" "$ROOT"
    done
    # Reap any helper PID a case spawned explicitly (live-supervisor /
    # recycled-pid fixtures).
    [[ -n "${HELPER_PID:-}" ]] && th_kill_own_child "$HELPER_PID"
    rm -rf "$ROOT"
    unset ROOT RECOVER REG BIN WINDOWS SENDS LAUNCHER_CALLS SPAWN_CALLS ORCH_CALLS FAUX_PID HELPER_PID
}

# Write a heartbeat whose pid is alive AND argv-identified as a watcher
# (so _watcher_alive treats it as healthy). Adds "watcher" to the
# window list. Sets FAUX_PID.
seed_healthy_watcher() {
    mkdir -p "$ROOT/faux/monitor/watcher"
    printf '#!/usr/bin/env bash\nsleep 60\n' > "$ROOT/faux/monitor/watcher/main.sh"
    chmod +x "$ROOT/faux/monitor/watcher/main.sh"
    bash "$ROOT/faux/monitor/watcher/main.sh" &
    FAUX_PID=$!
    sleep 0.2
    printf 'pid=%d\nts=%s\ntarget=orchestrator\n' "$FAUX_PID" "$(date -Is)" \
        > "$ROOT/monitor/.state/watcher-heartbeat"
    echo watcher >> "$WINDOWS"
}

run_recover() {
    PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
        bash "$RECOVER" "$@" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?
}

# Tab-joined registry line helpers (keep the literal tabs unambiguous).
reg_line()  { printf '%s\t%s\t%s\t%s\n'     "$1" "$2" "$3" "$4"; }
reg_line5() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

# Pidfile path for a service (mirrors _recover_pidfile in the script).
svc_pidfile() { printf '%s/monitor/.state/services/%s.pid' "$ROOT" "$1"; }

# Write an executable fake supervisor in <workdir>/<script>: it touches a
# marker so a launch is observable, then loops forever (a stand-in for a
# real supervised-restart wrapper). Echoes nothing; caller wires it up.
make_fake_wrapper() {
    local workdir="$1" script="$2" marker="$3"
    cat > "$workdir/$script" <<EOF
#!/usr/bin/env bash
echo "up \$\$" > "$marker"
while true; do sleep 1; done
EOF
    chmod +x "$workdir/$script"
}

# --- Case 1: parse_registry -------------------------------------------------
echo '=== case 1: _recover_parse_registry — comments/blanks/malformed/expansion ==='
build_case 1
export NEXUS_ROOT="$ROOT"
# shellcheck source=/dev/null
source "$RECOVER"   # sourcing: defines functions, does not run main
{
    echo '# a comment'
    echo ''
    reg_line svcA '~/wd-a' 'echo a' 'true'
    echo 'missing tabs here'
    reg_line svcB '$NEXUS_ROOT/wd-b' 'echo b' 'false'
} > "$REG"
parsed=$(_recover_parse_registry "$REG")
if [[ "$(printf '%s\n' "$parsed" | wc -l)" == "2" ]]; then
    pass "two valid records emitted (comment/blank/malformed dropped)"
else
    fail "expected 2 records, got: $parsed"
fi
if printf '%s\n' "$parsed" | grep -qF "$HOME/wd-a"; then
    pass "~ expanded to \$HOME in workdir"
else
    fail "~ not expanded: $parsed"
fi
if printf '%s\n' "$parsed" | grep -qF "$ROOT/wd-b"; then
    pass "\$NEXUS_ROOT expanded in workdir"
else
    fail "\$NEXUS_ROOT not expanded: $parsed"
fi
# 5-field row (optional <logfile>): the field is now EMITTED as its own
# 5th field (the headless launcher appends stdout there) and crucially
# must NOT leak into $health — a leak would corrupt the healthcheck and
# trigger spurious relaunches. $NEXUS_ROOT is expanded in the logfile.
printf 'svcC\t%s/wd-c\techo c\tcurl -fsS http://localhost:9/\t$NEXUS_ROOT/wd-c/c.log\n' \
    "$ROOT" > "$REG"
p5=$(_recover_parse_registry "$REG")
nf5=$(printf '%s' "$p5" | awk -F'\t' 'NR==1{print NF}')
h5=$(printf '%s' "$p5" | awk -F'\t' 'NR==1{print $4}')
l5=$(printf '%s' "$p5" | awk -F'\t' 'NR==1{print $5}')
if [[ "$nf5" == 5 && "$h5" == 'curl -fsS http://localhost:9/' ]]; then
    pass "5-field row: <logfile> emitted as field 5, healthcheck stays clean"
else
    fail "5-field parse leaked logfile into health: NF=$nf5 health=[$h5]"
fi
if [[ "$l5" == "$ROOT/wd-c/c.log" ]]; then
    pass "5-field row: \$NEXUS_ROOT expanded in <logfile>"
else
    fail "logfile not expanded: [$l5]"
fi
unset NEXUS_ROOT
cleanup_case

# --- Case 2: healthy service left alone -------------------------------------
echo '=== case 2: healthy service → not relaunched ==='
build_case 2
seed_healthy_watcher
mkdir -p "$ROOT/svcA"
reg_line svcA "$ROOT/svcA" 'echo boot' 'true' > "$REG"
run_recover --services-only
if grep -q "service 'svcA': healthy" "$ROOT/err" && [[ ! -s "$SENDS" ]]; then
    pass "healthy service skipped, no window launched"
else
    fail "rc=$RC err=$(cat "$ROOT/err") sends=$(cat "$SENDS")"
fi
cleanup_case

# --- Case 3: unhealthy + window present → leave to supervisor ----------------
echo '=== case 3: unhealthy but window present → not relaunched ==='
build_case 3
mkdir -p "$ROOT/svcA"
echo svcA >> "$WINDOWS"            # window already present
reg_line svcA "$ROOT/svcA" 'echo boot' 'false' > "$REG"
run_recover --services-only
if grep -q "window present" "$ROOT/err" && [[ ! -s "$SENDS" ]]; then
    pass "unhealthy+window-present left to its supervisor (no double-launch)"
else
    fail "err=$(cat "$ROOT/err") sends=$(cat "$SENDS")"
fi
cleanup_case

# --- Case 4: unhealthy + no supervisor → relaunch HEADLESS -------------------
echo '=== case 4: unhealthy + no supervisor → relaunched headless (pidfile, no window) ==='
build_case 4
mkdir -p "$ROOT/svcA"
make_fake_wrapper "$ROOT/svcA" run.sh "$ROOT/svcA/started"
reg_line svcA "$ROOT/svcA" './run.sh' 'false' > "$REG"
run_recover --services-only
sleep 0.4   # let the setsid'd inner shell write the pidfile + run the wrapper
pf=$(svc_pidfile svcA)
if grep -q "service 'svcA': relaunched headless" "$ROOT/err"; then
    pass "unhealthy+no-supervisor relaunched headless"
else
    fail "no headless relaunch logged: $(cat "$ROOT/err")"
fi
p=''; [[ -f "$pf" ]] && read -r p < "$pf"
if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; then
    pass "pidfile written with a live supervisor pid ($p)"
else
    fail "pidfile missing/dead: pf=$pf content=$(cat "$pf" 2>/dev/null)"
fi
if [[ -f "$ROOT/svcA/started" ]]; then
    pass "supervisor actually ran (marker written)"
else
    fail "marker not written — wrapper did not start"
fi
if ! grep -qx svcA "$WINDOWS"; then
    pass "no tmux window created (headless)"
else
    fail "a tmux window was created: $(cat "$WINDOWS")"
fi
cleanup_case

# --- Case 4b: unhealthy + live supervisor pidfile → left alone --------------
echo '=== case 4b: unhealthy + live supervisor pidfile (matching cmdline) → left alone ==='
build_case 4b
mkdir -p "$ROOT/svcA" "$ROOT/monitor/.state/services"
make_fake_wrapper "$ROOT/svcA" run.sh "$ROOT/svcA/started"
# Stand in for a prior headless launch: run the supervisor, record its pid.
( cd "$ROOT/svcA" && exec ./run.sh ) &
HELPER_PID=$!
sleep 0.3
echo "$HELPER_PID" > "$(svc_pidfile svcA)"
reg_line svcA "$ROOT/svcA" './run.sh' 'false' > "$REG"
run_recover --services-only
if grep -q "supervisor pid alive" "$ROOT/err"; then
    pass "live supervisor (matching cmdline) left to itself"
else
    fail "expected supervisor-alive; err=$(cat "$ROOT/err")"
fi
read -r p2 < "$(svc_pidfile svcA)"
if [[ "$p2" == "$HELPER_PID" ]]; then
    pass "pidfile unchanged — no double-launch"
else
    fail "pidfile changed $HELPER_PID -> $p2 (double-launched!)"
fi
cleanup_case

# --- Case 4c: stale pidfile (dead pid) → relaunch ---------------------------
echo '=== case 4c: stale pidfile (dead pid) → relaunched ==='
build_case 4c
mkdir -p "$ROOT/svcA" "$ROOT/monitor/.state/services"
make_fake_wrapper "$ROOT/svcA" run.sh "$ROOT/svcA/started"
( exec true ) & deadpid=$!; wait "$deadpid" 2>/dev/null   # a pid that is now dead
echo "$deadpid" > "$(svc_pidfile svcA)"
reg_line svcA "$ROOT/svcA" './run.sh' 'false' > "$REG"
run_recover --services-only
sleep 0.4
if grep -q "relaunched headless" "$ROOT/err"; then
    pass "stale (dead-pid) pidfile → relaunched"
else
    fail "expected relaunch on stale pidfile; err=$(cat "$ROOT/err")"
fi
read -r p3 < "$(svc_pidfile svcA)"
if [[ "$p3" != "$deadpid" ]] && kill -0 "$p3" 2>/dev/null; then
    pass "pidfile refreshed to a fresh live pid ($p3)"
else
    fail "pidfile not refreshed: dead=$deadpid now=$p3"
fi
cleanup_case

# --- Case 4d: recycled pid (alive, cmdline mismatch) → relaunch -------------
echo '=== case 4d: recycled pid (alive but non-matching cmdline) → relaunched ==='
build_case 4d
mkdir -p "$ROOT/svcA" "$ROOT/monitor/.state/services"
make_fake_wrapper "$ROOT/svcA" run.sh "$ROOT/svcA/started"
sleep 60 & HELPER_PID=$!          # live pid whose cmdline ("sleep 60") != wrapper
echo "$HELPER_PID" > "$(svc_pidfile svcA)"
reg_line svcA "$ROOT/svcA" './run.sh' 'false' > "$REG"
run_recover --services-only
sleep 0.4
if grep -q "relaunched headless" "$ROOT/err"; then
    pass "alive-but-non-matching pid treated as stale → relaunched (stale-PID guard)"
else
    fail "expected relaunch on recycled pid; err=$(cat "$ROOT/err")"
fi
read -r p4 < "$(svc_pidfile svcA)"
if [[ "$p4" != "$HELPER_PID" ]] && kill -0 "$p4" 2>/dev/null; then
    pass "pidfile refreshed to the real supervisor ($p4), not the recycled pid"
else
    fail "pidfile not refreshed: recycled=$HELPER_PID now=$p4"
fi
cleanup_case

# --- Case 5: workdir missing → skip -----------------------------------------
echo '=== case 5: workdir missing → skipped, not launched ==='
build_case 5
reg_line svcGone "$ROOT/does-not-exist" 'echo boot' 'false' > "$REG"
run_recover --services-only
if grep -q "workdir missing" "$ROOT/err" && [[ ! -s "$SENDS" ]]; then
    pass "missing-workdir service skipped"
else
    fail "err=$(cat "$ROOT/err") sends=$(cat "$SENDS")"
fi
cleanup_case

# --- Case 6: --dry-run launches nothing -------------------------------------
echo '=== case 6: --dry-run → decides but launches nothing ==='
build_case 6
mkdir -p "$ROOT/svcA"
reg_line svcA "$ROOT/svcA" 'echo boot' 'false' > "$REG"
run_recover --services-only --dry-run
if grep -q "would relaunch" "$ROOT/err" && [[ ! -f "$(svc_pidfile svcA)" ]]; then
    pass "dry-run logged intent without launching (no pidfile)"
else
    fail "err=$(cat "$ROOT/err") pidfile=$(cat "$(svc_pidfile svcA)" 2>/dev/null)"
fi
cleanup_case

# --- Case 7: watcher healthy → launcher NOT called --------------------------
echo '=== case 7: watcher healthy → launcher not called ==='
build_case 7
seed_healthy_watcher
run_recover --watcher-only
if grep -q "watcher: healthy" "$ROOT/err" && [[ ! -f "$LAUNCHER_CALLS" ]]; then
    pass "healthy watcher → no relaunch"
else
    fail "err=$(cat "$ROOT/err") launcher=$(cat "$LAUNCHER_CALLS" 2>/dev/null)"
fi
cleanup_case

# --- Case 8: watcher dead → launcher called ---------------------------------
echo '=== case 8: watcher missing heartbeat → launcher called ==='
build_case 8
# No heartbeat at all → _watcher_alive bucket 3 → relaunch.
run_recover --watcher-only
if [[ -f "$LAUNCHER_CALLS" ]] && grep -q called "$LAUNCHER_CALLS"; then
    pass "dead watcher → launcher invoked"
else
    fail "launcher not called; err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 9: no registry → watcher-only, exit 0 -----------------------------
echo '=== case 9: no registry → watcher-only recovery, exit 0 ==='
build_case 9
seed_healthy_watcher
# Deliberately do NOT create $REG.
run_recover
if (( RC == 0 )) && grep -q "no service registry" "$ROOT/err"; then
    pass "missing registry degrades to watcher-only, exit 0"
else
    fail "rc=$RC err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 10: recycled-PID heartbeat reads as dead → watcher relaunch -------
echo '=== case 10: live-but-non-watcher heartbeat pid → relaunch (incident half) ==='
build_case 10
# A live process that is NOT a watcher (bare sleep) standing in for a
# recycled low PID after a restart. The heartbeat names it; the tmux
# "watcher" window is present. Pre-fix this read as alive and recovery
# no-op'd; post-fix the identity check treats it as dead.
sleep 60 & RECYCLED=$!
printf 'pid=%d\nts=%s\ntarget=orchestrator\n' "$RECYCLED" "$(date -Is)" \
    > "$ROOT/monitor/.state/watcher-heartbeat"
echo watcher >> "$WINDOWS"
run_recover --watcher-only
if [[ -f "$LAUNCHER_CALLS" ]] && grep -q called "$LAUNCHER_CALLS"; then
    pass "recycled-PID heartbeat treated as dead → watcher relaunched"
else
    fail "launcher not called on recycled pid; err=$(cat "$ROOT/err")"
fi
kill "$RECYCLED" 2>/dev/null || true
cleanup_case

# --- Case 11: --no-services → core up, zero services -------------------------
echo '=== case 11: --no-services + dead watcher + unhealthy service → watcher relaunched, service untouched ==='
build_case 11
mkdir -p "$ROOT/svcA"
make_fake_wrapper "$ROOT/svcA" run.sh "$ROOT/svcA/started"
# No heartbeat at all → watcher reads as dead; svcA is unhealthy and
# would be relaunched by a full run.
reg_line svcA "$ROOT/svcA" './run.sh' 'false' > "$REG"
run_recover --no-services
sleep 0.4
if (( RC == 0 )) && [[ -f "$LAUNCHER_CALLS" ]] && grep -q called "$LAUNCHER_CALLS"; then
    pass "--no-services: dead watcher relaunched (core comes up)"
else
    fail "rc=$RC launcher=$(cat "$LAUNCHER_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
if [[ ! -f "$(svc_pidfile svcA)" && ! -f "$ROOT/svcA/started" ]] \
   && ! grep -q "service 'svcA'" "$ROOT/err"; then
    pass "--no-services: unhealthy registered service NOT touched (zero services)"
else
    fail "service touched: pidfile=$(cat "$(svc_pidfile svcA)" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
if grep -q "services: skipped" "$ROOT/err"; then
    pass "--no-services: skip is logged (evidence trail)"
else
    fail "no skip log line: $(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 11b: --no-services on a healthy core → complete no-op --------------
echo '=== case 11b: --no-services + healthy watcher → idempotent no-op ==='
build_case 11b
seed_healthy_watcher
mkdir -p "$ROOT/svcA"
reg_line svcA "$ROOT/svcA" 'echo boot' 'false' > "$REG"
run_recover --no-services
if (( RC == 0 )) && grep -q "watcher: healthy" "$ROOT/err" \
   && [[ ! -f "$LAUNCHER_CALLS" && ! -f "$(svc_pidfile svcA)" ]]; then
    pass "--no-services twice-runnable: healthy core untouched, no service launched"
else
    fail "rc=$RC launcher=$(cat "$LAUNCHER_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 12: conflicting flag combos rejected --------------------------------
echo '=== case 12: --services-only + --no-services/--watcher-only → exit 1, nothing launched ==='
build_case 12
mkdir -p "$ROOT/svcA"
reg_line svcA "$ROOT/svcA" 'echo boot' 'false' > "$REG"
run_recover --services-only --no-services
if (( RC == 1 )) && grep -q "recovers nothing" "$ROOT/err"; then
    pass "--services-only --no-services rejected with a clear error"
else
    fail "rc=$RC err=$(cat "$ROOT/err")"
fi
run_recover --no-services --services-only
if (( RC == 1 )); then
    pass "order-independent rejection (--no-services --services-only)"
else
    fail "rc=$RC err=$(cat "$ROOT/err")"
fi
run_recover --services-only --watcher-only
if (( RC == 1 )); then
    pass "--services-only --watcher-only (synonym) also rejected"
else
    fail "rc=$RC err=$(cat "$ROOT/err")"
fi
if [[ ! -f "$LAUNCHER_CALLS" && ! -f "$(svc_pidfile svcA)" ]]; then
    pass "rejected combos launched nothing"
else
    fail "launcher=$(cat "$LAUNCHER_CALLS" 2>/dev/null) pidfile=$(cat "$(svc_pidfile svcA)" 2>/dev/null)"
fi
cleanup_case

# --- Case 13: worker identification + inclusion criteria ---------------------
echo '=== case 13: snapshot workers — infra/registry/wrapped/closed/no-record excluded, active resumed ==='
build_case 13
seed_healthy_watcher
# Registry: one healthy legacy windowed service whose window name is in
# the snapshot — must be excluded from worker respawn.
mkdir -p "$ROOT/svcleg"
reg_line svcleg "$ROOT/svcleg" 'echo leg' 'true' > "$REG"
seed_snapshot orchestrator services watcher svcleg \
              w-wrapped w-closed w-retained w-norecord w-active
log_event spawn w-wrapped
log_event wrap-up w-wrapped
log_event spawn w-closed
log_event window-close w-closed
log_event spawn w-retained
log_event window-retain w-retained ',"reason":"wrap-up-2026-06-11"'
log_event spawn w-active
run_recover
if [[ -f "$SPAWN_CALLS" ]] && [[ "$(cat "$SPAWN_CALLS")" == "--resume w-active" ]]; then
    pass "exactly one resume: spawn-worker --resume w-active"
else
    fail "spawn calls: $(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
ok=1
for probe in \
    "worker 'orchestrator': infra window" \
    "worker 'services': infra window" \
    "worker 'svcleg': registered service window" \
    "worker 'w-wrapped': already wrapped/closed" \
    "worker 'w-closed': already wrapped/closed" \
    "worker 'w-retained': already wrapped/closed" \
    "worker 'w-norecord': no spawn record"; do
    grep -qF "$probe" "$ROOT/err" || { fail "missing skip line: $probe"; ok=0; }
done
(( ok == 1 )) && pass "every exclusion logged with its reason (loud-on-skip)"
if grep -q "workers: 1 candidate(s) — 1 resumed" "$ROOT/err"; then
    pass "summary tallies one resumed worker"
else
    fail "summary line wrong: $(grep 'workers:' "$ROOT/err")"
fi
cleanup_case

# --- Case 13b: infra exclusion tracks config-resolved window names -----------
# your-nexus#204: the orchestrator ($TARGET_WINDOW) and cockpit
# ($SERVICES_WINDOW) exclusions must follow the configured/overridden
# names, not a hardcoded `orchestrator`/`services` literal. Override both
# to non-default names and confirm a snapshot window of each is still
# treated as infra (not respawned as a worker), while a real worker resumes.
echo '=== case 13b: renamed orchestrator/cockpit windows still excluded as infra ==='
build_case 13b
seed_healthy_watcher
seed_snapshot orch2 cockpit2 watcher w-active
log_event spawn w-active
RECOVER_TARGET_WINDOW=orch2 MONITOR_SERVICES_WINDOW=cockpit2 run_recover
if [[ -f "$SPAWN_CALLS" ]] && [[ "$(cat "$SPAWN_CALLS")" == "--resume w-active" ]]; then
    pass "renamed-infra case: exactly one resume (w-active)"
else
    fail "spawn calls: $(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
ok=1
for probe in \
    "worker 'orch2': infra window" \
    "worker 'cockpit2': infra window"; do
    grep -qF "$probe" "$ROOT/err" || { fail "missing skip line: $probe"; ok=0; }
done
(( ok == 1 )) && pass "renamed orchestrator + cockpit excluded as infra (config respected)"
cleanup_case

# --- Case 14: idempotency — already-alive window not double-spawned ----------
echo '=== case 14: eligible worker whose window is already alive → skipped, no double-spawn ==='
build_case 14
seed_healthy_watcher
seed_snapshot w-active
log_event spawn w-active
echo w-active >> "$WINDOWS"     # the window survived / was already respawned
run_recover
if [[ ! -f "$SPAWN_CALLS" ]] && grep -q "worker 'w-active': window already alive" "$ROOT/err"; then
    pass "already-alive window skipped, spawn-worker never called"
else
    fail "spawn calls: $(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 15: --no-workers — services recover, workers skipped ---------------
echo '=== case 15: --no-workers + unhealthy service + eligible worker → service relaunched, worker skipped ==='
build_case 15
seed_healthy_watcher
mkdir -p "$ROOT/svcA"
make_fake_wrapper "$ROOT/svcA" run.sh "$ROOT/svcA/started"
reg_line svcA "$ROOT/svcA" './run.sh' 'false' > "$REG"
seed_snapshot w-active
log_event spawn w-active
run_recover --no-workers
sleep 0.4
if (( RC == 0 )) && [[ -f "$ROOT/svcA/started" ]]; then
    pass "--no-workers: unhealthy service still relaunched"
else
    fail "rc=$RC started=$(ls "$ROOT/svcA" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
if [[ ! -f "$SPAWN_CALLS" ]] && grep -q "workers: skipped" "$ROOT/err"; then
    pass "--no-workers: worker respawn skipped and logged"
else
    fail "spawn calls: $(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 16: flag matrix — --no-services skips workers; --services-only keeps them
echo '=== case 16: --no-services skips workers too; --services-only still resumes them ==='
build_case 16
seed_healthy_watcher
seed_snapshot w-active
log_event spawn w-active
run_recover --no-services
if (( RC == 0 )) && [[ ! -f "$SPAWN_CALLS" ]] && grep -q "workers: skipped" "$ROOT/err"; then
    pass "--no-services (core-only) skips worker respawn"
else
    fail "rc=$RC spawn calls: $(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
run_recover --services-only
if (( RC == 0 )) && [[ -f "$SPAWN_CALLS" ]] \
   && grep -q -- "--resume w-active" "$SPAWN_CALLS" \
   && [[ ! -f "$LAUNCHER_CALLS" ]]; then
    pass "--services-only: watcher skipped, worker resumed"
else
    fail "rc=$RC spawn=$(cat "$SPAWN_CALLS" 2>/dev/null) launcher=$(cat "$LAUNCHER_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 17: unresolvable session → loud skip, never fatal -------------------
echo '=== case 17: spawn-worker exit 11 (session unresolvable) → loud skip, exit 0 ==='
build_case 17
seed_healthy_watcher
seed_snapshot w-lost
log_event spawn w-lost
echo 11 > "$ROOT/spawn-worker.rc"
run_recover
if (( RC == 0 )) && grep -q "worker 'w-lost': SKIPPED — session-id unresolvable" "$ROOT/err" \
   && grep -q "workers: 1 candidate(s) — 0 resumed, 0 already alive, 1 skipped" "$ROOT/err"; then
    pass "unresolvable session skipped loudly, recovery exits 0"
else
    fail "rc=$RC err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 18: sanity cap bounds the respawn fan-out ---------------------------
echo '=== case 18: RECOVER_MAX_WORKERS=2 with 3 candidates → third skipped with notice ==='
build_case 18
seed_healthy_watcher
seed_snapshot w-a w-b w-c
log_event spawn w-a
log_event spawn w-b
log_event spawn w-c
PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" RECOVER_MAX_WORKERS=2 \
    bash "$RECOVER" >"$ROOT/out" 2>"$ROOT/err"
RC=$?
if (( RC == 0 )) && [[ "$(wc -l < "$SPAWN_CALLS")" == "2" ]] \
   && grep -q "sanity cap recover.max_workers=2 reached" "$ROOT/err" \
   && grep -q "1 over cap" "$ROOT/err"; then
    pass "cap enforced: 2 resumed, third skipped with logged notice"
else
    fail "rc=$RC spawn=$(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 19: --dry-run emits the stable `would resume` marker ----------------
echo '=== case 19: --dry-run → would-resume marker, spawn-worker never called ==='
build_case 19
seed_healthy_watcher
seed_snapshot w-active
log_event spawn w-active
run_recover --dry-run
if (( RC == 0 )) && [[ ! -f "$SPAWN_CALLS" ]] \
   && grep -q "worker 'w-active': would resume" "$ROOT/err"; then
    pass "--dry-run decides + logs the would-resume marker, launches nothing"
else
    fail "rc=$RC spawn=$(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 20: orchestrator-first — spawned BEFORE workers, pinned to slot
echo '=== case 20: orchestrator absent → spawned FIRST (before workers) + pinned to canonical index 2 ==='
build_case 20
seed_healthy_watcher
install_indexed_tmux
printf '1\tservices\n' > "$BIN/wins"          # orchestrator + w-active both absent; index 2 free
# Override the spawn-orch stub so the orchestrator "lands" at a NON-
# canonical index (4) — the pin must then move it to 2.
cat > "$ROOT/monitor/watcher/spawn-fresh-orchestrator.sh" <<SO
#!/usr/bin/env bash
echo "ORCH \$*" >> "$ROOT/order.log"
echo "\$*" >> "$ORCH_CALLS"
printf '4\torchestrator\n' >> "$BIN/wins"
exit 0
SO
chmod +x "$ROOT/monitor/watcher/spawn-fresh-orchestrator.sh"
seed_snapshot w-active
log_event spawn w-active
run_recover
if [[ -f "$ORCH_CALLS" ]] && grep -q -- "--target orchestrator" "$ORCH_CALLS"; then
    pass "orchestrator spawned via spawn-fresh-orchestrator (--target orchestrator)"
else
    fail "spawn-orch not called: $(cat "$ORCH_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
orch_line=$(grep -n ORCH "$ROOT/order.log" | head -1 | cut -d: -f1)
worker_line=$(grep -n WORKER "$ROOT/order.log" | head -1 | cut -d: -f1)
if [[ -n "$orch_line" && -n "$worker_line" ]] && (( orch_line < worker_line )); then
    pass "orchestrator brought up BEFORE workers (order.log: ORCH@$orch_line < WORKER@$worker_line)"
else
    fail "ordering wrong: ORCH@$orch_line WORKER@$worker_line order.log=$(cat "$ROOT/order.log" 2>/dev/null)"
fi
if grep -qP '^2\torchestrator$' "$BIN/wins" && grep -q "pinned to canonical window index 2 (was 4)" "$ROOT/err"; then
    pass "orchestrator window pinned to canonical index 2 (moved from 4)"
else
    fail "not pinned: wins=$(cat "$BIN/wins") err=$(grep orchestrator "$ROOT/err")"
fi
if [[ -f "$SPAWN_CALLS" ]] && [[ "$(cat "$SPAWN_CALLS")" == "--resume w-active" ]]; then
    pass "worker w-active still resumed after orchestrator-first"
else
    fail "worker not resumed: $(cat "$SPAWN_CALLS" 2>/dev/null)"
fi
cleanup_case

# --- Case 21: orchestrator already alive → not respawned, only re-pinned
echo '=== case 21: orchestrator already alive (wrong index) → NOT respawned, re-pinned to 2 ==='
build_case 21
seed_healthy_watcher
install_indexed_tmux
printf '1\tservices\n4\torchestrator\n' > "$BIN/wins"   # present, wrong index
run_recover --no-workers
if [[ ! -f "$ORCH_CALLS" ]] && grep -q "already alive — not respawning" "$ROOT/err"; then
    pass "live orchestrator NOT killed/respawned (spawn-orch never called)"
else
    fail "spawn-orch called or not logged: orch=$(cat "$ORCH_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
if grep -qP '^2\torchestrator$' "$BIN/wins" && grep -q "pinned to canonical window index 2 (was 4)" "$ROOT/err"; then
    pass "already-alive orchestrator re-pinned 4 → 2"
else
    fail "not re-pinned: wins=$(cat "$BIN/wins") err=$(grep orchestrator "$ROOT/err")"
fi
cleanup_case

# --- Case 22: pin refuses to clobber a different window in the slot
echo '=== case 22: canonical index held by a different window → pin refuses (no clobber) ==='
build_case 22
seed_healthy_watcher
install_indexed_tmux
printf '1\tservices\n2\tsomeworker\n4\torchestrator\n' > "$BIN/wins"
run_recover --no-workers
if grep -q "canonical index 2 held by 'someworker' — NOT moving" "$ROOT/err"; then
    pass "pin refuses when slot occupied by a different window (logged loudly)"
else
    fail "no refusal logged: $(grep orchestrator "$ROOT/err")"
fi
if grep -qP '^4\torchestrator$' "$BIN/wins" && grep -qP '^2\tsomeworker$' "$BIN/wins"; then
    pass "no clobber: orchestrator left at 4, someworker untouched at 2"
else
    fail "windows mutated: $(cat "$BIN/wins")"
fi
cleanup_case

# --- Case 23: operator-engaged inclusion (the #202 worker fix) ----------------
echo '=== case 23: wrapped-but-operator-engaged respawned; wrapped-and-abandoned skipped ==='
build_case 23
seed_healthy_watcher
seed_snapshot w-active w-wrapped-engaged w-wrapped-plain
log_event spawn w-active
log_event spawn w-wrapped-engaged
log_event wrap-up w-wrapped-engaged
log_event spawn w-wrapped-plain
log_event wrap-up w-wrapped-plain
seed_engaged w-wrapped-engaged            # operator re-engaged after the wrap
run_recover
calls=$(cat "$SPAWN_CALLS" 2>/dev/null)
if grep -q -- "--resume w-active" <<<"$calls" \
   && grep -q -- "--resume w-wrapped-engaged" <<<"$calls" \
   && ! grep -q -- "--resume w-wrapped-plain" <<<"$calls"; then
    pass "active AND wrapped-but-engaged resumed; wrapped-and-abandoned NOT"
else
    fail "wrong inclusion: calls=[$calls] err=$(cat "$ROOT/err")"
fi
if grep -q "worker 'w-wrapped-engaged': wrapped/closed BUT operator-engaged" "$ROOT/err" \
   && grep -q "worker 'w-wrapped-plain': already wrapped/closed per action log — skipping" "$ROOT/err"; then
    pass "both retired windows logged with the correct (divergent) reason"
else
    fail "skip/include reasons wrong: $(grep -E 'w-wrapped' "$ROOT/err")"
fi
if grep -q "operator-engaged windows captured:" "$ROOT/err" \
   && grep "operator-engaged windows captured:" "$ROOT/err" | grep -q "w-wrapped-engaged"; then
    pass "engaged set captured (before watcher relaunch) and logged"
else
    fail "engaged capture not logged: $(grep -i captured "$ROOT/err")"
fi
cleanup_case

# --- Case 24: --no-orchestrator and --services-only skip the orchestrator -----
echo '=== case 24: --no-orchestrator / --services-only skip the orchestrator step ==='
build_case 24
seed_healthy_watcher
seed_snapshot w-active
log_event spawn w-active
run_recover --no-orchestrator
if [[ ! -f "$ORCH_CALLS" ]] && grep -q "orchestrator: skipped" "$ROOT/err" \
   && [[ -f "$SPAWN_CALLS" ]] && grep -q -- "--resume w-active" "$SPAWN_CALLS"; then
    pass "--no-orchestrator: orchestrator skipped, workers still recover"
else
    fail "rc=$RC orch=$(cat "$ORCH_CALLS" 2>/dev/null) spawn=$(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
rm -f "$ORCH_CALLS" "$SPAWN_CALLS" "$LAUNCHER_CALLS"
run_recover --services-only
if [[ ! -f "$ORCH_CALLS" ]] && grep -q "orchestrator: skipped" "$ROOT/err" \
   && [[ ! -f "$LAUNCHER_CALLS" ]] \
   && [[ -f "$SPAWN_CALLS" ]] && grep -q -- "--resume w-active" "$SPAWN_CALLS"; then
    pass "--services-only: orchestrator AND watcher skipped (orchestrator is the caller), workers still recover"
else
    fail "rc=$RC orch=$(cat "$ORCH_CALLS" 2>/dev/null) launcher=$(cat "$LAUNCHER_CALLS" 2>/dev/null) spawn=$(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- summary ----------------------------------------------------------------
echo
echo "passed=$PASS failed=$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    exit 1
fi
