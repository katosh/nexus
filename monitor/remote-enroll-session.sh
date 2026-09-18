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
#   6  internal: could NOT COMPUTE the token hash on this machine — says nothing
#      about the token (your-org/nexus-code#1189)
#   7  internal: the enrollment machinery failed for a NON-TOKEN reason (lock
#      contention, authorized_keys write error, misconfigured from_cidr) —
#      likewise says nothing about the token (your-org/nexus-code#1189)
#  10  refused: channel not registered
#  11  refused: malformed baked token-hash arg (misconfigured enroll line)
#  12  refused: a client command was supplied (enroll-only endpoint)
#
# ── "COULD NOT DETERMINE" IS NOT "REFUSED" (your-org/nexus-code#1189) ──
# 6 and 7 exist because this endpoint used to answer *"the token does not match
# this enrollment invitation"* for two conditions in which nothing about the
# token was ever examined:
#
#   * `_remote_hash_token` is a three-fork `printf | sha256sum | awk`. When a
#     fork fails it returns 1, the old code turned that into the empty string
#     and tested `[[ -z "$_tok_hash" || … ]]` — AN EMPTINESS CHECK WEARING A
#     VALIDITY CHECK'S NAME. A machine that could not run `sha256sum` was
#     reported as a client presenting the wrong token.
#   * `remote-enroll.sh`'s `die` exits **1**, so a `flock -w 10` timeout or an
#     `_ak_rmw` write error already arrives here as rc 1 — and the old tail
#     collapsed EVERY non-zero child rc into one `exit 3` whose message names
#     the token. A resource failure wore a security verdict.
#
# Both are the same defect in opposite directions: a failure mode with no
# diagnosis of its own, folded into a specific and confident one. They are also
# why this suite went red under host load with `rc 3 want 0` and no explanation
# — the artefact could not distinguish "the enroll was refused" from "this
# machine could not do it". Fail-CLOSED is unchanged throughout: 6 and 7 enroll
# nothing, exactly as 3 does. What changes is only the CLAIM.

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
    # Explicit mode at creation (your-org/nexus-code#484): self-enrollment is
    # an audit surface, so its log must not be group-writable.
    _ensure_service_log "$lf"
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
# your-org/nexus-code#1266 + #1189, and this hunk exists ONLY in the composition
# of the two legs — neither branch could carry it alone. `_remote_registered` is
# deliberately BOOLEAN (see _remote_lib.sh: it is consumed in `if`/`if !` arms all
# over, and making it three-valued would flip an unknown number of them), so an
# UNREADABLE registry and a registry with NO ROW both return non-zero here. Those
# are opposite facts: one is a policy answer, the other is a resource failure, and
# exit 10 "channel not enabled" asserts the first about both. That is #1189's own
# defect class — a resource failure wearing a security verdict — in a path neither
# issue touched. Ask the readability question SEPARATELY, before the boolean.
_reg="$(_remote_services_registry)"
if [ -e "$_reg" ] && ! _remote_reg_open_ok "$_reg"; then
    _es_log "REFUSED(7): services registry exists but is NOT READABLE"
    echo "remote-enroll-session: could not read the services registry — this is NOT a" >&2
    echo "                       statement about your enrollment; the endpoint could not" >&2
    echo "                       determine whether the channel is enabled." >&2
    exit 7
fi
_remote_registered || { _es_log "REFUSED(10): not registered"; echo "remote-enroll-session: channel not enabled." >&2; exit 10; }

# ── gate: SOURCE ADDRESS (your-org/nexus-code#609 item 4) ──────────────
# Same runtime enforcement of monitor.remote.from_cidr as the main forced
# command. It matters MORE here, not less: this is the endpoint that installs a
# new permanent credential, so an enrollment window reachable from outside the
# pinned source range is the widest form of the gap. Fail-closed on an
# undeterminable peer, exactly as in remote-forced-command.sh.
if ! _remote_source_guard; then
    _es_log "REFUSED(14): source address rejected: $_REMOTE_SRC_REASON"
    echo "remote-enroll-session: refused: source address rejected: $_REMOTE_SRC_REASON" >&2
    exit 14
fi

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
#
# TWO ARMS, NOT ONE. Validate the SHAPE of what came back before comparing it:
# a hash this machine could not compute is a statement about the machine, and
# `[[ -z … ]]` cannot tell that from a mismatch — nor can it tell either from a
# TRUNCATED hash, which is non-empty, compares unequal, and would be reported as
# a wrong token with total confidence. `^[0-9a-f]{64}$` is the property; empty
# is merely one way to fail it.
_tok_hash=$(_remote_hash_token "$TOKEN" 2>/dev/null) || _tok_hash=""
if [[ ! "$_tok_hash" =~ ^[0-9a-f]{64}$ ]]; then
    _es_log "REFUSED(6): could not compute a sha256 of the token on this machine (no verdict on the token)"
    echo "remote-enroll-session: internal error — could not compute the token hash on this machine." >&2
    echo "  Nothing was enrolled. This is NOT a statement about your token; retry, or report it." >&2
    exit 6
fi
if [[ "$_tok_hash" != "$HASH" ]]; then
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
# DO NOT FLATTEN THE CHILD'S rc (your-org/nexus-code#1189). remote-enroll.sh
# exits 3 for its token verdicts, 2 when `_safe_pubkey` rejects the staged key,
# and **1** from `die` — which covers `_ak_rmw`'s write errors (4/5/6) and
# `_with_ak_lock`'s flock timeout (9), i.e. exactly the conditions a loaded host
# produces. Collapsing all of those into one `exit 3` published a token verdict
# for a machine's shortcoming; each keeps its own arm now.
case "$rc" in
    3)
        _es_log "REFUSED(3): child token verdict — invalid/expired/replayed"
        echo "remote-enroll-session: enrollment failed — the token is invalid, expired, or already used." >&2
        exit 3 ;;
    2|*)
        # rc 2 lands here WITH the rest, deliberately. It is `_safe_pubkey`
        # declining the STAGED file — and the client's key type and blob were
        # already shape-checked above, so at this point a rejection is about the
        # staging (an unreadable temp file is one of _safe_pubkey's own rc-2
        # arms), not about anything the client sent. Calling it a client error
        # would be the same substitution this change exists to remove.
        _es_log "REFUSED(7): enrollment machinery failed, child rc $rc — NOT a verdict on the token"
        echo "remote-enroll-session: internal error — the enrollment could not be completed on this machine (stage $rc)." >&2
        echo "  Nothing was enrolled. This is NOT a statement about your token; retry, or report it." >&2
        exit 7 ;;
esac
