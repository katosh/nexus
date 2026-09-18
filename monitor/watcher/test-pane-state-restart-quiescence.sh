#!/usr/bin/env bash
# test-pane-state-restart-quiescence.sh — `bg_quiesce`: which background-shell
# roots hold NO in-flight work, so the cc-update restart may kill the
# orchestrator between turns.
#
# THE DEFECT. `cc-auto-update-apply.sh restart-orchestrator` waits up to 900 s
# for a turn boundary, then force-kills. The #514 fix made `working-background`
# a boundary only in its Monitor-handle flavour, i.e. only when the pane-state
# line carries NO `bg_cpu=`, on the assumption that a Monitor lives inside
# claude's node process. On current Claude Code builds a `command` Monitor runs
# as a REAL zsh child of claude, so the orchestrator's mandated
# watcher-supervisor loop is counted as a background shell and every line
# carries `bg_cpu=`. Measured 2026-09-11 (2.1.268): 44 of 45 samples between
# turns read `working-background … bg_shells=1 bg_reliable=1 bg_cpu=… bg_infra=0
# bg_cmd=zsh:until_…/watcher-supe…`, and the ledger has no
# `safe-bumped-restarted` row, ever.
#
# THE FIX UNDER TEST. The process-tree walk classifies each root: quiescent iff
# its WHOLE eval'd payload is a nexus protocol wait loop
# (`_pane_payload_is_pure_wait`) AND nothing under it is anything but a shell or
# `sleep`, or it is #1208-stale. The restart gate accepts a shell-driven
# `working-background` only when `bg_reliable=1` and `bg_quiesce >= bg_shells`.
#
# DIFFERENTIAL DESIGN, as in test-pane-state-asyncrun-liveness.sh. L1 pins the
# POSITIVE against a real process tree. L2, L3 and L4 each differ from it by ONE
# variable and must give the opposite answer, so a walk that silently found
# nothing cannot pass them vacuously: L1 would go red first.
#
# Cases:
#   U*   _pane_payload_is_pure_wait accept/reject table
#   P*   _pane_root_payload: wrapper peel, quote unescape, no-wrapper refusal
#   L1   POSITIVE: supervisor-shaped root, only `sleep` beneath → shells=1 quiesce=1
#   L2   L1 plus a second root doing real work → shells=2 quiesce=1 (and G2 refuses)
#   L3   L1 but the wait command has a non-shell/non-sleep child → quiesce=0
#   L4   L1 but work is QUEUED after the loop (not yet started) → quiesce=0
#   E1   end to end: pane-state.sh on the L1 tree emits `bg_quiesce=1`
#   G*   the restart gate predicate, lifted from cc-auto-update-apply.sh
#
# Run: bash monitor/watcher/test-pane-state-restart-quiescence.sh

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
# The files this suite READS to reach its verdict. Declared once, as data, and
# both the paths below and the `--population` answer come from these lines, so
# the two cannot drift apart (your-org/nexus-code#803's rule for an implementor).
_Q_HELPER_REL=monitor/pane-state.sh
_Q_APPLY_REL=monitor/cc-auto-update-apply.sh
_Q_FIXTURE_REL=monitor/watcher/fixtures/idle-empty-synthetic.ansi
_Q_TESTLIB_REL=monitor/watcher/_test_helpers.sh
HELPER="$_repo_root/$_Q_HELPER_REL"
APPLY="$_repo_root/$_Q_APPLY_REL"

# --- the `--population` protocol (your-org/nexus-code#803) -----------------
# DECLARED rather than listed in suite-declarations.manifest: the whole point of
# this suite is to go red when pane-state.sh or the restart gate changes, and a
# non-declaring suite is invisible to `ng guards-for-diff` exactly when such an
# edit is being pushed.
# shellcheck disable=SC1091
. "$_test_dir/../_guard_population.sh"
gp_population() {
    printf '%s\n' "$_Q_HELPER_REL" "$_Q_APPLY_REL" "$_Q_FIXTURE_REL" "$_Q_TESTLIB_REL"
}
gp_handle "$@"

# shellcheck disable=SC1091
. "$_repo_root/$_Q_TESTLIB_REL"
# ASSERTION CENSUS (your-org/nexus-code#807): counted BEFORE the census
# assertion itself. Adopted from the start rather than opted out of in
# summary-honesty.manifest. An aborted plant never reaches it; th_abort is red.
EXPECTED_ASSERTIONS=61

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 ($2)"; else fail "$1 — got '$2' want '$3'"; fi; }

[[ -x "$HELPER" ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }
[[ -r "$APPLY"  ]] || { echo "apply script not readable: $APPLY" >&2; exit 1; }

WORK=$(mktemp -d -t nexus-quiesce-XXXXXX)
# Only ever signals process GROUPS this suite created with `setsid` and whose
# leader pid it recorded at launch. Never a pattern: sibling agents' argv holds
# these very strings (your-org/nexus-code#1073, #851). Every planted loop also
# expires on its own (the tick stub stops the loop at a deadline), so a failed
# kill self-clears rather than leaking.
SPAWNED=()
cleanup() {
    local p
    for p in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        kill -TERM -- "-$p" 2>/dev/null
        kill -TERM "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Extract the units. Sourcing pane-state.sh whole would execute it. THE
# EXTRACTION IS ITSELF A GUARD: a renamed function would otherwise make every
# case below fail with "command not found", which reads as a defect in the code
# under test rather than as a broken instrument.
UNITS="$WORK/units.sh"
: > "$UNITS"
FNS=(_pane_comm_is_shell _pane_ticks_to_epoch _pane_cmd_is_protocol_wait
     _pane_cmd_descriptor _pane_asyncrun_refs _pane_asyncrun_ref_is_died
     _pane_root_payload _pane_payload_is_pure_wait _pane_background_shells)
for fn in "${FNS[@]}"; do
    sed -n "/^${fn}() {/,/^}/p" "$HELPER" >> "$UNITS"
    printf '\n' >> "$UNITS"
done
GATE_FNS=(_restart_eligible _restart_line_field _restart_bg_all_quiescent)
for fn in "${GATE_FNS[@]}"; do
    sed -n "/^${fn}() {/,/^}/p" "$APPLY" >> "$UNITS"
    printf '\n' >> "$UNITS"
done
_PS_SCRIPT_DIR="$_repo_root/monitor"
# shellcheck disable=SC1090
source "$UNITS" || { echo "could not source extracted units" >&2; exit 1; }
for fn in "${FNS[@]}" "${GATE_FNS[@]}"; do
    if ! declare -F "$fn" >/dev/null; then
        echo "EXTRACTION GUARD FAILED: $fn was not extracted — the instrument is" >&2
        echo "broken; every result below would be a false FAIL." >&2
        exit 1
    fi
done
echo "extraction guard: all $(( ${#FNS[@]} + ${#GATE_FNS[@]} )) units present"

# ---------------------------------------------------------------------------
echo "=== U: _pane_payload_is_pure_wait — whole-payload recogniser ==="
uw() {   # uw <want-rc> <label> <payload>
    local rc=0
    _pane_payload_is_pure_wait "$3" || rc=$?
    (( rc > 1 )) && rc=1
    ck "$2" "$rc" "$1"
}
uw 0 "U1 the orchestrator's watcher-supervisor Monitor loop" \
   'until ! /x/monitor/watcher-supervise-tick.sh; do sleep 15; done'
uw 0 "U2 the async-run wake async-run.sh itself prescribes" \
   'monitor/proc-exists-authorized --until-gone --token ar-1 --timeout 1800; echo rc=$?; monitor/async-run.sh --status ar-1'
uw 0 "U3 the skeptic await loop skeptic SKILL prescribes" \
   'monitor/skeptic-channel.sh await w1; rc=$?; echo "AWAIT_RC=$rc"; exit $rc'
uw 0 "U4 cd prefix + quoted-root ng await" \
   'cd /x && "$NEXUS_ROOT"/monitor/ng skeptic await w1'
uw 0 "U5 async-run --await" \
   'monitor/async-run.sh --await --token ar-1 --timeout 600'
uw 1 "U6 a bare sleep timer is NOT a protocol wait" 'sleep 600'
uw 1 "U7 real work" 'python train.py'
uw 1 "U8 await THEN work: killing it destroys work not yet started" \
   'monitor/skeptic-channel.sh await x && python post.py'
uw 1 "U9 command substitution inside the loop" \
   'until ! /x/watcher-supervise-tick.sh; do sleep $(python -c 1); done'
uw 1 "U10 a pipe" 'monitor/proc-exists-authorized --until-gone --token t | tail -1'
uw 1 "U11 proc-exists-authorized without --until-*" 'monitor/proc-exists-authorized --match foo'
uw 1 "U12 a DESCRIPTION of the loop is not the loop" \
   'echo until ! watcher-supervise-tick.sh; do sleep 15; done'
uw 1 "U13 grep for the tick is not the tick" 'grep watcher-supervise-tick.sh file'
uw 1 "U14 a quoted separator fails closed" \
   'echo "a; python x"; monitor/async-run.sh --await --token t --timeout 5'
uw 1 "U15 the #1208 [ -s ] waiter is left to #1208" \
   'T=/s/async-run/w/ar-1; until [ -s "$T/status" ]; do sleep 60; done'
uw 1 "U16 a redirect" 'monitor/async-run.sh --await --token t --timeout 5 > out'
uw 1 "U17 a subshell" '(monitor/async-run.sh --await --token t --timeout 5)'
uw 1 "U18 empty payload" ''

echo "=== P: _pane_root_payload — the Claude Code shell wrapper ==="
real_shape="/usr/bin/zsh -c source /s/snap.sh 2>/dev/null || true && setopt NO_EXTENDED_GLOB 2>/dev/null || true && eval 'until ! /x/monitor/watcher-supervise-tick.sh; do sleep 15; done' < /dev/null && pwd"
ck "P1 peels the measured 2026-09-11 Monitor argv shape" \
   "$(_pane_root_payload "$real_shape")" \
   'until ! /x/monitor/watcher-supervise-tick.sh; do sleep 15; done'
quoted="zsh -c source s && eval 'echo '\\''hi'\\''; monitor/async-run.sh --await --token t --timeout 5' < /dev/null && pwd -P >| /tmp/cwd"
ck "P2 undoes the wrapper's '\\'' quote escaping" \
   "$(_pane_root_payload "$quoted")" \
   "echo 'hi'; monitor/async-run.sh --await --token t --timeout 5"
rc=0; _pane_root_payload "bash -c python x" >/dev/null || rc=$?
ck "P3 no eval wrapper → refused, never guessed" "$rc" "1"
rc=0; _pane_root_payload "zsh -c source s && eval 'until ! tick.sh; do sleep 15; do" >/dev/null || rc=$?
ck "P4 a cmdline truncated before its trailer → refused" "$rc" "1"
# P5/P5b (w234sk F2): the walk reads at most 4096 bytes of a cmdline, and a
# TRUNCATED one can still end in a `' < /dev/null` that belongs to the payload.
# At or over the cap is refused; one byte under it still peels, which pins the
# boundary as the cap rather than some property of the shape.
_mk_len() {   # _mk_len <total-bytes> — the real argv shape, padded to exactly that length
    local head="/usr/bin/zsh -c source /s/"
    local tail=".sh 2>/dev/null || true && eval 'until ! /x/monitor/watcher-supervise-tick.sh; do sleep 15; done' < /dev/null && pwd"
    local n=$(( $1 - ${#head} - ${#tail} ))
    printf '%s%s%s' "$head" "$(printf '%*s' "$n" '' | tr ' ' x)" "$tail"
}
rc=0; _pane_root_payload "$(_mk_len 4096)" >/dev/null || rc=$?
ck "P5 a cmdline AT the 4096-byte read cap → refused (it may be truncated)" "$rc" "1"
rc=0; _pane_root_payload "$(_mk_len 4095)" >/dev/null || rc=$?
ck "P5b one byte under the cap still peels (the boundary is the cap, not the shape)" "$rc" "0"

# ---------------------------------------------------------------------------
# Real process trees: `claude` (a copy of bash) -> `bash -c <root text>` -> …
# The root text carries the SAME `eval '<payload>' < /dev/null` shape Claude
# Code's shells carry, so _pane_root_payload is exercised on a kernel argv, and
# a trailing `&& :` keeps bash from exec-optimising the root away
# (your-org/nexus-code#1214).
cp /bin/bash "$WORK/claude"
LIFE=$(( $(th_deadline 30) + 20 ))
DEADLINE_EPOCH=$(( $(date +%s) + LIFE ))
mkdir -p "$WORK/bin" "$WORK/bin-busy"
# The tick stub keeps the loop going until the suite's deadline, then stops it,
# so a leaked tree ends by itself. The clock is a bash BUILTIN (`printf %(%s)T`),
# not `date`, so a tick in flight forks no non-shell child.
cat > "$WORK/bin/watcher-supervise-tick.sh" <<EOF
#!/usr/bin/env bash
printf -v now '%(%s)T' -1
[ "\$now" -lt $DEADLINE_EPOCH ]
EOF
# L3's tick: the wait command itself runs a non-shell, non-sleep child.
cat > "$WORK/bin-busy/watcher-supervise-tick.sh" <<EOF
#!/usr/bin/env bash
timeout $LIFE tail -f /dev/null
:
EOF
chmod +x "$WORK/bin/watcher-supervise-tick.sh" "$WORK/bin-busy/watcher-supervise-tick.sh"

_n=0
PLANTED=""
# plant <root-text> [<root-text>…] — sets PLANTED to the fake claude's pid.
#
# NEVER CALL IT IN A COMMAND SUBSTITUTION. A counter or pid assigned inside
# `$(…)` is discarded when that subshell exits (#1214's `_tree_n` trap), and the
# first draft of this suite re-made it: every plant reused plant #1's files, a
# stale pid file handed back plant #1's pid at once, L1's live claude re-read
# its OVERWRITTEN script, the third settle timed out, and the abort path then
# printed ALL TESTS PASSED at rc 0. So: a plain global, the pid file removed
# before launch, and a timeout that aborts RED (th_abort).
plant() {
    _n=$(( _n + 1 ))
    local mid="$WORK/mid.$_n.sh" pidf="$WORK/pid.$_n" i=0 t
    rm -f "$pidf"
    PLANTED=""
    : > "$mid"
    printf '#!/usr/bin/env bash\necho $$ > %q\n' "$pidf" >> "$mid"
    for t in "$@"; do
        i=$(( i + 1 ))
        printf '%s' "$t" > "$WORK/root.$_n.$i"
        printf 'bash -c "$(cat %q)" &\n' "$WORK/root.$_n.$i" >> "$mid"
    done
    printf 'sleep %d\n:\n' "$LIFE" >> "$mid"
    chmod +x "$mid"
    setsid "$WORK/claude" "$mid" >/dev/null 2>&1 &
    disown 2>/dev/null
    local p="" k
    for k in $(seq 1 100); do
        [[ -s "$pidf" ]] && { p=$(cat "$pidf"); break; }
        sleep 0.1
    done
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    SPAWNED+=("$p")
    PLANTED="$p"
}
# _below_comms <pid> — the comm of every process strictly below <pid>.
_below_comms() {
    local queue="$1" next d pid kid out=""
    for d in 1 2 3 4 5 6 7 8; do
        next=""
        for pid in $queue; do
            for kid in $(pgrep -P "$pid" 2>/dev/null); do
                out+=" $(ps -o comm= -p "$kid" 2>/dev/null)"
                next+=" $kid"
            done
        done
        queue="$next"
        [[ -n "$queue" ]] || break
    done
    printf '%s' "$out"
}
# settle <claude-pid> <nroots> <comm>… — wait until claude has <nroots> shell
# children and each named comm appears somewhere below it. A timeout ABORTS the
# suite RED: a quiet zero here would make L2-L4 pass while asserting nothing.
settle() {
    local cp="$1" want="$2"; shift 2
    local secs; secs=$(th_deadline 30)
    local end=$(( $(date +%s) + secs )) roots=0 all="" comm ok
    while (( $(date +%s) < end )); do
        roots=$(pgrep -P "$cp" -x bash 2>/dev/null | wc -l)
        all=$(_below_comms "$cp")
        ok=1
        (( roots == want )) || ok=0
        for comm in "$@"; do
            [[ " $all " == *" $comm "* ]] || ok=0
        done
        (( ok )) && return 0
        sleep 0.2
    done
    th_abort "TREE-PLANT TIMEOUT: claude $cp roots=$roots want=$want comms=[$all] need=[$*]"
}
walk() { _pane_background_shells "$1"; }

SUP="until ! $WORK/bin/watcher-supervise-tick.sh; do sleep $LIFE; done"

echo "=== L1: POSITIVE — a supervisor-shaped root with only sleep beneath ==="
plant ": QMARK1 && eval '$SUP' < /dev/null && :" || th_abort "L1 plant did not report its pid"
pp="$PLANTED"
settle "$pp" 1 sleep
read -r c1 _ r1 _ _ s1 q1 _ < <(walk "$pp")
ck "L1 the walk is reliable (a claude node was found)" "$r1" "1"
ck "L1 one background-shell root" "$c1" "1"
ck "L1 that root is quiescent" "$q1" "1"
L1_PID="$pp"

echo "=== L2: + a second root doing real work (one variable: a work root) ==="
plant ": QMARK2A && eval '$SUP' < /dev/null && :" \
      ": QMARK2B && eval 'timeout $LIFE tail -f /dev/null' < /dev/null && :" \
    || th_abort "L2 plant did not report its pid"
pp="$PLANTED"
[[ "$pp" != "$L1_PID" ]] || th_abort "L2 plant returned L1's pid — the plants are not independent"
settle "$pp" 2 sleep tail
read -r c2 _ r2 _ _ s2 q2 _ < <(walk "$pp")
ck "L2 two background-shell roots" "$c2" "2"
ck "L2 only the wait root is quiescent — the work root is not" "$q2" "1"
rc=0; _restart_bg_all_quiescent "bg_shells=$c2 bg_reliable=$r2 bg_cpu=1 bg_quiesce=$q2" || rc=$?
ck "L2 the restart gate REFUSES a pane holding real work" "$rc" "1"

echo "=== L3: L1, but the wait command has a non-shell child (one variable) ==="
BUSY="until ! $WORK/bin-busy/watcher-supervise-tick.sh; do sleep $LIFE; done"
plant ": QMARK3 && eval '$BUSY' < /dev/null && :" || th_abort "L3 plant did not report its pid"
pp="$PLANTED"
settle "$pp" 1 tail
read -r c3 _ r3 _ _ s3 q3 _ < <(walk "$pp")
ck "L3 one background-shell root" "$c3" "1"
ck "L3 a non-shell/non-sleep descendant disqualifies it" "$q3" "0"

echo "=== L4: L1, but work is queued AFTER the loop (one variable) ==="
plant ": QMARK4 && eval '$SUP; python3 -c 1' < /dev/null && :" || th_abort "L4 plant did not report its pid"
pp="$PLANTED"
settle "$pp" 1 sleep
read -r c4 _ r4 _ _ s4 q4 _ < <(walk "$pp")
ck "L4 one background-shell root" "$c4" "1"
ck "L4 work not yet started disqualifies it" "$q4" "0"

echo "=== E1: pane-state.sh emits bg_quiesce on the live L1 tree ==="
idle_fixture="$_repo_root/$_Q_FIXTURE_REL"
if [[ -r "$idle_fixture" ]]; then
    out=$("$HELPER" --fixture "$idle_fixture" --window 9 --name qtest --active 0 \
                    --pane-pid "$L1_PID" 2>&1)
    if [[ "$out" == *"state=working-background"* && " $out " == *" bg_quiesce=1 "* \
          && "$out" == *"bg_cpu="* ]]; then
        pass "E1 working-background + bg_cpu= + bg_quiesce=1 (full: $out)"
    else
        fail "E1 emit did not carry bg_quiesce=1 on a shell-driven line — full: $out"
    fi
    st=$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$out")
    rc=0; _restart_eligible "$st" "$out" || rc=$?
    ck "E1 the restart gate accepts that exact line" "$rc" "0"
    out_o=$("$HELPER" --fixture "$idle_fixture" --window 9 --name qtest --active 0 \
                      --bg-shells 2 --bg-cpu 7 --bg-quiesce 1 2>&1)
    if [[ " $out_o " == *" bg_shells=2 "* && " $out_o " == *" bg_quiesce=1 "* ]]; then
        pass "E1 --bg-quiesce override reaches the emit line"
    else
        fail "E1 --bg-quiesce override lost — full: $out_o"
    fi
else
    fail "E1 fixture missing: $idle_fixture"
fi

echo "=== E2: the REAL emitter x the gate — a login frame on the heartbeat route (w239sk F1) ==="
# w239sk F1: the `auth=login` veto (588c758b) keyed on a LABEL that pane-state's
# w237-D2 exclusion never attached to `working-background`/`working-self-paced`,
# both of which the gate accepts — so a login frame with a quiescent background
# shell, or a scheduled wakeup, read ELIGIBLE on the real emitter line, and G11
# was green only on a synthetic line the emitter could not produce. These cases
# feed the REAL emitter (login capture + heartbeat idle + the bg overrides, the
# exact drive w239sk used) and pass its OWN output to the gate. The orchestrator
# permanently holds the supervisor Monitor, so on the heartbeat route it reads
# working-background: this is the case, not an edge (#1520 arms the route).
_e2_now=$(date +%s)
_e2_hb="$WORK/e2-hb.json"; printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s}\n' "$_e2_now" "$_e2_now" > "$_e2_hb"
_e2_hb2="$WORK/e2-hb2.json"; printf '{"state":"idle_prompt","last_activity":%s,"last_turn_end":%s,"scheduled_wakeup_at":%s}\n' "$_e2_now" "$_e2_now" "$(( _e2_now + 600 ))" > "$_e2_hb2"
_e2_login="$_repo_root/monitor/watcher/fixtures/blocked-login-method-realmodel-268.ansi"
_e2_paste="$_repo_root/monitor/watcher/fixtures/blocked-login-codepaste-realmodel-268.ansi"
_e2_busyq="$_repo_root/monitor/watcher/fixtures/busy-dialog-quoted-midrender-synthetic.ansi"
e2() {   # e2 <label> <want-state> <want-auth> <want-gate-rc> <fixture> <hb-file> [extra pane-state args…]
    local label="$1" ws="$2" wa="$3" wrc="$4" fx="$5" hb="$6"; shift 6
    local out st au rc=0
    out=$("$HELPER" --fixture "$fx" --heartbeat-file "$hb" --now "$_e2_now" --window 2 --name orchestrator --active 1 "$@" 2>&1)
    st=$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$out")
    au=$(sed -n 's/.*[[:space:]]auth=\([a-z]*\).*/\1/p' <<<"$out")
    ck "$label: emitted state" "$st" "$ws"
    ck "$label: emitted auth= (\"\" = no label)" "$au" "$wa"
    _restart_eligible "$st" "$out" || rc=$?
    ck "$label: the gate on the emitter's OWN line" "$rc" "$wrc"
}
if [[ -r "$_e2_login" && -r "$_e2_paste" && -r "$_e2_busyq" ]]; then
    e2 "E2a login menu + heartbeat idle + quiescent bg shell → working-background carries auth=login, NOT a boundary" \
       working-background login 1 "$_e2_login" "$_e2_hb" --bg-shells 1 --bg-cpu 2 --bg-quiesce 1
    e2 "E2b login menu + scheduled wakeup → working-self-paced carries auth=login, NOT a boundary" \
       working-self-paced login 1 "$_e2_login" "$_e2_hb2"
    e2 "E2c code-paste step + heartbeat idle + quiescent bg shell → auth=login, NOT a boundary" \
       working-background login 1 "$_e2_paste" "$_e2_hb" --bg-shells 1 --bg-cpu 2 --bg-quiesce 1
    # CONTROL (w237sk D2's own false positive): a BUSY, row-less pane QUOTING a
    # login literal must stay UNLABELLED — narrowing the exclusion must not bring
    # it back. The busy fixture holds no login text of its own (w239sk delta:
    # an unspliced control could not go red), so the literal is SPLICED in the
    # way test-auth-hold.sh's D2 does, and the splice is asserted to have taken.
    _e2_spliced="$WORK/e2d-busy-quoting.ansi"
    { sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' "$_e2_busyq"
      printf "the GUIDE entry says the literal is 'Paste code here if prompted'\n"; } > "$_e2_spliced"
    if grep -qF 'Paste code here if prompted' "$_e2_spliced" \
       && ! grep -qF "❯$(printf '\u00a0')" "$_e2_spliced"; then
        out=$("$HELPER" --fixture "$_e2_spliced" --window 2 --name orchestrator --active 1 2>&1)
        ck "E2d CONTROL the spliced capture is busy and row-less (D2's population)" \
           "$(sed -n 's/.*state=\([a-z-]*\).*/\1/p' <<<"$out")" busy
        ck "E2d CONTROL …and a BUSY pane quoting a login literal stays unlabelled" \
           "$(sed -n 's/.*[[:space:]]auth=\([a-z]*\).*/\1/p' <<<"$out")" ""
    else
        fail "E2d the splice did not take, or the capture has a REPL row — the control would assert nothing"
        fail "E2d (second assertion withheld for the same reason)"
    fi
else
    fail "E2 fixtures missing: $_e2_login / $_e2_paste / $_e2_busyq"
fi

echo "=== G: the restart gate predicate ==="
gate() {   # gate <want-rc> <label> <state> <line>
    local rc=0
    _restart_eligible "$3" "$4" || rc=$?
    ck "$2" "$rc" "$1"
}
gate 0 "G1 every root quiescent on a reliable walk → boundary" working-background \
     "state=working-background bg_shells=1 bg_reliable=1 bg_cpu=2 bg_infra=0 bg_quiesce=1"
gate 1 "G2 a root that is not quiescent → keep waiting" working-background \
     "state=working-background bg_shells=2 bg_reliable=1 bg_cpu=2 bg_quiesce=1"
gate 1 "G3 unreliable walk → keep waiting" working-background \
     "state=working-background bg_shells=1 bg_reliable=0 bg_cpu=2 bg_quiesce=1"
gate 1 "G4 older pane-state with no bg_quiesce → keep waiting (pre-fix behaviour)" working-background \
     "state=working-background bg_shells=1 bg_reliable=1 bg_cpu=42 bg_oldest_start=1"
gate 1 "G5 malformed bg_quiesce → keep waiting" working-background \
     "state=working-background bg_shells=1 bg_reliable=1 bg_cpu=2 bg_quiesce=x"
gate 0 "G6 Monitor-handle flavour (no bg_cpu=) unchanged → boundary" working-background \
     "state=working-background active=1 window=2 name=orchestrator"
gate 1 "G7 zero roots with bg_cpu= → keep waiting" working-background \
     "state=working-background bg_shells=0 bg_reliable=1 bg_cpu=2 bg_quiesce=0"
gate 1 "G8 keys are delimiter-anchored (xbg_shells= is not bg_shells=)" working-background \
     "state=working-background xbg_shells=1 bg_shells=2 bg_reliable=1 bg_cpu=2 bg_quiesce=1"
gate 1 "G9 busy is never a boundary, whatever the bg fields say" busy \
     "state=busy bg_shells=1 bg_reliable=1 bg_cpu=2 bg_quiesce=1"
# INTERACTION with #1518's `auth=` field (w239 integration of the w234 and
# w237 branches). A live /login frame reaches `state=idle` via the heartbeat
# classification route (pane-state.sh's emitter says so, measured), and `idle`
# is a turn boundary — so without this veto the restart would kill the
# operator's login in progress and respawn a session that is STILL
# unauthenticated. `auth=login` therefore wins over every boundary verdict.
# `auth=expired` does NOT veto: the session is logged out and idle, a
# resume-from-transcript restart loses nothing, and the operator's board state
# is waiting in the transcript when they log back in.
gate 1 "G10 auth=login on idle → NOT a boundary (a login in progress wins)" idle \
     "state=idle active=1 window=2 name=orchestrator auth=login"
gate 1 "G11 auth=login on a quiescent shell-driven working-background → NOT a boundary" working-background \
     "state=working-background bg_shells=1 bg_reliable=1 bg_cpu=2 bg_infra=0 bg_quiesce=1 auth=login"
gate 0 "G12 auth=expired on idle → still a boundary (resume loses nothing)" idle \
     "state=idle active=1 window=2 name=orchestrator auth=expired"
gate 1 "G13 auth= is delimiter-anchored (xauth=login is not auth=login, but the veto still keys on the real token)" idle \
     "state=idle xauth=nothing auth=login window=2"

# A vanished case would otherwise quietly cost assertions and still read green.
_total=$(( ${PASS:-0} + ${FAIL:-0} + ${SKIP:-0} ))
if [[ "$_total" == "$EXPECTED_ASSERTIONS" ]]; then
    printf '  PASS: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS"; _th_pass
else
    printf '  FAIL: assertion census — %s ran, %s declared\n' "$_total" "$EXPECTED_ASSERTIONS" >&2; _th_fail
fi

th_summary_and_exit
