#!/usr/bin/env bash
# test-fs-evidence-df-status.sh — the filesystem-evidence probe must report
# `unknown` when it could not ASK, not a blank that reads as an answer.
#
# Run: bash monitor/watcher/test-fs-evidence-df-status.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHY THIS SUITE EXISTS (your-org/nexus-code#1056; class: #928).
#
# `_nexus_fs_evidence` is the probe whose whole job is to prove a write failure
# is NOT a storage outage. It read `df`'s capacity through
#
#     if dfline=$(df -Ph "$path" 2>/dev/null | tail -1); then
#
# — which tests **`tail`'s** status, never `df`'s. `tail` essentially always
# succeeds, so on a failing `df` the SUCCESS arm ran with an empty `dfline` and
# printed `fs_source=` / `fs_avail=` (blank). A reader cannot tell that from a
# filer that answered. The honest `unknown` arm was unreachable.
#
# THE DEPENDENCY IS THE DEFECT, not the reachability. `_lib.sh`'s own header
# requires it to be safe to source from a shell that has already configured its
# options, so a site whose CORRECTNESS depends on the sourcer having enabled
# pipefail violates that contract even while every current sourcer happens to
# enable it. Measured at `7c073a3`: `monitor/watcher/_lib.sh` has 21 true
# sourcers and 0 of them lack `pipefail`, so the swallow was LATENT rather than
# live — and the first sourcer that omits it would have reintroduced a silent
# blank with nothing to notice. This suite pins the option-independence, which
# is the property the fix actually buys.
#
# WHAT IS PINNED. Not "df works". That the probe's answer is the SAME under
# both option regimes, and that each of the three outcomes is distinguishable:
#
#   real numbers   when `df` answers
#   unknown        when `df` FAILS
#   unknown        when `df` succeeds but emits NOTHING
#
# CONTROLS, because "the assertions ran" proves nothing:
#   A — POSITIVE CONTROL. A working `df` must yield a NON-`unknown` source. A
#       fix that hard-wired `unknown` would satisfy every negative assertion
#       below; without A this suite would bless it.
#   B — NON-VACUITY. The stub `df` must be OBSERVED to have been called. If a
#       refactor stopped calling `df` at all, every `unknown` assertion would
#       still pass — for the wrong reason, which is this repo's dominant defect
#       class rebuilt inside its own regression test.
#   C — BOTH REGIMES are exercised explicitly. Running only under the suite's
#       own `pipefail` would have passed against the UNFIXED code, since
#       pipefail is exactly what made the old form's `else` arm reachable.
#
# NOT COVERED, declared rather than implied: the `mount_*` / `rw_bind` fields,
# which come from `/proc/self/mountinfo` and are a different evidence source;
# and a `df` that is SLOW rather than failing (a hung filer), which is a
# timeout question no in-process fixture can witness.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LIB="$REPO_ROOT/monitor/watcher/_lib.sh"

# --population (your-org/nexus-code#803 protocol). Two files: the library whose
# behaviour every assertion below is about, plus this suite's own source, which
# `gp_handle` adds. Small, and that is the point — an edit to `_lib.sh` is
# EXACTLY what can change this suite's verdict, so `guards-for-diff` should
# select it for one. Same shape as the two `run-tests.sh` rows in
# guard-populations.manifest.
#
# Declared rather than skipped as "not worth it": adding a test suite without a
# population grows the tracked-suite DENOMINATOR the index reports its blind
# spot against, so an unenrolled new suite makes that blind spot marginally
# worse — which is the defect `#1078` is about, paid forward.
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$LIB"; }
gp_handle "$@"

WORK=$(mktemp -d -t nexus-fsev-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# One driver, parameterised on (option regime, df behaviour). Run as a child
# `bash` so the regime is a property of THAT shell — setting and unsetting
# pipefail in this suite's own shell would leak option state into everything
# below, which watcher/test-ambient-shell-option-scope.sh exists to forbid.
drive() {   # <regime: pipefail|nopipefail> <df: ok|fail|silent>  -> prints evidence
    local regime="$1" dfmode="$2"
    cat > "$WORK/drive.sh" <<DRIVER
#!/usr/bin/env bash
[[ "$regime" == pipefail ]] && set -o pipefail
. "$LIB"
df() {
    printf 'called\n' >> "$WORK/df-calls"
    case "$dfmode" in
        ok)     command df "\$@" ;;
        fail)   return 1 ;;
        silent) return 0 ;;
    esac
}
_nexus_fs_evidence "$WORK" "" 2>/dev/null
DRIVER
    : > "$WORK/df-calls"
    bash "$WORK/drive.sh"
}

# No `| head -1` here, deliberately. This file sets `pipefail`, so a `| head`
# would be an early-exit reader site and would owe a row in
# early-exit-readers.manifest — for a convenience the loop gives for free.
field() {   # <evidence> <key>
    local _l
    while IFS= read -r _l; do
        case "$_l" in "$2="*) printf '%s\n' "${_l#*=}"; return 0 ;; esac
    done <<<"$1"
    return 0
}

# ---------------------------------------------------------------- A: positive
for regime in nopipefail pipefail; do
    ev=$(drive "$regime" ok)
    src=$(field "$ev" fs_source)
    if [[ -n "$src" && "$src" != unknown ]]; then
        printf '  PASS: [A/%s] working df yields a real fs_source (%s)\n' "$regime" "$src"; _th_pass
    else
        printf '  FAIL: [A/%s] working df yielded %q — positive control dead\n' "$regime" "$src" >&2; _th_fail
    fi
    assert_eq "[A/$regime] working df yields a non-unknown fs_avail" \
        "$( [[ -n "$(field "$ev" fs_avail)" && "$(field "$ev" fs_avail)" != unknown ]] && echo yes || echo no )" yes
done

# ------------------------------------------------ B: the defect — failing df
# This is the assertion that was FALSE before the fix, and false only in the
# nopipefail regime. Both are asserted so the option-independence is the claim.
for regime in nopipefail pipefail; do
    ev=$(drive "$regime" fail)
    assert_eq "[B/$regime] failing df yields fs_source=unknown"  "$(field "$ev" fs_source)" unknown
    assert_eq "[B/$regime] failing df yields fs_avail=unknown"   "$(field "$ev" fs_avail)"  unknown
    # NON-VACUITY: the stub must actually have been reached.
    assert_eq "[B/$regime] non-vacuity: stub df was called" \
        "$( [[ -s "$WORK/df-calls" ]] && echo called || echo NEVER-CALLED )" called
done

# ------------------------------ D: df succeeds but emits nothing (empty arm)
for regime in nopipefail pipefail; do
    ev=$(drive "$regime" silent)
    assert_eq "[D/$regime] silent df yields fs_source=unknown" "$(field "$ev" fs_source)" unknown
    assert_eq "[D/$regime] silent df yields fs_avail=unknown"  "$(field "$ev" fs_avail)"  unknown
done

# ------------------------------------------- C: the two regimes AGREE (fail)
a=$(drive nopipefail fail); b=$(drive pipefail fail)
assert_eq "[C] failing-df answer is identical under both option regimes" \
    "$(field "$a" fs_source)/$(field "$a" fs_avail)" \
    "$(field "$b" fs_source)/$(field "$b" fs_avail)"

# ---- assertion-count guard ------------------------------------------------
# `th_summary_and_exit` reports the assertions that RAN. One that never ran is
# invisible to it: an undefined `assert_*` is `command not found`, rc 127,
# tallied nowhere, and the footer still says ALL TESTS PASSED with a quieter
# number. Every case above is unconditional on the green path — two fixed
# regimes crossed with three fixed `df` behaviours — so the count is exact.
# Bump it deliberately when adding a case; a DROP means a case stopped running.
# Counted BEFORE this assertion, so the literal excludes it.
_EXPECTED_ASSERTIONS=15
_ran=$(( PASS + FAIL ))
assert_eq "every declared assertion executed ($_EXPECTED_ASSERTIONS)" \
    "$_ran" "$_EXPECTED_ASSERTIONS"

th_summary_and_exit
