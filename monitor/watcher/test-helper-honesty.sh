#!/usr/bin/env bash
# test-helper-honesty.sh — your-org/nexus-code#921 and #922.
#
# Both defects live in `monitor/watcher/_test_helpers.sh`, which **261** of the
# **454** tracked `test-*` suites SOURCE (of **293** files under monitor/ that
# mention it — the distinction is `#939` F4: a `grep -l` population counts
# comments too), and both fail in the direction where a check that never ran is
# reported as a check that passed.
#
# THOSE THREE NUMBERS ARE A PROPERTY OF A TREE — measured at `741191c8`, staged
# and tracked identical, and cited with their commands so the next reader
# re-derives rather than carries them (this header once said 133 / 145, which
# was 40% low by the time anyone checked; your-org/nexus-code#1364 rider):
#
#   bash monitor/watcher/undefined-helper-lint.sh --population          | wc -l   -> 454
#   bash monitor/watcher/undefined-helper-lint.sh --population-sourcing | wc -l   -> 261
#   git ls-files -- 'monitor/**' | xargs grep -l '_test_helpers\.sh'    | wc -l   -> 293
#
# Since #1364 the lint's POPULATION is the 454, not the 261: "sources the
# helper" is a per-file flag deciding only whether the helper's exports are
# reachable there. See the NON-SOURCING band below for what that closes.
#
#   #922  A bare `ok`/`bad`/`pass`/`fail` exits 127, is counted by NOTHING, and
#         the suite announces success for an assertion that does not exist.
#   #921  The generated `gh` stub read stdin whenever stdin was not a TTY, so a
#         GET with no piped body blocked forever if the SUITE's own stdin was an
#         open pipe — an invocation-dependent hang, not a reproducible failure.
#
# ── A NOTE ON WHAT THIS SUITE CAN AND CANNOT PROVE ────────────────────────────
#
# This file tests the test harness while using the test harness, so it shares a
# model with the thing it probes and inherits its blind spots. That is stated
# rather than papered over, and mitigated where it matters most:
#
#   * The #922 checks assert on the RAW EXIT CODE and the LEDGER FILE of a
#     child `bash -c` that sources the helper directly — evidence that does not
#     route through this suite's own accounting.
#   * The end-to-end direction reads a child suite's PRINTED VERDICT, not its
#     internals. That child is synthesised rather than copied from the corpus
#     (see the block for why); the equivalent plant into a REAL tracked suite
#     was run by hand and its before/after numbers are in the PR.
#
# Where a check could only be expressed through the harness, it is marked in a
# comment. A vacuous pass here would look exactly like a clean one, which is the
# whole subject of both issues.
#
# Run: bash monitor/watcher/test-helper-honesty.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO_ROOT=$(pwd)
HELPER="$REPO_ROOT/monitor/watcher/_test_helpers.sh"
LINT="$REPO_ROOT/monitor/watcher/undefined-helper-lint.sh"

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$HELPER"

# ── POPULATION DECLARATION (your-org/nexus-code#803, enrolled for #1030 F2) ──
#
# F2's second half: the lint was reachable by NO gate except transitively
# through this suite, and was named in neither `run-tests.sh` (its own
# collection glob is `test-*.sh`, which `undefined-helper-lint.sh` does not
# match), nor `.github/workflows/`, nor `guard-populations.manifest`. So
# `ng guards-for-diff` could not select it, and an author editing a suite had
# no way to learn that a lint reads it. Visible to a human, invisible to every
# gate.
#
# The declaration FORWARDS to the lint's own `--population` rather than
# restating it: the protocol's one rule, because a copy of an enumerator is a
# second implementation and a second implementation drifts. Added to it are the
# three files the verdict also depends on but that no suite enumeration would
# name — the lint's source, the helper it strips with, and the residue manifest
# it now ratchets against.
. "$REPO_ROOT/monitor/_guard_population.sh"
gp_population() {
    bash "$LINT" --population || return 1
    printf '%s\n' \
        "monitor/watcher/undefined-helper-lint.sh" \
        "monitor/watcher/_test_helpers.sh" \
        "monitor/watcher/_shell_quotes.awk" \
        "monitor/watcher/uhl-unknown-callsites.manifest"
}
gp_handle "$@"

WORK=$(mktemp -d) || exit 1
# NO `tmux kill-server` ANYWHERE IN THIS TRAP. This suite touches no tmux
# server; the cleanup removes one temp directory and nothing else. The
# 2026-08-09 server death started in a test cleanup trap.
trap 'rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════════
echo "=== #922: a missing helper must FAIL, not vanish ==="
# ═══════════════════════════════════════════════════════════════════════════
#
# Driven through a child `bash -c` that sources the helper and reports the
# LEDGER, not through this suite's counters. bash forks before invoking
# `command_not_found_handle`, so the in-memory increment is always lost to the
# parent — the ledger letter `M` is the mechanism, and reading it directly is
# what makes this evidence rather than a restatement.
#
# TMPDIR IS SCOPED TO $WORK (your-org/nexus-code#939 F1). Each `bash -c` below
# is a SEPARATE PROCESS that sources the helper, so each mints its own ledger
# and — for the seven calls that trip the handler — its own SENTINEL. None of
# them reaches `th_summary_and_exit`, which is what would normally remove the
# sentinel, so before this scoping every run of this suite left SEVEN sentinels
# in the shared /tmp. 67 had accumulated. A stale sentinel turns an unrelated,
# wholly clean suite RED when its pid comes round.
#
# The helper reads `${TMPDIR:-/tmp}`, so pointing TMPDIR at $WORK routes every
# child's state into the directory this suite's EXIT trap already removes —
# cleanup by construction rather than a second trap. That is deliberate: bash
# keeps one EXIT trap per shell, so adding another here would silently replace
# the `rm -rf "$WORK"` above.
_922_child_tmp="$WORK/th"
mkdir -p "$_922_child_tmp"
_922_ledger() {   # $1 = shell snippet -> the ledger letters it produced
    TMPDIR="$_922_child_tmp" bash -c '
        . "'"$HELPER"'" >/dev/null 2>&1
        '"$1"' >/dev/null 2>&1
        sort "$_TH_LEDGER" 2>/dev/null | tr -d " \n"
    ' 2>/dev/null
}

# The four assertion-shaped names. `pass` and `fail` are each defined locally in
# 14 suites — nearly three times as many as `ok` (5) and `bad` (4) — so they are
# the likelier slip, and #922 named neither of them.
for _n in ok bad pass fail; do
    assert_eq "#922 a bare \`$_n\` is COUNTED as a failure (ledger M)" \
        "$(_922_ledger "$_n 'planted'")" "M"
done

# The prefix arm must not regress: a misspelled assert_* was ALREADY caught
# before #922, and the fix must not have traded one population for another.
assert_eq "#922 a misspelled \`assert_eqq\` is still caught (prefix arm)" \
    "$(_922_ledger "assert_eqq 'planted' 1 1")" "M"
assert_eq "#922 an unknown \`th_*\` is still caught" \
    "$(_922_ledger "th_nonexistent_helper 'planted'")" "M"

# NEGATIVE CONTROL — the boundary must stay where it is. Several suites invoke
# an absent binary ON PURPOSE; widening this handler to every missing command
# would break them, which is a worse trade than the defect it would close.
assert_eq "#922 NEGATIVE CONTROL: an absent BINARY is NOT counted as a failure" \
    "$(_922_ledger "definitely-not-a-real-binary-xyz")" ""

# …and it still returns 127 with the stock message, so nothing that relies on
# the ordinary behaviour changes.
_922_rc=$(TMPDIR="$_922_child_tmp" bash -c '. "'"$HELPER"'" >/dev/null 2>&1; definitely-not-a-real-binary-xyz >/dev/null 2>&1; echo $?')
assert_eq "#922 …and still exits 127 for it" "$_922_rc" "127"

# The diagnostic must name the helper and say what went wrong. A guard that
# fires with an unreadable message costs the reader the same time as no guard.
_922_msg=$(TMPDIR="$_922_child_tmp" bash -c '. "'"$HELPER"'" >/dev/null 2>&1; ok "planted" 2>&1')
assert_contains "#922 the failure names the offending helper" "$_922_msg" 'MISSING TEST HELPER `ok`'
assert_contains "#922 …and says the assertion did NOT run" "$_922_msg" "did NOT run"
assert_contains "#922 …and cites the issue" "$_922_msg" "922"

# ── END-TO-END: a suite must not announce success over a missing assertion ──
#
# The checks above prove the mechanism. This proves it is WIRED, because #922
# was filed against a suite printing ALL TESTS PASSED, not against a handler.
#
# A SYNTHESISED suite is used rather than a copy of a tracked one. Two reasons,
# and the second is the load-bearing one:
#   * a real suite resolves its own paths from $BASH_SOURCE, so a copy run from
#     a temp dir cannot find the helper and fails for an unrelated reason —
#     measured, on the first draft of this file;
#   * planting into the tracked tree to run it would mutate the corpus mid-suite,
#     which is a worse hazard than the one being tested.
# The equivalent plant into a REAL tracked suite was run by hand and is recorded
# in the PR: with the old helper it printed `35 passed, 0 failed / ALL TESTS
# PASSED`; with the fix, `35 passed, 1 failed`.
_mk_suite() {   # $1 = path, $2 = the planted line ("" = none)
    {
        printf '#!/usr/bin/env bash\n'
        printf 'set -uo pipefail\n'
        printf '. %q\n' "$HELPER"
        printf 'assert_eq "a real check" 1 1\n'
        printf 'assert_eq "another real check" x x\n'
        [[ -n "${2:-}" ]] && printf '%s\n' "$2"
        printf 'th_summary_and_exit\n'
    } > "$1"
}

# BOTH DIRECTIONS. A clean suite must still pass — a harness that newly fails
# legitimate suites gets disabled by whoever is under time pressure, which
# removes it entirely.
_mk_suite "$WORK/clean.sh" ""
_922_clean=$(TMPDIR="$_922_child_tmp" bash "$WORK/clean.sh" 2>&1)
assert_contains "#922 BOTH DIRECTIONS: a clean suite still announces success" \
    "$_922_clean" "ALL TESTS PASSED"
assert_contains "#922 …with both of its real assertions counted" "$_922_clean" "2 passed"

# …and a suite with a planted bare `ok` must NOT.
_mk_suite "$WORK/planted.sh" 'ok "PLANTED — this assertion does not exist"'
_922_planted=$(TMPDIR="$_922_child_tmp" bash "$WORK/planted.sh" 2>&1)
assert_not_contains "#922 END-TO-END: a planted bare \`ok\` stops the suite announcing success" \
    "$_922_planted" "ALL TESTS PASSED"
assert_contains "#922 END-TO-END: …it reports a failure instead" "$_922_planted" "1 failed"
# The real assertions must still be counted — the guard adds a failure, it does
# not discard the work the suite actually did.
assert_contains "#922 END-TO-END: …without losing the genuine passes" "$_922_planted" "2 passed"

# ── THE POPULATION NEITHER HALF ABOVE CAN REACH ─────────────────────────────
#   your-org/nexus-code#922, the 2026-08-27 comment. NOT FIXED — see the skip
#   note below; these arms are the guard for an OPEN defect.
#
# Everything above proves the property for suites that SOURCE the helper. The
# runtime mechanism is `command_not_found_handle`, which is INSTALLED BY
# `_test_helpers.sh` — so a suite that does not source it never installs it —
# and the static half's lint draws its population by the SAME membership test
# (`undefined-helper-lint.sh` requires an actual `.`/`source` of the helper).
# Both halves are therefore keyed on one predicate, and a suite outside it is
# invisible to BOTH. A boundary drawn narrower than its mechanism is the defect
# this whole file is about; here it is the file's own boundary.
#
# THE POPULATION WAS NOT A CORNER. Measured at 989b888, tracked files, clean
# tree, nothing staged:
#
#   git ls-files -- 'monitor/*test-*.sh' | wc -l                    -> 392
#   bash monitor/watcher/undefined-helper-lint.sh --population      -> 204
#   comm -23 <(git ls-files -- 'monitor/*test-*.sh' | sort) \
#            <(bash monitor/watcher/undefined-helper-lint.sh --population | sort) \
#     | wc -l                                                       -> 189
#
# 203 of the 204 population rows are `test-*.sh`; 203 + 189 = 392, reconciled.
# (git's pathspec `*` crosses `/`, so that one form is the whole subtree —
# your-org/nexus-code#954.)
#
# CLOSED FOR THE STATIC HALF BY your-org/nexus-code#1364: the lint's population
# is now every tracked `test-*` under monitor/ that `shf_is_shell` accepts, and
# the third arm below is LIVE. Note the glob above also matches two NON-suites
# (`test-integration/_harness.sh`, `test-integration/stub-claude.sh` — the
# DIRECTORY name matches `*test-*`), so the live arm filters to basenames.
#
# AND THE DEFECT IS LIVE IN IT. Driven at 989b888 against a REAL tracked suite,
# `monitor/test-conflict-marker-lint.sh` — which defines its own `ok`/`bad` and
# sources nothing — with `assert_eq "PLANTED …" 1 2` appended before its
# summary, i.e. the muscle-memory reach for the shared vocabulary the issue
# describes:
#
#   bash monitor/test-conflict-marker-lint.sh
#       -> rc 0, `24 passed, 0 failed`, `ALL TESTS PASSED`
#          — byte-identical to the unplanted run bar one stderr line
#   monitor/watcher/run-tests.sh --filter conflict-marker-lint
#       -> `PASS  test-conflict-marker-lint.sh   1.02s   24 assertions`, `0 failed`
#   bash monitor/watcher/undefined-helper-lint.sh
#       -> rc 0, `clean — 204 suites … 0 UNKNOWN call site(s)`
#
# So the scoring instrument reports a PASS over an assertion that never ran,
# and no gate in this repo disagrees.
#
# WHAT THIS BAND ASSERTS, AND WHY IT IS THE RUNNER. `run-tests.sh` is the thing
# that turns a suite into a PASS row; the lint's cleanliness is a proxy for it
# and, on this population, a proxy that is clean while the property is false.
# So the arms below drive the REAL `run-tests.sh` over a two-file fixture
# corpus and read ITS verdict. The runner derives its collection glob from its
# own location, so a copy inside the fixture runs the fixture and nothing else
# — the same construction the lint potency block above uses, for the same
# reason. `NEXUS_TMUX_SOCKET_CHECK=off` is the runner's own documented override
# and is correct here: this corpus selects no suite that starts a tmux server,
# so the check would only import an ambient TMUX_TMPDIR into the verdict.
_ns_fx="$WORK/nsfx"
mkdir -p "$_ns_fx/monitor/watcher"
cp "$REPO_ROOT/monitor/watcher/run-tests.sh" "$_ns_fx/monitor/watcher/run-tests.sh"

_mk_nonsourcing_suite() {   # $1 = path, $2 = the planted line ("" = none)
    cat > "$1" <<'NSA'
#!/usr/bin/env bash
set -uo pipefail
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
ok "a real check"
ok "another real check"
NSA
    [[ -n "${2:-}" ]] && printf '%s\n' "$2" >> "$1"
    cat >> "$1" <<'NSB'
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
echo "FAILED" >&2; exit 1
NSB
}
_mk_nonsourcing_suite "$_ns_fx/monitor/watcher/test-nsfx-clean.sh"   ""
_mk_nonsourcing_suite "$_ns_fx/monitor/watcher/test-nsfx-planted.sh" \
    'assert_eq "PLANTED — the load-bearing check" 1 2'
_ns_run=$(NEXUS_TMUX_SOCKET_CHECK=off timeout 300 \
              bash "$_ns_fx/monitor/watcher/run-tests.sh" 2>&1)
_ns_verdict() {   # $1 = suite basename -> the runner's verdict token for its row
    printf '%s\n' "$_ns_run" \
        | grep -aE "^[[:space:]]*[A-Z]+[[:space:]]+$1([[:space:]]|\$)" \
        | awk 'NR==1{print $1}'
}
# NOTE: `awk 'NR==1{…}'`, NOT `awk '{print $1}' | head -1`. `head` closes the
# pipe early, which is an EARLY-EXIT READER (your-org/nexus-code#682) and would
# enrol this file in `early-exit-readers.manifest`, where it is not — a red in
# an unrelated guard, caused by a guard about honesty. `awk` with no `exit`
# drains its input and can never SIGPIPE its writer.

# CONTROLS, UNGATED. Without them a RED below is unreadable: "the runner did
# not say PASS" is satisfied just as well by a runner that never saw the file,
# never started, or refused. These two establish that it DID run this corpus
# and that the planted suite is IN it, so the only remaining reading of the
# gated arms is the property.
assert_eq "#922 CONTROL: the real runner scores the CLEAN non-sourcing fixture PASS" \
    "$(_ns_verdict test-nsfx-clean.sh)" "PASS"
# THE SECOND CONTROL IS WHAT MAKES THE FIRST GATED ARM FAIL-CLOSED, and it is
# not decoration. That arm is `assert_not_contains <verdict> PASS`, and an EMPTY
# verdict — the runner never emitted a row for this file, or emitted it in a
# shape `_ns_verdict` cannot parse — satisfies it VACUOUSLY. A pass over a
# reading that never happened is precisely the defect this file prosecutes, so
# it must not be reachable from inside the guard for it. Asserting the verdict
# is a MEMBER of the runner's vocabulary closes it: on an empty verdict the
# needle is empty, and `assert_contains` REFUSES an empty needle (`#1038`)
# rather than matching everything. Fail-closed by the helper's own guard.
assert_contains "#922 CONTROL: …and the planted fixture has a verdict the runner recognises" \
    "PASS FAIL SKIP TIMEOUT" "$(_ns_verdict test-nsfx-planted.sh)"

# WHICH ARMS ARE LIVE, AND WHY (your-org/nexus-code#1364 closes the STATIC half).
#
# The THIRD arm — every tracked suite is inside the lint's population — is now
# LIVE and asserted unconditionally: the population is every `test-*` under
# monitor/ that `shf_is_shell` accepts, so the arm reads 0 by construction and
# goes RED the day a suite falls out of it again.
#
# The first two arms are about the RUNTIME half — the runner scoring PASS over
# a non-sourcing suite whose bare `ok` exited 127 — and that is NOT closed
# here: the runtime handler lives inside `_test_helpers.sh` and a suite that
# does not source it never installs it. The lint sees the site (advisory,
# #1364); the runner still scores it. So those two stay `th_skip`: loud on
# stderr, counted apart from PASS, and the footer reads `SKIPPED — NOT covered`
# rather than a clean banner. `NEXUS_UHL_NONSOURCING=1` runs them (measured
# RED at 741191c8 — the property is still false, and that is the point of
# keeping them runnable rather than deleting them).
assert_eq \
    "#922/#1364 NON-SOURCING: every tracked test suite is inside the undefined-helper lint's population" \
    "$(comm -23 <(git ls-files -- 'monitor/*test-*.sh' | grep -E '/test-[^/]*$' | sort) \
                <(bash "$LINT" --population | sort) | grep -c . )" "0"
if [[ "${NEXUS_UHL_NONSOURCING:-0}" == "1" ]]; then
    # THE PROPERTY. Not "the lint is clean" — the runner must refuse to score a
    # pass over an assertion that did not execute, whatever the suite sources.
    assert_not_contains \
        "#922 NON-SOURCING: the runner must NOT score a suite with an undefined helper as PASS" \
        "$(_ns_verdict test-nsfx-planted.sh)" "PASS"
    assert_not_contains \
        "#922 NON-SOURCING: …and the run must not report zero failures" \
        "$_ns_run" "0 failed"
else
    _ns_why='the RUNTIME half of your-org/nexus-code#922 is OPEN for suites that do NOT source _test_helpers.sh (193 of 454 at 741191c8): the lint now SEES the site (#1364, advisory) but the runner still scores it PASS — set NEXUS_UHL_NONSOURCING=1 to run'
    th_skip "#922 NON-SOURCING: the runner must NOT score a suite with an undefined helper as PASS" \
        "$_ns_why"
    th_skip "#922 NON-SOURCING: …and the run must not report zero failures" "$_ns_why"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "=== #921: the gh stub reads stdin only when a body was piped ==="
# ═══════════════════════════════════════════════════════════════════════════
#
# The hang is invocation-dependent, so the repro must MAKE it deterministic:
# stdin is a process substitution that never reaches EOF. Under the old
# `[ -t 0 ]` proxy the stub blocked here forever; `timeout` converts that into
# rc 124, which is an assertable value rather than a hung suite.
#
# Every invocation below is wrapped in `timeout` for the same reason: a
# REGRESSION of this defect must fail the suite, never wedge it. A test for a
# hang that can itself hang is not a test.
make_gh_stub "$WORK/gh" "$WORK/calls" --with-body-capture "$WORK/body" <<'CASES'
    /repos/*/issues/1) printf '{"body":"stub"}\n' ;;
CASES
make_gh_stub "$WORK/gh-nocap" "$WORK/calls2" <<'CASES'
    /repos/*/issues/1) printf '{"body":"stub"}\n' ;;
CASES

# THE DEFECT: a GET with no piped body, with stdin held open.
timeout 10 "$WORK/gh" api /repos/o/r/issues/1 < <(sleep 30) >/dev/null 2>&1
assert_rc "#921 a bodyless GET does not block on an open stdin (body-capture stub)" "$?" 0
timeout 10 "$WORK/gh-nocap" api /repos/o/r/issues/1 < <(sleep 30) >/dev/null 2>&1
assert_rc "#921 …nor does the no-capture stub variant" "$?" 0

# The behaviour that must SURVIVE: `--input -` still captures the piped body.
# This is the case the old code was written for and the one a naive fix breaks.
printf '{"body":"hello"}' | timeout 10 "$WORK/gh" api -X PATCH /repos/o/r/issues/1 --input - >/dev/null 2>&1
assert_eq "#921 CONTROL: --input - still captures the piped body" \
    "$(cat "$WORK/body" 2>/dev/null)" '{"body":"hello"}'

# A bodyless call TRUNCATES the capture rather than leaving the previous body
# in place. "This call sent no body" is a real answer an assertion may rest on,
# and a stale body is indistinguishable from one this call sent.
printf 'STALE-FROM-A-PREVIOUS-CALL' > "$WORK/body"
timeout 10 "$WORK/gh" api /repos/o/r/issues/1 </dev/null >/dev/null 2>&1
assert_empty "#921 a bodyless call truncates the capture (no stale body)" \
    "$(cat "$WORK/body" 2>/dev/null)"

# `--input <file>` reads THAT FILE, which is what real `gh` does. Stdin is held
# open to prove the file path is taken rather than stdin.
printf '{"from":"a file"}' > "$WORK/payload.json"
timeout 10 "$WORK/gh" api -X PATCH /repos/o/r/issues/1 --input "$WORK/payload.json" < <(sleep 30) >/dev/null 2>&1
assert_eq "#921 --input <file> reads the file, not stdin" \
    "$(cat "$WORK/body" 2>/dev/null)" '{"from":"a file"}'

# The argv walker still works after `--input` was split out of the `-H|-f`
# group. `-F` was not handled at all before and is now consumed as 2-arg, so
# the endpoint must still be found past both.
_921_out=$(timeout 10 "$WORK/gh" api -H 'Accept: x' -F key=value /repos/o/r/issues/1 </dev/null 2>/dev/null)
assert_contains "#921 the endpoint still parses past -H and -F" "$_921_out" '"body":"stub"'

# ── A DELIBERATE, MEASURED BEHAVIOUR CHANGE ─────────────────────────────────
#
# A body piped WITHOUT `--input` is no longer drained, so the writer sees
# SIGPIPE (141) exactly as it would against real `gh`, which does not read
# stdin for such a call. The old stub drained unconditionally to prevent this.
#
# Pinned rather than left implicit, and reachability was MEASURED before the
# trade was accepted: at e256d4a no production `ng` call site and none of the
# 10 make_gh_stub suites pipes a body without `--input` (production always
# pairs `printf … | api … --input -`). If that ever changes, this assertion
# fails and the trade gets re-examined instead of surfacing as a mystery 141.
#
# WHICH non-zero code proves "not drained" is a property of the ENVIRONMENT,
# not of the stub, so it is MEASURED here rather than pinned. With SIGPIPE
# fatal — every shell in this lab — the writer is killed by signal 13 and the
# pipeline reports 141 under `pipefail`. With SIGPIPE inherited as SIG_IGN,
# write() returns EPIPE instead: bash's printf builtin reports `write error:
# Broken pipe` and exits 1. GitHub Actions' step shells are in the second
# world, so pinning 141 outright made this suite RED on every PR's CI while
# every local run stayed green (your-org/nexus-code#1262). Both codes prove the
# body was not drained; only 0 would mean it WAS, and 0 is what the guard is
# for.
#
# The control is asserted BEFORE the real probe, so a control that failed to
# break the pipe at all cannot quietly make the comparison vacuous.
_921_want=$( { printf 'x%.0s' {1..200000} 2>/dev/null | true; echo $?; } )
_921_broke=no; [[ "$_921_want" != "0" ]] && _921_broke=yes
assert_eq "#921 CONTROL — a reader that does not read breaks the pipe (writer rc=$_921_want)" \
    "$_921_broke" "yes"
_921_pipe_rc=$( { printf 'x%.0s' {1..200000} 2>/dev/null | timeout 10 "$WORK/gh-nocap" api /repos/o/r/issues/1 >/dev/null 2>&1; echo $?; } )
assert_eq "#921 a body piped WITHOUT --input is not drained (faithful to gh; want rc=$_921_want)" \
    "$_921_pipe_rc" "$_921_want"

# ═══════════════════════════════════════════════════════════════════════════
echo "=== #939 F1: the sentinel must not be a shared-/tmp landmine ==="
# ═══════════════════════════════════════════════════════════════════════════
#
# The sentinel is created by `command_not_found_handle` and removed only by
# `th_summary_and_exit`. Any process that trips the handler and does NOT reach
# the summary leaves one behind — and this suite trips it deliberately, seven
# times per run, in `bash -c` children that never summarise. Before `#939` F1
# that leaked 7 files per run into the SHARED /tmp; 67 had accumulated. With a
# pid-keyed name and `pid_max` 36864, a leftover turns a later, wholly CLEAN
# suite RED when the number comes round.
#
# Two independent properties, because cleanup alone only narrows the window:
#   1. this suite leaks NOTHING into the shared /tmp (TMPDIR scoping), and
#   2. the key CANNOT COLLIDE even if something does leak (pid + start time).

# (1) LEAK. Count shared-/tmp sentinels before and after provoking the handler
# the same way the #922 block does. `/tmp` is shared with other windows, so the
# assertion is on the DELTA, never on the absolute count — a neighbouring suite
# creating one of its own must not fail this.
_f1_before=$(ls /tmp/.th-missing-assert.* 2>/dev/null | wc -l)
_922_ledger "ok 'leak probe'" >/dev/null 2>&1
_922_ledger "bad 'leak probe'" >/dev/null 2>&1
_f1_after=$(ls /tmp/.th-missing-assert.* 2>/dev/null | wc -l)
assert_eq "#939 F1 provoking the handler leaks NOTHING into the shared /tmp" \
    "$(( _f1_after - _f1_before ))" "0"
# …and the children's state really did land somewhere this suite cleans up.
# WITHOUT this control the assertion above passes just as well if the handler
# stopped firing altogether — a zero delta would then mean "nothing happened",
# not "nothing leaked". (An earlier draft of this control compared a value to
# itself and was therefore vacuous; removed, because that is this PR's own
# subject arriving in its own test.)
_f1_child=$(ls "$_922_child_tmp"/.th-missing-assert.* 2>/dev/null | wc -l)
if (( _f1_child > 0 )); then
    _th_pass; printf '  PASS: #939 F1 CONTROL: the handler DID fire (%d child sentinels under $WORK)\n' "$_f1_child"
else
    _th_fail; printf '  FAIL: #939 F1 CONTROL: no child sentinel anywhere — the leak probe proved nothing\n' >&2
fi

# (2) COLLISION-PROOF. A bare pid is reusable; pid+start-time is not.
assert_contains "#939 F1 the process key carries more than a pid" "$_TH_KEY" "-"
_f1_pid_only=${_TH_KEY%%-*}
_f1_start=${_TH_KEY#*-}
assert_eq "#939 F1 …its first field is this pid" "$_f1_pid_only" "$$"
if [[ "$_f1_start" =~ ^[0-9]+$ ]] && (( _f1_start > 0 )); then
    _th_pass; printf '  PASS: #939 F1 …and its second field is a real start time (%s)\n' "$_f1_start"
else
    _th_fail; printf '  FAIL: #939 F1 second key field is not a start time: %s\n' "$_f1_start" >&2
fi
# The sentinel path must actually USE the key — a collision-proof key that the
# filename ignores would be a comment, not a fix.
assert_contains "#939 F1 the sentinel path uses the collision-proof key" \
    "$_TH_MISSING_ASSERT_SENTINEL" "$_TH_KEY"
assert_contains "#939 F1 …and so does the ledger path" "$_TH_LEDGER" "$_TH_KEY"

# The diagnostic must not promise FAIL lines it cannot guarantee (#939 F1).
_f1_diag=$(sed -n '/a MISSING TEST HELPER was recorded/,+3p' "$HELPER")
assert_not_contains "#939 F1 the summary no longer promises 'the FAIL lines above'" \
    "$_f1_diag" "see the FAIL lines above"
assert_contains "#939 F1 …and tells the reader what to do when there are none" \
    "$_f1_diag" "If there is NONE"

# ═══════════════════════════════════════════════════════════════════════════
echo "=== #939 F5: --input=<value> is the same verb as --input <value> ==="
# ═══════════════════════════════════════════════════════════════════════════
#
# `--input=-` is standard cobra syntax and real `gh` reads stdin for it. The
# first fix matched only the space-separated token, so the attached form
# silently truncated the capture and did not read stdin — turning the old HANG
# class into a wrong-answer class. Latent (no current caller uses it) but the
# stub must model the verb, not one spelling of it.
printf '{"body":"attached"}' | timeout 10 "$WORK/gh" api -X PATCH /repos/o/r/issues/1 --input=- >/dev/null 2>&1
assert_eq "#939 F5 --input=- reads stdin like --input -" \
    "$(cat "$WORK/body" 2>/dev/null)" '{"body":"attached"}'
printf '{"from":"attached file"}' > "$WORK/payload2.json"
timeout 10 "$WORK/gh" api -X PATCH /repos/o/r/issues/1 --input="$WORK/payload2.json" < <(sleep 30) >/dev/null 2>&1
assert_eq "#939 F5 --input=<file> reads that file, not stdin" \
    "$(cat "$WORK/body" 2>/dev/null)" '{"from":"attached file"}'

# ═══════════════════════════════════════════════════════════════════════════
echo "=== #922 static half: the undefined-helper lint ==="
# ═══════════════════════════════════════════════════════════════════════════
if [[ -x "$LINT" || -r "$LINT" ]]; then
    # It must be CLEAN on the real corpus. A lint that fails legitimate suites
    # is disabled by the first person under time pressure, which removes it
    # entirely — so this direction matters as much as the catching direction.
    _lint_out=$(bash "$LINT" 2>&1); _lint_rc=$?
    assert_rc "#922 lint is CLEAN on the corpus (no false positives)" "$_lint_rc" 0
    assert_contains "#922 …and reports its population, so a zero is checkable" \
        "$_lint_out" "suites"
    # #1364: the summary line names BOTH halves of the population and the
    # advisory count, so a reader of the clean line sees the widened axes
    # were measured rather than absent.
    assert_contains "#1364 …the summary names the sourcing/non-sourcing split and the advisory mode" \
        "$_lint_out" "do not; advisory)"
    assert_contains "#1364 …and publishes the ADVISORY count on the widened axes" \
        "$_lint_out" "ADVISORY call site(s) on the widened axes"

    # ── THE REFUSE ARMS, DRIVEN (your-org/nexus-code#939 F3) ────────────────
    #
    # This block previously carried a comment claiming "the refusal arms are
    # exercised by the unit checks below". There were no such checks: ZERO
    # assertions in this file asserted rc 2. In a PR whose subject is "a check
    # that never ran must not be reported as one that passed", a comment
    # asserting coverage that does not exist is the same defect at the
    # documentation layer. So the arms are driven, not described.
    #
    # Driven by making the ENUMERATION fail rather than by editing the lint: a
    # stub `git` early on PATH returns nothing for `ls-files`, which is exactly
    # the "I could not look" condition. Note `#906 B` — the property under test
    # is that this is REFUSED (2), never reported clean (0).
    _lint_stub="$WORK/stubbin"
    mkdir -p "$_lint_stub"
    printf '#!/usr/bin/env bash\ncase "$1" in ls-files) exit 0 ;; rev-parse) echo stub ;; *) exit 0 ;; esac\n' \
        > "$_lint_stub/git"
    chmod +x "$_lint_stub/git"
    _refuse_out=$(PATH="$_lint_stub:$PATH" bash "$LINT" 2>&1); _refuse_rc=$?
    assert_rc "#922 lint REFUSES (2) when the suite enumeration comes back empty" \
        "$_refuse_rc" 2
    assert_contains "#922 …and says so, rather than reporting clean" \
        "$_refuse_out" "REFUSED"
    # NEGATIVE CONTROL for the stub itself: without it, the same invocation is
    # clean. Otherwise a lint that refused for an unrelated reason would satisfy
    # the assertion above and prove nothing.
    _ctrl_rc=0; bash "$LINT" >/dev/null 2>&1 || _ctrl_rc=$?
    assert_rc "#922 CONTROL: the same lint is clean without the stub (rc 0)" "$_ctrl_rc" 0

    # A REFUSAL MUST NOT BE MISTAKEN FOR A FINDING. Exit 1 means "offences
    # found"; exit 2 means "could not look". A caller that treats non-zero as
    # one thing loses the distinction #906 B exists to draw.
    assert_not_contains "#922 …and a refusal does not claim it found offences" \
        "$_refuse_out" "calls a helper NOTHING defines"

    # ── POTENCY, ON A FIXTURE CORPUS (your-org/nexus-code#989) ──────────────
    #
    # Everything above this line tests that the lint is CLEAN and that it
    # REFUSES. Nothing tested that it CATCHES — so every clean verdict above
    # was a zero with no established potency, which is the exact reasoning
    # error the lint itself exists to punish. A guard nobody has seen fire is
    # indistinguishable from a guard that cannot.
    #
    # Driven on a self-contained fixture repo rather than by mutating the real
    # corpus: the lint derives REPO_ROOT from its OWN location, so a copy of it
    # inside the fixture lints the fixture and nothing else.
    _fx="$WORK/fixrepo"
    mkdir -p "$_fx/monitor/watcher"
    # THE FIXTURE HELPER IS THE REAL ONE, COPIED — not a two-line stub
    # (your-org/nexus-code#1030 F1). The stub defined `assert_eq` and `th_skip`
    # and nothing else, so inside the fixture `th_strip_heredocs` was UNDEFINED:
    # every fixture run below scanned RAW files, with zero heredoc stripping,
    # and the lint's old `body=$(th_strip_heredocs "$f") || body=$(cat "$f")`
    # silently took the `||` arm. Measured: `type -t th_strip_heredocs` is
    # empty after sourcing the stub, the call returns rc 127 and 0 bytes, and
    # NOTHING said so. That is precisely the shape this suite exists to
    # prosecute — a checker that could not look, reporting as though it had —
    # running inside its own potency harness. The lint now REFUSES (exit 2)
    # rather than falling back, which is what turned this up.
    cp "$REPO_ROOT/monitor/watcher/_test_helpers.sh" "$_fx/monitor/watcher/_test_helpers.sh"
    cp "$REPO_ROOT/monitor/watcher/_shell_quotes.awk" "$_fx/monitor/watcher/_shell_quotes.awk"
    # AND THE LIBRARY THE HELPER NOW FORWARDS TO (your-org/nexus-code#1227).
    # `th_strip_heredocs` used to be defined in `_test_helpers.sh`; it now lives
    # in `monitor/shell-files.sh` as `shf_strip_heredocs`, with a forwarder that
    # resolves `_TH_SHF_LIB` RELATIVE TO ITS OWN BASH_SOURCE. Copied alone into
    # a fixture, that path is `$_fx/monitor/shell-files.sh` and does not exist,
    # so the forwarder returns 1, the stripper is dead in the fixture, and
    # `undefined-helper-lint.sh` REFUSES corpus-wide at exit 2 — which is the
    # lint being correctly fail-closed about a fixture we broke, not a finding.
    # Measured: 76 passed / 12 failed, every failure `rc 2 want 0|1|4`.
    # The dependency is copied rather than the move reverted, because a fixture
    # that carries a library's caller must carry the library. `_shell_quotes.awk`
    # above is copied for the same reason, one layer down.
    mkdir -p "$_fx/monitor"
    cp "$REPO_ROOT/monitor/shell-files.sh" "$_fx/monitor/shell-files.sh"
    # The fixture corpus needs an EMPTY ratchet of its own; without one the
    # lint refuses (exit 2) because it cannot read the residue it must compare.
    _fx_manifest="$_fx/monitor/watcher/uhl-unknown-callsites.manifest"
    : > "$_fx_manifest"
    # A library reached ONLY through an exported variable — the #989 shape.
    cat > "$_fx/monitor/watcher/_fx_priv_lib.sh" <<'FXL'
_fx_probe_thing() { :; }
FXL
    # Defines both cross-suite names, so both are in the candidate set.
    cat > "$_fx/monitor/watcher/test-fx-defs.sh" <<'FXA'
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
_fx_local_helper() { :; }
_fx_probe_thing()  { :; }
FXA
    ( cd "$_fx" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm f ) >/dev/null 2>&1
    cp "$LINT" "$_fx/monitor/watcher/undefined-helper-lint.sh"
    # `UHL_UNKNOWN_MANIFEST` is repo-relative inside the fixture, and is the
    # axis the ratchet's own potency is driven on below: corpus held constant,
    # manifest varied.
    _fxlint() { ( cd "$_fx" && git add -A >/dev/null 2>&1
                  UHL_UNKNOWN_MANIFEST="${1:-monitor/watcher/uhl-unknown-callsites.manifest}" \
                  bash monitor/watcher/undefined-helper-lint.sh 2>&1 ); }
    _fxlint_rc() { ( cd "$_fx" && git add -A >/dev/null 2>&1
                     UHL_UNKNOWN_MANIFEST="${1:-monitor/watcher/uhl-unknown-callsites.manifest}" \
                     bash monitor/watcher/undefined-helper-lint.sh >/dev/null 2>&1 ); }

    # (a) CATCHES: a call nothing defines, in a suite whose sources all resolve.
    cat > "$_fx/monitor/watcher/test-fx-offence.sh" <<'FXB'
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
_fx_local_helper "planted"
FXB
    _fx_out=$(_fxlint); _fx_rc=$?
    assert_rc "#989 potency: the lint CATCHES a planted undefined helper" "$_fx_rc" 1
    assert_contains "#989 …and names the offending call site" \
        "$_fx_out" "test-fx-offence.sh"
    rm -f "$_fx/monitor/watcher/test-fx-offence.sh"

    # (b) EXONERATES the #989 shape: `source "$LIB"` where LIB is assigned in
    #     the same file. This is the false positive the fix removes —
    #     `_remote_identity_probe` at test-remote-instrument-potency.sh:301.
    cat > "$_fx/monitor/watcher/test-fx-varsource.sh" <<'FXC'
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
LIB="$(dirname "${BASH_SOURCE[0]}")/_fx_priv_lib.sh"
export LIB
source "$LIB"
_fx_probe_thing "reached through an exported variable"
FXC
    _fx_out=$(_fxlint); _fx_rc=$?
    assert_rc "#989 the exonerated shape (source \"\$LIB\") is CLEAN" "$_fx_rc" 0
    assert_not_contains "#989 …and _fx_probe_thing is not called undefined" \
        "$_fx_out" "_fx_probe_thing"

    # (c) UNRESOLVED IS NOT UNDEFINED, *and* is not silent. A source no static
    #     resolver can follow downgrades the verdict to UNKNOWN — which is a
    #     real soundness cost, so it must be counted and printed, never merely
    #     dropped. This asserts BOTH halves; the second is the one that keeps
    #     the exemption honest.
    # WRITTEN WITH printf, NOT A HEREDOC, and that is not a style choice.
    # `test-ambient-shell-option-scope.sh` builds a source graph over this tree
    # and does NOT strip heredocs, so a line-anchored `. "$1"` in fixture TEXT
    # registers as a real unresolvable source token belonging to THIS file —
    # measured: it added `watcher/test-helper-honesty.sh  $1` to that guard's
    # manifest. Quoting each line as a printf argument keeps the fixture bytes
    # identical while leaving no source directive at column 0 here.
    printf '%s\n' \
        '. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"' \
        '_fx_load() {' \
        '    . "$1"' \
        '}' \
        '_fx_local_helper "planted behind an unresolvable source"' \
        > "$_fx/monitor/watcher/test-fx-unknown.sh"
    _fx_out=$(_fxlint); _fx_rc=$?
    # STILL NOT AN OFFENCE — that is `#989` and it stands. What changed with
    # `#1030` F2 is that it is no longer INVISIBLE: an UNKNOWN that is not in
    # the manifest moves the residue, and moving the residue is exit 4.
    assert_rc "#1030 an UNRECORDED unresolvable-source UNKNOWN moves the residue (4)" "$_fx_rc" 4
    assert_contains "#989 …the UNKNOWN is REPORTED, not silently dropped" \
        "$_fx_out" "UNKNOWN"
    assert_contains "#989 …naming the site it could not determine" \
        "$_fx_out" "test-fx-unknown.sh"
    assert_not_contains "#989 …and does not claim it found an offence" \
        "$_fx_out" "calls a helper NOTHING defines"

    # …and RECORDING it makes the same corpus clean again. This is the pair
    # that gives the ratchet its meaning: an unresolvable source is a declared
    # blind spot, not a failure — but it has to be declared. Corpus held
    # constant, MANIFEST varied: the axis the mechanism varies on.
    ( cd "$_fx" && bash monitor/watcher/undefined-helper-lint.sh --unknown-set ) \
        > "$_fx_manifest" 2>/dev/null
    _fx_out=$(_fxlint); _fx_rc=$?
    assert_rc "#1030 …and RECORDING it in the manifest makes the corpus clean (0)" "$_fx_rc" 0
    assert_eq "#1030 …with exactly one recorded row" \
        "$(grep -c . "$_fx_manifest" 2>/dev/null)" "1"
    assert_contains "#1030 …keyed on <file>TAB<name>, not file:line" \
        "$(cat "$_fx_manifest" 2>/dev/null)" "test-fx-unknown.sh"
    assert_not_contains "#1030 …so an unrelated edit shifting line numbers cannot churn it" \
        "$(cat "$_fx_manifest" 2>/dev/null)" ":"
    : > "$_fx_manifest"
    rm -f "$_fx/monitor/watcher/test-fx-unknown.sh"

    # ── (d) F1: INERT HEREDOC TEXT MUST NOT EXEMPT A FILE ──────────────────
    #
    # The defect, driven. The source scan read the RAW file while the call scan
    # read the stripped body, so a `source` line inside a heredoc — fixture
    # text that never executes — set `unresolved_here` and downgraded every
    # finding in that file from UNDEFINED to UNKNOWN. It had already happened
    # to the lint's own suite (THIS file): `#989` added a `<<'FXC'` fixture
    # containing `source "$LIB"`, and a planted offence in it then returned
    # `rc 0, 1 UNKNOWN` where the same line in a non-exempt suite returned
    # `rc 1`. Measured at `3458180`, before and after: 14 suites carried an
    # unresolved source, 3 of them only because of heredoc text
    # (`test-ambient-shell-option-scope.sh`, THIS file, `test-version-restart.sh`);
    # after the fix, 11, and no suite newly exempt.
    #
    # Written with printf rather than a heredoc for the same reason the block
    # above is: `test-ambient-shell-option-scope.sh` does NOT strip heredocs,
    # so a line-anchored source directive in fixture text here registers as a
    # real unresolvable token belonging to THIS file.
    printf '%s\n' \
        '. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"' \
        'cat > /dev/null <<INERT' \
        '. "$AN_UNRESOLVABLE_PATH"' \
        'INERT' \
        '_fx_local_helper "planted behind an INERT heredoc source"' \
        > "$_fx/monitor/watcher/test-fx-heredoc.sh"
    _fx_out=$(_fxlint); _fx_rc=$?
    assert_rc "#1030 F1 a source inside a HEREDOC does not exempt the file — the offence is REPORTED (1)" \
        "$_fx_rc" 1
    assert_contains "#1030 F1 …named as UNDEFINED, not downgraded to UNKNOWN" \
        "$_fx_out" "test-fx-heredoc.sh"
    assert_not_contains "#1030 F1 …and NOT reported as something it could not determine" \
        "$_fx_out" "UNKNOWN: this file has a"
    rm -f "$_fx/monitor/watcher/test-fx-heredoc.sh"

    # ── (e) A STRIPPER THAT CANNOT RUN IS "COULD NOT LOOK", NOT "CLEAN" ────
    #
    # The mutant that defeats the F1 fix without breaking its invariant: the
    # old `body=$(th_strip_heredocs "$f" 2>/dev/null) || body=$(cat "$f")`
    # reverted SILENTLY to the raw file, so both scans still read the same
    # text — invariant intact — while the CONTENT went back to raw and F1
    # returned in full, with no signal at all.
    #
    # Driven by removing the shared quote machine the stripper needs, which is
    # exactly how it fails in practice (`th_strip_heredocs` returns 1 when
    # `_shell_quotes.awk` is unreadable). Not a contrived injection: this is
    # ALSO how the fixture corpus behaved for its whole life before this
    # change, because its two-line stub helper never defined the function at
    # all — rc 127, zero bytes, and every fixture assertion above silently
    # scanning unstripped files.
    mv "$_fx/monitor/watcher/_shell_quotes.awk" "$_fx/quotes.away"
    _fx_out=$(_fxlint); _fx_rc=$?
    mv "$_fx/quotes.away" "$_fx/monitor/watcher/_shell_quotes.awk"
    assert_rc "#1030 a stripper that cannot run is REFUSED (2), never reported clean" "$_fx_rc" 2
    assert_contains "#1030 …and says which files it could not render" \
        "$_fx_out" "could not be rendered"
    assert_not_contains "#1030 …and does not claim it found offences" \
        "$_fx_out" "calls a helper NOTHING defines"
    # CONTROL for (e): the same corpus is clean once the stripper is back.
    _fx_rc=0; _fxlint_rc || _fx_rc=$?
    assert_rc "#1030 CONTROL: the same fixture corpus is clean with the stripper present (0)" \
        "$_fx_rc" 0

    # ── (e2) THE FAIL-SAFE PATH IS ALSO "COULD NOT LOOK" ──────────────────
    #
    # `th_strip_heredocs` does not only fail by exit status. On an UNTERMINATED
    # heredoc it prints `mis-parse suspected, emitting the file UNSTRIPPED` and
    # exits **0** — fail-safe for its own contract, and a silent F1 for this
    # caller: rc says success, the content is raw, and a `2>/dev/null` throws
    # away the one signal that says so. The fix for F1 originally did exactly
    # that; grepping the change for a fresh instance of the class it closes is
    # what turned it up. Same shape as the `|| body=$(cat "$f")` being removed,
    # arriving through the rc that WAS checked rather than the one that was not.
    printf '%s\n' \
        '. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"' \
        'cat > /dev/null <<NEVERCLOSED' \
        '_fx_local_helper "inside a heredoc nobody closed"' \
        > "$_fx/monitor/watcher/test-fx-unterminated.sh"
    _fx_out=$(_fxlint); _fx_rc=$?
    rm -f "$_fx/monitor/watcher/test-fx-unterminated.sh"
    assert_rc "#1030 a stripper that WARNS and emits UNSTRIPPED (rc 0) is REFUSED (2)" "$_fx_rc" 2
    assert_contains "#1030 …naming the file and quoting the stripper's own warning" \
        "$_fx_out" "UNSTRIPPED"

    # ── (f) THE RATCHET IS POTENT ON THE REAL CORPUS ──────────────────────
    #
    # F2's finding was that nothing could tell UNKNOWN from clean: rc 0 by
    # design and a summary always containing "suites", which is exactly the
    # pair this suite asserted. Both still hold at 0 UNKNOWN and at N. So the
    # residue is compared against a manifest, and THAT comparison is what gets
    # a control — driven by varying the MANIFEST with the corpus held fixed.
    # Driven on the FIXTURE corpus, not the real one, and that is a cost
    # decision stated rather than hidden: the lint takes ~71s over 169 real
    # suites, this suite already costs 181s at `3458180`, and `run-tests.sh`
    # kills a test at 600s. Two more real-corpus runs would have put it inside
    # a factor of two of that ceiling for no extra evidence — the properties
    # under test here belong to the COMPARISON, not to the corpus, and the
    # real-corpus arm is already asserted at the top of this block (the lint
    # is clean, rc 0, against the shipped manifest).
    printf 'monitor/watcher/test-no-such-suite.sh\t_no_such_helper\n' > "$_fx_manifest"
    _rat_out=$(_fxlint); _rat_rc=$?
    : > "$_fx_manifest"
    assert_rc "#1030 F2 a residue that disagrees with the manifest is exit 4" "$_rat_rc" 4
    assert_contains "#1030 F2 …and says the residue moved, not that it found an offence" \
        "$_rat_out" "disagrees with the manifest"
    assert_not_contains "#1030 F2 …4 is not 1: a moved residue is not an offence" \
        "$_rat_out" "calls a helper NOTHING defines"
    # …and 4 is not 2 either. A missing manifest is "could not look".
    _miss_rc=0; _fxlint_rc "monitor/watcher/definitely-absent.manifest" || _miss_rc=$?
    assert_rc "#1030 F2 an ABSENT manifest is REFUSED (2), not silently unratcheted" "$_miss_rc" 2

    # ── (g) THE WIDENED POPULATION, WITH ITS NEGATIVE CONTROLS (#1364) ─────
    #
    # The mandatory pair. A lint that flags the planted bare `ok` in a
    # NON-sourcing suite AND does not flag the suite that legitimately defines
    # its own `ok`/`bad` is a lint; one that does both, or neither, is worse
    # than none. Both suites are non-sourcing on purpose — that is the half
    # the old population could not see at all.
    #
    # `test-fx-nonsrc-defs.sh` defines `ok`/`bad` and calls them (the shape 55
    # of the 70 own-`ok`/`bad` definers have at 741191c8). It also puts `ok`
    # into the WIDENED candidate universe, which is what makes the planted
    # call below a candidate at all.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'ok()  { printf "  PASS: %s\\n" "$1"; }' \
        'bad() { printf "  FAIL: %s\\n" "$1" >&2; }' \
        'ok "defines its own — legitimate"' \
        > "$_fx/monitor/watcher/test-fx-nonsrc-defs.sh"
    _fx_out=$(_fxlint); _fx_rc=$?
    assert_rc "#1364 NEGATIVE CONTROL: a non-sourcing suite that DEFINES its own ok/bad is clean (0)" "$_fx_rc" 0
    assert_not_contains "#1364 …and is not named as advisory either" "$_fx_out" "test-fx-nonsrc-defs.sh"
    # The plant: a NON-sourcing suite calling `ok` it never defined — #922's
    # exact shape outside the old population. ADVISORY by default: rc 0, the
    # site NAMED and COUNTED; `--strict` makes it the offence it is.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'ok "planted in a suite that sources nothing"' \
        > "$_fx/monitor/watcher/test-fx-nonsrc-planted.sh"
    _fx_out=$(_fxlint); _fx_rc=$?
    assert_rc "#1364 the widened lint SEES a bare ok in a NON-sourcing suite — advisory, rc 0" "$_fx_rc" 0
    assert_contains "#1364 …names the site under the ADVISORY heading" "$_fx_out" "test-fx-nonsrc-planted.sh"
    assert_contains "#1364 …and says which widened axis put it there" "$_fx_out" "widened population"
    assert_contains "#1364 …and the summary counts it (1 ADVISORY)" "$_fx_out" "1 ADVISORY call site(s)"
    assert_not_contains "#1364 …while the defining suite stays unnamed" "$_fx_out" "test-fx-nonsrc-defs.sh:"
    _fx_out=$( cd "$_fx" && git add -A >/dev/null 2>&1
               UHL_UNKNOWN_MANIFEST=monitor/watcher/uhl-unknown-callsites.manifest \
               bash monitor/watcher/undefined-helper-lint.sh --strict 2>&1 ); _fx_rc=$?
    assert_rc "#1364 POTENCY: under --strict the same plant is an OFFENCE (1)" "$_fx_rc" 1
    assert_contains "#1364 …named as such" "$_fx_out" "test-fx-nonsrc-planted.sh"
    assert_not_contains "#1364 …and the self-defining suite is STILL clean under --strict" "$_fx_out" "test-fx-nonsrc-defs.sh:"
    rm -f "$_fx/monitor/watcher/test-fx-nonsrc-planted.sh"
    # THE OTHER WIDENED AXIS: a SOURCING suite calling a name that only a
    # NON-sourcing suite defines. Before #1364 that name was not a candidate
    # at all (the universe was harvested from sourcing suites), so this was
    # invisible; now it is advisory, and the pre-#1364 strict verdict is
    # unchanged — asserted by (a) above, which still exits 1.
    printf '%s\n' \
        '. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"' \
        'ok "a sourcing suite reaching for a name only a non-sourcing suite defines"' \
        > "$_fx/monitor/watcher/test-fx-crossaxis.sh"
    _fx_out=$(_fxlint); _fx_rc=$?
    assert_rc "#1364 a sourcing suite calling a NON-sourcing suite's local name is ADVISORY, not an offence (0)" "$_fx_rc" 0
    assert_contains "#1364 …named with the widened-universe reason" "$_fx_out" "widened universe"
    rm -f "$_fx/monitor/watcher/test-fx-crossaxis.sh" "$_fx/monitor/watcher/test-fx-nonsrc-defs.sh"

else
    th_skip "#922 lint checks" "undefined-helper-lint.sh not present at $LINT"
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "=== #1038: an EMPTY needle must be REFUSED, not passed vacuously ==="
# ═══════════════════════════════════════════════════════════════════════════
#
# `grep -qF ""` matches EVERY line of any haystack — including an empty one,
# because the here-string supplies one empty line — so `assert_contains` with an
# empty needle passed VACUOUSLY. It did not assert a weaker thing; it asserted
# NOTHING, and reported the caller's failed probe as a success. Measured against
# the pre-fix helper, haystack deliberately carrying the WRONG value:
#
#     needle=[] len=0
#       PASS: line carries the client key      <- hay was AAAATOTALLYWRONGKEY
#       FAIL: control (a genuinely-absent key) <- the same helper, working
#
# WHY THIS BAND EXISTS AT ALL, AND WHY IT IS NOT OPTIONAL. `#1038` shipped four
# guards whose potency was demonstrated only in a scratch directory. A guard
# nothing in the repo can ever SEE FAIL is exactly the defect `#1038` is about,
# one level up: an assertion that cannot discriminate is indistinguishable from
# one that always passes. So the band below drives BOTH POLARITIES for every
# guard — the empty value is REFUSED, and the ordinary value still behaves.
#
# WHAT THIS BAND LOCALISES, MEASURED — AND WHAT IT DOES NOT. Mutation matrix on
# this tree (4 guard deletions + 2 `noreturn` slips, each proven to apply by
# md5 + `bash -n` + a guard-block census before any verdict was read):
#
#   assert_contains     delete   -> 6 band failures
#   assert_not_contains delete   -> 2
#   assert_no_file      delete   -> 1
#   th_tmux_wait_pane   delete   -> 1
#   assert_contains     noreturn -> 2
#   assert_no_file      noreturn -> 1
#
# READ THE LABELS, NOT THE COUNT. Six mutants produce only THREE distinct
# counts: `1` collides three ways and `2` collides two ways, and the `2` from
# `assert_contains/noreturn` is byte-identical in size to the `2` from
# `assert_not_contains/delete` — a different guard entirely. A count is not a
# fingerprint here.
#
# The LABEL SETS name the right guard for all six (verified: every failing label
# belongs to the mutated guard, none to another). But they are FIVE distinct
# sets for six mutants — `assert_no_file` delete and `noreturn` are
# indistinguishable, both yielding exactly the ledger assertion. So the honest
# claim is: this band localises WHICH GUARD broke, not WHICH WAY it broke. Do
# not read a failure count as a diagnosis, and do not assume the mode is
# recoverable from the output.
#
# EVIDENCE THAT DOES NOT ROUTE THROUGH THE THING UNDER TEST. This band probes
# `assert_contains`, so asserting on it WITH `assert_contains` would be circular
# in the one direction that matters. It reuses `_922_ledger`, which reads a
# CHILD `bash -c`'s ledger FILE: `P` = the child counted a pass, `F` = a
# counted failure. That is the same reasoning the `#922` band above states, and
# it is load-bearing here for the same reason.

# ---- assert_contains: the filed defect -------------------------------------
# The haystack carries the WRONG value throughout, so a `P` can only mean the
# assertion matched something it should never have matched.
assert_eq "#1038 assert_contains: an EMPTY needle is REFUSED (ledger F)" \
    "$(_922_ledger 'assert_contains lbl "carries AAAATOTALLYWRONGKEY" ""')" "F"
assert_eq "#1038 …and an empty HAYSTACK with an empty needle is refused too" \
    "$(_922_ledger 'assert_contains lbl "" ""')" "F"

# BOTH POLARITIES. A guard that refuses everything would satisfy the line above
# and be useless; these two are what make the refusal DISCRIMINATING.
assert_eq "#1038 POLARITY: a PRESENT needle still PASSES (ledger P)" \
    "$(_922_ledger 'assert_contains lbl "carries AAAATOTALLYWRONGKEY" "AAAATOTALLYWRONGKEY"')" "P"
assert_eq "#1038 POLARITY: an ABSENT needle still FAILS (guard did not swallow it)" \
    "$(_922_ledger 'assert_contains lbl "carries AAAATOTALLYWRONGKEY" "REALKEY-NOT-PRESENT"')" "F"

# THE BOUNDARY IS EXACTLY "EMPTY", NOT "BLANK" OR "FALSY". A single space and
# the string `0` are legitimate needles; refusing them would be a new defect.
assert_eq "#1038 BOUNDARY: a single-SPACE needle is not 'empty' — still passes" \
    "$(_922_ledger 'assert_contains lbl "a b c" " "')" "P"
assert_eq "#1038 BOUNDARY: the needle \`0\` is not 'empty' — still passes" \
    "$(_922_ledger 'assert_contains lbl "v=0" "0"')" "P"

# ---- assert_not_contains: the mirror, whose VERDICT must NOT have moved ----
# It already failed CLOSED on an empty needle before `#1038` — measured, not
# assumed — so `#1038` changed only its message. Pinning the verdict here is
# what stops a later "symmetry" cleanup from silently turning it into a pass.
assert_eq "#1038 MIRROR: an EMPTY needle still FAILS (verdict unchanged by #1038)" \
    "$(_922_ledger 'assert_not_contains lbl "carries AAAATOTALLYWRONGKEY" ""')" "F"
assert_eq "#1038 MIRROR POLARITY: an ABSENT needle still PASSES" \
    "$(_922_ledger 'assert_not_contains lbl "carries AAAATOTALLYWRONGKEY" "REALKEY-NOT-PRESENT"')" "P"

# ---- assert_no_file: the same class, opposite operator ----------------------
# `[[ ! -e "" ]]` is TRUE, so an empty path certified the absence of a file
# whose path it never learned. Note the asymmetry with its own mirror:
# `assert_file_exists` fails CLOSED on an empty path (`[[ -f "" ]]` is false),
# so only the NEGATIVE half was exposed — the inverse of the
# assert_contains/assert_not_contains pair, where the POSITIVE half was.
# Which half is fail-open is a property of the OPERATOR, not the polarity.
assert_eq "#1038 assert_no_file: an EMPTY path is REFUSED (ledger F)" \
    "$(_922_ledger 'assert_no_file lbl ""')" "F"
assert_eq "#1038 POLARITY: a genuinely absent path still PASSES" \
    "$(_922_ledger 'assert_no_file lbl "$WORK/definitely-not-here-1038"')" "P"
assert_eq "#1038 ASYMMETRY: assert_file_exists already failed closed on an empty path" \
    "$(_922_ledger 'assert_file_exists lbl ""')" "F"

# ---- th_tmux_wait_pane: a HAPPENS-BEFORE primitive -------------------------
# Worse in kind than the assertions above: an empty needle made it return 0 on
# the FIRST poll, so the caller was told tmux had already processed an earlier
# escape sequence when tmux may have processed nothing. It refuses IMMEDIATELY
# (rc 2) rather than falling through to the poll loop — a malformed call should
# not also cost the full timeout. NO TMUX IS INVOLVED: the "tmux command" is a
# stub script, so this runs anywhere and touches no server.
_1038_stub="$WORK/faketmux-1038"
printf '#!/usr/bin/env bash\necho "hello RDY world"\n' > "$_1038_stub"
chmod +x "$_1038_stub"
_1038_wait_rc() {   # $1 = needle -> rc of th_tmux_wait_pane with a 2s ceiling
    bash -c '. "'"$HELPER"'" >/dev/null 2>&1
             th_tmux_wait_pane "'"$_1038_stub"'" -- pane0 "'"$1"'" 2 >/dev/null 2>&1
             echo $?' 2>/dev/null
}
assert_eq "#1038 th_tmux_wait_pane: an EMPTY needle is REFUSED (rc 2, not 0)" \
    "$(_1038_wait_rc '')" "2"
assert_eq "#1038 POLARITY: a PRESENT sentinel still succeeds (rc 0)" \
    "$(_1038_wait_rc 'RDY')" "0"
assert_eq "#1038 POLARITY: an ABSENT sentinel still times out (rc 1, not 2)" \
    "$(_1038_wait_rc 'NOPE-ABSENT')" "1"

# ---- the diagnostic must point at the CALLER -------------------------------
# The haystack is a red herring for this defect: it is the EXPECTED value that
# came back empty, and a reader shown a haystack dump goes looking in the wrong
# place. Naming the producer is what turns this red into a five-minute fix.
_1038_msg=$(TMPDIR="$_922_child_tmp" bash -c '. "'"$HELPER"'" >/dev/null 2>&1; assert_contains lbl "hay" "" 2>&1')
assert_contains "#1038 the refusal says the needle was EMPTY" "$_1038_msg" "EMPTY needle"
assert_contains "#1038 …and sends the reader to the CALLER, not the haystack" "$_1038_msg" "Fix the CALLER"
assert_contains "#1038 …and says the pass would have been VACUOUS" "$_1038_msg" "VACUOUS"
assert_contains "#1038 …and cites the issue" "$_1038_msg" "1038"

# ---- the MIRROR's diagnostic is its guard's ONLY observable effect ---------
# Its VERDICT was already F before #1038, so the pin above cannot see the
# guard DELETED — only the guard INVERTED. Deletion is the realistic mutation
# ("this block is redundant, it already fails"), and it is invisible to every
# other assertion in this band. Measured: with the assert_not_contains guard
# removed, the whole suite stayed 66/0 green. The message is the discriminator.
_1038_msg_nc=$(TMPDIR="$_922_child_tmp" bash -c '. "'"$HELPER"'" >/dev/null 2>&1; assert_not_contains lbl "hay" "" 2>&1')
assert_contains "#1038 MIRROR: its refusal names the EMPTY needle (deletion is otherwise invisible)" \
    "$_1038_msg_nc" "EMPTY needle"
assert_contains "#1038 MIRROR: …and sends the reader to the CALLER, not the haystack" \
    "$_1038_msg_nc" "Fix the CALLER"

# ── EXPECTED-COUNT GUARD ────────────────────────────────────────────────────
#
# EXACT, not a floor. A missing assert_* exits 127 counted by nothing — which is
# THIS FILE'S OWN SUBJECT, so a guard here is not optional. A floor only catches
# a wholesale collapse; an exact count catches the single assertion that quietly
# stopped running, which is the failure mode `#922` is about. It also forces a
# deliberate update when an assertion is added, rather than letting the number
# drift upward unnoticed.
#
# The count is deterministic: the only `th_skip` is guarded on a file that this
# same commit adds, so it never fires in a healthy tree. If it ever does, this
# guard fires too and says so — which is correct, because a silently-skipped
# block is exactly what must not pass unremarked.
#
# WHAT THIS NUMBER ACTUALLY PINS (your-org/nexus-code#1038 round-2 skeptic).
# Not "the band might grow" — growth bumps the count in the very commit that
# causes it, which is the feature, not the hazard. What it pins is
# ENVIRONMENT-DEPENDENCE: this suite's population is not fixed by its own source
# alone, because the `#922` static half is gated on `undefined-helper-lint.sh`
# being PRESENT. Hide that file and a block of checks silently stops running.
#
# RE-MEASURE THE ENDPOINTS; DO NOT COPY THEM. They have moved twice already —
# `66 -> 53` (delta 13) on the pre-mirror band, `68 -> 55` (delta 13) after it,
# and the DELTA ITSELF moved when `#1030` added 17 assertions INSIDE the
# lint-gated block. The measured value for THIS tree is recorded beside
# EXPECTED below. The invariant is the SHAPE — hiding the lint must make this
# guard FIRE — not any particular pair of numbers.
#
# COMPOSITION, so the next rebase can redo this arithmetic instead of guessing:
#   48  the pre-#1030 baseline
#  +17  your-org/nexus-code#1030 (F1 heredoc arm, both strip-refusal arms, F2 ratchet)
#  +20  your-org/nexus-code#1038 (18 band + 2 mirror-diagnostic)
#   +1  your-org/nexus-code#1262 (the #921 pipe CONTROL, which establishes the
#       environment's own manifestation of a broken pipe before the probe is
#       compared against it)
#   +5  your-org/nexus-code#922 non-sourcing band (2 ungated controls + 3 arms
#       that are th_skip until the class is closed — a SKIP counts toward this
#       total exactly like a PASS, which is what stops the skip hiding here)
#  +14  your-org/nexus-code#1364 (2 real-corpus summary assertions, 12
#       fixture-corpus controls for the widened population; the third
#       non-sourcing arm flipped from th_skip to a live assert_eq, which is
#       count-neutral by design)
#  ---
#  105
# A textual merge that keeps "both hunks" picks 65 or 68 and is wrong either
# way: this number is a SUM of two independent extensions to one suite, so it
# has to be re-derived, never resolved.
#
# So when this number changes, the question is never "did the band grow?" — the
# diff answers that. It is "did some check stop RUNNING?".
EXPECTED=105
if (( PASS + FAIL + SKIP != EXPECTED )); then
    printf 'FAIL: recorded %d outcomes, expected exactly %d.\n' \
        "$(( PASS + FAIL + SKIP ))" "$EXPECTED" >&2
    printf '      A mismatch means checks were SKIPPED or ADDED without updating\n' >&2
    printf '      this guard — not that the ones that ran passed.\n' >&2
    _th_fail
fi

th_summary_and_exit
