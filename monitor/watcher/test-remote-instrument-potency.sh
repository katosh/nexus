#!/usr/bin/env bash
# INSTRUMENT POTENCY on the endpoint-identity probe (your-org/your-nexus#331).
#
# THE DEFECT, measured on the live nexus at 2026-08-24 17:48 -07:00. Name
# service resolution for our own uid failed inside the sandbox — `getent passwd
# 71780` rc 2, our passwd record absent — and `ssh`/`ssh-keygen` call
# `getpwuid()` at startup and abort:
#
#     ssh -V                 → No user exists for uid 71780   (rc 255)
#     ssh-keygen -lf <ours>  → No user exists for uid 71780
#     ssh-keyscan …          → WORKS  (it does not call getpwuid)
#
# `_remote_verify_live_host_key` then returned:
#
#     rc=1  detail: reached the listener but could not verify it is ours;
#           unclassified probe result: No user exists for uid 71780
#
# rc 1 is DEFINITE FOREIGN and is explicitly NOT operator-overridable, so the
# healthcheck escalated `nexus-remote-ssh` to DOWN — against a daemon that had
# been serving correctly for ten days, whose socket `ss -ltnpe` attributed to
# OUR uid WITH pid attribution (i.e. inside this user+pid namespace), and whose
# live host key was BYTE-IDENTICAL to `_remote_expected_host_key`. The emit's
# recommended remedy was `monitor/svc.sh restart nexus-remote-ssh`; running it
# would have destroyed a working endpoint and put the port into the genuinely
# contested state of the real two-week outage (your-org/your-nexus#326).
#
# WHY THE EXISTING ARM WAS WRONG WITHOUT BEING BADLY WRITTEN. The terminal arm
# fails CLOSED on purpose and its `#609` F9 comment is right to:
#
#     "treat as hostile" is a strong claim and must not fire on an accident.
#
# Its soundness rests on an UNSTATED PREMISE — that the ssh client actually
# executed a key exchange, so an unclassified diagnostic describes a PROTOCOL
# outcome. When the client aborts for a purely LOCAL reason the premise fails
# silently: `command -v "$sshbin"` still succeeds (the binary is PRESENT, it
# merely refuses to RUN — presence is a proxy for usability and the two came
# apart), no rc-2 guard fires, and the accident is reported as a verdict.
#
# THE FIX IS NOT A LONGER STRING LIST. Adding `No user exists for uid` to the
# matched wordings re-instantiates the defect class one wording later. The axis
# the mechanism varies on is whether THE INSTRUMENT RAN AT ALL, so the terminal
# arm now demands a POSITIVE CONTROL on the instrument — a local, network-free
# invocation of the same binary — before it is allowed to call anything hostile.
# A probe that could not execute yields UNKNOWN (rc 2, operator-overridable),
# never FOREIGN.
#
# WHAT THIS SUITE ASSERTS, and why every case is load-bearing:
#
#   1. THE REPRODUCTION — a client that cannot start (the live wording,
#      verbatim) yields rc 2 INDETERMINATE, not rc 1 FOREIGN.
#   2. THE NEGATIVE CONTROL THAT MATTERS — a client that RUNS FINE and emits an
#      UNCLASSIFIED diagnostic still yields rc 1 DEFINITE FOREIGN. Without this
#      case, a fix that simply deleted the terminal arm would pass case 1. The
#      `#609` F9 asymmetry must survive, and this is the assertion that proves
#      it did.
#   3. WORDING-INDEPENDENCE — a client that cannot start for a DIFFERENT local
#      reason (a shared-library failure; nothing to do with getpwuid) is also
#      UNKNOWN. A fix that only recognises the passwd wording fails here.
#   4. THE CLASSIFIED PROTOCOL ARMS ARE UNTOUCHED — forgery still rc 3,
#      key-mismatch still rc 1, handshake-failure still rc 1, verified still
#      rc 0. These run through the same code path the potency check guards.
#   5. THE PROBE-LEVEL VERDICT — `_remote_identity_probe` reports
#      `indeterminate` (rc 2) rather than `foreign`, and its reason does not
#      contain the word FOREIGN. rc 2 is the ONE verdict
#      `health_require_identity` may override, so this is what restores the
#      operator knob that was bypassed by construction.
#   6. THE DISCARDED ANSWER — with `ssh-keygen` unusable, both key blobs are
#      still in hand as text. The live blob is compared to ours DIRECTLY, so
#      the report says byte-identical instead of the live emit's `? != ?`.
#      A blob match is NOT possession (our public host key is handed to clients
#      by design and is replayable — `#609` F1), so it must never green a
#      verdict; case 5 asserts it does not.
#   7. THE POTENCY CHECK COSTS THE HEALTHY PATH NOTHING — it is reached only
#      after the probe failed to classify, so a verified endpoint performs
#      exactly one connect, preserving the `#431`/`#434` MaxStartups=3 budget.
#
# THE FIXTURES ARE STUBS ON `REMOTE_SSH_BIN`, DELIBERATELY. The trigger is a
# corrupted passwd file that the operator may repair at any moment, and a suite
# that depends on it is a suite that evaporates. Every case here is independent
# of the host's name service, needs no sshd, opens no socket, and reproduces the
# published rc and detail string byte-for-byte.
#
# Run: bash monitor/watcher/test-remote-instrument-potency.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
# Exported so the `bash -c` children below can `source "$LIB"` by NAME. Passing
# it positionally and sourcing `"$1"` works identically at runtime and is what
# this file did first — but a `source "$LIB"` is statically unresolvable, and
# test-ambient-shell-option-scope.sh tracks exactly that set. A name the graph
# can follow keeps this suite off a repo-wide manifest it has no business
# growing.
export LIB

WORK=$(mktemp -d -t nexus-potency-XXXXXX)
# principals_dir must resolve under $HOME/.claude at 0700 or
# _remote_principals_guard (correctly) refuses. Unique per PID so a parallel
# remote suite cannot collide.
PRINCIPALS="$HOME/.claude/principals-potency-$$"
cleanup() { rm -rf "$WORK" "$PRINCIPALS"; }
trap cleanup EXIT
mkdir -p "$WORK" "$HOME/.claude" "$PRINCIPALS"
chmod 700 "$HOME/.claude" "$PRINCIPALS"

# Hermetic config — the live nexus.yml carries a real routable bind and a /32
# pin which would otherwise leak into every case.
cat >"$WORK/nexus.yml" <<'YML'
monitor:
  remote:
    bind_address: 127.0.0.1
    from_cidr: ""
YML
export NEXUS_CONFIG="$WORK/nexus.yml"
export NEXUS_ROOT="$WORK"
export NEXUS_STATE_DIR="$WORK/state"
export MONITOR_REMOTE_PRINCIPALS_DIR="$PRINCIPALS"
mkdir -p "$WORK/state"

# A syntactically valid ed25519 public key. It is never used as a key here —
# only as the "<type> <blob>" text `_remote_expected_host_key` returns — so a
# fixed literal keeps the suite free of ssh-keygen, which is the tool the
# reproduced environment breaks.
# WELL-FORMED BASE64 — 68 chars, decodes cleanly to 51 bytes, exactly as a real
# ed25519 blob does. The first draft used a readable-but-malformed literal that
# `base64 -d` rejected; it still produced a fingerprint, because the fingerprint
# helper was hashing a failed decode (sk-sshhealth F2). A fixture that cannot
# survive the code's own input validation tests the validation, not the code.
OUR_BLOB='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
printf '%s potency-fixture\n' "$OUR_BLOB" > "$PRINCIPALS/ssh_host_ed25519_key.pub"
chmod 600 "$PRINCIPALS/ssh_host_ed25519_key.pub"

# ── THE STUB CLIENT ─────────────────────────────────────────────────────
# It must distinguish the VERDICT PROBE from any POTENCY invocation without
# hardcoding which potency invocation the implementation chose. The verdict
# probe is the only call that passes `-o UserKnownHostsFile=` — that is the
# discriminator, so `ssh -V`, `ssh -Q key`, `ssh -G`, or anything else the fix
# settles on all route to the potency arm. A test pinned to `-V` would be
# testing the mechanism instead of the property.
#
#   make_stub <name> <potency-rc> <probe-stdout-or-stderr-text> [probe-rc]
# A potency-rc of 0 means "this client can run"; non-zero means it aborts at
# startup, in which case the SAME failure text is emitted for every invocation
# — which is exactly how the real broken `ssh` behaves.
make_stub() {
    local name="$1" prc="$2" text="$3" xrc="${4:-255}"
    local p="$WORK/$name"
    cat >"$p" <<EOF
#!/usr/bin/env bash
_is_probe=0
for a in "\$@"; do
    case "\$a" in UserKnownHostsFile=*) _is_probe=1 ;; esac
done
if (( $prc != 0 )); then
    # Cannot start: identical failure for EVERY invocation, potency included.
    printf '%s\n' ${text@Q} >&2
    exit $prc
fi
if (( _is_probe )); then
    printf '%s\n' ${text@Q} >&2
    exit $xrc
fi
exit 0
EOF
    chmod +x "$p"
    printf '%s' "$p"
}

# Run the verdict probe under a given stub. Called DIRECTLY (never in a
# subshell) would be ideal, but we need both the rc and the detail; the detail
# is echoed on a second line so one capture carries both without losing the
# global to a subshell.
probe_with() {   # probe_with <stub-path> → "rc<TAB>detail"
    local stub="$1"
    REMOTE_SSH_BIN="$stub" bash -c '
        source "$LIB"
        _remote_verify_live_host_key 198.51.100.7 22100 2; rc=$?
        printf "%s\t%s" "$rc" "$_REMOTE_VERIFY_DETAIL"
    ' _
}
rc_of()     { printf '%s' "${1%%$'\t'*}"; }
detail_of() { printf '%s' "${1#*$'\t'}"; }

# ── 1. THE REPRODUCTION ─────────────────────────────────────────────────
echo "== 1. a client that CANNOT START is UNKNOWN, not FOREIGN =="
NOUSER=$(make_stub ssh-nouser 255 'No user exists for uid 71780')

# First: this fixture reproduces the PUBLISHED behaviour and not a lookalike.
# Pinned against the live measurement so a fixture that drifted from the
# incident would be caught here rather than silently testing something else.
pre=$(REMOTE_SSH_BIN="$NOUSER" bash -c '
    source "$LIB"
    out=$("$REMOTE_SSH_BIN" -n -p 22100 -o UserKnownHostsFile=/dev/null x@y true 2>&1)
    printf "%s" "$out"
' _)
assert_eq "the fixture emits the live wording verbatim" \
    "$pre" "No user exists for uid 71780"

r=$(probe_with "$NOUSER")
assert_eq "the binary is PRESENT, so command -v cannot catch this" \
    "$(command -v "$NOUSER" >/dev/null 2>&1 && echo present || echo absent)" "present"
assert_eq "verdict is 2 INDETERMINATE (was 1 DEFINITE FOREIGN)" "$(rc_of "$r")" "2"
assert_not_contains "…and it does NOT claim to have reached the listener" \
    "$(detail_of "$r")" "reached the listener"
assert_contains "…the detail names the INSTRUMENT as the thing that failed" \
    "$(detail_of "$r")" "could not run"
assert_contains "…and quotes the client's own diagnostic for the operator" \
    "$(detail_of "$r")" "No user exists for uid 71780"

# ── 2. THE NEGATIVE CONTROL THAT MATTERS ────────────────────────────────
# Delete the terminal arm and case 1 passes; this case is what makes that fix
# fail. The instrument runs — so an unclassified diagnostic IS a protocol
# outcome — and the #609 F9 asymmetry must hold.
echo "== 2. a WORKING client with an UNCLASSIFIED diagnostic is STILL definite-foreign =="
WEIRD=$(make_stub ssh-weird 0 'ssh: something nobody has ever enumerated happened')
r=$(probe_with "$WEIRD")
assert_eq "verdict stays 1 DEFINITE FOREIGN (#609 F9 preserved)" "$(rc_of "$r")" "1"
assert_contains "…and the detail still says it reached the listener" \
    "$(detail_of "$r")" "reached the listener"
assert_contains "…quoting the unclassified output" \
    "$(detail_of "$r")" "nobody has ever enumerated"

# ── 3. WORDING-INDEPENDENCE ─────────────────────────────────────────────
# The whole point of fixing on the potency axis. A fix that pattern-matched
# `No user exists for uid` passes cases 1 and 2 and fails here.
echo "== 3. a DIFFERENT local abort, unrelated to getpwuid, is also UNKNOWN =="
LDFAIL=$(make_stub ssh-ldfail 127 \
    'ssh: error while loading shared libraries: libcrypto.so.1.1: cannot open shared object file')
r=$(probe_with "$LDFAIL")
assert_eq "an unrunnable client is UNKNOWN whatever its wording" "$(rc_of "$r")" "2"
assert_contains "…and the detail quotes THAT diagnostic, not a canned one" \
    "$(detail_of "$r")" "libcrypto.so.1.1"

# A client that cannot start but exits ZERO with no output must not be read as
# a silent success — the empty-output arm returns rc 0 OURS, which is the one
# place a broken instrument could manufacture a FALSE GREEN rather than a false
# red. Potency is checked before that arm is trusted.
echo "== 3b. a client that exits 0 saying NOTHING cannot manufacture a green =="
cat >"$WORK/ssh-silent-broken" <<'EOF'
#!/usr/bin/env bash
_is_probe=0
for a in "$@"; do case "$a" in UserKnownHostsFile=*) _is_probe=1 ;; esac; done
# The instrument is BROKEN: it fails the potency invocation…
(( _is_probe )) || exit 255
# …but the verdict probe returns empty-and-zero, which the old code read as
# "the kex verified, report ours".
exit 0
EOF
chmod +x "$WORK/ssh-silent-broken"
r=$(probe_with "$WORK/ssh-silent-broken")
assert_eq "a broken instrument's empty output is UNKNOWN, never OURS" "$(rc_of "$r")" "2"

# ── 4. THE CLASSIFIED PROTOCOL ARMS ARE UNTOUCHED ───────────────────────
echo "== 4. every classified arm keeps its verdict =="
OURS=$(make_stub ssh-ours 0 'operator@host: Permission denied (publickey).')
r=$(probe_with "$OURS")
assert_eq "auth-refused after kex → 0 VERIFIED OURS" "$(rc_of "$r")" "0"

FORGE=$(make_stub ssh-forge 0 'key_verify failed for server_host_key')
r=$(probe_with "$FORGE")
assert_eq "bad signature over the exchange hash → 3 FORGERY" "$(rc_of "$r")" "3"

MISMATCH=$(make_stub ssh-mismatch 0 \
    'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! Host key verification failed.')
r=$(probe_with "$MISMATCH")
assert_eq "a different host key → 1 DEFINITE FOREIGN" "$(rc_of "$r")" "1"

SQUAT=$(make_stub ssh-squat 0 \
    'kex_exchange_identification: Connection closed by remote host')
r=$(probe_with "$SQUAT")
assert_eq "the 2026-07-29 banner-only squatter → 1 DEFINITE FOREIGN" "$(rc_of "$r")" "1"

REFUSED=$(make_stub ssh-refused 0 'ssh: connect to host port 22100: Connection refused')
r=$(probe_with "$REFUSED")
assert_eq "nothing listening → 2 INDETERMINATE (unchanged)" "$(rc_of "$r")" "2"

MISSING="$WORK/ssh-does-not-exist"
r=$(probe_with "$MISSING")
assert_eq "an ABSENT client → 2 INDETERMINATE (the pre-existing guard)" "$(rc_of "$r")" "2"

# ── 5. THE PROBE-LEVEL VERDICT AND THE OPERATOR KNOB ────────────────────
# _remote_identity_probe is what the healthcheck and the supervisor consult.
# rc 2 is the ONLY verdict health_require_identity may override, so a fix that
# stopped at _remote_verify_live_host_key would leave the knob still bypassed.
echo "== 5. _remote_identity_probe reports INDETERMINATE, not FOREIGN =="
# The keyscan is stubbed to present OUR blob — the live situation exactly: the
# endpoint really is ours, keyscan really does work, and only the ssh client is
# unusable.
cat >"$WORK/keyscan-ours" <<EOF
#!/usr/bin/env bash
printf '[198.51.100.7]:22100 %s\n' '$OUR_BLOB'
EOF
chmod +x "$WORK/keyscan-ours"

idp=$(REMOTE_SSH_BIN="$NOUSER" REMOTE_KEYSCAN_BIN="$WORK/keyscan-ours" bash -c '
    source "$LIB"
    _remote_identity_probe 198.51.100.7 22100 2; rc=$?
    printf "%s\t%s\t%s" "$rc" "$_REMOTE_ID_VERDICT" "$_REMOTE_ID_REASON"
' _)
idp_rc=${idp%%$'\t'*}; idp_rest=${idp#*$'\t'}
idp_verdict=${idp_rest%%$'\t'*}; idp_reason=${idp_rest#*$'\t'}

assert_eq "probe rc is 2 — the one verdict the operator knob covers" "$idp_rc" "2"
assert_eq "verdict is indeterminate" "$idp_verdict" "indeterminate"
assert_not_contains "the reason does NOT accuse a foreign sshd" "$idp_reason" "FOREIGN"
assert_not_contains "…and does not present the live emit's ? != ? comparison" \
    "$idp_reason" "it presents ?, ours is ?"

# ── 6. THE DISCARDED ANSWER ─────────────────────────────────────────────
# Both blobs were in hand as text; the old code compared FINGERPRINTS through
# ssh-keygen — the one broken tool — and printed `?` for a key it was holding.
echo "== 6. the blob comparison the old code threw away =="
assert_contains "the reason states the live key is byte-identical to ours" \
    "$idp_reason" "BYTE-IDENTICAL"
assert_contains "…naming a REAL fingerprint, not the live emit's '?'" \
    "$idp_reason" "SHA256:"

# …and it must NOT be treated as possession. Our public host key is handed to
# clients by design, so anyone can replay it (#609 F1). A byte-match with an
# unusable instrument is UNKNOWN — asserted by case 5's rc 2 — and this is the
# explicit statement of that, so a later change that upgrades a blob match to
# OURS turns this red.
assert_not_contains "…without ever calling a blob match proof of possession" \
    "$idp_verdict" "ours"

# ── 6b. THE FINGERPRINT FALLBACK, AGAINST THE ORACLE ────────────────────
# `_remote_fingerprint_sha256` reimplements OpenSSH's SHA256 fingerprint
# without ssh-keygen, which is what stops `?` being printed for a key we hold.
# A fallback that computed a DIFFERENT number would be worse than `?` — a
# confident wrong fingerprint an operator might compare against their pin — so
# it is checked against ssh-keygen itself wherever ssh-keygen is usable, on a
# freshly generated throwaway key rather than on any live host key.
echo "== 6b. the ssh-keygen-free fingerprint agrees with ssh-keygen =="
if command -v ssh-keygen >/dev/null 2>&1 \
   && ssh-keygen -t ed25519 -N '' -C potency-oracle -f "$WORK/oracle_key" </dev/null >/dev/null 2>&1 \
   && oracle=$(ssh-keygen -lf "$WORK/oracle_key.pub" 2>/dev/null | awk '{print $2}') \
   && [[ "$oracle" == SHA256:* ]]; then
    read -r _ oracle_blob _ < "$WORK/oracle_key.pub"
    got=$(bash -c 'source "$LIB"; _remote_fingerprint_sha256 "$1"' _ "$oracle_blob")
    assert_eq "the fallback reproduces ssh-keygen's fingerprint exactly" "$got" "$oracle"
    got2=$(bash -c 'source "$LIB"; _remote_fingerprint_of "$1"' _ "ssh-ed25519 $oracle_blob")
    assert_eq "…and _remote_fingerprint_of returns the same value" "$got2" "$oracle"
else
    th_skip "the ssh-keygen-free fingerprint agrees with ssh-keygen" \
        "ssh-keygen unusable here — the oracle is unavailable, so equivalence is NOT covered"
    th_skip "…and _remote_fingerprint_of returns the same value" \
        "ssh-keygen unusable here — the oracle is unavailable, so equivalence is NOT covered"
fi

# ── 6c. A FINGERPRINT WE CANNOT COMPUTE MUST BE `?`, NEVER A NUMBER ─────
# sk-sshhealth F2: the first draft of `_remote_fingerprint_sha256` piped an
# unchecked `base64 -d` into the digest, so a blob the decoder REJECTED yielded
# the hash of the empty stream at rc 0 — a well-formed, confident, WRONG
# fingerprint, identical for every unparseable input. That is this suite's own
# subject matter (a comparison of two unknowns reported as an identification)
# reproduced inside the fix for it, sitting in the operator-facing string a
# human reads before deciding whether to run a destructive remedy.
#
# It could not move a verdict — the verdict compares BLOBS — which is exactly
# why it would have survived every other assertion in this file.
echo "== 6c. an unparseable blob yields NO fingerprint, not the empty-string hash =="
EMPTY_SHA256='SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU'   # sha256 of ""
for bad in '!!!not-base64!!!' 'AAAA BBBB'; do
    bad_out=$(bash -c 'source "$LIB"; _remote_fingerprint_sha256 "$1" || printf REFUSED' _ "$bad")
    assert_eq "a blob base64 rejects is REFUSED: ${bad}" "$bad_out" "REFUSED"
done
# Named explicitly, because this exact string is what the defect produced and a
# regression would reintroduce it rather than some arbitrary wrong value.
allbad=$(bash -c 'source "$LIB"; _remote_fingerprint_sha256 "$1" || true' _ '!!!not-base64!!!')
assert_not_contains "…and never the SHA-256 of the empty stream" "$allbad" "$EMPTY_SHA256"
# The PARTIAL-decode half: 'AAAA BBBB' decodes 3 bytes and THEN errors, so an
# emptiness test alone waves it through and it collides with plain 'AAAA'.
# Both halves of the guard are therefore load-bearing.
part=$(bash -c 'source "$LIB"; _remote_fingerprint_sha256 "$1" || printf REFUSED' _ 'AAAA BBBB')
whole=$(bash -c 'source "$LIB"; _remote_fingerprint_sha256 "$1" || printf REFUSED' _ 'AAAA')
assert_not_contains "a partial decode never collides with a clean one" "$part" "$whole"
# CONTROL: the guard rejects malformed input WITHOUT rejecting valid input —
# otherwise "refuses everything" would satisfy every assertion above.
read -r _ our_blob_only _ <<<"$OUR_BLOB"
good=$(bash -c 'source "$LIB"; _remote_fingerprint_sha256 "$1" || printf REFUSED' _ "$our_blob_only")
assert_contains "CONTROL: a well-formed blob still fingerprints" "$good" "SHA256:"

# ── 7. COST ON THE HEALTHY PATH ─────────────────────────────────────────
# #431/#434 reduced the banner probe to ONE connect per attempt because sshd
# runs with MaxStartups=3. A potency check that ran unconditionally, or that
# opened a socket, would undo that. It is local, network-free, and reached only
# after classification failed — so a VERIFIED endpoint never invokes it.
echo "== 7. the potency check costs the verified path nothing =="
cat >"$WORK/ssh-counting" <<'EOF'
#!/usr/bin/env bash
_is_probe=0
for a in "$@"; do case "$a" in UserKnownHostsFile=*) _is_probe=1 ;; esac; done
if (( _is_probe )); then
    echo probe >> "$SSH_CALL_LOG"
    echo 'operator@host: Permission denied (publickey).' >&2
    exit 255
fi
echo potency >> "$SSH_CALL_LOG"
exit 0
EOF
chmod +x "$WORK/ssh-counting"
: > "$WORK/calls.log"
vrc=$(SSH_CALL_LOG="$WORK/calls.log" REMOTE_SSH_BIN="$WORK/ssh-counting" bash -c '
    source "$LIB"; _remote_verify_live_host_key 198.51.100.7 22100 2; printf "%s" "$?"
' _)
assert_eq "the verified path still returns 0" "$vrc" "0"
assert_eq "…having made exactly ONE probe invocation" \
    "$(grep -c '^probe$' "$WORK/calls.log")" "1"
assert_eq "…and ZERO potency invocations" \
    "$(grep -c '^potency$' "$WORK/calls.log")" "0"

# On the FAILING path the potency check does run — otherwise case 1 could pass
# for the wrong reason (e.g. an implementation that special-cased the wording
# after all). This asserts the mechanism was actually exercised.
: > "$WORK/calls.log"
SSH_CALL_LOG="$WORK/calls.log" REMOTE_SSH_BIN="$NOUSER" bash -c '
    source "$LIB"; _remote_verify_live_host_key 198.51.100.7 22100 2
' _ >/dev/null 2>&1
# $NOUSER does not write the log, so count invocations of the counting stub in
# a broken-instrument configuration instead.
cat >"$WORK/ssh-counting-broken" <<'EOF'
#!/usr/bin/env bash
_is_probe=0
for a in "$@"; do case "$a" in UserKnownHostsFile=*) _is_probe=1 ;; esac; done
(( _is_probe )) && echo probe >> "$SSH_CALL_LOG" || echo potency >> "$SSH_CALL_LOG"
echo 'No user exists for uid 71780' >&2
exit 255
EOF
chmod +x "$WORK/ssh-counting-broken"
: > "$WORK/calls.log"
SSH_CALL_LOG="$WORK/calls.log" REMOTE_SSH_BIN="$WORK/ssh-counting-broken" bash -c '
    source "$LIB"; _remote_verify_live_host_key 198.51.100.7 22100 2
' _ >/dev/null 2>&1
assert_eq "the failing path DOES run the potency control" \
    "$(( $(grep -c '^potency$' "$WORK/calls.log") >= 1 ? 1 : 0 ))" "1"

# ── EXPECTED-COUNT GUARD ────────────────────────────────────────────────
# Required at the `count=exact` protection level (your-org/nexus-code#807).
# This suite is unusually exposed to a silently-skipped case: every assertion
# reads a value produced by a `bash -c` subshell, so a stub that failed to
# become executable would yield an empty string and a plausible-looking FAIL —
# or, worse, a case that stopped running would shrink the total and still print
# the pass banner.
#   6  case 1  — fixture wording, presence, rc, three detail assertions
# + 3  case 2  — the #609 F9 negative control
# + 2  case 3  — wording independence
# + 1  case 3b — no false green from a broken instrument
# + 6  case 4  — ours / forgery / mismatch / squatter / refused / absent
# + 4  case 5  — probe rc, verdict, two reason assertions
# + 3  case 6  — byte-identical stated, a real fingerprint, never possession
# + 2  case 6b — fingerprint fallback vs the ssh-keygen oracle (or 2 SKIPs)
# + 5  case 6c — 2 refusals, no empty-stream hash, no partial collision, control
# + 4  case 7  — verified rc, one probe, zero potency, potency on the failing path
#
# SKIP counts toward the total. Case 6b is the only case that can decline, and
# it declines LOUDLY (th_skip prints the reason and the banner says NOT
# covered); folding it in keeps the guard from reading a legitimate skip as a
# vanished assertion, while a case that silently stopped running still trips it.
EXPECTED=$(( 6 + 3 + 2 + 1 + 6 + 4 + 3 + 2 + 5 + 4 ))
if (( PASS + FAIL + SKIP != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL + SKIP ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
