#!/usr/bin/env bash
# test-realmodel-vimode.sh — the harness must boot the KEYBOARD MODE
# production actually runs (your-org/nexus-code#724).
#
# WHY THIS EXISTS
#
# Every production nexus agent inherits `editorMode: "vim"` from user scope.
# `cch_setup` seeded no `editorMode` until #724, so every real-binary scenario
# — and therefore the whole pre-update gate — booted the binary in its DEFAULT
# keyboard mode. The gate was validating a configuration nobody is in. Same
# class as the `tui` fix in #568.
#
# It is not cosmetic. Vim mode paints `-- INSERT --` into the status row, and
# monitor/pane-state.sh reads exactly that row (`_detect_vim_insert`) to
# decide `user-typing` vs `idle` — the classification the orchestrator's
# kill-authorization is built on (#603, #626). So the production keyboard mode
# is an INPUT to the property this harness exists to gate, and gating it in
# the other mode measured something no worker runs.
#
# WHY THE CONTROL BOOT IS PART OF THE TEST, NOT AN EXTRA
#
# The obvious version of this test is vacuous, and #724 says so explicitly: an
# UNSEEDED vim probe asserts `-- INSERT --` against a binary that was never put
# into vim mode. If the seed mechanism silently stopped working — a renamed
# settings key, a config path the binary no longer reads, a scenario that
# rewrites settings.json and drops the key — a one-boot test that greps for
# the marker would simply go red for an unexplained reason, and a one-boot test
# that greps for anything WEAKER would stay green forever while measuring
# nothing.
#
# So the discriminator is the assertion. Three boots in one run:
#
#   worker  — harness default (`editorMode: vim`)  => `-- INSERT --` PRESENT
#   control — CCH_EDITOR_MODE='' (no key written)  => `-- INSERT --` ABSENT
#   enum    — `editorMode: vi`, out of enum        => `-- INSERT --` ABSENT
#
# Neither cell alone is evidence. Together they establish that the marker
# tracks THE SEED rather than tracking the binary, the terminal, or the
# grep: if the seed were inert both cells read ABSENT and the worker
# assertion reddens; if the detector matched anything at all both cells read
# PRESENT and the control assertion reddens.
#
# THE SPELLING IS LOAD-BEARING, AND GETTING IT WRONG FAILS OPEN SILENTLY.
# Read out of the pinned 2.1.224 binary (reported on #724 from the #744 work):
# the setting is a two-member enum `["normal","vim"]` carrying
# `.catch(void 0)`, and VI mode is active iff the value is strictly `"vim"`
# (`==="vim"` occurs once; `==="vi"` never; `vimMode` is not a key in this
# version). `.catch(void 0)` means an OUT-OF-ENUM VALUE IS DISCARDED WITHOUT
# AN ERROR — no warning, the pane simply stays in `normal`.
#
# So a near-miss spelling is indistinguishable from seeding nothing, and every
# assertion built on it passes for the wrong reason. That is not hypothetical:
# a differential control in #744 (`22547e8`) seeded `"vi"` and concluded from
# the absent indicator that the VI surface was inert — a `reachability`
# verdict since overturned, on a host where VI mode is demonstrably reachable
# and 9 of 10 live agent panes render the indicator.
#
# Cell 3 below pins exactly that, so the trap is an executable assertion
# rather than a comment somebody has to have read: an out-of-enum seed must
# behave like NO seed. If a future release starts REJECTING invalid values
# loudly, or starts accepting `"vi"`, that cell moves and the reader is told.
#
# The second boot also load-bears on a migration hazard the harness only just
# survived. The real binary MIGRATES `.claude.json`'s
# `bypassPermissionsModeAccepted` into settings.json as
# `skipDangerousModePermissionPrompt` on first boot and deletes the original,
# so a re-seed that rewrites settings.json without re-supplying that key wedges
# the control boot on the Bypass Permissions modal — forever, at `state=empty`.
# `cch_write_settings` is what makes the re-seed safe; if it regresses, the
# control boot never reaches idle and this test reddens. See the comment on
# that function.
#
# Gated on RUN_CC_HARNESS=1 (+ node + a resolvable claude binary);
# self-skips otherwise. See monitor/cc-harness/README.md.

set -uo pipefail
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$_self_dir/../_test_helpers.sh"
. "$_self_dir/../../cc-harness/_lib.sh"

cch_skip_if_disabled
cch_setup

echo "=== real-binary harness: production keyboard mode (vim) ==="
echo "    claude:  $CLAUDE_BIN"

# The marker pane-state itself keys on — same regex as
# monitor/pane-state.sh's _detect_vim_insert, deliberately, so this test
# cannot pass on a spelling that function would not accept.
has_insert() { grep -qE -- '--[[:space:]]*INSERT[[:space:]]*--' <<<"$1"; }

# ---------------------------------------------------------------------------
# 0. The DEFAULT is production parity, asserted structurally.
#
# Everything below measures the binary's behaviour under whatever the harness
# seeded. This asserts what it seeds BY DEFAULT — so a future edit that keeps
# the mechanism working but flips the default back to "no key" reddens here
# rather than silently returning the gate to the #724 state with every
# behavioural assertion still green.
# ---------------------------------------------------------------------------
seeded=$(cat "$CCH_CFG/settings.json")
assert_contains "cch_setup seeds editorMode=vim by default" "$seeded" '"editorMode": "vim"'
assert_contains "cch_setup seeds the permissions-prompt key" \
    "$seeded" '"skipDangerousModePermissionPrompt": true'

# ---------------------------------------------------------------------------
# 1. The production cell: seeded vim.
# ---------------------------------------------------------------------------
win=$(cch_boot_worker vim1)
[[ -n "$win" ]] || { echo "FAIL: worker window never appeared" >&2; exit 1; }
wait_for "seeded worker boots to idle" 40 -- cch_state_is "$win" idle

pane_vim=$(cch_capture "$win")
if has_insert "$pane_vim"; then
    echo "  PASS: real binary renders \`-- INSERT --\` under the seeded editorMode"
    PASS=$(( PASS + 1 ))
else
    echo "  FAIL: seeded editorMode=vim did NOT put the real binary in vim mode" >&2
    printf '%s\n' "$pane_vim" >&2
    FAIL=$(( FAIL + 1 ))
fi

# 2. The production CONSEQUENCE, and the reason the mode matters at all: an
#    EMPTY vim-mode input box must classify `idle`, not `user-typing`. #626
#    is the incident where the unsound `-- INSERT -- + non-blank row ⇒ draft`
#    heuristic stalled the board for thirty minutes; pane-state now requires
#    typed-text SGR as well. That refinement has never been exercised against
#    the real binary in vim mode — only against fixtures — because the harness
#    could not boot vim mode.
state_line=$(cch_pane_state "$win")
assert_contains "empty vim-mode box classifies idle (not user-typing)" \
    "$state_line" "state=idle"
assert_contains "empty vim-mode box reports input=blank" "$state_line" "input=blank"

# 3. …and a vim-mode box with real typed text must classify `user-typing`,
#    so assertion 2 is not passing merely because the vim clause is dead.
#    Text only — no Enter — so it stays an unsubmitted draft.
cch_tmux send-keys -t "$CCH_SESSION:$win" "draft that must not be killed"
wait_for "typed vim-mode box classifies user-typing" 15 -- \
    cch_state_is "$win" user-typing

cch_kill_claude "$win"

# ---------------------------------------------------------------------------
# 4. The CONTROL cell: no editorMode key at all. This is the non-vacuity
#    assertion — see the header. It re-seeds settings.json through
#    cch_write_settings, which is also what keeps the permissions-prompt key
#    alive across the rewrite.
# ---------------------------------------------------------------------------
cch_write_settings ''
assert_not_contains "control re-seed drops the editorMode key" \
    "$(cat "$CCH_CFG/settings.json")" 'editorMode'
assert_contains "control re-seed KEEPS the permissions-prompt key" \
    "$(cat "$CCH_CFG/settings.json")" '"skipDangerousModePermissionPrompt": true'

ctl=$(cch_boot_worker vim0)
[[ -n "$ctl" ]] || { echo "FAIL: control window never appeared" >&2; exit 1; }
# A control boot that never reaches idle is the migration hazard above, not a
# slow runner: the Bypass Permissions modal holds the pane. Since
# your-org/nexus-code#768 that no longer has to be inferred from a comment —
# the modal reports `state=blocked overlay=bypass-permissions`, and
# `wait_for`'s failure path prints the observed line plus the re-seed remedy.
# (It used to report `empty`, i.e. "don't know yet", which is what made this
# read as a timeout.)
wait_for "control worker boots to idle" 40 -- cch_state_is "$ctl" idle

pane_ctl=$(cch_capture "$ctl")
if has_insert "$pane_ctl"; then
    echo "  FAIL: control (no editorMode seeded) ALSO rendered \`-- INSERT --\` —" >&2
    echo "        the marker does not track the seed, so the vim assertion above" >&2
    echo "        proves nothing. This test is vacuous until that is explained." >&2
    printf '%s\n' "$pane_ctl" >&2
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: control renders NO \`-- INSERT --\` — the marker tracks the seed"
    PASS=$(( PASS + 1 ))
fi

cch_kill_claude "$ctl"

# ---------------------------------------------------------------------------
# 5. The OUT-OF-ENUM cell. `editorMode` carries `.catch(void 0)`, so a
#    near-miss spelling is silently discarded and reads EXACTLY like the
#    control above — which is what makes it dangerous, and why it is asserted
#    here rather than trusted to a comment. See the header.
#
#    This cell is deliberately NOT a claim that `"vi"` is wrong in principle;
#    it is a claim about THIS binary's enum. If a release adds `"vi"` as an
#    alias, this reddens and the reader learns the enum moved — which is the
#    correct outcome for a harness whose job is catching release drift.
# ---------------------------------------------------------------------------
cch_write_settings vi
assert_contains "out-of-enum re-seed really did write it" \
    "$(cat "$CCH_CFG/settings.json")" '"editorMode": "vi"'

bad=$(cch_boot_worker vimx)
[[ -n "$bad" ]] || { echo "FAIL: out-of-enum window never appeared" >&2; exit 1; }
wait_for "out-of-enum worker boots to idle" 40 -- cch_state_is "$bad" idle

pane_bad=$(cch_capture "$bad")
if has_insert "$pane_bad"; then
    echo "  FAIL: \`editorMode: vi\` DID put the binary in vim mode — the enum" >&2
    echo "        has changed since 2.1.224 (was [\"normal\",\"vim\"], strict)." >&2
    echo "        Update the header's enum evidence before trusting this suite." >&2
    FAIL=$(( FAIL + 1 ))
else
    echo "  PASS: out-of-enum \`vi\` is silently discarded — reads as NO seed"
    PASS=$(( PASS + 1 ))
fi

cch_kill_claude "$bad"

th_summary_and_exit
