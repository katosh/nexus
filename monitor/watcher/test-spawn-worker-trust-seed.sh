#!/usr/bin/env bash
# cc 2.1.232 regression guard: spawn-worker.sh must pre-seed Claude Code's
# workspace-trust entry for the worker's workdir before creating its window.
#
# From cc 2.1.232 ("Fixed nested git repositories inheriting trust from a
# parent directory; each repository now requires its own trust confirmation"),
# a worker spawned into work/<project> — a git repo nested inside the nexus
# git repo — stops on the trust dialog and never reaches a REPL.
#
# CORRECTED (your-org/nexus-code#1015 finding 4). This used to continue
# "Nothing in the existing control surface catches it: pane-state.sh reads
# that frame as `state=empty active=0`, NOT `blocked`". That was true when
# #888 was written and is now FALSE: #896 added a `workspace-trust` overlay
# arm to monitor/pane-state.sh, and the frame measures
# `state=blocked active=0 overlay=workspace-trust`. The seeder is still worth
# having — it PREVENTS the hang rather than detecting it — but it is no
# longer the only thing between a hung worker and an unobserved board.
#
# Run: bash monitor/watcher/test-spawn-worker-trust-seed.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Every assertion runs against an ISOLATED CLAUDE_CONFIG_DIR — this test must
# never touch the operator's real ~/.claude.json.

set -uo pipefail
unset NEXUS_WORKER_WINDOW

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SPAWN_REAL="$_test_dir/../spawn-worker.sh"
EWT_REAL="$_test_dir/../ensure-workdir-trusted.sh"

PASS=0
FAIL=0
EXPECTED_ASSERTIONS=13

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
        printf '  FAIL: %s\n           expected: %s\n' "$label" "$needle" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

command -v jq >/dev/null 2>&1 || { echo "test: jq required" >&2; exit 2; }

# ---- fixture ------------------------------------------------------------
WORK=$(cd "$(mktemp -d)" && pwd -P)
WINDOW_NAME="trust-seed-test-$$"
trap 'rm -rf "$WORK"; rm -f /tmp/spawn-launcher-${WINDOW_NAME}*.sh /tmp/spawn-prompt-${WINDOW_NAME}*.txt' EXIT

FAKE_NEXUS="$WORK/nexus"
# The workdir is a git repo NESTED inside the nexus git repo — the exact
# production topology the release regressed.
NESTED="$FAKE_NEXUS/work/proj"
mkdir -p "$FAKE_NEXUS/monitor" "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports" "$FAKE_NEXUS/config" "$NESTED"
git -C "$FAKE_NEXUS" init -q 2>/dev/null
git -C "$NESTED" init -q 2>/dev/null

for f in spawn-worker.sh ensure-workdir-trusted.sh _claude-bin.sh _tmux-window.sh \
         _fm_lib.sh assert-shims-wrapped.sh assert-gh-wrapped.sh guard-block.sh.in \
         ng _bookkeeping.sh; do
    [[ -f "$_test_dir/../$f" ]] && cp "$_test_dir/../$f" "$FAKE_NEXUS/monitor/$f"
done
chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh" "$FAKE_NEXUS/monitor/ensure-workdir-trusted.sh" \
         "$FAKE_NEXUS/monitor/assert-shims-wrapped.sh" "$FAKE_NEXUS/monitor/assert-gh-wrapped.sh" \
         "$FAKE_NEXUS/monitor/ng" 2>/dev/null
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
cat > "$STUB_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
case "$1" in
    info|list-windows|set-window-option) exit 0 ;;
    new-window) echo '@9'; exit 0 ;;
    *) exit 0 ;;
esac
TMUX_STUB
chmod +x "$STUB_BIN/tmux"
printf '#!/bin/bash\nexit 0\n' > "$STUB_BIN/claude"; chmod +x "$STUB_BIN/claude"

# Isolated config dir — NEVER the operator's real ~/.claude.json.
CFG_DIR="$WORK/claude-cfg"; mkdir -p "$CFG_DIR"
CFG="$CFG_DIR/.claude.json"
# Seed a config that trusts the PARENT only, with unrelated keys that must
# survive, exactly like a real operator's file.
jq -n --arg p "$FAKE_NEXUS" '{
    theme:"dark", oauthAccount:{uuid:"must-survive"},
    projects: { ($p): { hasTrustDialogAccepted:true, allowedTools:["Bash"] } }
}' > "$CFG"

spawn() {
    ( cd "$WORK" && PATH="$STUB_BIN:$PATH" CLAUDE_BIN="$STUB_BIN/claude" \
        NEXUS_ROOT="$FAKE_NEXUS" CLAUDE_CONFIG_DIR="$CFG_DIR" \
        "$FAKE_NEXUS/monitor/spawn-worker.sh" \
            -n "$1" -c "$NESTED" -p "$PROMPT_FILE" 2>&1 )
}

# ---- Test 1: a fresh spawn seeds trust for the nested workdir ------------
echo '=== fresh spawn seeds workspace trust for the nested workdir ==='
before=$(jq -r --arg d "$NESTED" '.projects[$d].hasTrustDialogAccepted // "absent"' "$CFG")
assert_eq "precondition: nested workdir starts UNtrusted" "$before" "absent"

out=$(spawn "$WINDOW_NAME"); rc=$?
assert_eq "spawn exits 0" "$rc" "0"
assert_eq "nested workdir is now trusted" \
    "$(jq -r --arg d "$NESTED" '.projects[$d].hasTrustDialogAccepted // "absent"' "$CFG")" "true"

# ---- Test 2: the seed MERGES, it does not replace ------------------------
echo '=== the seed preserves every other key in .claude.json ==='
assert_eq "unrelated top-level keys survive" \
    "$(jq -r '.oauthAccount.uuid' "$CFG")" "must-survive"
assert_eq "theme survives" "$(jq -r '.theme' "$CFG")" "dark"
assert_eq "the parent's own project entry survives" \
    "$(jq -r --arg p "$FAKE_NEXUS" '.projects[$p].hasTrustDialogAccepted' "$CFG")" "true"
assert_eq "the parent's other project fields survive" \
    "$(jq -r --arg p "$FAKE_NEXUS" '.projects[$p].allowedTools|join(",")' "$CFG")" "Bash"

# ---- Test 3: idempotent — a second spawn neither churns nor corrupts -----
echo '=== a second spawn is a no-op on an already-trusted workdir ==='
sum_before=$(md5sum < "$CFG")
out2=$(spawn "${WINDOW_NAME}-b"); rc2=$?
assert_eq "second spawn exits 0" "$rc2" "0"
assert_eq "config byte-identical on the second spawn (no rewrite)" \
    "$(md5sum < "$CFG")" "$sum_before"
assert_eq "config is still valid JSON" \
    "$(jq -e . "$CFG" >/dev/null 2>&1 && echo ok)" "ok"

# ---- Test 4: fail-CLOSED — a seed failure blocks the spawn ---------------
# Spawning anyway is what produces the silent hang, so the refusal is the
# feature. A corrupt config is the reachable form of "cannot seed".
echo '=== a seed failure REFUSES the spawn rather than hanging a worker ==='
printf 'not json{\n' > "$CFG"
out3=$(spawn "${WINDOW_NAME}-c"); rc3=$?
assert_eq "spawn refuses (exit 10) when trust cannot be seeded" "$rc3" "10"
assert_contains "refusal explains it would hang on the trust dialog" \
    "$out3" "trust dialog"

# ---- Test 5: structural — EVERY window-creation site is guarded ----------
# The fresh-spawn and --resume paths create windows at two separate sites,
# and $WORKDIR is only final on the resume path much later than on the fresh
# one. A seed call added to just one site is the rarely-taken-branch drift
# this repo has filed before (#568 D4), and no live fresh-spawn test can see
# it — so assert the structure directly.
echo '=== every `tmux new-window` site is preceded by a trust seed ==='
sites=$(grep -c 'tmux new-window -P' "$SPAWN_REAL")
guarded=$(grep -B6 'tmux new-window -P' "$SPAWN_REAL" | grep -c '_seed_workspace_trust')
assert_eq "each window-creation site ($sites) has a seed call within 6 lines" \
    "$guarded" "$sites"

# ---- verdict ------------------------------------------------------------
total=$(( PASS + FAIL ))
if [[ "$total" -ne "$EXPECTED_ASSERTIONS" ]]; then
    printf '  FAIL: assertion COUNT drifted — ran %d, expected %d (a helper that vanished is counted by nothing)\n' \
        "$total" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: every declared assertion executed (%d)\n' "$total"
    PASS=$(( PASS + 1 ))
fi

echo "=== summary: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && { echo "ALL TESTS PASSED"; exit 0; }
exit 1
