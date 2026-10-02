#!/usr/bin/env bash
# Tests for monitor/uv-cache-guard.sh — the dangling-uv-cache guard
# (jacob-greene/nexus#98, incident 2026-08-25).
#
# The fault: `locals/uv/cache` is a symlink into purgeable scratch. A purge
# removes the TARGET; the symlink survives dangling; every `uv` call then fails
# with `File exists (os error 17)`, which names neither the symlink nor the
# missing target. It took a registered JupyterLab service down twice, 20 min
# 18 s combined.
#
# These tests CONSTRUCT the broken state — they do not reason about the code.
# Test (13) is the decisive one: it runs the real `uv` against a real dangling
# symlink, asserts the incident's exact error, runs the guard, and asserts the
# same `uv` command then succeeds. Tests (3)-(5) are the controls: the guard
# must be a no-op on a healthy link, on a real directory, and on an absent path.
#
# This suite is NOT fully hermetic, and it cannot be. Nothing touches the live
# `locals/` tree, and almost everything lives under a `mktemp -d` sandbox. But
# arms (7), (8) and (18) must name paths at the FILESYSTEM ROOT by
# construction — see the ROOT_FIXTURES block below for why no `mktemp`
# directory can express those shapes. Those three paths carry this run's own
# PID, so two concurrent runs cannot share one, and the cleanup removes only
# paths that carry this run's tag.
#
# Run: bash monitor/watcher/test-uv-cache-guard.sh
# Expected: ALL TESTS PASSED on stdout, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD="$_test_dir/../uv-cache-guard.sh"
RECOVER="$_test_dir/../bootstrap-recover.sh"
LABSH="$_test_dir/../labsh-supervised.sh"

# Preconditions FAIL the suite; they never shrink it.
#
# Arms (13) and (14) used to be wrapped in `if command -v uv` and
# `if [[ -r "$LABSH" ]]`. A missing tool or an unreadable consumer then removed
# five assertions and the suite still printed ALL TESTS PASSED and exited 0.
# Measured: 45 passed, 0 failed with `uv` off PATH, against 50 with it. Arm
# (13) is the arm this header calls decisive, and arm (14) emitted nothing at
# all. That is a silent skip: a test the harness does not run, does not count,
# and does not report, so the suite still reads green.
#
# So every precondition is checked ONCE, here, and a missing one is a loud
# failure. The assertion count is then constant, which is what makes the
# expected-total tripwire at the foot of this file meaningful.
_precondition_failed() { printf 'FAIL: precondition — %s\n' "$1" >&2; echo FAILED; exit 1; }
[[ -r "$GUARD" ]]   || _precondition_failed "$GUARD is missing or unreadable"
[[ -r "$RECOVER" ]] || _precondition_failed "$RECOVER is missing or unreadable; arms (11) and (12) need it"
[[ -r "$LABSH" ]]   || _precondition_failed "$LABSH is missing or unreadable; arm (14) needs it"
command -v uv >/dev/null 2>&1 \
    || _precondition_failed "uv is not on PATH; arm (13), the decisive end-to-end arm, needs it"

PASS=0
FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }
assert_eq() {
    local label="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] && ok "$label" || bad "$label" "got $(printf %q "$got") want $(printf %q "$want")"
}

WORK=$(mktemp -d -t nexus-uv-cache-guard-XXXXXX)

# Root-level fixtures — the one thing here that cannot live under $WORK.
#
# Three arms must name paths at the filesystem root by construction:
#
#   | Arm  | Shape it needs                    | Why $WORK cannot express it        |
#   |------|-----------------------------------|------------------------------------|
#   | (7)  | one component, must NOT exist     | a $WORK path has >= 3 components   |
#   | (8)  | first component must NOT exist    | $WORK's first component exists     |
#   | (18) | one component, must EXIST         | a $WORK path has >= 3 components   |
#
# The root is writable in this sandbox, and several clones of this branch live
# on this host, so these paths are shared state in both directions.
#
#   * FALSE FAILURE. A regression under test creates the path, the old cleanup
#     removed only the `mktemp` directory, and the survivor then failed arm (7)
#     or arm (8) against CORRECT code on the next run.
#   * FALSE PASS, which is worse. Two runs that share a name let one run's
#     cleanup remove a path while the other run's arm is asserting on it. A
#     negative control — a mutation arm that must turn the suite red — then
#     PASSES against BROKEN code, and the verification record is worthless.
#
# A per-run unique name removes the sharing that both directions need. Each
# name carries this run's PID, which is unique among concurrently live
# processes, so no two concurrent runs can collide. The remover additionally
# refuses any path that does not carry this run's own tag, so a bug above can
# never delete another run's fixture or an unrelated root-level path.
ROOT_TAG="nexus-uv-cache-guard-$$"
ROOT_ABSENT="/$ROOT_TAG-absent"      # arm (7)
ROOT_NOMOUNT="/$ROOT_TAG-nomount"    # arm (8)
ROOT_PRESENT="/$ROOT_TAG-present"    # arm (18)
ROOT_FIXTURES=("$ROOT_ABSENT" "$ROOT_NOMOUNT" "$ROOT_PRESENT")
clean_root_fixtures() {
    local p
    for p in "${ROOT_FIXTURES[@]}"; do
        # Owner check. Only this run's own three names are removable.
        case "$p" in
            "/$ROOT_TAG-absent"|"/$ROOT_TAG-nomount"|"/$ROOT_TAG-present") : ;;
            *) continue ;;
        esac
        [[ -e "$p" || -L "$p" ]] || continue
        rm -rf -- "$p" 2>/dev/null || true
    done
}
trap 'rm -rf "$WORK"; clean_root_fixtures' EXIT

# Pre-flight. A path carrying THIS run's tag can only survive from a crashed
# run whose PID has since been reused. Say so, then clear it.
for _rf in "${ROOT_FIXTURES[@]}"; do
    [[ -e "$_rf" || -L "$_rf" ]] \
        && echo "NOTE: clearing a path left by a crashed run that held this PID: $_rf" >&2
done
clean_root_fixtures

# Run the guard as a SUBPROCESS so a `return` cannot leak into this shell and
# so each case gets a clean environment. Prints the exit code on stdout;
# stderr is captured to $2 when a caller wants to inspect the warnings.
run_guard() {
    local path="$1" errfile="${2:-/dev/null}" rc=0
    env -u UV_CACHE_DIR -u NEXUS_LOCALS \
        NEXUS_STATE_DIR="$WORK/state" \
        PATH="/usr/bin:/bin" \
        bash "$GUARD" "$path" 2>"$errfile" || rc=$?
    printf '%s' "$rc"
}

echo "=== uv-cache-guard ==="

# ---- (1) the fault: a dangling symlink is repaired -------------------------
c1="$WORK/c1"; mkdir -p "$c1/locals/uv" "$c1/scratch"
ln -s "$c1/scratch/nexus-uv-cache" "$c1/locals/uv/cache"
rc=$(run_guard "$c1/locals/uv/cache" "$WORK/c1.err")
assert_eq "(1) dangling symlink -> exit 10 (repaired)" "$rc" "10"
[[ -d "$c1/scratch/nexus-uv-cache" ]] \
    && ok "(1) target directory created" \
    || bad "(1) target directory created" "$c1/scratch/nexus-uv-cache is not a directory"
[[ -L "$c1/locals/uv/cache" && -e "$c1/locals/uv/cache" ]] \
    && ok "(1) symlink now resolves" \
    || bad "(1) symlink now resolves" "still dangling"

# ---- (2) idempotent: a second run is a silent no-op ------------------------
rc=$(run_guard "$c1/locals/uv/cache" "$WORK/c2.err")
assert_eq "(2) second run -> exit 0 (nothing to do)" "$rc" "0"
[[ ! -s "$WORK/c2.err" ]] \
    && ok "(2) second run warns nothing (fires once per purge)" \
    || bad "(2) second run warns nothing" "stderr: $(cat "$WORK/c2.err")"

# ---- (3) CONTROL: healthy symlink is untouched -----------------------------
c3="$WORK/c3"; mkdir -p "$c3/locals/uv" "$c3/scratch/nexus-uv-cache"
ln -s "$c3/scratch/nexus-uv-cache" "$c3/locals/uv/cache"
touch "$c3/scratch/nexus-uv-cache/sentinel"
rc=$(run_guard "$c3/locals/uv/cache" "$WORK/c3.err")
assert_eq "(3) healthy symlink -> exit 0" "$rc" "0"
[[ -f "$c3/scratch/nexus-uv-cache/sentinel" && ! -s "$WORK/c3.err" ]] \
    && ok "(3) healthy symlink: contents intact, no output" \
    || bad "(3) healthy symlink no-op" "sentinel or stderr changed"

# ---- (4) CONTROL: a real directory does not fire ---------------------------
c4="$WORK/c4"; mkdir -p "$c4/locals/uv/cache"
touch "$c4/locals/uv/cache/sentinel"
rc=$(run_guard "$c4/locals/uv/cache" "$WORK/c4.err")
assert_eq "(4) real directory -> exit 0" "$rc" "0"
[[ -d "$c4/locals/uv/cache" && ! -L "$c4/locals/uv/cache" && -f "$c4/locals/uv/cache/sentinel" ]] \
    && ok "(4) real directory: still a plain directory, contents intact" \
    || bad "(4) real directory no-op" "the path was modified"

# ---- (5) CONTROL: an absent path is NOT provisioned ------------------------
# Provisioning `locals/` is bootstrap-venv's job. A guard that also created a
# missing cache would silently take that over and mask an unprovisioned tree.
c5="$WORK/c5"; mkdir -p "$c5/locals/uv"
rc=$(run_guard "$c5/locals/uv/cache" "$WORK/c5.err")
assert_eq "(5) absent path -> exit 0" "$rc" "0"
[[ ! -e "$c5/locals/uv/cache" ]] \
    && ok "(5) absent path is not created (provisioning stays bootstrap-venv's job)" \
    || bad "(5) absent path" "the guard created $c5/locals/uv/cache"

# ---- (6) a RELATIVE link body resolves against the LINK, not the cwd -------
# The footgun the sketch in jacob-greene/nexus#98 had: `mkdir -p "$(readlink …)"` from the wrong
# cwd creates the wrong directory and leaves the real fault unrepaired.
c6="$WORK/c6"; mkdir -p "$c6/locals/uv" "$c6/scratch" "$c6/elsewhere"
ln -s "../../scratch/nexus-uv-cache" "$c6/locals/uv/cache"
rc=$(cd "$c6/elsewhere" && run_guard "$c6/locals/uv/cache" "$WORK/c6.err")
assert_eq "(6) relative body, foreign cwd -> exit 10" "$rc" "10"
[[ -d "$c6/scratch/nexus-uv-cache" ]] \
    && ok "(6) relative body resolved against the symlink's own directory" \
    || bad "(6) relative body" "$c6/scratch/nexus-uv-cache was not created"
[[ ! -e "$c6/elsewhere/scratch" && ! -e "$c6/elsewhere/nexus-uv-cache" ]] \
    && ok "(6) nothing created under the caller's cwd" \
    || bad "(6) relative body" "the guard created a directory under the cwd"

# ---- (7) REFUSE: a single top-level component is not a plausible cache -----
# This arm pins the target-plausibility rule, and it must pin THAT rule and no
# other. Exit 2 alone cannot do that: the guard has five refusal branches and
# they all return 2.
#
# For THIS arm's fixture — a single-component target that does not exist — the
# nearest-ancestor rule below would refuse the identical input for its own
# reason, because the only ancestor of an absent `/x` is `/`. So exit 2 here is
# not attributable, and this arm attributes by MESSAGE: it requires the text
# this rule alone emits, and requires the next rule's text to be absent.
#
# That is an attribution, not a boundary. This arm pins ONE fixture's answer.
# Widen the rule outside that fixture and this arm stays green. Arm (18) is the
# arm that pins the rule's BEHAVIOUR, on a fixture the ancestor rule cannot
# refuse — read its header for why such a fixture exists.
c7="$WORK/c7"; mkdir -p "$c7/locals/uv"
ln -s "$ROOT_ABSENT" "$c7/locals/uv/cache"
rc=$(run_guard "$c7/locals/uv/cache" "$WORK/c7.err")
assert_eq "(7) single top-level target -> exit 2 (refused)" "$rc" "2"
[[ ! -e "$ROOT_ABSENT" ]] \
    && ok "(7) refused without creating anything at /" \
    || bad "(7) refusal" "the guard created a top-level directory"
grep -q "not a plausible cache path" "$WORK/c7.err" \
    && ok "(7) the PLAUSIBILITY rule is the rule that refused (its own message)" \
    || bad "(7) plausibility rule" "the plausibility message is absent; stderr: $(cat "$WORK/c7.err")"
grep -q "no existing ancestor" "$WORK/c7.err" \
    && bad "(7) rule attribution" "the nearest-ancestor rule answered, so the plausibility rule did not fire" \
    || ok "(7) the nearest-ancestor rule did not answer for it (attribution is unambiguous)"

# ---- (8) REFUSE: no existing ancestor below / ------------------------------
# Models an unmounted scratch filesystem. Creating the tree would shadow the
# mountpoint with a directory on the root filesystem and hide the real fault.
#
# Like arm (7), this arm pins ONE fixture's answer, not the rule's boundary.
# Narrow the rule outside this fixture and the arm stays green.
c8="$WORK/c8"; mkdir -p "$c8/locals/uv"
ln -s "$ROOT_NOMOUNT/group/user/nexus-uv-cache" "$c8/locals/uv/cache"
rc=$(run_guard "$c8/locals/uv/cache" "$WORK/c8.err")
assert_eq "(8) unmounted-looking target -> exit 2 (refused)" "$rc" "2"
[[ ! -e "$ROOT_NOMOUNT" ]] \
    && ok "(8) refused without creating a shadow mountpoint" \
    || bad "(8) refusal" "the guard created $ROOT_NOMOUNT"
# Attribute the refusal to the nearest-ancestor rule, for the same reason
# arm (7) attributes its own: five branches return 2, so the exit code alone
# does not say which rule answered.
grep -q "no existing ancestor" "$WORK/c8.err" \
    && ok "(8) the NEAREST-ANCESTOR rule is the rule that refused (its own message)" \
    || bad "(8) ancestor rule" "the ancestor message is absent; stderr: $(cat "$WORK/c8.err")"

# ---- (9) REFUSE: a symlink cycle terminates ---------------------------------
c9="$WORK/c9"; mkdir -p "$c9"
ln -s "$c9/b" "$c9/a"
ln -s "$c9/a" "$c9/b"
rc=$(run_guard "$c9/a" "$WORK/c9.err")
assert_eq "(9) symlink cycle -> exit 2 (refused, bounded)" "$rc" "2"

# ---- (10) the purge is RECORDED durably (review question 2) ----------------
rec="$WORK/state/uv-cache-purged.log"
if [[ -f "$rec" ]]; then
    ok "(10) purge record written to \$NEXUS_STATE_DIR/uv-cache-purged.log"
    grep -qF "$c1/scratch/nexus-uv-cache" "$rec" \
        && ok "(10) record names the scratch target (so other losses can be checked)" \
        || bad "(10) record content" "target missing from $rec"
    # one line per repair: cases (1) and (6) repaired, (2)-(9) did not.
    assert_eq "(10) exactly one record per repair" "$(grep -c . "$rec")" "2"
else
    bad "(10) purge record" "$rec was not written"
fi
grep -q "WARNING" "$WORK/c1.err" \
    && ok "(10) repair warns loudly on stderr" \
    || bad "(10) warning" "no WARNING in stderr: $(cat "$WORK/c1.err")"

# ---- (11) bootstrap-recover wiring: --dry-run writes NOTHING ---------------
# boot-recover.sh runs `--dry-run` as a health probe, so it must stay
# side-effect-free.
#
# Arms (11) and (12) deliberately inherit the AMBIENT PATH — that is how they
# reach the real `sandbox-notify`, and reaching it is what exposed the
# unbounded bell that arm (16) now pins. An unbounded bell therefore HANGS
# these two arms. A hang is not a failure: the suite never reaches its
# summary, and arm (16), the arm written for exactly that regression, is never
# reached. So bound the invocation here too. A lost bound then fails the
# suite, with a named reason, instead of stalling it.
c11="$WORK/c11"; mkdir -p "$c11/locals/uv" "$c11/scratch"
ln -s "$c11/scratch/nexus-uv-cache" "$c11/locals/uv/cache"
dry_rc=0
dry_out=$(
    env -u UV_CACHE_DIR NEXUS_LOCALS="$c11/locals" NEXUS_STATE_DIR="$WORK/state11" \
        timeout 60 bash -c '
            set -uo pipefail
            source "$1" >/dev/null 2>&1
            DRY_RUN=1
            _recover_uv_cache_guard
        ' _ "$RECOVER" 2>&1
) || dry_rc=$?
(( dry_rc == 124 )) \
    && bad "(11) dry-run is bounded" "the dry-run probe hung and was killed at 60s (an unbounded call on the recovery path)" \
    || ok "(11) the dry-run probe finishes inside its 60s bound (rc=$dry_rc)"
if [[ ! -e "$c11/scratch/nexus-uv-cache" ]]; then
    ok "(11) bootstrap-recover --dry-run creates nothing"
else
    bad "(11) dry-run purity" "the target was created under --dry-run"
fi
grep -q "would repair" <<<"$dry_out" \
    && ok "(11) dry-run reports 'would repair'" \
    || bad "(11) dry-run marker" "output: $dry_out"
# The marker must NOT match boot-recover's launch gate — a dangling cache
# alone should not trigger a full recovery sweep.
grep -qE 'would (relaunch|run|resume)' <<<"$dry_out" \
    && bad "(11) dry-run gate" "the marker matches boot-recover's launch gate" \
    || ok "(11) marker does not trip boot-recover's 'would (relaunch|run|resume)' gate"

# ---- (12) bootstrap-recover wiring: a real run repairs ---------------------
# Bounded for the reason given at arm (11): this is the arm that repairs, so
# this is the arm that rings the bell, and an unbounded bell hangs it.
real_rc=0
real_out=$(
    env -u UV_CACHE_DIR NEXUS_LOCALS="$c11/locals" NEXUS_STATE_DIR="$WORK/state11" \
        timeout 60 bash -c '
            set -uo pipefail
            source "$1" >/dev/null 2>&1
            DRY_RUN=0
            _recover_uv_cache_guard
        ' _ "$RECOVER" 2>&1
) || real_rc=$?
(( real_rc == 124 )) \
    && bad "(12) the real recovery run is bounded" "the repair hung and was killed at 60s — the notification bell is not bounded" \
    || ok "(12) the real recovery run finishes inside its 60s bound (rc=$real_rc)"
[[ -d "$c11/scratch/nexus-uv-cache" ]] \
    && ok "(12) bootstrap-recover repairs the cache on a real run" \
    || bad "(12) recover wiring" "target not created; output: $real_out"
grep -q "uv cache: repaired" <<<"$real_out" \
    && ok "(12) recovery logs the repair under its [recover] prefix" \
    || bad "(12) recover log" "output: $real_out"

# ---- (13) THE PROOF: real uv fails, then recovers --------------------------
c13="$WORK/c13"; mkdir -p "$c13/locals/uv" "$c13/scratch"
ln -s "$c13/scratch/nexus-uv-cache" "$c13/locals/uv/cache"

before=$(UV_CACHE_DIR="$c13/locals/uv/cache" uv venv "$c13/venv-before" 2>&1)
before_rc=$?
if (( before_rc != 0 )); then
    ok "(13) real uv FAILS against the dangling symlink (rc=$before_rc)"
else
    bad "(13) reproduction" "uv unexpectedly succeeded; the fault was not reproduced"
fi
grep -qF "File exists (os error 17)" <<<"$before" \
    && ok "(13) uv reports the incident's exact error: File exists (os error 17)" \
    || bad "(13) error text" "got: $before"

rc=$(run_guard "$c13/locals/uv/cache" "$WORK/c13.err")
assert_eq "(13) guard repairs it -> exit 10" "$rc" "10"

after=$(UV_CACHE_DIR="$c13/locals/uv/cache" uv venv "$c13/venv-after" 2>&1)
after_rc=$?
if (( after_rc == 0 )); then
    ok "(13) the SAME uv command now SUCCEEDS (rc=0)"
else
    bad "(13) recovery" "uv still fails after the guard: $after"
fi
[[ -f "$c13/locals/uv/cache/CACHEDIR.TAG" ]] \
    && ok "(13) uv populated the cache through the repaired symlink" \
    || bad "(13) cache population" "no CACHEDIR.TAG under the cache path"

# ---- (14) labsh-supervised wiring ------------------------------------------
# The warm-restart path. bootstrap-recover only covers COLD BOOT; this
# supervisor restarts on its own long after any recovery sweep, and a purge can
# land in between.
grep -q 'uv-cache-guard.sh' "$LABSH" \
    && ok "(14) labsh-supervised sources the guard" \
    || bad "(14) labsh wiring" "uv-cache-guard.sh is not sourced"
grep -q '^repair_uv_cache()' "$LABSH" \
    && ok "(14) labsh-supervised defines repair_uv_cache" \
    || bad "(14) labsh wiring" "repair_uv_cache is not defined"
# The call must precede `labsh start` inside _start_cycle.
call_line=$(grep -n '^ *repair_uv_cache  *#' "$LABSH" | head -1 | cut -d: -f1)
start_line=$(grep -n '^ *labsh start --port' "$LABSH" | head -1 | cut -d: -f1)
if [[ -n "$call_line" && -n "$start_line" ]] && (( call_line < start_line )); then
    ok "(14) repair_uv_cache is called before 'labsh start' (line $call_line < $start_line)"
else
    bad "(14) labsh call site" "call=$call_line start=$start_line"
fi

# EXECUTE the warm-restart consumer, the way arms (11) and (12) execute the
# cold-boot one. The three greps above are text-only: replace the body of
# `repair_uv_cache` with `rc=0` and all three still pass, so the higher-value
# consumer — the one the 2026-08-25 incident burned, because the supervisor
# restarts long after any recovery sweep — was pinned by nothing.
#
# labsh-supervised.sh cannot be sourced: its last lines start the watchdog's
# infinite probe loop. So extract the function block and run THAT. The
# extracted text is the real body, so a change to the body changes this arm.
labsh_fn=$(awk '/^repair_uv_cache\(\) \{/,/^\}/' "$LABSH")
if ! grep -q 'nexus_uv_cache_guard' <<<"$labsh_fn"; then
    bad "(14) repair_uv_cache is executable in isolation" \
        "could not extract a repair_uv_cache body that calls the guard (renamed or restructured?)"
else
    # The fault: UV_CACHE_DIR points at a dangling symlink, as it does after
    # a scratch purge, because locals-env.sh points it at locals/uv/cache.
    c14="$WORK/c14"; mkdir -p "$c14/locals/uv" "$c14/scratch"
    ln -s "$c14/scratch/nexus-uv-cache" "$c14/locals/uv/cache"
    labsh_out=$(
        env -u NEXUS_LOCALS \
            UV_CACHE_DIR="$c14/locals/uv/cache" \
            NEXUS_STATE_DIR="$WORK/state14" \
            PATH="/usr/bin:/bin" \
            timeout 60 bash -c '
                set -uo pipefail
                log() { printf "[labsh-svc] %s\n" "$*"; }
                source "$1" >/dev/null 2>&1
                eval "$2"
                repair_uv_cache
            ' _ "$GUARD" "$labsh_fn" 2>&1
    )
    [[ -d "$c14/scratch/nexus-uv-cache" ]] \
        && ok "(14) repair_uv_cache REPAIRS a dangling uv cache on the warm-restart path" \
        || bad "(14) warm-restart repair" "the target was not created; output: $labsh_out"
    grep -q "repaired dangling uv cache symlink" <<<"$labsh_out" \
        && ok "(14) the warm restart logs the repair under its [labsh-svc] prefix" \
        || bad "(14) warm-restart log" "output: $labsh_out"

    # CONTROL: a healthy cache must not make the supervisor claim a repair.
    c14b="$WORK/c14b"; mkdir -p "$c14b/locals/uv" "$c14b/scratch/nexus-uv-cache"
    ln -s "$c14b/scratch/nexus-uv-cache" "$c14b/locals/uv/cache"
    labsh_out_ok=$(
        env -u NEXUS_LOCALS \
            UV_CACHE_DIR="$c14b/locals/uv/cache" \
            NEXUS_STATE_DIR="$WORK/state14b" \
            PATH="/usr/bin:/bin" \
            timeout 60 bash -c '
                set -uo pipefail
                log() { printf "[labsh-svc] %s\n" "$*"; }
                source "$1" >/dev/null 2>&1
                eval "$2"
                repair_uv_cache
            ' _ "$GUARD" "$labsh_fn" 2>&1
    )
    [[ -z "$labsh_out_ok" ]] \
        && ok "(14) a healthy cache is a silent no-op on the warm-restart path" \
        || bad "(14) warm-restart no-op" "output on a healthy cache: $labsh_out_ok"
fi

# ---- (15) locals-env.sh stays PURE -----------------------------------------
# Review question 1 (jacob-greene/nexus#98): the guard deliberately does NOT live in
# locals-env.sh, whose header promises "no mkdir, no network, no writes" and
# whose own suite asserts it. This test pins the decision so a later change
# cannot quietly move the guard there.
grep -q 'uv-cache-guard' "$_test_dir/../locals-env.sh" \
    && bad "(15) locals-env purity" "locals-env.sh references the guard; it must stay side-effect-free" \
    || ok "(15) locals-env.sh does not call the guard (its no-side-effects contract holds)"

# ---- (16) the repair NEVER blocks on the notification bell ------------------
# The guard runs on the cold-boot path. `sandbox-notify` hangs indefinitely
# when no tmux server is reachable, which is exactly the cold-boot case: an
# unbounded call stalls recovery for every registered service behind a bell
# nobody reads. Found by running arms (11)/(12) with the ambient PATH, where
# the real sandbox-notify is reachable — arms (1)-(10) pin PATH=/usr/bin:/bin
# and so never exercised it.
#
# Assert BEHAVIOUR, not source text: put a sandbox-notify on PATH that would
# hang forever, then require the repair to finish anyway.
c16="$WORK/c16"; mkdir -p "$c16/locals/uv" "$c16/scratch" "$c16/bin"
cat > "$c16/bin/sandbox-notify" <<'STUB'
#!/usr/bin/env bash
sleep 300
STUB
chmod +x "$c16/bin/sandbox-notify"
ln -s "$c16/scratch/nexus-uv-cache" "$c16/locals/uv/cache"

c16_start=$SECONDS
c16_rc=0
env -u UV_CACHE_DIR -u NEXUS_LOCALS \
    NEXUS_STATE_DIR="$WORK/state16" \
    PATH="$c16/bin:/usr/bin:/bin" \
    timeout 60 bash "$GUARD" "$c16/locals/uv/cache" >/dev/null 2>&1 || c16_rc=$?
c16_elapsed=$(( SECONDS - c16_start ))

if (( c16_rc == 124 )); then
    bad "(16) bell is bounded" "the guard hung on sandbox-notify (killed at 60s)"
elif (( c16_elapsed < 30 )); then
    ok "(16) a hanging sandbox-notify does not stall the repair (${c16_elapsed}s, rc=$c16_rc)"
else
    bad "(16) bell is bounded" "repair took ${c16_elapsed}s — the bell is not bounded"
fi
[[ -d "$c16/scratch/nexus-uv-cache" ]] \
    && ok "(16) the repair still happened despite the hanging bell" \
    || bad "(16) repair under hanging bell" "target was not created"
[[ -f "$WORK/state16/uv-cache-purged.log" ]] \
    && ok "(16) the durable purge record still landed (surface 2 precedes the bell)" \
    || bad "(16) durable record" "uv-cache-purged.log was not written"

# ---- (17) the guard keeps its executable bit -------------------------------
# The header documents a direct-execution entry point
# (`monitor/uv-cache-guard.sh [CACHE_PATH]`) and the file implements it at its
# foot. Every arm above invokes the guard as `bash "$GUARD"`, which works on a
# file with no executable bit — so NOTHING above can see the mode. Without the
# bit, direct execution returns 126 and the documented entry point is broken.
# Assert the mode, then assert the behaviour the mode exists for.
[[ -x "$GUARD" ]] \
    && ok "(17) the guard file is executable" \
    || bad "(17) guard file mode" "$GUARD is not executable; direct execution returns 126"

c17_rc=0
env -u UV_CACHE_DIR -u NEXUS_LOCALS \
    NEXUS_STATE_DIR="$WORK/state17" \
    PATH="/usr/bin:/bin" \
    timeout 60 "$GUARD" "$WORK/c17-absent-path" >/dev/null 2>&1 || c17_rc=$?
assert_eq "(17) direct execution runs the guard (no 126 Permission denied)" "$c17_rc" "0"

# ---- (18) the plausibility rule has BEHAVIOUR, not only a message ----------
# Arm (7) attributes a refusal to this rule by its message, because for arm
# (7)'s fixture the nearest-ancestor rule would refuse the same input anyway.
# This arm pins the rule by its EXIT CODE, on a fixture the ancestor rule
# CANNOT refuse. Such a fixture exists, and an earlier version of this suite
# claimed it could not.
#
# It exists because the guard and the kernel disagree about `..`.
# `_ucg_normalise` resolves `..` LEXICALLY, with no filesystem access, which
# is deliberate: the target is missing, so no resolving form can work. The
# KERNEL resolves `..` AFTER symlink resolution. So a link that sits in a
# directory reached through a symlink, whose relative body ascends past that
# symlink, hands the guard a target the kernel never resolved.
#
# The fixture exploits exactly that divergence:
#
#   | Resolver | Target of the link                    | Exists |
#   |----------|---------------------------------------|--------|
#   | kernel   | one level under the sandbox's parent  | no     |
#   | guard    | a one-component path at the root      | YES    |
#
# The link therefore still dangles, so the guard still runs. Its computed
# target has one component, and that component EXISTS — so the nearest
# existing ancestor is the target itself, and the ancestor rule accepts it.
# The plausibility rule is the only check left standing.
#
# Delete that rule and the guard reports a repair on a root-level directory and
# records a purge that never happened. That is the behaviour this arm pins.
c18="$WORK/c18"; mkdir -p "$c18/real/deep"
ln -s "$c18/real/deep" "$c18/alias"
mkdir -p "$ROOT_PRESENT"
# Ascend exactly as many levels as the LOGICAL directory of the link is deep,
# so the lexical result is $ROOT_PRESENT itself. Derived, never hard-coded,
# because $WORK's depth depends on $TMPDIR.
c18_depth=$(awk -F/ '{print NF-1}' <<<"$c18/alias")
c18_up=$(printf '../%.0s' $(seq 1 "$c18_depth"))
ln -s "${c18_up}${ROOT_PRESENT#/}" "$c18/alias/cache"

# Shape check first. If either half of the divergence stops holding, this arm
# must fail loudly rather than pass for the wrong reason.
[[ -L "$c18/alias/cache" && ! -e "$c18/alias/cache" ]] \
    && ok "(18) the fixture link dangles, so the guard runs on it" \
    || bad "(18) fixture shape" "the link does not dangle; the kernel resolved it to $(readlink -m "$c18/alias/cache" 2>/dev/null)"

rc=$(run_guard "$c18/alias/cache" "$WORK/c18.err")
assert_eq "(18) existing one-component target -> exit 2 (refused)" "$rc" "2"
grep -qF "$ROOT_PRESENT" "$WORK/c18.err" \
    && ok "(18) the guard computed the root-level target (the lexical-vs-kernel divergence holds)" \
    || bad "(18) fixture divergence" "stderr does not name $ROOT_PRESENT: $(cat "$WORK/c18.err")"
grep -q "no existing ancestor" "$WORK/c18.err" \
    && bad "(18) rule isolation" "the nearest-ancestor rule answered; this fixture was supposed to defeat it" \
    || ok "(18) the nearest-ancestor rule CANNOT refuse this fixture (it isolates the plausibility rule)"
# `run_guard` shares $WORK/state with arms (1)-(10), which legitimately hold
# two records, so assert on the TARGET rather than on the record count.
if grep -qF "$ROOT_PRESENT" "$WORK/state/uv-cache-purged.log" 2>/dev/null; then
    bad "(18) purge record" "the guard recorded a repair of $ROOT_PRESENT, which it must have refused"
else
    ok "(18) no purge was recorded for a root-level target"
fi

# ---- summary ---------------------------------------------------------------
#
# EXPECTED_ASSERTIONS is a tripwire against the silent-skip class: a test the
# harness does not run, does not count, and does not report, so the suite still
# reads green. Every precondition is checked at the head of this file, so the
# count is constant on any host that can run the suite at all. Bump this number
# in the same commit that adds or removes an assertion.
#
# Two arms wrap assertions in a conditional and therefore change the total when
# their branch flips: arm (10) when no purge record was written, and arm (14)
# when the consumer's function body cannot be extracted. Both branches fail
# loudly, so they are explanations rather than holes — and this tripwire firing
# beside them is correct, not noise.
EXPECTED_ASSERTIONS=55
_total=$(( PASS + FAIL ))
assert_eq "(0) the suite ran its full assertion set (no arm vanished)" "$_total" "$EXPECTED_ASSERTIONS"

echo
printf '=== summary: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if (( FAIL == 0 )); then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "FAILED"
exit 1
