#!/usr/bin/env bash
# Opt-in test helpers: shared assertion primitives + PASS/FAIL
# counters + summary footer + fake-nexus fixture builder.
#
# Existing tests under monitor/watcher/test-*.sh use inline
# assertions for self-containment. New tests MAY source this file
# instead of redefining assert_*:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
#
#   assert_eq         "label" "$got" "$want"
#   assert_rc         "label" "$got_rc" "$want_rc"
#   assert_contains   "label" "$haystack" "$needle"
#   assert_not_contains "label" "$haystack" "$needle"
#   assert_empty      "label" "$value"
#   assert_file_exists "label" "$path"
#   assert_no_file     "label" "$path"
#
#   # Fixture builder (issue #37) — populates a fake nexus tree
#   # with `monitor/ng`, a config/load.sh stub, and a mint-token.sh
#   # stub. Sets the global $FAKE_NEXUS to the populated dir.
#   setup_fake_nexus "$WORK/nexus" [--token <str>] [--repo <owner/name>] \
#                                  [--user <login>] [--allow-default]
#
#   # GH-stub fixture builder (issue #38) — generates a PATH-shadow
#   # `gh` script that captures every argv to a file and dispatches
#   # `gh api` calls to a caller-supplied case body keyed on the
#   # extracted endpoint:
#   make_gh_stub <stub-path> <capture-path> [--with-body-capture <path>] <<'CASES'
#       */issues/*/comments)  printf '{"html_url":"https://x/c"}' ;;
#       *)                    printf '{}' ;;
#   CASES
#
#   # Hermetic-env wrapper (issue #41) — unsets the five operator-side
#   # vars that can redirect production code into the real nexus
#   # tree, then runs the command:
#   run_hermetic VAR=val ... -- <cmd> [args...]
#
#   # ... at end of file:
#   th_summary_and_exit
#
# Counters are exported as PASS / FAIL globals. test_helpers does
# not call `set -uo pipefail` — sourcing test is responsible for
# its own shell options.

# bash 5.2 enables `patsub_replacement` by default, which makes `&`
# in the replacement string of `${var//pat/rep}` expand to the
# matched text. `make_gh_stub` feeds case bodies (which legitimately
# contain `&` in shapes like `&&` inside `[[ ]]` guards and `>&2`)
# through such a substitution to build the generated stub. With the
# option on, the resulting stub becomes syntactically broken — bash
# parses `>&2` as `>@@CASES@@2` and `&&` as `@@CASES@@@@CASES@@`,
# the stub fails to start, every `gh` call returns nonzero, and the
# ng-tests fail in mysterious "got 1 want 0" ways only on bash 5.2+.
# Force it off; bash 4.x doesn't know the option and silently no-ops.
#
# ambient-shell-option-scope: allow-unconditional-unset  this neutralises a
# bash 5.2 INTERPRETER DEFAULT for every suite that sources this file — it is
# not restoring an option some caller turned on, so there is no caller state to
# hand back wrongly. Different supplier from the leak class
# your-org/nexus-code#721 gates (interpreter, not library), which is exactly
# why it is exempted by a reason rather than by its filename.
shopt -u patsub_replacement 2>/dev/null || true

# Disarm Lmod's command_not_found_handle in the sourcing test shell
# (your-org/nexus-code#457/#479/#480). On the sandbox hosts BASH_ENV
# reaches Lmod's init, which arms a handler that shells out to
# `command_not_found.py` via PATH; bash forks a child before invoking
# it, so a test shell that narrows PATH past the dir holding that
# script turns any missing command into an unbounded fork chain (the
# 2026-07-08 pid_max exhaustion). Tests never rely on the handler —
# a missing command should be a plain rc=127. This guards the SOURCING
# shell only; bash children each re-arm from BASH_ENV, so PATHs handed
# to children go through th_hermetic_path below instead.
unset -f command_not_found_handle 2>/dev/null || true

# Public-template disable switch: the public-mirror tree ships a
# monitor/_public-guard.sh whose call sites make every bring-up entry
# point (bootstrap-recover.sh, bootstrap-install.sh, watcher/entry.sh)
# refuse with "nexus is disabled" unless NEXUS_PUBLIC_ENABLED=1. The
# unit suite executes those entry points against fixture-local state
# (stubbed labsh, tmpdir registries) — the sanctioned unlock, not a
# bypass of the guard's purpose (blocking ACCIDENTAL autonomous
# bring-up on a fork). Without it the mirror's CI reds on any
# helper-sourcing test that runs a guarded script for real (the
# bootstrap-recover stanza of test-jupyter-service.sh). On a tree
# that ships no guard (this source repo) the export is inert. NOTE: the
# guard's REFUSAL path — that it still fires with this variable unset — is
# not asserted by any CI (your-org/nexus-code#520); it cannot be, from
# source, since the guard ships only in the mirror. That assertion belongs
# in a mirror-side test, landed with the mirror sync.
export NEXUS_PUBLIC_ENABLED=1

: "${PASS:=0}"
: "${FAIL:=0}"
: "${SKIP:=0}"

# ── THE DURABLE ASSERTION LEDGER (your-org/nexus-code#805) ──────────────────
#
# THE DEFECT. `th_summary_and_exit` printed from the in-memory counters and
# exited 0 whenever `FAIL == 0`. It never asked whether anything had been
# COUNTED AT ALL, so a suite that asserted nothing announced a clean sweep:
#
#     $ bash -c '. _test_helpers.sh; th_summary_and_exit'
#     === summary: 0 passed, 0 failed ===
#     ALL TESTS PASSED                                   # rc 0
#
# Indistinguishable — to a reader, to the runner, and to `grep -c 'ALL TESTS
# PASSED'` — from a suite that ran 105 assertions and passed them all.
#
# THREE WAYS TO GET THERE, and the reason this is a ledger rather than a
# `(( PASS + FAIL + SKIP == 0 ))` guard. Only the first is the count-is-zero
# case; a guard on the counters alone cannot see the other two, because in both
# of them the counters are LYING rather than empty:
#
#   1. NOTHING RAN. An early `th_summary_and_exit` on a precondition (the
#      `test-fs-guard.sh` running-as-root path, pre-`#795`) reaches the summary
#      with all three counters at zero.
#
#   2. THE COUNT WAS LOST IN A SUBSHELL. `assert_*` mutates globals, so every
#      assertion inside `( … )`, `$( … )`, a pipeline stage or a `<( … )` is
#      counted into a child's copy of `PASS`/`FAIL` and discarded on exit. A
#      FAILING assertion in a subshell therefore leaves `FAIL == 0` and the
#      suite still exits 0 — `#783`'s uncounted-abort, arriving by a different
#      road. This is the variant a counter guard is blind to by construction.
#
#   3. THE HELPER WAS MISSING. `#609`: a call to an undefined `assert_*` is
#      rc 127 and nothing counts it. Already answered by the sentinel below —
#      and that sentinel is the PRECEDENT for this ledger, which generalises
#      the same file-survives-the-subshell trick from one precondition to
#      every counted outcome.
#
# THE MECHANISM. Every counter mutation also appends one byte to a file keyed
# on `$$`. A subshell inherits `$$` from its parent in bash, so a child's
# append lands in the SAME ledger the parent reads at summary time — which is
# exactly why the `#609` sentinel works, applied here to all three outcomes.
# The ledger is therefore a lower bound on what really ran, and the in-memory
# counters are a lower bound on the ledger. Where they disagree, the ledger is
# right and the counters are the lie.
#
# WHY `$$` AND NOT A MKTEMP. A separate `bash` child that re-sources this file
# gets its own `$$` and its own ledger, so a fixture script that itself uses
# these helpers cannot contaminate the parent's count. That property is load
# bearing; several suites run helper-sourcing fixtures.
_TH_LEDGER="${TMPDIR:-/tmp}/.th-ledger.$$"
# Truncate ONCE per test process, never in a subshell. `_TH_LEDGER_INIT` is a
# plain shell variable, so a subshell that re-sources this file inherits it set
# and leaves the parent's ledger alone; a genuinely separate process does not
# inherit it and so clears any ledger left behind by a recycled pid.
if [[ -z "${_TH_LEDGER_INIT:-}" ]]; then
    _TH_LEDGER_INIT=1
    : > "$_TH_LEDGER" 2>/dev/null || true
fi

# The three counted outcomes. These exist so the increment appears in exactly
# one place per outcome: twenty raw `PASS=$(( PASS + 1 ))` sites used to be
# spread across the assert_* bodies, and a ledger that twenty call sites have
# to remember to update is a ledger that will be wrong. `test-assertion-ledger.sh`
# asserts on THIS FILE'S SOURCE that no raw increment has come back.
_th_note() { printf '%s\n' "$1" >>"$_TH_LEDGER" 2>/dev/null || true; }
_th_pass() { PASS=$(( ${PASS:-0} + 1 )); _th_note P; }
_th_fail() { FAIL=$(( ${FAIL:-0} + 1 )); _th_note F; }
_th_skip() { SKIP=$(( ${SKIP:-0} + 1 )); _th_note S; }
# A failure raised by the MISSING-HELPER handler (`#609`) gets its own letter.
# It counts identically toward FAIL; the separate letter exists purely so the
# summary can ATTRIBUTE the loss. bash forks before invoking
# `command_not_found_handle` (see the Lmod note at the top of this file), so
# that increment is ALWAYS lost to the parent — without the distinct letter the
# summary would diagnose every missing helper as a generic subshell loss and
# print two competing explanations for one event.
_th_fail_missing() { FAIL=$(( ${FAIL:-0} + 1 )); _th_note M; }

# th_skip <label> <reason>
#
# Record a case that could NOT RUN. Loud on stderr, counted separately, and
# never a pass. `#568` A6 catalogued "a green count that is not a coverage
# claim" as its own defect class, and the runner answered it at FILE
# granularity (exit 77 ⇒ SKIP). This is the same contract one level down, for
# a single case inside an otherwise-running file: a check whose PRECONDITION
# is absent on this host must say so in the footer, so a reader of `ALL TESTS
# PASSED` knows what the run did not cover.
#
# The <reason> is mandatory in spirit and must name the missing precondition
# concretely (which path, which tool, which measured number) — a skip nobody
# can act on is only marginally better than a silent pass.
th_skip() {
    local label="$1" reason="${2:-<no reason given>}"
    printf '  SKIP: %s — %s\n' "$label" "$reason" >&2
    _th_skip
}

# ABORT A SCENARIO WITH A COUNTED FAILURE (your-org/nexus-code#783).
#
# THE DEFECT THIS EXISTS TO MAKE UNSPELLABLE. Five integration scenarios (as
# filed; `#789`'s spawn-shape refactor has since absorbed one of the seven
# sites into a correctly-counted `FAIL=…; return 1`, so six are converted here)
# aborted on a spawn precondition like this:
#
#     [[ "$win" =~ ^[0-9]+$ ]] || {
#         echo "  FAIL: spawn returned non-numeric window index: $win" >&2
#         th_summary_and_exit
#     }
#
# The `FAIL` is ECHOED, never COUNTED. `th_summary_and_exit` prints from the
# counters, `FAIL` is still 0, so a scenario that aborted half-way emitted
# `=== summary: 4 passed, 0 failed ===` / `ALL TESTS PASSED` and exited 0.
#
# Not hypothetical: `test-graceful-exit-relaunch.sh` phase B was entirely dead
# AND GREEN for as long as the harness lacked `monitor/_claude-bin.sh` (#764).
# The launcher died at its source line, the window never materialised,
# `list-windows` returned empty, and the uncounted abort announced a pass over
# six assertions that never ran.
#
# THE CONTRACT. An abort is a FAILURE, not a skip: the scenario intended to
# assert something and could not, and the reason is a broken precondition
# rather than an absent one. `th_skip` is for "this host cannot run the case";
# `th_abort` is for "the case should have run and the setup broke". Conflating
# them is how a red becomes a footnote.
#
# WHY THIS SHAPE. The bare-echo form is not merely discouraged — pairing it
# with `uncounted-abort-lint.sh` makes it a CI failure, so the wrong spelling
# cannot return quietly the way it arrived. The lint deliberately also accepts
# a direct `exit 1` (the `test-realmodel-*.sh` form), which never reaches the
# summary at all; see that file's axis for why both are sound and why only the
# summary-reaching one is the defect.
th_abort() {
    local reason="${1:-<no reason given>}"
    printf '  FAIL: ABORTED — %s\n' "$reason" >&2
    printf '        The scenario could not continue; assertions after this point did NOT run.\n' >&2
    _th_fail
    th_summary_and_exit
}

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"
        _th_pass
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        _th_fail
    fi
}

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"
        _th_pass
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        _th_fail
    fi
}

assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        _th_fail
    else
        printf '  PASS: %s\n' "$label"
        _th_pass
    fi
}

assert_empty() {
    local label="$1" got="$2"
    if [[ -z "$got" ]]; then
        printf '  PASS: %s\n' "$label"
        _th_pass
    else
        printf '  FAIL: %s — expected empty, got %q\n' "$label" "$got" >&2
        _th_fail
    fi
}

assert_file_exists() {
    local label="$1" path="$2"
    if [[ -f "$path" ]]; then
        printf '  PASS: %s\n' "$label"
        _th_pass
    else
        printf '  FAIL: %s — missing file: %s\n' "$label" "$path" >&2
        _th_fail
    fi
}

assert_no_file() {
    local label="$1" path="$2"
    if [[ ! -e "$path" ]]; then
        printf '  PASS: %s\n' "$label"
        _th_pass
    else
        printf '  FAIL: %s — file unexpectedly present: %s\n' "$label" "$path" >&2
        _th_fail
    fi
}

# --- fork-bomb precondition guard (your-org/nexus-code#479 / #457) -----
#
# Lmod's init (/app/lmod/lmod/init/bash, reached via BASH_ENV on the
# sandbox hosts) arms a `command_not_found_handle` that runs
# `command_not_found.py "$1"` — resolved via PATH, and the ONLY copy
# lives in /app/bin. Bash forks a child before invoking the handler,
# so when command_not_found.py is ITSELF unresolvable the handler
# re-fires inside the forked child, which forks again: an unbounded
# parent→child chain, each level blocked in wait(), that exhausted the
# node's pid_max on 2026-07-08 (#457). It is a conjunction — the armed
# handler is harmless while command_not_found.py resolves; a test that
# composes a synthetic PATH from absolute dirs supplies the missing
# half. Every PATH handed to a spawned child must therefore go through
# this helper.
#
# th_hermetic_path <base-path> <scratch-dir>
#
# Echo <base-path>, augmented so command_not_found.py stays resolvable:
# if it resolves on the AMBIENT PATH but not on <base-path>, append a
# private dir under <scratch-dir> holding ONLY a symlink to it. The
# fork-recursion primitive is defused without leaking any other host
# tool into the hermetic PATH. Off-sandbox (CI: no Lmod, no
# command_not_found.py) the base path is returned unchanged.
th_hermetic_path() {
    local base="$1" scratch="$2" cnf dir
    cnf=$(command -v command_not_found.py 2>/dev/null) \
        || { printf '%s' "$base"; return 0; }
    if PATH="$base" command -v command_not_found.py >/dev/null 2>&1; then
        printf '%s' "$base"; return 0
    fi
    dir="$scratch/th-cnf-bin"
    mkdir -p "$dir"
    ln -sf "$cnf" "$dir/command_not_found.py"
    printf '%s:%s' "$base" "$dir"
}

# th_assert_path_resolves_cnf <label> <path-string>
#
# Regression assertion for the same class: on hosts where
# command_not_found.py resolves ambiently, the given PATH must keep it
# resolvable (fails on a bare absolute-dir composition, passes once the
# construction goes through th_hermetic_path). Vacuously passes
# off-sandbox, where the mechanism cannot arm at all.
th_assert_path_resolves_cnf() {
    local label="$1" p="$2"
    if ! command -v command_not_found.py >/dev/null 2>&1; then
        printf '  PASS: %s (vacuous: no command_not_found.py on this host)\n' "$label"
        _th_pass; return 0
    fi
    if PATH="$p" command -v command_not_found.py >/dev/null 2>&1; then
        printf '  PASS: %s\n' "$label"
        _th_pass
    else
        printf '  FAIL: %s — command_not_found.py unresolvable on: %s\n' "$label" "$p" >&2
        _th_fail
    fi
}

# --- identity-verified kills (PID-recycling guard) ---------------------
#
# pid_max on the lab boxes is small (36864 observed) and a parallel
# suite run forks hundreds of processes per second, so the PID space
# wraps in well under a minute. A cleanup that kills a PID recorded
# earlier (pidfile, $!) whose process has since exited will, after a
# wrap, deliver the signal to whatever innocent process now owns the
# number — observed in the R3-tail stress campaign as a sibling
# test's subprocess dying silently (SIGKILL leaves no stderr; the
# victim assertion just reads as false). Both helpers therefore
# verify the CURRENT owner's identity via /proc before signalling,
# and refuse (rc 1, no kill) when identity can't be confirmed —
# leaking a short-lived helper is recoverable, killing a stranger's
# process is not. The check-then-kill window shrinks the race from
# minutes to microseconds; it cannot close it entirely.

# th_kill_fixture_pid <pid> <fixture-root> [<sig>] [--group]
#
# Signal <pid> only if its /proc cmdline or cwd still points into
# <fixture-root> (every per-test fixture dir is unique, so a recycled
# PID can't match). --group additionally signals the process group
# <pid> leads (for setsid'd fixture supervisors).
th_kill_fixture_pid() {
    local pid="$1" root="$2" sig="${3:-TERM}" group="${4:-}"
    [[ "$pid" =~ ^[0-9]+$ && -n "$root" ]] || return 1
    local cmdline cwd
    # `2>/dev/null` precedes the input redirect deliberately — see
    # th_reap_fixture_root. With it trailing, a pid that has already exited
    # prints a shell-level "No such file or directory" into the suite's
    # output, which is how a diagnostic ends up being counted as data.
    cmdline=$(2>/dev/null tr '\0' ' ' < "/proc/$pid/cmdline") || cmdline=""
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=""
    [[ "$cmdline" == *"$root"* || "$cwd" == "$root"* ]] || return 1
    [[ "$group" == "--group" ]] && kill "-$sig" -- "-$pid" 2>/dev/null
    kill "-$sig" "$pid" 2>/dev/null
}

# th_kill_own_child <pid> [<sig>]
#
# Signal <pid> only while it is still a child of THIS shell (its
# /proc ppid equals $$). Once the child has been reaped its PID is
# recyclable and the new owner's ppid is somebody else, so the guard
# refuses. Zombies keep their ppid, so an exited-but-unreaped child
# is still (harmlessly) signalable.
th_kill_own_child() {
    local pid="$1" sig="${2:-TERM}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    local stat rest ppid
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    rest="${stat##*) }"            # strip "pid (comm) " — comm may hold ')'
    read -r _state ppid _ <<<"$rest"
    [[ "$ppid" == "$$" ]] || return 1
    kill "-$sig" "$pid" 2>/dev/null
}

# th_reap_fixture_root <fixture-root> [<sig>] [<rounds>]
#
# Sweep /proc for every process whose cwd or argv places it inside
# <fixture-root>, signal them, and repeat to a FIXED POINT. Prints the
# number of processes signalled. rc 0 = a round completed with nothing
# left to signal; rc 1 = the round budget ran out with survivors.
#
# WHY THIS EXISTS, and why `th_kill_own_child` could not do it
# (your-org/nexus-code#860). `th_kill_own_child` requires `ppid == $$`,
# and it is RIGHT to: once a child is reaped its pid is recyclable and
# ppid is the only thing still proving ownership. But a fixture whose
# spawning subshell has already exited is REPARENTED TO INIT before
# cleanup ever runs, so every process that actually needs reaping has
# `ppid=1` and the guard refuses. Measured on `a74805b`: three
# supervisors leaked per run of test-svc-orphan-reconcile.sh while the
# suite printed ALL TESTS PASSED. A reap that no-ops is indistinguishable
# from a reap that worked if you only look at its return code.
#
# So ownership is established from a property REPARENTING CANNOT DESTROY:
# the process's own working directory, read from its own /proc entry, and
# required to sit under a fixture root that is unique per case (mktemp).
# `readlink` reports a removed directory as `<path> (deleted)`, and that
# is kept as a MATCH rather than discarded — a process whose cwd no longer
# exists outlived the fixture that made it, which is the signature we are
# hunting, not a disqualification.
#
# NOTHING HERE MATCHES BY NAME. The scan walks /proc directly, so there is
# no pattern for a scanner's own argv to collide with, and no basename to
# be worn by a class: `serve-supervised.sh` backs four live production
# rows on this host, and a read-only `pgrep` on it once matched all four
# (`#608`). The fixture root is the whole predicate.
#
# FIXED POINT, not a single pass. The code under test relaunches
# supervisors, so a process can appear between the scan and the signal;
# one pass looked clean exactly once during #860's diagnosis and was not
# a fix. The loop is bounded and reports failure rather than claiming a
# clean sweep it did not achieve.
#
# Composition note: `monitor/proc-kill-authorized` (your-org/nexus-code#851)
# answers the same question by SESSION for production callers. It is not
# used here because it filters a list rather than producing one, and a
# fixture must ENUMERATE — but the two witnesses are independent, and a
# caller wanting both can pipe this function's output through it.
# TWO FORKS PER ROUND, NOT TWO PER PROCESS. The obvious shape — loop over
# /proc and `readlink` + `tr` each entry — costs a fork per pid per witness.
# Measured on this host: 512 pids, ~1024 forks, 10 s for ONE pass. At eleven
# cleanup sites that is ~110 s added to a suite that ran in ~60, which is how
# a safety fix gets reverted for being slow. Both witnesses are therefore
# collected in a single pass each: `ls -l` over the cwd symlinks, and one
# `grep -l` over the cmdline files. Measured at 0 s for the same 512 pids.
_th_reap_scan() {   # _th_reap_scan <root> -> owned pids, one per line
    local root="$1" line pid tgt
    while IFS= read -r line; do
        [[ "$line" =~ /proc/([0-9]+)/cwd\ -\>\ (.*)$ ]] || continue
        pid="${BASH_REMATCH[1]}"
        tgt="${BASH_REMATCH[2]}"
        # A removed directory is reported as `<path> (deleted)`. That is KEPT
        # as a match: a process whose cwd no longer exists outlived the
        # fixture that made it, which is the signature, not a disqualifier.
        tgt="${tgt% (deleted)}"
        [[ "$tgt" == "$root" || "$tgt" == "$root"/* ]] || continue
        printf '%s\n' "$pid"
    done < <(ls -l /proc/[0-9]*/cwd 2>/dev/null)
}
#
# CWD IS THE ONLY WITNESS, AND THAT IS THE POINT. An earlier draft added a
# second pass — `grep -l -F "$root" /proc/[0-9]*/cmdline` — to catch a
# supervisor that had chdir'd away from the workdir it was launched in. It
# reproduced THIS ISSUE'S OWN DEFECT inside the fix for it: `grep`'s argv
# carries `$root`, `/proc/<grep's pid>/cmdline` is one of the files it reads,
# and so the scan matched its own scanner. Measured on an EMPTY root, where the
# correct answer is unambiguously zero:
#
#     grep -F "$root" /proc/[0-9]*/cmdline          -> 100 hits / 100 trials
#     printf '%s\n' "$root" | grep -F -f -  …       ->   0 hits / 100 trials
#
# In CI that transient pid was signalled and kept the sweep from ever reaching
# a fixed point, reddening three assertions on a run where every fixture
# process was in fact gone.
#
# The stdin form (second line) fixes the self-match and was measured clean —
# but it is still the wrong witness, because a SIBLING that merely mentions the
# root in its argv is not a process living in the fixture. This suite's own
# mutation helpers (`bash -c … "$R5"`) are exactly that. A process's working
# directory is a property OF THE PROCESS; an argv substring is a property of a
# string, and the observer is holding one too. Every fixture supervisor here is
# launched with `cd <workdir>`, so cwd answers the question completely.
#
# NOTE FOR ANYONE RE-TESTING THIS INTERACTIVELY: the operator's `grep` is a
# zsh FUNCTION wrapping ugrep, and under it the self-match does NOT reproduce —
# a probe run at an interactive prompt reports 0 hits and looks like a
# disproof. Run it under `bash -c`. That false negative cost a round trip here.

# THE VERDICT IS A SCAN, NOT A KILL COUNT. An earlier draft returned 0 only
# when a round signalled nothing, and returned 1 when the budget ran out having
# signalled something. That conflates "I delivered a signal" with "there is
# still work to do", and the two come apart under load: `kill` returns success
# for a process that is already dying but has not yet left /proc, so a
# successful reap on a contended runner reported FAILURE. Measured in CI on the
# `jobs 4` leg at 64% PSI stall, where two assertions expecting a clean sweep
# got rc 1 while the processes were in fact gone.
#
# So the loop signals, and then asks the only question that matters — is
# anything owned still there? A caller acting on the answer cares about the
# world, not about how many signals were sent.
th_reap_fixture_root() {
    local root="$1" sig="${2:-KILL}" rounds="${3:-4}"
    [[ -n "$root" && "$root" == /* && "$root" != "/" ]] || return 1
    local total=0 r pid found seen
    for (( r = 0; r < rounds; r++ )); do
        found=0; seen=" "
        while read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            (( pid == $$ )) && continue
            [[ "$seen" == *" $pid "* ]] && continue    # the two witnesses overlap
            seen+="$pid "
            found=1
            kill "-$sig" "$pid" 2>/dev/null && total=$(( total + 1 ))
        done < <(_th_reap_scan "$root")
        (( found == 0 )) && { printf '%s' "$total"; return 0; }
        sleep 0.3
    done
    # Budget spent. One final scan decides the verdict — signalling nothing, so
    # a process that merely took a while to die is not counted against us.
    #
    # Drained in full rather than through `head -1`: an early-closing reader
    # gives the producer EPIPE, and this repo tracks every such site because
    # under `pipefail` a consumed pipeline status can invert the verdict
    # (`#622`). The output here is a handful of pids, so there is nothing to
    # save by stopping early and a hazard population to stay out of.
    local remaining
    remaining=$(_th_reap_scan "$root")
    if [[ -z "$remaining" ]]; then
        printf '%s' "$total"; return 0
    fi
    printf '%s' "$total"
    return 1
}

# th_reap_fixture_survivors <fixture-root>
#
# Diagnostic companion: what is STILL owned by <fixture-root>, with each
# survivor's cwd, so a failing sweep assertion can say which processes it could
# not reap instead of only that it could not.
th_reap_fixture_survivors() {
    local root="$1" pid cwd
    while read -r pid; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd='<unreadable>'
        printf 'pid %s cwd=%s; ' "$pid" "$cwd"
    done < <(_th_reap_scan "$root" | sort -u)
}

# ---------------------------------------------------------------------------
# Hermetic tmux fixtures (your-org/nexus-code#555)
# ---------------------------------------------------------------------------
#
# A test that drives a REAL tmux server (`tmux -L <sock>`) is testing the
# watcher's tmux usage — NOT the operator's dotfiles. Left unpinned, tmux
# builds every fixture pane from `default-shell`, i.e. the invoking user's
# login shell, and runs it as a LOGIN shell: on the sandbox hosts that means
# each pane drags in ~/.zshenv → Lmod (lua) → conda → linuxbrew before it
# executes anything. Two failure modes follow, both observed on `dev` at
# 79f4cbb:
#
#   1. SLOW. Measured 6 s from `new-session` to the pane's first byte under
#      load average 44/36 cores (0.2 s with /bin/sh). Any fixture that waits
#      a fixed ~1 s for pane readiness fails outright — the pane has not run
#      a single instruction yet (test-paste-bracketed.sh).
#   2. FATAL. tmux 2.6 SEGFAULTS (`segfault at 6a1`, 541 occurrences in this
#      host's dmesg) while servicing a login-zsh pane; the next client call
#      dies with "lost server" (test-respawn-loop-integration.sh). Measured
#      12/12 servers killed with the login shell vs 0/6 with /bin/sh, in
#      interleaved batches on the same host at the same load. The crash is
#      upstream (tmux 2.6 + a heavyweight rc chain), not ours — but a test
#      suite has no business handing tmux that input.
#
# Both vanish once the fixture stops inheriting the operator's shell. Start
# every fixture server as:
#
#     th_tmux_fixture_conf "$WORK/tmux.conf"
#     tmux -L "$sock" -f "$WORK/tmux.conf" new-session -d ...
#
# `-f` alone (already used by test-integration/_harness.sh) neutralises the
# user's ~/.tmux.conf but NOT default-shell, which is a compiled-in default
# derived from the invoking user — it must be set explicitly.

# th_tmux_fixture_conf <path>
#
# Write a hermetic tmux config for a fixture server. Pins the pane shell to
# a POSIX sh run WITHOUT rc files (`default-command` makes tmux exec it
# non-login), zero-based indices, and no status line (nothing for a fixture
# to redraw, and no `#()` status jobs from a personal config).
th_tmux_fixture_conf() {
    local path="$1" sh
    sh=$(command -v sh 2>/dev/null) || sh=/bin/sh
    cat > "$path" <<CONF
set -g default-shell $sh
set -g default-command $sh
set -g base-index 0
set -g pane-base-index 0
set -g status off
set -g history-limit 5000
CONF
}

# th_fork_headroom
#
# How many more tasks this uid may create before fork returns EAGAIN.
# Prints an integer, or `unknown` when either input cannot be read.
#
# TASKS, NOT PROCESSES. RLIMIT_NPROC is checked against the real uid's
# task (thread) count, and the two differ by ~5.7x on this host — 871
# tasks against 153 processes, measured the same instant. Counting
# processes here would report ~6x the headroom that actually exists,
# which is the failure mode this helper exists to end rather than
# reproduce.
#
# PER-UID, and that is the whole difficulty: every agent, worker and
# watcher in the sandbox draws from ONE pool, so a suite's headroom is
# a property of what the entire board is doing and not of the suite.
th_fork_headroom() {
    local soft tasks
    soft=$(ulimit -Su 2>/dev/null) || soft=""
    [[ "$soft" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
    tasks=$(ps -Lu "$(id -u)" -o pid= 2>/dev/null | grep -c .) || tasks=""
    [[ "$tasks" =~ ^[0-9]+$ ]] && (( tasks > 0 )) || { printf 'unknown'; return 0; }
    local h=$(( soft - tasks ))
    (( h < 0 )) && h=0
    printf '%s' "$h"
}

# th_cpu_pressure
#
# What fraction of recent wall-clock at least one runnable task spent STALLED
# waiting for a CPU. Prints a float 0-100 (PSI `some avg10` for cpu), or
# `unknown` when the gauge cannot be read.
#
# WHY THIS EXISTS, AND WHY LOADAVG IS NOT IT (your-org/nexus-code#720).
# `#655` established that fork-EAGAIN is attributable and loadavg is not
# causal for it, and `#718` added `fork-headroom` so the next occurrence could
# be classified. That works, and its NEGATIVE is the problem it leaves behind:
# a CI-side occurrence sampled `fork-headroom=2037 of 2109` — 96.6% free —
# which excludes fork starvation and attributes NOTHING. A healthy headroom
# beside a failing suite reads as "resources were fine", which is this repo's
# dominant defect class pointed at its own instrument.
#
# The sampler's only CPU-ish field is loadavg, and loadavg CANNOT do this job
# for the comparison `#720` actually has to make — workstation against runner:
#
#   * It is UN-NORMALIZED. Measured here: loadavg 44.21 on 36 cores = 1.23x
#     oversubscription. The CI sample: loadavg 5.19 on 2 vCPU = 2.60x. The
#     runner was under MORE than twice the relative CPU pressure while its raw
#     number was 8x SMALLER. Compared as printed, the field reads backwards.
#   * On Linux it counts UNINTERRUPTIBLE (D-state) tasks, so it conflates I/O
#     wait with CPU demand.
#   * It is a 1/5/15-minute EWMA, so it lags a burst that a suite dies inside.
#
# PSI measures the property directly — time stalled on the CPU runqueue, in
# percent, already normalized, with a 10-second window. Available since kernel
# 4.20; present on this host (5.4) and on GitHub-hosted runners. Measured here
# at `some avg10=29.06` WITH `fork-headroom=6884 of 8192` — precisely the
# regime the current fields cannot distinguish from healthy.
th_cpu_pressure() {
    local line v
    line=$(grep -m1 '^some' /proc/pressure/cpu 2>/dev/null) || line=""
    [[ -n "$line" ]] || { printf 'unknown'; return 0; }
    # `some avg10=29.06 avg60=30.66 avg300=29.63 total=…`
    v=${line#*avg10=}; v=${v%% *}
    [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'unknown'; return 0; }
    printf '%s' "$v"
}

# th_require_fork_headroom <tasks> [<label>]
#
# A suite's declared resource precondition. rc 0 when the headroom is
# there (or cannot be measured — an unreadable gauge must not block a
# run); otherwise prints a numeric diagnostic and rc 1.
#
# WHY A PRECONDITION AT ALL (your-org/nexus-code#655). Without one, a
# starved run dies part-way through with `fork: retry: Resource
# temporarily unavailable` — or, under `timeout`, with a wholly different
# wording — and the operator sees a red suite. Four rounds went into
# correlating those reds against loadavg before the mechanism was pinned.
# A precondition converts an intermittent, misattributed red into a
# legible statement about the machine, made BEFORE any assertion runs.
#
# The caller is expected to `exit 77` on rc 1 — SKIP, which #568 A6 made
# a first-class status precisely so that "declined to run" can never be
# counted as evidence. That is the honest outcome here: the suite
# asserted nothing, and saying so is neither a pass nor a defect report.
# Failing RED instead would put a resource condition in the same bucket
# as a code defect, which is the conflation being removed.
#
# CALIBRATION IS MEASURED — and the measurement is NOISIER than the first
# version of this comment claimed. That version read "deterministic EAGAIN
# at <= 80, 3/3 green at 85, 90, 100, 110, 130, 150, one flake at 95", from
# three replicates per point. An independent re-run at six replicates found
# green AND red at both 60 and 85 (rc 254/124 mixed with rc 0), i.e. a BROAD
# STOCHASTIC transition, not a sharp boundary near 90. Three replicates was
# too few to see it — this chain's own "one run is not a measurement",
# applied to its own table.
#
# What survives, and why the shipped guard is unaffected: 256 sits above the
# entire noisy band either measurement found, and it was chosen generous for
# exactly this reason. Callers should declare a value comfortably above their
# measured need; the point is to fire only in the regime that genuinely
# breaks, never to become a second source of flakiness. Do NOT read the
# numbers above as a boundary to calibrate against.
th_require_fork_headroom() {
    local need="${1:-0}" label="${2:-this suite}" have
    [[ "$need" =~ ^[0-9]+$ ]] || return 0
    have=$(th_fork_headroom)
    # An unreadable gauge is not evidence of starvation. Degrade to
    # running the suite, exactly as every other surface in this repo
    # degrades to its prior behaviour rather than to a wrong answer.
    [[ "$have" =~ ^[0-9]+$ ]] || return 0
    (( have >= need )) && return 0
    printf 'RESOURCE PRECONDITION NOT MET — %s needs %s tasks of fork headroom, %s available.\n' \
        "$label" "$need" "$have" >&2
    printf '  RLIMIT_NPROC soft=%s, uid TASKS in use=%s (per-UID: shared with every agent on this box).\n' \
        "$(ulimit -Su 2>/dev/null || echo '?')" \
        "$(ps -Lu "$(id -u)" -o pid= 2>/dev/null | grep -c . || true)" >&2
    printf '  This is a statement about the MACHINE, not a test failure: the suite declined to run\n' >&2
    printf '  rather than die part-way through with EAGAIN and be read as a red.\n' >&2
    printf '  your-org/nexus-code#655. Re-run when the board is quieter, or raise ulimit -Su.\n' >&2
    return 1
}

# th_deadline <unloaded-seconds>
#
# Convert a deadline written in UNLOADED seconds into one appropriate for
# the host actually running the suite. Echoes the scaled value.
#
# WHY (your-org/nexus-code#558): every deadline in this suite is a guess
# about how long an event takes, made on the author's machine. That guess
# is only valid at the contention the author had. `test-jupyter-service.sh`
# is the worked example — green 93/93 standalone, failing EVERY full-suite
# run at `--jobs 4`, because its 20 s service-health deadlines were sized
# on an idle host. Nothing was wrong with the code under test; the suite
# had simply oversubscribed the CPU and then asserted an unloaded-host
# timing.
#
# Deadlines here are polled ceilings, not measurements: `wait_for` returns
# the instant its predicate holds, so a LARGER deadline costs zero wall
# time on a green run. It only changes how long a genuinely-broken run
# waits before it reports failure. That asymmetry is why scaling up is
# safe and does not blunt the assertion — unlike an upper-bound `elapsed <
# N` assertion, where inflating N really does erode what is being caught.
#
# Scale = CPU oversubscription, rounded up, floored at 1: on a 2-vCPU
# runner at `--jobs 4`, deadlines double; on a 36-core box at `--jobs 4`
# they are untouched. `NEXUS_TEST_DEADLINE_SCALE` overrides outright (CI
# sets it where the runner shape is known); `NEXUS_TEST_JOBS` is exported
# by run-tests.sh so a test knows the parallelism it is competing with.
th_deadline() {
    local base="${1:-0}" scale jobs cpus
    scale="${NEXUS_TEST_DEADLINE_SCALE:-}"
    if [[ ! "$scale" =~ ^[0-9]+$ ]] || (( scale < 1 )); then
        jobs="${NEXUS_TEST_JOBS:-1}"
        [[ "$jobs" =~ ^[0-9]+$ ]] && (( jobs >= 1 )) || jobs=1
        # `nproc` (coreutils) honours the process's CPU AFFINITY mask;
        # `getconf _NPROCESSORS_ONLN` reports system-wide online CPUs and
        # ignores it. The right denominator is "CPUs actually available to
        # this run" — under a `taskset`-pinned repro (or a cgroup-capped
        # CI runner) those differ, and only nproc tracks the real
        # contention. Fall back to getconf, then 1, if nproc is absent.
        cpus=$(nproc 2>/dev/null) \
            || cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cpus=1
        [[ "$cpus" =~ ^[0-9]+$ ]] && (( cpus >= 1 )) || cpus=1
        scale=$(( (jobs + cpus - 1) / cpus ))
        (( scale < 1 )) && scale=1
    fi
    [[ "$base" =~ ^[0-9]+$ ]] || base=0
    printf '%s' "$(( base * scale ))"
}

# th_tmux_wait_pane <tmux-cmd...> -- <target> <needle> [<timeout-seconds>]
#
# Poll capture-pane until <needle> appears in <target>'s visible content.
# Because tmux parses a pane's byte stream strictly in order, a sentinel
# printed AFTER some earlier escape sequence proves tmux has already
# processed that sequence — a real happens-before edge, unlike a sleep.
# Returns 0 on sighting, 1 on timeout (or if the server died).
th_tmux_wait_pane() {
    local -a cmd=()
    while (( $# )); do [[ "$1" == "--" ]] && { shift; break; }; cmd+=("$1"); shift; done
    local target="$1" needle="$2" timeout="${3:-30}"
    local deadline=$(( SECONDS + timeout ))
    while (( SECONDS < deadline )); do
        grep -qF -- "$needle" \
            <<<"$("${cmd[@]}" capture-pane -p -t "$target" 2>/dev/null)" && return 0
        sleep 0.1
    done
    return 1
}

# A MISSING ASSERTION HELPER MUST FAIL THE SUITE (your-org/nexus-code#609).
# Found while writing test-remote-identity-health.sh: `assert_rc` is not defined
# here — ten suites each define it privately — so a new suite that sources this
# file and calls it gets `command not found`, rc 127, and NOTHING counts it. The
# suite printed "ALL TESTS PASSED" with 14 exit-code assertions silently doing
# nothing. That is the very defect class this issue is about: a check that cannot
# fail is believed.
#
# Scoped deliberately to `assert_*` / `th_*` names: any OTHER missing command
# keeps stock bash behaviour (127 + the usual message), so no existing suite that
# deliberately invokes an absent binary changes behaviour. The sentinel file
# closes the subshell hole — an increment inside `$( )` would be discarded, but
# the file survives, and th_summary_and_exit reads it.
_TH_MISSING_ASSERT_SENTINEL="${TMPDIR:-/tmp}/.th-missing-assert.$$"
command_not_found_handle() {
    case "${1:-}" in
        assert_*|th_*)
            printf '  FAIL: MISSING TEST HELPER `%s` — this assertion did NOT run.\n' "$1" >&2
            printf '        A suite that calls an undefined assert_* silently passes; failing loudly instead.\n' >&2
            _th_fail_missing
            : > "$_TH_MISSING_ASSERT_SENTINEL" 2>/dev/null || true
            return 127
            ;;
    esac
    printf '%s: command not found\n' "${1:-}" >&2
    return 127
}

# rc comparison. Lives here now rather than being redefined per suite, which is
# how it came to be missing for a suite that assumed it was shared.
assert_rc() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"
        _th_pass
    else
        printf '  FAIL: %s — rc %s want %s\n' "$label" "$got" "$want" >&2
        _th_fail
    fi
}

# th_expect_fail <label> <want-count> -- <command> [args...]
#
# Run a command that is SUPPOSED to fail assertions, assert how many it
# provoked, and net those failures out of the ledger so the suite stays green.
#
# WHY THIS EXISTS (your-org/nexus-code#821, from the `#819` skeptic's F3). The
# `#805` ledger cannot distinguish a failure that was LOST in a subshell from
# one that was PROVOKED there on purpose — both are just an `F` appended by a
# child. That is correct and deliberate: guessing would defeat the point. But it
# left the deliberate-positive-control idiom with no way to say so, and the
# ratchet in test-summary-honesty-manifest.sh PRINTS the advice "route this
# suite through th_summary_and_exit". Following that advice for a file built on
# provoked failures — `test-lit-probe-order-dependence.sh` has seven
# `$( assert_… )` sites — would have produced a FALSE RED, blaming a subshell
# loss that was the whole point of the test. A remedy that is wrong for the file
# it is printed to is how a guard teaches people to ignore it.
#
# HOW THE NETTING WORKS. The ledger is append-only, because that is what lets a
# subshell's writes reach the parent. So a deliberate failure is not erased —
# a compensating `x` is appended, and the summary subtracts. Same mechanism,
# same durability, no special case in the reconciliation path.
#
# The in-memory counter is restored separately, and only if it actually moved:
# a provocation that ran in the MAIN shell incremented `FAIL` and must be undone,
# while one that ran in a subshell never touched it and must not be.
#
# KNOWN LIMIT — IT CANNOT YET BE ADOPTED BY THE FILE IT WAS BUILT FOR.
# `"$@" >/dev/null 2>&1` DISCARDS the command's output. All seven deliberate
# sites in `test-lit-probe-order-dependence.sh` — the only file in the tree that
# needs this helper — 3 `$( assert_no_claim … )` and 4 `$( assert_same_verdict … )`,
# counted on the tree — are of the form `NC_A=$( assert_no_claim … 2>&1 )`: they
# CAPTURE the emitted text and assert on it in the main shell. So the remedy as
# shipped cannot be taken up there without extending this helper to expose the
# captured output. That, not "worth its own review", is the real reason that
# file remains recorded in `summary-honesty.manifest` as `ledger=no::count=floor`
# rather than converted. Recorded here because the honest blocker is mechanical
# and a future author will otherwise rediscover it the hard way
# (your-org/nexus-code#830 skeptic, F2).
#
# THE COUNT IS ASSERTED, NOT ASSUMED. `<want-count>` is what makes this a test
# rather than a mute. A blanket "ignore failures in here" would suppress a REAL
# regression alongside the intended one — the exemption-shaped hole this repo
# keeps closing. If the block stops provoking failures, or provokes more than it
# should, that is itself a red.
th_expect_fail() {
    local label="$1" want="$2"; shift 2
    [[ "${1:-}" == "--" ]] && shift
    local mem_before lf_before lf_after got
    mem_before=${FAIL:-0}
    lf_before=$(_th_ledger_count F)
    "$@" >/dev/null 2>&1 || true
    lf_after=$(_th_ledger_count F)
    got=$(( lf_after - lf_before ))
    # Undo the in-memory increment ONLY if the provocation ran here.
    FAIL=$mem_before
    # …and net the ledger, one compensating mark per provoked failure.
    local i=0
    while (( i < got )); do _th_note x; i=$(( i + 1 )); done
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s (provoked %s expected failure(s))\n' "$label" "$got"
        _th_pass
    else
        printf '  FAIL: %s — provoked %s failure(s), expected %s\n' "$label" "$got" "$want" >&2
        _th_fail
    fi
}

# Count one outcome letter in the ledger. Prints 0 when the ledger is absent
# or unreadable, which is the safe direction: a ledger that cannot be read
# reconciles nothing and leaves the in-memory counters exactly as they were.
_th_ledger_count() {
    local letter="$1" n
    [[ -r "$_TH_LEDGER" ]] || { printf '0'; return 0; }
    n=$(grep -c "^${letter}\$" "$_TH_LEDGER" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# ── FIXTURE PORT ALLOCATION (your-org/nexus-code#800, class of #769) ────────
#
# THE MECHANISM, established by `#769` and confirmed in the wild. A port
# allocator that probes with a TCP **connect** predicts a property it does not
# measure: a connect detects only a LISTENING socket. A port already held as the
# EPHEMERAL SOURCE PORT of an outbound connection answers "free" to a connect
# and then fails `bind()` with `[Errno 98] Address already in use` — with AND
# without `SO_REUSEADDR`. The probe is deterministic, so "retry on seizure" was
# a placebo until the probe itself was fixed:
#
#     note: fixture port 33054 was SEIZED between allocation and bind (x3)
#     LOG: OSError: [Errno 98] Address already in use
#
# `#797` fixed the allocator in test-remote-identity-health.sh. `#800` is the
# same class, unclosed repo-wide and WEAKER: the remaining suites derive fixture
# ports with bare arithmetic — `PORT=$(( 21000 + ($$ % 4000) ))` — and never ask
# whether the port is bindable at all. Two exposures, both measured on this host:
#
#   * EPHEMERAL OVERLAP. `/proc/sys/net/ipv4/ip_local_port_range` is
#     `32768 60999` here and on the CI runners; several derived windows reach
#     into it, which is `#769`'s mechanism with no probe in front of it.
#   * CROSS-SUITE COLLISION. Derived windows overlap each other, and
#     `run-tests.sh --jobs N` schedules the colliding suites concurrently.
#
# WHY A COLLISION IS WORSE THAN A FLAKE HERE. A seized port makes the fixture
# fail to start, the affected case SKIPS, and the suite still prints ALL TESTS
# PASSED — 66/0 instead of 78/0 has been observed. The decisive case silently
# stops running. That is `#805`'s defect wearing a network costume, which is why
# these two fixes ship together.
#
# THE EXCLUSION SET IS A FILE, NOT A VARIABLE, AND THAT IS THE WHOLE TRICK.
# The natural call site is `PORT=$(th_alloc_port 21000)` — a COMMAND
# SUBSTITUTION, i.e. a subshell. An in-memory `_TH_PORTS_TAKEN` updated inside
# it dies with the child, so every allocation in a suite would be made against
# an empty exclusion set and two allocations could return the SAME port. That is
# precisely the subshell-scoped-mutation defect the assertion ledger above
# exists to answer; writing it a second time, in the same file, on the same day,
# would be the rule this repo keeps re-learning. Keyed on `$$` for the same
# reason the ledger is: a subshell inherits it, a separate process does not.
#
# HONEST LIMIT, inherited from `#797` and unchanged: this BINDS but does not
# HOLD. The probe socket closes before the fixture binds, so the answer remains
# a PREDICTION — a far better-evidenced one, but a prediction. Eliminating the
# race outright means handing the fixture a pre-bound descriptor, which would
# mean rewriting `sshd -p` and both python fixtures.
_TH_PORTS_FILE="${TMPDIR:-/tmp}/.th-ports.$$"
if [[ -z "${_TH_PORTS_INIT:-}" ]]; then
    _TH_PORTS_INIT=1
    : > "$_TH_PORTS_FILE" 2>/dev/null || true
fi

# th_alloc_port <base> [<extra-exclude-csv>] [<bind-addr>]
#
# Print a port in [base, base+899] that `bind()` — not `connect()` — reports as
# free, excluding every port this test process has already been handed. rc 1 if
# the whole window is unavailable, which is a REAL failure and must not be
# swallowed: `PORT=$(th_alloc_port 21000) || th_abort "no free port"`.
#
# <bind-addr> defaults to 127.0.0.1. Pass the address the FIXTURE will bind: a
# port free on loopback is not necessarily free on 0.0.0.0, and probing the
# wrong address is the same "measured something adjacent" error as the connect
# probe it replaces.
th_alloc_port() {
    local base="$1" extra="${2:-}" addr="${3:-127.0.0.1}" excl got
    excl=$(tr '\n' ',' <"$_TH_PORTS_FILE" 2>/dev/null)
    [[ -n "$extra" ]] && excl="${excl}${extra}"
    got=$(python3 -c '
import socket, sys
base = int(sys.argv[1]); pid = int(sys.argv[2])
excl = set(int(x) for x in sys.argv[3].split(",") if x.strip())
addr = sys.argv[4]
for i in range(200):
    p = base + ((pid + i * 7) % 900)
    if p in excl:
        continue
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind((addr, p))
    except OSError:
        continue
    finally:
        s.close()
    print(p)
    sys.exit(0)
sys.exit(1)
' "$base" "$$" "$excl" "$addr" 2>/dev/null) || return 1
    [[ "$got" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$got" >>"$_TH_PORTS_FILE" 2>/dev/null || true
    printf '%s' "$got"
}

# ── HEREDOC-AWARE SOURCE VIEW FOR CORPUS LINTS (your-org/nexus-code#806) ────
#
# THE TRAP THIS CLOSES. Six suites under monitor/watcher/ lint the corpus by
# grepping RAW SOURCE for a forbidden idiom — test-diagnostics-outlive-their-paths,
# test-sigpipe-assertion-lint, test-ambient-shell-option-scope,
# test-count-fallback-lint, test-uncounted-abort-lint, test-zsh-modifier-lint.
# A line-based grep cannot tell code a file RUNS from fixture text a file
# WRITES, so any suite that plants a violation to prove its own detector works
# gets flagged BY that detector. `#797` hit this: the moment its file became
# tracked, the guard flagged its own planted fixture and reddened five CI bands.
#
# `#797` dodged it by ASSEMBLING the plant from a placeholder so the literal
# never appears in source. That works, but it is a per-author trick — the next
# person to write a literal quoted-heredoc plant self-trips, which the `#797`
# skeptic confirmed against the shipped scanner (`HIT: future-test-newlint.sh:8`).
#
# The mechanism that actually separates the two populations is the HEREDOC:
# text inside one is data the file emits, not code the file executes. So give
# the lints a source view with heredoc BODIES blanked. Blanked, not deleted —
# line numbers must survive, because every one of these lints reports
# `file:line` and a renumbered report is worse than no report.
#
# EXEMPT BY MARKER, NOT BY FILENAME. This helper is the mechanism, not a
# policy: a lint that still needs to exempt a line does it with an in-line
# marker carrying a REASON (the `ambient-shell-option-scope:
# allow-unconditional-unset  <why>` shape already used at the top of this
# file). A filename allowlist erodes silently and, applied to a scanner's own
# file, blinds the one file best able to hide a violation.
#
# THE FAIL DIRECTION IS THE WHOLE DESIGN. Stripping can only REMOVE lines from
# a lint's population, so a stripper bug hides real violations — silently, which
# is this repo's dominant defect class. Two guards:
#
#   1. `<<` in ARITHMETIC is a left shift, not a heredoc. `$(( budget << streak ))`
#      in monitor/watcher/_scheduler.sh:574 parses as a heredoc opened with the
#      delimiter `streak`, which never appears again — so a naive stripper blanks
#      that file from line 574 to EOF and every lint goes quietly blind on it.
#      Measured on this tree, not imagined. Arithmetic depth is tracked and `<<`
#      inside it is ignored; a delimiter must also be letter-or-underscore
#      initial, which is what rejects `(o1 << 24)` in monitor/_remote_lib.sh:356.
#
#   2. AN UNTERMINATED HEREDOC AT EOF MEANS THE PARSE WAS WRONG. Real scripts
#      close their heredocs. If one is still open at EOF the stripper has
#      mis-parsed, so it discards its own output, emits the file UNCHANGED, and
#      says so on stderr. The lint then over-reports (its old behaviour) instead
#      of under-reporting. Loud and conservative beats silent and permissive.
_TH_QUOTES_AWK="$(dirname "${BASH_SOURCE[0]}")/_shell_quotes.awk"
th_strip_heredocs() {
    local f="$1"
    [[ -r "$f" ]] || return 1
    # The quote state machine is SHARED with uncounted-abort-lint.sh
    # (`_shell_quotes.awk`). It used to be inline here and a second, wrong copy
    # lived in the lint — a `sed` pair that paired any two apostrophes and ate
    # real code between them. One machine, two callers, is the point.
    local _q; _q="$(cat "$_TH_QUOTES_AWK" 2>/dev/null)" || return 1
    [[ -n "$_q" ]] || return 1
    awk "$_q"'
    function push(d, dash_) { n++; delim[n] = d; dsh[n] = dash_ }
    function scan(s,   i, L, j, d, dash_, q, arith, c2, c1, qm) {
        L = length(s); i = 1; arith = 0
        # Quote state from the SHARED machine. A `<<` inside a quoted string is
        # TEXT, not a redirection operator — monitor/test-conflict-marker-lint.sh
        # passes a single-quoted literal [cat <<EOF] to a helper as an argument.
        # The mask is consulted rather than a strip applied, because a heredoc
        # delimiter is usually QUOTED (<<[EOF]) and stripping quoted text would
        # delete the very delimiter this function exists to capture.
        qm = quote_mask(s)
        while (i <= L) {
            c1 = substr(s, i, 1)
            if (substr(qm, i, 1) == "1") { i++; continue }
            if (c1 == "#") break        # rest of the line is a comment
            c2 = substr(s, i, 2)
            # Track arithmetic context so a left shift is never read as a
            # heredoc. Both `$(( … ))` and a bare `(( … ))` command count.
            if (c2 == "((") { arith++; i += 2; continue }
            if (c2 == "))" && arith > 0) { arith--; i += 2; continue }
            if (c2 == "<<") {
                if (substr(s, i + 2, 1) == "<") { i += 3; continue }   # herestring
                if (arith > 0) { i += 2; continue }                    # left shift
                j = i + 2; dash_ = 0
                if (substr(s, j, 1) == "-") { dash_ = 1; j++ }
                while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
                q = substr(s, j, 1); d = ""
                if (q == "\"" || q == "'"'"'") {
                    j++
                    while (j <= L && substr(s, j, 1) != q) { d = d substr(s, j, 1); j++ }
                    j++
                } else {
                    if (q == "\\") j++
                    while (j <= L && substr(s, j, 1) ~ /[A-Za-z0-9_]/) { d = d substr(s, j, 1); j++ }
                }
                # Letter-or-underscore initial: rejects the numeric delimiter a
                # left shift like `(o1 << 24)` would otherwise manufacture.
                if (d ~ /^[A-Za-z_][A-Za-z0-9_]*$/) push(d, dash_)
                i = j; continue
            }
            i++
        }
    }
    { raw[NR] = $0 }
    {
        if (n > 0) {
            t = $0
            if (dsh[1]) sub(/^\t+/, "", t)
            if (t == delim[1]) {
                for (k = 1; k < n; k++) { delim[k] = delim[k+1]; dsh[k] = dsh[k+1] }
                n--
            }
            out[NR] = ""        # body AND terminator are data, never code
            next
        }
        c = $0; sub(/^[ \t]+/, "", c)
        if (substr(c, 1, 1) != "#") scan($0)   # a comment cannot open a heredoc
        out[NR] = $0
    }
    END {
        if (n > 0) {
            printf("th_strip_heredocs: %s: heredoc `%s` unterminated at EOF — ", FILENAME, delim[1]) > "/dev/stderr"
            printf("mis-parse suspected, emitting the file UNSTRIPPED\n") > "/dev/stderr"
            for (k = 1; k <= NR; k++) print raw[k]
            exit 0
        }
        for (k = 1; k <= NR; k++) print out[k]
    }
    ' "$f"
}

th_summary_and_exit() {
    local _lp _lf _ls _lm _lx _lost_fail=0 _lost_pass=0 _nothing=0
    _lp=$(_th_ledger_count P); _lf=$(_th_ledger_count F); _ls=$(_th_ledger_count S)
    _lm=$(_th_ledger_count M)
    # `M` (missing helper) counts toward FAIL exactly like `F`; it is tracked
    # apart only so the loss can be attributed to the right cause below.
    _lf=$(( _lf + _lm ))
    # `x` marks a failure PROVOKED on purpose via th_expect_fail and already
    # asserted there (your-org/nexus-code#821). Netted out here rather than
    # never recorded, so the ledger stays append-only and subshell-durable.
    _lx=$(_th_ledger_count x)
    _lf=$(( _lf - _lx ))
    (( _lf < 0 )) && _lf=0

    # RECONCILE FROM THE LEDGER (your-org/nexus-code#805, variant 2). The ledger
    # survives the subshell the counters die in, so where it is higher it is the
    # truth. Reconcile upward for all three, but treat the two directions
    # DIFFERENTLY, because they mean different things:
    #
    #   a lost FAIL is a FAILURE THAT DID NOT FAIL THE SUITE — `#783`'s defect
    #   reached by a different road, and the suite must go red;
    #
    #   a lost PASS/SKIP is a COUNT THAT UNDERSTATES ITS OWN COVERAGE — the work
    #   was done and it passed. Correcting the number is right; reddening on it
    #   would punish suites for the legitimate `x=$(fn_that_asserts)` idiom.
    (( _lf > ${FAIL:-0} )) && { _lost_fail=$(( _lf - FAIL )); FAIL=$_lf; }
    (( _lp > ${PASS:-0} )) && { _lost_pass=$(( _lp - PASS )); PASS=$_lp; }
    (( _ls > ${SKIP:-0} )) && SKIP=$_ls
    rm -f "$_TH_LEDGER" 2>/dev/null || true

    if [[ -f "$_TH_MISSING_ASSERT_SENTINEL" ]]; then
        rm -f "$_TH_MISSING_ASSERT_SENTINEL"
        (( FAIL >= 1 )) || FAIL=1     # the increment may have been lost in a subshell
        echo "  (at least one assertion helper was MISSING — see the FAIL lines above)" >&2
    fi

    # NOTHING WAS ASSERTED (your-org/nexus-code#805, variant 1). Checked AFTER
    # reconciliation, so a suite whose every assertion ran in a subshell is not
    # accused of asserting nothing — the ledger saw those.
    if (( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} == 0 )); then
        _nothing=1
    fi


    # Attribute the loss. A missing helper (`M`) is ALWAYS lost — bash forks
    # before `command_not_found_handle` — and it has already printed its own,
    # more specific diagnosis above. Subtracting it here is what stops the
    # summary printing two competing explanations for one event.
    _lost_fail=$(( _lost_fail - _lm ))
    (( _lost_fail < 0 )) && _lost_fail=0
    if (( _lost_fail > 0 )); then
        printf '  FAIL: %d FAILING assertion(s) were counted in a SUBSHELL and lost.\n' \
            "$_lost_fail" >&2
        printf '        `assert_*` mutates globals; inside ( … ), $( … ) or a pipeline the\n' >&2
        printf '        increment dies with the child. The durable ledger caught it; without\n' >&2
        printf '        it this suite would have exited 0 over a real failure.\n' >&2
    fi
    if (( _lost_pass > 0 )); then
        printf '  NOTE: %d passing assertion(s) were counted in a SUBSHELL; the count below\n' \
            "$_lost_pass" >&2
        printf '        is the LEDGER total, not the in-memory one. Not a failure — but an\n' >&2
        printf '        EXPECTED=<n> guard pinned to the in-memory number was pinned to a lie.\n' >&2
    fi

    echo
    if (( _nothing )); then
        # THE ZERO-ASSERTION BANNER (your-org/nexus-code#805). rc 1, deliberately,
        # NOT 77. The runner reads 77 as "this file declined to run" and tallies a
        # SKIP without reddening the run — the right answer for a file that knows
        # it cannot run and says so BEFORE asserting. Reaching the SUMMARY having
        # counted nothing is a different animal: the file intended to assert and
        # did not, which is broken, not skipped. The two honest spellings for a
        # genuine skip both remain available and both keep the suite green:
        # `th_skip <label> <reason>` (SKIP >= 1, per-case) and a bare `exit 77`
        # before the summary (file-level, `#568` A6).
        printf '=== summary: NOTHING ASSERTED — this suite claimed nothing ===\n'
        printf 'NOT A PASS: 0 passed, 0 failed, 0 skipped — no assertion ran.\n' >&2
        # NOTE FOR ANYONE EDITING THIS TEXT: it must NOT contain the literal pass
        # banner. Runners, CI steps and humans all `grep -c` that exact string,
        # so a FAILING suite whose diagnostic quotes it gets counted as a pass —
        # this very defect, reintroduced by the message that describes it.
        # test-assertion-ledger.sh asserts the absence and is how it was caught.
        printf '  A summary reached with all three counters at zero is indistinguishable\n' >&2
        printf '  from a clean sweep — to every reader, and to anything grepping for the\n' >&2
        printf '  pass banner.\n' >&2
        printf '  If this file legitimately cannot run here, say so: `th_skip <label> <reason>`\n' >&2
        printf '  for a single case, or `exit 77` before the summary for the whole file.\n' >&2
        exit 1
    fi
    if (( ${SKIP:-0} > 0 )); then
        printf '=== summary: %d passed, %d failed, %d SKIPPED (precondition absent — NOT covered) ===\n' \
            "$PASS" "$FAIL" "$SKIP"
    else
        printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
    fi
    if (( FAIL == 0 )); then
        # A file with skipped cases is NOT an unqualified pass. `ALL TESTS
        # PASSED` is the literal string humans and scrapers grep for, and
        # emitting it bare over an assertion that never ran is the same
        # overclaim `#568` A6 catalogued one level up — `#611` surfaced the
        # skip through the RUNNER, but a file run directly still announced a
        # clean sweep. Still exit 0: a skip is not a failure. Just never under
        # a banner that says everything was covered.
        if (( ${SKIP:-0} > 0 )); then
            printf 'ALL TESTS PASSED (%d case(s) SKIPPED — NOT covered)\n' "$SKIP"
        else
            echo "ALL TESTS PASSED"
        fi
        exit 0
    fi
    exit 1
}

# Populate <work-dir> with a minimal fake nexus tree:
#   <work-dir>/monitor/ng                  — copy of monitor/ng
#   <work-dir>/monitor/mint-token.sh       — echoes the configured token
#   <work-dir>/config/load.sh              — answers github.repo and
#                                            github.user_login; other keys
#                                            exit 2 (default) or fall
#                                            through to "$2" with
#                                            --allow-default.
#   <work-dir>/reports/                    — empty dir for upload tests
#
# Side effect: sets the global $FAKE_NEXUS to <work-dir>.
#
# Consolidates the 7-file duplication flagged by the watcher
# test-suite audit (your-org/nexus-code#37). Tests that need
# non-default stub behavior (e.g. an erroring mint-token) can call
# this helper first and then overwrite the generated files.
setup_fake_nexus() {
    local work_dir="$1"; shift
    local token='fake-installation-token'
    local repo='default-org/default-repo'
    local user='test-user'
    local allow_default=0
    while (( $# > 0 )); do
        case "$1" in
            --token)         token="$2"; shift 2 ;;
            --repo)          repo="$2"; shift 2 ;;
            --user)          user="$2"; shift 2 ;;
            --allow-default) allow_default=1; shift ;;
            *)
                printf 'setup_fake_nexus: unknown flag %q\n' "$1" >&2
                return 2
                ;;
        esac
    done

    # `ng` lives at monitor/ng; we are at monitor/watcher/_test_helpers.sh.
    local _th_dir _ng_src
    _th_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    _ng_src="$_th_dir/../ng"
    if [[ ! -f "$_ng_src" ]]; then
        printf 'setup_fake_nexus: ng not found at %s\n' "$_ng_src" >&2
        return 2
    fi

    FAKE_NEXUS="$work_dir"
    mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config" "$FAKE_NEXUS/reports"

    # PIN THE STATE DIR INTO THE FIXTURE (your-org/nexus-code#833).
    #
    # Copying `ng` into a fixture does NOT sandbox it. `_resolve_state_dir`
    # prefers `$NEXUS_STATE_DIR`, then the INHERITED `$NEXUS_ROOT`, and only
    # then its own location — so a fixture `ng` run from an agent shell (where
    # NEXUS_ROOT points at the operator's primary) appends to the OPERATOR'S
    # canonical state. Measured on this host: 103 rows across three suites
    # landed in the primary's `ng-usage.jsonl`, one of those bursts produced by
    # the very run that was measuring the leak.
    #
    # The dir is CREATED, not merely named: `ng`'s usage tap is
    # `[[ -n "$verb" && -d "$STATE_DIR" ]] || return 0`, so an absent directory
    # makes the tap a no-op and the fixture would "pass" by not exercising the
    # write path at all — a green that proves nothing.
    #
    # Exported rather than passed per-call: the leak is a property of every
    # `ng` this fixture starts, including ones a future case adds without
    # remembering this comment. That is the point — the wrong thing has to be
    # impossible, not discouraged.
    mkdir -p "$FAKE_NEXUS/monitor/.state"
    export NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state"
    cp "$_ng_src" "$FAKE_NEXUS/monitor/ng"
    # Libraries `ng` SOURCES. It sources these unconditionally and dies
    # if they are missing — deliberately, since the behaviour they
    # replace was silent coercion (your-org/nexus-code#601/#605), and a
    # fallback would reinstate exactly the defect. A fixture that copies
    # `ng` alone therefore produces an `ng` that cannot run at all, so
    # every library `ng` sources must be copied alongside it.
    local _th_lib
    for _th_lib in _bookkeeping.sh; do
        [[ -f "$_th_dir/../$_th_lib" ]] && cp "$_th_dir/../$_th_lib" "$FAKE_NEXUS/monitor/$_th_lib"
    done

    # The config stub interpolates $repo and $user at write time;
    # ${1:-} etc. stay as shell syntax in the generated stub.
    if (( allow_default )); then
        cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)        printf '%s' '$repo' ;;
    github.user_login)  printf '%s' '$user' ;;
    *) [[ \$# -ge 2 ]] && { printf '%s' "\$2"; exit 0; }; exit 2 ;;
esac
STUB
    else
        cat > "$FAKE_NEXUS/config/load.sh" <<STUB
#!/usr/bin/env bash
case "\${1:-}" in
    github.repo)        printf '%s' '$repo' ;;
    github.user_login)  printf '%s' '$user' ;;
    *) exit 2 ;;
esac
STUB
    fi
    chmod +x "$FAKE_NEXUS/config/load.sh"

    cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<STUB
#!/usr/bin/env bash
printf '%s' '$token'
STUB
    chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"
}

# Generate a PATH-shadow `gh` stub. The stub captures every `gh ...`
# invocation's argv to <capture-path> (one line per call) and, for
# `gh api ...` calls, walks argv to extract `$endpoint` (the first
# positional starting with `/`) and `$method` (from `-X METHOD`,
# default `GET`), then dispatches to the caller-supplied case body
# read from stdin. The case body has `$endpoint` and `$method` in
# scope and is responsible for printing the canned response to
# stdout.
#
# --with-body-capture <path>: when set, the stub captures stdin (the
# request body piped via `--input -`) to <path>. Without it, stdin
# is drained to /dev/null to keep upstream from SIGPIPEing. Tests
# that need to assert on the request body opt in via this flag.
#
# Argv walker shape consolidates the three existing stub variants:
# `-X` is 2-arg (method); `-H -f --input` are 2-arg (drained);
# `--paginate` is 1-arg; bare `/path` positional is the endpoint;
# other tokens are skipped. Closes your-org/nexus-code#38.
make_gh_stub() {
    local stub_path="$1" capture_path="$2"; shift 2
    local body_capture=""
    while (( $# > 0 )); do
        case "$1" in
            --with-body-capture) body_capture="$2"; shift 2 ;;
            *)
                printf 'make_gh_stub: unknown flag %q\n' "$1" >&2
                return 2
                ;;
        esac
    done

    local cases_body
    cases_body=$(cat)

    # Quoted-literal limiter ('STUB') keeps every $... and backslash
    # in the template literal; placeholders are substituted afterward.
    local template
    template=$(cat <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> @@CAPTURE@@
if [[ "${1:-}" != "api" ]]; then exit 0; fi
shift
method="GET"
endpoint=""
while (( $# > 0 )); do
    case "$1" in
        -X)            method="$2"; shift 2 ;;
        -H|-f|--input) shift 2 ;;
        --paginate)    shift ;;
        --)            shift; break ;;
        /*)            endpoint="$1"; shift ;;
        -*)            shift ;;
        *)             shift ;;
    esac
done
@@STDIN@@
case "$endpoint" in
@@CASES@@
esac
exit 0
STUB
)

    local stdin_block
    if [[ -n "$body_capture" ]]; then
        stdin_block=$(printf 'if ! [ -t 0 ]; then cat > %q 2>/dev/null || true; else : > %q; fi' \
            "$body_capture" "$body_capture")
    else
        stdin_block='if ! [ -t 0 ]; then cat >/dev/null 2>&1 || true; fi'
    fi

    # Quote the capture path so paths with spaces survive.
    local capture_quoted
    capture_quoted=$(printf '%q' "$capture_path")

    # ${VAR//PAT/REP} doesn't process backslashes inside REP for
    # literal substitution; safe for the case body the caller passes.
    template=${template//@@CAPTURE@@/$capture_quoted}
    template=${template//@@STDIN@@/$stdin_block}
    template=${template//@@CASES@@/$cases_body}

    mkdir -p "$(dirname "$stub_path")"
    printf '%s\n' "$template" > "$stub_path"
    chmod +x "$stub_path"
}

# Run a command with hermetic env. Unsets the five operator-side
# variables that can redirect production code (`monitor/ng`,
# `monitor/watcher/*`) into the real nexus tree:
#
#   TMUX, TMUX_PANE  — tmux context; production code branches on these
#   NEXUS_ROOT       — root path; ng's state-dir resolver reads this
#   NEXUS_CONFIG     — config-yaml path; load.sh reads this
#   HOME             — production code reaches into $HOME/.claude/
#                      (session-id lookup, projects/ enumeration)
#
# Caller pins replacements via inline VAR=value pairs before the
# `--` separator. Without `--` the helper would have no clean way to
# distinguish env assignments from the command being launched.
#
# Usage:
#   run_hermetic NEXUS_STATE_DIR="$STATE_DIR" PATH="$STUB_DIR:$PATH" \
#       -- "$NG" wrap-up 42 "$report"
#
# Audit cross-reference: gold-standard pattern is
# `test-ng-wrap-up.sh:243-254` (post-#41 sweep). Existing tests with
# partial `env -u` insertions migrate by either calling this helper
# or by adding the missing `-u` flags inline. See your-org/nexus-code#41.
run_hermetic() {
    local -a env_args=()
    while (( $# > 0 )); do
        case "$1" in
            --) shift; break ;;
            *=*) env_args+=("$1"); shift ;;
            *)
                printf 'run_hermetic: expected VAR=val or --, got %q\n' "$1" >&2
                return 2
                ;;
        esac
    done
    if (( $# == 0 )); then
        printf 'run_hermetic: no command after --\n' >&2
        return 2
    fi
    env -u TMUX -u TMUX_PANE -u NEXUS_ROOT -u NEXUS_CONFIG -u HOME \
        "${env_args[@]}" "$@"
}

# th_require_stub_claude <nexus-root> <stub-bin-dir>
#
# <stub-bin-dir> is the directory the fixture puts FIRST on PATH (the one
# holding its `claude` stub); the probe prepends it exactly as the fixture's
# own launcher does. Prepending it here is load-bearing, not cosmetic: without
# it the probe would resolve the operator's real binary even under a correct
# `env -u` run and refuse every time — a check that fails closed on the good
# path is worse than none.
#
# Refuse to run unless monitor/_claude-bin.sh, resolved AS THE PROCESS UNDER
# TEST WILL RESOLVE IT, yields the fixture's stub. Exits 1 with a named
# ENV-FAIL and the remedy; never returns on failure.
#
# your-org/nexus-code#746. Installing a stub at `$F/.bin/claude` and putting
# that dir first on PATH does NOT make the stub win. `monitor/locals-env.sh`
# RE-FRONTS `$NEXUS_LOCALS/bin` ahead of whatever the caller prepended, and on
# an operator box it is reached by EVERY non-interactive bash through
# `BASH_ENV=<nexus>/monitor/shellenv/bash_env.sh`. So a fixture that spawns
# `claude` spawns the operator's REAL binary: a live, billed Claude Code
# session sitting in the fixture receiving pasted prompts, and a test that then
# fails for a reason unrelated to what it claims to measure. Three #741
# baselines were taken that way and discarded. CI is immune only because the
# SLOW band is invoked under `env -u NEXUS_ROOT -u NEXUS_LOCALS`.
#
# WHY THIS ASSERTS THE RESOLUTION AND NOT PATH ORDER. A `CLAUDE_BIN` already
# exported in the operator's environment short-circuits _claude-bin.sh before
# PATH is consulted at all, so a PATH-shaped check sails straight past it.
# The property is "what will this fixture execute", so that is what is asked.
# Probing through `bash -c` is deliberate: that is what re-triggers BASH_ENV,
# so the probe sees the environment the process under test will see.
#
# COVERAGE BOUNDARY: this speaks only for the resolution `_claude-bin.sh`
# performs. A fixture that hardcodes a path, or execs `claude` by name without
# going through that helper, is outside it and needs its own check.
th_require_stub_claude() {
    local root="$1" bindir="$2" want="$2/claude" resolved
    resolved=$(
        export PATH="$bindir:$PATH"
        export NEXUS_ROOT="$root"
        bash -c '. "$NEXUS_ROOT/monitor/_claude-bin.sh" && printf %s "$CLAUDE_BIN"'
    ) 2>/dev/null || true
    [[ "$resolved" == "$want" ]] && return 0
    echo "ENV-FAIL: CLAUDE_BIN resolves to the WRONG binary — refusing to run." >&2
    echo "  resolved: ${resolved:-<unresolved>}" >&2
    echo "  expected: $want" >&2
    echo >&2
    echo "  This fixture spawns whatever CLAUDE_BIN names. Running it now would" >&2
    echo "  start a REAL Claude Code session inside the fixture and bill it, and" >&2
    echo "  the run would then fail for a reason unrelated to what it measures —" >&2
    echo "  so any baseline taken from it is void." >&2
    echo >&2
    echo "  Run it the way CI does:" >&2
    echo "    SLOW_TESTS=1 env -u NEXUS_ROOT -u NEXUS_LOCALS <this-test>" >&2
    echo >&2
    echo "  (If CLAUDE_BIN is exported in your shell, unset that too — it" >&2
    echo "   short-circuits monitor/_claude-bin.sh before PATH is consulted.)" >&2
    echo "  your-org/nexus-code#746" >&2
    exit 1
}
