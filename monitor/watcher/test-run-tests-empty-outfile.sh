#!/usr/bin/env bash
# A FAILED mktemp MUST NOT BECOME SEVEN DOTFILES IN THE USER'S WORKING TREE.
# (your-org/nexus-code#857)
#
# WHY THIS FILE EXISTS. `run_one` writes every sidecar and log as
# `"$out_file.<kind>"`. Both dispatch sites used to inline `$(mktemp …)` into
# the argument list unchecked, and a command substitution that fails collapses
# to the EMPTY STRING rather than erroring. `run_one` then received an empty
# base, and `.caseskipped` / `.nocount` / `.zerocount` / `.assertions` /
# `.failed` / `.timedout` / `.out` / `.err` were created as RELATIVE paths in
# whatever directory was current — the repo root, in practice.
#
# Every property of that failure is bad in the same direction: the files are
# dotfiles so no casual listing shows them, they persist after the run, and a
# `git add -A` sweeps them into a commit that no diff reviewer flags. `#850`
# committed seven of them and pushed one commit before anyone noticed; they
# were found by a `git ls-files` run for an unrelated reason.
#
# THE ASSERTION THAT MATTERS is the NEGATIVE one — that the working tree is
# still clean afterwards. A test that only checked the exit code would pass
# against a version that refuses loudly AND still writes the files, which is
# precisely the shape of bug being fixed: the loud part and the harmful part
# are independent.
#
# Run: bash monitor/watcher/test-run-tests-empty-outfile.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
RUNNER="$_test_dir/run-tests.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$RUNNER"; }
gp_handle "$@"

[[ -x "$RUNNER" || -r "$RUNNER" ]] || { echo "missing runner: $RUNNER" >&2; exit 2; }

# The eight names run_one derives from its base. Kept as data so a new sidecar
# kind added to run_one without updating this list shows up as an uncovered
# name rather than as a silent gap.
SIDECARS=( .caseskipped .nocount .zerocount .assertions .failed .timedout .out .err )

WORK=$(mktemp -d) || { echo "FAIL: mktemp for the fixture"; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# ── the shim: mktemp -p FAILS, mktemp -d SUCCEEDS ───────────────────────
# Scoped deliberately. `run-tests.sh` also mktemp -d's its own run_dir at
# startup; a shim that failed everything would abort before reaching the code
# under test, and the suite would pass for the wrong reason.
mkdir -p "$WORK/bin"
# RESOLVE the real mktemp; do NOT hardcode /usr/bin/mktemp. On this host it is
# `/bin/mktemp` and `/usr/bin/mktemp` does not exist, so the hardcoded form
# exec'd into rc 127 — the shim then failed EVERY call, the runner died before
# reaching the code under test, and the probes below passed for a reason that
# had nothing to do with the fix. The `mktemp -d` control is what caught it.
# Same trap CLAUDE.md records for `/usr/bin/grep`.
REAL_MKTEMP=$(command -v mktemp) \
    || { echo "FAIL: cannot resolve a real mktemp to shim" >&2; exit 1; }
{
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do'
    echo '    if [[ "$a" == "-p" ]]; then'
    echo '        echo "mktemp: (fixture) refusing -p" >&2'
    echo '        exit 1'
    echo '    fi'
    echo 'done'
    printf 'exec %q "$@"\n' "$REAL_MKTEMP"
} >"$WORK/bin/mktemp"
chmod +x "$WORK/bin/mktemp"

# Sanity-control the shim itself before trusting a result that depends on it.
# A shim that silently did nothing would make every assertion below vacuous.
( cd "$WORK" && PATH="$WORK/bin:$PATH" mktemp -p "$WORK" out-XXXXXX >/dev/null 2>&1 )
assert_eq "CONTROL: the fixture shim makes 'mktemp -p' fail" "$?" "1"
( cd "$WORK" && PATH="$WORK/bin:$PATH" mktemp -d >/dev/null 2>&1 )
assert_eq "CONTROL: …and leaves 'mktemp -d' working, so the runner still starts" "$?" "0"

# A trivial passing test for the runner to dispatch.
mkdir -p "$WORK/suite" "$WORK/cwd"
cat >"$WORK/suite/test-trivial.sh" <<'T'
#!/usr/bin/env bash
echo "=== summary: 1 passed, 0 failed ==="
echo "ALL TESTS PASSED"
exit 0
T
chmod +x "$WORK/suite/test-trivial.sh"

# ── the probe ───────────────────────────────────────────────────────────
# Run from a DEDICATED empty cwd, never the repo, so a regression cannot
# scribble into the tree this suite is checking.
probe() {   # <jobs> -> echoes "<rc>|<stray-count>|<output>"
    local jobs="$1" rc out stray=0 s
    rm -f "$WORK/cwd"/.* 2>/dev/null
    out=$( cd "$WORK/cwd" && PATH="$WORK/bin:$PATH" \
             bash "$RUNNER" --jobs "$jobs" "$WORK/suite/test-trivial.sh" 2>&1 )
    rc=$?
    for s in "${SIDECARS[@]}"; do
        [[ -e "$WORK/cwd/$s" ]] && stray=$(( stray + 1 ))
    done
    printf '%s|%s|%s' "$rc" "$stray" "$out"
}

# ── SERIAL (jobs=1) ─────────────────────────────────────────────────────
res=$(probe 1)
rc="${res%%|*}"; rest="${res#*|}"; stray="${rest%%|*}"; out="${rest#*|}"

assert_eq "SERIAL: no sidecar dotfile is created in the caller's cwd" "$stray" "0"
[[ "$rc" != "0" ]] && _th_pass || _th_fail
printf '  %s: SERIAL: the run does not report success on a broken run_dir (rc=%s)\n' \
    "$( [[ "$rc" != 0 ]] && echo PASS || echo FAIL )" "$rc"
assert_contains "SERIAL: …and says why, naming the directory it refused to write to" \
    "$out" "Refusing to write sidecars into"

# ── PARALLEL (jobs=2) ───────────────────────────────────────────────────
# The arm that actually shipped the bug: the substitution runs inside the
# xargs child, so the empty base was produced one process away from the check.
res=$(probe 2)
rc="${res%%|*}"; rest="${res#*|}"; stray="${rest%%|*}"; out="${rest#*|}"

assert_eq "PARALLEL: no sidecar dotfile is created in the caller's cwd" "$stray" "0"
assert_contains "PARALLEL: the child reports the failure rather than absorbing it" \
    "$out" "mktemp failed"

# ── run_one's own guard, driven directly ────────────────────────────────
# The call sites are checked above; this pins the funnel itself, which is what
# protects a caller nobody has written yet.
# The runner is not sourceable, so assert the guard textually: a refusal that
# exists only in prose is exactly what this repo keeps paying for. (An earlier
# draft tried `. "$1"` here to drive run_one directly; that never worked, and
# its dead `. "$1"` was an UNRESOLVABLE source token that reddened
# test-ambient-shell-option-scope's graph manifest. Removed rather than
# manifested — a manifest row for dead code is a row nobody can ever retire.)
# _occurrences <pattern> <file> — OCCURRENCES, not lines (your-org/nexus-code
# `#1026`). `grep -c` counts matching LINES, so two constructs sharing one line
# read as 1 and an `== N` assertion stays green with the construct duplicated.
# `-F` because every caller passes a LITERAL. On no match grep prints nothing
# and exits 1, yielding 0 — a replacement, never an appended second value, so
# no `|| echo 0` belongs here (your-org/nexus-code#725).
_occurrences() { grep -oF -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }

assert_eq "run_one carries an explicit empty-base refusal (not just call-site checks)" \
    "$(_occurrences 'EMPTY out_file base for' "$RUNNER")" "1"

# ── the tree this suite is about ────────────────────────────────────────
# The strongest available end-to-end statement: after both probes, the REPO
# ROOT still has none of the eight names. Cheap, and it is the exact condition
# whose violation reached a pushed commit in #850.
repo_stray=0
for s in "${SIDECARS[@]}"; do
    [[ -e "$REPO_ROOT/$s" ]] && repo_stray=$(( repo_stray + 1 ))
done
assert_eq "the repo root carries none of the eight sidecar names" "$repo_stray" "0"

EXPECTED=9
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
