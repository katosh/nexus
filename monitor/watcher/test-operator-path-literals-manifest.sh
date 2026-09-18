#!/usr/bin/env bash
# test-operator-path-literals-manifest.sh — enforce the recorded boundary for
# operator-specific absolute paths in installable docs and templates
# (your-org/nexus-code#1275, #1174).
#
# WHAT THIS BUYS. The class had two instances in two weeks and both were found
# by a person reading a file. The consequence of a miss is an ABSENCE — a line
# pasted onto another operator's host silently arms nothing — so nothing
# downstream ever disagrees. A red here is the only mechanism that turns
# "someone notices" into a signal.
#
# THE POSITIVE CONTROLS ARE THE POINT, not the set comparison. A guard never
# seen fail is not evidence, and a manifest that matches a scan proves only
# that two things agree. So this suite drives the REAL classifier against a
# planted fixture repo and requires it to (a) catch #1275's actual historical
# defect, (b) leave the CORRECT general forms alone, and (c) ignore generic
# container accounts. (b) matters as much as (a): a guard that flagged
# `<YOUR_NEXUS_ROOT>` or `$USER` would be demanding the removal of the fix.
set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
GEN="$_test_dir/operator-path-literals.sh"
MAN="$_test_dir/operator-path-literals.manifest"

# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

for f in "$GEN" "$MAN"; do
    [[ -r "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

# shellcheck disable=SC1091
. "$(cd "$_test_dir/.." && pwd)/_guard_population.sh"
gp_population() {
    bash "$GEN" --population    # the generator's OWN declaration, never a copy
    printf '%s\n' "$GEN"
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-opl-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
echo "=== the instrument is not vacuous ==="
# A classifier that silently returned nothing would make the set comparison
# below pass by having nothing to compare — the #618 silent-zero shape, inside
# the probe. A FLOOR, well under the true count, is asserted first.
bash "$GEN" > "$WORK/live.tsv" 2>/dev/null
n_live=$(command grep -c . "$WORK/live.tsv" || true)
if (( n_live >= 4 )); then
    pass "the classifier enumerated a plausible population ($n_live rows)"
else
    fail "the classifier returned $n_live rows — below the floor; every comparison below would be vacuous"
fi

command grep -vE '^[[:space:]]*(#|$)' "$MAN" > "$WORK/rec.tsv" || true
n_rec=$(command grep -c . "$WORK/rec.tsv" || true)
if (( n_rec >= 4 )); then
    pass "the manifest records a plausible population ($n_rec rows)"
else
    fail "the manifest holds $n_rec rows — below the floor"
fi

# ---------------------------------------------------------------------------
echo "=== the live tree matches the recorded boundary, BOTH directions ==="
LC_ALL=C sort "$WORK/live.tsv" > "$WORK/live.k"
LC_ALL=C sort "$WORK/rec.tsv"  > "$WORK/rec.k"
if added=$(comm -23 "$WORK/live.k" "$WORK/rec.k") && [[ -z "$added" ]]; then
    pass "no unrecorded operator-path literal in an installable doc/template"
else
    fail "UNRECORDED operator-path literal(s) — a doc or template gained a per-reader absolute path:
$added
  Run: bash monitor/watcher/operator-path-literals.sh --detail
  Then read the manifest header: a per-READER path is the #1275 defect and must
  be written as a general form (<YOUR_NEXUS_ROOT>, \$USER), NOT recorded here."
fi
if removed=$(comm -13 "$WORK/live.k" "$WORK/rec.k") && [[ -z "$removed" ]]; then
    pass "no stale manifest row"
else
    fail "STALE manifest row(s) — a literal was removed or a count dropped (this is good news; regenerate):
$removed"
fi

# ---------------------------------------------------------------------------
echo "=== POSITIVE CONTROL: the guard catches #1275's actual historical defect ==="
# The fixture is a real git repo, because the classifier's population is
# `git ls-files` — a plain directory would enumerate nothing and every
# assertion below would pass vacuously in the silent-zero shape.
FIX="$WORK/fx"
mkdir -p "$FIX/monitor"
git -C "$FIX" init -q 2>/dev/null
# Never write the operator's GLOBAL git config from a probe — it IS writable
# here and nothing validates a commit's author (your-org/nexus-code#1244).
git -C "$FIX" config --local user.email 'fixture@invalid'
git -C "$FIX" config --local user.name  'fixture'

# The README snippet EXACTLY as it shipped before #1275 was fixed.
cat > "$FIX/monitor/README.md" <<'PLANT'
# fixture
  ```sh
  # nexus cold-boot recovery (idempotent, debounced, non-blocking)
  [ -x /shared/your-lab-m/user/operator/nexus/monitor/boot-recover.sh ] && \
      /shared/your-lab-m/user/operator/nexus/monitor/boot-recover.sh >/dev/null 2>&1 || true
  ```
PLANT
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" commit -qm plant >/dev/null 2>&1

planted=$(OPL_REPO_ROOT="$FIX" bash "$GEN" 2>/dev/null || true)
# A HERESTRING, not a pipe: `grep -q` exits on its first match and SIGPIPEs
# the writer, and this suite runs under `pipefail` — the #622 early-exit-reader
# hazard, which test-sigpipe-assertion-lint.sh flagged here. A herestring is a
# redirect from a temp file, so there is no reader to close a pipe early.
if command grep -q '^monitor/README\.md	fh-user	2$' <<< "$planted"; then
    pass "the pre-#1275 README snippet is caught, with the right family and count (2)"
else
    fail "the guard did NOT catch #1275's own defect — it is not evidence of anything. Got:
$planted"
fi

# ---------------------------------------------------------------------------
echo "=== POSITIVE CONTROL (inverse): the CORRECT general forms are NOT flagged ==="
# A guard that flagged the remedy would demand its removal. Both spellings the
# repo actually settled on must pass clean.
cat > "$FIX/monitor/README.md" <<'CLEAN'
# fixture
  ```sh
  [ -x <YOUR_NEXUS_ROOT>/monitor/boot-recover.sh ] && \
      <YOUR_NEXUS_ROOT>/monitor/boot-recover.sh >/dev/null 2>&1 || true
  ```
  export NEXUS_ROOT=/shared/your-lab-m/user/$USER/nexus
CLEAN
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" commit -qm clean >/dev/null 2>&1
clean_out=$(OPL_REPO_ROOT="$FIX" bash "$GEN" 2>/dev/null || true)
if [[ -z "$clean_out" ]]; then
    pass "<YOUR_NEXUS_ROOT> and \$USER general forms are not flagged"
else
    fail "the guard flagged a CORRECT general form — it would demand removal of the fix. Got:
$clean_out"
fi

# ---------------------------------------------------------------------------
echo "=== POSITIVE CONTROL: generic container/CI accounts carry no operator identity ==="
cat > "$FIX/monitor/README.md" <<'GENERIC'
# fixture
  /home/runner/work/repo
  /home/ubuntu/thing
GENERIC
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" commit -qm generic >/dev/null 2>&1
gen_out=$(OPL_REPO_ROOT="$FIX" bash "$GEN" 2>/dev/null || true)
if [[ -z "$gen_out" ]]; then
    pass "/home/runner and /home/ubuntu are excluded (same on every host, so no layout leaks)"
else
    fail "a generic account was flagged as an operator identity. Got:
$gen_out"
fi

# ---------------------------------------------------------------------------
echo "=== the guard is keyed on the SHAPE, not on THIS operator's path ==="
# #1275 named this trap in advance: a guard keyed on `/shared/your-lab-m/user/
# operator/` is green for every other operator BY CONSTRUCTION. A foreign
# operator's literal, on a foreign lab and a foreign host, must still be red.
cat > "$FIX/monitor/README.md" <<'FOREIGN'
# fixture
  [ -x /shared/scratch/otherlab_x/user/someone/nexus/monitor/boot-recover.sh ] && :
  /Users/someone/nexus/monitor/boot-recover.sh
FOREIGN
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" commit -qm foreign >/dev/null 2>&1
foreign_out=$(OPL_REPO_ROOT="$FIX" bash "$GEN" 2>/dev/null || true)
if command grep -q '^monitor/README\.md	fh-user	1$' <<< "$foreign_out" \
   && command grep -q '^monitor/README\.md	macos-user	1$' <<< "$foreign_out"; then
    pass "a FOREIGN operator's path (different lab, different tier, and a macOS home) is red too"
else
    fail "the guard is keyed on this operator's literal path — green for everyone else by construction. Got:
$foreign_out"
fi

# ---------------------------------------------------------------------------
echo "=== POTENCY CONTROL: the assets/ exclusion is ROOT-anchored and covers NOTHING else ==="
# An exclusion is a NARROWING of a guard, so the only review question is
# whether it narrowed more than it meant (your-org/nexus-code#1457). Three
# plants in ONE fixture commit, all carrying the SAME operator-path literal, so
# the only variable is the PATH:
#   assets/reports/<report>.md   a wrap-up RECORDING at the root-anchored
#                                asset mount — must be OUT of population;
#   docs/assets.md               a doc surface whose NAME says assets — IN;
#   monitor/assets/README.md     a non-root `assets/` SEGMENT           — IN.
# Without the last two this suite would certify "the lint is quieter" as "the
# lint is correct". The root-anchored plant is the negative arm; the two
# doc-surface plants are the positive arm, and both must red with the right
# family and count — an exact-set comparison, not a membership test, so an
# extra or missing row fails.
rm -f "$FIX/monitor/README.md"
mkdir -p "$FIX/assets/reports" "$FIX/docs" "$FIX/monitor/assets"
for plant in assets/reports/worker_2026-01-01_000000_slug.md docs/assets.md monitor/assets/README.md; do
    cat > "$FIX/$plant" <<'RECORD'
# fixture
Report written at /shared/your-lab-m/user/operator/nexus/reports/ on this host.
RECORD
done
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" commit -qm assets-scope >/dev/null 2>&1
# The plant must be TRACKED, or an absence below is a false zero (#1054).
if [[ "$(git -C "$FIX" ls-files -- 'assets/reports/worker_2026-01-01_000000_slug.md')" != 'assets/reports/worker_2026-01-01_000000_slug.md' ]]; then
    echo "  fixture error: the assets/ plant is not tracked — the negative arm below would pass vacuously" >&2
    exit 97
fi
scope_out=$(OPL_REPO_ROOT="$FIX" bash "$GEN" 2>/dev/null || true)
if ! command grep -q '^assets/' <<< "$scope_out"; then
    pass "a report under the root-anchored assets/ is OUT of population (a recording, not a doc surface)"
else
    fail "the assets/ exclusion did not take — a wrap-up recording is still flagged. Got:
$scope_out"
fi
scope_want=$(printf '%s\n' \
    'docs/assets.md	fh-user	1' \
    'monitor/assets/README.md	fh-user	1')
if [[ "$scope_out" == "$scope_want" ]]; then
    pass "the SAME literal outside assets/ still reds — docs/assets.md and monitor/assets/README.md, exact set"
else
    fail "the exclusion narrowed MORE than assets/ — a doc surface with an operator path is no longer caught. Want:
$scope_want
  Got:
$scope_out"
fi

# 2 vacuity floors + 2 set-difference directions + 1 historical positive control
# + 1 inverse control (the remedy must NOT be flagged) + 1 generic-account
# exclusion + 1 foreign-operator shape control + 2 assets/-scope potency
# controls (the exclusion covers the root-anchored assets/, and nothing else).
#
# Reconciling against a DECLARED total is what catches an assertion that never
# executed (your-org/nexus-code#996) — a suite that silently ran 6 of 8 reports
# a green shaped exactly like a real one.
EXPECTED=$(( 2 + 2 + 1 + 1 + 1 + 1 + 2 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
