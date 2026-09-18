#!/usr/bin/env bash
# pane-state must ESTABLISH background-job liveness, not INFER it —
# your-org/nexus-code#1208.
#
# THE DEFECT. `_pane_background_shells` counted a shell child of claude as
# work in flight. That is an inference from a proxy ("a shell exists"), and it
# is wrong for the most common background-shell shape in this workspace: the
# wait wrapper an agent leaves around an `async-run` job.
#
#     T=<state>/async-run/<window>/<token>
#     until [ -s "$T/status" ]; do sleep 60; done
#
# A SIGKILLed job writes no status file BY CONSTRUCTION, so the loop waits
# forever, `pane-state` reports `working-background`, and `retire-preflight` —
# correctly default-deny — refuses to retire the window WITH NO FUTURE EVENT
# LEFT TO ARRIVE. Measured 2026-08-30 on window `olayingestsk2`, token
# `ar-abdb92e13667`, killed ~3 h earlier: `async-run --status-line` said
# `died`, `pane-state` said `working-background`, `retire-preflight` said
# `safe=0`. Two tools, one fact, opposite answers, and the wrong one is the
# one every consumer reads.
#
# WHAT THESE CASES ARE FOR. The fix is a call OUT to the existing authority
# (`async-run.sh`, which already owns the `terminal`/`running`/`died` model
# including the pid-IDENTITY check), never a second `died` detector here —
# growing one would reproduce #1208 inside its own fix. So most of what
# follows tests the DEFAULT-DENY boundary rather than the happy path: the only
# way to lose the `working-background` exemption is a POSITIVE `died`, and
# cases 3-6 and 8-10 exist to prove that every other outcome — `running`,
# `terminal`, unknown, unparseable, unresolvable, an alien descendant, a token
# that is not the root's own — leaves the pre-#1208 verdict untouched.
#
# Cases 12-14 exist only to prove what did NOT change: `working-background` is
# still reachable, `retire-preflight` still refuses it, and the kill allowlist
# is byte-for-byte untouched. The fix had to land in CLASSIFICATION, not in
# authorisation; a fix that achieved its result by weakening the guard would
# pass every other case here and be exactly the wrong change.
#
# CORPUS NOTE, stated rather than assumed. Cases 7-11 build REAL process trees
# (a copy of bash named `claude`, a shell child holding the token in its argv,
# and real descendants) so the /proc walk, the comm allowlist and the
# root-owns-the-token requirement are exercised against the kernel rather than
# against an override. Cases 1-6 exercise the resolver against REAL async-run
# state dirs. Case 6 alone uses a STUB async-run, because the property it
# pins — verdict-word EQUALITY, not substring — is not reachable through the
# real one today, and a property that is only defensive is exactly the one
# that rots unobserved.
#
# Run: bash monitor/watcher/test-pane-state-asyncrun-liveness.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
HELPER="$_repo_root/monitor/pane-state.sh"
ASYNCRUN="$_repo_root/monitor/async-run.sh"
BK="$_repo_root/monitor/_bookkeeping.sh"
PREFLIGHT="$_repo_root/monitor/retire-preflight.sh"

# Shared harness: the durable assertion LEDGER plus `th_summary_and_exit`.
# Adopted rather than opted out of -- test-summary-honesty-manifest.sh says
# plainly that appending your own new suite to its exemption list "opts your own
# new code out of the standard". The ledger survives the subshell a plain
# counter dies in, which matters here because several cases assert inside
# `$( … )` and `( … )`.
# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1" >&2; _th_fail; }
ck()   { if [[ "$2" == "$3" ]]; then pass "$1 ($2)"; else fail "$1 — got '$2' want '$3'"; fi; }

[[ -x "$HELPER"   ]] || { echo "helper not executable: $HELPER" >&2; exit 1; }
[[ -x "$ASYNCRUN" ]] || { echo "async-run not executable: $ASYNCRUN" >&2; exit 1; }
[[ -r "$BK"       ]] || { echo "bookkeeping not readable: $BK" >&2; exit 1; }

WORK=$(mktemp -d -t nexus-1208-XXXXXX)
# Only ever kills pids THIS suite recorded at launch. Never a pattern, never a
# pgrep -f: a predicate keyed on a string cannot tell the thing from the
# description of the thing, and sibling agents' argv holds these very strings
# (your-org/nexus-code#1073, #851). Every planted process also carries its own
# `sleep` bound, so a failed kill self-clears rather than leaking.
SPAWNED=()
cleanup() {
    local p
    for p in ${SPAWNED[@]+"${SPAWNED[@]}"}; do
        [[ "$p" =~ ^[0-9]+$ ]] && kill -TERM "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

field() { sed -E "s/.*(^| )$2=([^ ]*).*/\2/;t;d" <<<"$1"; }
C12=0

# ---------------------------------------------------------------------------
# Extract the units under test. Sourcing pane-state.sh whole would execute it,
# so the two resolver helpers plus the walk and its dependencies are lifted by
# name into one file.
#
# THE EXTRACTION IS ITSELF A GUARD. If a function were renamed or the sed range
# silently matched nothing, every case below would fail with "command not
# found" — which reads as a defect in the code under test rather than as a
# broken instrument. So extraction is asserted BEFORE anything is believed,
# and a missing function aborts the run instead of scoring a FAIL.
UNITS="$WORK/units.sh"
: > "$UNITS"
FNS=(_pane_comm_is_shell _pane_ticks_to_epoch _pane_cmd_is_protocol_wait
     _pane_cmd_descriptor _pane_asyncrun_refs _pane_asyncrun_ref_is_died
     _pane_background_shells)
for fn in "${FNS[@]}"; do
    sed -n "/^${fn}() {/,/^}/p" "$HELPER" >> "$UNITS"
    printf '\n' >> "$UNITS"
done
# shellcheck disable=SC1090
_PS_SCRIPT_DIR="$_repo_root/monitor"
source "$UNITS" || { echo "could not source extracted units" >&2; exit 1; }
for fn in "${FNS[@]}"; do
    if ! declare -F "$fn" >/dev/null; then
        echo "EXTRACTION GUARD FAILED: $fn was not extracted from $HELPER — the" >&2
        echo "instrument is broken; every result below would be a false FAIL." >&2
        exit 1
    fi
done
echo "extraction guard: all ${#FNS[@]} units present"

# A real async-run state root, so the resolver is exercised against the real
# tool and its real on-disk layout rather than against a mock of it.
SD="$WORK/state"
WIN=fixturewin
mkdir -p "$SD/async-run/$WIN"
plant() {   # plant <token> <pid> <pidstart> [<status-rc>]
    local tok="$1" pid="$2" ps="$3" st="${4:-}"
    local d="$SD/async-run/$WIN/$tok"
    mkdir -p "$d"
    printf '%s' "$pid" > "$d/pid"
    printf '%s' "$ps"  > "$d/pidstart"
    printf '%s' "$(date +%s)" > "$d/started"
    printf 'true'      > "$d/cmd"
    [[ -n "$st" ]] && printf '%s' "$st" > "$d/status"
    printf '%s' "$d"
}
ref_of() { printf '%s/async-run/%s/%s' "$SD" "$WIN" "$1"; }

# ---------------------------------------------------------------------------
echo "=== case 1: refs are extracted from an argv, all of them, none invented ==="
WRAPPER_ARGV="eval 'T=$SD/async-run/$WIN/ar-aaaaaaaaaaaa
until [ -s \"\$T/status\" ]; do sleep 60; done'"
got=$(_pane_asyncrun_refs "$WRAPPER_ARGV")
ck "the real wait-wrapper shape yields its one ref" \
   "$got" "$(ref_of ar-aaaaaaaaaaaa)"
got=$(_pane_asyncrun_refs "x /s/async-run/w1/ar-111111111111 y /s/async-run/w2/ar-222222222222 z" | tr '\n' ',')
ck "two refs in one argv both extracted" "$got" "/s/async-run/w1/ar-111111111111,/s/async-run/w2/ar-222222222222,"
got=$(_pane_asyncrun_refs "a plain background job; sleep 60")
ck "an argv naming no async-run job yields nothing" "$got" ""

# ---------------------------------------------------------------------------
echo "=== case 2: a DIED job is POSITIVELY established (the only SAFE arm) ==="
# pid 2 is the kernel's kthreadd; its real start-time is not 1, so the identity
# check fails and async-run reports the pid gone. No status file was written.
plant ar-dddddddddddd 2 1 >/dev/null
v=$(NEXUS_WORKER_WINDOW="$WIN" NEXUS_STATE_DIR="$SD" "$ASYNCRUN" --status-line ar-dddddddddddd)
ck "async-run itself calls this token died" "${v%%|*}" "died"
if _pane_asyncrun_ref_is_died "$(ref_of ar-dddddddddddd)"; then
    pass "the resolver agrees with the authority: died"
else
    fail "the resolver did NOT establish died for a token async-run calls died"
fi

# ---------------------------------------------------------------------------
echo "=== case 3: a TERMINAL job is not stale — it reported, so it is not #1208 ==="
plant ar-tttttttttttt 2 1 0 >/dev/null
v=$(NEXUS_WORKER_WINDOW="$WIN" NEXUS_STATE_DIR="$SD" "$ASYNCRUN" --status-line ar-tttttttttttt)
ck "async-run calls this token terminal" "${v%%|*}" "terminal"
_pane_asyncrun_ref_is_died "$(ref_of ar-tttttttttttt)" \
  && fail "a terminal job was called stale" \
  || pass "a terminal job is NOT stale (default-deny)"

# ---------------------------------------------------------------------------
echo "=== case 4: a RUNNING job is not stale — the direction that would retire live work ==="
# A real, self-bounding process of our own, with its real /proc start-time, so
# async-run's pid-IDENTITY check passes and the verdict is genuinely `running`.
sleep 90 & live_pid=$!
disown 2>/dev/null
SPAWNED+=("$live_pid")
live_start=$(awk '{print $22}' "/proc/$live_pid/stat" 2>/dev/null)
plant ar-rrrrrrrrrrrr "$live_pid" "$live_start" >/dev/null
v=$(NEXUS_WORKER_WINDOW="$WIN" NEXUS_STATE_DIR="$SD" "$ASYNCRUN" --status-line ar-rrrrrrrrrrrr)
ck "async-run calls this token running" "${v%%|*}" "running"
_pane_asyncrun_ref_is_died "$(ref_of ar-rrrrrrrrrrrr)" \
  && fail "a RUNNING job was called stale — this would retire live work" \
  || pass "a running job is NOT stale (default-deny)"

# ---------------------------------------------------------------------------
echo "=== case 5: every unresolvable input defaults to NOT-dead ==="
for bad in "" "garbage" "/no/such/async-run/w/ar-abcabcabcabc" \
           "$SD/async-run/$WIN/ar-nosuchtoken" "$SD/async-run/$WIN/notatoken" \
           "/async-run/ar-aaaaaaaaaaaa"; do
    if _pane_asyncrun_ref_is_died "$bad"; then
        fail "unresolvable input was called DEAD: '$bad'"
    else
        pass "unresolvable input defaults to not-dead: '${bad:-<empty>}'"
    fi
done

# ---------------------------------------------------------------------------
echo "=== case 6: the verdict is matched by EQUALITY, never as a substring ==="
# The detail half of a status line is free text. If the resolver matched
# `died` anywhere in the line, a `terminal` job whose detail merely MENTIONS
# the word would be retired as dead. Not reachable through today's async-run —
# which is exactly why it is pinned here rather than left to inspection.
STUB="$WORK/stubdir"; mkdir -p "$STUB"
cat > "$STUB/async-run.sh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'terminal|rc=0 the previous attempt died before it could report\n'
STUBEOF
chmod +x "$STUB/async-run.sh"
( _PS_SCRIPT_DIR="$STUB"
  if _pane_asyncrun_ref_is_died "$(ref_of ar-dddddddddddd)"; then exit 0; else exit 1; fi )
if (( $? == 0 )); then
    fail "a terminal line whose DETAIL contains 'died' was read as died — substring match"
else
    pass "a terminal line whose detail contains 'died' is NOT died — equality on the verdict word"
fi
# Positive control for the stub itself: a stub that says `died` MUST be
# believed, or the case above would pass for the wrong reason (a stub that is
# never consulted at all looks identical to one that is consulted and refused).
cat > "$STUB/async-run.sh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'died|pid=1 is gone\n'
STUBEOF
chmod +x "$STUB/async-run.sh"
( _PS_SCRIPT_DIR="$STUB"
  if _pane_asyncrun_ref_is_died "$(ref_of ar-dddddddddddd)"; then exit 0; else exit 1; fi )
if (( $? == 0 )); then
    pass "stub positive control: the resolver DOES consult async-run"
else
    fail "stub positive control FAILED — the resolver never consulted async-run, so case 6 proved nothing"
fi

# ---------------------------------------------------------------------------
# Real process trees. `pane_pid` -> a copy of bash named `claude` -> a shell
# child holding the token in its OWN argv -> optional descendants.
#
# THE ROOT MUST BE `bash -c '<text>'`, NOT `bash <scriptfile>`. A script file
# puts the command text in the FILE and leaves the argv as `bash /path/root.sh`,
# so no token is in any argv and EVERY case below would report `stale=0` — the
# default-deny answer — and pass. The first draft of this suite did exactly
# that: cases 8-11 were green while asserting nothing at all, and only case 7,
# the POSITIVE, caught it. That is the whole reason case 7 leads.
#
# So the design here is DIFFERENTIAL: case 7 pins the positive, and cases 8-11
# each differ from it by EXACTLY ONE VARIABLE (an alien descendant / where the
# token lives / the job's verdict / whether there is a token at all). A vacuous
# pass is then impossible, because the same tree with that one variable removed
# is asserted to give the opposite answer.
cp /bin/bash "$WORK/claude"
# _tree_n MUST live in a FILE, not a variable (your-org/nexus-code#1214 follow-up).
# Every call site is `pp=$(build_tree ...)`, so build_tree runs in a COMMAND
# SUBSTITUTION SUBSHELL and any `_tree_n=$((_tree_n+1))` it performs is discarded
# when that subshell exits. Measured: parent-n stays 0 across six plants, so all
# six markers were `NEXUS1208MARK1` and a TREE-PLANT banner could not say WHICH
# plant had failed -- the diagnostic was uniformly wrong while looking right.
_tree_n_file="$WORK/.tree_n"
printf '0' > "$_tree_n_file"
_tree_mark=""
_tree_next() {   # echo the next index, durably across subshells
    local n
    n=$(cat "$_tree_n_file" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] || n=0
    n=$(( n + 1 )); printf '%s' "$n" > "$_tree_n_file"; printf '%s' "$n"
}
# THE MARKER MUST SURVIVE bash's EXEC OPTIMISATION (your-org/nexus-code#1214).
# bash replaces itself with the LAST command of a `-c` string or a script when
# nothing needs the shell afterwards -- so `bash -c ': MARK; sleep 20'` becomes a
# process whose argv is literally `sleep 20`, and the marker this suite searches
# /proc/<pid>/cmdline for is GONE. Measured on this host, one probe, three
# interpreters:
#     4.4.20 (/bin/bash here)   argv: `bash -c : MARK; sleep 4`   marker PRESENT
#     4.4.18 (toolchain)        argv: `bash -c : MARK; sleep 4`   marker PRESENT
#     5.2.0  (toolchain)        argv: `sleep 4`                   marker GONE
# CI's runner /bin/bash IS 5.2 and this host's is 4.4.20, which is exactly why
# the suite passed locally and failed in CI on every run, independently of
# NEXUS_TEST_SHELL: the plant's inner `bash -c` resolves through PATH, not
# through the suite's interpreter. A trailing `:` leaves a command after the
# payload, so the shell must stay alive and keeps its argv. Verified to keep the
# marker on BOTH 4.4 and 5.2 -- the fix is not itself version-dependent.
#
# THE PLANT MUST OUTLIVE THE WAIT (your-org/nexus-code#1214 follow-up). The
# plant used to `sleep 25` while `wait_tree` polled for `th_deadline 30` -- 30 s
# locally and 60 s in CI. So the tree was GUARANTEED to be gone for the last
# 35 s of every wait, and once the poll loop was starved past ~25 s the wait
# could never succeed no matter how long it ran. CI's own banner proved it:
#     plant SELF-REPORTED pid 786256 -- the mid script DID run
#     walk root pid 786256 is DEAD; its direct children: <none>
#     processes carrying it anywhere: 0
# The mid script ran, and by timeout the whole tree had legitimately exited.
# Note the direction: SCALING the deadline (30 -> 60) made this WORSE, because
# it widened the window in which the answer is structurally unobtainable. The
# budget and the lifetime are one quantity and must be derived together.
_plant_life=$(( $(th_deadline 30) + 20 ))
_tree_rootpid() {   # _tree_rootpid <pidfile> <shell-\$!> — prefer the SELF-REPORTED pid
    local pidf="$1" fallback="$2" i n
    for i in $(seq 1 100); do          # 10 s; the plant writes this immediately
        if [[ -s "$pidf" ]]; then
            n=$(cat "$pidf" 2>/dev/null)
            [[ "$n" =~ ^[0-9]+$ ]] && { printf '%s' "$n"; return 0; }
        fi
        sleep 0.1
    done
    # Never silently substitute the unreliable pid: say so, then use it, so a
    # later TREE-PLANT TIMEOUT is attributable rather than mysterious.
    echo "PLANT DID NOT REPORT ITS PID within 10s — falling back to \$! ($fallback), which is unreliable after setsid" >&2
    printf '%s' "$fallback"
}
build_tree() {   # build_tree <root-shell-command-TEXT> ; echoes the pane_pid
    _tree_n=$(_tree_next)
    local mid="$WORK/mid.$_tree_n.sh"
    _tree_mark="NEXUS1208MARK$_tree_n"
    local pidf="$WORK/rootpid.$_tree_n"
    rm -f "$pidf"
    cat > "$mid" <<MIDEOF
#!/usr/bin/env bash
# REPORT OUR OWN PID (your-org/nexus-code#1214 follow-up). \$! after \`setsid\`
# is NOT reliably the planted process: setsid FORKS whenever its caller is
# already a process-group leader, and the pid the shell captures is then the
# short-lived forking parent, which exits at once. The walk would start from a
# DEAD pid and could never find the marker -- at ANY deadline. Measured both
# ways on this host, same script, job control the only variable:
#     set +m : \$!=alive  children=2  marker FOUND
#     set -m : \$!=DEAD   children=0  marker NOT found
# Writing our own \$\$ makes the root correct regardless of whether setsid
# forked, so the walk no longer depends on that behaviour at all.
echo \$\$ > "$pidf"
bash -c ': $_tree_mark; $1; :' &
sleep $_plant_life
MIDEOF
    chmod +x "$mid"
    setsid "$WORK/claude" "$mid" >"$WORK/plant.$_tree_n.out" 2>&1 &
    disown 2>/dev/null
    local p; p=$(_tree_rootpid "$pidf" "$!")
    SPAWNED+=("$p")
    wait_tree "$p" "$_tree_mark" "build_tree #$_tree_n"
    printf '%s' "$p"
}
build_tree_scripted() {   # root argv carries NO token; the FILE does
    _tree_n=$(_tree_next)
    local root="$WORK/root.$_tree_n.sh" mid="$WORK/mid.$_tree_n.sh"
    # The root is invoked as `bash <root>`, so the ROOT'S OWN ARGV carries the
    # script path and nothing else — which is exactly the property this builder
    # exists to create (case 9: a token that is NOT in the root's argv). The
    # unique path is therefore the marker; a marker written INTO the file would
    # appear in no argv and wait_tree would time out.
    _tree_mark="$root"
    # The trailing `:` is load-bearing, same reason as in build_tree: bash 5.2
    # EXEC-optimises the last command of a script, replacing the shell process
    # and its argv -- and here the argv IS the marker (the root script's path).
    printf '%s\n:\n' "$1" > "$root"
    local pidf="$WORK/rootpid.$_tree_n"
    rm -f "$pidf"
    cat > "$mid" <<MIDEOF
#!/usr/bin/env bash
# Same self-reported root as build_tree — see the note there.
echo \$\$ > "$pidf"
bash "$root" &
sleep $_plant_life
MIDEOF
    chmod +x "$mid"
    setsid "$WORK/claude" "$mid" >"$WORK/plant.$_tree_n.out" 2>&1 &
    disown 2>/dev/null
    local p; p=$(_tree_rootpid "$pidf" "$!")
    SPAWNED+=("$p")
    wait_tree "$p" "$_tree_mark" "build_tree_scripted #$_tree_n"
    printf '%s' "$p"
}
walk() { _pane_background_shells "$1"; }

# Wait for a planted tree to actually EXIST before measuring it.
#
# A fixed `sleep 1` was the first draft and it is not safe here: this repo
# routinely has several clones running suites at `--jobs 4` concurrently, and
# under that load a freshly-setsid'd three-level tree is not always up in a
# second. The failure would be silent and would point the wrong way — the walk
# would find no background shell, report `stale=0`, and every default-deny case
# (8, 9, 10, 11) would PASS while asserting nothing, exactly the vacuous-green
# trap that the first version of this suite already fell into once.
#
# So the wait is on the tree's OWN marker, and a timeout is a LOUD abort rather
# than a quiet zero. Descendants only: matching by string across the whole
# process table would hit sibling agents' argv, which quotes these very
# strings (your-org/nexus-code#1073).
_descendants() {
    local root="$1" queue="$1" next="" pid kid out=""
    local depth
    for depth in 0 1 2 3 4 5 6; do
        [[ -n "$queue" ]] || break
        next=""
        for pid in $queue; do
            out+="$pid "
            for kid in $(pgrep -P "$pid" 2>/dev/null); do next+="$kid "; done
        done
        queue="$next"
    done
    printf '%s' "$out"
}
wait_tree() {   # wait_tree <pane_pid> <marker> <label>
    local root="$1" marker="$2" label="$3" i pid secs iters
    # SCALED, not hardcoded (your-org/nexus-code#1214 follow-up). This wait
    # used to be a bare `seq 1 150` -- ~30 s at any contention -- and it
    # EXPIRED on CI's 2-vCPU runner (run 33457085002: loadavg 2.58 on
    # cpus=2, cpu-stall 13.91%), taking the whole suite red. `th_deadline`
    # is the harness's own answer to exactly this and every polled deadline
    # in the corpus is supposed to go through it: it multiplies by
    # NEXUS_TEST_DEADLINE_SCALE, or by ceil(NEXUS_TEST_JOBS / nproc) when
    # that is unset. The failure direction is what makes it worth scaling
    # rather than merely enlarging -- an expired plant aborts the suite
    # (exit 2, UNCLASSIFIED) rather than asserting something false, so the
    # cost of being too tight is a red that carries no information.
    secs=$(th_deadline 30)
    [[ "$secs" =~ ^[0-9]+$ ]] && (( secs >= 1 )) || secs=30
    iters=$(( secs * 5 ))              # the loop sleeps 0.2 s
    for i in $(seq 1 "$iters"); do
        for pid in $(_descendants "$root"); do
            # `grep -aF` straight at the file, NOT a command substitution
            # of `tr`. /proc/<pid>/cmdline is NUL-delimited; bash strips
            # NULs out of `$(...)` and warns once per read on stderr --
            # 14 warnings per run, noise in an instrument whose whole job
            # is to be readable when it fails. A marker always sits inside
            # ONE argv token, so it never spans a NUL and a fixed-string
            # match is exact.
            if grep -qaF -- "$marker" "/proc/$pid/cmdline" 2>/dev/null; then
                return 0
            fi
        done
        sleep 0.2
    done
    # Report the BUDGET ACTUALLY USED, never the literal 30: a scaled wait
    # whose message still says "30s" is a number the reader cannot check.
    echo "TREE-PLANT TIMEOUT: '$label' never appeared under pid $root within ${secs}s (base 30, scale $(th_deadline 1))." >&2
    # WHY IT FAILED — the banner used to say only THAT it failed, which is why two
    # CI runs and a wrong hypothesis could not settle the cause (#1214 follow-up).
    # Each line below discriminates a different explanation, so the NEXT failure is
    # self-explaining rather than another round of inference:
    local _pf="$WORK/rootpid.${_tree_n}" _kids _self
    if [[ -s "$_pf" ]]; then
        echo "  plant SELF-REPORTED pid $(cat "$_pf" 2>/dev/null) — the mid script DID run" >&2
    else
        echo "  plant NEVER wrote its pidfile ($_pf) — the mid script did NOT run at all" >&2
        echo "  (so this is spawn/exec, NOT the walk and NOT the deadline)" >&2
    fi
    _self=$(kill -0 "$root" 2>/dev/null && echo alive || echo DEAD)
    _kids=$(pgrep -P "$root" 2>/dev/null | tr '\n' ' ')
    echo "  walk root pid $root is $_self; its direct children: ${_kids:-<none>}" >&2
    # THE PLANT'S OWN OUTPUT, which used to go to /dev/null. A tree that starts
    # and then dies says WHY on its stderr, and discarding it is the silent
    # channel that made three CI runs uninformative about this step. CONTENTS,
    # not the path: the temp dir is gone by the time anyone reads the log.
    local _po="$WORK/plant.${_tree_n}.out"
    if [[ -s "$_po" ]]; then
        echo "  plant said (stdout+stderr, previously discarded):" >&2
        sed -e 's/^/    | /' "$_po" >&2
    else
        echo "  plant wrote NOTHING to stdout/stderr" >&2
    fi
    echo "  descendants walked: $(_descendants "$root" 2>/dev/null)" >&2
    echo "  marker sought: '$marker'" >&2
    # SELF-MATCH GUARD: `grep -laF -- "$marker" /proc/*/cmdline` carries the marker
    # in its OWN argv, so it matches itself and reports 1 where the truth is 0 --
    # measured, and it would read as "planted but unreachable" precisely when
    # nothing was planted. Scanned in pure bash instead, so the marker never
    # enters any process's argv.
    local _n=0 _c _cf _hits=''
    for _cf in /proc/[0-9]*/cmdline; do
        # The redirection itself must be silenced INSIDE the subshell: a pid can
        # exit between the glob and the read, and bash prints its own "No such
        # file" for the failed redirect BEFORE `|| continue` can matter.
        _c=$( { tr '\0' ' ' < "$_cf"; } 2>/dev/null ) || continue
        case "$_c" in *"$marker"*)
            _n=$(( _n + 1 ))
            [[ $_n -le 3 ]] && _hits="$_hits [${_cf%/cmdline}: $(printf '%.70s' "$_c")]"
            ;;
        esac
    done
    echo "  processes carrying it anywhere: $_n${_hits:+ ->$_hits}" >&2
    echo "  ^ NAMED, not counted: an agent's argv IS its prompt, so a marker merely" >&2
    echo "    DISCUSSED in a nearby session matches this scan (your-org/nexus-code#1073)." >&2
    echo "    Read the cmdlines: a plant's argv ends in a generated mid-script named" >&2
    echo "    mid.<n>.sh under this run's temp dir; anything else is a description of" >&2
    echo "    the marker rather than the marker itself." >&2
    echo "  ^ a NONZERO count with an empty descendant set means the tree was planted" >&2
    echo "    but is NOT reachable from the root this suite walks from — i.e. the ROOT" >&2
    echo "    is wrong, not the timeout." >&2
    echo "The node is probably loaded. This is UNCLASSIFIED, not a red: every" >&2
    echo "case below would report stale=0 and pass while asserting nothing." >&2
    # `exit 2` here leaves only the COMMAND SUBSTITUTION SUBSHELL -- every call
    # site is `pp=$(build_tree ...)`. For the abort to be real the CALL SITE must
    # test the substitution's status, which it now does (`|| exit 2`). Measured
    # before that change: 6 banners, "30 passed, 18 failed", rc 1 -- i.e. the
    # suite carried on and reported eighteen assertion failures about a tree that
    # was never planted, which is precisely the "asserting nothing" this banner
    # claims to prevent. The banner was telling the truth about the intent and
    # the code did the opposite.
    exit 2
}

DIED_REF=$(ref_of ar-dddddddddddd)
RUN_REF=$(ref_of ar-rrrrrrrrrrrr)

echo "=== case 7: THE POSITIVE — a wait wrapper on a DIED job is counted, and STALE ==="
# The live #1208 shape: the token sits in the wrapper's own argv, because
# Claude Code's Bash tool invokes `zsh -c '<text>'`. Measured on the real
# reproducer, /proc/15225/cmdline carried the full token path.
pp=$(build_tree "T=$DIED_REF; sleep 20") || exit 2
read -r c7 _ r7 _ _ s7 _ < <(walk "$pp")
ck "the walk is reliable (a claude node was found)" "$r7" "1"
ck "the wrapper is still COUNTED as a background shell" "$c7" "1"
ck "and it is reported STALE" "$s7" "1"

echo "=== case 8: case 7 + an ALIEN descendant -> NOT stale ==="
# One variable changed: a descendant that is neither a shell nor `sleep`.
# That is real work, and it disqualifies the root. Default-deny, because the
# cost of being wrong here is retiring a worker mid-computation.
pp=$(build_tree "T=$DIED_REF; timeout 20 tail -f /dev/null & sleep 20") || exit 2
read -r c8 _ r8 _ _ s8 _ < <(walk "$pp")
ck "still reliable" "$r8" "1"
ck "still counted" "$c8" "1"
ck "an alien descendant blocks staleness" "$s8" "0"

echo "=== case 9: case 7 with the token on a DESCENDANT only -> NOT stale ==="
# One variable changed: WHERE the token lives. The root's own argv must name
# the job, or the root is not a wait wrapper and its shell is doing something
# else entirely.
pp=$(build_tree_scripted "bash -c 'T=$DIED_REF; sleep 18' & sleep 20") || exit 2
read -r c9 _ r9 _ _ s9 _ < <(walk "$pp")
ck "still reliable" "$r9" "1"
ck "the root does not own the token, so NOT stale" "$s9" "0"

echo "=== case 10: case 7 with a RUNNING job instead -> NOT stale ==="
# One variable changed: the verdict. This is the direction that would retire
# live work, so it is the one that must never regress.
pp=$(build_tree "T=$RUN_REF; sleep 20") || exit 2
read -r c10 _ r10 _ _ s10 _ < <(walk "$pp")
ck "still reliable" "$r10" "1"
ck "still counted" "$c10" "1"
ck "a running job keeps the exemption" "$s10" "0"

echo "=== case 11: case 7 with NO job named at all -> untouched by #1208 ==="
# One variable changed: no token anywhere. The orchestrator's own
# `until … watcher-supervisor` loop is exactly this shape, and was measured
# UNCHANGED by the fix on 2026-08-30.
# BOUNDED, AND STILL A LOOP (your-org/nexus-code#1472 item 1, your-nexus#373).
# This was `until false; do sleep 19; done` — the file's ONLY unbounded plant,
# and the source of 110 leaked processes. Its five siblings all bound
# themselves (`sleep 20` at three build_tree sites, `timeout 20 … & sleep 20`
# at a fourth, `sleep 18 & sleep 20` at the scripted one), so the cleanup note
# at the top of this file — "every planted process also carries its own `sleep`
# bound, so a failed kill self-clears" — described the file's REAL convention
# and was false for exactly one site. It is now true for all six. (Count the
# `build_tree` / `build_tree_scripted` calls rather than trusting this
# sentence: an earlier draft of it said four and five.)
#
# The loop SHAPE is load-bearing and must not collapse to a bare `sleep`: this
# case exists to show a pane naming no job at all is untouched by #1208, and
# the orchestrator's own `until … watcher-supervisor` loop is exactly this
# shape. So it keeps the `until`/`sleep` form and only acquires a finite
# lifetime — two iterations, ~38 s, which outlives the single `walk` below by a
# wide margin and still expires well before it is litter. That is longer than
# the siblings' 20 s and comfortably inside `_plant_life`
# (`th_deadline 30` + 20), so the mid script still outlives it.
#
# NO COMMAND SUBSTITUTION IN THIS STRING. `build_tree` writes it through an
# UNQUOTED heredoc, so a `$(…)` or backtick here is substituted ONCE at
# stub-write time and a constant is baked in (your-org/nexus-code#1157). The
# arithmetic form below expands nothing.
pp=$(build_tree "n=0; until (( ++n > 2 )); do sleep 19; done") || exit 2
read -r c11 _ r11 _ _ s11 _ < <(walk "$pp")
ck "still reliable" "$r11" "1"
ck "still counted as work in flight" "$c11" "1"
ck "and never stale — nothing to resolve" "$s11" "0"

echo "=== case 11b: the work CAP fails toward NOT-stale, never toward stale ==="
# Resolution is bounded because each ref costs an external `timeout 5` call and
# a 4 KB argv could name many. A bound that BOUGHT its speed by guessing
# `stale` would manufacture retirements, so the direction is pinned here rather
# than trusted. Differential: same tree, cap the only variable.
plant ar-eeeeeeeeeeee 2 1 >/dev/null
TWO="T1=$DIED_REF T2=$(ref_of ar-eeeeeeeeeeee); sleep 20"
pp=$(build_tree "$TWO") || exit 2
_PANE_ASYNCRUN_MAX_REFS=8 read -r _ _ rA _ _ sA _ < <(_PANE_ASYNCRUN_MAX_REFS=8 walk "$pp")
ck "reliable, cap generous" "$rA" "1"
ck "two died jobs under a generous cap -> stale" "$sA" "1"
read -r _ _ rB _ _ sB _ < <(_PANE_ASYNCRUN_MAX_REFS=1 walk "$pp")
ck "reliable, cap tight" "$rB" "1"
ck "SAME tree, cap exceeded -> NOT stale (bounds work, never invents a retirement)" "$sB" "0"
got=$(_PANE_ASYNCRUN_MAX_REFS=2 _pane_asyncrun_refs \
        "a /s/async-run/w/ar-111111111111 b /s/async-run/w/ar-222222222222 c /s/async-run/w/ar-333333333333" | wc -l)
ck "cap 2 over 3 refs yields 2 refs PLUS the sentinel" "$got" "3"
got=$(_PANE_ASYNCRUN_MAX_REFS=2 _pane_asyncrun_refs \
        "a /s/async-run/w/ar-111111111111 b /s/async-run/w/ar-222222222222 c /s/async-run/w/ar-333333333333" | tail -1)
ck "the truncation sentinel is emitted, not silently dropped" "$got" "!truncated"
_pane_asyncrun_ref_is_died '!truncated' \
  && fail "the truncation sentinel was read as DEAD" \
  || pass "the truncation sentinel is never dead — it disqualifies the root"

# ---------------------------------------------------------------------------
echo "=== case 12: the verdict path — stale shells do not hold the exemption ==="
run_ov() { "$HELPER" --fixture "$1" --window 9 --name testwin --active 0 \
             --heartbeat-file "$WORK/hb.json" "${@:2}" 2>&1; }
printf '{"state":"idle","updated_at":%s}\n' "$(date +%s)" > "$WORK/hb.json"
# CHOOSE THE FIXTURE BY ITS MANIFEST EXPECTATION, NOT BY ITS NAME.
#
# This used to be `for _fx in "$_test_dir"/fixtures/idle-*.ansi`, which picks a
# fixture by FILENAME PREFIX and then relies on that prefix meaning the capture
# classifies as `idle` — the exact scheme `#1176` removed, re-instantiated by me
# inside the change that removes it. Found by grepping my own diff for a second
# instance after the skeptic found the first (`#1214` F2). A fix can
# re-instantiate the defect class it closes, and this branch did it twice.
#
# The manifest is the expectation. The BARE row (env `-`, args `-`) is the one
# that speaks for the fixture read with no scenario, which is how this case
# reads it. No pipe into `head`: an early-exit reader would enrol this file in
# early-exit-readers.manifest, and removing it is the fix rather than recording
# it.
MAN="$_test_dir/pane-state-fixtures.manifest"
FIX=""
if [[ -r "$MAN" ]]; then
    while IFS=$'\t' read -r _mf _mw _me _ma _mr; do
        [[ "$_mw" == "idle" && "$_me" == "-" && "$_ma" == "-" ]] || continue
        [[ -f "$_test_dir/fixtures/$_mf" ]] || continue
        FIX="$_test_dir/fixtures/$_mf"; break
    done < <(grep -vE '^[[:space:]]*(#|$)' "$MAN")
fi
if [[ -z "$FIX" ]]; then
    th_skip "case 12 (verdict path)" "no fixture in pane-state-fixtures.manifest has a bare expectation of idle"
else
    C12=6
    o=$(run_ov "$FIX" --bg-shells 1 --bg-oldest-start 1 --bg-stale 0)
    ck "1 shell, 0 stale -> working-background" "$(field "$o" state)" "working-background"
    ck "and bg_stale is reported even at 0 (asked, none stale)" "$(field "$o" bg_stale)" "0"
    o=$(run_ov "$FIX" --bg-shells 1 --bg-oldest-start 1 --bg-stale 1)
    st=$(field "$o" state)
    if [[ "$st" == "working-background" ]]; then
        fail "1 shell, 1 stale still claimed work in flight — #1208 is NOT fixed"
    else
        pass "1 shell, 1 stale -> no longer working-background (got '$st')"
    fi
    o=$(run_ov "$FIX" --bg-shells 2 --bg-oldest-start 1 --bg-stale 1)
    ck "2 shells, 1 stale -> STILL working-background (one is live)" \
       "$(field "$o" state)" "working-background"
    ck "and the stale one is reported" "$(field "$o" bg_stale)" "1"
    o=$(run_ov "$FIX" --bg-shells 1 --bg-oldest-start 1 --bg-stale 9)
    st=$(field "$o" state)
    if [[ "$st" == "working-background" ]]; then
        fail "stale > shells still claimed work in flight"
    else
        pass "stale > shells floors at zero, does not underflow (got '$st')"
    fi
fi

# ---------------------------------------------------------------------------
echo "=== case 13: what did NOT change — the kill allowlist is untouched ==="
# The fix had to land in CLASSIFICATION. A fix that instead taught the guard to
# authorise `working-background` would pass every case above and be exactly the
# wrong change.
# shellcheck disable=SC1090
source "$BK"
ck "working-background is STILL not kill-authorized" \
   "$(bk_pane_kill_authorized working-background && echo yes || echo no)" "no"
ck "empty is STILL not kill-authorized (don't-know-yet)" \
   "$(bk_pane_kill_authorized empty && echo yes || echo no)" "no"
ck "idle IS kill-authorized, as before" \
   "$(bk_pane_kill_authorized idle && echo yes || echo no)" "yes"

echo "=== case 14: retire-preflight still refuses a genuine working-background ==="
if [[ -x "$PREFLIGHT" ]]; then
    o=$("$PREFLIGHT" --pane-state working-background nosuchwindow-1208 2>&1)
    case "$o" in
        *safe=0*) pass "retire-preflight still refuses working-background" ;;
        *)        fail "retire-preflight no longer refuses working-background: $o" ;;
    esac
else
    echo "  SKIP: retire-preflight.sh not executable" >&2
fi

# ---------------------------------------------------------------------------
# EXPECTED-COUNT GUARD (your-org/nexus-code#807). A vanished loop body or an
# early `return` leaves a GREEN suite that asserted less than it claims, and no
# other check here would notice. Derived per case rather than pinned to a
# literal, so the number cannot silently drift:
#   3 (c1) + 2 (c2) + 2 (c3) + 2 (c4) + 6 (c5) + 2 (c6)
# + 3 (c7) + 3 (c8) + 2 (c9) + 3 (c10) + 3 (c11) + 7 (c11b)
# + C12 (6, or 0 when the fixture is absent and the case th_skips)
# + 3 (c13) + 1 (c14)
EXPECTED=$(( 3 + 2 + 2 + 2 + 6 + 2 + 3 + 3 + 2 + 3 + 3 + 7 + C12 + 3 + 1 ))
if (( PASS + FAIL != EXPECTED )); then
    printf '  FAIL: ASSERTION COUNT MISMATCH — %d ran, %d expected. An assertion did not execute.\n' \
        "$(( PASS + FAIL ))" "$EXPECTED" >&2
    _th_fail
fi

th_summary_and_exit
