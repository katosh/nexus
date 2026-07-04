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
#   monitor/watcher/run-tests.sh path/to/test.sh ...  # explicit paths
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
# Exit code: 0 if every selected test exits 0, 1 otherwise.
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
    local start_ns end_ns wall rc
    start_ns=$(date +%s%N)
    bash "$test_path" >"$log_base.out" 2>"$log_base.err"
    rc=$?
    end_ns=$(date +%s%N)
    wall=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.2f", (e-s)/1e9}')
    if (( rc == 0 )); then
        printf '  PASS  %-45s  %6ss\n' "$name" "$wall"
    else
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
    fi
    return $rc
}
export -f run_one

# Common temp dir for per-run outputs.
run_dir=$(mktemp -d -t nexus-test-runner-XXXXXX)
trap 'rm -rf "$run_dir"' EXIT
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

printf '=== running %d tests (jobs=%d) ===\n' "${#tests[@]}" "$jobs"

start_ns=$(date +%s%N)

if (( jobs > 1 )); then
    # Parallel: xargs gives us bounded concurrency without extra deps.
    printf '%s\n' "${tests[@]}" \
        | xargs -P "$jobs" -I{} bash -c \
            'run_one "$1" "$(mktemp -p "$2" out-XXXXXX)"' _ {} "$run_dir"
else
    for t in "${tests[@]}"; do
        run_one "$t" "$(mktemp -p "$run_dir" out-XXXXXX)"
    done
fi

end_ns=$(date +%s%N)
total=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.2f", (e-s)/1e9}')

# Aggregate failure list across the per-job .failed files.
failed_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && failed_paths+=("$line")
done < <(find "$run_dir" -name '*.failed' -exec cat {} +)

# Persist failures for --failed-only on the next run.
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

printf '=== suite total: %ss across %d tests; %d failed ===\n' \
    "$total" "${#tests[@]}" "${#failed_paths[@]}"

if [[ -n "${KEEP_LOGS_DIR:-}" ]]; then
    printf 'per-test logs kept under: %s\n' "$KEEP_LOGS_DIR"
fi

if (( ${#failed_paths[@]} > 0 )); then
    echo
    echo "Failed tests (re-run with --failed-only):"
    for f in "${failed_paths[@]}"; do
        printf '  %s\n' "$f"
    done
    exit 1
fi

exit 0
