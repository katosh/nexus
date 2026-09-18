#!/usr/bin/env bash
# Unit tests for monitor/spawn-worker.sh prompt composition.
#
# Run: bash monitor/watcher/test-spawn-worker.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
#
# Strategy: build a fake NEXUS_ROOT containing only the files
# spawn-worker.sh needs (the worker-defaults SKILL.md with a
# `## Worker floor` section), then invoke the helper with
# `--print-prompt` to compose the prompt without touching tmux.
# Assert on the emitted prompt body.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_REAL="$_test_dir/../spawn-worker.sh"

# ---- HERMETIC ENV (your-org/nexus-code#655) -----------------------------
#
# This suite builds a FIXTURE nexus and invokes the fixture's copy of
# spawn-worker.sh. But #577's root resolution honours a VALID INHERITED
# $NEXUS_ROOT over its own script-relative root -- correctly, that is the
# whole point of #577 -- so an ambient NEXUS_ROOT silently redirects every
# prompt-composition assertion at the PRIMARY's floor, worker-settings and
# reports dir instead of the fixture's.
#
# Every nexus-spawned agent has NEXUS_ROOT exported, and CI does not: its
# cell is literally named `unit suite (NEXUS_ROOT unset)`. That single
# variable is #655's "dev red locally / green in CI", measured:
#
#     test-spawn-worker.sh          75 pass / 24 fail  ->  101 / 0
#     test-spawn-worker-resume.sh   55 pass / 48 fail  ->  103 / 0
#
# It is NOT the bash 4.4 vs 5.2 axis -- CI's dedicated 4.4 cell is green.
# Scrub it here so the suite means the same thing in both environments; a
# test whose verdict depends on the caller's exported env is not a test.
unset NEXUS_ROOT

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

# ---- the force-push PROPERTY predicate (your-org/nexus-code#835) --------
#
# Emits one line per UNQUALIFIED force-push prohibition found in the text
# it is given; emits NOTHING when every prohibition is scoped to a shared
# branch. It replaces a `assert_not_contains "never force-push;"` that was
# keyed on the one historical SPELLING: measured at 989b888, three planted
# blanket bans — including `In practice: never force-push, ever.` appended
# to the very same bullet as the carve-out — all passed the suite 145/0
# while the floor told every worker to refuse the rebase CI depends on.
#
# Method, stated so its ERROR DIRECTION is checkable rather than implied:
#   * flatten newlines (the floor is hand-wrapped prose, so a restored ban
#     arrives split across a line break),
#   * cut into SEGMENTS on `.;!?` — the segment is the qualification
#     window, chosen because a fixed ±N-character window leaks the
#     carve-out's own `**shared**` onto a ban appended right after it,
#   * a segment is an offender iff it names a force-push AND carries a
#     prohibition word AND carries no shared-vs-own discriminator.
#
# DIRECTION OF ERROR, restated after a skeptic pass measured the first cut
# wrong in BOTH directions (6 of 11 faithful blanket bans GREEN, and correct
# scoped text RED). Verified on a 13-segment corpus: 8 of 8 blanket bans
# DETECTED, 5 of 5 correctly-scoped texts CLEAN.
#
# It OVER-matches: a correctly scoped ban whose prohibition and whose
# qualifier sit in DIFFERENT sentences ("Never force-push. Your own PR
# branch is the exception.") is reported. That is the direction to err in
# — a false RED is read, a false GREEN is what this issue was reopened
# for. It UNDER-matches a ban expressed without negation at all ("always
# ask the operator before any force-push"), and it will clear a segment
# that merely MENTIONS `dev` or `main` for an unrelated reason — accepted
# deliberately, because naming the shared branches is the commonest correct
# scoping and a false RED on it is what drove the previous cut's rejection
# of correct text. Extend the word lists rather than widening the window.
_unqualified_force_push_bans() {
    printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | tr '.;!?' '\n\n\n\n' | awk '
        {
            raw = $0
            seg = " " tolower(raw) " "
            gsub(/[^a-z0-9]+/, " ", seg)
        }
        # NAMES A FORCE-PUSH — force-ish AND push-ish anywhere in the segment,
        # NOT an enumeration of adjacency spellings. The enumerated form missed
        # `--force` and `forced push` outright (they are not `force push`), so
        # six of eleven faithful blanket bans passed GREEN.
        seg !~ / force | forced | forcing | forcepush | forcepushing | fast forward / { next }
        seg !~ / push | pushes | pushing | pushed / { next }
        seg !~ / never | not | no | nor | forbid | forbids | forbidden | prohibit | prohibits | prohibited | ban | bans | banned | avoid | avoids | refuse | refuses | reject | rejects | unacceptable | must not | do not | dont / { next }
        # SCOPED — a shared-vs-own discriminator, OR the ban NAMES the shared
        # branches, which IS the scoping. Two corrections here:
        #   * ` shared ` alone was too weak: the HISTORICAL blanket ban
        #     (`Never force-push, ever — protecting the remote is a shared
        #     responsibility`) was silenced by an incidental `shared`. It is
        #     ` shared branch ` now.
        #   * naming `dev`/`main` was not recognised, so the clearest possible
        #     scoping (`never force-push \`dev\` or \`main\``) was reported as
        #     UNQUALIFIED — a false RED on correct text.
        seg ~  / shared branch | shared branches | someone else | another agent | other agents | not your own | others have | somebody else | your own | own pr | own branch | unshared | dev | main / { next }
        { gsub(/^[[:space:]]+|[[:space:]]+$/, "", raw); if (raw != "") print raw }
    '
}
assert_no_unqualified_force_push_ban() {
    local label="$1" hay="$2" offenders prc
    # This assertion PASSES on an empty result, so every way of producing
    # an empty result must be loud or it is a check that cannot fail
    # (your-org/nexus-code#1092, and #835's own retraction). Two of them:
    # an empty HAY (the caller's extraction returned nothing), and a
    # producer that DIED (awk/tr rc — the file is `set -o pipefail`, so
    # the substitution's status is the pipeline's).
    if [[ -z "$hay" ]]; then
        printf '  FAIL: %s — EMPTY text; this assertion could only pass VACUOUSLY, fix the CALLER\n' "$label" >&2
        FAIL=$(( FAIL + 1 )); return
    fi
    offenders=$(_unqualified_force_push_bans "$hay"); prc=$?
    if [[ "$prc" -ne 0 ]]; then
        printf '  FAIL: %s — predicate pipeline exited %s; an empty result here is NOT a clearance\n' "$label" "$prc" >&2
        FAIL=$(( FAIL + 1 )); return
    fi
    if [[ -z "$offenders" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — unqualified force-push prohibition(s):\n' "$label" >&2
        printf '        %s\n' "$offenders" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}
assert_predicate_fires() {
    local label="$1" hay="$2"
    if [[ -n "$(_unqualified_force_push_bans "$hay")" ]]; then
        printf '  PASS: %s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s — predicate stayed SILENT on a known blanket ban\n' "$label" >&2
        FAIL=$(( FAIL + 1 ))
    fi
}

# ---- harness ------------------------------------------------------------

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Scope spawn-worker.sh's launcher/prompt tempfiles (it honours
# TMPDIR) to a per-test dir: the launcher-body assertions below glob
# for spawn-launcher-<window>.*.sh, and against global /tmp a
# concurrent suite run's identically-named files satisfy the glob —
# then either run's `rm -f` deletes the other's file mid-assertion
# ("launcher tempfile not created", reproduced under 3 parallel
# suites). Exported so every $SCRIPT invocation inherits it.
SPAWN_TMP="$WORK/spawn-tmp"
mkdir -p "$SPAWN_TMP"
export TMPDIR="$SPAWN_TMP"

FAKE_NEXUS="$WORK/nexus"
mkdir -p "$FAKE_NEXUS/monitor" \
         "$FAKE_NEXUS/skills/nexus.worker-defaults" \
         "$FAKE_NEXUS/reports"
# spawn-worker.sh resolves NEXUS_ROOT from its own location
# (`$(dirname "$0")/..`), so we drop a copy of the real script into
# the fake nexus.
cp "$SCRIPT_REAL" "$FAKE_NEXUS/monitor/spawn-worker.sh"
chmod +x "$FAKE_NEXUS/monitor/spawn-worker.sh"
SCRIPT="$FAKE_NEXUS/monitor/spawn-worker.sh"

# spawn-worker.sh sources monitor/_claude-bin.sh to resolve $CLAUDE_BIN.
# Drop a copy + a stub claude under node_modules/.bin/ so the resolver
# finds the project-local path (mirrors the post-install layout).
cp "$_test_dir/../_claude-bin.sh" "$FAKE_NEXUS/monitor/_claude-bin.sh"
# spawn-worker.sh also sources monitor/_tmux-window.sh for robust
# window-id targeting (issue #323); the fake nexus needs it too.
cp "$_test_dir/../_tmux-window.sh" "$FAKE_NEXUS/monitor/_tmux-window.sh"
# And the shared frontmatter reader (#405 P2) for report resolution.
cp "$_test_dir/../_fm_lib.sh" "$FAKE_NEXUS/monitor/_fm_lib.sh"
# your-org/nexus-code#941 — spawn-worker sources monitor/_bookkeeping.sh for
# the injective window-key encoder (`wk_encode`). It is the WRITER for
# `windows/<key>.json` and the skeptic markers, so it refuses rather than
# writing under a key the readers will not look at.
cp "$_test_dir/../_bookkeeping.sh" "$FAKE_NEXUS/monitor/_bookkeeping.sh"
# The shim-guard TEMPLATE (your-org/nexus-code#589). spawn-worker.sh emits its
# launcher guard from monitor/guard-block.sh.in and REFUSES rather than
# emitting an empty block, so this fixture must supply it like any other hard
# dependency. (No assert helper is copied: absent under BOTH roots the
# launcher refuses, but this suite never RUNS a launcher — it inspects the
# generated prompt — so the guard is emitted and simply never executed.)
cp "$_test_dir/../guard-block.sh.in" "$FAKE_NEXUS/monitor/guard-block.sh.in"
# The #545 spawn-skeptic auto-ack step shells out to request-channel.sh
# (+ its lib) to ack the pending request when a --skeptic-role spawn runs.
cp "$_test_dir/../request-channel.sh" "$FAKE_NEXUS/monitor/request-channel.sh"
chmod +x "$FAKE_NEXUS/monitor/request-channel.sh"
cp "$_test_dir/../_channel_lib.sh" "$FAKE_NEXUS/monitor/_channel_lib.sh"
mkdir -p "$FAKE_NEXUS/node_modules/.bin"
cat > "$FAKE_NEXUS/node_modules/.bin/claude" <<'CLAUDE_STUB'
#!/bin/bash
echo "stub-claude: $*"
CLAUDE_STUB
chmod +x "$FAKE_NEXUS/node_modules/.bin/claude"

# Minimal worker-defaults SKILL.md with a recognisable floor body.
cat > "$FAKE_NEXUS/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
---
description: stub
---

# nexus.worker-defaults

## Preamble (not the floor — should not be injected)

This should not appear in the composed prompt.

## Worker floor

- Always greet the bot.
- Never push --no-verify.
- FLOOR_MARKER_TOKEN_a78b21

## After-floor section (should not be injected)

Trailing content; the awk extractor stops at the next `## ` H2.
EOF

WORKDIR="$FAKE_NEXUS"
PROMPT_FILE="$WORK/task-prompt.txt"
cat > "$PROMPT_FILE" <<'EOF'
TASK_PROMPT_TOKEN_44ee0a

Do the thing.
EOF

# Minimal worker-settings.json that spawn-worker.sh requires (exit 10
# without it). Tests that exercise the spawn path inherit this file;
# the "missing-file → exit 10" regression test removes it explicitly.
cat > "$FAKE_NEXUS/monitor/worker-settings.json" <<'EOF'
{
  "skipDangerousModePermissionPrompt": true,
  "hooks": {}
}
EOF

# ---- Test 1: --print-prompt happy path (no -r) ------------------------

echo '=== --print-prompt without -r emits floor + task only ==='
out=$("$SCRIPT" -n test-win -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 on happy path"           "$rc" "0"
assert_contains  "prompt has Worker environment"  "$out" "## Worker environment"
assert_contains  "prompt has Workdir line"        "$out" "- Workdir: $WORKDIR"
assert_contains  "prompt has Reports dir line"    "$out" "- Reports dir: $FAKE_NEXUS/reports"
assert_contains  "prompt embeds the floor body"   "$out" "FLOOR_MARKER_TOKEN_a78b21"
assert_contains  "prompt embeds the task prompt"  "$out" "TASK_PROMPT_TOKEN_44ee0a"
assert_not_contains "prompt skips the after-floor section" "$out" "Trailing content"
assert_not_contains "prompt has no Prior-context section"  "$out" "## Prior context"

# ---- Test 2: -r <absolute report path> injects Prior context ----------

REPORT="$FAKE_NEXUS/reports/prior-report.md"
cat > "$REPORT" <<'EOF'
---
project: nexus
date: 2026-05-12
---

# Prior worker's report

## Summary

PRIOR_REPORT_BODY_TOKEN_9c12f3

## How to Resume

Continue from commit 0xCAFEBABE.
EOF

echo '=== -r <absolute path> injects Prior context section ==='
out=$("$SCRIPT" -n test-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        -r "$REPORT" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -r absolute path"   "$rc" "0"
assert_contains  "prompt has Prior context header" "$out" "## Prior context"
assert_contains  "prompt embeds the prior body"    "$out" "PRIOR_REPORT_BODY_TOKEN_9c12f3"
assert_contains  "prompt cites the report path"    "$out" "Path: $REPORT"
assert_contains  "prompt still has the floor"      "$out" "FLOOR_MARKER_TOKEN_a78b21"
assert_contains  "prompt still has the task"       "$out" "TASK_PROMPT_TOKEN_44ee0a"

# Order: env → prior → floor → task. Verify Prior context appears
# between Workdir and the floor marker.
env_line=$(grep -n '## Worker environment' <<<"$out" | head -1 | cut -d: -f1)
prior_line=$(grep -n '## Prior context' <<<"$out" | head -1 | cut -d: -f1)
floor_line=$(grep -n 'FLOOR_MARKER_TOKEN_a78b21' <<<"$out" | head -1 | cut -d: -f1)
task_line=$(grep -n 'TASK_PROMPT_TOKEN_44ee0a' <<<"$out" | head -1 | cut -d: -f1)
if [[ -n "$env_line" && -n "$prior_line" && -n "$floor_line" && -n "$task_line" ]] \
   && (( env_line < prior_line && prior_line < floor_line && floor_line < task_line )); then
    printf '  PASS: section ordering env<prior<floor<task\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: section ordering wrong (env=%s prior=%s floor=%s task=%s)\n' \
        "$env_line" "$prior_line" "$floor_line" "$task_line" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 3: -r <relative-to-NEXUS_ROOT> resolves ---------------------

echo '=== -r <relative path> resolves against NEXUS_ROOT ==='
out=$("$SCRIPT" -n test-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        -r "reports/prior-report.md" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -r relative path"      "$rc" "0"
assert_contains  "prompt embeds the prior body"      "$out" "PRIOR_REPORT_BODY_TOKEN_9c12f3"

# ---- Test 4: -r missing path → exit 9 ---------------------------------

echo '=== -r <missing path> → exit 9 ==='
out=$("$SCRIPT" -n test-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        -r "$WORK/nope-report.md" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 9 on missing prior-report"    "$rc" "9"
assert_contains  "stderr names the missing report"   "$out" \
                 "prior-report not readable"

# ---- Test 5: spawn issues set-window-option remain-on-exit + seeds anchors
#
# Issue #72 retain-persistence + lifecycle-anchor changes. We stub tmux
# AND ng so the spawn-worker.sh execution path is exercised end-to-end
# without actually touching tmux or the file system's action log. The
# stub records every invocation to a log file; we then assert the
# expected calls appear.

echo '=== spawn issues tmux set-window-option remain-on-exit on ==='

STUB_BIN="$WORK/stub-bin"
mkdir -p "$STUB_BIN"
STUB_LOG="$WORK/tmux-calls.log"
: > "$STUB_LOG"

cat > "$STUB_BIN/tmux" <<STUB
#!/bin/bash
printf '%s\n' "tmux \$*" >> "$STUB_LOG"
case "\$1" in
    info) exit 0 ;;
    list-windows) exit 0 ;;  # no windows → collision check passes
    # spawn-worker captures the window id from new-window -P and targets
    # every later op by that @id (#323). Emit a deterministic fake id so
    # the assertions below can match the -t @7 form. (No backticks in
    # this comment: the heredoc is unquoted, so they would run as a
    # command substitution at stub-creation time.)
    new-window) echo '@7'; exit 0 ;;
    set-window-option) exit 0 ;;
    send-keys) exit 0 ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$STUB_BIN/tmux"

# Stub ng so the spawn-time `log-action spawn` call doesn't blow up
# on missing nexus.yml in the fake nexus root.
mkdir -p "$FAKE_NEXUS/monitor"
cat > "$FAKE_NEXUS/monitor/ng" <<NGSTUB
#!/bin/bash
printf '%s\n' "ng \$*" >> "$STUB_LOG"
exit 0
NGSTUB
chmod +x "$FAKE_NEXUS/monitor/ng"

# Invoke the real spawn-worker.sh with stubs on PATH.
out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n integ-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq        "spawn exits 0"                                   "$rc" "0"
log_contents=$(cat "$STUB_LOG")
assert_contains "tmux new-window invoked"                "$log_contents" "tmux new-window"
assert_contains "remain-on-exit set on new window"       "$log_contents" \
                 "set-window-option -t @7 remain-on-exit on"
# Phantom-•bell fix: spawn must disable tmux auto-rename + OSC-driven
# rename on the new window so dead worker panes don't get retitled
# (to `•bell`, `bash`, etc.) and pollute the watcher's tmux snapshot.
# Both knobs are required: automatic-rename governs tmux's own
# pane_current_command + dead-state rename, allow-rename governs
# whether the inner pane is permitted to set the title via OSC.
assert_contains "automatic-rename disabled on new window" "$log_contents" \
                 "set-window-option -t @7 automatic-rename off"
assert_contains "allow-rename disabled on new window"     "$log_contents" \
                 "set-window-option -t @7 allow-rename off"
assert_contains "ng log-action spawn fired"              "$log_contents" \
                 "ng log-action monitor --event spawn"
# Engagement-log row should have been seeded directly.
ELOG="$FAKE_NEXUS/monitor/.state/engagement-log.tsv"
if [[ -f "$ELOG" ]] && grep -qF $'integ-win\t' "$ELOG"; then
    printf '  PASS: engagement-log row seeded\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: engagement-log row missing for integ-win\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# Spawn-prompt cache should have been written (PR #131 follow-up,
# tier-3/4 subject-issue discovery fallback). Composition includes
# the worker floor + task body, so the cached file content should
# contain both a Worker environment header and the task prompt.
SPAWN_CACHE="$FAKE_NEXUS/monitor/.state/spawn-prompts/integ-win.txt"
if [[ -f "$SPAWN_CACHE" ]]; then
    printf '  PASS: spawn-prompt cache file written (%s)\n' "$SPAWN_CACHE"; PASS=$(( PASS + 1 ))
    cache_body=$(<"$SPAWN_CACHE")
    assert_contains "cache carries Worker environment header"     "$cache_body" "## Worker environment"
    assert_contains "cache carries task prompt body"               "$cache_body" "TASK_PROMPT_TOKEN_44ee0a"
else
    printf '  FAIL: spawn-prompt cache missing at %s\n' "$SPAWN_CACHE" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Change 1: ordinary worker is NOT pre-warned of a skeptic ----------
# The env-header must carry NO `- Skeptic mode:` / `- Skeptic role:` line
# for an ordinary worker, even one spawned with --skeptic require — the
# worker learns of the skeptic only at wrap-up. Asserted on the env
# header specifically (the floor's role-pointer bullet legitimately names
# `Skeptic role:`, so scope the check to the lines before the first `---`).
echo '=== Change 1: ordinary worker env header carries no skeptic line ==='
ord_out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n ord-win -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic require --print-prompt 2>/dev/null)
ord_env=$(printf '%s\n' "$ord_out" | sed -n '1,/^---$/p')
assert_not_contains "ordinary env header has no '- Skeptic mode:' line" "$ord_env" "- Skeptic mode:"
assert_not_contains "ordinary env header has no '- Skeptic role:' line" "$ord_env" "- Skeptic role:"

# ---- Change 1/2: a --skeptic-role spawn DOES carry the role line + the
#      skeptic_orig provenance (defaults to target) -----------------------
echo '=== role spawn: env header role line + skeptic_orig provenance ==='
role_out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n role-win -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic-role --skeptic-target orig-task --print-prompt 2>/dev/null)
role_env=$(printf '%s\n' "$role_out" | sed -n '1,/^---$/p')
assert_contains "role spawn env header carries 'Skeptic role: YES'" "$role_env" "Skeptic role: YES"

# Full spawn (with stubs) writes provenance; skeptic_orig defaults to the
# target when --skeptic-orig is omitted, and is the threaded root when set.
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n role-prov -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic-role --skeptic-target orig-task >/dev/null 2>&1
ROLE_PROV="$FAKE_NEXUS/monitor/.state/windows/role-prov.json"
if [[ -f "$ROLE_PROV" ]]; then
    assert_eq "skeptic_orig defaults to target" \
        "$(jq -r '.skeptic_orig' "$ROLE_PROV")" "orig-task"
else
    printf '  FAIL: role-prov provenance record missing at %s\n' "$ROLE_PROV" >&2
    FAIL=$(( FAIL + 1 ))
fi
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n role-prov2 -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic-role --skeptic-target sk-prior --skeptic-orig orig-task >/dev/null 2>&1
ROLE_PROV2="$FAKE_NEXUS/monitor/.state/windows/role-prov2.json"
if [[ -f "$ROLE_PROV2" ]]; then
    assert_eq "skeptic_orig threads the explicit chain root" \
        "$(jq -r '.skeptic_orig' "$ROLE_PROV2")" "orig-task"
else
    printf '  FAIL: role-prov2 provenance record missing at %s\n' "$ROLE_PROV2" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- skeptic-pending marker (RE-)established at skeptic spawn -----------
# A --skeptic-role spawn must (re-)create the skeptic-pending markers for
# the windows it reviews. This is what restores the retire-block + the
# parked-awaiting-skeptic exemption for a genuinely-spawned second pass
# (ng wrap-up's verdict path no longer re-asserts them speculatively — that
# was the marker leak). A FIRST-pass spawn writes pending/<target>; a
# RECURSIVE spawn (--skeptic-orig != target) writes BOTH pending/<target>
# and pending/<orig>.
echo '=== skeptic-role spawn (re-)establishes skeptic-pending markers ==='
SKPEND="$FAKE_NEXUS/monitor/.state/skeptic/pending"
if [[ -f "$SKPEND/orig-task" ]]; then
    printf '  PASS: first-pass spawn creates pending/<target>\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: first-pass spawn did NOT create %s\n' "$SKPEND/orig-task" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -f "$SKPEND/sk-prior" ]]; then
    printf '  PASS: recursive spawn creates pending/<target>\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: recursive spawn did NOT create %s\n' "$SKPEND/sk-prior" >&2
    FAIL=$(( FAIL + 1 ))
fi
# role-prov2 carried --skeptic-orig orig-task, so the orig marker exists too
# (role-prov's earlier spawn already created pending/orig-task; assert the
# recursive path keeps the chain root parked).
if [[ -f "$SKPEND/orig-task" ]]; then
    printf '  PASS: recursive spawn keeps pending/<orig> (chain root) parked\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: recursive spawn did NOT keep %s\n' "$SKPEND/orig-task" >&2
    FAIL=$(( FAIL + 1 ))
fi
# An ordinary (non-role) worker spawn must NOT create a skeptic-pending
# marker — the marker means "a skeptic is required or actively reviewing",
# not "a worker exists". (require-mode markers are written by ng wrap-up,
# not by the spawn.)
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n plain-no-mark -c "$WORKDIR" -p "$PROMPT_FILE" >/dev/null 2>&1
if [[ ! -f "$SKPEND/plain-no-mark" ]]; then
    printf '  PASS: ordinary spawn writes no skeptic-pending marker\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: ordinary spawn unexpectedly wrote %s\n' "$SKPEND/plain-no-mark" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- #545: a --skeptic-role spawn AUTO-ACKS the pending spawn-skeptic
#      request whose origin == the reviewed target window ----------------
# ng wrap-up files a `kind=spawn-skeptic` request (origin=<reviewed
# window>) to PUSH the orchestrator to spawn the skeptic; spawning it IS
# the ack, so spawn-worker.sh closes the loop. Join key: request.origin ==
# skeptic-spawn.target-window. Pre-file a request for a fresh target, spawn
# the role, assert the request is now terminal (.done) — and that an
# UNRELATED request (different origin, or non-skeptic kind) is untouched.
echo '=== #545: skeptic-role spawn auto-acks the matching spawn-skeptic request ==='
CHAN="$FAKE_NEXUS/monitor/request-channel.sh"
REQ_DIR="$FAKE_NEXUS/monitor/.state/requests"
mkdir -p "$REQ_DIR"
# The request whose origin is the window we're about to review.
ACK_ID=$(NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state" \
    printf 'spawn-skeptic: validate ackme-worker\n\nissue: o/r#1\ndepth: 1\n' \
    | NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state" "$CHAN" file \
        --origin ackme-worker --kind spawn-skeptic --slug skeptic-d1 --priority normal - 2>/dev/null)
# A control request from a DIFFERENT origin — must survive.
OTHER_ID=$(printf 'spawn-skeptic: validate other-worker\n\ndepth: 1\n' \
    | NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state" "$CHAN" file \
        --origin other-worker --kind spawn-skeptic --slug skeptic-d1 --priority normal - 2>/dev/null)
# A control request from the SAME origin but a different kind — must survive.
QKIND_ID=$(printf 'a plain question from ackme-worker\n' \
    | NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state" "$CHAN" file \
        --origin ackme-worker --kind question --slug ask --priority normal - 2>/dev/null)

PATH="$STUB_BIN:$PATH" NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state" \
    "$SCRIPT" -n ackme-skeptic -c "$WORKDIR" -p "$PROMPT_FILE" \
    --skeptic-role --skeptic-target ackme-worker >/dev/null 2>&1

ack_state=$(NEXUS_STATE_DIR="$FAKE_NEXUS/monitor/.state" "$CHAN" list --state done 2>/dev/null | grep -c "$ACK_ID")
if [[ -f "$REQ_DIR/$ACK_ID.done.md" ]]; then
    printf '  PASS: matching spawn-skeptic request auto-acked to .done\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: request %s not acked (states: %s)\n' "$ACK_ID" \
        "$(ls "$REQ_DIR/$ACK_ID".*.md 2>/dev/null)" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ ! -f "$REQ_DIR/$OTHER_ID.done.md" ]]; then
    printf '  PASS: unrelated-origin request left untouched\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: unrelated-origin request %s was wrongly acked\n' "$OTHER_ID" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ ! -f "$REQ_DIR/$QKIND_ID.done.md" ]]; then
    printf '  PASS: same-origin non-skeptic request left untouched\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: same-origin question request %s was wrongly acked\n' "$QKIND_ID" >&2
    FAIL=$(( FAIL + 1 ))
fi

# --print-prompt mode MUST NOT write the cache (it skips the spawn
# path entirely, by design — no window, no cache).
PRINT_CACHE_NAME="print-only-win"
PRINT_CACHE="$FAKE_NEXUS/monitor/.state/spawn-prompts/$PRINT_CACHE_NAME.txt"
rm -f "$PRINT_CACHE"
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n "$PRINT_CACHE_NAME" -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt >/dev/null 2>&1
if [[ ! -f "$PRINT_CACHE" ]]; then
    printf '  PASS: --print-prompt does NOT write spawn-prompt cache\n'; PASS=$(( PASS + 1 ))
else
    printf '  FAIL: --print-prompt unexpectedly wrote %s\n' "$PRINT_CACHE" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 6: launcher carries --settings <worker-settings.json> --------

echo '=== launcher invokes claude --settings $NEXUS_ROOT/monitor/worker-settings.json ==='
: > "$STUB_LOG"
out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n settings-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq "spawn exits 0 with settings file present" "$rc" "0"
assert_contains "spawn stderr advertises settings path" "$out" \
                "settings=$FAKE_NEXUS/monitor/worker-settings.json"
launcher_files=( "$SPAWN_TMP"/spawn-launcher-settings-win.*.sh )
if [[ -e "${launcher_files[0]}" ]]; then
    launcher_body=$(cat "${launcher_files[@]}")
    assert_contains "launcher carries --settings flag with the repo path" \
                    "$launcher_body" "--settings $FAKE_NEXUS/monitor/worker-settings.json"
    # Belt-and-braces: no tempfile name should leak through.
    if grep -qE -- "--settings /tmp/spawn-hooks-" <<<"$launcher_body"; then
        printf '  FAIL: launcher references a tempfile settings path (should be the repo file)\n' >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: launcher does NOT reference a tempfile settings path\n'
        PASS=$(( PASS + 1 ))
    fi
    rm -f "${launcher_files[@]}"
else
    printf '  FAIL: launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 7: missing worker-settings.json → exit 10 --------------------

echo '=== missing monitor/worker-settings.json → exit 10 ==='
# Move the settings file aside so the existence check fails. Restore
# it after the test so subsequent tests (loop-wrapper, default-shape)
# see a present file again.
mv "$FAKE_NEXUS/monitor/worker-settings.json" "$FAKE_NEXUS/monitor/worker-settings.json.bak"
out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n missing-settings-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq      "exit 10 when worker-settings.json absent"  "$rc" "10"
assert_contains "stderr names the missing settings file"  "$out" \
                "worker-settings.json missing"
mv "$FAKE_NEXUS/monitor/worker-settings.json.bak" "$FAKE_NEXUS/monitor/worker-settings.json"

# ---- Test 7b: shipped monitor/worker-settings.json carries the bypass flag ----

echo '=== shipped monitor/worker-settings.json sets skipDangerousModePermissionPrompt: true ==='
# Verifies the real file (not the test stub) carries the key that
# suppresses the bypass-permissions startup dialog. If a future edit
# drops the flag, fresh-worker-dir spawns regress to wedging on the
# dialog and case-D in _unstick.sh would have to come back.
REAL_SETTINGS="$_test_dir/../worker-settings.json"
if [[ -f "$REAL_SETTINGS" ]]; then
    if python3 -c "import json,sys; sys.exit(0 if json.load(open('$REAL_SETTINGS')).get('skipDangerousModePermissionPrompt') is True else 1)"; then
        printf '  PASS: shipped worker-settings.json sets skipDangerousModePermissionPrompt=true\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: shipped worker-settings.json missing skipDangerousModePermissionPrompt=true\n' >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # And it must be valid JSON top-to-bottom.
    if python3 -c "import json; json.load(open('$REAL_SETTINGS'))" 2>/dev/null; then
        printf '  PASS: shipped worker-settings.json parses as valid JSON\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: shipped worker-settings.json is not valid JSON\n' >&2
        FAIL=$(( FAIL + 1 ))
    fi
else
    printf '  FAIL: shipped worker-settings.json not found at %s\n' "$REAL_SETTINGS" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 7c: the scancel + multi-push rules ride the JIT footgun hook ----
#
# B13 (your-org/your-nexus#236) required these two safety-grade rules to
# reach every worker. The worker-floor redesign moves them OUT of the
# always-injected prompt (where they diluted the task) and INTO the
# just-in-time footgun hook, which injects the reminder at the exact
# `git push` / `scancel --name` tool call. The rules still reach the
# worker — via `bash-footgun-patterns.conf` + `bash-footgun-guard.sh`,
# not the prompt. Assert their new home so a regression that drops them
# entirely still fails.

echo '=== scancel + multi-push safety rules live in the footgun conf/hook ==='
FOOTGUN_CONF="$_test_dir/../../monitor/bash-footgun-patterns.conf"
FOOTGUN_HOOK="$_test_dir/../../monitor/hooks/bash-footgun-guard.sh"
REAL_FLOOR_SKILL="$_test_dir/../../skills/nexus.worker-defaults/SKILL.md"
if [[ -f "$FOOTGUN_CONF" ]]; then
    conf_body=$(cat "$FOOTGUN_CONF")
    assert_contains "footgun conf pins each git push to its clone (git -C)" \
                    "$conf_body" "git -C <clone> push"
    assert_contains "footgun conf mandates scancel by job-id, not --name" \
                    "$conf_body" "scancel <jobid>"
    assert_contains "footgun conf matches the scancel --name over-match" \
                    "$conf_body" "scancel\b[^0-9]*--name"
else
    printf '  FAIL: bash-footgun-patterns.conf not found at %s\n' "$FOOTGUN_CONF" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -x "$FOOTGUN_HOOK" ]]; then
    printf '  PASS: bash-footgun-guard.sh present and executable\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: bash-footgun-guard.sh missing or not executable at %s\n' "$FOOTGUN_HOOK" >&2
    FAIL=$(( FAIL + 1 ))
fi
# The redesign REMOVED these from the always-injected floor body — assert
# the slimming actually happened (guards against a silent revert that
# re-bloats the prompt).
if [[ -f "$REAL_FLOOR_SKILL" ]]; then
    floor_body=$(awk '/^## Worker floor$/{f=1;next} /^## /{f=0} f' "$REAL_FLOOR_SKILL")
    assert_not_contains "slim floor no longer inlines the git -C push rule" \
                    "$floor_body" "git -C <clone> push"
    assert_not_contains "slim floor no longer inlines the scancel rule" \
                    "$floor_body" "scancel <jobid>"
fi

# ---- Test 7d: the force-push BOUNDARY, not a blanket ban (#835) --------
#
# The floor used to say "never force-push", flat. That contradicted the
# merge gate, which REQUIRES a rebase onto the current base before merge:
# a `pull_request` run is computed against a merge ref built at run
# creation and `rerun-failed-jobs` reuses that same stale ref, so a later
# green can describe a base that has moved — and rebasing onto the current
# base makes the push non-fast-forward.
#
# NOTE: an earlier version of this comment said "only a NEW HEAD
# re-evaluates". That was REFUTED by experiment — the merge ref is
# DEMAND-TRIGGERED, recomputed when something queries the PR's
# mergeability (measured: stale for 26h and 36h; refreshed within two
# minutes of one GET). The carve-out is unaffected: a rebase still makes
# the push non-fast-forward. Only the mechanism sentence was wrong.
# (And that sentence is a MODEL with a measured exception — a GET refreshed
# `mergeable` while the ref's base stayed put — see monitor/_merge_ref_base.sh
# and your-org/nexus-code#923 before leaning on one-GET-refreshes-it.)
#
# The blanket ban is the dangerous regression here, because it READS as
# correct: a reviewer restoring it sees a safety rule being tightened, not
# a rule that tells every worker to refuse a rebase CI depends on. Hence
# an explicit negative assertion rather than trusting review.

echo '=== force-push: floor carries the boundary, hook carries the how (#835) ==='
if [[ -f "$REAL_FLOOR_SKILL" ]]; then
    floor_body=$(awk '/^## Worker floor$/{f=1;next} /^## /{f=0} f' "$REAL_FLOOR_SKILL")
    # The carve-out must be present and must be SCOPED. "shared" is the
    # load-bearing word: without it the sentence licenses force-pushing dev.
    assert_contains "floor scopes the ban to a SHARED branch" \
                    "$floor_body" "force-push a **shared** branch"
    assert_contains "floor still names dev and main as shared" \
                    "$floor_body" '(`dev`, `main`'
    # The discriminator must be OBSERVABLE. An author-keyed one is not:
    # every agent here commits with the operator's identity, so "another
    # author's commits" has no referent a worker can check (#835 skeptic).
    assert_contains "floor keys the boundary on a CHECKABLE property" \
                    "$floor_body" "someone else has pushed commits to"
    assert_not_contains "floor does NOT key the boundary on AUTHORSHIP" \
                    "$floor_body" "another author's commits"
    assert_contains "floor licenses the rebase force-push on your OWN branch" \
                    "$floor_body" "PR branch after rebasing it onto the current base is expected"
    # ---- THE PROPERTY, not a spelling (#835 reopening) -----------------
    #
    # This used to be `assert_not_contains "never force-push;"` and it was
    # the sentence a close of #835 rested on ("the assert_not_contains
    # above is what should catch it first"). It could not. It keyed on the
    # ONE historical spelling, so at 989b888 the shipped guard scored
    # 145 passed / 0 failed with a blanket ban planted in the floor, three
    # different ways. The property the floor must hold is: EVERY
    # force-push prohibition it carries is scoped to a SHARED branch.
    assert_no_unqualified_force_push_ban \
        "floor carries NO unqualified force-push prohibition" "$floor_body"

    # The predicate's own liveness, asserted rather than assumed. A
    # property check that quietly stopped matching would report the floor
    # clean forever — the exact failure it replaces. These four are the
    # regression fixtures named in #835's reopening comment: three planted
    # blanket bans that the spelling-keyed assertion passed, plus the
    # historical wording from 371b5bd^ that it did catch.
    assert_predicate_fires "predicate fires: ban appended to the carve-out bullet" \
        'In practice: never force-push, ever.'
    assert_predicate_fires "predicate fires: blanket ban in a fresh bullet" \
        '- **Do not ever force push.** Fix the root cause instead.'
    assert_predicate_fires "predicate fires: blanket ban wrapped across lines" \
        'Under no circumstances may you force push to any
  branch, ever.'
    assert_predicate_fires "predicate fires: the historical 371b5bd^ wording" \
        'Never `--no-verify`, never force-push; fix the root cause.'
    # …and does NOT fire on the shipped scoped sentence in isolation, so a
    # green above is a measurement and not a predicate that matches nothing.
    assert_no_unqualified_force_push_ban \
        "predicate silent on the scoped carve-out sentence" \
        'Never `--no-verify`; never force-push a **shared** branch (`dev`,
  `main`, or any branch someone else has pushed commits to) —
  force-pushing your **own** PR branch after rebasing it onto the
  current base is expected.'

    # The two historical SPELLING checks are kept as cheap regression
    # fixtures for the exact text that shipped before 371b5bd. They are
    # SUBSUMED by the property assertion above and must never again be
    # cited as the thing that catches a returning ban.
    floor_flat=$(printf '%s' "$floor_body" | tr '\n' ' ' | tr -s ' ')
    assert_not_contains "floor does NOT carry the blanket 'never force-push;' (spelling fixture)" \
                    "$floor_flat" "never force-push;"
    assert_not_contains "floor does NOT carry the old 'no-verify, never' blanket (spelling fixture)" \
                    "$floor_flat" '`--no-verify`, never force-push'
    # The floor states the boundary only — the runnable precondition is the
    # hook's job. Keeping it out is what holds the per-spawn token cost down.
    assert_not_contains "floor does NOT inline the precondition command" \
                    "$floor_body" "origin/dev..HEAD"
fi

# The floor is not the only prose surface that describes it. #835's
# reopening found `docs/operating/spawning-workers.md` describing the
# INJECTED floor as "no `--no-verify`, no force-push" — unqualified —
# in the same file that carries the correctly scoped form a few lines
# later, and both of the close's enumeration keys were structurally
# blind to it (one classified whole FILES, the other keyed on the
# historical spelling). The property predicate asks the sentence-level
# question, so it sees it: run at 989b888 it names that sentence, and
# it stays silent on the orchestrator's destructive-instruction
# denylist in the same file, which merely LISTS `force push` as a
# trigger word and prohibits nothing.
SPAWN_DOC="$_test_dir/../../docs/operating/spawning-workers.md"
echo '=== force-push: the operator DOC describes the same boundary (#835) ==='
if [[ -f "$SPAWN_DOC" ]]; then
    assert_no_unqualified_force_push_ban \
        "spawning-workers.md carries NO unqualified force-push prohibition" \
        "$(cat "$SPAWN_DOC")"
    assert_contains "spawning-workers.md scopes the ban to a SHARED branch" \
                    "$(cat "$SPAWN_DOC")" 'force-push to a *shared* branch'
else
    printf '  FAIL: %s\n' "spawning-workers.md missing — cannot check the doc surface" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -f "$FOOTGUN_CONF" ]]; then
    conf_body=$(cat "$FOOTGUN_CONF")
    assert_contains "footgun conf points at the FAIL-CLOSED checker" \
                    "$conf_body" "monitor/force-push-check.sh <your git push args>"
    assert_contains "footgun conf warns the hand-rolled form is vacuous when blind" \
                    "$conf_body" "FOUR measured false-clearance modes"
    assert_contains "footgun conf warns the author check cannot see a sibling" \
                    "$conf_body" "an AUTHOR check cannot see a sibling"
    assert_contains "footgun conf says --force-with-lease does not backstop it" \
                    "$conf_body" "lease is satisfied by the very fetch"
    assert_contains "footgun conf explains why a new head is required" \
                    "$conf_body" "after rebasing it onto the current base is EXPECTED"
    assert_contains "footgun conf prefers --force-with-lease" \
                    "$conf_body" "force-with-lease"
    # ROW ORDER is load-bearing: bash-footgun-guard.sh takes the FIRST
    # matching row, and the generic `git-push` regex matches every
    # force-push too. If the force-push rows drift below it, a force-push
    # silently receives the generic cwd-leak reminder instead of the
    # boundary — no error, no failing match, just the wrong advice at the
    # one moment it matters. Compare line numbers, not mere presence.
    fp_line=$(grep -n '^force-push|' "$FOOTGUN_CONF" | head -1 | cut -d: -f1)
    gp_line=$(grep -n '^git-push|'   "$FOOTGUN_CONF" | head -1 | cut -d: -f1)
    if [[ -n "$fp_line" && -n "$gp_line" ]] && (( fp_line < gp_line )); then
        printf '  PASS: force-push rows precede the generic git-push row (first match wins)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: force-push row must precede git-push (force-push=%s git-push=%s)\n' \
            "${fp_line:-none}" "${gp_line:-none}" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # The conf's FIELD SEPARATOR is `|`, so a regex field holding a bare `|`
    # is silently TRUNCATED at that byte — the row still parses, matches
    # something narrower than intended, and nothing errors. Assert the
    # property structurally rather than by row count: field 3 of every row
    # must contain no bare `|`. (`\p` is the hook's literal-pipe escape and
    # is substituted after splitting, so it is legal and must be tolerated.)
    bare_pipe_rows=$(awk -F'|' '/^[a-z]/ { if ($3 ~ /\|/) print }' "$FOOTGUN_CONF" | wc -l)
    if [[ "$bare_pipe_rows" -eq 0 ]]; then
        printf '  PASS: no conf regex field contains a bare `|` (would truncate silently)\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: %s conf row(s) have a `|` in the regex field — use `\\p`\n' "$bare_pipe_rows" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    # All three force forms must be covered. `+refspec` is the one that
    # matters most: `git push origin +dev` IS the forbidden act (#835 skeptic).
    # Compare the REGEX FIELDS as fixed strings — the forms are themselves
    # regex source, so matching them as patterns re-reads `[a-zA-Z]` as a
    # bracket expression and silently never matches.
    fp_regexes=$(awk -F'|' '/^force-push\|/ { print $3 }' "$FOOTGUN_CONF")
    while IFS= read -r _form; do
        [ -n "$_form" ] || continue
        if grep -qF -- "$_form" <<<"$fp_regexes"; then
            printf '  PASS: force-push row covers %s\n' "$_form"; PASS=$(( PASS + 1 ))
        else
            printf '  FAIL: no force-push row covers %s\n' "$_form" >&2; FAIL=$(( FAIL + 1 ))
        fi
    done <<'FORMS'
--force
[[:space:]]-[a-zA-Z]*f
[[:space:]]\+
FORMS
fi

# ---- Test 8: loop-wrapper opt-in switches the launcher shape -----------
#
# Issue #75. When MONITOR_RETAIN_USE_LOOP_WRAPPER=1, the launcher
# generated by spawn-worker.sh should `exec monitor/claude-loop.sh`
# instead of invoking claude directly. We don't run it (the test
# stubs tmux so nothing actually executes), only inspect the file.

echo '=== MONITOR_RETAIN_USE_LOOP_WRAPPER=1 ⇒ launcher invokes claude-loop.sh ==='

# Drop a stub claude-loop.sh next to the spawn-worker so its NEXUS_ROOT
# resolves to a real file. Content doesn't matter — the launcher just
# needs the path to exist for inspection assertions.
cat > "$FAKE_NEXUS/monitor/claude-loop.sh" <<'LOOPSTUB'
#!/usr/bin/env bash
echo "claude-loop-stub: $*"
LOOPSTUB
chmod +x "$FAKE_NEXUS/monitor/claude-loop.sh"

: > "$STUB_LOG"
out=$(MONITOR_RETAIN_USE_LOOP_WRAPPER=1 \
      PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n loop-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq      "spawn-with-loop exits 0"               "$rc"           "0"
assert_contains "spawn stderr advertises loop=on"       "$out"          "loop=on"
loop_launcher_files=( "$SPAWN_TMP"/spawn-launcher-loop-win.*.sh )
if [[ -e "${loop_launcher_files[0]}" ]]; then
    launcher_body=$(cat "${loop_launcher_files[@]}")
    assert_contains "launcher exec's claude-loop.sh"   "$launcher_body" "exec \"\$NEXUS_ROOT/monitor/claude-loop.sh\""
    assert_contains "launcher passes --window"         "$launcher_body" "--window \"loop-win\""
    assert_contains "launcher passes --prompt-file"    "$launcher_body" "--prompt-file"
    # remain-on-exit is still set (orthogonal): the loop wrapper does
    # respawns, but if it ever exits we still want pane history.
    loop_log_contents=$(cat "$STUB_LOG")
    assert_contains "remain-on-exit set on loop window" "$loop_log_contents" \
                    "set-window-option -t @7 remain-on-exit on"
    assert_contains "automatic-rename disabled on loop window" "$loop_log_contents" \
                    "set-window-option -t @7 automatic-rename off"
    assert_contains "allow-rename disabled on loop window"     "$loop_log_contents" \
                    "set-window-option -t @7 allow-rename off"
    rm -f "${loop_launcher_files[@]}"
else
    printf '  FAIL: loop launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# Default (no env, no config knob) should still emit the direct
# `claude --dangerously-skip-permissions` shape — back-compat.
echo '=== default (no opt-in) keeps the direct claude launcher shape ==='
: > "$STUB_LOG"
out=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n direct-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq      "spawn-default exits 0"                 "$rc"           "0"
if [[ "$out" == *"loop=on"* ]]; then
    printf '  FAIL: default spawn announced loop=on (should be off)\n' >&2
    FAIL=$(( FAIL + 1 ))
else
    printf '  PASS: default spawn stderr does NOT advertise loop=on\n'
    PASS=$(( PASS + 1 ))
fi
direct_launcher_files=( "$SPAWN_TMP"/spawn-launcher-direct-win.*.sh )
if [[ -e "${direct_launcher_files[0]}" ]]; then
    launcher_body=$(cat "${direct_launcher_files[@]}")
    if grep -qF "claude-loop.sh" <<<"$launcher_body"; then
        printf '  FAIL: default launcher unexpectedly references claude-loop.sh\n' >&2
        FAIL=$(( FAIL + 1 ))
    else
        printf '  PASS: default launcher invokes claude directly\n'
        PASS=$(( PASS + 1 ))
    fi
    # `$CLAUDE_BIN` resolves to the project-local install at write time,
    # so the launcher contains `"/abs/.../claude" --dangerously...`.
    if [[ "$launcher_body" =~ \"?[^\ ]*claude\"?\ --dangerously-skip-permissions ]]; then
        printf '  PASS: default launcher carries <CLAUDE_BIN> --dangerously-skip-permissions\n'
        PASS=$(( PASS + 1 ))
    else
        printf '  FAIL: default launcher missing <CLAUDE_BIN> --dangerously-skip-permissions in body=%q\n' "$launcher_body" >&2
        FAIL=$(( FAIL + 1 ))
    fi
    rm -f "${direct_launcher_files[@]}"
else
    printf '  FAIL: direct launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 8b: --model threads into BOTH launcher shapes (issue #433) ----
#
# Opt-in per-worker model pin. With --model <id> the generated launcher
# must carry `--model "<id>"` — appended to the claude-loop.sh args in
# the loop shape, and to the direct claude invocation otherwise. With
# the flag omitted the launcher must carry NO --model token at all
# (default-off; the byte-identical guarantee is asserted on the
# invocation line here, full-file byte-diff was done at review time).

echo '=== --model <id> lands in the loop-shape launcher (value form) ==='
: > "$STUB_LOG"
out=$(MONITOR_RETAIN_USE_LOOP_WRAPPER=1 \
      PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n model-loop-win -c "$WORKDIR" -p "$PROMPT_FILE" \
      --model claude-fable-5 2>&1)
rc=$?
assert_eq       "spawn --model (loop shape) exits 0"     "$rc" "0"
model_loop_files=( "$SPAWN_TMP"/spawn-launcher-model-loop-win.*.sh )
if [[ -e "${model_loop_files[0]}" ]]; then
    launcher_body=$(cat "${model_loop_files[@]}")
    assert_contains "loop launcher execs claude-loop.sh"  "$launcher_body" \
                    "exec \"\$NEXUS_ROOT/monitor/claude-loop.sh\""
    assert_contains "loop launcher carries quoted --model" "$launcher_body" \
                    "--model \"claude-fable-5\""
    rm -f "${model_loop_files[@]}"
else
    printf '  FAIL: model loop launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== --model=<id> lands in the direct-shape launcher (= form) ==='
: > "$STUB_LOG"
out=$(PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n model-direct-win -c "$WORKDIR" -p "$PROMPT_FILE" \
      --model=claude-fable-5 2>&1)
rc=$?
assert_eq       "spawn --model= (direct shape) exits 0"  "$rc" "0"
model_direct_files=( "$SPAWN_TMP"/spawn-launcher-model-direct-win.*.sh )
if [[ -e "${model_direct_files[0]}" ]]; then
    launcher_body=$(cat "${model_direct_files[@]}")
    assert_contains "direct launcher carries quoted --model" "$launcher_body" \
                    "--dangerously-skip-permissions --model \"claude-fable-5\""
    rm -f "${model_direct_files[@]}"
else
    printf '  FAIL: model direct launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== no --model ⇒ launcher carries NO --model token (default-off) ==='
: > "$STUB_LOG"
out=$(PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n nomodel-win -c "$WORKDIR" -p "$PROMPT_FILE" 2>&1)
rc=$?
assert_eq       "spawn without --model exits 0"          "$rc" "0"
nomodel_files=( "$SPAWN_TMP"/spawn-launcher-nomodel-win.*.sh )
if [[ -e "${nomodel_files[0]}" ]]; then
    launcher_body=$(cat "${nomodel_files[@]}")
    assert_not_contains "default launcher has no --model" "$launcher_body" "--model"
    rm -f "${nomodel_files[@]}"
else
    printf '  FAIL: nomodel launcher tempfile not created\n' >&2
    FAIL=$(( FAIL + 1 ))
fi

echo '=== bare --model (no value) ⇒ usage error, no silent default ==='
out=$(PATH="$STUB_BIN:$PATH" \
      "$SCRIPT" -n bare-model-win -c "$WORKDIR" -p "$PROMPT_FILE" --model 2>&1)
rc=$?
assert_eq       "bare --model exits 5 (usage)"           "$rc" "5"
assert_contains "stderr names the missing model value"   "$out" \
                "--model requires a value"

# ---- Test 9: -c $NEXUS_ROOT emits root-cwd warning ---------------------
#
# Layered on top of the spawn safety floor: when the orchestrator
# passes the primary clone as the worker's cwd, spawn-worker.sh
# should warn on stderr AND inject a one-line note into the
# composed prompt. Subdirectories of NEXUS_ROOT (work/<project>,
# work/<project>-<task>) stay silent — the check is exact-equality
# only.

echo '=== -c $NEXUS_ROOT → root-cwd warning fires on stderr + in prompt ==='

# Symmetric harness: build a tmp worktree dir at $FAKE_NEXUS/work/
# foo so the negative case (warning silent on a worktree path) has
# an actual sibling-of-NEXUS_ROOT directory to point at.
mkdir -p "$FAKE_NEXUS/work/foo"

# (a) Warning fires when -c equals NEXUS_ROOT exactly.
out=$("$SCRIPT" -n root-cwd-win -c "$FAKE_NEXUS" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -c \$NEXUS_ROOT"            "$rc" "0"
assert_contains  "stderr carries root-cwd warning header" "$out" \
                 "spawn-worker.sh: warn: -c resolves to nexus primary clone"
assert_contains  "warning references the nexus primary clone path" "$out" "($FAKE_NEXUS)"
assert_contains  "warning points at skills/nexus.tmux-spawn"  "$out" \
                 "skills/nexus.tmux-spawn/SKILL.md \"secondary clones\""
assert_contains  "prompt injects the cwd nudge"            "$out" \
                 "Note: your cwd is the nexus primary clone"
assert_contains  "nudge mentions worktree command form"    "$out" \
                 "git worktree add"

# (b) Warning silent when -c is a subdirectory (worktree convention).
out=$("$SCRIPT" -n worktree-cwd-win -c "$FAKE_NEXUS/work/foo" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -c subdirectory"            "$rc" "0"
assert_not_contains "no root-cwd warning on a subdirectory" "$out" \
                 "spawn-worker.sh: warn: -c resolves to nexus primary clone"
assert_not_contains "no nudge injected into prompt on subdirectory" "$out" \
                 "Note: your cwd is the nexus primary clone"

# (c) Warning silent when -c is a symlink that resolves to a
# subdirectory of NEXUS_ROOT (defensive: cd "$WORKDIR" && pwd
# resolves symlinks, so symlink-to-worktree is fine).
ln -sfn "$FAKE_NEXUS/work/foo" "$WORK/foo-link"
out=$("$SCRIPT" -n symlink-cwd-win -c "$WORK/foo-link" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "exit 0 with -c symlink-to-subdir"       "$rc" "0"
assert_not_contains "no root-cwd warning on symlink-to-subdir" "$out" \
                 "resolves to nexus primary clone"

# ---- Test 10: the shell-trap callouts ride the JIT footgun hook --------
#
# B9 of your-org/your-nexus#236 (U9) required the floor to warn about pipe
# block-buffering, foreground `sleep` blocked → Monitor, and `ml`-into-pipe
# eval-loss. The worker-floor redesign moves these OUT of the always-injected
# prompt and INTO the footgun hook: foreground-sleep is a conf row; the two
# PIPE-triggered traps (python…|tail, ml…|pipe) can't live in the |-delimited
# conf, so they are matched in-code in bash-footgun-guard.sh. Assert the
# guidance still reaches the worker from its new home.

echo '=== shell-trap callouts live in the footgun conf/hook ==='
FOOTGUN_CONF="$_test_dir/../../monitor/bash-footgun-patterns.conf"
FOOTGUN_HOOK="$_test_dir/../../monitor/hooks/bash-footgun-guard.sh"
if [[ -f "$FOOTGUN_CONF" ]]; then
    conf_body=$(cat "$FOOTGUN_CONF")
    assert_contains "footgun conf warns foreground sleep blocked → Monitor" \
                    "$conf_body" "Foreground \`sleep\` is blocked"
else
    printf '  FAIL: bash-footgun-patterns.conf not found at %s\n' "$FOOTGUN_CONF" >&2
    FAIL=$(( FAIL + 1 ))
fi
if [[ -f "$FOOTGUN_HOOK" ]]; then
    hook_body=$(cat "$FOOTGUN_HOOK")
    assert_contains "footgun hook matches python…|tail block-buffering" \
                    "$hook_body" "python -u"
    assert_contains "footgun hook matches ml/module-into-pipe eval-loss" \
                    "$hook_body" "ml-pipe"
else
    printf '  FAIL: bash-footgun-guard.sh not found at %s\n' "$FOOTGUN_HOOK" >&2
    FAIL=$(( FAIL + 1 ))
fi

# ---- Test 7: the stateful arg parser (your-org/nexus-code#568 D11 + B7) ----
#
# TWO gaps this closes, both in the same ~155-line hand-rolled state machine:
#
#   D11: `--topic` was the ONLY flag with zero test references anywhere in the
#        suite — neither its value form nor its missing-value error branch.
#   B7:  nothing anywhere asserted what happens when a flag's VALUE ITSELF
#        LOOKS LIKE A FLAG (`--topic --model`). That is the classic failure of
#        a `for arg in "$@"` parser that cannot `shift`: the "expecting a
#        value" state has to be threaded by hand through eleven separate
#        `expect_*_val` variables, and the one case that distinguishes a
#        correct implementation from a subtly wrong one was untested. Writing
#        it FIRST is what makes the collapse to a `while`/`shift` loop provable
#        rather than hopeful.
#
# `--print-prompt` is the seam: it runs the whole parser and exits before any
# tmux/spawn side effect, so these are pure, fast parser assertions.

echo '=== arg parser: value-taking flags, incl. values that look like flags ==='

parse_out() {  # parse_out <args...> → stdout of a --print-prompt run
    PATH="$STUB_BIN:$PATH" "$SCRIPT" -n parser-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        --print-prompt "$@" 2>/dev/null
}
parse_err() {  # parse_err <args...> → "<rc>|<stderr>"
    local e r
    e=$(PATH="$STUB_BIN:$PATH" "$SCRIPT" -n parser-win -c "$WORKDIR" -p "$PROMPT_FILE" \
        --print-prompt "$@" 2>&1 >/dev/null); r=$?
    printf '%s|%s' "$r" "$e"
}

# your-org/nexus-code#1471: `--dry-run` outside `--resume` used to be SET, never
# READ, and the script fell through to a REAL spawn — the one flag meaning
# "take no action" performed the action. Now refused (exit 22) before anything
# is composed. Asserted on the SIDE EFFECT too: a stub-tmux spawn attempt must
# leave no `new-window` in the call log, because the bug's signature was a
# SUCCESSFUL spawn, not an exit code.
r=$(parse_err --dry-run)
case "$r" in
    22\|*"--dry-run is only meaningful with --resume"*) printf '  PASS: #1471 --dry-run without --resume is REFUSED (exit 22) with its own message\n'; PASS=$(( PASS + 1 )) ;;
    *) printf '  FAIL: #1471 --dry-run without --resume: expected exit 22 + message, got %s\n' "$r" >&2; FAIL=$(( FAIL + 1 )) ;;
esac
: > "$STUB_LOG"
PATH="$STUB_BIN:$PATH" "$SCRIPT" -n dryrun-win -c "$WORKDIR" -p "$PROMPT_FILE" --dry-run >/dev/null 2>&1; r=$?
assert_eq "#1471 a real spawn attempt with --dry-run exits 22" "$r" "22"
assert_not_contains "#1471 …and creates NO window (the side effect, not the code, is the assertion)" "$(cat "$STUB_LOG")" "new-window"
# The parser's default arm used to PASS THROUGH an unrecognised long option, so
# a typo (`--dryrun`, `--skpetic-role`) became an ordinary spawn with the
# intended behaviour absent. Refused now (exit 23); bare positionals and short
# options still flow to getopts (the CONTROL below).
r=$(parse_err --dryrun)
case "$r" in
    23\|*"unknown option '--dryrun'"*) printf '  PASS: #1471 an unrecognised --long option is REFUSED (exit 23), not passed through\n'; PASS=$(( PASS + 1 )) ;;
    *) printf '  FAIL: #1471 --dryrun: expected exit 23 + message, got %s\n' "$r" >&2; FAIL=$(( FAIL + 1 )) ;;
esac
out=$(parse_out --topic control-topic); r=$?
assert_eq "#1471 CONTROL: a declared long option still parses (rc 0)" "$r" "0"
r=$(parse_err --resume=some-window --dry-run)
case "$r" in
    22\|*) printf '  FAIL: #1471 CONTROL: --dry-run WITH --resume must not hit the exit-22 refusal, got %s\n' "$r" >&2; FAIL=$(( FAIL + 1 )) ;;
    *) printf '  PASS: #1471 CONTROL: --dry-run WITH --resume passes the refusal (whatever resume then says is resume'"'"'s business)\n'; PASS=$(( PASS + 1 )) ;;
esac

# D11: --topic in both spellings must be consumed, not leaked into the prompt
# body as a positional.
out=$(parse_out --topic refactor-the-parser)
assert_not_contains "--topic <value> is consumed, not treated as prompt text" \
                    "$out" "refactor-the-parser"
out=$(parse_out --topic=refactor-the-parser)
assert_not_contains "--topic=<value> is consumed, not treated as prompt text" \
                    "$out" "refactor-the-parser"

# D11: the missing-value error branch (spawn-worker.sh's `--topic requires a
# value`) had no coverage at all.
r=$(parse_err --topic)
case "$r" in
    0\|*) printf '  FAIL: bare --topic should be an error, exited 0\n' >&2; FAIL=$(( FAIL + 1 )) ;;
    *"--topic requires a value"*) printf '  PASS: bare --topic errors with its own message\n'; PASS=$(( PASS + 1 )) ;;
    *) printf '  FAIL: bare --topic: unexpected result %s\n' "$r" >&2; FAIL=$(( FAIL + 1 )) ;;
esac

# B7's proof gap: a value that is itself flag-shaped. The parser is stateful,
# so `--topic --model` MUST consume `--model` AS THE TOPIC VALUE (the state
# machine is in "expecting a value"), and must NOT re-interpret it as the
# --model flag. Whatever the parser does here is its contract; assert it, so a
# rewrite has something to preserve.
r=$(parse_err --topic --model)
case "$r" in
    *"--model requires a value"*)
        printf '  FAIL: --topic --model: the value was re-read as a flag (state machine leaked)\n' >&2
        FAIL=$(( FAIL + 1 )) ;;
    0\|*) printf '  PASS: --topic --model consumes "--model" AS the topic value (stateful, no re-dispatch)\n'
        PASS=$(( PASS + 1 )) ;;
    *) printf '  FAIL: --topic --model: unexpected result %s\n' "$r" >&2; FAIL=$(( FAIL + 1 )) ;;
esac

# Same shape on the other value-taking flags, so the whole family is pinned.
for flag in --kind --model --issue --reply-to --skeptic --skeptic-depth; do
    r=$(parse_err "$flag")
    case "$r" in
        0\|*) printf '  FAIL: bare %s should be an error, exited 0\n' "$flag" >&2; FAIL=$(( FAIL + 1 )) ;;
        *"$flag requires a"*) printf '  PASS: bare %s errors with its own message\n' "$flag"; PASS=$(( PASS + 1 )) ;;
        *) printf '  FAIL: bare %s: unexpected result %s\n' "$flag" "$r" >&2; FAIL=$(( FAIL + 1 )) ;;
    esac
done

# ══ your-org/nexus-code#814: the clone-freshness block ═════════════════════
#
# A worker pinned into a stale clone draws a repo-wide NEGATIVE from an object
# store missing the commits that would refute it. The prompt now carries how
# old the clone's knowledge of its remote is — and specifically NOT
# `.git/FETCH_HEAD` mtime, which #814 proposed and then disproved: a FAILED
# fetch truncates it to zero bytes and updates its mtime, so it reads fresher
# than the tree is in exactly the failure case that matters.
#
# The FETCH_HEAD case below is the load-bearing one. It builds a clone that is
# genuinely 1 commit behind, points it at an unreachable remote, fails a fetch
# (so FETCH_HEAD is zero bytes with a BRAND-NEW mtime), and asserts the emitted
# block still reports the OLD ref. A regression to the mtime probe passes every
# other assertion here and fails this one.
echo '=== #814: the prompt carries the clone freshness block ==='
FRESH_ROOT="$WORK/freshness"
mkdir -p "$FRESH_ROOT"
git init -q "$FRESH_ROOT/upstream"
git -C "$FRESH_ROOT/upstream" config user.email t@t
git -C "$FRESH_ROOT/upstream" config user.name t
echo one > "$FRESH_ROOT/upstream/a"
git -C "$FRESH_ROOT/upstream" add -A
# Back-dated, not `sleep`-separated. The FETCH_HEAD control below compares the
# file's mtime (now) against this commit's date, and at real-clock speed the
# whole fixture lands inside ONE second — the first draft tied at
# 1786185465 == 1786185465 and went red on a `>`. A fixed old date makes the
# comparison deterministic instead of a race the suite would lose occasionally
# and blame on load.
GIT_AUTHOR_DATE='2020-01-01T00:00:00 +0000' \
GIT_COMMITTER_DATE='2020-01-01T00:00:00 +0000' \
    git -C "$FRESH_ROOT/upstream" commit -qm one
git -C "$FRESH_ROOT/upstream" branch -M main
git clone -q "$FRESH_ROOT/upstream" "$FRESH_ROOT/clone" 2>/dev/null
git -C "$FRESH_ROOT/clone" config user.email t@t
git -C "$FRESH_ROOT/clone" config user.name t
STALE_SHA=$(git -C "$FRESH_ROOT/clone" rev-parse --short origin/main)

out=$("$SCRIPT" -n fresh-win -c "$FRESH_ROOT/clone" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "#814 --print-prompt still exits 0"   "$rc" "0"
assert_contains  "#814 the block is present"           "$out" "Clone freshness"
assert_contains  "#814 it reports the remote-tracking ref"    "$out" "origin/main"
assert_contains  "#814 it reports the ref's SHA"       "$out" "$STALE_SHA"
assert_contains  "#814 it states the negative-claim rule" "$out" \
                 "ONLY AS OLD AS THAT DATE"
assert_contains  "#814 it names the local-object-store trap" "$out" \
                 "git log --all"
# NO "newest remote-tracking ref anywhere" line — see the F2 case below for why
# that claim was removed rather than qualified.
assert_not_contains "#814 F2 no falsifiable \"bound on your knowledge\" claim" \
                 "$out" "newest remote-tracking ref"

echo '=== #814 THE REFUTATION: a failed fetch must NOT make the clone look fresh ==='
# Advance upstream so the clone is genuinely behind, then break the remote and
# fail a fetch — the shape #814 measured (`x-access-token` URL, "Invalid
# username or token").
echo two > "$FRESH_ROOT/upstream/b"
git -C "$FRESH_ROOT/upstream" add -A
git -C "$FRESH_ROOT/upstream" commit -qm two
NEW_SHA=$(git -C "$FRESH_ROOT/upstream" rev-parse --short HEAD)
git -C "$FRESH_ROOT/clone" remote set-url origin "$FRESH_ROOT/does-not-exist"
GIT_TERMINAL_PROMPT=0 git -C "$FRESH_ROOT/clone" fetch origin >/dev/null 2>&1
FH="$FRESH_ROOT/clone/.git/FETCH_HEAD"
FH_SIZE=$(stat -c %s "$FH" 2>/dev/null || echo missing)
assert_eq        "#814 CONTROL: the failed fetch truncated FETCH_HEAD to 0 bytes" \
                 "$FH_SIZE" "0"
# …and its mtime is now NEWER than the ref it is supposed to describe. This is
# the measurement that kills the mtime probe; assert it rather than assert it
# in prose.
FH_MTIME=$(stat -c %Y "$FH" 2>/dev/null || echo 0)
REF_MTIME=$(git -C "$FRESH_ROOT/clone" log -1 --format=%ct origin/main 2>/dev/null || echo 0)
if (( FH_MTIME > REF_MTIME )); then
    printf '  PASS: #814 CONTROL: FETCH_HEAD mtime is NEWER than the ref it describes\n'
    PASS=$(( PASS + 1 ))
else
    printf '  FAIL: #814 CONTROL: expected FETCH_HEAD mtime (%s) > ref date (%s)\n' \
        "$FH_MTIME" "$REF_MTIME" >&2
    FAIL=$(( FAIL + 1 ))
fi

out=$("$SCRIPT" -n fresh-win2 -c "$FRESH_ROOT/clone" -p "$PROMPT_FILE" --print-prompt 2>&1)
assert_contains  "#814 the block STILL reports the stale ref after a failed fetch" \
                 "$out" "$STALE_SHA"
assert_not_contains "#814 …and does NOT report the unfetched upstream commit" \
                 "$out" "$NEW_SHA"
assert_contains  "#814 the block warns against the FETCH_HEAD mtime probe" \
                 "$out" "FETCH_HEAD"

echo '=== #814 F2: a clone that PUSHED but never fetched must NOT read fresh ==='
# Skeptic finding F2, the one that would not merge. `git push` writes
# refs/remotes/origin/<branch> LOCALLY without fetching anything, so any signal
# derived from remote-tracking ref dates advances on the worker's own push while
# the clone learns nothing — a LOCAL operation moving a REMOTE-knowledge
# indicator, the same shape as the FETCH_HEAD mtime probe this block rejects,
# and falsified in the OPTIMISTIC direction.
#
# This is the fixture that control was missing: the clone is genuinely blind to
# upstream commits, then does exactly what every nexus worker does — branch,
# commit, push -u.
git -C "$FRESH_ROOT/clone" remote set-url origin "$FRESH_ROOT/upstream"
git -C "$FRESH_ROOT/clone" checkout -q -b operator/mytask
echo mine > "$FRESH_ROOT/clone/mine"
git -C "$FRESH_ROOT/clone" add -A
git -C "$FRESH_ROOT/clone" commit -qm "my work"
git -C "$FRESH_ROOT/clone" push -q -u origin operator/mytask 2>/dev/null
# Ground truth: the clone still cannot see the upstream commit made earlier.
PUSH_BLIND=$(git -C "$FRESH_ROOT/clone" cat-file -e "$NEW_SHA" 2>/dev/null && echo NO || echo YES)
assert_eq        "#814 F2 CONTROL: the clone really is blind to upstream" "$PUSH_BLIND" "YES"

out=$("$SCRIPT" -n pushed-win -c "$FRESH_ROOT/clone" -p "$PROMPT_FILE" --print-prompt 2>&1)
assert_contains  "#814 F2 the block still reports the STALE default-branch sha" \
                 "$out" "$STALE_SHA"
assert_not_contains "#814 F2 …and never the unfetched upstream commit" "$out" "$NEW_SHA"
# The load-bearing negative: nothing in the block may present the worker's own
# push as evidence of remote knowledge.
assert_not_contains "#814 F2 no \"bound on your knowledge\" claim survives" \
                 "$out" "cannot know anything the remote did after this"
# And the resolution order must not have picked the pushed branch.
assert_not_contains "#814 F2 the pushed feature branch is not the primary line" \
                 "$out" "resolved via @{upstream}"
assert_contains  "#814 F2 the default branch is what is reported"      "$out" \
                 "resolved via origin/HEAD"

echo '=== #814: a clone with NO remote says UNKNOWN, not fresh ===''
# The silent-absence arm. #814 suggested a hardcoded `origin/main`, which emits
# NOTHING in a repo that has no such ref — the same defect class one level up.
git init -q "$FRESH_ROOT/noremote"
git -C "$FRESH_ROOT/noremote" config user.email t@t
git -C "$FRESH_ROOT/noremote" config user.name t
git -C "$FRESH_ROOT/noremote" commit -q --allow-empty -m x
out=$("$SCRIPT" -n nrem-win -c "$FRESH_ROOT/noremote" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "#814 no-remote clone still exits 0"  "$rc" "0"
assert_contains  "#814 no-remote says NONE RESOLVED"   "$out" "NONE RESOLVED"
assert_contains  "#814 …and calls it UNKNOWN, not fresh" "$out" "is UNKNOWN, not fresh"

echo '=== #814: a non-git workdir degrades cleanly, does not break the spawn ==='
mkdir -p "$FRESH_ROOT/plain"
out=$("$SCRIPT" -n plain-win -c "$FRESH_ROOT/plain" -p "$PROMPT_FILE" --print-prompt 2>&1)
rc=$?
assert_eq        "#814 non-git workdir still exits 0"  "$rc" "0"
assert_contains  "#814 non-git workdir says so"        "$out" "NOT A GIT REPOSITORY"
assert_contains  "#814 CONTROL: the rest of the prompt is intact" "$out" \
                 "FLOOR_MARKER_TOKEN_a78b21"

echo '=== #814: the REAL worker floor carries the negative-claim rule ==='
# #814 item 2. Asserted against the REAL skills file, not the fake floor this
# suite injects: the composed-prompt assertions above use a fixture floor, so
# they would pass with the rule absent from the thing that actually ships.
# Extract the same way spawn-worker.sh does — `## Worker floor` to the next H2
# — so a rule that drifts BELOW that boundary (and therefore never reaches a
# worker) goes red rather than passing on a whole-file grep.
REAL_FLOOR=$(awk '
  /^## Worker floor[[:space:]]*$/ { in_floor = 1; next }
  in_floor && /^## / { exit }
  in_floor { print }
' "$_test_dir/../../skills/nexus.worker-defaults/SKILL.md" 2>/dev/null)
# Whitespace-squeezed, because the floor is hard-wrapped prose: asserting a
# phrase that happens to straddle a line break makes the test a hostage to
# reflow, and "reflow the paragraph" would then read as a real regression.
REAL_FLOOR_FLAT=$(printf '%s' "$REAL_FLOOR" | tr '\n' ' ' | tr -s ' ')
assert_contains  "#814 the shipped floor states the fetch-age rule" "$REAL_FLOOR_FLAT" \
                 "only as old as its last fetch"
assert_contains  "#814 …and names the local-object-store readers by name" "$REAL_FLOOR" \
                 "git log --all"
assert_contains  "#814 …and refuses the FETCH_HEAD mtime probe" "$REAL_FLOOR" \
                 "FETCH_HEAD"
# Skeptic infra item 1: the rule named only the READ side of the family. The
# WRITE side — your own push makes your clone look fresh — is the one an agent
# triggers by following this floor's own instruction to push its branch.
assert_contains  "#814 F2 …and names the WRITE side of the family too" \
                 "$REAL_FLOOR_FLAT" "your own \`git push\`"

# ---- your-org/nexus-code#1153: a skeptic-NAMED window spawned without --skeptic-role is WARNED
# A window named like a skeptic but spawned bare writes no linkage record, so
# its target reads "NO live skeptic" and is walked toward retirement while the
# review is in progress. Warning only, on stderr; the prompt is still composed.
_o1153=$("$SCRIPT" -n dolimeth-sk -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt 2>&1 >/dev/null)
assert_contains "#1153 a '-sk' window without --skeptic-role gets a WARNING naming the flag" \
                "$_o1153" "WITHOUT --skeptic-role"
_o1153=$("$SCRIPT" -n dolimethsk2 -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt 2>&1 >/dev/null)
assert_contains "#1153 …and so does the hyphen-less 'sk2' spelling this board actually uses" \
                "$_o1153" "WITHOUT --skeptic-role"
_o1153=$("$SCRIPT" -n dolimeth -c "$WORKDIR" -p "$PROMPT_FILE" --print-prompt 2>&1 >/dev/null)
assert_eq "#1153 CONTROL: a plain window name is not warned" "$(grep -c 'WITHOUT --skeptic-role' <<<"$_o1153" || true)" "0"
_o1153=$("$SCRIPT" -n dolimeth-sk -c "$WORKDIR" -p "$PROMPT_FILE" --skeptic-role --skeptic-target dolimeth --print-prompt 2>&1 >/dev/null)
assert_eq "#1153 CONTROL: the same name WITH --skeptic-role is not warned" "$(grep -c 'WITHOUT --skeptic-role' <<<"$_o1153" || true)" "0"

# ---- summary ----------------------------------------------------------

echo
echo "=== summary: $PASS passed, $FAIL failed ==="
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
exit 1
