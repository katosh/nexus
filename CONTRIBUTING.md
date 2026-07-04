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
`--no-verify`, no force-pushes. CI checks (`docs.yml`,
`check-no-reports-leaked.yml`, `tests.yml`) must be green
before merge.
