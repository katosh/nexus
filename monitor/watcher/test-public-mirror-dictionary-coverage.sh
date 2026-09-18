#!/usr/bin/env bash
# test-public-mirror-dictionary-coverage.sh — hold the public-mirror dictionary
# to the invariants that stop it being VACUOUSLY GREEN.
#
# THE DEFECT CLASS (your-org/nexus-code#979 §2). The leak gate reads its `deny`
# patterns from the same file the scrub reads its `map` rules from. So a
# category of identifier that nobody wrote down is invisible to BOTH: the scrub
# does not strip it and the gate does not flag it. The gate reports CLEAN
# rather than reporting a MISS, on a surface whose entire job is preventing a
# permanent public disclosure. Ten token families across sixteen files reached
# the built tree that way.
#
# The categories are covered from here on. They were NOT covered retroactively:
# hand-carried bootstrap state caught some and missed others, and measured
# against the current public tip, ten files still match six of these rules,
# pending remediation. That is tracked internally at your-org/nexus-code#1006,
# which is where the affected paths are recorded — deliberately not here.
#
# THAT OMISSION IS THE POINT, and it is the trap in writing this paragraph at
# all. The paths are public in the trivial sense that anyone can list the
# repository; but publishing "these ten files contain internal identifiers"
# INTO that repository narrows a reader's search from every file to ten, which
# the values themselves do not. A file that ships to the mirror may state that
# an exposure exists and how large it is. It must not become the map.
#
# So the honest reading of a green run here: the dictionary is now consistent
# and the build is clean going forward. It is not a statement that the
# published history is clean.
#
# You cannot, in general, detect a category nobody thought of. What you CAN do
# is refuse to let the two halves of the dictionary disagree, so that
# everything the toolkit knows about is both FIXED and POLICED:
#
#   1. every `map` SOURCE is matched by some `deny` pattern — a rule that
#      rewrites an identifier but does not arm the gate against it protects
#      today's tree and says nothing about tomorrow's;
#   2. no `map` SOURCE survives into the BUILT tree — a rule that is present
#      but never fires (wrong order, wrong case shape, a form the literal does
#      not reach) is indistinguishable from a rule that is absent, and the gate
#      cannot tell you which you have;
#   3. the gate is LIVE — planting a token drawn from the dictionary's own
#      `deny` list must make it fail. A gate that passes everything passes a
#      clean tree too.
#
# NOTHING HERE NAMES AN IDENTIFIER. Every value is read from the excluded
# dictionary at run time and reported by COUNT and by RULE INDEX, never by
# value — this file ships to the public mirror, and a suite that quoted the
# redaction dictionary would be the disclosure it exists to prevent. Failure
# messages give you the rule's line number; go read it locally.
#
# SENTINELS ARE EXEMPT FROM (1), and detected structurally rather than by
# spelling: the dictionary protects a form from a broader rule by parking it on
# a throwaway token and restoring it afterwards, so the round-trip's SOURCE is
# some other rule's REPLACEMENT. Those are machinery, not identifiers, and
# arming the gate against them would be nonsense.
#
# Run: bash monitor/watcher/test-public-mirror-dictionary-coverage.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Exit 77 = declined to run.

set -uo pipefail
export LC_ALL=C

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
SRC_ROOT=$(cd "$_test_dir/../.." && pwd)
PM="$SRC_ROOT/monitor/public-mirror"
MAPPING="$PM/mapping.tsv"
GATE="$PM/leak-gate.sh"

PASS=0; FAIL=0
pass(){ printf '  PASS: %s\n' "$1"; _th_pass; }
fail(){ printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

decline(){ printf 'DECLINED (exit 77): %s\n' "$1" >&2; exit 77; }

[ -r "$MAPPING" ] || decline "no dictionary at $MAPPING (a fresh operator has none)"
[ -r "$GATE" ]    || decline "no leak-gate.sh at $PM"
command -v python3 >/dev/null 2>&1 || decline "python3 not on PATH"
command -v git >/dev/null 2>&1 || decline "git not on PATH"

SHORTTMP="/tmp/tt-$$"
mkdir -p "$SHORTTMP" || decline "cannot create short temp dir $SHORTTMP"
WORK=$(mktemp -d "$SHORTTMP/dictcov.XXXXXX") || decline "mktemp failed under $SHORTTMP"
cleanup(){ rm -rf "$WORK" "$SHORTTMP"; }
trap cleanup EXIT

# --- 1 + 2. structural invariants over the dictionary ---------------------
#
# python3 rather than awk because `deny` entries are EREs and must be applied
# as regexes, case-insensitively, exactly as leak-gate.sh applies them.

SRCS="$WORK/map-sources.txt"
KEEPS="$WORK/keep-patterns.txt"
python3 - "$MAPPING" "$SRCS" "$KEEPS" > "$WORK/report.txt" 2>"$WORK/report.err" <<'PY'
import re, sys
path = sys.argv[1]
rows = []
for n, line in enumerate(open(path, encoding='utf-8'), 1):
    if line.lstrip().startswith('#'):
        continue
    f = line.rstrip('\n').split('\t')
    if f and f[0]:
        rows.append((n, f))

maps  = [(n, f[1], f[2] if len(f) > 2 else '', f[3] if len(f) > 3 else '')
         for n, f in rows if f[0] == 'map' and len(f) > 1 and f[1]]
denys = [(n, f[1]) for n, f in rows if f[0] == 'deny' and len(f) > 1 and f[1]]
keeps = [(n, f[1]) for n, f in rows if f[0] == 'keep' and len(f) > 1 and f[1]]
excls = [(n, f[1]) for n, f in rows if f[0] == 'exclude' and len(f) > 1 and f[1]]

print(f"COUNT map {len(maps)}")
print(f"COUNT deny {len(denys)}")
print(f"COUNT keep {len(keeps)}")
print(f"COUNT exclude {len(excls)}")

bad_re = 0
compiled = []
for n, d in denys:
    try:
        compiled.append((n, re.compile(d, re.I)))
    except re.error:
        bad_re += 1
        print(f"BADRE {n}")
print(f"COUNT badre {bad_re}")


def analyse(maps_, compiled_):
    """The ONE implementation of every classification below.

    The synthetic controls at the bottom call THIS function, not a copy of it.
    A control that exercises a parallel implementation proves the copy works
    and says nothing about the code that produced the verdict — which is the
    same substitution error ("check the thing you did not measure") that this
    whole suite exists to catch.
    """
    # A sentinel round-trip's SOURCE is SOME OTHER rule's REPLACEMENT.
    sent = set()
    for i, (_, src_i, _, _) in enumerate(maps_):
        others = {ob for j, (_, _, ob, _) in enumerate(maps_) if j != i and ob} \
               | {oa for j, (_, _, _, oa) in enumerate(maps_) if j != i and oa}
        if src_i in others:
            sent.add(src_i)
    unc = [n for n, src_i, _, _ in maps_
           if src_i not in sent and not any(r.search(src_i) for _, r in compiled_)]
    nop = [n for n, src_i, b_i, a_i in maps_ if src_i == b_i or (a_i and src_i == a_i)]
    return sent, unc, nop


# ---- POTENCY OF THE REPORTER ITSELF -------------------------------------
#
# "0 blind spots" is only worth reading if the reporter can produce a
# non-zero. A detector that returns an empty list because it is BROKEN is
# indistinguishable, in its output, from one that looked and found nothing —
# which would move the vacuous green one layer up rather than removing it.
# So drive the same `analyse` over synthetic inputs whose answers are known.
_c = lambda *ds: [(0, re.compile(d, re.I)) for d in ds]

# POSITIVE: a map SOURCE no deny matches must be reported; a self-map must be
# reported; a genuine round-trip must be classified as a sentinel.
p_sent, p_unc, p_nop = analyse(
    [(901, 'alpha', 'ALPHA', ''), (902, 'beta', 'beta', ''),
     (903, 'gamma', 'zzsentzz', ''), (904, 'zzsentzz', 'gamma', '')],
    _c('nothing-matches-here'))
ctl_pos = int(901 in p_unc and 902 in p_nop and 'zzsentzz' in p_sent)

# NEGATIVE: a covered, non-self, non-sentinel map must be reported by NOTHING.
n_sent, n_unc, n_nop = analyse([(911, 'delta', 'DELTA', '')], _c('delta'))
ctl_neg = int(not n_unc and not n_nop and not n_sent)

print(f"CONTROL positive {ctl_pos}")
print(f"CONTROL negative {ctl_neg}")

# The real verdict, through the same `analyse` the controls above drove.
# "Sentinel" means SOME OTHER rule's replacement; the "other" is load-bearing
# and was put there by a mutant rather than by foresight — without it, a rule
# that maps a token to ITSELF satisfies the test against its own replacement
# and exempts itself from every check below.
sentinels, uncovered, noop = analyse(maps, compiled)
print(f"COUNT sentinel {len(sentinels)}")
print(f"COUNT noop {len(noop)}")
for n in noop:
    print(f"NOOP {n}")
print(f"COUNT uncovered {len(uncovered)}")
for n in uncovered:
    print(f"UNCOVERED {n}")

# Every map SOURCE, one per line, for the built-tree residue scan. Written to a
# side file so the report itself stays value-free.
with open(sys.argv[2], 'w', encoding='utf-8') as out:
    for _, s, _, _ in maps:
        if s not in sentinels:
            out.write(s + '\n')
# The keep patterns, so the residue scan discounts the same lines leak-gate.sh
# does. Without this, a SOURCE that is a prefix of a deliberately-protected form
# (the sentinel round-trip restores it verbatim) reads as a rule that never
# fired — measured, and it is why this file carries the exemption at all.
with open(sys.argv[3], 'w', encoding='utf-8') as out:
    for _, k in keeps:
        out.write(k + '\n')
PY
rc=$?
if (( rc != 0 )); then
    fail "could not parse the dictionary: $(head -3 "$WORK/report.err" | tr '\n' ' ')"
    th_summary_and_exit
fi

_count(){ awk -v k="$1" '$1=="COUNT" && $2==k {print $3}' "$WORK/report.txt"; }
n_map=$(_count map); n_deny=$(_count deny); n_keep=$(_count keep)
n_excl=$(_count exclude); n_bad=$(_count badre); n_sent=$(_count sentinel)
n_unc=$(_count uncovered); n_noop=$(_count noop)

# ANTI-VACUITY FIRST. Every assertion below is a statement about a population;
# if the population is empty they all hold and mean nothing.
if [[ -n "${n_map:-}" ]] && (( n_map > 0 )); then
    pass "dictionary declares $n_map map rule(s) (population is non-empty)"
else
    fail "dictionary declares NO map rules — every invariant below would hold vacuously"
fi
if [[ -n "${n_deny:-}" ]] && (( n_deny > 0 )); then
    pass "dictionary declares $n_deny deny pattern(s)"
else
    fail "dictionary declares NO deny patterns — the gate would pass everything"
fi
if [[ -n "${n_excl:-}" ]] && (( n_excl > 0 )); then
    pass "dictionary declares $n_excl exclude path(s) (it excludes itself)"
else
    fail "dictionary declares NO exclude paths — it would ship itself"
fi
if (( ${n_bad:-1} == 0 )); then
    pass "every deny pattern compiles as a regex"
else
    fail "$n_bad deny pattern(s) do not compile — leak-gate would silently under-match; lines: $(awk '$1=="BADRE"{printf "%s ", $2}' "$WORK/report.txt")"
fi

# THE REPORTER'S OWN POTENCY, asserted before any verdict it produces is read.
# A blind-spot reporter that can emit "none" because it failed to enumerate has
# not removed the vacuous green, it has moved it one layer up — which is this
# workspace's recurring shape (your-org/nexus-code#997 most recently, where a
# scraper read a suite's own echoed fixture text as its result). The controls
# drive the SAME `analyse` that produced the numbers below, over synthetic
# inputs whose answers are known.
_ctl(){ awk -v k="$1" '$1=="CONTROL" && $2==k {print $3}' "$WORK/report.txt"; }
if [[ "$(_ctl positive)" == "1" ]]; then
    pass "reporter fires on a synthetic gap (uncovered + no-op + sentinel all detected)"
else
    fail "reporter did NOT flag a synthetic map SOURCE with no deny, a synthetic self-map, or a synthetic round-trip — every 'none' it reports below is unreadable"
fi
if [[ "$(_ctl negative)" == "1" ]]; then
    pass "reporter stays quiet on a synthetic covered rule (its FAILs are attributable)"
else
    fail "reporter flagged a synthetic rule that is covered, non-self and non-sentinel — it reports gaps that are not there"
fi

# INVARIANT -1 — every file the BUILD reads as a manifest is TRACKED.
#
# build.sh iterates `git ls-files` and reads its manifests from the working
# tree, so an untracked manifest is present for the author and ABSENT in any
# fresh clone — including the one this suite builds. The failure is silent by
# construction: a missing rename manifest is a documented no-op, so the build
# succeeds, renames nothing, and the only symptom is a leak this suite would
# otherwise attribute to the dictionary. Measured four separate times while
# this file was being written, each time costing a wrong diagnosis.
untracked_manifests=""
for m in monitor/public-mirror/mapping.tsv \
         monitor/public-mirror/overlay/manifest.tsv \
         monitor/public-mirror/overlay/renames.tsv; do
    [ -e "$SRC_ROOT/$m" ] || continue
    git -C "$SRC_ROOT" ls-files --error-unmatch -- "$m" >/dev/null 2>&1 \
        || untracked_manifests+=" $m"
done
if [[ -z "$untracked_manifests" ]]; then
    pass "every build manifest present in the tree is tracked in git"
else
    fail "build manifest(s) present but UNTRACKED — a fresh clone builds differently and says nothing:$untracked_manifests"
fi

# INVARIANT 0 — no rule rewrites a token to itself.
if (( ${n_noop:-1} == 0 )); then
    pass "no map rule is a no-op (none rewrites its SOURCE to itself)"
else
    fail "$n_noop map rule(s) rewrite their SOURCE to ITSELF — they look like coverage and produce none. mapping.tsv line(s): $(awk '$1=="NOOP"{printf "%s ", $2}' "$WORK/report.txt")"
fi

# INVARIANT 1 — map ⊆ deny.
if (( ${n_unc:-1} == 0 )); then
    pass "every non-sentinel map SOURCE is armed by a deny pattern ($((n_map - n_sent)) checked, $n_sent sentinel(s) exempt)"
else
    fail "$n_unc map SOURCE(s) have NO deny backstop — the scrub fixes them, the gate cannot see them. mapping.tsv line(s): $(awk '$1=="UNCOVERED"{printf "%s ", $2}' "$WORK/report.txt")"
fi

# --- 3. the gate is LIVE ---------------------------------------------------
#
# Prove potency before trusting any clean verdict: a gate that cannot fail is
# not evidence. The canary is drawn from the dictionary's own deny list at run
# time (a literal-looking pattern, so the planted text really matches), so this
# names nothing and cannot go stale.

canary=$(awk -F'\t' '!/^[[:space:]]*#/ && $1=="deny" && $2 ~ /^[A-Za-z0-9_.-]+$/ {print $2; exit}' "$MAPPING")
if [[ -z "$canary" ]]; then
    fail "no literal-shaped deny pattern to use as a canary — cannot prove the gate is live"
else
    d="$WORK/canary"; rm -rf "$d"; mkdir -p "$d"
    printf 'planted canary: %s\n' "$canary" > "$d/planted.txt"
    ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
        && git add -A && git commit -qm p ) >/dev/null 2>&1
    ( cd "$d" && bash "$GATE" "$MAPPING" . >/dev/null 2>&1 )
    if (( $? != 0 )); then
        pass "leak-gate FAILS on a token planted from its own denylist (gate is live)"
    else
        fail "leak-gate PASSED a token drawn from its own denylist — the gate asserts nothing"
    fi

    # NEGATIVE control on the same instrument: an empty tree must PASS, so the
    # failure above is attributable to the planted token and not to the gate
    # refusing everything.
    d2="$WORK/clean"; rm -rf "$d2"; mkdir -p "$d2"
    printf 'nothing to see here\n' > "$d2/ok.txt"
    ( cd "$d2" && git init -q && git config user.email t@t && git config user.name t \
        && git add -A && git commit -qm p ) >/dev/null 2>&1
    ( cd "$d2" && bash "$GATE" "$MAPPING" . >/dev/null 2>&1 )
    if (( $? == 0 )); then
        pass "leak-gate PASSES a clean tree (the failure above is the token, not the instrument)"
    else
        fail "leak-gate FAILED a tree with no denied token — it refuses everything, so its FAILs carry no information"
    fi
fi

# --- 4. no map SOURCE survives the build ----------------------------------
#
# A rule that never fires is indistinguishable from a rule that was never
# written, and the gate cannot tell you which you have: `deny` matches the
# OUTPUT, so a map whose SOURCE still sits in the built tree shows up as a
# leak, while a map whose source form differs subtly (case, ordering, a
# neighbouring token) shows up as nothing at all. Build once and check.
#
# SKIPPABLE, LOUDLY: the build is ~15 s and needs a git work tree. Set
# NEXUS_SKIP_MIRROR_BUILD=1 to opt out — and it is recorded as a th_skip, so a
# run that skipped it does not read as a run that did it.

RESIDUE_ASSERTS=6          # build-rc + scanner-potency + survivor-count + population-drift + gate-on-built-tree + unstaged-refusal
if [[ "${NEXUS_SKIP_MIRROR_BUILD:-0}" == "1" ]]; then
    RESIDUE_ASSERTS=1
    th_skip "built-tree residue scan" "NEXUS_SKIP_MIRROR_BUILD=1"
elif ! git -C "$SRC_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    RESIDUE_ASSERTS=1
    th_skip "built-tree residue scan" "$SRC_ROOT is not a git work tree"
elif [[ ! -s "$SRCS" ]]; then
    RESIDUE_ASSERTS=1
    fail "map SOURCE list is empty — the residue scan would check nothing"
else
    TREE="$WORK/tree"
    if ! git clone -q --no-hardlinks "$SRC_ROOT" "$TREE" 2>"$WORK/clone.err"; then
        RESIDUE_ASSERTS=1
        fail "could not clone a throwaway tree: $(head -2 "$WORK/clone.err" | tr '\n' ' ')"
    else
        # Judge what the author is about to push, not merely what is committed.
        #
        # ONE POPULATION, AND THIS STEP WAS THE ONLY PARTY OUT OF STEP
        # (your-org/nexus-code#1109, #1217). Measured on a planted fixture:
        # `git ls-files` — which is what `build.sh`'s scrub loop iterates and
        # what `leak-gate.sh`'s path check reads — lists a STAGED-but-uncommitted
        # file. So does `git grep`, the gate's content check. `git ls-tree HEAD`
        # does not. The scrubber and the gate therefore already agree on THE
        # INDEX; neither is limited to committed content.
        #
        # `git apply` writes WITHOUT staging. An ADDED path arrived here
        # untracked, sat out the scrub loop, and was then staged below for the
        # gate to read UNSCRUBBED. Measured at 989b888, one blob held constant
        # and trackedness the only variable: untracked 17/0 (vacuously — it
        # never reaches $TREE at all), STAGED 16/1 "leak-gate FAILS the built
        # tree: <the author's own new file>", committed 17/0. That sentence is
        # FALSE, and because the gate is right to refuse to name the token, a
        # reader cannot tell it from a real disclosure.
        #
        # So: inject, STAGE, then build. The staging is what makes $TREE's index
        # equal to what was injected, which is the population `build.sh` scrubs.
        git -C "$SRC_ROOT" diff HEAD --binary > "$WORK/wt.patch" 2>/dev/null || : > "$WORK/wt.patch"
        [ -s "$WORK/wt.patch" ] && git -C "$TREE" apply "$WORK/wt.patch" 2>/dev/null

        # UNTRACKED SOURCE FILES, injected explicitly. `git diff HEAD` does not
        # report them, so without this the `add -A` below would create a NEW
        # asymmetry in place of the old one: a file the author staged is
        # scrubbed and judged, the SAME file one `git add` earlier is invisible
        # to both — two adjacent states of one file, opposite treatment, no
        # signal either way. `--exclude-standard` honours .gitignore, so this is
        # the set the author is about to add, not their scratch space.
        #
        # BOUNDED BY SIZE (your-org/nexus-code#1421). "The set the author is
        # about to add" is false for a nexus whose untracked `artifacts/`,
        # `backups/` and `data/` are never going to be added: one run of this
        # suite copied 42.19 GiB of them into a /tmp (tmpfs, i.e. RAM) clone —
        # 40.77 GiB of it `artifacts/` — and a SIGKILLed run held it for two
        # days. Source files are small; anything over the cap is data, not a
        # file the dictionary scrub could judge. Skipped files are COUNTED and
        # reported beside the injected count, so the bound is visible rather
        # than silent.
        n_untracked=0; n_untracked_skipped=0
        _inject_max=${DICTCOV_MAX_INJECT_BYTES:-1048576}
        while IFS= read -r -d '' u; do
            [ -n "$u" ] || continue
            _usz=$(stat -c %s -- "$SRC_ROOT/$u" 2>/dev/null || echo 0)
            if [ "$_usz" -gt "$_inject_max" ]; then
                n_untracked_skipped=$((n_untracked_skipped+1)); continue
            fi
            mkdir -p -- "$TREE/$(dirname -- "$u")" 2>/dev/null
            cp -p -- "$SRC_ROOT/$u" "$TREE/$u" 2>/dev/null && n_untracked=$((n_untracked+1))
        done < <(git -C "$SRC_ROOT" ls-files --others --exclude-standard -z 2>/dev/null)

        git -C "$TREE" add -A >/dev/null 2>&1
        # The population the scrub is ABOUT to iterate, recorded before it runs.
        # Compared against the gate's population below; see the drift invariant.
        git -C "$TREE" ls-files > "$WORK/pop.build" 2>/dev/null || : > "$WORK/pop.build"
        # --allow-dirty: $TREE is now staged-but-uncommitted, which
        # `git status --porcelain` reports as dirty (your-org/nexus-code#1001).
        # It is NOT a claim that the injected diff is meant to stay unstaged —
        # the comment here said exactly that, and it certified the defect above.
        build_out=$( cd "$TREE" && bash monitor/public-mirror/build.sh --yes --allow-dirty 2>&1 ); build_rc=$?
        if (( build_rc != 0 )); then
            RESIDUE_ASSERTS=1
            fail "build.sh exit $build_rc — cannot scan a tree that did not build: $(tail -2 <<<"$build_out" | tr '\n' ' ')"
        else
            pass "build.sh exits 0 (residue scan has a tree to scan)"
            # Potency of the scanner itself, before believing any zero it
            # reports: a string that IS present must be found.
            if ( cd "$TREE" && git grep -qiF -- 'nexus' ) ; then
                pass "residue scanner is potent (a control string present in the tree is found)"
            else
                fail "residue scanner found nothing for a control string that is certainly present — a zero from it would be meaningless"
            fi
            keep_re=""
            [ -s "$KEEPS" ] && keep_re=$(paste -sd'|' "$KEEPS")
            survivors=0; survivor_lines=""
            n_checked=0
            while IFS= read -r s; do
                [ -n "$s" ] || continue
                n_checked=$((n_checked+1))
                hits=$( cd "$TREE" && git grep -inF -- "$s" 2>/dev/null )
                # Discount exactly what leak-gate.sh discounts. A SOURCE that is
                # a prefix of a form the dictionary deliberately protects (the
                # sentinel round-trip restores it verbatim) is not a rule that
                # failed to fire.
                [ -n "$keep_re" ] && hits=$(printf '%s\n' "$hits" | grep -vE "$keep_re")
                hits=$(printf '%s\n' "$hits" | sed '/^$/d')
                if [ -n "$hits" ]; then
                    survivors=$((survivors+1))
                    # Locate the RULE, not the first line that happens to quote
                    # the string — the prose above a rule mentions it too.
                    survivor_lines+=" $(awk -F'\t' -v s="$s" '$1=="map" && $2==s {print NR; exit}' "$MAPPING")"
                fi
            done < "$SRCS"
            if (( survivors == 0 )); then
                pass "no map SOURCE survives the build ($n_checked non-sentinel rule(s) checked)"
            else
                fail "$survivors of $n_checked map SOURCE(s) still present in the BUILT tree — those rules do not fire. mapping.tsv line(s):$survivor_lines"
            fi

            # AND THE GATE ITSELF, on the tree that would actually be published.
            # Every assertion above is about the dictionary's internal
            # consistency, which says nothing about a category DELETED from it:
            # drop a `map` rule and its SOURCE simply leaves the population, so
            # "no map SOURCE survives" holds vacuously. That mutant survived
            # until this ran. The `deny` half is what still remembers, so ask
            # it — and this is the one assertion whose subject is the artifact
            # rather than the recipe.
            # STAGE first, deliberately. `git write-tree` records the index, so
            # staging is what makes the gate's subject the artifact that would
            # actually be published rather than a working copy nobody pushes.
            # The gate now REFUSES an unstaged tree (exit 5) for that reason, so
            # this is not appeasing a check — it is asking the right question.
            git -C "$TREE" add -A >/dev/null 2>&1
            git -C "$TREE" ls-files > "$WORK/pop.gate" 2>/dev/null || : > "$WORK/pop.gate"

            # ---- POPULATION-DRIFT INVARIANT ------------------------------
            #
            # Keyed on the PROPERTY, not on the shape of the fix above: the set
            # of paths the GATE judges must be reachable from the set the SCRUB
            # iterated. Remove the `add -A` before the build and this goes red
            # on its own, without anyone having planted a denied token — which
            # is the point. A guard that only fires when a leak also happens to
            # be present cannot tell you your instrument drifted.
            #
            # build.sh's own path effects: it DROPS `exclude` paths and MOVES
            # `rename` sources to targets, both after the scrub loop. So the
            # reachable set is pop.build plus the rename targets; anything in
            # pop.gate outside it is a path the scrub loop never saw.
            : > "$WORK/pop.expected"
            cat "$WORK/pop.build" >> "$WORK/pop.expected"
            if [ -r "$PM/overlay/renames.tsv" ]; then
                grep -v '^[[:space:]]*#' "$PM/overlay/renames.tsv" \
                    | awk -F'\t' '$1=="rename" && $3!=""{print $3}' >> "$WORK/pop.expected"
            fi
            # sort before comm — comm compares LEXICALLY and silently
            # misreports unsorted input.
            sort -u "$WORK/pop.expected" > "$WORK/pop.expected.s"
            sort -u "$WORK/pop.gate"     > "$WORK/pop.gate.s"
            comm -23 "$WORK/pop.gate.s" "$WORK/pop.expected.s" > "$WORK/pop.unscrubbed"
            n_unscrubbed=$(grep -c . "$WORK/pop.unscrubbed" || true)
            if (( n_unscrubbed == 0 )); then
                pass "gate population is reachable from the scrub population ($(grep -c . "$WORK/pop.gate.s" || true) path(s) judged, $n_untracked untracked source file(s) injected, $n_untracked_skipped skipped over ${_inject_max} bytes)"
            else
                fail "$n_unscrubbed path(s) are judged by the leak gate but were NOT in the index the scrub loop iterated — the gate is reading unscrubbed bytes: $(awk 'NR<=3' "$WORK/pop.unscrubbed" | tr '\n' ' ')"
            fi

            gate_out=$( cd "$TREE" && bash monitor/public-mirror/leak-gate.sh "$MAPPING" . 2>&1 ); gate_rc=$?
            if (( gate_rc == 0 )); then
                pass "leak-gate PASSES the STAGED built tree (the artifact, not just the dictionary)"
            else
                # `awk NR<=3` rather than `head -3`: head closes the pipe
                # early, which puts this file on the early-exit-reader axis
                # (#622's family) for nothing more than a diagnostic string.
                # awk drains its input, so no writer ever sees EPIPE. The line
                # content is stripped before printing — a leak-gate hit quotes
                # the offending line, and this suite must not reproduce it.
                #
                # THE TWO CAUSES PRINTED APART (your-org/nexus-code#1109 ask 3,
                # #1217). This sentence used to be one string for two findings
                # that call for opposite responses: "a denied token SURVIVED the
                # scrub" is a disclosure and the tree must not ship, while "this
                # path was never scrubbed because it was not in the build-time
                # index" is a defect in this harness and says nothing about the
                # artifact. A reader could not tell them apart, because the gate
                # is correct to withhold the token — so the only honest
                # discriminator is one that needs no token at all: PATH
                # MEMBERSHIP in pop.unscrubbed, computed above.
                _off=$(grep -v '^LEAK GATE' <<<"$gate_out" | sed 's/:[0-9]*:.*//' | sed '/^$/d' | sort -u)
                _survived=$(comm -23 <(printf '%s\n' "$_off" | sed '/^$/d') "$WORK/pop.unscrubbed")
                _never=$(comm -12 <(printf '%s\n' "$_off" | sed '/^$/d') "$WORK/pop.unscrubbed")
                _ns=$(printf '%s\n' "$_survived" | grep -c . || true)
                _nn=$(printf '%s\n' "$_never"    | grep -c . || true)
                fail "leak-gate FAILS the built tree — $_ns path(s) SURVIVED THE SCRUB (a denied token the dictionary does not reach: treat as a disclosure)$( [ "$_ns" -gt 0 ] && printf ' [%s]' "$(printf '%s\n' "$_survived" | awk 'NR<=3' | tr '\n' ' ')" ); $_nn path(s) NEVER SCRUBBED (absent from the build-time index: a harness defect, not a leak)$( [ "$_nn" -gt 0 ] && printf ' [%s]' "$(printf '%s\n' "$_never" | awk 'NR<=3' | tr '\n' ' ')" )"
            fi

            # And the mechanism that makes the line above load-bearing: an
            # UNSTAGED tree must be refused, not passed. Before this, running
            # the recipe and omitting `git add -A` returned 0 here while the
            # tree `git write-tree` produces carried 512 leaking files
            # (your-org/nexus-code#979 F2). Dirty the tree and confirm.
            #
            # INSIDE this branch, deliberately. It used to sit after the
            # closing `fi` of the whole residue section, where `$TREE` is
            # unset — so `NEXUS_SKIP_MIRROR_BUILD=1`, the opt-out this file's
            # own header advertises, died on `TREE: unbound variable` under
            # `set -u` AFTER printing eleven PASS lines and BEFORE the summary
            # or the assertion-count guard. A caller reading the tail saw
            # passes and no verdict.
            printf '\n' >> "$TREE/README.md" 2>/dev/null || true
            ( cd "$TREE" && bash monitor/public-mirror/leak-gate.sh "$MAPPING" . >/dev/null 2>&1 )
            if (( $? == 5 )); then
                pass "leak-gate REFUSES an unstaged tree (exit 5) instead of vouching for one it cannot see"
            else
                fail "leak-gate did not refuse an unstaged tree — a PASS there describes a tree nobody would ship"
            fi
            git -C "$TREE" checkout -- README.md >/dev/null 2>&1 || true
        fi
    fi
fi

# --- assertion-count guard -------------------------------------------------
#
# Eleven fixed assertions (4 anti-vacuity, 2 reporter-potency,
# 1 tracked-manifest + 1 no-op-rule + 1 map-subset-deny
# invariant, 2 gate
# potency) plus the residue section, which contributes 6 when the build runs
# and 1 when it declines — declared by the branch itself rather than inferred
# from the total, so a branch that silently drops out cannot be absorbed as a
# smaller green number nobody reads.
#
# THE SKIP BRANCH MUST REACH THIS LINE. It did not: the unstaged-refusal
# assertion used to sit outside the residue section and dereference `$TREE`,
# which only the build branch assigns, so `NEXUS_SKIP_MIRROR_BUILD=1` killed
# the script on `TREE: unbound variable` before any summary was printed. This
# guard is the thing that would have reported the shortfall, and it was
# downstream of the death (your-org/nexus-code#1109).
EXPECTED_ASSERTIONS=$(( 11 + RESIDUE_ASSERTS + 1 ))
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} + 1 ))
if (( TOTAL_ASSERTIONS == EXPECTED_ASSERTIONS )); then
    pass "assertion total is exactly $EXPECTED_ASSERTIONS (11 fixed + $RESIDUE_ASSERTS residue + 1)"
else
    fail "assertion total $TOTAL_ASSERTIONS != expected $EXPECTED_ASSERTIONS — a branch was skipped or ran short"
fi

th_summary_and_exit
