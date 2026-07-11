#!/usr/bin/env bash
# Tests for monitor/reports-roll.sh — the monthly reports archiver with a
# ≥1-month safety buffer (issue #444).
#
# The load-bearing guarantee under test: a report is rolled into
# reports/YYYY-MM/ ONLY if it was created strictly BEFORE the first day of
# the PREVIOUS month. So the CURRENT month AND the trailing (previous)
# month always stay FLAT — an in-flight worker's report is days old at
# most and can NEVER be moved out from under it.
#
# Coverage:
#   1. Safety buffer — boundary proof. now=2026-07-15:
#        - 2026-05-31 (last day before the buffer)   -> ROLLS
#        - 2026-06-01 (first day of the buffer floor) -> STAYS FLAT
#        - 2026-06-30 (end of previous month)         -> STAYS FLAT
#        - 2026-07-15 (current month)                 -> STAYS FLAT
#      i.e. NOTHING newer than one full month back ever moves.
#   2. Bucketing by the report's own date + legacy/date-only filename
#      formats + project slugs that themselves contain underscores.
#   3. Malformed / undatable filenames are quarantined (left flat), never
#      rolled into a bogus bucket.
#   4. --dry-run touches nothing.
#   5. Idempotency — a second run is a clean no-op (rolls 0), and an
#      already-archived bucket file is never re-processed or clobbered.
#   6. January cutoff wrap — now=2026-01-10 keeps 2025-12 + 2026-01 flat
#      and rolls 2025-11.
#
# Run: bash monitor/watcher/test-reports-roll.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROLL="$_test_dir/../reports-roll.sh"

PASS=0
FAIL=0

assert_flat() {   # label, reports-dir, basename  → file is TOP-LEVEL flat
    local label="$1" dir="$2" base="$3"
    if [[ -f "$dir/$base" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (expected flat at %s/%s)\n' "$label" "$dir" "$base" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_bucket() { # label, reports-dir, YYYY-MM, basename → file is in bucket AND gone from flat
    local label="$1" dir="$2" bucket="$3" base="$4"
    if [[ -f "$dir/$bucket/$base" && ! -e "$dir/$base" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (expected %s/%s/%s, flat gone)\n' "$label" "$dir" "$bucket" "$base" >&2
        [[ -e "$dir/$base" ]] && printf '         still flat: %s/%s\n' "$dir" "$base" >&2
        [[ -f "$dir/$bucket/$base" ]] || printf '         missing bucket file: %s/%s/%s\n' "$dir" "$bucket" "$base" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {     # label, got, want
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (got %q want %q)\n' "$label" "$got" "$want" >&2
        FAIL=$((FAIL + 1))
    fi
}

mkdir_reports() { # make a fresh temp reports dir, print its path
    local t; t=$(mktemp -d)
    mkdir -p "$t/reports"
    printf '%s/reports' "$t"
}

# ---- 1 + 2 + 3: buffer boundary, bucketing, quarantine ---------------------
echo "== safety buffer + bucketing + quarantine (now=2026-07-15) =="
R=$(mkdir_reports)
: > "$R/nexus_2026-05-31_235959_last-day-before-buffer.md"   # ROLL  (2026-05)
: > "$R/nexus_2026-06-01_000000_first-day-of-buffer.md"      # KEEP  (buffer floor)
: > "$R/nexus_2026-06-30_120000_end-of-prev-month.md"        # KEEP  (2026-06)
: > "$R/nexus_2026-07-15_120000_current-month.md"            # KEEP  (2026-07)
: > "$R/nexus_2026-04-02_090000_older.md"                    # ROLL  (2026-04)
: > "$R/agent_sandbox_2026-04-15_legacy-notime.md"           # ROLL  (legacy no HHMMSS, project has _)
: > "$R/cleanup-pending-input_2026-05-05.md"                 # ROLL  (date-only slug)
: > "$R/nexus_2026-00-09_120000_malformed-month.md"          # QUARANTINE (month 00)
: > "$R/_otheruser47_reply_draft.md"                           # QUARANTINE (no date token)

out=$(bash "$ROLL" --reports-dir "$R" --now 2026-07-15 2>&1)
echo "$out" | sed 's/^/    /'

# THE safety-buffer assertions — the whole point of the feature.
assert_flat   "buffer floor (2026-06-01) stays flat"     "$R" "nexus_2026-06-01_000000_first-day-of-buffer.md"
assert_flat   "end of prev month (2026-06-30) stays flat" "$R" "nexus_2026-06-30_120000_end-of-prev-month.md"
assert_flat   "current month (2026-07-15) stays flat"    "$R" "nexus_2026-07-15_120000_current-month.md"
assert_bucket "last day before buffer (2026-05-31) rolls" "$R" "2026-05" "nexus_2026-05-31_235959_last-day-before-buffer.md"

# Bucketing by the report's own date, across filename formats.
assert_bucket "canonical filename rolls to its month"    "$R" "2026-04" "nexus_2026-04-02_090000_older.md"
assert_bucket "legacy no-HHMMSS (underscore project)"    "$R" "2026-04" "agent_sandbox_2026-04-15_legacy-notime.md"
assert_bucket "date-only slug rolls"                     "$R" "2026-05" "cleanup-pending-input_2026-05-05.md"

# Quarantine: malformed / undatable stay flat, never bucketed.
assert_flat   "malformed month (2026-00) quarantined flat" "$R" "nexus_2026-00-09_120000_malformed-month.md"
assert_flat   "no-date draft quarantined flat"           "$R" "_otheruser47_reply_draft.md"
if [[ ! -d "$R/2026-00" ]]; then
    printf '  PASS: no bogus 2026-00/ bucket created\n'; PASS=$((PASS + 1))
else
    printf '  FAIL: a 2026-00/ bucket was created\n' >&2; FAIL=$((FAIL + 1))
fi

# Summary line counts.
assert_eq "summary reports rolled=4" "$(echo "$out" | grep -oE 'rolled [0-9]+' | head -1)" "rolled 4"
assert_eq "summary kept-flat=3"      "$(echo "$out" | grep -oE 'kept-flat [0-9]+')" "kept-flat 3"
assert_eq "summary quarantined=2"    "$(echo "$out" | grep -oE 'quarantined [0-9]+')" "quarantined 2"

# ---- 4: --dry-run touches nothing -----------------------------------------
echo "== --dry-run is side-effect-free =="
R=$(mkdir_reports)
: > "$R/nexus_2026-04-02_090000_older.md"
: > "$R/nexus_2026-07-15_120000_current.md"
before=$(find "$R" | LC_ALL=C sort)
bash "$ROLL" --reports-dir "$R" --now 2026-07-15 --dry-run >/dev/null 2>&1
after=$(find "$R" | LC_ALL=C sort)
assert_eq "dry-run leaves the tree byte-identical" "$after" "$before"

# ---- 5: idempotency --------------------------------------------------------
echo "== idempotency: second run is a no-op, bucket file untouched =="
R=$(mkdir_reports)
: > "$R/nexus_2026-04-02_090000_older.md"
: > "$R/nexus_2026-07-15_120000_current.md"
bash "$ROLL" --reports-dir "$R" --now 2026-07-15 >/dev/null 2>&1
# Stamp the already-archived file so we can detect any illicit re-touch.
echo "SENTINEL" > "$R/2026-04/nexus_2026-04-02_090000_older.md"
out2=$(bash "$ROLL" --reports-dir "$R" --now 2026-07-15 2>&1)
assert_eq "second run rolls 0" "$(echo "$out2" | grep -oE 'rolled [0-9]+' | head -1)" "rolled 0"
assert_eq "archived bucket file left untouched" \
    "$(cat "$R/2026-04/nexus_2026-04-02_090000_older.md")" "SENTINEL"
tree_after=$(find "$R" -type f | LC_ALL=C sort)
bash "$ROLL" --reports-dir "$R" --now 2026-07-15 >/dev/null 2>&1
assert_eq "third run: tree stable" "$(find "$R" -type f | LC_ALL=C sort)" "$tree_after"

# ---- 6: January cutoff wrap ------------------------------------------------
echo "== January cutoff wrap (now=2026-01-10 → keep 2025-12 + 2026-01) =="
R=$(mkdir_reports)
: > "$R/nexus_2025-11-30_120000_two-months-back.md"   # ROLL  (2025-11)
: > "$R/nexus_2025-12-01_000000_prev-month-floor.md"  # KEEP  (buffer floor, Dec)
: > "$R/nexus_2026-01-05_120000_current.md"           # KEEP  (2026-01)
bash "$ROLL" --reports-dir "$R" --now 2026-01-10 >/dev/null 2>&1
assert_bucket "Nov rolls across the year boundary" "$R" "2025-11" "nexus_2025-11-30_120000_two-months-back.md"
assert_flat   "Dec (prev month) stays flat"        "$R" "nexus_2025-12-01_000000_prev-month-floor.md"
assert_flat   "Jan (current month) stays flat"     "$R" "nexus_2026-01-05_120000_current.md"

# ---- summary ---------------------------------------------------------------
echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d/%d)\n' "$PASS" "$((PASS + FAIL))"
    exit 0
else
    printf 'TESTS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
    exit 1
fi
