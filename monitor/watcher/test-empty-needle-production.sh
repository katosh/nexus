#!/usr/bin/env bash
# EMPTY-NEEDLE VACUITY IN **PRODUCTION** CODE (your-org/nexus-code#1093).
#
# `#1038` fixed the shared TEST helper; `#1092` fixed the 87 local test copies.
# This is the third half: the same `grep -qF ""` / `grep -qE ""` / `*""*`
# vacuity in code that is not a test, where a false pass costs something.
#
# ── WHAT IS FIXED HERE, AND HOW IT IS PROVED ────────────────────────────
#
# Every verdict below is either MEASURED — a probe actually run against a
# planted empty value — or GUARD-NAMED: a specific line, quoted, that makes
# emptiness unreachable. Nothing is settled by reading and concluding.
#
#   monitor/public-mirror/build.sh   `$start`   REACHABLE   -> guarded, tested A
#   monitor/watcher/entry.sh         `$TARGET`  REACHABLE   -> guarded, tested B
#   monitor/nexus-root-sensitivity.sh `$needle` REACHABLE   -> guarded, tested C
#
# ── THE THREE THIS DELIBERATELY DOES **NOT** FIX ────────────────────────
#
# Recorded as boundaries with the line that makes each impossible (section D),
# because an unfixed site that is merely unmentioned is indistinguishable from
# one nobody looked at — and because fixing an unreachable site inflates a diff
# with changes no evidence supports.
#
#   build.sh `$end`  — `#1093` proposed guarding this "the same as $start".
#                      That is WRONG in both directions. Its drift grep already
#                      sits behind `if [ -n "$end" ]`, so an empty needle never
#                      reaches it; and an empty `end` is a LEGITIMATE manifest
#                      mode (`if (end == "") { state=3 }` — delete START-to-EOF),
#                      so a row-level non-empty check would BREAK a feature to
#                      close a hole that is not open.
#   cc-auto-update-apply.sh `$candidate` — `_check_gate_evidence` really is
#                      defeated by an empty candidate in isolation, which is
#                      alarming for a gate that authorises a version bump. Its
#                      SOLE caller is preceded by `[[ -n "$candidate" ]] ||
#                      exit 2`. Weak, not exposed. The alarming half is the
#                      memorable half, so the other half is pinned here.
#   _test_helpers.sh `$root` — `th_kill_fixture_pid`'s `*"$root"*` test is
#                      preceded by `[[ … && -n "$root" ]] || return 1`.
#
#   slow-band-drift.sh `$needle` — every one of its 9 call sites passes a
#                      STRING LITERAL, so emptiness is unreachable from data.
#                      Not pinned structurally: "no caller passes a variable"
#                      is a property of call sites, which a future edit changes
#                      silently, and this suite would then assert something it
#                      had stopped checking. Named here, deliberately unguarded.
#
# ── WHY build.sh IS NEVER RUN BY THIS SUITE ─────────────────────────────
#
# `monitor/public-mirror/build.sh` DESTROYS whatever checkout it is invoked
# from — no dry run, no confirmation, and it deletes the dictionary that would
# say what it did (`#1001`, open). So `apply_overlay_block` is EXTRACTED and
# run against a fixture. The extraction is asserted non-empty and asserted to
# contain the guard, so a rename cannot turn this suite into a silent no-op.
#
# Run: bash monitor/watcher/test-empty-needle-production.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)

BUILD="$REPO_ROOT/monitor/public-mirror/build.sh"
ENTRY="$REPO_ROOT/monitor/watcher/entry.sh"
NRS="$REPO_ROOT/monitor/nexus-root-sensitivity.sh"
CCA="$REPO_ROOT/monitor/cc-auto-update-apply.sh"
HELPERS="$_test_dir/_test_helpers.sh"

. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$BUILD" "$ENTRY" "$NRS" "$CCA" "$HELPERS"; }
gp_handle "$@"

for _f in "$BUILD" "$ENTRY" "$NRS" "$CCA"; do
    [ -r "$_f" ] || { echo "missing: $_f" >&2; exit 2; }
done

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ═══════════════════════════════════════════════════════════════════════
echo '=== A: public-mirror/build.sh refuses an EMPTY overlay START anchor ==='
# ═══════════════════════════════════════════════════════════════════════
# `apply_overlay_block` is extracted, never invoked through build.sh (#1001).
AOB=$(sed -n '/^apply_overlay_block() {/,/^}/p' "$BUILD")
assert_contains "A0: apply_overlay_block extracted from build.sh"  "$AOB" "apply_overlay_block() {"
assert_contains "A0: …and the extraction reaches its END-anchor tail" "$AOB" "block over-ran"

# The guarded run: a truncated manifest row leaves $start empty.
_aob() {   # _aob <definition> <target> <start> <end> <repl>  -> "<rc>|<stderr>"
    local def="$1"; shift
    local out rc
    out=$(bash --noprofile --norc -c '
        def="$1"; shift
        OVERLAY_DIR="$1"; shift
        eval "$def"
        apply_overlay_block "$@"
    ' _ "$def" "$WORK/overlay" "$@" 2>&1); rc=$?
    printf '%s|%s' "$rc" "$out"
}
mkdir -p "$WORK/overlay"
_mktarget() { printf 'line one\nANCHOR-START\nmiddle\nANCHOR-END\nline five\n' > "$1"; }

_mktarget "$WORK/t1.txt"
r=$(_aob "$AOB" "$WORK/t1.txt" "" "" "-")
assert_eq       "A1: empty START anchor -> exit 4"            "${r%%|*}" "4"
assert_contains "A1: …and the refusal NAMES the empty anchor" "${r#*|}"  "EMPTY START anchor"
assert_eq       "A1: …and the target file is UNTOUCHED"       "$(wc -l < "$WORK/t1.txt" | tr -d ' ')" "5"

# The normal path is unaffected — a guard that also breaks the working case is
# not a fix, and only the pair of assertions says which one this is.
_mktarget "$WORK/t2.txt"
printf 'REPLACED\n' > "$WORK/overlay/repl.md"
r=$(_aob "$AOB" "$WORK/t2.txt" "ANCHOR-START" "ANCHOR-END" "repl.md")
assert_eq       "A2: a well-formed overlay row still applies (exit 0)" "${r%%|*}" "0"
assert_eq       "A2: …and the block was replaced"                      "$(cat "$WORK/t2.txt")" \
                "$(printf 'line one\nREPLACED\nANCHOR-END\nline five')"

# A real drifted anchor must still be caught — the guard must not have replaced
# the drift check, only preceded it.
_mktarget "$WORK/t3.txt"
r=$(_aob "$AOB" "$WORK/t3.txt" "NO-SUCH-ANCHOR" "ANCHOR-END" "-")
assert_eq       "A3: a genuinely drifted START anchor still exits 4" "${r%%|*}" "4"
assert_contains "A3: …with the DRIFT message, not the empty one"     "${r#*|}"  "not found in"

# ── the mutant: DELETE the guard and show the destruction it prevents ───
# A verdict-based assertion here would see nothing (#1038's blocker): with the
# guard deleted the empty ERE matches, the drift check passes, and the function
# exits 0 — so `rc` is 0 in BOTH the fixed and the broken tree for the *drift*
# question. What separates them is what happens to the FILE.
AOB_MUT=$(printf '%s\n' "$AOB" | sed '/EMPTY START anchor -- refusing/,+2d; /^  \[ -n "\$start" \] || {$/,+3d')
assert_eq "A4: the mutant actually applied (guard text gone)" \
    "$(printf '%s\n' "$AOB_MUT" | grep -c 'EMPTY START anchor')" "0"
assert_eq "A4: …and the mutant is otherwise the same function" \
    "$(printf '%s\n' "$AOB_MUT" | grep -c 'apply_overlay_block() {')" "1"
_mktarget "$WORK/t4.txt"
r=$(_aob "$AOB_MUT" "$WORK/t4.txt" "" "" "repl.md")
assert_eq "A5: MUTANT: an empty START anchor is reported as FOUND (exit 0)" "${r%%|*}" "0"
assert_eq "A5: MUTANT: …and the target is TRUNCATED to the replacement alone" \
    "$(cat "$WORK/t4.txt")" "REPLACED"
# and the fixed function, same inputs, leaves the file whole — the A1/A5 pair
# is the whole claim.
_mktarget "$WORK/t5.txt"
r=$(_aob "$AOB" "$WORK/t5.txt" "" "" "repl.md")
assert_eq "A6: FIXED: same inputs, refused, file intact (5 lines)" \
    "${r%%|*}/$(wc -l < "$WORK/t5.txt" | tr -d ' ')" "4/5"

# ═══════════════════════════════════════════════════════════════════════
echo '=== B: watcher/entry.sh refuses an EMPTY monitor.target_window ==='
# ═══════════════════════════════════════════════════════════════════════
# entry.sh is the watcher's boot path and is never invoked here. The guard
# block is extracted by its own anchors and run against a stubbed `$_cfg`.
GUARD=$(sed -n '/^TARGET="\$("\$_cfg" monitor.target_window/,/^fi$/p' "$ENTRY")
assert_contains "B0: the TARGET guard block extracted from entry.sh" "$GUARD" '_target_rc=$?'
assert_contains "B0: …and it exits rather than guessing"             "$GUARD" 'exit 2'

_target_guard() {   # _target_guard <stub-rc> <stub-stdout> -> "<rc>|<stderr>"
    local out rc
    out=$(bash --noprofile --norc -c '
        guard="$1"; rc="$2"; val="$3"
        _cfgstub() { printf %s "$val"; return "$rc"; }
        _cfg=_cfgstub
        eval "$guard"
        printf "TARGET=[%s]\n" "$TARGET"
    ' _ "$GUARD" "$1" "$2" 2>&1); rc=$?
    printf '%s|%s' "$rc" "$out"
}
# Route 1 — `target_window: ""` in config/nexus.yml. load.sh returns rc 0 with
# empty stdout (measured), so an rc check ALONE would not have caught this.
r=$(_target_guard 0 "")
assert_eq       "B1: rc 0 with an EMPTY value is refused (exit 2)" "${r%%|*}" "2"
assert_contains "B1: …and the refusal names the resolved-empty value" "${r#*|}" "resolved EMPTY"
# Route 2 — no config found: rc 1, empty stdout, diagnostic on stderr.
r=$(_target_guard 1 "")
assert_eq       "B2: a FAILED config read is refused (exit 2)"     "${r%%|*}" "2"
assert_contains "B2: …and the refusal reports the rc it consulted" "${r#*|}" "rc=1"
# The working case is untouched.
r=$(_target_guard 0 "orchestrator")
assert_eq "B3: a normal config read still yields the window name" "$r" "0|TARGET=[orchestrator]"

# ── the defect the guard prevents, reproduced on this host ─────────────
# `-x` normally makes an empty needle fail CLOSED. The here-string is what
# manufactures the satisfying line, and this asymmetry is the whole mechanism.
_boot_probe() { bash --noprofile --norc -c 'grep -qxF "$1" <<<"$(printf %s "$2")" && echo present || echo absent' _ "$1" "$2"; }
assert_eq "B4: empty needle + empty window list -> PRESENT (the fail-OPEN)" \
    "$(_boot_probe "" "")" "present"
# The same EMPTY stdin delivered without a here-string does NOT match — the
# here-string is what manufactures the satisfying line, and that asymmetry is
# the entire mechanism. `#1038` writes the contrast as `printf "" | grep -qxF ""`;
# it is spelled with /dev/null here because test-sigpipe-assertion-lint.sh
# forbids a `… | grep -q` writer (the reader quits first and `pipefail` promotes
# its SIGPIPE), and /dev/null is the same empty stdin with no writer at all.
assert_eq "B4: …while the same EMPTY stdin with no here-string is fail-CLOSED" \
    "$(bash --noprofile --norc -c 'grep -qxF "" </dev/null && echo present || echo absent')" "absent"
assert_eq "B4: …and a non-empty window list rejects the empty needle" \
    "$(_boot_probe "" "orchestrator")" "absent"
assert_eq "B5: the real needle still detects a present orchestrator" \
    "$(_boot_probe "orchestrator" "$(printf 'services\norchestrator')")" "present"

# ═══════════════════════════════════════════════════════════════════════
echo '=== C: nexus-root-sensitivity.sh maps an empty window to NO producers ==='
# ═══════════════════════════════════════════════════════════════════════
GP=$(sed -n '/^_grep_producers() {/,/^}/p' "$NRS")
assert_contains "C0: _grep_producers extracted" "$GP" "_grep_producers() {"
mkdir -p "$WORK/nrs/monitor/watcher"
printf 'echo worker-alpha\n' > "$WORK/nrs/monitor/watcher/test-a.sh"
printf 'echo worker-beta\n'  > "$WORK/nrs/monitor/watcher/test-b.sh"
_gp() { bash --noprofile --norc -c '
        gp="$1"; NRS_SUITE_ROOT="$2"; REPO_ROOT="$2"
        eval "$gp"; _grep_producers "$3" | grep -c . ' _ "$GP" "$WORK/nrs" "$1"; }
assert_eq "C1: an EMPTY window name yields ZERO producers, not every file" "$(_gp '')" "0"
assert_eq "C2: a real window name still finds its one producer"            "$(_gp 'worker-alpha')" "1"
GP_MUT=$(printf '%s\n' "$GP" | sed '/^[[:space:]]*\[ -n "\$needle" \] ||/d')
assert_eq "C3: the mutant actually applied (guard line gone)" \
    "$(printf '%s\n' "$GP_MUT" | grep -c '\[ -n "\$needle" \]')" "0"
assert_eq "C3: MUTANT: an empty window name implicates EVERY file" "$(
    bash --noprofile --norc -c 'gp="$1"; NRS_SUITE_ROOT="$2"; REPO_ROOT="$2"; eval "$gp"; _grep_producers "" | grep -c .' _ "$GP_MUT" "$WORK/nrs")" "2"

# ═══════════════════════════════════════════════════════════════════════
echo '=== D: the sites left unfixed, pinned to the guard that makes them safe ==='
# ═══════════════════════════════════════════════════════════════════════
# STRUCTURAL, and said so: each asserts that a named guard still PRECEDES the
# vacuous site. It does not re-derive that no other path reaches it. A guard
# that is deleted or moved below its site reddens here; a new caller that
# bypasses it does not, and no text predicate could see that.
_precedes() {   # _precedes <file> <guard-regex> <site-regex> -> 1 iff guard is above site
    local g s
    # `${v%%$'\n'*}` rather than `| head -1` — see enc_extract in the sibling
    # suite: `head` is an early-exit reader and `pipefail` promotes the writer's
    # SIGPIPE to the pipeline's status (#622).
    g=$(grep -nE "$2" "$1" | cut -d: -f1); g=${g%%$'\n'*}
    s=$(grep -nE "$3" "$1" | cut -d: -f1); s=${s%%$'\n'*}
    [ -n "$g" ] && [ -n "$s" ] && [ "$g" -lt "$s" ] && echo 1 || echo 0
}
assert_eq "D1: build.sh — the END drift grep still sits behind [ -n \"\$end\" ]" \
    "$(_precedes "$BUILD" '^[[:space:]]*if \[ -n "\$end" \]; then' '^[[:space:]]*grep -qE -- "\$end"')" "1"
# WHY THERE IS NO TEXT-PRESENCE ASSERTION HERE ANY MORE (#1108 skeptic F3).
# This used to assert that the awk branch `if (end == "") { state=3 }` EXISTS,
# and offer that as evidence that an empty `end` is a legitimate mode whose
# refusal would break a feature. A text-presence check cannot see REACHABILITY,
# and reachability is exactly where that reading fails — so the assertion was
# true and the claim it supported was not. Measured instead:
#
#   printf 'block\ttarget\tSTART\t\tREPL\n' | while IFS=$'\t' read -r k t s e r
#     -> start=[START] end=[REPL] repl=[]        an empty MIDDLE field is INEXPRESSIBLE
#   printf 'block\ttarget\tSTART\n'   -> start=[START] end=[] repl=[]
#
# Tab is an IFS WHITESPACE character, so consecutive tabs COLLAPSE — the same
# fact `#1093` used to rule out the empty-middle-field hypothesis for `$start`,
# carried one step further than `#1093` carried it. So the ONLY row shape that
# reaches `apply_overlay_block` with an empty `end` also has an empty `repl`,
# and the function exits 4 at the replacement check BEFORE awk ever runs. The
# live manifest agrees: 5 `block` rows, all 5-field, 0 with an empty 4th field
# (counted without reading content).
#
# The retraction's CONCLUSION is unchanged — do not add a row-level
# `[ -n "$end" ]` — but it now rests on the half that survives: the grep is
# already guarded, so there is no hole to close. Not on "it would break a
# working feature", which is false.
_mktarget "$WORK/t7.txt"
r=$(_aob "$AOB" "$WORK/t7.txt" "ANCHOR-START" "" "")
assert_eq       "D1: a 3-field row (empty end AND empty repl) exits 4…"  "${r%%|*}" "4"
assert_contains "D1: …at the REPLACEMENT check, before awk runs"         "${r#*|}"  "overlay replacement missing"
assert_eq       "D1: …leaving the target intact (awk never ran)"         "$(wc -l < "$WORK/t7.txt" | tr -d ' ')" "5"
assert_eq "D2: cc-auto-update-apply.sh — _check_gate_evidence has exactly ONE caller" \
    "$(grep -cE '^[^#]*_check_gate_evidence "' "$CCA")" "1"
assert_eq "D2: …and that caller is preceded by [[ -n \"\$candidate\" ]] || exit 2" \
    "$(_precedes "$CCA" '\[\[ -n "\$candidate" \]\] \|\| \{ note "safe: --candidate required"' '! _check_gate_evidence "\$gate_evidence"')" "1"
assert_eq "D3: _test_helpers.sh — th_kill_fixture_pid guards \$root before matching it" \
    "$(_precedes "$HELPERS" '\[\[ "\$pid" =~ \^\[0-9\]\+\$ && -n "\$root" \]\] \|\| return 1' '\[\[ "\$cmdline" == \*"\$root"\* ')" "1"

EXPECTED=$(( 14 + 11 + 5 + 7 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
