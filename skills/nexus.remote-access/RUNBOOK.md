# nexus.remote-access — operator RUNBOOK

Operator procedures for the confined remote SSH channel: choosing a bind
posture, enrolling a client, the forward-only carrier, rotate/revoke, and the
hard rules. This is a companion to [`SKILL.md`](SKILL.md) (skill discovery, the
guarantees, and enabling the endpoint). The client-facing paste template and
client-side tooling live in [`CLIENT.md`](CLIENT.md); threat-model rationale and
protocol reference in [`REFERENCE.md`](REFERENCE.md).

## Network exposure — two safe postures, both fully in-sandbox

Encryption and authentication are settled — always on, independent of the
bind (see the guarantees). The bind address governs the OTHER axis: how much
network the listener is reachable from. There are **two safe postures**, and
which fits depends only on whether you want the listener visible on the LAN.
Neither requires any action outside the sandbox: the sandbox shares the host
network namespace, so — exactly like every other service the operator runs
in-sandbox — it can bind either loopback OR a routable LAN address itself.

**Posture 1 — LAN-direct bind + `from_cidr` pin (recommended for off-host).**
Bind the endpoint on the host's LAN IP; an off-host client connects **directly**
to `<host>:<port>` — no tunnel, no carrier, nothing installed outside the
sandbox. This is the simplest path for a client on another machine, and it is
NOT "insecure": the listener is a hardened, pubkey-only, forced-command-confined,
host-key-pinned sshd with a strong-crypto allowlist. Because this is *sensitive*
access, a routable bind is **fail-closed on an EMPTY `from_cidr`** — the endpoint
REFUSES to come up until you declare a source range. It accepts any explicit,
well-formed CIDR (a malformed one is refused so a typo can't silently drop the
pin). Choose along a breadth ladder:

- **Broad subnet — recommended set-once default.** Pin your campus/LAN block once
  and any client on it can reach the auth stage; no per-client lookup. E.g.
  `140.107.0.0/16` (an EXAMPLE — the <your-institution> campus block; substitute your own
  network). Broader than any one client **by construction** — defence in depth,
  never a client identity control.
- **`/32` — one address, and READ THE NEXT PARAGRAPH before calling it "max
  security".** It admits exactly one source address. Whether that is a real
  client restriction depends entirely on **whose** address arrives.
- **`0.0.0.0/0` — any source, a conscious opt-in.** Exposes the SSH *pre-auth*
  surface to the whole reachable network. Auth stays pubkey-only + forced-command
  + strong-crypto + sandbox-confined (worst case: a confined channel login), but
  pre-auth SSH 0-days are the class this pin defends against — type it on purpose.

> ### `from_cidr` pins the LAST HOP, not the client
>
> **This is the sharpest trap in the subsystem, because the pin is present,
> correctly written, and still means much less than it looks like.** Where
> arrival is mediated by a **bastion, jump host, VPN concentrator or NAT**, the
> address the server sees is that **shared device's**. Pin it, and the `from=`
> line authenticates *the shared device* — infrastructure every user of it
> shares — while constraining **nothing about which client** sits behind it.
> Combined with a routable bind, that is the weaker posture wearing the
> appearance of the stronger. A green `from=` line is not evidence of a client
> restriction, and a `/32` is not automatically "max security": a `/32` naming
> an institutional bastion is among the *weakest* pins you can write, because
> it reads like the strongest.
>
> **Determine which case you are in, and say so.** The pin is meaningful when
> the **client's own** address is what arrives; it is largely decorative when a
> **shared hop's** address is what arrives. The ground truth is the peer
> address the server actually sees (`SSH_CLIENT`, which is what
> `_remote_source_guard` evaluates) — **not** the configured value. On the
> client, `ssh -G <target>` shows the route it will take and therefore which
> address arrives. If the pin resolves to a shared bastion, record that in the
> capability note rather than counting it as a control.
>
> **This also weakens a re-enrollment justified by the pin.** If you revoke and
> re-enroll to get `from=` onto a credential, and the CIDR you write is a
> shared hop, the new line is pinned in form and unpinned in substance. Re-derive
> the justification **before** the move, not after.
>
> **What is doing the work unconditionally** — on any topology, in either
> posture: the **pinned host key**, **public-key-only auth**, the **forced
> command**, and the **kernel sandbox boundary**. `from_cidr` shrinks the
> pre-auth surface, which is genuinely worth having; it is not what makes a
> routable bind acceptable.
>
> `monitor/remote-up.sh` prints the effective meaning of your configured pin on
> every bring-up, so the weak case is reportable rather than silent.

**Bastion hop — optional, most clients skip it.** Most clients reach the host
**directly** and need no jump host. ONLY if the client's network cannot route to
the endpoint directly (e.g. it sits behind a campus bastion reached by
`ProxyJump`) does the connect line need `-J`. Set `monitor.remote.jump_hosts` to
a **comma-separated chain** (`hop1,hop2`, applied in order) and the rendered
client lines carry it — a *single* hop assumes the endpoint host is directly
reachable from that hop, which off-site it often is not. In this case the source
IP the host sees is the BASTION's, not the client's laptop, so per the box above
a pin naming it restricts the bastion and not the client; pin it for pre-auth
surface reduction, and do not record it as a client control. Config + connect
(broad-subnet default shown, direct connect — no jump host):

```yaml
monitor: { remote: { bind_address: <HOST-LAN-IP>, from_cidr: "<YOUR-SUBNET>/16" } }   # or <CLIENT-IP>/32, or 0.0.0.0/0
```
```bash
# Off-host client connects DIRECTLY (no tunnel). <SSH-USER> = the in-sandbox login user.
ssh -i ~/.ssh/nexus-remote -p <PORT> <SSH-USER>@<HOST-LAN-IP> policy
```

**Posture 2 — loopback + tunnel/carrier (zero LAN exposure).** Keep the default
`bind_address: 127.0.0.1`; the listener never appears on any shared NIC. An
off-host client reaches it by forwarding the port into the host over SSH. Two
ways to open that forward without granting the client a shell on the host:

- **Operator opens it** with their EXISTING cluster login (`ssh -N -L
  <PORT>:127.0.0.1:<PORT> <user>@<host>`), client talks to `localhost:<PORT>`.
  Nothing new installed; the client only ever sees `localhost`.
- **Forward-only carrier** for a client-autonomous tunnel: the operator installs
  ONE restricted `authorized_keys` line on the host (generated by `ng remote
  carrier-authline`) that lets the client's key ONLY port-forward to the nexus
  port — no shell. See "Off-host access: the forward-only carrier" below. This
  is the one posture that needs an outside-sandbox step (one line), so use it
  only when you want BOTH zero LAN exposure AND an autonomous client tunnel.

**Choosing:** default to Posture 1 for an off-host client that can reach the
host on the LAN (simplest, in-sandbox, `from_cidr`-pinned) — the operator's own
other services already bind the LAN this way. Prefer Posture 2 when you want the
listener invisible on the network. **Never** set `bind_address: 0.0.0.0`/`::`
(all-interfaces) — that's a separate axis and the guard refuses it regardless of
`from_cidr`; a routable bind always carries a non-empty `from_cidr` pin (which may
be as broad as `0.0.0.0/0` if you consciously choose any-source).


## Enrolling a remote client — ONE-PASTE token self-enroll over SSH

Enrollment is automated and **pubkey-only**. Because an in-sandbox sshd is
non-root and cannot run an `AuthorizedKeysCommand`, self-enroll rides a
per-window **throwaway enroll key**: `ng remote enroll-invite` mints a one-time
token + a throwaway enroll keypair and installs the enroll PUBLIC key as an
enroll-only authorized_keys line. The operator's single paste carries the enroll
PRIVATE key + the token; the client self-generates its OWN permanent key, enrolls
it over the enroll session, then reconnects with its own key. The server never
gains a password path. The operator pastes ONE prompt and runs no second command.

**How it works (so an orchestrator can answer "is this safe?").** `enroll-invite`
installs a per-window enroll-only authorized_keys line — `command="<enroll-session>
<token-hash>",restrict[,from=…]` on the throwaway enroll PUBLIC key. The client
connects WITH THE ENROLL KEY (which lands on that line) and pipes
`<token>\n<its-own-public-key>` on stdin; the enroll session refuses any client
command, verifies sha256(token) == the baked hash, then delegates to
`remote-enroll.sh enroll`, which validates the token (single-use, TTL'd,
sha256-at-rest, fail-closed), reconstructs the permanent **channel-only** line for
the CLIENT's key SERVER-SIDE (forced command + `restrict` [+ `from=`], key baked
server-side — no client options survive), and consumes the token atomically. On
success it prunes the enroll line, so the window closes at the key layer too.
Outside a live-token window the enroll line is gone → an unknown key is denied at
the SSH layer; enrolled keys match the authorized_keys FILE directly. The bootstrap
hardens the *external enrollment path* only — the kernel sandbox remains the
boundary; a worst-case compromise yields a *confined channel login*, not escape.

**Orchestrator-side recipe — invite, fill, hand over. Done.**

```bash
# 1. Mint a one-time token + a THROWAWAY enroll keypair bound to a principal,
#    with a GENEROUS TTL so it survives the human paste + the client's self-enroll
#    round-trip. BOTH the token (REMOTE_ENROLL_TOKEN=…) and the enroll PRIVATE key
#    block print to THIS session ONLY — BOTH are SECRETS. Embed them into the
#    client prompt below as <ONE-TIME-TOKEN> and <ENROLL-PRIVATE-KEY>. The pasted
#    prompt IS the approved out-of-band delivery; it is NEVER posted to GitHub.
monitor/ng remote enroll-invite --principal alice --ttl 3600   # → REMOTE_ENROLL_TOKEN=nxr1_… + enroll privkey block (≤86400s TTL ceiling)

# 2. Non-secret values for the prompt's other placeholders:
monitor/ng remote host-fingerprint    # → <HOST-FINGERPRINT> (pin; non-secret)
whoami                                 # → <SSH-USER> (the in-sandbox login user)
# <ENDPOINT> = host LAN IP (Posture 1) or localhost via tunnel (Posture 2);
# <PORT> = the port IN FORCE (monitor/remote-up.sh --port, or its `Port:` line at bring-up)
#   — the recorded setup choice, not necessarily monitor.remote.port;
# <TUNNEL-TARGET> = user@node for THIS sandbox's host.

# 3. Fill the single client-agent prompt (next subsection) and hand the WHOLE
#    block to the operator to paste into their client agent. The client
#    self-enrolls over SSH with the enroll key — you run NO `ng remote enroll`.
#
# 4. If the client is an AGENT that should not block on await, ALSO hand over
#    the client helper SET (out-of-band, like the key — never over the channel).
#    It is THREE files, not one — nexus-request, nexus-reply-watch and the
#    shared _nexus_watch_lib.sh they both source from beside themselves — and
#    either script installed alone exits 64. Do not enumerate or transcribe
#    them by hand, and NEVER quote a sha256 from memory or from a document:
#
#        monitor/ng remote client-helper --base64
#
#    That emits a one-paste installer for the whole set plus digests computed
#    AT CALL TIME. A hash written into a document is correct when written and
#    wrong forever after, and both sides then agree on the stale value — the
#    exact failure this verb exists to make impossible.
#    See "Delivering the helper set" in CLIENT.md.
```

> **Manual fallback** (only if the self-enroll bootstrap is unavailable — e.g.
> `enroll-invite`'s enroll session cannot run): mint a bare token with
> `monitor/ng remote issue-token --principal <P> --ttl <S>`, have the client send
> its public key out-of-band, and run
> `monitor/ng remote enroll --pubkey <file> --token <ONE-TIME-TOKEN>` yourself.
> Same token machinery; one extra human step, no enroll key.

**State the access restriction up front (operator informed-choice).** Tell the
operator which command policy is in effect and what it implies:

- **`channel-only`** (default): the client can ONLY file requests + read/fetch
  its own replies (+ optional read-only attach). It canNOT run commands or open
  a shell. Broader access is arranged strictly out-of-band, operator-to-operator
  (see "Privilege expansion" below) — never via the channel.
- **`unfiltered`**: the client gets a sandbox-confined SHELL (arbitrary
  commands, still inside the sandbox). Choose this only for a trusted remote
  agent; set `monitor.remote.command_policy: unfiltered` before enrolling.

### Orchestrator provisioning checklist — what to provide

Before you can fill the enrollment-response form (in [`CLIENT.md`](CLIENT.md)),
gather (or decide) each
of these. This is the **form the orchestrator fills**: every field maps to the
one command (or one decision) that produces it, so you can go from zero → a
filled form deterministically. Work top-to-bottom; row 8 is the only SECRET
(row 9 is an OPTIONAL, non-secret connect flag).

| # | Field to fill | What it is / decide | Produced by |
|---|---|---|---|
| 1 | `<PRINCIPAL>` | short name for this client (`[A-Za-z0-9_-]`) | you choose |
| 2 | **bind posture** + `from_cidr` | LAN-direct + a source-CIDR pin (off-host, recommended) **or** loopback + tunnel (zero LAN exposure) — see "Network exposure" | decide, then set in `config/nexus.yml` and apply with `monitor/remote-up.sh` |
| 3 | `<ENDPOINT>` | the host's LAN IP (Posture 1) **or** `localhost` reached via a tunnel (Posture 2) | `monitor/remote-up.sh` prints the bind address |
| 4 | `<PORT>` | listener port — the one actually IN FORCE, which is the port `remote-up.sh` recorded at setup, **not** necessarily `monitor.remote.port` (a preference). Unset, the preference itself is DERIVED per-operator — `22100 + cksum(<operator identity>) % 900`, where the identity is `$MONITOR_REMOTE_OPERATOR_IDENTITY`, else `$USER`/`whoami`, else `github.user_login` (`_remote_operator_identity`) — never the legacy constant `22022` (<your-org>/nexus-code#893). | `monitor/remote-up.sh --port` (prints in-force / recorded / configured / derived) |
| 5 | `<SSH-USER>` | the in-sandbox login user | `whoami` |
| 6 | `<HOST-KEY-LINE>` + `<ALIAS>` + `<HOST-FINGERPRINT>` | the **full public key line** the client appends to `known_hosts.nexus`, the `HostKeyAlias` it keys the pin on, and the fingerprint as a CROSS-CHECK (all **non-secret**). **A fingerprint alone is not pinnable** — a client holding only `SHA256:…` must TOFU to populate the pin, and `ssh-keyscan` reports a key a server merely *claims*. Pin on the alias, not the address: `127.0.0.1` is not an identity here, and an address-keyed pin breaks on every posture move. | `monitor/remote-up.sh` (prints the line, the alias and the fingerprint, read off the live endpoint) |
| 7 | **TTL** | token lifetime — generous enough to survive the human paste + the client's self-enroll round-trip (≤ `86400`s) | you choose, passed as `--ttl S` |
| 8 | `<ONE-TIME-TOKEN>` + `<ENROLL-PRIVATE-KEY>` | **SECRET** bundle — the one-time token + throwaway enroll private key, bound to the principal | `monitor/ng remote enroll-invite --principal <PRINCIPAL> --ttl <TTL>` |
| 9 | `<JUMP-CHAIN>` | **OPTIONAL**, site-specific — `-J hop1,hop2`, **comma-separated and in order**, only if the SSH path crosses one or more bastions. A SINGLE hop assumes the endpoint host is directly reachable from it, which off-site it often is not. | `monitor.remote.jump_hosts` (omit for a direct-reachable client) |
| 10 | `<PIN-OPTS>` | `-o HostKeyAlias=… -o UserKnownHostsFile=… -o StrictHostKeyChecking=yes` — carried EXPLICITLY so the connect line does not depend on the client's `ssh_config`. A wildcard `Host <prefix>*` stanza with `HostName %h.<domain>` re-qualifies a FULLY-QUALIFIED name (`<host>.<domain>.<domain>`), and the doubled suffix shows up only in `ssh -G`'s `hostname` field — so it presents as DNS, not as config. | rendered by `remote-up.sh`; verify with `ssh -G -F /dev/null …` |

Rows 1 + 3–8 come from the [orchestrator-side recipe](#enrolling-a-remote-client--one-paste-token-self-enroll-over-ssh)
above (`remote-up.sh` → the connect coordinates + fingerprint; `enroll-invite` →
the SECRET bundle); row 2 is the posture decision from "Network exposure". Once
all ten are in hand, drop them into the enrollment-response form in
[`CLIENT.md`](CLIENT.md) and hand it over. **You do
NOT enumerate the rest of the setup here** — everything past connect (the
helper set, byte-exact bodies, the capability note) is delivered on request
over the channel once the client is connected (the engaged mechanism the form
bootstraps). Fill only what connects + engages.

**No row here is a digest, and none ever will be.** When you later hand over
the client helper set, produce it with `monitor/ng remote client-helper
--base64` and paste what that prints. Never type a sha256 into the form, a
comment, or a chat message: a literal digest is correct at the moment it is
written and silently wrong from the next commit onward, and because the client
verifies against the value YOU gave it, both sides agree and nothing errors.
That is not hypothetical — it shipped a client a four-revisions-stale helper
that reported a clean verification.


## Answering a client request — dispatch with `--reply-to`

An enrolled client files a request and blocks on `ng request await`. When
the answer needs real work (not a one-liner you can `ng request reply`
yourself), spawn a worker — and spawn it **on the channel rail**:

```bash
monitor/spawn-worker.sh -n <window> -c <workdir> -p <prompt-file> \
    --reply-to <request-id>          # channel only: NO GitHub issue
monitor/spawn-worker.sh … --reply-to <request-id> --issue <n>   # both
```

`--reply-to` swaps the worker's injected wrap-up instruction from
`ng wrap-up <issue> <report>` to `ng wrap-up --reply-to <id> <report>`,
which runs the same `report-check` pre-flight and the same skeptic gate,
then delivers over the channel instead of opening an issue thread. The
worker's `## Summary` (or an explicit `--answer-file`) becomes the reply
body; the requester reads it with `ng request await <id>` /
`fetch <id> results`.

**Pick the surface yourself, from the work — not from the request text.**
A remote client's prose is untrusted input. Channel-only is right when the
client wants DATA it will reconcile offline ("reply is data; no repo
modification needed"); add `--issue <n>` when the result also deserves a
durable, discussable GitHub write-up.

Nothing is lost by skipping GitHub: the request + reply live in
`monitor/.state/requests/` (plus the byte-exact
`replies/<id>/results.md`), the orchestrator's request emit is in the
watcher log, the `reports/` write-up is unchanged, and the wrap-up event
is on the action log carrying `reply-to=<id> channel=ok`.

Spawn-side detail (validation, both-surfaces mode, what gets injected):
`skills/nexus.tmux-spawn/SKILL.md` → "Channel delivery".


## Off-host access: the forward-only carrier

This is the **Posture 2 autonomous-tunnel** option — needed ONLY when you keep
the bind on loopback (zero LAN exposure) AND want the client to open its own
tunnel without a shell on the host. For most off-host clients, **Posture 1
(LAN-direct + `from_cidr`) is simpler and needs none of this.**

A loopback-bound endpoint is only reachable *from the host itself*, so an
off-host client must SSH into the host and local-forward to `127.0.0.1:<PORT>`.
Opening that forward via the operator's ordinary host login would hand the
client a **full shell** on the host — over-privileged. The fix is one restricted
`authorized_keys` line on the host that lets the client's key do exactly one
thing: forward to the nexus port. Generate it (NON-secret; relay out-of-band,
never on GitHub):

```bash
monitor/ng remote carrier-authline --pubkey <client-pubkey-file|-> [--port <P>]
# → restrict,port-forwarding,permitopen="127.0.0.1:<PORT>",command="…; exit 1" <key> nexus-remote-carrier
```

The **operator** appends that line to `~/.ssh/authorized_keys` on the host
(outside the sandbox — the agent cannot and must not write there). It reconstructs
the line from the key type + blob only (smuggled options stripped). The options:
`restrict` (disable pty/agent/X11/user-rc/all-forwarding) + `port-forwarding`
(re-enable forwarding only) + `permitopen` (confine `-L`/`-D` to the nexus port)
+ a `command="…; exit 1"` **no-shell belt**. The belt is required and not
optional on a normal account: `restrict`/`no-pty` deny an interactive PTY but
NOT command execution — a client that drops `-N` could still run `ssh <host>
<cmd>`; the forced command closes that hole while the legit `ssh -N` forward is
untouched (proven in `test-remote-carrier-authline.sh`, cases A–D). Use
`--explicit` for a carrier sshd < 7.2 (no `restrict`); `--no-shell-belt` only for
a dedicated `nexus-carrier` account whose shell is `/usr/sbin/nologin`.

**Security property.** A compromised client tunneling through the carrier still
cannot get a shell or reach anything but `127.0.0.1:<PORT>` — `permitopen`
blocks other `-L`/`-D` targets, the belt blocks exec, `restrict` blocks
pty/agent/X11. It then hits the loopback-bound nexus sshd (its own forced command
+ sandbox). Two confinement layers, no shell at either.

**Alternatives considered.** (B) Routable bind + `from_cidr` — this is now
Posture 1, the *recommended* in-sandbox default (the sandbox CAN bind routable;
`from_cidr` + the hardened sshd confine it), not an exotic exception. (C)
`ProxyCommand` via a netns/UNIX-socket bridge — strong but needs bespoke
per-host bridge infra; more moving parts for no gain over A or Posture 1.

## Privilege expansion — strictly out-of-band, operator-to-operator

**The nexus has NO mechanism that accepts or routes a privilege-expansion
request** — deliberately, so the nexus can never auto-expand a remote
principal's access without this sandbox operator's explicit, manual action
(operator directive, PR `#379`). The session only *informs* (banner / `policy`
verb) that broader access exists and is obtained elsewhere.

The flow is human, out-of-band: the **remote client asks its own operator**;
that operator arranges it **operator-to-operator** with this sandbox's
operator. If this operator agrees, they make the change manually on the nexus
side — there is no request the orchestrator or watcher acts on:

```bash
# THIS sandbox operator, by hand, after agreeing out-of-band:
# set monitor.remote.command_policy: unfiltered   (in config/nexus.yml)
monitor/remote-up.sh                              # re-applies the policy
monitor/ng remote revoke  --principal <name>      # drop the old (channel-only) key
monitor/ng remote enroll-invite --principal <name>  # re-enroll under the new policy (one-paste self-enroll; secrets out-of-band)
```

No request channel, no orchestrator decision, no GitHub — a manual,
operator-driven config change is the only path to relaxation.


## Rotate / revoke

- **Rotate**: re-run the enroll flow with a fresh key + a new token; the
  new line replaces the old for that principal (re-enroll overwrites).
- **Revoke immediately**: `monitor/ng remote revoke --principal alice`
  removes that line — no service restart needed. List enrolled
  principals (no key material) with `monitor/ng remote list`.


## Hard rules

- **NEVER** put a private key, token, or password on GitHub (PR / issue /
  comment / wiki / release / commit / log) or under `reports/` (which
  `ng wrap-up` uploads). Run `ng remote guard <draft>` before any
  GitHub-bound write that might contain key/token material; it exits
  non-zero (refuse the write) on a match.
- **NEVER** print a token or private key into a pane the remote client can
  `attach -r` to — describe, don't echo.
- **A routable bind is fail-closed on an EMPTY `from_cidr`; an all-interfaces
  bind is refused.** Both postures are safe and in-sandbox (see "Network
  exposure"): LAN-direct requires a SPECIFIC host IP **plus** a non-empty
  `from_cidr` pin (the endpoint won't start otherwise). The pin accepts any
  well-formed CIDR — a broad subnet (recommended set-once default), a client
  `/32` (max security), or `0.0.0.0/0` (a conscious any-source opt-in that
  exposes the pre-auth surface); a malformed value is refused. A wildcard
  `bind_address: 0.0.0.0`/`::` is a separate axis and is rejected outright;
  loopback keeps the listener off every NIC.
- A wedged/compromised `sshd` is **emit-only**: it is not blind-restarted;
  the watcher escalates via `--- service health ---` for orchestrator
  judgment (see `nexus.service-recovery`).
