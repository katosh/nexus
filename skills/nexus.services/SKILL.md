---
description: "The one how-to for registering a PERMANENT service in the services cockpit (`monitor/services.registry` + `monitor/svc.sh`): when to register at all, the registry row and the URL convention (`.deploy/endpoint`), healthcheck design (identity not liveness, capture-then-match), supervision, auto-deploy companions, network exposure, the verification checklist, and clean removal. Use when adding, changing or removing a long-running service; for RESPONDING to a service-health emit use nexus.service-recovery."
---

# nexus.services — registering a permanent service in the cockpit

TRIGGER when: you are about to add a row to `monitor/services.registry`,
change one, or take one out; or `svc.sh status` printed
`WARN service … probes HTTP but shows no URL`.

Not this skill: responding to a `--- service health ---` emit is
`skills/nexus.service-recovery/SKILL.md`. JupyterLab and the remote SSH
endpoint have their own registrars (below); do not hand-write their rows.

The column-by-column reference, with every measured trap, is the comment
block in `monitor/services.registry.example`. This skill is the procedure;
that file is the specification. Where they disagree, the example file wins
and this skill has a bug.

## 1. Should it be registered at all?

**Only PERMANENT services go in the registry** (operator ruling,
2026-10-04). A registered row is relaunched by `bootstrap-recover.sh` after
every restart, health-checked by the watcher every cycle, and auto-restarted
on failure. That is the right contract for something the lab relies on
(a site, an overlay, a daemon), and the wrong one for anything you are
trying out.

| It is… | Do this |
|---|---|
| a temporary, testing or one-session server | run it unregistered: `monitor/async-run.sh --desc "<what>" -- <cmd>` or `monitor/ng longjob run --desc "<what>" -- <cmd>` |
| a JupyterLab | `monitor/jupyter-up.sh <project-dir>` (or `--root`); `--down` removes it. `skills/nexus.jupyter/SKILL.md` |
| the remote agent channel | `monitor/remote-up.sh`; `--down` removes it. `skills/nexus.remote-access/SKILL.md` |
| a permanent service of your own | the rest of this skill |

## 2. The row

One line, **TAB-separated** (not spaces), in `monitor/services.registry`
(operator-local, gitignored; copy the example file if it does not exist):

    <name>  <workdir>  <launch-cmd>  <healthcheck-cmd>  [<logfile>  [<policy>]]

| Column | What it is | Who reads it |
|---|---|---|
| `name` | tmux window name and idempotency key | svc.sh, bootstrap-recover, watcher |
| `workdir` | where launch and healthcheck run; `~` and `$NEXUS_ROOT` expand; a missing workdir skips the row | all three |
| `launch-cmd` | a SUPERVISED restart loop (§4), never the bare server | bootstrap-recover, svc.sh start |
| `healthcheck-cmd` | exit 0 healthy, 100 a FINDING, anything else DOWN (§3) | all three |
| `logfile` | optional; default `<workdir>/serve.log` | svc.sh logs, bootstrap-recover |
| `policy` | optional `auto-restart` (default) or `emit-only`; needs the 5th column present (leave it empty between two TABs) | the watcher's service-health task only |

**The URL convention.** The cockpit's DETAIL cell shows a copy-pasteable URL
taken from, in order:

1. the first `http(s)://…` in the healthcheck TEXT;
2. else `<workdir>/.deploy/endpoint`: one line, the URL, e.g.
   `http://localhost:8774/` (shape-validated; anything not URL-shaped is
   ignored).

Use (2) whenever the healthcheck is a script. **Never weaken a healthcheck
to get a URL into the cockpit**: a script is usually the better probe.
`svc.sh status` warns on stderr when a row's healthcheck probes HTTP
(curl/wget/a URL, in the row or in the script it names) and neither source
yields a URL (<your-org>/nexus-code#1742). Fix the warning by writing
`.deploy/endpoint`.

There is deliberately no URL column: three tools parse the registry
positionally, and a field that selects is not a label (#1050).

## 3. The healthcheck

The full reasoning, with the incidents behind it, is in the example file.
The rules:

- **Identity, not liveness.** The sandbox shares the host network
  namespace, so a port is host-global: another operator's process can win
  the bind and answer your probe. Ask for something only YOUR service
  produces: a marker string on a page you serve, an authenticated endpoint
  whose token lives in your tree (`monitor/jupyter-health.sh` is the
  reference), or a cryptographic identity (`monitor/remote-ssh-health.sh`).
  A bare `curl -fsS -o /dev/null http://localhost:PORT/` is a liveness
  PROXY; choose it knowingly.
- **Capture, then match:** `grep -q '<marker>' <<<"$(curl -fsS --max-time 3 …)"`.
  NEVER `curl … | grep -q …`: under `pipefail` (bootstrap-recover sets it)
  the early-exiting grep SIGPIPEs curl, and the check fails at the moment it
  found the marker, restarting a healthy service (#622).
- **Fast and side-effect free.** It runs every recovery sweep and every
  watcher cycle: a short `--max-time`, no writes, no builds.
- **Never `pgrep -f <name>`.** Agents' argv carries their whole prompt, and a
  prompt that merely quotes your script name satisfies it (#1222, #1073).
  Have the supervisor write a pid file and check
  `test -f x.pid && kill -0 "$(cat x.pid)"`, or check a heartbeat stamp's
  freshness.
- An `/healthz` route that returns your marker is the simplest way to
  satisfy all four.

## 4. Supervision

- The launch command is a **restart loop** in your project tree (the
  `run-supervised.sh` / `serve-supervised.sh` pattern): it starts the
  server, waits on it, logs the exit, sleeps, and starts it again, and it
  writes the server's pid for the healthcheck. The loop survives crashes
  inside a session; the registry survives the session itself dying.
- **Start, stop and restart with `monitor/svc.sh start|stop|restart <name>`
  only.** Registered services run as their own session leaders, which is
  exactly why `monitor/proc-kill-authorized` refuses them. That refusal is
  correct: never `pkill`, never signal by name.
- `auto-restart` is right when a blind restart is safe. Use `emit-only` for
  anything with side effects on relaunch, any network listener exposed
  beyond the host, and any reporter whose failure means "look at this".

## 5. Companion services (watch + auto-deploy)

A site that rebuilds from a repo usually wants a second row: a watcher that
deploys. The pattern that has held up in this workspace:

1. build into a STAGING directory, never in place;
2. smoke-check the staged build (the same marker the healthcheck uses);
3. swap atomically (rename a symlink or a directory), never copy over the
   live tree;
4. keep the last good build, so a bad deploy is one rename away from undone.

Give the companion its own row and its own pid/heartbeat healthcheck (§3).
It is a reporter, so `emit-only` is usually right.

## 6. Access

- Bind `127.0.0.1` unless the service is meant to be reached from other
  machines. When it is bound externally, the cockpit rewrites `localhost`
  in the URL to the host's FQDN.
- Who may reach it, and whether it needs auth, is the **operator's
  decision**. Ask; do not decide it in a worker.

## 7. Verify before you call it done

- [ ] `monitor/svc.sh status` shows the row **UP** with its URL, and prints
      no `WARN` for it.
- [ ] The healthcheck goes non-zero when the server is stopped, and a
      foreign listener on the port would fail it (identity, §3).
- [ ] `monitor/svc.sh restart <name>` brings it back UP.
- [ ] It survives a restart: `monitor/bootstrap-recover.sh` relaunches it
      when it is down and has no window.
- [ ] `monitor/svc.sh logs <name>` shows its log.

## 8. Removing a service cleanly

1. `monitor/svc.sh stop <name>`.
2. Delete its row from `monitor/services.registry`. A managed row is
   removed by its registrar instead: `jupyter-up.sh … --down`,
   `remote-up.sh --down`.
3. Check `monitor/svc.sh orphans` for anything it left running, and retire
   such a leftover with `monitor/svc.sh retire-orphan`, never by signal.
4. Leave or remove `<workdir>/.deploy/endpoint` as you like: without a row,
   nothing reads it.
