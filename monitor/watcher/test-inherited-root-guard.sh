#!/usr/bin/env bash
# test-inherited-root-guard.sh — the INHERITED-NEXUS_ROOT hazard, and the CI
# cell that now enumerates it (your-org/nexus-code#655).
#
# THE HAZARD. Every nexus-spawned agent runs with NEXUS_ROOT exported
# (monitor/spawn-worker.sh). CI ran the band with NEXUS_ROOT UNSET in every
# cell — the three matrix cells plus `clean-env`, which scrubs it explicitly.
# So one whole side of the variable was never exercised, and a suite that
# leaks the ambient root is green in CI and red on every developer's machine.
# That is the "dev red locally / green in CI" half of #655, whose first
# diagnosis blamed the bash 4.4/5.2 boundary and was refuted (both verdicts
# obtained from 4.4.20 with the interpreter held constant).
#
# Three suites were fixed by hand on this variable, each found only because a
# human ran the whole band twice and diffed: test-spawn-worker.sh and
# test-spawn-worker-resume.sh (#706), test-erofs-escalation.sh (#708). The
# third leaks by a DIFFERENT path than the first two and mentions neither
# NEXUS_ROOT nor a fixture, which is why the obvious static sweep ("does it
# build a fixture nexus?") returns 36 files and does not contain it. This
# class cannot be enumerated by reading; it has to be measured.
#
# WHAT THIS FILE ASSERTS. Two things, in the order that matters:
#
#   1. THE MECHANISM, behaviourally, against the REAL monitor/locals-env.sh —
#      that an inherited NEXUS_ROOT front-runs a suite's PATH stub, and that
#      it does so ONLY when the root it names is POPULATED. The second half is
#      not a detail: an EMPTY decoy root does not reproduce the failure at all
#      (measured, 3/3 green, on test-erofs-escalation.sh with its scrub
#      reverted), so a CI cell pointed at an empty directory would be VACUOUS
#      and would look identical to a passing one.
#
#   2. THAT THE CELL EXISTS AND IS POINTED AT A POPULATED ROOT — the workflow
#      job, its NEXUS_ROOT, and its own refusal to run against a root missing
#      the wrapper dirs.
#
# Assertion 1 is what gives assertion 2 teeth. A structural check that a job
# exists would survive the job being silently defanged; the mechanism test
# says what "defanged" means and measures it.
#
# Run: bash monitor/watcher/test-inherited-root-guard.sh
# Expected: ALL TESTS PASSED, exit 0. Hermetic — no tmux, no network, no
# real nexus state; every NEXUS_ROOT below is set explicitly, so this suite
# is insensitive to the ambient one (it must be: it runs inside the very band
# the new cell runs with the variable exported).

set -uo pipefail

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

PASS=0; FAIL=0; SKIP=0

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_dir/../.." && pwd)
LOCALS_ENV="$REPO_ROOT/monitor/locals-env.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/tests.yml"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixtures, composed at RUNTIME.
#
# Deliberately not written as literal files in this repo: a corpus-scanning
# check whose corpus includes its own fixtures records itself (the trap #682's
# manifest fell into — control heredocs holding literal `| head -1` entered the
# manifest twice). Nothing here should ever be findable by a sweep over the
# tree looking for leaky suites.
# ---------------------------------------------------------------------------

# A PATH stub named exactly like the binary locals-env.sh fronts.
STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/sandbox-notify"
chmod +x "$STUB_BIN/sandbox-notify"

# An EMPTY root — a directory that exists and is a plausible NEXUS_ROOT but
# carries none of the wrapper dirs.
EMPTY_ROOT="$WORK/empty-root"
mkdir -p "$EMPTY_ROOT"

# A fixture nexus with its OWN copy of locals-env.sh and no wrapper dirs. This
# is the only place a copy is used, and it is needed for exactly one reason:
# with NEXUS_ROOT unset, locals-env.sh resolves its root from its own location
# (`$(dirname "$BASH_SOURCE")/..`), so sourcing the REAL file would resolve to
# the real repo and could not model a suite whose fixture is elsewhere.
FIXTURE_ROOT="$WORK/fixture-nexus"
mkdir -p "$FIXTURE_ROOT/monitor"
cp "$LOCALS_ENV" "$FIXTURE_ROOT/monitor/locals-env.sh"

# which_notify <locals-env-path> [<NEXUS_ROOT value, or the literal UNSET>]
# Sources the given locals-env.sh with the stub first on PATH and prints
# whatever `sandbox-notify` then resolves to. One helper, three conditions —
# so the three rows cannot drift apart in how they were obtained.
which_notify() {
    local le="$1" root="$2"
    if [[ "$root" == UNSET ]]; then
        env -u NEXUS_ROOT -u NEXUS_LOCALS -u NEXUS_LOCALS_PATH_ONLY \
            bash -c 'PATH="$1:$PATH"; . "$2"; command -v sandbox-notify || echo NONE' \
            _ "$STUB_BIN" "$le" 2>/dev/null
    else
        env -u NEXUS_LOCALS -u NEXUS_LOCALS_PATH_ONLY NEXUS_ROOT="$root" \
            bash -c 'PATH="$1:$PATH"; . "$2"; command -v sandbox-notify || echo NONE' \
            _ "$STUB_BIN" "$le" 2>/dev/null
    fi
}

echo "=== 1. the mechanism: an inherited root front-runs a suite's PATH stub ==="

# A1 — the clean side. Fixture root, no wrapper dirs, NEXUS_ROOT unset: the
# suite's own stub is what runs. This is CI as it stands today, and it is why
# the class has been invisible there.
got=$(which_notify "$FIXTURE_ROOT/monitor/locals-env.sh" UNSET)
assert_eq "NEXUS_ROOT unset + fixture root: the suite's OWN stub wins (today's CI)" \
    "$got" "$STUB_BIN/sandbox-notify"

# A2 — the hazard. Same suite, same stub, one exported variable naming a
# POPULATED root: the real wrapper is fronted ahead of the stub, the stub never
# runs, and any assertion that reads the stub's recorder sees an empty log.
# Nothing about the suite changed.
got=$(which_notify "$FIXTURE_ROOT/monitor/locals-env.sh" "$REPO_ROOT")
assert_eq "NEXUS_ROOT=<populated repo>: the REAL wrapper front-runs the stub" \
    "$got" "$REPO_ROOT/monitor/notifywrap/sandbox-notify"

# A3 — THE VACUITY BOUNDARY, and the reason the CI cell may not point at a
# scratch directory. An empty root fronts nothing, so the stub still wins and
# the hazard does not reproduce. A cell run this way is green for no reason.
got=$(which_notify "$FIXTURE_ROOT/monitor/locals-env.sh" "$EMPTY_ROOT")
assert_eq "NEXUS_ROOT=<EMPTY dir>: hazard does NOT reproduce — decoy must be populated" \
    "$got" "$STUB_BIN/sandbox-notify"

# A4 — the same three rows against the REAL locals-env.sh rather than the copy,
# for the two conditions where NEXUS_ROOT overrides self-location and a copy is
# therefore unnecessary. Guards the copy in A1-A3 from drifting into a test of
# something the shipped file no longer does.
got=$(which_notify "$LOCALS_ENV" "$REPO_ROOT")
assert_eq "REAL locals-env.sh, NEXUS_ROOT=<repo>: fronts the repo's notifywrap" \
    "$got" "$REPO_ROOT/monitor/notifywrap/sandbox-notify"

got=$(which_notify "$LOCALS_ENV" "$EMPTY_ROOT")
assert_eq "REAL locals-env.sh, NEXUS_ROOT=<EMPTY dir>: fronts nothing, stub wins" \
    "$got" "$STUB_BIN/sandbox-notify"

echo
echo "=== 2. the wrapper dirs a populated decoy needs are TRACKED ==="

# The checkout is only a usable decoy because these are in git. If any were
# ever untracked or gitignored, a fresh CI checkout would be an EMPTY root by
# A3's measurement and the cell would go quietly vacuous.
for rel in monitor/ghwrap/gh monitor/notifywrap/sandbox-notify monitor/pipwrap/pip; do
    if git -C "$REPO_ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        printf '  PASS: %s is tracked (a fresh checkout is a POPULATED root)\n' "$rel"
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s is NOT tracked — a CI checkout would be an empty decoy\n' "$rel" >&2
        FAIL=$(( FAIL + 1 ))
    fi
done

echo
echo "=== 3. the CI cell that runs the band on the exported side ==="

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null; then
    th_skip "tests.yml declares a NEXUS_ROOT-exported job" \
            "python3 with PyYAML is unavailable here — the workflow cannot be parsed, so section 3 asserted nothing"
    th_summary_and_exit
fi

# Parse rather than grep: the question is "does some job RUN THE BAND with
# NEXUS_ROOT set to the workspace", which is a fact about the job graph. A
# grep for the string would pass on a mention in a comment — the exact
# spelling-vs-property confusion this repo keeps paying for.
readarray -t probe < <(python3 - "$WORKFLOW" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf.get('jobs') or {}
hits = []
for name, job in jobs.items():
    env = dict(job.get('env') or {})
    steps = job.get('steps') or []
    for st in steps:
        env2 = dict(env); env2.update(st.get('env') or {})
        run = st.get('run') or ''
        if 'NEXUS_ROOT' not in env2:
            continue
        if 'run-tests.sh' not in run:
            continue
        hits.append((name, env2['NEXUS_ROOT'], run))
print(len(hits))
for name, root, run in hits:
    print(name)
    print(root)
    # 1 if the step refuses to proceed on a root missing the wrapper dirs.
    guard = all(d in run for d in ('ghwrap', 'notifywrap', 'pipwrap')) and 'exit 1' in run
    print('1' if guard else '0')
PY
)

n_hits="${probe[0]:-0}"
if [[ "$n_hits" == "0" ]]; then
    printf '  FAIL: no job in tests.yml runs run-tests.sh with NEXUS_ROOT set — the exported side of the variable is untested in CI\n' >&2
    FAIL=$(( FAIL + 1 ))
    th_summary_and_exit
fi
printf '  PASS: %s job(s) run the band with NEXUS_ROOT exported\n' "$n_hits"
PASS=$(( PASS + 1 ))

job_name="${probe[1]:-}"
root_expr="${probe[2]:-}"
has_guard="${probe[3]:-0}"

# The root must be the CHECKOUT. `github.workspace` is the only expression on a
# GitHub runner that names a populated nexus tree; A3 is why anything else
# (a runner temp dir, a bare name) makes the job vacuous.
assert_eq "job '$job_name' points NEXUS_ROOT at the checkout" \
    "$root_expr" '${{ github.workspace }}'

# And it must refuse rather than run vacuously if that ever stops being true.
assert_eq "job '$job_name' refuses to run against a root missing the wrapper dirs" \
    "$has_guard" "1"

th_summary_and_exit
