#!/usr/bin/env bash
# remote-forced-command.sh — the SSH forced-command dispatcher for the
# confined remote agent channel (agent-channel RFC Part A, §4.2 + §D.2/§D.4).
#
# THIS IS THE LOAD-BEARING CONFINEMENT. It is the single point where a
# remote string becomes an action, so it is a small, auditable allowlist
# `case` (the same discipline as the `gh` write-verb wrapper) that refuses
# anything outside it — never falling through to a shell.
#
# ── How it is wired ───────────────────────────────────────────────────
# Each authorized client gets ONE authorized_keys line of the form
#
#   command="<abs>/remote-forced-command.sh <principal>",restrict[,from="<cidr>"] <pubkey>
#
# `restrict` (modern OpenSSH) bundles no-pty,no-X11-forwarding,
# no-agent-forwarding,no-port-forwarding,no-user-rc — the §4.3 hardening.
# The PRINCIPAL is the FIRST POSITIONAL ARG, set server-side in
# authorized_keys — it is NEVER client-supplied (the client cannot change
# which key it logs in with, and the key fixes the principal). This is why
# we deliberately do NOT set a global `ForceCommand` in sshd_config: a
# global ForceCommand would shadow the per-key `command=` and erase the
# per-principal binding. Per-key `command=` is the correct, standard way to
# bind a forced command to a principal. (remote-sshd-supervised.sh §4.8.2.)
#
# When sshd runs this, the CLIENT's command string is in
# $SSH_ORIGINAL_COMMAND (the `command=` value runs; the client's string is
# NOT re-parsed by any shell — WE tokenize it, never `eval` it).
#
# ── The allowlist (the ONLY things a request-only principal may do) ────
#   request file  --kind K [--reply required|optional|none] [--priority normal|high]
#                 [--no-publish] --slug S (--message TEXT… | --message-stdin)
#       → ng request file  with `--origin remote-<principal>` FORCED.
#         Echoes the stable id (the client's correlation handle).
#   request await <id> [--timeout S]
#       → ng request await <id> --principal remote-<principal> (ownership-scoped).
#   request fetch <id> progress|results|status
#       → ng request fetch <id> SEL --principal remote-<principal> (path-confined).
#         `status` returns the rename-state word (new|claimed|replied|done|
#         failed) of the OWN request — read-only, ownership-checked, no path.
#   policy            → prints the FULL post-connect onboarding: the restrictions
#                       notice + the request-channel usage examples + the
#                       on-request capability-note template + the "why not C2"
#                       elaboration (read-only informational; no new capability).
#   help | onboarding → alias for `policy`; same full onboarding output.
#       This is the server-delivered half of the paste-length refactor: the
#       verbose usage material that used to live in the operator-pasted client
#       prompt is now retrieved over the channel post-connect. It RECAPS the
#       control contract but explicitly defers to the operator-supplied paste
#       as the source of consent (see _remote_onboarding_notice).
#   (bare connection, no command) → prints the LEAN policy notice, exit 0.
#       The notice INFORMS the client that broader access is obtained ONLY by
#       going through the client's OWN operator/channels (out-of-band) — there
#       is deliberately NO in-nexus verb that requests/grants an expansion,
#       so the nexus can never auto-expand without the operator's manual act.
#   attach   (opt-in: monitor.remote.allow_attach=true)
#       → a PINNED `tmux attach -t nexus -r` (read-only). Client args are
#         IGNORED — never forwarded — so the -r cannot be dropped nor the
#         target retargeted.
#
# Everything else (any other verb, any shell metacharacter that fails to
# match a token, --origin/--file/--principal smuggling, a newline, an
# unknown flag) FAILS CLOSED: refuse, log, exit non-zero. Never a shell.
#
# ── Exit codes ─────────────────────────────────────────────────────────
#   (passes through ng request's codes for file/await/fetch; see
#    request-channel.sh) plus:
#   10  service not registered (the channel is not enabled)
#   11  no / invalid principal (misconfigured authorized_keys command=)
#   12  refused: unknown verb / disallowed flag / malformed command
#   13  refused: attach not enabled, or tmux/ng not found

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=_remote_lib.sh
source "$_script_dir/_remote_lib.sh" || { echo "remote-forced-command: lib load failed" >&2; exit 12; }
# shellcheck source=_channel_lib.sh
source "$_script_dir/_channel_lib.sh" || { echo "remote-forced-command: channel lib load failed" >&2; exit 12; }

# Normalize to UTF-8 up front. sshd spawns this forced command with the
# DAEMON's environment (PermitUserEnvironment=no + no AcceptEnv → the client
# CANNOT set the locale), which is commonly C/POSIX. Force UTF-8 so the audit
# log, any _remote_lib awk, and — via the exec'd `ng request` — the body
# write all run consistently. The non-printable-byte guard below stays a
# deliberate `LC_ALL=C grep` (it must reject raw high bytes on the command
# line regardless of this), so this does not weaken the smuggling defense.
_chan_apply_utf8_locale

NG="$_script_dir/ng"

# Server ceiling on a client-held `await` (DoS: no unbounded session).
REMOTE_AWAIT_MAX_TIMEOUT="${REMOTE_AWAIT_MAX_TIMEOUT:-1800}"

# Audit log: every invocation (accepted OR refused) is recorded. Op-only
# location by default (principals_dir, 0700); overridable for tests. Body
# text is NEVER logged (it may carry task content) — only verb + id/slug.
_rc_logfile() {
    if [[ -n "${NEXUS_REMOTE_LOG:-}" ]]; then printf '%s' "$NEXUS_REMOTE_LOG"; return; fi
    printf '%s/forced-command.log' "$(_remote_principals_dir)"
}
_rc_log() {
    local lf; lf=$(_rc_logfile)
    local dir; dir=$(dirname "$lf")
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s principal=%s %s\n' "$(_remote_now)" "${PRINCIPAL:-?}" "$*" >> "$lf" 2>/dev/null || true
}
_remote_now() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?"; }

# Refuse: log the reason + the (truncated, body-free) verb, print to the
# client's stderr, exit with the given code. NEVER falls through.
refuse() {
    local code="$1"; shift
    _rc_log "REFUSED($code): $*"
    printf 'remote-forced-command: refused: %s\n' "$*" >&2
    exit "$code"
}

# ── the four allowlisted actions ──────────────────────────────────────
# Each receives the post-`request <sub>` tokens (or none, for attach),
# validates every field against a strict charset/enum, FORCES the origin /
# principal, and execs ng. No client token ever reaches a shell.

# request file …  →  ng request file --origin remote-<principal> …
_do_file() {
    local kind="" slug="" priority="" reply="" publish="" msg_mode=""
    local -a msg_words=()
    while (( $# > 0 )); do
        case "$1" in
            --kind)     kind="${2:-}";     shift 2 || refuse 12 "--kind needs a value" ;;
            --slug)     slug="${2:-}";     shift 2 || refuse 12 "--slug needs a value" ;;
            --priority) priority="${2:-}"; shift 2 || refuse 12 "--priority needs a value" ;;
            --reply)    reply="${2:-}";    shift 2 || refuse 12 "--reply needs a value" ;;
            --no-publish) publish="false"; shift ;;
            --message-stdin) msg_mode="stdin"; shift ;;
            --message)
                # Terminal flag: everything after --message is the message
                # body (joined by single spaces). This is the only way a
                # free-text body survives ssh's argv→string flattening
                # without a quoting nightmare; for byte-exact fidelity the
                # client uses --message-stdin instead.
                shift
                msg_mode="inline"
                msg_words=("$@")
                break
                ;;
            # Explicitly REFUSE the spoof / path / passthrough flags:
            --origin)    refuse 12 "--origin is forced server-side (cannot be client-supplied)" ;;
            --principal) refuse 12 "--principal is not accepted from a remote client" ;;
            --file)      refuse 12 "--file (server path) is not accepted; use --message / --message-stdin" ;;
            -)           refuse 12 "stdin sentinel '-' not accepted; use --message-stdin" ;;
            *) refuse 12 "request file: disallowed flag/argument: '$1'" ;;
        esac
    done
    [[ -n "$slug" ]] || refuse 12 "request file: --slug is required"
    [[ "$slug" =~ ^[A-Za-z0-9_-]+$ ]] || refuse 12 "request file: --slug must be [A-Za-z0-9_-]"
    [[ -n "$kind" ]] || kind="question"
    [[ "$kind" =~ ^[a-z][a-z0-9-]*$ ]] || refuse 12 "request file: --kind must be a kebab token"
    if [[ -n "$priority" ]]; then
        case "$priority" in normal|high) ;; *) refuse 12 "request file: --priority must be normal|high" ;; esac
    fi
    if [[ -n "$reply" ]]; then
        # `required` is the only value that changes behaviour; `optional`/`none`
        # are the DEFAULT (a reply is welcome, not demanded) and are accepted as
        # an explicit no-op — the `[--reply required]` help made an explicit
        # `optional` look natural, so honour it instead of refusing. Normalizing
        # to empty here means no `--reply` flag is forwarded to `ng request`.
        case "$reply" in
            required) ;;
            optional|none) reply="" ;;
            *) refuse 12 "request file: --reply accepts required|optional|none" ;;
        esac
    fi

    local -a args=(request file --origin "$ORIGIN" --kind "$kind" --slug "$slug")
    [[ -n "$priority" ]] && args+=(--priority "$priority")
    [[ -n "$reply"    ]] && args+=(--reply "$reply")
    [[ "$publish" == "false" ]] && args+=(--no-publish)

    _rc_log "request file slug=$slug kind=$kind reply=${reply:-none} publish=${publish:-true} msg=${msg_mode:-none}"
    case "$msg_mode" in
        stdin)
            # Stream the client's stdin as the body (byte-exact). The body
            # sentinel is a BARE `-` positional — NOT `--message -`: request
            # file's `--message` takes the NEXT token as LITERAL text, so
            # `--message -` persists the one-char body "-" and never reads
            # stdin (the bug that left 3 of 4 --message-stdin requests with an
            # empty "-" body). A lone `-` hits _chan_read_body's stdin branch
            # (`cat`), so the client's piped body is captured verbatim.
            args+=(-)
            exec "$NG" "${args[@]}"
            ;;
        inline)
            local msg="${msg_words[*]}"
            [[ -n "${msg//[[:space:]]/}" ]] || refuse 12 "request file: --message is empty"
            # A bare '-' body is ambiguous (ng would read stdin) and, with no
            # stdin attached, hangs the session — refuse it; use --message-stdin.
            [[ "$msg" == "-" ]] && refuse 12 "request file: ambiguous '-' body; use --message-stdin"
            args+=(--message "$msg")
            exec "$NG" "${args[@]}"
            ;;
        *)
            refuse 12 "request file: a body is required (--message TEXT… or --message-stdin)"
            ;;
    esac
}

# request await <id> [--timeout S]  →  ownership-scoped read of OWN reply
_do_await() {
    local id="${1:-}"
    [[ -n "$id" ]] || refuse 12 "request await: <id> required"
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || refuse 12 "request await: illegal id (must be [A-Za-z0-9_-])"
    shift
    local timeout=""
    while (( $# > 0 )); do
        case "$1" in
            --timeout) timeout="${2:-}"; shift 2 || refuse 12 "--timeout needs seconds" ;;
            --interval) refuse 12 "request await: --interval is server-controlled" ;;
            --principal) refuse 12 "request await: --principal is forced server-side" ;;
            *) refuse 12 "request await: disallowed flag/argument: '$1'" ;;
        esac
    done
    local -a args=(request await "$id" --principal "$ORIGIN")
    if [[ -n "$timeout" ]]; then
        [[ "$timeout" =~ ^[0-9]+$ ]] || refuse 12 "request await: --timeout must be an integer"
        # Clamp to the server ceiling so a client cannot hold a session open
        # arbitrarily long (DoS / session-slot exhaustion).
        (( timeout > REMOTE_AWAIT_MAX_TIMEOUT )) && timeout="$REMOTE_AWAIT_MAX_TIMEOUT"
        args+=(--timeout "$timeout")
    fi
    _rc_log "request await id=$id timeout=${timeout:-default}"
    exec "$NG" "${args[@]}"
}

# request fetch <id> progress|results|status  →  path-confined pull of OWN reply
# `status` is a READ-ONLY sub-mode of the SAME `fetch` verb (not a new
# top-level verb): it returns only the rename-state word of the client's own
# request, ownership-checked server-side exactly like progress/results, and
# names no path — so it widens the forced-command confinement by nothing. It
# lets a client watcher observe ACTIVE PROCESSING (`claimed`) and not close
# too early (agent-channel RFC §2.8, the rename-as-progress design).
_do_fetch() {
    local id="${1:-}" selector="${2:-}"
    [[ -n "$id" ]] || refuse 12 "request fetch: <id> required"
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || refuse 12 "request fetch: illegal id (must be [A-Za-z0-9_-])"
    case "$selector" in
        progress|results|status) ;;
        *) refuse 12 "request fetch: selector must be progress|results|status" ;;
    esac
    shift 2 || true
    # No further flags accepted (the selector is a fixed enum, never a path).
    (( $# == 0 )) || refuse 12 "request fetch: unexpected argument: '${1:-}'"
    _rc_log "request fetch id=$id selector=$selector"
    exec "$NG" request fetch "$id" "$selector" --principal "$ORIGIN"
}

# attach  →  PINNED read-only tmux attach (opt-in; client args ignored)
_do_attach() {
    _remote_allow_attach || refuse 13 "attach is disabled (monitor.remote.allow_attach != true; request-only posture)"
    command -v tmux >/dev/null 2>&1 || refuse 13 "tmux not found — cannot attach"
    local sess="${NEXUS_REMOTE_TMUX_SESSION:-nexus}"
    _rc_log "attach (read-only) session=$sess"
    # PINNED invocation. No client token is forwarded — the -r (read-only)
    # cannot be dropped and the target cannot be retargeted.
    exec tmux attach -t "$sess" -r
}

# ── gate 1: the channel must be registered (belt-and-suspenders, §4.8) ──
# A stray daemon left running after deregistration still cannot serve: the
# wrapper refuses unless the nexus-remote-ssh row is registered (the single
# enable signal). The healthcheck treats not-registered-as-healthy, so this
# is the last line, not the only one.
_remote_registered || refuse 10 "remote channel not registered (the service is not enabled)"

# ── gate 2: resolve + validate the server-pinned principal ────────────
PRINCIPAL="${1:-}"
if ! _remote_valid_principal "$PRINCIPAL"; then
    refuse 11 "missing/invalid principal in authorized_keys command= (got: '${PRINCIPAL}')"
fi
ORIGIN="remote-$PRINCIPAL"

# ── tokenize $SSH_ORIGINAL_COMMAND SAFELY (no eval, no glob, no subst) ──
CMD="${SSH_ORIGINAL_COMMAND:-}"
# A bare connection (no command) is INFORMATIONAL: print the policy notice
# (restrictions + options + how to request expansion) and exit 0 — so a
# client that just `ssh`es in learns what it may do and how to ask for more.
if [[ -z "$CMD" ]]; then
    _rc_log "policy notice (bare connection)"
    _remote_policy_notice "$PRINCIPAL"
    exit 0
fi
# A structured request command is a single line. Reject embedded newlines
# or NULs outright — they are the classic argument-smuggling vector and a
# legitimate command never contains them. (`read -ra` would stop at the
# first newline anyway; refusing makes the intent explicit + testable.)
case "$CMD" in
    *$'\n'*) refuse 12 "newline in command (argument smuggling)";;
esac
if printf '%s' "$CMD" | LC_ALL=C grep -q '[^[:print:][:space:]]'; then
    refuse 12 "non-printable byte in command"
fi
# `read -ra` performs ONLY IFS word-splitting: it does NOT expand $(…),
# backticks, ${…}, globs, or quotes. So `;`, `&&`, `$(rm -rf /)` become
# inert literal tokens that simply fail to match the allowlist below. Pin
# IFS to the standard whitespace set so a future sourced helper that
# mutated IFS cannot shift the splitting semantics out from under us.
IFS=$' \t\n'
read -ra ARGV <<<"$CMD"
(( ${#ARGV[@]} >= 1 )) || refuse 12 "no verb"

VERB="${ARGV[0]}"
SUB="${ARGV[1]:-}"

case "$VERB" in
    request)
        case "$SUB" in
            file)   _do_file   "${ARGV[@]:2}" ;;
            await)  _do_await  "${ARGV[@]:2}" ;;
            fetch)  _do_fetch  "${ARGV[@]:2}" ;;
            *) refuse 12 "unknown request subcommand: '${SUB}' (allowed: file|await|fetch)" ;;
        esac
        ;;
    policy|help|onboarding)
        # Discoverable self-description: the FULL post-connect onboarding
        # (restrictions notice + usage examples + capability-note template +
        # "why not C2" elaboration). Read-only informational — it adds no
        # capability and is identical under all three verb spellings. This is
        # the server-delivered material of the paste-length refactor; the
        # operator-pasted prompt points the client here for full usage.
        (( ${#ARGV[@]} <= 1 )) || refuse 12 "$VERB takes no arguments"
        _rc_log "onboarding notice (explicit verb: $VERB)"
        _remote_onboarding_notice "$PRINCIPAL"
        exit 0
        ;;
    attach)
        # Strict like the other verbs: attach takes NO arguments (the
        # invocation is fully pinned). Refuse extras rather than ignore them.
        (( ${#ARGV[@]} <= 1 )) || refuse 12 "attach takes no arguments"
        _do_attach
        ;;
    *)
        refuse 12 "unknown verb: '${VERB}' (allowed: request file|await|fetch; policy|help|onboarding; attach)"
        ;;
esac
