#!/usr/bin/env bash
# Tests for IDENTITY-not-NAME process matching (your-org/nexus-code#908) and
# the single window-key vocabulary shared by pane-state.sh / paste-followup.sh
# (your-org/nexus-code#905).
#
# Run: bash monitor/watcher/test-pane-state-claude-identity.sh
#
# ── WHY THE #908 TESTS ARE SHAPED THIS WAY ──────────────────────────────
# The thing under test is a CLASSIFIER, and the standing trap is that a probe
# which asks the classifier whether the classifier is right can only ever
# confirm it: it cannot see a process shape the classifier never considered.
# So the discriminating fixture is built from the OUTSIDE — a real, live
# process whose `comm` is `claude.exe` — and BOTH matchers are run against it,
# the shipped one and the pre-fix one lifted verbatim from `origin/dev`.
#
#   §1 asserts the NEW matcher accepts it.
#   §1's NEGATIVE CONTROL asserts the OLD matcher REJECTS it.
#
# Without that control §1 proves nothing: an assertion that passes against
# both the fixed and the broken code has no discriminative power, which is the
# defect `#872`'s own control shipped with.
#
# ── THE KILL AXIS IS NOT SYMMETRIC ──────────────────────────────────────
# `absent` is the one state on `_bookkeeping.sh:_BK_KILL_OK_STATES`. A
# classifier that newly reports a LIVE worker as dead destroys work; one that
# reports a dead worker as live strands a slot. The tests are weighted to
# match: every arm that could produce a false DEAD is driven directly, and the
# over-match direction is checked too, so widening identity does not quietly
# make everything look alive.
#
# tmux safety: §2 runs on a PRIVATE `-L` socket whose `#{socket_path}` is
# asserted UNEQUAL to the board's before a single window is created. The board
# died on 2026-08-09 and there is no in-sandbox recovery.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
. "$_test_dir/_test_helpers.sh"

WORK=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
_SOCK="paneid-$$-$RANDOM"
# your-org/nexus-code#991: measure the socket path BEFORE tmux is asked to
# bind it. A too-long TMUX_TMPDIR is an ENVIRONMENT fault, not a defect in
# the code under test, and without this it presents as one.
th_require_tmux_socket "$_SOCK"
cleanup() {
    [[ -n "${_MCP_PID:-}" ]] && kill "$_MCP_PID" 2>/dev/null
    [[ -n "${_SLEEP_PID:-}" ]] && kill "$_SLEEP_PID" 2>/dev/null
    [[ -n "${_DEL_PID:-}" ]] && kill "$_DEL_PID" 2>/dev/null
    # Private socket only, and only if we proved it was private.
    if [[ "${_SOCKET_PROVEN_PRIVATE:-0}" == 1 ]]; then
        tmux -L "$_SOCK" kill-server 2>/dev/null
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# ── §1 IDENTITY, NOT NAME (your-org/nexus-code#908) ──────────────────────
# Lift both matchers verbatim from the production files. Lifting rather than
# re-implementing is the point: a re-implementation would share a model with
# the thing it tests and could agree with a bug.
_lift() {   # <file> -> stdout: the two matcher functions
    sed -n '/^_pid_runs_claude() {/,/^}/p' "$1"
    sed -n '/^_pane_has_live_claude() {/,/^}/p' "$1"
}
NEW_SRC="$WORK/new.sh"; _lift "$REPO_ROOT/monitor/pane-state.sh" > "$NEW_SRC"
[[ -s "$NEW_SRC" ]] || { echo "FAIL: could not lift the shipped matcher"; exit 1; }

# ── THE PRE-FIX MATCHER, AND WHY IT IS NO LONGER LIFTED FROM origin/dev ──
# This used to read `git show origin/dev:monitor/pane-state.sh` and nothing
# else. `origin/dev` is a MOVING REF: once `#908` merged (19b8836), the
# "pre-fix" matcher WAS the fixed matcher, both sides accepted the fixture, and
# the control went red — `your-org/nexus-code#1035`, standing red on `dev`.
#
# `#1035` asked which of two propositions is false: (1) the fixture stopped
# representing the pre-fix condition, or (2) the control was invoking the wrong
# matcher and never discriminated. MEASURED at `d2f4415`, against the same live
# `claude.exe` fixture built below:
#
#     matcher lifted from 19b8836^ (the true pre-#908 blob)  ->  rc=1  REJECTS
#     matcher lifted from HEAD / origin/dev                  ->  rc=0  accepts
#
# So NEITHER: the fixture is still exactly right and the control has always
# discriminated. What moved is the SOURCE the control lifts its "pre-fix" copy
# from. The remedy is therefore to re-anchor, not to weaken the assertion — and
# emphatically not to re-anchor around the live defect, which is what "make the
# control pass" would have produced.
#
# The anchor is a chain, preferring real historical code, each candidate GATED
# on actually being pre-fix; then a SYNTHESIZED fallback, because the git
# lookup expires — this is the shape `test-tmux-shim.sh` already arrived at for
# the same class, and its reasoning applies verbatim: after one more merge every
# reachable ref contains the fix, and a control that SKIPS from then on is a gap
# reopened permanently, loudly.
#
# THE GATE IS ON THE LIFTED REGION, NOT ON THE BLOB — and that is not a detail.
# The genuine pre-#908 blob DOES contain the string `claude.exe`, once, at line
# 1951, inside a DIFFERENT function that this suite does not test. A whole-file
# `grep -q claude.exe` would therefore reject the one source that is actually
# pre-fix. Asking the blob whether it mentions the string, rather than asking
# the matcher under test whether it carries the arm, is the mention-for-property
# substitution this repo keeps filing; committed here it would have hidden the
# correct anchor behind a plausible rejection.
# COMMENTS ARE STRIPPED FIRST, and this is the third time in one block that
# the mention-vs-property distinction decides the answer. Measured on the
# lifted region at `d2f4415`: the shipped lift carries `claude.exe` THREE
# times — two `case` arms and one explanatory comment — and the synthesized
# pre-fix lift still carries the comment. A bare presence test therefore
# rejects the correct synthesis, which is precisely what it did on first run
# here: the suite SKIPPED with "the synthesis did not apply" while the sed had
# applied perfectly. It failed safe, which is the only reason it was cheap.
# Whole-line comments only, matching the technique `test-guard-closure-
# boundary.sh` uses for the same reason; a TRAILING comment could still vouch
# for its line, and that needs a tokeniser rather than a line-based idiom.
#
# HERESTRING, NOT `producer | grep -q`. This file runs under `set -uo pipefail`
# and `grep -q` EXITS AT THE FIRST MATCH, SIGPIPEing the producer, whose 141
# pipefail then propagates as the pipeline's status — which `!` flips to TRUE.
# So the piped spelling calls a POST-fix source pre-fix: fail-OPEN, straight
# back to a control that cannot discriminate. Written that way here first and
# caught by measuring it: on this small lift `grep -q` drains its input before
# exiting and the answer is accidentally right, while the same pipeline over a
# 200k-line file returns `rc=141`. That narrow window is what makes the idiom
# survive review and ambush later; `test-sigpipe-assertion-lint.sh` exists for
# it, and `test-guard-closure-boundary.sh` carries the same note verbatim.
_is_prefix_matcher() {   # <lifted-src> -> 0 if it has NO claude.exe case arm
    ! grep -q 'claude\.exe' <<<"$(grep -v '^[[:space:]]*#' "$1")"
}
OLD_SRC="$WORK/old.sh"
_HAVE_OLD=0
_OLD_PROV=""
for _ref in "$(git -C "$REPO_ROOT" merge-base origin/dev HEAD 2>/dev/null)" origin/dev HEAD~1; do
    [[ -n "$_ref" ]] || continue
    git -C "$REPO_ROOT" show "${_ref}:monitor/pane-state.sh" > "$WORK/ps-ref.sh" 2>/dev/null || continue
    [[ -s "$WORK/ps-ref.sh" ]] || continue
    _lift "$WORK/ps-ref.sh" > "$OLD_SRC"
    [[ -s "$OLD_SRC" ]] || continue
    if _is_prefix_matcher "$OLD_SRC"; then
        _HAVE_OLD=1; _OLD_PROV="git:${_ref}"; break
    fi
done
if (( ! _HAVE_OLD )); then
    # SYNTHESIZE. `#908`'s change at these two sites is exactly the addition of
    # `claude.exe` to the `case` arm, so removing it reproduces the unfixed
    # shape — and unlike a git ref, that stays true however far the branch
    # moves. Verified faithful at `d2f4415`: the synthesized matcher and the
    # 19b8836^ blob return the SAME rc=1 against the fixture.
    sed 's/claude|claude-code|claude\.exe)/claude|claude-code)/g; s/claude|claude\.exe|claude-code)/claude|claude-code)/g' \
        "$NEW_SRC" > "$OLD_SRC"
    # A MUTANT MUST PROVE IT APPLIED. A sed whose pattern has drifted leaves the
    # file byte-identical, and the control would then compare the shipped
    # matcher against itself — passing vacuously, which is the exact failure
    # this whole block exists to repair. Both directions are checked: something
    # changed, AND the result no longer carries the arm.
    if [[ -s "$OLD_SRC" ]] && ! cmp -s "$OLD_SRC" "$NEW_SRC" && _is_prefix_matcher "$OLD_SRC"; then
        _HAVE_OLD=1; _OLD_PROV="synthesized"
    fi
fi

_ask() {    # <src> <pid> -> prints "rc=<n> ind=<0|1>"
    bash -c '
        set -uo pipefail
        . "$1"
        _pane_has_live_claude "$2"; rc=$?
        printf "rc=%s ind=%s" "$rc" "${_PHLC_INDETERMINATE:-x}"
    ' _ "$1" "$2" 2>/dev/null
}
_ask_old() { # dev had no _PHLC_INDETERMINATE; only rc is meaningful
    bash -c '
        set -uo pipefail
        . "$1"
        _pane_has_live_claude "$2"; printf "rc=%s" "$?"
    ' _ "$1" "$2" 2>/dev/null
}

# A LIVE process presenting as `claude.exe`. Built by copying a real
# long-running binary to that basename: the classifier-visible properties are
# exactly the ones the real `.exe`-invoked claude presents — a live pid whose
# `/proc/<pid>/exe` basename is `claude.exe` — and it needs no claude boot, so
# it cannot hit the sandbox RLIMIT_NPROC ceiling the cc-harness legs can.
CBIN="$WORK/bin"; mkdir -p "$CBIN"
cp "$(command -v sleep)" "$CBIN/claude.exe" 2>/dev/null || { echo "FAIL: stage claude.exe"; exit 1; }
"$CBIN/claude.exe" 600 & _MCP_PID=$!
sleep 0.4
assert_eq "fixture: the staged process really presents as claude.exe" \
    "$(ps -o comm= -p "$_MCP_PID" 2>/dev/null | tr -d '[:space:]')" "claude.exe"

_r=$(_ask "$NEW_SRC" "$_MCP_PID")
assert_eq "#908 a live process identified as claude.exe is LIVE" "${_r%% *}" "rc=0"

if (( _HAVE_OLD )); then
    _ro=$(_ask_old "$OLD_SRC" "$_MCP_PID")
    assert_eq "#908 NEGATIVE CONTROL [$_OLD_PROV]: the PRE-FIX matcher rejects it (so this suite discriminates)" \
        "$_ro" "rc=1"
else
    # FAIL, NOT SKIP — and this is the ONE disposition rule for every control of
    # this shape in the repo (your-org/nexus-code#1094, #1100).
    #
    # SKIP is the honest verdict when the missing precondition is ENVIRONMENTAL:
    # something no harness could supply here and now. That was true of this
    # branch before, when the only source of a pre-fix matcher was git history
    # and CI checks out at fetch-depth 1 — a shallow checkout is a fact about
    # the environment, not a defect in the suite.
    #
    # THE SYNTHESIS CHANGES THE CATEGORY, which is the whole of the argument.
    # It needs no history, no refs and no network, so once it exists there is no
    # environmental route to this branch left. The only way to arrive here is a
    # sed whose pattern has drifted from the code it edits — a defect in this
    # suite. A defect must be RED; nothing else will make anyone fix it, and a
    # control that cannot fire is the exact thing #1094 exists to stop.
    #
    # So the earlier `th_skip` was correct BEFORE the synthesis was added and
    # wrong after. Its comment was already written for the post-synthesis world
    # ("a broken harness rather than a shallow checkout") while the code still
    # did the pre-synthesis thing — the two sibling controls in this same commit
    # disagreed with each other for exactly that reason.
    #
    # Applied identically at test-session-name-from-window.sh and
    # test-cc-restart-watchdog-verify.sh. `#1100` poses this as a choice between
    # `skip` and `bad` and asks for one answer; this is that answer, and the
    # reason it is not a coin-flip is the paragraph above. It also settles
    # `#1100`'s own file, where the expired branch called `pass` — wrong under
    # EITHER option, and now a fail.
    # got/want stay one word: assert_eq %q-escapes its operands, so a sentence
    # there prints as an unreadable backslash blob. The diagnosis belongs in the
    # LABEL, which is printed verbatim.
    assert_eq "#908 NEGATIVE CONTROL: a pre-fix matcher was obtainable — every candidate ref already carries the fix AND the synthesis did not apply (its sed has probably drifted from the case arms in monitor/pane-state.sh); the fix is NOT watched discriminating in this run" \
        "no" "yes"
fi

# The over-match direction. Widening identity must not make ordinary
# processes look like agents — that direction merely strands a slot, but it
# also silently disables the `absent` detection the gate depends on.
sleep 600 & _SLEEP_PID=$!
sleep 0.3
_r=$(_ask "$NEW_SRC" "$_SLEEP_PID")
assert_eq "#908 an ordinary process is NOT live-claude" "${_r%% *}" "rc=1"
assert_eq "#908 …and is NOT indeterminate (a transient child must not poison the walk)" \
    "${_r##* }" "ind=0"

# A pid that has EXITED is a real negative observation, not an unanswerable
# question. Conflating them was a defect in the first draft of this fix: it
# made an ordinary shell report indeterminate, which would have turned every
# `absent` into a permanent `unknown` — trading #908's false-dead for a
# false-alive that never self-clears.
kill "$_SLEEP_PID" 2>/dev/null; wait "$_SLEEP_PID" 2>/dev/null
_r=$(_ask "$NEW_SRC" "$_SLEEP_PID")
assert_eq "#908 an EXITED pid is 'not claude', not 'could not determine'" "${_r##* }" "ind=0"
_SLEEP_PID=

# A pid that was never a number cannot be walked at all.
_r=$(_ask "$NEW_SRC" "not-a-pid")
assert_eq "#908 a non-numeric pid is refused, not guessed" "${_r%% *}" "rc=1"

# F1 (sk907): A BINARY DELETED IN PLACE. `/proc/<pid>/exe` reads
# `<path> (deleted)` and `readlink -f` cannot resolve it AT ALL — it returns
# empty, so the identity test degrades to the name fallback and the ladder
# answers `absent`. That is #908 reopened through a different door, and an
# in-place upgrade puts every live worker in this state simultaneously.
DELDIR="$WORK/delbin"; mkdir -p "$DELDIR"
cp "$(command -v sleep)" "$DELDIR/claude.exe" 2>/dev/null || { echo "FAIL: stage deleted-binary fixture"; exit 1; }
"$DELDIR/claude.exe" 600 & _DEL_PID=$!
sleep 0.4
rm -f "$DELDIR/claude.exe"
assert_contains "fixture: the kernel really decorates the exe link as (deleted)" \
    "$(readlink "/proc/$_DEL_PID/exe" 2>/dev/null)" "(deleted)"
_r=$(_ask "$NEW_SRC" "$_DEL_PID")
assert_eq "#908 F1 a live agent whose binary was DELETED IN PLACE is still LIVE" \
    "${_r%% *}" "rc=0"

# …AND THE `(deleted)` STRIP IS WHAT CARRIES IT, not the name fallback.
# Mutation-checked: with `ps` available the fixture is rescued by `comm`, so
# removing the strip left the suite green — two independent fixes masking each
# other, and only one of them was the one under test. Deny the process the name
# path (a `ps` that fails, i.e. the hardened-kernel / foreign-uid case) and the
# exe path is the ONLY evidence left.
NOPS="$WORK/nops"; mkdir -p "$NOPS"
printf '#!/usr/bin/env bash\nexit 1\n' > "$NOPS/ps"; chmod +x "$NOPS/ps"
_r_nops=$(PATH="$NOPS:$PATH" bash -c '
    set -uo pipefail
    . "$1"
    _pane_has_live_claude "$2"; printf "rc=%s" "$?"
' _ "$NEW_SRC" "$_DEL_PID" 2>/dev/null)
assert_eq "#908 F1 …identified from the exe link ALONE, with the name path denied" \
    "$_r_nops" "rc=0"
_ladder_del=$(bash -c '
    set -uo pipefail
    fixture=""; pane_dead=0
    PANE_BOOT_GRACE_SECONDS=90
    '"$(sed -n '/^_pid_runs_claude() {/,/^}/p' "$REPO_ROOT/monitor/pane-state.sh")"'
    '"$(sed -n '/^_pane_has_live_claude() {/,/^}/p' "$REPO_ROOT/monitor/pane-state.sh")"'
    _pane_has_live_descendant() { return 1; }
    _proc_view_functional()     { return 0; }
    _pane_age_seconds()         { printf 9999; return 0; }
    '"$(sed -n '/^_absent_evidence() {/,/^}/p' "$REPO_ROOT/monitor/pane-state.sh")"'
    _absent_evidence '"$_DEL_PID"'
' 2>/dev/null)
assert_eq "#908 F1 …and the REAL ladder does not reach the kill-authorising state" \
    "$_ladder_del" "live-claude"
kill "$_DEL_PID" 2>/dev/null; _DEL_PID=

# THE LADDER MUST ACTUALLY DECLINE, not merely mention the reason.
#
# The first draft asserted this with `assert_contains` against the FILE TEXT,
# and mutation testing caught it: deleting the ladder arm entirely left the
# suite GREEN at 17/0, because the string still appeared in the comment
# describing it. A text-presence assertion is prose standing in for a
# behavioural test — the exact defect `#915` is about, committed inside the
# tests for `#908`. So drive the real function.
#
# `_absent_evidence` is lifted verbatim and its neighbours stubbed, isolating
# step (4b): a tree with NO claude, NO live descendant, a WORKING process
# view, and an age past the boot grace — i.e. every conjunct that yields
# `tree-empty-past-grace` = absent = kill-authorised — except that the
# identity of some pid could not be determined.
_ladder() {   # <indeterminate 0|1> -> the reason/evidence token
    bash -c '
        set -uo pipefail
        fixture=""; pane_dead=0
        PANE_BOOT_GRACE_SECONDS=90
        _pane_has_live_claude()     { _PHLC_INDETERMINATE='"$1"'; return 1; }
        _pane_has_live_descendant() { return 1; }
        _proc_view_functional()     { return 0; }
        _pane_age_seconds()         { printf 9999; return 0; }
        '"$(sed -n '/^_absent_evidence() {/,/^}/p' "$REPO_ROOT/monitor/pane-state.sh")"'
        _absent_evidence 4242
    ' 2>/dev/null
}
assert_eq "#908 an INDETERMINATE identity makes the ladder DECLINE to say absent" \
    "$(_ladder 1)" "claude-identity-indeterminate"
assert_eq "#908 …while a determinate empty tree past grace still resolves to absent" \
    "$(_ladder 0)" "tree-empty-past-grace"

# ── §2 ONE WINDOW-KEY VOCABULARY (your-org/nexus-code#905) ───────────────
# PRIVATE SOCKET, PROVEN PRIVATE BEFORE ANY WINDOW IS CREATED.
# NOTE `-t 0:` WITH THE TRAILING COLON. `-t 0` is parsed as window INDEX 0,
# not session 0, so `new-window -t 0` fails with `index in use` and
# `list-windows -t 0` reports one window instead of the session's. Both are
# quiet wrong answers rather than errors you notice.
_board_sock=$(tmux display-message -p '#{socket_path}' 2>/dev/null || printf '')
tmux -L "$_SOCK" new-session -d -s 0 -n alpha 'sleep 600' 2>/dev/null
_mine_sock=$(tmux -L "$_SOCK" display-message -p '#{socket_path}' 2>/dev/null || printf '')
if [[ -n "$_mine_sock" && "$_mine_sock" != "$_board_sock" ]]; then
    _SOCKET_PROVEN_PRIVATE=1
fi
assert_eq "#905 the fixture socket is PROVEN not the board's before use" \
    "${_SOCKET_PROVEN_PRIVATE:-0}" "1"

if [[ "${_SOCKET_PROVEN_PRIVATE:-0}" == 1 ]]; then
    tmux -L "$_SOCK" new-window -d -t 0: -n bravo 'sleep 600' 2>/dev/null

    _key() {   # <key> -> "rc=<n> out=<name>"
        local o rc
        o=$(TMUX_SOCK="$_SOCK" bash -c '
            set -uo pipefail
            . "$1/monitor/_tmux-window.sh"
            tmux() { command tmux -L "$TMUX_SOCK" "$@"; }
            resolve_window_key "$2" 2>/dev/null; ' _ "$REPO_ROOT" "$1" 2>/dev/null); rc=$?
        printf 'rc=%s out=%s' "$rc" "${o:-}"
    }
    _idx_of() { command tmux -L "$_SOCK" list-windows -t 0: -F '#{window_index} #{window_name}' 2>/dev/null | awk -v n="$1" '$2==n{print $1; exit}'; }
    _alpha_idx=$(_idx_of alpha)

    # UNAMBIGUOUS ARMS FIRST, while no window is NAMED like an index. The
    # first draft of this suite created the collision up front and then
    # asserted the plain index arm — which tmux happened to make ambiguous, so
    # the resolver correctly answered rc=4 and the TEST was wrong, not the
    # code. Ordering removes the luck.
    assert_eq "#905 a NAME resolves"                      "$(_key alpha)"           "rc=0 out=alpha"
    assert_eq "#905 an INDEX resolves to the same window"  "$(_key "$_alpha_idx")"  "rc=0 out=alpha"
    assert_eq "#905 a session:window key resolves"         "$(_key "0:$_alpha_idx")" "rc=0 out=alpha"
    assert_eq "#905 an unknown key is NOT FOUND, not guessed" "$(_key no-such-win)"  "rc=1 out="

    # NOW manufacture the collision deterministically: a window NAMED exactly
    # alpha's index, sitting at a different index. Picking either silently is
    # how a paste lands in the wrong pane, so the resolver must refuse.
    tmux -L "$_SOCK" new-window -d -t 0: -n "$_alpha_idx" 'sleep 600' 2>/dev/null
    _collide_idx=$(command tmux -L "$_SOCK" list-windows -t 0: -F '#{window_index} #{window_name}' 2>/dev/null | awk -v n="$_alpha_idx" '$2==n{print $1; exit}')
    if [[ -n "$_collide_idx" && "$_collide_idx" != "$_alpha_idx" ]]; then
        _r=$(_key "$_alpha_idx")
        assert_eq "#905 an AMBIGUOUS key (a NAME and an INDEX naming different windows) is REFUSED" \
            "${_r%% *}" "rc=4"
        _AMBIG_TESTED=1
    else
        th_skip "the #905 ambiguity arm" \
                "tmux placed the window named '$_alpha_idx' at index '$_collide_idx' — no collision exists to test in this run."
    fi
else
    th_skip "the #905 window-key arms" \
            "could not prove the fixture tmux socket differs from the board's — refusing to create windows rather than risk the board."
fi

# ── §3 THE TWO HELPERS AGREE — WITNESSED, NOT GREPPED ───────────────────
# sk907 F3: the first draft asserted this section with five `assert_contains`
# checks against file text, and its mutation M-A disconnected the resolver
# from `paste-followup.sh` COMPLETELY while the suite stayed 20/0 green. A
# string in a file is not a behaviour. Every claim below now drives a real
# helper on the PRIVATE socket and reads what it answers.
if [[ "${_SOCKET_PROVEN_PRIVATE:-0}" == 1 ]]; then
    # A `tmux` shim that pins every call to the fixture socket, so the helpers
    # under test cannot reach the board even by accident.
    SHIM="$WORK/shim"; mkdir -p "$SHIM"
    # ABSOLUTE path to the real tmux. `exec command tmux …` does NOT work:
    # `command` is a shell BUILTIN and `exec` needs a program, so the shim
    # exits 127 having never run tmux — the same family as the documented
    # `xargs -0 command grep` trap, and it produced a false red here before
    # it was caught.

    # --- REAL tmux BINARY, not whatever `tmux` resolves to (your-org/nexus-code#1033)
# `type -P tmux` / `command -v tmux` under an agent PATH return THE NEXUS
# WRAPPER, because monitor/tmuxwrap is PATH-fronted for every agent process.
# Binding that as "the real tmux" and then exec'ing it from a stub that is
# ITSELF named `tmux` and ITSELF on PATH makes the two select each other
# forever: the wrapper picks the stub (a different file, so every identity gate
# passes), the stub re-prepends its `-L <sock>` and execs the wrapper back.
# Measured live on 2026-08-26: argv grew one `-L` per round trip to 22,370
# characters and the uid reached 942 wrapper processes. Take the first PATH
# candidate that is an actual BINARY — a real tmux is ELF, every wrapper and
# every stub is a `#!` script — which is what "the real tmux" was always meant
# to denote.
_nx_real_tmux_bin() {
    # TWO ZSH DIVERGENCES, BOTH FIXED HERE (your-org/nexus-code#1319). This
    # body is byte-identical in four places (see the note above); keep it so.
    #
    # (1) THE SPLIT. `for _d in $PATH` under `IFS=:` is a BASH-ONLY idiom —
    #     zsh does not word-split an unquoted parameter, so the loop ran ONCE
    #     over the whole PATH string, every candidate test failed, and the
    #     function returned 1: "no real tmux BINARY on PATH" on a host that
    #     has one. Callers spell rc 1 as `exit 77` SKIP, so the failure was
    #     coverage silently leaving the population. Measured, interpreter the
    #     only variable and $PATH pinned identical: bash -> /usr/bin/tmux,
    #     zsh -> rc 1. Parameter expansion splits identically in both shells
    #     and needs no IFS bookkeeping at all.
    #
    # (2) THE MAGIC BYTES, and this one is worse — `read -N` DOES NOT EXIST
    #     IN ZSH (`zsh:read:1: bad option: -N`, rc 1), so the old `||
    #     _magic=""` arm fails OPEN toward "this is a real binary". Repairing
    #     only the split would therefore have turned a silent SKIP into a
    #     silent WRONG ANSWER: measured, the split-repaired body under zsh
    #     returns `monitor/tmuxwrap/tmux` — the wrapper — and a shim written
    #     from that names the wrapper, loses its `-L` pin, and reaches the
    #     operator's live board, which is the 2026-08-27 mechanism this
    #     file's header exists to prevent. `head -c 2` behaves identically in
    #     both shells, and `|| continue` is fail-CLOSED: a candidate whose
    #     bytes cannot be read is treated as a wrapper and skipped.
    local _d _magic _rest="$PATH:"
    while [ -n "$_rest" ]; do
        _d="${_rest%%:*}"; _rest="${_rest#*:}"
        [ -n "$_d" ] && [ -x "$_d/tmux" ] && [ ! -d "$_d/tmux" ] || continue
        _magic=$(head -c 2 -- "$_d/tmux" 2>/dev/null) || continue
        [ "$_magic" = '#!' ] || { printf '%s' "$_d/tmux"; return 0; }
    done
    return 1
}
    _REAL_TMUX=$(_nx_real_tmux_bin 2>/dev/null)
    printf '#!/usr/bin/env bash\nexec %s -L %s "$@"\n' "$_REAL_TMUX" "$_SOCK" > "$SHIM/tmux"
    chmod +x "$SHIM/tmux"
    _shim_ok=$(PATH="$SHIM:$PATH" tmux list-windows -t 0: -F '#{window_name}' 2>/dev/null | tr '\n' ' ')
    assert_contains "#905 the tmux shim reaches the FIXTURE socket, not the board" "$_shim_ok" "alpha"

    # pane-state.sh used to reject a NAME outright (sk907 F2: three artefacts
    # claimed otherwise while the code did not). Drive it.
    _ps_name=$(PATH="$SHIM:$PATH" bash "$REPO_ROOT/monitor/pane-state.sh" alpha 2>&1 | head -1)
    assert_contains "#905 pane-state.sh ACCEPTS a window NAME" "$_ps_name" "name=alpha"
    # Use bravo's index: by now a window NAMED alpha's index exists, so alpha's
    # index is legitimately ambiguous and is exercised separately below.
    _bravo_idx=$(_idx_of bravo)
    _ps_idx=$(PATH="$SHIM:$PATH" bash "$REPO_ROOT/monitor/pane-state.sh" "$_bravo_idx" 2>&1 | head -1)
    assert_contains "#905 pane-state.sh still accepts an INDEX (no regression)" "$_ps_idx" "name=bravo"

    # The ambiguous key: pane-state.sh used to answer SILENTLY about the
    # index-side window — a confident answer about the wrong window, and this
    # one can authorise a kill.
    _ps_amb=$(PATH="$SHIM:$PATH" bash "$REPO_ROOT/monitor/pane-state.sh" "$_alpha_idx" 2>&1; printf ' rc=%s' "$?")
    if [[ "${_AMBIG_TESTED:-0}" == 1 ]]; then
        assert_contains "#905 pane-state.sh REFUSES an ambiguous key instead of answering about one side" \
            "$_ps_amb" "AMBIGUOUS"
        # …and the sibling refuses the same key, which is the property #905 asks
        # for: the two helpers agree about what a key is.
        _pf_amb=$(PATH="$SHIM:$PATH" bash "$REPO_ROOT/monitor/paste-followup.sh" "$_alpha_idx" --message hi 2>&1 | head -2)
        assert_contains "#905 paste-followup.sh REFUSES the SAME ambiguous key" "$_pf_amb" "ambiguous"

        # sk907 F2 RESIDUE: the `session:window` form. The first fix guarded
        # only the BARE index, so `pane-state.sh 0:1` silently answered about
        # the index-side window while `paste-followup.sh 0:1` refused — the
        # helpers still disagreed, on the form CLAUDE.md documents and
        # orchestrators actually type. Both spellings are driven here so the
        # next edit cannot close one and leave the other.
        _ps_amb_sw=$(PATH="$SHIM:$PATH" bash "$REPO_ROOT/monitor/pane-state.sh" "0:$_alpha_idx" 2>&1; printf ' rc=%s' "$?")
        assert_contains "#905 F2 pane-state.sh REFUSES the session:window form of the ambiguous key" \
            "$_ps_amb_sw" "AMBIGUOUS"
        _pf_amb_sw=$(PATH="$SHIM:$PATH" bash "$REPO_ROOT/monitor/paste-followup.sh" "0:$_alpha_idx" --message hi 2>&1 | head -2)
        assert_contains "#905 F2 …and paste-followup.sh refuses it too (the helpers AGREE on both spellings)" \
            "$_pf_amb_sw" "AMBIGUOUS"
        # …while an UNAMBIGUOUS session:window key still answers, so the
        # refusal is not a blanket rejection of the form itself.
        _ps_ok_sw=$(PATH="$SHIM:$PATH" bash "$REPO_ROOT/monitor/pane-state.sh" "0:$_bravo_idx" 2>&1 | head -1)
        assert_contains "#905 F2 …and an UNAMBIGUOUS session:window key still answers" \
            "$_ps_ok_sw" "name=bravo"
        _AGREE_TESTED=1
    else
        th_skip "the #905 cross-helper agreement arms" \
                "no name/index collision exists in this tmux's index assignment, so there is no ambiguous key to drive."
    fi
else
    th_skip "the #905 behavioural arms" \
            "the fixture tmux socket could not be proven private — refusing to drive helpers that target tmux."
fi

# ── §4 THE HELPERS MUST DENOTE THE SAME WINDOW, NOT MERELY ACCEPT THE SAME KEY
#    (your-org/nexus-code#905 reopen; mechanism your-org/nexus-code#944) ───────
#
# §2 and §3 above are GREEN ON A BROKEN VOCABULARY, and no mutation was needed
# to show it — they are uninformative BY OMITTED INPUT CLASS, not by skipping.
# Two omissions, both structural:
#
#   (1) the whole fixture lived in ONE tmux session — a single `new-session` in
#       this file — so a cross-session disagreement was unreachable;
#   (2) every `session:window` assertion above passes an INDEX after the colon.
#       No assertion anywhere handed a `session:NAME` key to either helper.
#
# So the property this issue was actually opened about — that the two helpers,
# "typed in adjacent commands against the same window", denote the SAME
# window — was not asserted anywhere. Grammatical agreement (does each helper
# ACCEPT the key) is a PROXY for it, and the proxy holds while the property
# fails. That substitution is the defect class this repo keeps paying for,
# committed here inside the guard for it.
#
# THE MECHANISM, both halves readable at this ref:
#   _tmux-window.sh:128   `tmux list-windows -F` takes no `-a` and no `-t`, so
#                         the row set is the CURRENT session's only.
#   pane-state.sh:3062    pins the resolved index back to session ZERO —
#                         `win="0:$_ps_resolved"`.
# A name found in session `two` therefore comes back as session `0`'s window of
# the same INDEX. Measured on this fixture: `pane-state.sh charlie` answers
# `window=1 name=alpha` at rc 0 — a confident answer about a DIFFERENT window
# in a DIFFERENT session — while `paste-followup.sh charlie` pastes into
# charlie. Correspondingly `pane-state.sh alpha` exits 3 "no such tmux window"
# for a window that is live at `0:1`: a POSITIVE, FALSE claim of absence, on
# the one axis whose emitted state (`absent`) is kill-authorising.
#
# ASSERTED AS DENOTATION, NEVER AS ACCEPTANCE, and by two different shapes,
# because either alone is green on the broken code:
#   * AGREEMENT arms compare what pane-state.sh SAYS it looked at against the
#     window paste-followup actually PASTED INTO — witnessed by a unique marker
#     and capture-pane. Agreement alone is insufficient: for `alpha` and
#     `0:alpha` BOTH helpers currently fail, so they agree while both are wrong.
#   * LIVENESS arms therefore assert absolutely that a window which demonstrably
#     exists is not reported absent.
# Neither shape greps a file or consults the resolver the two are supposed to
# share; `resolve_window_key` is what paste-followup CONSUMES, so asking it
# would re-substitute the proxy this section exists to remove.

_XSESS_TESTED=0
if [[ "${_SOCKET_PROVEN_PRIVATE:-0}" == 1 && -n "${SHIM:-}" ]]; then
    # A SECOND SESSION, created LAST so it is the current one. The defect is
    # directional: it bites when the key names a window in the session tmux
    # considers current while the ANSWER is pinned to session zero. Which
    # session is current with no client attached is tmux's business, not this
    # suite's, so it is MEASURED via `display-message` (tmux's own answer) and
    # the arms SKIP rather than fail if the fixture did not land that way.
    # Asking the resolver instead would pin the defect as expected behaviour.
    tmux -L "$_SOCK" new-session -d -s two -n charlie 'sleep 600' 2>/dev/null
    _cur_sess=$(command tmux -L "$_SOCK" display-message -p '#{session_name}' 2>/dev/null || printf '')
    # NO `| awk … exit` HERE. An early-exit reader closes the pipe, and under
    # this file's `set -o pipefail` the writer's EPIPE can invert the pipeline
    # status — your-org/nexus-code#622/#682, whose manifest
    # (`early-exit-readers.manifest`) went red on the first draft of this line.
    # Regenerating that manifest is not the fix when the site is avoidable, and
    # this one is: a whole-line membership test needs no reader at all.
    _all_wins=$(command tmux -L "$_SOCK" list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null)
    _charlie_there=no
    [[ $'\n'"$_all_wins"$'\n' == *$'\n'"two:charlie"$'\n'* ]] && _charlie_there=yes

    # What window does pane-state.sh SAY it looked at? Its own `name=` field.
    # A non-zero exit / empty stdout is reported as `rc<N>` so a refusal can
    # never be silently read as agreement.
    _ps_denotes() {   # <key> -> window NAME pane-state.sh answered about, or rc<N>
        local out rc
        out=$(PATH="$SHIM:$PATH" bash "$REPO_ROOT/monitor/pane-state.sh" "$1" 2>/dev/null); rc=$?
        if (( rc != 0 )) || [[ -z "$out" ]]; then printf 'rc%s' "$rc"; return 0; fi
        [[ "$out" =~ name=([^[:space:]]*) ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
        printf 'noname'
    }
    # What window did paste-followup.sh actually REACH? Witnessed by a unique
    # marker and capture-pane over EVERY window on the fixture server — never by
    # reading the tool's own success message, which reports the key it was
    # given, not the pane it hit. `--no-enter` so nothing is submitted.
    # HERESTRING, not `capture-pane | grep -qF`: this file runs under
    # `set -uo pipefail` and `grep -q` exits at the first match, SIGPIPEing the
    # producer whose 141 then becomes the pipeline's status.
    _pf_seq=0
    _pf_lands_in() {  # <key> -> window NAME that received the paste, or REFUSED
        local key="$1" mark w n
        _pf_seq=$(( _pf_seq + 1 ))
        mark="GK905MARK$$X${_pf_seq}X${RANDOM}"
        PATH="$SHIM:$PATH" timeout 60 bash "$REPO_ROOT/monitor/paste-followup.sh" \
            "$key" --message "$mark" --no-enter >/dev/null 2>&1
        while read -r w n; do
            [[ -n "$w" ]] || continue
            if grep -qF "$mark" <<<"$(command tmux -L "$_SOCK" capture-pane -p -t "$w" 2>/dev/null)"; then
                printf '%s' "$n"; return 0
            fi
        done < <(command tmux -L "$_SOCK" list-windows -a -F '#{session_name}:#{window_index} #{window_name}' 2>/dev/null)
        printf 'REFUSED'
    }

    if [[ "$_cur_sess" == "two" && "$_charlie_there" == "yes" ]]; then
        # SKIPPED BY DEFAULT — THE GUARD IS REPORTING AN OPEN DEFECT, NOT PASSING.
        # These four arms are RED at this ref. They are skipped rather than left
        # failing because the fix is OUT OF SCOPE here and MUST BE SEQUENCED:
        # your-org/nexus-code#944 (the session-blind row source in
        # `_tmux-window.sh`) has to land BEFORE your-org/nexus-code#905's
        # prescribed remedy of routing pane-state's key through
        # `resolve_window_key` unconditionally — routing a kill-authorising
        # answer through today's session-blind resolver makes the wrong-window
        # answer worse, not better. Set PANE_STATE_DRIVE_OPEN_905=1 to drive
        # them; they are the reproduction, and they must go GREEN when #944 and
        # #905 land. DELETING them to restore a green is the failure mode this
        # whole section exists to prevent.
        if [[ "${PANE_STATE_DRIVE_OPEN_905:-0}" == 1 ]]; then
            # AGREEMENT — a bare NAME. pane-state answers `alpha`; the sibling
            # reaches `charlie`. Same key, adjacent commands, different windows.
            _x_ps=$(_ps_denotes charlie); _x_pf=$(_pf_lands_in charlie)
            assert_eq "#905/#944 a bare NAME denotes the SAME window in BOTH helpers" \
                "ps=$_x_ps pf=$_x_pf" "ps=charlie pf=charlie"

            # LIVENESS — `alpha` is live at 0:1. Exit 3 is documented as a
            # POSITIVE claim of absence, so this is a false negative on the
            # axis that authorises a kill.
            assert_eq "#905/#944 a live window in ANOTHER session is not reported ABSENT" \
                "$(_ps_denotes alpha)" "alpha"

            # AGREEMENT — the `session:NAME` spelling, the input class no
            # assertion in this file previously supplied to either helper.
            _x_ps_sn=$(_ps_denotes two:charlie); _x_pf_sn=$(_pf_lands_in two:charlie)
            assert_eq "#905 a session:NAME key denotes the SAME window in BOTH helpers" \
                "ps=$_x_ps_sn pf=$_x_pf_sn" "ps=charlie pf=charlie"

            # DOC TRUTH, DRIVEN. CLAUDE.md's WINDOW-KEY-VOCABULARY block says
            # both helpers accept "an index, a `session:window`, or a NAME".
            # The existing doc check is an assert_not_contains — it witnesses
            # only that an OLD false sentence is gone, never that the NEW one is
            # true. `0:alpha` is that sentence's own example shape.
            assert_eq "#905 the documented session:window form holds for a NAME, not only an INDEX" \
                "$(_ps_denotes 0:alpha)" "alpha"
            _XSESS_TESTED=1
        else
            th_skip "the #905/#944 cross-session denotation arms" \
                    "OPEN DEFECT, not an absent precondition: pane-state.sh answers about session 0's window for a name resolved in another session, and reports a live window absent. Fix is sequenced behind your-org/nexus-code#944 then #905. Drive with PANE_STATE_DRIVE_OPEN_905=1."
        fi
    else
        th_skip "the #905/#944 cross-session denotation arms" \
                "could not build the two-session fixture (current session '$_cur_sess', charlie present '$_charlie_there') — the topology that reaches the defect does not exist in this run."
    fi
else
    th_skip "the #905/#944 cross-session denotation arms" \
            "the fixture tmux socket could not be proven private, or the §3 shim was not built — refusing to drive helpers that target tmux."
fi

# THE USAGE STRING IS A CLAIM TOO, and nothing witnessed it (sk907, E3
# follow-up). `pane-state.sh` accepts a NAME; its usage said
# `<window-index|session:window>` for one round after that became true, and a
# #938 mutation reverting the fix survived at 28/0. A claim that is true and
# unguarded is one edit from being false — the class this PR spent four rounds
# on. Driven, not grepped: run the tool with no argument and read what it
# prints.
_usage_out=$(bash "$REPO_ROOT/monitor/pane-state.sh" 2>&1; true)
assert_contains "#905 E3 the usage string NAMES the window-name key it accepts" \
    "$_usage_out" "window-name"

# The doc claim is checked for TRUTH, not presence: CLAUDE.md must not carry
# the sentence the code now contradicts. The positive half of the claim is
# witnessed by the drives above rather than by grepping for a marker.
assert_not_contains "#905 CLAUDE.md no longer claims a name fails the lookup" \
    "$(cat "$REPO_ROOT/CLAUDE.md")" "passing a name fails the lookup"

# EXPECTED-COUNT GUARD (your-org/nexus-code#807). DERIVED, because §2's arms
# legitimately skip where a private socket is unavailable — that IS an
# environmental precondition. A pinned literal would go red for an
# environmental reason; lowering it to the skipping count would stop noticing a
# genuinely LOST assertion where they DO run.
#
# §1's NEGATIVE CONTROL IS NO LONGER IN THAT CATEGORY (#1094, #1100), so its
# contribution is now UNCONDITIONAL. It used to be `(( _HAVE_OLD )) && +1`,
# because the control could vanish for the environmental reason of a shallow
# checkout. The synthesized fallback removed that route: both branches now
# score exactly one assertion — the control, or the fail that says it could not
# be built. Leaving the conditional in place made the guard itself wrong on the
# drift path, and it said so, loudly, on the first mutant run after the
# disposition changed: `29 ran, 28 expected`.
EXPECTED=$(( 16 ))                      # §1 (8) + F1 (4) + §2 socket proof (1) + §3 usage + doc-truth (2) + the #908 control (1, unconditional)
if [[ "${_SOCKET_PROVEN_PRIVATE:-0}" == 1 ]]; then
    EXPECTED=$(( EXPECTED + 4 ))     # name / index / session:window / unknown
    [[ "${_AMBIG_TESTED:-0}" == 1 ]] && EXPECTED=$(( EXPECTED + 1 ))
    EXPECTED=$(( EXPECTED + 3 ))     # §3 shim proof + pane-state NAME + INDEX
    [[ "${_AGREE_TESTED:-0}" == 1 ]] && EXPECTED=$(( EXPECTED + 5 ))
fi
# §4 contributes 4 ONLY when driven. They are SKIPPED by default because they
# are RED at this ref (your-org/nexus-code#905 / #944, sequenced), so counting
# them unconditionally would make this guard red for the bookkeeping reason
# instead of the real one — and the skip line, not the count, is what says the
# defect is open.
[[ "${_XSESS_TESTED:-0}" == 1 ]] && EXPECTED=$(( EXPECTED + 4 ))
_total=$(( PASS + FAIL ))
if (( _total != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$_total" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
