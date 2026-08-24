#!/usr/bin/env bash
# A prescribed follow-up must not un-retain a wrapped-up window —
# your-org/nexus-code#683.
#
# THE DEFECT. Every machine-attributed submit REGRESSES the window to
# busy: it resets the idle-age anchor (consuming the standing
# `window-retain`) and writes a `machine-submit` stamp that makes any
# OLDER wrap-up read as superseded. The window then reports
# `idle NNNs WITHOUT wrap-up — consider follow-up paste` forever and
# drops out of the `(N retained windows suppressed: …)` footer, while
# `retire-preflight` simultaneously returns `safe=1` — two subsystems
# reading the same window and disagreeing.
#
# That premise is right for a RE-TASK and wrong for everything else,
# and the two follow-ups this workspace prescribes most often are
# neither: the `worker-health.sh` clarification the emit itself tells
# you to paste, and a release paste telling a worker to stop awaiting
# something that will never arrive. So the failure is CAUSED BY doing
# the prescribed thing, and it gets worse the more carefully the board
# is tended. Reproduced five times on 2026-08-03.
#
# WHY "JUST WRAP UP AGAIN" IS NOT THE FIX. The consumed retain is
# restored by any LATER wrap-up, which makes this look minor. It is not
# — it is SELECTIVE. It is permanent exactly when no further wrap-up
# will occur, and administrative pastes are disproportionately the ones
# that guarantee that: one of the reproductions said, verbatim, "do NOT
# re-run `ng wrap-up`". Prescribing a repeat wrap-up would trade a false
# resurface for a duplicate wrap-up — the `#665` trade, in the wrong
# direction.
#
# BOTH DIRECTIONS ARE MANDATORY, and that is the issue's own test note:
# "a fix that only suppresses is a fix that hides real re-tasks". Part C
# asserts the administrative paste leaves the retain intact AND that a
# default (re-task) paste still consumes it. A suite that only checked
# the first would pass against a patch that broke re-task detection for
# every window on the board.
#
# THE CARRIER IS COLUMN 4, NOT THE SRC TOKEN. The src column is a
# SELECTOR — `_idle_unconfirmed_paste_epoch` matches
# `$3 == "paste-followup"` EXACTLY — so encoding "administrative" as a
# src would exempt the paste from the `paste-unconfirmed` detector, and
# an administrative paste that silently fails to arrive is exactly as
# lost as a re-task that does. Delivery and re-task are different
# questions; A5 asserts they stay on different carriers.
#
# Run: bash monitor/watcher/test-administrative-paste.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SCRIPT="$_repo_root/monitor/paste-followup.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
fail() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 (got '$2')"; else fail "$1 — got '$2' want '$3'"; fi; }

WORK=$(mktemp -d -t nexus-683-admin-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
# PART A — the SENDER records the decision, explicitly.
# ===========================================================================
echo "=== PART A: paste-followup.sh records the administrative flag ==="

STUB_DIR="$WORK/bin"; mkdir -p "$STUB_DIR"
ACTIONS="$WORK/actions.log"
NGLOG="$WORK/ng.log"
SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
cmd="${1:-}"
if [[ "$cmd" == "list-windows" ]]; then
    fmt=""; prev=""
    for a in "$@"; do [[ "$prev" == "-F" ]] && fmt="$a"; prev="$a"; done
    case "$fmt" in
        *window_id*)
            # Delimiter EXTRACTED from the requested format (your-org/nexus-code#699).
            d="${fmt#*'#{window_id}'}"; d="${d%%'#{window_name}'*}"
            for w in ${MOCK_TMUX_WINDOWS:-}; do printf '@3%s%s\n' "$d" "$w"; done ;;
        *)           printf '%s\n' "${MOCK_TMUX_WINDOWS:-}" ;;
    esac
    exit 0
fi
printf '%s\n' "$*" >> "$ACTIONS"
exit 0
STUB
chmod +x "$STUB_DIR/tmux"

# `ng` stub: record the log-action argv so the audit trail is assertable.
cat > "$STUB_DIR/ng-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NGLOG"
exit 0
STUB
chmod +x "$STUB_DIR/ng-stub"

export ACTIONS NGLOG
export PATH="$STUB_DIR:$PATH"

AWIN="adminwin"
export MOCK_TMUX_WINDOWS="$AWIN"

run_paste() {           # run_paste <state-dir> [extra flags…]
    local sd="$1"; shift
    mkdir -p "$sd/heartbeat"
    printf '{"session_id":"%s","cwd":"/stub"}\n' "$SID" > "$sd/heartbeat/$AWIN.json"
    NEXUS_STATE_DIR="$sd" PASTE_NG_BIN="$STUB_DIR/ng-stub" \
    PASTE_CONFIRM_BUDGET=0 \
        bash "$SCRIPT" "$AWIN" "$@" --message "the follow-up" >/dev/null 2>&1
}
col4() { awk -F'\t' -v w="$AWIN" '$1 == w { print ($4 == "" ? "<empty>" : $4) }' "$1/machine-input.tsv" 2>/dev/null | tail -1; }
col3() { awk -F'\t' -v w="$AWIN" '$1 == w { print $3 }' "$1/machine-input.tsv" 2>/dev/null | tail -1; }

SD_ADMIN="$WORK/s-admin"; run_paste "$SD_ADMIN" --administrative
SD_TASK="$WORK/s-task";   run_paste "$SD_TASK"
SD_ALIAS="$WORK/s-alias"; run_paste "$SD_ALIAS" --no-retask

if [[ -s "$SD_ADMIN/machine-input.tsv" && -s "$SD_TASK/machine-input.tsv" ]]; then
    pass "A0 the sender wrote a ledger in both modes (non-vacuity)"
else
    fail "A0 the sender wrote NO ledger — every assertion below is vacuous"
fi

ck "A1 --administrative stamps column 4 = admin"  "$(col4 "$SD_ADMIN")" "admin"
ck "A2 the DEFAULT stays re-task (column 4 empty)" "$(col4 "$SD_TASK")" "<empty>"
ck "A3 --no-retask is an accepted alias"           "$(col4 "$SD_ALIAS")" "admin"

# A4: the audit trail the issue asked for.
if grep -q 'administrative=1' "$NGLOG" 2>/dev/null; then
    pass "A4 the action-log event records administrative=1"
else
    fail "A4 no administrative=1 in the action-log argv — the decision is not auditable"
fi
_n_admin=$(grep -c 'administrative=1' "$NGLOG" 2>/dev/null || true)
ck "A4b exactly the two administrative pastes logged it, not the re-task" "$_n_admin" "2"

# A5: ORTHOGONALITY. The src token must be untouched, or the paste is
# silently exempted from the paste-unconfirmed delivery check.
ck "A5 an administrative paste keeps src=paste-followup (still delivery-checked)" \
   "$(col3 "$SD_ADMIN")" "paste-followup"

# ===========================================================================
# PART B — the RESOLVER, including the direction that must NOT suppress.
# ===========================================================================
echo
echo "=== PART B: _openg_machine_input_administrative ==="

STATE_DIR="$WORK/bstate"; mkdir -p "$STATE_DIR"
# shellcheck source=monitor/watcher/_idle_probe.sh
source "$_repo_root/monitor/watcher/_idle_probe.sh" \
    || { echo "cannot source _idle_probe.sh" >&2; exit 1; }

if declare -F _openg_machine_input_administrative >/dev/null 2>&1; then
    pass "B0 _openg_machine_input_administrative is defined (non-vacuity)"
else
    fail "B0 resolver MISSING — Part B is vacuous"
fi

BW="bwin"
EPOCH_SEC=1785812748
EPOCH_US=1785812748574586
mi() { printf '%s\n' "$@" > "$STATE_DIR/machine-input.tsv"; }
adm() { _openg_machine_input_administrative "$BW" "$1"; }

mi "$BW	$EPOCH_US	paste-followup	admin"
ck "B1 an admin row at the resolved epoch resolves administrative" "$(adm $EPOCH_SEC)" "1"

mi "$BW	$EPOCH_US	paste-followup	"
ck "B2 a re-task row does not" "$(adm $EPOCH_SEC)" ""

# Backward compatibility: pre-#683 rows have only THREE columns and live
# in this append-only file forever. They must read as re-task, today's
# behaviour, not as administrative.
mi "$BW	$EPOCH_US	paste-followup"
ck "B3 a pre-#683 three-column row reads as re-task" "$(adm $EPOCH_SEC)" ""

# THE DIRECTION THAT MUST NOT SUPPRESS. An old administrative paste
# followed by a genuine re-task must resolve as RE-TASK — otherwise one
# administrative paste would permanently exempt the window and hide
# every later re-task, which is the failure the issue's test note names.
mi "$BW	1785812000000000	paste-followup	admin" \
   "$BW	$EPOCH_US	paste-followup	"
ck "B4 a NEWER re-task overrides an older administrative row" "$(adm $EPOCH_SEC)" ""

mi "$BW	1785812000000000	paste-followup	" \
   "$BW	$EPOCH_US	paste-followup	admin"
ck "B4b a NEWER administrative row overrides an older re-task" "$(adm $EPOCH_SEC)" "1"

# Unit handling, inherited from #679: both row formats must resolve.
mi "$BW	$EPOCH_SEC	paste-followup	admin"
ck "B5 a legacy SECONDS row with the marker resolves" "$(adm $EPOCH_SEC)" "1"

mi "$BW	$EPOCH_US	paste-followup	admin"
ck "B6 another window's admin row does not leak" \
   "$(_openg_machine_input_administrative otherwin "$EPOCH_SEC")" ""

rm -f "$STATE_DIR/machine-input.tsv"
ck "B7 a missing ledger resolves as re-task (fail-safe), not an error" "$(adm $EPOCH_SEC)" ""
ck "B8 a zero epoch resolves as re-task" "$(adm 0)" ""

# ===========================================================================
# PART C — the BEHAVIOUR, both directions, through the real _openg_observe.
#
# This is the assertion pair the issue specifies. Part A/B could both be
# green against a resolver nothing consults.
# ===========================================================================
echo
echo "=== PART C: the retain survives an administrative paste, and only that ==="

NOW=$(date +%s)
SUBMIT=$(( NOW - 10 ))
PASTE_US=$(( (NOW - 12) * 1000000 ))

setup_window() {        # setup_window <window> <col4>
    local w="$1" c4="$2"
    mkdir -p "$STATE_DIR/user-prompt" "$STATE_DIR/machine-submit"
    printf '%s\t%s\n' "$SUBMIT" "$SID" > "$STATE_DIR/user-prompt/$w"
    printf '%s\t%s\t%s\t%s\n' "$w" "$PASTE_US" "paste-followup" "$c4" \
        > "$STATE_DIR/machine-input.tsv"
    rm -f "$STATE_DIR/machine-submit/$w"
    rm -f "$STATE_DIR/engagement-log.tsv"
    rm -f "$STATE_DIR/openg.tsv" 2>/dev/null || true
}

observe() { _openg_observe "$1" idle '' "$NOW" "$(_openg_grace_seconds)" >/dev/null 2>&1; }

# --- C1/C2: the machine-submit stamp (what supersedes a wrap-up) --------
setup_window retaskwin ""
observe retaskwin
if [[ -f "$STATE_DIR/machine-submit/retaskwin" ]]; then
    pass "C1 a RE-TASK paste writes the machine-submit stamp (unchanged behaviour)"
else
    fail "C1 a re-task paste did NOT write the machine-submit stamp — real re-tasks are now hidden"
fi

setup_window adminwin2 "admin"
observe adminwin2
if [[ -f "$STATE_DIR/machine-submit/adminwin2" ]]; then
    fail "C2 an ADMINISTRATIVE paste wrote the machine-submit stamp — the wrap-up still reads superseded"
else
    pass "C2 an administrative paste writes NO machine-submit stamp"
fi

# --- C3/C4: the engagement log (what consumes the window-retain) --------
eng_for() { awk -F'\t' -v w="$1" '$1 == w { print $2 }' "$STATE_DIR/engagement-log.tsv" 2>/dev/null | tail -1; }

setup_window retaskwin2 ""
observe retaskwin2
if [[ -n "$(eng_for retaskwin2)" ]]; then
    pass "C3 a RE-TASK paste advances the engagement log (consumes the retain)"
else
    fail "C3 a re-task paste did not advance the engagement log — behaviour changed for real re-tasks"
fi

setup_window adminwin3 "admin"
observe adminwin3
if [[ -n "$(eng_for adminwin3)" ]]; then
    fail "C4 an ADMINISTRATIVE paste advanced the engagement log — the window-retain is still consumed"
else
    pass "C4 an administrative paste leaves the engagement log alone (retain survives)"
fi

# --- C5: the submit is still CONSUMED, in both modes ---------------------
#
# Not marking must not mean not observing. If attribution re-ran every
# cycle the window would churn, and worse, the submit could later be
# re-read as OPERATOR input and seed a spurious operator-engaged mark.
setup_window adminwin4 "admin"
observe adminwin4
_seen=$(_openg_lookup adminwin4 2>/dev/null | awk -F'\t' '{print $3}')
ck "C5 an administrative paste still consumes prompt_seen" "$_seen" "$SUBMIT"

# ===========================================================================
# PART D — compaction must not silently drop the marker.
# ===========================================================================
echo
echo "=== PART D: the marker survives ledger compaction ==="

DW="compactwin"
: > "$STATE_DIR/machine-input.tsv"
# 205 rows across only FIVE filler windows. Using 205 DISTINCT windows
# is the obvious fixture and it is wrong: compaction keeps one row per
# window, so 206 distinct windows compact to 206 rows, nothing shrinks,
# and D1/D2 then pass because the marker was never put at risk. D0 is
# what caught that.
for i in $(seq 1 205); do
    printf 'filler%s\t%s\tpaste-followup\t\n' "$(( i % 5 ))" "$(( PASTE_US + i ))" \
        >> "$STATE_DIR/machine-input.tsv"
done
printf '%s\t%s\t%s\t%s\n' "$DW" "$PASTE_US" "paste-followup" "admin" \
    >> "$STATE_DIR/machine-input.tsv"

_pre=$(wc -l < "$STATE_DIR/machine-input.tsv")
_machine_input_prune "" 2>/dev/null
_post=$(wc -l < "$STATE_DIR/machine-input.tsv")
if (( _post < _pre )); then
    pass "D0 compaction actually ran ($_pre → $_post rows) — non-vacuity"
else
    fail "D0 compaction did not run ($_pre → $_post) — D1 would prove nothing"
fi
ck "D1 the administrative marker survives compaction" \
   "$(awk -F'\t' -v w="$DW" '$1 == w { print $4 }' "$STATE_DIR/machine-input.tsv")" "admin"
ck "D2 the compacted row still resolves administrative" \
   "$(_openg_machine_input_administrative "$DW" "$(( PASTE_US / 1000000 ))")" "1"

# ---------------------------------------------------------------------------
printf '\n=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then echo "ALL TESTS PASSED"; exit 0; fi
exit 1
