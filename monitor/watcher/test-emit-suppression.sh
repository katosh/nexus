#!/usr/bin/env bash
# Tests for the manual emit-suppression channel — the orchestrator's
# backup lever for re-surfacing comments. Two surfaces:
#
#   1. `_filter_suppression` (in _emit_filters.sh) — the last-hop awk
#      filter that drops `id=<N>` blocks whose `comment:<N>` entry
#      appears in `$STATE_DIR/emit-suppression.lines`.
#
#   2. `monitor/ng suppress-emit <id>` — the operator-facing verb that
#      appends to the suppression file and logs an action-log event.
#
# Run: bash monitor/watcher/test-emit-suppression.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)

PASS=0
FAIL=0

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
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
assert_file_contains() {
    local label="$1" path="$2" needle="$3"
    if [[ -f "$path" ]] && grep -qxF -- "$needle" "$path"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — file %q missing line %q\n' "$label" "$path" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_exit() {
    local label="$1" want_rc="$2" got_rc="$3"
    if [[ "$got_rc" == "$want_rc" ]]; then
        printf '  PASS: %s (rc=%s)\n' "$label" "$got_rc"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got rc=%s want rc=%s\n' "$label" "$got_rc" "$want_rc" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ----

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
mkdir -p "$STATE_DIR"
export STATE_DIR

# `_filter_suppression` lives in _emit_filters.sh (extracted from
# main.sh in the issue 180 S2 seam). The module is functions-only with
# no top-level state, so — unlike main.sh, which the pre-extraction
# version of this test had to awk-pluck functions out of — it can be
# sourced directly.
# shellcheck source=_emit_filters.sh
. "$_test_dir/_emit_filters.sh"

# ---- 1. file absent → passthrough --------------------------------------
echo '=== absent suppression file: passthrough ==='
rm -f "$STATE_DIR/emit-suppression.lines"
input=$'issue=1 id=100 author=alice\n  body: hello world\npr=42 id=200 author=alice\n  body: another\n'
out=$(printf '%s' "$input" | _filter_suppression)
assert_contains "issue line passes" "$out" "issue=1 id=100"
assert_contains "issue body passes" "$out" "body: hello world"
assert_contains "pr line passes"    "$out" "pr=42 id=200"
assert_contains "pr body passes"    "$out" "body: another"

# ---- 2. comment:<id> present → block dropped --------------------------
echo '=== comment:<id> in suppression file drops matching block ==='
printf 'comment:100\n' > "$STATE_DIR/emit-suppression.lines"
out=$(printf '%s' "$input" | _filter_suppression)
assert_not_contains "issue line dropped"      "$out" "issue=1 id=100"
assert_not_contains "issue body dropped"      "$out" "hello world"
assert_contains     "pr line still present"   "$out" "pr=42 id=200"
assert_contains     "pr body still present"   "$out" "another"

# ---- 3. multiple suppressed ids --------------------------------------
echo '=== multiple comment:<id> entries drop all matching ==='
printf 'comment:100\ncomment:200\n' > "$STATE_DIR/emit-suppression.lines"
out=$(printf '%s' "$input" | _filter_suppression)
assert_not_contains "issue line dropped"  "$out" "issue=1 id=100"
assert_not_contains "pr line dropped"     "$out" "pr=42 id=200"

# ---- 4. malformed lines tolerated -----------------------------------
echo '=== malformed lines (blank, leading whitespace, # comments) tolerated ==='
printf '\n  comment:100  \n# remove this later\n\ncomment:300\nrubbish\n' > "$STATE_DIR/emit-suppression.lines"
input3=$'issue=1 id=100 author=alice\n  body: blocked\npr=42 id=200 author=alice\n  body: passes\nissue=7 id=300 author=alice\n  body: also blocked\n'
out=$(printf '%s' "$input3" | _filter_suppression)
assert_not_contains "id=100 dropped (whitespace tolerated)" "$out" "issue=1 id=100"
assert_not_contains "id=300 dropped"                        "$out" "issue=7 id=300"
assert_contains     "id=200 still present (# line ignored)" "$out" "pr=42 id=200"

# ---- 5. signature: prefix reserved (no effect today) -----------------
echo '=== signature: prefix is reserved (ignored, future extension) ==='
printf 'signature:abcdef\ncomment:100\n' > "$STATE_DIR/emit-suppression.lines"
out=$(printf '%s' "$input" | _filter_suppression)
assert_not_contains "comment:100 still drops" "$out" "issue=1 id=100"
assert_contains     "non-comment-id passes"   "$out" "pr=42 id=200"

# ---- 6. id substring safety -----------------------------------------
# id=1001 should NOT be matched by a suppression entry for id=100.
# The token boundary check on the line shape protects against this.
echo '=== id substring not falsely matched ==='
printf 'comment:100\n' > "$STATE_DIR/emit-suppression.lines"
input6=$'issue=1 id=1001 author=alice\n  body: should pass\nissue=2 id=100 author=alice\n  body: should drop\n'
out=$(printf '%s' "$input6" | _filter_suppression)
assert_contains     "id=1001 (substring) passes" "$out" "id=1001"
assert_not_contains "id=100 dropped"             "$out" "id=100 author"

# ---- 7. integration with full _gh_filter_dedup_pipeline --------------
# Source main.sh's full pipeline by extracting all four filters + the
# pipeline wrapper, then run a realistic input through it.
echo '=== _gh_filter_dedup_pipeline drops suppressed entry ==='
USER_LOGIN="alice"
BOT_LOGIN=""
CROSS_REPO_SURFACE="off"
export USER_LOGIN BOT_LOGIN CROSS_REPO_SURFACE

# Pull the dependent filters from _github.sh. The pipeline-member
# helpers (`_dedup_emit_lines`, `_filter_processed_comments`,
# `_filter_emit_cooldown`, `_emit_cooldown_flush`) came in with the
# _emit_filters.sh source above. Only the wrapper itself —
# `_gh_filter_dedup_pipeline` — still lives in main.sh (heavy
# top-level state), so it alone keeps the awk-extract + eval trick.
. "$_test_dir/_github.sh"
for fn in _gh_filter_dedup_pipeline; do
    fn_def=$(awk -v fn="$fn" '
        $0 ~ "^" fn "\\(\\) \\{$" { capture=1 }
        capture { print; if ($0 == "}") capture=0 }
    ' "$_test_dir/main.sh")
    [[ -n "$fn_def" ]] || { echo "extract $fn failed" >&2; exit 1; }
    eval "$fn_def"
done
# Per-comment cooldown defaults to 300s, which would conflict with
# this suite's repeated runs of the same `id=X` through the pipeline.
# Disable it for the integration assertions below.
MONITOR_EMIT_COOLDOWN_SECONDS=0
export MONITOR_EMIT_COOLDOWN_SECONDS

printf 'comment:777\n' > "$STATE_DIR/emit-suppression.lines"
input7=$'issue=5 id=555 author=alice\n  body: keep this\nissue=8 id=777 author=alice\n  body: drop this via suppression\n'
out=$(printf '%s' "$input7" | _gh_filter_dedup_pipeline)
assert_contains     "non-suppressed surfaces"   "$out" "id=555"
assert_not_contains "suppressed entry dropped"  "$out" "id=777"

# ---- 8. ng suppress-emit verb ---------------------------------------
echo '=== ng suppress-emit appends comment:<id> + dedups ==='
# ng resolves STATE_DIR via NEXUS_STATE_DIR > NEXUS_ROOT > config > script-relative.
# Use NEXUS_STATE_DIR to pin without touching config.
SUPPRESS_FILE="$STATE_DIR/emit-suppression.lines"
rm -f "$SUPPRESS_FILE"
NG="$_repo_root/monitor/ng"
NEXUS_STATE_DIR="$STATE_DIR" "$NG" suppress-emit 12345 --reason "test" > "$WORK/ng-out.txt" 2>"$WORK/ng-err.txt"
ng_rc=$?
assert_exit "ng suppress-emit exits 0" 0 "$ng_rc"
assert_file_contains "comment:12345 appended" "$SUPPRESS_FILE" "comment:12345"

# Second call dedups (no duplicate line).
NEXUS_STATE_DIR="$STATE_DIR" "$NG" suppress-emit 12345 > /dev/null
line_count=$(grep -c '^comment:12345$' "$SUPPRESS_FILE")
if [[ "$line_count" == "1" ]]; then
    printf '  PASS: dedup on repeat suppress-emit (count=1)\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: dedup on repeat (got %s lines)\n' "$line_count" >&2
    FAIL=$(( FAIL + 1 ))
fi

# Non-numeric id is rejected.
NEXUS_STATE_DIR="$STATE_DIR" "$NG" suppress-emit "abc123" >/dev/null 2>"$WORK/ng-err2.txt"
bad_rc=$?
assert_exit "ng suppress-emit rejects non-numeric" 1 "$bad_rc"

# ---- 9. compose integration: ng suppress-emit + pipeline drops it ----
echo '=== suppress-emit-written entry is honoured by the pipeline ==='
NEXUS_STATE_DIR="$STATE_DIR" "$NG" suppress-emit 9999 --reason "compose-integration" >/dev/null
input9=$'issue=1 id=9999 author=alice\n  body: should be dropped\nissue=2 id=8888 author=alice\n  body: should surface\n'
out=$(printf '%s' "$input9" | _gh_filter_dedup_pipeline)
assert_not_contains "9999 dropped by pipeline" "$out" "id=9999"
assert_contains     "8888 surfaces"            "$out" "id=8888"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
