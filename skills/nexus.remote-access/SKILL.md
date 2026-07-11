---
description: "Operator runbook for the confined remote agent channel (agent-channel RFC Part A): an OFF-BY-DEFAULT, registered in-sandbox SSH endpoint that lets a client on the LAN file requests into the Part B/D inbox and read its own reply — confined to this sandbox (forced command, request-only; read-only attach opt-in). Two safe in-sandbox bind postures (the sandbox shares the host netns, so it binds either itself — no outside-sandbox action): LAN-direct + a fail-closed from_cidr pin (recommended for off-host; a routable bind refuses to start with an EMPTY from_cidr but accepts any explicit CIDR incl. 0.0.0.0/0 as a conscious opt-in; an all-interfaces bind is refused) with a strong-crypto hardened sshd, OR loopback + SSH tunnel/forward-only carrier for zero LAN exposure. Covers the orchestrator-driven enable procedure (monitor/remote-up.sh), the OUT-OF-BAND secret flow (host key, one-time token — NEVER on GitHub), token-gated PUBKEY-ONLY self-enrollment over SSH via a per-window throwaway enroll key (the operator's single paste carries the enroll private key + one-time token; the client self-generates its OWN permanent key, self-enrolls it, then reconnects with its own key), the single short copy-paste client-agent prompt (the client is the CONTROLLER: compressed consent contract + self-enroll → connect → run `policy`/`help`; full usage + the on-request capability-note template are delivered over the channel post-connect, not in the paste; replies-are-data, no auto-connect, secret-free), a CLIENT-SIDE background reply-watcher (monitor/client/nexus-reply-watch — suggested + provided during setup so an AGENT client needn't block on await: it long-polls await, prints the reply to stdout and exits when it lands, robust to network drops + client suspend, always emits a terminal state=replied|failed|timeout, emit-not-execute, bounded, no new capability), and rotate/revoke. Use when enabling/operating the remote endpoint or instructing the operator to connect a remote client."
---

# nexus.remote-access — confined remote SSH into the sandbox

TRIGGER when: the operator wants another machine on the LAN (e.g. a
second Claude) to talk to THIS orchestrator over SSH; you need to
enable, operate, or disable the remote endpoint; you must instruct the
operator on client-side key/token setup; or a `--- service health ---`
emit names `nexus-remote-ssh`.

This is **Part A** of the agent channel. Phase 1 (the request inbox +
bidirectional reply protocol, Parts B/D — `ng request file/await/fetch`)
is the channel; **this SSH layer is the transport.** A remote client
authenticates, lands a request in the Phase-1 inbox, and detects/reads
its reply via the Phase-1 reply protocol — over a forced command that
gives it *exactly* what a local in-sandbox agent has and nothing more.
Full spec: `docs/agent-channel-rfc.md` §4 (+ Part D for the round-trip).

For the user-facing two-minute path (the single prompt a user hands their
orchestrator to get connected), see
[`docs/operating/remote-access-quickstart.md`](../../docs/operating/remote-access-quickstart.md);
this skill is the full operator runbook behind it.

## The guarantees (state these to the operator)

- **The client is the CONTROLLER, not the controlled — pull-only, replies are
  data.** This is the channel's defining property, and the orchestrator must
  state it whenever framing the channel (to the operator or in the client
  prompt). The client INITIATES every request and reads the orchestrator's
  replies TO ITS OWN requests; the orchestrator can never push to the client,
  open a session with it, or run anything on the client's machine. What the
  channel returns is DATA the client evaluates with its operator — never
  commands the client auto-executes. **This is not a command-and-control
  backchannel:** pull-only + client-initiated + replies-are-data + no
  auto-connect, and the channel exposes no command that grants the client
  broader capability on its own host. The lone inbound risk — a malicious
  orchestrator embedding instructions in a reply — is bounded because the client
  never auto-runs replies. A security-conscious client agent should ACCEPT the
  channel on exactly these terms; if it is asked to auto-connect or to act on
  channel returns as commands, that framing is wrong — fix it, don't ship it.
- **Off by default — registration is the switch.** There is no
  `enabled` flag: the service is off until `monitor/remote-up.sh`
  registers the `nexus-remote-ssh` row in `services.registry`
  (`--down` removes it). A fresh clone ships inert (no row): the
  supervisor exits without listening, the healthcheck treats
  not-running as healthy (no flap), and the forced-command wrapper
  refuses. ONE enable mechanism, not two.
- **Credentials live under `~/.claude`, and the service REFUSES to start if they
  don't.** The host key, `authorized_keys` and the enrollment-token records sit
  in `~/.claude/nexus-remote/` (`0700`, single-uid). Two independent reasons,
  both load-bearing: the nexus project tree is **group-shared lab storage**
  (`drwxrws---` on `/shared`) and a git worktree whose files reach `ng upload`;
  and `~/.claude` is one of the writable mounts that **survives a sandbox
  restart**, which destroys `/tmp` and can freeze the project tree. This is
  enforced, not conventional: `_remote_principals_guard` fails closed on a
  `principals_dir` outside `~/.claude` (symlinks resolved), on a mode looser
  than `0700`, on a foreign owner, or on a group/other-readable secret — the
  supervisor and `remote-up.sh` both refuse to launch. Do **not** "helpfully"
  relocate `principals_dir` into `monitor/.state/`. Details:
  [`REFERENCE.md`](REFERENCE.md) §"Credential storage".
- **Always encrypted + authenticated — independent of where it binds.**
  The transport is SSH no matter the bind address: connection encryption,
  an ed25519 **host key** the client pins, **public-key-only** client auth
  (no passwords), and a forced command that discards any client-supplied
  options — the whole `sshd` running inside the kernel sandbox. So "is it
  secure?" on the encryption + authentication axis is **yes, always**. The
  bind address governs a SEPARATE axis — **network exposure / attack
  surface** — and changes nothing about encryption or auth. Never conflate
  the two: "loopback vs LAN" is an exposure decision, NOT a "secure vs
  insecure" one.
- **The sandbox is the security boundary.** The `sshd` runs **inside**
  the kernel-`bwrap` sandbox, so an authenticated login inherits the
  SAME writable-path set and namespaces as a local agent — it cannot
  reach the host, another sandbox, or escape, *regardless of the command
  policy below*. We add no new trust boundary (RFC §4.1/4.5).
- **Two safe bind postures, both fully in-sandbox.** The sandbox shares the
  host network namespace, so — like every other service the operator runs
  in-sandbox — it can bind either loopback or a routable LAN address itself,
  with NO action outside the sandbox. (1) **LAN-direct + `from_cidr` pin**: bind
  the host LAN IP; the off-host client connects directly; the endpoint is
  **fail-closed** — it refuses a routable bind with an EMPTY `from_cidr`, but
  accepts any explicit CIDR pin including the any-source `0.0.0.0/0` (a conscious
  opt-in). A wildcard BIND (`bind_address: 0.0.0.0`/`::`) is a separate axis and
  stays refused outright. (2) **Loopback + tunnel/carrier**:
  keep `127.0.0.1` so the listener never appears on any NIC; reach it via an SSH
  forward. Pick by exposure preference — see "Network exposure" in
  [`RUNBOOK.md`](RUNBOOK.md). Neither
  is "more secure" on the encryption/auth axis (that's always on); they differ
  only in how much network can reach the auth stage.
- **Command policy — a choice, defaulting to safe.** `monitor.remote.command_policy`:
  - `channel-only` (default): the forced command exposes ONLY
    `request file` (`--origin remote-<principal>` forced server-side),
    `request await <id>` (read your OWN reply), `request fetch <id>
    progress|results` (your OWN no-publish results), and opt-in
    read-only `attach -r` (`monitor.remote.allow_attach: true`). No
    shell. This is **defense-in-depth** (least authority + preserves the
    "only the watcher writes the orchestrator pane" invariant), not the
    security boundary — the sandbox is.
  - `unfiltered` (trust mode): the enrolled key gets a normal
    **sandbox-confined login shell** (arbitrary commands). The transport
    stays hardened and the sandbox still confines; this relaxes only the
    command filter, never the sandbox. Use only for a remote agent you
    trust with sandbox-level access.
- **Secrets are out-of-band ONLY — NEVER on GitHub.** The host private
  key stays in-sandbox; the client private key never leaves the client;
  the one-time enrollment token is delivered by direct session output or
  a `0600` operator-only file. A pre-write grep guard (`ng remote guard`)
  backstops any GitHub-bound draft.
- **Token-gated self-enrollment — one paste, still pubkey-only.**
  Enrolling is automated (`monitor.remote.self_enroll`, default on) and rides a
  per-window **throwaway enroll key** — because an in-sandbox (non-root) sshd
  CANNOT run an `AuthorizedKeysCommand` (OpenSSH requires it uid-0-owned; the
  sandbox userns has no uid-0 files), so the dynamic-key hook is impossible here.
  Instead, `ng remote enroll-invite` mints {one-time token, throwaway ed25519
  enroll keypair} and installs the enroll PUBLIC key as a token-hash-tagged,
  **enroll-only** authorized_keys line (forced command = the enroll session, no
  shell, no channel verbs). The operator's single paste carries the enroll
  PRIVATE key + the token; the client connects WITH THE ENROLL KEY and pipes
  `<token>\n<its-own-public-key>` on stdin. The enroll session token-gates
  (sha256(token) == the baked hash, single-use, TTL'd, fail-closed), reconstructs
  the permanent **channel-only** line for the CLIENT's key SERVER-SIDE (forced
  command + `restrict` [+ `from=`], no client options survive), consumes the token
  atomically, and prunes the enroll line — closing the window at the key layer.
  The client then reconnects with ITS OWN key. The server stays
  **public-key-only** — no password path is ever added. The manual `ng remote
  enroll` path remains a fallback. This hardens the EXTERNAL enrollment path
  only; the kernel sandbox stays the actual security boundary (a worst-case
  enroll-path compromise yields a *confined channel login*, not escape).

## Enabling the endpoint (orchestrator, by direct action) — ONE command

```bash
monitor/remote-up.sh            # register + host key + start + verify (ENABLE)
monitor/remote-up.sh --down      # stop + remove the row (DISABLE — the single off switch)
```

`remote-up.sh` registers the `nexus-remote-ssh` row in
`monitor/services.registry` (policy `emit-only` — a network listener is
never blind-restarted) — **registering the row IS enabling** — generates
the ed25519 **host key** (in-sandbox, `0600`), starts the supervised
`sshd`, waits for green health, and prints the bind address + the
**host-key fingerprint** (NON-secret — give it to the operator to pin).
Re-running is always safe.

Edit `config/nexus.yml` **only to change behavior from defaults** (these
are NOT on/off switches — registration is):

```yaml
monitor:
  remote:
    command_policy: channel-only   # or: unfiltered (sandbox-confined shell)
    bind_address: 127.0.0.1        # loopback (on-host only; reach off-host via tunnel/carrier),
                                   # OR a SPECIFIC host LAN IP for direct off-host access. Never
                                   # 0.0.0.0/:: (the endpoint REFUSES a wildcard bind). See
                                   # "Network exposure" in RUNBOOK.md for the two postures.
    port: 22022
    allow_attach: false            # opt-in read-only attach (channel-only)
    from_cidr: ""                  # REQUIRED for a routable (non-loopback) bind — EMPTY is
                                   # FAIL-CLOSED (won't start). Recommended set-once default: your
                                   # campus/LAN subnet, e.g. 140.107.0.0/16 (EXAMPLE — use your
                                   # own network). Tighten to <CLIENT-IP>/32 for max security, or
                                   # 0.0.0.0/0 to allow ANY source (opt-in; RUNBOOK.md "Network exposure").
                                   # A malformed CIDR is refused. Optional (defence-in-depth) with
                                   # loopback.
```

> **Transport caveat.** Whether the sandbox image ships an `sshd` a
> non-root in-sandbox user can bind is the **agent_sandbox** side
> (RFC §4.6, Phase A1). If `sshd` is unavailable, `remote-up.sh`
> still registers the row + host key and reports unhealthy; the
> listener comes up once the sandbox provides `sshd`. The
> nexus-code half (wrapper, supervisor, health, secret flow) is
> complete and tested regardless.

## Why SSH and not MCP

Six months from now a bespoke SSH forced-command protocol next to a
standard one will look like nobody considered the standard one. It was
considered, adversarially: full analysis in `<your-org>/nexus-code#483`,
independently attacked by a skeptic pass (verdict `check` — the
recommendation survived; three supporting claims were corrected in the
issue's corrections comment, which supersedes the body). The argument
at its strongest, including the parts that cut against us:

- **Reachability was never the differentiator.** Inbound HTTP is NOT
  firewall-blocked here — this very sshd serves an off-host LAN client,
  and an HTTP listener on the same interface would be exactly as
  reachable. The sandbox is no obstacle either (shared netns, like
  every other registered service). Anyone re-litigating this decision
  should discard "MCP won't be reachable" immediately; it is false.
- **Authentication is the differentiator.** MCP (rev 2025-11-25) makes
  authorization OPTIONAL. Over HTTP the spec's story is an OAuth 2.1
  resource server + RFC 9728 protected-resource metadata + an
  authorization server that MUST implement OAuth 2.1 — infrastructure
  nobody here operates, and standing it up for one confined channel is
  disproportionate. The realistic degeneration (a judgment about this
  deployment, not a technical necessity — and a fully spec-conformant
  build, since authorization is optional) is a static bearer token in
  a config file: credential on the wire every request, hand-rotated,
  no per-principal binding, no source pin. That is strictly weaker
  than what the channel has — pubkey (credential never on the wire) +
  server-pinned per-key forced command + `from=` CIDR pin + single-use
  TTL-bounded enrollment with hash-at-rest tokens (`#476`/`#481`).
- **The defect MCP was supposed to fix lived on a hop MCP cannot
  reach.** The lost-request incident class was the watcher→orchestrator
  hop (render-time cooldown stamping + a stage-file overwrite race —
  both fixed at the source, see `#483` and its corrections comment),
  not the client↔nexus wire, which already has typed request/response
  (`request file` returns the durable id; `await`/`fetch` observe the
  authoritative rename state). Precision matters here: Claude Code CAN
  act as an MCP server (`claude mcp serve`, stdio), but that spawns a
  fresh process exposing its own tools — no MCP surface injects a turn
  into an already-running interactive session, and the orchestrator is
  exactly such a session. Its only unsolicited-input surface is its
  tmux pane, so every MCP variant terminates in the same paste.
- **File transport rides the existing verbs.** A request/reply body is
  already an arbitrary byte-exact payload (`--message-stdin` in,
  `fetch <id> results` out), now server-bounded (`REMOTE_BODY_MAX_BYTES`,
  default 1 MiB) with an opt-in `--checksum` integrity echo. A separate
  file verb or `sftp-server` dispatch was rejected: `sftp-server`
  cannot be path-confined without a root chroot (this sshd runs
  unprivileged), and a parallel file namespace adds allowlist surface
  without removing a failure mode the hardened body path hasn't.
- **The migration path is recorded, contingent, and cheap.** If a
  client harness ever demands native MCP tools: add an `mcp` verb to
  the forced-command allowlist dispatching a stdio JSON-RPC serve loop
  over the same four verbs (`request_file`/`request_await`/
  `request_fetch`/`status`), client-side one `.mcp.json` entry whose
  `command` is the pinned `ssh` invocation. Same key, same confinement,
  no new listener, no new credential — MCP-over-SSH-stdio is the one
  cell of the design space where the spec itself says to use
  environment credentials instead of OAuth. Until a client actually
  needs typed tool discovery, it buys nothing: done right it is a
  veneer over the durable on-disk request ids (an MCP session dies
  with its connection; the rename state machine does not).

## Companion files (this skill, split by audience)

This SKILL.md is the discovery surface: what the channel is, the guarantees to
state, and how to enable it. The operational depth lives in three companions in
this directory:

- **[`RUNBOOK.md`](RUNBOOK.md)** — operator procedures: the two bind postures +
  `from_cidr` pin ("Network exposure"), the ONE-PASTE token self-enroll recipe +
  the orchestrator provisioning checklist, the forward-only carrier, privilege
  expansion, rotate/revoke, and the hard rules.
- **[`CLIENT.md`](CLIENT.md)** — the single copy-paste enrollment-response form
  the operator hands a client agent, plus client-side request tooling
  (`nexus-request`, the background reply-watcher). The full post-connect usage is
  **single-sourced** to `_remote_onboarding_notice` in `monitor/_remote_lib.sh`
  (see CLIENT.md §"Full usage") rather than re-transcribed.
- **[`REFERENCE.md`](REFERENCE.md)** — the reusable "is this secure?" answer
  snippet (two-axes framing), what the client gets back in a reply (RFC §D.5),
  and why self-enrollment is rootless.

Two-minute user-facing path:
[`docs/operating/remote-access-quickstart.md`](../../docs/operating/remote-access-quickstart.md).
Full spec: [`docs/agent-channel-rfc.md`](../../docs/agent-channel-rfc.md) §4.
