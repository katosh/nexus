#!/usr/bin/env bash
# Guard for your-org/nexus-code#1369 / #1335 — retire-preflight's AUDIT WRITES
# must land in the SAME state dir as its READS.
#
# The defect: `retire-preflight.sh --state-dir X` scoped every read to X and
# then spawned `ng log-action` for its three gate-audit rows WITHOUT
# propagating X. `ng` reads `NEXUS_STATE_DIR`, never `STATE_DIR`, so the rows
# fell through to the INHERITED root — the operator's live `action-log.jsonl`.
# Measured on #1369: 10,275 of 30,530 live rows (33.7%) were gate audit, and
# only one of the three events carries a path that betrays its fixture origin.
#
# THE ASSERTION DIRECTION IS DELIBERATE (#1335, comment 2026-09-02T19:24Z).
# This suite asserts `delta = 0` on the AMBIENT log, not growth of the scoped
# one. The log is append-only, so a zero delta establishes that nothing was
# appended by anyone; a non-zero delta on a live board establishes nothing
# without attribution (measured: `delta=17`, all unrelated traffic, nearly
# reported as a leak). Here the ambient root is a DECOY under mktemp, so the
# board cannot race it — but the direction is kept so the same assertion
# would be sound against a live root too.
#
# A zero delta is only evidence if the write path was exercised, so two
# controls bracket it:
#   - POSITIVE: the scoped dir receives all three gate events (the audit fired
#     and went somewhere we can see);
#   - NEGATIVE (instrument): a bare `ng log-action` under the same ambient
#     root DOES grow the ambient log — so the detector can see a leak when one
#     exists and its zero is not a blind instrument's zero.
#
# Run: bash monitor/watcher/test-retire-preflight-audit-scope.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
PREFLIGHT="$_repo_root/monitor/retire-preflight.sh"
NG="$_repo_root/monitor/ng"

. "$_test_dir/_test_helpers.sh"

[[ -x "$PREFLIGHT" ]] || th_abort "missing: $PREFLIGHT"
[[ -x "$NG"        ]] || th_abort "missing: $NG"
command -v jq >/dev/null 2>&1 || th_abort "jq required"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/rpas-XXXXXX") || th_abort "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# The AMBIENT root: what an agent shell inherits. A full decoy is not needed —
# `ng`'s arm 2 is `$NEXUS_ROOT/monitor/.state`, nothing more — but the log
# must PRE-EXIST with a row so that "did not grow" is measured against a file
# that a leak would have appended to, not against an absent one (an absent
# log makes `ng`'s usage tap a no-op, and would make this whole suite
# vacuous; your-org/nexus-code#833).
AMBIENT="$WORK/ambient"
AMBIENT_LOG="$AMBIENT/monitor/.state/action-log.jsonl"
mkdir -p "$AMBIENT/monitor/.state"
printf '{"seed":"ambient"}\n' > "$AMBIENT_LOG"

REPORTS_DIR="$WORK/reports"; mkdir -p "$REPORTS_DIR"
NOW=$(date +%s)

ambient_rows() { wc -l < "$AMBIENT_LOG"; }

# run_scoped <scoped-dir> <window> [env-prefix...] — run the REAL preflight
# with `--state-dir` pointed at a fresh scoped dir, under an ambient root that
# is NOT that dir. The preflight is driven to the GO path (`--pane-state
# idle`, empty reports corpus, no marker) so that all three gate sites are
# reached: marker-gate, obligation-gate, disposition-gate.
run_scoped() {
    local scoped="$1" win="$2"; shift 2
    mkdir -p "$scoped"
    env -u NEXUS_STATE_DIR "$@" \
        bash "$PREFLIGHT" "$win" --state-dir "$scoped" --now "$NOW" \
        --reports-dir "$REPORTS_DIR" --pane-state idle >/dev/null 2>&1
}

scoped_events() {   # sorted, newline-joined event names in a scoped log
    local f="$1/action-log.jsonl"
    [[ -f "$f" ]] || { printf '(no log)'; return; }
    jq -r 'select(.agent == "retire-preflight") | .event' "$f" 2>/dev/null | sort | paste -sd, -
}

# ---------------------------------------------------------------------------
echo "=== NEGATIVE CONTROL (instrument): a bare ng log-action under the ambient root IS visible ==="
# Before trusting any zero below, show the instrument fires. This is exactly
# the shape the defect took — an `ng` child resolving arm 2 — and it MUST grow
# the ambient log, or "delta=0" further down means only "nothing could be
# seen".
b=$(ambient_rows)
env -u NEXUS_STATE_DIR NEXUS_ROOT="$AMBIENT" "$NG" log-action retire-preflight \
    --event audit-scope-instrument-control --extra "window=rpas-ctl" >/dev/null 2>&1
a=$(ambient_rows)
assert_eq "instrument control: an unscoped ng child appends ONE row to the ambient log" "$(( a - b ))" "1"
assert_contains "…and it is the row we sent" "$(tail -1 "$AMBIENT_LOG")" "audit-scope-instrument-control"

# ---------------------------------------------------------------------------
echo "=== arm 2: ambient NEXUS_ROOT, --state-dir elsewhere — the audit must not fall through ==="
SCOPED1="$WORK/scoped1"
b=$(ambient_rows)
run_scoped "$SCOPED1" rpas-a2 NEXUS_ROOT="$AMBIENT"; rc=$?
a=$(ambient_rows)
assert_rc "the preflight itself ran to a verdict (GO path reaches all three gate sites)" "$rc" "0"
assert_eq "AMBIENT action-log delta is ZERO (your-org/nexus-code#1369)" "$(( a - b ))" "0"
# POSITIVE CONTROL: the audit DID fire — into the scoped dir. Without this the
# zero above is satisfied by a preflight that logged nothing at all.
assert_eq "POSITIVE CONTROL: all three gate events landed in the SCOPED dir" \
    "$(scoped_events "$SCOPED1")" \
    "skeptic-disposition-gate,skeptic-marker-gate,skeptic-obligation-gate"
assert_not_contains "…and the ambient log carries no row for the fixture window" \
    "$(cat "$AMBIENT_LOG")" '"window":"rpas-a2"'

# ---------------------------------------------------------------------------
echo "=== arm 1: ambient NEXUS_STATE_DIR, --state-dir elsewhere — the FLAG wins for writes too ==="
# The other way an agent shell arrives: a pinned NEXUS_STATE_DIR (the #1349
# remedy). The explicit flag must still govern the audit, or a caller who
# scoped the run correctly by flag is overruled by their own ambient pin.
AMBIENT2="$WORK/ambient2-state"; mkdir -p "$AMBIENT2"
printf '{"seed":"ambient2"}\n' > "$AMBIENT2/action-log.jsonl"
SCOPED2="$WORK/scoped2"
b=$(wc -l < "$AMBIENT2/action-log.jsonl")
mkdir -p "$SCOPED2"
NEXUS_STATE_DIR="$AMBIENT2" bash "$PREFLIGHT" rpas-a1 --state-dir "$SCOPED2" --now "$NOW" \
    --reports-dir "$REPORTS_DIR" --pane-state idle >/dev/null 2>&1; rc=$?
a=$(wc -l < "$AMBIENT2/action-log.jsonl")
assert_rc "the preflight ran to a verdict under an ambient pin" "$rc" "0"
assert_eq "ambient NEXUS_STATE_DIR log delta is ZERO when --state-dir names another dir" "$(( a - b ))" "0"
assert_eq "POSITIVE CONTROL: the three gate events landed in the --state-dir" \
    "$(scoped_events "$SCOPED2")" \
    "skeptic-disposition-gate,skeptic-marker-gate,skeptic-obligation-gate"

# ---------------------------------------------------------------------------
echo "=== the export is the mechanism: the preflight hands NEXUS_STATE_DIR to EVERY child ==="
# #1335 option B: the script exports NEXUS_STATE_DIR from its resolved
# STATE_DIR so that a `log-action` site added LATER is covered without anyone
# remembering the prefix. Observe it through a stand-in `ng` that records its
# environment — the seam is `$self_dir`, the sibling-first resolution the
# preflight uses for `ng`, so the stand-in lives beside a symlinked copy.
_sd="$WORK/selfdir"; mkdir -p "$_sd"
for _f in _bookkeeping.sh _obligations.sh watcher retire-preflight.sh; do
    ln -s "$_repo_root/monitor/$_f" "$_sd/$_f" 2>/dev/null || true
done
cat > "$_sd/ng" <<'SDNG'
#!/usr/bin/env bash
# Records what NEXUS_STATE_DIR every ng child SEES, one line per invocation.
printf '%s\t%s\n' "${1:-}" "${NEXUS_STATE_DIR:-<unset>}" >> "${SD_ENV_LOG:?}"
case "${1:-}" in
  skeptic-obligations) printf 'window=%s key=%s outstanding=0 ledger=absent\n' "${2:-}" "${2:-}" ;;
  skeptic-disposition) printf 'state=no-report source=none report= report_mtime=0 blocking=0 reports=0 detail=\n' ;;
esac
exit 0
SDNG
chmod +x "$_sd/ng"
SCOPED3="$WORK/scoped3"; mkdir -p "$SCOPED3"
ENV_LOG="$WORK/sd-env.log"; : > "$ENV_LOG"
SD_ENV_LOG="$ENV_LOG" env -u NEXUS_STATE_DIR NEXUS_ROOT="$AMBIENT" \
    bash "$_sd/retire-preflight.sh" rpas-exp --state-dir "$SCOPED3" --now "$NOW" \
    --reports-dir "$REPORTS_DIR" --pane-state idle >/dev/null 2>&1
n_calls=$(grep -c . "$ENV_LOG" || true)
n_scoped=$(awk -F'\t' -v s="$SCOPED3" '$2 == s' "$ENV_LOG" | grep -c . || true)
assert_eq "POSITIVE CONTROL: the stand-in ng was invoked at least three times (the log-action sites)" \
    "$(( n_calls >= 3 ))" "1"
assert_eq "EVERY ng child saw NEXUS_STATE_DIR == the --state-dir (export, not just the three prefixes)" \
    "$n_scoped" "$n_calls"
assert_not_contains "…and none saw it unset" "$(cat "$ENV_LOG")" '<unset>'

# ---- assertion-count guard ------------------------------------------------
EXPECTED_ASSERTIONS=12
_ran=$(( ${PASS:-0} + ${FAIL:-0} ))
if (( _ran == EXPECTED_ASSERTIONS )); then
    printf '  PASS: every declared assertion executed (%d)\n' "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion count drifted — ran %d, expected %d\n' "$_ran" "$EXPECTED_ASSERTIONS" >&2
    _th_fail
fi

th_summary_and_exit
