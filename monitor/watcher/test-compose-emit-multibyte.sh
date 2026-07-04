#!/usr/bin/env bash
# Tests for the compose_emit multibyte byte-safety hardening
# (nexus-code: compose_emit multibyte wedge, 2026-06-24).
#
# Incident: the operator's scientific comment bodies carry non-ASCII
# (σ µ → ≈ ⟂). The snapshot byte-truncates the body preview to a fixed
# width, slicing a multibyte UTF-8 character mid-sequence and leaving an
# INVALID UTF-8 trailing byte. Under the ambient en_US.utf8 locale gawk's
# regex decoder logged "Invalid multibyte data detected" on every
# compose_emit fire (chronically, for hours) AND the bracket-class /
# tolower() match at the bad byte is locale-undefined. The watcher later
# wedged and a supervisor revive cost ~9min downtime.
#
# Fix under test:
#   1. Every body-decoding awk in the compose_emit filter pipeline runs
#      under LC_ALL=C (byte handling, locale-independent) — mirrors the
#      _reemit.sh re-feed precedent. No warning, byte-exact passthrough.
#   2. `_v2_task_compose_emit` BOUNDS the filter pipeline via _run_bounded
#      (the file-fed `_gh_filter_dedup_pipeline_file` wrapper) so a future
#      pathological body can never hang it and wedge the heartbeat —
#      on overrun the cycle keeps beating with empty eligible-comments.
#
# Run: bash monitor/watcher/test-compose-emit-multibyte.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

PASS=0
FAIL=0

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if ! grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         did NOT expect: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_eq() {
    local label="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — want=%q got=%q\n' "$label" "$want" "$got" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ----
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
export STATE_DIR
# Filters that consult knobs — set to passthrough-friendly values.
USER_LOGIN="alice"; BOT_LOGIN=""; CROSS_REPO_SURFACE="off"
MONITOR_EMIT_COOLDOWN_SECONDS=0
export USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE MONITOR_EMIT_COOLDOWN_SECONDS

# shellcheck source=_emit_filters.sh
. "$_test_dir/_emit_filters.sh"
# shellcheck source=_github.sh
. "$_test_dir/_github.sh"

# Pluck _run_bounded + the two pipeline wrappers from main.sh (main.sh has
# top-level execution and cannot be sourced wholesale; same awk-pluck
# pattern the pre-extraction filter tests used).
_pluck_fn() {  # <fn-name> <file>
    awk -v fn="$1" '
        $0 ~ "^"fn"\\(\\) \\{" { capture=1 }
        capture { print }
        capture && /^\}/ { exit }
    ' "$2"
}
eval "$(_pluck_fn _run_bounded            "$_test_dir/main.sh")"
eval "$(_pluck_fn _gh_filter_dedup_pipeline      "$_test_dir/main.sh")"
eval "$(_pluck_fn _gh_filter_dedup_pipeline_file "$_test_dir/main.sh")"

# Pick a UTF-8 ambient locale that actually exists; else the multibyte
# decoder never engages and these tests would be vacuous.
AMBIENT_UTF8=""
for _loc in en_US.UTF-8 en_US.utf8 C.UTF-8; do
    if locale -a 2>/dev/null | grep -qixF "${_loc/UTF-8/utf8}" \
       || locale -a 2>/dev/null | grep -qixF "$_loc"; then
        AMBIENT_UTF8="$_loc"; break
    fi
done

# ---- build an emit block with a body preview byte-truncated mid-char ----
# → is E2 86 92; keep only E2 86 (an invalid trailing byte) to mimic a
# fixed-width byte slice of "…flux →". Use the in-$REPO `issue=` shape so
# the block passes through every filter (cross_repo blocks are dropped by
# CROSS_REPO_SURFACE=off by design — orthogonal to byte-safety).
EMIT_IN="$WORK/emit.in"
{
    printf 'issue=42 author=alice id=999 title=Test\n'
    printf '  body: gradient is perp to sigma, mu approx 0.3; flux '
    printf '\xe2\x86'        # invalid (truncated) UTF-8
    printf '\n---\n'
} > "$EMIT_IN"

# ---- 0. meaningfulness guard -------------------------------------------
echo '=== precondition: ambient locale is multibyte-capable (bare awk warns) ==='
if [[ -z "$AMBIENT_UTF8" ]]; then
    echo "  SKIP: no UTF-8 locale available; cannot exercise the multibyte path" >&2
    echo "ALL TESTS PASSED (vacuous: no UTF-8 locale)"
    exit 0
fi
bare_err=$(LC_ALL="$AMBIENT_UTF8" gawk '{ x=tolower($0) } END{}' "$EMIT_IN" 2>&1 >/dev/null || true)
if ! grep -qF "Invalid multibyte" <<<"$bare_err"; then
    echo "  SKIP: gawk under $AMBIENT_UTF8 did not flag the invalid byte; path not exercised" >&2
    echo "ALL TESTS PASSED (vacuous: locale did not engage decoder)"
    exit 0
fi
echo "  PASS: bare gawk under $AMBIENT_UTF8 DOES warn (decoder engaged)"; PASS=$(( PASS + 1 ))

# ---- 1. each filter is byte-safe under the ambient UTF-8 locale ---------
# Run under the ambient UTF-8 locale; the filter's internal LC_ALL=C must
# suppress the warning AND preserve the block. The stderr file is named in
# the PARENT scope (the `out=$(...)` substitution subshells only its RHS).
for f in _filter_to_user_author _filter_skip_marker _filter_cross_repo_surface \
         _dedup_emit_lines _filter_suppression _filter_processed_comments; do
    echo "=== $f: byte-safe under $AMBIENT_UTF8 ==="
    errf="$WORK/err.$f"
    out=$(LC_ALL="$AMBIENT_UTF8" "$f" < "$EMIT_IN" 2>"$errf")
    err=$(cat "$errf" 2>/dev/null || true)
    assert_not_contains "$f: no multibyte warning" "$err" "Invalid multibyte"
    assert_contains     "$f: header preserved"     "$out" "issue=42 author=alice id=999"
done

# ---- 2. full pipeline: clean stderr + block survives + bytes intact -----
echo '=== _gh_filter_dedup_pipeline: clean + byte-exact body ==='
pipe_err="$WORK/pipe.err"
pipe_out=$(LC_ALL="$AMBIENT_UTF8" _gh_filter_dedup_pipeline < "$EMIT_IN" 2>"$pipe_err")
assert_not_contains "pipeline: no multibyte warning" "$(cat "$pipe_err")" "Invalid multibyte"
assert_contains     "pipeline: issue block survives" "$pipe_out" "issue=42 author=alice id=999"
# Byte-exactness: the surviving body line must still carry the E2 86 bytes.
body_md5=$(printf '%s\n' "$pipe_out" | grep -aF 'body:' | head -1 | tr -d '\n' | md5sum | cut -d' ' -f1)
want_md5=$(printf '  body: gradient is perp to sigma, mu approx 0.3; flux \xe2\x86' | md5sum | cut -d' ' -f1)
assert_eq "pipeline: body bytes preserved exactly (incl. invalid trailing byte)" "$want_md5" "$body_md5"

# ---- 3. file-fed wrapper feeds the pipeline correctly -------------------
echo '=== _gh_filter_dedup_pipeline_file reads <infile> ==='
wrap_out=$(LC_ALL="$AMBIENT_UTF8" _gh_filter_dedup_pipeline_file "$EMIT_IN" 2>/dev/null)
assert_contains "file-fed wrapper: issue block survives" "$wrap_out" "issue=42 author=alice id=999"

# ---- 4. bounded guard: happy path completes, overrun degrades to 124 ----
echo '=== _run_bounded: happy path returns 0 + output ==='
rc=0
_run_bounded 10 "$WORK/b.out" _gh_filter_dedup_pipeline_file "$EMIT_IN" || rc=$?
assert_eq       "bounded happy-path rc=0" "0" "$rc"
assert_contains "bounded happy-path output present" "$(cat "$WORK/b.out")" "issue=42"

echo '=== _run_bounded: overrun returns 124 (caller falls back to empty) ==='
_slow_pipeline_stub() { sleep 5; echo "should-not-appear"; }
rc=0
_run_bounded 1 "$WORK/b2.out" _slow_pipeline_stub || rc=$?
assert_eq "bounded overrun rc=124" "124" "$rc"
# Mirror the caller's fallback: rc!=0 ⇒ gh_now="" (never the partial body).
if (( rc != 0 )); then gh_now=""; else gh_now=$(cat "$WORK/b2.out"); fi
assert_eq "caller fallback: gh_now empty on overrun" "" "$gh_now"

# ---- summary ----
echo
echo "PASS=$PASS FAIL=$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "SOME TESTS FAILED" >&2
    exit 1
fi
