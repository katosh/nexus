#!/usr/bin/env bash
# Unit tests for monitor/spawn-worker.sh `--reply-to` / `--issue`
# (channel-delivery spawn contract).
#
# Run: bash monitor/watcher/test-spawn-worker-reply-to.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# THE LOAD-BEARING TEST IS T1. `spawn-worker.sh` composes the prompt for
# EVERY nexus worker, so a default-path regression breaks the whole fleet.
# T1 pins the no-flag composed prompt against an INDEPENDENT reference
# composition built here in the test (env header + `---` + floor + `---` +
# task). Two independently-written expressions of the same format must
# agree byte-for-byte; any stray block, separator, or reordering the
# `--reply-to` work might have introduced shows up as a diff. It is
# deliberately NOT a checked-in golden file: a golden would churn on every
# legitimate floor-prose edit and get rubber-stamped, which is exactly how
# a real regression slips through.
#
# T2-T5 cover the new path: injection content, both-surfaces mode,
# dispatch-time id validation, and the flag-shape errors.
#
# Env robustness (the sandbox-masks-CI trap, skills/nexus.self-fix): every
# invocation runs under `env -u NEXUS_ROOT -u NEXUS_STATE_DIR`, and no
# fixture heredoc dereferences a nexus-exported variable, so the suite
# behaves identically on a clean runner and inside the sandbox.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_REAL="$_test_dir/../spawn-worker.sh"
SKILL_REAL="$_test_dir/../../skills/nexus.worker-defaults/SKILL.md"

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
        printf '  FAIL: %s — missing %q\n' "$label" "$needle" >&2
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

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SPAWN_TMP="$WORK/spawn-tmp"
mkdir -p "$SPAWN_TMP"
export TMPDIR="$SPAWN_TMP"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" \
         "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports"

cp "$SCRIPT_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
# The shim-guard TEMPLATE (your-org/nexus-code#589). spawn-worker.sh emits its
# launcher guard from monitor/guard-block.sh.in and REFUSES (exit 78) rather
# than emitting an empty block — an empty block is a guard that does not run.
# A hard dependency of any fake tree that RUNS spawn-worker.sh.
cp "$_test_dir/../guard-block.sh.in" "$FAKE_NEXUS/monitor/guard-block.sh.in"

chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh"
SCRIPT="$FAKE_NEXUS/monitor/spawn-worker.sh"

# _bookkeeping.sh is the same class of hard dependency as guard-block.sh.in
# above: since your-org/nexus-code#941 BOTH spawn-worker.sh and _channel_lib.sh
# load `wk_encode` from it and REFUSE rather than fall back to the lossy key.
# Without it the spawn dies at exit 2 and _channel_lib's own helpers
# (_chan_safe, _chan_apply_utf8_locale) are never defined, so request-channel.sh
# fails downstream with `mv: cannot stat …/.new.md` — a symptom that names
# neither the encoder nor this fixture.
for _dep in _claude-bin.sh _tmux-window.sh _fm_lib.sh _channel_lib.sh _bookkeeping.sh; do
    cp "$_test_dir/../$_dep" "$FAKE_NEXUS/monitor/$_dep"
done
cp "$_test_dir/../request-channel.sh" "$FAKE_NEXUS/monitor/request-channel.sh"
chmod +x "$FAKE_NEXUS/monitor/request-channel.sh"

mkdir -p "$FAKE_NEXUS/node_modules/.bin"
cat > "$FAKE_NEXUS/node_modules/.bin/claude" <<'CLAUDE_STUB'
#!/bin/bash
echo "stub-claude: $*"
CLAUDE_STUB
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"

cat > "$FAKE_NEXUS/monitor/worker-settings.json" <<'EOF'
{ "skipDangerousModePermissionPrompt": true, "hooks": {} }
EOF

# The REAL skill file — this suite asserts on the shipped floor + override
# text, not on a stub, so a section rename or an accidental H2 inside
# either body fails here rather than in production.
cp "$SKILL_REAL" "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md"
SKILL="$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md"

# A workdir OUTSIDE the fake nexus root: `-c <nexus-root>` triggers
# spawn-worker's root-cwd warning block, which would otherwise show up in
# the composed prompt and muddy the byte-identity comparison in T1.
WORKDIR="$WORK/worker-tree"
mkdir -p "$WORKDIR"

PROMPT_FILE="$WORK/task-prompt.txt"
cat > "$PROMPT_FILE" <<'EOF'
TASK_PROMPT_TOKEN_44ee0a

Do the thing.
EOF

# Run spawn-worker with a hermetic environment. NEXUS_ROOT / NEXUS_STATE_DIR
# are unset so the script's own dirname resolution (and the inbox under it)
# is what the assertions exercise — on a clean CI runner they are unset
# anyway, so this makes sandbox and CI behave identically.
run_spawn() {
    env -u NEXUS_ROOT -u NEXUS_STATE_DIR "$SCRIPT" "$@"
}

# Extract a named H2 section body from the skill, the same awk way
# spawn-worker.sh does.
skill_section() {
    awk -v hdr="$1" '
      $0 == "## " hdr { in_sec = 1; next }
      in_sec && /^## / { exit }
      in_sec { print }
    ' "$SKILL"
}

# File a request into the fake inbox and print its id.
file_request() {
    local slug="$1" origin="${2:-remote-test-client}"
    printf 'Question body for %s\n' "$slug" \
        | env -u NEXUS_STATE_DIR NEXUS_ROOT="$FAKE_NEXUS" \
              "$FAKE_NEXUS/monitor/request-channel.sh" file \
              --origin "$origin" --kind question --reply required \
              --slug "$slug" -
}

# Advance a request .new -> .claimed (what the watcher does before the
# orchestrator can reply).
claim_request() {
    mv "$FAKE_NEXUS/monitor/.state/requests/$1.new.md" \
       "$FAKE_NEXUS/monitor/.state/requests/$1.claimed.md"
}

# ---- T1: the no-flag composed prompt is UNCHANGED -----------------------

echo '=== T1: default spawn prompt matches an independent reference composition ==='

default_prompt=$(run_spawn -n t1-win -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt)

floor_body=$(skill_section "Worker floor")
reference=$(
    printf '## Worker environment\n\n'
    printf -- '- Workdir: %s\n' "$WORKDIR"
    printf -- '- Primary nexus root: %s\n' "$FAKE_NEXUS"
    printf -- '- Reports dir: %s/reports\n' "$FAKE_NEXUS"
    # your-org/nexus-code#814 — the clone-freshness block. `$WORKDIR` here is a
    # plain fixture directory, not a git checkout, so the block is this single
    # deterministic line. Kept in the INDEPENDENT reference (rather than lifted
    # from the produced prompt) so this test still means "the composition is
    # byte-for-byte what we expect"; the git-backed shapes of the block are
    # covered in test-spawn-worker.sh against real fixture repos.
    printf -- '- Clone freshness: NOT A GIT REPOSITORY (%s) — no remote-tracking state to report.\n' "$WORKDIR"
    printf '\n---\n\n'
    printf '%s\n\n---\n\n' "$floor_body"
    cat -- "$PROMPT_FILE"
)
if [[ "$default_prompt" == "$reference" ]]; then
    printf '  PASS: no-flag prompt == reference composition (byte-identical)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: no-flag prompt DIVERGED from the reference composition\n' >&2
    diff <(printf '%s\n' "$reference") <(printf '%s\n' "$default_prompt") >&2
    FAIL=$(( FAIL + 1 ))
fi

# The override text must be entirely absent from a default spawn — the
# cheap, direct statement of the same invariant.
assert_not_contains "default prompt carries no channel wrap-up text" \
    "$default_prompt" "ng wrap-up --reply-to"
assert_not_contains "default prompt carries no override heading text" \
    "$default_prompt" "answers a CHANNEL request"
assert_contains     "default prompt still carries the floor issue form" \
    "$default_prompt" "monitor/ng wrap-up <issue> <report-path>"

# Same invariant under the other flag shapes an orchestrator commonly uses.
for _flags in "--skeptic require" "--skeptic deny" "--kind interactive"; do
    # shellcheck disable=SC2086
    other=$(run_spawn -n t1-win -c "$WORKDIR" -p "$PROMPT_FILE" $_flags --print-prompt)
    assert_not_contains "no channel text with '$_flags'" "$other" "ng wrap-up --reply-to"
done

# ---- T2: --reply-to injects the override, after the floor ---------------

echo '=== T2: --reply-to injects the override block between floor and task ==='

RID=$(file_request "t2-question")
claim_request "$RID"
assert_contains "fixture request id is well-formed" "$RID" "remote-test-client-t2-question"

rt_prompt=$(run_spawn -n t2-win -c "$WORKDIR" -p "$PROMPT_FILE" --reply-to "$RID" --print-prompt)
rc=$?
assert_eq "--reply-to spawn composes (rc 0)" "$rc" "0"

assert_contains "override names the exact wrap-up command" \
    "$rt_prompt" "monitor/ng wrap-up --reply-to $RID <report-path>"
assert_contains "override states no GitHub issue is opened" \
    "$rt_prompt" "no GitHub"
assert_contains "override still requires the reports/ report" \
    "$rt_prompt" "crash-resumption surface"
assert_contains "override explains the Summary-is-the-answer contract" \
    "$rt_prompt" "verbatim"
assert_contains "override documents --answer-file" \
    "$rt_prompt" "--answer-file"
assert_contains "floor is still present alongside the override" \
    "$rt_prompt" "sandbox-notify"
assert_contains "task prompt is still present" \
    "$rt_prompt" "TASK_PROMPT_TOKEN_44ee0a"
assert_not_contains "no unsubstituted placeholder leaks into the prompt" \
    "$rt_prompt" "<REQUEST_ID>"
assert_not_contains "orchestrator-facing meta-prose stays out of the prompt" \
    "$rt_prompt" "Injected VERBATIM"

# Ordering: env header < floor < override < task. The override must come
# AFTER the floor (so it supersedes the floor's issue-form bullet by
# recency) and BEFORE the task (so per-spawn instructions have the last word).
env_line=$(grep -n '^## Worker environment$'        <<<"$rt_prompt" | head -1 | cut -d: -f1)
floor_line=$(grep -n 'sandbox-notify'               <<<"$rt_prompt" | head -1 | cut -d: -f1)
ovr_line=$(grep -n 'answers a CHANNEL request'      <<<"$rt_prompt" | head -1 | cut -d: -f1)
task_line=$(grep -n 'TASK_PROMPT_TOKEN_44ee0a'      <<<"$rt_prompt" | head -1 | cut -d: -f1)
if [[ -n "$env_line" && -n "$floor_line" && -n "$ovr_line" && -n "$task_line" ]] \
   && (( env_line < floor_line && floor_line < ovr_line && ovr_line < task_line )); then
    printf '  PASS: section ordering env<floor<override<task\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: section ordering wrong (env=%s floor=%s override=%s task=%s)\n' \
        "$env_line" "$floor_line" "$ovr_line" "$task_line" >&2
    FAIL=$(( FAIL + 1 ))
fi

# The reply-to prompt is EXACTLY the default prompt plus the override block
# — nothing else moved. This is the additive-only assertion.
ovr_body=$(skill_section "Reply-to wrap-up override" | sed "s|<REQUEST_ID>|$RID|g")
printf '%s\n' "$ovr_body" > "$WORK/ovr.txt"
expected_rt=$(awk -v ovr="$WORK/ovr.txt" '
    /^TASK_PROMPT_TOKEN_44ee0a$/ && !inserted {
        while ((getline line < ovr) > 0) print line
        close(ovr); print ""; print "---"; print ""
        inserted = 1
    }
    { print }
' <<<"$default_prompt")
if [[ "$rt_prompt" == "$expected_rt" ]]; then
    printf '  PASS: --reply-to prompt == default prompt + override block (purely additive)\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: --reply-to prompt is not the default prompt plus the override block\n' >&2
    diff <(printf '%s\n' "$expected_rt") <(printf '%s\n' "$rt_prompt") >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- T3: --reply-to --issue = both surfaces ----------------------------

echo '=== T3: --reply-to --issue injects the both-surfaces command ==='

both=$(run_spawn -n t3-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        --reply-to "$RID" --issue 297 --print-prompt)
assert_contains "both-mode names the combined command" \
    "$both" "monitor/ng wrap-up --reply-to $RID --issue 297 <report-path>"
assert_contains "both-mode says BOTH surfaces" "$both" "BOTH surfaces"
assert_contains "both-mode still carries the base override" \
    "$both" "answers a CHANNEL request"

# ---- T4: dispatch-time request-id validation ---------------------------

echo '=== T4: --reply-to validates the id AT DISPATCH ==='

out=$(run_spawn -n t4-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        --reply-to no-such-request-id --print-prompt 2>&1); rc=$?
assert_eq       "unknown request id exits 16"        "$rc" "16"
assert_contains "unknown id names the inbox"         "$out" "does not resolve to any request"

out=$(run_spawn -n t4-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        --reply-to '../../etc/passwd' --print-prompt 2>&1); rc=$?
assert_eq       "path-traversal id exits 16"         "$rc" "16"
assert_contains "traversal id rejected on charset"   "$out" "[A-Za-z0-9_-]"

# A terminal request can never receive a reply — refuse at dispatch rather
# than let the worker discover it an hour later at wrap-up.
TERM_ID=$(file_request "t4-terminal")
mv "$FAKE_NEXUS/monitor/.state/requests/$TERM_ID.new.md" \
   "$FAKE_NEXUS/monitor/.state/requests/$TERM_ID.done.md"
out=$(run_spawn -n t4-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        --reply-to "$TERM_ID" --print-prompt 2>&1); rc=$?
assert_eq       "terminal (.done) request exits 16"  "$rc" "16"
assert_contains "terminal rejection names the state" "$out" "already terminal (state=done)"

# ---- T5: flag-shape errors ---------------------------------------------

echo '=== T5: --issue without --reply-to is refused ==='

out=$(run_spawn -n t5-win -c "$WORKDIR" -p "$PROMPT_FILE" --issue 42 --print-prompt 2>&1); rc=$?
assert_eq       "--issue alone exits 17"             "$rc" "17"
assert_contains "--issue alone explains why"         "$out" "only valid together with --reply-to"

out=$(run_spawn -n t5-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        --reply-to "$RID" --issue not-a-number --print-prompt 2>&1); rc=$?
assert_eq       "non-numeric --issue exits 17"       "$rc" "17"

out=$(run_spawn -n t5-win -c "$WORKDIR" -p "$PROMPT_FILE" --reply-to 2>&1); rc=$?
assert_eq       "--reply-to with no value exits 5 (usage)" "$rc" "5"

# ---- T6: missing override section fails loudly -------------------------

echo '=== T6: a skill file without the override section fails the spawn ==='

MUT_NEXUS="$WORK/nexus-mut"
cp -r "$FAKE_NEXUS" "$MUT_NEXUS"
awk '/^## Reply-to wrap-up override[[:space:]]*$/ { skip=1; next }
     skip && /^## / { skip=0 }
     !skip { print }' "$SKILL" > "$MUT_NEXUS/skills/nexus.worker-defaults/SKILL.md"
out=$(env -u NEXUS_ROOT -u NEXUS_STATE_DIR "$MUT_NEXUS/monitor/spawn-worker.sh" \
        -n t6-win -c "$WORKDIR" -p "$PROMPT_FILE" --reply-to "$RID" --print-prompt 2>&1); rc=$?
assert_eq       "missing override section exits 18"  "$rc" "18"
assert_contains "exit-18 message names the section"  "$out" "Reply-to wrap-up override"
# …but a DEFAULT spawn against the same mutated skill still works, proving
# the override section is not load-bearing for the fleet.
out=$(env -u NEXUS_ROOT -u NEXUS_STATE_DIR "$MUT_NEXUS/monitor/spawn-worker.sh" \
        -n t6-win -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt 2>&1); rc=$?
assert_eq       "default spawn unaffected by a missing override section" "$rc" "0"

# ---- summary ------------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
