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
> (`<ENDPOINT>`/`<PORT>`/`<SSH-USER>`), the host fingerprint, and the one-time
> token + enroll key (from `remote-up.sh` + `ng remote enroll-invite`). Use
> LAN-direct if my client host can reach this node directly (tell me which source
> IP to expect so you can pin it); otherwise set up the loopback + tunnel
> posture. I'll paste your enrollment message straight into my client agent.

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
3. **Pins the host fingerprint** you were given.
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
   ssh -i ~/.ssh/nexus-remote -p <PORT> <SSH-USER>@<ENDPOINT> \
       request file --kind question --slug complete-setup \
       --message "What are the remaining steps to complete my setup? Include the reply-watcher setup."
   ```

Net effort for you: **one paste, no return paste, no raw secrets handled.**

## Two network postures at a glance

| Posture | When | Shape |
|---|---|---|
| **LAN-direct + `from_cidr` pin** (recommended off-host) | The client host can reach this node on the LAN | The endpoint binds the host's LAN IP; the orchestrator pins your client's source range (a `/32`, a subnet, or `0.0.0.0/0` as a conscious opt-in). Client connects directly — no tunnel. |
| **Loopback + tunnel/carrier** (zero LAN exposure) | You want the listener invisible on the network | The endpoint stays on `127.0.0.1`; the client reaches it through an SSH forward the operator opens, or a forward-only carrier line. |

Both are always encrypted (SSH host key you pin) and authenticated
(public-key-only, forced command). The bind choice is an **exposure** decision,
not a "secure vs insecure" one. The orchestrator picks and fills the per-site
values; you never edit config. Full detail lives in the
[`nexus.remote-access`](https://github.com/<your-org>/nexus-code/blob/main/skills/nexus.remote-access/SKILL.md) skill.
