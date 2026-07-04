#!/usr/bin/env bash
# test-recovery-verb-mutation.sh — mutation test proving the recovery-verb
# mapping in monitor/hooks/_cause_classify.sh is LOAD-BEARING.
#
# A passing test suite is only meaningful if its assertions would FAIL when
# the code is wrong. The stall-detection chain hinges on one mapping: a
# `transient` (server 5xx) crash must recover via **paste** (the same turn
# succeeds on resume), while a `config`/`conversation` crash must recover via
# **respawn** (a paste just re-runs the doomed turn). The wrong verb
# mis-handles every interrupted worker.
#
# This test mutates that mapping (flip transient -> respawn) on a COPY of the
# classifier and proves:
#   1. the REAL classifier maps server_error -> transient/paste,
#   2. the MUTANT maps server_error -> transient/RESPAWN,
#   3. an assertion that expects `paste` (as the unit + e2e suites do) GOES
#      RED against the mutant — i.e. the suite would catch this regression.
#
# Pure + fast: no `claude`, no tmux, no network. Always runs in CI.
#
# Run: bash monitor/watcher/test-recovery-verb-mutation.sh

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/_test_helpers.sh"
_repo_root=$(cd "$_self_dir/../.." && pwd)
CLASSIFY="$_repo_root/monitor/hooks/_cause_classify.sh"

PASS=0; FAIL=0
assert_file_exists "classifier source present" "$CLASSIFY"

# --- 1. baseline: the REAL classifier maps a transient crash to paste -------
real_verdict=$(
    # shellcheck source=/dev/null
    . "$CLASSIFY"
    cause_classify_error "server_error" "API Error: 529 Overloaded"
)
assert_eq "real: server_error -> transient/paste" "transient	paste" "$real_verdict"

# --- 2. mutate a COPY: transient -> respawn ---------------------------------
mutant="$(mktemp)"
trap 'rm -f "$mutant"' EXIT
# Flip ONLY the transient recovery verb. The transient branch is the single
# line emitting `transient\tpaste`; rewrite its verb to respawn.
sed "s/printf 'transient\\\\tpaste'/printf 'transient\\\\trespawn'/" \
    "$CLASSIFY" > "$mutant"

# Guard: the mutation must have actually changed the file (catches a future
# refactor that renames the branch and would silently no-op the mutation,
# making this test vacuous).
if cmp -s "$CLASSIFY" "$mutant"; then
    echo "  FAIL: mutation was a no-op — the transient branch moved; update this test" >&2
    FAIL=$((FAIL+1))
    th_summary_and_exit
fi
echo "  PASS: mutation applied (transient verb rewritten paste -> respawn)"
PASS=$((PASS+1))

mutant_verdict=$(
    # shellcheck source=/dev/null
    . "$mutant"
    cause_classify_error "server_error" "API Error: 529 Overloaded"
)
assert_eq "mutant: server_error -> transient/RESPAWN" "transient	respawn" "$mutant_verdict"

# --- 3. the load-bearing proof: a paste-expecting assertion goes RED ---------
# This is exactly the assertion the unit suite (test-cause-classify.sh) and
# the e2e (test-realmodel-apispoof.sh) make. Against the mutant it MUST fail —
# if it still passed, the verb would be vacuous and a real regression would
# slip through.
if [[ "$mutant_verdict" == "transient	paste" ]]; then
    echo "  FAIL: mutant still yields paste — the recovery verb is NOT load-bearing!" >&2
    FAIL=$((FAIL+1))
else
    echo "  PASS: flipping the verb changes the classifier output — the suite would catch it"
    PASS=$((PASS+1))
fi

# Sanity: the real classifier is unchanged by all of the above (we mutated a
# copy, never the source).
real_again=$(
    # shellcheck source=/dev/null
    . "$CLASSIFY"
    cause_classify_error "server_error" "API Error: 529 Overloaded"
)
assert_eq "source untouched by the mutation" "transient	paste" "$real_again"

th_summary_and_exit
