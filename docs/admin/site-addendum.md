---
title: <your-lab> addendum
---

# <your-lab> addendum

!!! warning "Deployment-specific — removable"
    This page collects setup notes specific to the <your-lab>'s
    <your-institution> deployment of nexus. Nothing here is required for
    a general nexus deployment; nothing here generalises. The page
    exists so that <your-lab> operators can find the lab-specific
    shims in one place, and so that the rest of the site stays
    deployment-neutral. Once <your-institution> infrastructure changes
    or the lab adopts a different pattern, this page can be
    removed without touching anything else.

The general nexus install path lives at
[Getting started → Install](../getting-started/install.md). Operators
running on <your-lab>'s HPC hosts have a few extra concerns the
generic guide skips: how to land on a persistent compute node,
which fast-filesystem path to use, and which HPC-specific skills
to load. This page is the small set of substitutions and addenda
for that environment.

## Persistent compute host on the lab cluster

Nexus needs a host where tmux + `agent-sandbox` can run
continuously — the outer tmux session is what survives SSH drops
and reboots. On the <your-institution> <cluster> cluster, the lab pools its
members onto one shared HPC node via an in-house slot-coordination
tool named [`<shared-node-tool>`](https://github.com/<your-org>/<shared-node-tool>), so
the entire lab shares a single interactive allocation rather than
spawning per-user allocations. `<shared-node-tool>` keeps a chain of
trivial 1-CPU Slurm jobs ("slots") alive per user; as long as one
slot is running, the cluster's reaper leaves your SSH + tmux
session up indefinitely.

### Obtaining `<shared-node-tool>`

`<shared-node-tool>` is **not** on `PATH` and is **not** an Lmod module. It
is a small wrapper script that lives on the lab's shared
`<hpc-mount>` storage and is run by full path:

```bash
<fast-home>/shared_node/<shared-node-tool> current
```

Add an alias so you can type `<shared-node-tool>`:

```bash
alias <shared-node-tool>=<fast-home>/shared_node/<shared-node-tool>
```

The wrapper is self-bootstrapping — it loads `uv` (from the `uv`
Lmod module if not already present) and runs the `<shared-node-tool>.py`
CLI via `uv run`, so there is nothing to `pip install`. Cloning
[`<your-org>/<shared-node-tool>`](https://github.com/<your-org>/<shared-node-tool>)
yourself is **not** required for joining an already-running node;
clone it only if you intend to maintain a node (run the watcher,
fill/teardown slots).

!!! warning "Two access prerequisites"
    The canonical script currently lives under one operator's
    personal lab-share path (`…/user/<operator>/shared_node/`). To run
    it you need **both**:

    - **Lab-share access** to that path — i.e. membership in the
      `<group>` fast-share group. Without it the path is
      permission-denied.
    - **If you run inside `agent-sandbox`**, the path must be
      granted in your `~/.config/agent-sandbox/sandbox.conf` (the
      sandbox only exposes your project dir + `~/.claude` by
      default). An un-granted path simply *does not exist* from
      inside the sandbox — this is the most likely cause of a
      fresh environment reporting "`<shared-node-tool>` not found / path
      does not exist." Add the grant, restart the sandbox, and
      the script becomes visible.

### Discovering the current shared node

You almost never type the node hostname yourself — `<shared-node-tool>`
auto-discovers it from the live watcher heartbeat published under
`…/shared_node/heartbeats/<host>.json`:

```bash
<shared-node-tool> current        # human-readable: host + heartbeat age + free slots
<shared-node-tool> current -q     # just the hostname, for scripting
```

If you cannot run `<shared-node-tool>` yet (no alias, heartbeat dir not
granted into your sandbox, or you simply want a zero-dependency
check), discover the node straight from Slurm. Every <shared-node-tool>
slot job is named `{owner}_slot_{N}_extension_{M}` (placeholders
are `free_slot_*`), so the running slot jobs reveal the node:

```bash
# Run from <login-node> / a <cluster> login node (full squeue visibility).
# Prints the unique node(s) currently hosting <shared-node-tool> slot jobs.
squeue --states=RUNNING -h -o '%N %j' | awk '$2 ~ /_slot_/ {print $1}' | sort -u
```

`squeue` on a login node is unscoped across users, so this sees
every lab member's slot jobs — exactly how `<shared-node-tool> current`
itself resolves the node internally. (Inside an `agent-sandbox`
worker `squeue` is scoped to *your* project's jobs, so run this
discovery from a real login shell, not from a sandboxed worker.)

### First-time and recurring sessions

```bash
# [once] claim slots on the lab's shared node.
# <shared-node-tool> auto-detects the node; no hostname needed.
ssh <login-node>
<shared-node-tool> join                       # default: 3 staggered slots
logout
```

```bash
# [recurring] SSH straight to whatever node the lab is on now
ssh "$(<shared-node-tool> current -q)"        # resolves the current host
tmux new -s work      # first time;  tmux attach -t work to return
```

`<shared-node-tool>` keeps your slot reservation alive across logout/login,
and `<shared-node-tool> current` always follows the freshest heartbeat — so
when the lab rotates to a different node you do **not** update any
alias or hardcoded hostname. When you are finished for an extended
period, release your slots so others can use the cores:

```bash
<shared-node-tool> leave
```

For the full command reference, the watcher mechanism, and
multi-tenant etiquette, see the
[`<shared-node-tool>` README](https://github.com/<your-org>/<shared-node-tool>) and the
`hpc.shared-nodes` skill (see *HPC-aware skills* below).

Equivalent patterns work on other clusters — any long-lived
interactive allocation on a node that stays reachable while you're
away will do. The constraint is just: *same host every time,
persistent across SSH drops, alive during overnight worker runs*.

## Fast filesystem path

The <your-lab>'s `<hpc-mount>` mount is the appropriate location for
the nexus clone. If you run the bootstrap, `cd` to this path
before invoking `./monitor/bootstrap-install.sh` so the recorded
`nexus.root` matches. For the manual install path, replace
`<your-nexus-root>` in
[Install § M1](../getting-started/install.md#m1-pick-a-host-filesystem)
with:

```bash
export NEXUS_ROOT=<hpc-mount>/<group>/user/$USER/nexus
```

Quota and IO are tuned for workloads here; home-directory storage
is too small and IO-constrained for the `work/` checkout tree and
`reports/` log to live in.

## HPC-aware skills

Workers running on <your-institution> HPC benefit from the cluster-aware
skills in
[`<your-org>/<hpc-skills>`](https://github.com/<your-org>/<hpc-skills>):
Slurm job submission patterns, storage tier semantics, Lmod
module loads, and the small handful of <your-institution>-specific
conventions (account names, partition flags, scratch paths). Clone
into a sandbox-writable location under `~/.claude/` and symlink
into the skills search path:

```bash
git clone https://github.com/<your-org>/<hpc-skills>.git ~/.claude/<hpc-skills>
ln -s ~/.claude/<hpc-skills>/skills ~/.claude/skills/<hpc-skills>
```

The skills are discovered the same way the `nexus.*` skills are
(frontmatter-keyed auto-load by Claude Code) and are scoped to
worker contexts that touch HPC resources.

!!! note "<Shared-Node-Tool> / shared-node skill"
    A `hpc.shared-nodes` skill — multi-tenant etiquette plus
    `<shared-node-tool>` join/discover/leave guidance — lives on the
    `<operator>/shared-nodes-skill` branch of `<hpc-skills>` but is
    not yet merged to the default branch. **Recommendation:** land
    that skill and extend it with the *Obtaining `<shared-node-tool>`*
    pointer above (canonical shared-storage path + the two access
    prerequisites), so a fresh operator gets <shared-node-tool> discovery
    from the skill instead of relying on this addendum alone. Until
    it merges, this addendum is the canonical reference. The
    underlying tool documentation is the
    [`<your-org>/<shared-node-tool>` README](https://github.com/<your-org>/<shared-node-tool>).

!!! note "Automated from bootstrap"
    From the bootstrap install, this step is automated when the
    operator picks a `<your-org>/*` asset+issue repo on a <your-institution>
    HPC host (see `monitor/install-prompt.md` Phase 6.1 and
    `monitor/install-hpc-skills.sh`). The manual recipe above is
    the canonical reference for non-bootstrap installs and for
    re-installing on a host where the bootstrap has already run.

## What is *not* lab-specific

These details get asked enough that it's worth being explicit:

- **`agent-sandbox`** is not <your-lab> software. It's an
  [open-source kernel-enforced sandbox](https://github.com/katosh/agent_sandbox)
  used by anyone running coding agents on shared infrastructure.
- **`labsh`** is not <your-lab> software either — it's a
  [general-purpose project-local JupyterLab wrapper](https://github.com/katosh/labsh).
- **The bot's `[bot]` identity** is per-operator, regardless of
  organisation. Your bot is yours; this lab doesn't share a bot
  account.
- **The asset+issue repo split** applies to every nexus
  deployment, not just the lab's.

## Cross-links from the general guide

Pages that cross-reference this addendum:

- [Getting started → Install](../getting-started/install.md) —
  the host filesystem step (M1 in the manual fallback) and the
  implicit prerequisite of a persistent compute host.
- [Getting started → Overview](../getting-started/overview.md) —
  prerequisites list.
- [`README.md`](https://github.com/<your-org>/nexus-code/blob/main/README.md)
  in the repo root — the elevator pitch points here for
  <your-lab> readers.

## Removing this page

When the lab no longer runs the `<login-node>` → `<shared-node-tool>` →
shared-node pattern (or this deployment moves off the <cluster>
cluster entirely), delete this file and remove the `nav` entry
for it from `mkdocs.yml`. The general install guide is
self-contained and does not depend on anything here.
