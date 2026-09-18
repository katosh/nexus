#!/usr/bin/env bash
# Unit tests for monitor/paste-followup.sh (issues #201, #507).
#
# Run: bash monitor/watcher/test-paste-followup.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: shadow `tmux` on PATH with a recorder stub (window list
# from MOCK_TMUX_WINDOWS, every invocation appended to $ACTIONS), and
# point NEXUS_STATE_DIR at a temp dir so the machine-input stamp and
# the ng action-log land in the sandbox. Covers:
#   - happy path: stamp row written, VI-safe tmux sequence (insert
#     guard → set-buffer → paste-buffer → Enter), action-log event
#   - --no-enter skips the submit key
#   - missing window / empty message / unreadable file fail loudly
#     with NO stamp and NO paste
#   - stamp lands even when ng log-action fails (TSV is authoritative)
#
# #507 changed the exit contract: `send-keys Enter` returning 0 means tmux
# accepted a keystroke, not that Claude Code submitted the prompt. The
# helper now CONFIRMS the submission against the target session's own
# transcript and reports only what it established — 0 submitted,
# 3 unconfirmed, 4 established-NOT-submitted.
#
# So the happy paths below must supply a session to confirm against: a
# heartbeat (window → session-id) plus a transcript under NEXUS_CC_HOME,
# into which the tmux stub appends a TUI-submission record when it
# receives the Enter. `MOCK_NO_SUBMIT=1` makes the stub swallow the Enter
# — which is the #507 failure itself, and is asserted to exit 4.
#
# Deep coverage of the confirmation logic (promptSource classification,
# the task-notification false positive, byte-offset scanning, the
# collapsed-paste Enter retry) lives in
# monitor/test-paste-followup-confirm.sh. This file keeps its original
# remit — the stamp, the VI-safe sequence, the flags — plus the exit
# codes that remit now depends on.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$_test_dir/../paste-followup.sh"

PASS=0
FAIL=0
assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — got %q want %q\n' "$label" "$got" "$want" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_contains() {
    local label="$1" hay="$2" needle="$3"
    [[ -n "$needle" ]] || printf '  EMPTY needle — this assertion could only pass VACUOUSLY; fix the CALLER, whose expected value came back empty (your-org/nexus-code#1092).\n' >&2
    if [[ -n "$needle" ]] && grep -qF -- "$needle" <<<"$hay"; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s\n' "$label" >&2
        printf '         expected to find: %s\n' "$needle" >&2
        printf '         in:\n%s\n' "$hay" | sed 's/^/           /' >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_not_contains() {
    local label="$1" hay="$2" needle="$3"
    if grep -qF -- "$needle" <<<"$hay"; then
        printf '  FAIL: %s — unexpectedly found %q\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
ACTIONS="$WORK/actions.log"

# The session paste-followup confirms against (#507). The slug is
# deliberately not the real `/`+`_`→`-` transform of any path: the helper
# must find the transcript by SESSION-ID, never by rebuilding the slug.
CC_HOME="$WORK/cc"
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TRANSCRIPT="$CC_HOME/projects/-stub-slug/$SID.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
export MOCK_TRANSCRIPT="$TRANSCRIPT"

# Recorder tmux stub. list-windows emits MOCK_TMUX_WINDOWS; every
# other subcommand records argv and succeeds (or fails when
# MOCK_TMUX_FAIL names it).
cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "list-windows" ]]; then
    # Three callers: a bare existence check queries `-F
    # '#{window_name}'`; resolve_window_id queries
    # `#{window_id}<delim>#{window_name}` (#323); resolve_window_key /
    # resolve_window_index query `#{window_index}<delim>#{window_name}`
    # (#905). Answer each in its own shape so both resolvers succeed.
    fmt=""; prev=""
    for a in "$@"; do [[ "$prev" == "-F" ]] && fmt="$a"; prev="$a"; done
    case "$fmt" in
        *window_id*)
            # Delimiter EXTRACTED from the requested format, never assumed.
            # Hardcoding a TAB here silently diverged from the resolver when it
            # moved off TAB (your-org/nexus-code#699: a C/POSIX locale makes
            # tmux rewrite a TAB in `-F` output, so every present window read
            # as absent). A stub that hardcodes what it claims to parse fails
            # the same way the code under test did.
            d="${fmt#*'#{window_id}'}"; d="${d%%'#{window_name}'*}"
            for w in ${MOCK_TMUX_WINDOWS:-}; do printf '@3%s%s\n' "$d" "$w"; done ;;
        *window_index*)
            # THE INDEX SHAPE (your-org/nexus-code#905). `resolve_window_key`
            # and `resolve_window_index` ask for
            # `#{window_index}<delim>#{window_name}`, which contains no
            # `window_id` — so it used to fall through to the default arm and
            # come back as a BARE name carrying no delimiter. The resolver then
            # correctly refused the unsplittable row ("Window presence is
            # UNKNOWN, not absent") and the paste never happened. Answer it the
            # way real tmux does: index, delimiter, name — one row per window,
            # indices distinct. Delimiter EXTRACTED from the format, for the
            # same reason as the window_id arm above.
            d="${fmt#*'#{window_index}'}"; d="${d%%'#{window_name}'*}"
            i=0
            for w in ${MOCK_TMUX_WINDOWS:-}; do
                printf '%s%s%s\n' "$i" "$d" "$w"; i=$(( i + 1 ))
            done ;;
        *)           printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    esac
    exit 0
fi
printf '%s\n' "$*" >> "$ACTIONS"
if [[ -n "${MOCK_TMUX_FAIL:-}" && "$cmd" == "$MOCK_TMUX_FAIL" ]]; then
    exit 1
fi
# Stand in for Claude Code: an Enter that the TUI accepts records a
# TUI-submission line in the session transcript (#507). MOCK_NO_SUBMIT=1
# swallows it — an Enter tmux accepted that never became a submit, which
# is precisely the defect the confirmation exists to catch.
if [[ "$cmd" == "send-keys" && "${!#}" == "Enter" \
      && "${MOCK_NO_SUBMIT:-0}" != "1" && -n "${MOCK_TRANSCRIPT:-}" ]]; then
    printf '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":"the follow-up"}}\n' \
        >> "$MOCK_TRANSCRIPT"
fi
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

export ACTIONS
export PATH="$STUB_DIR:$PATH"

# Seed the two surfaces the helper confirms against: the heartbeat that
# maps window → session-id, and a transcript with some pre-existing
# history (so a naive "does this transcript contain a submission?" check
# would wrongly confirm on the OLD line rather than a newly appended one).
seed_session() {
    local window="$1"
    mkdir -p "$RUN_STATE/heartbeat"
    printf '{"state":"idle_prompt","last_activity":%s,"session_id":"%s","window":"%s"}\n' \
        "$(date +%s)" "$SID" "$window" > "$RUN_STATE/heartbeat/$window.json"
    printf '{"type":"user","promptSource":"typed","message":{"role":"user","content":"the ORIGINAL spawn prompt"}}\n' \
        > "$TRANSCRIPT"
    printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t0","content":"ok"}]}}\n' \
        >> "$TRANSCRIPT"
}

# Confirmation env: hermetic CC home, and a short budget so a
# deliberately-unconfirmable case costs ~2s rather than the 20s default.
helper_env() {
    printf '%s\n' \
        "NEXUS_STATE_DIR=$RUN_STATE" \
        "NEXUS_CC_HOME=$CC_HOME" \
        "PASTE_CONFIRM_TIMEOUT_SECONDS=2" \
        "PASTE_CONFIRM_POLL_SECONDS=0.05" \
        "BASH_ENV="
}

# ── THE FIXTURE'S PATH ISOLATION, MADE REAL (your-org/nexus-code#1120, #1188)
#
# `export PATH="$STUB_DIR:$PATH"` above is NOT sufficient in this workspace, and
# the reason is that it is undone in the CHILD. Agent processes carry
# `BASH_ENV=$NEXUS_ROOT/monitor/shellenv/bash_env.sh`, which bash sources at the
# start of EVERY non-interactive shell and which force-fronts the nexus
# toolchain — including `monitor/tmuxwrap` — ahead of whatever PATH it inherited.
# `run_helper` drives the code under test as `env … bash "$SCRIPT"`, a new
# non-interactive bash, so inside it a bare `tmux` is the WRAPPER and the
# recorder stub is second in line.
#
# The wrapper is a pass-through, so the helper's own calls still reach the stub —
# but on its way there tmuxwrap issues exactly one `show -s command-alias` of its
# own (its `_tw_resolve_alias`, monitor/tmuxwrap/tmux:572, a read of a SERVER
# OPTION rather than a write to any board), and the stub duly recorded it. That
# put ONE line in $ACTIONS on a path where the helper does nothing, so
# `missing window: no tmux writes` read `got 1 want 0`.
#
# Measured at 50c36ef, tree byte-identical, PATH-injection the ONLY variable:
#   bash                   test-paste-followup.sh  -> 43 passed / 1 failed
#   env -u BASH_ENV   bash test-paste-followup.sh  -> 44 passed / 0 failed
#   env -u NEXUS_ROOT bash test-paste-followup.sh  -> 44 passed / 0 failed
# (front-path is guarded on $NEXUS_ROOT, so either unset disarms it.)
#
# So #1120's two candidate explanations — "the guard stopped short-circuiting"
# or "the fixture's window really is present" — are BOTH wrong: the helper's
# short-circuit is intact and MOCK_TMUX_WINDOWS never lists `no-such-window`.
# The cause was never in the tree, which is exactly why #1120 reproduced at two
# refs with the blob unchanged. #1188 carries the CLASS (29 at-risk suites) and
# this fix does NOT close it: the dangerous direction there is a suite whose
# stub is bypassed reporting GREEN about the wrapper instead of its subject, and
# that is invisible. This is one member, fixed at the member.
#
# The remedy is #1105's shape — belt, and an ALARM. `helper_env` now pins an
# EMPTY `BASH_ENV` for the child (belt: no force-front, so the stub the fixture
# installed is the tmux the helper reaches), and the control below asserts that
# from inside the same `bash` shape `run_helper` uses (alarm: a future mechanism
# that displaces the stub again must be RED here, naming the isolation, instead
# of surfacing as an unrelated off-by-one in a recorder count). The belt fixes
# today's force-front; the alarm is the half that generalises.
# THE PROBE MUST RUN THE REAL BELT, NOT A COPY OF IT (skeptic F4). This line used
# to hardcode `env "BASH_ENV=" bash …`, which tested a DUPLICATE of the pin rather
# than the pin — so removing the belt from helper_env left the alarm GREEN and the
# regression resurfaced as exactly the "unrelated off-by-one in a recorder count"
# three lines above promise it would replace. Measured, belt-only mutant against
# the hardcoded form: 44 passed / 1 failed with `ISOLATION CONTROL` PASSING.
# The author's own mutant could not see this because it rewrote BOTH strings at
# once — and reported the sentinel appearing TWICE as proof the mutation applied,
# without asking why a belt-only change would touch two sites.
# Calling helper_env means the probe exercises whatever run_helper actually gives
# the child, so a belt regression reds the alarm AND a novel force-front still does.
# RUN_STATE is a helper_env input and run_helper reassigns it per call; give the
# probe its own so `set -u` has something bound.
RUN_STATE=$(mktemp -d "$WORK/state.isoprobe.XXXXXX")
_pf_child_tmux=$(env $(helper_env) bash -c 'command -v tmux' 2>/dev/null)
if [[ "$_pf_child_tmux" == "$STUB_DIR/tmux" ]]; then
    printf '  PASS: %s\n' "ISOLATION CONTROL — a child \`bash\` reaches the FIXTURE stub, not a PATH-fronted wrapper (#1120)"
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: %s\n' "ISOLATION CONTROL — the code under test would reach ${_pf_child_tmux:-<nothing>}, not this fixture's stub (#1120/#1188); every \$ACTIONS assertion below would be about that binary's calls too" >&2
    FAIL=$(( FAIL + 1 ))
fi

run_helper() {
    # Fresh per-run state dir so stamp assertions are exact.
    RUN_STATE=$(mktemp -d "$WORK/state.XXXXXX")
    [[ "${SKIP_SEED:-0}" == "1" ]] || seed_session "$1"
    HELPER_OUT=$(env $(helper_env) bash "$SCRIPT" "$@" 2>&1)
    HELPER_RC=$?
    : > /dev/null
}

echo '=== happy path: stamp + VI-safe sequence + submit ==='
export MOCK_TMUX_WINDOWS='demo-rerun-lead'
: > "$ACTIONS"
run_helper demo-rerun-lead --message 'please also plot chrX' --note 'unit test'
assert_eq "exit 0" "$HELPER_RC" "0"
assert_contains "reports a CONFIRMED submission, never 'delivered'" "$HELPER_OUT" 'submitted'
assert_not_contains "the pre-#507 banner is gone" "$HELPER_OUT" 'delivered to'
assert_contains "machine-input stamp written" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'
assert_contains "stamp src is paste-followup" \
    "$(awk -F'\t' '{print $3}' "$RUN_STATE/machine-input.tsv" 2>/dev/null)" 'paste-followup'
seq=$(cat "$ACTIONS")
# Targeting is by the resolved @id (#323), not the dotted-safe name.
assert_contains "insert-mode guard sent"  "$seq" 'send-keys -t @3 i BSpace'
assert_contains "buffer loaded"           "$seq" 'set-buffer -b'
assert_contains "buffer pasted to window" "$seq" '-t @3'
assert_contains "Enter submits"           "$seq" 'send-keys -t @3 Enter'
# Order: the stamp must precede any tmux action is enforced by code
# structure; here assert the paste precedes the Enter.
paste_line=$(grep -n 'paste-buffer' "$ACTIONS" | head -1 | cut -d: -f1)
enter_line=$(grep -n 'Enter' "$ACTIONS" | head -1 | cut -d: -f1)
if (( paste_line < enter_line )); then
    echo '  PASS: paste precedes Enter'; PASS=$((PASS+1))
else
    echo '  FAIL: Enter sent before paste' >&2; FAIL=$((FAIL+1))
fi
assert_contains "action-log audit event appended" \
    "$(cat "$RUN_STATE/action-log.jsonl" 2>/dev/null)" '"event":"paste-followup"'
assert_contains "action-log event carries the window" \
    "$(cat "$RUN_STATE/action-log.jsonl" 2>/dev/null)" 'demo-rerun-lead'

echo '=== --no-enter: paste without submit ==='
: > "$ACTIONS"
run_helper demo-rerun-lead --message 'queued text' --no-enter
assert_eq "exit 0" "$HELPER_RC" "0"
assert_not_contains "no Enter sent" "$(cat "$ACTIONS")" 'Enter'
assert_contains "still stamped" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'

echo '=== --src: injector-identity hint stamped as the src column (#293) ==='
run_helper demo-rerun-lead --message 'continue' --src skeptic-nudge
assert_eq "--src exit 0" "$HELPER_RC" "0"
assert_eq "--src recorded as the ledger src token" \
    "$(awk -F'\t' '{print $3}' "$RUN_STATE/machine-input.tsv" 2>/dev/null)" \
    "skeptic-nudge"

echo '=== --src + --no-enter: src carries the -no-enter suffix ==='
run_helper demo-rerun-lead --message 'queued' --src skeptic-nudge --no-enter
assert_eq "--src --no-enter exit 0" "$HELPER_RC" "0"
assert_eq "src token carries -no-enter suffix" \
    "$(awk -F'\t' '{print $3}' "$RUN_STATE/machine-input.tsv" 2>/dev/null)" \
    "skeptic-nudge-no-enter"

echo '=== --src absent: default src preserved (back-compat) ==='
run_helper demo-rerun-lead --message 'continue'
assert_eq "default src is paste-followup" \
    "$(awk -F'\t' '{print $3}' "$RUN_STATE/machine-input.tsv" 2>/dev/null)" \
    "paste-followup"

echo '=== message from --file and stdin ==='
printf 'multi\nline\nfollow-up\n' > "$WORK/msg.txt"
: > "$ACTIONS"
run_helper demo-rerun-lead --file "$WORK/msg.txt"
assert_eq "--file exit 0" "$HELPER_RC" "0"
: > "$ACTIONS"
RUN_STATE=$(mktemp -d "$WORK/state.XXXXXX")
seed_session demo-rerun-lead
HELPER_OUT=$(printf 'from stdin\n' | env $(helper_env) bash "$SCRIPT" demo-rerun-lead 2>&1)
HELPER_RC=$?
assert_eq "stdin exit 0" "$HELPER_RC" "0"
assert_contains "stdin path stamped" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'

# ── #507: the exit code must report only what was established ────────────
echo '=== #507: Enter accepted, prompt never submitted → exit 4 ==='
: > "$ACTIONS"
export MOCK_NO_SUBMIT=1
run_helper demo-rerun-lead --message 'a correction that must not be lost'
assert_eq "established negative: exit 4" "$HELPER_RC" "4"
assert_contains "names the outcome"    "$HELPER_OUT" 'pasted (NOT submitted)'
assert_not_contains "never claims delivery"  "$HELPER_OUT" 'delivered'
assert_not_contains "never claims submission" "$HELPER_OUT" ': submitted'
# The watcher's paste-unconfirmed detector reads this ledger. A paste that
# landed but did not submit must stay stamped, so the watcher agrees with
# us rather than misattributing the pane churn to the operator.
assert_contains "stamp retained on a NOT-submitted verdict" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'
# One retry, and only one: the collapsed-paste `[Pasted text #N]` case.
assert_eq "Enter retried exactly once" "$(grep -c 'send-keys -t @3 Enter' "$ACTIONS")" "2"
unset MOCK_NO_SUBMIT

echo '=== #507: no heartbeat ⇒ nothing to confirm against → exit 3 ==='
: > "$ACTIONS"
SKIP_SEED=1 run_helper demo-rerun-lead --message 'into the void'
assert_eq "unconfirmable: exit 3" "$HELPER_RC" "3"
assert_contains "says unconfirmed"  "$HELPER_OUT" 'submission unconfirmed'
assert_contains "names the reason"  "$HELPER_OUT" 'no session-id'
assert_not_contains "never claims delivery" "$HELPER_OUT" 'delivered'
# It must not assert a NEGATIVE it did not establish either.
assert_not_contains "not an established negative" "$HELPER_OUT" 'pasted (NOT submitted) to'

echo '=== failure modes: loud, no stamp, no paste ==='
: > "$ACTIONS"
run_helper no-such-window --message 'hi'
assert_eq "missing window: non-zero exit" "$(( HELPER_RC != 0 ))" "1"
assert_contains "missing window: loud stderr" "$HELPER_OUT" 'window not found'
assert_eq "missing window: no stamp" "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null | wc -l)" "0"
assert_eq "missing window: no tmux writes" "$(wc -l < "$ACTIONS")" "0"

run_helper demo-rerun-lead --message '   '
assert_eq "blank message: non-zero exit" "$(( HELPER_RC != 0 ))" "1"
assert_contains "blank message: loud stderr" "$HELPER_OUT" 'message is empty'

run_helper demo-rerun-lead --file "$WORK/does-not-exist.txt"
assert_eq "unreadable file: non-zero exit" "$(( HELPER_RC != 0 ))" "1"

echo '=== paste failure after stamp: loud failure, stamp retained ==='
: > "$ACTIONS"
export MOCK_TMUX_FAIL='paste-buffer'
run_helper demo-rerun-lead --message 'doomed'
assert_eq "paste failure: non-zero exit" "$(( HELPER_RC != 0 ))" "1"
assert_contains "paste failure: loud stderr" "$HELPER_OUT" 'paste-buffer failed'
# The pre-paste stamp stays — over-claiming machine input is the
# safe direction (it can only delay an operator seed one round).
assert_contains "paste failure: stamp retained" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'
unset MOCK_TMUX_FAIL

echo '=== your-org/nexus-code#1200: refuse to paste into a pane sitting on an overlay ==='
# THE PROPERTY: a message-delivery paste must not land in a pane with a
# permission overlay up, because the trailing Enter is consumed by the overlay
# and SELECTS ITS HIGHLIGHTED DEFAULT instead of delivering the message. The
# recorded incident: an instruction reading "OPTION 3 — HOLD. Do not commit the
# assets" selected `Commit all 325 MB`, pushed 384 files, and the send reported
# `delivered` — correctly by its own contract, which answers DID THE TEXT
# ARRIVE and never DID THE TEXT GET READ.
#
# The pane-state answer is injected through NEXUS_PASTE_PANE_STATE_BIN rather
# than by driving a real overlay: the property under test is what the paste
# path DOES with a `blocked` verdict, not how pane-state derives one (which
# test-pane-state.sh owns against real ANSI fixtures).
_ovl_stub="$STUB_DIR/ps-blocked"
cat > "$_ovl_stub" <<'PSSTUB'
#!/usr/bin/env bash
printf 'state=blocked active=1 window=9 name=%s overlay=permission content_hash=1\n' "$1"
PSSTUB
chmod +x "$_ovl_stub"
_ovl_ok="$STUB_DIR/ps-idle"
cat > "$_ovl_ok" <<'PSSTUB'
#!/usr/bin/env bash
printf 'state=idle active=0 window=9 name=%s input=blank content_hash=1\n' "$1"
PSSTUB
chmod +x "$_ovl_ok"

export MOCK_TMUX_WINDOWS='demo-rerun-lead'
: > "$ACTIONS"
NEXUS_PASTE_PANE_STATE_BIN="$_ovl_stub" \
    run_helper demo-rerun-lead --message 'OPTION 3 - HOLD. Do not commit the assets.'
assert_eq       "#1200 blocked pane: refuses (non-zero exit)" "$(( HELPER_RC != 0 ))" "1"
assert_contains "#1200 blocked pane: names the overlay kind"  "$HELPER_OUT" "overlay=permission"
assert_contains "#1200 blocked pane: says why, not just no"   "$HELPER_OUT" "SELECT ITS HIGHLIGHTED DEFAULT"
# THE ARM THAT MATTERS. A refusal that still pasted would be worse than no
# guard: it would carry the incident AND a message saying it did not.
assert_not_contains "#1200 blocked pane: NOTHING was pasted" \
    "$(cat "$RUN_STATE/machine-input.tsv" 2>/dev/null)" $'demo-rerun-lead\t'

# POSITIVE CONTROL — the same call with an IDLE verdict must still deliver.
# Without it every assertion above is satisfied by a guard that refuses always.
: > "$ACTIONS"
NEXUS_PASTE_PANE_STATE_BIN="$_ovl_ok" \
    run_helper demo-rerun-lead --message 'ordinary follow-up'
assert_eq "#1200 CONTROL: an idle pane still accepts the paste" "$HELPER_RC" "0"

# EVERY DOUBT PASTES — deliberately the opposite of the dead-pane guard above.
# This guard prevents a WRONG DELIVERY; refusing on doubt would break every
# delivery wherever pane-state is unavailable, including hermetic fixtures.
: > "$ACTIONS"
NEXUS_PASTE_PANE_STATE_BIN="$STUB_DIR/does-not-exist" \
    run_helper demo-rerun-lead --message 'unreadable pane state'
assert_eq "#1200 CONTROL: an unavailable pane-state does NOT block delivery" "$HELPER_RC" "0"

# The override is deliberate, and it is the issue's own ask 2: answering an
# overlay is a DIFFERENT ACT from sending a message, and must be spelled.
: > "$ACTIONS"
NEXUS_PASTE_PANE_STATE_BIN="$_ovl_stub" \
    run_helper demo-rerun-lead --message 'I have looked' --allow-blocked
assert_eq "#1200 --allow-blocked: the deliberate override delivers" "$HELPER_RC" "0"
# …AND IS ACTUALLY RECORDED. The first cut documented an audit trail and wrote
# nothing — a claim the code did not implement, in the guard whose whole subject
# is machinery that reports success for a question adjacent to the one that
# matters. Asserted on the artefact, not on the prose.
# ASSERTED ON THE ACTION LOG, NOT ON STDERR. The first cut of this arm checked
# $HELPER_OUT — which also carries the stderr courtesy print — so a mutant that
# dropped the RECORD and kept the print left it green. Measured: 56/0 with the
# record deleted. That is the proxy-vs-property defect this very guard exists to
# close, occurring inside it: the property is "a durable record exists", and
# stderr is not durable. The record is what an auditor reads.
assert_contains "#1200 --allow-blocked: the override is AUDITED in the ACTION LOG" \
    "$(cat "$RUN_STATE"/action-log.jsonl 2>/dev/null)" "allow-blocked OVERRIDE"
assert_contains "#1200 --allow-blocked: the logged record names the overlay it overrode" \
    "$(cat "$RUN_STATE"/action-log.jsonl 2>/dev/null)" "overlay=permission"

# FIELD-EXACT extraction. A greedy `.*state=` binds to the LAST match, so a
# line whose real state is `idle` but which also carries `refined_state=blocked`
# would refuse; and the mirror case (`state=blocked … x_state=idle`) would let
# the paste THROUGH, which is the defect this guard exists to stop.
_ovl_greedy="$STUB_DIR/ps-greedy"
cat > "$_ovl_greedy" <<'PSSTUB'
#!/usr/bin/env bash
printf 'state=idle active=0 window=9 name=%s refined_state=blocked overlay=permission\n' "$1"
PSSTUB
chmod +x "$_ovl_greedy"
: > "$ACTIONS"
NEXUS_PASTE_PANE_STATE_BIN="$_ovl_greedy" \
    run_helper demo-rerun-lead --message 'idle pane, decoy field'
assert_eq "#1200 a trailing *_state=blocked field does NOT trigger the guard" "$HELPER_RC" "0"
_ovl_greedy2="$STUB_DIR/ps-greedy2"
cat > "$_ovl_greedy2" <<'PSSTUB'
#!/usr/bin/env bash
printf 'state=blocked active=1 window=9 name=%s overlay=permission prior_state=idle\n' "$1"
PSSTUB
chmod +x "$_ovl_greedy2"
: > "$ACTIONS"
NEXUS_PASTE_PANE_STATE_BIN="$_ovl_greedy2" \
    run_helper demo-rerun-lead --message 'blocked pane, decoy field'
assert_eq "#1200 …and a trailing *_state=idle does NOT suppress it" "$(( HELPER_RC != 0 ))" "1"

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
