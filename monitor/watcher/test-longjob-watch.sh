#!/usr/bin/env bash
# monitor/watcher/test-longjob-watch.sh — the longjob-watch dispatcher
# (your-org/nexus-code#1535): the five-answer probe contract across every
# shipped subject kind, the dispatcher's emit policy (terminal-only by
# default, transitions on request, dedup, per-watch and per-session caps,
# unknown → bounded retry → UNKNOWN emit, TTL → EXPIRED), the NEVER-EXIT
# property (alive after every watch retired), the emit path recording its
# own failure, the ledger verdicts `status` derives, the declare-wait bridge,
# `await` as the fallback wake, `resolve` for the orphan-async resolver, and
# the resolver's `longjob` arm end to end.
#
# HERMETIC: NEXUS_STATE_DIR is a temp dir, the session key is pinned via
# NEXUS_LONGJOB_KEY, `sacct`/`squeue` are PATH-front stubs driven by a file,
# `async-run.sh` is a stub under a fixture NEXUS_ROOT, the dispatcher is this
# suite's own child (killed by pid it recorded, never by name).
#
# POTENCY CONTROLS (a test asserting "no event was emitted" passes just as
# happily when the emitter was never wired): every negative assertion here
# sits beside a positive one on the SAME rig differing by one flag —
# `--notify terminal` prints nothing on pending→running while
# `--notify transitions` prints exactly one line; the MUTED rig proves the
# cap by printing the cap line and NOT the third event, on a dispatcher that
# was shown to print the first two; and the "alive after all retire" check is
# shown able to fail by killing the dispatcher and re-running the same probe.
#
# MUTATION FLIP SET, predicted BEFORE the first run (monitor/mutation-gate.sh
# --suite <this> --list, then --line N on monitor/longjob-watch.sh):
#   FLIPS   the `retired` jq predicate line (every dispatcher case goes red,
#           the #1 bug this suite was born from); the `unknown` streak
#           comparison `(( streak >= umax ))` (UNKNOWN never emitted);
#           the `EMITTED >= SESSION_MAX_EVENTS` cap line (MUTED never printed
#           AND the third event printed); the `[[ "$new_state" != "$prev" ]]`
#           dedup on persistent watches (duplicate line); `trap '' PIPE`
#           (the closed-stdout rig kills the dispatcher: alive check red);
#           the ttl comparison (EXPIRED never emitted).
#   NO FLIP the `_lj_plugin_log`-style side channels this suite does not read,
#           the `note:` text of a pid: add, the `sed -n '2,110p'` usage arm,
#           and the LEDGER_FRESH_SECONDS +30 slack (this suite's stale ledger
#           is 10 000 s old, far outside any plausible slack) — the last is
#           the deliberate should-NOT-flip case.
set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
LJ="$REPO_ROOT/monitor/longjob-watch.sh"
PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s\n' "$1" >&2; FAIL=$(( FAIL + 1 )); }
WORK=$(mktemp -d -t lj-test-XXXXXX)
DPIDS=()
cleanup() { local p; for p in "${DPIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

export NEXUS_STATE_DIR="$WORK/state"; mkdir -p "$NEXUS_STATE_DIR/heartbeat"
export NEXUS_LONGJOB_KEY="t1"
export MONITOR_LONGJOB_POLL_SECONDS=5
export MONITOR_LONGJOB_PROBE_TIMEOUT_SECONDS=10
unset NEXUS_WORKER_WINDOW NEXUS_ORCHESTRATOR_WINDOW NEXUS_LONGJOB_WINDOW CLAUDE_CODE_SESSION_ID NEXUS_LONGJOB_SESSION_ID 2>/dev/null || true
SPOOL="$NEXUS_STATE_DIR/longjob/t1"

# ---- PATH-front stubs: sacct / squeue driven by files -----------------------
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/sacct" <<'EOF'
#!/usr/bin/env bash
# emits the contents of $LJ_SACCT_FILE (one "State|ExitCode" line, or empty)
[[ -f "${LJ_SACCT_FILE:-}" ]] && cat "$LJ_SACCT_FILE"; exit 0
EOF
cat > "$STUB/squeue" <<'EOF'
#!/usr/bin/env bash
[[ -f "${LJ_SQUEUE_FILE:-}" ]] && cat "$LJ_SQUEUE_FILE"; exit 0
EOF
chmod +x "$STUB/sacct" "$STUB/squeue"
export PATH="$STUB:$PATH"
export LJ_SACCT_FILE="$WORK/sacct.out" LJ_SQUEUE_FILE="$WORK/squeue.out"

# ---- fixture NEXUS_ROOT with a stub async-run.sh ------------------------------
FROOT="$WORK/froot"; mkdir -p "$FROOT/monitor"
cat > "$FROOT/monitor/async-run.sh" <<'EOF'
#!/usr/bin/env bash
# --disposition-line <token> → canned answers keyed on the token
[[ "${1:-}" == --disposition-line ]] || exit 2
case "${2:-}" in
  tok-live)   printf 'live|running|pid=1 alive\n' ;;
  tok-ok)     printf 'settled|terminal|rc=0 elapsed=3s\n' ;;
  tok-quiet)  printf 'settled|terminal|rc=0 elapsed=3s out=0B err=0B NO-OUTPUT-CAPTURED: the job wrote NOTHING to either stream, so this rc is UNCORROBORATED — it is the status of the payload%ss LAST command, and a payload that redirects its own output leaves this surface blank. Find the payload%ss own log before treating this rc as a verdict on its work\n' "'" "'" ;;
  tok-bad)    printf 'settled|terminal|rc=2 elapsed=3s\n' ;;
  tok-gone)   printf 'gone|died|pid gone, no status file\n' ;;
  *)          printf '\n' ;;
esac
EOF
chmod +x "$FROOT/monitor/async-run.sh"

probe() { NEXUS_ROOT="$FROOT" "$LJ" probe "$@"; }

echo "=== probe contract: cmd: exit status vocabulary ==="
[[ "$(probe cmd:'exit 0')" == done\|* ]]    && ok "cmd rc 0 → done"    || bad "cmd rc 0: $(probe cmd:'exit 0')"
[[ "$(probe cmd:'exit 1')" == running\|* ]] && ok "cmd rc 1 → running" || bad "cmd rc 1"
[[ "$(probe cmd:'exit 2')" == failed\|* ]]  && ok "cmd rc 2 → failed"  || bad "cmd rc 2"
[[ "$(probe cmd:'exit 3')" == unknown\|* ]] && ok "cmd rc 3 → unknown" || bad "cmd rc 3"
[[ "$(probe cmd:'exit 7')" == failed\|* ]]  && ok "cmd rc 7 (outside the vocabulary) → failed: the default arm EMITS" || bad "cmd rc 7: $(probe cmd:'exit 7')"
out=$(MONITOR_LONGJOB_PROBE_TIMEOUT_SECONDS=2 probe cmd:'sleep 30')
[[ "$out" == unknown\|*"timed out"* ]] && ok "a probe exceeding the probe timeout → unknown (not running)" || bad "timeout: $out"
[[ "$(probe nosuch:x)" == unknown\|*"no probe for kind"* ]] && ok "an unknown kind → unknown with the reason" || bad "unknown kind: $(probe nosuch:x)"

echo "=== probe contract: slurm via stubbed sacct/squeue ==="
: > "$LJ_SQUEUE_FILE"
for pair in 'COMPLETED|0:0=done' 'FAILED|1:0=failed' 'TIMEOUT|0:0=failed' 'OUT_OF_MEMORY|0:125=failed' 'CANCELLED by 123|0:0=failed' 'NODE_FAIL|0:0=failed' 'RUNNING|0:0=running' 'PENDING|0:0=pending' 'COMPLETING|0:0=running' 'SOME_NEW_STATE|0:0=failed'; do
    row="${pair%=*}"; want="${pair#*=}"
    printf '%s\n' "$row" > "$LJ_SACCT_FILE"
    got=$(probe slurm:12345); [[ "$got" == "$want"\|* ]] && ok "sacct '$row' → $want" || bad "sacct '$row' → $got (want $want)"
done
: > "$LJ_SACCT_FILE"
got=$(probe slurm:12345); [[ "$got" == unknown\|*"no accounting row"* ]] && ok "no sacct row and no squeue row → unknown (never running)" || bad "empty sacct: $got"
printf 'PENDING\n' > "$LJ_SQUEUE_FILE"
got=$(probe slurm:12345); [[ "$got" == pending\|*squeue* ]] && ok "no sacct row but squeue PENDING → pending (second source consulted)" || bad "squeue fallback: $got"
: > "$LJ_SQUEUE_FILE"
got=$(probe slurm:abc); [[ "$got" == unknown\|* ]] && ok "a non-numeric slurm target → unknown" || bad "bad jobid: $got"

echo "=== probe contract: asyncrun via stubbed async-run.sh ==="
[[ "$(probe asyncrun:tok-live)" == running\|* ]] && ok "live → running" || bad "asyncrun live"
[[ "$(probe asyncrun:tok-ok)"   == done\|* ]]    && ok "settled rc=0 → done" || bad "asyncrun ok"
[[ "$(probe asyncrun:tok-bad)"  == failed\|* ]]  && ok "settled rc=2 → failed" || bad "asyncrun bad"
[[ "$(probe asyncrun:tok-gone)" == failed\|died* ]] && ok "gone → failed|died (truncated, never done)" || bad "asyncrun gone: $(probe asyncrun:tok-gone)"
[[ "$(probe asyncrun:tok-none)" == unknown\|* ]] && ok "no disposition → unknown" || bad "asyncrun none"

echo "=== probe contract: pid with identity ==="
sleep 300 & SP=$!; DPIDS+=("$SP")
st=$(awk '{print $22}' "/proc/$SP/stat")
[[ "$(probe pid:$SP:$st)" == running\|* ]] && ok "alive pid with matching start-time → running" || bad "pid running"
[[ "$(probe pid:$SP:999)" == done\|*RECYCLED* ]] && ok "alive pid with a DIFFERENT start-time → done (recycled), never running" || bad "pid recycled: $(probe pid:$SP:999)"
[[ "$(probe pid:$SP)" == unknown\|* ]] && ok "a bare occupied pid (no identity) → unknown" || bad "bare pid"
kill "$SP"; wait "$SP" 2>/dev/null
[[ "$(probe pid:$SP:$st)" == done\|*"NOT retained"* ]] && ok "gone pid → done and says the exit status is not retained" || bad "pid gone: $(probe pid:$SP:$st)"

echo "=== probe contract: file predicates ==="
[[ "$(probe file:$WORK/nofile)" == pending\|* ]] && ok "absent file, exists → pending" || bad "file absent"
touch "$WORK/f1"; [[ "$(probe file:$WORK/f1)" == done\|* ]] && ok "present file, exists → done" || bad "file present"
printf 'abc\n' > "$WORK/f2"
[[ "$(probe file:$WORK/f2 --when grew --size0 4)" == running\|* ]] && ok "grew: size == size0 → running" || bad "grew running"
[[ "$(probe file:$WORK/f2 --when grew --size0 1)" == done\|* ]]    && ok "grew: size > size0 → done" || bad "grew done"
[[ "$(probe file:$WORK/f2 --when match --pattern '^ab')" == done\|* ]]  && ok "match: hit → done" || bad "match hit"
[[ "$(probe file:$WORK/f2 --when match --pattern 'zzz')" == running\|* ]] && ok "match: no hit → running" || bad "match miss"
[[ "$(probe file:$WORK/f2 --when match --pattern '(')" == failed\|* ]]   && ok "match: bad regex → failed (cannot evaluate), not silence" || bad "match bad regex: $(probe file:$WORK/f2 --when match --pattern '(')"

echo "=== dispatch refuses arguments at once (never a silent forever loop) ==="
# bundle-2609: `dispatch --repo x` used to run the dispatcher forever, which
# held test-ng-flag-order.sh's per-sub-verb sweep past a 2400 s ceiling.
out=$(timeout 20 "$LJ" dispatch --repo x 2>&1 </dev/null); rc=$?
(( rc == 2 )) && [[ "$out" == *"takes no arguments"* ]] && ok "dispatch with an argument → rc 2 at once, names the refusal" || bad "dispatch with an argument: rc=$rc (124 = still running at 20 s) out=$out"

echo "=== status/add before any dispatcher: NOT ARMED is said, rc 3 ==="
out=$("$LJ" status 2>&1); rc=$?
(( rc == 3 )) && [[ "$out" == *"dispatcher=absent"* ]] && ok "status: absent ledger → rc 3, says absent" || bad "status absent: rc=$rc $out"
out=$("$LJ" add file:"$WORK/never" --id unarmed 2>&1); rc=$?
(( rc == 3 )) && [[ "$out" == *"WILL NOT WAKE YOU"* && "$out" == *"await unarmed"* ]] && ok "add in an unarmed session: rc 3, says the watch will NOT wake you and names the await fallback" || bad "add unarmed: rc=$rc $out"
"$LJ" rm unarmed >/dev/null

echo "=== ledger verdicts: dead / stale, from planted ledgers ==="
mkdir -p "$SPOOL"
jq -n '{version:2, service:"polling", pid:999999, pid_start:"1", last_poll:0, active:0, poll_seconds:5, muted:0}' > "$SPOOL/dispatcher.json"
out=$("$LJ" status 2>&1); [[ "$out" == *"dispatcher=dead"* ]] && ok "ledger with a gone pid → dead" || bad "dead: $out"
myst=$(awk '{print $22}' /proc/$$/stat)
jq -n --arg p "$$" --arg s "$myst" '{version:2, service:"polling", pid:($p|tonumber), pid_start:$s, last_poll:(now|floor - 10000), active:0, poll_seconds:5, muted:0}' > "$SPOOL/dispatcher.json"
out=$("$LJ" status 2>&1); [[ "$out" == *"dispatcher=stale"* ]] && ok "ledger with a LIVE pid but a 10 000 s old poll → stale (alive is not polling)" || bad "stale: $out"
rm -f "$SPOOL/dispatcher.json"

echo "=== dispatcher: terminal-only default, transitions on request, unknown parking, TTL, never exit ==="
: > "$LJ_SACCT_FILE"; : > "$LJ_SQUEUE_FILE"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out1.txt" 2> "$WORK/err1.txt" &
D1=$!; DPIDS+=("$D1")
sleep 2
out=$("$LJ" add file:"$WORK/w1" --id w1 --interval 5 --desc "the w1 file" 2>&1); rc=$?
(( rc == 0 )) && [[ "$out" == *"dispatcher: ARMED"* ]] && ok "add with a live dispatcher: rc 0, says ARMED and that ending the turn is safe" || bad "add armed: rc=$rc $out"
[[ "$out" == *"first probe: pending|"* ]] && ok "add runs a synchronous first probe and shows it" || bad "first probe missing: $out"
"$LJ" add cmd:"test -e $WORK/w2 && exit 0; exit 1" --id w2 --interval 5 --notify transitions >/dev/null
"$LJ" add cmd:"test -e $WORK/w3 && exit 0; exit 1" --id w3 --interval 5 >/dev/null
"$LJ" add slurm:777 --id w4 --interval 5 --unknown-max 2 >/dev/null
"$LJ" add cmd:'exit 1' --id w5 --interval 5 --ttl 1 >/dev/null
out=$("$LJ" status); [[ "$out" == *"dispatcher=armed"* && "$out" == *"active_watches=5"* ]] && ok "status: armed, 5 active" || bad "status armed: $out"
sleep 10                             # first poll: w2/w3 pending→running (w2 prints, w3 does not), w4 unknown #1, w5 expired — five probes plus one paced print
[[ "$(jq -r '.retired_reason' "$SPOOL/watches/w5.json")" == expired ]] && ok "w5 retired: expired" || bad "w5 not yet expired"
touch "$WORK/w1"; touch "$WORK/w2"
sleep 7                              # second poll: w1 done, w2 done, w4 unknown #2 → UNKNOWN
sleep 6                              # third poll: settle
o=$(cat "$WORK/out1.txt")
grep -q '^longjob-watch: DONE w1 | record: monitor/longjob-watch.sh show w1 | file:.* \[desc: the w1 file\] — .*exists$' <<<"$o" && ok "w1: DONE line — pointer FIRST, then subject and desc, detail last" || bad "w1 line: $(grep 'DONE w1' <<<"$o")"
grep -q '^longjob-watch: RUNNING w2 | record: monitor/longjob-watch.sh show w2 | cmd:.*transition pending → running' <<<"$o" && ok "w2 (--notify transitions): pending→running printed" || bad "w2 transition missing"
grep -q '^longjob-watch: DONE w2 ' <<<"$o" && ok "w2: terminal DONE printed" || bad "w2 done missing"
! grep -q 'RUNNING w3' <<<"$o" && ok "w3 (default terminal): pending→running NOT printed — the negative whose positive control is w2 on the same rig" || bad "w3 printed a transition"
grep -q '^longjob-watch: UNKNOWN w4 | record: monitor/longjob-watch.sh show w4 | slurm:777 | PARKED after 2 consecutive unknown probes' <<<"$o" && ok "w4: UNKNOWN emitted after unknown_max=2 consecutive unknowns, watch parked" || bad "w4 unknown: $(grep 'UNKNOWN w4' <<<"$o")"
grep -q '^longjob-watch: EXPIRED w5 ' <<<"$o" && ok "w5: TTL 1 s → EXPIRED emitted" || bad "w5 expired missing"
grep -q '^longjob-watch: EXPIRED w5 | record: monitor/longjob-watch.sh show w5 | cmd:exit 1 | TTL reached' <<<"$o" && ok "F4: the record pointer comes first, then subject and action clause, the detail last" || bad "F4 line order: $(grep 'EXPIRED w5' <<<"$o")"
c=$(grep -c '^longjob-watch: ' <<<"$o"); (( c == 5 )) && ok "exactly 5 lines printed (w1, w2×2, w4, w5)" || bad "line count $c: $o"
[[ "$(jq -r .retired_reason "$SPOOL/watches/w4.json")" == unknown ]] && ok "w4 spec retired_reason=unknown" || bad "w4 spec"
[[ "$(jq -r '.state + "/" + .retired_reason' "$SPOOL/watches/w3.json")" == "running/" ]] && ok "w3 still active, state running (never printed, still tracked)" || bad "w3 spec: $(cat "$SPOOL/watches/w3.json")"
touch "$WORK/w3"; sleep 7
grep -q '^longjob-watch: DONE w3 ' "$WORK/out1.txt" && ok "w3: DONE printed once its predicate held" || bad "w3 done missing"
# F4: a detail at the probe's own 400-char cap plus a long desc must still fit under the host's 500-char cut
# a 250-char target (in the HEAD) + a 200-char probe detail (the cmd probe's own cap) + a long desc: only the DETAIL may be trimmed
"$LJ" add cmd:"printf '%0400d' 0; exit 2 # $(printf 'x%.0s' $(seq 1 250))" --id w6 --interval 5 --desc "$(printf 'd%.0s' $(seq 1 120))" >/dev/null 2>&1
sleep 9
l6=$(grep '^longjob-watch: FAILED w6 ' "$WORK/out1.txt"); (( ${#l6} > 0 && ${#l6} <= 480 )) && [[ "$l6" == *"| record: monitor/longjob-watch.sh show w6 |"* ]] && ok "F4: a 250-char target + 200-char detail + 120-char desc composes to ${#l6} chars ≤ 480 with the pointer intact (the head's elements are bounded; the adversarial shapes are in the D3 block)" || bad "F4 long line: ${#l6} chars: ${l6:0:120}…"
act=$("$LJ" status | grep active_watches); [[ "$act" == "active_watches=0" ]] && ok "every watch retired" || bad "$act"
if [[ -d "/proc/$D1" ]]; then ok "NEVER EXIT: dispatcher alive after every watch retired (pid $D1)"; else bad "dispatcher exited after the spool emptied"; fi
[[ -s "$WORK/err1.txt" ]] && bad "dispatcher wrote to stderr: $(head -3 "$WORK/err1.txt")" || ok "dispatcher wrote nothing to stderr"
e=$(grep -c $'\tdone\twritten\t\|\tunknown\twritten\t\|\tfailed\twritten\t' "$SPOOL/events.log"); (( e == 6 )) && ok "events.log records 6 WRITTEN terminal events (w1 w2 w3 w4 w5 w6; the word is written, never delivered — delivery is unobservable here)" || bad "events.log: $(cat "$SPOOL/events.log")"
! grep -q $'\t1\t' "$SPOOL/events.log" && ok "events.log carries no boolean printed=1 anywhere (skeptic F1: a record must not assert a delivery it cannot see)" || bad "a printed=1 row survives"
[[ "$(jq -r '.written' "$SPOOL/dispatcher.json")" == 7 ]] && [[ "$(jq -r '.emitted' "$SPOOL/dispatcher.json")" == null ]] && ok "ledger counts 'written' (7 = 6 terminal + w2's transition) and has no 'emitted' field" || bad "ledger fields: $(jq -c . "$SPOOL/dispatcher.json")"
# F1 pacing: w1 and w2 went terminal in the SAME poll pass; their lines must be ≥ 2 s apart
t1=$(awk -F'\t' '$2=="w1" && $3=="done"{print $1}' "$SPOOL/events.log"); t2=$(awk -F'\t' '$2=="w2" && $3=="done"{print $1}' "$SPOOL/events.log")
(( t2 - t1 >= 2 )) && ok "F1: two lines from ONE poll pass are paced ≥ 2 s apart (w1@$t1, w2@$t2) — the host's bucket refills 1 per 2 s, so a burst can never drain it" || bad "F1 pacing: w1@$t1 w2@$t2"
kill "$D1"; wait "$D1" 2>/dev/null
if [[ ! -d "/proc/$D1" ]]; then ok "POTENCY: the alive check reads a killed dispatcher as gone" ; else bad "alive check cannot fail"; fi
sleep 1
out=$("$LJ" status 2>&1); [[ "$out" == *"dispatcher=dead"* ]] && ok "status after the kill → dead" || bad "status dead: $out"

echo "=== dispatcher: persistent watch, dedup, per-watch cap, session cap + unmute ==="
export NEXUS_LONGJOB_KEY="t2"; SPOOL2="$NEXUS_STATE_DIR/longjob/t2"
NEXUS_ROOT="$FROOT" MONITOR_LONGJOB_SESSION_MAX_EVENTS=2 "$LJ" dispatch > "$WORK/out2.txt" 2> "$WORK/err2.txt" &
D2=$!; DPIDS+=("$D2"); sleep 2
# p1: persistent, level-triggered: failed while $WORK/down exists, running otherwise
"$LJ" add cmd:"test -e $WORK/down && exit 2; exit 1" --id p1 --interval 5 --persistent >/dev/null
sleep 7                                   # poll 1: running (no print: not a transition from failed)
touch "$WORK/down"; sleep 9               # poll 2: running→failed → print #1   (passes that print are paced: ≥ 2.5 s longer)
sleep 9                                   # poll 3: failed again → DEDUP, no print
rm -f "$WORK/down"; sleep 9               # poll 4: failed→running → print #2 (recovery)
touch "$WORK/down"; sleep 9               # poll 5: running→failed → would be print #3 → SESSION CAP → MUTED line
o=$(cat "$WORK/out2.txt")
(( $(grep -c '^longjob-watch: FAILED p1 ' <<<"$o") == 1 )) && ok "persistent: running→failed printed exactly once (dedup on the repeated failed poll)" || bad "p1 failed count: $o"
grep -q '^longjob-watch: RUNNING p1 .*transition failed → running' <<<"$o" && ok "persistent: failed→running recovery printed" || bad "p1 recovery missing: $o"
grep -q '^longjob-watch: MUTED — this session.s event cap (2) is reached' <<<"$o" && ok "session cap: the MUTED line is printed once the cap is reached" || bad "muted line missing: $o"
(( $(grep -c '^longjob-watch: ' <<<"$o") == 3 )) && ok "exactly 3 lines: two events then the cap notice — the third event was NOT delivered" || bad "line count: $o"
grep -q $'\tfailed\tmuted\t' "$SPOOL2/events.log" && ok "the suppressed event is in events.log as muted" || bad "events.log lacks muted row: $(cat "$SPOOL2/events.log")"
[[ "$(jq -r .muted "$SPOOL2/dispatcher.json")" == 1 ]] && ok "ledger muted=1" || bad "ledger not muted"
"$LJ" status >/dev/null 2>&1; rc=$?; (( rc == 3 )) && ok "status while muted → rc 3 (not armed-and-well)" || bad "status muted rc=$rc"
"$LJ" unmute >/dev/null; rm -f "$WORK/down"
# the flag is consumed at the next pass and the transition prints in it or the one after (paced): poll, bounded
# the recovery line must appear AFTER the MUTED line (order, not just presence): wait up to 60 s under load
_after_mute() { awk '/^longjob-watch: MUTED/{m=NR} /^longjob-watch: RUNNING p1 .*transition failed → running/{r=NR} END{exit !(m>0 && r>m)}' "$WORK/out2.txt"; }
for i in $(seq 1 120); do _after_mute && break; sleep 0.5; done
_after_mute && ok "after unmute the next transition is delivered again (a RUNNING line after the MUTED line)" || bad "post-unmute: out2=$(tr '\n' '|' < "$WORK/out2.txt" | cut -c1-200) events=$(cut -f1-4 "$SPOOL2/events.log" | tr '\n' '|') ledger=$(jq -c '{muted,written,note,last_poll}' "$SPOOL2/dispatcher.json") flag=$([ -f "$SPOOL2/unmute.flag" ] && echo still-present || echo consumed) now=$(date -u +%s)"
[[ -d "/proc/$D2" ]] && ok "persistent watch never retires and the dispatcher is still alive" || bad "D2 gone"
# per-watch cap on a fresh, unmuted dispatcher
kill "$D2"; wait "$D2" 2>/dev/null
export NEXUS_LONGJOB_KEY="t3"; SPOOL3="$NEXUS_STATE_DIR/longjob/t3"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out3.txt" 2>/dev/null &
D3=$!; DPIDS+=("$D3"); sleep 2
rm -f "$WORK/down"
"$LJ" add cmd:"test -e $WORK/down && exit 2; exit 1" --id c1 --interval 5 --persistent --max-events 1 >/dev/null
sleep 7; touch "$WORK/down"; sleep 9; rm -f "$WORK/down"; sleep 9
o=$(cat "$WORK/out3.txt")
(( $(grep -c '^longjob-watch: ' <<<"$o") == 1 )) && ok "per-watch cap 1: the first transition printed, the second suppressed" || bad "watch cap: $o"
[[ "$(jq -r .retired_reason "$SPOOL3/watches/c1.json")" == event-cap ]] && ok "watch retired with reason event-cap" || bad "cap retire reason: $(jq -c . "$SPOOL3/watches/c1.json")"
grep -q $'\tcapped\t' "$SPOOL3/events.log" && ok "the capped transition is logged as capped" || bad "no capped row"
echo "=== F7: agent watches are emitted before auto-* watches, whatever the alphabet says ==="
export NEXUS_LONGJOB_KEY="t7"; SPOOL7="$NEXUS_STATE_DIR/longjob/t7"
# both specs exist BEFORE the dispatcher starts, so its first pass sees both at once
"$LJ" add cmd:'exit 0' --id auto-slurm-1 --interval 5 --no-declare >/dev/null 2>&1   # sorts FIRST alphabetically
"$LJ" add cmd:'exit 0' --id zz-mine --interval 5 >/dev/null 2>&1                    # the agent's own, sorts LAST
NEXUS_ROOT="$FROOT" MONITOR_LONGJOB_SESSION_MAX_EVENTS=1 "$LJ" dispatch > "$WORK/out7.txt" 2>/dev/null &
D7=$!; DPIDS+=("$D7"); sleep 9
grep -q '^longjob-watch: DONE zz-mine ' "$WORK/out7.txt" && ! grep -q '^longjob-watch: DONE auto-slurm-1 ' "$WORK/out7.txt" && ok "F7: with a budget of 1 the agent's watch got the line and the auto-* one was muted" || bad "F7: $(cat "$WORK/out7.txt")"
kill "$D7"; wait "$D7" 2>/dev/null
echo "=== F6: a fatal error inside a poll pass does not kill the dispatcher ==="
export NEXUS_LONGJOB_KEY="t8"; SPOOL8="$NEXUS_STATE_DIR/longjob/t8"; mkdir -p "$SPOOL8/watches"
# a spec with a NON-NUMERIC interval (valid JSON, id matches the file) — the shape the skeptic measured killing the dispatcher on its first poll
jq -n '{id:"bad1", kind:"cmd", target:"exit 1", desc:"", session_key:"t8", added_at:0, interval:"abc", ttl:604800, notify:"terminal", persistent:false, max_events:8, unknown_max:5, when:"", pattern:"", size0:0, state:"pending", detail:"", last_probe:0, unknown_streak:0, events:0, retired:false, retired_reason:"", retired_at:0}' > "$SPOOL8/watches/bad1.json"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out8.txt" 2>/dev/null &
D8=$!; DPIDS+=("$D8"); sleep 8
[[ -d "/proc/$D8" ]] && ok "F6: dispatcher alive after polling a spec with interval=\"abc\"" || bad "F6: dispatcher died on a non-numeric field"
grep -q $'\tcorrupt\t' "$SPOOL8/events.log" && ok "F6: the bad field is logged as corrupt and defaulted" || bad "F6 no corrupt row: $(cat "$SPOOL8/events.log")"
[[ "$(jq -r .note "$SPOOL8/dispatcher.json")" == ok ]] && ok "F6: the pass completed (ledger note ok) — validation, not the subshell, handled it" || bad "F6 note: $(jq -r .note "$SPOOL8/dispatcher.json")"
# the subshell isolation itself, with a POTENCY control: a pass that dies fatally leaves the loop alive
"$LJ" add cmd:'exit 0' --id ok1 --interval 5 >/dev/null 2>&1; sleep 7
grep -q '^longjob-watch: DONE ok1 ' "$WORK/out8.txt" && ok "F6: a later, healthy watch is still served" || bad "F6: ok1 not served"
kill "$D8"; wait "$D8" 2>/dev/null
kill "$D3"; wait "$D3" 2>/dev/null

echo "=== the emit path records its own failure (stdout closed) ==="
export NEXUS_LONGJOB_KEY="t4"; SPOOL4="$NEXUS_STATE_DIR/longjob/t4"
NEXUS_ROOT="$FROOT" "$LJ" dispatch >&- 2>/dev/null &
D4=$!; DPIDS+=("$D4"); sleep 2
"$LJ" add cmd:'exit 0' --id e1 --interval 5 >/dev/null 2>&1
sleep 8
[[ -d "/proc/$D4" ]] && ok "a CLOSED stdout does not kill the dispatcher (SIGPIPE ignored, printf rc read)" || bad "dispatcher died on closed stdout"
[[ "$(jq -r .emit_failures "$SPOOL4/dispatcher.json")" -ge 1 ]] && ok "ledger emit_failures ≥ 1" || bad "emit_failures: $(cat "$SPOOL4/dispatcher.json")"
grep -q 'EMIT-FAILED' "$SPOOL4/emit-failures.log" && ok "emit-failures.log names the undelivered line" || bad "emit-failures.log: $(cat "$SPOOL4/emit-failures.log" 2>&1)"
out=$("$LJ" status 2>&1); [[ "$out" == *"EMIT FAILURES"* ]] && ok "status surfaces the emit failures" || bad "status no emit failures: $out"
kill "$D4"; wait "$D4" 2>/dev/null

echo "=== …and a stdout whose READER has gone (SIGPIPE, the case a closed fd cannot reach) ==="
# `>&-` above yields EBADF on write — an rc, no signal — so it exercises the
# rc check and NOT `trap '' PIPE`. Measured: deleting the trap left every case
# above green (subject mutation M4). A pipe whose reader exited is the signal
# path: without the trap bash dies of SIGPIPE on the first emit.
export NEXUS_LONGJOB_KEY="t4p"; SPOOL4P="$NEXUS_STATE_DIR/longjob/t4p"
mkfifo "$WORK/pipe4"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/pipe4" 2>/dev/null &
D4P=$!; DPIDS+=("$D4P")
sleep 1 < "$WORK/pipe4"          # a reader opens the pipe for one second, then leaves
sleep 1
"$LJ" add cmd:'exit 0' --id p1 --interval 5 >/dev/null 2>&1
sleep 8
[[ -d "/proc/$D4P" ]] && ok "an emit into a pipe with NO reader does not kill the dispatcher (trap '' PIPE)" || bad "dispatcher died of SIGPIPE (rc would be 141)"
[[ "$(jq -r .emit_failures "$SPOOL4P/dispatcher.json" 2>/dev/null)" -ge 1 ]] && ok "…and the EPIPE write is counted as an emit failure" || bad "emit_failures after SIGPIPE: $(cat "$SPOOL4P/dispatcher.json" 2>&1)"
kill "$D4P" 2>/dev/null; wait "$D4P" 2>/dev/null

echo "=== declare-wait bridge + resolve + the orphan-async longjob arm ==="
export NEXUS_LONGJOB_KEY="t5" NEXUS_WORKER_WINDOW="lj-win"; SPOOL5="$NEXUS_STATE_DIR/longjob/t5"
HB="$NEXUS_STATE_DIR/heartbeat/lj-win.json"
jq -n '{window:"lj-win", session_id:"11111111-2222-3333-4444-555555555555", state:"idle", external_waits:[]}' > "$HB"
"$LJ" add cmd:'exit 1' --id b1 --interval 5 >/dev/null 2>&1
[[ "$(jq -r '.external_waits[] | select(.kind=="longjob") | .id' "$HB")" == b1 ]] && ok "add declares an external wait kind=longjob id=<watch id> in the window's heartbeat" || bad "declare-wait: $(cat "$HB")"
[[ "$("$LJ" resolve b1)" == running\|* ]] && ok "resolve b1 (rc 1 probe) → running" || bad "resolve running: $("$LJ" resolve b1)"
"$LJ" add cmd:'exit 0' --id b2 --interval 5 >/dev/null 2>&1
[[ "$("$LJ" resolve b2)" == terminal\|done* ]] && ok "resolve b2 (rc 0 probe) → terminal|done" || bad "resolve terminal: $("$LJ" resolve b2)"
[[ "$("$LJ" resolve nope)" == unresolvable\|* ]] && ok "resolve of an unknown id → unresolvable" || bad "resolve nope"
# the resolver arm, driven through the REAL _orphan_async_resolve with a session-id-keyed spool
export NEXUS_LONGJOB_KEY="sid-11111111-2222-3333-4444-555555555555"
"$LJ" add cmd:'exit 0' --id r1 --interval 5 >/dev/null 2>&1
unset NEXUS_LONGJOB_KEY
STATE_DIR="$NEXUS_STATE_DIR"; export STATE_DIR
NEXUS_ROOT="$REPO_ROOT"; export NEXUS_ROOT
# shellcheck source=monitor/watcher/_orphan_async.sh
. "$_test_dir/_orphan_async.sh"
got=$(_orphan_async_resolve longjob r1 lj-win)
[[ "$got" == terminal\|done* ]] && ok "_orphan_async_resolve longjob → terminal via the heartbeat's session_id-keyed spool" || bad "resolver arm: $got"
got=$(_orphan_async_resolve longjob r-none lj-win)
[[ "$got" == unresolvable\|* ]] && ok "resolver arm: unknown watch → unresolvable (never terminal, never running)" || bad "resolver arm none: $got"
export NEXUS_LONGJOB_KEY="t5"
# retirement removes the wait: run a dispatcher on t5 and let b2 retire
NEXUS_ROOT="$FROOT" "$LJ" dispatch >/dev/null 2>&1 &
D5=$!; DPIDS+=("$D5"); sleep 7
[[ -z "$(jq -r '.external_waits[] | select(.id=="b2") | .id' "$HB")" ]] && ok "retiring b2 removed its external wait" || bad "wait b2 still declared: $(cat "$HB")"
[[ "$(jq -r '.external_waits[] | select(.id=="b1") | .id' "$HB")" == b1 ]] && ok "the still-running b1 wait is still declared" || bad "b1 wait gone"
echo "=== F3: a NON-terminal retirement keeps the external wait (the backstop) ==="
"$LJ" add cmd:'exit 1' --id b3 --interval 5 --ttl 1 >/dev/null 2>&1
"$LJ" add cmd:'exit 3' --id b4 --interval 5 --unknown-max 1 >/dev/null 2>&1
sleep 7
[[ "$(jq -r .retired_reason "$SPOOL5/watches/b3.json")" == expired && "$(jq -r '.external_waits[] | select(.id=="b3") | .id' "$HB")" == b3 ]] && ok "F3: TTL expiry retires the WATCH but keeps the WAIT declared" || bad "F3 expired: $(jq -c . "$SPOOL5/watches/b3.json") waits=$(jq -c .external_waits "$HB")"
[[ "$(jq -r .retired_reason "$SPOOL5/watches/b4.json")" == unknown && "$(jq -r '.external_waits[] | select(.id=="b4") | .id' "$HB")" == b4 ]] && ok "F3: an unknown park keeps the wait declared too" || bad "F3 unknown: waits=$(jq -c .external_waits "$HB")"
[[ "$("$LJ" resolve b3)" == running\|* ]] && ok "F3: resolve on an expired watch probes the SUBJECT live (running), not the park" || bad "F3 resolve b3: $("$LJ" resolve b3)"
kill "$D5"; wait "$D5" 2>/dev/null

echo "=== await: the fallback wake (rc 0 / 1 / 4) ==="
export NEXUS_LONGJOB_KEY="t6"
"$LJ" add file:"$WORK/aw1" --id aw1 --interval 2 >/dev/null 2>&1
( sleep 3; touch "$WORK/aw1" ) &
"$LJ" await aw1 --timeout 30 >/dev/null; rc=$?; (( rc == 0 )) && ok "await → 0 when the file appears" || bad "await done rc=$rc"
"$LJ" add cmd:'exit 2' --id aw2 --interval 2 >/dev/null 2>&1
"$LJ" await aw2 --timeout 30 >/dev/null; rc=$?; (( rc == 1 )) && ok "await → 1 on failed" || bad "await failed rc=$rc"
"$LJ" add cmd:'exit 1' --id aw3 --interval 2 >/dev/null 2>&1
"$LJ" await aw3 --timeout 3 >/dev/null; rc=$?; (( rc == 4 )) && ok "await → 4 on timeout (never a silent 0)" || bad "await timeout rc=$rc"
# await has its OWN unknown-streak loop (a copy of the dispatcher's policy): a
# subject mutation of the dispatcher's `(( streak >= umax ))` first landed on
# THIS copy and the suite stayed green — because nothing drove it. Now it does.
"$LJ" add cmd:'exit 3' --id aw4 --interval 1 --unknown-max 2 >/dev/null 2>&1
"$LJ" await aw4 --timeout 20 >/dev/null; rc=$?; (( rc == 3 )) && ok "await → 3 after unknown_max consecutive unknown probes (parked, never 0 and never a hang)" || bad "await unknown rc=$rc"

echo "=== D1: a paced burst keeps the ledger ARMED mid-pass (a healthy dispatcher must never read stale) ==="
# COVERED SHAPE: the paced-burst pass (emits make the pass long). The
# probe-slow pass (no emits) is the R1 block below. Neither alone is the property.
export NEXUS_LONGJOB_KEY="t9"; SPOOL9="$NEXUS_STATE_DIR/longjob/t9"
for k in $(seq 1 8); do "$LJ" add "file:$WORK/b$k" --id "b$k" --interval 5 >/dev/null 2>&1; touch "$WORK/b$k"; done
NEXUS_ROOT="$FROOT" MONITOR_LONGJOB_EMIT_MIN_GAP_MS=2500 "$LJ" dispatch > "$WORK/out9.txt" 2>/dev/null &
D9=$!; DPIDS+=("$D9")
sleep 12                                   # 8 terminal events × 2.5 s pacing = a ~20 s pass; we are in the middle of it
o9=$(wc -l < "$WORK/out9.txt"); (( o9 >= 2 && o9 <= 7 )) && ok "D1 rig: mid-burst ($o9 of 8 lines written so far) — the pass is genuinely in progress" || bad "D1 rig: $o9 lines at t=12 s (expected 2..7)"
st=$("$LJ" status 2>&1); [[ "$st" == *"dispatcher=armed"* ]] && ok "D1: ledger-verdict reads ARMED mid-burst (last_poll touched before each paced wait)" || bad "D1: $st"
lp1=$(jq -r .last_poll "$SPOOL9/dispatcher.json"); sleep 5; lp2=$(jq -r .last_poll "$SPOOL9/dispatcher.json")
(( lp2 > lp1 )) && ok "D1 relation guard: last_poll ADVANCED during the burst ($lp1 → $lp2) — the writer keeps its contract inside a pass, not only between passes" || bad "D1: last_poll did not advance ($lp1 → $lp2)"
out=$("$LJ" add cmd:'exit 1' --id b-late --interval 5 2>&1); rc=$?; (( rc == 0 )) && [[ "$out" == *"dispatcher: ARMED"* ]] && ok "D1: a fresh add mid-burst is told ARMED, rc 0" || bad "D1 add mid-burst: rc=$rc $out"
sleep 16
(( $(grep -c '^longjob-watch: DONE b' "$WORK/out9.txt") == 8 )) && ok "D1: all 8 lines written after the burst" || bad "D1: $(grep -c '^longjob-watch: DONE b' "$WORK/out9.txt") of 8"
kill "$D9"; wait "$D9" 2>/dev/null

echo "=== R1: a pass made long by SLOW PROBES with NO transitions still keeps the ledger fresh ==="
# COVERED SHAPES, stated (the round-three lesson): the D1 block above pins the
# PACED-BURST pass, the shape the D1 fix addressed; the skeptic then found the
# same property broken by a PROBE-SLOW pass with zero emits. This block pins
# that second shape. A guard covers the shape its author was thinking about
# — say which one it is.
export NEXUS_LONGJOB_KEY="t13"; SPOOL13="$NEXUS_STATE_DIR/longjob/t13"
for k in 1 2 3 4; do "$LJ" add cmd:'sleep 8; exit 1' --id "s$k" --interval 5 >/dev/null 2>&1; done   # 4 × 8 s probes, never a transition
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out13.txt" 2>/dev/null &
D13=$!; DPIDS+=("$D13"); sleep 18                                   # mid-pass: ~2 probes in, 0 emits, window = 3×5+30 = 45 s
lp1=$(jq -r .last_poll "$SPOOL13/dispatcher.json"); v=$("$LJ" ledger-verdict "$SPOOL13/dispatcher.json")
[[ "$v" == armed\|* ]] && ok "R1: armed at t=18 s of a 32 s zero-emit pass" || bad "R1 t=18: $v"
sleep 12; lp2=$(jq -r .last_poll "$SPOOL13/dispatcher.json"); v=$("$LJ" ledger-verdict "$SPOOL13/dispatcher.json")
[[ "$v" == armed\|* ]] && (( lp2 > lp1 )) && ok "R1: still armed at t=30 s and last_poll advanced ($lp1 → $lp2) with emits=0 — the heartbeat beats on TIME, not on events" || bad "R1 t=30: $v lp $lp1→$lp2"
[[ "$(jq -r .written "$SPOOL13/dispatcher.json")" == 0 ]] && ok "R1 control: nothing was written to stdout during the pass (the emit path is not what kept it fresh)" || bad "R1 control: written=$(jq -r .written "$SPOOL13/dispatcher.json")"
kill "$D13"; wait "$D13" 2>/dev/null
echo "=== R1 relation guard: a probe timeout past the freshness window is refused at start ==="
export NEXUS_LONGJOB_KEY="t14"; SPOOL14="$NEXUS_STATE_DIR/longjob/t14"
NEXUS_ROOT="$FROOT" MONITOR_LONGJOB_PROBE_TIMEOUT_SECONDS=100 "$LJ" dispatch > /dev/null 2> "$WORK/err14.txt" &
D14=$!; DPIDS+=("$D14"); sleep 3
[[ -d "/proc/$D14" ]] && [[ "$(jq -r .service "$SPOOL14/dispatcher.json")" == disabled ]] && grep -q 'probe_timeout_seconds (100) exceeds' "$WORK/err14.txt" && ok "R1 guard: probe_timeout 100 s vs poll 5 s → alive, service=disabled, said on stderr (never exits, never claims armed)" || bad "R1 guard: alive=$([ -d /proc/$D14 ] && echo y || echo n) $(cat "$SPOOL14/dispatcher.json" 2>&1 | cut -c1-120) $(cat "$WORK/err14.txt")"
kill "$D14"; wait "$D14" 2>/dev/null

echo "=== D2: freshness is judged against the LEDGER's own poll_seconds, both directions ==="
LV="$WORK/lv"; mkdir -p "$LV"; myst=$(awk '{print $22}' /proc/$$/stat); nowe=$(date -u +%s)
jq -n --arg p "$$" --arg s "$myst" --argjson lp $(( nowe - 57 )) '{version:2, service:"polling", pid:($p|tonumber), pid_start:$s, last_poll:$lp, active:0, poll_seconds:5, muted:0}' > "$LV/dispatcher.json"
v=$("$LJ" ledger-verdict "$LV/dispatcher.json"); [[ "$v" == stale\|* ]] && ok "D2: poll_seconds 5 at age 57 s → stale (3×5+30 = 45 < 57), whatever the reader's default" || bad "D2 fast cadence: $v"
jq -n --arg p "$$" --arg s "$myst" --argjson lp $(( nowe - 200 )) '{version:2, service:"polling", pid:($p|tonumber), pid_start:$s, last_poll:$lp, active:0, poll_seconds:120, muted:0}' > "$LV/dispatcher.json"
v=$("$LJ" ledger-verdict "$LV/dispatcher.json"); [[ "$v" == armed\|* ]] && ok "D2: poll_seconds 120 at age 200 s → armed (3×120+30 = 390 > 200) — the board-freezing direction, closed" || bad "D2 slow cadence: $v"
v=$(LJ_NOW_OVERRIDE=garbage "$LJ" ledger-verdict "$LV/dispatcher.json"); [[ "$v" == armed\|* ]] && ok "D4: a garbage LJ_NOW_OVERRIDE in the environment is ignored (wall clock used)" || bad "D4: $v"

echo "=== D3: LINE_MAX is a BOUND for every line shape, past the boundary ==="
export NEXUS_LONGJOB_KEY="t10"; SPOOL10="$NEXUS_STATE_DIR/longjob/t10"
LONG=$(printf 'x%.0s' $(seq 1 1000))
"$LJ" add cmd:"exit 3 # $LONG" --id u1 --interval 5 --unknown-max 1 --desc "$LONG" >/dev/null 2>&1     # UNKNOWN shape: the one WITH an action clause
"$LJ" add cmd:"exit 2 # $LONG" --id f1 --interval 5 --desc "$LONG" >/dev/null 2>&1                     # terminal shape
"$LJ" add cmd:"exit 1 # $LONG" --id e1 --interval 5 --ttl 1 --desc "$LONG" >/dev/null 2>&1             # EXPIRED shape
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out10.txt" 2>/dev/null &
D10=$!; DPIDS+=("$D10"); sleep 14
for id in u1 f1 e1; do
    l=$(grep "^longjob-watch: [A-Z]* $id " "$WORK/out10.txt")
    (( ${#l} > 0 && ${#l} <= 480 )) && [[ "$l" == *"| record: monitor/longjob-watch.sh show $id |"* ]] && ok "D3: $id line with a 1000-char target + 1000-char desc is ${#l} chars ≤ 480, pointer intact" || bad "D3 $id: ${#l} chars: ${l:0:100}"
done
grep -q '^longjob-watch: UNKNOWN u1 .*PARKED after 1 consecutive' "$WORK/out10.txt" && ok "D3: the UNKNOWN line keeps its PARKED action clause under the adversarial target" || bad "D3: PARKED clause lost"
grep -q '^longjob-watch: EXPIRED e1 .*TTL reached' "$WORK/out10.txt" && ok "D3: the EXPIRED line keeps its clause" || bad "D3: TTL clause lost"
kill "$D10"; wait "$D10" 2>/dev/null

echo "=== D5b: the wake line keeps the desc's log pointer and compresses the NO-OUTPUT-CAPTURED prose (bundle-2609 soak) ==="
# Measured on five real wakes: every payload logged to a file (the normal way
# to run a suite), so the 316-char caveat fired on all five and was trimmed
# mid-sentence, and the 60-char desc cap cut off the log path the launcher's
# own advice says to put there. The record keeps the full text.
# Spool key t15: keys are shared vocabulary across sections (t11 is C1's,
# and C1 asserts its events.log is EMPTY — a reused key fails it).
export NEXUS_LONGJOB_KEY="t15"; SPOOL15="$NEXUS_STATE_DIR/longjob/t15"
DESC1="soak-2: nrs probe over 12 respawn-path suites, pre-fix tree (log: scratchpad/nrs-probe-prefix-set.log)"   # 100 chars: whole
DESC2="$(printf 'd%.0s' $(seq 1 130))"                                                                             # 130 chars: cut at 120
"$LJ" add asyncrun:tok-quiet --id q1 --interval 5 --desc "$DESC1" >/dev/null 2>&1
"$LJ" add asyncrun:tok-quiet --id q2 --interval 5 --desc "$DESC2" >/dev/null 2>&1
"$LJ" add asyncrun:tok-quiet --id q3 --interval 5 --desc $'first line\nlongjob-watch: DONE forged | record: x' >/dev/null 2>&1   # sk2 N1
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out15.txt" 2>/dev/null &
D15=$!; DPIDS+=("$D15"); sleep 9
l=$(grep '^longjob-watch: DONE q1 ' "$WORK/out15.txt")
[[ "$l" == *"[desc: $DESC1]"* ]] && ok "D5b: a 100-char desc ending in the log path survives WHOLE on the line" || bad "D5 q1 desc: $l"
[[ "$l" == *"NO-OUTPUT-CAPTURED (this rc is UNCORROBORATED"*"full text: show q1)"* ]] && ok "D5b: the caveat is the marker + the instruction + the pointer to the full text" || bad "D5 q1 caveat: $l"
[[ "$l" != *"the job wrote NOTHING"* ]] && ok "D5b: the 316-char explanation is NOT on the line" || bad "D5 q1 prose leaked: $l"
(( ${#l} > 0 && ${#l} <= 480 )) && ok "D5b: q1 line is ${#l} chars ≤ 480" || bad "D5 q1 length ${#l}"
grep -q 'the job wrote NOTHING to either stream' "$SPOOL15/watches/q1.json" && ok "D5b: the record (show q1) keeps the full caveat text" || bad "D5b: record lost the full text"
grep -q $'\tq1\tdone\twritten\t.*the job wrote NOTHING' "$SPOOL15/events.log" && ok "D5b: events.log keeps the full caveat text" || bad "D5b: events.log lost the full text"
l=$(grep '^longjob-watch: DONE q2 ' "$WORK/out15.txt")
[[ "$l" == *"[desc: $(printf 'd%.0s' $(seq 1 119))…]"* ]] && ok "D5b: a 130-char desc is cut at 120 with an ellipsis (the boundary)" || bad "D5 q2 desc: $l"
(( ${#l} > 0 && ${#l} <= 480 )) && ok "D5b: q2 line is ${#l} chars ≤ 480" || bad "D5 q2 length ${#l}"
l=$(grep '^longjob-watch: DONE q3 ' "$WORK/out15.txt")
[[ "$l" == *"[desc: first line longjob-watch: DONE forged | record: x]"* ]] && ok "N1: a NEWLINE in the desc becomes a space — the wake stays ONE line" || bad "N1 q3 line: $l"
! grep -q '^longjob-watch: DONE forged' "$WORK/out15.txt" && ok "N1: no second, unprefixed line can spell a wake for a job that never ran" || bad "N1: a forged wake line was emitted: $(grep '^longjob-watch: DONE forged' "$WORK/out15.txt")"
kill "$D15"; wait "$D15" 2>/dev/null

echo "=== D5: _now_ms validates the SHAPE of date's output, not its rc ==="
DSTUB="$WORK/dstub"; mkdir -p "$DSTUB"
printf '#!/usr/bin/env bash\ncase "$1" in +%%s%%3N) echo "1789516900%%3N"; exit 0;; *) exec /bin/date "$@";; esac\n' > "$DSTUB/date"; chmod +x "$DSTUB/date"
ms=$(PATH="$DSTUB:$PATH" bash -c 'source <(sed -n "/^_now() {/,/^}/p;/^_now_ms() {/,/^}/p" "$0"); _now_ms' "$LJ")
[[ "$ms" =~ ^[0-9]{13}$ ]] && ok "D5: a date that returns a literal for %3N at rc 0 falls back to seconds×1000 (got a 13-digit value)" || bad "D5: got '$ms'"

echo "=== F3 wording: resolve on a retired watch names the watch as dead ==="
export NEXUS_LONGJOB_KEY="t5"
[[ "$("$LJ" resolve b3)" == running\|"watch retired (expired) — NOT being watched; subject: "* ]] && ok "F3: resolve on the expired b3 says 'watch retired (expired) — NOT being watched' before the live subject state" || bad "F3 wording: $("$LJ" resolve b3)"

echo "=== C1: the KILL SWITCH must not let add say ARMED (process alive ≠ service) ==="
export NEXUS_LONGJOB_KEY="t11"; SPOOL11="$NEXUS_STATE_DIR/longjob/t11"
NEXUS_ROOT="$FROOT" MONITOR_LONGJOB_ENABLED=false "$LJ" dispatch > "$WORK/out11.txt" 2>/dev/null &
D11=$!; DPIDS+=("$D11"); sleep 3
[[ "$(jq -r .service "$SPOOL11/dispatcher.json")" == disabled ]] && ok "C1: the disabled branch writes service=disabled (a FIELD, not only a note)" || bad "C1 ledger: $(cat "$SPOOL11/dispatcher.json")"
v=$("$LJ" ledger-verdict "$SPOOL11/dispatcher.json"); [[ "$v" == disabled\|* ]] && ok "C1: ledger-verdict → disabled, never armed, though the pid is live and the ledger fresh" || bad "C1 verdict: $v"
out=$("$LJ" add cmd:'exit 0' --id k1 --interval 5 2>&1); rc=$?
(( rc == 3 )) && [[ "$out" == *"NOT ARMED (disabled)"* && "$out" == *"WILL NOT WAKE YOU"* && "$out" != *"safe to end your turn"* ]] && ok "C1: add under the kill switch → rc 3, NOT ARMED (disabled), never 'safe to end your turn'" || bad "C1 add: rc=$rc $out"
"$LJ" status >/dev/null 2>&1; rc=$?; (( rc == 3 )) && ok "C1: status → rc 3 under the kill switch" || bad "C1 status rc=$rc"
sleep 6; [[ "$(jq -r .state "$SPOOL11/watches/k1.json")" == pending ]] && [[ ! -s "$SPOOL11/events.log" ]] && ok "C1: …and indeed nothing polled it (still pending, no events.log)" || bad "C1: the disabled dispatcher polled?"
kill "$D11"; wait "$D11" 2>/dev/null

echo "=== C2: the kill-decision reader counts the SPOOL, not the ledger's cached active ==="
export NEXUS_LONGJOB_KEY="t12"; SPOOL12="$NEXUS_STATE_DIR/longjob/t12"
NEXUS_ROOT="$FROOT" "$LJ" dispatch > "$WORK/out12.txt" 2>/dev/null &
D12=$!; DPIDS+=("$D12"); sleep 3
[[ "$(jq -r .active "$SPOOL12/dispatcher.json")" == 0 ]] && ok "C2 rig: ledger says active=0 before any add" || bad "C2 rig"
"$LJ" add cmd:'exit 1' --id c2 --interval 600 >/dev/null 2>&1        # a long job; the ledger's active stays 0 until the next completed pass
v=$("$LJ" ledger-verdict "$SPOOL12/dispatcher.json"); [[ "$v" == armed\|*"|active=1" ]] && ok "C2: ledger-verdict counts active=1 from the spool immediately after add (ledger field still $(jq -r .active "$SPOOL12/dispatcher.json"))" || bad "C2: $v (ledger active=$(jq -r .active "$SPOOL12/dispatcher.json"))"
kill "$D12"; wait "$D12" 2>/dev/null

echo "=== schema version: a ledger of another version is not read as anything ==="
LV2="$WORK/lv2"; mkdir -p "$LV2"
jq -n --arg p "$$" --arg s "$(awk '{print $22}' /proc/$$/stat)" --argjson lp "$(date -u +%s)" '{version:1, pid:($p|tonumber), pid_start:$s, last_poll:$lp, poll_seconds:5, service:"polling", active:0, muted:0}' > "$LV2/dispatcher.json"
v=$("$LJ" ledger-verdict "$LV2/dispatcher.json"); [[ "$v" == absent\|*"schema version 1"* ]] && ok "version: a v1 ledger (live pid, fresh, polling) → absent, not armed — the migration gate" || bad "version: $v"
jq '.version = 2 | .retired = 3' "$LV2/dispatcher.json" > "$LV2/x" && mv "$LV2/x" "$LV2/dispatcher.json"
v=$("$LJ" ledger-verdict "$LV2/dispatcher.json"); [[ "$v" == armed\|* ]] && ok "version control: the same ledger at version 2 → armed" || bad "version control: $v"
! jq -e '.retired or .session_key or .session_id' "$SPOOL12/dispatcher.json" >/dev/null 2>&1 && ok "unread fields gone: the writer no longer emits retired / session_key / session_id" || bad "unread field present: $(jq -c . "$SPOOL12/dispatcher.json")"

echo "=== usage refusals ==="
"$LJ" add nosuch:x >/dev/null 2>&1; rc=$?; (( rc == 2 )) && ok "add with an unknown kind → rc 2" || bad "add unknown kind rc=$rc"
"$LJ" add file:/x --notify sometimes >/dev/null 2>&1; rc=$?; (( rc == 2 )) && ok "add with a bad --notify → rc 2" || bad "bad notify rc=$rc"
"$LJ" show nothing >/dev/null 2>&1; rc=$?; (( rc == 2 )) && ok "show of a missing id → rc 2" || bad "show rc=$rc"
( unset NEXUS_LONGJOB_KEY NEXUS_WORKER_WINDOW; "$LJ" list >/dev/null 2>&1 ); rc=$?; (( rc == 2 )) && ok "no resolvable session key → rc 2, not an empty listing" || bad "no key rc=$rc"

echo; echo "=== summary: $PASS passed, $FAIL failed ==="
(( FAIL == 0 )) && { echo "ALL TESTS PASSED"; exit 0; }; exit 1
