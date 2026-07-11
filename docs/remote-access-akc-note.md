# Why the remote-access self-enroll is rootless (the AuthorizedKeysCommand impossibility proof)

This note preserves the analysis that formerly lived as a fail-closed tombstone
script, `monitor/remote-authorized-keys-command.sh` (retired). The script itself
carried no logic worth keeping — it emitted nothing and exited 0 — but the reason
it exists at all is a load-bearing design constraint for the confined remote agent
channel (agent-channel RFC Part A, §4.9.1). It is recorded here so the constraint
survives the script's deletion.

Operator runbook for the channel: `skills/nexus.remote-access/SKILL.md` (in the repo, not the docs site)
and its companion `RUNBOOK.md`. Full spec: [`docs/agent-channel-rfc.md`](agent-channel-rfc.md) §4.9.1.

## What an `AuthorizedKeysCommand` would have done

Token-gated self-enrollment needs a way to authorize a client's *offered* key
for a one-shot, enroll-only forced command **only while an enrollment token is
pending** — a dynamic decision sshd cannot make from a static
`AuthorizedKeysFile` alone. The natural OpenSSH primitive for a dynamic key
decision is `AuthorizedKeysCommand` (AKC): sshd runs an external program,
passes it the offered key (`%t %k`, already signature-verified by sshd), and
authorizes whatever authorizing line the program prints. The retired script was
that program.

## Why it cannot work with an in-sandbox (non-root) sshd

The `sshd` for this channel runs **inside** the kernel `bwrap` sandbox as a
**non-root** user. OpenSSH's `auth_secure_path` (`auth2-pubkey.c` → `misc.c`)
requires that the `AuthorizedKeysCommand` file **and every path component above
it** be owned by **uid 0** and not group/world-writable. The agent-sandbox user
namespace has **no uid-0-owned files at all** — real root is mapped to `nobody`
(65534). So sshd refuses to *execute* any `AuthorizedKeysCommand` here, logging:

```
Unsafe AuthorizedKeysCommand "<path>": bad ownership or modes for file <path>
```

followed by `Failed publickey`. No relocation, trampoline, symlink, or `chmod`
can satisfy the uid-0 requirement from inside the sandbox: there is no uid-0
identity available to own the file.

This was reproduced hermetically against a throwaway `sshd` 7.6p1: even
`/bin/true` (owned by `nobody`, the sandbox's mapping of real root) is rejected
as an AKC. It also surfaced live — a confirmed off-host client (source = an sn2
bastion) hit exactly this: self-enroll was denied at the **auth layer**, before
any token could be read.

## The rootless replacement

Self-enroll now rides `AuthorizedKeysFile` — the one rootless key primitive that
works — via a per-window **enroll-only key**:

- `ng remote enroll-invite --principal P` mints `{one-time token, throwaway
  enroll keypair}` and installs a token-hash-tagged, enroll-only
  `authorized_keys` line (forced command = the enroll session, no shell, no
  channel verbs).
- The client connects **with the enroll key** and pipes
  `<token>\n<its-own-pubkey>` to `remote-enroll-session.sh`, which token-gates,
  server-reconstructs the permanent channel-only line for the **client's** key,
  consumes the token atomically, and prunes the enroll line.
- `remote-sshd-supervised.sh` prunes stale enroll lines on token expiry.

Outside a live-token window there is no enroll line, so an unknown key is denied
at the SSH layer — the same fail-closed property the AKC pending-token gate was
meant to provide, achieved without any uid-0 dependency.

See `monitor/remote-enroll.sh` (`enroll-invite` / `prune-enroll`),
`monitor/remote-enroll-session.sh`, and
`monitor/watcher/test-remote-self-enroll.sh` (the hermetic suite; its opt-in
`SELFENROLL_LIVE_SSHD=1` block reproduces both the root cause and the fix
end-to-end against a real sshd).
