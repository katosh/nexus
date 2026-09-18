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

# Write the spawn-worker stub at the production default path
# ($_script_dir/spawn-worker.sh). Two behaviours, because recovery uses
# spawn-worker for two different jobs:
#
#   --resume <w>            RESURRECTION. Records its argv, and — when
#                           $ROOT/spawn-worker.creates-window exists —
#                           really creates the tmux window via the stub.
#                           That flag is what lets the cold-boot cases
#                           assert the OBSERVABLE property ("no worker
#                           window came back") instead of a proxy; the
#                           older cases assert on the recorded argv and
#                           leave it off.
#   --resume <w> --dry-run  RESOLUTION ONLY (your-org/nexus-code#651).
#                           The cold-boot manifest asks spawn-worker to
#                           resolve session-id + workdir without spawning
#                           anything, so the stub prints the real
#                           `resolved:` line shape and records the call to
#                           a SEPARATE file — a resolver call must never
#                           be mistakable for a resurrection.
#
# rc is staged via $ROOT/spawn-worker.rc / $ROOT/spawn-worker.dryrun.rc.
write_spawn_worker_stub() {
    cat > "$ROOT/monitor/spawn-worker.sh" <<SW
#!/usr/bin/env bash
dry=0
for a in "\$@"; do [ "\$a" = "--dry-run" ] && dry=1; done
if [ "\$dry" = 1 ]; then
    echo "\$*" >> "$ROOT/spawn-worker.dryrun.calls"
    rc=0
    [ -f "$ROOT/spawn-worker.dryrun.rc" ] && read -r rc < "$ROOT/spawn-worker.dryrun.rc"
    if [ "\$rc" = 0 ]; then
        printf 'resolved: window=%s session=sid-%s workdir=%s jsonl=%s nudge=off (heartbeat-absent)\n' \\
            "\$2" "\$2" "$ROOT/work/\$2" "$ROOT/work/\$2/t.jsonl"
    else
        echo "spawn-worker: --resume: cannot resolve a session-id for window '\$2'." >&2
    fi
    exit "\$rc"
fi
echo "WORKER \$*" >> "$ROOT/order.log"
echo "\$*" >> "$SPAWN_CALLS"
[ -f "$ROOT/spawn-worker.creates-window" ] && tmux new-window -n "\$2"
rc=0
[ -f "$ROOT/spawn-worker.rc" ] && read -r rc < "$ROOT/spawn-worker.rc"
exit "\$rc"
SW
    chmod +x "$ROOT/monitor/spawn-worker.sh"
}

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
    # …and _idle_probe.sh now REFUSES TO LOAD without the window-key encoder
    # (your-org/nexus-code#941): its top-of-file guard `return 2`s when
    # ../_bookkeeping.sh is unreadable, so EVERY function in that file —
    # `_openg_marked` included — silently fails to be defined and the
    # engaged-capture degrades to the active-only fallback. Measured: with the
    # encoder absent `declare -F _openg_marked` is empty; with it staged the
    # function is defined; at the pre-#941 _idle_probe.sh it was defined
    # either way. Same class as the _log-mode.sh / _version_restart.sh gaps
    # above — a helper that a fixture forgot to stage degrades to something
    # counted by nothing.
    cp "$_real_test_dir/../_bookkeeping.sh" "$ROOT/monitor/_bookkeeping.sh"
    # bootstrap-recover.sh sources ../_log-mode.sh for `_ensure_service_log`
    # (your-org/nexus-code#484). Without it the staged tree would run the
    # launcher with the helper UNDEFINED — service logs silently created
    # group-writable again, and the suite green anyway. Stage the real one.
    cp "$_real_test_dir/../_log-mode.sh" "$ROOT/monitor/_log-mode.sh"
    # bootstrap-recover.sh sources ../_dropped_manifest.sh for the
    # cold-boot manifest path + once-only delivery marker (your-org/
    # nexus-code#651). Stage the real one: the cold-boot cases below
    # assert on the manifest FILE, so a stubbed-out helper would test
    # nothing, and a missing one would leave the cold-boot path calling
    # undefined functions.
    cp "$_real_test_dir/../_dropped_manifest.sh" "$ROOT/monitor/_dropped_manifest.sh"
    # bootstrap-recover.sh sources watcher/_version_restart.sh for
    # `_version_record_service_running` (issue #186). It was never staged:
    # every case ran with the source FAILING and the helper undefined, so
    # the version stamp `_recover_launch_service` promises to write was
    # silently never written under test — and the source error leaked into
    # every stderr assertion as noise. Same class as the `_log-mode.sh`
    # gap above: a missing helper degrades to rc 127, which is counted by
    # nothing.
    cp "$_real_test_dir/_version_restart.sh" "$ROOT/monitor/watcher/_version_restart.sh"
    # bootstrap-recover.sh's `_recover_worker_last_report` no longer greps
    # filenames: it shells out to `$NEXUS_ROOT/monitor/ng reports-for-window`,
    # which keys on the frontmatter `window:` field (your-org/nexus-code#1195,
    # merged as #1303). `ng` was never staged here, so that call hit
    # `[[ -x "$ng" ]] || return 2` and EVERY manifest entry rendered the
    # "COULD NOT LOOK" arm — the cold-boot manifest's last-report field, the
    # one an orchestrator reads to decide whether a dropped worker had already
    # finished, degraded to "I could not look" for every worker and the suite
    # said so in three assertions at once. Stage the real `ng` (with the
    # primary-root resolver it refuses to start without) so this exercises the
    # real resolver rather than a stub of it — same rule as _log-mode.sh and
    # _version_restart.sh above. `_bookkeeping.sh`, `ng`'s other hard
    # dependency, is already staged.
    cp "$_real_test_dir/../ng" "$ROOT/monitor/ng"
    chmod +x "$ROOT/monitor/ng"
    cp "$_real_test_dir/../_nexus-root.sh" "$ROOT/monitor/_nexus-root.sh"
    RECOVER="$ROOT/monitor/bootstrap-recover.sh"
    REG="$ROOT/monitor/services.registry"
    BIN="$ROOT/bin"
    WINDOWS="$ROOT/windows";    : > "$WINDOWS"
    # Pane table for the agent-liveness predicate (`_nexus_window_has_live_agent`,
    # _lib.sh): `<pane_pid>|<window_name>|<pane_dead>` per row. Absent by
    # default, which is the fail-safe LIVE answer — so a case that means to
    # exercise liveness MUST seed it, or it passes on the fallback instead of
    # on evidence (your-org/nexus-code#651 skeptic r2 / the P1b survivor).
    PANES="$ROOT/panes";        : > "$PANES"
    FIXTURE_PANE_PIDS=()
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
  list-panes)   fmt=""
                shift
                while [ \$# -gt 0 ]; do
                  case "\$1" in -F) fmt="\$2"; shift 2 ;; *) shift ;; esac
                done
                [ -s "$PANES" ] || exit 0
                while IFS='|' read -r p_pid w_name p_dead; do
                  [ -n "\$w_name" ] || continue
                  line="\$fmt"
                  line="\${line//'#{window_name}'/\$w_name}"
                  line="\${line//'#{pane_dead}'/\$p_dead}"
                  line="\${line//'#{pane_pid}'/\$p_pid}"
                  printf '%s\n' "\$line"
                done < "$PANES" ;;
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
    SPAWN_DRY_CALLS="$ROOT/spawn-worker.dryrun.calls"
    write_spawn_worker_stub

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

# Seed the boot-intent record entry.sh leaves for the worker walk
# (your-org/nexus-code#651): seed_boot_intent <fresh|continue|garbage>
# [age-seconds]. Default age 5 s — a real cold boot reaches recovery in
# seconds; the TTL cases pass an age past the ttl deliberately.
seed_boot_intent() {
    local mode="$1" age="${2:-5}"
    printf 'mode=%s\nts=%s\nsource=entry.sh\npid=1\n' \
        "$mode" "$(( $(date +%s) - age ))" \
        > "$ROOT/monitor/.state/boot-intent"
}

# Make the spawn-worker stub really create the window it resumes, so a
# case can assert on the window list rather than on recorded argv.
worker_respawns_create_windows() { : > "$ROOT/spawn-worker.creates-window"; }

# Seed one pane row for the liveness predicate:
#   seed_pane <window> live|corpse
# `live` spawns a real process whose argv contains `claude` (so the /proc walk
# is genuinely exercised, not short-circuited) on a non-dead pane. `corpse` is
# the remain-on-exit shape: pane_dead=1, and the pid ALSO resolves to a
# claude-named process — because a corpse whose pid resolves to nothing passes
# with or without the `pane_dead` guard, and would pin nothing.
#
# Real pids only: an earlier fixture used pid 1 and appeared to pin the guard,
# but only on a host whose init is `bwrap` with `claude` in its argv. Never
# build a fixture on a pid you do not control.
seed_pane() {
    local window="$1" kind="$2" pid dead=0
    setsid bash -c "exec -a claude-fixture-$window sleep 45" >/dev/null 2>&1 &
    pid=$!
    FIXTURE_PANE_PIDS+=("$pid")
    [[ "$kind" == corpse ]] && dead=1
    printf '%s|%s|%s\n' "$pid" "$window" "$dead" >> "$PANES"
    sleep 0.2
}

# Window names currently in the tmux stub's world.
tmux_windows() { cat "$WINDOWS" 2>/dev/null; }

# Path of the cold-boot dropped-worker manifest in this fixture.
manifest_path() { printf '%s/monitor/.state/cold-boot-dropped-workers.md' "$ROOT"; }

# Newest `<name>.archived.<epoch>` sibling of a state file, or empty.
archived_of() { ls -1 "$1".archived.* 2>/dev/null | sort | tail -1; }

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
    # Reap seed_pane's fixture processes. Identity-checked by argv: after a
    # PID-space wrap a blind kill would signal whatever recycled the number.
    local _fp
    for _fp in "${FIXTURE_PANE_PIDS[@]+"${FIXTURE_PANE_PIDS[@]}"}"; do
        if kill -0 "$_fp" 2>/dev/null \
           && grep -q claude-fixture- \
              <<<"$(tr '\0' ' ' < "/proc/$_fp/cmdline" 2>/dev/null)"; then
            kill "$_fp" 2>/dev/null
        fi
    done
    rm -rf "$ROOT"
    unset ROOT RECOVER REG BIN WINDOWS PANES SENDS LAUNCHER_CALLS SPAWN_CALLS \
          SPAWN_DRY_CALLS ORCH_CALLS FAUX_PID HELPER_PID FIXTURE_PANE_PIDS
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
if grep -qF "$HOME/wd-a" <<<"$parsed"; then
    pass "~ expanded to \$HOME in workdir"
else
    fail "~ not expanded: $parsed"
fi
if grep -qF "$ROOT/wd-b" <<<"$parsed"; then
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
   && grep -q "w-wrapped-engaged" <<<"$(grep "operator-engaged windows captured:" "$ROOT/err")"; then
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

# ============================================================================
# Cold boot — `./watcher` without `--continue` must resurrect NOTHING
# (your-org/nexus-code#651).
#
# Every case below asserts the property on the OBSERVABLE outcome — which
# tmux windows exist afterwards — not on whether a flag was set. That is
# why these cases turn on `worker_respawns_create_windows`: with the
# argv-recording stub alone, "no worker came back" and "the stub was
# called but records nothing visible" are indistinguishable, and the test
# would be asserting a proxy for the thing it claims to prove.
# ============================================================================

# --- Case 25: cold boot resurrects nothing, archives everything, reports it --
echo '=== case 25: cold boot (mode=fresh) — no worker window created, state archived, manifest written ==='
build_case 25
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-alpha w-beta
log_event spawn w-alpha
log_event spawn w-beta
mkdir -p "$ROOT/reports"
# REAL frontmatter, not an empty file: `ng reports-for-window` matches the
# `window:` key inside a leading `---` fence and ignores the filename
# entirely (your-org/nexus-code#1195). An empty file is invisible to it, so
# the assertions below would pass or fail on the wrong mechanism.
cat > "$ROOT/reports/nexus_2026-07-30_120000_w-alpha-notes.md" <<'RPT'
---
window: w-alpha
session-id: sid-w-alpha
---

Notes filed by w-alpha before the crash.
RPT
snap_before=$(cat "$ROOT/monitor/.state/last-snapshot.txt")
seed_boot_intent fresh
run_recover

# (a) THE property: no worker window came back.
if [[ "$(tmux_windows)" != *w-alpha* ]] && [[ "$(tmux_windows)" != *w-beta* ]]; then
    pass "cold boot: NO worker window was created (observed on the tmux window list)"
else
    fail "cold boot created worker windows: $(tmux_windows) err=$(cat "$ROOT/err")"
fi

# (b) …and no resurrection was even attempted. The manifest's resolver
#     calls are --dry-run and land in a different file, so this stays a
#     clean "spawn-worker was never asked to spawn".
if [[ ! -f "$SPAWN_CALLS" ]]; then
    pass "cold boot: spawn-worker never invoked in resume (spawning) mode"
else
    fail "resume calls made on a cold boot: $(cat "$SPAWN_CALLS")"
fi

# (c) Nothing unrecoverable: the snapshot is archived, not deleted, and
#     byte-identical.
snap_arch=$(archived_of "$ROOT/monitor/.state/last-snapshot.txt")
if [[ ! -f "$ROOT/monitor/.state/last-snapshot.txt" ]] \
   && [[ -n "$snap_arch" ]] && [[ "$(cat "$snap_arch")" == "$snap_before" ]]; then
    pass "cold boot: prior worker snapshot archived (.archived.<epoch>), content intact, never deleted"
else
    fail "snapshot archive: still=$([[ -f "$ROOT/monitor/.state/last-snapshot.txt" ]] && echo yes || echo no) arch='$snap_arch'"
fi

# (d) The intent is one-shot: consumed (archived) so the SessionStart /
#     per-turn recoveries that share this script keep resuming workers.
intent_arch=$(archived_of "$ROOT/monitor/.state/boot-intent")
if [[ ! -f "$ROOT/monitor/.state/boot-intent" ]] && [[ -n "$intent_arch" ]] \
   && grep -q 'mode=fresh' "$intent_arch"; then
    pass "cold boot: boot-intent consumed — archived, not left to fire against a later recovery"
else
    fail "boot-intent not consumed: still=$([[ -f "$ROOT/monitor/.state/boot-intent" ]] && echo yes || echo no) arch='$intent_arch'"
fi

# (e) The orchestrator is handed a manifest it can act on: both dropped
#     windows, each with the session-id + workdir the canonical resolver
#     returned, its last report, and the exact re-spawn command.
man=$(manifest_path)
if [[ -s "$man" ]] \
   && grep -q '### `w-alpha`' "$man" && grep -q '### `w-beta`' "$man" \
   && grep -q 'session-id: `sid-w-alpha`' "$man" \
   && grep -q "workdir: \`$ROOT/work/w-alpha\`" "$man" \
   && grep -q 'reports/nexus_2026-07-30_120000_w-alpha-notes.md' "$man" \
   && grep -q 'monitor/spawn-worker.sh --resume w-beta' "$man" \
   && grep -qF "$(basename "$snap_arch")" "$man"; then
    pass "cold boot: manifest lists every dropped worker with session-id, workdir, last report, re-spawn command, and where its evidence was archived"
else
    fail "manifest wrong: $(cat "$man" 2>/dev/null)"
fi
# EXACT-LINE, not substring. A `grep -q` containment check cannot tell
# "correct" from "correct plus garbage": the `${report:+…}${report:-…}` pair
# that emitted the path TWICE satisfied every containment assertion above and
# shipped green (your-org/nexus-code#651 skeptic, finding 4 + its infra note).
# It lands on the field that tells the orchestrator a dropped worker had
# already finished, and a doubled path is one an agent can mis-copy.
if grep -qxF -- '- last report: `reports/nexus_2026-07-30_120000_w-alpha-notes.md`' "$man"; then
    pass "manifest 'last report' line is EXACTLY right (exact-match: a duplicated path would redden here, a substring check would not)"
else
    fail "last-report line malformed: $(grep 'last report' "$man" 2>/dev/null)"
fi
# …and the empty arm renders as the alternative ALONE, not both arms.
if grep -qxF -- '- last report: (none found under reports/)' "$man"; then
    pass "manifest 'last report' empty arm renders the placeholder alone (w-beta has no report)"
else
    fail "empty last-report arm malformed: $(grep 'last report' "$man" 2>/dev/null)"
fi

# (f) The resolver really was the canonical one, invoked read-only.
if [[ -f "$SPAWN_DRY_CALLS" ]] \
   && grep -qx -- "--resume w-alpha --dry-run" "$SPAWN_DRY_CALLS" \
   && grep -qx -- "--resume w-beta --dry-run" "$SPAWN_DRY_CALLS"; then
    pass "cold boot: manifest resolved session/workdir via spawn-worker --dry-run (canonical resolver, no reimplementation)"
else
    fail "dry-run resolver calls: $(cat "$SPAWN_DRY_CALLS" 2>/dev/null)"
fi

# The summary says "candidate(s)", not "dropped": since the liveness fix routed
# the tmux-survived shape here, some candidates may still be running and were
# never dropped. The authoritative split is the manifest writer's own line.
if grep -q "workers: cold boot — resurrected none; 2 snapshot candidate(s)" "$ROOT/err" \
   && grep -q "dropped-manifest: wrote .* (2 dropped, 0 still alive)" "$ROOT/err" \
   && (( RC == 0 )); then
    pass "cold boot: loud summary on stderr with the dropped-vs-still-alive split, exit 0"
else
    fail "rc=$RC err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 25b: the THIRD last-report arm — "could not look" ------------------
# The arm that has no other coverage, and the one that silently ate case 25's
# three assertions when `ng` went unstaged: `_recover_worker_last_report`
# propagates rc 2 rather than folding it into "none", because on the
# resumption surface "I could not look" and "there is none" send an
# orchestrator in opposite directions (your-org/nexus-code#1195, #813, #618).
# Here the reports corpus is ABSENT, so the real `ng` really returns 2.
echo '=== case 25b: cold boot, reports corpus not enumerable — manifest says COULD NOT LOOK, never "(none found)" ==='
build_case 25b
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-alpha
log_event spawn w-alpha
rm -rf "$ROOT/reports"
seed_boot_intent fresh
run_recover
man=$(manifest_path)
if grep -qxF -- '- last report: COULD NOT LOOK — the reports corpus was not enumerable' "$man" \
   && ! grep -qF -- '- last report: (none found under reports/)' "$man"; then
    pass "cold boot: an unenumerable corpus renders COULD NOT LOOK, NOT the positive negative"
else
    fail "could-not-look arm wrong: $(grep 'last report' "$man" 2>/dev/null)"
fi
cleanup_case

# --- Case 26: --continue keeps today's behaviour, unchanged ------------------
echo '=== case 26: --continue boot (mode=continue) — workers resumed, nothing archived, no manifest ==='
build_case 26
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-alpha w-beta
log_event spawn w-alpha
log_event spawn w-beta
seed_boot_intent continue
run_recover
if [[ "$(tmux_windows)" == *w-alpha* ]] && [[ "$(tmux_windows)" == *w-beta* ]] \
   && [[ -f "$SPAWN_CALLS" ]] \
   && grep -qx -- "--resume w-alpha" "$SPAWN_CALLS" \
   && grep -qx -- "--resume w-beta" "$SPAWN_CALLS"; then
    pass "--continue: both worker windows really came back (unchanged resume behaviour)"
else
    fail "continue-boot windows='$(tmux_windows)' calls=$(cat "$SPAWN_CALLS" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
if [[ -f "$ROOT/monitor/.state/last-snapshot.txt" ]] \
   && [[ ! -s "$(manifest_path)" ]] \
   && [[ ! -f "$SPAWN_DRY_CALLS" ]]; then
    pass "--continue: snapshot left in place, no manifest, resolver never run"
else
    fail "continue-boot touched cold-boot state: snap=$([[ -f "$ROOT/monitor/.state/last-snapshot.txt" ]] && echo kept || echo gone) man=$(cat "$(manifest_path)" 2>/dev/null | head -1)"
fi
if [[ ! -f "$ROOT/monitor/.state/boot-intent" ]] \
   && [[ -n "$(archived_of "$ROOT/monitor/.state/boot-intent")" ]]; then
    pass "--continue: boot-intent also one-shot (archived once acted on)"
else
    fail "continue boot-intent not consumed"
fi
cleanup_case

# --- Case 27: no intent at all → ordinary mid-life recovery, unchanged -------
# The SessionStart hook, bootstrap.sh's per-turn refresh and a manual
# `svc.sh up` all land here with NO boot-intent. Those are crash
# recoveries, not boots: resuming is exactly right, and a cold-boot
# regression here would silently disarm the workspace's crash recovery.
echo '=== case 27: no boot-intent (mid-life recovery) — workers resumed as before ==='
build_case 27
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-alpha
log_event spawn w-alpha
run_recover
if [[ "$(tmux_windows)" == *w-alpha* ]] \
   && [[ -f "$ROOT/monitor/.state/last-snapshot.txt" ]] \
   && [[ ! -s "$(manifest_path)" ]] \
   && ! grep -q 'cold boot' "$ROOT/err"; then
    pass "no boot-intent: crash recovery still resumes workers (no cold-boot behaviour leaked in)"
else
    fail "mid-life recovery changed: windows='$(tmux_windows)' err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 28: expired intent is ignored, loudly ------------------------------
# An intent whose boot never reached the worker walk (bring-up aborted,
# instance guard refused) must not fire days later against an unrelated
# recovery and wipe a live board. It expires INTO today's behaviour.
echo '=== case 28: boot-intent older than the TTL → archived and ignored, workers resumed ==='
build_case 28
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-alpha
log_event spawn w-alpha
seed_boot_intent fresh 4000          # > default ttl 900 s
run_recover
if [[ "$(tmux_windows)" == *w-alpha* ]] \
   && grep -q 'boot-intent: IGNORING' "$ROOT/err" \
   && grep -q 'ttl=900s' "$ROOT/err" \
   && [[ ! -f "$ROOT/monitor/.state/boot-intent" ]] \
   && [[ -n "$(archived_of "$ROOT/monitor/.state/boot-intent")" ]]; then
    pass "expired boot-intent: ignored loudly, archived, worker still resumed"
else
    fail "stale-intent handling: windows='$(tmux_windows)' err=$(cat "$ROOT/err")"
fi
# …and the TTL is configurable: the same record inside a widened TTL IS
# honoured, so the guard is a bound and not a hardcoded 900.
build_case 28b
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-alpha
log_event spawn w-alpha
seed_boot_intent fresh 4000
RECOVER_BOOT_INTENT_TTL=99999 run_recover
if [[ "$(tmux_windows)" != *w-alpha* ]] && grep -q 'FRESH boot requested' "$ROOT/err"; then
    pass "boot-intent TTL is configurable (RECOVER_BOOT_INTENT_TTL widens it; same record then honoured)"
else
    fail "ttl override ignored: windows='$(tmux_windows)' err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 29: --dry-run resolves but never consumes --------------------------
# boot-recover.sh runs `--dry-run` as a pure health probe at SessionStart.
# A probe that ATE the boot intent would leave the real run resurrecting
# everything — the exact bug this change exists to remove, reintroduced
# through the back door.
echo '=== case 29: --dry-run on a cold boot — decides, archives nothing, consumes nothing ==='
build_case 29
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-alpha
log_event spawn w-alpha
seed_boot_intent fresh
run_recover --dry-run
if [[ -f "$ROOT/monitor/.state/boot-intent" ]] \
   && [[ -f "$ROOT/monitor/.state/last-snapshot.txt" ]] \
   && [[ ! -s "$(manifest_path)" ]] \
   && [[ "$(tmux_windows)" != *w-alpha* ]] \
   && grep -q 'would DROP 1 worker' "$ROOT/err"; then
    pass "--dry-run: cold-boot decision reported, but intent + snapshot untouched and no manifest written"
else
    fail "dry-run consumed state: intent=$([[ -f "$ROOT/monitor/.state/boot-intent" ]] && echo kept || echo EATEN) err=$(cat "$ROOT/err")"
fi
# The real run that follows the probe must still see the intent.
run_recover
if [[ "$(tmux_windows)" != *w-alpha* ]] && [[ ! -f "$ROOT/monitor/.state/boot-intent" ]]; then
    pass "--dry-run then real run: the probe left the intent for the real run, which still dropped"
else
    fail "post-probe real run: windows='$(tmux_windows)' err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 30: an unresolvable worker is still reported, never dropped silently
echo '=== case 30: dropped worker whose session cannot be resolved is still listed ==='
build_case 30
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-ghost
log_event spawn w-ghost
echo 11 > "$ROOT/spawn-worker.dryrun.rc"
seed_boot_intent fresh
run_recover
man=$(manifest_path)
if [[ -s "$man" ]] \
   && grep -q '### `w-ghost`' "$man" \
   && grep -q 'UNRESOLVED' "$man" \
   && grep -q 'cannot resolve a session-id' "$man"; then
    pass "unresolvable dropped worker still listed, with the resolver's own diagnostic (no silent omission)"
else
    fail "ghost worker missing from manifest: $(cat "$man" 2>/dev/null)"
fi
cleanup_case

# --- Case 31: manifest delivery is once-only, and re-arms on a new cold boot -
# The manifest reaches the orchestrator through two surfaces
# (spawn-fresh-orchestrator's situation report, bootstrap.sh's on-wake
# stdout). Both share these helpers, so the once-only rule is tested
# here, once, on the shared implementation.
echo '=== case 31: _dropped_manifest_* — pending → delivered once → re-pending on a new manifest ==='
build_case 31
# shellcheck source=/dev/null
source "$ROOT/monitor/_dropped_manifest.sh"
sd="$ROOT/monitor/.state"
if ! _dropped_manifest_pending "$sd"; then
    pass "no manifest → nothing pending (the common case stays silent)"
else
    fail "pending with no manifest on disk"
fi
printf '# first drop\n' > "$(_dropped_manifest_path "$sd")"
first=$(_dropped_manifest_deliver "$sd")
if [[ "$first" == "# first drop" ]] && ! _dropped_manifest_pending "$sd"; then
    pass "manifest delivered once, then no longer pending"
else
    fail "first delivery: '$first' pending-after=$(_dropped_manifest_pending "$sd" && echo yes || echo no)"
fi
if ! _dropped_manifest_deliver "$sd" >/dev/null; then
    pass "second delivery attempt is a no-op (a settled question is not re-opened)"
else
    fail "manifest re-delivered"
fi
if [[ -s "$(_dropped_manifest_path "$sd")" ]]; then
    pass "delivery marks, never deletes — the manifest survives as the audit record"
else
    fail "manifest deleted by delivery"
fi
sleep 1                              # mtime granularity: make the rewrite strictly newer
printf '# second drop\n' > "$(_dropped_manifest_path "$sd")"
second=$(_dropped_manifest_deliver "$sd")
if [[ "$second" == "# second drop" ]]; then
    pass "a NEW cold boot's manifest goes pending again (newer-than-marker, no marker bookkeeping to forget)"
else
    fail "second cold boot not re-delivered: '$second'"
fi
cleanup_case

# --- Case 32: a cold boot that drops nothing leaves no stale manifest --------
# An undelivered manifest from an earlier cold boot must never be read as
# a description of THIS one — that would hand the orchestrator a list of
# workers to reconsider that this boot never had.
echo '=== case 32: cold boot with nothing to drop → prior manifest archived, none written ==='
build_case 32
seed_healthy_watcher
printf '# stale drop from a previous boot\n' > "$(manifest_path)"
seed_snapshot orchestrator services            # infra only: no worker candidates
seed_boot_intent fresh
run_recover
if [[ ! -s "$(manifest_path)" ]] \
   && [[ -n "$(archived_of "$(manifest_path)")" ]] \
   && grep -q 'cold boot — nothing to drop' "$ROOT/err"; then
    pass "empty cold boot: stale manifest archived (not delivered as if it were this boot's)"
else
    fail "stale manifest survived: $(cat "$(manifest_path)" 2>/dev/null) err=$(cat "$ROOT/err")"
fi
cleanup_case

# --- Case 33: the COLD_BOOT refusal arm, isolated ---------------------------
# your-org/nexus-code#651 skeptic, finding 3. Case 25 proves a cold boot
# resurrects nothing, but it cannot tell you WHICH of the two guards did it:
# the snapshot archive empties the candidate set before the workers step is
# even reached, so deleting the `elif (( COLD_BOOT == 1 ))` arm outright left
# the suite fully green. That arm had ZERO coverage while being load-bearing —
# whenever the `mv` fails (read-only or full state dir, permissions change,
# concurrent writer) it is the ONLY thing between a cold boot and a full
# resurrection, and `_recover_archive_state_file` handles that failure by
# logging a WARNING and carrying on.
#
# So: make the archive genuinely fail (read-only state dir) and assert the
# refusal still holds. The test is deliberately non-vacuous — it asserts the
# archive DID fail and the arm DID fire, so a run that never reached the
# workers step (an aborted preflight, say) reddens instead of passing quietly.
echo '=== case 33: archive fails → the COLD_BOOT refusal arm alone must stop resurrection ==='
build_case 33
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-alpha
log_event spawn w-alpha
seed_boot_intent fresh
chmod 500 "$ROOT/monitor/.state"
run_recover
chmod 700 "$ROOT/monitor/.state"      # restore before cleanup_case's rm -rf
if grep -q "WARNING failed to archive" "$ROOT/err" \
   && grep -qF "$ROOT/monitor/.state/last-snapshot.txt" "$ROOT/err" \
   && [[ -f "$ROOT/monitor/.state/last-snapshot.txt" ]]; then
    pass "archive-fails fixture is real: the snapshot mv failed and the file is still in place"
else
    fail "fixture did not reach the intended state: err=$(cat "$ROOT/err")"
fi
if grep -q "workers: cold boot (no --continue) — resurrecting nothing" "$ROOT/err"; then
    pass "the refusal arm actually fired (not a run that aborted before the workers step)"
else
    fail "refusal arm never reached: err=$(cat "$ROOT/err")"
fi
if [[ "$(tmux_windows)" != *w-alpha* ]] && [[ ! -f "$SPAWN_CALLS" ]]; then
    pass "archive failed AND no worker window came back — the refusal arm is independently load-bearing"
else
    fail "resurrection despite cold boot: windows='$(tmux_windows)' calls=$(cat "$SPAWN_CALLS" 2>/dev/null)"
fi
cleanup_case

# --- Case 34: the manifest must not call LIVE workers dropped ---------------
# your-org/nexus-code#651 skeptic r2, finding 1 — a defect the liveness fix
# newly EXPOSED rather than one it left alone.
#
# Before that fix, reaching the cold-boot path required no orchestrator window
# at all, which in practice meant the tmux server had died and taken every
# worker with it: "everything in the snapshot is gone" was true by
# construction. The fix deliberately routes the tmux-SURVIVED crash shape here
# too (claude segfaults / OOMs / `/exit`s — the whole point of the change) —
# and in that shape every worker window is still running. Building the manifest
# straight from the snapshot then hands a fresh orchestrator a categorical
# "they are NOT running now" about windows it can see for itself, with a
# `--resume` instruction attached.
echo '=== case 34: cold boot with a still-ALIVE worker → partitioned, not mislabelled ==='
# Three shapes, because two would not discriminate the PREDICATE:
#   w-gone   — no window at all           → dropped
#   w-alive  — window + live agent        → still running
#   w-corpse — window + DEAD pane         → dropped
# w-corpse is the load-bearing one. With a name-only check
# (`_recover_window_exists` alone) it would be filed under "still running" —
# the same corpse-is-not-liveness misreading this PR exists to remove, merely
# relocated from entry.sh into the manifest. A two-shape fixture cannot tell
# the two predicates apart; verified by mutation (the name-only mutant
# survived until this row existed).
build_case 34
seed_healthy_watcher
worker_respawns_create_windows
seed_snapshot w-gone w-alive w-corpse
log_event spawn w-gone
log_event spawn w-alive
log_event spawn w-corpse
echo w-alive  >> "$WINDOWS"         # survived the orchestrator's death
echo w-corpse >> "$WINDOWS"         # remain-on-exit leftover: listed, but dead
seed_pane w-alive  live
seed_pane w-corpse corpse
seed_boot_intent fresh
run_recover
man=$(manifest_path)
if [[ -s "$man" ]] \
   && grep -q '^# Cold boot dropped 2 worker agent(s)$' "$man"; then
    pass "manifest counts only genuinely dropped workers (live one excluded, corpse INCLUDED)"
else
    fail "header wrong: $(head -1 "$man" 2>/dev/null)"
fi
# The categorical "NOT running" claim must cover w-gone and NOT w-alive. Assert
# on SECTION MEMBERSHIP, not mere presence — the old manifest also "mentioned"
# the live worker, which is exactly what made it wrong.
gone_sec=$(awk '/^## Dropped/{f=1;next} /^## Still running/{f=0} f' "$man")
live_sec=$(awk '/^## Still running/{f=1;next} /^---$/{f=0} f' "$man")
if [[ "$gone_sec" == *'`w-gone`'* ]] && [[ "$gone_sec" != *'w-alive'* ]] \
   && [[ "$live_sec" == *'`w-alive`'* ]] && [[ "$live_sec" != *'w-gone'* ]]; then
    pass "each worker is in the RIGHT section: w-gone under Dropped, w-alive under Still running"
else
    fail "sections wrong — dropped='$gone_sec' still='$live_sec'"
fi
# THE predicate assertion: a corpse window EXISTS in tmux, so a name check
# calls it alive. Only real agent-liveness puts it where it belongs.
if [[ "$gone_sec" == *'`w-corpse`'* ]] && [[ "$live_sec" != *'w-corpse'* ]]; then
    pass "a remain-on-exit CORPSE worker is Dropped, not Still-running (agent liveness, not window presence)"
else
    fail "corpse misfiled — dropped='$gone_sec' still='$live_sec'"
fi
# The live worker must not carry a --resume instruction: acting on it exits 13
# on a live pane, and telling an orchestrator to do that is the misinformation.
if [[ "$live_sec" != *"--resume w-alive"* ]] \
   && [[ "$live_sec" == *"Do NOT"* ]]; then
    pass "live worker carries no --resume instruction (and the section says so explicitly)"
else
    fail "live worker still advertised as resumable: $live_sec"
fi
# And the property that must never regress: still nothing resurrected.
if [[ ! -f "$SPAWN_CALLS" ]] && [[ "$(tmux_windows)" != *w-gone* ]]; then
    pass "cold boot with a live worker present: still resurrects nothing, and leaves the live one running"
else
    fail "resurrection: calls=$(cat "$SPAWN_CALLS" 2>/dev/null) windows='$(tmux_windows)'"
fi
if [[ "$(tmux_windows)" == *w-alive* ]]; then
    pass "the live worker was left ALONE — declining to resurrect is not terminating"
else
    fail "live worker vanished: $(tmux_windows)"
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
