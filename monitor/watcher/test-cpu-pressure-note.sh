#!/usr/bin/env bash
# test-cpu-pressure-note.sh — the CPU-pressure term the failure sampler grew
# for your-org/nexus-code#720.
#
# WHAT #720 NEEDED, AND WHY THE EXISTING FIELDS COULD NOT SUPPLY IT.
# `#655` root-caused the intermittency to per-UID RLIMIT_NPROC headroom and
# `#718` put `fork-headroom` beside every failure, so a fork-starved run is now
# attributable. The CI-side occurrence that has since been sampled reads
# `fork-headroom=2037 of 2109` — 96.6% free. That is a NEGATIVE: it excludes
# fork exhaustion and attributes nothing, and a healthy headroom printed beside
# a failing suite reads as "resources were fine".
#
# The remaining suspect is CPU starvation, and the sampler's only CPU-ish field
# was loadavg, which cannot do it for `#720`'s workstation-vs-runner
# comparison: it is UN-NORMALIZED. Measured — 44.21 on 36 cores is 1.23x
# oversubscription; the runner's 5.19 on 2 vCPU is 2.60x. The runner was under
# more than twice the relative pressure while printing an 8x smaller number.
# Compared as printed, the field reads backwards.
#
# PSI (`/proc/pressure/cpu`) measures the property itself — percentage of the
# last 10 s in which some runnable task was stalled on the runqueue. Already a
# rate, already normalized, 10-second window rather than a 1-minute EWMA, and
# it does not count D-state tasks the way loadavg does.
#
# THE DUPLICATION THIS FILE POLICES. `run-tests.sh` sources NOTHING by design,
# so it cannot call `th_cpu_pressure`; a call would be `command not found`,
# `stall` would degrade to `unknown` on every run, and the field would read as
# "no PSI on this host" forever — a diagnostic that cannot fire, dressed as one
# that found nothing. The parse is therefore inlined there and duplicated here,
# and section B runs BOTH implementations against identical fixtures so the
# duplication cannot drift silently.
#
# Run: bash monitor/watcher/test-cpu-pressure-note.sh
# Expected: ALL TESTS PASSED, exit 0. Hermetic — reads /proc, writes nothing.

set -uo pipefail

# shellcheck source=monitor/watcher/_test_helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"

PASS=0; FAIL=0; SKIP=0

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNNER="$_dir/run-tests.sh"

# The runner's inlined parse, extracted VERBATIM between its markers. Running
# the shipped bytes rather than a restatement of them is the whole point: a
# hand-copied duplicate here would drift in exactly the way this file claims to
# prevent.
_psi_parse_src=$(sed -n '/# BEGIN psi-parse/,/# END psi-parse/p' "$RUNNER")

# _runner_parse <fixture-line> — evaluate the shipped block with `stall` preset.
_runner_parse() {
    local stall="$1"
    eval "$_psi_parse_src"
    printf '%s' "$stall"
}

echo '=== A. th_cpu_pressure against the live gauge ==='

_live=$(th_cpu_pressure)
if [[ -r /proc/pressure/cpu ]]; then
    if [[ "$_live" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf '  PASS: A1 live PSI reads as a number (got %s)\n' "$_live"; PASS=$((PASS+1))
    else
        printf '  FAIL: A1 PSI is readable here but th_cpu_pressure said %q\n' "$_live" >&2
        FAIL=$((FAIL+1))
    fi
else
    # Not a pass. PSI landed in 4.20; a kernel without it cannot exercise this.
    th_skip "A1 live PSI reading" \
            "/proc/pressure/cpu is not readable on this host (pre-4.20 kernel, or PSI disabled) — the live-gauge case did NOT run"
fi

# The gauge being unreadable must yield `unknown`, never an empty string that a
# later numeric test would silently coerce to 0 — "no reading" and "no
# pressure" are opposite conclusions.
assert_eq "A2 an unreadable gauge degrades to \`unknown\`" \
    "$(grep() { return 1; }; th_cpu_pressure)" "unknown"

assert_eq "A3 a malformed avg10 degrades to \`unknown\`, not to a partial parse" \
    "$(grep() { printf 'some avg10=n/a avg60=1.0\n'; }; th_cpu_pressure)" "unknown"

assert_eq "A4 a line with no avg10 field at all degrades to \`unknown\`" \
    "$(grep() { printf 'some total=12345\n'; }; th_cpu_pressure)" "unknown"

echo
echo '=== B. PARITY — the runner`s inlined parse and th_cpu_pressure agree ==='
# The anti-drift assertion. Both implementations, same fixtures, same answers.
# Asserted on FIXTURES rather than on two live reads: PSI moves between any two
# samples, so a live-vs-live comparison would be flaky for a reason that has
# nothing to do with the property under test.
assert_eq "B0 the runner's parse block was actually extracted" \
    "$([[ -n "$_psi_parse_src" ]] && printf yes || printf no)" "yes"

_fixtures=(
    'some avg10=29.06 avg60=30.66 avg300=29.63 total=384006288384'
    'some avg10=0.00 avg60=0.00 avg300=0.00 total=1'
    'some avg10=100.00 avg60=99.12 avg300=87.00 total=9'
    'some avg10=n/a avg60=1.0'
    'some total=12345'
    ''
)
_parity_mismatch=0
for _fx in "${_fixtures[@]}"; do
    _a=$(_runner_parse "$_fx")
    _b=$(grep() { [[ -n "$_fx" ]] && printf '%s\n' "$_fx" || return 1; }; th_cpu_pressure)
    [[ "$_a" == "$_b" ]] || {
        _parity_mismatch=$((_parity_mismatch+1))
        printf '        mismatch on %q: runner=%q helper=%q\n' "$_fx" "$_a" "$_b" >&2
    }
done
assert_eq "B1 both parses agree on all ${#_fixtures[@]} fixtures" "$_parity_mismatch" "0"

# Pin the extraction itself: if the markers vanish, B1 would compare an EMPTY
# program against the helper and could pass vacuously.
assert_eq "B2 the extracted block is non-vacuous (parses a known value)" \
    "$(_runner_parse 'some avg10=29.06 avg60=30.66 avg300=29.63 total=1')" "29.06"

echo
echo '=== C. the sampler emits the new fields ==='
# Section A of `_rt_resource_note`'s header states the boundary these live
# under: sampled AFTER exit, so they are the neighbourhood of a failure, not
# the instant of it. This section only pins that they are PRESENT and shaped
# right — the runner is exercised end-to-end by test-assertion-accounting.sh.
_note_src=$(sed -n '/^_rt_resource_note() {/,/^}/p' "$RUNNER")
assert_eq "C0 the sampler function was extracted" \
    "$([[ -n "$_note_src" ]] && printf yes || printf no)" "yes"

_out=$(eval "$_note_src"; _rt_resource_note "$(mktemp -u)")
assert_contains "C1 the sampler prints a cpus= denominator"      "$_out" "cpus="
assert_contains "C2 the sampler prints cpu-stall%"               "$_out" "cpu-stall%="
assert_contains "C3 fork-headroom is still printed (no regression)" "$_out" "fork-headroom="
assert_contains "C4 loadavg is still printed (no regression)"    "$_out" "loadavg="

# The escalation note is a CONDITIONAL, so assert both directions rather than
# whichever one this host happens to produce. `#655`'s regime (low headroom)
# must NOT be relabelled as `#720`'s — that would be the new instrument
# stealing attribution from the one that is already correct.
#
# THESE DRIVE THE SHIPPED BYTES, extracted between markers, and that is a
# CORRECTION rather than a precaution. C5-C8 originally RESTATED the
# conditional inline. The `#795` skeptic moved the shipped threshold `20` → `90`
# in `run-tests.sh` and this suite stayed **16/0 green** — the assertions that
# claim to pin `#720`'s discrimination rule were pinning a hand-copy of it.
# Partial extraction is worse than none: this file's header advertises the
# anti-drift discipline, so the visible rigor on the parse vouched for the one
# conditional that lacked it.
_esc_src=$(sed -n '/# BEGIN psi-escalate/,/# END psi-escalate/p' "$RUNNER")
assert_eq "C5a the shipped escalation conditional was extracted" \
    "$([[ -n "$_esc_src" ]] && printf yes || printf no)" "yes"

# _fires <stall> <headroom> [cpus] — run the SHIPPED conditional and report
# whether it emitted the note.
_fires() {
    local stall="$1" headroom="$2" cpus="${3:-36}" out
    out=$(eval "$_esc_src")
    [[ "$out" == *"CPU-STALL neighbourhood"* ]] && printf 'fires' || printf ''
}

assert_eq "C5 high stall + healthy headroom fires the #720 note" \
    "$(_fires 45.0 6000)" "fires"
assert_eq "C6 high stall + STARVED headroom stays #655's, not #720's" \
    "$(_fires 45.0 40)" ""
assert_eq "C7 a calm box fires nothing" \
    "$(_fires 1.2 6000)" ""
assert_eq "C8 an unreadable gauge fires nothing (no reading != no pressure)" \
    "$(_fires unknown 6000)" ""
# C9 pins the THRESHOLD itself, which is what silently drifted. 19 vs 20 is the
# boundary; a suite that only tested 45 and 1.2 passes a threshold moved to 90.
assert_eq "C9 the threshold is 20: stall=19 does NOT fire" \
    "$(_fires 19.0 6000)" ""
assert_eq "C9b the threshold is 20: stall=20 DOES fire" \
    "$(_fires 20.0 6000)" "fires"

th_summary_and_exit
