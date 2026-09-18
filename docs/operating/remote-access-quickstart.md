# Remote access quick-start

A **confined, pull-only, client-controlled** SSH channel into this nexus
sandbox. A client on another machine (e.g. a second Claude) files requests into
the nexus and reads the replies to its own requests — nothing more. The client
is the CONTROLLER: the nexus can never push to it, open a session with it, or
run anything on its machine, and the channel is confined to this kernel sandbox.

This page is the two-minute path. For depth — bind postures, `from_cidr`
pins, the forward-only carrier, rotate/revoke, and the full security
rationale — see the [`nexus.remote-access`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.remote-access/SKILL.md)
skill.

## Get connected — one prompt to your orchestrator

Paste this to **your orchestrator** (it drives the enable + enrollment for you):

> Please enable the confined remote SSH channel and give me the one-paste
> enrollment message for my client. **Consult the `nexus.remote-access` skill**
> (if your cwd is inside `work/`, skills don't auto-discover — read
> `skills/nexus.remote-access/SKILL.md` by path) and **fill its "Orchestrator
> provisioning checklist"** so the enrollment form carries everything it needs:
> the principal, the bind posture + `from_cidr` pin, the connect coordinates
> (`<ENDPOINT>`/`<PORT>`/`<SSH-USER>` + any jump chain), the **full host public
> key line** and the `HostKeyAlias` to pin it under (a fingerprint alone is not
> pinnable — keep it as a cross-check), and the one-time token + enroll key
> (from `remote-up.sh` + `ng remote enroll-invite`). Use LAN-direct if my client
> host can reach this node directly; otherwise set up the loopback + tunnel
> posture. Tell me **which source address you expect to arrive** and whether it
> is my machine or a shared hop, since that decides what the `from_cidr` pin
> actually restricts. I'll paste your enrollment message straight into my client
> agent.

The orchestrator's job is spelled out in the skill: gather the checklist items
(each maps to the command that produces it), fill the **minimal
enrollment-response form**, and hand it back. You don't need to know those
details — the prompt above tells the orchestrator to.

## What you get back, and what to do with it

The orchestrator hands you **one message** to paste **verbatim** into your
client agent. It carries the control contract, a one-time **enroll private
key** + **token** (both secret — out-of-band only, never GitHub), the host
fingerprint to pin, and the connect coordinates. Your client agent then, on its
own host:

1. **Keygens its OWN permanent key** (private key never leaves the client).
2. **Saves the enroll key** to a file (`chmod 600`) — it is used once, for enrollment only.
3. **Pins the host key from the LINE you were given** — appending it to a
   dedicated `known_hosts.nexus`, keyed on a stable `HostKeyAlias`, with the
   fingerprint kept as a cross-check.

   > **A fingerprint cannot seed a pin.** If you are handed only `SHA256:…`,
   > your only route to populate `known_hosts` is to connect once and accept
   > what arrives — TOFU against an endpoint that (as this page notes) may be
   > held by a co-tenant. `ssh-keyscan` is no better: it reports the key a
   > server *claims*, without verifying any signature, and the real public key
   > is not secret, so anyone can replay it. Ask for the **full public key
   > line**; your orchestrator gets it from `monitor/remote-up.sh`.
   >
   > Pin under an **alias**, not an address. `127.0.0.1` is not an identity on
   > a host with a shared network namespace — every co-tenant sandbox is also
   > `127.0.0.1` — and an address-keyed pin breaks whenever the posture moves.
   > Pinned under an alias, a real endpoint migration cost one client **no
   > change at all**.
4. **Self-enrolls** by piping the token + its own public key to the enroll
   session, authenticated by the enroll key. The server validates the token
   (single-use, TTL'd), reconstructs the client's channel-only line itself, and
   prunes the enroll key.
5. **Reconnects with its OWN key** and runs `policy` (or `help`) for the full
   usage — `request file` / `await` / `fetch`.
6. **Asks the orchestrator for the remaining setup steps.** Getting the channel
   up is not the whole setup — there are follow-on steps the server delivers
   (e.g. the **reply-watcher**, which tells your client when a reply lands). The
   client obtains these BY ASKING: once connected, it files a request over the
   channel for *the remaining steps to complete my setup* and specifically for
   the reply-watcher setup. Because the completion steps are requested (not
   hard-coded here), this stays correct as the flow evolves:
   ```bash
   ssh -i ~/.ssh/nexus-remote -p <PORT> <JUMP-CHAIN> \
       -o HostKeyAlias=<ALIAS> -o UserKnownHostsFile=~/.ssh/known_hosts.nexus \
       -o StrictHostKeyChecking=yes <SSH-USER>@<ENDPOINT> \
       request file --kind question --slug complete-setup \
       --message "What are the remaining steps to complete my setup? Include the client helper set and how to run it."
   ```

   The connect line carries its own `-o` options and its own `-J` chain on
   purpose: a line that relies on your `ssh_config` can be silently rewritten by
   a wildcard `Host` stanza, and the resulting failure looks like DNS rather
   than config. Check any form against a fresh client with
   `ssh -G -F /dev/null …` and compare the `hostname` field to the same command
   without `-F /dev/null`.

Net effort for you: **one paste, no return paste, no raw secrets handled.**

## The client tooling is a SET of three files

Among the follow-on steps is the client helper set: `nexus-request`,
`nexus-reply-watch`, and the shared `_nexus_watch_lib.sh` that both scripts
source from beside themselves. **All three go in one directory.** Either script
installed alone exits `64` with `cannot load _nexus_watch_lib.sh` — it names the
path it looked for and tells you to re-request the set.

Your orchestrator produces the delivery with one command, which emits a
one-paste installer for the whole set plus digests computed at call time:

```bash
monitor/ng remote client-helper --base64
```

**Digests are never quoted by hand.** A sha256 written into a document is right
when written and wrong from the next commit onward — and because you verify
against the value your orchestrator gave you, *both sides agree and nothing
errors*. That has happened: a client verified cleanly against a digest four
revisions stale and installed the old helper.

### Verifying the hash is not a security check

**A digest handed to you by the same party that handed you the files proves one
thing: the bytes survived transit.** It is not a signature. It authenticates
nothing, and it establishes nothing about whether the code is safe to run. If
you match the hash, you have ruled out a mangled copy — and nothing else.

**Reading the source before running it is your job, and the hash does not do it
for you.** These are short POSIX-sh scripts, meant to be read. Before you
authorise the install, expect to:

- confirm the only `.` sources the companion library at a fixed path beside the
  script, and never reply bytes;
- check the frontmatter parser's key allowlist;
- count the outbound call sites and confirm they are the pinned `ssh`
  invocation;
- confirm no `eval`, no pipe-to-shell, no persistence, no phone-home;
- run `sh -n` over each file.

Then say what you checked. "Hash matched" describes the postman, not the code.

## Two network postures at a glance

| Posture | When | Shape |
|---|---|---|
| **LAN-direct + `from_cidr` pin** (recommended **when your own address is what arrives**) | The client host can reach this node on the LAN | The endpoint binds the host's LAN IP; the orchestrator pins a source range (a `/32`, a subnet, or `0.0.0.0/0` as a conscious opt-in). Client connects directly — no tunnel. **The pin restricts the LAST HOP, not you:** if you arrive via a bastion, jump host, VPN or NAT, it pins that shared device and constrains nothing about which client is behind it. What confines this endpoint unconditionally is the pinned host key, pubkey-only auth, the forced command and the sandbox. |
| **Loopback + tunnel/carrier** (zero LAN exposure) | You want the listener invisible on the network | The endpoint stays on `127.0.0.1`; the client reaches it through an SSH forward the operator opens, or a forward-only carrier line. |

Both are always encrypted (SSH host key you pin) and authenticated
(public-key-only, forced command). The bind choice is an **exposure** decision,
not a "secure vs insecure" one. The orchestrator picks and fills the per-site
values; you never edit config. Full detail lives in the
[`nexus.remote-access`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.remote-access/SKILL.md) skill.
