#!/usr/bin/env bash
# remote-enroll-session.sh — the ENROLL-ONLY forced command for ROOTLESS
# token-gated self-enrollment over SSH (agent-channel RFC Part A §4.9.1).
#
# ── Why this shape (rootless constraint) ──────────────────────────────
# An in-sandbox sshd is NON-root and CANNOT use AuthorizedKeysCommand:
# OpenSSH's auth_secure_path requires the command owned by uid 0, and the
# sandbox user namespace has NO uid-0-owned files (real root maps to `nobody`).
# So there is no dynamic-key hook; the client cannot authenticate with an
# a-priori-unknown key. Self-enroll therefore rides the ONE rootless key
# primitive that works — AuthorizedKeysFile — via a per-window ENROLL-ONLY key:
# `ng remote enroll-invite` mints {one-time token, throwaway enroll keypair} and
# installs the enroll public key as a token-hash-tagged, enroll-only line:
#
#   command="<abs>/remote-enroll-session.sh <token_hash>",restrict[,from="…"] <enroll_pub> enroll-<hash>@nexus-remote
#
# The operator delivers {token, enroll PRIVATE key} to the client OUT-OF-BAND.
# The client connects WITH THE ENROLL KEY and pipes, on stdin:
#
#   <one-time-token>\n<its-own-public-key-line>\n
#
# ── The contract (enroll-ONLY, fail-closed) ───────────────────────────
#   * $1 is the token hash baked SERVER-SIDE into the forced command (binds this
#     enroll key to exactly its token). The client cannot change it.
#   * Reads EXACTLY two lines from stdin: the one-time token, then the client's
#     OWN public key line. Bounded, with a read timeout. Nothing else is read.
#   * REFUSES a non-empty $SSH_ORIGINAL_COMMAND — no client command, no shell,
#     no channel verb. It can do exactly one thing: attempt a token-gated enroll.
#   * Verifies sha256(token) == $1 (the enroll key must match its own token),
#     then delegates to `remote-enroll.sh enroll`, which performs the ATOMIC
#     single-use token consume, server-side authorized_keys line reconstruction
#     (forced command + restrict [+ from=]), and takes the principal from the
#     TOKEN record. The client pubkey is server-reconstructed (_safe_pubkey) —
#     any smuggled options/comment are stripped.
#   * On success it removes THIS enroll line (prune-enroll) so the window closes
#     at the key layer too; the client reconnects with its now-enrolled own key.
#   * On ANY failure (no/garbage/expired/replayed token, mismatch, bad pubkey,
#     write error) it enrolls nothing, logs the attempt WITHOUT the token, and
#     exits non-zero.
#
# ── Exit codes ─────────────────────────────────────────────────────────
#   0  enrolled (token consumed; reconnect with your OWN key)
#   3  refused: no / malformed / invalid / expired / replayed / mismatched token,
#      or a malformed client pubkey on stdin
#   5  internal: cannot stage the client pubkey for enrollment
#  10  refused: channel not registered
#  11  refused: malformed baked token-hash arg (misconfigured enroll line)
#  12  refused: a client command was supplied (enroll-only endpoint)

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_remote_lib.sh
source "$_script_dir/_remote_lib.sh" || { echo "remote-enroll-session: lib load failed" >&2; exit 5; }

EN="$_script_dir/remote-enroll.sh"

# Audit log (op-only; never the token). Mirrors the forced-command logger.
_es_logfile() {
    if [[ -n "${NEXUS_REMOTE_LOG:-}" ]]; then printf '%s' "$NEXUS_REMOTE_LOG"; return; fi
    printf '%s/self-enroll.log' "$(_remote_principals_dir)"
}
_es_log() {
    local lf; lf=$(_es_logfile); local dir; dir=$(dirname "$lf")
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" "$*" >> "$lf" 2>/dev/null || true
}

HASH="${1:-}"

# ── enroll-ONLY: refuse any client command (no passthrough, ever) ──────
if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    _es_log "REFUSED(12): client command on enroll-only endpoint"
    echo "remote-enroll-session: enroll-only endpoint — no commands are accepted here." >&2
    exit 12
fi

# ── gate: the channel must be registered ───────────────────────────────
_remote_registered || { _es_log "REFUSED(10): not registered"; echo "remote-enroll-session: channel not enabled." >&2; exit 10; }

# ── validate the SERVER-BAKED token hash (misconfig backstop) ──────────
[[ "$HASH" =~ ^[0-9a-f]{64}$ ]] || { _es_log "REFUSED(11): bad baked token hash"; echo "remote-enroll-session: misconfigured enroll line (bad token hash)." >&2; exit 11; }

# ── read the one-time token + the client's OWN pubkey from stdin ───────
# Line 1 = token; line 2 = the client's public key line. Bounded + timeout so a
# client that connects and never sends hangs no longer than the timeout (paired
# with sshd LoginGraceTime/ClientAlive*). We read at most two lines.
TOKEN=""; PUBLINE=""
IFS= read -r -t "${REMOTE_ENROLL_STDIN_TIMEOUT:-30}" TOKEN || true
IFS= read -r -t "${REMOTE_ENROLL_STDIN_TIMEOUT:-30}" PUBLINE || true
TOKEN="${TOKEN%$'\r'}"       # tolerate CRLF clients
PUBLINE="${PUBLINE%$'\r'}"

if [[ -z "$TOKEN" ]]; then
    _es_log "REFUSED(3): no token on stdin"
    echo "remote-enroll-session: no one-time token received on stdin." >&2
    exit 3
fi
# Bound the length and shape BEFORE handing it on (never log the value).
if (( ${#TOKEN} > 128 )) || [[ ! "$TOKEN" =~ ^nxr1_[0-9a-f]{16,}$ ]]; then
    _es_log "REFUSED(3): malformed token"
    echo "remote-enroll-session: malformed one-time token." >&2
    exit 3
fi
# Bind this enroll key to its own token: sha256(token) MUST equal the baked hash.
_tok_hash=$(_remote_hash_token "$TOKEN" 2>/dev/null || echo "")
if [[ -z "$_tok_hash" || "$_tok_hash" != "$HASH" ]]; then
    _es_log "REFUSED(3): token does not match this enroll key"
    echo "remote-enroll-session: token does not match this enrollment invitation." >&2
    exit 3
fi

# Validate the client pubkey SHAPE before consuming the token (so an obviously
# malformed key does not burn the one-time token). Full sanitation + server-side
# reconstruction happens in remote-enroll.sh:_safe_pubkey.
read -r _pktype _pkblob _rest <<<"$PUBLINE" || true
case "$_pktype" in
    ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *) _es_log "REFUSED(3): bad/absent client pubkey type on stdin"; echo "remote-enroll-session: missing or unsupported client public key on stdin." >&2; exit 3 ;;
esac
[[ "$_pkblob" =~ ^[A-Za-z0-9+/]+=*$ ]] || { _es_log "REFUSED(3): malformed client pubkey blob"; echo "remote-enroll-session: malformed client public key." >&2; exit 3; }

# ── stage the CLIENT pubkey and enroll via the atomic machinery ────────
umask 077
PDIR=$(_remote_principals_dir)
mkdir -p "$PDIR" 2>/dev/null || true
TMP=$(mktemp "$PDIR/.enroll-pub.XXXXXX" 2>/dev/null) || { _es_log "REFUSED(5): mktemp failed"; echo "remote-enroll-session: internal error." >&2; exit 5; }
# Write ONLY the sanitized type+blob (drop any client-supplied comment/options).
printf '%s %s self-enroll\n' "$_pktype" "$_pkblob" > "$TMP" || { rm -f "$TMP"; _es_log "REFUSED(5): stage write failed"; echo "remote-enroll-session: internal error." >&2; exit 5; }

# remote-enroll.sh performs: atomic single-use consume, principal-from-token,
# server-side line reconstruction. It fails closed (exit 3) on a spent/expired/
# replayed token. The token is piped on the child's STDIN (--token-stdin), NOT
# its argv, so it never appears in `ps`/`/proc/<pid>/cmdline` of any child.
printf '%s\n' "$TOKEN" | "$EN" enroll --pubkey "$TMP" --token-stdin >/dev/null 2>&1
rc=${PIPESTATUS[1]}
rm -f "$TMP"

if (( rc == 0 )); then
    # Close the window at the key layer: remove this now-consumed enroll line
    # (prune-enroll drops any enroll line whose token is no longer live).
    "$EN" prune-enroll >/dev/null 2>&1 || true
    _es_log "ENROLLED: a client key was enrolled via a consumed one-time token"
    echo "enrolled — reconnect with YOUR OWN key (the one-time token is now consumed)."
    echo "next: reconnect and run 'policy' (or 'help') for full usage + the on-request capability note."
    exit 0
fi
# enroll.sh returns 3 (token invalid/expired/replayed) or 2 (bad key)/other.
_es_log "REFUSED($rc): enrollment failed (token invalid/expired/replayed or write error)"
echo "remote-enroll-session: enrollment failed — the token is invalid, expired, or already used." >&2
exit 3
