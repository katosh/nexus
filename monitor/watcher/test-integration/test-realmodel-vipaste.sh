#!/usr/bin/env bash
# test-realmodel-vipaste.sh — closes the 2c hole the cc-harness gate
# leaves open.
#
# The gate's over-limit scenario asserts "recovery brief pasted on wake"
# against a STUBBED paste function (`_ol_test_paste` writes to a log), so
# no real paste ever reaches a real TUI. VI-mode drift in a Claude Code
# release would therefore pass the gate green and only surface in
# production, where a lost paste reads as a silent worker.
#
# This scenario boots the REAL candidate with `editorMode: "vim"`, puts
# the input box in NORMAL mode (the hazard state), and then runs the
# production paste helpers against it.
#
# WHY VI MODE IS FORCED ON. The nexus does not set an editor mode, so a
# production pane is normally in insert mode, where any VI handling is
# inert. A gate that boots the same way pins nothing. The hazard is the
# pane that IS in normal mode — an operator who turns VI mode on, or a
# pane a stray Escape left there — so the honest gate is the contract
# under VI mode ON. Booting with `--settings` is also what makes an
# `editorMode` regression visible: the scenario asserts the candidate
# honours the key before it relies on it.
#
# WHAT THE PASTE PATHS RELY ON. Every production paste is now BRACKETED
# (`paste-buffer -p`): the respawn path goes through
# monitor/_paste-deliver.sh (`pd_paste_file`, after an `i BSpace` guard),
# and monitor/paste-followup.sh sends `i BSpace` + `paste-buffer -p -d -b`.
# A bracketed paste lands as literal text whichever mode the box is in,
# so on today's binaries the guard is redundant and removing it leaves
# this scenario green (measured on 2.1.273). That redundancy is the
# PROPERTY both paths rest on, so it is pinned directly:
#
#   1. a control proves the marker bytes, pasted PLAIN (unbracketed) into
#      the normal-mode box, do NOT reach it — they run as VI commands;
#   2. the respawn path — `_respawn_paste_prompt_file` in
#      monitor/watcher/_respawn.sh — delivers and SUBMITS into the
#      normal-mode box;
#   3. the follow-up path — monitor/paste-followup.sh — delivers and
#      SUBMITS into the normal-mode box;
#   4. a bracketed paste with NO guard at all still lands literally.
#
# If a release stops treating a bracketed paste as literal, (4) goes red
# and the guard becomes load-bearing. The guards themselves are pinned
# hermetically, by monitor/watcher/test-paste-followup.sh and the
# _paste-deliver.sh suite, which record the tmux calls against a stub.
# Behaviour cannot pin a step the candidate makes redundant; structure
# can.
#
# Production paste calls run under cch_with_tmux_env, so their bare
# `tmux` calls — including the pane-liveness check each runs before it
# pastes — hit the harness's isolated socket, never production.
#
# Both prompt files are written WITHOUT a trailing newline on purpose. A
# trailing newline is itself a submit, so it would mask the explicit
# `Enter` and the "SUBMITTED" assertion would pin nothing.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.
#
# Run: RUN_CC_HARNESS=1 CLAUDE_BIN=<candidate> bash test-realmodel-vipaste.sh
set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_self_dir/../../.." && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL: %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

cch_skip_if_disabled
# Full request bodies, not just the mock's one-line summary. The summary
# logs only the LAST message of a request, and after the first turn that
# is a system block — so a "did the text cross the wire" assertion built
# on the summary can only ever see the first turn (it lands there via the
# session-title call). bodies.log carries every POST body verbatim.
export MOCK_DUMP_BODIES=1
cch_setup
trap cch_teardown EXIT
CCH_BODIES="$CCH_DIR/bodies.log"

echo "=== real-binary harness: VI-safe paste (2c) ==="
echo "    claude:  $CLAUDE_BIN ($("$CLAUDE_BIN" --version 2>&1 | head -1))"

# Markers carry NO character that enters insert mode in VI normal mode
# (no a A i I o O c C s S R). A marker that contained one would type
# itself into the box even with the `i` guard removed, and the mutation
# arm that removes the guard would go undetected again.
WIN_NAME=vipaste
MARKER="NEXVPT-$$-KMT"
MARKER_BKT="NEXVPT-$$-BKT"
MARKER_LIT="NEXVPT-$$-LTL"
NEVER="NEXVPT-never-pasted"

SETTINGS="$CCH_DIR/vi-settings.json"
cat > "$SETTINGS" <<'JSON'
{
  "skipDangerousModePermissionPrompt": true,
  "env": { "DISABLE_AUTOUPDATER": "1" },
  "editorMode": "vim"
}
JSON

WIN=$(cch_boot_worker "$WIN_NAME" "$SETTINGS")
[[ -n "$WIN" ]] || { echo "boot failed" >&2; exit 1; }

wait_for "candidate booted to idle" 60 -- cch_state_is "$WIN" idle \
    || { cch_capture "$WIN" | tail -15 >&2; echo "=== summary: $PASS passed, $FAIL failed ==="; exit 1; }

# The VI-mode indicator is the whole premise of this scenario. With
# `editorMode: "vim"` honoured the input box opens in insert mode and
# renders `-- INSERT --`; Escape drops it to normal mode and the
# indicator goes away. If a release stops honouring the key, BOTH
# assertions below go red and say so — the scenario can never quietly
# degrade into the non-pinning version it replaced.
_in_insert()  { command grep -qF -- '-- INSERT --' <<<"$(cch_capture "$WIN")"; }
_in_normal()  { ! _in_insert; }

wait_for "candidate honours editorMode=vim (-- INSERT -- indicator)" 30 -- _in_insert \
    || cch_capture "$WIN" | tail -6 >&2

cch_tmux send-keys -t "$CCH_SESSION:$WIN" Escape
wait_for "Escape left insert mode (pane is in VI NORMAL mode)" 15 -- _in_normal \
    || cch_capture "$WIN" | tail -6 >&2

PROMPT="$CCH_DIR/vipaste-prompt.txt"
printf '%s' "$MARKER" > "$PROMPT"      # no trailing newline — see header
_marker_rendered() { command grep -qF "$MARKER" <<<"$(cch_capture "$WIN")"; }

# ---- negative control: the marker rule, PROVEN, not asserted in a comment
# The comment above says the marker carries no character that enters
# insert mode. A rule in a comment decays. Prove it instead: paste the
# very same bytes into the NORMAL-mode box with NO guard in front, and
# hold that they do not reach the box. That is what makes the marker
# a discriminating probe: the delivery assertions below can only pass
# because the bytes landed as TEXT, never because they happened to type
# themselves. If a release made a plain paste literal too (as a bracketed
# paste already is), this control goes red and says so.
cch_tmux load-buffer -b "$CCH_SESSION-ctl" "$PROMPT"
cch_tmux paste-buffer -b "$CCH_SESSION-ctl" -t "$CCH_SESSION:$WIN"
hold_false "unguarded plain paste in NORMAL mode does NOT reach the box" 3 \
    -- _marker_rendered
# The bytes ran as VI commands, so the box can be in any mode now.
cch_tmux send-keys -t "$CCH_SESSION:$WIN" Escape
wait_for "pane is back in VI NORMAL mode after the unguarded control" 15 -- _in_normal \
    || cch_capture "$WIN" | tail -6 >&2

# ---- path 1: the respawn paste helper --------------------------------
# Source the production respawn helper and drive it under
# cch_with_tmux_env. It takes a window NAME (it targets `:=<name>`, the
# exact-match form), not a session:index pair. This is the real sequence
# the watcher uses to brief a respawned orchestrator.
export PATH="$CCH_DIR/.bin:$PATH"
# shellcheck source=/dev/null
. "$REPO_ROOT/monitor/watcher/_respawn.sh" >/dev/null 2>&1

if declare -F _respawn_paste_prompt_file >/dev/null; then
    ok "production paste helper _respawn_paste_prompt_file is loadable"
else
    bad "could not load _respawn_paste_prompt_file from _respawn.sh"; exit 1
fi

if cch_with_tmux_env _respawn_paste_prompt_file "$WIN_NAME" "$PROMPT"; then
    ok "respawn paste sequence (guard + bracketed paste + Enter) returned 0"
else
    bad "respawn paste sequence returned non-zero"
fi

# The control above proved these exact bytes do NOT land when pasted
# plain into the NORMAL-mode box, so seeing them here means the
# production path delivered them as literal text.
wait_for "pasted text reached the live TUI in VI NORMAL mode" 30 -- _marker_rendered \
    || cch_capture "$WIN" | tail -15 >&2

# STRONGER than "the log is non-empty": the boot itself issues requests
# (session title, etc.), so a size check would pass without any submit.
# Assert the MARKER TEXT crossed the wire as a user message. The prompt
# file carries no trailing newline, so the explicit `Enter` is the only
# thing that can submit it — this assertion pins that step.
_mock_saw_marker() { command grep -qF "$MARKER" "$CCH_BODIES" 2>/dev/null; }
wait_for "the paste SUBMITTED (the explicit Enter submitted it)" 60 -- _mock_saw_marker \
    || { echo "    request bodies seen: $(command grep -c '===BODY' "$CCH_BODIES" 2>/dev/null)" >&2; }

# Control for that assertion: a string never pasted must NOT be in the log.
if command grep -qF "$NEVER" "$CCH_BODIES" 2>/dev/null; then
    bad "control: an unpasted string appeared in the request log"
else
    ok "control: an unpasted string is absent from the request log"
fi

# Negative control: a marker that was never pasted must not appear.
if command grep -qF "$NEVER" <<<"$(cch_capture "$WIN")"; then
    bad "control: an unpasted marker appeared — the assertion is not specific"
else
    ok "control: an unpasted marker does not appear"
fi

# ---- path 2: the bracketed-paste follow-up helper --------------------
# monitor/paste-followup.sh is the highest-frequency injector and the
# only one that uses `paste-buffer -p` (bracketed paste). Run the real
# script, hermetically: NEXUS_STATE_DIR points at the harness state dir
# and PASTE_NG_BIN stubs the action-log append.
#
# Its submission CONFIRMATION cannot pass here — it reads the target's
# heartbeat and session transcript, neither of which a harness window
# has — so it is expected to report `unconfirmed` (rc 3). That is not
# the contract under test: rc 1 (a tmux/usage hard failure) is a real
# failure, and the paste itself is proven by the two assertions below.
wait_for "pane returned to idle after the first turn" 90 -- cch_state_is "$WIN" idle \
    || cch_capture "$WIN" | tail -10 >&2

cch_tmux send-keys -t "$CCH_SESSION:$WIN" Escape
wait_for "pane is in VI NORMAL mode again before the follow-up paste" 15 -- _in_normal \
    || cch_capture "$WIN" | tail -6 >&2

FOLLOWUP="$CCH_DIR/followup-msg.txt"
printf '%s' "$MARKER_BKT" > "$FOLLOWUP"   # no trailing newline — see header
cch_with_tmux_env env NEXUS_STATE_DIR="$CCH_STATE_DIR" PASTE_NG_BIN=/bin/true \
    bash "$REPO_ROOT/monitor/paste-followup.sh" "$WIN_NAME" \
        --file "$FOLLOWUP" --src cc-harness --confirm-timeout 2 \
        > "$CCH_DIR/followup.out" 2>&1
fu_rc=$?
if (( fu_rc == 1 )); then
    bad "paste-followup.sh hard-failed (rc 1): $(tail -2 "$CCH_DIR/followup.out")"
else
    ok "paste-followup.sh completed the bracketed paste (rc $fu_rc)"
fi

_bkt_rendered() { command grep -qF "$MARKER_BKT" <<<"$(cch_capture "$WIN")"; }
wait_for "bracketed paste (paste-buffer -p -d -b) reached the live TUI" 30 -- _bkt_rendered \
    || cch_capture "$WIN" | tail -15 >&2

_mock_saw_bkt() { command grep -qF "$MARKER_BKT" "$CCH_BODIES" 2>/dev/null; }
wait_for "the bracketed paste SUBMITTED (marker text reached the mock)" 60 -- _mock_saw_bkt \
    || { echo "    follow-up output: $(tail -2 "$CCH_DIR/followup.out")" >&2
         cch_capture "$WIN" | tail -12 >&2
         echo "    request bodies seen: $(command grep -c '===BODY' "$CCH_BODIES" 2>/dev/null)" >&2; }

# ---- the property both paths rest on, pinned -------------------------
# Paste bracketed into a NORMAL-mode box with NO insert-mode guard at
# all. Today the text still lands, which is why mutating the guard out
# of paste-followup.sh (or _paste-deliver.sh) leaves this scenario
# green: on a bracketed paste the guard is redundant. This assertion is
# how a release that CHANGES that gets caught. Red here does not mean
# production broke — production sends the guard — it means both paths
# now depend on the guard, so surface 2c needs a fresh look.
wait_for "pane returned to idle after the follow-up turn" 90 -- cch_state_is "$WIN" idle \
    || cch_capture "$WIN" | tail -10 >&2
cch_tmux send-keys -t "$CCH_SESSION:$WIN" Escape
wait_for "pane is in VI NORMAL mode for the unguarded bracketed probe" 15 -- _in_normal \
    || cch_capture "$WIN" | tail -6 >&2
cch_tmux set-buffer -b "$CCH_SESSION-lit" -- "$MARKER_LIT"
cch_tmux paste-buffer -p -d -b "$CCH_SESSION-lit" -t "$CCH_SESSION:$WIN"
_lit_rendered() { command grep -qF "$MARKER_LIT" <<<"$(cch_capture "$WIN")"; }
wait_for "a bracketed paste lands as literal text with NO insert-mode guard" 30 -- _lit_rendered \
    || { echo "    the guard in monitor/paste-followup.sh is now LOAD-BEARING — re-check surface 2c" >&2
         cch_capture "$WIN" | tail -12 >&2; }

echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
