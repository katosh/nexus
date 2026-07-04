#!/usr/bin/env bash
# Tests for ROOTLESS token-gated SELF-ENROLLMENT over SSH (agent-channel RFC
# Part A §4.9.1). An in-sandbox sshd is NON-root and CANNOT use
# AuthorizedKeysCommand (OpenSSH's auth_secure_path requires the command owned
# by uid 0, and the sandbox userns has no uid-0-owned files — real root maps to
# `nobody`). So self-enroll rides AuthorizedKeysFile via a per-window ENROLL-ONLY
# key:
#   * `ng remote enroll-invite`  mints a one-time token + a THROWAWAY enroll
#     keypair and installs a token-hash-tagged enroll-only authorized_keys line;
#     prints {token, enroll PRIVATE key} to stdout (out-of-band).
#   * remote-enroll-session.sh (the enroll line's forced command) reads
#     <token>\n<client-pubkey> from stdin, token-gates, server-reconstructs the
#     permanent channel-only line for the CLIENT key, then prunes the enroll line.
#   * remote-sshd-supervised.sh prunes stale enroll lines on token expiry.
#
# The security crux (red-team must-gets):
#   * enroll-invite installs the enroll-ONLY line (forced command = the enroll
#     session, NEVER the channel wrapper) + restrict [+ from=]; the enroll
#     PRIVATE key is out-of-band ONLY and never persisted at rest.
#   * the enroll session is hermetically enroll-only + fail-closed: token+pubkey
#     from stdin only, token bound to the baked hash, refuses any client command,
#     atomic single-use consume, server-side line reconstruction.
#   * valid → the CLIENT key is enrolled + token consumed + enroll line pruned;
#     replay/expired/mismatched/malformed → rejected, NO key written; smuggled
#     options/commands discarded.
#   * outside a token window there is NO enroll line → an unknown key is DENIED
#     at the SSH layer (the property the impossible AKC pending-token gate gave).
#
# Hermetic: principals_dir + services.registry are fixtures; ssh-keygen is real
# (present on the runner) to mint key fixtures. The default run needs no network,
# no sshd. An OPT-IN live-sshd block (SELFENROLL_LIVE_SSHD=1) proves the root
# cause (sshd refuses the AKC) AND the fix (enroll-key self-enroll) end-to-end.
#
# Run: bash monitor/watcher/test-remote-self-enroll.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
# A non-root-owned executable used ONLY to prove (in the LIVE block) that sshd
# REFUSES an AuthorizedKeysCommand living under a non-uid-0 tree — the root cause
# the rootless self-enroll design works around (see docs/remote-access-akc-note.md,
# formerly the remote-authorized-keys-command.sh tombstone). sshd rejects it on
# ownership BEFORE exec, so any script under this repo tree serves; we reuse one.
AKC_STANDIN="$MON_DIR/remote-enroll-session.sh"
SESSION="$MON_DIR/remote-enroll-session.sh"
EN="$MON_DIR/remote-enroll.sh"
LIB="$MON_DIR/_remote_lib.sh"

assert_rc() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then printf '  PASS: %s\n' "$label"; PASS=$((PASS+1))
    else printf '  FAIL: %s — rc %s want %s\n' "$label" "$got" "$want" >&2; FAIL=$((FAIL+1)); fi
}

command -v ssh-keygen >/dev/null 2>&1 || { echo "SKIP: ssh-keygen not present"; echo "ALL TESTS PASSED"; exit 0; }

WORK=$(mktemp -d -t nexus-remote-selfenroll-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
export MONITOR_REMOTE_PRINCIPALS_DIR="$WORK/principals"
export MONITOR_REMOTE_FROM_CIDR=""    # neutralize config bleed; §9 sets it explicitly
PDIR="$WORK/principals"
AK="$PDIR/authorized_keys"
# Registration IS the enable signal — register the nexus-remote-ssh row.
export NEXUS_SERVICES_REGISTRY="$WORK/services.registry"
printf 'nexus-remote-ssh\t%s\tlaunch\thealth\tlog\temit-only\n' "$WORK" > "$NEXUS_SERVICES_REGISTRY"

# the CLIENT keypair fixture (its private key would never leave the client).
ssh-keygen -t ed25519 -f "$WORK/client"   -N '' -C 'client@laptop'   >/dev/null 2>&1
ssh-keygen -t ed25519 -f "$WORK/attacker" -N '' -C 'attacker@evil'   >/dev/null 2>&1
CPUB=$(cat "$WORK/client.pub")
ABLOB=$(awk '{print $2}' "$WORK/attacker.pub")

# helpers
inv()    { bash "$EN" enroll-invite --principal "$1" --ttl "${2:-900}" 2>/dev/null; }
tokof()  { sed -n 's/^REMOTE_ENROLL_TOKEN=//p' <<<"$1"; }
hashof() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
# run the enroll session: sess <hash> <ssh_original_command> <stdin>
sess()   { local h="$1" soc="${2-}" input="${3-}"; SSH_ORIGINAL_COMMAND="$soc" bash "$SESSION" "$h" <<<"$input"; }
# grep -c prints the count (0 when none) AND exits 1 on no-match; capture the
# number and swallow the exit (never chain `|| echo 0`, which double-appends).
enroll_lines() { local n; n=$(grep -c 'enroll-[0-9a-f]\{64\}@nexus-remote' "$AK" 2>/dev/null); printf '%s' "${n:-0}"; }
pending_count() { ls "$PDIR/enroll/"*.token 2>/dev/null | wc -l | tr -d ' '; }

echo "== 1. enroll-invite installs an enroll-ONLY line + emits token & enroll priv key =="
out=$(inv alice); tok=$(tokof "$out"); H=$(hashof "$tok")
assert_contains "invite prints the one-time token"          "$out" "REMOTE_ENROLL_TOKEN=nxr1_"
assert_contains "invite prints an enroll PRIVATE key block"  "$out" "BEGIN NEXUS ENROLL PRIVATE KEY"
assert_contains "invite prints an openssh private key"       "$out" "BEGIN OPENSSH PRIVATE KEY"
eline=$(grep "enroll-$H@nexus-remote" "$AK")
assert_contains "enroll line forces the enroll session"      "$eline" "remote-enroll-session.sh $H"
assert_contains "enroll line carries restrict"               "$eline" "restrict"
assert_not_contains "enroll line NEVER is the channel wrapper" "$eline" "remote-forced-command.sh"
assert_no_file "enroll private key NOT persisted at rest (.enrollkey.*)" "$PDIR/.enrollkey.KEEP"
if ls "$PDIR"/.enrollkey.* >/dev/null 2>&1; then printf '  FAIL: enroll keypair left at rest\n' >&2; FAIL=$((FAIL+1)); else printf '  PASS: no enroll keypair at rest\n'; PASS=$((PASS+1)); fi

echo "== 2. session: valid token + client pub on stdin → CLIENT key enrolled, consumed, pruned =="
sess "$H" "" "$(printf '%s\n%s' "$tok" "$CPUB")" >/dev/null 2>&1
assert_rc "valid self-enroll rc0" "$?" "0"
assert_file_exists "authorized_keys written" "$AK"
line=$(grep 'alice@nexus-remote' "$AK")
assert_contains "enrolled line uses the CHANNEL forced command" "$line" "remote-forced-command.sh alice"
assert_contains "enrolled line carries restrict"                "$line" "restrict"
assert_contains "enrolled line carries the CLIENT key"          "$line" "$(awk '{print $2}' "$WORK/client.pub")"
assert_eq "token consumed (window closed)" "$(pending_count)" "0"
assert_eq "enroll line pruned after consume" "$(enroll_lines)" "0"

echo "== 3. after consume: NO enroll line (unknown key denied); REPLAY fails closed =="
assert_eq "no enroll line lingers" "$(enroll_lines)" "0"
before=$(grep -c . "$AK")
sess "$H" "" "$(printf '%s\n%s' "$tok" "$CPUB")" >/dev/null 2>&1
assert_rc "replay refused rc3" "$?" "3"
assert_eq "no extra line on replay" "$(grep -c . "$AK")" "$before"

echo "== 4. token/hash mismatch (enroll key bound to its own token) → rc3 =="
o2=$(inv bob); t2=$(tokof "$o2"); H2=$(hashof "$t2")
o3=$(inv carol); t3=$(tokof "$o3"); H3=$(hashof "$t3")
sess "$H2" "" "$(printf '%s\n%s' "$t3" "$CPUB")" >/dev/null 2>&1   # carol's token at bob's hash
assert_rc "mismatched token refused rc3" "$?" "3"
assert_eq "bob's token NOT consumed by a mismatch" "$(ls "$PDIR/enroll/$H2.token" 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "== 5. client command on the enroll endpoint → rc12, nothing enrolled =="
sess "$H2" "request file --slug x --message y" "$(printf '%s\n%s' "$t2" "$CPUB")" >/dev/null 2>&1
assert_rc "client command → rc12" "$?" "12"
assert_not_contains "bob NOT enrolled by a command attempt" "$(cat "$AK")" "bob@nexus-remote"

echo "== 6. malformed / empty client pubkey on stdin → rc3, token NOT burned =="
sess "$H2" "" "$(printf '%s\n%s' "$t2" 'not-a-key')" >/dev/null 2>&1
assert_rc "garbage client pubkey → rc3" "$?" "3"
sess "$H2" "" "$t2" >/dev/null 2>&1   # only a token, no pubkey line
assert_rc "missing client pubkey → rc3" "$?" "3"
assert_eq "bob's token SURVIVED malformed attempts (not burned)" "$(ls "$PDIR/enroll/$H2.token" 2>/dev/null | wc -l | tr -d ' ')" "1"
sess "$H2" "" "$(printf '%s\n%s' "$t2" "$CPUB")" >/dev/null 2>&1
assert_rc "bob valid enroll AFTER malformed attempts rc0" "$?" "0"

echo "== 7. EXPIRED token → session rc3; prune-enroll removes the expired line =="
o4=$(inv dave 900); t4=$(tokof "$o4"); H4=$(hashof "$t4")
rec="$PDIR/enroll/$H4.token"; sed -i 's/^expires=.*/expires=1/' "$rec"
sess "$H4" "" "$(printf '%s\n%s' "$t4" "$CPUB")" >/dev/null 2>&1
assert_rc "expired token refused rc3" "$?" "3"
assert_not_contains "dave never enrolled" "$(cat "$AK")" "dave@nexus-remote"
bash "$EN" prune-enroll >/dev/null 2>&1
assert_eq "expired enroll line pruned" "$(grep -c "enroll-$H4" "$AK" 2>/dev/null; true)" "0"

echo "== 8. SMUGGLED options in the client pubkey are stripped (server reconstruction) =="
o5=$(inv erin); t5=$(tokof "$o5"); H5=$(hashof "$t5")
CBLOB=$(awk '{print $2}' "$WORK/client.pub")
# valid type+blob, then hostile trailing tokens the client hopes land as options
sess "$H5" "" "$(printf '%s\n%s' "$t5" "ssh-ed25519 $CBLOB evil\",command=\"rm -rf /\"")" >/dev/null 2>&1
assert_rc "smuggled-options enroll still rc0 (blob is valid)" "$?" "0"
eline5=$(grep 'erin@nexus-remote' "$AK")
assert_contains "erin enrolled with the channel wrapper" "$eline5" "remote-forced-command.sh erin"
assert_not_contains "no smuggled rm -rf in erin's line"  "$eline5" "rm -rf"

echo "== 9. from= pin propagates to BOTH the enroll line AND the channel line =="
o6=$(MONITOR_REMOTE_FROM_CIDR="10.1.2.0/24" inv frank); t6=$(tokof "$o6"); H6=$(hashof "$t6")
eline6=$(grep "enroll-$H6@nexus-remote" "$AK")
assert_contains "from= present in the enroll line" "$eline6" 'from="10.1.2.0/24"'
MONITOR_REMOTE_FROM_CIDR="10.1.2.0/24" sess "$H6" "" "$(printf '%s\n%s' "$t6" "$CPUB")" >/dev/null 2>&1
assert_rc "frank enroll rc0" "$?" "0"
assert_contains "from= present in frank's channel line" "$(grep 'frank@nexus-remote' "$AK")" 'from="10.1.2.0/24"'

echo "== 10. enroll-invite respects self_enroll=false (manual-only) =="
MONITOR_REMOTE_SELF_ENROLL=false bash "$EN" enroll-invite --principal grace >/dev/null 2>&1
assert_rc "self_enroll=false → enroll-invite refused (rc1)" "$?" "1"
assert_not_contains "grace not enrolled/invited" "$(cat "$AK")" "grace"

echo "== 11. enroll session: not-registered fails closed (rc10) =="
o7=$(inv heidi); t7=$(tokof "$o7"); H7=$(hashof "$t7")
NEXUS_SERVICES_REGISTRY="$WORK/none.registry" sess "$H7" "" "$(printf '%s\n%s' "$t7" "$CPUB")" >/dev/null 2>&1
assert_rc "not registered → rc10" "$?" "10"
bash "$EN" prune-enroll >/dev/null 2>&1 || true

echo "== 12. _remote_token_hash_live reflects live/expired/consumed =="
o8=$(inv ivan); t8=$(tokof "$o8"); H8=$(hashof "$t8")
( source "$LIB"; _remote_token_hash_live "$H8" ); assert_rc "live token → 0" "$?" "0"
sed -i 's/^expires=.*/expires=1/' "$PDIR/enroll/$H8.token"
( source "$LIB"; _remote_token_hash_live "$H8" ); assert_rc "expired token → 1" "$?" "1"
( source "$LIB"; _remote_token_hash_live "deadbeef" ); assert_rc "bad-hash → 1" "$?" "1"
bash "$EN" prune-enroll >/dev/null 2>&1 || true

echo "== 13. no GitHub surface + no plaintext secret persisted =="
if grep -nE '(^|[^a-zA-Z._-])gh +(pr|issue|api|release|comment)' "$SESSION" "$EN" 2>/dev/null; then
    printf '  FAIL: a GitHub write verb appears in the self-enroll path\n' >&2; FAIL=$((FAIL+1))
else
    printf '  PASS: no GitHub write verb in the self-enroll scripts\n'; PASS=$((PASS+1))
fi
# no plaintext token AND no enroll private key persisted under principals_dir
if grep -rqF "$t8" "$PDIR" 2>/dev/null; then
    printf '  FAIL: a plaintext token was found on disk under principals_dir\n' >&2; FAIL=$((FAIL+1))
else printf '  PASS: no plaintext token persisted on disk\n'; PASS=$((PASS+1)); fi
if grep -rqF 'BEGIN OPENSSH PRIVATE KEY' "$PDIR" 2>/dev/null; then
    printf '  FAIL: an enroll PRIVATE key was found on disk under principals_dir\n' >&2; FAIL=$((FAIL+1))
else printf '  PASS: no enroll private key persisted on disk\n'; PASS=$((PASS+1)); fi

# ──────────────────────────────────────────────────────────────────────
# LIVE-sshd integration (opt-in): prove the ROOT CAUSE (sshd refuses the
# non-root-owned AuthorizedKeysCommand) AND the FIX (enroll-key self-enroll)
# end-to-end against a real sshd. Opt-in (SELFENROLL_LIVE_SSHD=1) AND only if a
# non-root sshd can bind a loopback high port — skip cleanly otherwise.
# ──────────────────────────────────────────────────────────────────────
if [[ "${SELFENROLL_LIVE_SSHD:-0}" == "1" ]]; then
    echo "== LIVE. real sshd: (A) AKC refused [root cause]  (B) enroll-key self-enroll [fix]  (C) window closes =="
    SSHD=$(command -v sshd || echo /usr/sbin/sshd)
    if [[ ! -x "$SSHD" ]]; then
        echo "  SKIP: sshd unavailable"
    else
        LPORT=42210; ME=$(whoami)
        ssh-keygen -t ed25519 -f "$WORK/hostkey" -N '' >/dev/null 2>&1
        mk_cfg() {  # $1 = AuthorizedKeysCommand line value (or empty for none)
            cat > "$WORK/sshd_config" <<EOF
Port $LPORT
ListenAddress 127.0.0.1
HostKey $WORK/hostkey
PidFile $WORK/sshd.pid
AuthorizedKeysFile $AK
AuthorizedKeysCommand ${1:-none}
AuthorizedKeysCommandUser $ME
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
LogLevel VERBOSE
AcceptEnv MONITOR_REMOTE_PRINCIPALS_DIR NEXUS_SERVICES_REGISTRY MONITOR_REMOTE_FROM_CIDR
EOF
        }
        # sshd strips the environment before exec'ing a forced command, so this
        # test passes its FIXTURE dirs to the enroll session via AcceptEnv/SendEnv.
        # PRODUCTION does NOT: the real forced command resolves principals_dir
        # from $HOME + config (config/load.sh), which a real login session has.
        start_sshd() { "$SSHD" -f "$WORK/sshd_config" -E "$WORK/sshd.log" 2>"$WORK/sshd.err" && sleep 1 &&
            { ss -ltn 2>/dev/null | grep -q ":$LPORT " || netstat -ltn 2>/dev/null | grep -q ":$LPORT "; }; }
        stop_sshd() { [[ -f "$WORK/sshd.pid" ]] && kill "$(cat "$WORK/sshd.pid")" 2>/dev/null; sleep 0.3 2>/dev/null || true; }
        SSH_OPTS=(-p "$LPORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$WORK/known"
                  -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR -o PreferredAuthentications=publickey
                  -o SendEnv=MONITOR_REMOTE_PRINCIPALS_DIR -o SendEnv=NEXUS_SERVICES_REGISTRY
                  -o SendEnv=MONITOR_REMOTE_FROM_CIDR)

        # A. ROOT CAUSE: wire the AKC path with a repo script (AKC_STANDIN), which
        #    lives under a non-root-owned tree → sshd must REFUSE to run it. This
        #    is the impossibility documented in docs/remote-access-akc-note.md.
        : > "$AK"; chmod 600 "$AK"
        mk_cfg "$AKC_STANDIN $PDIR %u %t %k"
        if start_sshd; then
            ssh-keyscan -p "$LPORT" 127.0.0.1 >"$WORK/known" 2>/dev/null
            ssh "${SSH_OPTS[@]}" -i "$WORK/client" "$ME@127.0.0.1" true >/dev/null 2>&1
            arc=$?
            stop_sshd
            if grep -q 'Unsafe AuthorizedKeysCommand' "$WORK/sshd.log" && (( arc != 0 )); then
                printf '  PASS: A — sshd REFUSES the non-root-owned AuthorizedKeysCommand (the root cause)\n'; PASS=$((PASS+1))
            else
                printf '  FAIL: A — expected "Unsafe AuthorizedKeysCommand" + auth failure (arc=%s)\n' "$arc" >&2; FAIL=$((FAIL+1))
            fi

            # B. FIX: AuthorizedKeysCommand=none; enroll-invite installs the
            #    enroll-only key; client connects WITH the enroll key + pipes
            #    <token>\n<client.pub> → self-enrolls; client's OWN key then
            #    Accepts. from= pinned to loopback so the connection is allowed.
            : > "$AK"; chmod 600 "$AK"
            export MONITOR_REMOTE_FROM_CIDR="127.0.0.1/32"
            invout=$(inv liveclient); ltok=$(tokof "$invout")
            printf '%s\n' "$invout" | sed -n '/BEGIN NEXUS ENROLL/,/END NEXUS ENROLL/p' \
                | sed '1d;$d' > "$WORK/enrollkey"; chmod 600 "$WORK/enrollkey"
            mk_cfg "none"
            if start_sshd; then
                : > "$WORK/sshd.log"
                enr=$(printf '%s\n%s\n' "$ltok" "$(cat "$WORK/client.pub")" \
                        | ssh "${SSH_OPTS[@]}" -T -i "$WORK/enrollkey" "$ME@127.0.0.1" 2>/dev/null)
                if [[ "$enr" == *enrolled* ]] && grep -q 'liveclient@nexus-remote' "$AK"; then
                    printf '  PASS: B — enroll-key self-enroll works end-to-end (client key enrolled)\n'; PASS=$((PASS+1))
                else
                    printf '  FAIL: B — self-enroll did not enroll the client key (out=[%s])\n' "$enr" >&2; FAIL=$((FAIL+1))
                fi
                # client's OWN key now authenticates (channel wrapper accepts auth)
                : > "$WORK/sshd.log"
                ssh "${SSH_OPTS[@]}" -T -i "$WORK/client" "$ME@127.0.0.1" </dev/null >/dev/null 2>&1
                if grep -q 'Accepted publickey for '"$ME" "$WORK/sshd.log"; then
                    printf '  PASS: B2 — the client OWN key now authenticates via AuthorizedKeysFile\n'; PASS=$((PASS+1))
                else
                    printf '  FAIL: B2 — client own key did not authenticate post-enroll\n' >&2; FAIL=$((FAIL+1))
                fi
                # C. window closed: enroll line pruned → enroll key now DENIED
                : > "$WORK/sshd.log"
                printf '%s\n%s\n' "$ltok" "$(cat "$WORK/client.pub")" \
                    | ssh "${SSH_OPTS[@]}" -T -i "$WORK/enrollkey" "$ME@127.0.0.1" >/dev/null 2>&1
                crc=$?
                if (( crc != 0 )) && ! grep -q 'enroll-[0-9a-f]' "$AK"; then
                    printf '  PASS: C — after consume the enroll key is DENIED (window closed, line pruned)\n'; PASS=$((PASS+1))
                else
                    printf '  FAIL: C — enroll key still usable after consume (crc=%s)\n' "$crc" >&2; FAIL=$((FAIL+1))
                fi
                stop_sshd
            else
                echo "  SKIP: could not start sshd for the fix path"; stop_sshd
            fi
            unset MONITOR_REMOTE_FROM_CIDR
        else
            echo "  SKIP: could not start a non-root sshd on 127.0.0.1:$LPORT (environment-dependent)"
            stop_sshd
        fi
    fi
fi

th_summary_and_exit
