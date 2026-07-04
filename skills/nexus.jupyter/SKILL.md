---
description: "JupyterLab-as-a-service for nexus projects: one-command activation (monitor/jupyter-up.sh), the single work-root session with all project kernels (--root + jupyter-kernel-crawl.sh, the foolproof default for 'a jupyter session'), per-project isolation mode, project-agent access via labsh-root.sh, and supervised auto-revival via services.registry. Builds on <yourlab>.labsh for the labsh primitives."
---

# nexus.jupyter — JupyterLab as a supervised nexus service

TRIGGER when: a user asks for a "jupyter" / "jupyterlab" / "notebook
session" (with or without specifics); a worker needs a persistent
kernel that survives across agent turns AND across reboots; an agent
should "chime in" on a notebook a human has open; a project's
JupyterLab should come back by itself after a crash or machine
restart; a project kernel needs registering.

This skill is the nexus *service* layer. The labsh *primitives*
(`start`/`stop`/`kernel add`/`kernel exec`/`kernel inspect`/`notebook
attach`/`notebook append`, shared-node etiquette, networking, the
Rust/AI-extension fallback chain) are documented in the **`<yourlab>.labsh`**
skill (`~/.claude/<hpc-skills>/skills/<yourlab>.labsh/SKILL.md`) and
`work/labsh/doc/labsh.md` — read those for anything kernel-level. Here:
how a project's labsh JupyterLab becomes an activate-once, self-healing,
boot-surviving nexus service, and what to do by default.

## The foolproof default

**When a user asks for "a jupyter session" with no project specified
(or wants to roam across projects), run exactly this and relay the
output:**

```bash
monitor/jupyter-up.sh --root
```

ONE JupyterLab rooted at the nexus work root (`$NEXUS_ROOT/work`),
registered as the single service `jupyterlab`, with EVERY
project's venv available as its own kernelspec (`proj-<project>`) —
browse into any `work/<project>/` and open a notebook on that
project's kernel. `monitor/jupyter-kernel-crawl.sh` registers the
kernels: fired async at activation, re-run by the supervisor every
~10 min (`LABSH_SVC_PERIODIC_EVERY`), runnable on demand. Idle
kernelspecs cost nothing — a kernel process only spawns when a
notebook attaches — so registering all projects is free until used.
New project appears under `work/`? It gets a kernel on the next
crawl, no re-activation. Deleted project? Its stale `proj-*`
kernelspec is pruned on the next crawl.

**When the request names ONE project and isolation matters (its own
port/token/lifecycle, or a server rooted inside the project), use
per-project mode:**

```bash
monitor/jupyter-up.sh /path/to/project
```

Both are idempotent and safe to re-run anytime ("is it up?" → just
run it again). The activate path either way:

1. **Kernel(s)** — root mode launches the kernel crawl (async);
   per-project mode runs `labsh kernel add` if no kernelspec is
   registered (reuses an existing `./.venv`, creates one otherwise —
   also idempotent).
2. **Registry** — ensures the service row (`jupyterlab` /
   `jupyter-<project>`) in `monitor/services.registry`, which makes it
   a real service: `bootstrap-recover.sh` revives it on boot, `svc.sh`
   shows and manages it.
3. **Start** — launches `monitor/labsh-supervised.sh` headless through
   recovery's own idempotent decision path (healthy / already
   supervised → leave alone; never a second server).
4. **Report** — waits for the healthcheck, prints the tokenized URL,
   the token path, and the agent quickstart.

Then interact through labsh, exactly as `<yourlab>.labsh` documents:

```bash
cd /path/to/project
labsh notebook attach analysis.ipynb        # ensure a kernel for the notebook
labsh kernel exec -n analysis.ipynb 'CODE'  # stateful; persists across turns
labsh kernel inspect -n analysis.ipynb      # whos-style live variables
labsh kernel find QUERY                     # resolve "the alignment notebook"
```

The operator never needs to know any of the underlying details — don't
make them choose ports, venvs, or supervision modes unless they ask.

## Project agents on the ROOT session (`labsh-root.sh`)

labsh anchors on `$PWD` — server discovery, the helper venv, and the
token all live under `./.jupyter`. The root session's `.jupyter` is at
the WORK ROOT, so a bare `labsh notebook attach` inside
`work/<project>` cannot see the root server. A project agent targets
it through the wrapper (it points `JUPYTER_CONFIG_DIR` /
`JUPYTER_DATA_DIR` at the work root and execs labsh; relative
notebook paths still resolve against the agent's cwd):

```bash
cd work/myproj
monitor/labsh-root.sh notebook attach analysis.ipynb --kernel-name proj-myproj
monitor/labsh-root.sh kernel exec -n analysis.ipynb 'CODE'   # stateful
monitor/labsh-root.sh url                                    # root server URL
```

The `--kernel-name proj-<project>` on the FIRST attach is what binds
the notebook to that project's venv; after that, `kernel exec -n`
finds the running kernel by notebook path (a process scan — also
works with bare `labsh` once the kernel is alive, but use the wrapper
for everything root-session so the failure modes stay boring).

Caveats: lifecycle verbs pass through too — `labsh-root.sh stop`
stops the SHARED root server (the supervisor bounces it, everyone's
kernels die). Stick to kernel/notebook/url/token verbs. If the same
notebook also has a kernel under a per-project server, `-n` will
report the ambiguity and refuse — disambiguate with `-k PID`.

## Decision tree (when something isn't the default)

- **Already running?** `jupyter-up.sh` re-run is a no-op that prints
  the URL. `monitor/jupyter-up.sh DIR --status` for a one-liner;
  `monitor/svc.sh status` for the whole stack.
- **No kernel yet?** The default path auto-registers. Extra packages at
  creation: `--pkgs "scanpy kompot"`. Later:
  `labsh kernel install PKG...` (per `<yourlab>.labsh`).
- **Existing venv elsewhere (Lmod python, shared env)?**
  `monitor/jupyter-up.sh DIR --venv /dir/containing/venv` — the
  argument is the directory CONTAINING `.venv`, not the `.venv`
  itself. Uses `labsh kernel register --project` (bakes
  `LD_LIBRARY_PATH` into `kernel.json` — required for Lmod-built
  pythons).
- **Port collision?** Not your problem: first start picks a
  deterministic per-project port in 9700–9949; labsh auto-increments
  past anything taken, and the supervisor persists the ACTUAL port to
  `.jupyter/labsh-service.env` so the healthcheck follows. Pin one
  explicitly with `--port N` only if the user asks.
- **Multiple projects?** The root session already covers them all from
  one server (kernelspecs `proj-<dir>`, namespaced by directory name —
  a same-name-after-sanitization clash is refused and logged, never
  clobbered). Per-project services remain available and coexist with
  the root session: each is its own service (`jupyter-<basename>`,
  path-hash-suffixed on basename clashes) with kernelspecs under its
  own `.jupyter/` — no cross-project collisions, ever.
- **Crawl now, not in ~10 min?** `monitor/jupyter-kernel-crawl.sh` runs
  on demand (idempotent; concurrent crawls are flock-guarded). Crawl
  log: `work/.jupyter/labsh-periodic.log`. Note: registering a venv
  installs `ipykernel` into it when missing (additive, never an
  upgrade); a venv on an Lmod python without the module loaded fails
  registration (logged, skipped) until activated with the module
  environment available.
- **Locked-down access?** `--ip 127.0.0.1` (SSH tunnel to use the UI),
  `--https` (self-signed TLS). Persisted; replayed on every restart.
  Default matches labsh: `0.0.0.0` + token auth — fine on the campus
  network, and the activation output warns like labsh does.
- **Human + agent on the same kernel?** Built in: the human opens the
  printed URL and works in the browser; the agent `labsh kernel exec`s
  against the same kernel from the CLI. Same server, same namespace.
  If the human already started `labsh` by hand, activation ADOPTS that
  server rather than starting a second one.
- **Server died / machine rebooted?** Nothing to do. The supervisor
  bounces a dead server within ~45 s; `bootstrap-recover.sh` (run on
  orchestrator wake / `svc.sh up`) relaunches a dead supervisor. The
  `/tmp` helper venvs labsh uses are recreated automatically on the
  next start. Kernels do NOT survive a server bounce — long-lived
  state that must survive restarts belongs in files, not kernel memory.
- **Token rotated?** (`labsh token --rotate`) The healthcheck fails,
  the supervisor bounces the server, the new token applies. Re-fetch
  the URL with `labsh url`. Running kernels are lost (above).
- **Done with the project?** `monitor/jupyter-up.sh DIR --down` stops
  everything AND removes the registry row — otherwise boot recovery
  resurrects it. `svc.sh stop jupyter-<name>` stops WITHOUT
  deactivating (it comes back on the next recovery sweep) — that is a
  pause, not a teardown. Root session: `monitor/jupyter-up.sh --root
  --down` (kernelspec files stay on disk — inert, reused on the next
  activation).

## Worker-prompt snippet (for orchestrators delegating)

When spawning a worker that needs a jupyter session, include: the
project dir; whether to use the root session (default — "interact via
`monitor/labsh-root.sh notebook attach <nb> --kernel-name
proj-<project>` then `labsh-root.sh kernel exec`") or per-project
isolation ("activate with `monitor/jupyter-up.sh <dir>` (idempotent),
interact via `labsh kernel exec/inspect` per `<yourlab>.labsh`"); and the
shared-node etiquette line from `<yourlab>.labsh` if the target is <node>.
Workers must NOT hand-edit `services.registry` — `jupyter-up.sh`
owns those rows.

Workers in a **secondary clone** must still invoke the MAIN clone's
`monitor/jupyter-up.sh` for live services: `NEXUS_ROOT` defaults to
the script's own checkout, so a secondary clone's copy registers
into that clone's registry — a service the live recovery sweep
never sees. (Tests/fixtures override via `NEXUS_SERVICES_REGISTRY`
+ `NEXUS_STATE_DIR`.)

## Anatomy (for debugging, not for the default path)

| Piece | Role |
|---|---|
| `monitor/jupyter-up.sh` | activation entrypoint; `--root` (work-root session), `--down`, `--status`, `--no-start` |
| `monitor/labsh-supervised.sh` | foreground watchdog the registry row launches; bounces unhealthy servers; runs the optional `.jupyter/labsh-service.periodic` hook async; TERM → `labsh stop` |
| `monitor/jupyter-health.sh` | authenticated probe of `/api/status` (registry healthcheck + watchdog probe — one implementation) |
| `monitor/jupyter-kernel-crawl.sh` | shallow sweep of `work/*/`: registers each project venv as `proj-<dir>` in the root session, prunes stale `proj-*` specs; flock-guarded, idempotent |
| `monitor/labsh-root.sh` | project-agent door into the root session: exports `JUPYTER_CONFIG_DIR`/`JUPYTER_DATA_DIR` at the work root, execs labsh |
| `<project>/.jupyter/labsh-service.env` | `PORT=`/`SCHEME=` of the live server (written after every start) |
| `<project>/.jupyter/labsh-service.opts` | persisted extra `labsh start` args (`--ip`, `--https`) |
| `<project>/.jupyter/labsh-service.log` | supervisor log; jupyter's own stdout is `.jupyter/labsh.bg.log` — `svc.sh logs` tails both |
| `monitor/services.registry` | the service row (operator-local, gitignored) |

Troubleshooting starts with `monitor/svc.sh logs <name>` (tails the
supervisor log and jupyter's own stdout together); `monitor/svc.sh
status` shows the tokened access URL in the `DETAIL` column while the
service is UP. The full lifecycle is documented in
`monitor/README.md` ("JupyterLab as a service").
