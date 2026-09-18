#!/usr/bin/env bash
# your-org/nexus-code#1277 — A SUCCESS BANNER OVER NOTHING IS A FALSE STATEMENT,
# AND THE RUNNER MUST REFUSE TO TALLY IT AS A PASS.
#
# Run: bash monitor/watcher/test-run-tests-false-pass.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT #1277 IS, AND WHY TWO EXISTING GATES BOTH MISSED IT
# --------------------------------------------------------
# Eleven suites decline a missing dependency like this:
#
#     command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq absent"
#                                        echo "ALL TESTS PASSED"; exit 0; }
#
# `run-tests.sh` tallies that PASS. `#1145`'s ratchet cannot see it because it
# keys on a DECLARED count and this declares none. `#1185`'s conjunction cannot
# see it either — and the reason is the finding worth keeping: its second signal
# asked "did this suite emit any per-assertion line?", and
# `_rt_emitted_assertion_lines` counted `SKIP:` among those. The line by which a
# suite ANNOUNCES it verified nothing was read as evidence that it verified
# something. Measured through the real runner at `5bd6d400`, three fixtures
# differing only in that line:
#
#     SKIP: line + banner   -> assertions: ?, NOT in the census, green
#     banner only           -> assertions: ?, in the census, green
#     real PASS + footer    -> 1 assertions, green
#
# So a mutation of `monitor/remote-enroll-session.sh` that unconditionally
# enrols an attacker key ships as a green suite on any host without
# `ssh-keygen`. That is the cost, and it is why the gate is a RED.
#
# WHAT IS ASSERTED HERE IS THE PROPERTY, DRIVEN THROUGH THE REAL RUNNER.
# No regex over `run-tests.sh`: every arm below plants a fixture, runs the real
# `monitor/watcher/run-tests.sh`, and reads its verdict. The mutants then break
# the runner and require each arm to REACT.
#
# THE THREE CONTROLS THAT STOP THIS BEING A GATE THAT CRIES WOLF, each asserted:
#   * a fixture OUTSIDE this repo is exempt (that is how every runner-under-test
#     suite here plants its `echo …; exit 0` vehicles — `mktemp -d`);
#   * a file that is merely SILENT stays a CENSUS, not a red (`#1185`'s deferred
#     fixture-convention decision is preserved, not quietly overturned);
#   * a real suite with real assertions stays GREEN.
#
# NO DEPENDENCY GATE AND NO SKIP PATH, deliberately: a suite about false skips
# that could itself skip would be its own subject.
#
# WHERE THIS SUITE WRITES. It plants fixtures in a dot-directory at the REPO
# ROOT and a mutant runner beside the real one, both removed by an EXIT trap.
# The plants are NOT named `test-*.sh`, so a manifest guard enumerating that
# glob concurrently cannot pick them up; the mutant runner is a dotfile, which
# a shell glob skips and `git ls-files` never sees. The repo-root dot-directory
# is this corpus's established idiom for a plant that must be inside the tree
# (`test-guards-for-diff.sh` does the same).

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd -P)
RUNNER="$_test_dir/run-tests.sh"

# THE SHARED LEDGER, NOT A HAND-ROLLED TALLY. `th_summary_and_exit` is what
# makes this suite's green certify that SOMETHING was asserted and that no FAIL
# was swallowed in a subshell (your-org/nexus-code#805) — and adopting it is what
# `summary-honesty.manifest` prescribes for a NEWLY ADDED suite, in as many
# words: appending a row for your own new code is opting it out of the standard
# the file exists to hold. Paired with the exact `EXPECTED_ASSERTIONS` guard at
# the foot, this file is `ledger=yes count=exact` and needs no row.
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"


[[ -r "$RUNNER" ]] || { echo "HARNESS: cannot read $RUNNER — no verdict reported" >&2; exit 1; }

# ── SCRUB INHERITED `export -f` HELPERS BEFORE DRIVING ANY RUNNER ───────────
#
# THIS SUITE WAS CORRECT ONLY STANDALONE, AND THAT IS THE WHOLE BUG. `bash
# monitor/watcher/test-run-tests-false-pass.sh` passed 26/0; the same file
# reached THROUGH `run-tests.sh` — which is how CI reaches every suite — RED
# deterministically at `--jobs 1` on an idle host.
#
# Mechanism, isolated: `run-tests.sh` does `export -f _rt_claims_success`
# (and friends), and an exported function is carried in the environment as
# `BASH_FUNC_<name>%%`, so it reaches EVERY descendant. When the outer runner
# runs this suite, mutant M4 — which deletes `export -f _rt_claims_success`
# from its COPY of the runner — cannot disarm anything: the mutant's `run_one`
# children still inherit the OUTER runner's definition. The gate stays armed,
# M4's "the gate is DISARMED" assertion fails, and the suite reds for a reason
# that has nothing to do with the code under test.
#
# NOT A CONCURRENCY EFFECT, and it matters that it is not: it reproduces at
# `--jobs 1` on an idle host. Concurrency was the available explanation and it
# was wrong — twice on this board tonight.
#
# THE NAME LIST IS DERIVED FROM THE RUNNER, NEVER HARDCODED. A hand-kept list
# is a denylist with a permissive default: the day someone adds a fifth
# `export -f`, a hardcoded list silently stops covering it and this suite goes
# back to being correct only standalone. Read the names out of the file under
# test, so the two cannot drift.
_inherited=0
while read -r _fn; do
    [[ -n "$_fn" ]] || continue
    if declare -F "$_fn" >/dev/null 2>&1; then
        _inherited=$(( _inherited + 1 ))
        unset -f "$_fn" 2>/dev/null || true
    fi
done < <(command grep -oE '^export -f [A-Za-z_][A-Za-z0-9_]*' "$RUNNER" | awk '{print $3}')
printf '  (inherited runner helpers scrubbed: %d — non-zero means this suite was reached THROUGH a runner)\n' "$_inherited"

# POSITIVE CONTROL ON THE SCRUB. Asserted rather than assumed, and phrased so
# it holds in BOTH modes: standalone there is nothing to scrub, through a
# runner there is, and either way no runner helper may survive into the
# children this suite is about to spawn. `unset -f` removes the environment
# entry as well as the function — measured, not assumed.
_surviving=$(env | command grep -cE '^BASH_FUNC_(_rt_[A-Za-z0-9_]*|run_one)' || true)
assert_eq "no runner helper survives in the environment for the children we spawn" \
          "$_surviving" "0"

OUTSIDE=$(mktemp -d "${TMPDIR:-/tmp}/rtfp.XXXXXX") || { echo "HARNESS: mktemp failed" >&2; exit 1; }
INSIDE=$(mktemp -d "$REPO_ROOT/.rtfp-plant.XXXXXX")  || { echo "HARNESS: mktemp in repo failed" >&2; exit 1; }
MUTANT="$_test_dir/.rtfp-runner-mutant.$$.sh"
# `git reset -- "$INSIDE"` first (your-org/nexus-code#1387, same shape as
# test-guards-for-diff.sh): the plant is untracked inside the repo root, a
# concurrent `git add -A` stages it, and `rm -rf` removes the directory but
# not the index entry. A no-op when nothing was staged.
cleanup() { git -C "$REPO_ROOT" reset -q -- "$INSIDE" 2>/dev/null; rm -rf "$OUTSIDE" "$INSIDE" "$MUTANT"; }
trap cleanup EXIT INT TERM

# --- the three fixture shapes ----------------------------------------------
plant() {  # plant <dir> <name> <body-lines...>
    local d="$1" n="$2"; shift 2
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$@"; } > "$d/$n"
    chmod +x "$d/$n"
}
for d in "$OUTSIDE" "$INSIDE"; do
    # THE #1277 SHAPE: a skip line, a success banner, exit 0.
    plant "$d" rtfp-skipbanner.sh 'echo "  SKIP: jq absent"' 'echo "ALL TESTS PASSED"' 'exit 0'
    # SILENT: no banner, no assertion line — the census case, deliberately NOT red.
    plant "$d" rtfp-silent.sh 'printf "%s\n" "no footer at all"' 'exit 0'
    # REAL: an assertion line and a readable footer.
    plant "$d" rtfp-real.sh 'echo "  PASS: something real"' \
          'echo "=== summary: 1 passed, 0 failed ==="' 'echo "ALL TESTS PASSED"' 'exit 0'
done

# `run <runner> <jobs> <paths...>` -> "<rc>|<red-count>", where red-count is the
# number of files the runner named as a false pass (0 when it named none).
run() {
    local runner="$1" jobs="$2"; shift 2
    local log rc n
    log=$(mktemp "${TMPDIR:-/tmp}/rtfp-log.XXXXXX")
    timeout 180 bash "$runner" --jobs "$jobs" "$@" > "$log" 2>&1
    rc=$?
    n=$(command grep -c '^ *false pass: ' "$log")
    printf '%s|%s' "$rc" "$n"
    rm -f "$log"
}

echo "=== 1. the property: an IN-REPO success banner over nothing is RED ==="
r=$(run "$RUNNER" 1 "$INSIDE/rtfp-skipbanner.sh")
assert_eq "in-repo skip+banner: run is RED"            "${r%%|*}" "1"
assert_eq "in-repo skip+banner: the file is NAMED"     "${r##*|}" "1"

echo
echo "=== 2. CONTROL — a fixture OUTSIDE the repo is exempt by construction ==="
# Without this, the gate would redden every runner-under-test suite in this
# corpus (they all plant under `mktemp -d`), and a guard that manufactures a
# false red is how the real ratchet gets switched off.
r=$(run "$RUNNER" 1 "$OUTSIDE/rtfp-skipbanner.sh")
assert_eq "byte-identical fixture outside the repo: run is GREEN" "${r%%|*}" "0"
assert_eq "…and nothing is named"                                 "${r##*|}" "0"

echo
# INVERTED DELIBERATELY (your-org/nexus-code#1185). This section used to assert
# that a SILENT in-repo file stays a census. The gate has been PROMOTED from
# `vacuous AND banner AND in-repo` to `vacuous AND in-repo`, so this is now the
# slice that reddens, and these two assertions are the positive control for that
# promotion: section 3 FLIPS while sections 2 and 4 do NOT.
#
# Section 2 (a byte-identical fixture OUTSIDE the repo) staying green is what
# shows the discriminator is `_rt_path_in_repo` and not the banner; section 4 (a
# real in-repo suite with real assertions) staying green is what shows the gate
# still keys on "asserted nothing" and not merely on "is in the repo". Change
# either of those and this control stops meaning anything.
echo "=== 3. a SILENT in-repo file is now RED (#1185 promotion) ==="
r=$(run "$RUNNER" 1 "$INSIDE/rtfp-silent.sh")
assert_eq "in-repo silent file: run is RED"    "${r%%|*}" "1"
assert_eq "…and it IS accused"                 "${r##*|}" "1"

echo
echo "=== 4. CONTROL — a real in-repo suite with real assertions stays GREEN ==="
r=$(run "$RUNNER" 1 "$INSIDE/rtfp-real.sh")
assert_eq "in-repo real suite: run is GREEN"   "${r%%|*}" "0"
assert_eq "…and it is not accused"             "${r##*|}" "0"

echo
echo "=== 5. THE PARALLEL ARM — the path CI uses, where an unexported helper disarms it ==="
# `--jobs 1` cannot see an export omission: `run_one` runs in this shell. The
# parallel arm gets a FRESH `bash -c` per test, so a helper that is merely
# DEFINED is `command not found` there — and both #1277 helpers fail toward
# PERMISSIVENESS when missing. Mutant M4 below is the demonstration.
r=$(run "$RUNNER" 2 "$INSIDE/rtfp-skipbanner.sh" "$INSIDE/rtfp-real.sh")
assert_eq "parallel: the banner file is still RED"  "${r%%|*}" "1"
assert_eq "parallel: exactly the one file is named" "${r##*|}" "1"

echo
echo "=== 6. MUTATION — each mutant proved APPLIED, then required to disarm the gate ==="
# run_mutant <label> <jobs> <python-edit-fn>
run_mutant() {
    local label="$1" jobs="$2" fn="$3"
    cp "$RUNNER" "$MUTANT"
    "$fn" "$MUTANT"
    if cmp -s "$RUNNER" "$MUTANT"; then
        printf '  FAIL: %s — MUTANT DID NOT APPLY (byte-identical); this round proves nothing\n' "$label" >&2
        _th_fail; _th_fail; return
    fi
    printf '  PASS: %s — mutant applied (differs from pristine)\n' "$label"; _th_pass
    # AN ASSERTION THAT ONLY SPEAKS ON FAILURE IS INVISIBLE TO THE COUNT GUARD,
    # and the count guard exists to catch exactly that. This check used to print
    # nothing on success, so the suite ran 22 assertions against a constant of
    # 25 and reported a mismatch it could not explain — the guard catching its
    # own author. It records a PASS now.
    if ! bash -n "$MUTANT" 2>/dev/null; then
        printf '  FAIL: %s — mutant does not parse; a syntax error is not a demonstration\n' "$label" >&2
        _th_fail; return
    fi
    printf '  PASS: %s — mutant still parses, so any reaction is behavioural\n' "$label"; _th_pass
    local r; r=$(run "$MUTANT" "$jobs" "$INSIDE/rtfp-skipbanner.sh")
    assert_eq "$label — the gate is DISARMED, so this suite catches it" "${r%%|*}|${r##*|}" "0|0"
}

# M1 — RESTORE THE ORIGINAL BLINDNESS. Put `SKIP|TODO` back into the
# per-assertion-line recogniser. Nothing else changes: the sidecar, the verdict
# and both predicates stay exactly as shipped, and the gate still goes dark —
# which is the whole point of #1277's mechanism and the half a fix aimed only at
# the verdict would miss.
m1() { python3 - "$1" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old="(PASS|FAIL|XFAIL)[[:space:]]*[:.)-]"
new="(PASS|FAIL|XFAIL|SKIP|TODO)[[:space:]]*[:.)-]"
assert old in s
open(p,'w',encoding='utf-8').write(s.replace(old,new,1))
PY
}
run_mutant "M1 SKIP counted as an assertion line again" 1 m1

# M2 — DELETE the sidecar write. The verdict block survives untouched, so a
# guard that looked for the `::error::` text in the source would still find it.
m2() { python3 - "$1" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
m=re.search(r'\n *if _rt_path_in_repo "\$test_path"; then\n[^\n]*falsepass"\n *fi\n', s)
assert m
open(p,'w',encoding='utf-8').write(s[:m.start()]+'\n'+s[m.end():])
PY
}
run_mutant "M2 the .falsepass sidecar write DELETED" 1 m2

# M3 — VALUE CHANGE, not deletion: the IN-REPO discriminator is still called,
# still named, still commented, and matches a prefix no path has.
#
# RETARGETED at your-org/nexus-code#1185. This arm used to mutate the BANNER
# recogniser, a load-bearing conjunct of the gate until the promotion removed
# it. Left alone it asserted that disarming the banner disarms the gate, which
# is now FALSE BY DESIGN — so it reddened for exactly the reason the change was
# made. A mutant must target a predicate the gate still consults.
m3() { python3 - "$1" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='        "$_RT_REPO_ROOT"/*) return 0 ;;'
new='        "$_RT_REPO_ROOT"/NEVER-MATCHES/*) return 0 ;;'
assert old in s
open(p,'w',encoding='utf-8').write(s.replace(old,new,1))
PY
}
run_mutant "M3 the in-repo discriminator matches nothing" 1 m3

# M4 — THE EXPORT OMISSION, visible ONLY at --jobs 2. This is the mutant the
# runner's own comment predicts and the reason arm 5 exists.
m4() { python3 - "$1" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old="export -f _rt_path_in_repo\n"
assert old in s
open(p,'w',encoding='utf-8').write(s.replace(old,"",1))
PY
}
run_mutant "M4 _rt_path_in_repo not exported (parallel arm only)" 2 m4

# M5 — RELOCATION of the verdict, not removal: `_false_pass` is still set, the
# list is still printed, and the exit arm no longer consults it. A guard reading
# the sidecar rather than the RUN'S VERDICT would survive this.
m5() { python3 - "$1" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
old='(( ${_false_pass:-0} > 0 )) && exit 1\n'
assert old in s
s=s.replace(old,"",1)
old2=''' && ${_vacuous_pass:-0} == 0 \\\n       && ${_false_pass:-0} == 0 )) && exit 0'''
new2=''' && ${_vacuous_pass:-0} == 0 )) && exit 0'''
assert old2 in s
open(p,'w',encoding='utf-8').write(s.replace(old2,new2,1))
PY
}
# M5 leaves the file NAMED but the run GREEN, so it is checked on rc alone.
cp "$RUNNER" "$MUTANT"; m5 "$MUTANT"
if cmp -s "$RUNNER" "$MUTANT"; then
    printf '  FAIL: M5 — MUTANT DID NOT APPLY (byte-identical)\n' >&2; _th_fail; _th_fail
else
    printf '  PASS: M5 verdict de-wired from the exit arm — mutant applied\n'; _th_pass
    r=$(run "$MUTANT" 1 "$INSIDE/rtfp-skipbanner.sh")
    assert_eq "M5 — the run goes GREEN while still naming the file, and arm 1 catches it" \
              "${r%%|*}|${r##*|}" "0|1"
fi

echo
echo "=== 7. the plants are removed, and the repo is left as it was found ==="
cleanup
trap - EXIT INT TERM
assert_eq "the in-repo plant directory is gone" "$( [[ -e "$INSIDE" ]] && echo present || echo gone )" "gone"
assert_eq "the mutant runner is gone"           "$( [[ -e "$MUTANT" ]] && echo present || echo gone )" "gone"

# EXACT COUNT, then the SHARED LEDGER. The two protect different things and
# neither implies the other: the count catches an assertion that never ran (a
# fixture that bailed, a helper that vanished at rc 127, which nothing else
# counts), and the ledger catches a FAIL recorded inside a subshell whose
# increment died with it.
EXPECTED_ASSERTIONS=27
echo
if (( PASS + FAIL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. Some assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi
th_summary_and_exit
