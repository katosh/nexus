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
# ── A COLLISION-PROOF PROCESS KEY (your-org/nexus-code#939 F1) ─────────────
#
# These paths used to be keyed on `$$` alone. A pid is REUSABLE: `pid_max` on
# this host is 36864, so on a busy board the same number comes round in
# minutes. The ledger tolerated that — a fresh process truncates it, see
# `_TH_LEDGER_INIT` below — but the SENTINEL does not: nothing truncates it,
# and `th_summary_and_exit` reads its mere existence as "a helper was missing".
# So a sentinel left behind by a dead process turns a later, wholly CLEAN suite
# RED when the pid comes round, with a diagnostic pointing at FAIL lines that
# were never printed. Measured on this board: 67 such files in /tmp at once.
#
# `$$`+start-time cannot collide: a reused pid necessarily has a later start
# time, so the key is unique for as long as /proc is readable. Field 22 of
# /proc/<pid>/stat is the process start time in clock ticks since boot.
#
# WHY NOT A `mktemp` PATH: it would have to be created at SOURCE time in all
# ~133 sourcing suites and then removed, which means an EXIT trap — and bash
# keeps exactly ONE EXIT trap per shell while 121 of those suites already
# install their own. Registering another silently replaces theirs (or is
# replaced by it). A key that cannot collide needs no cleanup to be SAFE, which
# is why this closes the hazard rather than narrowing its window.
#
# WHY NOT `export`: a subshell must share the parent's key (that is how a
# `command_not_found_handle` firing inside `$( )` reaches the parent's ledger),
# but a genuinely separate `bash` re-sourcing this file must NOT — a fixture
# that uses these helpers would otherwise contaminate its parent's count. A
# plain shell variable has exactly those semantics; an exported one does not.
_th_proc_key() {
    local st
    st=$(awk '{print $22}' "/proc/$$/stat" 2>/dev/null) || st=""
    [[ -n "$st" ]] || st=x        # /proc unreadable: degrade to bare pid
    printf '%s-%s' "$$" "$st"
}
_TH_KEY="$(_th_proc_key)"
_TH_LEDGER="${TMPDIR:-/tmp}/.th-ledger.$_TH_KEY"
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

# REFUSE AN EMPTY NEEDLE (your-org/nexus-code#1038).
#
# THE DEFECT THIS EXISTS TO MAKE UNSPELLABLE. `grep -qF ""` matches EVERY line
# of any haystack — including an empty one, since the here-string supplies one
# empty line — so an empty `$needle` made this assertion pass VACUOUSLY. It did
# not assert a weaker thing; it asserted NOTHING, and then reported the
# caller's failed probe as a success. Measured against the real helper before
# the guard, haystack deliberately carrying the WRONG value:
#
#     needle=[] len=0
#       PASS: line carries the client key      <- hay was AAAATOTALLYWRONGKEY
#       FAIL: control (a genuinely-absent key) <- the same helper, working
#
# WHY IT IS REACHABLE, NOT THEORETICAL. The needle is almost always a captured
# probe — `$(awk … )`, `$(gh api … )`, `$(<file)`. When the PRODUCER of that
# capture fails, it prints nothing and the capture is empty; if its rc is never
# consulted, the assertion downstream certifies a value it never saw. That is
# CLAUDE.md's `fromisoformat` MODE 2 exactly — the error is not lost, it is
# merely off the path that produces the verdict. Two such sites were confirmed
# fail-open (`test-remote-enroll.sh`, `test-remote-self-enroll.sh`) and fixed at
# the call site in `#1036`; their needle came from a `ssh-keygen` whose rc was
# never checked, behind a `command -v ssh-keygen` guard that proves the tool
# EXISTS, not that it SUCCEEDED.
#
# WHY REFUSING IS SAFE. A caller passing an empty needle is ALREADY asserting
# nothing, so turning it red surfaces a pre-existing defect rather than creating
# one. There is no legitimate reading of "assert that this output contains the
# empty string" — it is true of every output, so it can never discriminate. A
# caller that genuinely wants to assert emptiness has `assert_empty`; one that
# wants "this may or may not be present" has no business calling an assertion.
#
# THE DIAGNOSTIC POINTS AT THE CALLER, NOT AT THE HAYSTACK. That is the whole
# value: the haystack is a red herring here — it is the EXPECTED value that came
# back empty, and a reader shown a haystack dump will go looking in the wrong
# place. Naming the producer is what turns this red into a five-minute fix.
#
# THE MIRROR IS NOT SYMMETRIC, AND WAS MEASURED RATHER THAN ASSUMED.
# `assert_not_contains` below already fails CLOSED on an empty needle (the same
# `grep -qF ""` matches, so it takes its FAIL arm), which is the correct
# DIRECTION — a malformed assertion is loud. Its message is misleading, so it
# gains a diagnostic here, but its VERDICT is deliberately unchanged: it failed
# before this commit and it fails after, on exactly the same inputs.
#
# THIS GUARD DOES NOT REACH EVERY CALL SITE, AND THE GAP IS THE MAJORITY.
# Measured at `072e4b0` — `git grep -nE '\bassert_contains\b' 072e4b0 -- '*.sh'`
# for sites, `-l` for files. The partition RECONCILES, which an earlier draft of
# this comment did not: it counted THIS FILE among the "local copies" and its
# parts summed to one less than the total.
#
#   files mentioning assert_contains          203
#     local definers (their own copy)          87   ->  1867 call sites
#     sourcers of this file                   114   ->  1832 call sites
#     neither (cc-harness lint)                 1   ->     1
#     this file itself (the shared definer)     1   ->     2
#                                             ---       ----
#                                             203       3702  (= the total)
#
# Excluding this file's own 2 lines, 3700 are CALLS, of which the guard reaches
# the 1832 in sourcing files — **49.5%**. The other half is still fail-open.
#
# The local copies come in THREE spellings, all vacuous on an empty needle
# (each measured, not assumed):
#   72x  `grep -qF -- "$needle" <<<"$hay"`
#   10x  `[[ "$2" == *"$3"* ]]`            — `*""*` matches anything
#    5x  `"$REAL_GREP" -qF -- "$needle"`   — grep via a variable (the `#618`
#         silent-zero remedy), so the vacuity sits INSIDE the suites written to
#         guard a related silent-zero class
# Tracked at `#1092`. Do NOT read a green board as "the class is closed".
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ -z "$needle" ]]; then
        printf '  FAIL: %s — EMPTY needle: `grep -qF ""` matches anything, so this\n' "$label" >&2
        printf '         assertion could only have passed VACUOUSLY (your-org/nexus-code#1038).\n' >&2
        printf '         Fix the CALLER, not the haystack: its expected value came back empty.\n' >&2
        printf '         Check the rc of whatever produced the needle (a capture that failed\n' >&2
        printf '         prints nothing, and an unconsulted rc turns that into a silent pass).\n' >&2
        _th_fail
        return
    fi
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

# The mirror. It already failed CLOSED on an empty needle before `#1038`, so
# the VERDICT below is unchanged by design — only the diagnostic is added, for
# the same reason as above: "unexpectedly found ''" sends the reader to the
# haystack, when the fault is a caller whose expected value came back empty.
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if [[ -z "$needle" ]]; then
        printf '  FAIL: %s — EMPTY needle: this assertion is malformed, not merely\n' "$label" >&2
        printf '         unsatisfied (your-org/nexus-code#1038). It already failed before that\n' >&2
        printf '         fix, for the wrong stated reason. Fix the CALLER: its expected value\n' >&2
        printf '         came back empty — check the rc of whatever produced the needle.\n' >&2
        _th_fail
        return
    fi
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

# EMPTY PATH (your-org/nexus-code#1038, same class as assert_contains above).
# `[[ ! -e "" ]]` is TRUE, so an empty `$path` made this assertion pass
# VACUOUSLY — it certified the absence of a file whose path it never learned.
# Note the asymmetry with its own mirror, measured at `3458180`: the positive
# form `assert_file_exists` fails CLOSED on an empty path (`[[ -f "" ]]` is
# false), so only this negative half was exposed — the exact inverse of the
# assert_contains/assert_not_contains pair, where the POSITIVE half was the
# exposed one. Which half is fail-open is a property of the operator, not of
# the polarity, so neither pair's safety transfers to the other.
#
# DECLARED HONESTLY: hardening, not a live bug fix — but NOT for the reason an
# earlier draft of this comment gave. That draft claimed every call site passes
# a COMPOSED path (`"$VAR/suffix"`, non-empty even when `$VAR` is). That is
# FALSE and a reader would have inferred a structural invariant that does not
# hold. Measured at `072e4b0` over the 139 call-site lines outside this file
# (`git grep -n assert_no_file 072e4b0 -- '*.sh'`): 83 composed, ~20 literal,
# and **30 pass a BARE `$VAR`** (`$HISTFILE`, `$LPIDFILE`, `$MARKER`, `$OUT`,
# `$SF`, …) — each of which WOULD be empty if its variable were.
#
# So the real basis is EMPIRICAL, not structural: across two full 356-suite runs
# (at `3458180` and at this branch's head) this guard fired ZERO times, i.e. no
# such variable was empty on any executed path. That is an observation over the
# EXECUTED population, not a proof over all paths — the 30 bare-`$VAR` sites are
# where a future empty would come from, and they are unguarded by shape.
assert_no_file() {
    local label="$1" path="$2"
    if [[ -z "$path" ]]; then
        printf '  FAIL: %s — EMPTY path: `[[ ! -e "" ]]` is TRUE, so this assertion\n' "$label" >&2
        printf '         could only have passed VACUOUSLY (your-org/nexus-code#1038).\n' >&2
        printf '         Fix the CALLER: the path it meant to check came back empty.\n' >&2
        _th_fail
        return
    fi
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
# AND THAT IS EXACTLY WHY THE OBSERVER MUST STAND OUTSIDE IT
# (your-org/nexus-code#913). The sentence above is true and the reassuring
# conclusion people drew from it — including the author of this header —
# does NOT follow. Removing the name witness removed one way to
# self-match; it did not remove self-matching. The predicate is the
# fixture root, so when the CALLER'S cwd is inside that root, every
# process the scan forks in order to look — the process-substitution
# subshell, `ls`, their forks — inherits that cwd and is scanned as a
# fixture process. Measured on an EMPTY root, where the correct answer is
# unambiguously zero, 3/3 trials returned the caller plus four of its own
# scan processes; in the documented `n=$(th_reap_fixture_root …)` shape
# the reaper then SIGKILLed the very subshell that invoked it (rc 137,
# verdict never returned). Same shape and magnitude as the
# `grep -F "$root" /proc/*/cmdline` -> 100 hits / 100 trials the argv
# witness produced.
#
# WHICH PART IS LOAD-BEARING, measured ON THIS TREE rather than assumed —
# an earlier draft asserted the wrong one, which is the same defect as
# `#913` itself: a precise-sounding mechanism sentence is what stops the
# next reader looking. Each row is a single-element revert against
# test-fixture-reap-ownership.sh, baseline 50 passed / 0 failed:
#
#   drop the CALLER-FRAME BASHPID exclusion      45/5   NECESSARY
#   drop the three CONSUMER `cd /`s              46/4   NECESSARY
#   drop the PRIMITIVE's own `cd /`              50/0   redundant
#
#   * The caller-frame `BASHPID` exclusion is necessary. `$$` names the
#     TOP-LEVEL shell and never the subshell this function is running in,
#     so excluding only `$$` is what let the reaper signal the very
#     subshell that invoked it (rc 137).
#   * The consumers' `cd /` is necessary — and it was NOT, one commit ago.
#     This inverted when `_th_reap_scan`'s `cd /` moved INSIDE a subshell
#     (so that a direct caller's cwd is no longer silently changed). A
#     function call does not fork, so while that `cd` ran in the function's
#     own frame it also moved the consumer's process substitution and
#     covered for it. Subshelled, it no longer does. Two placements that
#     used to be redundant are now one necessary and one not.
#   * The primitive's `cd /` is therefore redundant for the public path and
#     is kept deliberately, for DIRECT callers of `_th_reap_scan` — a
#     primitive that is only correct when its caller knows the trick is the
#     same shape as the defect. That is an exemption, stated, not implied.
#
# NOT the reason, though an earlier draft said it was: `cd /` inside
# `_th_reap_scan` does not "leave the outer `< <(…)` subshell in the root".
# When it ran unsubshelled it moved that frame — instrumented directly, the
# frame's own /proc/$BASHPID/cwd read `/` after the call. The reason it was
# insufficient alone was the CALLER frame, above.
#
# The general lesson, which is the whole cluster's: a predicate that
# describes WHERE a process is cannot be evaluated from inside the place
# it describes. Whatever the witness, ask where the observer is standing.
#
# THE POPULATION THAT COULD REACH THIS, enumerated so nobody re-derives it.
# SEVENTEEN sites across 15 suites — the number this command actually prints,
# checked against it rather than counted by hand (an earlier draft said
# sixteen; `test-tmux-lookup-sigpipe.sh` has two `$PTMP` sites and they were
# collapsed into one). Treat it as a FLOOR, not a census: the pattern requires
# an all-caps name and a closing quote immediately after, so it misses
# `cd "$RIG/A"` and any mid-line `cd`. A widened pattern gives 23 sites across
# 18 suites; the SUITE LIST below is what matters and it is complete either
# way. At the ref this note was written:
#
#   git ls-files 'monitor/watcher/test-*.sh' 'monitor/test-*.sh' \
#       'monitor/watcher/test-integration/*.sh' \
#     | while IFS= read -r f; do
#         awk -v F="$f" '/^[[:space:]]*cd "\$[A-Z_]+"/ {print F"\t"$2}' "$f"; done
#
#   * EIGHT cd into `$REPO_ROOT` — the checkout, not a fixture root
#     (test-conflict-marker-lint, test-diagnostics-outlive-their-paths,
#     test-fixture-port-lint, test-guards-for-diff, test-strip-heredocs,
#     test-summary-honesty-manifest, test-tmux-lookup-sigpipe,
#     test-zsh-modifier-lint). Harmless for a reason that has nothing to do
#     with the `/` guard, which an earlier draft credited: a caller standing
#     in `$REPO_ROOT` is never standing in the mktemp root it passes.
#   * EIGHT cd into a real mktemp fixture dir (test-claude-md-ancestor-timeline
#     `$FIX`, test-claude-md-count-provenance `$FIX`, test-force-push-check
#     `$TMP`, test-infra-review-recursion `$T`, test-respawn-loop-integration
#     `$F`, test-tmux-lookup-sigpipe `$PTMP`, and both
#     test-integration/*.sh `$HARNESS_DIR`). These are the ones that WOULD
#     have tripped it — and none of them calls the reaper today: the only
#     three files mentioning `th_reap_fixture_root` / `_th_reap_scan` /
#     `th_reap_fixture_survivors` are this file and the two suites in `#890`
#     (`git ls-files | xargs grep -l`). So the hazard was prospective, which is
#     exactly why the header mattered more than the blast radius: it told the
#     next adopter this could not happen.
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
_th_reap_scan() {   # _th_reap_scan <root> [<root>…] -> owned pids, one per line
    # THE WHOLE BODY RUNS IN A SUBSHELL, and that is the point of this file's
    # title (your-org/nexus-code#913). `cd /` is what takes the observer — this
    # frame and every fork it makes, the `ls` and the process substitution —
    # out of any fixture root, so a caller standing inside the root it is
    # asking about still gets a correct answer. Doing it in a subshell means
    # the caller's own cwd is not silently changed to `/` as a side effect,
    # which an earlier draft did.
    #
    # BASHPID, not just `$$`: `$$` names the TOP-LEVEL shell and never the
    # subshell a function call is running in. Excluding only `$$` is what let
    # the reaper signal its own caller.
    #
    # Several roots, because the leak check needs to ask about a whole run's
    # worth at once. One walk of /proc answers for all of them, and — the
    # reason it lives here rather than being re-implemented at the call site —
    # a second copy of this walk is a second place to get the observer wrong.
    ( cd / 2>/dev/null || true
      local line pid tgt r
      while IFS= read -r line; do
          [[ "$line" =~ /proc/([0-9]+)/cwd\ -\>\ (.*)$ ]] || continue
          pid="${BASH_REMATCH[1]}"
          tgt="${BASH_REMATCH[2]}"
          # A removed directory is reported as `<path> (deleted)`. That is KEPT
          # as a match: a process whose cwd no longer exists outlived the
          # fixture that made it, which is the signature, not a disqualifier.
          tgt="${tgt% (deleted)}"
          (( pid == $$ || pid == BASHPID )) && continue
          for r in "$@"; do
              [[ -n "$r" ]] || continue
              if [[ "$tgt" == "$r" || "$tgt" == "$r"/* ]]; then
                  printf '%s\n' "$pid"
                  break
              fi
          done
      done < <(ls -l /proc/[0-9]*/cwd 2>/dev/null) )
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
            # $$ names the TOP-LEVEL shell, never the subshell this function
            # is usually running in (`n=$(th_reap_fixture_root …)`). BASHPID
            # names the current process; excluding only $$ let the reaper
            # SIGKILL its own caller. See the header (your-org/nexus-code#913).
            (( pid == $$ || pid == BASHPID )) && continue
            [[ "$seen" == *" $pid "* ]] && continue    # the two witnesses overlap
            seen+="$pid "
            found=1
            kill "-$sig" "$pid" 2>/dev/null && total=$(( total + 1 ))
        done < <(cd / 2>/dev/null; _th_reap_scan "$root")
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
    remaining=$(cd / 2>/dev/null; _th_reap_scan "$root")
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
    done < <(cd / 2>/dev/null; _th_reap_scan "$root" | sort -u)
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

# ---------------------------------------------------------------------------
# tmux SOCKET-PATH CEILING (your-org/nexus-code#991)
# ---------------------------------------------------------------------------
#
# THE THREE OUTCOMES, and the one that used to wear another's clothes. A suite
# that drives a real tmux server can end in three states, and before this block
# the second was INDISTINGUISHABLE from the third:
#
#   1. the socket path FITS and tmux answers        -> assertions run
#   2. the socket path CANNOT BE FORMED             -> was a FAIL
#   3. the code under test is genuinely broken      -> is a FAIL
#
# `sun_path` is 108 bytes and 107 is the longest path a NUL-TERMINATING caller
# can bind (108 binds with a full-struct `addrlen` — the limit is the calling
# convention, not the kernel); tmux composes `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket-name>`; and a
# session-scratchpad `TMUX_TMPDIR` (~124 bytes here) is over the limit BEFORE
# the suffix. Every `tmux -L` then dies `File name too long`, the suite takes
# its precondition branch, and reports FAIL. Five suites went red that way in
# one session, five attributions were wrong, and a published finding had to be
# retracted.
#
# WHY IT IS NOT AN ORDINARY FLAKE, and therefore why prose was never going to
# be enough. It reproduces IDENTICALLY on every tree, so the standard triage —
# "does this also fail on clean `dev`?" — answers YES, which reads as
# "pre-existing, not mine" and actually means "the apparatus is broken in
# both". A differential where one side PASSES is sound; one where BOTH fail
# establishes nothing about either.
#
# EXIT 78 IS THE SEPARATION, and it needs no change to the runner's status
# vocabulary. `run-tests.sh` prints the rc on every non-zero row
# (`FAIL  test-x.sh  0.01s  rc=78`), so the refusal is visible and greppable
# where a reader already looks, while remaining RED — because coverage really
# was lost and a SKIP would hide that (`#568` A6). 77 was not reused for
# exactly that reason: this is not "this host cannot run the case", it is
# "the environment handed me an address that cannot exist".
#
# The measurement itself lives in `monitor/_tmux_socket.sh` — ONE
# implementation, because a second copy of a rule is a rule that drifts.
#
# SOURCED CONDITIONALLY, AND THE FALLBACK REFUSES RATHER THAN DEGRADES.
# `test-helper-honesty.sh` copies THIS FILE ALONE into a fixture tree
# (`monitor/watcher/_test_helpers.sh`, no sibling `monitor/_tmux_socket.sh`), so
# an unconditional `.` prints `No such file or directory` on stderr for every
# such fixture — and a suite that then CALLED the helper would find
# `tmux_socket_verdict` undefined and get whatever `command_not_found_handle`
# does with it. Measured before this guard: source rc 0, one stderr line, the
# function silently half-defined.
#
# So: source it when it is there, and otherwise define a stand-in that exits
# 78 the moment anybody relies on it. Quiet at source time — a fixture that
# never asks a socket question is not broken by the absence — and LOUD at the
# only point where the absence can produce a wrong answer.
if [ -r "$(dirname "${BASH_SOURCE[0]}")/../_tmux_socket.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/../_tmux_socket.sh"
else
    _th_tmux_socket_lib_missing=1
fi

# Reserved rc for an environment that cannot host a tmux socket.
TH_RC_TMUX_SOCKET_REFUSED=78

# th_require_tmux_socket <socket-name> [<tmux-tmpdir>]
#
# Call this BEFORE the first `tmux -L <socket-name>` in a suite. Returns
# silently when the path fits; otherwise prints the refusal and exits 78.
#
# TAKES THE SOCKET NAME because the ceiling is a property of the WHOLE path,
# not of the directory: two suites inheriting the same `TMUX_TMPDIR` can
# straddle the limit purely on how long they made their socket name. A
# directory-only check would pass one and mis-blame the other.
#
# THE SECOND ARGUMENT IS NOT OPTIONAL DECORATION. A suite that PINS its own
# `TMUX_TMPDIR` (`env … TMUX_TMPDIR="$TT" tmux -L …`) is immune to the ambient
# value, and checking the ambient one for it would produce a FALSE REFUSAL —
# the same class of wrong answer, pointing the other way. Pass the directory
# the suite actually uses; omit it only when the suite genuinely inherits.
# th_require_fixture_repo <dir> [<label>] — REFUSE a fixture path that would
# aim git at the ENCLOSING repository (your-org/nexus-code#1429). `git -C ""`
# is documented as "do nothing" and `cd ""` returns 0 without moving, so a
# fixture path variable that expanded EMPTY — a `local a="$1" b="$a"`
# expansion-order slip, an unset var under no `set -u`, a `mktemp` whose rc
# nobody read — does not make the next git command fail: it runs it against
# the CURRENT repository, which in a nexus is the shared clone or the nexus
# itself, and WRITES there at rc 0. The walk-up trap's empty-string cousin.
# Three refusals, each named: empty, not a directory, not ITS OWN repository
# root (monitor/repo-root.sh, the fail-closed three-valued predicate — a
# subdirectory of the nexus answers `no`, and "could not tell" is not `yes`).
# Exit 97 so the reader cannot mistake it for an assertion failure.
TH_RC_FIXTURE_REPO_REFUSED=97
th_require_fixture_repo() {
    local dir="${1-}" label="${2:-fixture repo}"
    local rr; rr="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../repo-root.sh"
    if [ -z "$dir" ]; then
        printf '  REFUSED: %s path is EMPTY — `git -C ""` and `cd ""` are no-ops, so every\n           git command after this would run against the ENCLOSING repository\n           at rc 0 (your-org/nexus-code#1429). Exiting %s.\n' "$label" "$TH_RC_FIXTURE_REPO_REFUSED" >&2
        exit "$TH_RC_FIXTURE_REPO_REFUSED"
    fi
    if [ ! -d "$dir" ]; then
        printf '  REFUSED: %s path is not a directory: %s (your-org/nexus-code#1429). Exiting %s.\n' "$label" "$dir" "$TH_RC_FIXTURE_REPO_REFUSED" >&2
        exit "$TH_RC_FIXTURE_REPO_REFUSED"
    fi
    local verdict; verdict=$(bash "$rr" "$dir" 2>/dev/null) || true
    case "$verdict" in
        verdict=yes*) return 0 ;;
        *) printf '  REFUSED: %s path is not its OWN repository root: %s\n           repo-root.sh says: %s\n           A probe here would read or WRITE the enclosing repository (your-org/nexus-code#1429, #1196). Exiting %s.\n' \
               "$label" "$dir" "${verdict:-<no verdict>}" "$TH_RC_FIXTURE_REPO_REFUSED" >&2
           exit "$TH_RC_FIXTURE_REPO_REFUSED" ;;
    esac
}

th_require_tmux_socket() {
    local name="${1:?th_require_tmux_socket: socket name required}"
    local dir="${2-}"
    if [ "${_th_tmux_socket_lib_missing:-0}" = 1 ]; then
        printf '  REFUSED: monitor/_tmux_socket.sh is unreachable from %s, so the socket\n' \
               "$(dirname "${BASH_SOURCE[0]}")" >&2
        printf '           path CANNOT BE MEASURED. Proceeding would mean asserting on a\n' >&2
        printf '           precondition nobody checked, which is the defect this helper\n' >&2
        printf '           exists to remove (your-org/nexus-code#991). Exiting %s.\n' \
               "$TH_RC_TMUX_SOCKET_REFUSED" >&2
        exit "$TH_RC_TMUX_SOCKET_REFUSED"
    fi
    local verdict rc measured sockpath
    if [ -n "$dir" ]; then verdict=$(tmux_socket_verdict "$name" "$dir")
    else                   verdict=$(tmux_socket_verdict "$name"); fi
    rc=$?
    [ "$rc" -eq 0 ] && return 0
    measured="${verdict#* }"; measured="${measured%% *}"
    sockpath="${verdict#* }"; sockpath="${sockpath#* }"
    {
        printf '  REFUSED: tmux socket path is %s bytes; the usable maximum is %s.\n' \
               "${measured%%/*}" "$TMUX_SUN_PATH_MAX"
        printf '           path        : %s\n' "$sockpath"
        printf '           TMUX_TMPDIR : %s\n' "${dir:-${TMUX_TMPDIR:-<unset> (tmux falls back to /tmp)}}"
        printf '           This is NOT a failure of the code under test — tmux was never\n'
        printf '           asked to do anything; the address could not be formed\n'
        printf '           (sun_path is 108 bytes; 107 is the most a NUL-terminating\n'
        printf '           caller can bind). your-org/nexus-code#991.\n'
        # THE REMEDY MUST NAME THE VARIABLE THAT ACTUALLY DECIDED THE PATH. When a
        # caller passes an explicit directory, `TMUX_TMPDIR` is NOT what produced
        # it — `test-cc-harness-socket-isolation.sh` derives its socket root from
        # `mktemp -d -t`, i.e. from `$TMPDIR` — and telling that reader to shorten
        # `TMUX_TMPDIR` sends them to change a variable with no effect on the
        # failure. A remedy that does not work is worse than none: it costs a
        # round of "I did what it said and it still fails".
        if [ -n "$dir" ]; then
            printf '           The directory measured was passed explicitly by the caller, so\n' >&2
            printf '           TMUX_TMPDIR is NOT what produced it. Here TMPDIR=%s\n' \
                   "${TMPDIR:-<unset>}" >&2
            printf '           Remedy: shorten whatever produces that directory (for a\n' >&2
            printf '           `mktemp -d -t` root that means TMPDIR), e.g.\n' >&2
            printf '                   export TMPDIR=%s && mkdir -p "$TMPDIR"\n' \
                   "$(tmux_socket_short_tmpdir "$$")" >&2
        else
            printf '           Remedy: export TMUX_TMPDIR=%s && mkdir -p "$TMUX_TMPDIR"\n' \
                   "$(tmux_socket_short_tmpdir "$$")"
        fi
        printf '           No assertions ran. Exiting %s (NOT 77/SKIP: coverage was lost).\n' \
               "$TH_RC_TMUX_SOCKET_REFUSED"
    } >&2
    exit "$TH_RC_TMUX_SOCKET_REFUSED"
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
    # EMPTY NEEDLE (your-org/nexus-code#1038). Same `grep -qF ""` hazard as
    # assert_contains, but the consequence here is worse in kind: this is a
    # HAPPENS-BEFORE primitive, and an empty needle makes it return 0 on the
    # FIRST poll — so the caller is told "tmux has already processed the
    # earlier escape sequence" when tmux may not have processed anything. The
    # sleep-free ordering guarantee in the comment above becomes a sleep-free
    # guarantee of nothing, and every assertion the caller sequences after it
    # inherits the lie.
    #
    # DECLARED HONESTLY: this is HARDENING, not a live bug fix. At `3458180`
    # this primitive has exactly ONE caller (`test-paste-bracketed.sh:84`,
    # `git grep -n th_tmux_wait_pane 3458180 -- '*.sh'`) and it passes the
    # LITERAL `RDY`, so no reachable empty path exists today. The guard is for
    # the next caller, which will pass a captured sentinel.
    #
    # It refuses IMMEDIATELY rather than falling through to the poll loop: a
    # malformed call should not also cost the full timeout before failing.
    if [[ -z "$needle" ]]; then
        printf 'th_tmux_wait_pane: EMPTY needle — refusing (your-org/nexus-code#1038).\n' >&2
        printf '  An empty needle matches the first capture unconditionally, so this\n' >&2
        printf '  would report a happens-before edge that was never established.\n' >&2
        printf '  Fix the CALLER: check the rc of whatever produced the sentinel.\n' >&2
        return 2
    fi
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
# Scoped deliberately to the names below: any OTHER missing command keeps stock
# bash behaviour (127 + the usual message), so no existing suite that
# deliberately invokes an absent binary changes behaviour. The sentinel file
# closes the subshell hole — an increment inside `$( )` would be discarded, but
# the file survives, and th_summary_and_exit reads it.
#
# ── your-org/nexus-code#922: THE PREFIX WAS A NARROWER BOUNDARY THAN THE RULE ──
#
# The rule this guard states is "a missing assertion helper must fail the
# suite". What it IMPLEMENTED was a NAME PREFIX. A misspelled `assert_eqq` is
# caught (it matches `assert_*` — MEASURED, not assumed); a bare `ok` is not,
# because `ok` is an assertion helper by FUNCTION and not by spelling. It fell
# to the default arm, printed `ok: command not found`, returned 127, and was
# counted by nothing.
#
# Not hypothetical, and not a small case: the reporter of `#922` wrote the
# HEADLINE ASSERTION of `#881` as a bare `ok`/`bad` during `#907`. The suite
# went 222 -> 251 passed, 0 failed, with the one check the whole issue rested on
# silently absent. The assertion-count floor could not catch it either — a 127
# leaves no trace in the verdict OR the count, so the total is simply one lower
# than the author believes, with no baseline to compare against.
#
# THE ADDED NAMES ARE MEASURED, NOT GUESSED. They are exactly the
# assertion-shaped names that some helper-sourcing suite DEFINES LOCALLY and
# this file does not export — which is the mechanism by which a name "looks
# available" to somebody moving between suites. At e256d4a, across the 143
# suites that source this file (`git ls-files -- 'monitor/**/*.sh' 'monitor/*.sh'
# | xargs grep -l _test_helpers.sh | wc -l`, cross-checked by shebang):
#
#     pass  14 suites      ok    5 suites
#     fail  14 suites      bad   4 suites
#
# `pass` and `fail` are nearly three times as common as the two the issue
# named, and none of the four is a real command on this host, so all four reach
# this handler rather than executing something.
#
# WHAT THIS STILL DOES NOT CATCH, stated because a boundary drawn narrower than
# its mechanism is exactly the defect above: a helper name that is neither
# `assert_*`, `th_*`, nor one of these four — a suite-local `expect`, `check`,
# `verify`. This handler can only fire for names somebody enumerated. The
# general case is not solvable at call time (an unknown missing name is
# indistinguishable from a deliberately-absent binary), and is answered
# statically instead by `monitor/watcher/undefined-helper-lint.sh`, which
# derives the whole cross-suite name population from the corpus rather than from
# a list.
_TH_MISSING_ASSERT_SENTINEL="${TMPDIR:-/tmp}/.th-missing-assert.$_TH_KEY"
command_not_found_handle() {
    case "${1:-}" in
        assert_*|th_*|ok|bad|pass|fail)
            printf '  FAIL: MISSING TEST HELPER `%s` — this assertion did NOT run.\n' "$1" >&2
            printf '        An undefined helper exits 127 counted by NOTHING, so the suite would\n' >&2
            printf '        otherwise report success for a check that never executed. Define it,\n' >&2
            printf '        or use one this file exports (assert_eq/contains/not_contains/empty/\n' >&2
            printf '        file_exists/no_file/rc). your-org/nexus-code#922.\n' >&2
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

# REAP THIS PROCESS'S OWN FILES ON EXIT, WHATEVER ROAD IT LEAVES BY
# (your-org/nexus-code#1423, #1474). `th_summary_and_exit` removes the ledger
# and the ports file, but most suites never call it — they carry their own
# tally — and a suite that dies on a timeout calls nothing. Measured on the
# operator's node: 37,727 ledgers + 21,537 ports files live, all zero bytes,
# one pair per process. A sourced library must not CLOBBER the suite's EXIT
# trap, so this installs one only when none exists at source time, and
# `th_trap_exit` below chains for suites that want both. run-tests.sh closes
# the rest of the gap by giving every suite a private TMPDIR it deletes.
_th_reap_own_tmp() {
    rm -f "${_TH_LEDGER:-}" "${_TH_PORTS_FILE:-}" 2>/dev/null || true
}
# th_trap_exit <command> — append <command> to the EXIT trap without losing
# whatever handler is already installed (the helper's reaper, or the suite's).
th_trap_exit() {
    local _prev
    _prev=$(trap -p EXIT | sed -n "s/^trap -- '\(.*\)' EXIT\$/\1/p" | sed "s/'\\\\''/'/g")
    if [[ -n "$_prev" ]]; then trap -- "$_prev; $1" EXIT; else trap -- "$1" EXIT; fi
}
if [[ -z "$(trap -p EXIT)" ]]; then
    trap -- '_th_reap_own_tmp' EXIT
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
_TH_SHF_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/shell-files.sh"
# MOVED to monitor/shell-files.sh as `shf_strip_heredocs` (your-org/nexus-code#1227).
# It is needed by `shf_strip_comments`, and a PRODUCTION predicate must not
# source a TEST helper — which is what `undefined-helper-lint.sh:260` currently
# has to do. This forwarder keeps the six existing `th_strip_heredocs` callers
# byte-identical, and keeps ONE implementation: a second copy here would be the
# `#838`/`#842` two-wrong-machines mistake this function's own header names.
th_strip_heredocs() {
    if ! declare -F shf_strip_heredocs >/dev/null 2>&1; then
        # shellcheck source=monitor/shell-files.sh
        . "$_TH_SHF_LIB" || return 1
    fi
    shf_strip_heredocs "$@"
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
    # The ports file had no removal anywhere: 33,786 zero-byte `.th-ports.<pid>`
    # files under /tmp on 2026-09-03, one per suite process, beside 71,766
    # ledgers left by suites that never reached this line. Both are dirents in a
    # tmpfs — RAM — and both are now also reaped by monitor/tmpfs-guard.sh,
    # which is what covers the early-death paths this line cannot.
    rm -f "$_TH_PORTS_FILE" 2>/dev/null || true

    if [[ -f "$_TH_MISSING_ASSERT_SENTINEL" ]]; then
        rm -f "$_TH_MISSING_ASSERT_SENTINEL"
        (( FAIL >= 1 )) || FAIL=1     # the increment may have been lost in a subshell
        # your-org/nexus-code#939 F1. This used to say "see the FAIL lines above".
        # When the sentinel is genuine those lines are there; the message is
        # still wrong to promise them unconditionally, because the reader who
        # finds none is sent to doubt their own eyes rather than the harness.
        # Say what is known — a sentinel was found — and where to look.
        echo "  (a MISSING TEST HELPER was recorded during this run: an assertion did NOT execute.)" >&2
        echo "  Look for a \`FAIL: MISSING TEST HELPER\` line above. If there is NONE, the" >&2
        echo "  helper fired in a subshell whose output was captured or discarded — grep the" >&2
        echo "  suite for calls to helpers it neither defines nor sources." >&2
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
    # `_merge_ref_base.sh` joined this list with `ng pr merge --verify-base`
    # (your-org/nexus-code#880): that flag SOURCES the library, and a fixture
    # missing it makes the verb refuse every merge. The refusal is correct —
    # absence of the checker is not evidence the base is fine — but it is a
    # fixture defect masquerading as a verdict, which is the shape this whole
    # branch is about. `test-ng-pr.sh` covers the genuinely-missing case by
    # deleting the file from a fixture ON PURPOSE.
    local _th_lib
    # `_nexus-root.sh` joins the list for the same reason (your-org/nexus-code#1077):
    # `ng` refuses to start without the primary-root resolver, because a silent
    # un-pinning of reports and assets from the primary is worse than a refusal.
    for _th_lib in _bookkeeping.sh _merge_ref_base.sh _nexus-root.sh; do
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
    # ONE LINE OF DELEGATION (your-org/nexus-code#932). The template this
    # function used to carry CAPTURED `--jq` into `jq_expr` and never APPLIED
    # it, so every suite built here was blind to the run/job selection layer
    # that lives inside those expressions; the shared builder was the single
    # row of the stub-contract guard's blind-list ratchet. `_gh_stub.sh`'s
    # walker is a superset (`--jq=`, the jq-absent refusal, `ghs_emit` for an
    # arm that wants the expression evaluated) and `--no-autostate` pins the
    # state layer OFF in the generated file, so the callers that pre-digest
    # keep exactly what they had: same capture line, same `$endpoint` /
    # `$method` / `$jq_expr` in scope, same `--with-body-capture` semantics
    # (the body on `--input -`/`--input FILE`, TRUNCATED on a bodiless call),
    # stdin untouched unless a body was announced (#921).
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
    local _mgs_dir; _mgs_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    declare -F ghs_make_stub >/dev/null 2>&1 || . "$_mgs_dir/_gh_stub.sh"
    ghs_make_stub "$stub_path" "$capture_path" --no-autostate ${body_capture:+--with-body-capture "$body_capture"}
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

# th_pin_ng_state <ng-path> <state-dir>
#
# ESTABLISH the state directory every `ng` this suite starts will write to, and
# REFUSE TO CONTINUE if the pin did not take (your-org/nexus-code#1306, #833).
#
# ── WHY A PER-CALL `--state-dir` IS NOT A PIN ──────────────────────────────
#
# `--state-dir` is parsed by the VERB. `ng`'s process-level `STATE_DIR` is
# resolved once at startup by `_resolve_state_dir`, whose order is
# `$NEXUS_STATE_DIR` -> inherited `$NEXUS_ROOT/monitor/.state` -> config
# `nexus.root` -> script-relative. Its usage tap fires BEFORE dispatch and
# appends to that process-level path, so a suite that passes `--state-dir` at
# every call site has pinned the LEDGER and pinned NOTHING ELSE. Measured on
# this host at `0b82ffb2`, one `ng skeptic-evidence` against a nonexistent key
# with `--state-dir` supplied:
#
#     NEXUS_ROOT=<decoy>                        -> <decoy>/monitor/.state/ng-usage.jsonl  WRITTEN
#     NEXUS_ROOT=<decoy> NEXUS_STATE_DIR=<pin>  -> <decoy> untouched, row lands in <pin>
#
# In an agent shell the inherited `NEXUS_ROOT` is the operator's PRIMARY, so the
# first row is a write into live canonical state, at rc 0, with every assertion
# passing. No PASS/FAIL diff can see it; `monitor/nexus-root-sensitivity.sh`
# is the instrument that can.
#
# ── AND `env -u NEXUS_ROOT` IS NOT A FIX FOR THIS CLASS ────────────────────
#
# `nexus-root-sensitivity.sh`'s own remediation text says *"scrub it (unset /
# env -u) or pin it to the fixture at every spawn call site"*. That is right for
# the SPAWN class (#655) and WRONG here, because `_resolve_state_dir` does not
# stop when `NEXUS_ROOT` is gone — its THIRD arm reads config `nexus.root`, and
# on an operator's primary clone that key IS the primary. Measured on this host,
# `ng help` with NEXUS_ROOT unset and `nexus.root` pointed at a decoy:
#
#     env -u NEXUS_ROOT                      -> 1 row in <decoy>/monitor/.state
#     env -u NEXUS_ROOT NEXUS_STATE_DIR=<pin> -> 0 rows in decoy, 1 row in <pin>
#
# and, separately measured, the primary's `config/load.sh nexus.root` answers
# `/shared/.../nexus` — the primary itself.
#
# The direction is the bad one: `config/nexus.yml` is GITIGNORED, so it is
# absent from the probe's decoy (tracked files only) and `nexus.root` there
# answers the example file's placeholder, whose `monitor/.state` does not exist,
# so the tap no-ops. A scrub-fixed suite therefore reports HERMETIC under the
# probe and still writes into the operator's tree at home — a false negative
# produced by following the gate's own advice. Arm 1 is unconditional; use it.
#
# ── WHY THE CHECK IS BEHAVIOURAL, AND WHY IT CANNOT LEAK WHILE CHECKING ────
#
# Asserting `$NEXUS_STATE_DIR == <dir>` would test the SPELLING of the export,
# not the PROPERTY that `ng` honours it — the distinction
# `nexus-root-sensitivity.sh`'s own header is built on. So this runs a real
# `ng` and looks at where the row landed.
#
# The negative arm needs somewhere for a FAILED pin to land, and that place must
# not be the operator's tree: the probe therefore runs with `NEXUS_ROOT` pointed
# at a throwaway decoy carrying a `monitor/.state` directory. That decoy is both
# the containment and the POSITIVE CONTROL — it is a place a leak genuinely
# would appear (the tap is `[[ -n "$verb" && -d "$STATE_DIR" ]]`, so an ABSENT
# directory makes the tap a no-op and the check would pass by never exercising
# the write path at all). Both arms are asserted: the row must be IN the pin and
# ABSENT from the decoy. One arm alone is satisfiable by a broken `ng` that
# writes nowhere.
#
# COVERAGE BOUNDARY, stated because a check's silence is worth exactly its
# coverage: this speaks for processes that resolve state through
# `_resolve_state_dir` — `ng` and the scripts that mirror its order
# (`retire-preflight.sh`, `obligations.sh`, `pane-state.sh`). A helper that
# hardcodes a path, or a child launched with `env -u NEXUS_STATE_DIR`, is
# outside it. It is also silent about READS of the inherited root, which is the
# residual blind spot `nexus-root-sensitivity.sh` names in its own header.
# ADOPTION HAZARD, stated because it bit this helper's own first use: a suite
# that does NOT source this file gets `command not found` — rc 127, a line on
# stderr nobody reads, no counter moved, and a green summary that still leaks.
# `test-ng-wrap-up.sh` is exactly that shape (it defines its own assertion
# vocabulary), so it carries the same check written inline. Before adopting
# this helper, confirm the suite sources `_test_helpers.sh`; the probe is what
# tells you either way, not the diff.
th_pin_ng_state() {
    local ng="$1" dir="$2"
    [[ -n "$ng" && -n "$dir" ]] || th_abort "th_pin_ng_state: need <ng-path> <state-dir>"
    [[ -x "$ng" ]] || th_abort "th_pin_ng_state: ng not executable at $ng"

    mkdir -p "$dir" || th_abort "th_pin_ng_state: could not create $dir"
    export NEXUS_STATE_DIR="$dir"

    local decoy
    decoy=$(mktemp -d "${TMPDIR:-/tmp}/th-pin-XXXXXX") \
        || th_abort "th_pin_ng_state: mktemp failed — the pin is NOT CHECKED"
    mkdir -p "$decoy/monitor/.state"

    # `help` because the tap logs BEFORE dispatch, so the cheapest verb in the
    # file exercises the same write path as the expensive ones. NG_USAGE_LOG is
    # forced on: an operator with it set to 0 would otherwise make both arms
    # below read clean for a reason that has nothing to do with the pin.
    env NEXUS_ROOT="$decoy" NEXUS_STATE_DIR="$dir" NG_USAGE_LOG=1 \
        "$ng" help >/dev/null 2>&1

    local pinned=0 leaked=0
    [[ -s "$dir/ng-usage.jsonl"                 ]] && pinned=1
    [[ -e "$decoy/monitor/.state/ng-usage.jsonl" ]] && leaked=1
    rm -rf "$decoy"

    if (( leaked )); then
        th_abort "th_pin_ng_state: NEXUS_STATE_DIR did NOT contain ng's writes — a probe row reached the decoy root's monitor/.state. Running this suite would write into the inherited NEXUS_ROOT (your-org/nexus-code#1306)."
    fi
    if (( ! pinned )); then
        th_abort "th_pin_ng_state: NOT CHECKED — the probe wrote no usage row into $dir, so the pin is UNVERIFIED in both directions. Refusing to continue rather than reporting an unmeasured green (your-org/nexus-code#1306)."
    fi
    return 0
}

# th_assert_stub_reached <label> <tool> <want-path> -- <child-invocation...>
#
# ALARM for the BASH_ENV/PATH force-front class (your-org/nexus-code#1188,
# #1105, #746). Ask, from inside THE SUITE'S OWN child invocation, which
# binary a bare <tool> actually resolves to, and fail loudly naming what it
# reached instead.
#
# THE CONTRACT THAT MAKES IT WORTH HAVING: it must OBSERVE what the child
# reached, never RE-DERIVE the condition it is guarding. So the caller passes
# its own env-builder as the trailing argv — `-- env $(helper_env)`, `--
# env NEXUS_PATH_FRONT=off`, whatever the suite really uses — and this helper
# appends only `bash -c 'command -v <tool>'`. A probe that hardcoded the
# isolation instead would exercise a COPY of the belt and stay GREEN with the
# belt removed; that shipped once (your-org/nexus-code#1212, fixed 6565041)
# and is the reason this signature takes the invocation rather than building
# one.
#
# WHY IT IS NOT nx_assert_tmux_pinned. That one asserts the SOCKET the child
# reaches, and the socket SURVIVES delegation: monitor/tmuxwrap/tmux is a
# measured pass-through — it resolves the fixture's stub as "the real tmux"
# and execs it, so the pin holds while the recorder log gains one extra
# `show -s command-alias` per child shell. The socket assertion is the right
# alarm for the BOARD-SAFETY hazard (#1105) and is blind to the RECORDER
# FIDELITY hazard (#1188). This asserts the BINARY. A suite that needs both
# calls both.
th_assert_stub_reached() {
    local label="$1" tool="$2" want="$3"; shift 3
    [ "${1:-}" = "--" ] && shift
    local got
    got=$("$@" bash -c "command -v $tool" 2>/dev/null) || got=""
    if [ "$got" = "$want" ]; then
        printf '  PASS: %s\n' "ISOLATION CONTROL — a child reaches $want"
        _th_pass
        return 0
    fi
    printf '  FAIL: %s\n' "ISOLATION CONTROL — the code under test would reach ${got:-<nothing>}, not this fixture's stub $want; every assertion about recorded $tool calls below is about THAT binary (your-org/nexus-code#1188)" >&2
    _th_fail
    return 1
}

# ── CLAUDE.md BLOCK COVERAGE BOUNDARY (your-org/nexus-code#1239) ────────────
#
# th_claude_md_block_coverage MARKER...
#
# Print, in THIS suite's own output, how much of the CLAUDE.md entry the
# named block(s) sit in is actually executed by a fenced block — and how much
# is UNCHECKED prose. One line per marker, asserting nothing: its job is to
# stop a green from being read as coverage of the paragraph a reader acts on.
# The arithmetic lives in `claude-md-block-coverage.sh` (shared with the
# aggregate report in `test-claude-md-block-coverage.sh` §3), so the two
# cannot drift apart. Call it AFTER `gp_handle "$@"` in a suite that declares
# a population — `gp_handle` exits on `--population` and anything printed
# before it is read as a population row.
th_claude_md_block_coverage() {
    bash "$(dirname "${BASH_SOURCE[0]}")/claude-md-block-coverage.sh" "$@" 2>/dev/null || true
}
