#!/usr/bin/env bash
# Tests for SOURCE-ADDRESS ENFORCEMENT of monitor.remote.from_cidr
# (your-org/nexus-code#609 item 4) — the highest-severity item in that issue,
# because it is a SECURITY gate that read *satisfied* while being enforced
# nowhere.
#
# THE DEFECT. `_remote_bind_guard` permits a routable LAN bind ONLY if a
# from_cidr pin is configured (`_remote_lib.sh`, the routable-bind clause). But
# the pin was applied to credentials at ENROLL time only — `remote-enroll.sh`
# writes `from="<cidr>"` into the authorized_keys line it creates — and nothing
# reconciled a LATER-configured pin against pre-existing lines.
# `build_sshd_args` carries no address-scoped restriction either (`AllowUsers`
# scopes by USER, not by source), and the forced command never read SSH_CLIENT.
# Live state on the deployment that found this: `config/nexus.yml` set
# `from_cidr: "140.107.116.184/32"` while the sole credential read
# `command="…/remote-forced-command.sh operator-client",restrict <key>` — no
# `from=` at all, enrolled before the pin existed. So the routable bind was
# licensed BY a value that restricted nobody. A safety gate satisfied by a proxy.
#
# THE FIX, in two halves, both tested here:
#   POST-AUTH  the forced command (and the enroll session) evaluate the peer
#              address against from_cidr on EVERY connection — enforcement that
#              cannot drift from config, and it closes the live gap with no
#              re-enroll.
#   PRE-AUTH   `_remote_source_restriction_guard` reconciles the configured pin
#              against the live authorized_keys and reports a gap LOUDLY, and
#              REFUSES outright where no post-auth enforcement exists to cover
#              it (command_policy=unfiltered has no forced command; a line with
#              neither from= nor a command= has nothing at all).
#
#   1. unit: _remote_ip_in_cidr — IPv4, IPv6, IPv4-mapped, family, malformed
#   2. unit: _remote_peer_address from SSH_CLIENT / SSH_CONNECTION / neither
#   3. unit: _remote_source_guard decisions, incl. the fail-closed cases
#   4. the carrier posture is NOT broken: a loopback bind skips the check
#   5. integration: remote-forced-command.sh refuses an off-CIDR peer with 14
#      — with the in-CIDR NEGATIVE CONTROL beside it (without which the case
#      passes just as well if the gate refused unconditionally)
#   6. integration: remote-enroll-session.sh refuses an off-CIDR peer
#   7. the reconciliation audit classifies live authorized_keys lines
#   8. the gate: the EXACT live shape (restrict, no from=) is now LOUD, and
#      silent again once the pin is present (so the report is conditioned on
#      the gap, not unconditional)
#   9. the gate REFUSES where nothing enforces: unfiltered, and no-from-no-command
#  10. _remote_bind_guard inherits all of the above at its routable-bind clause
#
# Run: bash monitor/watcher/test-remote-source-enforcement.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"

# Resource precondition (your-org/nexus-code#655). This is the suite whose
# intermittency drove four rounds of loadavg correlation; the cause is
# per-UID RLIMIT_NPROC headroom, and it is measurable before the first
# assertion instead of discoverable half-way through as EAGAIN.
#
# 256, chosen generous. The transition is BROAD and STOCHASTIC rather than a
# sharp boundary — an independent six-replicate re-run found both green and
# red at 60 and at 85, where a three-replicate run had reported a clean edge
# near 90. 256 is above the whole noisy band either measurement found, which
# is the property that matters: a precondition firing near the true edge
# would become a second source of the flakiness it exists to remove. With a
# normal ceiling the headroom here is ~7,300, so this fires only when the box
# is genuinely starved.
th_require_fork_headroom 256 "test-remote-source-enforcement.sh" || exit 77

MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
FC="$MON_DIR/remote-forced-command.sh"
ES="$MON_DIR/remote-enroll-session.sh"

WORK=$(mktemp -d -t nexus-src609-XXXXXX)
PRINCIPALS="$HOME/.claude/principals-src609-$$"
trap 'rm -rf "$WORK" "$PRINCIPALS"' EXIT
mkdir -p "$WORK" "$PRINCIPALS" "$HOME/.claude"
chmod 700 "$HOME/.claude" "$PRINCIPALS"

# Hermetic config: the live nexus.yml carries a real routable bind + /32 pin,
# which would leak into the empty-from_cidr cases and mask them.
cat >"$WORK/nexus.yml" <<'YML'
monitor:
  remote:
    bind_address: 127.0.0.1
    from_cidr: ""
YML
export NEXUS_CONFIG="$WORK/nexus.yml"
export NEXUS_ROOT="$WORK"
export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
export MONITOR_REMOTE_PRINCIPALS_DIR="$PRINCIPALS"
mkdir -p "$WORK/state"
# Registration IS the enable signal — gate 1 of the forced command needs it.
printf 'nexus-remote-ssh\t%s\t%s\t%s\t%s\temit-only\n' \
    "$WORK" "$MON_DIR/remote-sshd-supervised.sh" "$MON_DIR/remote-ssh-health.sh" "$WORK/svc.log" \
    > "$NEXUS_SERVICES_REGISTRY"

# Run <code> against the lib with <env-assignments> applied. `VAR=x source lib`
# does NOT keep the assignment in scope for the LATER function call in bash's
# default mode, which silently ran every case below with an EMPTY environment —
# so they all read the hermetic defaults and "passed" the permit branch. Export
# explicitly; the _TH_NOOP placeholder keeps `export` well-formed when the env
# string is empty.
_lib_run() { bash -c "export _TH_NOOP=1 $1; source '$LIB'; $2"; }

# ── 1. unit: CIDR containment ────────────────────────────────────────────
echo "== 1. _remote_ip_in_cidr =="
inc() { bash -c "source '$LIB'; _remote_ip_in_cidr '$1' '$2'; echo \$?"; }
assert_eq "10.0.0.5 in 10.0.0.5/32"            "$(inc 10.0.0.5 10.0.0.5/32)"        "0"
assert_eq "10.0.0.6 NOT in 10.0.0.5/32"        "$(inc 10.0.0.6 10.0.0.5/32)"        "1"
assert_eq "140.107.116.184 in 140.107.0.0/16"  "$(inc 140.107.116.184 140.107.0.0/16)" "0"
assert_eq "140.108.1.1 NOT in 140.107.0.0/16"  "$(inc 140.108.1.1 140.107.0.0/16)"  "1"
assert_eq "10.1.2.3 in 10.0.0.0/8"             "$(inc 10.1.2.3 10.0.0.0/8)"         "0"
assert_eq "11.1.2.3 NOT in 10.0.0.0/8"         "$(inc 11.1.2.3 10.0.0.0/8)"         "1"
assert_eq "192.168.1.130 in 192.168.1.128/25"  "$(inc 192.168.1.130 192.168.1.128/25)" "0"
assert_eq "192.168.1.126 NOT in .128/25"       "$(inc 192.168.1.126 192.168.1.128/25)" "1"
assert_eq "any IPv4 in 0.0.0.0/0"              "$(inc 203.0.113.9 0.0.0.0/0)"       "0"
# IPv4-MAPPED: what a dual-stack sshd reports for an IPv4 peer. Without the
# unwrap an IPv4 pin would spuriously reject a legitimate client.
assert_eq "::ffff:10.0.0.5 in 10.0.0.5/32"     "$(inc ::ffff:10.0.0.5 10.0.0.5/32)" "0"
assert_eq "::ffff:10.0.0.9 NOT in 10.0.0.5/32" "$(inc ::ffff:10.0.0.9 10.0.0.5/32)" "1"
# IPv6, every compression spelling.
assert_eq "2001:db8::1 in 2001:db8::/32"       "$(inc 2001:db8::1 2001:db8::/32)"   "0"
assert_eq "2001:db9::1 NOT in 2001:db8::/32"   "$(inc 2001:db9::1 2001:db8::/32)"   "1"
assert_eq "::1 in ::1/128"                     "$(inc ::1 ::1/128)"                 "0"
assert_eq "::2 NOT in ::1/128"                 "$(inc ::2 ::1/128)"                 "1"
assert_eq "fe80::1:2:3:4 in fe80::/64"         "$(inc fe80::1:2:3:4 fe80::/64)"     "0"
assert_eq "expanded == compressed form"        "$(inc 2001:0db8:0000:0000:0000:0000:0000:0001 2001:db8::/32)" "0"
assert_eq "a /49 boundary is respected"        "$(inc 2001:db8:0:8000:: 2001:db8:0:0::/49)" "1"
assert_eq "…and its in-prefix sibling matches" "$(inc 2001:db8:0:7fff:: 2001:db8:0:0::/49)" "0"
assert_eq "zone id stripped (fe80::1%eth0)"    "$(inc 'fe80::1%eth0' fe80::/64)"    "0"
# FAMILY is exact, matching sshd's own from= semantics.
assert_eq "IPv6 peer vs IPv4 pin → no match"   "$(inc 2001:db8::1 10.0.0.0/8)"      "1"
assert_eq "IPv4 peer vs IPv6 pin → no match"   "$(inc 10.0.0.5 2001:db8::/32)"      "1"
# rc 2 = CANNOT EVALUATE. Every caller treats it as refuse, never permit.
assert_eq "malformed CIDR → rc 2"              "$(inc 10.0.0.5 'not-a-cidr')"       "2"
assert_eq "CIDR with no prefix → rc 2"         "$(inc 10.0.0.5 '10.0.0.5')"         "2"
assert_eq "IPv4 prefix > 32 → rc 2"            "$(inc 10.0.0.5 '10.0.0.0/33')"      "2"
assert_eq "octet > 255 in the pin → rc 2"      "$(inc 10.0.0.5 '10.0.0.300/24')"    "2"
assert_eq "malformed peer address → rc 2"      "$(inc '10.0.0' '10.0.0.0/8')"       "2"
assert_eq "octet > 255 in the peer → rc 2"     "$(inc '10.0.0.300' '10.0.0.0/8')"   "2"
assert_eq "empty peer → rc 2"                  "$(inc '' '10.0.0.0/8')"             "2"
assert_eq "':::' is malformed → rc 2"          "$(inc ':::1' '2001:db8::/32')"      "2"
assert_eq "two '::' groups → rc 2"             "$(inc '2001::db8::1' '2001:db8::/32')" "2"
assert_eq "9 hextets → rc 2"                  "$(inc '1:2:3:4:5:6:7:8:9' '1:2:3:4::/64')" "2"

# ── 2. unit: peer address extraction ────────────────────────────────────
echo "== 2. _remote_peer_address =="
peer() { _lib_run "$1" '_remote_peer_address; echo " rc=$?"'; }
assert_eq "from SSH_CLIENT"      "$(peer 'SSH_CLIENT="10.0.0.5 51234 22022"')"                  "10.0.0.5 rc=0"
assert_eq "from SSH_CONNECTION"  "$(peer 'SSH_CONNECTION="10.0.0.6 51234 10.0.0.1 22022"')"     "10.0.0.6 rc=0"
assert_eq "SSH_CLIENT wins"      "$(peer 'SSH_CLIENT="10.0.0.5 1 2" SSH_CONNECTION="10.9.9.9 1 2 3"')" "10.0.0.5 rc=0"
assert_eq "neither set → rc 1"   "$(peer '')"                                                   " rc=1"

# ── 3. unit: the runtime gate ───────────────────────────────────────────
echo "== 3. _remote_source_guard =="
sg() {  # <env-assignments> → "<rc>|<reason>"
    _lib_run "$1" '_remote_source_guard; printf "%s|%s" "$?" "$_REMOTE_SRC_REASON"' 
}
ROUTABLE='MONITOR_REMOTE_BIND_ADDRESS=140.107.222.134'
r=$(sg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32 SSH_CLIENT='140.107.116.184 1 2'")
assert_eq "in-CIDR peer permitted" "${r%%|*}" "0"
assert_contains "…and says why"    "$r" "is within from_cidr"
r=$(sg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32 SSH_CLIENT='203.0.113.9 1 2'")
assert_eq "off-CIDR peer REFUSED"  "${r%%|*}" "1"
assert_contains "…naming the peer and the pin" "$r" "203.0.113.9 is OUTSIDE from_cidr=140.107.116.184/32"
r=$(sg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=")
assert_eq "no pin configured → permit" "${r%%|*}" "0"
r=$(sg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=0.0.0.0/0 SSH_CLIENT='203.0.113.9 1 2'")
assert_eq "any-source /0 → permit"     "${r%%|*}" "0"
assert_contains "…as a conscious opt-in" "$r" "any-source"
# FAIL-CLOSED: a pin is configured but the peer cannot be determined.
r=$(sg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "pinned but no peer address → REFUSE" "${r%%|*}" "1"
assert_contains "…explicitly fail-closed" "$r" "fail-closed"
# FAIL-CLOSED: a malformed pin must never degrade to no-pin.
r=$(sg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=garbage SSH_CLIENT='10.0.0.5 1 2'")
assert_eq "malformed pin → REFUSE"   "${r%%|*}" "1"
assert_contains "…naming the malformation" "$r" "not a well-formed CIDR"
# A peer the matcher cannot parse is refused, not admitted.
r=$(sg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=10.0.0.0/8 SSH_CLIENT='not-an-ip 1 2'")
assert_eq "unparseable peer → REFUSE" "${r%%|*}" "1"

# ── 4. the loopback/carrier posture is not broken ───────────────────────
echo "== 4. loopback bind: from_cidr is not the operative control =="
# In the loopback + SSH-tunnel/carrier posture the peer address is the LOCAL end
# of the tunnel, so the client's real source is invisible by construction.
# Enforcing a LAN /32 against 127.0.0.1 would refuse every legitimate carrier
# session — an availability break dressed as hardening. Skip, and say so.
r=$(sg "MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32 SSH_CLIENT='127.0.0.1 1 2'")
assert_eq "loopback bind + LAN pin + loopback peer → permit" "${r%%|*}" "0"
assert_contains "…and explains that the carrier is the control" "$r" "not the operative control"
# NEGATIVE CONTROL: the skip requires BOTH axes. Same loopback peer, routable
# bind → refused.
r=$(sg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32 SSH_CLIENT='127.0.0.1 1 2'")
assert_eq "routable bind + same loopback peer → REFUSED" "${r%%|*}" "1"
# F9's sibling on this surface: F6. The skip used to check ONLY the configured
# bind, which is a PROXY for "this peer is a local tunnel end". A LAN peer is not
# a carrier's local end, and we have its address in SSH_CLIENT.
#
# Reachable by SKEW, not just by misconfiguration: remote-sshd-supervised.sh
# captures BIND ONCE at supervisor start while this gate re-reads config per
# connection. So editing bind_address to 127.0.0.1 — an intended TIGHTENING —
# without restarting the supervisor silently disabled the runtime pin while the
# socket stayed LAN-facing.
r=$(sg "MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32 SSH_CLIENT='203.0.113.9 1 2'")
assert_eq "loopback CONFIG + off-CIDR LAN peer → REFUSED (F6)" "${r%%|*}" "1"
assert_contains "…named as outside the pin, not waved through as a carrier" "$r" "203.0.113.9 is OUTSIDE"
assert_not_contains "…and NOT excused as the local carrier endpoint" "$r" "carrier endpoint"
# …and the in-CIDR LAN peer on the same loopback config is permitted, so the fix
# is a source check and not a blanket refusal.
r=$(sg "MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32 SSH_CLIENT='140.107.116.184 1 2'")
assert_eq "loopback CONFIG + in-CIDR LAN peer → permitted" "${r%%|*}" "0"
# F10: F6's reordering made "loopback bind + UNSET peer" refuse too, and that input
# was asserted NOWHERE afterwards — the three loopback cases above all set
# SSH_CLIENT, and self-enroll stopped exercising it. Behaviour was already correct;
# coverage had moved from incidentally-exercised to not-exercised, which is how a
# correct behaviour quietly becomes a regression nobody catches.
r=$(sg "MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "loopback CONFIG + UNSET peer → REFUSE (fail-closed)" "${r%%|*}" "1"
assert_contains "…for the peer-undeterminable reason" "$r" "cannot determine the peer address"


# ── 5. integration: the forced command ──────────────────────────────────
echo "== 5. remote-forced-command.sh enforces the pin at runtime =="
# Discriminator: exit 14 = refused on SOURCE (gate 3); exit 12 = the source gate
# PASSED and the bogus verb was refused later. No `ng` needed.
fc() {  # <env-assignments> <command-string> → rc
    bash -c "$1 SSH_ORIGINAL_COMMAND='$2' bash '$FC' testclient" >/dev/null 2>&1
    echo $?
}
fcerr() { bash -c "$1 SSH_ORIGINAL_COMMAND='$2' bash '$FC' testclient" 2>&1 >/dev/null; }
OFF="$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32 SSH_CLIENT='203.0.113.9 1 2'"
IN_="$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32 SSH_CLIENT='140.107.116.184 1 2'"
assert_eq "off-CIDR peer → refused 14" "$(fc "$OFF" 'bogusverb')" "14"
assert_contains "…with the reason" "$(fcerr "$OFF" 'bogusverb')" "source address rejected"
assert_contains "…naming peer and pin" "$(fcerr "$OFF" 'bogusverb')" "203.0.113.9 is OUTSIDE"
# THE NEGATIVE CONTROL. Without it, case 5 passes identically if gate 3 refused
# every connection — which would take the channel down, not secure it.
assert_eq "in-CIDR peer reaches verb dispatch (not 14)" "$(fc "$IN_" 'bogusverb')" "12"
assert_contains "…and is refused only on the verb" "$(fcerr "$IN_" 'bogusverb')" "unknown verb"
# The refusal must precede any action, including the informational bare-connect
# notice — an off-CIDR peer must learn nothing about the channel.
assert_eq "off-CIDR bare connection → refused 14, no policy notice" "$(fc "$OFF" '')" "14"
assert_not_contains "…and the notice is NOT emitted" \
    "$(bash -c "$OFF SSH_ORIGINAL_COMMAND='' bash '$FC' testclient" 2>/dev/null)" "nexus remote agent channel"
# Fail-closed: a pin with no SSH_* env at all.
assert_eq "pinned + no SSH_CLIENT → refused 14" \
    "$(fc "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32" 'bogusverb')" "14"
# NEGATIVE CONTROL: with NO pin configured, the absence of SSH_CLIENT is fine —
# proving the fail-closed refusal is conditioned on a pin existing.
assert_eq "no pin + no SSH_CLIENT → NOT a source refusal" \
    "$(fc "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=" 'bogusverb')" "12"

# ── 6. integration: the enroll session ──────────────────────────────────
echo "== 6. remote-enroll-session.sh enforces the pin too =="
# This endpoint INSTALLS a permanent credential, so an enrollment window
# reachable from outside the pin is the widest form of the gap.
HASH=$(printf 'x' | sha256sum | awk '{print $1}')
esrc=$(bash -c "$OFF bash '$ES' '$HASH'" </dev/null >/dev/null 2>&1; echo $?)
assert_eq "off-CIDR enroll attempt → refused 14" "$esrc" "14"
eserr=$(bash -c "$OFF bash '$ES' '$HASH'" </dev/null 2>&1 >/dev/null)
assert_contains "…with the reason" "$eserr" "source address rejected"
# NEGATIVE CONTROL: an in-CIDR peer gets past the source gate (and then fails
# for its own reason — no token on stdin), so the gate is not firing always.
esrc2=$(bash -c "$IN_ REMOTE_ENROLL_STDIN_TIMEOUT=1 bash '$ES' '$HASH'" </dev/null >/dev/null 2>&1; echo $?)
assert_eq "in-CIDR enroll attempt is NOT refused on source" \
    "$([[ "$esrc2" == 14 ]] && echo refused-on-source || echo passed-source-gate)" "passed-source-gate"

# ── 7. the reconciliation audit ─────────────────────────────────────────
echo "== 7. _remote_from_audit classifies live authorized_keys lines =="
AK="$PRINCIPALS/authorized_keys"
KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYFORTESTSONLY0000000000000'
audit() {  # <cidr> → "<rc>|total|ok|absent|mismatch|unenforced"
    bash -c "source '$LIB'; _remote_from_audit '$1'; \
      printf '%s|%s|%s|%s|%s|%s' \"\$?\" \"\$_REMOTE_FROM_AUDIT_TOTAL\" \"\$_REMOTE_FROM_AUDIT_OK\" \
      \"\$_REMOTE_FROM_AUDIT_ABSENT\" \"\$_REMOTE_FROM_AUDIT_MISMATCH\" \"\$_REMOTE_FROM_AUDIT_UNENFORCED\""
}
rm -f "$AK"
assert_eq "no authorized_keys → rc 2 (nothing enrolled)" "$(audit 10.0.0.0/8)" "2|0|0|||"
# THE EXACT LIVE SHAPE that made this a live gap: restrict present, from= absent.
printf 'command="%s/remote-forced-command.sh operator-client",restrict %s operator-client@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
assert_eq "live shape (no from=) → rc 1, line 1 absent, forced ⇒ enforced" \
    "$(audit 140.107.116.184/32)" "1|1|0|1||"
printf 'command="%s/remote-forced-command.sh c",restrict,from="140.107.116.184/32" %s c@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
assert_eq "matching from= → rc 0, counted ok" "$(audit 140.107.116.184/32)" "0|1|1|||"
assert_eq "…the SAME line vs a DIFFERENT pin → mismatch" "$(audit 10.0.0.0/8)" "1|1|0||1|"
# A line with neither from= nor a forced command has ZERO source enforcement.
printf '%s danger@host\n' "$KEY" > "$AK"
assert_eq "bare key line → absent AND unenforced" "$(audit 10.0.0.0/8)" "1|1|0|1||1"
# Blanks and comments are not credentials.
{ echo ''; echo '# a comment'; printf 'command="%s/remote-forced-command.sh c",restrict,from="10.0.0.0/8" %s c@n\n' "$MON_DIR" "$KEY"; } > "$AK"
assert_eq "blank + comment lines ignored; line numbers are real" "$(audit 10.0.0.0/8)" "0|1|1|||"
# SUPERSEDED ASSERTION, kept as a regression test with its polarity FLIPPED.
# It used to read "another clone's wrapper path still counts as enforced", which
# encoded the basename design F7 overturned: an unreadable/absent wrapper cannot be
# shown to enforce anything, so crediting it was a proxy. Fail closed instead.
# (Same habit as #608: when a fix changes a contract, hunt the assertions that were
# encoding the old one.)
printf 'command="/some/other/clone/monitor/remote-forced-command.sh c",restrict %s c@n\n' "$KEY" > "$AK"
assert_eq "an unreadable wrapper path is NOT credited as enforcing" "$(audit 10.0.0.0/8)" "1|1|0|1||1"

srg() {  # <env> → "<rc>|<stderr>"
    local out rc
    out=$(_lib_run "$1" '_remote_source_restriction_guard' 2>&1 >/dev/null); rc=$?
    printf '%s|%s' "$rc" "$out"
}
echo "== 7b. F7: enforcement is read OUT OF the named wrapper, not from its name =="
# The audit used to credit any line whose command= BASENAME looked like ours with
# runtime enforcement. That was a proxy, and it was FALSE ON LIVE STATE: the
# enrolled line names the main clone's wrapper, that clone is on `dev`, and `dev`'s
# wrapper has no gate 3 — so the audit reported "the pin is still ENFORCED at
# runtime" about a wrapper enforcing nothing (your-org/nexus-code#609 F7).
GATED="$WORK/gated"; GATELESS="$WORK/gateless"
mkdir -p "$GATED" "$GATELESS"
printf '#!/usr/bin/env bash\n_remote_source_guard || exit 14\n' > "$GATED/remote-forced-command.sh"
printf '_remote_source_guard() { :; }\n' > "$GATED/_remote_lib.sh"
printf '#!/usr/bin/env bash\n# an older clone: no gate 3 here\n' > "$GATELESS/remote-forced-command.sh"
printf '# an older clone lib\n' > "$GATELESS/_remote_lib.sh"
chmod +x "$GATED/remote-forced-command.sh" "$GATELESS/remote-forced-command.sh"
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$GATED" "$KEY" > "$AK"
assert_eq "wrapper CONTAINING the gate → counted as enforced" "$(audit 10.0.0.0/8)" "1|1|0|1||"
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$GATELESS" "$KEY" > "$AK"
assert_eq "same basename, NO gate in the file → UNENFORCED" "$(audit 10.0.0.0/8)" "1|1|0|1||1"
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$WORK/no-such-dir" "$KEY" > "$AK"
assert_eq "wrapper path missing entirely → UNENFORCED (fail-closed)" "$(audit 10.0.0.0/8)" "1|1|0|1||1"
# F11: the verdict deliberately treats gateless and missing alike, but the DIAGNOSIS
# must not — deleting a stale work/<project>-<task>/ clone is routine, and after it
# the channel refuses to launch with "unsafe bind exposure" and no pointer.
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_contains "…and the report NAMES the missing wrapper path" "$g" "$WORK/no-such-dir/remote-forced-command.sh"
assert_contains "…flagged as MISSING or UNREADABLE"              "$g" "MISSING or UNREADABLE"
assert_contains "…with the deleted-clone remedy"                 "$g" "re-enroll from a live checkout"
# NEGATIVE CONTROL: a wrapper that EXISTS but lacks the gate must NOT be reported as
# missing — same verdict, different diagnosis, which is the whole point.
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$GATELESS" "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_not_contains "a gateless-but-present wrapper is NOT called missing" "$g" "MISSING or UNREADABLE"
# …and the guard's verdict follows: gateless ⇒ REFUSE, gated ⇒ warn at rc 0.
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$GATELESS" "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "gateless wrapper on a routable bind → REFUSE" "${g%%|*}" "1"
assert_not_contains "…and never claims runtime enforcement" "$g" "still ENFORCED at runtime"
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$GATED" "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "gated wrapper → rc 0 (warn, channel stays up)" "${g%%|*}" "0"
assert_contains "…and the runtime-enforcement claim is now TRUE" "$g" "still ENFORCED at runtime"
# Degenerate credential store — found by auditing my own remedy for the very defect
# it closes. An UNREADABLE authorized_keys used to leave the audit's counters at
# zero, which its final test reported as "every line carries the pin" ⇒ the guard
# passed silently. Absent (nothing enrolled) and unreadable (cannot audit) are
# different answers and must not collapse.
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$GATED" "$KEY" > "$AK"
chmod 000 "$AK"
assert_eq "UNREADABLE authorized_keys → audit rc 3, not 'all pinned'" \
    "$(audit 140.107.116.184/32 | cut -d'|' -f1)" "3"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "…and the guard REFUSES rather than passing silently" "${g%%|*}" "1"
assert_contains "…naming it unauditable"      "$g" "must not"
assert_contains "…and pointing at permissions" "$g" "permissions"
chmod 600 "$AK"
# NEGATIVE CONTROL: an ABSENT store is still 'nothing enrolled' (rc 2, guard rc 0),
# so the refusal is conditioned on unreadable-not-missing.
rm -f "$AK"
assert_eq "ABSENT authorized_keys → audit rc 2 (nothing enrolled)" \
    "$(audit 140.107.116.184/32 | cut -d'|' -f1)" "2"
assert_eq "…and the guard stays silent"  "$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")" "0|"

# ── 8. the gate is LOUD on the live shape, and silent once pinned ───────
echo "== 8. _remote_source_restriction_guard reports the gap =="
printf 'command="%s/remote-forced-command.sh operator-client",restrict %s operator-client@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "channel-only + covered post-auth → rc 0 (channel stays up)" "${g%%|*}" "0"
assert_contains "…but LOUD about the gap"          "$g" "RECONCILIATION GAP"
assert_contains "…naming the line number"          "$g" "line(s) with NO from= option:        1"
assert_contains "…explaining enroll-time-only"     "$g" "applied at ENROLL time only"
assert_contains "…and prescribing the re-enroll"   "$g" "remote enroll-invite"
assert_contains "…and stating the residual risk"   "$g" "PRE-AUTH surface stays open"
# Never echo the line's bytes — they begin with a raw key blob.
assert_not_contains "…and never prints the key material" "$g" "AAAAC3NzaC1lZDI1NTE5"
# NEGATIVE CONTROL: the report must be conditioned on the GAP. Add the pin and
# the guard goes silent — otherwise case 8 passes with an unconditional warning.
printf 'command="%s/remote-forced-command.sh c",restrict,from="140.107.116.184/32" %s c@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "pin present on every line → rc 0"   "${g%%|*}" "0"
assert_eq "…and SILENT (no gap to report)"     "${g#*|}"  ""
# Not applicable cases are silent too.
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$MON_DIR" "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=0.0.0.0/0")
assert_eq "any-source /0 → nothing to enforce, silent" "$g" "0|"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=")
assert_eq "no pin → nothing to enforce, silent"        "$g" "0|"

# ── 9. the gate REFUSES where nothing enforces ─────────────────────────
echo "== 9. no enforcement anywhere ⇒ REFUSE, not warn =="
# The rule is keyed on the LINE, not the policy knob: a gap line is acceptable
# only if OUR forced command runs on it. An `unfiltered` line carries no
# command= by design, so from= is its only source control — and it names the
# wrong range here.
printf 'from="10.0.0.0/8" %s c@nexus-remote\n' "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_COMMAND_POLICY=unfiltered MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "unfiltered + wrong from= → REFUSE" "${g%%|*}" "1"
assert_contains "…because from= is the only control there" "$g" "ONLY source control"
assert_contains "…classified as a MISMATCH, not an absence" "$g" "DIFFERENT from= pin"
# The SAME unpinned line with a forced command is covered at runtime ⇒ warn, not
# refuse. This is what proves the refusal keys on the line and not on the knob:
# the policy knob is identical in both runs.
printf 'command="%s/remote-forced-command.sh c",restrict,from="10.0.0.0/8" %s c@nexus-remote\n' "$MON_DIR" "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_COMMAND_POLICY=unfiltered MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "same knob, but the LINE has our wrapper → rc 0 (warn)" "${g%%|*}" "0"
# NEGATIVE CONTROL: unfiltered with the CORRECT pin is accepted, so the refusal
# is conditioned on the gap and not on the policy alone.
printf 'from="140.107.116.184/32" %s c@nexus-remote\n' "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_COMMAND_POLICY=unfiltered MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "unfiltered + correct from= → rc 0" "${g%%|*}" "0"
# A line with neither from= nor a command= is refused under ANY policy.
printf '%s danger@host\n' "$KEY" > "$AK"
g=$(srg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "no from= AND no forced command → REFUSE" "${g%%|*}" "1"
assert_contains "…naming from_cidr as the only control" "$g" "ONLY source control"
# A loopback bind never refuses (from_cidr is not the operative control) but is
# still reported.
g=$(srg "MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "loopback + zero enforcement → still REFUSE (nothing enforces at all)" "${g%%|*}" "1"
printf 'command="%s/remote-forced-command.sh c",restrict %s c@nexus-remote\n' "$MON_DIR" "$KEY" > "$AK"
g=$(srg "MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "loopback + forced command → rc 0" "${g%%|*}" "0"
assert_contains "…and says the carrier is the control" "$g" "not the operative control"

# ── 10. _remote_bind_guard inherits the property check ──────────────────
echo "== 10. the routable-bind clause now verifies the pin is IN FORCE =="
bg() {
    local out rc
    out=$(_lib_run "$1" '_remote_bind_guard' 2>&1 >/dev/null); rc=$?
    printf '%s|%s' "$rc" "$out"
}
# THE DEFECT, at its own call site: the live shape used to make this read
# SATISFIED, silently licensing the routable bind.
printf 'command="%s/remote-forced-command.sh operator-client",restrict %s operator-client@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
g=$(bg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "routable + pin + unpinned credential → permitted but LOUD" "${g%%|*}" "0"
assert_contains "…the gap is surfaced at the bind guard" "$g" "RECONCILIATION GAP"
# NEGATIVE CONTROLS: the pre-existing bind-guard contracts must be untouched.
g=$(bg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=")
assert_eq "routable + EMPTY pin still REFUSED (load-bearing)" "${g%%|*}" "1"
assert_contains "…for the original reason" "$g" "without monitor.remote.from_cidr"
g=$(bg "MONITOR_REMOTE_BIND_ADDRESS=0.0.0.0 MONITOR_REMOTE_FROM_CIDR=10.0.0.0/8")
assert_eq "wildcard bind still REFUSED" "${g%%|*}" "1"
printf 'command="%s/remote-forced-command.sh c",restrict,from="140.107.116.184/32" %s c@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
g=$(bg "$ROUTABLE MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "routable + pin actually in force → rc 0, silent" "$g" "0|"
# unfiltered with no enforcement anywhere must take the bind DOWN, not warn.
printf 'from="10.0.0.0/8" %s c@nexus-remote\n' "$KEY" > "$AK"
g=$(bg "$ROUTABLE MONITOR_REMOTE_COMMAND_POLICY=unfiltered MONITOR_REMOTE_FROM_CIDR=140.107.116.184/32")
assert_eq "unfiltered + unenforced pin → bind guard REFUSES" "${g%%|*}" "1"

# ── 9. the POSTURE-AWARE from= pin (your-org/nexus-code#902) ────────────
#
# _remote_source_guard documents that under the loopback+carrier posture the
# peer is the local tunnel end, so a LAN pin "would refuse every legitimate
# carrier session". That exemption was UNREACHABLE: sshd enforces `from=` at
# publickey time, before the forced command runs. So the pin itself must know
# the posture. Measured before the fix: full pre-auth banner, then
# `Permission denied (publickey)`, for a key enrolled seconds earlier.
echo "== 9. _remote_from_pin_list is posture-aware =="
pin() { bash -c "source '$LIB'; $1 _remote_from_pin_list; printf '|%s' \"\$?\""; }

assert_eq "routable bind: the pin is EXACTLY the configured CIDR" \
    "$(pin 'MONITOR_REMOTE_BIND_ADDRESS=140.107.222.134 MONITOR_REMOTE_FROM_CIDR=10.0.0.0/8')" \
    "10.0.0.0/8|0"
assert_eq "loopback bind: loopback is ADDED so a carrier client can authenticate" \
    "$(pin 'MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=10.0.0.0/8')" \
    "10.0.0.0/8,127.0.0.1/32,::1/128|0"
assert_eq "no from_cidr configured: still no pin (loopback adds nothing on its own)" \
    "$(pin 'MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=')" \
    "|0"
assert_eq "illegal characters are REFUSED (rc 1), not written into a line" \
    "$(pin 'MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR="1.2.3.4/32 evil"')" \
    "|1"

# DE-DUPLICATION (skeptic finding F3). A doubled entry is harmless to sshd but
# it prints in the enroll confirmation the operator reads to check what a
# credential permits — the one line #902 deliberately made honest.
assert_eq "a from_cidr that already carries v4 loopback is not double-listed" \
    "$(pin 'MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=127.0.0.1/32')" \
    "127.0.0.1/32,::1/128|0"
assert_eq "…nor v6 loopback" \
    "$(pin 'MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=::1/128')" \
    "::1/128,127.0.0.1/32|0"
assert_eq "…and a list already carrying BOTH is returned unchanged" \
    "$(pin 'MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=10.0.0.0/8,::1/128,127.0.0.1/32')" \
    "10.0.0.0/8,::1/128,127.0.0.1/32|0"
# The de-dup is an EXACT-TOKEN match, deliberately not CIDR containment: a
# LAN range that merely resembles a loopback token must still get both entries,
# because dropping one is the lockout, and CIDR math in a security-relevant
# string is how you drop one by accident.
assert_eq "a non-loopback range is not mistaken for one (both entries still added)" \
    "$(pin 'MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=127.0.0.0/8')" \
    "127.0.0.0/8,127.0.0.1/32,::1/128|0"

# The audit must expect what an enroll would write NOW, or it flags its own
# correct output — and, worse, would report a LAN-only line as properly pinned
# under a loopback bind, which is precisely the credential sshd refuses.
printf 'command="%s/remote-forced-command.sh c",restrict,from="10.0.0.0/8" %s c@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
lb='MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 MONITOR_REMOTE_FROM_CIDR=10.0.0.0/8'
audit_default() { bash -c "source '$LIB'; $1 _remote_from_audit; printf '%s|%s' \"\$?\" \"\$_REMOTE_FROM_AUDIT_MISMATCH\""; }
assert_eq "loopback bind + LAN-only line → MISMATCH (operator is owed a re-enroll)" \
    "$(audit_default "$lb")" "1|1"
printf 'command="%s/remote-forced-command.sh c",restrict,from="10.0.0.0/8,127.0.0.1/32,::1/128" %s c@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
assert_eq "loopback bind + posture-aware line → clean" \
    "$(audit_default "$lb")" "0|"
# Negative control: the routable posture is unchanged by all of the above.
printf 'command="%s/remote-forced-command.sh c",restrict,from="10.0.0.0/8" %s c@nexus-remote\n' \
    "$MON_DIR" "$KEY" > "$AK"
assert_eq "routable bind + LAN-only line → still clean (no behaviour change)" \
    "$(audit_default 'MONITOR_REMOTE_BIND_ADDRESS=140.107.222.134 MONITOR_REMOTE_FROM_CIDR=10.0.0.0/8')" \
    "0|"

th_summary_and_exit
