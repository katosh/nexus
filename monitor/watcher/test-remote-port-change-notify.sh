#!/usr/bin/env bash
# Tests for the DURABLE port-change alert (your-org/nexus-code#757):
#   monitor/_remote_lib.sh                  (_remote_endpoint_params,
#                                            _remote_client_repin_notice)
#   monitor/remote-port-change-notify.sh    (surface fan-out, fail-loud verdict,
#                                            UNDELIVERED marker, secret guard)
#   monitor/remote-up.sh                    (alert_port_change wiring; the
#                                            bring-up does NOT block on a failed
#                                            alert; --status surfaces the marker)
#
# WHAT THIS SUITE COVERS, ON THE AXIS THE MECHANISM VARIES ON.
# The emitter's behaviour is a function of WHICH DURABLE SURFACE ACCEPTED, so the
# cases below enumerate that axis exhaustively for two surfaces:
#
#            github=ok   github=FAIL   github=unconfigured
#   push=ok     T9(*)       T10            T12b
#   push=FAIL   T9          T11            T12
#
# (*) both-ok is subsumed by T9/T10: the verdict is `delivered>=1`, and each
# single-surface case already proves that surface alone suffices. What is NOT
# covered: real network delivery (no GitHub or Pushover call is made anywhere in
# this suite — `ng` and `notify.sh` are argv-recording stubs), and the CONTENT of
# a real Pushover/email render. Those are the seams' own contract, not this one's.
#
# Hermetic: HOME is relocated so principals_dir resolves under $HOME/.claude;
# every outbound surface is a stub binary in a fixture dir; no port is bound
# except by the INT band's squatter + stub sshd (mirroring
# test-remote-port-select.sh, which this file's INT band is modelled on).
#
# EVERY assertion runs in the TOP-LEVEL shell. Values needing an isolated env are
# computed in a SUBPROCESS and asserted in the parent — never `( … assert … )`,
# whose FAIL increments a lost subshell copy of $FAIL (the #637 skeptic finding).
#
# Run: bash monitor/watcher/test-remote-port-change-notify.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
NOTIFY="$MON_DIR/remote-port-change-notify.sh"
UP="$MON_DIR/remote-up.sh"

command -v python3    >/dev/null 2>&1 || { echo "SKIP: python3 not present";    echo "ALL TESTS PASSED"; exit 0; }
command -v ssh-keygen >/dev/null 2>&1 || { echo "SKIP: ssh-keygen not present"; echo "ALL TESTS PASSED"; exit 0; }

WORK=$(mktemp -d -t nexus-portchange-XXXXXX)
SQUATTERS=()
cleanup() {
    local pf pid
    for pf in "$WORK"/state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null; }
    done
    for pid in "${SQUATTERS[@]}"; do kill -KILL "$pid" 2>/dev/null; done
    # T16 chmods principals_dir 500 to construct the unwritable-marker case; a
    # trap that fires mid-case would otherwise leave a dir `rm -rf` cannot empty.
    chmod -R u+rwX "$WORK" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
export NEXUS_ROOT="$WORK/nexusroot"
export HOME="$WORK/home"
export MONITOR_REMOTE_PRINCIPALS_DIR="$HOME/.claude/principals"
PRINCIPALS="$MONITOR_REMOTE_PRINCIPALS_DIR"
export MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1
export NEXUS_NOTIFY_QUIET=1                      # never ring a real bell
mkdir -p "$WORK/state" "$WORK/nexusroot/monitor/.state" "$HOME/.claude" "$PRINCIPALS"
chmod 700 "$HOME/.claude" "$PRINCIPALS"
unset MONITOR_REMOTE_PORT MONITOR_REMOTE_ENDPOINT_ISSUE MONITOR_REMOTE_ENDPOINT_ISSUE_REPO 2>/dev/null || true
unset MONITOR_REMOTE_FROM_CIDR NEXUS_CONFIG 2>/dev/null || true

AK="$PRINCIPALS/authorized_keys"
NOTICE="$PRINCIPALS/port-change-notice.md"
MARKER="$PRINCIPALS/port-change-notice.UNDELIVERED"
HISTFILE="$PRINCIPALS/port-history.log"
PORTFILE="$PRINCIPALS/port"

# A real host key so the fingerprint path is exercised, not stubbed.
ssh-keygen -t ed25519 -N '' -C nexus-remote-host -f "$PRINCIPALS/ssh_host_ed25519_key" >/dev/null 2>&1
FP=$(ssh-keygen -lf "$PRINCIPALS/ssh_host_ed25519_key.pub" 2>/dev/null | awk '{print $2}')

# The pubkey blob planted in fixture authorized_keys lines. Assembled from parts
# so this FILE never contains a literal `ssh-ed25519 AAAA…` string — the repo's
# own secret guard scans sources, and a fixture that trips it is a footgun.
KEYTYPE='ssh-ed25519'
KEYBLOB="AAAAC3NzaC1lZDI1NTE5AAAAI${_x:-}FIXTUREFIXTUREFIXTUREFIXTUREFIXTUREFIXTUR"

write_ak() {   # $1 = from= option or empty
    local from="${1:-}" opts="command=\"$MON_DIR/remote-forced-command.sh alice\",restrict"
    [[ -n "$from" ]] && opts="$opts,from=\"$from\""
    printf '%s %s %s alice@nexus-remote\n' "$opts" "$KEYTYPE" "$KEYBLOB" > "$AK"
    chmod 600 "$AK"
}

# ── stub outbound surfaces ──────────────────────────────────────────────────
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/ng" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NG_ARGV_LOG"
# Record the body we were handed, so content assertions read what would be POSTED.
_bf=""; while (( $# )); do [[ "$1" == "--body-file" ]] && { _bf="$2"; shift; }; shift; done
[[ -n "$_bf" && -r "$_bf" ]] && cp "$_bf" "$NG_BODY_COPY"
if [[ "${NG_STUB_RC:-0}" != 0 ]]; then echo "stub ng: refusing (NG_STUB_RC=$NG_STUB_RC)" >&2; exit "$NG_STUB_RC"; fi
echo "https://github.test/stub/comment/1"
EOF
cat > "$STUB/notify.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PUSH_ARGV_LOG"
if [[ "${PUSH_STUB_RC:-0}" != 0 ]]; then echo "stub notify: no backend configured" >&2; exit "$PUSH_STUB_RC"; fi
exit 0
EOF
chmod +x "$STUB/ng" "$STUB/notify.sh"
export REMOTE_NOTIFY_NG_BIN="$STUB/ng" REMOTE_NOTIFY_PUSH_BIN="$STUB/notify.sh"
export NG_ARGV_LOG="$WORK/ng.argv" PUSH_ARGV_LOG="$WORK/push.argv" NG_BODY_COPY="$WORK/ng.body"

reset_surfaces() {
    : > "$NG_ARGV_LOG"; : > "$PUSH_ARGV_LOG"; rm -f "$NG_BODY_COPY" "$MARKER" "$NOTICE"
    export NG_STUB_RC=0 PUSH_STUB_RC=0
}

# ===========================================================================
echo "== UNIT 1. the client re-pin notice names the transition and the endpoint =="
write_ak ""                                    # enrolled, NO from= (the live shape)
export MONITOR_REMOTE_FROM_CIDR=10.0.0.1/32
out=$(bash -c "source '$LIB'; _remote_client_repin_notice 22022 22023")
# A loopback bind renders the CLIENT-side target `localhost` (it reaches us
# through its own forward), matching _remote_onboarding_notice exactly — the
# whole point of single-sourcing _remote_endpoint_params. UNIT 4 covers the
# LAN posture, where the endpoint is the bind address itself.
assert_contains "names the OLD port as dead"      "$out" "localhost:22022"
assert_contains "names the NEW port"              "$out" "localhost:22023"
assert_contains "carries a runnable reconnect line with the NEW port" "$out" "-p 22023"
assert_contains "renders the on-disk host fingerprint" "$out" "$FP"
assert_contains "says the fingerprint did NOT change" "$out" "UNCHANGED"
assert_contains "names the client key file"       "$out" "~/.ssh/nexus-remote"

echo "== UNIT 2. the notice is SECRET-FREE (it is designed to reach GitHub) =="
assert_not_contains "no public-key blob in the notice"  "$out" "$KEYBLOB"
assert_not_contains "no key-type token in the notice"   "$out" "$KEYTYPE"
assert_not_contains "no PEM header in the notice"       "$out" "PRIVATE KEY"

echo "== UNIT 3. the re-enroll clause tracks _remote_from_audit, both directions =="
assert_contains "from= ABSENT on the live credential ⇒ says a re-enroll is owed" "$out" "RE-ENROLL IS ALSO OWED"
assert_contains "…and names the configured pin that is missing" "$out" "10.0.0.1/32"
assert_contains "…and gives the two-command remedy"             "$out" "enroll-invite"
# A LAN-ONLY pin under this fixture's LOOPBACK bind is NOT a satisfied pin —
# it is the credential sshd refuses at publickey time (your-org/nexus-code#902).
# So the re-enroll clause SHOULD fire here, and that is the operator signal.
write_ak "10.0.0.1/32"
out_lanpin=$(bash -c "source '$LIB'; _remote_client_repin_notice 22022 22023")
assert_contains "loopback bind + LAN-only pin ⇒ re-enroll IS owed (#902)" \
    "$out_lanpin" "RE-ENROLL IS ALSO OWED"

# THE NEGATIVE CONTROL, now stated at the posture-aware value: a credential
# carrying what an enroll would write TODAY is clean and must not nag.
write_ak "10.0.0.1/32,127.0.0.1/32,::1/128"
out_pinned=$(bash -c "source '$LIB'; _remote_client_repin_notice 22022 22023")
assert_not_contains "credential carries the POSTURE-AWARE pin ⇒ NO re-enroll clause" \
    "$out_pinned" "RE-ENROLL IS ALSO OWED"

# …and on a ROUTABLE bind the LAN-only pin is still clean — unchanged behaviour.
write_ak "10.0.0.1/32"
out_lanbind=$(MONITOR_REMOTE_BIND_ADDRESS=10.9.9.9 bash -c "source '$LIB'; _remote_client_repin_notice 22022 22023")
assert_not_contains "routable bind + LAN pin ⇒ still NO re-enroll clause" \
    "$out_lanbind" "RE-ENROLL IS ALSO OWED"
rm -f "$AK"
out_noak=$(bash -c "source '$LIB'; _remote_client_repin_notice 22022 22023")
assert_contains "nothing enrolled ⇒ says so instead of demanding a re-enroll" \
    "$out_noak" "NO CLIENT IS ENROLLED YET"
assert_not_contains "…and does not claim a re-enroll is owed" "$out_noak" "RE-ENROLL IS ALSO OWED"
write_ak ""

echo "== UNIT 4. posture-aware: loopback renders a tunnel, LAN renders none =="
out_lo=$(MONITOR_REMOTE_BIND_ADDRESS=127.0.0.1 bash -c "source '$LIB'; _remote_client_repin_notice 1 2")
assert_contains "loopback bind ⇒ the SSH forward line is present" "$out_lo" "ssh -N -L 2:127.0.0.1:2"
out_lan=$(MONITOR_REMOTE_BIND_ADDRESS=10.9.9.9 bash -c "source '$LIB'; _remote_client_repin_notice 1 2")
assert_contains "LAN bind ⇒ connect straight, no tunnel"        "$out_lan" "no tunnel needed"
assert_not_contains "LAN bind ⇒ no forward line (negative control)" "$out_lan" "ssh -N -L"
assert_contains "LAN bind ⇒ the endpoint is the bind address"   "$out_lan" "10.9.9.9:2"

echo "== UNIT 5. no host key on disk ⇒ says so, does not invent a fingerprint =="
mv "$PRINCIPALS/ssh_host_ed25519_key.pub" "$WORK/keep.pub"
out_nokey=$(bash -c "source '$LIB'; _remote_client_repin_notice 22022 22023")
assert_contains "missing host key is NAMED, not silently blank" "$out_nokey" "NOT AVAILABLE"
assert_contains "…and points at the command that produces it"   "$out_nokey" "remote-up.sh --status"
assert_not_contains "…and does not print the stale fingerprint" "$out_nokey" "$FP"
mv "$WORK/keep.pub" "$PRINCIPALS/ssh_host_ed25519_key.pub"

echo "== UNIT 6. _remote_endpoint_params honours an explicit port override =="
got=$(bash -c "source '$LIB'; _remote_endpoint_params 44444; printf '%s' \"\$_REMOTE_EP_PORT\"")
assert_eq "explicit override wins over the port in force" "$got" "44444"
printf '39777\n' > "$PORTFILE"
got=$(bash -c "source '$LIB'; _remote_endpoint_params; printf '%s' \"\$_REMOTE_EP_PORT\"")
assert_eq "no override ⇒ the recorded port in force" "$got" "39777"
rm -f "$PORTFILE"

# ===========================================================================
echo "== UNIT 7. usage is fail-closed on a nonsense transition =="
reset_surfaces
bash "$NOTIFY" --old 22022 --new 22022 >/dev/null 2>&1; rc=$?
assert_rc "old == new is refused (there is no change to announce)" "$rc" 1
bash "$NOTIFY" --old abc --new 22023 >/dev/null 2>&1; rc=$?
assert_rc "a non-numeric port is refused" "$rc" 1
bash "$NOTIFY" --new 22023 >/dev/null 2>&1; rc=$?
assert_rc "a missing --old is refused" "$rc" 1
assert_empty "…and no surface was touched by any refused invocation" "$(cat "$NG_ARGV_LOG" "$PUSH_ARGV_LOG")"

echo "== T9. github ok + push FAILED ⇒ delivered (rc 0), no marker =="
reset_surfaces
export MONITOR_REMOTE_ENDPOINT_ISSUE=311 MONITOR_REMOTE_ENDPOINT_ISSUE_REPO=acme/ops
PUSH_STUB_RC=2 bash "$NOTIFY" --old 22022 --new 22023 >"$WORK/o" 2>&1; rc=$?
o=$(cat "$WORK/o")
assert_rc      "one accepting surface is enough (rc 0)" "$rc" 0
assert_no_file "no UNDELIVERED marker when something landed" "$MARKER"
assert_contains "github reported ok"        "$o" "github:      ok"
assert_contains "push reported FAILED (not hidden behind the success)" "$o" "push:        FAILED"
ngargv=$(cat "$NG_ARGV_LOG")
assert_contains "ng got the configured issue number" "$ngargv" "comment 311"
assert_contains "ng got the configured repo"         "$ngargv" "--repo acme/ops"
assert_contains "ng got a --body-file"               "$ngargv" "--body-file"
body=$(cat "$NG_BODY_COPY" 2>/dev/null || echo "")
assert_contains "the POSTED body carries the transition headline" "$body" "port 22022 → 22023"
assert_contains "the POSTED body embeds the client paste"         "$body" "MOVED PORT"
assert_contains "the POSTED body says what to do with it"         "$body" "Send it exactly this"
assert_file_exists "the durable local copy was written" "$NOTICE"

echo "== T10. github FAILED + push ok ⇒ delivered (rc 0), and the failure is NAMED =="
reset_surfaces
NG_STUB_RC=7 bash "$NOTIFY" --old 22022 --new 22024 >"$WORK/o" 2>&1; rc=$?
o=$(cat "$WORK/o")
assert_rc      "the surviving surface carries it (rc 0)" "$rc" 0
assert_no_file "no marker while a surface still accepted" "$MARKER"
assert_contains "github failure is reported, not swallowed" "$o" "github:      FAILED"
assert_contains "…and the stub's own stderr is relayed"     "$o" "NG_STUB_RC=7"
assert_contains "push reported ok"                          "$o" "push:        ok"
pushargv=$(cat "$PUSH_ARGV_LOG")
assert_contains "push is sent at EMERGENCY priority" "$pushargv" "--priority emergency"
assert_contains "push demands delivery (a dead backend is an error)" "$pushargv" "--require-delivery"
assert_contains "push names both ports"              "$pushargv" "22024"

echo "== T11. BOTH surfaces fail ⇒ rc 3, durable marker, actionable retry =="
reset_surfaces
NG_STUB_RC=7 PUSH_STUB_RC=3 bash "$NOTIFY" --old 22022 --new 22025 >"$WORK/o" 2>&1; rc=$?
o=$(cat "$WORK/o")
assert_rc          "no durable surface accepted ⇒ rc 3" "$rc" 3
assert_file_exists "an UNDELIVERED marker is left behind" "$MARKER"
assert_contains    "the marker names the transition" "$(cat "$MARKER")" "old=22022"
assert_contains    "…and the new port"               "$(cat "$MARKER")" "new=22025"
assert_contains    "stderr states plainly that nobody was informed" "$o" "NO DURABLE SURFACE ACCEPTED"
assert_contains    "…and gives the exact re-send command"           "$o" "--old 22022 --new 22025"
assert_file_exists "the local copy is still written (the passive trail)" "$NOTICE"

echo "== T12. endpoint_issue UNSET is a FAILED surface, never a silent skip =="
reset_surfaces
unset MONITOR_REMOTE_ENDPOINT_ISSUE MONITOR_REMOTE_ENDPOINT_ISSUE_REPO
cat > "$WORK/cfg-noissue.yml" <<'YAML'
monitor:
  remote:
    bind_address: 127.0.0.1
YAML
o=$(NEXUS_CONFIG="$WORK/cfg-noissue.yml" PUSH_STUB_RC=2 bash "$NOTIFY" --old 22022 --new 22026 2>&1); rc=$?
assert_rc       "unconfigured issue + dead push ⇒ rc 3 (not a quiet success)" "$rc" 3
assert_contains "the unconfigured target is reported as FAILED" "$o" "github:      FAILED"
assert_contains "…and says which key to set"                    "$o" "endpoint_issue"
assert_contains "…and explains why there is no default"         "$o" "somebody else's thread"
assert_empty    "ng was never invoked with no issue configured" "$(cat "$NG_ARGV_LOG")"
assert_file_exists "the marker records the undelivered notice" "$MARKER"

echo "== T12b. endpoint_issue unset but push ALIVE ⇒ still delivered (rc 0) =="
reset_surfaces
o=$(NEXUS_CONFIG="$WORK/cfg-noissue.yml" bash "$NOTIFY" --old 22022 --new 22027 2>&1); rc=$?
assert_rc      "push alone satisfies the durability requirement" "$rc" 0
assert_no_file "…and clears/never writes the marker" "$MARKER"

echo "== T13. a successful re-send CLEARS a stale UNDELIVERED marker =="
reset_surfaces
export MONITOR_REMOTE_ENDPOINT_ISSUE=311
printf 'stale\tundelivered\told=1\tnew=2\treason=planted\n' > "$MARKER"
bash "$NOTIFY" --old 22022 --new 22028 >/dev/null 2>&1; rc=$?
assert_rc      "the re-send succeeds" "$rc" 0
assert_no_file "the stale marker is cleared on success" "$MARKER"

echo "== T14. --dry-run delivers NOTHING and says so =="
reset_surfaces
o=$(bash "$NOTIFY" --old 22022 --new 22029 --dry-run 2>&1); rc=$?
assert_rc    "dry run exits 0" "$rc" 0
assert_empty "ng was NOT invoked"     "$(cat "$NG_ARGV_LOG")"
assert_empty "notify.sh was NOT invoked" "$(cat "$PUSH_ARGV_LOG")"
assert_contains "the body is shown for inspection" "$o" "MOVED PORT"
assert_contains "…and it is labelled as undelivered" "$o" "NOTHING was delivered"
assert_no_file  "…and no marker is armed by a rehearsal" "$MARKER"

echo "== T14b. --dry-run is a faithful rehearsal: it runs the secret gate too =="
# The gate deliberately runs BEFORE the dry-run exit — a rehearsal that skips the
# gate the real run must pass is not a rehearsal — and the skeptic noted nothing
# asserted it. But a refusing rehearsal must NOT arm the persistent marker: it
# was never going to deliver, so there is no delivery failure to make durable,
# and marking would make `--status` cry wolf over a notice that does not exist.
reset_surfaces
o=$(MONITOR_REMOTE_FROM_CIDR="$KEYTYPE $KEYBLOB" bash "$NOTIFY" --old 22022 --new 22035 --dry-run 2>&1); rc=$?
assert_rc       "a dry run DOES exercise the secret gate (rc 3, not a free pass)" "$rc" 3
assert_contains "…and refuses loudly, naming the guard" "$o" "secret guard"
assert_not_contains "…and does NOT print the body it refused" "$o" "MOVED PORT"
assert_contains "…and says why no marker was armed"     "$o" "NO undelivered marker armed"
assert_no_file  "…and arms NO persistent marker (a rehearsal is not a delivery failure)" "$MARKER"
assert_empty    "…and posts nothing"                    "$(cat "$NG_ARGV_LOG")"
export MONITOR_REMOTE_FROM_CIDR=10.0.0.1/32

echo "== T15. the secret guard gates the outbound write, fail-closed =="
# Inject through a real interpolated field (from_cidr reaches the re-enroll
# clause) — the guard must refuse BEFORE anything is posted. This is the
# property, not a proxy: the assertion is that ng was never called.
reset_surfaces
o=$(MONITOR_REMOTE_FROM_CIDR="$KEYTYPE $KEYBLOB" bash "$NOTIFY" --old 22022 --new 22030 2>&1); rc=$?
assert_rc       "a secret-shaped body is refused (rc 3)" "$rc" 3
assert_contains "the refusal is loud and names the guard" "$o" "secret guard"
assert_empty    "NOTHING was posted to GitHub"    "$(cat "$NG_ARGV_LOG")"
assert_empty    "NOTHING was pushed"              "$(cat "$PUSH_ARGV_LOG")"
assert_file_exists "the marker records the refusal" "$MARKER"
export MONITOR_REMOTE_FROM_CIDR=10.0.0.1/32

echo "== T16. the MARKER's own write/clear failures are reported, never assumed =="
# The marker IS the persistence mechanism, so a marker operation that fails
# silently is this file's defect class one layer down. It WAS silent: three
# `>> … 2>/dev/null || true` operations under a header claiming nothing was
# swallowed. Found by the skeptic pass on `#761` (req-001); these are its cases.
reset_surfaces
chmod 500 "$PRINCIPALS"
if [[ -w "$PRINCIPALS" ]]; then
    chmod 700 "$PRINCIPALS"
    th_skip "marker write/clear failure" "chmod 500 left \$PRINCIPALS writable (running as root?) — the unwritable-dir case cannot be constructed here"
else
    # (a) nothing delivered AND the marker cannot be written: the run must NOT
    #     claim persistence it does not have.
    o=$(NG_STUB_RC=7 PUSH_STUB_RC=3 bash "$NOTIFY" --old 22022 --new 22031 2>&1); rc=$?
    chmod 700 "$PRINCIPALS"
    assert_rc          "still rc 3 — the delivery verdict is unchanged" "$rc" 3
    assert_no_file     "the marker genuinely is not on disk" "$MARKER"
    assert_contains    "the marker failure is NAMED"            "$o" "marker:      FAILED"
    assert_contains    "…and says the failure could not be made persistent" "$o" "could NOT be"
    assert_contains    "…and warns that --status will show nothing about it"  "$o" "--status\` will show NOTHING"
    assert_not_contains "…and does NOT claim a marker was written (the shipped lie)" "$o" "marker:      written"
    # A redirection failure is the SHELL's, so `2>/dev/null` on the command could
    # never suppress it (your-org/nexus-code#723). The old code let that raw line
    # bleed out unattributed and then contradicted it. We pre-check instead.
    assert_not_contains "no raw unattributed shell redirection error leaks" "$o" "Permission denied"

    # (b) delivery SUCCEEDS but a stale marker cannot be removed: --status would
    #     cry wolf forever, so that must be said. It must NOT change the verdict.
    reset_surfaces
    printf 'stale\tundelivered\told=1\tnew=2\treason=planted\n' > "$MARKER"
    chmod 500 "$PRINCIPALS"
    o=$(bash "$NOTIFY" --old 22022 --new 22032 2>&1); rc=$?
    chmod 700 "$PRINCIPALS"
    assert_rc          "delivery succeeded ⇒ still rc 0 (a leftover file is not a delivery failure)" "$rc" 0
    assert_contains    "the surviving stale marker is NAMED"    "$o" "marker:      STALE"
    assert_contains    "…and says --status will keep reporting it" "$o" "keep"
    assert_contains    "…and the delivery is still reported"    "$o" "delivered on at least one durable surface"
    assert_file_exists "…and the stale marker is indeed still there" "$MARKER"
    rm -f "$MARKER"
fi

echo "== T16b. positive control: on a writable dir both marker paths report success =="
reset_surfaces
o=$(NG_STUB_RC=7 PUSH_STUB_RC=3 bash "$NOTIFY" --old 22022 --new 22033 2>&1)
assert_contains "a successful marker write says so"  "$o" "marker:      written"
o=$(bash "$NOTIFY" --old 22022 --new 22034 2>&1)
assert_contains "a successful marker clear says so"  "$o" "marker:      cleared"
assert_no_file  "…and the marker really is gone"     "$MARKER"

# ===========================================================================
# INT — through remote-up.sh, on a REAL recorded move. Mirrors
# test-remote-port-select.sh's fixture: stub sshd, fixture registry, squatter.
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
squat_port() {
    local port="$1"
    python3 -c "
import socket,signal,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port)); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
signal.signal(signal.SIGINT,  lambda *a: sys.exit(0))
while True:
    try: c,_=s.accept(); c.close()
    except Exception: time.sleep(0.05)
" &
    local pid=$!; disown "$pid" 2>/dev/null || true; SQUATTERS+=("$pid")
    local i; for (( i=0; i<50; i++ )); do
        ( exec 3<>"/dev/tcp/127.0.0.1/$port" ) 2>/dev/null && return 0; sleep 0.1
    done; return 1
}
write_cfg() { cat > "$WORK/cfg.yml" <<YAML
monitor:
  remote:
    bind_address: 127.0.0.1
    port: $1
YAML
}
STUBD="$WORK/stub-sshd"; mkdir -p "$STUBD"
cat > "$STUBD/sshd" <<EOF
#!/usr/bin/env bash
port=""
while (( \$# )); do [[ "\$1" == "-p" ]] && { port="\$2"; shift; }; shift; done
exec python3 -c "
import socket,signal,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',int('\$port'))); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    try:
        c,_=s.accept(); c.sendall(b'SSH-2.0-stubsshd\r\n'); c.close()
    except Exception: pass
"
EOF
chmod +x "$STUBD/sshd"
export REMOTE_SSHD_BIN="$STUBD/sshd"
register_row() { printf 'nexus-remote-ssh\t%s\t%s\t%s\t%s\temit-only\n' \
    "$NEXUS_ROOT" "$MON_DIR/remote-sshd-supervised.sh" "$MON_DIR/remote-ssh-health.sh" "$WORK/svc.log" > "$NEXUS_SERVICES_REGISTRY"; }
kill_supervisors() {
    local pf pid
    for pf in "$WORK"/state/services/*.pid; do
        [[ -f "$pf" ]] || continue
        read -r pid < "$pf" 2>/dev/null || continue
        [[ "$pid" =~ ^[0-9]+$ ]] && { kill -TERM -- "-$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; }
        rm -f "$pf"
    done
}

echo "== INT 1. a REAL move fires the durable alert with the real old/new ports =="
kill_supervisors; reset_surfaces
rm -f "$PORTFILE" "$HISTFILE"
OCC=$(free_port); squat_port "$OCC" || printf '  (could not occupy port — case weakened)\n'
write_cfg "$OCC"; register_row
out=$(NEXUS_CONFIG="$WORK/cfg.yml" MONITOR_REMOTE_ENDPOINT_ISSUE=311 REMOTE_UP_TIMEOUT=3 bash "$UP" 2>&1)
newport=$(cat "$PORTFILE" 2>/dev/null || echo "")
assert_contains "remote-up still announces the move loudly on stderr" "$out" "PORT CHANGED"
ngargv=$(cat "$NG_ARGV_LOG")
assert_contains "the durable emitter ran and targeted the configured issue" "$ngargv" "comment 311"
body=$(cat "$NG_BODY_COPY" 2>/dev/null || echo "")
assert_contains "the posted body names the OCCUPIED port as the old one" "$body" "port $OCC"
if [[ -n "$newport" ]] && grep -qF -- "$newport" <<<"$body"; then
    printf '  PASS: the posted body names the ACTUALLY RECORDED new port (%s)\n' "$newport"; PASS=$((PASS+1))
else
    printf '  FAIL: posted body does not name the recorded new port %q\n' "$newport" >&2; FAIL=$((FAIL+1))
fi
assert_contains "the reason travels with the alert" "$body" "occupied by a non-ours listener"
assert_no_file  "a delivered alert leaves no marker" "$MARKER"
kill_supervisors

echo "== INT 2. no move ⇒ the emitter is NOT invoked (negative control) =="
kill_supervisors; reset_surfaces
rm -f "$HISTFILE"
PREF=$(free_port); printf '%s\n' "$PREF" > "$PORTFILE"     # recorded + free ⇒ sticky
write_cfg "$PREF"; register_row
out=$(NEXUS_CONFIG="$WORK/cfg.yml" MONITOR_REMOTE_ENDPOINT_ISSUE=311 REMOTE_UP_TIMEOUT=3 bash "$UP" 2>&1)
assert_not_contains "no PORT CHANGED banner on a sticky re-run" "$out" "PORT CHANGED"
assert_empty "ng was NOT invoked when nothing moved"      "$(cat "$NG_ARGV_LOG")"
assert_empty "notify.sh was NOT invoked when nothing moved" "$(cat "$PUSH_ARGV_LOG")"
assert_no_file "no notice file written when nothing moved" "$NOTICE"
kill_supervisors

echo "== INT 3. a FAILED alert does NOT block the bring-up, and is made persistent =="
kill_supervisors; reset_surfaces
rm -f "$PORTFILE" "$HISTFILE"
OCC2=$(free_port); squat_port "$OCC2" || printf '  (could not occupy port — case weakened)\n'
write_cfg "$OCC2"; register_row
out=$(NEXUS_CONFIG="$WORK/cfg.yml" MONITOR_REMOTE_ENDPOINT_ISSUE=311 \
      NG_STUB_RC=7 PUSH_STUB_RC=3 REMOTE_UP_TIMEOUT=3 bash "$UP" 2>&1); up_rc=$?
assert_rc       "remote-up still exits 0 — a working endpoint beats no endpoint" "$up_rc" 0
assert_contains "the endpoint was still brought up (setup message present)" "$out" "service is registered"
assert_contains "the alert failure is stated in the operator's terms" "$out" "NOBODY HAS BEEN INFORMED"
assert_contains "…and names the file holding the text to send the client" "$out" "port-change-notice.md"
assert_contains "…and gives the re-send command"  "$out" "remote-port-change-notify.sh --old"
assert_file_exists "the failure is persisted as a marker" "$MARKER"
newport2=$(cat "$PORTFILE" 2>/dev/null || echo "")
assert_eq "the port still moved (the alert is not a gate on the move)" \
    "$( [[ -n "$newport2" && "$newport2" != "$OCC2" ]] && echo moved || echo stuck )" "moved"

echo "== INT 4. --status keeps surfacing an undelivered notice until it is fixed =="
st=$(NEXUS_CONFIG="$WORK/cfg.yml" bash "$UP" --status 2>&1)
assert_contains "status announces the undelivered notice" "$st" "NEVER DELIVERED"
assert_contains "…and points at the client text"          "$st" "port-change-notice.md"
assert_contains "…and repeats the re-send command"        "$st" "remote-port-change-notify.sh"
rm -f "$MARKER"
st=$(NEXUS_CONFIG="$WORK/cfg.yml" bash "$UP" --status 2>&1)
assert_not_contains "…and stops once the marker is gone (negative control)" "$st" "NEVER DELIVERED"
kill_supervisors

echo "== INT 5. the bell escapes the \`task\` catch-all that batched the old alert away =="
# The transient bell is defence in depth, not the durable surface — but the
# MEASURED reason the shipped alert vanished was its CLASS, and a class is a
# property of the message TEXT. Nothing else in the repo watches that, so an
# innocent reword would silently drop it back into the catch-all. Take the
# message from the REAL call site (a PATH-front sandbox-notify stub records what
# alert_port_change actually emits — never re-typed here, which would let the
# test pass while the source drifted), then run the REAL notifywrap on it.
NBSTUB="$WORK/nb"; mkdir -p "$NBSTUB"
cat > "$NBSTUB/sandbox-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BELL_ARGV_LOG"
EOF
chmod +x "$NBSTUB/sandbox-notify"
export BELL_ARGV_LOG="$WORK/bell.argv"; : > "$BELL_ARGV_LOG"
reset_surfaces
MONITOR_REMOTE_ENDPOINT_ISSUE=311 PATH="$NBSTUB:$PATH" NEXUS_NOTIFY_QUIET=0 \
    bash -c "source '$UP' >/dev/null 2>&1; PORT_OLD=22022; PORT_NEW=22023; alert_port_change" \
    >/dev/null 2>&1
BELLMSG=$(head -1 "$BELL_ARGV_LOG" 2>/dev/null || echo "")
assert_contains "alert_port_change does emit a bell, and it names the move" "$BELLMSG" "22022->22023"

NOTIFYWRAP="$MON_DIR/notifywrap/sandbox-notify"
if [[ ! -x "$NOTIFYWRAP" ]]; then
    th_skip "bell classification" "monitor/notifywrap/sandbox-notify is not executable at $NOTIFYWRAP"
elif [[ -z "$BELLMSG" ]]; then
    th_skip "bell classification" "alert_port_change emitted no bell to classify (see the assertion above)"
else
    # Occupy the `task` cooldown with an unrelated worker ping, then fire ours.
    # This is exactly the repro in your-org/nexus-code#757: under the OLD text the
    # second line read verdict=suppress-cooldown and ZERO bells were emitted.
    NSTATE="$WORK/notifystate"; rm -rf "$NSTATE"; mkdir -p "$NSTATE"
    : > "$WORK/realbell.log"
    env -u NEXUS_NOTIFY_QUIET SANDBOX_NOTIFY_STUB_LOG="$WORK/realbell.log" \
        NEXUS_NOTIFY_STATE_DIR="$NSTATE" NEXUS_NOTIFY_ANCESTRY_SCAN=0 \
        PATH="$NBSTUB:$PATH" "$NOTIFYWRAP" "worker fixture: done" >/dev/null 2>&1
    env -u NEXUS_NOTIFY_QUIET SANDBOX_NOTIFY_STUB_LOG="$WORK/realbell.log" \
        NEXUS_NOTIFY_STATE_DIR="$NSTATE" NEXUS_NOTIFY_ANCESTRY_SCAN=0 \
        PATH="$NBSTUB:$PATH" "$NOTIFYWRAP" "$BELLMSG" >/dev/null 2>&1
    dec=$(cat "$NSTATE/notify-decisions.jsonl" 2>/dev/null || echo "")
    ours=$(printf '%s\n' "$dec" | grep -F -- "22022->22023" || true)
    assert_contains "the port-change bell classifies as \`critical\`, not the \`task\` catch-all" \
        "$ours" '"class":"critical"'
    assert_contains "…and RINGS despite a task-class bell 1 line earlier (the #757 repro)" \
        "$ours" '"verdict":"ring"'
    assert_not_contains "…and is NOT batched into a digest" "$ours" "suppress-cooldown"
    # NEGATIVE CONTROL — the SHIPPED text under the SAME sequence, in a FRESH
    # state dir. Fresh matters: replaying it into the dir above would be
    # confounded by the incident window our own `critical` bell just opened
    # (observed: verdict=suppress-incident), and the variable under test is the
    # CLASS, not the cascade collapse. So this isolates one difference — the
    # message text — and shows it is what decides ring vs silence.
    NSTATE2="$WORK/notifystate2"; rm -rf "$NSTATE2"; mkdir -p "$NSTATE2"
    env -u NEXUS_NOTIFY_QUIET SANDBOX_NOTIFY_STUB_LOG="$WORK/realbell.log" \
        NEXUS_NOTIFY_STATE_DIR="$NSTATE2" NEXUS_NOTIFY_ANCESTRY_SCAN=0 \
        PATH="$NBSTUB:$PATH" "$NOTIFYWRAP" "worker fixture: done" >/dev/null 2>&1
    env -u NEXUS_NOTIFY_QUIET SANDBOX_NOTIFY_STUB_LOG="$WORK/realbell.log" \
        NEXUS_NOTIFY_STATE_DIR="$NSTATE2" NEXUS_NOTIFY_ANCESTRY_SCAN=0 \
        PATH="$NBSTUB:$PATH" "$NOTIFYWRAP" \
        "nexus-remote-ssh port CHANGED 9001->9002 — re-inform your remote client (was pinned to :9001)" \
        >/dev/null 2>&1
    old=$(grep -F -- "9001->9002" "$NSTATE2/notify-decisions.jsonl" 2>/dev/null || true)
    assert_contains     "negative control: the SHIPPED text still falls to the \`task\` catch-all" "$old" '"class":"task"'
    assert_contains     "negative control: …and is batched away by its cooldown" "$old" "suppress-cooldown"
    assert_not_contains "negative control: …so it never rings (the shipped defect)" "$old" '"verdict":"ring"'
fi

th_summary_and_exit
