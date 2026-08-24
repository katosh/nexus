#!/usr/bin/env bash
# test-bookkeeping-contract.sh — the bookkeeping-defect family
# (your-org/nexus-code #599 #601 #602 #603 #605 #607 #615).
#
# One contract, tested as one thing:
#
#   1. A verb that IGNORES a supplied argument must fail loudly.
#   2. A signal that CANNOT DISTINGUISH two states must say so, and must
#      never authorise a destructive action.
#
# EVERY guard here is tested in BOTH directions, and the negative
# control asserts on the MESSAGE, not just the exit code. That is
# load-bearing rather than stylistic: several of these defects shipped
# with a passing test, because a check that exits non-zero for the wrong
# reason is indistinguishable from one that works. `bk_require_int`
# rejecting `"four findings"` proves nothing unless it rejects it for
# BEING NON-NUMERIC — a helper that died on an unrelated `set -u` error
# would satisfy an rc-only assertion just as well.
#
# The suite also asserts its own ASSERTION COUNT. A missing `assert_*`
# helper exits rc 127, which is counted by nothing: the file runs, prints
# no failure, and reports success for tests that never executed. The
# floor below is the guard against that.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO_ROOT=$(pwd)
. "$REPO_ROOT/monitor/watcher/_test_helpers.sh"

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=monitor/_bookkeeping.sh
source "$REPO_ROOT/monitor/_bookkeeping.sh"

echo "=== contract 1: a verb that ignores an argument must fail loudly ==="

# ---- #601: --skeptic-findings must not coerce prose to 0 ----------------
#
# The defect: `[[ "$v" =~ ^[0-9]+$ ]] || findings=0`. Prose became 0 —
# the value meaning "nothing found" — on the control path of the gate
# whose purpose is to stop under-reported findings. A skeptic's four
# findings (one HIGH, merge-blocking) printed as `findings: 0` and
# TERMINATED the chain.
BK_ERR=""
bk_require_int --skeptic-findings "4" --allow-empty
assert_rc "#601 a plain integer is accepted" $? 0

BK_ERR=""
bk_require_int --skeptic-findings "" --allow-empty
assert_rc "#601 empty (flag absent) is accepted with --allow-empty" $? 0

BK_ERR=""
bk_require_int --skeptic-findings "0" --allow-empty
assert_rc "#601 an explicit 0 (a real clean pass) is accepted" $? 0

# NEGATIVE CONTROL — the guard must fire, AND fire for the stated reason.
BK_ERR=""
bk_require_int --skeptic-findings "four findings, one HIGH and merge-blocking" --allow-empty
assert_rc "#601 NEGATIVE CONTROL: prose is REJECTED" $? 1
assert_contains "#601 …and the message names the offending FLAG" \
    "$BK_ERR" "--skeptic-findings"
assert_contains "#601 …and says WHY (non-integer), not some unrelated error" \
    "$BK_ERR" "must be an unsigned integer"
assert_contains "#601 …and echoes the value back so the typo is visible" \
    "$BK_ERR" "four findings"
# The specific inversion that made this dangerous: it must not have
# silently produced the "nothing found" value.
assert_not_contains "#601 …and does NOT report a coerced count" "$BK_ERR" "coerced to 0"

# A negative value is not an unsigned integer. This is the case a lazy
# `[[ -n $v ]]` guard would wave through.
BK_ERR=""
bk_require_int --skeptic-findings "-1" --allow-empty
assert_rc "#601 a negative count is REJECTED" $? 1

# Without --allow-empty, empty is a missing value, not a default.
BK_ERR=""
bk_require_int --skeptic-depth ""
assert_rc "#601 empty is REJECTED when --allow-empty is not passed" $? 1
assert_contains "#601 …naming the flag" "$BK_ERR" "--skeptic-depth"

# ---- end-to-end through `ng wrap-up` ------------------------------------
#
# The unit above proves the predicate. This proves it is WIRED — the
# #601 report was filed against `ng wrap-up`, not against a helper, and
# a guard that exists but is not reached is the defect class itself.
setup_fake_nexus "$WORK/nexus" >/dev/null 2>&1
mkdir -p "$WORK/nexus/reports"
cat > "$WORK/nexus/reports/r.md" <<'EOF'
---
name: r
---
## Summary
x
## What Was Done
x
## Current State
x
## What Remains
x
## How to Resume
x
EOF
ng_out=$(run_hermetic NEXUS_STATE_DIR="$WORK/state" -- \
    bash "$WORK/nexus/monitor/ng" wrap-up 1 "$WORK/nexus/reports/r.md" \
        --skeptic-role --skeptic-verdict check \
        --skeptic-findings "four findings, one merge-blocking" 2>&1)
ng_rc=$?
assert_rc "#601 ng wrap-up EXITS NON-ZERO on a prose --skeptic-findings" "$ng_rc" 1
assert_contains "#601 …and the failure names the flag (not a generic usage dump)" \
    "$ng_out" "--skeptic-findings"
# The exact symptom from the report: it must NOT have proceeded to
# announce a terminated chain.
assert_not_contains "#601 …and does NOT print the false termination" \
    "$ng_out" "Skeptic chain TERMINATES"

# CONTROL: the same call with a real count must NOT be rejected by this
# guard. A gate that refuses everything is not a working gate — and this
# is the assertion that would catch an over-broad regex.
ng_out=$(run_hermetic NEXUS_STATE_DIR="$WORK/state" -- \
    bash "$WORK/nexus/monitor/ng" wrap-up 1 "$WORK/nexus/reports/r.md" \
        --skeptic-role --skeptic-verdict check --skeptic-findings 4 2>&1)
assert_not_contains "#601 CONTROL: a numeric count is not rejected by the guard" \
    "$ng_out" "must be an unsigned integer"

# ---- #605: an ignored argument must be refused, never dropped ----------
BK_ERR=""
bk_refuse_ignored "--comment-body-file" \
    "a wrap-up comment already exists for this issue" \
    "pass a differing body (it will be posted as a new comment)"
assert_rc "#605 bk_refuse_ignored always fails" $? 1
assert_contains "#605 …naming the ignored argument" "$BK_ERR" "--comment-body-file"
assert_contains "#605 …stating it WOULD BE IGNORED (the whole point)" \
    "$BK_ERR" "IGNORE"
assert_contains "#605 …and carrying the remedy" "$BK_ERR" "do instead:"

echo
echo "=== contract 2: an indeterminate signal must not authorise a kill ==="

# ---- #603: the retirement gate is an allowlist with a default-DENY -----
#
# The defect: a `case` whose `*)` arm PERMITTED. `empty` — documented in
# pane-state.sh's own header as "don't know yet, try again next cycle" —
# fell through it, and would have killed a window 4m38s into a
# verification pass, mid-`git fetch`, with a message queued behind it.
for s in idle autosuggest-only absent idle-orphan-async; do
    bk_pane_kill_authorized "$s"
    assert_rc "#603 '$s' AUTHORISES a kill (definite: no turn in flight)" $? 0
done

# NEGATIVE CONTROLS — each must refuse, and be classified for the RIGHT
# reason. `active` and `indeterminate` are different situations calling
# for different orchestrator behaviour (wait vs. re-poll), so a guard
# that refused everything as one bucket would be a regression even
# though every rc assertion above would still pass.
for s in busy user-typing blocked working-background working-self-paced over-limit queued; do
    BK_ERR=""; BK_REFUSE_KIND=""
    bk_pane_kill_authorized "$s"
    assert_rc "#603 NEGATIVE CONTROL: '$s' REFUSES a kill" $? 1
    assert_eq "#603 …classified 'active', not 'indeterminate'" "$BK_REFUSE_KIND" "active"
done

BK_ERR=""; BK_REFUSE_KIND=""
bk_pane_kill_authorized "empty"
assert_rc "#603 NEGATIVE CONTROL: 'empty' REFUSES a kill (the reported defect)" $? 1
assert_eq "#603 …classified 'indeterminate', NOT 'active'" "$BK_REFUSE_KIND" "indeterminate"
assert_contains "#603 …and the reason says it does not assert finished" \
    "$BK_ERR" "does not assert that the window is finished"
assert_contains "#603 …and points at 'absent' as the state that DOES" \
    "$BK_ERR" "absent"

# THE INVERSION ITSELF. A state nobody enumerated must DENY. Under the
# old denylist shape this exact input was permitted, which is why the
# specific `empty` fix would not have been enough on its own.
BK_ERR=""; BK_REFUSE_KIND=""
bk_pane_kill_authorized "some-state-invented-in-2027"
assert_rc "#603 DEFAULT-DENY: an unrecognised state REFUSES a kill" $? 1
assert_eq "#603 …classified indeterminate" "$BK_REFUSE_KIND" "indeterminate"

BK_ERR=""
bk_pane_kill_authorized ""
assert_rc "#603 DEFAULT-DENY: an EMPTY state string REFUSES a kill" $? 1

# ---- retire-preflight actually applies the gate -------------------------
pf() { run_hermetic NEXUS_STATE_DIR="$WORK/state" -- \
        bash "$REPO_ROOT/monitor/retire-preflight.sh" --pane-state "$1" some-window 2>&1; }

out=$(pf empty); rc=$?
assert_rc "#603 retire-preflight REFUSES on pane=empty" "$rc" 1
assert_contains "#603 …emitting safe=0" "$out" "safe=0"
assert_contains "#603 …for the INDETERMINACY, not some other veto" "$out" "INDETERMINATE"

out=$(pf over-limit); rc=$?
assert_rc "#603 retire-preflight REFUSES on pane=over-limit (was permitted)" "$rc" 1
assert_contains "#603 …citing the suspension, not a generic refusal" "$out" "suspended"

out=$(pf a-future-state); rc=$?
assert_rc "#603 retire-preflight default-DENIES an unknown pane state" "$rc" 1
assert_contains "#603 …emitting safe=0" "$out" "safe=0"

# CONTROL — the gate must still PERMIT the legitimate case. Without this
# the whole fix could be "return 1 always", which passes every negative
# control above. `absent` is the state the issue names as the correct
# gate, so this is the assertion that proves retirement still works.
out=$(pf absent)
assert_contains "#603 CONTROL: pane=absent still reaches safe=1 (retirement works)" \
    "$out" "safe=1"

echo
echo "=== #603 / #607: pane-state classifies queued + vim-INSERT panes ==="

NBSP=$'\xc2\xa0'
ps_fixture() {
    # Run pane-state.sh against a fixture file; echo its emit line.
    local f="$WORK/fx.ansi"
    printf '%s' "$1" > "$f"
    run_hermetic -- bash "$REPO_ROOT/monitor/pane-state.sh" \
        --fixture "$f" --window 7 --name w 2>/dev/null
}

# The 2026-07-29 pane: a turn in flight, a queued message, and NO
# `❯<NBSP>` input row (Claude Code replaces it with the placeholder).
# This read `state=empty active=0` and became a kill candidate.
queued_pane=$'\n  Razzle-dazzling… (4m 38s · \xe2\x86\x93 12.1k tokens)\n\n\xe2\x9d\xaf Press up to edit queued messages\n  -- INSERT -- \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\n'
out=$(ps_fixture "$queued_pane")
assert_not_contains "#603 a queued pane is NOT 'empty' (the reported defect)" \
    "$out" "state=empty"
assert_contains "#603 …it reports busy (every consumer already treats busy as never-kill)" \
    "$out" "state=busy"
assert_contains "#603 …and carries the discriminating queued=1 field" "$out" "queued=1"

# NEGATIVE CONTROL for the queued detector: a pane with no placeholder
# and no spinner must NOT be called busy. Without this, "always emit
# busy" would pass the assertion above.
plain_idle=$'\n  Some transcript text\n\n\xe2\x9d\xaf'"$NBSP"$'\x1b[7m \x1b[0m\n'
out=$(ps_fixture "$plain_idle")
assert_not_contains "#603 CONTROL: an ordinary empty box is NOT reported busy" \
    "$out" "state=busy"
assert_not_contains "#603 CONTROL: …and carries no queued marker" "$out" "queued=1"

# Vim INSERT mode with visible operator text. Claude Code's vim mode does
# not reliably emit the bright-white SGR that _detect_user_typing keys
# on, so this pane read `empty active=0` — twice in one night — while an
# operator had unsubmitted text in the box.
vim_typed=$'\n  transcript\n\n\xe2\x9d\xaf'"$NBSP"$'please also check the second case\n  -- INSERT -- \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\n'
out=$(ps_fixture "$vim_typed")
assert_contains "#603 -- INSERT -- plus a non-blank input row is user-typing" \
    "$out" "state=user-typing"

# NEGATIVE CONTROL: `-- INSERT --` with an EMPTY box must NOT be
# user-typing. This is the assertion that stops the fix from pinning
# every vim-mode pane open forever — and it is the one that fails if the
# NBSP after the chevron is mistaken for typed text.
vim_empty=$'\n  transcript\n\n\xe2\x9d\xaf'"$NBSP"$'\x1b[7m \x1b[0m\n  -- INSERT -- \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\n'
out=$(ps_fixture "$vim_empty")
assert_not_contains "#603 CONTROL: -- INSERT -- with an EMPTY box is NOT user-typing" \
    "$out" "state=user-typing"

# NEGATIVE CONTROL, and the one that caught the first attempt at this
# fix. A GHOST is not typed text — and the autosuggest fixtures in
# test-pane-state.sh also render `-- INSERT --`, so a vim check that
# merely asked "is the row non-blank" reclassified every ghost as
# `user-typing`. That is not a safe over-trigger: `autosuggest-only` is
# itself a kill-authorising state, so the mistake did not add caution,
# it just moved which tested distinction got destroyed. The ghost begins
# at the reverse-video/dim pair, so only the text BEFORE it counts.
vim_ghost=$'\n  transcript\n\n\xe2\x9d\xaf'"$NBSP"$'\x1b[7mc\x1b[0;2mheck the second case\x1b[0m\n  -- INSERT -- \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\n'
out=$(ps_fixture "$vim_ghost")
assert_not_contains "#603 CONTROL: a GHOST under -- INSERT -- is NOT user-typing" \
    "$out" "state=user-typing"

# ---- #626: the BARE-DIM ghost, and the ghost-vs-draft field ------------
#
# The real rendering, captured live from window 0:33 on 2026-07-30:
#
#     \x1b[39m❯<NBSP>\x1b[2muse (d)
#
# `\x1b[2m` with NO reverse-video cursor. The pre-existing autosuggest
# signature required the `\x1b[7m` cursor, so it matched none of this —
# which is why NINETEEN windows rendering ghost text at once ALL
# classified `empty`, the "don't know" value, and the orchestrator (with
# only the unsound `-- INSERT --` heuristic left) read them as
# unsubmitted operator drafts and withheld messages for ~30 minutes.
bare_ghost=$'\n  transcript\n\n\x1b[39m\xe2\x9d\xaf'"$NBSP"$'\x1b[2muse (d)\n'
out=$(ps_fixture "$bare_ghost")
assert_not_contains "#626 a bare-dim ghost is NOT 'empty' (19/19 read empty)" \
    "$out" "state=empty"
assert_contains "#626 …it is autosuggest-only" "$out" "state=autosuggest-only"
assert_contains "#626 …and says GHOST outright, so no heuristic is needed" \
    "$out" "input=ghost"

# NEGATIVE CONTROL — the SGR-2 match must be on a WHOLE parameter.
# `\x1b[22m` (normal intensity) and `\x1b[32m` (green) both contain the
# digit 2; matching them would classify ordinary coloured text as a
# ghost and hand the pane a kill authorisation it must not have.
green_text=$'\n  transcript\n\n\x1b[39m\xe2\x9d\xaf'"$NBSP"$'\x1b[32mgreen not dim\n'
out=$(ps_fixture "$green_text")
assert_not_contains "#626 NEGATIVE CONTROL: SGR 32 (green) is NOT a dim ghost" \
    "$out" "input=ghost"
normal_int=$'\n  transcript\n\n\x1b[39m\xe2\x9d\xaf'"$NBSP"$'\x1b[22mnormal intensity\n'
out=$(ps_fixture "$normal_int")
assert_not_contains "#626 NEGATIVE CONTROL: SGR 22 (normal) is NOT a dim ghost" \
    "$out" "input=ghost"

# A dim introducer with NOTHING after it is not a ghost either — an
# empty box must not acquire one.
dim_empty=$'\n  transcript\n\n\x1b[39m\xe2\x9d\xaf'"$NBSP"$'\x1b[2m\x1b[0m\n'
out=$(ps_fixture "$dim_empty")
assert_not_contains "#626 NEGATIVE CONTROL: a dim run with no text is NOT a ghost" \
    "$out" "input=ghost"

# The field must report TYPED for real input, or it answers the wrong
# question. This is the assertion that keeps `input=` from degenerating
# into "always ghost".
typed_row=$'\n  transcript\n\n\xe2\x9d\xaf'"$NBSP"$'\x1b[38;5;231mpush it and open the PR\x1b[0m\n'
out=$(ps_fixture "$typed_row")
assert_contains "#626 CONTROL: bright-white typed input reports input=typed" \
    "$out" "input=typed"
assert_contains "#626 CONTROL: …and still classifies user-typing" \
    "$out" "state=user-typing"

# The honest residue: a non-blank row matching NEITHER marker is `?`,
# not a guess. #626's ask was that "I looked and could not tell" be
# distinguishable from "there is nothing here" — this is that.
unknown_row=$'\n  transcript\n\n\xe2\x9d\xaf'"$NBSP"$'plain unmarked text\n'
out=$(ps_fixture "$unknown_row")
assert_contains "#626 an unmarked non-blank row reports input=? (not a guess)" \
    "$out" "input=?"

# ...and the case a naive ghost-exclusion would get wrong in the other
# direction: a typed PREFIX with a ghost completion after it is real
# operator input.
vim_prefix=$'\n  transcript\n\n\xe2\x9d\xaf'"$NBSP"$'please check\x1b[7m \x1b[0;2mthe second case\x1b[0m\n  -- INSERT -- \xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on\n'
out=$(ps_fixture "$vim_prefix")
assert_contains "#603 a typed PREFIX before a ghost IS user-typing" \
    "$out" "state=user-typing"

echo
echo "=== #602: retirement teardown is enumeration-driven and verified ==="

ST="$WORK/state602"
seed_surfaces() {
    local w="$1" s="${1//[^a-zA-Z0-9_-]/_}"
    mkdir -p "$ST"/{user-prompt,machine-submit,heartbeat,pane-change,spawn-prompts} \
             "$ST"/{worker-health,bg-backoff,bg-firstseen,windows,decisions,footgun-seen} \
             "$ST/skeptic/pending" "$ST/skeptic/$s"
    echo x > "$ST/user-prompt/$w";        echo x > "$ST/machine-submit/$w"
    echo x > "$ST/heartbeat/$w.json";     echo x > "$ST/pane-change/$w"
    echo x > "$ST/spawn-prompts/$w.txt";  echo x > "$ST/worker-health/$w.json"
    echo x > "$ST/bg-backoff/$w";         echo x > "$ST/bg-firstseen/$w"
    echo x > "$ST/windows/$s.json";       echo x > "$ST/skeptic/pending/$s"
    echo x > "$ST/decisions/$w.deadbeef.json"
    echo x > "$ST/footgun-seen/$w.pipe-buffer"
    printf '%s\twrapped\n'        "$w" >  "$ST/idle-state.tsv"
    printf '%s\t1785370294\n'     "$w" >  "$ST/engagement-log.tsv"
    printf '%s\t0\t0\t1\tmachine\t0\n' "$w" > "$ST/operator-engaged.tsv"
    printf '%s\tover\n'           "$w" >  "$ST/over-limit-state.tsv"
    printf '%s\t1\tpaste-followup\n' "$w" > "$ST/machine-input.tsv"
    # An unrelated window, to prove the prune is scoped.
    printf 'other-window\twrapped\n' >> "$ST/idle-state.tsv"
}
rm -rf "$ST"; seed_surfaces kompot-panelL

# The manifest must be non-empty — an empty array would make every
# assertion below vacuously true.
(( ${#BK_RETIRE_SURFACES[@]} >= 15 ))
assert_rc "#602 the surface manifest is populated (not vacuous)" $? 0

refs=$(bk_state_refs_window "$ST" kompot-panelL)
assert_contains "#602 idle-state.tsv IS a tracked surface (the missed one)" \
    "$refs" "idle-state.tsv"
n_before=$(printf '%s\n' "$refs" | grep -c .)
(( n_before >= 15 ))
assert_rc "#602 a freshly-seeded window is detected on every seeded surface" $? 0

bk_prune_window_state "$ST" kompot-panelL
leftover=$(bk_state_refs_window "$ST" kompot-panelL)
assert_empty "#602 after teardown NO surface references the retired window" "$leftover"
# The reported symptom, named explicitly.
assert_not_contains "#602 idle-state.tsv no longer holds the retired row" \
    "$(cat "$ST/idle-state.tsv" 2>/dev/null)" "kompot-panelL"
# Scope: the prune must not have eaten the neighbours.
assert_contains "#602 CONTROL: an unrelated window's row SURVIVES the prune" \
    "$(cat "$ST/idle-state.tsv")" "other-window"

# `ng retire-window` end-to-end, on a window absent from tmux (the
# preflight has nothing live to protect, so it is correctly skipped).
#
# `--assume-absent` keeps this hermetic rather than dependent on whether the
# environment happens to have a live tmux server. CI installs tmux but starts
# no server, so `list-windows` fails and the resolver correctly reports rc 3
# "could not look" (your-org/nexus-code#699), which retire-window refuses by
# design — it must never prune the state of a window it did not OBSERVE. The
# flag asserts what is true in this fixture (kompot-panelL exists nowhere) and
# does not weaken the assertions below: with a live server the resolver
# returns rc 1 and the flag is never consulted. The teardown property being
# tested here is the prune-and-verify, not the tmux lookup.
rm -rf "$ST"; seed_surfaces kompot-panelL
rw_out=$(run_hermetic NEXUS_STATE_DIR="$ST" -- \
    bash "$REPO_ROOT/monitor/ng" retire-window kompot-panelL --reason test --assume-absent 2>&1); rw_rc=$?
assert_rc "#602 ng retire-window exits 0 on a clean teardown" "$rw_rc" 0
assert_contains "#602 …and ASSERTS the property, not that the rm's returned 0" \
    "$rw_out" "no state surface references it"
assert_not_contains "#602 …leaving idle-state.tsv clean" \
    "$(cat "$ST/idle-state.tsv" 2>/dev/null)" "kompot-panelL"

# --dry-run must report without mutating. A "dry run" that prunes is the
# same class of lie as a verb reporting work it did not do.
rm -rf "$ST"; seed_surfaces kompot-panelL
rw_out=$(run_hermetic NEXUS_STATE_DIR="$ST" -- \
    bash "$REPO_ROOT/monitor/ng" retire-window kompot-panelL --dry-run 2>&1)
assert_contains "#602 --dry-run NAMES idle-state.tsv" "$rw_out" "idle-state.tsv"
assert_contains "#602 CONTROL: --dry-run did NOT prune" \
    "$(cat "$ST/idle-state.tsv" 2>/dev/null)" "kompot-panelL"

# NEGATIVE CONTROL — the completeness check must FAIL when a surface is
# deliberately left dirty, and must NAME that surface. A check that
# reports "clean" unconditionally would pass every assertion above; this
# is the one that distinguishes them.
rm -rf "$ST"; seed_surfaces kompot-panelL
bk_prune_window_state "$ST" kompot-panelL
printf 'kompot-panelL\twrapped\n' >> "$ST/idle-state.tsv"
leftover=$(bk_state_refs_window "$ST" kompot-panelL)
assert_contains "#602 NEGATIVE CONTROL: a dirty surface is DETECTED" \
    "$leftover" "idle-state.tsv"
assert_contains "#602 …and reported with its kind, so it is actionable" \
    "$leftover" "tsv"

echo
echo "=== #615: one live await per channel; the park ends when the verdict lands ==="

SKST="$WORK/state615"
mkdir -p "$SKST/skeptic/pending"
sk() { run_hermetic NEXUS_STATE_DIR="$SKST" -- \
        bash "$REPO_ROOT/monitor/skeptic-channel.sh" "$@" 2>&1; }

# A worker enters await with a live pending marker; the skeptic then
# records its verdict (which removes the marker) but never runs `close`,
# so no DONE ever arrives. The old behaviour blocked to timeout while
# refreshing the very heartbeat that was then read as proof the wait was
# healthy. Two workers sat parked for hours this way.
echo 1 > "$SKST/skeptic/pending/w615"
sk init w615 >/dev/null 2>&1
# Remove the marker only AFTER `await` has certainly started and seen it
# live. The delay must exceed process start-up: if the marker vanishes
# before the first poll, `marker_seen` never latches and the run
# correctly (per the negative control below) times out instead — which
# would make this a flaky test rather than a failing one.
( sleep 4; rm -f "$SKST/skeptic/pending/w615" ) &
_rm_pid=$!
out=$(sk await w615 --timeout 25 --interval 1); rc=$?
wait "$_rm_pid" 2>/dev/null
assert_rc "#615 await ENDS on counterpart-finished (11), not on timeout (4)" "$rc" 11
assert_contains "#615 …with a distinct, loud outcome token" "$out" "COUNTERPART-FINISHED"
assert_contains "#615 …explaining that no DONE can arrive" "$out" "without closing the channel"

# NEGATIVE CONTROL — a worker that never had a marker must NOT read that
# absence as a resolution. Without the marker_seen latch this would exit
# 11 immediately, silently retiring workers whose skeptic never ran.
rm -f "$SKST/skeptic/pending/w616"
sk init w616 >/dev/null 2>&1
out=$(sk await w616 --timeout 2 --interval 1); rc=$?
assert_rc "#615 NEGATIVE CONTROL: no marker ever seen ⇒ timeout (4), NOT 11" "$rc" 4
assert_not_contains "#615 …and no counterpart-finished claim is made" \
    "$out" "COUNTERPART-FINISHED"

# The singleton record: `await` claims the channel and releases it.
chan_dir=$(sk dir w615 2>/dev/null | tail -1)
assert_no_file "#615 the await-owner record is released on exit" "$chan_dir/.await-owner"

# Reaping targets a RECORDED pid, never a pattern — a pgrep by script
# basename once matched, and a pkill then killed, four unrelated
# production services. Prove the identity check rejects a foreign pid.
if declare -F _await_pid_is_ours >/dev/null 2>&1; then :; fi
_await_pid_is_ours_probe=$(
    # shellcheck source=monitor/skeptic-channel.sh
    NEXUS_STATE_DIR="$SKST" bash -c '
        set -uo pipefail
        eval "$(sed -n "/^_await_pid_is_ours()/,/^}/p" "$1")"
        # $$ is this shell — a bash, but NOT a skeptic-channel await.
        if _await_pid_is_ours "$$" w615; then echo MATCHED; else echo REJECTED; fi
        if _await_pid_is_ours 999999999 w615; then echo MATCHED; else echo REJECTED; fi
    ' _ "$REPO_ROOT/monitor/skeptic-channel.sh"
)
assert_eq "#615 the reap identity check rejects a non-await pid AND a dead pid" \
    "$_await_pid_is_ours_probe" "$(printf 'REJECTED\nREJECTED')"

echo
echo "=== #607: paste consumption is three-valued, never a false 'no' ==="

SE_ST="$WORK/state607"
mkdir -p "$SE_ST/heartbeat" "$WORK/cc/projects/proj"
# shellcheck source=monitor/_submit_evidence.sh
source "$REPO_ROOT/monitor/_submit_evidence.sh"

# The sender (paste-followup.sh) and the watcher must not be able to
# disagree about what a TUI submission IS. `_submit_evidence.sh` says in
# a comment that its selector is kept byte-identical to
# paste-followup.sh's — and a comment asserting a property nothing
# checks is the exact defect this PR closes. So check it: extract both
# selector bodies and compare. Diverge them and this fails.
# The watcher's copy is read from the sourced variable (authoritative);
# the sender's is sed-extracted from its single-quoted literal, minus
# the `| 1` projection that is the only intended difference.
pf_sel=$(sed -n "/^_JQ_SUBMISSION='/,/^| 1'\$/p" "$REPO_ROOT/monitor/paste-followup.sh" \
    | sed "1d; /^| 1'\$/d")
squash() { printf '%s' "$1" | tr -d '[:space:]'; }
assert_eq "#607 the submission selector is IDENTICAL in sender and watcher" \
    "$(squash "$_SE_JQ_SELECT")" "$(squash "$pf_sel")"
# Guard the guard: an extraction that yielded nothing would make the
# comparison above trivially true.
assert_contains "#607 …and the comparison is non-vacuous" \
    "$pf_sel" "promptSource"

# No heartbeat ⇒ no session-id ⇒ nothing to read. That is `unknown`,
# NOT `no`. Reporting `no` here is the #607 defect: the emit that
# follows advises a re-paste, which duplicates completed work.
got=$(se_submission_since w607 "$SE_ST" 1000)
assert_eq "#607 an unreadable surface is 'unknown', never 'no'" "$got" "unknown"

echo '{"session_id":"11111111-2222-3333-4444-555555555555"}' > "$SE_ST/heartbeat/w607.json"
TSCRIPT="$WORK/cc/projects/proj/11111111-2222-3333-4444-555555555555.jsonl"

# A QUEUED submission — the exact record a message that waited behind an
# in-flight turn produces. It fires no UserPromptSubmit hook until the
# turn drains, which is why the hook-only detector called it lost.
{
  echo '{"type":"user","promptSource":"queued","timestamp":"2026-07-29T17:54:00Z","message":{"content":"the brief"}}'
} > "$TSCRIPT"
paste_epoch=$(date -d '2026-07-29T17:47:38Z' +%s 2>/dev/null)
got=$(NEXUS_CC_HOME="$WORK/cc" se_submission_since w607 "$SE_ST" "$paste_epoch")
assert_eq "#607 a QUEUED submission after the paste counts as consumed" "$got" "yes"

# NEGATIVE CONTROL — the genuine-loss path MUST keep working. A paste
# really was lost in the same session and re-issuing was correct, so a
# fix that answered 'yes' unconditionally would be worse than the bug.
: > "$TSCRIPT"
echo '{"type":"user","promptSource":"typed","timestamp":"2026-07-29T10:00:00Z","message":{"content":"older"}}' > "$TSCRIPT"
got=$(NEXUS_CC_HOME="$WORK/cc" se_submission_since w607 "$SE_ST" "$paste_epoch")
assert_eq "#607 NEGATIVE CONTROL: only OLDER submissions ⇒ 'no' (genuine loss still fires)" \
    "$got" "no"

# System-injected lines must not be mistaken for a prompt: Claude Code
# writes <task-notification> as a string-content user line, which a
# content-shape test would happily accept.
echo '{"type":"user","promptSource":"system","timestamp":"2026-07-29T18:00:00Z","message":{"content":"task-notification"}}' > "$TSCRIPT"
got=$(NEXUS_CC_HOME="$WORK/cc" se_submission_since w607 "$SE_ST" "$paste_epoch")
assert_eq "#607 a system task-notification is NOT a submission" "$got" "no"

echo '{"type":"user","promptSource":"sdk","timestamp":"2026-07-29T18:00:00Z","message":{"content":"subagent"}}' > "$TSCRIPT"
got=$(NEXUS_CC_HOME="$WORK/cc" se_submission_since w607 "$SE_ST" "$paste_epoch")
assert_eq "#607 an SDK/subagent turn is NOT a submission" "$got" "no"

# A scan that exceeded its budget has not established absence.
echo '{"type":"user","promptSource":"typed","timestamp":"2026-07-29T10:00:00Z","message":{"content":"old"}}' > "$TSCRIPT"
got=$(SE_TAIL_BYTES=8 NEXUS_CC_HOME="$WORK/cc" se_submission_since w607 "$SE_ST" "$paste_epoch")
assert_eq "#607 a TRUNCATED scan reports 'unknown', not 'no'" "$got" "unknown"

echo
echo "=== #599: re-fire dedup reads the deliverable, not just the inbox ==="

R_ST="$WORK/state599"; mkdir -p "$R_ST/requests"
REPORT="$WORK/r599.md"; echo "## Summary" > "$REPORT"
mk_req() {   # mk_req <state> <report-path>
    local f="$R_ST/requests/20260729T175509Z-nexuscode-overlimit-skeptic-d1.$1.md"
    printf 'spawn-skeptic\n\nreport-path: %s\n' "$2" > "$f"
    printf '%s' "$f"
}

# The stated disposition reader — the fix for the severity-blind
# recommendation. A COUNT cannot tell a nit from a merge-blocker; the
# report's own conclusion can.
d_report="$WORK/d.md"

# The parser under test, extracted the way every call site here extracts it.
# `_disp_full` returns the whole "<state> <source> <detail>" contract line;
# `_disp_state` returns just the state, for assertions that predate #684 and
# are about WHICH disposition was read rather than where it came from.
_disp_full() {   # _disp_full <report-path>
    bash -c 'eval "$(sed -n "/^_skeptic_stated_disposition()/,/^}/p" "$1")"
             _skeptic_stated_disposition "$2"' _ "$REPO_ROOT/monitor/ng" "$1"
}
_disp_state() { local s _r; read -r s _r <<<"$(_disp_full "$1")"; printf '%s' "$s"; }

printf 'Disposition: no-further-pass\n' > "$d_report"
assert_eq "#599 an explicit Disposition line is read" \
    "$(_disp_state "$d_report")" "no-further-pass"

printf '**Disposition**: second-pass\n' > "$d_report"
assert_eq "#599 …in its bold markdown form too" \
    "$(_disp_state "$d_report")" "second-pass"

printf 'No further skeptic pass is warranted.\n' > "$d_report"
assert_eq "#599 …and the canonical prose form" \
    "$(_disp_state "$d_report")" "no-further-pass"

# NEGATIVE CONTROL — a report that states NOTHING must say so. Pre-#684 this
# asserted EMPTY; since #684 the answer has a NAME (`absent`), because the
# empty string also meant "we could not read it" and those two need opposite
# handling. "The report did not say" is still a distinct answer from either
# value, and substituting one is the defect class this closes.
printf 'A long adversarial report discussing whether passes are ever useful.\n' > "$d_report"
assert_eq "#599 NEGATIVE CONTROL: a report stating no disposition yields absent" \
    "$(_disp_state "$d_report")" "absent"

# ---- #678: a findings COUNT must not override a stated disposition ------
#
# The defect: the depth-2 derivation escalated on `findings >= threshold`
# and ignored the report's own disposition. On 2026-08-02 it demanded a
# second pass four times against authors who had explicitly written
# `no-further-pass`; all four were adjudicated and declined, 0 warranted.
# A count measures THOROUGHNESS, not DOUBT — the worst offender filed six
# findings while leading with "safe to merge".
#
# The property: with an explicit disposition present, the DISPOSITION
# decides, and the count does not enter into it. So sweep the count across
# the whole range the threshold can cross and assert the verdict is
# INVARIANT — a single-N test would pass by construction at any N below
# the threshold, which is exactly why the original defect had coverage and
# shipped anyway.
echo "=== #678: an explicit disposition governs; the findings COUNT does not ==="

SK_WORK="$WORK/sk678"
mkdir -p "$SK_WORK"
setup_fake_nexus "$SK_WORK/nexus" >/dev/null 2>&1
mkdir -p "$SK_WORK/nexus/reports"
_sk_pad="Padding that carries this report body past the report-check minimum length so the gate under test is the disposition logic and not the stub check. "
_sk_report() {   # $1 = disposition value ("" = state none at all)
    {
        printf -- '---\nproject: nexus\ndate: 2026-08-03\n'
        printf 'session-id: 00000000-0000-0000-0000-000000000000\n'
        printf 'window: sk678\nstatus: completed\n'
        [[ -n "${1:-}" ]] && printf 'disposition: %s\n' "$1"
        printf -- '---\n\n'
        local s
        for s in Summary "What Was Done" "Current State" "What Remains" "How to Resume"; do
            printf '## %s\n%s%s\n\n' "$s" "$_sk_pad" "$_sk_pad"
        done
    } > "$SK_WORK/nexus/reports/r.md"
}
_sk_run() {   # $1 = disposition, rest = extra ng flags; echoes combined output
    local disp="$1"; shift
    _sk_report "$disp"
    run_hermetic NEXUS_STATE_DIR="$SK_WORK/state" -- \
        bash "$REPO_ROOT/monitor/ng" wrap-up 1 "$SK_WORK/nexus/reports/r.md" \
            --repo override-org/override-repo --skeptic-role "$@" 2>&1
}
_SK_ESCALATED='SECOND-PASS SKEPTIC RECOMMENDED'
_SK_HONOURED='TERMINATES on YOUR stated disposition'

# The sweep. N spans 0..6 — 6 is the real `nexuscode-676sk` count, and the
# default threshold is 1, so every N>=1 crossed it and escalated before.
for _n in 0 1 2 3 4 5 6; do
    _out=$(_sk_run no-further-pass --skeptic-verdict check --skeptic-findings "$_n" --skeptic-depth 1)
    assert_not_contains "#678 stated no-further-pass + findings=$_n does NOT demand a second pass" \
        "$_out" "$_SK_ESCALATED"
done
# …and it terminates for the STATED reason, not incidentally. Without this
# the sweep above would pass just as well if wrap-up crashed before the
# branch ran — the failure mode that makes an absence-assertion vacuous.
for _n in 1 2 3 4 5 6; do
    _out=$(_sk_run no-further-pass --skeptic-verdict check --skeptic-findings "$_n" --skeptic-depth 1)
    assert_contains "#678 …and terminates ON the stated disposition at findings=$_n" \
        "$_out" "$_SK_HONOURED"
done
# N=0 is the pre-existing clean path and must stay distinct: the honoured
# branch must not swallow "there was genuinely nothing to report".
_out=$(_sk_run no-further-pass --skeptic-verdict check --skeptic-findings 0 --skeptic-depth 1)
assert_contains "#678 findings=0 still takes the plain clean-termination path" \
    "$_out" "no substantive new issues"

# CONTROL 1 — a BLANK disposition MUST still escalate. That is genuine
# absence of signal and is the case that should ask (#678 point 4). A fix
# that silenced this too would trade false escalations for lost ones.
_out=$(_sk_run "" --skeptic-verdict check --skeptic-findings 4 --skeptic-depth 1)
assert_contains "#678 CONTROL: a BLANK disposition still escalates" \
    "$_out" "$_SK_ESCALATED"
assert_contains "#678 …and says the blank is why, so the author learns to write one" \
    "$_out" "states NO disposition"

# CONTROL 2 — SEVERITY overrides the stated disposition. A `suspect`
# verdict is the pass's own bottom line, contradicting no-further-pass at
# the level of the verdict rather than a tally.
_out=$(_sk_run no-further-pass --skeptic-verdict suspect --skeptic-findings 2 --skeptic-depth 1)
assert_contains "#678 CONTROL: verdict=suspect overrides a stated no-further-pass" \
    "$_out" "$_SK_ESCALATED"
assert_contains "#678 …and NAMES the override (auditable, not mysterious)" \
    "$_out" "OVERRIDDEN BY: verdict=suspect"
assert_contains "#678 …and states the COUNT is not what escalated it" \
    "$_out" "is NOT what escalated this"
_out=$(_sk_run no-further-pass --skeptic-verdict refuted --skeptic-findings 1 --skeptic-depth 1)
assert_contains "#678 CONTROL: verdict=refuted likewise overrides" \
    "$_out" "$_SK_ESCALATED"

# CONTROL 3 — a recorded worker contradiction overrides. Two parties on
# record disagreeing is what a further pass exists to adjudicate.
_out=$(_sk_run no-further-pass --skeptic-verdict check --skeptic-findings 1 --skeptic-depth 1 \
        --skeptic-contradicted "worker overrode the documented spawn order")
assert_contains "#678 CONTROL: a worker contradiction overrides a stated no-further-pass" \
    "$_out" "$_SK_ESCALATED"
assert_contains "#678 …and names the contradiction as the reason" \
    "$_out" "OVERRIDDEN BY: a recorded worker contradiction"

# CONTROL 4 — the MIRROR. An explicit `second-pass` must escalate even at
# findings=0. If the count governs downward but not upward, "the count is
# not the signal" is only asserted where it reduces work — and the
# direction that fails silent (a dropped request) is the unrecoverable one.
_out=$(_sk_run second-pass --skeptic-verdict credible --skeptic-findings 0 --skeptic-depth 1)
assert_contains "#678 CONTROL: a stated second-pass escalates even at findings=0" \
    "$_out" "$_SK_ESCALATED"
assert_contains "#678 …and attributes the escalation to the AUTHOR, not the count" \
    "$_out" "this escalation is YOURS"

# CONTROL 5 — the depth cap still wins. An honoured disposition must not
# resurrect a chain past max_depth, and the cap's escalate-to-operator arm
# must remain reachable.
_out=$(_sk_run "" --skeptic-verdict suspect --skeptic-findings 3 --skeptic-depth 9)
assert_contains "#678 CONTROL: the max-depth cap still terminates the chain" \
    "$_out" "MAX SKEPTIC DEPTH REACHED"

# ---- #881: an UNSTATED findings count must not become a MEASURED zero ---
#
# The sibling of #601, and the one it left standing. #601 stopped an
# UNREADABLE value becoming `0`; the very next line kept
#     [[ -n "$findings" ]] || findings=0
# which does the same thing to an UNSTATED one. `bk_require_int
# --allow-empty` preserves the empty-vs-invalid distinction on purpose,
# and the default then discarded the surviving half.
#
# Downstream that fabricated 0 was consumed as an OBSERVATION: printed as
# `new findings : 0`, logged as `"findings":"0"`, and fed to the
# recursion gate. Measured on the operator log when this was filed: 338
# of 615 `skeptic-verdict` records carry `findings=0` and NOT ONE can be
# classified — two wrap-ups differing only in whether the flag was passed
# emitted byte-identical records across every event the verb writes.
#
# THE TEST IS THE ABSENCE ITSELF. A test asserting `findings == 0` after
# an omission would PIN the bug, which is roughly how it survived #601.
# What must hold is that omission and an explicit 0 are DISTINGUISHABLE
# on disk — so the assertions compare the two records rather than
# checking either one against a value.
echo "=== #881: an omitted --skeptic-findings is recorded as ABSENT, not as 0 ==="

SK881="$WORK/sk881"
mkdir -p "$SK881"
setup_fake_nexus "$SK881/nexus" >/dev/null 2>&1
mkdir -p "$SK881/nexus/reports"
_sk881_report() {   # $1 = disposition value ("" = state none at all)
    {
        printf -- '---\nproject: nexus\ndate: 2026-08-14\n'
        printf 'session-id: 00000000-0000-0000-0000-000000000000\n'
        printf 'window: sk881\nstatus: completed\n'
        [[ -n "${1:-}" ]] && printf 'disposition: %s\n' "$1"
        printf -- '---\n\n'
        local s
        for s in Summary "What Was Done" "Current State" "What Remains" "How to Resume"; do
            printf '## %s\n%s%s\n\n' "$s" "$_sk_pad" "$_sk_pad"
        done
    } > "$SK881/nexus/reports/r.md"
}
# Fresh state dir per run, keyed by the caller's tag, so each invocation's
# action log holds exactly its own records — no filtering, no last-line
# heuristics, nothing that could quietly read a neighbour's row.
_sk881_run() {   # $1 = tag, $2 = disposition, rest = extra ng flags
    local tag="$1" disp="$2"; shift 2
    _sk881_report "$disp"
    run_hermetic NEXUS_STATE_DIR="$SK881/state-$tag" -- \
        bash "$REPO_ROOT/monitor/ng" wrap-up 1 "$SK881/nexus/reports/r.md" \
            --repo override-org/override-repo --skeptic-role "$@" 2>&1
}
# The `skeptic-verdict` record that run wrote, ts stripped. Prints the
# literal `<NO-RECORD>` rather than empty on failure: an empty string
# compares equal to another empty string, and two runs that both wrote
# nothing would then "agree" — #881 reproduced inside its own test.
_sk881_rec() {   # $1 = tag
    local f="$SK881/state-$1/action-log.jsonl"
    [[ -s "$f" ]] || { printf '<NO-RECORD>'; return 0; }
    local r
    r=$(jq -c 'select(.event=="skeptic-verdict")|del(.ts)' "$f" 2>/dev/null)
    [[ -n "$r" ]] || { printf '<NO-RECORD>'; return 0; }
    printf '%s' "$r"
}

_out_zero=$(_sk881_run zero "" --skeptic-verdict credible --skeptic-depth 1 --skeptic-findings 0)
_out_omit=$(_sk881_run omit "" --skeptic-verdict credible --skeptic-depth 1)
_rec_zero=$(_sk881_rec zero)
_rec_omit=$(_sk881_rec omit)

# Guard the guard: both runs must actually have produced a record, or
# every comparison below is vacuous.
assert_not_contains "#881 the explicit-0 run wrote a skeptic-verdict record" \
    "$_rec_zero" "<NO-RECORD>"
assert_not_contains "#881 the omitted run wrote a skeptic-verdict record" \
    "$_rec_omit" "<NO-RECORD>"

# THE CONTRACT. Not "what value did it log" — whether the two states are
# distinguishable at all.
#
# Written through `assert_eq` rather than a hand-rolled if/ok/bad, because
# THIS SUITE HAS NO `ok`/`bad`: `_test_helpers.sh` exports `assert_*` and
# `_th_pass`/`_th_fail`, and a bare `ok`/`bad` call exits 127 counted by
# NOTHING — the suite stays green while its most load-bearing check never
# runs. That is the failure this file's own assertion-count floor exists
# to catch, and it was reproduced HERE, on the #881 assertion, during
# authoring. Recorded rather than quietly corrected: the trap is that a
# 127 leaves no trace in the verdict, only in the count.
_sk881_cmp=different
[[ "$_rec_zero" == "$_rec_omit" ]] && _sk881_cmp="IDENTICAL: $_rec_zero"
assert_eq "#881 an explicit 0 and an omitted flag are DISTINGUISHABLE in the action log" \
    "$_sk881_cmp" "different"

# …and distinguishable in the direction that says which is which.
assert_contains "#881 an explicit 0 is recorded as STATED" \
    "$_rec_zero" '"findings-stated":"true"'
assert_contains "#881 …carrying the measured count" "$_rec_zero" '"findings":"0"'
assert_contains "#881 an omitted flag is POSITIVELY recorded as unstated" \
    "$_rec_omit" '"findings-stated":"false"'
# NO SENTINEL. Absent must be absent: a `-1`, an empty string or any other
# in-band marker is the same defect in a new costume, because a consumer
# can do arithmetic on it without noticing nobody supplied it.
assert_not_contains "#881 …and carries NO findings key at all (absent is absent)" \
    "$_rec_omit" '"findings"'
assert_not_contains "#881 …no -1 sentinel" "$_rec_omit" '-1'

# The PRINTER is a consumer too — it is what the skeptic actually reads.
assert_contains "#881 the terminal says 'not stated', not a number" \
    "$_out_omit" "new findings    : not stated"
assert_not_contains "#881 …and never prints the fabricated zero" \
    "$_out_omit" "new findings    : 0"
assert_contains "#881 CONTROL: an explicit 0 still prints as 0" \
    "$_out_zero" "new findings    : 0"

# The RECURSION GATE. With nothing stated on either surface, no party is
# on record saying the chain may end, so it must not say so for them.
assert_not_contains "#881 an unstated count does NOT silently terminate the chain" \
    "$_out_omit" "no substantive new issues"
assert_contains "#881 …it escalates instead" "$_out_omit" "$_SK_ESCALATED"
assert_contains "#881 …and names the absence as the cause, not a finding" \
    "$_out_omit" "STATED NEITHER A COUNT NOR A DISPOSITION"
assert_contains "#881 …and does not launder the absence into a discovery" \
    "$_out_omit" "not because this pass found substantive"
assert_contains "#881 …and spells out both one-line remedies" \
    "$_out_omit" "--skeptic-findings 0"

# CONTROL 1 — the legitimate clean pass is UNCHANGED. wrap-up is on every
# agent's exit path; a fix that escalates a real 0 would push workers to
# route around the verb, and the hand-off record degrades.
assert_contains "#881 CONTROL: an explicit 0 still terminates cleanly" \
    "$_out_zero" "no substantive new issues"
assert_not_contains "#881 CONTROL: …and does not escalate" "$_out_zero" "$_SK_ESCALATED"

# CONTROL 2 — a stated disposition still governs, count or no count. This
# is #678's rule, and #881 must not quietly repeal it: an author who read
# the evidence and wrote `no-further-pass` is not made to also supply a
# tally.
_out_nfp=$(_sk881_run nfp no-further-pass --skeptic-verdict credible --skeptic-depth 1)
assert_contains "#881 CONTROL: an unstated count + stated no-further-pass still TERMINATES" \
    "$_out_nfp" "TERMINATES"
assert_not_contains "#881 CONTROL: …and does not escalate" "$_out_nfp" "$_SK_ESCALATED"
# …but it must say WHICH termination this is. "No substantive new issues"
# is a claim about the evidence and must not be printed over a count that
# was never taken.
assert_contains "#881 …and says the termination is the DISPOSITION's, not a measurement" \
    "$_out_nfp" "you stated no findings count"
assert_not_contains "#881 …and does NOT claim it found nothing" \
    "$_out_nfp" "no substantive new issues"

# CONTROL 3 — the MIRROR. A stated `second-pass` still escalates as the
# AUTHOR's, and must not be re-attributed to the absence.
_out_2p=$(_sk881_run twopass second-pass --skeptic-verdict credible --skeptic-depth 1)
assert_contains "#881 CONTROL: an unstated count + stated second-pass escalates" \
    "$_out_2p" "$_SK_ESCALATED"
assert_contains "#881 …attributed to the AUTHOR" "$_out_2p" "this escalation is YOURS"
assert_not_contains "#881 …and not to a count that derives nothing" \
    "$_out_2p" "would have derived a clean termination"

# CONTROL 4 — severity still wins over everything, with no count present.
_out_susp=$(_sk881_run susp no-further-pass --skeptic-verdict suspect --skeptic-depth 1)
assert_contains "#881 CONTROL: verdict=suspect still overrides with no count stated" \
    "$_out_susp" "$_SK_ESCALATED"
assert_contains "#881 …and the override reason stays the verdict" \
    "$_out_susp" "OVERRIDDEN BY: verdict=suspect"
assert_contains "#881 …and it does not blame a threshold it never applied" \
    "$_out_susp" "threshold 1 was never applied"

# CONTROL 5 — #601 is not regressed by any of this: a PROSE count is still
# refused rather than silently becoming either 0 or "not stated". The
# three states must stay three.
_out_prose=$(_sk881_run prose "" --skeptic-verdict credible --skeptic-depth 1 \
                --skeptic-findings "four, one merge-blocking")
assert_contains "#601/#881 prose is still REFUSED, not coerced to 'not stated'" \
    "$_out_prose" "must be an unsigned integer"
assert_not_contains "#601/#881 …and does not reach the verdict banner" \
    "$_out_prose" "new findings"

# ---- #879: the opt-out's CONTRADICTIONS are refused at PARSE time ------
#
# `--not-a-skeptic-verdict` says "this wrap-up is not a skeptic verdict".
# `--skeptic-role` and `--skeptic-verdict` each say it is. A caller that
# types both holds a wrong belief about which hand-off it is performing,
# and resolving the contradiction by precedence would pick one silently
# (#605: a verb that ignores a supplied argument must fail loudly).
#
# It must refuse at PARSE time, not inside the skeptic step — by the time
# that runs the report has been uploaded and the comment posted, so a
# rejected value strands a half-completed hand-off. That is #601's
# hoisting argument, and it applies verbatim here.
echo "=== #879: --not-a-skeptic-verdict contradictions refuse before the hand-off ==="

_sk879_run() {   # rest = ng flags after the report path
    _sk881_report ""
    run_hermetic NEXUS_STATE_DIR="$SK881/state-879" -- \
        bash "$REPO_ROOT/monitor/ng" wrap-up 1 "$SK881/nexus/reports/r.md" \
            --repo override-org/override-repo "$@" 2>&1
}

_out879=$(_sk879_run --not-a-skeptic-verdict "authored this patch myself in this window" \
                     --skeptic-role); _rc879=$?
assert_rc "#879 --not-a-skeptic-verdict + --skeptic-role is REFUSED" "$_rc879" 1
assert_contains "#879 …naming the contradiction, not a generic usage dump" \
    "$_out879" "contradicts --skeptic-role"
_out879=$(_sk879_run --not-a-skeptic-verdict "authored this patch myself in this window" \
                     --skeptic-verdict credible); _rc879=$?
assert_rc "#879 --not-a-skeptic-verdict + --skeptic-verdict is REFUSED" "$_rc879" 1
assert_contains "#879 …naming that contradiction too" \
    "$_out879" "contradicts --skeptic-verdict"
# …and it refused BEFORE the hand-off, so nothing was published. The
# upload/comment banner is the observable proxy for "we got that far".
assert_not_contains "#879 …and refused BEFORE uploading anything" \
    "$_out879" "Full report:"

# CONTROL — the flag alone, on an unstamped off-tmux wrap-up, must not
# become a new way to fail. It is refused as INERT (there is no role to
# opt out of), and the message says which, so the caller learns the
# window's actual state rather than re-typing flags.
_out879=$(_sk879_run --not-a-skeptic-verdict "this window was never stamped as a skeptic"); _rc879=$?
assert_rc "#879 CONTROL: the flag on an unstamped window is refused as inert" "$_rc879" 1
assert_contains "#879 CONTROL: …and says WHY it is inert" "$_out879" "is inert here"

# ---- #906(A)/#883: every flag wrap-up PARSES must be ADVERTISED --------
#
# `sk900` measured 12 flags parsed by `ng` verbs and absent from that
# verb's own `--help`; ELEVEN were the `--skeptic-*` family, all on this
# verb. A correct mechanism behind a lying interface is #883's class, and
# it is how #879 came to look like a missing feature: the caller cannot
# consult a flag that is not advertised, so the only visible path out of
# the role gate was to assert a verdict.
#
# Scoped deliberately to the flags THIS branch touches the interface of —
# the skeptic family plus the new opt-out. The rest of #906(A) (other
# verbs) is not closed here and is not claimed to be.
#
# TWO FAILURE MODES, and the second is the one #906(B) is about. A drift
# check is a DERIVATION, and #900's derived synopsis degraded SILENTLY on
# an arm it could not parse — advertising a value-taking flag as a switch,
# confidently and wrongly. So this check refuses to be vacuous: if the
# extractor finds ZERO arms it FAILS rather than passing with an empty
# set. An extraction that returns nothing is not evidence of no drift; it
# is evidence the extractor did not run. That is this file's own #881
# thesis, arriving inside the remedy for #879.
echo "=== #906(A): wrap-up's parsed skeptic flags must appear in its --help ==="

# The arg loop, bounded to cmd_wrap_up. `sed` between the function header
# and the loop's terminator, then take the `--flag)` arms.
_wu_loop=$(sed -n '/^cmd_wrap_up()/,/^}/p' "$REPO_ROOT/monitor/ng")
_wu_flags=$(grep -oE '^\s+--(skeptic-[a-z-]+|not-a-skeptic-verdict)\)' <<<"$_wu_loop" \
            | tr -d ' )' | sort -u)
_wu_n=$(printf '%s\n' "$_wu_flags" | grep -c . )
# THE ANTI-VACUITY GATE. Assert against a floor derived from what the
# protocol documents, not from the extraction itself — a check that
# compares an extraction to itself always agrees.
if (( _wu_n >= 12 )); then
    _th_pass; printf '  PASS: #906(A) the extractor found the skeptic arg loop (%d arms)\n' "$_wu_n"
else
    _th_fail
    printf '  FAIL: #906(A) the extractor found only %d arms — it did NOT run; every\n' "$_wu_n" >&2
    printf '        comparison below would be vacuously green (#906 finding B)\n' >&2
fi

_wu_help=$(run_hermetic -- bash "$REPO_ROOT/monitor/ng" wrap-up --help 2>&1)
# The help surface must itself be non-empty, for the same reason.
assert_contains "#906(A) …and \`wrap-up --help\` produced a synopsis at all" \
    "$_wu_help" "usage: ng wrap-up"
_wu_missing=""
while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    grep -qF -- "$_f" <<<"$_wu_help" || _wu_missing="${_wu_missing:+$_wu_missing }$_f"
done <<<"$_wu_flags"
assert_eq "#906(A) every parsed skeptic flag is advertised in --help" \
    "${_wu_missing:-none}" "none"

# ---- #681 F1: the disposition parser GOVERNS, so it must not misparse ---
#
# #681 promoted `_skeptic_stated_disposition` from ADVISORY to GOVERNING.
# Before it, a misparse mislabelled a banner and the spawn request was filed
# anyway (`recommendation=DISPUTED`) — one orchestrator glance. After it, a
# misparse in the suppressing direction means NO REQUEST IS FILED. Same parser,
# new blast radius, and the new one is the unrecoverable-silence direction the
# PR itself argues about.
#
# The old parser squashed word boundaries (`tr -dc 'a-z-'`) and then
# SUBSTRING-matched, so a MENTION of a token was indistinguishable from a
# STATEMENT of one. Three inversions were demonstrated; the sharpest handed an
# author who wrote `second-pass` the value `no-further-pass`, because the `case`
# arms listed `*no-further-pass*` FIRST and so won regardless of position.
#
# Every rule below is FAIL-SAFE: doubt resolves to empty, and empty ESCALATES.
_d_report="$WORK/d681.md"
_disp_write() {   # $1 = frontmatter disposition line ("" = none), $2 = body
    { printf -- '---\nproject: p\ndate: 2026-08-03\n'
      [[ -n "${1:-}" ]] && printf '%s\n' "$1"
      printf -- '---\n\n%s\n' "${2:-body}"
    } > "$_d_report"
}
# STATE only — what the pre-#684 assertions below were always about.
_disp() { _disp_write "${1:-}" "${2:-}"; _disp_state "$_d_report"; }
# The full contract line, for the #684 assertions that are about provenance.
_dispf() { _disp_write "${1:-}" "${2:-}"; _disp_full "$_d_report"; }

echo "=== #681 F1: a governing parser must not turn a mention into a verdict ==="

# The canonical forms must keep working. A guard that refuses everything is not
# a guard, and these are the forms skills/nexus.skeptic tells skeptics to write.
assert_eq "#681 F1 canonical no-further-pass still parses" \
    "$(_disp 'disposition: no-further-pass')" "no-further-pass"
assert_eq "#681 F1 canonical second-pass still parses" \
    "$(_disp 'disposition: second-pass')" "second-pass"
assert_eq "#681 F1 bold markdown form still parses" \
    "$(_disp '**Disposition**: second-pass')" "second-pass"
assert_eq "#681 F1 underscored + trailing period still parses" \
    "$(_disp 'Disposition: no_further_pass.')" "no-further-pass"
assert_eq "#681 F1 canonical PROSE form still parses (the #599 guard)" \
    "$(_disp '' 'No further skeptic pass is warranted.')" "no-further-pass"

# LEGACY SPACED FORMS. The old normaliser (`tr -dc 'a-z-'`) deleted spaces, so
# `no further pass` reached the token arms. The first cut of the #681 F1 fix
# preserved word boundaries and silently stopped accepting it — fail-safe in
# DIRECTION (it escalates) but it would have escalated AGAINST an author's
# stated intent, which is #678's own defect wearing a different hat. Caught by
# diffing new-vs-old parser output over legacy inputs, not by a failing test —
# so these assertions exist to make sure it cannot come back silently.
assert_eq "#681 F1 legacy spaced 'no further pass' still parses (no silent regression)" \
    "$(_disp 'disposition: no further pass')" "no-further-pass"
assert_eq "#681 F1 legacy CamelCase 'NoFurtherPass' still parses" \
    "$(_disp 'disposition: NoFurtherPass')" "no-further-pass"
# ...and the symmetric form the OLD parser rejected for want of a `secondpass`
# arm. Accepting it is the escalating direction and removes an asymmetry where
# only the SUPPRESSING token had a spaced spelling.
assert_eq "#681 F1 spaced 'second pass' now parses too (asymmetry the old arms had)" \
    "$(_disp 'disposition: second pass')" "second-pass"

# (a2) THE SHARPEST — an explicitly stated `second-pass` must never come back
# as its opposite. This is the assertion the fix exists for.
assert_eq "#681 F1 (a2) a field naming BOTH tokens refuses; a stated second-pass is NEVER inverted to no-further-pass" \
    "$(_disp 'disposition: second-pass — I explicitly reject no-further-pass here')" "unreadable"

# ARM ORDERING — the trap, asserted directly. The old failure was that the
# `case` arm listed first WON, so the answer depended on which token the author
# happened to mention rather than on which they stated. Assert the property
# that kills it: the verdict is INDEPENDENT of the order the tokens appear in.
# The two arms are also mutually exclusive by construction now (`no-further-pass`
# and `second-pass` share no exact value), so reordering them cannot change any
# result — order-independence is structural, not merely observed here.
_d_fwd=$(_disp 'disposition: second-pass — I explicitly reject no-further-pass here')
_d_rev=$(_disp 'disposition: no-further-pass — but on reflection I want a second-pass')
assert_eq "#681 F1 ARM ORDER cannot decide: both token orderings give the SAME answer" \
    "$_d_fwd" "$_d_rev"
assert_eq "#681 F1 …and that shared answer REFUSES (ambiguous ⇒ escalate, the fail-safe direction)" \
    "$_d_rev" "unreadable"

# (a) a single token MENTIONED inside a sentence that rejects it.
assert_eq "#681 F1 (a) a field that MENTIONS a token while rejecting it is not a statement of it" \
    "$(_disp 'disposition: I considered no-further-pass and REJECT it; a skeptic must review this')" "unreadable"

# (a3) the prose fallback matching a DISCUSSION mid-clause — the hazard the
# function's own header claimed to be narrow enough to avoid while not avoiding
# it. A conclusion is stated as a sentence; a discussion is embedded.
assert_eq "#681 F1 (a3) mid-clause prose DISCUSSION does not invert the conclusion" \
    "$(_disp '' 'I weighed whether no further pass is warranted and concluded it is NOT.')" "absent"

# A present-but-unparseable field must NOT fall through to the prose scan —
# otherwise the report's ARGUMENT silently replaces the author's CONCLUSION.
assert_eq "#681 F1 an unparseable field does not fall through to body prose" \
    "$(_disp 'disposition: see the discussion below' 'No further skeptic pass is warranted.')" "unreadable"

# Both prose forms present ⇒ ambiguous ⇒ refuse (the prose half of the
# both-tokens rule; this arm is the reachable one now that the field arm
# requires an exact token).
assert_eq "#681 F1 prose stating BOTH conclusions refuses rather than taking the first match" \
    "$(_disp '' 'No further skeptic pass is warranted.
A second skeptic pass is warranted.')" "unreadable"

# NEGATIVE CONTROL — unchanged from #599: a report that states nothing yields
# empty, not a guessed disposition.
assert_eq "#681 F1 NEGATIVE CONTROL: a report stating no disposition is ABSENT, not unreadable" \
    "$(_disp '' 'A long adversarial report discussing whether passes are ever useful.')" "absent"

# ---- #681 F4: the spawn reason must name the ACTUAL cause ---------------
#
# `_SK_SPAWN_REASONS` was set to `second-pass-dispute` unconditionally, on the
# grounds that "a recursion is by definition a prior-skeptic dispute". #681
# routed the MIRROR through that same path — the case where the author
# EXPLICITLY ASKED for the next pass — making the by-definition label false on
# its face and telling the orchestrator's adjudication step the opposite of what
# happened.
echo "=== #681 F4: the filed reason names the actual cause, not a assumed one ==="

_out=$(_sk_run second-pass --skeptic-verdict credible --skeptic-findings 0 --skeptic-depth 1)
assert_contains "#681 F4 the mirror still escalates (unchanged)" "$_out" "$_SK_ESCALATED"
_out=$(_sk_run no-further-pass --skeptic-verdict suspect --skeptic-findings 2 --skeptic-depth 1)
assert_contains "#681 F4 a severity override still escalates (unchanged)" "$_out" "$_SK_ESCALATED"
# These are SOURCE assertions, and that is weaker than behaviour — said plainly
# rather than dressed up. The reason string only reaches a filed request when a
# real tmux source window resolves, which this suite does not mock (the mock
# lives in monitor/watcher/test-ng-wrap-up.sh). What is checkable here is that
# the assignment is CONDITIONAL and that the three causes carry three DISTINCT
# labels; a behavioural assertion on the filed request body belongs in the
# wrap-up suite alongside its existing `spawn_req_body` helpers.
#
# NOTE for whoever extends this: `assert_not_contains` runs `grep -qF` over the
# needle, and grep -F treats EACH LINE of a multi-line needle as a SEPARATE
# pattern. A multi-line needle therefore matches if ANY of its lines appears —
# such an assertion can never pass. Keep needles single-line.
_ng_reasons=$(sed -n '/_SK_SPAWN_EFFECTIVE="second-pass"/,/_SK_SPAWN_CONTRADICTED=/p' "$REPO_ROOT/monitor/ng")
assert_contains "#681 F4 the author-requested cause has its OWN label" \
    "$_ng_reasons" "second-pass-author-requested"
assert_contains "#681 F4 a severity override of a stated disposition is named as such" \
    "$_ng_reasons" "disposition-overridden"
assert_contains "#681 F4 the reason is assigned CONDITIONALLY, keyed on the mirror flag" \
    "$_ng_reasons" "if (( _sk_author_asked == 1 )); then"
assert_contains "#685 an author who CONCURS is not disputing anything" \
    "$_ng_reasons" "second-pass-author-concurs"
assert_contains "#685 …nor is a report that stated no disposition at all" \
    "$_ng_reasons" "second-pass-no-disposition-stated"
# Assert the COUNT so collapsing two arms onto one string (the regression that
# would silently restore the old by-definition label) reddens here rather than
# passing on the greps above — and assert DISTINCTNESS, because the count alone
# cannot see it: six assignments of the same string still count six. The
# property the label space needs is that no two causes share a name.
_ng_label_count=$(printf '%s\n' "$_ng_reasons" | grep -c '_SK_SPAWN_REASONS="' || true)
_ng_label_uniq=$(printf '%s\n' "$_ng_reasons" \
    | sed -n 's/.*_SK_SPAWN_REASONS="\([^"]*\)".*/\1/p' | sort -u | grep -c .)
assert_eq "#681 F4 exactly six causes are assigned (not one unconditional)" \
    "$_ng_label_count" "6"
assert_eq "#685 …and no two of them share a label (distinctness, not just count)" \
    "$_ng_label_uniq" "6"

# ---- #684: absent and unreadable are DIFFERENT answers ------------------
#
# The parser returned the SAME empty sentinel for "the author stated nothing"
# and "the author stated it and we could not read it". #681 had just built a
# GOVERNING policy on that sentinel, so a disposition that formatted unluckily
# silently became an escalation against an author who had used the sanctioned
# vocabulary. Both still escalate — that is the fail-safe direction — but only
# one of them should do so QUIETLY.
echo "=== #684: the parser reports WHICH failure it hit, not one silence ==="

# The contract itself: three fields, and a state that is NEVER empty.
_d_fields=$(_dispf 'disposition: no-further-pass' | awk '{print NF}')
assert_eq "#684 the contract is three fields: <state> <source> <detail>" "$_d_fields" "3"

# (1) THE REPORTED DEFECT — a disposition sharing a line with the verdict.
# `**Verdict: X** · **Disposition: no-further-pass.**` parsed EMPTY because the
# field matcher anchored at `^disposition:`. That produced a real depth-2
# escalation against an author who had stated `no-further-pass`.
assert_eq "#684 (1) a disposition sharing the VERDICT's line is read, not missed" \
    "$(_disp '' '**Verdict: `credible`** · **Disposition: no-further-pass.**')" "no-further-pass"
assert_eq "#684 (1) …also in the two other same-line spellings found in the corpus" \
    "$(_disp '' '**Verdict: `check`.** **Disposition: no-further-pass.**')" "no-further-pass"
assert_eq "#684 (1) …and with the verdict and label sharing one bold span" \
    "$(_disp '' '**Verdict: `credible`. Disposition: no-further-pass.**')" "no-further-pass"

# (2) THE DEFECT #684 DID NOT NAME, and the more common one: the label is at
# LINE START (so the old anchor matched) and the VALUE ran past the token into
# commentary, so the exact-token rule rejected it. 3 of the 7 corpus
# false-absents are this shape; the anchoring fix alone recovers under half.
assert_eq "#684 (2) a bolded field whose value is followed by commentary still parses" \
    "$(_disp '' '**Disposition: no-further-pass** — the findings are concrete and fixable.')" \
    "no-further-pass"
assert_eq "#684 (2) …and with the sentence continuing after the bold close" \
    "$(_disp '' '**Disposition: no-further-pass.** Substantive new findings: 4.')" \
    "no-further-pass"
# The bound is the STRUCTURAL `**`, not an em-dash. An unbolded value running
# into commentary that names the other token must still REFUSE — otherwise
# rule (5) would quietly reopen the #681 F1 (a2) inversion.
assert_eq "#684 (2) NEGATIVE CONTROL: an UNBOLDED value naming both tokens still refuses" \
    "$(_disp 'disposition: no-further-pass — but on reflection I want a second-pass')" \
    "unreadable"
# DECLARED BOUNDARY, asserted so it stays a decision rather than an accident.
# An UNBOLDED value followed by a sentence is `unreadable`, NOT the token —
# even though a human reads the intent easily. `**` is a structural markdown
# terminator with one meaning; a period is prose punctuation, and bounding on
# it would be exactly the "tighter regex" #684 says is another proxy. One
# report in 877 has this shape (`your-nexus-sandboxkill`), and the pre-#684
# parser got it wrong too — the difference is that it now says so LOUDLY and
# tells the author how to fix it, instead of reporting a considered silence.
assert_eq "#684 (2) BOUNDARY: an unbolded token followed by prose is unreadable, not the token" \
    "$(_disp '' 'Disposition: no-further-pass. Fixes landed in `ff678db`.')" "unreadable"
# The reserved-field misuse this makes visible: a free-text handoff blob in the
# frontmatter `disposition:` slot. Pre-#684 that returned the same silence as a
# report with no disposition at all, so the hijack was undetectable; it is a
# real corpus case (`your-nexus-burndown3`) and the reason the spawn brief now
# tells workers to use `handoff:`.
assert_eq "#684 (2) a free-text blob in the reserved field is unreadable, not absent" \
    "$(_disp 'disposition: handoff — landed X; Y not started; see the report')" "unreadable"

# (3) PROSE MENTIONS must not become fields now that the label may appear
# mid-line. These are verbatim corpus lines: 8 of the 10 reports whose only
# `disposition:` occurrence is loose are prose, so a naive "match anywhere"
# loosening produces 4x more false candidates than true ones.
for _m in \
    'that touch a nexus-sensitive surface, and their disposition:' \
    "Not re-litigated, and I agree with the worker's disposition: the tree arm" \
    '- Issue **x#405** is open (phased plan; `#402` disposition: merge after P0 only).' \
    'None is a trivial no-content duplicate. Prior operator disposition: **DEFER**.' \
    'Findings that refined the briefed disposition:' \
    '**Against the `#568` disposition: no finding.** Ten of eleven re-measurements' \
    'supports *intent*. Disposition: consolidate preserving current behaviour exactly;' \
    'the request carried `report-stated-disposition: -` because my'; do
    assert_eq "#684 (3) prose MENTION is not a stated field: ${_m:0:44}…" \
        "$(_disp '' "$_m")" "absent"
done
# The sharpest of them, kept separate because it is a report ABOUT this parser
# quoting BOTH tokens inside a markdown table cell. A backticked label is a
# QUOTATION; treating it as a statement is how a doc about the bug acquires it.
assert_eq "#684 (3) a TABLE ROW quoting both tokens in a code span is not a statement" \
    "$(_disp '' '| **`disposition: second-pass — I reject no-further-pass here`** | **`no-further-pass`** |')" \
    "absent"
# `report-stated-disposition` is a DIFFERENT label. Whole-word only.
assert_eq "#684 (3) …and a longer hyphenated label is not this label" \
    "$(_disp '' 'report-stated-disposition: no-further-pass')" "absent"
# …including on the VERDICT-PREFIXED path, which is the only place the
# whole-word rule is not subsumed by the prefix rule: rule (4) passes on the
# line's opening `**Verdict:`, so without rule (1) this line FABRICATES a
# stated `second-pass`. Written because mutating rule (1) reddened NOTHING
# until this case existed — a rule with no reachable test is not a tested rule.
assert_eq "#684 (3) …even after a verdict prefix, where rule (4) alone lets it through" \
    "$(_disp '' '**Verdict: `check`.** report-stated-disposition: second-pass')" "absent"
# CONTROL: `_` is markdown emphasis, not a label separator. Excluding it from
# the whole-word class is what keeps the italic form a field; including it
# rejected `_Disposition_:` while accepting the identical `*Disposition*:`.
assert_eq "#684 (3) CONTROL: italic _Disposition_: is still a field" \
    "$(_disp '' '_Disposition_: second-pass')" "second-pass"
assert_eq "#684 (3) CONTROL: …and so is the asterisk form it must agree with" \
    "$(_disp '' '*Disposition*: second-pass')" "second-pass"

# (3b) A FENCED BLOCK is a quotation, exactly as an inline code span is.
# Found by running the finished parser over the report that documents it: the
# fenced sample `**Disposition: no-further-pass**` parsed as a STATEMENT, in
# the SUPPRESSING direction. Rule (5) is what made it reachable, so the #684
# fix INTRODUCED this — the class re-instantiating itself inside its own fix,
# for the third time in this file's history. Every report about this parser
# quotes a disposition line in a fence, so it is not a corner case.
assert_eq "#684 (3b) a disposition inside a FENCED block is a quotation, not a statement" \
    "$(_disp '' 'Here is the shape that failed:

```
**Disposition: no-further-pass** — the findings are concrete and fixable.
```

That is the example.')" "absent"
assert_eq "#684 (3b) …tilde fences too" \
    "$(_disp '' '~~~
Disposition: second-pass
~~~')" "absent"
# The prose fallback needs the same treatment, or a fenced SAMPLE SENTENCE
# governs. This is the arm the pre-#684 parser also got wrong.
assert_eq "#684 (3b) …and a fenced PROSE conclusion does not govern either" \
    "$(_disp '' '```
No further skeptic pass is warranted.
```')" "absent"
# CONTROL: closing the fence must RESUME scanning, or (3b) silently mutes
# everything after the first code block in a report — which would be a far
# worse regression than the one it fixes, and invisible.
assert_eq "#684 (3b) CONTROL: a real field AFTER a closed fence is still read" \
    "$(_disp '' '```
Disposition: second-pass
```

**Disposition: no-further-pass.**')" "no-further-pass"

# ---- #687 F1: a CONTAINER is not structure ------------------------------
#
# `#687` widened the field scan to accept a same-line prefix, and classified
# `>` `|` and backtick as "structure" alongside `*` `_` `#` `-`. They are not.
# An emphasis mark DECORATES a statement; a CONTAINER delegates the text to
# something else. So a BLOCKQUOTED field — the syntax reports use to quote a
# prior round, and the one a skeptic uses to quote its target — parsed as this
# author's own stated disposition, in the SUPPRESSING direction.
#
# Fourth instance of this guard's own subject appearing inside it, and the
# second in the #687/#688 pair. `#688` closed fences; this closes the rest.
# All zero-instance in the corpus, so the fix is provably invariant over all
# 879 reports — which is why each assertion below is paired with a CONTROL.
echo "=== #687 F1: containers (quote) vs emphasis (decorate) ==="

_disp_after() { _disp '' "$1"; }
# Every container, in the four spellings that actually occur.
assert_eq "#687 F1 a BLOCKQUOTED field is a quotation (the live regression)" \
    "$(_disp_after '> **Disposition: no-further-pass**')" "absent"
assert_eq "#687 F1 …unbolded" \
    "$(_disp_after '> Disposition: no-further-pass')" "absent"
assert_eq "#687 F1 …nested blockquote" \
    "$(_disp_after '>> Disposition: no-further-pass')" "absent"
assert_eq "#687 F1 …and a quoted verdict+disposition line (the #684 shape, quoted)" \
    "$(_disp_after '> **Verdict: `check`.** **Disposition: no-further-pass.**')" "absent"
assert_eq "#687 F1 a TABLE CELL field is tabulated data, not a statement" \
    "$(_disp_after '| Disposition: no-further-pass | notes |')" "absent"
# The HTML comment bites in its MULTI-LINE spelling: the single-line form was
# already rejected by the `<!` residue, so testing only that would have passed
# against a parser with no comment handling at all.
assert_eq "#687 F1 (F2) a MULTI-LINE HTML comment is a container" \
    "$(_disp_after '<!--
**Disposition: no-further-pass**
-->')" "absent"
assert_eq "#687 F1 (F2) …and the single-line form stays rejected" \
    "$(_disp_after '<!-- **Disposition: second-pass** -->')" "absent"

# CONTROLS — one per container. A container-skip that never RESUMES mutes
# every field after the first quote in a report: worse than the leak it fixes,
# and invisible, because it fails toward `absent` and `absent` is silent.
# The #687 skeptic's M3 mutant proved this control is the load-bearing one.
assert_eq "#687 F1 CONTROL: a real field AFTER a blockquote is still read" \
    "$(_disp_after '> quoted prior round
> **Disposition: second-pass**

**Disposition: no-further-pass.**')" "no-further-pass"
assert_eq "#687 F1 CONTROL: …after an HTML comment" \
    "$(_disp_after '<!--
Disposition: second-pass
-->

Disposition: no-further-pass')" "no-further-pass"
assert_eq "#687 F1 CONTROL: …after a table" \
    "$(_disp_after '| Disposition: second-pass | x |

Disposition: no-further-pass')" "no-further-pass"
# CONTROLS — the EMPHASIS marks must keep decorating. Dropping a container
# from the class is only correct if the emphasis marks survive; a fix that
# tightened `structural_only` too far would redden here and nowhere else.
assert_eq "#687 F1 CONTROL: bullet is emphasis/structure, still a field" \
    "$(_disp_after '- Disposition: no-further-pass')" "no-further-pass"
assert_eq "#687 F1 CONTROL: heading likewise" \
    "$(_disp_after '## Disposition: no-further-pass')" "no-further-pass"
assert_eq "#687 F1 CONTROL: bold likewise" \
    "$(_disp_after '**Disposition: no-further-pass**')" "no-further-pass"
assert_eq "#687 F1 CONTROL: the same-line verdict form still parses" \
    "$(_disp_after '**Verdict: `credible`** · **Disposition: no-further-pass.**')" "no-further-pass"

echo "=== #689: the 4-space INDENTED CODE BLOCK — the last container ==="
#
# The one container that does NOT fall out of the container/emphasis rule, and
# the reason is worth keeping: that rule classifies MARKS, and whitespace is a
# member of the EMPHASIS class (`structural_only` strips ` ` and `\t`). Every
# other container is self-identifying from the line's bytes; this one's opener
# is whitespace, so its container-ness is a property of the ENCLOSING BLOCK,
# not of a mark. A bare `^    ` skip is therefore refused — it is a proxy, and
# it drops real dispositions written as list-continuation text.
#
# So the rule measures the property: indented >= 4 columns PAST the enclosing
# list item's content column, AND not interrupting a paragraph. The pair below
# is the whole point — the SAME four spaces, opposite answers, decided by
# block context. A `^    ` implementation passes the first and fails the
# second, so the second is the load-bearing assertion.
assert_eq "#689 a top-level 4-space INDENTED CODE BLOCK is a container" \
    "$(_disp_after 'Some prose.

    Disposition: no-further-pass')" "absent"
assert_eq "#689 …the SAME indent as list continuation is the author SPEAKING" \
    "$(_disp_after '- outer
  - inner
    Disposition: no-further-pass')" "no-further-pass"
# Relative, not absolute: inside a list item the code block starts at the
# item's content column + 4. Absolute-indent implementations fail both of these
# in opposite directions.
assert_eq "#689 …a code block INSIDE a list item is listcol+4, not 4" \
    "$(_disp_after '- outer
  - inner

        Disposition: no-further-pass')" "absent"
assert_eq "#689 …while listcol+0 after a blank is a loose paragraph, still read" \
    "$(_disp_after '- outer
  - inner

    Disposition: no-further-pass')" "no-further-pass"
# The paragraph-interruption rule. Without it, continuation text under a bullet
# would be eaten, which is the noisy false negative #689 refused to buy.
assert_eq "#689 an indented block CANNOT interrupt a paragraph" \
    "$(_disp_after 'Some prose.
    Disposition: no-further-pass')" "no-further-pass"
# The PROSE fallback had the identical hole and #689 names only the field scan.
# One shared program text feeds both scanners; this is what proves it reaches
# the second one.
assert_eq "#689 the PROSE fallback honours the indent too (same shared rule)" \
    "$(_disp_after 'Some prose.

    No further skeptic pass is warranted.')" "absent"
assert_eq "#689 CONTROL: …and unindented prose still infers" \
    "$(_disp_after 'No further skeptic pass is warranted.')" "no-further-pass"
# CONTROL — the container must RESUME. A skip that never ends mutes every
# field after the first indented block, and fails toward the silent `absent`.
assert_eq "#689 CONTROL: a real field AFTER an indented block is still read" \
    "$(_disp_after 'Some prose.

    Disposition: second-pass

Disposition: no-further-pass')" "no-further-pass"
# CONTROL — corpus-attested indents. Every `disposition` line in 2,483 report
# files sits at indent 0, 2 or 3; none at >= 4. These must not move.
assert_eq "#689 CONTROL: corpus-attested indent 2 is untouched" \
    "$(_disp_after '- x
  Disposition: second-pass')" "second-pass"
assert_eq "#689 CONTROL: corpus-attested indent 3 is untouched" \
    "$(_disp_after '- x
   Disposition: second-pass')" "second-pass"
# CONTROL — frontmatter is YAML, not markdown, and is deliberately exempt
# (`bctx = (want == "body")`). A block-scalar continuation is not a code block.
assert_eq "#689 CONTROL: an indented FRONTMATTER field is not a code block" \
    "$(_disp 'handoff: x
disposition: no-further-pass')" "no-further-pass"

# (4) FRONTMATTER WINS over the body. Reports are append-only, so the body is a
# LOG and the frontmatter is the CURRENT-VALUE header. The corpus proof is
# `kompot-consist-sk2`, whose body states the superseded round-4 `second-pass`
# and whose author wrote, verbatim, "the frontmatter now carries the current
# values". Treating that as a conflict would REFUSE a report whose author was
# unambiguous.
_d_state=$(_disp 'disposition: no-further-pass' '**Verdict: `check`. Disposition: second-pass.**')
assert_eq "#684 (4) a frontmatter field OVERRIDES a superseded body one" \
    "$_d_state" "no-further-pass"
_d_src=$(_dispf 'disposition: no-further-pass' '**Disposition: second-pass.**' | awk '{print $2}')
assert_eq "#684 (4) …and says the answer came from the frontmatter" "$_d_src" "frontmatter"
# CONTROL: with no frontmatter field the body IS consulted, or (4) would be
# indistinguishable from "the body is never read".
_d_src=$(_dispf '' '**Disposition: second-pass.**' | awk '{print $2}')
assert_eq "#684 (4) CONTROL: with no frontmatter field, the body still governs" "$_d_src" "body"
# CONTROL: two BODY fields that genuinely disagree have no precedence rule to
# resolve them, so they must refuse rather than let LINE ORDER decide — the
# same trap as the #681 arm ORDER one, a level up.
assert_eq "#684 (4) two disagreeing BODY fields refuse; LINE ORDER cannot decide" \
    "$(_disp '' '**Disposition: no-further-pass.**
**Disposition: second-pass.**')" "unreadable"

# (5) THE THIRD STATE, asserted as a DISTINCTION. Asserting each value alone
# would pass for a parser that returned one constant, which is the shape of the
# defect being fixed.
_d_absent=$(_disp '' 'A long adversarial report that states nothing.')
_d_unread=$(_disp 'disposition: probably fine, I think')
assert_eq "#684 (5) a report stating nothing is 'absent'" "$_d_absent" "absent"
assert_eq "#684 (5) a report stating something unparseable is 'unreadable'" "$_d_unread" "unreadable"
if [[ "$_d_absent" == "$_d_unread" ]]; then
    assert_eq "#684 (5) absent and unreadable are DISTINGUISHABLE (the whole issue)" \
        "$_d_absent" "<a different state from $_d_unread>"
else
    assert_eq "#684 (5) absent and unreadable are DISTINGUISHABLE (the whole issue)" \
        "distinct" "distinct"
fi

# (6) A NAMED-BUT-UNREADABLE report is `unreadable`; NO report named at all is
# `absent`. The caller passes `${_SK_REPORT_PATH:-}`, so both reach the parser.
assert_eq "#684 (6) a report path that cannot be read is 'unreadable', not 'absent'" \
    "$(_disp_state "$WORK/definitely-not-here.md")" "unreadable"
assert_eq "#684 (6) …but NO report path offered is genuine absence of signal" \
    "$(_disp_state '')" "absent"

# (7) A BLOCKQUOTED prose conclusion is a QUOTATION of a prior round, not this
# author's. The pre-#684 prose anchor allowed `>` and so read it as their own —
# live, because append-only reports quote prior rounds in exactly that syntax.
assert_eq "#684 (7) a BLOCKQUOTED prose conclusion does not govern" \
    "$(_disp '' '> No further skeptic pass is warranted.')" "absent"
# CONTROL: the unquoted form still governs, or (7) would be a mute of the whole
# prose fallback rather than of quotations.
assert_eq "#684 (7) CONTROL: the same sentence UNQUOTED still governs" \
    "$(_disp '' 'No further skeptic pass is warranted.')" "no-further-pass"
# …and it is attributed, so a prose-sourced decision is auditable as such.
assert_eq "#684 (7) …and is attributed to prose, not to a field" \
    "$(_dispf '' 'No further skeptic pass is warranted.' | awk '{print $2}')" "prose"

# (8) THE EXTRACTION CONTRACT. Every call site above extracts this function with
# `sed -n '/^_skeptic_stated_disposition()/,/^}/p'`, which stops at the FIRST
# column-0 `}`. The function now contains an embedded awk program, where a
# column-0 brace is the natural formatting — and a truncated extraction is
# still valid-looking bash that silently tests a fragment. Assert the
# round-trip, not the convention.
# The sibling footgun, added after it bit: the embedded awk program is a
# SINGLE-QUOTED string, so one apostrophe in one of its comments ("the line's
# opening…") terminates the quote and breaks the whole of `ng`. Loud here — it
# reddened 78 assertions — but `bash -n` is the check that names the cause
# instead of making every downstream test fail for an unrelated-looking reason.
bash -n "$REPO_ROOT/monitor/ng" 2>/dev/null
assert_rc "#684 (8) monitor/ng parses (an apostrophe in the awk program breaks it)" $? 0

_d_extract=$(sed -n '/^_skeptic_stated_disposition()/,/^}/p' "$REPO_ROOT/monitor/ng")
assert_rc "#684 (8) the EXTRACTED function is syntactically complete" \
    "$(printf '%s' "$_d_extract" | bash -n 2>/dev/null; echo $?)" 0
assert_contains "#684 (8) …and reaches its final return, not a truncated prefix" \
    "$_d_extract" "no-disposition-stated"

# ---- #685: the override decision leaves a disk trace, like the honoured one --
#
# The honoured branch has logged `skeptic-disposition-honoured` since #681; the
# OVERRIDE named its cause only in a printf to the worker's terminal. So the
# honoured rate was measurable and the override rate was not — and the override
# is the higher-stakes half, which makes it the one least likely to be
# questioned and therefore the one that most needs the trace.
echo "=== #685: the skeptic-decision audit trail is two-sided ==="
_ng_disp_arm=$(sed -n '/local _sk_rule=""/,/adjudicates/p' "$REPO_ROOT/monitor/ng")
assert_contains "#685 the OVERRIDE path emits an action-log event" \
    "$_ng_disp_arm" "skeptic-disposition-overridden"
assert_contains "#685 …carrying WHICH rule fired, so the cause is reconstructible" \
    "$_ng_disp_arm" "rule="
# Both halves must carry `source`, or the two rates are not comparable: an
# override of a prose-sourced disposition is a different event from an override
# of a stated field, and #684 is the reason that distinction now exists.
_ng_honoured_arm=$(sed -n '/skeptic-disposition-honoured/,/issue=\$issue/p' "$REPO_ROOT/monitor/ng")
assert_contains "#685 …and the HONOURED event carries the same source field" \
    "$_ng_honoured_arm" "source=\$_sk_dsource"
# The unreadable arm is the third decision and needs its own trace, or #684's
# new state is invisible to the same audit that motivated #685.
_ng_unread_arm=$(sed -n '/YOUR DISPOSITION WAS NOT READ/,/issue=\$issue/p' "$REPO_ROOT/monitor/ng")
assert_contains "#685 …and the UNREADABLE decision is logged too" \
    "$_ng_unread_arm" "skeptic-disposition-unreadable"

# ---- assertion-count floor ---------------------------------------------
#
# A missing assert_* helper exits rc 127 and is counted by NOTHING: the
# file runs, prints nothing alarming, and reports success for tests that
# never ran. Asserting the COUNT — not just the verdict — is what makes
# a green result mean "the checks ran and passed".
MIN_ASSERTIONS=260
if (( PASS + FAIL < MIN_ASSERTIONS )); then
    echo "FAIL: only $((PASS + FAIL)) assertions executed; expected >= $MIN_ASSERTIONS." >&2
    echo "      A green run with too few assertions means checks were SKIPPED," >&2
    echo "      not that they passed (a missing assert_* helper exits 127 silently)." >&2
    FAIL=$((FAIL + 1))
fi

th_summary_and_exit
