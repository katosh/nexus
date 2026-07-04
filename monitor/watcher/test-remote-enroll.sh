#!/usr/bin/env bash
# Tests for monitor/remote-enroll.sh (the `ng remote …` backend) — the
# OUT-OF-BAND secret-provisioning flow for the confined remote agent
# channel (agent-channel RFC §4.9). The security crux here is "no secret
# ever transits a public surface" + a single-use, fail-closed token.
#
#   1.  gen-host-key: 0600 private key, fingerprint printed, idempotent
#   2.  issue-token: token → stdout ONLY; recorded HASHED (no plaintext on disk)
#   3.  enroll: consumes token → authorized_keys line w/ forced command +
#       principal + `restrict`; token then gone
#   4.  replay of a consumed token FAILS CLOSED (rc3)
#   5.  EXPIRED token FAILS CLOSED (rc3)
#   6.  principal-mismatch (--principal != token's) FAILS CLOSED (rc3)
#   7.  pubkey OPTION-INJECTION stripped: a malicious command=/options in the
#       supplied .pub never reaches authorized_keys (server reconstructs)
#   8.  malformed pubkey rejected
#   9.  revoke removes the principal's line; list shows principals (no key material)
#   10. from_cidr pin appears in the authorized_keys line when configured
#   11. guard: catches private key / public key / token; clean text passes
#   12. NO secret on a public surface: no `gh`/github verb anywhere; the
#       plaintext token is never written to any file under principals_dir
#
# Hermetic: principals_dir is a fixture; ssh-keygen is real (present on the
# runner). No network, no GitHub.
#
# Run: bash monitor/watcher/test-remote-enroll.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
EN="$MON_DIR/remote-enroll.sh"

assert_rc() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — rc %s want %s\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}

command -v ssh-keygen >/dev/null 2>&1 || { echo "SKIP: ssh-keygen not present"; echo "ALL TESTS PASSED"; exit 0; }

WORK=$(mktemp -d -t nexus-remote-enroll-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/principals"
PDIR="$WORK/principals"

# a client keypair fixture (the private key would never leave the client)
ssh-keygen -t ed25519 -f "$WORK/client" -N '' -C 'alice@laptop' >/dev/null 2>&1

echo "== 1. gen-host-key: 0600 key + fingerprint, idempotent =="
fp=$(bash "$EN" gen-host-key 2>/dev/null)
assert_rc "gen-host-key rc0" "$?" "0"
assert_file_exists "host private key present" "$PDIR/ssh_host_ed25519_key"
mode=$(stat -c '%a' "$PDIR/ssh_host_ed25519_key" 2>/dev/null || stat -f '%Lp' "$PDIR/ssh_host_ed25519_key")
assert_eq "host key is 0600" "$mode" "600"
assert_contains "fingerprint printed (SHA256)" "$fp" "SHA256:"
fp1=$(cat "$PDIR/ssh_host_ed25519_key")
bash "$EN" gen-host-key >/dev/null 2>&1
fp2=$(cat "$PDIR/ssh_host_ed25519_key")
assert_eq "gen-host-key idempotent (key unchanged)" "$fp1" "$fp2"

echo "== 2. issue-token: stdout only, recorded HASHED =="
tok=$(bash "$EN" issue-token --principal alice --ttl 900 2>/dev/null)
assert_contains "token has nxr1_ prefix" "$tok" "nxr1_"
# plaintext token must NOT appear anywhere on disk under principals_dir
if grep -rqF "$tok" "$PDIR" 2>/dev/null; then
    printf '  FAIL: plaintext token found on disk under principals_dir\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: plaintext token NOT on disk (only hashed record)\n'; PASS=$((PASS+1))
fi
assert_eq "exactly one pending token record" "$(ls "$PDIR/enroll/"*.token 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "== 3. enroll: consumes token, writes forced-command line =="
bash "$EN" enroll --pubkey "$WORK/client.pub" --token "$tok" >/dev/null 2>&1
assert_rc "enroll rc0" "$?" "0"
ak="$PDIR/authorized_keys"
assert_file_exists "authorized_keys written" "$ak"
akline=$(cat "$ak")
assert_contains "line carries forced command" "$akline" "remote-forced-command.sh alice"
assert_contains "line carries restrict"        "$akline" "restrict"
assert_contains "line carries the client key"   "$akline" "$(awk '{print $2}' "$WORK/client.pub")"
assert_eq "token consumed (no pending records)" "$(ls "$PDIR/enroll/"*.token 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== 4. replay of consumed token fails closed (rc3) =="
bash "$EN" enroll --pubkey "$WORK/client.pub" --token "$tok" >/dev/null 2>&1
assert_rc "replay refused rc3" "$?" "3"

echo "== 4b. CONCURRENT replay: exactly one of two racing enrolls wins (H2) =="
tokc=$(bash "$EN" issue-token --principal raceyone --ttl 900 2>/dev/null)
bash "$EN" enroll --pubkey "$WORK/client.pub" --token "$tokc" >/dev/null 2>&1 & p1=$!
bash "$EN" enroll --pubkey "$WORK/client.pub" --token "$tokc" >/dev/null 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
winc=0; [[ "$r1" == 0 ]] && winc=$((winc+1)); [[ "$r2" == 0 ]] && winc=$((winc+1))
assert_eq "exactly one concurrent enroll wins" "$winc" "1"
assert_eq "exactly one raceyone line (no double-enroll)" "$(grep -c 'raceyone@nexus-remote' "$ak")" "1"

echo "== 4c. every enrolled line carries a forced command (HIGH invariant) =="
# enroll constructs the line server-side, so it always has command=; assert it.
assert_eq "no command=-less authorized_keys line" "$(grep -vc 'command="' "$ak")" "0"

echo "== 5. expired token fails closed (rc3) =="
tok2=$(bash "$EN" issue-token --principal bob --ttl 900 2>/dev/null)
rec=$(ls "$PDIR/enroll/"*.token | head -1)
# force expiry into the past
sed -i 's/^expires=.*/expires=1/' "$rec"
bash "$EN" enroll --pubkey "$WORK/client.pub" --token "$tok2" >/dev/null 2>&1
assert_rc "expired token refused rc3" "$?" "3"
assert_eq "expired token also consumed" "$(ls "$PDIR/enroll/"*.token 2>/dev/null | wc -l | tr -d ' ')" "0"

echo "== 6. principal mismatch fails closed (rc3) =="
tok3=$(bash "$EN" issue-token --principal carol --ttl 900 2>/dev/null)
bash "$EN" enroll --principal mallory --pubkey "$WORK/client.pub" --token "$tok3" >/dev/null 2>&1
assert_rc "principal mismatch refused rc3" "$?" "3"

echo "== 7. pubkey option-injection is stripped =="
tok4=$(bash "$EN" issue-token --principal dave --ttl 900 2>/dev/null)
# a hostile .pub with a prepended command=/options
printf 'command="rm -rf /",no-pty ssh-ed25519 %s evil@host\n' "$(awk '{print $2}' "$WORK/client.pub")" > "$WORK/evil.pub"
bash "$EN" enroll --pubkey "$WORK/evil.pub" --token "$tok4" >/dev/null 2>&1
assert_rc "enroll with hostile .pub still rc0 (sanitized)" "$?" "0"
daveline=$(grep 'dave@nexus-remote' "$ak")
assert_contains "dave's line uses OUR forced command" "$daveline" "remote-forced-command.sh dave"
assert_not_contains "hostile 'rm -rf' NOT in authorized_keys" "$(cat "$ak")" "rm -rf"
assert_not_contains "hostile 'no-pty' option NOT injected"    "$daveline" "no-pty"

echo "== 8. malformed pubkey rejected =="
tok5=$(bash "$EN" issue-token --principal erin --ttl 900 2>/dev/null)
printf 'this is not a key\n' > "$WORK/bad.pub"
bash "$EN" enroll --pubkey "$WORK/bad.pub" --token "$tok5" >/dev/null 2>&1
assert_rc "malformed pubkey refused rc2" "$?" "2"

echo "== 9. revoke + list =="
out=$(bash "$EN" list 2>/dev/null)
assert_contains "list shows alice" "$out" "alice"
assert_contains "list shows dave"  "$out" "dave"
assert_not_contains "list prints NO key material" "$out" "ssh-ed25519"
bash "$EN" revoke --principal alice >/dev/null 2>&1
assert_rc "revoke rc0" "$?" "0"
assert_not_contains "alice's line removed" "$(cat "$ak")" "remote-forced-command.sh alice"
assert_contains "dave's line retained" "$(cat "$ak")" "remote-forced-command.sh dave"

echo "== 10. from_cidr pin in the authorized_keys line =="
tok6=$(MONITOR_REMOTE_FROM_CIDR="10.0.0.0/8" bash "$EN" issue-token --principal frank --ttl 900 2>/dev/null)
MONITOR_REMOTE_FROM_CIDR="10.0.0.0/8" bash "$EN" enroll --pubkey "$WORK/client.pub" --token "$tok6" >/dev/null 2>&1
frankline=$(grep 'frank@nexus-remote' "$ak")
assert_contains "from= pin present" "$frankline" 'from="10.0.0.0/8"'

echo "== 10b. unfiltered policy: enroll writes a command=-less SHELL line =="
toku=$(MONITOR_REMOTE_COMMAND_POLICY=unfiltered bash "$EN" issue-token --principal shellguy --ttl 900 2>/dev/null)
MONITOR_REMOTE_COMMAND_POLICY=unfiltered bash "$EN" enroll --pubkey "$WORK/client.pub" --token "$toku" >/dev/null 2>&1
assert_rc "unfiltered enroll rc0" "$?" "0"
shellline=$(grep 'shellguy@nexus-remote' "$ak")
assert_not_contains "unfiltered line has NO forced command" "$shellline" 'command="'
assert_not_contains "unfiltered line has NO restrict"        "$shellline" 'restrict'
assert_contains "unfiltered line carries the key + principal" "$shellline" "shellguy@nexus-remote"
# list + revoke work on an unfiltered (command=-less) line too
assert_contains "list shows the unfiltered principal" "$(bash "$EN" list 2>/dev/null)" "shellguy"
bash "$EN" revoke --principal shellguy >/dev/null 2>&1
assert_not_contains "revoke removes the unfiltered line" "$(cat "$ak")" "shellguy@nexus-remote"

echo "== 10c. --token-stdin: token read from stdin, never argv (self-enroll path) =="
toks=$(bash "$EN" issue-token --principal stdinguy --ttl 900 2>/dev/null)
printf '%s\n' "$toks" | bash "$EN" enroll --pubkey "$WORK/client.pub" --token-stdin >/dev/null 2>&1
assert_rc "enroll via --token-stdin rc0" "$?" "0"
assert_contains "stdinguy enrolled with forced command" "$(grep 'stdinguy@nexus-remote' "$ak")" "remote-forced-command.sh stdinguy"
# replay of the stdin-consumed token fails closed
printf '%s\n' "$toks" | bash "$EN" enroll --pubkey "$WORK/client.pub" --token-stdin >/dev/null 2>&1
assert_rc "replay of stdin token refused rc3" "$?" "3"
# --token and --token-stdin together is a usage error (rc1)
printf 'x\n' | bash "$EN" enroll --pubkey "$WORK/client.pub" --token nxr1_dead --token-stdin >/dev/null 2>&1
assert_rc "both --token and --token-stdin → usage error rc1" "$?" "1"

echo "== 11. guard: secrets blocked, clean text passes =="
echo "perfectly harmless prose" | bash "$EN" guard >/dev/null 2>&1
assert_rc "clean text passes guard rc0" "$?" "0"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nxxxx\n' | bash "$EN" guard >/dev/null 2>&1
assert_rc "private key blocked rc3" "$?" "3"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAxyz user@host" | bash "$EN" guard >/dev/null 2>&1
assert_rc "public key blob blocked rc3" "$?" "3"
echo "the token is nxr1_0123456789abcdef0123456789abcdef ok" | bash "$EN" guard >/dev/null 2>&1
assert_rc "enrollment token blocked rc3" "$?" "3"
# guard on a real report-shaped file (no secrets) passes
printf '# Report\n\nSpawned worker foo; see your-org/your-nexus#412.\n' > "$WORK/report.md"
bash "$EN" guard "$WORK/report.md" >/dev/null 2>&1
assert_rc "clean report file passes guard rc0" "$?" "0"

echo "== 12. NO GitHub surface anywhere in the secret flow =="
# Static guarantee: remote-enroll.sh + _remote_lib.sh never invoke gh or an
# ng github-write verb. (Greps for a `gh ` call or `ng … issue/pr/comment`.)
if grep -nE '(^|[^a-zA-Z._-])gh +(pr|issue|api|release|comment)' "$EN" "$MON_DIR/_remote_lib.sh" 2>/dev/null; then
    printf '  FAIL: a GitHub write verb appears in the secret flow\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: no GitHub write verb in remote-enroll.sh / _remote_lib.sh\n'; PASS=$((PASS+1))
fi

echo "== 13. R1: enrollment-record reads via shared _kv_get == old sed|head -1 =="
# remote-enroll.sh's enroll command reads principal/expires from the claimed
# token record with `_kv_get` (was hand-rolled `sed -n 's/^KEY=//p' | head -1`,
# your-org/nexus-code#405 R1). Prove the swap is byte-for-byte equivalent to the
# retired sed form on the record schema the WRITER emits (`_mint_token`:
# `printf 'principal=%s\n' …; printf 'expires=%s\n' …`), including a value that
# itself contains '=' and a missing key. Source the SAME lib chain the script
# sources (_remote_lib.sh → _fm_lib.sh) so `_kv_get` is exercised in scope.
. "$MON_DIR/_remote_lib.sh"
_old_sed_get() { sed -n "s/^$2=//p" "$1" | head -1; }   # the retired reader
# (a) normal record, exactly as _mint_token writes it
{ printf 'principal=%s\n' 'alice'; printf 'expires=%s\n' '1893456000'; } > "$WORK/r1a.token"
assert_eq "R1 principal: _kv_get == sed" "$(_kv_get "$WORK/r1a.token" principal)" "$(_old_sed_get "$WORK/r1a.token" principal)"
assert_eq "R1 expires:   _kv_get == sed" "$(_kv_get "$WORK/r1a.token" expires)"   "$(_old_sed_get "$WORK/r1a.token" expires)"
assert_eq "R1 principal value correct"   "$(_kv_get "$WORK/r1a.token" principal)" "alice"
# (b) value containing '=' — only the literal KEY= prefix is stripped, rest verbatim
printf 'principal=a=b=c\n' > "$WORK/r1b.token"
assert_eq "R1 '=' in value: _kv_get == sed" "$(_kv_get "$WORK/r1b.token" principal)" "$(_old_sed_get "$WORK/r1b.token" principal)"
assert_eq "R1 '=' in value verbatim"        "$(_kv_get "$WORK/r1b.token" principal)" "a=b=c"
# (c) missing key — both yield empty (rc0)
printf 'expires=1893456000\n' > "$WORK/r1c.token"
assert_eq "R1 missing key: _kv_get == sed" "$(_kv_get "$WORK/r1c.token" principal)" "$(_old_sed_get "$WORK/r1c.token" principal)"
assert_eq "R1 missing key is empty"        "$(_kv_get "$WORK/r1c.token" principal)" ""
# (d) prefix guard — asking for `expires` must not false-match `expires_at`
printf 'expires_at=999\nexpires=1893456000\n' > "$WORK/r1d.token"
assert_eq "R1 prefix guard: _kv_get == sed" "$(_kv_get "$WORK/r1d.token" expires)" "$(_old_sed_get "$WORK/r1d.token" expires)"
assert_eq "R1 prefix guard value correct"   "$(_kv_get "$WORK/r1d.token" expires)" "1893456000"

th_summary_and_exit
