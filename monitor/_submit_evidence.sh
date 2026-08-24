#!/usr/bin/env bash
# _submit_evidence.sh — "was this paste actually consumed?", answered
# from the target's OWN transcript, for any caller that needs to know.
#
# THE ASYMMETRY THIS EXISTS TO CLOSE (your-org/nexus-code#607).
#
# `paste-followup.sh` has always judged a paste against TWO independent
# surfaces, either of which suffices:
#
#   (a) the target session's transcript gains a TUI-submission record —
#       Claude Code's own ledger, authoritative;
#   (b) the worker's UserPromptSubmit hook stamp advances past the paste
#       epoch for the same session-id.
#
# The watcher's `paste-unconfirmed` detector had only (b). And (b) is
# precisely the surface that can silently not fire: a message submitted
# behind an in-flight turn is QUEUED, and a queued message produces no
# submit event until the running turn drains. Turns here routinely run
# minutes; the confirm grace is 180s. So the detector read "no stamp
# within the window" as proof of non-delivery, and the emit advised a
# RE-PASTE — an action that is destructive by duplication.
#
# It was wrong 10/10 on 2026-07-29. The cleanest instance: a four-part
# verification brief, labelled (a)–(d), whose target's report contains
# four sections titled exactly `## (a) …` through `## (d) …`, appended
# after the paste timestamp, followed by a verdict. Re-pasting on that
# advice would have re-run a completed adversarial verification pass.
#
# So this library gives the watcher surface (a) too, and — the part that
# matters more than either surface — makes the answer THREE-VALUED. A
# bounded scan that finds nothing has not established absence; it has
# run out of budget. Saying so is the difference between a signal that
# can be trusted and one that cannot.
#
# The genuine-loss path must keep working: pastes really do get lost
# here (one was, in the same session, and re-issuing was correct). This
# library therefore never suppresses a verdict — it only distinguishes
# `no` from `unknown`, leaving the caller to decide what each warrants.
#
# Pure functions, no top-level side effects.
[[ -n "${_SUBMIT_EVIDENCE_SH_LOADED:-}" ]] && return 0
_SUBMIT_EVIDENCE_SH_LOADED=1

# The TUI-submission discriminator. Every user-role line — including
# every tool_result — is `"type":"user"`, so "a new user message" is far
# too coarse: a busy agent emits them continuously. Worse, Claude Code
# injects `<task-notification>` messages as string-content user lines,
# which a content-shape test would happily mistake for a real prompt.
# `promptSource` is the discriminator:
#     typed / queued / suggestion_accepted → a TUI submission ✓
#     system                               → task-notification ✗
#     sdk                                  → subagent / SDK turn  ✗
#     (absent)                             → a tool_result, or a
#                                            pre-`promptSource` build
# Note `queued` is an ACCEPTED value: a message that submitted after
# waiting behind a turn is submitted, full stop. That is the whole
# #607 case.
#
# Kept byte-identical to paste-followup.sh's own filter — the sender and
# the watcher must not be able to disagree about what a submission is.
_SE_JQ_SELECT='
select(.type == "user")
| select((.isMeta // false) | not)
| select((.isSidechain // false) | not)
| select(
    if has("promptSource") then
        (.promptSource != "system" and .promptSource != "sdk")
    else
        ((.message.content | type) == "string")
    end
  )'
# Two projections over the SAME selector, so the "counted a submission"
# and "dated a submission" questions can never drift apart.
_SE_JQ_SUBMISSION="$_SE_JQ_SELECT | 1"
_SE_JQ_SUBMISSION_TS="$_SE_JQ_SELECT | .timestamp // empty"

# ---- the SECOND spelling of "the bytes arrived" (your-org/nexus-code#665) --
#
# The selector above answers "did a TUI submission happen". MEASURED on
# 2026-08-05, that is not the only shape delivery takes, and the shape it
# misses is precisely the one `#607` is about.
#
# A paste that lands while a turn is IN FLIGHT is queued, and Claude Code
# records the queueing — not a `type:"user"` line. Two self-pastes into a
# live worker (this window, 3,530 B and 196 B) each produced:
#
#   {"type":"queue-operation","operation":"enqueue","content":"<the bytes>",...}
#   {"type":"attachment","attachment":{"type":"queued_command",...},...}
#   {"type":"queue-operation","operation":"remove","content":"<the bytes>",...}
#
# and NO `type:"user"` record whatsoever — before, during, or after the
# message was consumed into the running turn. So `se_submission_since`
# answers `no` for a paste that demonstrably arrived and was acted on.
# That is a FALSE POSITIVE manufactured by looking for one spelling of a
# property that has two.
#
# `enqueue` is the arrival event and therefore the right one to match:
# the detector exists to catch a paste whose Enter was swallowed, i.e. a
# failure of DELIVERY. `remove` is consumption, and it also fires when a
# queued message is CANCELLED — matching it would conflate "the operator
# deliberately dropped this" with "the worker read it". Coverage boundary:
# a paste that was delivered and then cancelled reads as delivered here.
_SE_JQ_ENQUEUE_SELECT='
select(.type == "queue-operation")
| select(.operation == "enqueue")
| select((.content | type) == "string")'

# Timestamps of BOTH delivery spellings, for the "did anything arrive"
# question. Union, not replacement — a direct (unqueued) paste still
# produces only the `type:"user"` record.
_SE_JQ_DELIVERY_TS="(( $_SE_JQ_SELECT | .timestamp // empty ), ( $_SE_JQ_ENQUEUE_SELECT | .timestamp // empty ))"

# ---- content-identity projection (your-org/nexus-code#665, item 1) ---------
#
# `<iso-timestamp><TAB><base64 of the canonical content>` for every record
# of either delivery spelling. base64 because the content is arbitrary
# multi-line text and this has to survive a line-oriented read loop.
#
# THE CANONICAL FORM, and why there is one at all. The paste path is
# byte-transparent with EXACTLY ONE exception, established by controlled
# self-paste rather than assumed: a literal TAB arrives as FOUR SPACES.
# Measured at seven tab positions (columns 1, 3, 7, 8, 15, leading, and a
# consecutive pair) across two independent replicates; both tabstop
# hypotheses are REFUTED (`expand -t8` and `expand -t4` each diverge at
# line 2 of the fixture),
# and a flat `s/\t/    /g` reproduces the recorded bytes exactly. Multibyte
# UTF-8, trailing spaces, blank lines, backticks, `${braces}` and a 3.5 KB
# body that triggers Claude Code's collapsed-paste placeholder all arrive
# unchanged.
#
# So the transform is applied on BOTH sides — here in jq (which cannot
# mangle a trailing newline the way a shell round-trip would) and in the
# sender. It is the identity function composed with the one known channel
# map, NOT a normalisation that blurs content: every non-whitespace byte,
# every line break and every trailing space still discriminates. The only
# pair it cannot tell apart is a message that differs from another solely
# by tab-versus-four-spaces, which is not a distinction any follow-up
# instruction rests on.
_SE_JQ_DELIVERY_B64="((
  $_SE_JQ_SELECT
  | [(.timestamp // \"\"), ((.message.content | tostring | gsub(\"\\t\"; \"    \")) | @base64)]
), (
  $_SE_JQ_ENQUEUE_SELECT
  | [(.timestamp // \"\"), ((.content | gsub(\"\\t\"; \"    \")) | @base64)]
)) | @tsv"

# How many trailing bytes of a transcript to scan. A live worker
# transcript reaches hundreds of MB (792 MB observed on this operator),
# so scanning from byte 0 is not an option. Anything appended AFTER the
# paste is by construction at the END of the file, so a tail is the
# right shape — but it is a BOUND, and a bound that is exceeded is the
# reason `unknown` exists.
: "${SE_TAIL_BYTES:=8388608}"

# Claude Code homes to search, most specific first. NEXUS_CC_HOME, when
# set, is the ONLY root consulted (hermetic-test seam, shared with
# paste-followup.sh).
se_cc_homes() {
    if [[ -n "${NEXUS_CC_HOME:-}" ]]; then
        printf '%s\n' "$NEXUS_CC_HOME"
        return 0
    fi
    [[ -n "${CLAUDE_CONFIG_DIR:-}" ]] && printf '%s\n' "$CLAUDE_CONFIG_DIR"
    printf '%s\n' "$HOME/.claude"
}

# `<cc-home>/projects/*/<session-id>.jsonl`.
#
# Two traps, both paid for in blood (see paste-followup.sh's header):
# do NOT pick "the newest jsonl in the project dir" — a worker and its
# skeptic share a clone, so one project dir holds several sessions, and
# the session-id is the key. And do NOT hand-derive the project-dir
# slug: the transform maps `/` AND `_` to `-`, which is easy to get
# wrong, while a bare `find` over ~/.claude descends into `file-history/`
# and takes minutes. Session-ids are UUIDs, so a bounded glob finds the
# file without deriving the slug at all.
se_transcript_for_session() {
    local sid="$1" home p
    [[ -n "$sid" ]] || return 1
    while IFS= read -r home; do
        [[ -n "$home" ]] || continue
        for p in "$home"/projects/*/"$sid.jsonl"; do
            [[ -f "$p" ]] || continue   # no nullglob: unmatched glob is the literal
            printf '%s' "$p"
            return 0
        done
    done < <(se_cc_homes)
    return 1
}

# Session-id of the agent in `window`, from the heartbeat its own hooks
# write, falling back to the UserPromptSubmit stamp's session column.
# `state_dir` is passed explicitly so this file needs no globals.
se_session_id_for_window() {
    local window="$1" state_dir="$2" sid="" hb="$2/heartbeat/$1.json"
    if [[ -f "$hb" ]] && command -v jq >/dev/null 2>&1; then
        sid=$(jq -r '.session_id // empty' "$hb" 2>/dev/null) || sid=""
    fi
    if [[ -z "$sid" && -f "$state_dir/user-prompt/$window" ]]; then
        sid=$(head -1 "$state_dir/user-prompt/$window" 2>/dev/null | cut -f2) || sid=""
    fi
    [[ -n "$sid" ]] || return 1
    printf '%s' "$sid"
}

# se_submission_since <window> <state-dir> <epoch>
#
# TEMPORAL PROXY — read `se_submission_with_digest` below before relying
# on this to decide whether a particular paste arrived. It answers "did
# anything arrive after this moment", which is a different question, and
# the gap between them is your-org/nexus-code#665 item 1. It survives as
# the fallback for pastes with no recorded content marker (every paste
# predating that change, and any whose sender died before stamping one).
#
# Scans BOTH delivery spellings since #665 — a `type:"user"` TUI
# submission and a `queue-operation`/`enqueue` — because a paste that
# lands mid-turn produces only the latter, and answering `no` for it was
# a false positive this function generated on its own.
#
# Prints exactly one of:
#   yes      a delivery is recorded at/after <epoch> in the window's own
#            transcript. Something arrived; not necessarily this paste.
#   no       the transcript was read in full over the scanned range and
#            holds no such submission.
#   unknown  we could not establish either. Causes, all real:
#              * jq absent (the scan cannot run at all);
#              * no heartbeat / session-id / transcript to read;
#              * the transcript is LARGER than the scan bound, so the
#                region we read is not the whole region that matters.
#
# `unknown` is not a failure mode to be minimised away — it is the
# honest value, and the one whose absence caused #607. A caller must
# not treat it as `no`.
#
# The timestamp comparison is on the record's own ISO `timestamp`
# field, converted with `date -d`. A record with no parseable timestamp
# is skipped rather than assumed recent: assuming would manufacture a
# `yes`, and a false `yes` silences a genuine lost paste — the failure
# direction this detector exists to catch.
se_submission_since() {
    local window="$1" state_dir="$2" epoch="$3"
    if ! command -v jq >/dev/null 2>&1; then printf 'unknown'; return 0; fi
    [[ "$epoch" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
    local sid transcript
    sid=$(se_session_id_for_window "$window" "$state_dir") || { printf 'unknown'; return 0; }
    transcript=$(se_transcript_for_session "$sid") || { printf 'unknown'; return 0; }
    local size
    size=$(stat -c %s "$transcript" 2>/dev/null) || size=0
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    # `^\{.*\}$` guards a tail that may land mid-line: jq aborts a whole
    # stream on one malformed value. A leading fragment is some line's
    # TAIL (never starts with `{`); a trailing fragment is some line's
    # HEAD (never ends with `}`); JSONL forbids raw newlines inside
    # strings, so no complete record is ever rejected by this filter.
    local found ts se_e
    found=$(tail -c "$SE_TAIL_BYTES" "$transcript" 2>/dev/null \
        | grep -E '^\{.*\}$' 2>/dev/null \
        | jq -r "$_SE_JQ_DELIVERY_TS" 2>/dev/null \
        | while IFS= read -r ts; do
              [[ -n "$ts" ]] || continue
              se_e=$(date -d "$ts" +%s 2>/dev/null) || continue
              [[ "$se_e" =~ ^[0-9]+$ ]] || continue
              if (( se_e >= epoch )); then printf 'yes'; break; fi
          done)
    if [[ "$found" == "yes" ]]; then printf 'yes'; return 0; fi

    # Nothing found. Was the scan complete? If the file exceeds the
    # bound we read only its tail, and "not in the part I read" is not
    # "not in the file".
    if (( size > SE_TAIL_BYTES )); then printf 'unknown'; return 0; fi
    printf 'no'
}

# ===========================================================================
# CONTENT IDENTITY — your-org/nexus-code#665 item 1
#
# Everything above answers "did a submission happen AT OR AFTER this
# epoch". That is a TEMPORAL PROXY for the question actually being asked,
# which is "did THIS paste arrive". The two come apart in exactly the
# case that matters: a paste that was genuinely lost, in a window where
# the worker submitted anything else afterwards, reads `yes` and is
# silenced. A lost paste is unrecoverable silence; that is the strictly
# worse failure direction, and it is this issue's own defect class living
# inside its own fix — a check that asserts a proxy rather than the
# property.
#
# The property is byte identity. The sender knows the bytes it pasted, so
# it records their digest beside the paste; the watcher matches THAT in
# the target's transcript. No timestamp ordering decides consumption.
#
# THE FAILURE DIRECTIONS ARE NOT SYMMETRIC, and the asymmetry is designed
# in rather than hoped for:
#   * a digest that MATCHES is proof of arrival — sha256 over the exact
#     canonical bytes cannot be satisfied by unrelated content;
#   * a digest that does NOT match is never rendered as "delivered". It
#     is the unresolved emit, which is what the caller already does with
#     every non-`yes` answer.
# So the marker can only ever remove a false positive or add one. It can
# never manufacture the silence.
# ===========================================================================

# Upper bound on candidate records examined in one scan. Delivery records
# are rare relative to tool_results, so this is a runaway guard, not a
# working limit — and exceeding it yields `unknown`, never `no`, because
# a scan that stopped early has not established absence.
: "${SE_MAX_CANDIDATES:=2000}"

# sha256 over stdin, hex, no filename. Prints nothing and fails when no
# hasher exists — which propagates as `unknown`, not as a mismatch.
#
# NO `| awk '{print $1; exit}'`, and the reason is your-org/nexus-code#622
# rather than taste: an early-exiting reader closes the pipe, the hasher
# takes EPIPE, and under `pipefail` the pipeline's status goes NON-ZERO.
# Every caller here consumes that status — `se_paste_digest` is a
# `… || PASTE_DIGEST=""`, and the scan's is a `… || continue` — so the
# race would silently produce no digest at all, or silently skip a
# candidate that matched. It is a race and not a certainty (the hash is
# one short line, usually written before awk exits), which is exactly
# the shape that survives testing and fires on a loaded box.
#
# Caught by monitor/watcher/early-exit-readers.sh, which flagged the two
# new `awk-exit` sites. Fixed at the source rather than recorded in the
# manifest: a command substitution reads stdin to EOF, so no pipe is ever
# closed early and the population returns to its recorded boundary.
se_sha256_stdin() {
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum) || return 1
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256) || return 1
    else
        return 1
    fi
    printf '%s' "${out%% *}"
}

se_have_hasher() {
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1
}

# The canonical form of a message about to be pasted — the SENDER's half
# of the transform documented at _SE_JQ_DELIVERY_B64. Pure bash parameter
# expansion on purpose: a `sed`/`awk` round-trip would append a trailing
# newline the pasted bytes never had, and the digest would then match
# nothing at all — a surface that silently never fires is worse than no
# surface, because its silence reads as "delivered".
se_paste_canonical() {
    local s="$1"
    printf '%s' "${s//$'\t'/    }"
}

# Digest of a message as it will appear in the target's transcript.
# Empty output (rc 1) when no hasher is available; the caller records no
# digest at all in that case, which degrades the watcher to its
# pre-#665 behaviour rather than to a wrong answer.
se_paste_digest() {
    se_have_hasher || return 1
    se_paste_canonical "$1" | se_sha256_stdin
}

# se_submission_with_digest <window> <state-dir> <epoch> <digest>
#
# Prints exactly one of:
#   yes      a delivery record carrying EXACTLY these bytes exists at or
#            after <epoch> in the window's own transcript.
#   no       the transcript was read in full over the scanned range and
#            no record carries them.
#   unknown  the question could not be put. Causes, all real: no jq, no
#            hasher, no base64, no session-id/transcript, a malformed
#            digest, a transcript larger than the scan bound, or a
#            candidate count past SE_MAX_CANDIDATES.
#
# The epoch gate stays — it is not what decides consumption, but it stops
# a record that PREDATES this paste from answering for it. Coverage
# boundary, stated rather than discovered later: two pastes of identical
# content into one window are indistinguishable by content digest, so the
# earlier one reads as delivered once the later one arrives. The bytes did
# reach the worker, which is what the emit is about.
se_submission_with_digest() {
    local window="$1" state_dir="$2" epoch="$3" want="$4"
    command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    command -v base64 >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    se_have_hasher || { printf 'unknown'; return 0; }
    [[ "$epoch" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { printf 'unknown'; return 0; }

    local sid transcript
    sid=$(se_session_id_for_window "$window" "$state_dir") || { printf 'unknown'; return 0; }
    transcript=$(se_transcript_for_session "$sid") || { printf 'unknown'; return 0; }
    local size
    size=$(stat -c %s "$transcript" 2>/dev/null) || size=0
    [[ "$size" =~ ^[0-9]+$ ]] || size=0

    # The epoch gate, WITHOUT a fork per record. Transcript timestamps are
    # ISO-8601 UTC (`2026-08-06T06:02:46.344Z`), so stripping the
    # separators from the first 19 characters yields a 14-digit number
    # that orders identically to the instant — comparable with `(( ))`,
    # which costs nothing.
    #
    # `date -d` per candidate would cost a FORK PER RECORD in the
    # watcher's cycle, which is your-org/nexus-code#655's hazard living
    # inside the code that investigates it: on a fork-starved box the
    # surface that decides whether a paste was lost would itself start
    # failing to fork. It stays as the FALLBACK for any timestamp that
    # does not match the expected shape, so an unexpected format degrades
    # to correct-but-slow rather than to a wrong comparison.
    #
    # SCOPE, stated because the first version of this comment overstated
    # it: this removes the `date` fork only. `base64` and `sha256sum` still
    # fork once each per candidate past the epoch gate, so the hazard is
    # REDUCED, not removed — measured at 404 forks against 705 over 201
    # candidates, i.e. ~43%. Those remaining forks are exactly the ones
    # whose per-call failure the `degraded` flag below has to catch.
    #
    # Numeric, not lexicographic: `[[ a > b ]]` uses locale COLLATION,
    # and glibc collation in a UTF-8 locale can ignore punctuation — a
    # string compare here would be correct on this host and quietly wrong
    # on another. `10#` forces base 10, or `08` would be an octal error.
    local epoch_num=""
    epoch_num=$(date -u -d "@$epoch" +%Y%m%d%H%M%S 2>/dev/null) || epoch_num=""
    [[ "$epoch_num" =~ ^[0-9]{14}$ ]] || epoch_num=""

    # Process substitution, NOT a pipe into `while`: the loop must run in
    # THIS shell so a match can `return` from the function instead of
    # being smuggled out through a subshell's stdout.
    # `degraded` separates "I read this candidate and it did not match" from
    # "I could not read this candidate at all". The up-front `command -v`
    # guards catch a tool that is ABSENT; they say nothing about one that
    # FAILS PER INVOCATION, which is exactly what a fork returning EAGAIN
    # looks like. Without this the scan answers `no` — and the emit then
    # renders "the pasted bytes appear in no delivery record … this is the
    # shape a genuinely lost paste takes" — in precisely the fork-starved
    # regime your-org/nexus-code#655 is about, having never hashed anything.
    # The DIRECTION was already safe (a false positive, and the emit still
    # refuses to self-execute); the WORDING was not, and `unknown` is the
    # value that already exists for it.
    local ts b64 se_e got ts_num n=0 overrun=0 degraded=0
    while IFS=$'\t' read -r ts b64; do
        n=$(( n + 1 ))
        if (( n > SE_MAX_CANDIDATES )); then overrun=1; break; fi
        [[ -n "$ts" && -n "$b64" ]] || continue
        # SE_FORCE_DATE_FALLBACK is a TEST SEAM (never set in production):
        # it defeats the fast path so the suite can measure that the
        # fallback really does fork per record, which is what makes the
        # fork-count assertion non-vacuous.
        if [[ -z "${SE_FORCE_DATE_FALLBACK:-}" \
              && -n "$epoch_num" && "$ts" == *Z && "${#ts}" -ge 20 ]]; then
            ts_num="${ts:0:19}"
            ts_num="${ts_num//[-:T]/}"
            [[ "$ts_num" =~ ^[0-9]{14}$ ]] || ts_num=""
        else
            ts_num=""
        fi
        if [[ -n "$ts_num" ]]; then
            (( 10#$ts_num >= 10#$epoch_num )) || continue
        else
            se_e=$(date -d "$ts" +%s 2>/dev/null) || { degraded=1; continue; }
            [[ "$se_e" =~ ^[0-9]+$ ]] || { degraded=1; continue; }
            (( se_e >= epoch )) || continue
        fi
        # `set -o pipefail` INSIDE the substitution, and it is LOAD-BEARING —
        # measured, not argued. A failed `base64` writes nothing, `sha256sum`
        # on empty input SUCCEEDS, and without pipefail the pipeline exits 0
        # carrying the digest of the EMPTY STRING: a valid-looking,
        # always-wrong hash that no `||` can catch because nothing failed.
        #
        # Remove it and hand the scan that empty digest as the value to look
        # for, and it answers `yes` — "this paste was delivered" — for a
        # paste whose bytes were never decoded. That is the FALSE NEGATIVE
        # direction, the unrecoverable one this whole surface exists to
        # avoid. B6c's third assertion pins exactly that.
        #
        # An earlier revision of this comment said the necessity was argued
        # rather than demonstrated, because the mutant left the suite green.
        # That was true of the SUITE and not of the CODE: the assertion was
        # vacuous — a leaked failing-hasher stub from the previous case sent
        # it back through the hasher guard, so it never reached this line.
        # With the fixture reset the mutant is caught. The lesson is the
        # PR's own: "no mutant reddens" is a claim about the test, and it
        # must be checked before it is believed about the code.
        got=$(set -o pipefail
              printf '%s' "$b64" | base64 -d 2>/dev/null | se_sha256_stdin) \
            || { degraded=1; continue; }
        [[ "$got" =~ ^[0-9a-f]{64}$ ]] || { degraded=1; continue; }
        if [[ "$got" == "$want" ]]; then printf 'yes'; return 0; fi
    done < <(tail -c "$SE_TAIL_BYTES" "$transcript" 2>/dev/null \
        | grep -E '^\{.*\}$' 2>/dev/null \
        | jq -r "$_SE_JQ_DELIVERY_B64" 2>/dev/null)

    (( overrun )) && { printf 'unknown'; return 0; }
    # A candidate we could not read is not a candidate that did not match.
    (( degraded )) && { printf 'unknown'; return 0; }
    if (( size > SE_TAIL_BYTES )); then printf 'unknown'; return 0; fi
    printf 'no'
}
