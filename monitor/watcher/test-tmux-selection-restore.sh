#!/usr/bin/env bash
# test-tmux-selection-restore.sh — the operator's tmux window selection
# survives an orchestrator restart (your-org/nexus-code#1528).
#
# WHAT IS UNDER TEST. `cc-auto-update-apply.sh restart-orchestrator` kills the
# orchestrator window; the watcher's `_respawn_spawn_window` recreates it with
# `new-window -d`. Killing a session's ACTIVE window makes tmux select another
# window, `-d` never selects, so the operator lands on `services`, a worker or
# the restart watchdog and stays there. `monitor/_tmux-window.sh` now carries a
# capture (taken by whoever kills) and a restore (at the single creation site),
# with four rules and a deliberate-navigation veto; this suite drives them
# against a REAL tmux, because every one of those rules is a claim about what
# tmux does to the active window and a stub would only restate the claim.
#
# TESTED ON tmux 2.6 — this host's version. Nothing here is a claim about a
# newer tmux; the fixture prints the version it drove.
#
# PARTS.
#   A  the helper's rules, driven directly:
#        A1 prior WAS the target      -> the NEW orchestrator window is selected
#        A2 prior another live window -> selection unchanged (a no-op restore)
#        A3 prior CLOSED in the gap   -> the orchestrator (a worker retired)
#        A4 no capture                -> nothing (the NO-CAPTURE POLICY)
#        A5 deliberate navigation     -> left alone
#        A6 stale capture             -> nothing, file consumed
#        A7 consumed exactly once
#        A8 two-phase capture: a stale-watchdog kill vs navigation in the gap
#        A9 grouped sessions: per-session selection, each restored on its own
#        A10 tmux would not answer   -> capture writes nothing; restore inert
#        A11 the #1524 hazard: a prefix sibling AND a same-named stale window
#            — restore targets by @id, so it lands on the new window where a
#            by-NAME select is measured to fail (duplicate) or land on the
#            sibling (exact name absent)
#   B  through `_respawn_spawn_window` itself, the production creation site:
#        B1 crash/version/force path: target PRESENT, capture+kill+restore
#        B2 cc-update path: target ABSENT, capture written by the killer
#        B3 restore forced to FAIL is INERT: rc 0, window created, and the
#           wall time within noise of B1 — measured, both printed
#        B4 the rc 3 contract (new-window failed) is untouched
#   D  rule 4, the SNAPSHOT ARM (operator decision, #1528): with no kill-time
#      capture the watcher's last-seen snapshot decides —
#        D1 orchestrator was active when it vanished -> new orchestrator
#        D2 operator was on a live worker              -> left alone
#        D3 no snapshot                                -> orchestrator (default)
#        D4 stale snapshot                             -> orchestrator
#        D5 snapshot's active window has closed        -> orchestrator
#        D6 the writer keeps the last snapshot that SAW the target (a
#           post-vanish fire writes nothing); D6r precedence: a kill-time
#           capture beats the snapshot
#        D7 grouped sessions, per session; D8 the snapshot is not consumed;
#        D9 dead tmux is inert; D1/D2/D3/D6 again through
#        _respawn_spawn_window with the target ABSENT (the vanished-window path)
#   E  the watcher registers the snapshot writer (source read: the task fn
#      calls tmux_selection_snapshot; the golden table pins the cadence)
#   C  the cc-update verb's ORDERING, read from its source: the first capture
#      precedes the stale-watchdog kill, the refresh precedes the orchestrator
#      kill, the post-kill note follows it, and the EXIT trap drops the file on
#      any exit that did not reach the kill (w240sk F1). Text about code — the BEHAVIOUR of the helper is A, and the verb
#      end-to-end (stub tmux) is `test-cc-auto-update.sh`; C pins the one
#      property neither can see, the ORDER of the calls in the verb.
#
# ISOLATION. A private `-L` socket in a SHORT `TMUX_TMPDIR`, `$TMUX` scrubbed,
# a PATH-front shim built from the real tmux BINARY (`_tmux-fixture.sh`,
# your-org/nexus-code#1105) because `_respawn.sh` and the helper call bare
# `tmux`; the pin is asserted before any leg runs. Never the default socket,
# never `kill-server`.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MON=$(cd "$_test_dir/.." && pwd)
HELPER="$MON/_tmux-window.sh"
RESPAWN="$_test_dir/_respawn.sh"
CCAPPLY="$MON/cc-auto-update-apply.sh"
for f in "$HELPER" "$RESPAWN" "$CCAPPLY"; do
    [[ -f "$f" ]] || { echo "SETUP: missing $f" >&2; exit 1; }
done

# --- `--population` (your-org/nexus-code#803): what this suite READS. ------
# Declared before the tmux server comes up, so a population probe costs no
# server boot. `gp_handle` adds this file and the protocol library itself.
. "$MON/_guard_population.sh"
gp_population() {
    printf '%s\n' "$HELPER" "$RESPAWN" "$CCAPPLY" "$_test_dir/_tmux-fixture.sh"
}
gp_handle "$@"

# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
# shellcheck source=_tmux-fixture.sh
. "$_test_dir/_tmux-fixture.sh"

command -v tmux >/dev/null 2>&1 \
    || { echo "ENV-FAIL: tmux not on PATH — this suite is about real tmux behaviour; refusing rather than skipping" >&2; exit 1; }
REALTMUX=$(nx_real_tmux_bin) || { echo "SKIP: no real tmux BINARY on PATH (only wrappers)" >&2; exit 77; }

WORK=$(mktemp -d -t nexus-1528-XXXXXX)
th_trap_exit "rm -rf $(printf '%q' "$WORK") 2>/dev/null || true"
nx_tmux_fixture_init "$WORK" || { echo "ENV-FAIL: private TMUX_TMPDIR" >&2; exit 1; }
SOCK="nx1528-$$"
th_require_tmux_socket "$SOCK" "$TMUX_TMPDIR"
th_tmux_fixture_conf "$WORK/tmux.conf"
nx_write_tmux_shim "$WORK/bin" "$REALTMUX" "$SOCK" -f "$WORK/tmux.conf" \
    || { echo "SETUP: could not write the tmux shim" >&2; exit 1; }
PATH="$WORK/bin:$PATH"; export PATH
nx_assert_tmux_pinned "$WORK/bin" "$TMUX_TMPDIR/tmux-$(id -u)/$SOCK" || exit 1

cleanup_sessions() {
    local s
    while IFS= read -r s; do
        [[ -n "$s" ]] && tmux kill-session -t "$s" >/dev/null 2>&1 || true
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}
th_trap_exit 'cleanup_sessions'

echo "tmux under test: $(tmux -V 2>&1) via $REALTMUX on socket $SOCK"

# shellcheck source=../_tmux-window.sh
. "$HELPER"

S=zz1528-S; G=zz1528-G
STATE="$WORK/state"; mkdir -p "$STATE"
CAP=$(tmux_selection_capture_file "$STATE")

# Board helpers. Every window runs `sleep`, so nothing renames or exits.
act()  { tmux display-message -p -t "$1:" '#{window_id}' 2>/dev/null; }
wid()  { tmux list-windows -t "$1:" -F '#{window_id}|#{window_name}' 2>/dev/null \
             | awk -F'|' -v n="$2" '$2==n && !seen {print $1; seen=1}'; }
sel()  { tmux select-window -t "$1:$2" >/dev/null 2>&1; }
newwin() { tmux new-window -d -t "$1:" -n "$2" -P -F '#{window_id}' sleep 600; }
board_up() {   # S with orchestrator, services, worker; optional grouped G
    cleanup_sessions
    tmux new-session -d -s "$S" -n orchestrator -x 80 -y 24 sleep 600 || return 1
    newwin "$S" services >/dev/null; newwin "$S" worker >/dev/null
    tmux set-option -t "$S" automatic-rename off >/dev/null 2>&1 || true
    if [[ "${1-}" == grouped ]]; then tmux new-session -d -t "$S" -s "$G" || return 1; fi
    rm -f "$CAP"
    return 0
}
kill_orch() { tmux kill-window -t "$1:$(wid "$1" orchestrator)"; }

echo "== A: the rules, driven on the helper =="

# A1 prior WAS the target. S: last=worker, active=orchestrator.
board_up || th_abort "board"
sel "$S" worker; sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"; rc=$?
assert_rc "A1 capture rc 0" "$rc" 0
kill_orch "$S"
tmux_selection_note_post_kill "$CAP"; rc=$?
assert_rc "A1 post-kill note rc 0" "$rc" 0
auto=$(act "$S")
assert_eq "A1 CONTROL: tmux moved S off the killed window onto its last (worker)" "$auto" "$(wid "$S" worker)"
new=$(newwin "$S" orchestrator)
assert_eq "A1 CONTROL: new-window -d did not move the selection" "$(act "$S")" "$auto"
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A1 restore rc 0" "$rc" 0
assert_contains "A1 rule named" "$out" "rule=prior-was-target select=$new"
assert_eq "A1 S is on the NEW orchestrator window" "$(act "$S")" "$new"

# A2 prior another live window: killing a non-active window moves nothing.
board_up || th_abort "board"
sel "$S" services
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
assert_eq "A2 CONTROL: killing a NON-active window left S on services" "$(act "$S")" "$(wid "$S" services)"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A2 restore rc 0" "$rc" 0
assert_contains "A2 rule: prior still present, already active (no-op)" "$out" "rule=prior-still-present select=already-active"
assert_eq "A2 S still on services" "$(act "$S")" "$(wid "$S" services)"

# A3 prior CLOSED in the gap (a worker retired) -> the orchestrator.
board_up || th_abort "board"
sel "$S" worker
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
tmux kill-window -t "$S:$(wid "$S" worker)"
assert_eq "A3 CONTROL: the worker's retirement moved S (tmux, not the operator)" "$(act "$S")" "$(wid "$S" services)"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A3 restore rc 0" "$rc" 0
assert_contains "A3 rule: prior closed" "$out" "rule=prior-closed select=$new"
assert_eq "A3 S is on the orchestrator" "$(act "$S")" "$new"

# A4 NO capture -> nothing. The operator is on services; leave them.
board_up || th_abort "board"
sel "$S" services; kill_orch "$S"; rm -f "$CAP"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A4 no capture: rc 1" "$rc" 1
assert_eq "A4 no capture: selection untouched" "$(act "$S")" "$(wid "$S" services)"

# A5 deliberate navigation: tmux put S on X after the kill; the operator moved
# to Y != X while X still exists -> kept on Y.
board_up || th_abort "board"
sel "$S" worker; sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
assert_eq "A5 CONTROL: tmux chose worker" "$(act "$S")" "$(wid "$S" worker)"
sel "$S" services
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A5 restore rc 0" "$rc" 0
assert_contains "A5 rule: deliberate navigation, kept" "$out" "rule=deliberate-navigation active=$(wid "$S" services) post-kill=$(wid "$S" worker) select=kept"
assert_eq "A5 S stays on services" "$(act "$S")" "$(wid "$S" services)"

# A6 stale capture -> nothing done, file consumed.
board_up || th_abort "board"
sel "$S" worker; sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"
sed -i 's/^ts=.*/ts=1000/' "$CAP"
kill_orch "$S"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A6 stale: rc 3" "$rc" 3
assert_contains "A6 stale: named as such with the bound" "$out" "capture=stale-or-unreadable ts=1000"
assert_contains "A6 stale: bound is 1800 s by default" "$out" "bound=1800s"
assert_eq "A6 stale: selection left where tmux put it" "$(act "$S")" "$(wid "$S" worker)"
assert_no_file "A6 stale: file consumed" "$CAP"
# ...and the bound is a knob.
board_up || th_abort "board"
sel "$S" orchestrator; tmux_selection_capture orchestrator "$CAP"
sed -i "s/^ts=.*/ts=$(( $(date +%s) - 120 ))/" "$CAP"
kill_orch "$S"; new=$(newwin "$S" orchestrator)
out=$(TMUX_SELECTION_STALE_SECONDS=60 tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A6b a 120 s old capture under a 60 s bound is stale" "$rc" 3
assert_contains "A6b the override is reported" "$out" "bound=60s"

# A7 consumed exactly once.
board_up || th_abort "board"
sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
new=$(newwin "$S" orchestrator)
tmux_selection_restore "$new" "$CAP" >/dev/null; rc=$?
assert_rc "A7 first restore rc 0" "$rc" 0
assert_no_file "A7 the capture file is gone after the restore" "$CAP"
sel "$S" services
tmux_selection_restore "$new" "$CAP" >/dev/null; rc=$?
assert_rc "A7 a second restore finds no capture (rc 1)" "$rc" 1
assert_eq "A7 ...and moves nothing" "$(act "$S")" "$(wid "$S" services)"

# A8 two-phase capture. (a) the operator sits on a STALE WATCHDOG window that
# the verb kills before its own spawn: the first capture records it, the kill
# moves the selection, the pre-kill refresh KEEPS the closed prior -> rule 3.
# `last` is set to services first, so tmux's choice after the watchdog kill is
# services and NOT the orchestrator — otherwise the final assertion could pass
# by coincidence of the board layout (a refresh-ignoring mutant survived it).
board_up || th_abort "board"
wd=$(newwin "$S" cc-restart-watchdog); sel "$S" services; sel "$S" cc-restart-watchdog
tmux_selection_capture orchestrator "$CAP"
assert_contains "A8a first capture: prior is the watchdog window" "$(cat "$CAP")" "prior|$(tmux display-message -p -t "$S:" '#{session_id}')|$wd|0"
tmux kill-window -t "$S:$wd"
moved=$(act "$S")
assert_eq "A8a CONTROL: tmux's choice after the watchdog kill is services, not the orchestrator" "$moved" "$(wid "$S" services)"
tmux_selection_capture --refresh orchestrator "$CAP"; rc=$?
assert_rc "A8a refresh rc 0" "$rc" 0
assert_contains "A8a refresh KEEPS the closed prior" "$(cat "$CAP")" "|$wd|0"
kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore "$new" "$CAP")
assert_contains "A8a restore: prior closed -> orchestrator" "$out" "rule=prior-closed select=$new"
assert_eq "A8a S on the orchestrator, not on tmux's choice ($moved)" "$(act "$S")" "$new"
# (b) the operator NAVIGATES during the arm-wait: the refresh takes their new
# position, not the first capture's.
board_up || th_abort "board"
sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"
assert_contains "A8b first capture says prior WAS the target" "$(cat "$CAP")" "|$(wid "$S" orchestrator)|1"
sel "$S" services
tmux_selection_capture --refresh orchestrator "$CAP"
assert_contains "A8b refresh: prior is now services, not the target" "$(cat "$CAP")" "|$(wid "$S" services)|0"
assert_not_contains "A8b refresh: the superseded prior is gone" "$(cat "$CAP")" "|1"
kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
new=$(newwin "$S" orchestrator)
tmux_selection_restore "$new" "$CAP" >/dev/null
assert_eq "A8b S stays on services (their choice during the wait)" "$(act "$S")" "$(wid "$S" services)"
# (c) a FRESH capture (no --refresh) ignores an existing file entirely.
board_up || th_abort "board"
sel "$S" worker; tmux_selection_capture orchestrator "$CAP"
sel "$S" orchestrator; tmux_selection_capture orchestrator "$CAP"
assert_contains "A8c fresh capture overwrote the earlier prior" "$(cat "$CAP")" "|$(wid "$S" orchestrator)|1"
assert_not_contains "A8c ...and kept nothing of it" "$(cat "$CAP")" "|$(wid "$S" worker)|"

# A9 grouped sessions: the same windows, TWO active windows. S on the
# orchestrator, G on services -> S restored to the new orchestrator, G left.
board_up grouped || th_abort "board"
sel "$S" worker; sel "$S" orchestrator; sel "$G" services
sid_s=$(tmux display-message -p -t "$S:" '#{session_id}'); sid_g=$(tmux display-message -p -t "$G:" '#{session_id}')
assert_eq "A9 CONTROL: grouped" "$(tmux display-message -p -t "$G:" '#{session_grouped}')" 1
tmux_selection_capture orchestrator "$CAP"
assert_contains "A9 capture: S prior was the target" "$(cat "$CAP")" "prior|$sid_s|$(wid "$S" orchestrator)|1"
assert_contains "A9 capture: G prior was services" "$(cat "$CAP")" "prior|$sid_g|$(wid "$S" services)|0"
kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
assert_eq "A9 CONTROL: the kill moved S" "$(act "$S")" "$(wid "$S" worker)"
assert_eq "A9 CONTROL: the kill did NOT move G" "$(act "$G")" "$(wid "$S" services)"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A9 restore rc 0" "$rc" 0
assert_eq "A9 S on the new orchestrator" "$(act "$S")" "$new"
assert_eq "A9 G still on services" "$(act "$G")" "$(wid "$S" services)"
assert_contains "A9 both sessions reported" "$out" "session=$sid_g rule=prior-still-present"
# ...and BOTH on the orchestrator: both restored, each by its own session id.
board_up grouped || th_abort "board"
sel "$S" worker; sel "$S" orchestrator; sel "$G" services; sel "$G" orchestrator
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
new=$(newwin "$S" orchestrator)
tmux_selection_restore "$new" "$CAP" >/dev/null
assert_eq "A9b S restored" "$(act "$S")" "$new"
assert_eq "A9b G restored" "$(act "$G")" "$new"

# A10 tmux would not answer.
board_up || th_abort "board"
sel "$S" orchestrator
TMUX_WINDOW_TMUX_CMD=/bin/false tmux_selection_capture orchestrator "$CAP"; rc=$?
assert_rc "A10 capture with a dead tmux: rc 3" "$rc" 3
assert_no_file "A10 ...writes nothing" "$CAP"
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
new=$(newwin "$S" orchestrator); before=$(act "$S")
out=$(TMUX_WINDOW_TMUX_CMD=/bin/false tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A10 restore with a dead tmux: rc 3" "$rc" 3
assert_contains "A10 ...says so" "$out" "tmux=would-not-answer"
assert_eq "A10 ...moves nothing" "$(act "$S")" "$before"
assert_no_file "A10 ...and consumes the file" "$CAP"
# A stub that answers in a shape this helper cannot parse (names only, as the
# cc-update fixture's tmux does) is a non-answer, not a capture.
printf '#!/usr/bin/env bash\nprintf "orchestrator\\nservices\\n"\n' > "$WORK/namesonly"; chmod +x "$WORK/namesonly"
TMUX_WINDOW_TMUX_CMD="$WORK/namesonly" tmux_selection_capture orchestrator "$CAP"; rc=$?
assert_rc "A10b unparseable rows: rc 3" "$rc" 3
assert_no_file "A10b ...nothing written" "$CAP"
# Garbage in the file: unreadable, consumed, nothing moved.
printf 'not a capture\n' > "$CAP"
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A10c garbage capture: rc 3" "$rc" 3
assert_no_file "A10c ...consumed" "$CAP"

# A11 the #1524 hazard. A prefix sibling `orchestrator-sk` AND a same-named
# stale window are present; the operator was on the target.
board_up || th_abort "board"
newwin "$S" orchestrator-sk >/dev/null
sel "$S" services; sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
stale=$(newwin "$S" orchestrator)     # a same-named impostor, created first
new=$(newwin "$S" orchestrator)       # the window the respawn owns
# The measured shape of the hazard, as CONTROLS: by NAME, a duplicate FAILS
# and an absent exact name lands on the SIBLING.
tmux select-window -t "$S:orchestrator" >/dev/null 2>&1; rc=$?
assert_rc "A11 CONTROL: select-window by NAME with a duplicate present fails (rc 1)" "$rc" 1
out=$(tmux_selection_restore "$new" "$CAP"); rc=$?
assert_rc "A11 restore rc 0" "$rc" 0
assert_eq "A11 by @id: S is on the window the respawn OWNS, not the impostor" "$(act "$S")" "$new"
[[ "$(act "$S")" != "$stale" ]] && [[ "$(act "$S")" != "$(wid "$S" orchestrator-sk)" ]]; rc=$?
assert_rc "A11 ...and on neither the impostor nor the prefix sibling" "$rc" 0
tmux kill-window -t "$S:$stale"; tmux kill-window -t "$S:$new"
tmux select-window -t "$S:orchestrator" >/dev/null 2>&1
assert_eq "A11 CONTROL: with the exact name ABSENT, by-name lands on the prefix sibling (#1524)" "$(act "$S")" "$(wid "$S" orchestrator-sk)"

echo "== B: through _respawn_spawn_window (the production creation site) =="

FAKE_NEXUS="$WORK/nexus"; mkdir -p "$FAKE_NEXUS/monitor/.state"
LAUNCHER="$WORK/launcher.sh"; printf '#!/usr/bin/env bash\nexec sleep 600\n' > "$LAUNCHER"; chmod +x "$LAUNCHER"
export NEXUS_STATE_DIR="$STATE"
# shellcheck source=_respawn.sh
. "$RESPAWN"
declare -F _respawn_spawn_window >/dev/null || th_abort "_respawn_spawn_window not defined after sourcing $RESPAWN"

now_ms() { date +%s%N | cut -c1-13; }
spawn() {   # spawn <force> -> RC, ERR (file), MS
    local t0 t1
    : > "$WORK/spawn.err"
    t0=$(now_ms)
    _respawn_spawn_window orchestrator "$FAKE_NEXUS" "$LAUNCHER" "$1" 2>"$WORK/spawn.err"; RC=$?
    t1=$(now_ms); MS=$(( t1 - t0 ))
}

# B1 crash / version / force-replace path: the target is PRESENT (here a live
# `sleep`; in production a dead pane held by remain-on-exit), S is on it.
board_up || th_abort "board"
sel "$S" worker; sel "$S" orchestrator; old=$(wid "$S" orchestrator)
spawn 1; MS_B1=$MS
assert_rc "B1 respawn rc 0" "$RC" 0
new=$(wid "$S" orchestrator)
[[ -n "$new" && "$new" != "$old" ]]; rc=$?
assert_rc "B1 a NEW orchestrator window exists" "$rc" 0
assert_eq "B1 S is on the new orchestrator window" "$(act "$S")" "$new"
assert_contains "B1 the watcher log names the rule" "$(cat "$WORK/spawn.err")" "rule=prior-was-target select=$new"
assert_no_file "B1 the capture was consumed" "$CAP"
# ...and rule 2 through the same site: on services, stays on services.
board_up || th_abort "board"
sel "$S" services
spawn 1
assert_rc "B1b respawn rc 0" "$RC" 0
assert_eq "B1b S still on services" "$(act "$S")" "$(wid "$S" services)"

# B2 the cc-update path: the KILLER captured and killed; the respawn finds the
# target absent and consumes the capture.
board_up || th_abort "board"
sel "$S" worker; sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"
tmux_selection_capture --refresh orchestrator "$CAP"
kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
assert_eq "B2 CONTROL: S on tmux's choice (worker) before the respawn" "$(act "$S")" "$(wid "$S" worker)"
spawn 1
assert_rc "B2 respawn rc 0" "$RC" 0
new=$(wid "$S" orchestrator)
assert_eq "B2 S is on the new orchestrator window" "$(act "$S")" "$new"
assert_contains "B2 log line" "$(cat "$WORK/spawn.err")" "rule=prior-was-target"
# ...with the operator having navigated in the gap: left alone.
board_up || th_abort "board"
sel "$S" worker; sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
sel "$S" services
spawn 1
assert_rc "B2b respawn rc 0" "$RC" 0
assert_eq "B2b S stays on services" "$(act "$S")" "$(wid "$S" services)"
assert_contains "B2b log names the veto" "$(cat "$WORK/spawn.err")" "rule=deliberate-navigation"

# B3 RESTORE FORCED TO FAIL IS INERT. Three forcings, all rc 0, all create the
# window; the first is timed against B1.
board_up || th_abort "board"
sel "$S" worker; sel "$S" orchestrator
tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
TMUX_WINDOW_TMUX_CMD=/bin/false spawn 1; MS_B3=$MS
assert_rc "B3 restore's tmux dead: respawn rc 0" "$RC" 0
assert_eq "B3 ...window created" "$(tmux list-windows -t "$S:" -F '#{window_name}' | grep -cx orchestrator)" 1
assert_eq "B3 ...selection left where tmux put it (worker)" "$(act "$S")" "$(wid "$S" worker)"
assert_contains "B3 ...and the failure is logged, not hidden" "$(cat "$WORK/spawn.err")" "rc 3): capture=present tmux=would-not-answer"
assert_no_file "B3 ...file consumed" "$CAP"
printf 'B3 timing: B1 (restore applied) %s ms, B3 (restore failed) %s ms\n' "$MS_B1" "$MS_B3"
# The spawn is one tmux round trip plus a fork; the restore adds one
# list-windows and one select-window. Anything within a second of each other
# is noise on this host; a material delay would be an order of magnitude.
(( MS_B3 - MS_B1 < 1000 && MS_B1 - MS_B3 < 1000 )); rc=$?
assert_rc "B3 wall time within 1 s of B1 (${MS_B1} vs ${MS_B3} ms)" "$rc" 0
# Garbage capture.
board_up || th_abort "board"
sel "$S" services; kill_orch "$S"; printf 'garbage\n' > "$CAP"
spawn 1
assert_rc "B3b garbage capture: respawn rc 0" "$RC" 0
# An unreadable capture is no capture: rule 4 applies (operator decision on
# #1528), and with no snapshot either, the orchestrator is the default.
assert_eq "B3b ...unreadable capture + no snapshot: the default, the orchestrator" "$(act "$S")" "$(wid "$S" orchestrator)"
assert_contains "B3b ...logged as the default" "$(cat "$WORK/spawn.err")" "rule=no-snapshot default=orchestrator"
assert_no_file "B3b ...consumed" "$CAP"
# Capture naming a session that no longer exists.
board_up || th_abort "board"
sel "$S" services; kill_orch "$S"
printf 'v=1\nts=%s\ntarget=orchestrator\nprior|$999|@0|1\n' "$(date +%s)" > "$CAP"
spawn 1
assert_rc "B3c capture for a vanished session: respawn rc 0" "$RC" 0
assert_contains "B3c ...logged as session-gone" "$(cat "$WORK/spawn.err")" "session=\$999 rule=session-gone select=skipped"
assert_eq "B3c ...selection untouched" "$(act "$S")" "$(wid "$S" services)"
# The capture's state dir missing: capture cannot write, kill proceeds, rc 0.
board_up || th_abort "board"
sel "$S" orchestrator
NEXUS_STATE_DIR="$WORK/does-not-exist" spawn 1
assert_rc "B3d unwritable state dir: respawn rc 0" "$RC" 0
assert_eq "B3d ...a new window exists" "$(tmux list-windows -t "$S:" -F '#{window_name}' | grep -cx orchestrator)" 1

# B4 the rc 3 contract is untouched: a tmux whose new-window fails.
mkdir -p "$WORK/bin-nonew"
cat > "$WORK/bin-nonew/tmux" <<SH
#!/usr/bin/env bash
[[ "\$1" == new-window ]] && exit 1
exec "$WORK/bin/tmux" "\$@"
SH
chmod +x "$WORK/bin-nonew/tmux"
board_up || th_abort "board"
sel "$S" orchestrator
PATH="$WORK/bin-nonew:$PATH" _respawn_spawn_window orchestrator "$FAKE_NEXUS" "$LAUNCHER" 1 2>/dev/null; rc=$?
assert_rc "B4 new-window failed: rc 3, as before" "$rc" 3

echo "== D: rule 4 — the snapshot arm (no kill-time capture) =="

SNAP=$(tmux_selection_snapshot_file "$STATE")
sid_of() { tmux display-message -p -t "$1:" '#{session_id}'; }
# vanish: the window goes without a capture (external kill / no remain-on-exit)
vanish_orch() { rm -f "$CAP"; kill_orch "$1"; }

# D1 orchestrator ACTIVE when it vanished -> new orchestrator.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; sel "$S" orchestrator
tmux_selection_snapshot orchestrator "$SNAP"; rc=$?
assert_rc "D1 snapshot rc 0" "$rc" 0
assert_contains "D1 snapshot says the orchestrator was active" "$(cat "$SNAP")" "prior|$(sid_of "$S")|$(wid "$S" orchestrator)|1"
vanish_orch "$S"
assert_eq "D1 CONTROL: tmux moved S to worker" "$(act "$S")" "$(wid "$S" worker)"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore_fallback "$new" "$SNAP"); rc=$?
assert_rc "D1 fallback rc 0" "$rc" 0
assert_contains "D1 rule named" "$out" "rule=snapshot-active-was-target select=$new"
assert_eq "D1 S is on the new orchestrator" "$(act "$S")" "$new"

# D2 operator on a LIVE worker -> left alone (the death moved nobody).
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker
tmux_selection_snapshot orchestrator "$SNAP"
vanish_orch "$S"
assert_eq "D2 CONTROL: killing a non-active window moved nothing" "$(act "$S")" "$(wid "$S" worker)"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore_fallback "$new" "$SNAP"); rc=$?
assert_rc "D2 fallback rc 0" "$rc" 0
assert_contains "D2 rule: still present, kept" "$out" "rule=snapshot-active-still-present active=$(wid "$S" worker) select=kept"
assert_eq "D2 S stays on the worker" "$(act "$S")" "$(wid "$S" worker)"

# D3 NO snapshot -> the orchestrator, the operator's literal default — even
# though they were on a worker (nothing says whether the death moved them).
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; vanish_orch "$S"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore_fallback "$new" "$SNAP"); rc=$?
assert_rc "D3 fallback rc 0" "$rc" 0
assert_contains "D3 rule: no snapshot, default" "$out" "rule=no-snapshot default=orchestrator select=$new"
assert_eq "D3 S is on the orchestrator" "$(act "$S")" "$new"

# D4 STALE snapshot -> the orchestrator, with the age and bound named.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; tmux_selection_snapshot orchestrator "$SNAP"
sed -i "s/^ts=.*/ts=$(( $(date +%s) - 300 ))/" "$SNAP"
vanish_orch "$S"; new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore_fallback "$new" "$SNAP"); rc=$?
assert_rc "D4 fallback rc 0" "$rc" 0
assert_contains "D4 rule: stale, default" "$out" "rule=snapshot-stale age="
assert_contains "D4 ...bound is 120 s by default" "$out" "bound=120s default=orchestrator"
assert_eq "D4 S is on the orchestrator" "$(act "$S")" "$new"
# ...and a 300 s old snapshot under a 600 s bound is FRESH: the knob works.
sel "$S" worker
out=$(TMUX_SELECTION_SNAPSHOT_STALE_SECONDS=600 tmux_selection_restore_fallback "$new" "$SNAP")
assert_contains "D4b under a 600 s bound the same snapshot is read (worker still present, kept)" "$out" "rule=snapshot-active-still-present"
assert_eq "D4b ...and S stays on the worker" "$(act "$S")" "$(wid "$S" worker)"

# D5 the snapshot's active window has CLOSED -> the orchestrator.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; tmux_selection_snapshot orchestrator "$SNAP"; gone=$(wid "$S" worker)
vanish_orch "$S"; tmux kill-window -t "$S:$gone"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore_fallback "$new" "$SNAP"); rc=$?
assert_rc "D5 fallback rc 0" "$rc" 0
assert_contains "D5 rule: snapshot's window closed" "$out" "rule=snapshot-active-closed ($gone) select=$new"
assert_eq "D5 S is on the orchestrator" "$(act "$S")" "$new"

# D6 the writer KEEPS the last snapshot that saw the target: the watcher keeps
# ticking after the window vanishes, and a post-vanish write would describe
# the board tmux already moved. Measured shape before this rule: the real
# watcher's respawn read a snapshot with no row for its session.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; sel "$S" orchestrator; tmux_selection_snapshot orchestrator "$SNAP"
before=$(grep '^prior' "$SNAP")
vanish_orch "$S"
tmux_selection_snapshot orchestrator "$SNAP"; rc=$?
assert_rc "D6 writer with the target absent: rc 1" "$rc" 1
assert_eq "D6 ...and the pre-vanish snapshot stands" "$(grep '^prior' "$SNAP")" "$before"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore_fallback "$new" "$SNAP")
assert_contains "D6 ...so the arm still knows the orchestrator was active" "$out" "rule=snapshot-active-was-target"
assert_eq "D6 S on the new orchestrator" "$(act "$S")" "$new"
# ...and with NO pre-vanish snapshot, a post-vanish fire writes nothing.
board_up || th_abort "board"; rm -f "$SNAP"; vanish_orch "$S"
tmux_selection_snapshot orchestrator "$SNAP"
assert_no_file "D6b no pre-vanish snapshot, target absent: nothing written" "$SNAP"

# D7 grouped: S on the orchestrator, G on services -> S restored, G kept.
board_up grouped || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; sel "$S" orchestrator; sel "$G" services
tmux_selection_snapshot orchestrator "$SNAP"; vanish_orch "$S"
new=$(newwin "$S" orchestrator)
out=$(tmux_selection_restore_fallback "$new" "$SNAP"); rc=$?
assert_rc "D7 fallback rc 0" "$rc" 0
assert_eq "D7 S on the new orchestrator" "$(act "$S")" "$new"
assert_eq "D7 G still on services" "$(act "$G")" "$(wid "$S" services)"
assert_contains "D7 G reported kept" "$out" "session=$(sid_of "$G") rule=snapshot-active-still-present"

# D8 the snapshot is the watcher's rolling file: NOT consumed.
assert_file_exists "D8 snapshot still present after the fallback" "$SNAP"

# D9 dead tmux: inert.
board_up || th_abort "board"
sel "$S" worker; tmux_selection_snapshot orchestrator "$SNAP"; vanish_orch "$S"; new=$(newwin "$S" orchestrator)
out=$(TMUX_WINDOW_TMUX_CMD=/bin/false tmux_selection_restore_fallback "$new" "$SNAP"); rc=$?
assert_rc "D9 fallback with a dead tmux: rc 3" "$rc" 3
assert_eq "D9 ...moves nothing" "$(act "$S")" "$(wid "$S" worker)"
TMUX_WINDOW_TMUX_CMD=/bin/false tmux_selection_snapshot orchestrator "$SNAP"; rc=$?
assert_rc "D9b the writer with a dead tmux: rc 3" "$rc" 3
assert_no_file "D9b ...and removes the previous snapshot rather than let it age" "$SNAP"

echo "== D through _respawn_spawn_window (target ABSENT, no capture) =="
# D1r orchestrator active when it vanished.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; sel "$S" orchestrator; tmux_selection_snapshot orchestrator "$SNAP"; vanish_orch "$S"
spawn 1
assert_rc "D1r respawn rc 0" "$RC" 0
new=$(wid "$S" orchestrator)
assert_eq "D1r S is on the new orchestrator" "$(act "$S")" "$new"
assert_contains "D1r log names the snapshot arm" "$(cat "$WORK/spawn.err")" "no capture; snapshot arm rc 0): session=$(sid_of "$S") rule=snapshot-active-was-target select=$new"
# D2r on a live worker.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; tmux_selection_snapshot orchestrator "$SNAP"; vanish_orch "$S"
spawn 1
assert_rc "D2r respawn rc 0" "$RC" 0
assert_eq "D2r S stays on the worker" "$(act "$S")" "$(wid "$S" worker)"
assert_contains "D2r log: kept" "$(cat "$WORK/spawn.err")" "rule=snapshot-active-still-present"
# D3r no snapshot: the default.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; vanish_orch "$S"
spawn 1
assert_rc "D3r respawn rc 0" "$RC" 0
assert_eq "D3r S is on the orchestrator" "$(act "$S")" "$(wid "$S" orchestrator)"
assert_contains "D3r log: no snapshot, default" "$(cat "$WORK/spawn.err")" "rule=no-snapshot default=orchestrator"
# D6r precedence: a kill-time capture (operator on services) beats a snapshot
# claiming the orchestrator was active.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" orchestrator; tmux_selection_snapshot orchestrator "$SNAP"
sel "$S" services; tmux_selection_capture orchestrator "$CAP"; kill_orch "$S"; tmux_selection_note_post_kill "$CAP"
spawn 1
assert_rc "D6r respawn rc 0" "$RC" 0
assert_eq "D6r the capture won: S stays on services" "$(act "$S")" "$(wid "$S" services)"
assert_not_contains "D6r the snapshot arm did not run" "$(cat "$WORK/spawn.err")" "snapshot arm"
# D3r-inert: the snapshot arm's tmux dead -> respawn rc 0, window created.
board_up || th_abort "board"; rm -f "$SNAP"
sel "$S" worker; vanish_orch "$S"
TMUX_WINDOW_TMUX_CMD=/bin/false spawn 1
assert_rc "D9r snapshot arm's tmux dead: respawn rc 0" "$RC" 0
assert_eq "D9r ...window created" "$(tmux list-windows -t "$S:" -F '#{window_name}' | grep -cx orchestrator)" 1
assert_contains "D9r ...and logged" "$(cat "$WORK/spawn.err")" "snapshot arm rc 3): snapshot-arm tmux=would-not-answer"

echo "== E: the watcher registers the snapshot writer (source read) =="
MAIN_SH="$_test_dir/main.sh"
assert_eq "E1 main.sh registers selection_snapshot as a cheap sync task at 10 s" \
    "$(grep -cE '^_schedule_task selection_snapshot +10 +_v2_task_selection_snapshot +--class cheap$' "$MAIN_SH")" 1
assert_eq "E2 the task body calls tmux_selection_snapshot on the state dir's snapshot file" \
    "$(awk '/^_v2_task_selection_snapshot\(\)/,/^}/' "$MAIN_SH" | grep -c 'tmux_selection_snapshot "\$TARGET" "\$(tmux_selection_snapshot_file "\$STATE_DIR")"')" 1
assert_eq "E3 main.sh sources the helper that defines it" "$(grep -c 'source "\$_script_dir/../_tmux-window.sh"' "$MAIN_SH")" 1

echo "== C: the cc-update verb's call ORDER (source read) =="
n_cap=$(grep -n 'tmux_selection_capture "\$TARGET_WINDOW" "\$_SEL_CAPTURE_FILE"' "$CCAPPLY" | head -n1 | cut -d: -f1)
n_wdkill=$(grep -n 'kill-window -t "\$WATCHDOG_WINDOW"' "$CCAPPLY" | head -n1 | cut -d: -f1)
n_refresh=$(grep -n 'tmux_selection_capture --refresh "\$TARGET_WINDOW" "\$_SEL_CAPTURE_FILE"' "$CCAPPLY" | head -n1 | cut -d: -f1)
n_kill=$(grep -n '"\$TMUX_CMD" kill-window -t "\$TARGET_WINDOW" 9>&-' "$CCAPPLY" | head -n1 | cut -d: -f1)
n_post=$(grep -n 'tmux_selection_note_post_kill "\$_SEL_CAPTURE_FILE"' "$CCAPPLY" | head -n1 | cut -d: -f1)
for v in n_cap n_wdkill n_refresh n_kill n_post; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { printf '  FAIL: C site %s not found in %s\n' "$v" "$CCAPPLY" >&2; _th_fail; }
done
if [[ "$n_cap$n_wdkill$n_refresh$n_kill$n_post" =~ ^[0-9]+$ ]]; then
    (( n_cap < n_wdkill && n_wdkill < n_refresh && n_refresh < n_kill && n_kill < n_post )); rc=$?
    assert_rc "C1 order: capture($n_cap) < stale-watchdog kill($n_wdkill) < refresh($n_refresh) < orchestrator kill($n_kill) < post-kill note($n_post)" "$rc" 0
fi
# A capture belongs to a kill (w240sk F1). The kill line sets the flag, the
# EXIT trap drops the capture whenever the flag is unset — one drop for the
# per-exit aborts, the TERM trap's exit 25 and a `set -u` death alike — and no
# per-exit `rm` list remains to be kept complete by hand.
assert_eq "C2 the kill line is followed by the reached-flag" \
    "$(sed -n "$((n_kill+1))p" "$CCAPPLY" | grep -c '^    _SEL_KILL_REACHED=1')" 1
assert_eq "C2 the EXIT trap drops the capture when the kill was not reached" \
    "$(awk '/^    _restart_outcome_on_exit\(\)/,/^    }/' "$CCAPPLY" | grep -c 'if (( _SEL_KILL_REACHED == 0 )) && \[\[ -n "\$_SEL_CAPTURE_FILE" \]\]; then')" 1
assert_eq "C2 ...and that is the ONLY drop (no per-exit rm list)" "$(grep -c 'rm -f "\$_SEL_CAPTURE_FILE"' "$CCAPPLY")" 1
assert_eq "C2 both bookkeeping globals are initialised at file scope (set -u safe in the trap)" \
    "$(grep -cE '^_SEL_(CAPTURE_FILE=""|KILL_REACHED=0)$' "$CCAPPLY")" 2
# The capture calls go through the verb's tmux seam and close the lock fd.
assert_eq "C3 all three helper calls carry the CC_AUTO_TMUX seam and 9>&-" \
    "$(grep -cE 'TMUX_WINDOW_TMUX_CMD="\$TMUX_CMD" tmux_selection_(capture|note_post_kill) .*9>&- \|\| true$' "$CCAPPLY")" 3

# ---- assertion-count guard (count=exact, summary-honesty) -------------------
# The ledger certifies that SOMETHING was asserted; only an exact count makes a
# VANISHED assertion redden. ONE physical line, as the classifier requires.
EXPECTED_ASSERTIONS=160
TOTAL_ASSERTIONS=$(( ${PASS:-0} + ${FAIL:-0} ))
assert_eq "assertion TOTAL matches EXPECTED_ASSERTIONS — no assertion silently dropped or added" "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
