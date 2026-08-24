#!/usr/bin/env python3
"""ci-uncovered-paths.py — which tracked files can no workflow examine?

THE DEFECT THIS MEASURES (your-org/nexus-code#856, generalising #853). A
workflow's `paths:` filter decides whether it fires for a diff. A file matching
NO `paths:` filter of any suite-running workflow is a file whose PR runs no
suite — and on a repo that also has an unconditional workflow (one with no
`paths:` key, firing on every PR), that PR still shows green checks. The green
is real and is evidence about something other than the change.

WHY A SEPARATE COMMAND AND NOT A LINT. The answer is not a pass/fail. Plenty of
files legitimately have no suite: a LICENSE, a changelog, an editor config.
What matters is that the set is KNOWN and its growth is deliberate, because the
dangerous member is not the LICENSE — it is the directory that HAS a suite
reading it and was never wired into a `paths:` filter. This command cannot tell
those apart either; it hands you the list so a person can.

  monitor/ci-uncovered-paths.py [--workflows-dir DIR] [--suite WF]... [--quiet]

Exit codes:
  0  every tracked file is examined by at least one suite-running workflow
  1  some are not — the count and the members are printed
  2  refusal: could not enumerate (no git, no workflows, unparsable workflow)

ENUMERATION. `git ls-files`, never `git ls-tree` with a glob pathspec —
`ls-tree` pathspecs are path PREFIXES, not globs, so a glob there returns zero
hits at rc 0, which reads as "nothing tracked". Same family of confident-zero as
the defect being measured.

GLOB SEMANTICS ARE NOT REIMPLEMENTED. GitHub's `*` stops at `/` and `**` crosses
it, which is neither fnmatch nor shell globbing. This imports the expansion from
monitor/ci-trigger-audit.py, so this command and the audit that gates PRs can
never disagree about what a filter matches — a second implementation would
answer a different question and the difference would look like a finding.
"""

import argparse
import collections
import importlib.util
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_audit():
    path = os.path.join(_HERE, "ci-trigger-audit.py")
    spec = importlib.util.spec_from_file_location("_cta", path)
    if spec is None:
        raise SystemExit("ci-uncovered-paths: cannot load %s" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--workflows-dir", default=".github/workflows")
    # Which workflows count as EXAMINING a file. Declared rather than guessed:
    # `docs.yml` fires for `docs/**` and runs `mkdocs build`, which is a real
    # check and reads nothing about a suite. Defaulting to the suite runners
    # keeps the question "is this file tested", not "does anything fire".
    ap.add_argument("--suite", action="append", default=None,
                    help="workflow basename that runs a test suite (repeatable; "
                         "default: tests.yml, tests-slow-integration.yml, "
                         "cc-harness.yml)")
    ap.add_argument("--all-workflows", action="store_true",
                    help="count ANY paths-filtered workflow as examining a file, "
                         "not only the suite runners")
    ap.add_argument("--quiet", action="store_true", help="counts only")
    args = ap.parse_args()

    cta = _load_audit()

    try:
        out = subprocess.check_output(["git", "ls-files"])
    except (subprocess.CalledProcessError, OSError) as exc:
        print("REFUSED: could not run `git ls-files` (%s). Refusing to report a "
              "coverage result over a population it could not enumerate." % exc)
        return 2
    files = [f for f in out.decode("utf-8", "replace").splitlines() if f.strip()]
    if not files:
        print("REFUSED: `git ls-files` returned nothing. An empty population "
              "would make every coverage claim below vacuously true.")
        return 2

    wfdir = args.workflows_dir
    if not os.path.isdir(wfdir):
        print("REFUSED: %s is not a directory" % wfdir)
        return 2
    names = sorted(f for f in os.listdir(wfdir)
                   if f.endswith(".yml") or f.endswith(".yaml"))
    if not names:
        print("REFUSED: %s holds no workflow files — refusing to report that "
              "every file is uncovered when the real answer is that nothing "
              "was read." % wfdir)
        return 2

    default_suites = ("tests.yml", "tests-slow-integration.yml", "cc-harness.yml")
    suites = set(args.suite) if args.suite else set(default_suites)

    selectors = []       # (workflow, patterns) that can EXAMINE a file
    unconditional = []   # fire on every PR and filter nothing
    for n in names:
        try:
            trig = cta.parse_workflow(os.path.join(wfdir, n))
        except cta.Refusal as exc:
            print("REFUSED: %s: %s" % (n, exc))
            return 2
        if trig is None:
            continue
        if trig["paths"] is None:
            unconditional.append(n)
            continue
        if args.all_workflows or n in suites:
            selectors.append((n, trig["paths"]))

    if not selectors:
        print("REFUSED: no workflow in %s both carries a `paths:` filter and "
              "counts as examining a file. Every file would read as uncovered, "
              "which is a statement about this command's inputs and not about "
              "the repo." % wfdir)
        return 2

    uncovered = [f for f in files
                 if not any(cta.path_matches(p, [f]) for _, p in selectors)]

    print("tracked files            : %d" % len(files))
    print("examining workflows      : %s"
          % ", ".join(n for n, _ in selectors))
    if unconditional:
        # Named explicitly, because these are the reason an uncovered PR still
        # shows green checks. Without this line a reader sees "0 workflows
        # examine this file" and cannot reconcile it with a green PR page.
        print("unconditional workflows  : %s  (no `paths:` filter — these fire on "
              "EVERY PR, so an uncovered PR still shows green checks that read "
              "none of its files)" % ", ".join(unconditional))
    print("uncovered                : %d" % len(uncovered))

    if not uncovered:
        print()
        print("OK: every tracked file matches at least one examining workflow's "
              "`paths:` filter.")
        return 0

    groups = collections.defaultdict(list)
    for f in uncovered:
        groups[f.split("/")[0] if "/" in f else "<root>"].append(f)

    print()
    print("UNCOVERED, by top-level path:")
    for k in sorted(groups, key=lambda k: (-len(groups[k]), k)):
        print("  %-28s %d" % (k, len(groups[k])))

    if not args.quiet:
        print()
        print("Members (a PR touching ONLY these runs no suite):")
        for f in uncovered:
            print("  %s" % f)

    print()
    print("This is a LIST, not a verdict. A LICENSE needs no suite; a directory "
          "that a suite already reads as a fixture and that nobody wired into a "
          "`paths:` filter is a silent hole. This command cannot tell them "
          "apart — that judgement is yours, and making it is the point.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
