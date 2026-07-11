# nexus.remote-access — REFERENCE (rationale + protocol)

Threat-model rationale and protocol reference for the confined remote SSH
channel. Companion to [`SKILL.md`](SKILL.md) (the guarantees + enabling);
operator procedures in [`RUNBOOK.md`](RUNBOOK.md); the client paste template +
tooling in [`CLIENT.md`](CLIENT.md). Full spec: [`docs/agent-channel-rfc.md`](../../docs/agent-channel-rfc.md) §4.

## Credential storage — where the secrets live, and why it is enforced

**The invariant.** Every piece of remote-channel credential material lives under
`$HOME/.claude/nexus-remote/` (the `principals_dir`), mode `0700`, owned by the
sandbox uid. Nothing credential-bearing is ever written into the nexus project
tree.

**Why `~/.claude` specifically.** Two independent reasons, either of which alone
would be sufficient — which is why this is not a preference:

1. **The project tree is group-shared.** `$SANDBOX_PROJECT_DIR` lives on
   `/shared` as `drwxrws---`: every member of the lab unix group can read it.
   It is also a git worktree, so files there are one `ng upload` away from a
   GitHub asset URL. A host private key or an `authorized_keys` there is
   readable by people who were never granted channel access.
2. **`~/.claude` survives a sandbox restart.** A restart destroys `/tmp`
   outright and can leave the project tree frozen. `~/.claude` and the project
   tree are the two writable mounts; only the former is both durable *and*
   `0700`. Credential **durability** and credential **secrecy** happen to point
   at the same directory.

So: do **not** relocate `principals_dir` into `monitor/.state/`, `/tmp`, or any
"convenient" tree. The next editor who finds `monitor.remote.principals_dir` and
thinks it belongs next to the other service state is the reader this section
exists for.

**Layout** (all inside `principals_dir`):

| Path | Mode | Secret? | Purpose |
|---|---|---|---|
| `ssh_host_ed25519_key` | `0600` | **yes** | server host key (the client pins its fingerprint) |
| `ssh_host_ed25519_key.pub` | `0644` | no | the fingerprint source; non-secret by design (§4.10) |
| `authorized_keys` | `0600` | **yes** | enrolled principals + their forced-command lines |
| `.authorized_keys.lock` | `0600` | **yes** | `flock` serialization for enroll/revoke |
| `enroll/<sha256>.token` | `0600` | **yes** | pending-token record: `principal=` + `expires=` only |
| `self-enroll.log`, `forced-command.log` | `0600` | **yes** | per-session audit |
| `banner.txt` | `0644` | no | the pre-auth policy banner shown to every client |

The **plaintext token is never written to disk** — the filename is its sha256,
and the body holds only the principal and the expiry.

**The enforcement (`_remote_principals_guard`, `monitor/_remote_lib.sh`).** Both
`monitor/remote-up.sh` and the supervisor call it before anything listens, and
refuse loudly on failure. It fails closed when the `principals_dir`:

- resolves outside `$HOME/.claude` — **both sides resolved physically**, so a
  symlink from inside `.claude` into shared storage does not smuggle it past,
  and a shared-prefix sibling (`~/.claude-evil`) is not "under" the root;
- is owned by another uid, or has a mode other than `0700` (same for `enroll/`);
- holds a group/other-**readable** *secret* file, or *any* group/other-**writable**
  file — including files the guard does not recognize.

`_remote_principals_harden` runs first and idempotently tightens the modes we
own (it only ever restricts). It deliberately **cannot** repair a wrong
*location* — that is never auto-"fixed", only refused. There is **no env escape
hatch**: hermetic tests relocate `HOME`, exactly as a sandbox restart would.

An **unresolvable owner fails closed**: if `id -u` or `_remote_owner_of` yields
nothing, the guard refuses rather than falling through. "We could not tell who
owns the credential directory" must never read as "it is fine".

**Why `_remote_owner_of` is a separate function.** A foreign-owned directory
cannot be *created* in-sandbox — it needs a second uid the bwrap userns does not
grant. So the ownership **decision** is tested by overriding `_remote_owner_of`
to inject a foreign uid, while the **reader** is tested unstubbed against a real
foreign-owned path (`/etc`, which the userns reports as the kernel overflowuid
`65534`, not `0`). Decision + reader together cover the check. Do not inline
`stat` into the guard: it would make the one fail-closed condition that cannot be
forged the one that is never tested — which is how a fail-closed check silently
becomes fail-open.

**Enrollment-token lifecycle.** Tokens are single-use and TTL'd
(`monitor.remote.enrollment_token_ttl_seconds`, default 900 s):

- **Redeem** is an atomic `mv`-based claim, so exactly one racer can consume a
  token; the record is deleted on consume, and a replay finds nothing to claim.
- An **expired** token is refused fail-closed at redeem, and `prune-enroll`
  drops its `authorized_keys` enroll line — so an expired token grants nothing
  by two independent mechanisms.
- `ng remote gc-tokens` (supervisor loop + `remote-up.sh`) then deletes the
  inert **records**: expired, corrupt, and stranded `*.token.consumed.*` claim
  files older than one TTL. This is *hygiene*, not access control — but a file
  that can never grant access should not outlive its purpose. Before this
  existed, six expired records sat on the live endpoint for ~9 days.

**The one artifact in the shared tree: `monitor/.state/remote-ssh.log`.** It is
the `services.registry` log column, tailed by `svc.sh` and the watcher, so it
stays there. That is safe **by content, enforced**, not by luck: the supervisor
and `sshd -o LogLevel=VERBOSE` emit connection IPs and key *fingerprints*, both
non-secret; `validate_auth_keys` reports a bad `authorized_keys` line by line
*number* and never echoes its bytes (it used to print the first 40 characters —
for the line it rejects, that is a raw `ssh-ed25519 AAAA…` blob prefix).
`test-remote-service-log.sh` asserts this, with a negative control proving the
secret-scanner can actually fail. The log rotates in place above
`monitor.remote.service_log_max_bytes` (default 8 MiB, keeping the last 2000
lines) — **truncate, never rename**, because `svc.sh` holds an `O_APPEND` fd on
that inode. Left unrotated it reached 49 MiB of port-scan noise.

## Stating security to the operator (reusable snippet)

When the operator asks "is this secure?", answer on both axes and keep them
distinct — the orchestrator can lift this verbatim:

> - **Encrypted?** Yes, always — SSH transport encryption with an ed25519
>   host key you pin.
> - **Authenticated?** Yes, always — public-key-only (no passwords), plus a
>   forced command that discards client-supplied options, all inside the
>   kernel sandbox.
> - **Network exposure?** Your choice of two safe postures. LAN-direct: the
>   listener is on your host's LAN IP, **pinned by `from_cidr`** to a source range
>   you declare (a broad subnet as a set-once default, a client `/32` for max
>   security, or `0.0.0.0/0` as a conscious any-source opt-in), behind a
>   pubkey-only, forced-command-confined, strong-crypto sshd — an EMPTY pin is
>   fail-closed. Loopback + tunnel: the listener stays on `127.0.0.1`, invisible
>   on the network, reached through an SSH forward. An all-interfaces
>   `bind_address: 0.0.0.0`/`::` is a separate axis and is refused outright.
> - **Who controls whom?** The client does. The client initiates requests and
>   reads the replies to its own requests; this orchestrator cannot push to the
>   client, start a session with it, or run anything on its machine. Replies are
>   data the client evaluates — never commands it executes. It is a pull-only,
>   client-controlled channel, not a command-and-control backchannel.

Encryption/auth are settled independently of the bind. "Loopback vs LAN" is
an **exposure** decision, NOT a "secure vs insecure" one — never present it
as the latter. And the control direction is fixed: the **client controls** the
channel and treats replies as data — the orchestrator never drives the client.


## What the client gets back in a reply

The orchestrator's `ng request reply` writes a `## Reply` + `reply:`
frontmatter carrying, per RFC §D.5:
- `worker.window` / `worker.directory` / `worker.session_id` — references
  to the spawned worker, its directory, and (for liveness) its session;
- `github_issue: owner/repo#N` when `publish: true` — the client watches
  that issue with its own GitHub access; OR
- `progress_path` / `results_path` (advisory) when `--no-publish` — the
  client pulls them with `request fetch <id> progress|results`, which is
  **path-confined by construction** to `replies/<id>/` and recomputes the
  path from the id (it ignores the advisory fields).

`await`/`fetch` are **ownership-scoped**: a principal can read only the
round-trip whose `origin` equals its own `remote-<principal>`.


## Why self-enrollment is rootless (the AuthorizedKeysCommand impossibility)

The token-gated self-enrollment rides a per-window enroll key over
`AuthorizedKeysFile`, NOT a dynamic `AuthorizedKeysCommand` (AKC), because an
in-sandbox sshd is non-root and OpenSSH refuses to execute a non-uid-0-owned
AKC. The full impossibility proof (and the rootless replacement it forced) is in
[`docs/remote-access-akc-note.md`](../../docs/remote-access-akc-note.md).
