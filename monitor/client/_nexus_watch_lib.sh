# _nexus_watch_lib.sh — shared POSIX-sh core for the CLIENT-SIDE confined
# nexus request/reply tooling: nexus-reply-watch (#400) and nexus-request.
#
# ┌────────────────────────────────────────────────────────────────────────┐
# │ SECURITY INVARIANT — load-bearing, the skeptic enforces it:            │
# │   Every function here treats reply/request bytes as DATA. There is no  │
# │   `eval`, no `.`/`source` of channel bytes, no `| sh|bash`, no `$(…)`  │
# │   wrapping channel content into a command position, no `chmod +x`, no  │
# │   `exec`, no cron/at/systemd re-arm. Reply bytes reach ONLY `cat` (a   │
# │   pure data sink) → stdout / --out. The lib adds NO server verb and NO │
# │   new capability: it merely composes the emit grammar and resolves the │
# │   ssh identity for the SAME allowlisted `request …` verbs a human      │
# │   could type by hand.                                                  │
# └────────────────────────────────────────────────────────────────────────┘
#
# It is SOURCED (never executed) and defines shared defaults + helpers that
# operate on caller-set globals — chiefly:
#   PROG      the emitting program name (goes in every status line)
#   id        the request id
#   out       optional --out mirror path ("" = stdout only)
#   tmp       the per-iteration body buffer (await output)
#   emittmp   the composed-emit buffer that deliver() flushes
#   ssh_alias the ssh-config Host alias (for resolve_ssh_id)
# Both front-ends set these before calling into the lib. Keeping the function
# NAMES identical to nexus-reply-watch's originals means its loop is unchanged
# after it starts sourcing this file — the shipped test suite is the
# byte-for-byte regression guard on that refactor.

# Idempotent source guard (both front-ends may indirectly pull it in).
[ -n "${_NEXUS_WATCH_LIB:-}" ] && return 0
_NEXUS_WATCH_LIB=1

# ---- shared defaults ---------------------------------------------------
POLL_DEFAULT=300          # per-connection server-side await block (seconds)
POLL_MIN=5
POLL_MAX=1800             # the server clamps await to 1800; match it client-side
TIMEOUT_DEFAULT=86400     # overall wall-clock lifetime budget (24h)
TIMEOUT_MAX=604800        # hard ceiling (7d); --timeout 0 maps here (never truly infinite)
# Transient-error backoff bounds. Accept either the nexus-request or the
# legacy nexus-reply-watch env name so both front-ends + their test seams work.
BACKOFF_BASE=${NEXUS_WATCH_BACKOFF_BASE:-${NEXUS_REPLY_WATCH_BACKOFF_BASE:-5}}
BACKOFF_CAP=${NEXUS_WATCH_BACKOFF_CAP:-${NEXUS_REPLY_WATCH_BACKOFF_CAP:-300}}
SSH_ALIAS_DEFAULT=nexus-remote

# ssh hardening applied to EVERY invocation. ServerAlive turns a dead/
# suspended socket into a ~60s rc 255 (symmetric with the server's ~60s
# ClientAlive drop); BatchMode never blocks on a prompt (fails closed to
# 255); ConnectTimeout ≤ the server's LoginGraceTime=15.
SSH_HARDENING='-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4'

# ---- diagnostics go to STDERR ONLY (stdout is reserved for the event) --
log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown; }

# First non-empty line of a file, sanitized to one clean line for a
# `detail="…"` token (collapse whitespace, strip any embedded quote).
first_line() {
    sed -e 's/"/'"'"'/g' -e 's/[[:cntrl:]]/ /g' "$1" 2>/dev/null \
        | awk 'NF{print;exit}' | cut -c1-200
}

# Best-effort sha256 of a file. POSIX guarantees no sha tool, so this
# DEGRADES to `none` — the length prefix is the load-bearing anti-spoof
# primitive; the digest is belt-and-suspenders.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum < "$1" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 < "$1" 2>/dev/null | cut -d' ' -f1
    else
        printf none
    fi
}

# Keyed frontmatter reader — the SEMANTIC MIRROR of `_fm_get` in
# monitor/_fm_lib.sh, specialized to the colon-separated / fenced case (#405
# P2). Kept IN-BUNDLE (not sourced from the server tree) so the confined client
# stays self-contained and single-lib; the awk logic matches the server's so
# the frontmatter the server WRITES and this client READS share ONE spec and
# cannot drift — a cross-implementation parity test (test-fm-lib.sh section E)
# pins that equivalence. Reads the value of the FIRST top-level `key: value` in
# the leading `---`…`---` block (leading whitespace after the colon trimmed),
# empty if absent. The key is validated as an identifier (^[A-Za-z0-9_-]+$, so
# it carries no backslash into `awk -v`) and matched as a literal byte prefix,
# never a regex. Field bytes reach ONLY awk's `print` (a pure DATA sink) — no
# eval/source/exec — upholding the security invariant.
_fm_get() {
    case "$2" in ''|*[!A-Za-z0-9_-]*) return 2 ;; esac
    awk -v key="$2" '
        BEGIN { prefix = key ":"; plen = length(prefix); infm = 0 }
        NR==1 { if ($0 ~ /^---[[:space:]]*$/) infm = 1; next }
        infm && $0 ~ /^---[[:space:]]*$/ { exit }
        !infm { next }
        {
            if (substr($0, 1, plen) == prefix) {
                rest = substr($0, plen + 1)
                sub(/^[[:space:]]*/, "", rest)
                print rest
                exit
            }
        }
    ' "$1" 2>/dev/null
}

# Extract the `state:` value from a reply's FIRST frontmatter block only
# (between the first two `---` fences). Reading the machine field — never a
# prose sentence — is what discriminates replied vs acked, and confining it
# to the frontmatter means reply-body content cannot spoof the state. Thin
# wrapper over the shared `_fm_get`.
reply_state() { _fm_get "$1" state; }

# Resolve the ssh identity from $ssh_alias (+ NEXUS_REMOTE_SSH_* overrides).
# Sets $SSH (the program, default `ssh` — the hermetic-test seam) and $SSH_ID
# (the connection args). Both are left unquoted on use so a stub like
# SSH="sh test/fake-ssh.sh" word-splits correctly.
resolve_ssh_id() {
    : "${SSH:=ssh}"
    if [ -n "${NEXUS_REMOTE_SSH_HOST:-}" ]; then
        _port="${NEXUS_REMOTE_SSH_PORT:-22022}"
        _user="${NEXUS_REMOTE_SSH_USER:-}"
        _key="${NEXUS_REMOTE_SSH_KEY:-$HOME/.ssh/nexus-remote}"
        _target="${_user:+$_user@}$NEXUS_REMOTE_SSH_HOST"
        SSH_ID="-p $_port -i $_key $_target"
    else
        SSH_ID="$ssh_alias"
    fi
}

# ---- deliver: stdout is the event; mirror atomically to --out ----------
# Reads the composed emit from $emittmp. Writes it to stdout, then (if --out)
# writes it to a temp beside FILE and atomically renames — so a consumer that
# watches FILE never observes a half-written emit.
deliver() {
    cat "$emittmp"
    if [ -n "$out" ]; then
        _otmp="$out.tmp.$$"
        if cp "$emittmp" "$_otmp" 2>/dev/null && mv -f "$_otmp" "$out" 2>/dev/null; then :; else
            log "warning: could not write --out file: $out"
            rm -f "$_otmp" 2>/dev/null
        fi
    fi
}

# ---- compose the terminal emits ---------------------------------------
# compose_reply <state> [bodyfile]
#   Length-framed reply emit. The body defaults to $tmp (nexus-reply-watch's
#   await buffer); nexus-request passes the byte-exact `fetch results` raw
#   body explicitly. The length prefix is the anti-spoof primitive: the
#   consumer reads EXACTLY reply_bytes bytes and never line-scans the body,
#   so a reply body that itself contains a `state=…` line can never
#   masquerade as the status line.
compose_reply() {
    _st=$1
    _bodyfile=${2:-$tmp}
    _bytes=$(wc -c < "$_bodyfile" 2>/dev/null | tr -d ' \t'); [ -n "$_bytes" ] || _bytes=0
    _sha=$(sha256_of "$_bodyfile")
    {
        printf '%s: state=%s id=%s reply_bytes=%s reply_sha256=%s note=reply-is-data ts=%s\n' \
            "$PROG" "$_st" "$id" "$_bytes" "$_sha" "$(utc_now)"
        printf -- '--- reply-body %s ---\n' "$_bytes"
        cat "$_bodyfile"                 # verbatim reply bytes — a pure DATA sink
        printf -- '\n--- end reply-body ---\n'
    } > "$emittmp"
}

# compose_status <state> [key=value …]  — a status line, no body block.
compose_status() {
    _st=$1; shift
    printf '%s: state=%s id=%s %s ts=%s\n' "$PROG" "$_st" "$id" "$*" "$(utc_now)" > "$emittmp"
}

# ---- the ONE ssh-rc classification table (both front-ends route here) ---
# ssh/forced-command exit codes split into two families:
#   * VERB-INDEPENDENT terminal-fatal codes — the forced-command +
#     transport layer (remote-forced-command.sh §exit-codes; request-channel
#     rc 1/5). Their meaning does not depend on which `request …` verb ran,
#     so the rc→reason map is authoritative HERE and nowhere else.
#   * VERB-SPECIFIC codes {0, 2, 4} — rc 0 (ok/terminal), rc 4 (await
#     pending), and rc 2 which is DELIBERATELY absent below because the server
#     overloads it per verb (request-channel.sh §exit-codes): `await` rc 2 =
#     the request reached .failed (terminal_failed), `fetch` rc 2 = id not
#     found (not_found). A single table cannot own a verb-overloaded code, so
#     each caller matches 0/2/4 against ITS verb BEFORE consulting this table.
#     (This is why nexus-reply-watch's `await` rc 2 and nexus-request's `fetch
#     status` rc 2 legitimately carry different reasons — same number, two
#     verbs — and must NOT be "unified" into one arm.)
# rc 255 and any unclassified code are transient (reconnect + back off).

# fatal_reason_for <rc> — canonical reason token for a verb-INDEPENDENT
# terminal-fatal code, or empty for a transient/verb-specific code.
fatal_reason_for() {
    case "$1" in
        5)        printf confinement_reject ;;
        10)       printf channel_unavailable ;;
        11)       printf enroll_auth_lost ;;
        1|12|13)  printf refused ;;    # 1 = usage/bad-arg (STATIC → terminal, never retried); 12/13 = refused verb/flag/attach
        *)        : ;;
    esac
}

# fatal_detail_for <reason> <errfile> — canonical detail string per reason,
# byte-identical across both front-ends so the same rc emits the same line.
fatal_detail_for() {
    case "$1" in
        confinement_reject)  printf 'ownership check failed (id/principal mismatch)' ;;
        channel_unavailable) printf 'remote channel not registered/enabled' ;;
        enroll_auth_lost)    printf 'principal not enrolled / authorized_keys mis-bound' ;;
        *)                   first_line "$2" ;;   # refused (+ any future reason): the server's own line
    esac
}

# classify_ssh_rc <rc> <errfile> — if <rc> is a verb-independent terminal
# fatal code, EMIT the canonical failure (state=failed reason=… detail="…")
# and EXIT 2 (via emit_failed); otherwise RETURN 1 so the caller treats it as
# transient. Callers must have already matched their verb-specific 0/2/4.
classify_ssh_rc() {
    _reason=$(fatal_reason_for "$1")
    [ -n "$_reason" ] || return 1
    emit_failed "$_reason" "$(fatal_detail_for "$_reason" "$2")"
}

# ---- exactly-once terminal emit (crash-restart double-emit guard) ------
# Callers set $sentinel to a per-id path that survives a reboot. Ordering is
# load-bearing: mark_emitted runs BEFORE the visible emit, so an instance that
# crashes mid-emit and is resumed on the same id short-circuits and never
# double-emits. already_emitted tolerates an unset sentinel (nexus-request
# learns its id only after the file step).
already_emitted() { [ -n "${sentinel:-}" ] && [ -e "$sentinel" ]; }
mark_emitted()    { [ -n "${sentinel:-}" ] && : > "$sentinel"; }

# ---- shared terminal emitters (compose → sentinel → deliver → exit) ----
# emit_replied <bodyfile> — length-framed reply body, exit 0.
emit_replied() {
    if already_emitted; then log "terminal reply for id=$id already emitted — no re-emit"; exit 0; fi
    compose_reply replied "$1"
    mark_emitted
    deliver
    exit 0
}
# emit_failed <reason> <detail> — status line, no body, exit 2.
emit_failed() {
    if already_emitted; then log "terminal failure for id=$id already emitted — no re-emit"; exit 2; fi
    compose_status failed "reason=$1" "detail=\"$2\""
    mark_emitted
    deliver
    exit 2
}
# emit_timeout <waited_s> — a give-up; NOT sentinel-guarded (retryable), exit 3.
emit_timeout() {
    compose_status timeout reason=budget_exhausted "waited_s=$1"
    deliver
    exit 3
}

# ---- one remote call (a single ssh session) ---------------------------
# The ONLY way a front-end reaches the server. $SSH/$SSH_HARDENING/$SSH_ID are
# word-split (a stub like SSH="sh fake-ssh.sh" relies on this); the request
# subcommand args pass through verbatim. No channel token reaches a shell.
#
# STDIN IS NOT REDIRECTED HERE — it is inherited from the caller so a body can
# stream byte-exact into the ssh session (nexus-request --message-stdin/-file).
# A function-internal `</dev/null` would run AFTER the caller's fd 0 is
# inherited and would silently strip every piped body (the D1 defect). Call
# sites that must NOT forward stdin (inline body; every fetch/await poll)
# append their own `</dev/null`.
remote() {
    # shellcheck disable=SC2086
    $SSH $SSH_HARDENING $SSH_ID "$@"
}

# ---- transient backoff: bounded, wall-clock-subordinate, jittered ------
# Sleep the current $backoff (never past $deadline; +PID jitter decorrelates
# concurrent watchers so their reconnects don't synchronize), then grow it
# toward $BACKOFF_CAP. Reads/writes the shared $backoff; reads $deadline.
backoff_sleep() {
    _now=$(date +%s 2>/dev/null || echo "$deadline")
    _sleep=$(( backoff + ($$ % 7) ))
    _rem=$(( deadline - _now )); [ "$_sleep" -gt "$_rem" ] && _sleep=$_rem
    [ "$_sleep" -lt 1 ] && _sleep=1
    sleep "$_sleep"
    backoff=$(( backoff * 2 )); [ "$backoff" -gt "$BACKOFF_CAP" ] && backoff=$BACKOFF_CAP
}

# ---- the shared watch-loop core ---------------------------------------
# The wall-clock-bounded poll skeleton both front-ends run. It owns the parts
# that MUST NOT drift between the tools: the lifetime budget (WALL-CLOCK via
# date +%s — a multi-hour suspend consumes wall time, never inflates a retry
# count), the stop-file escape hatch, and the single clean state=timeout edge.
# The per-iteration work is the caller's poll_once hook — the only
# tool-specific step (nexus-request: status-precheck + await-as-sleep;
# nexus-reply-watch: await-as-detector). poll_once emits any terminal state
# itself (via the shared emit_* which exit) or returns to recycle; it may
# extend $deadline (nexus-request's rename-as-progress patience) and consumes
# $backoff via backoff_sleep. Requires: timeout, stop_file, id, sentinel,
# BACKOFF_BASE set; a poll_once function defined.
watch_loop() {
    start=$(date +%s 2>/dev/null || echo 0)
    deadline=$(( start + timeout ))
    backoff=$BACKOFF_BASE
    while :; do
        # Explicit stop (agent drops a stop-file) — clean, no emit.
        if [ -n "$stop_file" ] && [ -e "$stop_file" ]; then
            log "stop-file present ($stop_file) — exiting cleanly (no emit)"
            rm -f "$stop_file" 2>/dev/null
            exit 143
        fi
        now=$(date +%s 2>/dev/null || echo "$deadline")
        if [ "$now" -ge "$deadline" ]; then
            emit_timeout "$(( now - start ))"
        fi
        poll_once
    done
}
