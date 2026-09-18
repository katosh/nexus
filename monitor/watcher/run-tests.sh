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
#   monitor/watcher/run-tests.sh --timeout 600  # per-test ceiling, +15s KILL
#                                               # grace; rc=124 (TERM) or 137
#                                               # (KILL). Tallied + printed as
#                                               # TIMEOUT (never a pass, never
#                                               # omitted). NOT a hard ceiling:
#                                               # a test that ignores TERM runs
#                                               # up to <timeout>+15s and the
#                                               # reported wall includes it
#                                               # (your-org/nexus-code#1041).
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
# EXIT CODES:
#   0  complete and green
#   1  complete and RED — a test failed, or the accounting and the verdict
#      disagreed (your-org/nexus-code#877)
#   2  usage error (bad flag, unwritable --state, …)
#   3  INCOMPLETE and RESUMABLE — --max-seconds stopped this invocation, or a
#      ledger still holds unrecorded tests. Repeat the same command.
#   4  NOT A VERDICT — one or more DISPATCH CHILDREN were killed by a signal,
#      so this run measured a SUBSET (your-org/nexus-code#1083). A signal is an
#      environment event, not a test result; the pass count and the failure
#      list are both lower bounds. Re-run. Distinct from 1 precisely so
#      "the machine interrupted the sweep" cannot be read as "your code is
#      broken", and from 3 because resuming does not repair a machine that is
#      killing the batch.
#
#      TWO BOUNDARIES, both stated because the first draft of this line was
#      honest and false (#1135 skeptic F3, F4):
#
#      (a) PARALLEL ARM ONLY. The traps live in the `xargs` child, which
#          exists only at `--jobs > 1`. At `--jobs 1` `run_one` executes in
#          this shell, there is no child to trap, and exit 4 is STRUCTURALLY
#          UNREACHABLE — so #1083's rc conflation persists there, undeclared
#          until now. Measured with the same fixture that yields exit 4 at
#          `--jobs 4`: at `--jobs 1` the runner is itself in the signal's path
#          and dies **rc=143**, printing no banner and no summary at all. That
#          arm has no truncation to fix (no `xargs` means no batch to abort),
#          but a caller reading this contract must not infer that a serial run
#          distinguishes an environment event from a test result. It does not,
#          and under a direct signal it does not report anything either.
#
#      (b) "DISPATCH CHILD", NOT "TEST PROCESS". A TEST killed by a signal
#          returns 128+N to `run_one`, which records it as FAIL (or TIMEOUT
#          under `--timeout`) and the run exits 1 — correctly, because the
#          verdict was still recorded. Measured: a test doing `kill -TERM $$`
#          prints `FAIL <name> rc=143`, the run exits 1, and NO sweep-interrupted
#          banner appears. Exit 4 fires only when the child that
#          was RUNNING a test died before recording anything. The earlier
#          wording said "test processes were killed by a signal", which names
#          the wrong process and describes a case that exits 1.
#  97  the runner refused to write its sidecars (a failed mktemp, #857)
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
# STATUSES: PASS · SKIP · ENVSKIP · FAIL · TIMEOUT. A test that DECLINES TO RUN
# exits 77 and is tallied SKIP (your-org/nexus-code#568 A6); a test that RAN,
# ASSERTED, and then found the MACHINE unable to supply what it needed exits 69
# (EX_UNAVAILABLE) and is tallied ENVSKIP (your-org/nexus-code#1283). Those are
# opposite facts wanting opposite actions and they used to share exit 77: SKIP
# accuses the HARNESS (the SLOW_TESTS gate did not take, so the suite left the
# band silently) and must stay loud, while an ENVSKIP accuses nothing and is
# evidence of neither side. Neither reds the runner; in the blocking slow band
# `monitor/slow-band-drift.sh` scores an ENVSKIP rc 4 ENV-UNPROVEN — explicitly
# not a clearance — while a plain SKIP there stays NEW-RED. Before that third state
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
# The repo tree this runner belongs to, with a TRAILING SLASH so the prefix test
# in `_rt_path_in_repo` cannot match a sibling directory whose name merely starts
# the same way (your-org/nexus-code#1277). EXPORTED because the parallel arm's
# `bash -c` children evaluate the predicate and would otherwise see it unset —
# which reads as "not in the repo" and silently disarms the gate.
_RT_REPO_ROOT=$(cd "$_self_dir/../.." 2>/dev/null && pwd -P) || _RT_REPO_ROOT=""
export _RT_REPO_ROOT
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
            # THE WHOLE HEADER BLOCK, not a hardcoded range (found sweeping the
            # #1031/#997 class). This was `sed -n '2,19p'` against a comment
            # block that has since grown to line 65, so `--help` ended
            # mid-sentence at "--resume skips already-recorded" and silently
            # omitted --max-seconds, --require-ci-parity, the explicit-paths
            # form, the STATUSES paragraph and THE ENTIRE EXIT-CODE CONTRACT.
            # Same class as the rest of this branch: a label (`--help`, "print
            # usage") whose definition (lines 2-19) had drifted from it, with
            # nothing in the output saying it was truncated. Derived from the
            # block's actual extent, so it cannot drift again.
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
                "${BASH_SOURCE[0]}"
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

# AN AMBIENT NEXUS_STATE_DIR IS A BEHAVIOURAL CHANGE TO EVERY SUITE THAT
# ARRANGES ITS OWN STATE DIR (your-org/nexus-code#1386). Arm 1 of `ng`'s
# resolver chain is the only unconditional one — that is what makes pinning it
# right for a one-off PROBE (#1349) and wrong as the environment of a SUITE
# RUN: the pin overrides whatever the suite built for itself, and the red that
# follows is indistinguishable from a defect in the reader's own diff. Measured
# on one suite, one variable: 93/0 clean, 91/2 under an ambient pin; and a full
# band under a pin outside the checkout read 40/58 where the correct config
# read 91/0. Said ONCE, up front, so the reader of a red below has the cause
# beside it — not refused, because CI never sets it and a suite that pins its
# own is immune (the fix for a suite this bites is to pin its own arm 1).
if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    printf 'run-tests.sh: WARNING — NEXUS_STATE_DIR=%s is set in the AMBIENT environment (your-org/nexus-code#1386).\n' "$NEXUS_STATE_DIR" >&2
    printf '  It is arm 1 of the state resolver and unconditional, so it OVERRIDES every suite that arranges its own\n' >&2
    printf '  state dir. A red below is not evidence about the tree until the run is repeated WITHOUT it.\n' >&2
    printf '  Pin NEXUS_STATE_DIR for a one-off probe; never for a suite run.\n' >&2
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
# SHAPE, not emptiness (your-org/nexus-code#1382): under zsh both expansions
# are empty and the format string still emits its literal `.`, so `interp_ver`
# is "." — non-empty — and an emptiness check let zsh through with a banner
# reading `(bash .)`. zsh is the interpreter this workspace defaults to for
# agents, so it is the one non-bash interpreter most likely to arrive here.
if [[ ! "$interp_ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
    printf 'run-tests.sh: %q did not report a BASH_VERSINFO (got %q) — is it bash?\n' \
        "$TEST_INTERPRETER" "$interp_ver" >&2
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
# ---------------------------------------------------------------------------
# tmux SOCKET-PATH CEILING — refuse the RUN, not the suite
# (your-org/nexus-code#991)
# ---------------------------------------------------------------------------
#
# A `TMUX_TMPDIR` too long for `sun_path` is a property of the RUN, not of any
# suite: every real-tmux suite in the dispatch list is already doomed before
# the first one starts, and each will report a FAIL that reads as a defect in
# the code it tests. Five did exactly that in one session; five attributions
# were wrong and one published finding was retracted.
#
# So the check belongs HERE, where it is asked ONCE and can refuse before
# anything runs. `th_require_tmux_socket` (in `_test_helpers.sh`) is the same
# rule one level down, for a suite invoked directly rather than through this
# runner; neither subsumes the other.
#
# THE RESERVE, and why this gate is deliberately weaker than the per-suite one.
# The runner cannot know the socket NAME a suite will choose, so it checks
# whether the DIRECTORY leaves room for one. `_TMUX_SOCKNAME_RESERVE` is 40,
# chosen against the measured corpus maximum of 33 bytes — the longest socket
# name at this ref is `nexus-pane-state-140-<pid>-<random>`
# (`monitor/watcher/test-pane-state.sh:1538`). A suite that invents a longer
# name can therefore still straddle the limit after this gate passes, which is
# precisely what `th_require_tmux_socket` is for: it takes the real name and
# measures the real path.
#
# EXIT 2, the runner's established "refuse to run" code, because nothing has
# been dispatched and no verdict exists to report. Override with
# NEXUS_TMUX_SOCKET_CHECK=off for an environment that has a long TMUX_TMPDIR
# on purpose and runs no tmux suite.
_TMUX_SOCKNAME_RESERVE=40
if [[ "${NEXUS_TMUX_SOCKET_CHECK:-on}" != off ]]; then
    . "$_self_dir/../_tmux_socket.sh"
    _tt_dir="${TMUX_TMPDIR:-/tmp}"
    # The longest path this directory could ever produce for a socket name of
    # the reserve length. Composed through the same function the suites use,
    # so the gate cannot drift from the thing it gates.
    _tt_probe=$(printf 'x%.0s' $(seq 1 "$_TMUX_SOCKNAME_RESERVE"))
    _tt_len=$(tmux_socket_len "$_tt_probe" "$_tt_dir")
    if (( _tt_len > TMUX_SUN_PATH_MAX )); then
        {
            printf 'run-tests.sh: REFUSED — TMUX_TMPDIR cannot host a tmux socket.\n'
            printf '  TMUX_TMPDIR      : %s\n' "${TMUX_TMPDIR:-<unset> (tmux falls back to /tmp)}"
            printf '  worst-case path  : %s bytes; the usable maximum is %s\n' \
                   "$_tt_len" "$TMUX_SUN_PATH_MAX"
            printf '  why              : sun_path is 108 bytes, and 107 is the most a\n'
            printf '                     NUL-terminating caller (tmux, python) can bind. tmux\n'
            printf '                     composes\n'
            printf '                     ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket-name>, and this\n'
            printf '                     directory leaves no room for a %s-byte name.\n' "$_TMUX_SOCKNAME_RESERVE"
            printf '  what would happen: every real-tmux suite would fail `File name too long`\n'
            printf '                     and report it as a defect in the code under test.\n'
            printf '                     That cost five wrong attributions and one retracted\n'
            printf '                     finding (your-org/nexus-code#991).\n'
            printf '  remedy           : export TMUX_TMPDIR=%s && mkdir -p "$TMUX_TMPDIR"\n' \
                   "$(tmux_socket_short_tmpdir "$$")"
            printf '  override         : NEXUS_TMUX_SOCKET_CHECK=off (only if this run selects\n'
            printf '                     no suite that starts a tmux server).\n'
        } >&2
        exit 2
    fi
    unset _tt_dir _tt_probe _tt_len
fi

# ---- the per-suite PRIVATE ROOT: its contract, and the sweep that survives a
#      SIGKILL (your-org/nexus-code#1481, #1423) -------------------------------
#
# Every suite is handed ONE private directory as both TMPDIR and TMUX_TMPDIR
# (see run_one). Four suites depend on properties of that directory in four
# different ways, and none of them said so until all six CI bands went red:
# tmux fixtures need the path SHORT (108-byte sun_path); one suite asserts its
# fixture is under /tmp; one caps a diagnostic at 300 B; one's suite-name
# classifier met a path ELEMENT spelled like a suite file (`test-x.sh.tmp`) —
# the documented family of a scanner meeting its own pattern in a name.
# So the contract is asserted HERE, directly, and the runner REFUSES a root
# that violates it rather than letting four suites fail four different ways:
#   (1) under NEXUS_TEST_PRIVATE_ROOT_BASE (default /tmp) — a seam so a test
#       can plant a violation and watch this refuse;
#   (2) at most _RT_PRIVATE_ROOT_MAX bytes;
#   (3) no path element matching the suite-file pattern `test-*.sh*`.
_RT_PRIVATE_ROOT_BASE="${NEXUS_TEST_PRIVATE_ROOT_BASE:-/tmp}"
_RT_PRIVATE_ROOT_MAX=40
_rt_private_root_violation() {   # <path> -> prints the reason, rc 1; silent rc 0 when compliant
    local p="$1" el rest
    case "$p" in "$_RT_PRIVATE_ROOT_BASE"/nxt-*) ;; *) printf 'not under %s/nxt-*' "$_RT_PRIVATE_ROOT_BASE"; return 1 ;; esac
    if (( ${#p} > _RT_PRIVATE_ROOT_MAX )); then printf '%d bytes, more than %d' "${#p}" "$_RT_PRIVATE_ROOT_MAX"; return 1; fi
    rest="${p#/}"
    while [[ -n "$rest" ]]; do
        el="${rest%%/*}"; rest="${rest#"$el"}"; rest="${rest#/}"
        case "$el" in test-*.sh*) printf 'path element %q is spelled like a suite file' "$el"; return 1 ;; esac
    done
    return 0
}
# A `trap EXIT` does not survive SIGKILL, and a band cancelled at its ceiling
# IS a SIGKILL — three of four refs hit it in one night. On CI the runner VM
# dies with the leak; on an operator's host the root persists, holding the
# suite's whole fixture tree, which is the #1423 leak in a new place with a
# bigger payload. So stale roots are swept at every runner start.
#
# THE IDENTITY IN THE NAME IS THE TOP-LEVEL RUNNER'S PID, AND LIVENESS IS THE
# WHOLE PREDICATE. The first cut named roots with `$$` and classified a live
# pid by its cmdline ("is it a run-tests.sh?"). Both were wrong for the same
# reason (#851's shape — a cleanup keyed on a name-ish proxy reaping a
# sibling's live work): under `--jobs N` run_one is an xargs `bash -c` child,
# so `$$` was the CHILD's pid and its cmdline was `bash -c run_one …` — a live
# root that "did not look like a runner", eligible for rm -rf by ANOTHER
# runner's start-up sweep on this shared /tmp, i.e. one agent's suites losing
# their fixtures mid-run because a second agent started a test run. So:
#   * every root carries _RT_RUNNER_PID — the top-level runner's pid, exported
#     across the xargs boundary — so the pid in the name is one whose death
#     means the run is over, serial or parallel ($RANDOM disambiguates);
#   * a root is reaped ONLY when that pid is positively GONE (no /proc entry)
#     AND the root is older than the floor. A live pid keeps its root whatever
#     its cmdline says — "alive but not recognisably a runner" is AMBIGUOUS
#     (recycled, or an owner we cannot name), and ambiguity keeps. A recycled
#     pid therefore defers the reap until that process, too, is gone; that is
#     a bounded leak, not a deleted live fixture.
#   * no /proc at all (no /proc/self) → no sweep: everything would look gone.
# TWO STATED BOUNDARIES (w225 skeptic F5). The predicate sees the NAMER, not
# the USERS: a SIGKILLed runner can leave `timeout -k 15` + a suite alive to
# their own ceiling (`ceiling-overrides.tsv` carries 1200 s against this 600 s
# floor), so a sibling runner starting in that window can reap a root a live
# suite is still using — narrower than the hole it replaced, and named rather
# than hidden. And pid liveness is read from /proc, so the predicate assumes
# the pid namespace and /tmp are CO-SCOPED (true in this sandbox: `/tmp` is a
# per-container tmpfs); a host that bind-mounts a shared /tmp into a
# pid-unshared container would see every foreign pid as "gone".
# Under-reaping is the safe direction; this is a sweeper, not a reaper.
# The parallel arm runs run_one in `export -f`'d children: the predicate and
# its knobs must cross that boundary too, or the children see an EMPTY base
# and refuse every root (measured: "under /nxt-*, at most 0 bytes").
export -f _rt_private_root_violation
export _RT_PRIVATE_ROOT_BASE _RT_PRIVATE_ROOT_MAX
_RT_RUNNER_PID=$$
export _RT_RUNNER_PID
_RT_SWEEP_AGE_FLOOR_S=600
_rt_sweep_stale_roots() {
    local d name pid now age swept=0
    [[ -d /proc/self ]] || return 0                               # cannot tell liveness at all: sweep nothing
    now=$(date +%s)
    for d in "$_RT_PRIVATE_ROOT_BASE"/nxt-"$(id -u)"-*; do
        [[ -d "$d" ]] || continue
        name="${d##*/}"; pid="${name#nxt-*-}"; pid="${pid%%-*}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ -d "/proc/$pid" ]] && continue                           # ALIVE, whatever it is: keep
        age=$(( now - $(stat -c %Y "$d" 2>/dev/null || echo "$now") ))
        (( age >= _RT_SWEEP_AGE_FLOOR_S )) || continue           # young: keep
        rm -rf "$d" 2>/dev/null && swept=$(( swept + 1 ))
    done
    (( swept > 0 )) && printf 'run-tests.sh: swept %d stale private root(s) under %s left by killed runs (your-org/nexus-code#1481)\n' "$swept" "$_RT_PRIVATE_ROOT_BASE" >&2
    return 0
}
_rt_sweep_stale_roots

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
        #
        # THE TAG SAYS "MENTIONS", BECAUSE THAT IS ALL IT MEASURES
        # (your-org/nexus-code#1041 item 2). The predicate is `grep -q` over the
        # whole file, so a comment, a usage line, or a grep pattern inside a
        # fixture body earns the tag. It read "(integration; …)", which claims
        # the file GATES on the variable, and that is a stronger statement than
        # `grep -q` can support.
        #
        # THE LABEL IS THE HALF THAT CHANGES, AND THAT IS A MEASURED CHOICE, NOT
        # A DEFAULT. Tightening the predicate makes it strictly WORSE. Measured
        # at 7c4ddbb over `monitor/watcher/test-integration/test-*.sh`: of the
        # six scenarios that mention the token at all, FIVE mention it only in a
        # usage COMMENT — the real gate lives in `_harness.sh:40`
        # (`[[ "${RUN_INTEGRATION:-0}" != "1" ]]`), which they source. So a
        # comment-excluding predicate would drop five of the six true positives.
        # And it would NOT drop the known false positive: `test-slow-band-drift`
        # carries the token inside a `grep -q 'SLOW_TESTS\|RUN_INTEGRATION'`
        # PATTERN STRING, which is not a comment. Every tightening available
        # here loses more than it gains.
        #
        # `(integration` is preserved as the leading token on purpose:
        # `.github/workflows/tests-slow-integration.yml` counts these lines with
        # `grep -c '(integration'` as an anti-vacuous-pass guard. Changing the
        # prefix would silently zero that guard — a lint about honesty breaking
        # a check about vacuity.
        tag_base=$(basename "$t")
        if grep -q 'RUN_INTEGRATION' "$t" 2>/dev/null; then
            printf '%-45s  (integration? mentions RUN_INTEGRATION; RUN_INTEGRATION=1 to enable)\n' "$tag_base"
        elif grep -q 'SLOW_TESTS' "$t" 2>/dev/null; then
            printf '%-45s  (slow? mentions SLOW_TESTS; SLOW_TESTS=1 to enable)\n' "$tag_base"
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
# WHAT THE CORPUS ACTUALLY SAYS. Measured over all selected suites, from
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
# --- ONE FOOTER LINE, READ BY EVERY FIELD (#1031, #997) --------------------
#
# The two figures this runner derives from a suite's stdout — the ASSERTION
# count and the CASE-SKIP count — used to be scraped INDEPENDENTLY, with
# different patterns, over the whole file. Two defects followed, and they are
# one bug wearing two faces:
#
#   #1031  the assertion scrape took the LAST matching line. For a suite with
#          skips that is `th_summary_and_exit`'s BANNER, printed AFTER the
#          summary — and the `ALL TESTS PASSED (N` alternative, written for
#          `(63 assertions)`, captured the SKIP count out of
#          `ALL TESTS PASSED (1 case(s) SKIPPED — NOT covered)`.
#          Measured on `dev` at `ca62020`: `test-tmux-shim.sh` ran 102
#          assertions and the row said `1 assertions`. Worse than an off-by-N:
#          the number is ANTI-CORRELATED with coverage — the more a suite
#          skips, the LARGER its reported assertion count — so it moves the
#          wrong way exactly when a reader most needs it to move the right way.
#
#   #997   the skip scrape matched ANY line ANYWHERE in stdout, so a suite
#          whose SUBJECT is parsing footers — and which therefore echoes
#          specimen footers as test data — was scored on its own fixtures.
#          `test-assertion-accounting.sh` §8 prints
#          `  PASS: capture: === summary: 41 passed, 0 failed, 2 SKIPPED (…`
#          and the runner annotated it `(2 CASE(S) SKIPPED — NOT covered)`
#          against a suite whose real footer is
#          `=== summary: 63 passed, 0 failed ===` and which declined nothing.
#
# WHICH IS WRONG, THE LABEL OR THE COMPUTATION? For #1031 the COMPUTATION: the
# column header `assertions` says what a reader needs, and the sed captured a
# different quantity. Relabelling the column would have been the other, wrong
# repair — it would have made every correctly-counted row lie instead. For
# #997 the computation too, but at the LINE level rather than the field level:
# the pattern was right about what it wanted and wrong about where to look.
#
# THE FIX IS DEFINITIONAL. Both fields now come from ONE line, chosen once,
# here. They cannot describe different lines any more — not because two call
# sites happen to agree today, but because there is only one selection left to
# disagree with.
#
# WHICH HALF FIXES #997, stated precisely because the obvious answer is wrong
# and was written here first. It is NOT the anchor. #997's old scrape selected
# `the last line containing SKIPPED`, and a suite whose own footer declines
# nothing has no such line of its own — so the only candidate was the echoed
# specimen. Reading the FOOTER line instead fixes it outright: the echo comes
# BEFORE the summary (a suite cannot print after its own footer, because the
# footer exits), so `tail -n1` over footers passes the echo by whether or not
# anything is anchored. The anchor below is a SECOND and weaker line of
# defence, and its limit is measured rather than assumed — see its own note.
#
# WHICH line, and why the anchor is PER-ALTERNATIVE rather than global.
# `^`-anchoring everything is the obvious repair and it is measurably wrong
# here. At `5de291f`, `git grep -h -E "(printf|echo).*pass / %d fail"` over
# `:(glob)monitor/watcher/test-*.sh` finds EIGHT suites whose real footer is
# INDENTED (`printf '  %d pass / %d fail\n'` — test-cc-gate.sh,
# test-pane-state.sh, +6), and a DOCUMENTED spelling carries a label prefix
# (`cc-update: 23 passed, 0 failed`). A global anchor turns those into `?`.
#
# So the alternatives split by strength — and the split is not merely an anchor,
# it is a PRECEDENCE. `tail -n1` over one combined pattern makes the LAST
# matching line win, which lets a line printed AFTER a correct footer override
# it. Measured on the one-pattern form:
#
#     === summary: 63 passed, 0 failed ===
#     ALL TESTS PASSED
#     hint: 0 passed, 0 failed means nothing ran      <- prose, not a footer
#     -> 0   ... and `0 ASSERTIONS — this PASS covers nothing`, plus the suite
#            NAMED in `=== N passing file(s) declared ZERO assertions ===`
#
# A suite that ran 63 assertions is published as vacuous by a sentence it
# printed about itself. That is the same defect as #1031 read from the other
# end — there the overriding line was `th_summary_and_exit`'s own banner, here
# it is arbitrary trailing prose — and it is why the repair is a two-tier
# SELECT rather than a widened regex. Tier 1 is consulted first and wins
# outright; tier 2 is reached only when no marker-led footer exists at all:

#
#   MARKER-LED  `=== summary:` and `ALL TESTS PASSED` carry a unique marker.
#               Anchored to `^[[:space:]]*` — the marker must be the first
#               non-blank content on the line. That ACCEPTS an indented real
#               footer and refuses a prefixed one. Measured at `5de291f`:
#               `git grep -h -E "(printf|echo).*===[[:space:]]*summary:"` over
#               `:(glob)monitor/watcher/test-*.sh` is 141 lines and NONE of them
#               emits the marker behind non-blank text.
#
#               WHAT THE ANCHOR DOES NOT BUY, measured rather than reasoned:
#               `  PASS: capture: === summary: 41 passed, 0 failed ===` is
#               STILL selected, because `41 passed, 0 failed` satisfies a
#               SHAPE-ONLY alternative that has no marker to anchor. So the
#               anchor only removes lines whose ONLY match was marker-led —
#               `  PASS: capture: ALL TESTS PASSED (92 assertions)` is the
#               case it actually catches, and that is the case section 9 of
#               test-assertion-accounting.sh asserts. Claiming more for it
#               would be this file's own defect class: a guard credited with
#               a population it does not cover.
#
#   SHAPE-ONLY  the other five are weak patterns with no marker, and they
#               legitimately carry label and indentation prefixes
#               (`cc-update: 23 passed, 0 failed`). Left unanchored, exactly as
#               before — but now consulted ONLY when tier 1 is empty, so
#               trailing prose can no longer outrank a real footer. The eight
#               `  N pass / M fail` suites and the labelled spellings still
#               read, because none of them emits a marker-led line at all.
#
# COVERAGE BOUNDARY, drawn on the axis the mechanism varies on — PREFIX, not
# suite: this selects the suite's OWN footer for every footer that is
# MARKER-LED. A suite with NO recognised footer that ALSO echoes a SHAPE-ONLY
# footer-shaped line still has that echo read as its result; it would otherwise
# read `?`.
#
# AND THE TIERING INVERTS ONE CASE, which belongs here because the boundary
# above reads as though it does not (`your-org/nexus-code#1040` skeptic F3).
# A suite whose OWN footer is SHAPE-ONLY, which also echoes a MARKER-LED
# specimen at line start, now reports the ECHO — tier 1 outranks tier 2
# regardless of position, so the real footer loses. Measured against both
# selectors over the same planted logs:
#
#     marker-led echo, then real `  63 pass / 0 fail`   ->  here 7, before 63
#     `ALL TESTS PASSED (7 assertions)` echo, then that ->  here 7, before 63
#     marker-led echo, then real `cc-update: 23 passed` ->  here 7, before 23
#     real summary, then trailing prose `hint: 0 passed` ->  here 63, before 0
#
# The fourth row is what the tiering was built for; the first three are its
# price, and they fall on exactly the ten suites the weak patterns are kept for.
# NOT LIVE: applying both selectors to the same contained logs across all 348
# suites yields ZERO divergences — the eight indented-footer suites emit no
# tier-1 line at all — so this is a documentation gap, not a defect in the tree.
#
# NO POSITIONAL RULE SEPARATES THE TWO, and that is why the entry stops at a
# sentence rather than a redesign. "A marker-led line that is not the footer"
# and "a marker-led line that IS the footer, followed by noise" are the same
# shape to any reader that cannot execute the suite. Preferring the LAST
# marker-led line restores rows 1-3 and reinstates row 4; preferring the FIRST
# does the reverse. The residue is irreducible; do not try to engineer it away.
# What is owed a reader is this paragraph. That residue is the price of keeping the five weak patterns at all,
# and closing it means dropping them, which costs the ten real suites above.
# A prefixed MARKER-LED line (a datestamped banner, say) now reads `?` where it
# used to read a number — deliberately: a prefixed banner is indistinguishable
# from an echoed one, and `?` is loud and counted in the footer's normalisation
# list, where a fabricated number is neither.
# THE PATTERNS ARE INLINE, NOT IN VARIABLES, and that is a correctness
# requirement rather than a style choice — learned the hard way while writing
# this. Held in two exported globals, the function is no longer self-contained,
# and it has TWO consumers that copy it without its environment:
#
#   * test-assertion-accounting.sh §8 extracts it with
#     `source <(sed -n '/^_rt_footer_line() {/,/^}/p' "$RUNNER")`. Unset
#     variables make both greps take an EMPTY pattern, which matches EVERY
#     line — so the reader silently returns the last line of the log and 23
#     assertions went `?`. Measured, on the first run after the change.
#
#   * the `--jobs N` path, where `run_one` is dispatched through
#     `xargs … bash -c` and a child inherits only what was exported. A missed
#     `export` there is #693's original defect exactly: every row `?`, a run
#     total of 0, and green.
#
# Both failures are silent and produce a plausible number. An inline pattern
# cannot have either, so the dependency is removed rather than documented.
_rt_footer_line() {
    local log="$1" line
    line=$(grep -aE '(^[[:space:]]*===[[:space:]]*summary:[[:space:]]*[0-9]+[[:space:]]+passed)|(^[[:space:]]*ALL TESTS PASSED[[:space:]]*\([0-9]+([[:space:]]*[)/]|[[:space:]]+(assertions|checks)))' \
             -- "$log" 2>/dev/null | tail -n1)
    [[ -n "$line" ]] || \
    line=$(grep -aE '([0-9]+[[:space:]]+passed,[[:space:]]*[0-9]+[[:space:]]+failed)|(passed[[:space:]]*[=:][[:space:]]*[0-9]+)|([0-9]+[[:space:]]+pass[[:space:]]*/[[:space:]]*[0-9]+[[:space:]]+fail)|(PASS=[0-9]+)|([0-9]+/[0-9]+[[:space:]]+passed)' \
             -- "$log" 2>/dev/null | tail -n1)
    printf '%s' "$line"
}
# The `ALL TESTS PASSED (` alternative above now REQUIRES an assertion-count
# spelling after the number: `)` closes it (`(111)`), `/` continues it
# (`(37/37)`), or the words `assertions`/`checks` name it. The skip banner's
# next token is `case`, so it can no longer be selected — which is the #1031
# repair, made at the SELECTION step rather than the capture step so that a
# suite carrying both a summary line and a skip banner falls through to the
# summary (102) instead of falling through to `?`.
export -f _rt_footer_line

# _rt_emitted_assertion_lines <log> — rc 0 if the suite printed at least one
# PER-ASSERTION result line. The SECOND, WEAKER signal behind the `?` gate
# (your-org/nexus-code#1185): it answers "did this suite do anything observable"
# when the footer channel has already failed to answer "how much".
#
# DELIBERATELY BROADER THAN THE FOOTER READER, and in the opposite direction.
# `_rt_declared_assertions` is anchored and strict because a WRONG COUNT is
# indistinguishable from a right one. Here the cost is reversed: this predicate
# only ever KEEPS A SUITE GREEN, so a false positive is a missed red (the hole
# stays open for that suite) while a false negative is a WRONG RED on a suite
# that did assert. On a gate whose whole risk is being switched off for crying
# wolf, the recogniser must be generous. Anything that looks like a per-case
# verdict counts, in any of the spellings this corpus uses.
# _rt_ceiling_for <test_path> — the PER-TEST timeout this suite should get.
# Echoes the run's ceiling unless `ceiling-overrides.tsv` names this basename
# (your-org/nexus-code#992).
#
# ONLY EVER RAISES, NEVER LOWERS. A row that could shorten a ceiling would be a
# way to make a slow suite TIMEOUT sooner and call that a result, and a typo'd
# small number would silently convert real passes into timeouts — a false RED,
# which trains readers to distrust the census. Raising is the only direction
# that can be wrong in the safe way: the worst a too-large row does is let a
# genuine hang run longer, and the CEILING-ADJACENT census still names the
# suite on every run.
#
# THE SHAPE IS VALIDATED, NOT THE EMPTINESS. An emptiness check is a presence
# test wearing a validity test's name; a stray word or a control byte passes it
# and then poisons the arithmetic below under `set -e`.
_rt_ceiling_for() {
    local tp="$1" base cand file
    local run_ceiling="${PER_TEST_TIMEOUT:-0}"
    file="${_RT_CEILING_FILE:-$(dirname -- "${BASH_SOURCE[0]}")/ceiling-overrides.tsv}"
    [[ "$run_ceiling" =~ ^[0-9]+$ ]] && (( run_ceiling > 0 )) || { printf '%s' "$run_ceiling"; return 0; }
    [[ -r "$file" ]] || { printf '%s' "$run_ceiling"; return 0; }
    base=$(basename -- "$tp")
    cand=$(awk -F'\t' -v b="$base" '
        /^[[:space:]]*#/ { next }
        NF >= 2 && $1 == b { print $2; exit }
    ' "$file" 2>/dev/null)
    [[ "$cand" =~ ^[0-9]+$ ]] || { printf '%s' "$run_ceiling"; return 0; }
    (( cand > run_ceiling )) && { printf '%s' "$cand"; return 0; }
    printf '%s' "$run_ceiling"
}

#
# A DECLINE IS NOT AN ASSERTION — `SKIP` and `TODO` are NOT in the alternation
# (your-org/nexus-code#1277). They were, and that is precisely why this
# predicate could not see the population `#1277` is about. MEASURED, three
# fixtures through the real runner at `5bd6d400`:
#
#   echo "  SKIP: jq absent"; echo "ALL TESTS PASSED"; exit 0
#       -> assertions: ?   emitted_assertion_lines=YES   NOT in the census
#   echo "ALL TESTS PASSED"; exit 0
#       -> assertions: ?   emitted_assertion_lines=NO    in the census
#   a real PASS line + a readable footer
#       -> 1 assertions                                  green, correctly
#
# The only difference between the first two is the SKIP line, and the first is
# the shape that actually ships: `command -v jq || { echo "  SKIP: jq absent";
# echo "ALL TESTS PASSED"; exit 0; }`. So the line by which a suite ANNOUNCES it
# verified nothing was being read as evidence that it verified something, and
# `#1145`'s ratchet and `#1185`'s conjunction both missed the same 11 suites for
# this one reason.
#
# THIS NARROWS A DELIBERATELY GENEROUS PREDICATE, so the direction is checked
# rather than assumed. The paragraph above is right that a false negative here
# is a WRONG RED — but only for a suite whose footer is ALSO unreadable, and a
# suite whose every per-case line is `SKIP:` and whose footer says nothing has,
# by construction, verified nothing. It is not being mis-read; it is being read
# correctly for the first time. TAP's `not ok 3 # SKIP` still matches on
# `not ok`, which is a RESULT and stays in.
# _rt_assertion_line_count <log> — HOW MANY per-assertion result lines this log
# holds (your-org/nexus-code#1308 §1, re-scoped from a refusal to a census).
#
# ONE RECOGNISER, TWO CALLERS. `_rt_emitted_assertion_lines` below is now a thin
# `> 0` over this, so "which spellings count as an assertion line" has exactly
# one answer in this file and the two cannot drift. That is deliberate, and the
# alternative was MEASURED WRONG: over a 450-log corpus a purpose-written
# `PASS:`-only counter produced 10 mismatches of which only ONE was real —
# `test-watcher-liveness-trichotomy` (22+3) and `test-watcher-singleton-groups`
# (22+5) spell some verdicts `ok:` and reconcile EXACTLY once `ok:` is counted,
# and `monitor/test-slow-band-step-contract` scored 0 against a 12-passed
# footer for the same reason. All three read `holds` through this function.
#
# GENEROUS, AND THAT IS THE RIGHT DIRECTION *FOR A CENSUS* — by a different
# argument from the one below, which must not be borrowed. There, generosity is
# safe because a false positive only keeps a suite green. Here it is safe
# because this feeds a NAMED LIST and never a verdict: an over-match costs a
# line a human reads and dismisses, an under-match is a silent zero. It must
# NOT be reused for a red without re-arguing the direction.
#
# SPELLINGS COVERED (case-insensitively, at line start after optional space):
#   `ok` / `not ok`, optionally `[`-prefixed   (TAP)
#   `PASS` / `FAIL` / `XFAIL` followed by one of `:` `.` `)` `-`
#   `✓`  `✗`  `×`
# NOT COVERED, each a stated bound rather than an oversight:
#   `SKIP:` / `TODO:` — a DECLINE is not an assertion (your-org/nexus-code#1277)
#   any other per-case vocabulary a suite invents
#   an assertion line printed with a non-space prefix
# OVER-MATCHES, known: `^[[:space:]]*` admits an INDENTED echo, so a suite that
#   lets a nested runner's FAIL diagnostic through (run_one echoes a failing
#   log's tail indented by four) counts those lines too.
_rt_assertion_line_count() {
    local log="$1" n
    [[ -s "$log" ]] || { printf '0'; return 0; }
    n=$(grep -acEi '^[[:space:]]*(\[?(ok|not ok)\b|(PASS|FAIL|XFAIL)[[:space:]]*[:.)-]|✓|✗|×)' -- "$log" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}
export -f _rt_assertion_line_count
_rt_emitted_assertion_lines() {
    local log="$1"
    [[ -s "$log" ]] || return 1
    # Delegated so the spelling set lives in ONE place (see above).
    # Behaviour is unchanged: `grep -q` was "at least one match"; this is
    # "count > 0". A count of 0 makes the arithmetic false, i.e. rc 1.
    (( $(_rt_assertion_line_count "$log") > 0 ))
}

# _rt_claims_success <log> — rc 0 if the suite printed an unambiguous SUCCESS
# BANNER (your-org/nexus-code#1277).
#
# DELIBERATELY NARROW, and in the OPPOSITE direction to the predicate above.
# That one only ever keeps a suite green, so it must be generous; this one only
# ever turns a run RED, so a false positive is a wrong red and it must be
# strict. It matches the banner and nothing else — not a summary line, not a
# count, not prose. `ALL TESTS PASSED` after a skip is a FALSE STATEMENT, and
# that is the whole claim this predicate is used to make.
_rt_claims_success() {
    local log="$1"
    [[ -s "$log" ]] || return 1
    grep -qE '^[[:space:]]*ALL (TESTS|CHECKS) PASSED\b' "$log"
}

# _rt_path_in_repo <test-path> — rc 0 if this suite is a FILE OF THIS REPO
# rather than a fixture planted in a scratch dir (your-org/nexus-code#1277).
#
# THE DISCRIMINATOR IS A PROPERTY, NOT AN ALLOWLIST, and that is the point. The
# `#1185` census was left a census on the stated ground that "its only observed
# effect is on PLANTED FIXTURES — a runner-under-test's minimal `echo …; exit 0`
# vehicle, which is the standard idiom here". That is true and it is a real
# constraint: every runner-under-test suite in this repo plants its fixtures
# under `mktemp -d`, i.e. `$TMPDIR`, and reddening those would break
# test-assertion-accounting.sh, test-run-tests-bounded.sh and their siblings —
# a guard against a false green that manufactures a false red, which is how a
# ratchet gets switched off.
#
# Those fixtures are OUTSIDE the repo tree and every real suite is INSIDE it, so
# the two populations are separated by where the file lives — no path list to
# keep up to date, no floor to tune, and nothing that a new fixture or a new
# suite has to be told about. A path we cannot resolve is treated as NOT in the
# repo, i.e. it cannot cause a red: this predicate gates an accusation, so
# "could not tell" must not accuse.
_rt_path_in_repo() {
    local tp="$1" abs
    [[ -n "${_RT_REPO_ROOT:-}" ]] || return 1
    abs=$(cd "$(dirname -- "$tp")" 2>/dev/null && pwd -P) || return 1
    [[ -n "$abs" ]] || return 1
    case "$abs/" in
        "$_RT_REPO_ROOT"/*) return 0 ;;
    esac
    return 1
}

_rt_declared_assertions() {
    local log="$1" line
    line=$(_rt_footer_line "$log")
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
# MUST be exported, and the set is now CLOSED rather than merely sufficient.
#
# `run_one` is dispatched through `xargs … bash -c` when --jobs > 1, and a child
# shell inherits exported FUNCTIONS, not the file's definitions. Exporting
# `run_one` alone left this callee undefined in every parallel child:
# 245 x `_rt_declared_assertions: command not found`, every row `assertions: ?`,
# and a run total of `0` — green, in all five cells of the fast band, from the
# first merge.
#
# CLOSURE, not hope: this file `source`s nothing, and every function `run_one`
# can reach is exported. The set grew from two to four with #1031/#997
# (`_rt_footer_line`, `_rt_footer_skips`) plus the two note helpers below —
# the comment that stood here said "exactly two functions", which was the state
# of the file and not a property of it, so it went stale the moment the file
# grew. What is invariant is the RULE: every script-defined callee of `run_one`,
# transitively, needs its own `export -f`, and `_rt_footer_skips` calls
# `_rt_footer_line`, so the transitive closure is what matters rather than the
# direct callees. test-assertion-accounting.sh section 6 runs the parallel band
# and catches the omission; a missing export renders as `command not found` in
# the child and `?` on every row.
export -f _rt_declared_assertions

# --- CASE-SKIP COUNT, from the SAME footer line (#997) ---------------------
#
# The old form was `sed -n 's/.*=== summary:.*[^0-9]\([0-9]*\) SKIPPED.*/\1/p'`
# over the whole of `$log_base.out`, which is why an echoed specimen scored the
# suite that echoed it. Reading `_rt_footer_line` instead means the skip count
# and the assertion count are, by construction, two fields of ONE line — the
# property #997 and #1031 both violated from opposite ends.
#
# SECOND WIDENING, and it is a separate defect found sweeping the class: the
# capture is now case-INSENSITIVE in `SKIPPED`. `th_summary_and_exit` emits the
# uppercase spelling, but the corpus does not only contain it —
# `git grep -n "failed, %d skipped"` over `:(glob)monitor/watcher/*.sh` at
# `5de291f` finds `test-claude-md-618-remedies.sh:297` emitting
# `=== summary: %d passed, %d failed, %d skipped (…) ===`. So the ABSENCE of
# the annotation used to mean "no UPPERCASE SKIPPED on a summary line" while
# being read as "this green covers everything it ran" — a predicate narrower
# than the population its silence was taken to cover, which is the same defect
# class one field over.
#
# The explicit `[^0-9]` before the capture is load-bearing for the reason the
# assertion capture documents above: without it a greedy `.*` eats into the
# number and `12 SKIPPED` captures `2`.
_rt_footer_skips() {
    local log="$1" line n
    line=$(_rt_footer_line "$log")
    [[ -n "$line" ]] || return 1
    n=$(printf '%s' " $line" \
        | sed -n 's/.*[^0-9]\([0-9][0-9]*\)[[:space:]][[:space:]]*[Ss][Kk][Ii][Pp][Pp][Ee][Dd].*/\1/p')
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$n"
}
export -f _rt_footer_skips

# _rt_footer_fails <log> — the FAILED count from the SAME footer line, or rc 1
# when this runner's spellings do not carry one (your-org/nexus-code#1308 §1).
#
# rc 1 IS AN ANSWER AND MUST STAY DISTINCT FROM 0. "declares no failed count"
# and "declares zero failures" are different facts; merging them would let the
# census compare a line total against a denominator it invented, which is how a
# plausible wrong number gets published. Such a suite is recorded UNCOMPARABLE
# and named, never folded into the holds column.
#
# Reads `_rt_footer_line`, so passed / failed / skipped are three fields of ONE
# line by construction — the property `#997` and `#1031` each violated from one
# end. `[^0-9]`-guarded for the reason `_rt_declared_assertions` documents: a
# greedy `.*` otherwise eats into the number and `12 failed` captures `2`.
#
# MOST-SPECIFIC FIRST, AND THE ORDER IS LOAD-BEARING. With a positional arm
# first, the footer `passed: 41  failed: 0` captures **41** — the greedy `.*`
# anchors on the last `failed` and `41` followed by whitespace satisfies the
# positional shape. Measured on that literal footer, and on
# `[3/12] passed=41 failed=0`, before the reorder. A LABELLED count must be
# read as a label before any positional arm runs.
#
# The unqualified banner is an arm of its own: `ALL TESTS PASSED` /
# `ALL CHECKS PASSED` asserts zero failures without spelling a number, and it is
# the footer `_rt_footer_line` selects for the eight indented-footer suites.
_rt_footer_fails() {
    local log="$1" line n pat sline
    line=$(_rt_footer_line "$log")
    [[ -n "$line" ]] || return 1
    sline=" $line"
    case "$line" in
        *"ALL TESTS PASSED"*|*"ALL CHECKS PASSED"*) printf '0'; return 0 ;;
    esac
    for pat in \
        's/.*failed[[:space:]]*[=:][[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        's/.*FAIL=\([0-9][0-9]*\).*/\1/p' \
        's/.*[^0-9]\([0-9][0-9]*\)[[:space:]][[:space:]]*failed.*/\1/p' \
        's/.*[^0-9]\([0-9][0-9]*\)[[:space:]][[:space:]]*fail\([^a-zA-Z].*\)*$/\1/p'
    do
        n=$(printf '%s' "$sline" | sed -n "$pat")
        [[ -n "$n" ]] && break
    done
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$n"
}
export -f _rt_footer_fails

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
    # RECONCILED AGAINST THE HEADROOM PRINTED TWO LINES UP (found sweeping the
    # #1031/#997 class; the highest-stakes member of it, because unlike a
    # mislabelled count this one instructs the reader to DISMISS A RED).
    #
    # The unconditional form asserted RLIMIT_NPROC exhaustion from a bare
    # substring match on either stream — so a suite that merely QUOTES the
    # strerror in a diagnostic had its genuine failure attributed to the
    # environment. Measured on `dev` at 5de291f with a fixture whose only crime
    # is the quote, and note the third line — the runner had already computed
    # the number that refutes it and printed it immediately above:
    #
    #     FAIL  test-eagain-echo.sh   0.01s  rc=1
    #       resources … fork-headroom=7068 …
    #       *** CPU-STALL neighbourhood: fork-headroom=7068 is HEALTHY, so this is NOT #655 exhaustion,
    #       *** EAGAIN in this run — RLIMIT_NPROC exhaustion, NOT a test defect.
    #       *** matched: FAIL: expected 'Resource temporarily unavailable' in the log
    #       *** your-org/nexus-code#655: re-run before reading this as a red.
    #
    # Two adjacent notes, flatly contradicting each other, and the one that
    # wins with a reader is the one that lets them stop. `monitor/watcher/
    # test-fork-headroom-guard.sh` builds fixtures containing all three
    # spellings, so the trigger is live in-tree, not hypothetical.
    #
    # THE LABEL IS THE WRONG HALF, and the widened MATCH is right: #655's own
    # reasoning — key on the strerror (the property), not on bash's fork
    # wording — still holds, and narrowing the grep would reintroduce the
    # false NEGATIVE it was widened to close. What was wrong is that a
    # substring was published as a diagnosis. So the match stays exactly as
    # broad and the CLAIM is now conditioned on the evidence the runner already
    # has: headroom is the same quantity #655 is about, it is computed in this
    # very function, and it was simply never consulted.
    #
    # The asymmetry is deliberate. Unknown headroom (`?`) keeps the original
    # confident wording: that is the environment where #655 actually bites and
    # where a missed attribution costs a real re-run. Only a MEASURED, healthy
    # headroom downgrades the note to what it is — an unexplained occurrence of
    # the string — and even then the match is still printed, so nothing is
    # hidden from a reader who wants to judge it themselves.
    if [[ -n "$hit" ]]; then
        if [[ "$headroom" =~ ^[0-9]+$ ]] && (( headroom >= 500 )); then
            printf '    *** the EAGAIN strerror appears in this run — but fork-headroom=%s is HEALTHY,\n' "$headroom"
            printf '%s\n' "    *** so RLIMIT_NPROC exhaustion is NOT supported by this run's own numbers."
            printf '    *** matched: %s\n' "$hit"
            printf '    *** Most likely the test QUOTED the string. Do NOT dismiss this red on it;\n'
            printf '    *** if headroom were exhausted this line would say so (your-org/nexus-code#655).\n'
        else
            printf '    *** EAGAIN in this run — RLIMIT_NPROC exhaustion, NOT a test defect.\n'
            printf '    *** matched: %s\n' "$hit"
            printf '    *** fork-headroom=%s at sample time.\n' "$headroom"
            printf '    *** The ceiling is per-UID and shared with every other agent on this box.\n'
            printf '    *** your-org/nexus-code#655: re-run before reading this as a red.\n'
        fi
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
    # `.assertions`, `.failed`, `.timedout`, `.accounted`, `.ceilingadj`,
    # `.out`, `.err` — RELATIVE paths,
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
    # STDIN IS THE RUNNER'S TO DEFINE, NOT THE CALLER'S (your-org/nexus-code#1152).
    # Both exec sites below redirect `</dev/null`. Without it a test inherits
    # whatever stdin the person or system that invoked run-tests.sh happened to
    # have, so a suite driving any callee that reads stdin returns a DIFFERENT
    # VERDICT depending on WHO RAN IT — measured on this file's own fixture:
    # PASS in 0.02s under `</dev/null`, FAIL in 5.01s under an open pipe that
    # never writes, same tree, same commit, nothing else varied. Under an
    # agent's Bash tool stdin is a socket: neither a TTY nor at EOF, which is
    # the hanging case. That is your-org/nexus-code#921's class one layer up:
    # #921 fixed the generated `gh` stub, which cannot reach a real callee like
    # monitor/send.sh:504 (`else cat > "$TMP_PAYLOAD"; fi`).
    #
    # WHY HERE AND NOT ON THE DISPATCH ARMS, which is what #1152 proposed. The
    # parallel arm is `printf … | xargs -P`, and xargs reads its ARGUMENT LIST
    # from stdin — a `</dev/null` there would feed xargs an empty test list and
    # silently run nothing, which is this repo's dominant defect class (a
    # confident zero) installed by the remedy for it. run_one is the single
    # point every test in BOTH arms passes through, so redirecting here covers
    # the class by construction and cannot starve the dispatcher.
    #
    # RISK CHECKED, NOT ASSUMED: 0 of 390 tracked `test-*.sh` consume the
    # runner's stdin. The five that mention stdin at all are a lint fixture
    # STRING, two `$(cat)` inside generated stubs fed by their own caller, a
    # heredoc-supplied `source /dev/stdin`, and a hook stub given a payload.
    # A suite needing input still supplies its own (`< fixture`); a redirect
    # here does not prevent that.
    start_ns=$(date +%s%N)
    # Per-suite ceiling (your-org/nexus-code#992). `PER_TEST_TIMEOUT` stays the
    # run's default; this suite's effective ceiling may be RAISED by a measured
    # row in ceiling-overrides.tsv. Everything downstream — the timeout itself,
    # the CEILING-ADJACENT margin census, the ledger row — reads the EFFECTIVE
    # value, so a suite with an override is judged against the ceiling it
    # actually ran under rather than against a number that no longer applies.
    # `local` so the override cannot leak into the next test in the serial arm.
    # ORDER IS LOAD-BEARING: resolve FIRST, shadow SECOND. bash scopes `local`
    # DYNAMICALLY, so `local PER_TEST_TIMEOUT; X=$(_rt_ceiling_for …)` would run
    # the helper with PER_TEST_TIMEOUT already local and EMPTY — it would read
    # its own caller's empty shadow as the run ceiling, return 0, and DISABLE
    # the per-test timeout entirely. Measured while writing this: a 6s fixture
    # under `--timeout 3` passed instead of timing out, in BOTH arms, which is
    # a guard silently switched off rather than a wrong number.
    local _rt_eff_ceiling; _rt_eff_ceiling=$(_rt_ceiling_for "$test_path")
    local PER_TEST_TIMEOUT="$_rt_eff_ceiling"
    # A PRIVATE TMPDIR PER SUITE, REAPED WHEN IT EXITS (your-org/nexus-code
    # #1423, #1474). Every suite process that sources _test_helpers.sh writes
    # a `.th-ledger.<pid>-<start>` and a `.th-ports.<pid>` into ${TMPDIR:-/tmp},
    # and only `th_summary_and_exit` removes them — so every process that ends
    # by any other road (its own tally, a timeout, a fixture child) leaves two
    # zero-byte dirents in a tmpfs. Measured on the operator's node 2026-09-06:
    # 37,727 ledgers and 21,537 ports files live; the family had reached
    # 105,552. They are EXCLUDED from tmpfs-guard's entries threshold, so the
    # largest accumulator was invisible to the alarm built for accumulation,
    # and the same debris made this repo's own guard suite tar 21.8k files of
    # `monitor/.state` past its ceiling — three surfaces, one cause. Giving the
    # suite a TMPDIR that dies with it reaps the whole family (and mutgate,
    # olay-guard, every `mktemp` a suite forgot) without a reaper having to
    # decide, by name and age, what is dead.
    #
    # TMUX SOCKETS ARE THE ONE FAMILY THAT MUST NOT FOLLOW (your-org/nexus-code
    # #1481). The first cut of this block said "TMUX_TMPDIR is untouched" — true
    # of the VARIABLE, false of the BEHAVIOUR: the tmux fixture derived its
    # socket dir from the suite's `mktemp -d -t` workdir, i.e. from $TMPDIR, so
    # relocating TMPDIR to `…/slow-band-logs/<suite>.tmp/…` pushed every socket
    # path past the 108-byte sun_path limit and reddened all six CI bands at
    # once. Text about code is not behaviour of code. So the two families are
    # split here: TMPDIR is private and long-path-tolerant; TMUX_TMPDIR is
    # pinned to a SHORT per-suite root under /tmp that this runner also reaps,
    # and the fixture (`nx_tmux_fixture_init`) no longer reads the workdir for
    # its socket root at all. The run-level sun_path gate above measured the
    # AMBIENT TMUX_TMPDIR; this per-suite pin is measured by the same helper.
    #
    # AND THE PRIVATE ROOT MUST ITSELF BE SHORT AND /tmp-ROOTED (#1481, the
    # rest of the same red). The first cut put it at `$log_base.tmp` —
    # `…/test-failure-artifacts/first-run-logs/watcher__<suite>.sh.tmp/` on CI,
    # ~90 bytes — and four more suites reddened for reasons that were not the
    # socket at all: one PINS its own TMUX_TMPDIR from `mktemp -d` under TMPDIR
    # (151-byte socket path), one asserts its ephemeral fixture is under /tmp
    # (`FATAL: ephemeral fixture is not under /tmp`), one caps a diagnostic
    # token at 300 B that the long path overflowed, and one's classifier met a
    # path element spelled like a suite file (`test-x.sh.tmp`). A suite's
    # working assumptions about `$TMPDIR` are part of the harness contract:
    # short, under /tmp, no path element that looks like a test. So ONE short
    # private root serves both variables — `/tmp/nxt-<uid>-<pid>-<rand>` — and
    # is reaped when the suite exits. The `nxt-` prefix is this runner's; it is
    # never the sockets-only `/tmp/c71780`, and nothing else writes there.
    # `_RT_RUNNER_PID`, never `$$`: in the parallel arm `$$` is the xargs
    # child's pid, which a sibling's sweep could not attribute to a live run.
    # The name draws $RANDOM; a collision with a LIVE sibling root is ~3/32768
    # per start (measured uniform under xargs -P4, w225 skeptic F6), and an
    # `rm -rf` before `mkdir -p` would delete that sibling's fixture. So:
    # `mkdir` WITHOUT -p, redraw on EEXIST, never remove what we did not make.
    local _rt_tmp _rt_tt _rt_why _rt_try=0
    while :; do
        _rt_tmp="$_RT_PRIVATE_ROOT_BASE/nxt-$(id -u)-${_RT_RUNNER_PID:-$$}-$RANDOM"
        if mkdir "$_rt_tmp" 2>/dev/null; then break; fi
        _rt_try=$(( _rt_try + 1 ))
        (( _rt_try < 8 )) || { _rt_tmp=""; break; }
    done
    # THE CONTRACT, asserted on the root we are about to hand out — not only
    # on the four symptoms that once exposed it. A relocation that breaks it
    # fails HERE with its reason, before a single suite has to.
    if _rt_why=$(_rt_private_root_violation "$_rt_tmp"); then :; else
        rmdir "$_rt_tmp" 2>/dev/null || true   # ours, just made, empty
        printf 'run-tests.sh: REFUSED — the per-suite private root %q violates the harness contract: %s.\n' "$_rt_tmp" "$_rt_why" >&2
        printf '  The root a suite is handed as TMPDIR/TMUX_TMPDIR must be under %s/nxt-*, at most %d bytes, with no path element spelled like a suite file (your-org/nexus-code#1481).\n' "$_RT_PRIVATE_ROOT_BASE" "$_RT_PRIVATE_ROOT_MAX" >&2
        exit 2
    fi
    if [[ -z "$_rt_tmp" ]]; then
        # Could not isolate: run against the inherited TMPDIR rather than
        # refuse the suite, and say so once on stderr — a run that is already
        # in trouble should not lose its accounting over its own tidiness.
        printf 'run-tests.sh: WARN: could not create a private root under %s after %d draws — %s runs with the inherited TMPDIR/TMUX_TMPDIR and may leave .th-* files behind\n' "$_RT_PRIVATE_ROOT_BASE" "$_rt_try" "$suite_tag" >&2
        _rt_tmp="${TMPDIR:-/tmp}"; _rt_tt="${TMUX_TMPDIR:-/tmp}"
    else
        _rt_tt="$_rt_tmp"
    fi
    if [[ "${PER_TEST_TIMEOUT:-0}" =~ ^[0-9]+$ ]] && (( ${PER_TEST_TIMEOUT:-0} > 0 )); then
        # Hard per-test ceiling (#499). TERM first so the test's own EXIT
        # trap can reap its fixture processes; KILL 15 s later if it
        # ignores that. rc=124 is timeout's TERM verdict, 137 the
        # KILL escalation — both are TIMEOUT, never a pass.
        NEXUS_TEST_SUITE="$suite_tag" TMPDIR="$_rt_tmp" TMUX_TMPDIR="$_rt_tt" \
        timeout -k 15 "$PER_TEST_TIMEOUT" "${TEST_INTERPRETER:-bash}" "$test_path" \
            </dev/null >"$log_base.out" 2>"$log_base.err"
        rc=$?
    else
        NEXUS_TEST_SUITE="$suite_tag" TMPDIR="$_rt_tmp" TMUX_TMPDIR="$_rt_tt" \
        "${TEST_INTERPRETER:-bash}" "$test_path" </dev/null >"$log_base.out" 2>"$log_base.err"
        rc=$?
    fi
    end_ns=$(date +%s%N)
    # Reap the private root — never the inherited one we fell back to.
    [[ "$_rt_tmp" == "$_RT_PRIVATE_ROOT_BASE"/nxt-* ]] && rm -rf "$_rt_tmp" 2>/dev/null || true
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
    elif (( rc == 69 )); then
        # ENVSKIP (your-org/nexus-code#1283). Exit 69 — EX_UNAVAILABLE, "a
        # service is unavailable" — means "I RAN, I ASSERTED, and then measured
        # this MACHINE unable to supply something I needed, so I decline to
        # render a verdict". That is the OPPOSITE situation from `exit 77` and
        # it wants the opposite action, but until now the two arrived as one
        # token: `SKIP` carries the accusation "the SLOW_TESTS gate did not
        # take, so this suite silently left the band", which must stay loud —
        # and it was indistinguishable from an honest environment decline. In
        # the blocking slow band, where the tolerated set is empty by design,
        # every honest decline was therefore NEW-RED, so the ENV/PRODUCT
        # distinction #1025 asked for and #1115 partly shipped was inert in the
        # only band where it was needed.
        #
        # A DECLARED CODE, NOT AN INFERENCE. `#1283` suggests telling the two
        # apart by assertion count — a self-skip runs no assertion, an ENV
        # decline has a non-zero one. That discriminator is INERT here: the
        # ledger's assertion column is forced to `?` for every non-PASS row
        # (see `_ledger_assertions` below), in two independent places, so the
        # number the inference needs does not survive to the reader. It is also
        # the wrong SHAPE: an inference fails OPEN (a suite that forgets to
        # assert gets classified as a gate-skip and quietly reds, or worse, the
        # reverse), while a code the suite DECLARES fails CLOSED. A suite that
        # exits 69 against a runner that has not learned this arm falls to the
        # `rc != 0` arm below and is a FAIL — red and attributable, never green.
        #
        # WHY 69. 77 is SKIP (autotools, #568 A6), 78 is EX_CONFIG and 79 is
        # "NOT CHECKED" (#612), all three already load-bearing in this tree.
        # 75/EX_TEMPFAIL reads well and is TAKEN — `_scheduler.sh` uses rc 75
        # for back-pressure, which an `exit 75` census does not show and a
        # broad one does.
        #
        # ARM ORDER IS LOAD-BEARING HERE, unlike the equality arms it sits
        # among (your-org/nexus-code#1121). This arm and the `rc == 77` arm
        # above are literal equality over disjoint values, so THEIR order does
        # not matter; but `rc != 0` below is a RANGE that also matches 69, so
        # both equality arms must precede it or the range silently swallows
        # them. That is the one place a reordering here changes an answer.
        status=ENVSKIP
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

    # --- ACCOUNTING CENSUS (your-org/nexus-code#1308 §1, re-scoped) ---------
    #
    # THE INVARIANT: a printed per-assertion verdict must be COUNTED. So the
    # assertion lines a suite emitted, across both its streams, must equal the
    # passed+failed total its own footer declares.
    #
    # AN EXCESS IS A QUESTION, NOT A DIAGNOSIS. `#1308 §1` proposed this
    # comparison as PROOF that two writers shared one file, on the premise that
    # "no single-run defect can make a suite emit more assertions than it
    # declares". MEASURED FALSE: `test-eligibility-resurface.sh:280-285` wraps
    # an assertion in an explicit subshell, so its `printf '  PASS: …'` reaches
    # stdout while its `PASS=$(( PASS + 1 ))` mutates a copy discarded at `)`.
    # Eight printed, seven counted — DETERMINISTIC, ONE writer, reproduced on a
    # dedicated CI runner (artifact 9856627877) and locally solo. Measured at
    # `0b82ffb2`; FIXED IN TREE since, so do not expect to find the shape at
    # that location today — the citation dates the evidence, not the code.
    # Both causes
    # are named in the printed block, with the artefacts that discriminate;
    # naming only one would reproduce the mis-attribution `#1308`'s own comment
    # thread confesses to three times in one night.
    #
    # WHY IT IS WORTH BUILDING. Here the loss is BENIGN: an undercount on a
    # PASSING suite. The identical mechanism on a FAILING assertion leaves
    # `FAIL` at 0 in the parent, the suite exits 0, and a RED assertion is
    # reported GREEN. `_test_helpers.sh` reconciles exactly this upward from
    # `_TH_LEDGER` — but only for suites that SOURCE it. A suite with its own
    # vocabulary has no ledger and no protection: `#922`'s stated population
    # gap, reached by an INVARIANT (a printed verdict must be counted) instead
    # of by a NAME, and therefore immune to the vocabulary problem that bounds
    # `undefined-helper-lint.sh`.
    #
    # WHAT IT IS BLIND TO, stated because a census that does not bound itself
    # gets read as coverage it does not have: the OTHER half of that same
    # population, the `#922` MISSING-HELPER shape. A call to an undefined
    # helper is rc 127 — it prints NOTHING and counts NOTHING, so the line
    # total and the footer fall short by the SAME amount and the invariant
    # HOLDS. Measured against a planted pair differing only in how the third
    # assertion is lost: `( ok … )` -> MISMATCH 3/2+0; `undefined_helper …` ->
    # holds, silent. This complements `undefined-helper-lint.sh`; it does not
    # replace it.
    #
    # A CENSUS, NEVER A RED, IN THIS CHANGE. On one clean 450-log corpus pass
    # 10 of 450 suites mismatched and NINE were recogniser artefacts rather
    # than defects. Reddening before the spellings are normalised is how a
    # ratchet gets switched off and takes the real gate with it —
    # `#1175`/`#1185`'s own lesson. Nothing here touches the exit code.
    #
    # `_rt_path_in_repo` gates it for the `#1277` reason, and by PROPERTY
    # rather than by a path list: the six `fixtures__test-canon-summary`-family
    # rows in that corpus pass are synthetic FOOTER fixtures that declare a
    # footer and emit no assertion line at all, and they live under
    # `mktemp -d`, outside the tree.
    #
    # THE TRAILING COMMENT ON THE GATE BELOW IS LOAD-BEARING, NOT DECORATION.
    # Without it this line is byte-identical to the `.falsepass` gate ~70 lines
    # down, and `test-run-tests-false-pass.sh`'s M2 mutant anchors on that text.
    # Keep the two textually distinct.
    if _rt_path_in_repo "$test_path"; then   # census gate (#1308 §1)
        local _rt_ln _rt_fm _rt_verdict
        _rt_ln=$(( $(_rt_assertion_line_count "$log_base.out") \
                 + $(_rt_assertion_line_count "$log_base.err") ))
        _rt_fm=$(_rt_footer_fails "$log_base.out") || _rt_fm='?'
        if [[ "$n_assertions" =~ ^[0-9]+$ ]] && [[ "$_rt_fm" =~ ^[0-9]+$ ]]; then
            if (( _rt_ln == n_assertions + _rt_fm )); then _rt_verdict=holds
            else _rt_verdict=mismatch; fi
        else
            _rt_verdict=uncomparable
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$test_path" "$_rt_ln" "$n_assertions" "$_rt_fm" "$_rt_verdict" \
            >> "$out_file.acctcensus"
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
    # a name of its own rather than a derived quantity: PASS writes `.assertions` or
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
    # --- CEILING MARGIN (your-org/nexus-code#992) --------------------------
    #
    # A suite whose runtime sits just under its own timeout ceiling does not
    # fail — it FLAPS. Measured: `test-run-tests-bounded.sh` TIMEOUTs at
    # 600.01s against the default 600s ceiling and PASSes at 570.21s against a
    # 650s one, on IDENTICAL code, at host load 35/36. Five percent headroom on
    # an oversubscribed box is a coin toss, and the coin is tossed again on
    # every run.
    #
    # WHY THIS BELONGS IN A BUNDLE ABOUT MISLABELLED NUMBERS. It is the odd
    # member — a VERDICT that is unreliable rather than a COUNT that is
    # mislabelled — and it earns its place on the second half of the same rule:
    # `PASS` is a label whose definition, for a ceiling-adjacent suite, is
    # "passed THIS TIME". The runner never printed the margin that decides
    # whether the verdict reproduces, so the verdict was not re-derivable from
    # the output. Everything else about #992 is honest already — `rc=124` is
    # tallied as TIMEOUT and never as a pass (#499) — and the entire cost is
    # rediscovery: `TIMEOUT at the ceiling` carries no diagnostic content, reads
    # as "it hung", and gets re-diagnosed from scratch by someone with no reason
    # to suspect the ceiling. One session spent about an hour on it.
    #
    # A DERIVED BAND, NOT A CURATED LIST. #992 asks for the family to be
    # "recorded somewhere agents read", and the tempting shape is a roster of
    # known-slow suites. That is a standing dismissal: it decays the moment a
    # suite gets faster, a ceiling is raised, or the host gets busier, and a
    # decayed roster tells the next reader to write off a red that is theirs.
    # Derived per run from the wall THIS run measured, it cannot decay.
    #
    # Computed ABOVE the `case` for the same reason `.accounted` is: an outcome
    # arm added later inherits it instead of silently not having it. The
    # exclusion of TIMEOUT is DEFINITIONAL, not an enumeration — a timed-out
    # suite did not complete, so it has no margin to report, and its row already
    # names the ceiling.
    local _ceil_pct=''
    if [[ "$status" != TIMEOUT ]] \
       && [[ "${PER_TEST_TIMEOUT:-0}" =~ ^[0-9]+$ ]] && (( ${PER_TEST_TIMEOUT:-0} > 0 )); then
        _ceil_pct=$(awk -v w="$wall" -v c="$PER_TEST_TIMEOUT" \
                        -v t="${NEXUS_CEILING_ADJACENT_PCT:-80}" \
                        'BEGIN { if (c <= 0) exit 0; p = 100 * w / c; if (p >= t) printf "%d", (p >= 100 ? 100 : p) }')
    fi
    # Field 3 is the WALL (added with #992's --profile repair). Appended, not
    # substituted: every existing reader keys on $1/$2 (`awk -F'\t' '$2 ==
    # "FAIL"'`), so a wider row still parses. It exists so `--profile` derives
    # its table from the SAME write the tally reconciles against, rather than
    # from a parallel record that could describe a different population.
    printf '%s\t%s\t%s\n' "$test_path" "$status" "$wall" >> "$out_file.accounted"
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
            # ONE LINE, TWO FIELDS (#997, #1031). `_rt_footer_skips` reads the
            # SAME line `_rt_declared_assertions` read for `$ann` above — see
            # `_rt_footer_line`. The old form scraped `=== summary:.*N SKIPPED`
            # over the whole of `$log_base.out`, so a suite that ECHOED a
            # specimen footer as test data was annotated with its own fixture's
            # skip count while its assertion count came from its real footer:
            # one row, two lines, two different suites' worth of numbers.
            _skipped_cases=$(_rt_footer_skips "$log_base.out") || _skipped_cases=0
            if [[ "$_skipped_cases" =~ ^[0-9]+$ ]] && (( _skipped_cases > 0 )); then
                printf '  PASS  %-45s  %6ss %s  (%s CASE(S) SKIPPED — NOT covered)\n' \
                    "$name" "$wall" "$ann" "$_skipped_cases"
                # THE LINE BOTH NUMBERS CAME FROM. A reader can now re-derive
                # the assertion count AND the skip count on this row from the
                # runner's own output, without the suite's log — which is
                # exactly what #1031 and #997 denied them: a qualified row whose
                # qualifier could be checked against nothing.
                #
                # Printed only on QUALIFIED rows, and that is the boundary: an
                # unqualified row's count remains a transcription of a footer
                # this runner deliberately does not echo (one extra line x ~300
                # suites buys nothing, since an unqualified row has no second
                # number to disagree with).
                printf '    footer: %s\n' \
                    "$(_rt_footer_line "$log_base.out" | cut -c1-160)"
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
                # `?` MEANS "COULD NOT DETERMINE", AND THAT IS NOT "FINE"
                # (your-org/nexus-code#1185). `#1145`'s ratchet reds only the
                # READABLE-footer zero, so the escape from it was to be LESS
                # legible: a suite asserting nothing whose footer this runner
                # cannot read prints `assertions ?` and the run stays GREEN.
                # A hole shaped like the thing it ratchets.
                #
                # BUT `?` ALONE MUST NOT RED, and that is the whole design.
                # Measured over the corpus, every suite declares a count — in
                # one of twelve spellings — so `?` today means NORMALISATION
                # DEBT far more often than vacuity. Reddening on it would red
                # on the wrong defect and get the ratchet switched off, which
                # is why `#1175` scoped the gate to `zerocount` and said so.
                #
                # So the gate is CONJUNCTIVE, on a second and independent
                # signal: did this suite emit ANY per-assertion line at all? A
                # suite with 92 assertions in an unread spelling still prints
                # 92 result lines and stays green; a suite that printed no
                # footer this runner can read AND no assertion line has given
                # the runner nothing to go on in either channel, and that is
                # not normalisation debt — it is a green nobody can vouch for.
                # This is `#1185`'s second option, chosen because it does not
                # wait on the normalisation checklist.
                if ! _rt_emitted_assertion_lines "$log_base.out"; then
                    printf '%s\n' "$test_path" >> "$out_file.vacuous"
                    # AND THE SLICE OF THAT LIST THAT IS A FALSE STATEMENT
                    # RATHER THAN A SILENCE (your-org/nexus-code#1277).
                    #
                    # A file that printed nothing the runner could read has made
                    # no claim; whether THAT should red is the fixture-convention
                    # decision the census below defers, and it stays deferred. A
                    # file that printed `ALL TESTS PASSED` while asserting
                    # nothing has made a claim that is FALSE, and no convention
                    # is needed to say so. `#1277` measured the cost: an
                    # unconditional attacker-key enrolment in
                    # test-remote-self-enroll.sh shipping as a green suite on
                    # any host without `ssh-keygen`.
                    #
                    # Gated on the file being IN THIS REPO so a planted fixture
                    # that legitimately prints the banner cannot be accused —
                    # see `_rt_path_in_repo`.
                    # PROMOTED (your-org/nexus-code#1185): the
                    # `_rt_claims_success` conjunct is GONE. It used to restrict
                    # the red to the BANNER slice while a merely SILENT in-repo
                    # file stayed a census, on the stated ground that the census
                    # had no real members and reddening it would only hit
                    # planted fixtures. That ground was a MEASUREMENT, and the
                    # measurement has been retaken on two clean CI runners --
                    # boxes quieter than the "quiet box" #1185 asks for:
                    #
                    #   fast unit band, run 33651666674 job 100319937399:
                    #     "16424 declared ...; 0 file(s) declared no
                    #      machine-readable count"  => nocount 0, so vacuous 0
                    #   SLOW_TESTS=1 band, run 33663933682 job 100360901166
                    #   (a GREEN run on dev): nocount 1
                    #     (test-respawn-loop-integration.sh) and NO
                    #     "unverifiable pass:" row => vacuous 0
                    #
                    # So `vacuous AND in-repo` reddens NOTHING on either band
                    # today, and the fixture-convention objection is answered by
                    # PROPERTY rather than by a floor: `_rt_path_in_repo` exempts
                    # every planted fixture because they live under `mktemp -d`,
                    # outside the tree. Verified across all 39 suites that drive
                    # this runner: exactly ONE plants in-repo on purpose
                    # (test-run-tests-false-pass.sh), and that is the suite whose
                    # job is to test this discriminator.
                    #
                    # A silent in-repo file makes no claim, which is why this was
                    # deferred; but it also gives the runner nothing in EITHER
                    # channel, and a green nobody can vouch for is the thing the
                    # ratchet exists to refuse.
                    if _rt_path_in_repo "$test_path"; then
                        printf '%s\n' "$test_path" >> "$out_file.falsepass"
                    fi
                fi
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
            # BOTH STREAMS, NO LINE CAP, AND ABSENCE IS STATED
            # (your-org/nexus-code#1041 item 5). This used to be
            # `head -n 3 -- "$log_base.out"`, i.e. the first three lines of
            # STDOUT only — while `run_one` sends the test's stderr to
            # `$log_base.err`, 190 lines away, and nothing ever read it.
            # Measured: a skip whose reason was on stderr, and one whose reason
            # was on stdout line 4, both printed an EMPTY reason field. The
            # arm's own comment states the property being defeated — "a SKIP
            # whose cause is invisible is how a permanently-unrun test hides in
            # plain sight" — so the DEFINITION was the wrong half, not the
            # label.
            #
            # The 3-line cap bought nothing: `grep -m1` already stops at the
            # first match, so the cap only ever excluded reasons, never bounded
            # work. And a missing reason now SAYS SO rather than rendering as
            # whitespace — an absence a reader cannot distinguish from a blank
            # field is the same defect one level down.
            _skip_reason=$(cat -- "$log_base.out" "$log_base.err" 2>/dev/null \
                | grep -m1 -i 'skip' | sed 's/^[[:space:]]*//' | cut -c1-100)
            printf '  SKIP  %-45s  %6ss  %s\n' "$name" "$wall" \
                "${_skip_reason:-(no reason declared — the test exited 77 saying nothing)}"
            # THE ROLL-UP MUST EXIST ON THIS ARM TOO (your-org/nexus-code#1041
            # item 5, second half). `skipped_paths` was populated ONLY inside
            # the `--state` branch, so a `--jobs N` unit band with exit-77 tests
            # printed per-row SKIPs and NO roll-up at all — and that is the arm
            # `tests.yml` takes. A reader skimming to the foot of a green CI log
            # saw nothing about coverage that had declined to run.
            #
            # A sidecar, on the `.caseskipped`/`.ceilingadj` pattern, because
            # the parallel arm runs `run_one` in children that share no memory
            # with the summary scope. Carries the REASON as well as the path:
            # the per-row reason has usually scrolled away by the time anyone
            # reads the roll-up, and a list of bare paths is what made this
            # worth fixing at the row level in the first place.
            printf '%s\t%s\n' "$test_path" \
                "${_skip_reason:-(no reason declared)}" >> "$out_file.skipped"
            ;;
        ENVSKIP)
            # Rendered as its OWN row, never as a SKIP with a footnote
            # (your-org/nexus-code#1283). The two are opposite accusations —
            # "the gate did not take, so this suite left the band" versus "this
            # MACHINE could not supply what the suite needed" — and a reader
            # scanning a CI log is the last place to re-merge them.
            #
            # Same reason-extraction as SKIP and for the same reason: a decline
            # whose cause is invisible is how permanently-unrun coverage hides.
            # Both streams and no line cap (#1041 item 5); the needle is `ENV`
            # rather than `skip`, since a declining suite says ENV-INCONCLUSIVE
            # or ENV-FAIL and need not use the word "skip" at all — but an
            # absent reason SAYS SO rather than rendering as whitespace.
            _env_reason=$(cat -- "$log_base.out" "$log_base.err" 2>/dev/null \
                | grep -m1 -i 'env' | sed 's/^[[:space:]]*//' | cut -c1-100)
            printf '  ENV   %-45s  %6ss  %s\n' "$name" "$wall" \
                "${_env_reason:-(no reason declared — the test exited 69 saying nothing)}"
            printf '%s\t%s\n' "$test_path" \
                "${_env_reason:-(no reason declared)}" >> "$out_file.envskip"
            ;;
        TIMEOUT)
            # THE WALL INCLUDES `timeout -k 15`'s KILL GRACE, AND THE ROW NOW
            # SAYS SO (your-org/nexus-code#1041 item 6). A test that ignores
            # TERM is killed 15 s later, so a 1 s ceiling yields a 16 s wall —
            # measured, `trap "" TERM; sleep 25` under `--timeout 1` printed
            # 16.00s, sixteen times the ceiling, with `15` appearing nowhere in
            # the output.
            #
            # THE GRACE IS NOT SUBTRACTED, deliberately. 16 s is the honest
            # elapsed time; a runner that under-reports how long it actually
            # took, to flatter its own ceiling, is a worse instrument than one
            # that over-reports. So the LABEL changes, not the measurement.
            #
            # `rc` is printed for the same reason FAIL prints it, and its
            # absence here was the sharper half: 124 is timeout's TERM verdict
            # ("the test cleaned up") and 137 the KILL escalation ("the test
            # refused to die, and its fixture processes may still be running").
            # Those are different operational situations and the row rendered
            # them identically.
            printf '  TIMEOUT  %-42s  %6ss  (ceiling %ss +%ss KILL grace; rc=%d — NOT a pass; see #499)\n' \
                "$name" "$wall" "$PER_TEST_TIMEOUT" 15 "$rc"
            # rc 137 is not merely "slower than 124". The test ignored TERM and
            # was SIGKILLed, so its EXIT trap never ran and whatever it spawned
            # was never reaped. That is an operational fact about the machine
            # the next test is about to run on, and nothing else in the output
            # carries it.
            if (( rc == 137 )); then
                printf '      SIGKILLed after the grace — its EXIT trap did NOT run, so fixture\n'
                printf '      processes it spawned may STILL BE RUNNING and competing with the rest\n'
                printf '      of this sweep.\n'
            fi
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
    # The margin, printed beside the row it qualifies (#992). Emitted for any
    # COMPLETED outcome, so a FAIL that was also ceiling-adjacent says so —
    # a suite dying at 95% of its ceiling and a suite dying at 5% of it are two
    # different investigations.
    if [[ -n "$_ceil_pct" ]]; then
        printf '    CEILING-ADJACENT: %ss of the %ss per-test ceiling (%s%% used, %s%% margin) — a TIMEOUT here is LOAD, not a hang (#992)\n' \
            "$wall" "$PER_TEST_TIMEOUT" "$_ceil_pct" "$(( 100 - _ceil_pct ))"
        printf '%s\t%s\t%s\t%s\n' "$test_path" "$wall" "$PER_TEST_TIMEOUT" "$_ceil_pct" \
            >> "$out_file.ceilingadj"
    fi
    # Durable ledger (#499): one line per completed test, appended the
    # moment it finishes, so an interrupted run resumes instead of
    # restarting and the final tally is computed from what actually ran.
    # Field 4 is the case-level skip count (your-org/nexus-code#584 F1);
    # field 5 the DECLARED assertion count, or `?` when the suite's footer is
    # in a spelling this runner does not read (your-org/nexus-code#693).
    #
    # FIELD 5 IS AN ASSERTION COUNT OR `?`, UNCONDITIONALLY
    # (your-org/nexus-code#1041 item 10). On a FAIL row this used to be the
    # suite's *PASSED* count: a suite declaring `40 passed, 1 failed` attempted
    # 41 and wrote 40, because `_rt_declared_assertions` scrapes the first
    # integer on the footer and the header's stated equivalence ("the first
    # integer IS the executed-assertion count") holds only for a PASSING suite.
    #
    # THE PREVIOUS DEFENCE WAS "NOTHING DOWNSTREAM READS IT", AND THAT IS THE
    # WEAKEST AVAILABLE ONE. The only thing between that value and a wrong
    # total is a single `st == PASS` guard in the ledger aggregation, and a
    # correct-by-accident value nobody re-derives is this corpus's dominant
    # defect. So write `?` instead — which already means "this runner could not
    # read a count", is already mapped to `nocount` by every existing reader,
    # and makes the ledger's invariant unconditionally what the header claims.
    #
    # NOT relabelled "the suite's passed count": that would break the PASS-row
    # meaning to accommodate a row shape that should not be written that way.
    local _ledger_assertions="$n_assertions"
    [[ "$status" == PASS ]] || _ledger_assertions='?'
    # Appended, not substituted: every existing reader keys on $1/$2, so a
    # ledger written by this runner still parses in an older one.
    if [[ -n "${TALLY_FILE:-}" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$test_path" "$status" "$wall" \
            "$n_cases_skipped" "$_ledger_assertions" >> "$TALLY_FILE"
    fi
    # A SKIP is not a failure: it must not turn the runner red, and
    # --failed-only must not re-select it. `ENVSKIP` joins it for the same
    # reason and no more (your-org/nexus-code#1283): a machine's shortcoming is
    # not a product regression, so it must not red the RUNNER. That is not a
    # clearance and is not where an ENVSKIP is adjudicated — in the blocking
    # slow band `slow-band-drift.sh` scores it rc 4 ENV-UNPROVEN, explicitly
    # "not a pass and not a regression". In the fast band it is reported and
    # non-red exactly as a SKIP already is; making it red THERE would recreate
    # `#1283` in the other band, with the accusation pointing at the machine.
    [[ "$status" == PASS || "$status" == SKIP || "$status" == ENVSKIP ]]
}
# ONE SIGNALLED CHILD MUST NOT TRUNCATE THE SWEEP (your-org/nexus-code#1083).
#
# `xargs` stops reading input IMMEDIATELY, without dispatching anything
# further, as soon as any child is terminated BY A SIGNAL. So a single
# signalled child silently converts a full sweep into a partial one. Measured
# on this host, 20 items at -P 4 with item 5 killed by SIGTERM:
#
#   child KILLED by SIGTERM (WIFSIGNALED)  ->   7 of 20 ran, xargs rc 125
#   child EXITS 90 (a normal 1-125 status) ->  19 of 20 ran, xargs rc 123
#
# THE DISTINCTION IS `WIFSIGNALED`, NOT THE NUMBER. A child that *exits* with
# status 143 does NOT trip this — measured, 19 of 20 ran at rc 123 — so a
# fixture built by "exit 143" reproduces nothing and comes back clean for the
# wrong reason. Only a genuine signal death does it.
#
# The remedy is therefore to make a signalled child DIE LIKE AN EXIT: trap the
# fatal signals in the xargs child, record what happened, and leave with a
# status in 1-125. `xargs` then keeps dispatching, and the run loses exactly
# the one test that was interrupted instead of every test after it.
#
# THE RECORD IS THE POINT, not the containment. Swallowing a signal to keep
# the batch alive, without saying so, would convert a loud truncation into a
# quiet one — the exact trade this repo must never make. The sidecar names the
# interrupted test and the signal, the aggregation below turns it into a
# banner, and the run exits 4: NOT A VERDICT. Containment buys back the other
# 141 tests; it does not buy silence about the one that was killed.
#
# A per-child sidecar keyed on `$$`, matching every other sidecar here: the
# parallel arm runs in children that share no memory with this scope.
# THE WRITE IS NOT ALLOWED TO FAIL QUIETLY. A `2>/dev/null` here would make a
# lost record indistinguishable from no signal at all — and that is not a
# hypothetical: the first cut of this fix did exactly that, wrote to a path
# that could not exist, and turned a LOUD truncation into a silent one while
# every other symptom looked repaired. If the sidecar cannot be written, say
# so on stderr, where the runner's failure-tail machinery will surface it.
_rt_child_signalled() {   # $1 = test path, $2 = run_dir, $3 = signal name
    if ! printf '%s\t%s\n' "$1" "$3" >> "$2/child.$$.signalled"; then
        printf 'run-tests.sh: %s was killed by SIG%s and the record could NOT be written to %s\n' \
            "$1" "$3" "$2/child.$$.signalled" >&2
        printf '  The sweep is TRUNCATED and this run cannot account for it (#1083).\n' >&2
    fi
    exit 90
}
export -f _rt_child_signalled
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
# NEW CALLEES OF run_one MUST BE EXPORTED TOO, or the PARALLEL arm silently
# loses them. `xargs … bash -c` gets a FRESH shell, so a helper that is merely
# defined in this file is `command not found` there — and both of these fail
# TOWARD PERMISSIVENESS, which is why the omission is not self-announcing:
# `_rt_ceiling_for` missing leaves PER_TEST_TIMEOUT EMPTY, so the per-test
# ceiling is DISABLED for every parallel child, and `#499`'s hard bound
# silently stops applying; `_rt_emitted_assertion_lines` missing makes the
# `#1185` conjunction unevaluable. Caught only by running the real band —
# `--jobs 1` cannot see it, and the serial arm is the one most local testing
# uses (your-org/nexus-code#992, #1185).
export -f _rt_ceiling_for
export -f _rt_emitted_assertion_lines
# The two `#1277` companions travel with it, for the reason stated above this
# block: a helper merely DEFINED here is `command not found` in the parallel
# arm's fresh `bash -c`, and both of these fail toward PERMISSIVENESS — an
# unexported `_rt_claims_success` makes every parallel child decide "no banner",
# and an unexported `_rt_path_in_repo` makes every one decide "not in the repo".
# Either omission silently disarms the gate on exactly the path CI uses.
export -f _rt_claims_success
export -f _rt_path_in_repo
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
# (your-org/nexus-code#1041 item 9) A `touch "$run_dir/failed"` used to sit
# here. It was DEAD: the aggregation reads `find … -name '*.failed'`, which
# requires a literal dot, so a file named `failed` could never match — verified
# with a planted pair, and `git grep -F run_dir/failed` finds no reader
# anywhere in the repo.
#
# DELETED RATHER THAN RENAMED, which is the whole judgement. Renaming it to
# `*.failed` would be WORSE than the bug: it feeds an empty line into
# `failed_paths` on every run, and makes an all-green run indistinguishable
# from one whose sidecars vanished. And what it appears to guard — `cat` with
# no arguments hanging on stdin — CANNOT HAPPEN: measured, `find DIR -name
# '*.failed' -exec cat {} +` over a directory with zero matches is SILENT at
# rc 0, because `-exec … +` never execs `cat` when nothing matched. The write
# was a fossil of a misapprehension, so the fix is to remove it, not to make
# it load-bearing.

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
# DEDUPLICATE ONCE, AT SELECTION (your-org/nexus-code#1041 item 7). There was
# no uniqueness check anywhere, so one file listed twice produced two rows, two
# ledger rows, and a DOUBLED assertion total — while `.caseskipped`,
# `.nocount`, `.zerocount` and `.ceilingadj` are all `sort -u`'d and
# `.assertions` is not. That asymmetry is the defect worth naming: two figures
# in the same footer stopped describing the same population, and the reader was
# given a count ("10 assertions across N passing file(s)") immediately above a
# list enumerating fewer files than the count claimed.
#
# FIXED HERE RATHER THAN BY `sort -u`-ING `.assertions`, and that is the whole
# judgement. `.assertions` holds COUNTS, not paths: deduping it would collapse
# two genuinely distinct suites that each declared 5 into one, turning a
# VISIBLE over-count into an INVISIBLE under-count. Deduplicating the selection
# instead makes every downstream figure describe one population for free — the
# existing `sort -u`s become redundant-but-harmless, `_n_pass_files`'s mixing
# of an undeduped LINE count with a deduped PATH count becomes sound, the
# `.failed`/`.timedout` lists stop double-listing in the "re-run with
# --failed-only" block, and the ledger loop over `all_selected` stops
# double-counting on the `--state` path too. One fix, six symptoms.
#
# Order-preserving: `sort -u` here would silently reorder a caller's explicit
# argument list, and the runner prints rows in dispatch order.
_dedup=(); declare -A _seen_sel=()
for _t in "${tests[@]:-}"; do
    [[ -n "$_t" ]] || continue
    [[ -n "${_seen_sel[$_t]:-}" ]] && continue
    _seen_sel[$_t]=1; _dedup+=("$_t")
done
if (( ${#_dedup[@]} != ${#tests[@]} )); then
    printf '=== %d duplicate selection(s) dropped — a file listed twice would double-count its assertions (#1041) ===\n' \
        "$(( ${#tests[@]} - ${#_dedup[@]} ))"
fi
tests=("${_dedup[@]}")
unset _dedup _seen_sel _t

# The FULL selection, kept for the final accounting.
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

# WHICH TREE this run is a claim about (your-org/nexus-code#1465). A suite
# result is a property of a tree: the header above records nproc, the count
# and the interpreter, and without the ref a green log carried to another
# checkout silently describes something else (CLAUDE.md, count-provenance).
#
#   ref       the FULL 40-char sha, never `--short`: an abbreviated hash's
#             width is a property of the READING repository's object count,
#             so a short one is not matchable across clones (#1249).
#   branch    `--abbrev-ref HEAD`, or `detached`.
#   dirty     yes when `status --porcelain --untracked-files=normal` is
#             non-empty — an UNTRACKED new suite counts, because it is in the
#             population the runner just enumerated and in no commit.
#   worktree  linked when the git dir is not the common dir (a `git worktree
#             add` tree), else main.
#
# ROOTED AT _RT_REPO_ROOT, NEVER $PWD, AND GATED BY repo-root.sh. `git -C` on
# a directory that is not its own repository does not fail — it WALKS UP and
# answers about the enclosing repository at rc 0 (#1196). A runner copied into
# an un-versioned fixture under some checkout would otherwise stamp that
# checkout's sha onto the fixture's log, which is a confident wrong ref, the
# one shape a provenance line must never produce. So a walked-up answer prints
# `ref=UNKNOWN (dir is not its own repository root)`, and no git at all prints
# `ref=UNKNOWN (not a git checkout)` — never a blank, never a borrowed sha.
_rt_tree_line() {
    local root="${_RT_REPO_ROOT:-}" rr="$_self_dir/../repo-root.sh"
    local kind='' rrline='' sha='' branch='' dirty='' wt='' st='' top='' gd='' cd_=''
    if [[ -z "$root" || ! -d "$root" ]] || ! command -v git >/dev/null 2>&1; then
        printf 'ref=UNKNOWN (not a git checkout)\n'; return 0
    fi
    # Every git call drops an ambient GIT_DIR/GIT_WORK_TREE, as repo-root.sh
    # does: an exported pair would redirect `-C` to a repository that is not
    # the one under `$root`.
    _rt_git() { env -u GIT_DIR -u GIT_WORK_TREE git -C "$root" "$@"; }
    if [[ -r "$rr" ]]; then
        rrline=$(bash "$rr" "$root" 2>/dev/null) || true
        kind=$(sed -n 's/^verdict=[^ ]* kind=\([^ ]*\).*/\1/p' <<<"$rrline")
        case "$kind" in
            root)            wt=main ;;
            linked-worktree) wt=linked ;;
            none|absent|unreadable|git-unavailable|error|'')
                printf 'ref=UNKNOWN (not a git checkout)\n'; return 0 ;;
            *)  # subdir, gitdir-stub, gitdir-itself, inside-gitdir, bare, …:
                # a sha from here would be the ENCLOSING repository's.
                printf 'ref=UNKNOWN (dir is not its own repository root: kind=%s)\n' "$kind"
                return 0 ;;
        esac
    else
        # No predicate beside this runner (a bare copy in a fixture): the two
        # discriminators CLAUDE.md names, applied by hand.
        top=$(_rt_git rev-parse --show-toplevel 2>/dev/null) || {
            printf 'ref=UNKNOWN (not a git checkout)\n'; return 0; }
        [[ -n "$top" && "$(cd "$top" 2>/dev/null && pwd -P)" == "$root" ]] || {
            printf 'ref=UNKNOWN (dir is not its own repository root)\n'; return 0; }
        gd=$(_rt_git rev-parse --absolute-git-dir 2>/dev/null) || gd=''
        cd_=$(_rt_git rev-parse --git-common-dir 2>/dev/null) || cd_=''
        [[ -n "$cd_" && "$cd_" != /* ]] && cd_="$root/$cd_"
        gd=$(cd "$gd" 2>/dev/null && pwd -P) || gd=''
        cd_=$(cd "$cd_" 2>/dev/null && pwd -P) || cd_=''
        if [[ -n "$gd" && -n "$cd_" && "$gd" != "$cd_" ]]; then wt=linked; else wt=main; fi
    fi
    sha=$(_rt_git rev-parse HEAD 2>/dev/null) || sha=''
    # An unborn HEAD (init, no commit) answers `HEAD` at rc 128; anything that
    # is not 40 hex is not a ref and must not be printed as one.
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { printf 'ref=UNKNOWN (not a git checkout)\n'; return 0; }
    branch=$(_rt_git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=''
    [[ -n "$branch" && "$branch" != HEAD ]] || branch=detached
    if st=$(_rt_git status --porcelain --untracked-files=normal 2>/dev/null); then
        if [[ -n "$st" ]]; then dirty=yes; else dirty=no; fi
    else
        dirty=unknown   # `status` itself failed: say so rather than guess `no`
    fi
    printf 'ref=%s branch=%s dirty=%s worktree=%s\n' "$sha" "$branch" "$dirty" "$wt"
}
printf '=== tree: %s ===\n' "$(_rt_tree_line)"

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
                '_rt_test="$1"; _rt_dir="$2"
                 trap '"'"'_rt_child_signalled "$_rt_test" "$_rt_dir" TERM'"'"' TERM
                 trap '"'"'_rt_child_signalled "$_rt_test" "$_rt_dir" INT'"'"'  INT
                 trap '"'"'_rt_child_signalled "$_rt_test" "$_rt_dir" HUP'"'"'  HUP
                 trap '"'"'_rt_child_signalled "$_rt_test" "$_rt_dir" QUIT'"'"' QUIT
                 # Trapped, so this child leaves by `exit 90` rather than by
                 # signal death, and `xargs` keeps dispatching (#1083).
                 #
                 # NAMED VARIABLES, NOT `$1`/`$2`, AND THIS IS THE WHOLE POINT.
                 # The trap bodies are single-quoted, so they expand when the
                 # signal ARRIVES — and the signal arrives while `run_one` is
                 # on the stack, where `$1`/`$2` are RUN_ONE'"'"'S parameters:
                 # `$2` is the per-test out_file, not the run dir. The first
                 # cut of this fix used `$1`/`$2` and therefore appended to
                 # `<a regular file>/child.$$.signalled`, which cannot exist —
                 # so the write failed, `2>/dev/null` ate the error, the child
                 # still exited 90, and the run reported NO signal at all.
                 # Measured: 11 of 12 tests recovered (containment worked) and
                 # `n_signalled` was 0, so it exited 1 instead of 4. That is
                 # this file'"'"'s own disease reproduced inside its own
                 # remedy: containment WITHOUT the record is a truncation made
                 # quiet, which is strictly worse than the loud one it
                 # replaced. Plain variables are immune to function scope.
                 o=$(mktemp -p "$2" out-XXXXXX) && [ -n "$o" ] || {
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
# Suites that COMPLETED but used most of their per-test ceiling (#992). Same
# per-job sidecar shape as `.caseskipped`, for the same reason: the band has to
# survive the parallel arm, where `run_one` runs in a child that shares no
# memory with this scope.
ceiling_adj=()
while IFS= read -r line; do
    [[ -n "$line" ]] && ceiling_adj+=("$line")
done < <(find "$run_dir" -name '*.ceilingadj' -exec cat {} + 2>/dev/null | LC_ALL=C sort -u)
# Children that were KILLED BY A SIGNAL (your-org/nexus-code#1083). Each row is
# `<test path>\t<signal>`, written by `_rt_child_signalled` in the child that
# received it. This is an ENVIRONMENT event — a process-group kill from a
# sibling suite, an OOM reaper, an operator stopping a run — and it is
# categorically not a test result, which is why it gets its own exit code
# below rather than being folded into the FAIL count.
# Files that DECLINED TO RUN (your-org/nexus-code#1041 item 5). Aggregated on
# the same per-job sidecar pattern as `.caseskipped`, so the roll-up survives
# the parallel arm. Under a ledger this is recomputed from the ledger below —
# the ledger is the durable record of the whole sweep, while these sidecars
# cover only this invocation.
skipped_rows=()
while IFS= read -r line; do
    [[ -n "$line" ]] && skipped_rows+=("$line")
done < <(find "$run_dir" -name '*.skipped' -exec cat {} + 2>/dev/null | LC_ALL=C sort -u)

# Files that RAN AND DECLINED ON ENVIRONMENT GROUNDS (#1283). Its own sidecar
# rather than a flag on `.skipped`, so the parallel arm cannot re-merge the two
# declines the status split exists to separate.
envskip_rows=()
while IFS= read -r line; do
    [[ -n "$line" ]] && envskip_rows+=("$line")
done < <(find "$run_dir" -name '*.envskip' -exec cat {} + 2>/dev/null | LC_ALL=C sort -u)

signalled_rows=()
while IFS= read -r line; do
    [[ -n "$line" ]] && signalled_rows+=("$line")
done < <(find "$run_dir" -name '*.signalled' -exec cat {} + 2>/dev/null | LC_ALL=C sort -u)
n_signalled=${#signalled_rows[@]}

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
# `.vacuous` — the CONJUNCTION (your-org/nexus-code#1185): footer unreadable AND
# no per-assertion line emitted. A strict subset of `nocount_paths`, carried as
# its own sidecar rather than derived here, because the second signal is only
# available in `run_one`, where the suite's log is still to hand.
vacuous_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && vacuous_paths+=("$line")
done < <(find "$run_dir" -name '*.vacuous' -exec cat {} + 2>/dev/null | sort -u)
# `.falsepass` — the strict subset of `.vacuous` that also printed a success
# BANNER and is a file of this repo (your-org/nexus-code#1277). Unlike its
# parent it is a RED, because a false statement needs no convention to condemn.
falsepass_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && falsepass_paths+=("$line")
done < <(find "$run_dir" -name '*.falsepass' -exec cat {} + 2>/dev/null | sort -u)
# `.acctcensus` — one row per IN-REPO suite that reached a verdict: assertion
# lines emitted, the footer's passed count, its failed count (or `?`), and
# holds|mismatch|uncomparable. Reported, never acted on (rationale in run_one).
acctcensus_rows=()
while IFS= read -r line; do
    [[ -n "$line" ]] && acctcensus_rows+=("$line")
done < <(find "$run_dir" -name '*.acctcensus' -exec cat {} + 2>/dev/null | LC_ALL=C sort -u)
zerocount_paths=()
while IFS= read -r line; do
    [[ -n "$line" ]] && zerocount_paths+=("$line")
done < <(find "$run_dir" -name '*.zerocount' -exec cat {} + 2>/dev/null | sort -u)

# Persist failures for --failed-only on the next run (timeouts included — they
# are failures until they finish).
#
# UNDER A LEDGER THIS IS A UNION, NOT AN OVERWRITE (your-org/nexus-code#1041
# item 1). The comment here used to promise "under --resume, MERGE with the
# still-unrun remainder so a budget-stopped sweep never shrinks the set", and
# there was no merge — one unconditional write and one unconditional truncate.
# Measured on two invocations of the same resumed sweep:
#
#   inv1 rc=1  last-failures.txt lines: 1
#   inv2 rc=1  last-failures.txt lines: 0   <- resumed; nothing NEW failed
#   ledger still records the FAIL: 1
#   $ run-tests.sh --failed-only
#   run-tests.sh: no previous failures recorded at …/last-failures.txt
#
# The verdict stayed correct (rc 1, from the ledger); what was destroyed is the
# re-run set the footer two lines earlier tells you to use — and
# `.github/workflows/tests.yml` reads this file. A silent zero in the runner's
# own state, which is the house defect class.
#
# THE FIX IS SPLIT, because the promise had two halves and only one was right.
#
#   FAILURES half — DEFINITION was wrong, so the code changes. The ledger is the
#   durable record of the whole sweep, so when there is one, take the union of
#   every FAIL/TIMEOUT row in it with this invocation's failures. A later
#   invocation can then no longer erase an earlier one's red.
#
#   STILL-UNRUN half — LABEL was wrong, so the promise goes. Folding unrun tests
#   into a file named `last-failures.txt` would make `--failed-only` re-run
#   tests that never failed, and "finish the sweep" is already exactly what
#   `--resume` does. Implementing it would have duplicated `--resume` under a
#   name that means something else.
if [[ -n "$tally_file" && -s "$tally_file" ]]; then
    # LAST ROW WINS, PER PATH — the same rule the ledger aggregation itself uses
    # (`$1==p{s=$2} END{print s}`), and getting this wrong is how the first cut
    # of this fix broke the OTHER direction. `run_one` APPENDS a row per
    # invocation, so a test that failed and was later fixed has BOTH a FAIL row
    # and a PASS row. A naive `$2 == "FAIL"` over every row therefore pins it in
    # `last-failures.txt` permanently, and `--failed-only` re-runs a passing
    # test forever. Measured: fail, fix, re-run green — runner correctly exits
    # 0, and the naive form still reported `last-failures: 1`.
    #
    # So the union is with the ledger's CURRENT verdict per path, not with every
    # verdict it has ever held. Reading the ledger this way also means the set
    # SHRINKS when a test goes green, which a plain file union could never do —
    # the whole point of deriving from the ledger rather than merging files.
    awk -F'\t' '
        { st[$1] = $2 }
        END { for (path in st) if (st[path] == "FAIL" || st[path] == "TIMEOUT") print path }
    ' "$tally_file" > "$_failures_file".tmp 2>/dev/null || : > "$_failures_file".tmp
    {
        (( ${#failed_paths[@]} > 0 )) && printf '%s\n' "${failed_paths[@]}"
        cat "$_failures_file".tmp
    } | grep -v '^$' | sort -u > "$_failures_file" || : > "$_failures_file"
    rm -f "$_failures_file".tmp
elif (( ${#failed_paths[@]} > 0 )); then
    printf '%s\n' "${failed_paths[@]}" > "$_failures_file"
else
    : > "$_failures_file"
fi

if (( profile )); then
    # A HEADING WITH NO BODY IS A LABEL WITH NO COMPUTATION — found sweeping
    # the #1031/#997 class, and the most literal member of it. This block used
    # to print the heading and then nothing at all (its body was a comment
    # reading "Skip — wall-time is already inline"), while usage line 10 and
    # `--help` both advertised `print per-file wall-time`. What actually
    # followed the heading was the next banner, `=== suite total: …`, which a
    # reader is invited to take as its content.
    #
    # Derived from `.accounted`, deliberately: that record is written once per
    # verdict above the outcome `case`, and is the same input the #877
    # reconciliation uses — so the profile cannot describe a different
    # population from the tally printed beside it.
    echo
    echo "=== per-file wall-time (sorted desc) ==="
    _prof=$(find "$run_dir" -name '*.accounted' -exec cat {} + 2>/dev/null \
            | awk -F'\t' 'NF >= 3 && $3 ~ /^[0-9.]+$/ { printf "%s\t%s\t%s\n", $3, $2, $1 }' \
            | LC_ALL=C sort -rn)
    if [[ -n "$_prof" ]]; then
        while IFS=$'\t' read -r _pw _ps _pp; do
            [[ -n "$_pp" ]] || continue
            if [[ "${PER_TEST_TIMEOUT:-0}" =~ ^[0-9]+$ ]] && (( ${PER_TEST_TIMEOUT:-0} > 0 )); then
                printf '  %9ss  %-8s %3s%% of ceiling  %s\n' "$_pw" "$_ps" \
                    "$(awk -v w="$_pw" -v c="$PER_TEST_TIMEOUT" 'BEGIN{printf "%d", 100*w/c}')" "$_pp"
            else
                printf '  %9ss  %-8s  %s\n' "$_pw" "$_ps" "$_pp"
            fi
        done <<< "$_prof"
    else
        # NOT "no slow tests" — say which. An empty table under a heading is
        # how this defect looked in the first place.
        echo "  (no wall-times recorded — no test reached a verdict in this invocation)"
    fi
    if [[ -n "$tally_file" ]]; then
        echo "  (this invocation only — a resumed test wrote no sidecar here)"
    fi
    unset _prof
fi

# --- honest accounting (#499) ---------------------------------------------
# With a --state ledger, the tally is computed over the FULL selection:
# every selected test must terminate as PASS, FAIL, or TIMEOUT before the
# runner will read green. Anything unrecorded is reported as such — a
# test that never ran is not a pass.
n_pass=0; n_fail=0; n_timeout=0; n_skip=0; n_unrecorded=0
n_envskip=0
n_case_skips=0; n_case_skip_files=0
skipped_paths=()
# DECLARED UNCONDITIONALLY, beside the counter it parallels. The ledger arm
# below is the only writer, but this script runs under `set -u` and the
# roll-up at the foot reads `${#envskip_paths[@]}` on EVERY path — including
# the sidecar (`--jobs N`) path that never enters the ledger branch.
envskip_paths=()
if [[ -n "$tally_file" ]]; then
    # The ledger SUPERSEDES the per-job sidecars gathered above — it covers the
    # whole sweep including tests this invocation resumed past, and adding to
    # the sidecar totals instead of replacing them would double-count every
    # test that ran just now.
    #
    # `caseskipped_paths` is REBUILT here for the same reason and it was not
    # before — a defect found sweeping the #1031/#997 class rather than filed
    # against. The counted line below (`=== N CASE(S) SKIPPED across M passing
    # file(s) ===`) came from the LEDGER, i.e. the whole sweep, while the LIST
    # printed at the foot of the run (`PASSED but with SKIPPED CASES:`) came
    # from THIS INVOCATION's sidecars. Under --resume those are different
    # populations, so the run could state a number and then name fewer files
    # than it had just claimed — a count and its own evidence describing
    # different sets, in one output, with nothing to say so. Same class as the
    # two defects this branch is about: the label (`M passing file(s)`) and the
    # computation behind the list had drifted apart.
    # `vacuous_paths` is NOT reconstructible here and is deliberately left EMPTY.
    # The ledger records the assertion COUNT, not whether the suite emitted any
    # per-assertion line, and that second signal lives only in the suite's log
    # during `run_one`. So a resumed sweep under-reports this gate rather than
    # guessing — the same direction `nocount` already errs in, and stated so a
    # reader does not read an empty list as "none found" (your-org/nexus-code#1185).
    n_assert_total=0; nocount_paths=(); zerocount_paths=(); caseskipped_paths=()
    vacuous_paths=()
    # `falsepass_paths` is derived from `vacuous_paths` plus the suite's log, so
    # it is unreconstructible here for the same reason and left EMPTY rather than
    # guessed (your-org/nexus-code#1277). A resumed sweep therefore UNDER-reports
    # this gate — the same direction `nocount` and `vacuous` already err in, and
    # said here so an empty list is not read as "none found".
    falsepass_paths=()
    for t in "${all_selected[@]}"; do
        st=$(awk -F'\t' -v p="$t" '$1==p{s=$2} END{print s}' "$tally_file")
        cs=$(awk -F'\t' -v p="$t" '$1==p{s=$4} END{print s}' "$tally_file")
        [[ "$cs" =~ ^[0-9]+$ ]] || cs=0
        if (( cs > 0 )); then
            n_case_skips=$(( n_case_skips + cs ))
            n_case_skip_files=$(( n_case_skip_files + 1 ))
            caseskipped_paths+=("$t")
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
            # ENVSKIP is counted SEPARATELY and never folded into SKIP
            # (your-org/nexus-code#1283) — folding them would re-merge at the
            # summary exactly the two facts the status split exists to keep
            # apart. Its own arm also keeps it out of the `*)` default, where
            # it would be tallied `not yet run` and the run would under-report
            # its own coverage while reading green.
            ENVSKIP) n_envskip=$(( n_envskip + 1 )); envskip_paths+=("$t") ;;
            *)       n_unrecorded=$(( n_unrecorded + 1 )) ;;
        esac
    done
    # The load rides this line too (your-org/nexus-code#1445, residual): the
    # non-ledger `suite total:` line already carries it, and a `--state` run is
    # the one a bundler reads back hours later, when `uptime` is gone.
    printf '=== ledger %s: %d PASS, %d SKIP, %d ENVSKIP, %d FAIL, %d TIMEOUT, %d not yet run (of %d selected; this invocation: %ss) — loadavg %s on %s cpus ===\n' \
        "$tally_file" "$n_pass" "$n_skip" "$n_envskip" "$n_fail" "$n_timeout" "$n_unrecorded" \
        "${#all_selected[@]}" "$total" \
        "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')" "$(nproc 2>/dev/null || echo '?')"
    # The whole point of A6: PASS is now an evidence claim, so say plainly
    # how much of the selection produced no evidence at all.
    if (( n_skip > 0 )); then
        printf '=== %d of %d selected tests DECLINED TO RUN — the PASS count is not a coverage claim over them ===\n' \
            "$n_skip" "${#all_selected[@]}"
    fi
    # SEPARATE SENTENCE, NOT A LARGER NUMBER (your-org/nexus-code#1283). An
    # ENVSKIP is also uncovered ground and must be said so — the A6 claim that
    # "PASS is an evidence claim" is false the moment a decline goes unstated.
    # But it is uncovered for a DIFFERENT reason, and adding it to `n_skip`
    # would recreate at the summary the exact conflation the status split
    # exists to end: a reader could no longer tell "the gate did not take" from
    # "this machine could not".
    if (( n_envskip > 0 )); then
        printf '=== %d of %d selected tests RAN AND DECLINED ON ENVIRONMENT GROUNDS — no verdict either way about them ===\n' \
            "$n_envskip" "${#all_selected[@]}"
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
        # The load is printed BESIDE the count (your-org/nexus-code#1445): two of
        # the six reds in that issue's full run were load artefacts, and a reader
        # of a bare `6 failed` had no way to know. `/proc/loadavg` 1/5/15 plus
        # the CPU count, so the number is comparable across hosts.
        printf '=== suite total: %ss across %d tests; %d failed (%d of those TIMEOUT) — loadavg %s on %s cpus ===\n' \
            "$total" "${#tests[@]}" "${#failed_paths[@]}" "${#timedout_paths[@]}" \
            "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo '?')" "$(nproc 2>/dev/null || echo '?')"
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
# THE SWEEP WAS CUT SHORT BY A SIGNAL (your-org/nexus-code#1083). Printed
# BEFORE the dispatch banner because it is the CAUSE and that is the symptom:
# a reader who sees only `DISPATCH FAILED — exited 123` learns that something
# went wrong, not that the machine interrupted the run.
if (( n_signalled > 0 )); then
    printf '::error::SWEEP INTERRUPTED — %d dispatch child process(es) were KILLED BY A SIGNAL. This is NOT a test result.\n' \
        "$n_signalled"
    printf '%s\n' "${signalled_rows[@]}" | sed 's/^/    killed: /'
    echo "    A signal is an ENVIRONMENT event — a sibling suite's process-GROUP kill, an"
    echo "    OOM reaper, an operator stopping the run — not a verdict about the code under"
    echo "    test. The interrupted test(s) produced NO verdict, so the counts above are a"
    echo "    LOWER BOUND on both the passes and the failures."
    echo "    Before #1083 this ALSO truncated the sweep: xargs stops dispatching the moment"
    echo "    any child is signalled, so one kill silently converted a full run into a"
    echo "    partial one (measured: 7 of 20 items ran). Those children are now trapped and"
    echo "    leave by exit 90, so the rest of the batch still runs — but the run is still"
    echo "    not a verdict, and it exits 4 rather than 1 to say so."
    echo "    Re-run; if it recurs, find what is signalling the batch (see #1083, #851)."
fi

if (( dispatch_rc != 0 )); then
    printf '::error::DISPATCH FAILED — the parallel dispatcher exited %d, so at least one test did not complete normally.\n' \
        "$dispatch_rc"
    case "$dispatch_rc" in
        123) echo "    123 = at least one child exited 1-125. run_one returns 0 for a test that" ;
             echo "          merely FAILED, so this is a child that could not run the test at all" ;
             echo "          (a refused mktemp exits 97 here, and a child that CAUGHT a fatal" ;
             echo "          signal exits 90 — see the SWEEP INTERRUPTED banner above, which" ;
             echo "          names the test and the signal; #1083)." ;;
        124) echo "    124 = a child exited 255." ;;
        125) echo "    125 = a child was killed by a signal WITHOUT running its trap." ;
             echo "          Since #1083 the children trap TERM/INT/HUP/QUIT and leave by exit" ;
             echo "          90, so reaching 125 means an UNTRAPPABLE signal (SIGKILL, SIGSTOP-" ;
             echo "          then-reaped) or one that arrived before the traps were installed." ;
             echo "          xargs stops dispatching here, so the sweep is TRUNCATED: every" ;
             echo "          test after this point never ran and is absent, not passing." ;;
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
# WHAT "ACROSS THE RUN" MEANT, and why the label moved rather than the sum
# (found sweeping the #1031/#997 class; both independent sweeps flagged it).
# `n_assert_total` is summed from `.assertions`, which ONLY the PASS arm
# writes — so a red suite's declared count, though computed at
# `_rt_declared_assertions` time for PASS and FAIL alike, contributes nothing.
# On a run with failures the headline coverage figure understates by exactly
# the failing suites' work, which is when a reader is most likely to be asking
# how much evidence exists.
#
# THE LABEL IS THE WRONG HALF HERE, and that is a judgement, not a default: a
# failing suite's footer count is not evidence of coverage — its `N passed` is
# the count before it went red, and folding that into a coverage total would
# make a red run look better-covered than a green one. So the computation
# stays and the wording states its population.
#
# SECOND, the SCOPE differs by path and one wording served both: the ledger arm
# recomputes over the whole resumed sweep, the sidecar arm covers only this
# invocation. Printed directly beneath `this invocation: Ns`, "across the run"
# read as the latter on both.
printf '=== assertions: %d declared across %s PASSING file(s); %d file(s) declared no machine-readable count ===\n' \
    "$n_assert_total" \
    "$( [[ -n "$tally_file" ]] && printf 'the whole sweep%s' "'s" || printf "this invocation's" )" \
    "${#nocount_paths[@]}"

# --- ACCOUNTING CENSUS (your-org/nexus-code#1308 §1) ------------------------
# Rationale and bounds in `run_one`. THE THREE COUNTS PRINT TOGETHER AND ALWAYS,
# so a `MISMATCH: 0` cannot be read off a run that could compare nothing:
# `uncomparable` is the instrument's own blind spot and belongs beside the
# number it bounds. Under `--resume` the previous invocation's sidecars are
# gone, so this covers THIS INVOCATION and says so.
if (( ${#acctcensus_rows[@]} > 0 )); then
    _acc_holds=0; _acc_mis=0; _acc_unc=0
    for _row in "${acctcensus_rows[@]}"; do
        case "${_row##*$'\t'}" in
            holds)    _acc_holds=$(( _acc_holds + 1 )) ;;
            mismatch) _acc_mis=$(( _acc_mis + 1 )) ;;
            *)        _acc_unc=$(( _acc_unc + 1 )) ;;
        esac
    done
    printf '=== accounting census (this invocation): %d hold, %d MISMATCH, %d uncomparable, of %d in-repo suite(s) ===\n' \
        "$_acc_holds" "$_acc_mis" "$_acc_unc" "${#acctcensus_rows[@]}"
    if (( _acc_mis > 0 )); then
        printf '    A suite emitted more assertion lines than its own footer accounts for.\n'
        printf '    NOT a verdict about the code under test. TWO candidate causes, and this\n'
        printf '    runner CANNOT TELL THEM APART — it reports the number and stops:\n'
        printf '      (1) an assertion whose PRINT escaped a subshell while its COUNT did not\n'
        printf '          (your-org/nexus-code#805 variant 2, #783). Measured in this repo\n'
        printf '          at test-eligibility-resurface.sh:280-285 @ 0b82ffb2 (fixed since).\n'
        printf '      (2) two writers sharing one captured file (#1308 §1) — e.g. two runs\n'
        printf '          against one --keep-logs dir.\n'
        printf '    WHAT DISTINGUISHES THEM, from artefacts you already have:\n'
        printf '      * RE-RUN THE SUITE ALONE. (1) is deterministic and reproduces exactly;\n'
        printf '        (2) does not survive isolation.\n'
        printf '      * READ THE EXCESS LINES LABELS in the .out. (1) leaves DISTINCT labels,\n'
        printf '        each appearing once; (2) duplicates labels, or leaves two footers.\n'
        printf '      * Look for an explicit ( … ) around an assertion call, and whether the\n'
        printf '        suite sources _test_helpers.sh — without it there is no _TH_LEDGER and\n'
        printf '        none of the #805 upward reconciliation, so (1) is unprotected.\n'
        printf '    Cause (1) is BENIGN in this direction (an undercount on a PASSING suite)\n'
        printf '    and is NOT benign on a FAILING assertion: the same loss leaves FAIL at 0\n'
        printf '    in the parent and the suite exits 0 over a red assertion.\n'
        printf '    %-58s %s\n' 'suite' 'lines / footer passed+failed'
        for _row in "${acctcensus_rows[@]}"; do
            [[ "${_row##*$'\t'}" == mismatch ]] || continue
            printf '    %-58s %s / %s+%s\n' \
                "$(printf '%s' "$_row" | cut -f1)" "$(printf '%s' "$_row" | cut -f2)" \
                "$(printf '%s' "$_row" | cut -f3)" "$(printf '%s' "$_row" | cut -f4)"
        done
    fi
    if (( _acc_unc > 0 )); then
        printf '    COVERAGE BOUNDARY: %d suite(s) UNCOMPARABLE — this runner could not read a\n' "$_acc_unc"
        printf '    passed and/or failed count from their footer, so they are counted in NEITHER\n'
        printf '    column above. Not a defect in those suites: a spelling it does not normalise.\n'
    fi
    printf '    Recogniser: the alternation _rt_assertion_line_count shares with\n'
    printf '    _rt_emitted_assertion_lines — TAP ok/not ok, PASS|FAIL|XFAIL + :.)- and the\n'
    printf '    tick/cross glyphs. SKIP:/TODO: are NOT assertions (#1277); any other per-case\n'
    printf '    vocabulary is invisible to it. It is also BLIND to the #922 missing-helper\n'
    printf '    shape (rc 127 prints nothing and counts nothing, so the invariant holds).\n'
    printf '    Planted fixtures are excluded by _rt_path_in_repo, not by a path list.\n'
    unset _acc_holds _acc_mis _acc_unc _row
fi

# HARNESS GUARD. `?` was designed as the loud value — and it is not loud enough,
# because "this runner could not read the footer" and "this runner could not RUN"
# render identically. When _rt_declared_assertions was missing from every
# parallel child, all 245 suites read `?` and the footer said `0 declared`: a
# plausible number, printed with total confidence, on a green run.
#
# Every suite in the repo declares a count, so EVERY passing file reading `?`
# is not a corpus-wide simultaneous regression — it is the harness.
# Say so and go RED. A per-file `?` stays a normalisation note; only the
# all-of-them case is an error, so normalisation debt never turns a run red.
# THIS INVOCATION, ON BOTH PATHS (your-org/nexus-code#1041 item 3). The guard
# below asserts "the READER DID NOT RUN", which is a claim about THIS
# invocation — so both of its inputs must be measured from this invocation's
# sidecars, on the ledger path too.
#
# They were not. Under a ledger `_n_pass_files` was `n_pass`, i.e. every PASS
# row in the ledger including ones written by EARLIER invocations, possibly by
# an OLDER RUNNER — and a row written before the field-5 column existed has no
# field 5, so the aggregation maps it to `?` and pushes it into
# `nocount_paths`. A resumed sweep whose ledger held >=20 such rows therefore
# satisfied `nocount >= _n_pass_files`, printed "all N passing file(s) read as
# `?`", asserted that the reader had not run, and exited 1.
#
# REPRODUCED, not merely reasoned about — #1041 filed this as code-reading-only
# because it needs a pre-#693 ledger to construct. Twenty-two fixtures plus a
# hand-written 3-field ledger, resumed so nothing re-ran:
#
#   === ledger …: 22 PASS, 0 SKIP, 0 FAIL, 0 TIMEOUT, 0 not yet run … ===
#   ::error::ASSERTION ACCOUNTING IS BROKEN — all 22 passing file(s) read as `?`.
#   rc=1
#
# Nothing was wrong. The reader ran perfectly; it simply had nothing to read,
# because the ledger predated the column. A guard that reds a green, fully
# accounted sweep on the strength of the ledger's AGE is worse than no guard.
#
# So derive BOTH inputs from the run dir: one `.assertions` line each for the
# files this invocation could read, one `.nocount` path each for the rest. A
# fully-resumed invocation measures nothing, both are 0, the floor is not met,
# and the guard correctly stays silent instead of inventing a verdict about
# work it did not do.
_guard_assert_lines=$(find "$run_dir" -name '*.assertions' -exec cat {} + 2>/dev/null | grep -c . ) || _guard_assert_lines=0
_guard_nocount=$(find "$run_dir" -name '*.nocount' -exec cat {} + 2>/dev/null | sort -u | grep -c . ) || _guard_nocount=0
[[ "$_guard_assert_lines" =~ ^[0-9]+$ ]] || _guard_assert_lines=0
[[ "$_guard_nocount" =~ ^[0-9]+$ ]] || _guard_nocount=0
_n_pass_files=$(( _guard_assert_lines + _guard_nocount ))
# FLOOR, and it is not arbitrary decoration. "Every suite declares a count" is
# true of THIS REPO'S suites — it is emphatically not true of the throwaway
# fixtures a test feeds this runner. test-run-tests-bounded.sh drives it with
# `ok-a.sh`-style scripts that print nothing at all, and an unfloored guard
# turned six of its assertions red: a guard against a false green that
# manufactures a false red. Caught locally, before this shipped, only because
# that suite was re-run after an unrelated timeout.
#
# The class this guards (a helper missing from the parallel children) manifests
# in EVERY run, so it is always visible at band scale; the floor costs nothing
# against it. 20 is comfortably above any fixture set in this repo and far below
# the full corpus.
#
# NO CORPUS CONSTANT HERE, ON PURPOSE (your-org/nexus-code#1041 item 4). This
# rationale used to say "far below the 248-suite band", and the header note
# below asserted a property "measured over all 248 selected suites". The corpus
# was 348 when #1041 was filed and is 366 at 7c4ddbb — a claim about a
# population that had grown ~48% since it was written. Refreshing the number
# would only restart the clock, which is the same mistake one commit later, so
# the number is REMOVED rather than updated. Re-derive it when you need it:
#
#   git ls-tree -r --name-only <ref> | grep -cE '(^|/)test-[^/]*\.sh$'
#
# (basename semantics deliberately — git's pathspec `*` crosses `/` and would
# count `test-integration/_harness.sh` and `stub-claude.sh`, which are a shared
# library and a shim rather than suites; your-org/nexus-code#1111.)
: "${NEXUS_ASSERT_ACCOUNTING_FLOOR:=20}"
if (( _n_pass_files >= NEXUS_ASSERT_ACCOUNTING_FLOOR \
      && _guard_nocount >= _n_pass_files )); then
    printf '::error::ASSERTION ACCOUNTING IS BROKEN — all %d passing file(s) THIS INVOCATION measured read as `?`.\n' \
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
    printf '=== %d passing file(s) declared ZERO assertions — a PASS that asserts nothing ===\n' \
        "${#zerocount_paths[@]}"
    for f in "${zerocount_paths[@]}"; do printf '    0 assertions: %s\n' "$f"; done
    # AND IT IS NOW RED (your-org/nexus-code#1145). Printing it was not enough:
    # `#568 A6` added the third state and fixed the RUNNER, and two suites never
    # adopted the CONVENTION the state depends on — so the hole stayed open for
    # months exactly where the header says it was closed, with the census
    # naming them on every run and the run staying green. A suite that CANNOT
    # RUN in this environment is a SKIP (`exit 77`); a PASS asserting nothing
    # claims a property it never tested, and there is no third thing it can
    # legitimately be.
    #
    # NO KNOB, deliberately. The correct response is one character in the
    # declining suite (`exit 0` -> `exit 77`), and a suppression variable would
    # be reached for first and left set.
    #
    # MEASURED BEFORE SHIPPING, on the band each claim covers, so this is not an
    # unmeasured red: at `ca6205c` + the two `#1145` fixes, the fast unit band
    # (376 selected, 352 PASS / 23 SKIP) reported ZERO zero-assertion passes and
    # zero unreadable footers, with a planted control confirming the census
    # names both shapes. The `RUN_INTEGRATION=1` band is NOT measured here, and
    # a red there would be a TRUE positive by construction — a passing suite
    # that asserted nothing — not a false alarm to be silenced.
    printf '::error::THIS RUN IS RED. A PASS that asserts nothing is not a pass — make each file above SKIP (exit 77) or give it a real assertion.\n'
    echo "    A suite that cannot run in this environment is a SKIP; a PASS claims a"
    echo "    property it never tested. There is no third thing it can be, and there is"
    echo "    no knob here on purpose — the fix is one character in the declining suite."
    echo "    'assertions: ?' below is NOT this on its own: an unreadable footer is"
    echo "    normalisation debt. It turns the run red only when the suite ALSO emitted"
    echo "    no per-assertion line at all (your-org/nexus-code#1185)."
    _vacuous_pass=1
fi
if (( ${#nocount_paths[@]} > 0 )); then
    # NOT a coverage finding: measured over the whole corpus, every suite
    # declares a count — in one of twelve spellings. These are the ones this
    # runner cannot read, so this list is a NORMALISATION checklist, and it is
    # the honest form of the answer: a number derived by guessing at spellings
    # offline was wrong three times in a row while this was being built.
    printf '    (footer spelling unread by the runner — normalisation debt, not missing coverage)\n'
    for f in "${nocount_paths[@]}"; do printf '    assertions ?: %s\n' "$f"; done
fi

# ── `?` IS NOT "FINE" WHEN NOTHING ELSE SPOKE EITHER (#1185) ────────────────
# `#1145`'s ratchet reds `zerocount` — the READABLE zero. The shape one step to
# its left stayed green: a suite that asserts nothing AND whose footer this
# runner cannot read prints `assertions ?` and passes. The escape from the red
# was to be LESS legible, not more, which is a hole shaped like the thing it
# ratchets.
#
# THE CONJUNCTION IS WHAT MAKES THIS SAFE TO TURN ON. `?` alone is dominated by
# normalisation debt, and reddening on it would red on a different defect and
# get the whole ratchet switched off — which is why `#1175` scoped to
# `zerocount` on purpose. A suite reaches this list only when BOTH channels
# came back empty: no footer this runner can read, and no per-assertion line of
# any kind. That is not "spelled its total unusually"; it is a green with
# nothing behind it in either channel.
#
# MEASURED BEFORE SHIPPING, on the band the claim covers, so this is not an
# unmeasured red — see the census printed by this same run.
# ── A SUCCESS BANNER OVER NOTHING IS A FALSE STATEMENT, AND IT IS RED (#1277) ──
# The strict subset of the census below: unreadable footer, no per-assertion
# line, AND the file printed `ALL TESTS PASSED`, AND it is a file of this repo.
#
# WHY THIS IS A RED WHERE ITS PARENT IS A CENSUS. The census is deferred because
# `?` is dominated by normalisation debt and a gate that cries wolf gets switched
# off — a real constraint, and it still holds for a file that printed NOTHING.
# It does not hold here. A file that printed `ALL TESTS PASSED` while asserting
# nothing is not spelled unusually and is not silent; it has stated a property it
# never tested. `#1277` measured what that costs: a mutation of
# `monitor/remote-enroll-session.sh` that unconditionally appends an attacker key
# scores `30 passed, 17 failed` with `ssh-keygen` present and `ALL TESTS PASSED`,
# rc 0, `assertions: ?` with it masked.
#
# WHY IT WAS INVISIBLE UNTIL NOW, stated because it is the part worth keeping:
# `#1145`'s ratchet keys on a DECLARED count and these declare none;
# `#1185`'s conjunction keys on a second signal, and that signal counted the
# suite's own `SKIP:` line as an assertion. Two gates built for this class, both
# blind to it, for two different reasons. The `SKIP`/`TODO` removal from
# `_rt_emitted_assertion_lines` is what makes this population visible at all —
# neither half works without the other.
#
# THE FIX IN THE DECLINING SUITE IS ONE CHARACTER: `exit 0` -> `exit 77`, and
# drop the banner. There is no knob here, on purpose.
if (( ${#falsepass_paths[@]} > 0 )); then
    printf '::error::THIS RUN IS RED. %d in-repo file(s) PASSED having asserted nothing the runner can see (your-org/nexus-code#1277, #1185).\n' \
        "${#falsepass_paths[@]}"
    for f in "${falsepass_paths[@]}"; do printf '    false pass: %s\n' "$f"; done
    echo "    Each file above declared no count the runner could read AND emitted no"
    echo "    per-assertion line, so NEITHER channel says what it verified — most often"
    echo "    a dependency gate that exits 0 instead of 77. Make it SKIP (exit 77), or"
    echo "    give it a real assertion, or emit a footer the runner can read."
    echo "    The banner is no longer part of this test (#1185): a file that printed"
    echo "    'ALL TESTS PASSED' made a FALSE statement and a silent one made NO"
    echo "    statement, but both hand the runner a green nobody can vouch for."
    echo "    A planted fixture outside this repo is exempt by construction and"
    echo "    cannot reach this list."
    _false_pass=1
fi
if (( ${#vacuous_paths[@]} > 0 )); then
    printf '=== %d passing file(s) declared NO readable count AND emitted NO assertion line (census, not a red — #1185) ===\n' \
        "${#vacuous_paths[@]}"
    for f in "${vacuous_paths[@]}"; do printf '    unverifiable pass: %s\n' "$f"; done
    echo "    ^ NOT the normalisation-debt list above: these also printed no PASS/ok/FAIL"
    echo "    line, so neither channel says what they verified. Give the file a real"
    echo "    assertion, make it SKIP (exit 77) if it cannot run here, or emit a footer"
    echo "    the runner can read."
    #
    # A CENSUS, NOT A RED — and the reason is a MEASUREMENT, not caution
    # (your-org/nexus-code#1185). `#1185` asks for `?` to become a refusal. Built
    # as one and run over the whole corpus, it reddens NOTHING real: all 390
    # suites declare a machine-readable count (`0 file(s) declared no
    # machine-readable count`, 15,327 assertions). Its only observed effect is on
    # PLANTED FIXTURES — a runner-under-test's minimal `echo …; exit 0` vehicle,
    # which is the standard idiom here for testing an UNRELATED runner property.
    #
    # And reddening those would contradict a DELIBERATE existing decision, not an
    # oversight: test-assertion-accounting.sh section 7 already reds an ALL-`?`
    # run (that means the READER did not run — a harness failure) while asserting
    # that "2 footerless fixtures (below the floor) stay GREEN — no false red".
    # That floor exists for the same reason `#1175` scoped its own gate to
    # `zerocount`: a gate that cries wolf gets switched off, taking the real
    # ratchet with it.
    #
    # So the half that was missing is OBSERVABILITY, and that is what this
    # provides: `assertions ?` used to cover both "spelled its total unusually"
    # and "said nothing at all", indistinguishably. Those are now separate lists.
    # Turning this list into a red is a decision for whoever owns the fixture
    # convention, and it should be taken with the corpus number above in hand.
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
elif (( ${#skipped_rows[@]} > 0 )); then
    # THE NON-LEDGER ARM, which had no roll-up at all (#1041 item 5). Reasons
    # included: by the time anyone reads the foot of a CI log the per-row reason
    # has scrolled past, and a bare path list is what made the blank reason
    # worth fixing one level up.
    echo
    echo "SKIPPED (declined to run — asserted nothing; NOT passes, #568 A6):"
    printf '%s\n' "${skipped_rows[@]}" | while IFS=$'\t' read -r _p _why; do
        printf '  %-58s %s\n' "$_p" "$_why"
    done
fi
# ENV-DECLINED roll-up. Mirrors the SKIPPED block above — ledger arm first,
# sidecar arm as the `elif` — because the same reader needs the same list on
# both paths, and #1041 item 5 is the record of what happens when only one arm
# has it: the `--jobs N` band printed per-row declines and no roll-up at all.
if (( ${#envskip_paths[@]} > 0 )); then
    echo
    echo "ENV-DECLINED (ran, asserted, then found this MACHINE unable — NOT passes, NOT regressions, #1283):"
    for f in "${envskip_paths[@]}"; do
        printf '  %s\n' "$f"
    done
elif (( ${#envskip_rows[@]} > 0 )); then
    echo
    echo "ENV-DECLINED (ran, asserted, then found this MACHINE unable — NOT passes, NOT regressions, #1283):"
    printf '%s\n' "${envskip_rows[@]}" | while IFS=$'\t' read -r _p _why; do
        printf '  %-58s %s\n' "$_p" "$_why"
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
if (( ${#ceiling_adj[@]} > 0 )); then
    # THE FLAP BAND (your-org/nexus-code#992). Everything here PASSED or FAILED
    # on its own terms; the point is that the verdict is not reproducible, and
    # nothing in the rows above said so.
    echo
    # THE CEILING IS PER ROW, NOT PER RUN, and this header must not name one.
    # Since ceiling-overrides.tsv exists a suite can run under a ceiling other
    # than the run default, so printing `$PER_TEST_TIMEOUT` here would label
    # every row with a number that does not apply to some of them — a caption
    # contradicting the data beneath it, which is worse than no caption. Each
    # row carries the ceiling it was actually judged against.
    printf 'CEILING-ADJACENT (completed, but used >=%s%% of ITS OWN per-test ceiling — a TIMEOUT here is LOAD, not a hang; #992):\n' \
        "${NEXUS_CEILING_ADJACENT_PCT:-80}"
    for f in "${ceiling_adj[@]}"; do
        IFS=$'\t' read -r _ca_path _ca_wall _ca_ceil _ca_pct <<<"$f"
        [[ "$_ca_pct" =~ ^[0-9]+$ ]] || continue
        printf '  %ss of %ss (%s%% used, %s%% margin): %s\n' \
            "$_ca_wall" "$_ca_ceil" "$_ca_pct" "$(( 100 - _ca_pct ))" "$_ca_path"
    done
    echo "  ^ raise --timeout for these, give the suite a measured row in"
    echo "    monitor/watcher/ceiling-overrides.tsv, or split them. A re-run that"
    echo "    comes back"
    echo "    green has not fixed anything — it has re-rolled the dice, and the"
    echo "    next TIMEOUT will be re-diagnosed from scratch as a hang."
    echo "    Threshold: NEXUS_CEILING_ADJACENT_PCT (default 80)."
    # SCOPE, stated because it is narrower than the rest of this footer: this
    # band is built from THIS INVOCATION's sidecars. Under --state --resume the
    # tally above covers the whole sweep from the ledger, and the ledger carries
    # no ceiling field, so a suite that ran in an earlier invocation is absent
    # here rather than silently reported as having had headroom.
    if [[ -n "$tally_file" ]]; then
        echo "    (this invocation only — the ledger carries no ceiling field)"
    fi
fi
if (( ${#failed_paths[@]} > 0 )); then
    echo
    echo "Failed tests (re-run with --failed-only):"
    for f in "${failed_paths[@]}"; do
        printf '  %s\n' "$f"
    done
fi

# --- the LOCAL known-red set, as DATA (your-org/nexus-code#1445) ------------
# A full local run on an operator's live board is not green on pristine dev,
# so "6 failed" is a count the reader must interpret — and will misinterpret
# in both directions. The set is a manifest the runner reads, and the failing
# set is PARTITIONED against it: known rows are listed with their class,
# issue and reason; anything else is UNEXPLAINED and blocks the local gate.
# The verdict (exit code) is UNCHANGED by this block — a row changes what is
# printed, never whether the run is red. DIFF THE SETS, NEVER THE COUNTS.
_klr_manifest="${NEXUS_KNOWN_LOCAL_RED:-$(dirname "${BASH_SOURCE[0]}")/known-local-red.tsv}"
if (( ${#failed_paths[@]} > 0 )) && [[ -r "$_klr_manifest" ]]; then
    _klr_known=(); _klr_unexplained=()
    for f in "${failed_paths[@]}"; do
        _klr_tag="$(basename "$(dirname "$f")")/$(basename "$f")"
        _klr_row=$(awk -F'\t' -v t="$_klr_tag" '$0 !~ /^[[:space:]]*(#|$)/ && $1 == t { print; exit }' "$_klr_manifest")
        if [[ -n "$_klr_row" ]]; then
            _klr_known+=("$_klr_row")
        else
            _klr_unexplained+=("$f")
        fi
    done
    echo
    if (( ${#_klr_known[@]} > 0 )); then
        printf 'KNOWN-LOCAL-RED (%d of %d failures are in %s — inherited, NOT evidence about your diff; each row names the issue that expires it):\n' \
            "${#_klr_known[@]}" "${#failed_paths[@]}" "${_klr_manifest#"$PWD"/}"
        for _klr_row in "${_klr_known[@]}"; do
            IFS=$'\t' read -r _klr_s _klr_c _klr_i _klr_r <<<"$_klr_row"
            printf '  %-52s %-10s %-7s %s\n' "$_klr_s" "$_klr_c" "$_klr_i" "$_klr_r"
        done
    fi
    if (( ${#_klr_unexplained[@]} > 0 )); then
        printf 'UNEXPLAINED (%d of %d failures are NOT in the known-local-red set — these block the push):\n' \
            "${#_klr_unexplained[@]}" "${#failed_paths[@]}"
        for f in "${_klr_unexplained[@]}"; do printf '  %s\n' "$f"; done
        printf 'LOCAL GATE: BLOCKED — failing set is NOT a subset of the known-local-red set (%d unexplained).\n' \
            "${#_klr_unexplained[@]}"
    else
        printf 'LOCAL GATE: failing set ⊆ known-local-red set (%d of %d) — CLEAR for the local gate. The run is still RED (exit 1):\n' \
            "${#_klr_known[@]}" "${#failed_paths[@]}"
        echo "  a row in the manifest changes what is printed, never the verdict, and CI never reads it."
    fi
elif (( ${#failed_paths[@]} > 0 )); then
    echo
    printf 'known-local-red manifest not readable at %s — every failure above is UNCLASSIFIED (your-org/nexus-code#1445).\n' "$_klr_manifest"
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

# Exit contract: 4 = the sweep was INTERRUPTED BY A SIGNAL, so it is not a
# verdict either way (#1083); 3 = incomplete (budget stop and/or unrecorded
# remainder under a ledger) — resume with the same command; 1 = complete but
# red, which since #877 includes "the accounting and the verdict disagreed" —
# a failed test and an unmeasured one are both reasons not to merge;
# 0 = complete and green.
#
# WHY A FOURTH CODE IS RIGHT HERE AND WAS WRONG AT #877, because the note at
# the foot of this file argues the opposite and both are correct. #877 refused
# a new code for an ACCOUNTING BREAKDOWN and reused 1, on the ground that a
# caller which had not been taught the new code would classify it wrongly and
# "the cost of being wrong here is a green that should have been red".
#
# The direction of the error is what differs. That case risked a FALSE GREEN,
# so an unrecognised code was dangerous. This case is the inverse: the failure
# mode is a run that reads as A PRODUCT VERDICT when it is an ENVIRONMENT
# event. Every untaught caller treats a non-zero status as red — which is the
# SAFE reading here — so the new code can only ever add information, never
# remove a refusal. Checked against the callers rather than assumed:
#
#   tests.yml unit bands       bare invocation under `set -e` -> any non-zero is red
#   tests-slow-integration.yml `case "$rc" in 0|1) ;; 3) …; *) …` — 4 lands in the
#                              `*)` arm, which prints "failed as a HARNESS (rc=4),
#                              not as a test result — there is no trustworthy ledger
#                              to adjudicate" and exits 1. That is EXACTLY the right
#                              classification, with no edit to the workflow.
#
# 3 was rejected for the same reason #877 rejected it: 3 is a live instruction
# ("budget exhausted, the ledger is PARTIAL, resume"), and resuming does not
# repair a machine that is killing the batch.
#
# PRECEDENCE: 4 outranks both 1 and 3. A signalled sweep also shows up as an
# accounting shortfall (the interrupted test recorded nothing) and, under a
# ledger, as `n_unrecorded > 0` — those are the SYMPTOM. The signal is the
# CAUSE, and naming the cause is what tells the reader to re-run rather than
# to go looking for a broken mktemp or a budget to raise. It outranks 1 for
# the harder reason too: when a sweep is cut short, the FAIL list is a LOWER
# BOUND, so "red" understates what is unknown. Non-zero either way, so no
# caller loses a refusal by this choice.
# BROKEN BEATS INCOMPLETE (your-org/nexus-code#877). The `_accounting_broken`
# clause is a precedence rule, not an extra condition. Under a `--state` ledger
# a lost verdict ALSO shows up as `n_unrecorded > 0`, so without this the run
# would take the arm below and exit 3 — whose contract is "budget stopped this
# invocation, resume with the same command". Resuming does not repair a refused
# `mktemp` or a destroyed run dir, so that would hand the caller a confident and
# actionable instruction that cannot work, and `tests-slow-integration.yml`
# would report it as an exhausted serial budget. An incomplete run is resumable;
# a run whose accounting broke is not, and must read as red.
# SIGNALLED BEATS EVERYTHING (your-org/nexus-code#1083). Placed above the
# incomplete/red arms deliberately — see the PRECEDENCE paragraph in the exit
# contract above. The banner naming each killed test has already printed.
if (( n_signalled > 0 )); then
    echo
    printf 'NOT A VERDICT: %d test process(es) were killed by a signal; this run measured a SUBSET.\n' \
        "$n_signalled"
    echo "The pass count and the failure list are both LOWER BOUNDS. Re-run before reading"
    echo "either as evidence. Exit 4 (your-org/nexus-code#1083)."
    exit 4
fi
if { (( budget_stopped )) || { [[ -n "$tally_file" ]] && (( n_unrecorded > 0 )); }; } \
   && (( ${_accounting_broken:-0} == 0 )); then
    echo
    # THE HARDCODED ZERO (found sweeping the #1031/#997 class; the sharpest
    # non-filed member of it). This argument used to be
    # `[[ -n "$tally_file" ]] && printf '%d' "$n_unrecorded" || printf '%d' 0`
    # — a literal `0` whenever there was no ledger. `--max-seconds` does NOT
    # require `--state` (only `--resume` does), so that is a supported
    # combination, and on it the line whose ENTIRE JOB is reporting
    # incompleteness reported none. Measured on `dev` at 5de291f, four
    # fixtures, `--max-seconds 1`, ONE executed:
    #
    #     === suite total: 1.04s across 4 tests; 0 failed (0 of those TIMEOUT) ===
    #     INCOMPLETE: budget/ceiling stopped this invocation with 0 test(s) unaccounted.
    #
    # Three unaccounted, reported as zero, at rc 3. The label and the
    # computation were not merely out of step — the computation was a constant.
    #
    # Without a ledger the shortfall IS derivable, from the two counts the #877
    # reconcile already computes: dispatched minus accounted. That is a
    # narrower claim than `n_unrecorded` (it cannot see a test never dispatched
    # because the sweep stopped before selecting it — there is no such case
    # here, since selection precedes dispatch) and it is measured rather than
    # assumed. `n_accounted`/`n_dispatched` are set only on the non-ledger arm,
    # which is exactly the arm this fallback serves.
    printf 'INCOMPLETE: budget/ceiling stopped this invocation with %d test(s) unaccounted.\n' \
        "$( if [[ -n "$tally_file" ]]; then printf '%d' "$n_unrecorded"
            else printf '%d' "$(( ${n_dispatched:-0} - ${n_accounted:-0} ))"; fi )"
    echo "Resume with the SAME command (add --state <file> --resume if you had none) until exit != 3."
    exit 3
fi
if [[ -n "$tally_file" ]]; then
    (( n_fail == 0 && n_timeout == 0 && ${_assert_harness_broken:-0} == 0 \
       && ${_accounting_broken:-0} == 0 && ${_vacuous_pass:-0} == 0 \
       && ${_false_pass:-0} == 0 )) && exit 0
    exit 1
fi
(( ${#failed_paths[@]} > 0 )) && exit 1
(( ${_assert_harness_broken:-0} > 0 )) && exit 1
# A PASS THAT ASSERTS NOTHING IS RED (your-org/nexus-code#1145), and 1 for the
# same reason the accounting breakdown is: 1 already means "do not merge" to
# every caller, and the cost of being wrong here is a green that should have
# been red.
(( ${_vacuous_pass:-0} > 0 )) && exit 1
(( ${_false_pass:-0} > 0 )) && exit 1
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
