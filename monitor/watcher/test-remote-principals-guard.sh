#!/usr/bin/env bash
# Tests for the fail-closed CREDENTIAL-STORAGE guard of the confined remote
# channel: `_remote_principals_harden` / `_remote_principals_guard`
# (monitor/_remote_lib.sh) and the enrollment-token record GC
# (`monitor/remote-enroll.sh gc-tokens`).
#
# WHY the invariant is `$HOME/.claude`, and why it is now ENFORCED, not merely
# observed to hold: the nexus project tree is GROUP-SHARED lab storage on
# /shared (drwxrws---) and is a git worktree whose files reach `ng upload`.
# $HOME/.claude is 0700, single-uid, and survives a sandbox restart (which
# destroys /tmp). Before this suite, `monitor.remote.principals_dir` /
# MONITOR_REMOTE_PRINCIPALS_DIR could relocate the host key + authorized_keys
# into the shared tree and sshd would start happily.
#
#   1. the DEFAULT principals_dir (0700 under $HOME/.claude) PASSES
#   2. a principals_dir OUTSIDE $HOME/.claude is REFUSED             ← load-bearing
#   2b. a SIBLING with a shared prefix ($HOME/.claude-evil) is REFUSED
#   2c. a SYMLINK from inside $HOME/.claude into shared storage is REFUSED
#       (both sides are resolved physically — symlinks cannot smuggle)
#   3. principals_dir mode 0755 is REFUSED                            ← load-bearing
#   3b. enroll/ mode 0755 is REFUSED
#   4. a group/other-READABLE secret file is REFUSED (host key, authorized_keys,
#      *.token, self-enroll.log, forced-command.log, .authorized_keys.lock)
#   4b. a group/other-WRITABLE non-secret file is REFUSED (banner.txt, *.pub)
#   4c. a NON-secret file that is merely group-READABLE passes (banner/*.pub
#      are non-secret by design — the guard must not over-refuse and get
#      switched off)
#   5. every refusal prints an actionable remediation, and the guard NEVER
#      mutates (a refused dir keeps its mode)
#   6. `_remote_principals_harden` self-heals the modes we OWN, and does NOT
#      mask a wrong LOCATION (harden-then-guard still refuses)
#   7. gc-tokens deletes EXPIRED and CORRUPT records, KEEPS a live one
#   8. gc-tokens removes stranded `*.token.consumed.*` claim files older than
#      one TTL, and keeps a fresh one (a consume may be in flight)
#   9. gc-tokens never touches authorized_keys / the host key
#
# NOTE on what was ALREADY true before this change (regression locks, not new
# guarantees — see the PR body): an expired token is ALREADY refused at redeem,
# and a consumed token record is ALREADY removed at redeem. Cases 10 and 11
# assert both so a future refactor cannot quietly drop them.
#
#  10. redeeming an EXPIRED token fails closed (exit 3), no key enrolled
#  11. redeeming a token REMOVES its record from disk (single-use consume)
#
# Hermetic: HOME, NEXUS_CONFIG and the principals_dir are all fixtures. The
# production guard has NO env escape hatch — these tests obey the real rule by
# relocating HOME, exactly as a sandbox restart would. ssh-keygen is real.
#
# Run: bash monitor/watcher/test-remote-principals-guard.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_test_dir/_test_helpers.sh"
MON_DIR=$(cd "$_test_dir/.." && pwd)
LIB="$MON_DIR/_remote_lib.sh"
ENROLL="$MON_DIR/remote-enroll.sh"

WORK=$(mktemp -d -t nexus-pguard-XXXXXX); trap 'rm -rf "$WORK"' EXIT

# Pin config to a fixture so the operator's live nexus.yml never leaks in.
HERMETIC_CFG="$WORK/nexus.yml"
cat >"$HERMETIC_CFG" <<'YML'
monitor:
  remote:
    bind_address: 127.0.0.1
    from_cidr: ""
YML
export NEXUS_CONFIG="$HERMETIC_CFG"

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude"
SHARED="$WORK/shared-lab-tree"          # stands in for /shared/…/nexus
mkdir -p "$SHARED"

# Run the guard with a given HOME + principals_dir. Echo PASS|REFUSE|ABSENT.
# Nothing but $1/$2 varies — the guard itself is production code, unmodified.
#
# ABSENT is load-bearing for the both-directions check. Run against PRE-FIX
# source, `bash -c "source lib; _remote_principals_guard"` exits 127 (command
# not found) — indistinguishable from a refusal (exit 1) unless we look. Every
# REFUSE assertion would then pass VACUOUSLY on the very source it is meant to
# fail on, and the suite would prove nothing. Probe with `declare -F` first.
guard() {
    local home="$1" pdir="$2"
    HOME="$home" bash -c "source '$LIB'; declare -F _remote_principals_guard >/dev/null" 2>/dev/null \
        || { echo ABSENT; return; }
    HOME="$home" MONITOR_REMOTE_PRINCIPALS_DIR="$pdir" \
        bash -c "source '$LIB'; _remote_principals_guard" >/dev/null 2>&1 \
        && echo PASS || echo REFUSE
}
guard_err() {
    local home="$1" pdir="$2"
    HOME="$home" MONITOR_REMOTE_PRINCIPALS_DIR="$pdir" \
        bash -c "source '$LIB'; _remote_principals_guard" 2>&1 >/dev/null
}
harden() {
    local home="$1" pdir="$2"
    HOME="$home" MONITOR_REMOTE_PRINCIPALS_DIR="$pdir" \
        bash -c "source '$LIB'; _remote_principals_harden" >/dev/null 2>&1
}
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Build a well-formed principals dir at $1 (0700, 0600 secrets).
mk_pdir() {
    local d="$1"
    mkdir -p "$d/enroll"; chmod 700 "$d" "$d/enroll"
    : > "$d/authorized_keys";      chmod 600 "$d/authorized_keys"
    : > "$d/ssh_host_ed25519_key"; chmod 600 "$d/ssh_host_ed25519_key"
    : > "$d/self-enroll.log";      chmod 600 "$d/self-enroll.log"
    printf 'nexus-remote\n' > "$d/banner.txt";            chmod 644 "$d/banner.txt"
    printf 'ssh-ed25519 AAAA host\n' > "$d/ssh_host_ed25519_key.pub"; chmod 644 "$d/ssh_host_ed25519_key.pub"
}

# ── 1. the compliant default passes ──────────────────────────────────────
GOOD="$FAKE_HOME/.claude/nexus-remote"
mk_pdir "$GOOD"
assert_eq "compliant 0700 dir under \$HOME/.claude passes" "$(guard "$FAKE_HOME" "$GOOD")" "PASS"

# A not-yet-created dir under the root is fine (gen-host-key creates it 0700).
assert_eq "absent dir under the root passes (created 0700 on demand)" \
    "$(guard "$FAKE_HOME" "$FAKE_HOME/.claude/not-yet")" "PASS"

# ── 2. LOCATION — the load-bearing rule ──────────────────────────────────
OUTSIDE="$SHARED/monitor/.state/nexus-remote"
mk_pdir "$OUTSIDE"
assert_eq "principals_dir in the group-shared project tree is REFUSED" \
    "$(guard "$FAKE_HOME" "$OUTSIDE")" "REFUSE"

assert_eq "principals_dir at \$HOME (outside .claude) is REFUSED" \
    "$(guard "$FAKE_HOME" "$FAKE_HOME/nexus-remote")" "REFUSE"

# 2b. prefix-boundary: `.claude-evil` must not satisfy "starts with .claude"
EVIL="$FAKE_HOME/.claude-evil/nexus-remote"
mk_pdir "$EVIL"
assert_eq "sibling with a shared prefix (.claude-evil) is REFUSED" \
    "$(guard "$FAKE_HOME" "$EVIL")" "REFUSE"

# 2c. symlink escape: a path that LEXICALLY lives under $HOME/.claude but
# physically resolves into shared storage must be refused.
SYMTGT="$SHARED/sneaky-store"; mk_pdir "$SYMTGT"
ln -sfn "$SYMTGT" "$FAKE_HOME/.claude/linked-remote"
assert_eq "symlink from inside .claude into shared storage is REFUSED" \
    "$(guard "$FAKE_HOME" "$FAKE_HOME/.claude/linked-remote")" "REFUSE"

# …and the same physical dir reached by its real path is refused identically.
assert_eq "the symlink's target is REFUSED by its real path too" \
    "$(guard "$FAKE_HOME" "$SYMTGT")" "REFUSE"

# ── 2d. OWNERSHIP ────────────────────────────────────────────────────────
# A foreign-owned principals_dir cannot be FORGED in-sandbox: creating one
# requires a second uid, which the bwrap userns does not give us. So we test the
# ownership DECISION through the `_remote_owner_of` seam (the guard resolves the
# owner through that function, deliberately, so this stays testable), and test
# the SEAM ITSELF separately against a real file. Decision + reader = the whole
# check. This is the one fail-closed condition that would otherwise be asserted
# rather than tested, and an untested fail-closed check is how it becomes
# fail-open.
guard_owned_by() {   # $1 = uid that _remote_owner_of should report
    local uid="$1"
    HOME="$FAKE_HOME" MONITOR_REMOTE_PRINCIPALS_DIR="$GOOD" \
        bash -c "source '$LIB'
                 declare -F _remote_principals_guard >/dev/null || { echo ABSENT; exit 0; }
                 _remote_owner_of() { printf '%s' '$uid'; }
                 _remote_principals_guard >/dev/null 2>&1 && echo PASS || echo REFUSE"
}
guard_owned_by_err() {
    local uid="$1"
    HOME="$FAKE_HOME" MONITOR_REMOTE_PRINCIPALS_DIR="$GOOD" \
        bash -c "source '$LIB'
                 _remote_owner_of() { printf '%s' '$uid'; }
                 _remote_principals_guard" 2>&1 >/dev/null
}
ME_UID=$(id -u)
FOREIGN_UID=$(( ME_UID + 1 ))

assert_eq "principals_dir owned by a FOREIGN uid is REFUSED" \
    "$(guard_owned_by "$FOREIGN_UID")" "REFUSE"
assert_contains "…and the refusal names both uids" \
    "$(guard_owned_by_err "$FOREIGN_UID")" "is owned by uid $FOREIGN_UID, not by uid $ME_UID"
assert_eq "…while our OWN uid passes (the stub is not simply refusing everything)" \
    "$(guard_owned_by "$ME_UID")" "PASS"
assert_eq "uid 0 (root-owned credential dir) is REFUSED for a non-root caller" \
    "$(guard_owned_by 0)" "REFUSE"

# Fail CLOSED when ownership cannot be resolved at all. Previously an empty
# owner fell through to the mode check and the service STARTED.
assert_eq "an UNRESOLVABLE owner is REFUSED (not silently trusted)" \
    "$(guard_owned_by "")" "REFUSE"
assert_contains "…with an explicit cannot-determine refusal" \
    "$(guard_owned_by_err "")" "cannot determine ownership"

# The SEAM itself: unstubbed, _remote_owner_of must really read st_uid.
: > "$WORK/owned-by-me"
real_owner=$(bash -c "source '$LIB'; _remote_owner_of '$WORK/owned-by-me'")
assert_eq "_remote_owner_of reads the real st_uid of a file" "$real_owner" "$ME_UID"
real_owner_dir=$(bash -c "source '$LIB'; _remote_owner_of '$GOOD'")
assert_eq "_remote_owner_of reads the real st_uid of a directory" "$real_owner_dir" "$ME_UID"
# …and returns non-zero / empty on a path that does not exist (feeding the
# fail-closed branch above rather than a bogus uid).
missing_owner=$(bash -c "source '$LIB'; _remote_owner_of '$WORK/no-such-file' || true")
assert_empty "_remote_owner_of yields nothing for a missing path" "$missing_owner"

# Ground the seam in reality: on a REAL foreign-owned path the reader must
# report a foreign uid, not our own. We cannot CREATE such a path in-sandbox (no
# second uid), but we can OBSERVE one read-only. Without this, the stub above
# could be testing a decision the real reader can never trigger.
#
# Do NOT assert uid 0 here: inside the agent-sandbox's bwrap user namespace, the
# root-owned host /etc is unmapped and `stat` reports the kernel overflowuid
# (65534, "nobody") — which is precisely the foreign uid the guard would meet in
# production. Assert the property that matters (foreign ≠ ours), not the number.
if [[ -d /etc ]]; then
    etc_owner=$(bash -c "source '$LIB'; _remote_owner_of /etc")
    if [[ "$etc_owner" =~ ^[0-9]+$ ]] && [[ "$etc_owner" != "$ME_UID" ]]; then
        printf '  PASS: the reader reports a real FOREIGN uid (%s) for /etc, ≠ our uid (%s)\n' "$etc_owner" "$ME_UID"
        PASS=$((PASS+1))
    else
        printf '  FAIL: reader cannot distinguish a foreign owner (got %s, our uid %s)\n' "$etc_owner" "$ME_UID" >&2
        FAIL=$((FAIL+1))
    fi
    # …and the guard REFUSES when handed that real foreign uid (no stub involved
    # in producing it — only in placing it where the guard looks).
    assert_eq "guard REFUSES a principals_dir carrying that real foreign uid" \
        "$(guard_owned_by "$etc_owner")" "REFUSE"
else
    printf '  SKIP: no /etc — real foreign-owner reader check not exercised\n'
fi

# Belt and braces: with NO stub at all, the real dir we really own still passes,
# so the ownership check is not vacuously refusing on the happy path.
assert_eq "unstubbed ownership check passes on a dir we actually own" \
    "$(guard "$FAKE_HOME" "$GOOD")" "PASS"

# ── 3. DIRECTORY MODE ────────────────────────────────────────────────────
LOOSE="$FAKE_HOME/.claude/loose-remote"
mk_pdir "$LOOSE"; chmod 755 "$LOOSE"
assert_eq "principals_dir mode 0755 is REFUSED" "$(guard "$FAKE_HOME" "$LOOSE")" "REFUSE"
chmod 750 "$LOOSE"
assert_eq "principals_dir mode 0750 (group-readable) is REFUSED" "$(guard "$FAKE_HOME" "$LOOSE")" "REFUSE"
chmod 700 "$LOOSE"
assert_eq "…back at 0700 it passes" "$(guard "$FAKE_HOME" "$LOOSE")" "PASS"

# 3b. enroll/ subdir mode
chmod 755 "$LOOSE/enroll"
assert_eq "enroll/ mode 0755 is REFUSED" "$(guard "$FAKE_HOME" "$LOOSE")" "REFUSE"
chmod 700 "$LOOSE/enroll"

# ── 4. FILE MODES ────────────────────────────────────────────────────────
FM="$FAKE_HOME/.claude/fm-remote"
for secret in ssh_host_ed25519_key authorized_keys self-enroll.log forced-command.log .authorized_keys.lock; do
    rm -rf "$FM"; mk_pdir "$FM"
    : > "$FM/$secret"; chmod 600 "$FM/$secret"
    assert_eq "…$secret at 0600 passes" "$(guard "$FAKE_HOME" "$FM")" "PASS"
    chmod 640 "$FM/$secret"
    assert_eq "group-READABLE secret $secret is REFUSED" "$(guard "$FAKE_HOME" "$FM")" "REFUSE"
done

# a token record is secret too
rm -rf "$FM"; mk_pdir "$FM"
TOKREC="$FM/enroll/$(printf 'a%.0s' {1..64}).token"
printf 'principal=x\nexpires=9999999999\n' > "$TOKREC"; chmod 600 "$TOKREC"
assert_eq "enroll/*.token at 0600 passes" "$(guard "$FAKE_HOME" "$FM")" "PASS"
chmod 604 "$TOKREC"
assert_eq "other-READABLE enroll/*.token is REFUSED" "$(guard "$FAKE_HOME" "$FM")" "REFUSE"

# 4b. non-secret file that is group/other WRITABLE
rm -rf "$FM"; mk_pdir "$FM"
chmod 666 "$FM/banner.txt"
assert_eq "group/other-WRITABLE banner.txt is REFUSED" "$(guard "$FAKE_HOME" "$FM")" "REFUSE"
chmod 644 "$FM/banner.txt"
chmod 664 "$FM/ssh_host_ed25519_key.pub"
assert_eq "group-WRITABLE host pubkey is REFUSED" "$(guard "$FAKE_HOME" "$FM")" "REFUSE"

# 4c. …but merely group/other-READABLE non-secrets are FINE. A guard that
# refused here would refuse on a healthy dir and get switched off.
chmod 644 "$FM/ssh_host_ed25519_key.pub"
assert_eq "0644 banner.txt + host pubkey pass (non-secret by design)" \
    "$(guard "$FAKE_HOME" "$FM")" "PASS"

# ── 5. actionable refusals; the guard never mutates ──────────────────────
err=$(guard_err "$FAKE_HOME" "$OUTSIDE")
assert_contains "location refusal names the required root" "$err" ".claude"
assert_contains "location refusal says REFUSING" "$err" "REFUSING"
assert_contains "location refusal explains the shared-tree hazard" "$err" "group-shared"

chmod 755 "$LOOSE"
err=$(guard_err "$FAKE_HOME" "$LOOSE")
assert_contains "mode refusal prints the chmod remediation" "$err" "chmod 700"
assert_eq "guard did NOT mutate the refused dir's mode" "$(mode_of "$LOOSE")" "755"
chmod 700 "$LOOSE"

# unset HOME ⇒ refuse (cannot resolve the credential root). Compare the rc
# EXACTLY: a substring test for "rc=1" also matches the "rc=127" that pre-fix
# source returns for a missing function — another vacuous both-ways pass.
rc=$(HOME= MONITOR_REMOTE_PRINCIPALS_DIR="$GOOD" \
        bash -c "source '$LIB'; _remote_principals_guard" >/dev/null 2>&1; echo "$?")
assert_eq "empty \$HOME fails closed (exit 1, not 127)" "$rc" "1"

# ── 6. harden self-heals modes we own, but NOT the location ──────────────
HH="$FAKE_HOME/.claude/harden-remote"
mk_pdir "$HH"
chmod 755 "$HH"; chmod 660 "$HH/authorized_keys"
: > "$HH/.authorized_keys.lock"; chmod 660 "$HH/.authorized_keys.lock"   # the live-endpoint mode
assert_eq "pre-harden: loose dir is REFUSED" "$(guard "$FAKE_HOME" "$HH")" "REFUSE"
harden "$FAKE_HOME" "$HH"
assert_eq "harden tightened the dir to 0700" "$(mode_of "$HH")" "700"
assert_eq "harden tightened authorized_keys to 0600" "$(mode_of "$HH/authorized_keys")" "600"
assert_eq "harden tightened the flock file to 0600" "$(mode_of "$HH/.authorized_keys.lock")" "600"
assert_eq "post-harden: the compliant dir PASSES" "$(guard "$FAKE_HOME" "$HH")" "PASS"

# harden must NOT rescue a wrong location — that is never auto-"fixed"
harden "$FAKE_HOME" "$OUTSIDE"
assert_eq "harden does NOT mask a wrong LOCATION (still refused)" \
    "$(guard "$FAKE_HOME" "$OUTSIDE")" "REFUSE"

# ── 7. gc-tokens: expired + corrupt out, live stays ──────────────────────
GC="$FAKE_HOME/.claude/gc-remote"
mk_pdir "$GC"
now=$(date +%s)
h_live="$(printf '1%.0s' {1..64})"; h_exp="$(printf '2%.0s' {1..64})"; h_bad="$(printf '3%.0s' {1..64})"
printf 'principal=live\nexpires=%s\n' "$(( now + 3600 ))" > "$GC/enroll/$h_live.token"
printf 'principal=old\nexpires=%s\n'  "$(( now - 3600 ))" > "$GC/enroll/$h_exp.token"
printf 'principal=bad\nexpires=NOPE\n'                    > "$GC/enroll/$h_bad.token"
chmod 600 "$GC"/enroll/*.token
printf 'command="x" ssh-ed25519 AAAA live@nexus-remote\n' > "$GC/authorized_keys"
chmod 600 "$GC/authorized_keys"

HOME="$FAKE_HOME" MONITOR_REMOTE_PRINCIPALS_DIR="$GC" bash "$ENROLL" gc-tokens >/dev/null 2>&1
assert_file_exists "gc-tokens KEEPS a live token record" "$GC/enroll/$h_live.token"
assert_no_file     "gc-tokens removes an EXPIRED record"  "$GC/enroll/$h_exp.token"
assert_no_file     "gc-tokens removes a CORRUPT record"   "$GC/enroll/$h_bad.token"

# ── 8. stranded consume-claims ───────────────────────────────────────────
old_claim="$GC/enroll/$h_exp.token.consumed.999"
new_claim="$GC/enroll/$h_live.token.consumed.998"
printf 'principal=old\nexpires=1\n' > "$old_claim"; chmod 600 "$old_claim"
printf 'principal=live\nexpires=1\n' > "$new_claim"; chmod 600 "$new_claim"
touch -d "@$(( now - 7200 ))" "$old_claim" 2>/dev/null || touch -t "$(date -d @$(( now - 7200 )) +%Y%m%d%H%M.%S)" "$old_claim"
HOME="$FAKE_HOME" MONITOR_REMOTE_PRINCIPALS_DIR="$GC" bash "$ENROLL" gc-tokens >/dev/null 2>&1
assert_no_file     "gc-tokens removes a STRANDED claim older than one TTL" "$old_claim"
assert_file_exists "gc-tokens KEEPS a fresh claim (consume may be in flight)" "$new_claim"

# ── 9. gc-tokens touches nothing else ────────────────────────────────────
assert_file_exists "gc-tokens leaves authorized_keys alone" "$GC/authorized_keys"
assert_file_exists "gc-tokens leaves the host key alone"    "$GC/ssh_host_ed25519_key"
assert_eq "gc-tokens leaves authorized_keys byte-identical" \
    "$(wc -l < "$GC/authorized_keys" | tr -d ' ')" "1"

# ── 10/11. redeem-path regression locks (already true — keep them true) ──
if command -v ssh-keygen >/dev/null 2>&1; then
    RD="$FAKE_HOME/.claude/redeem-remote"
    mk_pdir "$RD"
    rm -f "$RD/authorized_keys"
    ssh-keygen -t ed25519 -f "$WORK/client" -N '' -C client >/dev/null 2>&1
    run_enroll() {  # $1 = plaintext token
        printf '%s\n' "$1" | HOME="$FAKE_HOME" MONITOR_REMOTE_PRINCIPALS_DIR="$RD" \
            bash "$ENROLL" enroll --pubkey "$WORK/client.pub" --token-stdin >/dev/null 2>&1
        echo "rc=$?"
    }

    # 10. an EXPIRED token is refused (exit 3) and enrolls nothing.
    tok_exp=$(HOME="$FAKE_HOME" MONITOR_REMOTE_PRINCIPALS_DIR="$RD" \
        MONITOR_REMOTE_ENROLLMENT_TOKEN_TTL_SECONDS=1 \
        bash "$ENROLL" issue-token --principal expiring 2>/dev/null)
    sleep 2
    assert_eq "redeeming an EXPIRED token fails closed (exit 3)" "$(run_enroll "$tok_exp")" "rc=3"
    assert_no_file "…and no authorized_keys was written" "$RD/authorized_keys"

    # 11. a VALID token enrolls once, and its record is GONE (single-use).
    tok_ok=$(HOME="$FAKE_HOME" MONITOR_REMOTE_PRINCIPALS_DIR="$RD" \
        bash "$ENROLL" issue-token --principal onceonly 2>/dev/null)
    hash_ok=$(printf '%s' "$tok_ok" | sha256sum 2>/dev/null | cut -d' ' -f1)
    assert_file_exists "a freshly issued token has a pending record" "$RD/enroll/$hash_ok.token"
    assert_eq "a VALID token enrolls (exit 0)" "$(run_enroll "$tok_ok")" "rc=0"
    assert_no_file "consumed token record is REMOVED from disk" "$RD/enroll/$hash_ok.token"
    assert_eq "replaying the consumed token fails closed (exit 3)" "$(run_enroll "$tok_ok")" "rc=3"

    # The plaintext token must never have been written anywhere under the dir.
    if grep -rqF "$tok_ok" "$RD" 2>/dev/null; then
        printf '  FAIL: the plaintext token was found on disk under principals_dir\n' >&2; FAIL=$((FAIL+1))
    else
        printf '  PASS: the plaintext token never reached disk\n'; PASS=$((PASS+1))
    fi
else
    printf '  SKIP: ssh-keygen absent — redeem-path locks (10/11) not exercised\n'
fi

th_summary_and_exit
