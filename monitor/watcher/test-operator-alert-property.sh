#!/usr/bin/env bash
# test-operator-alert-property.sh — the operator-alert EMAIL CONTRACT, checked
# over seeded random schedules rather than hand-picked ones
# (your-org/nexus-code#1653 round 4).
#
# Three review rounds each fixed one schedule and broke another (a latch that
# dropped a third outage, a deferral that silenced a flicker). So the guarantee
# is written down, and every schedule the generator can produce is held to it:
#
#   LIVENESS  every run in which a key's condition stands CONTINUOUSLY at
#             critical for >= L = 900 s has an email for that key within
#             [critical onset - W, critical onset + L], W = 3600 s. An email
#             already sent for the key within the preceding hour counts.
#             L >= REARM_CONFIRM (600 s) + one tick + margin.
#   LIVENESS-C (cumulative; skeptic I1) within a CHAIN — a key's runs whose
#             gaps stay under REARM (7200 s) — and before the chain's first
#             CONFIRMED email: once the RESUMED runs' cumulative critical
#             standing reaches L = 900 s (at T), an email for the key exists in
#             [T - W, T]. This is the G1 bound written down; without it a
#             flicker that never emails passed every seed (all 36 of 1000).
#   SAFETY    any two NON-escalation emails for a key are >= 3600 s apart (so
#             <= 24 per key per day, N = 24), and a key's escalation emails
#             never exceed its runs that turn warning -> critical.
#
# HERMETIC, and a real send is impossible: the push command is a RECORDER, gh
# and mint are stubs, NEXUS_NOTIFY_QUIET is irrelevant because notify.sh is
# never on the path. The clock is an in-process `date` function (FAKE_NOW).
#
# THE MODEL IS THE WATCHER'S: presence is sampled on 60 s ticks, and the
# checker reasons about the SAMPLED schedule — what the module actually saw.
# One stated restriction: the generator never draws an absence in
# [240 s, 420 s], the band around the 300 s clear hold-down where a 60 s tick
# decides whether a dip is a flap or a finalised clear. Outside that band both
# sides of the rule are exercised (short dips flap, long gaps resume/begin).
#
# Usage: test-operator-alert-property.sh [--seeds N] [--jobs J] [--seed S]
#   default N=24 random seeds (PROP_SEEDS) + the fixed schedules day/third/
#   flicker; the evidence run is --seeds 1000.
# On a violation: prints the seed, the invariant, the sampled schedule and the
# emails, and the one-line reproducer (--seed S).

set -uo pipefail
_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
_repo_root=$(cd "$_test_dir/../.." && pwd)
MODULE="$_test_dir/_operator_alert.sh"

# ---- POPULATION DECLARATION (your-org/nexus-code#1078) --------------------
. "$_test_dir/../_guard_population.sh"
gp_population() { printf '%s\n' "$MODULE"; }
gp_handle "$@"

# DEFAULT is sized for the unit band's 600 s per-suite ceiling (~16 s per 8 h
# seed under load, measured): the 3 fixed schedules + 1 regression seed + 24 random seeds: measured 286 s for
# 4 fixed + 8 random at load ~57, and 557 s for the main suite alone at the
# same load, so the band default is kept small and everything runs in parallel. The
# contract's evidence run is `--seeds 1000` (or more), launched separately and
# logged; the band re-checks a sample every time. Seeds are 1..N, so any run's
# seed set is a prefix of the evidence run's.
SEEDS="${PROP_SEEDS:-24}"; JOBS="${PROP_JOBS:-8}"; ONE=""; WORKER=""
while (( $# > 0 )); do
    case "$1" in
        --seeds)  SEEDS="$2"; shift 2 ;;
        --jobs)   JOBS="$2"; shift 2 ;;
        --seed)   ONE="$2"; shift 2 ;;
        --worker) WORKER="$2"; shift 2 ;;   # internal: run the seeds listed in file $2
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 missing"; exit 77; }

TICK=60 L=900 W=3600 RATE=3600

# ---- the generator (seeded; prints `t<TAB>key<TAB>state` rows, state ∈
#      absent|warning|critical, plus `t<TAB>-<TAB>restart`) -------------------
gen() {   # <seed> → schedule on stdout, sampled on $TICK ticks
python3 - "$1" "$TICK" <<'PY'
import random, sys
seed, tick = sys.argv[1], int(sys.argv[2])
H = 3600
def fixed(name):
    # minute-resolution presence for auth-expired, the skeptic's rig2 shapes
    if name == 'day':      # 07:56:14 origin; real presence windows of 2026-09-27
        on = lambda o: (300 <= o < 7946) or (8784 <= o < 8877) or (14626 <= o < 14811)
        return 15360, on
    if name == 'third':
        on = lambda o: (o < 60*60) or (90*60 <= o < 150*60) or (o >= 180*60)
        return 400*60, on
    if name == 'flicker':
        on = lambda o: (o < 60*60) or (o >= 70*60 and ((o//60 - 70) % 14) < 8)
        return 240*60, on
    if name == 'warnfirst':
        # the SERVICE-shaped key: a WARNING incident (sends no email), cleared,
        # then a CRITICAL run from +20 min standing 30 min. It must email at
        # +30 min; a warning `began` that recorded a last_email would rate-cap
        # it to +60 min, outside its LIVENESS window (mutant M22 survived the
        # random seeds — this schedule is the targeted kill).
        st = lambda o: 'warning' if o < 10*60 else ('critical' if 20*60 <= o < 50*60 else 'absent')
        return 60*60, ('svc-prop', st)
    return None
f = fixed(seed)
rows = []
if f:
    end, on = f
    for t in range(0, end + 1, tick):
        if isinstance(on, tuple): rows.append((t, on[0], on[1](t)))
        else: rows.append((t, 'auth-expired', 'critical' if on(t) else 'absent'))
else:
    rng = random.Random(int(seed))
    end = 8 * H
    def durations(present):
        # gaps from seconds to hours; never in the tick-ambiguous [240, 420] band
        while True:
            r = rng.random()
            if present:
                d = rng.choice([rng.randint(30, 590), rng.randint(600, 1800), rng.randint(1800, 3 * H)])
            else:
                d = rng.choice([rng.randint(10, 239), rng.randint(421, 1800), rng.randint(1800, 3 * H), rng.randint(2 * H, 4 * H)])
            yield d
    for key, sevmode in (('auth-expired', 'critical'), ('svc-prop', 'mixed')):
        t, present, gen_ = 0, rng.random() < 0.5, None
        segs = []
        while t < end:
            dg = durations(present); d = next(dg)
            if present:
                if sevmode == 'critical': plan = ('critical', None)
                else:
                    k = rng.choice(['critical', 'warning', 'escalate'])
                    plan = (k, t + rng.randint(1, max(1, d - 1)) if k == 'escalate' else None)
                segs.append((t, t + d, plan))
            t += d; present = not present
        for t in range(0, end + 1, tick):
            st = 'absent'
            for (a, b, (k, esc_at)) in segs:
                if a <= t < b:
                    if k == 'escalate': st = 'critical' if t >= esc_at else 'warning'
                    else: st = k
                    break
            rows.append((t, key, st))
    for _ in range(rng.randint(0, 6)):
        rows.append((rng.randrange(0, end, tick), '-', 'restart'))
rows.sort(key=lambda r: (r[0], r[1] != '-'))
for t, k, s in rows: print(f"{t}\t{k}\t{s}")
PY
}

# ---- the checker: LIVENESS + SAFETY over the sampled schedule --------------
check() {   # <schedule-file> <emails-file> <seed> → rc 0 ok, 1 violation (explained)
python3 - "$1" "$2" "$3" "$TICK" "$L" "$W" "$RATE" <<'PY'
import sys, collections
sched, emails, seed = sys.argv[1], sys.argv[2], sys.argv[3]
TICK, L, W, RATE = map(int, sys.argv[4:8])
HOLD = 300
pres = collections.defaultdict(list)          # key -> [(t, state)]
for line in open(sched):
    t, k, s = line.rstrip('\n').split('\t')
    if k != '-': pres[k].append((int(t), s))
em = collections.defaultdict(list)            # key -> [(t, kind)]
for line in open(emails):
    p = line.split()
    if len(p) >= 3: em[p[2]].append((int(p[0]), p[1]))
bad = []
for key, seq in pres.items():
    # runs: maximal present stretches, dips shorter than the hold-down MERGED
    runs, cur, last_present = [], None, None
    for t, s in seq:
        if s != 'absent':
            if cur is None or (last_present is not None and t - last_present - TICK >= HOLD):
                if cur: runs.append(cur)
                cur = {'start': t, 'end': t, 'states': []}
            cur['end'] = t; cur['states'].append((t, s)); last_present = t
    if cur: runs.append(cur)
    E = sorted(em.get(key, []))
    # LIVENESS: critical onset c; continuous critical to the run's end
    for r in runs:
        crit = [t for t, s in r['states'] if s == 'critical']
        if not crit: continue
        c = crit[0]
        if r['end'] - c + TICK < L: continue
        # continuous critical from c: every sampled state after c is critical
        if any(s != 'critical' for t, s in r['states'] if t >= c): continue
        globals()['ELIG'] = globals().get('ELIG', 0) + 1
        if not any(c - W <= t <= c + L for t, _ in E):
            bad.append(f"LIVENESS key={key} critical from +{c}s for {r['end']-c+TICK}s: no email in [+{c-W}, +{c+L}]")
    # LIVENESS-C: chains of runs whose gaps stay under REARM. A gap's boundary
    # is decided when the clear FINALISES (~end + tick + hold-down), so gaps in
    # [REARM, REARM + 600] are tick-ambiguous: such a chain is SKIPPED, not
    # guessed. Chains with any non-critical state are skipped too (severity
    # interplay is LIVENESS/escalation's business, above).
    REARM = 7200
    chains, cur_c = [], None
    for i, r in enumerate(runs):
        gap = r['start'] - runs[i-1]['end'] if i else None
        if gap is None or gap > REARM + 600:
            if cur_c: chains.append(cur_c)
            cur_c = {'runs': [r], 'skip': False}
        else:
            if gap >= REARM: cur_c['skip'] = True
            cur_c['runs'].append(r)
    if cur_c: chains.append(cur_c)
    for ch in chains:
        if ch['skip'] or len(ch['runs']) < 2: continue
        if any(s != 'critical' for r in ch['runs'] for _, s in r['states']): continue
        chain_start = ch['runs'][0]['start']
        cum, T = 0, None
        for r in ch['runs'][1:]:
            if cum + (r['end'] - r['start']) >= L:
                T = r['start'] + (L - cum); break
            cum += (r['end'] - r['start']) + TICK     # a cleared episode's full standing
        if T is None: continue
        # EXERCISED: this chain reached T. Correct code has usually CONFIRMED
        # by then (at 600 s cumulative), which satisfies the clause; a code
        # that never accumulates has not, and is checked below.
        globals()['ELIGC'] = globals().get('ELIGC', 0) + 1
        if any(k in ('confirmed', 'resumed-confirmed') and chain_start <= t <= T for t, k in E): continue   # confirmed (latched) by T
        if not any(T - W <= t <= T for t, _ in E):
            bad.append(f"LIVENESS-C key={key} chain from +{chain_start}s: resumed runs reach {L}s cumulative at +{T}s with no email in [+{T-W}, +{T}]")
    # SAFETY: non-escalation emails >= RATE apart; escalations <= warning->critical runs
    ne = [t for t, k in E if k != 'escalated']
    for a, b in zip(ne, ne[1:]):
        if b - a < RATE: bad.append(f"SAFETY key={key} two non-escalation emails {b-a}s apart (+{a}, +{b})")
    transitions = sum(1 for r in runs if any(s == 'warning' for _, s in r['states']) and any(s == 'critical' for _, s in r['states']))
    nesc = sum(1 for _, k in E if k == 'escalated')
    if nesc > transitions: bad.append(f"SAFETY key={key} {nesc} escalation emails > {transitions} warning->critical runs")
    span = seq[-1][0] - seq[0][0] + TICK
    if len(ne) > 24 * span / 86400 + 1: bad.append(f"SAFETY key={key} {len(ne)} non-escalation emails in {span}s (> N=24/day)")
elig = globals().get('ELIG', 0)
if bad:
    print(f"VIOLATION seed={seed}")
    for b in bad: print("  " + b)
    sys.exit(1)
print(f"STATS eligible={elig} eligible_c={globals().get('ELIGC', 0)}")
PY
}

# ---- one seed: drive the REAL module through the production call shapes ----
run_seed() {   # <seed> <workdir> → rc 0 ok, 1 violation, 2 harness error
    local seed="$1" w="$2" t key st prev_t=""
    rm -rf "$w"; mkdir -p "$w/state" "$w/tmp" "$w/root/monitor" "$w/bin"
    export STATE_DIR="$w/state" TMPDIR="$w/tmp" NEXUS_ROOT="$w/root"
    export EMAILS="$w/emails"; : > "$EMAILS"
    cat > "$w/bin/notify-recorder" <<'EOF'
#!/usr/bin/env bash
# records EMAIL ATTEMPTS only: `<fake-now> <kind> <key>`; the email leg always lands
title="$1"; esf=""; pri=routine; shift 2
while (( $# > 0 )); do case "$1" in --email-status-file) esf="$2"; shift 2 ;; --priority) pri="$2"; shift 2 ;; *) shift ;; esac; done
if [[ "$pri" == emergency ]]; then
    k=${title#nexus operator-alert: }; key=${k%% *}; kind=${k##*(}; kind=${kind%)}
    printf '%s %s %s\n' "$FAKE_NOW" "$kind" "$key" >> "$EMAILS"
    [[ -n "$esf" ]] && printf 'ok\n' > "$esf"
else
    [[ -n "$esf" ]] && printf 'skipped\n' > "$esf"
fi
exit 0
EOF
    chmod +x "$w/bin/notify-recorder"
    export _OPERATOR_ALERT_PUSH_CMD="$w/bin/notify-recorder" MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false
    export _OPERATOR_ALERT_NETWORK_SYNC=1 MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=300
    unset NEXUS_NOTIFY_QUIET MONITOR_OPERATOR_ALERT_REMINDER_SECONDS
    gen "$seed" > "$w/schedule" || { echo "HARNESS-ERROR seed=$seed: the generator failed"; return 2; }
    # A fresh watcher per seed: the in-process memo starts empty. (The module
    # is sourced ONCE per process, below; its state lives in STATE_DIR/TMPDIR,
    # which are fresh per seed.)
    _OPERATOR_ALERT_MEMO=(); _OPERATOR_ALERT_COMMENT_MEMO=()
    local base=1790520974
        while IFS=$'\t' read -r t key st; do
            export FAKE_NOW=$(( base + t ))
            if [[ "$key" == - ]]; then
                # a WATCHER RESTART: the in-process memo dies with the process,
                # and the $TMPDIR memo goes too — only the state dir survives
                _OPERATOR_ALERT_MEMO=(); _OPERATOR_ALERT_COMMENT_MEMO=()
                rm -f "$TMPDIR"/.nexus-operator-alert.* 2>/dev/null
                continue
            fi
            if [[ "$st" == absent ]]; then
                # The production shape (the auth hold): clear only while the key
                # stands. With no stamp (and, here, no memo — the state dir is
                # writable) `clear` is a no-op, so skipping it changes cost only.
                [[ -f "$STATE_DIR/operator-alert/$key.stamp" ]] && _operator_alert clear "$key" "absent"
            elif [[ "$key" == auth-expired ]]; then
                _operator_alert due "$key" && _operator_alert raise "$key" critical "prop"
            else
                _operator_alert due "$key" "$st" && _operator_alert raise "$key" "$st" "prop"
            fi
        done < "$w/schedule"
    # (the loop's own status is its LAST command's — typically a `due && raise`
    # whose `due` said "not due", rc 1 — and is deliberately NOT read)
    # emails carry absolute fake time; the checker wants offsets
    awk -v b=1790520974 '{ printf "%d %s %s\n", $1 - b, $2, $3 }' "$EMAILS" > "$w/emails.rel"
    check "$w/schedule" "$w/emails.rel" "$seed" > "$w/verdict" 2>&1 || {
        cat "$w/verdict"
        echo "  reproduce: bash monitor/watcher/test-operator-alert-property.sh --seed $seed"
        echo "  emails (offset kind key):"; sed 's/^/    /' "$w/emails.rel"
        echo "  schedule transitions (offset key state):"
        awk -F'\t' '$2=="-"{print "    +"$1" restart"; next} {if(last[$2]!=$3){print "    +"$1" "$2" "$3; last[$2]=$3}}' "$w/schedule"
        return 1
    }
    return 0
}

# The driver runs IN this process: the clock is a function (no fork per
# `date +%s`), and the module is sourced once. Every process that drives seeds
# (the parent for the fixed schedules, each worker for its share) gets this.
date() { if [[ "${1:-}" == "+%s" && "${FAKE_NOW:-}" =~ ^[0-9]+$ ]]; then printf '%s\n' "$FAKE_NOW"; else command date "$@"; fi; }
_OPERATOR_ALERT_LOG_FN=: _OPERATOR_ALERT_BELL_FN=:
# shellcheck source=_operator_alert.sh
source "$MODULE" || { echo "cannot source $MODULE" >&2; exit 2; }

WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/opalert-prop-XXXXXX") || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK_ROOT"' EXIT

if [[ -n "$WORKER" ]]; then
    rc=0
    while read -r s; do
        run_seed "$s" "$WORK_ROOT/$s"; r=$?
        if (( r == 0 )); then
            echo "SEED-OK $s $(sed -n 's/^STATS //p' "$WORK_ROOT/$s/verdict") kinds=$(awk '{print $2}' "$WORK_ROOT/$s/emails.rel" | sort | uniq -c | awk '{printf "%s:%s,", $2, $1}')"
        else echo "SEED-FAIL $s rc=$r"; rc=1; fi
    done < "$WORKER"
    exit $rc
fi

if [[ -n "$ONE" ]]; then
    run_seed "$ONE" "$WORK_ROOT/one"; r=$?; echo "  (run_seed rc=$r)"; [[ -n "${PROP_KEEP:-}" ]] && cp -r "$WORK_ROOT/one" "$PROP_KEEP"
    (( r == 0 )) && { echo "  PASS: seed $ONE holds LIVENESS and SAFETY"; exit 0; }
    echo "  FAIL: seed $ONE"; exit 1
fi

# ---- provenance: which tree this evidence is about -------------------------
_ref=$(git -C "$_repo_root" rev-parse HEAD 2>/dev/null || echo unknown)
_dirty=$(git -C "$_repo_root" status --porcelain -- monitor 2>/dev/null | grep -c . || true)
echo "=== property run: ref=${_ref} dirty_monitor_paths=${_dirty:-?} seeds=${SEEDS} jobs=${JOBS} tick=${TICK}s L=${L}s W=${W}s rate=${RATE}s ==="

# ---- the parent reports through the helper LEDGER (summary honesty) --------
. "$_test_dir/_test_helpers.sh"
PASS=0; FAIL=0; SKIP=0
pass() { printf '  PASS: %s\n' "$1"; _th_pass; }
fail() { printf '  FAIL: %s\n' "$1"; _th_fail; }

# ---- fixed schedules first, each with its expected email count -------------
# ---- POSITIVE CONTROLS: the checker must FLAG planted violations ------------
# A property checker that never fires passes every schedule. Before any seed is
# believed, the checker is shown a planted LIVENESS violation (a 20 min critical
# run with no email), a planted SAFETY violation (two emails 60 s apart), and a
# clean control that must NOT be flagged.
echo "=== positive controls: the checker flags planted violations ==="
PC="$WORK_ROOT/pc"; mkdir -p "$PC"
for (( t = 0; t <= 1200; t += 60 )); do printf '%s\tauth-expired\tcritical\n' "$t"; done > "$PC/live.sched"
: > "$PC/none.emails"
if check "$PC/live.sched" "$PC/none.emails" pc-live > "$PC/live.out" 2>&1; then
    fail "PC: a planted LIVENESS violation (20 min critical, no email) was NOT flagged"
elif grep -q '^  LIVENESS key=auth-expired' "$PC/live.out"; then
    pass "PC: a planted LIVENESS violation (20 min critical, no email) is flagged"
else fail "PC: the LIVENESS plant failed for the wrong reason: $(tr '\n' ' ' < "$PC/live.out")"; fi
printf '0 began auth-expired\n60 confirmed auth-expired\n' > "$PC/storm.emails"
if check "$PC/live.sched" "$PC/storm.emails" pc-safe > "$PC/safe.out" 2>&1; then
    fail "PC: a planted SAFETY violation (two emails 60 s apart) was NOT flagged"
elif grep -q '^  SAFETY key=auth-expired two non-escalation emails 60s apart' "$PC/safe.out"; then
    pass "PC: a planted SAFETY violation (two emails 60 s apart) is flagged"
else fail "PC: the SAFETY plant failed for the wrong reason: $(tr '\n' ' ' < "$PC/safe.out")"; fi
printf '0 began auth-expired\n' > "$PC/ok.emails"
if check "$PC/live.sched" "$PC/ok.emails" pc-ok > "$PC/ok.out" 2>&1; then
    pass "PC: CONTROL — the same run WITH its email at +0 is not flagged"
else fail "PC: the clean control was flagged: $(tr '\n' ' ' < "$PC/ok.out")"; fi

# Each fixed schedule / regression seed is driven in the BACKGROUND (they are
# the longest schedules), then judged here once all have finished.
FIXED=( "day 1" "third 3" "flicker 2" "warnfirst 1" "161 -" "615 -" "327 -" )   # <seed> <expected emails | - = any>
for spec in "${FIXED[@]}"; do
    set -- $spec
    run_seed "$1" "$WORK_ROOT/fixed-$1" > "$WORK_ROOT/fixed-$1.out" 2>&1 &
done
wait
echo "=== fixed schedules (the day, the skeptic's third and flicker) and regression seeds ==="
# REGRESSION SEEDS: counterexamples a full evidence run found, kept forever.
#   161 — a deferred confirmation that came due while the key stood at WARNING
#         "confirmed" without emailing, recorded a phantom last_email, and
#         rate-capped the next genuine critical run out of its email (LIVENESS).
#   615 — a resume whose chain confirmation was ALREADY due waited a tick; the
#         episode lasted one tick, so the email was lost until the next resume
#         78 min later (LIVENESS-C). 327 — the same, one tick late (LIVENESS-C).
for spec in "${FIXED[@]}"; do
    set -- $spec
    w="$WORK_ROOT/fixed-$1"
    if ! grep -q . "$w/emails.rel" 2>/dev/null && [[ ! -f "$w/emails.rel" ]]; then
        fail "schedule '$1': no result (the seed did not complete):"; sed 's/^/    /' "$w.out"; continue
    fi
    if grep -q '^VIOLATION\|^HARNESS-ERROR' "$w.out"; then
        fail "schedule '$1' violates an invariant:"; sed 's/^/    /' "$w.out"; continue
    fi
    n=$(grep -c . "$w/emails.rel")
    if [[ "$2" == - ]]; then pass "regression seed $1 holds both invariants ($n email(s))"
    elif [[ "$n" == "$2" ]]; then pass "fixed schedule '$1' holds both invariants, $n email(s) as expected"
    else fail "fixed schedule '$1' holds the invariants but sent $n email(s), want $2"; fi
done

# ---- REMINDER BOUND over long outages (your-org/nexus-code#1713) -----------
# A condition only the operator can clear (a login expiry over a weekend) used
# to remind every hour for as long as it stood. The contract now:
#   BOUND     reminders R over an outage of T s satisfy
#             R <= ceil(log2(MAX/BASE)) + 1 + T/MAX   (O(log T) + T/cap)
#   SCHEDULE  every gap between consecutive announcements is >= the backoff
#             delay owed after the earlier one, min(BASE*2^(n-1), MAX), minus
#             nothing: a gap that SHRINKS back to BASE after a watcher restart
#             is exactly the in-process-memo defect the issue names.
# Each seed draws an outage of 1 h .. 7 d, sampled on 900 s ticks (a divisor
# of every owed delay, so the SCHEDULE clause is exact; coarser than the
# watcher's 5 s to keep a 7-day seed near a minute), with random WATCHER
# RESTARTS (in-process and $TMPDIR memos wiped; only the state dir survives)
# and random one-tick DIPS that the clear hold-down (1800 s here) absorbs as
# flaps. Seeds run in parallel, like the fixed schedules. Then the condition clears and comes back after REARM, and
# the second outage must start its schedule from BASE again (reset on clear).
OB_SEEDS="${PROP_OUTAGE_SEEDS:-8}"; OB_TICK=900; OB_BASE=3600; OB_MAX=86400
outage_gen() {   # <seed> → `t<TAB>state` rows (state ∈ on|dip|off|restart)
python3 - "$1" "$OB_TICK" <<'PY2'
import random, sys
rng = random.Random(int(sys.argv[1]) * 7919 + 13); tick = int(sys.argv[2])
T1 = rng.randint(3600, 7 * 86400) // tick * tick
T2 = rng.randint(3600, 3 * 86400) // tick * tick
gap = 3 * 3600                                  # > REARM (7200 s): a NEW incident
rows = []
for t in range(0, T1, tick):
    rows.append((t, 'dip' if (t > 0 and rng.random() < 0.01) else 'on'))
for t in range(T1, T1 + gap, tick): rows.append((t, 'off'))
for t in range(T1 + gap, T1 + gap + T2, tick): rows.append((t, 'on'))
rows.append((T1 + gap + T2, 'off'))
for _ in range(rng.randint(1, 8)):
    rows.append((rng.randrange(0, T1 + gap + T2, tick), 'restart'))
rows.sort(key=lambda r: (r[0], r[1] != 'restart'))
print(f"#\t{T1}\t{T1 + gap}\t{T2}")
for t, s in rows: print(f"{t}\t{s}")
PY2
}
outage_check() {   # <schedule> <raises: `offset kind n`> <seed> → rc 0 ok, 1 violation
python3 - "$1" "$2" "$3" "$OB_BASE" "$OB_MAX" "$OB_TICK" <<'PY2'
import math, sys
sched, raises, seed = sys.argv[1], sys.argv[2], sys.argv[3]
BASE, MAX, TICK = map(int, sys.argv[4:7])
hdr = open(sched).readline().split('\t'); T1, S2, T2 = int(hdr[1]), int(hdr[2]), int(hdr[3])
R = [(int(a), k) for a, k, *_ in (l.split() for l in open(raises) if l.strip())]
bad = []
def delay(n): return min(BASE * 2 ** (n - 1), MAX) if MAX >= BASE else BASE
for lo, T in ((0, T1), (S2, T2)):
    ev = [(t, k) for t, k in R if lo <= t < lo + T + TICK]
    if not ev or ev[0][1] not in ('began', 'resumed'):
        bad.append(f"outage at +{lo}: first announcement is {ev[:1]} — want a began"); continue
    rem = [t for t, k in ev if k == 'continues']
    bound = math.ceil(math.log2(MAX / BASE)) + 1 + T / MAX
    if len(rem) > bound:
        bad.append(f"BOUND outage at +{lo} lasting {T}s: {len(rem)} reminders > {bound:.2f}")
    for n, ((a, _), (b, _)) in enumerate(zip(ev, ev[1:]), start=1):
        if b - a < delay(n):
            bad.append(f"SCHEDULE outage at +{lo}: announcement {n+1} came {b-a}s after announcement {n} (+{a}), owed >= {delay(n)}s")
    # LIVENESS of the reminder itself: the backoff must not silence a standing
    # outage — once past the first delay, a reminder is owed within MAX + TICK
    t_last = ev[-1][0]
    if lo + T - t_last > max(delay(len(ev)), BASE) + TICK:
        bad.append(f"LIVENESS outage at +{lo}: last announcement at +{t_last}, outage stood until +{lo+T} with none owed-and-sent")
    print(f"OUTAGE lo={lo} T={T} reminders={len(rem)} bound={bound:.2f}")
if bad:
    print(f"VIOLATION seed={seed}")
    for b in bad: print("  " + b)
    sys.exit(1)
PY2
}
run_outage() {   # <seed> <workdir> → rc 0 ok, 1 violation
    local seed="$1" w="$2" t st key=auth-expired base=1790520974
    rm -rf "$w"; mkdir -p "$w/state" "$w/tmp" "$w/root/monitor"
    export STATE_DIR="$w/state" TMPDIR="$w/tmp" NEXUS_ROOT="$w/root"
    export MONITOR_OPERATOR_ALERT_PUSH_ENABLED=false MONITOR_OPERATOR_ALERT_GITHUB_ENABLED=false
    export MONITOR_OPERATOR_ALERT_CLEAR_HOLDDOWN_SECONDS=1800
    unset MONITOR_OPERATOR_ALERT_REMINDER_SECONDS MONITOR_OPERATOR_ALERT_REMINDER_MAX_SECONDS
    _OPERATOR_ALERT_MEMO=(); _OPERATOR_ALERT_COMMENT_MEMO=()
    outage_gen "$seed" > "$w/schedule" || { echo "HARNESS-ERROR seed=$seed"; return 2; }
    while IFS=$'\t' read -r t st; do
        [[ "$t" == '#' ]] && continue
        export FAKE_NOW=$(( base + t ))
        case "$st" in
            restart) _OPERATOR_ALERT_MEMO=(); _OPERATOR_ALERT_COMMENT_MEMO=(); rm -f "$TMPDIR"/.nexus-operator-alert.* 2>/dev/null ;;
            on)      _operator_alert due "$key" && _operator_alert raise "$key" critical "prop" ;;
            dip|off) [[ -f "$STATE_DIR/operator-alert/$key.stamp" ]] && _operator_alert clear "$key" "absent" ;;
        esac
    done < "$w/schedule"
    python3 - "$STATE_DIR/operator-alerts.jsonl" "$base" > "$w/raises" <<'PY2' || { echo "HARNESS-ERROR seed=$seed: no ledger"; return 2; }
import json, sys
b = int(sys.argv[2])
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r.get('event') == 'raise': print(r['ts'] - b, r['kind'], r.get('n', ''))
PY2
    outage_check "$w/schedule" "$w/raises" "$seed" > "$w/verdict" 2>&1 || { cat "$w/verdict"; return 1; }
    return 0
}

echo "=== reminder bound over long outages (#1713): ${OB_SEEDS} seeds, 1 h .. 7 d, restarts + flaps ==="
# POSITIVE CONTROLS for the outage checker: an HOURLY reminder stream (the
# pre-#1713 cadence) must be flagged on both clauses; the backoff schedule on
# the same outage must not be.
OPC="$WORK_ROOT/opc"; mkdir -p "$OPC"
printf '#\t172800\t183600\t3600\n' > "$OPC/sched"
{ echo "0 began 1"; for (( h = 1; h < 48; h++ )); do echo "$(( h * 3600 )) continues $(( h + 1 ))"; done
  echo "183600 began 1"; } > "$OPC/hourly"
if outage_check "$OPC/sched" "$OPC/hourly" opc-hourly > "$OPC/hourly.out" 2>&1; then
    fail "OPC: an HOURLY reminder stream over 48 h was NOT flagged"
elif grep -q '^  BOUND' "$OPC/hourly.out" && grep -q '^  SCHEDULE' "$OPC/hourly.out"; then
    pass "OPC: an hourly reminder stream over 48 h is flagged (BOUND and SCHEDULE)"
else fail "OPC: the hourly plant failed for the wrong reason: $(tr '\n' ' ' < "$OPC/hourly.out")"; fi
{ echo "0 began 1"; for t in 3600 10800 25200 54000 111600; do echo "$t continues x"; done; echo "183600 began 1"; } > "$OPC/backoff"
if outage_check "$OPC/sched" "$OPC/backoff" opc-ok > "$OPC/backoff.out" 2>&1; then
    pass "OPC: CONTROL — the backoff schedule on the same 48 h outage is not flagged"
else fail "OPC: the clean backoff control was flagged: $(tr '\n' ' ' < "$OPC/backoff.out")"; fi
{ echo "0 began 1"; echo "3600 continues 2"; echo "10800 continues 3"; echo "14400 continues 4"; echo "183600 began 1"; } > "$OPC/reset"
if outage_check "$OPC/sched" "$OPC/reset" opc-reset > "$OPC/reset.out" 2>&1; then
    fail "OPC: a schedule that RESET to 1 h mid-outage (a restart forgetting the backoff) was NOT flagged"
elif grep -q '^  SCHEDULE.*announcement 4 came 3600s' "$OPC/reset.out"; then
    pass "OPC: a mid-outage reset to the 1 h base (the restart defect) is flagged"
else fail "OPC: the reset plant failed for the wrong reason: $(tr '\n' ' ' < "$OPC/reset.out")"; fi
ob_ok=0; ob_bad=0; ob_rem=0; ob_maxT=0
for (( s = 1; s <= OB_SEEDS; s++ )); do
    ( run_outage "$s" "$WORK_ROOT/outage-$s" > "$WORK_ROOT/outage-$s.out" 2>&1; echo "$?" > "$WORK_ROOT/outage-$s.rc" ) &
done
wait
for (( s = 1; s <= OB_SEEDS; s++ )); do
    if [[ "$(cat "$WORK_ROOT/outage-$s.rc" 2>/dev/null)" == 0 ]]; then
        (( ob_ok++ ))
        while read -r _ lo T r _; do
            T=${T#T=}; r=${r#reminders=}; (( ob_rem += r )); (( T > ob_maxT )) && ob_maxT=$T
        done < <(grep '^OUTAGE' "$WORK_ROOT/outage-$s/verdict")
    else
        (( ob_bad++ )); fail "outage seed $s:"; sed -n '1,20s/^/    /p' "$WORK_ROOT/outage-$s.out"
        echo "    reproduce: PROP_OUTAGE_SEEDS=$s (seeds are 1..N)"
    fi
done
echo "  coverage: ${ob_ok} seeds, ${ob_rem} reminders in total, longest outage ${ob_maxT}s"
(( ob_rem > 0 )) || fail "0 reminders across every outage seed — a vacuous pass"
(( ob_maxT >= 2 * OB_MAX )) || fail "no outage seed reached 2 x REMINDER_MAX (${ob_maxT}s) — the T/MAX regime was never exercised"
(( ob_bad == 0 && ob_ok == OB_SEEDS )) && pass "all ${OB_SEEDS} outage seeds hold BOUND, SCHEDULE and reminder LIVENESS (restarts and flaps included)"
unset MONITOR_OPERATOR_ALERT_PUSH_ENABLED

# ---- random seeds, in parallel workers --------------------------------------
echo "=== ${SEEDS} random seeds (seeded 1..${SEEDS}; 8 h each; restarts included) ==="
seq 1 "$SEEDS" > "$WORK_ROOT/all"
# Numbered parts (split -d): every file named below is KNOWN to exist, so no
# glob is ever fed to cat/grep (a vanished nullglob would make them read stdin).
split -d -a 3 -n "r/$JOBS" "$WORK_ROOT/all" "$WORK_ROOT/part."
for (( i = 0; i < JOBS; i++ )); do
    f=$(printf '%s/part.%03d' "$WORK_ROOT" "$i")
    bash "$0" --worker "$f" > "$f.out" 2>&1 &
done
wait
ALL="$WORK_ROOT/workers.out"; : > "$ALL"
for (( i = 0; i < JOBS; i++ )); do cat "$(printf '%s/part.%03d.out' "$WORK_ROOT" "$i")" >> "$ALL"; done
ok=$(grep -c '^SEED-OK' "$ALL")
bad=$(grep -c '^SEED-FAIL' "$ALL")
if (( ok + bad != SEEDS )); then fail "accounted for $(( ok + bad )) of $SEEDS seeds — a worker died"; fi
elig=$(sed -n 's/^SEED-OK .* eligible=\([0-9]*\).*/\1/p' "$ALL" | awk '{n+=$1} END{print n+0}')
kinds=$(sed -n 's/^SEED-OK .* kinds=//p' "$ALL" | tr ',' '\n' | awk -F: 'NF==2{n[$1]+=$2} END{for(k in n) printf "%s=%d ", k, n[k]}')
echo "  coverage: ${elig} LIVENESS-eligible runs checked; emails by kind: ${kinds:-none}"
# A property that checked nothing proves nothing: both paths the contract
# exists for must have been REACHED across the seeds.
for need in began confirmed escalated; do
    [[ " $kinds" == *" $need="* ]] || fail "no '$need' email in any seed — the generator never reached that path"
done
(( elig > 0 )) || fail "0 LIVENESS-eligible runs — a vacuous pass"
eligc=$(sed -n 's/^SEED-OK .* eligible_c=\([0-9]*\).*/\1/p' "$ALL" | awk '{n+=$1} END{print n+0}')
echo "  coverage: ${eligc} chains reached ${L} s of cumulative resumed standing (LIVENESS-C exercised)"
(( eligc > 0 )) || fail "0 LIVENESS-C-eligible chains — the cumulative clause checked nothing"
if (( bad == 0 )); then
    pass "all $ok random seeds hold LIVENESS (L=${L}s, W=${W}s) and SAFETY (>=${RATE}s apart, N=24/day)"
else
    fail "$bad of $SEEDS random seeds violate an invariant (first 3 shown):"
    grep -A40 '^VIOLATION' "$ALL" | awk '/^VIOLATION/{n++} n<=3' | sed 's/^/    /'
fi
th_summary_and_exit
