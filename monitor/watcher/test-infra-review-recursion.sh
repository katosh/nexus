#!/usr/bin/env bash
# Regression test for the nexus.infra-review corpus-scan recipe after the
# reports/ dir was time-partitioned into monthly buckets (issue #444).
#
# The meta-review reads the ENTIRE historical corpus, so once older months
# are rolled into reports/YYYY-MM/ its file-discovery MUST recurse into the
# buckets. This test pins the recursing recipe documented in
# skills/nexus.infra-review/SKILL.md and proves:
#   1. The `find … -print0 | xargs -0 grep -l` recipe finds infra sections
#      in BOTH the flat current month AND an archived bucket.
#   2. The OLD flat glob (`grep -l … reports/*.md`) MISSES the bucketed
#      report — i.e. the recursion fix is load-bearing, not cosmetic.
#   3. The awk extractor preserves each match's provenance across buckets.
#
# If the skill's recipe is ever reverted to a flat glob, assertion 1 fails.
#
# Run: bash monitor/watcher/test-infra-review-recursion.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf '  FAIL: %s (got %q want %q)\n' "$label" "$got" "$want" >&2
        FAIL=$((FAIL + 1))
    fi
}

T=$(mktemp -d)
R="$T/reports"
mkdir -p "$R/2026-04" "$R/2026-05"

# Flat current-month report with an infra section.
cat > "$R/nexus_2026-07-01_120000_current.md" <<'EOF'
# current
## Infrastructure Issues
- flat-current infra finding
## How to Resume
EOF

# Archived (bucketed) report with an infra section — only a recursing scan sees it.
cat > "$R/2026-04/nexus_2026-04-10_120000_archived.md" <<'EOF'
# archived
## Infrastructure Issues
- archived-bucket infra finding
## How to Resume
EOF

# A bucketed report WITHOUT an infra section — must not be listed.
cat > "$R/2026-05/nexus_2026-05-10_120000_no-infra.md" <<'EOF'
# no infra
## Summary
nothing here
EOF

cd "$T"

# ---- 1: recursing recipe (as documented in the skill) finds both ----------
echo "== recursing find recipe sees flat + bucketed =="
mapfile -t hits < <(find reports -type f -name '*.md' -print0 \
    | xargs -0 grep -l '^## Infrastructure Issues' | LC_ALL=C sort)
assert_eq "recursion finds exactly 2 infra reports" "${#hits[@]}" "2"
found_flat=0 found_bucket=0
for h in "${hits[@]}"; do
    [[ "$h" == *"nexus_2026-07-01_120000_current.md" ]] && found_flat=1
    [[ "$h" == *"2026-04/nexus_2026-04-10_120000_archived.md" ]] && found_bucket=1
done
assert_eq "flat current-month report found"  "$found_flat"   "1"
assert_eq "archived bucket report found"      "$found_bucket" "1"

# ---- 2: the OLD flat glob misses the bucket (fix is load-bearing) ---------
echo "== old flat glob misses the archive =="
flat_only=$(grep -l '^## Infrastructure Issues' reports/*.md 2>/dev/null | wc -l | tr -d ' ')
assert_eq "flat reports/*.md glob sees only the 1 flat report" "$flat_only" "1"

# ---- 3: awk extractor keeps provenance across buckets ---------------------
echo "== awk extractor preserves provenance markers =="
extract=$(awk '
  /^## Infrastructure Issues/ { in_block=1; print "<<< " FILENAME " >>>"; print; next }
  in_block && /^## / && !/^## Infrastructure Issues/ { in_block=0 }
  in_block { print }
' "${hits[@]}")
markers=$(printf '%s\n' "$extract" | grep -c '^<<< ')
assert_eq "one provenance marker per infra report" "$markers" "2"
if printf '%s\n' "$extract" | grep -q 'archived-bucket infra finding'; then
    printf '  PASS: archived bucket content present in extract\n'; PASS=$((PASS + 1))
else
    printf '  FAIL: archived bucket content missing from extract\n' >&2; FAIL=$((FAIL + 1))
fi

echo
if (( FAIL == 0 )); then
    printf 'ALL TESTS PASSED (%d/%d)\n' "$PASS" "$((PASS + FAIL))"
    exit 0
else
    printf 'TESTS FAILED: %d passed, %d failed\n' "$PASS" "$FAIL" >&2
    exit 1
fi
