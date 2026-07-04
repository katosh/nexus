#!/usr/bin/env bash
# _channel_lib.sh — the shared "rename is the signal" primitives for the
# nexus file-based channels (Part C harmonization, agent-channel RFC §2.8).
#
# Two channels in the tree speak the same dialect:
#   - monitor/skeptic-channel.sh — worker ↔ skeptic (peer, within a review)
#   - monitor/request-channel.sh — worker/client → orchestrator (escalation)
# Both encode state in a filename suffix, publish every state-producing
# write via a temp file + atomic `mv -f`, and treat the rename ITSELF as
# the cross-process signal. This file is the single home for that core so
# a developer who knows one channel knows the other and the primitive is
# not re-derived per channel.
#
# Scope discipline (deliberate): request-channel.sh sources this lib.
# skeptic-channel.sh is NOT yet migrated onto it — it is a working,
# independently-tested channel, and rewriting its internals would
# destabilize a load-bearing path for zero behavioural gain. The RFC
# files that migration as an OPTIONAL, parity-gated follow-up (§2.8
# "recommended refactor"; §5 rows C1/C2). This lib is structured so that
# migration is a mechanical later step: every helper here mirrors a
# skeptic-channel.sh counterpart 1:1 (named in the comments below).
#
# Sourcing contract: this file defines functions only — no side effects,
# no `set` changes, no global writes. Source it after resolving STATE_DIR.

# The keyed-field primitive lives in _fm_lib.sh (the single reader/writer both
# channels + the token records share, #405 P2). Pull it in from this lib's own
# directory so every _channel_lib.sh consumer gets `_fm_get` in scope; the guard
# in _fm_lib.sh makes a double-source (e.g. via _remote_lib.sh) a no-op, and it
# too defines functions only, so the side-effect-free contract above holds.
# shellcheck source=_fm_lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_fm_lib.sh"

# Sanitize an identifier (window name / origin / slug / principal) into a
# filename-safe token. Mirrors skeptic-channel.sh:_safe and the rule
# spawn-worker.sh uses for window-keyed state files. Anything outside
# [A-Za-z0-9_-] collapses to `_`.
_chan_safe() { printf '%s' "${1//[^a-zA-Z0-9_-]/_}"; }

# Force a UTF-8 locale so an inherited C/POSIX (ASCII) locale — the common
# default for a daemon-spawned SSH forced command, and for a bare cron/
# supervisor env — cannot make a locale-sensitive tool choke on a UTF-8
# request body: awk multibyte handling, a `read`/`${#s}` byte-vs-char count,
# or a future Python helper whose stdio codec defaults to ASCII and throws
# UnicodeDecodeError on the first non-ASCII byte. A remote client filed a
# request under LC_ALL=C and hit exactly that (agent-channel RFC Part B/D).
# Belt-and-suspenders alongside the byte-transparent `printf`/`cat` writes:
# it can never HURT (writing UTF-8 under UTF-8 is correct) and closes the
# whole class of ASCII-locale breakage.
#
# Idempotent + conservative: a NO-OP if the ambient locale is already some
# UTF-8 spelling (respect an operator's explicit choice) or if no UTF-8
# locale is installed (never break a minimal host). Exports LC_ALL + LANG
# (a real side effect) — so call it ONLY from a short-lived entrypoint or a
# subshell, NEVER at source time (this lib's sourcing contract is side-effect
# free; this helper is opt-in by call).
_chan_apply_utf8_locale() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]*) return 0 ;;   # already a UTF-8 spelling → leave it
    esac
    local _cand
    for _cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if locale -a 2>/dev/null | grep -qxF "$_cand"; then
            export LC_ALL="$_cand" LANG="$_cand"
            return 0
        fi
    done
    return 0
}

# ISO-8601 UTC timestamp. Mirrors skeptic-channel.sh:_now_iso.
_chan_now_iso() { date -Is 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

# Second-granular sortable UTC stamp for request-id stems
# (YYYYMMDDTHHMMSSZ). Sortable lexicographically → FIFO-by-default.
# CHAN_TS_OVERRIDE is a test seam: it pins the stamp so the same-second
# collision / disambiguator path is deterministically exercisable.
_chan_ts() {
    if [[ -n "${CHAN_TS_OVERRIDE:-}" ]]; then printf '%s' "$CHAN_TS_OVERRIDE"; return; fi
    date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s
}

# Read a --file / --message / stdin body to stdout. Byte-for-byte the
# contract of skeptic-channel.sh:_read_body. Returns non-zero (via the
# caller's die) on an empty/ambiguous spec.
#
# $1 = a "die" function name to call on error (so each channel keeps its
# own prefixed error voice); remaining args are the flag stream.
_chan_read_body() {
    local _die="$1"; shift
    local file="" text="" have_dash=0
    while (( $# > 0 )); do
        case "$1" in
            --file)    file="${2:-}"; shift 2 || { "$_die" "--file needs a path"; return 1; } ;;
            --message) text="${2:-}"; shift 2 || { "$_die" "--message needs text"; return 1; } ;;
            -)         have_dash=1;   shift ;;
            *)         "$_die" "unexpected argument: $1"; return 1 ;;
        esac
    done
    if [[ -n "$file" && -n "$text" ]]; then
        "$_die" "--file and --message are mutually exclusive"; return 1
    fi
    if [[ -n "$file" ]]; then
        [[ -r "$file" ]] || { "$_die" "cannot read --file: $file"; return 1; }
        cat -- "$file"
    elif [[ -n "$text" ]]; then
        printf '%s' "$text"
    elif (( have_dash )) || [[ ! -t 0 ]]; then
        cat
    else
        "$_die" "no body: pass --file <p>, --message <t>, or pipe to stdin"; return 1
    fi
}

# Capture a --file/--message/stdin body into a fresh temp FILE, byte-exact,
# and print that temp path on stdout. The FILE — never a shell string — is the
# canonical body carrier across the channel: a $(…) capture strips trailing
# newlines and an argv / `awk -v` hop applies backslash-escape processing,
# either of which silently corrupts+shortens a script/JSON/regex/prose body.
# So a body must never transit a shell variable; it streams file→file. The
# caller OWNS the printed path and must `rm` it. $1 = a die-fn (each channel
# keeps its own error voice); remaining args are the _chan_read_body flag
# stream. Fails non-zero on an empty/ambiguous spec with the temp removed —
# INCLUDING when the die-fn `exit`s: the rm line below is unreachable past an
# exiting die, so an EXIT trap carries the cleanup on that path. The trap is
# safe exactly because this function MUST be invoked inside a $(…) capture
# (that is also how the path gets returned): the command-substitution subshell
# starts trap-free, so setting/clearing EXIT here cannot clobber a caller trap.
# The trap stashes the path in a shell-global, NOT the local: bash unwinds the
# function's locals before running the EXIT trap when the exit comes from a
# callee (the die-fn), so a fire-time `$_bf` is gone — empty at best, an
# unbound-variable abort under `set -u` — and the rm would silently miss.
_chan_body_capture() {
    local _die="$1"; shift
    local _bf
    _bf=$(mktemp "${TMPDIR:-/tmp}/chanbody.XXXXXX") || { "$_die" "mktemp (body) failed"; return 1; }
    _CHAN_BODY_CAPTURE_TMP="$_bf"
    trap 'rm -f "${_CHAN_BODY_CAPTURE_TMP:-}" 2>/dev/null' EXIT
    if ! _chan_read_body "$_die" "$@" > "$_bf"; then
        rm -f "$_bf" 2>/dev/null || true
        trap - EXIT
        return 1
    fi
    trap - EXIT
    printf '%s' "$_bf"
}

# Atomic publish: write the content produced by running "$@" (a command
# that writes the file body to stdout via a here-callback is awkward in
# bash, so instead callers pass a builder that writes to $1). This helper
# takes a destination path and a builder function; the builder receives a
# temp path, writes the body there, and this helper renames it into place.
# Mirrors the temp+`mv -f` idiom at skeptic-channel.sh:352,366 / 524,535.
#
# Usage: _chan_publish_atomic <dest> <die-fn> <builder-fn> [builder-args...]
#   builder-fn is invoked as: builder-fn <tmp-path> [builder-args...]
#   and must write the full intended file content to <tmp-path>.
_chan_publish_atomic() {
    local dest="$1" _die="$2" builder="$3"; shift 3
    local dir; dir=$(dirname -- "$dest")
    local tmp; tmp=$(mktemp "$dir/.chan.XXXXXX") || { "$_die" "mktemp failed in $dir"; return 1; }
    if ! "$builder" "$tmp" "$@"; then
        rm -f "$tmp" 2>/dev/null || true
        "$_die" "failed to build $dest"; return 1
    fi
    if ! mv -f "$tmp" "$dest"; then
        rm -f "$tmp" 2>/dev/null || true
        "$_die" "publish rename failed: $dest"; return 1
    fi
    return 0
}

# Atomic claim: rename `src` → `dst`, the single-winner lock primitive.
# `mv -f` on one filesystem yields exactly one winner per inode even
# under a racing poll, so the rename IS the claim. Mirrors the ack rename
# at skeptic-channel.sh:473-474 (open→ack) and the watcher claim
# (new→claimed). Returns 0 if THIS call won the rename, non-zero if the
# source was already gone (someone else claimed it first).
_chan_claim_rename() {
    local src="$1" dst="$2"
    [[ -e "$src" ]] || return 1
    mv -f "$src" "$dst" 2>/dev/null
}

# ── Race-safe state transition (the rename state machine's enforced core) ──
# Move an id to <to-state>, re-resolving ONCE if a concurrent writer (the
# watcher's new→claimed claim, or the max-age reaper's claimed→failed) renames
# the file out from under us between the resolve and the state rename. This
# function REPLACES the request-channel header's prose "single-writer + atomic
# rename = no race" claim with enforced behaviour: `.new` and `.claimed` each
# have two potential writers, so a naive resolve-then-mv can (a) spuriously die
# when the watcher claims mid-ack and (b) strand reply text in a reaped file.
#
# CLAIM-FIRST + INTERMEDIATE-NAME ordering (deliberate; NOT the pre-refactor
# "content-mv then state-mv"). The transition is claimed by a single-winner
# atomic rename BEFORE any content is written, so a LOST race is non-corrupting:
# if a reaper renamed `<id>.claimed`→`<id>.failed` first, our claim simply fails
# and the `.failed` file it produced is byte-for-byte the reaper's — we never
# touched it. But a CONTENT transition must NOT claim straight into the terminal
# name: doing so leaves the terminal-named file holding PRE-transition content
# in the window before the content swap, and a crash / NFS EIO there strands a
# terminal file readers false-succeed on. So a content transition claims into a
# NON-AUTHORITATIVE intermediate (`.replying`/`.failing`), publishes the full
# content there, then does ONE atomic finalize rename intermediate→terminal.
# The terminal name therefore only ever appears via a rename of an already
# full-content file — it is NEVER observable partial. `.replying`/`.failing` are
# transitional/pending states (readers treat them like `.claimed`, never
# terminal); a crash leaves one on disk, recovered by the watcher reaper
# (_requests_claim: an aged complete `.replying`→`.replied`, else →`.failed`).
# A pure state rename (ack: no content) needs no intermediate — the claim IS the
# whole transition. A same-state content update (reply --amend) rewrites the
# terminal file with one atomic temp+mv (`.replied` is stable; never torn).
#
# Args:
#   $1 die-fn        channel error voice (called + exits on a build/IO fault)
#   $2 resolve-fn    id → "<path>\t<state>" on stdout, rc1 if absent (e.g.
#                    _state_file_for_id). Re-invoked on every (re)resolve.
#   $3 id
#   $4 to-state      terminal state word (done|replied|failed)
#   $5 intermediate  the pending state word to claim into for a CONTENT
#                    transition (replying|failing); "-" for a pure rename (ack).
#   $6 legal-from    space-list of states this is legal FROM (e.g. "new claimed");
#                    MAY include to-state for a same-state update (amend: "replied").
#   $7 builder-fn    writes the FULL intended file content to a temp; invoked
#                    `builder <tmp> <src-path> [builder-args...]`. "-" = pure rename.
#   $8.. builder-args (streamed after <tmp> <src-path>)
#
# Prints the resolved terminal path on success. Return codes:
#   0  transitioned, OR an idempotent no-op (already AT to-state and to-state is
#      not a legal-from — e.g. double-ack, double-fail)
#   2  id absent
#   6  illegal: current state is stable, not in legal-from, and != to-state
#   7  race lost: bounded retry exhausted (current kept being claimed away)
#   8  build / content-IO fault — NOTE the channel die-fn `exit`s(1), so a caller
#      invoking via $(…) observes rc 1, not 8; 8 surfaces only if a caller passes
#      a non-exiting die-fn.
# Test seams (all fire at most ONCE; mirror CHAN_TS_OVERRIDE; unset in prod):
#   CHAN_TRANSITION_RACE_HOOK      eval'd between resolve and claim
#   CHAN_TRANSITION_MIDGAP_HOOK    eval'd between claim and the content mv
#                                  (the claim↔content gap; a crash here leaves an
#                                  intermediate with PRE-transition content)
#   CHAN_TRANSITION_FINALIZE_HOOK  eval'd between the content mv and the finalize
#                                  (a crash here leaves a COMPLETE intermediate)
_chan_transition() {
    local _die="$1" _resolve="$2" id="$3" to="$4" inter_st="$5" legal="$6" builder="$7"; shift 7
    local attempt sf path state target dir tmp inter
    for attempt in 0 1; do
        sf=$("$_resolve" "$id") || return 2
        path="${sf%$'\t'*}"; state="${sf##*$'\t'}"
        target="${path%.$state.md}.$to.md"
        case " $legal " in
            *" $state "*) ;;                             # legal source → proceed
            *) [[ "$state" == "$to" ]] && { printf '%s' "$path"; return 0; }
               return 6 ;;                               # stable illegal source
        esac
        if [[ -n "${CHAN_TRANSITION_RACE_HOOK:-}" ]]; then
            eval "$CHAN_TRANSITION_RACE_HOOK" || true
            unset CHAN_TRANSITION_RACE_HOOK
        fi
        dir=$(dirname -- "$path")
        if [[ "$target" == "$path" ]]; then
            # Same-state content update (reply --amend): one atomic temp+mv over
            # the stable terminal file — never torn, no intermediate needed.
            if [[ "$builder" != "-" ]]; then
                _chan_publish_atomic "$path" "$_die" "$builder" "$path" "$@" || return 8
            fi
            printf '%s' "$path"; return 0
        fi
        if [[ "$builder" == "-" ]]; then
            # Pure state rename (ack): the claim-rename IS the whole transition;
            # no content window, so it goes straight to the terminal name.
            if _chan_claim_rename "$path" "$target"; then printf '%s' "$target"; return 0; fi
        else
            # Content transition: build full content, claim into the pending
            # intermediate, swap content in, finalize to the terminal name.
            tmp=$(mktemp "$dir/.chan.XXXXXX") || { "$_die" "transition: mktemp failed in $dir"; return 8; }
            if ! "$builder" "$tmp" "$path" "$@"; then
                rm -f "$tmp" 2>/dev/null || true
                # A builder failing because $path vanished mid-build (a racer took
                # it) is a LOST race, not a fault — re-resolve and retry. A failure
                # with $path still present is a genuine build/IO fault.
                [[ -e "$path" ]] || continue
                "$_die" "transition: builder failed for $id"; return 8
            fi
            inter="${path%.$state.md}.$inter_st.md"
            if _chan_claim_rename "$path" "$inter"; then
                if [[ -n "${CHAN_TRANSITION_MIDGAP_HOOK:-}" ]]; then
                    eval "$CHAN_TRANSITION_MIDGAP_HOOK" || true
                    unset CHAN_TRANSITION_MIDGAP_HOOK
                fi
                if ! mv -f "$tmp" "$inter"; then
                    # The intermediate holds PRE-transition content and is a
                    # pending (non-terminal) state — the reaper recovers it. Fail
                    # loudly; no terminal file was ever exposed partial.
                    rm -f "$tmp" 2>/dev/null || true; "$_die" "transition: content swap failed: $inter"; return 8
                fi
                if [[ -n "${CHAN_TRANSITION_FINALIZE_HOOK:-}" ]]; then
                    eval "$CHAN_TRANSITION_FINALIZE_HOOK" || true
                    unset CHAN_TRANSITION_FINALIZE_HOOK
                fi
                # Finalize: ONE atomic rename of the now-complete intermediate to
                # the terminal name. The terminal name's first appearance carries
                # full content — never partial.
                if ! _chan_claim_rename "$inter" "$target"; then
                    "$_die" "transition: finalize rename failed: $inter → $target"; return 8
                fi
                printf '%s' "$target"; return 0
            fi
            rm -f "$tmp" 2>/dev/null || true
        fi
        # Lost the claim: $path was renamed away by a racer. Re-resolve + retry once.
    done
    return 7
}

# Read a single scalar frontmatter field from a markdown file's leading
# YAML block (between the first two `---` fences). Returns the value of
# the FIRST top-level `key: value` match (leading whitespace trimmed),
# empty if absent. Deliberately tiny — no nested-YAML support; the
# channel schemas keep correlation fields (request/origin/kind/state/
# reply) at the top level. $1=file $2=key.
#
# Now a thin alias over the shared `_fm_get` (#405 P2): the parser body moved
# to _fm_lib.sh so this channel field read and the client's reply-state read
# cannot drift. The signature (and the `return 1` on an unreadable file, which
# `_fm_get` alone does not raise) is preserved byte-for-byte — this is
# watcher-sourced, so the name/arity is load-bearing.
_chan_frontmatter_field() {
    local file="$1" key="$2"
    [[ -r "$file" ]] || return 1
    _fm_get "$file" "$key"
}
