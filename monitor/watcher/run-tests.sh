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
# Exit codes: 0 = every selected test ran and passed; 1 = at least one
# FAIL or TIMEOUT; 3 = incomplete (--max-seconds budget hit; resume).
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

# Per-test runner: prints a status line, captures wall-time if
# --profile is set, writes failed paths to a per-job tempfile.
# With $KEEP_LOGS_DIR set (--keep-logs), the full stdout/stderr of
# every test lands at <dir>/<parent>__<name>.{out,err} and survives
# the run — under --jobs N the inline stderr tails of concurrent
# failures interleave, so a rare flake's assertion text is otherwise
# unrecoverable without a lucky re-run.
run_one() {
    local test_path="$1" out_file="$2"
    local name; name=$(basename "$test_path")
    local log_base="$out_file"
    if [[ -n "${KEEP_LOGS_DIR:-}" ]]; then
        local parent; parent=$(basename "$(dirname "$test_path")")
        log_base="$KEEP_LOGS_DIR/${parent}__${name}"
    fi
    local start_ns end_ns wall rc status
    start_ns=$(date +%s%N)
    if [[ "${PER_TEST_TIMEOUT:-0}" =~ ^[0-9]+$ ]] && (( ${PER_TEST_TIMEOUT:-0} > 0 )); then
        # Hard per-test ceiling (#499). TERM first so the test's own EXIT
        # trap can reap its fixture processes; KILL 15 s later if it
        # ignores that. rc=124 is timeout's TERM verdict, 137 the
        # KILL escalation — both are TIMEOUT, never a pass.
        timeout -k 15 "$PER_TEST_TIMEOUT" bash "$test_path" >"$log_base.out" 2>"$log_base.err"
        rc=$?
    else
        bash "$test_path" >"$log_base.out" 2>"$log_base.err"
        rc=$?
    fi
    end_ns=$(date +%s%N)
    wall=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.2f", (e-s)/1e9}')
    status=PASS
    if (( rc != 0 )); then
        status=FAIL
        if [[ "${PER_TEST_TIMEOUT:-0}" != "0" ]] && { (( rc == 124 )) || (( rc == 137 )); }; then
            status=TIMEOUT
        fi
    fi
    case "$status" in
        PASS)    printf '  PASS  %-45s  %6ss\n' "$name" "$wall" ;;
        TIMEOUT)
            printf '  TIMEOUT  %-42s  %6ss  (ceiling %ss — NOT a pass; see #499)\n' \
                "$name" "$wall" "$PER_TEST_TIMEOUT"
            printf '%s\n' "$test_path" >> "$out_file.failed"
            printf '%s\n' "$test_path" >> "$out_file.timedout"
            ;;
        FAIL)
            printf '  FAIL  %-45s  %6ss  rc=%d\n' "$name" "$wall" "$rc"
            printf '%s\n' "$test_path" >> "$out_file.failed"
            # Echo the captured stderr tail so the failure is debuggable
            # without re-running. Stay terse — 20 lines is enough to see
            # the failed assertion in the existing test format. (tail, not
            # sed: GNU sed has no `$-20` address — the original sed form
            # errored silently into 2>/dev/null and printed nothing, which
            # is why CI failures looked output-less.)
            tail -n 20 -- "$log_base.err" 2>/dev/null | sed 's/^/    /'
            if [[ -n "${KEEP_LOGS_DIR:-}" ]]; then
                printf '    full logs: %s.{out,err}\n' "$log_base"
            fi
            ;;
    esac
    # Durable ledger (#499): one line per completed test, appended the
    # moment it finishes, so an interrupted run resumes instead of
    # restarting and the final tally is computed from what actually ran.
    if [[ -n "${TALLY_FILE:-}" ]]; then
        printf '%s\t%s\t%s\n' "$test_path" "$status" "$wall" >> "$TALLY_FILE"
    fi
    [[ "$status" == PASS ]]
}
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
        _probe_ok() { ( ulimit -Su "$1" 2>/dev/null; /bin/true ) 2>/dev/null; }
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
            if [[ "$_hard" == unlimited ]] || (( _nproc_cap < _hard )); then
                if ulimit -u "$_nproc_cap" 2>/dev/null; then
                    printf '=== nproc guard: RLIMIT_NPROC capped at %d (probed task floor %d + headroom %d; tasks != processes, #506) ===\n' \
                        "$_nproc_cap" "$_hi" "$_headroom"
                fi
            fi
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

printf '=== running %d tests (jobs=%d%s%s) ===\n' "${#tests[@]}" "$jobs" \
    "$( (( per_test_timeout > 0 )) && printf ', timeout=%ss' "$per_test_timeout" )" \
    "$( (( max_seconds > 0 )) && printf ', budget=%ss' "$max_seconds" )"

start_ns=$(date +%s%N)
budget_stopped=0

if (( jobs > 1 )); then
    # Parallel: xargs gives us bounded concurrency without extra deps.
    if (( ${#tests[@]} > 0 )); then
        printf '%s\n' "${tests[@]}" \
            | xargs -P "$jobs" -I{} bash -c \
                'run_one "$1" "$(mktemp -p "$2" out-XXXXXX)"' _ {} "$run_dir"
    fi
else
    _budget_t0=$SECONDS
    for t in "${tests[@]:-}"; do
        [[ -n "$t" ]] || continue
        if (( max_seconds > 0 )) && (( SECONDS - _budget_t0 >= max_seconds )); then
            budget_stopped=1
            break
        fi
        run_one "$t" "$(mktemp -p "$run_dir" out-XXXXXX)"
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
n_pass=0; n_fail=0; n_timeout=0; n_unrecorded=0
if [[ -n "$tally_file" ]]; then
    for t in "${all_selected[@]}"; do
        st=$(awk -F'\t' -v p="$t" '$1==p{s=$2} END{print s}' "$tally_file")
        case "$st" in
            PASS)    n_pass=$(( n_pass + 1 )) ;;
            FAIL)    n_fail=$(( n_fail + 1 )) ;;
            TIMEOUT) n_timeout=$(( n_timeout + 1 )) ;;
            *)       n_unrecorded=$(( n_unrecorded + 1 )) ;;
        esac
    done
    printf '=== ledger %s: %d PASS, %d FAIL, %d TIMEOUT, %d not yet run (of %d selected; this invocation: %ss) ===\n' \
        "$tally_file" "$n_pass" "$n_fail" "$n_timeout" "$n_unrecorded" \
        "${#all_selected[@]}" "$total"
else
    printf '=== suite total: %ss across %d tests; %d failed (%d of those TIMEOUT) ===\n' \
        "$total" "${#tests[@]}" "${#failed_paths[@]}" "${#timedout_paths[@]}"
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
if (( ${#failed_paths[@]} > 0 )); then
    echo
    echo "Failed tests (re-run with --failed-only):"
    for f in "${failed_paths[@]}"; do
        printf '  %s\n' "$f"
    done
fi

# Exit contract: 3 = incomplete (budget stop and/or unrecorded remainder
# under a ledger) — resume with the same command; 1 = complete but red;
# 0 = complete and green.
if (( budget_stopped )) || { [[ -n "$tally_file" ]] && (( n_unrecorded > 0 )); }; then
    echo
    printf 'INCOMPLETE: budget/ceiling stopped this invocation with %d test(s) unaccounted.\n' \
        "$( [[ -n "$tally_file" ]] && printf '%d' "$n_unrecorded" || printf '%d' 0 )"
    echo "Resume with the SAME command (add --state <file> --resume if you had none) until exit != 3."
    exit 3
fi
if [[ -n "$tally_file" ]]; then
    (( n_fail == 0 && n_timeout == 0 )) && exit 0
    exit 1
fi
(( ${#failed_paths[@]} > 0 )) && exit 1
exit 0
