#!/usr/bin/env bash
# test-early-exit-reader-manifest.sh — the early-exit-reader boundary is
# CHECKED, not asserted (your-org/nexus-code#682).
#
# Run: bash monitor/watcher/test-early-exit-reader-manifest.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# WHAT THIS IS FOR. `#622` converted one early-exit reader (`| grep -q`) and
# gave it a lint. `#682` asks about the others — `head`, `grep -m`, `sed …q`,
# `awk …exit` — and its own framing is the reason this is a manifest rather
# than a conversion: *"classify before converting; churning benign sites costs
# review attention."* The raw grep counts behind the issue (`head` 197,
# `awk` 143, `sed -n` 54, `grep -m` 1) are not a defect count, and acting on
# them would have produced hundreds of diffs with almost no hazard behind them.
#
# So the deliverable is a BOUNDARY: the population is enumerated on a declared
# axis (see `early-exit-readers.sh`), recorded in
# `early-exit-readers.manifest`, and this suite fails when the two disagree.
# A newly-added early-exit reader goes red until somebody classifies it, and
# nobody has to trust a number in a comment.
#
# NON-VACUITY — the failure mode a manifest test invites is a classifier that
# silently finds nothing, against a manifest regenerated from that same
# nothing: two zeros agreeing perfectly. Guarded four ways:
#   * the manifest's total is PINNED against a floor, so an empty classifier
#     cannot agree with an empty manifest;
#   * a POSITIVE control — a planted file containing each of the four reader
#     kinds — must be classified, proving the classifier still fires;
#   * a NEGATIVE control — a planted file containing draining readers
#     (`| cat`, `| sed -n …p`, bare `| awk '{print}'`, `| sort`) and an
#     early-exit reader in a file WITHOUT `pipefail` — must produce nothing,
#     proving the axis's filters are load-bearing rather than decorative;
#   * `sed-q`'s real-tree count of ZERO is asserted as a MEASURED result, with
#     the positive control proving the `sed …q` arm can fire at all. A zero
#     nobody can distinguish from a broken arm is exactly this repo's dominant
#     defect class.
#
# COVERAGE BOUNDARY: this checks the POPULATION, not the verdict on any site.
# It says "these are the places a reviewer must look"; it does not say any of
# them is a live bug. Readers reached via `xargs`, via a variable holding the
# command name, or in shell outside `monitor/` are off the axis and are not
# claimed about — stated in the classifier header too, so the two cannot drift.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
CLASSIFIER="$_test_dir/early-exit-readers.sh"
MANIFEST="$_test_dir/early-exit-readers.manifest"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
#
# What this guard reads, asked of the CLASSIFIER rather than restated here,
# so the advertised population is the one that is actually walked. The
# manifest is part of it: this suite compares the classifier against that
# file, so an edit to either moves the verdict.
. "$_test_dir/../_guard_population.sh"
gp_population() {
    bash "$CLASSIFIER" --population
    printf '%s\n' "$CLASSIFIER" "$MANIFEST"
}
gp_handle "$@"

REAL_GREP=$(command -v grep 2>/dev/null || true)
[[ -x "$REAL_GREP" ]] || REAL_GREP=/bin/grep

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
    else printf '  FAIL: %s\n           expected: %s\n           in: %s\n' "$label" "$needle" "$hay" >&2; FAIL=$(( FAIL + 1 )); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- Test 1: the classifier and the manifest exist and are non-trivial ----
echo '=== Test 1: manifest is present and non-trivial ==='
[[ -x "$CLASSIFIER" || -r "$CLASSIFIER" ]] \
    && { printf '  PASS: %s\n' "classifier present"; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: %s\n' "classifier missing at $CLASSIFIER" >&2; FAIL=$(( FAIL + 1 )); }
[[ -r "$MANIFEST" ]] \
    && { printf '  PASS: %s\n' "manifest present"; PASS=$(( PASS + 1 )); } \
    || { printf '  FAIL: %s\n' "manifest missing at $MANIFEST" >&2; FAIL=$(( FAIL + 1 )); }

man_rows=$("$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" -c . || true)
man_total=$("$REAL_GREP" -v '^#' "$MANIFEST" | awk -F'\t' '{ t += $4 } END { print t + 0 }')
# A floor, not an equality: the repo grows, and a test that goes red on every
# added `| head` in a new test file would be regenerated without being read.
assert_gt "manifest has rows"                 "$man_rows"  "40"
assert_gt "manifest accounts for real sites"  "$man_total" "100"

# ---- Test 2: THE BOUNDARY — classifier output == manifest ---------------
echo '=== Test 2: the live tree matches the recorded boundary ==='
live="$WORK/live.tsv"
# LC_ALL=C pinned here so this output doubles as one half of Test 5b's locale
# comparison. The classifier walks ~400 files, so a full-corpus invocation is
# the suite's dominant cost; reusing this one keeps 5b a genuine whole-corpus
# check instead of paying for a third walk.
LC_ALL=C bash "$CLASSIFIER" "$REPO_ROOT" > "$live" 2>"$WORK/live.err"
rc=$?
assert_eq "classifier exits 0" "$rc" "0"
recorded="$WORK/recorded.tsv"
"$REAL_GREP" -v '^#' "$MANIFEST" | "$REAL_GREP" . > "$recorded" || true

if diff -u "$recorded" "$live" > "$WORK/diff.txt" 2>&1; then
    printf '  PASS: %s\n' "live tree matches early-exit-readers.manifest"; PASS=$(( PASS + 1 ))
else
    {
        printf '  FAIL: the early-exit-reader population changed.\n'
        printf '        A reader that can close a pipe EARLY was added or removed.\n'
        printf '        Regenerating the manifest is NOT the fix — decide which it is:\n'
        printf '          + a NEW site: is the pipeline status consumed (if / && / set -e /\n'
        printf '            a captured $?)? Then the writer'"'"'s EPIPE can invert the verdict\n'
        printf '            under pipefail — that is #622 with a different reader.\n'
        printf '          - a REMOVED site: good. Regenerate and say so.\n'
        printf '        Regenerate with:\n'
        printf '          bash monitor/watcher/early-exit-readers.sh > /tmp/rows.tsv\n'
        printf '        Diff (recorded vs live):\n'
        sed -n '1,60p' "$WORK/diff.txt"
    } >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 3: POSITIVE control — every reader kind is still detectable ----
# Without this, a classifier whose regexes all stopped matching would agree
# with a manifest regenerated from the same silence.
echo '=== Test 3: positive control — all four reader kinds classify ==='
FIX="$WORK/fixture"
mkdir -p "$FIX/monitor"
git -C "$FIX" init -q 2>/dev/null
# The fixture's pipelines are COMPOSED at runtime rather than written as a
# heredoc. This file is itself git-tracked under monitor/ and sets pipefail, so
# a literal `… | head -1` in a heredoc here would be classified as a real site
# in the real tree — the suite would enter its own manifest, and `sed-q`'s
# measured zero (Test 5) would become 1 purely because the test that proves the
# arm works contains an example of it. Self-reference is a hazard for any lint
# whose corpus includes itself; composing the reader token out of a variable
# removes it at the source instead of carving out an exclusion rule that
# something else could later hide behind.
{
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    i=0
    for reader in 'head -1' 'grep -m1 x' "sed -n '1p;q'" "awk '{ print; exit }'"; do
        i=$(( i + 1 ))
        printf 'v%d=$(printf %s | %s)\n' "$i" "'x\\n'" "$reader"
    done
} > "$FIX/monitor/pos.sh"
git -C "$FIX" add -A >/dev/null 2>&1
pos=$(bash "$CLASSIFIER" "$FIX" 2>/dev/null)
for k in head grep-m sed-q awk-exit; do
    assert_contains "positive control: '$k' is classified" "$pos" "$k"
done

# ---- Test 4: NEGATIVE control — the axis filters are load-bearing --------
# Draining readers must NOT be flagged (that is the whole point of #682:
# `| sed -n …p` and a bare `| awk` read to EOF and cannot SIGPIPE anything),
# and an early-exit reader in a file WITHOUT pipefail must NOT be flagged
# (without pipefail the reader's exit cannot become the pipeline's status).
echo '=== Test 4: negative control — draining readers and no-pipefail excluded ==='
cat > "$FIX/monitor/neg.sh" <<'NEG'
#!/usr/bin/env bash
set -euo pipefail
a=$(printf 'x\n' | cat)
b=$(printf 'x\n' | sed -n 's/x/y/p')
c=$(printf 'x\n' | awk '{ print }')
d=$(printf 'x\n' | sort)
e=$(printf 'x\n' | grep x)
NEG
# Composed, not a heredoc, for the same self-reference reason as pos.sh above:
# THIS file sets pipefail, so a literal early-exit reader anywhere in it —
# including inside a heredoc that is only ever written to a fixture — is a real
# site on the declared axis. (It was: the first version of this suite entered
# its own manifest twice, once from each control.)
{
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf 'v=$(printf %s | %s)\n' "'x\\n'" 'head -1'
} > "$FIX/monitor/nopf.sh"
git -C "$FIX" add -A >/dev/null 2>&1
all=$(bash "$CLASSIFIER" "$FIX" 2>/dev/null)
neg_hits=$(printf '%s\n' "$all" | "$REAL_GREP" -c 'monitor/neg\.sh' || true)
nopf_hits=$(printf '%s\n' "$all" | "$REAL_GREP" -c 'monitor/nopf\.sh' || true)
assert_eq "draining readers are NOT flagged"                  "$neg_hits"  "0"
assert_eq "a file without pipefail is NOT on the axis"        "$nopf_hits" "0"
# ...and the positive file still IS, in the same run — so the two zeros above
# are the filters working, not the classifier having died.
pos_hits=$(printf '%s\n' "$all" | "$REAL_GREP" -c 'monitor/pos\.sh' || true)
assert_gt "the positive file is still classified in the SAME run" "$pos_hits" "0"

# ---- Test 5: sed-q's zero is a measured result, not a broken arm ---------
echo '=== Test 5: sed-q is genuinely absent from the real tree ==='
real_sedq=$(awk -F'\t' '$2 == "sed-q" { n++ } END { print n + 0 }' "$recorded")
assert_eq "no '| sed …q' site exists in the repo" "$real_sedq" "0"
# Test 3 already proved the sed-q arm CAN fire; asserting both is what makes
# this zero mean "measured absent" rather than "never looked".
assert_contains "…and the sed-q arm demonstrably fires when one exists" "$pos" "sed-q"

# ---- Test 4b: a SOURCED library inherits its sourcer's pipefail ----------
# The skeptic's F5, and the reason this assertion exists rather than a comment:
# the first version tested `pipefail` in the file itself, so
# `monitor/watcher/_lib.sh` — sourced 14× by `main.sh`, which sets pipefail, and
# carrying live on-axis sites at `:1226` and `:1498` — had ZERO manifest rows.
# Appending a real `sed -n '1p;q'` to it left the total unchanged at 192. A
# manifest that cannot enumerate a live on-axis site is a blind spot, not a
# boundary. The repo already NAMED this gap (`_lib.sh:2787-2793`, "every library
# that INHERITS it … was invisible to that audit") — #682 inherited #622's
# filter and reproduced #622's blind spot.
#
# Asserted as a PAIR, because "include sourced libraries" is trivially satisfied
# by including everything: the inherited lib must be IN, and an unsourced lib
# with no pipefail of its own must stay OUT.
echo '=== Test 4b: pipefail is inherited through `source`, and only through it ==='
{
    printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "$(dirname "$0")/_inherited.sh"\n'
} > "$FIX/monitor/sourcer.sh"
{
    printf '#!/usr/bin/env bash\n# no pipefail of its own — it runs inside the sourcer'"'"'s options\n'
    printf 'w=$(printf %s | %s)\n' "'x\\n'" 'head -1'
} > "$FIX/monitor/_inherited.sh"
{
    printf '#!/usr/bin/env bash\n# no pipefail, and nothing sources it\n'
    printf 'w=$(printf %s | %s)\n' "'x\\n'" 'head -1'
} > "$FIX/monitor/_orphan.sh"
git -C "$FIX" add -A >/dev/null 2>&1
inh=$(bash "$CLASSIFIER" "$FIX" 2>/dev/null)
inh_hits=$(printf '%s\n' "$inh" | "$REAL_GREP" -c 'monitor/_inherited\.sh' || true)
orp_hits=$(printf '%s\n' "$inh" | "$REAL_GREP" -c 'monitor/_orphan\.sh'    || true)
assert_gt "a sourced library INHERITS pipefail and is on the axis" "$inh_hits" "0"
assert_eq "an unsourced library with no pipefail stays OFF the axis" "$orp_hits" "0"
# And the real instance the skeptic found, pinned by name so a regression in
# the closure cannot quietly drop the whole watcher helper set again.
assert_gt "the real _lib.sh is enumerated (it was invisible before)" \
    "$("$REAL_GREP" -c '^monitor/watcher/_lib\.sh' "$MANIFEST" || true)" "0"

# ---- Test 5b: the classifier is LOCALE-STABLE ---------------------------
# A manifest is a BYTE comparison, so a locale-dependent sort makes it valid
# only on the machine that generated it. Not hypothetical: the first version
# sorted in the ambient locale, and `en_US.utf8` collation ignores a leading
# `_` — so `monitor/_remote_lib.sh` sorted among the `c`s locally and first in
# CI. Same 91 rows, different ORDER: green on the author's box, red in all four
# CI cells. Pinned here so the `LC_ALL=C` cannot be dropped silently.
echo '=== Test 5b: classifier output is byte-identical across locales ==='
loc_b=$(LC_ALL=en_US.utf8 bash "$CLASSIFIER" "$REPO_ROOT" 2>/dev/null)
assert_eq "C and en_US.utf8 produce identical output" "$(cat "$live")" "$loc_b"

# ---- Test 6: the prod/test split is populated both ways ------------------
# #682's useful subset is production code; a scope column that silently
# collapsed to one value would hide exactly that.
echo '=== Test 6: the scope split is real ==='
prod=$(awk -F'\t' '$3 == "prod" { t += $4 } END { print t + 0 }' "$recorded")
test_=$(awk -F'\t' '$3 == "test" { t += $4 } END { print t + 0 }' "$recorded")
assert_gt "production sites recorded" "$prod"  "0"
assert_gt "test sites recorded"       "$test_" "0"

# ---- assertion-count guard ----------------------------------------------
EXPECTED_ASSERTIONS=21
TOTAL=$(( PASS + FAIL ))
if (( TOTAL != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi

printf '\n=== summary: %d passed, %d failed (%d assertions; expected %d) ===\n' \
    "$PASS" "$FAIL" "$TOTAL" "$EXPECTED_ASSERTIONS"
printf 'population: %d sites (%d prod, %d test) across %d (file,kind) rows\n' \
    "$man_total" "$prod" "$test_" "$man_rows"
if (( FAIL == 0 )); then echo 'ALL TESTS PASSED'; exit 0; fi
echo 'TESTS FAILED' >&2
exit 1
