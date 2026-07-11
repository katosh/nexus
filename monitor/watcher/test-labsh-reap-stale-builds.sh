#!/usr/bin/env bash
# Tests for the evidence-gated labsh build reaper (your-org/nexus-code#467).
#
# The bug: `reap_stale_builds()` (added in #450) decided a labsh cold build was
# stale and killed it, without ever establishing that it was stale. No age
# check, no progress check, no executable-identity check.
#
#   (1) `pgrep -u <uid> -f 'jupyter-lab'` matches on the FULL ARGV, so it
#       selects processes that are not builds. An ordinary agent shell whose
#       command line merely MENTIONS the port and `jupyter-lab` was selected and
#       killed. The `--port $port` guard does not save it — that is also just an
#       argv substring.
#   (2) The bg.pid branch had no port constraint and accepted a bare `*uvx*`.
#       A recycled pid landing on any unrelated `uv tool uvx …` was killed.
#       Long-lived `uvx` processes are routine (the zotero MCP server is one).
#   (3) No age gate, so a build that started seconds ago was indistinguishable
#       from a genuine orphan.
#
# Enumerated LIVE on the node while writing the fix:
#
#   pid   /proc/pid/exe   argv                                     old predicate
#   806   zsh             mentions `jupyter-lab` + `--port 9704`   KILLED (agent shell)
#   21698 uv              `uv tool uvx --from zotero-mcp-server`   KILLED via `*uvx*`
#   5538  uv              `uvx … jupyter-lab --port 9704` 3036s    the real build
#
# This is a LATENT hazard, not the cause of any incident: `reap_stale_builds`'s
# own log lines have ZERO occurrences across a month of labsh-service.log
# (2026-06-10 .. 2026-07-09). It is fixed as the latent hazard it is.
#
# The fix requires POSITIVE EVIDENCE and fails closed: uid match, identity by
# `/proc/<pid>/exe` basename in {uv, uvx} (never an argv substring), our
# `jupyter-lab` + `--port <port>` markers, and age >= LABSH_COLD_BUILD_BUDGET.
#
# HOW THIS IS TESTED WITHOUT KILLING ANYTHING REAL
# ------------------------------------------------
# `_labsh_build_age` is a pure PREDICATE: it inspects /proc and prints an age,
# it never signals. So the decision is testable in isolation, with real
# processes we own and can account for:
#
#   * a `zsh` (a copied bash binary, so exe reports `zsh`) whose ARGV contains
#     `jupyter-lab --port <port>` — the exact shape of the agent-shell false
#     positive: right argv, wrong executable.
#   * a fake `uv` binary (also a copied bash) invoked with a zotero-style argv —
#     exe IS `uv`, but no `--port` and no `jupyter-lab`: the MCP-server false
#     positive that the bare `*uvx*` branch selected.
#   * a fake `uv` invoked with a real build argv — the true build. Tested BOTH
#     fresh (must be spared) and past budget (must be reaped).
#
# Every spawned pid is recorded and killed by that exact pid on exit. No
# `pkill`, no `-f` pattern — a `-f` match here would reap sibling workers and
# this shell.
#
# Assertions:
#   A  agent-shell shape (argv mentions jupyter-lab + our port, exe != uv)
#      is NOT our build.  [the headline false positive]
#   B  LEAK DEMO — the OLD `pgrep -f`/argv predicate DOES select that shell,
#      proving A is load-bearing and not a property it had anyway.
#   C  a foreign `uvx` (zotero shape: exe=uv, no --port) is NOT our build.
#   D  LEAK DEMO — the OLD bare `*uvx*` bg.pid predicate DOES select it.
#   E  a REAL build younger than the budget is our build but NOT stale (spared).
#   F  a REAL build older than the budget IS stale (reaped) — #450's intent
#      is preserved; this is not a fix that simply stops reaping.
#   G  fail closed: a dead pid, a non-numeric pid, and our own $$ are refused.
#   H  reap_stale_builds() itself spares the fresh build and the decoys, and
#      kills only the aged build, when driven end-to-end against real pids.
#
# Run: bash monitor/watcher/test-labsh-reap-stale-builds.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SUP="$_repo_root/monitor/labsh-supervised.sh"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "got [$2] want [$3]"; }

[[ -f "$SUP" ]] || { echo "missing $SUP" >&2; exit 1; }
[[ -r /proc/self/status ]] || { echo "SKIP: /proc unavailable" >&2; exit 0; }
command -v ps >/dev/null || { echo "SKIP: ps unavailable" >&2; exit 0; }

WORK=$(mktemp -d)
KIDS=()
cleanup() {
    local p
    for p in "${KIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---- port safety ----------------------------------------------------------
# THIS SUITE ONCE TOOK DOWN THE OPERATOR'S LIVE JUPYTERLAB. An earlier draft
# spawned fixtures whose argv contained `jupyter-lab --port 9704` — the REAL
# service's port. The live supervisor's `reap_stale_builds` matched a fixture on
# cmdline, killed it as "an orphaned uvx jupyter-lab build", and `labsh start`
# then failed; the watcher read the same resemblance, concluded a cold build was
# in progress, and SUSPENDED auto-restart. A test that reaches out of its
# sandbox and reaps the operator's live service is a defect regardless of what
# it proves.
#
# So: an EPHEMERAL high port, never one a labsh service could own, verified
# unbound before use. Production's predicates are conjunctions requiring
# `--port <the service's port>`, so a port no service owns cannot match one.
# Belt and braces: refuse to run at all if the port is in labsh's range or is
# listening.
_pick_port() {
    local p tries=0
    while (( tries < 50 )); do
        p=$(( 49152 + (RANDOM % 16000) ))       # IANA ephemeral range
        (( p >= 9700 && p <= 9799 )) && { tries=$((tries+1)); continue; }   # labsh range
        if command -v ss >/dev/null 2>&1; then
            ss -ltn 2>/dev/null | grep -qE "[:.]${p}[[:space:]]" && { tries=$((tries+1)); continue; }
        fi
        printf '%s' "$p"; return 0
    done
    return 1
}
PORT=$(_pick_port) || { echo "could not find a free ephemeral port" >&2; exit 1; }
(( PORT >= 49152 && PORT <= 65535 )) || { echo "refusing: port $PORT outside the ephemeral range" >&2; exit 1; }
(( PORT >= 9700 && PORT <= 9799 )) && { echo "refusing: port $PORT is in labsh's range" >&2; exit 1; }
echo "  (fixtures on ephemeral port $PORT — never a labsh service port)"

# The service workdir is a THROWAWAY under $WORK. Identity in the fixed
# predicate is cwd-based, so a fixture whose cwd is this temp dir can never be
# mistaken for a build of the real service, whatever its argv says.
WD="$WORK/project"
mkdir -p "$WD/.jupyter"
BG_PID_FILE="$WD/.jupyter/labsh.bg.pid"
PROJECT_DIR="$WD"
COLD_BUILD_BUDGET=3600        # overridden per-section; never straddles wall-clock
log() { printf '[log] %s\n' "$*" >> "$WORK/log.txt"; }

# ---- lift the REAL predicate + reaper out of the script under test ---------
# labsh-supervised.sh is a `set -uo pipefail` daemon with a top-level main loop,
# so it cannot be sourced. Extract verbatim. `_labsh_build_age` is absent from
# pre-fix source; that is expected, and the leak demos below cover that
# direction by running the OLD predicate explicitly.
EVID="$_repo_root/monitor/_labsh_build_evidence.sh"
[[ -r "$EVID" ]] && source "$EVID"

_reapif_src=$(sed -n '/^_reap_if_stale() {/,/^}/p' "$SUP")
_reap_src=$(sed -n '/^reap_stale_builds() {/,/^}/p' "$SUP")
[[ -n "$_reap_src" ]] || { echo "could not extract reap_stale_builds from $SUP" >&2; exit 1; }
[[ -n "$_reapif_src" ]] && eval "$_reapif_src"
_LABSH_EVIDENCE="$EVID"
_REAP_KILLED=0
eval "$_reap_src"

HAVE_FIX=0
declare -F labsh_build_is_ours >/dev/null && HAVE_FIX=1

# ---- process fixtures -----------------------------------------------------
# The fixtures must control BOTH /proc/<pid>/exe and the argv, independently —
# that separation is the whole point of the fix. Two traps, both hit while
# writing this and both verified before relying on the result:
#
#   1. `sleep 120 jupyter-lab --port 9704` DIES instantly: sleep rejects a
#      non-duration argument. A dead pid would make every assertion vacuous.
#   2. `uv -c 'sleep 120'` leaves exe=`sleep`, NOT `uv`: bash exec()s a lone
#      simple command in place of itself. A trailing `; true` makes it two
#      commands and defeats the optimisation. Without this the fixture silently
#      tests nothing — exactly the "assert a state you never established"
#      failure this issue is about.
#
# So: copy a real `bash` binary to the name we want `exe` to report, and give
# it `-c 'sleep 120; true'` plus the decoy argv.
cp "$(command -v bash)" "$WORK/uv"    # exe basename → uv
cp "$(command -v bash)" "$WORK/zsh"   # exe basename → zsh (an agent shell)
# Short-lived on purpose: if this suite is SIGKILLed its trap never runs, and a
# long-sleeping fixture would outlive it. 25s covers the suite many times over.
_STAY='sleep 25; true'

# Every fixture runs with cwd = the throwaway workdir, which is what makes it
# our build under the fixed predicate — and what makes it impossible for the
# REAL supervisor (whose workdir is elsewhere) to claim it.
spawn() { # <argv...>  → echoes pid, records it for cleanup
    ( cd "$WD" && exec "$@" ) >/dev/null 2>&1 &
    local p=$!
    KIDS+=("$p")
    printf '%s' "$p"
}
# A decoy that must never look like ours: same argv, cwd OUTSIDE the workdir.
spawn_elsewhere() {
    ( cd "$WORK" && exec "$@" ) >/dev/null 2>&1 &
    local p=$!
    KIDS+=("$p")
    printf '%s' "$p"
}

# (a) agent-shell shape: exe is `zsh`; argv MENTIONS jupyter-lab and our port.
SHELL_PID=$(spawn "$WORK/zsh" -c "$_STAY" jupyter-lab --port "$PORT")
# (b) foreign uvx: exe IS `uv`; zotero-style argv, no --port, no jupyter-lab.
ZOTERO_PID=$(spawn "$WORK/uv" -c "$_STAY" tool uvx --from zotero-mcp-server zotero-mcp)
# (c) a REAL build shape: exe `uv`, jupyter-lab, our port, cwd = the workdir.
FRESH_PID=$(spawn "$WORK/uv" -c "$_STAY" tool uvx --from jupyterlab jupyter-lab --port "$PORT" --no-browser)
# (d) an IMPOSTOR: byte-identical argv to (c), but launched from OUTSIDE the
#     workdir. This is the process the old predicate could not tell from (c) —
#     and, on 2026-07-09, the one it killed.
IMPOSTOR_PID=$(spawn_elsewhere "$WORK/uv" -c "$_STAY" tool uvx --from jupyterlab jupyter-lab --port "$PORT" --no-browser)

# Fixtures must be what we claim before any assertion leans on them.
_exe_of() { basename "$(readlink -f "/proc/$1/exe" 2>/dev/null)" 2>/dev/null; }
for _ in $(seq 1 60); do [[ -r "/proc/$IMPOSTOR_PID/cmdline" ]] && break; sleep 0.05; done
[[ "$(_exe_of "$SHELL_PID")"    == zsh ]] || { echo "fixture broken: SHELL_PID exe=$(_exe_of "$SHELL_PID")" >&2; exit 1; }
[[ "$(_exe_of "$ZOTERO_PID")"   == uv  ]] || { echo "fixture broken: ZOTERO_PID exe=$(_exe_of "$ZOTERO_PID")" >&2; exit 1; }
[[ "$(_exe_of "$FRESH_PID")"    == uv  ]] || { echo "fixture broken: FRESH_PID exe=$(_exe_of "$FRESH_PID")" >&2; exit 1; }
[[ "$(_exe_of "$IMPOSTOR_PID")" == uv  ]] || { echo "fixture broken: IMPOSTOR_PID exe=$(_exe_of "$IMPOSTOR_PID")" >&2; exit 1; }

# The OLD predicates, transcribed from the pre-fix source, for the leak demos.
old_pgrep_selects() { # pid port
    local cmd; cmd=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    [[ "$cmd" == *jupyter-lab* && "$cmd" == *"--port $2"* ]]
}
old_bgpid_selects() { # pid
    local cmd; cmd=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    case "$cmd" in *jupyter-lab*|*jupyter_lab*|*uvx*) return 0 ;; esac
    return 1
}

_is_ours() { labsh_build_is_ours "$1" "$WD" "$PORT"; }

# ============================================================
echo '=== A/B: an agent shell that merely MENTIONS jupyter-lab is not a build ==='
# ============================================================
if (( HAVE_FIX )); then
    _is_ours "$SHELL_PID" && bad "A: agent-shell shape is NOT our build" "predicate accepted it" \
                          || ok  "A: agent-shell shape is NOT our build (exe gate rejects it)"
else
    bad "A: agent-shell shape is NOT our build" "pre-fix: no evidence predicate exists"
fi
old_pgrep_selects "$SHELL_PID" "$PORT" \
    && ok  "B: LEAK DEMO — the old argv predicate DOES select the agent shell" \
    || bad "B: LEAK DEMO — old argv predicate selects the agent shell" "it did not; fixture is wrong"

# ============================================================
echo '=== C/D: a foreign uvx (zotero MCP shape) is not a build ==='
# ============================================================
if (( HAVE_FIX )); then
    _is_ours "$ZOTERO_PID" && bad "C: foreign uvx is NOT our build" "predicate accepted it" \
                           || ok  "C: foreign uvx is NOT our build (no jupyter-lab marker)"
else
    bad "C: foreign uvx is NOT our build" "pre-fix: no evidence predicate exists"
fi
old_bgpid_selects "$ZOTERO_PID" \
    && ok  "D: LEAK DEMO — the old bare *uvx* bg.pid predicate DOES select it" \
    || bad "D: LEAK DEMO — old bg.pid predicate selects foreign uvx" "it did not; fixture is wrong"

# ============================================================
echo '=== J: identity, not resemblance — same argv, different cwd, NOT ours ==='
# ============================================================
# This is the 2026-07-09 incident in one assertion. The impostor's argv is
# byte-identical to the real build's. Only cwd distinguishes them.
if (( HAVE_FIX )); then
    _is_ours "$IMPOSTOR_PID" && bad "J: impostor with identical argv is NOT ours" "predicate accepted it" \
                             || ok  "J: impostor with identical argv is NOT ours (cwd gate)"
    _is_ours "$FRESH_PID"    && ok  "J: the real build IS ours (same argv, right cwd)" \
                             || bad "J: the real build IS ours" "predicate rejected the genuine build"
else
    bad "J: impostor with identical argv is NOT ours" "pre-fix: no cwd gate exists"
fi
old_pgrep_selects "$IMPOSTOR_PID" "$PORT" \
    && ok  "J: LEAK DEMO — the old argv predicate cannot tell them apart" \
    || bad "J: LEAK DEMO — old argv predicate selects the impostor" "it did not; fixture is wrong"

# ============================================================
echo '=== E/F: age decides. Fresh build spared; aged build reaped (#450 intent kept) ==='
# ============================================================
if (( HAVE_FIX )); then
    # Never let the budget straddle this suite's own wall-clock: with a small
    # budget a slow section ages FRESH_PID past it and "spared" flakes — a test
    # asserting a state it did not establish, this issue's defect in a lab coat.
    COLD_BUILD_BUDGET=3600
    age=$(labsh_build_age "$FRESH_PID"); rc=$?
    assert_eq "E: age is readable for a real build (rc 0)" "$rc" "0"
    [[ "$age" =~ ^[0-9]+$ ]] && ok "E: predicate reports a numeric age (${age}s)" \
                             || bad "E: numeric age" "got [$age]"
    labsh_build_is_stale "$FRESH_PID" "$WD" "$PORT" "$COLD_BUILD_BUDGET" \
        && bad "E: fresh build is NOT stale" "declared stale at ${age}s < ${COLD_BUILD_BUDGET}s" \
        || ok  "E: fresh build is NOT stale (age < budget)"

    _REAP_KILLED=0
    _reap_if_stale "$FRESH_PID" "$PORT" "test" \
        && bad "E: fresh build is SPARED" "it was reaped" \
        || ok  "E: fresh build is SPARED"
    kill -0 "$FRESH_PID" 2>/dev/null && ok "E: fresh build still alive" || bad "E: fresh build still alive" "killed"

    # Budget 0 is satisfied by any age >= 0: no dependence on elapsed time.
    COLD_BUILD_BUDGET=0
    labsh_build_is_stale "$FRESH_PID" "$WD" "$PORT" 0 \
        && ok  "F: a build past the budget IS stale" \
        || bad "F: aged build is stale" "declared fresh"
    _REAP_KILLED=0
    _reap_if_stale "$FRESH_PID" "$PORT" "test" \
        && ok  "F: a build past the budget IS reaped (#450's intent preserved)" \
        || bad "F: aged build is reaped" "it was spared"
    for _ in $(seq 1 60); do kill -0 "$FRESH_PID" 2>/dev/null || break; sleep 0.05; done
    kill -0 "$FRESH_PID" 2>/dev/null && bad "F: aged build actually died" "still alive" \
                                     || ok  "F: aged build actually died"
    # An impostor past the budget is STILL not reaped — age never rescues a
    # failed identity check.
    labsh_build_is_stale "$IMPOSTOR_PID" "$WD" "$PORT" 0 \
        && bad "F: impostor is never stale" "declared stale" \
        || ok  "F: impostor is never stale, at any age"
    COLD_BUILD_BUDGET=3600
else
    bad "E: fresh build is SPARED" "pre-fix: no age gate exists at all"
    bad "F: aged build is reaped"  "pre-fix: no age gate exists at all"
fi

# ============================================================
echo '=== G: fail closed on anything unestablished ==='
# ============================================================
if (( HAVE_FIX )); then
    DEAD=$(spawn "$WORK/uv" -c 'true'); sleep 0.3
    _is_ours "$DEAD"       && bad "G: dead pid refused" "accepted"        || ok "G: dead pid refused"
    _is_ours "not-a-pid"   && bad "G: non-numeric pid refused" "accepted" || ok "G: non-numeric pid refused"
    _is_ours "$$"          && bad "G: own pid refused" "accepted"         || ok "G: own pid refused"
    _is_ours 1             && bad "G: pid 1 refused (uid gate)" "accepted"|| ok "G: pid 1 refused (uid gate)"
    # A budget we cannot parse is a budget we have not established.
    labsh_build_is_stale "$ZOTERO_PID" "$WD" "$PORT" "" 2>/dev/null \
        && bad "G: non-numeric budget refused" "accepted" || ok "G: non-numeric budget refused"
    # ...and an empty workdir can never identify anything.
    labsh_build_is_ours "$ZOTERO_PID" "" "$PORT" 2>/dev/null \
        && bad "G: empty workdir refused" "accepted" || ok "G: empty workdir refused"
else
    bad "G: fail closed" "pre-fix: no predicate to fail closed"
fi

# ============================================================
echo '=== H: reap_stale_builds() end-to-end spares decoys, kills only the orphan ==='
# ============================================================
FRESH2=$(spawn "$WORK/uv" -c "$_STAY" tool uvx --from jupyterlab jupyter-lab --port "$PORT" --no-browser)
for _ in $(seq 1 60); do [[ -r "/proc/$FRESH2/cmdline" ]] && break; sleep 0.05; done
printf '%s' "$FRESH2" > "$BG_PID_FILE"

if (( HAVE_FIX )); then
    COLD_BUILD_BUDGET=3600      # nothing is an orphan by this budget
    reap_stale_builds "$PORT" >/dev/null 2>&1
    kill -0 "$FRESH2"       2>/dev/null && ok "H: fresh bg.pid build survives a reap pass" || bad "H: fresh bg.pid build survives" "killed"
    kill -0 "$SHELL_PID"    2>/dev/null && ok "H: agent shell survives a reap pass"        || bad "H: agent shell survives" "killed"
    kill -0 "$ZOTERO_PID"   2>/dev/null && ok "H: foreign uvx survives a reap pass"        || bad "H: foreign uvx survives" "killed"
    kill -0 "$IMPOSTOR_PID" 2>/dev/null && ok "H: impostor survives a reap pass"           || bad "H: impostor survives" "killed"

    COLD_BUILD_BUDGET=0
    reap_stale_builds "$PORT" >/dev/null 2>&1
    for _ in $(seq 1 60); do kill -0 "$FRESH2" 2>/dev/null || break; sleep 0.05; done
    kill -0 "$FRESH2" 2>/dev/null && bad "H: orphan past budget is reaped" "survived" || ok "H: orphan past budget is reaped"
    kill -0 "$SHELL_PID"    2>/dev/null && ok "H: agent shell STILL survives the orphan sweep" || bad "H: agent shell survives sweep" "killed"
    kill -0 "$ZOTERO_PID"   2>/dev/null && ok "H: foreign uvx STILL survives the orphan sweep" || bad "H: foreign uvx survives sweep" "killed"
    kill -0 "$IMPOSTOR_PID" 2>/dev/null && ok "H: impostor STILL survives the orphan sweep"    || bad "H: impostor survives sweep" "killed"
else
    bad "H: reap_stale_builds spares decoys" "pre-fix: unconditional argv-matched kill"
fi

# ============================================================
echo '=== I: contract — the reaper reasons from /proc evidence, not from argv greps ==='
# ============================================================
# Structural, and it flips direction: FAILS on pre-fix source, PASSES after.
#
# Note what this suite deliberately does NOT do: it never drives the PRE-FIX
# `reap_stale_builds` end-to-end. That function sweeps the whole system with
# `pgrep -u <uid> -f jupyter-lab` and kills every match, so running it here would
# kill the real labsh build and any agent shell whose command line mentions
# jupyter-lab — on this very node. That it cannot be safely executed IS the bug,
# and on 2026-07-09 an earlier draft of this very file proved it the hard way.
# B, D and J therefore demonstrate the pre-fix DECISION (which pids it selects)
# without ever executing the kill.
_reaper_body=$(sed -n '/^reap_stale_builds() {/,/^}/p' "$SUP" | grep -vE '^\s*#')
grep -q 'pgrep' <<<"$_reaper_body" \
    && bad "I: reaper does not use pgrep (argv matching)" "pgrep still present" \
    || ok  "I: reaper does not use pgrep (argv matching)"
grep -q 'labsh_build_is_ours\|labsh_build_scan\|_reap_if_stale' <<<"$_reaper_body" \
    && ok  "I: reaper routes every kill through the shared evidence predicate" \
    || bad "I: reaper routes every kill through the shared evidence predicate" "no predicate call"
grep -qE '\*uvx\*' <<<"$_reaper_body" \
    && bad "I: no bare *uvx* match survives" "bare *uvx* glob still selects foreign processes" \
    || ok  "I: no bare *uvx* match survives"

# The watcher's cold-build predicate must use the SAME shared helper — one
# question, one answer, opposite polarity (nexus-code#465 extended).
_sh_body=$(sed -n '/^_sh_labsh_build_in_progress() {/,/^}/p' "$_repo_root/monitor/watcher/_service_health.sh" | grep -vE '^\s*#')
grep -q 'pgrep' <<<"$_sh_body" \
    && bad "I: watcher predicate does not use pgrep" "pgrep still present at _service_health.sh" \
    || ok  "I: watcher predicate does not use pgrep"
grep -q 'labsh_build_is_ours\|labsh_build_scan' <<<"$_sh_body" \
    && ok  "I: watcher predicate uses the SAME shared evidence helper" \
    || bad "I: watcher predicate uses the shared helper" "not wired"
grep -qE '\*uvx\*' <<<"$_sh_body" \
    && bad "I: watcher predicate drops the bare *uvx* arm" "still present" \
    || ok  "I: watcher predicate drops the bare *uvx* arm"

# ============================================================
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d assertions)\n' "$PASS"
    exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2
    exit 1
fi
