#!/usr/bin/env bash
# _guard_population.sh — the `--population` PROTOCOL: how a guard tells the
# rest of the repo which files it reads (your-org/nexus-code#803).
#
# ---------------------------------------------------------------------------
# THE DEFECT THIS SERVES
# ---------------------------------------------------------------------------
#
# A PR's green covers the suites its DIFF TOUCHES, not the suites its CHANGE
# AFFECTS. Three occurrences in one night, same mechanism: a worker changed X,
# ran the suites that live near X, they passed, it pushed — and the guard that
# reddened was one whose scanned POPULATION X had just entered. Nothing told
# the worker that guard existed, because nothing mapped "what I changed" to
# "what scans what I changed". The repo's construct-keyed guards are unusually
# good and unusually invisible for exactly this reason.
#
# The information already exists: each guard derives its population. What was
# missing is the REVERSE INDEX, and the precondition for one is a way to ask a
# guard what it reads without reading its source. This file is that protocol;
# `monitor/guards-for-diff.sh` is the index built on it.
#
# ---------------------------------------------------------------------------
# WHAT "POPULATION" MEANS HERE, stated exactly because a looser reading is
# what makes such an index over-claim
# ---------------------------------------------------------------------------
#
# A guard's population is **the set of files whose BYTES it reads in order to
# reach its verdict**. Not "the files where the construct occurs" — that set is
# a RESULT, and a file that is scanned and found clean is exactly the file that
# your edit can dirty. Not "the directory the guard lives in" — that is the
# belief that failed three times.
#
# The definition is chosen because it is the one that makes SELECTION SOUND in
# the direction that matters: if a guard does not read your file, your edit to
# that file cannot change its verdict. The converse is NOT claimed — a guard
# that reads your file may still be unaffected by your edit — so the index
# over-selects, deliberately, and says so.
#
# It follows that a guard's population includes its OWN source, its manifest,
# its generator, and every library it sources: `bash` reads those bytes too,
# and an edit to any of them can change the verdict. `gp_handle` adds the
# suite's own path AND THIS LIBRARY for free (your-org/nexus-code#1197 — every
# declaring guard sources this file by construction, and measured at
# 50c36efc7ef3 only 7 of 23 had it in their declared population, 5 of those
# incidentally); everything else the guard declares.
#
# ---------------------------------------------------------------------------
# THE ONE RULE FOR AN IMPLEMENTOR
# ---------------------------------------------------------------------------
#
# `gp_population` MUST call the guard's own enumerator. Never a copy of it,
# never a hand-typed list of what the enumerator currently returns. A copy is
# a second implementation of the population, and a second implementation drifts
# — at which point the index reports, with total confidence, that a guard does
# not read a file it does read. That is this repo's dominant defect class
# (silence read as absence) rebuilt inside the remedy for it.
#
# Usage, in a guard, AFTER its enumerator functions are defined and BEFORE it
# does any work:
#
#     . "$_test_dir/../_guard_population.sh"
#     gp_population() {
#         _aso_shell_files "$REPO_ROOT/monitor"    # the guard's OWN enumerator
#         printf '%s\n' "monitor/watcher/aso-unresolved-sources.manifest"
#     }
#     gp_handle "$@"     # prints and exits 0 when $1 is --population; else no-op
#
# Paths may be absolute or repo-relative; `gp_handle` normalises, de-duplicates
# and sorts. It REFUSES (exit 3, diagnostic on stderr) on an empty population
# or a path that does not exist — see gp_handle for why both are fail-closed.
#
# ---------------------------------------------------------------------------
# AND THE SECOND RULE, IF YOUR ENUMERATOR SEARCHES CONTENT: KEY ON
# APPLICABILITY, NEVER ON CONFORMANCE (your-org/nexus-code#1197, #1224)
# ---------------------------------------------------------------------------
#
# The rule above is about not COPYING an enumerator. This one is about what an
# enumerator may ASK, and it only bites when a population is derived by
# searching file CONTENT rather than by walking a corpus — so it is the rule
# for exactly the `git grep`-shaped `gp_population`.
#
# Ask "is this file SUBJECT to the rule I check?" — applicability.
# Never "does this file ALREADY SATISFY it?" — conformance.
#
# A conformance predicate is self-referential by construction: satisfying it is
# what puts a file in the population, so VIOLATING it removes the file — and the
# violation is precisely what the guard exists to catch. The predicate deletes
# its own evidence.
#
# The worked example, because it shipped and was measured.
# `test-public-mirror-build-entry-guard.sh` enumerated
# `git grep -lE 'build\.sh"? +--yes'` — the callers ALREADY PASSING `--yes`.
# Dropping `--yes` at the one production caller removed that caller from the
# population and DESELECTED the guard: 6 guards selected before the edit, 5
# after, exit 0. Fixed by keying on `build\.sh` — names it at all — and making
# `--yes` the ASSERTION rather than the FILTER.
#
# WHY YOU WILL NOT NOTICE IT IN REVIEW, which is the reason this paragraph is
# here rather than only in that guard's comment. The failure does not look like
# an empty selection. The report stays FULL, every surviving line is TRUE, and
# the guard appears under `CONSIDERED AND EXCLUDED` — so a reader obeying this
# repo's own "read the list, not the count" rule concludes the guard was
# evaluated and ruled out. It was evaluated; the ruling was correct about a
# population that had just dropped the file in question. Both rules we already
# teach are satisfied, and both are insufficient.
#
# AND IF YOU CHANGE WHAT A PREDICATE KEYS ON, RE-ENUMERATE UNDER BOTH KEYS AND
# DIFF THE SETS. A key change silently re-scopes a population. The first
# proposed fix for the guard above was `public-mirror/build\.sh` — path-keyed
# instead of construct-keyed — which matched 4 files and DROPPED the one
# production caller, because it invokes through a variable
# (`bash "$REL_PM/build.sh"`); that caller is also one of the row's declared
# sentinels. Diff the MEMBERSHIP, not the count: 4 against 10 was noticed, and a
# closer pair would not have been (`#946` F1).
#
# ---------------------------------------------------------------------------
# COVERAGE BOUNDARY of the protocol itself, on the axis the MECHANISM varies on
# — HOW A GUARD DECLARES WHAT IT READS. There is exactly one declaration
# mechanism: this flag. So a guard that does not implement it is INVISIBLE to
# every consumer, and the index's duty is to say how many such guards exist
# rather than to imply the ones it knows are all of them. What the protocol
# cannot express, and what therefore is not claimed:
#
#   * a guard whose verdict depends on RUNTIME STATE your change produces
#     rather than on a file it reads (a tmux server's answers, a CI run's
#     conclusions, an installed binary's version). No path list describes it.
#   * a population computed from a file's CONTENT AT MERGE — a guard whose
#     enumerator your branch does not contain yet. The index answers against
#     YOUR tree, so a guard whose population definition changed on ANOTHER
#     branch selects differently after merge than it does now. That is the
#     first of #803's three occurrences (`#781` x `#791`) and no per-branch
#     index can see it; `guards-for-diff.sh` states it in its own output.
#   * transitive reads through a path this guard's enumerator does not itself
#     produce. The protocol asks the guard; the guard's answer is only as wide
#     as its enumerator.
#
# This file is SOURCED by test suites, so it must not impose shell options on
# its caller (your-org/nexus-code#721's leak class, gated by
# watcher/test-ambient-shell-option-scope.sh P2). It therefore sets none, and
# restores nothing, because it changes nothing.

# The literal token every participating guard carries, and therefore the thing
# `guards-for-diff.sh` discovers them by. Kept as a named constant so the
# discovery predicate and the protocol cannot drift apart: a grep for this
# string IS the declaration, not a proxy for it.
GP_FLAG='--population'

# Repo root, if the caller has not already resolved one. Derived from THIS
# file's location, which is `monitor/`, so it is correct from any cwd and in
# any clone.
gp_repo_root() {
    if [[ -n "${GP_REPO_ROOT:-}" ]]; then
        printf '%s' "$GP_REPO_ROOT"
        return 0
    fi
    ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )
}

# CANONICALISE A PATH THE WAY GIT SPELLS IT — textually, with no forks
# (your-org/nexus-code#1218).
#
# THE MISMATCH THIS CLOSES. `gp_render` validated a declared row against the
# FILESYSTEM's vocabulary — `[[ -e ]]`, "does this path resolve?" — while the
# consumer, `guards-for-diff.sh`, intersects populations with a changed-file
# list from `git diff --name-only` / `git ls-files`, i.e. GIT's vocabulary,
# "is this the string git emits?". Every spelling in the gap between those two
# names a real file, passes every check, and can never be intersected with a
# diff. It is the quietest failure available: the population NAMES the file,
# the guard is listed and truthful, and the intersection is empty. No error, no
# zero, nothing to notice.
#
# `#1197` closed ONE member with `case "$line" in /*/../*|/*/..)` — a denylist
# of the spellings somebody had noticed, with a permissive default arm, which
# is the shape this repo has filed against repeatedly (#1119, #1121, #851).
# The four spellings and their fate under that fix:
#
#     /abs/monitor/watcher/../x.sh   -e passes   fixed by #1197
#     monitor/watcher/../x.sh        -e passes   STILL UNMATCHABLE
#     ./monitor/x.sh                 -e passes   STILL UNMATCHABLE
#     monitor//x.sh                  -e passes   STILL UNMATCHABLE
#
# One predicate now covers all four and every future one, because it does not
# enumerate spellings: it reduces any spelling to the canonical one.
#
# TEXTUAL, NOT `realpath`/`cd`, AND THAT IS THE CORRECT SEMANTICS HERE RATHER
# THAN THE CHEAP ONE. The consumer is git, and git pathspecs are matched
# TEXTUALLY — `git diff --name-only` never emits a symlink-resolved path, so
# resolving symlinks would produce a row git still cannot match, trading one
# unmatchable spelling for another. It is also fork-free, which matters for a
# reason this repo has already paid for once: a corpus guard emits ~500 rows
# and there are 25 declaring guards, so a per-row fork here would rebuild the
# O(files)-with-a-process-each walk that #1254 exists to remove, inside the fix
# for #1218.
#
# THE DIVERGENCE FROM `cd`-BASED RESOLUTION IS REAL AND IS THE RIGHT TRADE: for
# `a/b/../c` where `a/b` is a SYMLINK, textual gives `a/c` and `cd` gives the
# link target's sibling. Git means the former. Where the two disagree the `-e`
# rot check below still fires, so the failure is loud rather than silent.
#
# No word splitting and no unquoted expansion anywhere in the loop: a path
# containing a glob character must not be expanded, and setting `set -f` to
# prevent that is exactly the shell-option leak this file's header forbids
# (#721's class).
gp_canon() {   # <path> -> the same path, canonically spelled
    local p="$1" seg rest lead='' n
    local -a out=()
    [[ "$p" == /* ]] && lead='/'
    while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
    rest="$p"
    while :; do
        if [[ "$rest" == */* ]]; then seg="${rest%%/*}"; rest="${rest#*/}"
        else                          seg="$rest";       rest=''; fi
        case "$seg" in
            ''|'.') : ;;
            '..')
                n=${#out[@]}
                # `..` is only resolvable against a real preceding segment. A
                # leading run of `..` (or one past the root) is KEPT rather than
                # silently eaten, so a row that escapes the tree stays visibly
                # wrong and the rot check refuses it.
                if (( n > 0 )) && [[ "${out[$((n-1))]}" != '..' ]]; then
                    unset "out[$((n-1))]"; out=( ${out[@]+"${out[@]}"} )
                else
                    out+=( '..' )
                fi ;;
            *) out+=( "$seg" ) ;;
        esac
        [[ -n "$rest" ]] || break
    done
    local IFS=/
    printf '%s%s' "$lead" "${out[*]-}"
}

# Normalise one path to repo-relative. An absolute path under the root has the
# root stripped; anything else is passed through unchanged, so a guard that
# already emits repo-relative rows needs no adaptation.
gp_relpath() {   # <root> <path>
    local root="$1" p="$2"
    case "$p" in
        "$root"/*) printf '%s' "${p#"$root"/}" ;;
        *)         printf '%s' "$p" ;;
    esac
}

# ---------------------------------------------------------------------------
# THE UNTRACKED HALF OF A POPULATION (your-org/nexus-code#1197)
# ---------------------------------------------------------------------------
#
# A population computed from the index cannot see the file you just wrote
# (`#1054`), so a guard that wants to be honest about untracked files has to
# scan the working tree. Two guards did, with byte-identical hand-rolled loops,
# and both were unbounded in a way that took the WHOLE INDEX DOWN:
#
#     git ls-files --others --exclude-standard -z | while read -d '' u; do
#         grep -qE "$re" "$u" && printf '%s\n' "$u"
#     done
#
# One `grep` process per untracked file, reading every byte of each. On the
# operator nexus that meant ~4,374 files per regex and ~8,700 process spawns,
# the probe blew `guards-for-diff`'s 180 s budget, and the index exited 2
# REFUSED — correctly, fail-closed, and with the effect that every worker on
# that host got NO pre-push gate at all rather than a partial one.
#
# THE COST IS BYTES, NOT FILES, AND THAT IS THE PART THE ISSUE GOT WRONG.
# `#1197` names `.sandbox-state/` (3,394 untracked files) as "the actual bug"
# and proposes gitignoring it as "the one-line fix that restores the gate".
# Measured on the operator nexus, untracked bytes by top-level directory:
#
#     artifacts/          794 files   41,741 MB   <- 97% of the bytes
#     backups/            139 files      462 MB
#     data/                 4 files      361 MB
#     .sandbox-state/   3,394 files       89 MB   <- 0.2% of the bytes
#
# Ten `.h5ad` files are 41.5 GB of the 42.6 GB total. Gitignoring
# `.sandbox-state/` removes 78% of the FILES and 0.2% of the BYTES, so on its
# own it would not have restored the gate. A file-count bound would have been
# tuned against the wrong quantity for the same reason.
#
# WHAT ACTUALLY BOUNDS IT IS `-I`, and it is nearly free. `grep -I` decides a
# file is binary from its FIRST BUFFER and stops, so a 2 GB `.h5ad` costs one
# read rather than 2 GB. Measured on this host, same file, same regex:
# `grep -lE` 9 s, `grep -lIE` 0 s. Extrapolated across the ten of them that is
# ~175 s in the h5ad files alone, against a 180 s budget — the timeout, by
# itself, before any other file is touched.
#
# BATCHING ALONE DOES NOT FIX IT, and that is worth recording because it is the
# obvious fix and it is the one that fails. Measured over the operator nexus's
# full 4,374-file untracked set with the guards' real `assert_contains` regex,
# each arm under a 300 s bound:
#
#     A  per-file loop, no -I  (the shipped form)   >300 s, hit the bound
#     B  xargs batch,   no -I                       >300 s, hit the bound
#     C  xargs batch,   with -I                       21 s
#
# The spawns were never the cost; the bytes were.
#
# `-I` IS A NARROWING, AND IT IS THE NARROWING THIS COMMENT OWES AN ARGUMENT
# FOR. It is not "the same answer, faster": a file whose first buffer holds a
# NUL is skipped even if its later bytes match. So the read set genuinely
# shrinks, by exactly the NUL-bearing files.
#
# The argument that this is the RIGHT set to drop: both callers EXTRACT the
# matched definition and EXECUTE it as bash, so a file that is not a shell file
# cannot contribute a definition to extract — it was only ever bytes the
# enumerator paid for. The argument is not left as prose: the exact boundary is
# planted and asserted in test-empty-needle-local-copies.sh, one fixture each
# way — a matching TEXT file that must be FOUND, and a matching NUL-bearing
# file that must be SKIPPED — so the day someone disagrees with this trade they
# will find it written down as data rather than have to infer it.
#
# What is NOT claimed, because the cheap measurement that would have supported
# it was vacuous: that no binary file in that tree matches. Both arms above
# returned zero matches, and 0 == 0 distinguishes nothing. The boundary is
# established by the fixtures, not by that run.
#
# The batching is the second, smaller win — one `grep` per `xargs` batch
# instead of one per file — and it is what removes the ~8,700 spawns.
#
# RESIDUAL, DECLARED RATHER THAN PAPERED OVER: this is still O(untracked TEXT
# bytes). A tree carrying gigabytes of untracked *text* would still exhaust the
# probe budget. No budget is enforced here on purpose — an untested ceiling is
# machinery whose failure path nobody has ever reached (`#965`) — and the thing
# that now makes such a regression LOUD instead of silent is that
# test-guards-for-diff.sh probes under the index's own 180 s budget rather than
# its former 300 s, so a probe that would refuse the tool reds the guard first.
#
# Newline-in-filename is unrepresentable in this protocol either way:
# `gp_render` reads its input line by line. That is the protocol's boundary,
# not something this helper introduces.
# THE RESIDUAL ABOVE IS NOW BOUNDED, AND THE BOUND IS ON THE RIGHT QUANTITY
# (your-org/nexus-code#1254 item 1). The comment above declared the residual
# rather than papering over it, and was right to — but "declared" is not
# "stateable", and the missing thing was the NUMBER. Derived from #1254's
# measurement (~1.1 GB of non-binary payload read over two regex passes in
# 15.89 s, i.e. ~140 MB/s on this storage), the 180 s probe budget corresponds
# to roughly 25 GB of untracked TEXT. That is ordinary for this lab — one
# untracked CSV/TSV/FASTQ/mtx drop reaches it — and when it is reached the
# symptom is byte-for-byte the one #1197 filed: probe rc 124, tool exit 2, gate
# down, nothing named.
#
# WHICH QUANTITY TO BOUND IS THE WHOLE DESIGN, and the obvious choice is wrong.
# Bounding TOTAL untracked bytes would refuse the operator's real tree — 42.6 GB,
# of which 41.5 GB is ten `.h5ad` files — and that tree is precisely the one
# `-I` already handles in ~16 s. A total-bytes ceiling would therefore take the
# gate down on the tree #1223 fixed, which is a regression wearing a bound's
# clothes. The quantity that actually costs time is TEXT bytes, so that is what
# is measured and bounded.
#
# HOW IT IS MEASURED WITHOUT PAYING FOR IT. `grep -lI` with an empty pattern
# matches the first line of every TEXT file and skips every binary one, and `-l`
# stops at the first match — so the classifying pass reads one buffer per file,
# O(files) syscalls rather than O(bytes). Summing the sizes of exactly the files
# it returns is the text-byte total, exactly. The real regex pass then runs over
# that already-classified set, so the `-I` narrowing is applied once rather than
# twice and the second pass costs no more than before.
#
# THE FAILURE PATH IS EXERCISED, not merely installed (`#965`: an untested
# ceiling is machinery whose failure path nobody has ever reached).
# test-guards-for-diff.sh plants a tree over the budget and asserts this refuses
# — fast, and naming the directories responsible — rather than being discovered
# 180 s later as an anonymous timeout.
#
# IT STAYS A REFUSAL RATHER THAN BECOMING A NAMED PARTIAL, which is #1197's
# third ask, and the reason is this file's own doctrine: a population that came
# back short is indistinguishable downstream from a guard that reads none of
# your files. A partial population IS a silently narrowed one. What the ask
# correctly identifies is that a blanket refusal NAMES NOTHING — so the refusal
# now names the budget, the measured total, and the top contributing
# directories, which is the actionable half without the unsound half.
GP_UNTRACKED_TEXT_BUDGET_BYTES="${GP_UNTRACKED_TEXT_BUDGET_BYTES:-2147483648}"   # 2 GiB

# THE REFUSAL TRAVELS IN-BAND, AND THAT IS NOT A STYLE CHOICE — AN EXIT STATUS
# CANNOT REACH THE CONSUMER FROM HERE. Both production callers wrap this
# helper in a brace group and PIPE it:
#
#     { git grep -lE …; gp_untracked_matching …; } | grep -vFx … | sort -u
#
# A pipeline's exit status is its LAST command's, so `sort -u`'s success
# overwrites any status this function returns — and one of the two callers
# even ends the group with a literal `true`. Measured: with the budget
# exceeded, the diagnostic printed on stderr and the probe still exited **0**,
# so the tool carried on with a SILENTLY NARROWED population. That is this
# repo's dominant defect class arriving inside the bound written to prevent
# it, and it is the exact shape CLAUDE.md's pipeline-status entry describes.
#
# Fixing the two call sites would work and is not available: they are outside
# this change's scope, and a bound that depends on every future caller
# remembering to preserve a status is a bound with a permissive default arm.
# So the signal goes on the DATA channel, which no pipeline can discard, and
# `gp_render` fails CLOSED on it. The `\x01` prefix is what makes it
# unspoofable in practice — no path in this repo contains a control character,
# and a path that did would refuse here rather than be silently accepted,
# which is the safe direction.
GP_REFUSAL_SENTINEL=$'\x01GP_REFUSAL\x01'


gp_untracked_matching() {   # <root> <extended-regex> -> repo-relative paths
    local root="$1" re="$2"
    (
        cd "$root" 2>/dev/null || exit 1

        # PASS 1 — classify text vs binary, one buffer per file.
        local textlist; textlist=$(mktemp) || exit 1
        # shellcheck disable=SC2064
        trap "rm -f '$textlist'" EXIT
        git ls-files --others --exclude-standard -z 2>/dev/null \
            | xargs -0 -r grep -lIZ -e '' 2>/dev/null > "$textlist"

        # PASS 2 — the text-byte total, one `du` for the whole set. `--files0-from`
        # keeps NUL separation end to end, so a filename with a newline or a space
        # cannot split a record. `-c` gives the grand total, `-b` apparent bytes.
        # A TOTAL THAT COULD NOT BE MEASURED IS NOT ZERO. The first cut of this
        # fell back to `total=0` when `du` failed or printed something
        # unparseable, which is fail-OPEN in a budget: "I could not measure it"
        # became "it is under the limit", and the enumeration then ran unbounded
        # — the exact behaviour the budget exists to remove, reachable only when
        # something is already wrong. An emptiness/shape check is a presence test
        # wearing a validity test's name unless the invalid case REFUSES.
        local total=0 dur=0
        if [[ -s "$textlist" ]]; then
            total=$(du -cb --files0-from="$textlist" 2>/dev/null | tail -1 | cut -f1) || dur=$?
            if [[ ! "$total" =~ ^[0-9]+$ ]]; then
                printf '%s: could not measure untracked TEXT bytes (du rc %s, got %q).\n' \
                    "_guard_population" "$dur" "$total" >&2
                printf '  Refusing rather than assuming the budget is clear: an unmeasured\n' >&2
                printf '  total read as 0 is a bound that disappears exactly when something\n' >&2
                printf '  is already wrong.\n' >&2
                printf '%s could not measure untracked text bytes\n' "$GP_REFUSAL_SENTINEL"
                exit 3
            fi
        fi

        if (( total > GP_UNTRACKED_TEXT_BUDGET_BYTES )); then
            printf '%s: UNTRACKED TEXT BUDGET EXCEEDED — refusing.\n' "_guard_population" >&2
            printf '  untracked TEXT bytes: %s\n  budget:               %s\n' \
                "$total" "$GP_UNTRACKED_TEXT_BUDGET_BYTES" >&2
            printf '  This enumeration is O(untracked TEXT bytes). Left unbounded it\n' >&2
            printf '  exhausts guards-for-diff'"'"'s 180s probe budget at roughly 25 GB and\n' >&2
            printf '  the tool exits 2 with nothing named (your-org/nexus-code#1197,\n' >&2
            printf '  #1254). Refusing HERE is the same refusal, arriving in seconds and\n' >&2
            printf '  saying what to do about it. Top untracked TEXT directories:\n' >&2
            # `sed -n '1,5p'`, NOT `head -5`. `head` closes the pipe as soon as it
            # has its five lines, SIGPIPEing `sort` — and under the `pipefail`
            # these callers run with, the pipeline then reports 141. That is the
            # construct `monitor/watcher/early-exit-readers.sh` enumerates, and
            # writing one HERE would have been this bundle's own subject matter
            # re-instantiated inside its remedy: it reddened
            # test-early-exit-reader-manifest.sh, which reddened
            # test-guards-for-diff.sh through its --run arm. `sed` without a `q`
            # DRAINS its input, so it cannot close the pipe early. Same fix, and
            # the same reasoning, as the `hits=` line in guards-for-diff.sh.
            tr '\0' '\n' < "$textlist" \
                | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | sed -n '1,5p' \
                | while read -r n d; do printf '    %6s files  %s\n' "$n" "${d:-.}" >&2; done
            printf '  Gitignore what does not belong in the tree, or raise\n' >&2
            printf '  GP_UNTRACKED_TEXT_BUDGET_BYTES deliberately.\n' >&2
            # ON STDOUT TOO — see GP_REFUSAL_SENTINEL above. The exit status is
            # kept for anyone calling this helper directly; the sentinel is what
            # survives the callers that pipe it.
            printf '%s untracked text %s B exceeds budget %s B\n' \
                "$GP_REFUSAL_SENTINEL" "$total" "$GP_UNTRACKED_TEXT_BUDGET_BYTES"
            exit 3
        fi

        # PASS 3 — the real regex, over the already-classified TEXT set only.
        if [[ -s "$textlist" ]]; then
            xargs -0 -r grep -lE -- "$re" < "$textlist" 2>/dev/null
        fi
        # AN ENUMERATOR'S EXIT STATUS MUST DESCRIBE THE ENUMERATION, NOT ITS
        # LAST BATCH. `grep` exits 1 on no-match and `xargs` turns that into
        # 123; under the `set -o pipefail` these callers run with, "no untracked
        # file matched" — the ordinary case — would otherwise propagate out of
        # `gp_population` and be read by `gp_render` as a FAILED enumerator,
        # refusing rc 3 and taking the whole index to exit 2. The budget refusal
        # above exits 3 BEFORE reaching this line, so it is not swallowed by it.
        true
    )
}

# The protocol entry point. A no-op unless the guard was invoked with
# `--population`, so adding this call to a suite cannot change what that suite
# does when it is run normally.
#
# THREE REFUSALS, all fail-CLOSED, because every one of them would otherwise
# make a guard silently disappear from a selection:
#
#   * no `gp_population` — the suite carries the flag and does not implement
#     it. Discovery finds it by the flag, so a half-implementation would be
#     probed, answer nothing, and be dropped.
#   * an EMPTY population — indistinguishable, downstream, from "reads none of
#     your files". A guard that reads nothing is not a guard; a population
#     that came back empty is an enumerator that broke. Both must be loud.
#     This is the `mapfile`-in-zsh shape (an enumeration that fails as zero)
#     and the `grep -r` shape (a search that cannot see the tree), which have
#     between them produced three confident wrong answers in this workspace.
#   * a path that does not EXIST — a population that names a deleted file is a
#     population that has rotted, and a rotted population is one that no longer
#     describes what the guard reads.
#
# gp_handle EXITS the suite when it handles the flag — it does not return. A
# `return 0` here would print the population and then run the whole suite,
# which is not a probe. The rendering is split out so the exit status is the
# only thing gp_handle decides.
gp_handle() {
    [[ "${1:-}" == "$GP_FLAG" ]] || return 0
    # `${GP_SELF-...}` without the colon, deliberately: an explicitly EMPTY
    # GP_SELF means "no self path to add", which is how a fixture exercises a
    # bare declaration. A colon form would treat empty as unset and silently
    # fall back to BASH_SOURCE.
    local self="${GP_SELF-${BASH_SOURCE[1]:-}}"
    gp_render "$self"
    exit $?
}

gp_render() {   # <suite-path>
    local self="$1"
    local root; root=$(gp_repo_root)

    if ! declare -F gp_population >/dev/null 2>&1; then
        printf '%s: %s declares %s but implements no gp_population()\n' \
            "_guard_population" "${self:-<unknown suite>}" "$GP_FLAG" >&2
        return 3
    fi

    local raw rc=0 out=() line rel
    raw=$(gp_population) || rc=$?
    if (( rc != 0 )); then
        printf '%s: %s: gp_population() failed (rc %d) — refusing to report a\n' \
            "_guard_population" "${self:-<unknown suite>}" "$rc" >&2
        printf '  population this guard did not successfully produce.\n' >&2
        return 3
    fi

    # EMPTINESS IS CHECKED ON THE GUARD'S OWN ANSWER, BEFORE the suite path is
    # appended below. Checking after would make this refusal unreachable — the
    # appended self is always one line, so a broken enumerator would answer
    # "one file: myself" and be quietly excluded from every selection. A guard
    # that can never fire is the defect this file exists to prevent, so it does
    # not get to live inside it.
    # A REFUSAL FROM AN ENUMERATOR, ARRIVING IN-BAND. Checked BEFORE the
    # emptiness test below, deliberately: a refusal that also happened to
    # produce no other rows would otherwise be reported as an empty population,
    # which is a true statement about the wrong thing — the enumerator did not
    # come back empty, it came back REFUSING, and the remedies differ.
    if [[ "$raw" == *"$GP_REFUSAL_SENTINEL"* ]]; then
        printf '%s: %s: an enumerator REFUSED — refusing to report a population\n' \
            "_guard_population" "${self:-<unknown suite>}" >&2
        printf '  it did not successfully produce. The enumerator'"'"'s own diagnostic is\n' >&2
        printf '  above; this is the marker it passed down the data channel because a\n' >&2
        printf '  pipeline in the call path discards exit status:\n' >&2
        printf '%s\n' "$raw" | grep -aF "$GP_REFUSAL_SENTINEL" \
            | sed "s/$(printf '\x01')GP_REFUSAL$(printf '\x01') /    /" >&2
        return 3
    fi

    if [[ -z "${raw//[[:space:]]/}" ]]; then
        printf '%s: %s: declared population is EMPTY. That is not "reads none of\n' \
            "_guard_population" "${self:-<unknown suite>}" >&2
        printf '  your files" — it is an enumerator that produced nothing, and\n' >&2
        printf '  downstream the two are indistinguishable. Refusing.\n' >&2
        return 3
    fi

    # The suite's own source is part of what it reads, always. Declared here
    # rather than in each guard so it cannot be forgotten in one of them —
    # and editing a guard is the least arguable reason to run it.
    #
    # Resolved to an absolute path FIRST. `BASH_SOURCE` carries the path as the
    # caller spelled it, so `bash monitor/watcher/test-x.sh` from the repo root
    # yields a relative path that is correct only from that cwd — and the
    # existence check below would then refuse a perfectly good suite whenever
    # the probe ran from anywhere else.
    if [[ -n "$self" ]]; then
        case "$self" in
            /*) ;;
            *)  self=$( cd "$(dirname "$self")" 2>/dev/null && pwd )/$(basename "$self") ;;
        esac
        raw="$raw
$(gp_relpath "$root" "$self")"
    fi

    # THIS LIBRARY IS PART OF EVERY DECLARING GUARD'S READ SET, and it is added
    # here for the same reason the suite's own path is: a thing every guard
    # depends on BY CONSTRUCTION must not be something each guard has to
    # remember to declare (your-org/nexus-code#1197).
    #
    # The protocol's own doctrine, twenty lines up this file, already says a
    # guard's population includes "every library it sources: `bash` reads those
    # bytes too, and an edit to any of them can change the verdict" — and then
    # left it to each guard. Measured at 50c36efc7ef3, clean tree, by probing
    # every row of guard-populations.manifest: **7 of 23** enrolled guards had
    # `monitor/_guard_population.sh` in their declared population. The other 16
    # source this file and were invisible to an edit to it.
    #
    # And the 7 is softer than it looks, which is why the count is quoted rather
    # than treated as coverage. It decomposes 5 + 2. FIVE are the broad-corpus
    # guards (ambient-shell-option-scope, early-exit-reader, spawn-shape,
    # tmux-window-resolver, knob-default-agrees), which sweep every shell file
    # under `monitor/` and therefore pick this file up INCIDENTALLY, as one more
    # member of a corpus — they would keep it after an edit that removed every
    # deliberate mention. TWO name it deliberately: test-guards-for-diff.sh,
    # which reads it, and test-claude-md-guards-for-diff.sh, whose entire
    # `gp_population` is a hand-written five-literal list with no corpus sweep
    # and which includes this path because its fail-closed fixture sources it.
    #
    # This sentence read "all but one of those incidentally" until a skeptic
    # measured it (`#1223` F-B). The operative 7 was exact and nothing
    # behavioural turned on the split, but the split was stated as measured and
    # was not — and it erred toward making the pre-fix state look worse than it
    # was, which is the direction that flatters the fix. Corrected here rather
    # than left, because a decomposition nobody checked is the same liability as
    # a count nobody can re-run.
    #
    # Either way the conclusion stands: a guard whose population is NARROW —
    # which is most of them — got no protection from being in that 7.
    #
    # That was survivable while this file held only `gp_handle`/`gp_render`,
    # which change about once a quarter. It stopped being survivable the moment
    # shared ENUMERATION logic moved in: `gp_untracked_matching` above now
    # computes the untracked half of two guards' populations, so an edit to it
    # changes what both of them read — and both were measured BLIND to this file
    # at 50c36efc7ef3, so before this line an edit to it selected neither. That
    # is the #1170 shape (a guard that cannot be selected by the edit which
    # invalidates it) arriving as a side effect of the #1197 fix, in the same
    # PR, which is precisely how it would have gone unnoticed.
    #
    # Added AFTER the emptiness check above, deliberately and for the reason
    # stated there: appending anything before it would let a broken enumerator
    # answer "one file: the library" and be quietly excluded from every
    # selection instead of refusing.
    # CANONICALISED UNCONDITIONALLY, not just when relative — being absolute is
    # not the same as being canonical. Every declaring guard sources this file
    # as `"$_test_dir/../_guard_population.sh"`, so `BASH_SOURCE[0]` is an
    # ABSOLUTE path containing a `..`, and an `/*) ;;` passthrough emitted
    # `monitor/watcher/../_guard_population.sh`. That path EXISTS, so the
    # rot check below waves it through; it is simply a second spelling of a file
    # the rest of the repo calls `monitor/_guard_population.sh`. `git diff`
    # never produces that spelling, so `guards-for-diff`'s `comm -12` against a
    # changed-file list can never match it — the population would name the file
    # and still fail to select on it. A wrong answer that passes every check,
    # which is the class this file exists to prevent. Measured: 8 of 23 with the
    # passthrough, and the 8 were the corpus-sweeping guards that pick the file
    # up canonically by another route.
    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        raw="$raw
${BASH_SOURCE[0]}"
    fi

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # BEING ABSOLUTE IS NOT BEING CANONICAL, and the difference is a silent
        # miss. Every declaring guard sources this library as
        # `"$_test_dir/../_guard_population.sh"`, so the path is absolute AND
        # contains a `..`; rendered as-is it becomes
        # `monitor/watcher/../_guard_population.sh`. That path EXISTS, so the
        # rot check below waves it through — it is simply a second spelling of a
        # file the rest of the repo calls `monitor/_guard_population.sh`.
        #
        # `git diff` never emits that spelling, so `guards-for-diff` intersects
        # the population with the changed-file list and CANNOT MATCH: the
        # population NAMES the file and still fails to select on it. There is a
        # live instance — test-knob-default-agrees.sh declares
        # `"$_test_dir/../_guard_population.sh"` on purpose, and was measured
        # emitting the unusable spelling, so the one guard that deliberately
        # declared this library got nothing for it.
        #
        # Resolved for the whole CLASS rather than for that instance, and the
        # `case` is what keeps it cheap: only a path actually containing `..`
        # pays a fork, so the ordinary member — every one of the ~500 in a
        # corpus guard — costs a string test. Absolute only: a repo-relative
        # path with a `..` would resolve against the prober's CWD rather than
        # the repo, which is a different and worse guess than leaving it alone.
        # RESIDUAL, and it is a CLASS this closes one member of. The enabler is
        # the `[[ -e ]]` rot check below: it validates a row against the
        # FILESYSTEM's vocabulary (does this path resolve?) while the consumer,
        # `guards-for-diff`, needs GIT's (is this the string `git diff` emits?).
        # Any spelling in the gap between those two names a real file, passes
        # every check here, and can never be intersected with a diff. Measured
        # by static read of this loop, the four spellings and their fate:
        #
        #     /abs/monitor/watcher/../x.sh   -e passes   FIXED below
        #     monitor/watcher/../x.sh        -e passes   still unmatched
        #     ./monitor/x.sh                 -e passes   still unmatched
        #     monitor//x.sh                  -e passes   still unmatched
        #
        # Nothing in the tree emits the last three today, and a `find .`-rooted
        # enumerator would emit `./`-prefixed rows as a matter of course. The
        # structural fix is to validate the row against git's vocabulary rather
        # than the filesystem's — one predicate instead of one `case` per
        # spelling somebody notices — and it is deliberately NOT done here:
        # it changes what every row of every population is checked against, and
        # that deserves its own PR rather than riding along in this one. Filed
        # separately. Note it is NOT the trackedness refusal this manifest's
        # header deliberately rejected: accepting an uncommitted file is sound,
        # accepting a non-canonical spelling of a tracked one is the bug, and
        # `-e` currently bundles those two relaxations into one test.
        # CANONICALISE BEFORE RELATIVISING, and canonicalise UNCONDITIONALLY.
        # The `case "$line" in /*/../*|/*/..)` fork this replaces was a denylist
        # of two spellings with a permissive default arm; `gp_canon` is one
        # predicate over all of them (your-org/nexus-code#1218). Order matters:
        # `gp_relpath` strips the root by PREFIX match, so an uncanonical
        # absolute row would fail to match the root and pass through absolute.
        line=$(gp_canon "$line")
        rel=$(gp_relpath "$root" "$line")
        # And again after relativising: stripping the root can expose a leading
        # `./` or a `..` that was hidden inside the absolute form.
        rel=$(gp_canon "$rel")
        # A ROW THAT CANONICALISES TO NOTHING IS NOT A PATH. `.`, `./`, `a/..`
        # and the repo root itself all reduce to the empty string, and an empty
        # row would pass the `-e` check below (`$root/` exists), then sit in the
        # population matching nothing — a member that can never be intersected
        # with a diff, which is precisely the class this canonicalisation
        # closes, re-entering through its own remedy. Refused rather than
        # dropped: silently discarding it would make a guard that declared only
        # such rows look like one with a smaller population instead of a broken
        # declaration.
        if [[ -z "$rel" ]]; then
            printf '%s: %s: declared population row %q canonicalises to the repo\n' \
                "_guard_population" "${self:-<unknown suite>}" "$line" >&2
            printf '  root itself, which names no file and can never match a diff. Refusing.\n' >&2
            return 3
        fi
        if [[ ! -e "$root/$rel" ]]; then
            printf '%s: %s: declared population names a path that does not exist: %s\n' \
                "_guard_population" "${self:-<unknown suite>}" "$rel" >&2
            return 3
        fi
        out+=( "$rel" )
    done <<<"$raw"

    # Unreachable given the emptiness check above (every surviving line is
    # appended), and kept as a belt: if the normalisation loop ever grows a
    # filter, a population that filters down to nothing must still refuse
    # rather than print a clean empty answer.
    if (( ${#out[@]} == 0 )); then
        printf '%s: %s: population normalised to EMPTY — refusing.\n' \
            "_guard_population" "${self:-<unknown suite>}" >&2
        return 3
    fi

    printf '%s\n' "${out[@]}" | sort -u
    return 0
}
