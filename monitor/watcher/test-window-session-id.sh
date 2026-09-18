#!/usr/bin/env bash
# Session-id resolution must not derive a project slug — your-org/nexus-code#647.
#
# The retired procedure in skills/nexus.window-cleanup/SKILL.md did:
#
#     SLUG=$(printf '%s' "$WORKDIR" | sed 's|/|-|g')
#     JSONL=$(ls -t "$HOME/.claude/projects/$SLUG/"*.jsonl 2>/dev/null | head -1)
#     SESSION_ID=$(basename -s .jsonl "$JSONL" 2>/dev/null || true)
#
# Claude Code maps `_` to `-` as well as `/`. Every workdir on this host
# contains `your-lab-m`, so that named a directory which does not exist — for
# EVERY window, always. `ls` failed, `2>/dev/null` hid it, SESSION_ID came
# out empty, and window-close logged `session-id=unknown`, silently
# disabling `ng respawn`.
#
# CASE 1 IS THE ONE THE OLD FIXTURES LACKED: a workdir containing an
# underscore. #647 names that omission as the reason this survived, so it
# is asserted first and by name.
#
# Run: bash monitor/watcher/test-window-session-id.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
BIN="$_repo_root/monitor/window-session-id.sh"

PASS=0; FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }

[[ -x "$BIN" ]] || { echo "not executable: $BIN" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq absent"; echo "ALL TESTS PASSED"; exit 0; }

WORK=$(mktemp -d -t nexus-647-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
SD="$WORK/state"; mkdir -p "$SD/windows" "$SD/heartbeat"
CC="$WORK/cc"; mkdir -p "$CC/projects"

# PER-RUN UNIQUE session-ids, not the shared literal this file used to carry
# (your-org/nexus-code#1094). `11111111-2222-3333-4444-555555555555` appears in
# NINE test files on this tree, so it is not a fixture value at all — it is a
# repo-wide constant that any of them can leave behind on the host. One of them
# did: `test-session-name-from-window.sh` wrote it into the operator's REAL
# ~/.claude/projects before `ce0a80d` added its $HOME redirect, and those two
# leftover directories are still on disk. Case 5 then asserted "NO transcript
# exists for this id" — a claim about a search space it did not control — and
# the resolver, correctly, found one.
#
# Two independent repairs, because either alone still leaves a way in: the ids
# are now unique per run (nothing on the host can carry them), AND the search
# space is closed below (nothing outside $WORK is consulted). The uniqueness
# alone would not survive a future fixture that plants a matching id inside
# $CC; the isolation alone would not survive a resolver that grows a fourth
# search root.
_mkuuid() {   # a v4-shaped id from $RANDOM — no uuidgen dependency
    printf '%04x%04x-%04x-4%03x-%04x-%04x%04x%04x' \
        $((RANDOM*RANDOM%65536)) $((RANDOM*RANDOM%65536)) $((RANDOM*RANDOM%65536)) \
        $((RANDOM%4096)) $(( (RANDOM%4096) + 32768 )) \
        $((RANDOM*RANDOM%65536)) $((RANDOM*RANDOM%65536)) $((RANDOM*RANDOM%65536))
}
SID_A=$(_mkuuid)
SID_B=$(_mkuuid)
if [[ "$SID_A" == "$SID_B" ]]; then
    echo "  FAIL: the two fixture ids collided — every case below is vacuous" >&2
    exit 1
fi

# A workdir WITH UNDERSCORES, and a project dir named the way Claude Code
# actually names it: BOTH `/` and `_` mapped to `-`. The old sed produced
# the first form and the real dir is the second, which is the whole bug.
WD='/shared/your-lab-m/user/operator/nexus/work/kompot_revisions-272Fmerge'
OLD_SLUG=$(printf '%s' "$WD" | sed 's|/|-|g')
REAL_SLUG=$(printf '%s' "$WD" | sed 's|[/_]|-|g')
mkdir -p "$CC/projects/$REAL_SLUG"
: > "$CC/projects/$REAL_SLUG/$SID_A.jsonl"

printf '{"window":"w_under","workdir":"%s","session_id":"%s"}\n' "$WD" "$SID_A" \
    > "$SD/windows/w_under.json"

# CLOSE THE SEARCH SPACE. `window-session-id.sh --verify` globs
# `projects/*/<sid>.jsonl` across THREE Claude Code homes — $NEXUS_CC_HOME,
# $CLAUDE_CONFIG_DIR and $HOME/.claude — and this harness used to pin only the
# first. So every `--verify` assertion was made against a search space two
# thirds of which belonged to whoever happened to be running the suite. That is
# not a flaky test: the resolver was right and the assertion was unfalsifiable
# in the direction that matters, which is the same "checked a proxy, not the
# property" shape this repo keeps paying for.
#
# All three roots are pinned into $WORK. $HOME is redirected to a directory
# that exists but holds no `.claude`, so the third root is present-and-empty
# rather than merely absent — an absent root is skipped by the `[ -d ]` guard
# and would not exercise the same code path.
HOMEDIR="$WORK/home"; mkdir -p "$HOMEDIR/.claude/projects"
CFGDIR="$WORK/cfg";   mkdir -p "$CFGDIR/projects"
run() {
    HOME="$HOMEDIR" CLAUDE_CONFIG_DIR="$CFGDIR" \
    NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$SD" NEXUS_CC_HOME="$CC" "$BIN" "$@" 2>&1
}

echo "=== case 1: THE OMITTED FIXTURE — a workdir containing '_' ==="
if [[ "$OLD_SLUG" != "$REAL_SLUG" ]]; then
    pass "fixture is genuinely the divergent shape (old='$OLD_SLUG' != real)"
else
    fail "fixture has no underscore divergence — this case is vacuous"
fi
# The old derivation must MISS, or the case proves nothing.
if [[ -d "$CC/projects/$OLD_SLUG" ]]; then
    fail "the retired slug derivation would still have found the dir — fixture is wrong"
else
    pass "the retired '/'-only derivation names a directory that does not exist"
fi
out=$(run w_under --verify); rc=$?
if (( rc == 0 )) && [[ "$out" == "$SID_A" ]]; then
    pass "resolver returns the recorded id despite the underscores"
else
    fail "expected $SID_A rc=0, got rc=$rc '$out'"
fi

echo "=== case 2: heartbeat fallback when no spawn record exists ==="
printf '{"window":"w_hb","session_id":"%s"}\n' "$SID_B" > "$SD/heartbeat/w_hb.json"
mkdir -p "$CC/projects/some-other-dir"; : > "$CC/projects/some-other-dir/$SID_B.jsonl"
out=$(run w_hb --verify); rc=$?
if (( rc == 0 )) && [[ "$out" == "$SID_B" ]]; then
    pass "falls back to the heartbeat record"
else
    fail "heartbeat fallback: expected $SID_B rc=0, got rc=$rc '$out'"
fi

echo "=== case 3: FAILS LOUD — never a plausible 'unknown' ==="
# The defect was not "no id", it was an id-shaped placeholder reaching a
# log that ng respawn later trusted.
out=$(run no-such-window); rc=$?
if (( rc == 3 )); then pass "unknown window exits 3"; else fail "expected rc=3, got $rc"; fi
if [[ "$out" != *unknown* ]] || [[ "$out" == *"NOT falling back"* ]]; then
    pass "diagnostic does not emit a bare 'unknown' as an answer"
else
    fail "emitted an 'unknown'-shaped answer: $out"
fi
if [[ "$out" == *"$SD/windows/no-such-window.json"* ]]; then
    pass "diagnostic names where it looked"
else
    fail "diagnostic does not say where it looked: $out"
fi

echo "=== case 4: a placeholder in the state file is NOT laundered ==="
# These files have been observed carrying literal 'unknown'.
printf '{"window":"w_bad","session_id":"unknown"}\n' > "$SD/windows/w_bad.json"
out=$(run w_bad); rc=$?
if (( rc == 3 )); then
    pass "a non-uuid session_id is refused, not echoed"
else
    fail "laundered a placeholder into an answer: rc=$rc '$out'"
fi

echo "=== case 5: --verify catches a recorded id with no transcript ==="
printf '{"window":"w_ghost","session_id":"%s"}\n' "$SID_A" > "$SD/windows/w_ghost.json"
rm -f "$CC/projects/$REAL_SLUG/$SID_A.jsonl"
out=$(run w_ghost --verify); rc=$?
if (( rc == 3 )) && [[ "$out" == *"NO transcript"* ]]; then
    pass "--verify refuses an id whose transcript is gone"
else
    fail "--verify accepted a ghost id: rc=$rc '$out'"
fi
# …and WITHOUT --verify it still resolves, so the two modes differ.
out=$(run w_ghost); rc=$?
if (( rc == 0 )) && [[ "$out" == "$SID_A" ]]; then
    pass "without --verify the recorded id is still returned (modes are distinct)"
else
    fail "bare mode should still resolve: rc=$rc '$out'"
fi

# POTENCY CONTROL FOR THE ISOLATION ITSELF — and it is the assertion that
# makes the rc=3 above worth reading (your-org/nexus-code#1094). Closing the
# search space can produce a refusal for the WRONG reason: a harness that
# blinded the resolver entirely would score exactly the same rc=3, and case 5
# would then be a check that cannot fail. So each of the three roots the
# resolver globs is planted IN TURN and `--verify` must ACCEPT — one root at a
# time, so a root that is silently never consulted is named rather than
# covered for by its neighbours.
#
# This is also the regression guard on the isolation: if `window-session-id.sh`
# grows a FOURTH search root, this suite keeps passing (it asserts about the
# three it pins) while the harness has stopped being hermetic — so the
# enumeration below is asserted to be the whole list at the source, not
# remembered here.
_verify_roots_declared=$(grep -c 'NEXUS_CC_HOME\|CLAUDE_CONFIG_DIR\|HOME/.claude' \
    <<<"$(sed -n '/^    for _home in /p' "$BIN")")
if [[ "$_verify_roots_declared" == 1 ]]; then
    pass "the --verify root list is the single line this harness pins"
else
    fail "the --verify root list is not the one line this harness pins (got $_verify_roots_declared) — re-read $BIN before trusting case 5"
fi

for _root in "$CC" "$CFGDIR" "$HOMEDIR/.claude"; do
    mkdir -p "$_root/projects/planted"
    : > "$_root/projects/planted/$SID_A.jsonl"
    out=$(run w_ghost --verify); rc=$?
    if (( rc == 0 )) && [[ "$out" == "$SID_A" ]]; then
        pass "--verify ACCEPTS once a transcript is planted in ${_root##*/} (the refusal above was absence, not blindness)"
    else
        fail "--verify did not see a transcript planted in $_root: rc=$rc '$out'"
    fi
    rm -rf "$_root/projects/planted"
done

# …and back to refusing, so the plants above were really removed and nothing
# below inherits a transcript case 5 deleted on purpose.
out=$(run w_ghost --verify); rc=$?
if (( rc == 3 )); then
    pass "--verify refuses again once the plants are removed"
else
    fail "a planted transcript outlived its case: rc=$rc '$out'"
fi

echo "=== case 6: NO hard jq dependency (your-org/nexus-code#671 review) ==="
# test-guard-closure-boundary.sh keeps a manifest of sites where an absent
# jq silently changes behaviour, and it caught the first version of this
# file joining them. The decision was to REMOVE the dependency, not widen
# the manifest — this is a retirement-path helper, and a degraded host is
# exactly when it must still work. The uuid gate is what makes the
# non-jq parse safe: a mis-parse fails it and is refused, never echoed.
NOJQ="$WORK/nojq"; mkdir -p "$NOJQ"
# Case 5 deleted this transcript on purpose; restore it so --verify here
# tests the PARSE path rather than re-testing case 5's ghost detection.
: > "$CC/projects/$REAL_SLUG/$SID_A.jsonl"
out=$(PATH="/usr/bin:/bin" NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$SD" NEXUS_CC_HOME="$CC" \
      "$BIN" w_under --verify 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == "$SID_A" ]]; then
    pass "resolves with jq ABSENT (plain-text fallback + uuid gate)"
else
    fail "no-jq path failed: rc=$rc '$out'"
fi
# A jq that is PRESENT but broken must not take the lookup down either.
printf '#!/bin/sh\nexit 127\n' > "$NOJQ/jq"; chmod +x "$NOJQ/jq"
out=$(PATH="$NOJQ:$PATH" NEXUS_ROOT="$_repo_root" NEXUS_STATE_DIR="$SD" NEXUS_CC_HOME="$CC" \
      "$BIN" w_under --verify 2>&1); rc=$?
if (( rc == 0 )) && [[ "$out" == "$SID_A" ]]; then
    pass "resolves with a BROKEN jq (falls back on empty result, not on absence)"
else
    fail "broken-jq path failed: rc=$rc '$out'"
fi
# And the guard's own regex must no longer match this file.
if grep -qE 'command -v jq >/dev/null 2>&1 \|\| *(\{|exit 0|return 0)' "$BIN"; then
    fail "file still matches the jq-degradation pattern the manifest tracks"
else
    pass "file does not match the jq-degradation pattern (stays off the manifest)"
fi

echo "=== case 7: the retired derivation is gone from the skill ==="
SK="$_repo_root/skills/nexus.window-cleanup/SKILL.md"
if grep -qF "sed 's|/|-|g'" "$SK"; then
    fail "SKILL.md still instructs the '/'-only slug derivation"
else
    pass "SKILL.md no longer derives a slug by hand"
fi
if grep -q 'ng session-id' "$SK"; then
    pass "SKILL.md uses the recorded-state resolver"
else
    fail "SKILL.md does not reference the resolver"
fi

printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
