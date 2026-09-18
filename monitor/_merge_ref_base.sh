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
#   _MRB_STATE                 current | stale | divergent | unread | n/a
#   _MRB_DETAIL                one clause naming what was read and from where
#   _MRB_BASE_REF              the base BRANCH NAME the comparison used
#   _MRB_BASE_SHA              the LIVE TIP read at check time — the verdict's
#                              own expiry token (your-org/nexus-code#880)
#   _MRB_TESTED                the base the runs actually checked out, when they
#                              agreed on one; empty otherwise
#   _MRB_RUNS_READ             N: runs that yielded a readable checkout line
#   _MRB_RUNS_TOTAL            M: successful pull_request runs at the head. Every
#                              count this file reports is N-of-M — a bare count
#                              is a completeness claim it cannot support, which
#                              is the defect the first cut shipped (#882 S1)
#   _mrb_clearance_disposition <state> -> permit | withhold. An ALLOWLIST with a
#                              default-DENY arm: the caller must ASK rather than
#                              enumerate the blocking states itself.
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
# AND THE DEMAND MODEL HAS ONE RECORDED COUNTER-OBSERVATION — READ IT BEFORE
# LEANING ON "ONE GET REFRESHES IT" (your-org/nexus-code#923). On `#903`, a
# `GET /repos/your-org/nexus-code/pulls/903` moved `mergeable` from `null` to
# `true` with `mergeable_state: clean` — so a RECOMPUTE demonstrably occurred —
# while `refs/pull/903/merge` kept merging base `10ac0c5d14c3` across SIX reads
# over 150 s, with `dev` at `48515bc69b03`. Repeated GETs during that window did
# not move it. So the demand refreshed the ANSWER and not the BASE, and those
# are separable in a way the paragraph above does not distinguish.
#
# WHAT THAT IS AND IS NOT. It is ONE PR on ONE occasion, and it is NOT a
# refutation: `#859` earned its claim with a treatment/control pair across two
# PRs and many base advances, and nothing here matches that standard. The open
# questions it leaves — does the ref rebase only when `.base.sha` advances
# rather than when the base BRANCH does; is there a cooldown; is
# `mergeable: null -> true` a DIFFERENT computation from the ref rebase, with
# only the former demand-triggered — are unanswered, and answering them was
# scope drift for the window that saw it.
#
# ── TWO OF THOSE THREE ARE NOW ANSWERED (your-org/nexus-code#923) ─────────
#
# Measured 2026-09-02 18:36-18:44Z against this repo, six open PRs, `dev` at
# `0b82ffb2`. Read-only; every number is three `gh api` calls.
#
# (a) "does the ref rebase only when `.base.sha` advances?"  **NO — refuted.**
#     PR `#670` has had NOTHING pushed to it since 2026-08-07T00:07:49Z and its
#     `.base.sha` is still `f0c9510`, the value recorded four paragraphs below
#     as of `ffb899a9` (2026-08-09). Its merge-ref first parent TODAY is
#     `4b7320f0` — a different commit, and `f0c9510` is an ANCESTOR of it. The
#     ref rebased while `.base.sha` stayed frozen, so the two are not gated on
#     each other. This half needs no assumption about who issued a demand in
#     the interval: both values are observed, and neither depends on that.
#
# (c) "is `mergeable: null -> true` a DIFFERENT computation from the rebase?"
#     **YES — #923's observation REPRODUCES, at n=2 rather than n=1.** A single
#     `GET /pulls/{n}` on `#1004` and `#1009` moved `mergeable` off `null`
#     (`false/dirty` and `true/unstable` respectively), so a recompute
#     demonstrably occurred in both. Their merge-ref first parents were
#     IDENTICAL at +2 s, +3 m36 s, +5 m07 s and +6 m59 s — well past `#859`'s
#     ~2-minute refresh window. Three untouched controls (`#670`, `#1149`,
#     `#1330`) did not move either. `#1009` is the informative arm:
#     `mergeable: true` means a rebase was POSSIBLE, so the non-refresh is not
#     explained by a conflict — which `#1004` (`dirty`) alone could not rule
#     out, and which is a confound neither `#859` nor `#923` names.
#
# (b) the COOLDOWN question is still open. Nothing here bounds how long a
#     recently-refreshed ref ignores further demands, and establishing it needs
#     base advances this window cannot force.
#
# WHAT THIS DOES NOT ESTABLISH, said plainly because the gap is the interesting
# part: **what DOES trigger the rebase.** `#670`'s ref moved at some point in a
# 24-day interval, and this board has many agents that read PRs, so "no demand
# occurred" is NOT a claim that can be made — only "no PUSH occurred and
# `.base.sha` did not advance". So the honest summary is that the two
# quantities are separable and neither reliably triggers the other, which is
# strictly weaker than a mechanism and strictly stronger than one occasion.
#
# NOTHING BELOW CHANGES. This function never reasons about when the ref was
# computed — it compares the base the runner ACTUALLY CHECKED OUT against the
# live tip read now — which is why it survived `#823 -> #859` and survives this.
#
# THE DIRECTION OF THE ERROR IS WHY THIS IS A NOTE AND NOT AN ALARM. A ref that
# lags MORE than the model predicts makes `stale` MORE likely, which is the safe
# direction for this check. What would be unsafe is a future change that starts
# RELYING on "one GET refreshes it" — that is the thing nobody has reproduced.
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
# `gh api` for the log, never `gh run view --log` — for TWO reasons, and the
# second holds on a host with ONE gh client, which is why the rule cannot rest
# on the first alone (your-org/nexus-code#1408):
#   1. CLIENT TRUNCATION (#755): the REST payload is byte-identical across gh
#      clients, while `gh run view --job … --log` returns ZERO lines at rc 0
#      on the 1.13.0 client installed on this host.
#   2. ATTEMPT CORRECTNESS (#1408): `gh run view --job <id> --log` IGNORES the
#      job id and serves the run's LATEST attempt. Measured: two jobs of one
#      run, attempt 1 `conclusion=failure` and attempt 2 `success`, returned
#      143,369 B BYTE-IDENTICAL logs reading `397 tests; 0 failed` for both,
#      while `gh api repos/O/R/actions/jobs/<id>/logs` returned distinct
#      payloads (80,606 B `1 failed` / 79,363 B `0 failed`) matching each
#      job's own conclusion. A `log_bytes >= 20 KB` floor screens only the
#      EMPTY tail of reason 1 and is structurally blind to this: the wrong
#      log is large, well-formed and internally consistent. Invisible on
#      single-attempt runs, which is why it survives until a re-run — the
#      moment the attempts disagree and the answer matters.
# Corollary: a log byte count is METHOD-DEPENDENT (`gh run view` prefixes every
# line with job and step names, ~80% larger); publish the method beside it.
#
# FAIL-CLOSED IN THE HONEST DIRECTION. Three outcomes, and `unread` is NOT
# folded into either of the others: GitHub expires logs, so "could not read it"
# is an ordinary state and blocking on it would break this verb on every older
# head. It is reported as NOT CHECKED beside the verdict — the same treatment
# the audit gives absent attempt provenance — because a base nobody verified
# must not read as a base that was verified and found current.
#
# WHICH STATES MAY ACCOMPANY A CLEARANCE — AN ALLOWLIST, DEFAULT-DENY
# (your-org/nexus-code#878, #882). The caller used to spell the gate as
# `[[ "$_MRB_STATE" == stale ]]`, i.e. a DENYLIST with a permissive default arm.
# That shape passes whatever its author did not think of, and this file is about
# to add a state — so a new fail-closed verdict would have fallen straight into
# the permissive arm and CLEARED the head while printing "NOT CHECKED". The same
# structural lesson `bk_pane_kill_authorized` already carries: enumerate what may
# proceed, deny the rest, and put the enumeration next to the states rather than
# in the caller where it drifts.
#
# `unread` PERMITS, deliberately, and that is not an oversight: GitHub expires
# logs, so blocking on "could not read it" would break this verb on every older
# head — the gate-that-always-fires failure, which ends with the gate disabled.
# It is reported as NOT CHECKED beside the verdict instead.
_mrb_clearance_disposition() {
    case "${1:-}" in
        current|n/a|unread) printf 'permit\n' ;;
        *)                  printf 'withhold\n' ;;
    esac
}

_MRB_STATE=""      # current | stale | divergent | unread | n/a
_MRB_DETAIL=""
_MRB_BASE_REF=""
_MRB_BASE_SHA=""
_MRB_TESTED=""
_MRB_RUNS_READ=""   # N — runs that yielded a readable checkout line
_MRB_RUNS_TOTAL=""  # M — successful pull_request runs at the head. N/M, never a bare N (#882 S1)
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
    # BOTH ROWS ARE DATED, AND THE FIRST ONE HAS SINCE FLIPPED (#923). They
    # were taken at `ffb899a9`, 2026-08-09. Re-measured 2026-09-02 18:36Z,
    # `#670` reads `.base.sha` f0c9510 (unchanged) against merge-ref base
    # `4b7320f0` — it is now the DISAGREE shape, on a PR with no push since
    # 2026-08-07. A worked example is a count, and a count is a property of a
    # tree AND A MOMENT: read these two rows as dated observations of the two
    # SHAPES, never as the current state of either PR.
    #
    # The shapes are what matters and both still occur. Re-measured across all
    # six open PRs at that moment: THREE agree (#1004, #1328, #1330) and THREE
    # disagree (#670, #1009, #1149) — and in every disagreeing case `.base.sha`
    # is an ANCESTOR of the merge-ref base, i.e. the SNAPSHOT lags the REF.
    # That direction was not previously recorded and it is the #670 shape's
    # own hazard restated: the field an implementer reaches for is behind the
    # one CI actually built against.
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
    # Published so a caller can COMPARE rather than REMEMBER (#880). A `current`
    # verdict is a point-in-time fact that expires the moment this sha stops
    # being the tip, and nothing re-checks it between the verdict and the merge.
    _MRB_BASE_REF="$base_ref"
    _MRB_BASE_SHA="$base_sha"
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
    # THE LIMIT THIS FILE USED TO NAME HERE IS NOW CLOSED, AND IT HAD TO BE
    # (your-org/nexus-code#878, #882). The text read: "if two runs at one head
    # tested DIFFERENT bases, this reports the first one it finds… a narrower gap
    # than the one being closed." Naming it was right; leaving it resolved in the
    # DEFAULT-UNSAFE direction was not, because three separately-measured facts
    # compose into a silent false `current` — the exact failure this file exists
    # to prevent:
    #
    #   1. `actions/runs?head_sha=` returns NEWEST-FIRST (verified live on the
    #      `#670` and `#823` heads). So "the first one it finds" is systematically
    #      the FRESHEST base — the most `current`-looking answer available.
    #   2. `conclusion=="success"` does NOT identify the run that supplied the
    #      verdict. `ci-signal` and `conflict-markers` are cheap, fire
    #      unconditionally, and DO print the merge checkout line.
    #   3. Later rounds routinely have `tests` SKIPPED while a cheap workflow
    #      succeeds — measured twice, `92b394b` (#827) and `5c3a2c7` (#830).
    #
    # So the check could read its base from a round whose test suite never ran,
    # and report `current` because that round happened to sit at the live tip.
    #
    # THE FIX IS TO STOP PICKING. Every selected run is read, not merely the
    # first that answers, and a DISAGREEMENT is its own fail-closed verdict
    # (`divergent`) rather than a silent preference for the freshest. This is
    # deliberately NOT an attempt to identify "the run that supplied the verdict"
    # — that is not determinable from a run's own metadata, which is how the gap
    # arose. Agreement makes the question moot; disagreement is reported, not
    # resolved.
    #
    # THE FIRST CUT OF THAT FIX CONTAINED THE DEFECT IT WAS FIXING, and the
    # correction is the reason there is no `.[0:8]` below any more. "Every
    # selected run" was still a NEWEST-FIRST WINDOW of eight, and on this very
    # PR's head that window measured as:
    #
    #   idx 0-7  ci-signal, conflict-markers, ci-signal, conflict-markers, …
    #   idx 8    tests (slow + integration)   <-- EXCLUDED BY THE CAP
    #   idx 9    tests                        <-- EXCLUDED BY THE CAP
    #
    # Ten successful `pull_request` runs; the cap admitted eight cheap ones and
    # BOTH runs that executed tests fell off the end. That is `#882` verbatim —
    # a base resolved from runs whose tests never ran — reproduced inside its own
    # fix, and reachable by nothing more exotic than editing the PR description
    # four times (each `edited` event adds a cheap round at the FRONT of a
    # newest-first list, pushing the test runs off the back).
    #
    # A FIXED-SIZE HEAD WINDOW CANNOT BE PART OF THIS ANSWER. Not "a bigger cap":
    # any cap is a silent exclusion rule whose victims are systematically the
    # OLDEST runs, and the oldest round is exactly where the tests live once
    # cheap rounds accumulate. Prioritising test-executing runs was considered
    # and rejected for the same reason it was rejected above — it still leaves
    # unread runs unverified, and an unread run is one that might disagree. The
    # population is read whole, or the shortfall is declared.
    #
    # COST, measured rather than asserted: one job log per run instead of one
    # per head. Job logs on this repo run 38-64 KB. A quiet head carries 4-5
    # successful `pull_request` runs (~200-300 KB); the worst head measured today,
    # after four PR-body edits, carried 10 (~500 KB). The API page bounds it at
    # 100, and `total_count` is checked below so that even that bound cannot
    # truncate silently. That is the price of a merge gate answering the question
    # it claims to.
    #
    # REJECTED CHEAPER FORM, recorded so it is not re-proposed: group runs by
    # `created_at` and read one per distinct timestamp, on the theory that one
    # webhook event yields one merge ref. Probably true, and still an INFERENCE
    # about a mechanism whose last two rules were both wrong (#823, #859). This
    # file reads the runner's own record instead. Keep it that way.
    # The `TOTALCOUNT` header is emitted by the SAME call, so knowing whether the
    # page truncated costs no extra request. It is parsed TOLERANTLY — a payload
    # without it is read as ids only — so a fixture written before this line
    # still means exactly what it meant.
    local run_ids runs_raw total_count=""
    runs_raw=$(gh api "/repos/${REPO}/actions/runs?head_sha=${SHA}&per_page=100" \
                --jq '"TOTALCOUNT \(.total_count)", (.workflow_runs[] | select(.event=="pull_request" and .conclusion=="success") | .id)' 2>/dev/null) || runs_raw=""
    total_count=$(printf '%s\n' "$runs_raw" | sed -n 's/^TOTALCOUNT //p' | sed -n '1p')
    run_ids=$(printf '%s\n' "$runs_raw" | grep -v '^TOTALCOUNT ' || true)
    run_ids=$(printf '%s\n' "$run_ids" | sed '/^$/d')
    # S1-ANCHOR: the run list is COMPLETE here — no window, no slice, no
    # "first N". This line is deliberately a named marker rather than an
    # incidental one, because `test-merge-ref-base.sh` case 13 mutates exactly
    # here to re-create the `.[0:8]` window that shipped in the first cut, and a
    # control anchored to whatever line happened to be adjacent is a control
    # that silently stops controlling. If you add a filter below this point,
    # case 13 will tell you what it costs.
    if [[ -z "$run_ids" ]]; then
        _MRB_STATE="unread"
        _MRB_DETAIL="no successful pull_request run at this head to read a merge ref from"
        return 0
    fi
    # `_rid` is declared LOCAL: this library is SOURCED into a long-lived caller,
    # so an undeclared loop variable is a global it silently plants in that
    # caller's namespace (the #721 leak class this file's header promises not to
    # be part of).
    local n_runs=0 _rid
    while IFS= read -r _rid; do [[ -n "$_rid" ]] && n_runs=$(( n_runs + 1 )); done <<<"$run_ids"
    # SUCCESSFUL jobs only, and SEVERAL of them — not `.jobs[0]`. A run's first
    # job is routinely one that never checked anything out (a `skipped` matrix
    # cell, a gate job), and its log carries no checkout line at all. Reading
    # only that job reports `unread` on a head whose merge ref is perfectly
    # readable two jobs later — an "I looked in the wrong place" dressed as "it
    # cannot be known", which is the silent-zero family this file exists to
    # refuse. Measured on `#823`: `.jobs[0]` yields nothing; the successful
    # jobs yield the line.
    local job_ids from_run="" first_tested="" witness="" n_read=0 n_bases=0 uniq_bases="" n_jobtrunc=0
    line=""
    while IFS= read -r run_id; do
        [[ -n "$run_id" ]] || continue
        # NO `.[0:6]` EITHER, for the same reason the run cap went (#882 S1). The
        # job cap could only ever LOSE a run's base, never corrupt it — but a lost
        # base is a run whose agreement was never established, and the whole
        # verdict is a claim about agreement. The scan still stops at the FIRST
        # job carrying a line, so the common case reads exactly one job log; the
        # cap only ever bit runs that carry no line at all, which are precisely
        # the ones worth being sure about.
        # THE JOBS PAGE IS BOUNDED TOO, and it gets the same TOTALCOUNT header
        # for the same reason (#882 S1 residual). A run with more than 100 jobs
        # returns a truncated list, and this scan would then report "no merge
        # line in this run" when the honest answer is "not in the 100 I saw".
        # It cannot produce a WRONG base — only a missing one — but a missing
        # base is a run whose agreement was never established, and the verdict
        # is a claim about agreement.
        local jobs_raw jt=""
        jobs_raw=$(gh api "/repos/${REPO}/actions/runs/${run_id}/jobs?per_page=100" \
                    --jq '"TOTALCOUNT \(.total_count)", (.jobs[] | select(.conclusion=="success") | .id)' 2>/dev/null) || jobs_raw=""
        jt=$(printf '%s\n' "$jobs_raw" | sed -n 's/^TOTALCOUNT //p' | sed -n '1p')
        job_ids=$(printf '%s\n' "$jobs_raw" | grep -v '^TOTALCOUNT ' || true)
        [[ -n "$job_ids" ]] || continue
        line=""
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
            [[ -n "$line" ]] && break
        done <<<"$job_ids"
        # NO `break` HERE — that `break` WAS the defect (#878, #882). The scan
        # continues to the next run so a disagreement can be SEEN; stopping at
        # the first readable line is what made newest-first ordering decide the
        # verdict.
        if [[ -z "$line" ]]; then
            # Only counts when the run gave us nothing: a run whose line we DID
            # find is fully accounted for however long its job list was.
            [[ "$jt" =~ ^[0-9]+$ ]] && (( jt > 100 )) && n_jobtrunc=$(( n_jobtrunc + 1 ))
            continue
        fi
        tested=${line##* }
        n_read=$(( n_read + 1 ))
        [[ -n "$from_run" ]] || { from_run="$run_id"; first_tested="$tested"; }
        if [[ " ${uniq_bases} " != *" ${tested} "* ]]; then
            uniq_bases="${uniq_bases}${uniq_bases:+ }${tested}"
            n_bases=$(( n_bases + 1 ))
            witness="${witness}${witness:+, }run ${run_id} tested ${tested:0:12}"
        fi
    done <<<"$run_ids"
    _MRB_RUNS_READ="$n_read"
    _MRB_RUNS_TOTAL="$n_runs"
    if (( n_read == 0 )); then
        _MRB_STATE="unread"
        _MRB_DETAIL="no successful job of any of the ${n_runs} successful run(s) at this head carries a \`Merge <head> into <base>\` line (logs expired, or a shape this parse does not know)"
        return 0
    fi
    # THE COUNT CARRIES ITS DENOMINATOR (your-org/nexus-code#882 S1). The first
    # cut printed "8 successful run(s) read" where 8 was the CAP, not the total —
    # a bare count reads as completeness, and it was making exactly the
    # completeness claim it could not support. `N of M` is the whole fix: a
    # reader can see 8 of 10 and know two runs went unverified, which no bare
    # count can express.
    local coverage="${n_read} of ${n_runs} successful run(s) read"
    local shortfall=""
    if (( n_read < n_runs )); then
        shortfall=" — the other $(( n_runs - n_read )) carry no readable \`Merge … into …\` line (logs expired, or they checked out no merge ref), so their base is NOT verified"
        (( n_jobtrunc > 0 )) && shortfall+="; ${n_jobtrunc} of those had MORE THAN 100 jobs, so the line may simply be outside the page this read could see"
    fi
    # DISAGREEMENT IS ITS OWN VERDICT, NOT A TIE TO BREAK. Reporting the newest
    # would report the freshest base, which is the most `current`-looking answer
    # and the one direction that must never be the default.
    # DISAGREEMENT FIRST, because it is a POSITIVE finding: it survives any
    # amount of missing coverage. Truncation and shortfall only ever weaken a
    # claim of agreement, never a demonstration of disagreement.
    if (( n_bases > 1 )); then
        _MRB_STATE="divergent"
        _MRB_DETAIL="the successful runs at this head DISAGREE about the base they tested (${witness}; ${coverage}) — refusing to pick one, because newest-first ordering would systematically report the FRESHEST base and a round whose \`tests\` were skipped can be the one sitting at the live tip (your-org/nexus-code#878, #882)"
        return 0
    fi
    # A PAGE THAT TRUNCATED IS A POPULATION NOBODY ENUMERATED, and "they all
    # agree" is a claim over a population. `total_count` counts every run at this
    # head; above the page size the id list is short by an unknown amount, so
    # agreement among what came back says nothing about what did not. `unread` is
    # the honest state — we did not check — and it is non-blocking, so this
    # cannot wedge a board on a head that merely ran a lot of workflows.
    # A NON-NUMERIC total_count IS "COULD NOT TELL", NOT "NO TRUNCATION".
    #
    # THE MECHANISM RECORDED HERE FIRST WAS WRONG, and it is corrected rather
    # than quietly replaced, because a wrong recorded mechanism is worse than
    # none: it stops the next reader checking. The first note said the guard
    # "evaluates the bare word as 0 and SILENTLY DOES NOT FIRE". That was
    # measured in the wrong environment — a `bash -c` WITHOUT `set -u`, which is
    # not how this library is ever run.
    #
    # Measured properly, naming the shell, because the answer DEPENDS on it:
    #
    #   bash 4.4.20, `set -u`  (the live path: ci-head-attempts.sh line 122 is
    #                           `set -uo pipefail`)
    #       (( total_count > 100 )) with total_count=null
    #       -> `bash: null: unbound variable`, rc 127 — FATAL. The verb DIES
    #          mid-check with a message naming nothing the reader can act on.
    #   bash 4.4.20, no `set -u`   -> rc 1, treated as 0: silent pass.
    #   zsh 5.4.2,  `set -u`       -> rc 1, no error:     silent pass.
    #
    # So pre-fix this was a CRASH on the live path and a silent pass elsewhere —
    # in neither case a verdict. `null` is exactly what jq emits for an absent
    # field, so the input is ordinary, not exotic. The `=~ ^[0-9]+$` test below
    # runs BEFORE any arithmetic touches the value, which is what makes the
    # answer independent of the caller's shell and option set.
    if [[ -n "$total_count" && ! "$total_count" =~ ^[0-9]+$ ]]; then
        _MRB_STATE="unread"
        _MRB_DETAIL="the run page reported a total this parse could not read (${total_count}), so whether the successful-run list is TRUNCATED is unknown — ${coverage}, and 'they all agree' is a claim over a population that could not be sized (your-org/nexus-code#882 S1)"
        return 0
    fi
    if [[ -n "$total_count" ]] && (( total_count > 100 )); then
        _MRB_STATE="unread"
        _MRB_DETAIL="this head carries ${total_count} runs, more than the 100-run API page, so the successful-run list is TRUNCATED by an unknown amount — ${coverage} of a population that could not be enumerated, and agreement among the runs that came back is not agreement among all of them (your-org/nexus-code#882 S1)"
        return 0
    fi
    tested="$first_tested"
    _MRB_TESTED="$tested"
    if [[ "$tested" == "$base_sha" ]]; then
        _MRB_STATE="current"
        _MRB_DETAIL="run ${from_run} tested against ${tested:0:12}, which EQUALS the live tip of ${base_ref} read just now (${coverage}, all testing the same base${shortfall})"
    else
        _MRB_STATE="stale"
        _MRB_DETAIL="run ${from_run} tested against ${tested:0:12}; the live tip of ${base_ref} is now ${base_sha:0:12} (${coverage}, all testing the same base${shortfall})"
    fi
}

