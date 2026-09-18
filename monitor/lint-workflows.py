#!/usr/bin/env python3
"""lint-workflows.py — static properties a CI red must satisfy to reach anyone.

Two rule families, one failure mode: a red that reaches nobody.

  MC  a PR meta-edit must never evict the code run that carries the head's
      verdict (your-org/nexus-code#628, re-found as #736)
  SR  a scheduled workflow must be reachable from the branch it is authored on,
      or it is not coverage — it is a file (#737)
  AU  `apt-get update` must be narrowed to the sources the build consumes and
      never masked (#1505) — documented on `_check_apt_update`

MC is documented immediately below; SR's rationale, boundary and measurement
live on `_check_reachability`.

=============================== RULE FAMILY MC ===============================

THE DEFECT (your-org/nexus-code#628, re-found as #736). A GitHub concurrency
group serialises runs by key. When a workflow lists `edited` in its
`on.pull_request.types` *and* gates its jobs on the base having actually
changed — the repo's standard shape, so a base retarget re-runs CI while a
title/body edit costs no runner minutes (#604) — a pure title/body edit
produces a run whose every job SKIPS. If that skip-run shares a concurrency
group with the real run for the same head sha, the cheap skip evicts the
expensive real one and the head is left carrying `cancelled` + `skipped`:
zero assertions executed, and a rollup that reads clean because neither
conclusion is a `failure`.

`tests.yml` closed this at source by putting the EVENT CLASS in the group key
(`-meta` vs `-code`). `cc-harness.yml` never got the same treatment (#736), and
`docs.yml` is exposed through the other cancel mode (below). Two files, one
property — so this lint checks the PROPERTY over every workflow rather than the
filenames anyone happened to think of. There is no exemption pragma, on purpose:
an exemption is how a property degrades into the two sites its author knew.

BOTH CANCEL MODES EVICT. This is the part `#736` did not state and the reason
this lint does not condition on `cancel-in-progress`:

  cancel-in-progress: true   a queued run CANCELS the IN-PROGRESS run in its
                             group. Skip-run evicts a running code run. This is
                             `cc-harness.yml`'s exposure — the loud one.

  cancel-in-progress: false  runs queue instead, but GitHub keeps only the most
                             recently queued run pending: "Any previously
                             pending job or workflow in the concurrency group
                             will be canceled." So a PENDING code run is
                             cancelled by a later meta-edit run that queues
                             behind the same in-flight run — and a title edit
                             does not move the head, so the cancelled code run
                             and the skipped meta run share a head sha. Same end
                             state, rarer path (it needs three events inside one
                             window). This is `docs.yml`'s exposure.

  no `concurrency:` block    nothing is ever cancelled. Exempt, and that is a
                             fact about GitHub, not a tolerance.

RULES

  MC001  meta-edit eviction. The workflow declares a concurrency group, lists
         `edited` in `on.pull_request.types`, and has at least one job whose
         `if:` is sensitive to the edited action — yet the group key does not
         discriminate the meta-edit event class. The skip-run and the code run
         share a key. This is `#736` verbatim.

  MC002  inert or mismatched split. The group key DOES reference
         `github.event.action`, but a job `if:` also keys on
         `github.event.changes` (the base-retarget discriminator) and the group
         key does not. A base RETARGET is an `edited` event whose jobs RUN, so a
         group keyed on `action == 'edited'` alone drops that job-executing
         retarget into `-meta` alongside title-edit skip-runs — and a title edit
         landing mid-retarget cancels it, giving cancelled(retarget) +
         skipped(title-edit): `#627` reborn INSIDE the remedy. Named by the
         `#628` skeptic; `tests.yml`'s own comment records it as the reason its
         predicate is `edited && !changes.base.ref.from` rather than `edited`.

COVERAGE BOUNDARY (on the axis the mechanism varies on — HOW a job's skip
condition is spelled). This lint decides "this job can skip on a pure meta-edit"
and "this group key discriminates the meta-edit class" by TEXTUAL reference to
`github.event.action` / `github.event.changes` in the `if:` and `group:`
strings. It does not evaluate GitHub expressions, so it cannot confirm the group
predicate is the exact negation of the job condition — MC002 checks the one
mismatch that has actually bitten (a missing `changes` term), not equivalence in
general. A job that skips on a meta-edit WITHOUT naming either field — through an
`env:` indirection, a reusable-workflow input, or a composite expression that
reaches the same place by another route — is outside this boundary and will not
be flagged. Every skip condition in this repo today is written with those
fields, which is why the proxy holds here and why widening the spelling is what
would break it.

=============================== RULE FAMILY SR ===============================

  SR001  a workflow that declares `schedule` and NOTHING that fires from a
         non-default branch is unreachable — unregistered, unrunnable and
         untestable — until it is merged to the default branch. Rationale,
         the measurement behind it and its coverage boundary: see
         `_check_reachability` below.

=============================== RULE FAMILY TD ===============================

  TD001  a step that invokes `monitor/watcher/run-tests.sh` without engaging
         `th_deadline`'s scaling — neither `NEXUS_TEST_DEADLINE_SCALE` set to
         an EFFECTIVE value nor `--jobs N` with N GREATER THAN the runner's
         vCPU count.
         "Effective", not "present": the pin is RESOLVED the way the runtime
         resolves it (innermost scope first — inline `VAR=val` prefix, then
         step/job/workflow `env:`) and a value below 2, a non-numeric value or
         an unevaluatable `${{ }}` expression is a finding. Exempting on mere
         presence let `NEXUS_TEST_DEADLINE_SCALE: 1` through, which th_deadline
         honours as a valid override and which is strictly worse than omitting
         the pin (your-org/nexus-code#1300 R3).
         Rationale, the measurement behind it and its coverage boundary: see
         `_check_deadline_scale` below.

REFUSALS (fail-closed, exit 2). A linter that shrugs at a shape it does not
understand manufactures the silent green it exists to prevent. Refused: an
unreadable or non-mapping workflow file, a missing `on:` block, an `on:` that is
neither a string, list nor mapping, a `jobs:` that is not a mapping, a job that
is not a mapping, a job `if:` that is not a string, a `concurrency:` that is
neither a string nor a mapping, and a `concurrency.group` that is not a string.

=============================== RULE FAMILY PF ===============================

  PF001  a workflow's `paths:` filter omits a file that workflow transitively
         EXECUTES or SOURCES, so a PR changing that file produces no run — an
         absence indistinguishable from a pass (your-org/nexus-code#765, the
         same defect #568 D6 fixed by hand one level down and left half-open).
         The closure is DERIVED from the workflow's own `run:` steps rather
         than maintained by hand, and it is a lower bound whose unresolved
         edges are counted and printed. Rationale, method and the coverage
         boundary: see `_check_path_filter` and `execution_closure` below.

=============================== RULE FAMILY EB ===============================

  EB001  a `run:` body reads `$?`/`${PIPESTATUS[…]}` at a point where errexit
         is live and the status producer ran unprotected, so the branch hanging
         off that read is dead code for exactly the failing case it was written
         for (your-org/nexus-code#784, previously #739 and #779 — five
         instances in three rounds, which is why this is a property and not a
         sixth hand-fix). Rationale, the measurement behind it and its coverage
         boundary — pinned as data and differentially tested against a real
         bash by monitor/test-lint-errexit-branch.sh — see
         `_check_errexit_branch` below.

Exit codes:
  0  every workflow satisfies the property (or is exempt, and the reason is printed)
  1  at least one MC001/MC002/SR001/TD001/PF001/EB001 violation
  2  refusal — a shape this lint does not understand, or bad usage
  3  --selftest failed (the lint did not fail on a planted violation, or fired
     on a planted control)

Run:
  python3 monitor/lint-workflows.py .github/workflows
  python3 monitor/lint-workflows.py --selftest
"""

import argparse
import importlib.util
import os
import re
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_audit():
    """Import monitor/ci-trigger-audit.py as a module for its shared primitives.

    `Refusal`, `ON_KEYS` and `_get_on` are imported rather than re-typed. ON_KEYS
    in particular is not a convenience: PyYAML implements YAML 1.1, which
    resolves the bare key `on` to the boolean True, so EVERY workflow parses with
    True as its trigger key and a lint reading `doc["on"]` finds no triggers and
    reports every file clean. Two copies of that fact is one copy that can drift
    back to the blind spot, in the file whose whole job is to not have one. The
    hyphen in the filename is why this needs importlib rather than `import`.
    """
    path = os.path.join(_HERE, "ci-trigger-audit.py")
    spec = importlib.util.spec_from_file_location("ci_trigger_audit", path)
    if spec is None or spec.loader is None:
        sys.stderr.write(
            "lint-workflows: cannot load %s — refusing to lint "
            "with a re-typed copy of the YAML-1.1 `on:` handling.\n" % path)
        sys.exit(2)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_audit = _load_audit()
Refusal = _audit.Refusal
ON_KEYS = _audit.ON_KEYS
yaml = _audit.yaml

# The two payload fields every meta-edit skip condition in this repo is written
# with. `github.event.action` selects the edit; `github.event.changes` is
# present ONLY when the base branch changed, which is what separates a
# job-executing retarget from a free title edit (#604).
ACTION_REF = "github.event.action"
CHANGES_REF = "github.event.changes"


def _expr_refs(text):
    """Which discriminator fields a GitHub expression string names."""
    return (ACTION_REF in text, CHANGES_REF in text)


def parse_pr_types(doc, path):
    """The `on.pull_request.types` list, or None when there is no PR trigger."""
    on = None
    for k in ON_KEYS:
        if isinstance(doc, dict) and k in doc:
            on = doc[k]
            break
    if on is None:
        raise Refusal("%s: no `on:` trigger block" % path)
    if isinstance(on, str):
        return [] if on == "pull_request" else None
    if isinstance(on, list):
        return [] if "pull_request" in on else None
    if not isinstance(on, dict):
        raise Refusal("%s: `on:` is a %s" % (path, type(on).__name__))
    if "pull_request" not in on:
        return None
    pr = on["pull_request"]
    if pr is None:
        return []
    if not isinstance(pr, dict):
        raise Refusal("%s: `on.pull_request` is a %s"
                      % (path, type(pr).__name__))
    types = pr.get("types")
    if types is None:
        return []
    if isinstance(types, str):
        return [types]
    if not isinstance(types, list):
        raise Refusal("%s: `on.pull_request.types` is a %s; expected a list"
                      % (path, type(types).__name__))
    for t in types:
        if not isinstance(t, str):
            raise Refusal("%s: `on.pull_request.types` holds a non-string (%r)"
                          % (path, t))
    return list(types)


def parse_concurrency(doc, path):
    """The concurrency group key, or None when the workflow declares none.

    `concurrency: <string>` is the shorthand for `concurrency: {group: <string>}`
    and is accepted; anything else is refused rather than guessed at.
    """
    if "concurrency" not in doc:
        return None
    conc = doc["concurrency"]
    if isinstance(conc, str):
        return conc
    if not isinstance(conc, dict):
        raise Refusal("%s: `concurrency` is a %s; expected a string or a mapping"
                      % (path, type(conc).__name__))
    group = conc.get("group")
    if group is None:
        raise Refusal("%s: `concurrency` declares no `group`" % path)
    if not isinstance(group, str):
        raise Refusal("%s: `concurrency.group` is a %s; expected a string"
                      % (path, type(group).__name__))
    return group


def meta_sensitive_jobs(doc, path):
    """Job ids whose `if:` names an edited-action discriminator field.

    Such a job can evaluate FALSE on a pure title/body edit — i.e. its run is a
    skip-run, which is exactly the run that must not share a group with a code
    run. Returns (ids_naming_action_or_changes, ids_naming_changes).
    """
    jobs = doc.get("jobs")
    if jobs is None:
        raise Refusal("%s: no `jobs:` block" % path)
    if not isinstance(jobs, dict):
        raise Refusal("%s: `jobs` is a %s; expected a mapping"
                      % (path, type(jobs).__name__))
    sensitive, with_changes = [], []
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            raise Refusal("%s: job %r is a %s; expected a mapping"
                          % (path, job_id, type(job).__name__))
        if "if" not in job:
            continue
        cond = job["if"]
        if not isinstance(cond, str):
            raise Refusal(
                "%s: job %r has a non-string `if:` (%r). Refusing to guess "
                "whether it can skip on a meta-edit." % (path, job_id, cond))
        names_action, names_changes = _expr_refs(cond)
        if names_action or names_changes:
            sensitive.append(job_id)
        if names_changes:
            with_changes.append(job_id)
    return sensitive, with_changes


def lint_file(path):
    """Return (findings, note). findings is a list of (rule_id, message)."""
    try:
        with open(path, "r") as fh:
            doc = yaml.safe_load(fh)
    except Exception as exc:
        raise Refusal("%s: unparseable (%s)" % (path, exc))
    if not isinstance(doc, dict):
        raise Refusal("%s: top level is not a mapping" % path)

    name = os.path.basename(path)
    mc_findings, mc_note = _check_meta_concurrency(doc, path, name)
    sr_findings, sr_note = _check_reachability(doc, path, name)
    td_findings, td_note = _check_deadline_scale(doc, path, name)
    pf_findings, pf_note = _check_path_filter(doc, path, name)
    eb_findings, eb_note = _check_errexit_branch(doc, path, name)
    au_findings, au_note = _check_apt_update(doc, path, name)
    findings = (mc_findings + sr_findings + td_findings + pf_findings
                + eb_findings + au_findings)
    # A file is reported "exempt" only when EVERY family excused it; if one
    # family checked it, the file was checked. Collapsing the notes into one
    # line keeps the exempt list readable without hiding which family spoke.
    if mc_note and sr_note and td_note and pf_note and eb_note and au_note:
        return findings, "%s; %s; %s; %s; %s; %s" % (mc_note, sr_note, td_note,
                                                     pf_note, eb_note, au_note)
    return findings, None


def _check_meta_concurrency(doc, path, name):
    """Rule family MC — a meta-edit skip-run must not share a key with a code run."""
    types = parse_pr_types(doc, path)
    if types is None:
        return [], "%s: no pull_request trigger — no meta-edit run exists" % name
    if "edited" not in types:
        return [], ("%s: `edited` not in on.pull_request.types — a title/body "
                    "edit produces no run at all" % name)

    group = parse_concurrency(doc, path)
    if group is None:
        return [], ("%s: declares no concurrency group — GitHub cancels nothing, "
                    "so no run can evict another" % name)

    sensitive, with_changes = meta_sensitive_jobs(doc, path)
    if not sensitive:
        return [], ("%s: no job `if:` names %s/%s — the replacement run EXECUTES "
                    "rather than skipping, so it carries a real verdict"
                    % (name, ACTION_REF, CHANGES_REF))

    group_action, group_changes = _expr_refs(group)
    findings = []
    if not group_action and not group_changes:
        findings.append((
            "MC001",
            "job(s) %s skip on a pure meta-edit, but the concurrency group\n"
            "        %s\n"
            "    does not name %s or %s — so the skip-run and the real code run\n"
            "    share one key and the cheap run evicts the expensive one, leaving\n"
            "    this head with cancelled+skipped and zero assertions (#628/#736).\n"
            "    Remedy — mirror the job condition's negation into the key, as\n"
            "    tests.yml does:\n"
            "      group: <prefix>-${{ github.ref }}-${{ (github.event_name == "
            "'pull_request' && github.event.action == 'edited' && "
            "!github.event.changes.base.ref.from) && 'meta' || 'code' }}"
            % (", ".join(sorted(sensitive)), group.strip(),
               ACTION_REF, CHANGES_REF)))
    elif with_changes and not group_changes:
        findings.append((
            "MC002",
            "the concurrency group names %s but NOT %s, while job(s) %s do key on\n"
            "    it. A base RETARGET is an `edited` event whose jobs RUN, so this key\n"
            "    files that job-executing run under the same class as title-edit\n"
            "    skip-runs; a title edit landing mid-retarget cancels it and the head\n"
            "    carries cancelled+skipped again — #627 reborn inside its own remedy\n"
            "    (named by the #628 skeptic). The `-meta` predicate must mirror the\n"
            "    job `if:` EXACTLY: `edited && !changes.base.ref.from`, not `edited`."
            % (ACTION_REF, CHANGES_REF, ", ".join(sorted(with_changes)))))
    return findings, None


# Triggers GitHub will only ever fire from the repository's DEFAULT branch. A
# workflow built solely out of these cannot run — cannot even be REGISTERED —
# from the branch it is authored on.
DEFAULT_BRANCH_ONLY_TRIGGERS = frozenset({"schedule", "workflow_dispatch"})
# Triggers that fire from the ref carrying the workflow file, so a workflow
# holding one of these is exercised on the development branch immediately.
BRANCH_LOCAL_TRIGGERS = frozenset({"pull_request", "pull_request_target", "push"})


def _trigger_names(doc, path):
    on = None
    for k in ON_KEYS:
        if k in doc:
            on = doc[k]
            break
    if on is None:
        raise Refusal("%s: no `on:` trigger block" % path)
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        for t in on:
            if not isinstance(t, str):
                raise Refusal("%s: `on:` list holds a non-string (%r)" % (path, t))
        return set(on)
    if isinstance(on, dict):
        return set(str(k) for k in on)
    raise Refusal("%s: `on:` is a %s" % (path, type(on).__name__))


def _check_reachability(doc, path, name):
    """Rule family SR — a scheduled workflow must be reachable before it is live.

    THE DEFECT (your-org/nexus-code#737, found by measurement rather than by
    reading). `tests-slow-integration.yml` was added on 2026-07-24 to keep the
    SLOW + integration rot visible on a nightly cadence. It triggers on
    `schedule` + `workflow_dispatch` ONLY. GitHub registers and schedules cron
    from the DEFAULT branch, and this repo develops on `dev` while `main` sits
    hundreds of commits behind — so the file never reached the default branch,
    the Actions API returns 404 for the workflow (it is not merely runless, it is
    UNKNOWN to GitHub), and the nightly produced zero ledgers in the thirteen
    days it was believed to be watching. The control that isolates the variable:
    `ci-signal.yml` is ALSO `dev`-only and has 151 runs — because it carries a
    `pull_request` trigger, which fires from the PR head ref.

    The failure is silent in the worst way. A workflow file that is present,
    reviewed, merged and syntactically valid reads as coverage; nothing anywhere
    reports "this workflow has never run". It is the repo's dominant defect class
    — silence used as a proxy for absence — one level above the test suite.

    SR001 therefore requires a `schedule`d workflow to ALSO carry a trigger that
    fires from a non-default branch (`push`, `pull_request`,
    `pull_request_target`), so the workflow is registered, exercised and
    falsifiable on the branch where it is authored rather than going live
    untested — or never going live at all.

    COVERAGE BOUNDARY (on the axis the mechanism varies on — WHERE the file
    lives). This rule is STATIC: it reads trigger declarations and never asks git
    or the Actions API whether the file is present on the default branch, so it
    does not detect an unreachable schedule-only workflow in a repo whose default
    branch IS the development branch, where that shape is harmless. It enforces
    the authoring rule that makes reachability verifiable, not reachability
    itself. Deliberate: a network- or git-dependent check cannot run in an
    offline unit suite without a skip, and a skip is the vacuous pass this file
    exists to prevent.
    """
    triggers = _trigger_names(doc, path)
    if "schedule" not in triggers:
        return [], ("%s: declares no `schedule` — nothing here depends on the "
                    "default branch to fire" % name)
    local = sorted(triggers & BRANCH_LOCAL_TRIGGERS)
    if local:
        return [], None
    return [(
        "SR001",
        "declares `schedule` and nothing but default-branch-only triggers (%s).\n"
        "    GitHub registers and schedules cron from the DEFAULT branch, so on the\n"
        "    branch this file is authored on it cannot run — and until it is merged\n"
        "    to the default branch the Actions API does not know it exists. It goes\n"
        "    live untested, or, in a repo whose default branch lags development,\n"
        "    never goes live at all: #737 is exactly that, thirteen days of a\n"
        "    nightly that had produced zero runs while reading as coverage.\n"
        "    Remedy — add a trigger that fires from the authoring branch\n"
        "    (`push:` with a `branches:`/`paths:` filter is usually right), so the\n"
        "    workflow is registered and falsifiable before it is relied upon."
        % ", ".join(sorted(triggers & DEFAULT_BRANCH_ONLY_TRIGGERS)))], None


# --------------------------------------------------------------------------
# RULE FAMILY TD — deadline scaling that is actually engaged
# --------------------------------------------------------------------------

# GitHub-hosted standard runners. The public-repo ubuntu images are 2-vCPU;
# that number is the DENOMINATOR in th_deadline's ceil(jobs/nproc), so it is
# what decides whether a `--jobs` value engages scaling at all. Larger runners
# are deliberately absent: an unrecognised label is reported as an exemption
# with its reason rather than guessed at, because a wrong denominator would
# manufacture exactly the confident-but-wrong verdict this family exists to
# stop. Add a label here only with a measured vCPU count.
RUNNER_VCPUS = {
    "ubuntu-latest": 2,
    "ubuntu-24.04": 2,
    "ubuntu-22.04": 2,
    "ubuntu-20.04": 2,
}

RUN_TESTS_TOKEN = "monitor/watcher/run-tests.sh"
DEADLINE_SCALE_VAR = "NEXUS_TEST_DEADLINE_SCALE"


def _resolve_deadline_scale(body, step_env, job_env, wf_env):
    """Resolve NEXUS_TEST_DEADLINE_SCALE as the RUNTIME sees it, not as text.

    Returns (value, scope-label) or (None, None). Precedence is INNERMOST
    FIRST, which is what GitHub does and what a text scan gets wrong:

        inline `VAR=val cmd` prefix   >   step `env:`   >   job `env:`   >   workflow `env:`

    The inline form is not exotic — tests-slow-integration.yml's SLOW band
    sets the scale exactly that way (`SLOW_TESTS=1 NEXUS_TEST_DEADLINE_SCALE=2
    env -u ... bash run-tests.sh`), so a resolver that only walked the three
    YAML scopes would report that band UNPINNED and be confidently wrong about
    the one band #749 was filed against (your-org/nexus-code#1300 R3).

    COVERAGE BOUNDARY — read this before trusting a green
    (your-org/nexus-code#1300 R4). This function is HALF semantic and half
    textual, and the halves have different strength:

      * RESOLVED SEMANTICALLY: workflow-, job- and step-scoped `env:`, read
        from the `yaml.safe_load`ed document. Scope precedence here is real.
      * MATCHED BY REGEX: the INLINE scope. It takes the FIRST match in the
        step body where the shell takes the one on the line that actually
        runs, and it applies a `.strip()` the runtime does NOT perform.

    Two measured consequences, stated at the strength each was measured:

      * FALSE GREEN, verified: a decoy earlier in the body — e.g. an
        `echo "NEXUS_TEST_DEADLINE_SCALE=2"` line above a real
        `NEXUS_TEST_DEADLINE_SCALE=1 ... run-tests.sh` — resolves to the
        DECOY and the lint returns rc 0 on a genuinely inert band.
      * MISSTATED REASON, not a false green: a padded value such as `" 1"` is
        flagged, but the finding says the value is `1` and blames
        th_deadline for "honouring a valid override". Measured, th_deadline
        matches `^[0-9]+$`, REJECTS `" 1"`, and falls back to
        ceil(jobs/nproc) — so the direction is safe (it flags) while the
        mechanism named is wrong.

    A trailing `#` does NOT defeat it — measured, `SCALE=1#x` is caught by the
    non-numeric arm. Recorded because it was reported as a defeat and is not
    one here; do not carry that claim forward without re-measuring.

    LIVE COUNT: **0 inert pins across 9 run-tests steps and 6 resolved pins**,
    at e4635e84, clean tree. So this is a RATCHET AGAINST ACCIDENTAL
    REGRESSION, not a proof against a determined edit.

    The cheap improvement, deliberately NOT taken here: switching the regex to
    the LAST match would close the decoy case. It is left undone because the
    fixtures and mutants that vouch for this function were verified against
    THIS implementation, and because last-match is still not semantic — a
    decoy AFTER the real invocation would defeat it in turn. Resolving the
    inline scope properly means parsing the step body as shell, which is a
    different piece of work than a lint rule.
    """
    m = re.search(re.escape(DEADLINE_SCALE_VAR) + r"=([^\s;&|]+)", body or "")
    if m:
        return m.group(1), "inline on the command"
    for scope, label in ((step_env, "step `env:`"),
                         (job_env, "job `env:`"),
                         (wf_env, "workflow `env:`")):
        if isinstance(scope, dict) and DEADLINE_SCALE_VAR in scope:
            return scope[DEADLINE_SCALE_VAR], label
    return None, None


def _strip_shell_comments(text):
    """Drop whole-line `#` comments from a run: block.

    Only whole-line comments. A `#` mid-line can be inside a string or a
    parameter expansion, and mis-stripping one would silently change what the
    rule sees — the failure mode is a MISSED invocation, i.e. a false green.
    """
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        out.append(line)
    return "\n".join(out)


def _matrix_values(job, key):
    """All values `matrix.<key>` can take in this job, or None if undecidable."""
    strategy = job.get("strategy")
    if not isinstance(strategy, dict):
        return None
    matrix = strategy.get("matrix")
    if not isinstance(matrix, dict):
        return None
    values = []
    direct = matrix.get(key)
    if isinstance(direct, list):
        values.extend(direct)
    include = matrix.get("include")
    if isinstance(include, list):
        for entry in include:
            if isinstance(entry, dict) and key in entry:
                values.append(entry[key])
    return values or None


def _jobs_values(run_text, job):
    """Every value `--jobs` takes here.

    Returns (values, undecidable_reason). A `${{ matrix.x }}` argument is
    resolved against the job's matrix, because the INERT cell is the one that
    matters: tests.yml runs `--jobs ${{ matrix.jobs }}` over {2, 4}, and on a
    2-vCPU runner the `2` cell scales by ceil(2/2)=1 while the `4` cell scales
    by 2. A rule that looked only at the largest value would pass a workflow
    half of whose cells are unprotected.
    """
    values = []
    # A regex, not `.split()`. `--jobs ${{ matrix.jobs }}` contains SPACES
    # inside the expression, so whitespace tokenisation yields `${{` as the
    # argument and the rule degrades to "not a literal" — it would have
    # reported tests.yml as undecidable while never seeing the inert `jobs: 2`
    # cell, which is the one case in this repo the rule most needs to catch.
    for raw in re.findall(r"--jobs(?:=|\s+)(\$\{\{.*?\}\}|[^\s\\]+)", run_text):
        raw = raw.strip()
        if raw.isdigit():
            values.append(int(raw))
            continue
        if "matrix." in raw:
            key = raw.split("matrix.", 1)[1]
            key = key.strip().strip("}").strip()
            resolved = _matrix_values(job, key)
            if resolved is None:
                return values, "`--jobs %s` does not resolve to a matrix this rule can read" % raw
            for val in resolved:
                try:
                    values.append(int(val))
                except (TypeError, ValueError):
                    return values, "matrix value %r for `--jobs` is not an integer" % (val,)
            continue
        return values, "`--jobs %s` is not a literal this rule can evaluate" % raw
    return values, None


def _check_deadline_scale(doc, path, name):
    """Rule family TD — a run-tests.sh invocation must ENGAGE deadline scaling.

    THE DEFECT (your-org/nexus-code#749, generalised by #751). `th_deadline()`
    scales every polled deadline by CPU oversubscription, ceil(jobs/nproc),
    where `jobs` is `NEXUS_TEST_JOBS` — which run-tests.sh exports from its own
    `--jobs`. A band passing no `--jobs` gets jobs=1, so on a 2-vCPU runner the
    scale is ceil(1/2) = 1 and every deadline is exactly its literal. The
    deadlines carry comments saying they are scaled, so the code READS as
    protected while it is not. That is how #749 happened, in the band #737 had
    just made blocking.

    WHY `N > nproc` AND NOT `N >= 1`. ceil is not strictly increasing here:
    `--jobs 2` on a 2-vCPU runner is ceil(2/2) = 1, identical to passing
    nothing. Requiring merely "some --jobs" would bless the inert case. This
    was tests.yml's `jobs: 2` matrix cell until your-org/nexus-code#1300 dropped
    it for cost; the shape is still live in this rule's own selftest fixtures
    (`td-jobs-equal-nproc`, `td-matrix-has-inert-cell`), which is where the
    negative control belongs — a rule whose only witness is production config
    stops being tested the day that config changes (#1300 F1).

    WHY THIS IS ENFORCEMENT AND #749 WAS NOT. #749 made the EFFECTIVE scale
    visible in run-tests.sh's own header (`deadline-scale=1`). Visibility
    requires somebody to read a log of a run that already happened; this
    refuses the configuration before it merges.

    STATED COVERAGE BOUNDARY, on the axis the mechanism varies on:

      * This rule is about the INVOCATION, not about whether the tests behind
        it honour the scale. A test that hardcodes a literal deadline instead
        of calling `th_deadline` is invisible here and to #749's header alike —
        both report the scale, neither reports who consults it.
        test-respawn-loop-integration.sh was exactly that case (#752).
      * `--list` invocations are exempt: they enumerate and exit, timing
        nothing.
      * An unrecognised `runs-on` label yields an exemption with its reason
        rather than a guessed vCPU count.
      * A `run:` block is analysed as a whole, so a block containing BOTH a
        scaled and an unscaled invocation is judged by the block. No such block
        exists in this repo today; if one appears, split it.
    """
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        # `jobs:` shape is already refused by the MC family; nothing to add.
        return [], None

    wf_env = doc.get("env") if isinstance(doc.get("env"), dict) else {}
    findings = []
    exempt_reasons = []
    saw_invocation = False

    for job_id, job in sorted(jobs.items()):
        if not isinstance(job, dict):
            continue
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        job_env = job.get("env") if isinstance(job.get("env"), dict) else {}
        runs_on = job.get("runs-on")

        for step in steps:
            if not isinstance(step, dict):
                continue
            run_text = step.get("run")
            if not isinstance(run_text, str):
                continue
            body = _strip_shell_comments(run_text)
            if RUN_TESTS_TOKEN not in body:
                continue
            # A pure `--list` enumerates and exits; it times nothing.
            if "--list" in body and body.count(RUN_TESTS_TOKEN) == 1:
                continue
            saw_invocation = True

            step_env = step.get("env") if isinstance(step.get("env"), dict) else {}
            where = "%s / job `%s`" % (name, job_id)
            step_name = step.get("name")
            if isinstance(step_name, str):
                where += " / step `%s`" % step_name

            # Scale set explicitly anywhere that reaches the process: workflow
            # env, job env, step env, or inline on the command itself.
            #
            # RESOLVE THE VALUE — DO NOT EXEMPT ON PRESENCE
            # (your-org/nexus-code#1300 R3). This arm used to `continue` the
            # moment the variable was MENTIONED in any scope, which made the
            # rule blind to the one edit that actually degrades CI:
            # `NEXUS_TEST_DEADLINE_SCALE: 1`. th_deadline honours that as a
            # VALID override (measured: `th_deadline 10` is 10 at 1 and 20 at
            # 2), so every polled deadline reverts to its bare literal — the
            # #749 state, reached from inside the remedy for #749, by one
            # character. It is STRICTLY WORSE than deleting the pin, which at
            # least falls back to ceil(jobs/nproc).
            #
            # Presence was a PROXY; the property is the resolved VALUE. And it
            # must be resolved the way the RUNTIME resolves it, innermost
            # scope first — a text scan that takes the FIRST match disagrees
            # with GitHub, which takes the LAST enclosing scope, and the
            # disagreement silently favours whichever value makes the check
            # pass.
            scale_raw, scale_scope = _resolve_deadline_scale(
                body, step_env, job_env, wf_env)
            if scale_raw is not None:
                sval = str(scale_raw).strip()
                if "${{" in sval:
                    findings.append((
                        "TD001",
                        "%s sets %s to the expression `%s` (%s).\n"
                        "    Its runtime value cannot be evaluated here, so whether the\n"
                        "    band is scaled is UNKNOWN — reported rather than assumed\n"
                        "    away (fail-closed).\n"
                        % (where, DEADLINE_SCALE_VAR, sval, scale_scope)))
                elif not sval.isdigit():
                    findings.append((
                        "TD001",
                        "%s sets %s to the NON-NUMERIC value `%s` (%s).\n"
                        "    th_deadline matches `^[0-9]+$` and SILENTLY falls back to\n"
                        "    ceil(jobs/nproc), so the pin does not mean what it says and\n"
                        "    nothing reports the discrepancy.\n"
                        % (where, DEADLINE_SCALE_VAR, sval, scale_scope)))
                elif int(sval) < 2:
                    findings.append((
                        "TD001",
                        "%s sets %s=%s (%s).\n"
                        "    th_deadline honours that as a VALID override, so every polled\n"
                        "    deadline is its bare literal — NO scaling at all. This is the\n"
                        "    #749 configuration, and it is WORSE than omitting the pin,\n"
                        "    which would at least fall back to ceil(jobs/nproc).\n"
                        "    Remedy: set %s to 2 or more.\n"
                        % (where, DEADLINE_SCALE_VAR, sval, scale_scope,
                           DEADLINE_SCALE_VAR)))
                continue

            if not isinstance(runs_on, str):
                exempt_reasons.append(
                    "%s: `runs-on` is not a plain label — vCPU count unknown, "
                    "so `--jobs N > nproc` cannot be evaluated" % where)
                continue
            vcpus = RUNNER_VCPUS.get(runs_on)
            if vcpus is None:
                exempt_reasons.append(
                    "%s: runner `%s` has no measured vCPU count in RUNNER_VCPUS"
                    % (where, runs_on))
                continue

            values, undecidable = _jobs_values(body, job)
            remedy = (
                "    Remedy — either make the oversubscription real:\n"
                "      bash monitor/watcher/run-tests.sh --jobs %d ...   "
                "(> %d vCPU, so ceil() > 1)\n"
                "    or state the scale outright, as tests-slow-integration.yml does:\n"
                "      %s: 2\n"
                % (vcpus + 1, vcpus, DEADLINE_SCALE_VAR))

            if undecidable:
                findings.append((
                    "TD001",
                    "%s invokes run-tests.sh and %s.\n"
                    "    Unable to prove the deadline scale is engaged, so this is\n"
                    "    reported rather than assumed away (fail-closed).\n%s"
                    % (where, undecidable, remedy)))
                continue

            if not values:
                findings.append((
                    "TD001",
                    "%s invokes run-tests.sh with NO `--jobs` and no %s.\n"
                    "    jobs defaults to 1, so on a %d-vCPU `%s` th_deadline scales by\n"
                    "    ceil(1/%d) = 1 and every polled deadline is its bare literal —\n"
                    "    while the deadlines carry comments saying they are scaled.\n"
                    "    This is the #749 configuration exactly.\n%s"
                    % (where, DEADLINE_SCALE_VAR, vcpus, runs_on, vcpus, remedy)))
                continue

            inert = sorted({v for v in values if v <= vcpus})
            if inert:
                findings.append((
                    "TD001",
                    "%s invokes run-tests.sh with `--jobs` %s on a %d-vCPU `%s`.\n"
                    "    ceil(jobs/nproc) = 1 for %s, so those runs get NO deadline\n"
                    "    scaling at all — identical to passing no `--jobs`.\n"
                    "    (`--jobs` alone is not enough: ceil(2/2) = ceil(1/2) = 1.)\n%s"
                    % (where,
                       ", ".join(str(v) for v in sorted(set(values))),
                       vcpus, runs_on,
                       ", ".join(str(v) for v in inert),
                       remedy)))

    if findings:
        return findings, None
    if not saw_invocation:
        return [], "%s: invokes no run-tests.sh timing run" % name
    if exempt_reasons:
        return [], "; ".join(exempt_reasons)
    return [], None



# --------------------------------------------------------------------------
# RULE FAMILY AU — `apt-get update` must not fail on a source the build never
# installs from, and must not be masked either
# --------------------------------------------------------------------------
#
# THE DEFECT (your-org/nexus-code#1505). Every job that installs packages
# died in SETUP at 10-16 s — 9 of 10, twice, with the survivor being the one
# job that installs nothing — because `apt-get update` exits 100 when ANY
# configured source fails its index fetch, and the source that failed was
# Google Chrome's, preinstalled on the runner image and never installed from
# by this repo. Its own message said the failure was survivable ("They have
# been ignored, or old ones used instead"); the exit status said otherwise, and
# a single third-party index outage took the whole battery down for every PR
# and for `dev`. Six bare sites in tests.yml, two in tests-slow-integration.yml,
# one in cc-harness.yml, zero mitigations — and `google.*chrome` returns 0 over
# our YAML, so a grep for the offending source reads as "not our problem".
# The exposure is the BARE invocation, which is why this is a lint over the
# construct and not a note about a hostname.
#
#   AU001  a `run:` body invokes `apt-get update` with NO earlier line in the
#          SAME body narrowing /etc/apt/sources.list.d/. The order is the rule:
#          a narrowing AFTER the update protects nothing.
#   AU002  the invocation is masked — `|| true` / `|| :` on the update line.
#          The tempting one-liner and the wrong fix: it converts a genuine
#          failure of the Ubuntu indexes this build DOES need into a
#          mysterious missing-package failure a step later. Reported even
#          when AU001 is satisfied, because masking is wrong on its own.
#
# WHAT IS NOT CHECKED, stated: a retry loop. The shipped remedy retries a
# transient index failure a bounded number of times and then fails loudly,
# but a retry is a courtesy to the transient case, not the property — the
# property is that the source list is narrowed to what the build consumes.
# A step that narrows and does not retry is clean here.

_AU_UPDATE = re.compile(r"\bapt-get\b(?:\s+-{1,2}[\w-]+(?:=\S+)?)*\s+update\b")
_AU_NARROW = re.compile(r"\brm\b.*\s/etc/apt/sources\.list\.d/")
_AU_MASK = re.compile(r"\|\|\s*(?:true|:)(?:\s|;|$)")


def _au_strip_comment(line):
    """Drop a trailing `# …` (at start or after whitespace); quotes are not
    modelled — none of the shapes this family reads carry a quoted `#`."""
    return re.sub(r"(^|\s)#.*$", "", line)


def au_scan(body):
    """Yield (lineno, statement, rule) for every apt-get update in BODY."""
    narrowed = False
    for lineno, raw in enumerate(body.splitlines(), 1):
        line = _au_strip_comment(raw)
        if _AU_NARROW.search(line):
            narrowed = True
        if not _AU_UPDATE.search(line):
            continue
        if _AU_MASK.search(line):
            yield lineno, raw, "AU002"
        if not narrowed:
            yield lineno, raw, "AU001"


def _check_apt_update(doc, path, name):
    """Rule family AU — apt-get update narrowed before, never masked."""
    jobs = doc.get("jobs")
    if jobs is None:
        return [], "%s: no `jobs:` block — no `run:` body to analyse" % name
    if not isinstance(jobs, dict):
        raise Refusal("%s: `jobs:` is not a mapping" % path)
    findings, scanned = [], 0
    for jobname, job in sorted(jobs.items()):
        if not isinstance(job, dict):
            raise Refusal("%s: job %s is not a mapping" % (path, jobname))
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        for step in steps:
            if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                continue
            label = step.get("name") or "(unnamed step)"
            for lineno, stmt, rule in au_scan(step["run"]):
                scanned += 1
                if rule == "AU001":
                    why = ("bare `apt-get update`: it exits 100 when ANY "
                           "configured source fails its index, including the "
                           "runner image's third-party sources this build never "
                           "installs from. Narrow /etc/apt/sources.list.d/ "
                           "BEFORE it in the same body")
                else:
                    why = ("`apt-get update` is MASKED: `|| true` hides a real "
                           "failure of the Ubuntu indexes this build needs and "
                           "moves the red to a missing package a step later. "
                           "Narrow the source list instead of widening the "
                           "tolerance")
                findings.append((
                    rule,
                    "job `%s`, step %r, line %d of its `run:` body:\n"
                    "        %s\n"
                    "    %s (your-org/nexus-code#1505)."
                    % (jobname, label, lineno, stmt.strip()[:100], why)))
            # A clean site still counts as scanned — the note below must not
            # read a narrowed corpus as "nothing to analyse".
            if _AU_UPDATE.search(step["run"]):
                scanned += 1
    if not scanned:
        return [], ("%s: no `run:` body invokes apt-get update — nothing to "
                    "narrow" % name)
    return findings, None


def lint_dir(workflows_dir):
    names = sorted(f for f in os.listdir(workflows_dir)
                   if f.endswith(".yml") or f.endswith(".yaml"))
    if not names:
        raise Refusal("%s: no workflow files — refusing to report a clean lint "
                      "over an empty set" % workflows_dir)
    all_findings, notes, checked = [], [], []
    for n in names:
        findings, note = lint_file(os.path.join(workflows_dir, n))
        if note:
            notes.append("  exempt: %s" % note)
        else:
            checked.append(n)
        for rule, msg in findings:
            all_findings.append((rule, n, msg))
    return all_findings, notes, names, checked


# --------------------------------------------------------------------------
# RULE FAMILY PF — a `paths:` filter that covers what the workflow RUNS
# --------------------------------------------------------------------------
#
# THE DEFECT (your-org/nexus-code#765, and #568 D6 one level down). A workflow
# with a `paths:` filter only runs when a changed file matches it. If the filter
# omits a file the workflow EXECUTES, then a PR changing that file gets no run —
# and the absence is indistinguishable from a pass. #765's instance: cc-harness
# .yml omitted `monitor/watcher/run-tests.sh`, the runner the workflow itself
# invokes, and `monitor/watcher/_test_helpers.sh`, which every realmodel
# scenario sources. So a PR changing the real-binary runner received ZERO
# real-binary evidence, with thirteen green check-runs and a full enumeration
# satisfying this repo's merge discipline.
#
# WHY THIS IS A DERIVATION AND NOT TWO MORE LINES IN A LIST. #568 D6 already
# fixed this once, by hand, adding `_idle_probe.sh` and `_over_limit.sh` under
# a comment stating the principle exactly: "the realmodel scenarios SOURCE
# these two modules, so a change to either changes what this workflow proves —
# yet neither was in the filter." The same sentence was true of the runner and
# the helpers, and they were not added. A hand-maintained list of a workflow's
# transitive dependencies re-acquires the hole every time the workflow grows
# one, because nothing recomputes it. What the workflow executes and what its
# scripts source is COMPUTABLE, so it is computed here.
#
#   PF001  a file in the workflow's derived execution closure is not covered by
#          that workflow's own `paths:` filter.
#
# THE CLOSURE IS A LOWER BOUND, AND THAT IS SAID OUT LOUD RATHER THAN HOPED
# OVER. Static resolution of shell cannot be complete: a path built from a
# runtime variable (`$NEXUS_ROOT/...`, `$CCH_DIR/...`) is genuinely undecidable
# here. Every such reference is COUNTED AND PRINTED as an unresolved edge, so
# the reader knows exactly how much of the closure this rule could not see.
# Silence about them would be the defect class this file is written in.
#
# CONSEQUENCES OF THE BOUND, both directions:
#   - a file this rule DOES name is genuinely executed and genuinely uncovered:
#     a true positive, which is why PF001 is a finding rather than a note;
#   - a file it does NOT name may still be executed via an unresolved edge, so
#     a clean PF result is "no hole found on the resolvable edges", NEVER "the
#     filter is complete". The output says so in those words.
#
# WHAT IS DELIBERATELY NOT CHECKED: whether a filter entry is SUPERFLUOUS. The
# closure being a lower bound makes "this pattern matches nothing I derived"
# evidence of nothing, and over-inclusion costs runner minutes without ever
# hiding evidence. A rule that cannot distinguish a stale entry from an
# unresolved edge should not pretend to, so it does not.

_CLOSURE_EXT = (".sh", ".py", ".jq")

# workflow name -> (resolved file count, unresolved edge count), so the CLEAN
# report can quantify its own coverage instead of only asserting it is bounded.
_PF_COVERAGE = {}

# `VAR=$(cd <expr> && pwd)` — the two idioms this repo builds every script-dir
# variable with (200+ and 39 occurrences respectively at the time of writing).
_DIR_ASSIGN = re.compile(
    r'^[ \t]*(?:export[ \t]+|local[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)='
    r'\$\([ \t]*cd[ \t]+(.+?)&&[ \t]*pwd', re.M)
# Any token naming a shell/python/jq file by a path. Requiring a `/` is what
# keeps this from matching prose; it also means a bare `foo.sh` with no
# directory is out of scope, which is correct — such a reference could not be
# resolved to a repo file anyway.
_PATH_TOKEN = re.compile(
    r'(?<![\w-])((?:[A-Za-z0-9_${}\[\]./-])*?/[A-Za-z0-9_${}\[\]./*-]*?'
    r'(?:\.sh|\.py|\.jq))(?![\w])')
_VAR_REF = re.compile(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?')
# The INLINE script-dir substitution — `. "$(dirname "$0")/dep.sh"` — used ~27
# times here alongside the bound-variable idiom. Rewritten to a synthetic
# variable so one resolver handles both, rather than a second code path that
# can drift from the first.
#
# The four shapes are ENUMERATED rather than matched loosely on purpose: a
# permissive pattern would silently swallow some other `$(dirname …)` whose
# argument is not the script itself and resolve it to the wrong directory,
# which is a confidently wrong edge. Anything not listed here stays
# unresolved — and unresolved is REPORTED, so the failure mode of this
# enumeration being incomplete is an undercount that says so, not a lie.
_SELFDIR = "__SELFDIR__"
_SELF_DIR_SUBST = re.compile(
    r'\$\(\s*dirname\s+"(?:'
    r'\$\(\s*readlink\s+-f\s+"(?:\$\{BASH_SOURCE\[0\]\}|\$0)"\s*\)'
    r'|\$\{BASH_SOURCE\[0\]\}|\$0'
    r')"\s*\)')
# A `run:` step body. Only `run:` blocks seed the closure: `uses:` steps are
# third-party actions, not this repo's files.
_RUN_BLOCK = re.compile(r'run:\s*\|?(.*?)(?=\n\s{6}- |\n\s{4}\w|\Z)', re.S)


def _strip_comment_lines(text):
    """Drop whole-line `#` comments.

    Load-bearing, not tidiness: `monitor/cc-harness/_lib.sh` mentions
    `test-integration/_harness.sh` four times in PROSE and executes it zero
    times. Counting a comment as an edge would manufacture dependencies and
    then demand the filter cover them.
    """
    return "\n".join(l for l in text.splitlines()
                     if not l.lstrip().startswith("#"))


def _bind_dir_vars(text, self_dir):
    """Map script-dir variable -> absolute directory, for one file's text.

    Two passes over the assignments rather than one, because the repo's second
    idiom builds a variable OUT OF the first (`_repo_root=$(cd "$_test_dir/../.."
    && pwd)`) and a single forward pass would miss it whenever the assignments
    are not in dependency order.
    """
    bound = {_SELFDIR: self_dir}
    for _ in range(3):
        for m in _DIR_ASSIGN.finditer(text):
            var, expr = m.group(1), m.group(2)
            if "BASH_SOURCE" in expr or re.search(r'\$\{?0\}?', expr):
                base = self_dir
            else:
                base = None
                for v in _VAR_REF.findall(expr):
                    if v in bound:
                        base = bound[v]
                        break
            if base is None:
                continue
            tail = re.findall(r'(?:\)|\}|\w)((?:/\.\.)+|(?:/[\w.-]+)+)"', expr)
            suffix = tail[-1].lstrip("/") if tail else ""
            bound[var] = os.path.normpath(
                os.path.join(base, suffix) if suffix else base)
    return bound


def _resolve_token(tok, bound, self_dir):
    """Absolute path for a path token, or None when a variable is unbound."""
    unresolved = []

    def sub(m):
        v = m.group(1)
        if v in bound:
            return bound[v]
        unresolved.append(v)
        return ""

    t = _VAR_REF.sub(sub, tok)
    if unresolved:
        return None
    if not t.startswith("/"):
        t = os.path.join(self_dir, t)
    return os.path.normpath(t)


def execution_closure(workflow_path, repo_root):
    """Files a workflow transitively executes or sources.

    Returns (closure, unresolved) — `closure` a sorted list of repo-relative
    paths, `unresolved` a sorted list of (referrer, token) edges that could not
    be resolved statically. Both are returned because reporting the first
    without the second would state a lower bound as if it were the answer.
    """
    import glob as _glob

    try:
        with open(workflow_path, "r") as fh:
            wf_text = fh.read()
    except OSError as exc:
        raise Refusal("%s: unreadable (%s)" % (workflow_path, exc))

    todo = []
    for block in _RUN_BLOCK.findall(wf_text):
        for tok in _PATH_TOKEN.findall(_strip_comment_lines(block)):
            if "$" in tok:          # a workflow-level expression, e.g. ${{ }}
                continue
            todo.append(os.path.join(repo_root, tok))

    seen, unresolved = set(), set()
    while todo:
        path = todo.pop()
        for p in (_glob.glob(path) if "*" in path else [path]):
            rel = os.path.relpath(p, repo_root)
            if rel.startswith("..") or rel in seen:
                continue
            if not rel.endswith(_CLOSURE_EXT) or not os.path.isfile(p):
                continue
            seen.add(rel)
            try:
                with open(p, "r", errors="replace") as fh:
                    body = _strip_comment_lines(fh.read())
            except OSError:
                continue
            body = _SELF_DIR_SUBST.sub("${%s}" % _SELFDIR, body)
            d = os.path.dirname(os.path.abspath(p))
            bound = _bind_dir_vars(body, d)
            for tok in set(_PATH_TOKEN.findall(body)):
                r = _resolve_token(tok, bound, d)
                if r is None:
                    unresolved.add((rel, tok))
                else:
                    todo.append(r)
    return sorted(seen), sorted(unresolved)


def _check_path_filter(doc, path, name, repo_root=None):
    """Rule family PF — the `paths:` filter must cover what the workflow runs."""
    if repo_root is None:
        repo_root = os.path.dirname(os.path.dirname(
            os.path.dirname(os.path.abspath(path))))

    # Same ON_KEYS walk the other families use — PyYAML resolves the bare key
    # `on` to the BOOLEAN True under YAML 1.1, so `doc["on"]` finds nothing and
    # reports every workflow clean.
    on = None
    for k in ON_KEYS:
        if isinstance(doc, dict) and k in doc:
            on = doc[k]
            break
    if on is None:
        raise Refusal("%s: no `on:` trigger block" % path)
    pr = on.get("pull_request") if isinstance(on, dict) else None
    patterns = pr.get("paths") if isinstance(pr, dict) else None
    if patterns is None:
        # No filter means the workflow runs on every PR into its listed bases.
        # There is no hole to have. This is the shape ci-signal.yml is required
        # to keep, so it must be an EXEMPTION and never a violation.
        return [], ("%s: no `on.pull_request.paths` filter — it cannot omit "
                    "anything" % name)
    if not isinstance(patterns, list):
        raise Refusal("%s: on.pull_request.paths is not a list" % path)

    closure, unresolved = execution_closure(path, repo_root)
    # Record the derivation's own size for the CLEAN path to report. The
    # finding path already prints these numbers; the clean path used to print
    # only prose ("no hole was found on the edges it could follow"), and GREEN
    # is precisely where a reader over-reads a bounded claim into an unbounded
    # one. On cc-harness.yml the derivation resolves 24 files and CANNOT
    # resolve 22 references — nearly half the edges are invisible, and a reader
    # who is not told that will read rc 0 as "the filter is complete".
    _PF_COVERAGE[name] = (len(closure), len(unresolved))
    if not closure:
        # Nothing derivable: a workflow whose steps run no repo file (or a
        # fixture outside a repo). Stated, because a silent empty closure would
        # make every such workflow report clean for the wrong reason.
        return [], ("%s: no repo file is reachable from its `run:` steps — "
                    "nothing to derive a filter from" % name)

    try:
        regexes = [_audit.gh_glob_to_regex(p) for p in patterns]
    except Refusal:
        # Negated patterns: the audit refuses to guess GitHub's ordering, and
        # so does this. Propagated, not swallowed.
        raise

    missing = [f for f in closure
               if not any(rx.match(f) for rx in regexes)]
    if not missing:
        return [], None

    return [(
        "PF001",
        "its `paths:` filter does not cover %d file(s) this workflow "
        "transitively EXECUTES or SOURCES: %s. A PR changing any of them "
        "produces NO run of this workflow, and that absence is "
        "indistinguishable from a pass (your-org/nexus-code#765). Derived from "
        "the workflow's own `run:` steps: %d file(s) reachable, %d reference(s) "
        "unresolvable and therefore NOT covered by this finding%s."
        % (len(missing), ", ".join(missing), len(closure), len(unresolved),
           ("" if not unresolved else
            " (e.g. %s)" % ", ".join("%s -> %s" % u for u in unresolved[:3]))))], None


# --------------------------------------------------------------------------
# RULE FAMILY EB — a status branch that is REACHABLE under errexit
# --------------------------------------------------------------------------
#
# THE DEFECT (your-org/nexus-code#784, previously #739 and #779). GitHub runs
# every `run:` body under `/usr/bin/bash -e {0}`. `set -uo pipefail` is the
# repo's habitual opener and it does NOT clear `-e`. So a body that runs a
# command and then reads `$?` / `${PIPESTATUS[…]}` to dispatch on it has
# already died at the command: the read, and every branch hanging off it, is
# DEAD CODE for exactly the non-zero case the branch was written for.
#
# Measured under bash 5.2 (CI's pin), not reasoned:
#
#   bash -e -c 'set -uo pipefail;    (exit 3) | tee /dev/null; echo REACHED'
#     -> prints nothing, exits 3
#   bash -e -c 'set +e -uo pipefail; (exit 3) | tee /dev/null; echo REACHED'
#     -> prints REACHED, exits 0
#
# WHY A LINT AND NOT A SIXTH HAND-FIX. This has now been found five times in
# three rounds, and the shape is invisible at review because the green path is
# unaffected — it fires only when the command is red, i.e. on the runs that
# matter. #739 fixed the SLOW band step. #779 fixed ci-signal's audit step,
# whose entire `case "$rc"` dispatch had been dead for every non-zero rc, so not
# one `::error::ci-signal:` explanation was ever emitted. #784 filed a third
# instance — the SIBLING step of #739's, in the same file — and enumerating the
# PROPERTY rather than the filenames then turned up two MORE that #784 itself
# did not know about, both in tests.yml, both capturing the command's output
# into a variable that the abort meant was never printed. Two hand-fixes at two
# call sites did not close the class; a third would not have either.
#
#   EB001  a `run:` body reads `$?` or `${PIPESTATUS[…]}` at a point where
#          errexit is live and the command that produced that status ran
#          UNPROTECTED, so the read is unreachable whenever the status is
#          non-zero.
#
# THE REMEDY THE FINDING NAMES is `|| rc=$?` (with `rc` pre-initialised), NOT
# `set +e`. Both work; the first makes the intent explicit in the code, so a
# later edit cannot silently resurrect the defect by moving a line. This is the
# same argument tests-slow-integration.yml's own #739 comment makes.
#
# COVERAGE BOUNDARY, on the axis the MECHANISM varies on — which is HOW THE
# STATUS PRODUCER IS PROTECTED FROM ERREXIT, not which files were searched.
# bash exempts a failing command from `-e` in a fixed set of syntactic
# positions, and this family's whole job is to agree with that set. Prose
# cannot be made to fail, so the boundary is pinned as DATA and DIFFERENTIALLY
# tested against the real shell by monitor/test-lint-errexit-branch.sh: every
# shape in its manifest is executed under a real bash with a failing producer to
# observe whether the branch is REACHED, and the lint's verdict must agree with
# what bash did. A shape the lint calls safe that bash aborts is a red there.
#
# What this family CANNOT see, stated because a clean EB is otherwise
# over-read: heredoc bodies are skipped (they are data for another interpreter,
# not statements of this shell), so a status branch inside a generated script is
# not analysed; errexit state is tracked through literal `set` commands only, so
# a body that toggles `-e` through a variable, a sourced file or an `eval` is
# analysed under the wrong assumption; and the producer is taken to be the
# preceding statement in program order, which is right for straight-line code
# and approximate across a function definition called later.
_EB_SET_RE = re.compile(r"^\s*set\s+(?P<args>[-+][^;]*)$")
_EB_STATUS_RE = re.compile(r"\$\?|\$\{?PIPESTATUS\b")
# `case … in` is here for the same reason as `if`: its word expansion cannot
# fail, so a `$?` read inside a branch observes whatever ran BEFORE the case.
# Measured — `set -uo pipefail; false || true; case x in x) echo $?;; esac`
# reaches, and this rule flagged it until the manifest row was added.
_EB_COMPOUND_HEAD = re.compile(r"^\s*(if|elif|while|until|case)\b")
# OPENERS ONLY. A bare opener standing alone as a statement means the real
# status producer is the compound's CONDITION, which bash already exempted;
# without this, every `if …; then` + `$?`-on-the-next-line reads as a violation.
#
# The CLOSERS (`fi`, `done`, `esac`, `}`) are deliberately NOT here, and that is
# a correction rather than an omission: a command that fails INSIDE a `then`
# block or a loop body aborts the step exactly as it would anywhere else, so a
# read after the closer cannot observe it. Measured:
#   bash -e -c 'set -uo pipefail; if true; then false; fi; rc=$?; echo REACHED'
#     -> nothing, exit 1
# Exempting closers was therefore a MISSED detection, the dangerous direction.
# The residual conservatism is the converse case — a compound whose body did NOT
# fail (`if false; then :; fi; rc=$?`) is flagged though bash reaches it. That
# is outside the manifest's stated precondition (every shape there has a
# producer that FAILS), it is a rare shape in a `run:` body, and the remedy is
# one `|| rc=$?`. Erring toward the false alarm is the correct direction for a
# rule whose miss is a silently dead diagnostic.
_EB_CONTROL_ONLY = frozenset({"then", "else", "do", "{", "("})
# The only statements that CANNOT fail, and therefore the only ones whose
# presence as the final element of a `||`/`&&` list keeps a following `$?` read
# reachable. `cmd || rc=$?` is safe because `rc=$?` always succeeds; `cmd1 ||
# cmd2` is NOT, because a failing cmd2 is the final element of the list and
# errexit fires on it.
_EB_ASSIGN_WORD = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
_EB_DECL_KW = re.compile(r"^(local|declare|export|readonly|typeset)\s+")
_EB_SET_CMD = re.compile(r"^set\s+[-+]")


def _eb_words(stmt):
    """Split a statement on UNQUOTED whitespace."""
    words, cur, quote = [], "", None
    for c in stmt.strip():
        if quote:
            cur += c
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
            cur += c
        elif c.isspace():
            if cur:
                words.append(cur)
                cur = ""
        else:
            cur += c
    if cur:
        words.append(cur)
    return words


def _eb_cannot_fail(stmt):
    """True when this statement has no way to return non-zero.

    The distinction that matters, and the one a regex got wrong: an
    ENV-PREFIXED COMMAND (`SLOW_TESTS=1 env -u X bash run-tests.sh`) looks like
    an assignment at its left edge and is a command. Reading it as a
    can't-fail assignment silently un-detected two of the five known #784
    instances — caught by the historical replay, then pinned as the
    `env-prefixed-command` row of monitor/test-lint-errexit-branch.sh.
    """
    s = stmt.strip()
    if s in ("true", ":"):
        return True
    if _EB_SET_CMD.match(s):
        return True
    s = _EB_DECL_KW.sub("", s)
    # A command substitution or backtick can fail, and its status becomes the
    # assignment's — this is the instance-4 shape, so it is never can't-fail.
    if "$(" in s or "`" in s:
        return False
    words = _eb_words(s)
    if not words:
        return False
    # EVERY word must be an assignment. One that is not means the assignments
    # were an environment prefix and this is a command.
    return all(_EB_ASSIGN_WORD.match(w) for w in words)
# GitHub's `shell:` keys and whether the interpreter they select has errexit on
# by default. `bash` (the explicit key, not the default) is
# `bash --noprofile --norc -eo pipefail {0}`; the DEFAULT (no key at all) is
# `bash -e {0}`. Both are errexit-on, which is why this repo declaring zero
# `shell:` keys leaves every body exposed rather than protected.
_EB_ERREXIT_SHELLS = frozenset({"bash", "sh"})
_EB_NON_SHELL = frozenset({"python", "pwsh", "powershell", "cmd"})
_EB_SEP = re.compile(r"(\|\||&&|;;|;|\||&)")


def _eb_strip(body):
    """Drop comments and heredoc BODIES, returning (lineno, text) pairs.

    A heredoc body is data handed to another program, not a statement of this
    shell — analysing it would flag the contents of a generated script that
    this step never executes under `-e`. tests.yml's `-p`-stripping tmux shim
    is exactly that shape.
    """
    out, pending = [], []
    lines = body.split("\n")
    for i, raw in enumerate(lines):
        if pending:
            term, dashed = pending[0]
            probe = raw.lstrip("\t") if dashed else raw
            if probe.strip() == term and (dashed or raw.rstrip() == term):
                pending.pop(0)
            continue
        text, quote, j = [], None, 0
        while j < len(raw):
            c = raw[j]
            if quote:
                if c == "\\" and quote == '"':
                    text.append(c)
                    j += 1
                    if j < len(raw):
                        text.append(raw[j])
                    j += 1
                    continue
                if c == quote:
                    quote = None
                text.append(c)
            elif c in "'\"":
                quote = c
                text.append(c)
            elif c == "\\":
                text.append(c)
                j += 1
                if j < len(raw):
                    text.append(raw[j])
                j += 1
                continue
            elif c == "#" and (not text or text[-1].isspace()):
                break
            else:
                text.append(c)
            j += 1
        line = "".join(text)
        for m in re.finditer(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", line):
            pending.append((m.group(3), bool(m.group(1))))
        out.append((i + 1, line))
    return out


def _eb_unbalanced_dq(s):
    quote, j = None, 0
    while j < len(s):
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if quote:
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        j += 1
    return quote == '"'


def _eb_logical_lines(pairs):
    """Join backslash-continued and open-quote lines into logical lines."""
    joined, buf, start = [], "", None
    for lineno, line in pairs:
        if start is None:
            start = lineno
        buf = line if not buf else buf + " " + line.strip()
        if buf.endswith("\\"):
            buf = buf[:-1]
            continue
        if buf.count("'") % 2 or _eb_unbalanced_dq(buf):
            buf += "\n"
            continue
        joined.append((start, buf))
        buf, start = "", None
    if buf.strip():
        joined.append((start, buf))
    return joined


def _eb_statements(logical):
    """Split one logical line into (text, preceding-operator) at top level."""
    parts, cur, quote, depth, j, prev_op = [], "", None, 0, 0, None
    while j < len(logical):
        c = logical[j]
        if quote:
            cur += c
            if c == "\\" and quote == '"':
                j += 1
                if j < len(logical):
                    cur += logical[j]
            elif c == quote:
                quote = None
            j += 1
            continue
        if c == "\\":
            cur += c
            j += 1
            if j < len(logical):
                cur += logical[j]
            j += 1
            continue
        if c in "'\"":
            quote = c
            cur += c
            j += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth = max(0, depth - 1)
        if depth == 0:
            m = _EB_SEP.match(logical, j)
            if m:
                parts.append((cur, prev_op))
                prev_op, cur, j = m.group(1), "", m.end()
                continue
        cur += c
        j += 1
    parts.append((cur, prev_op))
    return [(t, o) for t, o in parts if t.strip() or o]


def _eb_set_after(stmt, errexit, pipefail):
    """Apply a literal `set` command to the tracked (errexit, pipefail) state.

    `pipefail` is tracked because it decides whether a PIPELINE can fail from
    any element or only from its last: `cmd1 | cmd2; rc=${PIPESTATUS[0]}` with
    pipefail OFF observes a failing `cmd1` perfectly well, so flagging it would
    be a false alarm. With pipefail ON — which is what every body in this repo
    actually sets — the pipeline fails and the step aborts before the read.
    """
    m = _EB_SET_RE.match(stmt)
    if not m:
        return errexit, pipefail
    toks = m.group("args").split()
    i = 0
    while i < len(toks):
        tok = toks[i]
        if tok.startswith("--"):
            i += 1
            continue
        if tok[:1] in ("-", "+"):
            on = tok[0] == "-"
            if "e" in tok[1:]:
                errexit = on
            # `-o name` / the combined `-uo pipefail`: the option NAME is the
            # next token, not a letter in this one.
            if "o" in tok[1:] and i + 1 < len(toks):
                if toks[i + 1] == "pipefail":
                    pipefail = on
                i += 1
        i += 1
    return errexit, pipefail


def eb_scan(body, errexit=True, pipefail=False):
    """Return [(lineno, statement, reason)] for every UNREACHABLE status read.

    `errexit` is the state the interpreter starts in — True for GitHub's
    default `bash -e {0}` and for an explicit `shell: bash`/`sh`. `pipefail`
    starts off for the default shell; an explicit `shell: bash` turns it on
    (`bash --noprofile --norc -eo pipefail {0}`).
    """
    findings = []
    prev_stmt, prev_op = None, None
    for lineno, line in _eb_logical_lines(_eb_strip(body)):
        for stmt, op in _eb_statements(line):
            s = stmt.strip()
            if not s:
                if op:
                    prev_op = op
                continue
            if _EB_STATUS_RE.search(s) and errexit:
                reason = _eb_unprotected(s, op, prev_stmt, prev_op, pipefail)
                if reason:
                    findings.append((lineno, s, reason))
            errexit, pipefail = _eb_set_after(s, errexit, pipefail)
            prev_stmt, prev_op = s, op
    return findings


def _eb_unprotected(stmt, op, prev_stmt, prev_op, pipefail):
    """Return a reason string if this status read is unreachable, else None.

    The exemptions mirror bash's own, and each arm below names the rule it
    mirrors. They are NOT a list anyone should trust from reading: every one is
    adjudicated against a real bash by monitor/test-lint-errexit-branch.sh,
    which is where two of these arms came from after the shell disagreed with
    what this docstring used to claim.
    """
    if op in ("||", "&&"):
        # `cmd || rc=$?` — the read IS the final element, so `cmd` was exempt
        # and its status survives to be read. This is the remedy shape.
        return None
    if prev_stmt is None:
        # First statement of the body: `$?` is the shell's entry status, and no
        # command in this body produced it.
        return None
    if _EB_COMPOUND_HEAD.match(prev_stmt) or prev_stmt.strip() in _EB_CONTROL_ONLY:
        return None
    if prev_op == ";;":
        # The preceding statement is a SIBLING `case` branch. Exactly one branch
        # of a `case` executes, so that branch's last command never ran and
        # cannot be this read's producer — the producer is whatever ran before
        # the `case`, which the compound-head arm above already exempted.
        return None
    if _eb_cannot_fail(prev_stmt):
        # The preceding statement cannot fail — a `set`, a plain assignment,
        # `true`, `:`. There is no non-zero status for errexit to have aborted
        # on, so the read is reachable and reads 0. Checked in EVERY position,
        # not only inside a `||` list: `set -uo pipefail` followed by `rc=$?`
        # is the shape that caught this, found by the manifest in
        # monitor/test-lint-errexit-branch.sh rather than by inspection.
        return None
    if prev_op in ("||", "&&"):
        # The producer is the FINAL element of a `&&`/`||` list. bash exempts
        # every element but that one, so a failing one still aborts.
        return ("the status comes from `%s`, the final element of a `%s` list "
                "— bash exempts every element of such a list EXCEPT the last, "
                "so a non-zero there still aborts the step before this read"
                % (prev_stmt.strip()[:60], prev_op))
    if prev_op == "|" and not pipefail:
        # Without pipefail a pipeline's status is its LAST element's, so a
        # non-zero from an earlier stage — the case `${PIPESTATUS[0]}` is
        # written to observe — does not abort anything and the read is
        # reachable. Declared as a boundary rather than flagged: the narrower
        # residual risk (the last stage itself failing) is a different claim,
        # and manufacturing a finding here would be a false alarm on a body
        # that behaves exactly as written.
        return None
    return ("`%s` runs unprotected under errexit, so a non-zero status aborts "
            "the step before this read — the branch below it is dead code for "
            "exactly the failing case it was written for. Remedy: initialise "
            "`rc=0` and append `|| rc=$?` to that command"
            % prev_stmt.strip()[:70])


def _eb_step_errexit(step, name, jobname):
    """Return (errexit_state, pipefail_state, exemption-note) for a `run:` body.

    GitHub's DEFAULT (no `shell:` key) is `bash -e {0}` — errexit on, pipefail
    OFF. The explicit `shell: bash` is a different command line,
    `bash --noprofile --norc -eo pipefail {0}` — both on. The distinction
    matters to EB because pipefail decides whether a pipeline producer can fail
    from any stage.
    """
    shell = step.get("shell")
    if shell is None:
        return True, False, None
    if not isinstance(shell, str):
        raise Refusal("%s: job %s has a non-string `shell:`" % (name, jobname))
    head = shell.strip().split()[0] if shell.strip() else ""
    if head in _EB_NON_SHELL:
        return None, None, "`shell: %s` is not a POSIX shell" % head
    if head in _EB_ERREXIT_SHELLS and "{0}" not in shell:
        return True, head == "bash", None
    # A custom template (`bash -x {0}`, …) replaces GitHub's flags outright, so
    # errexit is on only if the template says so. Read the flags rather than
    # assuming either way: assuming ON would manufacture findings on a body
    # that is genuinely safe, and assuming OFF would hide real ones.
    flags = shell.split("{0}")[0]
    on = bool(re.search(r"(^|\s)-[a-zA-Z]*e[a-zA-Z]*(\s|$)", flags)
              or "-o errexit" in flags)
    if on:
        return True, "pipefail" in flags, None
    return None, None, ("`shell: %s` sets no `-e`, so errexit is off for this "
                        "body" % shell.strip())


def _check_errexit_branch(doc, path, name):
    """Rule family EB — a status branch must be REACHABLE under errexit."""
    jobs = doc.get("jobs")
    if jobs is None:
        return [], "%s: no `jobs:` block — no `run:` body to analyse" % name
    if not isinstance(jobs, dict):
        raise Refusal("%s: `jobs:` is not a mapping" % path)

    findings, scanned = [], 0
    for jobname, job in sorted(jobs.items()):
        if not isinstance(job, dict):
            raise Refusal("%s: job %s is not a mapping" % (path, jobname))
        steps = job.get("steps")
        if not isinstance(steps, list):
            continue
        defaults = job.get("defaults")
        job_shell = None
        if isinstance(defaults, dict) and isinstance(defaults.get("run"), dict):
            job_shell = defaults["run"].get("shell")
        for step in steps:
            if not isinstance(step, dict) or not isinstance(step.get("run"), str):
                continue
            probe = dict(step)
            if probe.get("shell") is None and job_shell is not None:
                probe["shell"] = job_shell
            errexit, pipefail, _why = _eb_step_errexit(probe, name, jobname)
            if errexit is None:
                continue
            scanned += 1
            label = step.get("name") or "(unnamed step)"
            # Where errexit CAME FROM, named per step. A step that declares its
            # own `shell:` did not get `-e` from GitHub's default, and telling
            # its author otherwise sends them looking for a default that is not
            # in play.
            origin = ("GitHub runs `run:` bodies under `bash -e {0}` and `set "
                      "-uo pipefail` does NOT clear `-e`"
                      if probe.get("shell") is None else
                      "this step's own `shell: %s` sets `-e`"
                      % str(probe.get("shell")).strip())
            for lineno, stmt, reason in eb_scan(step["run"], errexit, pipefail):
                findings.append((
                    "EB001",
                    "job `%s`, step %r, line %d of its `run:` body:\n"
                    "        %s\n"
                    "    %s. %s (your-org/nexus-code#784)."
                    % (jobname, label, lineno, stmt.strip()[:100], reason,
                       origin)))
    if not scanned:
        return [], ("%s: no `run:` body runs under errexit — nothing can lose "
                    "a status branch" % name)
    return findings, None


# --------------------------------------------------------------------------
# --selftest: the NEGATIVE CONTROL. A guard never observed failing is not
# evidence, so every rule is watched to fire on a violation planted on purpose
# AND to stay silent on a control that merely looks like one. The fixtures are
# the real shapes: the pre-fix cc-harness key, the pre-fix docs key (the
# cancel-in-progress:false path), the #628-skeptic near-miss, and the two
# legitimately-exempt shapes this repo actually ships.
# --------------------------------------------------------------------------

_JOB_IF = ("github.event_name != 'pull_request' || github.event.action != "
           "'edited' || github.event.changes.base.ref.from")
_SPLIT = ("x-${{ github.ref }}-${{ (github.event_name == 'pull_request' && "
          "github.event.action == 'edited' && "
          "!github.event.changes.base.ref.from) && 'meta' || 'code' }}")

FIXTURES = [
    # (name, yaml, expected rule ids in output, why)
    ("cc-harness-prefix", """
on:
  pull_request:
    types: [opened, synchronize, reopened, edited, ready_for_review]
concurrency:
  group: cc-harness-${{ github.ref }}
  cancel-in-progress: true
jobs:
  realmodel-harness:
    if: %s
    runs-on: ubuntu-latest
""" % _JOB_IF, ["MC001"], "the #736 head: cancel-in-progress true, unsplit key"),

    ("docs-prefix-no-cancel", """
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]
concurrency:
  group: docs-${{ github.ref }}
  cancel-in-progress: false
jobs:
  build:
    if: %s
    runs-on: ubuntu-latest
""" % _JOB_IF, ["MC001"],
     "cancel-in-progress FALSE still evicts a PENDING code run — the rule must "
     "not be conditioned on the cancel mode"),

    ("split-on-action-only", """
on:
  pull_request:
    types: [opened, synchronize, edited]
concurrency:
  group: x-${{ github.ref }}-${{ github.event.action == 'edited' && 'meta' || 'code' }}
  cancel-in-progress: true
jobs:
  build:
    if: %s
    runs-on: ubuntu-latest
""" % _JOB_IF, ["MC002"],
     "the #628-skeptic near-miss: a retarget filed next to title-edit skip-runs"),

    ("tests-yml-shape", """
on:
  pull_request:
    types: [opened, synchronize, reopened, edited, ready_for_review]
concurrency:
  group: %s
  cancel-in-progress: true
jobs:
  syntax:
    if: %s
    runs-on: ubuntu-latest
""" % (_SPLIT, _JOB_IF), [], "the remediated shape — control, must stay silent"),

    ("ci-signal-shape", """
on:
  pull_request:
    types: [opened, synchronize, reopened, edited, ready_for_review]
concurrency:
  group: ci-signal-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  ci-signal:
    runs-on: ubuntu-latest
""", [], "no job `if:` — the replacement run EXECUTES, so it carries a verdict"),

    ("no-concurrency", """
on:
  pull_request:
    types: [opened, synchronize, edited]
jobs:
  build:
    if: %s
    runs-on: ubuntu-latest
""" % _JOB_IF, [], "no group — GitHub cancels nothing"),

    ("no-edited-type", """
on:
  pull_request:
    types: [opened, synchronize]
concurrency:
  group: x-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build:
    if: %s
    runs-on: ubuntu-latest
""" % _JOB_IF, [], "a title edit produces no run at all"),

    # The YAML 1.1 trap, as its own fixture: `on:` resolves to the boolean True.
    # If ON_KEYS ever regressed to the string "on" alone, EVERY workflow would
    # read as trigger-less and this violation would go silent — which is the
    # blind spot, not a pass. The fixture is identical to cc-harness-prefix; only
    # the assertion that it is still SEEN is the point.
    ("yaml11-on-is-boolean-true", """
"on":
  pull_request:
    types: [edited, synchronize]
concurrency:
  group: x-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build:
    if: %s
    runs-on: ubuntu-latest
""" % _JOB_IF, ["MC001"], "quoted `on` — must be seen identically to bare `on`"),

    # --- rule family SR -----------------------------------------------------
    ("schedule-only", """
on:
  schedule:
    - cron: '0 7 * * *'
  workflow_dispatch:
jobs:
  band:
    runs-on: ubuntu-latest
""", ["SR001"], "the #737 head: cron that can never fire from the authoring branch"),

    ("schedule-plus-push", """
on:
  schedule:
    - cron: '0 7 * * *'
  workflow_dispatch:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
""", [], "a push trigger registers it and exercises it on the dev branch"),

    ("schedule-plus-pull-request", """
on:
  schedule:
    - cron: '0 7 * * *'
  pull_request:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
""", [], "a pull_request trigger fires from the PR head ref — ci-signal's shape"),

    ("dispatch-only-no-schedule", """
on:
  workflow_dispatch:
jobs:
  band:
    runs-on: ubuntu-latest
""", [], "no `schedule` — nothing here silently depends on the default branch"),

    # SR must be independent of MC: a file can violate BOTH, and reporting only
    # the first family checked is how a second defect rides in behind a fixed
    # one. This fixture is the cross-term.
    ("both-families-violated", """
on:
  schedule:
    - cron: '0 7 * * *'
  pull_request:
    types: [edited, synchronize]
concurrency:
  group: x-${{ github.ref }}
  cancel-in-progress: true
jobs:
  build:
    if: %s
    runs-on: ubuntu-latest
""" % _JOB_IF, ["MC001"],
     "schedule + pull_request: SR is satisfied by the PR trigger, MC is not"),

    # ---- rule family TD -----------------------------------------------------
    # A `push`-only trigger with no concurrency block keeps MC and SR silent, so
    # each fixture isolates TD. The planted violations are the two REAL shapes
    # (#749's band, and tests.yml's `jobs: 2` matrix cell); the controls are the
    # three legitimate ways to satisfy the property.
    ("td-no-jobs", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    steps:
      - name: run the band
        run: bash monitor/watcher/run-tests.sh --state ledger.tsv
""", ["TD001"], "the #749 head: no --jobs, no scale => ceil(1/2) = 1, inert"),

    ("td-jobs-equal-nproc", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    steps:
      - name: run the band
        run: bash monitor/watcher/run-tests.sh --jobs 2 tests
""", ["TD001"],
     "--jobs 2 on 2 vCPU is ceil(2/2) = 1 — passing SOME --jobs is not enough"),

    ("td-matrix-has-inert-cell", """
on:
  push:
    branches: [dev]
jobs:
  unit:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - jobs: 2
          - jobs: 4
    steps:
      - name: run unit suite
        run: bash monitor/watcher/run-tests.sh --jobs ${{ matrix.jobs }} tests
""", ["TD001"],
     "tests.yml's shape: the `4` cell scales, the `2` cell does not — the rule "
     "must judge the INERT cell, not the largest"),

    ("td-jobs-oversubscribed", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    steps:
      - name: run the band
        run: bash monitor/watcher/run-tests.sh --jobs 4 tests
""", [], "--jobs 4 on 2 vCPU is ceil(4/2) = 2 — genuinely oversubscribed"),

    ("td-scale-explicit-job-env", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    env:
      NEXUS_TEST_DEADLINE_SCALE: 2
    steps:
      - name: run the band
        run: bash monitor/watcher/run-tests.sh --state ledger.tsv
""", [], "the scale is stated outright, so no --jobs is needed"),

    # The VALUE arms (your-org/nexus-code#1300 R3). The positive control for
    # `td-scale-explicit-job-env` above proves an explicit scale EXEMPTS the
    # step; these three prove the exemption is conditional on the value being
    # effective, which is what "presence is a proxy" cost three rounds to see.
    ("td-scale-inert-value-one", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    env:
      NEXUS_TEST_DEADLINE_SCALE: 1
    steps:
      - name: run the band
        run: bash monitor/watcher/run-tests.sh --state ledger.tsv
""", ["TD001"], "scale 1 is a VALID override th_deadline honours — every "
     "deadline reverts to its bare literal, worse than omitting the pin"),

    ("td-scale-step-overrides-job", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    env:
      NEXUS_TEST_DEADLINE_SCALE: 2
    steps:
      - name: run the band
        env:
          NEXUS_TEST_DEADLINE_SCALE: 1
        run: bash monitor/watcher/run-tests.sh --state ledger.tsv
""", ["TD001"], "GitHub resolves the INNERMOST scope, so the effective value "
     "is 1 while the job env still reads 2 — a first-match text scan reports OK"),

    ("td-scale-non-numeric", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    env:
      NEXUS_TEST_DEADLINE_SCALE: two
    steps:
      - name: run the band
        run: bash monitor/watcher/run-tests.sh --state ledger.tsv
""", ["TD001"], "th_deadline matches ^[0-9]+$ and silently falls back to "
     "ceil(jobs/nproc) — the pin does not mean what it says"),

    ("td-list-only", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    steps:
      - name: enumerate
        run: bash monitor/watcher/run-tests.sh --list | grep -c integration
""", [], "--list enumerates and exits — it times nothing, so it is exempt"),

    ("td-commented-out-invocation", """
on:
  push:
    branches: [dev]
jobs:
  band:
    runs-on: ubuntu-latest
    steps:
      - name: not actually running it
        run: |
          # bash monitor/watcher/run-tests.sh --state ledger.tsv
          echo "nothing to do"
""", [], "a commented-out invocation is not an invocation"),

    # --- EB: the five real instances, reduced to their shapes, plus the
    #     controls that separate the property from its spelling. The full
    #     protection-shape manifest is differentially tested against a real
    #     bash by monitor/test-lint-errexit-branch.sh; these are the fixtures
    #     that keep the RULE watched inside the lint's own selftest.
    ("eb-bare-then-read", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: instance 3
        run: |
          set -uo pipefail
          bash monitor/band.sh --resume
          rc=$?
          [ "$rc" -ne 3 ] && break
""", ["EB001"], "the #784 instance-3 shape: bare invocation, then `rc=$?`"),

    ("eb-assignment-cmdsub", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: instance 4
        run: |
          set -uo pipefail
          out=$(bash monitor/probe.sh 2>&1); rc=$?
          printf '%s\\n' "$out"
""", ["EB001"],
     "an assignment whose command substitution fails IS a failing command — "
     "the instance-4 shape, which #784's own enumeration missed"),

    ("eb-pipestatus", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: instance 2
        run: |
          set -uo pipefail
          python3 monitor/ci-trigger-audit.py | tee /tmp/audit.txt
          rc=${PIPESTATUS[0]}
""", ["EB001"], "the #779 shape — PIPESTATUS, not `$?`; the rule is the "
                "property, not the spelling"),

    ("eb-echo-status-inline", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: instance 1
        run: |
          set -uo pipefail
          bash monitor/band.sh --state ledger.tsv
          echo "run-tests exit=$? (the VERDICT is the drift check below)"
""", ["EB001"], "the #739 shape — the read is inside an `echo`, never assigned "
                "to `rc`; a lint keyed on `rc=$?` would miss it"),

    ("eb-remedy-or-rc", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: the remedy
        run: |
          set -uo pipefail
          rc=0
          bash monitor/band.sh --resume || rc=$?
          case "$rc" in 0|1) ;; *) exit 1 ;; esac
""", [], "`|| rc=$?` — the read is the final element of the list, so the "
         "producer was exempt and its status survives"),

    ("eb-set-plus-e", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: errexit explicitly cleared
        run: |
          set +e -uo pipefail
          python3 monitor/ci-trigger-audit.py | tee /tmp/audit.txt
          rc=${PIPESTATUS[0]}
""", [], "errexit cleared before the producer — ci-signal's shipped remedy"),

    ("eb-if-condition", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: status read inside a compound
        run: |
          set -uo pipefail
          if bash monitor/band.sh; then
            echo "green $?"
          fi
""", [], "bash exempts the condition of `if`, so the read is reachable"),

    ("eb-heredoc-body", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: generated script is data, not statements
        run: |
          set -uo pipefail
          cat > /tmp/gen.sh <<'SCRIPT'
          some-command
          rc=$?
          SCRIPT
          bash /tmp/gen.sh
""", [], "a heredoc body is handed to another interpreter — this step never "
         "runs those lines under its own `-e`"),

    ("eb-non-shell", """
on: [push]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - name: python is not a shell
        shell: python
        run: |
          import subprocess
          rc = subprocess.call(["true"])
""", [], "`shell: python` has no errexit to lose a branch to"),
    # --- AU: apt-get update narrowed before, never masked (#1505) ---------
    ("au-bare", """
on:
  pull_request:
    branches: [dev]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends jq
""", ["AU001"], "the #1505 head: a bare apt-get update, nine of them shipped"),

    ("au-narrowed", """
on:
  pull_request:
    branches: [dev]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: |
          sudo rm -f /etc/apt/sources.list.d/google-chrome*
          for i in 1 2 3; do sudo apt-get update && break; [ "$i" -lt 3 ] || exit 1; sleep 15; done
          sudo apt-get install -y --no-install-recommends jq
""", [], "the shipped remedy is clean — else AU001 fires on everything"),

    ("au-narrowed-after", """
on:
  pull_request:
    branches: [dev]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: |
          sudo apt-get update
          sudo rm -f /etc/apt/sources.list.d/google-chrome*
""", ["AU001"], "ORDER is the rule: a narrowing after the update protects nothing"),

    ("au-masked", """
on:
  pull_request:
    branches: [dev]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: |
          sudo rm -f /etc/apt/sources.list.d/google-chrome*
          sudo apt-get update || true
          sudo apt-get install -y jq
""", ["AU002"], "narrowed AND masked: the wrong fix is reported on its own"),

    ("au-masked-bare", """
on:
  pull_request:
    branches: [dev]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: sudo apt-get update || true
""", ["AU001", "AU002"], "the tempting one-liner earns both rules"),

    ("au-other-step-narrowed", """
on:
  pull_request:
    branches: [dev]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: sudo rm -f /etc/apt/sources.list.d/google-chrome*
      - run: sudo apt-get update
""", ["AU001"], "SAME BODY is the rule: a narrowing in another step is not seen"),

    ("au-comment-only", """
on:
  pull_request:
    branches: [dev]
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: |
          # we used to run apt-get update here
          echo nothing
""", [], "a mention in a comment is not an invocation"),

]

REFUSAL_FIXTURES = [
    ("job-if-not-a-string", """
on:
  pull_request:
    types: [edited]
concurrency:
  group: x-${{ github.ref }}
jobs:
  build:
    if: true
    runs-on: ubuntu-latest
""", "a non-string `if:` is refused, never read as 'does not skip'"),

    ("concurrency-without-group", """
on:
  pull_request:
    types: [edited]
concurrency:
  cancel-in-progress: true
jobs:
  build:
    if: %s
    runs-on: ubuntu-latest
""" % _JOB_IF, "a concurrency block with no group is refused, not treated as absent"),

    ("jobs-not-a-mapping", """
on:
  pull_request:
    types: [edited]
concurrency:
  group: x-${{ github.ref }}
jobs:
  - build
""", "a jobs: list is refused rather than read as zero sensitive jobs"),
]


def selftest():
    ok = True
    tmp = tempfile.mkdtemp(prefix="lint-meta-conc-")

    print("-- planted violations + controls (one fixture per shape) --")
    for name, body, expected, why in FIXTURES:
        path = os.path.join(tmp, "%s.yml" % name)
        with open(path, "w") as fh:
            fh.write(body)
        try:
            findings, _note = lint_file(path)
        except Refusal as exc:
            print("  FAIL %-28s REFUSED unexpectedly: %s" % (name, exc))
            ok = False
            continue
        got = sorted({r for r, _m in findings})
        want = sorted(expected)
        if got == want:
            print("  ok   %-28s -> %-14s %s"
                  % (name, ",".join(got) or "(clean)", why))
        else:
            print("  FAIL %-28s want %s, got %s  [%s]"
                  % (name, want or "(clean)", got or "(clean)", why))
            ok = False

    print("-- fail-closed refusals (a shape the lint does not understand) --")
    for name, body, why in REFUSAL_FIXTURES:
        path = os.path.join(tmp, "%s.yml" % name)
        with open(path, "w") as fh:
            fh.write(body)
        try:
            lint_file(path)
        except Refusal:
            print("  ok   %-28s -> REFUSED       %s" % (name, why))
            continue
        print("  FAIL %-28s did not refuse: %s" % (name, why))
        ok = False

    # --- PF: needs a REPO, not a flat fixture -----------------------------
    #
    # The fixtures above are lone .yml files, so PF exempts them ("no repo file
    # is reachable"). PF001 is about the relationship between a filter and the
    # files on disk that the workflow reaches, so its fixtures have to be small
    # repositories. Four shapes, chosen so a pass means something:
    #
    #   uncovered   the rule FIRES on a real omission
    #   covered     it stays silent when the filter is adequate  (else it is a
    #               rule that always fires, and `uncovered` proves nothing)
    #   comment     a path mentioned only in PROSE is not an edge — the exact
    #               shape of `_harness.sh` in monitor/cc-harness/_lib.sh, which
    #               names it four times and executes it never
    #   vardir      `. "$_d/dep.sh"` with `_d` bound from BASH_SOURCE resolves
    #               — this is the ONLY mechanism by which #765's real omission
    #               (`_test_helpers.sh`) is reachable, so a resolver that
    #               quietly stopped handling it would report cc-harness.yml
    #               clean and this whole family would be decorative
    print("-- PF: planted repos (the filter-vs-closure property) --")
    _pf_cases = [
        ("pf-uncovered", "  . \"$(dirname \"$0\")/dep.sh\"\n",
         ["monitor/entry.sh"], ["PF001"],
         "an executed file outside the filter is named"),
        ("pf-covered", "  . \"$(dirname \"$0\")/dep.sh\"\n",
         ["monitor/**"], [],
         "an adequate filter is silent — so the fire above is the omission"),
        ("pf-comment-only", "  # see monitor/dep.sh for why\n  true\n",
         ["monitor/entry.sh"], [],
         "a path named only in a comment is not an executed edge"),
        ("pf-vardir",
         "  _d=$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\n"
         "  . \"$_d/dep.sh\"\n",
         ["monitor/entry.sh"], ["PF001"],
         "a $scriptdir/dep.sh source resolves — the #765 mechanism itself"),
    ]
    for case, entry_body, patterns, expected, why in _pf_cases:
        root = os.path.join(tmp, case)
        os.makedirs(os.path.join(root, ".github", "workflows"), exist_ok=True)
        os.makedirs(os.path.join(root, "monitor"), exist_ok=True)
        with open(os.path.join(root, "monitor", "entry.sh"), "w") as fh:
            fh.write("#!/usr/bin/env bash\n" + entry_body)
        with open(os.path.join(root, "monitor", "dep.sh"), "w") as fh:
            fh.write("#!/usr/bin/env bash\ntrue\n")
        wf = os.path.join(root, ".github", "workflows", "w.yml")
        with open(wf, "w") as fh:
            fh.write(
                "on:\n  pull_request:\n    branches: [dev]\n    paths:\n"
                + "".join("      - '%s'\n" % p for p in patterns)
                + "jobs:\n  b:\n    runs-on: ubuntu-latest\n    steps:\n"
                  "      - run: bash monitor/entry.sh\n")
        try:
            with open(wf) as fh:
                doc = yaml.safe_load(fh)
            findings, _n = _check_path_filter(doc, wf, "w.yml", repo_root=root)
        except Refusal as exc:
            print("  FAIL %-28s REFUSED unexpectedly: %s" % (case, exc))
            ok = False
            continue
        got = sorted({r for r, _m in findings})
        if got == sorted(expected):
            print("  ok   %-28s -> %-14s %s"
                  % (case, ",".join(got) or "(clean)", why))
        else:
            print("  FAIL %-28s want %s, got %s  [%s]"
                  % (case, expected or "(clean)", got or "(clean)", why))
            ok = False

    # The empty-directory refusal: a lint that reports "clean" over nothing is
    # the failure mode, not a pass.
    empty = os.path.join(tmp, "empty")
    os.makedirs(empty, exist_ok=True)
    try:
        lint_dir(empty)
        print("  FAIL %-28s reported clean over an empty workflows dir"
              % "empty-dir-refusal")
        ok = False
    except Refusal:
        print("  ok   %-28s -> REFUSED       an empty set is not a clean set"
              % "empty-dir-refusal")

    print()
    print("SELFTEST %s" % ("PASSED" if ok else "FAILED"))
    return 0 if ok else 3


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("workflows_dir", nargs="?",
                    help="directory of workflow files (e.g. .github/workflows)")
    ap.add_argument("--selftest", action="store_true",
                    help="run the negative control and exit")
    # EB only. Exists so monitor/test-lint-errexit-branch.sh can put ONE shell
    # snippet through this exact scanner and through a REAL bash, and assert
    # the two agree. Without it that test would have to re-implement the
    # module load, i.e. test a copy.
    ap.add_argument("--scan-body", metavar="FILE",
                    help="scan one shell snippet as if it were a `run:` body "
                         "under GitHub's default `bash -e {0}`; prints one "
                         "`EB001 <line> <statement>` per unreachable status "
                         "read. Exit 1 if any, 0 if none.")
    ap.add_argument("--pipefail", action="store_true",
                    help="with --scan-body: start with pipefail already on")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if args.scan_body:
        try:
            with open(args.scan_body, "r") as fh:
                body = fh.read()
        except OSError as exc:
            print("REFUSED: %s" % exc)
            return 2
        hits = eb_scan(body, True, args.pipefail)
        for lineno, stmt, reason in hits:
            print("EB001 %d %s" % (lineno, stmt.strip()))
            print("      %s" % reason)
        return 1 if hits else 0
    if not args.workflows_dir:
        sys.stderr.write("usage: %s <workflows-dir> | --selftest\n"
                         % os.path.basename(sys.argv[0]))
        return 2

    try:
        findings, notes, names, checked = lint_dir(args.workflows_dir)
    except Refusal as exc:
        print("REFUSED: %s" % exc)
        print("lint-workflows refuses to report a clean lint "
              "over input it did not fully understand.")
        return 2
    except OSError as exc:
        print("REFUSED: %s" % exc)
        return 2

    print("=== workflow lint: MC (meta-edit eviction) + SR (schedule reachability)"
          " + TD (deadline scaling engaged) + PF (paths filter covers what the "
          "workflow runs) + EB (status branch reachable under errexit) + AU "
          "(apt-get update narrowed, never masked) over %d file(s) ===" % len(names))
    for n in notes:
        print(n)
    # State the CHECKED set out loud. "Everything was exempt" is a legitimate
    # outcome and a silent one is indistinguishable from a lint that ran over
    # nothing — the shape this repo keeps paying for. So it is a sentence.
    if checked:
        print("  checked (the property applies): %s" % ", ".join(checked))
    else:
        print("  checked (the property applies): NONE — every workflow was "
              "exempt for a reason printed above. That is a finding about the "
              "corpus, not a clean lint.")

    if not findings:
        print()
        print("OK: no workflow lets a PR meta-edit's skip-run evict the code run "
              "that carries its head's verdict; every scheduled workflow is "
              "reachable; every run-tests.sh invocation engages deadline "
              "scaling; no `paths:` filter omits a file its own workflow "
              "executes; no `run:` body branches on a status errexit "
              "already aborted on; and every `apt-get update` is narrowed to "
              "the sources the build consumes and never masked.")
        # The PF half is a LOWER BOUND and the clean line must not be read as
        # more than it is. Same rule as everywhere else here: the boundary is
        # declared where the reader forms the belief, not in a docstring.
        print("    PF scope: derived from statically resolvable `run:`/source "
              "edges. A path built from a runtime variable cannot be resolved "
              "and is NOT covered by this pass — a clean PF result means no "
              "hole was found on the edges it could follow, not that the "
              "filters are complete.")
        # The NUMBERS, on the green path, not only on the red one. Prose about
        # a bound is easy to skim past; "22 unresolved" is not.
        for n in sorted(_PF_COVERAGE):
            got, miss = _PF_COVERAGE[n]
            if got or miss:
                print("      %-32s %d file(s) resolved, %d reference(s) NOT "
                      "resolved (invisible to PF)" % (n, got, miss))
        return 0

    print()
    for rule, wf, msg in findings:
        print("%s: %s" % (rule, wf))
        print("    %s" % msg)
    print()
    # Print only the closing argument each family's findings earn. A trailer
    # about concurrency keys under a lone SR001 is a plausible-sounding
    # misdirection, and this file exists to stop exactly that.
    kinds = {rule for rule, _wf, _msg in findings}
    if any(k.startswith("MC") for k in kinds):
        print("MC: a head whose run was cancelled and whose replacement skipped "
              "carries NO verdict, and a rollup reads that as clean because "
              "neither conclusion is a `failure`. Fix the group key at source; "
              "ci-signal's verdict invariant is the backstop, not the remedy.")
    if any(k.startswith("SR") for k in kinds):
        print("SR: a workflow file that has never run is not coverage. Give it a "
              "trigger that fires from the branch it is authored on, so it is "
              "registered and falsifiable before anything is believed about it.")
    if any(k.startswith("EB") for k in kinds):
        print("EB: the step still goes RED — what is lost is the SENTENCE "
              "saying why. Every `::error::` explanation, every captured "
              "output, every enumerated disposition below that read is dead "
              "code on precisely the runs that produce a failure, and the "
              "green path is unaffected, so review cannot see it. Fix with "
              "`rc=0` + `|| rc=$?` on the command, not with `set +e`: the "
              "explicit form survives a later edit moving a line.")
    if any(k.startswith("AU") for k in kinds):
        print("AU: a bare `apt-get update` fails the whole battery on an index "
              "outage of a source this build never installs from, and a masked "
              "one hides the outage of a source it does. Narrow "
              "/etc/apt/sources.list.d/ before the update, in the same body; "
              "retry if you like; never `|| true`.")
    if any(k.startswith("PF") for k in kinds):
        print("PF: a workflow that does not run on a change to the code it "
              "executes provides no evidence about that change — and the "
              "missing run is indistinguishable from a passing one, so a "
              "reviewer doing everything right merges it (#765). Add the named "
              "files to the filter. Do NOT treat the list as complete: it is "
              "what could be derived, so re-run this lint after editing rather "
              "than assuming the closure stopped there.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
