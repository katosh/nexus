---
description: "Installing private GitHub packages (R remotes::install_github, uv/pip git+, …) inside nexus workers: use the user's `gh auth token` via GITHUB_PAT / GITHUB_TOKEN, not the bot's installation token (which 404s silently). Fail loudly when the PAT is unset."
---

# nexus.private-package-install — PAT-driven private installs

TRIGGER when an agent is about to install a package from a private GitHub repository — `remotes::install_github` / `devtools::install_github` / `pak::pkg_install` / `renv::install` / `renv::restore` in R, `uv pip install git+https://...` or `pip install git+https://...` or `uv sync` against a `pyproject.toml` with a `git+` source in Python, or any other tool that authenticates against a private-repo `git clone` under the hood (Apptainer pulling a private OCI image, etc.).

## The one rule

The bot's installation token (minted by `monitor/mint-token.sh`, surfaced as `GH_TOKEN` in workers) **404s silently** on private-GitHub package-install surfaces. The 404 is indistinguishable from "repo does not exist", and a worker can spend an hour debugging the wrong layer.

Bootstrap scripts that install private dependencies MUST use the **user's OAuth token** (`gh auth token`) via `GITHUB_PAT` (R) or `GITHUB_TOKEN` (Python's `git`-delegating tools), and MUST fail loudly when neither is set — never let the bot token silently take over.

This mirrors the fail-loud rule in `nexus.bot` (empty `GH_TOKEN` → exit non-zero, never fall through to user `gh` auth). Same principle, inverted direction: there we refuse silent bot → user fallback for writes; here we refuse silent user → bot fallback for reads.

## R — `remotes::install_github` and friends

```bash
GITHUB_PAT="$(gh auth token)" Rscript -e \
  'remotes::install_github("<your-org>/<repo>", ref = "<sha>")'
```

`devtools::install_github` wraps `remotes::install_github`; `pak::pkg_install("github::<your-org>/<repo>@<sha>")` and `renv::install("<your-org>/<repo>")` read the same `GITHUB_PAT` env var. `renv::restore()` reads it too when the lockfile carries GitHub sources. Set the env var once at the shell level; every R-side install helper picks it up.

Always pin to a SHA (or tag) rather than HEAD. Bare `install_github("<your-org>/<repo>")` resolves to the default branch's current HEAD at install time, which moves under you and breaks reproducibility — the same hazard `hpc.reproducibility` flags for any version-mutable dependency.

## Python — `uv pip install git+...` (preferred)

```bash
GITHUB_TOKEN="$(gh auth token)" uv pip install \
  "git+https://github.com/<your-org>/<repo>@<sha>"
```

`uv pip` is the workspace default: plain `pip install` inside the agent-sandbox hangs for 5+ min on the `/app/bin/pip` Lmod wrapper, while `uv pip install` finishes in seconds. The underlying NFS-metadata-latency story lives in `<your-org>.sandbox-gotchas` rule 1 and `hpc.python`'s uv section; this skill defers to those for the why.

Declarative form in `pyproject.toml`:

```toml
[project]
dependencies = [
  "<package> @ git+https://github.com/<your-org>/<repo>@<sha>",
]
```

then `GITHUB_TOKEN="$(gh auth token)" uv sync` resolves the private URL.

For one-shot PEP 723 inline-metadata scripts:

```bash
GITHUB_TOKEN="$(gh auth token)" uv run --with \
  "<package> @ git+https://github.com/<your-org>/<repo>@<sha>" \
  my_script.py
```

The env-var form assumes `gh auth setup-git` has been run for the user (standard nexus setup), so the git-credential helper routes `GITHUB_TOKEN` to `github.com` clones. Where that's not guaranteed — e.g. a CI runner that doesn't carry `gh` config — embed the token in the URL directly:

```bash
uv pip install \
  "git+https://x-access-token:$(gh auth token)@github.com/<your-org>/<repo>@<sha>"
```

Same pattern `<your-org>.sandbox-gotchas` rule 3 uses for one-shot bot-token pushes; it bypasses the credential helper entirely.

## Python — plain `pip install git+...` (fallback only)

Reach for plain `pip` only when `uv` is unavailable (e.g. an upstream container whose entrypoint hard-codes `pip`). Expect multi-minute hangs inside the agent-sandbox:

```bash
GITHUB_TOKEN="$(gh auth token)" pip install \
  "git+https://github.com/<your-org>/<repo>@<sha>"
```

If a third-party `Makefile` or CI script you don't control hard-codes `pip`, alias it for the session: `alias pip='uv pip'`.

## The fail-loud rule

Every bootstrap script that touches a private install MUST refuse to run with an empty `GITHUB_PAT` / `GITHUB_TOKEN` — not silently fall back to whatever ambient credential the shell happens to carry (the bot token, a stale netrc entry, a credential helper from a different identity).

R bootstrap (`inst/bootstrap.R` or similar):

```r
pat <- Sys.getenv("GITHUB_PAT")
if (!nzchar(pat)) {
  stop(
    "GITHUB_PAT unset — pass the user's OAuth token (gh auth token). ",
    "The nexus bot installation token 404s on remotes::install_github."
  )
}
remotes::install_github("<your-org>/<repo>", ref = "<sha>")
```

Shell wrapper for any Python install:

```bash
: "${GITHUB_TOKEN:?GITHUB_TOKEN unset — pass the user PAT (gh auth token); bot token 404s on pip install git+}"
uv pip install "git+https://github.com/<your-org>/<repo>@<sha>"
```

`${VAR:?msg}` is the load-bearing primitive: it expands to `$VAR` when set and non-empty, or exits the shell non-zero with `msg` on stderr when unset/empty. Drop it at the top of every install script; one line, zero ceremony, no silent fallback.

## Other ecosystems

Any tool that authenticates a private-repo `git clone` under the hood follows the same pattern: pass the user's PAT (via env or URL-embed), never the bot's installation token, and fail loudly on a missing PAT. The two non-R / non-Python cases that come up in lab workers:

- **`apptainer pull docker://ghcr.io/<your-org>/<image>:<tag>`** for a private OCI image — set `SINGULARITY_DOCKER_USERNAME=<your-github-user>` and `SINGULARITY_DOCKER_PASSWORD="$(gh auth token)"`, or `apptainer remote login` against `oras://ghcr.io` with the same credential. Defer to `hpc.containers` for the surrounding pull / SIF-storage conventions.
- **`renv::restore` from a `renv.lock`** carrying GitHub sources — same `GITHUB_PAT` env var as in the R section above; the failure mode is identical.

Tools that don't go through GitHub auth (CRAN via `install.packages`, Bioconductor via `BiocManager::install`, PyPI via `uv pip install <name>`, conda-forge / bioconda via mamba) are unaffected by this skill — install them the normal way per `hpc.r` / `hpc.python`.

## Cross-check with <hpc-skills>

This skill **does not** restate the general packaging conventions on <your-institution> infrastructure: uv vs Lmod-module Python, virtual-env placement, `fhR` / `renv`, Apptainer pull mechanics, the conda-forge mirror, NFS-metadata latency behind the `pip` hang. Those live in `hpc.python`, `hpc.r`, `hpc.containers`, `hpc.reproducibility`, and `<your-org>.sandbox-gotchas` respectively — read them for the underlying mechanics. This skill scopes specifically to the **nexus-bot-context auth layer**: bot installation token 404s on private installs, user OAuth via `gh auth token` works, and the fail-loud rule that prevents silent fallback between the two. When in doubt about packaging mechanics, defer to the `fh.*` skill; when in doubt about which token to pass, this skill is canonical.

## Documented field example

`<your-org>/<other-nexus>#6` (ccflowR install audit, 2026-05-08) traced an opaque 404 in an R bootstrap script to a bot-installation-token fallback when `GITHUB_PAT` was unset. The fix landed as a fail-loud guard in `inst/bootstrap.R`, exactly the shape shown above. That incident is the canonical reproduction case for this skill's rule.

## See Also

- `nexus.bot` — GitHub-write identity skill; the PAT-install content was carved out of there to keep that skill focused on writes (PR / issue / comment / asset upload). A one-line pointer back to here lives at the equivalent place in `nexus.bot/SKILL.md`.
- `nexus.worker-defaults` — every-worker safety floor; reach for this skill when a task touches a private-GitHub package install.
- `hpc.python` — uv, modules, virtual envs on <cluster>; the underlying packaging mechanics.
- `hpc.r` — fhR modules, `renv`, Bioconductor; the R-side packaging mechanics.
- `hpc.containers` — Apptainer pulls and digest pinning; the surrounding mechanics for the ghcr.io case above.
- `<your-org>.sandbox-gotchas` — rule 1 (always `uv pip`, never plain `pip`) and rule 3 (URL-embed token form for one-shot pushes — same pattern for one-shot installs).
- `hpc.reproducibility` — version pinning as a general practice; this skill's "always pin to a SHA" line is the GitHub-source instance of that rule.
