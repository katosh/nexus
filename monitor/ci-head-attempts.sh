#!/usr/bin/env bash
# ci-head-attempts.sh — "is this head green, and was it green the FIRST time?"
# (your-org/nexus-code#748). Exposed as `ng ci-attempts`.
#
# WHY THIS EXISTS AS AN AGENT-FACING VERB, and not only as a CI check.
# ci-signal.yml audits attempt provenance too, but it only fires on
# `pull_request` events and only judges that PR's head. The near-miss it was
# built from was not a PR gate failing — it was an AGENT reading CI at a head
# and concluding "green, merge it". That agent used `gh run list`, which shows
# only the latest attempt, so a SLOW band that concluded `failure` and was
# re-run to `success` at the same sha rendered as a clean first-pass green. The
# red was found only by enumerating attempts by hand.
#
# This workspace's own standard says to enumerate CI at the final head "by name
# AND by attempt". Before this verb there was no command that did the second
# half, so every agent hand-rolled it — and hand-rolling is what failed. That
# is the argument for a verb rather than a documented recipe.
#
# Usage:
#   ng ci-attempts <sha|branch|PR-number> [--repo OWNER/NAME]
#                                         [--audit|--no-audit]
#
# Exit codes mirror the surface they describe, so a script can branch on them:
#   0  every run at this head has CONCLUDED and is `success` on attempt 1 (and,
#      when the expected-band audit ran, every band that should have gated this
#      change concluded and carries a `success` verdict)
#   3  NOT CONCLUDED — nothing is wrong and nothing is finished: at least one
#      run (or expected band) is still queued or in progress, so there is no
#      clearance to give yet. Distinct from 0 because a green quantified over
#      the concluded subset is vacuous when that subset is empty or partial
#      (your-org/nexus-code#762); distinct from 4 because a run still going IS
#      evidence the band fired. The one retryable-by-waiting code here.
#   5  at least one run's LATEST attempt concluded `failure` — a live red
#   6  every completed run is green, but at least one green REPLACED a
#      `failure` at this same sha, or its provenance could not be read
#   4  a band that SHOULD have gated this change carries no verdict — it did
#      not run, or it ran to a non-verdict conclusion. The absence of a
#      verdict is RED (your-org/nexus-code#628).
#   7  the PR is CONFLICTED (`mergeable_state: dirty`), so no Actions run can
#      exist at this head by construction — the merge ref `refs/pull/N/merge`
#      is uncomputable and `push:` is scoped to [main, dev]
#      (your-org/nexus-code#773). Its own code because the ACTION is its own:
#      rebase. Folding it into 4 would tell the reader to wait for bands that
#      cannot arrive.
#   8  UNGATED — every workflow that fired is green and NOT ONE was selected by
#      what this diff changes (your-org/nexus-code#856). Nothing is missing and
#      nothing failed; no suite examined the change, because the bands that ran
#      carry no `paths:` filter and fire on every PR. Distinct from 0 because it
#      is not a clearance, and from 4 because no band is absent that should have
#      been present — the expected set itself is empty of anything that reads
#      these files. Not retryable: re-running produces the same empty set. The
#      resolution is a `paths:` filter or an explicit human "this needs no
#      suite".
#   9  STALE MERGE REF — every run at this head is green, and the tree those
#      runs tested is NOT the tree that would land. A `pull_request` run is
#      computed against `refs/pull/N/merge`; if the base branch has moved since
#      that ref was last computed, the green describes a merge result that no
#      longer exists. your-org/nexus-code#823 merged on exactly that. Its own
#      code because the ACTION is its own — rebase or push, so a new run is
#      computed against the current base — and folding it into 4 would tell the
#      reader to wait for bands that already ran.
#
#      NUMBERED 9, NOT 8, AND THE COLLISION IS WORTH RECORDING. This arm was
#      written as `8` while `#856`/`#868` was independently writing UNGATED as
#      `8` on `dev`; the rebase collided them. They are not alternatives — they
#      occupy different arms of the same if/elif chain (UNGATED short-circuits
#      well before the clearance `else` this check guards), so the renumber is
#      purely an allocation fix and changes no control flow. Renumbering the
#      NEWER, unmerged arm keeps `dev`'s shipped contract stable.
#  10  DIVERGENT MERGE REF — every run at this head is green, and the runs
#      DISAGREE about which base they tested (your-org/nexus-code#878, #882).
#      Distinct from 9 because nothing here says the base MOVED: one of the
#      bases may well be the live tip. What is established is that the head
#      carries more than one answer, and the verb refuses to choose — newest
#      -first ordering would systematically choose the freshest, which is the
#      most `current`-looking answer available and the one direction that must
#      never be a default. Reachable because `conclusion=="success"` does not
#      identify the run that supplied the VERDICT: `ci-signal` and
#      `conflict-markers` fire unconditionally, print the checkout line, and
#      routinely succeed in a later round whose `tests` were SKIPPED. The
#      resolution is the same as 9's — rebase or push, so one round exists
#      against one base — but the DIAGNOSIS differs, and folding it into 9
#      would tell the reader the base moved when that has not been shown.
#   2  usage / lookup refusal — fail-closed, never a green by default
#
# WHY THE EXPECTED-BAND AUDIT LIVES HERE TOO (your-org/nexus-code#740).
# This verb used to report only what the RUNS say, and punt "which workflows
# SHOULD have run" to ci-trigger-audit.py. That division was right about
# ownership and wrong about REACHABILITY: ci-trigger-audit.py is invoked from
# ci-signal.yml, which is **itself an Actions workflow**. So during the
# 2026-08-06 Actions outage every verdict guard this repo has built failed
# open simultaneously, and the residue read as success — zero check-runs at
# PR #739's head presented as `mergeable=true mergeable_state=clean`. Not
# pending, not blocked: *clean*.
#
# The merge-path reader needs an answer from OUTSIDE Actions, and this verb is
# the only CI surface here that already runs locally. So it now COMPOSES the
# audit rather than duplicating it — `--audit` shells out to the real
# ci-trigger-audit.py, which stays the single owner of trigger semantics and
# of the #628 verdict invariant. Nothing is reimplemented; the expectations
# are simply made reachable when Actions is not.
#
# THE ZERO CASE WAS NEVER THE DANGEROUS ONE. An empty run list was already a
# loud refusal here. The silent case is a PARTIAL set: some bands ran, all of
# them green, and the missing ones invisible — "every completed run is a
# first-pass success" is *true* and reads as approval. A prose disclaimer at
# the bottom is not a gate. Hence exit 4.
#
# AND AN EMPTY SET HAS SEVERAL CAUSES, WHICH MUST NOT COLLAPSE. "The provider
# was down", "the triggers genuinely select nothing for this change", "the PR
# is CONFLICTED so no run can exist" and "I could not look" are four different
# findings with four different responses, and reporting them as one number
# would be this repo's dominant defect class reproduced inside its own remedy.
# They are separated below.
#
# The fourth was added by your-org/nexus-code#773 and is the one that had
# already cost a wrong diagnosis: a `dirty` PR landed in the outage arm and was
# reported as "Actions stopped creating runs repo-wide" while another PR had 13
# runs at that same moment. A decomposition is only worth its complexity while
# it stays exhaustive, and an arm that absorbs the cases nobody enumerated is
# how it stops being.
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

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=""
REF=""
# auto: audit when a PR context is available, skip when it is not. Explicit
# --audit turns "no PR context" into a REFUSAL rather than a silent skip.
AUDIT="auto"

die() { printf 'ci-attempts: %s\n' "$*" >&2; exit 2; }

_argloop_prev_1=-1; while (( $# )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
    case "$1" in
        --repo) REPO="${2:-}"; shift 2 ;;
        --audit)    AUDIT=yes; shift ;;
        --no-audit) AUDIT=no;  shift ;;
        # DERIVED, not a line range. `sed -n '2,62p'` was correct exactly once:
        # the header grew by six lines for #762 and the hardcoded bound would
        # have silently truncated `--help` mid-sentence — a doc that quietly
        # stops is the same silent-shortfall shape this file is about. Print
        # the leading comment block and stop at the first line that is not one.
        -h|--help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
        -*) die "unknown argument: $1" ;;
        *)  [[ -z "$REF" ]] || die "expected one ref, got a second: $1"
            REF="$1"; shift ;;
    esac
done

[[ -n "$REF" ]] || die "usage: ng ci-attempts <sha|branch|PR-number> [--repo OWNER/NAME]"

if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
        || die "could not resolve the repo; pass --repo OWNER/NAME"
fi
[[ -n "$REPO" ]] || die "could not resolve the repo; pass --repo OWNER/NAME"

# Resolve to a full head sha. A PR number resolves via its head; a branch via
# its tip. A SHORT sha is resolved rather than used directly: the runs endpoint
# matches head_sha EXACTLY and returns an EMPTY list for an abbreviated one —
# which is indistinguishable, to a caller that does not check, from "this head
# has no CI at all". That silent-zero shape is the same family as the bug this
# file exists to catch, so it is refused rather than reported.
SHA=""
PR_NUM=""
if [[ "$REF" =~ ^[0-9]+$ ]]; then
    PR_NUM="$REF"
    SHA=$(gh pr view "$REF" --repo "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null) \
        || die "could not resolve PR #$REF in $REPO"
elif [[ "$REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
    SHA="$REF"
else
    SHA=$(gh api "/repos/${REPO}/commits/${REF}" --jq .sha 2>/dev/null) \
        || die "could not resolve '$REF' to a commit in $REPO"
fi
[[ "$SHA" =~ ^[0-9a-fA-F]{40}$ ]] || die "refusing to query on a non-40-char sha ('$SHA'); an abbreviated sha returns an EMPTY run list that reads as 'no CI'"

RUNS=$(gh api "/repos/${REPO}/actions/runs?head_sha=${SHA}&per_page=100" 2>/dev/null) \
    || die "could not list runs for $SHA in $REPO — this is 'could not look', which is NOT 'nothing was wrong'"

# THE TALLY IS NOT THE ENUMERATION. `per_page=100` is one page, and nothing
# here paginates. A head with more runs than fit would silently yield a SHORT
# list, and every "band X is missing" conclusion drawn from it would be an
# artefact of the truncation rather than an observation about CI. The API
# reports the true size in `total_count`; comparing against it is the only way
# this file can vouch for its own enumeration, so a mismatch REFUSES instead of
# reporting a confident subset. (Live heads on this repo carry 4-16 runs, so
# this has never fired — it guards a claim, not a current bug.)
_total=$(jq -r '.total_count // "?"' <<<"$RUNS" 2>/dev/null)
_returned=$(jq -r '.workflow_runs | length' <<<"$RUNS" 2>/dev/null)
if [[ "$_total" =~ ^[0-9]+$ ]] && [[ "$_returned" =~ ^[0-9]+$ ]] \
   && (( _total != _returned )); then
    die "run enumeration is INCOMPLETE for $SHA (API reports $_total runs, this page returned $_returned). Refusing to report on a truncated set — any 'missing band' finding would be an artefact of the truncation."
fi

OBSERVED=$(jq -r -f "$_here/ci-observed-runs.jq" <<<"$RUNS" 2>/dev/null) \
    || die "could not extract runs (is jq installed?)"

ENRICHED=""
if [[ -n "$OBSERVED" ]]; then
    ENRICHED=$(bash "$_here/ci-attempt-history.sh" --repo "$REPO" <<<"$OBSERVED") \
        || die "could not resolve attempt history"
    # Did each `failure` EXECUTE anything? (your-org/nexus-code#846.) A run that
    # GitHub aborted before assigning a runner — an account-billing block, a
    # quota refusal — concludes `failure` with `steps: []`, and this verb used
    # to report exit 5 and send the reader into their own diff for a failure
    # that never touched it.
    #
    # NOT `|| die`, and NOT a fallback to an empty string. The honest
    # degradation is the UNENRICHED rows: their execution column is absent,
    # which monitor/ci-trigger-audit.py reads as `unknown`, which keeps every
    # `failure` RED. So a failure of this step costs a worse MESSAGE and never a
    # softer VERDICT — the one direction in which this whole feature is allowed
    # to fail. Same argument, same shape, as ci-signal.yml's fallback for
    # ci-attempt-history.sh.
    if _exec_rows=$(bash "$_here/ci-run-execution.sh" --repo "$REPO" <<<"$ENRICHED"); then
        ENRICHED="$_exec_rows"
    else
        printf 'NOTE: could not read execution evidence (monitor/ci-run-execution.sh\n' >&2
        printf 'failed). Any `failure` below is reported as a real red WITHOUT having\n' >&2
        printf 'checked whether its run executed a single step — unmeasured, not\n' >&2
        printf 'exonerated (#846).\n\n' >&2
    fi
fi

TMP=$(mktemp -d) || die "could not create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# ---- is this PR CONFLICTED? (your-org/nexus-code#773) ----------------------
#
# THE FOURTH CAUSE OF AN EMPTY OBSERVED SET. A PR in `mergeable_state: dirty`
# receives ZERO GitHub Actions check-runs, by construction, and #758's
# three-way decomposition below does not name it:
#
#   - `pull_request` workflows run against the MERGE ref `refs/pull/N/merge`.
#     GitHub cannot compute that ref while the merge conflicts, so no run is
#     created.
#   - `push:` in this repo is scoped `branches: [main, dev]`, so a push to the
#     feature branch does not trigger one either.
#
# Net: CI CANNOT RUN AT ALL until the conflict is resolved, and "wait for the
# bands to go green" waits forever. Before this arm the state landed in the
# outage-shaped arm and pointed the reader at GitHub instead of at the rebase.
# That mis-signposting has already cost one wrong diagnosis: on PR #744, this
# workspace reported "Actions stopped creating runs repo-wide" while PR #767
# had 13 runs at the same moment.
#
# COST, STATED RATHER THAN GLOSSED. This is NOT free. The issue supposed
# `mergeable_state` was "a single API field already fetched on this path"; it
# was not fetched anywhere — it appeared only in a comment. So this is one
# extra API call, and it is spent LAZILY: only on the paths where the answer
# changes the advice (an empty observed set, and a missing-band verdict), never
# on the cleared path, and cached so a second consult is free.
#
# WHICH VALUES THIS ARM CLAIMS, in code rather than only in prose.
# `mergeable_state` takes several values and only ONE of them is a
# by-construction cause of zero runs:
#
#   dirty     CLAIMED. The merge ref is uncomputable. Zero Actions runs.
#   unknown   NOT CLAIMED, and NOT silently treated as "not dirty" — GitHub
#             computes mergeability in a background job and answers `unknown`
#             until it lands, so a single unlucky GET would otherwise convert
#             "could not look" into "not conflicted". That is the exact
#             substitution this file exists to refuse, so it is retried a
#             bounded number of times and then REPORTED as unread.
#   clean|behind|blocked|unstable|draft|has_hooks
#             NOT CLAIMED. None of them stops the merge ref from being
#             computed, so none is a by-construction cause of an empty set.
#             `behind` in particular is NOT a conflict — a boundary drawn one
#             value too wide would be honest, tested, and false.
#
# SETS THE GLOBAL `_MS` RATHER THAN PRINTING, and is called bare rather than in
# `$(…)`. That is the cache, not a style choice: a command substitution runs in
# a SUBSHELL, so a `_MS_CACHED=` assignment inside `_ms=$(_mergeable_state)`
# would be discarded the moment the substitution closed and every consult would
# re-fetch — with up to two `sleep 2` retries. The first draft of this function
# did exactly that while its comment claimed the second consult was free, which
# is this file's own subject matter (a stated property nothing checks) in its
# own remedy. Measured:
#   C=""; f(){ [[ -n "$C" ]] && { echo "$C"; return; }; C=set; echo "$C"; }
#   x=$(f); y=$(f); echo "$C"   →  empty; f ran twice
#
# The cache is LATENT, and that is stated rather than left for a reader to
# assume otherwise. The two call sites below are mutually exclusive by
# construction — the empty-observed arm exits, and the missing-band arm is
# only reachable when runs exist — so nothing consults this twice today. It
# guards a future call site, not a present cost, and no test can currently
# tell a working cache here from a broken one.
_MS_CACHED=""
_MS=""
_mergeable_state() {
    [[ -n "$_MS_CACHED" ]] && { _MS="$_MS_CACHED"; return 0; }
    if [[ -z "$PR_NUM" ]]; then
        _MS_CACHED="no-pr-context"
        _MS="$_MS_CACHED"; return 0
    fi
    local try ms=""
    for try in 1 2 3; do
        # `gh api`, not `gh pr view --json mergeStateStatus`: this host may run
        # gh 1.13.0 (#755), whose `--json` field set predates that key, and the
        # REST payload is byte-identical across clients. It is also the REST
        # `mergeable_state` vocabulary the comment above enumerates, not
        # GraphQL's differently-spelled one (`CONFLICTING`), so the values and
        # the boundary cannot drift apart.
        ms=$(gh api "/repos/${REPO}/pulls/${PR_NUM}" --jq '.mergeable_state // "unknown"' 2>/dev/null) || ms=""
        [[ -n "$ms" && "$ms" != unknown ]] && break
        # Asking again is what MAKES GitHub compute it; a single GET on a PR
        # nobody has polled recently answers `unknown` by default.
        (( try < 3 )) && sleep 2
    done
    _MS_CACHED="${ms:-unread}"
    _MS="$_MS_CACHED"
}

# The one sentence every non-cleared arm needs when the field could not be
# read. Kept in one place so the three call sites cannot drift into three
# different degrees of confidence about the same unread field.
_conflict_caveat() {
    local ms="$1"
    case "$ms" in
        unknown|unread)
            printf 'CAVEAT: this PR'\''s `mergeable_state` could NOT be read (%s), so\n' "$ms"
            printf '"it is not conflicted" is NOT established here. A conflicted PR gets\n'
            printf 'ZERO Actions runs by construction (#773) and would look exactly like\n'
            printf 'the state above. Check it before concluding anything about GitHub.\n\n'
            ;;
        no-pr-context)
            printf 'CAVEAT: no PR context, so conflict status is unavailable — a\n'
            printf 'conflicted PR produces zero runs by construction (#773) and cannot be\n'
            printf 'ruled out from a bare sha.\n\n'
            ;;
    esac
}

# ---- the merge-ref base (your-org/nexus-code#823) --------------------------
#
# Extracted to monitor/_merge_ref_base.sh so it can be tested directly against a
# deterministic stub, rather than against a live PR whose merge ref a passing
# reader can move by opening the page. (This used to say the STALE arm "cannot be
# demonstrated on a live PR on demand" — that hedge was honest when written and is
# now discharged by measurement; see the library's header, your-org/nexus-code#859.
# The stub remains the right fixture; only the impossibility claim was wrong.)
# This file stays the only CALLER; the library stays the only definition.
[[ -r "$_here/_merge_ref_base.sh" ]] || die "missing $_here/_merge_ref_base.sh — refusing to report a clearance without the merge-ref base check (your-org/nexus-code#823)"
# The path is spelled out LITERALLY rather than held in a variable, and that is
# load-bearing rather than a style choice: `early-exit-readers.sh` builds its
# pipefail axis by grepping source lines for a literal `*.sh` basename, so
# `. "$_mrb_lib"` is an edge it cannot resolve — the library would sit off the
# axis, and the guard's silence about it would mean "could not see it", not
# "nothing there". Measured: with the variable form the classifier recorded
# ZERO sites for the library while this file is `set -o pipefail`.
# shellcheck source=/dev/null
. "$_here/_merge_ref_base.sh"

# ---- expected-band audit (your-org/nexus-code#740) -------------------------
#
# Composed, never reimplemented: ci-trigger-audit.py stays the single owner of
# trigger semantics and of the #628 verdict invariant. All this does is make it
# reachable from OUTSIDE Actions, which is the whole point — the guard that
# would have caught the outage was itself among the things the outage stopped.
AUDIT_RAN=no
AUDIT_RC=0
AUDIT_OUT=""
AUDIT_SKIP=""

# The workflows must be read AT THE HEAD SHA, not from whatever this clone
# happens to have checked out. Auditing a head against a different revision's
# trigger definitions would answer a question about the wrong tree — the exact
# shape of defect this verb exists to catch. Local objects first (no API), the
# contents API second, and a REFUSAL third: there is no third-best source that
# is still honest.
_materialize_workflows() {
    local sha="$1" dest="$2" root f n list got=0
    root=$(cd "$_here/.." && pwd)
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1 \
       && git -C "$root" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            if git -C "$root" show "${sha}:${f}" > "$dest/${f##*/}" 2>/dev/null; then
                got=1
            fi
        done < <(git -C "$root" ls-tree --name-only "${sha}" .github/workflows/ 2>/dev/null)
    fi
    (( got )) && return 0
    list=$(gh api "repos/${REPO}/contents/.github/workflows?ref=${sha}" --jq '.[].name' 2>/dev/null) || list=""
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if gh api "repos/${REPO}/contents/.github/workflows/${n}?ref=${sha}" \
               -H 'Accept: application/vnd.github.raw' > "$dest/$n" 2>/dev/null; then
            got=1
        fi
    done <<<"$list"
    (( got )) && return 0
    return 1
}

if [[ "$AUDIT" != "no" ]]; then
    if [[ -z "$PR_NUM" ]]; then
        AUDIT_SKIP="no PR context — expectations are derived from the PR's BASE ref and CHANGED files, and a bare sha carries neither"
    else
        _base=$(gh pr view "$PR_NUM" --repo "$REPO" --json baseRefName --jq .baseRefName 2>/dev/null) || _base=""
        _nfiles=$(gh pr view "$PR_NUM" --repo "$REPO" --json changedFiles --jq .changedFiles 2>/dev/null) || _nfiles=""
        gh pr view "$PR_NUM" --repo "$REPO" --json files --jq '.files[].path' > "$TMP/changed.txt" 2>/dev/null || : > "$TMP/changed.txt"
        # NOT `grep -c . file || echo 0`. On an EMPTY file `grep -c` prints
        # `0` *and* exits 1, so the fallback appends a second line and
        # `_listed` becomes "0\n0" — and on a real error it manufactures a
        # confident `0` from a failure. Counting a silent zero into a claim is
        # the exact defect this file is being hardened against. `awk` counts
        # non-empty lines, always exits 0, and reports 0 because it MEASURED 0.
        _listed=$(awk 'NF { n++ } END { print n+0 }' "$TMP/changed.txt")
        if [[ -z "$_base" ]]; then
            AUDIT_SKIP="could not resolve PR #${PR_NUM}'s base ref"
        elif [[ ! "$_nfiles" =~ ^[0-9]+$ ]]; then
            # A tally that CANNOT BE READ must not silently disable the guard
            # that depends on it. Previously a non-numeric `changedFiles`
            # (null, an error string, an older `gh` that omits the field —
            # this host runs gh 1.13.0, see #755) made the regex false, which
            # skipped the comparison and let the audit proceed on an
            # UNVOUCHED file list: "could not read the tally" collapsing into
            # "the enumeration is fine". That is this file's own subject
            # matter, inside its own guard.
            AUDIT_SKIP="changed-file tally is UNREADABLE (changedFiles=${_nfiles:-<empty>}) — the file list cannot be vouched for, and an unvouched list would silently shrink the expected set"
        elif (( _listed != _nfiles )); then
            # Same tally-vs-enumeration rule as the run list above: a short
            # file list silently shrinks the EXPECTED set, which would turn a
            # missing band into a band that was never expected.
            AUDIT_SKIP="changed-file enumeration is INCOMPLETE (PR reports $_nfiles files, $_listed listed) — a short list would silently shrink the expected set"
        elif ! _materialize_workflows "$SHA" "$TMP"; then
            AUDIT_SKIP="could not read .github/workflows at ${SHA:0:12} from either local objects or the contents API — auditing against this clone's checked-out workflows would judge the head by another revision's triggers"
        else
            printf '%s\n' "$ENRICHED" > "$TMP/observed.txt"
            AUDIT_OUT=$(python3 "$_here/ci-trigger-audit.py" \
                            --workflows-dir "$TMP" \
                            --base-ref "$_base" \
                            --changed-files "$TMP/changed.txt" \
                            --observed "$TMP/observed.txt" \
                            --self-workflow ci-signal.yml 2>&1)
            AUDIT_RC=$?
            AUDIT_RAN=yes
        fi
    fi
    # `--audit` MEANS "audited, or refused" — for EVERY cause, not just the
    # one that happened to be checked inline. This used to `die` only on
    # "no PR context"; the other three skip causes (base ref unresolvable,
    # changed-file enumeration incomplete or unreadable, workflows
    # unreadable) fell through to rc 0 with a prose disclaimer. A caller
    # scripting `ng ci-attempts <PR> --audit && merge` would then merge on
    # an audit that never ran — which is this file's own thesis ("a prose
    # disclaimer at the bottom is not a gate") left unapplied to the flag
    # whose entire purpose is to BE a gate. One check, after the chain, so a
    # cause added later cannot forget to honour the flag.
    if [[ "$AUDIT" == "yes" && "$AUDIT_RAN" != yes ]]; then
        die "--audit was requested but the expected-band audit could not run: ${AUDIT_SKIP:-unspecified}. Refusing rather than reporting on runs alone — you asked for the audit, so its absence is a failure, not a footnote."
    fi
fi

printf 'head %s (%s)\n\n' "${SHA:0:12}" "$REPO"

# ---- the empty observed set, decomposed by CAUSE --------------------------
#
# "Zero runs" is not one finding. Reporting it as one number would be the
# defect this verb is being hardened against, reproduced inside the remedy.
if [[ -z "$OBSERVED" ]]; then
    printf '  NO runs recorded at this head at all.\n\n'

    # ARM 4, FIRST because it is STRUCTURAL (your-org/nexus-code#773). The
    # other three arms all ask "why did the workflows GitHub was willing to run
    # not run?". This one says GitHub was never willing: with the merge ref
    # uncomputable there is no event to fire on, so the emptiness is fully
    # explained before those questions are worth asking. Placed ahead of the
    # outage arm exactly as the issue asks, and ahead of the
    # triggers-select-nothing arm too — a conflicted PR produces zero runs
    # whatever its triggers say, so reporting the trigger analysis first would
    # hand the reader an explanation that is true but not the operative one.
    _mergeable_state; _ms="$_MS"
    if [[ "$_ms" == dirty ]]; then
        printf 'CAUSE: this PR is CONFLICTED (`mergeable_state: dirty`). No Actions\n'
        printf 'run can exist at this head, by construction — `pull_request`\n'
        printf 'workflows run against the merge ref `refs/pull/%s/merge`, which\n' "$PR_NUM"
        printf 'GitHub cannot compute while the merge conflicts, and this repo scopes\n'
        printf '`push:` to [main, dev] so a feature-branch push does not trigger one\n'
        printf 'either. This is NOT an outage and NOT a trigger gap: waiting for the\n'
        printf 'bands to go green here waits forever.\n\n'
        printf 'REMEDY: rebase or merge the base branch into this PR to resolve the\n'
        printf 'conflict, then push. CI starts at the new head.\n'
        if [[ "$AUDIT_RAN" == yes ]] && (( AUDIT_RC == 0 )); then
            # Both things are true and the reader needs both, or a rebase will
            # be followed by the same empty screen and a second wrong diagnosis.
            printf '\nAND SEPARATELY: the expected-band audit came back clean, meaning no\n'
            printf 'workflow'\''s triggers select this change anyway. Resolving the\n'
            printf 'conflict will NOT by itself produce a run — this change is untested\n'
            printf 'for a second, independent reason.\n'
        fi
        exit 7
    fi
    _conflict_caveat "$_ms"

    if [[ "$AUDIT_RAN" == yes ]] && (( AUDIT_RC == 0 )); then
        printf 'CAUSE: the triggers genuinely select nothing for this change — no\n'
        printf 'workflow was expected to gate it. That is a legitimate state (a\n'
        printf 'docs-only tweak, say), but it is a SENTENCE, not a green: this\n'
        printf 'change is UNTESTED, it is merely untested on purpose.\n'
        exit 4
    fi
    if [[ "$AUDIT_RAN" == yes ]]; then
        printf 'CAUSE: bands WERE expected and none of them ran. That is a provider\n'
        printf 'outage or a dispatch that never registered — not a pass. The audit:\n\n'
        printf '%s\n' "$AUDIT_OUT"
        exit 4
    fi
    printf 'CAUSE: UNDETERMINED — the expected-band audit did not run (%s),\n' "${AUDIT_SKIP:-not requested}"
    printf 'so "no runs" cannot be separated from "no runs were expected".\n'
    printf 'This is an absence, and an unexplained one. It is not a pass.\n'
    exit 2
fi

rc=0
live_red=0
provenance=0
# A `failure` that executed ZERO steps (your-org/nexus-code#846). Counted
# separately from `live_red` because the two demand opposite actions — fix the
# code vs fix the account — and this file used to have only the first counter,
# so an unexecuted run drove the verb to exit 5 and told the reader to read logs
# that do not exist. Only POSITIVE evidence lands here; `unknown` (including an
# absent column, the pre-#846 wire format) counts as a live red.
unexecuted=0
# your-org/nexus-code#884 — the OTHER member of the excluded set: a run that
# COMPLETED with a conclusion that is neither `success` nor `failure`
# (`skipped`, `cancelled`, `neutral`, `timed_out`, `action_required`). The rows
# have always marked it `--  … — not a verdict`; nothing counted it, so the
# summary quantified over it and asserted it was a success. Same tell as #762
# below: the information was in the rows and only the SUMMARY contradicted it.
nonverdict=0
nonverdict_names=""
# your-org/nexus-code#762. The per-row output has ALWAYS distinguished a run
# that has not concluded (`.... still in_progress`), so the information was
# present and only the SUMMARY contradicted it. That is the tell that the bug
# is in the aggregation, not in the wording — so these counters exist to make
# the summary quantify over the same set the rows do. Rows, not workflows: a
# workflow with two runs at one sha is two facts about this head.
pending_n=0
concluded_n=0
pending_names=""
# NOT `IFS=$'\t' read -r path status conclusion ...`. TAB is an IFS WHITESPACE
# character, so bash collapses runs of it and DROPS empty fields: an in-flight
# run has an empty conclusion, and
#   path<TAB>in_progress<TAB><TAB>1<TAB>99<TAB>
# would read back as conclusion=1, attempt=99, priors=(empty) — every pending
# run silently reclassified as a 99th attempt with unreadable provenance, i.e.
# a false RETRY-UNKNOWN on exactly the rows that are still fine. Measured, not
# assumed:
#   printf 'a\tcompleted\t\t2\t99\tfailure\n' | while IFS=$'\t' read -r p s c a i r
#   → concl=[2] attempt=[99] id=[failure] priors=[]
# Explicit prefix-stripping preserves empty fields, which is why
# ci-attempt-history.sh parses the same way.
_field() {
    local n="$1" line="$2" i=1
    while (( i < n )); do
        [[ "$line" == *$'\t'* ]] || { printf ''; return 0; }
        line=${line#*$'\t'}
        i=$(( i + 1 ))
    done
    printf '%s' "${line%%$'\t'*}"
}

while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    path=$(_field 1 "$line")
    status=$(_field 2 "$line")
    conclusion=$(_field 3 "$line")
    attempt=$(_field 4 "$line")
    priors=$(_field 6 "$line")
    # Field 7 is ABSENT on the pre-#846 wire format, and an empty string is not
    # `unexecuted`, so the arm below falls through to the live-red branch. The
    # default is the RED one on purpose.
    execution=$(_field 7 "$line")
    exec_detail=$(_field 8 "$line")
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=1
    wf="${path##*/}"
    mark="ok"
    note=""
    if [[ "$status" != "completed" ]]; then
        mark="....";  note="still $status — no verdict yet"
        pending_n=$(( pending_n + 1 ))
        pending_names="${pending_names:+$pending_names, }$wf"
    elif [[ "$conclusion" == "failure" && "$execution" == "unexecuted" ]]; then
        # POSITIVE evidence only. Nothing else in this file may set this mark.
        mark="NOT-STARTED"
        note="concluded failure having executed ZERO steps — ${exec_detail:-no detail}"
        unexecuted=$(( unexecuted + 1 ))
    elif [[ "$conclusion" == "failure" ]]; then
        mark="RED";   note="concluded failure"; live_red=1
    elif [[ "$conclusion" != "success" ]]; then
        mark="--";    note="concluded $conclusion — not a verdict"
        # your-org/nexus-code#884 — COUNTED, because it was not.
        #
        # This run is `completed`, so `concluded_n` below includes it, and every
        # universal claim in this file is quantified over completed runs. It is
        # not a `success`. So each of those claims was FALSE whenever this arm
        # fired, and the contradiction printed in the same output: `--  wf
        # concluded skipped — not a verdict` three lines above `VERDICT: every
        # completed run at this head is a FIRST-PASS success.`
        #
        # The `unexecuted` member above already had this treatment. This one did
        # not, so the five claim sites were qualified for one member of the
        # excluded set and not the other — the defect is the ASYMMETRY, not the
        # missing sentence.
        nonverdict=$(( nonverdict + 1 ))
        nonverdict_names="${nonverdict_names:+$nonverdict_names, }${wf} (${conclusion})"
    fi
    if [[ "$status" == "completed" ]]; then
        concluded_n=$(( concluded_n + 1 ))
    fi
    if (( attempt > 1 )); then
        case ",$priors," in
            *,failure,*)
                mark="RETRY-OVER-RED"
                note="attempt $attempt; superseded attempt(s) concluded ${priors} — this green REPLACED a red at this same sha"
                provenance=1 ;;
            *,'?',*|*,,*)
                mark="RETRY-UNKNOWN"
                note="attempt $attempt; superseded attempt(s) UNREADABLE (${priors:-none reported}) — provenance could not be verified"
                provenance=1 ;;
            *)
                note="attempt $attempt; superseded attempt(s) concluded ${priors} — no verdict was replaced" ;;
        esac
    fi
    printf '  %-16s %-34s %s\n' "$mark" "$wf" "${note:-attempt 1, success}"
done <<<"$ENRICHED"

printf '\n'
if [[ "$AUDIT_RAN" == yes ]]; then
    printf '%s\n\n' "$AUDIT_OUT"
fi

# The aborted runs, mentioned by whichever arm WINS over them (#846 / PR #854
# skeptic F1). Losing the precedence must not mean losing the fact: a reader who
# is told only "still in progress" fixes the wait and is ambushed by the billing
# block, and one told only "this head is RED" fixes code that was never run.
# One function so the arms cannot drift into three degrees of disclosure.
# ---- THE EXCLUDED SET, DECIDED IN ONE PLACE (your-org/nexus-code#884) -------
#
# Five sentences in this file make a UNIVERSAL claim about the runs at this
# head. Each one branched on `(( unexecuted ))` privately, and when a second
# member of the excluded set appeared, four of five were never taught about it —
# so at rc 0 the verb printed `every completed run at this head is a FIRST-PASS
# success` underneath a row reading `--  wf  concluded skipped — not a verdict`.
#
# The fix is not five more `if`s. It is that MEMBERSHIP and its WORDING are
# decided here, once, and the claim sites ask. A third member added later is
# then qualified into all five by construction, which is the only version of
# this that stays fixed. Same reasoning as `_excluded_note` below, which already
# exists because three arms had drifted into three degrees of disclosure.
#
# `_excl_any` — is anything excluded at all.
# `_excl_clause` — the clause that narrows the QUANTIFIER.
# `_excl_count_phrase` — names what was excluded, for the parenthetical.
#
# WHAT IS PRESERVED, AND WHAT IS NOT (corrected, your-org/nexus-code#955
# skeptic round 3). This block used to claim the `unexecuted`-only wording was
# preserved "BYTE-FOR-BYTE … asserted differentially in
# test-ci-head-attempts.sh". Both halves were false, and the sentence is exactly
# the kind of over-claim the three fixes on this PR exist to remove — so it is
# corrected rather than deleted, since the reader still needs to know the shape
# of the change.
#
# Preserved: the WORDING — `that EXECUTED`, `%d ran nothing at all`, and the
# absence of any non-verdict clause — on every head with `nonverdict == 0`.
# NOT preserved: the LINE WRAPPING. Folding the count into `_excl_count_phrase`
# moved the phrase into the first `printf`, so the break lands after it instead
# of inside it. Measured across all 42 fixtures in test-ci-head-attempts.sh at
# 423f92e vs 50d1621: 6 outputs changed, 5 of them the intended #884/#885 cases
# and ONE — the rc-9 stale-merge-ref arm, `unexecuted`-only — a pure reflow:
#     -  … is a first-pass success (1 ran
#     -  nothing at all — see below), AND the merge ref …
#     +  … is a first-pass success (1 ran nothing at all
#     +  — see below), AND the merge ref …
# Cosmetic, and unavoidable while the phrase is dynamic. It is written down
# because an invariant nobody can check is the same liability as a silent zero.
#
# Asserted now, in test-ci-head-attempts.sh, at the level that is actually true:
# T32 pins the zero-exclusion sentence, and the `unexecuted`-only WORDING is
# pinned on the rc-9 arm (`that EXECUTED`, `ran nothing at all`, and NO
# `RETURNED A VERDICT`). Byte-identity of the whole output is NOT asserted; it
# would need a golden file, and no test in this suite compares bytes
# (`grep -c 'diff <(' monitor/test-ci-head-attempts.sh` → 0).
_excl_any()  { (( unexecuted || nonverdict )); }
# BARE (no leading `that`): one call site reads `every run that EXISTS and
# %s`, where a second `that` would be ungrammatical. Sites that need it prepend
# their own — which also keeps the `unexecuted`-only output byte-identical.
_excl_clause() {
    if   (( unexecuted && nonverdict )); then printf 'EXECUTED and RETURNED A VERDICT'
    elif (( unexecuted ));               then printf 'EXECUTED'
    else                                      printf 'RETURNED A VERDICT'
    fi
}
_excl_count_phrase() {
    local _p=""
    (( unexecuted )) && _p="${unexecuted} ran nothing at all"
    (( nonverdict )) && _p="${_p:+$_p; }${nonverdict} concluded without a verdict"
    printf '%s' "$_p"
}

# The #884 member's disclosure. Called from `_excluded_note` rather than from
# the eight arms, for the reason that function already records: one function so
# the arms cannot drift into different degrees of disclosure.
_nonverdict_note() {
    (( nonverdict )) || return 0
    printf '\nALSO AT THIS HEAD: %d run(s) COMPLETED with a conclusion that is not a\n' "$nonverdict"
    printf 'verdict (marked `--` above): %s. A non-verdict is not a\n' "$nonverdict_names"
    printf 'success — it is the ABSENCE of one, which your-org/nexus-code#628 treats\n'
    printf 'as red when the band was expected to gate. It is excluded from the\n'
    printf 'claim above rather than counted into it.\n'
}

# ---- your-org/nexus-code#885: WHAT IT SAYS, PER ARM ------------------------
#
# This helper was audited by whether each arm CALLS it. That is a PRESENCE
# test, and presence was never the property — the property is whether what it
# SAYS is true in the arm that called it. Verified, on the audit arm:
#
#   fixture: `tests.yml` (a GATING band) concluded `failure` having executed
#   ZERO steps, `docs.yml` still in progress (so `pending_n > 0` keeps the
#   NOT-STARTED arm shut and this arm wins).
#
#   the audit says   : `UNEXECUTED-RUN: tests.yml … Reported as an ABSENCE of
#                       verdict (exit 4)`
#   the verdict says : `the expected-band audit above did NOT come back clean
#                       (rc 4)`
#   this note said   : `That does NOT drive the verdict above`
#
# All three in one output. The unexecuted run was the sole cause of the audit's
# rc 4, which was the sole cause of the verdict — so the disclosure asserted the
# opposite of what its own arm had just printed. A call-site census could never
# have seen it: the call was there.
#
# So the causal claim is now the CALLER's to make, because causality is a
# property of the arm and not of the helper:
#
#   independent — the excluded runs did not drive this verdict. Safe to say
#                 "don't chase this"; true for provenance, UNGATED, conflicted,
#                 pending and stale-ref, where the verdict has a different cause.
#   drives      — they are the cause. Reserved; no arm currently claims it.
#   unknown     — cannot be established here. The audit arm: its rc 4 may come
#                 from an unexecuted run OR from a genuinely missing band, and
#                 this helper cannot tell which. It therefore says NEITHER,
#                 which is the honest answer and the fail-safe one. The audit's
#                 own paragraph above already states the true cause.
#
# An absent or unrecognised argument resolves to `unknown` — a new call site
# that forgets to decide gets silence about causality rather than a confident
# sentence somebody else chose for it. That default is the whole point: the
# previous default was a CLAIM.
_excluded_note() {
    local _cause="${1:-unknown}"
    _nonverdict_note
    (( unexecuted )) || return 0
    printf '\nALSO AT THIS HEAD: %d run(s) concluded `failure` having executed ZERO\n' "$unexecuted"
    printf 'steps (marked NOT-STARTED above) — an account or runner-supply problem,\n'
    case "$_cause" in
        independent)
            printf 'not your code. That does NOT drive the verdict above, and it does not\n'
            printf 'clear by waiting either: it needs the supply fixed and a re-run.\n' ;;
        drives)
            printf 'not your code. That IS what drove the verdict above, and it does not\n'
            printf 'clear by waiting either: it needs the supply fixed and a re-run.\n' ;;
        *)
            printf 'not your code. It does not clear by waiting: it needs the supply fixed\n'
            printf 'and a re-run. Whether it is what drove the verdict above is stated by\n'
            printf 'the audit output above, not here.\n' ;;
    esac
}

if (( live_red )); then
    printf 'VERDICT: a run at this head concluded `failure`. This head is RED.\n'
    if (( unexecuted )); then
        # Both facts, or the reader fixes one and is ambushed by the other.
        printf 'AND SEPARATELY: %d run(s) at this head concluded `failure` having\n' "$unexecuted"
        printf 'executed ZERO steps (marked NOT-STARTED above). Those are plumbing, not\n'
        printf 'code — but the red above is NOT one of them, so it still needs fixing.\n'
    fi
    rc=5
elif (( provenance )); then
    # The opening sentence is QUANTIFIED OVER COMPLETED RUNS, and it was flatly
    # false whenever one of them concluded `failure` with zero steps — which is
    # the condition this whole verb was changed to surface. Not an omission: a
    # claim of the opposite. Qualified rather than deleted, because the
    # provenance finding itself is still true and still the verdict.
    if _excl_any; then
        printf 'VERDICT: every completed run that %s is green (%s\n' "$(_excl_clause)" "$(_excl_count_phrase)"
        printf '— see below), but at least one green is NOT a\n'
    else
        printf 'VERDICT: every completed run is green, but at least one green is NOT a\n'
    fi
    printf 'first-pass green (or its provenance is unreadable). A red that was\n'
    printf 're-run is still a red that nobody adjudicated — decide whether it was\n'
    printf 'a flake or a real defect before treating this head as tested.\n'
    _excluded_note independent
    rc=6
elif [[ "$AUDIT_RAN" == yes ]] && (( AUDIT_RC == 8 )); then
    # UNGATED (your-org/nexus-code#856). Handled BEFORE the generic
    # non-zero arm, which would otherwise open "every run that EXISTS is a
    # first-pass success, but the expected-band audit did NOT come back clean"
    # — true, and the wrong diagnosis: nothing is missing, nothing failed, and
    # no band was ever selected by this diff.
    #
    # THIS IS THE MERGE-PATH READER, so unlike ci-signal.yml (a peer check that
    # warns and stays green) it REFUSES. The two readers want opposite things
    # from the same state, which is the same split rc 3 already has.
    printf 'VERDICT: this head is NOT CLEARED — nothing examined your change.\n'
    printf 'Every GATING workflow that fired is green, and NOT ONE of them was\n'
    printf 'selected\n'
    printf 'by what this diff changes: they carry no `paths:` filter, so they fire\n'
    printf 'on every PR and their green is evidence about the PR existing, not\n'
    printf 'about these files. The audit above NAMES the files nothing examined.\n\n'
    printf 'The merge rule this workspace applies — "each expected band exactly\n'
    printf 'once, every band success" — is satisfied VACUOUSLY here, because the\n'
    printf 'expected set contains only unconditional bands. That rule cannot tell\n'
    printf 'a band that correctly did not apply from a band suppressed by a\n'
    printf '`paths:` filter: both render as ABSENT, and this verb cannot tell\n'
    printf 'them apart either. What it CAN tell you — and what the merge rule\n'
    printf 'could not — is that NO band selected by your diff ran at all, which\n'
    printf 'is enough to withhold a clearance and not enough to call it a defect.\n\n'
    printf 'DECIDE, do not inherit: if a suite covers these files, wire them into\n'
    printf 'its workflow `paths:` filter and push. If they genuinely need no\n'
    printf 'suite, say so explicitly on the PR — that is a judgement a person\n'
    printf 'makes, and this verb refuses so that it gets made.\n'
    # INTRODUCED BY A REBASE, not by either PR (#854 skeptic, post-rebase).
    # This arm arrived from #856/#868 and landed ABOVE every #846 arm in the
    # same chain. Its siblings all disclose unexecuted runs; this one did not,
    # so at rc 8 the summary silently dropped a fact every other arm carries.
    #
    # Reachable rather than theoretical: `unexecuted` is counted over EVERY run
    # at the head, including non-gating ones, while rc 8 is a statement about
    # the GATING set — so a non-gating band can have concluded `failure` with
    # zero steps while the gating set is UNGATED.
    #
    # Bounded, and worth stating so the severity is not overread: rc 8 already
    # withholds clearance, so this could never open a merge or swallow a red.
    # It is a DISCLOSURE gap. It still wants fixing, because a verdict chain
    # where one arm omits what its siblings disclose is what makes a reader
    # stop trusting all of them.
    _excluded_note independent
    rc=8
# THE GUARDS ARE THE ORDERING (#846 / PR #854 skeptic F1). The arms below are
# mutually exclusive on `AUDIT_RAN`/`AUDIT_RC`, so the effective precedence is
# set by two conditions rather than by moving twenty-six lines:
#
#   this arm    fires unless an aborted run is the ONLY thing wrong
#               (`unexecuted == 0 || pending_n > 0`)
#   the         fires only when nothing is still running
#   `unexecuted`  (`pending_n == 0`)
#   arm below
#
# Net order: live-red > provenance > PENDING > UNEXECUTED > audit findings.
#
# BOTH guards were needed, and the first attempt that carried only one is why
# they are written out. Moving the `unexecuted` arm below the pending arms fixed
# the reported stop-waiting over-claim and immediately manufactured a NEW one
# HERE — on the live billing-blocked head this arm won and opened "every run
# that EXISTS is a first-pass success" while four runs had concluded `failure`.
# Adding `unexecuted == 0` fixed that and STILL left F1 alive for the shape the
# skeptic actually reported, because an aborted run beside an in-flight one can
# also carry a genuinely missing third band: the audit then reds at rc 4, this
# arm was skipped, and the `unexecuted` arm caught it and told the reader to
# stop waiting anyway. `pending_n > 0` here, and `pending_n == 0` there, is what
# closes it — the property is "is anything still running", and it has to be
# asked on the tally, not inferred from the audit's exit code.
#
# The audit verdicts that would outrank an absence are already claimed above: an
# audit rc 5 means a gating band's `failure` SPOKE, which sets `live_red`, and
# rc 6 sets `provenance`. Audit rc 1 maps to 4 in the `case` below anyway, so
# nothing this arm would have said is lost — and the audit's own full output,
# trigger gap included, is printed above the verdict either way.
elif [[ "$AUDIT_RAN" == yes ]] && (( AUDIT_RC != 0 && AUDIT_RC != 3 )) \
     && (( unexecuted == 0 || pending_n > 0 )); then
    # The PARTIAL set — the case a prose disclaimer never caught. Every run
    # that exists is a first-pass green, which is TRUE and reads as approval;
    # the bands that never ran are invisible in that sentence.
    #
    # The opening sentence is QUANTIFIED, and after #846 it has to be said
    # conditionally: this arm is now reachable with `unexecuted > 0` (when
    # something is also still running), and "every run that EXISTS is a
    # first-pass success" is flatly false about a head where four runs
    # concluded `failure`. It is exactly the vacuous-quantifier defect #762
    # fixed one arm over, so it gets the same treatment rather than a
    # disclaimer underneath.
    if ! _excl_any; then
        printf 'VERDICT: every run that EXISTS is a first-pass success, but the\n'
    else
        printf 'VERDICT: every run that EXISTS and %s is a first-pass success\n' "$(_excl_clause)"
        printf '(%s — see below), but the\n' "$(_excl_count_phrase)"
    fi
    printf 'expected-band audit above did NOT come back clean (rc %s). Bands that\n' "$AUDIT_RC"
    printf 'should have gated this change are missing or carry no verdict. The\n'
    printf 'absence of a verdict is RED — this head is NOT cleared.\n'
    _excluded_note unknown
    # The SECOND place a conflict changes the advice (#773). Runs exist here —
    # a manual dispatch, or runs from before the base moved — so this is not
    # the empty-set arm, but the missing bands still cannot arrive while the
    # merge ref is uncomputable. Without this line the reader is told bands are
    # missing and left to wait for them.
    _mergeable_state; _ms="$_MS"
    if [[ "$_ms" == dirty ]]; then
        printf '\nAND THE MISSING BANDS CANNOT ARRIVE: this PR is CONFLICTED\n'
        printf '(`mergeable_state: dirty`), so `pull_request` workflows have no\n'
        printf 'computable merge ref to run against (#773). Rebase first; re-running\n'
        printf 'or waiting will not produce them.\n'
    fi
    case "$AUDIT_RC" in
        4|1) rc=4 ;;
        5)   rc=5 ;;
        6)   rc=6 ;;
        *)   rc=4 ;;
    esac
elif [[ "$AUDIT_RAN" == yes ]] && (( AUDIT_RC == 3 )); then
    # NOT CONCLUDED, per the audit's own quantifier (your-org/nexus-code#762).
    #
    # WHICH SET the claim is about is the whole point, so the audit's answer is
    # preferred here over this file's own row tally: the audit knows the
    # EXPECTED bands, this file only knows the runs that happen to exist, and
    # "every band that should have gated this change" is the stronger and more
    # useful statement. The audit's own NOT-CONCLUDED block above already names
    # the pending bands and says whether the concluded subset is empty or
    # partial; repeating it here would be a second copy free to drift.
    printf 'VERDICT: this head is NOT CLEARED — it has not finished.\n'
    if (( unexecuted )); then
        printf 'No band is missing, gapped or replaced — but %d run(s) executed\n' "$unexecuted"
        printf 'NOTHING (see below), and nothing says this head passed either:\n'
        printf 'the expected-band audit\n'
    else
        printf 'Nothing is wrong with the check set (no band is missing, gapped or\n'
        printf 'replaced) and nothing says it passed either: the expected-band audit\n'
    fi
    printf 'above reports bands still queued or in progress. An unfinished check\n'
    printf 'set is an ABSENCE of verdict, and #628 rules that RED, not amber.\n'
    printf 'Re-run this verb once those bands conclude.\n'
    _excluded_note independent
    rc=3
elif [[ "$AUDIT_RAN" != yes ]] && (( pending_n > 0 )); then
    # Same state, reached WITHOUT the audit — so the quantifier is weaker and
    # must be stated as such. Here the only set this file knows is the runs
    # that EXIST at this head; a band that never fired is invisible either way
    # (that is what the audit is for), so this says "not concluded" and does
    # NOT say "nothing is missing".
    printf 'VERDICT: this head is NOT CLEARED — it has not finished.\n'
    if (( concluded_n == 0 )); then
        printf 'NO run at this head has concluded yet (%d still queued or in\n' "$pending_n"
        printf 'progress: %s). "Every completed run is a first-pass\n' "$pending_names"
        printf 'success" would be quantified over the EMPTY SET here — vacuously\n'
        printf 'true, and it is exactly that sentence which used to print as\n'
        printf 'cleared (#762). There is no evidence yet, of any sign.\n'
    else
        printf 'PARTIAL and PROVISIONAL: %d run(s) have concluded and every one that\n' "$concluded_n"
        printf '%s is a first-pass success; %d have NOT (%s).\n' \
            "$( _excl_any && _excl_clause || printf 'EXECUTED' )" "$pending_n" "$pending_names"
        printf 'That green describes the runs that FINISHED. It is not a\n'
        printf 'description of this head, and the pending runs can still redden it.\n'
    fi
    printf 'Scope: this is a claim about the runs that EXIST — the expected-band\n'
    printf 'audit did NOT run (%s), so a\n' "${AUDIT_SKIP:-not requested}"
    printf 'workflow that should have gated this change and never fired would be\n'
    printf 'INVISIBLE above, separately from the pending ones named here.\n'
    _excluded_note independent
    rc=3
elif (( unexecuted )) && (( pending_n == 0 )); then
    # your-org/nexus-code#846, PLACED HERE AND NOT HIGHER — the skeptic pass on
    # PR #854 (F1) found this arm sitting ABOVE every pending arm, where it won
    # over a run that was still executing. It printed "it will NOT clear by
    # waiting" and "no diff can address it" TWO LINES BELOW its own
    # "still in_progress — no verdict yet". Both are false while a run is
    # running.
    #
    # THE DEFECT WAS NOT THE ORDERING, IT WAS WHERE THE PROPERTY WAS CHECKED.
    # `classify_runs()` in ci-trigger-audit.py ranks UNEXECUTED below PENDING
    # and says why in its docstring, and fixture 17g pins it. The PR body then
    # claimed the precedence outright — but the claim had been verified against
    # the PYTHON half only, while this shell verb, the surface a human actually
    # reads, carried the opposite order and no test. A property verified on one
    # implementation and asserted of both is the your-org/nexus-code#836 shape.
    #
    # So: below BOTH pending arms, and below the audit-findings arm, which
    # leaves this reachable only when nothing else at this head has a claim.
    # T25 covers the aborted-beside-in-flight case the skeptic had to construct
    # by hand.
    printf 'VERDICT: this head is NOT CLEARED, and NOT because of your code.\n'
    printf '%d run(s) concluded `failure` having executed ZERO steps: every job ran\n' "$unexecuted"
    printf 'nothing and none was ever assigned a runner. GitHub created the run,\n'
    printf 'labelled it a failure, and never started it. There are no logs to read\n'
    printf 'and no test that said no — a suite that did not execute has not spoken,\n'
    printf 'whatever the conclusion string says (#628, #846).\n'
    printf 'CAUSE is an account or runner-supply problem — billing, a spending\n'
    printf 'limit, a quota, an Actions incident — and it will NOT clear by waiting\n'
    printf 'or by editing code. Fix the supply, then push or re-run.\n'
    printf 'The absence of a verdict is RED: this head is untested, and it is\n'
    printf 'untested for a reason no diff can address.\n'
    rc=4
else
    # THE MERGE-REF BASE, checked BEFORE the clearance sentence and able to
    # withhold it (your-org/nexus-code#823). Everything above establishes that
    # the right bands ran and concluded green; this establishes that what they
    # ran against is what would land. Those are different questions, and until
    # now this verb answered only the first while sounding like it answered
    # both.
    _merge_ref_base
    # THE GATE IS ASKED, NOT ENUMERATED (your-org/nexus-code#878, #882). This
    # used to be spelled `[[ "$_MRB_STATE" == stale ]]` — a DENYLIST with a
    # permissive default arm, so any state the library grew afterwards would
    # have fallen through to the clearance below and CLEARED the head while the
    # summary line printed `NOT CHECKED`. The library now owns an ALLOWLIST with
    # a default-DENY arm and the caller asks it, which is the only version of
    # this that survives the next state being added. Same structural lesson as
    # `bk_pane_kill_authorized`: a hand-enumerated denylist retires whatever its
    # author did not think of.
    _mrb_disp=$(_mrb_clearance_disposition "$_MRB_STATE")
    if [[ "$_mrb_disp" == withhold && "$_MRB_STATE" != stale ]]; then
        # Every withholding state EXCEPT `stale`, whose prose is the arm below
        # (left exactly where it was — it is under a negative control that pins
        # its text, and re-indenting it would silently retire that control).
        if [[ "$_MRB_STATE" == divergent ]]; then
            _mrb_exit=10
            printf 'VERDICT: this head is NOT CLEARED — its runs disagree about which\n'
            printf 'tree they tested.\n'
            # THE SIXTH UNIVERSAL-CLAIM SITE (your-org/nexus-code#884).
            # This arm used to test `unexecuted` PRIVATELY — qualified for one
            # member of the excluded set and not the other, which is #884's
            # defect verbatim, in the one arm #884's fix could not see. It is a
            # MERGE SEAM, not an oversight: `8551eea` (the #884 fix) converted
            # every site that existed on its base, and `41c9bf1` (#878) added
            # this arm from a base predating it. `git merge-base --is-ancestor`
            # is rc 1 in BOTH directions between them; git merged both cleanly
            # and kept the old idiom. Same geometry as T6d's "THIRD MERGE-ORDER
            # SEAM ON THIS BRANCH", one arm over.
            #
            # It asks the SAME helper as the `stale` sibling sixty lines below,
            # so membership is decided in ONE place and a member added later is
            # qualified into this arm by construction. The enrolment that keeps
            # a SEVENTH site from arriving the same way is the population lint
            # in test-ci-head-attempts.sh — every universal-claim emit in this
            # file must sit within 8 lines of an `_excl_any`.
            if _excl_any; then
                printf 'Every run at this head that %s is a first-pass success (%s\n' \
                    "$(_excl_clause)" "$(_excl_count_phrase)"
                printf '— see below), AND they do not agree on a base: %s.\n' "$_MRB_DETAIL"
            else
                printf 'Every run at this head is a first-pass success, AND they do not agree\n'
                printf 'on a base: %s.\n' "$_MRB_DETAIL"
            fi
            printf 'This is NOT a claim that the base moved — one of those bases may be\n'
            printf 'the live tip. It is a claim that the head carries more than one answer,\n'
            printf 'and that picking among them is not something this verb may do silently.\n'
            printf 'WHY IT HAPPENS: a `success` conclusion does not identify the run that\n'
            printf 'supplied the VERDICT. `ci-signal` and `conflict-markers` are cheap, fire\n'
            printf 'unconditionally and DO print the checkout line, so a later round whose\n'
            printf '`tests` were SKIPPED can be the freshest thing at this head. Reading it\n'
            printf 'would report the newest base — the most `current`-looking answer\n'
            printf 'available (your-org/nexus-code#878, #882).\n'
            printf 'REMEDY: rebase (or push) so ONE round exists against ONE base, then\n'
            printf 're-run this verb. Re-running CI at the SAME head does not fix it.\n'
            # B1 BUNDLE SEAM. This arm is new in #878/#882 (your-org/nexus-code#903)
            # and called `_unexecuted_note`, which #955 DELETED when it made
            # causality the CALLER's to state (#885). The two PRs never saw each
            # other, git merged both cleanly, and the result called a function that
            # no longer exists. Caught by #955's own T6f.
            #
            # `independent`, matching the `stale` sibling below and the contract
            # above, which names stale-ref as independent: this verdict is driven by
            # SUCCESSFUL runs disagreeing about their base, a different cause from a
            # run that executed nothing.
            _excluded_note independent
        else
            # A withholding state the library grew and this verb has no sentence
            # for. Refusing is the honest answer: a clearance printed beside a
            # verdict nobody wrote prose for is a clearance nobody checked.
            _mrb_exit=2
            printf 'REFUSING: the merge-ref base check returned `%s`, a state this verb\n' "$_MRB_STATE"
            printf 'has no sentence for and therefore cannot report honestly. It withholds\n'
            printf 'the clearance rather than printing one beside a verdict it cannot\n'
            printf 'explain. DETAIL: %s.\n' "$_MRB_DETAIL"
            printf 'This is a defect in this verb, not in your branch: the library grew a\n'
            printf 'state and this arm was not extended. File it.\n'
            # `unknown`, NOT `independent`. This arm cannot say what drove the
            # verdict — that is the whole reason it is refusing — so claiming the
            # excluded runs did not is precisely the over-claim #885 removed.
            _excluded_note unknown
        fi
        exit "$_mrb_exit"
    fi
    if [[ "$_MRB_STATE" == stale ]]; then
        printf 'VERDICT: this head is NOT CLEARED — the green describes a tree that\n'
        printf 'would not land.\n'
        # THE THIRD REBASE SEAM, and the same one twice over (#846 x #823).
        # This arm arrived from #823 and landed INSIDE the clearance `else`,
        # ABOVE every #846 statement in it — the identical geometry to #868's
        # rc-8 arm landing above the #846 arms one level out. Its opening
        # sentence is QUANTIFIED OVER EVERY RUN AT THE HEAD, and it was flatly
        # false whenever one of them concluded `failure` having executed
        # nothing: a FALSE ASSERTION, the rc-6 shape, not the rc-8 omission.
        #
        # It also CONTRADICTED ITS OWN OUTPUT. The row table printed directly
        # above says `NOT-STARTED ... concluded failure having executed ZERO
        # steps`; this said every run is a first-pass success. Measured, not
        # reasoned: fixture = clean gating set (audit rc 0), one non-gating run
        # still pending, one non-gating `failure` with `steps: []`, merge ref
        # stale. T6d drives exactly that and T6e is its vacuity control.
        #
        # Reachable by the same argument the `else` below already records:
        # audit rc 0 keeps arms 3-5 shut, `pending_n > 0` keeps the `unexecuted`
        # arm shut, and what is left falls here.
        if _excl_any; then
            printf 'Every run at this head that %s is a first-pass success (%s\n' \
                "$(_excl_clause)" "$(_excl_count_phrase)"
            printf '— see below), AND the merge ref they were computed\n'
            printf 'against is stale: %s.\n' "$_MRB_DETAIL"
        else
            printf 'Every run at this head is a first-pass success, AND the merge ref they\n'
            printf 'were computed against is stale: %s.\n' "$_MRB_DETAIL"
        fi
        printf 'A `pull_request` run tests `refs/pull/%s/merge`, resolved to a sha when\n' "$PR_NUM"
        printf 'the run was created and pinned there, so its base is as old as the last\n'
        printf 'time that ref was recomputed — at or before the run, never after.\n'
        printf 'The base has moved since, so nothing here has tested the merge result\n'
        printf 'you are about to create. This is what your-org/nexus-code#823 merged on,\n'
        printf 'and the enumeration that cleared it was correct about every other thing\n'
        printf 'it checked.\n'
        printf 'REMEDY: rebase (or push) so a new run is computed against the current\n'
        printf 'base, then re-run this verb. Re-running CI at the SAME head does not\n'
        printf 'fix it — `rerun-failed-jobs` replays the merge ref the original run\n'
        printf 'pinned, and a NEW run only picks up a fresher base if the ref has been\n'
        printf 'recomputed since, which happens on DEMAND and not on a timer.\n'
        # Like every sibling arm. This one needs it MORE than the others,
        # because it is the only arm that leaves by `exit` rather than by
        # falling to the bottom of the chain — so it is the one arm where a
        # disclosure added at the end of the function can never reach it.
        _excluded_note independent
        exit 9
    fi
    # Reachable with `unexecuted > 0`: audit rc 0 (the GATING set is clean) with
    # a non-gating run still pending routes here, and the sentence below is
    # quantified over COMPLETED runs — which includes the aborted one.
    if _excl_any; then
        printf 'VERDICT: every completed run at this head that %s is a FIRST-PASS\n' "$(_excl_clause)"
        printf 'success (%s — see below).\n' "$(_excl_count_phrase)"
    else
        printf 'VERDICT: every completed run at this head is a FIRST-PASS success.\n'
    fi
    # The coverage boundary is declared on the axis this verb varies on —
    # whether expectations were checked — and it is stated HERE, at the point
    # a reader forms the belief, rather than in a docstring they will not open.
    if [[ "$AUDIT_RAN" == yes ]]; then
        printf 'Scope: the expected-band audit ALSO ran and is clean, so this covers\n'
        printf 'both questions — what ran is honest, and everything that should have\n'
        printf 'run did AND CONCLUDED. This head is cleared.\n'
        if (( pending_n > 0 )); then
            # The audit's quantifier is `gating`, and it came back clean, so
            # the clearance stands. But runs exist at this head that have not
            # concluded and are NOT gating bands (a workflow the paths filter
            # excludes, or ci-signal itself, which the audit skips as its own
            # self-integrity subject). Naming them is the difference between a
            # bounded claim and one the reader silently over-reads: the
            # clearance is about what GATES this change, and something at this
            # head is still moving.
            printf 'NOTE: %d run(s) at this head have still not concluded (%s).\n' \
                   "$pending_n" "$pending_names"
            printf 'The audit does not count them as gating this change, so they do not\n'
            printf 'withhold the clearance above — but the head is not yet quiet, and a\n'
            printf 'required check outside the gating set (ci-signal audits every\n'
            printf 'workflow but itself) would be among these.\n'
        fi
    else
        printf 'Scope: this is a claim about the runs that EXIST — and ONLY that.\n'
        printf 'The expected-band audit did NOT run (%s),\n' "${AUDIT_SKIP:-not requested}"
        printf 'so a workflow that should have gated this change and never fired\n'
        printf 'would be INVISIBLE above. Re-run with a PR number to close that gap.\n'
    fi
    # The base question, answered out loud in EVERY direction and on BOTH
    # arms above — a verified base is a FINDING and must be stated, or a
    # reader cannot tell it from a check that never ran. That conflation is
    # this repo's dominant defect class and this verb's own subject, so the
    # sentence is unconditional on the cleared path rather than living inside
    # whichever branch happened to be edited last.
    #
    # AND IT CARRIES ITS OWN EXPIRY (your-org/nexus-code#880). `#823`'s lesson is
    # that people read an enumeration as a DURABLE clearance; this check's own
    # output is susceptible to the same reading one level up. The verdict is
    # point-in-time — true as of the ref read a second ago — and nothing
    # re-checks it between here and the merge. So the base sha is printed IN
    # FULL rather than described, because a reader who must REMEMBER a condition
    # will not, and a reader who can COMPARE one will.
    #
    # MEASURED, so this is a stated fact and not a caution. Ground truth is the
    # base each run actually checked out versus the FIRST PARENT of the merge
    # commit that landed. Over every merge into `dev` in
    # `[2026-08-10T00:47:22Z, 2026-08-14T17:18:41Z]` — the merge that introduced
    # this check to the last merge before CI failed repo-wide — measured
    # 2026-08-14T18:53:54Z against `dev` e256d4a9865: 5 OF 17 landed on a base
    # their green never tested (`#870`, `#871`, `#890`, `#869`, `#899`).
    # Worked example: `#870` ran its suite against `a74805b5` at 01:44:41Z;
    # `#854` merged at 02:31:41Z, moving `dev` to `4ed5aa1e`; `#870` merged onto
    # `4ed5aa1e` at 02:36:41Z. Five minutes, a CLEAN merge, no conflict and no
    # red — so nothing except this sentence would have told anybody. The
    # shortest window measured was FOUR SECONDS (`#899` behind `#872`).
    #
    # (Benign in the event: the tree `#870` created was tested by `#842`'s runs,
    # CREATED 2026-08-10T02:38:25Z — one minute forty-four seconds later. This
    # clause has now been wrong twice, both times by reading `#842`'s MERGE date
    # (2026-08-14) as the date its runs ran: first as "four days later", then
    # "corrected" to the merge date itself, which is the same wrong fact
    # re-expressed. The sentence asserts WHEN THE TREE WAS TESTED, and a run's
    # `created_at` is what answers that — its PR's `merged_at` answers a
    # different question. Adjusting the number twice without asking which field
    # the claim rests on is how a wrong fact survives two corrections.
    # That the cover was ~2 minutes rather than 4 days makes it luckier, not
    # safer: nothing arranged it.)
    #
    # It does not BLOCK, and that is deliberate. A gate that fires on every
    # clearance gets disabled by whoever is under time pressure, which removes
    # the gate entirely. This states a scope; `ng pr merge --base-sha <sha>` is
    # the opt-in enforcement for a caller who wants the window closed.
    case "$_MRB_STATE" in
        current) printf 'Merge-ref base: VERIFIED — %s.\n' "$_MRB_DETAIL"
                 printf 'EXPIRY: that verdict is point-in-time. It holds ONLY while %s'\''s tip is\n' "$_MRB_BASE_REF"
                 printf '%s, and nothing re-checks it between here and\n' "$_MRB_BASE_SHA"
                 printf 'your merge. A base advance that merges CLEANLY produces no conflict and\n'
                 printf 'no red, so nothing else will warn you (#880 — measured on `#870`, which\n'
                 printf 'landed on a base its green never tested, 5 minutes after dev moved).\n'
                 printf 'RE-CHECK immediately before merging, or pin it:\n'
                 printf '  git fetch -q origin %s && git rev-parse origin/%s   # must equal the sha above\n' \
                        "$_MRB_BASE_REF" "$_MRB_BASE_REF"
                 printf '  ng pr merge <n> --sha <verified-head> --base-sha %s\n' "$_MRB_BASE_SHA" ;;
        n/a)     printf 'Merge-ref base: NOT APPLICABLE — %s.\n' "$_MRB_DETAIL" ;;
        *)       printf 'Merge-ref base: NOT CHECKED — %s.\n' "$_MRB_DETAIL"
                 printf 'That is `not looked at`, NOT `looked at and current`. The runs above\n'
                 printf 'may have been computed against a base that has since moved (#823).\n' ;;
    esac
    _excluded_note independent
fi
exit "$rc"
