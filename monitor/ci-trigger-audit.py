#!/usr/bin/env python3
"""ci-trigger-audit.py — prove a PR actually got the CI it looks like it got.

THE DEFECT (your-org/nexus-code#604). `on: pull_request: branches: [main, dev]`
filters the **base** branch. A PR whose base is a feature branch therefore
matches no workflow, gets ZERO checks, and GitHub renders that identically to
"all checks passed": `gh pr view` reports `MERGEABLE` with an EMPTY
`statusCheckRollup`, the merge button shows no red and nothing to click past,
and any "merge when green" automation reads absence-of-failure as success.
your-org/nexus-code#593 sat in exactly that state — OPEN, MERGEABLE,
skeptic-validated, and completely untested — and was caught only because a
human noticed its check count looked different from its neighbours'.

WHAT THIS CHECKS, AND WHY IT IS THE PROPERTY AND NOT A PROXY. The tempting
gate is "the PR has at least one check". That is a proxy, and a bad one: it is
satisfied by this very workflow and so is green by construction. The property
is *"every workflow that would have gated this change actually produced a run
for this head sha"*. So the audit recomputes, from the workflow sources
themselves, which workflows SHOULD have fired for this (base ref, changed
files) pair, and compares that set against the runs GitHub actually recorded.

Several distinct failures fall out, and they are reported separately because
they have different remedies. The unifying invariant (your-org/nexus-code#628):
for every workflow that SHOULD have gated this change, the head must carry a run
whose conclusion is `success` or `failure`. Anything else — `skipped`,
`cancelled`, `timed_out`, `action_required`, `neutral`, `stale`, or **absent** —
is not a verdict, and the absence of a verdict is RED. "A run exists" is a proxy
for "the suite ran to a verdict", and these are the cases where they diverge
(#282's shape one level up).

  TRIGGER-GAP   a workflow's `paths:` MATCH this PR's files, but its
                `branches:` filter excludes this PR's base. The workflow would
                have gated this change on a normal base; the base is why it is
                silent. This is the #593 shape. Retarget onto a listed base,
                or dispatch the workflow on the head ref.

  MISSING-RUN   a workflow SHOULD have fired on every axis and still produced
                no run at all for this head sha (Actions outage, a broken
                workflow file, a dispatch that never registered). This is #619's
                shape: nothing was cancelled and nothing skipped — nothing ran.

  NO-VERDICT    a gating workflow DID produce run(s) for this head sha, but no
                conclusion among them is a verdict — `skipped`, `cancelled`,
                `timed_out`, `action_required`, `neutral`, `stale`. Runs
                existed; the suite did not execute to a pass or a fail. This is
                #627's shape: a title-edit run evicted the real run and then
                skipped, leaving cancelled+skipped and zero assertions run. The
                finding NAMES the run count and every run id, because in that
                shape the multiplicity IS the mechanism and the sentence used
                to say "a run" while listing two conclusions (#787).

  UNEXECUTED-   a gating workflow's run concluded `failure` having executed ZERO
  RUN           steps: every job ran nothing and none was ever assigned a runner
                (your-org/nexus-code#846). A CI-plumbing gap wearing a `failure`
                label. Held distinct from FAILED because the two send a reader
                to opposite places — one to their own diff, one to the billing
                page — and until #846 this file sent the reader to the diff for
                both. Observed live on #837 (head 0b45293a) and again for hours
                on 2026-08-08, when an account payment failure made every run
                repo-wide conclude `failure` in 2-4s with `steps: []`.

                THE ASYMMETRY IS THE DESIGN. Only POSITIVE evidence of
                non-execution downgrades a red; "could not tell" stays RED. See
                UNEXECUTED_EVIDENCE and classify_runs() — a plumbing gap read as
                a code red costs a misrouted reader, while a code red read as a
                plumbing gap merges broken code.

  FAILED        a gating workflow's run concluded `failure` and is not known to
                have executed nothing. This IS a verdict — a real, red one —
                reported SEPARATELY from the absence cases because the human
                response differs: read the test logs and fix the code, not the
                CI plumbing. That last clause is asserted only when execution
                was MEASURED; when it was not, the finding says so rather than
                claiming a property it never checked (#846).

  REPLACED-     a gating workflow concluded `failure` on an earlier ATTEMPT at
  VERDICT       this head sha and something else on a later one. The red was not
                fixed, it was re-run (your-org/nexus-code#748). This is the
                fourth kind of thing that can be wrong with a check set, and the
                only one the other three structurally cannot see: MISSING-RUN,
                NO-VERDICT and TRIGGER-GAP are all species of *absence*, and are
                caught by enumerating that every expected band is named and
                `success`. A replaced verdict defeats that enumeration by
                construction — the band IS named and IS `success`. GitHub keeps
                only the latest attempt in `GET /actions/runs`, in `gh run list`
                and in the check-runs API, so a retried green is byte-identical
                to a first-pass green everywhere. At head d4df844f the SLOW band
                went `failure` then `success` on re-run at the same sha and read
                as clean to every tool in this repo.

  UNGATED       every workflow that fired concluded `success`, and NOT ONE was
                selected by what the diff changed (your-org/nexus-code#856). The
                merge rule this repo actually applies — "each expected band
                exactly once, every band `success`" — is satisfied VACUOUSLY
                here: the expected set contains only workflows that fire
                unconditionally and cannot read the files that changed.

                THE GATE COULD NOT SEE THIS BECAUSE IT HAS NO EXPECTED SET. "Did
                band X run?" has the same answer, `absent`, for a band that
                correctly did not apply and for a band silently suppressed by a
                `paths:` filter. So the rule has two readings and both are
                wrong: strictly, a CLAUDE.md-only PR can never merge, because
                bands that will never exist for that diff are "missing";
                permissively, a PR touching only uncovered files clears the
                strictest gate in the workspace by running nothing.

                WHAT THIS STATE DOES AND DOES NOT DISTINGUISH, stated narrowly
                because the wider version is wrong and tempting. It does NOT
                separate "correctly did not apply" from "silently suppressed" —
                nothing here can, the two are identical from outside, and every
                message in this file says so. What it distinguishes is coarser
                and is the part that was missing: whether ANY band selected by
                the diff's content ran at all. That is enough to stop a
                clearance being issued over a set containing only workflows
                that cannot read the change, and it is not enough to decide
                whether the gap is a defect. The list is printed so a person
                decides.

                Measured at `a91f82b`: 76 of 634 tracked files match no
                `tests.yml` `paths:` entry.

  ATTEMPTS-     a run is past attempt 1 and what the superseded attempt(s)
  UNKNOWN       concluded could not be read. Held distinct from REPLACED-VERDICT
                and from silence alike: "could not determine" is not "determined
                that nothing failed". Folding an unreadable answer into the
                benign branch is how a check that never ran gets believed.

BAND MULTIPLICITY IS REPORTED, NOT ADJUDICATED (your-org/nexus-code#787). Every
run of every gating band is printed before the findings: `runs=N` with each
run's conclusion/attempt/id, which run supplied the verdict, and — when all
bands ran once — the POSITIVE sentence saying so, because a silent report is
indistinguishable from one that never ran. This adds NO verdict state and
changes no exit code; classify_runs() already handles multi-run heads and gets
them right. What was missing is that a reader could not SEE it: on PR #778
every band ran twice (success at the code push, skipped from a later body
edit), the GREEN was correct, and two independent enumerations both reported
"each check-run once" and missed it. See multiplicity_lines() for the full
argument and for why the same silence was more dangerous on the RED path.

A run still queued or in progress at audit time is neither present-as-verdict
nor absent: it is PENDING. ci-signal cannot block for the tens of minutes a
suite takes, so a PENDING run is NOT a finding — its own check carries the
final pass/fail, and reddening a peer check because a sibling is still running
would make this workflow fail on essentially every PR.

BUT "not a finding" IS NOT "cleared" (your-org/nexus-code#762). Those are two
different questions and this file used to answer them with one number. The
positive claim — "every workflow that should have gated this PR carries a
`success` verdict" — is quantified over the CONCLUDED subset, so when zero
gating bands have concluded it is VACUOUSLY TRUE and rendered as `OK` at exit
0. Observed live on PR #758's own head while all three of its bands were still
`in_progress`. That is this repo's dominant defect class — an absence read as
an affirmation — sitting in the reporting layer of the remedy built for it
(#740, #604), and #628's rule is precisely that the absence of a verdict is
RED; "in progress" is an absence of a verdict.

So PENDING now gets its own exit code (3) and its own sentence, and the
positive claim is made ONLY when every gating band has actually concluded. The
two readers this file serves want opposite things from that state and both are
served correctly by separating it: ci-signal.yml, a PEER check running
concurrently with the bands, maps 3 to success and says so out loud; a
merge-path reader (`ng ci-attempts`) maps 3 to "not cleared, come back later".
Neither can be served by a number that means both.

Exit codes are part of the contract:
  0  every gating workflow has CONCLUDED and carries a `success` verdict, AND at
     least one of them was selected by this diff's content — so the green is
     evidence about THIS change and not merely about the PR's existence
     (your-org/nexus-code#856)
  1  TRIGGER-GAP / SELF-BROKEN — never retryable, the PR shape itself is the cause
  2  usage / parse refusal — fail-closed, see REFUSALS below
  3  NOT CONCLUDED — nothing is wrong with the check set, and it is not finished
     either: at least one gating workflow is still queued/in progress and no
     finding stands against any other. Distinct from 0 because a claim over an
     empty or partial concluded set is not a clearance, and distinct from 4
     because a run that is still going IS evidence that the band fired. The
     only exit code here that means "ask again later" rather than "act".
  4  NO VERDICT — a gating workflow produced no `success`/`failure` conclusion:
     MISSING-RUN (no run), NO-VERDICT (a run with a non-verdict conclusion), or
     UNEXECUTED-RUN (a `failure` that executed zero steps, #846). Retryable; the
     caller may poll and re-audit while a real run might still register or
     finish. UNEXECUTED-RUN is the member that will not clear by waiting — the
     summary says so explicitly rather than letting it inherit the shared
     "re-audit" advice.
  5  FAILED — a gating workflow's run concluded `failure` and executed something,
     or its execution could not be measured. A real red, distinct from an absence
     of verdict; not retryable.
  6  REPLACED-VERDICT / ATTEMPTS-UNKNOWN — every gating workflow carries a
     `success` verdict, but at least one of those greens is not a FIRST-PASS
     green (or its provenance could not be read). Ranked last so that exit 6
     carries the narrow, useful meaning "the check set is otherwise clean and
     the thing wrong with it is the retry"; not retryable, because a superseded
     attempt is a permanent fact about the sha and re-reading it cannot change
     the answer.
  8  UNGATED — every workflow that FIRED concluded `success`, and not one of them
     was selected by what this diff changed (your-org/nexus-code#856). The bands
     that ran carry no `paths:` filter, so they fire on every PR and their green
     is evidence about something other than these files. NOT automatically wrong
     — a docs-only change legitimately needs no suite — and NOT a clearance,
     which is why it is neither 0 nor 1. The uncovered files are NAMED so the
     reader can tell "needs no test" from "has a test nobody wired into a
     `paths:` filter"; this audit cannot tell those apart, and both render as
     `absent`.
  7  EXPECTATIONS ONLY — `--observed` was omitted, so this run read the workflow
     SOURCES and read nothing at all about what ran (your-org/nexus-code#812).
     The expectations half can still be clean or red — a TRIGGER-GAP is computed
     from sources alone and still exits 1 — but when it is clean there is no
     verdict to report, because no verdict was ever looked for. Distinct from 0,
     which ASSERTS a `success` verdict; distinct from 3, which says the bands
     are still running and is therefore evidence they fired. Not retryable by
     polling: re-run WITH data, not later.

THE NO-DATA PATH IS STRUCTURALLY SEPARATE, NOT MERELY WORDED DIFFERENTLY
(your-org/nexus-code#812). Until #812 this file printed, two lines apart, "band
multiplicity: NOT CHECKED — … that is 'not looked at', not 'looked at and
clean'" and "OK: every workflow that should have gated this PR has CONCLUDED and
carries a `success` verdict", at rc 0, with the #748 qualifier that would have
softened it guarded by `elif observed is not None` — so the one path that most
needed a qualifier received none. Wording it better would have left the sentence
one edit away from being reachable again. Instead the verdict sentence now lives
in exactly one function, `cleared_lines()`, which REFUSES (UnmeasuredClaim) if it
is ever called without run data, and the three terminal states are selected by
one function, `clearance_report()`, on the question "what was this run in a
position to answer" rather than on "was anything wrong". `main()` has no other
place that can print a clearance.

REFUSALS (fail-closed). A parser that shrugs at a shape it does not understand
manufactures exactly the silent green this file exists to prevent, so anything
unrecognised is exit 2 with a message, never a default. Refused shapes:
`branches-ignore`, `paths-ignore`, negated (`!`) path patterns, a non-list
where a list is required, and an unreadable/!mapping workflow file.

COVERAGE BOUNDARY (one sentence, on the axis the mechanism varies on — WHICH
absence-of-verdict states are caught). This audit catches every absence-of-
verdict state that is terminal or absent at the moment it runs — `skipped`,
`cancelled`, `timed_out`, `action_required`, `neutral`, `stale`, and
no-run-at-all — and reports a genuine `failure` distinctly from them; it does
NOT catch a run that is still IN PROGRESS when the audit runs and is cancelled
only afterward (ci-signal runs once and cannot block for the minutes a suite
takes, so it treats an in-flight run as verdict-pending — that race is closed at
source by the event-class-discriminated concurrency group, which
monitor/lint-workflows.py now requires of EVERY workflow in the
directory rather than of the one file that happened to get it first
(your-org/nexus-code#736), not by this invariant), and it still cannot see
required-status-check configuration,
so it makes an unverdicted PR visibly RED but does not by itself block the
merge button.
"""

import argparse
import collections
import os
import re
import sys

# One observed workflow run. A record rather than a bare tuple because #787
# added a fifth field (`run_id`) to a shape ten call sites unpacked positionally
# — and a positional unpack that silently reads the wrong column is the exact
# family of defect this file exists to report on. #846 added the sixth and
# seventh (`executed`, `exec_detail`) for the same reason.
#
# The two #846 fields carry DEFAULTS, and the default for `executed` is
# `unknown` rather than anything friendlier. A constructor that predates #846
# — including any future one — therefore builds a run whose execution is
# unmeasured, which keeps a `failure` RED. Putting the fail-closed default in
# the TYPE means it cannot be forgotten at a call site.
Run = collections.namedtuple(
    "Run", "status conclusion attempt priors run_id executed exec_detail")
Run.__new__.__defaults__ = ("unknown", "")

# What monitor/ci-run-execution.sh may say about whether a run EXECUTED
# anything, and — the whole of #846 in one line — which of those tokens is
# allowed to take a `failure` away from RED.
#
#   THE BOUNDARY: "no steps data" and "zero steps executed" are DIFFERENT
#   PROPOSITIONS, and only the second one may downgrade a red.
#
# So this is an allowlist of exactly ONE token, for the same reason
# VERDICT_CONCLUSIONS is an allowlist (#628): a token this code has never heard
# of, an absent column, a failed lookup and a truncated page must all fail
# toward RED. The asymmetry is deliberate and it is the point. Misreading a
# plumbing gap as a code red costs a misrouted reader; misreading a code red as
# a plumbing gap merges broken code because the gate said "not your fault".
UNEXECUTED_EVIDENCE = frozenset({"unexecuted"})

try:
    import yaml
except ImportError:  # fail-closed: no silent "nothing to audit"
    sys.stderr.write(
        "ci-trigger-audit: PyYAML is required and is not importable. "
        "Refusing to report a clean audit without having parsed anything.\n")
    sys.exit(2)


# YAML 1.1 (which PyYAML implements) resolves the bare key `on` to the boolean
# True. Every GitHub workflow therefore parses with True as a top-level key,
# not the string "on". Reading d["on"] silently yields nothing and every
# workflow looks trigger-less — a blind spot of precisely the kind this file
# exists to close, so both spellings are accepted and the case is tested.
ON_KEYS = ("on", True)


class Refusal(Exception):
    """An input shape the audit does not understand. Never downgraded."""


class UnmeasuredClaim(Exception):
    """The clearance sentence was reached without the data that licenses it.

    Deliberately NOT a Refusal. A Refusal is about the INPUT — a shape the audit
    will not guess at. This is about this file's own control flow: it fires only
    if a future edit routes the no-observed-data path back into the verdict
    sentence (your-org/nexus-code#812). It exists so that precondition is
    enforced by the interpreter rather than by whoever next reads `main()`; a
    precondition nothing can trip is prose, and prose cannot be made to fail.
    """


def _get_on(doc, path):
    for k in ON_KEYS:
        if isinstance(doc, dict) and k in doc:
            return doc[k]
    return None


def _as_list(value, what, path):
    if value is None:
        return None
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        for item in value:
            if not isinstance(item, str):
                raise Refusal("%s: %s contains a non-string entry (%r)"
                              % (path, what, item))
        return value
    raise Refusal("%s: %s is a %s; expected a string or a list"
                  % (path, what, type(value).__name__))


def gh_glob_to_regex(pattern):
    """Translate a GitHub Actions path filter into an anchored regex.

    GitHub's globs are NOT fnmatch: `*` stops at a `/` and `**` crosses it.
    fnmatch.translate gets both wrong (its `*` spans separators), which would
    make `monitor/*` match `monitor/watcher/x.sh` and quietly widen every
    expectation. Hence a hand-rolled translation.
    """
    out = []
    i = 0
    n = len(pattern)
    while i < n:
        c = pattern[i]
        if c == "*":
            if pattern.startswith("**/", i):
                # `**/` matches zero or more leading directory components.
                out.append("(?:.*/)?")
                i += 3
                continue
            if pattern.startswith("**", i):
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
            i += 1
            continue
        if c == "?":
            out.append("[^/]")
            i += 1
            continue
        out.append(re.escape(c))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def path_matches(patterns, changed_files):
    """True iff any changed file matches any pattern.

    A trailing `/**`-style pattern is also honoured as a directory prefix:
    GitHub treats `monitor/**` as covering everything under monitor/, which
    the regex already does, but `monitor/` alone would not — normalise it.
    """
    regexes = []
    for p in patterns:
        if p.startswith("!"):
            raise Refusal(
                "negated path pattern %r — this audit does not implement "
                "GitHub's negation ordering and will not guess" % p)
        regexes.append(gh_glob_to_regex(p))
    for f in changed_files:
        for rx in regexes:
            if rx.match(f):
                return True
    return False


def parse_workflow(path):
    """Return the pull_request trigger facts for one workflow file.

    Returns None when the workflow declares no `pull_request` trigger at all
    (a push-only or schedule-only workflow gates no PR and is not audited).
    """
    try:
        with open(path, "r") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:
        raise Refusal("%s: unparseable (%s)" % (path, exc))
    if not isinstance(doc, dict):
        raise Refusal("%s: top level is not a mapping" % path)

    on = _get_on(doc, path)
    if on is None:
        raise Refusal("%s: no `on:` trigger block" % path)

    # `on: pull_request` (bare), `on: [push, pull_request]`, or a mapping.
    if isinstance(on, str):
        return {"branches": None, "paths": None} if on == "pull_request" else None
    if isinstance(on, list):
        return {"branches": None, "paths": None} if "pull_request" in on else None
    if not isinstance(on, dict):
        raise Refusal("%s: `on:` is a %s" % (path, type(on).__name__))

    if "pull_request" not in on:
        return None
    pr = on["pull_request"]
    if pr is None:  # `pull_request:` with an empty body — no filters at all
        return {"branches": None, "paths": None}
    if not isinstance(pr, dict):
        raise Refusal("%s: `on.pull_request` is a %s" % (path, type(pr).__name__))

    for banned in ("branches-ignore", "paths-ignore"):
        if banned in pr:
            raise Refusal(
                "%s: `on.pull_request.%s` is not implemented by this audit. "
                "Implement it or convert to the positive form — refusing to "
                "guess at a filter that decides whether CI ran."
                % (path, banned))

    return {
        "branches": _as_list(pr.get("branches"), "on.pull_request.branches", path),
        "paths": _as_list(pr.get("paths"), "on.pull_request.paths", path),
    }


def branch_matches(patterns, base_ref):
    for p in patterns:
        if p.startswith("!"):
            raise Refusal(
                "negated branch pattern %r — refusing to guess at ordering" % p)
        # Branch filters use the same glob dialect; `/` is not special for
        # `*` in refs, but GitHub documents `*` as not matching `/` here too.
        if gh_glob_to_regex(p).match(base_ref):
            return True
    return False


def read_lines(path):
    if not path:
        return []
    with open(path, "r") as fh:
        return [ln.strip() for ln in fh if ln.strip()]


# The only two conclusions that constitute a verdict (your-org/nexus-code#628).
# This is an ALLOWLIST on purpose: a denylist ("everything except skipped and
# cancelled counts") is what let `timed_out`, `action_required`, `neutral` and
# `stale` read as evidence — the #282 shape. Enumerating what IS a verdict makes
# a conclusion this code has never heard of fail toward RED, not toward green.
VERDICT_CONCLUSIONS = frozenset({"success", "failure"})


def read_observed_runs(entries):
    """Parse the observed-runs file into {workflow-basename: [Run, ...]}.

    Each line is TAB-separated
    `path<TAB>status<TAB>conclusion<TAB>run_attempt<TAB>run_id<TAB>priors`,
    as emitted by monitor/ci-observed-runs.jq and then enriched by
    monitor/ci-attempt-history.sh. Each run becomes a `Run` record.

    `run_id` used to be dropped here as "plumbing for the enrichment step
    [carrying] no verdict meaning". That was right about the VERDICT and wrong
    about the READER (your-org/nexus-code#787): when a band ran more than once,
    the id is the only thing that lets somebody go and look at WHICH run
    supplied the verdict and which one merely sat beside it. It is kept for the
    multiplicity report and is still not consulted by any classifier.

    Every field after `path` is optional and degrades fail-closed. A bare
    `path` (no tabs) is tolerated and read as a run with unknown
    status/conclusion — which classify_runs() then treats as NOT a verdict.
    A row with no `run_attempt` column reads as attempt 1: that is the
    pre-#748 wire format, and treating it as "attempt 1" is the one
    assumption that cannot manufacture a false alarm — it under-reports a
    retry rather than inventing one. The complementary risk (silently
    reporting a clean green over a retry we could not see) is why
    ci-signal.yml pipes through the enrichment step unconditionally rather
    than leaving the column optional in practice.

    Everything is keyed on the basename so a full workflow path and a
    basename compare equal.
    """
    runs = {}
    for e in entries:
        parts = e.split("\t")
        wf = os.path.basename(parts[0].strip())
        if not wf:
            continue
        status = parts[1].strip() if len(parts) > 1 else ""
        conclusion = parts[2].strip() if len(parts) > 2 else ""
        # 0 is the sentinel for "the attempt column was not supplied", and it
        # is deliberately NOT 1. Defaulting an absent column to 1 would let
        # this audit print "each of those greens is a first-pass green" on the
        # strength of never having looked — the precise defect class the #748
        # finding is an instance of. 0 propagates to classify_attempts() as
        # UNSUPPLIED and suppresses the positive claim instead of faking it.
        raw_attempt = parts[3].strip() if len(parts) > 3 else ""
        attempt = int(raw_attempt) if raw_attempt.isdigit() else 0
        run_id = parts[4].strip() if len(parts) > 4 else ""
        raw_priors = parts[5].strip() if len(parts) > 5 else ""
        priors = tuple(p.strip() for p in raw_priors.split(",") if p.strip())
        # `unknown` is the default for an ABSENT column, and it is the same
        # token a FAILED lookup produces — on purpose. Both mean "this audit
        # cannot say whether the run executed anything", both keep a `failure`
        # RED, and giving the absent case a friendlier default would let a
        # caller that never ran the enricher collect the downgrade for free
        # (#846). The pre-#846 wire format has six fields and lands here.
        executed = parts[6].strip() if len(parts) > 6 else ""
        exec_detail = parts[7].strip() if len(parts) > 7 else ""
        runs.setdefault(wf, []).append(
            Run(status, conclusion, attempt, priors, run_id,
                executed or "unknown", exec_detail))
    return runs


# A retry whose superseded attempt concluded `failure` REPLACED a verdict; one
# whose superseded attempt concluded anything else replaced no verdict at all.
# Kept as a name rather than an inline literal so it reads against
# VERDICT_CONCLUSIONS above: a `failure` is the only non-`success` conclusion
# that was ever a verdict, so it is the only one whose replacement can be a
# contradiction.
REPLACEABLE_VERDICTS = frozenset({"failure"})


def classify_attempts(runs):
    """Map a workflow's runs to an ATTEMPT-PROVENANCE state (#748).

    Deliberately separate from classify_runs(). That function answers "did the
    suite speak?"; this one answers "was what it said the FIRST thing it said?"
    A single function conflating them is exactly the blur this exists to
    prevent — an enumeration that checks every band is named and `success`
    defeats a MISSING verdict and is silent about a REPLACED one.

      CLEAN         every run is on attempt 1. Nothing was re-run.
      RETRIED       a run is past attempt 1, and no superseded attempt
                    concluded `failure`. A retry happened; no verdict was
                    replaced, so nothing contradicts the current conclusion.
      REPLACED      a superseded attempt concluded `failure` and the workflow
                    now reads otherwise. Two contradicting verdicts at one sha,
                    with nothing adjudicating between them.
      UNDETERMINED  a run is past attempt 1 and at least one superseded
                    attempt's conclusion could not be read (`?`). NOT folded
                    into RETRIED: "could not determine" is not "determined that
                    nothing failed", and collapsing the two is how an unfetched
                    object's non-zero exit got read as a negative answer.
      UNSUPPLIED    the caller gave no attempt column at all (the pre-#748 wire
                    format). Distinct from CLEAN, and that distinction is the
                    whole point: CLEAN is a finding ("I looked; nothing was
                    re-run"), UNSUPPLIED is the absence of one ("I was not
                    given anything to look at"). Reporting UNSUPPLIED as CLEAN
                    would let this audit assert a first-pass green it never
                    checked — the same shape as the defect it detects.

    Precedence is REPLACED > UNDETERMINED > RETRIED > UNSUPPLIED > CLEAN — the
    most consequential state a run set supports wins, so a workflow with one
    benign retry and one replaced red reports the replaced red.
    """
    if not runs:
        return "CLEAN"
    priors = [p for r in runs for p in r.priors]
    if any(p in REPLACEABLE_VERDICTS for p in priors):
        return "REPLACED"
    if any(p == "?" for p in priors):
        return "UNDETERMINED"
    if any(r.attempt > 1 for r in runs):
        # attempt > 1 with an empty prior list is itself unresolved: the
        # enrichment step either did not run or could not name the attempt.
        return "RETRIED" if priors else "UNDETERMINED"
    # Checked AFTER the positive states, so a caller that supplied attempts for
    # some rows and not others still gets the findings its data supports.
    if any(r.attempt == 0 for r in runs):
        return "UNSUPPLIED"
    return "CLEAN"


def classify_runs(runs):
    """Map a gating workflow's runs to a single verdict state (#628).

    `runs` is a list of (status, conclusion) tuples for one workflow's runs on
    the head sha. Returns one of:

      PASS       at least one run concluded `success` — the code was tested and
                 passed. A success anywhere wins: a later title-edit skip does
                 not un-test a head a real run already passed.
      FAIL       a run concluded `failure`, none concluded `success`, and that
                 failing run is not POSITIVELY known to have executed nothing.
                 A real, red verdict — reported distinctly from the absences.
      PENDING    no terminal verdict yet, but a run is still queued/in progress.
                 Its own check will carry the pass/fail; ci-signal cannot wait.
      UNEXECUTED every failing run at this band is positively known to have
                 executed ZERO steps (your-org/nexus-code#846). A CI-plumbing
                 gap wearing a `failure` label — a suite that never started has
                 not spoken, whatever GitHub called the result.
      NO_VERDICT runs exist but every one is terminal with a non-verdict
                 conclusion (skipped/cancelled/timed_out/action_required/…).
      ABSENT     no run at all for this head sha.

    Precedence is success > failure > pending > unexecuted > no-verdict; a
    workflow that both passed once and skipped once is PASS, and one cancelled +
    skipped (the exact #627 head) with no success/failure/in-flight run is
    NO_VERDICT.

    WHERE #846 SITS IN THAT ORDER, and why it is not simply "failure → check
    steps". An unexecuted `failure` is treated EXACTLY like a non-verdict
    conclusion: it drops out of the verdict set and the existing precedence then
    runs unchanged. That is why UNEXECUTED sits BELOW pending — a band with one
    aborted run and one still in flight is PENDING, because the in-flight run
    may yet speak, and telling the reader "plumbing gap" while a real run is
    executing would be the same over-claim in a new place.

    PER-RUN, AGGREGATED FROM JOBS, AND MIXED RUNS ARE RED. The evidence token
    describes a RUN and is computed by monitor/ci-run-execution.sh from ALL of
    that run's jobs: `unexecuted` requires that EVERY job ran zero steps and
    that NO job was assigned a runner. So a MIXED run — some jobs executed, some
    never started — yields `mixed`, which is not on the allowlist and therefore
    lands in FAIL. That is a deliberate choice and it can be wrong in the
    harmless direction: a run whose only executed job passed, plus an aborted
    job, reads as a real red. The alternative — classifying per job and
    downgrading the run if ANY job was aborted — would let one infrastructure
    hiccup inside an otherwise-executing run excuse a genuine test failure
    beside it. Between a false RED and a false "not your fault", this file
    always takes the false RED.

    This docstring said `unknown` until PR #854's skeptic measured `executed`
    (F2). Both readings were wrong, and the second mattered: the token selects
    which MESSAGE the FAILED finding prints, and `executed` licenses "this is
    not a CI-plumbing gap" — false of a run that is partly one. The token is now
    `mixed` and carries its own tail. Recorded rather than quietly corrected,
    because a docstring that predicted the wrong token for the sentence #846
    exists to discipline is the same defect one level up.
    """
    if not runs:
        return "ABSENT"
    conclusions = {r.conclusion for r in runs}
    if "success" in conclusions:
        return "PASS"
    # A `failure` is a verdict only if the suite actually ran. `spoke` keeps
    # every failing run whose execution evidence is anything OTHER than a
    # positive `unexecuted` — including `unknown`, `not-checked`, an absent
    # column and a token from a future enricher this code has not heard of.
    # Written as "not on the one-token allowlist" rather than as a list of
    # unknown-ish spellings, because a denylist here is what would let the next
    # unenumerated token silently excuse a red.
    red = [r for r in runs if r.conclusion == "failure"]
    spoke = [r for r in red if r.executed not in UNEXECUTED_EVIDENCE]
    if spoke:
        return "FAIL"
    # A run whose status is anything other than `completed` is still in flight
    # (its conclusion is null until it finishes). GitHub statuses seen here:
    # queued, in_progress, waiting, requested, pending — all pre-terminal.
    if any(r.status and r.status != "completed" for r in runs):
        return "PENDING"
    if red:
        return "UNEXECUTED"
    return "NO_VERDICT"


# --------------------------------------------------------------------------
# BAND MULTIPLICITY — adjudicated already, now SURFACED (#787)
# --------------------------------------------------------------------------
#
# THE GAP, stated narrowly because the wide version is wrong. Multiplicity is
# NOT unchecked: classify_runs() above takes the per-band run LIST and its
# precedence rules are written for exactly this, with both shapes pinned by
# monitor/test-ci-trigger-audit.sh — `cancelled + skipped` is NO-VERDICT/RED
# (the #627 eviction), `success + skipped` is GREEN on purpose ("a head a real
# run passed stays passed"). Nothing below changes any of that, and nothing
# below is a second adjudicator. VERDICT_CONCLUSIONS and classify_runs do not
# move.
#
# What was missing is that a reader could not SEE it. On PR #778 every gating
# band ran TWICE — four `success` at the last code push, four `skipped` from an
# `edited` event twenty minutes later (a PR *body* fix) — and the merge was
# correct for the documented reason. But two independent enumerations, a
# worker's and its skeptic's, both reported "one head_sha, run_attempt=1, each
# check-run once" and NEITHER noticed. That is not carelessness; it is the
# reporting surface:
#
#   * `GET /commits/{sha}/check-runs`, the endpoint a human reaches for,
#     returns check-runs and not runs, so a second run of the same band shows
#     up as more rows with no field saying why.
#   * "distinct head_sha == 1" and "each band ran exactly once" are different
#     questions, and this repo's own CI-discipline wording invites conflating
#     them. #778 satisfied the first and failed the second.
#   * a `success + skipped` band is indistinguishable at a glance from a band
#     that ran once, so the #628 cause — a title/body edit after the last code
#     push — leaves no signal a reviewer will notice.
#
# So a reader could not tell a green that means "one clean run per band" from a
# green that means "two runs, adjudicated in your favour". Those warrant the
# same merge and a different amount of attention.
#
# It runs in the RED direction too, and more dangerously. The NO-VERDICT
# finding used to open "produced a run for this head sha, but its conclusion is
# cancelled, skipped" — SINGULAR, while listing two conclusions. A reader is
# told one run somehow concluded twice, when the truth is that a free skip-run
# EVICTED a real one. That is the #627 mechanism, and the sentence describing
# it hid the multiplicity that IS the mechanism.
#
# This costs no extra API calls: every field used here is already in the
# payload monitor/ci-observed-runs.jq extracts, which is the same argument that
# file makes for carrying `run_attempt`.


def verdict_source(runs, state):
    """Return the Run that supplied `state`, or None when nothing did.

    Reporting only. The verdict is classify_runs()'s; this answers the strictly
    weaker question "which of these runs is the one it came from", which is
    unanswerable from the summary line and is what a reader needs in order to
    go and look.
    """
    if state == "PASS":
        return next((r for r in runs if r.conclusion == "success"), None)
    if state == "FAIL":
        # The run that SPOKE, which after #846 is not necessarily the first
        # `failure` in the list: a band with one aborted run and one genuinely
        # failing run is FAIL because of the second, and naming the first would
        # point the reader at the run with no logs in it.
        return next((r for r in runs
                     if r.conclusion == "failure"
                     and r.executed not in UNEXECUTED_EVIDENCE), None)
    if state == "PENDING":
        return next((r for r in runs
                     if r.status and r.status != "completed"), None)
    return None


def describe_run(run):
    """One run as `run <id> (<conclusion>, attempt N)`."""
    what = run.conclusion or run.status or "?"
    ident = run.run_id or "id-unknown"
    if run.attempt:
        return "run %s (%s, attempt %d)" % (ident, what, run.attempt)
    return "run %s (%s, attempt unrecorded)" % (ident, what)


# A `skipped` sibling at one head sha is the signature of the #628 family: a PR
# title/body edit after the last code push fires an `edited` event whose jobs
# all skip. Named explicitly so the family is self-diagnosing rather than
# re-derived by each reader who trips over it.
_EDIT_SHELL_HINT = (
    "a `skipped` sibling run at one head sha is the your-org/nexus-code#628 "
    "signature: a PR TITLE or BODY edit after the last code push fires an "
    "`edited` event whose jobs all skip, at no runner cost and with no signal "
    "a reviewer notices. Write PR bodies with `--body-file` BEFORE the final "
    "push if you want a head that carries one run per band.")


def multiplicity_lines(gating, observed):
    """Render the per-band multiplicity report. Returns (lines, notices).

    `notices` are emitted as GitHub `::notice::` annotations so the fact
    reaches the PR page and not only the step log — the #778 readers were
    reading a summary, which is precisely where this has to appear.
    """
    if observed is None:
        return (["band multiplicity: NOT CHECKED — this run audited "
                 "expectations only, with no observed-runs data. That is "
                 "'not looked at', not 'looked at and clean'."], [])

    with_runs = [(wf, observed.get(wf, [])) for wf in gating
                 if observed.get(wf)]
    if not with_runs:
        return (["band multiplicity: no gating band produced a run, so there "
                 "is no multiplicity to report (the absences are findings "
                 "above, not a clean multiplicity result)."], [])

    multi = [(wf, runs) for wf, runs in with_runs if len(runs) > 1]
    lines, notices = [], []
    if not multi:
        # The POSITIVE sentence. Silence here is indistinguishable from a
        # check that never ran, and that is the whole defect being fixed.
        lines.append(
            "band multiplicity: every one of the %d gating band(s) with a run "
            "produced EXACTLY ONE run at this head sha." % len(with_runs))
        return lines, notices

    lines.append(
        "band multiplicity: %d of %d gating band(s) with runs ran MORE THAN "
        "ONCE at this head sha (your-org/nexus-code#787)."
        % (len(multi), len(with_runs)))
    lines.append(
        "    The verdict is UNCHANGED — this is a report, not a second "
        "adjudication. But a green from two runs is not the same evidence as "
        "a green from one, and neither `gh run list` nor "
        "`GET /commits/{sha}/check-runs` shows a reader the difference.")
    for wf, runs in multi:
        state = classify_runs(runs)
        src = verdict_source(runs, state)
        others = [r for r in runs if r is not src]
        if src is not None:
            lines.append("  %-30s runs=%d  %s from %s"
                         % (wf, len(runs), state, describe_run(src)))
            for r in others:
                lines.append("  %-30s          alongside %s"
                             % ("", describe_run(r)))
        else:
            # The dangerous direction: NO run supplied a verdict, and the
            # multiplicity IS the mechanism (#627's cancelled+skipped). Every
            # run is listed flat — calling one of them "alongside" would imply
            # another was the verdict, and none was.
            lines.append("  %-30s runs=%d  %s — NO run supplied a verdict"
                         % (wf, len(runs), state))
            for r in runs:
                lines.append("  %-30s          %s" % ("", describe_run(r)))
        if any(r.conclusion == "skipped" for r in others) or (
                src is None and any(r.conclusion == "skipped" for r in runs)):
            lines.append("      %s" % _EDIT_SHELL_HINT)
        notices.append(
            "%s ran %d times at this head sha; %s. Runs: %s"
            % (wf, len(runs),
               ("the verdict came from %s" % describe_run(src)) if src
               else "NO run supplied a verdict",
               "; ".join(describe_run(r) for r in runs)))
    return lines, notices


# --------------------------------------------------------------------------
# THE CLEARANCE CLAIM — one sentence, one function, one precondition (#812)
# --------------------------------------------------------------------------
#
# "No finding" is not one state, and this file used to render three of them with
# two sentences. The discriminator below is deliberately NOT "was anything
# wrong": every state here has nothing wrong with it. It is "which question was
# this run in a position to answer at all".
#
#   observed is None  the run was shown no runs. It can say which workflows
#                     SHOULD gate this PR — that is computed from the workflow
#                     sources — and it can say nothing whatever about what ran.
#   pending           the runs exist and are still going. Evidence the bands
#                     fired; not evidence of what they will conclude (#762).
#   otherwise         every gating band concluded, and concluded `success`.
#
# The first two are absences of DIFFERENT things and the third is the only
# presence, so they get three sentences and three exit codes. The house rule the
# multiplicity report already states one screen higher — "'not looked at' is not
# 'looked at and clean'" — is the same rule, and until #812 the summary line
# directly beneath it broke it.


def expectations_only_lines(gating):
    """The `observed is None` terminal block. Never a verdict."""
    lines = ["EXPECTATIONS ONLY: no observed-runs data was supplied "
             "(`--observed` omitted), so this run examined which workflows "
             "SHOULD gate this PR and examined NOTHING about what ran."]
    if gating:
        lines.append(
            "    CHECKED, and clean: %d workflow(s) should gate this PR (%s), "
            "and none is trigger-gapped or self-broken. That is a claim about "
            "the workflow SOURCES, which is the whole of what this mode reads."
            % (len(gating), ", ".join(gating)))
    else:
        lines.append(
            "    CHECKED, and clean: NO workflow's triggers select this "
            "change, so there is no band whose run could have been examined. "
            "That is not a verdict either — it is the statement that no "
            "verdict was ever expected.")
    lines.append(
        "    NOT CHECKED, and therefore NOT CLEAN: whether any expected band "
        "produced a run at this head sha, whether it concluded, whether it "
        "concluded `success`, and whether that green was a first-pass one. "
        "None of those questions was asked.")
    lines.append(
        "    This exit is 7 and 7 means NOT MEASURED. Supply "
        "`--observed <file>` (monitor/ci-observed-runs.jq emits it, "
        "monitor/ci-attempt-history.sh enriches it) if you want a verdict; "
        "polling will not help, because nothing here is waiting on anything.")
    return lines


def not_concluded_lines(gating, pending):
    """The PENDING terminal block (your-org/nexus-code#762).

    Nothing is WRONG here — every finding branch is empty — but "nothing is
    wrong" is not "this head is cleared", and the claim underneath used to be
    quantified over the CONCLUDED subset, which makes it vacuously true when
    that subset is empty. So the quantifier is checked explicitly against
    `gating`, and the two sub-states are printed differently because a reader
    forms a different belief from each — even though the ACTION is the same
    (wait, then re-audit), which is why they share one exit code rather than
    inventing two. One number per action, one sentence per belief.
    """
    concluded = [w for w in gating if w not in pending]
    lines = ["NOT CONCLUDED: this head's check set is not finished, and "
             "nothing here says it passed."]
    if not concluded:
        lines.append("    NO gating workflow has reached a verdict yet — %d "
                     "of %d still queued or in progress: %s."
                     % (len(pending), len(gating), ", ".join(pending)))
        lines.append("    A claim about 'every completed run' would be "
                     "quantified over the EMPTY SET here, hence vacuously "
                     "true, and it is exactly that sentence which used to "
                     "render as OK (#762). There is no evidence yet — not "
                     "good evidence, not bad evidence, NONE.")
    else:
        lines.append("    PARTIAL and PROVISIONAL: %d of %d gating workflows "
                     "have concluded and carry a `success` verdict (%s); %s "
                     "still queued or in progress."
                     % (len(concluded), len(gating), ", ".join(concluded),
                        ", ".join(pending)))
        lines.append("    That green is a statement about the bands that "
                     "FINISHED. It is not a statement about this head, and "
                     "the pending bands can still turn it red.")
    lines.append("    This is retryable and only retryable: re-audit once "
                 "the pending bands conclude.")
    return lines


def _require_measured(observed):
    """Precondition for any sentence that asserts a verdict about runs.

    A named function rather than an inline `if` for two reasons. It can be
    called from — and only from — the places that make such a claim, so "which
    sentences need run data" is greppable rather than remembered. And a negative
    control can delete exactly this line, without touching the branch that
    normally keeps it unreached, which is how a test shows the precondition is
    load-bearing rather than decorative (monitor/test-ci-trigger-audit.sh 16e).
    """
    if observed is None:
        raise UnmeasuredClaim(
            "a clearance sentence was reached with no observed-runs data. It "
            "asserts a `success` verdict for every gating band; an audit that "
            "was shown no runs does not hold one. Route the no-data case to "
            "expectations_only_lines() (exit 7) instead — see "
            "your-org/nexus-code#812, which is this exact sentence having been "
            "printed at rc 0 on the path where nothing was examined.")


def _unexamined_block(unexamined, total_changed):
    """The files nothing read, rendered for a report that is otherwise a PASS.

    Kept as its own function because it is called from BOTH terminal states that
    can carry unexamined files — the UNGATED block and the CLEARANCE block — and
    the second one is where it was missing (PR #868 skeptic). A clearance that
    silently omits what it did not examine is the same defect this file exists
    to close, one level in.
    """
    lines = []
    if not unexamined:
        return lines
    shown = unexamined[:20]
    lines.append(
        "    PARTIALLY EXAMINED: %d of the %d changed file(s) match NO "
        "workflow's `paths:` filter, so nothing read them%s:"
        % (len(unexamined), total_changed,
           "" if len(unexamined) <= 20 else " (first 20 shown)"))
    for f in shown:
        lines.append("      %s" % f)
    lines.append(
        "    The verdict above is a REAL clearance — a band selected by this "
        "diff's content ran and passed — but it is a claim about the files "
        "that were examined, and the ones listed here are not among them. "
        "That may be fine (a README beside a code change needs no suite of its "
        "own) or it may be a `paths:` filter that never learned about a "
        "directory; this audit cannot tell those apart and does not try.")
    return lines


def cleared_lines(gating, observed, unexamined=(), total_changed=0):
    """The one place in this file that says a head carries a `success` verdict.

    `observed` is not decoration: passing it is what licenses the sentence, and
    the precondition below is why the sentence cannot be reached without it. A
    caller with no run data has nothing to hand here, which is the point
    (your-org/nexus-code#812).
    """
    _require_measured(observed)
    lines = ["OK: every workflow that should have gated this PR has "
             "CONCLUDED and carries a `success` verdict for this head sha."]
    # The first-pass claim is made ONLY when an attempt column was actually
    # supplied for every observed run. Printing it otherwise would be this file
    # asserting a property it did not measure, which is the #748 defect wearing
    # the detector's clothes.
    checked_provenance = bool(observed) and all(
        r.attempt > 0
        for runs in observed.values()
        for r in runs)
    if checked_provenance:
        lines.append("    Each of those greens is a FIRST-PASS green: no "
                     "gating run was re-run into passing at this sha (#748).")
    else:
        lines.append("    Attempt provenance was NOT supplied, so whether any "
                     "of those greens replaced an earlier `failure` is "
                     "UNKNOWN — not verified-absent (#748).")
    # THE CLEARANCE MUST CARRY WHAT IT DID NOT EXAMINE (PR #868 skeptic).
    # The per-file `unexamined` list was computed and then DISCARDED on this
    # path, so a diff mixing one covered file with any number of uncovered ones
    # printed the full clearance and named none of them. That made the whole
    # feature fire only when an uncovered file was the SOLE change — the
    # demonstration case — and go silent the moment any covered file rode
    # along, which is what a real PR looks like.
    lines.extend(_unexamined_block(list(unexamined), total_changed))
    return lines


def ungated_lines(gating, unexamined, observed):
    """The UNGATED terminal block (your-org/nexus-code#856).

    Every gating band concluded `success`, and NOT ONE of them was selected by
    what this diff changed. The bands that ran are the unconditional ones — a
    workflow with no `paths:` filter fires on every PR — so the green is real
    and is evidence about something other than this change.
    """
    _require_measured(observed)
    lines = ["UNGATED: every workflow that fired for this PR has CONCLUDED and "
             "carries a `success` verdict — and NOT ONE of them was selected "
             "by what this diff changed."]
    lines.append(
        "    %d workflow(s) fired (%s), all of them unconditionally: they carry "
        "no `paths:` filter, so they fire on EVERY PR and their green says "
        "nothing about these files. No workflow's `paths:` filter matched this "
        "diff, so no suite examined the change."
        % (len(gating), ", ".join(gating) if gating else "none"))
    shown = unexamined[:20]
    lines.append("    NOT EXAMINED BY ANY WORKFLOW (%d file(s)%s):"
                 % (len(unexamined),
                    "" if len(unexamined) <= 20 else ", first 20 shown"))
    for f in shown:
        lines.append("      %s" % f)
    lines.append(
        "    This is NOT automatically wrong — a docs-only change legitimately "
        "needs no suite. It is also NOT a clearance, and those are different "
        "sentences: this audit cannot tell a file that NEEDS no test from a "
        "file whose test exists and was never wired into a `paths:` filter. "
        "Both render as `absent`, and the merge rule 'every expected band ran "
        "and passed' is satisfied VACUOUSLY by the second.")
    lines.append(
        "    Decide deliberately: if these files are covered by a suite, add "
        "them to that workflow's `paths:` filter; if they genuinely need none, "
        "say so on the PR. Exit 8 exists so that decision is made by a person "
        "and not inherited from an empty set.")
    return lines


def clearance_report(gating, pending, observed, content_gating=(), unexamined=(),
                     total_changed=0):
    """Terminal block for a finding-free audit: (lines, exit_code).

    `pending` is only ever populated when `observed is not None`, so the first
    arm cannot swallow a pending state; the ordering is nonetheless written so
    that the no-data case is decided FIRST and by the presence of data alone,
    never by the emptiness of some derived list. An arm that reads "nothing is
    pending" as "everything concluded" is the vacuous quantifier one level up.

    THE UNGATED ARM (your-org/nexus-code#856) is the same rule applied to a
    quantifier nobody had looked at. `cleared_lines()` is quantified over
    `gating` — every workflow that FIRES. On this repo `conflict-markers.yml`
    carries no `paths:` filter and therefore fires on every PR, so `gating` is
    never empty and the clearance was never vacuous in the obvious way. It was
    vacuous in a subtler one: for a diff that matches no `paths:` filter, the
    only members of `gating` are workflows that cannot read the files that
    changed, and "every workflow that should have gated this PR carries a
    `success` verdict" is TRUE, and means nothing about the change.

    Measured at `a91f82b`: 76 of 634 tracked files match no `tests.yml`
    `paths:` entry. A PR touching only those got this function's exit 0 and the
    full clearance sentence, on the strength of a merge-conflict-marker check.
    """
    if observed is None:
        return expectations_only_lines(gating), 7
    if pending:
        return not_concluded_lines(gating, pending), 3
    if not content_gating:
        return ungated_lines(gating, list(unexamined), observed), 8
    return cleared_lines(gating, observed, unexamined, total_changed), 0


def audit(workflows_dir, base_ref, changed_files, observed, self_workflow):
    findings = []   # (kind, workflow, message)
    gating = []     # workflows that SHOULD have run
    notes = []
    # Gating workflows whose runs exist but have NOT concluded (#762). Returned
    # rather than only noted: the caller's positive claim must be quantified
    # over `gating`, not over `gating minus pending`, and it cannot do that
    # arithmetic from a prose note. This list being non-empty is the difference
    # between "clean" and "not finished".
    pending = []
    # Workflows selected BY THE DIFF'S CONTENT — i.e. gating workflows that
    # carry a `paths:` filter and whose filter matched. A workflow with no
    # `paths:` filter fires unconditionally and is deliberately NOT here
    # (your-org/nexus-code#856).
    content_gating = []
    path_selectors = []   # (name, patterns) for the above, to name unexamined files

    names = sorted(f for f in os.listdir(workflows_dir)
                   if f.endswith(".yml") or f.endswith(".yaml"))
    if not names:
        raise Refusal("%s: no workflow files — refusing to report a clean "
                      "audit over an empty set" % workflows_dir)

    for name in names:
        full = os.path.join(workflows_dir, name)
        trig = parse_workflow(full)

        # --- self-integrity ------------------------------------------------
        # The guard is only load-bearing while it is itself unfilterable. A
        # future edit adding `branches:`/`paths:` to it would trigger-gap the
        # trigger-gap detector out of existence, silently and permanently.
        if self_workflow and name == self_workflow:
            if trig is None:
                findings.append(("SELF-BROKEN", name,
                                 "the ci-signal workflow declares no "
                                 "pull_request trigger; it cannot guard anything"))
            else:
                if trig["branches"] is not None:
                    findings.append(("SELF-BROKEN", name,
                                     "ci-signal declares `branches: %s` — the "
                                     "guard must run on EVERY base or it shares "
                                     "the blind spot it exists to detect"
                                     % (trig["branches"],)))
                if trig["paths"] is not None:
                    findings.append(("SELF-BROKEN", name,
                                     "ci-signal declares `paths: %s` — the "
                                     "guard must run on EVERY PR or a PR can "
                                     "dodge it by touching other files"
                                     % (trig["paths"],)))
            continue

        if trig is None:
            notes.append("%s: no pull_request trigger — gates no PR" % name)
            continue

        paths_apply = (trig["paths"] is None
                       or path_matches(trig["paths"], changed_files))
        base_applies = (trig["branches"] is None
                        or branch_matches(trig["branches"], base_ref))

        if not paths_apply:
            notes.append("%s: paths filter does not match this PR's files "
                         "— correctly silent" % name)
            continue

        if not base_applies:
            findings.append((
                "TRIGGER-GAP", name,
                "its paths filter MATCHES this PR's changed files, but its "
                "`branches: %s` excludes this PR's base %r. On a listed base "
                "this workflow WOULD have gated this change; the base is the "
                "only reason it is silent."
                % (trig["branches"], base_ref)))
            continue

        gating.append(name)
        # CONTENT-SELECTED vs merely FIRING (your-org/nexus-code#856). A
        # workflow with NO `paths:` filter fires on every PR, so its presence in
        # `gating` says nothing whatever about the diff. Only a workflow whose
        # `paths:` filter MATCHED was selected BY what changed, and only those
        # can be evidence that this change was examined. Recorded separately
        # because the clearance sentence below is quantified over `gating`, and
        # that quantifier is what made an unexamined diff read as cleared.
        if trig["paths"] is not None:
            content_gating.append(name)
            path_selectors.append((name, trig["paths"]))
        if observed is None:
            continue

        wf_runs = observed.get(name, [])
        state = classify_runs(wf_runs)

        # Provenance is judged on EVERY gating workflow, and BEFORE the PASS
        # short-circuit, because a PASS is the only place a replaced red can
        # hide. Checking it after `if state == "PASS": continue` would build
        # the detector and then route the one case it exists for around it.
        prov = classify_attempts(wf_runs)
        if prov == "REPLACED":
            reds = sorted({p for r in wf_runs
                           for p in r.priors if p in REPLACEABLE_VERDICTS})
            latest = sorted({r.conclusion or "(none)" for r in wf_runs})
            findings.append((
                "REPLACED-VERDICT", name,
                "an earlier attempt at this head sha concluded %s and a later "
                "attempt concluded %s. The red was not fixed, it was RE-RUN — "
                "and every tool that reads only the latest attempt (`gh run "
                "list`, the check-runs API, this audit before #748) shows this "
                "head as a clean first-pass green. Two contradicting verdicts "
                "exist at one sha and nothing has adjudicated between them: "
                "decide whether the earlier red was a flake or a real defect. "
                "A flake is a DEFECT IN THE TEST and belongs in a fix, not in "
                "a re-run habit. Resolve by fixing the flake and pushing (the "
                "new head gets a first-pass verdict), not by re-running this "
                "check — re-running ci-signal cannot clear this, because the "
                "superseded attempt is a permanent fact about this sha."
                % (", ".join(reds), ", ".join(latest))))
        elif prov == "UNDETERMINED":
            findings.append((
                "ATTEMPTS-UNKNOWN", name,
                "a run for this head sha is past attempt 1, and what the "
                "superseded attempt(s) concluded could NOT be read. This is "
                "reported rather than passed over: `could not determine` is "
                "not `determined that nothing failed`, and a green whose "
                "provenance is unreadable is not a verified first-pass green. "
                "Re-run this audit once the Actions API is reachable; if it "
                "stays unreadable, treat the green as unverified."))
        elif prov == "RETRIED":
            benign = sorted({p for r in wf_runs for p in r.priors})
            notes.append(
                "%s: re-run at this head sha (superseded attempt(s) concluded "
                "%s). No VERDICT was replaced — a `failure` is the only "
                "conclusion that was ever a verdict — so nothing contradicts "
                "the current one. Stated, not counted against the PR."
                % (name, ", ".join(benign)))
        elif prov == "UNSUPPLIED":
            notes.append(
                "%s: no attempt column in the observed-runs data, so this "
                "audit did NOT check whether its verdict was a first-pass one. "
                "Pipe the extractor through monitor/ci-attempt-history.sh to "
                "close this. Absence of a REPLACED-VERDICT finding here means "
                "'not checked', not 'checked and clean'." % name)

        if state == "PASS":
            continue
        if state == "PENDING":
            pending.append(name)
            notes.append("%s: a run for this head sha is still in progress — "
                         "its own check carries the pass/fail; not counted as "
                         "absent, and NOT counted as concluded either (#762)"
                         % name)
            continue
        if state == "ABSENT":
            findings.append((
                "MISSING-RUN", name,
                "should have fired on every axis (base %r matches, paths "
                "match) but GitHub recorded NO run at all for this head sha. "
                "Nothing was skipped or cancelled — nothing ran (the #619 "
                "shape)." % base_ref))
        elif state == "NO_VERDICT":
            nv_runs = observed.get(name, [])
            concs = sorted({r.conclusion or "(none)" for r in nv_runs})
            # The run COUNT leads, and each run is named. This sentence used to
            # open "produced a run … but its conclusion is cancelled, skipped"
            # — singular, while listing two conclusions, so it read as one run
            # that somehow concluded twice. The multiplicity IS the #627
            # mechanism (a free skip-run evicting a real one), and hiding it
            # here misled in the DANGEROUS direction: a reader cannot diagnose
            # an eviction they are not told happened (your-org/nexus-code#787).
            findings.append((
                "NO-VERDICT", name,
                "produced %d run(s) for this head sha — %s — and NOT ONE "
                "concluded `success` or `failure`. Conclusions seen: %s. The "
                "suite did not execute to a pass or a fail.%s `success`/"
                "`failure` are the only verdicts."
                % (len(nv_runs),
                   "; ".join(describe_run(r) for r in nv_runs),
                   ", ".join(concs),
                   ("" if len(nv_runs) < 2 else
                    " TWO OR MORE RUNS AT ONE HEAD SHA IS THE MECHANISM, not a "
                    "detail: this is the #627 shape, where `cancel-in-progress: "
                    "true` lets a free skip-run from a PR meta-edit EVICT the "
                    "real run that was still executing. Read the run ids above "
                    "in order — the cancelled one is the suite you wanted."))))
        elif state == "UNEXECUTED":
            unex = [r for r in wf_runs if r.conclusion == "failure"]
            details = sorted({r.exec_detail for r in unex if r.exec_detail})
            findings.append((
                "UNEXECUTED-RUN", name,
                "concluded `failure` for this head sha and EXECUTED NOTHING: "
                "every job of %s ran zero steps and none was ever assigned a "
                "runner. That is a CI-PLUMBING GAP wearing a `failure` label, "
                "not a verdict on your code — there are no logs to read and no "
                "test that said no. A suite that did not execute has not "
                "spoken, whatever GitHub labelled the result, by the same "
                "reasoning that makes `skipped` not a pass (#628, #846). "
                "Reported as an ABSENCE of verdict (exit 4, retryable) rather "
                "than as a FAILED (exit 5, not retryable), because retrying an "
                "infrastructure abort is the correct response and retrying a "
                "real red is the #748 habit. Fix the ACCOUNT or the RUNNER "
                "supply, then re-run — changing code cannot clear this.%s"
                % ("; ".join(describe_run(r) for r in unex),
                   (" Evidence: %s" % " | ".join(details)) if details else
                   " GitHub supplied no annotation explaining why, so the "
                   "cause is unstated here — the zero-execution finding stands "
                   "on the steps and runner evidence alone.")))
        elif state == "FAIL":
            src = verdict_source(wf_runs, "FAIL")
            # The strong sentence — "not a CI-plumbing gap" — is a CLAIM ABOUT
            # EXECUTION, and until #846 this file made it having never measured
            # execution. It is now made only when the evidence licenses it, and
            # the unmeasured case says so instead of borrowing the confidence.
            # Correcting the wording without the classifier would have been the
            # same defect in a politer voice; correcting the classifier without
            # the wording would have left the sentence lying on the path that
            # still, correctly, reds.
            if src is not None and src.executed == "executed":
                tail = ("Execution was MEASURED: %s. So the strong reading "
                        "holds — read the run's logs and fix the code, this is "
                        "not a CI-plumbing gap." % src.exec_detail)
            elif src is not None and src.executed == "mixed":
                # The run SPOKE, so this is a real red and stays exit 5. But
                # "this is not a CI-plumbing gap" is false of a run that is
                # PARTLY one, and saying it anyway would be this file's own
                # subject matter (PR #854 skeptic, F2).
                tail = ("Execution was MEASURED and is MIXED: %s. The red is "
                        "real and belongs in your diff — but part of this run "
                        "did NOT execute, so a job you expected to see a result "
                        "from may simply never have started. Read the failing "
                        "job's logs; do not read the whole run as a verdict."
                        % src.exec_detail)
            else:
                tail = ("Whether this run EXECUTED anything was NOT measured "
                        "(evidence: %s). It is treated as a real red because "
                        "unmeasured is not exonerated (#846) — but before "
                        "hunting a defect in your diff, check the run's jobs: "
                        "zero steps and no runner assigned means nothing ran "
                        "and the fault is not in the code. Pipe the "
                        "observed-runs data through "
                        "monitor/ci-run-execution.sh to have this answered "
                        "rather than left open."
                        % (src.executed if src is not None else "none"))
            findings.append((
                "FAILED", name,
                "concluded `failure` for this head sha. This IS a verdict — a "
                "real, red one — reported separately from an ABSENT/NO-VERDICT "
                "so the response is not confused. %s" % tail))

    # The files no content-selected workflow examines. Computed per FILE, not
    # per diff: a diff can select `tests.yml` on one file while another file in
    # the same diff is examined by nothing, and a set-level answer would hide
    # that. Named rather than counted, because "N files are uncovered" is a
    # claim about the tally and the reader needs the members.
    unexamined = [f for f in changed_files
                  if not any(path_matches(pats, [f]) for _, pats in path_selectors)]

    return findings, gating, notes, pending, content_gating, unexamined


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--workflows-dir", required=True)
    ap.add_argument("--base-ref", required=True,
                    help="the PR's BASE branch (this is what `branches:` filters)")
    ap.add_argument("--changed-files", required=True,
                    help="file with one changed path per line")
    ap.add_argument("--observed",
                    help="file with one run per line as `path<TAB>status<TAB>"
                         "conclusion[<TAB>run_attempt<TAB>run_id<TAB>priors"
                         "<TAB>execution<TAB>execution_detail]` (emitted by "
                         "monitor/ci-observed-runs.jq, enriched by "
                         "monitor/ci-attempt-history.sh and "
                         "monitor/ci-run-execution.sh) for the head sha; a bare "
                         "path is tolerated and read fail-closed as a "
                         "non-verdict run, and an absent execution column reads "
                         "as `unknown`, which keeps a `failure` RED; omit to "
                         "audit expectations only")
    ap.add_argument("--self-workflow", default="ci-signal.yml",
                    help="basename of the guard workflow, checked for "
                         "self-integrity (empty string disables)")
    args = ap.parse_args()

    try:
        changed = read_lines(args.changed_files)
        observed = (read_observed_runs(read_lines(args.observed))
                    if args.observed else None)
        findings, gating, notes, pending, content_gating, unexamined = audit(
            args.workflows_dir, args.base_ref, changed, observed,
            args.self_workflow or None)
    except Refusal as exc:
        print("REFUSED: %s" % exc)
        print("ci-trigger-audit refuses to report a clean audit over input it "
              "did not fully understand.")
        return 2
    except OSError as exc:
        print("REFUSED: %s" % exc)
        return 2

    print("=== ci-signal: CI trigger audit ===")
    print("base ref      : %s" % args.base_ref)
    print("changed files : %d" % len(changed))
    for n in notes:
        print("  note: %s" % n)

    # State the gating set out loud. "Nothing gates this PR" is a legitimate
    # outcome (a docs-only tweak, say) but it must be a SENTENCE, never an
    # empty screen that a reader mistakes for a passing check set.
    gapped = [wf for kind, wf, _ in findings if kind == "TRIGGER-GAP"]
    if gating:
        print("gating workflows for this PR: %s" % ", ".join(gating))
    elif gapped:
        # Do NOT say "NONE" here. Nothing is gating this PR, but the reason is
        # the trigger gap itself — and a bare "NONE" reads as "nothing was
        # supposed to gate this", which is the exact misreading the whole
        # check exists to prevent.
        print("gating workflows for this PR: NONE ARE RUNNING — but %s would "
              "have gated it on a listed base. This is the trigger gap, not "
              "an absence of applicable workflows." % ", ".join(gapped))
    else:
        print("gating workflows for this PR: NONE — no workflow's paths "
              "filter matches these changed files. That is an explicit "
              "finding, not an absence of information.")
    if observed is not None:
        if observed:
            # `@N` is appended for any run past attempt 1. This one-line
            # summary is what a reader skims, so the retry has to be visible
            # HERE and not only in a finding further down — the near-miss at
            # d4df844f was a human reading a summary line exactly like this
            # one and seeing nothing to distinguish it from a clean green.
            shown = ", ".join(
                "%s[%s]" % (wf, "/".join(
                    "%s%s" % (r.conclusion or r.status or "?",
                              "@%d" % r.attempt if r.attempt > 1 else "")
                    for r in runs))
                for wf, runs in sorted(observed.items()))
        else:
            shown = "(none)"
        print("runs observed for head sha : %s" % shown)

    # --- band multiplicity (your-org/nexus-code#787) -----------------------
    # Printed for EVERY outcome — green, red, and the expectations-only mode
    # where the answer is "NOT CHECKED" — and printed BEFORE the findings. A
    # reader forms the "this head got clean CI" belief right here, at the
    # summary, which is exactly where #778's two independent enumerations
    # formed it and were wrong. Deliberately OUTSIDE the `observed is not
    # None` guard: a report that simply vanishes when there is no data is
    # indistinguishable from one that looked and found nothing, and that
    # conflation is the whole defect.
    mult_lines, mult_notices = multiplicity_lines(gating, observed)
    for line in mult_lines:
        print(line)
    for n in mult_notices:
        # An annotation, not an error: the verdict is already correct and must
        # not change. This only has to reach the PR page, because that is
        # where the fact was invisible.
        print("::notice::band multiplicity — %s" % n)

    if not findings:
        print()
        # Three terminal states, one selector, and the verdict sentence
        # reachable from exactly one of them (your-org/nexus-code#812). See
        # clearance_report() for why the discriminator is "what could this run
        # answer" and not "was anything wrong".
        try:
            cl_lines, cl_rc = clearance_report(
                gating, pending, observed, content_gating, unexamined,
                len(changed))
        except UnmeasuredClaim as exc:
            # Fail-CLOSED, and to 2 rather than to an uncaught traceback: an
            # uncaught exception exits 1, which on this contract MEANS
            # TRIGGER-GAP — a wrong finding rather than a refusal. 2 is the
            # code that already means "refused to report on input it did not
            # fully understand", and an invariant this file broke about its own
            # data is exactly that.
            print("REFUSED: %s" % exc)
            return 2
        for line in cl_lines:
            print(line)
        return cl_rc

    kinds = set(k for k, _, _ in findings)
    print()
    for kind, wf, msg in findings:
        print("%s: %s" % (kind, wf))
        print("    %s" % msg)

    print()
    if "TRIGGER-GAP" in kinds or "SELF-BROKEN" in kinds:
        print("This PR has LESS CI than it appears to have. An empty or "
              "partial check set is not a passing check set.")
        print("Remedies, in order of preference:")
        print("  1. Retarget this PR onto a base the workflow lists "
              "(usually `dev`). NOTE: changing a base emits only the "
              "`edited` event, so a workflow whose `types:` omit `edited` "
              "will NOT re-run on the retarget alone.")
        print("  2. Dispatch the workflow on this head ref:")
        print("       gh workflow run <workflow>.yml --ref <head-branch>")
        print("     (this audit counts a workflow_dispatch run, because it "
              "asks whether the CODE was tested, not by which event.)")
        return 1

    # A missing run and a non-verdict run are both "no verdict" and both
    # retryable: a real run may still register (MISSING-RUN) or a non-verdict
    # run may be superseded by a real one that is still registering/finishing
    # (NO-VERDICT). They take precedence over FAILED for the RETRY decision so
    # the poll does not settle while a verdict might still arrive — but every
    # finding is printed regardless, so a concurrent FAILED is never hidden.
    if ("MISSING-RUN" in kinds or "NO-VERDICT" in kinds
            or "UNEXECUTED-RUN" in kinds):
        print("At least one gating workflow produced NO VERDICT (no run; a run "
              "whose conclusion is not `success`/`failure`; or a run that "
              "concluded `failure` having executed ZERO steps) for this head "
              "sha. The absence of a verdict is RED. If a real run is still "
              "registering or finishing, re-audit; otherwise this head has no "
              "test evidence and must not be merged.")
        if "UNEXECUTED-RUN" in kinds:
            # The remedy differs from the other two members of this exit code,
            # so it is spelled out rather than folded into "re-audit": nothing
            # about the CODE can clear an unexecuted run, and a reader who
            # treats it as a normal retryable absence will poll a state that
            # will not change on its own.
            print("One of those is an UNEXECUTED-RUN: GitHub created the run, "
                  "labelled it `failure`, and never started a job. That is an "
                  "account/runner-supply problem — billing, a spending limit, "
                  "a quota, an Actions incident — and it will NOT clear by "
                  "waiting or by editing code. Fix the supply, then push or "
                  "re-run.")
        return 4

    if "FAILED" in kinds:
        print("At least one gating workflow FAILED on this head sha. This is a "
              "real verdict, not an absence of one — read the failing run's "
              "logs and fix the code.")
        return 5

    # Only provenance findings remain (#748). Ranked LAST on purpose: exit 6
    # therefore means every gating workflow carries a `success` verdict AND at
    # least one of those greens is not the first thing that head said. That is
    # a narrower, more useful statement than it would be if it could fire
    # alongside a live red.
    print("Every gating workflow carries a `success` verdict for this head "
          "sha — but at least one of those greens is NOT a first-pass green.")
    print("This is the REPLACED-verdict case, and it is a different failure "
          "from a MISSING one. Enumerating that every expected band is named "
          "and `success` — the discipline this repo already applies — catches "
          "a band that never spoke. It cannot catch a band that spoke twice "
          "and had its first answer overwritten, because the band IS named "
          "and IS `success`.")
    print("Not retryable: re-running this check re-reads the same permanent "
          "fact about this sha. Resolve it by deciding whether the superseded "
          "red was a flake or a real defect, fixing whichever it was, and "
          "pushing — a new head sha earns a first-pass verdict.")
    return 6


if __name__ == "__main__":
    sys.exit(main())
