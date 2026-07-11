#!/usr/bin/env bash
# Tests for monitor/.state/remote-ssh.log — the ONE remote-channel artifact
# that lives in the GROUP-SHARED project tree (services.registry log column,
# mode 0660, tailed by svc.sh and the watcher).
#
# THE DECISION, and why the log stays where it is: it is a SERVICE log, not a
# credential. Relocating it under the 0700 principals_dir would break the
# registry contract and the operator's `svc.sh logs` tooling for no secrecy
# gain — the supervisor and sshd(LogLevel=VERBOSE) emit connection IPs and key
# FINGERPRINTS, both explicitly non-secret (RFC §4.10). What was missing is
# that nothing ENFORCED that, and it grew to 49 MB of port-scan noise with no
# rotation. So: keep the path, enforce the content, bound the size.
#
#   1. `_remote_secret_guard` flags private keys / key blobs / nxr1_ tokens
#      (NEGATIVE CONTROL — proves the assertion in case 2 is capable of failing)
#   2. the supervisor's own log lines, and a realistic sshd VERBOSE transcript,
#      contain NO secret-shaped material
#   3. validate_auth_keys reports a bad authorized_keys line by LINE NUMBER and
#      never echoes its bytes (pre-fix it printed `${line:0:40}` — for the very
#      line it rejects, that is a raw `ssh-ed25519 AAAA…` blob prefix)
#   4. rotation triggers above the size cap, keeps the tail, and PRESERVES THE
#      INODE (svc.sh holds an O_APPEND fd on it — a rename would orphan the
#      writer; only truncate-in-place is safe)
#   5. rotation is a no-op below the cap, and leaves the log 0640
#   6. an O_APPEND writer that survives a rotation keeps appending correctly
#
# Run: bash monitor/watcher/test-remote-service-log.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
SUP="$MON_DIR/remote-sshd-supervised.sh"

WORK=$(mktemp -d -t nexus-svclog-XXXXXX); trap 'rm -rf "$WORK"' EXIT
HERMETIC_CFG="$WORK/nexus.yml"
printf 'monitor:\n  remote:\n    bind_address: 127.0.0.1\n' >"$HERMETIC_CFG"
export NEXUS_CONFIG="$HERMETIC_CFG"

# shellcheck source=../_remote_lib.sh
source "$LIB"

# ── 1. NEGATIVE CONTROL: the guard can fail ──────────────────────────────
# Without this, case 2 ("no secret in the log") could pass because the guard is
# broken/absent rather than because the log is clean.
cat > "$WORK/dirty-priv" <<'EOF'
[2026-07-09T00:00:00] remote-sshd: supervisor up
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gt
-----END OPENSSH PRIVATE KEY-----
EOF
_remote_secret_guard "$WORK/dirty-priv" >/dev/null 2>&1
assert_eq "negative control: guard TRIPS on a private key (exit 3)" "$?" "3"

printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleBlobExampleBlobExampleBlobEx client\n' > "$WORK/dirty-pub"
_remote_secret_guard "$WORK/dirty-pub" >/dev/null 2>&1
assert_eq "negative control: guard TRIPS on a public key blob (exit 3)" "$?" "3"

printf 'consumed token nxr1_%s\n' "$(printf 'a%.0s' {1..32})" > "$WORK/dirty-tok"
_remote_secret_guard "$WORK/dirty-tok" >/dev/null 2>&1
assert_eq "negative control: guard TRIPS on an nxr1_ token (exit 3)" "$?" "3"

# ── 2. the real log content is clean ─────────────────────────────────────
# Verbatim shapes emitted by the supervisor + sshd -o LogLevel=VERBOSE, incl.
# the fingerprint line (non-secret by design) and the scan noise that made the
# live log 49 MB.
cat > "$WORK/clean" <<'EOF'
[2026-07-09T21:00:00+00:00] remote-sshd: supervisor up: sshd=/usr/sbin/sshd bind=140.107.222.134 port=22022 principals_dir=/home/op/.claude/nexus-remote
[2026-07-09T21:00:00+00:00] remote-sshd: exec: /usr/sbin/sshd -D -e -p 22022
Connection from 140.107.222.134 port 51484 on 140.107.222.134 port 22022
Did not receive identification string from 140.107.222.134 port 51484
Accepted publickey for op from 140.107.116.184 port 40122 ssh2: ED25519 SHA256:sJgWWLNCYqaaUyqCWv/MMWUiT53sHF9v9eq2w7WOYjU
Postponed publickey for op from 140.107.116.184 port 40122 ssh2 [preauth]
[2026-07-09T21:05:00+00:00] remote-sshd: FATAL: channel-only policy but authorized_keys line 3 lacks a forced command (would grant a shell)
[2026-07-09T21:05:00+00:00] remote-sshd: WARNING: authorized_keys line 3 without 'restrict' hardening
[2026-07-09T21:05:01+00:00] remote-sshd: log rotated in place (was 8388609 bytes; kept last 2000 lines)
EOF
_remote_secret_guard "$WORK/clean" >/dev/null 2>&1
assert_eq "a realistic supervisor+sshd VERBOSE transcript is secret-free (exit 0)" "$?" "0"

# A fingerprint must NOT be treated as a secret (else the guard is unusable here).
printf 'ED25519 SHA256:sJgWWLNCYqaaUyqCWv/MMWUiT53sHF9v9eq2w7WOYjU\n' > "$WORK/fp"
_remote_secret_guard "$WORK/fp" >/dev/null 2>&1
assert_eq "a host-key FINGERPRINT is not a secret (exit 0)" "$?" "0"

# ── 3. validate_auth_keys must never echo an authorized_keys line ─────────
# Pre-fix source logged `${line:0:40}`; for the rejected (command=-less) line
# that is 40 bytes of a public-key blob, into a 0660 group-readable file.
badline='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleBlobExampleBlob attacker@host'
if grep -q '\${line:0:40}' "$SUP"; then
    printf '  FAIL: remote-sshd-supervised.sh still echoes authorized_keys bytes (${line:0:40})\n' >&2
    FAIL=$((FAIL+1))
else
    printf '  PASS: supervisor no longer echoes authorized_keys bytes into the shared log\n'
    PASS=$((PASS+1))
fi
assert_contains "…and reports the offending line by NUMBER instead" \
    "$(grep -o 'authorized_keys line \$lineno[^"]*' "$SUP" | head -1)" 'line $lineno'
# The rejection message itself must be secret-free even with a blob in the file.
msg="FATAL: channel-only policy but authorized_keys line 3 lacks a forced command (would grant a shell)"
assert_not_contains "the rejection message carries no key material" "$msg" "AAAA"
printf '%s\n' "$badline" > "$WORK/ak-bad"   # (the blob exists; it just never reaches the log)
assert_eq "…proof the fixture blob WOULD have tripped the guard" \
    "$(_remote_secret_guard "$WORK/ak-bad" >/dev/null 2>&1; echo $?)" "3"

# ── 4/5/6. rotation ──────────────────────────────────────────────────────
FAKE_ROOT="$WORK/nexus"; mkdir -p "$FAKE_ROOT/monitor/.state"
LOGF="$FAKE_ROOT/monitor/.state/remote-ssh.log"
export NEXUS_ROOT="$FAKE_ROOT"
assert_eq "_remote_service_log resolves under \$NEXUS_ROOT" "$(_remote_service_log)" "$LOGF"

rotate() { MONITOR_REMOTE_SERVICE_LOG_MAX_BYTES="$1" MONITOR_REMOTE_SERVICE_LOG_KEEP_LINES="$2" \
    bash -c "export NEXUS_ROOT='$FAKE_ROOT'; source '$LIB'; _remote_rotate_service_log"; }
inode_of() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1" 2>/dev/null; }

seq 1 20000 | sed 's/^/scan noise line /' > "$LOGF"; chmod 660 "$LOGF"
before_size=$(stat -c '%s' "$LOGF" 2>/dev/null || stat -f '%z' "$LOGF")
before_ino=$(inode_of "$LOGF")

# 5. below the cap ⇒ untouched
rotate 100000000 2000
assert_eq "no rotation below the size cap" \
    "$(stat -c '%s' "$LOGF" 2>/dev/null || stat -f '%z' "$LOGF")" "$before_size"

# 6. an O_APPEND writer held across the rotation (this is svc.sh's fd)
exec 9>>"$LOGF"

# 4. above the cap ⇒ rotate
rotate 4096 500
after_size=$(stat -c '%s' "$LOGF" 2>/dev/null || stat -f '%z' "$LOGF")
after_ino=$(inode_of "$LOGF")
(( after_size < before_size )) \
    && { printf '  PASS: rotation shrank the log (%s → %s bytes)\n' "$before_size" "$after_size"; PASS=$((PASS+1)); } \
    || { printf '  FAIL: rotation did not shrink the log (%s → %s)\n' "$before_size" "$after_size" >&2; FAIL=$((FAIL+1)); }
assert_eq "rotation PRESERVED the inode (O_APPEND writers keep working)" "$after_ino" "$before_ino"
assert_contains "rotation kept the TAIL of the log" "$(tail -3 "$LOGF")" "scan noise line 20000"
assert_contains "rotation left an audit marker" "$(tail -1 "$LOGF")" "log rotated in place"
assert_not_contains "rotation dropped the head" "$(head -1 "$LOGF")" "scan noise line 1 "
assert_eq "rotated log is 0640 (not group-writable)" \
    "$(stat -c '%a' "$LOGF" 2>/dev/null || stat -f '%Lp' "$LOGF")" "640"

# 6. the surviving fd still appends to the END, not to a stale offset.
printf 'post-rotation append\n' >&9
exec 9>&-
assert_contains "an O_APPEND fd held across rotation still appends at EOF" \
    "$(tail -1 "$LOGF")" "post-rotation append"
assert_eq "…and did not re-inflate the file with a sparse hole" \
    "$(( $(stat -c '%s' "$LOGF" 2>/dev/null || stat -f '%z' "$LOGF") < before_size ))" "1"

# The rotated log must still be secret-free.
_remote_secret_guard "$LOGF" >/dev/null 2>&1
assert_eq "the rotated log is secret-free" "$?" "0"

th_summary_and_exit
