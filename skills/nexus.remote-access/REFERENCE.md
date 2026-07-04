# nexus.remote-access — REFERENCE (rationale + protocol)

Threat-model rationale and protocol reference for the confined remote SSH
channel. Companion to [`SKILL.md`](SKILL.md) (the guarantees + enabling);
operator procedures in [`RUNBOOK.md`](RUNBOOK.md); the client paste template +
tooling in [`CLIENT.md`](CLIENT.md). Full spec: [`docs/agent-channel-rfc.md`](../../docs/agent-channel-rfc.md) §4.

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
