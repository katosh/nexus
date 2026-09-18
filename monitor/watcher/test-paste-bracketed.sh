#!/usr/bin/env bash
# Regression test for the bracketed-paste fix in monitor/paste-followup.sh
# (your-org/nexus-code#521).
#
# Run: bash monitor/watcher/test-paste-bracketed.sh
# Expected: ALL TESTS PASSED on stdout, exit 0. Skips loudly if tmux absent.
#
# Background: `paste-followup.sh` pasted multi-line follow-ups WITHOUT `-p`,
# so tmux replaced each embedded linefeed with its separator (CR) and the
# newline reached the Claude REPL as an Enter — the first line submitted
# alone, the rest stranded. The fix is `tmux paste-buffer -p …`: `-p` wraps
# the buffer in bracketed-paste control codes (`ESC[200~ … ESC[201~`) IFF the
# receiving application has requested bracketed-paste mode (mode ?2004), so
# the whole message arrives as one literal paste and the newline is text.
#
# These tests drive a REAL isolated tmux server (`tmux -L`, never the
# operator's) and capture what a pane actually receives, proving:
#   1. app requested mode ?2004 + `-p` → bytes ARE wrapped (the fix works,
#      verified on the deployed tmux 2.6);
#   2. same pane, NO `-p` (the pre-fix call) → NOT wrapped (the bug);
#   3. app did NOT request mode ?2004 + `-p` → NOT wrapped (safe-by-
#      construction: `-p` is inert unless the app opted in, so it can never
#      regress a non-bracketed consumer);
#   4. source guard: paste-followup.sh's paste-buffer call carries `-p`;
#   5. main.sh's EMIT paste (`_paste_to_target_unlocked`, the watcher's paste
#      into the orchestrator) is bracketed too, and its submit Enter arrives
#      after the closing ESC[201~ — driven through the real function;
#   6. _unstick.sh's single-line paste (`_paste_line_to_window`) likewise.
#
# The ?2004h must be parsed by tmux BEFORE the paste. The original fixture
# guessed at that with `sleep 1.2`, which is not a synchronisation primitive:
# the pane shell was the operator's LOGIN shell, and on a loaded sandbox host
# its rc chain (Lmod/lua, conda, linuxbrew) took ~6 s to reach the first
# instruction — so every attempt, retries included, pasted into a pane that
# had not yet emitted ?2004h, `-p` correctly declined to wrap, and assertion 1
# failed 100% of the time while 2 and 3 passed VACUOUSLY on an empty capture.
# Two changes make it deterministic (your-org/nexus-code#555):
#   * a hermetic fixture shell (th_tmux_fixture_conf) — a bare `sh`, no rc
#     files, ready in ~0.2 s;
#   * a real happens-before edge — the pane prints a RDY sentinel immediately
#     AFTER the ?2004h and we poll capture-pane for it. tmux parses a pane's
#     byte stream in order, so seeing RDY proves ?2004h is already parsed.
# The negative assertions now also require the payload to have ARRIVED, so an
# empty capture reads as a failure instead of a pass.

set -uo pipefail

_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MONITOR_DIR=$(cd "$_script_dir/.." && pwd)
PASTE="$MONITOR_DIR/paste-followup.sh"
# shellcheck source=/dev/null
. "$_script_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

command -v tmux >/dev/null 2>&1 || { echo "skipped: tmux not on PATH"; exit 77; }   # SKIP (#568 A6)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TCONF="$WORK/tmux.conf"
th_tmux_fixture_conf "$TCONF"

# ESC[200~ = 1b 5b 32 30 30 7e ; ESC[201~ = 1b 5b 32 30 31 7e
OPEN_HEX='1b5b3230307e'
CLOSE_HEX='1b5b3230317e'
# 'lineB' — the payload's LAST line. Present iff the whole paste landed.
PAYLOAD_HEX='6c696e6542'

# Capture the bytes a pane receives from a paste.
#   $1 = "on"|"off"  — whether the pane requests bracketed-paste mode ?2004
#   $2 = extra paste-buffer flags (e.g. "-p")
# Echoes the hex of the received bytes.
capture() {
    local mode="$1" flags="$2"
    local sock="pb-$$-${RANDOM}" out="$WORK/out-${RANDOM}"; : > "$out"
    # your-org/nexus-code#991: measure the socket path BEFORE tmux is asked to
    # bind it. A too-long TMUX_TMPDIR is an ENVIRONMENT fault, not a defect in
    # the code under test, and without this it presents as one.
    th_require_tmux_socket "$sock"
    local enable=""
    [[ "$mode" == "on" ]] && enable='printf "\033[?2004h"; '
    local p
    # RDY is printed AFTER the ?2004h, so tmux having rendered RDY proves it
    # already parsed the mode-set. `stty raw -echo` keeps the pasted bytes off
    # the screen, so RDY can only come from the pane's own printf.
    p=$(tmux -L "$sock" -f "$TCONF" new-session -d -P -F '#{pane_id}' -x 80 -y 24 \
        "sh -c 'stty raw -echo; ${enable}printf \"RDY\r\n\"; dd of=$out bs=1 2>/dev/null'") \
        || { echo ""; return; }
    if ! th_tmux_wait_pane tmux -L "$sock" -- "$p" RDY 30; then
        tmux -L "$sock" kill-server 2>/dev/null
        echo ""; return
    fi
    tmux -L "$sock" set-buffer -b B -- "$(printf 'lineA\nlineB')" 2>/dev/null
    # shellcheck disable=SC2086
    tmux -L "$sock" paste-buffer $flags -d -b B -t "$p" 2>/dev/null
    # dd is byte-at-a-time; wait for the payload to land rather than guessing.
    local deadline=$(( SECONDS + 15 ))
    while (( SECONDS < deadline )); do
        grep -q 'lineB' "$out" 2>/dev/null && break
        sleep 0.1
    done
    tmux -L "$sock" send-keys -t "$p" C-d 2>/dev/null; sleep 0.3
    tmux -L "$sock" kill-server 2>/dev/null
    od -An -tx1 "$out" 2>/dev/null | tr -d ' \n'
}

echo "== tmux $(tmux -V) =="

# ---- capability gate (deliberately NOT a version gate) ---------------------
#
# Assertions 1-3 exercise `paste-buffer -p`, the bracketed-paste flag. On a
# tmux that does not HAVE that flag, the mechanism under test does not exist
# and a hard failure would be noise, not signal. Detect the capability
# directly instead of pinning a version number: tmux rejects an unknown flag
# with `unknown option` + a `usage:` line, whereas a supported flag reaches
# the buffer lookup and reports `no buffer`.
#
# Capability detection is strictly safer than a version threshold — a
# threshold is a guess that can silently skip a tmux which does support `-p`,
# hiding a real regression. This probe skips ONLY when the flag is genuinely
# absent.
#
# On the deployed tmux 2.6 `-p` IS supported and all four assertions pass, so
# this gate is inert here (your-org/nexus-code#555). It exists so the suite
# degrades honestly on some other tmux, not to paper over anything on ours.
paste_p_supported() {
    local sock="pbcap-$$-${RANDOM}" out
    # your-org/nexus-code#991: measure the socket path BEFORE tmux is asked to
    # bind it. A too-long TMUX_TMPDIR is an ENVIRONMENT fault, not a defect in
    # the code under test, and without this it presents as one.
    th_require_tmux_socket "$sock"
    tmux -L "$sock" -f "$TCONF" new-session -d -x 80 -y 24 'sleep 30' 2>/dev/null || return 0
    out=$(tmux -L "$sock" paste-buffer -p -b __nexus_probe__ 2>&1)
    tmux -L "$sock" kill-server 2>/dev/null
    [[ "$out" == *"unknown option"* || "$out" == *"usage:"* ]] && return 1
    return 0
}

if paste_p_supported; then

# Every case below asserts on a capture that MUST contain the payload. An
# empty capture (pane never started, server died) used to satisfy all three
# "is NOT wrapped" assertions vacuously; now it is a loud failure with the
# hex printed, so a broken fixture can never masquerade as a green test.
assert_paste() {
    local label="$1" mode="$2" flags="$3" want="$4"   # want = wrapped|plain
    local hex; hex=$(capture "$mode" "$flags")
    if [[ "$hex" != *"$PAYLOAD_HEX"* ]]; then
        fail "$label — payload never reached the pane (fixture broken, hex='$hex')"
        return
    fi
    if [[ "$want" == wrapped ]]; then
        if [[ "$hex" == *"$OPEN_HEX"* && "$hex" == *"$CLOSE_HEX"* ]]; then
            pass "$label"
        else
            fail "$label — payload arrived UNWRAPPED (hex='$hex')"
        fi
    else
        if [[ "$hex" != *"$OPEN_HEX"* && "$hex" != *"$CLOSE_HEX"* ]]; then
            pass "$label"
        else
            fail "$label — payload arrived WRAPPED (hex='$hex')"
        fi
    fi
}

    # 1. app requested ?2004 + -p → wrapped (the fix works)
    assert_paste "app requested mode ?2004 + '-p' → paste is bracketed (ESC[200~ … ESC[201~)" \
                 on "-p" wrapped

    # 2. same pane, NO -p (the pre-fix call) → not wrapped (the bug)
    assert_paste "no '-p' → paste is NOT bracketed (reproduces the pre-fix bug)" \
                 on "" plain

    # 3. app did NOT request ?2004 + -p → not wrapped (safe-by-construction)
    assert_paste "'-p' on a pane that did NOT request mode ?2004 → inert (no regression risk)" \
                 off "-p" plain

    # 5. main.sh's EMIT paste — the watcher's own paste into the orchestrator.
    #    #521 fixed paste-followup.sh only; main.sh's _paste_to_target_unlocked
    #    kept the unbracketed form. Unbracketed, the REPL can only infer a paste
    #    from bytes arriving together, and the body's newlines and the submit
    #    Enter are the same byte (CR), so a REPL that reads the paste and the
    #    Enter in one chunk folds the Enter into the paste and the emit is
    #    stranded, unsubmitted, in the input box. Measured against the real
    #    claude 2.1.248/2.1.261/2.1.268 in the cc-harness (w235 probe): paste
    #    and Enter delivered back to back -> not submitted (a single-line body
    #    with no newline too), while the function's content check still
    #    returns 0. Bracketed, the submit CR arrives AFTER ESC[201~ and is a
    #    keypress by construction, however the bytes are chunked. Drives the
    #    REAL function (extracted from main.sh, as
    #    test-target-config.sh does) into a pane that requested mode ?2004 and
    #    records the bytes it receives.
    # 6. _unstick.sh's _paste_line_to_window, which the unstick cascade uses to
    #    paste one line (no newline) into the orchestrator and into workers:
    #    Enter 0.1 s later, and NO submit check at all. The same late read
    #    strands it on the real binary (your-org/nexus-code#1516), and a strand
    #    there reads `user-typing input=typed`, which the watcher treats as an
    #    operator draft. Same byte-level precondition as 5.
    #
    # drive_paste_hex <sock> <driver>: a private pane that requested mode ?2004,
    # in a window named `orchestrator`. <driver> runs in a subshell in which
    # every bare `tmux` (the function's own AND the dead-pane guard's) goes to
    # THIS private server and nowhere else. Prints the hex of every byte the
    # pane received, up to a trailing sentinel; the driver's rc lands in
    # $WORK/drv-rc.
    # The socket-path check is HOISTED into the main shell: th_require_tmux_socket
    # EXITS on refusal, and reached from inside `$(drive_paste_hex …)` that exit
    # would end only the subshell, turning an environment refusal into a
    # "fixture broken" FAIL (your-org/nexus-code#1339).
    drive_paste_hex() {
        local sock="$1" driver="$2" out="$WORK/drv-${RANDOM}"
        : > "$out"; : > "$WORK/drv-rc"
        local p
        p=$(tmux -L "$sock" -f "$TCONF" new-session -d -s emit -n orchestrator -P -F '#{pane_id}' -x 80 -y 24 \
            "sh -c 'stty raw -echo; printf \"\033[?2004h\"; printf \"RDY\r\n\"; dd of=$out bs=1 2>/dev/null'") \
            || { echo ""; return; }
        if ! th_tmux_wait_pane tmux -L "$sock" -- "$p" RDY 30; then
            tmux -L "$sock" kill-server 2>/dev/null
            echo ""; return
        fi
        (
            set +u
            tmux() { command tmux -L "$sock" "$@"; }
            . "$MONITOR_DIR/_pane-live.sh"
            . "$MONITOR_DIR/_tmux-window.sh"
            "$driver"
            printf '%s' "$?" > "$WORK/drv-rc"
        )
        # Happens-before edge, not a sleep: tmux writes pane input in order, so
        # once this sentinel has reached dd, every byte the function sent —
        # the Enter included — has too.
        tmux -L "$sock" send-keys -l -t "$p" ZZEND 2>/dev/null
        local deadline=$(( SECONDS + 15 ))
        while (( SECONDS < deadline )); do
            grep -q 'ZZEND' "$out" 2>/dev/null && break
            sleep 0.1
        done
        tmux -L "$sock" send-keys -t "$p" C-d 2>/dev/null; sleep 0.3
        tmux -L "$sock" kill-server 2>/dev/null
        od -An -tx1 "$out" 2>/dev/null | tr -d ' \n'
    }
    # The drivers eval each function straight out of its production file. An
    # extraction that comes back EMPTY leaves the name undefined, the call
    # returns 127, and the rc check below reports "never pasted" — loud.
    drive_emit() {
        log() { :; }
        _orchestrator_refresh_pin() { :; }
        _orchestrator_record_paste() { :; }
        printf 'lineA\nlineB\n--- nexus-emit-sig 2026-01-01T00:00:00+00:00 0a0b0c ---\n' > "$WORK/emit-body.md"
        eval "$(sed -n '/^_paste_to_target_unlocked() {/,/^}/p' "$MONITOR_DIR/watcher/main.sh")"
        _paste_to_target_unlocked orchestrator "$WORK/emit-body.md" >/dev/null 2>&1
    }
    drive_line() {
        eval "$(sed -n '/^_paste_line_to_window() {/,/^}/p' "$MONITOR_DIR/watcher/_unstick.sh")"
        _paste_line_to_window orchestrator "ZZline please continue" >/dev/null 2>&1
    }
    SENTINEL_HEX='5a5a454e44'
    esock="pbemit-$$-${RANDOM}"
    th_require_tmux_socket "$esock"
    ehex=$(drive_paste_hex "$esock" drive_emit)
    erc=$(cat "$WORK/drv-rc" 2>/dev/null)
    if [[ "$ehex" != *"$PAYLOAD_HEX"*"$SENTINEL_HEX"* ]]; then
        fail "main.sh emit paste — payload or sentinel never reached the pane (fixture broken; fn rc='$erc', hex='$ehex')"
    elif [[ "$erc" != 0 && "$erc" != 4 ]]; then
        # rc 0/4 both mean the paste and the Enter were SENT (4 = the content
        # check saw no signature, which is right for this echo-less pane). Any
        # other rc means the function refused before pasting, and the byte
        # assertions below would be about nothing.
        fail "main.sh emit paste — _paste_to_target_unlocked returned rc '$erc', so it never pasted (fixture, not verdict)"
    else
        if [[ "$ehex" == *"$OPEN_HEX"*"$PAYLOAD_HEX"*"$CLOSE_HEX"* ]]; then
            pass "main.sh _paste_to_target_unlocked pastes the emit BRACKETED (ESC[200~ … ESC[201~)"
        else
            fail "main.sh _paste_to_target_unlocked pastes the emit UNBRACKETED — its newlines and its submit Enter are the same byte (hex='$ehex')"
        fi
        erest="${ehex##*"$CLOSE_HEX"}"
        if [[ "$ehex" == *"$CLOSE_HEX"* && "$erest" == 0d*"$SENTINEL_HEX"* ]]; then
            pass "main.sh emit paste — the submit Enter (CR) arrives AFTER ESC[201~, so no chunking can fold it into the paste"
        else
            fail "main.sh emit paste — no CR after a closing ESC[201~: the submit Enter is indistinguishable from a pasted newline (hex='$ehex')"
        fi
    fi

    # 6. (see the comment above drive_paste_hex)
    LINE_HEX='5a5a6c696e65'   # 'ZZline' — present iff the pasted line landed
    lsock="pbline-$$-${RANDOM}"
    th_require_tmux_socket "$lsock"
    lhex=$(drive_paste_hex "$lsock" drive_line)
    lrc=$(cat "$WORK/drv-rc" 2>/dev/null)
    if [[ "$lhex" != *"$LINE_HEX"*"$SENTINEL_HEX"* ]]; then
        fail "_unstick.sh line paste — the line or the sentinel never reached the pane (fixture broken; fn rc='$lrc', hex='$lhex')"
    elif [[ "$lrc" != 0 ]]; then
        # _paste_line_to_window returns 1 for every refusal and every tmux
        # failure; only 0 means the paste and the Enter were sent.
        fail "_unstick.sh line paste — _paste_line_to_window returned rc '$lrc', so it never pasted (fixture, not verdict)"
    else
        if [[ "$lhex" == *"$OPEN_HEX"*"$LINE_HEX"*"$CLOSE_HEX"* ]]; then
            pass "_unstick.sh _paste_line_to_window pastes the line BRACKETED (ESC[200~ … ESC[201~)"
        else
            fail "_unstick.sh _paste_line_to_window pastes the line UNBRACKETED — a late read folds its Enter into the paste (hex='$lhex')"
        fi
        lrest="${lhex##*"$CLOSE_HEX"}"
        if [[ "$lhex" == *"$CLOSE_HEX"* && "$lrest" == 0d*"$SENTINEL_HEX"* ]]; then
            pass "_unstick.sh line paste — the submit Enter (CR) arrives AFTER ESC[201~"
        else
            fail "_unstick.sh line paste — no CR after a closing ESC[201~: the submit Enter can be taken as part of the paste (hex='$lhex')"
        fi
    fi
else
    printf '  SKIP: tmux %s has no `paste-buffer -p` — the bracketed-paste\n' "$(tmux -V)"
    printf '        mechanism does not exist on it; assertions 1-3 are unrunnable.\n'
    printf '        The source guard below still runs (version-independent).\n'
fi

# 4. source guard: the fix is present in paste-followup.sh. Deliberately
#    OUTSIDE the capability gate — it is a pure source grep, so it holds the
#    regression line on every tmux, including one that cannot run 1-3.
if grep -Eq 'tmux paste-buffer[^|]*-p' "$PASTE"; then
    pass "paste-followup.sh calls paste-buffer with '-p'"
else
    fail "paste-followup.sh paste-buffer call lost its '-p' flag (regression)"
fi

# 7. THE POPULATION GUARD, and it is the part that makes 4/5/6 more than three
#    spot checks: EVERY executable `tmux paste-buffer` in `monitor/` must carry
#    `-p`. Enumerated rather than listed, for `test-paste-dead-pane-guard.sh`'s
#    stated reason one hazard over — "a rule applied to the sites somebody
#    happened to be editing is not applied" — and this file is the proof that
#    the reason is not theoretical: `#521` bracketed `paste-followup.sh` and
#    left `main.sh`; `#1516` bracketed those two and left `_respawn.sh`, which
#    was believed covered by `#1514`'s branch and measured NOT to be on any ref
#    (`paste-buffer -p` count 0 in `_respawn.sh` at `origin/dev` 4f73e0e7,
#    `origin/main` 0a76c4d5, `81c38b39` and `da1b54c3` — skeptic `w236sk` F3,
#    your-org/nexus-code#1518).
#
#    `_respawn.sh`'s site is the worst of the four: it pastes the RESPAWN
#    PROMPT and has NO content check, so a strand there is an orchestrator
#    respawned, never briefed, and reported respawned — a MANUFACTURED success,
#    where every visible artefact says the work was done.
#
#    A FIFTH site is therefore LOUD rather than silent. The enumeration is
#    `git ls-files` over `monitor/` — tracked files, stated because an untracked
#    new script is invisible to it (`#1054`) — filtered to executable call lines,
#    and it deliberately does NOT use a glob pathspec: git's `*` crosses `/`
#    (`#954`), so `:(glob)` or a plain directory prefix is the honest form.
#    Comment lines and quoted occurrences are excluded by requiring the line to
#    begin with the call.
echo
echo "== 7. population guard: every executable paste-buffer in monitor/ is bracketed =="
_PB_ROOT=$(cd "$MONITOR_DIR/.." && pwd)
_pb_unbracketed=0
_pb_total=0
while IFS= read -r _pb_f; do
    [[ -r "$_PB_ROOT/$_pb_f" ]] || continue
    while IFS= read -r _pb_line; do
        _pb_total=$(( _pb_total + 1 ))
        # A STRING MENTION IS NOT AN INVOCATION, and the exemption list is a
        # DENYLIST whose default is REQUIRE — the opposite polarity from this
        # repo's kill gates, and correct here for a stateable reason: a false
        # positive costs one `-p` on a line nobody executes, or a reworded
        # message; a false NEGATIVE is an unbracketed paste into the operator's
        # pane. So anything this cannot classify is treated as an invocation.
        #
        # The one measured mention is `paste-followup.sh`'s
        # `die "tmux paste-buffer failed for window $WINDOW"`. Note the
        # exemption keys on the MESSAGE VERB at line start, not on the presence
        # of a quote: w237sk's evasion case
        # `[ -n "$1" ] && tmux paste-buffer …` also carries a quote before
        # `tmux`, and a quote-based rule would have exempted exactly the
        # construct this widening exists to catch.
        if grep -Eq '^[[:space:]]*(die|echo|printf|log|warn|fail|unstick_log|_[a-z_]*log)[[:space:]]' <<<"$_pb_line"; then
            _pb_total=$(( _pb_total - 1 ))
            continue
        fi
        if ! grep -Eq 'paste-buffer([[:space:]]+-[A-Za-z]+)*[[:space:]]+-p([[:space:]]|$)|paste-buffer[[:space:]]+-p' <<<"$_pb_line"; then
            printf '  FAIL: unbracketed paste-buffer in %s: %s\n' "$_pb_f" "${_pb_line#"${_pb_line%%[![:space:]]*}"}" >&2
            _pb_unbracketed=$(( _pb_unbracketed + 1 ))
        fi
    # KEYED ON `paste-buffer` ANYWHERE ON A NON-COMMENT LINE (skeptic w237sk F6).
    #
    # The first cut matched only line-start and `if`/`elif` heads, so a call
    # written mid-line evaded it entirely — w237sk appended
    #
    #     _evade() { [ -n "$1" ] && tmux paste-buffer -b "$1" -t x; }
    #
    # to `_respawn.sh` and the guard still reported `all 4 … carry '-p'`, total
    # unchanged. An `&&`-chained call, a `$TMUX`-variable call, or one inside
    # `eval` was invisible. The guard's stated purpose is that a FIFTH site is
    # loud; it was loud for two spellings.
    #
    # Comment lines are excluded by the `^[[:space:]]*#` filter rather than by
    # the match shape, which is what lets the match itself widen. Quoted
    # occurrences in prose are still counted — deliberately: a false positive
    # here costs one `-p` on a string nobody executes, while a false negative is
    # an unbracketed paste, and this file's own history is three missed sites.
    done < <(grep -E 'paste-buffer' "$_PB_ROOT/$_pb_f" 2>/dev/null | grep -vE '^[[:space:]]*#')
done < <(git -C "$_PB_ROOT" ls-files -- monitor 2>/dev/null | grep -E '\.sh$' | grep -v '/test-\|/fixtures/')
# A ZERO TOTAL IS NOT A PASS. If the enumeration finds no call sites at all, the
# guard has gone blind — a renamed directory, a changed call spelling, a `git
# ls-files` returning nothing in a worktree — and a blind guard reports green.
# Four sites are known to exist at this ref; fewer means the predicate stopped
# seeing them, not that the tree stopped having them.
# THE FLOOR IS DERIVED, NOT HARDCODED (skeptic w237sk F6). It used to be a
# literal `< 4` with the four filenames in the message, so the day a fifth site
# legitimately landed the floor was stale and a later 5 -> 4 drop would pass
# silently. The floor now comes from a recorded manifest, so a CHANGE in the
# population is what has to be acknowledged — and the manifest's own staleness
# is visible because it lists the files.
_pb_manifest="$_PB_ROOT/monitor/watcher/paste-buffer-sites.manifest"
_pb_floor=0
if [[ -r "$_pb_manifest" ]]; then
    # SUM THE COUNT COLUMN, not the row count. The first cut counted ROWS — i.e.
    # FILES — and compared that to a total counted in CALL SITES. Two different
    # units, and they happened to be equal (4 files, 4 sites), so the floor
    # passed while comparing nothing. A unit mismatch that coincides on today's
    # data is the worst kind: it reads as a working check.
    _pb_floor=$(awk -F'\t' '!/^[[:space:]]*#/ && NF>=2 {n+=$2} END{print n+0}' "$_pb_manifest" 2>/dev/null) || _pb_floor=0
fi
[[ "$_pb_floor" =~ ^[0-9]+$ ]] || _pb_floor=0
if (( _pb_floor == 0 )); then
    fail "no recorded paste-buffer site manifest at $_pb_manifest — the floor cannot be derived, and a guard whose floor is 0 vouches for any enumeration including an empty one"
elif (( _pb_total < _pb_floor )); then
    fail "population guard found $_pb_total paste-buffer call site(s); $_pb_floor are on record in $(basename "$_pb_manifest") — the ENUMERATION is blind, or a site was removed without updating the manifest. A blind guard reports green"
elif (( _pb_unbracketed == 0 )); then
    pass "all $_pb_total executable paste-buffer call sites in monitor/ carry '-p'"
else
    fail "$_pb_unbracketed of $_pb_total executable paste-buffer call sites in monitor/ are UNBRACKETED (listed above)"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
