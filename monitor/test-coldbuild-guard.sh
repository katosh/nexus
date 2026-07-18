#!/usr/bin/env bash
# test-coldbuild-guard.sh — the cold-build guard (your-org/your-nexus#273).
#
# A labsh bring-up re-materialises its ephemeral uvx environment whenever the
# (unpinned) jupyterlab resolution drifts: measured 2026-07-13 on this nexus at
# 15m24s to link 96 packages onto NFS + ~2min to import and bind — a ~19-minute
# window in which nothing listens and the healthcheck legitimately fails. A
# stop/restart in that window DISCARDS the build and restarts the clock, which
# is what makes a slow bring-up look like a crash loop.
#
# The guard therefore refuses stop/restart while a build is in flight. Its
# correctness is ALL about the two directions:
#
#   trips wrongly   ⇒ a genuinely dead service can never be restarted. WORSE.
#   misses a build  ⇒ one rebuild is wasted. Recoverable.
#
# so the predicate must fail CLOSED (⇒ "not in progress" ⇒ restart allowed) on
# anything it cannot positively prove. Most of the cases below pin that down.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# ── keep the suite OUT of live service state (your-org/your-nexus#273) ─────
# `_coldbuild_stalled` persists a progress sample under
# $STATE_DIR/service-health/<name>.buildprogress, and the cases below use the
# REAL service name `jupyterlab`. Round 2 "fixed" this by exporting STATE_DIR
# before sourcing svc.sh — WHICH NEVER WORKED: svc.sh sources
# bootstrap-recover.sh, which does
#     STATE_DIR="${NEXUS_STATE_DIR:-$NEXUS_ROOT/monitor/.state}"
# UNCONDITIONALLY, clobbering the export. Round 3 then wrote a dead test-double
# pid into the LIVE jupyterlab record — a fake build-in-progress marker sitting
# in production state, which is how a phantom incident gets manufactured later.
#
# NEXUS_STATE_DIR is the variable bootstrap-recover actually honours, so redirect
# THAT — before the source, so the derived STATE_DIR lands in the sandbox too.
TMP=$(mktemp -d) || exit 1
export NEXUS_STATE_DIR="$TMP/state"
export STATE_DIR="$TMP/state"

# The real directories the suite must never touch. Snapshot them now; assert at
# the end that we did not write into them. An assertion, not a convention — the
# previous fix was reported and regressed.
#
# Watch the path the UNFIXED code would have written to, which is NOT necessarily
# this clone: bootstrap-recover derives STATE_DIR from $NEXUS_ROOT, and NEXUS_ROOT
# is exported into every nexus worker's environment pointing at the PRIMARY clone.
# That is exactly what happened — a suite run from a worktree polluted the primary
# clone's state. Watching only "$PWD/.state" would have missed the regression it
# exists to catch.
LIVE_DIRS=("$PWD/.state/service-health")
if [[ -n "${NEXUS_ROOT:-}" && -d "$NEXUS_ROOT/monitor/.state/service-health" ]]; then
    LIVE_DIRS+=("$NEXUS_ROOT/monitor/.state/service-health")
fi
# Fingerprint ONLY the *.buildprogress records, not the whole directory: the
# live watcher and other workers write <svc>.events / <svc>.restart into this
# same dir continuously, so a whole-dir snapshot is FLAKY (it failed on the very
# first run for that reason). `<name>.buildprogress` is the only thing
# _coldbuild_stalled can create, so it is the precise and stable pollution
# vector — and mutation-proved to catch the regression.
live_fingerprint() {
    local d f
    for d in "${LIVE_DIRS[@]}"; do
        for f in "$d"/*.buildprogress; do
            [[ -e "$f" ]] && printf '%s %s\n' "$f" "$(cat "$f" 2>/dev/null)"
        done
    done
    return 0
}
LIVE_BEFORE=$(live_fingerprint)

source ./_labsh_build_evidence.sh
# svc.sh guards main() behind a BASH_SOURCE test, so sourcing yields functions.
source ./svc.sh >/dev/null 2>&1 || true

# Prove the redirect actually took, rather than trusting it (round 2 did not).
if [[ "${STATE_DIR:-}" != "$TMP/state" ]]; then
    echo "FATAL: STATE_DIR is '${STATE_DIR:-<unset>}', not the sandbox — the suite would write to LIVE state." >&2
    exit 1
fi

pass=0; fail=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail+1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got rc=$2, want rc=$3)"; fi; }

BUILD=''
cleanup() { [[ -n "$BUILD" ]] && kill "$BUILD" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$STATE_DIR/service-health"

wd="$TMP/wd"; mkdir -p "$wd/.jupyter"
printf 'PORT=9705\nSCHEME=http\n' > "$wd/.jupyter/labsh-service.env"
: > "$wd/.jupyter/labsh.bg.log"      # no URL yet ⇒ cold phase

# ── a test double for an in-flight build ────────────────────────────────────
# It must satisfy every gate labsh_build_is_ours applies: our uid, an exe whose
# basename is uv/uvx, cwd == the service workdir, and an argv carrying
# jupyter-lab + this service's port. A copy of bash gives us a process that
# blocks and tolerates an arbitrary argv; the gates read /proc, not the binary.
#
# `sleep 120; :` — NOT a bare `sleep 120`. bash optimizes a -c script that is a
# single simple command into a direct exec, replacing itself, so /proc/exe would
# become /bin/sleep and the double would stop looking like `uv`. The trailing
# `:` keeps bash resident as the process under test.
cp /bin/bash "$TMP/uv"
( cd "$wd" && exec "$TMP/uv" -c 'sleep 120; :' \
    uv tool uvx --python 3.12 --from jupyterlab jupyter-lab --port 9705 --ip 0.0.0.0 ) &
BUILD=$!
sleep 1
kill -0 "$BUILD" 2>/dev/null || { echo "FATAL: test double did not start"; exit 1; }
echo "$BUILD" > "$wd/.jupyter/labsh.bg.pid"

echo "=== POSITIVE: a build in flight is detected, and the guard refuses ==="
if ev=$(labsh_build_in_progress "$wd"); then
    ok "labsh_build_in_progress detects the build (pid+age: '$ev')"
else
    bad "labsh_build_in_progress missed an in-flight build"
fi

SVC_FORCE=0
_coldbuild_guard jupyterlab "$wd" /x/labsh-supervised.sh >/dev/null 2>&1
check "guard REFUSES stop during an in-flight build" "$?" "1"

SVC_FORCE=1
_coldbuild_guard jupyterlab "$wd" /x/labsh-supervised.sh >/dev/null 2>&1
check "--force / SVC_FORCE=1 overrides the guard" "$?" "0"

SVC_FORCE=0
_coldbuild_guard dolimap-serve "$wd" ./serve-supervised.sh >/dev/null 2>&1
check "a non-labsh service is never guarded" "$?" "0"

echo "=== BOUNDS: the guard must never refuse a WEDGED build (your-org/your-nexus#273 round 2) ==="
# The first cut had no time bound, which nullified the watcher's cold_build_ceiling:
# the watcher would correctly decide to act past its ceiling, call `svc.sh restart`,
# and be REFUSED -- automated recovery defeated, human required. Both bounds below
# exist to make that impossible.
# (1) AGE CAP. Shrink the watcher's ceiling so our seconds-old double is "past" it.
SVC_FORCE=0
MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=1 \
    _coldbuild_guard jupyterlab "$wd" /x/labsh-supervised.sh >/dev/null 2>&1
check "past the cold-build ceiling ⇒ presumed WEDGED ⇒ restart ALLOWED" "$?" "0"

# The cap tracks the MINIMUM of the watcher ceiling and the reap budget, so the
# guard can never outlast the layer that is about to act on the build.
MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=9999 LABSH_COLD_BUILD_BUDGET=1 \
    _coldbuild_guard jupyterlab "$wd" /x/labsh-supervised.sh >/dev/null 2>&1
check "past the supervisor's reap budget (the smaller bound) ⇒ ALLOWED" "$?" "0"

# ceiling 0 disables the watcher's cold-build defer entirely; the guard must
# not defer either, or it would defer where the watcher does not.
MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=0 \
    _coldbuild_guard jupyterlab "$wd" /x/labsh-supervised.sh >/dev/null 2>&1
check "cold-build defer disabled (ceiling=0) ⇒ guard defers too ⇒ ALLOWED" "$?" "0"

# (2) PROGRESS. Under the cap, a build that is MOVING is protected...
rm -f "$STATE_DIR/service-health"/*.buildprogress
MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=9999 LABSH_BUILD_STALL_SECONDS=1 \
    _coldbuild_guard jupyterlab "$wd" /x/labsh-supervised.sh >/dev/null 2>&1
check "under the cap, first sight of a build ⇒ REFUSED (baseline taken)" "$?" "1"

printf 'materialising...\n' >> "$wd/.jupyter/labsh.bg.log"   # forward motion
sleep 2
MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=9999 LABSH_BUILD_STALL_SECONDS=1 \
    _coldbuild_guard jupyterlab "$wd" /x/labsh-supervised.sh >/dev/null 2>&1
check "build is PROGRESSING (log grew) ⇒ still REFUSED" "$?" "1"

# ...but a build that stops moving for the whole stall window is released.
# (Nothing advances the double's CPU/wchar/log from here on.)
sleep 2
MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS=9999 LABSH_BUILD_STALL_SECONDS=1 \
    _coldbuild_guard jupyterlab "$wd" /x/labsh-supervised.sh >/dev/null 2>&1
check "alive but NO forward progress for the stall window ⇒ presumed wedged ⇒ ALLOWED" "$?" "0"

# A healthy NFS build was measured frozen (no CPU, no wchar, no log) for 90+s
# while legitimately progressing, so the default window must be far above that.
#
# Read the default OUT OF THE GUARD, from the refusal text it prints, with the
# env var UNSET (env -u) so svc.sh must supply it. The previous version of this
# assertion was a TAUTOLOGY — it expanded ${LABSH_BUILD_STALL_SECONDS:-600} in
# the TEST's own scope, where the variable is unset, and asserted 600 == 600
# while never observing svc.sh at all. The round-2 skeptic proved it un-failable
# by mutating the guard's default 600 → 900 and watching the suite stay GREEN.
# An assertion that cannot fail is decoration (your-org/your-nexus#273).
# Every knob UNSET (env -u), so the numbers can only come from svc.sh's own
# defaults.
#
# MUTATION SENSITIVITY — the honest account. The cap is
#     cap = min(watcher_ceiling, reap_budget),  both defaulting to 1800
# so raising EITHER bound alone leaves cap = min(3600, 1800) = 1800: an
# EQUIVALENT mutant that stays GREEN. (I published "cap 1800→3600 ⇒ RED" in the
# PR, the commit, the incident and the report. That is FALSE — my sed had
# silently mutated BOTH bounds. The round-3 skeptic ran the single-bound mutant
# and got GREEN. Correcting it here rather than swapping the evidence quietly.)
# The failable direction is DOWNWARD, at EITHER bound — verified:
#     config-helper 1800→900  ⇒ RED 22/1
#     reap-budget   1800→900  ⇒ RED 22/1
#     stall default  600→900  ⇒ RED 22/1
# NEXUS_STATE_DIR, not STATE_DIR: bootstrap-recover.sh (sourced by svc.sh)
# recomputes STATE_DIR from it and would otherwise clobber the sandbox.
rm -f "$STATE_DIR/service-health"/*.buildprogress
msg=$(env -u LABSH_BUILD_STALL_SECONDS \
          -u MONITOR_SERVICE_HEALTH_COLD_BUILD_CEILING_SECONDS \
          -u LABSH_COLD_BUILD_BUDGET \
          NEXUS_STATE_DIR="$STATE_DIR" \
      bash -c "SVC_FORCE=0; source ./svc.sh >/dev/null 2>&1 || true
               [[ \"\$STATE_DIR\" == '$STATE_DIR' ]] || { echo 'FATAL: subshell STATE_DIR escaped to live state'; exit 1; }
               _coldbuild_guard jupyterlab '$wd' /x/labsh-supervised.sh" 2>&1)
check "the guard's OWN default stall window is 600s (read from its refusal text)" \
    "$(printf '%s' "$msg" | grep -oE 'for [0-9]+s' | grep -oE '[0-9]+' | head -1)" "600"
check "the guard's OWN default age cap is 1800s (read from its refusal text)" \
    "$(printf '%s' "$msg" | grep -oE 'build is [0-9]+s old' | grep -oE '[0-9]+' | head -1)" "1800"

# The refusal must not leak raw shell errors at the operator (the first-sight
# refusal used to emit "buildprogress: No such file or directory" — a redirect
# failure bash reports itself, which `read`'s 2>/dev/null cannot suppress).
if printf '%s' "$msg" | grep -qE 'No such file or directory|line [0-9]+:'; then
    bad "refusal text leaks a raw shell error to the operator"
else
    ok "refusal text is clean (no raw shell error leaked)"
fi

echo "=== the watcher's own restart path can never reach the guard ==="
# Structural, deliberately NOT executed: calling cmd_stop/cmd_restart with
# 'watcher' would stop the LIVE watcher. Assert instead that both functions
# dispatch watcher) before the guard call, so the guard is unreachable for it.
for fn in cmd_stop cmd_restart; do
    body=$(declare -f "$fn")
    w=$(printf '%s\n' "$body" | grep -n 'watcher)'        | head -1 | cut -d: -f1)
    g=$(printf '%s\n' "$body" | grep -n '_coldbuild_guard' | head -1 | cut -d: -f1)
    if [[ -n "$w" && -n "$g" ]] && (( w < g )); then
        ok "$fn dispatches watcher) before _coldbuild_guard (guard unreachable for the watcher)"
    else
        bad "$fn: watcher dispatch (line ${w:-none}) does not precede the guard (line ${g:-none})"
    fi
done

echo "=== (a) short-circuit: a bound URL wins even while the build process lives ==="
printf 'http://127.0.0.1:9705/lab?token=x\n' > "$wd/.jupyter/labsh.bg.log"
labsh_build_in_progress "$wd" >/dev/null 2>&1
check "URL bound ⇒ cold phase over ⇒ restartable (even with a live build pid)" "$?" "1"
: > "$wd/.jupyter/labsh.bg.log"

echo "=== (b2) the /proc scan finds a build whose bg.pid we no longer hold ==="
rm -f "$wd/.jupyter/labsh.bg.pid"
labsh_build_in_progress "$wd" >/dev/null 2>&1
check "build found by /proc scan with NO bg.pid (prior supervisor generation)" "$?" "0"

# Everything below asserts the fail-closed direction, which is only meaningful
# once NO build exists. Reap the double first — otherwise (b2) correctly keeps
# finding it and every 'no build' case is vacuous.
kill "$BUILD" 2>/dev/null; wait "$BUILD" 2>/dev/null; BUILD=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
    labsh_build_in_progress "$wd" >/dev/null 2>&1 || break
    sleep 0.5
done
labsh_build_in_progress "$wd" >/dev/null 2>&1
check "double reaped ⇒ no build detected (precondition for the cases below)" "$?" "1"

echo "=== NEGATIVE: must FAIL CLOSED — never block a restart it cannot justify ==="

echo 999999 > "$wd/.jupyter/labsh.bg.pid"
labsh_build_in_progress "$wd" >/dev/null 2>&1
check "bg.pid is a dead pid ⇒ fails closed" "$?" "1"

echo $$ > "$wd/.jupyter/labsh.bg.pid"
labsh_build_in_progress "$wd" >/dev/null 2>&1
check "bg.pid is an unrelated live pid (this shell) ⇒ fails closed" "$?" "1"

# The regression this file exists to prevent: a nexus permanently runs
# `uv tool uvx --from zotero-mcp-server`, whose /proc/<pid>/exe IS `uv`. An
# argv-resemblance predicate adopts it, silences the watchdog, and (on
# 2026-07-09) got the real build reaped on the same match.
zot=$(pgrep -u "$(id -u)" -x uv 2>/dev/null | head -1)
if [[ -n "$zot" ]]; then
    echo "$zot" > "$wd/.jupyter/labsh.bg.pid"
    labsh_build_in_progress "$wd" >/dev/null 2>&1
    check "an unrelated REAL uv process (zotero uvx) is not adopted" "$?" "1"
else
    echo "  SKIP  no unrelated 'uv' process on this host to test against"
fi

rm -f "$wd/.jupyter/labsh.bg.pid"
labsh_build_in_progress "$wd" >/dev/null 2>&1
check "no bg.pid and no scannable build ⇒ fails closed (dead service restartable)" "$?" "1"

labsh_build_in_progress "$TMP/nonexistent" >/dev/null 2>&1
check "missing project dir ⇒ fails closed" "$?" "1"

echo "=== HYGIENE: the suite must not touch LIVE service-health state ==="
# Round 2 caught this, I reported it fixed, and round 3 found it AGAIN — a dead
# test-double pid written into the real jupyterlab record. A fix that regressed
# is worse than one never claimed, so it is now an ASSERTION, not a convention.
if [[ "$(live_fingerprint)" == "$LIVE_BEFORE" ]]; then
    ok "live .buildprogress records unchanged (${#LIVE_DIRS[@]} dir(s) watched, incl. \$NEXUS_ROOT's)"
else
    bad "the suite MODIFIED live service-health state:"
    diff <(printf '%s\n' "$LIVE_BEFORE") <(live_fingerprint) >&2 || true
fi
_leaked=0
for _d in "${LIVE_DIRS[@]}"; do
    compgen -G "$_d/*.buildprogress" >/dev/null 2>&1 && { _leaked=1; echo "    leaked into: $_d" >&2; }
done
if (( _leaked )); then
    bad "a .buildprogress record exists in LIVE state — a fake build marker in production"
else
    ok "no .buildprogress record leaked into any live state dir"
fi

echo
echo "  $pass passed, $fail failed"
(( fail == 0 ))
