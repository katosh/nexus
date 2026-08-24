#!/usr/bin/env bash
# Unit tests for `ng report-grep` (cmd_report_grep in monitor/ng) — the
# ignore-file-blind corpus search with a visibility guard (issue #618).
#
# Run: bash monitor/watcher/test-ng-report-grep.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# The class under test is #282's dominant one — silence used as a proxy
# for absence — living inside the search primitive. `reports/.gitignore`
# is a bare `*`; the operator's interactive `grep` wraps `ugrep
# --ignore-files`, so a plain `grep -r <token> reports/` returns ZERO
# matches, no error, over ~1,600 files. `ng report-grep` must (a) find a
# present token through that bare-`*` gitignore, and (b) REFUSE to hand
# back a false zero when the search is blind to the tree — emitting a
# diagnostic that names the ignore-file interaction instead.
#
# The load-bearing case is the negative control (Test 4): an
# ignore-file-aware `grep` is placed on PATH (a faithful stand-in for the
# operator's ugrep wrapper — `command grep` honours a grep executable
# earlier on PATH), and the guard must convert its silent zero into a
# loud diagnostic. Test 6 then EXCISES the guard from a copy of `ng` and
# asserts the very same invocation goes red for the expected reason (a
# silent zero, no diagnostic) — a guard never observed to fail is not
# evidence.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

# The real grep binary, resolved WITHOUT the operator's `grep` shell
# function (this test runs under bash, so `command -v grep` already gives
# the executable; the explicit fallbacks harden it for odd PATHs).
REAL_GREP=$(command -v grep 2>/dev/null || true)
[[ -x "$REAL_GREP" ]] || REAL_GREP=/bin/grep
[[ -x "$REAL_GREP" ]] || REAL_GREP=/usr/bin/grep

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_gt() {
    local label="$1" got="$2" floor="$3"
    if (( got > floor )); then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q not > %q\n' "$label" "$got" "$floor" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if "$REAL_GREP" -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s\n           expected substring: %s\n           in: %s\n' "$label" "$needle" "$hay" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if "$REAL_GREP" -qF -- "$needle" <<<"$hay"; then printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2; FAIL=$(( FAIL + 1 ))
    else printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config" "$FAKE_NEXUS/reports"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"

# `ng` refuses to start unless _bookkeeping.sh is readable beside it
# (the bookkeeping-contract startup guard, your-org/nexus-code #601 #605
# #629). It ships in the repo alongside `ng`, so a faithful fake install
# must provision it too — omitting it makes every report-grep assertion
# fail at `ng` startup, not on the report-grep contract (your-org/nexus-code#631).
cp "$_test_dir/../_bookkeeping.sh" "$FAKE_NEXUS/monitor/_bookkeeping.sh"

cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"
cat > "$FAKE_NEXUS/monitor/mint-token.sh" <<'STUB'
#!/usr/bin/env bash
printf 'fake-token'
STUB
chmod +x "$FAKE_NEXUS/monitor/mint-token.sh"

# A minimal reports corpus: report-shaped files carry the mandatory
# `## How to Resume` heading (the visibility sentinel) plus a distinctive
# token in exactly two of them. `reports/.gitignore` is the real bare `*`.
REPORTS="$FAKE_NEXUS/reports"
printf '%s\n' '*' > "$REPORTS/.gitignore"
make_report() { # <name> <extra-body-line>
    printf '# Report\n\n## Summary\ns\n\n## How to Resume\nresume steps\n\n%s\n' "$2" > "$REPORTS/$1"
}
make_report "nexus_2026-01-01_000000_a.md" "nothing special here"
make_report "nexus_2026-01-02_000000_b.md" "this one mentions DISTINCT_TOKEN_QK7"
make_report "nexus_2026-01-03_000000_c.md" "also mentions DISTINCT_TOKEN_QK7 again"

# run_ng OUT ERR RC -- <ng args...>   (search root defaults to the fake
# reports dir via NEXUS_ROOT). Extra leading env assignments may be
# passed before `--` is NOT supported; use run_ng_env for that.
run_ng() {
    local _o="$1" _e="$2" _r="$3"; shift 3
    [[ "$1" == "--" ]] && shift
    local _ot _et _rc
    _ot=$(mktemp); _et=$(mktemp)
    ( NEXUS_ROOT="$FAKE_NEXUS" NEXUS_WORKER_WINDOW="" "$NG" "$@" >"$_ot" 2>"$_et" )
    _rc=$?
    printf -v "$_o" '%s' "$(<"$_ot")"
    printf -v "$_e" '%s' "$(<"$_et")"
    printf -v "$_r" '%s' "$_rc"
    rm -f "$_ot" "$_et"
}

# run_ng_env OUT ERR RC PATHVAL NGBIN -- <ng args...>  — run with an
# explicit PATH prepend (to shadow `command grep`) and an explicit ng
# binary (so Test 6 can drive a guard-excised copy).
run_ng_env() {
    local _o="$1" _e="$2" _r="$3" _path="$4" _ng="$5"; shift 5
    [[ "$1" == "--" ]] && shift
    local _ot _et _rc
    _ot=$(mktemp); _et=$(mktemp)
    ( NEXUS_ROOT="$FAKE_NEXUS" NEXUS_WORKER_WINDOW="" PATH="$_path" "$_ng" "$@" >"$_ot" 2>"$_et" )
    _rc=$?
    printf -v "$_o" '%s' "$(<"$_ot")"
    printf -v "$_e" '%s' "$(<"$_et")"
    printf -v "$_r" '%s' "$_rc"
    rm -f "$_ot" "$_et"
}

# An ignore-file-AWARE grep on PATH: a faithful stand-in for the
# operator's ugrep --ignore-files wrapper. It drops any recursive root
# whose directory carries a bare-`*` .gitignore, then delegates to the
# real grep. `command grep` inside cmd_report_grep resolves to THIS.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/grep" <<EOF
#!/usr/bin/env bash
args=(); roots=(); after_dd=0; have_root=0
for a in "\$@"; do
  if (( after_dd )); then roots+=("\$a"); have_root=1; continue; fi
  if [[ "\$a" == "--" ]]; then after_dd=1; args+=("\$a"); continue; fi
  args+=("\$a")
done
keep=()
for r in \${roots[@]+"\${roots[@]}"}; do
  if [[ -d "\$r" && -f "\$r/.gitignore" ]] && "$REAL_GREP" -qxF '*' "\$r/.gitignore"; then continue; fi
  keep+=("\$r")
done
if (( have_root )) && (( \${#keep[@]} == 0 )); then exit 1; fi
exec "$REAL_GREP" \${args[@]+"\${args[@]}"} \${keep[@]+"\${keep[@]}"}
EOF
chmod +x "$FAKEBIN/grep"
SHADOW_PATH="$FAKEBIN:$PATH"

DIAG_MARK="VISIBILITY GUARD"          # the diagnostic's headline
DIAG_CAUSE="ignore-file-aware grep"   # names the ignore-file interaction
DIAG_ISSUE="issue #618"

# ---- Test 1: present token in the corpus returns > 0 hits --------------
echo '=== Test 1: present token → hits, exit 0 ==='
run_ng out err rc -- report-grep -l DISTINCT_TOKEN_QK7
assert_eq       "exit 0 on a present token"          "$rc" "0"
n=$(printf '%s\n' "$out" | "$REAL_GREP" -c . || true)
assert_gt       "at least the 2 seeded files match"  "$n" "1"
assert_contains "a matching file is a report"        "$out" "nexus_2026-01-02_000000_b.md"
assert_not_contains "no visibility-guard diagnostic on a real hit" "$err" "$DIAG_MARK"

# ---- Test 2: genuine no-match (corpus visible) → exit 1, no diagnostic --
echo '=== Test 2: genuine absence with a visible corpus → exit 1, silent ==='
run_ng out err rc -- report-grep -l ABSENT_TOKEN_NEVER_WRITTEN_ZZ
assert_eq       "exit 1 on a genuine no-match"       "$rc" "1"
assert_not_contains "no diagnostic when the corpus is provably visible" "$err" "$DIAG_MARK"

# ---- Test 3: bare-* tree, BLIND search still finds the token -----------
# Isolates the variable: the bare-* .gitignore alone does NOT hide the
# token from cmd_report_grep's `command grep` (no ignore-aware grep on
# PATH here). This is the fix working.
echo '=== Test 3: bare-* .gitignore does not blind command grep ==='
CTRL="$WORK/ctrl"; mkdir -p "$CTRL"
printf '%s\n' '*' > "$CTRL/.gitignore"
printf '## How to Resume\nx\nCONTROL_TOKEN_MW3 here\n' > "$CTRL/r.md"
run_ng out err rc -- report-grep -l CONTROL_TOKEN_MW3 "$CTRL"
assert_eq       "exit 0: token found through bare-* gitignore" "$rc" "0"
assert_contains "the bare-* file is reported"        "$out" "$CTRL/r.md"

# ---- Test 4: NEGATIVE CONTROL — ignore-aware grep → guard fires --------
# The same bare-* tree as Test 3, but now an ignore-file-aware grep sits
# on PATH (the regression the guard exists to catch). The token IS in the
# file, yet the suppressed search sees zero AND the sentinel probe sees
# zero. The guard must refuse the false zero with a diagnostic. Assert on
# the DIAGNOSTIC MESSAGE, not the exit code (a missing assert_* helper
# exits rc 127 and is counted by nothing).
echo '=== Test 4: ignore-aware grep on PATH → visibility guard fires ==='
run_ng_env out err rc "$SHADOW_PATH" "$NG" -- report-grep -l CONTROL_TOKEN_MW3 "$CTRL"
assert_contains "guard diagnostic headline present"  "$err" "$DIAG_MARK"
# The diagnostic must state only what the probe ESTABLISHED (no report
# visible under these roots) and read as a "don't know", NOT assert a
# cause the probe didn't isolate: in the live shell `command grep` is
# blind-proof against the operator's `grep` FUNCTION, so ugrep is only a
# candidate, and the wrong/empty/narrow root is the more actionable one,
# listed first (skeptic round 1, Q1).
assert_contains "diagnostic frames it as a don't-know, not a diagnosis" "$err" 'not a diagnosis'
assert_contains "diagnostic points at the typed root first" "$err" "check the root you typed"
assert_contains "diagnostic offers ignore-file interaction as a candidate" "$err" "$DIAG_CAUSE"
assert_contains "diagnostic cites the issue"         "$err" "$DIAG_ISSUE"
assert_not_contains "a suppressed file is NOT silently reported as a hit" "$out" "$CTRL/r.md"
assert_eq       "non-zero exit (guard), not a silent 0/1" "$rc" "3"

# ---- Test 5: matched positive for Test 4 — sentinel present, visible ---
# Prove the guard does NOT false-alarm merely because an ignore-aware
# grep is on PATH: a tree WITHOUT a bare-* .gitignore stays visible, so
# a present token is found and no diagnostic is emitted, even under the
# shadowed PATH.
echo '=== Test 5: ignore-aware grep + visible tree → no false alarm ==='
VIS="$WORK/vis"; mkdir -p "$VIS"
printf '## How to Resume\nx\nVISIBLE_TOKEN_PL9 here\n' > "$VIS/r.md"
run_ng_env out err rc "$SHADOW_PATH" "$NG" -- report-grep -l VISIBLE_TOKEN_PL9 "$VIS"
assert_eq       "exit 0: visible tree, token found"  "$rc" "0"
assert_not_contains "no guard diagnostic on a visible tree" "$err" "$DIAG_MARK"

# ---- Test 6: guard is non-vacuous — excise it, negative control goes red
# Build a copy of ng with the >>> / <<< VISIBILITY-GUARD-618 span
# replaced by a bare `return 1` (the pre-guard behaviour: trust the
# zero). Re-run Test 4's exact invocation. WITHOUT the guard the
# primitive returns a SILENT zero — no diagnostic — which is precisely
# the #618 bug. Assert the diagnostic is GONE (the negative control goes
# red for the expected reason) and the exit is the silent grep no-match.
echo '=== Test 6: excise the guard → silent zero returns (guard is load-bearing) ==='
NG_NOGUARD="$WORK/ng-noguard"
awk '
  /# >>> VISIBILITY-GUARD-618/ { print "        return 1"; skip=1; next }
  /# <<< VISIBILITY-GUARD-618/ { skip=0; next }
  skip { next }
  { print }
' "$NG_REAL" > "$NG_NOGUARD"
chmod +x "$NG_NOGUARD"
# Sanity: the mutant must still be valid bash and must have actually
# dropped the guard (else the "goes red" below would be vacuous).
if bash -n "$NG_NOGUARD" 2>/dev/null; then printf '  PASS: %s\n' "mutant ng parses"; PASS=$(( PASS + 1 )); else printf '  FAIL: %s\n' "mutant ng does not parse" >&2; FAIL=$(( FAIL + 1 )); fi
# The excision must be checked DIFFERENTIALLY — present in the real ng,
# absent in the mutant — never as a bare "absent from the mutant".
#
# This assertion was vacuous until #707. It grepped the mutant for
# `VISIBILITY GUARD — refusing`, a spelling that had drifted (the real
# diagnostic reads `VISIBILITY GUARD — a zero this search cannot vouch
# for`). Count in the mutant: 0. Count in the REAL ng: also 0. So the
# guard-on-the-guard could not fail — it would have passed had the awk
# excision matched nothing at all, which is the exact vacuity it was
# written to rule out. Asserting the real ng has the string FIRST is what
# converts a spelling into a property: a future reword goes red here
# instead of silently disarming Test 6.
mut_have=$("$REAL_GREP" -c "$DIAG_MARK" "$NG_NOGUARD" || true)
real_have=$("$REAL_GREP" -c "$DIAG_MARK" "$NG_REAL" || true)
assert_gt       "the REAL ng contains the guard diagnostic (anti-vacuity)" "$real_have" "0"
assert_eq       "mutant no longer contains the guard diagnostic" "$mut_have" "0"
run_ng_env out err rc "$SHADOW_PATH" "$NG_NOGUARD" -- report-grep -l CONTROL_TOKEN_MW3 "$CTRL"
assert_not_contains "excised guard: diagnostic is GONE (bug reproduced)" "$err" "$DIAG_MARK"
assert_eq       "excised guard: silent grep no-match exit 1"  "$rc" "1"

# ---- Test 7: empty pattern is refused ----------------------------------
echo '=== Test 7: empty pattern refused ==='
run_ng out err rc -- report-grep ""
assert_eq       "exit 1 on empty pattern"            "$rc" "1"
assert_contains "empty-pattern diagnostic"           "$err" "empty pattern"

# ---- assertion-count guard ---------------------------------------------
# A missing assert_* helper (typo → rc 127) is counted by nothing; a
# verdict of ALL TESTS PASSED with too few assertions is a false green.
# Pin the exact count so a silently-dropped assertion turns the suite red.
EXPECTED_ASSERTIONS=24
TOTAL=$(( PASS + FAIL ))

echo
echo "=== summary: $PASS passed, $FAIL failed ($TOTAL assertions; expected $EXPECTED_ASSERTIONS) ==="
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    echo "ASSERTION COUNT MISMATCH: ran $TOTAL, expected $EXPECTED_ASSERTIONS — a helper was likely skipped (rc 127). Treating as failure." >&2
    exit 1
fi
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
