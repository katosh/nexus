#!/usr/bin/env bash
# Tests for monitor/assert-shims-wrapped.sh — the fail-CLOSED spawn-time
# precondition that refuses to start an agent unless EVERY PATH-front shim under
# monitor/*wrap is reachable in the shell the agent's Bash tool will use, and the
# worker's soft RLIMIT_NPROC ceiling is observed to apply and propagate
# (your-org/nexus-code#578 generalised by #589).
#
# The teeth this suite guards — the #578 set, now over the whole shim set:
#   - POSITIVE: with the REAL monitor/shellenv proxies (which re-front via
#     front-path.zsh) the guard PASSES even when the operator's ~/.zshrc
#     re-prepends decoys — i.e. the re-front actually beats the race #578 lost.
#   - NEGATIVE: a broken interactive proxy that does NOT re-front makes the
#     login+interactive (snapshot) probe resolve a decoy, and the guard REFUSES
#     (exit 1) naming that exact surface, while the non-interactive surface still
#     passes — proving the break is localized, not blanket.
#   - NOT CHECKED: shim dirs absent (fork / old checkout), NEXUS_ROOT unset, or
#     no probe shell → exit 79 and a loud banner, NEVER exit 0. "The check did
#     not run" and "the check ran and was clean" must not be the same observable
#     value (your-org/nexus-code#612).
#   - BASH carve-out: an interactive-bash miss is WARN-only (no ZDOTDIR analog to
#     fix ~/.bashrc), so it must NOT halt the spawn, and it must leave an
#     operator-facing breadcrumb.
#
# and the #589 additions:
#   - ENUMERATION: the guarded set is discovered from the shim DIRECTORIES, so a
#     newly-added shim dir is enforced with no edit to the guard. The regression
#     that matters is the FAIL-OPEN one: an unwrapped `pip` RUNS (the #487 fork
#     storm), unlike an unwrapped `gh` which errors for lack of credentials.
#   - SHADOWING: an alias/function ahead of the shim is a bypass by another
#     route and must refuse, not pass.
#   - NPROC, BY OBSERVATION: a ceiling the launcher requested but that did NOT
#     apply must refuse (the launcher's `ulimit … || true` swallows the failure),
#     and the limit must be observed in a spawned CHILD and GRANDCHILD.
#
# and the #612 addition, which is what this suite is FOR rather than merely
# something it checks:
#   - ROUTE INVARIANCE. The verdict must be a function of the STATE OF THE HOST,
#     never of which override variable the caller happened to set. That is not
#     an abstract nicety: the #612/#598 contradiction was demonstrably
#     satisfiable by an implementation that branched on NEXUS_SHIMWRAP_GLOB vs
#     NEXUS_GHWRAP_DIR and handed each suite the answer it wanted — it shipped
#     green through both. Every 79 condition below is therefore reached by all
#     three routes (each override, and NEITHER), and the three answers are
#     asserted EQUAL before they are asserted correct. An implementation that
#     discriminates on the fixture fails the equality assertion by name.
#
# Hermetic: fake shim dirs / decoys / HOME in a tmpdir; no network. zsh cases
# auto-SKIP (still exit 0) when zsh is absent.
#
# Run: bash monitor/watcher/test-assert-shims-wrapped.sh
# Expected: ALL TESTS PASSED, exit 0.

set -uo pipefail

_test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$_test_dir/../.." && pwd)
ASSERT="$REPO_ROOT/monitor/assert-shims-wrapped.sh"
LEGACY="$REPO_ROOT/monitor/assert-gh-wrapped.sh"

PASS=0; FAIL=0
ok()  { printf '  PASS: %s\n' "$1"; PASS=$(( PASS + 1 )); }
bad() { printf '  FAIL: %s — %s\n' "$1" "$2" >&2; FAIL=$(( FAIL + 1 )); }

[[ -x "$ASSERT" ]]                            || { echo "missing assert-shims-wrapped.sh" >&2; exit 1; }
[[ -x "$REPO_ROOT/monitor/ghwrap/gh" ]]       || { echo "missing ghwrap/gh" >&2; exit 1; }
[[ -x "$REPO_ROOT/monitor/pipwrap/pip" ]]     || { echo "missing pipwrap/pip" >&2; exit 1; }
[[ -f "$REPO_ROOT/monitor/shellenv/.zshrc" ]] || { echo "missing shellenv/.zshrc" >&2; exit 1; }
[[ -r "$REPO_ROOT/monitor/shellenv/front-path.zsh" ]] || { echo "missing front-path.zsh" >&2; exit 1; }

HAVE_ZSH=0; command -v zsh >/dev/null 2>&1 && HAVE_ZSH=1
ZSH_BIN=$(command -v zsh 2>/dev/null || echo /usr/bin/zsh)
BASH_BIN=$(command -v bash)

# The ambient soft RLIMIT_NPROC, read ONCE. Several cases need a finite one to
# construct a *confirmable* nproc failure; on a host where it is unlimited or
# unreadable they SKIP loudly rather than pass vacuously.
CEIL_PRECHECK=$(bash -c 'ulimit -Su' 2>/dev/null)
[[ "$CEIL_PRECHECK" == "unlimited" ]] && CEIL_PRECHECK=""

SB=$(mktemp -d)
# A native-compinit ~/.zshrc dumps to $ZDOTDIR/.zcompdump; the positive case
# uses the repo shellenv as ZDOTDIR, so clean any dump the probe leaves (it is
# gitignored at runtime — this keeps the test tree pristine).
trap 'rm -rf "$SB"; rm -f "$REPO_ROOT/monitor/shellenv/.zcompdump"*' EXIT

# ---------------------------------------------------------------------------
# Case 1 — POSITIVE against the REAL proxies and the REAL shim set. Fake HOME
# whose ~/.zshenv and ~/.zshrc re-prepend decoys for BOTH `gh` and `pip`
# (simulating linuxbrew); NEXUS_ROOT = repo so front-path.zsh fronts the real
# monitor/{ghwrap,pipwrap,notifywrap}. The guard must PASS.
# ---------------------------------------------------------------------------
if [[ $HAVE_ZSH -eq 1 ]]; then
    H1="$SB/home1"; DEC1="$SB/decoy1"; mkdir -p "$H1" "$DEC1"
    for n in gh pip pip3 sandbox-notify; do
        printf '#!/bin/sh\necho DECOY\n' > "$DEC1/$n"; chmod +x "$DEC1/$n"
    done
    printf 'export PATH="%s:$PATH"\n' "$DEC1" > "$H1/.zshenv"
    printf 'export PATH="%s:$PATH"\n' "$DEC1" > "$H1/.zshrc"
    out=$(HOME="$H1" NEXUS_ROOT="$REPO_ROOT" ZDOTDIR="$REPO_ROOT/monitor/shellenv" \
          NEXUS_ASSERT_GH_SHELL="$ZSH_BIN" SHELL="$ZSH_BIN" \
          NEXUS_ASSERT_SKIP_NPROC=1 \
          "$ASSERT" 2>&1); rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "positive(zsh): real proxies re-front over gh+pip decoys → guard passes"
    else
        bad "positive(zsh)" "expected exit 0, got $rc; output: $out"
    fi
fi
if [[ $HAVE_ZSH -ne 1 ]]; then
    printf '  SKIP: zsh absent — positive/negative/enumeration zsh cases skipped (CI installs zsh)\n'
fi

# ---------------------------------------------------------------------------
# Case 2 — NEGATIVE: a broken shellenv whose .zshenv fronts the shims but whose
# .zshrc re-prepends decoys and does NOT re-front. login+interactive must refuse
# (exit 1) naming that surface; non-interactive still passes.
# ---------------------------------------------------------------------------
if [[ $HAVE_ZSH -eq 1 ]]; then
    SH2="$SB/shims2"; GW2="$SH2/ghwrap"; PW2="$SH2/pipwrap"
    DEC2="$SB/decoy2"; SE2="$SB/shellenv2"
    mkdir -p "$GW2" "$PW2" "$DEC2" "$SE2"
    printf '#!/bin/sh\necho WRAP\n'  > "$GW2/gh";  chmod +x "$GW2/gh"
    printf '#!/bin/sh\necho WRAP\n'  > "$PW2/pip"; chmod +x "$PW2/pip"
    printf '#!/bin/sh\necho DECOY\n' > "$DEC2/gh"; chmod +x "$DEC2/gh"
    printf '#!/bin/sh\necho DECOY\n' > "$DEC2/pip"; chmod +x "$DEC2/pip"
    printf 'export PATH="%s:%s:$PATH"\n' "$GW2" "$PW2" > "$SE2/.zshenv"  # front shims
    printf 'export PATH="%s:$PATH"\n' "$DEC2" > "$SE2/.zshrc"            # bury, no re-front
    out=$(HOME="$SB/emptyhome" NEXUS_ROOT="$SB" ZDOTDIR="$SE2" \
          NEXUS_SHIMWRAP_GLOB="$SH2/*wrap" \
          NEXUS_ASSERT_GH_SHELL="$ZSH_BIN" SHELL="$ZSH_BIN" \
          NEXUS_ASSERT_SKIP_NPROC=1 \
          "$ASSERT" 2>&1); rc=$?
    if [[ $rc -eq 1 ]]; then
        ok "negative(zsh): broken interactive proxy → guard refuses (exit 1)"
    else
        bad "negative(zsh)" "expected exit 1, got $rc; output: $out"
    fi
    if grep -qi 'REFUSING SPAWN.*login+interactive' <<<"$out"; then
        ok "negative(zsh): refusal names the login+interactive (snapshot) surface"
    else
        bad "negative(zsh) reason" "refusal did not name the login+interactive surface; output: $out"
    fi
    if grep -qi 'REFUSING SPAWN.*non-interactive' <<<"$out"; then
        bad "negative(zsh) localization" "the non-interactive surface also refused — the break was not localized to interactive"
    else
        ok "negative(zsh): non-interactive surface passes — break localized to the snapshot surface (#578 signature)"
    fi
    # #589's core claim: the SAME break is reported for a NON-gh shim, and its
    # hazard note says FAIL-OPEN. This is the assertion that would have caught
    # the gh-only guard leaving the #487 pip storm unenforced.
    if grep -q 'REFUSING SPAWN.*`pip`' <<<"$out"; then
        ok "negative(zsh): the pip shim is enforced too, not just gh (#589)"
    else
        bad "negative(zsh) pip" "no refusal naming \`pip\`; output: $out"
    fi
    if grep -qi 'FAIL-OPEN' <<<"$out" && grep -q '#487' <<<"$out"; then
        ok "negative(zsh): pip refusal states the FAIL-OPEN consequence and cites #487"
    else
        bad "negative(zsh) pip hazard" "pip refusal lacked the FAIL-OPEN/#487 rationale; output: $out"
    fi
fi

# ---------------------------------------------------------------------------
# Case 3 — ENUMERATION, not a hand-maintained list. Drop a NEW shim dir
# (monitor-style `*wrap`) containing a brand-new name the guard has never heard
# of, bury it, and the guard must refuse for THAT name with no edit to the guard.
# This is the anti-regression for the failure class #589 is about: a mechanism
# that exists and silently stops applying.
# ---------------------------------------------------------------------------
if [[ $HAVE_ZSH -eq 1 ]]; then
    SH3="$SB/shims3"; NW3="$SH3/newwrap"; DEC3="$SB/decoy3"; SE3="$SB/shellenv3"
    mkdir -p "$NW3" "$DEC3" "$SE3"
    printf '#!/bin/sh\necho WRAP\n'  > "$NW3/frobnicate"; chmod +x "$NW3/frobnicate"
    printf '#!/bin/sh\necho DECOY\n' > "$DEC3/frobnicate"; chmod +x "$DEC3/frobnicate"
    printf 'export PATH="%s:$PATH"\n' "$NW3"  > "$SE3/.zshenv"
    printf 'export PATH="%s:$PATH"\n' "$DEC3" > "$SE3/.zshrc"
    out=$(HOME="$SB/emptyhome" NEXUS_ROOT="$SB" ZDOTDIR="$SE3" \
          NEXUS_SHIMWRAP_GLOB="$SH3/*wrap" \
          NEXUS_ASSERT_GH_SHELL="$ZSH_BIN" SHELL="$ZSH_BIN" \
          NEXUS_ASSERT_SKIP_NPROC=1 \
          "$ASSERT" 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && grep -q 'frobnicate' <<<"$out"; then
        ok "enumeration: a brand-new shim dir/name is enforced with no edit to the guard (#589)"
    else
        bad "enumeration" "expected exit 1 naming frobnicate, got $rc; output: $out"
    fi
fi

# ---------------------------------------------------------------------------
# Case 4 — SHADOWING: an alias ahead of the shim is a bypass by another route.
# The shim dir IS fronted, so a dir-prefix check alone would pass; only an
# answer-shape check catches it.
# ---------------------------------------------------------------------------
if [[ $HAVE_ZSH -eq 1 ]]; then
    SH4="$SB/shims4"; GW4="$SH4/ghwrap"; SE4="$SB/shellenv4"
    mkdir -p "$GW4" "$SE4"
    printf '#!/bin/sh\necho WRAP\n' > "$GW4/gh"; chmod +x "$GW4/gh"
    printf 'export PATH="%s:$PATH"\n' "$GW4" > "$SE4/.zshenv"
    { printf 'export PATH="%s:$PATH"\n' "$GW4"
      printf 'alias gh="echo ALIASED"\n'; } > "$SE4/.zshrc"
    out=$(HOME="$SB/emptyhome" NEXUS_ROOT="$SB" ZDOTDIR="$SE4" \
          NEXUS_SHIMWRAP_GLOB="$SH4/*wrap" \
          NEXUS_ASSERT_GH_SHELL="$ZSH_BIN" SHELL="$ZSH_BIN" \
          NEXUS_ASSERT_SKIP_NPROC=1 \
          "$ASSERT" 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && grep -qi 'SHADOWED' <<<"$out"; then
        ok "shadowing: an alias ahead of the shim refuses (not a silent pass)"
    else
        bad "shadowing" "expected exit 1 naming SHADOWED, got $rc; output: $out"
    fi
fi

# ---------------------------------------------------------------------------
# Case 5 — NOT CHECKED: no shim dirs → exit 79 (your-org/nexus-code#612).
#
# This case previously asserted exit 0 with the label "skip: nothing to
# enforce", which made the suite its own instance of the defect it exists to
# prevent: "nothing to enforce" and "enforced and clean" were one observable,
# and the branch produced it in a stderr line no caller had any reason to read.
# The operator's ruling is 79, and it lands HERE — in assert-shims-wrapped.sh,
# the guard monitor/guard-block.sh.in actually reaches. Landed in the
# deprecated assert-gh-wrapped.sh forwarder instead, the branch would never
# execute and this suite would still be green.
#
# The message assertions are load-bearing, not decoration: they are what stops
# 79 collapsing back into "some non-zero". Matched on the TEXT, so a
# coincidental 79 from an unrelated cause cannot pass for the contract.
# ---------------------------------------------------------------------------
out=$(NEXUS_ROOT="$SB" NEXUS_SHIMWRAP_GLOB="$SB/does-not-exist/*wrap" \
      NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
      NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>&1); rc=$?
if [[ $rc -eq 79 ]]; then
    ok "not-checked: shim dirs absent → exit 79, distinguishable from a pass"
else
    bad "not-checked" "expected exit 79 when shim dirs absent, got $rc; output: $out"
fi
if grep -q 'NOT CHECKED: no shim dirs found' <<<"$out"; then
    ok "not-checked: the shim-dirs-absent branch is LOUD about what went unverified"
else
    bad "not-checked loudness" "expected a 'NOT CHECKED: no shim dirs found' banner; got: $out"
fi
if grep -q 'This is not a pass' <<<"$out"; then
    ok "not-checked: the verdict explicitly denies itself the status of a pass"
else
    bad "not-checked verdict" "expected the verdict line to deny it is a pass; got: $out"
fi

# ---------------------------------------------------------------------------
# Case 5b — the OTHER two unadjudicable states. The merge-verification skeptic
# found the #612/#598 contradiction was three conditions, not the one that was
# reported; fixing only the named one would have left two live.
# ---------------------------------------------------------------------------
out=$(env -u NEXUS_ROOT NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
      NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>&1); rc=$?
if [[ $rc -eq 79 ]] && grep -q 'NOT CHECKED: NEXUS_ROOT unset' <<<"$out"; then
    ok "not-checked: NEXUS_ROOT unset → 79, naming the malformed launcher env"
else
    bad "not-checked root-unset" "expected exit 79 naming NEXUS_ROOT unset, got $rc; output: $out"
fi

out=$(NEXUS_ROOT="$REPO_ROOT" NEXUS_ASSERT_GH_SHELL="$SB/no-such-shell-$$" \
      SHELL="$SB/no-such-shell-$$" NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>&1); rc=$?
if [[ $rc -eq 79 ]] && grep -q 'NOT CHECKED: probe shell' <<<"$out"; then
    ok "not-checked: probe shell missing → 79, naming the shell it could not run"
else
    bad "not-checked probe-shell" "expected exit 79 naming the probe shell, got $rc; output: $out"
fi

# A CONFIRMED failure must OUTRANK an unexaminable precondition. Without this,
# an implementation could report 79 and convert a refusal into an
# allow-with-a-note — the same fail-open direction in a new costume.
#
# UNCONDITIONAL, and that is the whole point of its construction (skeptic
# req-001). The first version built the CONFIRMED leg from an nproc ceiling
# that did not apply, which needs a FINITE ambient soft RLIMIT_NPROC and so
# skipped itself on any host without one — containers, routinely. Worse, the
# assertion-count guard was incremented by the same condition, so the count
# agreed that nothing was missing: the one pin on this contract vanished and
# the guard against vanishing pins reported "expected for this host". An
# adversary that inverts ONLY the precedence — accumulator kept, every message
# kept — shipped ALL TESTS PASSED on both suites under that condition while
# returning 79 where the honest guard returns 1.
#
# So the CONFIRMED leg is now a SHIM refusal, which needs nothing from the
# host's rlimits: a real shim dir supplied through the glob, with a decoy
# ahead of it on the inherited PATH so the enforceable `-c` surface resolves
# the decoy. The unexaminable leg is NEXUS_ROOT unset — deliberately not the
# missing probe shell, because with no probe shell no probe runs and no
# refusal can be confirmed, so those two are mutually exclusive by
# construction. Both signals are asserted present, so this cannot pass by
# refusing for a reason that has nothing to do with precedence.
PREC="$SB/prec"; mkdir -p "$PREC/shims/ghwrap" "$PREC/decoy"
printf '#!/bin/sh\necho WRAP\n'  > "$PREC/shims/ghwrap/gh"; chmod +x "$PREC/shims/ghwrap/gh"
printf '#!/bin/sh\necho DECOY\n' > "$PREC/decoy/gh";        chmod +x "$PREC/decoy/gh"
out=$(env -u NEXUS_ROOT -u BASH_ENV PATH="$PREC/decoy:/usr/bin:/bin" \
      NEXUS_SHIMWRAP_GLOB="$PREC/shims/*wrap" \
      NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
      NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>&1); rc=$?
if [[ $rc -eq 1 ]]; then
    ok "precedence: a CONFIRMED failure outranks NOT CHECKED (1, never 79)"
else
    bad "precedence" "expected exit 1 when a leg refuses alongside an unchecked one, got $rc; output: $out"
fi
if grep -q 'NOT CHECKED: NEXUS_ROOT unset' <<<"$out" && grep -q 'REFUSING SPAWN' <<<"$out"; then
    ok "precedence: …and BOTH legs really occurred — this is a precedence case, not a bare refusal"
else
    bad "precedence construction" "the fixture did not exhibit an unchecked leg AND a confirmed leg together; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 5c — ROUTE INVARIANCE, the assertion this suite exists for.
#
# The same host state ("there are no shim dirs anywhere") is reached three
# ways: through NEXUS_SHIMWRAP_GLOB, through the pre-#589 NEXUS_GHWRAP_DIR
# override, and through NEITHER — a real NEXUS_ROOT whose default
# monitor/*wrap glob simply matches nothing. The third route is the decisive
# one, because it is the only one a production launcher takes and the only one
# no fixture can be recognised by.
#
# Equality is asserted BEFORE correctness, and separately, so the failure
# message distinguishes "the guard is wrong" from "the guard is answering the
# fixture". The merge-verification skeptic built exactly that second
# implementation — a branch on which override was set, routing each suite to
# the answer it wanted — and it passed both suites while being illegitimate.
# This assertion is what makes that construction fail, by name.
#
# WHAT THIS CASE PINS, precisely: the OVERRIDE axis. An earlier version of this
# comment said the no-override route is "the only one no fixture can be
# recognised by". That sentence was FALSE and a depth-1 skeptic falsified it by
# construction: all three routes here run against SPARSE temp trees, so an
# implementation that discriminates on TREE SHAPE — "does $NEXUS_ROOT carry
# monitor/spawn-worker.sh, i.e. is it a real checkout?" — agrees on all three
# and passes. It then returns 0 on a real checkout stripped of its shim dirs,
# which is the #614 / re-rooted-#577 state the whole contract exists for. That
# is this branch's own wrong-axis lesson recurring against the assertion
# written to prevent it. Case 5e below pins the tree-shape axis; the residual
# is declared there.
# ---------------------------------------------------------------------------
NOROOT="$SB/bare_root"; mkdir -p "$NOROOT/monitor"     # a root with NO *wrap dirs
r_glob=$(NEXUS_ROOT="$SB" NEXUS_SHIMWRAP_GLOB="$SB/does-not-exist/*wrap" \
         NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
         NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>/dev/null; echo $?)
r_ghwrap=$(NEXUS_ROOT="$NOROOT" NEXUS_GHWRAP_DIR="$NOROOT/monitor/ghwrap" \
           NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
           NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>/dev/null; echo $?)
r_none=$(env -u NEXUS_SHIMWRAP_GLOB -u NEXUS_GHWRAP_DIR \
         NEXUS_ROOT="$NOROOT" NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
         NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>/dev/null; echo $?)
if [[ "$r_glob" == "$r_ghwrap" && "$r_ghwrap" == "$r_none" ]]; then
    ok "route invariance: one host state → one verdict, whichever override the caller set"
else
    bad "route invariance" \
        "the verdict depends on WHICH override the caller set — that discriminates on the fixture, not on the property (NEXUS_SHIMWRAP_GLOB=$r_glob NEXUS_GHWRAP_DIR=$r_ghwrap neither=$r_none)"
fi
if [[ "$r_none" -eq 79 ]]; then
    ok "route invariance: and the shared verdict is 79, reached with NO override at all"
else
    bad "route invariance value" "expected 79 on the no-override route (the only one a launcher takes), got $r_none"
fi

# ---------------------------------------------------------------------------
# Case 5e — TREE-SHAPE INVARIANCE. The second axis, and the one Case 5c does
# not reach (skeptic req-001).
#
# Every fixture above builds a SPARSE temp tree: a `monitor/` dir and little
# else. A real nexus checkout is dense — spawn-worker.sh, config/, skills/,
# docs/, the lot. That difference is a signal, and a signal a fixture can be
# recognised by is a signal a wrong implementation can discriminate on. The
# demonstrated one keyed on `-f $NEXUS_ROOT/monitor/spawn-worker.sh` and
# revived `dev`'s "nothing to enforce → exit 0" rationale for real checkouts
# only. It passed all five suites.
#
# So the SAME condition — no shim dirs under the resolved root — is exercised
# against a tree that IS a real checkout by every structural test: a full copy
# of this repo (minus .git) with monitor/*wrap removed. That is the #614 shape
# and the re-rooted-#577 shape both. The two answers are asserted EQUAL first,
# then correct, exactly as in 5c.
#
# DECLARED RESIDUAL, on the axis the mechanism varies on: this pins the
# verdict's invariance across the OVERRIDE axis (5c) and the TREE-SHAPE axis
# (here). It does NOT and cannot enumerate every property of the environment a
# discriminator might key on — hostname, an unrelated env var, a file count, a
# timing signal. Two axes are pinned by measurement; the rest is unpinned and
# is stated as unpinned rather than implied to be covered.
# ---------------------------------------------------------------------------
DENSE="$SB/dense_checkout"; mkdir -p "$DENSE"
if ( cd "$REPO_ROOT" && tar --exclude=./.git -cf - . ) 2>/dev/null | ( cd "$DENSE" && tar xf - ) 2>/dev/null \
   && [[ -f "$DENSE/monitor/spawn-worker.sh" && -d "$DENSE/config" ]]; then
    rm -rf "$DENSE"/monitor/*wrap
    n_wrap=$(find "$DENSE/monitor" -maxdepth 1 -name '*wrap' | wc -l)
    if [[ "$n_wrap" -ne 0 ]]; then
        bad "tree-shape fixture" "the dense tree still carries $n_wrap shim dir(s) — the case would assert nothing"
    else
        r_dense=$(NEXUS_ROOT="$DENSE" NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
                  NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>/dev/null; echo $?)
        if [[ "$r_dense" == "$r_none" ]]; then
            ok "tree-shape invariance: a DENSE real checkout and a sparse temp tree get the same verdict"
        else
            bad "tree-shape invariance" \
                "the verdict depends on whether the root LOOKS like a real checkout — that discriminates on the fixture, not on the property (dense=$r_dense sparse=$r_none)"
        fi
        if [[ "$r_dense" -eq 79 ]]; then
            ok "tree-shape invariance: and a real checkout stripped of its shim dirs is 79 (the #614 state)"
        else
            bad "tree-shape value" "expected 79 on a real checkout with no shim dirs — the state the contract exists for — got $r_dense"
        fi
    fi
else
    bad "tree-shape fixture" "could not build the dense checkout copy under $DENSE; the tree-shape axis went unexercised"
fi

# ---------------------------------------------------------------------------
# Case 5d — the DECLARED BOUND of the 79 contract, asserted rather than merely
# written down. An explicit caller opt-out is NOT an absent precondition: the
# caller that set the flag already knows which leg it disabled, so those return
# 0. The bound is only honest while no launcher sets one — so that is checked
# too, on the axis the mechanism varies on (who sets the flag), not on prose.
# ---------------------------------------------------------------------------
rc=$(NEXUS_ROOT="$SB" NEXUS_ASSERT_SKIP_SHIMS=1 NEXUS_ASSERT_SKIP_NPROC=1 \
     NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" "$ASSERT" 2>/dev/null; echo $?)
if [[ "$rc" -eq 0 ]]; then
    ok "declared bound: an EXPLICIT skip is not an absent precondition → 0, not 79"
else
    bad "declared bound" "expected exit 0 under explicit skip flags, got $rc"
fi
setters=$(grep -lE 'NEXUS_ASSERT_SKIP_(SHIMS|NPROC)=' \
    "$REPO_ROOT/monitor/spawn-worker.sh" "$REPO_ROOT/monitor/watcher/_respawn.sh" \
    "$REPO_ROOT/monitor/guard-block.sh.in" 2>/dev/null || true)
if [[ -z "$setters" ]]; then
    ok "declared bound: no launcher sets a skip flag, so the bound stays a test-only affordance"
else
    bad "declared bound leaked" "a launcher sets NEXUS_ASSERT_SKIP_*, which silently converts a real 79 into a 0: $setters"
fi

# ---------------------------------------------------------------------------
# Case 6 — BASH carve-out: an interactive-bash miss must WARN (reaching the
# operator), not refuse. The `-c` surface re-fronts via BASH_ENV (→ shim), while
# the interactive `-lic` surface resolves an unwrapped gh. Guard must exit 0 AND
# emit the "not enforceable" carve-out warning AND leave a breadcrumb.
#
# DETERMINISM (your-org/nexus-code#578 CI flake): the decoy must reach the
# `-lic` probe WITHOUT depending on whether login+interactive bash sources
# ~/.bashrc — it does NOT reliably (a login shell reads a profile, not
# ~/.bashrc, unless the profile sources it; that variance is what made this case
# pass locally and fail in CI). So the decoy is put on the INHERITED PATH
# (resolves with no rc-sourcing at all) AND re-prepended from ~/.bash_profile /
# ~/.profile (the files a login bash DOES read, sourced after /etc/profile so
# they survive a PATH reset). BASH_ENV fronts the shim for the non-interactive
# `-c` surface only (interactive bash does not read BASH_ENV).
# ---------------------------------------------------------------------------
SH6="$SB/shims6"; GW6="$SH6/ghwrap"; DEC6="$SB/decoy6"; H6="$SB/home6"
mkdir -p "$GW6" "$DEC6" "$H6" "$SB/monitor/.state"   # .state so the breadcrumb path runs
printf '#!/bin/sh\necho WRAP\n'  > "$GW6/gh"; chmod +x "$GW6/gh"
printf '#!/bin/sh\necho DECOY\n' > "$DEC6/gh"; chmod +x "$DEC6/gh"
# Non-interactive re-front hook (stands in for bash_env.sh): front the shim.
BENV6="$SB/bashenv6.sh"; printf 'export PATH="%s:$PATH"\n' "$GW6" > "$BENV6"
# Login-bash profiles re-prepend the decoy (survive an /etc/profile PATH reset).
printf 'export PATH="%s:$PATH"\n' "$DEC6" > "$H6/.bash_profile"
printf 'export PATH="%s:$PATH"\n' "$DEC6" > "$H6/.profile"
printf 'export PATH="%s:$PATH"\n' "$DEC6" > "$H6/.bashrc"
out=$(HOME="$H6" NEXUS_ROOT="$SB" NEXUS_SHIMWRAP_GLOB="$SH6/*wrap" BASH_ENV="$BENV6" \
      PATH="$DEC6:/usr/bin:/bin" \
      NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
      NEXUS_ASSERT_SKIP_NPROC=1 "$ASSERT" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then
    ok "bash carve-out: interactive-bash miss does not halt the spawn (exit 0)"
else
    bad "bash carve-out" "expected exit 0 (warn-only for bash -lic), got $rc; output: $out"
fi
if grep -qi 'CARVE-OUT.*not enforceable' <<<"$out"; then
    ok "bash carve-out: emits the 'not enforceable' carve-out warning for the interactive surface"
else
    bad "bash carve-out reason" "expected a 'not enforceable' carve-out warning; output: $out"
fi
if [[ -s "$SB/monitor/.state/gh-wrapper-carveout.log" ]]; then
    ok "bash carve-out: recorded a persistent operator-facing breadcrumb"
else
    bad "bash carve-out surfacing" "carve-out wrote no breadcrumb to \$NEXUS_ROOT/monitor/.state; output: $out"
fi

# ---------------------------------------------------------------------------
# Case 7 — RLIMIT_NPROC by OBSERVATION (#589).
#
# 7a. A ceiling the launcher CLAIMS to have set but which did not apply must
#     refuse. This is the swallowed-`|| true` hole: reading the launcher source
#     for a `ulimit` line proves nothing about the live limit.
# 7b. A correctly-applied ceiling passes, and the assertion actually observed a
#     CHILD and a GRANDCHILD (rather than only its own process). We prove the
#     observation is real by making the child/grandchild readings differ from
#     ours: run the guard with a HIGHER soft limit than the shell it spawns can
#     see is impossible without privileges, so instead assert the positive
#     direction (equal limits pass) and, separately, that a genuinely
#     non-propagating chain is caught (7c).
# 7c. A grandchild whose limit RISES above ours must refuse. Simulated with a
#     stub `bash` on PATH that reports a higher `ulimit -Su` — the guard shells
#     out to `bash`, so a stub is the only way to exhibit a non-propagating
#     kernel without one.
# ---------------------------------------------------------------------------
CEIL="$CEIL_PRECHECK"
if [[ -z "$CEIL" ]]; then
    printf '  SKIP: ambient soft RLIMIT_NPROC is unlimited/unreadable — nproc cases need a finite one\n'
else
    # 7a — request a ceiling far below the live one → refuse, naming the class.
    out=$(NEXUS_ROOT="$SB" NEXUS_ASSERT_SKIP_SHIMS=1 \
          NEXUS_ASSERT_NPROC_EXPECT=1 "$ASSERT" 2>&1); rc=$?
    if [[ $rc -eq 1 ]] && grep -q 'RLIMIT_NPROC' <<<"$out" && grep -q '#487' <<<"$out"; then
        ok "nproc: a requested ceiling that did NOT apply refuses (swallowed \`|| true\`, #487)"
    else
        bad "nproc not-applied" "expected exit 1 citing RLIMIT_NPROC/#487, got $rc; output: $out"
    fi

    # 7b — the live ceiling, honestly declared, passes.
    out=$( (ulimit -Su "$CEIL" 2>/dev/null; NEXUS_ROOT="$SB" NEXUS_ASSERT_SKIP_SHIMS=1 \
            NEXUS_ASSERT_NPROC_EXPECT="$CEIL" "$ASSERT" 2>&1) ); rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "nproc: an applied ceiling that propagates to child+grandchild passes"
    else
        bad "nproc applied" "expected exit 0, got $rc; output: $out"
    fi

    # 7c — NEGATIVE CONTROL for the propagation leg. A stub `bash` that reports
    # a higher soft limit than the guard's own must be caught; without the
    # child/grandchild observation this case is indistinguishable from 7b.
    STUB6="$SB/stub-nproc"; mkdir -p "$STUB6"
    cat > "$STUB6/bash" <<STUB
#!/bin/sh
# Report a soft limit ABOVE the guard's own for the ulimit probes; anything
# else (the python leg) is delegated to the real bash.
case "\$*" in
    *ulimit*) echo $(( CEIL + 4096 )); exit 0 ;;
esac
exec $BASH_BIN "\$@"
STUB
    chmod +x "$STUB6/bash"
    out=$( (ulimit -Su "$CEIL" 2>/dev/null
            PATH="$STUB6:$PATH" NEXUS_ROOT="$SB" NEXUS_ASSERT_SKIP_SHIMS=1 \
            NEXUS_ASSERT_NPROC_EXPECT="$CEIL" "$ASSERT" 2>&1) ); rc=$?
    if [[ $rc -eq 1 ]] && grep -qi 'RISES' <<<"$out"; then
        ok "nproc: a limit that RISES in a spawned child/grandchild refuses (propagation is observed, not assumed)"
    else
        bad "nproc propagation" "expected exit 1 naming a RISE, got $rc; output: $out"
    fi
fi

# ---------------------------------------------------------------------------
# Case 8 — the deprecated gh-only entry point still forwards, so a stale
# launcher or a fork that calls the old name keeps getting a real check instead
# of silently skipping it (which is the #589 failure class itself).
#
# It must now forward the 79 VERDICT too, unchanged. A forwarder that flattened
# 79 to 0 would restore the exact contradiction #612 exists to remove, on the
# one entry point old callers still use — and it would do it silently, because
# every direct-call assertion above would stay green.
# ---------------------------------------------------------------------------
if [[ -x "$LEGACY" ]]; then
    out=$(NEXUS_ROOT="$SB" NEXUS_SHIMWRAP_GLOB="$SB/does-not-exist/*wrap" \
          NEXUS_ASSERT_GH_SHELL="$BASH_BIN" SHELL="$BASH_BIN" \
          NEXUS_ASSERT_SKIP_NPROC=1 "$LEGACY" 2>&1); rc=$?
    if [[ $rc -eq 79 ]] && grep -q 'assert-shims-wrapped' <<<"$out"; then
        ok "legacy entry point forwards to the generalised guard, verdict intact (79)"
    else
        bad "legacy delegation" "expected exit 79 with output from the successor, got $rc; output: $out"
    fi
else
    bad "legacy delegation" "monitor/assert-gh-wrapped.sh is missing — stale launchers would skip the check entirely"
fi

# ---------------------------------------------------------------------------
# Case 9 — every agent-spawning launcher must actually CALL the guard, and must
# apply its nproc ceiling BEFORE calling it (else the observation is vacuous).
#
# Rewritten for the #612 merge, and the rewrite is the point. The guard call no
# longer appears in spawn-worker.sh at all: it lives in the single-source
# template monitor/guard-block.sh.in, interpolated as $SHIM_GUARD_BLOCK. The
# previous form grepped spawn-worker.sh for the literal `assert-shims-wrapped.sh`
# and would have gone RED for a wiring that is in fact correct — a check
# asserting a proxy (a string in a file) rather than the property (the guard is
# reached from the emitted launcher, after the ceiling).
#
# The ordering check is also per-EMISSION-SITE now. The old awk took the FIRST
# match of each marker in the whole file, so a second or third launcher emitting
# them in the wrong order was invisible; spawn-worker.sh emits three.
# ---------------------------------------------------------------------------
sw="$REPO_ROOT/monitor/spawn-worker.sh"
TPL9="$REPO_ROOT/monitor/guard-block.sh.in"

# Link 1 — the emitted block reaches the generalised guard, and prefers it.
if [[ -r "$TPL9" ]] && grep -q 'assert-shims-wrapped.sh assert-gh-wrapped.sh' "$TPL9"; then
    ok "wiring: the emitted guard block searches the generalised guard FIRST"
else
    bad "wiring template" "guard-block.sh.in does not search assert-shims-wrapped.sh ahead of the deprecated name"
fi

# Link 2 — every launcher heredoc emits, IN ORDER: the ceiling, the declared
# expectation, then the block. Checked inside each heredoc region separately.
ord=$(awk '
    /^[[:space:]]*cat > "\$LAUNCHER_TMP" <<LAUNCHER$/ { inh = 1; sites++; u = e = g = 0; next }
    inh && /^LAUNCHER$/ {
        inh = 0
        if (!u)         bad = bad " site" sites ":no-ulimit-line"
        else if (!e)    bad = bad " site" sites ":no-nproc-expect"
        else if (!g)    bad = bad " site" sites ":no-guard-block"
        else if (!(u < e && e < g)) bad = bad " site" sites ":order(u=" u ",e=" e ",g=" g ")"
        next
    }
    inh && /^\$NPROC_ULIMIT_LINE$/                         { u = NR }
    inh && /^export NEXUS_ASSERT_NPROC_EXPECT=/            { e = NR }
    inh && /^\$SHIM_GUARD_BLOCK$/                          { g = NR }
    END { if (sites == 0) print "no-launcher-heredocs-found"; else if (bad != "") print bad; else print "ok:" sites }
' "$sw")
if [[ "$ord" == ok:* ]]; then
    ok "wiring: all ${ord#ok:} spawn-worker launchers apply the ceiling, declare it, then run the guard — in that order"
else
    bad "wiring order" "a launcher heredoc emits the guard block without the ceiling before it, or emits nothing: $ord"
fi

# Link 3 — the orchestrator's launcher is composed by a real function, so
# assert against the COMPOSED TEXT rather than against _respawn.sh's source.
L9="$SB/wiring-launcher.sh"
( set +u
  CLAUDE_BIN=/bin/true
  . "$REPO_ROOT/monitor/watcher/_respawn.sh"
  _respawn_compose_launcher "$L9" "$REPO_ROOT" "" "" "orchestrator" "" ) >/dev/null 2>&1
if [[ -s "$L9" ]] && grep -q 'assert-shims-wrapped.sh' "$L9"; then
    ok "wiring: the COMPOSED orchestrator launcher reaches the generalised guard"
else
    bad "wiring respawn" "the launcher _respawn.sh actually composes does not reach assert-shims-wrapped.sh"
fi

# Hygiene: the runtime .zcompdump (unavoidable with native compinit) must be
# gitignored so it can never pollute a commit. That is the real contract.
if grep -q 'monitor/shellenv/.zcompdump' "$REPO_ROOT/.gitignore" 2>/dev/null; then
    ok "hygiene: monitor/shellenv/.zcompdump* is gitignored"
else
    bad "hygiene" ".gitignore is missing the monitor/shellenv/.zcompdump* entry"
fi

# ---------------------------------------------------------------------------
# ASSERTION COUNT — the verdict is not the whole story.
#
# `ALL TESTS PASSED` is a claim about the assertions that RAN. An assertion
# that never ran is counted by nothing: a helper that vanished exits 127 mid
# case, an `if` whose precondition silently went false skips its whole block,
# and either way the footer still reads green with a smaller number nobody
# looks at. This workspace has shipped that exact failure.
#
# So the expected count is DECLARED, per group, from the same conditions that
# gate the groups. A drop is a case that stopped executing; an unexplained rise
# is a case counted twice. Adding a case means bumping the number here on
# purpose — which is the point, not friction.
# ---------------------------------------------------------------------------
# 3 (case 5) + 2 (5b conditions) + 2 (5b precedence) + 2 (5c) + 2 (5e)
# + 2 (5d) + 3 (case 6) + 1 (case 8) + 3 (case 9) + 1 (hygiene).
# Counted BEFORE this assertion itself runs.
#
# The PRECEDENCE pair is in the UNCONDITIONAL base now, not in the nproc
# group. That relocation is the fix, not bookkeeping: when a contract's only
# pin sits behind a host condition AND the expected count is incremented by
# the same condition, the count guard certifies the loss instead of catching
# it — "expected for this host" is exactly the shape of a check that asserts a
# proxy. A number that cannot move with the host cannot launder a missing
# assertion.
EXPECT=21
(( HAVE_ZSH ))            && EXPECT=$(( EXPECT + 8 ))   # cases 1-4
[[ -n "$CEIL_PRECHECK" ]] && EXPECT=$(( EXPECT + 3 ))   # case 7a/b/c only
RAN=$(( PASS + FAIL ))
if (( RAN == EXPECT )); then
    ok "assertion count: $RAN executed, $EXPECT expected for this host"
else
    bad "assertion count" "$RAN assertions executed but $EXPECT were expected (HAVE_ZSH=$HAVE_ZSH CEIL=${CEIL_PRECHECK:-none}) — a case stopped running, or a helper exited 127 and was counted by nothing"
fi

echo
if [[ $FAIL -eq 0 ]]; then
    printf 'ALL TESTS PASSED (%d)\n' "$PASS"; exit 0
else
    printf '%d PASSED, %d FAILED\n' "$PASS" "$FAIL" >&2; exit 1
fi
