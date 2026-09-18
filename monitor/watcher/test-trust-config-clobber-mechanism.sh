#!/usr/bin/env bash
# your-org/nexus-code#1334 — MECHANISM PROOF, NOT A FIELD REPRODUCTION.
#
# READ THAT LINE AGAIN BEFORE CITING THIS SUITE. It establishes that a freshly
# seeded workspace-trust key CAN be silently lost to a competing writer of
# .claude.json. It does NOT establish that this is what happened in the field
# occurrence on #1334 — that remains open, and the two hypotheses (clobber vs
# `hasTrustDialogAccepted` not being the only gating key) are indistinguishable
# from post-hoc state, because answering the dialog sets the same value.
#
# WHY IT MATTERS: ensure-workdir-trusted.sh takes an fd-9 `flock` and installs
# via an atomic `mv`. Both are CORRECT. This suite shows they are also
# INSUFFICIENT — a writer that honours neither (which is what the script's own
# header says `claude` itself is) can drop the key with no error anywhere. If
# that holds, no discipline at the WRITE site can fix this, and the remedy
# belongs at the verify/re-seed layer. That conclusion is the point of the
# suite, and it needs no live spawn and no `claude` process.
#
# DETERMINISTIC BY CONSTRUCTION: the competing writer blocks on a MARKER FILE
# rather than sleeping, so the interleaving is fixed and this cannot flake
# under load. A sleep-based race would be exactly the "passes on my machine"
# defect this repo keeps filing.
#
# Run: bash monitor/watcher/test-trust-config-clobber-mechanism.sh
set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$_test_dir/_test_helpers.sh"

EWT="$_test_dir/../ensure-workdir-trusted.sh"
EXPECTED_ASSERTIONS=11

command -v jq >/dev/null 2>&1 || { echo "test: jq required" >&2; exit 2; }
[ -x "$EWT" ] || { echo "test: not executable: $EWT" >&2; exit 2; }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

trust_of() {  # $1=cfg  $2=workdir
    jq -r --arg d "$2" '.projects[$d].hasTrustDialogAccepted // "ABSENT"' "$1" 2>/dev/null
}

# A competing writer with STALE in-memory state: read -> wait for the seed to
# finish -> write its stale copy back. It takes no lock and does no rename,
# which is the entire point: the seeder's discipline is unilateral.
make_competitor() {
    cat > "$WORK/competitor.sh" <<'COMP'
#!/usr/bin/env bash
cfg="$1"; go="$2"
stale=$(cat "$cfg")
while [ ! -e "$go" ]; do sleep 0.05; done
printf '%s\n' "$stale" > "$cfg"
COMP
    chmod +x "$WORK/competitor.sh"
}
make_competitor

echo '=== ARM 1: a stale competing writer DROPS the freshly seeded key ==='
A="$WORK/a"; mkdir -p "$A/cfg" "$A/wd"; AWD=$(cd "$A/wd" && pwd -P)
jq -n '{projects:{"/pre/existing":{hasTrustDialogAccepted:true}},theme:"dark"}' > "$A/cfg/.claude.json"

"$WORK/competitor.sh" "$A/cfg/.claude.json" "$A/go" &   # reads NOW, writes after $A/go
comp=$!
sleep 0.3                                                # let it complete its read
seed_out=$(CLAUDE_CONFIG_DIR="$A/cfg" "$EWT" "$AWD" 2>&1); seed_rc=$?
mid=$(trust_of "$A/cfg/.claude.json" "$AWD")
touch "$A/go"; wait "$comp"
after=$(trust_of "$A/cfg/.claude.json" "$AWD")

assert_eq "the seed itself SUCCEEDS (rc 0)" "$seed_rc" "0"
assert_contains "…and REPORTS success" "$seed_out" "seeded workspace trust"
assert_eq "the key IS true immediately after the seed" "$mid" "true"
# THE FINDING. Every artefact above says the seed worked; the key is gone.
assert_eq "…and is GONE once the competitor flushes its stale copy" "$after" "ABSENT"
# Distinguishes "key lost" from "file corrupted" — the field signature is the
# former: everything else in the config is intact.
assert_eq "the config is still valid JSON afterwards" \
    "$(jq -e . "$A/cfg/.claude.json" >/dev/null 2>&1 && echo ok)" "ok"
assert_eq "an entry present in the STALE copy survives" \
    "$(trust_of "$A/cfg/.claude.json" "/pre/existing")" "true"

echo '=== ARM 2: CONTROL — no competing writer, same elapsed time ==='
# Without this the ARM 1 result proves nothing: an ABSENT key could be the
# seeder failing, or time passing, rather than the race.
B="$WORK/b"; mkdir -p "$B/cfg" "$B/wd"; BWD=$(cd "$B/wd" && pwd -P)
jq -n '{projects:{"/pre/existing":{hasTrustDialogAccepted:true}}}' > "$B/cfg/.claude.json"
CLAUDE_CONFIG_DIR="$B/cfg" "$EWT" "$BWD" >/dev/null 2>&1
sleep 0.3
assert_eq "the key SURVIVES when nothing races it" "$(trust_of "$B/cfg/.claude.json" "$BWD")" "true"

echo '=== ARM 3: the seeder holds a lock the competitor never asks for ==='
# Why ARM 1 is not fixable at the write site: the lock is real and uncontended,
# so the competing writer is not waiting on it — it does not know it exists.
C="$WORK/c"; mkdir -p "$C/cfg" "$C/wd"; CWD=$(cd "$C/wd" && pwd -P)
jq -n '{projects:{}}' > "$C/cfg/.claude.json"
CLAUDE_CONFIG_DIR="$C/cfg" "$EWT" "$CWD" >/dev/null 2>&1
assert_eq "the seeder DOES create its lock file" \
    "$([ -e "$C/cfg/.claude.json.nexus-trust.lock" ] && echo yes || echo no)" "yes"
# The competitor above is a faithful stand-in precisely because it never opens
# this path. Assert that, so a future edit that makes it lock-aware is caught
# and this suite stops silently proving something weaker than it claims.
assert_eq "the competitor stand-in references no lock (else this proves less)" \
    "$(grep -c 'nexus-trust.lock' "$WORK/competitor.sh")" "0"

echo '=== ARM 4: would flock HELP if the other writer took it? ==='
# THE QUESTION THAT DECIDES WHERE THE REMEDY GOES. If a lock-aware competitor
# cannot lose the key, the gap is an UNCOORDINATED WRITER, not a missing lock —
# and nothing added at ensure_trusted's write site can close it, because the
# fix would have to be applied to the OTHER process. That is what moves the
# remedy to the verify/re-seed layer. If instead the key were lost even against
# a lock-aware competitor, the seeder's own locking would be at fault and the
# fix would belong here.
#
# THE LOCK DOES THE SEQUENCING, NOT A MARKER. An earlier attempt gave the
# lock-aware competitor a marker to wait on and DEADLOCKED: it held the lock
# while waiting for a marker that only appears after a seed which was itself
# blocked on that lock. That deadlock measured the harness, not the mechanism.
cat > "$WORK/competitor_locking.sh" <<'COMPL'
#!/usr/bin/env bash
cfg="$1"
exec 9>"${cfg}.nexus-trust.lock"
flock 9                       # the ONE difference from the stand-in above
stale=$(cat "$cfg")
sleep 0.5                     # hold stale state INSIDE the critical section
printf '%s\n' "$stale" > "$cfg"
exec 9>&-
COMPL
chmod +x "$WORK/competitor_locking.sh"

D="$WORK/d"; mkdir -p "$D/cfg" "$D/wd"; DWD=$(cd "$D/wd" && pwd -P)
jq -n '{projects:{}}' > "$D/cfg/.claude.json"
"$WORK/competitor_locking.sh" "$D/cfg/.claude.json" &
compl=$!
sleep 0.1                                       # ensure it holds the lock first
CLAUDE_CONFIG_DIR="$D/cfg" "$EWT" "$DWD" >/dev/null 2>&1
wait "$compl"
assert_eq "a LOCK-AWARE competitor cannot lose the key (flock WOULD have helped)" \
    "$(trust_of "$D/cfg/.claude.json" "$DWD")" "true"
# Non-vacuity: the two competitors must differ ONLY in taking the lock, or
# ARM 1 vs ARM 4 is comparing two unrelated programs.
assert_eq "the locking competitor differs from the stand-in by TAKING the lock" \
    "$(grep -c 'flock 9' "$WORK/competitor_locking.sh")" "1"

# ---- verdict ------------------------------------------------------------
_total=$(( ${PASS:-0} + ${FAIL:-0} ))
if [[ "$_total" -ne "$EXPECTED_ASSERTIONS" ]]; then
    printf '  FAIL: assertion COUNT drifted — ran %d, expected %d\n' "$_total" "$EXPECTED_ASSERTIONS" >&2
    FAIL=$(( ${FAIL:-0} + 1 ))
else
    printf '  PASS: every declared assertion executed (%d)\n' "$_total"
    PASS=$(( ${PASS:-0} + 1 ))
fi

th_summary_and_exit
