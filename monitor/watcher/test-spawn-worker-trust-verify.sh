#!/usr/bin/env bash
# test-spawn-worker-trust-verify.sh — your-org/nexus-code#1334: after the
# launcher is sent, spawn-worker.sh must CONFIRM the worker did not land on
# Claude Code's workspace-trust dialog and, if it did, RECOVER — bounded,
# loud, and only ever on the exact `state=blocked overlay=workspace-trust`
# pair, with "no work was lost" asserted before the kill.
#
# The seed (test-spawn-worker-trust-seed.sh) was measured NECESSARY AND NOT
# SUFFICIENT: 1 of 5 clones seeded by the same code path booted into the
# dialog anyway. This suite drives the RESPONSE:
#
#   ARM A  a fine pane: no kill, no re-seed, no delay past the first positive
#          state, and the launcher carries CLAUDE_CODE_SANDBOXED=1 (the
#          primary fix — the gate is skipped before the key is read).
#   ARM B  the pane sits on the trust dialog and a competing writer has
#          dropped the seeded key: detected, key-at-detection recorded as
#          ABSENT (the discriminating measurement #1334 prescribes), window
#          killed, key re-seeded and read back, window re-created under the
#          same name, launcher re-sent, worker reaches idle. Exit 0.
#   ARM C  the dialog persists with the key TRUE at every detection: bounded
#          at NEXUS_SPAWN_TRUST_MAX_RECOVER, exit 21, diagnostic says a
#          re-seed cannot help and names the key-path suspect. No `spawned:`.
#   ARM D  a DIFFERENT overlay: noted, never killed, exit 0.
#   ARM E  `empty` forever: UNVERIFIED after the budget, exit 0, no kill.
#   ARM F  NEXUS_SPAWN_TRUST_VERIFY_SECONDS=0: pane-state never consulted.
#   ARM G  THE KILL PRECONDITION: a transcript exists for the session id at
#          detection -> recovery REFUSED before any kill, exit 21.
#   ARM H  tmux cannot resolve the window key: UNVERIFIED quickly, exit 0.
#   ARM I  structural: both window-creation sites keep the launcher and call
#          the verifier; the kill is preceded by the precondition; the
#          exemption names bk_pane_kill_authorized; the kill allowlist in
#          _bookkeeping.sh still does not contain `blocked`.
#
# pane-state.sh and tmux are STUBS scripted per arm — the classifier itself is
# covered by test-pane-state.sh and the real-binary trust suites; what is under
# test here is spawn-worker.sh's response to what the classifier says.
#
# Run: bash monitor/watcher/test-spawn-worker-trust-verify.sh
# Every arm runs against an ISOLATED CLAUDE_CONFIG_DIR and a per-run TMPDIR —
# never the operator's ~/.claude.json, never /tmp's launcher files.
set -uo pipefail
unset NEXUS_WORKER_WINDOW
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"
# SPAWN_WORKER_UNDER_TEST lets a mutation control point this suite at a
# mutant copy without editing the suite (the prediction is made against the
# tree, the mutant is a copy). Default: the real script.
SPAWN_REAL="${SPAWN_WORKER_UNDER_TEST:-$_test_dir/../spawn-worker.sh}"
BK_REAL="$_test_dir/../_bookkeeping.sh"
EXPECTED_ASSERTIONS=87

command -v jq >/dev/null 2>&1 || { echo "test: jq required" >&2; exit 2; }
[ -r "$SPAWN_REAL" ] || { echo "test: not readable: $SPAWN_REAL" >&2; exit 2; }

# ---- fixture ------------------------------------------------------------
WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
FAKE_NEXUS="$WORK/nexus"
NESTED="$FAKE_NEXUS/work/proj"
TMPD="$WORK/tmp"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports" "$FAKE_NEXUS/config" "$NESTED" "$TMPD"
git -C "$FAKE_NEXUS" init -q 2>/dev/null
git -C "$NESTED" init -q 2>/dev/null
# `_nexus-root.sh` and `_action-log.sh`-family helpers: `ng log-action` refuses
# to run without its primary-root resolver, and the ACTION-LOG assertions
# below are the point of arms B/C/E/G — a fixture where `ng` fails silently
# would make them vacuous, so `ng` must actually work here.
for f in ensure-workdir-trusted.sh _claude-bin.sh _tmux-window.sh _fm_lib.sh _nexus-root.sh \
         assert-shims-wrapped.sh assert-gh-wrapped.sh ng _bookkeeping.sh; do
    [[ -f "$_test_dir/../$f" ]] && cp "$_test_dir/../$f" "$FAKE_NEXUS/monitor/$f"
done
# The guard template is installed on its OWN line, by name: the closure-boundary
# ratchet (test-guard-closure-boundary.sh, "every fixture installing
# spawn-worker.sh installs the template") keys on a `cp … guard-block.sh.in`
# in command position, and a loop variable is a route it cannot see -- it
# reports a fixture like this one as MISSING the template, a false red that is
# loud rather than silent, which is the predicate's stated trade.
cp "$_test_dir/../guard-block.sh.in" "$FAKE_NEXUS/monitor/guard-block.sh.in"
cp "$SPAWN_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
chmod +x "$FAKE_NEXUS/monitor/"*.sh "$FAKE_NEXUS/monitor/ng" 2>/dev/null
printf '{}' > "$FAKE_NEXUS/monitor/worker-settings.json"
cat > "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
---
description: stub
---

# nexus.worker-defaults

## Worker floor

- FLOOR_TOKEN
EOF
cat > "$FAKE_NEXUS/config/load.sh" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    github.repo)        printf 'org/repo' ;;
    github.user_login)  printf 'test-user' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$FAKE_NEXUS/config/load.sh"
PROMPT_FILE="$WORK/task.txt"; echo "test prompt" > "$PROMPT_FILE"

STUB_BIN="$WORK/stub-bin"; mkdir -p "$STUB_BIN"
export TMUX_LOG="$WORK/tmux.log" TMUX_WIN="$WORK/tmux.win"
export PS_SCRIPT="$WORK/ps.script" PS_CURSOR="$WORK/ps.cursor" PS_LOG="$WORK/ps.log"
CFG_DIR="$WORK/claude-cfg"; mkdir -p "$CFG_DIR"; CFG="$CFG_DIR/.claude.json"
export CFG_FOR_STUBS="$CFG" CFG_DIR_FOR_STUBS="$CFG_DIR"

# tmux stub: records every verb; hands out window ids; answers the key
# resolution; can PLANT a transcript for the launcher's --session-id when
# TMUX_PLANT_TRANSCRIPT=1 (arm G — "something ran in that pane").
cat > "$STUB_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_LOG"
case "$1" in
    new-window)
        n=$(cat "$TMUX_WIN" 2>/dev/null || echo 9); echo "@$n"; echo $((n+1)) > "$TMUX_WIN"; exit 0 ;;
    display-message)
        [ "${TMUX_NOKEY:-0}" = 1 ] && exit 1
        echo "0:7"; exit 0 ;;
    send-keys)
        if [ "${TMUX_PLANT_TRANSCRIPT:-0}" = 1 ]; then
            l="$4"
            # A bash regex over `read`, not `sed`: the gate-3 shim scanner
            # (_tmux_shim_scan.awk) proves a mock SAFE only from an allowlist of
            # words that cannot execute a program, and `sed` is excluded (GNU
            # `e`/`s///e`). With sed here the whole shim fell to default-deny
            # UNSAFE (your-org/nexus-code#1105) on a body that never runs tmux.
            sid=""
            while IFS= read -r line || [ -n "$line" ]; do
                if [[ "$line" =~ --session-id\ ([0-9a-f-]+) ]]; then sid="${BASH_REMATCH[1]}"; fi
            done < "$l"
            if [ -n "$sid" ]; then mkdir -p "$CFG_DIR_FOR_STUBS/projects/x"; : > "$CFG_DIR_FOR_STUBS/projects/x/$sid.jsonl"; fi
        fi
        # loop-wrapper arm: SOME transcript, any slug, newer than the pre-send stamp
        if [ "${TMUX_PLANT_ANY:-0}" = 1 ]; then
            sleep 1; mkdir -p "$CFG_DIR_FOR_STUBS/projects/unrelated-slug"; : > "$CFG_DIR_FOR_STUBS/projects/unrelated-slug/zz.jsonl"
        fi
        # resume arm: the resumed transcript GROWS after the launcher was sent
        if [ -n "${TMUX_GROW_RESUME:-}" ]; then sleep 1; printf 'x\n' >> "$TMUX_GROW_RESUME"; fi
        exit 0 ;;
    *) exit 0 ;;
esac
TMUX_STUB
chmod +x "$STUB_BIN/tmux"
printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/claude"; chmod +x "$STUB_BIN/claude"

# pane-state stub: emits the scripted lines in order, then repeats the last;
# logs every call; on an overlay line runs $PS_ON_OVERLAY (arm B's competing
# writer, which drops the seeded key exactly when the dialog is "seen").
cat > "$FAKE_NEXUS/monitor/pane-state.sh" <<'PS_STUB'
#!/bin/bash
n=$(cat "$PS_CURSOR" 2>/dev/null || echo 0)
total=$(wc -l < "$PS_SCRIPT")
idx=$(( n < total ? n : total - 1 ))
line=$(sed -n "$((idx + 1))p" "$PS_SCRIPT")
echo $((n + 1)) > "$PS_CURSOR"
printf 'call=%s key=%s -> %s\n' "$n" "$1" "$line" >> "$PS_LOG"
case "$line" in
    *overlay=workspace-trust*) [ -n "${PS_ON_OVERLAY:-}" ] && eval "$PS_ON_OVERLAY" ;;
esac
printf '%s\n' "$line"
PS_STUB
chmod +x "$FAKE_NEXUS/monitor/pane-state.sh"

DROP_KEY="jq --arg d \"$NESTED\" 'del(.projects[\$d].hasTrustDialogAccepted)' \"$CFG_FOR_STUBS\" > \"$CFG_FOR_STUBS.t\" && mv \"$CFG_FOR_STUBS.t\" \"$CFG_FOR_STUBS\""

reset_arm() {   # $1 = scripted pane-state lines (newline-separated)
    printf '%s\n' "$1" > "$PS_SCRIPT"
    : > "$PS_CURSOR"; : > "$PS_LOG"; : > "$TMUX_LOG"; echo 9 > "$TMUX_WIN"
    rm -rf "$CFG_DIR/projects" "$TMPD"/* 2>/dev/null   # rm -rf on a symlink removes the LINK, not its target
    jq -n --arg p "$FAKE_NEXUS" '{theme:"dark", projects:{($p):{hasTrustDialogAccepted:true}}}' > "$CFG"
}
spawn() {   # $1 = window name; per-arm env via the `K=V spawn …` prefix form (a function, so not `env`)
    ( cd "$WORK" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
        NEXUS_ROOT="$FAKE_NEXUS" CLAUDE_CONFIG_DIR="$CFG_DIR" TMPDIR="$TMPD" \
        "$FAKE_NEXUS/monitor/spawn-worker.sh" -n "$1" -c "$NESTED" -p "$PROMPT_FILE" 2>&1 )
}
tmux_count() { grep -c "^$1" "$TMUX_LOG" 2>/dev/null || true; }
ps_calls()   { wc -l < "$PS_LOG" | tr -d ' '; }
key_now()    { jq -r --arg d "$NESTED" '.projects[$d].hasTrustDialogAccepted // "ABSENT"' "$CFG"; }
keeps_left() { find "$TMPD" -maxdepth 1 \( -name '*.keep' -o -name '*.stamp' \) | wc -l | tr -d ' '; }
# `n=$(…) || n=0`, not `grep -c … || echo 0`: `grep -c` already prints 0 on no
# match, so the `|| echo 0` form appends a SECOND value (count-fallback-lint,
# your-org/nexus-code#725). Counting LINES is the right unit here -- the action
# log is one JSON record per line.
elog()       { local f="$FAKE_NEXUS/monitor/.state/action-log.jsonl" n; n=$( [ -f "$f" ] && grep -c "\"event\":\"$1\"" "$f" 2>/dev/null ) || n=0; printf '%s\n' "${n:-0}"; }

# ---- ARM A: a fine pane -------------------------------------------------
echo '=== ARM A: a worker that boots fine is neither killed nor delayed ==='
reset_arm $'state=empty active=0\nstate=idle active=0'
t0=$(date +%s); out=$(spawn wA); rc=$?; el=$(( $(date +%s) - t0 ))
assert_eq "A: spawn exits 0" "$rc" "0"
assert_contains "A: the check reports the positive state it stopped on" "$out" "reached state=idle"
assert_contains "A: the spawned: line is printed" "$out" "spawned: window=wA"
assert_eq "A: no window was killed" "$(tmux_count kill-window)" "0"
assert_eq "A: exactly one window was created" "$(tmux_count new-window)" "1"
assert_eq "A: the launcher was sent once" "$(tmux_count send-keys)" "1"
assert_eq "A: pane-state consulted until the first positive state (2 calls)" "$(ps_calls)" "2"
assert_eq "A: no kept launcher/prompt/stamp files linger" "$(keeps_left)" "0"
[ "$el" -le 6 ] && _th_pass || { printf '  FAIL: A: the fine path took %ss (expected <= 6)\n' "$el" >&2; _th_fail; }
launcher=$(find "$TMPD" -maxdepth 1 -name 'spawn-launcher-wA.*.sh' -print -quit)
assert_file_exists "A: the generated launcher is on disk (the stub tmux never ran it)" "$launcher"
assert_eq "A: the launcher sets CLAUDE_CODE_SANDBOXED=1 on the claude invocation (primary fix)" \
    "$(grep -c 'CLAUDE_CODE_SANDBOXED=1 "' "$launcher")" "1"

# ---- ARM B: dialog + lost key -> detected, re-seeded, respawned ------------
echo '=== ARM B: the pane sits on the trust dialog with the key CLOBBERED -> recovered ==='
reset_arm $'state=empty active=0\nstate=blocked active=0 overlay=workspace-trust\nstate=empty active=0\nstate=idle active=0'
out=$(PS_ON_OVERLAY="$DROP_KEY" spawn wB); rc=$?
assert_eq "B: spawn exits 0 after recovery" "$rc" "0"
assert_contains "B: detection names the dialog" "$out" "landed on the WORKSPACE-TRUST dialog"
assert_contains "B: the key was read from disk BEFORE acting and was ABSENT" "$out" "trust-key-at-detection=ABSENT"
assert_contains "B: recovery is announced with its bound" "$out" "recovery 1 of 2"
assert_contains "B: the worker then reached a positive state" "$out" "reached state=idle"
assert_contains "B: …and the check says it took a recovery" "$out" "after 1 recover"
assert_contains "B: the spawned: line is still printed" "$out" "spawned: window=wB"
assert_eq "B: the dialog window was killed exactly once" "$(tmux_count kill-window)" "1"
assert_eq "B: a second window was created under the same name" "$(tmux_count 'new-window -P -F #{window_id} -d -n wB')" "2"
assert_eq "B: the launcher was re-sent" "$(tmux_count send-keys)" "2"
assert_eq "B: the window options were re-applied on the new window" "$(tmux_count 'set-window-option -t @10')" "3"
assert_eq "B: the key is TRUE again on disk (re-seeded and read back)" "$(key_now)" "true"
assert_eq "B: no kept launcher/prompt/stamp files linger" "$(keeps_left)" "0"
assert_eq "B: the detection reached the ACTION LOG (spawn-trust-overlay)" "$(elog spawn-trust-overlay)" "1"
assert_eq "B: the recovery reached the ACTION LOG (spawn-trust-recover)" "$(elog spawn-trust-recover)" "1"
assert_eq "B: the action-log row carries the key-at-detection value" \
    "$(grep -c 'trust-key-at-detection.*ABSENT' "$FAKE_NEXUS/monitor/.state/action-log.jsonl")" "1"

# ---- ARM C: dialog persists, key TRUE throughout -> bounded, exit 21 -------
echo '=== ARM C: the dialog persists with the key TRUE -> bounded at the max, exit 21 ==='
reset_arm 'state=blocked active=0 overlay=workspace-trust'
out=$(NEXUS_SPAWN_TRUST_MAX_RECOVER=1 spawn wC); rc=$?
assert_eq "C: spawn exits 21" "$rc" "21"
assert_contains "C: the failure is announced with the bound" "$out" "still on the workspace-trust dialog after 1 recover"
assert_contains "C: the history shows the key TRUE at every detection" "$out" "history: true,true"
assert_contains "C: …so the diagnostic says a re-seed cannot help" "$out" "re-seed cannot help"
assert_contains "C: …and names the key-path suspect" "$out" "KEY-PATH MISMATCH"
# Four-space-indented full path: the listing line, not the seeder's own
# "seeded workspace trust for <path>" line (which a mutant still prints).
assert_contains "C: …listing .projects keys sharing the workdir basename" "$out" "    $NESTED"
assert_not_contains "C: no spawned: line on a failed spawn" "$out" "spawned: window=wC"
assert_eq "C: exactly one recovery (one kill) before the bound" "$(tmux_count kill-window)" "1"
assert_eq "C: two windows in total; the last is LEFT IN PLACE" "$(tmux_count new-window)" "2"
assert_eq "C: the failure reached the ACTION LOG" "$(elog spawn-trust-failed)" "1"
assert_eq "C: no kept files linger even on failure" "$(keeps_left)" "0"

# ---- ARM D: a different overlay is not ours ------------------------------
echo '=== ARM D: a pane blocked on ANOTHER overlay is noted and left alone ==='
reset_arm 'state=blocked active=0 overlay=bypass-permissions'
out=$(spawn wD); rc=$?
assert_eq "D: spawn exits 0" "$rc" "0"
assert_contains "D: the note names the overlay and disclaims it" "$out" "overlay=bypass-permissions; not the trust dialog"
assert_eq "D: nothing was killed" "$(tmux_count kill-window)" "0"
assert_eq "D: pane-state consulted once" "$(ps_calls)" "1"

# ---- ARM E: empty forever -> unverified, never a failure --------------------
echo '=== ARM E: `empty` for the whole budget -> UNVERIFIED, exit 0, no kill ==='
reset_arm 'state=empty active=0'
t0=$(date +%s); out=$(NEXUS_SPAWN_TRUST_VERIFY_SECONDS=2 spawn wE); rc=$?; el=$(( $(date +%s) - t0 ))
assert_eq "E: spawn exits 0" "$rc" "0"
assert_contains "E: the outcome is UNVERIFIED, stated as not a failure" "$out" "UNVERIFIED: no positive pane state within 2s"
assert_contains "E: the spawned: line is printed" "$out" "spawned: window=wE"
assert_eq "E: nothing was killed" "$(tmux_count kill-window)" "0"
[ "$el" -le 7 ] && _th_pass || { printf '  FAIL: E: budget 2s but the spawn took %ss\n' "$el" >&2; _th_fail; }
assert_eq "E: the unverified outcome reached the ACTION LOG" "$(elog spawn-trust-unverified)" "1"

# ---- ARM F: disabled ---------------------------------------------------------
echo '=== ARM F: NEXUS_SPAWN_TRUST_VERIFY_SECONDS=0 disables the check ==='
reset_arm 'state=blocked active=0 overlay=workspace-trust'
out=$(NEXUS_SPAWN_TRUST_VERIFY_SECONDS=0 spawn wF); rc=$?
assert_eq "F: spawn exits 0" "$rc" "0"
assert_eq "F: pane-state was never consulted" "$(ps_calls)" "0"
assert_eq "F: no kept files linger" "$(keeps_left)" "0"

# ---- ARM G: the kill precondition ------------------------------------------
echo '=== ARM G: a transcript EXISTS at detection -> recovery REFUSED before any kill ==='
reset_arm 'state=blocked active=0 overlay=workspace-trust'
out=$(TMUX_PLANT_TRANSCRIPT=1 spawn wG); rc=$?
assert_eq "G: spawn exits 21" "$rc" "21"
assert_contains "G: the refusal names the precondition" "$out" "no-work-lost precondition failed (transcript-exists(1))"
assert_contains "G: …and says why a transcript disqualifies the detection" "$out" "something RAN in that pane"
assert_eq "G: NOTHING was killed" "$(tmux_count kill-window)" "0"
assert_eq "G: no second window" "$(tmux_count new-window)" "1"
assert_eq "G: the refusal reached the ACTION LOG with its reason" \
    "$(grep -c 'respawn-refused' "$FAKE_NEXUS/monitor/.state/action-log.jsonl")" "1"

# ---- ARM H: the window key cannot be resolved -------------------------------
echo '=== ARM H: tmux cannot resolve the window key -> UNVERIFIED quickly, exit 0 ==='
reset_arm 'state=idle active=0'
t0=$(date +%s); out=$(TMUX_NOKEY=1 spawn wH); rc=$?; el=$(( $(date +%s) - t0 ))
assert_eq "H: spawn exits 0" "$rc" "0"
assert_contains "H: the outcome names the unresolvable key" "$out" "could not resolve window @9 to a pane-state key"
assert_eq "H: pane-state was never consulted" "$(ps_calls)" "0"
[ "$el" -le 6 ] && _th_pass || { printf '  FAIL: H: took %ss (expected <= 6)\n' "$el" >&2; _th_fail; }

# ---- ARM I: structural --------------------------------------------------------
echo '=== ARM I: structure — both sites, the precondition before the kill, the exemption named ==='
assert_eq "I: the fresh site keeps the launcher before sending it" \
    "$(grep -c '^_sw_trust_keep_launcher fresh$' "$SPAWN_REAL")" "1"
assert_eq "I: the resume site keeps the launcher before sending it" \
    "$(grep -c '^    _sw_trust_keep_launcher resume$' "$SPAWN_REAL")" "1"
# `grep -o … | wc -l` counts OCCURRENCES; `grep -c` counts LINES and reads as
# occurrences (textguard-lint R1, your-org/nexus-code#1016). Two of these
# patterns can legitimately appear twice on one line, so the unit matters.
assert_eq "I: the verifier is called at exactly the two window-creation sites" \
    "$(grep -o '_sw_trust_verify "\$WID"$' "$SPAWN_REAL" | wc -l)" "2"
assert_eq "I: the ONLY kill in the block is preceded by the precondition" \
    "$(grep -B14 'tmux kill-window -t "\$old_wid"' "$SPAWN_REAL" | grep -o '_sw_trust_no_work_ran' | wc -l)" "1"
assert_eq "I: the exemption is stated by name at the call site" \
    "$(grep -o 'EXEMPTION FROM .bk_pane_kill_authorized.' "$SPAWN_REAL" | wc -l)" "1"
assert_eq "I: the kill allowlist in _bookkeeping.sh still excludes blocked (the guard was not weakened)" \
    "$(grep -E '^_BK_KILL_OK_STATES=' "$BK_REAL" | grep -c 'blocked')" "0"
# Counted as COMMAND-position occurrences (line start, prefix or export), not
# as bare mentions — the rationale comments name the variable too.
assert_eq "I: every launcher template sets CLAUDE_CODE_SANDBOXED=1 (fresh direct, fresh loop, resume)" \
    "$(grep -cE '^(export )?CLAUDE_CODE_SANDBOXED=1( |$)' "$SPAWN_REAL")" "3"

# ---- ARM J: projects is a SYMLINK (this host's shape) -------------------------
# sp1334sk (#1334): `find <symlink>` does not descend a symlinked STARTING
# POINT, so the precondition returned 0 for a transcript that existed and the
# kill went ahead. Both directions on the symlink shape: a planted transcript
# must REFUSE, and no transcript must still RECOVER (the probe is potent, not
# merely non-zero).
echo '=== ARM J: $CLAUDE_CONFIG_DIR/projects is a SYMLINK — the precondition still sees the transcript ==='
symlink_projects() { rm -rf "$CFG_DIR/projects" "$WORK/realprojects"; mkdir -p "$WORK/realprojects"; ln -s "$WORK/realprojects" "$CFG_DIR/projects"; }
reset_arm 'state=blocked active=0 overlay=workspace-trust'; symlink_projects
out=$(TMUX_PLANT_TRANSCRIPT=1 spawn wJ); rc=$?
assert_eq "J1: symlinked projects, transcript planted THROUGH the symlink" "$(find -H "$CFG_DIR/projects" -name '*.jsonl' | wc -l | tr -d ' ')" "1"
assert_eq "J1: spawn exits 21 (refused)" "$rc" "21"
assert_contains "J1: the refusal names the transcript" "$out" "transcript-exists(1)"
assert_eq "J1: NOTHING was killed" "$(tmux_count kill-window)" "0"
reset_arm $'state=blocked active=0 overlay=workspace-trust\nstate=idle active=0'; symlink_projects
out=$(PS_ON_OVERLAY="$DROP_KEY" spawn wJ2); rc=$?
assert_eq "J2: same symlink shape, NO transcript -> recovered, exit 0" "$rc" "0"
assert_eq "J2: exactly one kill (the probe is potent in both directions)" "$(tmux_count kill-window)" "1"
rm -rf "$CFG_DIR/projects" "$WORK/realprojects"

# ---- ARM K: the loop-wrapper path (no session id) -----------------------------
# No id claude will honour, so the precondition is the COARSE stamp check:
# any transcript anywhere under projects/*/ newer than the pre-send stamp
# refuses. The launcher template is the loop one (`export`), exercised here.
echo '=== ARM K: loop wrapper — coarse stamp precondition, both directions ==='
reset_arm 'state=blocked active=0 overlay=workspace-trust'
out=$(MONITOR_RETAIN_USE_LOOP_WRAPPER=1 TMUX_PLANT_ANY=1 spawn wK); rc=$?
assert_eq "K1: a transcript under an UNRELATED slug, newer than the stamp -> exit 21" "$rc" "21"
assert_contains "K1: the refusal says it was anywhere, not slug-matched" "$out" "transcript-newer-than-spawn-anywhere(1)"
assert_eq "K1: NOTHING was killed" "$(tmux_count kill-window)" "0"
assert_contains "K1: the loop launcher carries the flag via export" "$(cat "$TMPD"/spawn-launcher-wK.*.sh)" "export CLAUDE_CODE_SANDBOXED=1"
reset_arm $'state=blocked active=0 overlay=workspace-trust\nstate=idle active=0'
mkdir -p "$CFG_DIR/projects/old"; : > "$CFG_DIR/projects/old/aa.jsonl"; touch -d '2026-01-01' "$CFG_DIR/projects/old/aa.jsonl"
out=$(MONITOR_RETAIN_USE_LOOP_WRAPPER=1 PS_ON_OVERLAY="$DROP_KEY" spawn wK2); rc=$?
assert_eq "K2: only an OLDER transcript on disk -> recovered, exit 0" "$rc" "0"
assert_eq "K2: exactly one kill" "$(tmux_count kill-window)" "1"

# ---- ARM R: the --resume site, LIVE ------------------------------------------
# The resumed transcript exists by definition, so the precondition there is
# "unchanged since the launcher was sent". Host shape reproduced exactly:
# $CLAUDE_CONFIG_DIR/projects is a symlink to $HOME/.claude/projects, and the
# resolver locates the transcript under the workdir's slug.
echo '=== ARM R: --resume — the resumed transcript must be UNCHANGED, on the symlink shape ==='
RHOME="$WORK/home"; RSLUG=$(printf '%s' "$NESTED" | sed 's|[^a-zA-Z0-9]|-|g'); RUUID="33333333-3333-4333-8333-333333333333"
resume_fixture() {
    rm -rf "$RHOME" "$CFG_DIR/projects"; mkdir -p "$RHOME/.claude/projects/$RSLUG"
    printf '{}\n' > "$RHOME/.claude/projects/$RSLUG/$RUUID.jsonl"; touch -d '2026-06-01 09:00' "$RHOME/.claude/projects/$RSLUG/$RUUID.jsonl"
    ln -s "$RHOME/.claude/projects" "$CFG_DIR/projects"
}
rspawn() { ( cd "$WORK" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" HOME="$RHOME" \
        NEXUS_ROOT="$FAKE_NEXUS" CLAUDE_CONFIG_DIR="$CFG_DIR" TMPDIR="$TMPD" \
        "$FAKE_NEXUS/monitor/spawn-worker.sh" --resume "$RUUID" -n "$1" -c "$NESTED" 2>&1 ) }
reset_arm $'state=blocked active=0 overlay=workspace-trust\nstate=idle active=0'; resume_fixture
out=$(PS_ON_OVERLAY="$DROP_KEY" rspawn wR); rc=$?
assert_contains "R1: the resume path actually ran (resumed: line)" "$out" "resumed: window=wR"
assert_eq "R1: transcript unchanged -> recovered, exit 0" "$rc" "0"
assert_eq "R1: exactly one kill" "$(tmux_count kill-window)" "1"
assert_contains "R1: the resume launcher carries the flag" "$(cat "$TMPD"/spawn-launcher-wR.*.sh)" "CLAUDE_CODE_SANDBOXED=1"
reset_arm 'state=blocked active=0 overlay=workspace-trust'; resume_fixture
out=$(TMUX_GROW_RESUME="$RHOME/.claude/projects/$RSLUG/$RUUID.jsonl" rspawn wR2); rc=$?
assert_eq "R2: transcript GREW after the launcher was sent -> exit 21" "$rc" "21"
assert_contains "R2: the refusal names the change" "$out" "resume-transcript-changed("
assert_eq "R2: NOTHING was killed" "$(tmux_count kill-window)" "0"
rm -rf "$RHOME" "$CFG_DIR/projects"

# ---- verdict ------------------------------------------------------------
_total=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _total != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' "$_total" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi
th_summary_and_exit
