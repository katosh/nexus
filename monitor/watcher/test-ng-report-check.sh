#!/usr/bin/env bash
# Unit tests for `ng report-check` (cmd_report_check in monitor/ng).
#
# Run: bash monitor/watcher/test-ng-report-check.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build a minimal fake nexus tree (ng + stubbed
# config/load.sh), then synthesise reports with controlled defects
# and assert the verb's exit code + stderr against each defect.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NG_REAL="$_test_dir/../ng"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else printf '  FAIL: %s\n           expected: %s\n' "$label" "$needle" >&2; FAIL=$(( FAIL + 1 )); fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2; FAIL=$(( FAIL + 1 ))
    else printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 )); fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/config"
cp "$NG_REAL" "$FAKE_NEXUS/monitor/ng"
NG="$FAKE_NEXUS/monitor/ng"
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'default-org/default-repo' ;;
    github.user_login)  printf 'test-user' ;;
    monitor.report_min_chars) printf '%s' "${2:-500}" ;;
    *) [[ $# -ge 2 ]] && { printf '%s' "$2"; exit 0; } ; exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"

run_check() {
    local _out_var="$1" _err_var="$2" _rc_var="$3"; shift 3
    local _stdout _stderr _rc _out_tmp _err_tmp
    _out_tmp=$(mktemp); _err_tmp=$(mktemp)
    "$NG" report-check "$@" >"$_out_tmp" 2>"$_err_tmp"
    _rc=$?
    _stdout=$(<"$_out_tmp"); _stderr=$(<"$_err_tmp")
    rm -f "$_out_tmp" "$_err_tmp"
    printf -v "$_out_var" '%s' "$_stdout"
    printf -v "$_err_var" '%s' "$_stderr"
    printf -v "$_rc_var"  '%s' "$_rc"
}

# A complete report (≥500 body chars; all sections; valid frontmatter;
# no placeholders). Used as the baseline; modified per-test for the
# sad-path probes.
write_complete_report() {
    local path="$1"
    cat > "$path" <<'EOF'
---
project: nexus
date: 2026-05-10
session-id: 4e8f1c2b-3a91-4d77-b9e0-5f2d0a1c7e8a
window: foo-window
trigger: #42 (comment 9999)
status: completed
---

# Demonstration report (complete)

## Summary

Shipped the report-check verb and integrated it as a pre-flight in
ng wrap-up. Verb validates frontmatter, sections, body length, and
placeholder absence.

## What Was Done

- Added cmd_report_check to monitor/ng.
- Wired it into cmd_wrap_up at the start, before upload.
- Added 36 test assertions across multiple suites.
- Updated nexus.report skill with the schema.
- Updated nexus.worker-defaults skill with the report-init bullet.

## Current State

- Branch operator/ng-wrap-up-and-friction-fixes, four commits.
- Tests green across all watcher suites except test-emit-gate.sh
  which is a pre-existing failure on origin/main.
- PR your-org/nexus-code#4 carries every change.

## What Remains

- Address any follow-up review feedback on PR #4.
- Land round-4 changes once review clears.

## How to Resume

- git checkout operator/ng-wrap-up-and-friction-fixes
- bash monitor/watcher/test-ng-report-check.sh
- Read this report for context.
EOF
}

# ---- Test 1: complete report → exit 0 ----------------------------------

echo '=== complete report → exit 0 ==='
GOOD="$WORK/good.md"
write_complete_report "$GOOD"
run_check out err rc "$GOOD"
assert_eq        "exit 0 on complete report"          "$rc" "0"
assert_contains  "stdout reports OK"                  "$out" "OK"

# ---- Test 2: file missing → exit 2 ------------------------------------

echo '=== file missing → exit 2 ==='
run_check out err rc "$WORK/nope.md"
assert_eq        "exit 2 on missing file"             "$rc" "2"
assert_contains  "stderr names missing-file"          "$err" "missing"

# ---- Test 3: missing frontmatter → exit 1 -----------------------------

echo '=== missing frontmatter → exit 1 ==='
NOFM="$WORK/no-fm.md"
write_complete_report "$NOFM"
# Strip the frontmatter (first '---' to second '---' inclusive).
awk 'BEGIN{flag=0} /^---$/{flag++; next} flag>=2{print}' "$NOFM" > "$NOFM.tmp" && mv "$NOFM.tmp" "$NOFM"
run_check out err rc "$NOFM"
assert_eq        "exit 1 with no frontmatter"         "$rc" "1"
assert_contains  "stderr complains about frontmatter" "$err" "frontmatter"

# ---- Test 4: missing required field → exit 1 --------------------------

echo '=== frontmatter missing session-id → exit 1 ==='
NOSID="$WORK/no-sid.md"
write_complete_report "$NOSID"
sed -i '/^session-id:/d' "$NOSID"
run_check out err rc "$NOSID"
assert_eq        "exit 1 with missing session-id"     "$rc" "1"
assert_contains  "stderr names session-id"            "$err" "session-id"

# ---- Test 5: session-id = "unknown" → exit 1 --------------------------

echo '=== frontmatter session-id: unknown → exit 1 ==='
SUNK="$WORK/sid-unk.md"
write_complete_report "$SUNK"
sed -i 's/^session-id:.*/session-id: unknown/' "$SUNK"
run_check out err rc "$SUNK"
assert_eq        "exit 1 with session-id=unknown"     "$rc" "1"
assert_contains  "stderr names the unknown sentinel"  "$err" "unknown"

# ---- Test 6: status = invalid value → exit 1 --------------------------

echo '=== frontmatter status: bogus → exit 1 ==='
BAD_STATUS="$WORK/bad-status.md"
write_complete_report "$BAD_STATUS"
sed -i 's/^status:.*/status: half-done/' "$BAD_STATUS"
run_check out err rc "$BAD_STATUS"
assert_eq        "exit 1 with bad status value"       "$rc" "1"
assert_contains  "stderr names the canonical set"     "$err" "completed|partial|blocked"

# ---- Test 7: missing one section → exit 1 -----------------------------

echo '=== missing "## How to Resume" → exit 1 ==='
NOSEC="$WORK/no-section.md"
write_complete_report "$NOSEC"
# Strip from "## How to Resume" to EOF.
awk '/^## How to Resume/{flag=1} !flag{print}' "$NOSEC" > "$NOSEC.tmp" && mv "$NOSEC.tmp" "$NOSEC"
run_check out err rc "$NOSEC"
assert_eq        "exit 1 with missing section"        "$rc" "1"
assert_contains  "stderr names the missing section"   "$err" "How to Resume"

# ---- Test 8: body too short → exit 1 ----------------------------------

echo '=== body < 500 chars → exit 1 (default threshold) ==='
SHORT="$WORK/short.md"
cat > "$SHORT" <<'EOF'
---
project: nexus
date: 2026-05-10
session-id: 4e8f1c2b-3a91-4d77-b9e0-5f2d0a1c7e8a
window: foo
trigger: #1
status: partial
---

# tiny

## Summary

a

## What Was Done

a

## Current State

a

## What Remains

a

## How to Resume

a
EOF
run_check out err rc "$SHORT"
assert_eq        "exit 1 on too-short body"           "$rc" "1"
assert_contains  "stderr names body chars + threshold" "$err" \
                 "body too short"

# ---- Test 9: --allow-todo skips placeholder check, not other checks ---

echo '=== TODO present + --allow-todo → exit 0 ==='
TODO="$WORK/todo.md"
write_complete_report "$TODO"
# Insert a TODO line in body.
sed -i 's/Shipped the report-check verb/TODO: write summary/' "$TODO"
run_check out err rc "$TODO"
assert_eq        "exit 1 on TODO without --allow-todo" "$rc" "1"
assert_contains  "stderr flags TODO/FIXME"             "$err" "TODO"
run_check out err rc "$TODO" --allow-todo
assert_eq        "exit 0 with --allow-todo"           "$rc" "0"

# ---- Test 10: `_(fill in)_` from skeleton flagged ---------------------

echo '=== skeleton `_(fill in)_` placeholder flagged ==='
SKEL="$WORK/skel.md"
write_complete_report "$SKEL"
sed -i 's/Shipped the report-check verb/_(fill in)_/' "$SKEL"
run_check out err rc "$SKEL"
assert_eq        "exit 1 on skeleton placeholder"     "$rc" "1"
assert_contains  "stderr names the skeleton marker"   "$err" "_(fill in)_"

# ---- Test 11: --allow-todo flag accepted as no-op when nothing to skip

echo '=== --allow-todo on a complete report → exit 0 ==='
run_check out err rc "$GOOD" --allow-todo
assert_eq        "exit 0 on complete + --allow-todo"  "$rc" "0"

# ---- Test 12: MONITOR_REPORT_MIN_CHARS overrides config knob ---------

echo '=== MONITOR_REPORT_MIN_CHARS=2000 makes the complete report too short ==='
out=""; err=""; rc=""
out_tmp=$(mktemp); err_tmp=$(mktemp)
MONITOR_REPORT_MIN_CHARS=2000 "$NG" report-check "$GOOD" >"$out_tmp" 2>"$err_tmp"
rc=$?
out=$(<"$out_tmp"); err=$(<"$err_tmp"); rm -f "$out_tmp" "$err_tmp"
assert_eq        "exit 1 when threshold raised"       "$rc" "1"
assert_contains  "stderr names the higher threshold"  "$err" "< 2000"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
