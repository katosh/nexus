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
#   --timeout <s> stop starting new guards after <s> seconds, and bound the
#                 guard that is running to the remaining budget PLUS a 15s
#                 SIGKILL grace (default 0 = unbounded, the historical
#                 behaviour). The worst case is <s>+15s, NOT <s>: a guard that
#                 ignores TERM is killed 15s after the deadline rather than
#                 waited on forever, which is what this flag did before
#                 your-org/nexus-code#1135 skeptic F2 measured 40s under
#                 `--timeout 5`. Guards left without a verdict — never started,
#                 or started and cut off — are NAMED and the run exits 5; a
#                 truncated sweep must not read as a clean one
#                 (your-org/nexus-code#965).
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
#   4  --run: every selected guard that ran came back green, but at least one
#      of those greens is UNVERIFIED — the guard's population does not contain
#      an UNTRACKED file in your diff, so its pass is a claim about a tree that
#      does not contain that file (your-org/nexus-code#1054). Distinct from 0
#      precisely so a caller cannot read it as a clearance. `git add` the named
#      files and re-run to convert it into a real verdict.
#   5  --run: the --timeout deadline expired with selected guards left WITHOUT A
#      VERDICT — never started, or started and cut off mid-run. They are named.
#      A guard that did not finish is not a guard that passed, and
#      before this code a truncated --run was indistinguishable from a clean
#      one — measured on #946, where --run selected the right guard, was killed
#      by an external 2-minute ceiling before reaching it, and its silence
#      covered a real red (your-org/nexus-code#965).
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
#   5. AN UNTRACKED FILE IS INVISIBLE TO A `git ls-files` POPULATION, and it
#      cuts BOTH WAYS. Several enrolled guards enumerate that way, so a file you
#      have written and not yet `git add`ed can show as scanned by nobody —
#      under-selecting for the change most likely to ENTER a population. This is
#      not left implicit: the report NAMES your untracked changed files and says
#      to re-run after adding them. Found by this tool failing to select on its
#      own new files.
#
#      THE OTHER DIRECTION IS WORSE AND WAS THE LATER FINDING (#1054). SELECTION
#      counts the full working set — committed vs base + staged + unstaged +
#      UNTRACKED — while a population guard enumerates `git ls-files`, i.e.
#      TRACKED ONLY. So this tool can select a guard BECAUSE OF an untracked
#      file, run it, and report a confident green from a guard that cannot see
#      that file. Measured, content held constant and trackedness the only
#      variable: the same planted reader scored 21 passed / 0 failed while
#      untracked and 20 passed / 1 failed once `git add`ed.
#
#      The pre-existing warning below does NOT cover this: it is about
#      EXCLUSIONS, and a reader who finds their guard under SELECTED reasonably
#      concludes the caveat is not about them — which is exactly what happened.
#      So the VERDICT itself is qualified rather than a second warning added:
#      a green from a guard whose population omits an untracked changed file is
#      printed as UNVERIFIED, and --run exits 4. A red stays red; a guard that
#      can see every untracked changed file still prints PASS.
#
#      Note what makes this decidable WITHOUT a new declaration protocol: the
#      populations are already computed here, and "this guard's population does
#      not contain that file" is a FACT about data in hand, not an inference
#      about how the guard enumerates. A guard that reaches untracked files by
#      some other means is therefore never falsely downgraded.

set -uo pipefail

# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924) — see monitor/ng for
# the full rationale. Each iteration must consume at least one argument; a
# value-taking flag given LAST otherwise spins forever, and a hang on this
# board is worse than an error because nothing surfaces it.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

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
run_timeout=0
_argloop_prev_1=-1; while (( $# )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --base)  base_ref="${2:-}"; shift 2 ;;
        --run)   do_run=1; shift ;;
        --timeout) run_timeout="${2:-}"; [[ -n "$run_timeout" ]] || _argloop_stuck "$1"; shift 2 ;;
        --quiet) quiet=1; shift ;;
        --changed-files) changed_from="${2:-}"; shift 2 ;;
        --suites-from)   suites_from="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'guards-for-diff: unknown argument %q\n' "$1" >&2; exit 2 ;;
    esac
done

if ! [[ "$run_timeout" =~ ^[0-9]+$ ]]; then
    printf 'guards-for-diff: --timeout must be a non-negative integer (got %q)\n' \
        "$run_timeout" >&2
    exit 64
fi

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
#
# …AND `:(glob)`, because that is only HALF the lesson (your-org/nexus-code#1111,
# #954). `ls-files` pathspecs are globs, but git matches them with `fnmatch`
# WITHOUT `FNM_PATHNAME`, so a bare `*` CROSSES `/`. `'*test-*.sh'` therefore
# matched any path with `test-` in a DIRECTORY component, and this repo has one:
# `monitor/watcher/test-integration/`. Measured at 7c4ddbb:
#
#   git ls-files -- '*test-*.sh'            -> 368   <- what this line used to be
#   git ls-files -- ':(glob)**/test-*.sh'   -> 366
#
# The two extras were `test-integration/_harness.sh` (a shared library) and
# `test-integration/stub-claude.sh` (a `claude` shim). Neither is a suite,
# neither answers `--population`, and neither is dispatched as a test. So EVERY
# `N of M tracked test suites` line below — the enrolled ratio and the
# blind-spot count alike — overstated `M` by 2.
#
# RECONCILED A SECOND WAY, independently of git pathspecs altogether: the
# runner dispatches by BASENAME, `find monitor .github -name "test-*.sh" -type f`
# (run-tests.sh), which returns **366** on the same tree. The corrected
# predicate agrees with the thing that actually runs the suites; the old one did
# not. That the two agree also establishes there is no `test-*.sh` outside
# `monitor/` and `.github/`, since the git side scans the whole repo.
#
# The single `**/` pathspec covers a ROOT-level suite too — measured with a
# planted `test-<x>.sh` at the repo root, matched via `--others`. So the second
# `'test-*.sh'` pathspec that suggests itself here is redundant, and would have
# to be written `':(glob)test-*.sh'` anyway: an unprefixed one re-introduces the
# exact defect this comment is about, inside its own remedy.
if [[ -n "$suites_from" ]]; then
    [[ -r "$suites_from" ]] || {
        printf 'guards-for-diff: REFUSED — --suites-from %q is unreadable.\n' \
            "$suites_from" >&2
        exit 2
    }
    all_suites=$(sort -u "$suites_from" | "$GREP" -v '^$')
else
    all_suites=$(git ls-files -- ':(glob)**/test-*.sh' 2>/dev/null | sort)
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
sel_names=(); sel_why=(); sel_blind=(); exc_names=(); exc_sizes=()
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$changed" > "$tmp/changed"

# UNTRACKED CHANGED FILES — computed HERE, before the probe loop, because the
# per-guard verdict now depends on them (your-org/nexus-code#1054). It used to
# be derived at report time purely to print a warning.
#
# TWO CONDITIONS, AND THE SECOND ONE IS THE WHOLE OF your-org/nexus-code#1179.
#
# `git ls-files --error-unmatch <f>` is the authoritative "is this path in the
# index" question, and for a long time it was the only one asked. It is true
# and it answers the wrong question. The question #1054 needs is not "is this
# path in the index" but **"is this a file the guard SHOULD have seen and
# could not?"** — and a path that is not in the index because it was DELETED is
# one the guard correctly does not see. There is nothing there to be blind to.
#
# The two are indistinguishable by index membership alone, so a `git rm`, and
# every rename git does not resolve to an `R`, was classified `untracked`.
# Measured on a throwaway clone of this repo at `50c36ef`, one commit that
# modifies `monitor/ng` and deletes one fixture, everything else held constant:
# `UNTRACKED (1 of 2 changed files)` naming the deleted path, every selected
# guard `BLIND TO` it, every green `UNVERIFIED`, and `--run` exit 4 on a fully
# committed, clean tree.
#
# AND THE PRINTED REMEDY WAS UNREACHABLE, which is what made it corrosive
# rather than merely noisy: the report says "`git add` and re-run", and you
# cannot `git add` a path that does not exist into `git ls-files`. So there was
# no state the author could reach in which that diff returned 0. Exit 4 exists
# precisely so an unverified green is not read as a clearance; a code that
# fires on every deletion and cannot be cleared trains the reader to dismiss
# it, and the next time it fires for the real #1054 reason it looks identical.
#
# ON THE SHAPE OF THE PREDICATE. Existence, NOT a `--diff-filter=D` subtraction.
# The filter form is a denylist of change shapes — D, and the source half of an
# R — with a permissive default arm, so a shape nobody enumerated falls through
# to `untracked`; and it cannot answer at all under `--changed-files`, where a
# supplied list carries no status. `-e` is the allowlist: a file that is in your
# diff, exists on disk, and is absent from the index is exactly and only the
# #1054 hazard. It needs no git plumbing and it answers identically on both
# input routes.
#
# WHAT THIS DELIBERATELY DOES NOT DO: it does not care WHY the path is absent
# from disk. A deletion, a rename's old half, a path supplied to
# `--changed-files` that never existed — all three are cases where no
# population can contain the path and no guard can be blind to it.
# BOUNDED: ONE `git` PER BATCH, NOT ONE PER CHANGED FILE
# (your-org/nexus-code#1254 item 2).
#
# This loop used to spawn `git ls-files --error-unmatch` once per changed file,
# under no timeout at all — the 180 s bound applies only to the probe loop
# BELOW it. So the last literal O(untracked files) walk in the tool sat in front
# of the only thing that could have announced it. Measured on a planted tree,
# per-file form: 1,000 files 4.89 s, 5,000 files 31.18 s — and #1254 measured
# 212 s at 50,000, i.e. past the whole tool's useful latency with NOTHING
# printed. Its failure direction is worse in kind than a refusal: it cannot exit
# 2, it just runs, so there is no announcement to read.
#
# The batched form asks git the SAME question — "which of these paths are in the
# index?" — once per `xargs` batch. Measured on the same trees: 0.099 s and
# 0.788 s, a 40–49x reduction, and the two forms returned IDENTICAL sets.
#
# WHY NOT `git ls-files --others --exclude-standard`, which #1254 proposes.
# Measured on a planted fixture, it CHANGES THE ANSWER: a path that is in your
# changed list, exists on disk and is absent from the index but is GITIGNORED
# is reported untracked by the shipped predicate and NOT by that one.
#
#     changed list: ignored/secret.txt, plain_untracked.txt, src/tracked.txt
#     shipped  (--error-unmatch)      -> ignored/secret.txt plain_untracked.txt
#     batched  (this form)            -> ignored/secret.txt plain_untracked.txt
#     --others --exclude-standard     -> plain_untracked.txt          <- DROPS one
#
# That narrowing is not cosmetic. A dropped path is one no guard is marked
# `BLIND TO`, so a green that is unverified reports as verified — #1054 running
# backwards, in the direction that manufactures confidence. It is reachable
# through `--changed-files`, where the supplied list carries no ignore status.
# So the performance fix is taken and the semantic change that came bundled with
# it is not.
#
# `[[ -e ]]` stays a shell BUILTIN test — no fork per file — so the existence
# half was never the cost. `GIT_LITERAL_PATHSPECS` stops a filename containing
# pathspec magic from being reinterpreted as a pattern.
#
# PLAIN `sort`, NOT `LC_ALL=C sort`, and that is deliberate. `untracked.s` is
# `comm`ed below against `pop.s`, which this file sorts in the AMBIENT locale;
# pinning C on one side of a comparison and not the other is a collation
# mismatch that `comm` resolves silently and wrongly on any path where the two
# orders differ (`-` and `_` against `.` are the ones this repo has). Sorting
# every side the same way is what makes the comparison sound — which locale
# that is does not matter, and agreeing with the file's existing convention is
# cheaper than converting every other sort in it.
printf '%s\n' "$changed" | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -e "$f" ]] || continue
    printf '%s\n' "$f"
done | sort -u > "$tmp/cand.s"
tr '\n' '\0' < "$tmp/cand.s" \
    | GIT_LITERAL_PATHSPECS=1 xargs -0 -r git ls-files -z -- 2>/dev/null \
    | tr '\0' '\n' | sort -u > "$tmp/cand.tracked"
untracked=$(comm -23 "$tmp/cand.s" "$tmp/cand.tracked")
n_untracked=$(printf '%s\n' "$untracked" | "$GREP" -c . || true)
printf '%s\n' "$untracked" | "$GREP" -v '^$' | sort -u > "$tmp/untracked.s" || true

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
        # #1054: which UNTRACKED changed files are absent from THIS guard's
        # population. `comm -13` = lines only in file 2 (untracked ∖ population).
        # A non-empty answer is a FACT — this guard did not scan those paths —
        # so any green it returns is a claim about a tree without them.
        sel_blind+=( "$(comm -13 "$tmp/pop.s" "$tmp/untracked.s" 2>/dev/null | tr '\n' ' ')" )
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
        if [[ -n "${sel_blind[$i]// /}" ]]; then
            printf '      BLIND TO (untracked, absent from its population): %s\n' \
                "${sel_blind[$i]}"
            printf '      → a green from this guard would be UNVERIFIED. `git add` and re-run.\n'
        fi
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
# (`untracked` / `n_untracked` were computed above the probe loop — the
# per-guard verdict depends on them now, not just this warning.)
if (( n_untracked > 0 )); then
    printf '\nUNTRACKED (%d of %d changed files):\n' "$n_untracked" "$n_changed"
    printf '%s\n' "$untracked" | sed 's/^/  /'
    printf '  Populations derived from `git ls-files` CANNOT SEE these, so a guard\n'
    printf '  that would scan them may show as excluded above. `git add` them and\n'
    printf '  re-run before trusting the exclusions — adding a file is the change\n'
    printf '  most likely to enter a population.\n'
    printf '  This warning is about EXCLUSIONS. The SELECTED direction is handled\n'
    printf '  separately and does not rely on you reading this: a guard blind to one\n'
    printf '  of these files is marked above, and under --run its green prints as\n'
    printf '  UNVERIFIED with exit 4 (your-org/nexus-code#1054).\n'
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
    unverified=0
    _n_sel=${#sel_names[@]}
    _reached=0
    _passed=0
    _failed=0
    unreached=()
    # THE DEADLINE (your-org/nexus-code#965). `--run` had no bound at all, so a
    # slow corpus under CPU contention simply outlived whatever was invoking it
    # — a 2-minute agent Bash-tool ceiling, in the measured occurrence — and the
    # guard it had CORRECTLY selected, the one that was red, was never reached.
    _deadline=0
    (( run_timeout > 0 )) && _deadline=$(( SECONDS + run_timeout ))
    for i in "${!sel_names[@]}"; do
        s="${sel_names[$i]}"
        blind="${sel_blind[$i]:-}"
        # STOP AT THE DEADLINE, and RECORD what was not reached. An unreached
        # guard is precisely the fail-closed case exit 2 and exit 3 already
        # exist for: a guard the tool could not ask looks exactly like a guard
        # with nothing to say.
        if (( _deadline > 0 )) && (( SECONDS >= _deadline )); then
            unreached+=("$s")
            continue
        fi
        # THE INDEX IS NOT DECORATION. Every line this loop prints already went
        # to the reader before the next guard started — bash's builtin `printf`
        # is not block-buffered, measured by SIGKILLing a producer mid-stream
        # and finding all five lines already in the capture file. So progress
        # was never the missing half. What was missing is that a SURVIVING
        # FRAGMENT could not describe itself: `--- some/suite.sh` tells you
        # nothing about how much is left, and if the announcement line above
        # is lost with the rest of a truncated capture, neither does anything
        # else. `[3/12]` is self-locating — one line is enough to know the run
        # did not finish.
        printf -- '--- [%d/%d] %s\n' "$(( i + 1 ))" "$_n_sel" "$s"
        _reached=$(( _reached + 1 ))
        _guard_cmd=( bash "$s" )
        if (( _deadline > 0 )); then
            _remain=$(( _deadline - SECONDS ))
            (( _remain < 1 )) && _remain=1
            # Bound the INDIVIDUAL guard too, not just the loop: without this a
            # single hanging guard consumes the whole budget and every guard
            # after it reports as unreached, which names the wrong culprit.
            #
            # `-k 15`, AND THAT IS NOT A DETAIL (your-org/nexus-code#1135
            # skeptic F2). Without it `timeout` sends TERM and then WAITS
            # FOREVER for a guard that ignores TERM. Measured: a guard doing
            # `trap "" TERM; sleep 40` under `--timeout 5` took **40 s**, while
            # this file's own `--help` promised to "bound the --run phase to
            # <s> seconds total". That is exactly the defect this branch fixes
            # in run-tests.sh for #1041 item 6 — a label claiming a ceiling the
            # code does not enforce — re-instantiated in the other file by the
            # same author in the same PR.
            #
            # The grace is NAMED rather than hidden, for the same reason #1041
            # item 6 names it rather than subtracting it: the honest bound is
            # `<remaining> + 15`, not `<remaining>`, and a tool that understates
            # its own worst case to look tidier is the instrument this whole
            # branch is about.
            _guard_cmd=( timeout -k 15 "$_remain" bash "$s" )
        fi
        _grc=0
        "${_guard_cmd[@]}" || _grc=$?
        # A GUARD THE BUDGET KILLED DID NOT FAIL — IT DID NOT FINISH. The first
        # cut of this change ran each guard under `timeout` and then took any
        # non-zero as FAIL, so a guard cut off by the deadline printed `FAIL`
        # and the run exited 1. That is a probe's failure presented as a
        # result: this tool's own subject matter, reproduced inside the fix for
        # it. Measured — a 20 s fixture guard under `--timeout 5` reported
        # `FAIL` and rc 1, indistinguishable from a guard that found something.
        #
        # `timeout` reports 124. Only read it as a budget kill when the
        # DEADLINE HAS ACTUALLY ARRIVED; otherwise a guard that exits 124 on
        # its own account keeps its verdict. That residual — a guard exiting
        # 124 at the very instant the deadline lands — is real and unresolvable
        # from an exit status alone, and it errs toward "not reached", which is
        # the fail-closed direction.
        # BOTH 124 AND 137. `timeout` reports 124 when TERM ended the guard and
        # 137 when the `-k` KILL escalation did. Matching only 124 would send
        # every TERM-ignoring guard straight back down the FAIL arm — so adding
        # `-k` to fix F2 would have re-broken the NOT-FINISHED classification
        # that #965's own fix exists to provide. Second-order, and the reason
        # this is not the one-word change it looks like.
        if (( _deadline > 0 )) && (( _grc == 124 || _grc == 137 )) \
           && (( SECONDS >= _deadline )); then
            printf '    NOT FINISHED %s%s\n' "$s" \
                "$( (( _grc == 137 )) && printf ' (SIGKILLed after the 15s grace — it ignored TERM)' )"
            printf '        the --timeout %ss budget expired while this guard was running;\n' "$run_timeout"
            printf '        it returned no verdict. This is NOT a failure and NOT a pass.\n'
            unreached+=("$s")
            _reached=$(( _reached - 1 ))
            continue
        fi
        if (( _grc == 0 )); then
            # #1054: a PASS from a guard whose population omits an untracked
            # changed file is NOT a pass — it is a green about a tree that does
            # not contain that file. Qualify the VERDICT rather than print
            # another warning beside it: the pre-existing untracked warning is
            # about EXCLUSIONS, and a reader who finds their guard under
            # SELECTED reasonably reads it as not applying to them.
            #
            # Only the GREEN is downgraded. A red is still a red (see the FAIL
            # arm), and a guard that can see every untracked changed file still
            # prints PASS — so this cannot fire on the legitimate case.
            if [[ -n "${blind// /}" ]]; then
                printf '    UNVERIFIED %s\n' "$s"
                printf '        it passed, but its population does not contain: %s\n' "$blind"
                printf '        so this green is about a tree WITHOUT those files. `git add` them\n'
                printf '        and re-run to turn it into a verdict.\n'
                unverified=1
                _passed=$(( _passed + 1 ))
            else
                printf '    PASS %s\n' "$s"
                _passed=$(( _passed + 1 ))
            fi
        else
            # A red needs no qualification — the guard found something real, and
            # adding the untracked files can only find more.
            printf '    FAIL %s\n' "$s"
            rc=1
            _failed=$(( _failed + 1 ))
        fi
    done

    # THE RECONCILIATION LINE (your-org/nexus-code#965). The closing statement
    # that says the loop finished. Without it, "ran 8 guards, all passed" and
    # "was killed before reaching the one that fails" produce the same visible
    # artefact — a listing with no failure text — and the natural reading of
    # the second is the first. Printed on EVERY --run, green or red, because a
    # completion claim that only appears sometimes is not one a reader can rely
    # on the absence of.
    printf '\n=== --run: reached %d of %d selected guard(s) — %d passed, %d failed ===\n' \
        "$_reached" "$_n_sel" "$_passed" "$_failed"
    if (( ${#unreached[@]} > 0 )); then
        printf '::error::--run TIMED OUT after %ss — %d selected guard(s) RETURNED NO VERDICT.\n' \
            "$run_timeout" "${#unreached[@]}"
        printf '%s\n' "${unreached[@]}" | sed 's/^/    NO VERDICT: /'
        printf '    A guard that did not run, or was cut off mid-run, is not a guard that\n'
        printf '    passed. The verdicts above\n'
        printf '    cover %d of %d selected guards and say nothing about the rest — which is\n' \
            "$_reached" "$_n_sel"
        printf '    the case this tool exists to make legible, so it exits 5 rather than\n'
        printf '    letting a partial sweep read as a clean one. Raise --timeout or run the\n'
        printf '    named guards directly.\n'
        exit 5
    fi
    if (( rc == 0 )) && (( unverified )); then
        printf '\n=== NOT A CLEARANCE (exit 4) ===\n'
        printf 'Every selected guard came back green, but at least one green is\n'
        printf 'UNVERIFIED: the guard cannot see an untracked file in your diff, so it\n'
        printf 'answered about a tree that does not contain it. Measured on this very\n'
        printf 'tool (your-org/nexus-code#1054): the same planted reader scored\n'
        printf '21 passed / 0 failed untracked and 20 passed / 1 failed once `git add`ed.\n'
        printf '`git add` the files named above and re-run.\n'
        exit 4
    fi
    exit "$rc"
fi

(( ${#sel_names[@]} )) || exit 3
exit 0
