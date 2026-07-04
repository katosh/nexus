#!/usr/bin/env bash
# test-channel-integration.sh — the ONE opt-in end-to-end integration tier
# for the confined remote request/reply channel (agent-channel RFC Part A).
#
# WHY THIS EXISTS (the seam every other test cannot reach)
#   Every existing client/server test STUBS `ssh` (and `gh`), so nothing that
#   actually crosses the process boundary — stdin plumbing, the sshd daemon's
#   ASCII locale, ssh's argv→SSH_ORIGINAL_COMMAND flattening, the forced
#   command's re-tokenization — ever runs in CI. Three shipped bugs (an emit
#   gate, a C-locale UnicodeDecodeError, a `--message -` sentinel bug) and the
#   P0 empty-body defect all lived in exactly that stubbed seam; the first real
#   client was production. This tier boots a THROWAWAY loopback sshd and drives
#   the REAL remote-forced-command.sh + request-channel.sh + client tool over a
#   REAL `ssh` on 127.0.0.1, so the boundary is exercised for real.
#
# WHAT IT PINS that the stub tier could not see:
#   * `request file --message-stdin` streams a byte-adversarial body over a real
#     ssh session under a C-locale daemon and lands byte-exact under ## Details.
#   * a server-side reply materializes results.md that `request fetch results`
#     returns byte-exact over ssh.
#   * `request await` exit codes (replied=0, pending/timeout=4) propagate through
#     ssh to the client.
#   * the forced command REFUSES (never ignores) a disallowed verb and an
#     injected --origin spoof over real ssh, mutating no state.
#   * the `nexus-request` client tool drives the whole submit→reply→emit round
#     trip against the real endpoint via its documented $SSH / NEXUS_REMOTE_SSH_*
#     seams, with a byte-exact reply.
#
# GATING
#   SLOW test: self-skips (green) unless SLOW_TESTS=1 (the CI SLOW lane sets it;
#   the fast iteration loop does not). Additionally AUTO-SKIPS (green, with a
#   reason) when the ssh client, ssh-keygen, or an sshd binary is absent, or the
#   throwaway sshd refuses to start (e.g. the sandbox blocks the bind/exec). A
#   skip is never a red failure.
#
# RESIDUE
#   sshd is killed by RECORDED pid (identity-verified, never pkill-by-pattern);
#   the fixture dir is removed on EXIT on every path. It NEVER touches the live
#   monitor/.state, the user's ~/.ssh, or any system sshd config.
#
# Run:      SLOW_TESTS=1 bash monitor/watcher/test-channel-integration.sh
# Skip-proof (sshd forced-unavailable):
#           SLOW_TESTS=1 NEXUS_TEST_SSHD_BIN=/no/such/sshd bash monitor/watcher/test-channel-integration.sh

set -uo pipefail

_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_test_helpers.sh
. "$_dir/_test_helpers.sh"

# monitor/watcher/ -> repo root; the real production scripts under test.
REPO_ROOT=$(cd "$_dir/../.." && pwd)
WRAPPER="$REPO_ROOT/monitor/remote-forced-command.sh"
CHAN="$REPO_ROOT/monitor/request-channel.sh"
CLIENT="$REPO_ROOT/monitor/client/nexus-request"

# ── SLOW gate ──────────────────────────────────────────────────────────
if [[ -z "${SLOW_TESTS:-}" ]]; then
    echo "skipped: test-channel-integration (SLOW_TESTS unset; set SLOW_TESTS=1 to run the real-sshd round-trip)"
    exit 0
fi

skip() { echo "skipped: test-channel-integration — $*"; exit 0; }

# ── precondition detection (each maps to a distinct, reported skip) ────
command -v ssh        >/dev/null 2>&1 || skip "ssh client not found on PATH"
command -v ssh-keygen >/dev/null 2>&1 || skip "ssh-keygen not found on PATH"

# Locate an sshd binary. NEXUS_TEST_SSHD_BIN, when SET (even to a bogus path),
# is honoured verbatim with NO fallback — the deterministic knob the skip-proof
# uses to force the "sshd absent" branch. Otherwise: PATH first, then the same
# sbin fallbacks the production supervisor probes (so a dev box / CI runner with
# sshd in /usr/sbin but not on PATH still RUNS the tier rather than skipping).
# NB a bare PATH mask cannot hide an absolute /usr/sbin/sshd (by design — the
# fallback mirrors remote-sshd-supervised.sh:locate_sshd), so the override knob
# is the honest way to exercise the skip path.
find_sshd() {
    if [[ -n "${NEXUS_TEST_SSHD_BIN+x}" ]]; then
        [[ -n "$NEXUS_TEST_SSHD_BIN" && -x "$NEXUS_TEST_SSHD_BIN" ]] \
            && { printf '%s' "$NEXUS_TEST_SSHD_BIN"; return 0; }
        return 1
    fi
    local c
    c=$(command -v sshd 2>/dev/null) && { printf '%s' "$c"; return 0; }
    for c in /usr/sbin/sshd /sbin/sshd /usr/local/sbin/sshd; do
        [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
SSHD_BIN=$(find_sshd) || skip "sshd binary not found (the in-sandbox sshd transport is the agent_sandbox side, RFC §4.6/A1)"

# A free high (>1024) loopback port. python3 kernel-assigned is the reliable
# path; a bash /dev/tcp probe loop is the fallback.
free_port() {
    local p i
    if command -v python3 >/dev/null 2>&1; then
        p=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null) \
            && [[ "$p" =~ ^[0-9]+$ ]] && { printf '%s' "$p"; return 0; }
    fi
    for i in $(seq 1 50); do
        p=$(( (RANDOM % 20000) + 20000 ))   # 20000–39999, all > 1024
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
            printf '%s' "$p"; return 0
        fi
        exec 3>&- 2>/dev/null || true
    done
    return 1
}

# ── fixture + guaranteed cleanup ───────────────────────────────────────
FX=$(mktemp -d "${TMPDIR:-/tmp}/nexus-chanint.XXXXXX") || skip "mktemp -d failed"
SSHD_PID=""
cleanup() {
    # Identity-verified kill: signal the sshd only if /proc still shows the
    # fixture path in its argv (a recycled pid can't match) — never pkill.
    [[ -n "$SSHD_PID" ]] && th_kill_fixture_pid "$SSHD_PID" "$FX" TERM
    rm -rf "$FX"
}
trap cleanup EXIT
# An uncaught SIGINT/SIGTERM does NOT run the EXIT trap; without this a
# signal-killed run orphans the backgrounded sshd and leaks the fixture dir.
trap 'cleanup; trap - INT TERM EXIT; exit 130' INT TERM

STATE="$FX/state"
REQ_DIR="$STATE/requests"
mkdir -p "$STATE" "$FX/principals"

PORT=$(free_port) || skip "could not find a free loopback port"
PRINCIPAL=testclient

# Throwaway host key + client keypair in the fixture (never ~/.ssh).
ssh-keygen -q -t ed25519 -N '' -C 'nexus-chanint-host'   -f "$FX/hostkey"   </dev/null || skip "ssh-keygen (host) failed"
ssh-keygen -q -t ed25519 -N '' -C 'nexus-chanint-client' -f "$FX/clientkey" </dev/null || skip "ssh-keygen (client) failed"
chmod 600 "$FX/hostkey"

# services.registry with the single enable row the forced command's gate 1
# (_remote_registered) checks — awk -F'\t' matches field 1 == nexus-remote-ssh.
printf 'nexus-remote-ssh\tremote\n' > "$FX/services.registry"

# The authorized_keys line MIRRORS the real per-key shape built by
# remote-enroll.sh:cmd_enroll — `command="<wrapper> <principal>",restrict` +
# the trailing `<principal>@nexus-remote` identity comment — with ONE addition:
# an `env …` prefix pins the state/registry/principals/log dirs into the
# fixture. sshd strips the client environment (PermitUserEnvironment=no, no
# AcceptEnv) and OpenSSH 7.6p1 has no per-key SetEnv, so baking the env into the
# forced command is the only way to point the real ng at fixture state without
# touching the live .state. The restriction options and the command/principal
# shape are the production line verbatim; the KEY field is not quite — the
# production line carries _safe_pubkey's reconstructed `<type> <blob>` (comment
# stripped) while this one keeps ssh-keygen's comment (a trailing field sshd
# ignores). The _safe_pubkey reconstruction is enrollment's boundary, not the
# wrapper's, so this tier deliberately does not exercise it.
ENVP="env NEXUS_STATE_DIR=$STATE NEXUS_SERVICES_REGISTRY=$FX/services.registry MONITOR_REMOTE_PRINCIPALS_DIR=$FX/principals NEXUS_REMOTE_LOG=$FX/principals/forced-command.log"
printf 'command="%s %s %s",restrict %s %s@nexus-remote\n' \
    "$ENVP" "$WRAPPER" "$PRINCIPAL" "$(cat "$FX/clientkey.pub")" "$PRINCIPAL" \
    > "$FX/authkeys"
chmod 600 "$FX/authkeys"

# Self-contained sshd_config written by the test. Mirrors the hardened posture
# of remote-sshd-supervised.sh:build_sshd_args (pubkey-only, no PAM, no
# forwarding, no user-rc/env, the strong-crypto allowlist) — the client must
# negotiate with the SAME daemon posture production uses. AuthorizedKeysFile,
# HostKey, PidFile all point into the fixture; StrictModes off so the fixture's
# ownership/mode doesn't trip a non-root sshd.
cat > "$FX/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $FX/hostkey
PidFile $FX/sshd.pid
AuthorizedKeysFile $FX/authkeys
Protocol 2
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
HostbasedAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
AllowUsers $USER
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no
GatewayPorts no
PermitTTY no
PermitUserRC no
PermitUserEnvironment no
AllowStreamLocalForwarding no
UsePAM no
PrintMotd no
StrictModes no
LoginGraceTime 15
MaxSessions 4
LogLevel VERBOSE
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com
EOF

# Gate the GENERATED config through `sshd -t` first: a config sshd REJECTS is a
# bug in this test's config generation and must RED — a green skip there would
# hide a regression in the very seam this tier guards, forever (skips read as
# pass in the SLOW lane). Only an accepted-config startup failure (bind/exec
# blocked by the environment) remains a skip.
if ! cfg_err=$("$SSHD_BIN" -t -f "$FX/sshd_config" 2>&1); then
    printf '  FAIL: generated sshd_config rejected by sshd -t (test bug, not environment):\n%s\n' "$cfg_err" >&2
    FAIL=$(( FAIL + 1 ))
    th_summary_and_exit
fi

# Launch under a C locale — this reproduces the daemon-side ASCII locale that a
# UTF-8 request body must survive (the forced command's _chan_apply_utf8_locale
# is what closes that seam). If sshd dies on bind/exec with a VALID config, we
# SKIP (green), not FAIL.
LC_ALL=C LANG=C "$SSHD_BIN" -D -e -f "$FX/sshd_config" > "$FX/sshd.log" 2>&1 &
SSHD_PID=$!

up=0
for _ in $(seq 1 50); do
    if grep -q 'Server listening' "$FX/sshd.log" 2>/dev/null; then up=1; break; fi
    kill -0 "$SSHD_PID" 2>/dev/null || break   # sshd exited early (bind/exec refused)
    sleep 0.1
done
if (( ! up )); then
    echo "--- sshd.log (startup failure) ---" >&2
    sed 's/^/    /' "$FX/sshd.log" >&2 2>/dev/null || true
    SSHD_PID=""   # already dead; nothing to signal
    skip "throwaway sshd did not come up (sandbox may block the bind/exec)"
fi
echo "sshd up on 127.0.0.1:$PORT (pid $SSHD_PID), fixture $FX"

# Real ssh client against the throwaway endpoint. Host-key checks are disabled
# against a throwaway key + /dev/null known_hosts (nothing persistent touched).
rssh() {
    ssh -p "$PORT" -i "$FX/clientkey" \
        -o BatchMode=yes -o ConnectTimeout=15 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
        127.0.0.1 "$@"
}
sha() { sha256sum < "$1" | cut -d' ' -f1; }

# Byte-exact tail of the ## Details section (P1 layout: ## Details is the LAST
# section; body = everything from header-line+2 to EOF).
extract_details() {
    local reqfile="$1" out="$2" det
    det=$(grep -n '^## Details$' "$reqfile" | head -1 | cut -d: -f1)
    [[ -n "$det" ]] || return 1
    tail -n +"$((det + 2))" -- "$reqfile" > "$out"
}

# ── Stanza 1: byte-adversarial request body over real ssh, C-locale daemon ──
# TAB, backslashes, an embedded newline, UTF-8 (é + ☃), NO trailing newline.
printf 'a\tb\\c\nd \303\251 \342\230\203 line-with-no-trailing-eol' > "$FX/s1.body"
s1src=$(sha "$FX/s1.body")
id1=$(LC_ALL=C rssh request file --kind question --reply required --slug adv-req --message-stdin < "$FX/s1.body" 2>"$FX/s1.err")
if [[ -z "$id1" ]]; then
    printf '  FAIL: S1 real-ssh request file returned no id\n' >&2
    sed 's/^/         /' "$FX/s1.err" >&2 2>/dev/null || true
    FAIL=$(( FAIL + 1 ))
else
    reqf1="$REQ_DIR/$id1.new.md"
    assert_file_exists "S1 request landed as .new.md ($id1)" "$reqf1"
    if extract_details "$reqf1" "$FX/s1.extracted"; then
        assert_eq "S1 ## Details body sha256 == source (byte-exact over ssh, LC_ALL=C daemon)" \
            "$(sha "$FX/s1.extracted")" "$s1src"
    else
        printf '  FAIL: S1 could not locate ## Details in %s\n' "$reqf1" >&2
        FAIL=$(( FAIL + 1 ))
    fi
fi

# ── Stanza 2: server-side reply, then real-ssh fetch results (byte-exact) ──
# A different adversarial payload as the REPLY body (quotes, backticks, $,
# backslash, TAB, UTF-8, no trailing newline).
printf '#!/bin/sh\necho "$USER" `date` \\ tab:\t \303\244 end-no-eol' > "$FX/s2.reply"
s2src=$(sha "$FX/s2.reply")
id2=$(LC_ALL=C rssh request file --kind question --slug reply-rt --message-stdin < "$FX/s1.body" 2>/dev/null)
if [[ -z "$id2" ]]; then
    printf '  FAIL: S2 could not file the request to reply to\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    # Watcher-claim analogue: the orchestrator side replies only to a .claimed
    # request (the watcher's atomic new→claimed rename is out of band here).
    mv "$REQ_DIR/$id2.new.md" "$REQ_DIR/$id2.claimed.md"
    if NEXUS_STATE_DIR="$STATE" bash "$CHAN" reply "$id2" - < "$FX/s2.reply" >/dev/null 2>"$FX/s2.reply.err"; then
        rssh request fetch "$id2" results < /dev/null > "$FX/s2.fetched" 2>/dev/null
        assert_eq "S2 fetched reply sha256 == source (byte-exact over ssh)" \
            "$(sha "$FX/s2.fetched")" "$s2src"
    else
        printf '  FAIL: S2 server-side reply failed\n' >&2
        sed 's/^/         /' "$FX/s2.reply.err" >&2 2>/dev/null || true
        FAIL=$(( FAIL + 1 ))
    fi
fi

# ── Stanza 3: await exit-code mapping over real ssh ───────────────────────
# replied(0): id2 is .replied from S2.
if [[ -n "${id2:-}" ]]; then
    rssh request await "$id2" --timeout 5 < /dev/null > /dev/null 2>&1; rc=$?
    assert_eq "S3 await on a replied request → exit 0 (over ssh)" "$rc" "0"
fi
# pending/timeout(4): a fresh request left unclaimed (.new) times out.
id3=$(LC_ALL=C rssh request file --kind question --slug pending-rt --message-stdin < "$FX/s1.body" 2>/dev/null)
if [[ -n "$id3" ]]; then
    rssh request await "$id3" --timeout 1 < /dev/null > /dev/null 2>&1; rc=$?
    assert_eq "S3 await on a pending request → exit 4 (timeout, over ssh)" "$rc" "4"
else
    printf '  FAIL: S3 could not file the pending request\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ── Stanza 4: refuse-don't-ignore over real ssh + no state mutation ───────
count_reqs() { find "$REQ_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }
before=$(count_reqs)
rssh request delete "$id2" < /dev/null > /dev/null 2>&1; rc_verb=$?          # disallowed request subcommand
rssh shell               < /dev/null > /dev/null 2>&1; rc_top=$?             # unknown top-level verb
rssh request file --origin spoofed --slug evil --message x < /dev/null > /dev/null 2>&1; rc_spoof=$?  # --origin spoof
after=$(count_reqs)
assert_eq "S4 disallowed 'request delete' refused (nonzero)" \
    "$([[ $rc_verb  -ne 0 ]] && echo refused || echo LEAKED)" "refused"
assert_eq "S4 unknown 'shell' verb refused (nonzero)" \
    "$([[ $rc_top   -ne 0 ]] && echo refused || echo LEAKED)" "refused"
assert_eq "S4 injected --origin spoof refused (nonzero)" \
    "$([[ $rc_spoof -ne 0 ]] && echo refused || echo LEAKED)" "refused"
assert_eq "S4 no state mutation from the refused commands" "$after" "$before"
# Belt: no request file was created with the spoofed origin.
if grep -rql '^origin: spoofed$' "$REQ_DIR" 2>/dev/null; then
    printf '  FAIL: S4 a spoofed-origin request file leaked into the inbox\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: S4 no spoofed-origin request file present\n'
    PASS=$(( PASS + 1 ))
fi

# ── Stanza 5: the nexus-request client tool, end to end ───────────────────
# Drives the real client tool through its documented seams: $SSH overrides the
# ssh program (add throwaway host-key opts), NEXUS_REMOTE_SSH_* points it at the
# loopback endpoint + fixture key. It files, background-waits, and — once we
# reply server-side — emits state=replied with a byte-exact reply.
if [[ -x "$CLIENT" ]]; then
    printf 'client-tool body \303\251 \\ tab:\t no-trailing-eol' > "$FX/s5.body"
    s5src=$(sha "$FX/s5.body")
    (
        export SSH="ssh -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
        export NEXUS_REMOTE_SSH_HOST=127.0.0.1
        export NEXUS_REMOTE_SSH_PORT="$PORT"
        export NEXUS_REMOTE_SSH_USER="$USER"
        export NEXUS_REMOTE_SSH_KEY="$FX/clientkey"
        export NEXUS_REQUEST_STATE="$FX/nrstate"   # client-side sentinel dir (never ~/.local)
        exec "$CLIENT" --slug client-tool --reply required --message-stdin \
            --poll 5 --timeout 60 --id-out "$FX/s5.id" --out "$FX/s5.emit" \
            < "$FX/s5.body" > "$FX/s5.stdout" 2>"$FX/s5.stderr"
    ) &
    nrpid=$!
    # Bounded wait (≤20s) for the client to file + record its id.
    cid=""
    for _ in $(seq 1 40); do
        [[ -s "$FX/s5.id" ]] && { cid=$(cat "$FX/s5.id"); break; }
        kill -0 "$nrpid" 2>/dev/null || break
        sleep 0.5
    done
    if [[ -n "$cid" && -f "$REQ_DIR/$cid.new.md" ]]; then
        mv "$REQ_DIR/$cid.new.md" "$REQ_DIR/$cid.claimed.md"
        NEXUS_STATE_DIR="$STATE" bash "$CHAN" reply "$cid" - < "$FX/s5.body" >/dev/null 2>&1
        wait "$nrpid"; nrrc=$?
        assert_eq "S5 nexus-request exits 0 on a replied round-trip" "$nrrc" "0"
        emit=$(cat "$FX/s5.emit" 2>/dev/null)
        assert_contains "S5 emit carries the terminal state=replied event" "$emit" "state=replied"
        # The tool's own sha256 is computed over the bytes it FETCHED back — if it
        # equals the source sha, the client-tool round trip is byte-exact.
        assert_contains "S5 emitted reply_sha256 == source (client-tool byte-exact)" \
            "$emit" "reply_sha256=$s5src"
    else
        # Could not drive the client tool without editing it → report a GAP, do
        # not leave the background process dangling.
        th_kill_own_child "$nrpid" TERM 2>/dev/null || kill "$nrpid" 2>/dev/null || true
        wait "$nrpid" 2>/dev/null || true
        printf '  FAIL: S5 could not file via nexus-request (cid=%q) — client-tool seam gap\n' "$cid" >&2
        sed 's/^/         /' "$FX/s5.stderr" >&2 2>/dev/null || true
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: S5 client tool %s not found/executable\n' "$CLIENT" >&2
    FAIL=$(( FAIL + 1 ))
fi

th_summary_and_exit
