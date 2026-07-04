#!/usr/bin/env bash
# remote-enroll.sh — the `ng remote …` backend: out-of-band secret
# provisioning for the confined remote agent channel (agent-channel RFC
# §4.9). Generates the server host key, issues SINGLE-USE TTL'd enrollment
# tokens, consumes a token to authorize ONE client public key (writing the
# forced-command authorized_keys line), revokes a principal, and exposes
# the pre-write secret grep guard.
#
# ── THE SECURITY CONTRACT ─────────────────────────────────────────────
#   * NO subcommand here EVER calls a GitHub verb or writes under reports/.
#     Secrets travel ONLY out-of-band: a token is printed to THIS session's
#     stdout (the orchestrator reads it and hands it to the operator), or
#     written to a 0600 op-only file. NEVER a PR/issue/comment/log/commit.
#   * The enrollment token is recorded HASHED (sha256) — the on-disk
#     pending-token file is not itself a usable secret.
#   * A token is consumed (deleted) on first successful enroll; a replay or
#     an expired token FAILS CLOSED.
#   * The authorized_keys line is reconstructed SERVER-SIDE from the key
#     type + blob ONLY — any options/comment in the supplied .pub are
#     discarded, so a client cannot smuggle its own `command=`/options.
#
# ── Subcommands ───────────────────────────────────────────────────────
#   gen-host-key                generate the ed25519 host key (idempotent);
#                               print its fingerprint (non-secret)
#   host-fingerprint            print the host-key fingerprint (non-secret)
#   issue-token --principal P [--ttl S]
#                               mint a one-time token (printed to stdout,
#                               OUT-OF-BAND ONLY); record it hashed+TTL'd
#   enroll --pubkey F --token T [--principal P]
#                               consume T → append the forced-command
#                               authorized_keys line for its principal
#   enroll-invite --principal P [--ttl S]
#                               ROOTLESS token-gated SELF-enroll bootstrap:
#                               mint a one-time token + a throwaway per-window
#                               enroll-only keypair, install the enroll-only
#                               authorized_keys line, and print {token, enroll
#                               PRIVATE key} to stdout (OUT-OF-BAND only). The
#                               client connects with the enroll key and pipes
#                               <token>\n<its-own-pubkey> to self-enroll. Needed
#                               because an in-sandbox (non-root) sshd cannot use
#                               AuthorizedKeysCommand (root-owned requirement,
#                               unattainable in the sandbox userns).
#   prune-enroll                remove enroll-only lines whose token is
#                               consumed/expired (enroll window == token window)
#   revoke --principal P        remove P's authorized_keys line(s)
#   list                        list enrolled principals (non-secret)
#   carrier-authline --pubkey F|- [--port P]
#                               emit the restricted authorized_keys line for
#                               the OFF-HOST forward-only carrier (the operator
#                               installs it on the carrier host, OUTSIDE the
#                               sandbox). Grants the client ONLY a port-forward
#                               to the nexus loopback port — no shell, no other
#                               forward target. NON-secret (pubkey+options).
#   guard [FILE]                pre-write secret grep guard (FILE or stdin);
#                               exit 3 if a secret-shaped string is found
#
# Exit codes: 0 ok · 1 usage · 2 not-found/missing · 3 guard tripped /
#   token invalid/expired/replayed · 4 dependency missing (ssh-keygen).

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_remote_lib.sh
source "$_script_dir/_remote_lib.sh"

WRAPPER="$_script_dir/remote-forced-command.sh"
SESSION="$_script_dir/remote-enroll-session.sh"

die()  { printf 'remote-enroll: %s\n' "$*" >&2; exit 1; }
warn() { printf 'remote-enroll: %s\n' "$*" >&2; }
now_epoch() { date +%s; }

# principals_dir, created 0700 (op-only) — the secret material's home,
# OUTSIDE the GitHub-tracked tree. umask 077 closes the create-then-chmod
# window so dirs/files are born restricted (no 0755/0644 interval).
_ensure_principals_dir() {
    umask 077
    local d; d=$(_remote_principals_dir)
    mkdir -p "$d" 2>/dev/null || die "cannot create principals_dir: $d"
    chmod 700 "$d" 2>/dev/null || true
    mkdir -p "$d/enroll" 2>/dev/null || true
    chmod 700 "$d/enroll" 2>/dev/null || true
    printf '%s' "$d"
}

HOST_KEY_NAME="ssh_host_ed25519_key"

# ── authorized_keys read-modify-write, serialized + atomic ────────────
# _ak_rmw <ak> <marker> [<line>] : drop every line containing <marker>
# (literal), then append <line> if given. temp + mv -f = atomic swap.
_ak_rmw() {
    local ak="$1" marker="$2" line="${3:-}" tmp
    touch "$ak" 2>/dev/null || return 4
    chmod 600 "$ak" 2>/dev/null || true
    tmp=$(mktemp "$ak.XXXXXX") || return 5
    grep -v -F "$marker" "$ak" > "$tmp" 2>/dev/null || true
    [[ -n "$line" ]] && printf '%s\n' "$line" >> "$tmp"
    mv -f "$tmp" "$ak" || { rm -f "$tmp"; return 6; }
    chmod 600 "$ak" 2>/dev/null || true
}

# Run an authorized_keys mutation ("$@") under an exclusive flock (when
# flock is present); else run it directly. The lock serializes concurrent
# enroll/revoke so neither loses an update nor resurrects a revoked key.
_with_ak_lock() {
    local d; d=$(_remote_principals_dir)
    local lock="$d/.authorized_keys.lock"
    if command -v flock >/dev/null 2>&1; then
        ( flock -w 10 200 || exit 9; "$@" ) 200>>"$lock"
    else
        "$@"
    fi
}

# ── gen-host-key ──────────────────────────────────────────────────────
cmd_gen_host_key() {
    command -v ssh-keygen >/dev/null 2>&1 || { warn "ssh-keygen not found"; exit 4; }
    local d; d=$(_ensure_principals_dir)
    local key="$d/$HOST_KEY_NAME"
    if [[ -f "$key" ]]; then
        say_fp "$key"
        return 0
    fi
    # -N '' = no passphrase (a service host key); the PRIVATE key never
    # leaves principals_dir. Comment is non-secret.
    ssh-keygen -t ed25519 -f "$key" -N '' -C "nexus-remote-host" >/dev/null 2>&1 \
        || die "ssh-keygen failed for $key"
    chmod 600 "$key" 2>/dev/null || true
    [[ -f "$key.pub" ]] && chmod 644 "$key.pub" 2>/dev/null || true
    warn "generated host key: $key (private key stays in-sandbox, 0600)"
    say_fp "$key"
}

say_fp() {
    local key="$1"
    command -v ssh-keygen >/dev/null 2>&1 || return 0
    [[ -f "$key.pub" ]] || return 0
    # Fingerprint is NON-secret; printed for the operator to pin (§4.10).
    ssh-keygen -lf "$key.pub" 2>/dev/null || true
}

cmd_host_fingerprint() {
    local d; d=$(_remote_principals_dir)
    local key="$d/$HOST_KEY_NAME"
    [[ -f "$key.pub" ]] || { warn "no host key yet ($key.pub) — run: ng remote gen-host-key"; exit 2; }
    say_fp "$key"
}

# Mint one token: generate the secret, record it HASHED (filename) + principal
# + expiry under enroll/, and echo the PLAINTEXT token on stdout (the ONLY copy;
# out-of-band surface). Assumes principal + ttl are already validated. Shared by
# `issue-token` and `enroll-invite`. Returns non-zero (die) on failure.
_mint_token() {
    local principal="$1" ttl="$2"
    local d; d=$(_ensure_principals_dir)
    local tok; tok=$(_remote_gen_token) || die "issue-token: could not generate randomness (need openssl or /dev/urandom)"
    local hash; hash=$(_remote_hash_token "$tok") || die "issue-token: could not hash token (need sha256sum/shasum/openssl)"
    local expires=$(( $(now_epoch) + ttl ))
    local rec="$d/enroll/$hash.token"
    # Record HASH only (filename) + principal + expiry. The plaintext token
    # is NEVER written to disk — only emitted to stdout.
    { printf 'principal=%s\n' "$principal"; printf 'expires=%s\n' "$expires"; } > "$rec" \
        || die "issue-token: cannot write pending record"
    chmod 600 "$rec" 2>/dev/null || true
    printf '%s' "$tok"
}

# ── issue-token ───────────────────────────────────────────────────────
cmd_issue_token() {
    local principal="" ttl=""
    while (( $# > 0 )); do
        case "$1" in
            --principal) principal="${2:-}"; shift 2 || die "--principal needs a value" ;;
            --ttl)       ttl="${2:-}";       shift 2 || die "--ttl needs seconds" ;;
            *) die "issue-token: unknown flag: $1" ;;
        esac
    done
    _remote_valid_principal "$principal" || die "issue-token: --principal must be [A-Za-z0-9_-] (got: '$principal')"
    [[ -z "$ttl" ]] && ttl=$(_remote_ttl)
    [[ "$ttl" =~ ^[0-9]+$ ]] || die "issue-token: --ttl must be an integer"
    # A "one-time" token must stay short-lived: reject 0 (degenerate) and
    # cap at a ceiling so an intercepted token's replay window is bounded.
    local ttl_max="${REMOTE_TOKEN_TTL_MAX:-86400}"   # 24h hard ceiling
    (( ttl >= 1 )) || die "issue-token: --ttl must be >= 1"
    (( ttl <= ttl_max )) || die "issue-token: --ttl exceeds the ${ttl_max}s ceiling (one-time tokens are short-lived)"

    local tok; tok=$(_mint_token "$principal" "$ttl") || exit $?

    warn "issued one-time token for principal '$principal' (TTL ${ttl}s; single-use)."
    warn "  Deliver OUT-OF-BAND only (read it from THIS session, or copy to a 0600 file)."
    warn "  It is NEVER posted to GitHub. The plaintext below is the ONLY copy."
    # The token plaintext → stdout (the out-of-band surface). Caller must
    # not pipe this into any GitHub write (the guard backstops that).
    printf '%s\n' "$tok"
}

# Parse a public-key file SAFELY: return "<type> <blob>" from the first
# key line, discarding ANY leading options and trailing comment so a
# client-supplied .pub cannot inject authorized_keys options. Refuses if
# no valid key type is found or more than one key line is present.
_safe_pubkey() {
    local file="$1"
    [[ -r "$file" ]] || { warn "pubkey file not readable: $file"; return 2; }
    local line keycount=0 out=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        # Tokenize; find the first token that is a known key type.
        local -a toks; read -ra toks <<<"$line"
        local i type="" blob=""
        for (( i=0; i<${#toks[@]}; i++ )); do
            case "${toks[$i]}" in
                ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
                    type="${toks[$i]}"; blob="${toks[$((i+1))]:-}"; break ;;
            esac
        done
        [[ -n "$type" && -n "$blob" ]] || { warn "no recognizable public key in: $file"; return 2; }
        # blob must be base64 (the key material) — reject anything else.
        [[ "$blob" =~ ^[A-Za-z0-9+/]+=*$ ]] || { warn "malformed key blob in: $file"; return 2; }
        keycount=$(( keycount + 1 ))
        out="$type $blob"
    done < "$file"
    (( keycount == 1 )) || { warn "expected exactly one public key in $file (found $keycount)"; return 2; }
    printf '%s' "$out"
}

# ── enroll ────────────────────────────────────────────────────────────
cmd_enroll() {
    local pubkey="" token="" principal="" token_stdin=0
    while (( $# > 0 )); do
        case "$1" in
            --pubkey)    pubkey="${2:-}";    shift 2 || die "--pubkey needs a file" ;;
            --token)     token="${2:-}";     shift 2 || die "--token needs a value" ;;
            # Read the one-time token from STDIN (first line) instead of argv,
            # so the secret never appears in this process's argv / ps / the
            # parent's child-argv. Used by the self-enroll session (§4.9.1).
            --token-stdin) token_stdin=1;    shift ;;
            --principal) principal="${2:-}"; shift 2 || die "--principal needs a value" ;;
            *) die "enroll: unknown flag: $1" ;;
        esac
    done
    if (( token_stdin )); then
        [[ -z "$token" ]] || die "enroll: pass either --token or --token-stdin, not both"
        IFS= read -r token || true
        token="${token%$'\r'}"
    fi
    [[ -n "$pubkey" ]] || die "enroll: --pubkey <file> required"
    [[ -n "$token"  ]] || die "enroll: --token <one-time-token> required (or --token-stdin)"
    [[ -x "$WRAPPER" ]] || die "enroll: forced-command wrapper missing: $WRAPPER"

    # Validate + consume the token (single-use, TTL).
    local hash; hash=$(_remote_hash_token "$token") || die "enroll: cannot hash token"
    local d; d=$(_ensure_principals_dir)
    local rec="$d/enroll/$hash.token"
    # ATOMIC consume: claim the record by renaming it. `mv` is the
    # test-and-claim — exactly ONE concurrent enroll can move the file; the
    # loser's `mv` fails (source already gone) and exits 3. `rm -f` would
    # NOT be atomic (it returns 0 whether or not it removed anything), so
    # two racers could both pass an existence check. Read principal/expiry
    # from the claimed copy; a replay of a spent token finds nothing to mv.
    local claimed="$rec.consumed.$$"
    if ! mv "$rec" "$claimed" 2>/dev/null; then
        warn "enroll: token invalid, already used, or never issued (fail-closed)"; exit 3
    fi
    local rec_principal rec_expires
    rec_principal=$(_kv_get "$claimed" principal)
    rec_expires=$(_kv_get "$claimed" expires)
    rm -f "$claimed"
    [[ "$rec_expires" =~ ^[0-9]+$ ]] || { warn "enroll: corrupt token record"; exit 3; }
    if (( $(now_epoch) > rec_expires )); then
        warn "enroll: token EXPIRED (fail-closed); issue a fresh one"; exit 3
    fi
    _remote_valid_principal "$rec_principal" || { warn "enroll: corrupt principal in token record"; exit 3; }
    if [[ -n "$principal" && "$principal" != "$rec_principal" ]]; then
        warn "enroll: --principal '$principal' does not match the token's bound principal '$rec_principal' (fail-closed)"
        exit 3
    fi
    principal="$rec_principal"

    # Parse the pubkey SAFELY (server reconstructs the line; no client options).
    local keypair; keypair=$(_safe_pubkey "$pubkey") || exit 2

    # Build the authorized_keys line PER COMMAND POLICY (RFC §4.2).
    local from_cidr; from_cidr=$(_remote_from_cidr)
    local from_opt=""
    if [[ -n "$from_cidr" ]]; then
        # crude CIDR/host sanity (no spaces, no quotes) — defence in depth.
        [[ "$from_cidr" =~ ^[0-9A-Fa-f:.*/_,-]+$ ]] || die "enroll: from_cidr has illegal characters: $from_cidr"
        from_opt="from=\"$from_cidr\""
    fi
    local policy; policy=$(_remote_command_policy)
    local ak="$d/authorized_keys" line
    if [[ "$policy" == unfiltered ]]; then
        # TRUST mode: no forced command, no `restrict` — the key gets a
        # normal sandbox-confined login shell (arbitrary commands). The
        # kernel sandbox + the sshd transport hardening remain the controls;
        # we relax only the in-sandbox command filter, never the sandbox.
        if [[ -n "$from_opt" ]]; then
            printf -v line '%s %s %s@nexus-remote' "$from_opt" "$keypair" "$principal"
        else
            printf -v line '%s %s@nexus-remote' "$keypair" "$principal"
        fi
    else
        # channel-only (default): forced command + `restrict` (the §4.3
        # hardening: no-pty,no-*-forwarding,no-user-rc) + optional from=.
        local opts="command=\"$WRAPPER $principal\",restrict"
        [[ -n "$from_opt" ]] && opts="$opts,$from_opt"
        printf -v line '%s %s %s@nexus-remote' "$opts" "$keypair" "$principal"
        # HIGH invariant: a channel-only line MUST carry the forced command
        # (a command=-less line would grant a shell, defeating the policy).
        case "$line" in command=\"*) ;; *) die "enroll: refusing a command=-less channel-only authorized_keys line (would grant a shell)";; esac
    fi
    # Identity marker present in BOTH policies: the trailing principal
    # comment. Leading space prevents a prefix collision (alicebob vs bob).
    # Serialize the read-modify-write under flock so a concurrent
    # enroll/revoke cannot lose an update or RESURRECT a revoked key.
    _with_ak_lock _ak_rmw "$ak" " $principal@nexus-remote" "$line" \
        || die "enroll: failed to update authorized_keys (lock timeout or write error)"

    local mode_desc="channel-only (forced-command, request-only)"
    [[ "$policy" == unfiltered ]] && mode_desc="unfiltered (sandbox-confined SHELL — arbitrary commands)"
    warn "enrolled principal '$principal' — policy: $mode_desc${from_cidr:+, from=$from_cidr}. Token consumed."
    warn "  Authorized: $ak"
    warn "  The client connects with its PRIVATE key (which never left its host)."
}

# ── enroll-invite ─────────────────────────────────────────────────────
# The ROOTLESS token-gated self-enroll bootstrap (RFC §4.9.1). An in-sandbox
# sshd is NON-root and CANNOT use AuthorizedKeysCommand: OpenSSH's
# auth_secure_path requires the command owned by uid 0, and the sandbox user
# namespace has NO uid-0-owned files (real root maps to `nobody`). So the
# dynamic-key AKC path is impossible here — proven empirically. Instead we mint,
# per enrollment window, a THROWAWAY enroll-only keypair and install its PUBLIC
# key as a token-hash-tagged, enroll-only authorized_keys line — riding the one
# rootless key primitive (AuthorizedKeysFile) that already backs the channel.
#
# The operator hands the client, OUT-OF-BAND, {one-time token, enroll PRIVATE
# key, host fingerprint}. The client connects with the enroll key and pipes
#   <token>\n<its-own-public-key>\n
# to the enroll-only session (remote-enroll-session.sh), which token-gates,
# server-reconstructs the permanent channel-only line for the CLIENT key, then
# removes this enroll line. The client reconnects with ITS OWN key thereafter.
#
# Security invariants (preserved from the AKC design; a skeptic checks these):
#   * The enroll PRIVATE key is emitted to stdout (out-of-band) and NEVER
#     persisted at rest — only the enroll PUBLIC key lives in authorized_keys,
#     and only while its token is live (removed on consume, pruned on expiry).
#     Outside a token window the enroll line is GONE → an unknown key is denied
#     at the SSH layer, the same posture the AKC pending-token gate gave.
#   * Enrollment does NOT widen access: the resulting client line carries the
#     SAME command="<wrapper> <principal>",restrict[,from=…] as a manual enroll;
#     the enroll session grants NO shell/channel verbs (enroll-only forced cmd).
#   * Token stays single-use + TTL'd + sha256-at-rest + fail-closed; the client
#     pubkey is server-reconstructed (_safe_pubkey), so smuggled options/comment
#     are stripped.
cmd_enroll_invite() {
    local principal="" ttl=""
    while (( $# > 0 )); do
        case "$1" in
            --principal) principal="${2:-}"; shift 2 || die "--principal needs a value" ;;
            --ttl)       ttl="${2:-}";       shift 2 || die "--ttl needs seconds" ;;
            *) die "enroll-invite: unknown flag: $1" ;;
        esac
    done
    _remote_valid_principal "$principal" || die "enroll-invite: --principal must be [A-Za-z0-9_-] (got: '$principal')"
    _remote_self_enroll || die "enroll-invite: self-enroll is disabled (monitor.remote.self_enroll=false) — use 'enroll' for manual enrollment"
    command -v ssh-keygen >/dev/null 2>&1 || { warn "ssh-keygen not found"; exit 4; }
    [[ -x "$SESSION" ]] || die "enroll-invite: enroll session missing/not executable: $SESSION"
    [[ -z "$ttl" ]] && ttl=$(_remote_ttl)
    [[ "$ttl" =~ ^[0-9]+$ ]] || die "enroll-invite: --ttl must be an integer"
    local ttl_max="${REMOTE_TOKEN_TTL_MAX:-86400}"
    (( ttl >= 1 )) || die "enroll-invite: --ttl must be >= 1"
    (( ttl <= ttl_max )) || die "enroll-invite: --ttl exceeds the ${ttl_max}s ceiling"

    local d; d=$(_ensure_principals_dir)
    # Optional from= pin (mirror cmd_enroll): the enroll line AND the resulting
    # channel line are pinned to the same source range.
    local from_cidr; from_cidr=$(_remote_from_cidr)
    local from_opt=""
    if [[ -n "$from_cidr" ]]; then
        [[ "$from_cidr" =~ ^[0-9A-Fa-f:.*/_,-]+$ ]] || die "enroll-invite: from_cidr has illegal characters: $from_cidr"
        from_opt="from=\"$from_cidr\""
    fi

    # Mint the token first — its hash tags the enroll line + is baked into the
    # enroll session's forced command (binding the enroll key to this token).
    local tok; tok=$(_mint_token "$principal" "$ttl") || exit $?
    local hash; hash=$(_remote_hash_token "$tok") || die "enroll-invite: cannot hash token"

    # Throwaway enroll keypair (private key NEVER persisted past this call).
    umask 077
    local tmpd; tmpd=$(mktemp -d "$d/.enrollkey.XXXXXX") || die "enroll-invite: mktemp failed"
    ssh-keygen -t ed25519 -f "$tmpd/k" -N '' -C "enroll-$hash" >/dev/null 2>&1 \
        || { rm -rf "$tmpd"; die "enroll-invite: ssh-keygen failed"; }
    local epub; epub=$(_safe_pubkey "$tmpd/k.pub") || { rm -rf "$tmpd"; exit 2; }

    # Enroll-ONLY authorized_keys line: forced command = the enroll session with
    # the token hash baked, + restrict + optional from=. Marker = the trailing
    # enroll-<hash>@nexus-remote comment (used by enroll/prune to remove it).
    local opts="command=\"$SESSION $hash\",restrict"
    [[ -n "$from_opt" ]] && opts="$opts,$from_opt"
    local line; printf -v line '%s %s enroll-%s@nexus-remote' "$opts" "$epub" "$hash"
    case "$line" in command=\"*) ;; *) rm -rf "$tmpd"; die "enroll-invite: refusing a command=-less enroll line" ;; esac
    local ak="$d/authorized_keys"
    _with_ak_lock _ak_rmw "$ak" " enroll-$hash@nexus-remote" "$line" \
        || { rm -rf "$tmpd"; die "enroll-invite: failed to write enroll line (lock timeout or write error)"; }

    warn "enroll-invite for '$principal' (TTL ${ttl}s, single-use). Deliver OUT-OF-BAND only — NEVER GitHub."
    warn "  The client connects with the enroll PRIVATE key below and pipes:  <token>\\n<its client .pub>"
    warn "    printf '%%s\\n%%s\\n' \"\$TOKEN\" \"\$(cat client.pub)\" | ssh -T -i enroll_key -p <port> $USER@<host>"
    warn "  On success the client's own key is enrolled (channel-only); reconnect with it."
    # OUT-OF-BAND payload → stdout ONLY. The plaintext token + enroll private key
    # are the ONLY copies (the private key is shredded from disk immediately).
    printf 'REMOTE_ENROLL_TOKEN=%s\n' "$tok"
    printf -- '-----BEGIN NEXUS ENROLL PRIVATE KEY (out-of-band only; never GitHub)-----\n'
    cat "$tmpd/k"
    printf -- '-----END NEXUS ENROLL PRIVATE KEY-----\n'
    command -v shred >/dev/null 2>&1 && shred -u "$tmpd/k" 2>/dev/null
    rm -rf "$tmpd"
}

# ── prune-enroll ──────────────────────────────────────────────────────
# Remove every enroll-only line whose backing token is no longer live (consumed
# → record gone, or expired). Idempotent; safe to call from the supervisor loop
# and the healthcheck. This keeps the enroll window == the token window, so an
# unknown key is denied at the SSH layer once no token is pending — the property
# the (impossible-here) AuthorizedKeysCommand pending-token gate used to give.
cmd_prune_enroll() {
    local d; d=$(_remote_principals_dir)
    local ak="$d/authorized_keys"
    [[ -f "$ak" ]] || return 0
    local h removed=0
    while IFS= read -r h; do
        [[ -n "$h" ]] || continue
        _remote_token_hash_live "$h" && continue    # keep: token still live
        _with_ak_lock _ak_rmw "$ak" " enroll-$h@nexus-remote" "" && removed=$((removed+1))
    done < <(grep -oE 'enroll-[0-9a-f]{64}@nexus-remote' "$ak" 2>/dev/null \
                 | sed -E 's/^enroll-//; s/@nexus-remote$//' | sort -u)
    (( removed > 0 )) && warn "prune-enroll: removed $removed stale enroll line(s)"
    return 0
}

# ── carrier-authline ──────────────────────────────────────────────────
# Emit the restricted authorized_keys line for the OFF-HOST FORWARD-ONLY
# CARRIER. The nexus sshd binds loopback (127.0.0.1:<port>) INSIDE the
# sandbox; an off-host client cannot reach that loopback directly. The only
# route is to SSH into the carrier host (the node this sandbox runs on) and
# local-forward to 127.0.0.1:<port>. Riding the operator's full :22 login to
# do that hands the client a SHELL on the carrier host — over-privileged for a
# peer that only needs the forward. This line locks ONE client key to ONE
# capability: forward to the nexus loopback port, nothing else.
#
# THE OPERATOR installs this line (append to ~/.ssh/authorized_keys on the
# carrier host, OUTSIDE the sandbox — the agent cannot write there). The line
# is NON-secret (a public key + restriction options); it is safe to relay to
# the operator out-of-band, but per convention it is NOT posted to GitHub.
#
# Restriction set (OpenSSH 7.2+ modern form, the default):
#   restrict            disable EVERYTHING (pty, agent-fwd, X11-fwd, user-rc,
#                       AND all port forwarding) — minimal authority baseline.
#   port-forwarding     re-enable ONLY forwarding (so -L can work at all).
#   permitopen=         confine every -L/-D forward DESTINATION to exactly the
#                       nexus loopback target; any other target is refused.
#   command="…; exit 1" THE NO-SHELL BELT. CRITICAL: `restrict` (and no-pty)
#                       do NOT block command execution — they only deny an
#                       interactive PTY. A client that drops `-N` could still
#                       run `ssh carrier <cmd>` and execute it. The forced
#                       command closes that hole: ANY shell/exec request runs
#                       this harmless no-op instead. The legitimate client uses
#                       `ssh -N` (no exec channel requested), so the forced
#                       command never fires and the -L forward persists. So the
#                       belt costs the legit path nothing and denies exec to a
#                       non-cooperative one. Omit with --no-shell-belt ONLY if
#                       the carrier account's login shell is itself /usr/sbin/
#                       nologin (a dedicated carrier account), which makes the
#                       belt redundant; on a normal account (e.g. the operator's
#                       own) the belt is REQUIRED to deny a shell.
cmd_carrier_authline() {
    local pubkey="" port="" comment="nexus-remote-carrier" explicit=0 shell_belt=1
    while (( $# > 0 )); do
        case "$1" in
            --pubkey)        pubkey="${2:-}";  shift 2 || die "--pubkey needs <file|->" ;;
            --port)          port="${2:-}";    shift 2 || die "--port needs a value" ;;
            --comment)       comment="${2:-}"; shift 2 || die "--comment needs a value" ;;
            # sshd < 7.2 fallback: spell out the no-* options `restrict` bundles.
            --explicit)      explicit=1;  shift ;;
            # Drop the forced-command no-shell belt (literal minimal form). SAFE
            # ONLY when the carrier account's shell is nologin; else it permits
            # non-interactive command execution. Documented + loud.
            --no-shell-belt) shell_belt=0; shift ;;
            *) die "carrier-authline: unknown flag: $1" ;;
        esac
    done
    [[ -n "$pubkey" ]] || die "carrier-authline: --pubkey <file|-> required"
    [[ -z "$port" ]] && port=$(_remote_port)
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
        || die "carrier-authline: --port must be an integer 1..65535 (got: '$port')"
    # The comment is the trailing identity field; defang to a safe charset so
    # it can never smuggle a space + option (defense in depth — it is the LAST
    # field and reconstructed by us, but validate anyway).
    [[ "$comment" =~ ^[A-Za-z0-9_@.:-]+$ ]] \
        || die "carrier-authline: --comment must be [A-Za-z0-9_@.:-] (got: '$comment')"

    # Parse the pubkey SAFELY: reconstruct from keytype+blob ONLY, discarding
    # any options/comment the client may have smuggled into its .pub — mirror
    # the server-side _safe_pubkey hardening used by enroll, so a client cannot
    # inject its own authorized_keys options through carrier-authline either.
    local keypair
    if [[ "$pubkey" == "-" ]]; then
        local tmp; tmp=$(mktemp) || die "carrier-authline: mktemp failed"
        cat > "$tmp"
        keypair=$(_safe_pubkey "$tmp"); local rc=$?
        rm -f "$tmp"
        (( rc == 0 )) || exit 2
    else
        keypair=$(_safe_pubkey "$pubkey") || exit 2
    fi

    # Build the restriction option set.
    local base
    if (( explicit )); then
        # No `restrict`: forwarding is enabled by default and constrained by
        # permitopen; spell out the no-* options restrict would have bundled.
        base='no-pty,no-agent-forwarding,no-X11-forwarding,no-user-rc'
    else
        base='restrict,port-forwarding'
    fi
    local opts="$base,permitopen=\"127.0.0.1:$port\""
    if (( shell_belt )); then
        # No comma inside the message (a bare comma inside a quoted option value
        # is fine for sshd, but we keep it out for parser-robustness across tools).
        opts="$opts,command=\"echo 'forward-only nexus carrier: no shell - port-forward only' >&2; exit 1\""
    fi

    # stdout = the single line (pipe-safe); the usage note goes to stderr.
    printf '%s %s %s\n' "$opts" "$keypair" "$comment"

    warn "carrier-authline: append the ONE line above to ~/.ssh/authorized_keys on the"
    warn "  CARRIER HOST (the node this sandbox runs on), OUTSIDE the sandbox. It grants"
    warn "  the client's key ONLY a port-forward to the nexus channel (127.0.0.1:$port) —"
    warn "  no shell, no command, no other forward target, no pty/agent/X11. NON-secret"
    warn "  (public key + options): relay out-of-band; do NOT post it to GitHub."
    if (( shell_belt )); then
        warn "  The forced command is the no-shell belt: the client connects with"
        warn "  'ssh -N -L $port:127.0.0.1:$port [-J <jump>] <user>@<carrier-host>'."
    else
        warn "  --no-shell-belt: NO forced command — SAFE ONLY if the carrier account's"
        warn "  login shell is /usr/sbin/nologin; otherwise this permits command execution."
    fi
}

# ── revoke ────────────────────────────────────────────────────────────
cmd_revoke() {
    local principal=""
    while (( $# > 0 )); do
        case "$1" in
            --principal) principal="${2:-}"; shift 2 || die "--principal needs a value" ;;
            *) die "revoke: unknown flag: $1" ;;
        esac
    done
    _remote_valid_principal "$principal" || die "revoke: --principal must be [A-Za-z0-9_-]"
    local d; d=$(_remote_principals_dir)
    local ak="$d/authorized_keys"
    [[ -f "$ak" ]] || { warn "revoke: no authorized_keys at $ak — nothing to revoke"; return 0; }
    local before after
    before=$(wc -l < "$ak" 2>/dev/null || echo 0)
    # Match the principal's trailing comment (present in BOTH policies) so
    # revoke works whether the line was channel-only or unfiltered. Leading
    # space prevents a prefix collision (alicebob vs bob).
    _with_ak_lock _ak_rmw "$ak" " $principal@nexus-remote" \
        || die "revoke: failed to rewrite authorized_keys (lock timeout or write error)"
    after=$(wc -l < "$ak" 2>/dev/null || echo 0)
    warn "revoke: removed $(( before - after )) line(s) for principal '$principal' (no service restart needed)"
}

# ── list ──────────────────────────────────────────────────────────────
cmd_list() {
    local d; d=$(_remote_principals_dir)
    local ak="$d/authorized_keys"
    [[ -f "$ak" ]] || { warn "no authorized_keys at $ak (no principals enrolled)"; return 0; }
    # Extract the principal from each line's trailing `<principal>@nexus-remote`
    # comment (present in BOTH policies). Non-secret (names only; no key
    # material printed).
    local line p
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip transient per-window enroll-only lines (enroll-<hash>@nexus-remote);
        # they are not enrolled principals.
        [[ "$line" == *enroll-[0-9a-f]*@nexus-remote* ]] && continue
        [[ "$line" =~ ([A-Za-z0-9_-]+)@nexus-remote ]] || continue
        p="${BASH_REMATCH[1]}"
        printf '%s\n' "$p"
    done < "$ak"
}

# ── guard (pre-write secret scan) ─────────────────────────────────────
cmd_guard() {
    local file="${1:-}"
    if [[ -n "$file" ]]; then
        _remote_secret_guard "$file"
    else
        _remote_secret_guard
    fi
}

# ── dispatch ──────────────────────────────────────────────────────────
sub="${1:-}"; shift || true
case "$sub" in
    gen-host-key)     cmd_gen_host_key "$@" ;;
    host-fingerprint) cmd_host_fingerprint "$@" ;;
    issue-token)      cmd_issue_token "$@" ;;
    enroll)           cmd_enroll "$@" ;;
    enroll-invite)    cmd_enroll_invite "$@" ;;
    prune-enroll)     cmd_prune_enroll "$@" ;;
    revoke)           cmd_revoke "$@" ;;
    list)             cmd_list "$@" ;;
    carrier-authline) cmd_carrier_authline "$@" ;;
    guard)            cmd_guard "$@" ;;
    ""|-h|--help)
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        [[ -z "$sub" ]] && exit 1 || exit 0 ;;
    *) die "unknown subcommand: $sub (gen-host-key|host-fingerprint|issue-token|enroll|enroll-invite|prune-enroll|revoke|list|carrier-authline|guard)" ;;
esac
