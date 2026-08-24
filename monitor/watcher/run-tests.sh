#!/usr/bin/env bash
# Convenience runner for the watcher test suite. Purely additive —
# direct `bash monitor/watcher/test-X.sh` keeps working.
#
# Usage:
#   monitor/watcher/run-tests.sh                # all tests, serial
#   monitor/watcher/run-tests.sh --jobs 4       # parallel
#   monitor/watcher/run-tests.sh --filter idle  # only files matching
#   monitor/watcher/run-tests.sh --list         # list, do not run
#   monitor/watcher/run-tests.sh --profile      # print per-file wall-time
#   monitor/watcher/run-tests.sh --failed-only  # re-run last run's failures
#   monitor/watcher/run-tests.sh --keep-logs DIR # persist per-test stdout/stderr
#   monitor/watcher/run-tests.sh --timeout 600  # hard per-test ceiling; rc=124
#                                               # tallied + printed as TIMEOUT
#                                               # (never a pass, never omitted)
#   monitor/watcher/run-tests.sh --state F --resume --max-seconds 480
#                                               # bounded, RESUMABLE run: tally
#                                               # appended to F after each test,
#                                               # --resume skips already-recorded
#                                               # tests, --max-seconds stops
#                                               # cleanly between tests (exit 3 +
#                                               # a resume hint). Repeat the same
#                                               # command until it exits 0 (all
#                                               # accounted, green) or 1 (red).
#   monitor/watcher/run-tests.sh path/to/test.sh ...  # explicit paths
#
# WHY bounded+resumable (your-org/nexus-code#499): the suite outgrew any
# single bounded invocation (~175 tests, dozens exceeding a 10-minute
# tool ceiling), so "ran the full suite" had quietly become unestablishable
# — no runner finished. The state tsv (path<TAB>status<TAB>wall) is the
# honest ledger: every selected test terminates as pass, FAIL, or TIMEOUT,
# and the summary refuses to read green while anything is unaccounted for.
# Canonical full-suite drive:
#   SLOW_TESTS=1 RUN_INTEGRATION=1 env -u NEXUS_ROOT -u NEXUS_LOCALS \
#     monitor/watcher/run-tests.sh --timeout 600 \
#       --state /tmp/suite-$(git rev-parse --short HEAD).tsv \
#       --resume --max-seconds 480      # repeat until exit != 3
#
# Slow tests opt out of the default fast loop. They self-skip when
# SLOW_TESTS is unset (printing "skipped: …"), and run normally when
# SLOW_TESTS=1 is exported. CI / pre-push hooks should set
# `SLOW_TESTS=1`; the fast iteration loop runs without it. Slow
# tests are tagged with "(slow)" in `--list` output.
#
# Integration tests live under `test-integration/` (real tmux server
# + stubbed claude shim; see test-integration/README.md). They self-
# skip when RUN_INTEGRATION is unset, matching the SLOW_TESTS
# pattern but on a separate axis so a pre-push hook can opt into
# unit-slow tests without paying the tmux bring-up cost on every
# push. Tagged "(integration)" in `--list`.
#
# Exit codes: 0 = every selected test terminated as PASS or SKIP; 1 = at least
# one FAIL or TIMEOUT; 3 = incomplete (--max-seconds budget hit; resume).
#
# STATUSES: PASS · SKIP · FAIL · TIMEOUT. A test that DECLINES TO RUN exits 77
# and is tallied SKIP (your-org/nexus-code#568 A6). Before that third state
# existed, `status=PASS` whenever rc==0 meant every self-skipping test counted
# as a pass, and three of them printed the literal `ALL TESTS PASSED` after
# zero checks — so "the suite is green" was not a coverage claim and nothing
# in the output said so. SKIP does not turn the run red; it is reported
# separately, and the summary states outright how much of the selection
# produced no evidence.
#
# State file: ~/.cache/nexus-test-runner/last-failures.txt
# (overrideable via $NEXUS_TEST_STATE_DIR).

set -uo pipefail

# The unit/integration suite runs OUTSIDE the agent-sandbox by design
# (developer shells, CI on ubuntu-latest). The sandbox gate added in
# your-org/nexus-code#350 makes launcher.sh / entry.sh REFUSE to spawn a
# watcher outside the sandbox unless acceptance is declared — which would
# otherwise break every test that performs a real launcher→main.sh spawn.
# Declaring acceptance suite-wide is truthful: these are deliberate
# out-of-sandbox runs. Tests that wipe the environment with `env -i` must
# re-inject this themselves (or simulate in-sandbox by setting
# SANDBOX_ACTIVE=1 + SANDBOX_PROJECT_DIR). Export only if unset so an
# in-sandbox developer run keeps SANDBOX_* as the (no-op) signal.
export NEXUS_I_ACCEPT_NO_SANDBOX="${NEXUS_I_ACCEPT_NO_SANDBOX:-1}"

# No test may ring a REAL terminal bell. Several suites drive the genuine
# alert paths (monitor/cc-auto-update-apply.sh, revive-watcher.sh, the watcher
# escalations), each of which calls `sandbox-notify`. Measured on 2026-07-24, a
# single direct run of test-cc-auto-update.sh emitted ~3.4 bells/second into
# the operator's live tmux — the dominant source of the bell flood that
# PR #373 was meant to end. monitor/notifywrap/sandbox-notify honours this as a
# hard off-switch. It is belt-and-braces with that wrapper's test-ancestry
# probe (which also covers `bash monitor/watcher/test-X.sh` run directly).
export NEXUS_NOTIFY_QUIET=1

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_state_dir="${NEXUS_TEST_STATE_DIR:-$HOME/.cache/nexus-test-runner}"
mkdir -p "$_state_dir"
_failures_file="$_state_dir/last-failures.txt"

filter=""
list_only=0
profile=0
failed_only=0
jobs=1
keep_logs_dir=""
per_test_timeout="${NEXUS_TEST_TIMEOUT:-0}"
tally_file=""
resume=0
max_seconds=0
require_ci_parity="${NEXUS_TEST_REQUIRE_CI_PARITY:-0}"
explicit_files=()

while (( $# > 0 )); do
    case "$1" in
        --filter)        filter="$2"; shift 2 ;;
        --filter=*)      filter="${1#--filter=}"; shift ;;
        --list|-l)       list_only=1; shift ;;
        --profile|-p)    profile=1; shift ;;
        --failed-only|-f) failed_only=1; shift ;;
        --jobs|-j)       jobs="$2"; shift 2 ;;
        --jobs=*)        jobs="${1#--jobs=}"; shift ;;
        --keep-logs)     keep_logs_dir="$2"; shift 2 ;;
        --keep-logs=*)   keep_logs_dir="${1#--keep-logs=}"; shift ;;
        --timeout)       per_test_timeout="$2"; shift 2 ;;
        --timeout=*)     per_test_timeout="${1#--timeout=}"; shift ;;
        --state)         tally_file="$2"; shift 2 ;;
        --state=*)       tally_file="${1#--state=}"; shift ;;
        --resume)        resume=1; shift ;;
        --max-seconds)   max_seconds="$2"; shift 2 ;;
        --max-seconds=*) max_seconds="${1#--max-seconds=}"; shift ;;
        --require-ci-parity) require_ci_parity=1; shift ;;
        -h|--help)
            sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# //; s/^#$//'
            exit 0
            ;;
        --)              shift; explicit_files+=("$@"); break ;;
        -*)
            printf 'run-tests.sh: unknown flag %q\n' "$1" >&2
            exit 2
            ;;
        *)               explicit_files+=("$1"); shift ;;
    esac
done

if ! [[ "$jobs" =~ ^[0-9]+$ ]] || (( jobs < 1 )); then
    printf 'run-tests.sh: --jobs must be a positive integer (got %q)\n' "$jobs" >&2
    exit 2
fi
if ! [[ "$per_test_timeout" =~ ^[0-9]+$ ]] || ! [[ "$max_seconds" =~ ^[0-9]+$ ]]; then
    printf 'run-tests.sh: --timeout / --max-seconds must be non-negative integers\n' >&2
    exit 2
fi
if (( resume )) && [[ -z "$tally_file" ]]; then
    printf 'run-tests.sh: --resume requires --state <file> (the ledger to resume from)\n' >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# INTERPRETER AXIS (your-org/nexus-code#610)
#
# The suite's own correctness depends on shell-version behaviour, and no host
# in this workspace runs the bash CI runs. That asymmetry has already hidden
# two 5.2-only defects: the fork-floor probe that collapsed to its lower bound
# (#597 — CI capped forks at 87 against a real floor of 566, so every test died
# of EAGAIN) and `patsub_replacement` silently corrupting generated gh stubs.
# Neither could be reproduced locally EVEN IN PRINCIPLE.
#
# Two things follow, and both are needed. NEXUS_TEST_SHELL makes the local
# environment able to run the suite under CI's interpreter (build one with
# monitor/toolchain-bash.sh). And, whether or not that is used, the run
# DECLARES which interpreter it took its evidence under — because a green run
# that cannot see a whole failure class must not be read as covering it.
# ---------------------------------------------------------------------------
TEST_INTERPRETER="${NEXUS_TEST_SHELL:-bash}"
if ! command -v "$TEST_INTERPRETER" >/dev/null 2>&1; then
    printf 'run-tests.sh: NEXUS_TEST_SHELL=%q is not executable.\n' "$TEST_INTERPRETER" >&2
    printf '  Build one with: monitor/toolchain-bash.sh --print-path\n' >&2
    printf '  Refusing to silently fall back to the system bash — that is the\n' >&2
    printf '  exact substitution #610 is about.\n' >&2
    exit 2
fi
export TEST_INTERPRETER

# Ask the INTERPRETER, not this shell: the runner may be 4.4 while dispatching
# tests to a built 5.2, and it is the tests' interpreter whose version bounds
# the coverage claim.
interp_ver=$("$TEST_INTERPRETER" -c \
    'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null) || interp_ver=""
if [[ -z "$interp_ver" ]]; then
    printf 'run-tests.sh: %q did not report a BASH_VERSINFO — is it bash?\n' \
        "$TEST_INTERPRETER" >&2
    exit 2
fi

_ci_bash_pin_file="${NEXUS_CI_BASH_VERSION_FILE:-$_self_dir/../ci-bash-version}"
ci_bash_ver=""
if [[ -r "$_ci_bash_pin_file" ]]; then
    ci_bash_ver=$(grep -v '^[[:space:]]*#' "$_ci_bash_pin_file" \
                  | grep -v '^[[:space:]]*$' | head -1 | tr -d '[:space:]')
fi

interp_parity=unknown
if [[ -n "$ci_bash_ver" ]]; then
    if [[ "$interp_ver" == "$ci_bash_ver" ]]; then
        interp_parity=match
    else
        interp_parity=differs
    fi
fi

if [[ "$interp_parity" == differs ]] && (( require_ci_parity )); then
    printf 'run-tests.sh: --require-ci-parity: interpreter is bash %s, CI runs bash %s.\n' \
        "$interp_ver" "$ci_bash_ver" >&2
    printf '  NEXUS_TEST_SHELL=$(monitor/toolchain-bash.sh --print-path) %s ...\n' \
        "$0" >&2
    exit 2
fi
if (( max_seconds > 0 )) && (( jobs > 1 )); then
    printf 'run-tests.sh: --max-seconds is serial-only (a budget stop between concurrent shards would be a lie)\n' >&2
    exit 2
fi
if [[ -n "$tally_file" ]]; then
    mkdir -p "$(dirname "$tally_file")" 2>/dev/null || true
    touch "$tally_file" || { printf 'run-tests.sh: cannot write --state %q\n' "$tally_file" >&2; exit 2; }
fi

# Build the test list. Explicit paths win; otherwise glob test-*.sh.
if (( ${#explicit_files[@]} > 0 )); then
    tests=("${explicit_files[@]}")
elif (( failed_only )); then
    if [[ ! -s "$_failures_file" ]]; then
        echo "run-tests.sh: no previous failures recorded at $_failures_file" >&2
        exit 2
    fi
    mapfile -t tests < "$_failures_file"
else
    mapfile -t tests < <(
        for t in "$_self_dir"/test-*.sh; do
            [[ -f "$t" ]] || continue
            printf '%s\n' "$t"
        done
        # Pull in the monitor/-level suites (your-org/nexus-code#484).
        # Several tests for non-watcher scripts live one directory up —
        # test-retire-preflight.sh, test-interactive-sessions.sh, and the
        # two #507/#484 regression suites. Nothing globbed them, so CI ran
        # none of them: a regression test nobody runs is not a regression
        # test, it is a claim of protection that was never established.
        # Resolve the dir rather than globbing `$_self_dir/..`, so the
        # `<parent>/<basename>` suffix the --filter and --keep-logs paths
        # derive reads `monitor/test-x.sh`, not `../test-x.sh`.
        _monitor_dir=$(cd "$_self_dir/.." && pwd) || _monitor_dir=""
        if [[ -n "$_monitor_dir" ]]; then
            for t in "$_monitor_dir"/test-*.sh; do
                [[ -f "$t" ]] || continue
                printf '%s\n' "$t"
            done
        fi
        # Pull in the integration suite too. Each file self-skips
        # when RUN_INTEGRATION is unset, so the default fast loop
        # pays one ~50 ms `bash -c '<skip>'` per file rather than
        # the multi-second tmux bring-up. Discoverable via --list
        # / --filter without forcing operators to remember the
        # subdirectory path.
        for t in "$_self_dir"/test-integration/test-*.sh; do
            [[ -f "$t" ]] || continue
            printf '%s\n' "$t"
        done
    )
fi

# Apply --filter substring after path resolution. Matches against
# the path SUFFIX (`<parent-dir>/<basename>`) so a filter like
# `integration` catches both `test-respawn-loop-integration.sh` and
# anything under `test-integration/`.
if [[ -n "$filter" ]]; then
    filtered=()
    for t in "${tests[@]}"; do
        parent=$(basename "$(dirname "$t")")
        suffix="$parent/$(basename "$t")"
        if [[ "$suffix" == *"$filter"* ]]; then
            filtered+=("$t")
        fi
    done
    tests=("${filtered[@]}")
fi

if (( ${#tests[@]} == 0 )); then
    echo "run-tests.sh: no tests matched" >&2
    exit 2
fi

if (( list_only )); then
    for t in "${tests[@]}"; do
        # Content-based opt-out detection: robust to file renames, no
        # separate allow-list to maintain. Integration tag wins over
        # slow tag if a file gates on both — integration is the
        # heavier dependency (tmux on PATH).
        tag_base=$(basename "$t")
        if grep -q 'RUN_INTEGRATION' "$t" 2>/dev/null; then
            printf '%-45s  (integration; RUN_INTEGRATION=1 to enable)\n' "$tag_base"
        elif grep -q 'SLOW_TESTS' "$t" 2>/dev/null; then
            printf '%-45s  (slow; SLOW_TESTS=1 to enable)\n' "$tag_base"
        else
            printf '%s\n' "$tag_base"
        fi
    done
    exit 0
fi

# --- declared assertion count (your-org/nexus-code#693) --------------------
#
# THE HOLE. CI records per-suite results only: `PASS test-svc.sh 15.96s`. On a
# green run every suite's stream is discarded, so WHICH assertions executed is
# unrecoverable after the fact — and this repo's own standard ("validate a green
# as non-vacuous") is therefore not performable against CI at all. A fixture
# change that makes a case unreachable produces a green indistinguishable from a
# real one.
#
# WHAT THE CORPUS ACTUALLY SAYS. Measured over all 248 selected suites, from
# their OUTPUT rather than their source: **every one of them already declares a
# count.** The gap is not coverage, it is NORMALISATION — the counts are spelled
# twelve different ways, so no single reader sees them:
#
#     === summary: N passed, M failed ===        163 suites (_test_helpers.sh)
#     ALL TESTS PASSED (N assertions)              |
#     ALL TESTS PASSED (N checks)                  |
#     ALL TESTS PASSED (N)                         |
#     ALL TESTS PASSED (N/M)                       |
#     N passed, M failed                           |  85 suites, private
#     <label>: N passed, M failed                  |  footers
#     passed=N failed=M                            |
#     passed: N  failed: M                         |
#     N pass / M fail                              |
#     PASS=N FAIL=M                                |
#     <label> tests: N/M passed                    |
#
# WHY AN ENUMERATED SET IS THE RIGHT SHAPE HERE, given that this repo has been
# burned repeatedly by checking spellings instead of properties. The banned move
# is enumerating spellings OFFLINE TO PRODUCE A NUMBER: a missed spelling
# silently deflates the answer and nothing says so. That failure happened three
# times while this set was being derived — a terminal-line reader scored 23
# suites as having no accounting, a whole-file reader scored 14, and reading all
# 14 by hand found the true residual is ZERO. Here a missed spelling produces a
# visible `?` on the run's own row and a counted line in the footer, on every CI
# run, forever. Loud, not silent — and the footer is the migration checklist.
#
# The first integer on the matched line IS the executed-assertion count: every
# shape above leads with its PASSED count, and a passing suite has zero
# failures.
_rt_declared_assertions() {
    local log="$1" line
    line=$(grep -aE '(===[[:space:]]*summary:[[:space:]]*[0-9]+[[:space:]]+passed)|(ALL TESTS PASSED[[:space:]]*\([0-9]+)|([0-9]+[[:space:]]+passed,[[:space:]]*[0-9]+[[:space:]]+failed)|(passed[[:space:]]*[=:][[:space:]]*[0-9]+)|([0-9]+[[:space:]]+pass[[:space:]]*/[[:space:]]*[0-9]+[[:space:]]+fail)|(PASS=[0-9]+)|([0-9]+/[0-9]+[[:space:]]+passed)' \
             -- "$log" 2>/dev/null | tail -n1)
    [[ -n "$line" ]] || return 1
    # ANCHORED CAPTURE, one per alternative — SEVEN, matching the regex above.
    # (The twelve in the table are SPELLINGS; several collapse onto one
    # alternative. Quoting either number alone invites the confusion, so: twelve
    # spellings across seven alternatives.)
    #
    # This replaces "the first integer on the matched line", which was a SILENT
    # corruption path — the one failure mode this feature must not have, since a
    # wrong count is indistinguishable from a right one:
    #
    #   [2026-08-05 02:00] passed: 41  failed: 0   ->  2026   (a timestamp)
    #   [3/12] passed=41 failed=0                  ->  3      (a progress counter)
    #   cc-update2: 17 passed, 0 failed            ->  2      (a DOCUMENTED spelling)
    #   2026-08-05 === summary: 63 passed, 0 ===   ->  2026   (the CANONICAL footer,
    #                                                          emitted by 163 suites)
    #
    # The last two are the ones that matter: they are inside the supported set, so
    # "use a documented spelling" was not protection. Latent today — no current
    # label carries a digit (`retire-preflight:`, `cc-update:`, `cc-version:`) and
    # nothing datestamps the footer — which is exactly when to fix it.
    #
    # Each pattern's leading `.*` is greedy, so it anchors to the LAST occurrence
    # of its marker and any prefix (timestamp, counter, label) is consumed rather
    # than captured. Order runs most-specific first; the first pattern that yields
    # a digit wins.
    # Every capture is preceded by an explicit `[^0-9]` (or a literal delimiter),
    # because a greedy `.*` will otherwise eat into the NUMBER: `.*\([0-9]*\)`
    # against `cc-update: 23 passed,` lets `.*` swallow `cc-update: 2` and
    # captures `3`. Caught only by driving the function over the corpus's own
    # footers rather than reading the patterns. The leading sentinel space makes
    # `[^0-9]` satisfiable when the number starts the line (`4 passed, 0 failed`).
    local n pat sline=" $line"
    for pat in \
        's/.*summary:[[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*passed.*/\1/p' \
        's/.*ALL TESTS PASSED[[:space:]]*(\([0-9][0-9]*\).*/\1/p' \
        's/.*[^0-9]\([0-9][0-9]*\)\/[0-9][0-9]*[[:space:]][[:space:]]*passed.*/\1/p' \
        's/.*[^0-9]\([0-9][0-9]*\)[[:space:]][[:space:]]*passed,.*/\1/p' \
        's/.*passed[[:space:]]*[=:][[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        's/.*[^0-9]\([0-9][0-9]*\)[[:space:]][[:space:]]*pass[[:space:]]*\/.*/\1/p' \
        's/.*PASS=\([0-9][0-9]*\).*/\1/p'
    do
        n=$(printf '%s' "$sline" | sed -n "$pat")
        [[ -n "$n" ]] && break
    done
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$n"
}
# MUST be exported, and the pair is now CLOSED rather than merely sufficient.
#
# `run_one` is dispatched through `xargs … bash -c` when --jobs > 1, and a child
# shell inherits exported FUNCTIONS, not the file's definitions. Exporting
# `run_one` alone left this callee undefined in every parallel child:
# 245 x `_rt_declared_assertions: command not found`, every row `assertions: ?`,
# and a run total of `0` — green, in all five cells of the fast band, from the
# first merge.
#
# CLOSURE, not hope: this file `source`s nothing and defines exactly two
# functions (`_rt_declared_assertions`, `run_one`); `run_one`'s only
# script-defined callee is the former. So {run_one, _rt_declared_assertions} is
# the complete set reachable in a child, and there is no second missing export
# to find. Adding a third function called from `run_one` means adding a third
# `export -f` — test-assertion-accounting.sh section 6 catches the omission.
export -f _rt_declared_assertions

# Per-test runner: prints a status line, captures wall-time if
# --profile is set, writes failed paths to a per-job tempfile.
# With $KEEP_LOGS_DIR set (--keep-logs), the full stdout/stderr of
# every test lands at <dir>/<parent>__<name>.{out,err} and survives
# the run — under --jobs N the inline stderr tails of concurrent
# failures interleave, so a rare flake's assertion text is otherwise
# unrecoverable without a lucky re-run.
# --- resource state beside a failure (your-org/nexus-code#655) -------------
#
# WHY THE NUMBERS, AND WHY THESE NUMBERS. #655's intermittent-suite component
# spent four rounds correlating failures against LOADAVG, and loadavg is the
# wrong variable: 20/20 runs of the flakiest suite came back green at loadavg
# 29.9-34.0, spanning and exceeding the 31 of the single original observation.
# What DOES reproduce the exact signature — `bash: fork: retry: Resource
# temporarily unavailable` — is RLIMIT_NPROC headroom: at ~213 resident
# processes for this uid, `ulimit -Su` <= 2000 fails deterministically and
# >= 2500 passes.
#
# RLIMIT_NPROC is per-UID, so every agent, worker and watcher on the box draws
# from ONE pool. That is exactly why load CORRELATED without being causal: more
# agents raise both the load and the process count. Recording the ceiling and
# the count beside each failure is what turns the next occurrence into an
# attribution instead of a fifth round of correlation.
#
# BOUNDARY, stated because it is easy to over-read: this samples AFTER the test
# process has exited, so it is the neighbourhood of the failure, not the
# instant of it. A storm that has already drained will read healthy. It is
# evidence, not proof — but the fork-EAGAIN line below IS from the failing run
# itself, and that one is decisive.
# TWO CORRECTIONS, both measured on 2026-08-05 (your-org/nexus-code#655).
# The analysis above is right and independently replicated — 6/6 green at
# loadavg 36.4-39.0 with full headroom, 3/3 red at loadavg 38.0 with
# headroom squeezed to 60 tasks, so headroom is causal and load is not.
# What was wrong was the INSTRUMENTATION, in both of its halves, and each
# failure is this repo's dominant defect class: a proxy standing in for
# the property.
#
# (1) THE COUNT WAS THE WRONG POPULATION. `ps -u … -o pid=` counts
#     PROCESSES; RLIMIT_NPROC is checked against TASKS (threads). Measured
#     here the same instant: 153 processes, 871 tasks — a 5.7x
#     understatement of the only quantity the ceiling compares against. An
#     operator reading `resident-procs(uid)=153 soft=8192` concludes there
#     is vast headroom at the exact moment a suite is dying of EAGAIN. The
#     repo already knows the distinction — the nproc guard's own banner
#     says "tasks != processes, #506" — it just was not applied here. Both
#     are printed now, the one that matters is labelled, and the headroom
#     is computed rather than left as an subtraction the reader has to
#     know to perform.
#
# (2) THE DETECTOR MATCHED A SPELLING, NOT THE PROPERTY. The old test was
#     `grep -F 'fork: retry: Resource temporarily unavailable'` — bash's
#     exact wording. A reproduction of the identical mechanism emits
#     `timeout: fork system call failed: Resource temporarily unavailable`
#     (coreutils'), which does NOT match. That is the spelling CI is MOST
#     likely to see, because run_one wraps every test in `timeout` whenever
#     PER_TEST_TIMEOUT is set — so the case the note was written for was
#     precisely the case it stayed silent about, and the run read as a
#     plain red.
#
#     The property is EAGAIN, whose strerror is "Resource temporarily
#     unavailable", so that is what is matched. Deliberately broader than
#     fork: EAGAIN from another syscall in a test log is far more likely to
#     be this exhaustion than a coincidence, and the asymmetry decides it —
#     a false positive costs one re-run, a false negative costs a
#     misattributed red and another round of correlation. The matched line
#     is ECHOED rather than summarised, so the reader judges the
#     attribution instead of taking the grep's word for it.
# A THIRD CORRECTION (your-org/nexus-code#720), same defect class as the two
# above: a proxy standing in for the property.
#
# The fields below attribute FORK starvation well, and `#718`'s CI-side sample
# proved it — `fork-headroom=2037 of 2109` on a 2-vCPU runner at jobs=4. But
# that reading is a NEGATIVE: it excludes fork exhaustion and attributes
# nothing, and a 96.6%-free headroom printed beside a failing suite reads as
# "resources were fine". The failure it cannot see is CPU starvation.
#
# loadavg was already here and cannot close it, for the reason `th_cpu_pressure`
# documents: it is un-normalized, so the runner's 5.19-on-2-vCPU (2.60x) prints
# SMALLER than a workstation's 44-on-36 (1.23x) while being twice the pressure.
# `#720`'s whole question is workstation-vs-runner, so the one field that spoke
# to CPU was uninterpretable across exactly the comparison it was needed for.
#
# So: `cpus` (the denominator, making loadavg comparable at last) and
# `cpu-stall%` (PSI — time actually stalled on the runqueue, already a rate).
# HIGH cpu-stall WITH healthy fork-headroom is the signature that previously
# had no spelling; it is now one line and two numbers.
_rt_resource_note() {
    local log_base="$1" soft hard nprocs ntasks la headroom cpus stall
    soft=$(ulimit -Su 2>/dev/null || echo '?')
    hard=$(ulimit -Hu 2>/dev/null || echo '?')
    # `grep -c` prints its count on the NO-MATCH path too and exits 1, so a
    # `|| echo '?'` fallback appends a second value ("0\n?") rather than
    # replacing it — and the `^[0-9]+$` guard below would then silently
    # downgrade headroom to '?' for a reason that is not the one stated
    # (issue #725). Capture, then validate.
    nprocs=$(ps -u  "$(id -u)" -o pid= 2>/dev/null | grep -c .) || nprocs='?'
    ntasks=$(ps -Lu "$(id -u)" -o pid= 2>/dev/null | grep -c .) || ntasks='?'
    la=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')
    headroom='?'
    if [[ "$soft" =~ ^[0-9]+$ && "$ntasks" =~ ^[0-9]+$ ]]; then
        headroom=$(( soft - ntasks ))
    fi
    # `nproc` honours the CPU affinity mask (and a cgroup-capped runner);
    # `getconf` does not. The right denominator is CPUs available to THIS run
    # — the same reasoning `th_deadline` already applies.
    cpus=$(nproc 2>/dev/null) || cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cpus='?'
    [[ "$cpus" =~ ^[0-9]+$ ]] && (( cpus >= 1 )) || cpus='?'
    # INLINED, not delegated to `th_cpu_pressure`. This runner sources NOTHING
    # — deliberately, per the note further down — so a call to a
    # `_test_helpers.sh` symbol here would be `command not found`, `stall`
    # would degrade to `unknown` on every run, and the field would read as "no
    # PSI on this host" forever. That is a diagnostic that cannot fire dressed
    # as one that found nothing, i.e. the defect this whole file exists to
    # stop. `test-cpu-pressure-note.sh` asserts the two implementations agree,
    # so the duplication cannot drift silently.
    stall=$(grep -m1 '^some' /proc/pressure/cpu 2>/dev/null) || stall=""
    # BEGIN psi-parse — extracted verbatim by test-cpu-pressure-note.sh and run
    # against the same fixtures as `th_cpu_pressure`, so the two cannot drift.
    if [[ -n "$stall" && "$stall" == *avg10=* ]]; then
        stall=${stall#*avg10=}; stall=${stall%% *}
        [[ "$stall" =~ ^[0-9]+([.][0-9]+)?$ ]] || stall='unknown'
    else
        stall='unknown'
    fi
    # END psi-parse
    printf '    resources (sampled after exit): RLIMIT_NPROC soft=%s hard=%s  uid-TASKS=%s (what the ceiling counts)  uid-procs=%s  fork-headroom=%s  loadavg=%s  cpus=%s  cpu-stall%%=%s (PSI some avg10)\n' \
        "$soft" "$hard" "$ntasks" "$nprocs" "$headroom" "$la" "$cpus" "$stall"
    # The signature that had no spelling before: plenty of fork headroom, and
    # the box nonetheless spent a large fraction of the last 10 s with a task
    # stalled on the runqueue. Stated as a READING, not a verdict — it is
    # sampled after exit, so it is the neighbourhood of the failure (the same
    # boundary the header declares for every field here).
    # BEGIN psi-escalate — extracted verbatim by test-cpu-pressure-note.sh and
    # driven with controlled (stall, headroom, cpus). Marker-extracted for the
    # same reason psi-parse is, and the reason is a MEASURED one: C5-C8 used to
    # restate this conditional inline, so moving the `20` threshold to `90` here
    # left the suite 16/0 GREEN. An assertion that pins a discrimination rule by
    # re-typing it pins the retyping, not the rule — "a guard that cannot fire,
    # dressed as one that found nothing", inside the fix for that class.
    if [[ "$stall" =~ ^[0-9]+([.][0-9]+)?$ && "$headroom" =~ ^[0-9]+$ ]]; then
        if (( ${stall%.*} >= 20 )) && (( headroom >= 500 )); then
            printf '    *** CPU-STALL neighbourhood: fork-headroom=%s is HEALTHY, so this is NOT #655 exhaustion,\n' "$headroom"
            printf '    *** but PSI says a task was stalled on the runqueue %s%% of the last 10s on %s cpu(s).\n' "$stall" "$cpus"
            printf '    *** A wall-clock predicate can expire here with every resource gauge reading fine.\n'
            printf '    *** your-org/nexus-code#720: read as contention before reading as a test defect.\n'
        fi
    fi
    # END psi-escalate
    local hit
    hit=$(grep -m1 -h 'Resource temporarily unavailable' \
            "$log_base.err" "$log_base.out" 2>/dev/null)
    if [[ -n "$hit" ]]; then
        printf '    *** EAGAIN in this run — RLIMIT_NPROC exhaustion, NOT a test defect.\n'
        printf '    *** matched: %s\n' "$hit"
        printf '    *** The ceiling is per-UID and shared with every other agent on this box.\n'
        printf '    *** your-org/nexus-code#655: re-run before reading this as a red.\n'
    fi
}

# --- a failing test's own diagnosis (your-org/nexus-code#752) ---------------
#
# THE PROPERTY: when a test goes red, show the text that test emitted about
# its failure. Tailing `.err` ALONE was a PROXY for that property — one that
# returns NOTHING, silently, whenever a suite announces its verdict on stdout.
#
# MEASURED, not reasoned: at head d4df844f (run 31153179861) the blocking SLOW
# band reported
#
#     FAIL  test-respawn-loop-integration.sh   59.26s  rc=1
#
# and not one further line, on BOTH attempts. Its `.err` was 0 bytes; its
# `.out` was 10,563 bytes ending `FAIL: guard did not trip within deadline`.
# The runner had the diagnosis on disk and printed none of it, so the red was
# triaged as a mystery flake for a day.
#
# WHY THE FIX BELONGS HERE AND NOT IN THE TESTS. The obvious alternative is to
# make every suite write failures to stderr. That cannot be verified: the
# affected set is not statically decidable. Sourcing `_test_helpers.sh` is NOT
# a guarantee — test-respawn-loop-integration.sh DOES source it, and every
# `assert_*` in it routes to stderr correctly, but its terminal verdict is
# hand-rolled `echo` on the success-path fallthrough and never goes through a
# helper at all.
#
# A corpus scan scores 63 of 271 and MISSES that file — the very file that
# motivated this. A rule whose own motivating case evades it is not a rule.
#
# THE PREDICATE, stated because the number is meaningless without it (a skeptic
# re-derivation on #759 reproduced the denominator exactly and could not
# reproduce 63 from the loose phrase "suites with no stderr FAIL routing",
# which admits at least eight operationalizations scoring 23-207). Verbatim,
# under an EXPLICIT bash -c — in zsh the `< <(…)` enumeration is a different
# language and the count is not this one:
#
#   bash -c '
#   total=0; nohelper=0; risky=0
#   while IFS= read -r f; do
#     total=$((total+1))
#     grep -q "_test_helpers.sh" "$f" 2>/dev/null && continue
#     nohelper=$((nohelper+1))
#     if grep -qE "^[[:space:]]*(echo|printf)[[:space:]].*\bFAIL" "$f" \
#        && [ "$(grep -cE "^[[:space:]]*(echo|printf)[[:space:]].*\bFAIL.*>&2" "$f")" = 0 ]
#     then risky=$((risky+1)); fi
#   done < <(find monitor .github -name "test-*.sh" -type f | sort)
#   echo "total=$total no-helper=$nohelper risky=$risky"'
#   # total=271 no-helper=174 risky=63   (measured at 0a54967)
#
# So 63 is the CONJUNCTION of three conditions, not "no stderr routing": the
# suite does not source _test_helpers.sh, AND announces a failure from an
# anchored echo/printf line, AND has no such line carrying `>&2`. Change any
# one and the number changes.
#
# THE NUMBER IS ILLUSTRATIVE; THE MISS IS THE ARGUMENT. Note the miss does not
# depend on this predicate at all — test-respawn-loop-integration.sh carries
# `FAIL … >&2` at its fixture-drift guard, so EVERY static "does it route FAIL
# to stderr" scan classifies it compliant, whatever the spelling. That is why
# the runner carries the guarantee unconditionally, for every suite, including
# ones not yet written.
#
# STATED COVERAGE BOUNDARY: this shows stdout only when stderr is EMPTY. A
# suite that emits unrelated stderr noise AND reports its verdict on stdout
# still shows only the noise. That residual is deliberate — always printing
# both tails doubles the output of every red, and the empty-stderr case is the
# one that is provably silent rather than merely cluttered. If a suite is ever
# found in that residual, widen this to print both labelled tails.
_rt_failure_tail() {
    local log_base="$1" n=20
    if [[ -s "$log_base.err" ]]; then
        tail -n "$n" -- "$log_base.err" 2>/dev/null | sed 's/^/    /'
        return
    fi
    if [[ -s "$log_base.out" ]]; then
        # Say WHICH stream this is. The reader who has to triage a red should
        # never have to guess whether an empty stderr meant "silent test" or
        # "runner looked in the wrong place" — that ambiguity is #752 itself.
        printf '    (stderr empty — stdout tail follows)\n'
        tail -n "$n" -- "$log_base.out" 2>/dev/null | sed 's/^/    /'
        return
    fi
    printf '    (test emitted nothing on either stream)\n'
}

run_one() {
    local test_path="$1" out_file="$2"
    # FAIL CLOSED ON AN EMPTY BASE (your-org/nexus-code#857).
    #
    # Every sidecar and log below is written as `"$out_file.<kind>"`. With an
    # EMPTY base those become `.caseskipped`, `.nocount`, `.zerocount`,
    # `.assertions`, `.failed`, `.timedout`, `.out`, `.err` — RELATIVE paths,
    # created in whatever directory happens to be current, which in practice is
    # the repo root. They are dotfiles, so nothing lists them; they persist
    # after the run; and a `git add -A` sweeps all of them into a commit
    # without a diff reviewer noticing a dotfile at the root. That is exactly
    # how #850 committed seven of them, one commit already pushed before anyone
    # saw it — found by an unrelated `git ls-files`.
    #
    # The base is empty only when the caller's `$(mktemp …)` failed, i.e. when
    # the run is ALREADY in trouble. Writing junk into the user's working tree
    # is the worst available response to that: it is invisible, it outlives the
    # run, and it silently discards this test's accounting. Refuse instead.
    #
    # Guarded here rather than only at the two call sites because this is the
    # single funnel every sidecar write passes through, so it also covers a
    # caller nobody has written yet.
    if [[ -z "$out_file" ]]; then
        printf 'run-tests.sh: EMPTY out_file base for %s — refusing.\n' \
            "${test_path:-<no test path>}" >&2
        printf '  Sidecars would have been written as dotfiles into %s\n' "$PWD" >&2
        printf '  and would survive the run. The caller'\''s mktemp failed; fix that.\n' >&2
        printf '  (your-org/nexus-code#857)\n' >&2
        return 97
    fi
    local name; name=$(basename "$test_path")
    local log_base="$out_file"
    if [[ -n "${KEEP_LOGS_DIR:-}" ]]; then
        local parent; parent=$(basename "$(dirname "$test_path")")
        log_base="$KEEP_LOGS_DIR/${parent}__${name}"
    fi
    # WHICH SUITE THIS IS, carried into the child's environment so anything it
    # leaks can name its producer (your-org/nexus-code#720). The band runs at
    # `--jobs 4` and `ng-usage.jsonl`'s `ts` has ONE-SECOND resolution, so a
    # leaked row's timestamp places it in a window holding several concurrent
    # suites — which is why the CI occurrence at `d1cc62b` could be NARROWED to
    # a handful of `ng`-verb suites and not ATTRIBUTED to one. #720's own
    # comment names two remedies and calls this the better of them: serialising
    # the band at `--jobs 1` buys one attribution for ~8 minutes of runner time
    # and buys nothing for the run after it, while putting the suite IN THE ROW
    # is durable and survives any future `--jobs` value.
    #
    # `<parent>/<basename>`, the same suffix --filter and --keep-logs already
    # use, so one spelling identifies a suite everywhere.
    #
    # A per-command assignment, not an `export`: it must reach this child and
    # nothing else, and it must not persist into the runner's own later work.
    local suite_tag; suite_tag="$(basename "$(dirname "$test_path")")/$name"
    local start_ns end_ns wall rc status
    start_ns=$(date +%s%N)
    if [[ "${PER_TEST_TIMEOUT:-0}" =~ ^[0-9]+$ ]] && (( ${PER_TEST_TIMEOUT:-0} > 0 )); then
        # Hard per-test ceiling (#499). TERM first so the test's own EXIT
        # trap can reap its fixture processes; KILL 15 s later if it
        # ignores that. rc=124 is timeout's TERM verdict, 137 the
        # KILL escalation — both are TIMEOUT, never a pass.
        NEXUS_TEST_SUITE="$suite_tag" \
        timeout -k 15 "$PER_TEST_TIMEOUT" "${TEST_INTERPRETER:-bash}" "$test_path" \
            >"$log_base.out" 2>"$log_base.err"
        rc=$?
    else
        NEXUS_TEST_SUITE="$suite_tag" \
        "${TEST_INTERPRETER:-bash}" "$test_path" >"$log_base.out" 2>"$log_base.err"
        rc=$?
    fi
    end_ns=$(date +%s%N)
    wall=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.2f", (e-s)/1e9}')
    status=PASS
    if (( rc == 77 )); then
        # SKIP (your-org/nexus-code#568 A6). Exit 77 — the autotools
        # convention — means "this test DECLINED TO RUN", which is a third
        # outcome the ledger previously could not express: `status=PASS`
        # whenever rc==0 tallied every self-skipping test as a pass, so a
        # green count silently conflated "asserted and passed" with "asserted
        # nothing at all". Thirteen structurally-skipping tests sat in the
        # default band, and three printed the literal `ALL TESTS PASSED` after
        # ZERO checks — the exact string humans and scrapers grep for. A SKIP
        # is not a failure (it must not turn the suite red) and not a pass
        # (it must not be counted as evidence).
        status=SKIP
    elif (( rc != 0 )); then
        status=FAIL
        if [[ "${PER_TEST_TIMEOUT:-0}" != "0" ]] && { (( rc == 124 )) || (( rc == 137 )); }; then
            status=TIMEOUT
        fi
    fi
    # Case-level skip count, for the ledger. The RENDERING of a qualified
    # PASS row is #611's (merged on dev) and is left exactly as it stands; this
    # only carries its count out to the tally file, which #611 deliberately
    # left alone. Set inside the PASS arm below.
    local n_cases_skipped=0
    # Declared assertion count (#693). `?` means the suite's footer is in a
    # spelling this runner does not read — NOT that it asserted nothing. The
    # distinction is the whole point: `?` is a normalisation debt, visible on
    # the row and counted in the footer; `0` is a green that covers nothing.
    local n_assertions='?'
    if [[ "$status" == PASS || "$status" == FAIL ]]; then
        n_assertions=$(_rt_declared_assertions "$log_base.out") || n_assertions='?'
    fi
    local ann=''
    case "$n_assertions" in
        '?') ann='  assertions: ?' ;;
        0)   ann='  0 ASSERTIONS — this PASS covers nothing' ;;
        *)   ann="  ${n_assertions} assertions" ;;
    esac
    # TERMINAL-ACCOUNTING RECORD (your-org/nexus-code#877). One line per test
    # that reached a verdict, written for EVERY outcome.
    #
    # DELIBERATELY ABOVE the `case`, not inside its arms. The summary compares
    # this count against the number of tests dispatched, and that comparison is
    # only trustworthy if the record cannot be forgotten. Written per-arm, a new
    # outcome added later would silently not be counted and the run would
    # under-report its own coverage while still reading green — which is the
    # exact defect class this record exists to catch, reintroduced one level
    # down. Above the `case`, a new arm inherits the record by construction.
    #
    # It cannot be reconstructed from the existing sidecars, which is why it is
    # a ninth name rather than a derived quantity: PASS writes `.assertions` or
    # `.nocount`, FAIL and TIMEOUT write `.failed`, and SKIP (`exit 77`) writes
    # NOTHING AT ALL on this path. A run of nothing but SKIPs therefore produces
    # zero outcome sidecars and is indistinguishable, by sidecar count alone,
    # from a run whose accounting was destroyed — so a naive "no sidecars means
    # refuse" rule would go red on a legitimately all-skipped run.
    # CARRIES THE STATUS, not just the path (your-org/nexus-code#887 skeptic F1).
    # The per-test row above is printed from `$status` in memory; the `.failed`
    # sidecar is a SEPARATE write in the arms below. Lose only that second write
    # and the row still prints while the tally does not count it — which
    # reproduces `#877`'s exact symptom (`FAIL` row, `0 failed`, `rc=0`) on a
    # runner that has already reconciled its accounting against dispatch, because
    # the record and the dispatch count still agree. Recording the status HERE
    # means the printed row and the verdict derive from ONE write, so the summary
    # can cross-check them instead of trusting that two writes stayed in step.
    printf '%s\t%s\n' "$test_path" "$status" >> "$out_file.accounted"
    case "$status" in
        PASS)
            # CASE-level skips must survive a green run (your-org/nexus-code#597
            # skeptic finding F1). `exit 77` gives us FILE-level SKIP, but a file
            # that runs 63 assertions and declines 3 exits 0, and this arm used
            # to print a bare `PASS` — while the per-test .out/.err are echoed
            # ONLY on FAIL. So `th_skip`'s reason line, the probed-uid list and
            # the `K SKIPPED` footer were all discarded exactly where they matter
            # most: CI, the only continuously-running environment.
            #
            # That is not a cosmetic loss. It made a green leg unable to
            # distinguish "the fail-closed ownership check ran" from "it was
            # skipped because no foreign-owned path existed" — both exit 0 — so
            # the security assertion `#584` exists to protect could go
            # permanently uncovered behind a `PASS`. It also hid T6's
            # headroom-64 banner on green runs.
            #
            # The footer `th_summary_and_exit` already emits is machine-readable,
            # so surface it generically: any test whose output declares skipped
            # cases gets an annotated row plus its own SKIP lines echoed. No
            # ledger semantics change — the ledger's SKIP column stays
            # file-level (exit 77) so existing tallies keep meaning what they
            # say; this is an additional, louder channel, not a redefinition.
            _skipped_cases=$(sed -n 's/.*=== summary:.*[^0-9]\([0-9][0-9]*\) SKIPPED.*/\1/p' \
                                 -- "$log_base.out" 2>/dev/null | tail -n1)
            if [[ "$_skipped_cases" =~ ^[0-9]+$ ]] && (( _skipped_cases > 0 )); then
                printf '  PASS  %-45s  %6ss %s  (%s CASE(S) SKIPPED — NOT covered)\n' \
                    "$name" "$wall" "$ann" "$_skipped_cases"
                grep -h -- 'SKIP:' "$log_base.out" "$log_base.err" 2>/dev/null \
                    | sed 's/^[[:space:]]*/    /' | cut -c1-200
                n_cases_skipped="$_skipped_cases"
                printf '%s\n' "$test_path" >> "$out_file.caseskipped"
            else
                printf '  PASS  %-45s  %6ss %s\n' "$name" "$wall" "$ann"
            fi
            unset _skipped_cases
            # Per-job sidecar for the no-ledger path, mirroring .caseskipped.
            # Three files, not one with a sentinel: the footer asks three
            # different questions (how many assertions ran; how many suites
            # could not say; which declared zero), and conflating any two is
            # how `?` would get silently counted as 0.
            if [[ "$n_assertions" == '?' ]]; then
                printf '%s\n' "$test_path" >> "$out_file.nocount"
            else
                printf '%s\n' "$n_assertions" >> "$out_file.assertions"
                if (( n_assertions == 0 )); then
                    printf '%s\n' "$test_path" >> "$out_file.zerocount"
                fi
            fi
            ;;
        SKIP)
            # Print the test's own reason line — a SKIP whose cause is
            # invisible is how a permanently-unrun test hides in plain sight.
            printf '  SKIP  %-45s  %6ss  %s\n' "$name" "$wall" \
                "$(head -n 3 -- "$log_base.out" 2>/dev/null | grep -m1 -i 'skip' | sed 's/^[[:space:]]*//' | cut -c1-100)"
            ;;
        TIMEOUT)
            printf '  TIMEOUT  %-42s  %6ss  (ceiling %ss — NOT a pass; see #499)\n' \
                "$name" "$wall" "$PER_TEST_TIMEOUT"
            _rt_resource_note "$log_base"
            printf '%s\n' "$test_path" >> "$out_file.failed"
            printf '%s\n' "$test_path" >> "$out_file.timedout"
            ;;
        FAIL)
            printf '  FAIL  %-45s  %6ss  rc=%d\n' "$name" "$wall" "$rc"
            _rt_resource_note "$log_base"
            printf '%s\n' "$test_path" >> "$out_file.failed"
            # Echo the failing test's own diagnosis so the failure is
            # debuggable without re-running. Stay terse — 20 lines is enough
            # to see the failed assertion in the existing test format. (tail,
            # not sed: GNU sed has no `$-20` address — the original sed form
            # errored silently into 2>/dev/null and printed nothing, which
            # is why CI failures looked output-less.) Which STREAM to read is
            # `_rt_failure_tail`'s problem, not this arm's — see #752 there.
            _rt_failure_tail "$log_base"
            if [[ -n "${KEEP_LOGS_DIR:-}" ]]; then
                printf '    full logs: %s.{out,err}\n' "$log_base"
            fi
            ;;
    esac
    # Durable ledger (#499): one line per completed test, appended the
    # moment it finishes, so an interrupted run resumes instead of
    # restarting and the final tally is computed from what actually ran.
    # Field 4 is the case-level skip count (your-org/nexus-code#584 F1);
    # field 5 the DECLARED assertion count, or `?` when the suite's footer is
    # in a spelling this runner does not read (your-org/nexus-code#693).
    # Appended, not substituted: every existing reader keys on $1/$2, so a
    # ledger written by this runner still parses in an older one.
    if [[ -n "${TALLY_FILE:-}" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$test_path" "$status" "$wall" \
            "$n_cases_skipped" "$n_assertions" >> "$TALLY_FILE"
    fi
    # A SKIP is not a failure: it must not turn the runner red, and
    # --failed-only must not re-select it.
    [[ "$status" == PASS || "$status" == SKIP ]]
}
# `_rt_resource_note` must be exported alongside `run_one` — the parallel path
# runs `run_one` in a fresh bash, where an unexported helper is `command not
# found`. It printed exactly that in CI on the first push of #716: the note
# went missing precisely in the `--jobs N` band, which is the band where the
# fork-EAGAIN it exists to attribute actually happens.
export -f _rt_resource_note
# Same contract, same reason, for the #752 failure-tail helper: `run_one` calls
# it on the FAIL arm, so an unexported `_rt_failure_tail` would be `command not
# found` in `--jobs N` mode — and the symptom would be a red printing NO
# diagnosis, i.e. #752 reproduced inside its own fix, in the one mode where the
# suite is slowest to re-run by hand.
#
# NOTE which suite covers this, because the obvious answer is wrong.
# test-assertion-accounting.sh section 6 is the established guard for "a helper
# went missing from the parallel children" — but EVERY fixture it builds exits
# 0 (they only print footers), so it never reaches the FAIL arm and cannot see
# this function at all. The coverage is test-run-tests-bounded.sh T7, which
# runs its failing fixtures at --jobs 1 AND --jobs 2 for exactly this reason.
export -f _rt_failure_tail
export -f run_one

# Common temp dir for per-run outputs.
run_dir=$(mktemp -d -t nexus-test-runner-XXXXXX)
trap 'rm -rf "$run_dir"' EXIT

# --- command_not_found_handle disarm (your-org/nexus-code#479 / #480) -----
# On the sandbox hosts BASH_ENV reaches (directly, or via the
# monitor/shellenv chain) Lmod's init, which arms a
# `command_not_found_handle` in EVERY non-interactive bash — including
# every bash any test spawns at any depth. The handler runs
# `command_not_found.py` via PATH; bash forks a child before invoking
# it, so a test that hands a child a synthetic PATH lacking the dir
# holding that script turns any missing command into an unbounded fork
# chain (the 2026-07-08 pid_max exhaustion, #457). The per-site guard
# is th_hermetic_path (_test_helpers.sh); this is the harness-level
# backstop: re-point BASH_ENV at a wrapper that sources the original,
# then disarms the handler — so no bash spawned under this runner,
# whatever its PATH, retains the recursion primitive. A missing command
# degrades to a plain rc=127, which is what tests want anyway. Tests
# that manage BASH_ENV themselves (env -i, explicit BASH_ENV=...) are
# unaffected: they drop or override the inherited value.
if [[ -n "${BASH_ENV:-}" && -r "${BASH_ENV}" ]]; then
    _benv_guard="$run_dir/bash-env-disarm.sh"
    {
        printf '. %q\n' "$BASH_ENV"
        printf 'unset -f command_not_found_handle 2>/dev/null || true\n'
    } > "$_benv_guard"
    export BASH_ENV="$_benv_guard"
fi
touch "$run_dir/failed"

if [[ -n "$keep_logs_dir" ]]; then
    mkdir -p "$keep_logs_dir" || {
        printf 'run-tests.sh: cannot create --keep-logs dir %q\n' "$keep_logs_dir" >&2
        exit 2
    }
    # Absolute path: run_one executes in xargs children whose cwd is
    # inherited, but callers may pass a relative dir and later cd.
    KEEP_LOGS_DIR=$(cd "$keep_logs_dir" && pwd)
    export KEEP_LOGS_DIR
fi

# --- Fork-bomb containment (your-org/nexus-code#457 / #449) --------------
# The suite runs `main.sh --once` under `xargs -P N`. A recursive-fork
# regression in the code under test (e.g. an unbounded subshell walk in the
# idle/process-tree path) turns a single test into a fork bomb that exhausts
# the node-wide `pid_max` (36864 on our nodes) and takes down the whole
# nexus stack — twice on 2026-07-08. Cap RLIMIT_NPROC for THIS run and every
# child (xargs → run_one → the test → main.sh → its subshells) so the kernel
# refuses the runaway's forks LONG before pid_max, converting a node-killer
# into a bounded, loud test failure.
#
# The cap is RELATIVE — but relative to the quantity the kernel actually
# compares against, which is the real UID's total TASK (thread) count, NOT
# its process count (your-org/nexus-code#506). A single node/claude process
# holds up to ~1000 threads, so the old `ps -o pid=` process count
# under-counted ~7-9x — and in the dangerous direction: the documented
# NEXUS_TEST_NPROC_HEADROOM=1 produced a cap far BELOW the fork floor, and
# every test (including the ones that pass) died with `fork: retry` — a
# confirmation hazard, since a harness that cannot fork reports failure for
# every hypothesis handed to it. A pid namespace (agent-sandbox) additionally
# hides the uid's host-side tasks, so NO ps variant is authoritative.
# Therefore probe the floor the kernel itself enforces — the smallest soft
# cap at which a fork still succeeds (binary search seeded by the visible
# task count) — and add the headroom to THAT. The knob now means what its
# name says: headroom above the true floor. Headroom default 2048 dwarfs the
# suite's peak concurrency (low hundreds) yet stays far under pid_max
# (36864, which also counts tasks). Small headrooms are honest now, but the
# headroom must still cover the suite's OWN fork bursts — below ~64 expect
# bash's EAGAIN retry backoff to crawl. Opt out with NEXUS_TEST_NPROC_GUARD=off.
if [[ "${NEXUS_TEST_NPROC_GUARD:-on}" != "off" ]]; then
    _headroom="${NEXUS_TEST_NPROC_HEADROOM:-2048}"
    if [[ "$_headroom" =~ ^[0-9]+$ ]]; then
        _cur_tasks=$(ps -eLo pid= 2>/dev/null | grep -c .)
        [[ "$_cur_tasks" =~ ^[0-9]+$ ]] && (( _cur_tasks > 0 )) || _cur_tasks=64
        # The probe MUST actually fork, and that is harder than it looks.
        # `( ulimit -Su N; /bin/true )` does NOT reliably fork: bash may exec the
        # last simple command of a subshell in place of the subshell, and bash
        # 5.2 does so far more aggressively than 4.4. When the optimisation
        # fires, no child is ever created, RLIMIT_NPROC is never exercised, every
        # candidate "succeeds", and the binary search collapses to its lower
        # bound — reporting a floor of ~23 on a host whose real floor was 566.
        # Measured on a GitHub runner (bash 5.2) at your-org/nexus-code#597:
        # "capped at 87 (probed task floor 23 …)" immediately followed by
        # run-tests.sh's own `fork: Resource temporarily unavailable`. That is
        # the #506 confirmation hazard back in full — a cap BELOW the true fork
        # floor, so every test dies of EAGAIN — and it was invisible because
        # the default headroom 2048 is large enough to mask a garbage floor.
        # It reproduces on no host with bash 4.x, which is why local
        # verification passed and only CI caught it.
        #
        # Command substitution cannot be optimised away: the parent has to read
        # the child's bytes through a pipe, so a real child must exist. And we
        # confirm the child RAN by checking what it wrote, rather than trusting
        # the exit status of a failed fork — a fork that fails yields empty
        # output, which is unambiguous.
        _probe_ok() {
            ( ulimit -Su "$1" 2>/dev/null || exit 1
              _pr=$(/bin/echo ok) || exit 1
              [ "$_pr" = ok ] ) 2>/dev/null
        }
        _lo=0; _hi=""
        _cand=$(( _cur_tasks > 64 ? _cur_tasks : 64 ))
        for _i in 1 2 3 4 5 6 7 8; do
            if _probe_ok "$_cand"; then _hi=$_cand; break; fi
            _lo=$_cand; _cand=$(( _cand * 2 ))
        done
        if [[ -n "$_hi" ]]; then
            while (( _hi - _lo > 32 )); do
                _mid=$(( (_lo + _hi) / 2 ))
                if _probe_ok "$_mid"; then _hi=$_mid; else _lo=$_mid; fi
            done
            _nproc_cap=$(( _hi + _headroom ))
            _hard=$(ulimit -Hu 2>/dev/null || echo unlimited)
            # Only ever LOWER the limit (raising needs privilege and is not
            # our intent); skip if the hard cap is already tighter.
            #
            # SOFT ONLY — `-Su`, never a bare `-u` (your-org/nexus-code#863).
            # A bare `ulimit -u N` sets soft AND hard, and lowering the HARD
            # limit is IRREVERSIBLE for this process and every descendant: only
            # a privileged process can raise it back. Measured on this host,
            # from a fresh shell:
            #
            #   ulimit -u  5000  ->  soft=5000  hard=5000       (unrecoverable)
            #   ulimit -Su 5000  ->  soft=5000  hard=3089753    (recoverable)
            #
            # Containment is UNCHANGED by the switch, because the kernel checks
            # `fork()` against the SOFT limit. The hard limit only bounds how
            # far soft can be raised — which is to say, the only thing the bare
            # form added was the damage.
            #
            # The damage is not hypothetical. `test-run-tests-bounded.sh` runs
            # this runner INSIDE a run of this runner, and the nested copy must
            # probe its own fork floor to engage its own guard. Under an
            # inherited hard cap the nested probe cannot explore above it, so
            # the computed cap fails the `< _hard` test below, the guard skips,
            # and — before this change — it skipped SILENTLY. The nested run
            # then reported rc=0 with no containment and no banner, and T6a
            # (which parses that banner) failed with `banner absent or wrong`
            # and no way to tell why. Same species as the accounting/verdict
            # split this file's summary guards address: the harness's own
            # bounding invalidated a measurement, and the invalid measurement
            # was reported as a result.
            if [[ "$_hard" == unlimited ]] || (( _nproc_cap < _hard )); then
                if ulimit -Su "$_nproc_cap" 2>/dev/null; then
                    printf '=== nproc guard: RLIMIT_NPROC capped at %d (probed task floor %d + headroom %d; tasks != processes, #506) ===\n' \
                        "$_nproc_cap" "$_hi" "$_headroom"
                else
                    # SAY SO. A guard that declines to engage and prints nothing
                    # is indistinguishable from one that engaged — and the whole
                    # point of the guard is that a fork storm here takes the node
                    # down. Loud, on stderr, and never fatal: the run is still
                    # worth taking, it is just NOT contained.
                    printf '=== nproc guard: NOT ENGAGED — `ulimit -Su %d` was refused (soft=%s hard=%s). This run has NO fork-bomb containment. (#863) ===\n' \
                        "$_nproc_cap" "$(ulimit -Su 2>/dev/null || echo '?')" "$_hard" >&2
                fi
            else
                # Not an error: something stricter is already in force, so the
                # run IS contained — just not by us. Still said out loud,
                # because the banner's absence is otherwise unreadable, and
                # because this is the arm a nested run lands in when an outer
                # runner lowered the hard limit (the #863 mechanism).
                printf '=== nproc guard: not engaged — computed cap %d is not below the inherited HARD limit %s, which is already at least as strict (soft=%s). Containment is inherited, not ours. (#863) ===\n' \
                    "$_nproc_cap" "$_hard" "$(ulimit -Su 2>/dev/null || echo '?')"
            fi
        else
            # The binary search never found a soft cap at which a fork
            # succeeded. Before #863 this printed nothing at all, which is the
            # worst case of the three: no containment AND no record that the
            # attempt was made.
            printf '=== nproc guard: NOT ENGAGED — could not probe a fork floor in %d doublings from %d (hard=%s). This run has NO fork-bomb containment. (#863) ===\n' \
                8 "$(( _cur_tasks > 64 ? _cur_tasks : 64 ))" \
                "$(ulimit -Hu 2>/dev/null || echo unlimited)" >&2
        fi
    fi
    unset _cur_tasks _headroom _nproc_cap _hard _lo _hi _cand _mid _i
    unset -f _probe_ok 2>/dev/null || true
fi

# run_one reads these from the environment (it also runs inside xargs
# children under --jobs).
export PER_TEST_TIMEOUT="$per_test_timeout"
export TALLY_FILE="$tally_file"

# The FULL selection, kept for the final accounting: the summary refuses
# to read green while any selected test is unaccounted for (#499).
all_selected=("${tests[@]}")

# --resume: skip tests the ledger already records (any status — re-running
# failures is --failed-only's job; resume's job is finishing the sweep).
if (( resume )) && [[ -s "$tally_file" ]]; then
    _resumed_skip=0
    filtered=()
    for t in "${tests[@]}"; do
        if awk -F'\t' -v p="$t" '$1==p{f=1} END{exit !f}' "$tally_file"; then
            _resumed_skip=$(( _resumed_skip + 1 ))
        else
            filtered+=("$t")
        fi
    done
    # A plain assignment: `("${filtered[@]:-}")` would leave ONE EMPTY
    # element when nothing remains, so a fully-recorded ledger printed
    # "1 remaining / running 1 tests" while running nothing (skeptic
    # finding on #499; display-only, but a runner whose own counts lie
    # is the wrong place to tolerate it).
    if (( ${#filtered[@]} > 0 )); then
        tests=("${filtered[@]}")
    else
        tests=()
    fi
    printf '=== resume: %d already recorded in %s; %d remaining ===\n' \
        "$_resumed_skip" "$tally_file" "${#tests[@]}"
fi

# Tell every child how much parallelism it is competing with, so
# `th_deadline` can size polled deadlines for the actual contention rather
# than for the idle host the numbers were written on
# (your-org/nexus-code#558). Purely additive: a test run directly, outside
# this runner, sees no NEXUS_TEST_JOBS and scales by 1.
export NEXUS_TEST_JOBS="$jobs"

# Print the EFFECTIVE deadline scale, not just the inputs it is derived from
# (your-org/nexus-code#749). th_deadline() scales polled deadlines by CPU
# oversubscription, ceil(jobs/nproc) — which is 1 whenever jobs <= nproc. The
# SLOW band runs at jobs=1 on a 2-vCPU runner, so its scale was silently 1 and
# every deadline was exactly its literal, in the band #737 had just made
# blocking. Nothing in the log said so: `jobs=1` is printed, `nproc` is not,
# and the reader is left to do the division. A band that forgets to set
# NEXUS_TEST_DEADLINE_SCALE now says `deadline-scale=1` in its own header
# rather than looking identical to one that set it deliberately.
_eff_cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
[[ "$_eff_cpus" =~ ^[0-9]+$ ]] && (( _eff_cpus >= 1 )) || _eff_cpus=1
if [[ "${NEXUS_TEST_DEADLINE_SCALE:-}" =~ ^[0-9]+$ ]] \
   && (( NEXUS_TEST_DEADLINE_SCALE >= 1 )); then
    _eff_scale="${NEXUS_TEST_DEADLINE_SCALE} (explicit)"
else
    _eff_scale="$(( (jobs + _eff_cpus - 1) / _eff_cpus )) (derived: ${jobs}j/${_eff_cpus}cpu)"
fi
printf '=== running %d tests (jobs=%d%s%s, deadline-scale=%s) ===\n' \
    "${#tests[@]}" "$jobs" \
    "$( (( per_test_timeout > 0 )) && printf ', timeout=%ss' "$per_test_timeout" )" \
    "$( (( max_seconds > 0 )) && printf ', budget=%ss' "$max_seconds" )" \
    "$_eff_scale"
printf '=== interpreter: %s (bash %s)%s ===\n' \
    "$TEST_INTERPRETER" "$interp_ver" \
    "$( [[ "$interp_parity" == differs ]] && printf ' — CI runs bash %s' "$ci_bash_ver" )"

start_ns=$(date +%s%N)
budget_stopped=0
# The DISPATCH's own exit status (your-org/nexus-code#877). Distinct from any
# test's verdict: this is "did the machinery that runs tests complete", and
# before #877 it was thrown away entirely on the parallel arm. `xargs` returns
# 123 when any child exits 1-125, 124 on a 255, 125 when a child is signalled,
# 126/127 when the command cannot be run — every one of which means some test
# did not produce a verdict. Discarding it is how a run in which NOTHING
# executed reported `0 failed` and exited 0.
dispatch_rc=0

if (( jobs > 1 )); then
    # Parallel: xargs gives us bounded concurrency without extra deps.
    if (( ${#tests[@]} > 0 )); then
        # CHECK mktemp, do not inline it into the argument list (#857). An
        # unchecked `$(mktemp …)` collapses to the empty string on failure and
        # hands run_one a base that resolves to the CHILD'S cwd. Inlined here
        # rather than factored into a helper on purpose: run_one's callees must
        # each be `export -f`'d for the parallel path (see the export block
        # below), and this needs no such coupling.
        printf '%s\n' "${tests[@]}" \
            | xargs -P "$jobs" -I{} bash -c \
                'o=$(mktemp -p "$2" out-XXXXXX) && [ -n "$o" ] || {
                     printf "run-tests.sh: mktemp failed in %s — skipping %s rather than\\n" "$2" "$1" >&2
                     printf "  writing its sidecars into %s (your-org/nexus-code#857)\\n" "$PWD" >&2
                     exit 97
                 }
                 run_one "$1" "$o"
                 # THE CHILD EXIT STATUS ANSWERS EXACTLY ONE QUESTION:
                 # did this child RECORD a verdict? Not "was the verdict good".
                 #
                 # run_one deliberately returns non-zero for FAIL and TIMEOUT
                 # (its last line is a PASS-or-SKIP test, so that --failed-only
                 # and the serial arm behave), which means an ORDINARY red made
                 # every child exit 1 and xargs return 123. Propagating that
                 # verbatim reported DISPATCH FAILED on every run containing a
                 # failing test — a true red with a false reason, which is the
                 # same disease as a false green: a verdict the runner did not
                 # earn. Caught by this suite CONTROL arm, and only after an
                 # empty-haystack bug stopped that control passing vacuously.
                 #
                 # By the time run_one RETURNS the verdict is already in the
                 # sidecars, so 0 is the honest answer. Anything that loses a
                 # verdict either never reaches this line (a signal) or never
                 # got here at all (the 97 above, or an unrunnable command), and
                 # those still surface — as a non-zero xargs status here, and
                 # independently as an accounted-vs-dispatched shortfall.
                 exit 0' _ {} "$run_dir"
        # CAPTURE IT. `${PIPESTATUS[1]}` rather than `$?` deliberately: this
        # file sets `pipefail`, under which `$?` happens to give the same
        # answer, but that makes the correctness of this line depend on a
        # `set -o` two hundred lines away. PIPESTATUS names the xargs slot
        # outright and keeps working if that option is ever changed. It must be
        # read on the line IMMEDIATELY after the pipeline — any intervening
        # command replaces it.
        dispatch_rc=${PIPESTATUS[1]}
    fi
else
    _budget_t0=$SECONDS
    for t in "${tests[@]:-}"; do
        [[ -n "$t" ]] || continue
        if (( max_seconds > 0 )) && (( SECONDS - _budget_t0 >= max_seconds )); then
            budget_stopped=1
            break
        fi
        # Same check as the parallel arm (#857). Serial failure is FATAL rather
        # than skip-one: with jobs=1 a broken run_dir will fail for every
        # remaining test, so continuing would emit one diagnostic per test and
        # still finish with a summary implying the run was performed.
        _out=$(mktemp -p "$run_dir" out-XXXXXX) || _out=""
        if [[ -z "$_out" ]]; then
            printf 'run-tests.sh: mktemp failed in %s — aborting.\n' "$run_dir" >&2
            printf '  Refusing to write sidecars into %s (your-org/nexus-code#857)\n' "$PWD" >&2
            exit 97
        fi
        run_one "$t" "$_out"
    done
fi

end_ns=$(date +%s%N)
total=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.2f", (e-s)/1e9}')

# Aggregate failure + timeout lists across the per-job files.
failed_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && failed_paths+=("$line")
done < <(find "$run_dir" -name '*.failed' -exec cat {} +)
timedout_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && timedout_paths+=("$line")
done < <(find "$run_dir" -name '*.timedout' -exec cat {} + 2>/dev/null)
# Files that PASSED but declined individual CASES (skeptic finding F1 on
# your-org/nexus-code#597). These are green and must stay green — but a reader
# of "ALL TESTS PASSED" has to be told which coverage was not actually taken.
caseskipped_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && caseskipped_paths+=("$line")
done < <(find "$run_dir" -name '*.caseskipped' -exec cat {} + 2>/dev/null | sort -u)

# Assertion accounting (your-org/nexus-code#693). Three quantities, kept
# separate on purpose — collapsing any two is how "green" reacquires the
# ambiguity this is meant to remove:
#   n_assert_total   how many assertions the run's passing files declared
#   nocount_paths    files whose footer this runner could not read at all
#   zerocount_paths  files that declared ZERO — a PASS asserting nothing
n_assert_total=0
while IFS= read -r line; do
    [[ "$line" =~ ^[0-9]+$ ]] && n_assert_total=$(( n_assert_total + line ))
done < <(find "$run_dir" -name '*.assertions' -exec cat {} + 2>/dev/null)
nocount_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && nocount_paths+=("$line")
done < <(find "$run_dir" -name '*.nocount' -exec cat {} + 2>/dev/null | sort -u)
zerocount_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && zerocount_paths+=("$line")
done < <(find "$run_dir" -name '*.zerocount' -exec cat {} + 2>/dev/null | sort -u)

# Persist failures for --failed-only on the next run (timeouts included —
# they are failures until they finish). Under --resume, MERGE with the
# still-unrun remainder so a budget-stopped sweep never shrinks the set.
if (( ${#failed_paths[@]} > 0 )); then
    printf '%s\n' "${failed_paths[@]}" > "$_failures_file"
else
    : > "$_failures_file"
fi

if (( profile )); then
    echo
    echo "=== per-file wall-time (sorted desc) ==="
    # Recompute by re-reading the status lines that were printed —
    # they include "PASS NAME  WALLs". Cheaper than tracking in arrays.
    # Skip — wall-time is already inline in each PASS/FAIL row above.
fi

# --- honest accounting (#499) ---------------------------------------------
# With a --state ledger, the tally is computed over the FULL selection:
# every selected test must terminate as PASS, FAIL, or TIMEOUT before the
# runner will read green. Anything unrecorded is reported as such — a
# test that never ran is not a pass.
n_pass=0; n_fail=0; n_timeout=0; n_skip=0; n_unrecorded=0
n_case_skips=0; n_case_skip_files=0
skipped_paths=()
if [[ -n "$tally_file" ]]; then
    # The ledger SUPERSEDES the per-job sidecars gathered above — it covers the
    # whole sweep including tests this invocation resumed past, and adding to
    # the sidecar totals instead of replacing them would double-count every
    # test that ran just now.
    n_assert_total=0; nocount_paths=(); zerocount_paths=()
    for t in "${all_selected[@]}"; do
        st=$(awk -F'\t' -v p="$t" '$1==p{s=$2} END{print s}' "$tally_file")
        cs=$(awk -F'\t' -v p="$t" '$1==p{s=$4} END{print s}' "$tally_file")
        [[ "$cs" =~ ^[0-9]+$ ]] || cs=0
        if (( cs > 0 )); then
            n_case_skips=$(( n_case_skips + cs ))
            n_case_skip_files=$(( n_case_skip_files + 1 ))
        fi
        # Assertion accounting from the LEDGER (#693), not the per-job
        # sidecars — under --resume the sidecars cover only this invocation,
        # while the ledger is the durable record of the whole sweep. A row
        # written by a pre-#693 runner has no field 5; that is `?`, the same
        # as an unreadable footer, and never silently 0.
        if [[ "$st" == PASS ]]; then
            as=$(awk -F'\t' -v p="$t" '$1==p{s=$5} END{print s}' "$tally_file")
            if [[ "$as" =~ ^[0-9]+$ ]]; then
                n_assert_total=$(( n_assert_total + as ))
                if (( as == 0 )); then zerocount_paths+=("$t"); fi
            else
                nocount_paths+=("$t")
            fi
        fi
        case "$st" in
            PASS)    n_pass=$(( n_pass + 1 )) ;;
            FAIL)    n_fail=$(( n_fail + 1 )) ;;
            TIMEOUT) n_timeout=$(( n_timeout + 1 )) ;;
            SKIP)    n_skip=$(( n_skip + 1 )); skipped_paths+=("$t") ;;
            *)       n_unrecorded=$(( n_unrecorded + 1 )) ;;
        esac
    done
    printf '=== ledger %s: %d PASS, %d SKIP, %d FAIL, %d TIMEOUT, %d not yet run (of %d selected; this invocation: %ss) ===\n' \
        "$tally_file" "$n_pass" "$n_skip" "$n_fail" "$n_timeout" "$n_unrecorded" \
        "${#all_selected[@]}" "$total"
    # The whole point of A6: PASS is now an evidence claim, so say plainly
    # how much of the selection produced no evidence at all.
    if (( n_skip > 0 )); then
        printf '=== %d of %d selected tests DECLINED TO RUN — the PASS count is not a coverage claim over them ===\n' \
            "$n_skip" "${#all_selected[@]}"
    fi
    # Same claim one level down (your-org/nexus-code#584 F1). A file that ran
    # and passed can still have declined individual CASES; `%d SKIP` above
    # counts only whole files (`exit 77`), so without this line a run whose
    # only uncovered assertion is a security check reads as an unqualified
    # pass. That is precisely how `#584`'s foreign-owner check could have gone
    # permanently unexercised behind `1 PASS, 0 SKIP`.
    if (( n_case_skips > 0 )); then
        printf '=== %d CASE(S) SKIPPED across %d passing file(s) — assertions that did NOT run; the PASS count is not a coverage claim over them ===\n' \
            "$n_case_skips" "$n_case_skip_files"
    fi
else
    # --- completeness BEFORE verdict (your-org/nexus-code#877) --------------
    # The ledger path above already refuses to call a run green while any
    # selected test is unrecorded (`n_unrecorded`, #499). This path — the one
    # `tests.yml`'s unit jobs take, at `--jobs 2` and `--jobs 4` — had no such
    # notion at all: it counted `.failed` rows and called the absence of them
    # zero failures. Those are not the same claim. `0 failed` derived from an
    # input set that was never written is not a verdict, it is a missing
    # measurement wearing a verdict's clothes, and it exits 0.
    #
    # Reproduced on this arm: with `mktemp -p` failing, both children exited 97
    # before running anything, and the runner printed `0 failed` and exited 0
    # for a run in which ZERO tests executed.
    #
    # So compare the two counts that must agree, and believe neither on its own.
    n_accounted=$(find "$run_dir" -name '*.accounted' -exec cat {} + 2>/dev/null \
                    | grep -c .) || n_accounted=0
    [[ "$n_accounted" =~ ^[0-9]+$ ]] || n_accounted=0
    n_dispatched=${#tests[@]}
    # How many tests REACHED a losing verdict, according to the record written
    # in the same breath as the printed row. TIMEOUT counts because its arm
    # writes `.failed` too, so the two sides compare like with like.
    n_acc_failed=$(find "$run_dir" -name '*.accounted' -exec cat {} + 2>/dev/null \
                     | awk -F'\t' '$2 == "FAIL" || $2 == "TIMEOUT"' | grep -c .) \
                   || n_acc_failed=0
    [[ "$n_acc_failed" =~ ^[0-9]+$ ]] || n_acc_failed=0

    # The tally line QUALIFIES ITSELF when it is short of its own denominator.
    # The `::error::` below would otherwise be the only correction, and it is
    # printed after — so anything that reads the summary line alone (a human
    # skimming, a log excerpt, a grep for `failed`) would still take away the
    # unqualified number. A count that is missing rows must say so where the
    # count is, not somewhere downstream of it.
    if (( budget_stopped == 0 )) && (( n_dispatched > 0 )) \
       && (( n_accounted < n_dispatched )); then
        printf '=== suite total: %ss across %d tests; %d failed — BUT ONLY %d of %d TESTS WERE MEASURED, so this is NOT a verdict (#877) ===\n' \
            "$total" "${#tests[@]}" "${#failed_paths[@]}" "$n_accounted" "$n_dispatched"
    else
        printf '=== suite total: %ss across %d tests; %d failed (%d of those TIMEOUT) ===\n' \
            "$total" "${#tests[@]}" "${#failed_paths[@]}" "${#timedout_paths[@]}"
    fi
    if (( ${#caseskipped_paths[@]} > 0 )); then
        printf '=== %d passing file(s) declined individual CASES — the pass count is not a coverage claim over them ===\n' \
            "${#caseskipped_paths[@]}"
    fi

    # `budget_stopped` is excluded because there the shortfall is INTENDED and
    # already reported as rc=3 below; folding it in here would relabel a known
    # partial run as a broken one.
    if (( budget_stopped == 0 )) && (( n_dispatched > 0 )) \
       && (( n_accounted < n_dispatched )); then
        printf '::error::ACCOUNTING INCOMPLETE — %d of %d dispatched test(s) produced NO verdict.\n' \
            "$(( n_dispatched - n_accounted ))" "$n_dispatched"
        echo "    The '$(printf '%d failed' "${#failed_paths[@]}")' above is computed from per-job sidecars under the run dir,"
        echo "    and those tests wrote none — so they are absent from the tally rather than"
        echo "    counted in it. An UNMEASURED run is not a passing run: refusing to exit 0."
        echo "    Look above for a per-test diagnostic (a failed mktemp, a vanished run dir,"
        echo "    a child killed before it could record). See your-org/nexus-code#877."
        _accounting_broken=1
    fi

    # THE VERDICT CHANNEL vs THE PRINTED ROWS (your-org/nexus-code#887 skeptic F1).
    # The check above reconciles the RECORD against DISPATCH, which catches every
    # loss point that destroys the record. It does not catch a SELECTIVE loss of
    # an outcome sidecar: `.accounted` still reconciles, `dispatch_rc` is still 0,
    # and a run that printed `FAIL` reports `0 failed` and exits 0 — `#877`'s
    # symptom surviving on a runner that had supposedly fixed it. Reproduced with
    # external ground-truth markers, on the non-ledger path, which is the path
    # `tests.yml`'s unit jobs take.
    #
    # Both sides here derive from writes made INSIDE run_one for the same test:
    # the status recorded beside the path, against the `.failed` rows the tally is
    # actually computed from. If they disagree, one of the two channels lost a
    # write, and the tally is the one that decides the exit code — so refuse.
    #
    # WHY THE LEDGER PATH HAS NO EQUIVALENT, and it is not an oversight: under
    # `--state` the ledger row is appended AFTER the outcome sidecars, so losing
    # a `.failed` still leaves the row, and the tally is computed from the ledger
    # rather than from the sidecars — the FAIL is counted either way. That path
    # is immune by WRITE ORDERING, not by this check. Measured, not assumed
    # (your-org/nexus-code#887 skeptic). Recorded here because an unexplained
    # asymmetry is an invitation to "fix" it by adding a second check that would
    # be pure cost, or worse, to reorder those writes and quietly remove the
    # immunity this note is describing.
    if (( budget_stopped == 0 )) && (( n_acc_failed != ${#failed_paths[@]} )); then
        printf '::error::VERDICT DISAGREES WITH THE RECORD — %d test(s) reached a losing verdict, but the tally counted %d.\n' \
            "$n_acc_failed" "${#failed_paths[@]}"
        echo "    The per-test rows printed above and the '=== suite total:' tally are"
        echo "    computed from DIFFERENT writes inside run_one. They just disagreed, so"
        echo "    one of them lost a write — and the tally is the one that sets the exit"
        echo "    code. A verdict computed from a channel that lost input is not a verdict."
        echo "    See your-org/nexus-code#877."
        _accounting_broken=1
    fi
fi

# The DISPATCH's own status, checked for BOTH accounting paths (#877). It is
# independent evidence from the counts above: a child can be signalled after
# writing its record, so the tallies reconcile while the run was still cut
# short. Checked here rather than at the dispatch site so it is adjacent to the
# verdict it invalidates.
if (( dispatch_rc != 0 )); then
    printf '::error::DISPATCH FAILED — the parallel dispatcher exited %d, so at least one test did not complete normally.\n' \
        "$dispatch_rc"
    case "$dispatch_rc" in
        123) echo "    123 = at least one child exited 1-125. run_one returns 0 for a test that" ;
             echo "          merely FAILED, so this is a child that could not run the test at all" ;
             echo "          (a refused mktemp exits 97 here)." ;;
        124) echo "    124 = a child exited 255." ;;
        125) echo "    125 = a child was killed by a signal." ;;
        126) echo "    126 = the dispatched command was found but could not be executed." ;;
        127) echo "    127 = the dispatched command was not found." ;;
        *)   echo "    (see xargs(1) for the meaning of this status)" ;;
    esac
    echo "    Either way the affected test's verdict is MISSING from the tally above"
    echo "    rather than counted in it. Refusing to exit 0. See your-org/nexus-code#877."
    _accounting_broken=1
fi

# --- assertion accounting (your-org/nexus-code#693) ------------------------
# Printed for BOTH accounting paths, because the question it answers — "how
# much did this green actually assert?" — is the same either way. Before this,
# `PASS test-svc.sh 15.96s` was the entire record a green CI run left behind,
# and a suite that ran 108 assertions was typographically identical to one that
# ran none.
printf '=== assertions: %d declared across the run; %d file(s) declared no machine-readable count ===\n' \
    "$n_assert_total" "${#nocount_paths[@]}"

# HARNESS GUARD. `?` was designed as the loud value — and it is not loud enough,
# because "this runner could not read the footer" and "this runner could not RUN"
# render identically. When _rt_declared_assertions was missing from every
# parallel child, all 245 suites read `?` and the footer said `0 declared`: a
# plausible number, printed with total confidence, on a green run.
#
# Every one of the repo's 248 suites declares a count, so EVERY passing file
# reading `?` is not 248 simultaneous corpus regressions — it is the harness.
# Say so and go RED. A per-file `?` stays a normalisation note; only the
# all-of-them case is an error, so normalisation debt never turns a run red.
if [[ -n "$tally_file" ]]; then
    _n_pass_files="$n_pass"
else
    # Exactly the files this run measured: one `.assertions` line each for the
    # readable ones, one `.nocount` path each for the rest. Derived from the
    # same sidecars the totals come from, so the guard cannot disagree with the
    # number it is guarding.
    _n_pass_files=$(( $(find "$run_dir" -name '*.assertions' -exec cat {} + 2>/dev/null | wc -l) \
                      + ${#nocount_paths[@]} ))
fi
# FLOOR, and it is not arbitrary decoration. "Every suite declares a count" is
# true of THIS REPO'S 248 suites — it is emphatically not true of the throwaway
# fixtures a test feeds this runner. test-run-tests-bounded.sh drives it with
# `ok-a.sh`-style scripts that print nothing at all, and an unfloored guard
# turned six of its assertions red: a guard against a false green that
# manufactures a false red. Caught locally, before this shipped, only because
# that suite was re-run after an unrelated timeout.
#
# The class this guards (a helper missing from the parallel children) manifests
# in EVERY run, so it is always visible at band scale; the floor costs nothing
# against it. 20 is comfortably above any fixture set in this repo and far below
# the 248-suite band.
: "${NEXUS_ASSERT_ACCOUNTING_FLOOR:=20}"
if (( _n_pass_files >= NEXUS_ASSERT_ACCOUNTING_FLOOR \
      && ${#nocount_paths[@]} >= _n_pass_files )); then
    printf '::error::ASSERTION ACCOUNTING IS BROKEN — all %d passing file(s) read as `?`.\n' \
        "$_n_pass_files"
    echo "    Not a corpus finding: every suite in this repo declares a count, so"
    echo "    'none of them could be read' means the reader did not run. The first"
    echo "    instance was _rt_declared_assertions missing from the --jobs N>1"
    echo "    children (your-org/nexus-code#693 follow-up); check the run log above"
    echo "    for 'command not found'."
    _assert_harness_broken=1
fi
if (( ${#zerocount_paths[@]} > 0 )); then
    # The loud one. A suite that declares ZERO exits 0 and prints `ALL TESTS
    # PASSED`; nothing else in this output distinguishes it from a real pass.
    # test-public-guard-refusal.sh does exactly this on a source tree.
    printf '=== %d passing file(s) declared ZERO assertions — a PASS that asserts nothing ===\n' \
        "${#zerocount_paths[@]}"
    for f in "${zerocount_paths[@]}"; do printf '    0 assertions: %s\n' "$f"; done
fi
if (( ${#nocount_paths[@]} > 0 )); then
    # NOT a coverage finding: measured over all 248 suites, every one of them
    # declares a count — in one of twelve spellings. These are the ones this
    # runner cannot read, so this list is a NORMALISATION checklist, and it is
    # the honest form of the answer: a number derived by guessing at spellings
    # offline was wrong three times in a row while this was being built.
    printf '    (footer spelling unread by the runner — normalisation debt, not missing coverage)\n'
    for f in "${nocount_paths[@]}"; do printf '    assertions ?: %s\n' "$f"; done
fi

if [[ -n "${KEEP_LOGS_DIR:-}" ]]; then
    printf 'per-test logs kept under: %s\n' "$KEEP_LOGS_DIR"
fi

if (( ${#timedout_paths[@]} > 0 )); then
    echo
    echo "TIMED OUT (never finished — NOT passes; raise --timeout or fix the test, #499):"
    for f in "${timedout_paths[@]}"; do
        printf '  %s\n' "$f"
    done
fi
if (( ${#skipped_paths[@]} > 0 )); then
    echo
    echo "SKIPPED (declined to run — asserted nothing; NOT passes, #568 A6):"
    for f in "${skipped_paths[@]}"; do
        printf '  %s\n' "$f"
    done
fi
if (( ${#caseskipped_paths[@]} > 0 )); then
    echo
    echo "PASSED but with SKIPPED CASES (green; individual assertions did NOT run):"
    for f in "${caseskipped_paths[@]}"; do
        printf '  %s\n' "$f"
    done
    echo "  ^ each row above printed its own SKIP reason inline; a precondition"
    echo "    the host could not supply means that coverage was NOT taken."
fi
if (( ${#failed_paths[@]} > 0 )); then
    echo
    echo "Failed tests (re-run with --failed-only):"
    for f in "${failed_paths[@]}"; do
        printf '  %s\n' "$f"
    done
fi

# --- interpreter coverage boundary (your-org/nexus-code#610) ---------------
# Printed LAST, on green runs too, because green is exactly when it matters: a
# reader who has just seen every test pass is the one about to conclude the
# change is safe. The suite cannot test a shell it is not running, so it says
# which one it ran instead of leaving the reader to assume it was CI's.
echo
case "$interp_parity" in
    match)
        printf '=== interpreter parity: bash %s, the same major.minor CI runs — shell-version-dependent behaviour IS covered by this run ===\n' \
            "$interp_ver"
        ;;
    differs)
        printf '=== COVERAGE BOUNDARY: this run took its evidence under bash %s; CI runs bash %s ===\n' \
            "$interp_ver" "$ci_bash_ver"
        echo "    Behaviour that differs between those two majors/minors was NOT tested here,"
        echo "    and a pass above is not a claim about it. This is not hypothetical: the"
        echo "    #597 fork-floor defect existed ONLY on 5.2 and could not be reproduced on"
        echo "    4.4 even in principle, and patsub_replacement (5.2-default) silently"
        echo "    corrupted generated gh stubs the same way."
        echo "    To close the gap locally:"
        echo "      NEXUS_TEST_SHELL=\$(monitor/toolchain-bash.sh --print-path) \\"
        echo "          monitor/watcher/run-tests.sh <same args>"
        echo "    To make a mismatch FAIL rather than merely declare: --require-ci-parity"
        ;;
    *)
        printf '=== COVERAGE BOUNDARY: ran under bash %s; CI-s pinned version is UNKNOWN (monitor/ci-bash-version unreadable) ===\n' \
            "$interp_ver"
        echo "    Parity with CI could not be evaluated, so this run makes no claim about it."
        ;;
esac

# Exit contract: 3 = incomplete (budget stop and/or unrecorded remainder
# under a ledger) — resume with the same command; 1 = complete but red,
# which since #877 includes "the accounting and the verdict disagreed" —
# a failed test and an unmeasured one are both reasons not to merge;
# 0 = complete and green.
# BROKEN BEATS INCOMPLETE (your-org/nexus-code#877). The `_accounting_broken`
# clause is a precedence rule, not an extra condition. Under a `--state` ledger
# a lost verdict ALSO shows up as `n_unrecorded > 0`, so without this the run
# would take the arm below and exit 3 — whose contract is "budget stopped this
# invocation, resume with the same command". Resuming does not repair a refused
# `mktemp` or a destroyed run dir, so that would hand the caller a confident and
# actionable instruction that cannot work, and `tests-slow-integration.yml`
# would report it as an exhausted serial budget. An incomplete run is resumable;
# a run whose accounting broke is not, and must read as red.
if { (( budget_stopped )) || { [[ -n "$tally_file" ]] && (( n_unrecorded > 0 )); }; } \
   && (( ${_accounting_broken:-0} == 0 )); then
    echo
    printf 'INCOMPLETE: budget/ceiling stopped this invocation with %d test(s) unaccounted.\n' \
        "$( [[ -n "$tally_file" ]] && printf '%d' "$n_unrecorded" || printf '%d' 0 )"
    echo "Resume with the SAME command (add --state <file> --resume if you had none) until exit != 3."
    exit 3
fi
if [[ -n "$tally_file" ]]; then
    (( n_fail == 0 && n_timeout == 0 && ${_assert_harness_broken:-0} == 0 \
       && ${_accounting_broken:-0} == 0 )) && exit 0
    exit 1
fi
(( ${#failed_paths[@]} > 0 )) && exit 1
(( ${_assert_harness_broken:-0} > 0 )) && exit 1
# ACCOUNTING BREAKDOWN IS RED (your-org/nexus-code#877), and it is deliberately
# 1 rather than a new code. 1 already means "do not merge this" to every caller
# — `tests.yml`, `ci-signal.yml`, the slow band, and any human reading a red X —
# whereas a fourth code would be correctly classified only by callers that had
# been taught it, and the cost of being wrong here is a green that should have
# been red. 3 was rejected for the opposite reason: it is not a free slot but a
# live instruction, `tests-slow-integration.yml` treats it as "budget exhausted,
# the ledger is PARTIAL, resume" — and resuming does not repair a broken
# mktemp, so reusing it would emit a false diagnosis and invite a retry loop.
(( ${_accounting_broken:-0} > 0 )) && exit 1
exit 0
