#!/usr/bin/env bash
# test-spawn-worker-state-dir.sh — spawn-worker.sh must honour $NEXUS_STATE_DIR
# for EVERY state path it writes (your-org/nexus-code#973).
#
# ---------------------------------------------------------------------------
# THE DEFECT
# ---------------------------------------------------------------------------
#
# $NEXUS_STATE_DIR is this repo's isolation knob. `ng` documents it as the
# "test escape hatch" and resolves it FIRST (_resolve_state_dir); 36 files
# honour it, and `setup_fake_nexus` EXPORTS it into every fixture precisely so
# that "the wrong thing has to be impossible, not discouraged" (#833).
#
# monitor/spawn-worker.sh honoured it NOWHERE. At e256d4a the file contained
# ZERO references to the variable and pinned all twelve of its state paths to
# `$NEXUS_ROOT/monitor/.state` directly. So a fixture that pinned the state dir
# — believing itself isolated, because that is what the knob means everywhere
# else — still had spawn-worker.sh write into whatever root NEXUS_ROOT named.
#
# THE FAILURE IS ON THE RECORD, and it is legible because the two writers
# DISAGREED. test-spawn-worker.sh's #545 case pins NEXUS_STATE_DIR at its
# fixture for one spawn. On 2026-08-04 12:17:03, with an ambient NEXUS_ROOT
# still inherited (pre-#706 scrub), that single spawn split:
#
#   action-log row  -> written via `ng`, which HONOURS the pin -> fixture.
#                      The operator's primary action log has no `ackme` spawn
#                      row to this day.
#   pending marker  -> written directly off NEXUS_ROOT -> the operator's LIVE
#                      monitor/.state/skeptic/pending/ackme-worker, where it
#                      sat as an orphaned retire-block for 19 days.
#
# A pending marker is a HARD retire gate (retire-preflight.sh check 1b), so a
# future window that happens to reuse a fixture name boots already blocked,
# with no task and no verdict able to clear it.
#
# ---------------------------------------------------------------------------
# WHY THIS SUITE EXISTS ALONGSIDE nexus-root-sensitivity.sh
# ---------------------------------------------------------------------------
#
# That detector probes the INHERITED-NEXUS_ROOT axis: it exports NEXUS_ROOT at
# a decoy and diffs the decoy. Measured at e256d4a, it reports BOTH suites that
# carry the leaked fixture names — test-spawn-worker.sh and
# test-skeptic-channel.sh — as `verdict=hermetic leaked-paths=0`, and both
# verdicts are CORRECT: those suites control NEXUS_ROOT (one scrubs, one pins),
# so spawn-worker never sees the decoy through that variable.
#
# The axis below is a DIFFERENT one, and the detector is blind to it by
# construction: the leak fires when NEXUS_STATE_DIR and NEXUS_ROOT DISAGREE,
# which the detector never arranges. Two instruments, two axes; neither alone
# is a census.
#
# ---------------------------------------------------------------------------
# EVERY ZERO BELOW IS VOUCHED FOR
# ---------------------------------------------------------------------------
#
# "Nothing leaked into the decoy" and "the spawn aborted before it could write
# anything" produce byte-identical evidence. That is not a hypothetical: the
# first draft of this probe used an EMPTY decoy root, spawn-worker exited on
# the missing worker floor long before the marker write, and the run reported a
# clean decoy — a green that proved nothing. `test-inherited-root-guard.sh`
# records the same lesson for the CI cell ("an EMPTY decoy root does not
# reproduce the failure at all... would be VACUOUS").
#
# So the decoy here is POPULATED (built by the same mk_fixture as the fixture),
# and every run asserts its own `spawned:` witness line before any absence
# claim is read. A run that did not reach the spawn FAILS rather than passing
# quietly.
#
# Run: bash monitor/watcher/test-spawn-worker-state-dir.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.
# Hermetic: no tmux (stubbed), no network, no real nexus state. Every
# NEXUS_ROOT below is set explicitly and NEXUS_STATE_DIR is always pinned, so
# the suite is insensitive to the ambient environment — it must be, since it
# runs inside the `inherited-root` CI cell that exports NEXUS_ROOT.

set -uo pipefail

unset NEXUS_ROOT
unset NEXUS_STATE_DIR

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=monitor/watcher/_test_helpers.sh
. "$_test_dir/_test_helpers.sh"
REPO=$(cd "$_test_dir/../.." && pwd)
SPAWN_SRC="$REPO/monitor/spawn-worker.sh"

# Every assertion this file intends to run. Compared against the ledger at the
# end, because "26 passed, 0 failed" is a claim about what RAN, not about what
# was SUPPOSED to run — an assertion lost to an early `return` reports a
# smaller green rather than a red (#805).
EXPECTED_ASSERTIONS=29

PASS=0; FAIL=0; SKIP=0
ok()  { printf '  PASS: %s\n' "$1"; _th_pass; }
bad() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }

[ -x "$SPAWN_SRC" ] || { echo "missing or non-executable $SPAWN_SRC" >&2; exit 2; }

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"

# ---- fixture builder -----------------------------------------------------
# Deliberately builds a COMPLETE nexus: this same function makes the decoy, so
# the decoy can never be the vacuous kind that aborts the spawn early.
mk_fixture() {   # mk_fixture <dir>
    local F="$1" h
    mkdir -p "$F/monitor" "$F/skills/nexus.worker-defaults" "$F/reports" \
             "$F/config" "$F/node_modules/.bin"
    cp "$SPAWN_SRC" "$F/monitor/spawn-worker.sh"
    chmod +x "$F/monitor/spawn-worker.sh"
    # _bookkeeping.sh carries `wk_encode`, which spawn-worker.sh's preamble
    # loads from $NEXUS_ROOT and REFUSES the spawn (exit 2) without
    # (your-org/nexus-code#941). Absent it, every spawn below dies upstream of
    # the STATE_DIR resolution — and this suite says so loudly rather than
    # reporting a clean decoy, which is exactly what its "absence evidence is
    # VOID" guard is for.
    for h in _claude-bin.sh _tmux-window.sh _fm_lib.sh \
             request-channel.sh _channel_lib.sh _bookkeeping.sh; do
        cp "$REPO/monitor/$h" "$F/monitor/$h"
    done
    # The shim-guard TEMPLATE gets its OWN literal `cp`, not a turn in the loop
    # above. test-guard-closure-boundary.sh audits that every fixture
    # installing spawn-worker.sh also installs this template, and its detector
    # matches a `cp` line by position — by DESIGN, with the blind spot recorded
    # in its own header as "a false RED, which is loud and self-correcting,
    # never a silent pass". Staging the template inside the loop is exactly
    # such a route, and it reds that guard. Keep this line literal.
    cp "$REPO/monitor/guard-block.sh.in" "$F/monitor/guard-block.sh.in"
    chmod +x "$F/monitor/request-channel.sh"
    printf '#!/bin/bash\necho stub-claude\n' > "$F/node_modules/.bin/claude"
    chmod +x "$F/node_modules/.bin/claude"
    # Stub `ng`: the real one needs a config this fixture has no business
    # carrying. It is also the component that ALREADY honours the pin, so
    # stubbing it isolates the property under test to spawn-worker.sh itself.
    printf '#!/bin/bash\nexit 0\n' > "$F/monitor/ng"; chmod +x "$F/monitor/ng"
    printf '{"skipDangerousModePermissionPrompt":true,"hooks":{}}\n' \
        > "$F/monitor/worker-settings.json"
    cat > "$F/skills/nexus.worker-defaults/SKILL.md" <<'EOF'
---
description: stub
---

## Worker floor

- floor body.
EOF
}

STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/tmux" <<'S'
#!/bin/bash
case "$1" in new-window) echo '@7' ;; esac
exit 0
S
chmod +x "$STUB/tmux"

PROMPT="$WORK/p.txt"; echo "do the thing" > "$PROMPT"

DECOY="$WORK/decoy"
mk_fixture "$DECOY"

# run_spawn <fixture> <window> <target> <env...>
# Returns 0 only if the spawn REACHED the spawn point. The witness is
# spawn-worker's own `spawned:` line — the last thing it prints, and printed
# after the skeptic-marker block. Without it, an absence claim below would be
# indistinguishable from an early abort.
LAST_ERR=""
run_spawn() {
    local F="$1" win="$2" tgt="$3"; shift 3
    local rc
    LAST_ERR=$(env "$@" PATH="$STUB:$PATH" TMPDIR="$TMPDIR" \
        "$F/monitor/spawn-worker.sh" -n "$win" -c "$F" -p "$PROMPT" \
        --skeptic-role --skeptic-target "$tgt" 2>&1 >/dev/null); rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q "spawned: window=$win" <<<"$LAST_ERR"; then
        bad "run '$win' did not reach the spawn (rc=$rc) — its absence evidence is VOID: $(tail -1 <<<"$LAST_ERR")"
        return 1
    fi
    ok "run '$win' reached the spawn (witness: 'spawned: window=$win')"
    return 0
}

# Files a run is expected to produce somewhere. Named individually rather than
# as a `find` diff so a NEW state path added to spawn-worker.sh without a
# NEXUS_STATE_DIR-aware home shows up as an unlisted extra, not as noise.
state_paths() {   # state_paths <root> <window> <target>
    printf '%s\n' \
        "$1/monitor/.state/skeptic/pending/$3" \
        "$1/monitor/.state/spawn-prompts/$2.txt" \
        "$1/monitor/.state/windows/$2.json" \
        "$1/monitor/.state/engagement-log.tsv"
}

# ===========================================================================
echo '=== potency: with NO pin, state lands under NEXUS_ROOT (the old path) ==='
# ===========================================================================
# This is the control that makes every "did not leak" below meaningful: it
# proves the probe can SEE these four paths when they are in fact written.
F0="$WORK/fx0"; mk_fixture "$F0"
if run_spawn "$F0" ctrl-win CTRL-TGT -u NEXUS_ROOT -u NEXUS_STATE_DIR; then
    while IFS= read -r p; do
        [ -e "$p" ] && ok "control: probe SEES $(basename "$p")" \
                    || bad "control: probe is BLIND to $(basename "$p") — zeros below are worthless"
    done < <(state_paths "$F0" ctrl-win CTRL-TGT)
fi
if [ -e "$DECOY/monitor/.state/skeptic/pending/CTRL-TGT" ]; then
    bad "control unexpectedly touched the decoy"
else
    ok "control left the decoy alone"
fi

# ===========================================================================
echo
echo '=== the regression: NEXUS_STATE_DIR pinned, NEXUS_ROOT elsewhere ==='
# ===========================================================================
# The exact shape of the 2026-08-04 12:17:03 `ackme-worker` leak.
F1="$WORK/fx1"; mk_fixture "$F1"
PIN1="$F1/monitor/.state"
if run_spawn "$F1" pin-win PIN-TGT "NEXUS_ROOT=$DECOY" "NEXUS_STATE_DIR=$PIN1"; then
    while IFS= read -r p; do
        [ -e "$p" ] && ok "honoured pin: $(basename "$p") written under NEXUS_STATE_DIR" \
                    || bad "IGNORED pin: $(basename "$p") absent from NEXUS_STATE_DIR"
    done < <(state_paths "$F1" pin-win PIN-TGT)
    while IFS= read -r p; do
        [ -e "$p" ] && bad "LEAK into NEXUS_ROOT: $p" \
                    || ok "no leak into NEXUS_ROOT: $(basename "$p")"
    done < <(state_paths "$DECOY" pin-win PIN-TGT)
fi

# ===========================================================================
echo
echo '=== the #577 structural re-root must not defeat the pin either ==='
# ===========================================================================
# `unset NEXUS_ROOT` does NOT isolate a suite on its own: it hands resolution
# to the secondary-clone walk, which re-roots onto any enclosing nexus. A
# fixture built under <primary>/work/** therefore resolves NEXUS_ROOT to the
# PRIMARY even with the scrub in place. The pin must still win.
mkdir -p "$DECOY/work"
F2="$DECOY/work/fx2"; mk_fixture "$F2"
PIN2="$F2/monitor/.state"
if run_spawn "$F2" st-win ST-TGT -u NEXUS_ROOT "NEXUS_STATE_DIR=$PIN2"; then
    grep -q 'SECONDARY CLONE' <<<"$LAST_ERR" \
        && ok "the structural re-root DID fire (this case is not vacuous)" \
        || bad "structural re-root did not fire — this case proves nothing"
    while IFS= read -r p; do
        [ -e "$p" ] && bad "LEAK into the re-rooted primary: $p" \
                    || ok "no leak into the re-rooted primary: $(basename "$p")"
    done < <(state_paths "$DECOY" st-win ST-TGT)
fi

# ===========================================================================
echo
echo '=== fail CLOSED: an unusable pin refuses the spawn, never falls back ==='
# ===========================================================================
# A pin we cannot honour is worse than no pin: the caller has already concluded
# it is isolated. Falling through to the live root is exactly what wrote
# `ackme-worker`, so refuse instead.
F3="$WORK/fx3"; mk_fixture "$F3"
UNUSABLE="$WORK/unwritable/state"
mkdir -p "$WORK/unwritable"; chmod 500 "$WORK/unwritable"
err=$(env "NEXUS_ROOT=$DECOY" "NEXUS_STATE_DIR=$UNUSABLE" PATH="$STUB:$PATH" \
    TMPDIR="$TMPDIR" "$F3/monitor/spawn-worker.sh" -n fc-win -c "$F3" \
    -p "$PROMPT" --skeptic-role --skeptic-target FC-TGT 2>&1 >/dev/null); rc=$?
chmod 700 "$WORK/unwritable"
if [ "$rc" -eq 19 ]; then
    ok "unusable NEXUS_STATE_DIR exits 19 (documented refusal)"
else
    bad "unusable NEXUS_STATE_DIR exited $rc, want 19"
fi
grep -q 'REFUSING to spawn' <<<"$err" \
    && ok "refusal names itself on stderr" \
    || bad "refusal is silent — stderr: $(tail -1 <<<"$err")"
if [ -e "$DECOY/monitor/.state/skeptic/pending/FC-TGT" ]; then
    bad "FELL BACK to the live root after an unusable pin — the #973 failure"
else
    ok "did NOT fall back to NEXUS_ROOT after an unusable pin"
fi

# ===========================================================================
echo
echo '=== source guard: no state path may be keyed off NEXUS_ROOT again ==='
# ===========================================================================
# The behavioural cases above only cover the paths `state_paths` enumerates. A
# future edit can add a thirteenth. This catches that class by construction.
#
# AN IDIOM GREP IS A CLAIM ABOUT THE *SPELLING*, NOT THE *IDIOM*. The first
# version of this lint matched `$NEXUS_ROOT` only, and the function parameter
# in _write_provenance_record / _seed_lifecycle_anchors is spelled
# `$nexus_root` — lowercase. So the guard was blind to the exact spelling the
# two functions it most needed to watch actually use, and a mutant adding a
# state path in that spelling survived it green. It was not hypothetical: the
# lowercase form had a LIVE instance in the file the guard was protecting
# (`hb_ref`, the provenance record's last_activity_ref, pointing at a heartbeat
# that is written under $STATE_DIR — a dangling pointer under a pinned dir).
# This workspace has lost a site to precisely this before, on `[^a-zA-Z0-9_-]`
# vs `[^A-Za-z0-9_-]`: same character set, different string, survived a fix and
# three skeptic passes.
#
# So the pattern is case-insensitive and brace-tolerant, and — the part that
# actually earns trust — it is exercised against a DELIBERATELY
# ALTERNATELY-SPELLED plant below. A control that reuses the spelling the lint
# was written for cannot detect a spelling blind spot.
_state_root_offenders() {   # _state_root_offenders <file>
    # Every root-keyed state path, any spelling, minus comments and minus the
    # four SANCTIONED sites: the fallback definition, the refusal message, and
    # the `${STATE_DIR:-...}` guarded defaults the eval-extracting suites need.
    grep -Ein '\$\{?nexus_root\}?/monitor/\.state' "$1" \
        | grep -Ev '^[0-9]+:[[:space:]]*#' \
        | grep -Fv 'STATE_DIR="$NEXUS_ROOT/monitor/.state"' \
        | grep -Fv 'REFUSING to spawn' \
        | grep -Ev '\$\{STATE_DIR:-\$\{?nexus_root\}?/monitor/\.state\}' || true
}

offenders=$(_state_root_offenders "$SPAWN_SRC")
if [ -z "$offenders" ]; then
    ok "no CODE site keys state off the nexus root, in any spelling"
else
    bad "state paths still keyed off the nexus root:"
    printf '        %s\n' "$offenders" >&2
fi

# CONTROL PAIR — DIFFERENTIAL, and that is not a stylistic choice.
#
# The obvious control is "plant a mutant, assert the lint reports SOMETHING".
# That control is VACUOUS whenever the base file already has offenders, because
# the non-empty result is produced by the base and the plant contributes
# nothing. Measured: run this suite against `origin/dev`'s spawn-worker.sh —
# the pre-fix file, 15 root-keyed mentions — and the absolute form passes both
# spellings while proving nothing whatsoever about either.
#
# So compare the COUNT WITH the plant against the count WITHOUT it. The delta
# is attributable to the plant by construction, on a clean base or a dirty one.
_offender_count() { _state_root_offenders "$1" | grep -c . || true; }
_base_n=$(_offender_count "$SPAWN_SRC")

# The lowercase arm is the one that matters: it is the arm the previous
# NEXUS_ROOT-only lint failed, so a green here is a measured widening.
for _spell in 'NEXUS_ROOT' 'nexus_root'; do
    _mut="$WORK/mutant-$_spell.sh"
    cp "$SPAWN_SRC" "$_mut"
    printf '_new_state_path="$%s/monitor/.state/brand-new-thing"\n' "$_spell" >> "$_mut"
    _mut_n=$(_offender_count "$_mut")
    if [ "$_mut_n" -gt "$_base_n" ]; then
        ok "lint KILLS a planted state path spelled \$$_spell (offenders $_base_n → $_mut_n)"
    else
        bad "lint SURVIVES a planted state path spelled \$$_spell — blind to that spelling (offenders stayed at $_base_n)"
    fi
done

# Negative control: the sanctioned guarded form must add NO offender, or the
# lint is merely loud rather than correct and the next author will delete it.
_neg="$WORK/mutant-sanctioned.sh"
cp "$SPAWN_SRC" "$_neg"
printf '_ok_path="${STATE_DIR:-$nexus_root/monitor/.state}/another-thing"\n' >> "$_neg"
_neg_n=$(_offender_count "$_neg")
if [ "$_neg_n" -eq "$_base_n" ]; then
    ok "lint ACCEPTS the sanctioned \${STATE_DIR:-...} guarded form (offenders unchanged at $_base_n)"
else
    bad "lint rejects the sanctioned guarded form (offenders $_base_n → $_neg_n) — it would flag the eval-extract fallbacks"
fi

# Sanity-check the pattern against a KNOWN TOTAL. The fallback definition, the
# refusal message and the guarded defaults legitimately contain the string, so
# a pattern matching ZERO anywhere means it stopped matching, not that the file
# got cleaner — the lint's own silent-zero guard.
root_mentions=$(grep -Ein '\$\{?nexus_root\}?/monitor/\.state' "$SPAWN_SRC" | grep -c . || true)
if [ "$root_mentions" -ge 4 ]; then
    ok "lint pattern still matches the file ($root_mentions mentions) — its zero above is trustworthy"
else
    bad "lint pattern matched $root_mentions times; expected >=4 (fallback + refusal + 3 guarded defaults + prose). The zero above is NOT trustworthy."
fi

echo
# The count guard. `th_summary_and_exit` reconciles PASS/FAIL against the
# durable ledger, which catches an assertion LOST in a subshell; this catches
# the complementary case it cannot see — an assertion that never ran at all,
# because a case returned early. Both directions, or the green is only a claim
# about the assertions that happened to execute.
RUN=$(( PASS + FAIL + SKIP ))
if [ "$RUN" -ne "$EXPECTED_ASSERTIONS" ]; then
    bad "ASSERTION COUNT MISMATCH — $RUN ran, $EXPECTED_ASSERTIONS expected. A case returned early; the tally above is not coverage."
fi

th_summary_and_exit
