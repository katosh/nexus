#!/usr/bin/env bash
# your-org/nexus-code#1195 — AN AGENT HAS TWO NAMES, AND THE RESUMPTION
# SURFACE KEYED ON THE WRONG ONE.
#
# A report's FILENAME carries a cwd-derived PROJECT SLUG: `_report_project_slug`
# takes the first segment after the last `/work/` in `$PWD`, and falls back to
# `$NEXUS_WORKER_WINDOW` only when `report-init` ran OUTSIDE a `work/` tree. The
# frontmatter `window:` field is resolved from LIVE TMUX. They are never
# reconciled, and on the live corpus they disagree for 136 of 709 reports, with
# 21 windows indexed under two or more slugs.
#
# Two production sites looked reports up by FILENAME — `bootstrap-recover.sh`'s
# cold-boot dropped-worker manifest and the watcher's fresh-orchestrator
# situation report. Both are the RESUMPTION surface, and both printed "none
# found" about workers that had filed a report. It errs the other way too: for
# one live window the name match returns 6 where the frontmatter says 3.
#
# The three answers must stay apart: FOUND, LOOKED-AND-FOUND-NONE, and COULD
# NOT LOOK. Collapsing the last two is the whole of #813 (and #618/#707/#770
# before it).
#
# Run: bash monitor/watcher/test-report-window-key.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

STATE_DIR=$(mktemp -d); export STATE_DIR
trap 'rm -rf "$STATE_DIR"' EXIT

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

NG="$_test_dir/../ng"
[[ -x "$NG" ]] || th_abort "monitor/ng not executable at $NG"

# CONTAIN `ng`'s PROCESS-LEVEL STATE DIR (your-org/nexus-code#1306). The
# per-call pins below reach the LEDGER; `ng` resolves `STATE_DIR` once at
# startup and its usage tap fires before dispatch, so any call site that does
# not ALSO pin the environment appends to the inherited `$NEXUS_ROOT` — the
# operator's canonical state in an agent shell. Measured LEAK at `0b82ffb2`.
# Pinned to a DEDICATED SINK rather than to this fixture's asserted state dir,
# so containing the telemetry cannot perturb anything this suite counts.
_NG_SINK="$STATE_DIR/.ng-telemetry"
th_pin_ng_state "$NG" "$_NG_SINK"

# ── FIXTURE CORPUS ─────────────────────────────────────────────────────────
# A  slug == window            (the agreeing majority)
# B  slug != window            (THE ARM SPLIT — what a filename glob misses)
# C  unrelated
# D  window: thing2            (anti-over-match: a filename glob for `thing`
#                               would sweep this in; the frontmatter must not)
R="$STATE_DIR/reports"; mkdir -p "$R"
_mk() { printf -- '---\nproject: %s\ndate: 2026-09-01\nwindow: %s\nstatus: completed\n---\n\n# r\n' "$2" "$3" > "$R/$1"; }
_mk 'thing_2026-09-01_100000_a.md'      thing       thing
_mk 'nc-thing_2026-09-01_100100_b.md'   nc-thing    thing
_mk 'other_2026-09-01_100200_c.md'      other       other
_mk 'thing_2026-09-01_100300_d.md'      thing       thing2

_rfw() { "$NG" reports-for-window "$1" --reports-dir "$R" 2>/dev/null; }

echo "=== 1. the verb keys on the frontmatter, not the filename ==="
_out=$(_rfw thing); _rc=$?
# POSITIVE CONTROL FIRST: the verb found SOMETHING. Every "does not contain"
# below is a false pass on an empty answer.
assert_eq "the scan FOUND reports for \`thing\` (rc 0)" "$_rc" "0"
assert_eq "…exactly the two whose FRONTMATTER says \`thing\`" \
    "$(printf '%s\n' "$_out" | grep -c .)" "2"
# THE ARM SPLIT — the file a filename glob cannot see.
assert_contains "…including the one whose SLUG differs from its window" "$_out" "nc-thing_2026-09-01_100100_b.md"
assert_contains "…and the agreeing one" "$_out" "thing_2026-09-01_100000_a.md"
# ANTI-OVER-MATCH: `ls reports/ | grep thing` would return three.
assert_not_contains "…and NOT \`thing2\`, which a substring glob would sweep in" "$_out" "_d.md"
# The measured contrast, so the point is asserted and not merely narrated.
assert_eq "CONTRAST: a FILENAME glob returns a different set entirely" \
    "$(ls -1 "$R" | grep -c 'thing')" "3"

echo "=== 2. the three answers stay apart ==="
_rfw nosuchwindow >/dev/null 2>&1
assert_eq "a window nobody claims is rc 1 — LOOKED and found none" "$?" "1"
"$NG" reports-for-window thing --reports-dir "$STATE_DIR/nonexistent" >/dev/null 2>&1
assert_eq "an unenumerable corpus is rc 2 — COULD NOT LOOK, never folded into 1" "$?" "2"
assert_eq "…and rc 2 prints NOTHING on stdout, so no caller can read it as a result" \
    "$("$NG" reports-for-window thing --reports-dir "$STATE_DIR/nonexistent" 2>/dev/null | wc -c | tr -d ' ')" "0"

echo "=== 3. the two production sites no longer key on the filename ==="
# Asserted on the SOURCE because both sites are inside long cold-boot/watcher
# paths whose full drive needs a tmux fixture; the property here is which KEY
# they use, and that is decidable from the call. Paired with arm 1, which
# proves the key they now use is the correct one.
for _f in ../bootstrap-recover.sh spawn-fresh-orchestrator.sh; do
    _p="$_test_dir/$_f"
    [[ -r "$_p" ]] || { assert_eq "FIXTURE: $_f is readable" "missing" "present"; continue; }
    # COMMENT LINES ARE EXCLUDED. Both sites now carry a comment QUOTING the
    # old form, so a bare text search matches the explanation of the fix and
    # reddens on the fixed tree — a guard keyed on SHAPE rather than on the
    # property. Measured while writing this: 1 hit on each, all comment.
    assert_eq "$(basename "$_f"): no CODE line looks a report up by filename glob" \
        "$(grep -vE '^[[:space:]]*#' "$_p" | grep -cE -- '-name "\*\$\{?(window|w)\}?\*\.md"' || true)" "0"
    assert_eq "$(basename "$_f"): …it asks \`ng reports-for-window\` in CODE instead" \
        "$(grep -vE '^[[:space:]]*#' "$_p" | grep -c 'reports-for-window' || true)" "1"
    assert_eq "$(basename "$_f"): …and has a COULD NOT LOOK arm the operator can read" \
        "$( (( $(grep -vE '^[[:space:]]*#' "$_p" | grep -ci 'COULD NOT LOOK' || true) >= 1 )) && echo yes || echo NO)" "yes"
done

echo "=== 4. the docs no longer teach the wrong key ==="
for _d in nexus.tmux-spawn nexus.report; do
    _dp="$_test_dir/../../skills/$_d/SKILL.md"
    [[ -r "$_dp" ]] || { assert_eq "FIXTURE: $_d/SKILL.md is readable" "missing" "present"; continue; }
    assert_eq "$_d: points at \`ng reports-for-window\`" \
        "$( grep -q 'reports-for-window' "$_dp" && echo yes || echo NO)" "yes"
    assert_eq "$_d: …and says the slug is cwd-derived, not the window name" \
        "$( grep -qi 'cwd-derived' "$_dp" && echo yes || echo NO)" "yes"
done

_EXPECTED_ASSERTIONS=19
_ran=$(( PASS + FAIL ))
if (( _ran == _EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$_EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$_EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
