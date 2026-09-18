#!/usr/bin/env bash
# request-channel.sh — the watcher-mediated request inbox and the
# bidirectional request/reply protocol (agent-channel RFC Parts B + D).
#
# A worker (or, in Phase 2, a confined remote SSH client) files a durable
# REQUEST to the orchestrator that cannot be lost, cannot be
# double-processed, and drains at the orchestrator's pace. The mechanism
# is a markdown inbox under $STATE_DIR/requests/ that the WATCHER watches:
# the watcher claims each request by atomic rename, surfaces it in its
# normal emit, and re-emits until the orchestrator acks by renaming. No
# new writer to the orchestrator pane is introduced — requests ride the
# watcher's existing emit (see monitor/watcher/_requests.sh).
#
# This script is the PRODUCER/CLIENT + ORCHESTRATOR facade (the watcher's
# claim/emit/re-emit is internal, no verb). It is the worker→orchestrator
# generalization of the peer-to-peer skeptic channel
# (monitor/skeptic-channel.sh); both share the "rename is the signal"
# core in monitor/_channel_lib.sh (RFC §2.8).
#
# ── Lifecycle (the rename IS the signal) ──────────────────────────────
#
#   producer            watcher                    orchestrator
#   ────────            ───────                    ────────────
#   file → <id>.new.md
#                  claim (atomic mv) → <id>.claimed.md
#                       │ emit `--- requests ---`, re-emit until acked
#                                            ack:   .claimed → .done                    (no body)
#                                            reply: .claimed → [.replying] → .replied
#                                            fail:  .claimed → [.failing]  → .failed
#
#   Filename-suffix states: new | claimed | replied | done | failed, plus the
#   TRANSIENT content-transition intermediates replying | failing (pending;
#   readers treat them like claimed). The filename suffix is authoritative — an
#   in-file `state:` field can lag until a builder rewrites it. `list` follows
#   the same reader rule: the intermediates are selected by `--state claimed`
#   (and `all`) — the enum stays the five stable words — but each row renders
#   its LITERAL suffix (e.g. `[replying]`), so a crashed transition pending
#   the watcher reaper is visible instead of hidden.
#
#   ── The transition is a table, ENFORCED, not a prose invariant ─────────
#   The header once claimed "single-writer-per-transition + atomic rename =
#   no race". That was false: `.new` and `.claimed` each have TWO writers —
#   the watcher (new→claimed claim; claimed→failed max-age reaper) AND this
#   facade (ack/reply/fail). A naive resolve-then-rename therefore races:
#   an ack could spuriously die when the watcher claimed mid-op, and a reply
#   could strand its text in a reaped `.failed` file. cmd_ack/cmd_reply/
#   cmd_fail now route every state change through `_chan_transition`
#   (monitor/_channel_lib.sh): an explicit legal-from table, CLAIM-FIRST
#   ordering, and exactly ONE re-resolve-on-race retry. The legal table:
#
#     ack    new|claimed → done               (idempotent at done; terminal≠done → no-op;
#                                               REFUSED rc6 on a LIVE reply:required id —
#                                               ack would close it without the demanded reply)
#     fail   new|claimed → [.failing]  → failed  (idempotent at failed)
#     reply  claimed     → [.replying] → replied (one reply; replied w/o --amend → rc 6)
#     amend  replied     → replied            (same-state content update; non-replied → rc 6)
#
#   INTERMEDIATE-NAME safety (the F1 fix): a CONTENT transition never claims
#   straight into its terminal name — that would leave the terminal-named file
#   holding pre-transition content in the window before the content swap, and a
#   crash / NFS EIO there strands a terminal file readers false-succeed on.
#   Instead it claims into a NON-AUTHORITATIVE intermediate (`.replying`/
#   `.failing`), writes the full content there, then does ONE atomic finalize
#   rename → terminal. The terminal name therefore appears ONLY via a rename of
#   an already-complete file — never observable partial. A crash mid-transition
#   leaves an intermediate, which the watcher reaper recovers (a complete aged
#   `.replying` → `.replied` byte-exact; an incomplete one, or any aged
#   `.failing`, → `.failed`; see monitor/watcher/_requests.sh). ack (a pure
#   rename, no content) and amend (one atomic temp+mv over the stable `.replied`)
#   need no intermediate. A LOST race is non-corrupting either way: if a reaper
#   renamed `.claimed`→`.failed` first, our claim simply fails (rc 6) and the
#   `.failed` file is byte-for-byte the reaper's — we never touched it.
#
#   UNFORGEABLE MARKERS (every state/boundary decision keys on builder-controlled
#   FRONTMATTER, never on body-text position — both the request `## Details` and
#   the reply body are free-form and can contain a `## Reply` or `state:` line):
#     • reaper completeness: a `.replying` is COMPLETE iff its frontmatter
#       `state:` == replied (set by the reply builder before the content mv) —
#       NOT a `## Reply` grep. An incomplete crash still holds the request's
#       `state: new`, so a request quoting `## Reply` cannot forge a finalize.
#     • reply body location: the reply block records `body_bytes: N`, so the raw
#       body is exactly the file's LAST N bytes. `--amend` slices there (verified
#       against results.md) and REFUSES a legacy reply lacking the marker; the
#       legacy fetch-results fallback prefers it and refuses an ambiguous
#       (>1 occurrence) `## Reply` rather than guess. No `## Reply` text search
#       decides any boundary.
#
#   Reads of a TRANSITIONAL file (new|claimed|replying|failing) race the same
#   renames — the resolved path can vanish before `fetch`/`await` read it,
#   spuriously rc-5-rejecting a healthy request. `_resolve_read_owned` gives a
#   confined read one re-resolve retry; terminal states are stable and need none.
#
# ── ID allocation (collision-free, NFS-atomic) ────────────────────────
#
#   The stable id is the stem `<ts>-<origin>-<slug>[-NN]` (invariant
#   across renames; the dedup/ack key AND the reply correlation handle).
#   `<ts>` is second-granular, so two producers sharing origin+slug in the
#   same second would collide. We reserve the stem with **`mkdir`** of a
#   marker dir under `.ids/<stem>` — `mkdir` is atomic across NFS clients
#   (the same reason the watcher uses flock, not O_EXCL, on the
#   cross-client `.state` substrate; RFC §1.7). On a collision we append
#   the next numeric disambiguator and retry. The id is printed ONLY after
#   the reserving `mkdir` wins, so the printed id always equals the
#   on-disk stem — the property a remote client depends on to correlate
#   its reply (RFC §2.2a, §D.2). (O_EXCL / `set -C` open is NOT used: it
#   is not reliably atomic on NFS-cross-client.)
#
# ── Subcommands ───────────────────────────────────────────────────────
#   PRODUCER / CLIENT side:
#     file   --origin <w> --kind <k> [--priority normal|high] [--reply required|optional|none]
#            [--no-publish] --slug <s> [--file f|--message t|-]   # writes .new.md; PRINTS id
#     await  <id> [--timeout S] [--interval S] [--principal P]    # block→read reply
#     fetch  <id> progress|results|status [--principal P]         # no-publish: pull a fetch file; status = rename-state word
#     list   [--state new|claimed|replied|done|failed|all]        # table; claimed + all
#            include pending replying|failing intermediates, rendered literally
#     show   <id>                                                 # print the request file
#     reqfile <id>                                                # resolve id → path
#     dir                                                         # print the inbox dir
#   ORCHESTRATOR side:
#     ack    <id>                                                 # .claimed → .done (bare ack;
#            REFUSED on a reply:required id — use `reply` so the demanded answer isn't dropped)
#     reply  <id> [--file f|--message t|-] [--status S] [--worker w] [--dir p]
#            [--issue owner/repo#N] [--no-publish] [--progress p] [--results p]  # .claimed → .replied
#            --status is a CLOSED vocabulary (unknown values are refused, #1293):
#              spawned   a reviewer is coming; ITS verdict discharges the gate
#                        (on a spawn-skeptic request, --worker is REQUIRED)
#              declined  no review — on a spawn-skeptic request this verb
#                        resolves the skeptic gate BEFORE replying, so the
#                        decision and its record are one act
#              deferred  not now; the gate deliberately STAYS armed
#              answered  an ordinary answer (REFUSED on spawn-skeptic: ambiguous)
#            [--skeptic-resolved]  assert the gate is already discharged; skip
#                        the resolve. Says so on stderr; never silent.
#     fail   <id> --reason "<why>"                                # → .failed
#
# ── Exit codes ────────────────────────────────────────────────────────
#   0   ok / await: replied or done (terminal answer present)
#   1   usage / bad argument
#   2   request id not found / await: failed terminal / fetch: confinement reject
#   3   not-ready (fetch results before it exists)
#   4   await timed out (still pending)
#   5   ownership check failed (principal != request origin)
#   6   illegal state transition (e.g. reply to an already-replied id; ack of a
#       LIVE reply:required id — it would close without the demanded reply)
#
# State dir resolution mirrors monitor/ng + skeptic-channel.sh:
#   NEXUS_STATE_DIR → NEXUS_ROOT/monitor/.state → config nexus.root →
#   script-relative fallback.

set -uo pipefail

# ARGUMENT-LOOP PROGRESS GUARD (your-org/nexus-code#924). Each argument loop
# below asserts that every iteration consumes at least one argument. Without it
# a value-taking flag given LAST spins forever — `shift 2` with `$#` == 1 is
# refused, so the arm re-matches — and a hang here is worse than an error
# because nothing on this board surfaces it. Full rationale: monitor/ng.
_argloop_stuck() {
    printf '%s: option %s requires a value (argument loop made no progress)\n' \
        "${0##*/}" "${1-}" >&2
    exit 64
}

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die()  { printf 'request-channel: %s\n' "$*" >&2; exit 1; }

# ---- your-org/nexus-code#906 R1 (diagnostic axis) -------------------------
#
# A bare token that does not start with `-` is NOT an unknown flag — it is an
# unexpected POSITIONAL, and saying "unknown flag" sends the reader hunting a
# flag name that was never the problem, at the exact moment they got the call
# shape wrong and most needed to be told what was actually wrong.
#
# It must also not ECHO THE WHOLE TOKEN. Measured in ordinary orchestration:
# `ng request reply <id> "<900-char message>"` printed the entire message back
# as a flag name. Same family as #858 C, where a multi-line body embedded in a
# diagnostic survived a `| tail -1` and read as a plausible value.
_arg_excerpt() {   # <token> → first line, excerpted, dropped-line count named
    local v="${1-}" first nl bytes
    first="${v%%$'\n'*}"
    # BYTE-capped, trimmed on a CHARACTER boundary (your-org/nexus-code#906).
    # Three axes, and only the third is the property:
    #   #858 C capped LINES   → a 900-char SINGLE-line token walked through
    #   the first #906 cut capped CHARACTERS → still a proxy; 72 multi-byte
    #                                          characters is 219 bytes
    #   this caps BYTES       → what "do not swamp the diagnostic" means
    # Character-boundary trimming is why the char cap comes first: slicing at
    # a byte offset would split a multi-byte character into mojibake, so the
    # loop removes whole characters until the byte budget is met.
    (( ${#first} > 72 )) && first="${first:0:72}"
    while (( ${#first} > 1 )); do
        bytes=$(LC_ALL=C printf '%s' "$first" | wc -c)
        (( bytes <= 96 )) && break
        first="${first:0:$(( ${#first} - 4 ))}"
    done
    # Ellipsis iff the excerpt is shorter than the line it came from. One
    # condition, because the two-clause version this replaced could in
    # principle append twice and only testing showed it did not.
    [[ "$first" != "${v%%$'\n'*}" ]] && first="${first}…"
    nl="${v//[^$'\n']/}"
    if (( ${#nl} > 0 )); then
        printf "'%s' (+%d more line(s))" "$first" "${#nl}"
    else
        printf "'%s'" "$first"
    fi
}

# <verb> <token> [<what they probably wanted>]
_die_positional() {
    local verb="$1" tok="$2" hint="${3:-}"
    local msg="$verb: unexpected POSITIONAL argument $(_arg_excerpt "$tok")"
    if [[ -n "$hint" ]]; then msg+=" — did you mean $hint?"; else msg+="."; fi
    die "$msg Flags must start with --; positionals are matched in order."
}
warn() { printf 'request-channel: %s\n' "$*" >&2; }

# shellcheck source=_channel_lib.sh
source "$_script_dir/_channel_lib.sh"

# Normalize to UTF-8 before we read a --message / stdin body, write the
# .new.md, or compose a reply: this facade is reached under an SSH forced
# command whose ambient locale is the (often ASCII) sshd-daemon default, and
# a UTF-8 body under LC_ALL=C is where a UnicodeDecodeError surfaces
# (agent-channel RFC Part B/D). No-op when the locale is already UTF-8.
_chan_apply_utf8_locale

_resolve_state_dir() {
    if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
        printf '%s' "$NEXUS_STATE_DIR"; return 0
    fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then
        printf '%s/monitor/.state' "$NEXUS_ROOT"; return 0
    fi
    local cfg_root=""
    if [[ -x "$_script_dir/../config/load.sh" ]]; then
        cfg_root=$("$_script_dir/../config/load.sh" nexus.root 2>/dev/null) || cfg_root=""
    fi
    if [[ -n "$cfg_root" ]]; then
        printf '%s/monitor/.state' "$cfg_root"; return 0
    fi
    printf '%s/.state' "$_script_dir"
}

STATE_DIR="$(_resolve_state_dir)"
REQ_DIR="$STATE_DIR/requests"
REPLIES_DIR="$REQ_DIR/replies"
IDS_DIR="$REQ_DIR/.ids"

# The confinement root: a fetched symlink's resolved target must stay
# under this tree (defence-in-depth, RFC §D.6). SANDBOX_PROJECT_DIR is the
# kernel-enforced writable root inside the sandbox; fall back to the nexus
# root, then the state dir.
_confine_root() {
    if [[ -n "${SANDBOX_PROJECT_DIR:-}" ]]; then printf '%s' "$SANDBOX_PROJECT_DIR"; return; fi
    if [[ -n "${NEXUS_ROOT:-}" ]]; then printf '%s' "$NEXUS_ROOT"; return; fi
    printf '%s' "$STATE_DIR"
}

# A request id is a filename stem composed only of [A-Za-z0-9_-] (the ts
# contributes digits + T + Z; origin/slug are _chan_safe-sanitized;
# disambiguator is `-NN`). REJECTING anything else is the load-bearing
# path-confinement guard for `fetch`/`await`/`show`: it makes `..`, `/`,
# and absolute paths un-representable as an id, so no id can ever name a
# file outside the inbox tree (RFC §D.6, §6).
_validate_id() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || die "illegal request id (must be [A-Za-z0-9_-]): $1"
}

# Resolve an id to its current on-disk file + state. The FILENAME SUFFIX is the
# authoritative state (an in-file `state:` field can lag until a builder rewrites
# it — the suffix always wins). Terminal states (replied/done/failed) take
# precedence — they are where the id comes to rest — then the pending
# CONTENT-TRANSITION intermediates (replying/failing: a content transition has
# claimed the slot but not yet finalized; readers treat these like claimed, NOT
# terminal), then claimed/new. A terminal and its intermediate never coexist for
# one id (the finalize is a single atomic rename), so ordering only matters as
# defence: a completed terminal must outrank a stale intermediate. Prints
# "<path>\t<state>" on stdout, rc 0; rc 1 if no file for the id exists.
_state_file_for_id() {
    local id="$1" st f
    for st in replied done failed replying failing claimed new; do
        f="$REQ_DIR/$id.$st.md"
        if [[ -f "$f" ]]; then printf '%s\t%s' "$f" "$st"; return 0; fi
    done
    return 1
}

# Verify, when a principal is supplied (the Part A forced-command path
# forces `--origin remote-<principal>` and passes its principal here),
# that the request's `origin` frontmatter equals that principal. A local
# caller passes no principal → no check (a local agent is not confined).
# Exits 5 on mismatch. $1=request-file $2=principal(may be empty).
_check_ownership() {
    local file="$1" principal="$2"
    [[ -n "$principal" ]] || return 0
    local origin; origin=$(_chan_frontmatter_field "$file" origin)
    if [[ "$origin" != "$principal" ]]; then
        printf 'request-channel: ownership check failed: id origin %q != principal %q\n' \
            "$origin" "$principal" >&2
        exit 5
    fi
    return 0
}

# Race-aware resolve + ownership for a confined READ verb (fetch). Resolves
# the id and, when a principal is given, verifies origin == principal. The
# read race (RFC §D.6 follow-up): `_state_file_for_id` may resolve a
# TRANSITIONAL `.claimed`/`.new` path that the watcher renames away before the
# subsequent frontmatter read — leaving `origin` empty and spuriously rc-5
# rejecting a healthy request. A terminal state (replied/done/failed) is stable
# and never needs a retry; a transitional miss re-resolves EXACTLY ONCE (a
# claimed file transitions forward only, so the second resolve lands on a
# stable terminal). Sets globals _RR_PATH / _RR_STATE. Returns 0 on a resolved
# (and, if principal, owned) request; returns 1 when absent for a LOCAL caller;
# exits 5 on a real ownership mismatch or a confined-principal miss. Must be
# called in the main shell (never `$(…)`) so its `exit 5` propagates.
_RR_PATH=""; _RR_STATE=""
_resolve_read_owned() {
    local id="$1" principal="$2" try sf origin
    _RR_PATH=""; _RR_STATE=""
    for try in 0 1; do
        if ! sf=$(_state_file_for_id "$id"); then
            if [[ -n "$principal" ]]; then
                printf 'request-channel: no request for id %s — cannot verify ownership\n' "$(_arg_excerpt "$id")" >&2
                exit 5
            fi
            return 1
        fi
        _RR_PATH="${sf%$'\t'*}"; _RR_STATE="${sf##*$'\t'}"
        # Test seam (mirrors CHAN_TS_OVERRIDE): interpose a rename between the
        # resolve above and the frontmatter read below. Fires at most ONCE.
        if [[ -n "${CHAN_READ_RACE_HOOK:-}" ]]; then
            eval "$CHAN_READ_RACE_HOOK" || true
            unset CHAN_READ_RACE_HOOK
        fi
        [[ -n "$principal" ]] || return 0     # local caller: no ownership read
        origin=$(_chan_frontmatter_field "$_RR_PATH" origin 2>/dev/null) || origin=""
        case "$_RR_STATE" in claimed|new|replying|failing) local _transitional=1 ;; *) local _transitional=0 ;; esac
        if [[ -z "$origin" && ! -f "$_RR_PATH" && "$_transitional" -eq 1 && "$try" -eq 0 ]]; then
            continue                          # race (c): a transitional file was
                                              # renamed away mid-read → re-resolve
        fi
        if [[ "$origin" != "$principal" ]]; then
            printf 'request-channel: ownership check failed: id origin %q != principal %q\n' \
                "$origin" "$principal" >&2
            exit 5
        fi
        return 0
    done
    if [[ -n "$principal" ]]; then
        printf 'request-channel: no stable request for id %s — cannot verify ownership\n' "$id" >&2
        exit 5
    fi
    return 1
}

# ── file ──────────────────────────────────────────────────────────────
_build_request_file() {
    # builder for _chan_publish_atomic: writes the .new.md body to $1. The body
    # arrives as a FILE (bodyfile), never a shell string — trailing newlines and
    # backslashes must survive byte-exact (see _chan_body_capture).
    local tmp="$1" id="$2" origin="$3" kind="$4" priority="$5" reply="$6" \
          publish="$7" bodyfile="$8"
    {
        printf -- '---\n'
        printf 'request: %s\n' "$id"
        printf 'origin: %s\n' "$origin"
        # PROCESS-DERIVED provenance beside the argv-supplied origin
        # (your-org/nexus-code#1341): eight requests landed in the operator's
        # inbox in 84 s and nothing in the record said WHO filed them — the one
        # field that read as provenance identified the ng BINARY. These facts
        # are taken from the filing process, not from its arguments, so a
        # mis-set --origin is still attributable.
        printf 'filed-by: uid=%s pid=%s ppid=%s window=%s pane=%s session=%s host=%s\n' \
            "$(id -un 2>/dev/null || echo '?')" "$$" "$PPID" \
            "${NEXUS_WORKER_WINDOW:-<unset>}" "${TMUX_PANE:-<unset>}" \
            "${CLAUDE_SESSION_ID:-${NEXUS_SESSION_ID:-<unset>}}" "$(hostname -s 2>/dev/null || echo '?')"
        printf 'kind: %s\n' "$kind"
        [[ -n "$reply" ]] && printf 'reply: %s\n' "$reply"
        printf 'created: %s\n' "$(_chan_now_iso)"
        printf 'priority: %s\n' "$priority"
        printf 'publish: %s\n' "$publish"
        # `state:` IS A CONTENT-TRANSITION COMPLETION MARKER, NOT THE REQUEST'S
        # STATE (your-org/nexus-code#1358). THE FILENAME SUFFIX IS THE STATE OF
        # RECORD — the header at the top of this file says so, and this write
        # site did not, which is where the field acquires its false authority.
        #
        # Only a CONTENT builder rewrites it: `_build_reply_content` and
        # `_build_amend_content` write `state: replied`, `_build_fail_content`
        # writes `state: failed`. `ack` is a PURE RENAME (`_chan_transition`
        # with builder `-`), by design and for the crash-safety reason the
        # header gives, so it never touches the body. A `.done.md` therefore
        # keeps whatever this line wrote — measured on the live request store
        # 2026-09-02: 99/99 `.replied.md` carry `state: replied` and 0/79
        # `.done.md` carry `state: done`; ALL 79 still say `state: new`.
        #
        # THE FIELD IS NOT DECORATIVE, WHICH IS WHY IT IS NOT SIMPLY DROPPED.
        # `watcher/_requests.sh` keys crash recovery on it: a `.replying` is
        # COMPLETE iff its frontmatter says `state: replied` (the builder writes
        # it BEFORE the content mv), and that test is deliberately unforgeable
        # by body text. Dropping the field would also break the remote client,
        # which reads it off a terminal `.replied.md` to tell a reply from an
        # ack (`client/nexus-reply-watch`).
        #
        # SO: DO NOT WRITE A PREDICATE ON THE VALUES THIS FIELD GETS WRONG.
        # Both readers today ask `== replied` — the one value a builder always
        # maintains — so the field is right about the only question anyone asks
        # of it. `== done`, `!= new` and `== new` are the tempting next
        # predicates and every one of them is wrong on every terminal-by-ack
        # request. Ask the FILENAME SUFFIX instead (`list --state done`, or
        # `_state_file_for_id`, which returns it). `test-request-state-field.sh`
        # asserts the reader polarity so this cannot regress silently.
        printf 'state: new\n'
        printf -- '---\n\n'
        printf '## Request\n\n'
        # SUMMARY ONLY: the first non-empty line of the body, streamed verbatim
        # (awk `print` reprints $0 byte-faithfully; no -v, no escape processing).
        # This is the line the watcher surfaces (_requests_summary). The FULL
        # body lives once under ## Details below.
        awk 'NF{print; exit}' "$bodyfile"
        printf '\n'
        printf '## Details\n\n'
        # FULL body, byte-exact, streamed file→file (cat, never printf %s). As
        # the LAST section, everything from its blank line to EOF IS the body —
        # so a byte-exact extraction is `tail -n +<hdr+2>`.
        cat -- "$bodyfile"
    } > "$tmp"
}

cmd_file() {
    local origin="" kind="question" priority="normal" reply="" publish="true" slug=""
    local -a body_args=()
    _argloop_prev_1=-1; while (( $# > 0 )); do (( $# != _argloop_prev_1 )) || _argloop_stuck "$1"; _argloop_prev_1=$#
        case "$1" in
            --origin)   origin="${2:-}";   shift 2 || die "--origin needs a value" ;;
            --kind)     kind="${2:-}";     shift 2 || die "--kind needs a value" ;;
            --priority) priority="${2:-}"; shift 2 || die "--priority needs normal|high" ;;
            --reply)    reply="${2:-}";    shift 2 || die "--reply needs a value (required)" ;;
            --slug)     slug="${2:-}";     shift 2 || die "--slug needs a value" ;;
            --no-publish) publish="false"; shift ;;
            --file|--message) body_args+=("$1" "${2:-}"); shift 2 || die "$1 needs a value" ;;
            -)          body_args+=("-");   shift ;;
            *) die "file: unknown flag: $(_arg_excerpt "$1")" ;;
        esac
    done
    [[ -n "$origin" ]] || die "file: --origin <window-or-principal> is required"
    [[ -n "$slug"   ]] || die "file: --slug <kebab> is required"
    # Origin is provenance AND the reply-ownership key — it must be
    # filename-safe and un-spoofable. Reject (don't silently mangle) so the
    # printed id matches the caller's expectation. The remote forced-command
    # path forces a `remote-<principal>` origin already in this charset.
    [[ "$origin" =~ ^[A-Za-z0-9_-]+$ ]] || die "file: --origin must be [A-Za-z0-9_-]: $(_arg_excerpt "$origin")"
    case "$priority" in normal|high) ;; *) die "file: --priority must be normal|high" ;; esac
    # --reply gates whether the request DEMANDS a reply. The only value that
    # changes behaviour is `required`; `optional`/`none` (and empty) are the
    # DEFAULT — a reply is welcome but not demanded — so accept them as an
    # explicit no-op rather than erroring on the natural-looking spelling.
    case "$reply" in
        ""|optional|none) reply="" ;;
        required) ;;
        *) die "file: --reply accepts 'required', 'optional', or 'none'" ;;
    esac
    [[ "$kind" =~ ^[a-z][a-z0-9-]*$ ]] || die "file: --kind must be a kebab token: $(_arg_excerpt "$kind")"

    local safe_slug; safe_slug=$(_chan_safe "$slug")
    [[ -n "$safe_slug" ]] || die "file: --slug sanitizes to empty: $(_arg_excerpt "$slug")"

    mkdir -p "$REQ_DIR" "$IDS_DIR" "$REPLIES_DIR" 2>/dev/null \
        || die "file: cannot create inbox dirs under $REQ_DIR"

    # Collision-free id reservation via mkdir (atomic across NFS clients).
    local ts; ts=$(_chan_ts)
    local base="${ts}-${origin}-${safe_slug}"
    local stem="$base" n=0
    while ! mkdir "$IDS_DIR/$stem" 2>/dev/null; do
        n=$((n + 1))
        (( n > 999 )) && die "file: could not allocate a free id for $(_arg_excerpt "$base") after 999 tries"
        stem=$(printf '%s-%02d' "$base" "$n")
    done

    # Capture the body BYTE-EXACT into a temp FILE (never a $(…) shell capture,
    # which strips trailing newlines). The request file is assembled FROM this
    # file so a script/data/prose body — including its exact trailing bytes —
    # survives verbatim under ## Details. On any failure past the id-reservation
    # mkdir, release the reserved marker so the stem stays allocatable.
    local bodyfile; bodyfile=$(_chan_body_capture die "${body_args[@]}") \
        || { rmdir "$IDS_DIR/$stem" 2>/dev/null || true; exit 1; }
    if ! grep -q '[^[:space:]]' -- "$bodyfile"; then
        rm -f "$bodyfile"; rmdir "$IDS_DIR/$stem" 2>/dev/null || true
        die "file: request body is empty"
    fi

    local dest="$REQ_DIR/$stem.new.md"
    if ! _chan_publish_atomic "$dest" die _build_request_file \
            "$stem" "$origin" "$kind" "$priority" "$reply" "$publish" "$bodyfile"; then
        rm -f "$bodyfile"; rmdir "$IDS_DIR/$stem" 2>/dev/null || true
        die "file: failed to publish $dest"
    fi
    rm -f "$bodyfile"
    # Pre-create the per-request reply dir so the no-publish branch and the
    # orchestrator's reply have a home that already exists (RFC §D.6).
    mkdir -p "$REPLIES_DIR/$stem" 2>/dev/null || true
    # THE printed id == the on-disk stem (reserved above before this print).
    printf '%s\n' "$stem"
}

# ── await ─────────────────────────────────────────────────────────────
cmd_await() {
    local id=""
    local timeout=1800 interval=5 principal="${NEXUS_REQUEST_PRINCIPAL:-}"
    _argloop_prev_2=-1; while (( $# > 0 )); do (( $# != _argloop_prev_2 )) || _argloop_stuck "$1"; _argloop_prev_2=$#
        case "$1" in
            --timeout)   timeout="${2:-}";   shift 2 || die "--timeout needs seconds" ;;
            --interval)  interval="${2:-}";  shift 2 || die "--interval needs seconds" ;;
            --principal) principal="${2:-}"; shift 2 || die "--principal needs a value" ;;
            --*) die "await: unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$id" ]]; then id="$1"
                else _die_positional "await" "$1"; fi
                shift ;;
        esac
    done
    [[ -n "$id" ]] || die "usage: await <id> [--timeout S] [--interval S] [--principal P]"
    _validate_id "$id"
    [[ "$timeout"  =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || die "--interval must be a positive integer"
    local waited=0 sf path state
    while :; do
        if sf=$(_state_file_for_id "$id"); then
            path="${sf%$'\t'*}"; state="${sf##*$'\t'}"
            case "$state" in
                replied)
                    _check_ownership "$path" "$principal"
                    cat -- "$path"
                    return 0 ;;
                done)
                    _check_ownership "$path" "$principal"
                    printf 'acknowledged, no reply body (id %s)\n' "$id"
                    return 0 ;;
                failed)
                    _check_ownership "$path" "$principal"
                    printf 'request FAILED (id %s):\n' "$id"
                    cat -- "$path"
                    return 2 ;;
            esac
        fi
        (( waited >= timeout )) && break
        sleep "$interval"
        waited=$((waited + interval))
    done
    printf 'request-channel: await timed out after %ds; id %s still pending (not yet replied/done)\n' \
        "$timeout" "$(_arg_excerpt "$id")" >&2
    return 4
}

# ── fetch (no-publish branch; path-confined BY CONSTRUCTION) ───────────
cmd_fetch() {
    local id=""
    local selector=""
    local principal="${NEXUS_REQUEST_PRINCIPAL:-}"
    _argloop_prev_3=-1; while (( $# > 0 )); do (( $# != _argloop_prev_3 )) || _argloop_stuck "$1"; _argloop_prev_3=$#
        case "$1" in
            --principal) principal="${2:-}"; shift 2 || die "--principal needs a value" ;;
            --*) die "fetch: unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$id" ]]; then id="$1"
                elif [[ -z "$selector" ]]; then selector="$1"
                else _die_positional "fetch" "$1"; fi
                shift ;;
        esac
    done
    [[ -n "$id" && -n "$selector" ]] || die "usage: fetch <id> progress|results|status [--principal P]"
    _validate_id "$id"
    # The selector is a FIXED enum, never a path. Target is computed from
    # <id> + selector ALONE — the reply frontmatter's advisory *_path
    # fields are IGNORED (RFC §D.6): nothing the client supplies can widen
    # the reachable surface beyond replies/<id>/{progress,results}.md.
    # `status` is a read-only sub-mode that returns ONLY the rename-state
    # word (new|claimed|replied|done|failed) of the client's OWN request —
    # it names no file, so it is strictly narrower than progress/results and
    # adds no new reachable surface. It exists so a client watcher can detect
    # ACTIVE PROCESSING (`claimed`) and not close too early (RFC §2.8: the
    # rename IS the signal).
    case "$selector" in progress|results|status) ;; *) die "fetch: selector must be 'progress', 'results', or 'status'" ;; esac

    # Ownership: resolve the request file (any state) for the id, verify
    # origin == principal. A confined remote client can fetch only its own
    # round-trip. Race-aware: a transitional (.claimed/.new) resolve that the
    # watcher renames away mid-read is re-resolved once, never a spurious rc 5.
    local path state=""
    if _resolve_read_owned "$id" "$principal"; then
        path="$_RR_PATH"; state="$_RR_STATE"
    fi

    # status: emit ONLY the current rename-state word for the client's own
    # request. Read-only, ownership-checked above, names no path. If no file
    # exists for the id (a confined principal already exited 5 above; a local
    # caller falls through here) report not-found → rc 2.
    if [[ "$selector" == status ]]; then
        if [[ -z "$state" ]]; then
            printf 'request-channel: no request for id %s\n' "$(_arg_excerpt "$id")" >&2
            exit 2
        fi
        # A CONTENT-TRANSITION intermediate (replying/failing) is pending, not a
        # settled state — report it as `claimed` so a client watcher keys off the
        # same ACTIVE-PROCESSING word and NEVER reads a terminal-looking status
        # for a not-yet-finalized transition (RFC §2.8; the F1 no-false-terminal fix).
        local report="$state"
        case "$state" in replying|failing) report=claimed ;; esac
        printf '%s\n' "$report"
        return 0
    fi

    local target="$REPLIES_DIR/$id/$selector.md"
    if [[ ! -e "$target" ]]; then
        # A replied request written by the current code ALWAYS has a
        # materialized results.md, so this fallback fires only for (a) a
        # crash-recovered reply (the reaper finalized .replying→.replied without
        # re-materializing results.md) or (b) a LEGACY reply. Reconstruct the raw
        # body from the .replied.md, keying on the UNFORGEABLE body_bytes marker
        # (the reply body is the last N bytes) — no `## Reply` text search, so a
        # `## Reply` line in the request ## Details or the reply body cannot
        # mis-anchor it. A truly legacy file lacking body_bytes falls back to the
        # `## Reply` header, but REFUSES (rc 2) if that header is AMBIGUOUS
        # (>1 occurrence) rather than guess.
        if [[ "$state" == replied && "$selector" == results && -n "${path:-}" && -f "$path" ]]; then
            local n; n=$(_reply_body_bytes "$path")
            if [[ "$n" =~ ^[0-9]+$ ]]; then
                tail -c "$n" -- "$path"
                return 0
            fi
            # `grep -c` PRINTS `0` on no match and ALSO exits 1, so the old
            # `|| echo 0` appended a second `0` and nhdr became "0\n0" —
            # which `[[ -eq ]]` cannot evaluate: bash raises "syntax error in
            # expression" on stderr and BOTH branches below test false, so a
            # reply file with no `## Reply` header fell through the header
            # route silently. Issue #725.
            local nhdr; nhdr=$(grep -c '^## Reply$' -- "$path" 2>/dev/null) || nhdr=0
            [[ "$nhdr" =~ ^[0-9]+$ ]] || nhdr=0
            if [[ "$nhdr" -eq 1 ]]; then
                local rl; rl=$(grep -n '^## Reply$' -- "$path" | cut -d: -f1)
                tail -n +"$((rl + 2))" -- "$path"
                return 0
            elif [[ "$nhdr" -gt 1 ]]; then
                printf 'request-channel: legacy reply %s has an ambiguous ## Reply boundary and no body_bytes marker — refusing to guess; read the .replied file directly\n' "$id" >&2
                exit 2
            fi
        fi
        # progress on a replied request is a terminal, successful state (rc 0),
        # not an error — the round-trip is complete; point at the result.
        if [[ "$state" == replied && "$selector" == progress ]]; then
            printf 'request-channel: request %s is complete (state=replied) — the result is `fetch %s results` (or `await %s`)\n' \
                "$id" "$id" "$id"
            return 0
        fi
        if [[ "$selector" == results ]]; then
            printf 'request-channel: results not ready for id %s — poll `fetch %s progress`\n' "$id" "$id" >&2
            exit 3
        fi
        printf 'request-channel: no %s yet for id %s\n' "$selector" "$id" >&2
        exit 3
    fi
    # Symlink defence-in-depth: a results.md symlinked to a report is
    # honoured ONLY if its resolved target stays under the confinement
    # root. The client cannot supply the link target (the worker/
    # orchestrator created it), so this is belt-and-suspenders.
    if [[ -L "$target" ]]; then
        local real; real=$(readlink -f -- "$target" 2>/dev/null || true)
        local root; root=$(_confine_root)
        local rroot; rroot=$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")
        if [[ -z "$real" || "$real" != "$rroot"/* ]]; then
            printf 'request-channel: refusing %s: symlink target escapes the confinement root\n' "$target" >&2
            exit 2
        fi
    fi
    cat -- "$target"
}

# ── show / reqfile / dir / list ───────────────────────────────────────
cmd_show() {
    local id="${1:-}"; [[ -n "$id" ]] || die "usage: show <id>"
    _validate_id "$id"
    local sf path
    sf=$(_state_file_for_id "$id") || { printf 'request-channel: no request for id %s\n' "$(_arg_excerpt "$id")" >&2; exit 2; }
    path="${sf%$'\t'*}"
    cat -- "$path"
}

cmd_reqfile() {
    local id="${1:-}"; [[ -n "$id" ]] || die "usage: reqfile <id>"
    _validate_id "$id"
    local sf
    sf=$(_state_file_for_id "$id") || { printf 'request-channel: no request for id %s\n' "$(_arg_excerpt "$id")" >&2; exit 2; }
    printf '%s\n' "${sf%$'\t'*}"
}

cmd_dir() { printf '%s\n' "$REQ_DIR"; }

cmd_list() {
    local state=all
    _argloop_prev_4=-1; while (( $# > 0 )); do (( $# != _argloop_prev_4 )) || _argloop_stuck "$1"; _argloop_prev_4=$#
        case "$1" in
            --state) state="${2:-}"; shift 2 || die "--state needs a value" ;;
            *) die "list: unknown flag: $(_arg_excerpt "$1")" ;;
        esac
    done
    [[ -d "$REQ_DIR" ]] || return 0
    # The content-transition intermediates (.replying/.failing — a crashed
    # reply/fail pending the watcher reaper) are selected under `claimed`,
    # mirroring the reader rule everywhere else (`fetch status` reports them
    # as claimed; _state_file_for_id orders them with claimed): the --state
    # enum stays the five stable words. Each row still renders its LITERAL
    # filename suffix (`[replying]`), so the operator sees the truth.
    local -a globs=()
    case "$state" in
        new)      globs=("$REQ_DIR"/*.new.md) ;;
        claimed)  globs=("$REQ_DIR"/*.claimed.md "$REQ_DIR"/*.replying.md "$REQ_DIR"/*.failing.md) ;;
        replied)  globs=("$REQ_DIR"/*.replied.md) ;;
        done)     globs=("$REQ_DIR"/*.done.md) ;;
        failed)   globs=("$REQ_DIR"/*.failed.md) ;;
        all)      globs=("$REQ_DIR"/*.new.md "$REQ_DIR"/*.claimed.md "$REQ_DIR"/*.replying.md "$REQ_DIR"/*.failing.md "$REQ_DIR"/*.replied.md "$REQ_DIR"/*.done.md "$REQ_DIR"/*.failed.md) ;;
        *) die "list: --state must be new|claimed|replied|done|failed|all (claimed includes the pending replying/failing intermediates)" ;;
    esac
    local f base st origin kind
    for f in "${globs[@]}"; do
        [[ -e "$f" ]] || continue
        base=$(basename -- "$f")
        st="${base%.md}"; st="${st##*.}"
        origin=$(_chan_frontmatter_field "$f" origin)
        kind=$(_chan_frontmatter_field "$f" kind)
        printf '[%-8s] %-50s origin=%s kind=%s\n' "$st" "${base%.md}" "$origin" "$kind"
    done
}

# Read the reply block's builder-recorded `body_bytes` (the raw reply body's
# byte length) from the nested `reply:` frontmatter. This is the UNFORGEABLE
# boundary for locating the reply body — it is the LAST `body_bytes` bytes of
# the file — immune to a `## Reply` line appearing in the request `## Details`
# or in the reply body itself (both are free-form). Empty for a legacy reply
# written before the marker existed (callers must then refuse to guess). Reads
# only the nested key inside the `reply:` block, stopping at the next top-level
# frontmatter key. $1=file.
_reply_body_bytes() {
    awk '
        /^reply:[[:space:]]*$/ { r=1; next }
        r==1 && /^  body_bytes:[[:space:]]/ { sub(/^  body_bytes:[[:space:]]*/,""); print; exit }
        r==1 && /^[^[:space:]]/ { exit }
    ' "$1" 2>/dev/null
}

# ── transition content builders (invoked BY _chan_transition) ──────────
# Each writes the FULL intended <to-state> file content to $1 (a temp), reading
# the current on-disk request from $2 (the src path _chan_transition resolved).
# The engine then atomically swaps the temp into the claimed terminal slot. The
# P1 body-codec discipline is intact: the reply: block streams in from a FILE
# via getline (no `awk -v` escape processing carries multi-line text) and the
# BODY / reason is appended verbatim afterwards (cat / printf %s), so no
# backslash-escape mangling ever touches free prose (the #401 defect class).
#
# INTENTIONALLY BESPOKE vs _fm_lib.sh (#405 P2): these builders do NOT ride
# `_fm_put` — each is a coordinated whole-file transition (multi-line `reply:`
# block + `state:` flip + body append in ONE rename) that a single-key put
# cannot express. Their awk cores match the STRICT canonical form this file's
# own writers emit (`$0=="---"` fences, `/^state:[[:space:]]/`), tighter than
# the lib's lenient reader — correct here because the input is always a file
# this channel itself wrote. Parity with the shared reader is pinned by
# monitor/watcher/test-fm-lib.sh (legacy-parity + enumerated divergences).

# Fresh reply: inject the reply: block before the closing fence, flip state →
# replied, append "## Reply" + the byte-exact body. src is the .claimed file.
_build_reply_content() {
    local tmp="$1" src="$2" rbfile="$3" bodyfile="$4"
    awk -v rf="$rbfile" '
        BEGIN { infm=0 }
        NR==1 && $0=="---" { infm=1; print; next }
        infm && $0=="---" {
            while ((getline line < rf) > 0) print line
            close(rf); infm=0; print; next
        }
        infm && /^state:[[:space:]]/ { print "state: replied"; next }
        { print }
        END { print ""; print "## Reply"; print "" }
    ' "$src" > "$tmp" || return 1
    cat -- "$bodyfile" >> "$tmp" || return 1
}

# Amend an already-replied file (replied→replied): swap the OLD reply: block for
# the FRESH one (with amended_at) and replace the reply BODY, preserving the
# ## Request / ## Details request payload untouched. src is the .replied file.
#
# UNFORGEABLE boundary: the reply body is the LAST <n_old> bytes of the file
# (n_old = the builder-recorded `reply: body_bytes`, resolved + verified against
# results.md by cmd_reply BEFORE this runs). Everything before those bytes — the
# frontmatter, ## Request, ## Details, and the emitted `## Reply` header — is the
# byte-exact HEAD. There is NO `## Reply` text search anywhere: a `## Reply` line
# in the request `## Details` or in the reply body cannot mis-anchor the split
# (the round-3 BLOCKER-2 exploit). The awk touches ONLY the fenced frontmatter
# (swap the reply: block); the request sections + the `## Reply` header pass
# through verbatim, then the new body is appended. $5 = n_old (bytes).
_build_amend_content() {
    local tmp="$1" src="$2" rbfile="$3" bodyfile="$4" n_old="$5" fsize head_bytes
    [[ "$n_old" =~ ^[0-9]+$ ]] || return 1
    fsize=$(wc -c < "$src") || return 1
    head_bytes=$(( fsize - n_old ))
    (( head_bytes >= 0 )) || return 1
    # HEAD = the file minus the last n_old body bytes (frontmatter + request
    # sections + the trailing `## Reply\n\n` header). Swap the frontmatter reply:
    # block in place; pass everything after the fence (incl. the `## Reply`
    # header) through unchanged.
    head -c "$head_bytes" -- "$src" | awk -v rf="$rbfile" '
        BEGIN { infm=0; inreply=0 }
        NR==1 && $0=="---" { infm=1; print; next }
        infm && $0=="---" {
            while ((getline line < rf) > 0) print line
            close(rf); infm=0; inreply=0; print; next
        }
        infm && /^reply:[[:space:]]*$/ { inreply=1; next }
        infm && inreply && /^[[:space:]]/ { next }
        infm && inreply && /^[^[:space:]]/ { inreply=0 }
        infm && /^state:[[:space:]]/ { print "state: replied"; next }
        { print }
    ' > "$tmp" || return 1
    cat -- "$bodyfile" >> "$tmp" || return 1
}

# Fail: add failed_at, flip state → failed, append "## Failure" + the reason
# prose (verbatim). src is the .new/.claimed file.
_build_fail_content() {
    local tmp="$1" src="$2" reason="$3"
    awk -v ts="$(_chan_now_iso)" '
        NR==1 && $0=="---" { infm=1; print; next }
        infm && $0=="---" { print "failed_at: " ts; infm=0; print; next }
        infm && /^state:[[:space:]]/ { print "state: failed"; next }
        { print }
        END { print ""; print "## Failure"; print "" }
    ' "$src" > "$tmp" || return 1
    printf '%s\n' "$reason" >> "$tmp" || return 1
}

# _reply_refuse <rc> — every `cmd_reply` exit AFTER `_validate_id` and BEFORE
# the payload is opened routes through here, so no such refusal can forget to
# say what became of the payload (your-org/nexus-code#1358).
#
# THE SCOPE LINE IS LOAD-BEARING, AND IT HAS BEEN WRONG TWICE — READ IT BEFORE
# YOU TRUST IT. Version 1 said "every" while the code covered only the eight
# STATE refusals; three exits before the capture did not route through it (`no
# request for id` at exit 2, and the two `die`s for a corrupt `body_bytes` and
# an unrecognised state). Those three were then wired up — and the sentence was
# rewritten to the UNBOUNDED "EVERY `cmd_reply` exit that fires BEFORE the
# payload is opened … all eleven", which is a SECOND universal over a subset,
# committed in the act of correcting the first. Measured at `dc00d87f`, five
# exits fire before the payload is opened and print no payload note:
#
#     malformed id (`_validate_id`)                          rc 1
#     no id at all (the usage `die`)                         rc 1
#     unknown flag (`--*) die`)                              rc 1
#     stray positional (`_die_positional`)                   rc 1
#     dangling `--file`/`--message` with no value            rc 1
#
# The last is the sharpest: the arg loop appends the pair to `body_args` and
# THEN dies on the failed `shift 2`, so the text is in the array and still
# unreported. The CODE is defensible — these are argument-parse errors, before
# an id has been established — so the fix is this narrowed sentence, not eleven
# more call sites. What is not defensible is a universal quantifier nobody
# re-derives: version 1's failure was an unchecked "every", and so was version
# 2's. If you widen the routing, widen this line; if you widen this line, count
# the arms first.
#
# Reads the caller's `body_args` by dynamic scope, deliberately and documented:
# `cmd_reply` is the only caller and the array is its local. Threading it
# through every call site is the thing that eventually gets one of them wrong
# — which is precisely what happened when there were eight. The
# `${body_args[@]+…}` guard degrades a future caller lacking the array to a
# silent refusal rather than an unbound-variable failure INSIDE a refusal that
# is already in progress.
_reply_refuse() {
    _reply_payload_note ${body_args[@]+"${body_args[@]}"} >&2
    exit "${1:-6}"
}
_reply_refuse_6() { _reply_refuse 6; }

# _reply_payload_note <body_args...>
# Say what became of a reply payload the refusal path never read
# (your-org/nexus-code#1358). Prints one or more stderr-ready lines; prints
# NOTHING when no payload was supplied.
#
# WHY THIS EXISTS. `cmd_reply` parses `--file`/`--message` into `body_args` and
# does not open them until AFTER every state refusal has exited. So a refused
# reply loses no bytes — and says nothing about that either, which is the same
# silence the channel exists to prevent. The two cases differ and the
# difference is the whole point:
#
#   --file <p>   the bytes were NEVER OPENED and are unchanged at <p>. Nothing
#                to recover; the caller just has to be told where they still are.
#   --message t  the text lived only in argv and dies with the process, so it is
#                spilled to a temp file HERE and the path is named.
#   -            stdin. Deliberately NOT drained: this runs on a refusal path
#                whose stdin is whatever the caller had, and reading an
#                inherited terminal stdin BLOCKS. Say it was not read.
#
# Best-effort throughout: a spill that cannot be written degrades to naming the
# loss, never to failing the refusal that is already in progress.
_reply_payload_note() {
    local i=0 n=$# a v spill
    local -a args=("$@")
    while (( i < n )); do
        a="${args[i]}"; v="${args[i+1]:-}"
        case "$a" in
            --file)
                printf '  Your `--file %s` was NOT read — this verb opens the payload only after\n' "$v"
                printf '  the state check above, so its bytes are unchanged at that path.\n'
                i=$(( i + 2 )) ;;
            --message)
                spill=$(mktemp "${TMPDIR:-/tmp}/reqreply-refused.XXXXXX" 2>/dev/null) || spill=""
                if [[ -n "$spill" ]] && printf '%s\n' "$v" > "$spill" 2>/dev/null; then
                    printf '  Your `--message` text was NOT recorded on the request. It lived only in\n'
                    printf '  argv, so it has been spilled to: %s\n' "$spill"
                else
                    printf '  Your `--message` text was NOT recorded and could not be spilled to a temp\n'
                    printf '  file — it exists nowhere but your own scrollback. Copy it before retrying.\n'
                fi
                i=$(( i + 2 )) ;;
            -)
                printf '  A stdin payload (`-`) was NOT read. It is deliberately not drained here:\n'
                printf '  this is a refusal path and reading an inherited stdin would block.\n'
                i=$(( i + 1 )) ;;
            *)  i=$(( i + 1 )) ;;
        esac
    done
}

# ── reply (orchestrator → client; .claimed → .replied; --amend: replied→replied)
cmd_reply() {
    local id=""
    local status="" worker="" wdir="" issue="" publish="" progress="" results="" amend=0
    local skeptic_resolved=0
    local -a body_args=()
    _argloop_prev_5=-1; while (( $# > 0 )); do (( $# != _argloop_prev_5 )) || _argloop_stuck "$1"; _argloop_prev_5=$#
        case "$1" in
            --status)   status="${2:-}";   shift 2 || die "--status needs a value" ;;
            --worker)   worker="${2:-}";   shift 2 || die "--worker needs a value" ;;
            --dir)      wdir="${2:-}";     shift 2 || die "--dir needs a path" ;;
            --issue)    issue="${2:-}";    shift 2 || die "--issue needs owner/repo#N" ;;
            --no-publish) publish="false"; shift ;;
            --amend)    amend=1;           shift ;;
            --skeptic-resolved) skeptic_resolved=1; shift ;;
            --progress) progress="${2:-}"; shift 2 || die "--progress needs a path" ;;
            --results)  results="${2:-}";  shift 2 || die "--results needs a path" ;;
            --file|--message) body_args+=("$1" "${2:-}"); shift 2 || die "$1 needs a value" ;;
            -)          body_args+=("-");   shift ;;
            --*) die "reply: unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$id" ]]; then id="$1"
                else _die_positional "reply" "$1" "--message/--file"; fi
                shift ;;
        esac
    done
    [[ -n "$id" ]] || die "usage: reply <id> [--message t|--file f] [--status spawned|answered|declined|deferred] [--worker w] [--dir p] [--issue o/r#N] [--no-publish] [--amend] [--skeptic-resolved] [--progress p] [--results p]"
    _validate_id "$id"

    # Pre-check for a precise voice on a STABLE state. The transition engine
    # re-validates independently (its resolve is the authority under a race);
    # this block only chooses the user-facing message + gates --amend.
    local sf path state
    sf=$(_state_file_for_id "$id") || { printf 'request-channel: no request for id %s\n' "$(_arg_excerpt "$id")" >&2; _reply_refuse 2; }
    path="${sf%$'\t'*}"; state="${sf##*$'\t'}"
    local amend_n_old=""
    if (( amend )); then
        case "$state" in
            replied) ;;
            replying|failing) printf 'request-channel: id %s has an in-flight/crashed transition (%s); the watcher reaper recovers it — retry --amend after\n' "$id" "$state" >&2; _reply_refuse_6 ;;
            *) printf 'request-channel: reply --amend requires a replied request; id %s is %s\n' "$id" "$state" >&2; _reply_refuse_6 ;;
        esac
        # UNFORGEABLE amend boundary: the reply body is the last body_bytes bytes.
        # A legacy .replied written before the marker existed cannot be amended
        # safely (its body boundary is not machine-locatable) — REFUSE, never
        # guess by scanning for `## Reply` (forgeable). Then VERIFY the recorded
        # length actually matches the materialized results.md (a byte compare)
        # and refuse on any mismatch (hand-edited / corrupted file).
        amend_n_old=$(_reply_body_bytes "$path")
        if [[ -z "$amend_n_old" ]]; then
            printf 'request-channel: id %s is a legacy reply without a body_bytes marker; --amend cannot locate the reply body safely — re-reply manually (fail + fresh reply) instead\n' "$id" >&2
            _reply_refuse_6
        fi
        [[ "$amend_n_old" =~ ^[0-9]+$ ]] || { _reply_payload_note ${body_args[@]+"${body_args[@]}"} >&2
            die "reply --amend: corrupt body_bytes ($amend_n_old) for id $id"; }
        local _results="$REPLIES_DIR/$id/results.md"
        if [[ -f "$_results" ]]; then
            if ! tail -c "$amend_n_old" -- "$path" | cmp -s - "$_results"; then
                printf 'request-channel: id %s reply body (last %s bytes) does not match results.md — refusing to amend a tampered/corrupt reply\n' "$id" "$amend_n_old" >&2
                _reply_refuse_6
            fi
        fi
        # (results.md absent — e.g. a crash-recovered reply — leaves body_bytes,
        # itself unforgeable frontmatter, as the sole authority; nothing to cross-check.)
    else
        case "$state" in
            claimed) ;;
            replied) printf 'request-channel: id %s is already replied (one reply per request; use --amend to update)\n' "$id" >&2; _reply_refuse_6 ;;
            done|failed) printf 'request-channel: id %s is terminal (%s); cannot reply\n' "$id" "$state" >&2; _reply_refuse_6 ;;
            replying|failing) printf 'request-channel: id %s has an in-flight/crashed transition (%s); the watcher reaper recovers it — retry after\n' "$id" "$state" >&2; _reply_refuse_6 ;;
            new) printf 'request-channel: id %s is unclaimed (.new); the watcher claims before reply\n' "$id" >&2; _reply_refuse_6 ;;
            *) _reply_payload_note ${body_args[@]+"${body_args[@]}"} >&2
               die "reply: unexpected state for id $id: $state" ;;
        esac
    fi

    # Body is optional prose. Capture it BYTE-EXACT into a temp file — never a
    # shell variable + awk -v (both mangle the body): $(…) strips trailing
    # newlines and awk -v applies backslash-escape processing (\n, \t, \\, \",
    # \{ …), which silently corrupts+shortens any script/code/JSON/regex sent
    # as a reply. Same byte-fidelity contract as request file's --message-stdin.
    local bodyfile
    if (( ${#body_args[@]} > 0 )); then
        bodyfile=$(_chan_body_capture die "${body_args[@]}") || exit 1
    else
        bodyfile=$(mktemp "${TMPDIR:-/tmp}/reqreply-body.XXXXXX") || die "reply: mktemp (body) failed"
    fi
    # Synthesize a minimal line if no (non-empty) body was supplied.
    if [[ ! -s "$bodyfile" ]]; then
        printf '(see the reply: frontmatter above for references.)\n' > "$bodyfile"
    fi
    # publish flag: --no-publish wins; else DERIVE it. For a fresh reply, inherit
    # the request's top-level `publish` frontmatter. For --amend, inherit the
    # PRIOR reply's publish (the nested reply.publish) so an amend does NOT
    # silently flip a --no-publish reply back to published — an amend that means
    # to change publish must pass --no-publish (or would re-derive published)
    # explicitly. Default true.
    if [[ -z "$publish" ]]; then
        if (( amend )); then
            publish=$(awk '
                /^reply:[[:space:]]*$/ { r=1; next }
                r==1 && /^  publish:[[:space:]]/ { sub(/^  publish:[[:space:]]*/,""); print; exit }
                r==1 && /^[^[:space:]]/ { exit }
            ' "$path")
        else
            publish=$(_chan_frontmatter_field "$path" publish)
        fi
        [[ "$publish" == "false" ]] || publish="true"
    fi
    # status default: spawned if a worker is named, else answered.
    if [[ -z "$status" ]]; then
        if [[ -n "$worker" ]]; then status="spawned"; else status="answered"; fi
    fi

    # ---- A REPLY'S STATUS IS A SELECTOR, SO IT IS NOT A FREE LABEL ---------
    #
    # `status` used to accept any string and nothing read it. It is now the
    # field that decides whether answering a `spawn-skeptic` request DISCHARGES
    # the skeptic gate the request was filed against, so an unrecognised value
    # must be a REFUSAL and not a silent accept: the moment a value SELECTS,
    # adding a member is a behavioural change that has to teach the matcher in
    # the same commit (your-org/nexus-code#1050). Allowlist, default-DENY. The
    # arms are literal equality over disjoint values, so no arm can shadow
    # another (#1121).
    #
    #   spawned   a reviewer was spawned; ITS verdict discharges the gate later
    #   declined  the orchestrator declined the review; the gate must be
    #             discharged HERE, because nothing else will
    #   deferred  not now, ask again — deliberately does NOT discharge the gate
    #   answered  an ordinary answer to a non-gating request
    case "$status" in
        spawned|answered|declined|deferred) ;;
        *) printf 'request-channel: reply --status %s is not a recognised status.\n' "$(_arg_excerpt "$status")" >&2
           printf '  Known: spawned | answered | declined | deferred\n' >&2
           printf '  This field SELECTS (a spawn-skeptic decline discharges the skeptic gate),\n' >&2
           printf '  so an unknown value is refused rather than recorded as a label.\n' >&2
           exit 2 ;;
    esac

    # ---- ACTING ON A DECISION MUST RECORD IT ------------------------------
    #
    # Answering a `spawn-skeptic` request — including DECLINING it — used to
    # write nothing to the skeptic ledger. The request moved to `.replied.md`,
    # this verb returned 0, the requesting agent read the decline and
    # reasonably reported it as recorded, and `retire-window` later refused
    # with "a cleared marker is not clearance" because from the ledger's side
    # no verdict and no resolution existed. Measured three times in one
    # session (`olayship`, `ctxdiff`, `integ`); each was fixed by re-issuing
    # the SAME decision through `ng skeptic resolve`, so the decision was never
    # in doubt — only its record. It also produced re-filing loops: three
    # windows filed the same request twice and one filed it four times,
    # because a reply resolves the REQUEST without changing anything the
    # requester's wrap-up path reads. Answering harder does not help.
    # (your-org/nexus-code#1293; the ambiguity is #961 / #1199.)
    #
    # A DECLINE THAT IS NOT RECORDED IS INDISTINGUISHABLE FROM A REVIEW THAT
    # NEVER HAPPENED. So on a spawn-skeptic request this verb refuses to leave
    # the answer's MEANING unstated, and on a decline it makes the decision and
    # its durable record ONE act.
    local req_kind req_origin
    req_kind=$(_chan_frontmatter_field "$path" kind)
    req_origin=$(_chan_frontmatter_field "$path" origin)
    if [[ "$req_kind" == "spawn-skeptic" ]] && (( amend == 0 )); then
        case "$status" in
            spawned)
                # A spawn is discharged later by the reviewer's own verdict —
                # but only if a reviewer actually exists. Naming it is the
                # whole content of the claim.
                if [[ -z "$worker" ]]; then
                    printf 'request-channel: --status spawned on a spawn-skeptic request must name the reviewer (--worker <window>).\n' >&2
                    printf '  The gate is discharged by THAT window'"'"'s verdict; an unnamed spawn discharges nothing.\n' >&2
                    exit 6
                fi
                ;;
            answered)
                # The ambiguous case that caused all three incidents. `answered`
                # cannot say whether a reviewer is coming, so nothing downstream
                # can tell a decline from a spawn — which is exactly why the
                # population on disk is unclassifiable after the fact.
                printf 'request-channel: --status answered is ambiguous on a spawn-skeptic request.\n' >&2
                printf '  Say which answer this is, so the ledger and the request agree:\n' >&2
                printf '    --status spawned --worker <window>   a reviewer is coming; ITS verdict discharges the gate\n' >&2
                printf '    --status declined                    no review; this verb discharges the gate now\n' >&2
                printf '    --status deferred                    not now — the gate STAYS armed on purpose\n' >&2
                exit 6 ;;
            declined)
                if (( skeptic_resolved )); then
                    printf 'request-channel: NOTE — --skeptic-resolved given; not resolving %s again. You are asserting the gate is already discharged.\n' \
                        "${req_origin:-<unknown-origin>}" >&2
                else
                    [[ -n "$req_origin" ]] || { printf 'request-channel: spawn-skeptic decline for id %s has no `origin` in its frontmatter; cannot resolve a gate without a window\n' "$id" >&2; exit 6; }
                    # The rationale is written to the audit trail beside the
                    # marker and `resolve` requires it to be substantive. Refuse
                    # a too-short body rather than PADDING one: a manufactured
                    # rationale is worse than no verb at all.
                    local _sk_reason; _sk_reason=$(tr '\n' ' ' < "$bodyfile" | sed 's/  */ /g; s/^ //; s/ $//')
                    if (( ${#_sk_reason} < 20 )); then
                        rm -f "$bodyfile"
                        printf 'request-channel: a spawn-skeptic DECLINE discharges %s'"'"'s skeptic gate, and that goes on the audit trail.\n' "$req_origin" >&2
                        printf '  Give a substantive --message (>=20 chars) saying WHY the review is declined.\n' >&2
                        exit 6
                    fi
                    # ORDER IS THE GUARANTEE (your-org/nexus-code#665): resolve
                    # BEFORE the request transitions. resolve-then-reply fails
                    # LOUD — the caller sees a non-zero reply and nothing was
                    # consumed. reply-then-resolve fails SILENT: the request is
                    # already `.replied`, the caller believes the decision
                    # landed, and that IS this bug.
                    local _sk_bin="$_script_dir/skeptic-channel.sh" _sk_out _sk_rc
                    if [[ ! -x "$_sk_bin" ]]; then
                        rm -f "$bodyfile"
                        printf 'request-channel: cannot resolve %s'"'"'s skeptic gate — %s is missing or not executable. REFUSING the reply rather than recording a decline nothing will see.\n' "$req_origin" "$_sk_bin" >&2
                        exit 6
                    fi
                    _sk_out=$("$_sk_bin" resolve "$req_origin" --reason "spawn-skeptic request $id DECLINED by the orchestrator: $_sk_reason" 2>&1); _sk_rc=$?
                    if (( _sk_rc != 0 )); then
                        rm -f "$bodyfile"
                        printf 'request-channel: the skeptic gate for %s was NOT resolved (rc %s) — REFUSING to record the decline.\n' "$req_origin" "$_sk_rc" >&2
                        printf '%s\n' "$_sk_out" | sed 's/^/  /' >&2
                        printf '  Nothing was written. If the gate is already discharged, re-run with --skeptic-resolved.\n' >&2
                        exit 6
                    fi
                    printf 'request-channel: resolved %s'"'"'s skeptic gate on the record before replying (your-org/nexus-code#1293).\n' "$req_origin" >&2
                fi
                ;;
            deferred)
                printf 'request-channel: NOTE — --status deferred leaves %s'"'"'s skeptic gate ARMED on purpose; retirement will still require a verdict or a resolution.\n' \
                    "${req_origin:-<unknown-origin>}" >&2
                ;;
        esac
    fi
    # session_id best-effort from the worker's window record (liveness hint).
    local session_id=""
    if [[ -n "$worker" ]] && command -v jq >/dev/null 2>&1; then
        local rec="$STATE_DIR/windows/$(_chan_safe "$worker").json"
        [[ -f "$rec" ]] && session_id=$(jq -r '.session_id // ""' "$rec" 2>/dev/null) || session_id=""
    fi

    # Assemble the nested reply: block into a FILE (getline-streamed by the
    # builder — charset-safe, no awk -v text). --amend refreshes replied_at and
    # stamps an amended_at field.
    # body_bytes: the exact byte length of the reply body appended below — the
    # UNFORGEABLE marker that lets `--amend` and the legacy fetch-results
    # fallback locate the reply body as the file's last N bytes, with no
    # `## Reply` text search (which a request/reply body could forge).
    local body_n; body_n=$(wc -c < "$bodyfile") || body_n=0
    body_n=${body_n//[^0-9]/}
    local replied_at; replied_at=$(_chan_now_iso)
    local rblock=""
    rblock+=$'reply:\n'
    rblock+="  status: $status"$'\n'
    rblock+="  replied_at: $replied_at"$'\n'
    (( amend )) && rblock+="  amended_at: $replied_at"$'\n'
    rblock+="  publish: $publish"$'\n'
    rblock+="  body_bytes: $body_n"$'\n'
    if [[ -n "$worker" ]]; then
        rblock+=$'  worker:\n'
        rblock+="    window: $worker"$'\n'
        [[ -n "$wdir"       ]] && rblock+="    directory: $wdir"$'\n'
        [[ -n "$session_id" ]] && rblock+="    session_id: $session_id"$'\n'
    fi
    if [[ "$publish" == "false" ]]; then
        rblock+="  progress_path: monitor/.state/requests/replies/$id/progress.md"$'\n'
        rblock+="  results_path:  monitor/.state/requests/replies/$id/results.md"$'\n'
    elif [[ -n "$issue" ]]; then
        rblock+="  github_issue: $issue"$'\n'
    fi
    local rbfile; rbfile=$(mktemp "${TMPDIR:-/tmp}/reqreply-rblock.XXXXXX") \
        || { rm -f "$bodyfile"; die "reply: mktemp (rblock) failed"; }
    printf '%s' "$rblock" > "$rbfile"

    # Route the state change through the transition engine (claim-first via a
    # non-authoritative intermediate, one re-resolve retry). A fresh reply is
    # claimed→[.replying]→replied; --amend is a replied→replied same-state content
    # update (no intermediate — one atomic temp+mv over the stable terminal file).
    local dst rc
    if (( amend )); then
        dst=$(_chan_transition die _state_file_for_id "$id" replied - "replied" _build_amend_content "$rbfile" "$bodyfile" "$amend_n_old"); rc=$?
    else
        dst=$(_chan_transition die _state_file_for_id "$id" replied replying "claimed" _build_reply_content "$rbfile" "$bodyfile"); rc=$?
    fi
    rm -f "$rbfile"

    case "$rc" in
        0) ;;
        6) # The state changed under us between the pre-check and the engine's
           # resolve — the classic case is the max-age reaper renaming
           # .claimed → .failed. Report LOUDLY; the terminal file the racer
           # produced is byte-intact (claim-first never wrote to it).
           rm -f "$bodyfile"
           local now_state="unknown"
           local nsf; nsf=$(_state_file_for_id "$id") && now_state="${nsf##*$'\t'}"
           printf 'request-channel: reply lost the race for id %s (now %s) — the request was concurrently transitioned (reaper/ack); terminal file left intact, no reply written\n' \
               "$id" "$now_state" >&2
           exit 6 ;;
        2) rm -f "$bodyfile"; printf 'request-channel: no request for id %s\n' "$(_arg_excerpt "$id")" >&2; exit 2 ;;
        7) rm -f "$bodyfile"; die "reply: id $id kept being renamed under a concurrent writer; retry" ;;
        *) rm -f "$bodyfile"; die "reply: transition failed for $id (rc $rc)" ;;
    esac

    # Materialize the fetchable results.md into the confined reply dir ONLY on a
    # WON transition (a lost race must never leave a fetchable result on a
    # failed request). Copy, never a deref of a client path; the fetch verb
    # recomputes its target from <id> and ignores any client-supplied path (RFC
    # §D.6). ALWAYS write it as a BYTE-EXACT copy of the raw reply body (an
    # explicit --results artifact wins) — this makes `fetch <id> results` a
    # corruption-proof RAW-BYTES transport. --amend re-materializes it byte-exact.
    local reply_dir="$REPLIES_DIR/$id"
    mkdir -p "$reply_dir" 2>/dev/null || true
    if [[ -n "$results" && -f "$results" ]]; then
        cp -f -- "$results" "$reply_dir/results.md" 2>/dev/null || true
    else
        cp -f -- "$bodyfile" "$reply_dir/results.md" 2>/dev/null || true
    fi
    [[ -n "$progress" && -f "$progress" ]] && cp -f -- "$progress" "$reply_dir/progress.md" 2>/dev/null || true
    rm -f "$bodyfile"
    printf '%s\n' "$dst"
}

# ── ack (orchestrator; new|claimed → done; idempotent) ─────────────────
cmd_ack() {
    local id="${1:-}"; [[ -n "$id" ]] || die "usage: ack <id>"
    _validate_id "$id"
    # REPLY-REQUIRED GUARD: ack is the TERMINAL "acknowledged, no reply body"
    # transition (.new|.claimed → .done). Running it on a request whose
    # frontmatter demands `reply: required` would CLOSE the request WITHOUT the
    # demanded reply — silent data loss the client cannot detect: it keeps
    # awaiting a reply that never lands, and the operator has to re-file (the
    # real incident that motivated this guard). Refuse LOUDLY and redirect to
    # `reply`, making the footgun structurally impossible. Only a LIVE
    # (new|claimed) request is at risk; an already-terminal id (replied → the
    # reply was given; done/failed → handled or moot) falls through to the
    # idempotent transition below, which is the correct harmless no-op —
    # re-acking a settled request must never start erroring.
    local _sf _path _state _reply
    if _sf=$(_state_file_for_id "$id"); then
        _path="${_sf%$'\t'*}"; _state="${_sf##*$'\t'}"
        case "$_state" in
            new|claimed)
                _reply=$(_chan_frontmatter_field "$_path" reply)
                if [[ "$_reply" == required ]]; then
                    printf 'request-channel: id %s is reply:required — use `ng request reply %s …` (ack would close it to .done WITHOUT the required reply)\n' \
                        "$id" "$id" >&2
                    exit 6
                fi ;;
        esac
    fi
    # Pure state rename (no content rewrite — the filename suffix is the state
    # of record) through the transition engine: an ack that races the watcher's
    # new→claimed claim re-resolves and completes from .claimed (ack-from-claimed
    # is legal), instead of the old spurious hard die.
    local out rc
    out=$(_chan_transition die _state_file_for_id "$id" done - "new claimed" -); rc=$?
    case "$rc" in
        0) # RESTAMP: `rename(2)` PRESERVES mtime, and the GC reads mtime
           # (your-org/nexus-code#1358). `ack` is a pure rename, so without this
           # a `.done.md` carries the mtime it had as `.new.md` — its FILING
           # time — and `watcher/_requests.sh`'s retention sweep ages it from
           # when it was asked rather than from when it was answered. Measured
           # on the live store 2026-09-02: 79/79 `.done.md` mtimes match their
           # own `created:` to the second (max delta 0s), while 0/99
           # `.replied.md` do (max delta 6174s) — because a reply is a content
           # transition and lands a fresh file.
           #
           # THE TAIL IS THE PART THAT BITES: retention and max-age are the SAME
           # default (259200s / 72h), so a request that dwells near the max-age
           # cap and is then acked is GC'd almost immediately instead of 72h
           # later. Bounded, but the bound is total loss of retention.
           #
           # Best-effort: a `touch` that fails leaves exactly the pre-fix
           # behaviour, which is a shortened retention and never a lost request,
           # so it must not fail an otherwise-successful ack.
           [[ -n "$out" ]] && touch -- "$out" 2>/dev/null || true
           printf '%s\n' "$out"; return 0 ;;
        2) # No live file: GC'd or never existed. Idempotent no-op.
           printf 'request-channel: id %s not present (already acked/GC'"'"'d?) — no-op\n' "$id" >&2
           return 0 ;;
        6) # Already terminal in a state ack does not own (replied/failed) —
           # harmless; the request is handled.
           local nsf st="?"; nsf=$(_state_file_for_id "$id") && st="${nsf##*$'\t'}"
           printf 'request-channel: id %s already terminal (%s)\n' "$id" "$st" >&2
           return 0 ;;
        7) die "ack: id $id kept being renamed under a concurrent claim; retry" ;;
        *) die "ack: transition failed for $id (rc $rc)" ;;
    esac
}

# ── fail (orchestrator/watcher; new|claimed → failed) ──────────────────
cmd_fail() {
    local id=""
    local reason=""
    _argloop_prev_6=-1; while (( $# > 0 )); do (( $# != _argloop_prev_6 )) || _argloop_stuck "$1"; _argloop_prev_6=$#
        case "$1" in
            --reason) reason="${2:-}"; shift 2 || die "--reason needs text" ;;
            --*) die "fail: unknown flag: $(_arg_excerpt "$1")" ;;
            *)  if [[ -z "$id" ]]; then id="$1"
                else _die_positional "fail" "$1" "--reason"; fi
                shift ;;
        esac
    done
    [[ -n "$id" ]] || die "usage: fail <id> --reason \"<why>\""
    _validate_id "$id"
    [[ -n "$reason" ]] || die "fail: --reason is required"
    local out rc
    out=$(_chan_transition die _state_file_for_id "$id" failed failing "new claimed" _build_fail_content "$reason"); rc=$?
    case "$rc" in
        0) printf '%s\n' "$out"; return 0 ;;   # transitioned OR idempotent (already .failed)
        2) printf 'request-channel: no request for id %s\n' "$(_arg_excerpt "$id")" >&2; exit 2 ;;
        6) # Not in a failable state (done/replied terminal, or an in-flight
           # replying/failing intermediate) — refuse.
           local nsf st="?"; nsf=$(_state_file_for_id "$id") && st="${nsf##*$'\t'}"
           printf 'request-channel: id %s is %s; not failing\n' "$id" "$st" >&2
           return 6 ;;
        7) die "fail: id $id kept being renamed under a concurrent writer; retry" ;;
        *) die "fail: transition failed for $id (rc $rc)" ;;
    esac
}

main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        file)     cmd_file    "$@" ;;
        await)    cmd_await   "$@" ;;
        fetch)    cmd_fetch   "$@" ;;
        show)     cmd_show    "$@" ;;
        reqfile)  cmd_reqfile "$@" ;;
        dir)      cmd_dir     "$@" ;;
        list)     cmd_list    "$@" ;;
        reply)    cmd_reply   "$@" ;;
        ack)      cmd_ack     "$@" ;;
        fail)     cmd_fail    "$@" ;;
        -h|--help|"")
            awk '/^$/{exit} NR>1' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            [[ -z "$sub" ]] && exit 1 || exit 0
            ;;
        *) die "unknown subcommand: $(_arg_excerpt "$sub") (run with --help)" ;;
    esac
}

main "$@"
