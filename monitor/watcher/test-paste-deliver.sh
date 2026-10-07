#!/usr/bin/env bash
# test-paste-deliver.sh — every paste path delivers CONFIRMED, or says it did
# not (your-org/nexus-code#1591, #1590).
#
# Run: bash monitor/watcher/test-paste-deliver.sh
#      SUBJECT_ROOT=<another checkout> bash monitor/watcher/test-paste-deliver.sh
# Expected: ALL TESTS PASSED, exit 0. Skips (77) without tmux or jq.
#
# WHAT IT DRIVES. The four production paste paths —
#
#   E  monitor/watcher/main.sh      _paste_to_target_unlocked   (the emit paste)
#   U  monitor/watcher/_unstick.sh  _paste_line_to_window
#   R  monitor/watcher/_respawn.sh  _respawn_paste_prompt_file
#   F  monitor/paste-followup.sh    (the script, end to end)
#
# — each against a REAL private tmux server whose pane runs a small fake REPL
# that reproduces, deterministically, what the real Claude Code 2.1.278 was
# MEASURED doing in the cc-harness at 17f1f926:
#
#   hold     a prompt carrying an invisible character is CLEANED and KEPT in
#            the input box on the first Enter, and sent on the second
#   stuck    Enter is ignored (a freshly --resume'd orchestrator, 2026-09-11)
#   blocked  Enter is ignored and the pane reads an overlay
#   busy     the prompt is QUEUED: a `queue-operation enqueue` record, no
#            `type:"user"` record (#665)
#
# Real tmux, because two of the defects live in tmux's own handling of the
# bytes: the command-list rule that eats a trailing `;` from a `set-buffer`
# DATA argument (#1590), and the bracketed-paste / Enter ordering.
#
# THE PROPERTY, for every caller:   reported delivered  ==>  the REPL recorded it
# The pre-fix emit paste breaks it in the manufactured-success direction: rc 0
# for a body the REPL is still holding, because a held body renders its
# trailer in the input box and the old check grepped the pane for that trailer.
#
# SUBJECT_ROOT points the DRIVERS at another tree (the pre-fix base, to show
# the reproduction) while the rig stays this file's. Rows that need the
# primitive itself report n/a on a tree that does not have one. Every
# assertion carries a STABLE ID in brackets so two runs can be compared as
# SETS (`comm`), never as totals.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$_script_dir/_test_helpers.sh"
# shellcheck source=./_tmux-fixture.sh
. "$_script_dir/_tmux-fixture.sh"
ROOT="${SUBJECT_ROOT:-$(cd "$_script_dir/../.." && pwd)}"
MON="$ROOT/monitor"
[[ -r "$MON/watcher/main.sh" ]] || { echo "SUBJECT_ROOT=$ROOT has no monitor/watcher/main.sh" >&2; exit 2; }
HAVE_PD=0; [[ -r "$MON/_paste-deliver.sh" ]] && HAVE_PD=1

# Counted through the shared LEDGER (`_th_pass` / `_th_fail`), so a FAIL raised
# inside a subshell still fails the suite (#805) and `th_summary_and_exit` can
# certify the total; the exact-count guard at the bottom makes a VANISHED
# assertion redden (#807). N/A rows are printed, never counted.
NA=0
pass() { printf '  PASS: [%s] %s\n' "$1" "$2"; _th_pass; }
fail() { printf '  FAIL: [%s] %s\n' "$1" "$2" >&2; _th_fail; }
na()   { printf '  N/A:  [%s] %s\n' "$1" "$2"; NA=$(( NA + 1 )); }

# THE ONE ENUMERATOR of "production shell files under monitor/" — used by the
# P-onesite / P-noargv rows below AND by gp_population, so the advertised
# population is the one actually walked (the protocol's one rule).
_pdt_prod_shell_files() {   # <repo-root>
    git -C "$1" ls-files -- monitor | command grep -E '\.sh$' | command grep -v '/test-\|/fixtures/'
}
# What this suite READS, for `ng guards-for-diff`: every production shell file
# under monitor/ (the one-site and no-argv rows scan them all), the client-less
# paste paths among them, the site manifest, and the fixture library. Always
# THIS repo — SUBJECT_ROOT only redirects the drivers.
_pdt_repo=$(cd "$_script_dir/../.." && pwd)
# shellcheck source=../_guard_population.sh
. "$_script_dir/../_guard_population.sh"
gp_population() {
    _pdt_prod_shell_files "$_pdt_repo"
    printf '%s\n' monitor/watcher/paste-buffer-sites.manifest monitor/watcher/_tmux-fixture.sh
}
gp_handle "$@"
eq()   { if [[ "$3" == "$4" ]]; then pass "$1" "$2"; else fail "$1" "$2 — got '$3' want '$4'"; fi; }

command -v tmux >/dev/null 2>&1 || { echo "skipped: tmux not on PATH"; exit 77; }
command -v jq   >/dev/null 2>&1 || { echo "skipped: jq not on PATH"; exit 77; }

WORK=$(mktemp -d)
SOCKS=()
cleanup() {
    local s
    for s in "${SOCKS[@]:-}"; do [[ -n "$s" ]] && env -u TMUX "$TMUX_BIN" -L "$s" kill-server 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT
TCONF="$WORK/tmux.conf"; th_tmux_fixture_conf "$TCONF"
# THE REAL BINARY, never `command -v tmux` (your-org/nexus-code#1105). Inside an
# agent pane a PATH lookup of tmux answers with monitor/tmuxwrap, and a planted
# shim that names a WRAPPER is skipped by the wrapper's own gate-3 — the -L pin
# is then lost and the client reaches the operator's board. The first cut of
# this suite did exactly that; test-tmux-shim-gate3-safety.sh caught it.
TMUX_BIN=$(nx_real_tmux_bin) || { echo "skipped: no real tmux binary resolvable (only PATH-front shims)"; exit 77; }
SID="11111111-2222-3333-4444-555555555555"

ZWSP=$'\xe2\x80\x8b'; SHY=$'\xc2\xad'

# ---- the fake REPL --------------------------------------------------------
# Raw-mode, byte-at-a-time. Requests bracketed paste, keeps an input box, and
# answers Enter according to $FC_DIR/mode. Everything it learns goes to files
# so the suite asserts on what the PANE RECEIVED, not on what a caller said.
cat > "$WORK/fakecc.sh" <<'FAKECC'
#!/usr/bin/env bash
export LC_ALL=C
D="$1"; T="$2"
stty raw -echo
box=""; inpaste=0; pend=""; enters=0; pastes=0; subs=0; syncs=0; cur=""
OPEN=$'\033[200~'; CLOSE=$'\033[201~'; ZW=$'\xe2\x80\x8b'; SH=$'\xc2\xad'
put() { printf '%s' "$2" > "$D/.$1.tmp" && mv -f "$D/.$1.tmp" "$D/$1"; }
state() {
    local m; m=$(cat "$D/mode" 2>/dev/null)
    if [[ "$m" == preblocked ]] || [[ "$m" == blocked && $enters -ge 1 ]]; then put pane-state "state=blocked active=0 overlay=permission"
    elif [[ "$m" == qmark && -n "$box" ]]; then put pane-state "state=user-typing active=0 input=?"
    # An OPERATOR DRAFT already in the box when the paste arrives
    # (your-org/nexus-code#1674): `draft` reads as typed text, `draftq` as the
    # undecidable `input=?`. `ghost` is an autosuggest over an EMPTY box.
    elif [[ "$m" == draftq && -n "$box" ]]; then put pane-state "state=user-typing active=0 input=?"
    # …and the same draft typed ahead into a MID-TURN worker, as a hook-fresh
    # pane now reports it (your-org/nexus-code#1683 F1): the state is the hook's
    # `busy`, the box is read off the capture. `busyblank` is its control: a
    # mid-turn pane whose box is EMPTY must still be pasted into.
    elif [[ "$m" == busydraft && -n "$box" ]]; then put pane-state "state=busy active=0 input=typed"
    elif [[ "$m" == busydraftq && -n "$box" ]]; then put pane-state "state=busy active=0 input=?"
    elif [[ "$m" == busyblank && -z "$box" ]]; then put pane-state "state=busy active=0 input=blank"
    elif [[ "$m" == ghost && -z "$box" ]]; then put pane-state "state=autosuggest-only active=0 input=ghost"
    # A box the READER misses (your-org/nexus-code#1604): the body sits in the box
    # and pane-state says idle/blank — the general shape of the measured 2.1.278
    # blank-first-line misread, keyed on the misread and not on how it arises
    # (the normaliser now drops leading blank lines, so that road is closed).
    elif [[ "$m" == misread ]]; then put pane-state "state=idle active=0 input=blank"
    # MEASURED on the real 2.1.278 (your-org/nexus-code#1597): the REPL KEEPS a
    # leading blank line, so the glyph row is empty and the text sits on the next
    # row — and production pane-state, which classifies from the glyph row alone,
    # reads that box as idle with a blank input. The fake says what the real
    # reader says, or a stranded blank-first payload would stay green here.
    elif [[ -n "$box" && "${box%%$'\n'*}" == "" ]]; then put pane-state "state=idle active=0 input=blank"
    elif [[ -n "$box" ]]; then put pane-state "state=user-typing active=0 input=typed"
    elif [[ -e "$D/busy" ]]; then put pane-state "state=busy active=0 queued=1"
    else put pane-state "state=idle active=0 input=blank"; fi
}
# THE INPUT ROW IS RENDERED AS CLAUDE CODE RENDERS IT, because the primitive's
# retry decision is an EQUALITY on it (pd_box_is_ours): the prompt glyph `❯`
# (e2 9d af), a no-break space (c2 a0), then the box's first line; further lines
# on following rows. The real binary COLLAPSES a paste of more than 2 newlines
# or more than 800 chars into `[Pasted text #N +K lines]` (K = its newline
# count) — which is every real emit — so the trailer is then NOT on the pane
# while the body is held. `collapse` modes reproduce that; `foreignpaste` shows
# a placeholder that is NOT ours (somebody else's paste, a different K).
ks=(); lens=()
show() {
    local m i out="" first rest="" collapsed=0; m=$(cat "$D/mode" 2>/dev/null)
    # THE BINARY'S OWN RULE AND SPELLING (2.1.278 `a4`/`BL`, read from the binary):
    # collapse when a paste is over 800 chars or has more than 2 line breaks;
    # `[Pasted text #N]` when it has NONE, `[Pasted text #N +K lines]` otherwise.
    # The first cut of this REPL printed `+0 lines`, which the binary never does,
    # and that is how a stranded long single-line payload stayed green (pastesk F9).
    for (( i = 0; i < ${#ks[@]}; i++ )); do (( ${lens[$i]} > 800 || ${ks[$i]} > 2 )) && collapsed=1; done
    if [[ "$m" == foreignpaste ]]; then out="[Pasted text #1 +99 lines]"
    elif (( collapsed )) && [[ -n "$box" ]]; then
        for (( i = 0; i < ${#ks[@]}; i++ )); do
            if (( ${ks[$i]} == 0 )); then out+="[Pasted text #$(( i + 1 ))]"
            else out+="[Pasted text #$(( i + 1 )) +${ks[$i]} lines]"; fi
        done
    else
        first="${box%%$'\n'*}"; out="$first"
        [[ "$box" == *$'\n'* ]] && rest="${box#*$'\n'}"
    fi
    printf '\r\n\342\235\257\302\240%s\r\n' "$out"
    [[ -n "$rest" ]] && printf '  %s\r\n' "${rest//$'\n'/$'\r\n'  }"
    # AN OPERATOR CONTINUATION ROW below our box content (your-org/nexus-code#1729):
    # shift+Enter after our chip or line, then text — an indented row under the
    # glyph row, which the next Enter would submit WITH ours. Drawn only; the
    # fake's own box does not carry it, so a submit records only our bytes and
    # the assertions key on the ENTER that must not be sent.
    case "$m" in *cont*) printf '  operator continuation text\r\n' ;; esac
    # …and the box's BOTTOM BORDER with a footer under it, as the real 2.1.273
    # draws it (fixtures/pasted-multiline-chip-realmodel-273.ansi): a full row of
    # U+2500, then hint text that is NOT input.
    case "$m" in *border*)
        printf '%s\r\n' "$(printf '\342\224\200%.0s' $(seq 1 60))"
        printf '  -- INSERT -- footer hint text\r\n' ;;
    esac
    return 0
}
record() {   # $1 = submission | enqueue
    subs=$(( subs + 1 )); printf '%s' "$box" > "$D/submitted.$subs.bin"
    if [[ "$1" == enqueue ]]; then
        printf '%s' "$box" | jq -Rsc '{type:"queue-operation",operation:"enqueue",timestamp:"2026-09-19T00:00:00.000Z",content:.}' >> "$T"
        : > "$D/busy"
    else
        printf '%s' "$box" | jq -Rsc '{type:"user",promptSource:"typed",timestamp:"2026-09-19T00:00:00.000Z",message:{role:"user",content:.}}' >> "$T"
    fi
    box=""; ks=(); lens=(); put subs "$subs"; printf '\r\nSUBMITTED\r\n'
    # …and the EMPTY input box is drawn again BELOW it, as the real binary does
    # (every real capture under fixtures/*realmodel*): the submitted prompt is now
    # HISTORY, above the last `❯` row. The emit fallback splits the pane at that
    # row (your-org/nexus-code#1604), so a REPL that never redrew the box would
    # make every real submit look like a body still sitting in it.
    show
}
enter() {
    enters=$(( enters + 1 )); put enters "$enters"
    local m; m=$(cat "$D/mode" 2>/dev/null)
    case "$m" in
        stuck|blocked|preblocked|qmark|foreignpaste|misread) : ;;
        pasteafter-fast)
            # Ours submits at once; 0.3 s later SOMEBODY ELSE pastes ONE LONG LINE,
            # which the binary shows as the COUNT-LESS `[Pasted text #1]` — the same
            # spelling any zero-break payload of OURS would have IF it collapsed.
            if (( enters == 1 )); then
                [[ -n "$box" ]] && record submission; state; sleep 0.3
                box=$(printf 'operator-paste-%.0s' $(seq 1 70)); ks=(0); lens=("${#box}"); show
            elif [[ -n "$box" ]]; then record submission; fi ;;
        collideafter-fast)
            # Ours submits at once; 0.3 s later an operator draft that shares NOTHING
            # with our line but its ASCII letters: both project to " OK" once every
            # byte >= 0x80 is dropped (your-org/nexus-code#1597).
            if (( enters == 1 )); then
                [[ -n "$box" ]] && record submission; state; sleep 0.3
                box=$'\xe3\x81\x93\xe3\x82\x8c\xe3\x81\xa7 OK \xe3\x81\x8b'; show
            elif [[ -n "$box" ]]; then record submission; fi ;;
        typeafter|typeafter-fast)
            # Ours submits at once; then SOMEBODY ELSE'S text is in the box — 0.3 s
            # later (`-fast`, inside any timing rule's blind window) or 1.6 s later.
            if (( enters == 1 )); then
                [[ -n "$box" ]] && record submission; state
                if [[ "$m" == typeafter-fast ]]; then sleep 0.3; else sleep 1.6; fi
                box="half-typed operator draft"; show
            elif [[ -n "$box" ]]; then record submission; fi ;;
        hold|busy-hold|hold-collapse|hold-foreign-queued|hold-foreign-compact|transienthold|hold-chipcont|hold-chipborder|hold-chipcontborder|hold-textcont)
            if [[ "$box" == *"$ZW"* || "$box" == *"$SH"* ]]; then
                box="${box//$ZW/}"; box="${box//$SH/}"
                # A REAL hold whose pane reads `busy` for 0.4 s after the cleaning
                # Enter before it reads `user-typing input=typed` — one transient
                # frame (skeptic pastesk F6).
                if [[ "$m" == transienthold ]]; then put pane-state "state=busy active=0"; sleep 0.4; fi
                # A record that is NOT this paste lands on the cleaning Enter: the
                # target's own transcript writes these with nobody else pasting.
                [[ "$m" == hold-foreign-queued ]] && printf '%s\n' '{"type":"user","promptSource":"queued","timestamp":"2026-09-19T00:00:00.000Z","message":{"role":"user","content":"an EARLIER queued prompt, submitted at turn end"}}' >> "$T"
                [[ "$m" == hold-foreign-compact ]] && printf '%s\n' '{"type":"user","isCompactSummary":true,"timestamp":"2026-09-19T00:00:00.000Z","message":{"role":"user","content":"This session is being continued from a previous conversation"}}' >> "$T"
                printf '\r\nRemoved invisible characters - review and press Enter to send\r\n'; show
            elif [[ -n "$box" ]]; then
                if [[ "$m" == busy-hold ]]; then record enqueue; else record submission; fi
            fi ;;
        busy) [[ -n "$box" ]] && record enqueue ;;
        lateecho)
            # The submitted prompt reaches HISTORY a second AFTER the submit, as
            # its trailer line — the only way a COLLAPSED body's trailer can ever
            # be on the pane (your-org/nexus-code#1539). Box redrawn below it.
            if [[ -n "$box" ]]; then
                local tr="${box%$'\n'}"; tr="${tr##*$'\n'}"
                record submission; state; sleep 1
                printf '\r\n%s\r\n' "$tr"; show
            fi ;;
        *)    [[ -n "$box" ]] && record submission ;;
    esac
    state
}
case "$(cat "$D/mode" 2>/dev/null)" in draft|draftq|busydraft|busydraftq) box="when we restart the emit gets stuck until I enter it "; show ;; esac
printf '\033[?2004h'; state; printf 'RDY\r\n'
while IFS= read -r -s -N1 ch; do
    if [[ -n "$pend" || "$ch" == $'\033' ]]; then
        pend+="$ch"
        if [[ "$pend" == "$OPEN" ]]; then inpaste=1; cur=""; pend=""; continue; fi
        if [[ "$pend" == "$CLOSE" ]]; then
            inpaste=0; pastes=$(( pastes + 1 )); printf '%s' "$cur" > "$D/pasted.$pastes.bin"
            # THE REPL PROMPT'S OWN PASTE PATH (`Ole` in 2.1.278, its twin in 2.1.273)
            # expands every TAB to four spaces BEFORE the length test. The first cut
            # measured the raw paste, which is the OTHER path's rule (`$c`), and that
            # is how a held payload with TABs stayed green while stranded (pastesk F13).
            _nl="${cur//[!$'\n']/}"; _tb="${cur//[!$'\t']/}"; ks+=("${#_nl}"); lens+=("$(( ${#cur} + 3 * ${#_tb} ))")
            box+="$cur"; pend=""; show; state; continue
        fi
        [[ "$OPEN" == "$pend"* || "$CLOSE" == "$pend"* ]] && continue
        ch="$pend"; pend=""          # not a bracket: fall through as data
    fi
    if (( inpaste )); then
        [[ "$ch" == $'\r' ]] && ch=$'\n'
        cur+="$ch"; continue
    fi
    case "$ch" in
        # bash's own `read` re-enables ICRNL on the tty it reads from, so the
        # Enter keypress arrives as LF here, not CR (measured: 61 0a 62). Accept
        # both — the REPL being simulated sees CR.
        $'\r'|$'\n') enter ;;
        $'\x7f') box="${box%?}"; state ;;
        $'\x1d') syncs=$(( syncs + 1 )); put sync "$syncs" ;;
        *)       box+="$ch"; state ;;
    esac
done
FAKECC
chmod +x "$WORK/fakecc.sh"

# pane-state stand-in: the fake REPL writes the line, this prints it.
cat > "$WORK/pane-state-stub" <<'STUB'
#!/usr/bin/env bash
cat "${FAKECC_DIR:?}/pane-state" 2>/dev/null
echo
STUB
chmod +x "$WORK/pane-state-stub"
mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/sandbox-notify"; chmod +x "$WORK/bin/sandbox-notify"

# ---- one row = one private server + one fake REPL -------------------------
ROW_RC=""; ROW_OUT=""; D=""; SOCK=""
row_open() {   # row_open <mode> [transcript=1|0]
    local mode="$1" with_t="${2:-1}"
    SOCK="pd$$-${RANDOM}"
    th_require_tmux_socket "$SOCK"
    SOCKS+=("$SOCK")
    D="$WORK/row-${RANDOM}${RANDOM}"; mkdir -p "$D/state/heartbeat" "$D/cc/projects/-slug"
    printf '%s' "$mode" > "$D/mode"; printf '0' > "$D/enters"; printf '0' > "$D/subs"
    TRANSCRIPT="$D/cc/projects/-slug/$SID.jsonl"
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the ORIGINAL spawn prompt"}}\n' > "$TRANSCRIPT"
    if [[ "$with_t" == 1 ]]; then
        printf '%s\n' "$SID" > "$D/state/orchestrator-session-id"
        printf '{"state":"idle_prompt","session_id":"%s","window":"orchestrator"}\n' "$SID" > "$D/state/heartbeat/orchestrator.json"
    fi
    # The SERVER's environment is what its panes inherit — never the live
    # state dir, never the real sandbox-notify.
    local p
    p=$(env -u TMUX NEXUS_STATE_DIR="$D/state" PATH="$WORK/bin:$PATH" \
        "$TMUX_BIN" -L "$SOCK" -f "$TCONF" new-session -d -s 0 -n orchestrator -P -F '#{pane_id}' -x 200 -y 50 \
        "bash $WORK/fakecc.sh $D $TRANSCRIPT") || { ROW_RC="rig"; return 1; }
    th_tmux_wait_pane env -u TMUX "$TMUX_BIN" -L "$SOCK" -- "$p" RDY 30 || { ROW_RC="rig"; return 1; }
    PANE="$p"
}
row_sync() {   # a happens-before edge: tmux writes pane input in order
    local want=$(( $(cat "$D/sync" 2>/dev/null || echo 0) + 1 )) deadline=$(( SECONDS + 15 ))
    env -u TMUX "$TMUX_BIN" -L "$SOCK" send-keys -t "$PANE" 'C-]' 2>/dev/null
    while (( SECONDS < deadline )); do
        [[ "$(cat "$D/sync" 2>/dev/null)" == "$want" ]] && return 0
        sleep 0.1
    done
    return 1
}
row_close() { env -u TMUX "$TMUX_BIN" -L "$SOCK" kill-server 2>/dev/null; }
enters()    { cat "$D/enters" 2>/dev/null || echo 0; }
subs()      { cat "$D/subs" 2>/dev/null || echo 0; }
hexof()     { od -An -tx1 "$1" 2>/dev/null | tr -d ' \n'; }
# A loop over the glob, not `ls <glob>`: under an ambient `nullglob` an unmatched
# glob VANISHES and a bare `ls` lists the CWD (nullglob-bare-form manifest).
pastes() { local f n=0; for f in "$D"/pasted.*.bin; do [[ -e "$f" ]] && n=$(( n + 1 )); done; printf '%s' "$n"; }

# Drivers. Each runs in a SUBSHELL whose bare `tmux` reaches only $SOCK.
_drv_env() {
    set +u
    # FAIL-ONCE hooks (your-org/nexus-code#1539): `$D/fail-insert-once` makes the
    # pre-paste `send-keys i BSpace` fail once; `$D/fail-enter-once` the first
    # `send-keys Enter`, AFTER the body is in the box. Each file is consumed.
    tmux() {
        if [[ "${1:-}" == send-keys ]]; then
            if [[ "${*: -1}" == BSpace && -e "$D/fail-insert-once" ]]; then rm -f "$D/fail-insert-once"; return 1; fi
            if [[ "${*: -1}" == Enter && -e "$D/fail-enter-once" ]]; then rm -f "$D/fail-enter-once"; return 1; fi
        fi
        env -u TMUX "$TMUX_BIN" -L "$SOCK" "$@"
    }
    # The emit fallback's re-look (#1539) is 3 s in production; 2 s here (CHOSEN)
    # keeps the rows quick and still spans lateecho's 1 s render delay.
    export MONITOR_PASTE_RENDER_RECHECK_SECONDS="${PDT_RECHECK_SECONDS:-2}"
    export NEXUS_CC_HOME="$D/cc" FAKECC_DIR="$D" PD_PANE_STATE_BIN="$WORK/pane-state-stub"
    export PD_CONFIRM_WINDOWS="${ROW_WINDOWS:-2 2 2}" PD_POLL_SECONDS=0.1 PD_HELD_CHECK_SECONDS=0.5
    STATE_DIR="$D/state"; TARGET=orchestrator; ORCH_PIN_FILE="$D/state/orchestrator-session-id"
    ORCH_LAST_PASTE_FILE="$D/state/last-paste"
    log() { printf '%s\n' "$*" >> "$D/log"; }
    unstick_log() { printf '%s\n' "$*" >> "$D/log"; }
    _orchestrator_refresh_pin() { :; }; _orchestrator_record_paste() { :; }
    . "$MON/_pane-live.sh"; . "$MON/_tmux-window.sh"
    [[ -r "$MON/_submit_evidence.sh" ]] && . "$MON/_submit_evidence.sh"
    (( HAVE_PD )) && . "$MON/_paste-deliver.sh"
    # The draft-deferral counter (your-org/nexus-code#1683 F2), when the subject
    # has one, with the operator alert replaced by a RECORDER: `raise` makes the
    # key standing, `standing` answers from that, every call is logged.
    [[ -r "$MON/watcher/_paste_deferral.sh" ]] && . "$MON/watcher/_paste_deferral.sh"
    _operator_alert() {
        printf '%s\n' "$*" >> "$D/alerts"
        case "${1:-}" in
            raise)    : > "$D/alert-standing" ;;
            standing) [[ -e "$D/alert-standing" ]]; return ;;
        esac
        return 0
    }
    eval "$(sed -n '/^_respawn_read_pin_sid() {/,/^}/p' "$MON/watcher/_respawn.sh")"
}
drive() {   # drive E|W|U|R <file>   (W = E through paste_with_retry)
    local who="$1" f="$2"
    (
        _drv_env
        case "$who" in
            E) eval "$(sed -n '/^_paste_to_target_unlocked() {/,/^}/p' "$MON/watcher/main.sh")"
               _paste_to_target_unlocked orchestrator "$f" ;;
            W) for _fn in paste_to_target _paste_to_target_unlocked paste_with_retry; do
                   eval "$(sed -n "/^$_fn() {/,/^}/p" "$MON/watcher/main.sh")"
               done
               paste_with_retry orchestrator "$f" ;;
            U) eval "$(sed -n '/^_paste_line_to_window() {/,/^}/p' "$MON/watcher/_unstick.sh")"
               _paste_line_to_window orchestrator "$(cat "$f")" ;;
            R) eval "$(sed -n '/^_respawn_paste_prompt_file() {/,/^}/p' "$MON/watcher/_respawn.sh")"
               _respawn_paste_prompt_file orchestrator "$f" ;;
        esac
    ) > "$D/drv.out" 2>&1
    ROW_RC=$?
    row_sync || ROW_RC="rig-sync"
}
drive_F() {  # drive_F <args…>  — paste-followup.sh, the script
    nx_write_tmux_shim "$D/bin" "$TMUX_BIN" "$SOCK" || { ROW_RC="rig-shim"; return; }
    ROW_OUT=$(
        PATH="$D/bin:$WORK/bin:$PATH" NEXUS_STATE_DIR="$D/state" NEXUS_CC_HOME="$D/cc" \
        FAKECC_DIR="$D" NEXUS_PASTE_PANE_STATE_BIN="$WORK/pane-state-stub" PASTE_NG_BIN=/bin/true \
        PASTE_CONFIRM_TIMEOUT_SECONDS="${ROW_TIMEOUT:-6}" PASTE_CONFIRM_POLL_SECONDS=0.1 PD_HELD_CHECK_SECONDS=0.5 \
        env -u NEXUS_ROOT -u NEXUS_LOCALS -u TMUX bash "$MON/paste-followup.sh" orchestrator "$@" 2>&1
    )
    ROW_RC=$?
    row_sync || ROW_RC="rig-sync"
}
body() {  # body <file> <text…>  — an emit-shaped body with a trailer
    local f="$1"; shift
    printf '%s\n--- nexus-emit-sig 2026-09-19T00:00:00+00:00 %06x ---\n' "$*" "$RANDOM" > "$f"
}
# THE PROPERTY. "delivered" is rc 0 for every caller here.
honest() {  # honest <id> <label>
    if [[ "$ROW_RC" == 0 && "$(subs)" == 0 ]]; then
        fail "$1" "$2 — MANUFACTURED SUCCESS: reported delivered (rc 0) while the REPL recorded NOTHING (enters=$(enters), box still held)"
    elif [[ "$ROW_RC" == rig* ]]; then
        fail "$1" "$2 — RIG failure ($ROW_RC), not a verdict"
    else
        pass "$1" "$2 (rc=$ROW_RC, recorded=$(subs), enters=$(enters))"
    fi
}

echo "== subject: $ROOT  ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?'))  primitive=$HAVE_PD  $("$TMUX_BIN" -V) =="

# =========================== E — the emit paste ===========================
echo; echo "== E. main.sh _paste_to_target_unlocked =="
row_open normal && { body "$D/b" "E-ctl plain ascii body"; drive E "$D/b"
    eq E-ctl.rc "control: an ASCII emit into a normal REPL is delivered" "$ROW_RC" 0
    eq E-ctl.rec "control: …and the REPL recorded exactly one submission" "$(subs)" 1
    eq E-ctl.enters "control: …with exactly ONE Enter" "$(enters)" 1; row_close; }

# A ZWSP on a line that ALSO carries a non-ASCII letter: the normaliser leaves
# it (tier C, non-ASCII line), so this row exercises LAYER 1 alone.
row_open hold && { body "$D/b" "E-held naïve a${ZWSP}b body"; drive E "$D/b"
    honest E-held.honest "a HELD emit is not certified delivered"
    eq E-held.rec "a HELD emit is recovered: the REPL recorded it" "$(subs)" 1
    eq E-held.enters "…by exactly ONE extra Enter" "$(enters)" 2; row_close; }

row_open hold && { body "$D/b" "E-norm a${ZWSP}b hy${SHY}phen body"; drive E "$D/b"
    honest E-norm.honest "an emit whose invisibles sit on an ASCII line is not certified while held"
    eq E-norm.rec "…it is delivered" "$(subs)" 1
    if (( HAVE_PD )); then
        eq E-norm.enters "…on the FIRST Enter, because it was normalised before the paste" "$(enters)" 1
        case "$(hexof "$D/pasted.1.bin")" in
            *e2808b*|*c2ad*) fail E-norm.bytes "the pane still received an invisible character" ;;
            *) pass E-norm.bytes "the bytes the pane received carry no ZWSP / soft hyphen" ;;
        esac
    else na E-norm.enters "needs the primitive"; na E-norm.bytes "needs the primitive"; fi; row_close; }

row_open stuck && { body "$D/b" "E-stuck plain ascii body"; drive E "$D/b"
    honest E-stuck.honest "an emit the REPL never accepts is not certified delivered"
    if (( HAVE_PD )); then
        eq E-stuck.rc "…it is reported NOT SUBMITTED (rc 6), which paste_with_retry does not re-paste" "$ROW_RC" 6
        eq E-stuck.enters "…after a BOUNDED number of Enters (1 + 2 retries)" "$(enters)" 3
    else na E-stuck.rc "needs the primitive"; na E-stuck.enters "needs the primitive"; fi; row_close; }

row_open blocked && { body "$D/b" "E-blocked plain ascii body"; drive E "$D/b"
    honest E-blocked.honest "an emit eaten by an overlay is not certified delivered"
    eq E-blocked.enters "NO second Enter into a pane that reads blocked (#1200)" "$(enters)" 1; row_close; }

row_open busy && { body "$D/b" "E-busy plain ascii body"; drive E "$D/b"
    eq E-busy.rc "control: a QUEUED emit (enqueue record, no type:user record) is delivered" "$ROW_RC" 0
    eq E-busy.enters "control: …with ONE Enter" "$(enters)" 1; row_close; }

row_open busy-hold && { body "$D/b" "E-busyheld naïve a${ZWSP}b body"; drive E "$D/b"
    honest E-busyheld.honest "an emit HELD in a busy pane is not certified delivered"
    eq E-busyheld.rec "…it is queued by the second Enter" "$(subs)" 1; row_close; }

# No pin, no heartbeat: nothing can confirm. The pane can still say "held".
row_open hold 0 && { body "$D/b" "E-nosid naïve a${ZWSP}b body"; drive E "$D/b"
    honest E-nosid.honest "UNVERIFIABLE target: a held emit is still not certified delivered"
    eq E-nosid.rec "UNVERIFIABLE target: positive held evidence alone earns the second Enter" "$(subs)" 1; row_close; }
row_open normal 0 && { body "$D/b" "E-nosid-ctl plain ascii body"; drive E "$D/b"
    eq E-nosidctl.rc "control: UNVERIFIABLE target, normal REPL — the rendering fallback still answers 0" "$ROW_RC" 0
    eq E-nosidctl.enters "control: …and NO blind retry is sent when nothing could confirm it" "$(enters)" 1; row_close; }

# THE RECORD MUST BE OURS (skeptic pastesk F1 on #1595). The target's OWN
# transcript writes selector-matching records with nobody else pasting: an
# earlier queued prompt submitted at turn end, a compaction summary. With ours
# HELD and one of those landing on the cleaning Enter, the first cut answered
# rc 0 `submitted` after ONE Enter — ours never recorded.
for _fm in queued compact; do
    row_open "hold-foreign-$_fm" && { body "$D/b" "E-foreign naïve a${ZWSP}b body"; drive E "$D/b"
        honest "E-foreign-$_fm.honest" "a FOREIGN $_fm record inside the held window is not taken for this emit"
        eq "E-foreign-$_fm.rec" "…and the held emit is still recovered" "$(subs)" 1
        eq "E-foreign-$_fm.enters" "…by its second Enter" "$(enters)" 2; row_close; }
done
# ONE TRANSIENT FRAME IS NOT A FACT (F6): a real hold whose pane reads `busy` for
# 0.4 s after the cleaning Enter. The first cut of the F3 rule was one-strike and
# stranded it — rc 6, the emit left sitting in the box.
row_open transienthold && { body "$D/b" "E-transient naïve a${ZWSP}b body"; drive E "$D/b"
    honest E-transient.honest "a held emit behind ONE transient non-held frame is not certified while held"
    eq E-transient.rec "…and is still recovered" "$(subs)" 1
    eq E-transient.enters "…by its second Enter" "$(enters)" 2; row_close; }
# `input=?` is undecidable and is read as a DRAFT: no Enter, and no delivery claim (F2).
row_open qmark && { body "$D/b" "E-qmark plain ascii body"; drive E "$D/b"
    honest E-qmark.honest "an undecidable box (input=?) is not certified delivered"
    eq E-qmark.enters "control: an undecidable box gets NO second Enter" "$(enters)" 1; row_close; }
# AN INERT EMIT WHOSE BODY IS VISIBLY IN THE BOX IS NOT DELIVERED
# (your-org/nexus-code#1604). The pane reader misses the box (idle/blank), so the
# primitive ends `inert` (readable transcript) or `unverifiable` (none); main.sh
# sends both to the rendering fallback, and a WHOLE-PANE grep found the trailer
# in the unsent box and answered rc 0 — no request, no record. Red at 9f0b719a.
row_open misread && { body "$D/b" "E-misread plain ascii body"; drive E "$D/b"
    honest E-misread.honest "an INERT emit sitting in a box the reader misses is not certified delivered"
    eq E-misread.rc "…it is reported NOT SUBMITTED (rc 6): the trailer is IN the input box" "$ROW_RC" 6
    eq E-misread.enters "…with no retry Enter (the box never read as ours)" "$(enters)" 1; row_close; }
row_open misread 0 && { body "$D/b" "E-misread-nosid plain ascii body"; drive E "$D/b"
    honest E-misread-nosid.honest "UNVERIFIABLE target: a body sitting in a misread box is not certified delivered"
    eq E-misread-nosid.rc "…NOT SUBMITTED (rc 6)" "$ROW_RC" 6; row_close; }
# …and a body with NO TRAILER, which is the road #1604's own real-binary repro
# took: `$sig` empty, the rendering check SKIPPED, rc 0 unconditionally. Only
# compose_report writes a trailer; the over-limit and orphan-async briefs do not.
# Located by the primitive's derived needle instead. Red at 9f0b719a.
row_open misread && { printf 'E-misread-nosig plain ascii body with no trailer\n' > "$D/b"; drive E "$D/b"
    honest E-misread-nosig.honest "a TRAILER-LESS body sitting in a misread box is not certified delivered"
    eq E-misread-nosig.rc "…NOT SUBMITTED (rc 6), found by the derived needle" "$ROW_RC" 6; row_close; }
# …and a derived needle that carries a BACKSLASH SEQUENCE inside its first 32
# bytes (skeptic note on your-org/nexus-code#1626). `awk -v` ran escape
# processing on the needle, so the literal `\n` / `\t` below became a newline
# and a tab, matched no rendered row, and the refusal was off for this body:
# rc 0. The needle now reaches awk through ENVIRON, verbatim.
row_open misread && { printf '%s\n' 'E-bs a\nb\tc plain ascii body, no trailer' > "$D/b"; drive E "$D/b"
    honest E-misread-bs.honest "a trailer-less body whose needle carries a literal \\n / \\t, sitting in a misread box, is not certified delivered"
    eq E-misread-bs.rc "…NOT SUBMITTED (rc 6): the needle is matched VERBATIM" "$ROW_RC" 6; row_close; }
printf '%s\n' 'E-bs a\nb\tc plain ascii body, no trailer' > "$D/bs-pre"
eq E-misread-bs.pre "precondition: that body's first 32 bytes DO carry a literal backslash sequence" \
    "$(head -c 32 "$D/bs-pre" | LC_ALL=C grep -cF -e '\n')" 1
row_open normal 0 && { printf 'E-nosig-ctl plain ascii body with no trailer\n' > "$D/b"; drive E "$D/b"
    eq E-nosig-ctl.rc "control: a TRAILER-LESS body really submitted (unverifiable target) is still answered 0" "$ROW_RC" 0
    eq E-nosig-ctl.rec "control: …and the REPL did record it" "$(subs)" 1; row_close; }
row_open misread && { body "$D/b" "W-misread plain ascii body"; drive W "$D/b"
    eq W-misread.pastes "control: paste_with_retry does NOT re-paste a body already in the box" "$(pastes)" 1; row_close; }
# THE FALLBACK STILL ANSWERS FOR WHAT IT EXISTS FOR (pastesk F2): a STALE pin —
# a readable transcript that is not the one the REPL writes — ends `inert` for a
# real submit, and the trailer then sits in the HISTORY, above the redrawn box.
row_open normal && {
    _stale="99999999-8888-7777-6666-555555555555"
    printf '%s\n' "$_stale" > "$D/state/orchestrator-session-id"
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"a DIFFERENT session"}}\n' > "$D/cc/projects/-slug/$_stale.jsonl"
    body "$D/b" "E-stalesid plain ascii body"; drive E "$D/b"
    eq E-stalesid.rc "control: a STALE pin, real submit — the trailer is ABOVE the box, so the fallback still answers 0" "$ROW_RC" 0
    eq E-stalesid.rec "control: …and the REPL did record it" "$(subs)" 1
    case "$(cat "$D/log" 2>/dev/null)" in
        *"UNCONFIRMED (inert"*) pass E-stalesid.path "control: …and it was the rendering fallback that answered, from inert" ;;
        *) fail E-stalesid.path "control: the stale-pin row did not reach the fallback from inert — it tests nothing (log: $(tr '\n' '|' < "$D/log" 2>/dev/null))" ;;
    esac; row_close; }
# THE RETRY ENTER IS AN EQUALITY, NOT A SHAPE (skeptic pastesk A4 / F8 on #1595,
# and the orchestrator's direction). Ours submits; then SOMEBODY ELSE'S text is
# in the box and reads `user-typing input=typed` — the same SHAPE as a held
# paste. Unverifiable target, so nothing but the box can tell them apart. A
# second Enter would SUBMIT THE OPERATOR'S DRAFT, the one outcome that cannot be
# undone. 0.3 s is inside the blind window of every timing rule this primitive
# tried (one-strike, then two-consecutive); the equality has no window.
for _ta in typeafter-fast typeafter; do
    row_open "$_ta" 0 && { body "$D/b" "E-$_ta plain ascii body"; drive E "$D/b"
        eq "E-$_ta.enters" "a draft appearing $([[ $_ta == *fast ]] && echo 0.3 || echo 1.6) s after our submit earns NO Enter" "$(enters)" 1
        eq "E-$_ta.rec" "…so the operator's draft is NEVER submitted" "$(subs)" 1; row_close; }
done
# THE COUNT-LESS PLACEHOLDER IS OURS ONLY IF OUR PAYLOAD WOULD COLLAPSE (skeptic
# pastesk F12, its row X5b). `[Pasted text #N]` carries no line count, so once it
# was accepted (F9) it EQUALLED every zero-break payload of ours — and every
# unstick line and every `--message` send is `printf %s`, K = 0 — including SHORT
# ones the binary never collapses. An operator's long single-line paste appearing
# 0.3 s after our submit was then SUBMITTED by the retry: F8's class, through
# the new door. A short payload of ours renders as TEXT, so a placeholder in the
# box cannot be it.
row_open pasteafter-fast 0 && { printf 'U-pasteafter please continue with the task' > "$D/b"; drive U "$D/b"
    eq U-pasteafter.enters "an operator's count-less placeholder after our SHORT line earns NO Enter" "$(enters)" 1
    eq U-pasteafter.rec "…so the operator's paste is NEVER submitted" "$(subs)" 1; row_close; }
# A placeholder that is NOT ours — somebody else's collapsed paste, a different
# line count — has the held SHAPE and fails the EQUALITY.
row_open foreignpaste && { body "$D/b" "E-foreignpaste plain ascii body"; drive E "$D/b"
    honest E-foreignpaste.honest "control: a box holding somebody else's paste is not certified delivered"
    eq E-foreignpaste.enters "a placeholder whose line count is not ours earns NO Enter" "$(enters)" 1; row_close; }
# An overlay is ALREADY up: nothing may be pasted, and no Enter pressed (F4).
row_open preblocked && { body "$D/b" "E-preblocked plain ascii body"; drive E "$D/b"
    eq E-preblocked.pastes "an overlay already up: NOTHING is pasted into it (#1200)" "$(pastes)" 0
    eq E-preblocked.enters "…and no Enter is pressed" "$(enters)" 0
    if (( HAVE_PD )); then eq E-preblocked.rc "…reported as rc 7: the ORCHESTRATOR is on an overlay, not a watcher paste fault (F7)" "$ROW_RC" 7
    else na E-preblocked.rc "needs the primitive"; fi; row_close; }
# An OPERATOR DRAFT is ALREADY in the box (your-org/nexus-code#1674). Measured on
# the live board 2026-09-29 13:16:02: the emit was pasted INTO the operator's
# half-typed message and the first Enter sent it mid-word. Nothing may be
# pasted and no Enter pressed — with the box read as typed text, and with it
# read as the undecidable `input=?`.
if row_open draft; then body "$D/b" "E-draft plain ascii body"; drive E "$D/b"
    eq E-draft.pastes "an operator draft in the box: NOTHING is pasted into it (#1674)" "$(pastes)" 0
    eq E-draft.enters "…no Enter is pressed" "$(enters)" 0
    eq E-draft.rec "…and the draft is NOT submitted" "$(subs)" 0
    if (( HAVE_PD )); then eq E-draft.rc "…reported rc 7: a fact about the pane, not a watcher paste fault" "$ROW_RC" 7
    else na E-draft.rc "needs the primitive"; fi; row_close
else fail E-draft.rig "rig: row_open draft failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
if row_open draftq; then body "$D/b" "E-draftq plain ascii body"; drive E "$D/b"
    eq E-draftq.pastes "a box reading input=? is a draft (#626): NOTHING is pasted (#1674)" "$(pastes)" 0
    eq E-draftq.rec "…and it is NOT submitted" "$(subs)" 0; row_close
else fail E-draftq.rig "rig: row_open draftq failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
# NEGATIVE: a GHOST over an empty box is NOT a draft — the gate must not make an
# autosuggest block delivery.
if row_open ghost; then body "$D/b" "E-ghost plain ascii body"; drive E "$D/b"
    eq E-ghost.rc "a ghost/autosuggest is not a draft: the emit is delivered" "$ROW_RC" 0
    eq E-ghost.rec "…exactly one submission" "$(subs)" 1; row_close
else fail E-ghost.rig "rig: row_open ghost failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
# THE SAME DRAFT, TYPED AHEAD INTO A MID-TURN PANE (your-org/nexus-code#1683
# F1). The gate read only `user-typing`, so a `busy` pane — which is what every
# hook-carrying worker reads while its heartbeat is fresh — was pasted into.
if row_open busydraft; then body "$D/b" "E-busydraft plain ascii body"; drive E "$D/b"
    eq E-busydraft.pastes "a draft typed into a MID-TURN pane (busy input=typed): NOTHING is pasted (#1683)" "$(pastes)" 0
    eq E-busydraft.rec "…and the draft is NOT submitted" "$(subs)" 0
    if (( HAVE_PD )); then eq E-busydraft.rc "…reported rc 7, as for an idle-box draft" "$ROW_RC" 7
    else na E-busydraft.rc "needs the primitive"; fi; row_close
else fail E-busydraft.rig "rig: row_open busydraft failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
if row_open busydraftq; then body "$D/b" "E-busydraftq plain ascii body"; drive E "$D/b"
    eq E-busydraftq.pastes "a mid-turn box reading input=? is a draft (#626): NOTHING is pasted (#1683)" "$(pastes)" 0
    eq E-busydraftq.rec "…and it is NOT submitted" "$(subs)" 0; row_close
else fail E-busydraftq.rig "rig: row_open busydraftq failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
# NEGATIVE: a mid-turn pane with an EMPTY box is not a draft — reading the box on
# a busy pane must not make `busy` itself refuse.
if row_open busyblank; then body "$D/b" "E-busyblank plain ascii body"; drive E "$D/b"
    eq E-busyblank.rc "a mid-turn pane with an empty box (busy input=blank): the emit is delivered" "$ROW_RC" 0
    eq E-busyblank.rec "…exactly one submission" "$(subs)" 1; row_close
else fail E-busyblank.rig "rig: row_open busyblank failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
if row_open busydraft; then printf 'U-busydraft please continue with the task' > "$D/b"; drive U "$D/b"
    eq U-busydraft.pastes "unstick into a mid-turn draft: NOTHING is pasted (#1683)" "$(pastes)" 0
    eq U-busydraft.rec "…and it is NOT submitted" "$(subs)" 0; row_close
else fail U-busydraft.rig "rig: row_open busydraft failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
# A DRAFT THAT STAYS (your-org/nexus-code#1683 F2). rc 7 used to be neither
# counted nor surfaced, so a draft left in the box — or a stranded emit of ours —
# withheld every later emit in silence. Now: a per-target run count, an operator
# alert once the run is long enough in BOTH count and age, and a reset + clear
# on the next delivery. Thresholds are set per drive so both gates are exercised.
_dfr_count() { cut -f1 "$D/state/paste-deferral/orchestrator" 2>/dev/null || echo none; }
_dfr_n()     { [[ -e "$D/alerts" ]] || { echo 0; return; }; command grep -c -F -e "$1" "$D/alerts"; }
if (( HAVE_PD )); then
    if row_open draft; then
        body "$D/b" "D-defer plain ascii body"
        MONITOR_PASTE_DEFERRAL_ALERT_COUNT=2 MONITOR_PASTE_DEFERRAL_ALERT_SECONDS=3600 drive E "$D/b"
        eq D-defer1.count "one draft deferral is COUNTED for the target (#1683)" "$(_dfr_count)" 1
        MONITOR_PASTE_DEFERRAL_ALERT_COUNT=2 MONITOR_PASTE_DEFERRAL_ALERT_SECONDS=3600 drive E "$D/b"
        eq D-defer2.count "…a second in a row makes the run 2" "$(_dfr_count)" 2
        eq D-defer2.quiet "…count reached but the run is YOUNGER than the age threshold: no alert" "$(_dfr_n 'raise paste-draft-deferred:orchestrator')" 0
        MONITOR_PASTE_DEFERRAL_ALERT_COUNT=2 MONITOR_PASTE_DEFERRAL_ALERT_SECONDS=0 drive E "$D/b"
        eq D-defer3.count "…a third makes it 3" "$(_dfr_count)" 3
        eq D-defer3.raise "…and past BOTH thresholds the operator alert is RAISED, once, at warning" "$(_dfr_n 'raise paste-draft-deferred:orchestrator warning')" 1
        eq D-defer.pastes "…while nothing was ever pasted into the draft" "$(pastes)" 0
        _dfr_saved="$WORK/dfr-saved"; mkdir -p "$_dfr_saved"
        cp "$D/state/paste-deferral/orchestrator" "$_dfr_saved/count" 2>/dev/null
        cp "$D/alert-standing" "$_dfr_saved/standing" 2>/dev/null
        row_close
    else fail D-defer.rig "rig: row_open draft failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
    if row_open normal; then
        mkdir -p "$D/state/paste-deferral"
        cp "$_dfr_saved/count" "$D/state/paste-deferral/orchestrator" 2>/dev/null
        cp "$_dfr_saved/standing" "$D/alert-standing" 2>/dev/null
        body "$D/b" "D-reset plain ascii body"; drive E "$D/b"
        eq D-reset.rc "the box is clear again: the emit is delivered" "$ROW_RC" 0
        eq D-reset.count "…and the delivery RESETS the run" "$(_dfr_count)" none
        eq D-reset.clear "…and CLEARS the standing alert" "$(_dfr_n 'clear paste-draft-deferred:orchestrator')" 1
        row_close
    else fail D-reset.rig "rig: row_open normal failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi
else
    na D-defer "needs the primitive (no occupied-before-paste without it)"
fi

# The unstick path goes through the same primitive.
if row_open draft; then printf 'U-draft please continue with the task' > "$D/b"; drive U "$D/b"
    eq U-draft.pastes "unstick into an operator draft: NOTHING is pasted (#1674)" "$(pastes)" 0
    eq U-draft.rec "…and it is NOT submitted" "$(subs)" 0
    if (( HAVE_PD )); then eq U-draft.rc "…reported not delivered (rc 1)" "$ROW_RC" 1
    else na U-draft.rc "needs the primitive"; fi; row_close
else fail U-draft.rig "rig: row_open draft failed (ROW_RC=$ROW_RC) — this row did NOT run"; fi

# THE PRODUCTION SHAPE. A real emit collapses to a placeholder, so while it is
# held its trailer is NOT on the pane: the pre-fix function returned 4, and
# paste_with_retry answered rc 4 by RE-PASTING — a second copy on top of the
# held one, held again. Measured on the real 2.1.278 at 17f1f926: rc 4, no
# request, and the box reading `[Pasted text #1 +15 lines][Pasted text #2 +15
# lines]`, waiting for the next Enter to submit both, merged with the next emit.
bigbody() {   # an EMIT-SHAPED body: many lines, > 800 chars — what the binary collapses
    local f="$1" i; shift
    { printf '%s\n' "$*"; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf -- '- row %02d: a relayed issue comment, padded to a realistic emit width so that the paste collapses\n' "$i"; done
      printf -- '--- nexus-emit-sig 2026-09-19T00:00:00+00:00 %06x ---\n' "$RANDOM"; } > "$f"
}
row_open hold-collapse && { bigbody "$D/b" "E-dup naïve a${ZWSP}b body"; drive W "$D/b"
    honest E-dup.honest "control: a held emit-shaped body is never reported delivered while held"
    eq E-dup.once "a held emit-shaped body is pasted ONCE — never re-pasted on top of itself" "$(pastes)" 1
    eq E-dup.rec  "…and is delivered" "$(subs)" 1; row_close; }
row_open stuck && { body "$D/b" "E-nodup plain ascii body"; drive W "$D/b"
    if (( HAVE_PD )); then
        eq E-nodup.once "rc 6 (pasted, NOT submitted) is never answered with a re-paste" "$(pastes)" 1
    else na E-nodup.once "needs the primitive (rc 6 does not exist without it)"; fi; row_close; }

# THE QUIESCENT DUPLICATE (your-org/nexus-code#1539). A COLLAPSED emit, really
# submitted on the first Enter, into a target nothing can confirm (no transcript):
# the trailer never reaches the pane, the fallback answered rc 4 AFTER the Enter,
# and paste_with_retry RE-PASTED — two submits, one `pasted to` log line. The
# Enter went out, so the answer is a logged rc 4, never a second paste.
row_open normal 0 && { bigbody "$D/b" "W-quiescent plain ascii body"; drive W "$D/b"
    eq W-quiescent.pastes "a collapsed emit submitted into an unconfirmable target is pasted ONCE" "$(pastes)" 1
    eq W-quiescent.rec "…and the REPL recorded it ONCE — no duplicate delivery" "$(subs)" 1
    eq W-quiescent.rc "…reported rc 4 (unconfirmed, not re-pasted)" "$ROW_RC" 4
    case "$(cat "$D/log" 2>/dev/null)" in
        *"NOT re-pasted"*) pass W-quiescent.log "…and the rc 4 is LOGGED at the paste site, never silent" ;;
        *) fail W-quiescent.log "rc 4 left no NOT re-pasted line (log: $(tr '\n' '|' < "$D/log" 2>/dev/null))" ;;
    esac; row_close; }
# …and the re-LOOK (no paste) is what answers when the trailer renders late: the
# submitted prompt reaches history a second after the Enter.
row_open lateecho 0 && { bigbody "$D/b" "W-lateecho plain ascii body"; drive W "$D/b"
    eq W-lateecho.rc "a collapsed emit whose trailer renders LATE is found by the re-look: rc 0" "$ROW_RC" 0
    eq W-lateecho.pastes "…pasted ONCE" "$(pastes)" 1
    eq W-lateecho.rec "…recorded ONCE" "$(subs)" 1; row_close; }
# A PRE-ENTER failure still retries — nothing reached the box, so a re-paste
# cannot duplicate — and the retry is LOGGED.
row_open normal && { body "$D/b" "W-preinsert plain ascii body"; : > "$D/fail-insert-once"; drive W "$D/b"
    eq W-preinsert.rc "control: a failed pre-paste insert key is RETRIED and delivered" "$ROW_RC" 0
    eq W-preinsert.rec "control: …recorded exactly once" "$(subs)" 1
    eq W-preinsert.pastes "control: …pasted exactly once (the failed attempt pasted nothing)" "$(pastes)" 1
    case "$(cat "$D/log" 2>/dev/null)" in
        *"paste_with_retry: 'orchestrator' attempt 1 rc=3"*"send-keys-insert"*) pass W-preinsert.log "…and the retry is LOGGED with its rc and failing step" ;;
        *) fail W-preinsert.log "the retry left no log line (log: $(tr '\n' '|' < "$D/log" 2>/dev/null))" ;;
    esac; row_close; }
# A REFUSED ENTER comes after the body is in the box: re-pasting stacks a second
# copy on it (#1591). rc 6, pasted once.
row_open normal && { body "$D/b" "W-enterfail plain ascii body"; : > "$D/fail-enter-once"; drive W "$D/b"
    if (( HAVE_PD )); then
        eq W-enterfail.pastes "a refused Enter (body already in the box) is NOT answered with a re-paste" "$(pastes)" 1
        eq W-enterfail.rc "…reported NOT SUBMITTED (rc 6)" "$ROW_RC" 6
    else na W-enterfail.pastes "needs the primitive"; na W-enterfail.rc "needs the primitive"; fi; row_close; }

# =========================== U — the unstick line ==========================
echo; echo "== U. _unstick.sh _paste_line_to_window =="
row_open normal && { printf 'U-ctl please continue' > "$D/b"; drive U "$D/b"
    eq U-ctl.rc "control: delivered" "$ROW_RC" 0; eq U-ctl.enters "control: one Enter" "$(enters)" 1; row_close; }
row_open hold && { printf 'U-held naïve a%sb continue' "$ZWSP" > "$D/b"; drive U "$D/b"
    honest U-held.honest "a HELD line is not reported delivered"
    eq U-held.rec "a HELD line is recovered" "$(subs)" 1; row_close; }
# A SINGLE-LINE payload over 800 chars: the binary collapses it to `[Pasted text
# #N]` with NO `+K lines`. Held, it must still be recognised as OURS (pastesk F9).
row_open hold && { printf 'U-longline naïve a%sb %s end' "$ZWSP" "$(printf 'padding-%.0s' $(seq 1 110))" > "$D/b"; drive U "$D/b"
    honest U-longline.honest "a held single-line payload over 800 chars is not reported delivered while held"
    # SINGLE-quoted label: backticks inside double quotes are COMMAND SUBSTITUTION,
    # and the first cut of this line ran `[Pasted text #N]` as a command and printed
    # the label with the token deleted. test-subshell-exit-guards.sh caught it.
    eq U-longline.rec '…and is recovered: [Pasted text #N] with no line count IS ours' "$(subs)" 1
    eq U-longline.enters "…by exactly one extra Enter" "$(enters)" 2; row_close; }
# TABs: the binary measures length AFTER expanding each TAB to four spaces, so a
# single line UNDER 800 by a raw count and OVER it by the binary's collapses too.
# Held, it must still be recognised as OURS (pastesk F13, its row T1): 80 TABs in
# a line of under 700 bytes, over 900 after expansion.
row_open hold && { printf 'U-tabline naïve a%sb %s%s end' "$ZWSP" "$(printf 'col\t%.0s' $(seq 1 80))" "$(printf 'padding-%.0s' $(seq 1 40))" > "$D/b"; drive U "$D/b"
    honest U-tabline.honest "a held single-line payload that collapses only BY ITS TABS is not reported delivered while held"
    eq U-tabline.rec '…and is recovered: the placeholder IS ours, because the binary counts a TAB as four' "$(subs)" 1
    eq U-tabline.enters "…by exactly one extra Enter" "$(enters)" 2; row_close; }
# ---- your-org/nexus-code#1729: the WHOLE input region, not the glyph row -----
# OUR held chip (or line) with an OPERATOR continuation row under it: the glyph
# row alone still reads as ours, so the old equality admitted it and the retry
# Enter submitted the operator's text together with our payload. Nothing but
# ours may be in the region between the glyph row and the bottom border.
_U1729_LONG() { printf 'U-%s naïve a%sb %s end' "$1" "$ZWSP" "$(printf 'padding-%.0s' $(seq 1 110))"; }
if (( HAVE_PD )); then
    row_open hold-chipcont && { _U1729_LONG chipcont > "$D/b"; drive U "$D/b"
        honest U-chipcont.honest "our held chip with an operator continuation row is not reported delivered"
        eq U-chipcont.enters "…and earns NO retry Enter: the region below the chip is not ours" "$(enters)" 1
        eq U-chipcont.rec "…so the operator's continuation is NEVER submitted with our chip" "$(subs)" 0; row_close; }
    # CONTROL for the border detection: the chip alone, with the bottom border and a
    # FOOTER below it. The footer is not input — a region running to the end of the
    # capture would refuse this, so it is what proves the border is found.
    row_open hold-chipborder && { _U1729_LONG chipborder > "$D/b"; drive U "$D/b"
        eq U-chipborder.rec "CONTROL: our chip alone above the border (footer below) is still recovered" "$(subs)" 1
        eq U-chipborder.enters "CONTROL: …by exactly one extra Enter" "$(enters)" 2; row_close; }
    row_open hold-chipcontborder && { _U1729_LONG chipcontborder > "$D/b"; drive U "$D/b"
        eq U-chipcontborder.enters "an operator row ABOVE the border, under our chip, earns NO retry Enter" "$(enters)" 1
        eq U-chipcontborder.rec "…and nothing is submitted" "$(subs)" 0; row_close; }
    row_open hold-textcont && { printf 'U-textcont naïve a%sb continue' "$ZWSP" > "$D/b"; drive U "$D/b"
        eq U-textcont.enters "our held TEXT line with an operator continuation row earns NO retry Enter" "$(enters)" 1
        eq U-textcont.rec "…and nothing is submitted" "$(subs)" 0; row_close; }
else
    for _id in U-chipcont.honest U-chipcont.enters U-chipcont.rec U-chipborder.rec U-chipborder.enters \
               U-chipcontborder.enters U-chipcontborder.rec U-textcont.enters U-textcont.rec; do
        na "$_id" "needs the primitive"
    done
fi
# The same, through pd_deliver's DERIVED needle (no caller-supplied trailer here).
# ---- your-org/nexus-code#1597: a first line the equality could not read ------
# Row ids are the prediction file's, written before these rows or the fix. What
# the REPL does with each body was MEASURED on the real 2.1.278 first; the two
# real-binary arms in test-realmodel-paste-held.sh are where it stays measured.
row_open hold && { printf '\nU97-blank na\xc3\xafve a%sb please continue' "$ZWSP" > "$D/b"; drive U "$D/b"
    honest U97-blank.honest "a held line behind an EMPTY first line is not reported delivered while stranded"
    eq U97-blank.rec "…and is recovered" "$(subs)" 1
    eq U97-blank.bytes "…and what was submitted starts with our first NON-blank line" "$(head -c 9 "$D/submitted.1.bin" 2>/dev/null)" "U97-blank"; row_close; }
row_open hold && { printf '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe3\x81\xae\xe6\x9c\x80\xe5\x88\x9d%s\xe6\xbc\xa2\xe5\xad\x97' "$ZWSP" > "$D/b"; drive U "$D/b"
    eq U97-cjk.rec "a held first line with NO ASCII at all is recovered" "$(subs)" 1
    eq U97-cjk.enters "…by exactly one extra Enter" "$(enters)" 2; row_close; }
row_open collideafter-fast 0 && { printf '\xe4\xbf\xae\xe6\xad\xa3 OK \xe3\x81\xa7\xe3\x81\x99' > "$D/b"; drive U "$D/b"
    eq U97-collide.enters "an operator draft with the SAME ASCII PROJECTION as our line earns NO Enter" "$(enters)" 1
    eq U97-collide.rec "…so the operator's draft is NEVER submitted" "$(subs)" 1; row_close; }
row_open hold && { printf '\xc3\xb6k a%sb' "$ZWSP" > "$D/b"; drive U "$D/b"
    eq U97-short.rec "CONTROL: a held line under 8 characters is still recovered, by WHOLE equality" "$(subs)" 1; row_close; }

row_open hold-foreign-queued && { printf 'U-foreign naïve a%sb please continue with the task' "$ZWSP" > "$D/b"; drive U "$D/b"
    honest U-foreign.honest "a FOREIGN queued record is not taken for this line (derived needle)"
    eq U-foreign.rec "…and the held line is still recovered" "$(subs)" 1; row_close; }
# An undecidable box is "not delivered", never "could not confirm" — on this path too.
row_open qmark && { printf 'U-qmark please continue' > "$D/b"; drive U "$D/b"
    honest U-qmark.honest "an undecidable box (input=?) is not reported delivered by the unstick path"; row_close; }
row_open stuck && { printf 'U-stuck please continue' > "$D/b"; drive U "$D/b"
    honest U-stuck.honest "a line the REPL never accepts is not reported delivered"; row_close; }

# The module sourced STANDALONE under `set -u`, with no UNSTICK_LOG — how
# test-paste-dead-pane-guard.sh and entry.sh load it. The first cut of this
# change logged through `unstick_log`, which dereferences $UNSTICK_LOG: a fatal
# expansion that turned a delivered paste into rc 1.
row_open normal && {
    (
        set -u; unset UNSTICK_LOG STATE_DIR TARGET
        tmux() { env -u TMUX "$TMUX_BIN" -L "$SOCK" "$@"; }
        export NEXUS_CC_HOME="$D/cc" FAKECC_DIR="$D" PD_PANE_STATE_BIN="$WORK/pane-state-stub" PD_CONFIRM_WINDOWS="2" PD_POLL_SECONDS=0.1
        . "$MON/watcher/_unstick.sh" >/dev/null 2>&1
        _paste_line_to_window orchestrator "U-nounset please continue"
    ) > "$D/drv.out" 2>&1; ROW_RC=$?; row_sync || ROW_RC=rig-sync
    eq U-nounset.rc "control: standalone under set -u with no UNSTICK_LOG — the paste still returns 0" "$ROW_RC" 0
    eq U-nounset.rec "control: …and was delivered" "$(subs)" 1; row_close; }

# =========================== R — the respawn brief =========================
echo; echo "== R. _respawn.sh _respawn_paste_prompt_file =="
row_open normal && { printf 'R-ctl brief line one\nline two' > "$D/b"; drive R "$D/b"
    eq R-ctl.rc "control: pasted and Enter sent" "$ROW_RC" 0
    eq R-ctl.rec "control: the REPL recorded the brief" "$(subs)" 1; row_close; }
row_open hold && { printf 'R-norm brief a%sb' "$ZWSP" > "$D/b"; drive R "$D/b"
    if (( HAVE_PD )); then
        eq R-norm.rec "a brief whose invisibles sit on an ASCII line is normalised, so ONE Enter submits it" "$(subs)" 1
    else na R-norm.rec "needs the primitive"; fi; row_close; }

# =========================== F — paste-followup.sh =========================
echo; echo "== F. paste-followup.sh =="
row_open normal && { drive_F --message 'F-ctl a follow-up'
    eq F-ctl.rc "control: submitted" "$ROW_RC" 0; eq F-ctl.enters "control: one Enter" "$(enters)" 1; row_close; }

# #1590 — the bytes are never argv.
row_open normal && { drive_F --message 'F-semi run the loop;'
    eq F-semi1.bytes "a message ENDING in ';' reaches the pane with its ';' (#1590)" \
        "$(cat "$D/pasted.1.bin" 2>/dev/null)" 'F-semi run the loop;'; row_close; }
row_open normal && { drive_F --message ';'
    eq F-semi2.rc "a message that is exactly ';' is delivered, not a tmux failure (#1590)" "$ROW_RC" 0
    eq F-semi2.bytes "…and the pane received exactly ';'" "$(cat "$D/pasted.1.bin" 2>/dev/null)" ';'; row_close; }
row_open normal && { drive_F --message 'F-semi a;b mid'
    eq F-semictl.bytes "control: a ';' that is NOT last was never affected" \
        "$(cat "$D/pasted.1.bin" 2>/dev/null)" 'F-semi a;b mid'; row_close; }

row_open hold && { drive_F --message "F-held naïve a${ZWSP}b"
    honest F-held.honest "control: a HELD follow-up is never reported submitted while held"
    eq F-held.rec "control: a HELD follow-up is recovered by the Enter retry" "$(subs)" 1; row_close; }

row_open blocked && { drive_F --message 'F-blocked plain follow-up'
    eq F-blocked.enters "NO retry Enter into a pane that reads blocked (#1200)" "$(enters)" 1
    eq F-blocked.rc "…and it is reported NOT submitted (rc 4)" "$ROW_RC" 4; row_close; }

row_open hold && { drive_F --message "F-norm a${ZWSP}b"
    eq F-norm.rec "a follow-up whose invisibles sit on an ASCII line is delivered" "$(subs)" 1
    want=$(printf '%s' "$(cat "$D/submitted.1.bin" 2>/dev/null)" | sha256sum | cut -d' ' -f1)
    # One sidecar per paste and one paste per row; awk reads the FILES (no pipe,
    # so no early-exit reader) and stops at the first digest= line.
    got=""
    for _v in "$D"/state/paste-verdicts/orchestrator.*; do
        [[ -f "$_v" && "$_v" != *.scan ]] || continue
        got=$(awk -F= '$1=="digest"{print $2; exit}' "$_v" 2>/dev/null)
    done
    eq F-norm.digest "the recorded digest= describes the bytes the transcript RECORDED, not the raw ones (#665 stays usable)" "$got" "$want"
    row_close; }

# =========================== P — the primitive itself ======================
echo; echo "== P. _paste-deliver.sh — the normaliser's tiers =="
if (( HAVE_PD )); then
    # shellcheck source=/dev/null
    . "$MON/_paste-deliver.sh"
    nrm() { printf '%b' "$1" > "$WORK/n.in"; pd_normalise_file "$WORK/n.in" "$WORK/n.out"; hexof "$WORK/n.out"; }
    hx()  { printf '%b' "$1" | od -An -tx1 | tr -d ' \n'; }
    eq P-zwsp     "ZWSP flanked by ASCII is removed"                 "$(nrm 'a\xe2\x80\x8bb')"              "$(hx 'ab')"
    eq P-thai     "ZWSP between Thai letters is KEPT (2.1.278 keeps it; measured SENT)" \
                                                                     "$(nrm '\xe0\xb8\x81\xe2\x80\x8b\xe0\xb8\x82')" "$(hx '\xe0\xb8\x81\xe2\x80\x8b\xe0\xb8\x82')"
    eq P-zwj      "a ZWJ emoji sequence is KEPT"                     "$(nrm '\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9')" "$(hx '\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9')"
    eq P-vs16     "VS16 after an emoji is KEPT"                      "$(nrm 'w \xe2\x9a\xa0\xef\xb8\x8f k')" "$(hx 'w \xe2\x9a\xa0\xef\xb8\x8f k')"
    eq P-mixed    "tier C on a line with ANY other non-ASCII is left for layer 1 (under-strip, never over-strip)" \
                                                                     "$(nrm 'a\xe2\x80\x8bb \xe2\x9c\x93')" "$(hx 'a\xe2\x80\x8bb \xe2\x9c\x93')"
    eq P-shy      "soft hyphen (tier U) is removed even on a non-ASCII line" "$(nrm 'caf\xc3\xa9 hy\xc2\xadphen')" "$(hx 'caf\xc3\xa9 hyphen')"
    eq P-bom      "a leading BOM is removed"                         "$(nrm '\xef\xbb\xbfhello')"           "$(hx 'hello')"
    eq P-tag      "a stray tag character is removed"                 "$(nrm 'g\xf3\xa0\x81\x81h')"          "$(hx 'gh')"
    eq P-ls       "U+2028 becomes LF, as 2.1.278 maps it"            "$(nrm 'a\xe2\x80\xa8b')"              "$(hx 'a\nb')"
    eq P-perline  "the ASCII-line test is PER LINE"                  "$(nrm 'a\xe2\x80\x8bb\n\xe0\xb8\x81\xe2\x80\x8b\xe0\xb8\x82\n')" "$(hx 'ab\n\xe0\xb8\x81\xe2\x80\x8b\xe0\xb8\x82\n')"
    eq P-nonl     "no trailing newline is invented"                  "$(nrm 'plain')"                       "$(hx 'plain')"
    # your-org/nexus-code#1597: LEADING blank lines are dropped — the one stated
    # exception to "never over-strips" (2.1.278 records that newline; with it the
    # glyph row is empty and pane-state cannot see the payload at all).
    eq N97-lead.strip    "leading empty and space/TAB-only lines are dropped"        "$(nrm '\n \t\nfoo\n')" "$(hx 'foo\n')"
    eq N97-lead.allblank "CONTROL: a payload of ONLY blank lines is left byte-identical (fail-open)" "$(nrm '\n\n \n')" "$(hx '\n\n \n')"
    eq N97-lead.inner    "CONTROL: an INNER blank line is kept"                      "$(nrm 'a\n\nb')"       "$(hx 'a\n\nb')"
    eq P-ctl      "control: CR, ESC and TAB are NOT touched (measured SENT on 2.1.278)" "$(nrm 'a\r\nb\033[1mc\td')" "$(hx 'a\r\nb\033[1mc\td')"
    eq P-latin    "control: ordinary non-ASCII text is untouched"    "$(nrm 'na\xc3\xafve \xe2\x80\x94 ok')" "$(hx 'na\xc3\xafve \xe2\x80\x94 ok')"

    # THE TIER TABLES AGAINST THE CODE POINTS, derived independently of the byte
    # ranges in the primitive: python encodes each code point, the normaliser is
    # asked about `a<cp>b`, and the answer must be `ab` for every member of the
    # union and UNCHANGED for the neighbours just outside each range.
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$WORK/cp" <<'PY'
import sys
U=[0xAD,0x115F,0x1160]+list(range(0x202A,0x202F))+list(range(0x2060,0x2070))+[0x3164]+list(range(0xFE03,0xFE0E))+[0xFEFF,0xFFA0]+list(range(0xFFF0,0xFFFC))+[0x16FE4]+list(range(0x1D173,0x1D17B))+list(range(0xE0080,0xE1000))
C=[0x34F,0x61C,0x17B4,0x17B5]+list(range(0x180B,0x1810))+list(range(0x200B,0x2010))+[0xFE00,0xFE01,0xFE02,0xFE0E,0xFE0F,0x1107F]+list(range(0x13430,0x13440))+list(range(0x1BCA0,0x1BCA4))+list(range(0xE0000,0xE0080))
members=set(U)|set(C)
outside=sorted({c+d for c in members for d in (-1,1)}-members-{0x2028,0x2029})
outside=[c for c in outside if c>0x7F and not (0xD800<=c<=0xDFFF)]
with open(sys.argv[1]+'.in','wb') as f:
    for c in sorted(members): f.write(b'a'+chr(c).encode('utf-8')+b'b\n')
with open(sys.argv[1]+'.out','wb') as f:
    for c in outside: f.write(b'a'+chr(c).encode('utf-8')+b'b\n')
open(sys.argv[1]+'.n','w').write('%d %d\n'%(len(members),len(outside)))
PY
        py_rc=$?
        read -r n_in n_out < "$WORK/cp.n" 2>/dev/null || { n_in=0; n_out=0; }
        if (( py_rc != 0 || n_in < 3900 || n_out < 20 )); then
            fail P-table.rig "the code-point table did not generate (python rc=$py_rc, members=$n_in, outside=$n_out) — a short table would pass vacuously"
        else
            rm -f "$WORK/cp.in.n"
            pd_normalise_file "$WORK/cp.in" "$WORK/cp.in.n"
            # COUNT THE GOOD LINES, NEVER THE BAD ONES. The first cut asserted
            # `grep -vcx ab` == 0, and a normaliser that produced NO OUTPUT AT
            # ALL satisfied it: zero bad lines in a file that did not exist.
            # Found by mutation (M4). The population is n_in, so the assertion
            # is that exactly n_in lines read `ab`.
            good=$(LC_ALL=C command grep -cx 'ab' "$WORK/cp.in.n" 2>/dev/null) || good=0
            eq P-table.members "every one of the $n_in tier-U/C code points is removed from an ASCII line" "${good:-0}" "$n_in"
            pd_normalise_file "$WORK/cp.out" "$WORK/cp.out.n"
            if cmp -s "$WORK/cp.out" "$WORK/cp.out.n"; then pass P-table.outside "all $n_out code points ADJACENT to a tier range are untouched (no range is one too wide)"
            else fail P-table.outside "a code point just OUTSIDE a tier range was altered — a byte range is too wide"; fi
        fi
    else
        na P-table.members "python3 not on PATH"; na P-table.outside "python3 not on PATH"
    fi

    # THE ONE DELIVERY PATH THAT DOES NOT GO THROUGH THE PRIMITIVE, and why it
    # may not: monitor/watcher/_fs_guard.sh types its read-only-filesystem alert
    # with `send-keys -l` + one Enter, because the primitive stages the body in
    # a FILE and that alert fires precisely when no file can be written. It is
    # the last resort behind every out-of-band channel, and its text is fixed
    # and nexus-authored — so what has to hold is that the text can never be
    # HELD: no tier-U/C byte anywhere in that file. Same check for _unstick.sh,
    # whose pasted lines are fixed text too. The normaliser being the identity
    # on a file is exactly "this file carries none of them".
    for _f in watcher/_fs_guard.sh watcher/_unstick.sh; do
        pd_normalise_file "$MON/$_f" "$WORK/ident.out"
        if [[ -s "$MON/$_f" ]] && cmp -s "$MON/$_f" "$WORK/ident.out"; then
            pass "P-fixedtext.${_f##*/}" "$_f carries no invisible-class byte, so its fixed texts cannot be held for review"
        else
            fail "P-fixedtext.${_f##*/}" "$_f carries an invisible-class byte (or is empty) — a fixed text pasted from it would be HELD on Claude Code >= 2.1.277"
        fi
    done

    # The ONE paste-buffer site, and the bytes are never argv. Both predicates
    # take a ROOT, so the same code that clears the real tree is shown CATCHING a
    # planted violation below — a scan never seen to fail is not evidence.
    _pdt_paste_sites() {   # <root> -> file:line of every executable paste-buffer
        _pdt_prod_shell_files "$1" \
            | while IFS= read -r f; do command grep -E 'paste-buffer' "$1/$f" | command grep -vE '^[[:space:]]*#' \
            | command grep -vE '^[[:space:]]*(die|echo|printf|log|warn|fail|unstick_log|_[a-z_]*log)[[:space:]]' | sed "s|^|$f:|"; done
    }
    _pdt_argv_sites() {    # <root> -> file:line of every production `tmux … set-buffer`
        _pdt_prod_shell_files "$1" | command grep -v '/cc-harness/' \
            | while IFS= read -r f; do command grep -nE '^[^#]*tmux[^#|]* set-buffer' "$1/$f" | sed "s|^|$f:|"; done
    }
    # _pd_would_collapse against the binary's REPL-path rule: length AFTER each TAB
    # became four spaces, compared with 800 (pastesk F13). The predicate may say
    # "would" for a payload the binary shows as text; it must never say "would not"
    # for one the binary collapses.
    wc_of() { printf '%s' "$1" > "$WORK/wc.in"; if _pd_would_collapse "$WORK/wc.in" 0; then echo would; else echo would-not; fi; }
    xs() { printf 'x%.0s' $(seq 1 "$1"); }
    eq P-collapse.tab   "700 bytes plus 80 TABs is 940 to the binary: WOULD collapse"      "$(wc_of "$(xs 620)$(printf '\t%.0s' $(seq 1 80))")" would
    eq P-collapse.edge  "797 chars and ONE TAB is 801 to the binary: WOULD collapse"        "$(wc_of "$(xs 797)"$'\t')" would
    eq P-collapse.under "CONTROL: 796 chars and one TAB is exactly 800: would NOT collapse" "$(wc_of "$(xs 796)"$'\t')" would-not
    eq P-collapse.notab "CONTROL: no TAB — 800 would not, 801 would"                        "$(wc_of "$(xs 800)"):$(wc_of "$(xs 801)")" "would-not:would"
    n_sites=$(_pdt_paste_sites "$ROOT")
    eq P-onesite "exactly ONE executable paste-buffer under monitor/, in the primitive" \
        "$(printf '%s\n' "$n_sites" | command grep -c .):$(printf '%s\n' "$n_sites" | cut -d: -f1 | sort -u | tr '\n' ' ')" "1:monitor/_paste-deliver.sh "
    # Captured, then tested — never `… | grep -q` as the condition: an early-exit
    # reader under pipefail hands the WRITER's EPIPE to the `if` (#622).
    argv_sites=$(_pdt_argv_sites "$ROOT")
    if [[ -n "$argv_sites" ]]; then
        fail P-noargv "a production script still hands paste bytes to tmux as an ARGV element (set-buffer) — #1590: $argv_sites"
    else pass P-noargv "no production script hands paste bytes to tmux as an argv element (#1590)"; fi

    # POSITIVE CONTROLS: a fixture repository with a SECOND paste site and an
    # argv payload planted in it. `git add` and no commit — the enumerator is
    # `git ls-files`, which reads the index.
    PLANT="$WORK/plant-repo"; mkdir -p "$PLANT/monitor/watcher"
    git init -q "$PLANT" 2>/dev/null
    th_require_fixture_repo "$PLANT"
    printf '#!/usr/bin/env bash\npd_paste_file() { tmux paste-buffer -p -d -b "$1" -t "$2"; }\n' > "$PLANT/monitor/_paste-deliver.sh"
    printf '#!/usr/bin/env bash\n# a comment naming tmux paste-buffer is not a site\nsneak() { [ -n "$1" ] && tmux paste-buffer -p -b "$1" -t x; }\n' > "$PLANT/monitor/watcher/grown.sh"
    printf '#!/usr/bin/env bash\nold() { tmux set-buffer -b "$BUF" -- "$MSG"; }\n' > "$PLANT/monitor/argv.sh"
    git -C "$PLANT" add -A 2>/dev/null
    plant_sites=$(_pdt_paste_sites "$PLANT" | cut -d: -f1 | sort -u | tr '\n' ' ')
    eq P-plant.site "a PLANTED second paste-buffer site is flagged, by file — and the comment beside it is not" \
        "$plant_sites" "monitor/_paste-deliver.sh monitor/watcher/grown.sh "
    plant_argv=$(_pdt_argv_sites "$PLANT" | cut -d: -f1 | tr '\n' ' ')
    eq P-plant.argv "a PLANTED set-buffer argv payload is flagged (#1590)" "$plant_argv" "monitor/argv.sh "
else
    na P-all "SUBJECT_ROOT has no monitor/_paste-deliver.sh — the primitive rows do not apply to this tree"
fi

echo
printf '== %s n/a ==\n' "$NA"

# ---- assertion-count guard (count=exact, summary-honesty) -------------------
# The ledger certifies that SOMETHING was asserted and no FAIL was lost to a
# subshell; only an exact count makes a VANISHED assertion redden. The total is
# a property of the SUBJECT: a tree with no primitive answers n/a for the rows
# that need one (73 counted), and the two code-point-table rows need python3.
# The #1674 draft/ghost rows add 11, of which 2 need the primitive: 145 -> 156,
# 100 -> 109. The #1683 F1 mid-turn rows add 9, of which 1 needs it: 156 -> 165,
# 109 -> 117. The #1683 F2 deferral rows add 9, all needing it: 165 -> 174.
# The #1729 input-region rows add 9, all needing it: 174 -> 183.
EXPECTED_ASSERTIONS=183
(( HAVE_PD )) || EXPECTED_ASSERTIONS=117
if (( HAVE_PD )) && ! command -v python3 >/dev/null 2>&1; then EXPECTED_ASSERTIONS=$(( EXPECTED_ASSERTIONS - 2 )); fi
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
# ONE physical line, deliberately: the summary-honesty classifier reads
# `count=exact` off the `assert_eq` prefix and the EXPECTED operand on the SAME line.
assert_eq "assertion TOTAL matches EXPECTED_ASSERTIONS — no assertion silently dropped or added" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
