#!/usr/bin/env bash
# The harness-neutral agent-delivery contract — skills/nexus.agent-delivery,
# your-org/nexus-code#1049.
#
# WHAT IS ACTUALLY AT RISK, and therefore what these assertions are for.
#
# 1. THE GUARD KEY. `_idle_unconfirmed_paste_epoch` matches
#    `$3 == "paste-followup"` EXACTLY (_idle_probe.sh:1481). A transport that
#    writes any other token is SILENTLY exempt from the delivery guard — a
#    safety check switched off by a logging decision, inside the change whose
#    whole purpose is delivery robustness. Under a PLUGGABLE design this stops
#    being a wrapper detail: every future harness would have to remember a
#    magic string, and the one that forgets re-opens the hole. So send.sh owns
#    column 3 and A2 asserts NO flag and NO adapter can move it.
#
# 2. THE EXCLUSIVITY RULE. A fallback chain whose failure mode is DOUBLE
#    EXECUTION is strictly worse than the single transport it replaces —
#    duplicated instructions have produced duplicate comments and duplicate
#    commits on this board. So a fallback may fire ONLY on a PROVEN negative,
#    never on an absent confirmation. C1/C2 assert both directions, because a
#    chain that never advances is just as wrong as one that always does, and a
#    suite checking only "unknown halts" would pass against a patch that broke
#    fallback entirely.
#
# 3. STAMP BEFORE SEND, DIE IF THE STAMP FAILS (#665). stamp→send fails LOUD;
#    send→stamp fails SILENT, leaving unstamped input the watcher may sample.
#    B2 asserts the refusal actually refuses — that nothing goes out.
#
# 4. THE NONCE'S PLACEMENT IS LOAD-BEARING, NOT COSMETIC. The ledger's
#    compaction rebuilds surviving rows as EXACTLY FOUR COLUMNS
#    (_idle_probe.sh:1964-1967), so a nonce in a 5th column would be dropped
#    silently once the ledger passes 200 lines — only on a busy board, which is
#    both the hardest case to reproduce and the one where a lost delivery costs
#    most. That is #683's hazard and #676's remedy. G1 asserts the nonce
#    survives a real compaction; G2 asserts the 5th-column form would NOT, so
#    the rationale is demonstrated rather than asserted in a comment.
#
# Run: bash monitor/watcher/test-agent-delivery.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
SEND="$_repo_root/monitor/send.sh"

# The shared ledger, NOT a hand-rolled banner (your-org/nexus-code#805/#821).
# A hand-rolled summary prints from in-memory counters, which a subshell can
# silently discard — a FAIL that never reddens the suite. `th_summary_and_exit`
# reconciles from an append-only ledger that survives the subshell, so this
# suite's green certifies that something was actually asserted.
. "$(dirname "${BASH_SOURCE[0]}")/_test_helpers.sh"
PASS=0; FAIL=0
ck()  { assert_eq "$1" "$2" "$3"; }
ckc() { assert_contains "$1" "$2" "$3"; }

WORK=$(mktemp -d -t nexus-1049-delivery-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
ST="$WORK/state"; HD="$WORK/harness"; mkdir -p "$ST/windows" "$ST/user-prompt" "$HD"
W=worker7
printf '{"window":"%s","harness":"fake"}\n' "$W" > "$ST/windows/$W.json"

# A scripted adapter. FAKE_* drive its answers, so the chain's decisions are
# exercised without tmux, a peer, or a harness of any kind.
cat > "$HD/fake.sh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
verb="${1:-}"; shift || true
case "$verb" in
transports)
    # QUOTED: the rows are TAB-separated, and an unquoted expansion word-splits
    # on tab, turning one 4-field row into four 1-field rows. The chain then
    # read every FIELD as a transport name with an empty `invoke` and skipped
    # them all — a fixture bug that produced a plausible, entirely wrong verdict.
    if [[ -n "${FAKE_TRANSPORTS:-}" ]]; then printf '%s\n' "$FAKE_TRANSPORTS"
    else
        # DEFAULT fixture, deliberately faithful in two ways: t1 declares NO
        # `stamps` field (so the fail-closed default is exercised by every
        # test that does not override), and an invoke=agent transport is
        # present, because that is the real shape of a Claude Code peer.
        printf 't1\tshell\tsubmit-stamp\n'
        printf 'cc-sendmessage\tagent\tsubmit-stamp\tcaller\n'
    fi ;;
liveness)   n="${2:-}"; eval "rc=\${FAKE_LIVE_${n//-/_}:-0}"; exit "$rc" ;;
send)       n="${2:-}"; printf '%s %s\n' "$n" "${4:-}" >> "${FAKE_SENDLOG:?}"
            eval "rc=\${FAKE_SEND_${n//-/_}:-0}"; exit "$rc" ;;
esac
exit 2
FAKE
chmod +x "$HD/fake.sh"

run() { NEXUS_STATE_DIR="$ST" NEXUS_HARNESS_DIR="$HD" bash "$SEND" "$@" 2>&1; }
SENDLOG="$WORK/sent.log"; : > "$SENDLOG"; export FAKE_SENDLOG="$SENDLOG"
T2=$'t1\tshell\tsubmit-stamp\nt2\tshell\tsubmit-stamp'

# ===========================================================================
echo "=== PART A: the guard key is OWNED by send.sh and cannot be moved ==="
# ===========================================================================
: > "$ST/machine-input.tsv"
out=$(run "$W" --stamp-only --transport t1 --message hi)
col3=$(awk -F'\t' -v w="$W" '$1==w{print $3; exit}' "$ST/machine-input.tsv")
ck "A1 a stamped send writes the guard key in column 3" "$col3" "paste-followup"
# The detector's OWN selector, run verbatim against the ledger we just wrote.
seen=$(awk -F'\t' -v w="$W" '$1==w && $3=="paste-followup" && $2 ~ /^[0-9]+$/ {n++} END{print n+0}' "$ST/machine-input.tsv")
ck "A2 the paste-unconfirmed selector SEES the row" "$seen" "1"
# No flag may relabel it — `--transport` is descriptive, never selective.
out=$(run "$W" --stamp-only --transport cc-sendmessage --message hi)
bad=$(awk -F'\t' -v w="$W" '$3!="paste-followup"{n++} END{print n+0}' "$ST/machine-input.tsv")
ck "A3 --transport cannot relabel column 3 (no exempt rows)" "$bad" "0"
tr_side=$(cat "$ST"/paste-verdicts/"$W".* 2>/dev/null | awk -F= '$1=="transport"{print $2}' | sort -u | tr '\n' ',')
ckc "A4 the transport identity rides the SIDECAR instead" "$tr_side" "cc-sendmessage"

# ===========================================================================
echo "=== PART B: stamp BEFORE send, and refuse when the stamp fails ==="
# ===========================================================================
: > "$SENDLOG"; : > "$ST/machine-input.tsv"
out=$(run "$W" --message hi); rc=$?
ck "B1 a normal send stamps and delivers" "$rc" "0"
rows=$(wc -l < "$ST/machine-input.tsv" | tr -d ' ')
# WHO STAMPS. The fake adapter declares no `stamps` field, so it must default
# to `caller` and send.sh must stamp — a missing declaration may never be the
# permissive arm, or a new adapter is silently exempt from the guard, which is
# the whole hole. Exactly ONE row: two would mean send.sh and the transport
# both stamped, and the watcher takes the max epoch per window, so the second
# would move the attribution instant off the moment the send began.
ck "B2 a transport declaring NOTHING is stamped anyway (fail-closed)" "$rows" "1"
ck "B2b …with the guard key" \
   "$(awk -F'\t' -v w="$W" '$1==w{print $3; exit}' "$ST/machine-input.tsv")" "paste-followup"
# stamps=self — the transport stamps for itself (paste-followup.sh does), so
# send.sh must NOT stamp again.
: > "$ST/machine-input.tsv"; : > "$SENDLOG"
out=$(FAKE_TRANSPORTS=$'t1\tshell\tsubmit-stamp\tself' run "$W" --message hi)
ck "B2c a stamps=self transport is NOT double-stamped" \
   "$(wc -l < "$ST/machine-input.tsv" | tr -d ' ')" "0"
ck "B2d …but it WAS sent" "$(grep -c '^t1 ' "$SENDLOG")" "1"
: > "$SENDLOG"
chmod 000 "$ST/machine-input.tsv" 2>/dev/null
out=$(run "$W" --stamp-only --transport t1 --message hi); rc=$?
chmod 644 "$ST/machine-input.tsv" 2>/dev/null
ck "B3 an unstampable ledger REFUSES (rc 1)" "$rc" "1"
ckc "B4 …and says why" "$out" "refusing to send unstamped"
ck "B5 …and NOTHING was sent" "$(wc -l < "$SENDLOG" | tr -d ' ')" "0"

# ===========================================================================
echo "=== PART C: the EXCLUSIVITY RULE, both directions ==="
# ===========================================================================
# C1 — `unknown` (rc 3) MUST halt. This is the double-delivery guard: the
# instruction may yet land, so a second transport would execute it twice.
: > "$SENDLOG"
out=$(FAKE_TRANSPORTS="$T2" FAKE_SEND_t1=3 run "$W" --message hi); rc=$?
ck "C1a an UNKNOWN first transport halts the chain (rc 3)" "$rc" "3"
ck "C1b …and the second transport was NEVER attempted" "$(grep -c '^t2 ' "$SENDLOG")" "0"
ckc "C1c …and it names the rule" "$out" "PROVEN negative"
# C2 — an ESTABLISHED negative (rc 4) MUST advance. A chain that never falls
# back is exactly as broken as one that always does.
: > "$SENDLOG"
out=$(FAKE_TRANSPORTS="$T2" FAKE_SEND_t1=4 FAKE_SEND_t2=0 run "$W" --message hi); rc=$?
ck "C2a an ESTABLISHED negative advances to the next transport (rc 0)" "$rc" "0"
ck "C2b …and t2 really was attempted" "$(grep -c '^t2 ' "$SENDLOG")" "1"
ck "C2c …and both carried the SAME nonce (one logical delivery)" \
   "$(awk '{print $2}' "$SENDLOG" | sort -u | wc -l | tr -d ' ')" "1"
# C3 — a PROVEN-dead peer is an established negative too, and licenses advancing
# WITHOUT a send attempt. This is the arm that makes an invoke=agent transport's
# liveness probe worth having (#1049: success:true from a SIGKILLed peer).
: > "$SENDLOG"
out=$(FAKE_TRANSPORTS="$T2" FAKE_LIVE_t1=1 FAKE_SEND_t2=0 run "$W" --message hi); rc=$?
ck "C3a a PROVABLY dead transport is skipped and the chain advances" "$rc" "0"
ck "C3b …and t1 was never sent to" "$(grep -c '^t1 ' "$SENDLOG")" "0"
# C4 — liveness `unknown` (rc 2) must NOT be read as dead: it must still try.
: > "$SENDLOG"
out=$(FAKE_TRANSPORTS="$T2" FAKE_LIVE_t1=2 FAKE_SEND_t1=0 run "$W" --message hi); rc=$?
ck "C4 liveness=unknown still ATTEMPTS the transport" "$(grep -c '^t1 ' "$SENDLOG")" "1"

# ===========================================================================
echo "=== PART D: an invoke=agent transport is skipped LOUDLY, never claimed ==="
# ===========================================================================
: > "$SENDLOG"
AG=$'cc\tagent\tsubmit-stamp\nt2\tshell\tsubmit-stamp'
out=$(FAKE_TRANSPORTS="$AG" FAKE_SEND_t2=0 run "$W" --message hi); rc=$?
ck "D1 the chain still delivers via the shell transport" "$rc" "0"
ck "D2 the agent transport was NOT invoked" "$(grep -c '^cc ' "$SENDLOG")" "0"
ckc "D3 …and the skip is stated, not silent" "$out" "invoke=agent"
# D4 — a chain of ONLY agent transports must refuse, not report success.
: > "$SENDLOG"
out=$(FAKE_TRANSPORTS=$'cc\tagent\tnone' run "$W" --message hi); rc=$?
ck "D4 an all-agent chain refuses (rc 1), never claims delivery" "$rc" "1"
ckc "D5 …and says nothing was sent" "$out" "Nothing was sent"

# ===========================================================================
echo "=== PART E: --stamp-only stamps and sends NOTHING ==="
# ===========================================================================
: > "$SENDLOG"
out=$(run "$W" --stamp-only --transport cc-sendmessage --message hi); rc=$?
ck "E1 --stamp-only succeeds" "$rc" "0"
ck "E2 …and no transport ran" "$(wc -l < "$SENDLOG" | tr -d ' ')" "0"
ckc "E3 …and it emits the nonce for the caller to carry" "$out" "nonce="
ck "E4 --stamp-only without --transport is refused" \
   "$(run "$W" --stamp-only --message hi >/dev/null 2>&1; echo $?)" "1"

# ===========================================================================
echo "=== PART F: the receipt, via --check ==="
# ===========================================================================
# A FAITHFUL fixture: the real shape this exists for is a Claude Code peer
# whose preferred transport is invoke=agent (SendMessage) with tmux-paste
# behind it — not a single-transport board.
FTR=$'cc-sendmessage\tagent\tsubmit-stamp\tcaller\nt2\tshell\tsubmit-stamp\tself'
export FAKE_TRANSPORTS="$FTR"
: > "$ST/machine-input.tsv"
# An UNDECLARED transport must be refused, not stamped into a dead end.
ck "F0 --stamp-only refuses a transport the harness does not declare" \
   "$(run "$W" --stamp-only --transport no-such --message hi >/dev/null 2>&1; echo $?)" "1"
out=$(run "$W" --stamp-only --transport cc-sendmessage --message hi)
NONCE=$(printf '%s\n' "$out" | awk -F= '$1=="nonce"{print $2}')
EPOCH=$(printf '%s\n' "$out" | awk -F= '$1=="epoch"{print $2}')
ck "F1 a nonce was issued" "$([[ -n "$NONCE" ]] && echo yes || echo no)" "yes"
# No receipt yet, peer not provably dead → UNKNOWN, and it must NOT license a fallback.
rc=$(FAKE_LIVE_cc_sendmessage=2 run "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)
ck "F2 no receipt + peer not proven dead ⇒ unknown (rc 3)" "$rc" "3"
# The receipt lands: the nexus-owned submit-stamp advances past the send.
printf '%s\t%s\n' "$(( EPOCH / 1000000 + 5 ))" "sess-1" > "$ST/user-prompt/$W"
rc=$(run "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)
ck "F3 an advanced submit-stamp ⇒ delivered (rc 0)" "$rc" "0"
# A STALE stamp (older than the send) must NOT be read as a receipt.
printf '%s\t%s\n' "$(( EPOCH / 1000000 - 60 ))" "sess-1" > "$ST/user-prompt/$W"
rc=$(FAKE_LIVE_cc_sendmessage=2 run "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)
ck "F4 a stamp OLDER than the send is not a receipt (rc 3)" "$rc" "3"
# Proven-dead peer + no receipt ⇒ ESTABLISHED negative, fallback licensed.
rc=$(FAKE_LIVE_cc_sendmessage=1 run "$W" --check --nonce "$NONCE" >/dev/null 2>&1; echo $?)
ck "F5 proven-dead peer + no receipt ⇒ established negative (rc 4)" "$rc" "4"

unset FAKE_TRANSPORTS
# ===========================================================================
echo "=== PART G: the nonce survives ledger COMPACTION (placement rationale) ==="
# ===========================================================================
# G1 — replay the real compaction awk from _idle_probe.sh:1964-1967 over a
# >200-row ledger and assert the sidecar's nonce is still resolvable. This is
# the property that justifies the sidecar over a 5th column.
: > "$ST/machine-input.tsv"
out=$(run "$W" --stamp-only --transport cc-sendmessage --message hi)
N2=$(printf '%s\n' "$out" | awk -F= '$1=="nonce"{print $2}')
for i in $(seq 1 210); do printf 'filler%s\t%s\tpaste-followup\t\n' "$i" "$(( 1700000000000000 + i ))"; done \
    >> "$ST/machine-input.tsv"
awk -F'\t' -v OFS='\t' \
    '$2 ~ /^[0-9]+$/ && ($2 + 0) > m[$1] { m[$1] = $2 + 0; s[$1] = $3; a[$1] = $4 }
     END { for (w in m) print w, m[w], s[w], a[w] }' \
    "$ST/machine-input.tsv" > "$ST/mi.compact" && mv "$ST/mi.compact" "$ST/machine-input.tsv"
found=$(grep -lxF "nonce=$N2" "$ST"/paste-verdicts/"$W".* 2>/dev/null | wc -l | tr -d ' ')
ck "G1 the nonce survives compaction (it is in the sidecar)" "$found" "1"
ck "G2 …and the guard key survived too" \
   "$(awk -F'\t' -v w="$W" '$1==w{print $3; exit}' "$ST/machine-input.tsv")" "paste-followup"
# G3 — demonstrate the counterfactual: a 5th column does NOT survive. This is
# why the placement is what it is, shown rather than asserted.
printf 'demo\t1700000000000001\tpaste-followup\t\tNONCE-IN-COL5\n' > "$ST/mi5.tsv"
awk -F'\t' -v OFS='\t' \
    '$2 ~ /^[0-9]+$/ && ($2 + 0) > m[$1] { m[$1] = $2 + 0; s[$1] = $3; a[$1] = $4 }
     END { for (w in m) print w, m[w], s[w], a[w] }' "$ST/mi5.tsv" > "$ST/mi5.out"
ck "G3 a 5th column is DROPPED by compaction (why the nonce is a sidecar)" \
   "$(grep -c 'NONCE-IN-COL5' "$ST/mi5.out" | tr -d ' ')" "0"

# ===========================================================================
echo "=== PART H: the claude-code liveness probe (the REAL adapter) ==="
# ===========================================================================
# This is the one harness-specific mechanism the fallback leans on, so it is
# tested against the real adapter rather than a fake. It is what converts
# #1049's `success:true` from a SIGKILLed peer (unknown, ~3 min after the
# kill) into an ESTABLISHED negative — and an established negative is the ONLY
# thing that licenses a fallback. A probe that answered 1 when it should have
# answered 2 would manufacture exactly the double delivery this design exists
# to prevent, so the UNKNOWN arms below matter as much as the DEAD ones.
CC="$_repo_root/monitor/harness/claude-code.sh"
CCH="$WORK/cchome"; mkdir -p "$CCH/sessions"
reg() { printf '%s' "$2" > "$CCH/sessions/$1.json"; }
probe() { CLAUDE_CONFIG_DIR="$CCH" bash "$CC" liveness "$1" cc-sendmessage >/dev/null 2>&1; echo $?; }

# A pid that cannot exist (above this host's pid_max).
DEADPID=$(( $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768) + 1 ))
reg dead "{\"pid\":$DEADPID,\"name\":\"w-dead\",\"messagingSocketPath\":\"$WORK/nope.sock\"}"
ck "H1 a dead pid ⇒ PROVABLY unreachable (rc 1)" "$(probe w-dead)" "1"

# Live pid, socket declared but absent: nothing is listening ⇒ proven negative.
reg nosock "{\"pid\":$$,\"name\":\"w-nosock\",\"messagingSocketPath\":\"$WORK/absent.sock\"}"
ck "H2 a live pid with no listening socket ⇒ PROVABLY unreachable (rc 1)" "$(probe w-nosock)" "1"

# No socket declared at all: we cannot answer. MUST be unknown, never dead —
# "I could not look" and "I looked and it is gone" are opposite recoveries.
reg nopath "{\"pid\":$$,\"name\":\"w-nopath\"}"
ck "H3 no socket path declared ⇒ unknown (rc 2), NOT dead" "$(probe w-nopath)" "2"

# No registry entry for the window at all ⇒ unknown.
ck "H4 an unknown window ⇒ unknown (rc 2), NOT dead" "$(probe w-absent)" "2"

# A REAL listening unix socket ⇒ reachable. Proves H1/H2 are not just "this
# probe always says 1" — without this arm every DEAD assertion above would
# pass against a probe hard-wired to fail.
SOCK="$WORK/live.sock"
python3 -c "
import socket,sys,os
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.bind('$SOCK'); s.listen(4)
sys.stdout.write('up'); sys.stdout.flush()
import time; time.sleep(25)
" > "$WORK/live.ready" 2>/dev/null &
LIVEPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$SOCK" ]] && break; sleep 0.3; done
ck "H5 the test socket really bound (else H1/H2 prove nothing)" \
   "$([[ -S "$SOCK" ]] && echo yes || echo no)" "yes"
reg live "{\"pid\":$$,\"name\":\"w-live\",\"messagingSocketPath\":\"$SOCK\"}"
ck "H5b a real listening socket ⇒ reachable (rc 0)" "$(probe w-live)" "0"
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null

# ===========================================================================
echo "=== PART I: registration / discovery, and its degradation ==="
# ===========================================================================
# skills/nexus.agent-delivery §6/§7. Discovery reads the NEXUS-owned descriptor
# (monitor/.state/windows/<w>.json), never a harness's private registry —
# reading ~/.claude to decide WHICH harness is running is circular, and would
# make Claude Code the only harness that can ever be discovered.
ln -sf "$_repo_root/monitor/harness/generic-tmux.sh" "$HD/generic-tmux.sh"
harness_of() { run "$1" --dry-run 2>&1 | sed -n 's/^window=.*harness=\([^ ]*\).*/\1/p'; }

printf '{"window":"w-cc","harness":"claude-code"}\n' > "$ST/windows/w-cc.json"
ln -sf "$_repo_root/monitor/harness/claude-code.sh" "$HD/claude-code.sh"
ck "I1 a declared harness selects its adapter" "$(harness_of w-cc)" "claude-code"

# NO harness field: degrade to generic-tmux. An agent whose launcher never
# learned to record a harness is still FIRST-CLASS — it is addressed the same
# way and stamped the same way; only what may be CONCLUDED narrows (§7).
printf '{"window":"w-bare"}\n' > "$ST/windows/w-bare.json"
ck "I2 a descriptor with no harness degrades to generic-tmux" "$(harness_of w-bare)" "generic-tmux"
# No descriptor at all: same floor, not an error.
ck "I3 no descriptor at all also degrades to generic-tmux" "$(harness_of w-none)" "generic-tmux"

# An UNKNOWN harness must REFUSE, not silently fall back to tmux. Falling back
# would address a foreign agent through a transport nobody said reaches it —
# a delivery claim about a mechanism that was never declared.
printf '{"window":"w-weird","harness":"acme-agent"}\n' > "$ST/windows/w-weird.json"
ck "I4 an UNDECLARED harness refuses (rc 1), never falls back silently" \
   "$(run w-weird --dry-run >/dev/null 2>&1; echo $?)" "1"

# The real spawn path records the field, or I1 is unreachable in production.
#
# THIS ASSERTION USED TO BE A SOURCE GREP — `grep -c '"harness":"claude-code"'
# monitor/spawn-worker.sh == 1` — and that is precisely how your-org/nexus-code#1085
# survived it. `_write_provenance_record` has two writers, and the field was
# spelled ONLY in the `printf` fallback taken when `jq` is absent (never, on
# this host). The grep found that dead literal and reported the producer
# conformant while 0 of 1,278 live descriptors declared a harness, so I1 was
# unreachable in production for exactly as long as this assertion was green.
#
# A probe that reads the producer's SOURCE cannot distinguish "writes the
# field" from "mentions the field". So it now consumes a record the real
# function PRODUCED. The record's name is discovered by globbing rather than
# computed, to avoid re-implementing `wk_encode` here.
#
# Scope: this pins the production (`jq`) arm only — enough to keep I1 honest.
# The branch differential, the jq-masked fallback leg and the potency mutants
# live in monitor/watcher/test-provenance-harness-field.sh.
_i5_root="$WORK/i5-prov"; mkdir -p "$_i5_root/windows"
{
    printf 'set -uo pipefail\n'
    awk '/^_write_provenance_record\(\)/,/^}$/' "$_repo_root/monitor/spawn-worker.sh"
    printf 'wk_encode() { printf %%s "$1"; }\n'
    printf 'STATE_DIR=%q\n' "$_i5_root"
    printf '_write_provenance_record %q "w-i5" "sid" "task" "/wd" "/pf" "t"\n' "$_i5_root"
} > "$WORK/i5-produce.sh"
bash "$WORK/i5-produce.sh" >/dev/null 2>&1
# Glob, not `ls | head -1`: a `| head` is an early-exit reader, and under this
# suite's `pipefail` the writer's EPIPE can invert the pipeline's status
# (your-org/nexus-code#622). The fresh root holds exactly one record.
_i5_rec=""
for _i5_f in "$_i5_root/windows/"*.json; do
    [[ -f "$_i5_f" ]] && { _i5_rec="$_i5_f"; break; }
done
ck "I5 the record spawn-worker ACTUALLY WRITES declares a harness" \
   "$(NEXUS_F="${_i5_rec:-/nonexistent}" python3 -c '
import json, os, sys
try: d = json.load(open(os.environ["NEXUS_F"]))
except Exception: print("<UNPARSEABLE>"); sys.exit(0)
print(d.get("harness", "<ABSENT>"))' 2>/dev/null)" "claude-code"

# ===========================================================================
echo "=== PART J: --check is scoped to the CARRYING transport; receipt=none is enforced ==="
# ===========================================================================
# BOTH ARMS HERE EXIST BECAUSE THE SUITE WAS BLIND TO THEM. The `#1049` skeptic
# constructed a real double delivery against code that scored 51/51, and both
# of its candidate fixes ALSO scored 51/51 — i.e. the suite could not tell fixed
# code from broken code on either path. An assertion added beside a fix that
# passes BEFORE the fix is not a test of that fix.
#
# J1 IS THE DEFECT ITSELF. `--check` used to probe EVERY declared transport and
# return `not-delivered` on the first provably-dead one — INCLUDING a transport
# that never carried the send. The sidecar records `transport=`; `--check`
# discarded it. So: carrier ALIVE, unused sibling dead, no receipt yet ⇒ the
# tool said "A fallback is licensed" and the caller sent a second copy while the
# first was still in flight. A FALSE ESTABLISHED NEGATIVE — the single thing the
# exclusivity rule exists to forbid.
#
# The rule was never wrong and was never breached on the send path. The hazard
# came through a different door: a helper answering a question about
# "transports" when the question that matters is about THE transport that
# carried THIS message. A guard scoped to the wrong noun.
#
# F5 passes either way, which is exactly why it did not catch this: its dead
# transport IS the carrier, so the scoping is invisible to it. J1 differs from
# F5 in one variable — whether the dead transport is the one that carried.
FTJ=$'carrier\tshell\tsubmit-stamp\tcaller\nsibling\tshell\tsubmit-stamp\tcaller'
export FAKE_TRANSPORTS="$FTJ"
: > "$ST/machine-input.tsv"; rm -f "$ST"/paste-verdicts/"$W".* 2>/dev/null
: > "$ST/user-prompt/$W"
outJ=$(run "$W" --stamp-only --transport carrier --message hi)
NJ=$(printf '%s\n' "$outJ" | awk -F= '$1=="nonce"{print $2}')
# carrier LIVE (0), the sibling that carried NOTHING is PROVABLY dead (1).
ck "J1 carrier alive + an unused sibling dead ⇒ unknown (3), NOT a licensed fallback" \
   "$(FAKE_LIVE_carrier=0 FAKE_LIVE_sibling=1 run "$W" --check --nonce "$NJ" >/dev/null 2>&1; echo $?)" "3"
# The positive control: when the CARRIER itself is proven dead, rc 4 must still
# be reached. Without this, "always return 3" would pass J1 and destroy the
# fallback entirely — the same both-directions discipline as Part C.
ck "J2 the CARRIER proven dead ⇒ established negative (4) — fallback still works" \
   "$(FAKE_LIVE_carrier=1 FAKE_LIVE_sibling=0 run "$W" --check --nonce "$NJ" >/dev/null 2>&1; echo $?)" "4"
# FAIL CLOSED: a sidecar with no `transport=` must not re-open the all-probe
# path. Unknown carrier ⇒ unknown verdict, never a licensed fallback.
sc=""
while IFS= read -r _f; do [[ -n "$sc" ]] || sc="$_f"; done \
    < <(command grep -lxF "nonce=$NJ" "$ST"/paste-verdicts/"$W".* 2>/dev/null)
command grep -v '^transport=' "$sc" > "$sc.tmp" && mv "$sc.tmp" "$sc"
outJ3c=$(run "$W" --stamp-only --transport carrier --message hi)
NJ2=$(printf '%s\n' "$outJ3c" | awk -F= '$1=="nonce"{print $2}')
outJ3=$(FAKE_LIVE_=1 FAKE_LIVE_carrier=0 FAKE_LIVE_sibling=1 run "$W" --check --nonce "$NJ" 2>&1; echo "rc=$?")
ck "J3 a sidecar with NO recorded carrier fails CLOSED to unknown (3)" \
   "$(printf '%s\n' "$outJ3" | sed -n 's/^rc=//p')" "3"
ckc "J3b …and says WHY, naming the unrecorded carrier as the reason" \
    "$outJ3" "does not record which transport carried"
# J3c — an explicit --transport may NAME the carrier, never REPLACE it. Pointing
# --check at a transport that did not carry the send is the same wrong-noun
# defect one door along, chosen by hand instead of by a loop.
ck "J3c --check REFUSES a --transport that is not the recorded carrier" \
   "$(run "$W" --check --nonce "$NJ2" --transport sibling >/dev/null 2>&1; echo $?)" "1"
# J3d — the OTHER half of the same defect, and the one J3c does not cover: when
# NO carrier was recorded, a caller-named --transport was accepted UNCHECKED and
# drove the verdict, so a dead sibling yielded rc 4 with a diagnostic asserting
# "the CARRYING transport sibling" — about a transport nothing established had
# carried anything. J3c covers DISAGREEMENT; this covers UNVERIFIED ASSERTION,
# which is the same defect with nothing to disagree with. `--transport` is a
# caller's claim, never evidence.
ck "J3d a caller-named --transport with NO recorded carrier stays unknown (3), never 4" \
   "$(FAKE_LIVE_=1 FAKE_LIVE_carrier=0 FAKE_LIVE_sibling=1 run "$W" --check --nonce "$NJ" --transport sibling >/dev/null 2>&1; echo $?)" "3"

# J4 — `receipt: none` is DECLARED, plumbed and printed, but never reached the
# verdict, so a shell transport that can produce no evidence of arrival and
# returns 0 was reported `delivered`. That contradicts this contract's own text
# twice over (§5 "delivered = a receipt was observed"; §7 "sends to it report
# `unknown`") and is a delivery claim with no evidence — the failure class
# `#1049` was opened for. Latent for the shipped harness, live the moment a
# SECOND harness exists, i.e. exactly when the standard starts being used.
: > "$SENDLOG"
ck "J4 a shell transport declaring receipt=none cannot report delivered" \
   "$(FAKE_TRANSPORTS=$'nr\tshell\tnone\tcaller' FAKE_SEND_nr=0 run "$W" --message hi >/dev/null 2>&1; echo $?)" "3"
ck "J4b …and it really was sent (the downgrade is about the CLAIM, not the send)" \
   "$(command grep -c '^nr ' "$SENDLOG" | tr -d ' ')" "1"
# The control that stops J4 becoming a blanket downgrade of every send.
ck "J5 CONTROL a transport declaring a real receipt still reports delivered (0)" \
   "$(FAKE_TRANSPORTS=$'ok\tshell\tsubmit-stamp\tcaller' FAKE_SEND_ok=0 run "$W" --message hi >/dev/null 2>&1; echo $?)" "0"
unset FAKE_TRANSPORTS

# ── the assertion COUNT, compared EXACTLY (your-org/nexus-code#821 axis B) ──
# A suite can lose assertions silently — an arm that stops running still
# reports a clean green. A FLOOR does not catch that; only an exact comparison
# does. Update this number deliberately when adding an arm; a mismatch is a
# red, not a warning.
EXPECTED_ASSERTIONS=59
_run_total=$(( PASS + FAIL ))
assert_eq "assertion count is exactly what this suite declares" "$_run_total" "$EXPECTED_ASSERTIONS"

th_summary_and_exit
