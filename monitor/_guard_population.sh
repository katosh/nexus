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
# suite's own path for free; everything else the guard declares.
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

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        rel=$(gp_relpath "$root" "$line")
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
