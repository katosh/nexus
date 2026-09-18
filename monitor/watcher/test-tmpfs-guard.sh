#!/usr/bin/env bash
# test-tmpfs-guard.sh — the /tmp reaper removes ONLY what every predicate axis
# admits, the guard fails LOUD over threshold, and mutation-gate.sh no longer
# leaks its workdir (your-org/nexus-code tmpfs leak, 2026-09-03).
#
# Each axis of the safety predicate in monitor/tmpfs-guard.sh is planted as its
# own directory in a fixture root, so a regression on any ONE axis turns
# exactly one assertion red and names it. The positive control is the set of
# four leaking families that MUST be removed: a reaper that removes nothing
# passes every "kept" assertion and is worthless, which is why the removals are
# asserted first.
#
# Potency control (run by hand, recorded in the PR): point TMPFS_GUARD_MG at
# the pre-fix `git show origin/dev:monitor/mutation-gate.sh` and the two
# mutation-gate assertions go red; `monitor/mutation-gate.sh --suite <this>
# --list` enumerates the deletable lines for the standard gate.
#
# Run: bash monitor/watcher/test-tmpfs-guard.sh
# Expected: ALL TESTS PASSED, exit 0.
set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
GUARD="$REPO_ROOT/monitor/tmpfs-guard.sh"
MG="${TMPFS_GUARD_MG:-$REPO_ROOT/monitor/mutation-gate.sh}"

. "$_test_dir/_test_helpers.sh"
EXPECTED_ASSERTIONS=81   # +4: your-org/nexus-code#1490 — emit_both does not truncate an
                         #     append-opened log, with a potency arm on the pre-fix construct.
                         # +35: your-org/nexus-code#1423 — the pressure trigger, its bands,
                         # the two protocol lines, owner attribution, and the
                         # regression that an ENTRY COUNT can no longer trip anything

# Short root: tmux/socket paths are measured against sun_path elsewhere, and a
# socket is planted below, so the fixture stays under /tmp, never the scratchpad.
ROOT=$(mktemp -d /tmp/tg.XXXXXX) || { echo "mktemp failed"; exit 1; }
export NEXUS_STATE_DIR="$ROOT/.state"
# Fixture-local state, and NO live config: every knob is passed as a flag so the
# operator's config/nexus.yml cannot change what this suite measures.
cleanup() { exec 7>&- 2>/dev/null; kill "${_HOLD_PID:-}" 2>/dev/null; rm -rf -- "$ROOT"; }
trap cleanup EXIT

old() {   # <path>… — age every entry (and its contents) 3 days
    find "$@" -exec touch -h -d '3 days ago' -- {} + 2>/dev/null
}
plant() {   # <name> [<bytes>] -> dir with one payload file
    local d="$ROOT/$1" n="${2:-4096}"
    mkdir -p -- "$d/sub"
    head -c "$n" /dev/zero > "$d/sub/payload.bin"
    printf '%s' "$d"
}

# ── the population ──────────────────────────────────────────────────────────
A=$(plant olay-guard-aaaaaaaa 65536); old "$A"                # leak family, old  → REMOVE
B=$(plant mutgate-4242);            old "$B"                # leak family, old  → REMOVE
C=$(plant tmp.AbCdEfGhIj);          old "$C"                # bare mktemp, old  → KEEP (not a default family: the watcher's own scratch is tmp.*)
D=$(plant tt-99999);                old "$D"                # SIGKILLed suite   → REMOVE
Y=$(plant olay-guard-bbbbbbbb)                              # young             → keep
H=$(plant olay-guard-cccccccc);     old "$H"                # old but HELD OPEN → keep
exec 7>>"$H/sub/payload.bin"
U=$(plant leaky-unknown-1);         old "$U"                # unregistered name → keep
S=$(plant olay-guard-dddddddd);     old "$S"                # holds a SOCKET    → keep
python3 - "$S/sub/x.sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()   # a socket FILE, not bound
PY
old "$S"
F=$(plant olay-guard-ffffffff);     old "$F"                # old at the TOP, fresh content 3 levels down → keep
mkdir -p "$F/sub/deep"; : > "$F/sub/deep/fresh.txt"; find "$F" -type d -exec touch -h -d '3 days ago' -- {} +   # dirs aged, the FILE stays fresh
G=$(plant olay-guard-gggggggg);     old "$G"                # old, held ONLY in a child's ENVIRONMENT → keep
HOLD_DIR="$G/sub" sleep 600 & _HOLD_PID=$!
N=$(plant "olay-guard-nl$(printf '\n')nl"); old "$N"       # NEWLINE in the name: must be handled, never phantom-logged → REMOVE
DN=$(plant c71780 3145728);         old "$DN"               # denylisted root   → keep
DC=$(plant claude-71780);           old "$DC"               # denylisted root   → keep
mkdir -p "$ROOT/.nexus-trash"
T_OLD="$ROOT/.nexus-trash/old-binary.20260801"; mkdir -p "$T_OLD"; : > "$T_OLD/f"; old "$T_OLD"
T_NEW="$ROOT/.nexus-trash/fresh-binary";        mkdir -p "$T_NEW"; : > "$T_NEW/f"
P_OLD="$ROOT/.th-ports.4242";  : > "$P_OLD"; old "$P_OLD"      # helper dotFILE, old → REMOVE
P_NEW="$ROOT/.th-ports.4243";  : > "$P_NEW"                    # helper dotfile, young → keep

# Sanity: the plants exist before any absence below is believed.
assert_file_exists "positive control: old leak planted"   "$A/sub/payload.bin"
assert_file_exists "positive control: held file planted"  "$H/sub/payload.bin"
[ -S "$S/sub/x.sock" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL: socket plant missing"; }

# ── refusal: no live-reference list means no removal ────────────────────────
out=$("$GUARD" --reap --root "$ROOT" --inuse-file "$ROOT/no-such-list" 2>&1); rc=$?
assert_rc          "reap REFUSES without a readable in-use list" "$rc" 3
assert_file_exists "…and removed nothing"                        "$A/sub/payload.bin"

# ── dry run: plan only ──────────────────────────────────────────────────────
out=$("$GUARD" --reap --dry-run --root "$ROOT" 2>&1); rc=$?
assert_rc       "dry-run rc"                         "$rc" 0
assert_eq       "dry-run plans exactly the 5 leaks"  "$(printf '%s\n' "$out" | grep -c '^would-remove')" 5
assert_contains "dry-run names the trash sweep"      "$out" "would-run    _trash.sh --clear"
assert_file_exists "dry-run removed nothing"         "$A/sub/payload.bin"

# ── the real reap, live /proc walk (this process holds fd 7 on $H) ──────────
out=$("$GUARD" --reap --root "$ROOT" --trash-days 1 2>&1); rc=$?
assert_rc      "reap rc"                                  "$rc" 0
assert_no_file "REMOVED: old olay-guard-*"                "$A"
assert_no_file "REMOVED: old mutgate-*"                   "$B"
assert_file_exists "KEPT: bare tmp.* is not a default family (watcher scratch residual)" "$C/sub/payload.bin"
assert_file_exists "KEPT: top-level old, FRESH content three levels down"  "$F/sub/deep/fresh.txt"
assert_contains    "…and the kept reason names the fresh path"             "$out" "fresh-content-or-socket:sub/deep/fresh.txt"
assert_file_exists "KEPT: held only in a live child's ENVIRONMENT"         "$G/sub/payload.bin"
assert_no_file     "REMOVED: newline-named entry, handled via NUL-delimited enumeration" "$N"
assert_eq          "…and no phantom 'removed' line for a path that never existed" "$(grep -c "removed $ROOT/olay-guard-nl bytes" "$NEXUS_STATE_DIR/tmpfs-guard.log")" 0
assert_no_file "REMOVED: old tt-<pid>"                    "$D"
assert_file_exists "KEPT: young leak-family dir"          "$Y/sub/payload.bin"
assert_file_exists "KEPT: old dir with a file HELD OPEN"  "$H/sub/payload.bin"
assert_file_exists "KEPT: unregistered family"            "$U/sub/payload.bin"
# -S, not assert_file_exists: that helper tests -f, and a socket is not a
# regular file — the assertion's shape would fail a kept socket.
if [ -S "$S/sub/x.sock" ]; then PASS=$((PASS+1)); echo "  PASS: KEPT: dir holding a socket file"; else FAIL=$((FAIL+1)); echo "  FAIL: KEPT: dir holding a socket file — gone: $S"; fi
# The denylist is witnessed by MISCONFIGURING the allowlist to include the
# denylisted names: with normal families these names are rejected by the
# allowlist first, so the deny arm never runs and an assertion here could not
# fail if the denylist were deleted (skeptic mutant M3, 35/35 with no denylist).
TMPFS_REAP_FAMILIES='^c71780$ ^claude-71780$' "$GUARD" --reap --root "$ROOT" --trash-days 1 >/dev/null 2>&1
assert_file_exists "KEPT: denylisted c71780 even when the allowlist names it"      "$DN/sub/payload.bin"
assert_file_exists "KEPT: denylisted claude-71780 even when the allowlist names it" "$DC/sub/payload.bin"
assert_no_file     "REMOVED: old helper dotfile .th-ports.*"  "$P_OLD"
assert_file_exists "KEPT: young helper dotfile"               "$P_NEW"
assert_no_file     "TRASH: old entry cleared (_trash.sh finally has a caller)" "$T_OLD"
assert_file_exists "TRASH: fresh entry kept"              "$T_NEW/f"
assert_contains    "summary counts the five removals"     "$out" "removed=5"
assert_contains    "log records the predicate per removal" "$(cat "$NEXUS_STATE_DIR/tmpfs-guard.log")" "unreferenced=yes"

# ── --check: MEMORY PRESSURE, never inventory (your-org/nexus-code#1423) ────
# `df` answers about the FILESYSTEM, not about the fixture directory, so a
# capacity band cannot be planted — it is DERIVED from the live figure and the
# thresholds are set around it. That makes every assertion below deterministic
# without pretending the fixture controls the mount.
USED_PCT=$(df -P -- "$ROOT" 2>/dev/null | awk 'NR==2 { gsub("%","",$5); print $5 }')
[[ "$USED_PCT" =~ ^[0-9]+$ ]] || { echo "SKIP: could not read df used% for $ROOT"; USED_PCT=""; }

if [[ -n "$USED_PCT" ]] && [ "$USED_PCT" -lt 99 ]; then
    QUIET_WARN=$(( USED_PCT + 1 ))
    out=$("$GUARD" --check --root "$ROOT" --warn-pct "$QUIET_WARN" --high-pct 100 --critical-pct 100 \
                   --mem-avail-low-pct 0 --max-inode-pct 101 --max-c71780-mib 100000 2>/dev/null); rc=$?
    assert_rc       "under every threshold the check is SILENT (rc 0)" "$rc" 0
    assert_contains "…and the healthy line still REPORTS the entry counts as context" "$out" "context only: entries="
    # THE REGRESSION THAT MATTERS. The fixture root holds far more than the old
    # 6,000-entry threshold's worth of nothing-in-particular, and the old check
    # tripped on exactly that. A count can no longer trip anything, and this is
    # the assertion that says so rather than trusting the flag removal.
    out=$("$GUARD" --check --root "$ROOT" --warn-pct "$QUIET_WARN" --high-pct 100 --critical-pct 100 \
                   --mem-avail-low-pct 0 --max-inode-pct 101 --max-c71780-mib 100000 2>/dev/null); rc=$?
    assert_rc "an ENTRY COUNT can no longer trigger anything — inventory is not consumption (#1423)" "$rc" 0
else
    echo "  SKIP: $ROOT is at ${USED_PCT:-?}% — cannot construct a below-threshold arm"
fi

# Capacity: thresholds at 0 put any mount in the worst band, so the banding
# itself is exercised rather than the host's current fullness.
out=$("$GUARD" --check --root "$ROOT" --warn-pct 0 --high-pct 0 --critical-pct 0 \
               --mem-avail-low-pct 0 --max-inode-pct 101 --max-c71780-mib 100000 2>/dev/null); rc=$?
assert_rc       "over the capacity threshold is a FINDING (rc 100: alive, condition present)" "$rc" 100
assert_contains "…named tmp_capacity, not 'entries'"        "$out" "tmp_capacity:"
assert_contains "…banded CRITICAL when past the critical threshold" "$out" "band critical"
assert_contains "…and says the bytes ARE the node's RAM"    "$out" "ARE the node's RAM"
# The two protocol lines the service-health layer reads (#1423). Their ABSENCE
# is the defect that re-fired a finding on a two-entry drift, so they are
# asserted here at the producer as well as at the consumer.
assert_contains "the finding DECLARES a stable suppression key" "$out" "finding-key: tmpfs:"
assert_contains "…keyed per CONDITION with its own band, never on a live counter" "$out" "tmp_capacity=critical"
assert_contains "the finding declares a monotone severity band"  "$out" "finding-band: 3"
# P0: detail the orchestrator can ACT on without going to measure.
assert_contains "the finding ranks families BY BYTES"        "$out" "top families BY BYTES"
assert_contains "…with a BYTES column, not only a count"     "$out" "BYTES"
assert_contains "…states the growth rate"                    "$out" "growth:"
assert_contains "…and bounds what a reap would reclaim"      "$out" "would reclaim AT MOST"
assert_contains "…stating the direction that bound errs in"  "$out" "UPPER BOUND"
# P0b: OWNER attribution — "is this even ours?" answered, not assumed.
assert_contains "the finding attributes bytes to an OWNER"   "$out" "owners by bytes:"
assert_contains "…and the per-family table carries an OWNER column" "$out" "OWNER"
# The demoted count is still THERE, and labelled as deciding nothing.
assert_contains "the entry count survives as DIAGNOSTIC CONTEXT" "$out" "DIAGNOSTIC CONTEXT"
assert_contains "…explicitly saying it decides nothing"          "$out" "decides nothing"

# Inodes: its OWN condition with an honest name, never smuggled in as memory.
out=$("$GUARD" --check --root "$ROOT" --warn-pct 101 --high-pct 101 --critical-pct 101 \
               --mem-avail-low-pct 0 --max-inode-pct 0 --max-c71780-mib 100000 2>/dev/null); rc=$?
assert_rc       "the inode ceiling is its own condition and can trip alone" "$rc" 100
assert_contains "…named 'inodes', not folded into memory"   "$out" "inodes:"
assert_contains "…and says why it needs a different remedy" "$out" "stops allocation while bytes are still free"

# Node memory: MemAvailable against MemTotal.
out=$("$GUARD" --check --root "$ROOT" --warn-pct 101 --high-pct 101 --critical-pct 101 \
               --mem-avail-low-pct 100 --max-inode-pct 101 --max-c71780-mib 100000 2>/dev/null); rc=$?
assert_rc       "node memory pressure is its own condition"  "$rc" 100
assert_contains "…named node_memory"                         "$out" "node_memory:"
assert_contains "…and points at attribution BEFORE assuming it is ours" "$out" "BEFORE assuming it is ours"

# socket_root: a CONTRACT condition, ON by default, capped at `elevated`, and
# it must never be described as pressure. What was wrong with it was the
# REPETITION, not the condition: instrumented over the guard's own 205-emit
# history, this leg took exactly ONE value across all 205 emits while the
# entry-count leg took 13 — so the stable, actionable leg was re-broadcast
# every two minutes only because a noisy leg's integer shared its string.
out=$("$GUARD" --check --root "$ROOT" --warn-pct 101 --high-pct 101 --critical-pct 101 \
               --mem-avail-low-pct 0 --max-inode-pct 101 --max-c71780-mib 1 2>/dev/null); rc=$?
assert_rc       "socket-root payload raises a finding by default"        "$rc" 100
assert_contains "…named as a CONTRACT violation, never as pressure"      "$out" "CONTRACT violation"
assert_not_contains "…and the HEADLINE does not call it memory pressure" "$out" "is under MEMORY PRESSURE"
assert_contains "…capped at band elevated so it cannot masquerade as pressure" "$out" "band elevated"
out=$(SOCKET_ROOT_TRIGGER=0 "$GUARD" --check --root "$ROOT" --warn-pct 101 --high-pct 101 --critical-pct 101 \
               --mem-avail-low-pct 0 --max-inode-pct 101 --max-c71780-mib 1 2>/dev/null); rc=$?
assert_rc       "…and it can be silenced by config without a code change" "$rc" 0
assert_contains "…still REPORTED on the healthy line when silenced"       "$out" "non-socket payload"

# THE SUPPRESSION KEY IS PER-CONDITION AND CARRIES NO MEASUREMENT. This is the
# whole #1423 P0c mechanism at the producer: a noisy leg must not be able to
# re-broadcast a quiet one, and it cannot if no leg's numbers are in the key.
out=$("$GUARD" --check --root "$ROOT" --warn-pct 0 --high-pct 0 --critical-pct 101 \
               --mem-avail-low-pct 0 --max-inode-pct 101 --max-c71780-mib 1 2>/dev/null)
key1=$(printf '%s\n' "$out" | sed -n 's/^finding-key: //p')
assert_contains "the key names EACH condition with ITS OWN band" "$key1" "socket_root=elevated"
assert_contains "…including the capacity leg"                    "$key1" "tmp_capacity=high"
# Digits in the ROOT PATH are legitimate (this fixture root is an mktemp name),
# so the assertion is scoped to the CONDITION half — which is where a
# measurement would leak in. Written this way after the naive whole-key form
# went red on the fixture's own directory name.
assert_eq       "the condition half of the key contains NO digits from any measurement (the #1423 laundering defect)" \
    "$(printf '%s' "${key1#tmpfs:$ROOT:}" | tr -cd '0-9' | wc -c)" "0"
# Crossing INTO A WORSE BAND changes the key; that is the one thing that must.
out=$("$GUARD" --check --root "$ROOT" --warn-pct 0 --high-pct 0 --critical-pct 0 \
               --mem-avail-low-pct 0 --max-inode-pct 101 --max-c71780-mib 1 2>/dev/null)
key2=$(printf '%s\n' "$out" | sed -n 's/^finding-key: //p')
assert_contains "a leg crossing into a WORSE band changes the key" "$key2" "tmp_capacity=critical"

# Retired knobs REFUSE rather than being silently ignored. A flag that stops
# doing anything while still being accepted is the manufactured-success shape
# this whole file is about.
for _flag in --max-used-pct --max-entries --max-th-files; do
    "$GUARD" --check --root "$ROOT" "$_flag" 5 >/dev/null 2>&1; rc=$?
    assert_rc "retired flag $_flag is REFUSED (rc 2), never accepted as a no-op" "$rc" 2
done
out=$("$GUARD" --check --root "$ROOT" --max-entries 5 2>&1); rc=$?
assert_contains "…and the refusal names the replacement" "$out" "--max-inode-pct"

# Ordered bands are a precondition, and an unordered set fails SILENTLY (every
# value lands in one band) unless it is refused.
"$GUARD" --check --root "$ROOT" --warn-pct 90 --high-pct 20 --critical-pct 80 >/dev/null 2>&1; rc=$?
assert_rc "unordered pressure thresholds are REFUSED" "$rc" 2

# A measurement failure stays UNHEALTHY (3), never a finding: a monitor that
# cannot look is not a monitor reporting that all is well.
"$GUARD" --check --root "$ROOT/definitely-not-here" >/dev/null 2>&1; rc=$?
assert_rc "a root that cannot be measured is rc 2 at parse time" "$rc" 2

# ── mutation-gate.sh: the workdir is removed on every exit path ─────────────
MGTMP="$ROOT/mg"; mkdir -p "$MGTMP"
stub="$ROOT/stub-suite.sh"
printf '#!/usr/bin/env bash\necho "PASS: one"\necho "=== summary: 1 passed, 0 failed ==="\necho ALL TESTS PASSED\n' > "$stub"; chmod +x "$stub"
# a `die` path (bad --line) and the listing path, both after the allocation
TMPDIR="$MGTMP" "$MG" --suite "$stub" --line 999 >/dev/null 2>&1 || true
TMPDIR="$MGTMP" "$MG" --suite "$stub" --list     >/dev/null 2>&1 || true
assert_eq "mutation-gate leaves no mutgate-* workdir behind" "$(find "$MGTMP" -maxdepth 1 -name 'mutgate-*' | wc -l)" 0
TMPDIR="$MGTMP" "$MG" --suite "$stub" --list --keep-workdir >/dev/null 2>&1 || true
assert_eq "…unless --keep-workdir asks for it"                "$(find "$MGTMP" -maxdepth 1 -name 'mutgate-*' | wc -l)" 1

# ── your-org/nexus-code#1441: the READ-ONLY half ships as its own mode ─────
# `--check-daemon` loops --check and NEVER reaps; `--daemon` is the deleting
# half. The registry example carries the reporter by default and the reaper
# commented out, so an operator who copies it inherits visibility, not rm -rf.
CD="$ROOT/cd"; mkdir -p "$CD"
plant_cd() { local d="$CD/$1"; mkdir -p -- "$d/sub"; head -c 4096 /dev/zero > "$d/sub/payload.bin"; old "$d"; }
plant_cd olay-guard-deadbeef
: > "$CD/inuse"   # an EMPTY, readable in-use list: an UNREADABLE one is the reaper's own refusal fixture (line 83)
timeout 5 "$GUARD" --check-daemon --root "$CD" --interval-seconds 1 --inuse-file "$CD/inuse" >/dev/null 2>&1 || true
assert_eq "#1441: --check-daemon looped for 5s and the reapable dir SURVIVED (read-only)" \
    "$([[ -d "$CD/olay-guard-deadbeef" ]] && echo present || echo gone)" "present"
# POTENCY: the deleting half removes the same plant, so the survival above is
# a property of the mode, not of the plant being unreapable.
timeout 5 "$GUARD" --daemon --root "$CD" --interval-seconds 1 --inuse-file "$CD/inuse" --trash-days 1 >/dev/null 2>&1 || true
assert_eq "#1441 POTENCY: --daemon on the same plant REAPS it" \
    "$([[ -d "$CD/olay-guard-deadbeef" ]] && echo present || echo gone)" "gone"
_reg="$REPO_ROOT/monitor/services.registry.example"
_chk=$(grep -c $'^tmpfs-check\t.*--check-daemon\t.*\temit-only$' "$_reg")
_reap_live=$(grep -c $'^tmpfs-reap\t' "$_reg"); _reap_comment=$(grep -c $'^# tmpfs-reap\t.*--daemon' "$_reg")
assert_eq "#1441: the example registers tmpfs-check (--check-daemon, emit-only) LIVE and tmpfs-reap only COMMENTED" \
    "$_chk/$_reap_live/$_reap_comment" "1/0/1"

# ---- #1490: emit_both must not TRUNCATE an append-opened log ---------------
#
# `tee /dev/stderr` OPENS the path fd 2 points at, and an open of a regular
# file TRUNCATES it — so this guard, whose whole job is to describe an
# ACCUMULATING condition over time, destroyed its own history on every finding
# it emitted. Measured on the pre-fix construct: a seeded 40-line log came back
# as 1 line, rc 0, nothing on stderr.
#
# Driven against the REAL function, extracted from the guard under test rather
# than re-typed here: a second copy of the remedy would pass while the shipped
# one regressed. Run in a child shell opened `>>log 2>&1`, which is the launch
# form that makes the defect reachable — `_service_health.sh` starts services
# exactly that way, and a fixture that redirected stdin or used `>` instead
# would be green against the broken construct too.
_e1490_dir=$(mktemp -d)
_e1490_log="$_e1490_dir/svc.log"
seq 1 40 > "$_e1490_log"
_e1490_fn=$(sed -n '/^emit_both()/,/^}/p' "$GUARD")
assert_eq "#1490 PRECONDITION: emit_both was extracted from the guard, not re-typed" \
    "$( [[ -n "$_e1490_fn" ]] && echo yes || echo NO )" "yes"
bash -c "$_e1490_fn"$'\n''emit_both "a finding"' >>"$_e1490_log" 2>>"$_e1490_log"
_e1490_after=$(wc -l < "$_e1490_log" | tr -d ' ')
assert_eq "#1490: 40 seeded lines SURVIVE an emit through emit_both" \
    "$( (( _e1490_after >= 40 )) && echo survived || echo "TRUNCATED to $_e1490_after" )" "survived"
# POTENCY. The same fixture through the construct that was there proves this
# assertion can fail — without it, a green says only that something was written.
seq 1 40 > "$_e1490_log"
# The pre-fix construct is ASSEMBLED from split literals, never written out.
# `tee-reopen-lint.sh` scans every shell file in the repo, including this one,
# so a literal `tee /dev/stderr` here is indistinguishable from a real site and
# would make the lint flag its own potency fixture — one hit, forever, in the
# tree it certifies clean. The alternative is an allowlist exempting this path,
# and a lint with an exemption for the file most likely to contain the pattern
# is a lint with a hole shaped like its own author. The construct is still
# genuinely EXECUTED below, which is the whole point of a potency arm.
_e1490_bad_form='printf "a finding\n" | te''e /dev/std''err >/dev/null'
bash -c "$_e1490_bad_form" >>"$_e1490_log" 2>>"$_e1490_log"
_e1490_bad=$(wc -l < "$_e1490_log" | tr -d ' ')
assert_eq "#1490 POTENCY: the pre-fix \`tee /dev/stderr\` construct DOES truncate the same log" \
    "$( (( _e1490_bad < 40 )) && echo truncated || echo "survived at $_e1490_bad" )" "truncated"
# And the fixed construct really reaches fd 2 — a remedy that silently stopped
# writing to stderr would satisfy both assertions above.
_e1490_err=$(bash -c "$_e1490_fn"$'\n''emit_both "a finding"' 2>&1 >/dev/null)
assert_eq "#1490: …and it still writes to STDERR (the emit surface production reads)" \
    "$_e1490_err" "a finding"
rm -rf "$_e1490_dir"

# Census: the assertion total is pinned EXACTLY (count=exact in
# summary-honesty.manifest), counted BEFORE this census assertion itself.
_ran=$((PASS + FAIL))
if (( _ran == EXPECTED_ASSERTIONS )); then PASS=$((PASS+1)); echo "  PASS: assertion census: $_ran ran, expected $EXPECTED_ASSERTIONS"
else FAIL=$((FAIL+1)); echo "  FAIL: assertion census: $_ran ran, expected $EXPECTED_ASSERTIONS"; fi
th_summary_and_exit
