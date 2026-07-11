#!/usr/bin/env bash
# Tests for monitor/svc.sh — the service cockpit + unified service CLI.
#
# Strategy (mirrors test-bootstrap-recover.sh): build an isolated fake
# nexus tree, copy the real svc.sh + bootstrap-recover.sh + watcher/_lib.sh
# in at the canonical depth, and stub config/load.sh, watcher/launcher.sh
# (records its argv), and tmux (file-backed window list). Unit cases
# source svc.sh for its functions; verb cases run it as a CLI. Every
# launch happens inside the fake tree — never against live services.
#
# Cases:
#   1. svc_parse_registry — comments/blanks/malformed skipped, ~ and
#      $NEXUS_ROOT expanded, 5th <logfile> field carried separately.
#   2. svc_logfile — default <workdir>/serve.log, relative resolved
#      under workdir, absolute kept.
#   3. svc_endpoint — URL for curl checks, pid for pgrep -f, '-' else;
#      localhost URLs rewritten to the FQDN iff the port's live listener
#      binds beyond loopback (stubbed ss/hostname), untouched for
#      loopback-only binds and down services.
#   4. svc_supervisor — '-' (no pidfile), pid:N (live + cmdline match),
#      stale (dead pid), orphan (dead pid but the healthcheck passes);
#      _recover_supervisor_state's absent/stale/alive split.
#   5. `status` verb — pinned watcher + orchestrator rows, registry
#      rows, plain output (no ANSI escapes) when piped, exit 0.
#   6. `start` — down service relaunched headless (marker + pidfile);
#      idempotent second start does not double-launch.
#   7. `stop` — live supervisor TERM'd via its process group, pidfile
#      removed; second stop is a benign no-op.
#   8. `start watcher` / `restart watcher` — delegate to launcher.sh
#      (bare / --replace).
#   9. `up` — delegates to bootstrap-recover.sh (dead watcher =>
#      launcher invoked) and ends with a status table.
#  9b. `up --no-services` — core only: watcher relaunched, registered
#      services untouched; the conflicting --no-services
#      --services-only combo propagates as a hard failure (rc 1).
#  10. unknown service / orchestrator verbs — refuse with guidance.
#  11. `logs` — tails the resolved logfile; a workdir with a labsh
#      server log (.jupyter/labsh.bg.log) gets BOTH files tailed;
#      `logs watcher` tails the startup log AND the live scheduler
#      jsonl (watcher_log_files unit-tested in cases 1-4).
#  12. advertised jupyterlab — virtual DOWN row when no real
#      registry row exists; labsh-aware hint (activate vs install);
#      renders without labsh on PATH; real row wins (no duplicate);
#      bootstrap-recover never sees/auto-starts it; verbs redirect
#      to activation.
#  13. DETAIL column — an UP labsh service renders its reachable
#      tokened URL (FQDN on external bind, ?token= from .jupyter/
#      token, bare URL without a token, fallback when DOWN); the
#      WINDOW column is gone.
#  14. height-aware priority rendering — in dashboard mode (INPLACE=1)
#      the frame is budgeted to the pane height: core + DOWN rows are
#      NEVER hidden, healthy rows page (n/p) with an explicit
#      `+N more UP — page X/Y` indicator, hidden-unhealthy goes loud,
#      URL wraps are priced into the budget, SVC_PAGE clamps, and the
#      non-TTY `status` verb stays unbudgeted (full table, no paging).
#  16. DEGRADED/orphan rendering — a service whose recorded supervisor pid
#      is dead while its healthcheck still passes is NEVER reported as a
#      healthy `UP`: STATUS degrades to `DEGRADED`, SUPERVISOR reads
#      `orphan`, and a legend explains it + names the reconcile action. A
#      DOWN service with the same dead record keeps the honest `stale`.
#
# Run: bash monitor/watcher/test-svc.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_real_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REAL_SVC="$_real_test_dir/../svc.sh"
REAL_RECOVER="$_real_test_dir/../bootstrap-recover.sh"
REAL_LIB="$_real_test_dir/_lib.sh"
# The canonical fresh-open() writability probe (your-org/nexus-code#473).
# svc.sh's `fs` row reaches it through _lib.sh; copy it into the fixture so
# the tests exercise the REAL module, not _lib.sh's partial-tree fallback.
REAL_FS_PROBE="$_real_test_dir/../_fs_probe.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$(( FAIL + 1 )); }
pass() { echo "ok:   $*"; PASS=$(( PASS + 1 )); }

# th_kill_fixture_pid / th_kill_own_child (PID-recycling-safe cleanup).
# shellcheck source=_test_helpers.sh
. "$_real_test_dir/_test_helpers.sh"

build_case() {
    local label="$1"
    ROOT=$(mktemp -d -t "nexus-svc-${label}-XXXXXX")
    mkdir -p "$ROOT/monitor/watcher" "$ROOT/monitor/.state/services" \
             "$ROOT/config" "$ROOT/bin"
    cp "$REAL_SVC" "$ROOT/monitor/svc.sh"
    cp "$REAL_RECOVER" "$ROOT/monitor/bootstrap-recover.sh"
    cp "$REAL_LIB" "$ROOT/monitor/watcher/_lib.sh"
    cp "$REAL_FS_PROBE" "$ROOT/monitor/_fs_probe.sh"
    chmod +x "$ROOT/monitor/svc.sh" "$ROOT/monitor/bootstrap-recover.sh"
    SVC="$ROOT/monitor/svc.sh"
    REG="$ROOT/monitor/services.registry"
    BIN="$ROOT/bin"
    WINDOWS="$ROOT/windows";    : > "$WINDOWS"
    LAUNCHER_CALLS="$ROOT/launcher.calls"

    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$ROOT/config/load.sh"
    chmod +x "$ROOT/config/load.sh"

    printf '#!/usr/bin/env bash\necho "$@" >> "%s"\n' "$LAUNCHER_CALLS" \
        > "$ROOT/monitor/watcher/launcher.sh"
    chmod +x "$ROOT/monitor/watcher/launcher.sh"

    cat > "$BIN/tmux" <<TM
#!/usr/bin/env bash
case "\$1" in
  list-windows) cat "$WINDOWS" 2>/dev/null ;;
  has-session)  exit 0 ;;
  *)            : ;;
esac
exit 0
TM
    chmod +x "$BIN/tmux"
}

cleanup_case() {
    # Every kill below is identity-verified (th_kill_*): pidfiles can
    # name PIDs whose process died mid-case (the case-4 sleeper is
    # killed+waited before cleanup runs), and after a PID-space wrap a
    # blind `kill -KILL -- "-$p"` group-SIGKILLs whatever innocent
    # process recycled the number — observed killing a sibling test's
    # grep in the R3-tail stress campaign. Real fixture supervisors
    # are setsid'd with cwd inside $ROOT, so the fixture-root check
    # identifies them; anything else in the pidfile is stale.
    [[ -n "${FAUX_PID:-}" ]] && th_kill_fixture_pid "$FAUX_PID" "$ROOT"
    local pf p
    for pf in "$ROOT"/monitor/.state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r p < "$pf" 2>/dev/null
        [[ "$p" =~ ^[0-9]+$ ]] && th_kill_fixture_pid "$p" "$ROOT" KILL --group
    done
    [[ -n "${HELPER_PID:-}" ]] && th_kill_own_child "$HELPER_PID"
    rm -rf "$ROOT"
    unset ROOT SVC REG BIN WINDOWS LAUNCHER_CALLS FAUX_PID HELPER_PID
}

# Run svc.sh as a CLI inside the fake tree. Output in $ROOT/out|err, rc
# in $RC.
run_svc() {
    PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
        bash "$SVC" "$@" >"$ROOT/out" 2>"$ROOT/err"
    RC=$?
}

reg_line()  { printf '%s\t%s\t%s\t%s\n'     "$1" "$2" "$3" "$4"; }
reg_line5() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5"; }

svc_pidfile() { printf '%s/monitor/.state/services/%s.pid' "$ROOT" "$1"; }

make_fake_wrapper() {
    local workdir="$1" script="$2" marker="$3"
    cat > "$workdir/$script" <<EOF
#!/usr/bin/env bash
echo "up \$\$" > "$marker"
while true; do sleep 1; done
EOF
    chmod +x "$workdir/$script"
}

# Live faux watcher process whose argv matches monitor/watcher/main.sh,
# heartbeat pointing at it, plus the watcher window. Sets FAUX_PID.
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

# --- Cases 1-4: sourced function units ---------------------------------------
echo '=== cases 1-4: sourced units (parse / logfile / endpoint / supervisor) ==='
build_case units
# Deterministic socket + hostname state for the endpoint-rewrite cases:
# the REAL host may have the test ports bound externally, so svc_endpoint
# must never consult the live ss here. ss replays $ROOT/ss.out (absent ->
# empty, i.e. "no listener"); hostname returns a fixed FQDN.
printf '#!/usr/bin/env bash\ncat "%s" 2>/dev/null\nexit 0\n' "$ROOT/ss.out" > "$BIN/ss"
printf '#!/usr/bin/env bash\necho host.example.org\n' > "$BIN/hostname"
chmod +x "$BIN/ss" "$BIN/hostname"
export NEXUS_ROOT="$ROOT"
PATH="$BIN:$PATH"
# shellcheck source=/dev/null
source "$SVC"   # BASH_SOURCE guard: functions only, no cockpit

{
    echo '# comment'
    echo ''
    reg_line svcA '~/wd-a' 'echo a' 'true'
    echo 'malformed no tabs'
    reg_line5 svcB '$NEXUS_ROOT/wd-b' 'echo b' 'false' '$NEXUS_ROOT/wd-b/b.log'
} > "$REG"
parsed=$(svc_parse_registry "$REG")
[[ "$(printf '%s\n' "$parsed" | wc -l)" == 2 ]] \
    && pass "parse: 2 valid records (comment/blank/malformed dropped)" \
    || fail "parse: expected 2 records, got: $parsed"
printf '%s\n' "$parsed" | grep -qF "$HOME/wd-a" \
    && pass "parse: ~ expanded in workdir" || fail "parse: ~ not expanded"
b_health=$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="svcB"{print $4}')
b_log=$(printf '%s\n' "$parsed" | awk -F'\t' '$1=="svcB"{print $5}')
[[ "$b_health" == 'false' && "$b_log" == "$ROOT/wd-b/b.log" ]] \
    && pass "parse: 5th field carried separately, \$NEXUS_ROOT expanded" \
    || fail "parse: health=[$b_health] log=[$b_log]"

[[ "$(svc_logfile /srv/x '')" == '/srv/x/serve.log' ]] \
    && pass "logfile: empty field defaults to <workdir>/serve.log" \
    || fail "logfile default: $(svc_logfile /srv/x '')"
[[ "$(svc_logfile /srv/x 'rel/a.log')" == '/srv/x/rel/a.log' ]] \
    && pass "logfile: relative resolves under workdir" \
    || fail "logfile relative: $(svc_logfile /srv/x 'rel/a.log')"
[[ "$(svc_logfile /srv/x '/var/log/a.log')" == '/var/log/a.log' ]] \
    && pass "logfile: absolute kept" \
    || fail "logfile absolute: $(svc_logfile /srv/x '/var/log/a.log')"

# watcher_log_files — the watcher core row's resolved log set: startup
# log + live scheduler jsonl, existing files only, never an error.
[[ -z "$(watcher_log_files)" ]] \
    && pass "watcher logs: neither file yet -> empty set, rc 0" \
    || fail "watcher logs empty-state: [$(watcher_log_files)]"
touch "$ROOT/monitor/.state/watcher.log"
[[ "$(watcher_log_files)" == "$ROOT/monitor/.state/watcher.log" ]] \
    && pass "watcher logs: fresh boot (no jsonl yet) -> startup log alone" \
    || fail "watcher logs startup-only: [$(watcher_log_files)]"
touch "$ROOT/monitor/.state/watcher-scheduler.jsonl"
wlf=$(watcher_log_files)
if [[ "$(printf '%s\n' "$wlf" | wc -l)" == 2 ]] \
   && printf '%s\n' "$wlf" | grep -qx "$ROOT/monitor/.state/watcher-scheduler.jsonl"; then
    pass "watcher logs: scheduler jsonl joins the resolved set"
else
    fail "watcher logs dual: [$wlf]"
fi
rm -f "$ROOT/monitor/.state/watcher.log" \
      "$ROOT/monitor/.state/watcher-scheduler.jsonl"

[[ "$(svc_endpoint 'curl -fsS http://localhost:8765/')" == 'http://localhost:8765/' ]] \
    && pass "endpoint: URL extracted from curl check (no listener -> localhost kept)" \
    || fail "endpoint url: $(svc_endpoint 'curl -fsS http://localhost:8765/')"
[[ "$(svc_endpoint 'test -f x')" == '-' ]] \
    && pass "endpoint: non-curl/pgrep check shows '-'" \
    || fail "endpoint other: $(svc_endpoint 'test -f x')"
# External bind (0.0.0.0) -> FQDN substituted, path preserved.
printf 'LISTEN 0 4096 0.0.0.0:8765 0.0.0.0:*\n' > "$ROOT/ss.out"
SVC_LISTEN_FRESH=0
ep=$(svc_endpoint 'curl -fsS -o /dev/null http://localhost:8765/')
[[ "$ep" == 'http://host.example.org:8765/' ]] \
    && pass "endpoint: external bind rewrites localhost -> FQDN" \
    || fail "endpoint external: [$ep]"
# IPv6 wildcard bind counts as external too.
printf 'LISTEN 0 4096 [::]:8766 [::]:*\n' > "$ROOT/ss.out"
SVC_LISTEN_FRESH=0
ep=$(svc_endpoint 'curl -fsS http://localhost:8766/')
[[ "$ep" == 'http://host.example.org:8766/' ]] \
    && pass "endpoint: [::] bind rewrites localhost -> FQDN" \
    || fail "endpoint v6 external: [$ep]"
# Loopback-only listener -> localhost kept.
printf 'LISTEN 0 4096 127.0.0.1:8765 0.0.0.0:*\n' > "$ROOT/ss.out"
SVC_LISTEN_FRESH=0
ep=$(svc_endpoint 'curl -fsS http://localhost:8765/')
[[ "$ep" == 'http://localhost:8765/' ]] \
    && pass "endpoint: loopback-only bind keeps localhost" \
    || fail "endpoint loopback: [$ep]"
# Different external port must not bleed onto this URL's port.
printf 'LISTEN 0 4096 0.0.0.0:9999 0.0.0.0:*\n' > "$ROOT/ss.out"
SVC_LISTEN_FRESH=0
ep=$(svc_endpoint 'curl -fsS http://localhost:8765/')
[[ "$ep" == 'http://localhost:8765/' ]] \
    && pass "endpoint: unrelated external port leaves URL untouched" \
    || fail "endpoint port-mismatch: [$ep]"
rm -f "$ROOT/ss.out"
SVC_LISTEN_FRESH=0

[[ "$(svc_supervisor ghost 'echo x')" == '-' ]] \
    && pass "supervisor: no pidfile -> '-'" \
    || fail "supervisor no-pidfile: $(svc_supervisor ghost 'echo x')"
sleep 300 &
HELPER_PID=$!
echo "$HELPER_PID" > "$(svc_pidfile sleeper)"
# Wait for the child to actually exec `sleep`: between bash's fork and
# the execve, /proc/PID/cmdline still shows the forking bash, so an
# immediate svc_supervisor call reads a cmdline without "sleep" and
# reports `stale` (~4% of immediate reads under parallel-suite load).
# Poll-until with a hard deadline; 15 s is orders of magnitude beyond
# any observed fork-to-exec latency, so a timeout means a real bug.
_exec_deadline=$(( SECONDS + 15 ))
until [[ "$(tr '\0' ' ' < "/proc/$HELPER_PID/cmdline" 2>/dev/null)" == *sleep* ]]; do
    (( SECONDS >= _exec_deadline )) && break
    sleep 0.05
done
sup=$(svc_supervisor sleeper 'sleep 300')
[[ "$sup" == "pid:$HELPER_PID" ]] \
    && pass "supervisor: live + cmdline-matched -> pid:N" \
    || fail "supervisor live: [$sup]"
kill "$HELPER_PID" 2>/dev/null; wait "$HELPER_PID" 2>/dev/null
sleep 0.2
sup=$(svc_supervisor sleeper 'sleep 300')
[[ "$sup" == 'stale' ]] \
    && pass "supervisor: dead pid -> stale" \
    || fail "supervisor stale: [$sup]"
# Health-aware cell: the SAME dead record must read `orphan` when the
# healthcheck passes (the daemon outlived its supervisor) and `stale` only
# when the service is DOWN too — never a word that contradicts STATUS.
sup=$(svc_supervisor sleeper 'sleep 300' UP)
[[ "$sup" == 'orphan' ]] \
    && pass "supervisor: dead pid + healthy -> orphan" \
    || fail "supervisor orphan: [$sup]"
sup=$(svc_supervisor sleeper 'sleep 300' DOWN)
[[ "$sup" == 'stale' ]] \
    && pass "supervisor: dead pid + DOWN -> stale" \
    || fail "supervisor stale/down: [$sup]"
# An absent record is never an orphan, whatever the health verdict says.
[[ "$(svc_supervisor ghost 'echo x' UP)" == '-' ]] \
    && pass "supervisor: no pidfile stays '-' even when healthy" \
    || fail "supervisor absent/UP: $(svc_supervisor ghost 'echo x' UP)"
# The underlying primitive distinguishes absent from stale — the split the
# watcher's inconsistency detector depends on.
[[ "$(_recover_supervisor_state ghost 'echo x')" == 'absent' ]] \
    && pass "primitive: no pidfile -> absent" \
    || fail "primitive absent: $(_recover_supervisor_state ghost 'echo x')"
[[ "$(_recover_supervisor_state sleeper 'sleep 300')" == stale:* ]] \
    && pass "primitive: dead pid -> stale:<pid>" \
    || fail "primitive stale: $(_recover_supervisor_state sleeper 'sleep 300')"
# The sleeper is dead and reaped; clear the var so cleanup_case can't
# re-signal a recycled PID.
HELPER_PID=""
unset NEXUS_ROOT
cleanup_case

# --- Case 5: status verb ------------------------------------------------------
echo '=== case 5: status — pinned core rows + registry rows, plain when piped ==='
build_case status
seed_healthy_watcher
echo orchestrator >> "$WINDOWS"
touch "$ROOT/monitor/.state/orchestrator-heartbeat"
mkdir -p "$ROOT/wd-up" "$ROOT/wd-down"
reg_line svc-up   "$ROOT/wd-up"   './w.sh' 'true'  >  "$REG"
reg_line svc-down "$ROOT/wd-down" './w.sh' 'false' >> "$REG"
run_svc status
[[ $RC == 0 ]] && pass "status exits 0" || fail "status rc=$RC"
grep -qE '^ 0  watcher .*UP' "$ROOT/out" \
    && pass "watcher pinned as row 0, UP" \
    || fail "watcher row missing/not UP: $(grep watcher "$ROOT/out")"
grep -qE '^ -  orchestrator .*UP .*watcher' "$ROOT/out" \
    && pass "orchestrator pinned, UP, supervised-by-watcher" \
    || fail "orchestrator row: $(grep orchestrator "$ROOT/out")"
grep -qE 'svc-up .*UP' "$ROOT/out" && grep -qE 'svc-down .*DOWN' "$ROOT/out" \
    && pass "registry rows show UP/DOWN per healthcheck" \
    || fail "service rows: $(cat "$ROOT/out")"
if grep -q $'\033' "$ROOT/out"; then
    fail "piped status contains ANSI escapes"
else
    pass "piped status is plain (no ANSI escapes)"
fi
cleanup_case

# --- Cases 6+7: start / stop lifecycle -----------------------------------------
echo '=== cases 6+7: start launches headless once; stop kills the group ==='
build_case lifecycle
mkdir -p "$ROOT/wd-s"
make_fake_wrapper "$ROOT/wd-s" wrapper.sh "$ROOT/wd-s/marker"
# Healthcheck = "the wrapper's recorded pid is alive": fails before the
# first start (no marker) and goes down WITH the process group, so a
# clean stop exits 0.
hc="kill -0 \$(awk '{print \$2}' marker 2>/dev/null)"
reg_line5 svc-s "$ROOT/wd-s" './wrapper.sh' "$hc" "$ROOT/wd-s/s.log" > "$REG"

run_svc start svc-s
[[ $RC == 0 ]] && pass "start: rc 0" || fail "start rc=$RC err=$(cat "$ROOT/err")"
sleep 1
[[ -f "$ROOT/wd-s/marker" ]] \
    && pass "start: wrapper really ran (marker)" || fail "start: no marker"
pf=$(svc_pidfile svc-s)
[[ -f "$pf" ]] && read -r spid < "$pf" || spid=''
[[ "$spid" =~ ^[0-9]+$ ]] && kill -0 "$spid" 2>/dev/null \
    && pass "start: live supervisor pidfile ($spid)" \
    || fail "start: pidfile/pid bad: [$spid]"
grep -q 'relaunched' "$ROOT/err" \
    && pass "start: outcome reported" || fail "start: $(cat "$ROOT/err")"

run_svc start svc-s
grep -qE 'healthy|supervisor-alive' "$ROOT/err" \
    && pass "start twice: idempotent (no double-launch)" \
    || fail "second start: $(cat "$ROOT/err")"
read -r spid2 < "$pf"
[[ "$spid2" == "$spid" ]] \
    && pass "start twice: pidfile unchanged" \
    || fail "pidfile changed: $spid -> $spid2"

run_svc stop svc-s
[[ $RC == 0 ]] && pass "stop: rc 0" || fail "stop rc=$RC err=$(cat "$ROOT/err")"
sleep 0.3
kill -0 "$spid" 2>/dev/null \
    && fail "stop: supervisor $spid still alive" \
    || pass "stop: supervisor process gone"
[[ -f "$pf" ]] && fail "stop: pidfile not removed" || pass "stop: pidfile removed"

grep -q 'WARNING' "$ROOT/err" \
    && fail "stop: spurious daemonized-child WARNING on a clean stop" \
    || pass "stop: clean (healthcheck went down with the group)"

run_svc stop svc-s
[[ $RC == 0 ]] && grep -q 'nothing to stop' "$ROOT/err" \
    && pass "stop twice: benign no-op" \
    || fail "second stop: rc=$RC err=$(cat "$ROOT/err")"

# Warning path: a healthcheck that survives the group kill (here a
# leftover marker file standing in for a daemonized child) must be
# flagged loudly and exit nonzero.
mkdir -p "$ROOT/wd-w"
make_fake_wrapper "$ROOT/wd-w" wrapper.sh "$ROOT/wd-w/marker"
reg_line5 svc-w "$ROOT/wd-w" './wrapper.sh' "test -f '$ROOT/wd-w/marker'" "$ROOT/wd-w/w.log" >> "$REG"
run_svc start svc-w
sleep 1
run_svc stop svc-w
[[ $RC == 1 ]] && grep -q 'WARNING' "$ROOT/err" \
    && pass "stop: persistent healthcheck -> WARNING + rc 1" \
    || fail "warning path: rc=$RC err=$(cat "$ROOT/err")"
cleanup_case

# --- Case 8: watcher verbs delegate to launcher.sh -----------------------------
echo '=== case 8: start/restart watcher -> launcher.sh (bare / --replace) ==='
build_case watcherverbs
run_svc start watcher
[[ $RC == 0 ]] && [[ -f "$LAUNCHER_CALLS" ]] \
    && pass "start watcher: launcher invoked" \
    || fail "start watcher: rc=$RC calls=$(cat "$LAUNCHER_CALLS" 2>/dev/null)"
: > "$LAUNCHER_CALLS"
run_svc restart watcher
grep -q -- '--replace' "$LAUNCHER_CALLS" \
    && pass "restart watcher: launcher --replace" \
    || fail "restart watcher: $(cat "$LAUNCHER_CALLS" 2>/dev/null)"
cleanup_case

# --- Case 9: up delegates to bootstrap-recover ----------------------------------
echo '=== case 9: up — dead watcher => launcher invoked, status table follows ==='
build_case up
# No heartbeat at all -> watcher unhealthy -> recover_watcher fires the
# launcher stub. Empty registry -> services half degrades gracefully.
run_svc up
[[ $RC == 0 ]] && pass "up: rc 0" || fail "up rc=$RC err=$(cat "$ROOT/err")"
[[ -f "$LAUNCHER_CALLS" ]] \
    && pass "up: dead watcher relaunched via launcher" \
    || fail "up: launcher never invoked"
grep -qE '^ 0  watcher' "$ROOT/out" \
    && pass "up: ends with the status table" \
    || fail "up: no status table: $(cat "$ROOT/out")"
cleanup_case

# --- Case 9b: up --no-services — core only, zero services; bad combo fails ----
echo '=== case 9b: up --no-services — core only + bad-combo propagation ==='
build_case upns
mkdir -p "$ROOT/svcA"
# An unhealthy registered service that a FULL up would relaunch.
cat > "$ROOT/svcA/run.sh" <<'EOF'
#!/usr/bin/env bash
echo up > started
while true; do sleep 1; done
EOF
chmod +x "$ROOT/svcA/run.sh"
reg_line svcA "$ROOT/svcA" './run.sh' 'false' > "$REG"
run_svc up --no-services
[[ $RC == 0 ]] && pass "up --no-services: rc 0" \
    || fail "up --no-services rc=$RC err=$(cat "$ROOT/err")"
[[ -f "$LAUNCHER_CALLS" ]] \
    && pass "up --no-services: dead watcher still relaunched (core)" \
    || fail "up --no-services: launcher never invoked"
if [[ ! -f "$ROOT/monitor/.state/services/svcA.pid" && ! -f "$ROOT/svcA/started" ]]; then
    pass "up --no-services: registered service NOT launched"
else
    fail "up --no-services launched svcA: $(ls "$ROOT/monitor/.state/services" 2>/dev/null)"
fi
run_svc up --no-services --services-only
[[ $RC == 1 ]] && grep -q 'bootstrap-recover.sh failed' "$ROOT/err" \
    && pass "up: conflicting flags propagate as a hard failure" \
    || fail "bad combo: rc=$RC err=$(cat "$ROOT/err")"
cleanup_case

# --- Case 10: refusals ----------------------------------------------------------
echo '=== case 10: unknown service + orchestrator verbs refuse with guidance ==='
build_case refusals
reg_line svcA "$ROOT" 'echo a' 'true' > "$REG"
run_svc start nope
[[ $RC == 1 ]] && grep -q "unknown service 'nope'" "$ROOT/err" \
    && pass "start unknown: rc 1 + names the registry" \
    || fail "start unknown: rc=$RC err=$(cat "$ROOT/err")"
run_svc stop orchestrator
[[ $RC == 1 ]] && grep -q 'watcher-managed' "$ROOT/err" \
    && pass "stop orchestrator: redirected to the watcher" \
    || fail "stop orchestrator: rc=$RC err=$(cat "$ROOT/err")"
run_svc logs
[[ $RC == 1 ]] && grep -q 'usage' "$ROOT/err" \
    && pass "logs without name: usage error" \
    || fail "bare logs: rc=$RC err=$(cat "$ROOT/err")"
cleanup_case

# --- Case 11: logs tails the resolved logfile ------------------------------------
echo '=== case 11: logs — tails the registry-resolved logfile ==='
build_case logs
mkdir -p "$ROOT/wd-l"
printf 'hello-from-the-log\n' > "$ROOT/wd-l/custom.log"
reg_line5 svc-l "$ROOT/wd-l" './w.sh' 'true' 'custom.log' > "$REG"
PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
    timeout 2 bash "$SVC" logs svc-l >"$ROOT/out" 2>"$ROOT/err"
rc=$?
grep -q 'hello-from-the-log' "$ROOT/out" && [[ $rc == 124 ]] \
    && pass "logs: tail -F on the relative-resolved 5th-field logfile" \
    || fail "logs: rc=$rc out=$(cat "$ROOT/out") err=$(cat "$ROOT/err")"
run_svc logs watcher
[[ $RC == 1 ]] && grep -q 'logfile not found' "$ROOT/err" \
    && pass "logs watcher: generic missing-logfile error (no migration special-casing)" \
    || fail "logs watcher: rc=$RC err=$(cat "$ROOT/err")"
# Watcher dual-tail: at scheduler handoff the live activity lands in
# watcher-scheduler.jsonl, not watcher.log — `logs watcher` must tail
# BOTH so a frozen startup log never reads as a dead watcher.
printf 'startup-sweep-line\n' > "$ROOT/monitor/.state/watcher.log"
printf '{"ts":"now","task":"heartbeat","rc":0}\n' \
    > "$ROOT/monitor/.state/watcher-scheduler.jsonl"
PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
    timeout 2 bash "$SVC" logs watcher >"$ROOT/out" 2>"$ROOT/err"
if grep -q 'startup-sweep-line' "$ROOT/out" \
   && grep -q '"task":"heartbeat"' "$ROOT/out"; then
    pass "logs watcher: scheduler jsonl tailed alongside the startup log"
else
    fail "watcher dual-tail: out=$(cat "$ROOT/out") err=$(cat "$ROOT/err")"
fi
# A labsh service's workdir carries the server's own log — `logs` must
# tail it alongside the wrapper log (that's where the tokened URL is).
mkdir -p "$ROOT/wd-l/.jupyter"
printf 'hello-from-the-server-log\n' > "$ROOT/wd-l/.jupyter/labsh.bg.log"
PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
    timeout 2 bash "$SVC" logs svc-l >"$ROOT/out" 2>"$ROOT/err"
if grep -q 'hello-from-the-log' "$ROOT/out" \
   && grep -q 'hello-from-the-server-log' "$ROOT/out"; then
    pass "logs: jupyter server log tailed alongside the wrapper log"
else
    fail "logs dual-tail: out=$(cat "$ROOT/out") err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 12: advertised jupyterlab (virtual row) --------------------------
echo '=== case 12: advertised jupyterlab — DOWN row, labsh-aware hint, live-row-wins, never recovered ==='
build_case advertise
mkdir -p "$ROOT/wd-x"
reg_line svc-x "$ROOT/wd-x" './w.sh' 'true' > "$REG"

# (a) labsh present (stub in $BIN guarantees it regardless of host):
#     advertised DOWN row + activate hint.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/labsh"; chmod +x "$BIN/labsh"
run_svc status
[[ $RC == 0 ]] && grep -qE '^ -  jupyterlab +DOWN' "$ROOT/out" \
    && pass "advertise: virtual DOWN row shown when no registry row exists" \
    || fail "advertise row: rc=$RC $(grep jupyter "$ROOT/out")"
grep -q 'jupyter-up.sh --root' "$ROOT/out" \
    && pass "advertise: labsh present -> activate hint" \
    || fail "activate hint missing: $(cat "$ROOT/out")"

# (b) labsh absent: minimal PATH (fixture bin + system dirs) excludes
#     any user-installed labsh. The row must still render (display-only,
#     never executes labsh) and the hint must point at the installer.
rm -f "$BIN/labsh"
PATH="$(th_hermetic_path "$BIN:/usr/bin:/bin" "$ROOT")" NEXUS_ROOT="$ROOT" \
    bash "$SVC" status >"$ROOT/out" 2>"$ROOT/err"
rc=$?
[[ $rc == 0 ]] && grep -qE '^ -  jupyterlab +DOWN' "$ROOT/out" \
    && pass "advertise: renders without labsh on PATH (display-only)" \
    || fail "labsh-absent render: rc=$rc err=$(cat "$ROOT/err")"
if grep -q 'install-labsh.sh' "$ROOT/out" && ! grep -q 'jupyter-up.sh --root' "$ROOT/out"; then
    pass "advertise: labsh absent -> install hint, not activate"
else
    fail "install hint: $(cat "$ROOT/out")"
fi

# (c) live row wins: a real jupyterlab registry row suppresses the
#     advertisement — exactly one jupyterlab line, showing UP.
reg_line jupyterlab "$ROOT/wd-x" './w.sh' 'true' >> "$REG"
run_svc status
n=$(grep -c 'jupyterlab' "$ROOT/out")
if grep -qE 'jupyterlab +UP' "$ROOT/out" && [[ "$n" == 1 ]]; then
    pass "advertise: real registry row wins — single UP row, no virtual duplicate"
else
    fail "suppression: count=$n rows=$(grep jupyter "$ROOT/out")"
fi

# (d) no auto-start: with the jupyter row gone again, recovery iterates
#     ONLY real registry rows — it never sees the advertised entry and
#     never launches or pidfiles it.
reg_line svc-x "$ROOT/wd-x" './w.sh' 'true' > "$REG"
PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
    bash "$ROOT/monitor/bootstrap-recover.sh" --services-only >"$ROOT/rout" 2>&1
grep -q 'services: 1 registered' "$ROOT/rout" \
    && pass "recover: counts only the real registry row" \
    || fail "recover count: $(cat "$ROOT/rout")"
if ! grep -q 'jupyterlab' "$ROOT/rout" \
   && [[ ! -f "$(svc_pidfile jupyterlab)" ]]; then
    pass "recover: advertised row invisible to recovery — no auto-start, no pidfile"
else
    fail "recovery touched the advertised row: $(cat "$ROOT/rout")"
fi

# (e) verbs on the dormant capability redirect to activation, not
#     "unknown service".
run_svc start jupyterlab
[[ $RC == 1 ]] && grep -q 'jupyter-up.sh --root' "$ROOT/err" \
    && pass "start jupyterlab (unregistered): redirects to activation" \
    || fail "start redirect: rc=$RC err=$(cat "$ROOT/err")"
cleanup_case

# --- Case 13: DETAIL — tokened jupyter URL when UP, fallbacks, no WINDOW ---------
echo '=== case 13: DETAIL — tokened URL for UP labsh services; WINDOW column gone ==='
build_case detail
# Deterministic sockets/hostname (same scheme as cases 1-4): ss replays
# $ROOT/ss.out, hostname is fixed — run_svc puts $BIN first on PATH.
printf '#!/usr/bin/env bash\ncat "%s" 2>/dev/null\nexit 0\n' "$ROOT/ss.out" > "$BIN/ss"
printf '#!/usr/bin/env bash\necho host.example.org\n' > "$BIN/hostname"
chmod +x "$BIN/ss" "$BIN/hostname"
mkdir -p "$ROOT/wd-j/.jupyter"
printf 'PORT=9755\nSCHEME=http\n' > "$ROOT/wd-j/.jupyter/labsh-service.env"
printf 'sekrit-token\n' > "$ROOT/wd-j/.jupyter/token"
printf 'LISTEN 0 4096 0.0.0.0:9755 0.0.0.0:*\n' > "$ROOT/ss.out"
reg_line jupyterlab "$ROOT/wd-j" './w.sh' 'true' > "$REG"

run_svc status
grep -qE 'jupyterlab +UP .*http://host\.example\.org:9755/lab\?token=sekrit-token$' "$ROOT/out" \
    && pass "detail: UP labsh service shows the full tokened FQDN URL" \
    || fail "tokened detail: $(grep jupyterlab "$ROOT/out")"
grep -q 'WINDOW' "$ROOT/out" \
    && fail "WINDOW column still rendered" \
    || pass "detail: WINDOW column removed"
grep -q 'DETAIL' "$ROOT/out" \
    && pass "detail: DETAIL header still present" \
    || fail "DETAIL header missing: $(head -4 "$ROOT/out")"

# Loopback-only bind keeps localhost in the URL (token still shown).
printf 'LISTEN 0 4096 127.0.0.1:9755 0.0.0.0:*\n' > "$ROOT/ss.out"
run_svc status
grep -q 'http://localhost:9755/lab?token=sekrit-token' "$ROOT/out" \
    && pass "detail: loopback bind keeps localhost host" \
    || fail "loopback detail: $(grep jupyterlab "$ROOT/out")"

# No token resolvable -> bare URL, never an error.
rm -f "$ROOT/wd-j/.jupyter/token"
printf 'LISTEN 0 4096 0.0.0.0:9755 0.0.0.0:*\n' > "$ROOT/ss.out"
run_svc status
[[ $RC == 0 ]] && grep -qE 'jupyterlab +UP .*http://host\.example\.org:9755/lab$' "$ROOT/out" \
    && pass "detail: missing token degrades to the bare URL" \
    || fail "bare-url fallback: rc=$RC $(grep jupyterlab "$ROOT/out")"

# DOWN service -> generic endpoint fallback, no URL leak.
printf 'sekrit-token\n' > "$ROOT/wd-j/.jupyter/token"
reg_line jupyterlab "$ROOT/wd-j" './w.sh' 'false' > "$REG"
run_svc status
if grep -qE 'jupyterlab +DOWN' "$ROOT/out" && ! grep -q 'token=' "$ROOT/out"; then
    pass "detail: DOWN service falls back (no stale URL/token shown)"
else
    fail "down fallback: $(grep jupyterlab "$ROOT/out")"
fi

# Malformed env file (no numeric port) -> fallback, exit 0.
printf 'PORT=bogus\n' > "$ROOT/wd-j/.jupyter/labsh-service.env"
reg_line jupyterlab "$ROOT/wd-j" './w.sh' 'true' > "$REG"
run_svc status
[[ $RC == 0 ]] && ! grep -q 'token=' "$ROOT/out" \
    && pass "detail: unparsable port never errors the cockpit" \
    || fail "malformed env: rc=$RC $(grep jupyterlab "$ROOT/out")"
cleanup_case

# --- Case 14: height-aware priority rendering + paging ----------------------
echo '=== case 14: height budget — core+DOWN always visible, healthy rows page, status verb unbudgeted ==='
build_case overflow
PATH="$BIN:$PATH"
export NEXUS_ROOT="$ROOT"
mkdir -p "$ROOT/wd"
# 30 rows, two DOWN (05/17), plus a real jupyterlab row whose tokened
# URL (~113 chars) wraps at 100 cols — the wrap must be priced in.
{
    for i in $(seq -w 1 30); do
        hc=true; [[ "$i" == 05 || "$i" == 17 ]] && hc=false
        reg_line "svc$i" "$ROOT/wd" 'echo noop' "$hc"
    done
    reg_line jupyterlab "$ROOT/wd-jl" 'echo noop' 'true'
} > "$REG"
mkdir -p "$ROOT/wd-jl/.jupyter"
printf 'PORT=58888\nSCHEME=http\n' > "$ROOT/wd-jl/.jupyter/labsh-service.env"
printf 'a%.0s' $(seq 64) > "$ROOT/wd-jl/.jupyter/token"
# Deterministic sockets/hostname (same scheme as cases 1-4/13): the
# REAL host may have 58888 bound externally, which would rewrite the
# URL's host and break the token assertion below.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/ss"
printf '#!/usr/bin/env bash\necho host.example.org\n' > "$BIN/hostname"
chmod +x "$BIN/ss" "$BIN/hostname"
# shellcheck source=/dev/null
source "$SVC"   # re-source against this fixture's NEXUS_ROOT
# Colour off regardless of how the test itself is run: a TTY-attached
# run would colorize the sourced renderer and break the row regexes.
C_G='' C_R='' C_Y='' C_DIM='' C_B='' C_0=''

# line_cost unit: wrap pricing at the budget's width.
TERM_COLS=100
line_cost "$(printf 'x%.0s' $(seq 113))"
[[ "$COST" == 2 ]] \
    && pass "line_cost: 113 chars at 100 cols -> 2 physical lines" \
    || fail "line_cost wrap: COST=$COST"
line_cost 'short line'
[[ "$COST" == 1 ]] \
    && pass "line_cost: short line -> 1" || fail "line_cost short: COST=$COST"

# Budgeted dashboard frame: 25x100 pane. render_status output captured
# in a subshell, so page state is asserted via the rendered text.
load_services
INPLACE=1 SVC_ROWS=25 SVC_COLS=100
frame=$(render_status)
grep -qE ' 0  watcher .*DOWN' <<<"$frame" \
    && pass "budget: watcher core row visible on page 1" \
    || fail "watcher row hidden: $frame"
grep -qE ' -  orchestrator .*DOWN' <<<"$frame" \
    && pass "budget: orchestrator core row visible on page 1" \
    || fail "orchestrator row hidden"
if grep -qE 'svc05 +DOWN' <<<"$frame" && grep -qE 'svc17 +DOWN' <<<"$frame"; then
    pass "budget: BOTH unhealthy rows pinned on page 1"
else
    fail "DOWN rows not pinned: $(grep -E 'svc(05|17)' <<<"$frame")"
fi
grep -qE '\+[0-9]+ more UP — page 1/[0-9]+ \(n next, p prev\)' <<<"$frame" \
    && pass "budget: explicit +N more / page X/Y indicator" \
    || fail "indicator missing: $(tail -3 <<<"$frame")"
# Frame height honors the pane: physical lines (logical + wraps at 100
# cols) must leave PROMPT_RESERVE rows free.
phys=0
while IFS= read -r ln; do
    w=${#ln}; (( w <= 100 )) && phys=$(( phys + 1 )) \
        || phys=$(( phys + (w + 99) / 100 ))
done <<<"$frame"
(( phys <= 23 )) \
    && pass "budget: frame is $phys physical lines <= 23 (25-row pane minus prompt reserve)" \
    || fail "frame overflows the pane: $phys physical lines"

# Page 2 swaps the healthy slice but keeps every problem row pinned.
SVC_PAGE=2
frame2=$(render_status)
if grep -qE 'svc05 +DOWN' <<<"$frame2" && grep -qE 'svc17 +DOWN' <<<"$frame2" \
   && grep -qE ' 0  watcher .*DOWN' <<<"$frame2"; then
    pass "paging: core + DOWN rows still visible on page 2"
else
    fail "page 2 dropped a problem row"
fi
grep -q 'page 2/' <<<"$frame2" \
    && pass "paging: indicator shows page 2" \
    || fail "page 2 indicator: $(tail -3 <<<"$frame2")"
p1=$(grep -oE 'svc[0-9]+ +UP' <<<"$frame" | head -1)
p2=$(grep -oE 'svc[0-9]+ +UP' <<<"$frame2" | head -1)
[[ -n "$p1" && -n "$p2" && "$p1" != "$p2" ]] \
    && pass "paging: page 2 shows a different healthy slice ($p1 -> $p2)" \
    || fail "healthy slice unchanged across pages: [$p1] [$p2]"

# Out-of-range page clamps to the last page instead of erroring.
SVC_PAGE=99
frame3=$(render_status)
last=$(grep -oE 'page [0-9]+/[0-9]+' <<<"$frame3" | head -1)
[[ "$last" =~ ^page\ ([0-9]+)/([0-9]+)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] \
    && pass "paging: SVC_PAGE=99 clamps to the last page ($last)" \
    || fail "clamp: [$last]"
# The tokened URL lives on the last page, full and untruncated.
grep -q 'token=' <<<"$frame3" \
    && grep -qF "http://localhost:58888/lab?token=$(cat "$ROOT/wd-jl/.jupyter/token")" <<<"$frame3" \
    && pass "paging: full tokened URL untruncated on its page" \
    || fail "tokened URL truncated/missing on last page"

# Loud mode: unhealthy alone overflow a tiny pane -> red-channel
# indicator names the hidden unhealthy count (never silent).
SVC_PAGE=1 SVC_ROWS=12
{
    for i in $(seq -w 1 20); do
        reg_line "down$i" "$ROOT/wd" 'echo noop' 'false'
    done
} > "$REG"
load_services
frame4=$(render_status)
grep -qE '! [0-9]+ unhealthy \+ [0-9]+ healthy hidden — page 1/[0-9]+' <<<"$frame4" \
    && pass "loud mode: hidden unhealthy rows announced explicitly" \
    || fail "loud indicator missing: $(tail -3 <<<"$frame4")"
grep -qE 'down01 +DOWN' <<<"$frame4" \
    && pass "loud mode: unhealthy rows page from page 1 (first DOWN visible)" \
    || fail "loud mode page 1: $frame4"
INPLACE=0; unset SVC_ROWS SVC_COLS; SVC_PAGE=1

# Non-TTY `status` (scripts/agents) stays unbudgeted: full table, no
# pagination markers, even against the 31-row registry.
{
    for i in $(seq -w 1 30); do
        hc=true; [[ "$i" == 05 || "$i" == 17 ]] && hc=false
        reg_line "svc$i" "$ROOT/wd" 'echo noop' "$hc"
    done
    reg_line jupyterlab "$ROOT/wd-jl" 'echo noop' 'true'
} > "$REG"
run_svc status
# 31 registry rows (svc01-30 + jupyterlab) + 3 pinned core rows (watcher,
# watcher-sup, orchestrator) = 34. The watcher-sup row is the
# watcher-supervision core row (its name matches the `watcher` alternative).
n_rows=$(grep -cE '^ [0-9-]+ +(svc|jupyterlab|watcher|orchestrator)' "$ROOT/out")
[[ $RC == 0 && "$n_rows" == 34 ]] \
    && pass "status verb: all 34 rows printed, no height budget" \
    || fail "status rows: rc=$RC n=$n_rows"
if grep -qE 'page [0-9]+/|more UP|hidden' "$ROOT/out"; then
    fail "status verb: pagination markers leaked into non-TTY output"
else
    pass "status verb: no pagination markers when piped"
fi
unset NEXUS_ROOT
cleanup_case

# --- Case 15: wrong-launch guard + empty-arg footgun (issue #203 revision) -------
#
# (a) `svc.sh ""` (an empty variable expanding into the verb slot) must
#     die loudly instead of silently starting the cockpit.
# (b) Cockpit invoked from a pane inside the window named
#     monitor.target_window → renamed off + refused (exit 4).
# (c) Cockpit refused when a live peer cockpit pane exists (exit 4).
# (d) Legitimate first cockpit (no peer, own window not the target, or
#     indeterminate probes) proceeds — piped no-arg renders once, rc 0.
echo
echo '=== case 15: wrong-launch guard + empty-arg footgun ==='
build_case guard

# Richer tmux stub: display-message serves pane→window mapping from
# files; list-panes -a serves a canned pane table; list-panes -t <win>
# serves a per-window table; rename-window is recorded.
PANES_ALL="$ROOT/panes-all.txt"        # pane_id|pane_pid|win_id|win_name
PANES_OWN="$ROOT/panes-own.txt"        # pane pids of the own window
OWN_PANE_PID_FILE="$ROOT/own-pane-pid"
OWN_WINDOW_FILE="$ROOT/own-window"     # "<win_id>\t<win_name>"
TMUX_GUARD_LOG="$ROOT/tmux-guard.log"
cat > "$BIN/tmux" <<TM
#!/usr/bin/env bash
echo "tmux \$*" >> "$TMUX_GUARD_LOG"
case "\$1" in
  list-windows) cat "$WINDOWS" 2>/dev/null ;;
  has-session)  exit 0 ;;
  display|display-message)
      fmt=""
      shift
      while (( \$# > 0 )); do
          case "\$1" in
              -p) shift ;;
              -t) shift 2 ;;
              *)  fmt="\$1"; shift ;;
          esac
      done
      case "\$fmt" in
          '#{pane_pid}') cat "$OWN_PANE_PID_FILE" 2>/dev/null ;;
          *)             cat "$OWN_WINDOW_FILE" 2>/dev/null ;;
      esac
      ;;
  list-panes)
      if [[ "\$2" == "-a" ]]; then cat "$PANES_ALL" 2>/dev/null
      else cat "$PANES_OWN" 2>/dev/null; fi
      ;;
  *) : ;;
esac
exit 0
TM
chmod +x "$BIN/tmux"

# (a) explicit empty argument dies loudly, never reaches the cockpit.
run_svc ""
[[ $RC == 1 ]] && grep -q "empty argument" "$ROOT/err" \
    && pass "empty-arg verb dies loudly (rc=1), no cockpit" \
    || fail "empty-arg: rc=$RC err=$(cat "$ROOT/err")"

# (b) own window is the target window → rename off + exit 4. The pane
# must HOST the process: pane_pid is this test shell ($$), an ancestor
# of the run_svc child.
printf '%s\n' "$$" > "$OWN_PANE_PID_FILE"
printf '@9\torchestrator\n' > "$OWN_WINDOW_FILE"
: > "$PANES_OWN"          # no orchestrator process in the window
: > "$TMUX_GUARD_LOG"
TMUX=/tmp/fake,1,1 TMUX_PANE=%0 PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
    bash "$SVC" >"$ROOT/out" 2>"$ROOT/err"; RC=$?
if [[ $RC == 4 ]] && grep -q "REFUSING to run the cockpit inside the 'orchestrator' window" "$ROOT/err" \
   && grep -q "rename-window -t @9 services-misplaced" "$TMUX_GUARD_LOG"; then
    pass "cockpit in target window: renamed off + refused (rc=4)"
else
    fail "target-window guard: rc=$RC err=$(head -2 "$ROOT/err") log=$(grep rename "$TMUX_GUARD_LOG" || true)"
fi

# (b2) same, but a live orchestrator shares the window → still refused,
# but the name is the orchestrator's — NO rename.
NEXUS_IS_ORCHESTRATOR=1 sleep 30 &
GUARD_ORCH_PID=$!
sleep 0.1
if [[ -r "/proc/$GUARD_ORCH_PID/environ" ]]; then
    printf '%s\n' "$GUARD_ORCH_PID" > "$PANES_OWN"
    : > "$TMUX_GUARD_LOG"
    TMUX=/tmp/fake,1,1 TMUX_PANE=%0 PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
        bash "$SVC" >"$ROOT/out" 2>"$ROOT/err"; RC=$?
    if [[ $RC == 4 ]] && ! grep -q "rename-window" "$TMUX_GUARD_LOG"; then
        pass "cockpit in target window with live orchestrator: refused, name untouched"
    else
        fail "live-orch rename protection: rc=$RC renames=$(grep -c rename-window "$TMUX_GUARD_LOG")"
    fi
else
    pass "(b2) skipped: /proc environ unreadable"
fi
kill "$GUARD_ORCH_PID" 2>/dev/null; wait "$GUARD_ORCH_PID" 2>/dev/null

# (c) live peer cockpit elsewhere → refused (exit 4), peer untouched.
printf '@1\tmywindow\n' > "$OWN_WINDOW_FILE"   # own window NOT the target
mkdir -p "$ROOT/fakecockpit"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$ROOT/fakecockpit/svc.sh"
bash "$ROOT/fakecockpit/svc.sh" &
PEER_PID=$!
sleep 0.2
printf '%%7|%s|@0|services\n' "$PEER_PID" > "$PANES_ALL"
: > "$TMUX_GUARD_LOG"
TMUX=/tmp/fake,1,1 TMUX_PANE=%0 PATH="$BIN:$PATH" NEXUS_ROOT="$ROOT" \
    bash "$SVC" >"$ROOT/out" 2>"$ROOT/err"; RC=$?
if [[ $RC == 4 ]] && grep -q "already running" "$ROOT/err" \
   && ! grep -qE "kill|rename" "$TMUX_GUARD_LOG"; then
    pass "peer cockpit alive: second cockpit refused (rc=4), peer untouched"
else
    fail "peer guard: rc=$RC err=$(head -2 "$ROOT/err")"
fi
kill "$PEER_PID" 2>/dev/null; wait "$PEER_PID" 2>/dev/null

# (d) legitimate first cockpit: no peer, own window not the target →
# piped no-arg renders once and exits 0.
: > "$PANES_ALL"
run_svc
[[ $RC == 0 ]] \
    && pass "legit first cockpit proceeds (piped render-once, rc=0)" \
    || fail "legit cockpit refused: rc=$RC err=$(head -3 "$ROOT/err")"

cleanup_case

# --- Case 16: a dead pid record NEVER renders as bare `stale` beside UP -----
# The nexus-remote-ssh shape: the daemon outlives its supervisor, so the
# healthcheck stays green while the pidfile rots. `UP stale` is a
# self-contradicting cell; the cockpit must say `orphan` and explain it.
echo '=== case 16: healthy + dead pid record renders `orphan`, not `stale` ==='
build_case orphan
PATH="$BIN:$PATH"
export NEXUS_ROOT="$ROOT"
mkdir -p "$ROOT/wd"
{
    reg_line svcorph "$ROOT/wd" 'echo noop' 'true'    # healthy
    reg_line svcdead "$ROOT/wd" 'echo noop' 'false'   # unhealthy
} > "$REG"
# One reaped PID, recorded for both. Provably not a live `echo noop`.
bash -c 'exit 0' & GHOST=$!; wait "$GHOST" 2>/dev/null
echo "$GHOST" > "$ROOT/monitor/.state/services/svcorph.pid"
echo "$GHOST" > "$ROOT/monitor/.state/services/svcdead.pid"

run_svc status
[[ $RC == 0 ]] && pass "orphan: status verb still exits 0" || fail "status rc=$RC"
grep -qE 'svcorph +DEGRADED +orphan' "$ROOT/out" \
    && pass "orphan: healthy + dead pid record renders DEGRADED/orphan" \
    || fail "orphan cell: $(grep svcorph "$ROOT/out")"
# The load-bearing assertion: a supervisor-less daemon must NEVER be reported
# as a plain healthy UP — that display masked a dying service for ~19h.
grep -qE 'svcorph +UP ' "$ROOT/out" \
    && fail "orphan: still reports a supervisor-less service as healthy UP" \
    || pass "orphan: a supervisor-less service is never reported plain UP"
grep -qE 'svcdead +DOWN +stale' "$ROOT/out" \
    && pass "orphan: DOWN + dead record keeps the honest 'stale'" \
    || fail "stale cell: $(grep svcdead "$ROOT/out")"
grep -q 'DEGRADED/orphan' "$ROOT/out" \
    && pass "orphan: the word is never shown without a legend" \
    || fail "no orphan legend: $(tail -5 "$ROOT/out")"
grep -q 'supervisor is DEAD' "$ROOT/out" \
    && pass "orphan: legend states the supervisor is dead" \
    || fail "legend does not explain orphan"
grep -q 'svc.sh restart <name>' "$ROOT/out" \
    && pass "orphan: legend names the reconcile action" \
    || fail "legend has no action"
unset NEXUS_ROOT
cleanup_case

# --- Case 17: `stop` on an orphan must NOT read as an all-clear -------------
# Deleting a stale pidfile does not stop an orphaned daemon and is not
# supervision. `stop` removed the RECORD, not the process; if it says nothing,
# the operator believes the service is stopped while it keeps serving,
# unsupervised and now unrecorded (skeptic finding B on PR #460).
echo '=== case 17: stop on an orphan warns loudly; the daemon is still serving ==='
build_case stoporphan
PATH="$BIN:$PATH"
export NEXUS_ROOT="$ROOT"
mkdir -p "$ROOT/wd"
reg_line svcorph "$ROOT/wd" 'echo noop' 'true' > "$REG"      # healthcheck always passes
bash -c 'exit 0' & GHOST=$!; wait "$GHOST" 2>/dev/null
echo "$GHOST" > "$ROOT/monitor/.state/services/svcorph.pid"   # dead record => orphan

run_svc stop svcorph
[[ $RC == 0 ]] && pass "stop-orphan: exits 0" || fail "stop rc=$RC"
grep -q 'no live supervisor' "$ROOT/err" \
    && pass "stop-orphan: reports there was no supervisor to stop" \
    || fail "no supervisor line: $(cat "$ROOT/err")"
[[ ! -f "$ROOT/monitor/.state/services/svcorph.pid" ]] \
    && pass "stop-orphan: the stale record is removed" \
    || fail "pidfile survived"
# The load-bearing assertion: a still-passing healthcheck after `stop` means an
# orphaned daemon is serving. Silence here is the false all-clear.
grep -q 'WARNING' "$ROOT/err" \
    && pass "stop-orphan: WARNS that the daemon is still serving" \
    || fail "stop-orphan: silent all-clear! err=$(cat "$ROOT/err")"
grep -q 'removed the record, not the daemon' "$ROOT/err" \
    && pass "stop-orphan: says the record was removed, not the daemon" \
    || fail "no record-vs-daemon warning"
grep -q "svc.sh restart svcorph" "$ROOT/err" \
    && pass "stop-orphan: names the reconcile action" \
    || fail "no reconcile guidance"

# A genuinely-down service with a dead record must stay quiet: nothing survives,
# so there is nothing to warn about.
reg_line svcdown "$ROOT/wd" 'echo noop' 'false' > "$REG"
echo "$GHOST" > "$ROOT/monitor/.state/services/svcdown.pid"
run_svc stop svcdown
grep -q 'WARNING' "$ROOT/err" \
    && fail "stop-orphan: warned about a genuinely DOWN service" \
    || pass "stop-orphan: a truly down service triggers no orphan warning"
unset NEXUS_ROOT
cleanup_case

# --- summary ---------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
if (( FAIL == 0 )); then
    echo 'ALL TESTS PASSED'
    exit 0
else
    echo 'TESTS FAILED'
    exit 1
fi
