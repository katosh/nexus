#!/usr/bin/env bash
# test-codex-worker.sh — the Codex worker harness, hermetically
# (your-org/nexus-code#1640, layer 2).
#
# Stub codex (CODEX_BIN), stub tmux (PATH), a fake nexus root holding copies
# of the real scripts. Nothing here runs Codex or touches a tmux server: the
# spawn's GENERATED LAUNCHER is inspected, never executed. The real-binary,
# real-tmux half is monitor/watcher/test-integration/test-codex-worker-e2e.sh.
#
# Covered, each against the real script:
#   A. spawn-worker.sh --harness codex: refusals (24 no binary, 25 no login,
#      24 loop wrapper, usage on a bad harness), the launcher it writes, the
#      descriptor, persisted folder trust, the floor + Codex addendum, and a
#      Claude spawn's prompt NOT carrying the addendum (negative control);
#   B. --resume of a Codex window: `codex resume <thread>` from the
#      descriptor, and exit 11 when the rollout is missing;
#   C. codex-hook.sh: heartbeat + submit-stamp + descriptor thread id, stdout
#      always empty, never touching a non-Codex descriptor;
#   D. codex-trust-workdir.sh: append, edit, idempotence, preservation;
#   E. ng report-init's session id for a Codex worker, and that it NEVER
#      falls through to a ~/.claude transcript;
#   F. harness/codex.sh declares tmux-paste with the submit-stamp receipt.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Population (skeptic F5, #1640): every script this suite drives a copy of for
# the Codex harness, so an edit to any selects it in `ng guards-for-diff`.
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' monitor/spawn-worker.sh monitor/_spawn-codex.sh monitor/codex-hook.sh \
        monitor/codex-trust-workdir.sh monitor/harness/codex.sh monitor/_codex.sh monitor/ng
}
gp_handle "$@"
# shellcheck source=_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
MON=$(cd "$_test_dir/.." && pwd)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/codexworker.XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# ---- fake nexus ------------------------------------------------------------
FN="$WORK/nexus"
mkdir -p "$FN/monitor/harness" "$FN/skills/nexus.worker-defaults" "$FN/reports" "$FN/codex-cli"
for f in spawn-worker.sh _claude-bin.sh _tmux-window.sh _fm_lib.sh _bookkeeping.sh guard-block.sh.in \
         request-channel.sh _channel_lib.sh _codex.sh _spawn-codex.sh codex-trust-workdir.sh \
         codex-hook.sh worker-heartbeat.sh; do
    cp "$MON/$f" "$FN/monitor/$f" || th_abort "copy $f"
done
cp "$MON/harness/codex.sh" "$MON/harness/generic-tmux.sh" "$FN/monitor/harness/" || th_abort "copy adapters"
cp "$MON/_nexus-root.sh" "$MON/repo-root.sh" "$FN/monitor/" 2>/dev/null || true
chmod +x "$FN/monitor/"*.sh "$FN/monitor/harness/"*.sh
printf '{ "dependencies": { "@openai/codex": "9.9.9" } }\n' > "$FN/codex-cli/package.json"
printf '#!/bin/bash\nexit 0\n' > "$FN/monitor/ng"; chmod +x "$FN/monitor/ng"
mkdir -p "$FN/node_modules/.bin"
printf '#!/bin/bash\necho "stub-claude: $*"\n' > "$FN/node_modules/.bin/claude"; chmod +x "$FN/node_modules/.bin/claude"
cat > "$FN/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
---
description: stub
---
## Worker floor

FLOOR-SENTINEL-4471: the floor body.

## Codex worker addendum

ADDENDUM-SENTINEL-9152: read the nexus contract first.

## Reply-to wrap-up override

reply-to body.
EOF

STUBCODEX="$WORK/bin/codex"; mkdir -p "$WORK/bin"
printf '#!/bin/bash\n[ "$1" = --version ] && { echo "codex-cli 9.9.9"; exit 0; }\nexit 0\n' > "$STUBCODEX"; chmod +x "$STUBCODEX"
STUBTMUX="$WORK/tbin"; mkdir -p "$STUBTMUX"; TLOG="$WORK/tmux.log"; : > "$TLOG"
cat > "$STUBTMUX/tmux" <<STUB
#!/bin/bash
printf 'tmux %s\n' "\$*" >> "$TLOG"
case "\$1" in
    new-window) echo '@7' ;;
    display-message) echo 0 ;;
esac
exit 0
STUB
chmod +x "$STUBTMUX/tmux"

WD="$WORK/wd"; mkdir -p "$WD"
git -C "$WD" init -q . || th_abort "git init"
th_require_fixture_repo "$WD" "codex worker workdir"
echo "do the task — TASK-SENTINEL-2203" > "$WORK/task.txt"
STATE="$WORK/state"; CH="$WORK/codexhome"; mkdir -p "$STATE" "$CH"

# _spawn <args…> ; sets RC OUT. TMPDIR is the suite's, so the generated
# launcher lands where it can be read.
_spawn() {
    RC=0
    OUT=$(env -u OPENAI_API_KEY -u CODEX_API_KEY -u MONITOR_RETAIN_USE_LOOP_WRAPPER \
              PATH="$STUBTMUX:$PATH" TMPDIR="$WORK/tmp" NEXUS_ROOT="$FN" NEXUS_ALLOW_SECONDARY_ROOT=1 \
              NEXUS_STATE_DIR="$STATE" CODEX_HOME="$CH" CODEX_BIN="${T_BIN-$STUBCODEX}" \
              ${T_ENV:+$T_ENV} \
              bash "$FN/monitor/spawn-worker.sh" "$@" 2>&1) || RC=$?
}
mkdir -p "$WORK/tmp"
# The newest generated launcher for window $1. `find` with a QUOTED pattern,
# not `ls <glob>`: under an inherited nullglob an unmatched glob vanishes and
# a bare `ls` would list the CWD (test-nullglob-bare-form-manifest.sh).
_launcher() {
    find "$WORK/tmp" -maxdepth 1 -type f -name "spawn-launcher-*$1*.sh" -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | sed -n '1s/^[^ ]* //p'
}

echo "=== A. spawn-worker.sh --harness codex ==="
_spawn -n cxa -c "$WD" -p "$WORK/task.txt" --harness bogus
assert_rc "an unknown --harness is usage (rc 5)" "$RC" "5"
T_BIN="$WORK/no-such-codex" _spawn -n cxa -c "$WD" -p "$WORK/task.txt" --harness codex
assert_rc "no codex binary -> rc 24" "$RC" "24"
_spawn -n cxa -c "$WD" -p "$WORK/task.txt" --harness codex
assert_rc "no \$CODEX_HOME/auth.json and no custom provider -> rc 25" "$RC" "25"
assert_contains "…naming the one-time operator login, key on STDIN" "$OUT" "printenv OPENAI_API_KEY | "
: > "$TLOG"
assert_eq "…and no window was created" "$(grep -c 'new-window' "$TLOG" || true)" "0"
echo '{"auth_mode":"apikey"}' > "$CH/auth.json"
T_ENV="MONITOR_RETAIN_USE_LOOP_WRAPPER=1" _spawn -n cxa -c "$WD" -p "$WORK/task.txt" --harness codex
assert_rc "the claude-loop wrapper has no Codex form -> rc 24" "$RC" "24"

_spawn -n cxa -c "$WD" -p "$WORK/task.txt" --harness codex --print-prompt
assert_rc       "--print-prompt -> rc 0" "$RC" "0"
assert_contains "the floor is injected" "$OUT" "FLOOR-SENTINEL-4471"
assert_contains "the Codex addendum is injected, under its heading" "$OUT" $'## Codex worker addendum\n\nADDENDUM-SENTINEL-9152'
assert_contains "the task follows" "$OUT" "TASK-SENTINEL-2203"
_spawn -n cxa -c "$WD" -p "$WORK/task.txt" --print-prompt
assert_not_contains "NEGATIVE CONTROL: a Claude spawn's prompt carries NO Codex addendum" "$OUT" "ADDENDUM-SENTINEL-9152"

: > "$TLOG"
_spawn -n cxa -c "$WD" -p "$WORK/task.txt" --harness codex --model gpt-test-7 --skeptic deny
assert_rc "a Codex spawn -> rc 0" "$RC" "0"
assert_contains "…and says harness=codex" "$OUT" "harness=codex"
L=$(_launcher cxa); [[ -n "$L" && -r "$L" ]] || th_abort "no launcher written under $WORK/tmp"
LT=$(<"$L")
assert_contains     "launcher execs the resolved codex binary" "$LT" "\"$STUBCODEX\" "
assert_contains     "…with codex's sandbox off (bwrap cannot start here) and no approvals" "$LT" "-s danger-full-access -a never"
assert_contains     "…with the requested model" "$LT" "-m gpt-test-7"
assert_contains     "…with the update prompt disabled" "$LT" "check_for_update_on_startup=false"
assert_contains     "…reading CLAUDE.md as the project doc" "$LT" 'project_doc_fallback_filenames=\[\"CLAUDE.md\"\]'
assert_contains     "…with the Stop hook wired to codex-hook.sh" "$LT" "$FN/monitor/codex-hook.sh\\ Stop"
assert_contains     "…and the UserPromptSubmit hook (the submit-stamp receipt)" "$LT" "$FN/monitor/codex-hook.sh\\ UserPromptSubmit"
assert_contains     "…and the PreToolUse hook (skeptic F4: a tool's START marks the turn busy)" "$LT" "$FN/monitor/codex-hook.sh\\ PreToolUse"
assert_contains     "…exporting the window name the hooks key on" "$LT" "export NEXUS_WORKER_WINDOW=\"cxa\""
assert_contains     "…pinning CODEX_HOME to the one the preflight checked" "$LT" "export CODEX_HOME=\"$CH\""
assert_contains     "…keeping the fail-closed shim guard prelude" "$LT" "NEXUS_ASSERT_NPROC_EXPECT"
assert_not_contains "…and carrying NO claude flag" "$LT" "--dangerously-skip-permissions"
assert_eq "descriptor records harness=codex and an EMPTY session id (the hook fills it)" \
    "$(jq -c '[.harness, .session_id]' "$STATE/windows/cxa.json" 2>/dev/null)" '["codex",""]'
assert_contains "folder trust was PERSISTED for the workdir" "$(cat "$CH/config.toml" 2>/dev/null)" \
    "[projects.\"$(cd "$WD" && pwd -P)\"]"
assert_eq "no Claude trust-verify ran for a Codex window (no capture-pane polling)" \
    "$(grep -c 'capture-pane' "$TLOG" || true)" "0"

echo "=== B. --resume of a Codex window ==="
SID=01900000-0000-7000-8000-000000000001
jq --arg s "$SID" '.session_id=$s' "$STATE/windows/cxa.json" > "$WORK/d.json" && mv "$WORK/d.json" "$STATE/windows/cxa.json"
_spawn --resume cxa -c "$WD" --dry-run
assert_rc "no rollout on disk for the thread -> rc 11" "$RC" "11"
mkdir -p "$CH/sessions/2026/09/26"
: > "$CH/sessions/2026/09/26/rollout-2026-09-26T11-45-04-$SID.jsonl"
_spawn --resume cxa -c "$WD" --dry-run
assert_rc       "with the rollout present -> resolved (dry run rc 0)" "$RC" "0"
assert_contains "…to the descriptor's thread id and the rollout" "$OUT" "session=$SID"
rm -f "$WORK/tmp"/spawn-launcher-*.sh
_spawn --resume cxa -c "$WD" --no-nudge
assert_rc       "a Codex resume spawns -> rc 0" "$RC" "0"
L=$(_launcher cxa); LT=$(cat "$L" 2>/dev/null)
assert_contains "the resume launcher runs \`codex resume <thread>\`" "$LT" "\"$STUBCODEX\" resume -s danger-full-access"
assert_contains "…naming the recorded thread" "$LT" "\"$SID\""

echo "=== C. codex-hook.sh ==="
HOOK="$FN/monitor/codex-hook.sh"
_hook() {   # <event> <payload> ; sets HOUT HRC
    HRC=0
    HOUT=$(printf '%s' "$2" | env NEXUS_ROOT="$FN" NEXUS_STATE_DIR="$STATE" NEXUS_WORKER_WINDOW="${H_WIN:-cxh}" "$HOOK" "$1") || HRC=$?
}
printf '{"window":"cxh","harness":"codex","session_id":""}\n' > "$STATE/windows/cxh.json"
printf '{"window":"cxc","harness":"claude-code","session_id":""}\n' > "$STATE/windows/cxc.json"
H_SID=01900000-0000-7000-8000-000000000002
_hook SessionStart "{\"session_id\":\"$H_SID\",\"hook_event_name\":\"SessionStart\"}"
assert_eq "SessionStart: rc 0 and NOTHING on stdout (codex parses hook stdout)" "$HRC|$HOUT" "0|"
assert_eq "SessionStart: the Codex descriptor gets the thread id" "$(jq -r .session_id "$STATE/windows/cxh.json")" "$H_SID"
assert_eq "SessionStart: heartbeat busy with the session id" \
    "$(jq -c '[.state,.session_id]' "$STATE/heartbeat/cxh.json")" "[\"busy\",\"$H_SID\"]"
H_WIN=cxc _hook SessionStart "{\"session_id\":\"$H_SID\"}"
assert_eq "NEGATIVE CONTROL: a claude-code descriptor is never written" "$(jq -r .session_id "$STATE/windows/cxc.json")" ""
_hook SessionStart '{"session_id":"01a0ffff-0000-7000-8000-000000000000"}'
assert_eq "an already-recorded thread id is never overwritten" "$(jq -r .session_id "$STATE/windows/cxh.json")" "$H_SID"
_hook UserPromptSubmit "{\"session_id\":\"$H_SID\",\"prompt\":\"hi\"}"
assert_eq "UserPromptSubmit writes the submit-stamp <epoch>TAB<sid>" \
    "$(awk -F'\t' '{print ($1 ~ /^[0-9]+$/) "|" $2}' "$STATE/user-prompt/cxh")" "1|$H_SID"
_hook PreToolUse "{\"session_id\":\"$H_SID\",\"tool_name\":\"exec_command\"}"
assert_eq "PreToolUse -> heartbeat busy (a tool STARTS)" "$(jq -r .state "$STATE/heartbeat/cxh.json")" "busy"
_hook Stop "{\"session_id\":\"$H_SID\"}"
assert_eq "Stop -> idle_prompt with last_turn_end" \
    "$(jq -c '[.state, (.last_turn_end|type)]' "$STATE/heartbeat/cxh.json")" '["idle_prompt","number"]'
_hook Stop 'this is not json {'
assert_eq "garbage payload: still rc 0, still silent" "$HRC|$HOUT" "0|"
_hook NoSuchEvent '{}'
assert_eq "unknown event: rc 0, silent" "$HRC|$HOUT" "0|"

echo "=== D. codex-trust-workdir.sh ==="
TW="$FN/monitor/codex-trust-workdir.sh"; TH="$WORK/th"; mkdir -p "$TH" "$WORK/w1" "$WORK/w2"
W1=$(cd "$WORK/w1" && pwd -P)
printf '[tui]\nx = 1\n\n[projects."%s"]\ntrust_level = "untrusted"\nkeep = 2\n' "$W1" > "$TH/config.toml"
"$TW" "$WORK/w1" --codex-home "$TH"; rc=$?
assert_rc "edit an existing untrusted table -> rc 0" "$rc" "0"
assert_eq "…trust_level is now trusted, and only once" "$(grep -c '^trust_level = "trusted"$' "$TH/config.toml")" "1"
assert_contains "…unrelated keys preserved" "$(cat "$TH/config.toml")" $'[tui]\nx = 1'
assert_contains "…table keys preserved" "$(cat "$TH/config.toml")" "keep = 2"
"$TW" "$WORK/w2" --codex-home "$TH"; before=$(cksum < "$TH/config.toml")
"$TW" "$WORK/w2" --codex-home "$TH"
assert_eq "a second run is byte-identical (idempotent)" "$(cksum < "$TH/config.toml")" "$before"
"$TW" "$WORK/nope" --codex-home "$TH" 2>/dev/null; rc=$?
assert_rc "a missing workdir -> rc 2" "$rc" "2"

echo "=== E. ng report-init session id for a Codex worker ==="
NG_SRC="$MON/ng"
_rsid() { ( cd "$WORK/w1" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR HOME="$WORK/fakehome" CODEX_THREAD_ID="$1" \
            bash -c "source <(sed -n '/^_report_session_id() {/,/^}/p' '$NG_SRC'); _report_session_id" ); }
slug=$(printf '%s' "$(cd "$WORK/w1" && pwd)" | sed 's|[^a-zA-Z0-9]|-|g')
mkdir -p "$WORK/fakehome/.claude/projects/$slug"
: > "$WORK/fakehome/.claude/projects/$slug/99999999-aaaa-4bbb-8ccc-dddddddddddd.jsonl"
assert_eq "CODEX_THREAD_ID is the session id" "$(_rsid "$H_SID")" "$H_SID"
assert_eq "a malformed CODEX_THREAD_ID yields NOTHING — never another agent's Claude transcript" "$(_rsid garbage)" ""
assert_eq "CONTROL: with no CODEX_THREAD_ID the Claude fallback DOES find that transcript" \
    "$( ( cd "$WORK/w1" && env -u CODEX_THREAD_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR HOME="$WORK/fakehome" \
          bash -c "source <(sed -n '/^_report_session_id() {/,/^}/p' '$NG_SRC'); _report_session_id" ) )" \
    "99999999-aaaa-4bbb-8ccc-dddddddddddd"

echo "=== F. harness/codex.sh ==="
AD="$FN/monitor/harness/codex.sh"
assert_eq "with a heartbeat: tmux-paste, shell, submit-stamp receipt, stamps=self" \
    "$(env NEXUS_ROOT="$FN" NEXUS_STATE_DIR="$STATE" "$AD" transports cxh)" $'tmux-paste\tshell\tsubmit-stamp\tself'
assert_eq "without one: the receipt is declared none, not assumed" \
    "$(env NEXUS_ROOT="$FN" NEXUS_STATE_DIR="$STATE" "$AD" transports nohb)" $'tmux-paste\tshell\tnone\tself'
"$AD" frobnicate >/dev/null 2>&1; rc=$?
assert_rc "an unknown verb -> rc 2" "$rc" "2"

EXPECTED_ASSERTIONS=56
TOTAL_ASSERTIONS=$(( PASS + FAIL + ${SKIP:-0} ))
if (( TOTAL_ASSERTIONS != EXPECTED_ASSERTIONS )); then
    printf '  FAIL: assertion count %d != expected %d — an assertion was silently dropped\n' \
        "$TOTAL_ASSERTIONS" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
fi
th_summary_and_exit
