#!/usr/bin/env bash
# Regression test for the fork-free project-slug derivation in
# `ng report-init` (your-org/nexus-code#638).
#
# Run: bash monitor/watcher/test-ng-report-init-forkfree.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE DEFECT
# ----------
# `_report_project_slug` used to derive the project by forking `$(pwd)`
# and `printf | sed` on report-init's hot path. Under jobs-4 fork /
# RLIMIT_NPROC pressure (the sandbox caps worker processes; a loaded CI
# runner oversubscribes 2 cores 4 ways) either subprocess can fail. A
# failed `sed` yields an EMPTY slug, and cmd_report_init wrote the report
# anyway — `reports/_<date>_<slug>.md`, exit 0. A misattributed report,
# no error: this workspace's dominant defect class (silence as
# correctness). It surfaced as `test-ng-report-init.sh` reddening `dev`
# intermittently, ONLY in the `bash, jobs 4` cell — the pre-existing
# fragility (introduced e10b2fe, 2026-05-10) made observable when added
# test files (#629, #636) raised jobs-4 scheduling density.
#
# THE FIX, and what this test pins
# --------------------------------
#   1. Derivation is now pure-builtin ($PWD + ${##}/${%%} expansion), so
#      it cannot fail under fork pressure. Test 1 proves it: with `sed`
#      forced to fail on PATH (a faithful stand-in for the subprocess
#      failure), report-init from work/<proj> STILL embeds <proj>.
#   2. Test 2 is the NEGATIVE CONTROL — a mutant `ng` whose derivation is
#      restored to the old `printf|sed` body reproduces the bug under the
#      same failing `sed` (empty slug, misfiled report). Without this,
#      Test 1 is a gate never seen fail; with it, Test 1 is shown to
#      discriminate the fix from the defect.
#   3. cmd_report_init now guards the one remaining fork (the outer
#      command substitution) — an empty project ⇒ die loudly, never a
#      silent misfile. Test 3 drives an empty-slug mutant and asserts the
#      loud refusal + that NO `_<date>` file was written.
#
# COVERAGE BOUNDARY: this exercises the project-slug derivation under a
# simulated subprocess failure (a PATH-front `sed` that exits non-zero)
# and the empty-slug guard. It does not simulate every fork site in
# cmd_report_init; it closes the specific silent-degradation path that
# reddened dev, on the axis it varied (subprocess failure of the slug
# derivation), plus the guard backstop for the residual outer fork.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"
BK_REAL="$_test_dir/../_bookkeeping.sh"
NR_REAL_1077="$_test_dir/../_nexus-root.sh"

# Resolve the real grep executable (this runs under bash, so `command -v
# grep` already yields the binary, not the operator's ugrep wrapper).
REAL_GREP=$(command -v grep 2>/dev/null || true)
[[ -x "$REAL_GREP" ]] || REAL_GREP=/bin/grep

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_ne() {
    local label="$1" got="$2" nope="$3"
    if [[ "$got" != "$nope" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q, wanted anything but\n' "$label" "$got" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && "$REAL_GREP" -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s\n           expected substring: %s\n           in: %s\n' "$label" "$needle" "$hay" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if "$REAL_GREP" -qF -- "$needle" <<<"$hay"; then printf '  FAIL: %s — unexpectedly found %q in: %s\n' "$label" "$needle" "$hay" >&2; FAIL=$(( FAIL + 1 ))
    else printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config" "$FAKE_NEXUS/reports" "$FAKE_NEXUS/work/myproj"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
cp "$BK_REAL" "$FAKE_NEXUS/monitor/_bookkeeping.sh"
# your-org/nexus-code#1077: `ng` also refuses without the primary-root resolver.
cp "$NR_REAL_1077" "$FAKE_NEXUS/monitor/_nexus-root.sh"
NG="$FAKE_NEXUS/monitor/ng"

cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"
printf '#!/usr/bin/env bash\nprintf fake-token\n' > "$FAKE_NEXUS/monitor/mint-token.sh"
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# A PATH-front `sed` that always fails — a faithful stand-in for a fork /
# exec failure of the subprocess the OLD derivation depended on.
FAILBIN="$WORK/failbin"
mkdir -p "$FAILBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAILBIN/sed"
chmod +x "$FAILBIN/sed"

# run_ri OUT RC <ng-binary> <fail_sed:0|1> -- run report-init from
# work/myproj with slug2 into the fake reports dir; capture stdout + rc.
run_ri() {
    local _o="$1" _r="$2" _ng="$3" _failsed="$4"
    local _path _ot _rc _pathenv=""
    (( _failsed == 1 )) && _pathenv="$FAILBIN:"
    _ot=$(mktemp)
    ( cd "$FAKE_NEXUS/work/myproj" \
        && PATH="${_pathenv}$PATH" NEXUS_WORKER_WINDOW="" NEXUS_ROOT="$FAKE_NEXUS" \
           "$_ng" report-init slug2 --reports-dir "$FAKE_NEXUS/reports" >"$_ot" 2>>"$FAKE_NEXUS/stderr.log" )
    _rc=$?
    printf -v "$_o" '%s' "$(<"$_ot")"
    printf -v "$_r" '%s' "$_rc"
    rm -f "$_ot"
}

TODAY=$(date +%Y-%m-%d)

# ---- Test 1: fork-free derivation holds even when `sed` fails ----------
echo '=== Test 1: real ng — project=myproj even with sed failing (fork-free) ==='
run_ri T1_PATH T1_RC "$NG" 1
assert_eq       "exit 0"                                "$T1_RC" "0"
assert_contains "filename embeds project=myproj"        "$T1_PATH" \
                "$FAKE_NEXUS/reports/myproj_${TODAY}_"
assert_not_contains "NOT a misattributed empty-project file" "$T1_PATH" "/reports/_${TODAY}_"

# ---- Test 2: NEGATIVE CONTROL — the pre-fix code reproduces the bug ---
# Reconstruct the pre-fix ng faithfully: (a) restore the old `printf|sed`
# derivation fork AND (b) strip the empty-slug guard. Both reversions are
# required — with the guard still present the old derivation would fail
# LOUD (that is Test 3's defense-in-depth), so a mutant that reverts only
# the derivation would not reproduce the SILENT misfile the incident was.
echo '=== Test 2: mutant (pre-fix: sed fork + no guard) — silent misfile reproduces ==='
NG_OLD="$FAKE_NEXUS/monitor/ng-old"
python3 - "$NG" "$NG_OLD" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
new = "        local after=\"${cwd##*/work/}\"\n        printf '%s' \"${after%%/*}\"\n"
old = "        printf '%s' \"$cwd\" | sed -E 's|.*/work/([^/]+).*|\\1|'\n"
guard = "    [[ -n \"$project\" ]] || die \"report-init: could not derive a project slug (resource pressure?) — retry, or pass --project <name> explicitly\"\n"
assert new in s, "fork-free derivation lines not found — test needs updating to match ng"
assert guard in s, "empty-slug guard line not found — test needs updating to match ng"
s = s.replace(new, old, 1).replace(guard, "", 1)
open(dst, "w").write(s)
PY
chmod +x "$NG_OLD"
run_ri T2_PATH T2_RC "$NG_OLD" 1
assert_eq       "mutant parses & exits 0 (degrades silently, as the bug did)" "$T2_RC" "0"
assert_not_contains "mutant does NOT embed myproj (fork failure lost it)" \
                    "$T2_PATH" "/reports/myproj_"
assert_contains "mutant emits the misattributed empty-project path"        \
                "$T2_PATH" "/reports/_${TODAY}_"

# ---- Test 3: empty-slug guard refuses loudly, writes nothing -----------
# Mutant whose derivation returns empty on the work/ branch. The guard in
# cmd_report_init must die rather than write `reports/_<date>_<slug>.md`.
echo '=== Test 3: empty-slug guard — loud refusal, no misfiled report ==='
NG_EMPTY="$FAKE_NEXUS/monitor/ng-empty"
python3 - "$NG" "$NG_EMPTY" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
new = "        printf '%s' \"${after%%/*}\"\n"
empty = "        printf '' ; return 0\n"
assert new in s, "derivation print line not found — test needs updating to match ng"
open(dst, "w").write(s.replace(new, empty, 1))
PY
chmod +x "$NG_EMPTY"
# Count pre-existing reports so we can assert nothing new was written.
_before=$(find "$FAKE_NEXUS/reports" -maxdepth 1 -name '*.md' | wc -l)
_e_out=$(mktemp); _e_err=$(mktemp)
( cd "$FAKE_NEXUS/work/myproj" \
    && NEXUS_WORKER_WINDOW="" NEXUS_ROOT="$FAKE_NEXUS" \
       "$NG_EMPTY" report-init slug3 --reports-dir "$FAKE_NEXUS/reports" >"$_e_out" 2>"$_e_err" )
T3_RC=$?
T3_OUT=$(<"$_e_out"); T3_ERR=$(<"$_e_err"); rm -f "$_e_out" "$_e_err"
_after=$(find "$FAKE_NEXUS/reports" -maxdepth 1 -name '*.md' | wc -l)
assert_ne       "guard: non-zero exit on empty slug"        "$T3_RC" "0"
assert_contains "guard: diagnostic names the derivation failure" \
                "$T3_ERR" "could not derive a project slug"
assert_eq       "guard: NO report file written"             "$_after" "$_before"
assert_not_contains "guard: no misattributed path on stdout" "$T3_OUT" "/reports/_"

# ---- summary ------------------------------------------------------------
TOTAL=$(( PASS + FAIL ))
EXPECTED=10
echo
echo "=== summary: $PASS passed, $FAIL failed ($TOTAL assertions; expected $EXPECTED) ==="
if (( FAIL == 0 && TOTAL == EXPECTED )); then
    echo "ALL TESTS PASSED"; exit 0
else
    (( TOTAL != EXPECTED )) && echo "ASSERTION COUNT DRIFT: ran $TOTAL, expected $EXPECTED" >&2
    exit 1
fi
