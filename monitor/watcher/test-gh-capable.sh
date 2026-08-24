#!/usr/bin/env bash
# monitor/watcher/test-gh-capable.sh — the `gh` version floor (#755).
#
# Covers monitor/gh-capable.sh (the resolution primitive), the prefer-capable
# resolution in monitor/ghwrap/gh, and the version-floor leg in
# monitor/assert-shims-wrapped.sh.
#
# NON-VACUITY. A suite that passes is worth nothing until something is shown to
# make it fail, so `--mutants` re-runs the whole suite against seeded defects
# and requires each to redden. The mutants are the plausible WRONG
# implementations of this change, not typos:
#
#   identity-resolution  revert to "first non-self gh"     — the #755 bug itself
#   floor-zero           floor 0.0.0 (accept anything)
#   ge-always-true       `_ghc_ge` always succeeds
#   stale-cache          cache ignores size/mtime          — serves a stale version
#   degraded-silent      drop the below-floor breadcrumb
#   gate-silent          gate stops objecting below floor
#   unverified-skipped   unreadable treated as below-floor  — the CI regression
#
# ASSERTION COUNT IS ITSELF ASSERTED. A refactor that stops RUNNING an
# assertion is invisible in a pass/fail tally, so the expected total is pinned
# below and checked. Nothing here runs assertions inside `( )`: a failure in a
# subshell cannot fail this suite, and a missing helper would be rc 127 counted
# by nobody.
#
# ---------------------------------------------------------------------------
# WHAT THIS SUITE DOES NOT COVER — stated on the axis the MECHANISM varies on
# ---------------------------------------------------------------------------
# The mechanism in #755 varies on `gh` VERSION. This suite fakes that axis with
# stubs that answer `--version` and nothing else, so what is verified here is
# RESOLUTION AND GATING LOGIC — which candidate gets chosen, what is said about
# it, and what the gate does. That part is host-independent and runs identically
# in CI.
#
# It does NOT verify the BEHAVIOURAL claims that motivate the floor: that
# 1.13.0 returns zero lines for `run view --job --log`, two of ten jobs for
# `run view --log`, and `pass` for a `skipped` check. Those were measured
# against the real binaries on the operator's host (see the #755 thread) and
# are deliberately NOT re-tested here, because doing so would require both real
# clients, a live token, and network — none of which a runner has.
#
# So a green CI run is NOT evidence that resolution behaves correctly on the
# operator's host. A GitHub runner has one `gh`, no `/app/bin`, and no
# competing candidates, so the very PATH shape this change exists for cannot
# occur there. The host-level evidence is the measurement, not this suite.

set -u

SELF_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
MONITOR_DIR=$(CDPATH= cd "$SELF_DIR/.." && pwd)
REPO_ROOT=$(CDPATH= cd "$MONITOR_DIR/.." && pwd)

EXPECTED_ASSERTIONS=56

PASS=0; FAIL=0; RUN=0
pass() { PASS=$((PASS + 1)); RUN=$((RUN + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); RUN=$((RUN + 1)); printf '  FAIL: %s\n' "$1"; }
ok()   { if [ "$1" = 0 ]; then pass "$2"; else fail "$2${3:+ — $3}"; fi; }

eq() { # eq <actual> <expected> <label>
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 — expected '$2', got '$1'"; fi
}
contains() { # contains <haystack> <needle> <label>
    case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 — '$2' not in: $(printf '%s' "$1" | head -c 200)" ;; esac
}
lacks() {
    case "$1" in *"$2"*) fail "$3 — unexpectedly found '$2'" ;; *) pass "$3" ;; esac
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nexus-ghcap.XXXXXX")
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# --- fake gh clients ---------------------------------------------------------
# A stub that answers `--version` the way the real client does. Version-only:
# these tests are about RESOLUTION, and the behavioural divergence they stand
# in for is measured against the real binaries in the #755 thread, not re-faked
# here.
mk_gh() { # mk_gh <dir> <version-or-BROKEN>
    mkdir -p "$1"
    if [ "$2" = BROKEN ]; then
        printf '#!/bin/sh\nexit 3\n' > "$1/gh"
    else
        printf '#!/bin/sh\ncase "$1" in --version) printf "gh version %s (2020-01-01)\\n" "%s" ;; *) printf "stub\\n" ;; esac\n' "$2" "$2" > "$1/gh"
    fi
    chmod +x "$1/gh"
}

# A utility dir with NO `gh` in it.
#
# The degraded / no-client cases must control the FULL candidate set, and
# `/usr/bin:/bin` does not let them: a GitHub runner ships its own `gh` there
# (2.96.0 at the time of writing), so a fixture claiming "no capable client on
# PATH" silently had one and the resolver correctly declined to degrade. That
# reddened four assertions on CI while passing here, because this host has no
# /usr/bin/gh. Symlinking an explicit utility list — rather than reaching for
# /usr/bin — makes the candidate set a property of the fixture instead of a
# property of whoever is running it.
CLEANBIN="$WORK/cleanbin"; mkdir -p "$CLEANBIN"
for _u in sh bash env date stat readlink dirname basename cut mkdir mv rm cat \
          awk sed tr head printf test expr sleep chmod ln touch grep wc sort id uname; do
    _p=$(command -v "$_u" 2>/dev/null) && [ -n "$_p" ] && ln -sf "$_p" "$CLEANBIN/$_u" 2>/dev/null
done
if [ -e "$CLEANBIN/gh" ]; then
    echo "FATAL: cleanbin acquired a gh — the hermetic fixtures would be meaningless" >&2
    exit 2
fi

STALE="$WORK/bin-stale";  mk_gh "$STALE" 1.13.0
NEWER="$WORK/bin-new";    mk_gh "$NEWER" 2.89.0
MIDDLE="$WORK/bin-mid";   mk_gh "$MIDDLE" 2.86.0     # exactly AT the floor
TWOX="$WORK/bin-2x";      mk_gh "$TWOX" 2.14.7      # 2.x and MEASURED BAD (2 of 10 jobs)
DEVB="$WORK/bin-dev";     mkdir -p "$DEVB"
printf '#!/bin/sh\ncase "$1" in --version) echo "gh version DEV";; *) echo DEVSTUB;; esac\n' > "$DEVB/gh"
chmod +x "$DEVB/gh"
BROKEN="$WORK/bin-broke"; mk_gh "$BROKEN" BROKEN

CACHE="$WORK/cache"
export NEXUS_GH_CAPABLE_CACHE="$CACHE"

# ============================================================================
run_suite() {
PASS=0; FAIL=0; RUN=0

# shellcheck disable=SC1090
. "$MONITOR_DIR/gh-capable.sh"

echo "=== version math (_ghc_ge) ==="
_ghc_ge 2.89.0 2.0.0; ok $? "2.89.0 >= 2.0.0"
_ghc_ge 1.13.0 2.0.0; r=$?; [ "$r" != 0 ]; ok $? "1.13.0 is NOT >= 2.0.0 (the whole point)"
_ghc_ge 2.86.0 2.86.0; ok $? "equal versions satisfy the floor"
_ghc_ge 2.1 2.0.9;    ok $? "a missing patch component is treated as 0, not as failure"
_ghc_ge 10.0.0 9.9.9; ok $? "double-digit major compares numerically, not lexically"

echo "=== version parsing (_ghc_version) ==="
eq "$(_ghc_version "$STALE/gh")" "1.13.0" "parses 'gh version 1.13.0 (…)'"
eq "$(_ghc_version "$NEWER/gh")" "2.89.0" "parses 'gh version 2.89.0 (…)'"
eq "$(_ghc_version "$BROKEN/gh")" "" "a client that cannot report a version yields empty"
eq "$(_ghc_version "$WORK/does-not-exist")" "" "a nonexistent path yields empty"

echo "=== three-state _ghc_meets ==="
_ghc_meets "$NEWER/gh"; eq "$?" "0" "meets → 0"
_ghc_meets "$STALE/gh"; eq "$?" "1" "below floor → 1"
_ghc_meets "$BROKEN/gh"; eq "$?" "2" "UNDETERMINABLE → 2, never folded into 0 or 1"

echo "=== cache correctness ==="
rm -rf "$CACHE"
v1=$(_ghc_version "$NEWER/gh")
[ -d "$CACHE" ]; ok $? "a cache entry is written on first probe"
# Rewrite the binary with a DIFFERENT version; size+mtime change must invalidate.
mk_gh "$NEWER" 2.99.0
touch -d '+1 minute' "$NEWER/gh" 2>/dev/null || touch "$NEWER/gh"
v2=$(_ghc_version "$NEWER/gh")
eq "$v1|$v2" "2.89.0|2.99.0" "an upgraded binary invalidates the cache (never serves a stale version)"
mk_gh "$NEWER" 2.89.0

echo "=== resolution (_ghc_resolve) — the #755 bug and its fix ==="
# THE BUG: stale client FIRST on PATH. Identity resolution took it; capability
# resolution must skip it and take the capable one further down.
line=$(_ghc_resolve "" "$STALE:$NEWER:/nonexistent")
eq "$(printf '%s' "$line" | cut -f1)" "$NEWER/gh" "stale-FIRST PATH resolves to the CAPABLE client (the #755 fix)"
eq "$(printf '%s' "$line" | cut -f2)" "ok" "…with status=ok"
contains "$(printf '%s' "$line" | cut -f4)" "1.13.0" "…and NAMES the client it skipped, with its version"

line=$(_ghc_resolve "" "$NEWER:$STALE")
eq "$(printf '%s' "$line" | cut -f1)" "$NEWER/gh" "capable-FIRST PATH is unchanged (PATH order still honoured)"
eq "$(printf '%s' "$line" | cut -f4)" "" "…and nothing is reported as skipped"

line=$(_ghc_resolve "" "$MIDDLE:$NEWER")
eq "$(printf '%s' "$line" | cut -f1)" "$MIDDLE/gh" "the FIRST capable candidate wins, not the newest"

# A 2.x client can be BELOW the floor. The first draft set the floor at 2.0.0 on
# two data points; a third client, 2.14.7, returns 2 of 10 jobs from
# `run view --log` — so "1.x bad, 2.x good" was a bound drawn on too little of
# the axis: honest, tested, and false.
_ghc_meets "$TWOX/gh"; eq "$?" "1" "a 2.x client BELOW the floor is still below it (2.14.7 truncates)"
line=$(_ghc_resolve "" "$TWOX:$NEWER")
eq "$(printf '%s' "$line" | cut -f1)" "$NEWER/gh" "…and is skipped in favour of a measured-good client"

# The version proxy failing in the wild: two real clients here report
# "gh version DEV" and sit at opposite ends of the capability range.
eq "$(_ghc_version "$DEVB/gh")" "" "a 'gh version DEV' build yields no parseable version"
line=$(_ghc_resolve "" "$DEVB:$NEWER")
eq "$(printf '%s' "$line" | cut -f2)" "unverified" "…and is taken in place as unverified, not stepped over"

# Availability: nothing capable must DEGRADE, never refuse.
line=$(_ghc_resolve "" "$STALE:/nonexistent")
eq "$(printf '%s' "$line" | cut -f1)" "$STALE/gh" "no capable client → still returns one (availability over refusal)"
eq "$(printf '%s' "$line" | cut -f2)" "degraded" "…flagged status=degraded"

line=$(_ghc_resolve "" "/nonexistent:/also-nope")
eq "$(printf '%s' "$line" | cut -f2)" "none" "no gh anywhere → status=none"

# ABSENCE OF EVIDENCE IS NOT EVIDENCE OF STALENESS. An unreadable candidate is
# TAKEN IN PLACE — stepping over it would change which binary runs on the
# strength of a silence, which is the #755 defect committed inside its own fix.
# CI caught the first implementation doing exactly that (see gh-capable.sh).
line=$(_ghc_resolve "" "$BROKEN:$NEWER")
eq "$(printf '%s' "$line" | cut -f1)" "$BROKEN/gh" "an UNREADABLE candidate is taken IN PLACE, not stepped over"
eq "$(printf '%s' "$line" | cut -f2)" "unverified" "…flagged unverified, so nothing mistakes it for a vouched client"

# …but a candidate PROVEN below the floor IS skipped. That is the distinction:
# demote on positive proof, never on silence.
line=$(_ghc_resolve "" "$STALE:$NEWER")
eq "$(printf '%s' "$line" | cut -f1)" "$NEWER/gh" "a PROVEN below-floor candidate is still skipped (proof, not silence)"

# Cross-clone wrapper exclusion (this workspace runs parallel clones).
SIB="$WORK/sibling/monitor/ghwrap"; mk_gh "$SIB" 9.9.9
line=$(_ghc_resolve "" "$SIB:$NEWER")
eq "$(printf '%s' "$line" | cut -f1)" "$NEWER/gh" "a SIBLING clone's ghwrap is skipped, not probed as a client"

echo "=== resolution cache: the memoised ANSWER must not go stale ==="
# The whole resolution is memoised per PATH string; the risk this introduces is
# vouching for a binary that has since been replaced.
SWAP="$WORK/bin-swap"; mk_gh "$SWAP" 2.89.0
eq "$(_ghc_resolve "" "$SWAP" | cut -f2)" "ok" "a capable client resolves ok (and is cached)"
eq "$(_ghc_resolve "" "$SWAP" | cut -f1)" "$SWAP/gh" "…a warm hit returns the same client"
# Replace that very binary with a below-floor one, same path.
mk_gh "$SWAP" 1.13.0
touch -d '+1 minute' "$SWAP/gh" 2>/dev/null || touch "$SWAP/gh"
eq "$(_ghc_resolve "" "$SWAP" | cut -f2)" "degraded" "a DOWNGRADED chosen binary invalidates the cached answer"

# `degraded` must never be cached, or a host that gets fixed stays broken.
DEG="$WORK/bin-deg"; mk_gh "$DEG" 1.13.0
eq "$(_ghc_resolve "" "$DEG" | cut -f2)" "degraded" "a below-floor-only PATH is degraded"
mk_gh "$DEG" 2.89.0
touch -d '+1 minute' "$DEG/gh" 2>/dev/null || touch "$DEG/gh"
eq "$(_ghc_resolve "" "$DEG" | cut -f2)" "ok" "…and degraded is NOT cached, so installing a capable client is noticed"

echo "=== wrapper end-to-end ==="
FAKEROOT="$WORK/root"; mkdir -p "$FAKEROOT/monitor/.state"
cp "$MONITOR_DIR/gh-capable.sh" "$MONITOR_DIR/gh-shim.sh" "$FAKEROOT/monitor/"
mkdir -p "$FAKEROOT/monitor/ghwrap"; cp "$MONITOR_DIR/ghwrap/gh" "$FAKEROOT/monitor/ghwrap/gh"
W="$FAKEROOT/monitor/ghwrap"

# The headline: wrapper PATH-front, stale client ahead of the capable one.
out=$(env PATH="$W:$STALE:$NEWER:$CLEANBIN" NEXUS_ROOT="$FAKEROOT" \
        NEXUS_GH_CAPABLE_CACHE="$CACHE" WATCHER_WINDOW=headless GH_TOKEN=x \
        "$W/gh" --version 2>/dev/null)
contains "$out" "2.89.0" "wrapper with stale-FIRST PATH now runs the CAPABLE client"
lacks "$out" "1.13.0" "…and does not run the stale one"

# Degraded path: warning on stderr AND a durable breadcrumb.
rm -f "$FAKEROOT/monitor/.state/gh-below-floor"
err=$(env PATH="$W:$STALE:$CLEANBIN" NEXUS_ROOT="$FAKEROOT" \
        NEXUS_GH_CAPABLE_CACHE="$CACHE" WATCHER_WINDOW=headless GH_TOKEN=x \
        "$W/gh" --version 2>&1 >/dev/null)
contains "$err" "WARNING" "no capable client → loud warning on stderr"
contains "$err" "755" "…citing the issue"
[ -f "$FAKEROOT/monitor/.state/gh-below-floor" ]; ok $? "…and a DURABLE breadcrumb the gate can read"
contains "$(cat "$FAKEROOT/monitor/.state/gh-below-floor" 2>/dev/null)" "1.13.0" "…naming the version actually selected"

# THE CI REGRESSION, end-to-end through the wrapper. `test-gh-wrapper.sh`'s
# fake real-gh answers every argv with a marker and no version. The first
# implementation stepped over it and ran the runner's own /usr/bin/gh, reddening
# six unit bands. The wrapper must execute the marker binary sitting in front.
MARKDIR="$WORK/bin-marker"; mkdir -p "$MARKDIR"
printf '#!/bin/sh\nprintf "IAMTHEMARKER argv=[%%s]\\n" "$*"\n' > "$MARKDIR/gh"
chmod +x "$MARKDIR/gh"
out=$(env PATH="$W:$MARKDIR:$NEWER:$CLEANBIN" NEXUS_ROOT="$FAKEROOT" \
        NEXUS_GH_CAPABLE_CACHE="$CACHE" WATCHER_WINDOW=headless GH_TOKEN=x \
        "$W/gh" --version 2>/dev/null)
contains "$out" "IAMTHEMARKER" "an unversionable gh in FRONT is the one executed, not a capable one behind it"

# Availability guarantee: degraded must still RUN the command.
out=$(env PATH="$W:$STALE:$CLEANBIN" NEXUS_ROOT="$FAKEROOT" \
        NEXUS_GH_CAPABLE_CACHE="$CACHE" WATCHER_WINDOW=headless GH_TOKEN=x \
        "$W/gh" --version 2>/dev/null)
contains "$out" "1.13.0" "degraded still EXECUTES (a wrapper that refuses would halt the board)"

# No client at all still refuses 127 (unchanged pre-#755 contract).
env PATH="$W:$CLEANBIN" NEXUS_ROOT="$FAKEROOT" "$W/gh" --version >/dev/null 2>&1
eq "$?" "127" "no gh on PATH at all → still refuses with 127"

echo "=== spawn gate: the version-floor leg ==="
# The gate measures the EFFECTIVE client end-to-end: a bare `gh --version` in a
# spawned probe shell, through whatever the shim resolution actually produces.
# Fixture: a synthetic shim dir on PATH front, holding a stub of known version.
GATE="$WORK/gate"; mkdir -p "$GATE/shims/ghwrap" "$GATE/root/monitor/.state"
gate_run() { # gate_run <version> [extra env assignments...]
    mk_gh "$GATE/shims/ghwrap" "$1"; shift
    env PATH="$GATE/shims/ghwrap:$CLEANBIN" \
        NEXUS_ROOT="$GATE/root" \
        NEXUS_SHIMWRAP_GLOB="$GATE/shims/*wrap" \
        NEXUS_ASSERT_GH_SHELL=/bin/sh \
        NEXUS_ASSERT_SKIP_NPROC=1 \
        "$@" \
        bash "$MONITOR_DIR/assert-shims-wrapped.sh" 2>&1
    printf 'RC=%s\n' "$?"
}

g=$(gate_run 2.89.0)
contains "$g" "RC=0" "gate: a client MEETING the floor passes"
lacks "$g" "BELOW the declared floor" "…silently, with no floor objection"

g=$(gate_run 1.13.0)
contains "$g" "RC=0" "gate: a BELOW-floor client allows the spawn by default"
contains "$g" "BELOW the declared floor" "…but says so loudly"
contains "$g" "skipped" "…naming the measured degradation (pr checks / skipped)"
[ -f "$GATE/root/monitor/.state/gh-below-floor.log" ]; ok $? "…and appends a durable breadcrumb"

g=$(gate_run 1.13.0 NEXUS_REQUIRE_GH_FLOOR=1)
contains "$g" "RC=1" "gate: NEXUS_REQUIRE_GH_FLOOR=1 makes below-floor a REFUSAL"
contains "$g" "REFUSING SPAWN" "…with the refusal stated"

g=$(gate_run 1.13.0 NEXUS_ASSERT_SKIP_GH_FLOOR=1)
lacks "$g" "BELOW the declared floor" "gate: the leg honours its explicit opt-out"

g=$(gate_run BROKEN)
contains "$g" "RC=0" "gate: an unreadable version is a WARNING, not 79 (the guard DID look)"
contains "$g" "could not read a \`gh\` version" "…and says which state it is in"

echo "=== assertion count ==="
eq "$RUN" "$EXPECTED_ASSERTIONS" "assertion count: $RUN executed, $EXPECTED_ASSERTIONS expected"
}
# ============================================================================

if [ "${1:-}" = "--mutants" ]; then
    echo "### MUTATION RUN — every mutant must redden at least one assertion ###"
    BACKUP="$WORK/backup"; mkdir -p "$BACKUP"
    cp "$MONITOR_DIR/gh-capable.sh" "$BACKUP/gh-capable.sh"
    cp "$MONITOR_DIR/ghwrap/gh" "$BACKUP/ghwrap-gh"
    cp "$MONITOR_DIR/assert-shims-wrapped.sh" "$BACKUP/assert-shims-wrapped.sh"
    restore() {
        cp "$BACKUP/gh-capable.sh" "$MONITOR_DIR/gh-capable.sh"
        cp "$BACKUP/ghwrap-gh" "$MONITOR_DIR/ghwrap/gh"
        cp "$BACKUP/assert-shims-wrapped.sh" "$MONITOR_DIR/assert-shims-wrapped.sh"
    }
    trap 'restore; cleanup' EXIT

    MUT_FAIL=0
    apply_and_check() { # apply_and_check <name> <sed-target-file> <sed-expr...>
        name="$1"; shift
        restore
        # cksum, NOT `wc -c`: the first version of this guard compared byte
        # COUNTS and instantly false-positived on `unverified-skipped`, whose
        # mutation is `return 2` -> `return 1` — same length, different file.
        before=$(cat "$MONITOR_DIR/gh-capable.sh" "$MONITOR_DIR/ghwrap/gh" "$MONITOR_DIR/assert-shims-wrapped.sh" | cksum)
        "$@" || { printf '  MUTANT %-20s: could not apply\n' "$name"; MUT_FAIL=1; return; }
        after=$(cat "$MONITOR_DIR/gh-capable.sh" "$MONITOR_DIR/ghwrap/gh" "$MONITOR_DIR/assert-shims-wrapped.sh" | cksum)
        if [ "$before" = "$after" ]; then
            # A mutant whose pattern no longer matches patches NOTHING and then
            # "passes", which reads identically to a mutant the suite killed.
            # That is this repo's dominant defect class living in the mutation
            # harness, so it is a hard error, not a note.
            printf '  MUTANT %-20s: *** PATTERN DID NOT MATCH — mutation was a no-op ***\n' "$name"
            MUT_FAIL=1; return
        fi
        rm -rf "$CACHE"
        out=$(run_suite 2>&1)
        n=$(printf '%s' "$out" | grep -c '^  FAIL:')
        if [ "$n" -gt 0 ]; then
            printf '  MUTANT %-20s: REDDENS %s assertion(s) — %s\n' "$name" "$n" \
                "$(printf '%s' "$out" | grep -m1 '^  FAIL:' | sed 's/^  FAIL: //' | cut -c1-90)"
        else
            printf '  MUTANT %-20s: *** SURVIVED — the suite does not test this ***\n' "$name"
            MUT_FAIL=1
        fi
    }

    m_identity() { # revert to identity resolution: take the first candidate unconditionally
        perl -0pi -e 's/        _ghc_meets "\$_ghc_cand"\n        case \$\? in/        _ghc_meets "\$_ghc_cand"\n        case 0 in/' "$MONITOR_DIR/gh-capable.sh"
    }
    # NB: this must track the DEFAULT FLOOR. When the floor moved 2.0.0 -> 2.86.0
    # the old pattern stopped matching, perl patched nothing, and the mutant
    # "survived" — the harness reporting a survivor is what caught it. A mutant
    # that cannot apply is indistinguishable from one the suite fails to kill,
    # so `apply_and_check` verifies the file actually changed.
    m_floorzero() { perl -0pi -e 's/\$\{NEXUS_GH_MIN_VERSION:-2\.86\.0\}/\${NEXUS_GH_MIN_VERSION:-0.0.0}/' "$MONITOR_DIR/gh-capable.sh"; }
    m_getrue()    { perl -0pi -e 's/^_ghc_ge\(\) \{\n/_ghc_ge() {\n    return 0\n/m' "$MONITOR_DIR/gh-capable.sh"; }
    m_stalecache(){ perl -0pi -e 's/                "\$_ghc_st "\*\)/                *)/' "$MONITOR_DIR/gh-capable.sh"; }
    m_silent()    { perl -0pi -e 's/if \[ "\$_gw_status" = degraded \]; then/if false; then/' "$MONITOR_DIR/ghwrap/gh"; }
    m_gatesilent(){ perl -0pi -e 's/        if \[ "\$_asw_ge" != 0 \]; then/        if false; then/' "$MONITOR_DIR/assert-shims-wrapped.sh"; }
    # The CI regression, reproduced in one token: treat "cannot read a version"
    # as "below the floor", so the resolver steps over an unreadable client and
    # runs a different binary. Six unit bands red at 5cab8c0.
    m_unverified(){ perl -0pi -e 's/\[ -n "\$_ghc_last_ver" \] \|\| return 2/[ -n "\$_ghc_last_ver" ] || return 1/' "$MONITOR_DIR/gh-capable.sh"; }

    apply_and_check identity-resolution m_identity
    apply_and_check floor-zero          m_floorzero
    apply_and_check ge-always-true      m_getrue
    apply_and_check stale-cache         m_stalecache
    apply_and_check degraded-silent     m_silent
    apply_and_check gate-silent         m_gatesilent
    apply_and_check unverified-skipped  m_unverified

    restore
    echo
    if [ "$MUT_FAIL" = 0 ]; then echo "ALL MUTANTS REDDEN THE SUITE"; exit 0; fi
    echo "SOME MUTANTS SURVIVED"; exit 1
fi

run_suite
echo
if [ "$FAIL" = 0 ]; then
    echo "ALL TESTS PASSED ($PASS)"
    exit 0
fi
echo "$PASS PASSED, $FAIL FAILED"
exit 1
