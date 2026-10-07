#!/usr/bin/env bash
# _paste-deliver.sh — THE confirmed-delivery primitive. Every tmux paste this
# repo makes into a Claude Code pane goes through here, and the ONE executable
# `tmux paste-buffer` under monitor/ lives in this file
# (monitor/watcher/paste-buffer-sites.manifest).
#
# WHY ONE PRIMITIVE (your-org/nexus-code#1591). There were four paste sites and
# three ideas of what "delivered" means:
#
#   monitor/paste-followup.sh          polled the target's TRANSCRIPT, retried
#                                      Enter once                        (#507)
#   monitor/watcher/_respawn.sh        polled pane-state for `busy`, re-sent
#                                      Enter while `user-typing`        (#1470)
#   monitor/watcher/main.sh (emit)     grepped the PANE for the emit trailer
#   monitor/watcher/_unstick.sh        checked nothing
#
# Claude Code 2.1.277 added a review step: a prompt carrying an invisible
# character is CLEANED and HELD in the input box on the first Enter, and sent
# on the second. 2.1.273 sent the identical bytes on the first Enter. Measured
# on the real 2.1.278 binary at 17f1f926, the emit paste failed in TWO shapes,
# decided by the body's size:
#
#   SHORT body (<= 2 newlines and <= 800 chars — it renders as text in the box)
#     rc 0, no request, no transcript record. The old check grepped the PANE
#     for the emit trailer, and a held body renders its trailer in the input
#     box. A MANUFACTURED SUCCESS: every artefact says delivered, and the only
#     evidence is an absence.
#   EMIT-SHAPED body (every real emit: it collapses to `[Pasted text #N …]`)
#     the trailer is NOT on the pane, so the check returned 4 — and
#     paste_with_retry answered rc 4 by RE-PASTING. The box then held
#     `[Pasted text #1 +15 lines][Pasted text #2 +15 lines]`: two cleaned
#     copies, still unsent, waiting for the next emit's Enter to submit them
#     merged with it. Loud, and destructive by duplication.
#
# Both come from the same two mistakes: taking a RENDERING for a SUBMIT, and
# answering "not delivered" with another paste instead of another Enter.
#
# ---- THE POLICY, and the measurements it rests on ------------------------
#
# TWO layers, deliberately unequal:
#
#   1. CONFIRM, then a second Enter on positive evidence — THE MECHANISM.
#      Whatever rule Claude Code applies, a held prompt needs exactly one more
#      Enter (measured: every held arm sent on the second). So after the Enter
#      we look for evidence the prompt was ACCEPTED (pd_evidence_seen), and
#      when the pane instead POSITIVELY reads `state=user-typing input=typed`
#      — the text is in the box — we press Enter again, a bounded number of
#      times. This is correct under either value of the server-side feature
#      flag that gates the review step (`tengu_tranquil_cloud`, client default
#      TRUE in 2.1.278, so it is armed without any first-party auth), on
#      2.1.273 where the step does not exist, and for any future change to the
#      character set, because it keys on the OUTCOME and not on the rule.
#
#   2. NORMALISE before the paste — A FAST PATH, never the guarantee.
#      pd_normalise_file removes the characters the review step would remove,
#      so the common case never enters the held state at all and the sender's
#      content digest (monitor/_submit_evidence.sh) describes the bytes the
#      transcript will actually record.
#
# Why not normalise alone: the rule is CONTEXT-SENSITIVE and it is upstream's
# to change. Read out of the 2.1.278 binary, the candidate set is one
# predicate, and sixteen of its members are KEPT in context — a ZWJ inside an
# emoji sequence, VS16 after an emoji or a keycap base, a ZWSP between Thai /
# Khmer / Lao / Myanmar letters, LRM/RLM on a line carrying right-to-left
# letters, tag characters after U+1F3F4. Measured: `ก<ZWSP>ข` SENT on the first
# Enter while `a<ZWSP>b` was HELD. A blanket strip would delete characters
# Claude Code itself keeps; an exact re-implementation would rot on the next
# release. So the normaliser is CONSERVATIVE and its error direction is stated:
#
#   RELATIVE TO CLAUDE CODE 2.1.278 IT UNDER-STRIPS AND NEVER OVER-STRIPS.
#
#   TIER U — code points 2.1.278 removes unconditionally: removed everywhere.
#   TIER C — code points 2.1.278 keeps in some context: removed ONLY on a line
#            whose visible content is pure ASCII. Every keep-condition in the
#            2.1.278 source requires a non-ASCII neighbour or a non-ASCII
#            letter on the line, so on such a line none can hold.
#   U+2028 / U+2029 become LF, as 2.1.278 maps them.
#
# What is left over (a ZWSP on a line that also carries an emoji, say) takes
# layer 1: held, seen, second Enter. NOT in either tier, on purpose: C0/C1
# controls and DEL. They are in upstream's predicate, but CRLF and ESC were
# measured SENT on the first Enter — the terminal input layer consumes them
# before the cleaner runs — so stripping them would change today's behaviour
# for no measured benefit. C1 is unmeasured; layer 1 covers it.
#
# SAFE ON THE RUNNING PIN. On 2.1.273 layer 1 finds its evidence after the
# first Enter and never presses a second; layer 2 removes characters that
# carry no instruction content. Both measured.
#
# The tier tables are UTF-8 BYTE patterns under LC_ALL=C, so the pass is total
# over arbitrary bytes and needs nothing the watcher does not already have
# (GNU sed). monitor/watcher/test-paste-deliver.sh checks them against a table
# generated from the code points, independently of these byte ranges.
#
# ---- WHAT COUNTS AS EVIDENCE ---------------------------------------------
#
# The same two surfaces paste-followup.sh has trusted since #507, plus the
# second spelling of arrival #665 measured:
#
#   a. the target session's transcript gains, AFTER a byte offset taken before
#      the paste, a TUI-submission record (`promptSource` typed / queued / …)
#      or a `queue-operation enqueue` record — what a paste into a BUSY pane
#      writes instead. The selectors are monitor/_submit_evidence.sh's, so the
#      sender and the watcher cannot disagree about what a submission is.
#   b. a caller-supplied hook-stamp predicate (PD_EXTRA_EVIDENCE_FN).
#
# NOT evidence: a tmux rc; the pane's scrollback; the emit trailer in the pane.
#
# THE RECORD MUST BE OURS (skeptic pastesk F1 on #1595). The first cut accepted
# ANY matching record after the offset and called the boundary "a second
# paster". It is far wider: a target's OWN transcript writes matching records
# with nobody else pasting — an EARLIER queued prompt submitted at turn end
# (`promptSource:"queued"`), compaction summaries, local-command records; 316,
# 48 and 88 of them in one live orchestrator transcript. With ours HELD and one
# such record landing on the cleaning Enter, pastesk measured rc 0 `submitted`,
# ONE Enter, ours never recorded — #1591's manufactured success by another road.
#
# So a record counts only if its content CONTAINS A NEEDLE from this paste:
#   * the caller's, when it has a unique one — PD_EVIDENCE_NEEDLE; the emit
#     path passes its `nexus-emit-sig <iso> <nonce>` trailer;
#   * otherwise the longest run of printable ASCII in the (normalised) payload.
#     Claude Code's cleaning removes invisibles and never touches ASCII, and the
#     one known channel map (TAB -> four spaces, #665) cannot fall inside a run
#     that excludes TAB — so the needle survives whatever the rule does.
# With NO needle (a payload with no 12-char ASCII run), the selector NARROWS
# instead: `promptSource` must be present and not `queued`, and compaction
# summaries are out. A paste into a busy pane writes an `enqueue` first, which
# is accepted either way. COVERAGE BOUNDARY that remains: two pastes of the
# SAME text into one pane are indistinguishable, as they are to #665's digest.
#
# ---- A RETRY ENTER NEEDS AN EQUALITY, NOT A SHAPE ------------------------
#
# An Enter aimed at an overlay SELECTS ITS HIGHLIGHTED DEFAULT (#1200: it
# committed 325 MB), so pd_deliver reads the pane BEFORE pasting and refuses a
# positive `blocked`. And an Enter aimed at an input box SUBMITS WHATEVER IS IN
# IT — so a retry Enter is pressed only when BOTH hold:
#
#   1. pane-state positively reads `state=user-typing input=typed`, and
#   2. THE BOX'S CONTENT IS OUR PAYLOAD (pd_box_is_ours): its first row is a
#      prefix of our payload's first line, or — for a paste Claude Code
#      collapsed — it is nothing but `[Pasted text #N +K lines]` placeholders
#      whose K is our payload's line count.
#
# (1) alone is a SHAPE: "the box looks held". Any typed draft has that shape, on
# every Claude Code version, and the watcher pastes into the very pane the
# operator types into. Skeptic pastesk measured it (A4 on #1595): with a draft
# appearing 0.3 s after our submit, the retry Enter SUBMITTED the operator's
# half-typed draft — the one outcome of this primitive that cannot be undone; a
# lost emit is archived and re-composed. Two attempts to close that by timing
# (one-strike, then two-consecutive "box seen without typed text") each left a
# window, and the second was shipped with a claim about it that was false. So
# the decision is now an EQUALITY, the same lesson as the tmux shim: act only on
# what is positively ours. Everything else — a draft, a ghost, `input=?`, an
# unreadable pane, a placeholder whose count is not ours — gets NO Enter and is
# reported `undecidable-box`. THERE IS NO BLIND RETRY ANY MORE, not even the one
# paste-followup.sh had kept since #507 for an unreadable pane.
#
# The two-consecutive non-held rule (F6) stays, for the other side: it decides
# when a window may END early, and one transient frame is still not a fact.
#
# WHAT THE EQUALITY DOES NOT COVER, stated (skeptic pastesk rounds 3-4):
#   * ACCEPTED RESIDUAL: an operator draft that is ITSELF a prefix, 8 characters
#     or longer, of our payload's first line satisfies it and is submitted. So
#     does an operator PASTE with exactly our line-break count — but only when
#     our own payload is one the binary would collapse (over 800 chars or more
#     than 2 breaks): a short payload of ours never equals a placeholder.
#   * STRANDED, never wrongly submitted: a payload whose first line is EMPTY, or
#     so CJK-heavy that its ASCII projection is under 8 characters, can never
#     match the text form; if Claude Code holds it, it stays held and is reported.
#   * STRANDED, never wrongly submitted, IN A PANE UNDER 12 ROWS (skeptic
#     pastesk F13): the REPL's break threshold is `max(0, min(rows - 10, 2))`,
#     not 2, so a short pane collapses a payload of ours with only 1 or 2 line
#     breaks, and _pd_would_collapse (which assumes 2) then refuses the
#     placeholder. The pane height is deliberately NOT read: board windows are
#     far taller, and a zero-break short payload collapses at NO height, so the
#     F12 guarantee does not depend on it.
#   * The placeholder spelling is Claude Code's. A reworded one fails SAFE: no
#     match, no Enter, a loud `undecidable-box` — and
#     test-realmodel-paste-held.sh's held, long-line and tab-line arms go red before the
#     pin moves.
#
# ---- THE ONE PATH THAT DOES NOT COME THROUGH HERE, DELIBERATELY ------------
#
# monitor/watcher/_fs_guard.sh types its read-only-filesystem alert with
# `send-keys -l` and one Enter. It cannot use this file: the payload is staged
# in a FILE, and that alert fires exactly when no file can be written. It is the
# last resort behind every out-of-band channel, its text is fixed and
# nexus-authored, and test-paste-deliver.sh asserts the file carries no
# invisible-class byte — so that text can never be held. Anything that relays
# text somebody ELSE wrote belongs here.
#
# Pure functions plus the PD_* result variables; no top-level side effects.
[[ -n "${_PASTE_DELIVER_SH_LOADED:-}" ]] && return 0
_PASTE_DELIVER_SH_LOADED=1

_pd_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Dependencies, each optional at LOAD and checked at USE (the _pane-live.sh
# lesson: several fixtures build partial trees, and a missing sibling must stop
# PASTES, not module loading).
if [[ -r "$_pd_dir/_submit_evidence.sh" ]]; then
    # shellcheck source=monitor/_submit_evidence.sh
    . "$_pd_dir/_submit_evidence.sh"
fi
# Dead-pane paste guard (#745) — this file holds the ONE paste-buffer, so it is
# the one file test-paste-dead-pane-guard.sh's call-site manifest holds to the
# full contract: source the guard explicitly, call it in command position
# BEFORE the paste, and carry a FAIL-CLOSED fallback.
# shellcheck source=monitor/_pane-live.sh
declare -F _tmux_pane_is_dead >/dev/null 2>&1 || {
    [[ -r "$_pd_dir/_pane-live.sh" ]] && \
    . "$_pd_dir/_pane-live.sh"
}
if ! declare -F _tmux_pane_is_dead >/dev/null 2>&1; then
    # FAIL-CLOSED FALLBACK (#745). Without the real predicate a live pane cannot
    # be told from a corpse, and a paste into a corpse kills the tmux SERVER — so
    # every paste refuses, loudly, at the moment it is attempted. An rc 127 from
    # a missing function would read as "not dead", which is the hazard restored
    # in exactly the partial trees least likely to be looked at. Quiet at load,
    # loud at use. It leaves NEXUS_PANE_LIVE_VERDICT unset, so pd_paste_file
    # reports `pane-unknown` (RETRYABLE), never `dead-pane`.
    _tmux_pane_is_dead() {
        printf '%s: _pane-live.sh unavailable — cannot prove %q is a live pane, refusing to paste (your-org/nexus-code#745: a paste into a dead pane kills the tmux server)\n' \
            "${BASH_SOURCE[1]##*/}" "${1:-?}" >&2
        return 0
    }
fi

# ---- result variables (reset by each entry point) ------------------------
PD_OUTCOME=""            # submitted | submitted-after-retry | queued |
                         # queued-after-retry | held | blocked |
                         # blocked-before-paste | occupied-before-paste |
                         # inert | in-flight |
                         # undecidable-box | unverifiable | tmux-failed |
                         # dead-pane | pane-unknown
_PD_NEEDLE_DERIVED=""
PD_ENTER_RETRIES=0       # retry Enters actually sent (the first is not a retry)
PD_FAIL_STEP=""          # which tmux call failed, for the caller's diagnostic
PD_UNVERIFIABLE_REASON=""
PD_NORMALISED_BYTES=0    # bytes removed by the last pd_normalise_file
PD_TRANSCRIPT_GREW=0

# Return codes of pd_submit / pd_deliver. 3 and 4 are paste-followup.sh's
# RC_UNCONFIRMED / RC_NOT_SUBMITTED, kept so its contract does not move.
readonly PD_RC_OK=0
readonly PD_RC_TMUX=1
readonly PD_RC_UNCONFIRMED=3
readonly PD_RC_NOT_SUBMITTED=4
readonly PD_RC_DEAD_PANE=5
readonly PD_RC_PANE_UNKNOWN=6

# ---- layer 2: the normaliser ---------------------------------------------
#
# TIER U. Code points, in order: U+00AD; U+115F U+1160; U+202A–202E;
# U+2060–206F; U+3164; U+FE03–FE0D; U+FEFF; U+FFA0; U+FFF0–FFFB; U+16FE4;
# U+1D173–1D17A; U+E0080–E0FFF.
_PD_TIER_U='\xc2\xad|\xe1\x85[\x9f\xa0]|\xe2\x80[\xaa-\xae]|\xe2\x81[\xa0-\xaf]|\xe3\x85\xa4|\xef\xb8[\x83-\x8d]|\xef\xbb\xbf|\xef\xbe\xa0|\xef\xbf[\xb0-\xbb]|\xf0\x96\xbf\xa4|\xf0\x9d\x85[\xb3-\xba]|\xf3\xa0[\x82-\xbf][\x80-\xbf]'
# TIER C. U+034F; U+061C; U+17B4 U+17B5; U+180B–180F; U+200B–200F;
# U+FE00–FE02 U+FE0E U+FE0F; U+1107F; U+13430–1343F; U+1BCA0–1BCA3;
# U+E0000–E007F.
_PD_TIER_C='\xcd\x8f|\xd8\x9c|\xe1\x9e[\xb4\xb5]|\xe1\xa0[\x8b-\x8f]|\xe2\x80[\x8b-\x8f]|\xef\xb8[\x80-\x82\x8e\x8f]|\xf0\x91\x81\xbf|\xf0\x93\x90[\xb0-\xbf]|\xf0\x9b\xb2[\xa0-\xa3]|\xf3\xa0[\x80\x81][\x80-\xbf]'

# pd_normalise_file <in> <out>
#
# FAIL-OPEN, and that is the right polarity HERE: this is the fast path, and
# layer 1 is what makes delivery correct. If sed is missing or errors, <out>
# is a byte copy of <in> and the paste proceeds un-normalised. rc 0 when <out>
# is usable (normalised or copied), 1 when <out> could not be written at all.
pd_normalise_file() {
    local in="$1" out="$2" a b
    PD_NORMALISED_BYTES=0
    [[ -r "$in" ]] || return 1
    # FAIL-OPEN MEANS THE TABLES TOO. `${_PD_TIER_C}` on an UNSET variable is a
    # fatal expansion under a caller's `set -u` — not a failed command, so the
    # copy fallback below never runs and the CALLER dies mid-paste. Found by
    # mutation (delete the table line: every paste-followup row died, and a
    # table assertion passed vacuously on the missing output). An empty `()`
    # group would also make sed match the empty string everywhere. No table,
    # no normalisation: copy, and let layer 1 do its job.
    if [[ -z "${_PD_TIER_U:-}" || -z "${_PD_TIER_C:-}" ]]; then
        cp -f -- "$in" "$out" 2>/dev/null || return 1
        return 0
    fi
    if ! LC_ALL=C sed -E "
s/\xe2\x80[\xa8\xa9]/\n/g
s/(${_PD_TIER_U})//g
h
s/(${_PD_TIER_C})//g
/[\x80-\xff]/{x;}
" "$in" > "$out" 2>/dev/null; then
        cp -f -- "$in" "$out" 2>/dev/null || return 1
        return 0
    fi
    # LEADING BLANK LINES ARE DROPPED (your-org/nexus-code#1597) — the ONE stated
    # exception to "never over-strips". MEASURED on the real 2.1.278: the REPL
    # keeps a leading empty line, so the input row is the prompt glyph and nothing
    # else, the text sits on the NEXT row, and production pane-state — which
    # classifies the input from the glyph row alone — reads `idle input=blank`
    # for a box that is holding our payload. No `held` verdict, so no second
    # Enter: stranded one layer BEFORE pd_box_is_ours is ever asked. 2.1.278 does
    # RECORD that newline, so this removes bytes Claude Code would have kept; they
    # carry no instruction content, and with them the payload cannot be seen.
    # Lines of only space/TAB/CR count as blank (that reading is unmeasured; the
    # strip is a superset). FAIL-OPEN like the rest: a payload that would become
    # EMPTY is left exactly as it was, and an INNER blank line is never touched.
    # GNU sed keeps a missing final newline missing, so none is invented.
    if LC_ALL=C sed -e '/[^ \t\r]/,$!d' "$out" > "$out.lead" 2>/dev/null && [[ -s "$out.lead" ]]; then
        mv -f -- "$out.lead" "$out" 2>/dev/null || rm -f -- "$out.lead"
    else
        rm -f -- "$out.lead"
    fi
    a=$(stat -c %s "$in" 2>/dev/null) || a=0
    b=$(stat -c %s "$out" 2>/dev/null) || b=0
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] && (( a > b )) && PD_NORMALISED_BYTES=$(( a - b ))
    return 0
}

# ---- the paste itself ----------------------------------------------------
#
# pd_paste_file <tmux-target> <file> [<buffer-name>]
#
# VI-safe `i BSpace`, then the bytes go FILE -> buffer -> pane. They are NEVER
# an argv element: tmux 2.6 applies its command-list rule to a `set-buffer`
# DATA argument, so a message whose last character is `;` lost it, and a
# message that was exactly `;` failed (your-org/nexus-code#1590). `load-buffer`
# reads bytes. BRACKETED (`-p`), always (#521, #1516).
#
# The #745 guard is HERE as well as in each caller: the callers word the
# refusal for their operator, this one makes it structural — the only
# `paste-buffer` in the tree cannot be reached with a pane nobody proved live.
#
# rc 0 pasted; 1 a tmux call failed (PD_FAIL_STEP); 5 dead pane; 6 liveness
# could not be established (RETRYABLE — not a corpse diagnosis, #1017).
pd_paste_file() {
    local tgt="$1" file="$2" buf="${3:-nexus-paste-$$-${RANDOM}${RANDOM}}"
    PD_FAIL_STEP=""
    # The guard is asked about the NAME (or @id), not about the `:=` spelling.
    # `_tmux_pane_is_dead` walks `list-panes` rows and matches a name, an @id
    # or a %id EXACTLY; `:=orchestrator` matches no row while tmux resolves it
    # fine, which the guard rightly reads as "could not tell" and refuses. The
    # `:=` prefix only says "exact window name" (#1524), so the name it wraps is
    # precisely the key the guard wants.
    if _tmux_pane_is_dead "${tgt#:=}"; then
        if [[ "${NEXUS_PANE_LIVE_VERDICT:-}" == "dead" ]]; then
            PD_OUTCOME="dead-pane"; return "$PD_RC_DEAD_PANE"
        fi
        PD_OUTCOME="pane-unknown"; return "$PD_RC_PANE_UNKNOWN"
    fi
    tmux send-keys -t "$tgt" i BSpace 2>/dev/null \
        || { PD_OUTCOME="tmux-failed"; PD_FAIL_STEP="send-keys-insert"; return "$PD_RC_TMUX"; }
    sleep "${PD_INSERT_SETTLE_SECONDS:-0.1}"
    tmux load-buffer -b "$buf" "$file" 2>/dev/null \
        || { PD_OUTCOME="tmux-failed"; PD_FAIL_STEP="load-buffer"; return "$PD_RC_TMUX"; }
    if ! tmux paste-buffer -p -d -b "$buf" -t "$tgt" 2>/dev/null; then
        tmux delete-buffer -b "$buf" 2>/dev/null || true
        PD_OUTCOME="tmux-failed"; PD_FAIL_STEP="paste"; return "$PD_RC_TMUX"
    fi
    return 0
}

# ---- layer 1: evidence ---------------------------------------------------

_PD_TRANSCRIPT=""
_PD_NEEDLE=""
_PD_BASE=0
_PD_LAST=0
_PD_VERIFY=0

_pd_file_size() {
    local n
    [[ -f "$1" ]] || { printf '0'; return 0; }
    n=$(stat -c %s "$1" 2>/dev/null) || n=0
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# pd_evidence_begin <session-id>
#
# Set PD_EVIDENCE_NEEDLE (a unique substring of this paste), or call
# `_PD_NEEDLE_DERIVED=$(pd_needle_from_file <payload>)` first; pd_deliver does.
#
# Call BEFORE the paste, so the baseline cannot include our own submission.
# rc 0 verifiable; 1 not, with PD_UNVERIFIABLE_REASON naming why.
pd_evidence_begin() {
    local sid="${1:-}"
    _PD_TRANSCRIPT=""; _PD_BASE=0; _PD_LAST=0; _PD_VERIFY=0
    # The needle this paste's records must carry: the caller's if it named one,
    # else whatever pd_needle_from_file found (pd_deliver / the caller sets it).
    _PD_NEEDLE="${PD_EVIDENCE_NEEDLE:-${_PD_NEEDLE_DERIVED:-}}"
    PD_UNVERIFIABLE_REASON=""; PD_TRANSCRIPT_GREW=0
    if ! command -v jq >/dev/null 2>&1; then
        PD_UNVERIFIABLE_REASON="jq not on PATH — cannot read the session transcript"; return 1
    fi
    if ! declare -F se_transcript_for_session >/dev/null 2>&1; then
        PD_UNVERIFIABLE_REASON="monitor/_submit_evidence.sh unavailable"; return 1
    fi
    if [[ -z "$sid" ]]; then
        PD_UNVERIFIABLE_REASON="no session-id for the target"; return 1
    fi
    if ! _PD_TRANSCRIPT=$(se_transcript_for_session "$sid"); then
        _PD_TRANSCRIPT=""
        PD_UNVERIFIABLE_REASON="no transcript for session $sid under $(se_cc_homes | tr '\n' ' ')"
        return 1
    fi
    _PD_BASE=$(_pd_file_size "$_PD_TRANSCRIPT")
    _PD_LAST=$_PD_BASE
    _PD_VERIFY=1
    return 0
}

# Which delivery spelling, if any, was appended after the baseline.
# Prints `submission`, `enqueue` or nothing. Byte offset, not line offset: a
# live transcript reaches hundreds of MB and `tail -c` is O(1) in its size.
# `^\{.*\}$` drops the partial line a mid-append stat can land in; JSONL
# forbids raw newlines in strings, so no complete record is ever rejected.
#
# NO `| head -1` ON THE END OF THIS. An early-exit reader closes the pipe while
# jq is still writing, jq takes EPIPE, and under a caller's `pipefail` —
# paste-followup.sh runs `set -uo pipefail` — the pipeline's status becomes the
# WRITER's 141 (your-org/nexus-code#622, early-exit-readers.manifest, which is
# what caught the first cut of this function). Drain the stream and keep the
# first line by parameter expansion instead: there are at most a handful of
# records after the offset, and nothing can then close the pipe early.
_pd_records_since_base() {
    [[ -f "$_PD_TRANSCRIPT" ]] || return 0
    local out prog
    # `c` is a record's text whichever spelling it is; tool_result arrays are "".
    local def='def c: (if .type == "queue-operation" then (.content // "") else (.message.content | if type == "string" then . else "" end) end);'
    local nocompact='select((.isCompactSummary // false) | not)'
    if [[ -n "$_PD_NEEDLE" ]]; then
        prog="$def (( $_SE_JQ_SELECT | $nocompact | select(c | contains(\$n)) | \"submission\" ), ( $_SE_JQ_ENQUEUE_SELECT | select(c | contains(\$n)) | \"enqueue\" ))"
    else
        prog="$def (( $_SE_JQ_SELECT | $nocompact | select(has(\"promptSource\")) | select(.promptSource != \"queued\") | \"submission\" ), ( $_SE_JQ_ENQUEUE_SELECT | \"enqueue\" ))"
    fi
    out=$(tail -c +"$(( _PD_BASE + 1 ))" "$_PD_TRANSCRIPT" 2>/dev/null \
        | LC_ALL=C command grep -E '^\{.*\}$' 2>/dev/null \
        | jq -r --arg n "$_PD_NEEDLE" "$prog" 2>/dev/null) || true
    printf '%s' "${out%%$'\n'*}"
}

# pd_needle_from_file <file> — the longest run of printable ASCII (no TAB) in
# the payload, space-trimmed, capped at 200 bytes; EMPTY when no run reaches 12
# bytes (the selector then narrows instead — see the header). Drained through
# awk's END, never an early-exit reader.
pd_needle_from_file() {
    [[ -r "${1:-}" ]] || return 0
    LC_ALL=C command grep -aoE '[ -~]{12,}' "$1" 2>/dev/null | LC_ALL=C awk '
        { sub(/^ +/, ""); sub(/ +$/, ""); if (length($0) > length(b)) b = $0 }
        END { if (length(b) >= 12) printf "%s", substr(b, 1, 200) }'
}

_PD_EVIDENCE_KIND=""
# rc 0 the moment either surface holds. The transcript scan is gated on the
# file having GROWN: an inert session costs one stat per poll.
pd_evidence_seen() {
    local cur kind
    _PD_EVIDENCE_KIND=""
    if (( _PD_VERIFY )); then
        cur=$(_pd_file_size "$_PD_TRANSCRIPT")
        if (( cur != _PD_LAST )); then
            _PD_LAST=$cur
            (( cur > _PD_BASE )) && PD_TRANSCRIPT_GREW=1
            kind=$(_pd_records_since_base)
            if [[ -n "$kind" ]]; then _PD_EVIDENCE_KIND="$kind"; return 0; fi
        fi
    fi
    if [[ -n "${PD_EXTRA_EVIDENCE_FN:-}" ]] && declare -F "$PD_EXTRA_EVIDENCE_FN" >/dev/null 2>&1; then
        if "$PD_EXTRA_EVIDENCE_FN"; then _PD_EVIDENCE_KIND="submission"; return 0; fi
    fi
    return 1
}

# pd_pane_verdict <pane-state-key> [before-paste]
#
# held     state=user-typing AND input=typed — the text is IN the input box.
#          An ALLOWLIST of one: `input=?` is undecidable and `ghost`/`blank`
#          say nothing typed is there (w234sk F8).
# queued   the pane is mid-turn. AFTER our paste, typed text in a mid-turn box
#          is expected (ours, queued behind the turn), so the default mode does
#          not read `input=` here.
#          `before-paste` mode (your-org/nexus-code#1683 F1) DOES: before a byte
#          of ours goes out, typed text in a mid-turn box can only be somebody
#          else's, so a busy-family pane with input=typed is `held` and one with
#          input=? is `draft` — the same allowlist as `user-typing`. A busy line
#          with no `input=` field (no REPL row to read) stays `queued`: every
#          doubt pastes, as before.
# blocked  an overlay is up. NEVER press Enter.
# draft    state=user-typing with input=? — undecidable, so treated as an
#          operator draft. NEVER press Enter.
# clear    readable, and the box holds nothing typed (idle, ghost, blank …).
#          An Enter there is a no-op at best, so none is sent.
# unknown  could not look (no key, no pane-state, empty answer, state=unknown
#          or empty). NO Enter: there is no blind retry.
#
# FIELD-EXACT, never a greedy `sed 's/.*state=…'` (#1295 review): that binds
# to the LAST `state=` on the line, so `refined_state=blocked` would refuse an
# idle pane and a trailing `…_state=idle` would wave a real overlay through.
_pd_field() {
    printf '%s' "$1" | awk -v k="$2" '{
        for (i = 1; i <= NF; i++) {
            n = index($i, "=")
            if (n > 0 && substr($i, 1, n - 1) == k) { print substr($i, n + 1); exit }
        }
    }'
}
pd_pane_verdict() {
    local key="${1:-}" mode="${2:-}" bin="${PD_PANE_STATE_BIN:-$_pd_dir/pane-state.sh}" line st inp
    [[ -n "$key" && -x "$bin" ]] || { printf 'unknown'; return 0; }
    # THE VERDICT MUST COME FROM THE TMUX THE PASTE WENT TO. pane-state.sh is an
    # EXTERNAL process: it runs whatever `tmux` is on PATH. If `tmux` is a shell
    # FUNCTION in this shell — every suite that aims these functions at a private
    # server does exactly that — the paste went one way and an external reader
    # would look another: inside an agent pane, at the LIVE board's window of the
    # same name. A reading about a different pane is worse than none, because
    # `held` authorises an Enter. So: unknown, unless the caller named its own
    # reader explicitly (PD_PANE_STATE_BIN), which is what a rig does.
    if [[ -z "${PD_PANE_STATE_BIN:-}" ]] && declare -F tmux >/dev/null 2>&1; then
        printf 'unknown'; return 0
    fi
    line=$("$bin" "$key" 2>/dev/null) || line=""
    [[ -n "$line" ]] || { printf 'unknown'; return 0; }
    st=$(_pd_field "$line" state); inp=$(_pd_field "$line" input)
    case "$st" in
        blocked)                  printf 'blocked' ;;
        user-typing)
            case "$inp" in
                typed) printf 'held' ;;
                # `input=?` is undecidable from bytes and is READ AS A DRAFT
                # (#626). A draft never earns an Enter — not even the one blind
                # retry (pastesk F2).
                "?")   printf 'draft' ;;
                *)     printf 'clear' ;;
            esac ;;
        busy|working-background|working-self-paced)
            if [[ "$mode" == before-paste && "$inp" == typed ]]; then printf 'held'
            elif [[ "$mode" == before-paste && "$inp" == "?" ]]; then printf 'draft'
            else printf 'queued'; fi ;;
        # "could not look" and "don't know yet" are NOT "the box is clear".
        unknown|empty|"")         printf 'unknown' ;;
        *)                        printf 'clear' ;;
    esac
}

# pd_box_is_ours <tmux-target> <payload-file> — THE EQUALITY. rc 0 only when
# the input box's visible content is positively this payload; rc 1 for anything
# else, INCLUDING "could not read the pane". See the header.
#
# WHICH ROW (skeptic pastesk round 4): submitted prompts in the history ALSO
# render as `❯ text` at column 1, so "the last `❯` row" is the input row only
# while the input box is drawn LAST — which it is in every real capture under
# monitor/watcher/fixtures/*realmodel*, and in both builds measured. A layout
# that drew history below the box would make this read a HISTORY row; that fails
# toward "not ours" unless the history row happens to be this very payload.
#
# The input row is the LAST row that starts with Claude Code's prompt glyph
# `❯` (e2 9d af), which is followed by a no-break space (c2 a0) — bytes read off
# the real 2.1.278 and 2.1.273. Compared as ASCII PROJECTIONS (every byte
# >= 0x80 dropped on both sides, TAB as four spaces): Claude Code's cleaning
# removes only non-ASCII invisibles, so the projection of what it shows equals
# the projection of what we pasted, whatever its rule is.
#
# THE WHOLE INPUT REGION, NOT THE GLYPH ROW (your-org/nexus-code#1729). The first
# cut decided on the `❯` row ALONE, so our chip with an operator CONTINUATION
# below it (shift+Enter after the chip, then text — an indented row under the
# glyph row) read as ours, and the retry Enter submitted the operator's text
# together with our brief. So every row AFTER the glyph row, up to the box's
# bottom border (a row of nothing but `─` U+2500, 3+ of them — the real 2.1.273
# capture draws a full-width one directly under the input, see
# fixtures/pasted-multiline-chip-realmodel-273.ansi) or the end of the capture,
# is now part of the decision:
#   placeholder  every one of those rows must be BLANK (visible projection).
#   text         the region, WHITESPACE-FREE, must EQUAL the whole payload,
#                whitespace-free, under the visible projection. Whitespace-free
#                so a line Ink WRAPS (at a word, dropping the space, or mid-word)
#                and the two-column continuation indent compare equal; a row the
#                payload does not account for cannot. The ASCII fallback (first
#                row only, below) admits the region only when its ASCII
#                projection equals the payload's AND every continuation row is
#                pure ASCII — so an extra row is caught by one or the other.
# The old first-row tests still GATE both branches, so this only ever refuses
# more. ERROR DIRECTION, stated: a payload row that itself is nothing but `─`
# ends the region early and the equality then fails — refused, the safe side;
# a multi-row payload of ours whose LATER rows carry a glyph the visible
# projection cannot predict is refused too (`draft`, never an Enter). No border
# found means the region runs to the end of the capture: anything drawn there
# (a footer) is refused, never accepted.
pd_box_is_ours() {
    local tgt="$1" file="${2:-}" cap row text first k n rest
    [[ -n "$file" && -r "$file" ]] || return 1
    cap=$(tmux capture-pane -p -t "$tgt" -S -40 2>/dev/null) || return 1
    row=$(printf '%s\n' "$cap" | LC_ALL=C awk 'index($0, "\342\235\257") == 1 { r = $0 } END { printf "%s", r }')
    [[ -n "$row" ]] || return 1
    # The rows BELOW that glyph row, up to the bottom border (#1729). The same
    # "last row starting with `❯`" rule as `row` above, so both read one box.
    rest=$(printf '%s\n' "$cap" | LC_ALL=C awk '
        index($0, "\342\235\257") == 1 { s = ""; done = 0; next }
        { if (done) next
          t = $0; n = gsub(/\342\224\200/, "", t)
          if (n >= 3 && t ~ /^[ \t]*$/) { done = 1; next }
          s = s $0 "\n" }
        END { printf "%s", s }')
    local rowraw text_v want_v want_a
    rowraw=$(printf '%s' "$row" | LC_ALL=C sed -e 's/^\xe2\x9d\xaf//' -e 's/^\(\xc2\xa0\| \)*//')
    # TWO projections of the row. `text` is the ASCII one (every byte >= 0x80
    # dropped); `text_v` is the VISIBLE one (only Claude Code's invisible candidate
    # set dropped). See the text branch below for which decides what, and why.
    text=$(printf '%s' "$rowraw" | LC_ALL=C sed -e 's/[\x80-\xff]//g' -e 's/[[:space:]]*$//')
    text_v=$(printf '%s' "$rowraw" | _pd_visible)
    [[ -n "$text_v" ]] || return 1
    if [[ "$text" == "[Pasted text #"* ]]; then
        # Nothing but placeholders, and EVERY one carries OUR line count, exactly.
        # The spelling and the count are Claude Code's own, read out of the
        # 2.1.278 binary (and 2.1.273's equivalent):
        #     a4(id, n) = n === 0 ? `[Pasted text #${id}]` : `[Pasted text #${id} +${n} lines]`
        #     n         = (text.match(/\r\n|\r|\n/g) || []).length
        # so a SINGLE-LINE paste over 800 chars has NO `+K lines` at all — the
        # first cut demanded one and stranded our own long single-line payload
        # (skeptic pastesk F9; its fake REPL printed `+0 lines`, which the binary
        # never does, so the suite stayed green).
        [[ "$text" =~ ^(\[Pasted\ text\ \#[0-9]+(\ \+[0-9]+\ lines)?\])+$ ]] || return 1
        n=$(_pd_expected_k "$file") || return 1
        [[ "$n" =~ ^[0-9]+$ ]] || return 1
        # A PLACEHOLDER CAN BE OURS ONLY IF OUR PAYLOAD WOULD COLLAPSE (skeptic
        # pastesk F12). Once the count-less spelling was accepted it EQUALLED
        # every zero-break payload of ours — every unstick line, every
        # `--message` send — including SHORT ones the binary never collapses, and
        # an operator's long single-line paste appearing 0.3 s after our submit
        # was SUBMITTED by the retry. A payload of ours that the binary renders
        # as TEXT cannot be the placeholder in the box.
        if ! _pd_would_collapse "$file" "$n"; then
            return 1
        fi
        while IFS= read -r k; do
            k="${k#*+}"; [[ "$k" == *" lines]" ]] && k="${k%% *}" || k=0
            [[ "$k" =~ ^[0-9]+$ ]] || return 1
            (( k == n )) || return 1
        done < <(printf '%s' "$text" | LC_ALL=C command grep -oE '\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]')
        # …and NOTHING below the chip (#1729): an operator continuation row
        # under our placeholder is text the next Enter would submit with it.
        [[ -z "$(printf '%s' "$rest" | _pd_visible | _pd_wsfree)" ]] || return 1
        return 0
    fi
    IFS= read -r first < "$file" || [[ -n "$first" ]] || return 1
    # THE VISIBLE PROJECTION DECIDES (your-org/nexus-code#1597). The first cut
    # compared ASCII projections only, and that was wrong in BOTH directions:
    #   STRANDED       a first line with no ASCII at all projects to the empty
    #                  string, which can never match, so a held CJK line stayed held;
    #   WRONGLY SENT   whole-row equality was accepted at ANY length, and short
    #                  projections COLLIDE: our `<CJK> OK <CJK>` and an operator's
    #                  unrelated `<other CJK> OK <CJK>` both project to ` OK`, the
    #                  equality held, and the retry Enter SUBMITTED THE DRAFT
    #                  (test-paste-deliver.sh U97-collide, red at d58bc49a). That is
    #                  the unrecoverable direction, and nobody had recorded it.
    # So: compare with ONLY the invisible candidate set removed (Tier U + Tier C,
    # from both sides — whichever of them Claude Code kept in context, both sides
    # lose it), whole or as a wrapped prefix of 8+ CODE POINTS. MEASURED: the real
    # 2.1.278 box and a tmux 2.6 capture return CJK one code point per character,
    # no padding cell, and tmux returns emoji, a ZWJ family, a decomposed accent
    # and a keycap byte-identical.
    want_v=$(printf '%s' "$first" | _pd_visible)
    [[ -n "$want_v" ]] || return 1
    # FALLBACK, and only where it is DISCRIMINATING: what INK does to an emoji
    # when it draws the box is NOT measured, so an ASCII-rich line must not be
    # stranded by a glyph we cannot predict. 8+ ASCII characters, whole or prefix —
    # never the short whole-equality that collided above.
    want_a=$(printf '%s' "$first" | LC_ALL=C sed -e 's/\t/    /g' -e 's/[\x80-\xff]//g' -e 's/[[:space:]]*$//')
    local by_v=0 by_a=0
    if [[ "$want_v" == "$text_v" ]] || { (( $(_pd_cp_len "$text_v") >= 8 )) && [[ "$want_v" == "$text_v"* ]]; }; then
        by_v=1
    fi
    (( ${#text} >= 8 )) && [[ "$want_a" == "$text"* ]] && by_a=1
    (( by_v || by_a )) || return 1
    # THE FIRST ROW IS NECESSARY, NOT SUFFICIENT (#1729): the whole input region
    # must be the whole payload. Visible projection first, whitespace-free.
    local box_v pay_v
    box_v=$( { printf '%s\n' "$rowraw"; printf '%s' "$rest"; } | _pd_visible | _pd_wsfree)
    pay_v=$(_pd_visible < "$file" | _pd_wsfree)
    [[ -n "$pay_v" && "$box_v" == "$pay_v" ]] && return 0
    # The ASCII route, only behind a first row the fallback itself admitted: the
    # region's ASCII projection equals the payload's (no extra ASCII), AND every
    # continuation row is pure ASCII (no extra non-ASCII the projection drops).
    (( by_a )) || return 1
    [[ "$(printf '%s' "$rest" | LC_ALL=C tr -d '\000-\177' | wc -c | tr -d ' ')" == 0 ]] || return 1
    local box_a pay_a
    box_a=$( { printf '%s\n' "$rowraw"; printf '%s' "$rest"; } | LC_ALL=C sed -e 's/[\x80-\xff]//g' | _pd_wsfree)
    pay_a=$(LC_ALL=C sed -e 's/[\x80-\xff]//g' < "$file" | _pd_wsfree)
    [[ -n "$pay_a" && "$box_a" == "$pay_a" ]] && return 0
    return 1
}

# _pd_wsfree (stdin -> stdout): every ASCII whitespace byte removed, newlines
# included — the comparison basis for a WRAPPED, indented input region (#1729).
_pd_wsfree() { LC_ALL=C tr -d ' \t\n\r\013\014'; }

# _pd_visible (stdin -> stdout): TAB as four spaces, the invisible candidate set
# (Tier U + Tier C) removed, trailing whitespace trimmed. With no tier tables
# loaded it removes nothing — the comparison is then merely stricter.
_pd_visible() {
    if [[ -n "${_PD_TIER_U:-}" && -n "${_PD_TIER_C:-}" ]]; then
        LC_ALL=C sed -E -e 's/\t/    /g' -e "s/(${_PD_TIER_U})//g" -e "s/(${_PD_TIER_C})//g" -e 's/[[:space:]]*$//'
    else
        LC_ALL=C sed -E -e 's/\t/    /g' -e 's/[[:space:]]*$//'
    fi
}
# _pd_cp_len <string>: its length in CODE POINTS, from bytes under LC_ALL=C
# (every byte that is not a UTF-8 continuation byte starts one).
_pd_cp_len() {
    local n
    n=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c) || n=0
    printf '%s' "${n//[!0-9]/}"
}

# _pd_expected_k <payload-file> — the K Claude Code will print for this payload.
# DERIVED, not tolerated (skeptic pastesk F11): K counts `\r\n|\r|\n` in the
# text Claude Code RECEIVES, and tmux's paste maps every LF to CR on the way —
# so no `\r\n` pair survives, and K is simply the payload's LF count PLUS its CR
# count, plus the separators Claude Code maps to a line break before counting
# (VT, FF, NEL; U+2028/2029 too, which pd_normalise_file has already made LF).
# The first cut accepted K or K+1, an unmeasured tolerance that only widened the
# set of OPERATOR pastes able to satisfy the equality.
_pd_expected_k() {
    local a b
    a=$(LC_ALL=C tr -cd '\n\r\013\014' < "$1" 2>/dev/null | wc -c) || return 1
    b=$(LC_ALL=C command grep -o $'\xc2\x85' "$1" 2>/dev/null | wc -l) || b=0
    printf '%s' "$(( ${a//[!0-9]/} + ${b//[!0-9]/} ))"
}

# _pd_would_collapse <payload-file> <K> — the binary's OWN rule for the REPL
# prompt's paste handler, read from 2.1.278 (`Ole`) and 2.1.273 (its twin):
#     t = stripANSI(paste).replace(/\r\n|\r/g, "\n").replaceAll("\t", "    ")
#     collapse when  t.length > 800  ||  breaks(t) > max(0, min(rows - 10, 2))
# `length` is JavaScript's: UTF-16 code units, so a code point above U+FFFF counts
# twice. Computed from bytes under LC_ALL=C: every byte that is not a UTF-8
# continuation byte starts a code point, and a 4-byte lead (f0-f4) adds one more.
# EVERY TAB COUNTS AS FOUR (skeptic pastesk F13). The first cut took its rule
# from the binary's OTHER paste path (`$c`), which does not expand TABs, and so
# said "would not" for our own held line of 671 units with 80 TABs — 911 to the
# binary, collapsed in the box, and stranded as `undecidable-box`.
# ERROR DIRECTION, stated: every other transformation the binary applies first
# (stripANSI, its cleaning, CRLF to LF) can only SHORTEN the text, so within a few
# characters of 800 this may say "would collapse" for a payload the binary shows
# as text. That is harmless — the box then holds text, the placeholder branch is
# never entered, and the text branch decides. In a pane of 12 rows or more it
# never says "would not" for a payload that does collapse; under 12 rows the
# break threshold drops below 2 and it can (the header states that residual).
_pd_would_collapse() {
    local file="$1" k="${2:-0}" bytes cont astral tabs
    (( k > 2 )) && return 0
    bytes=$(LC_ALL=C wc -c < "$file" 2>/dev/null) || return 1
    cont=$(LC_ALL=C tr -cd '\200-\277' < "$file" 2>/dev/null | wc -c) || cont=0
    astral=$(LC_ALL=C tr -cd '\360-\364' < "$file" 2>/dev/null | wc -c) || astral=0
    tabs=$(LC_ALL=C tr -cd '\t' < "$file" 2>/dev/null | wc -c) || tabs=0
    bytes=${bytes//[!0-9]/}; cont=${cont//[!0-9]/}; astral=${astral//[!0-9]/}; tabs=${tabs//[!0-9]/}
    (( ${bytes:-0} - ${cont:-0} + ${astral:-0} + 3 * ${tabs:-0} > 800 ))
}

# pd_submit <tmux-target> <pane-state-key> [<windows>]
#
# Press Enter, then establish what happened. <windows> is a space-separated
# list of confirm windows in seconds, one per Enter: its length minus one is
# the retry bound. Default `PD_CONFIRM_WINDOWS` or "3 3 3" — CHOSEN, not
# measured as optimal: a send shows its evidence within ~1 s on both 2.1.273
# and 2.1.278, three windows keep the worst case (~9 s) well inside the 20 s
# per-target paste lock, and two retries cover a hold plus one ignored Enter.
#
# Inside a window the pane is asked every PD_HELD_CHECK_SECONDS (default 1):
# TWO consecutive `held` readings with no evidence end the window early, so a
# held prompt costs ~2 s, not the whole window. Two, because one reading can
# land between the keypress and the repaint.
#
# rc 0 PD_OUTCOME=submitted | queued | *-after-retry
#    3 in-flight (transcript grew, nothing of ours yet) | unverifiable |
#      undecidable-box (typed text is there and cannot be shown to be ours)
#    4 held (in the box after every retry) | blocked | inert
#    1 tmux refused the Enter
pd_submit() {
    local tgt="$1" key="${2:-}" windows="${3:-${PD_CONFIRM_WINDOWS:-3 3 3}}"
    local poll="${PD_POLL_SECONDS:-0.25}" held_every="${PD_HELD_CHECK_SECONDS:-1}"
    local -a win; read -r -a win <<<"$windows"
    (( ${#win[@]} >= 1 )) || win=(3)
    local w=0 verdict="" iters i per_check held_streak can_confirm=0 nonheld_seen=0 nonheld_streak=0
    PD_ENTER_RETRIES=0; PD_OUTCOME=""
    # Can ANY evidence ever appear? If not, polling for it is theatre: the only
    # thing worth waiting for is a positive `held`, and a blind retry has no
    # success criterion — so none is sent (paste-followup.sh's historical
    # behaviour for an unverifiable target: one Enter, rc 3).
    if (( _PD_VERIFY )) || [[ -n "${PD_EXTRA_EVIDENCE_FN:-}" ]]; then can_confirm=1; fi

    sleep "${PD_PRE_ENTER_SECONDS:-0.2}"
    tmux send-keys -t "$tgt" Enter 2>/dev/null \
        || { PD_OUTCOME="tmux-failed"; PD_FAIL_STEP="send-keys-enter"; return "$PD_RC_TMUX"; }

    while :; do
        iters=$(awk -v s="${win[$w]}" -v p="$poll" 'BEGIN { n = s / p; printf "%d", (n < 1 ? 1 : n) }')
        per_check=$(awk -v s="$held_every" -v p="$poll" 'BEGIN { n = s / p; printf "%d", (n < 1 ? 1 : n) }')
        held_streak=0; verdict=""
        for (( i = 0; i < iters; i++ )); do
            if pd_evidence_seen; then _pd_submit_ok; return 0; fi
            # One EARLY reading (i == 1) besides the cadence: OUR held text is in
            # the box continuously from the paste on, so a box seen EMPTY at any
            # point means a later `held` is somebody else's text (pastesk F3).
            if (( i == 1 || ( i > 0 && i % per_check == 0 ) )); then
                verdict=$(pd_pane_verdict "$key")
                _pd_note_reading "$verdict"
                if [[ "$verdict" == held ]]; then
                    (( i == 1 )) || held_streak=$(( held_streak + 1 ))
                    (( held_streak >= 2 )) && break
                else
                    held_streak=0
                    [[ "$verdict" == blocked ]] && break
                    # Nothing can confirm and the box has been seen without
                    # typed text TWICE running: nothing left here to learn.
                    (( ! can_confirm && nonheld_seen )) && break
                fi
            fi
            sleep "$poll"
        done
        if pd_evidence_seen; then _pd_submit_ok; return 0; fi
        if [[ -z "$verdict" || "$verdict" == unknown ]]; then
            verdict=$(pd_pane_verdict "$key"); _pd_note_reading "$verdict"
        fi
        # A LONE non-held reading at the end of a window decides nothing: look
        # once more, a cadence later, before it is allowed to withhold an Enter.
        case "$verdict" in clear|queued|draft)
            if (( ! nonheld_seen )); then
                sleep "$held_every"
                verdict=$(pd_pane_verdict "$key"); _pd_note_reading "$verdict"
            fi ;;
        esac
        # `held` is a SHAPE. The Enter needs the EQUALITY: the box's content must
        # be THIS payload (see the header). A draft, a ghost, an unreadable pane,
        # a caller that named no payload — none of them is ours.
        if [[ "$verdict" == held ]] && ! pd_box_is_ours "$tgt" "${PD_PAYLOAD_FILE:-}"; then
            verdict=draft
        fi

        # Decide whether another Enter is warranted — see the header.
        case "$verdict" in
            blocked) PD_OUTCOME="blocked"; return "$PD_RC_NOT_SUBMITTED" ;;
            queued|clear|draft) break ;;
            held)    : ;;      # held AND ours — the only road to another Enter
            *)       break ;;  # unknown: could not look. No blind retry.
        esac
        (( w + 1 < ${#win[@]} )) || break
        w=$(( w + 1 ))
        tmux send-keys -t "$tgt" Enter 2>/dev/null || break
        PD_ENTER_RETRIES=$(( PD_ENTER_RETRIES + 1 ))
    done

    if pd_evidence_seen; then _pd_submit_ok; return 0; fi
    if [[ "$verdict" == held ]]; then
        PD_OUTCOME="held"; return "$PD_RC_NOT_SUBMITTED"
    fi
    if [[ "$verdict" == draft ]]; then
        # Text is in the box and it cannot be shown to be ours. No Enter, and no
        # verdict either way: UNCONFIRMED.
        PD_OUTCOME="undecidable-box"; return "$PD_RC_UNCONFIRMED"
    fi
    if (( ! can_confirm )); then
        PD_OUTCOME="unverifiable"; return "$PD_RC_UNCONFIRMED"
    fi
    if (( PD_TRANSCRIPT_GREW )) || [[ "$verdict" == queued ]]; then
        PD_OUTCOME="in-flight"; return "$PD_RC_UNCONFIRMED"
    fi
    if (( ! _PD_VERIFY )); then
        PD_OUTCOME="unverifiable"; return "$PD_RC_UNCONFIRMED"
    fi
    PD_OUTCOME="inert"; return "$PD_RC_NOT_SUBMITTED"
}

# (Since the retry became an EQUALITY — see the header — `nonheld_seen` no longer
# decides whether an Enter is pressed. It only decides when a window with
# nothing to confirm may END early. The history below is why it needs two
# readings to do even that.)
# ONE READING IS NOT A FACT (skeptic pastesk F6 on #1595). The F3 rule — "a box
# seen without typed text means a later `held` is somebody else's draft" — was
# first written ONE-STRIKE, and a single transient frame then stranded a REAL
# hold: the pane reading `busy` for 0.4 s after the cleaning Enter turned every
# later `held` into `draft`, no Enter was sent, and the emit sat in the box — the
# direction #1591 is about, introduced by the fix for F3. So the box counts as
# "seen without typed text" only on TWO CONSECUTIVE non-held readings, which are
# a cadence apart: a repaint does not last that long, a human draft takes longer
# than that to appear. Uses pd_submit's locals through bash's dynamic scope.
_pd_note_reading() {
    case "$1" in
        clear|queued|draft) nonheld_streak=$(( nonheld_streak + 1 ))
                            (( nonheld_streak >= 2 )) && nonheld_seen=1 ;;
        held)               nonheld_streak=0 ;;
    esac
    return 0
}

_pd_submit_ok() {
    local base="submitted"
    [[ "$_PD_EVIDENCE_KIND" == enqueue ]] && base="queued"
    if (( PD_ENTER_RETRIES > 0 )); then PD_OUTCOME="${base}-after-retry"; else PD_OUTCOME="$base"; fi
}

# pd_deliver <tmux-target> <pane-state-key> <file> <session-id> [<windows>]
#
# The whole sequence for a caller with no bookkeeping of its own between the
# paste and the Enter: normalise -> baseline -> paste -> submit. The caller's
# <file> is never modified. rc as pd_paste_file / pd_submit.
pd_deliver() {
    local tgt="$1" key="$2" file="$3" sid="${4:-}" windows="${5:-}"
    local norm rc
    norm=$(mktemp "${TMPDIR:-/tmp}/nexus-paste.XXXXXX") || norm=""
    if [[ -n "$norm" ]] && pd_normalise_file "$file" "$norm"; then :; else
        [[ -n "$norm" ]] && rm -f "$norm"; norm=""
    fi
    # THE FIRST ENTER IS NOT BLIND EITHER (pastesk F4). "Never into blocked"
    # used to hold for the RETRIES only: the emit, unstick and respawn paths
    # pasted and pressed Enter without looking, and an Enter into an overlay
    # SELECTS ITS HIGHLIGHTED DEFAULT (#1200). One read, before a byte goes out.
    # Only a POSITIVE `blocked` refuses; every doubt pastes, as in
    # paste-followup.sh's own guard.
    #
    # …AND NEVER INTO A BOX THAT ALREADY HOLDS TYPED TEXT (your-org/nexus-code#1674).
    # A bracketed paste lands at the CURSOR, so into an operator's half-typed
    # message it MERGES, and our Enter then submits the draft with the emit inside
    # it. Measured on the live board 2026-09-29 13:16:02: the startup-sweep emit
    # was pasted into the operator's message and sent it mid-word (the enqueue
    # record: operator text, then the emit, then a word cut in half). That
    # record carried our needle, so this primitive reported `queued` — delivered — for the operator's own message.
    # The retry Enters have been an EQUALITY since #1596; the FIRST Enter was
    # still a shape-blind one into whatever the box held. So the same allowlist
    # decides here: `held` (user-typing input=typed) and `draft` (input=?,
    # undecidable, read as a draft per #626) paste NOTHING. A ghost, a blank box,
    # `busy`, an unreadable pane — every doubt — still pastes, exactly as before.
    # ERROR DIRECTION, stated: this also defers when the typed text is an EARLIER
    # paste of ours still stuck in the box, so a stranded emit now blocks later
    # ones (each refusal logged) instead of being submitted merged with them.
    # RESIDUAL: a draft begun between this read and the paste (~0.3 s) is not seen.
    # `before-paste`: a MID-TURN pane's box is read too (your-org/nexus-code#1683
    # F1) — an operator types ahead into a busy worker, and that draft is exactly
    # as mergeable as one in an idle box.
    local _pd_pre; _pd_pre=$(pd_pane_verdict "$key" before-paste)
    if [[ "$_pd_pre" == blocked ]]; then
        [[ -n "$norm" ]] && rm -f "$norm"
        PD_ENTER_RETRIES=0; PD_OUTCOME="blocked-before-paste"
        return "$PD_RC_NOT_SUBMITTED"
    fi
    if [[ "$_pd_pre" == held || "$_pd_pre" == draft ]]; then
        [[ -n "$norm" ]] && rm -f "$norm"
        PD_ENTER_RETRIES=0; PD_OUTCOME="occupied-before-paste"
        return "$PD_RC_NOT_SUBMITTED"
    fi
    _PD_NEEDLE_DERIVED=$(pd_needle_from_file "${norm:-$file}")
    pd_evidence_begin "$sid" || true
    pd_paste_file "$tgt" "${norm:-$file}"; rc=$?
    if (( rc == 0 )); then
        # The bytes that were PASTED are what the box must equal.
        PD_PAYLOAD_FILE="${norm:-$file}" pd_submit "$tgt" "$key" "$windows"; rc=$?
    fi
    [[ -n "$norm" ]] && rm -f "$norm"
    return "$rc"
}
