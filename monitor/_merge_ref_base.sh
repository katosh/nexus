#!/usr/bin/env bash
# _merge_ref_base.sh — "was this head's green computed against the CURRENT
# base?" (your-org/nexus-code#823).
#
# A SOURCED library, not an inline function, for one reason: the answer is a
# verdict on a merge and it deserves a test that does not have to stand up the
# whole `ng ci-attempts` verb to reach it. `monitor/watcher/test-merge-ref-base.sh`
# drives `_merge_ref_base` directly against a stubbed `gh`, including the STALE
# arm.
#
# THAT ARM CARRIED A HEDGE — "which no live PR can be made to demonstrate on
# demand" — AND THE HEDGE IS NOW DISCHARGED BY MEASUREMENT (#859). Recorded as a
# discharge rather than a correction, because the hedge was RIGHT: nobody had
# measured it, and naming the limit of what was known was the honest thing to
# write. It is being retired by evidence, which is the only thing that should
# retire one. Hedge in the same place next time.
#
# What was measured, and which is which:
#
#   * `#670` is an OBSERVED STALE CASE. Its merge ref tested a base that `dev`
#     had long left behind — the same head's later round moved to a newer base
#     (runs 30785047964 -> 31133530169). So the stale arm describes something
#     that demonstrably happens to live PRs, not only to a stub.
#   * THE REFRESH IS DEMAND-TRIGGERED, NOT TIME-BASED, which is what makes the
#     arm reproducible ON DEMAND — in BOTH directions. A treatment/control pair
#     on two open PRs whose refs were 26 and 36 hours stale across many `dev`
#     advances: leave a PR unqueried and it STAYS stale (control, unmoved);
#     issue one `GET /repos/{owner}/{repo}/pulls/{n}` and it refreshes to `dev`'s
#     tip within ~2 minutes (treatment). Elapsed time alone refreshes nothing.
#
# The STUB STAYS, and the reason is unchanged by any of this: a test asserting a
# verdict wants a deterministic fixture, not a live PR whose merge ref a passing
# reader can move by opening the page. What is no longer true is the claim of
# IMPOSSIBILITY — so read this as "the stub is the right fixture", never as "a
# live PR could not show you".
#
# Contract:
#   _merge_ref_base            reads $REPO, $PR_NUM, $SHA; sets $_MRB_STATE and
#                              $_MRB_DETAIL. Cached: safe to call repeatedly.
#   _MRB_STATE                 current | stale | unread | n/a
#   _MRB_DETAIL                one clause naming what was read and from where
#
# Sourced by test suites and by a hot verb, so it imposes NO shell options on
# its caller (your-org/nexus-code#721's leak class, gated by
# watcher/test-ambient-shell-option-scope.sh P2). It sets none.

# ---- the merge-ref base (your-org/nexus-code#823) --------------------------
#
# THE GAP THIS CLOSES, stated as the recipe it belongs in rather than as prose.
# This verb — and every hand-rolled enumeration in this repo — asks WHICH runs
# exist, WHAT they concluded, and on WHICH attempt. None of them asks AGAINST
# WHAT BASE. A `pull_request` run does not test your branch: it tests
# `refs/pull/N/merge`, a merge commit GitHub maintains for the PR — resolved to
# a sha when the run is created and pinned there (the runner's fetch refspec is
# by SHA, not by ref name). If the base branch moves afterwards, every green
# above stays green while describing a tree that no longer exists. `#823` merged
# on precisely that, and the enumeration that cleared it was correct about
# everything it checked.
#
# THE REF IS DEMAND-TRIGGERED, NOT RUN-TRIGGERED (your-org/nexus-code#859), and
# that distinction is why this check reads a log line instead of reasoning about
# timing. GitHub recomputes `refs/pull/N/merge` when something ASKS for the PR's
# mergeability — a single-PR `GET /repos/{owner}/{repo}/pulls/{n}`, a PR page
# view, a lifecycle event. Creating a workflow run is NOT such an event. A run
# therefore uses whatever the ref HELD at that moment, last refreshed by some
# earlier demand, so the tested base is AT OR BEFORE the run's creation — and
# can be substantially older. Measured on this repo under a treatment/control
# pair: two open PRs' merge refs sat stale for 26 AND 36 HOURS across many
# `dev` advances, and the one that received a single mergeability request
# refreshed to the live tip within ~2 minutes while the control did not move.
#
# So do not read "computed at run creation" into this, and do not let a RECENT
# RUN imply a RECENT BASE — it does not. Nothing in a run's own metadata says
# how old its base is. Only the checkout line says what was actually tested.
#
# THE SOURCE IS THE RUNNER'S OWN LOG LINE, and that is deliberate. The runner
# prints `HEAD is now at <merge> Merge <head> into <base>` when it checks the
# merge ref out, which is a RECORD OF WHAT WAS TESTED.
#
# IT IS ALSO WHY THE LOGIC BELOW SURVIVED THE MECHANISM CHANGING UNDER IT. This
# check compares the base the runner ACTUALLY CHECKED OUT against the LIVE TIP
# read at check time. It never asks WHEN the ref was computed, so it does not
# depend on the recomputation rule at all: it was correct under "computed at run
# creation", it is correct under demand-triggering, and it stays correct under
# whatever supersedes that. Only the paragraph above was ever wrong — and a
# correct mechanism carrying a stale rationale is exactly how the next reader
# re-derives the wrong rule, which is the failure this file exists to close.
# Keep the two separable: fix the explanation here, leave the comparison alone.
#
# Every other available signal is a reconstruction:
#
#   * reading `refs/pull/N/merge` now answers a DIFFERENT question — what the
#     ref holds today, which is neither what the run tested nor reliably the
#     current base, since a plain `git/ref` read does not itself trigger a
#     recompute and can hand back a ref hours stale — and it answers it
#     confidently;
#   * comparing the run's `created_at` against the base tip's commit DATE is a
#     heuristic, because a commit can be authored long before it is pushed —
#     it would report a stale run as fresh, which is the unsafe direction.
#
# `gh api` for the log, never `gh run view --log`: the REST payload is
# byte-identical across gh clients, while `gh run view --job … --log` returns
# ZERO lines at rc 0 on the 1.13.0 client installed on this host (#755).
#
# FAIL-CLOSED IN THE HONEST DIRECTION. Three outcomes, and `unread` is NOT
# folded into either of the others: GitHub expires logs, so "could not read it"
# is an ordinary state and blocking on it would break this verb on every older
# head. It is reported as NOT CHECKED beside the verdict — the same treatment
# the audit gives absent attempt provenance — because a base nobody verified
# must not read as a base that was verified and found current.
_MRB_STATE=""      # current | stale | unread | n/a
_MRB_DETAIL=""
_merge_ref_base() {
    [[ -n "$_MRB_STATE" ]] && return 0
    if [[ -z "$PR_NUM" ]]; then
        _MRB_STATE="n/a"
        _MRB_DETAIL="no PR context — a bare sha has no merge ref"
        return 0
    fi
    local base_sha run_id job_id line tested
    # THE LIVE TIP OF THE BASE BRANCH, read from the ref — NOT `.base.sha`.
    #
    # This is the one-line difference between a check that fires on `#823` and
    # one that cannot fire at all, and getting it wrong the first time is the
    # whole reason this comment is long. `.base.sha` is a SNAPSHOT: GitHub
    # records it with the pull-request object and does not advance it as the
    # base branch moves. Measured against `#823` itself, the incident this check
    # is named after: with `.base.sha` it returns `current`; with the ref below
    # it fires.
    #
    # WHY, STATED CORRECTLY — the earlier grounds here were wrong in the
    # direction that UNDERSTATES the hazard, so they are replaced rather than
    # softened (your-org/nexus-code#837 logic review). This used to claim the
    # merge ref "is derived from that same snapshot, so BOTH SIDES OF THE
    # COMPARISON MOVE TOGETHER". They do NOT move together. `.base.sha` and
    # `refs/pull/N/merge` are INDEPENDENT freezes updated by overlapping but
    # distinct triggers, and the divergence is measured:
    #
    #   PR #670 — `.base.sha` f0c9510, merge-ref base f0c9510          AGREE
    #   PR #811 — `.base.sha` 1973ffc, merge-ref base a91f82b          DISAGREE
    #             (the merge ref refreshed 2026-08-09T20:11:54Z on a single
    #              `GET /pulls/811`; `.base.sha` did not advance)
    #
    # So `.base.sha` is not merely INSENSITIVE to base movement — it is
    # UNCORRELATED with the question, and it errs in BOTH directions:
    #
    #   * #670 shape — the two coincide, so it reports `current` while the
    #     tested base is far behind. FALSE-CURRENT: the unsafe direction, and
    #     precisely the `#823` failure this check exists to catch.
    #   * #811 shape — merge ref refreshed, `.base.sha` frozen, so it would
    #     report `stale` when the tested base IS the live tip. False-stale;
    #     safe direction, still wrong.
    #
    # The old grounds implied a comparison that merely cannot FIRE. The real
    # hazard is a comparison that can fire WRONGLY, either way. That is a
    # stronger case for the ref read below, not a weaker one — and it is why
    # the fallback further down is a refusal rather than a downgrade.
    #
    # `git/ref/heads/<branch>` is the branch pointer as it stands right now,
    # which is what "would this merge into the tree that exists" actually asks.
    local base_ref
    base_ref=$(gh api "/repos/${REPO}/pulls/${PR_NUM}" --jq '.base.ref // ""' 2>/dev/null) || base_ref=""
    if [[ -n "$base_ref" ]]; then
        base_sha=$(gh api "/repos/${REPO}/git/ref/heads/${base_ref}" --jq '.object.sha // ""' 2>/dev/null) || base_sha=""
    fi
    if [[ -z "$base_sha" ]]; then
        # NOT a fallback to `.base.sha`. A comparison against the snapshot is
        # not a weaker version of this check, it is a check that cannot fail —
        # and reporting its result would be a verdict over something never
        # measured. `unread` is the honest answer when the live tip is
        # unreadable.
        _MRB_STATE="unread"
        _MRB_DETAIL="could not read the LIVE tip of base branch ${base_ref:-<unknown>} (refusing to fall back to the PR's frozen .base.sha, which cannot detect base movement)"
        return 0
    fi
    # SUCCESSFUL pull_request runs, not merely pull_request runs. Two reasons,
    # both measured on `#823`'s own head:
    #
    #   * its first pull_request run is `cc-harness` at `skipped` — a #628 edit
    #     shell, which checks nothing out and whose jobs carry no checkout line.
    #     Reading it reports `unread` on a head whose merge ref IS readable.
    #   * a head can carry several ROUNDS of runs fired at different times, so
    #     their merge refs need not agree. The one worth reading is the one
    #     that SUPPLIED THE VERDICT, and that run concluded `success`.
    #
    # Several runs are scanned rather than one, because NOT EVERY successful
    # run checks out a merge ref: measured on `#823`, three of its successful
    # runs check out `refs/remotes/origin/dev` directly and print no merge
    # line at all, while the round that actually ran the tests prints it.
    # Reading only the first would report `unread` on the very head this check
    # exists for.
    #
    # LIMIT, since it follows from the same observation: if two runs at one
    # head tested DIFFERENT bases, this reports the first one it finds and
    # names the run it came from. It does not detect disagreement between
    # rounds. That is a narrower gap than the one being closed, and naming it
    # is cheaper than a guess about how common it is.
    local run_ids
    run_ids=$(gh api "/repos/${REPO}/actions/runs?head_sha=${SHA}&per_page=100" \
                --jq '[.workflow_runs[] | select(.event=="pull_request" and .conclusion=="success") | .id] | .[0:8] | .[]' 2>/dev/null) || run_ids=""
    if [[ -z "$run_ids" ]]; then
        _MRB_STATE="unread"
        _MRB_DETAIL="no successful pull_request run at this head to read a merge ref from"
        return 0
    fi
    # SUCCESSFUL jobs only, and SEVERAL of them — not `.jobs[0]`. A run's first
    # job is routinely one that never checked anything out (a `skipped` matrix
    # cell, a gate job), and its log carries no checkout line at all. Reading
    # only that job reports `unread` on a head whose merge ref is perfectly
    # readable two jobs later — an "I looked in the wrong place" dressed as "it
    # cannot be known", which is the silent-zero family this file exists to
    # refuse. Measured on `#823`: `.jobs[0]` yields nothing; the successful
    # jobs yield the line.
    local job_ids from_run=""
    line=""
    while IFS= read -r run_id; do
        [[ -n "$run_id" ]] || continue
        job_ids=$(gh api "/repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100" \
                    --jq '[.jobs[] | select(.conclusion=="success") | .id] | .[0:6] | .[]' 2>/dev/null) || job_ids=""
        [[ -n "$job_ids" ]] || continue
        while IFS= read -r job_id; do
            [[ -n "$job_id" ]] || continue
            # `grep` WITHOUT `-m1`, then `sed -n '1p'`. The `-m1` form is an
            # EARLY-EXIT READER: it closes the pipe on its first match, which
            # SIGPIPEs `gh`, and this library is sourced into a caller that
            # runs `set -o pipefail` — the #622/#682 shape. It happens to be
            # harmless here because the assignment's status is discarded, but
            # "harmless because nothing currently reads the status" is a
            # property of the CALLER, not of this line, and the next edit
            # changes callers. `grep` without `-m` drains its input and cannot
            # close the pipe early; `sed -n '1p'` drains too.
            #
            # Do not "optimise" this back: `early-exit-readers.sh` could not
            # have told you. Its pipefail axis resolves source edges by literal
            # basename, and until the caller's `. "$_here/_merge_ref_base.sh"`
            # was spelled out literally this file sat OFF the axis entirely —
            # so the guard's silence meant "could not see it", not "clean".
            line=$(gh api "/repos/${REPO}/actions/jobs/${job_id}/logs" 2>/dev/null \
                   | grep -oE 'Merge [0-9a-f]{40} into [0-9a-f]{40}' \
                   | sed -n '1p' || true)
            [[ -n "$line" ]] && { from_run="$run_id"; break; }
        done <<<"$job_ids"
        [[ -n "$line" ]] && break
    done <<<"$run_ids"
    if [[ -z "$line" ]]; then
        _MRB_STATE="unread"
        _MRB_DETAIL="no successful job of any successful run at this head carries a \`Merge <head> into <base>\` line (logs expired, or a shape this parse does not know)"
        return 0
    fi
    tested=${line##* }
    if [[ "$tested" == "$base_sha" ]]; then
        _MRB_STATE="current"
        _MRB_DETAIL="run ${from_run} tested against ${tested:0:12}, which EQUALS the live tip of ${base_ref} read just now"
    else
        _MRB_STATE="stale"
        _MRB_DETAIL="run ${from_run} tested against ${tested:0:12}; the live tip of ${base_ref} is now ${base_sha:0:12}"
    fi
}

