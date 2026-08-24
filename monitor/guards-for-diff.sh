#!/usr/bin/env bash
# guards-for-diff.sh — "which guards scan what I just changed?"
# your-org/nexus-code#803.
#
# Usage:
#   bash monitor/guards-for-diff.sh [--base <ref>] [--run] [--quiet]
#
#   --base <ref>  compare against <ref> (default: the first of `origin/dev`,
#                 `dev`, `origin/main`, `main` that resolves). Changed files are
#                 `<ref>...HEAD` PLUS everything uncommitted, staged and
#                 untracked — a pre-push helper that ignored the working tree
#                 would answer about a state you are not pushing.
#   --run         run the selected guards, in order, and report each verdict.
#   --quiet       selected guard commands only, one per line, for scripting.
#   --changed-files <file>
#                 read the changed-file list from <file> instead of computing
#                 it from git. A first-class flag rather than a test hook: the
#                 selector is the part worth planting fixtures against, and a
#                 seam that only exists under test is a seam nobody exercises
#                 the way it is used.
#   --suites-from <file>
#                 consider exactly the suites listed in <file> instead of
#                 discovering them. Same rationale; it is what lets
#                 test-guards-for-diff.sh plant a BROKEN guard and assert this
#                 script refuses rather than silently dropping it.
#
# Exit codes:
#   0  at least one registered guard reads a file in your diff (or, under
#      --run, they all passed)
#   1  --run: a selected guard FAILED
#   2  REFUSED — a guard's population probe errored, or the diff could not be
#      computed. Fail-closed: an index that silently drops a guard it could not
#      ask is worse than no index, because its answer looks the same.
#   3  NO registered guard reads your diff. Not an error and not a clearance:
#      the considered list is printed in full, because "0 selected" and "the
#      index did not run" are indistinguishable to anyone reading a summary,
#      and that conflation is this repo's dominant defect class.
#
# ---------------------------------------------------------------------------
# WHAT THIS IS FOR
# ---------------------------------------------------------------------------
#
# A PR's green covers the suites its DIFF TOUCHES, not the suites its CHANGE
# AFFECTS. Three occurrences in one night: a worker changed X, ran the suites
# near X, they passed, it pushed, and the guard that reddened was one whose
# scanned POPULATION X had just entered — a population defined by SOURCE
# CONSTRUCT, not by directory. The sharpest of the three (`#796`) pinned its
# OWN coverage boundary as data and still tripped two other data-pinned
# boundaries: doing the discipline correctly for your own change does not tell
# you whose boundary you just crossed.
#
# "Run the full suite" is the workaround and should still happen before a push.
# But it is ~570 s across 270 files, so in practice workers run what they
# believe is relevant — and BELIEVING CORRECTLY is precisely what failed three
# times. This removes the belief for the guards that declare themselves.
#
# ---------------------------------------------------------------------------
# HOW A GUARD BECOMES VISIBLE HERE — the protocol, not a registry
# ---------------------------------------------------------------------------
#
# There is no list of guards in this file. A guard is discovered iff it
# IMPLEMENTS the `--population` protocol (monitor/_guard_population.sh), and the
# discovery predicate is the implementation itself — the literal call
# `gp_handle "$@"` together with a `gp_population()` definition — not a name, a
# directory, or a comment that could drift away from it. Teaching a guard the
# protocol enrols it; nothing else does, and nothing has to remember.
#
# The predicate is deliberately the CALL and not the flag string. A file merely
# MENTIONING `--population` in prose would be probed, would not answer, and
# would therefore RUN — a discovery rule whose false positive is "execute an
# arbitrary test suite" is not a discovery rule. See GFD_DECL2 below for the
# residual case (a suite that PLANTS a fixture) and how it is resolved.
#
# ---------------------------------------------------------------------------
# COVERAGE BOUNDARY, on the axis the MECHANISM varies on — HOW A GUARD
# DECLARES WHAT IT READS. Pinned as DATA by
# monitor/watcher/guard-populations.manifest and asserted by
# monitor/watcher/test-guards-for-diff.sh, because prose cannot be made to
# fail. Stated so it can be disagreed with:
#
#   1. A guard that does not implement the protocol is INVISIBLE here. That is
#      the residual, and this script PRINTS ITS SIZE on every run rather than
#      leaving the reader to infer that the guards it names are all of them.
#      The fix for a missed guard is to teach it `gp_population`; the number is
#      a ratchet and should only fall.
#
#   2. Selection is by READ, not by EFFECT. A guard that reads your file may be
#      wholly unaffected by your edit, so this OVER-selects on purpose. The
#      converse — a guard that does not read your file cannot be affected by
#      editing it — is the sound half, and it is the half selection needs.
#      Exception, and it is the one that matters: a guard whose verdict depends
#      on RUNTIME STATE your change produces rather than on a file it reads (a
#      tmux server's answers, a CI run's conclusions, an installed binary's
#      version) is not describable as a path set at all, and no `--population`
#      answer covers it.
#
#   3. THE ANSWER IS ABOUT YOUR TREE, NOT ABOUT THE MERGE. Populations are
#      computed by running each guard's enumerator against the working tree you
#      have. A guard whose population DEFINITION changed on another branch will
#      select differently once both land. That is `#803`'s FIRST occurrence
#      exactly — `#791` taught the scope guard's resolver to resolve
#      extensionless nodes, which put `monitor/ng` into P2's population for the
#      first time, while `#781` independently added a violating pair to `ng`;
#      neither PR was red alone and the pair was. No per-branch index can see
#      that, this one included, and it says so in its own footer rather than
#      leaving it to be rediscovered.
#
#   4. A guard's declaration is only as wide as its own enumerator. The
#      protocol asks the guard; it cannot audit the answer.
#
#   5. AN UNTRACKED FILE IS INVISIBLE TO A `git ls-files` POPULATION. Several
#      enrolled guards enumerate that way, so a file you have written and not
#      yet `git add`ed can show as scanned by nobody — under-selecting for the
#      change most likely to ENTER a population. This is not left implicit: the
#      report NAMES your untracked changed files and says to re-run after
#      adding them. Found by this tool failing to select on its own new files.

set -uo pipefail

_gfd_self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_gfd_self/.." && pwd)

# The literal that IS the protocol implementation — see "HOW A GUARD BECOMES
# VISIBLE" above. Kept in one place so the discovery predicate and the library
# cannot drift apart.
GFD_DECL='gp_handle "$@"'
# …AND a `gp_population()` definition. Two tokens, not one: a file carrying only
# the call is quoting it (in prose, in a diagnostic, in half a fixture) rather
# than implementing it, and probing such a file RUNS it.
#
# WHAT THE SECOND TOKEN DOES NOT FIX, stated because the obvious reading is
# wrong: a suite that plants a COMPLETE protocol fixture carries both tokens and
# is still only quoting them. `test-guards-for-diff.sh` does exactly that, on
# purpose. No text predicate separates quoting from implementing — that would
# need a parse, and a heredoc-blind one would be the very defect this repo keeps
# re-learning. The resolution is not a cleverer regex: such a suite must ITSELF
# implement the protocol, which that one does and declares in the manifest. If a
# future one does not, the failure is LOUD — the probe runs the suite, no
# population comes back, and this script REFUSES — never a silent miscovering.
GFD_DECL2='gp_population()'

# The operator's interactive `grep` is a ugrep wrapper honouring .gitignore
# (your-org/nexus-code#618), and a discovery that silently matched nothing
# would report "no guards exist". Bind the real binary.
GREP=$(type -P grep 2>/dev/null) || GREP=/bin/grep

base_ref=""
do_run=0
quiet=0
changed_from=""
suites_from=""
while (( $# )); do
    case "$1" in
        --base)  base_ref="${2:-}"; shift 2 ;;
        --run)   do_run=1; shift ;;
        --quiet) quiet=1; shift ;;
        --changed-files) changed_from="${2:-}"; shift 2 ;;
        --suites-from)   suites_from="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'guards-for-diff: unknown argument %q\n' "$1" >&2; exit 2 ;;
    esac
done

cd "$REPO_ROOT" || exit 2

# ---------------------------------------------------------------------------
# THE DIFF
# ---------------------------------------------------------------------------
_gfd_pick_base() {
    local r
    for r in origin/dev dev origin/main main; do
        if git rev-parse --verify --quiet "$r" >/dev/null 2>&1; then
            printf '%s' "$r"; return 0
        fi
    done
    return 1
}

if [[ -n "$changed_from" ]]; then
    [[ -r "$changed_from" ]] || {
        printf 'guards-for-diff: REFUSED — --changed-files %q is unreadable.\n' \
            "$changed_from" >&2
        exit 2
    }
    base_ref="(supplied: $changed_from)"
    changed=$(sort -u "$changed_from" | "$GREP" -v '^$')
elif [[ -z "$base_ref" ]]; then
    base_ref=$(_gfd_pick_base) || {
        printf 'guards-for-diff: REFUSED — no base ref resolves (tried origin/dev,\n' >&2
        printf '  dev, origin/main, main). Pass --base <ref>. Auditing against an\n' >&2
        printf '  unknown base would report a diff nobody asked about.\n' >&2
        exit 2
    }
fi

# Merge-base form (`A...B`), so a base that has moved ahead does not present
# other people's commits as your change.
if [[ -z "$changed_from" ]]; then
    if ! git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
        printf 'guards-for-diff: REFUSED — base ref %q does not resolve.\n' "$base_ref" >&2
        exit 2
    fi
    changed=$(
        {
            git diff --name-only "$base_ref"...HEAD 2>/dev/null
            git diff --name-only HEAD 2>/dev/null           # unstaged
            git diff --name-only --cached 2>/dev/null       # staged
            git ls-files --others --exclude-standard 2>/dev/null
        } | sort -u | "$GREP" -v '^$'
    )
fi
n_changed=$(printf '%s\n' "$changed" | "$GREP" -c . || true)

# ---------------------------------------------------------------------------
# DISCOVERY — every tracked test suite that implements the protocol
# ---------------------------------------------------------------------------
#
# `git ls-files` with a GLOB pathspec, never `git ls-tree` (whose pathspecs are
# path PREFIXES and which returns a confident zero here — your-org/nexus-code#770).
if [[ -n "$suites_from" ]]; then
    [[ -r "$suites_from" ]] || {
        printf 'guards-for-diff: REFUSED — --suites-from %q is unreadable.\n' \
            "$suites_from" >&2
        exit 2
    }
    all_suites=$(sort -u "$suites_from" | "$GREP" -v '^$')
else
    all_suites=$(git ls-files -- '*test-*.sh' 2>/dev/null | sort)
fi
n_suites=$(printf '%s\n' "$all_suites" | "$GREP" -c . || true)
# The floor applies to the DERIVED enumeration only: with an explicit list the
# caller has said what to consider, and refusing a two-line list would be a
# floor on the wrong thing. It is the derived path that can go silently blind.
if [[ -z "$suites_from" ]] && (( n_suites < 50 )); then
    printf 'guards-for-diff: REFUSED — the suite enumeration returned %d files.\n' "$n_suites" >&2
    printf '  This repo has hundreds. A scan that cannot see the corpus reports a\n' >&2
    printf '  clean sweep, which is indistinguishable from having no guards at all.\n' >&2
    exit 2
fi

declaring=$(
    printf '%s\n' "$all_suites" | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        "$GREP" -qF -- "$GFD_DECL" "$f" 2>/dev/null || continue
        "$GREP" -qF -- "$GFD_DECL2" "$f" 2>/dev/null && printf '%s\n' "$f"
    done
)
n_declaring=$(printf '%s\n' "$declaring" | "$GREP" -c . || true)
if (( n_declaring == 0 )); then
    printf 'guards-for-diff: REFUSED — no suite implements the --population\n' >&2
    printf '  protocol. Either the discovery predicate (%q) has drifted from\n' "$GFD_DECL" >&2
    printf '  monitor/_guard_population.sh, or the enrolment was reverted. An\n' >&2
    printf '  empty index would print "0 guards scan your diff", which is the\n' >&2
    printf '  same sentence a working index prints for a docs-only change.\n' >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# PROBE + INTERSECT
# ---------------------------------------------------------------------------
sel_names=(); sel_why=(); exc_names=(); exc_sizes=()
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$changed" > "$tmp/changed"

while IFS= read -r suite; do
    [[ -n "$suite" ]] || continue
    # A bounded probe. `--population` is meant to answer without doing the
    # suite's work, so a probe that runs long is a broken declaration, not a
    # slow one — and hanging the pre-push helper is how it stops being used.
    # rc captured into a variable, NOT read as `$?` inside the `then` block:
    # after `if ! cmd; then`, `$?` is the status of the NEGATED condition — 0 or
    # 1 — not the probe's real exit code. A diagnostic that confidently prints
    # the wrong number is this file's own subject matter, and the timeout arm
    # (124) is exactly the case where the number is the diagnosis.
    probe_rc=0
    timeout 180 bash "$suite" --population > "$tmp/pop" 2>"$tmp/err" || probe_rc=$?
    if (( probe_rc != 0 )); then
        printf 'guards-for-diff: REFUSED — %s --population failed (rc %d).\n' \
            "$suite" "$probe_rc" >&2
        sed 's/^/    /' "$tmp/err" >&2
        printf '  Refusing to report a selection with a guard silently dropped from\n' >&2
        printf '  it: a guard the index could not ask looks exactly like a guard that\n' >&2
        printf '  does not read your diff.\n' >&2
        exit 2
    fi
    sort -u "$tmp/pop" > "$tmp/pop.s"
    # `sed -n '1,6p'`, NOT `head -6`. `head` closes the pipe as soon as it has
    # its six lines, which SIGPIPEs `comm`; under this script's `pipefail` the
    # pipeline then reports 141, and the next reader of that status inverts the
    # verdict — your-org/nexus-code#622's shape with a different reader, which
    # `monitor/watcher/early-exit-readers.sh` enumerates and this file would
    # otherwise have joined. `sed` without a `q` DRAINS its input, so it cannot
    # close the pipe early. (Found by test-early-exit-reader-manifest.sh going
    # red on this file — which is #803's own mechanism catching #803's own
    # remedy, and is why it is worth writing down rather than just fixing.)
    hits=$(comm -12 "$tmp/pop.s" "$tmp/changed" | sed -n '1,6p')
    size=$(wc -l < "$tmp/pop.s" | tr -d ' ')
    if [[ -n "$hits" ]]; then
        sel_names+=( "$suite" )
        sel_why+=( "$(printf '%s' "$hits" | tr '\n' ' ')" )
    else
        exc_names+=( "$suite" )
        exc_sizes+=( "$size" )
    fi
done <<<"$declaring"

if (( quiet )); then
    (( ${#sel_names[@]} )) && printf 'bash %s\n' "${sel_names[@]}"
    (( ${#sel_names[@]} )) || exit 3
    exit 0
fi

# ---------------------------------------------------------------------------
# THE REPORT
# ---------------------------------------------------------------------------
printf '=== guards-for-diff (your-org/nexus-code#803) ===\n'
printf 'base            : %s\n' "$base_ref"
if [[ -n "$changed_from" ]]; then
    printf 'changed files   : %d (supplied list, not computed from git)\n' "$n_changed"
else
    printf 'changed files   : %d (committed vs base + staged + unstaged + untracked)\n' "$n_changed"
fi
printf 'guards declaring: %d of %d tracked test suites\n' "$n_declaring" "$n_suites"
printf '\n'

if (( ${#sel_names[@]} )); then
    printf 'SELECTED — these guards READ a file you changed:\n'
    for i in "${!sel_names[@]}"; do
        printf '  %s\n' "${sel_names[$i]}"
        printf '      because it reads: %s\n' "${sel_why[$i]}"
    done
else
    # The loud empty. A helper that silently selects nothing is this repo's
    # dominant defect class wearing a new hat, so the considered list is
    # printed IN FULL here and the exit code is its own.
    printf 'SELECTED: NONE.\n'
    printf '  %d guards were CONSIDERED and none of them reads any file in your\n' "$n_declaring"
    printf '  diff. That is a measured answer, not an absence of one — the\n'
    printf '  considered list is below, with each population size.\n'
fi

printf '\nCONSIDERED AND EXCLUDED — read none of your changed files:\n'
if (( ${#exc_names[@]} )); then
    for i in "${!exc_names[@]}"; do
        printf '  %-56s population %s files\n' "${exc_names[$i]}" "${exc_sizes[$i]}"
    done
else
    printf '  (none — every declaring guard was selected)\n'
fi

# THE UNTRACKED WARNING, and it is not a nicety. Several enrolled guards derive
# their population from `git ls-files`, which cannot see a file you have written
# and not yet `git add`ed — so the index under-selects for exactly the change
# most likely to ENTER a population, namely adding a file. Found by this tool
# failing to select on its own new files; stated here rather than left for the
# next person to trip over.
untracked=$(printf '%s\n' "$changed" | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || printf '%s\n' "$f"
done)
n_untracked=$(printf '%s\n' "$untracked" | "$GREP" -c . || true)
if (( n_untracked > 0 )); then
    printf '\nUNTRACKED (%d of %d changed files):\n' "$n_untracked" "$n_changed"
    printf '%s\n' "$untracked" | sed 's/^/  /'
    printf '  Populations derived from `git ls-files` CANNOT SEE these, so a guard\n'
    printf '  that would scan them may show as excluded above. `git add` them and\n'
    printf '  re-run before trusting the exclusions — adding a file is the change\n'
    printf '  most likely to enter a population.\n'
fi

printf '\nWHAT THIS DOES NOT COVER — read it before treating a green as coverage:\n'
printf '  * %d of %d tracked test suites do not declare a population and are\n' \
    "$(( n_suites - n_declaring ))" "$n_suites"
printf '    INVISIBLE to this index. It is not a substitute for the full suite.\n'
printf '  * Populations are computed against THIS tree. A guard whose population\n'
printf '    DEFINITION changed on another branch selects differently after merge\n'
printf '    — your-org/nexus-code#803'\''s first occurrence (#781 x #791) is exactly\n'
printf '    that, and no per-branch index can see it.\n'
printf '  * Selection is by what a guard READS, not by what your edit AFFECTS.\n'

if (( do_run )); then
    if (( ${#sel_names[@]} == 0 )); then
        printf '\n--run: nothing selected, so nothing was run. That is not a pass.\n'
        exit 3
    fi
    printf '\n=== running %d selected guard(s) ===\n' "${#sel_names[@]}"
    rc=0
    for s in "${sel_names[@]}"; do
        printf -- '--- %s\n' "$s"
        if bash "$s"; then
            printf '    PASS %s\n' "$s"
        else
            printf '    FAIL %s\n' "$s"
            rc=1
        fi
    done
    exit "$rc"
fi

(( ${#sel_names[@]} )) || exit 3
exit 0
