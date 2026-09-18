#!/usr/bin/env bash
# Tests for monitor/declare-wait.sh and monitor/declare-no-wait.sh —
# the worker-side helpers that manipulate `external_waits` and
# `dismissed_waits` in the per-window heartbeat. Together they
# implement the worker side of the async-signal contract surface
# from issue #183.
#
# Run: bash monitor/watcher/test-declare-wait.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
DECLARE_WAIT="$_repo_root/monitor/declare-wait.sh"
DECLARE_NO_WAIT="$_repo_root/monitor/declare-no-wait.sh"

PASS=0
FAIL=0

ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

[[ -x "$DECLARE_WAIT"    ]] || { echo "missing: $DECLARE_WAIT"    >&2; exit 1; }
[[ -x "$DECLARE_NO_WAIT" ]] || { echo "missing: $DECLARE_NO_WAIT" >&2; exit 1; }

# Helper to run declare-wait or declare-no-wait in a hermetic env.
run() {
    local helper="$1"; shift
    NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
        bash "$helper" "$@"
}

hb_file="$WORK/.state/heartbeat/testw.json"

# Reset the heartbeat between tests so each assertion is isolated.
reset_hb() {
    rm -f "$hb_file"
    rm -rf "$WORK/.state/heartbeat"
}

read_waits() {
    jq -c '.external_waits // []' "$hb_file" 2>/dev/null
}
read_dismissed() {
    jq -c '.dismissed_waits // []' "$hb_file" 2>/dev/null
}

echo "=== declare-wait.sh basics ==="

# (1) Basic add.
reset_hb
run "$DECLARE_WAIT" slurm 42 "first job"
got=$(read_waits)
if [[ "$got" == '[{"kind":"slurm","id":"42","desc":"first job"}]' ]]; then
    ok "add slurm 42 → single entry"
else
    bad "add slurm 42" "got=$got"
fi

# (2) Second add appends.
run "$DECLARE_WAIT" ci abc/runs/1 "ci run"
got=$(read_waits)
if [[ "$got" == '[{"kind":"slurm","id":"42","desc":"first job"},{"kind":"ci","id":"abc/runs/1","desc":"ci run"}]' ]]; then
    ok "second add → two entries"
else
    bad "second add" "got=$got"
fi

# (3) Re-add same (kind, id) updates desc rather than dup.
run "$DECLARE_WAIT" slurm 42 "updated desc"
got=$(read_waits)
expected_count=$(jq 'length' <<<"$got")
if [[ "$expected_count" == "2" ]]; then
    desc=$(jq -r '.[] | select(.kind=="slurm" and .id=="42") | .desc' <<<"$got")
    if [[ "$desc" == "updated desc" ]]; then
        ok "re-add same (kind,id) → updates desc, no dup"
    else
        bad "re-add desc" "got desc=$desc"
    fi
else
    bad "re-add count" "got count=$expected_count"
fi

# (4) --remove drops by (kind, id).
run "$DECLARE_WAIT" --remove slurm 42
got=$(read_waits)
if [[ "$got" == '[{"kind":"ci","id":"abc/runs/1","desc":"ci run"}]' ]]; then
    ok "--remove slurm 42 → drops only that entry"
else
    bad "--remove" "got=$got"
fi

# (5) --remove of non-existent entry is silent no-op.
run "$DECLARE_WAIT" --remove slurm 999
got=$(read_waits)
if [[ "$got" == '[{"kind":"ci","id":"abc/runs/1","desc":"ci run"}]' ]]; then
    ok "--remove non-existent → silent no-op"
else
    bad "--remove non-existent" "got=$got"
fi

# (6) --clear empties the array.
run "$DECLARE_WAIT" --clear
got=$(read_waits)
if [[ "$got" == "[]" ]]; then
    ok "--clear → empty array"
else
    bad "--clear" "got=$got"
fi

# (7) --list reads from disk.
reset_hb
run "$DECLARE_WAIT" slurm 5 "x"
run "$DECLARE_WAIT" http "https://api/y" "y"
listed=$(run "$DECLARE_WAIT" --list)
listed_count=$(jq 'length' <<<"$listed")
if [[ "$listed_count" == "2" ]]; then
    ok "--list returns current entries"
else
    bad "--list count" "got=$listed_count"
fi

echo
echo "=== declare-wait.sh error handling ==="

# (8) Missing NEXUS_WORKER_WINDOW fails loud (exit 2). `env -u`
# explicitly unsets the inherited var; tests that share a shell
# with the smoke-test scaffolding might otherwise carry it
# through.
out_err=$(env -u NEXUS_WORKER_WINDOW NEXUS_STATE_DIR="$WORK/.state" \
    bash "$DECLARE_WAIT" slurm 1 "x" 2>&1)
rc=$?
if (( rc == 2 )) && grep -qF "NEXUS_WORKER_WINDOW unset" <<<"$out_err"; then
    ok "missing NEXUS_WORKER_WINDOW → exit 2 with stderr message"
else
    bad "missing window guard" "rc=$rc out=$out_err"
fi

# (9) Bad usage exits 2.
out_err=$(NEXUS_STATE_DIR="$WORK/.state" NEXUS_WORKER_WINDOW=testw \
            bash "$DECLARE_WAIT" 2>&1)
rc=$?
if (( rc == 2 )); then
    ok "no-args → exit 2"
else
    bad "no-args usage" "rc=$rc"
fi

echo
echo "=== declare-no-wait.sh basics ==="

reset_hb
run "$DECLARE_WAIT"    slurm 100 "to-dismiss"
run "$DECLARE_WAIT"    slurm 200 "keep"

# (10) Dismiss moves entry from external_waits to dismissed_waits.
run "$DECLARE_NO_WAIT" slurm 100
waits=$(read_waits)
dismissed=$(read_dismissed)
if [[ "$waits" == '[{"kind":"slurm","id":"200","desc":"keep"}]' ]] \
   && [[ "$dismissed" == '[{"kind":"slurm","id":"100"}]' ]]; then
    ok "dismiss → moves from external_waits to dismissed_waits"
else
    bad "dismiss move" "waits=$waits dismissed=$dismissed"
fi

# (11) Dismiss without prior external_waits row still records.
reset_hb
run "$DECLARE_NO_WAIT" slurm 555
dismissed=$(read_dismissed)
if [[ "$dismissed" == '[{"kind":"slurm","id":"555"}]' ]]; then
    ok "dismiss before declare → record in dismissed_waits"
else
    bad "dismiss-before-declare" "got=$dismissed"
fi

# (12) Dismiss is idempotent (no dup entries).
run "$DECLARE_NO_WAIT" slurm 555
dismissed=$(read_dismissed)
count=$(jq 'length' <<<"$dismissed")
if [[ "$count" == "1" ]]; then
    ok "dismiss twice → single entry (idempotent)"
else
    bad "dismiss idempotent" "count=$count"
fi

# (13) --un-dismiss removes from dismissed_waits.
run "$DECLARE_NO_WAIT" --un-dismiss slurm 555
dismissed=$(read_dismissed)
if [[ "$dismissed" == "[]" ]]; then
    ok "--un-dismiss → dismissed_waits empty"
else
    bad "--un-dismiss" "got=$dismissed"
fi

# (14) --list shows dismissed_waits only (not external_waits).
reset_hb
run "$DECLARE_WAIT"    slurm 1 "x"
run "$DECLARE_NO_WAIT" slurm 2
listed=$(run "$DECLARE_NO_WAIT" --list)
if [[ "$listed" == '[{"kind":"slurm","id":"2"}]' ]]; then
    ok "--list dismissed only"
else
    bad "--list dismissed" "got=$listed"
fi

echo
echo "=== cross-helper preservation ==="

# (15) declare-wait preserves dismissed_waits.
reset_hb
run "$DECLARE_NO_WAIT" slurm 10
run "$DECLARE_WAIT"    slurm 20 "new"
dismissed=$(read_dismissed)
if [[ "$dismissed" == '[{"kind":"slurm","id":"10"}]' ]]; then
    ok "declare-wait preserves prior dismissed_waits"
else
    bad "declare-wait preserve" "got=$dismissed"
fi

# (16) declare-no-wait preserves other external_waits.
reset_hb
run "$DECLARE_WAIT"    slurm 1 "keep"
run "$DECLARE_WAIT"    ci 9 "keep ci"
run "$DECLARE_NO_WAIT" slurm 1
waits=$(read_waits)
if [[ "$waits" == '[{"kind":"ci","id":"9","desc":"keep ci"}]' ]]; then
    ok "declare-no-wait preserves other external_waits"
else
    bad "declare-no-wait preserve" "got=$waits"
fi

echo
# ---------------------------------------------------------------
# your-org/nexus-code#1326 — shape floor + effect reporting.
#
# TWO SEPARATE DEFENCES, and the split is deliberate:
#   * the SHAPE floor (monitor/_wait_id.sh) refuses a value that
#     cannot have come from a launch — rc 2, nothing written;
#   * the EFFECT report distinguishes "a wait was lifted" (rc 0) from
#     "a row was appended and nothing was lifted" (rc 4). A truncated
#     but ASCII id such as a bare `syn-` is well formed, so only the
#     second defence can catch it. Asserting both is what stops a
#     later reader mistaking either half for the whole fix.
# ---------------------------------------------------------------
echo "=== #1326 shape floor ==="

quiet() { run "$@" >/dev/null 2>&1; }

# (17) Every hazard input from #1326 is REFUSED at rc 2 — on BOTH
# verbs, because a floor on one side only would let a worker declare
# a wait it could not then dismiss.
reset_hb
_shape_fail=0
for bad_id in 'syn-…' 'not an id at all' '../../etc/passwd' '$(whoami)' '-i' 'a	b'; do
    for helper in "$DECLARE_WAIT" "$DECLARE_NO_WAIT"; do
        quiet "$helper" nohup "$bad_id"
        rc=$?
        [[ $rc -eq 2 ]] || { bad "shape refusal" "id=[$bad_id] helper=${helper##*/} rc=$rc (want 2)"; _shape_fail=1; }
    done
done
for bad_kind in 'bad kind' '-k' 'k…'; do
    quiet "$DECLARE_NO_WAIT" "$bad_kind" syn-abcdef012345
    rc=$?
    [[ $rc -eq 2 ]] || { bad "shape refusal (kind)" "kind=[$bad_kind] rc=$rc (want 2)"; _shape_fail=1; }
done
(( _shape_fail )) || ok "malformed kind/id refused at rc 2 on both verbs"

# (18) NEGATIVE CONTROL for the floor: a refusal must write NOTHING.
# A validator that refuses loudly and records anyway would leave the
# ledger in exactly the state the issue is about.
reset_hb
quiet "$DECLARE_WAIT" slurm 4242 "real"
before=$(cat "$hb_file")
quiet "$DECLARE_NO_WAIT" nohup 'syn-…'
quiet "$DECLARE_WAIT"    nohup 'syn-…'
after=$(cat "$hb_file")
if [[ "$before" == "$after" ]]; then
    ok "refused call writes nothing (heartbeat byte-identical)"
else
    bad "refusal wrote" "before=$before after=$after"
fi

# (19) POSITIVE CONTROL: the whole live population and every
# documented example must still be ACCEPTED. #1326 proposed a kind
# allowlist (nohup|slurm|asyncrun) and a per-kind id grammar; both are
# measurably wrong against this nexus's own heartbeats — kind
# `slurm-srun-async` and kind `service` are live, kind `slurm` carries
# BOTH `2219913` and `syn-02ce6257b730`, and `declare-wait`'s own
# docstring documents a `ci` example with slashes. This case is the
# reason the floor is a character class.
reset_hb
_accept_fail=0
while IFS='|' read -r k i; do
    quiet "$DECLARE_WAIT" "$k" "$i" "d"
    rc=$?
    [[ $rc -eq 0 ]] || { bad "shape acceptance" "kind=$k id=$i rc=$rc (want 0)"; _accept_fail=1; }
done <<'CASES'
slurm|2219913
slurm|52527284_4
slurm|syn-02ce6257b730
asyncrun|ar-e156942f7283
nohup|syn-0919b1641f12
slurm-srun-async|syn-066ab96b3f71
service|myviewer-8766
ci|your-org/nexus-code/runs/26304173692
CASES
(( _accept_fail )) || ok "live kinds + documented examples all accepted"

echo "=== #1326 effect reporting ==="

# (20) Dismissing a wait that IS on record: rc 0.
reset_hb
quiet "$DECLARE_WAIT" slurm 777 "real"
quiet "$DECLARE_NO_WAIT" slurm 777
rc=$?
waits=$(read_waits)
if [[ $rc -eq 0 && "$waits" == "[]" ]]; then
    ok "dismiss of a real wait → rc 0, wait lifted"
else
    bad "dismiss real" "rc=$rc waits=$waits"
fi

# (21) Dismissing a wait that is NOT on record: rc 4, and the record
# is still made. The sticky pre-detection path (test 11) is
# legitimate and must survive; what changes is that the caller can
# now tell the two apart. A bare `syn-` is the motivating input —
# well formed, so the shape floor passes it, and short, so it matches
# nothing.
reset_hb
quiet "$DECLARE_WAIT" nohup syn-0919b1641f12 "real"
quiet "$DECLARE_NO_WAIT" nohup 'syn-'
rc=$?
dismissed=$(read_dismissed)
waits=$(read_waits)
if [[ $rc -eq 4 \
   && "$dismissed" == '[{"kind":"nohup","id":"syn-"}]' \
   && "$waits" == '[{"kind":"nohup","id":"syn-0919b1641f12","desc":"real"}]' ]]; then
    ok "dismiss of a truncated id → rc 4, recorded, real wait UNTOUCHED"
else
    bad "dismiss truncated" "rc=$rc dismissed=$dismissed waits=$waits"
fi

# (22) declare-wait --remove that matches nothing: rc 4. Its
# docstring promised a "silent no-op"; that is the same defect one
# verb over.
reset_hb
quiet "$DECLARE_WAIT" slurm 111 "real"
quiet "$DECLARE_WAIT" --remove slurm 999
rc=$?
[[ $rc -eq 4 ]] && ok "--remove matching nothing → rc 4" \
                || bad "--remove no-match rc" "rc=$rc (want 4)"

# (23) --un-dismiss that matches nothing: rc 4.
reset_hb
quiet "$DECLARE_NO_WAIT" slurm 222
quiet "$DECLARE_NO_WAIT" --un-dismiss slurm 999
rc=$?
[[ $rc -eq 4 ]] && ok "--un-dismiss matching nothing → rc 4" \
                || bad "--un-dismiss no-match rc" "rc=$rc (want 4)"

# (24) …and the matching cases stay rc 0, so rc 4 means what it says
# rather than "this verb always complains".
reset_hb
quiet "$DECLARE_WAIT" slurm 333 "real"
quiet "$DECLARE_WAIT" --remove slurm 333;      rc_rm=$?
quiet "$DECLARE_NO_WAIT" slurm 444
quiet "$DECLARE_NO_WAIT" --un-dismiss slurm 444; rc_un=$?
if [[ $rc_rm -eq 0 && $rc_un -eq 0 ]]; then
    ok "--remove / --un-dismiss that DO match → rc 0"
else
    bad "matching removals" "rc_rm=$rc_rm rc_un=$rc_un (want 0/0)"
fi

# (25) COUPLING TEST — the watcher's reaper must read rc 4 as SUCCESS.
# `monitor/watcher/_orphan_async.sh:_orphan_async_reap_real` shells out to
# `declare-wait.sh --remove`, and its one caller logs "could not reap … it
# will re-flag" on ANY non-zero. Introducing rc 4 above therefore reached
# into the watcher; without this assertion the coupling is invisible from
# either file and a later author would restore the false diagnostic. A
# MALFORMED id must still fail (rc non-zero) — that one genuinely cannot be
# reaped and the hand-remedy log line is the right outcome.
if [[ -r "$_repo_root/monitor/watcher/_orphan_async.sh" ]]; then
    reset_hb
    _rc_out=$(
        NEXUS_STATE_DIR="$WORK/.state" NEXUS_ROOT="$_repo_root" \
        bash -c '
            set -u
            . "'"$_repo_root"'/monitor/watcher/_orphan_async.sh" 2>/dev/null || exit 9
            NEXUS_WORKER_WINDOW=testw bash "'"$_repo_root"'/monitor/declare-wait.sh" slurm 900 d
            _orphan_async_reap_real testw slurm 900;      printf "%s " "$?"
            _orphan_async_reap_real testw slurm 900;      printf "%s " "$?"
            # A MALFORMED id must be REAPABLE, not refused. The shape floor
            # gates the CREATE path only; gating removal would strand a row
            # written by the pre-fix code, with no `--clear` on the dismiss
            # verb and hand-edited JSON as the only way out
            # (your-org/nexus-code#1373 skeptic finding 2). Plant one directly,
            # the way the old code would have written it, and require the
            # reaper to clear it.
            printf %s "{\"window\":\"testw\",\"last_activity\":1788000000,\"external_waits\":[{\"kind\":\"nohup\",\"id\":\"syn-…\"}],\"dismissed_waits\":[]}" \
                > "'"$WORK"'/.state/heartbeat/testw.json"
            _orphan_async_reap_real testw nohup "syn-…"; printf "%s " "$?"
            printf "%s" "$(jq -r ".external_waits|length" "'"$WORK"'/.state/heartbeat/testw.json")"
        ' 2>/dev/null
    )
    if [[ "$_rc_out" == "0 0 0 0" ]]; then
        ok "watcher reaper: present→0, already-absent→0 (rc 4 is success), MALFORMED row reaped not stranded"
    else
        bad "watcher reaper rc coupling" "got=[$_rc_out] want=[0 0 0 0]"
    fi
else
    bad "watcher reaper rc coupling" "_orphan_async.sh unreadable"
fi

# (26) your-org/nexus-code#1373 skeptic finding 2 — THE FLOOR GATES THE WRITE
# VERBS, NOT THE REMOVE VERBS. Gating removal is the one place a shape floor
# can only STRAND: a malformed row written by the PRE-FIX code is exactly what
# an operator needs to delete, `declare-no-wait` has no `--clear` hatch, and
# hand-edited JSON would be the only way out. Removal can only shrink the
# record, so an unvalidated id there is harmless; every hazard input still
# arrives on the CREATE path and is still refused.
reset_hb
printf '%s' '{"window":"testw","last_activity":1788000000,"external_waits":[{"kind":"nohup","id":"syn-…"}],"dismissed_waits":[{"kind":"nohup","id":"syn-…"}]}' \
    > /dev/null 2>&1 || true
mkdir -p "$WORK/.state/heartbeat"
printf '%s' '{"window":"testw","last_activity":1788000000,"external_waits":[{"kind":"nohup","id":"syn-…"}],"dismissed_waits":[{"kind":"nohup","id":"syn-…"}]}' \
    > "$hb_file"
quiet "$DECLARE_WAIT"    --remove      nohup 'syn-…'; _rm_rc=$?
quiet "$DECLARE_NO_WAIT" --un-dismiss  nohup 'syn-…'; _un_rc=$?
_left_w=$(read_waits); _left_d=$(read_dismissed)
if [[ $_rm_rc -eq 0 && $_un_rc -eq 0 && "$_left_w" == "[]" && "$_left_d" == "[]" ]]; then
    ok "pre-fix MALFORMED entries are removable — the floor does not strand them"
else
    bad "malformed removal stranded" "rm=$_rm_rc un=$_un_rc waits=$_left_w dismissed=$_left_d"
fi

# (27) …and the CREATE path is still closed to every hazard input, so
# ungating removal bought the escape hatch without reopening the door.
reset_hb
_create_fail=0
for bad_id in 'syn-…' 'not an id at all' '../../etc/passwd' '$(whoami)' '-i'; do
    quiet "$DECLARE_WAIT"    nohup "$bad_id"; [[ $? -eq 2 ]] || _create_fail=1
    quiet "$DECLARE_NO_WAIT" nohup "$bad_id"; [[ $? -eq 2 ]] || _create_fail=1
done
(( _create_fail )) && bad "create path reopened" "a hazard input was accepted" \
                   || ok "CREATE path still refuses every hazard input at rc 2"

echo "=== summary ==="
printf '  %d pass / %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    echo "FAIL"
    exit 1
fi
echo "ALL TESTS PASSED"
exit 0
