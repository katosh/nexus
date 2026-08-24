#!/usr/bin/env bash
# test-paste-dead-pane-guard.sh — your-org/nexus-code#745.
#
# `tmux paste-buffer` into a pane tmux reports as `#{pane_dead}` KILLS
# THE TMUX SERVER. In this workspace that is the watcher, every worker
# window, the orchestrator and the sandbox session, and the operator
# cannot restart the nexus from inside. Measured 20/20 on the deployed
# tmux 2.6, on BOTH call forms in the tree.
#
# Three parts, because three different things can rot:
#
#   A  the PREDICATE — real tmux, not a mock. The claim is about what
#      `#{pane_dead}` and `#{pane_active}` do on the installed tmux, so
#      a mock would assert what we typed into a variable.
#   B  the CALL-SITE MANIFEST — every `tmux paste-buffer` in monitor/
#      must be guarded. A rule applied to the sites somebody happened
#      to be editing is not applied (your-org/nexus-code#735 F5); this
#      is what makes a FIFTH site loud instead of silent.
#   C  END-TO-END — drive the real helpers against a real corpse and
#      assert the server SURVIVES, with an unguarded positive control
#      in the same fixture proving the fixture can still kill it. A
#      "server survived" that cannot fail is not evidence.
#
# Gated behind SLOW_TESTS=1: it stands up real tmux servers (~10 s).
#
# SAFETY. Every server here is private (`env -u TMUX tmux -L <name>` —
# `$TMUX` outranks `TMUX_TMPDIR`, your-org/nexus-code#644) and is torn
# down with `kill-session`, NEVER `kill-server`: bwrap is PID 1 under
# `--die-with-parent`, so a bare `kill-server` ends the sandbox. Part C
# deliberately CRASHES its own private servers; that is the control.
#
# Run: SLOW_TESTS=1 bash monitor/watcher/test-paste-dead-pane-guard.sh

set -uo pipefail

if [ "${SLOW_TESTS:-0}" != "1" ]; then
    echo "skipped: $(basename "$0") (set SLOW_TESTS=1 to enable; ~10s, needs tmux)"
    exit 77   # SKIP, not PASS (your-org/nexus-code#568 A6)
fi

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
MON="$REPO_ROOT/monitor"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s (got %q)\n' "$label" "$got"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s: got %q, want %q\n' "$label" "$got" "$want" >&2; FAIL=$(( FAIL + 1 ))
    fi
}
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

command -v tmux >/dev/null 2>&1 || {
    echo "ENV-FAIL: tmux is not on PATH — this test is about real tmux behaviour," >&2
    echo "          so skipping it would assert nothing. Refusing instead." >&2
    exit 1
}

WORK=$(mktemp -d -t nexus-745-XXXXXX)
PAYLOAD="$WORK/payload.txt"
printf 'guard test payload\nsecond line\n' > "$PAYLOAD"

# shellcheck source=../_pane-live.sh
. "$MON/_pane-live.sh"

# ---------------------------------------------------------------------
# fixture helpers
# ---------------------------------------------------------------------
# The harness must NOT go through the PATH wrapper it installs for the
# helpers under test: the wrapper already supplies `-L`, so a wrapped
# `tmux -L $sock` becomes `tmux -L <wrapper-sock> -L $sock` and the
# harness silently drives the wrong server. Resolve the real binary ONCE,
# before any PATH munging, and use it for every harness-side call.
TMUX_BIN=$(command -v tmux)
_SOCKS=()
# Sets $SOCK; deliberately does NOT echo it, and the callers deliberately do
# not use command substitution. Assigning from `$( new_server … )` runs the
# function in a SUBSHELL, so the `_SOCKS+=(…)` bookkeeping never reached the
# parent, the EXIT trap iterated an EMPTY array, and every call leaked one
# private tmux server holding sleeping processes. Measured: ~64 servers left
# behind across one mutation session, on a shared node. Keep the bookkeeping
# in the shell that owns the trap.
new_server() {                      # new_server <suffix> -> sets $SOCK
    SOCK="nexus-745-$$-$1"
    _SOCKS+=("$SOCK")
    env -u TMUX "$TMUX_BIN" -L "$SOCK" new-session -d -s m -n base 'sleep 120' 2>/dev/null
}
tx() { local s="$1"; shift; env -u TMUX "$TMUX_BIN" -L "$s" "$@"; }
server_alive() { tx "$1" list-sessions >/dev/null 2>&1; }
teardown_all() {
    local s sess
    for s in ${_SOCKS[@]+"${_SOCKS[@]}"}; do
        server_alive "$s" || continue
        while IFS= read -r sess; do
            [[ -n "$sess" ]] && tx "$s" kill-session -t "$sess" 2>/dev/null
        done < <(tx "$s" list-sessions -F '#{session_name}' 2>/dev/null)
    done
    rm -rf "$WORK"
}
trap teardown_all EXIT

# make_corpse <sock> <winname> — window whose process has exited, kept
# by remain-on-exit. Preset the option so the corpse forms
# deterministically rather than racing the child's exit (#741).
make_corpse() {
    local s="$1" w="$2" i d
    tx "$s" set-option -g remain-on-exit on 2>/dev/null
    tx "$s" new-window -d -n "$w" 'exit 1' 2>/dev/null
    for i in $(seq 1 50); do
        d=$(tx "$s" list-panes -s -F '#{window_name} #{pane_dead}' 2>/dev/null \
              | awk -v w="$w" '$1 == w && !seen { print $2; seen = 1 }')
        [[ "$d" == "1" ]] && return 0
        sleep 0.1
    done
    return 1
}

# route a bare `tmux` (what the helpers call) to a private socket
route_tmux_to() {
    local sock="$1"
    mkdir -p "$WORK/bin"
    cat > "$WORK/bin/tmux" <<WRAP
#!/usr/bin/env bash
exec env -u TMUX $TMUX_BIN -L "$sock" "\$@"
WRAP
    chmod +x "$WORK/bin/tmux"
    PATH="$WORK/bin:$PATH"; export PATH
}

# =====================================================================
echo '=== A: the predicate, against real tmux ==='
# =====================================================================
new_server a; SA="$SOCK"
route_tmux_to "$SA"

tx "$SA" new-window -d -n livewin 'sleep 120' 2>/dev/null
sleep 0.3
_tmux_pane_is_dead livewin; rc=$?
assert_eq "live window -> rc=1 (not dead, paste allowed)" "$rc" "1"

make_corpse "$SA" deadwin || { echo "ENV-FAIL: no corpse formed (tmux $(tmux -V))" >&2; exit 1; }
_tmux_pane_is_dead deadwin; rc=$?
assert_eq "remain-on-exit corpse -> rc=0 (dead, REFUSE)" "$rc" "0"

# the corpse must not condemn its neighbours
_tmux_pane_is_dead livewin; rc=$?
assert_eq "live sibling of a corpse -> rc=1" "$rc" "1"

# @id form (paste-followup.sh targets by @id)
wid=$(tx "$SA" list-windows -a -F '#{window_name} #{window_id}' 2>/dev/null \
        | awk '$1 == "deadwin" && !seen { print $2; seen = 1 }')
if [[ -n "$wid" ]]; then
    _tmux_pane_is_dead "$wid"; rc=$?
    assert_eq "corpse addressed by @id -> rc=0" "$rc" "0"
else
    fail "could not resolve @id for the corpse"
fi

# %pane form
pid=$(tx "$SA" list-panes -a -F '#{window_name} #{pane_id}' 2>/dev/null \
        | awk '$1 == "deadwin" && !seen { print $2; seen = 1 }')
if [[ -n "$pid" ]]; then
    _tmux_pane_is_dead "$pid"; rc=$?
    assert_eq "corpse addressed by %pane -> rc=0" "$rc" "0"
else
    fail "could not resolve %pane for the corpse"
fi

# a name nobody holds: not provably dead -> proceed (the paste will
# simply fail, harmlessly)
_tmux_pane_is_dead zz-no-such-window; rc=$?
assert_eq "unheld name -> rc=1 (proceed; paste fails harmlessly)" "$rc" "1"
_tmux_pane_is_dead ""; rc=$?
assert_eq "empty target -> rc=1" "$rc" "1"

# THE ACTIVE PANE IS THE ONE THAT MATTERS, both directions. A
# window-level "holds any live pane" test is wrong each way; these two
# assertions are what pin that.
tx "$SA" new-window -d -n splitwin 'sleep 120' 2>/dev/null
tx "$SA" split-window -t splitwin 'exit 1' 2>/dev/null
# POLL for the split pane's death rather than sleeping a guessed second.
# A fixed sleep made this assertion flaky under load — it read
# `panes: 0010` (nothing dead yet) and failed for a reason that had
# nothing to do with the predicate.
act=''
for _i in $(seq 1 50); do
    act=$(tx "$SA" list-panes -t splitwin -F '#{pane_active}#{pane_dead}' 2>/dev/null | tr -d '\n')
    [[ "$act" == *"11"* ]] && break
    sleep 0.1
done
if [[ "$act" == *"11"* ]]; then
    _tmux_pane_is_dead splitwin; rc=$?
    assert_eq "dead pane is ACTIVE (live sibling present) -> rc=0 (REFUSE)" "$rc" "0"
    liveidx=$(tx "$SA" list-panes -t splitwin -F '#{pane_index} #{pane_dead}' 2>/dev/null \
                | awk '$2 == "0" && !seen { print $1; seen = 1 }')
    tx "$SA" select-pane -t "splitwin.$liveidx" 2>/dev/null
    _tmux_pane_is_dead splitwin; rc=$?
    assert_eq "live pane is ACTIVE (dead sibling present) -> rc=1 (allow)" "$rc" "1"
else
    fail "split fixture did not produce an active dead pane (panes: $act)"
fi

# a query that cannot be answered is not "dead"
PATH_SAVED="$PATH"
EMPTY=$(mktemp -d); PATH="$EMPTY"
_tmux_pane_is_dead deadwin; rc=$?
assert_eq "no tmux on PATH -> rc=1 (not provably dead)" "$rc" "1"
PATH="$PATH_SAVED"; rmdir "$EMPTY"

STUB_EMPTY="$WORK/emptybin"; mkdir -p "$STUB_EMPTY"

# =====================================================================
echo '=== B: call-site manifest — every paste-buffer is guarded ==='
# =====================================================================
# Discovered from the HAZARD (every real `tmux paste-buffer`
# invocation), never from a hand-kept list — the list is what rots.
# Comment lines are excluded; a comment mentioning the verb is not a
# call. Test files are out of scope: they drive private fixture servers
# on purpose.
# `tmux paste-buffer` inside a QUOTED STRING is a diagnostic, not a call
# (paste-followup.sh's own `die "tmux paste-buffer failed …"` is one, and
# the first cut of this discovery counted it — 5 sites where the tree has
# 4). Drop lines whose match sits inside double quotes.
paste_sites=$(command grep -rn 'tmux paste-buffer' --include='*.sh' "$MON" 2>/dev/null \
    | command grep -v '/test' \
    | command grep -vE ':[0-9]+:[[:space:]]*#' \
    | command grep -vE '"[^"]*tmux paste-buffer')

if [[ -z "$paste_sites" ]]; then
    fail "B: found ZERO paste-buffer sites — the discovery is broken, and a green here would be vacuous"
else
    nsites=$(printf '%s\n' "$paste_sites" | command grep -c .)
    # The FILE SET is declared, so a fifth site cannot appear silently —
    # a new file goes red until somebody classifies it, which is the
    # whole point (your-org/nexus-code#735 F5, #682's manifest pattern).
    EXPECTED_PASTE_FILES='monitor/paste-followup.sh
monitor/watcher/_respawn.sh
monitor/watcher/_unstick.sh
monitor/watcher/main.sh'
    # Both sides through the SAME `sort -u`: the collation here is
    # locale-dependent (it orders `main.sh` before `_respawn.sh`), so
    # comparing a hand-ordered literal against sorted output fails on
    # ordering alone and says nothing about the set.
    got_files=$(printf '%s\n' "$paste_sites" | sed "s|^$MON|monitor|" | cut -d: -f1 | sort -u)
    want_files=$(printf '%s\n' "$EXPECTED_PASTE_FILES" | sort -u)
    if [[ "$got_files" == "$want_files" ]]; then
        pass "B: paste-buffer file set matches the manifest ($nsites site(s) in 4 files)"
    else
        fail "B: paste-buffer FILE SET changed — classify the new/removed site, do not widen this test."$'\n'"expected:"$'\n'"$want_files"$'\n'"got:"$'\n'"$got_files"
    fi
    unguarded=''
    while IFS= read -r site; do
        [[ -n "$site" ]] || continue
        f="${site%%:*}"
        # A MENTION IS NOT A CALL, and this check used to accept one.
        # Every consumer names `_tmux_pane_is_dead` three times: the
        # `declare -F` probe, the fallback DEFINITION, and the actual
        # call. A bare `grep -q` matches the first two, so DELETING THE
        # CALL from paste-followup.sh (the 20/20 `-p -d` form) or from
        # main.sh left this suite 31/31 GREEN — measured. The fallback
        # added in this very PR is what blinded it: before that, the
        # only mention WAS the call.
        #
        # Require a COMMAND-POSITION call, and require it to precede the
        # paste. `_tmux_pane_is_dead() {` (definition) and
        # `declare -F _tmux_pane_is_dead` (probe) are excluded by shape,
        # not by line number, so moving them cannot re-blind this.
        # `!seen` rather than `head -1`: an early-exit reader on the
        # right of a pipe under `pipefail` enters
        # early-exit-readers.manifest (#682) as a site a reviewer must
        # look at. Second time this manifest has caught this file;
        # draining a handful of lines costs nothing.
        call_line=$(command grep -nE '(^|[;&|]|\bif\b|\bthen\b|\belif\b|!)[[:space:]]*_tmux_pane_is_dead[[:space:]]' "$f" \
            | command grep -vE '_tmux_pane_is_dead[[:space:]]*\(\)' \
            | command grep -v 'declare -F' \
            | awk -F: '!seen { print $1; seen = 1 }')
        paste_line="${site#*:}"; paste_line="${paste_line%%:*}"
        if [[ -z "$call_line" ]]; then
            unguarded+="${unguarded:+$'\n'}$site (no command-position CALL to _tmux_pane_is_dead)"
        elif (( call_line >= paste_line )); then
            unguarded+="${unguarded:+$'\n'}$site (guard called at line $call_line, AFTER the paste at $paste_line)"
        fi
    done <<<"$paste_sites"
    if [[ -z "$unguarded" ]]; then
        pass "B: every paste-buffer call site's file calls _tmux_pane_is_dead"
    else
        fail "B: paste-buffer site(s) with no CALL to the guard before the paste — each can kill the tmux server (#745):"$'\n'"$unguarded"
    fi
    # ...and each of those files must also SOURCE the guard, or the call
    # is an rc-127 no-op.
    unsourced=''
    nofallback=''
    while IFS= read -r site; do
        [[ -n "$site" ]] || continue
        f="${site%%:*}"
        # A MENTION is not a source. `# shellcheck source=../_pane-live.sh`
        # is a comment; requiring a command-position `source`/`.` is what
        # makes deleting the real line red.
        command grep -qE '(^|&&)[[:space:]]*(source|\.)[[:space:]]+[^#]*_pane-live\.sh' "$f" \
            || unsourced+="${unsourced:+$'\n'}$f"
        # ...and the FAIL-CLOSED FALLBACK. The source is conditional (a
        # partial fixture tree legitimately lacks the file), so without a
        # fallback the guard call would be rc 127 — which reads as "not
        # dead" and silently restores the hazard in exactly the trees
        # least likely to be looked at.
        #
        # EXERCISED, NOT GREPPED. `grep -q 'declare -F …'` was the FOURTH
        # instance of the mention-vs-substance class in this file, found
        # by auditing for it rather than by a failure: it passes on a
        # fallback that has been gutted or inverted, and only ONE of the
        # four files had its fallback behaviourally covered. Extract each
        # file's block, run it with the real predicate absent, and demand
        # that it REFUSE.
        fb_block=$(sed -n '/^if ! declare -F _tmux_pane_is_dead/,/^fi$/p' "$f")
        if [[ -z "$fb_block" ]]; then
            nofallback+="${nofallback:+$'\n'}$f (no fallback block)"
        else
            fb_verdict=$(bash -c '
                '"$fb_block"'
                declare -F _tmux_pane_is_dead >/dev/null 2>&1 || { echo NOT-DEFINED; exit 0; }
                _tmux_pane_is_dead somewindow 2>/dev/null && echo REFUSES || echo ALLOWS' 2>/dev/null)
            [[ "$fb_verdict" == "REFUSES" ]] \
                || nofallback+="${nofallback:+$'\n'}$f (fallback verdict: ${fb_verdict:-<none>}, want REFUSES)"
        fi
    done <<<"$paste_sites"
    if [[ -z "$unsourced" ]]; then
        pass "B: every such file sources _pane-live.sh explicitly"
    else
        fail "B: file(s) call the guard without sourcing it (rc 127 reads as 'not dead'):"$'\n'"$unsourced"
    fi
    if [[ -z "$nofallback" ]]; then
        pass "B: every such file's fallback REFUSES when the real predicate is absent (exercised, not grepped)"
    else
        fail "B: file(s) whose fail-closed fallback does not refuse — a missing _pane-live.sh then reads as 'not dead':"$'\n'"$nofallback"
    fi

    # THE FALLBACK ITSELF, exercised rather than asserted. Load a copy of
    # the guard's consumer from a tree where _pane-live.sh does NOT exist
    # and confirm two things at once: the module still LOADS (a partial
    # fixture tree must not be bricked by a missing paste guard — CI
    # proved that the hard way), and the predicate refuses.
    fbtree="$WORK/nofile/monitor/watcher"
    mkdir -p "$fbtree"
    cp "$MON/watcher/_unstick.sh" "$fbtree/_unstick.sh"
    cp "$MON/_log-mode.sh" "$WORK/nofile/monitor/_log-mode.sh"
    fb=$(PATH="$STUB_EMPTY:$PATH" bash -c '
        . "'"$fbtree"'/_unstick.sh" >/dev/null 2>&1 || { echo "LOAD-FAILED"; exit 0; }
        declare -F _tmux_pane_is_dead >/dev/null 2>&1 || { echo "NO-FALLBACK"; exit 0; }
        _tmux_pane_is_dead somewindow 2>/dev/null && echo "REFUSES" || echo "ALLOWS"' 2>/dev/null)
    assert_eq "B: with _pane-live.sh ABSENT the module still loads and the guard REFUSES" "$fb" "REFUSES"
fi

# =====================================================================
echo '=== C: end-to-end — the helpers survive a real corpse ==='
# =====================================================================
# Positive control FIRST, in its own throwaway server: prove this
# fixture still reproduces the crash. Without it, "the server survived"
# below could mean the tmux stopped crashing, not that the guard works.
# WHETHER THIS TMUX HAS THE BUG IS ITSELF A MEASUREMENT, not an
# assumption. It is confirmed 20/20 on the tmux this workspace deploys
# (2.6); a newer tmux may well have fixed it. If it has, that is
# INFORMATION — it must not red the build, and it must not be allowed
# to make the survival assertions below look like evidence when they
# would pass on any tmux at all. So: record it, and gate only the
# claims that actually depend on it. The rc assertions (did the guard
# REFUSE?) are version-independent and always run.
HAZARD_REPRODUCES=0
new_server c1; SC1="$SOCK"
if make_corpse "$SC1" victim; then
    tx "$SC1" load-buffer -b b1 "$PAYLOAD" 2>/dev/null
    tx "$SC1" paste-buffer -b b1 -t victim >/dev/null 2>&1
    if server_alive "$SC1"; then
        pass "C: this tmux ($(tmux -V)) does NOT crash on an unguarded paste into a corpse — the survival checks below are therefore SKIPPED as vacuous; the refusal checks still run"
    else
        HAZARD_REPRODUCES=1
        pass "C: positive control — an UNGUARDED paste into the corpse killed the server (fixture reproduces #745)"
    fi
else
    fail "C: positive-control corpse never formed"
fi

# assert_survived <sock> <label> — only meaningful where the positive
# control established that an unguarded paste WOULD have killed it.
assert_survived() {
    local sock="$1" label="$2"
    if (( HAZARD_REPRODUCES == 0 )); then
        printf '  SKIP: %s (this tmux does not exhibit #745; assertion would be vacuous)\n' "$label"
        return 0
    fi
    if server_alive "$sock"; then pass "$label"; else fail "$label"; fi
}

# _paste_line_to_window (_unstick.sh) against a corpse
new_server c2; SC2="$SOCK"
route_tmux_to "$SC2"
if make_corpse "$SC2" victim; then
    ( . "$MON/watcher/_unstick.sh" >/dev/null 2>&1
      _paste_line_to_window victim "please continue" ) >/dev/null 2>&1
    rc=$?
    assert_survived "$SC2" "C: _paste_line_to_window refused — server SURVIVED"
    assert_eq "C: _paste_line_to_window returns its paste-failed rc" "$rc" "1"
else
    fail "C: corpse never formed for the _unstick leg"
fi

# _respawn_paste_prompt_file (_respawn.sh) against a corpse
new_server c3; SC3="$SOCK"
route_tmux_to "$SC3"
if make_corpse "$SC3" victim; then
    ( . "$MON/watcher/_respawn.sh" >/dev/null 2>&1
      _respawn_paste_prompt_file victim "$PAYLOAD" ) >/dev/null 2>&1
    rc=$?
    assert_survived "$SC3" "C: _respawn_paste_prompt_file refused — server SURVIVED"
    assert_eq "C: _respawn_paste_prompt_file returns 1" "$rc" "1"
else
    fail "C: corpse never formed for the _respawn leg"
fi

# paste-followup.sh (the -p -d form, 20/20 — the most lethal site) against
# a real corpse. Run the REAL CLI, not an extraction: this leg had NO
# behavioural coverage at all, and deleting its guard left the suite green.
new_server c5; SC5="$SOCK"
route_tmux_to "$SC5"
if make_corpse "$SC5" victim; then
    pf_state=$(mktemp -d "$WORK/pfstate.XXXXXX")
    pf_out=$(env "NEXUS_STATE_DIR=$pf_state" "NEXUS_CC_HOME=$WORK/cc" \
                 "PASTE_CONFIRM_TIMEOUT_SECONDS=2" "PASTE_CONFIRM_POLL_SECONDS=0.05" \
                 bash "$MON/paste-followup.sh" victim --message 'poke the corpse' 2>&1)
    pf_rc=$?
    assert_survived "$SC5" "C: paste-followup.sh refused — server SURVIVED"
    if (( pf_rc != 0 )); then
        pass "C: paste-followup.sh refused with a non-zero rc (got $pf_rc)"
    else
        fail "C: paste-followup.sh returned 0 on a DEAD pane — it pasted, or claimed success"
    fi
    case "$pf_out" in
        *745*|*"DEAD pane"*) pass "C: paste-followup.sh names the reason (#745 / DEAD pane)" ;;
        *) fail "C: paste-followup.sh refused without naming the dead pane: ${pf_out:0:160}" ;;
    esac
else
    fail "C: corpse never formed for the paste-followup leg"
fi

# main.sh's _paste_to_target_unlocked against a real corpse. main.sh runs
# its whole loop at source time, so extract the function body — the same
# device test-target-config.sh:244 uses — and drive the REAL code with the
# few globals this path touches stubbed.
new_server c6; SC6="$SOCK"
route_tmux_to "$SC6"
if make_corpse "$SC6" orchestrator; then
    m_body=$(sed -n '/^_paste_to_target_unlocked() {/,/^}/p' "$MON/watcher/main.sh")
    if [[ -z "$m_body" ]]; then
        fail "C: could not extract _paste_to_target_unlocked() from main.sh"
    else
        m_rc=$(
            PATH="$WORK/bin:$PATH" bash -c '
                . "'"$MON"'/_pane-live.sh"
                log() { :; }
                '"$m_body"'
                _paste_to_target_unlocked orchestrator "'"$PAYLOAD"'" >/dev/null 2>&1
                echo $?' 2>/dev/null
        )
        assert_survived "$SC6" "C: main.sh _paste_to_target_unlocked refused — server SURVIVED"
        assert_eq "C: main.sh _paste_to_target_unlocked returns the non-retryable rc 5" "$m_rc" "5"
    fi
else
    fail "C: corpse never formed for the main.sh leg"
fi

# ...and the guarded helpers must still DELIVER into a live pane.
# A guard that refuses everything would pass every assertion above.
new_server c4; SC4="$SOCK"
route_tmux_to "$SC4"
tx "$SC4" new-window -d -n alive 'sleep 120' 2>/dev/null
sleep 0.3
( . "$MON/watcher/_unstick.sh" >/dev/null 2>&1
  _paste_line_to_window alive "still delivering" ) >/dev/null 2>&1
rc=$?
assert_eq "C: NON-VACUITY — live pane still receives the paste (rc=0)" "$rc" "0"
server_alive "$SC4" && pass "C: live-pane server unharmed" || fail "C: live-pane server died"

# =====================================================================
echo '=== D: the parsing contract, against a STUB tmux ==='
# =====================================================================
# Real tmux only ever emits `0` or `1` for `#{pane_dead}`, so the choice
# between an ALLOWLIST (`== "1"` is dead) and a DENYLIST (`!= "0"` is
# dead) is invisible to parts A-C — measured: that mutant SURVIVED the
# real-tmux suite 20/20. It is not a cosmetic choice. On a tmux that
# does not know the format the field expands EMPTY, and the two
# readings diverge completely:
#
#   allowlist  empty -> not dead -> paste proceeds (today's behaviour)
#   denylist   empty -> dead     -> EVERY paste refused, forever: the
#                                   watcher goes silent, no worker is
#                                   ever woken, and nothing is red
#
# A stub is the right instrument here precisely because these rows are
# ones real tmux cannot produce. The semantics stay in parts A-C.
STUB="$WORK/stub"; mkdir -p "$STUB"
stub_rows() {
    cat > "$STUB/tmux" <<STUBEOF
#!/usr/bin/env bash
[[ "\$1" == "list-panes" ]] || exit 0
exit_rc=${2:-0}
(( exit_rc == 0 )) || exit "\$exit_rc"
cat <<'ROWS'
$1
ROWS
STUBEOF
    chmod +x "$STUB/tmux"
}
with_stub() { PATH="$STUB:$PATH" bash -c '. "'"$MON"'/_pane-live.sh"; _tmux_pane_is_dead "$1"; echo $?' _ "$1"; }

stub_rows 'orchestrator|@1|%1|1|'
assert_eq "D: pane_dead EMPTY (tmux too old) -> rc=1, paste still proceeds" "$(with_stub orchestrator)" "1"
stub_rows 'orchestrator|@1|%1|1|yes'
assert_eq "D: pane_dead garbage 'yes' -> rc=1" "$(with_stub orchestrator)" "1"
stub_rows 'orchestrator|@1|%1|1|11'
assert_eq "D: pane_dead '11' is not '1' -> rc=1" "$(with_stub orchestrator)" "1"
stub_rows 'orchestrator|@1|%1|1|0'
assert_eq "D: pane_dead 0 -> rc=1 (live)" "$(with_stub orchestrator)" "1"
stub_rows 'orchestrator|@1|%1|1|1'
assert_eq "D: pane_dead 1 -> rc=0 (dead, REFUSE)" "$(with_stub orchestrator)" "0"
stub_rows 'orchestrator'
assert_eq "D: malformed row, no delimiters -> rc=1" "$(with_stub orchestrator)" "1"
# a dead pane in a DIFFERENT window must not condemn the target
stub_rows 'other|@2|%2|1|1
orchestrator|@1|%1|1|0'
assert_eq "D: another window's corpse -> rc=1" "$(with_stub orchestrator)" "1"
# the documented ambiguity rule: duplicate names, one active pane dead
stub_rows 'orchestrator|@1|%1|1|0
orchestrator|@2|%2|1|1'
assert_eq "D: duplicate name, one active pane DEAD -> rc=0 (errs to refuse)" "$(with_stub orchestrator)" "0"
# an INACTIVE dead pane in the target window is not what a paste hits
stub_rows 'orchestrator|@1|%1|1|0
orchestrator|@1|%3|0|1'
assert_eq "D: inactive dead pane in the target window -> rc=1" "$(with_stub orchestrator)" "1"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "SOME TESTS FAILED" >&2; exit 1; fi
echo "ALL TESTS PASSED"
exit 0
