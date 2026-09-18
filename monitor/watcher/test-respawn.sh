#!/usr/bin/env bash
# Unit tests for monitor/watcher/_respawn.sh — the shared respawn
# primitives that back BOTH recovery paths:
#
#   - main.sh respawn_agent           (target window missing)
#   - spawn-fresh-orchestrator.sh    (target alive but unresponsive)
#
# Issue #161: pre-fix, respawn_agent execed
#   "$CLAUDE_BIN" --dangerously-skip-permissions "$prompt"
# WITHOUT --continue, silently discarding the prior orchestrator
# session on every window-absent respawn. spawn-fresh-orchestrator
# already had --continue by default (PR #158).
#
# Issue #176 (PR #177): when the orchestrator session-id pin is valid
# the helper upgrades to `--resume <pinned-sid>` (deterministic).
#
# Issue #200 (this change): the pin-MISSING degradation is no longer
# `--continue`. `--continue` grabs the arbitrary freshest jsonl in the
# project dir, which resurrected a transient recovery session during
# the 2026-05-29 crash recovery (second death). The safe degradation
# is a COLD spawn (no --resume, no --continue). So the contract these
# tests assert is now:
#   pin valid           → launcher carries `--resume <sid>`, NOT --continue
#   pin missing/stale    → launcher carries NEITHER --resume NOR --continue
#   --no-continue        → cold spawn even with a valid pin
#   --resume-sid <sid>   → caller override wins over pin auto-detect
#
# Run directly: bash monitor/watcher/test-respawn.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$label (got $got)"
    else
        fail "$label — got $got want $want"
    fi
}

assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        pass "$label"
    else
        fail "$label — missing literal: $needle"
    fi
}

assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        fail "$label — unexpectedly found: $needle"
    else
        pass "$label"
    fi
}

# --- harness -----------------------------------------------------------

WORK=$(mktemp -d -t nexus-respawn-test-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Isolate launcher temp files into our own $WORK so a parallel CI
# run (run-tests.sh --jobs 2) can't collide with another test
# globbing /tmp/nexus-respawn-launch-*. The helper honours
# $RESPAWN_TMPDIR; production keeps /tmp default.
export RESPAWN_TMPDIR="$WORK/launchers"
mkdir -p "$RESPAWN_TMPDIR"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor/.state" \
         "$FAKE_NEXUS/monitor/watcher" \
         "$FAKE_NEXUS/node_modules/.bin"

# Provide _claude-bin.sh + a stub claude binary at the project-local
# install location. _claude-bin.sh prefers the project-local install
# over PATH; the helper sources this file to resolve $CLAUDE_BIN.
cp "$_test_dir/../_claude-bin.sh" "$FAKE_NEXUS/monitor/_claude-bin.sh"
cat > "$FAKE_NEXUS/node_modules/.bin/claude" <<'CLAUDE_STUB'
#!/bin/bash
echo "stub-claude: $*"
CLAUDE_STUB
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"

# Stub tmux that records every invocation. Defaults: target window
# IS present (so kill-window fires) and tmux verbs return 0.
TMUX_STUB_BIN="$WORK/stub-bin"
mkdir -p "$TMUX_STUB_BIN"
TMUX_LOG="$WORK/tmux-calls.log"
: > "$TMUX_LOG"
# Declared here (not beside its stub, further down) so the pane-state stub
# below can bake in BOTH log paths: an arm driven by the capture stub logs
# its Enter to THIS file, and the pane must go busy for that arm too.
TMUX_CAP_LOG="$WORK/tmux-calls-cap.log"
: > "$TMUX_CAP_LOG"

cat > "$TMUX_STUB_BIN/tmux" <<STUB
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$TMUX_LOG"
case "\$1" in
    list-windows)
        fmt="\$3"
        if [[ -f "$WORK/tmux-target-absent" ]] && ! grep -q 'new-window' "$TMUX_LOG"; then
            names=("watcher")
        else
            names=("watcher" "orchestrator")
        fi
        idx=0
        for n in "\${names[@]}"; do
            case "\$fmt" in
                '#{window_name}'|'')              printf '%s\n' "\$n" ;;
                '#I #W')                          printf '%d %s\n' "\$idx" "\$n" ;;
                '#{window_index}|#{window_name}') printf '%d|%s\n' "\$idx" "\$n" ;;
                *)                                printf '%s\n' "\$n" ;;
            esac
            idx=\$(( idx + 1 ))
        done
        ;;
    new-window)
        # -P -F '#{window_id}' makes tmux print the id of the window it just
        # created, and _respawn_spawn_window keys its rc=3 contract on that
        # handle rather than on a presence-by-NAME probe (your-org/nexus-code
        # #1327). A stub answering with ZERO BYTES models "created nothing",
        # so the arm has to speak the handle or every spawn reads as a
        # failure. Most stubs in this corpus already do -- spawn-worker.sh
        # has used the same discriminator since #323; the respawn family
        # was the outlier, in the code and in its fixtures alike.
        #
        # NO BACKTICKS IN THIS HEREDOC. It is UNQUOTED (<<STUB), so a
        # backticked word in a COMMENT is command-substituted when the
        # fixture is written -- measured at HEAD: six `command not found`
        # lines per run, from this very comment (your-org/nexus-code#1157).
        printf '@7\n'
        exit 0
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$TMUX_STUB_BIN/tmux"

# Stub pane-state.sh. STATEFUL BY NECESSITY (your-org/nexus-code#1470).
#
# The respawn path asks pane-state TWO questions whose accepted answers are
# DISJOINT: readiness accepts `empty|idle`, post-paste submit-evidence accepts
# `busy` (it accepted `busy|user-typing` until the typed-retry arms below
# showed `user-typing` is the signature of an UNSUBMITTED brief). A static
# stub can satisfy at most one of them, and the
# static `idle` this used to print satisfied readiness while making
# submit-evidence UNREACHABLE. Worse, the tmux stub kept the target window
# ABSENT for the whole call, so `_respawn_probe_state` could never resolve an
# index and pane-state was NEVER INVOKED AT ALL -- measured: zero calls across
# the entire suite. Every arm therefore drove the exhausted-retry path and
# asserted rc 0 on it, which is the #1470 defect pinned as expected behaviour
# by its own regression suite. Six arms went red the moment the helper began
# reporting an undelivered brief honestly.
#
# So presence and busy-ness are both CAUSED, not scripted: the tmux stubs
# reveal the window once `new-window` appears in their log, and this stub
# reports `busy` once an `Enter` appears there. Both derive from a log the
# arms already truncate between scenarios, so nothing leaks between arms and
# no new bookkeeping is added. `PSTUB_SUBMIT_EVIDENCE=0` pins it to `idle`
# forever: that is the FAILURE arm -- the paste landed and no turn began.
PANE_STATE_STUB="$FAKE_NEXUS/monitor/pane-state.sh"
cat > "$PANE_STATE_STUB" <<PSTUB
#!/bin/bash
# PSTUB_TYPING_ENTERS=N: the brief LANDS but does not submit until the Enter
# count exceeds N. Before any Enter the pane is idle (readiness); after 1..N
# Enters it reads user-typing with typed input -- the brief sitting in the box,
# measured 2026-09-11 -- and only after Enter N+1 does it go busy. Caused by
# the tmux logs, like the arm below, so it self-resets with them.
if [ -n "\${PSTUB_TYPING_ENTERS:-}" ]; then
    n=\$(cat "$TMUX_LOG" "$TMUX_CAP_LOG" 2>/dev/null | grep -c 'send-keys .* Enter')
    if [ "\$n" -eq 0 ]; then
        printf 'state=idle active=1 window=%s name=orchestrator\\n' "\$1"
    elif [ "\$n" -le "\$PSTUB_TYPING_ENTERS" ]; then
        # PSTUB_TYPING_INPUT picks the input= value (default typed); `none`
        # drops the field entirely.
        case "\${PSTUB_TYPING_INPUT:-typed}" in
            none) printf 'state=user-typing active=1 window=%s name=orchestrator\\n' "\$1" ;;
            *)    printf 'state=user-typing active=1 window=%s name=orchestrator input=%s\\n' "\$1" "\${PSTUB_TYPING_INPUT:-typed}" ;;
        esac
    else
        printf 'state=busy active=1 window=%s name=orchestrator\\n' "\$1"
    fi
    exit 0
fi
# The pane reports \`busy\` only AFTER an Enter has been sent -- read off the
# tmux stubs' own logs, so the answer is CAUSED by the paste rather than by a
# call count, and self-resets with the log truncation every arm already does.
# Both logs are consulted: an arm may be driven by either stub.
if [ "\${PSTUB_SUBMIT_EVIDENCE:-1}" = "1" ] \\
   && grep -qs 'send-keys .* Enter' "$TMUX_LOG" "$TMUX_CAP_LOG"; then
    printf 'state=busy active=1 window=%s name=orchestrator\\n' "\$1"
else
    printf 'state=idle active=1 window=%s name=orchestrator\\n' "\$1"
fi
PSTUB
chmod +x "$PANE_STATE_STUB"

# Seed orchestrator-settings.json so the helper picks up --settings.
cat > "$FAKE_NEXUS/monitor/orchestrator-settings.json" <<'EOF'
{ "hooks": {} }
EOF

# Source the unit under test in a subshell-friendly way. We need
# `log` and `_respawn_orchestrator` callable in our process.
log() { :; }   # silent for the tests that don't care about log output

# --- Test 1: helper passes --continue by default -----------------------

echo '=== window-absent path, no pin: helper degrades to a COLD spawn (issue #200) ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"

launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

# Subshell so we don't pollute the parent's NEXUS_ROOT / functions.
(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator
) 2>"$WORK/stderr-1.log"
rc=$?
assert_eq "exit 0 on bare spawn (no prompt-file)" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    # Helper must honour $RESPAWN_TMPDIR (regression coverage for the
    # PR #166 parallel-CI flake: pre-fix the launcher landed in /tmp
    # and two concurrent tests' globs raced each other).
    case "$new_launcher" in
        "$RESPAWN_TMPDIR"/*) pass "launcher landed under \$RESPAWN_TMPDIR ($new_launcher)" ;;
        *) fail "launcher landed outside \$RESPAWN_TMPDIR: $new_launcher" ;;
    esac
    assert_not_contains "no-pin launcher OMITS --continue (issue #200 safe degradation)" "$body" "--continue"
    assert_not_contains "no-pin launcher OMITS --resume (nothing to resume)" "$body" "--resume"
    assert_contains "launcher carries --dangerously-skip-permissions" \
                    "$body" "--dangerously-skip-permissions"
    assert_contains "launcher carries --settings <orchestrator-settings.json>" \
                    "$body" "--settings $FAKE_NEXUS/monitor/orchestrator-settings.json"
    assert_contains "launcher exports NEXUS_IS_ORCHESTRATOR marker" \
                    "$body" "export NEXUS_IS_ORCHESTRATOR=1"
    assert_contains "launcher exports NEXUS_ROOT" \
                    "$body" "export NEXUS_ROOT=\"$FAKE_NEXUS\""
    # Configurable-target plumbing: the launcher must carry the target
    # window so the session-pin hook's self-rename agrees with the
    # watcher's targeting (here: the default name, passed through).
    assert_contains "launcher exports NEXUS_ORCHESTRATOR_WINDOW=<target>" \
                    "$body" 'export NEXUS_ORCHESTRATOR_WINDOW="orchestrator"'
else
    fail "no launcher tempfile produced under $RESPAWN_TMPDIR/nexus-respawn-launch-*"
fi

tmux_log=$(cat "$TMUX_LOG")
assert_contains "tmux new-window invoked for target" \
                "$tmux_log" "new-window -d -n orchestrator"
assert_contains "tmux set-window-option remain-on-exit on" \
                "$tmux_log" "set-window-option -t orchestrator remain-on-exit on"
# Window-name pin (issue 209): without these, tmux's rename loop or an
# OSC escape can rename the window away from the watcher's target.
assert_contains "tmux set-window-option automatic-rename off (issue 209)" \
                "$tmux_log" "set-window-option -t orchestrator automatic-rename off"
assert_contains "tmux set-window-option allow-rename off (issue 209)" \
                "$tmux_log" "set-window-option -t orchestrator allow-rename off"

# --- Test 2: --no-continue opts out ------------------------------------

echo '=== --no-continue: launcher omits --continue (fresh boot) ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"   # absent-path premise: window gone, re-verify passes (#203)
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator --no-continue
) 2>"$WORK/stderr-2.log"
rc=$?
assert_eq "exit 0 with --no-continue" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_not_contains "launcher OMITS --continue under --no-continue" "$body" "--continue"
    assert_contains "launcher still carries --settings" "$body" "--settings"
else
    fail "no launcher tempfile produced on --no-continue path"
fi

# --- Test 3: prompt-file delivery ---------------------------------------

echo '=== --prompt-file: helper paste-buffers the prompt and sends Enter ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"   # absent-path premise (#203)

PROMPT="$WORK/test-prompt.txt"
cat > "$PROMPT" <<'EOF'
test recovery prompt body
EOF

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator --prompt-file "$PROMPT"
) 2>"$WORK/stderr-3.log"
rc=$?
assert_eq "exit 0 when prompt-file delivery succeeds" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

tmux_log=$(cat "$TMUX_LOG")
assert_contains "load-buffer received the prompt file" \
                "$tmux_log" "load-buffer -b nexus-respawn"
assert_contains "paste-buffer targeted the new window" \
                "$tmux_log" "paste-buffer -p -b nexus-respawn"
assert_contains "send-keys submitted Enter after paste" \
                "$tmux_log" "send-keys -t orchestrator Enter"

# --- Test 3b: the post-paste verification DECIDES the rc (#1470) --------
#
# A PAIR, varying exactly ONE thing: whether the pane ever reports a
# submitted turn. Everything else -- the spawn, the paste, the Enter -- is
# byte-identical between the arms, which is what makes the failing arm
# evidence about the VERIFICATION rather than about the transport.
#
# Before #1470 both arms returned 0: `paste_rc` was set only when `tmux
# send-keys` itself failed, so the function reported the TRANSPORT's success
# and never the OUTCOME's. Test 3 above is the positive half of this pair --
# it now genuinely reaches `state=busy` -- and this is the negative half.

echo '=== #1470: submit-evidence PRESENT vs ABSENT decides the return code ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"
: > "$WORK/respawn-1470.log"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS
    # THE ONE VARIABLE: the pane never leaves `idle`, so the Enter never
    # produces a turn. This is the production signature -- both recorded
    # incidents read `last state='unknown'`, the state that means "could not
    # look at all", and resolving THAT as delivered is the permissive-default
    # arm CLAUDE.md singles out for kill decisions, applied to a delivery.
    PSTUB_SUBMIT_EVIDENCE=0
    export PSTUB_SUBMIT_EVIDENCE

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"
    log() { printf '%s\n' "$1" >> "$WORK/respawn-1470.log"; }

    _respawn_orchestrator orchestrator --prompt-file "$PROMPT" --log-fn log
) 2>"$WORK/stderr-3b.log"
rc=$?
rm -f "$WORK/tmux-target-absent"

assert_eq "rc 4 when the pane NEVER reports a submitted turn" "$rc" "4"

tmux_log_3b=$(cat "$TMUX_LOG")
respawn_log_3b=$(cat "$WORK/respawn-1470.log")

# THE DISCRIMINATOR: the transport succeeded end to end. Without these two the
# rc 4 above would be satisfied by a fixture in which the paste simply never
# happened, and the arm would prove nothing about verification.
assert_contains "…and the paste-buffer still landed (the transport SUCCEEDED)" \
                "$tmux_log_3b" "paste-buffer -p -b nexus-respawn"
assert_contains "…and Enter was still sent" \
                "$tmux_log_3b" "send-keys -t orchestrator Enter"

assert_contains "…the retry fired first (the fix is not fewer retries)" \
                "$respawn_log_3b" "retrying Enter once"
assert_contains "…and exhausting it is REPORTED, not passed through" \
                "$respawn_log_3b" "reporting UNDELIVERED (rc 4)"

# --- Test 3c: `user-typing` is NOT submit evidence; typed input gets Enter ---
#
# Measured 2026-09-11: watcher.log 04:28:06 logged "post-paste verify (after
# retry): state=user-typing — turn submitted" while the recovery brief sat in
# the orchestrator's input box (`state=user-typing input=typed`) for ~5.5 min,
# until one hand-sent Enter submitted it. The old predicate accepted
# `busy|user-typing`, so #1470's UNDELIVERED arm could not fire for this shape.
#
# Every arm below differs from the others only in the pane's answer; the paste
# and the Enter transport are identical. THE ENTER COUNT is the discriminator
# the rc alone cannot give: pre-fix, A2 also returns 0 — after ONE Enter,
# having mistaken the typed box for a submitted turn.
ARM_RC=0
ARM_ENTERS=0
run_typed_arm() {   # run_typed_arm <logfile> [NAME=value…]
    ARM_LOG="$1"; shift
    : > "$TMUX_LOG"
    : > "$ARM_LOG"
    touch "$WORK/tmux-target-absent"
    (
        export NEXUS_ROOT="$FAKE_NEXUS" PATH="$TMUX_STUB_BIN:$PATH" PANE_STATE_BIN="$PANE_STATE_STUB"
        export FRESH_SPAWN_READINESS_BUDGET_SECONDS=2 FRESH_SPAWN_READINESS_POLL_SECONDS=0
        export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
        export FRESH_SPAWN_SUBMIT_TYPED_RETRY_BUDGET_SECONDS=4 FRESH_SPAWN_SUBMIT_TYPED_RETRY_INTERVAL_SECONDS=1
        for kv in "$@"; do export "$kv"; done
        # shellcheck source=_respawn.sh
        . "$_test_dir/_respawn.sh"
        log() { printf '%s\n' "$1" >> "$ARM_LOG"; }
        _respawn_orchestrator orchestrator --prompt-file "$PROMPT" --log-fn log
    ) 2>"$ARM_LOG.stderr"
    ARM_RC=$?
    rm -f "$WORK/tmux-target-absent"
    ARM_ENTERS=$(grep -c 'send-keys -t orchestrator Enter' "$TMUX_LOG")
}

echo '=== 3c A1: the brief sits typed in the box and never submits → rc 4, not "submitted" ==='
run_typed_arm "$WORK/typed-a1.log" PSTUB_TYPING_ENTERS=999
assert_eq "A1 rc 4 — a typed, unsubmitted brief is UNDELIVERED" "$ARM_RC" "4"
assert_not_contains "A1 never logs 'turn submitted'" "$(cat "$WORK/typed-a1.log")" "turn submitted"
assert_contains "A1 the typed-retry fired" "$(cat "$WORK/typed-a1.log")" "typed-retry 1"
assert_contains "A1 exhaustion is REPORTED" "$(cat "$WORK/typed-a1.log")" "reporting UNDELIVERED (rc 4)"
if (( ARM_ENTERS >= 3 )); then
    pass "A1 Enter re-sent while the box held typed text (${ARM_ENTERS} Enters)"
else
    fail "A1 expected >= 3 Enters (paste + retry + typed-retry), got ${ARM_ENTERS}"
fi

echo '=== 3c A2: Enter is ignored twice more, then takes → rc 0 after typed-retries ==='
run_typed_arm "$WORK/typed-a2.log" PSTUB_TYPING_ENTERS=3
assert_eq "A2 rc 0 once a later Enter actually submits" "$ARM_RC" "0"
assert_eq "A2 exactly 4 Enters: paste, retry, two typed-retries" "$ARM_ENTERS" "4"
assert_contains "A2 logs the typed-retry submission" "$(cat "$WORK/typed-a2.log")" "typed-retries): state=busy — turn submitted"

echo '=== 3c A3: a normal submit is untouched — ONE Enter, no typed-retry ==='
run_typed_arm "$WORK/typed-a3.log"
assert_eq "A3 rc 0" "$ARM_RC" "0"
assert_eq "A3 exactly 1 Enter" "$ARM_ENTERS" "1"
assert_not_contains "A3 no typed-retry" "$(cat "$WORK/typed-a3.log")" "typed-retry"

echo '=== 3c A4: an IDLE pane gets the single #1470 retry and no typed-retry ==='
run_typed_arm "$WORK/typed-a4.log" PSTUB_SUBMIT_EVIDENCE=0
assert_eq "A4 rc 4" "$ARM_RC" "4"
assert_eq "A4 exactly 2 Enters (no hammering a pane with nothing in its box)" "$ARM_ENTERS" "2"
assert_not_contains "A4 no typed-retry" "$(cat "$WORK/typed-a4.log")" "typed-retry"

echo '=== 3c A5: budget 0 disables the typed-retry, and typed is STILL not submitted ==='
run_typed_arm "$WORK/typed-a5.log" PSTUB_TYPING_ENTERS=999 FRESH_SPAWN_SUBMIT_TYPED_RETRY_BUDGET_SECONDS=0
assert_eq "A5 rc 4" "$ARM_RC" "4"
assert_eq "A5 exactly 2 Enters" "$ARM_ENTERS" "2"

# A6/A7 (w234sk F8): the typed-retry is an ALLOWLIST. Enter is pressed only on
# a positive `input=typed`. `input=?` is undecidable, and CLAUDE.md says to read
# it as a draft; a line with no `input=` field has said nothing about the box.
# Both must get the single #1470 retry and no typed-retry.
echo '=== 3c A6: user-typing with input=? → NO typed-retry (an undecidable box is a draft) ==='
run_typed_arm "$WORK/typed-a6.log" PSTUB_TYPING_ENTERS=999 'PSTUB_TYPING_INPUT=?'
assert_eq "A6 rc 4" "$ARM_RC" "4"
assert_eq "A6 exactly 2 Enters (paste + the single retry)" "$ARM_ENTERS" "2"
assert_not_contains "A6 no typed-retry" "$(cat "$WORK/typed-a6.log")" "typed-retry"

echo '=== 3c A7: user-typing with NO input= field → NO typed-retry ==='
run_typed_arm "$WORK/typed-a7.log" PSTUB_TYPING_ENTERS=999 PSTUB_TYPING_INPUT=none
assert_eq "A7 rc 4" "$ARM_RC" "4"
assert_eq "A7 exactly 2 Enters" "$ARM_ENTERS" "2"
assert_not_contains "A7 no typed-retry" "$(cat "$WORK/typed-a7.log")" "typed-retry"

# --- Test 3d: the FORKED fresh-spawn path re-arms requests on rc 4 too ------
#
# w234sk F5. spawn-fresh-orchestrator.sh exits 4 when the window was replaced
# but the brief never became a turn. #1470 taught respawn_agent to re-arm
# claimed requests on that code; the forked path the orchestrator-liveness state
# machine launches reset them only on 0. The typed-retry above now turns a
# typed-but-unsubmitted brief into rc 4 instead of a false 0, so that path would
# strand still-claimed requests. The body is a top-level function so a stub
# exiting a chosen code can drive it.
echo '=== w234sk F5: _orch_fresh_spawn_forked resets delivery state on rc 0 AND rc 4, not on 3 ==='
FORK_DIR="$WORK/fork-scripts"
mkdir -p "$FORK_DIR"
cat > "$FORK_DIR/spawn-fresh-orchestrator.sh" <<'FSO'
#!/bin/bash
exit "${FORK_STUB_RC:-0}"
FSO
chmod +x "$FORK_DIR/spawn-fresh-orchestrator.sh"
fork_body=$(awk '/^_orch_fresh_spawn_forked\(\) \{$/ {c=1} c {print} c && /^\}$/ {exit}' "$_test_dir/main.sh")
if [[ -n "$fork_body" ]]; then
    pass "extracted _orch_fresh_spawn_forked from main.sh (the rc cases below exercise the real body)"
else
    fail "could not extract _orch_fresh_spawn_forked from main.sh; the rc cases below would prove nothing"
fi
FORK_RESET=0
FORK_LOG=""
fork_case() {   # fork_case <stub-rc> → sets FORK_RESET=0|1 and FORK_LOG
    rm -f "$WORK/fork-reset" "$WORK/fork.log"
    (
        _script_dir="$FORK_DIR"
        TARGET=orchestrator
        NEXUS_ROOT="$FAKE_NEXUS"
        STATE_DIR="$FAKE_NEXUS/monitor/.state"
        LOGFILE="$WORK/fork-child.log"
        export FORK_STUB_RC="$1"
        _close_inherited_locks() { :; }
        log() { printf '%s\n' "$*" >> "$WORK/fork.log"; }
        requests_reset_delivery_state() { : > "$WORK/fork-reset"; }
        sandbox-notify() { :; }
        eval "$fork_body"
        _orch_fresh_spawn_forked "prev-sid" "respawn-test"
    ) 2>>"$WORK/fork-stderr.log"
    if [[ -f "$WORK/fork-reset" ]]; then FORK_RESET=1; else FORK_RESET=0; fi
    FORK_LOG=$(cat "$WORK/fork.log" 2>/dev/null)
}
fork_case 0
assert_eq "F5 rc 0: delivery state reset (unchanged)" "$FORK_RESET" "1"
assert_contains "F5 rc 0: logged as success (unchanged)" "$FORK_LOG" "orchestrator fresh-spawn (forked) succeeded"
fork_case 4
assert_eq "F5 rc 4: delivery state reset, because the window WAS replaced (#1470's rule, now on the fork path)" "$FORK_RESET" "1"
assert_contains "F5 rc 4: logged as undelivered, not as success" "$FORK_LOG" "NOT delivered (rc 4)"
fork_case 3
assert_eq "F5 rc 3: no reset, since nothing was replaced" "$FORK_RESET" "0"

# --- Test 4: settings absent → launcher omits --settings ---------------

echo '=== orchestrator-settings.json absent: launcher omits --settings ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"   # absent-path premise (#203)
mv "$FAKE_NEXUS/monitor/orchestrator-settings.json" "$WORK/settings-backup.json"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator
) 2>"$WORK/stderr-4.log"
rc=$?
assert_eq "exit 0 when settings file absent" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_not_contains "launcher OMITS --settings when file absent" "$body" "--settings"
    assert_not_contains "no-pin launcher still OMITS --continue (issue #200)" "$body" "--continue"
else
    fail "no launcher tempfile produced on settings-absent path"
fi
mv "$WORK/settings-backup.json" "$FAKE_NEXUS/monitor/orchestrator-settings.json"

# --- Test 5: integration via main.sh respawn_agent ---------------------
#
# Source main.sh in a way that defines respawn_agent without running
# the main loop. Then call respawn_agent and assert the launcher
# carries --continue (the issue #161 acceptance criterion).

echo '=== respawn_agent (main.sh) integration, no pin: launcher is a COLD spawn (issue #200) ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"   # absent-path premise: respawn_agent omits --force-replace (#203)
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

# main.sh sources _lib.sh and _respawn.sh from $_script_dir. It also
# expects config/load.sh + a couple of env vars before reaching the
# main loop. Simplest path: NEXUS_ROOT_OVERRIDE the script-leveled
# globals to avoid running it. Use a subshell + ad-hoc redefinition
# of main_loop to a no-op, and trap exit before the dispatcher kicks
# off. But that path is fragile.
#
# Easier: extract the fragments we need. Source _lib.sh + _respawn.sh
# directly, then DEFINE respawn_agent INLINE here using the body from
# main.sh and verify it calls the helper. The fragment-test catches
# the integration concern (does respawn_agent route through the
# helper?) without bootstrapping the whole watcher loop.

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS

    # Required by respawn_agent's _respawn_consec_record_failure
    # call path (we won't trip it, but the var must be set).
    RESPAWN_CONSEC_COUNTER="$WORK/consec-counter.txt"
    _monitor_dir="$FAKE_NEXUS/monitor"

    # Pull in helpers respawn_agent depends on.
    # shellcheck source=_lib.sh
    . "$_test_dir/_lib.sh"
    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"
    # shellcheck source=_respawn_prompts.sh
    . "$_test_dir/_respawn_prompts.sh"

    log() { :; }

    # Extract respawn_agent's body from main.sh and source it. This
    # is robust to body changes — we read the live code, not a
    # transcribed copy. awk emits everything between `^respawn_agent\(\) \{`
    # and its matching `^\}`.
    respawn_agent_body=$(awk '
        /^respawn_agent\(\) \{$/ { capture = 1 }
        capture { print }
        capture && /^\}$/ { capture = 0 }
    ' "$_test_dir/main.sh")
    eval "$respawn_agent_body"

    respawn_agent orchestrator
) 2>"$WORK/stderr-5.log"
rc=$?
assert_eq "respawn_agent exit 0" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_not_contains "respawn_agent no-pin launcher OMITS --continue (issue #200)" \
                        "$body" "--continue"
    assert_not_contains "respawn_agent no-pin launcher OMITS --resume" \
                        "$body" "--resume"
    assert_contains "respawn_agent launcher carries --dangerously-skip-permissions" \
                    "$body" "--dangerously-skip-permissions"
else
    fail "respawn_agent did not produce a launcher tempfile"
fi

# The recovery prompt on the cold path must NOT claim context was
# resumed — it must tell the agent it has no prior context and to
# re-onboard. (respawn_agent uses a capturing tmux stub only in
# Test 11; here we assert the launcher contract. The prompt-body
# contract for the cold path is asserted in Test 12 below.)

# --- Test 5b: rc 4 through main.sh is SAFE as well as loud (#1470) ------
#
# Making an exhausted submit verification report honestly (commit above)
# makes rc 4 reachable for the first time in normal operation. Until then it
# fired only when `tmux send-keys` itself failed or the prompt-file was
# missing, and `respawn_agent` handled it in the `*)` arm -- which returns
# BEFORE `requests_reset_delivery_state`. So the window would be replaced,
# every still-claimed request would stay claimed by a session that no longer
# exists, and nothing would be left to re-arm them.
#
# That is the same defect class one step downstream: a manufactured success
# traded for a silent stranding. This arm exists because nothing else
# observes the new code path -- an unexercised recovery arm is exactly how
# the #1470 stranding survived in the first place.

echo '=== #1470: rc 4 through respawn_agent re-arms requests AND reports failure ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"
rm -f "$WORK/reset-called" "$WORK/ng-calls.log" "$WORK/respawn-agent-1470.log"

# `ng` stub: respawn_agent action-logs through "$_monitor_dir/ng", guarded by
# a `-x` test, so without this the action-log half is silently skipped and the
# assertion below would pass vacuously.
cat > "$FAKE_NEXUS/monitor/ng" <<NGSTUB
#!/bin/bash
printf '%s\n' "ng \$*" >> "$WORK/ng-calls.log"
exit 0
NGSTUB
chmod +x "$FAKE_NEXUS/monitor/ng"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS
    PSTUB_SUBMIT_EVIDENCE=0          # the pane never reports a submitted turn
    export PSTUB_SUBMIT_EVIDENCE

    RESPAWN_CONSEC_COUNTER="$WORK/consec-counter-1470.txt"
    _monitor_dir="$FAKE_NEXUS/monitor"
    STATE_DIR="$FAKE_NEXUS/monitor/.state"

    # shellcheck source=_lib.sh
    . "$_test_dir/_lib.sh"
    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"
    # shellcheck source=_respawn_prompts.sh
    . "$_test_dir/_respawn_prompts.sh"

    log() { printf '%s\n' "$*" >> "$WORK/respawn-agent-1470.log"; }
    # The observable stand-in for the real reset. main.sh defines it far from
    # respawn_agent, so the body extracted below would otherwise call nothing.
    requests_reset_delivery_state() { : > "$WORK/reset-called"; }

    respawn_agent_body=$(awk '
        /^respawn_agent\(\) \{$/ { capture = 1 }
        capture { print }
        capture && /^\}$/ { capture = 0 }
    ' "$_test_dir/main.sh")
    eval "$respawn_agent_body"

    respawn_agent orchestrator
) 2>"$WORK/stderr-5b.log"
rc=$?
rm -f "$WORK/tmux-target-absent"
rm -f "$FAKE_NEXUS/monitor/ng"

agent_log=$(cat "$WORK/respawn-agent-1470.log" 2>/dev/null || true)

assert_eq "respawn_agent reports FAILURE when the brief was not delivered" "$rc" "1"
# This suite defines its own primitives (pass/fail/assert_eq/assert_contains)
# and does NOT source _test_helpers.sh, so `assert_file_exists` is not in
# scope here. Written with the local ones on purpose: the first draft used
# `assert_file_exists`, which exited `command not found` WITHOUT counting --
# so the assertion silently did not run while the suite total was unchanged
# at 140 either way. Totals agreeing is not evidence that the same
# assertions ran (#1150).
if [[ -f "$WORK/reset-called" ]]; then
    pass "…and the delivery stamps were RE-ARMED anyway (the window WAS replaced)"
else
    fail "…and the delivery stamps were RE-ARMED anyway (the window WAS replaced)"
fi
assert_contains "…and the respawn was action-logged" \
                "$(cat "$WORK/ng-calls.log" 2>/dev/null || true)" "watcher-respawn-agent"
assert_contains "…the rc-4 arm names the undelivered brief rather than a bare rc" \
                "$agent_log" "was NOT delivered (helper rc=4)"
assert_contains "…and the tail says the next poll must re-deliver" \
                "$agent_log" "brief UNDELIVERED"
# NOT the `*)` arm: that one prints only "helper returned rc=N" and returns
# before the reset. If rc 4 ever falls back into it, this fires.
assert_not_contains "…rc 4 does NOT fall through to the generic arm" \
                    "$agent_log" "helper returned rc=4"

# --- Test 6: issue #176 — pin → --resume <sid> via auto-detect ----------
#
# When `monitor/.state/orchestrator-session-id` holds a valid UUID AND
# the referenced jsonl exists in `$HOME/.claude/projects/<slug>/`, the
# helper must spawn `claude --resume <sid>` instead of `--continue`.
# This is the fix for #176: pre-fix `--continue` selects the most-
# recent jsonl in the project dir, which is the wrong session when a
# supervisor or parallel worker is writing more recently than the dead
# orchestrator's jsonl. `--resume <sid>` is deterministic.

echo '=== issue #176: pin → --resume <sid> via auto-detect ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

PIN_SID="aabbccdd-eeff-1122-3344-556677889900"
PIN_DIR="$FAKE_NEXUS/monitor/.state"
mkdir -p "$PIN_DIR"
printf '%s\n' "$PIN_SID" > "$PIN_DIR/orchestrator-session-id"

# Per Claude Code's slug encoding, replace every char outside [a-zA-Z0-9-]
# with '-'. _respawn_choose_resume_mode reads $HOME, so we redirect HOME
# to a per-test workdir to stage the jsonl deterministically.
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"
SLUG="${FAKE_NEXUS//[^a-zA-Z0-9-]/-}"
PROJ_DIR="$FAKE_HOME/.claude/projects/$SLUG"
mkdir -p "$PROJ_DIR"
touch "$PROJ_DIR/$PIN_SID.jsonl"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator
) 2>"$WORK/stderr-6.log"
rc=$?
assert_eq "exit 0 with valid pin + jsonl" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_contains "launcher carries --resume <pinned-sid>" "$body" "--resume $PIN_SID"
    assert_not_contains "launcher OMITS --continue when --resume is used" "$body" "--continue"
else
    fail "no launcher produced on resume path"
fi
stderr_log=$(cat "$WORK/stderr-6.log")
# The log_fn is set to `:` by default in the bare _respawn_orchestrator
# call, so no log line. But the `:` is overridden when our local
# `log()` is in scope; the test invocation passes `log` indirectly via
# the subshell-local function. Don't gate on stderr here — the
# launcher body is the contract surface.

# --- Test 7: pin malformed → falls back to --continue ------------------

echo '=== issue #200: malformed pin → cold spawn (NOT --continue) ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

printf '%s\n' "not-a-uuid" > "$PIN_DIR/orchestrator-session-id"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator
) 2>"$WORK/stderr-7.log"
rc=$?
assert_eq "exit 0 with malformed pin" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_not_contains "malformed pin → launcher OMITS --continue (issue #200)" "$body" "--continue"
    assert_not_contains "launcher OMITS --resume on malformed pin" "$body" "--resume"
else
    fail "no launcher produced on malformed-pin path"
fi

# --- Test 8: pin valid but jsonl missing → fallback to --continue ------

echo '=== issue #200: pin valid + jsonl missing → cold spawn (NOT --continue) ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

printf '%s\n' "$PIN_SID" > "$PIN_DIR/orchestrator-session-id"
rm -f "$PROJ_DIR/$PIN_SID.jsonl"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator
) 2>"$WORK/stderr-8.log"
rc=$?
assert_eq "exit 0 with pin but missing jsonl" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_not_contains "jsonl missing → launcher OMITS --continue (issue #200)" "$body" "--continue"
    assert_not_contains "launcher OMITS --resume when jsonl is missing" "$body" "--resume"
else
    fail "no launcher produced on jsonl-missing path"
fi

# Stage the jsonl back so the next test starts with valid state.
touch "$PROJ_DIR/$PIN_SID.jsonl"

# --- Test 9: --no-continue trumps a valid pin --------------------------

echo '=== issue #176: --no-continue wins over a valid pin (fresh boot) ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

# Pin file is still valid here.
(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator --no-continue
) 2>"$WORK/stderr-9.log"
rc=$?
assert_eq "exit 0 with --no-continue + valid pin" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_not_contains "--no-continue suppresses --resume even with valid pin" "$body" "--resume"
    assert_not_contains "--no-continue suppresses --continue" "$body" "--continue"
else
    fail "no launcher produced on --no-continue + pin path"
fi

# --- Test 10: --resume-sid caller override (no in-helper pin check) ----

echo '=== issue #176: caller-supplied --resume-sid bypasses pin auto-detect ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

# Remove the pin file entirely so the helper would normally fall back
# to --continue. The --resume-sid override must still win.
rm -f "$PIN_DIR/orchestrator-session-id"
OVERRIDE_SID="11112222-3333-4444-5555-666677778888"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator --resume-sid "$OVERRIDE_SID"
) 2>"$WORK/stderr-10.log"
rc=$?
assert_eq "exit 0 with --resume-sid override" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_contains "launcher carries --resume <override-sid>" "$body" "--resume $OVERRIDE_SID"
    assert_not_contains "launcher OMITS --continue with --resume-sid" "$body" "--continue"
else
    fail "no launcher produced on --resume-sid override path"
fi

# --- Test 11: respawn_agent (main.sh) renders accurate prompt boilerplate

echo '=== issue #176: respawn_agent boilerplate names the real resume command ==='
: > "$TMUX_LOG"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

# Re-stage a valid pin so respawn_agent's _respawn_choose_resume_mode
# upgrade fires and the prompt mentions --resume.
printf '%s\n' "$PIN_SID" > "$PIN_DIR/orchestrator-session-id"
touch "$PROJ_DIR/$PIN_SID.jsonl"

# Capture the prompt-file the respawn_agent body writes by overriding
# RESPAWN_TMPDIR for the duration of the call AND telling the helper
# to leave the prompt alone (we'll inspect it after). The body does
# `rm -f "$prompt_file"` after the spawn, so we need to capture the
# content via a tmux-paste-buffer hook — easier: intercept by
# pre-emptively reading the prompt-file path from the stub tmux's
# load-buffer log line.
RESPAWN_TMPDIR_PROMPT="$WORK/prompt-stage"
mkdir -p "$RESPAWN_TMPDIR_PROMPT"

# A capturing tmux stub: copies load-buffer's input file to $WORK so
# we can inspect the prompt body after respawn_agent removes the
# original.
TMUX_STUB_CAP_BIN="$WORK/stub-bin-cap"
mkdir -p "$TMUX_STUB_CAP_BIN"
: > "$TMUX_CAP_LOG"

cat > "$TMUX_STUB_CAP_BIN/tmux" <<STUB
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$TMUX_CAP_LOG"
case "\$1" in
    list-windows)
        fmt="\$3"
        if grep -q 'new-window' "$TMUX_CAP_LOG"; then
            names=("watcher" "orchestrator")
        else
            names=("watcher")
        fi
        idx=0
        for n in "\${names[@]}"; do
            case "\$fmt" in
                '#{window_name}'|'')              printf '%s\n' "\$n" ;;
                '#I #W')                          printf '%d %s\n' "\$idx" "\$n" ;;
                '#{window_index}|#{window_name}') printf '%d|%s\n' "\$idx" "\$n" ;;
                *)                                printf '%s\n' "\$n" ;;
            esac
            idx=\$(( idx + 1 ))
        done
        ;;
    new-window)
        # -P -F '#{window_id}' makes tmux print the id of the window it just
        # created, and _respawn_spawn_window keys its rc=3 contract on that
        # handle rather than on a presence-by-NAME probe (your-org/nexus-code
        # #1327). A stub answering with ZERO BYTES models "created nothing",
        # so the arm has to speak the handle or every spawn reads as a
        # failure. Most stubs in this corpus already do -- spawn-worker.sh
        # has used the same discriminator since #323; the respawn family
        # was the outlier, in the code and in its fixtures alike.
        #
        # NO BACKTICKS IN THIS HEREDOC. It is UNQUOTED (<<STUB), so a
        # backticked word in a COMMENT is command-substituted when the
        # fixture is written -- measured at HEAD: six `command not found`
        # lines per run, from this very comment (your-org/nexus-code#1157).
        printf '@7\n'
        exit 0
        ;;
    load-buffer)
        # Args: load-buffer -b <buf> <file>
        cp "\$4" "$WORK/prompt-captured.txt" 2>/dev/null || true
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$TMUX_STUB_CAP_BIN/tmux"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_CAP_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS

    RESPAWN_CONSEC_COUNTER="$WORK/consec-counter.txt"
    _monitor_dir="$FAKE_NEXUS/monitor"

    # shellcheck source=_lib.sh
    . "$_test_dir/_lib.sh"
    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"
    # shellcheck source=_respawn_prompts.sh
    . "$_test_dir/_respawn_prompts.sh"

    log() { :; }

    respawn_agent_body=$(awk '
        /^respawn_agent\(\) \{$/ { capture = 1 }
        capture { print }
        capture && /^\}$/ { capture = 0 }
    ' "$_test_dir/main.sh")
    eval "$respawn_agent_body"

    respawn_agent orchestrator
) 2>"$WORK/stderr-11.log"
rc=$?
assert_eq "respawn_agent exit 0 on resume path" "$rc" "0"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_contains "respawn_agent launcher carries --resume <pinned-sid>" \
                    "$body" "--resume $PIN_SID"
    assert_not_contains "respawn_agent launcher OMITS --continue when --resume is used" \
                        "$body" "--continue"
else
    fail "respawn_agent did not produce a launcher on the resume path"
fi
if [[ -f "$WORK/prompt-captured.txt" ]]; then
    prompt_body=$(cat "$WORK/prompt-captured.txt")
    assert_contains "recovery prompt names 'claude --resume <sid>'" \
                    "$prompt_body" "claude --resume $PIN_SID"
    assert_not_contains "recovery prompt does NOT name 'claude --continue' on resume path" \
                        "$prompt_body" "claude --continue"
    # issue #238: the resume prompt must instruct the new orchestrator to
    # (re-)arm the watcher-supervisor Monitor, carrying the exact arm
    # command, placed in the "watcher was right" branch (after the
    # false-positive validation), NOT before it.
    assert_contains "resume prompt instructs (re-)arm of the supervisor Monitor" \
                    "$prompt_body" "(re-)arm the"
    assert_contains "resume prompt carries the exact Monitor arm command" \
                    "$prompt_body" 'Monitor({command: "until ! '
    assert_contains "resume prompt arm command names the supervise-tick script" \
                    "$prompt_body" "monitor/watcher-supervise-tick.sh"
    # The arm step must come AFTER the false-positive stand-down protocol —
    # a duplicate orchestrator must stand down BEFORE it would arm a second
    # supervisor (mutual-liveness: exactly one supervisor).
    standdown_pos=$(awk '/Stand down using EXACTLY/{print NR; exit}' "$WORK/prompt-captured.txt")
    arm_pos=$(awk '/\(re-\)arm the/{print NR; exit}' "$WORK/prompt-captured.txt")
    if [[ -n "$standdown_pos" && -n "$arm_pos" ]] && (( arm_pos > standdown_pos )); then
        pass "arm step follows the false-positive stand-down (no second supervisor before stand-down)"
    else
        fail "arm step ordering wrong (standdown@${standdown_pos:-?} arm@${arm_pos:-?})"
    fi
else
    fail "respawn_agent did not paste a prompt body"
fi

# Clean up the captured-prompt path so subsequent runs start fresh.
rm -f "$WORK/prompt-captured.txt"

# --- Test 12: respawn_agent cold path — prompt says "no context resumed"
#
# Issue #200: when the pin can't identify a session, respawn_agent must
# (a) spawn cold (no --resume / no --continue) AND (b) paste a recovery
# prompt that tells the agent it has NO resumed context and to
# re-onboard — NOT one that falsely claims "your prior conversation is
# intact". The false claim is what would let a cold orchestrator
# barrel ahead re-enacting imagined in-flight work.

echo '=== issue #200: respawn_agent cold-path prompt disclaims resumed context ==='
: > "$TMUX_CAP_LOG"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

# Remove the pin so _respawn_choose_resume_mode returns "fresh".
rm -f "$PIN_DIR/orchestrator-session-id"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_CAP_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS

    RESPAWN_CONSEC_COUNTER="$WORK/consec-counter.txt"
    _monitor_dir="$FAKE_NEXUS/monitor"

    # shellcheck source=_lib.sh
    . "$_test_dir/_lib.sh"
    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"
    # shellcheck source=_respawn_prompts.sh
    . "$_test_dir/_respawn_prompts.sh"

    log() { :; }

    respawn_agent_body=$(awk '
        /^respawn_agent\(\) \{$/ { capture = 1 }
        capture { print }
        capture && /^\}$/ { capture = 0 }
    ' "$_test_dir/main.sh")
    eval "$respawn_agent_body"

    respawn_agent orchestrator
) 2>"$WORK/stderr-12.log"
rc=$?
assert_eq "respawn_agent exit 0 on cold path" "$rc" "0"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    assert_not_contains "cold-path launcher OMITS --continue" "$body" "--continue"
    assert_not_contains "cold-path launcher OMITS --resume" "$body" "--resume"
else
    fail "respawn_agent did not produce a launcher on the cold path"
fi
if [[ -f "$WORK/prompt-captured.txt" ]]; then
    prompt_body=$(cat "$WORK/prompt-captured.txt")
    assert_contains "cold-path prompt says it started the agent cold" \
                    "$prompt_body" "started you cold"
    assert_contains "cold-path prompt tells the agent to re-onboard from scratch" \
                    "$prompt_body" "Re-onboard from scratch"
    assert_not_contains "cold-path prompt does NOT claim 'prior conversation is intact'" \
                        "$prompt_body" "prior conversation is intact"
    # issue #238: the cold/fresh prompt must ALSO carry the (re-)arm step
    # for the watcher-supervisor Monitor — a fresh respawn drops the
    # in-process supervisor exactly the same way a resume does.
    assert_contains "cold-path prompt instructs (re-)arm of the supervisor Monitor" \
                    "$prompt_body" "(re-)arm the"
    assert_contains "cold-path prompt carries the exact Monitor arm command" \
                    "$prompt_body" 'Monitor({command: "until ! '
    assert_contains "cold-path prompt arm command names the supervise-tick script" \
                    "$prompt_body" "monitor/watcher-supervise-tick.sh"
    # Same ordering invariant: arm step AFTER the false-positive stand-down.
    standdown_pos=$(awk '/Stand down using EXACTLY/{print NR; exit}' "$WORK/prompt-captured.txt")
    arm_pos=$(awk '/\(re-\)arm the/{print NR; exit}' "$WORK/prompt-captured.txt")
    if [[ -n "$standdown_pos" && -n "$arm_pos" ]] && (( arm_pos > standdown_pos )); then
        pass "cold-path arm step follows the false-positive stand-down"
    else
        fail "cold-path arm step ordering wrong (standdown@${standdown_pos:-?} arm@${arm_pos:-?})"
    fi
else
    fail "respawn_agent did not paste a prompt body on the cold path"
fi
rm -f "$WORK/prompt-captured.txt"

# --- Test 13: issue #203 — cold spawn carries --session-id + pins at spawn
#
# The deterministic-session-id fix: a cold/fresh spawn must boot with a
# generated `claude --session-id <uuid>` AND write that uuid to the
# orchestrator pin immediately — so the watcher knows the orchestrator's
# session from the instant of spawn (no lazy-hook gap), and the NEXT
# respawn can --resume it instead of degrading again.

echo '=== issue #203: cold spawn carries --session-id <uuid> and pins it at spawn ==='
: > "$TMUX_LOG"
touch "$WORK/tmux-target-absent"
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
# No pin → choose returns fresh → deterministic --session-id path.
rm -f "$PIN_DIR/orchestrator-session-id"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    log() { echo "$@" >&2; }
    _respawn_orchestrator orchestrator --log-fn log
) 2>"$WORK/stderr-13.log"
rc=$?
assert_eq "exit 0 on deterministic cold spawn" "$rc" "0"
rm -f "$WORK/tmux-target-absent"

launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
new_launcher=$(comm -13 <(printf '%s\n' "$launchers_before" | sort -u) \
                        <(printf '%s\n' "$launchers_after"  | sort -u) | head -1)
launched_sid=""
if [[ -n "$new_launcher" && -f "$new_launcher" ]]; then
    body=$(cat "$new_launcher")
    sid_match=$(grep -oE -- '--session-id [0-9a-fA-F-]{36}' <<<"$body" | head -1 || true)
    launched_sid="${sid_match#--session-id }"
    if [[ -n "$launched_sid" ]]; then
        pass "cold-spawn launcher carries a generated --session-id ($launched_sid)"
    else
        fail "cold-spawn launcher missing --session-id; body=$body"
    fi
    assert_not_contains "cold-spawn launcher still OMITS --continue" "$body" "--continue"
    assert_not_contains "cold-spawn launcher still OMITS --resume" "$body" "--resume"
else
    fail "no launcher produced on deterministic cold-spawn path"
fi

# The pin must hold exactly the launched session-id.
pin_after=""
[[ -f "$PIN_DIR/orchestrator-session-id" ]] && { pin_after=$(<"$PIN_DIR/orchestrator-session-id"); pin_after="${pin_after//[[:space:]]/}"; }
assert_eq "pin written at spawn equals the launched session-id" "$pin_after" "$launched_sid"
assert_contains "log records the deterministic pin write" \
                "$(cat "$WORK/stderr-13.log")" "pinned orchestrator session-id"

# --- Test 14: issue #203 — helper unit tests ---------------------------

echo '=== issue #203: _respawn_new_session_id / _respawn_write_pin units ==='
(
    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"
    sid=$(_respawn_new_session_id)
    [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || exit 1
    sid2=$(_respawn_new_session_id)
    [[ "$sid" != "$sid2" ]] || exit 2   # two calls → distinct uuids
    exit 0
)
assert_eq "_respawn_new_session_id yields distinct valid UUIDs" "$?" "0"

UNIT_ROOT="$WORK/pin-unit"
mkdir -p "$UNIT_ROOT/monitor/.state"
(
    . "$_test_dir/_respawn.sh"
    _respawn_write_pin "$UNIT_ROOT" "abcdef01-2345-6789-abcd-ef0123456789"
)
unit_pin=$(cat "$UNIT_ROOT/monitor/.state/orchestrator-session-id" 2>/dev/null || true)
assert_eq "_respawn_write_pin writes the sid" "${unit_pin//[[:space:]]/}" "abcdef01-2345-6789-abcd-ef0123456789"
# Garbage must be refused (rc!=0, pin unchanged).
(
    . "$_test_dir/_respawn.sh"
    _respawn_write_pin "$UNIT_ROOT" "not-a-uuid"
)
reject_rc=$?
assert_eq "_respawn_write_pin refuses a non-UUID (rc=1)" "$reject_rc" "1"
unit_pin_after=$(cat "$UNIT_ROOT/monitor/.state/orchestrator-session-id" 2>/dev/null || true)
assert_eq "pin unchanged after rejected garbage write" "${unit_pin_after//[[:space:]]/}" "abcdef01-2345-6789-abcd-ef0123456789"

# --- Test 15: incident 2026-06-02 — _respawn_verify_target_absent units

echo '=== incident 2026-06-02: _respawn_verify_target_absent re-verification ==='

# Dedicated tmux stub for the verify tests. Controllable via files:
#   $WORK/verify-window-present       — list-windows includes 'orchestrator'
#   $WORK/verify-panes                — list-panes -a output (pid|win_id|name)
# Records every invocation for kill/rename scoping assertions.
TMUX_STUB_VERIFY_BIN="$WORK/stub-bin-verify"
mkdir -p "$TMUX_STUB_VERIFY_BIN"
TMUX_VERIFY_LOG="$WORK/tmux-calls-verify.log"
: > "$TMUX_VERIFY_LOG"

cat > "$TMUX_STUB_VERIFY_BIN/tmux" <<STUB
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$TMUX_VERIFY_LOG"
case "\$1" in
    list-windows)
        if [[ -f "$WORK/verify-window-present" ]]; then
            printf 'watcher\norchestrator\n'
        else
            printf 'watcher\n'
        fi
        ;;
    list-panes)
        cat "$WORK/verify-panes" 2>/dev/null
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$TMUX_STUB_VERIFY_BIN/tmux"

# (a) Window present again at decision time → abort.
rm -f "$WORK/verify-panes"
touch "$WORK/verify-window-present"
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator
    "
)
verify_rc=$?
assert_eq "(a) window reappeared → verify aborts (rc=1)" "$verify_rc" "1"
assert_contains "(a) reason is 'window-reappeared'" "$verify_out" "window-reappeared"
rm -f "$WORK/verify-window-present"

# (b) Window absent but a live orchestrator process exists in a pane →
# abort + heal the rename. Use a real background process carrying
# NEXUS_IS_ORCHESTRATOR=1 so the /proc environ scan is exercised for real.
NEXUS_IS_ORCHESTRATOR=1 sleep 30 &
ORCH_FAKE_PID=$!
printf '%s|@7|claude\n' "$ORCH_FAKE_PID" > "$WORK/verify-panes"
: > "$TMUX_VERIFY_LOG"
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator
    "
)
verify_rc=$?
if [[ -r "/proc/$ORCH_FAKE_PID/environ" ]]; then
    assert_eq "(b) live orchestrator process in a pane → verify aborts (rc=1)" "$verify_rc" "1"
    assert_contains "(b) reason names the pane pid" "$verify_out" "orchestrator-process-alive pane_pid=$ORCH_FAKE_PID"
    tmux_verify_log=$(cat "$TMUX_VERIFY_LOG")
    assert_contains "(b) heal: renames the found window back to the target" \
                    "$tmux_verify_log" "rename-window -t @7 orchestrator"
    assert_contains "(b) heal: re-pins automatic-rename off" \
                    "$tmux_verify_log" "set-window-option -t @7 automatic-rename off"
    assert_not_contains "(b) heal path never kills anything" "$tmux_verify_log" "kill-"
else
    pass "(b) skipped: /proc/<pid>/environ not readable on this host (verify degrades to other signals)"
fi
kill "$ORCH_FAKE_PID" 2>/dev/null; wait "$ORCH_FAKE_PID" 2>/dev/null

# (c) Window absent, no orchestrator pane, but the orchestrator heartbeat
# advanced AFTER the absent streak began → abort (alive somewhere).
rm -f "$WORK/verify-panes"
VERIFY_STATE="$WORK/verify-state"
mkdir -p "$VERIFY_STATE"
touch "$VERIFY_STATE/orchestrator-heartbeat"
streak_start=$(( $(date +%s) - 60 ))   # streak began 60s ago; heartbeat is fresh
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" \
    ORCH_HEARTBEAT_FILE="$VERIFY_STATE/orchestrator-heartbeat" \
    bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator $streak_start
    "
)
verify_rc=$?
assert_eq "(c) heartbeat newer than streak start → verify aborts (rc=1)" "$verify_rc" "1"
assert_contains "(c) reason is 'orchestrator-signal-fresh'" "$verify_out" "orchestrator-signal-fresh"

# (d) Same heartbeat but the streak began AFTER its last write → no
# evidence of life during the streak → proceed. (A recently-dead
# orchestrator must not block its own legitimate respawn.)
sleep 1
streak_start=$(( $(date +%s) + 1 ))   # streak begins after the heartbeat write
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" \
    ORCH_HEARTBEAT_FILE="$VERIFY_STATE/orchestrator-heartbeat" \
    bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator $streak_start
    "
)
verify_rc=$?
assert_eq "(d) heartbeat older than streak start → verify proceeds (rc=0)" "$verify_rc" "0"
assert_contains "(d) reason is 'verified-absent'" "$verify_out" "verified-absent"

# (e) Window absent, nothing alive at all → proceed.
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator
    "
)
verify_rc=$?
assert_eq "(e) genuinely absent → verify proceeds (rc=0)" "$verify_rc" "0"
assert_contains "(e) reason is 'verified-absent'" "$verify_out" "verified-absent"

# --- Test 15b: PR #266 revision — duplicate-orchestrator kill preserved,
#     single-legit protected, impostor-in-slot killable
#
# Operator direction on PR #266: the re-verify abort was too absolute.
# Refined rules under test here (see _respawn_verify_target_absent):
#   (f)  single orchestrator pane, sid ≠ pin → STILL legit (pin can lag
#        a resume-fork); abort, never kill.
#   (g)  two orchestrator panes, one matches the pin (anchor) → the
#        provable duplicate's window is killed; respawn still aborts.
#   (h)  two orchestrator panes, NEITHER matches the pin → unadjudicable;
#        abort, kill nothing.
#   (i)  target-named window holding only a positively-classified
#        NON-orchestrator occupant (misplaced cockpit) → verify rc=0:
#        the kill-then-spawn proceeds (intended recovery).
#   (j)  same impostor but fresh liveness signals → abort (a live
#        orchestrator is somewhere; spawning would duplicate it).
#   (k)  sid extraction: env marker preferred, argv --session-id fallback.
#   (l)  compose_launcher exports NEXUS_ORCH_SESSION_ID when sid known.

echo '=== PR #266 revision: duplicate-orchestrator kill / impostor-in-slot ==='

VERIFY_PIN_DIR="$WORK/verify-pin"
mkdir -p "$VERIFY_PIN_DIR"
SID_A="11111111-1111-1111-1111-111111111111"
SID_B="22222222-2222-2222-2222-222222222222"
SID_C="33333333-3333-3333-3333-333333333333"

# (f) single pane, sid != pin → never killed.
NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCH_SESSION_ID="$SID_B" sleep 30 &
LONE_PID=$!
if [[ -r "/proc/$LONE_PID/environ" ]]; then
    printf '%s|@7|orchestrator\n' "$LONE_PID" > "$WORK/verify-panes"
    touch "$WORK/verify-window-present"
    printf '%s\n' "$SID_A" > "$VERIFY_PIN_DIR/pin"
    : > "$TMUX_VERIFY_LOG"
    verify_out=$(
        PATH="$TMUX_STUB_VERIFY_BIN:$PATH" \
        ORCH_PIN_FILE="$VERIFY_PIN_DIR/pin" \
        bash -c "
            . '$_test_dir/_respawn.sh'
            _respawn_verify_target_absent orchestrator
        "
    )
    verify_rc=$?
    assert_eq "(f) single orchestrator with sid≠pin → abort (rc=1)" "$verify_rc" "1"
    assert_contains "(f) reason is window-reappeared-live" "$verify_out" "window-reappeared-live"
    assert_not_contains "(f) the single known orchestrator is never killed" \
                        "$(cat "$TMUX_VERIFY_LOG")" "kill-"
else
    pass "(f) skipped: /proc environ unreadable"
fi
kill "$LONE_PID" 2>/dev/null; wait "$LONE_PID" 2>/dev/null

# (g) two panes, anchor matches pin → provable duplicate's window killed.
NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCH_SESSION_ID="$SID_A" sleep 30 &
ANCHOR_PID=$!
NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCH_SESSION_ID="$SID_B" sleep 30 &
DUP_PID=$!
if [[ -r "/proc/$ANCHOR_PID/environ" ]]; then
    # The duplicate squats the target-named window; the anchor lives
    # under a drifted name (rename race).
    {
        printf '%s|@8|orchestrator\n' "$DUP_PID"
        printf '%s|@9|claude\n' "$ANCHOR_PID"
    } > "$WORK/verify-panes"
    touch "$WORK/verify-window-present"
    printf '%s\n' "$SID_A" > "$VERIFY_PIN_DIR/pin"
    : > "$TMUX_VERIFY_LOG"
    verify_out=$(
        PATH="$TMUX_STUB_VERIFY_BIN:$PATH" \
        ORCH_PIN_FILE="$VERIFY_PIN_DIR/pin" \
        bash -c "
            . '$_test_dir/_respawn.sh'
            _respawn_verify_target_absent orchestrator
        "
    )
    verify_rc=$?
    tmux_verify_log=$(cat "$TMUX_VERIFY_LOG")
    assert_eq "(g) anchored dedup → respawn still aborts (rc=1)" "$verify_rc" "1"
    assert_contains "(g) the provable duplicate's window is killed" \
                    "$tmux_verify_log" "kill-window -t @8"
    assert_contains "(g) reason records the killed duplicate" \
                    "$verify_out" "killed duplicates"
    assert_not_contains "(g) the pin-matching anchor's window is never killed" \
                        "$tmux_verify_log" "kill-window -t @9"
else
    pass "(g) skipped: /proc environ unreadable"
fi
kill "$ANCHOR_PID" "$DUP_PID" 2>/dev/null
wait "$ANCHOR_PID" "$DUP_PID" 2>/dev/null

# (h) two panes, neither matches the pin → unadjudicable, no kill.
NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCH_SESSION_ID="$SID_A" sleep 30 &
P1=$!
NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCH_SESSION_ID="$SID_B" sleep 30 &
P2=$!
if [[ -r "/proc/$P1/environ" ]]; then
    {
        printf '%s|@8|orchestrator\n' "$P1"
        printf '%s|@9|claude\n' "$P2"
    } > "$WORK/verify-panes"
    touch "$WORK/verify-window-present"
    printf '%s\n' "$SID_C" > "$VERIFY_PIN_DIR/pin"
    : > "$TMUX_VERIFY_LOG"
    verify_out=$(
        PATH="$TMUX_STUB_VERIFY_BIN:$PATH" \
        ORCH_PIN_FILE="$VERIFY_PIN_DIR/pin" \
        bash -c "
            . '$_test_dir/_respawn.sh'
            _respawn_verify_target_absent orchestrator
        "
    )
    verify_rc=$?
    assert_eq "(h) no pin anchor among duplicates → abort (rc=1)" "$verify_rc" "1"
    assert_contains "(h) reason is multiple-orchestrators-unresolvable" \
                    "$verify_out" "multiple-orchestrators-unresolvable"
    assert_not_contains "(h) unadjudicable → nothing killed" \
                        "$(cat "$TMUX_VERIFY_LOG")" "kill-"
else
    pass "(h) skipped: /proc environ unreadable"
fi
kill "$P1" "$P2" 2>/dev/null
wait "$P1" "$P2" 2>/dev/null

# (i) impostor-in-slot: target-named window holds only a plain process
# (a misplaced cockpit stand-in) → verify rc=0, kill proceeds.
sleep 30 &
IMPOSTOR_PID=$!
printf '%s|@5|orchestrator\n' "$IMPOSTOR_PID" > "$WORK/verify-panes"
touch "$WORK/verify-window-present"
rm -f "$VERIFY_PIN_DIR/pin"
: > "$TMUX_VERIFY_LOG"
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" \
    MONITOR_VERIFY_REPROBE_SECONDS=0 \
    bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator
    "
)
verify_rc=$?
assert_eq "(i) non-orchestrator occupant in slot → verify proceeds (rc=0)" "$verify_rc" "0"
assert_contains "(i) reason is impostor-in-slot" "$verify_out" "impostor-in-slot"

# (j) same impostor but a fresh heartbeat (streak-based) → abort.
touch "$VERIFY_STATE/orchestrator-heartbeat"
streak_start=$(( $(date +%s) - 60 ))
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" \
    MONITOR_VERIFY_REPROBE_SECONDS=0 \
    ORCH_HEARTBEAT_FILE="$VERIFY_STATE/orchestrator-heartbeat" \
    bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator $streak_start
    "
)
verify_rc=$?
assert_eq "(j) impostor + fresh signals → abort (rc=1)" "$verify_rc" "1"
assert_contains "(j) reason is orchestrator-signal-fresh" "$verify_out" "orchestrator-signal-fresh"
kill "$IMPOSTOR_PID" 2>/dev/null; wait "$IMPOSTOR_PID" 2>/dev/null
rm -f "$WORK/verify-window-present" "$WORK/verify-panes"

# (k) sid extraction: env marker, then argv fallback.
NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCH_SESSION_ID="$SID_A" sleep 30 &
ENV_SID_PID=$!
# `; :` keeps bash resident (a lone command would exec-optimize into
# `sleep`, dropping the --session-id argv this case exercises).
NEXUS_IS_ORCHESTRATOR=1 bash -c 'sleep 30; :' sid-carrier --session-id "$SID_B" &
ARGV_SID_PID=$!
sleep 0.2
if [[ -r "/proc/$ENV_SID_PID/environ" ]]; then
    got_sid=$(bash -c ". '$_test_dir/_respawn.sh'; _respawn_pid_tree_orchestrator_sid $ENV_SID_PID")
    assert_eq "(k) sid from NEXUS_ORCH_SESSION_ID environ" "$got_sid" "$SID_A"
    got_sid=$(bash -c ". '$_test_dir/_respawn.sh'; _respawn_pid_tree_orchestrator_sid $ARGV_SID_PID")
    assert_eq "(k) sid from --session-id argv fallback" "$got_sid" "$SID_B"
    # A marker-free process: env -i guarantees a clean environ even
    # when the suite itself runs under an orchestrator's Bash tool
    # (which would leak NEXUS_IS_ORCHESTRATOR=1 into $$'s environ).
    env -i sleep 30 &
    CLEAN_PID=$!
    sleep 0.1
    if bash -c ". '$_test_dir/_respawn.sh'; _respawn_pid_tree_orchestrator_sid $CLEAN_PID" >/dev/null; then
        fail "(k) non-orchestrator pid must return rc=1"
    else
        pass "(k) non-orchestrator pid returns rc=1"
    fi
    kill "$CLEAN_PID" 2>/dev/null; wait "$CLEAN_PID" 2>/dev/null
else
    pass "(k) skipped: /proc environ unreadable"
fi
kill "$ENV_SID_PID" "$ARGV_SID_PID" 2>/dev/null
wait "$ENV_SID_PID" "$ARGV_SID_PID" 2>/dev/null

# (l) compose_launcher: sid arg → NEXUS_ORCH_SESSION_ID export in the
# launcher; no sid → no export line.
SID_LAUNCHER="$WORK/sid-launcher.sh"
( CLAUDE_BIN=/usr/bin/true
  . "$_test_dir/_respawn.sh"
  _respawn_compose_launcher "$SID_LAUNCHER" /tmp/nexus-root "" "" orchestrator "$SID_A" )
if grep -qF "export NEXUS_ORCH_SESSION_ID=\"$SID_A\"" "$SID_LAUNCHER"; then
    pass "(l) launcher exports NEXUS_ORCH_SESSION_ID when sid known"
else
    fail "(l) launcher missing sid export" "$(cat "$SID_LAUNCHER")"
fi
( CLAUDE_BIN=/usr/bin/true
  . "$_test_dir/_respawn.sh"
  _respawn_compose_launcher "$SID_LAUNCHER" /tmp/nexus-root "" "" orchestrator )
if grep -qF "NEXUS_ORCH_SESSION_ID" "$SID_LAUNCHER"; then
    fail "(l) launcher must not export an empty sid" "$(cat "$SID_LAUNCHER")"
else
    pass "(l) no sid → no NEXUS_ORCH_SESSION_ID line"
fi
rm -f "$SID_LAUNCHER"

# --- Test 15c: your-org/nexus-code#741 — a remain-on-exit corpse is
#     NOT an "unclassified occupant"
#
# `_respawn_spawn_window` sets `remain-on-exit on`, so a crashed agent
# leaves the target window LISTED with a dead pane. tmux keeps
# reporting that pane's `#{pane_pid}`, but the process is GONE, so
# `/proc/<pid>/cmdline` is unreadable and the occupant scan could not
# classify it — and "unclassified" routed to the refuse arm. The gate
# therefore vetoed the respawn of an orchestrator that had already
# died, permanently. Measured against a real tmux corpse before the
# fix: rc=1, "window-reappeared (unclassified occupant; refusing to
# kill)".
#
# The stub's pane rows gain a 4th field, `#{pane_dead}`. Rows written
# with three fields (every case above) leave it EMPTY, which must
# continue to mean LIVE — a tmux too old to know the format must not
# have its windows read as corpses.

echo '=== your-org/nexus-code#741: remain-on-exit corpse in the target slot ==='

# (m) The corpse itself: window listed, sole pane dead, pid unreadable.
touch "$WORK/verify-window-present"
printf '999999|@7|orchestrator|1\n' > "$WORK/verify-panes"
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator
    "
)
verify_rc=$?
assert_eq "(m) dead pane in the target slot → verify proceeds (rc=0)" "$verify_rc" "0"
assert_contains "(m) reason names the corpse" "$verify_out" "remain-on-exit corpse"

# (n) pane_dead EMPTY (a tmux that does not support the format) must
# NOT be read as a corpse. This is the fail-safe direction: absent
# evidence of death is not evidence of death, and the wrong call here
# spawns a second orchestrator beside a live one.
printf '999999|@7|orchestrator|\n' > "$WORK/verify-panes"
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator
    "
)
verify_rc=$?
assert_eq "(n) empty pane_dead → NOT a corpse; verify still aborts (rc=1)" "$verify_rc" "1"
assert_contains "(n) reason is the conservative refusal" "$verify_out" "unclassified occupant"

# (o) A live pane sharing the window with a corpse is still an
# occupant: one dead pane must not condemn its live sibling.
printf '%s|@7|orchestrator|1\n' 999999 > "$WORK/verify-panes"
printf '%s|@7|orchestrator|0\n' "$$" >> "$WORK/verify-panes"
verify_out=$(
    PATH="$TMUX_STUB_VERIFY_BIN:$PATH" bash -c "
        . '$_test_dir/_respawn.sh'
        _respawn_verify_target_absent orchestrator
    "
)
verify_rc=$?
assert_contains "(o) live sibling of a corpse is classified, not a corpse" \
                "$verify_out" "impostor-in-slot"

# (p) THE STALE-PID HAZARD. tmux reports a dead pane's `#{pane_pid}`
# forever, and the kernel recycles pids. Point a DEAD row at a pid that
# is very much alive AND carries the orchestrator marker: read
# credulously, that corpse becomes a live orchestrator and vetoes every
# future respawn. The dead-pane skip in the marked-pane scan is what
# stops it — without that skip this returns rc=1
# "orchestrator-process-alive".
NEXUS_IS_ORCHESTRATOR=1 NEXUS_ORCH_SESSION_ID="$SID_A" sleep 30 &
RECYCLED_PID=$!
if [[ -r "/proc/$RECYCLED_PID/environ" ]]; then
    printf '%s|@7|orchestrator|1\n' "$RECYCLED_PID" > "$WORK/verify-panes"
    verify_out=$(
        PATH="$TMUX_STUB_VERIFY_BIN:$PATH" bash -c "
            . '$_test_dir/_respawn.sh'
            _respawn_verify_target_absent orchestrator
        "
    )
    verify_rc=$?
    assert_eq "(p) dead pane whose pid was RECYCLED by a live orchestrator-marked process → still a corpse (rc=0)" \
              "$verify_rc" "0"
    assert_contains "(p) reason names the corpse, not a live orchestrator" \
                    "$verify_out" "remain-on-exit corpse"
else
    pass "(p) skipped: /proc environ unreadable"
fi
kill "$RECYCLED_PID" 2>/dev/null; wait "$RECYCLED_PID" 2>/dev/null
rm -f "$WORK/verify-window-present" "$WORK/verify-panes"

# --- Test 16: incident 2026-06-02 — recovery prompt never instructs
#     killing the watcher (root cause 2)
#
# The pre-incident prompt told a respawned orchestrator that discovered
# a false-positive respawn to "kill the watcher (`tmux kill-window -t
# watcher`)". The duplicate followed it on 2026-06-02 and left the
# workspace unmonitored. The contract now: the prompt must (a) never
# instruct touching the watcher window or the tmux session, (b)
# explicitly forbid it, and (c) scope the stand-down to the duplicate's
# OWN window, by window id.

echo '=== incident 2026-06-02: recovery prompt stand-down protocol (both flavours) ==='

# Resume-flavour prompt (valid pin). Reuses the capturing tmux stub
# from Test 11, which copies the load-buffer file to prompt-captured.txt.
printf '%s\n' "$PIN_SID" > "$PIN_DIR/orchestrator-session-id"
touch "$PROJ_DIR/$PIN_SID.jsonl"
rm -f "$WORK/prompt-captured.txt"
: > "$TMUX_CAP_LOG"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_CAP_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS

    RESPAWN_CONSEC_COUNTER="$WORK/consec-counter.txt"
    _monitor_dir="$FAKE_NEXUS/monitor"

    # shellcheck source=_lib.sh
    . "$_test_dir/_lib.sh"
    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"
    # shellcheck source=_respawn_prompts.sh
    . "$_test_dir/_respawn_prompts.sh"

    log() { :; }

    respawn_agent_body=$(awk '
        /^respawn_agent\(\) \{$/ { capture = 1 }
        capture { print }
        capture && /^\}$/ { capture = 0 }
    ' "$_test_dir/main.sh")
    eval "$respawn_agent_body"

    respawn_agent orchestrator
) 2>"$WORK/stderr-16a.log"
rc=$?
assert_eq "respawn_agent exit 0 (resume flavour, prompt-safety run)" "$rc" "0"

if [[ -f "$WORK/prompt-captured.txt" ]]; then
    prompt_body=$(cat "$WORK/prompt-captured.txt")
    assert_not_contains "resume prompt never instructs 'kill-window -t watcher'" \
                        "$prompt_body" "kill-window -t watcher"
    assert_contains "resume prompt forbids killing the watcher" \
                    "$prompt_body" "NEVER kill the watcher"
    assert_contains "resume prompt scopes stand-down to the duplicate's own window" \
                    "$prompt_body" "your-own-window-id"
    assert_contains "resume prompt requires restoring the original's window name" \
                    "$prompt_body" "rename-window -t <its-window-id> 'orchestrator'"
    assert_contains "resume prompt requires the false positive be action-logged" \
                    "$prompt_body" "respawn-false-positive"
else
    fail "respawn_agent did not paste a prompt body (resume flavour, prompt-safety run)"
fi
rm -f "$WORK/prompt-captured.txt"

# Cold-flavour prompt (no pin): same safety contract.
rm -f "$PIN_DIR/orchestrator-session-id"
: > "$TMUX_CAP_LOG"

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_CAP_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS

    RESPAWN_CONSEC_COUNTER="$WORK/consec-counter.txt"
    _monitor_dir="$FAKE_NEXUS/monitor"

    # shellcheck source=_lib.sh
    . "$_test_dir/_lib.sh"
    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"
    # shellcheck source=_respawn_prompts.sh
    . "$_test_dir/_respawn_prompts.sh"

    log() { :; }

    respawn_agent_body=$(awk '
        /^respawn_agent\(\) \{$/ { capture = 1 }
        capture { print }
        capture && /^\}$/ { capture = 0 }
    ' "$_test_dir/main.sh")
    eval "$respawn_agent_body"

    respawn_agent orchestrator
) 2>"$WORK/stderr-16b.log"
rc=$?
assert_eq "respawn_agent exit 0 (cold flavour, prompt-safety run)" "$rc" "0"

if [[ -f "$WORK/prompt-captured.txt" ]]; then
    prompt_body=$(cat "$WORK/prompt-captured.txt")
    assert_not_contains "cold prompt never instructs 'kill-window -t watcher'" \
                        "$prompt_body" "kill-window -t watcher"
    assert_contains "cold prompt forbids killing the watcher" \
                    "$prompt_body" "NEVER kill the watcher"
    assert_contains "cold prompt scopes stand-down to the duplicate's own window" \
                    "$prompt_body" "your-own-window-id"
else
    fail "respawn_agent did not paste a prompt body (cold flavour, prompt-safety run)"
fi
rm -f "$WORK/prompt-captured.txt"

# --- Test 17: incident 2026-06-02 — respawn kill scope (root cause 2) --
#
# When the respawn replaces an existing target window, the only kill
# the entire dance may issue is `kill-window -t <target>`. Never the
# watcher window, never a session, never the server.
#
# This is the orchestrator-UNRESPONSIVE replacement (--force-replace):
# the window IS present and we deliberately replace the wedged claude.
# The absent-target path (no --force-replace) would instead ABORT here
# via the issue #203 re-verify guard — see Test 18.

echo '=== incident 2026-06-02: respawn kills ONLY the exact target window (force-replace) ==='
: > "$TMUX_LOG"
rm -f "$WORK/tmux-target-absent"   # stub lists watcher AND orchestrator → kill path fires

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS
    FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS=1
    export FRESH_SPAWN_POST_PASTE_VERIFY_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator --force-replace
) 2>"$WORK/stderr-17.log"
rc=$?
assert_eq "respawn over an existing target window exits 0" "$rc" "0"

tmux_log=$(cat "$TMUX_LOG")
assert_contains "respawn kills the stale target window (exact name)" \
                "$tmux_log" "kill-window -t orchestrator"
assert_not_contains "respawn NEVER kills the watcher window" \
                    "$tmux_log" "kill-window -t watcher"
assert_not_contains "respawn NEVER kills a session" "$tmux_log" "kill-session"
assert_not_contains "respawn NEVER kills the server" "$tmux_log" "kill-server"

# --- Test 18: issue #203 — re-verify guard ABORTS kill of a live -------
# orchestrator on the absent-target path (no --force-replace).
#
# The catastrophe class: an absent-target respawn decision fires the
# kill-then-spawn (possibly from a restart-surviving async subshell)
# long after the decision, by which time a LIVE orchestrator reoccupies
# the window. Without --force-replace the helper must re-verify and
# ABORT (rc=5) — never destroying the healthy agent — and must NOT issue
# any kill-window.

echo '=== issue #203: absent-path respawn ABORTS the kill when target reappeared (live orchestrator) ==='
: > "$TMUX_LOG"
rm -f "$WORK/tmux-target-absent"   # stub lists orchestrator → window is PRESENT (reappeared)
launchers_before=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)

(
    NEXUS_ROOT="$FAKE_NEXUS"
    export NEXUS_ROOT
    HOME="$FAKE_HOME"
    export HOME
    PATH="$TMUX_STUB_BIN:$PATH"
    export PATH
    PANE_STATE_BIN="$PANE_STATE_STUB"
    export PANE_STATE_BIN
    FRESH_SPAWN_READINESS_BUDGET_SECONDS=2
    export FRESH_SPAWN_READINESS_BUDGET_SECONDS
    FRESH_SPAWN_READINESS_POLL_SECONDS=0
    export FRESH_SPAWN_READINESS_POLL_SECONDS

    # shellcheck source=_respawn.sh
    . "$_test_dir/_respawn.sh"

    _respawn_orchestrator orchestrator
) 2>"$WORK/stderr-18.log"
rc=$?
assert_eq "absent-path respawn ABORTS with rc=5 when a live orchestrator occupies the window" "$rc" "5"

tmux_log=$(cat "$TMUX_LOG")
assert_not_contains "guard: NO kill-window when target reappeared" \
                    "$tmux_log" "kill-window -t orchestrator"
assert_not_contains "guard: NO new-window when aborted" \
                    "$tmux_log" "new-window -d -n orchestrator"
# The abort reason is logged loudly to stderr.
abort_log=$(cat "$WORK/stderr-18.log" 2>/dev/null || true)
assert_contains "guard: abort logged loudly" "$abort_log" "ABORTED before kill"
launchers_after=$(ls "$RESPAWN_TMPDIR"/nexus-respawn-launch-* 2>/dev/null || true)
if [[ "$launchers_before" == "$launchers_after" ]]; then
    pass "guard: no orphan launcher tempfile left behind on abort"
else
    fail "guard: an abort should clean up its launcher tempfile"
fi

# --- Summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
