#!/usr/bin/env bash
# Tests for monitor/_log-mode.sh and the service-log creation sites
# (your-org/nexus-code#484).
#
# Run: bash monitor/test-service-log-mode.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE CONTRACT UNDER TEST. A bare `>>"$lf"` creates the log under the
# ambient umask — `0660`, group-writable, in a group-shared tree. A
# group-writable log is not evidence: anyone in the unix group can
# rewrite it and nothing records that they did. Every service log must
# therefore have its mode set AT CREATION (0640: group read yes, group
# write no), not at rotation.
#
# EVERY TEST HERE RUNS UNDER A DELIBERATELY PERMISSIVE `umask 000`.
# That is the point: under the repo's real umask a wrong implementation
# can still look right. Test 0 is the control — it asserts that a bare
# redirect under this umask really does produce a world-writable log, so
# a green suite can never be an artifact of an umask that was tight all
# along. To watch the real assertions fail against the pre-fix world:
#
#     LOG_MODE_HELPER=noop bash monitor/test-service-log-mode.sh
#
# which stubs `_ensure_service_log` to a no-op — exactly the state of
# `dev` before this change — and every mode assertion goes red.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_ne() {
    local label="$1" got="$2" notwant="$3"
    if [[ "$got" != "$notwant" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q which must differ from %q\n' "$label" "$got" "$notwant" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

mode() { stat -c %a "$1" 2>/dev/null || echo "MISSING"; }
# Group- or other-writable? The property the issue is actually about.
group_or_other_writable() {
    local m; m=$(stat -c %a "$1" 2>/dev/null) || { echo "MISSING"; return; }
    local g=${m: -2:1} o=${m: -1:1}
    if (( (g & 2) || (o & 2) )); then echo yes; else echo no; fi
}

# ---- load the helper (or, for the fail-watch, a no-op stand-in) ----------
if [[ "${LOG_MODE_HELPER:-real}" == "noop" ]]; then
    echo "!! LOG_MODE_HELPER=noop — emulating pre-#484 dev; assertions SHOULD fail"
    _ensure_service_log() { :; }
else
    # shellcheck source=_log-mode.sh
    . "$_test_dir/_log-mode.sh"
fi

WORK=$(mktemp -d)
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# The whole suite runs maximally permissive. Anything that comes out
# tight came out tight because the code made it so.
umask 000

# ── 0. CONTROL: prove the umask is really permissive ─────────────────────
# Without this, a green suite could just mean the umask was 077 all along.
echo "## 0. control: a bare >> redirect under umask 000 IS world-writable"
ctl="$WORK/control.log"
: >> "$ctl"
assert_eq "bare redirect yields 666"          "$(mode "$ctl")" "666"
assert_eq "bare redirect is group/other-writable" "$(group_or_other_writable "$ctl")" "yes"

# ── 1. Fresh creation is 0640 ────────────────────────────────────────────
echo "## 1. _ensure_service_log creates a fresh log at 0640"
lf="$WORK/fresh.log"
_ensure_service_log "$lf"
assert_eq "created"                    "$([[ -f "$lf" ]] && echo yes || echo no)" "yes"
assert_eq "mode is 640"                "$(mode "$lf")" "640"
assert_eq "not group/other-writable"   "$(group_or_other_writable "$lf")" "no"

# ── 2. The real usage pattern: helper, then the redirect ─────────────────
# The redirect must not loosen what the helper tightened.
echo "## 2. helper + the actual '>>' redirect keeps 0640"
lf="$WORK/serve.log"
_ensure_service_log "$lf"
( setsid bash -c 'echo hello' </dev/null >>"$lf" 2>&1 & ) 2>/dev/null
sleep 0.3
assert_eq "mode still 640 after the redirect" "$(mode "$lf")" "640"
assert_ne "and differs from the bare-redirect control" "$(mode "$lf")" "$(mode "$ctl")"
assert_eq "service output landed"             "$(cat "$lf" 2>/dev/null)" "hello"

# ── 3. A pre-existing 0660 log is repaired ───────────────────────────────
echo "## 3. pre-existing 0660 log is repaired to 0640 on next launch"
lf="$WORK/legacy.log"
: >> "$lf"; chmod 660 "$lf"
printf 'historic evidence\n' >> "$lf"
assert_eq "starts 660" "$(mode "$lf")" "660"
_ensure_service_log "$lf"
assert_eq "repaired to 640"          "$(mode "$lf")" "640"
assert_eq "content NOT truncated"    "$(cat "$lf")" "historic evidence"

# ── 4. Never loosen: a 0600 log stays 0600 ───────────────────────────────
# `g-w,o-rwx` only removes bits. A helper that chmod'd a literal 640
# would silently GRANT group read to a log deliberately kept private.
echo "## 4. a 0600 log is never loosened to 0640"
lf="$WORK/private.log"
: >> "$lf"; chmod 600 "$lf"
_ensure_service_log "$lf"
assert_eq "stays 600" "$(mode "$lf")" "600"

# ── 5. Idempotent across repeated launches ───────────────────────────────
echo "## 5. idempotent"
lf="$WORK/idem.log"
_ensure_service_log "$lf"; m1=$(mode "$lf")
printf 'line\n' >> "$lf"
_ensure_service_log "$lf"; m2=$(mode "$lf")
_ensure_service_log "$lf"; m3=$(mode "$lf")
assert_eq "mode stable 1→2" "$m1" "$m2"
assert_eq "mode stable 2→3" "$m2" "$m3"
assert_eq "rc is 0"         "$( _ensure_service_log "$lf"; echo $? )" "0"
assert_eq "content preserved across calls" "$(cat "$lf")" "line"

# ── 6. Missing parent directory is created ───────────────────────────────
echo "## 6. missing parent dir is created"
lf="$WORK/deep/nested/dir/serve.log"
_ensure_service_log "$lf"
assert_eq "log exists"  "$([[ -f "$lf" ]] && echo yes || echo no)" "yes"
assert_eq "mode is 640" "$(mode "$lf")" "640"

# ── 7. NEVER fail a launch: unwritable parent, empty arg, missing arg ────
# The helper's whole risk profile is that it runs on the launch path.
echo "## 7. the helper never returns non-zero, whatever the world does"
ro="$WORK/readonly"
mkdir -p "$ro"; chmod 500 "$ro"
_ensure_service_log "$ro/cannot-create.log"; assert_eq "unwritable parent → rc 0" "$?" "0"
chmod 700 "$ro"
_ensure_service_log ""                     ; assert_eq "empty path → rc 0"       "$?" "0"
_ensure_service_log                        ; assert_eq "no arg → rc 0"           "$?" "0"
lf="$WORK/adir"; mkdir -p "$lf"
_ensure_service_log "$lf"                  ; assert_eq "path is a directory → rc 0" "$?" "0"

# ── 8. A log owned by another uid is left alone, launch still proceeds ────
# We cannot chown without root, so assert the guard that implements it:
# a path that is not `-O` ours must be skipped rather than chmod-ed.
echo "## 8. a log we do not own is left alone (rc 0, no chmod attempt)"
notmine="/etc/hostname"     # exists, root-owned, we are not root
if [[ -e "$notmine" && ! -O "$notmine" ]]; then
    before=$(mode "$notmine")
    _ensure_service_log "$notmine"; rc=$?
    assert_eq "rc 0 on a foreign-owned log"  "$rc" "0"
    assert_eq "mode untouched"               "$(mode "$notmine")" "$before"
else
    echo "  SKIP: no foreign-owned file available (running as root?)"
fi

# ── 9. END-TO-END: the real fleet-wide launcher, bootstrap-recover.sh ─────
# _recover_launch_service is THE create-by-redirect site for every
# registry service (remote-ssh.log, labsh-service.log, serve.log,
# deploy.log, annzarro.log …). bootstrap-recover.sh is source-safe: it
# runs _recover_main only when executed directly.
echo "## 9. end-to-end: bootstrap-recover.sh::_recover_launch_service"
if [[ "${LOG_MODE_HELPER:-real}" == "noop" ]]; then
    echo "  (fail-watch mode: sourcing the real script would load the real helper)"
    echo "  SKIP: end-to-end case is only meaningful against the real helper"
else
  E2E="$WORK/e2e"
  mkdir -p "$E2E/monitor/.state" "$E2E/svc"
  out=$(
    NEXUS_ROOT="$E2E" NEXUS_STATE_DIR="$E2E/monitor/.state" \
    NEXUS_SERVICES_REGISTRY="$E2E/registry" \
    bash -c '
        umask 000
        set -uo pipefail
        source "$1/bootstrap-recover.sh" 2>/dev/null || { echo "SOURCE_FAILED"; exit 0; }
        declare -F _recover_launch_service >/dev/null || { echo "NO_FUNC"; exit 0; }
        lf="$2/svc/serve.log"
        _recover_launch_service "testsvc" "$2/svc" "/bin/echo started" "$lf" >/dev/null 2>&1
        sleep 0.4
        stat -c %a "$lf" 2>/dev/null || echo MISSING
    ' _ "$_test_dir" "$E2E"
  )
  case "$out" in
      SOURCE_FAILED|NO_FUNC)
          echo "  SKIP: could not source bootstrap-recover.sh in isolation ($out)" ;;
      *)
          assert_eq "registry service log created 0640, not 0660" "$out" "640" ;;
  esac
fi

# ── 10. Every owned create-by-redirect site guards its log ───────────────
# A behavioural test can only drive the sites it can reach. This lint keeps
# the *set* closed: add a new service-log redirect without an
# `_ensure_service_log` in front of it and this goes red. The issue named
# two sites; the eleven outside monitor/watcher/ landed with #484/PR #508,
# and the monitor/watcher/ residual (deferred there because a concurrent
# agent owned the tree) landed with nexus-code#509 — the set is closed.
echo "## 10. each owned service-log redirect is preceded by the helper"
SITES=(
    "bootstrap-recover.sh"          # every registry service log (fleet-wide)
    "boot-recover.sh"               # boot-recover.log
    "cc-restart-watchdog-loop.sh"   # restart-watchdog.log (tee -a)
    "jupyter-up.sh"                 # labsh-periodic.log
    "labsh-supervised.sh"           # labsh-periodic.log
    "cc-auto-update-apply.sh"       # apply.log + detached-restart.log
    "node-forensics.sh"             # node-forensics.log (incl. post-rotation)
    "gh-shim.sh"                    # impersonate.log  (audit)
    "hooks/gh-write-guard.sh"       # gh-bypass-warnings.log (audit)
    "remote-forced-command.sh"      # forced-command.log (audit)
    "remote-enroll-session.sh"      # self-enroll.log (audit)
    # -- the monitor/watcher/ residual (nexus-code#509) --
    "watcher/launcher.sh"           # watcher.log (spawn redirects)
    "watcher/main.sh"               # watcher-alerts.log + fresh-spawn fork
    "watcher/_version_restart.sh"   # watcher.log (self-restart re-exec)
    "watcher/_github.sh"            # watcher-alerts.log (graphql gate)
    "watcher/_scheduler.sh"         # watcher-scheduler.jsonl
    "watcher/_unstick.sh"           # unstick log
    "watcher/_cc_auto_update.sh"    # detached-restart.log
    "watcher/spawn-fresh-orchestrator.sh"  # watcher.log
)
for f in "${SITES[@]}"; do
    p="$_test_dir/$f"
    if [[ ! -f "$p" ]]; then
        printf '  FAIL: %s — file missing\n' "$f" >&2; FAIL=$(( FAIL + 1 )); continue
    fi
    if grep -q '_ensure_service_log' "$p"; then
        printf '  PASS: %s calls _ensure_service_log\n' "$f"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s creates a service log by redirect but never calls _ensure_service_log\n' "$f" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

# ── 11. The helper really is POSIX sh (gh-shim.sh sources it as `sh`) ────
echo "## 11. _log-mode.sh is sourceable and correct under dash"
if command -v dash >/dev/null 2>&1; then
    lf="$WORK/dash.log"
    dash -c ". \"\$1\"; _ensure_service_log \"\$2\"" _ "$_test_dir/_log-mode.sh" "$lf" 2>/dev/null
    assert_eq "dash: rc 0"          "$?" "0"
    assert_eq "dash: created 0640"  "$(mode "$lf")" "640"
else
    echo "  SKIP: dash not on PATH"
fi

# ── 12. Watcher modules' own log writers create 0640 (nexus-code#509) ────
# Behavioural, not lint: source each module standalone (they self-source
# _log-mode.sh via BASH_SOURCE — the #508 lesson: a subset-staged tree
# with the helper missing must fail LOUD, not run with it undefined) and
# drive its writer under the planted umask.
echo "## 12. watcher module log writers create 0640"
if [[ "${LOG_MODE_HELPER:-real}" == "noop" ]]; then
    echo "  SKIP: fail-watch mode (modules source the real helper)"
else
    lf="$WORK/unstick.log"
    ( umask 000
      source "$_test_dir/watcher/_unstick.sh"
      UNSTICK_LOG="$lf" unstick_log "hello" ) 2>/dev/null
    assert_eq "unstick_log creates 0640"        "$(mode "$lf")" "640"
    lf="$WORK/sched.jsonl"
    ( umask 000
      source "$_test_dir/watcher/_scheduler.sh"
      MONITOR_SCHEDULER_LOG="$lf" _scheduler_log_fire t 0 1 2 ) 2>/dev/null
    assert_eq "_scheduler_log_fire creates 0640" "$(mode "$lf")" "640"
fi

# ── 13. END-TO-END: launcher.sh's spawn redirect creates watcher.log 0640 ─
# The case nexus-code#509 asked for verbatim: drive the real launcher in
# an isolated fixture tree (stub main.sh + tmux + config, the
# test-launcher-* pattern) under umask 000 and stat the log the spawn
# redirect created.
echo "## 13. end-to-end: launcher.sh spawn creates watcher.log 0640"
if [[ "${LOG_MODE_HELPER:-real}" == "noop" ]]; then
    echo "  SKIP: fail-watch mode (the copied launcher sources the real helper)"
else
    L="$WORK/launcher-e2e"
    mkdir -p "$L/monitor/watcher" "$L/monitor/.state" "$L/bin" "$L/config"
    cp "$_test_dir/watcher/launcher.sh"       "$L/monitor/watcher/launcher.sh"
    cp "$_test_dir/watcher/_lib.sh"           "$L/monitor/watcher/_lib.sh"
    cp "$_test_dir/watcher/_respawn_async.sh" "$L/monitor/watcher/_respawn_async.sh"
    cp "$_test_dir/_log-mode.sh"              "$L/monitor/_log-mode.sh"
    printf '#!/usr/bin/env bash\necho $$ > "%s"\nsleep 30\n' \
        "$L/monitor/.state/watcher.pid" > "$L/monitor/watcher/main.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$L/bin/tmux"
    printf '#!/usr/bin/env bash\necho "${2:-}"\n' > "$L/config/load.sh"
    chmod +x "$L/monitor/watcher/launcher.sh" "$L/monitor/watcher/main.sh" \
             "$L/bin/tmux" "$L/config/load.sh"
    ( umask 000; PATH="$L/bin:$PATH" "$L/monitor/watcher/launcher.sh" ) \
        >"$L/out" 2>&1
    e2e_rc=$?
    wlog="$L/monitor/.state/watcher.log"
    if (( e2e_rc != 0 )) || [[ ! -f "$wlog" ]]; then
        printf '  FAIL: launcher e2e did not produce %s (rc=%s): %s\n' \
            "$wlog" "$e2e_rc" "$(tail -2 "$L/out" 2>/dev/null | tr '\n' ' ')" >&2
        FAIL=$(( FAIL + 1 ))
    else
        assert_eq "watcher.log created 0640, not 0660" "$(mode "$wlog")" "640"
    fi
    # Reap the stub watcher (fixture-scoped: its argv carries $L).
    _p=$(cat "$L/monitor/.state/watcher.pid" 2>/dev/null || true)
    if [[ "$_p" =~ ^[0-9]+$ ]] \
       && grep -aq "$L/monitor/watcher/main.sh" "/proc/$_p/cmdline" 2>/dev/null; then
        kill "$_p" 2>/dev/null || true
    fi
fi

# ---- summary -------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
fi
printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
exit 1
