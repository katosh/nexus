#!/usr/bin/env bash
# Cross-surface contract test for `ng` — the combination neither #627 nor
# #629 exercised, and that consequently red-flagged `dev` at ea4de2b
# (your-org/nexus-code#631).
#
# Run: bash monitor/test-ng-cross-surface.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE MECHANISM THIS GUARDS
# -------------------------
# #627 (856626d) added `cmd_report_grep` and a 23-assertion test that
# builds a MINIMAL fake nexus install (a fake `monitor/` holding just
# `ng` + `config/load.sh` + `mint-token.sh`) and drives `ng report-grep`
# against it. #629 (13070f2) added `monitor/_bookkeeping.sh` and a
# STARTUP guard in `ng`: if `_bookkeeping.sh` is not readable BESIDE
# `ng`, the process refuses at startup (your-org/nexus-code#601 #605).
#
# Each PR was green on its own head. Neither exercised the other's
# surface: #629's guard now gates EVERY verb — including report-grep —
# yet #627's fake install never provisioned `_bookkeeping.sh`, so on the
# merged tree every report-grep assertion failed at `ng` startup, not on
# the report-grep contract. CI could not see it: #629's branch predated
# #627's merge and was tested against nobody.
#
# This test pins the COUPLING explicitly, so it can never drift silent
# again: it drives BOTH surfaces (report-grep AND a `bk_*` primitive)
# through ONE real `ng` startup, and asserts the negative — that stripping
# `_bookkeeping.sh` from the install turns report-grep's silent-zero
# refusal into a startup refusal (the exact #631 failure), proving the
# two surfaces share the startup path rather than living independently.
#
# COVERAGE BOUNDARY: this exercises the report-grep verb and one bk_*
# primitive (bk_state_refs_window, via `retire-window --dry-run`) through
# the shared `ng` startup guard — the axis on which #631's breakage
# varied (which combinations of recently-merged surfaces run in one
# install). It does not enumerate every verb; it closes the CLASS "a
# minimal test install silently drifts from the real install's required
# file set" for these two surfaces by making their shared dependency an
# asserted, not incidental, fact.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/ng"
BK_REAL="$_test_dir/_bookkeeping.sh"
NR_REAL_1077="$_test_dir/_nexus-root.sh"

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
    if "$REAL_GREP" -qF -- "$needle" <<<"$hay"; then printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2; FAIL=$(( FAIL + 1 ))
    else printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# build_install <dir> <with_bookkeeping:0|1> — provision a fake nexus
# install faithful to the real one, optionally OMITTING _bookkeeping.sh
# to reproduce the pre-fix #631 state.
build_install() {
    local fn="$1" with_bk="$2"
    mkdir -p "$fn/monitor" "$fn/config" "$fn/reports"
    cp "$NG_REAL" "$fn/monitor/ng"
    (( with_bk == 1 )) && cp "$BK_REAL" "$fn/monitor/_bookkeeping.sh"
    # your-org/nexus-code#1077: `ng` also refuses without the primary-root resolver.
    cp "$NR_REAL_1077" "$fn/monitor/_nexus-root.sh"
    cat > "$fn/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
    chmod +x "$fn/config/load.sh"
    printf '#!/usr/bin/env bash\nprintf fake-token\n' > "$fn/monitor/mint-token.sh"
    chmod +x "$fn/monitor/mint-token.sh"
    # A minimal reports corpus with the real bare-`*` gitignore and a
    # distinctive token in one file.
    printf '%s\n' '*' > "$fn/reports/.gitignore"
    printf '# Report\n\n## Summary\ns\n\n## How to Resume\nr\n\nmentions XSURFACE_TOKEN_Z4\n' \
        > "$fn/reports/nexus_2026-01-01_000000_a.md"
}

# run_ng OUT ERR RC <install-dir> -- <ng args...>
run_ng() {
    local _o="$1" _e="$2" _r="$3" _fn="$4"; shift 4
    [[ "$1" == "--" ]] && shift
    local _ot _et _rc
    _ot=$(mktemp); _et=$(mktemp)
    ( NEXUS_ROOT="$_fn" NEXUS_WORKER_WINDOW="" "$_fn/monitor/ng" "$@" >"$_ot" 2>"$_et" )
    _rc=$?
    printf -v "$_o" '%s' "$(<"$_ot")"
    printf -v "$_e" '%s' "$(<"$_et")"
    printf -v "$_r" '%s' "$_rc"
    rm -f "$_ot" "$_et"
}

# ---- Test 1: report-grep surface runs through the live startup guard ----
echo "=== Test 1: report-grep works through #629's bookkeeping startup guard ==="
FN_OK="$WORK/ok"
build_install "$FN_OK" 1
run_ng T1_OUT T1_ERR T1_RC "$FN_OK" -- report-grep XSURFACE_TOKEN_Z4
assert_eq       "report-grep exits 0 on a present token" "$T1_RC" "0"
assert_contains "report-grep found the token"            "$T1_OUT" "XSURFACE_TOKEN_Z4"
assert_not_contains "no broken-install diagnostic when _bookkeeping.sh is present" \
                    "$T1_ERR" "bookkeeping-contract guards"

# ---- Test 2: a bk_* primitive is loaded & callable through the SAME ng ---
# `retire-window --dry-run` reaches bk_state_refs_window with no side
# effects: it proves _bookkeeping.sh was not merely PRESENT but sourced
# and its functions wired into the same process that serves report-grep.
echo "=== Test 2: bk_* primitive live in the same install (retire-window --dry-run) ==="
run_ng T2_OUT T2_ERR T2_RC "$FN_OK" -- retire-window somewindow --dry-run
assert_eq       "retire-window --dry-run exits 0"                "$T2_RC" "0"
assert_contains "dry-run header printed (bk_state_refs_window ran)" "$T2_OUT" "DRY RUN for somewindow"
assert_not_contains "no bk_require_int: command not found (helpers sourced)" \
                    "$T2_ERR" "command not found"

# ---- Test 3: the #631 coupling — strip _bookkeeping.sh, report-grep dies -
# The regression sentinel. WITHOUT _bookkeeping.sh the SAME report-grep
# invocation must refuse at startup with the broken-install diagnostic and
# emit NO report-grep hit — proving report-grep is gated by the bookkeeping
# startup guard. This is the assertion that was red on ea4de2b; if a future
# change ever lets report-grep run without the guard (or a fixture drops
# the file), this goes red LOUDLY instead of the surface silently drifting.
echo "=== Test 3: without _bookkeeping.sh, report-grep refuses at startup (#631) ==="
FN_BROKEN="$WORK/broken"
build_install "$FN_BROKEN" 0
run_ng T3_OUT T3_ERR T3_RC "$FN_BROKEN" -- report-grep XSURFACE_TOKEN_Z4
assert_ne       "report-grep does NOT exit 0 on a broken install" "$T3_RC" "0"
assert_contains "startup refusal names the missing guards"        "$T3_ERR" "bookkeeping-contract guards"
assert_not_contains "no report-grep hit leaked past the refusal"  "$T3_OUT" "XSURFACE_TOKEN_Z4"

# ---- summary ------------------------------------------------------------
TOTAL=$(( PASS + FAIL ))
EXPECTED=9
echo
echo "=== summary: $PASS passed, $FAIL failed ($TOTAL assertions; expected $EXPECTED) ==="
if (( FAIL == 0 && TOTAL == EXPECTED )); then
    echo "ALL TESTS PASSED"; exit 0
else
    (( TOTAL != EXPECTED )) && echo "ASSERTION COUNT DRIFT: ran $TOTAL, expected $EXPECTED" >&2
    exit 1
fi
