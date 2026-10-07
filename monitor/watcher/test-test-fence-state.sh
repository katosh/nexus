#!/usr/bin/env bash
# test-test-fence-state.sh — a suite or mutation run from a tree nested under a
# nexus's work/ writes NOTHING into that nexus's state (your-org/nexus-code#1680).
#
# THE DEFECT. #577 taught the primary-root resolvers (monitor/_nexus-root.sh
# `nexus_primary_root`, and spawn-worker.sh's own walk) that a nexus tree nested
# under another nexus's `work/` is a secondary clone whose STATE belongs to the
# enclosing primary. Right for a worker; wrong for a hermetic tree. A fixture
# nexus built by `mktemp -d` sits under `work/` whenever its TMPDIR does, and
# mutation-gate.sh put the suite's TMPDIR at `<--workdir>/tmp` (#1601): with a
# --workdir under work/rmsk-band, the resume suite's fixture spawns re-rooted
# onto the operator's primary and appended their spawn rows to its production
# action log — 321 rows, window names res-win / stamp-win / other-name. The same
# walk made the gate's tree COPY take the primary's identity, so every baseline
# was red and no mutant was exercised.
#
# THE FIX. Each harness exports NEXUS_TEST_FENCE=<its scratch root>
# (run-tests.sh: the per-suite private root; mutation-gate.sh: --workdir;
# _test_helpers.sh, for a suite run standalone: TMPDIR). Under a fence neither
# resolver re-roots onto a root OUTSIDE it. Fixture primaries INSIDE the fence
# (what the #577 suites build) still de-nest, and without a fence (a worker)
# nothing changes.
#
# CASES, each through the REAL harness entry point:
#   A. mutation-gate.sh --run-bounded, --workdir under a fake primary's work/,
#      running a payload that spawns from a `mktemp -d` fixture nexus — the
#      incident, replayed. Positive control: the fixture's OWN log got the row.
#   B. run-tests.sh running a planted suite that lives IN a clone nested under
#      the fake primary's work/ and resolves its root in place.
#   C. the same planted suite run standalone, sourcing _test_helpers.sh.
#   D. spawn-worker.sh's INHERITED-NEXUS_ROOT arm (the July rows' mechanism).
#   E. #577 kept: no fence -> primary; fence containing both -> primary;
#      unresolvable fence -> the tree itself (fail-closed).
#
# The fake primary is built in this suite's own mktemp dir; the real primary is
# never named, read or written.
#
# Run: bash monitor/watcher/test-test-fence-state.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_test_dir/.." && pwd)
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"

# The five harness/resolver files whose disagreement IS the leak: the two
# resolvers that de-nest, and the three harnesses that must fence them.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$MON/_nexus-root.sh" "$MON/spawn-worker.sh" "$MON/mutation-gate.sh" \
        "$MON/watcher/run-tests.sh" "$MON/watcher/_test_helpers.sh"
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-1680-XXXXXX) || { echo "mktemp failed" >&2; exit 97; }
WORK=$(cd "$WORK" && pwd -P)
th_trap_exit 'rm -rf "$WORK"'
export MON WORK

# --- shared fixture library: defined HERE, written out for the payloads ------
# Defined in the suite itself (not in a heredoc that is then sourced) so the
# #922 undefined-helper lint can see the definition; the payloads source the
# `declare -f` copy.
# make_nexus <root> — a nexus tree spawn-worker.sh and ng can run in (the
# layout test-secondary-clone-state.sh builds).
make_nexus() {
    local root="$1" f
    mkdir -p "$root/monitor/.state" "$root/monitor/watcher" "$root/config" \
             "$root/reports" "$root/work" \
             "$root/skills/nexus.worker-defaults" "$root/node_modules/.bin"
    for f in spawn-worker.sh guard-block.sh.in ng _claude-bin.sh _tmux-window.sh \
             _fm_lib.sh _bookkeeping.sh _nexus-root.sh; do
        cp "$MON/$f" "$root/monitor/$f" || return 1
    done
    chmod +x "$root/monitor/spawn-worker.sh" "$root/monitor/ng"
    printf '#!/bin/bash\necho "stub-claude: $*"\n' > "$root/node_modules/.bin/claude"
    chmod +x "$root/node_modules/.bin/claude"
    printf '{ "hooks": {} }\n' > "$root/monitor/worker-settings.json"
    printf -- '---\ndescription: stub\n---\n\n## Worker floor\n\n- stub.\n' \
        > "$root/skills/nexus.worker-defaults/SKILL.md"
    cat > "$root/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)       printf 'default-org/default-repo' ;;
    github.user_login) printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$root/config/load.sh"
}
LIB="$WORK/lib.sh"
declare -f make_nexus > "$LIB" || th_abort "could not write the fixture library"

STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<'STUB'
#!/bin/bash
case "$1" in new-window) echo '@7'; exit 0 ;; *) exit 0 ;; esac
STUB
chmod +x "$STUB_BIN/tmux"
export STUB_BIN
export FAKE_HOME="$WORK/home"; mkdir -p "$FAKE_HOME"
printf 'do the thing\n' > "$WORK/prompt.txt"

# THE FAKE PRIMARY whose state must stay empty.
FP="$WORK/fp"
make_nexus "$FP" || th_abort "could not build the fake primary"
fp_state_files() { find "$FP/monitor/.state" -type f 2>/dev/null | sed "s|^$FP/||" | sort; }
assert_empty "precondition: the fake primary's .state starts empty" "$(fp_state_files)"

echo '=== A. mutation-gate --workdir under <primary>/work: the incident, replayed ==='
cat > "$WORK/payload-spawn.sh" <<'PAYLOAD'
#!/usr/bin/env bash
# A suite's fixture: a nexus under `mktemp -d` (so under the gate's TMPDIR),
# spawning one worker with stub tmux, exactly as the resume suite does.
set -u
. "$WORK/lib.sh"
F=$(mktemp -d) || exit 3
F="$F/nexus"; make_nexus "$F" || exit 3
mkdir -p "$F/work/proj"
( cd "$F" && env -u NEXUS_ROOT -u NEXUS_STATE_DIR PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
    "$F/monitor/spawn-worker.sh" -n fence-win -c "$F/work/proj" -p "$WORK/prompt.txt" ) \
    >/dev/null 2>"$WORK/payload-spawn.err"
echo "spawn-rc=$?"
echo "own-rows=$(grep -c '"event":"spawn"' "$F/monitor/.state/action-log.jsonl" 2>/dev/null)"
exit 0
PAYLOAD
WD="$FP/work/mut/wd"
mkdir -p "$WD"
env -u NEXUS_TEST_FENCE -u NEXUS_ROOT -u NEXUS_STATE_DIR \
    bash "$MON/mutation-gate.sh" --run-bounded "$WORK/payload-spawn.sh" --workdir "$WD" \
    >"$WORK/mg.out" 2>"$WORK/mg.err"
mg_rc=$?
assert_rc "mutation-gate ran the payload to completion" "$mg_rc" 0
bout=$(cat "$WD/bounded.out" 2>/dev/null)
assert_contains "the fixture spawn itself succeeded" "$bout" "spawn-rc=0"
# POSITIVE CONTROL: the spawn DID log a row — into the fixture's own state.
# Without it an empty fake primary proves nothing (a spawn that never ran).
own=$(sed -n 's/^own-rows=//p' <<<"$bout")
[[ "$own" =~ ^[1-9][0-9]*$ ]] && own_ok=yes || own_ok="no (own-rows=${own:-<none>})"
assert_eq "the fixture's OWN action log holds the spawn row" "$own_ok" yes
assert_empty "NOTHING was written into the enclosing primary's .state" "$(fp_state_files)"
assert_contains "the refused re-root is LOUD, naming the fence" \
    "$(cat "$WORK/payload-spawn.err" 2>/dev/null)" "outside NEXUS_TEST_FENCE"
rm -rf "$FP/monitor/.state"; mkdir -p "$FP/monitor/.state"

# A planted suite that lives IN a clone nested under the fake primary and does
# what an in-place helper does: resolve its primary, and write state there.
C="$FP/work/clone"
make_nexus "$C" || th_abort "could not build the nested clone"
plant_probe() {   # plant_probe <file> [helpers-to-source]
    {
        printf '#!/usr/bin/env bash\nset -u\n'
        [[ -n "${2:-}" ]] && printf '. %q\n' "$2"
        printf '. %q\n' "$C/monitor/_nexus-root.sh"
        printf 'r=$(nexus_primary_root %q)\n' "$C"
        printf 'echo "probe-row" >> "$r/monitor/.state/probe.log"\n'
        printf 'echo "resolved=$r"\n'
        printf 'echo "  PASS: probe ran"\necho "=== summary: 1 passed, 0 failed ==="\necho "ALL TESTS PASSED"\n'
    } > "$1"
    chmod +x "$1"
}

echo '=== B. run-tests.sh, suite in a clone nested under <primary>/work ==='
plant_probe "$C/monitor/watcher/test-fence-probe.sh"
env -u NEXUS_TEST_FENCE -u NEXUS_ROOT -u NEXUS_STATE_DIR \
    bash "$MON/watcher/run-tests.sh" --keep-logs "$WORK/rt-logs" \
    "$C/monitor/watcher/test-fence-probe.sh" >"$WORK/rt.out" 2>"$WORK/rt.err"
rt_rc=$?
assert_rc "run-tests ran the planted suite green" "$rt_rc" 0
# find, not a bare `cat <glob>`: an unmatched glob must not leave `cat` reading stdin.
rt_log=$(find "$WORK/rt-logs" -name '*fence-probe*.out' -exec cat {} + 2>/dev/null)
assert_contains "the planted suite resolved to its OWN tree" "$rt_log" "resolved=$C"
assert_empty "run-tests: NOTHING in the enclosing primary's .state" "$(fp_state_files)"
rm -rf "$FP/monitor/.state"; mkdir -p "$FP/monitor/.state"

echo '=== C. the same suite standalone, sourcing _test_helpers.sh ==='
plant_probe "$C/monitor/watcher/test-fence-probe2.sh" "$MON/watcher/_test_helpers.sh"
mkdir -p "$WORK/standalone-tmp"
c_out=$(env -u NEXUS_TEST_FENCE -u NEXUS_ROOT -u NEXUS_STATE_DIR TMPDIR="$WORK/standalone-tmp" \
    bash "$C/monitor/watcher/test-fence-probe2.sh" 2>&1)
assert_contains "standalone: resolved to its OWN tree" "$c_out" "resolved=$C"
assert_empty "standalone: NOTHING in the enclosing primary's .state" "$(fp_state_files)"
rm -rf "$FP/monitor/.state"; mkdir -p "$FP/monitor/.state"

echo '=== D. spawn-worker: an INHERITED NEXUS_ROOT outside the fence ==='
launcher_root() {   # launcher_root <name> <env…> -> the NEXUS_ROOT the launcher exports
    local name="$1"; shift
    mkdir -p "$WORK/sw-tmp"
    ( cd "$C" && env -u NEXUS_STATE_DIR "$@" TMPDIR="$WORK/sw-tmp" PATH="$STUB_BIN:$PATH" HOME="$FAKE_HOME" \
        "$C/monitor/spawn-worker.sh" -n "$name" -c "$C" -p "$WORK/prompt.txt" \
        >/dev/null 2>"$WORK/sw.err" ) || true
    # First match only, without a pipe into an early-exit reader (#622).
    sed -n '/^export NEXUS_ROOT="\(.*\)"$/{s//\1/p;q;}' "$WORK/sw-tmp/spawn-launcher-$name".*.sh 2>/dev/null </dev/null
    rm -f "$WORK/sw-tmp/spawn-launcher-$name".*.sh
}
got=$(launcher_root inh-out NEXUS_ROOT="$FP" NEXUS_TEST_FENCE="$C")
assert_eq "inherited primary OUTSIDE the fence is refused" "$got" "$C"
assert_contains "…loudly" "$(cat "$WORK/sw.err")" "REFUSING the inherited NEXUS_ROOT"
assert_empty "…and the primary's .state stays empty" "$(fp_state_files)"
rm -rf "$FP/monitor/.state"; mkdir -p "$FP/monitor/.state"

echo '=== E. #577 kept: workers, and fixtures inside the fence ==='
got=$(env -u NEXUS_TEST_FENCE bash -c '. "$1"; nexus_primary_root "$2"' _ "$MON/_nexus-root.sh" "$C")
assert_eq "no fence (a worker): the clone de-nests to its primary" "$got" "$FP"
got=$(NEXUS_TEST_FENCE="$WORK" bash -c '. "$1"; nexus_primary_root "$2"' _ "$MON/_nexus-root.sh" "$C")
assert_eq "fence containing primary AND clone: de-nests as before" "$got" "$FP"
got=$(NEXUS_TEST_FENCE="$WORK/no-such-dir" bash -c '. "$1"; nexus_primary_root "$2"' _ "$MON/_nexus-root.sh" "$C")
assert_eq "unresolvable fence: fail-closed, no de-nesting" "$got" "$C"
got=$(launcher_root inh-in NEXUS_ROOT="$FP" NEXUS_TEST_FENCE="$WORK")
assert_eq "spawn-worker: inherited primary INSIDE the fence still wins" "$got" "$FP"
got=$(launcher_root structural NEXUS_ROOT= NEXUS_TEST_FENCE="$WORK")
assert_eq "spawn-worker: structural detection inside the fence still re-roots" "$got" "$FP"

# ---- assertion-count guard -------------------------------------------------
_EXPECTED_ASSERTIONS=19
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
