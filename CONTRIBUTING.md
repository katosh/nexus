# Contributing

Contributions welcome.

- **Local dev setup, branch conventions, watcher-isolation rule:**
  [`docs/contributing/development.md`](docs/contributing/development.md)
- **Test suite (`monitor/watcher/test-*.sh`) and conventions:**
  [`docs/contributing/tests.md`](docs/contributing/tests.md)
- **Adding a new `nexus.*` skill:**
  [`docs/contributing/adding-a-skill.md`](docs/contributing/adding-a-skill.md)
- **Release / CHANGELOG conventions:**
  [`docs/contributing/release.md`](docs/contributing/release.md)
- **Workspace contract that binds agents working in this repo:**
  [`CLAUDE.md`](CLAUDE.md)

PR titles ≤ 70 characters; body explains the *why*. No
`--no-verify`. No force-push to a **shared** branch (`dev`,
`main`, or any branch someone else has pushed commits to);
force-pushing your **own** PR branch after rebasing it onto the
current base is expected — the merge gate requires it, because a
`pull_request` run is computed against a merge ref built at run
creation, and `rerun-failed-jobs` reuses that same ref. The merge ref is
**demand-triggered** — recomputed when something queries the PR's
mergeability, not on a timer — so a stale ref can persist indefinitely,
*and* the act of querying refreshes it. Before trusting a green: query
the PR, then create a new run, then enumerate that run.
CI checks (`ci-signal.yml`,
`tests.yml`, `cc-harness.yml`, `docs.yml`,
`check-no-reports-leaked.yml`) must be green before merge.

**An empty check set is not a passing check set.** Workflow
`branches:` filters match the PR's *base*, so a PR stacked on a
feature branch used to collect zero checks and read as green.
`ci-signal.yml` now runs on every PR into every base and goes
red when a workflow that should have gated your change did not
run. Note also that retargeting a PR emits only the `edited`
event, so a base change re-runs CI only where a workflow opts
into that type. See
[`docs/contributing/development.md`](docs/contributing/development.md)
→ "Zero checks is not green".
