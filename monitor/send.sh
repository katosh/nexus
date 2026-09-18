#!/usr/bin/env bash
# monitor/send.sh — `ng send`: the first conforming implementation of the
# harness-neutral agent-delivery contract.
#
#   FULL CONTRACT: skills/nexus.agent-delivery/SKILL.md   ← read this first.
#
# WHAT THIS IS FOR. An orchestrator (or the watcher, or a script) must hand an
# instruction to an agent and find out whether it ARRIVED. `paste-followup.sh`
# does that for a tmux+Claude-Code agent and keeps all 47 of its callers; this
# adds the seam a SECOND harness plugs into, so a nexus can host agents of
# different harnesses at the same time and address any of them the same way.
#
# THE GUARD IS THE POINT. `_idle_unconfirmed_paste_epoch` catches a lost
# instruction by matching `$3 == "paste-followup"` EXACTLY in machine-input.tsv
# (_idle_probe.sh:1481, verified at a2cefa2). A transport that writes any other
# token is SILENTLY exempt from the delivery guard. So this file — not the
# transport — owns column 3, and no adapter can override it. The guard's VALUE
# is structurally inescapable rather than conventionally respected. That inverts
# #1049's constraint 3 from an annoyance into the load-bearing design rule.
#
# ROW COVERAGE IS A WEAKER PROMISE THAN THE KEY'S VALUE, and the gap is
# `invoke: agent`: this file never carries such a transport, so it never stamps
# for one. `--stamp-only` closes the gap only as far as the calling agent
# remembers to use it — see the paragraph below, and SKILL §3's exception table.
#
# THE EXCLUSIVITY RULE (SKILL §4), which is why this is safe to chain:
#
#     Advance to the next transport ONLY on an ESTABLISHED negative.
#     On `unknown`, STOP. A fallback fires on a proven non-delivery,
#     never on an absent confirmation.
#
# A send that RETURNED SUCCESS is not delivery: #1049 measured `success:true`
# with a msg_id from a SIGKILLed peer, ~3 minutes after the kill. Under this
# rule that is `unknown` and the chain HALTS, rather than pasting a second copy
# of an instruction that may yet land. A duplicated instruction has produced
# duplicate comments and duplicate commits on this board; a fallback whose
# failure mode is double execution is strictly worse than the single transport
# it means to improve.
#
# WHAT THIS CANNOT DO, MEASURED. Claude Code's `SendMessage` is an IN-PROCESS
# TOOL — `claude --help` at 2.1.246 has no `send`/`message` subcommand. No
# shell caller can perform it. It is declared `invoke: agent`; the chain SKIPS
# it and says so. The supported path is `--stamp-only` (stamp here, send from
# your own tool loop), then `--check`. That closes the real present-day hole:
# a raw agent-to-agent SendMessage is UNSTAMPED, so its submit reads as
# operator input and the delivery guard never sees it.
#
# Usage:
#   ng send <window> [--file <p> | --message <t> | stdin]   deliver
#   ng send <window> --stamp-only --transport <name> …      stamp, do not send
#   ng send <window> --check --nonce <hex>                  poll for a receipt
#       Scoped to the transport that CARRIED that nonce (read back from the
#       sidecar), never to "the transports". rc 4 therefore means THAT carrier
#       is provably unreachable. An explicit --transport may only NAME the
#       recorded carrier; a mismatch is refused.
#   ng send <window> --check --last                         poll for the NEWEST
#       ng-send record on that window (your-org/nexus-code#1367) — the nonce
#       is read back from the epoch-keyed sidecar, so an UNKNOWN can be
#       resolved AFTER THE FACT by a caller that never captured stdout (a
#       loop, a `grep` that kept only the verdict line). NOT a fallback: it
#       only finds the send you already made. --last and --nonce exclude
#       each other.
#   ng send <window> --list                                 every send record
#       for that window, newest first, one line each:
#       `epoch= time= nonce= transport= outcome=` (`-` = not recorded; a
#       direct paste-followup.sh paste carries no nonce). rc 1 when none.
#   ng send <window> --ledger-coverage                      can this ledger's
#       SILENCE about <window> be read as "no send"? Names, per declared
#       transport, whether a delivery through it writes a row here. rc 0 =
#       every declared transport stamps; rc 3 = an `invoke: agent` transport
#       is declared and a delivery through it leaves NO ROW unless the
#       sending agent ran --stamp-only — so a missing row is not evidence
#       (your-org/nexus-code#1368, SKILL §3).
#   ng send <window> --dry-run                              show the chain
#
# Options. The first four are FORWARDED verbatim to the transport (they are
# paste-followup.sh's, documented there); `ng send` owns only the ledger
# stamp, so it must still advertise what it accepts — a flag parsed here and
# absent from this block is undiscoverable by construction (#883).
#   --note <text>        action-log annotation; never part of the payload.
#   --issue <n>          action-log issue cross-ref.
#   --comment <id>       action-log trigger-comment cross-ref.
#   --administrative     (alias --no-retask) this delivery does NOT re-task
#                        the agent. Deliberately not guessed from --note prose.
#   --confirm-timeout <sec>  how long to wait for the receipt before
#                        reporting `unknown`. Forwarded to the carrier.
#   --help, -h           this text.
#
# Test seams (hermetic suite; never set in production):
#   NEXUS_STATE_DIR      state dir override.
#   NEXUS_HARNESS_DIR    directory of harness adapters.
#   NEXUS_PASTE_BIN      paste-followup binary (generic-tmux adapter).
#
# Exit (SKILL §5): 0 delivered | 3 unknown (chain halted) | 4 established
# non-delivery | 1 refused (usage, no window, unstampable ledger) | 2 internal.
# --ledger-coverage: 0 complete over the declared transports | 3 a declared
# transport escapes the ledger. --list: 0 records printed | 1 none.
#
# WHICH LEDGER (your-org/nexus-code#1368). The state dir is the PRIMARY nexus's,
# resolved by `monitor/_nexus-root.sh` — the one resolver `ng`, `upload-asset.sh`
# and `watcher-supervise-tick.sh` already share — from $NEXUS_ROOT, else this
# script's own parent, de-nested out of any `<primary>/work/<clone>/` it sits
# under. This file used to end its resolver at `$_sd/.state`, i.e. the CLONE's
# own state dir when run from a secondary clone: the stamp SUCCEEDED, `die`
# never fired, the delivery went out, and the primary's ledger — the one the
# watcher and every auditor read — had no row. A fail-loud stamp into the wrong
# ledger is a silent failure of the ledger. The resolved primary is EXPORTED as
# NEXUS_ROOT to the adapter and its children, because the shipped shell
# transport execs paste-followup.sh (stamps=self), which resolves a state dir
# of its own: one resolution per send, not one per process.
#
# THE TWO VERDICT CODES DO NOT SHARE A SCOPE — read this before trusting either.
#   rc 4 is MESSAGE-scoped: the transport that carried THIS nonce is provably
#        unreachable.
#   rc 0 is WINDOW-scoped:  the receipt surface (<state>/user-prompt/<window>)
#        holds ONE epoch per WINDOW, so ANY submission after your send satisfies
#        it. Two outstanding nonces on one window plus ONE submit ⇒ BOTH report
#        `delivered`. Measured. Read rc 0 as "this window submitted something
#        after your send", NOT as "your message arrived".
# Structural, not incidental: the nonce is not injected into the payload (SKILL
# §4), so the receipt genuinely cannot tell two messages apart. It fails SAFE
# for the hazard this tool exists to prevent — rc 0 STOPS a fallback, so it
# cannot double-deliver — but it CAN hide a lost message. A harness needing
# per-message confirmation from THAT surface must carry an id the receiver echoes.
#
# THERE IS A SECOND RECEIPT, AND IT IS MESSAGE-SCOPED (your-org/nexus-code#1099).
# `--check` now also consults the CONTENT marker paste-followup.sh records in the
# sidecar (`digest=`, sha256 over the canonical bytes, written BEFORE the paste)
# against the receiver's own transcript, via `se_submission_with_digest`. Two
# consequences:
#   * the QUEUED path is answerable at all. A paste consumed out of the queue by
#     a running turn does NOT fire `UserPromptSubmit`, so the submit-stamp above
#     never arrives for it — `unknown` was TERMINAL, not transient, for the most
#     common non-trivial case. The digest surface reads the `queue-operation`
#     /`enqueue` record that path DOES produce.
#   * when it fires, rc 0 means "THESE bytes are in a delivery record", not
#     "this window submitted something". Consulted FIRST for that reason.
# Neither surface can raise rc 4: a digest `no` is bounded-scan evidence, never a
# proven-unreachable carrier. The exclusivity rule is untouched.
#
# THE VERDICT AND ITS QUALIFIER SHARE A STREAM (your-org/nexus-code#1287). Both
# rc-0 arms print the §5 verdict token `delivered`, and both now carry a
# machine-readable qualifier ON STDOUT, beside it:
#
#   delivered [receipt=content-digest scope=message content=yes]
#   delivered [receipt=submit-stamp   scope=window  content=no|unknown|none|unavailable]
#
#   receipt=  which surface answered
#   scope=    what that surface can speak for (message vs window)
#   content=  what the MESSAGE-scoped surface said. Total over the verdict
#             space: yes|no|unknown from se_submission_with_digest, `none` when
#             the send recorded no digest at all (every transport but
#             tmux-paste), `unavailable` when the helper could not be loaded.
#
# Before this, the weaker arm printed a bare `delivered` on stdout while the
# contradicting caution went out through say() — i.e. STDERR. `out=$(ng send …
# --check)` captures stdout ALONE, so that caller got one line, `delivered`,
# for a message that had never arrived; and the two rc-0 arms were
# distinguishable only by prose. rc is unchanged and deliberately so: §5 pins
# `delivered` <-> rc 0 and §5.1 declares this case rc 0 on purpose, because rc
# 0'"'"'s licence ("stop; do not fall back") is correct under either reading. The
# stderr caution is RETAINED alongside, per §5.1.

set -uo pipefail

_sd=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Caller tokens reach stderr EXCERPTED, never whole (your-org/nexus-code#858 C,
# #906). An unknown-option diagnostic that echoes a 900-byte argument swamps the
# message it was meant to carry, and a `| tail -1` capture downstream then reads
# the residue as a plausible value. Byte-capped, trimmed on a CHARACTER boundary
# so a multi-byte character is never sliced into mojibake. Copied verbatim from
# monitor/ng rather than re-derived: test-ng-flag-order.sh D2 keys on a script
# DEFINING this helper, and a second, subtly different implementation is exactly
# the drift that check exists to catch.
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

die() { printf '%s\n' "$*" | sed 's/^/ng send: /' >&2; exit 1; }
say() { printf 'ng send: %s\n' "$*" >&2; }

RC_UNKNOWN=3; RC_NOT_DELIVERED=4

# ---- state dir: the PRIMARY's, by the repo's ONE resolver (#1368) ---------
# See "WHICH LEDGER" in the header. Fail-CLOSED on a missing resolver, as `ng`
# and `upload-asset.sh` do: without it the only alternative is the private
# script-relative arm, which is exactly the wrong-ledger path being removed.
if [[ -n "${NEXUS_STATE_DIR:-}" ]]; then
    STATE_DIR="$NEXUS_STATE_DIR"          # test seam; children inherit it too
else
    [[ -r "$_sd/_nexus-root.sh" ]] \
        || die "cannot read $_sd/_nexus-root.sh — the primary-root resolver is missing. Without it a send from a secondary clone stamps the CLONE's ledger and the primary's has no row (your-org/nexus-code#1368); refusing rather than guessing which ledger to stamp."
    # shellcheck source=monitor/_nexus-root.sh
    . "$_sd/_nexus-root.sh" || die "cannot source $_sd/_nexus-root.sh"
    _cand="${NEXUS_ROOT:-$_sd/..}"
    NEXUS_PRIMARY=$(nexus_primary_root "$_cand") \
        || die "cannot resolve a nexus root from '$_cand' (not a directory) — refusing to guess a state dir"
    # HANDED DOWN. paste-followup.sh (stamps=self) and the harness adapter each
    # resolve their own state dir with NEXUS_ROOT as their second arm; exporting
    # the de-nested answer makes every child agree with this file.
    export NEXUS_ROOT="$NEXUS_PRIMARY"
    STATE_DIR="$NEXUS_PRIMARY/monitor/.state"
fi

WINDOW=""; MSG_FILE=""; MSG_TEXT=""; NONCE=""; ONLY_TRANSPORT=""
STAMP_ONLY=0; CHECK=0; DRY=0; ADMIN=0; TIMEOUT=""
NONCE_GIVEN=0; LAST=0; LIST=0; COVERAGE=0
PASS=()
[[ $# -gt 0 ]] || { sed -n '/^# Usage:/,/^# Exit/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
WINDOW="$1"; shift
case "$WINDOW" in -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

_stuck() { printf 'ng send: option %s requires a value (argument loop made no progress)\n' "${1-}" >&2; exit 64; }
_prev=-1; while (( $# > 0 )); do (( $# != _prev )) || _stuck "$1"; _prev=$#
    case "$1" in
        --file)       MSG_FILE="${2:-}"; shift 2 || die "--file needs a path" ;;
        --message)    MSG_TEXT="${2:-}"; shift 2 || die "--message needs text" ;;
        --nonce)      NONCE="${2:-}"; NONCE_GIVEN=1; shift 2 || die "--nonce needs a value" ;;
        --last)       LAST=1; shift ;;
        --list)       LIST=1; shift ;;
        --ledger-coverage) COVERAGE=1; shift ;;
        --transport)  ONLY_TRANSPORT="${2:-}"; shift 2 || die "--transport needs a name" ;;
        --confirm-timeout) TIMEOUT="${2:-}"; shift 2 || die "--confirm-timeout needs seconds" ;;
        --stamp-only) STAMP_ONLY=1; shift ;;
        --check)      CHECK=1; shift ;;
        --dry-run)    DRY=1; shift ;;
        --administrative|--no-retask) ADMIN=1; PASS+=(--administrative); shift ;;
        --note)       PASS+=(--note "${2:-}");    shift 2 || die "--note needs text" ;;
        --issue)      PASS+=(--issue "${2:-}");   shift 2 || die "--issue needs a number" ;;
        --comment)    PASS+=(--comment "${2:-}"); shift 2 || die "--comment needs an id" ;;
        --help|-h)    sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $(_arg_excerpt "$1")" ;;
    esac
done
[[ -n "$TIMEOUT" ]] && PASS+=(--confirm-timeout "$TIMEOUT")

# ---- harness resolution: the NEXUS-owned descriptor, never ~/.claude -----
# skills/nexus.agent-delivery §6. Reading a harness's private registry to
# decide WHICH harness is running is circular; the nexus records it at spawn.
_harness_for_window() {
    # NOT one `local` statement: bash declares every name in a `local` FIRST
    # and assigns after, so a later assignment cannot reference an earlier
    # one — `local w="$1" d=".../$w.json"` expands $w while it is still
    # unset. Under `set -u` that aborts the function (caught by the suite);
    # WITHOUT `set -u` it silently yields `.../windows//x.json`. Measured
    # both ways on this host.
    local w="$1"
    local d="$STATE_DIR/windows/$w.json"
    local h=""
    if [[ -f "$d" ]] && command -v python3 >/dev/null 2>&1; then
        h=$(NEXUS_D="$d" python3 -c 'import json,os,sys
try: print(json.load(open(os.environ["NEXUS_D"])).get("harness") or "")
except Exception: pass' 2>/dev/null) || h=""
    fi
    # The PRIMARY's config, not the clone's (your-org/nexus-code#1428): NEXUS_ROOT
    # was exported as the de-nested primary above, so its config/load.sh is the
    # one that describes the board this send is for.
    local _cfg="${NEXUS_ROOT:-$_sd/..}/config/load.sh"
    if [[ -z "$h" && -x "$_cfg" ]]; then
        h=$("$_cfg" monitor.default_harness 2>/dev/null) || h=""
    fi
    # generic-tmux is the floor, not a guess: it assumes nothing about the
    # software in the pane, so an unknown harness degrades to "addressable,
    # receipt declared from what is actually there" (SKILL §7).
    [[ -n "$h" ]] || h="generic-tmux"
    printf '%s' "$h"
}
HARNESS=$(_harness_for_window "$WINDOW")
# Test seam (hermetic suite; NEVER set in production), same convention as
# paste-followup.sh's NEXUS_CC_HOME / PASTE_NG_BIN.
ADAPTER="${NEXUS_HARNESS_DIR:-$_sd/harness}/$HARNESS.sh"
[[ -x "$ADAPTER" ]] || die "no adapter for harness '$HARNESS' (looked for $ADAPTER). Implement it per skills/nexus.agent-delivery §8, or fix the descriptor."

# ---- nonce ---------------------------------------------------------------
# Recorded in the epoch-keyed sidecar (NOT a new TSV column: the ledger's
# compaction rebuilds rows as exactly four columns, _idle_probe.sh:1964-1967,
# so a 5th would vanish past 200 lines — #683's hazard, #676's remedy).
# Defence in depth and an audit key; the EXCLUSIVITY RULE is the real defence,
# because receiver-side dedupe needs receiver cooperation a foreign harness
# may not offer.
if [[ -z "$NONCE" ]]; then
    NONCE=$( (head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n') 2>/dev/null ) || NONCE=""
    [[ -n "$NONCE" ]] || NONCE="ts$(date +%s%6N 2>/dev/null || date +%s)"
fi

_epoch_key() { local e; e=$(date +%s%6N 2>/dev/null); [[ "$e" =~ ^[0-9]{16,}$ ]] || e=$(( $(date +%s) * 1000000 )); printf '%s' "$e"; }

# ---- the receipt (SKILL §2) ---------------------------------------------
# `submit-stamp`: <state>/user-prompt/<window> = epoch<TAB>session-id, written
# by a NEXUS-installed hook (spawn-worker.sh:21), NOT by Claude Code — which is
# why it is the standard's receipt and why a new harness inherits confirmation
# by emitting one file. Compared on the EPOCH alone: the second column is a
# session id, whose format is a harness's business, so keying on it here would
# smuggle a harness assumption into the contract.
_submit_stamp_epoch() {
    local f="$STATE_DIR/user-prompt/$WINDOW" e
    [[ -f "$f" ]] || return 1
    e=$(head -1 "$f" 2>/dev/null | cut -f1) || return 1
    [[ "$e" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$e"
}

# ---- the common stamp (SKILL §3) ----------------------------------------
# COLUMN 3 IS OWNED HERE AND IS THE LITERAL GUARD KEY. No adapter, no flag, no
# caller may change it. Historical name; read it as "machine-injected input,
# subject to the delivery guard".
GUARD_KEY="paste-followup"
_stamp_ledger() {
    local epoch="$1" transport="$2" admin_col=""
    (( ADMIN )) && admin_col="admin"
    mkdir -p "$STATE_DIR" 2>/dev/null
    # STAMP BEFORE SEND, AND DIE IF IT FAILS (#665 / SKILL §3). The asymmetry
    # is the reason: stamp→send fails LOUD (a stamped epoch whose submission
    # never confirms is exactly what paste-unconfirmed catches — a recoverable
    # false positive); send→stamp fails SILENT, leaving unstamped input the
    # watcher may sample. Order any two-part operation so the failure mode is
    # the observable one.
    printf '%s\t%s\t%s\t%s\n' "$WINDOW" "$epoch" "$GUARD_KEY" "$admin_col" \
        >> "$STATE_DIR/machine-input.tsv" \
        || die "cannot stamp $STATE_DIR/machine-input.tsv — refusing to send unstamped (the watcher would misattribute the input to the operator)"
    local dir="$STATE_DIR/paste-verdicts" tmp
    mkdir -p "$dir" 2>/dev/null || return 0
    tmp="$dir/.$WINDOW.$epoch.$$"
    { printf 'window=%s\nepoch=%s\nnonce=%s\ntransport=%s\n' \
        "$WINDOW" "$epoch" "$NONCE" "$transport"; } > "$tmp" 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null; return 0; }
    mv -f "$tmp" "$dir/$WINDOW.$epoch" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    return 0
}

# Find the epoch we stamped for a nonce (for --check).
_epoch_for_nonce() {
    local dir="$STATE_DIR/paste-verdicts" f best=0 e
    for f in "$dir/$WINDOW."*; do
        [[ -f "$f" ]] || continue
        grep -qxF "nonce=$NONCE" "$f" 2>/dev/null || continue
        e=$(awk -F= '$1=="epoch"{print $2; exit}' "$f" 2>/dev/null)
        [[ "$e" =~ ^[0-9]+$ ]] && (( e > best )) && best=$e
    done
    (( best > 0 )) || return 1
    printf '%s' "$best"
}

# ---- the sidecar READER (your-org/nexus-code#1367) -----------------------
# The sidecar has had a WRITER since #1049 and no reader for a caller: the nonce
# a `--check` needs was on stdout alone, and stdout is the stream a loop or a
# verdict-line `grep` discards. With no nonce there was no way to resolve an
# UNKNOWN, and the path of least resistance from "I cannot check" was "send
# again" — the exact move the EXCLUSIVITY RULE forbids, performed by the rule's
# own author within the hour. This reads the records back by (window, epoch).
# `<window>.<epoch>` only: `.scan` siblings (_idle_probe.sh) and another window
# sharing the prefix (`w` vs `w.x`) are excluded by requiring an all-digit tail.
_sidecar_records() {   # -> "<epoch>\t<nonce|->\t<transport|->\t<outcome|->", newest first
    local dir="$STATE_DIR/paste-verdicts" f tail n t o
    for f in "$dir/$WINDOW."*; do
        [[ -f "$f" ]] || continue
        tail="${f##*/}"; tail="${tail#"$WINDOW".}"
        [[ "$tail" =~ ^[0-9]+$ ]] || continue
        n=$(sed -n 's/^nonce=//p' "$f" 2>/dev/null | sed -n '1p')
        t=$(sed -n 's/^transport=//p' "$f" 2>/dev/null | sed -n '1p')
        o=$(sed -n 's/^outcome=//p' "$f" 2>/dev/null | sed -n '1p')
        printf '%s\t%s\t%s\t%s\n' "$tail" "${n:--}" "${t:--}" "${o:--}"
    done | sort -t "$(printf '\t')" -k1,1nr
}
_iso_of_epoch() {   # <micros> -> UTC ISO-8601, or `?`
    local s=$(( ${1:-0} / 1000000 ))
    date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '?'
}

# ---- transports ----------------------------------------------------------
TRANSPORTS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && TRANSPORTS+=("$line")
done < <("$ADAPTER" transports "$WINDOW" 2>/dev/null)
(( ${#TRANSPORTS[@]} )) || die "harness '$HARNESS' declared no transports for window $WINDOW"

if (( LIST )); then
    _n=0
    while IFS=$'\t' read -r _e _nn _t _o; do
        printf 'epoch=%s time=%s nonce=%s transport=%s outcome=%s\n' \
            "$_e" "$(_iso_of_epoch "$_e")" "$_nn" "$_t" "$_o"
        _n=$(( _n + 1 ))
    done < <(_sidecar_records)
    if (( _n == 0 )); then
        say "no send records for window $WINDOW in $STATE_DIR/paste-verdicts (records are dropped when the window is retired and swept after ~7 days)"
        exit 1
    fi
    exit 0
fi

# ---- --ledger-coverage: can this ledger's SILENCE be read? (#1368) --------
# A COVERAGE GAP IS A PROPERTY OF THE WINDOW'S DECLARED TRANSPORTS, NOT OF ANY
# ROW, so it is answered here — by the ledger's writer, from the same descriptor
# every send reads — rather than stored beside the rows. A stored copy would be
# a second source that goes stale the moment a descriptor changes, and a new
# per-window file under the state dir is an UNMANIFESTED surface to
# `bk_state_refs_unmanifested` at every retirement. The ledger could not name
# its gap before; an auditor counting rows for a window read 8 deliveries
# against 7 rows and nearly published "the correction never propagated".
if (( COVERAGE )); then
    printf 'window=%s harness=%s ledger=%s/machine-input.tsv\n' "$WINDOW" "$HARNESS" "$STATE_DIR"
    _gap=""
    for t in "${TRANSPORTS[@]}"; do
        IFS=$'\t' read -r n inv rcp stm <<<"$t"
        if [[ "$inv" == "shell" ]]; then
            printf '  %-16s invoke=%-6s row=yes (stamped by %s, before a byte goes out)\n' "$n" "$inv" "${stm:-caller}"
        else
            printf '  %-16s invoke=%-6s row=NO-ROW unless the sending agent ran --stamp-only first\n' "$n" "$inv"
            _gap="${_gap:+$_gap,}$n"
        fi
    done
    if [[ -n "$_gap" ]]; then
        printf 'ledger-complete=no — a delivery to %s through %s (invoke=agent) leaves NO ROW in this ledger, so a MISSING ROW IS NOT EVIDENCE that nothing was sent; the receiver'"'"'s own transcript is the only record of such a send (your-org/nexus-code#1368, skills/nexus.agent-delivery §3).\n' "$WINDOW" "$_gap"
        exit $RC_UNKNOWN
    fi
    printf 'ledger-complete=yes — every transport declared for %s is shell-invocable and stamps a row before sending; over the DECLARED transports this ledger'"'"'s silence about %s is evidence of no send (a hand-typed tmux send-keys is outside every declaration and outside this claim).\n' "$WINDOW" "$WINDOW"
    exit 0
fi

if (( DRY )); then
    printf 'window=%s harness=%s nonce=%s\n' "$WINDOW" "$HARNESS" "$NONCE"
    for t in "${TRANSPORTS[@]}"; do
        IFS=$'\t' read -r n inv rcp stm <<<"$t"
        printf '  %-16s invoke=%-6s receipt=%-13s stamps=%-7s' "$n" "$inv" "$rcp" "${stm:-caller}"
        "$ADAPTER" liveness "$WINDOW" "$n" >/dev/null 2>&1
        case $? in 0) printf 'liveness=live\n' ;; 1) printf 'liveness=PROVEN-DEAD\n' ;; *) printf 'liveness=unknown\n' ;; esac
    done
    exit 0
fi

# ---- --check: poll for a receipt on an already-stamped send --------------
if (( CHECK )); then
    # `NONCE` is never empty here — an auto-generated one was minted above for
    # the send path — so the old `[[ -n "$NONCE" ]]` guard was dead code and a
    # bare `--check` died with "no stamped send found for nonce <random>".
    # Decide on what the CALLER gave.
    if (( LAST )); then
        (( NONCE_GIVEN )) && die "--last and --nonce are mutually exclusive: --last READS the nonce back from the newest ng-send record; --nonce names one"
        _pick=$(_sidecar_records | awk -F'\t' '$2 != "-" && !done { print; done = 1 }')
        [[ -n "$_pick" ]] || die "no ng-send record (one carrying nonce=) for window $WINDOW in $STATE_DIR/paste-verdicts — 'ng send $WINDOW --list' shows every record; a direct paste-followup.sh paste carries no nonce and cannot be checked by nonce"
        IFS=$'\t' read -r _pe NONCE _pt _po <<<"$_pick"
        say "--last resolved to the newest ng-send record for $WINDOW: epoch=$_pe ($(_iso_of_epoch "$_pe")) nonce=$NONCE transport=$_pt"
        _newest=$(_sidecar_records | awk -F'\t' 'NR == 1 { print $1 }')
        [[ "$_newest" == "$_pe" ]] \
            || say "note: a NEWER record with no nonce exists (epoch=$_newest, $(_iso_of_epoch "$_newest") — a direct paste-followup.sh paste). --last answers about the newest ng SEND, not the newest paste."
    elif (( ! NONCE_GIVEN )); then
        die "--check needs --nonce <hex> (printed by the send) or --last (reads the newest ng-send record back from the sidecar; use --list to see them all)"
    fi
    st=$(_epoch_for_nonce) || die "no stamped send found for nonce $NONCE on window $WINDOW ('ng send $WINDOW --list' shows what is recorded)"
    st_s=$(( st / 1000000 ))
    _sidecar="$STATE_DIR/paste-verdicts/$WINDOW.$st"

    # ---- THE QUEUED PATH HAS NO SUBMIT-STAMP, EVER (your-org/nexus-code#1099)
    #
    # `_submit_stamp_epoch` reads <state>/user-prompt/<window>, written by the
    # receiver's `UserPromptSubmit` hook. MEASURED: a paste consumed out of the
    # QUEUE by an already-running turn does not fire that hook. On two
    # independent sends the same hour — `devred-sk` nonce e39b443a…, sent
    # 23:40:57, and `harness-sk` nonce eff1d051…, sent 23:48:41 — the stamp
    # still read each window's SPAWN time and the file had never been
    # rewritten, while `devred-sk`'s own report quoted the message back. So for
    # the single most common non-trivial case, `unknown` was not a transient
    # state on the way to an answer: it was TERMINAL, and the "re-check"
    # instruction named a loop that could never exit on success.
    #
    # The receipt asserted a PROXY (a hook fired) for the PROPERTY (the bytes
    # reached the agent). The proxy is sound on the path it was designed
    # against — an IDLE receiver — and silently absent on the path that
    # happens when the board is busy.
    #
    # THE PROPERTY IS ALREADY COMPUTED IN THIS REPO, so this reuses it rather
    # than inventing a second answer: paste-followup.sh records `digest=`
    # (sha256 over the canonical bytes) in this same sidecar BEFORE pasting,
    # and monitor/_submit_evidence.sh's `se_submission_with_digest` matches it
    # against the receiver's own transcript. That selector already scans BOTH
    # delivery spellings — a `type:"user"` TUI submission AND a
    # `queue-operation`/`enqueue` — and `enqueue` is exactly the record the
    # queued path produces. The measured transcript held the bytes 3×, so the
    # predicate counts >= 1 and never exactly 1; that is the shipped selector's
    # behaviour, not something re-derived here.
    #
    # THE FALSE POSITIVE THIS CAN PRODUCE, AND WHY IT IS ACCEPTABLE HERE.
    # `_SE_JQ_ENQUEUE_SELECT` matches arrival, not consumption. A paste that
    # was delivered and then CANCELLED out of the queue therefore reads as
    # delivered. That boundary is declared where the selector lives and is not
    # new; the discriminator does not exist in the measured record set, because
    # `queue-operation`/`remove` fires for consumption AND cancellation alike,
    # and no `type:"user"` record is written when a queued message is consumed.
    # Inventing one would be guessing.
    #
    # What makes it acceptable HERE is the licence, not the likelihood:
    # **rc 0 and rc 3 license the SAME action — neither permits a fallback.**
    # Only rc 4 does, and no digest verdict can produce rc 4 (see below). So a
    # digest false positive cannot cause the double delivery this whole
    # contract exists to prevent; its entire cost is that an orchestrator stops
    # polling a message somebody deliberately cancelled — and the party that
    # cancelled it is the one who knows. Against that, the status quo is a
    # PERMANENT `unknown` for every queued send.
    #
    # A digest `no` DOES NOT LICENSE rc 4, and that is deliberate. `no` means
    # "these bytes are in no delivery record over the scanned range" — which is
    # consistent with a paste sitting unsent in the input box AND with reading
    # the wrong transcript. rc 4 is reserved for a carrier PROVEN unreachable.
    # Weakening that is #1049's failure, and #1099 explicitly does not ask for
    # it. `no` only sharpens the rc-3 diagnostic.
    _sc_field() {   # <name> -> the value after the FIRST '=', empty when absent
        # NOT `awk -F=`: `outcome=` values contain '=' and ':' inside prose, so
        # a field split would truncate them. Anchored, first match wins.
        [[ -r "$_sidecar" ]] || return 0
        sed -n "s/^$1=//p" "$_sidecar" 2>/dev/null | sed -n '1p'
    }
    _digest=$(_sc_field digest)
    _outcome=$(_sc_field outcome)
    _content_verdict=""
    if [[ "$_digest" =~ ^[0-9a-f]{64}$ ]]; then
        if [[ -r "$_sd/_submit_evidence.sh" ]]; then
            # shellcheck source=monitor/_submit_evidence.sh
            . "$_sd/_submit_evidence.sh"
        fi
        if declare -F se_submission_with_digest >/dev/null 2>&1; then
            _content_verdict=$(se_submission_with_digest \
                "$WINDOW" "$STATE_DIR" "$st_s" "$_digest") || _content_verdict=""
        fi
    fi

    # THE VERDICT AND ITS QUALIFIER MUST SHARE A STREAM (your-org/nexus-code#1287).
    #
    # Both rc-0 arms below print the SKILL §5 verdict token `delivered`, and
    # until #1287 they were distinguishable only by prose — while the evidence
    # that CONTRADICTS the weaker one went out through say(), i.e. STDERR.
    # `out=$(ng send … --check)` is the natural way to capture a verdict, and
    # command substitution captures stdout ALONE, so that caller received
    # exactly one line, `delivered`, with the contradiction on a stream it
    # never read. Reported from a live send into a still-booting window: the
    # window-scoped stamp advanced on the SPAWNED AGENT'"'"'S OWN prompt
    # submission, which is guaranteed to happen in that interval — so the false
    # positive is MOST reliable exactly when it is least visible.
    #
    # WHAT IS AND IS NOT CHANGED HERE, because the contract constrains this
    # tightly and the temptation is to "fix" the rc:
    #   * rc STAYS 0. SKILL §5 pins verdict `delivered` <-> rc 0, and §5.1
    #     already declares THIS case rc 0 on purpose — rc 0'"'"'s licence ("stop;
    #     do not fall back") is correct under either reading. A NEW rc would
    #     drop every `(( rc == 0 ))` caller into an else branch whose behaviour
    #     is unknown and might license the double delivery this whole contract
    #     exists to prevent. Widening the rc vocabulary is a SKILL change, not
    #     a send.sh change.
    #   * the DISCRIMINATOR moves onto stdout, machine-readable, on BOTH arms.
    #     Symmetry is the point: a caller could not previously tell a
    #     MESSAGE-scoped rc 0 from a WINDOW-scoped one without matching prose.
    #
    # `receipt=` names the surface that answered, `scope=` what that surface can
    # speak for, `content=` what the message-scoped surface said. The stderr
    # say() below is deliberately left intact and overlaps this text: stdout
    # must stand alone for a caller that discarded stderr, and stderr must stand
    # alone for the human reading a terminal.
    case "$_content_verdict" in
        yes|no|unknown) _content_field="$_content_verdict" ;;
        *) if [[ -n "$_digest" ]]; then _content_field=unavailable   # helper missing
           else                         _content_field=none          # no digest recorded
           fi ;;
    esac

    # THE CONTENT RECEIPT IS MESSAGE-SCOPED; the submit-stamp is WINDOW-scoped
    # (see the header). So it is asked FIRST: a `yes` here answers the question
    # the caller actually asked, rather than "this window submitted something".
    if [[ "$_content_verdict" == "yes" ]]; then
        printf 'ng send: delivered [receipt=content-digest scope=message content=yes] — the exact bytes of nonce %s appear in a delivery record in %s'"'"'s own transcript (content receipt, MESSAGE-scoped; digest %s).\n' \
            "$NONCE" "$WINDOW" "${_digest:0:12}…"
        exit 0
    fi

    now=$(_submit_stamp_epoch) || now=""
    if [[ -n "$now" ]] && (( now > st_s )); then
        # The stamp is WINDOW-scoped: ANY submission after the send satisfies
        # it, so it cannot tell two outstanding nonces apart. When the
        # message-scoped surface DISAGREES, the headline itself must carry that
        # — a bare `delivered` on stdout is a verdict stronger than what was
        # established, which SKILL §5 forbids in as many words.
        if [[ "$_content_verdict" == "no" ]]; then
            printf 'ng send: delivered [receipt=submit-stamp scope=window content=no] — submit-stamp advanced past the send (nonce %s), but the content receipt for THIS message found its exact bytes in NO delivery record over the scanned range: the submission that advanced the stamp may have been a different message. rc 0 still forbids a fallback; VERIFY before treating nonce %s as acted upon.\n' \
                "$NONCE" "$NONCE"
        else
            printf 'ng send: delivered [receipt=submit-stamp scope=window content=%s] — submit-stamp advanced past the send (nonce %s). WINDOW-scoped: any submission after the send satisfies it.\n' \
                "$_content_field" "$NONCE"
        fi
        # Retained verbatim: SKILL §5.1 states this case "says so on stderr",
        # and a human reading a terminal should not have to parse a field list.
        if [[ "$_content_verdict" == "no" ]]; then
            say "CAUTION — that receipt is WINDOW-scoped. The content receipt for THIS message found its exact bytes in no delivery record over the scanned range, so the submission that advanced the stamp may have been a different message. Verify before treating nonce $NONCE as acted upon."
        fi
        exit 0
    fi
    # PROBE THE TRANSPORT THAT CARRIED THIS MESSAGE — NOT "the transports".
    #
    # This loop used to iterate every DECLARED transport and exit 4 on the first
    # provably-dead one, regardless of which had carried the send. `_stamp_ledger`
    # records `transport=` in the sidecar and this read it back as nothing. So a
    # peer whose `tmux-paste` is dead while its `cc-sendmessage` carrier is ALIVE
    # got "A fallback is licensed" — a FALSE ESTABLISHED NEGATIVE, and the caller
    # sent a second copy while the first was still in flight. Reproduced
    # end-to-end against a real live socket and real tmux by the #1049 skeptic.
    #
    # The exclusivity rule was never wrong and was never breached on the send
    # path. The hazard came through a DIFFERENT DOOR: a helper answering a
    # question about "transports" when the question that matters is about THE
    # transport that carried THIS message. A guard scoped to the wrong noun is
    # not a weaker guard — it is a guard on something else.
    #
    # FAIL CLOSED when the carrier was not recorded: report `unknown`, never
    # re-open the all-probe path. An unrecorded carrier is "I cannot tell which
    # transport to ask", and that is precisely not an established negative.
    _recorded=$(awk -F= '$1=="transport"{print $2; exit}' \
                "$STATE_DIR/paste-verdicts/$WINDOW.$st" 2>/dev/null) || _recorded=""
    _carrier="$_recorded"
    # An explicit --transport may only ever NAME the carrier, never REPLACE it.
    # Letting a caller point --check at a transport that did not carry the send
    # is the same defect one door along: the answer would be about the wrong
    # noun again, just chosen by hand instead of by a loop. Refuse the mismatch.
    if [[ -n "$ONLY_TRANSPORT" ]]; then
        # NO CARRIER RECORDED + a caller-named transport ⇒ still `unknown`. The
        # refusal below covers DISAGREEMENT; this covers UNVERIFIED ASSERTION,
        # which is the same defect with nothing to disagree with. Without it a
        # caller could name any declared transport and, if that transport were
        # dead, get rc 4 with a diagnostic asserting `the CARRYING transport
        # <x>` — about a transport nothing established had carried anything.
        # `--transport` is a caller's claim; it is not evidence.
        if [[ -z "$_recorded" ]]; then
            say "unknown — no carrier is recorded for nonce $NONCE, so --transport $ONLY_TRANSPORT is a caller's assertion rather than evidence that it carried the send. Not concluding; do NOT fall back."
            exit $RC_UNKNOWN
        fi
        if [[ "$ONLY_TRANSPORT" != "$_recorded" ]]; then
            die "--transport $ONLY_TRANSPORT does not match the transport recorded for nonce $NONCE ($_recorded). --check answers about the transport that CARRIED the send; it cannot be pointed at another one."
        fi
        _carrier="$ONLY_TRANSPORT"
    fi
    # WHY THE `unknown` IS UNKNOWN — composed once, appended to every rc-3 exit
    # below. Before #1099 the message said "re-check" and named no reason, so a
    # permanent `unknown` and a slow one read identically and the caller had no
    # basis for choosing between spinning, escalating and (worst) re-sending.
    _why=""
    case "$_content_verdict" in
        no)      _why=" The content receipt was consulted and answered NO: the exact bytes are in no delivery record over the scanned range. That is NOT an established non-delivery (the scan is bounded and the transcript may not be the one that matters), so it does not license a fallback — but it is the shape a lost paste takes, and re-checking is unlikely to change it." ;;
        unknown) _why=" The content receipt could not be put (no jq/base64/hasher, no session-id or transcript for this window, or the transcript exceeds the scan bound), so neither surface has an answer." ;;
        yes)     _why="" ;;
        *)
            if [[ -n "$_digest" ]]; then
                _why=" No content receipt was consulted: monitor/_submit_evidence.sh is unavailable to this send."
            else
                _why=" This send recorded no content marker (digest=), so only the submit-stamp surface exists for it — every transport but tmux-paste is in that position."
            fi ;;
    esac
    # THE TERMINAL CASE, NAMED. `outcome=pasted (submission unconfirmed …
    # plausibly QUEUED …)` means the bytes went into a pane whose turn was
    # already running. The receiver consumes such a paste out of the QUEUE,
    # which does not fire `UserPromptSubmit` — so the submit-stamp surface will
    # NEVER answer for this send, no matter how long anyone polls it.
    case "$_outcome" in
        *QUEUED*|*queued*)
            _why="${_why} NOTE: this send was recorded as \`${_outcome}\`. A paste consumed out of the queue by a running turn does not fire UserPromptSubmit, so NO submit-stamp will ever arrive for it (your-org/nexus-code#1099) — polling that surface cannot terminate. The content receipt above is the only surface that can answer, and re-checking helps only while it reads \`unknown\`." ;;
    esac

    if [[ -z "$_carrier" ]]; then
        say "unknown — no receipt yet, and the sidecar does not record which transport carried nonce $NONCE, so non-delivery cannot be established for any of them. Do NOT fall back.${_why}"
        exit $RC_UNKNOWN
    fi
    "$ADAPTER" liveness "$WINDOW" "$_carrier" >/dev/null 2>&1
    if (( $? == 1 )); then
        say "not-delivered — the CARRYING transport $_carrier is PROVABLY unreachable and no receipt landed (nonce $NONCE). A fallback is licensed."
        exit $RC_NOT_DELIVERED
    fi
    say "unknown — no receipt yet and non-delivery is NOT established for the carrying transport $_carrier (nonce $NONCE). Do NOT fall back.${_why}"
    exit $RC_UNKNOWN
fi

# ---- payload -------------------------------------------------------------
[[ -n "$MSG_FILE" && -n "$MSG_TEXT" ]] && die "--file and --message are mutually exclusive"
PAYLOAD=""; TMP_PAYLOAD=""
if [[ -n "$MSG_FILE" ]]; then
    [[ -r "$MSG_FILE" ]] || die "cannot read --file: $MSG_FILE"
    PAYLOAD="$MSG_FILE"
else
    TMP_PAYLOAD=$(mktemp "${TMPDIR:-/tmp}/ngsend.XXXXXX") || die "mktemp failed"
    if [[ -n "$MSG_TEXT" ]]; then printf '%s' "$MSG_TEXT" > "$TMP_PAYLOAD"
    else cat > "$TMP_PAYLOAD"; fi
    PAYLOAD="$TMP_PAYLOAD"
fi
trap '[[ -n "$TMP_PAYLOAD" ]] && rm -f "$TMP_PAYLOAD"' EXIT
[[ -s "$PAYLOAD" ]] || die "refusing to send an empty message"

# ---- --stamp-only: the supported path for an invoke=agent transport ------
if (( STAMP_ONLY )); then
    [[ -n "$ONLY_TRANSPORT" ]] || die "--stamp-only needs --transport <name> (the transport you are about to perform yourself)"
    # The transport must be one this harness actually DECLARES. Stamping for a
    # transport that does not exist writes a sidecar `--check` can never match,
    # so the send would sit `unknown` forever — an absent confirmation that
    # looks like a slow one. Fail closed at the call site instead.
    _declared=0
    for _t in "${TRANSPORTS[@]}"; do
        IFS=$'\t' read -r _n _ _ _ <<<"$_t"
        [[ "$_n" == "$ONLY_TRANSPORT" ]] && _declared=1
    done
    (( _declared )) || die "harness '$HARNESS' does not declare transport '$ONLY_TRANSPORT' for $WINDOW (declared: $(printf '%s\n' "${TRANSPORTS[@]}" | cut -f1 | tr '\n' ' '))"
    ep=$(_epoch_key)
    _stamp_ledger "$ep" "$ONLY_TRANSPORT"
    printf 'ng send: STAMPED ONLY — nothing was sent.\n' >&2
    printf 'ng send: now perform %s yourself, then: ng send %s --check --nonce %s   (or --check --last if the nonce is lost)\n' "$ONLY_TRANSPORT" "$WINDOW" "$NONCE" >&2
    printf 'ng send:   that --check answers about %s specifically (0 delivered | 3 unknown, do NOT fall back | 4 %s provably unreachable, fallback licensed)\n' "$ONLY_TRANSPORT" "$ONLY_TRANSPORT" >&2
    printf 'nonce=%s\nepoch=%s\n' "$NONCE" "$ep"
    exit 0
fi

# ---- the chain -----------------------------------------------------------
FINAL=$RC_UNKNOWN; ATTEMPTED=0
for t in "${TRANSPORTS[@]}"; do
    IFS=$'\t' read -r name invoke receipt stamps <<<"$t"
    [[ -n "$ONLY_TRANSPORT" && "$name" != "$ONLY_TRANSPORT" ]] && continue
    if [[ "$invoke" != "shell" ]]; then
        # NOT a failure and NOT a delivery — say exactly that. A silent skip
        # here would let the caller read the chain's later success as though
        # the preferred transport had been tried.
        say "skip $name (invoke=$invoke — no shell caller can perform it; use --stamp-only, see skills/nexus.agent-delivery §2)"
        continue
    fi
    "$ADAPTER" liveness "$WINDOW" "$name" >/dev/null 2>&1; lv=$?
    if (( lv == 1 )); then
        say "skip $name — PROVABLY unreachable (established negative; advancing is licensed)"
        FINAL=$RC_NOT_DELIVERED
        continue
    fi
    ATTEMPTED=1
    # WHO STAMPS (SKILL §3). Declared by the transport, because the answer is
    # not uniform: `tmux-paste` runs paste-followup.sh, which stamps BEFORE its
    # own send and `die`s if that fails (#665) — stamping again here would put
    # TWO rows in an append-only ledger for ONE send, and the watcher takes the
    # max epoch per window, so the second row would move the attribution
    # instant off the moment the send actually began.
    #
    # Everything else declares `caller`, and then we MUST stamp — a transport
    # nobody stamps for is unstamped input, which is the whole hole this
    # closes. `caller` is therefore the DEFAULT: an adapter that declares
    # nothing gets stamped rather than silently exempted (fail-closed; a
    # missing field must never be the permissive arm).
    if [[ "${stamps:-caller}" != "self" ]]; then
        _stamp_ledger "$(_epoch_key)" "$name"
    fi
    say "attempting $name (receipt=$receipt, stamps=${stamps:-caller})"
    "$ADAPTER" send "$WINDOW" "$name" "$PAYLOAD" "$NONCE" "${PASS[@]+"${PASS[@]}"}"; rc=$?
    case $rc in
        0)
            # A TRANSPORT THAT DECLARED NO RECEIPT CANNOT ESTABLISH DELIVERY, and
            # its rc 0 means only "the send call returned". §5 says `delivered`
            # requires a receipt to have been OBSERVED and that this tool never
            # reports a verdict stronger than what it established; §7 says sends
            # to such an agent report `unknown`. This is where the implementation
            # is made to match the standard — not the other way round.
            #
            # `$receipt` used to be parsed and used ONLY in a diagnostic, so a
            # shell transport declaring `receipt: none` that returned 0 was
            # announced as `delivered`: a delivery claim with no evidence, which
            # is the exact failure class #1049 was opened for. Latent for the
            # shipped harness (a receipt-less generic-tmux send execs
            # paste-followup, which returns 3 when it cannot verify) and LIVE the
            # moment a second harness exists — i.e. with the first real use of
            # this contract.
            #
            # This does NOT penalise a deliberate fire-and-forget transport: §4
            # already states the cost out loud, that such a transport can never
            # license a fallback. The send still happened; only the CLAIM changes.
            if [[ "${receipt:-none}" == "none" ]]; then
                say "$name sent and returned 0, but it declares receipt=none — nothing was OBSERVED, so this is UNKNOWN, not delivered (nonce $NONCE). Do NOT re-send; re-check with: ng send $WINDOW --check --nonce $NONCE (or --check --last)"
                exit $RC_UNKNOWN
            fi
            printf 'ng send: delivered via %s (harness=%s, nonce=%s)\n' "$name" "$HARNESS" "$NONCE"; exit 0 ;;
        "$RC_NOT_DELIVERED")
            # ESTABLISHED negative — the only rc that licenses advancing.
            say "$name established NON-delivery — advancing to the next transport"
            FINAL=$RC_NOT_DELIVERED; continue ;;
        "$RC_UNKNOWN")
            # THE EXCLUSIVITY RULE. Halt. Falling back here is what produces a
            # double execution, which is strictly worse than not falling back.
            say "$name returned UNKNOWN — halting the chain (a fallback may only fire on a PROVEN negative). Do NOT re-send. Re-check with: ng send $WINDOW --check --nonce $NONCE — or, if this nonce was not captured, ng send $WINDOW --check --last — either answers about $name, the transport that carried this send"
            exit $RC_UNKNOWN ;;
        *) say "$name refused (rc=$rc) — treating as unknown, halting"; exit $RC_UNKNOWN ;;
    esac
done

if (( ! ATTEMPTED )) && (( FINAL == RC_UNKNOWN )); then
    die "no shell-invocable transport was available for window $WINDOW (harness=$HARNESS). Nothing was sent."
fi
if (( FINAL == RC_NOT_DELIVERED )); then
    say "NOT DELIVERED — every transport in the chain established a negative (nonce $NONCE)"
    exit $RC_NOT_DELIVERED
fi
exit $RC_UNKNOWN
