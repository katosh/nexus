#!/usr/bin/env bash
# The NULLGLOB + BARE-FORM population must match its recorded boundary, and the
# classifier's distinctions must be load-bearing. your-org/nexus-code#1214 S1.
#
# WHY THIS SUITE EXISTS. `#1214` D1 fixed one site and wrote the enumeration
# into a COMMIT MESSAGE. `git diff --name-status` for that commit adds no file:
# no lint, no manifest, no guard. So nothing failed when site N+1 appeared, and
# the knowledge sat where no future author would read it — the same
# "an assertion nothing can disagree with" shape the whole branch was about,
# arriving in the audit OF that branch. This makes the enumeration executable.
#
# WHAT A GREEN HERE DOES AND DOES NOT CERTIFY. It certifies that the POPULATION
# has not drifted: a new pairing is RED rather than a discovery. It does NOT
# certify that the 65 `unreviewed` rows are safe — `unreviewed` means exactly
# what it says, and a guessed `safe` on each would be worse than nothing,
# because a false `safe` is what a future reader would trust. (65, not 69: of
# the 69 rows that are not `defect`, four carry a reviewed `safe` verdict.)
#
# AND IT DOES NOT CERTIFY A `safe (b)` VERDICT STILL HOLDS. Those are claims
# about REACHABILITY under a dynamically-set shell option; the key being stable
# says the TEXT is unchanged, never that the call path is. The one such property
# that can be mechanised from inside this repo is asserted below (the BASH_ENV
# prelude case); the rest is a human's.
#
# Run: bash monitor/watcher/test-nullglob-bare-form-manifest.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
GEN="$_test_dir/nullglob-bare-form.sh"
AWKF="$_test_dir/_nullglob_bare_form.awk"
MAN="$_test_dir/nullglob-bare-form.manifest"
# The file three `safe` rows depend on. See the BASH_ENV case below.
BASH_ENV_FILE="$_repo_root/monitor/shellenv/bash_env.sh"

# THE SPELLING-SET PREDICATE for "this file enables nullglob".
#
# A SINGLE CANONICAL PLANT PROVES ONE SPELLING, NOT THE CLASS
# (your-org/nexus-code#1214, and this repo's own `[^a-zA-Z0-9_-]` vs
# `[^A-Za-z0-9_-]` history where one site survived a fix and three skeptic
# passes). The first version of this predicate was
# `shopt[[:space:]]+-s[[:space:]]+([a-z_]+[[:space:]]+)*nullglob` and it MISSED
# three real carriers, measured: `shopt -qs nullglob`, `shopt -s "nullglob"`,
# and a dynamically-named option.
#
#   -[^u[:space:]]*s[^u[:space:]]*   the flag CLUSTER must contain `s` and must
#                                    NOT contain `u`. `-qs` and `-sq` SET (bash:
#                                    `-q` is "suppress output", `-s` is "enable"),
#                                    so they are carriers -- measured, glob count
#                                    0. In a MIXED cluster `u` WINS: `shopt -su`
#                                    and `-us` both resolve to `-u` and are NOT
#                                    carriers, so flagging them would be a FALSE
#                                    POSITIVE, and a false positive is what gets
#                                    a guard weakened by whoever hits it.
#   ([-a-z_"']+[[:space:]]+)*        other option names may precede nullglob
#   ["']?nullglob                    the name may be quoted
_NG_SET_RE='shopt[[:space:]]+-[^u[:space:]]*s[^u[:space:]]*[[:space:]]+([-a-z_"'"'"']+[[:space:]]+)*["'"'"']?nullglob'

# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

for f in "$GEN" "$AWKF" "$MAN"; do
    [[ -r "$f" ]] || { echo "missing: $f" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# DECLARE WHAT THIS GUARD READS, so `ng guards-for-diff` can SELECT it
# (your-org/nexus-code#1214 G1).
#
# It shipped without this, and the shape of that omission is the reason it is
# worth a comment rather than a one-liner: this guard's population is EVERY
# tracked shell file under `monitor/`, so almost any change in the repo can add
# a site to it -- and it was the one guard the pre-push index could not name.
# Measured end to end, staged: plant a site, the generator goes 73 -> 74, this
# guard exits 1, and `ng guards-for-diff` exits **0** with this file absent from
# SELECTED. Exit 0, blind-spot count printed, and the relevant guard sitting
# inside that blind spot. That is round-1 O5 recurring on the guard built to
# close S1 -- the remedy landing outside the index that exists to find it.
#
# The list comes from the GENERATOR's own `--files` mode, never a copy: a second
# implementation of the population drifts, and then the index reports with total
# confidence that this guard does not read a file it does read.
# shellcheck disable=SC1091
. "$(cd "$_test_dir/.." && pwd)/_guard_population.sh"
gp_population() {
    bash "$GEN" --files "$_repo_root"
    printf '%s\n' "$AWKF"
    printf '%s\n' "$MAN"
    printf '%s\n' "$GEN"
    # Declared because the BASH_ENV assertion below READS it. A guard that
    # reads a file it does not declare is what this protocol exists to stop.
    printf '%s\n' "$BASH_ENV_FILE"
}
gp_handle "$@"

WORK=$(mktemp -d -t nexus-ngbf-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
echo "=== the instrument is not vacuous ==="
# A generator that silently returns nothing would make the set comparison below
# pass by having nothing to compare — the #618 silent-zero shape, inside the
# probe. So a FLOOR, well under the true count, is asserted first.
"$GEN" "$_repo_root" > "$WORK/live.tsv" 2>/dev/null
n_live=$(command grep -c . "$WORK/live.tsv" || true)
if (( n_live >= 20 )); then
    pass "the generator enumerated a plausible population ($n_live sites)"
else
    fail "the generator returned $n_live sites — below the floor; every comparison below would be vacuous"
fi
command grep -vE '^[[:space:]]*(#|$)' "$MAN" > "$WORK/rec.full" || true
n_rec=$(command grep -c . "$WORK/rec.full" || true)
if (( n_rec >= 20 )); then
    pass "the manifest records a plausible population ($n_rec rows)"
else
    fail "the manifest holds $n_rec rows — below the floor"
fi

# ---------------------------------------------------------------------------
echo "=== the live tree matches the recorded boundary, BOTH directions ==="
# THE KEY IS FIELDS 1-5: file, normalized line, occurrence, command, glob. It is
# deliberately NOT a line number -- see the manifest header. `#1238` inserts one
# line at `monitor/ng:548` and, under the old `<file>:<LINE>` key, rekeyed three
# rows recorded at 1316/1326/1329 into three ADDED and three REMOVED sites for a
# tree in which nothing changed. Both PRs merge CLEAN and neither touches the
# other's file, so this guard was the only thing that disagreed.
cut -f1-5 "$WORK/live.tsv" | LC_ALL=C sort > "$WORK/live.k"
cut -f1-5 "$WORK/rec.full" | LC_ALL=C sort > "$WORK/rec.k"
# A human reading a red still needs a line number; it just must not be the KEY.
# `--locate` supplies it, freshly measured, so the diagnostic cannot go stale.
"$GEN" --locate "$_repo_root" > "$WORK/loc.tsv" 2>/dev/null || true
_where() {   # annotate each key line with the site's CURRENT file:line
    awk -F'\t' 'NR==FNR { w[$1 FS $2 FS $3] = $4; next }
                 { k = $1 FS $2 FS $3
                   printf "  %s:%s\t%s\t%s\n", $1, (k in w ? w[k] : "?"), $4, $5 }' \
        "$WORK/loc.tsv" -
}
# LC_ALL=C ON THE `comm`, NOT ONLY ON THE `sort` (found while re-keying,
# your-org/nexus-code#1214). The key files are built with `LC_ALL=C sort`;
# `comm` used to run under the AMBIENT locale, which here is en_US.utf8, and the
# two ORDERS DIFFER on this very data. `comm` on differently-collated input does
# not fail the pipeline — it prints a diagnostic nothing reads and returns a
# WRONG SET. Measured on this tree: with exactly ONE row removed from the
# recorded set, the truth is `1 added / 0 gone` and ambient `comm` answered
# **7 added / 6 gone**, the six phantom removals including all three
# `monitor/ng` `safe (b)` rows — i.e. it invents exactly the "recorded row whose
# pairing is gone" signal that invites a reviewer to regenerate a reachability
# argument away. Same failure shape as the line-key bug this re-key removes (a
# site reported as both added and removed for a tree in which nothing changed),
# arriving in the COMPARISON rather than in the KEY.
#
# It was silent because the two sets are EQUAL, and on equal sets a broken
# comparison and a working one return the same empty answer. ASSERTING THAT
# `comm` DID NOT COMPLAIN IS NOT ENOUGH — measured, it does not complain here
# either, so such an assertion passes on a matching tree while certifying
# nothing, and one was written and thrown away before this. What replaces it is
# a POSITIVE CONTROL that injects a KNOWN difference and demands the EXACT
# answer, through the same function the real comparison uses. Under ambient
# `comm` that control reads 7/6 against an expected 1/0 and goes RED.
_setdiff() {   # _setdiff <recorded-keys> <live-keys> -> _SD_ADDED, _SD_GONE
    _SD_ADDED=$(LC_ALL=C comm -13 "$1" "$2" 2>/dev/null)
    _SD_GONE=$( LC_ALL=C comm -23 "$1" "$2" 2>/dev/null)
}
_sd_n() { [[ -z "$1" ]] && { printf '0'; return; }; printf '%s\n' "$1" | command grep -c .; }

_setdiff "$WORK/rec.k" "$WORK/live.k"
added="$_SD_ADDED"; gone="$_SD_GONE"
if [[ -z "$added" ]]; then
    pass "no UNRECORDED pairing in the tree"
else
    fail "NEW nullglob/bare-form pairing(s) not in the manifest — classify, do not just regenerate:
$(printf '%s\n' "$added" | _where)"
fi
if [[ -z "$gone" ]]; then
    pass "no STALE row naming a pairing that is gone"
else
    fail "manifest row(s) whose pairing no longer exists. A REMOVED site — regenerate and say so.
A REKEYED site — the text changed; re-read the disposition against the NEW text
before carrying it across (\`file:?\` below means the recorded text is nowhere in
the tree, which is what a text change looks like from here):
$(printf '%s\n' "$gone" | _where)"
fi

# ---------------------------------------------------------------------------
echo "=== the SET DIFFERENCE returns the EXACT truth on a KNOWN difference ==="
# Both direction checks above pass on a matching tree, and so would a comparison
# that can never disagree — or one that disagrees WRONGLY, which is the case
# actually observed. So the same `_setdiff` is run against deliberately
# corrupted copies of the recorded set, and the assertion is on EXACT MEMBERSHIP
# rather than on non-emptiness: a mere "something was reported" is what let
# 7 added / 6 gone stand in for 1 / 0.
#
# BOTH SIDES DERIVE FROM `rec.k`, NOT FROM `live.k`, AND THAT IS THE POINT.
# These two assertions test the INSTRUMENT, so they must not also re-test the
# TREE. An earlier version compared a corrupted record against the live keys,
# and when the tree was genuinely out of sync it failed too — measured, one
# planted site produced 29P/3F where exactly ONE defect existed, the plant plus
# both of these controls reacting to it. That is this repo's own "a failing lint
# names its offenders — read the list, not the count" trap, manufactured inside
# a control added to prevent a different silent failure. Keyed against `rec.k`
# on both sides, a real tree drift produces exactly ONE red and these two stay
# green, because the property they assert is about `_setdiff`.
#
# It still catches the collation bug, which is the only reason the change is
# safe: measured on this tree with both sides C-sorted, ambient `comm` answers
# 7 added / 6 gone where the truth is 1 / 0, identically to the live-keyed form.
# The disorder is a property of the FILE ORDER against `comm`'s collation, not
# of which file it is compared with.
_probe_drop="$WORK/rec.k.drop"
_dropped=$(command head -1 "$WORK/rec.k")
command tail -n +2 "$WORK/rec.k" > "$_probe_drop"
_setdiff "$_probe_drop" "$WORK/rec.k"
if [[ "$_SD_ADDED" == "$_dropped" && -z "$_SD_GONE" ]]; then
    pass "one row dropped from the record -> EXACTLY that row reported unrecorded, nothing else"
else
    fail "one row dropped, and the answer was $(_sd_n "$_SD_ADDED") added / $(_sd_n "$_SD_GONE") gone instead of exactly 1 / 0 — the set difference is not trustworthy (collation?):
added:
$_SD_ADDED
gone:
$_SD_GONE"
fi
_probe_add="$WORK/rec.k.phantom"
_phantom='monitor/zzz-phantom.sh	phantom=$(ls "$D"/never-* )	1	ls	/never-*'
{ cat "$WORK/rec.k"; printf '%s\n' "$_phantom"; } | LC_ALL=C sort > "$_probe_add"
_setdiff "$_probe_add" "$WORK/rec.k"
if [[ "$_SD_GONE" == "$_phantom" && -z "$_SD_ADDED" ]]; then
    pass "one phantom row added to the record -> EXACTLY that row reported stale, nothing else"
else
    fail "one phantom row added, and the answer was $(_sd_n "$_SD_ADDED") added / $(_sd_n "$_SD_GONE") gone instead of exactly 0 / 1:
added:
$_SD_ADDED
gone:
$_SD_GONE"
fi

# ---------------------------------------------------------------------------
echo "=== the ARITY invariant: the generator's default output IS the key columns ==="
# One definition of the key, not two. If these drift, `cut -f1-5` above silently
# compares different things on the two sides and the guard passes by confusion.
_nf_live=$(awk -F'\t' '{print NF}' "$WORK/live.tsv" | LC_ALL=C sort -u | tr '\n' ' ')
if [[ "${_nf_live// /}" == "5" ]]; then
    pass "generator default output is exactly 5 columns (the key), on every row"
else
    fail "generator rows have field counts [$_nf_live] — expected 5 on every row"
fi
_nf_rec=$(awk -F'\t' '{print NF}' "$WORK/rec.full" | LC_ALL=C sort -u | tr '\n' ' ')
if [[ "${_nf_rec// /}" == "7" ]]; then
    pass "manifest rows are exactly 7 columns (5 key + disposition + reason)"
else
    fail "manifest rows have field counts [$_nf_rec] — expected 7 on every row"
fi
# The OCCURRENCE ordinals of a duplicate group must be 1..N with no gap and no
# repeat, or two distinct sites can collide onto one key and the row count and
# the site count stop being the same number.
_occ_bad=$(awk -F'\t' '{ n[$1 FS $2]++; seen[$1 FS $2 FS $3]++ }
    END { for (k in seen) if (seen[k] > 1) print "DUPLICATE KEY: " k
          for (k in n) { for (i = 1; i <= n[k]; i++)
                             if (!((k FS i) in seen)) print "GAP: " k " @" i } }' "$WORK/live.tsv")
if [[ -z "$_occ_bad" ]]; then
    pass "every duplicate group's ordinals are 1..N — no collision, no gap"
else
    fail "ordinal integrity broken:
$_occ_bad"
fi

# ---------------------------------------------------------------------------
echo "=== a REVIEWED row may not sit in a DUPLICATE-TEXT group ==="
# your-org/nexus-code#1214 sk F1. This closes the residual the manifest header
# calls failure mode (1), and it closes it because the header UNDERSTATED it.
#
# The header said ordinal churn produces a red whose offending line "is IN THAT
# FILE'S OWN DIFF, so the red is attributable". Measured by the reviewing
# skeptic, it is not. Plant a `safe` verdict on occurrence 7 of the 13-member
# `launchers_before` group in test-respawn.sh, then insert ONE byte-identical
# sibling above line 154:
#   * ONE red, naming test-respawn.sh:1638 — the LAST sibling, 1,484 lines from
#     the edit, a line nobody touched;
#   * `PASS: no STALE row naming a pairing that is gone`;
#   * and the recorded occurrence-7 disposition now silently describes what used
#     to be occurrence 6. Ordinals 7..13 all shifted REFERENT, and nothing said
#     so.
# So it is neither an attributable red nor a silent green: it is a red pointing
# at the WRONG SITE plus a SILENT referent shift.
#
# AND THE GROUP IS FORMED ON *NORMALISED* TEXT, which discards the one axis a
# `safe (b)` reachability argument can turn on. Two sites differing only by
# leading whitespace — one inside a block that runs `shopt -s nullglob`, one not
# — are genuinely different REACHABILITY and land in ONE (file, line) group. The
# ordinal keeps the KEYS distinct, so nothing collides; what is positional
# rather than textual is which SITE a disposition refers to.
#
# The fix is not a better key. Inside a duplicate group there is by construction
# no text to distinguish the members, so no content-derived key can carry a
# per-member verdict. The fix is to REFUSE to hold one: a reviewed verdict is
# only meaningful on a site the key can name uniquely, which is a SINGLETON
# group. 8 of 8 reviewed rows are singletons today, so this is green on arrival
# and becomes a loud precondition the day somebody classifies one of the 36
# duplicate-group sites — which is exactly what this manifest exists to
# accumulate.
_rev_dup=$(awk -F'\t' '
    { n[$1 FS $2]++; disp[NR]=$6; k[NR]=$1 FS $2; f[NR]=$1; occ[NR]=$3 }
    END { for (i = 1; i <= NR; i++)
              if (disp[i] != "unreviewed" && n[k[i]] > 1)
                  printf "  %s occurrence %s (%s) — group of %d identical lines\n", \
                         f[i], occ[i], disp[i], n[k[i]] }' "$WORK/rec.full")
if [[ -z "$_rev_dup" ]]; then
    pass "every defect/safe row is the ONLY site with its text in its file — a reviewed verdict names one site"
else
    fail "reviewed row(s) inside a DUPLICATE-TEXT group. The ordinal keeps the KEY unique but not the
REFERENT: insert one byte-identical sibling above these and the verdict silently
moves to a different site, while the red names the LAST member of the group
instead of the edit. Distinguish the site's text, or leave it \`unreviewed\`:
$_rev_dup"
fi

# ---------------------------------------------------------------------------
echo "=== the manifest's own keys are DISTINCT ==="
# your-org/nexus-code#1214 sk F4. Two identical key rows DO red today, but under
# the message "manifest row(s) whose pairing no longer exists" — because `comm`
# reports the surplus copy as unique to the record. Loud, so never a hazard, but
# it sends the reader looking for a deleted site that does not exist. Named
# properly here.
_dup_key=$(cut -f1-3 "$WORK/rec.full" | LC_ALL=C sort | uniq -d)
if [[ -z "$_dup_key" ]]; then
    pass "no duplicate key in the manifest — row count and site count are the same number"
else
    fail "DUPLICATE manifest key(s) — two rows claim one site, so one disposition is unreachable:
$_dup_key"
fi

# ---------------------------------------------------------------------------
echo "=== every reviewed verdict carries a reason ==="
# Fields 6 and 7 — a naive `nullglob-bare-form.sh > manifest` REGENERATION
# emits five columns, so $6 is empty and this check is what catches it. That is
# the intended failure: regenerating is not a fix, it is a discard.
_bad_reason=$(awk -F'\t' '($6=="defect"||$6=="safe") && ($7=="-"||$7=="") {print $1" | "$2}' "$WORK/rec.full")
if [[ -z "$_bad_reason" ]]; then
    pass "every defect/safe row states WHY — a verdict nobody can check is not a verdict"
else
    fail "reviewed row(s) with no reason: $_bad_reason"
fi
_bad_disp=$(awk -F'\t' '$6!="defect" && $6!="safe" && $6!="unreviewed" {print $1" | "$2" -> "$6}' "$WORK/rec.full")
if [[ -z "$_bad_disp" ]]; then
    pass "every disposition is one of defect|safe|unreviewed"
else
    fail "unknown disposition(s): $_bad_disp"
fi

# ---------------------------------------------------------------------------
echo "=== THE ACCEPTANCE PROPERTY: the key survives insertion ABOVE a site ==="
# This is the whole reason the key was changed, so it is EXERCISED rather than
# argued. A throwaway one-file repo is built, the generator run against it, then
# five lines are inserted ABOVE every recorded site -- the `#1238` shape exactly,
# where one insertion at `monitor/ng:548` rekeyed three rows at 1316/1326/1329 --
# and the key set must be IDENTICAL while the LINE NUMBERS must have MOVED.
#
# BOTH halves are assertions on purpose. "The keys are identical" is, on its own,
# equally consistent with the insertion having silently failed to apply; the
# line-numbers-moved check is the positive control on the plant, and without it
# this section could pass while measuring nothing (`#1150`).
_FX="$WORK/fx"
_FXF="$_FX/monitor/fixture-sites.sh"
mkdir -p "$_FX/monitor"
cp "$_repo_root/monitor/shell-files.sh" "$_FX/monitor/shell-files.sh"
_fx_write() {   # _fx_write <padding-lines-above-every-site> <alpha-glob>
    local pad="$1" g="$2" i
    {
        printf '%s\n' '#!/usr/bin/env bash'
        for (( i = 0; i < pad; i++ )); do printf '%s\n' '# padding'; done
        printf 'a=$(ls "$D"/%s 2>/dev/null | head -1)\n' "$g"
        printf 'x=$(cat "$D"/dup-* 2>/dev/null)\n'
        printf '%s\n' 'echo middle'
        printf 'x=$(cat "$D"/dup-* 2>/dev/null)\n'
    } > "$_FXF"
}
_fx_write 0 'alpha-*'
git -C "$_FX" init >/dev/null 2>&1
git -C "$_FX" add -A >/dev/null 2>&1
# Staged, not committed, and deliberately so: `git ls-files` is what the
# population predicate reads, and an UNTRACKED fixture is invisible to it --
# a green here would then be a green about a tree with no fixture in it
# (`#1054`). The non-vacuity assertion below is what would catch that.
_fx_keys()  { bash "$GEN"          "$_FX" 2>/dev/null; }
_fx_lines() { bash "$GEN" --locate "$_FX" 2>/dev/null | cut -f4 | LC_ALL=C sort -n | tr '\n' ' '; }

_fx_k0=$(_fx_keys); _fx_l0=$(_fx_lines)
_fx_n=$(printf '%s\n' "$_fx_k0" | command grep -c . || true)
if (( _fx_n == 3 )); then
    pass "the fixture repo is SEEN by the generator (3 planted sites) — the plant applied"
else
    fail "the generator found $_fx_n sites in the fixture, expected 3 — every comparison below is vacuous"
fi
_fx_occ=$(printf '%s\n' "$_fx_k0" | awk -F'\t' '$4=="cat"{print $3}' | LC_ALL=C sort -n | tr '\n' ' ')
if [[ "${_fx_occ% }" == "1 2" ]]; then
    pass "two BYTE-IDENTICAL sites are disambiguated by the ordinal (1, 2)"
else
    fail "identical sites got ordinals [$_fx_occ], expected '1 2' — the key collides and two sites share one row"
fi

_fx_write 5 'alpha-*'          # five lines inserted ABOVE every site
_fx_k1=$(_fx_keys); _fx_l1=$(_fx_lines)
if [[ "$_fx_l1" != "$_fx_l0" ]]; then
    pass "the insertion APPLIED: site line numbers moved [$_fx_l0] -> [$_fx_l1]"
else
    fail "line numbers did not move ([$_fx_l0]) — the insertion never applied, so the key-stability check below measures NOTHING"
fi
if [[ "$_fx_k1" == "$_fx_k0" ]]; then
    pass "…and the KEY SET IS UNCHANGED across it — the #1238 rekey cannot recur"
else
    fail "the key set changed under an insertion ABOVE the sites — the key is still position-dependent:
$(diff <(printf '%s\n' "$_fx_k0") <(printf '%s\n' "$_fx_k1") || true)"
fi
_fx_occ1=$(printf '%s\n' "$_fx_k1" | awk -F'\t' '$4=="cat"{print $3}' | LC_ALL=C sort -n | tr '\n' ' ')
if [[ "${_fx_occ1% }" == "1 2" ]]; then
    pass "…and the duplicate group's ordinals did not renumber either"
else
    fail "ordinals renumbered under an unrelated insertion: [$_fx_occ1]"
fi

# A STABLE KEY MUST NOT BE AN INERT ONE. If the key survived a change to the
# site's own text, the manifest would carry a disposition about text that is no
# longer there — which is worse than the churn just removed, because it is
# silent. So the same fixture is edited where it counts.
_fx_write 5 'beta-*'
if [[ "$(_fx_keys)" != "$_fx_k0" ]]; then
    pass "editing the SITE'S OWN TEXT does change the key — a red, as it must be"
else
    fail "the key survived a change to the site's own text — it is inert, and a recorded disposition would silently outlive the code it describes"
fi

# ---------------------------------------------------------------------------
echo "=== the classifier's distinctions are LOAD-BEARING (positive controls) ==="
# Each control is planted and run through the classifier directly, because the
# classifier is where the axis lives. A guard whose distinctions were never
# seen to fire is indistinguishable from one that matches everything, or
# nothing.
_cls() { printf '%s\n' "$1" > "$WORK/probe.sh"; awk -f "$AWKF" "$WORK/probe.sh" 2>/dev/null; }

if [[ -n "$(_cls 'ls "$D"/blocked-*.ansi 2>/dev/null | head -1')" ]]; then
    pass "DETECTS the D1 shape (ls + a vanishing glob)"
else
    fail "did NOT detect the D1 shape — the classifier cannot see the defect it exists for"
fi
if [[ -n "$(_cls 'x=$(cat "$D"/.wf1.* 2>/dev/null)')" ]]; then
    pass "DETECTS a stdin-reading bare form (cat), so the axis is not keyed on \`ls\`"
else
    fail "did NOT detect \`cat\` — the axis has collapsed onto one command"
fi
if [[ -z "$(_cls "grep -vE '^[[:space:]]*\$' \"\$f\"")" ]]; then
    pass "IGNORES a \`*\`-free quoted regex"
else
    fail "matched a quoted regex — the quote-blanking is not working"
fi
if [[ -z "$(_cls "sed -E 's/.*x//' \"\$f\"")" ]]; then
    pass "IGNORES a \`*\` inside a QUOTED PATTERN (33 raw hits vs the real ones)"
else
    fail "matched a \`*\` inside a quoted pattern — false positives would bury the signal"
fi
if [[ -z "$(_cls 'stat -c %s "$D"/*.ansi')" ]]; then
    pass "IGNORES a command that ERRORS bare (stat) — THE PAIRING is the axis, not the glob"
else
    fail "matched \`stat\`, which errors with no arguments; the axis is not the pairing"
fi
if [[ -z "$(_cls '# ls "$D"/*.ansi | head -1')" ]]; then
    pass "IGNORES a commented-out site"
else
    fail "matched a comment"
fi

# ---------------------------------------------------------------------------
echo "=== the SOURCED-LIBRARY case: population is shell-wide, not shopt-carrying ==="
# `#1214` S2. `nullglob` is a SHELL option, so it reaches sourced code that
# never mentions it. A file with a bare-form pairing and NO `shopt` anywhere
# must still be enumerated, or the population repeats the original under-count.
printf '%s\n' '#!/usr/bin/env bash' 'x=$(cat "$D"/frag.* 2>/dev/null)' > "$WORK/lib-no-shopt.sh"
if [[ -n "$(awk -f "$AWKF" "$WORK/lib-no-shopt.sh" 2>/dev/null)" ]]; then
    pass "a file with NO \`shopt\` is still classified — the axis is shell-wide"
else
    fail "a file with no \`shopt\` was skipped — this is the S2 under-count, reintroduced"
fi
if command grep -qE 'shopt' "$WORK/lib-no-shopt.sh"; then
    fail "the sourced-library fixture mentions shopt — the control proves nothing"
else
    pass "and that fixture provably contains no \`shopt\` (the control is honest)"
fi

# ---------------------------------------------------------------------------
echo "=== the BASH_ENV chain: the property three \`safe\` rows rest on ==="
# your-org/nexus-code#1214 sk2 F2. Three `monitor/ng` rows are dispositioned
# `safe (b)` -- not reachable under nullglob. That rests on the PROCESS
# BOUNDARY holding, and an earlier version of those rows named only
# BASHOPTS/SHELLOPTS as the carriers to check. It missed the one this nexus
# EXPORTS BY DESIGN: `monitor/locals-env.sh` sets
# BASH_ENV=$NEXUS_ROOT/monitor/shellenv/bash_env.sh for every agent process and
# its children, and bash sources $BASH_ENV at the start of every
# NON-interactive shell. Measured: with a nullglob-setting BASH_ENV, the real
# unmodified `ng report-init` writes a WRONG session id into a real report's
# frontmatter.
#
# Nothing is broken today because that file carries no `shopt`. This turns that
# from PROSE into a RED: it is the cheapest thing on this branch that converts
# a claim three permanent dispositions depend on into something that fails.
if [[ -r "$BASH_ENV_FILE" ]]; then
    pass "the BASH_ENV prelude exists and is readable (a missing file must not pass silently)"
    if command grep -qE "$_NG_SET_RE" "$BASH_ENV_FILE"; then
        fail "monitor/shellenv/bash_env.sh SETS nullglob — it is exported as BASH_ENV into every agent process, so three \`safe\` rows in nullglob-bare-form.manifest are no longer safe. Re-disposition them or remove the option."
    else
        pass "monitor/shellenv/bash_env.sh sets no nullglob — the safe (b) rows hold"
    fi
else
    fail "cannot read $BASH_ENV_FILE — the property three \`safe\` rows depend on is unverifiable"
fi
# POSITIVE CONTROL: the predicate must fire on a file that does set it, or the
# green above is equally consistent with a grep that can never match.
printf '%s\n' '#!/usr/bin/env bash' 'shopt -s nullglob' > "$WORK/be-planted.sh"
if command grep -qE "$_NG_SET_RE" "$WORK/be-planted.sh"; then
    pass "…and the predicate FIRES on a planted prelude that does set it"
else
    fail "the BASH_ENV predicate did not fire on a planted positive — it cannot detect the thing it checks"
fi
#
# COVERAGE BOUNDARY, STATED SO THE GREEN IS NOT OVERREAD. This checks ONE file:
# the repo's own prelude. `bash_env.sh` re-sources $NEXUS_PREV_BASH_ENV, which
# on this host is /app/lmod/lmod/init/bash -- OUTSIDE THIS REPO and outside any
# guard's reach. That half is unmeasured beyond a one-time read, and no
# assertion here covers it. Nor does this cover the other carriers: an exported
# BASHOPTS/SHELLOPTS, or `bash -O nullglob` on the invocation, leave no text in
# any file to grep.

# ---------------------------------------------------------------------------
echo "=== the predicate covers the SPELLING SET, not one spelling ==="
# A single canonical plant proves the predicate fires on THAT STRING. This repo
# has been bitten by exactly that distinction (`[^a-zA-Z0-9_-]` vs
# `[^A-Za-z0-9_-]`: same set, different string, one site surviving a fix and
# three skeptic passes). So every spelling below has its CARRIER STATUS
# MEASURED LIVE -- run as a real BASH_ENV prelude, glob counted -- rather than
# hardcoded, and the predicate's verdict is compared against that. A hardcoded
# expectation would rot silently the day bash changed.
_sm_dir="$WORK/spell"; mkdir -p "$_sm_dir"
printf 'a=( ./nope-* ); echo ${#a[@]}\n' > "$_sm_dir/probe.sh"
_sm_n=0 _sm_fn="" _sm_fp=""
_sm_case() {   # _sm_case <label> <line>
    printf '%s\n' "$2" > "$_sm_dir/env.sh"
    local n c v
    n=$(cd "$_sm_dir" && env -u BASHOPTS BASH_ENV="$_sm_dir/env.sh" bash ./probe.sh 2>/dev/null)
    c=no; [[ "$n" == "0" ]] && c=yes
    v=no; command grep -qE "$_NG_SET_RE" "$_sm_dir/env.sh" 2>/dev/null && v=yes
    _sm_n=$(( _sm_n + 1 ))
    [[ "$c" == yes && "$v" == no  ]] && _sm_fn="$_sm_fn [$1]"
    [[ "$c" == no  && "$v" == yes ]] && _sm_fp="$_sm_fp [$1]"
}
_sm_case 'shopt -s nullglob'            'shopt -s nullglob'
_sm_case 'shopt -s extglob nullglob'    'shopt -s extglob nullglob'
_sm_case 'shopt -s dotglob nullglob'    'shopt -s dotglob nullglob'
_sm_case 'shopt -s nullglob extglob'    'shopt -s nullglob extglob'
_sm_case 'indented'                     '    shopt -s nullglob'
_sm_case 'tab-separated'                "$(printf 'shopt -s\tnullglob')"
_sm_case 'shopt -qs nullglob'           'shopt -qs nullglob'
_sm_case 'shopt -sq nullglob'           'shopt -sq nullglob'
_sm_case 'double-quoted'                'shopt -s "nullglob"'
_sm_case 'single-quoted'                "shopt -s 'nullglob'"
_sm_case 'trailing comment'             'shopt -s nullglob # why'
_sm_case 'shopt -u nullglob'            'shopt -u nullglob'
_sm_case 'shopt -q nullglob'            'shopt -q nullglob'
_sm_case 'shopt -su nullglob'           'shopt -su nullglob'
_sm_case 'shopt -us nullglob'           'shopt -us nullglob'
_sm_case 'shopt -qu nullglob'           'shopt -qu nullglob'

if (( _sm_n >= 12 )); then
    pass "the spelling matrix exercised $_sm_n spellings (non-vacuous)"
else
    fail "the spelling matrix exercised only $_sm_n — too few to claim coverage"
fi
if [[ -z "${_sm_fn// /}" ]]; then
    pass "NO FALSE NEGATIVE: every measured carrier is detected"
else
    fail "carrier(s) the predicate MISSES:$_sm_fn — the guard is narrower than the sentence beside it"
fi
if [[ -z "${_sm_fp// /}" ]]; then
    pass "NO FALSE POSITIVE: nothing that is not a carrier is flagged"
else
    fail "non-carrier(s) the predicate FLAGS:$_sm_fp — a false positive is what gets a guard weakened"
fi

# THE ONE SPELLING NO GREP CAN CLOSE, pinned so it cannot change unnoticed.
# A dynamically-named option is a carrier and is undetectable by any text
# predicate. This is a BOUND on the claim, not a defect to fix: the assertion
# below states the limit rather than hiding it, so the green above is read as
# "these spellings" and never as "any spelling".
printf '%s\n' 'o=nullglob; shopt -s $o' > "$_sm_dir/dyn.sh"
_dyn_c=$(cd "$_sm_dir" && env -u BASHOPTS BASH_ENV="$_sm_dir/dyn.sh" bash ./probe.sh 2>/dev/null)
if [[ "$_dyn_c" == "0" ]] && ! command grep -qE "$_NG_SET_RE" "$_sm_dir/dyn.sh"; then
    pass "STATED LIMIT holds: a DYNAMICALLY-NAMED option is a carrier and is undetectable by any grep"
else
    fail "the dynamic-name limit changed (carrier=$_dyn_c, detected=$(command grep -qE "$_NG_SET_RE" "$_sm_dir/dyn.sh" && echo yes || echo no)) — re-state the bound"
fi

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (your-org/nexus-code#807): 2 non-vacuity + 2 set
# directions + 2 exact-truth positive controls on the set difference
# + 3 arity/ordinal + 2 reviewed-row-uniqueness/distinct-key (sk F1, F4)
# + 2 disposition checks + 6 key-stability fixture
# + 6 classifier controls + 2 sourced-library + 3 BASH_ENV + 4 spelling-set.
EXPECTED=$(( 2 + 2 + 2 + 3 + 2 + 2 + 6 + 6 + 2 + 3 + 4 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
