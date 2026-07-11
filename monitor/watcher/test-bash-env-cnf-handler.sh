#!/usr/bin/env bash
# Regression test for the command_not_found_handle fork chain
# (your-org/nexus-code#480; the real mechanism behind #457).
#
# THE MECHANISM (reproduced, not assumed). Lmod's init arms a
# `command_not_found_handle` and does NOT `export -f` it. Bash FORKS A CHILD
# before invoking that handler, and the child inherits the parent's argv. The
# handler shells out to `command_not_found.py`; when THAT is itself unresolvable
# (a PATH that drops /app/bin), the handler re-fires inside the forked child,
# which forks again — an unbounded parent→child chain, each level blocked in
# wait(), until pid_max returns EAGAIN. Sourcing Lmod does not spawn a bash by
# itself; the earlier "re-source recursion" reading was falsified.
#
# #457's marker guard (NEXUS_BASH_ENV_CHAINED) keeps the handler off every
# DESCENDANT bash. But it is ancestry-dependent: the FIRST bash in a process
# tree still sources the chain and still arms the handler. #480 removes the
# primitive instead — `unset -f command_not_found_handle` after the chain — so
# ancestry stops mattering and a stripped PATH is harmless.
#
# THIS TEST drives that exact shape hermetically. It needs no real Lmod, no
# /app/bin, and no network. The fake prior-env arms a handler whose helper is
# unresolvable, and the handler SELF-LIMITS at a small depth, so the test can
# never fork-bomb the machine (mirrors test-bash-env-chain-guard.sh's cap).
#
# Both directions:
#   * against a copy of bash_env.sh with the `unset -f` line REMOVED, the
#     handler recurses (depth >= 3)  -> proves the test can see the bug;
#   * against the real bash_env.sh, the handler is gone (depth == 0, rc 127).
# A test that passes both ways proves nothing.
#
# Run: bash monitor/watcher/test-bash-env-cnf-handler.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_self_dir/../.." && pwd)
_bash_env="$_repo_root/monitor/shellenv/bash_env.sh"

[[ -r "$_bash_env" ]] || { echo "cannot read $_bash_env" >&2; exit 1; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

passed=0; failed=0
ok()   { printf '  PASS: %s\n' "$1"; passed=$((passed+1)); }
bad()  { printf '  FAIL: %s\n' "$1" >&2; failed=$((failed+1)); }

# ---- the fake prior-env: Lmod's SHAPE, none of its bulk ------------------
# Arms a handler that calls an unresolvable helper (the `command_not_found.py`
# stand-in) and self-limits so recursion is demonstrable but bounded.
cat > "$TMP/fake_prior.sh" <<'PRIOR'
# A legitimately exported function, as Lmod exports `module`/`ml`. It must
# SURVIVE the fix: #480 removes only command_not_found_handle.
fake_module() { printf 'fake_module ran\n'; }
export -f fake_module

# Lmod's shape: a handler that shells out to a helper. Not export -f'd.
command_not_found_handle() {
    printf 'x\n' >> "$CNF_COUNT"
    # Self-limit: without this the chain is unbounded by construction.
    if [ "$(wc -l < "$CNF_COUNT" 2>/dev/null || echo 0)" -ge 6 ]; then
        return 127
    fi
    cnf_helper_that_does_not_exist_xyz "$1"   # unresolvable -> handler re-fires
    return 127
}
PRIOR

# ---- a bash_env.sh with the #480 fix STRIPPED OUT (the pre-fix control) ---
grep -v '^unset -f command_not_found_handle' "$_bash_env" > "$TMP/bash_env_prefix.sh"

if ! grep -q '^unset -f command_not_found_handle' "$_bash_env"; then
    bad "bash_env.sh does not contain the '#480' unset -f line — nothing to test"
    printf '\n=== summary: %d passed, %d failed ===\n' "$passed" "$failed"
    exit 1
fi
if grep -q '^unset -f command_not_found_handle' "$TMP/bash_env_prefix.sh"; then
    bad "pre-fix control still contains the unset -f line"
fi

# ---- driver --------------------------------------------------------------
# `env -i` wipes NEXUS_BASH_ENV_CHAINED, so the subject is a FIRST-in-tree bash:
# precisely the case #457's marker guard does not cover. PATH deliberately omits
# any directory holding the handler's helper.
run_case() {  # <bash_env file> -> echoes "<handler_invocations> <rc>"
    local envfile="$1"
    local count="$TMP/count.$$.$RANDOM"; : > "$count"
    local out rc
    out=$(env -i \
            PATH="/usr/local/bin:/usr/bin:/bin" \
            HOME="$TMP" \
            CNF_COUNT="$count" \
            BASH_ENV="$envfile" \
            NEXUS_PREV_BASH_ENV="$TMP/fake_prior.sh" \
            timeout -s KILL 30 bash --noprofile --norc \
                -c 'a_command_that_does_not_exist_xyz >/dev/null 2>&1; printf "rc=%s\n" "$?"' 2>/dev/null)
    rc="${out#rc=}"
    printf '%s %s' "$(wc -l < "$count" 2>/dev/null || echo 0)" "${rc:-none}"
}

# ---- direction 1: the bug is visible without the fix ---------------------
read -r pre_depth pre_rc <<<"$(run_case "$TMP/bash_env_prefix.sh")"
if (( pre_depth >= 3 )); then
    ok "pre-fix: handler recursed (depth=$pre_depth) — the test can see the bug"
else
    bad "pre-fix: expected handler recursion (depth>=3), got depth=$pre_depth rc=$pre_rc"
fi

# ---- direction 2: the fix removes the primitive --------------------------
read -r post_depth post_rc <<<"$(run_case "$_bash_env")"
if (( post_depth == 0 )); then
    ok "post-fix: handler never invoked (depth=0) — primitive removed"
else
    bad "post-fix: handler still armed (depth=$post_depth) — unset -f did not take"
fi
if [[ "$post_rc" == "127" ]]; then
    ok "post-fix: unresolvable command is a plain 127"
else
    bad "post-fix: expected rc=127, got rc=$post_rc"
fi

# ---- the fix must not nuke legitimately exported functions ---------------
survivor=$(env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$TMP" \
    CNF_COUNT="$TMP/ignore" \
    BASH_ENV="$_bash_env" NEXUS_PREV_BASH_ENV="$TMP/fake_prior.sh" \
    timeout -s KILL 20 bash --noprofile --norc \
        -c 'declare -F fake_module >/dev/null && echo present || echo absent' 2>/dev/null)
if [[ "$survivor" == "present" ]]; then
    ok "post-fix: the chained env's exported function (fake_module) survives"
else
    bad "post-fix: chained env's exported function was lost (got '$survivor')"
fi

# ---- the #457 marker guard must still hold -------------------------------
marker=$(env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$TMP" \
    CNF_COUNT="$TMP/ignore2" \
    BASH_ENV="$_bash_env" NEXUS_PREV_BASH_ENV="$TMP/fake_prior.sh" \
    timeout -s KILL 20 bash --noprofile --norc \
        -c 'bash -c "printf %s \"\${NEXUS_BASH_ENV_CHAINED:-unset}\""' 2>/dev/null)
if [[ "$marker" == "1" ]]; then
    ok "#457 marker still exported and inherited by a child bash"
else
    bad "#457 marker regression: child saw '$marker'"
fi

printf '\n=== summary: %d passed, %d failed ===\n' "$passed" "$failed"
if (( failed == 0 )); then printf 'ALL TESTS PASSED\n'; exit 0; fi
exit 1
