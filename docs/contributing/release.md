# Release

There is no formal release process today. This page describes
what releases look like in practice and what to do when one
becomes load-bearing.

## Current convention

`nexus-code` ships as a rolling `main` branch. Every operator
clones it directly and pulls updates when they want them.
`agent-sandbox`, by contrast, tags `vX.Y.Z` and publishes
GitHub Releases. nexus may grow into that shape, but not yet —
the install footprint is small enough that a `git pull` is the
upgrade path.

What this means in practice:

- **No tags.** `git tag --list` is empty.
- **No release notes.** The
  [`CHANGELOG.md`](https://github.com/<your-org>/nexus-code/blob/main/CHANGELOG.md)
  at the repo root is the closest substitute; it groups recent
  merges under an `[Unreleased]` heading.
- **No version field anywhere.** Nothing in `monitor/`,
  `config/`, or the watcher reports a version. The bug-report
  surrogate is a commit sha — `git rev-parse HEAD` on the
  clone that observed the bug.

Watcher-touching changes that warrant downstream operator
attention land via a PR title that names the area (`watcher:`,
`monitor:`, `ng:`, `skills:`), so a `git log` from the
operator's last `git pull` is the upgrade-impact summary.

## Updating the CHANGELOG

When you merge a change worth surfacing to an operator on
upgrade, add a bullet under `## [Unreleased]` in
`CHANGELOG.md`. Sections follow Keep-a-Changelog — `Added`,
`Changed`, `Fixed`, `Removed`, `Deprecated`, `Security`. Keep
entries to one or two sentences and link the PR for detail.

What counts as "worth surfacing":

- New `ng` verb or flag.
- New `nexus.yml` key or env-var override.
- New `nexus.*` skill.
- Workflow-touching watcher behaviour (new emit class, new
  unstick path, changed eligibility filter).
- Anything that requires the operator to act on upgrade
  (re-install the GitHub App, restart the watcher, edit
  `nexus.yml`).

Routine code cleanups, docs typo fixes, and internal
refactors don't need a CHANGELOG entry — the commit log is
sufficient.

## If a real release flow lands later

The signal that the rolling-`main` convention is no longer
enough: a CHANGELOG bullet that requires operators to time
their upgrade, or a breaking change to `nexus.yml` that needs
a migration step. When that happens, the build-out is roughly
agent-sandbox's release flow:

- Tag `vX.Y.Z` on `main` after CI is green.
- Stamp the version somewhere the runtime can report (a
  `monitor/.version` file, or the first line of
  `monitor/agent-prompt.md`).
- Promote `## [Unreleased]` to `## [X.Y.Z] - <date>` in the
  CHANGELOG.
- Open a GitHub Release on the tag, pasting the CHANGELOG
  section as the body.
- (Optional) `.github/workflows/release.yml` to automate the
  tag → release step.

Don't pre-build this. The convention earns its place when an
operator actually needs to know which version they're running.
